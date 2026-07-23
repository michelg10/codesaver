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
    /// Boom debris: fades white → grey → gone instead of aging like code.
    var fading = false
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

// MARK: - Boom session

/// One boom per saver activation, shared by every display's view. The first
/// view to wake reads the igniter's capture manifest, builds a single
/// BoomCore spanning all displays, and anchors the shared clock; sibling
/// views attach to it. Every view derives sim time from the same monotonic
/// anchor, so three displays act as one machine.
final class BoomSession {
    enum Kind: String { case idle, corner }

    let core: BoomCore
    let backdrops: [Int: CGImage]    // field index → captured desktop
    /// The mapped raw captures behind those images — the Metal renderers
    /// read these pages directly as zero-copy textures.
    let backdropBuffers: [Int: BoomCaptureBuffer]
    let kind: Kind
    let verb: String
    let armDuration: Double          // idle: 5 s pre-animation; corner: none

    /// Wall anchor of the shared clock — nil until every display is ready.
    /// Activation is a burst of work on one main thread (session load, window
    /// migration, pipeline warm-up, backdrop uploads); anchoring at creation
    /// let the countdown burn through it, so late displays joined mid-show
    /// and the init stalls made the boom judder and de-sync. The clock now
    /// starts only when the whole stage is set.
    private var anchorMedia: Double?
    private var readyFields = Set<Int>()
    private let createdMedia = CACurrentMediaTime()
    /// A display that never reports (asleep, mirrored, host quirk, staging
    /// failure) must not hold the show hostage: the clock starts this many
    /// seconds after session creation no matter what.
    private static let readyBackstop = 4.0

    /// Shared sim seconds: negative while armed, 0 at detonation. Before the
    /// anchor exists the clock holds just shy of its start — the armed scene
    /// (or, for corner triggers, the pre-detonation beat) freezes in place.
    var simTime: Double { simTime(at: CACurrentMediaTime()) }

    /// Sim seconds at a given host time — the frame clock passes the vsync
    /// timestamp so per-frame sim steps stay exactly even (wall-clock
    /// callback jitter must not leak into tick counts).
    func simTime(at wall: Double) -> Double {
        guard let anchor = anchorMedia else { return min(-0.05, -armDuration) }
        let t = wall - anchor - armDuration
        // Boom time (t ≥ 0) runs through the slow-motion dilation; the armed
        // countdown stays wall-clock. Continuous at t = 0.
        return t < 0 ? t : t / CodeSaverView.boomTimeScale
    }

    /// Until the anchor exists every display holds pure black — the reveal
    /// (all desktops at once, same tick) is the show's actual first frame.
    var isAnchored: Bool { anchorMedia != nil }

    // (A deadViews fast-path used to live here — views reporting their own
    // clocks dead so the anchor stopped waiting for them. The screen-link +
    // adoption machinery made every commissioned view stageable, its call
    // sites evaporated, and "my view-link died" stopped implying "my display
    // isn't coming". A display that truly never stages now costs the
    // readyBackstop, which is the honest signal.)

    /// A view reports its display fully staged: field bound (post-migration,
    /// so the origin match is real), textures uploaded, frames rendering.
    /// The clock anchors when every display's field has reported.
    func markReady(_ fieldIndex: Int) {
        guard anchorMedia == nil else { return }
        if readyFields.insert(fieldIndex).inserted {
            viewLog.notice("boom display ready: field \(fieldIndex, privacy: .public) (\(self.readyFields.count, privacy: .public)/\(self.core.fields.count, privacy: .public))")
            BoomDiag.log("ready: field \(fieldIndex) (\(readyFields.count)/\(core.fields.count))")
        }
        maybeAnchor("all live displays staged")
    }

    private func maybeAnchor(_ reason: String) {
        guard anchorMedia == nil else { return }
        guard readyFields.count >= max(1, core.fields.count) else { return }
        anchorMedia = CACurrentMediaTime()
        viewLog.notice("boom clock anchored")
        BoomDiag.log("anchored — \(reason) (ready \(readyFields.count)/\(core.fields.count))")
    }

    /// Per-frame: fires the readiness backstop.
    func pollReadiness() {
        guard anchorMedia == nil,
              CACurrentMediaTime() - createdMedia > Self.readyBackstop else { return }
        anchorMedia = CACurrentMediaTime()
        viewLog.notice("boom clock anchored by backstop — ready: \(self.readyFields.count, privacy: .public)/\(self.core.fields.count, privacy: .public)")
        BoomDiag.log("anchored by BACKSTOP — ready \(readyFields.count)/\(core.fields.count)")
    }

    // The host parks every window at the main display's origin before
    // migrating it — so two views can transiently bind the SAME field. Only
    // the first claimant renders it; a stuck sibling holds black instead of
    // double-rendering the same content out of phase on top of the owner
    // (two independent ~30 fps clocks compositing = beat-frequency stutter).
    // Claims EXPIRE: a view whose display link dies (its window parked on a
    // display that isn't compositing) must not hold a field hostage — the
    // live view actually on that display steals the claim within half a
    // second. Renewed on every rendered frame.
    private var fieldOwners: [Int: (owner: ObjectIdentifier, at: Double)] = [:]

    func claimField(_ index: Int, by owner: ObjectIdentifier) -> Bool {
        let now = CACurrentMediaTime()
        if let current = fieldOwners[index], current.owner != owner {
            guard now - current.at >= 0.5 else { return false }
            BoomDiag.log("field \(index) claim STOLEN from a stalled view")
        }
        fieldOwners[index] = (owner, now)
        return true
    }

    func releaseField(_ index: Int, by owner: ObjectIdentifier) {
        if fieldOwners[index]?.owner == owner { fieldOwners[index] = nil }
    }

    /// A field nobody (alive) is rendering — what a view whose window never
    /// migrated adopts by elimination.
    func unclaimedField(count: Int) -> Int? {
        let now = CACurrentMediaTime()
        return (0..<count).first {
            fieldOwners[$0] == nil || now - fieldOwners[$0]!.at > 0.5
        }
    }

    static var shared: BoomSession?
    private static var attempted = false

    private init(core: BoomCore, backdrops: [Int: CGImage],
                 backdropBuffers: [Int: BoomCaptureBuffer], kind: Kind, verb: String) {
        self.core = core
        self.backdrops = backdrops
        self.backdropBuffers = backdropBuffers
        self.kind = kind
        self.verb = verb
        // Corner triggers get a beat too: the desktop fades in, settles on
        // screen for a moment, and only then burns — instead of flooding the
        // instant the reveal lands.
        self.armDuration = kind == .corner ? 1.5 : 5
    }

