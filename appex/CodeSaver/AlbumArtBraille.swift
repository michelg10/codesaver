//
//  AlbumArtBraille.swift
//  CodeSaver
//
//  Album art -> COLOURED Unicode braille (U+2800..U+28FF) dot matrix.
//
//  Native port of feeds/albumart/braille.py. The Python is the source of truth
//  for the *look*; this file reproduces its arithmetic step for step, including
//  PIL's LANCZOS resampler (fixed-point, two-pass, 8-bit intermediate), CPython's
//  round-half-to-even, colorsys' HSV, and the nearest-rank percentile.
//
//  PIPELINE
//    1. resize to the dot grid (2*cols x 4*rows) and dither to 1 bit using an
//       unsharp local-contrast pass + gamma, NOT naive luminance thresholding;
//    2. pack the dot bits into braille codepoints;
//    3. colour each CELL from its INKED dots only (blended toward the whole 2x4
//       region, weighted by how many dots voted), lift chroma with a convex
//       peak-pinned curve whose knee is adaptive to the cover's own chroma and
//       whose evidence is gated by how much light the cell has, then solve HSV
//       value LUMA-FIRST so that saturating a cell no longer darkens it;
//    4. auto-scale the luma ramp so the 99.5th percentile lands on `peakLuma`.
//
//  Every constant braille.py exposes lives in `Params`, which is passed down
//  the call chain -- no shared mutable state, so renders are safe to run
//  concurrently and the app's tuning window can drive one without touching
//  what the saver is drawing. `Params()` is byte-for-byte the Python.
//
//  Everything is namespaced inside the enum on purpose: this target also hosts a
//  sibling ramp renderer, so no file-scope symbol may be introduced here.
//
import Foundation
import CoreGraphics

enum AlbumArtBraille {

    // MARK: - Tunables

    /// Every knob braille.py exposes, as a value passed *through* the render
    /// rather than read off the type. Two renders with different `Params` can
    /// therefore run at the same time — nothing here is shared, mutable state.
    ///
    /// Defaults ARE the Python constants; `Params()` reproduces braille.py.
    ///
    /// Everything is a `Double`, including the four counts that are really
    /// integers (`cols`, `rows`, `quant`, `chClip`), so a UI can bind one
    /// slider type to all of them; the renderer reads the integers back
    /// through `colCount` / `rowCount` / `quantStep` / `channelClip`, which
    /// round and clamp.
    struct Params: Equatable {

        // --- grid -----------------------------------------------------------
        /// Character grid. The dot grid is 2 dots per cell across, 4 down.
        var cols: Double = 46
        var rows: Double = 23

        // --- tone -----------------------------------------------------------
        var blurR: Double = 8.0             // dots; local-contrast radius
        var sharpen: Double = 0.40          // unsharp amount
        var loPct: Double = 1.0
        var hiPct: Double = 96.0
        var gamma: Double = 2.10
        var floor: Double = 0.03
        var ceil: Double = 0.98

        // --- colour ---------------------------------------------------------
        var satToe: Double = 0.035          // below this the cell is neutral, not tinted
        var satKneeMin: Double = 0.474      // floor of the adaptive chroma knee
        var satKneePct: Double = 96.0       // ... which rises to this percentile of the cover's own chroma
        var satPow: Double = 1.55           // >1 == convex: the middle falls away faster than linearly
        var satMax: Double = 0.92
        var chromaDarkToe: Double = 0.05    // source V under this carries no usable hue
        var chromaDarkKnee: Double = 0.28   // ... full chroma only trusted from here up

        // --- luma -----------------------------------------------------------
        var lumFloor: Double = 0.46         // target Rec.709 luma of the darkest cell
        var lumPeak: Double = 0.88          // ... and the brightest, before the auto-scale
        var lumPow: Double = 0.56           // <1 == lifts the mids of the luminance ramp
        var hueLumaFloor: Double = 0.30     // stop dividing once a hue is this dark
        var vKnee: Double = 0.80            // soft-clip joint for v
        var peakLuma: Double = 216.0        // target 99.5th-pct luma of the rendered cells
        var chClip: Double = 238            // hard channel ceiling
        var quant: Double = 3               // colour quantisation step

        init() {}

