//
//  AlbumArtRamp.swift
//  CodeSaver
//
//  Native port of feeds/albumart/ramp.py — album art -> COLOUR luminance-ramp ASCII.
//
//  Three things are decided by measurement, not by convention:
//
//  1. A 19-STEP RAMP, ORDERED BY MEASURED INK.  Every glyph was rendered in SF Mono at
//     the real cell size (15px type in a 9x18px cell, 8x supersampled) and its coverage
//     counted; the ramp is strictly increasing in that number.  This is not the folklore
//     ramp: in SF Mono '#'=20.5% > '%'=20.0% > '@'=19.8%.  Glyphs also have to sit still,
//     so only near-cy-0.50, full-advance glyphs survive.  The table below is verbatim from
//     ramp.py's `--measure` output; regenerate there, paste here.
//
//  2. THE TOP OF THE RAMP IS 'Q' AT 24.05%, BECAUSE NO LETTER IN THIS FONT GOES ABOVE IT.
//     Shade blocks measure in monotonically above the letters but were removed on user
//     feedback — they read as filled rectangles rather than as specular highlights.
//
//  3. GLYPH-INK AND COLOUR ARE MARRIED, NOT STACKED.  Naively you get double darkening:
//     a mid cell picks a mid glyph (~15% ink) AND a mid colour, and what the eye integrates
//     is the PRODUCT, so the picture collapses into the floor.  Here the glyph is chosen
//     from tone, its measured coverage a_i is looked up, and the colour is DIVIDED by that
//     coverage — (aRef/a_i)^k — so a sparse glyph is handed a brighter colour and a dense
//     one a dimmer colour, and the two multiply back onto one smooth tonal curve.
//
//     Colour itself is the artwork's own linear-light cell mean.  Chroma is carried as a
//     luma-normalised ratio, so saturation and brightness stay independent: `sat` opens the
//     ratio around the achromatic axis without moving luma at all, and the tone curve then
//     places that luma under a `peak` ceiling of ~175/255.  The floor stays at true black —
//     p2 clips to the space glyph — so the art dissolves into the panel instead of ending
//     on a visible dark rectangle.
//
//  Every tunable below carries ramp.py's value as its `Params` DEFAULT, so a
//  default-constructed render stays byte-identical to ramp.py.  Tuning is now a value
//  passed in, not an edit: `Params` is a plain value type threaded through every stage,
//  which is what lets the app's tuning window drive a live preview while the daemon
//  renders concurrently with different values.  Nothing here is mutable global state.
//

import Foundation
import CoreGraphics

enum AlbumArtRamp {

    // MARK: - Tunable parameters

    /// Everything the tuning window can move.  Defaults are ramp.py's constants verbatim.
    ///
    /// `cols`/`rows` are Doubles here only so the UI can bind every knob through one
    /// slider path; they are rounded and floored to a usable grid before use.
    struct Params: Equatable {
        /// 44 cols at the 2:1 cell aspect (9x18px) renders a square cover square.
        var cols: Double = 44
        var rows: Double = 22

        /// Tone curve.  The linear-light downsample lifts everything, so it is paired
        /// with a gamma ABOVE 1 to push the bulk back down.  The cell-grid unsharp is
        /// opened wide (0.75) so hairline graphics — a 6px white rule averaged into a
        /// 27px cell — still separate from their background.
        var gamma: Double = 1.15
        var loPct: Double = 2.0
        var hiPct: Double = 99.5
        var sharp: Double = 0.75

        /// Colour management.
        var peak: Double = 175.0    // ceiling on emitted colour luma (0..255) — nothing glares
        var aExp: Double = 1.00     // tone exponent applied to colour before ink compensation
        var inkK: Double = 0.42     // ink-compensation strength (see note 3); 0 = naive stack
        var sat: Double  = 1.30     // chroma gain about the achromatic axis (luma-preserving)

        init() {}

        /// Missing, non-finite, or unrecognised keys keep their default; present
        /// ones are clamped to their slider's range, because the file is
        /// hand-editable and `loPct`/`hiPct` reach `Int()` in `percentile` —
        /// past Int.max that is a fatal error, not a bad render.
        init(json: [String: Double]) {
            for t in Self.tunables {
                if let v = json[t.key], v.isFinite {
                    self[t.key] = Swift.min(Swift.max(v, t.min), t.max)
                }
            }
        }

        var json: [String: Double] {
            var o: [String: Double] = [:]
            for t in Self.tunables { o[t.key] = self[t.key] }
            return o
        }