    /// Loads the manifest once per activation; all views share the result.
    /// The helper deletes the manifest the moment the user returns, so a
    /// fresh file means "the user has been away since this was captured".
    static func loadIfNeeded(codeLines: () -> [String], verbs: [String]) -> BoomSession? {
        if let shared { return shared }
        guard !attempted else { return nil }
        attempted = true
        let loadStart = CACurrentMediaTime()

        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CodeSaver")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("boom-manifest.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = obj["kind"] as? String, let kind = Kind(rawValue: kindRaw),
              let capturedAt = obj["capturedAt"] as? Double,
              let mouseX = obj["mouseX"] as? Double, let mouseY = obj["mouseY"] as? Double,
              let displayList = obj["displays"] as? [[String: Any]], !displayList.isEmpty
        else { return nil }
        // Corner captures are only fresh for moments; idle captures stay
        // valid as long as the user never came back (backstop: 6 h).
        let age = Date().timeIntervalSince1970 - capturedAt
        guard age > -5, age < (kind == .corner ? 20 : 6 * 3600) else { return nil }

        let origin = CGPoint(x: mouseX, y: mouseY)
        struct Disp { let x, y, w, h: Double; let image: String? }
        let disps: [Disp] = displayList.compactMap { d in
            guard let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let w = d["w"] as? Double, let h = d["h"] as? Double,
                  w > 8, h > 8 else { return nil }
            return Disp(x: x, y: y, w: w, h: h, image: d["image"] as? String)
        }
        // Grids on the main thread (font metrics); the per-display work fans
        // out across cores. Raw captures ("CSRW", written by the igniter) are
        // mmap'd — no decode at all, the pixels are the helper's own decoded
        // buffer still sitting in the page cache; legacy/stand-in images
        // fall back to an actual decode. Colorize is the only real work left.
        let grids = disps.map { BoomGrid(size: CGSize(width: $0.w, height: $0.h)) }
        var decoded = [(color: [UInt32], image: CGImage, buffer: BoomCaptureBuffer?)?](
            repeating: nil, count: disps.count)
        decoded.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: disps.count) { i in
                guard let name = disps[i].image else { return }
                let url = dir.appendingPathComponent(name)
                if name.hasSuffix(".raw"), let mapped = BoomCaptureBuffer.map(url),
                   let cg = mapped.makeImage() {
                    buf[i] = (BoomCore.colorize(cg, grid: grids[i]), cg, mapped)
                    return
                }
                guard let img = NSImage(contentsOf: url),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }
                buf[i] = (BoomCore.colorize(cg, grid: grids[i]), cg, nil)
            }
        }
        var fields: [BoomField] = []
        var backdrops: [Int: CGImage] = [:]
        var buffers: [Int: BoomCaptureBuffer] = [:]
        var radius: CGFloat = 0
        for (i, d) in disps.enumerated() {
            var color = [UInt32](repeating: 0, count: grids[i].cols * grids[i].rows)
            if let dec = decoded[i] {
                color = dec.color
                backdrops[fields.count] = dec.image
                buffers[fields.count] = dec.buffer
            }
            fields.append(BoomField(grid: grids[i], originCG: CGPoint(x: d.x, y: d.y),
                                    color: color))
            for c in [CGPoint(x: d.x, y: d.y), CGPoint(x: d.x + d.w, y: d.y),
                      CGPoint(x: d.x, y: d.y + d.h), CGPoint(x: d.x + d.w, y: d.y + d.h)] {
                radius = max(radius, hypot(c.x - origin.x, c.y - origin.y))
            }
        }
        // No captured images at all (e.g. Screen Recording was denied when
        // the helper armed): a boom over pure black isn't a show — start the
        // saver normally instead.
        guard !fields.isEmpty, !backdrops.isEmpty else { return nil }

        let core = BoomCore(
            params: BoomCore.Params(originCG: origin, radius: max(radius, 1),
                                    seed: UInt64(abs(capturedAt * 1000)) | 1,
                                    codeLines: codeLines()),
            fields: fields)
        let session = BoomSession(core: core, backdrops: backdrops,
                                  backdropBuffers: buffers, kind: kind,
                                  verb: verbs.randomElement() ?? "Idling")
        shared = session
        BoomDiag.log(String(format: "session load: kind=%@ displays=%d mapped-raw=%d took %.1f ms",
                            kind.rawValue, fields.count, buffers.count,
                            (CACurrentMediaTime() - loadStart) * 1000))
        return session
    }
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

    // MARK: Boom intro
    // The saver can open with the two-boom ignition (see BoomCore.swift): an
    // idle status line at the (former) mouse position detonates; the first
    // cell-quantized front converts the desktop into terminal cells, the
    // second wipes them to black, flung glyphs travel through the grid and
    // settle, the line zaps to its home panel in whole-cell hops, and the
    // writers ignite in the second front's wake. Armed by the igniter helper
    // (serialized BoomCore handoff), the CODESAVER_BOOM env var (snapshots),
    // or a click in the preview window.

    public var boomWave1 = 0.85 * BoomCore.tempo               // first front's sweep, s
    public var boomGap = BoomCore.gapBase * BoomCore.tempo     // detonation → second front, s
    public var boomWave2 = BoomCore.wave2Base * BoomCore.tempo // second front's sweep, s
    public var boomDebrisDensity: Double = 0.065 // fling chance per revealed cell

    /// Slow-motion INSPECTION lever only — dilating the clock spreads the
    /// 60 Hz sim ticks over more wall time, so cell-quantized motion drops
    /// below full frame rate (at 3×, effectively 20 fps). Real pacing lives
    /// in BoomCore.tempo, which stretches the choreography at full tick
    /// rate. Keep this at 1 outside debugging sessions.
    static let boomTimeScale: Double = 1

    private enum Intro { case none, armed, boom }
    private var intro = Intro.none
    private var boomOriginNorm = CGPoint(x: 0.5, y: 0.55)  // fraction of bounds
    private var armEndsAt: Double = 0         // sim time of detonation
    private var armTotal: Double = 5          // full armed length (choreography clock)
    private var cursorRaster: CGImage?        // arrow cursor, rasterized once per scale
    private var cursorRasterScale: CGFloat = 0
    private var boomStart: Double = 0
    private var handoffChecked = false
    private var boomSession: BoomSession?
    private var boomCore: BoomCore?
    private var boomFieldIndex = 0
    /// This view's display origin in global CG coords (zero outside handoff).
    private var viewOriginCG = CGPoint.zero

    // Metal is THE renderer — no CPU fallback (it was pure mirror overhead;
    // every Mac this runs on has a GPU). If Metal init ever fails, the view
    // stays black and logs; that's the whole degradation story.
    private static var metalDisabled = false
    private var boomMetal: BoomMetalRenderer?
    private var metalHost: BoomMetalHostView?

    private var metalActive: Bool { boomMetal != nil && metalHost != nil }

    private let viewBirth = CACurrentMediaTime()

    /// Short per-view tag so multi-display diag streams are attributable.
    private lazy var diagID = String(format: "v%04x",
                                     UInt16(truncatingIfNeeded: ObjectIdentifier(self).hashValue))

    /// Session runs hold pure black until every display has staged: the
    /// reveal — all desktops in the same tick — is the show's first frame,
    /// instead of backdrops popping in one at a time as windows come up.
    private var introHoldingCurtain: Bool {
        intro == .armed && boomSession?.isAnchored == false
    }
    private var wasHoldingCurtain = false

    /// The reveal is a traditional fade: the desktops rise out of black
    /// together over this window, starting the moment the clock anchors —
    /// a hard cut from black read as an awkward blip.
    private static let revealFadeDuration = 0.45

    /// 0 → black, 1 → desktop fully on. Only session-armed runs fade; the
    /// boom itself (and local preview arms) run at full brightness.
    private var armedRevealProgress: Double {
        guard intro == .armed, let session = boomSession else { return 1 }
        guard session.isAnchored else { return 0 }
        return clampd((session.simTime + session.armDuration) / Self.revealFadeDuration, 0, 1)
    }

    private var resolvedBoomOrigin: NSPoint {
        // Session runs measure against the field's true display size — the
        // service window's bounds can briefly be the wrong display's.
        if let core = boomCore, boomSession != nil {
            let s = core.fields[boomFieldIndex].grid.size
            return NSPoint(x: boomOriginNorm.x * s.width, y: boomOriginNorm.y * s.height)
        }
        return NSPoint(x: boomOriginNorm.x * bounds.width, y: boomOriginNorm.y * bounds.height)
    }

    /// Whether the detonation point is on this view's display — the armed
    /// line and departure flash belong to that display alone.
    private var boomOriginOnThisDisplay: Bool {
        let o = resolvedBoomOrigin
        return o.x >= 0 && o.x < bounds.width && o.y >= 0 && o.y < bounds.height
    }

    /// When the second front reaches a point of this view, in sim seconds.
    private func boomSecondHit(ofLocal p: NSPoint) -> Double {
        guard let core = boomCore else { return 0 }
        return core.secondHit(ofGlobal: CGPoint(x: p.x + viewOriginCG.x,
                                                y: p.y + viewOriginCG.y))
    }

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
        configureIntroFromEnv()
        Self.warmBoomPipelines()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        loadResources()
        startCycle(freshVerb: true)
        configureIntroFromEnv()
        Self.warmBoomPipelines()
    }

    /// Shader compilation (~100 ms) off the main thread at launch, so the
    /// pipelines are ready before the intro asks for them — activation is
    /// already a burst of main-thread work.
    private static var warmedPipelines = false
    private static func warmBoomPipelines() {
        guard !metalDisabled, !warmedPipelines else { return }
        warmedPipelines = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = BoomMetalContext.shared
        }
    }

    // Non-opaque: the CAMetalLayer subview is the opaque surface. A view
    // whose frame clock has died hides that layer and becomes fully
    // transparent — so a zombie window stacked above a live one on the same
    // display can never black it out.
    public override var isOpaque: Bool { false }
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

    // The frame clock is a CADisplayLink pinned to 30 Hz — the display's
    // own beat, not a runloop timer. 30 divides the panel's refresh evenly,
    // so every displayed frame is exactly two vsyncs AND exactly two 60 Hz
    // sim ticks: perfectly even cell motion. (Runloop timers drift a few ms
    // per frame; floor'd against the 60 Hz sim grid that yielded 1/2/3-tick
    // frames — the jitter the eye catches on quantized motion.)
    private var displayLinkBox: Any?   // CADisplayLink (macOS 14+ class)
    private var legacyTimer: Timer?

    public override func animateOneFrame() {
        // The saver framework's own timer is one of the jittery clocks; its
        // callback is ignored — the display link drives.
    }

    /// Advances by wall-clock time and requests a redraw. Safe to call from
    /// multiple drivers: overlapping calls produce dt ≈ 0, not double speed.
    private var dtStats = (lo: 1.0, hi: 0.0, sum: 0.0, n: 0)
    /// The current frame's vsync-aligned timestamp (host time), so the sim
    /// clock steps on the display grid, not on jittery callback wall time.
    private var frameNow: Double = 0

    private func tick() {
        tick(at: CACurrentMediaTime())
    }

    private func tick(at t: Double) {
        frameNow = t
        let raw = lastWall == 0 ? 0 : t - lastWall
        let dt = lastWall == 0 ? animationTimeInterval : clampd(raw, 0, 0.25)
        lastWall = t
        // Cadence proof for the diag: a perfect 30 Hz shows ~33.3/33.3/33.3.
        if raw > 0 {
            dtStats.lo = min(dtStats.lo, raw)
            dtStats.hi = max(dtStats.hi, raw)
            dtStats.sum += raw
            dtStats.n += 1
            if dtStats.n >= 150 {
                BoomDiag.log(diagID + String(
                    format: " frame dt: avg %.2f ms, min %.2f, max %.2f (150 frames)",
                    dtStats.sum / Double(dtStats.n) * 1000,
                    dtStats.lo * 1000, dtStats.hi * 1000))
                dtStats = (1.0, 0.0, 0.0, 0)
            }
        }
        advance(by: dt)
        ensureMetalSurfaces()
        invalidateForFrame()
        renderMetalFrame()
    }

    // MARK: Metal intro surfaces

    /// The whole saver renders on Metal — boom AND steady state — so there
    /// is no renderer handoff (and no handoff hitch) when the intro ends:
    /// the same pipeline just stops drawing the field and keeps drawing the
    /// rows. Surfaces come up once per window and stay. The CG draw path
    /// remains intact underneath as the no-Metal fallback and the snapshot
    /// harness's reference.
    private func ensureMetalSurfaces() {
        guard window != nil, !Self.metalDisabled else { return }
        if boomMetal == nil {
            guard let ctx = BoomMetalContext.shared,
                  let renderer = BoomMetalRenderer(context: ctx) else {
                Self.metalDisabled = true
                viewLog.error("Metal unavailable — falling back to the CG renderer")
                return
            }
            boomMetal = renderer
            renderer.diagTag = diagID
        }
        if metalHost == nil {
            let host = BoomMetalHostView(frame: bounds)
            addSubview(host)
            metalHost = host
            setNeedsDisplay(bounds)   // the view itself paints black once
            BoomDiag.log("\(diagID) metal surfaces up (field \(boomFieldIndex))")
        }
    }

    /// Keeps the renderer bound to this view's current field — cheap identity
    /// checks per frame; real work only at attach and window migration.
    private func syncMetalContent() {
        guard let metal = boomMetal else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let core = boomCore {
            metal.bindFieldIfNeeded(core.fields[boomFieldIndex],
                                    backdrop: backdropSource,
                                    buffer: boomSession?.backdropBuffers[boomFieldIndex],
                                    scale: scale)
        } else if intro == .armed, let img = backdropSource {
            metal.bindBackdropOnly(img)
        }
    }

    private func renderMetalFrame() {
        guard let metal = boomMetal, let host = metalHost, let layer = host.metalLayer,
              bounds.width > 8, !rows.isEmpty else { return }
        syncMetalContent()
        let scale = window?.backingScaleFactor ?? 2
        // Only the field's owner renders it; a sibling stuck pre-migration
        // on the same field presents black — unless its display link is dead
        // (occluded window = invisible locally, yet still a real display's
        // compositor source), in which case it ADOPTS the unclaimed field:
        // the built-in gets its own content even though the host never told
        // us which display we are.
        var owns = boomSession?.claimField(boomFieldIndex, by: ObjectIdentifier(self)) ?? true
        if !owns, CACurrentMediaTime() - lastLinkFire > 0.7,
           CACurrentMediaTime() - viewBirth > 1.2,   // let migration/screens win first
           let session = boomSession, let core = boomCore,
           let free = session.unclaimedField(count: core.fields.count) {
            adoptField(free, session: session)
            owns = session.claimField(free, by: ObjectIdentifier(self))
            BoomDiag.log("\(diagID) adopted field \(free) by elimination (occluded window)")
            // syncMetalContent above bound the OLD field's textures; rebind
            // now or this frame paints the wrong display's content.
            syncMetalContent()
        }
        guard var frame = owns ? buildFrameInput(scale: scale)
                               : BoomMetalRenderer.FrameInput() else { return }
        if !owns { frame.holdBlack = true }
        metal.renderFrame(frame, core: intro != .none ? boomCore : nil,
                          fieldIndex: boomFieldIndex,
                          viewSize: bounds.size, scale: scale, into: layer)
        // Staged: our (post-migration) field is bound, textures live, frames
        // flowing. The session clock starts once every display says so.
        if owns, let session = boomSession, let core = boomCore,
           metal.isBound(to: core.fields[boomFieldIndex]) {
            session.markReady(boomFieldIndex)
        }
    }

    /// One frame of everything, as Metal inputs: the same decisions the CG
    /// path makes, emitted as glyph instances, fills, and UI-raster quads.
    private func buildFrameInput(scale: CGFloat) -> BoomMetalRenderer.FrameInput? {
        guard let metal = boomMetal else { return nil }
        metal.configureText(fontBase: font?.pointSize ?? 12, charW: charW,
                            lineH: lineH, scale: scale)
        // The pressure pulse — the "contained blowout" halo around the
        // statusline, fed into the glow field's a-channel. Origin display
        // only. Exponential ember tail: the 5-step shader quantization
        // makes the halo shrink inward through discrete brightness bands
        // instead of winking out.
        metal.blastPulse = nil
        if boomOriginOnThisDisplay, let core = boomCore {
            let g = core.fields[boomFieldIndex].grid
            let c = armedLineCenter
            let cell = (cx: Int((c.x - g.leftInset) / g.charW),
                        cy: Int((c.y - g.topInset) / g.lineH))
            if intro == .boom {
                let t = now - boomStart
                if t >= 0, t < 1.1 {
                    metal.blastPulse = (cell.cx, cell.cy,
                                        Float(3.2 * exp(-t / 0.35)), 14)
                }
            } else if intro == .armed, boomSession?.kind != .corner {
                // Phosphor for the cursor-glitch: the materializing glyph
                // glows, and the glow LINGERS faintly between reps —
                // phosphor doesn't know the glyph left.
                let a = armTotal - (armEndsAt - now)
                let slot = a < 1.3 ? -1 : Int((a - 1.3) * 30)
                var lvl: Float = 0
                if slot >= 3, slot < 14 {
                    let inRep = slot == 3 || slot == 4 || slot == 7
                        || slot == 8 || slot == 11 || slot == 12
                    lvl = inRep ? 1.0 : 0.45
                } else if slot >= 14 {
                    lvl = max(0, 0.9 - Float(slot - 14) * 0.12)
                }
                // Radius 3: a tight LED corona around the glyph, not a flood.
                if lvl > 0 { metal.blastPulse = (cell.cx, cell.cy, lvl, 3) }
            }
        }
        var frame = BoomMetalRenderer.FrameInput()
        frame.holdBlack = introHoldingCurtain
        frame.reveal = armedRevealProgress
        frame.vignetteMax = Double(vignetteMax)
        switch intro {
        case .none:
            frame.vignetteFactor = 1
        case .boom:
            if let core = boomCore {
                let t = now - boomStart - core.params.gap - core.params.wave2 * 0.6
                frame.vignetteFactor = clampd(t / 0.8, 0, 1)
            }
        case .armed:
            frame.vignetteFactor = 0
        }
        if frame.holdBlack { return frame }
        buildRowGlyphs(&frame, metal: metal, scale: scale)
        buildUIQuads(&frame, metal: metal, scale: scale)
        return frame
    }

    /// Metal twin of the snapshot harness's CPU reference frames.
    public func metalDebugSnapshot() -> CGImage? {
        guard let ctx = BoomMetalContext.shared else { return nil }
        if boomMetal == nil { boomMetal = BoomMetalRenderer(context: ctx) }
        guard let metal = boomMetal else { return nil }
        // Scale 1: the harness's bitmaps are point-sized.
        if let core = boomCore {
            metal.bindFieldIfNeeded(core.fields[boomFieldIndex],
                                    backdrop: backdropSource,
                                    buffer: boomSession?.backdropBuffers[boomFieldIndex],
                                    scale: 1)
        } else if intro == .armed, let img = backdropSource {
            metal.bindBackdropOnly(img)
        }
        guard let frame = buildFrameInput(scale: 1) else { return nil }
        return metal.snapshot(frame, core: intro != .none ? boomCore : nil,
                              fieldIndex: boomFieldIndex,
                              viewSize: bounds.size, scale: 1)
    }

    // MARK: Metal frame builders

    @inline(__always) private func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                        _ t: Float) -> SIMD3<Float> {
        a + (b - a) * min(max(t, 0), 1)
    }

    /// The typed rows (and fading boom debris) as glyph instances — the
    /// exact per-character color math of segmentString, no CoreText.
    private func buildRowGlyphs(_ frame: inout BoomMetalRenderer.FrameInput,
                                metal: BoomMetalRenderer, scale: CGFloat) {
        guard intro != .armed else { return }   // rows are cleared while armed
        let s = Float(scale)
        let cw = Float(charW) * s
        let lh = Float(lineH) * s
        let x0 = Float(leftInset) * s
        let maxY = bounds.height - lineH
        let codeBaseV = SIMD3<Float>(0.58, 0.65, 0.72)
        let glowTextV = SIMD3<Float>(0.93, 0.98, 1.0)
        let glowHaloV = SIMD3<Float>(0.50, 0.83, 1.0)
        let cursorV = SIMD3<Float>(0.66, 0.90, 1.0)

        func emit(_ ch: Character, cells: Int, x: Float, y: Float,
                  color: SIMD4<Float>, halo: SIMD4<Float>? = nil) {
            guard let slot = metal.glyphSlot(for: ch, cells: cells) else { return }
            let size = SIMD2(cw * Float(cells), lh)
            if let halo {
                frame.glyphs.append(.init(origin: SIMD2(x, y), size: size,
                                          color: halo, uvRect: slot.uv,
                                          flags: SIMD4(0, 1, 0, 0)))
            }
            var c = color
            var flags = SIMD4<UInt32>(0, 0, 0, 0)
            if slot.isColor {
                c = SIMD4(1, 1, 1, color.w)
                flags.x = 1
            }
            frame.glyphs.append(.init(origin: SIMD2(x, y), size: size,
                                      color: c, uvRect: slot.uv, flags: flags))
        }

        for (i, segs) in rows.enumerated() {
            let yPt = topInset + CGFloat(i) * lineH
            if yPt > maxY { break }
            let y = Float(yPt) * s
            for seg in segs {
                guard !seg.chars.isEmpty, seg.typed > 0 || seg.isActive else { continue }
                if seg.fading {
                    let f = Float(BoomCore.settledFade(age: now - seg.settledAt))
                    guard f > 0.01 else { continue }
                    let color = SIMD4(mix3(codeBaseV, glowTextV, 0.85 * f), 0.95 * f)
                    var xCells = seg.xCol
                    for ch in seg.chars {
                        let cells = cellWidth(ch)
                        if ch != " " {
                            emit(ch, cells: cells, x: x0 + Float(xCells) * cw, y: y,
                                 color: color)
                        }
                        xCells += cells
                    }
                    continue
                }

                let age = max(0, now - seg.settledAt)
                var baseAlpha = seg.isActive
                    ? Float(codeActiveAlpha)
                    : Float(codeSettledFloor) + Float(codeSettledBoost)
                        * Float(exp(-age / Double(codeFadeTau)))
                if seg.isComment { baseAlpha *= Float(codeCommentDim) }
                let tint = Float(seg.tint)
                let tinted = SIMD3<Float>(min(1, 0.58 + tint * 0.3), 0.65,
                                          min(1, 0.72 - tint))
                let heat = seg.isActive ? 1.0
                    : exp(-max(0, now - seg.typingDoneAt) / 0.55)
                let visible = seg.typed
                let cutoff = heat > 0.03 ? max(0, visible - 8) : visible
                var xCells = seg.xCol
                for k in 0..<visible {
                    let ch = seg.chars[k]
                    let cells = cellWidth(ch)
                    let x = x0 + Float(xCells) * cw
                    xCells += cells
                    guard ch != " " else { continue }
                    if k < cutoff {
                        emit(ch, cells: cells, x: x, y: y,
                             color: SIMD4(tinted, baseAlpha))
                    } else {
                        let d = visible - 1 - k
                        let b = Float(min(1, pow(0.70, Double(d)) * heat
                            * Double(codeGlowStrength)))
                        let color = SIMD4(mix3(tinted, glowTextV, 0.85 * b),
                                          baseAlpha + (1 - baseAlpha) * b)
                        let halo: SIMD4<Float>? = b > 0.12
                            ? SIMD4(glowHaloV, 0.85 * b) : nil
                        emit(ch, cells: cells, x: x, y: y, color: color, halo: halo)
                    }
                }
                if seg.isActive || now - seg.typingDoneAt < 0.3 {
                    emit("\u{258A}", cells: 1, x: x0 + Float(xCells) * cw, y: y,
                         color: SIMD4(cursorV, 0.85),
                         halo: SIMD4(glowHaloV, 0.9))
                }
            }
        }
    }

    /// The UI above the vignette: clock, spinner panel / teleport, idle line.
    private func buildUIQuads(_ frame: inout BoomMetalRenderer.FrameInput,
                              metal: BoomMetalRenderer, scale: CGFloat) {
        if intro == .armed {
            guard boomOriginOnThisDisplay else { return }
            if boomSession?.kind == .corner {
                // Corner runs: the user just hit the corner and is watching
                // it — the finished line appears as soon as the reveal lands.
                guard armedRevealProgress >= 1 else { return }
                buildIdleLineQuad(&frame, metal: metal, scale: scale)
            } else {
                buildArmedIntro(&frame, metal: metal, scale: scale)
            }
            return
        }
        if clockVisible { buildClockQuad(&frame, metal: metal) }
        buildPanelQuads(&frame, metal: metal, scale: scale)
    }

    /// Rasterizes a flipped-coordinates drawing block for upload as a quad.
    private func rasterUI(size: NSSize, scale: CGFloat,
                          _ body: () -> Void) -> CGImage? {
        let pw = max(1, Int(size.width * scale))
        let ph = max(1, Int(size.height * scale))
        guard let cg = Self.makeBGRAContext(pw: pw, ph: ph) else { return nil }
        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(ph))
        cg.scaleBy(x: scale, y: -scale)
        body()
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage()
    }

    /// The cursor's visual center — the anchor everything organizes around:
    /// the glyph materializes HERE, the growing line stays centered HERE,
    /// and the boom detonates (within a few px) HERE. That coincidence is
    /// what makes the blast read as the statusline's own energy escaping.
    private var armedLineCenter: NSPoint {
        let o = resolvedBoomOrigin
        return NSPoint(x: o.x + 6.5, y: o.y + 10)
    }

    /// Idle runs center the line on the cursor (clamped on-screen, whole
    /// points — reflow happens in per-character jumps, never a glide);
    /// corner runs keep the tooltip placement beside the corner.
    private func idleLineOrigin(for size: NSSize) -> NSPoint {
        guard boomSession?.kind != .corner else { return armedTextOrigin() }
        let c = armedLineCenter
        let x = min(max((c.x - size.width / 2).rounded(), 24),
                    bounds.width - size.width - 24)
        let y = min(max((c.y - size.height / 2).rounded(), 24),
                    bounds.height - size.height - 24)
        return NSPoint(x: x, y: y)
    }

    /// The armed intro for idle runs: the desktop reveals with the cursor
    /// exactly where the user left it; the cursor and the spinner glyph
    /// then TRADE PLACES in quantized frame-blocks (same visual center, no
    /// tween — a display deciding what it's showing) with an electric
    /// shimmer; the verb types out around the fixed center; the finished
    /// line shimmers until detonation. No countdown — the wait is the show.
    private func buildArmedIntro(_ frame: inout BoomMetalRenderer.FrameInput,
                                 metal: BoomMetalRenderer, scale: CGFloat) {
        let a = armTotal - (armEndsAt - now)
        let morphStart = 1.3, morphLen = 0.55, perChar = 0.055
        let o = resolvedBoomOrigin

        // 30 Hz flicker slots; three reps — {3,4}, {7,8}, {11,12} show the
        // glyph — then 14 locks it in. (The phosphor pulse in
        // buildFrameInput follows the same slots.)
        let slot = a < morphStart ? -1 : Int((a - morphStart) * 30)
        let showGlyph = slot >= 14 || slot == 3 || slot == 4 || slot == 7
            || slot == 8 || slot == 11 || slot == 12
        if !showGlyph {
            if cursorRaster == nil || cursorRasterScale != scale {
                cursorRaster = makeCursorRaster(scale: scale)
                cursorRasterScale = scale
            }
            if let raster = cursorRaster {
                metal.setUITexture("cursor", image: raster)
                // Tip = hotspot at (1,1); the recorded mouse point is the tip.
                frame.quads.append(.init(
                    key: "cursor",
                    rect: CGRect(x: o.x - 1, y: o.y - 1,
                                 width: Self.cursorSize.width,
                                 height: Self.cursorSize.height),
                    alpha: Double(armedRevealProgress)))
            }
            return
        }

        let chars = (armedVerb + "\u{2026}").count
        let typeStart = morphStart + morphLen
        let typed = a < typeStart ? 0
            : min(chars, Int((a - typeStart) / perChar) + 1)
        // Materialization shimmer: bright through the flicker, one dimmer
        // step after lock-in, then off. Steps, not a fade.
        let shimmer: Double = slot < 14 ? 0.4 : (slot < 20 ? 0.18 : 0)
        buildIdleLineQuad(&frame, typed: typed, shimmer: shimmer,
                          metal: metal, scale: scale)
    }

    private static let cursorSize = NSSize(width: 15, height: 22)

    /// The macOS arrow pointer, drawn by hand — NSCursor.arrow.image is
    /// EMPTY outside a real UI session (verified: 0×0, no reps, both in the
    /// headless harness and remote-view hosts), so the fake cursor is a
    /// vector twin: black fill, white outline, tip at (1,1).
    private func makeCursorRaster(scale: CGFloat) -> CGImage? {
        rasterUI(size: Self.cursorSize, scale: scale) {
            let pts: [(CGFloat, CGFloat)] = [
                (1, 1), (1, 18.5), (5.2, 14.6), (7.8, 20.9), (10.7, 19.7),
                (8.1, 13.5), (13.7, 13.5),
            ]
            let p = NSBezierPath()
            p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
            for pt in pts.dropFirst() { p.line(to: NSPoint(x: pt.0, y: pt.1)) }
            p.close()
            p.lineWidth = 2.2
            p.lineJoinStyle = .round
            NSColor.white.setStroke()
            p.stroke()
            NSColor.black.setFill()
            p.fill()
        }
    }

    private func buildIdleLineQuad(_ frame: inout BoomMetalRenderer.FrameInput,
                                   typed: Int? = nil, shimmer: Double = 0,
                                   metal: BoomMetalRenderer, scale: CGFloat) {
        let text = idleLineString(typed: typed)
        let size = text.size()
        let origin = idleLineOrigin(for: size)
        // Detonation kinetics: a two-frame surge flash through the box and
        // a BLAST of ejecta out of it (below). The box itself stays put —
        // a shake on something this small read as a timid shudder.
        var surge: Float = 0
        if intro == .boom {
            let t = now - boomStart
            if t >= 0, t < 2.0 / 30 { surge = t < 1.0 / 30 ? 0.6 : 0.28 }
        }
        // The tooltip panel extends 14/8 past the text; +2 for the stroke.
        let pad = NSSize(width: 16, height: 10)
        let full = NSSize(width: size.width + pad.width * 2,
                          height: size.height + pad.height * 2)
        guard let img = rasterUI(size: full, scale: scale, {
            drawIdleLine(text, at: NSPoint(x: pad.width, y: pad.height))
        }) else { return }
        metal.setUITexture("idleline", image: img, always: true)
        let panelRect = CGRect(x: origin.x - pad.width, y: origin.y - pad.height,
                               width: full.width, height: full.height)
        frame.quads.append(.init(key: "idleline", rect: panelRect))
        if shimmer > 0 {
            // Electric block over the materializing glyph — steps with the
            // flicker slots.
            let gw = idleLineString(typed: 0).size().width
            frame.lateFills.append(BoomMetalRenderer.fill(
                NSRect(x: origin.x - 6, y: origin.y - 6,
                       width: gw + 12, height: size.height + 12),
                scale: scale, color: SIMD4(0.75, 0.64, 1.0, Float(shimmer))))
        }
        if surge > 0 {
            frame.lateFills.append(BoomMetalRenderer.fill(
                panelRect.insetBy(dx: -2, dy: -2),
                scale: scale, color: SIMD4(0.75, 0.64, 1.0, surge)))
        }
        // The blast: cell-blocks in the accent palette ejected from the
        // panel's perimeter, decelerating outward like debris. Everything
        // quantized — positions re-rolled per 30 Hz step, snapped to the
        // terminal lattice, a quarter of the blocks sitting out each step
        // (sparkle, not smear). White-hot for the first two frames.
        if intro == .boom, let core = boomCore {
            let t = now - boomStart
            if t >= 0, t < 0.7 {
                let g = core.fields[boomFieldIndex].grid
                let cw = g.charW, lh = g.lineH
                let step = (t * 30).rounded(.down) / 30
                let stepIx = Int(t * 30)
                let c = armedLineCenter
                let rx = Double(panelRect.width) / 2, ry = Double(panelRect.height) / 2
                for i in 0..<56 {
                    if boomCellNoise(i, stepIx, 0xE1A6) < 0.25 { continue }
                    let ang = boomCellNoise(i, 11, 0xE1A5) * 2 * .pi
                    // Contained blowout: short reach, full intensity — the
                    // violence is in the brightness, not the distance.
                    let reach = 40.0 + boomCellNoise(i, 23, 0xE1A5) * 90.0
                    let r0 = sqrt(pow(rx * cos(ang), 2) + pow(ry * sin(ang), 2))
                    let r = r0 + reach * (1 - exp(-step / 0.13))
                    let px = Double(c.x) + cos(ang) * r
                    let py = Double(c.y) + sin(ang) * r
                    let col = ((CGFloat(px) - g.leftInset) / cw).rounded(.down)
                    let row = ((CGFloat(py) - g.topInset) / lh).rounded(.down)
                    let fade = Float(max(0, 1 - step / 0.7))
                    let color: SIMD4<Float> = t < 4.0 / 30
                        ? SIMD4(1.0, 0.97, 1.0, 1.0)
                        : SIMD4(0.80, 0.70, 1.0, 0.95 * fade)
                    frame.lateFills.append(BoomMetalRenderer.fill(
                        NSRect(x: g.leftInset + col * cw, y: g.topInset + row * lh,
                               width: cw, height: lh),
                        scale: scale, color: color))
                }
            }
        }
    }

    private func buildClockQuad(_ frame: inout BoomMetalRenderer.FrameInput,
                                metal: BoomMetalRenderer) {
        guard let cache = ensureClockCache() else { return }
        metal.setUITexture("clock", image: cache.image)   // 1 Hz re-upload
        frame.quads.append(.init(key: "clock", rect: cache.blitRect,
                                 maskToWipedCells: intro == .boom))
        clockBottom = cache.bottom
    }

    private func appendTeleportFlash(_ fills: inout [BoomMetalRenderer.CellInstance],
                                     rect: NSRect, alpha: CGFloat, scale: CGFloat) {
        guard alpha > 0.02 else { return }
        fills.append(BoomMetalRenderer.fill(rect.insetBy(dx: -7, dy: -5), scale: scale,
                                            color: SIMD4(0.93, 0.96, 1.0, Float(alpha * 0.22))))
        fills.append(BoomMetalRenderer.fill(rect, scale: scale,
                                            color: SIMD4(0.93, 0.96, 1.0, Float(alpha))))
    }

    private func appendBlip(_ fills: inout [BoomMetalRenderer.CellInstance],
                            cell: NSRect, scale: CGFloat) {
        fills.append(BoomMetalRenderer.fill(cell, scale: scale,
                                            color: SIMD4(0.93, 0.96, 1.0, 0.9)))
        let ring = cell.insetBy(dx: -4, dy: -4)
        let c = SIMD4<Float>(0.93, 0.96, 1.0, 0.65)
        let w: CGFloat = 1
        fills.append(BoomMetalRenderer.fill(NSRect(x: ring.minX, y: ring.minY,
                                                   width: ring.width, height: w),
                                            scale: scale, color: c))
        fills.append(BoomMetalRenderer.fill(NSRect(x: ring.minX, y: ring.maxY - w,
                                                   width: ring.width, height: w),
                                            scale: scale, color: c))
        fills.append(BoomMetalRenderer.fill(NSRect(x: ring.minX, y: ring.minY,
                                                   width: w, height: ring.height),
                                            scale: scale, color: c))
        fills.append(BoomMetalRenderer.fill(NSRect(x: ring.maxX - w, y: ring.minY,
                                                   width: w, height: ring.height),
                                            scale: scale, color: c))
    }

    /// The spinner panel — including the full teleport choreography — as
    /// fills and a per-frame raster quad. Mirrors drawSpinnerPanel exactly.
    private func buildPanelQuads(_ frame: inout BoomMetalRenderer.FrameInput,
                                 metal: BoomMetalRenderer, scale: CGFloat) {
        let text = spinnerAttributedString()
        let size = text.size()
        let padH: CGFloat = uiFont.pointSize * 1.7
        let padV: CGFloat = uiFont.pointSize * 1.05
        let textOrigin = spinnerTextOrigin(for: size)
        var backdropAlpha: CGFloat = 1
        var arrivalFlash: CGFloat = 0
        if intro == .boom, let core = boomCore {
            let grid = core.fields[boomFieldIndex].grid
            let t = now - boomStart
            let start = idleLineOrigin(for: idleLineString().size())
            let zapStart = core.duration + 0.35
            let tz = t - zapStart
            if tz < 0 {
                if boomOriginOnThisDisplay {
                    buildIdleLineQuad(&frame, metal: metal, scale: scale)
                }
                return
            }
            if tz < 0.23, boomOriginOnThisDisplay {
                let a = CGFloat(1 - tz / 0.23)
                let idleSize = idleLineString().size()
                appendTeleportFlash(&frame.fills,
                                    rect: NSRect(x: start.x - 6, y: start.y - 3,
                                                 width: idleSize.width + 12,
                                                 height: idleSize.height + 6),
                                    alpha: 0.85 * a * a, scale: scale)
            }
            if tz < 0.07 { return }
            if tz < 0.13 {
                appendBlip(&frame.fills,
                           cell: NSRect(x: (bounds.width - grid.charW) / 2,
                                        y: textOrigin.y,
                                        width: grid.charW, height: grid.lineH),
                           scale: scale)
                return
            }
            if tz < 0.22 { return }
            backdropAlpha = CGFloat(clampd((tz - 0.30) / 0.15, 0, 1))
            if tz < 0.36 { arrivalFlash = CGFloat((0.36 - tz) / 0.14) * 0.55 }
        }
        let shadowPad: CGFloat = 40
        let panel = NSRect(x: textOrigin.x - padH, y: textOrigin.y - padV,
                           width: size.width + padH * 2, height: size.height + padV * 2)
        ensurePanelBackdropImage(panel)
        let full = NSSize(width: panel.width + shadowPad * 2,
                          height: panel.height + shadowPad * 2)
        let bAlpha = backdropAlpha
        guard let img = rasterUI(size: full, scale: scale, {
            if bAlpha > 0.02, let pimg = panelCacheImage,
               let cg = NSGraphicsContext.current?.cgContext {
                cg.saveGState()
                if bAlpha < 1 { cg.setAlpha(bAlpha) }
                cg.translateBy(x: 0, y: full.height)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(pimg, in: CGRect(origin: .zero, size: full))
                cg.restoreGState()
            }
            text.draw(at: NSPoint(x: shadowPad + padH, y: shadowPad + padV))
        }) else { return }
        metal.setUITexture("panel", image: img, always: true)
        frame.quads.append(.init(key: "panel",
                                 rect: NSRect(x: panel.minX - shadowPad,
                                              y: panel.minY - shadowPad,
                                              width: full.width, height: full.height)))
        if arrivalFlash > 0 {
            appendTeleportFlash(&frame.lateFills,
                                rect: NSRect(x: textOrigin.x - 4, y: textOrigin.y - 2,
                                             width: size.width + 8, height: size.height + 4),
                                alpha: arrivalFlash, scale: scale)
        }
    }

    private var boomFreshCells: [Int] = []
    private var introNeedsFullRedraw = true
    private var lastIntroUIRect = NSRect.zero

    /// During the intro, invalidate only what changed — full-frame redraws
    /// at 5K × N displays are what made the boom a slideshow (~33 ms/frame
    /// just to re-composite a static backdrop). AppKit clips draw(_:) to the
    /// union of these rects.
    private func invalidateForFrame() {
        // Metal renders every pixel imperatively per tick; the view's own
        // backing is a black rectangle that never needs repainting.
        guard !metalActive else { return }
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
            // Tick once right now: session attach and Metal staging start
            // immediately instead of waiting out the first framework frame
            // (or the 1 s fallback probe). Overlapping drivers are safe —
            // an extra tick just advances by dt ≈ 0.
            tick()
            startFrameClock()
            startWatchdog()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.rescueZeroSizedWindow()
            }
        } else {
            stopFrameClock()
            stopWatchdog()
        }
    }

    /// Fires even when the display link doesn't — the runloop is kept alive
    /// by the sibling views. A dead link means our window sits on a display
    /// that isn't compositing: hide the surface (transparent window) and
    /// release any field claim so the live sibling takes over.
    private var watchdog: Timer?

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A dead display link = our window is occluded (macOS suspends
            // links for covered windows — the fate of a never-migrated
            // window stacked under its sibling). The view is still the
            // compositor's source for a real display, so keep it ALIVE:
            // drive ticks from a timer, which occlusion can't suspend.
            guard self.displayLinkBox != nil, self.fallbackSource == nil,
                  CACurrentMediaTime() - self.lastLinkFire > 0.35,
                  self.lastLinkFire > 0 || CACurrentMediaTime() - self.lastWall > 0.35
            else { return }
            self.engageStrictFallback()
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// The occlusion fallback clock: a strict DispatchSourceTimer ticking on
    /// absolute 1/30 s boundaries, feeding boundary timestamps into the sim
    /// clock — so even a link-less view gets metronome cadence and exactly
    /// two sim ticks per frame (a plain NSTimer here measured 40 ms avg with
    /// a 1 s stall: the built-in's "still laggy").
    private var fallbackSource: DispatchSourceTimer?
    private var fallbackBase: Double = 0
    private var fallbackLastSlot: Double = -1

    private var usingScreenLink = false

    private func engageStrictFallback() {
        // First choice: a SCREEN-bound display link for our field's true
        // panel — vsync-locked and immune to window occlusion (it's scoped
        // to the display, not to our covered window). The dispatch grid
        // timer below is the last resort; it can't phase-lock to the panel
        // and measurably skips a slot every few seconds.
        if #available(macOS 14.0, *), let session = boomSession {
            let target = session.core.fields[boomFieldIndex].originCG
            if let screen = NSScreen.screens.first(where: {
                guard let num = $0.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                else { return false }
                let b = CGDisplayBounds(num)
                return abs(b.origin.x - target.x) < 0.5 && abs(b.origin.y - target.y) < 0.5
            }) {
                (displayLinkBox as? CADisplayLink)?.invalidate()
                let link = screen.displayLink(target: self,
                                              selector: #selector(displayTick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30,
                                                                preferred: 30)
                link.add(to: .main, forMode: .common)
                displayLinkBox = link
                usingScreenLink = true
                lastLinkFire = CACurrentMediaTime()
                nextTickBoundary = 0
                BoomDiag.log("\(diagID) view link suspended — SCREEN link engaged for field \(boomFieldIndex)")
                return
            }
        }
        lastWall = CACurrentMediaTime()   // don't count the dead gap as a frame
        fallbackBase = CACurrentMediaTime()
        fallbackLastSlot = -1
        let period = 1.0 / 30.0
        let src = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        src.schedule(deadline: .now() + period, repeating: period,
                     leeway: .milliseconds(1))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Quantize to the absolute grid; tolerate coalesced fires.
            let k = ((CACurrentMediaTime() - self.fallbackBase) / period).rounded()
            guard k > self.fallbackLastSlot else { return }
            self.fallbackLastSlot = k
            self.tick(at: self.fallbackBase + k * period)
        }
        src.resume()
        fallbackSource = src
        BoomDiag.log("\(diagID) display link suspended (occluded window) — strict grid timer engaged")
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func startFrameClock() {
        guard displayLinkBox == nil, legacyTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = displayLink(target: self, selector: #selector(displayTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30,
                                                            preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLinkBox = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            legacyTimer = timer
        }
    }

    private func stopFrameClock() {
        if #available(macOS 14.0, *) {
            (displayLinkBox as? CADisplayLink)?.invalidate()
        }
        displayLinkBox = nil
        legacyTimer?.invalidate()
        legacyTimer = nil
        fallbackSource?.cancel()
        fallbackSource = nil
    }

    private var nextTickBoundary: Double = 0
    /// Last CADisplayLink fire — dies when our window is occluded (e.g. a
    /// never-migrated window stacked under a sibling). Ticks then fall back
    /// to a timer, which occlusion cannot suspend.
    private var lastLinkFire: Double = 0

    @available(macOS 14.0, *)
    @objc private func displayTick(_ link: CADisplayLink) {
        lastLinkFire = CACurrentMediaTime()
        // Tick every N vsyncs where N·period is closest to 1/30 s — the
        // panel's own grid decides: 2nd vsync at 60 Hz (33.3 ms), 4th at
        // 120 (33.3), 3rd at 100 (30 ms, ~33 fps). Steady cadence beats
        // exact rate: forcing absolute 33.3 ms boundaries on a 100 Hz grid
        // produced a 40/30 ms wobble, which reads worse than a slightly
        // fast metronome. (Rate ranges are advisory; callbacks arrive at
        // panel rate, so decimation is ours.)
        let vsync = max(0.001, link.targetTimestamp - link.timestamp)
        let period = max(1, (1.0 / 30.0 / vsync).rounded()) * vsync
        if nextTickBoundary == 0 { nextTickBoundary = link.timestamp }
        guard link.timestamp >= nextTickBoundary - vsync * 0.25 else { return }
        nextTickBoundary += period
        if link.timestamp > nextTickBoundary + 0.1 {   // resync after a stall
            nextTickBoundary = link.timestamp + period
        }
        tick(at: link.timestamp)
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

    deinit {
        stopFrameClock()
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
        if !handoffChecked, window != nil { attachBoomSession() }
        // Session runs re-derive their clock from the shared monotonic anchor
        // every frame — all displays in lockstep even across dropped frames.
        // (Pre-anchor the clock holds still, so the scene freezes until every
        // display has staged; see BoomSession.markReady.)
        if let session = boomSession, intro != .none {
            rebindFieldIfNeeded(session)
            session.pollReadiness()
            let t = session.simTime(at: frameNow > 0 ? frameNow : CACurrentMediaTime())
            if intro == .armed { armEndsAt = now - t } else { boomStart = now - t }
        }
        switch intro {
        case .armed:
            // The captured desktop + the idle line; the scene holds its breath.
            if now >= armEndsAt { detonate() } else { return }
        case .boom:
            if let core = boomCore {
                // Local runs (preview click / env): dilate by drifting the
                // epoch so (now - boomStart) grows at 1/scale. Session runs
                // dilate at the source (BoomSession.simTime).
                if boomSession == nil, Self.boomTimeScale != 1 {
                    boomStart += dt * (1 - 1 / Self.boomTimeScale)
                }
                // Cap the catch-up target: past duration+6 the field is fully
                // transitioned and finishIntro (below) fires off the wall
                // clock anyway. Without the cap, a frame clock that stalls
                // mid-boom (display sleep) and resumes minutes later would
                // replay every missed tick — thousands of full-grid steps in
                // one frame.
                core.advance(to: min(now - boomStart, core.duration + 6))
                _ = core.drainPaints(boomFieldIndex)
                // Preview runs own every field; in a session each display's
                // view drains its own.
                if boomSession == nil {
                    for i in core.fields.indices where i != boomFieldIndex {
                        _ = core.drainPaints(i)
                    }
                }
                // The handoff waits for the debris: every flung glyph gets
                // its own bright-block → settled → fade lifecycle. Ending on
                // the fixed clock guillotined whichever heads were still
                // drifting — they all blipped out in one frame.
                let boomT = now - boomStart
                if boomT > core.duration + 1.0,
                   !core.particles.contains(where: { !$0.settled })
                       || boomT > core.duration + 5.0 {
                    finishIntro()
                }
            } else {
                intro = .none
            }
        case .none:
            break
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
        // Boom debris that has faded out is done for good.
        if now >= nextFadePurge {
            nextFadePurge = now + 3
            for i in rows.indices {
                rows[i].removeAll { $0.fading && now - $0.settledAt > BoomCore.settledFadeLife + 1 }
            }
        }
    }

    private var nextFadePurge: Double = 0

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

    // MARK: Boom intro mechanics

    /// Arms the intro: the scene clears to black and the idle line ticks down
    /// at `p` (fractions of bounds) until detonation.
    public func armIntro(atNormalized p: CGPoint, countdown: Double) {
        boomOriginNorm = p
        intro = .armed
        armEndsAt = now + countdown
        armTotal = countdown
        armedVerb = verbs.randomElement()?.ing ?? "Idling"
        boomSession = nil
        boomCore = nil
        viewOriginCG = .zero
        for i in rows.indices { rows[i] = [] }
    }

    /// Re-runs the boom from the last origin (tuning-panel button).
    public func replayBoom() {
        armIntro(atNormalized: boomOriginNorm, countdown: 1.2)
    }

    /// Preview-window convenience: a click detonates at that point. The real
    /// saver never receives events (input ends the session first).
    public override func mouseDown(with event: NSEvent) {
        guard bounds.width > 8 else { return }
        let p = convert(event.locationInWindow, from: nil)
        armIntro(atNormalized: CGPoint(x: p.x / bounds.width, y: p.y / bounds.height),
                 countdown: 1.2)
    }

    /// CODESAVER_BOOM="x,y[,armSeconds]" (x/y as fractions) arms the intro at
    /// launch — the snapshot harness's deterministic trigger.
    private func configureIntroFromEnv() {
        guard let spec = ProcessInfo.processInfo.environment["CODESAVER_BOOM"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count >= 2 else { return }
        armIntro(atNormalized: CGPoint(x: parts[0], y: parts[1]),
                 countdown: parts.count >= 3 ? parts[2] : 2.0)
    }

    /// Production path: the igniter left a capture manifest (screenshots +
    /// mouse position + trigger kind); the shared BoomSession loads it once
    /// and every display's view attaches. Idle triggers play a 5-second
    /// armed pre-animation over the captured desktop; hot-corner triggers
    /// detonate immediately. No manifest (or a stale one) → normal start.
    private func attachBoomSession() {
        handoffChecked = true
        guard intro == .none, let win = window, bounds.width > 8 else { return }
        guard let session = BoomSession.loadIfNeeded(codeLines: { self.boomCodeLines() },
                                                     verbs: verbs.map(\.ing)) else { return }
        // Which field is ours: appex service windows sit at their display's
        // CG origin (see clockVisible).
        let wo = win.frame.origin
        boomFieldIndex = session.core.fields.firstIndex {
            abs($0.originCG.x - wo.x) < 0.5 && abs($0.originCG.y - wo.y) < 0.5
        } ?? 0
        boomSession = session
        boomCore = session.core
        BoomDiag.log(String(format: "%@ attach: window origin (%.0f, %.0f) → field %d, simTime %.2f",
                            diagID, wo.x, wo.y, boomFieldIndex, session.simTime))
        viewOriginCG = session.core.fields[boomFieldIndex].originCG
        let fieldSize = session.core.fields[boomFieldIndex].grid.size
        boomOriginNorm = CGPoint(
            x: (session.core.params.originCG.x - viewOriginCG.x) / fieldSize.width,
            y: (session.core.params.originCG.y - viewOriginCG.y) / fieldSize.height)
        armedVerb = session.verb
        for i in rows.indices { rows[i] = [] }
        let t = session.simTime
        if t < 0 {
            intro = .armed
            armEndsAt = now - t
            armTotal = session.armDuration
        } else {
            detonate(start: now - t)
        }
    }

    /// The host parks every window on the main display first and migrates it
    /// to its real display moments later (see clockVisible) — so the field
    /// binding must follow the window rather than latch on first sight.
    private func rebindFieldIfNeeded(_ session: BoomSession) {
        guard let win = window else { return }
        // Primary identity: the window's SCREEN — what the display link
        // follows. In the wedged host state the frame origin stays parked at
        // (0,0) forever while the screen association is already correct
        // (proven live: a stuck-origin view ticking on its true panel's
        // vsync grid). Trust it only while the link is actually firing.
        var target: Int?
        if CACurrentMediaTime() - lastLinkFire < 0.7,
           let screen = win.screen,
           let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let b = CGDisplayBounds(num)
            target = session.core.fields.firstIndex {
                abs($0.originCG.x - b.origin.x) < 0.5 && abs($0.originCG.y - b.origin.y) < 0.5
            }
        }
        if target == nil {
            let wo = win.frame.origin
            target = session.core.fields.firstIndex {
                abs($0.originCG.x - wo.x) < 0.5 && abs($0.originCG.y - wo.y) < 0.5
            }
        }
        guard let idx = target, idx != boomFieldIndex else { return }
        // Never rebind INTO a field another live view is rendering (e.g. an
        // adopted view's stale (0,0) origin matching the main field).
        guard session.claimField(idx, by: ObjectIdentifier(self)) else { return }
        session.releaseField(boomFieldIndex, by: ObjectIdentifier(self))
        boomFieldIndex = idx
        BoomDiag.log(String(format: "%@ rebound → field %d (window origin (%.0f, %.0f))",
                            diagID, idx, win.frame.origin.x, win.frame.origin.y))
        reengageFallbackIfNeeded()
        let field = session.core.fields[idx]
        viewOriginCG = field.originCG
        boomOriginNorm = CGPoint(
            x: (session.core.params.originCG.x - viewOriginCG.x) / field.grid.size.width,
            y: (session.core.params.originCG.y - viewOriginCG.y) / field.grid.size.height)
        if intro == .boom {
            // Ignition times belong to the display we actually live on.
            for w in writers {
                let p = NSPoint(x: leftInset + CGFloat(w.col) * charW,
                                y: topInset + CGFloat(w.row) * lineH)
                w.pauseUntil = min(w.pauseUntil,
                                   boomStart + boomSecondHit(ofLocal: p) * Self.boomTimeScale
                                       + rand(0.05, 0.4))
            }
        }
        setNeedsDisplay(bounds)
    }

    /// A fallback clock serves a specific panel; if our field changes after
    /// engagement, re-engage for the new one.
    private func reengageFallbackIfNeeded() {
        guard usingScreenLink || fallbackSource != nil else { return }
        if usingScreenLink {
            if #available(macOS 14.0, *) {
                (displayLinkBox as? CADisplayLink)?.invalidate()
            }
            displayLinkBox = nil
            usingScreenLink = false
        }
        fallbackSource?.cancel()
        fallbackSource = nil
        engageStrictFallback()
    }

    /// Binds this view to a field chosen by elimination (its window's
    /// origin lies). Mirrors rebindFieldIfNeeded's bookkeeping.
    private func adoptField(_ idx: Int, session: BoomSession) {
        session.releaseField(boomFieldIndex, by: ObjectIdentifier(self))
        boomFieldIndex = idx
        let field = session.core.fields[idx]
        viewOriginCG = field.originCG
        boomOriginNorm = CGPoint(
            x: (session.core.params.originCG.x - viewOriginCG.x) / field.grid.size.width,
            y: (session.core.params.originCG.y - viewOriginCG.y) / field.grid.size.height)
        if intro == .boom {
            for w in writers {
                let p = NSPoint(x: leftInset + CGFloat(w.col) * charW,
                                y: topInset + CGFloat(w.row) * lineH)
                w.pauseUntil = min(w.pauseUntil,
                                   boomStart + boomSecondHit(ofLocal: p) * Self.boomTimeScale
                                       + rand(0.05, 0.4))
            }
        }
        reengageFallbackIfNeeded()
        setNeedsDisplay(bounds)
    }

    private func detonate(start: Double? = nil) {
        intro = .boom
        boomStart = start ?? now
        BoomDiag.log(String(format: "detonate (field %d, t=%.2f)", boomFieldIndex, now - boomStart))
        if boomCore == nil {
            // Local arming (preview click / env): one field over this view,
            // asciified from a stand-in capture when provided. Fixed seed:
            // snapshot runs must be reproducible.
            let grid = BoomGrid(size: bounds.size)
            var color = [UInt32](repeating: 0, count: grid.cols * grid.rows)
            if let img = Self.standInCapture() {
                color = BoomCore.colorize(img, grid: grid)
            }
            let o = resolvedBoomOrigin
            boomCore = BoomCore(
                params: BoomCore.Params(originCG: o,
                                        radius: maxCornerDistance(from: o),
                                        seed: 0xC0DE_5AFE,
                                        wave1: boomWave1, gap: boomGap,
                                        wave2: boomWave2,
                                        debrisDensity: boomDebrisDensity,
                                        idleVerb: armedVerb,
                                        codeLines: boomCodeLines()),
                fields: [BoomField(grid: grid, originCG: .zero, color: color)])
            boomFieldIndex = 0
            viewOriginCG = .zero
        }
        guard let core = boomCore else { return }
        core.advance(to: max(0, now - boomStart))
        for i in core.fields.indices { _ = core.drainPaints(i) }
        // The boom opens a fresh request; its latency window covers the whole
        // show — parens only after the zap has landed.
        startCycle(freshVerb: true)
        phaseStart = boomStart
        // Parens only after the zap has landed: the line flies bare. (The
        // zap fires at (duration + 0.35) dilated; at scale 1 this is the
        // original duration + 0.9.)
        parenDelay = max(parenDelay, (core.duration + 0.35) * Self.boomTimeScale + 0.55)
        // The explosion's energy carries into the typing, then decays toward
        // the request-latency lull on speedMul's own ease.
        speedMul = 1.35
        for i in rows.indices { rows[i] = [] }
        for w in writers {
            respawn(w)
            let p = NSPoint(x: leftInset + CGFloat(w.col) * charW,
                            y: topInset + CGFloat(w.row) * lineH)
            w.pauseUntil = boomStart + boomSecondHit(ofLocal: p) * Self.boomTimeScale
                + rand(0.05, 0.4)
        }
    }

    /// The boom's end: settled flung glyphs become ordinary one-character
    /// segments — the normal pipeline owns them, ages them, and eventually
    /// types over them — and the whole boom apparatus is released.
    private func finishIntro() {
        if let core = boomCore {
            // Backstop stragglers (the +5 s cap fired): park them in place so
            // they continue their own decay as settled glyphs — never a mass
            // vanish. Shared core: the first view to finish parks for all.
            core.parkRemainingParticles()
            let f = core.fields[boomFieldIndex]
            // The boom grid extends past the screen edges; the typing grid is
            // inset. Same lattice, shifted by a whole number of cells.
            let colShift = Int(((leftInset - f.grid.leftInset) / charW).rounded())
            let rowShift = Int(((topInset - f.grid.topInset) / lineH).rounded())
            for row in 0..<f.grid.rows {
                for col in 0..<f.grid.cols {
                    let saverCol = col - colShift
                    let saverRow = row - rowShift
                    guard saverCol >= 0, saverCol < cols,
                          saverRow >= 0, saverRow < rowCount else { continue }
                    let i = f.index(col, row)
                    guard f.state[i] == BoomField.stateSettled,
                          let scalar = Unicode.Scalar(Int(f.ascii[i])), f.ascii[i] >= 33
                    else { continue }
                    // The fade started at the actual settle moment; carry
                    // that clock over so the curve never jumps. Already-faded
                    // glyphs don't come back. Anchored backwards from `now`:
                    // a glyph that settled (t − s) sim-seconds ago settled
                    // scale× that many wall-seconds ago — anchoring forward
                    // from boomStart under dilation put settle moments in
                    // the future and every glyph flashed back to white.
                    let settleTime = now - ((now - boomStart)
                        - Double(f.hitTick[i]) / BoomCore.tickHz) * Self.boomTimeScale
                    guard BoomCore.settledFade(age: now - settleTime) > 0.01 else { continue }
                    let seg = Segment()
                    seg.xCol = saverCol
                    seg.chars = [Character(scalar)]
                    seg.cells = 1
                    seg.typed = 1
                    seg.fading = true
                    seg.typingDoneAt = now - 10
                    seg.settledAt = settleTime
                    rows[saverRow].append(seg)
                }
            }
        }
        intro = .none
        boomCore = nil
        // The Metal pipeline persists — same renderer, next frame just has
        // no field pass. No teardown, no cache rebuilds, no hitch.
        setNeedsDisplay(bounds)
        BoomDiag.log("finishIntro (field \(boomFieldIndex))")
    }

    /// Real code for the boom's spots, straight from the session corpus.
    private func boomCodeLines() -> [String] {
        var lines: [String] = []
        for _ in 0..<6 {
            lines += randomChunk().map { String($0) }
        }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? BoomCore.fallbackCodeLines : lines
    }

    private static func standInCapture() -> CGImage? {
        guard let path = ProcessInfo.processInfo.environment["CODESAVER_CAPTURE"],
              let img = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static let standInCaptureImage: CGImage? = standInCapture()

    /// The desktop the boom destroys: in production, this display's captured
    /// screenshot from the session; in the harness, the stand-in image. The
    /// saver's opening frame IS the desktop, so the system's activation
    /// transition lands on a picture of what it left.
    private var backdropSource: CGImage? {
        if let session = boomSession { return session.backdrops[boomFieldIndex] }
        return Self.standInCaptureImage
    }


    private func maxCornerDistance(from o: NSPoint) -> CGFloat {
        let corners = [NSPoint(x: 0, y: 0), NSPoint(x: bounds.width, y: 0),
                       NSPoint(x: 0, y: bounds.height),
                       NSPoint(x: bounds.width, y: bounds.height)]
        return corners.map { hypot($0.x - o.x, $0.y - o.y) }.max() ?? bounds.width
    }

    // MARK: Drawing

    private var loggedFirstDraw = false

    public override func draw(_ rect: NSRect) {
        if !loggedFirstDraw {
            loggedFirstDraw = true
            viewLog.notice("first draw — bounds \(Double(self.bounds.width), privacy: .public)×\(Double(self.bounds.height), privacy: .public)")
            BoomDiag.log(String(format: "%@ first draw — bounds %.0f×%.0f, window origin (%.0f, %.0f), scale %.1f",
                                diagID, bounds.width, bounds.height,
                                window?.frame.origin.x ?? -1, window?.frame.origin.y ?? -1,
                                window?.backingScaleFactor ?? -1))
        }
        ensureSetup()
        if !metalActive {
            bgColor.setFill()
            bounds.fill()
        }
        guard !rows.isEmpty else { return }

        // The first draw beats the first animation tick — without this, the
        // normal saver (spinner and all) flashes on every display for a few
        // frames before the boom session attaches and drops the curtain.
        if !handoffChecked, window != nil { attachBoomSession() }

        // Everything renders on the CAMetalLayer subview; this view's own
        // content is the black base (and the whole story if Metal ever dies).
    }

    // MARK: Clock

    /// Bottom edge of the clock as last drawn; the spinner panel's safe area
    /// is measured from this.
    private var clockBottom: CGFloat = 0

    /// Where the clock's bottom will land before it has ever been drawn:
    /// mirrors buildClockCache's row count and step math.
    private func predictedClockBottom() -> CGFloat {
        let f = monoFont(bounds.height * clockScale, .regular)
        let step = (f.ascender - f.descender) * 0.9
        let rowCount = CGFloat(5 + 2 * clockVPadRows)
        return bounds.height * clockTopFrac + rowCount * step
    }

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


    /// Refreshes the 1 Hz clock raster; shared by the CG path and the Metal
    /// quad builder.
    private func ensureClockCache() -> ClockCache? {
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
        return clockCache
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



    // The radial gradient rasterizes every pixel per frame (~72ms at 5K —
    // measured as 72% of total frame cost), so it's cached as an exact
    // backing-pixel CGImage and blitted. The image is radially symmetric, so
    // the flipped context doesn't matter.



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

    /// Animated glyph: cosine phase, period 2000 ms, eased at both ends.
    private func appendSpinnerGlyph(to result: NSMutableAttributedString) {
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
    }

    private func workingString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let elapsed = now - phaseStart
        let verb = verbs[verbIndex]

        appendSpinnerGlyph(to: result)
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

    /// Where the panel's text sits: who owns the top of the screen decides
    /// where it centers — our clock here → center in what remains below it;
    /// our clock enabled but on another display → nothing owns the top, so
    /// center exactly; clock disabled → the system lock-screen clock owns
    /// the top (its 17% reservation is visual weight, not measured extent).
    /// Shared by the CG path and the Metal panel builder.
    private func spinnerTextOrigin(for size: NSSize) -> NSPoint {
        let textY: CGFloat
        if clockVisible {
            // Until the clock has drawn once (it fades in late during the
            // boom), clockBottom is unset — predict it from the same metrics
            // buildClockCache uses, so the teleport blip and landing agree
            // with where the panel will actually live.
            let effectiveClockBottom = clockBottom > 0 ? clockBottom : predictedClockBottom()
            let safeTop = effectiveClockBottom + lineH * panelGapMult
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
        return NSPoint(x: (bounds.width - size.width) / 2, y: textY)
    }


    /// Where the armed idle line sits: tooltip-style, right and below the
    /// detonation origin (the mouse's resting spot) — flipping left or up
    /// when the panel would run off the screen. Measures the finished line
    /// (there is no countdown anymore), so the anchor never moves while the
    /// verb types out.
    private func armedTextOrigin() -> NSPoint {
        let o = resolvedBoomOrigin
        let size = idleLineString().size()
        var x = o.x + 18
        if x + size.width + 14 > bounds.width { x = o.x - 18 - size.width }
        var y = o.y + 16
        if y + size.height + 8 > bounds.height { y = o.y - 16 - size.height }
        return NSPoint(x: x, y: y)
    }

    /// The verb the idle line shows — a real spinner verb, shared with the
    /// helper through the handoff so the crossfade is invisible.
    private var armedVerb = "Idling"

    /// The idle line: glyph + glowing verb. `typed` truncates the verb for
    /// the armed intro's type-out (nil = the finished line).
    private func idleLineString(typed: Int? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendSpinnerGlyph(to: result)
        let full = armedVerb + "\u{2026}"
        let text = typed.map { String(full.prefix(max(0, $0))) } ?? full
        if !text.isEmpty {
            appendGlowingVerb(text, to: result, intensity: 1.0)
        }
        return result
    }

    /// The idle line with its tooltip panel — black, bordered, exactly what
    /// the helper draws over the desktop.
    private func drawIdleLine(_ text: NSAttributedString, at origin: NSPoint) {
        let size = text.size()
        let path = NSBezierPath(roundedRect: NSRect(x: origin.x - 14, y: origin.y - 8,
                                                    width: size.width + 28,
                                                    height: size.height + 16),
                                xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(at: origin)
    }




    // The panel's fill + stroke + 26px drop shadow depend only on its size,
    // which changes about once a second — cache the raster, blit per frame.
    private var panelCacheImage: CGImage?
    private var panelCacheKey = ""


    /// Refreshes the size-keyed panel raster (fill + stroke + drop shadow);
    /// shared by the CG path and the Metal panel builder.
    private func ensurePanelBackdropImage(_ panel: NSRect) {
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
    }
}