        /// Anything missing, unknown, or not a finite number keeps its default;
        /// anything present is clamped to its slider's range. The file is
        /// hand-editable, and `blurR`/`loPct`/`hiPct` reach `Int()` further
        /// down — a value past Int.max there is a fatal error, not a bad render.
        init(json: [String: Double]) {
            for t in Self.tunables {
                guard let v = json[t.key], v.isFinite else { continue }
                self[t.key] = Swift.min(Swift.max(v, t.min), t.max)
            }
        }

        /// Every tunable, ready for `AlbumArtTuning`.
        var json: [String: Double] {
            var o = [String: Double](minimumCapacity: Self.tunables.count)
            for t in Self.tunables { o[t.key] = self[t.key] }
            return o
        }

        /// Keyed access, so the tuning window can drive a slider per
        /// `tunables` entry without a switch of its own.
        subscript(key: String) -> Double {
            get {
                switch key {
                case "cols": return cols
                case "rows": return rows
                case "blurR": return blurR
                case "sharpen": return sharpen
                case "loPct": return loPct
                case "hiPct": return hiPct
                case "gamma": return gamma
                case "floor": return floor
                case "ceil": return ceil
                case "satToe": return satToe
                case "satKneeMin": return satKneeMin
                case "satKneePct": return satKneePct
                case "satPow": return satPow
                case "satMax": return satMax
                case "chromaDarkToe": return chromaDarkToe
                case "chromaDarkKnee": return chromaDarkKnee
                case "lumFloor": return lumFloor
                case "lumPeak": return lumPeak
                case "lumPow": return lumPow
                case "hueLumaFloor": return hueLumaFloor
                case "vKnee": return vKnee
                case "peakLuma": return peakLuma
                case "chClip": return chClip
                case "quant": return quant
                default: return 0
                }
            }
            set {
                switch key {
                case "cols": cols = newValue
                case "rows": rows = newValue
                case "blurR": blurR = newValue
                case "sharpen": sharpen = newValue
                case "loPct": loPct = newValue
                case "hiPct": hiPct = newValue
                case "gamma": gamma = newValue
                case "floor": floor = newValue
                case "ceil": ceil = newValue
                case "satToe": satToe = newValue
                case "satKneeMin": satKneeMin = newValue
                case "satKneePct": satKneePct = newValue
                case "satPow": satPow = newValue
                case "satMax": satMax = newValue
                case "chromaDarkToe": chromaDarkToe = newValue
                case "chromaDarkKnee": chromaDarkKnee = newValue
                case "lumFloor": lumFloor = newValue
                case "lumPeak": lumPeak = newValue
                case "lumPow": lumPow = newValue
                case "hueLumaFloor": hueLumaFloor = newValue
                case "vKnee": vKnee = newValue
                case "peakLuma": peakLuma = newValue
                case "chClip": chClip = newValue
                case "quant": quant = newValue
                default: break
                }
            }
        }

        /// Slider descriptors, in the order the tuning window should show them.
        static let tunables: [AlbumArtTunable] = [
            AlbumArtTunable("cols", "columns", 8, 120, group: "Size"),
            AlbumArtTunable("rows", "rows", 8, 80, group: "Size"),

            AlbumArtTunable("blurR", "blur radius", 1, 32, group: "Dither"),
            AlbumArtTunable("sharpen", "unsharp", 0, 2, group: "Dither"),
            AlbumArtTunable("loPct", "black point %", 0, 40, group: "Dither"),
            AlbumArtTunable("hiPct", "white point %", 60, 100, group: "Dither"),
            AlbumArtTunable("gamma", "gamma", 0.2, 5, group: "Dither"),
            AlbumArtTunable("floor", "ink floor", 0, 0.5, group: "Dither"),
            AlbumArtTunable("ceil", "ink ceiling", 0.5, 1, group: "Dither"),

            AlbumArtTunable("satToe", "sat toe", 0, 0.3, group: "Colour"),
            AlbumArtTunable("satKneeMin", "sat knee floor", 0, 1, group: "Colour"),
            AlbumArtTunable("satKneePct", "sat knee %", 50, 100, group: "Colour"),
            AlbumArtTunable("satPow", "sat curve", 0.2, 4, group: "Colour"),
            AlbumArtTunable("satMax", "sat max", 0, 1, group: "Colour"),
            AlbumArtTunable("chromaDarkToe", "dark toe", 0, 0.5, group: "Colour"),
            AlbumArtTunable("chromaDarkKnee", "dark knee", 0, 1, group: "Colour"),

            AlbumArtTunable("lumFloor", "luma floor", 0, 1, group: "Luma"),
            AlbumArtTunable("lumPeak", "luma peak", 0, 1, group: "Luma"),
            AlbumArtTunable("lumPow", "luma curve", 0.1, 3, group: "Luma"),
            AlbumArtTunable("hueLumaFloor", "hue luma floor", 0.05, 1, group: "Luma"),
            AlbumArtTunable("vKnee", "value knee", 0.1, 1, group: "Luma"),
            AlbumArtTunable("peakLuma", "peak luma", 60, 255, group: "Luma"),
            AlbumArtTunable("chClip", "channel clip", 1, 255, group: "Luma"),
            AlbumArtTunable("quant", "quantise", 1, 16, group: "Luma"),
        ]