        /// Keyed access by the same names the JSON uses.  An unknown key reads 0 and
        /// swallows writes, so a stale tuning file can never trap the renderer.
        subscript(key: String) -> Double {
            get {
                switch key {
                case "cols":  return cols
                case "rows":  return rows
                case "gamma": return gamma
                case "loPct": return loPct
                case "hiPct": return hiPct
                case "sharp": return sharp
                case "peak":  return peak
                case "aExp":  return aExp
                case "inkK":  return inkK
                case "sat":   return sat
                default:      return 0
                }
            }
            set {
                switch key {
                case "cols":  cols  = newValue
                case "rows":  rows  = newValue
                case "gamma": gamma = newValue
                case "loPct": loPct = newValue
                case "hiPct": hiPct = newValue
                case "sharp": sharp = newValue
                case "peak":  peak  = newValue
                case "aExp":  aExp  = newValue
                case "inkK":  inkK  = newValue
                case "sat":   sat   = newValue
                default:      break
                }
            }
        }

        /// Slider descriptors for the tuning window — the renderer is the single source
        /// of truth for what exists, what it is called, and how far it may travel.
        static let tunables: [AlbumArtTunable] = [
            AlbumArtTunable("cols",  "columns",       8,  120, group: "Size"),
            AlbumArtTunable("rows",  "rows",          8,   80, group: "Size"),

            AlbumArtTunable("gamma", "gamma",       0.3,  3.0, group: "Tone"),
            AlbumArtTunable("loPct", "black point", 0.0, 20.0, group: "Tone"),
            AlbumArtTunable("hiPct", "white point", 80.0, 100.0, group: "Tone"),
            AlbumArtTunable("sharp", "unsharp",     0.0,  3.0, group: "Tone"),

            AlbumArtTunable("peak",  "peak luma",  60.0, 255.0, group: "Colour"),
            AlbumArtTunable("aExp",  "tone exponent", 0.3, 3.0, group: "Colour"),
            AlbumArtTunable("inkK",  "ink comp",    0.0,  1.5, group: "Colour"),
            AlbumArtTunable("sat",   "saturation",  0.0,  3.0, group: "Colour"),
        ]

        /// The grid, as the sampler needs it: whole cells, never small enough to make
        /// the percentile/unsharp stages degenerate.
        var colCount: Int { Self.gridCount(cols) }
        var rowCount: Int { Self.gridCount(rows) }

        private static func gridCount(_ v: Double) -> Int {
            guard v.isFinite else { return minGrid }
            let r = v.rounded()
            if r <= Double(minGrid) { return minGrid }
            if r >= Double(maxGrid) { return maxGrid }
            return Int(r)
        }

        private static let minGrid = 8
        private static let maxGrid = 4096
    }

    // MARK: - Fixed constants (measured, not tuned)

    /// (glyph, measured SF Mono ink coverage %) — strictly increasing.
    /// Regenerate with `ramp.py --measure`.
    static let ramp: [(glyph: Character, ink: Double)] = [
        (" ",  0.00), ("·",  2.30), ("-",  5.53), (":",  6.90), ("!",  8.02),
        ("/",  9.48), ("+", 10.25), ("=", 11.56), ("x", 12.73), ("*", 13.89),
        ("o", 15.36), ("X", 17.36), ("C", 18.21), ("%", 19.99), ("#", 20.52),
        ("D", 21.93), ("W", 22.42), ("0", 23.33), ("Q", 24.05),
    ]

    static let aRef = 24.05     // pivot: the densest plain glyph.  comp == 1 there.

    /// Rec.709 luma weights.
    static let wR = 0.2126
    static let wG = 0.7152
    static let wB = 0.0722

    // MARK: - Public API

    /// Renders `image` to the same dictionary shape `ramp.py --json` prints:
    /// `{"style": "ramp", "cols": Int, "rows": Int, "chars": [String], "colors": [[String]]}`
    /// Safe to hand straight to `JSONSerialization`.
    ///
    /// `params` is by-value throughout — concurrent renders with different tunings do
    /// not interact.
    static func render(_ image: CGImage, params: Params = Params()) -> [String: Any]? {
        let cols = params.colCount, rows = params.rowCount
        guard cols > 0, rows > 0,
              let cells = sampleLinearCells(image, params) else { return nil }
        let t = tone(cells, params)
        let (chars, colors) = paint(cells: cells, tone: t, params: params)
        return [
            "style": "ramp",
            "cols": cols,
            "rows": rows,
            "chars": chars,
            "colors": colors,
        ]
    }

    // MARK: - sRGB <-> linear light

    private static func toLinear(_ a: Double) -> Double {
        a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
    }

