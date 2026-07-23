import AppKit

// BoomCore — the two-boom ignition, as a cell simulation.
//
// The grid is the display. Nothing here ever draws between cells: the first
// shockwave pixelates the desktop into cell-sized color blocks (stamping
// spots of real code over it), the second flips the cells to black, and
// glyphs flung by the first front travel *through* the grid — a moving
// character occupies exactly one cell per tick, the cells it crossed cooling
// behind it. The visible wave shapes are entirely emergent from per-cell
// flash-and-decay; no circle, ring, or gradient is ever drawn.
//
// The whole show runs inside the saver process: the igniter helper only
// captures the desktop and records the mouse before macOS's own trigger
// starts the saver. All displays' fields live in one core; the saver's
// views share it and each renders its own display's slice. The seeded PRNG
// keeps snapshot runs reproducible.

// MARK: - Deterministic randomness

public struct BoomRNG {
    public var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func double01() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    public mutating func range(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * double01()
    }

    /// base + Exp(mean), capped — the saver's expTail, seeded.
    public mutating func expTail(base: Double, mean: Double, cap: Double) -> Double {
        min(cap, base - log(max(1e-9, double01())) * mean)
    }
}

/// Stable per-cell noise in [0, 1): hash of (cell, salt), independent of the
/// PRNG stream so it never desynchronizes draw counts across processes.
public func boomCellNoise(_ col: Int, _ row: Int, _ salt: UInt64) -> Double {
    var h = UInt64(bitPattern: Int64(col)) &* 0x9E3779B97F4A7C15
    h ^= UInt64(bitPattern: Int64(row)) &* 0xC2B2AE3D27D4EB4F
    h ^= salt
    h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
    h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
    return Double((h ^ (h >> 31)) >> 11) * (1.0 / 9007199254740992.0)
}

// MARK: - Diagnostics

/// The boom's black box: a timestamped timeline written next to the capture
/// manifest. The unified log is unreadable on some setups (`log show`
/// returns nothing), so the saver records its own ground truth — session
/// load cost, per-display staging, the clock anchor, texture binds, frame
/// averages. One file per process launch, tiny, always on.
public enum BoomDiag {
    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static let t0 = CACurrentMediaTime()

    public static func log(_ msg: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            let dir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/CodeSaver")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // NOT "boom-" prefixed: the igniter's manifest cleanup deletes
            // boom-* on user return and was eating the diagnostics with it.
            let url = dir.appendingPathComponent("saver-diag.log")
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? Data("── \(stamp) pid \(getpid())\n".utf8).write(to: url)
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
        guard let handle else { return }
        handle.write(Data(String(format: "[%9.3f] %@\n",
                                 CACurrentMediaTime() - t0, msg()).utf8))
    }
}

// MARK: - Mapped capture

/// A capture handed over as decoded pixels ("CSRW" v1 — written by the
/// igniter, format documented there): mmap'd rather than read, so "loading"
/// a 15 MB frame is a few page-table entries against the still-warm page
/// cache instead of a JPEG decode. The saver wraps the mapping as a CGImage
/// for colorize/CPU drawing, and the Metal renderer reads the very same
/// pages as a zero-copy texture.
public final class BoomCaptureBuffer {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelOffset: Int
    public let base: UnsafeMutableRawPointer
    public let length: Int

    public var pixels: UnsafeMutableRawPointer { base + pixelOffset }

    private init(width: Int, height: Int, bytesPerRow: Int, pixelOffset: Int,
                 base: UnsafeMutableRawPointer, length: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelOffset = pixelOffset
        self.base = base
        self.length = length
    }

    deinit { munmap(base, length) }