        // --- integer views --------------------------------------------------
        // The upper clamps are not taste, they are ceilings: `dotColours`
        // supersamples SUPER-x, so cols alone sizes a cols*12 x rows*24 buffer.

        var colCount: Int { Self.asInt(cols, 8, 256) }
        var rowCount: Int { Self.asInt(rows, 8, 256) }
        var quantStep: Int { Self.asInt(quant, 1, 64) }
        var channelClip: Int { Self.asInt(chClip, 1, 255) }

        /// Dot grid: 2 dots per cell across, 4 down.
        var dotW: Int { colCount * 2 }      // 92 at defaults
        var dotH: Int { rowCount * 4 }      // 92 at defaults

        /// Round-and-clamp. NaN cannot reach `Int()` — that traps.
        private static func asInt(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
            guard v.isFinite else { return lo }
            if v <= Double(lo) { return lo }
            if v >= Double(hi) { return hi }
            return Int(v.rounded())
        }
    }

    // --- fixed structure (not tunable) --------------------------------------

    static let SUPER = 6                    // source px per dot edge before linear-light averaging

    /// Ramp auto-scale convergence (braille.py: 8 iterations, 0.8 tolerance, 2.4 cap, 0.85 damping).
    static let SCALE_ITERATIONS = 8
    static let SCALE_TOLERANCE: Double = 0.8
    static let SCALE_CAP: Double = 2.4
    static let SCALE_DAMPING: Double = 0.85

    // --- panel metrics (Apple Braille -> SF Mono grid fix, from the font files) ---
    static let METRIC_FONT_SIZE: Double = 19.6992
    static let METRIC_LETTER_SPACING: Double = -4.19377
    static let METRIC_LINE_HEIGHT: Double = 18.8623
    static let METRIC_BASE_FONT_SIZE: Double = 15.0

    // MARK: - Public API