    private static func toSRGB(_ a: Double) -> Double {
        let c = a < 0.0 ? 0.0 : (a > 1.0 ? 1.0 : a)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// 8-bit sRGB -> linear light, precomputed.  Exact, and it keeps the per-pixel work
    /// on the downsample to a load and an add.
    private static let linearLUT: [Double] = (0..<256).map { toLinear(Double($0) / 255.0) }

    // MARK: - Decode

    /// Draws `image` into a tightly packed 8-bit RGBX sRGB buffer.  Row 0 is the top row.
    ///
    /// The destination is explicitly sRGB, so wide-gamut artwork (Display P3 from the
    /// Music APIs) is colour-managed into the space the ramp's maths assumes.  Alpha is
    /// composited over black rather than discarded, which is what a screensaver panel on a
    /// black background actually shows.  Both cases are moot for real cover art, which is
    /// opaque and untagged/sRGB — and for those this is byte-identical to PIL's decode.
    private static func decodeRGBX8(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w < 1 << 16, h < 1 << 16 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    // MARK: - Downsample

    /// Area-averages each cell in LINEAR light -> `rows * cols * 3` doubles, row-major.
    ///
    /// Averaging in gamma space makes thin bright graphics vanish (a cover's signature
    /// hairline rules stop being recognisable); linear light is the physically correct
    /// downscale and keeps them.  The cell edges are numpy's `(k * n) // steps` integer
    /// partition, so cells differ in size by at most one pixel and tile the source exactly.
    private static func sampleLinearCells(_ image: CGImage, _ params: Params) -> [Double]? {
        guard let (px, w, h) = decodeRGBX8(image) else { return nil }
        let cols = params.colCount, rows = params.rowCount

        var ys = [Int](repeating: 0, count: rows + 1)
        for j in 0...rows { ys[j] = (j * h) / rows }
        var xs = [Int](repeating: 0, count: cols + 1)
        for i in 0...cols { xs[i] = (i * w) / cols }

        var out = [Double](repeating: 0, count: rows * cols * 3)
        px.withUnsafeBufferPointer { p in
            for j in 0..<rows {
                // Degenerate bands appear only when the source is shorter/narrower than the
                // grid; widen to one pixel rather than average an empty slice (numpy: NaN).
                var y0 = ys[j], y1 = ys[j + 1]
                if y1 <= y0 { y0 = min(y0, h - 1); y1 = y0 + 1 }
                for i in 0..<cols {
                    var x0 = xs[i], x1 = xs[i + 1]
                    if x1 <= x0 { x0 = min(x0, w - 1); x1 = x0 + 1 }
                    var sr = 0.0, sg = 0.0, sb = 0.0
                    for y in y0..<y1 {
                        let row = y * w * 4
                        for x in x0..<x1 {
                            let o = row + x * 4
                            sr += linearLUT[Int(p[o])]
                            sg += linearLUT[Int(p[o + 1])]
                            sb += linearLUT[Int(p[o + 2])]
                        }
                    }
                    let n = Double((y1 - y0) * (x1 - x0))
                    let d = (j * cols + i) * 3
                    out[d]     = sr / n
                    out[d + 1] = sg / n
                    out[d + 2] = sb / n
                }
            }
        }
        return out
    }

    // MARK: - Tone

    /// Linear cell RGB -> t in 0..1, the tone every later decision is taken from.
    private static func tone(_ cells: [Double], _ params: Params) -> [Double] {
        let cols = params.colCount, rows = params.rowCount
        var v = [Double](repeating: 0, count: rows * cols)
        for i in 0..<v.count {
            let o = i * 3
            v[i] = toSRGB(cells[o] * wR + cells[o + 1] * wG + cells[o + 2] * wB)
        }
        v = unsharp(v, amount: params.sharp, cols: cols, rows: rows)

        let lo = percentile(v, params.loPct)
        let hi = percentile(v, params.hiPct)
        let span = Swift.max(hi - lo, 1e-6)

        var t = [Double](repeating: 0, count: v.count)
        for i in 0..<v.count {
            var x = (v[i] - lo) / span
            if x < 0 { x = 0 } else if x > 1 { x = 1 }
            t[i] = pow(x, params.gamma)
        }
        return t
    }

    /// Local-contrast boost on the CELL grid — recovers edges the downsample softened.
    /// Edge-replicating 3x3 box blur, summed in the same order numpy's `sum(...)` uses.
    private static func unsharp(_ cells: [Double], amount: Double,
                                cols: Int, rows: Int) -> [Double] {
        guard amount > 0 else { return cells }
        let pw = cols + 2, ph = rows + 2
        var p = [Double](repeating: 0, count: pw * ph)
        for j in 0..<ph {
            let sj = Swift.min(Swift.max(j - 1, 0), rows - 1)
            for i in 0..<pw {
                let si = Swift.min(Swift.max(i - 1, 0), cols - 1)
                p[j * pw + i] = cells[sj * cols + si]
            }
        }
        var out = [Double](repeating: 0, count: cells.count)
        for j in 0..<rows {
            for i in 0..<cols {
                var s = 0.0
                for dj in 0..<3 {
                    let base = (j + dj) * pw + i
                    for di in 0..<3 { s += p[base + di] }
                }
                let c = cells[j * cols + i]
                out[j * cols + i] = c + amount * (c - s / 9.0)
            }
        }
        return out
    }

    /// numpy's default ("linear") percentile, including its two-sided lerp: for a fraction
    /// at or above 0.5 it interpolates down from the upper sample, which keeps the result
    /// bit-identical to `np.percentile` rather than merely close.
    private static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        let n = s.count
        let q = Swift.min(Swift.max(p, 0.0), 100.0)   // 0..100 by definition; keeps Int() in range
        let virtual = (q / 100.0) * Double(n - 1)
        if !(virtual > 0) { return s[0] }
        let prev = Int(virtual.rounded(.down))
        if prev >= n - 1 { return s[n - 1] }
        let g = virtual - Double(prev)
        let lo = s[prev], hi = s[prev + 1]
        let diff = hi - lo
        return g >= 0.5 ? hi - diff * (1.0 - g) : lo + diff * g
    }

    // MARK: - Glyph + colour

    /// Pulls chroma toward the achromatic axis just far enough to fit in sRGB.
    /// Scaling chroma about 1.0 leaves dot(chroma, W709) == 1, so this never moves the
    /// cell's luma — an out-of-gamut colour loses saturation, never brightness.
    private static func gamutFit(_ c: (Double, Double, Double), _ Y: Double) -> (Double, Double, Double) {
        let mx = Swift.max(c.0, Swift.max(c.1, c.2))
        let mn = Swift.min(c.0, Swift.min(c.1, c.2))
        var s = 1.0
        if Y > 1e-9 && mx > 1.0 && mx * Y > 1.0 {
            s = Swift.min(s, (1.0 / Y - 1.0) / (mx - 1.0))
        }
        if mn < 0.0 {
            s = Swift.min(s, 1.0 / (1.0 - mn))
        }
        s = Swift.max(0.0, Swift.min(1.0, s))
        return (1.0 + s * (c.0 - 1.0), 1.0 + s * (c.1 - 1.0), 1.0 + s * (c.2 - 1.0))
    }

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> String {
        var out = "#"
        for v in [r, g, b] {
            let c = v < 0 ? 0 : (v > 255 ? 255 : v)
            out.append(hexDigits[c >> 4])
            out.append(hexDigits[c & 0xF])
        }
        return out
    }

    /// Character from tone, colour from the artwork.
    private static func paint(cells: [Double], tone t: [Double],
                              params: Params) -> ([String], [[String]]) {
        let cols = params.colCount, rows = params.rowCount
        let peak = params.peak, aExp = params.aExp, inkK = params.inkK, sat = params.sat
        let steps = Double(ramp.count - 1)
        var chars: [String] = []
        var colors: [[String]] = []
        chars.reserveCapacity(rows)
        colors.reserveCapacity(rows)

        for j in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            var crow: [String] = []
            crow.reserveCapacity(cols)

            for i in 0..<cols {
                let idx = j * cols + i
                let tv = t[idx]

                // np.rint == round-half-to-even.
                var gi = Int((tv * steps).rounded(.toNearestOrEven))
                if gi < 0 { gi = 0 } else if gi > ramp.count - 1 { gi = ramp.count - 1 }
                let entry = ramp[gi]

                // Colour luma: tone, then divided by the glyph's measured ink coverage.
                let comp = entry.ink > 0 ? pow(aRef / Swift.max(entry.ink, 1e-6), inkK) : 1.0
                let v = Swift.min(peak * pow(tv, aExp) * comp, 255.0)
                let Y = toLinear(v / 255.0)

                let o = idx * 3
                let lr = cells[o], lg = cells[o + 1], lb = cells[o + 2]
                let ySrc = Swift.max(lr * wR + lg * wG + lb * wB, 1e-9)
                let chroma = (1.0 + sat * (lr / ySrc - 1.0),
                              1.0 + sat * (lg / ySrc - 1.0),
                              1.0 + sat * (lb / ySrc - 1.0))
                let fit = gamutFit(chroma, Y)

                let r = Int((toSRGB(fit.0 * Y) * 255.0).rounded(.toNearestOrEven))
                let g = Int((toSRGB(fit.1 * Y) * 255.0).rounded(.toNearestOrEven))
                let b = Int((toSRGB(fit.2 * Y) * 255.0).rounded(.toNearestOrEven))

                line.append(entry.glyph)
                crow.append(hex(r, g, b))
            }
            chars.append(line)
            colors.append(crow)
        }
        return (chars, colors)
    }
}