    public static func map(_ url: URL) -> BoomCaptureBuffer? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 32 else { return nil }
        let len = Int(st.st_size)
        // PROT_WRITE + MAP_PRIVATE: Metal's no-copy buffer wants a writable
        // pointer; copy-on-write keeps reads coming straight from the cache.
        guard let base = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0),
              base != MAP_FAILED else { return nil }
        let h = base.assumingMemoryBound(to: UInt32.self)
        let w = Int(h[2]), ht = Int(h[3]), bpr = Int(h[4]), off = Int(h[5])
        guard h[0] == 0x4353_5257, h[1] == 1,
              w > 0, ht > 0, bpr >= w * 4, off >= 32, off + ht * bpr <= len else {
            munmap(base, len)
            return nil
        }
        return BoomCaptureBuffer(width: w, height: ht, bytesPerRow: bpr,
                                 pixelOffset: off, base: base, length: len)
    }

    /// A CGImage view over the mapped pixels — zero-copy; the provider keeps
    /// the mapping alive. (Not cached on the class: image → provider → self
    /// would cycle.)
    public func makeImage() -> CGImage? {
        let ref = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(
            dataInfo: ref.toOpaque(), data: pixels, size: height * bytesPerRow,
            releaseData: { info, _, _ in
                Unmanaged<BoomCaptureBuffer>.fromOpaque(info!).release()
            })
        else {
            ref.release()
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

// MARK: - Grid

/// Cell metrics for one display. MUST mirror CodeSaverView.ensureSetup — the
/// boom's grid is the saver's grid, so the takeover is cell-identical.
public struct BoomGrid {
    public let size: CGSize
    public let fontBase: CGFloat
    public let charW: CGFloat
    public let lineH: CGFloat
    public let leftInset: CGFloat
    public let topInset: CGFloat
    public let cols: Int
    public let rows: Int

    public init(size: CGSize) {
        self.size = size
        let base = min(max(size.width / 125.0, 11.5), 16.5)
        fontBase = base
        let font = NSFont(name: "SFMono-Regular", size: base)
            ?? .monospacedSystemFont(ofSize: base, weight: .regular)
        charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        lineH = ceil(base * 1.55)
        // Lattice-aligned with the saver's typing grid (whose insets are
        // max(18, 1.5%) / max(14, 2%)), but extended past every screen edge:
        // the boom owns the whole display, not the typing safe-area. The
        // first column/row start at or before zero, the last reach past the
        // far edge.
        let insetL = max(18, size.width * 0.015)
        let insetT = max(14, size.height * 0.02)
        leftInset = insetL - ceil(insetL / charW) * charW
        topInset = insetT - ceil(insetT / lineH) * lineH
        cols = Int(ceil((size.width - leftInset) / charW))
        rows = Int(ceil((size.height - topInset) / lineH))
    }

    public init(size: CGSize, fontBase: CGFloat, charW: CGFloat, lineH: CGFloat,
                leftInset: CGFloat, topInset: CGFloat, cols: Int, rows: Int) {
        self.size = size
        self.fontBase = fontBase
        self.charW = charW
        self.lineH = lineH
        self.leftInset = leftInset
        self.topInset = topInset
        self.cols = cols
        self.rows = rows
    }

    public func cellRect(_ col: Int, _ row: Int) -> CGRect {
        CGRect(x: leftInset + CGFloat(col) * charW, y: topInset + CGFloat(row) * lineH,
               width: charW, height: lineH)
    }

    /// Cell containing a point in local (top-left origin) coords, or nil.
    public func cell(at p: CGPoint) -> (col: Int, row: Int)? {
        let c = Int(floor((p.x - leftInset) / charW))
        let r = Int(floor((p.y - topInset) / lineH))
        guard c >= 0, c < cols, r >= 0, r < rows else { return nil }
        return (c, r)
    }

    /// Snaps a point to its cell's top-left corner (clamped into the grid).
    public func snap(_ p: CGPoint) -> CGPoint {
        let c = min(max(Int(((p.x - leftInset) / charW).rounded()), 0), cols - 1)
        let r = min(max(Int(((p.y - topInset) / lineH).rounded()), 0), rows - 1)
        return CGPoint(x: leftInset + CGFloat(c) * charW, y: topInset + CGFloat(r) * lineH)
    }
}

// MARK: - Field (one display's cell buffer)

public final class BoomField {
    public static let stateUntouched: UInt8 = 0  // pre-wave-1: the real desktop
    public static let stateAscii: UInt8 = 1      // asciified desktop
    public static let stateBlack: UInt8 = 2      // wiped
    public static let stateSettled: UInt8 = 3    // a flung glyph came to rest here

    public let grid: BoomGrid
    public let originCG: CGPoint                 // display origin, global CG coords
    /// Per-cell average desktop color, packed 0xRRGGBB — the "pixelation".
    public var color: [UInt32]
    /// ASCII code per cell (0 = none): code spots and settled glyphs.
    public var ascii: [UInt8]
    public var state: [UInt8]
    public var hitTick: [Int32]                  // tick of last state change (flash timing)
    /// Precomputed wave arrival times (sim seconds), jitter baked in.
    var hit1: [Float] = []
    var hit2: [Float] = []

    public init(grid: BoomGrid, originCG: CGPoint, color: [UInt32]) {
        self.grid = grid
        self.originCG = originCG
        let n = grid.cols * grid.rows
        self.color = color.count == n ? color : [UInt32](repeating: 0, count: n)
        self.ascii = [UInt8](repeating: 0, count: n)
        self.state = [UInt8](repeating: 0, count: n)
        self.hitTick = [Int32](repeating: -1, count: n)
    }

    public func index(_ col: Int, _ row: Int) -> Int { row * grid.cols + col }
}

// MARK: - Core

public final class BoomCore {
    public static let tickHz = 60.0

    /// Choreography tempo: >1 stretches the whole show — front sweeps grow
    /// ×tempo, debris slows to match (spawn speeds, drag, and settle
    /// thresholds ÷tempo, which time-stretches the same trajectories) — all
    /// at full tick rate. This is the pacing knob; clock dilation
    /// (CodeSaverView.boomTimeScale) is only for slow-motion inspection,
    /// since it drops the effective motion rate. 2.2 after live review
    /// (1.3, then 30% more twice — "barely time to see the spectacle").
    public static let tempo = 2.2

    // The UNIFIED BOOM (kept after live review): the second front chases the
    // first so closely they read as ONE compound event — pixelate, energize,
    // black in a single pass, the whole wiped interior crackling with surge
    // blips as the ring expands. wave2Base matches wave1's sweep so the
    // chase lag stays constant (~0.34 s) across the whole screen. (The old
    // two-beat show, with its quiet Matrix-space interlude: gapBase 1.15,
    // wave2Base 1.0.)
    public static let gapBase = 0.2
    public static let wave2Base = 0.85

    /// Last-resort code for the spots when no corpus is reachable.
    public static let fallbackCodeLines: [String] = [
        "func animateOneFrame() {",
        "    let t = CACurrentMediaTime()",
        "    advance(by: t - lastWall)",
        "    setNeedsDisplay(bounds)",
        "}",
        "private func detonate(start: Double? = nil) {",
        "    intro = .boom",
        "    boomStart = start ?? now",
        "    startCycle(freshVerb: true)",
        "}",
        "let drag = exp(-dt * 1.6)",
        "for w in writers { update(w, dt: dt) }",
    ]

    public struct Params {
        public var originCG: CGPoint      // detonation point, global CG coords
        public var radius: CGFloat        // shared terminal radius across displays
        public var seed: UInt64
        public var wave1: Double          // first front's sweep time, s
        public var gap: Double            // detonation → second front, s
        public var wave2: Double          // second front's sweep time, s
        public var debrisDensity: Double  // spawn chance per revealed cell
        /// The gerund on the idle line — both processes must show the same
        /// verb for the crossfade to be invisible.
        public var idleVerb: String
        /// Real code for the spots the first front scatters. Serialized with
        /// the blob so both processes stamp identical text.
        public var codeLines: [String]

        public init(originCG: CGPoint, radius: CGFloat, seed: UInt64,
                    wave1: Double = 0.85 * BoomCore.tempo,
                    gap: Double = BoomCore.gapBase * BoomCore.tempo,
                    wave2: Double = BoomCore.wave2Base * BoomCore.tempo,
                    debrisDensity: Double = 0.065, idleVerb: String = "Idling",
                    codeLines: [String] = []) {
            self.originCG = originCG
            self.radius = radius
            self.seed = seed
            self.wave1 = wave1
            self.gap = gap
            self.wave2 = wave2
            self.debrisDensity = debrisDensity
            self.idleVerb = idleVerb
            self.codeLines = codeLines.isEmpty ? BoomCore.fallbackCodeLines : codeLines
        }
    }

    public struct Particle {
        public var x, y: Double           // global CG coords (sim-side only)
        public var vx, vy: Double
        public var ch: UInt8              // ASCII code (33…126)
        public var settled = false
        /// Tick when the glyph slowed into its decay — set while it's still
        /// drifting, so the fade begins before it parks and the population
        /// decays staged rather than in lockstep.
        public var decayTick: Int32 = -1
    }

    public var params: Params
    public var fields: [BoomField]
    public var particles: [Particle] = []
    public private(set) var tickCount = 0
    var rng: BoomRNG

    /// Cells whose static value changed since the renderer last drained them.
    public var pendingPaints: [[Int]]
    /// Transient comet-trail decals (field, cell index, tick) — cosmetic,
    /// recomputed identically on both sides, never serialized.
    public var trailDecals: [(field: Int, idx: Int, tick: Int)] = []
    /// Non-space chars drawn from codeLines: what debris is made of.
    private var charPool: [UInt8] = []

    /// Settled-glyph fade: 1 on landing → 0 at `settledFadeLife` seconds.
    /// Quadratic, not exponential: the drop toward black starts immediately
    /// and actually completes instead of trailing off forever. Shared with
    /// the saver so the fade is continuous across the ownership transfer.
    public static let settledFadeLife = 5.0
    public static func settledFade(age: Double) -> Double {
        let t = max(0.0, 1.0 - max(0.0, age) / settledFadeLife)
        return t * t
    }

    private static let maxParticles = 1300
    private static let jitter1 = 0.10        // per-cell arrival jitter, s
    private static let jitter2 = 0.12
    // Debris physics ÷tempo across the board: the same fling trajectories,
    // traversed tempo× slower — matching the stretched fronts.
    private static let drag = 1.6 / tempo
    private static let settleSpeed = 42.0 / tempo  // px/s: below this a glyph parks
    private static let decaySpeed = 260.0 / tempo  // px/s: below this its fade begins
    private static let streakSpeed = 250.0 / tempo // px/s: above this it leaves a trail
    private static let spotChance = 0.0015   // code-spot chance per revealed cell

    public var simTime: Double { Double(tickCount) / Self.tickHz }

    public init(params: Params, fields: [BoomField]) {
        self.params = params
        self.fields = fields
        self.rng = BoomRNG(seed: params.seed)
        self.pendingPaints = fields.map { _ in [] }
        for f in fields { precomputeHits(f) }
        charPool = params.codeLines.flatMap { line in
            line.unicodeScalars.compactMap { $0.value >= 33 && $0.value < 127 ? UInt8($0.value) : nil }
        }
        if charPool.isEmpty { charPool = Array("{}[]()<>=+-*/;:._".utf8) }
    }

    private func precomputeHits(_ f: BoomField) {
        let n = f.grid.cols * f.grid.rows
        f.hit1 = [Float](repeating: 0, count: n)
        f.hit2 = [Float](repeating: 0, count: n)
        let R = max(1, Double(params.radius))
        for row in 0..<f.grid.rows {
            for col in 0..<f.grid.cols {
                let rect = f.grid.cellRect(col, row)
                let gx = Double(f.originCG.x + rect.midX)
                let gy = Double(f.originCG.y + rect.midY)
                let d = min(hypot(gx - Double(params.originCG.x),
                                  gy - Double(params.originCG.y)) / R, 0.999)
                // Decelerating front, exponent tuned so hits spread across
                // the sweep instead of dumping most cells in the first third.
                let u = 1 - pow(1 - d, 0.6)
                let i = f.index(col, row)
                f.hit1[i] = Float(params.wave1 * u
                    + (boomCellNoise(col, row, params.seed &+ 0xB1) - 0.5) * Self.jitter1)
                f.hit2[i] = Float(params.gap + params.wave2 * u
                    + (boomCellNoise(col, row, params.seed &+ 0xB2) - 0.5) * Self.jitter2)
            }
        }
    }

    /// When the *second* front reaches a global point — what the saver keys
    /// writer ignition, clock fade, and the zap on.
    public func secondHit(ofGlobal p: CGPoint) -> Double {
        let R = max(1, Double(params.radius))
        let d = min(hypot(Double(p.x - params.originCG.x),
                          Double(p.y - params.originCG.y)) / R, 0.999)
        return params.gap + params.wave2 * (1 - pow(1 - d, 0.6))
    }

    public var duration: Double { params.gap + params.wave2 + 0.5 }

    // MARK: Ticking

    /// Advances the sim to time `t` in fixed steps. Deterministic: any two
    /// hosts stepping from the same state reach the same state.
    public func advance(to t: Double) {
        while simTime < t {
            tickCount += 1
            step()
        }
    }

    private func step() {
        let t = simTime
        let dt = 1.0 / Self.tickHz

        // Wavefronts: state transitions in fixed cell order (determinism).
        for (fi, f) in fields.enumerated() {
            let n = f.grid.cols * f.grid.rows
            for i in 0..<n {
                if f.state[i] == BoomField.stateUntouched, t >= Double(f.hit1[i]) {
                    f.state[i] = BoomField.stateAscii
                    f.hitTick[i] = Int32(tickCount)
                    pendingPaints[fi].append(i)
                    spawnDebris(field: f, fieldIndex: fi, cell: i)
                    spawnSpot(field: f, fieldIndex: fi, cell: i)
                } else if f.state[i] == BoomField.stateAscii, t >= Double(f.hit2[i]) {
                    f.state[i] = BoomField.stateBlack
                    f.hitTick[i] = Int32(tickCount)
                    pendingPaints[fi].append(i)
                }
                // Settled glyphs survive the second front: they were flung
                // *by* the boom; the boom doesn't reclaim them.
            }
        }

        // Flung glyphs: continuous sim, grid-quantized display. Trail decals
        // are the cells crossed this tick (Bresenham), cooling behind the head.
        let dragMul = exp(-dt * Self.drag)
        for pi in particles.indices where !particles[pi].settled {
            var p = particles[pi]
            let ox = p.x, oy = p.y
            p.vx *= dragMul
            p.vy *= dragMul
            p.x += p.vx * dt
            p.y += p.vy * dt
            if let (fi, f) = fieldContaining(x: p.x, y: p.y) {
                let speed = hypot(p.vx, p.vy)
                // Only fast movers streak; a drifting glyph is just a glyph.
                if speed > Self.streakSpeed {
                    // BOTH endpoints in THIS field's grid space. A glyph
                    // crossing displays used to keep its old display's cell
                    // coords for the start point, and the Bresenham walk
                    // painted a phantom line sweeping in from the new
                    // display's far edge. Off-grid start cells are fine —
                    // the walk's bounds check clips them at the seam.
                    markTrail(field: fi, grid: f.grid,
                              from: cellIn(f, x: ox, y: oy),
                              to: cellIn(f, x: p.x, y: p.y), f: f)
                }
                if p.decayTick < 0, speed < Self.decaySpeed {
                    p.decayTick = Int32(tickCount)
                }
                if speed < Self.settleSpeed {
                    p.settled = true
                    if let cell = f.grid.cell(at: CGPoint(x: p.x - f.originCG.x,
                                                          y: p.y - f.originCG.y)) {
                        let i = f.index(cell.col, cell.row)
                        f.state[i] = BoomField.stateSettled
                        f.ascii[i] = p.ch
                        // The settled fade continues the in-flight decay
                        // clock, not a fresh one: no jump at parking.
                        f.hitTick[i] = p.decayTick >= 0 ? p.decayTick : Int32(tickCount)
                        pendingPaints[fi].append(i)
                    }
                }
            } else {
                p.settled = true    // flew off every display: gone
            }
            particles[pi] = p
        }

        // Trim decals older than the cooling window.
        let cutoff = tickCount - 16
        trailDecals.removeAll { $0.tick < cutoff }
    }

    /// The first front occasionally stamps a spot of actual code into the
    /// field: a few consecutive corpus lines, barely-translucent white over
    /// the pixelated desktop. Cells ahead of the front hold theirs latently
    /// and appear when the wave reveals them; already-revealed cells pop in
    /// with a flash. Indentation survives because spaces skip cells.
    private func spawnSpot(field f: BoomField, fieldIndex fi: Int, cell i: Int) {
        guard rng.double01() < Self.spotChance else { return }
        let col0 = i % f.grid.cols, row0 = i / f.grid.cols
        let lineCount = 2 + Int(rng.double01() * 4.999)
        let start = Int(rng.double01() * Double(params.codeLines.count))
        for li in 0..<lineCount {
            let row = row0 + li
            guard row < f.grid.rows else { break }
            let line = params.codeLines[(start + li) % params.codeLines.count]
            for (k, ch) in line.unicodeScalars.enumerated() {
                guard k < 44, col0 + k < f.grid.cols else { break }
                guard ch.value >= 33, ch.value < 127 else { continue }
                let j = f.index(col0 + k, row)
                guard f.state[j] == BoomField.stateUntouched
                    || f.state[j] == BoomField.stateAscii else { continue }
                f.ascii[j] = UInt8(ch.value)
                if f.state[j] == BoomField.stateAscii {
                    f.hitTick[j] = Int32(tickCount)
                    pendingPaints[fi].append(j)
                }
            }
        }
    }

    private func spawnDebris(field f: BoomField, fieldIndex: Int, cell i: Int) {
        guard particles.count < Self.maxParticles else { return }
        guard rng.double01() < params.debrisDensity else { return }
        let col = i % f.grid.cols, row = i / f.grid.cols
        let rect = f.grid.cellRect(col, row)
        let gx = Double(f.originCG.x + rect.midX)
        let gy = Double(f.originCG.y + rect.midY)
        var dx = gx - Double(params.originCG.x)
        var dy = gy - Double(params.originCG.y)
        let len = max(1, hypot(dx, dy))
        dx /= len
        dy /= len
        // Outward from the origin, with tangential spray.
        let sizeMul = max(0.7, Double(params.radius) / 1500)
        let speed = rng.expTail(base: 300, mean: 500, cap: 2400) * sizeMul / Self.tempo
        let tang = rng.range(-0.45, 0.45)
        particles.append(Particle(
            x: gx, y: gy,
            vx: (dx - dy * tang) * speed,
            vy: (dy + dx * tang) * speed,
            ch: charPool[Int(rng.double01() * Double(charPool.count)) % charPool.count]
        ))
    }

    /// Raw cell coords of a global point in `f`'s grid — deliberately
    /// unclamped: callers use out-of-range results to clip at field seams.
    private func cellIn(_ f: BoomField, x: Double, y: Double) -> (Int, Int) {
        let lx = x - Double(f.originCG.x)
        let ly = y - Double(f.originCG.y)
        return (Int(floor((lx - Double(f.grid.leftInset)) / Double(f.grid.charW))),
                Int(floor((ly - Double(f.grid.topInset)) / Double(f.grid.lineH))))
    }

    private func fieldContaining(x: Double, y: Double) -> (Int, BoomField)? {
        for (i, f) in fields.enumerated() {
            let b = CGRect(origin: f.originCG, size: f.grid.size)
            if b.contains(CGPoint(x: x, y: y)) { return (i, f) }
        }
        return nil
    }

    private func markTrail(field fi: Int, grid: BoomGrid,
                           from a: (Int, Int), to b: (Int, Int), f: BoomField) {
        guard b.0 >= 0, b.1 >= 0 else { return }
        guard a.0 != b.0 || a.1 != b.1 else { return }
        // Bresenham through the cells crossed this tick.
        var (x0, y0) = a.0 >= 0 ? a : b
        let (x1, y1) = b
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            if x0 >= 0, x0 < grid.cols, y0 >= 0, y0 < grid.rows {
                trailDecals.append((field: fi, idx: f.index(x0, y0), tick: tickCount))
            }
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    // MARK: Pixelate

    /// Downsamples an image to one average color per cell — the pixelated
    /// desktop the first front reveals. This is the only unreproducible
    /// input the helper hands the saver. Darkening happens at paint time.
    public static func colorize(_ image: CGImage, grid: BoomGrid) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: grid.cols * grid.rows)
        guard let ctx = CGContext(data: nil, width: grid.cols, height: grid.rows,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return out }
        ctx.interpolationQuality = .medium
        // Scale so one cell = one pixel: the full display image drawn at
        // (points / cell-size) px, shifted so the grid's inset region lands
        // on the bitmap. The context is bottom-up; the row read flips back.
        ctx.draw(image, in: CGRect(
            x: -grid.leftInset / grid.charW,
            y: -(grid.size.height - grid.topInset - CGFloat(grid.rows) * grid.lineH) / grid.lineH,
            width: grid.size.width / grid.charW,
            height: grid.size.height / grid.lineH
        ))
        guard let data = ctx.data else { return out }
        let stride = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: stride * grid.rows)
        for row in 0..<grid.rows {
            // CG *draws* bottom-up, but bitmap memory row 0 is the TOP
            // scanline — the two flips cancel, so memory row == cell row.
            for col in 0..<grid.cols {
                let o = row * stride + col * 4
                out[row * grid.cols + col] =
                    UInt32(px[o]) << 16 | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2])
            }
        }
        return out
    }

    /// Parks every still-drifting glyph where it is: each becomes a settled
    /// cell continuing its own in-flight decay clock. The handoff backstop —
    /// glyphs may never simply vanish.
    public func parkRemainingParticles() {
        for pi in particles.indices where !particles[pi].settled {
            var p = particles[pi]
            p.settled = true
            if let (fi, f) = fieldContaining(x: p.x, y: p.y),
               let cell = f.grid.cell(at: CGPoint(x: p.x - f.originCG.x,
                                                  y: p.y - f.originCG.y)) {
                let i = f.index(cell.col, cell.row)
                f.state[i] = BoomField.stateSettled
                f.ascii[i] = p.ch
                f.hitTick[i] = p.decayTick >= 0 ? p.decayTick : Int32(tickCount)
                pendingPaints[fi].append(i)
            }
            particles[pi] = p
        }
    }

    /// Hands the host renderer the cells whose static value changed.
    public func drainPaints(_ fieldIndex: Int) -> [Int] {
        let out = pendingPaints[fieldIndex]
        pendingPaints[fieldIndex] = []
        return out
    }
}