    /// Render `image` to the same dictionary that `braille.py --json` prints.
    /// Keys: style, cols, rows, ink, chars, colors, metrics.
    static func render(_ image: CGImage, params p: Params = Params()) -> [String: Any]? {
        guard let src = decode(image) else { return nil }

        let cols = p.colCount, rows = p.rowCount
        let dw = p.dotW, dh = p.dotH

        let bits = dither(src, p)
        let dots = dotColours(src, p)

        // ---- one linear-light colour per CELL, from the inked dots ----------
        var cells = [Cell](repeating: Cell(), count: rows * cols)
        var lums: [Double] = []
        lums.reserveCapacity(rows * cols)

        for cr in 0..<rows {
            for cc in 0..<cols {
                var r = 0.0, g = 0.0, b = 0.0
                var ar = 0.0, ag = 0.0, ab = 0.0
                var n = 0
                for dr in 0..<4 {
                    for dc in 0..<2 {
                        let di = ((cr * 4 + dr) * dw + (cc * 2 + dc)) * 3
                        let pr = dots[di], pg = dots[di + 1], pb = dots[di + 2]
                        ar += pr; ag += pg; ab += pb
                        if bits[(cr * 4 + dr) * dw + (cc * 2 + dc)] != 0 {
                            r += pr; g += pg; b += pb; n += 1
                        }
                    }
                }
                ar /= 8.0; ag /= 8.0; ab /= 8.0
                let inked = n > 0
                if inked {
                    r /= Double(n); g /= Double(n); b /= Double(n)
                } else {
                    // Renders nothing; keep a colour anyway so runs can merge.
                    r = ar; g = ag; b = ab
                }
                // Luminance from the INKED dots -- a dot is a piece of light, so the
                // shadow the cell declined to draw must not drag its level down.
                let y = linToSRGB(0.2126 * r + 0.7152 * g + 0.0722 * b)
                // Hue/sat from a blend toward the whole region, weighted by how many
                // dots actually voted: one lit dot is a noisy colour sample.
                let a = Double(n) / (Double(n) + 2.0)
                let cr_ = a * r + (1 - a) * ar
                let cg_ = a * g + (1 - a) * ag
                let cb_ = a * b + (1 - a) * ab
                // V comes back too: it gates the chroma. Saturation is a ratio and
                // survives all the way to black, where it is only noise.
                let hsv = rgbToHSV(linToSRGB(cr_), linToSRGB(cg_), linToSRGB(cb_))
                cells[cr * cols + cc] = Cell(h: hsv.0, s: hsv.1, vs: hsv.2, y: y, inked: inked)
                if inked { lums.append(y) }
            }
        }

        let ylo = pct(lums, 2.0)
        let yhi = pct(lums, 99.0)
        let yspan = max(1e-6, yhi - ylo)

        let dknee = max(1e-6, p.chromaDarkKnee - p.chromaDarkToe)

        // ---- where the chroma cap lands, per cover --------------------------
        // The quantile is taken on saturation ALREADY multiplied by the dark gate,
        // or it would be set by the very noise the gate exists to throw away.
        var eff: [Double] = []
        eff.reserveCapacity(cells.count)
        for c in cells where c.inked {
            eff.append(c.s * clamp01((c.vs - p.chromaDarkToe) / dknee))
        }
        let satKnee = eff.isEmpty ? p.satKneeMin
                                  : max(p.satKneeMin, pct(eff, p.satKneePct))
        let knee = max(1e-6, satKnee - p.satToe)

        // ---- converge the ramp on peakLuma ----------------------------------
        var scale = 1.0
        for _ in 0..<SCALE_ITERATIONS {
            let peak = renderPass(cells, scale, ylo, yspan, dknee, knee, p).peak
            if abs(peak - p.peakLuma) < SCALE_TOLERANCE { break }
            // A cover whose brightest cells are all deep hues can never reach
            // peakLuma (pure red tops out at 54/255); cap the chase so it does
            // not run away and bleach every near-neutral cell to white.
            scale = min(SCALE_CAP, scale * pow(p.peakLuma / max(1.0, peak), SCALE_DAMPING))
        }
        let grid = renderPass(cells, scale, ylo, yspan, dknee, knee, p).grid

        // ---- braille codepoints ---------------------------------------------
        var chars: [String] = []
        chars.reserveCapacity(rows)
        for cr in 0..<rows {
            var line = String.UnicodeScalarView()
            for cc in 0..<cols {
                var v = 0
                for dr in 0..<4 {
                    for dc in 0..<2 where bits[(cr * 4 + dr) * dw + (cc * 2 + dc)] != 0 {
                        v |= 1 << bitFor(dc, dr)
                    }
                }
                line.append(Unicode.Scalar(UInt32(0x2800 + v))!)
            }
            chars.append(String(line))
        }

        // ---- colours as hex --------------------------------------------------
        var colors: [[String]] = []
        colors.reserveCapacity(rows)
        for cr in 0..<rows {
            var row: [String] = []
            row.reserveCapacity(cols)
            for cc in 0..<cols {
                let i = (cr * cols + cc) * 3
                row.append(String(format: "#%02X%02X%02X", grid[i], grid[i + 1], grid[i + 2]))
            }
            colors.append(row)
        }

        var inkCount = 0
        for b in bits where b != 0 { inkCount += 1 }
        let ink = (Double(inkCount) / Double(dw * dh) * 10000.0).rounded() / 10000.0

        return [
            "style": "braille",
            "cols": cols,
            "rows": rows,
            "ink": ink,
            "chars": chars,
            "colors": colors,
            "metrics": [
                "fontSize": METRIC_FONT_SIZE,
                "letterSpacing": METRIC_LETTER_SPACING,
                "lineHeight": METRIC_LINE_HEIGHT,
                "baseFontSize": METRIC_BASE_FONT_SIZE,
            ],
        ]
    }

    // MARK: - Cell record

