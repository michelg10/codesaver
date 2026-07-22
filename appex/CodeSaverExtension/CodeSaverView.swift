import AppKit
import ScreenSaver
import QuartzCore
import os.log

private let viewLog = AppexLog.logger("View")

// MARK: - Helpers

@inline(__always) private func rand(_ a: Double, _ b: Double) -> Double {
    a < b ? Double.random(in: a...b) : a
}

@inline(__always) private func clampd(_ v: Double, _ a: Double, _ b: Double) -> Double {
    min(max(v, a), b)
}

/// Box-Muller normal sample.
private func gaussRand(mean: Double, sigma: Double) -> Double {
    let u1 = Double.random(in: 1e-9...1)
    let u2 = Double.random(in: 0...1)
    return mean + sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

/// base + Exp(mean), capped: most samples land near base + mean, with a long tail.
private func expTail(base: Double, mean: Double, cap: Double) -> Double {
    min(cap, base - log(Double.random(in: 1e-9..<1)) * mean)
}

private extension NSColor {
    /// Linear blend toward `other` in device RGB.
    func mixed(with other: NSColor, _ f: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else { return self }
        let t = min(max(f, 0), 1)
        return NSColor(
            deviceRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
    }
}

// MARK: - Model

private final class Segment {
    var xCol = 0
    var chars: [Character] = []
    var cells = 0      // claimed width in cells (CJK/emoji occupy 2+)
    var typed = 0
    var isActive = false
    var typingDoneAt: Double = -100
    var settledAt: Double = -100
    var tint: CGFloat = 0
    var isComment = false
}

private final class Writer {
    var queue: [[Character]] = []
    var row = 0
    var band = 0
    var col = 0
    var current: Segment?
    var cps: Double = 80
    var carry: Double = 0
    var pauseUntil: Double = 0
}

// MARK: - View

@objc(CodeSaverView)
public final class CodeSaverView: ScreenSaverView {

    // Spinner glyph frames; a cosine phase sweeps the index 0→5→0.
    private static let spinnerFrames =
        ["\u{B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"]

    // MARK: Palette

    // Pure black: borderless on OLED/miniLED — the code floats on nothing.
    private let bgColor = NSColor.black
    private let codeBase = NSColor(deviceRed: 0.58, green: 0.65, blue: 0.72, alpha: 1)
    private let glowText = NSColor(deviceRed: 0.93, green: 0.98, blue: 1.0, alpha: 1)
    private let glowHalo = NSColor(deviceRed: 0.50, green: 0.83, blue: 1.0, alpha: 1)
    private let cursorColor = NSColor(deviceRed: 0.66, green: 0.90, blue: 1.0, alpha: 1)
    // Accent: bluish-purple (ref #6E49E4, Display P3), lifted a touch for
    // text legibility on the dark background.
    private let accent = NSColor(displayP3Red: 0.494, green: 0.357, blue: 0.937, alpha: 1)
    private let accentHot = NSColor(displayP3Red: 0.75, green: 0.64, blue: 1.0, alpha: 1)

    // MARK: Preferences

    static let prefsSuite = "com.michelg10.CodeSaver.Extension"
    private static let prefs = ScreenSaverDefaults(forModuleWithName: prefsSuite)
    private var showClock = true
    private var use24Hour = false
    private var nextPrefsRead: Double = 0

    private func readPrefs() {
        guard let p = Self.prefs else { return }
        showClock = p.object(forKey: "showClock") == nil ? true : p.bool(forKey: "showClock")
        use24Hour = p.bool(forKey: "use24HourTime")
    }

    /// The clock only appears on the designated main display (the one that
    /// owns the menu bar). If we can't tell which display we're on, assume
    /// main so the clock never silently disappears. The preview always shows
    /// it regardless of which display the System Settings window is on.
    ///
    /// In the appex, every display's view lives in one extension process,
    /// each hosted in a window positioned at the target display's origin in
    /// CoreGraphics coordinates (top-left origin) used unconverted as a Cocoa
    /// frame — so window.screen is nil (or briefly wrong, see below) for
    /// displays off the primary row, but the window's origin identifies the
    /// display. Match the origin, not the full rect: the window's size has
    /// historically been the main display's size (Aerial does the same).
    /// window.screen remains as a fallback for real windows (legacy .saver,
    /// the preview harness) whose origin matches no display.
    ///
    /// The host initially places every window on the main display and migrates
    /// it to its real target moments later; since this is evaluated every
    /// draw, a wrong early answer self-corrects after the migration.
    private var clockVisible: Bool {
        guard showClock else { return false }
        if isPreview { return true }
        guard let window else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for id in ids.prefix(Int(count)) {
                let origin = CGDisplayBounds(id).origin
                if abs(origin.x - window.frame.origin.x) < 0.5,
                   abs(origin.y - window.frame.origin.y) < 0.5 {
                    return CGDisplayIsMain(id) != 0
                }
            }
        }
        if let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return CGDisplayIsMain(id) != 0
        }
        return true
    }
    // MARK: Tunable clock style
    // Adjusted live by the preview harness's debug sliders; the shipped saver
    // uses these defaults.

    // Values hand-tuned with the preview harness's sliders (2026-07-11).
    public var clockPadCells: CGFloat = 4      // blank cells each side of the digits
    public var clockTopFrac: CGFloat = 0.0887  // box top, fraction of screen height
    public var clockScale: CGFloat = 0.026     // cell font size, fraction of screen height
    public var clockBackdropAlpha: CGFloat = 0.375
    public var clockBorderWhite: CGFloat = 0.289
    public var clockDigitWhite: CGFloat = 0.78
    public var clockVPadRows: Int = 1          // empty rows above/below the digits
    public var panelGapMult: CGFloat = 0.5     // gap between clock and safe area, × lineH
    public var panelBias: CGFloat = -4.10      // spinner panel vertical bias, in clock-cell units (negative = up)

    // MARK: Tunable background-code style

    public var codeActiveAlpha: CGFloat = 0.52   // line being typed
    public var codeSettledFloor: CGFloat = 0.19  // old settled lines converge here
    public var codeSettledBoost: CGFloat = 0.31  // extra brightness that fades with age
    public var codeFadeTau: CGFloat = 26         // age decay time constant, seconds
    public var codeCommentDim: CGFloat = 0.6     // multiplier for comment lines
    public var codeGlowStrength: CGFloat = 1.0   // typing-head trail glow
    public var vignetteMax: CGFloat = 0.42       // edge darkening at the corners

    // MARK: Content

    private var verbs: [(ing: String, past: String)] = []

    // Corpus: whole source files, memory-mapped, selected per session with
    // bounded unfairness across repos (sqrt weighting + share cap) and
    // decoded lazily. Half the subset refreshes each time a "request"
    // finishes — new task, new context.
    private static let subsetSize = 400
    private static let repoShareCap = 0.12
    private var corpusData: Data?
    private var fullIndex: [String: [[Int]]] = [:]   // repo → [[offset, length]]
    private var blockRefs: [Range<Int>] = []         // this session's subset
    private var decodedBlocks: [Int: [String]] = [:] // subset slot → lines
    private var fallbackBlocks: [[String]] = []      // legacy corpus.txt path

    // MARK: Clock

    private var now: Double = 0
    private var lastWall: Double = 0

    // MARK: Layout

    private var setupSize = NSSize.zero
    private var font: NSFont!
    private var uiFont: NSFont!
    private var uiBoldFont: NSFont!
    private var charW: CGFloat = 8
    private var lineH: CGFloat = 18
    private var rowCount = 0
    private var cols = 80
    private var leftInset: CGFloat = 24
    private var topInset: CGFloat = 16

    private var bandCount = 1
    private var bandWidth = 80
    private var rows: [[Segment]] = []
    private var writers: [Writer] = []

    // MARK: Spinner state

    private enum Phase { case working, done }
    private var phase = Phase.working
    private var phaseStart: Double = 0
    private var workDuration: Double = 120
    private var doneDuration: Double = 10
    private var verbIndex = 0

    private var tokens: Double = 0
    private var tokensCeil: Double = 2000
    private var tokensTau: Double = 32
    private var arrowIsDown = true
    private var nextArrowFlip: Double = 8
    private var statusVisible = true
    private var nextStatusRoll: Double = 5
    /// Whether the status text is actually on screen this tick, and since when.
    /// Each visible stretch escalates coding → still → almost done on a fixed
    /// clock, and always restarts at "coding" when the text comes back.
    private var statusShowing = false
    private var statusEnteredAt: Double = 0
    private var frozenDoneText = ""
    /// Seconds at the start of a cycle where only the glyph + verb show,
    /// mirroring API latency before the first response chunk.
    private var parenDelay: Double = 2.5
    /// Eased global speed for the background typing: 1 while working (↓),
    /// slightly faster during ↑ upload bursts, slowest while the spinner rests.
    private var speedMul: Double = 1.0

    // MARK: Init

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        loadResources()
        startCycle(freshVerb: true)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        loadResources()
        startCycle(freshVerb: true)
    }

    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }

    // MARK: Resources

    private func loadResources() {
        var resourceDirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CODESAVER_RESOURCES"] {
            resourceDirs.append(URL(fileURLWithPath: env))
        }
        if let url = Bundle(for: CodeSaverView.self).resourceURL {
            resourceDirs.append(url)
        }
        resourceDirs.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources"))

        func readFirst(_ name: String) -> String? {
            for dir in resourceDirs {
                if let s = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                    return s
                }
            }
            return nil
        }

        // Verbs: "Gerund<TAB>Past" per line.
        let verbText = readFirst("spinner-verbs.txt")
            ?? "Coding\tCoded\nCompiling\tCompiled\nRefactoring\tRefactored\nShipping\tShipped"
        verbs = verbText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (ing: parts[0], past: parts[1])
        }
        if verbs.isEmpty { verbs = [(ing: "Coding", past: "Coded")] }

        // Corpus: corpus.bin (whole files, mmapped) + corpus-index.json.
        for dir in resourceDirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("corpus.bin"),
                                       options: .mappedIfSafe),
                  let idxData = try? Data(contentsOf: dir.appendingPathComponent("corpus-index.json")),
                  let idx = (try? JSONSerialization.jsonObject(with: idxData)) as? [String: [[Int]]],
                  !idx.isEmpty else { continue }
            // Validate the whole index against the bin before trusting any of
            // it — a stale/corrupt pair falls through to the legacy fallback
            // instead of rendering garbage or trapping on Range construction.
            let blocks = idx.values.flatMap { $0 }
            let valid = !blocks.isEmpty && blocks.allSatisfy {
                $0.count == 2 && $0[0] >= 0 && $0[1] > 0 && $0[0] <= data.count - $0[1]
            }
            guard valid else { continue }
            corpusData = data
            fullIndex = idx
            blockRefs = chooseSubset(budget: Self.subsetSize)
            break
        }
        if corpusData == nil {
            // Legacy text corpus (blocks separated by U+0001 header lines).
            let corpusText = readFirst("corpus.txt") ?? Self.fallbackCorpus
            var blocks: [[String]] = []
            var current: [String] = []
            corpusText.enumerateLines { line, _ in
                if line.hasPrefix("\u{01}") {
                    if current.count >= 3 { blocks.append(current) }
                    current = []
                } else {
                    current.append(line)
                }
            }
            if current.count >= 3 { blocks.append(current) }
            fallbackBlocks = blocks.isEmpty ? [Self.fallbackCorpus.components(separatedBy: "\n")] : blocks
        }
    }

    /// Draws `budget` blocks across repos: weight ∝ sqrt(file count), capped
    /// at a fixed share of the budget, floored at one block per repo.
    private func chooseSubset(budget: Int) -> [Range<Int>] {
        let repos = fullIndex.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        guard !repos.isEmpty else { return [] }
        let weights = repos.map { sqrt(Double($0.value.count)) }
        let totalW = weights.reduce(0, +)
        let cap = max(1, Int(Double(budget) * Self.repoShareCap))
        var result: [Range<Int>] = []
        for (i, (_, blocks)) in repos.enumerated() {
            let ideal = Int((Double(budget) * weights[i] / totalW).rounded())
            let quota = min(blocks.count, min(cap, max(1, ideal)))
            for pair in blocks.shuffled().prefix(quota)
            where pair.count == 2 && pair[0] >= 0 && pair[1] > 0 {
                result.append(pair[0]..<(pair[0] + pair[1]))
            }
        }
        return result.shuffled()
    }

    /// Swaps part of the session subset for freshly drawn blocks. Slots are
    /// chosen without replacement so `fraction` means what it says.
    private func rotateSubset(fraction: Double) {
        guard corpusData != nil, !fullIndex.isEmpty, blockRefs.count >= 8 else { return }
        let fresh = chooseSubset(budget: max(8, Int(Double(blockRefs.count) * fraction)))
        let slots = Array(0..<blockRefs.count).shuffled().prefix(fresh.count)
        for (slot, r) in zip(slots, fresh) {
            blockRefs[slot] = r
            decodedBlocks[slot] = nil
        }
    }

    /// Lazily decodes one block of corpus.bin into lines.
    private func blockLines(at slot: Int) -> [String] {
        if let cached = decodedBlocks[slot] { return cached }
        guard let data = corpusData else { return [] }
        let r = blockRefs[slot]
        guard r.lowerBound >= 0, r.upperBound <= data.count else { return [] }
        var lines = String(decoding: data.subdata(in: r), as: UTF8.self)
            .components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        decodedBlocks[slot] = lines
        return lines
    }

    private static let fallbackCorpus = """
    func animateOneFrame() {
        let t = CACurrentMediaTime()
        advance(by: t - lastWall)
        setNeedsDisplay(bounds)
    }
    """

    // MARK: Layout setup

    private func ensureSetup() {
        guard bounds.width > 8, bounds.height > 8 else { return }
        guard bounds.size != setupSize else { return }
        setupSize = bounds.size

        let base = isPreview ? 7.0 : clampd(Double(bounds.width) / 125.0, 11.5, 16.5)
        font = NSFont(name: "SFMono-Regular", size: base) ?? .monospacedSystemFont(ofSize: base, weight: .regular)
        uiFont = NSFont(name: "SFMono-Regular", size: base * 1.18) ?? .monospacedSystemFont(ofSize: base * 1.18, weight: .regular)
        uiBoldFont = NSFont(name: "SFMono-Semibold", size: base * 1.18) ?? .monospacedSystemFont(ofSize: base * 1.18, weight: .semibold)

        charW = ("M" as NSString).size(withAttributes: [.font: font!]).width
        lineH = ceil(base * 1.55)
        leftInset = max(18, bounds.width * 0.015)
        topInset = max(14, bounds.height * 0.02)
        rowCount = max(4, Int((bounds.height - topInset * 2) / lineH))
        cols = max(20, Int((bounds.width - leftInset * 2) / charW))

        cellWidthCache.removeAll()  // widths are ratios of the (new) font
        rows = Array(repeating: [], count: rowCount)
        // Nominal spawn bands across the width; chunks get jitter within them,
        // so no fixed column edges ever show.
        bandCount = isPreview ? 1 : max(1, Int((Double(cols) / 100.0).rounded()))
        bandWidth = cols / bandCount
        let writerCount = isPreview ? 2 : min(8, max(3, min(bandCount * 3, rowCount / 6)))
        writers = (0..<writerCount).map { _ in Writer() }
        for w in writers {
            respawn(w)
            w.pauseUntil = now + rand(0, 2.5)
        }
    }

    // MARK: Animation

    private var fallbackTimer: Timer?
    private var frameworkDriven = false

    public override func animateOneFrame() {
        frameworkDriven = true
        stopFallbackTimer()
        tick()
    }

    /// Advances by wall-clock time and requests a redraw. Safe to call from
    /// multiple drivers: overlapping calls produce dt ≈ 0, not double speed.
    private func tick() {
        let t = CACurrentMediaTime()
        let dt = lastWall == 0 ? animationTimeInterval : clampd(t - lastWall, 0, 0.25)
        lastWall = t
        advance(by: dt)
        setNeedsDisplay(bounds)
    }

    // In the appex world the framework drives animateOneFrame when
    // SSENeedsAnimationTimer is true — but not every host does (and the host
    // app's preview window has no framework at all). If no frame request
    // arrives shortly after we land in a window, drive ourselves.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            viewLog.notice("viewDidMoveToWindow — window frame \(Double(win.frame.width), privacy: .public)×\(Double(win.frame.height), privacy: .public), view bounds \(Double(self.bounds.width), privacy: .public)×\(Double(self.bounds.height), privacy: .public)")
            rescueZeroSizedWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.window != nil else { return }
                self.rescueZeroSizedWindow()
                if !self.frameworkDriven { self.startFallbackTimer() }
            }
        } else {
            stopFallbackTimer()
            // Re-arm for a possible next window whose host doesn't drive frames.
            frameworkDriven = false
        }
    }

    /// On macOS 26 the ViewBridge sizing handshake from the host can fail to
    /// deliver a frame, leaving the remote service window at 0×0 forever: the
    /// model animates, draw(_:) never fires, and the saver composites as pure
    /// black (System Settings preview included). If the host hasn't sized us,
    /// adopt the screen's size ourselves — a genuine host size transaction
    /// arriving later still wins, so this is purely a fallback.
    private func rescueZeroSizedWindow() {
        guard let win = window, win.frame.width < 1 || win.frame.height < 1 else { return }
        var f = win.frame
        f.size = win.screen?.frame.size ?? NSScreen.main?.frame.size ?? NSSize(width: 1920, height: 1080)
        viewLog.notice("zero-sized service window — self-rescuing to \(Double(f.width), privacy: .public)×\(Double(f.height), privacy: .public)")
        win.setFrame(f, display: true)
    }

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    deinit {
        stopFallbackTimer()
    }

    /// Advances the simulation clock. Exposed for the preview/snapshot harness.
    public func advance(by dt: Double) {
        now += dt
        ensureSetup()
        guard !rows.isEmpty else { return }
        if now >= nextPrefsRead {
            readPrefs()
            nextPrefsRead = now + 2
        }
        // ↑ means upload — data streaming to the model — so everything runs a
        // touch hotter while it's active. Idle at the slowest speed while the
        // spinner rests AND while a new request waits on the API: typing only
        // ramps up when the first response chunk arrives.
        let streaming = phase == .working && now - phaseStart >= parenDelay
        let targetMul: Double = streaming ? (arrowIsDown ? 1.0 : 1.18) : 0.22
        speedMul += (targetMul - speedMul) * min(1, dt * 1.5)
        for w in writers { update(w, dt: dt) }
        updateSpinner(dt: dt)
    }

    // MARK: Background writers

    private func randomChunk() -> [[Character]] {
        let block: [String]
        if !blockRefs.isEmpty {
            block = blockLines(at: Int.random(in: 0..<blockRefs.count))
        } else {
            block = fallbackBlocks.randomElement() ?? []
        }
        guard !block.isEmpty else { return [] }
        var slice: [String]
        let want = Int(rand(8, 24))
        if block.count > want {
            let start = Int.random(in: 0...(block.count - want))
            slice = Array(block[start..<(start + want)])
        } else {
            slice = block
        }
        while let f = slice.first, f.trimmingCharacters(in: .whitespaces).isEmpty { slice.removeFirst() }
        while let l = slice.last, l.trimmingCharacters(in: .whitespaces).isEmpty { slice.removeLast() }
        // De-dent: strip the indentation every non-empty line shares, so a
        // chunk cut from deep inside a function starts at its own margin.
        let common = slice.reduce(Int.max) { acc, line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                ? acc : min(acc, line.prefix(while: { $0 == " " }).count)
        }
        if common > 0, common < Int.max {
            slice = slice.map { String($0.dropFirst(min(common, $0.count))) }
        }
        return slice.map { Array($0) }
    }

    // MARK: Cell widths
    // The layout is a character-cell model, but CJK/emoji glyphs paint wider
    // than one cell. Widths are MEASURED per character (so the model matches
    // whatever font fallback actually draws) and ceil'd — over-claiming is
    // safe (spans clear enough, truncation stays inside the margin); under-
    // claiming is what causes text painting over its neighbors.
    private var cellWidthCache: [Character: Int] = [:]

    private func cellWidth(_ ch: Character) -> Int {
        if ch.isASCII { return 1 }
        if let cached = cellWidthCache[ch] { return cached }
        let advance = (String(ch) as NSString).size(withAttributes: [.font: font!]).width
        let w = max(1, Int(ceil(advance / charW - 0.05)))
        cellWidthCache[ch] = w
        return w
    }

    private func cellWidth(of chars: [Character]) -> Int {
        var total = 0
        for ch in chars { total += cellWidth(ch) }
        return total
    }

    /// Longest prefix of `chars` fitting `budget` cells (never bisecting a
    /// wide character), and that prefix's cell width.
    private func prefixFitting(_ chars: [Character], budget: Int) -> (chars: [Character], cells: Int) {
        var cells = 0, end = 0
        for ch in chars {
            let w = cellWidth(ch)
            if cells + w > budget { break }
            cells += w
            end += 1
        }
        return (Array(chars[0..<end]), cells)
    }

    private func respawn(_ w: Writer) {
        w.queue = randomChunk()
        w.cps = rand(45, 140)
        w.carry = 0
        w.current = nil
        w.pauseUntil = now + rand(0.4, 2.0)
        w.band = Int.random(in: 0..<bandCount)
        // Gaussian placement around the band anchor: most chunks sit near it,
        // but the tails push writers well outside their "column" so the layout
        // never reads as a grid.
        let anchor = Double(w.band * bandWidth) + Double(bandWidth) * 0.08
        let spread = max(8.0, Double(bandWidth) * 0.2)
        w.col = max(0, min(cols - 36, Int(gaussRand(mean: anchor, sigma: spread))))
        var attempt = 0
        repeat {
            w.row = Int.random(in: 0..<rowCount)
            attempt += 1
        } while attempt < 8 && writers.contains(where: { $0 !== w && $0.band == w.band && abs($0.row - w.row) < 6 })
    }

    /// Claims a segment for the writer's next line, clipping whatever settled
    /// text it lands on (a terminal overwriting cells, not a grid).
    private func startLine(_ w: Writer) {
        var line = w.queue[0]
        var cells = cellWidth(of: line)
        let budget = cols - w.col
        if cells > budget { (line, cells) = prefixFitting(line, budget: budget) }
        clearSpan(row: w.row, from: w.col - 1, to: w.col + max(cells, 44) + 1)
        let seg = Segment()
        seg.xCol = w.col
        seg.chars = line
        seg.cells = cells
        seg.isActive = true
        seg.tint = CGFloat(rand(-0.05, 0.07))
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        seg.isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*")
            || trimmed.hasPrefix("/*") || trimmed.hasPrefix("--")
        rows[w.row].append(seg)
        w.current = seg
    }

    private func clearSpan(row: Int, from a: Int, to b: Int) {
        // Clips everything in the span, active segments included — the newest
        // line wins, like a terminal overwriting cells. A writer whose active
        // segment gets removed just finishes that line invisibly and moves on.
        rows[row].removeAll { seg in
            let s = seg.xCol
            let e = seg.xCol + seg.cells
            guard s < b && e > a else { return false }
            if s < a {
                // Starts left of the span: clip its tail — but a stump too
                // short to read as code is just visual debris, drop it.
                // `keep` is in cells; the cut lands on a character boundary.
                let keep = max(0, a - s)
                if keep < 12 { return true }
                let fitted = prefixFitting(seg.chars, budget: keep)
                seg.chars = fitted.chars
                seg.cells = fitted.cells
                seg.typed = min(seg.typed, seg.chars.count)
                return false
            }
            return true
        }
    }

    private func update(_ w: Writer, dt: Double) {
        guard now >= w.pauseUntil else { return }
        guard !w.queue.isEmpty else { respawn(w); return }

        if w.current == nil { startLine(w) }
        guard let seg = w.current else { return }

        // Whitespace is free — indentation appears instantly — so the visible
        // characters type as one continuous stream.
        w.carry += w.cps * speedMul * dt
        while true {
            while seg.typed < seg.chars.count, seg.chars[seg.typed] == " " { seg.typed += 1 }
            guard seg.typed < seg.chars.count, w.carry >= 1 else { break }
            w.carry -= 1
            seg.typed += 1
        }

        if seg.typed >= seg.chars.count {
            seg.isActive = false
            seg.typingDoneAt = now
            seg.settledAt = now
            if seg.chars.isEmpty { rows[w.row].removeAll { $0 === seg } }
            w.current = nil
            w.carry = 0
            w.queue.removeFirst()
            w.row = (w.row + 1) % rowCount
            // A newline costs about three visible characters.
            w.pauseUntil = now + 3.0 / (w.cps * speedMul)
            if w.queue.isEmpty { respawn(w) }
        }
    }

    // MARK: Spinner

    private func startCycle(freshVerb: Bool) {
        phase = .working
        phaseStart = now
        // Exponential tail: median ~100s, but the occasional marathon run.
        workDuration = ProcessInfo.processInfo.environment["CODESAVER_WORKDUR"].flatMap(Double.init)
            ?? expTail(base: 50, mean: 70, cap: 600)
        doneDuration = rand(7, 14)
        if freshVerb, !verbs.isEmpty {
            var next = Int.random(in: 0..<verbs.count)
            if verbs.count > 1 && next == verbIndex { next = (next + 1) % verbs.count }
            verbIndex = next
        }
        tokens = 0
        tokensCeil = rand(900, 5200)
        tokensTau = rand(24, 42)
        arrowIsDown = true
        nextArrowFlip = now + expTail(base: 6, mean: 9, cap: 90)
        statusVisible = true
        nextStatusRoll = now + rand(3, 7)
        statusShowing = false
        parenDelay = rand(1.2, 4.0)
    }

    private func updateSpinner(dt: Double) {
        switch phase {
        case .working:
            // The counter holds at zero until the first "response chunk" arrives.
            if now - phaseStart >= parenDelay {
                // Asymptotic growth: fast at first, flattening toward a ceiling
                // that itself creeps so the number never fully stalls. Upload
                // bursts (↑) surge — the ceiling races ahead and the counter
                // chases it hard, permanently raising the trajectory.
                let upload = !arrowIsDown
                tokensCeil += (upload ? 26.0 : 2.5) * dt
                tokens += (tokensCeil - tokens) * dt / tokensTau * (upload ? 3.0 : 1.0)
            }
            if now >= nextArrowFlip {
                arrowIsDown.toggle()
                // Long-tailed dwells, still ~1:3 time ↑ vs ↓ on average. The
                // tail is what lets a ↓ stretch occasionally run past 30s and
                // reach "almost done coding".
                nextArrowFlip = now + (arrowIsDown
                    ? expTail(base: 6, mean: 9, cap: 90)
                    : expTail(base: 2, mean: 2, cap: 20))
            }
            if now >= nextStatusRoll {
                statusVisible = Double.random(in: 0...1) < 0.78
                nextStatusRoll = now + rand(3, 7)
            }
            // Entering the "coding…" state restarts its escalation clock.
            let showing = statusVisible && arrowIsDown && now - phaseStart >= parenDelay
            if showing && !statusShowing { statusEnteredAt = now }
            statusShowing = showing
            if now - phaseStart >= workDuration {
                frozenDoneText = "\u{273B} \(verbs[verbIndex].past) for \(timeString(workDuration))"
                phase = .done
                phaseStart = now
                // Request finished: most of the corpus subset refreshes — the
                // next task arrives with mostly new context, a little carryover.
                rotateSubset(fraction: 0.7)
            }
        case .done:
            if now - phaseStart >= doneDuration {
                startCycle(freshVerb: true)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    private func countString(_ v: Double) -> String {
        let n = Int(v)
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", v / 1000)
    }

    private func statusText(since: Double) -> String {
        if since < 12 { return "coding with xhigh effort" }
        if since < 30 { return "still coding with xhigh effort" }
        return "almost done coding with xhigh effort"
    }

    // MARK: Drawing

    private var loggedFirstDraw = false

    public override func draw(_ rect: NSRect) {
        if !loggedFirstDraw {
            loggedFirstDraw = true
            viewLog.notice("first draw — bounds \(Double(self.bounds.width), privacy: .public)×\(Double(self.bounds.height), privacy: .public)")
        }
        ensureSetup()
        bgColor.setFill()
        bounds.fill()
        guard !rows.isEmpty else { return }

        drawRows()
        drawVignette()
        if clockVisible { drawClock() }
        drawSpinnerPanel()
    }

    // MARK: Clock

    /// Bottom edge of the clock as last drawn; the spinner panel's safe area
    /// is measured from this.
    private var clockBottom: CGFloat = 0

    private static func dateFmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }
    private static let fmtWeekday = dateFmt("EEE")
    private static let fmtMonth = dateFmt("MMM")

    private func monoFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let names: [NSFont.Weight: String] = [
            .light: "SFMono-Light", .regular: "SFMono-Regular",
            .medium: "SFMono-Medium", .semibold: "SFMono-Semibold",
        ]
        if let n = names[weight], let f = NSFont(name: n, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // The box content changes once per second, but building it (formatters,
    // grid, ~150 attributed runs, font lookups) plus rasterizing its shadow
    // blurs measured ~12ms/frame at 5K — so the ENTIRE build sits behind a
    // 1Hz content key, and the per-frame work is a single image blit.
    private struct ClockCache {
        let key: String
        let image: CGImage
        let blitRect: NSRect
        let bottom: CGFloat
    }
    private var clockCache: ClockCache?

    /// BGRA little-endian context: the backing store's native layout, so
    /// blits are copies rather than per-pixel format conversions.
    private static func makeBGRAContext(pw: Int, ph: Int) -> CGContext? {
        CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Blits a cached CGImage under a positive y-scale — a flipped CTM knocks
    /// CG off its fast path (measured 10x slower). The rect is snapped to
    /// device pixels and sized exactly to the image: a fractional origin or
    /// any scaling forces per-pixel resampling (measured ~8x slower).
    private func blit(_ image: CGImage, in rect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = CGFloat(image.width) / scale
        let h = CGFloat(image.height) / scale
        let x = (rect.origin.x * scale).rounded() / scale
        let yTop = (rect.origin.y * scale).rounded() / scale
        cg.saveGState()
        cg.interpolationQuality = .none
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: NSRect(x: x, y: bounds.height - yTop - h, width: w, height: h))
        cg.restoreGState()
    }

    private func drawClock() {
        let date = Date()
        // Gregorian explicitly: day/year numerics must match the POSIX-locale
        // month/weekday names (a Buddhist-calendar system yields year 2569).
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second, .day, .year], from: date)
        let hh = c.hour ?? 0
        let hourStr = use24Hour ? String(format: "%02d", hh) : "\(hh % 12 == 0 ? 12 : hh % 12)"
        let minStr = String(format: "%02d", c.minute ?? 0)
        let secStr = String(format: "%02d", c.second ?? 0)
        let scale = window?.backingScaleFactor ?? 2

        let key = "\(hourStr):\(minStr):\(secStr)|\(c.day ?? 0)|\(use24Hour)|" +
            "\(Int(bounds.width))x\(Int(bounds.height))|\(scale)|\(clockScale)|\(clockPadCells)|" +
            "\(clockVPadRows)|\(clockBackdropAlpha)|\(clockBorderWhite)|\(clockDigitWhite)|\(clockTopFrac)"
        if clockCache?.key != key {
            clockCache = buildClockCache(key: key, date: date, components: c,
                                         hourStr: hourStr, minStr: minStr, secStr: secStr, scale: scale)
        }
        guard let cache = clockCache else { return }
        blit(cache.image, in: cache.blitRect)
        clockBottom = cache.bottom
    }

    private func buildClockCache(key: String, date: Date, components c: DateComponents,
                                 hourStr: String, minStr: String, secStr: String,
                                 scale: CGFloat) -> ClockCache? {
        let h = bounds.height
        let hh = c.hour ?? 0
        let ampm = hh < 12 ? "AM" : "PM"
        let wd = Self.fmtWeekday.string(from: date)
        let mo = Self.fmtMonth.string(from: date)
        let day = c.day ?? 1

        // Soft dark halo so the clock stays readable over glowing code.
        let scrim = NSShadow()
        scrim.shadowColor = NSColor.black.withAlphaComponent(0.9)
        scrim.shadowBlurRadius = h * 0.02
        scrim.shadowOffset = .zero

        // ── TUI clock box ────────────────────────────────────────────────
        // ╭─ /* Sat Jul 11 2026 */ ──────────╮
        // │   time in half-block digits      │
        // ╰────────────────────────── PM ─╯
        let f = monoFont(h * clockScale, .regular)
        let charW = ("\u{2588}" as NSString).size(withAttributes: [.font: f]).width
        // Slightly tighter than the natural line height so half-block rows
        // tile without seams (overdraw between rows is invisible).
        let step = (f.ascender - f.descender) * 0.9

        let timeStr = "\(hourStr):\(minStr):\(secStr)"
        let dateStr = "/* \(wd) \(mo) \(day) \(c.year ?? 0) */"
        // AM/PM trails the seconds after one gap column, on the bottom row.
        // Element: [1 lpad][digits][1 gap][AM/PM], padded symmetrically.
        let suffix = use24Hour ? "" : " \(ampm)"

        // Build the 5-row bit grid, remembering what each column belongs to.
        enum Seg { case digit, colon, seconds, gap }
        var grid = Array(repeating: "", count: 5)
        var colSeg: [Seg] = []
        var colons = 0
        for ch in timeStr {
            guard let bits = Self.blockGlyphs[ch] else { continue }
            let seg: Seg
            if ch == ":" { colons += 1; seg = .colon } else { seg = colons >= 2 ? .seconds : .digit }
            for r in 0..<5 { grid[r] += bits[r] }
            colSeg.append(contentsOf: Array(repeating: seg, count: bits[0].count))
            for r in 0..<5 { grid[r] += "0" }
            colSeg.append(.gap)
        }
        if colSeg.last == .gap {
            for r in 0..<5 { grid[r].removeLast() }
            colSeg.removeLast()
        }

        let gridW = colSeg.count
        // The time element is [1 leading blank][digits][AM/PM] — the blank
        // counterweights the 2-col meridian — and symmetric padding wraps the
        // whole element.
        let lead = suffix.isEmpty ? 0 : 1
        let elementW = lead + gridW + suffix.count
        let inner = max(elementW + Int(clockPadCells) * 2, dateStr.count + 4)
        let leftPad = (inner - elementW) / 2 + lead
        let rightPad = inner - elementW - (leftPad - lead)

        // Opaque colors: rows overlap slightly to avoid seams, and translucent
        // glyphs would double-composite into visible bands where they do.
        // Colon/seconds derive from digit brightness to keep the hierarchy.
        let borderC = NSColor(white: clockBorderWhite, alpha: 1)
        let dateC = NSColor(deviceRed: 0.31, green: 0.35, blue: 0.39, alpha: 1)
        let cellC: [Seg: NSColor] = [
            .digit: NSColor(white: clockDigitWhite, alpha: 1),
            .colon: NSColor(white: clockDigitWhite * 0.48, alpha: 1),
            .seconds: NSColor(white: clockDigitWhite * 0.63, alpha: 1),
            .gap: .clear,
        ]

        func run(_ s: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .shadow: scrim])
        }

        var rows: [NSAttributedString] = []

        // Heavy box drawing, square corners; date centered in the top rail.
        let top = NSMutableAttributedString()
        let dateFill = max(0, inner - dateStr.count - 2)
        let dateLeft = dateFill / 2
        top.append(run("\u{250F}" + String(repeating: "\u{2501}", count: dateLeft) + " ", borderC))
        top.append(run(dateStr, dateC))
        top.append(run(" " + String(repeating: "\u{2501}", count: dateFill - dateLeft) + "\u{2513}", borderC))
        rows.append(top)

        let emptyRow = run("\u{2503}" + String(repeating: " ", count: inner) + "\u{2503}", borderC)
        for _ in 0..<clockVPadRows { rows.append(emptyRow) }

        // 5 grid rows → 3 text rows of half-blocks.
        for tr in 0..<3 {
            let topBits = Array(grid[tr * 2])
            let botBits = tr * 2 + 1 < 5 ? Array(grid[tr * 2 + 1]) : Array(repeating: Character("0"), count: gridW)
            let line = NSMutableAttributedString()
            line.append(run("\u{2503}" + String(repeating: " ", count: leftPad), borderC))
            for i in 0..<gridW {
                let t = topBits[i] == "1", b = botBits[i] == "1"
                let ch = t && b ? "\u{2588}" : t ? "\u{2580}" : b ? "\u{2584}" : " "
                line.append(run(ch, cellC[colSeg[i]] ?? .white))
            }
            if !suffix.isEmpty {
                // AM/PM occupies the bottom text row only.
                line.append(tr == 2
                    ? run(suffix, NSColor(white: 0.44, alpha: 1))
                    : run(String(repeating: " ", count: suffix.count), borderC))
            }
            line.append(run(String(repeating: " ", count: rightPad) + "\u{2503}", borderC))
            rows.append(line)
        }

        for _ in 0..<clockVPadRows { rows.append(emptyRow) }

        rows.append(run("\u{2517}" + String(repeating: "\u{2501}", count: inner) + "\u{251B}", borderC))

        let boxW = CGFloat(inner + 2) * charW
        let x0 = (bounds.width - boxW) / 2
        let topY = h * clockTopFrac
        let backdrop = NSRect(x: x0 - charW * 0.6, y: topY - step * 0.25,
                              width: boxW + charW * 1.2, height: CGFloat(rows.count) * step + step * 0.5)
        // Padding around the cached raster so the scrim halos aren't clipped.
        let pad = h * 0.045
        guard let image = Self.rasterizeClock(
            rows: rows, backdropSize: backdrop.size, pad: pad, step: step,
            inset: NSPoint(x: charW * 0.6, y: step * 0.25),
            backdropAlpha: clockBackdropAlpha, scale: scale
        ) else { return nil }
        return ClockCache(key: key, image: image,
                          blitRect: backdrop.insetBy(dx: -pad, dy: -pad),
                          bottom: topY + CGFloat(rows.count) * step)
    }

    /// Renders backdrop + box rows (including their shadow blurs) into a
    /// retina CGImage, so per-frame cost is a single blit.
    private static func rasterizeClock(rows: [NSAttributedString], backdropSize: NSSize,
                                       pad: CGFloat, step: CGFloat, inset: NSPoint,
                                       backdropAlpha: CGFloat, scale: CGFloat) -> CGImage? {
        let size = NSSize(width: backdropSize.width + pad * 2, height: backdropSize.height + pad * 2)
        let pw = max(1, Int(size.width * scale)), ph = max(1, Int(size.height * scale))
        guard let cg = makeBGRAContext(pw: pw, ph: ph) else { return nil }

        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(ph))
        cg.scaleBy(x: scale, y: -scale)

        NSColor.black.withAlphaComponent(backdropAlpha).setFill()
        NSBezierPath(roundedRect: NSRect(origin: NSPoint(x: pad, y: pad), size: backdropSize),
                     xRadius: 2, yRadius: 2).fill()
        for (i, row) in rows.enumerated() {
            row.draw(at: NSPoint(x: pad + inset.x, y: pad + inset.y + CGFloat(i) * step))
        }

        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage()
    }

    /// 3×5 bitmaps for the block digits (colon is a single column).
    private static let blockGlyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "011", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
        "7": ["111", "001", "001", "010", "010"],
        "8": ["111", "101", "111", "101", "111"],
        "9": ["111", "101", "111", "001", "111"],
        ":": ["0", "1", "0", "1", "0"],
    ]

    private func drawRows() {
        let maxY = bounds.height - lineH
        for (i, segs) in rows.enumerated() {
            let y = topInset + CGFloat(i) * lineH
            if y > maxY { break }
            for seg in segs {
                guard !seg.chars.isEmpty, seg.typed > 0 || seg.isActive else { continue }
                segmentString(seg).draw(at: NSPoint(x: leftInset + CGFloat(seg.xCol) * charW, y: y))
            }
        }
    }

    private func segmentString(_ slot: Segment) -> NSAttributedString {
        let visible = slot.typed
        let result = NSMutableAttributedString()

        let age = max(0, now - slot.settledAt)
        var baseAlpha: CGFloat = slot.isActive
            ? codeActiveAlpha
            : codeSettledFloor + codeSettledBoost * CGFloat(exp(-age / Double(codeFadeTau)))
        if slot.isComment { baseAlpha *= codeCommentDim }
        let tinted = NSColor(
            deviceRed: min(1, 0.58 + slot.tint * 0.3),
            green: 0.65,
            blue: min(1, 0.72 - slot.tint),
            alpha: 1
        )
        let settledColor = tinted.withAlphaComponent(baseAlpha)

        // Heat: 1 while typing, cools quickly after the line completes.
        let heat = slot.isActive ? 1.0 : exp(-max(0, now - slot.typingDoneAt) / 0.55)
        let trailLen = 8
        let cutoff = heat > 0.03 ? max(0, visible - trailLen) : visible

        if cutoff > 0 {
            result.append(NSAttributedString(
                string: String(slot.chars[0..<cutoff]),
                attributes: [.font: font!, .foregroundColor: settledColor]
            ))
        }
        if cutoff < visible {
            for k in cutoff..<visible {
                let d = visible - 1 - k
                let b = min(1, pow(0.70, CGFloat(d)) * CGFloat(heat) * codeGlowStrength)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font!,
                    .foregroundColor: settledColor.mixed(with: glowText, 0.85 * b)
                        .withAlphaComponent(baseAlpha + (1 - baseAlpha) * b),
                ]
                if b > 0.12 {
                    let shadow = NSShadow()
                    shadow.shadowColor = glowHalo.withAlphaComponent(0.85 * b)
                    shadow.shadowBlurRadius = font.pointSize * 0.6 * b
                    shadow.shadowOffset = .zero
                    attrs[.shadow] = shadow
                }
                result.append(NSAttributedString(string: String(slot.chars[k]), attributes: attrs))
            }
        }

        if slot.isActive || now - slot.typingDoneAt < 0.3 {
            let shadow = NSShadow()
            shadow.shadowColor = glowHalo.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = font.pointSize * 0.7
            shadow.shadowOffset = .zero
            result.append(NSAttributedString(string: "\u{258A}", attributes: [
                .font: font!,
                .foregroundColor: cursorColor.withAlphaComponent(0.85),
                .shadow: shadow,
            ]))
        }
        return result
    }

    // The radial gradient rasterizes every pixel per frame (~72ms at 5K —
    // measured as 72% of total frame cost), so it's cached as an exact
    // backing-pixel CGImage and blitted. The image is radially symmetric, so
    // the flipped context doesn't matter.
    private var vignetteImage: CGImage?
    private var vignetteKey = ""

    private func drawVignette() {
        guard vignetteMax > 0.01 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
        guard pw > 0, ph > 0 else { return }
        let key = "\(pw)x\(ph)@\(vignetteMax)"
        if key != vignetteKey || vignetteImage == nil {
            vignetteImage = Self.renderVignette(pw: pw, ph: ph, maxAlpha: vignetteMax)
            vignetteKey = key
        }
        guard let img = vignetteImage else { return }
        blit(img, in: bounds)
    }

    private static func renderVignette(pw: Int, ph: Int, maxAlpha: CGFloat) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        // BGRA little-endian: the backing store's native layout, so the
        // per-frame blit is a copy, not a 15-megapixel format conversion.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: bitmapInfo),
              let gradient = CGGradient(colorsSpace: cs, colors: [
                  CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                  CGColor(red: 0, green: 0, blue: 0, alpha: maxAlpha * 0.12),
                  CGColor(red: 0, green: 0, blue: 0, alpha: maxAlpha),
              ] as CFArray, locations: [0, 0.55, 1])
        else { return nil }
        let center = CGPoint(x: CGFloat(pw) / 2, y: CGFloat(ph) / 2)
        // Matches NSGradient's radial draw(in:relativeCenterPosition: .zero):
        // the end color lands exactly at the corners.
        let radius = hypot(CGFloat(pw), CGFloat(ph)) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
        return ctx.makeImage()
    }

    // MARK: Spinner rendering

    private func spinnerAttributedString() -> NSAttributedString {
        switch phase {
        case .working: return workingString()
        case .done: return doneString()
        }
    }

    private func dimAttrs(_ alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: uiFont!, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
    }

    /// Per-character left-to-right glow sweep over the verb.
    private func appendGlowingVerb(_ text: String, to result: NSMutableAttributedString, intensity: Double) {
        let chars = Array(text)
        let period = Double(chars.count) + 16
        let pos = (now * 13).truncatingRemainder(dividingBy: period) - 5
        for (i, ch) in chars.enumerated() {
            let d = Double(i) - pos
            let b = CGFloat(exp(-(d * d) / (2 * 1.9 * 1.9)) * intensity)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: uiBoldFont!,
                .foregroundColor: accent.mixed(with: glowText, 0.9 * b),
            ]
            if b > 0.1 {
                let shadow = NSShadow()
                shadow.shadowColor = accentHot.withAlphaComponent(0.9 * b)
                shadow.shadowBlurRadius = uiFont.pointSize * 0.65 * b
                shadow.shadowOffset = .zero
                attrs[.shadow] = shadow
            }
            result.append(NSAttributedString(string: String(ch), attributes: attrs))
        }
    }

    private func workingString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let elapsed = now - phaseStart
        let verb = verbs[verbIndex]

        // Animated glyph: cosine phase, period 2000 ms, eased at both ends.
        let spinnerPhase = (1 - cos(2 * Double.pi * now / 2.0)) / 2
        let frame = Self.spinnerFrames[Int((spinnerPhase * 5).rounded())]
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = accentHot.withAlphaComponent(0.8)
        glyphShadow.shadowBlurRadius = uiFont.pointSize * 0.5
        glyphShadow.shadowOffset = .zero
        result.append(NSAttributedString(string: frame + " ", attributes: [
            .font: uiBoldFont!,
            .foregroundColor: accent.mixed(with: accentHot, 0.3),
            .shadow: glyphShadow,
        ]))

        appendGlowingVerb(verb.ing + "\u{2026}", to: result, intensity: 1.0)

        // API latency: nothing but the spinner and the verb until the first
        // response chunk arrives.
        guard elapsed >= parenDelay else { return result }

        let sep = dimAttrs(0.26)
        let val = dimAttrs(0.5)
        result.append(NSAttributedString(string: " (", attributes: sep))
        result.append(NSAttributedString(string: timeString(elapsed), attributes: val))
        result.append(NSAttributedString(string: " \u{B7} ", attributes: sep))
        // One shared counter — an arrow flip changes direction, never the number.
        let arrow = arrowIsDown ? "\u{2193}" : "\u{2191}"
        result.append(NSAttributedString(string: "\(arrow) \(countString(tokens)) tokens", attributes: val))
        if statusShowing {
            result.append(NSAttributedString(string: " \u{B7} ", attributes: sep))
            result.append(NSAttributedString(
                string: statusText(since: now - statusEnteredAt),
                attributes: dimAttrs(0.42)
            ))
        }
        result.append(NSAttributedString(string: ")", attributes: sep))
        return result
    }

    private func doneString() -> NSAttributedString {
        // Finished state is deliberately quiet: one flat grey, regular weight,
        // no glow — the rest between cycles.
        NSAttributedString(string: frozenDoneText, attributes: [
            .font: uiFont!,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
    }

    private func drawSpinnerPanel() {
        let text = spinnerAttributedString()
        let size = text.size()
        let padH: CGFloat = uiFont.pointSize * 1.7
        let padV: CGFloat = uiFont.pointSize * 1.05
        // Who owns the top of the screen decides where the panel centers:
        // our clock here → center in what remains below it; our clock enabled
        // but on another display → nothing owns the top (enabling our clock
        // implies the user disabled the system one), so center exactly; clock
        // disabled → the system lock-screen clock owns the top, center in
        // what remains. The 17% is not the clock's measured extent (it spans
        // roughly 22% of screen height) but its visual weight: reserving 17%
        // is what makes the panel *feel* centered under it.
        let textY: CGFloat
        if clockVisible {
            let safeTop = clockBottom + lineH * panelGapMult
            // Bias is expressed in clock-cell units so it scales with the clock.
            textY = safeTop + (bounds.height - safeTop - size.height) / 2
                + bounds.height * clockScale * panelBias
        } else if showClock {
            textY = (bounds.height - size.height) / 2
        } else {
            let safeTop = bounds.height * 0.17
            textY = safeTop + (bounds.height - safeTop - size.height) / 2
                + bounds.height * clockScale * panelBias
        }
        let panel = NSRect(
            x: (bounds.width - size.width) / 2 - padH,
            y: textY - padV,
            width: size.width + padH * 2,
            height: size.height + padV * 2
        )

        drawPanelBackdrop(panel)

        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: textY))
    }

    // The panel's fill + stroke + 26px drop shadow depend only on its size,
    // which changes about once a second — cache the raster, blit per frame.
    private var panelCacheImage: CGImage?
    private var panelCacheKey = ""

    private func drawPanelBackdrop(_ panel: NSRect) {
        let shadowPad: CGFloat = 40
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(Int(panel.width))x\(Int(panel.height))@\(scale)"
        if key != panelCacheKey || panelCacheImage == nil {
            let size = NSSize(width: panel.width + shadowPad * 2, height: panel.height + shadowPad * 2)
            let pw = max(1, Int(size.width * scale)), ph = max(1, Int(size.height * scale))
            if let cg = Self.makeBGRAContext(pw: pw, ph: ph) {
                let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                cg.saveGState()
                cg.translateBy(x: 0, y: CGFloat(ph))
                cg.scaleBy(x: scale, y: -scale)
                let local = NSRect(x: shadowPad, y: shadowPad, width: panel.width, height: panel.height)
                let drop = NSShadow()
                drop.shadowColor = NSColor.black.withAlphaComponent(0.75)
                drop.shadowBlurRadius = 26
                drop.shadowOffset = .zero
                drop.set()
                let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
                NSColor.black.withAlphaComponent(0.68).setFill()
                path.fill()
                NSShadow().set()
                NSColor.white.withAlphaComponent(0.09).setStroke()
                path.lineWidth = 1
                path.stroke()
                cg.restoreGState()
                NSGraphicsContext.restoreGraphicsState()
                panelCacheImage = cg.makeImage()
            }
            panelCacheKey = key
        }
        guard let img = panelCacheImage else { return }
        blit(img, in: panel.insetBy(dx: -shadowPad, dy: -shadowPad))
    }
}