    private struct Cell {
        var h: Double = 0
        var s: Double = 0
        var vs: Double = 0
        var y: Double = 0
        var inked: Bool = false
    }

    // MARK: - Tone: dither

    /// The dotW x dotH ink bitmap (1 byte per dot, 0/1).
    private static func dither(_ src: Bitmap, _ p: Params) -> [UInt8] {
        let w = p.dotW, h = p.dotH
        let small = resample(src, w, h)

        var base = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 3
            base[i] = (0.2126 * Double(small.px[p])
                     + 0.7152 * Double(small.px[p + 1])
                     + 0.0722 * Double(small.px[p + 2])) / 255.0
        }

        let low = boxBlur(base, w, h, p.blurR)
        var sharp = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { sharp[i] = base[i] + p.sharpen * (base[i] - low[i]) }

        let lo = pct(sharp, p.loPct)
        let hi = pct(sharp, p.hiPct)
        let span = max(1e-6, hi - lo)

        var grid = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            grid[i] = p.floor + pow(clamp01((sharp[i] - lo) / span), p.gamma) * (p.ceil - p.floor)
        }

        // Serpentine Floyd-Steinberg.
        var bits = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let fwd = (y % 2 == 0)
            let xs: StrideThrough<Int> = fwd ? stride(from: 0, through: w - 1, by: 1)
                                             : stride(from: w - 1, through: 0, by: -1)
            for x in xs {
                let old = grid[y * w + x]
                let new: Double = old >= 0.5 ? 1.0 : 0.0
                bits[y * w + x] = UInt8(new)
                let err = old - new
                let nx = fwd ? 1 : -1
                let taps: [(Int, Int, Double)] = [(nx, 0, 7.0 / 16.0), (-nx, 1, 3.0 / 16.0),
                                                  (0, 1, 5.0 / 16.0), (nx, 1, 1.0 / 16.0)]
                for (dx, dy, f) in taps {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0 && xx < w && yy >= 0 && yy < h {
                        grid[yy * w + xx] += err * f
                    }
                }
            }
        }
        return bits
    }

    /// Separable box blur, run 3x to approximate a gaussian.
    private static func boxBlur(_ g: [Double], _ w: Int, _ h: Int, _ radius: Double) -> [Double] {
        // A radius beyond the grid is the same blur as one exactly the grid's
        // size; bounding it here also keeps `x + r` from overflowing.
        let r = max(1, pyRoundToInt(min(radius, Double(max(w, h)))))
        var cur = g
        var tmp = [Double](repeating: 0, count: w * h)
        var nxt = [Double](repeating: 0, count: w * h)
        for _ in 0..<3 {
            for y in 0..<h {
                let base = y * w
                for x in 0..<w {
                    let a = max(0, x - r), b = min(w - 1, x + r)
                    var s = 0.0
                    for i in a...b { s += cur[base + i] }
                    tmp[base + x] = s / Double(b - a + 1)
                }
            }
            for x in 0..<w {
                for y in 0..<h {
                    let a = max(0, y - r), b = min(h - 1, y + r)
                    var s = 0.0
                    for i in a...b { s += tmp[i * w + x] }
                    nxt[y * w + x] = s / Double(b - a + 1)
                }
            }
            swap(&cur, &nxt)
        }
        return cur
    }

    // MARK: - Colour: per-dot linear light

    /// dotW x dotH grid of linear-light (r,g,b), box-averaged from a SUPER-x
    /// supersample. Returned flat, 3 doubles per dot.
    private static func dotColours(_ src: Bitmap, _ p: Params) -> [Double] {
        let n = SUPER
        let dw = p.dotW, dh = p.dotH
        let big = resample(src, dw * n, dh * n)
        let inv = 1.0 / Double(n * n)
        var out = [Double](repeating: 0, count: dw * dh * 3)
        let lut = s2l
        let rowStride = big.w * 3
        big.px.withUnsafeBufferPointer { px in
            for dy in 0..<dh {
                let y0 = dy * n
                for dx in 0..<dw {
                    let x0 = dx * n
                    var r = 0.0, g = 0.0, b = 0.0
                    for yy in y0..<(y0 + n) {
                        var p = yy * rowStride + x0 * 3
                        for _ in 0..<n {
                            r += lut[Int(px[p])]
                            g += lut[Int(px[p + 1])]
                            b += lut[Int(px[p + 2])]
                            p += 3
                        }
                    }
                    let o = (dy * dw + dx) * 3
                    out[o] = r * inv
                    out[o + 1] = g * inv
                    out[o + 2] = b * inv
                }
            }
        }
        return out
    }

    // MARK: - Colour: the per-cell solve

    /// Build every cell's RGB at a given luma-ramp scale; report the 99.5th-pct luma.
    private static func renderPass(_ cells: [Cell], _ scale: Double,
                                   _ ylo: Double, _ yspan: Double,
                                   _ dknee: Double, _ knee: Double,
                                   _ p: Params) -> (grid: [Int], peak: Double) {
        let n = p.rowCount * p.colCount
        let clip = p.channelClip, quant = p.quantStep
        var grid = [Int](repeating: 0, count: n * 3)
        var peaks: [Double] = []
        peaks.reserveCapacity(cells.count)

        for i in 0..<n {
            let c = cells[i]
            // --- chroma: toe, dark-gate, then a CONVEX lift pinned at the peak.
            //     The gate discounts a near-black cell's hue, which is JPEG
            //     noise, not colour.
            let gate = clamp01((c.vs - p.chromaDarkToe) / dknee)
            let u = clamp01((c.s - p.satToe) / knee) * gate
            let sat = p.satMax * pow(u, p.satPow)
            // --- luma: the ramp is a target BRIGHTNESS, not an HSV V.
            let t = pow(clamp01((c.y - ylo) / yspan), p.lumPow)
            let target = (p.lumFloor + t * (p.lumPeak - p.lumFloor)) * scale
            // Solve v for that luma; chroma rides along as a ratio, so saturating
            // a cell no longer darkens it.
            let f1 = hsvToRGB(c.h, sat, 1.0)
            let l1 = 0.2126 * f1.0 + 0.7152 * f1.1 + 0.0722 * f1.2
            let v = softKnee(target / max(p.hueLumaFloor, l1), p.vKnee)
            let f = hsvToRGB(c.h, sat, v)

            var rgb = (min(clip, pyRoundToInt(f.0 * 255)),
                       min(clip, pyRoundToInt(f.1 * 255)),
                       min(clip, pyRoundToInt(f.2 * 255)))
            rgb = (min(255, (rgb.0 / quant) * quant + quant / 2),
                   min(255, (rgb.1 / quant) * quant + quant / 2),
                   min(255, (rgb.2 / quant) * quant + quant / 2))
            grid[i * 3] = rgb.0
            grid[i * 3 + 1] = rgb.1
            grid[i * 3 + 2] = rgb.2
            if c.inked {
                peaks.append(0.2126 * Double(rgb.0) + 0.7152 * Double(rgb.1) + 0.0722 * Double(rgb.2))
            }
        }
        return (grid, pct(peaks, 99.5))
    }

    // MARK: - Small numerics

    /// Unicode braille dot bit order for cell column c (0..1), row r (0..3).
    private static func bitFor(_ c: Int, _ r: Int) -> Int {
        return r == 3 ? (6 + c) : (c * 3 + r)
    }

    private static func clamp01(_ v: Double) -> Double {
        return v < 0 ? 0.0 : (v > 1 ? 1.0 : v)
    }

    /// Clip to 1.0 asymptotically instead of hard, so a brighter cell still
    /// renders brighter far past the joint.
    private static func softKnee(_ x: Double, _ k: Double) -> Double {
        if x < 0.0 { return 0.0 }
        if x <= k { return x }
        return k + (1.0 - k) * (1.0 - exp(-(x - k) / (1.0 - k)))
    }

    /// CPython's `int(round(x))`: round half to even. Non-finite or out-of-
    /// range input saturates instead of trapping (`Int(Double)` is fatal
    /// past Int.max; every caller bounds its argument, this is the backstop).
    private static func pyRoundToInt(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        let r = x.rounded(.toNearestOrEven)
        if r >= 9.2e18 { return Int.max }
        if r <= -9.2e18 { return Int.min }
        return Int(r)
    }

    /// CPython's `x % 1.0`: the result takes the sign of the divisor.
    private static func pyMod1(_ x: Double) -> Double {
        var r = x.truncatingRemainder(dividingBy: 1.0)
        if r < 0 { r += 1.0 }
        return r
    }

    /// Nearest-rank percentile, matching braille.py's `pct()`.
    private static func pct(_ vals: [Double], _ p: Double) -> Double {
        if vals.isEmpty { return 0.0 }
        let s = vals.sorted()
        let q = min(max(p, 0.0), 100.0)     // a percentile is 0..100 by definition
        var i = pyRoundToInt(q / 100.0 * Double(s.count - 1))
        if i < 0 { i = 0 }
        if i > s.count - 1 { i = s.count - 1 }
        return s[i]
    }

    /// sRGB 0..255 -> linear light, as a 256-entry LUT.
    private static let s2l: [Double] = (0..<256).map { c -> Double in
        let v = Double(c) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linToSRGB(_ value: Double) -> Double {
        let v = value < 0 ? 0.0 : (value > 1 ? 1.0 : value)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// Python `colorsys.rgb_to_hsv`.
    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let v = maxc
        if minc == maxc { return (0.0, 0.0, v) }
        let rangec = maxc - minc
        let s = rangec / maxc
        let rc = (maxc - r) / rangec
        let gc = (maxc - g) / rangec
        let bc = (maxc - b) / rangec
        var h: Double
        if r == maxc { h = bc - gc }
        else if g == maxc { h = 2.0 + rc - bc }
        else { h = 4.0 + gc - rc }
        h = pyMod1(h / 6.0)
        return (h, s, v)
    }

    /// Python `colorsys.hsv_to_rgb`.
    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        if s == 0.0 { return (v, v, v) }
        var i = Int(h * 6.0)
        let f = (h * 6.0) - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        i = ((i % 6) + 6) % 6
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - Bitmap decode

    /// 8-bit RGB, 3 bytes per pixel, top-down rows.
    private struct Bitmap {
        var w: Int
        var h: Int
        var px: [UInt8]
    }

    private static func decode(_ image: CGImage) -> Bitmap? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w < 1 << 15, h < 1 << 15 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = rgbx.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard drew else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 3)
        rgbx.withUnsafeBufferPointer { s in
            px.withUnsafeMutableBufferPointer { d in
                for i in 0..<(w * h) {
                    d[i * 3] = s[i * 4]
                    d[i * 3 + 1] = s[i * 4 + 1]
                    d[i * 3 + 2] = s[i * 4 + 2]
                }
            }
        }
        return Bitmap(w: w, h: h, px: px)
    }

    // MARK: - PIL-exact LANCZOS resampler
    //
    // Pillow's ImagingResample for 8-bit images: per-axis coefficients normalised
    // into 22-bit fixed point, a horizontal pass whose result is CLIPPED BACK TO 8
    // BITS, then a vertical pass over that intermediate. CoreGraphics' own
    // interpolation is a different kernel entirely and drifts the dither pattern,
    // so the kernel is implemented here rather than delegated.

    private static let PRECISION_BITS = 22
    private static let LANCZOS_SUPPORT: Double = 3.0

    private struct Coeffs {
        var ksize: Int
        var bounds: [Int]   // 2 per output sample: min, count
        var kk: [Int32]     // outSize * ksize fixed-point weights
    }

    private static func sincFilter(_ x: Double) -> Double {
        if x == 0.0 { return 1.0 }
        let t = x * Double.pi
        return sin(t) / t
    }

    private static func lanczosFilter(_ x: Double) -> Double {
        if x >= -LANCZOS_SUPPORT && x < LANCZOS_SUPPORT {
            return sincFilter(x) * sincFilter(x / LANCZOS_SUPPORT)
        }
        return 0.0
    }

    private static func precomputeCoeffs(inSize: Int, outSize: Int) -> Coeffs {
        let scale = Double(inSize) / Double(outSize)
        let filterscale = max(1.0, scale)
        let support = LANCZOS_SUPPORT * filterscale
        let ksize = Int(ceil(support)) * 2 + 1
        var bounds = [Int](repeating: 0, count: outSize * 2)
        var kk = [Double](repeating: 0, count: outSize * ksize)
        let ss = 1.0 / filterscale

        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            var ww = 0.0
            var xmin = Int(center - support + 0.5)   // C truncation toward zero
            if xmin < 0 { xmin = 0 }
            var xmax = Int(center + support + 0.5)
            if xmax > inSize { xmax = inSize }
            xmax -= xmin
            let kb = xx * ksize
            for x in 0..<xmax {
                let w = lanczosFilter((Double(x + xmin) - center + 0.5) * ss)
                kk[kb + x] = w
                ww += w
            }
            if ww != 0.0 {
                for x in 0..<xmax { kk[kb + x] /= ww }
            }
            bounds[xx * 2] = xmin
            bounds[xx * 2 + 1] = xmax
        }

        // Pillow's normalize_coeffs_8bpc.
        let one = Double(1 << PRECISION_BITS)
        var k32 = [Int32](repeating: 0, count: kk.count)
        for i in 0..<kk.count {
            let v = kk[i]
            k32[i] = Int32(v < 0 ? (-0.5 + v * one) : (0.5 + v * one))
        }
        return Coeffs(ksize: ksize, bounds: bounds, kk: k32)
    }

    private static func clip8(_ acc: Int) -> UInt8 {
        let v = Int(Int32(truncatingIfNeeded: acc)) >> PRECISION_BITS
        if v < 0 { return 0 }
        if v > 255 { return 255 }
        return UInt8(v)
    }

    private static func resample(_ src: Bitmap, _ xsize: Int, _ ysize: Int) -> Bitmap {
        let w = src.w, h = src.h
        if xsize == w && ysize == h { return src }

        let ch = precomputeCoeffs(inSize: w, outSize: xsize)
        let cv = precomputeCoeffs(inSize: h, outSize: ysize)
        var boundsV = cv.bounds
        let yboxFirst = boundsV[0]
        let yboxLast = boundsV[ysize * 2 - 2] + boundsV[ysize * 2 - 1]

        let needH = (xsize != w)
        let needV = (ysize != h)

        var cur = src.px
        var curW = w
        var curH = h
        let half = 1 << (PRECISION_BITS - 1)

        if needH {
            for i in 0..<ysize { boundsV[i * 2] -= yboxFirst }
            let th = yboxLast - yboxFirst
            var tmp = [UInt8](repeating: 0, count: xsize * th * 3)
            cur.withUnsafeBufferPointer { sp in
                tmp.withUnsafeMutableBufferPointer { dp in
                    ch.kk.withUnsafeBufferPointer { kp in
                        ch.bounds.withUnsafeBufferPointer { bp in
                            for yy in 0..<th {
                                let rowBase = (yy + yboxFirst) * curW * 3
                                let outBase = yy * xsize * 3
                                for xx in 0..<xsize {
                                    let xmin = bp[xx * 2], xmax = bp[xx * 2 + 1]
                                    let kb = xx * ch.ksize
                                    var a0 = half, a1 = half, a2 = half
                                    var p = rowBase + xmin * 3
                                    for x in 0..<xmax {
                                        let k = Int(kp[kb + x])
                                        a0 += Int(sp[p]) * k
                                        a1 += Int(sp[p + 1]) * k
                                        a2 += Int(sp[p + 2]) * k
                                        p += 3
                                    }
                                    let o = outBase + xx * 3
                                    dp[o] = clip8(a0)
                                    dp[o + 1] = clip8(a1)
                                    dp[o + 2] = clip8(a2)
                                }
                            }
                        }
                    }
                }
            }
            cur = tmp
            curW = xsize
            curH = th
        }

        if needV {
            var out = [UInt8](repeating: 0, count: curW * ysize * 3)
            cur.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBufferPointer { dp in
                    cv.kk.withUnsafeBufferPointer { kp in
                        for yy in 0..<ysize {
                            let ymin = boundsV[yy * 2], ymax = boundsV[yy * 2 + 1]
                            let kb = yy * cv.ksize
                            let outBase = yy * curW * 3
                            for xx in 0..<curW {
                                var a0 = half, a1 = half, a2 = half
                                var p = ymin * curW * 3 + xx * 3
                                for y in 0..<ymax {
                                    let k = Int(kp[kb + y])
                                    a0 += Int(sp[p]) * k
                                    a1 += Int(sp[p + 1]) * k
                                    a2 += Int(sp[p + 2]) * k
                                    p += curW * 3
                                }
                                let o = outBase + xx * 3
                                dp[o] = clip8(a0)
                                dp[o + 1] = clip8(a1)
                                dp[o + 2] = clip8(a2)
                            }
                        }
                    }
                }
            }
            cur = out
            curH = ysize
        }

        return Bitmap(w: curW, h: curH, px: cur)
    }
}
