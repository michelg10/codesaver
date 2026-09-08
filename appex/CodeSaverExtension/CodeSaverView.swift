import AppKit
import ImageIO
import IOKit.ps
import ScreenSaver
import QuartzCore
import os.log

private let viewLog = AppexLog.logger("View")

// MARK: - Helpers

/// The scene's random stream (SplitMix64), seeded from system entropy at
/// launch — so the saver is as random as it ever was — but *reseedable*, so
/// the preview harness can replay a run frame-for-frame. Scrubbing a
/// timeline is only useful if the two frames you compare differ by the knob
/// you moved and nothing else. Main thread only, like the rest of the view.
private struct SaverRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
private var saverRNG = SaverRNG(state: UInt64.random(in: 0...UInt64.max))

@inline(__always) private func rand(_ a: Double, _ b: Double) -> Double {
    a < b ? Double.random(in: a...b, using: &saverRNG) : a
}

@inline(__always) private func clampd(_ v: Double, _ a: Double, _ b: Double) -> Double {
    min(max(v, a), b)
}

/// Box-Muller normal sample.
private func gaussRand(mean: Double, sigma: Double) -> Double {
    let u1 = Double.random(in: 1e-9...1, using: &saverRNG)
    let u2 = Double.random(in: 0...1, using: &saverRNG)
    return mean + sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

/// base + Exp(mean), capped: most samples land near base + mean, with a long tail.
private func expTail(base: Double, mean: Double, cap: Double) -> Double {
    min(cap, base - log(Double.random(in: 1e-9..<1, using: &saverRNG)) * mean)
}

/// Clamped smoothstep on 0…1.
@inline(__always) private func smooth01(_ x: Double) -> Double {
    let t = clampd(x, 0, 1)
    return t * t * (3 - 2 * t)
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

    /// Forgets the activation's session. Called when the last view goes
    /// away: the appex host process can outlive a single activation, and a
    /// static cache that survived would replay the previous desktop on the
    /// next wake no matter what the igniter just captured.
    static func release() {
        shared = nil
        attempted = false
    }

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
                                  verb: verbs.randomElement(using: &saverRNG) ?? "Idling")
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
    public var clockPadCells: CGFloat = 5      // blank cells each side of the digits
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

    /// How far the first front knocks the desktop down as it pixelates it:
    /// the mosaic is painted at this fraction of the captured color (1 = raw
    /// desktop, 0 = black), code spots dimming in step. 0.82 — an 18% cut —
    /// sits the mosaic just under the sharp desktop still ahead of the front,
    /// so the boundary reads as a conversion rather than a lighting change.
    /// CODESAVER_MOSAIC_DIM overrides it for snapshot sweeps.
    public var boomMosaicDim: Double =
        ProcessInfo.processInfo.environment["CODESAVER_MOSAIC_DIM"].flatMap(Double.init) ?? 0.82

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
    /// Field-claim starvation clock (see renderMetalFrame): wall time of the
    /// first frame this view was refused its field since the session
    /// anchored, and the rendered frames since. Both reset the moment a
    /// claim succeeds.
    private var fieldLostSince: Double = 0
    private var fieldLostFrames = 0
    private static let fieldLossGrace = 2.0

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
    /// One API request = prefill → decode; a turn chains requests with a
    /// tool-use wait between them (the ↑ stretch where the number freezes).
    private enum Step { case prefill, decode, toolWait }
    private var step = Step.prefill
    /// Session decode tok/s mean. Every request drifts it in a clamped
    /// mean-reverting walk — server jitter — and each decode samples its own
    /// rate around it.
    private var decodeRateMean: Double = 72
    private var segRate: Double = 0      // decode: mean tok/s of this step
    private var prefillBase: Double = 0  // counter at prefill start…
    private var prefillCount: Double = 0 // …lerping to base + count by step end
    private var segStart: Double = 0
    private var segEndsAt: Double = -1 // < 0 → no step started this turn
    private var prefillSurge: Double = 1.35 // typing mult while this prefill runs
    /// Mean-reverting wobble around the decode mean, continuous across steps —
    /// the moment-to-moment server load riding on top of each step's rate.
    private var rateJitter: Double = 1
    private var arrowIsDown = true
    private var nextStatusRoll: Double = 5
    /// The status suffix shows in continuous stints, decode-only. Starting a
    /// stint restarts the escalation ladder and rolls the stint's whole length
    /// up front — long-tailed, so the 45s "almost done coding" rung stays a
    /// rare event — capped to end at least a second before the decode segment
    /// does: a reply never completes on "still coding".
    private var statusShowing = false
    private var statusShowUntil: Double = 0
    private var statusEnteredAt: Double = 0
    private var frozenDoneText = ""
    /// Seconds at the start of a cycle where only the glyph + verb show,
    /// mirroring API latency before the first response chunk.
    private var parenDelay: Double = 2.5
    /// Eased global speed for the background typing: 1 while working (↓),
    /// slightly faster during ↑ upload bursts, slowest while the spinner rests.
    private var speedMul: Double = 1.0

    // MARK: Init

    /// Views alive in this process; the shared BoomSession is dropped when
    /// the count returns to zero (see BoomSession.release).
    private static var liveViews = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        Self.liveViews += 1
        animationTimeInterval = 1.0 / 30.0
        loadResources()
        startCycle(freshVerb: true)
        configureIntroFromEnv()
        Self.warmBoomPipelines()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.liveViews += 1
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
        // The corpus CodeSaver.app fetches at runtime beats anything bundled;
        // the sandboxed appex reaches it through the shared app-group container.
        if let dir = CorpusStore.corpusDirectory {
            resourceDirs.append(dir)
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

        // Verbs: "Gerund<TAB>Past" per line. Split on `isNewline`, not on
        // "\n" — Swift makes CRLF ONE Character, so a CRLF list has no "\n"
        // separator at all and came back as a single verb holding the whole
        // file. Trim the invisibles (BOM, ZWSP) a hand-edited list carries,
        // and compose: a Hangul or kana verb typed on macOS can arrive
        // decomposed, which the cell grid then measures a jamo at a time.
        let verbText = readFirst("spinner-verbs.txt")
            ?? "Coding\tCoded\nCompiling\tCompiled\nRefactoring\tRefactored\nShipping\tShipped"
        let verbTrim = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))
        verbs = verbText.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
                .map { $0.trimmingCharacters(in: verbTrim).precomposedStringWithCanonicalMapping }
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
            // The producer packs blocks back to back, so the index's last
            // byte IS the bin's last byte. Bounds alone can't tell a matched
            // pair from a NEW bin read against an OLD index (the two files
            // swap in separately, and the corpus normally grows): every old
            // block would still fit, and the session would slice the new
            // file at the old file's boundaries.
            guard blocks.map({ $0[0] + $0[1] }).max() == data.count else { continue }
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
            for pair in blocks.shuffled(using: &saverRNG).prefix(quota)
            where pair.count == 2 && pair[0] >= 0 && pair[1] > 0 {
                result.append(pair[0]..<(pair[0] + pair[1]))
            }
        }
        return result.shuffled(using: &saverRNG)
    }

    /// Swaps part of the session subset for freshly drawn blocks. Slots are
    /// chosen without replacement so `fraction` means what it says.
    private func rotateSubset(fraction: Double) {
        guard corpusData != nil, !fullIndex.isEmpty, blockRefs.count >= 8 else { return }
        let fresh = chooseSubset(budget: max(8, Int(Double(blockRefs.count) * fraction)))
        let slots = Array(0..<blockRefs.count).shuffled(using: &saverRNG).prefix(fresh.count)
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
        //
        // The claim only matters WHILE the field is being drawn. Once the
        // intro has ended (boomCore released) there is no field pass to
        // double-render, so the claim is never consulted again — a view that
        // never won its field must not hold black for the rest of the
        // session on that account.
        var owns = true
        if intro != .none, let session = boomSession {
            owns = session.claimField(boomFieldIndex, by: ObjectIdentifier(self))
        }
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
        // Backstop: migration and adoption are matters of moments. A view
        // still shut out of its field two seconds (and a run of rendered
        // frames — a main-thread stall must not count) after the stage was
        // set is not going to get one: it leaves the show and renders the
        // ordinary saver instead of a black display. Its display is either
        // one the manifest never described (hot-plugged after capture) or a
        // duplicate the host wedged on top of the owner; in both cases the
        // plain saver beats black.
        if !owns, boomSession?.isAnchored == true {
            let wall = CACurrentMediaTime()
            if fieldLostSince == 0 { fieldLostSince = wall }
            fieldLostFrames += 1
            if wall - fieldLostSince > Self.fieldLossGrace, fieldLostFrames >= 15 {
                BoomDiag.log("\(diagID) never won field \(boomFieldIndex) — leaving the boom, plain saver")
                leaveBoomSession()
                syncMetalContent()
                owns = true
            }
        } else {
            fieldLostSince = 0
            fieldLostFrames = 0
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
        frame.mosaicDim = boomMosaicDim
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
            // Zero-width characters claim no column and draw nothing.
            guard cells > 0, let slot = metal.glyphSlot(for: ch, cells: cells)
            else { return }
            // Size from the slot the atlas actually built, never from what we
            // asked for: a clamped request would otherwise stretch the glyph.
            let size = SIMD2(cw * Float(slot.cells), lh)
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
        pollWidgetFeed()   // warm the widget feed even while armed/booming
        pollAlbumArt()     // faster cadence: the tuning window republishes live
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
        // Widgets first: the saver's own statusline always composites
        // ABOVE the Claude panels. They exist through the boom, masked to
        // wiped cells like the clock; the feed was parsed while armed.
        buildWidgetQuads(&frame, metal: metal, scale: scale)
        if clockVisible { buildClockQuad(&frame, metal: metal) }
        buildBatteryQuad(&frame, metal: metal, scale: scale)
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
        // Centre of the arrow's silhouette, tip-relative (11.5 × 18.9).
        return NSPoint(x: o.x + 5.75, y: o.y + 9.5)
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
                // The recorded mouse point is the tip, so the raster hangs off
                // it by wherever the tip sits inside the image.
                frame.quads.append(.init(
                    key: "cursor",
                    rect: CGRect(x: o.x - Self.cursorTip.x,
                                 y: o.y - Self.cursorTip.y,
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

    private static let cursorSize = NSSize(width: 16, height: 24)

    /// Where the arrow's point sits inside the raster. Not (0,0): the tip is
    /// a MITERED corner, and its spike runs ~2.2 px up and left of the point
    /// itself — start at the edge and the sharp end gets clipped off. Whole
    /// pixels, so the arrow's vertical left edge lands ON a pixel column
    /// instead of straddling two and smearing the whole glyph.
    private static let cursorTip = NSPoint(x: 3, y: 3)

    /// The macOS arrow pointer, drawn by hand — NSCursor.arrow.image is
    /// EMPTY outside a real UI session (verified: 0×0, no reps, both in the
    /// headless harness and remote-view hosts), so the fake cursor is a
    /// vector twin: black fill, white outline, tip at `cursorTip`.
    private func makeCursorRaster(scale: CGFloat) -> CGImage? {
        rasterUI(size: Self.cursorSize, scale: scale) {
            // System-pointer proportions, measured off a screenshot: the head
            // is a 45° wedge out to the shoulder at (11.5, 11.4), then the
            // notch and the leg down to (6.8, 18.9). Tip-relative, y down.
            let pts: [(CGFloat, CGFloat)] = [
                (0, 0), (0, 16.5), (4.2, 12.4), (6.8, 18.9),
                (9.4, 17.8), (6.8, 11.4), (11.5, 11.4),
            ]
            let t = Self.cursorTip
            let p = NSBezierPath()
            p.move(to: NSPoint(x: t.x + pts[0].0, y: t.y + pts[0].1))
            for pt in pts.dropFirst() {
                p.line(to: NSPoint(x: t.x + pt.0, y: t.y + pt.1))
            }
            p.close()
            // Miter, not round: a pointer's tip is a POINT. Rounding it (and
            // the shoulder, and the leg) sanded every corner into a nub —
            // the silhouette was right and it still read as not-the-cursor.
            // 1.8 wide leaves 0.9 of white outside the black, like the real
            // one; 2.2 wore a fat halo.
            p.lineWidth = 1.8
            p.lineJoinStyle = .miter
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


    // MARK: - Battery meter (top right, on the clock's rail line)
    //
    // A light-box panel of the session / now-playing family — same grid
    // (`font`, `charW`, `lineH`), same rounded backdrop, same rails — set on
    // the clock's top rail and on the now-playing panel's right edge, so the
    // two labelled rails read as one line across the top of the screen. The
    // gauge inside is twenty character cells of `#` over `-` between
    // brackets: five percent a cell, quantised, ASCII. Not a drawn bar; not
    // a solid block run either, which at this size stops reading as type.
    //
    // Every state speaks in the TUI vocabulary: the estimate breaks the
    // bottom rail the way `session N tokens` does, charging reverse-videos
    // the fill's leading cell and blinks it at 0.5 Hz on whole seconds, and
    // ≤10% reverse-videos the percentage (steady — a screensaver should not
    // flash at you). No battery at all (a desktop) shows nothing.

    private struct BatteryReading {
        var pct: Int        // 0…100
        var ac: Bool
        var charging: Bool
        var mins: Int       // to empty / to full; -1 = still calculating
    }

    /// CODESAVER_BATTERY="pct=54 src=battery charging=0 mins=252" replaces the
    /// IOKit read entirely — the snapshot harness renders every state through
    /// it. pct=-1 is "no battery present", and the widget stays away.
    private static let batteryOverride: BatteryReading? = {
        guard let spec = ProcessInfo.processInfo.environment["CODESAVER_BATTERY"] else { return nil }
        var kv: [String: String] = [:]
        for field in spec.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let p = field.split(separator: "=", maxSplits: 1)
            if p.count == 2 { kv[String(p[0])] = String(p[1]) }
        }
        return BatteryReading(pct: kv["pct"].flatMap { Int($0) } ?? -1,
                              ac: kv["src"] != "battery",
                              charging: kv["charging"] == "1",
                              mins: kv["mins"].flatMap { Int($0) } ?? -1)
    }()

    private var batteryReading: BatteryReading?
    private var batteryPolledAt: Double = -1

    /// Live override for the preview harness's battery knobs: while enabled,
    /// these replace the IOKit read (and the env override) so every state
    /// can be dialled in by hand. Doubles because the harness's knobs are
    /// sliders. present < 0.5 = no battery (a desktop); mins < 0.5 = unknown.
    public var batteryDebugEnabled = false
    public var batteryDebugPresent: Double = 1
    public var batteryDebugPct: Double = 54
    public var batteryDebugAC: Double = 0
    public var batteryDebugCharging: Double = 0
    public var batteryDebugMins: Double = 252

    /// One power-source read a second, wall-clock stamped — never per frame.
    /// (The frame path only ever asks for the cached value.)
    private func currentBattery(wall: Double) -> BatteryReading? {
        if batteryDebugEnabled {
            guard batteryDebugPresent >= 0.5 else { return nil }
            return BatteryReading(pct: min(100, max(0, Int(batteryDebugPct.rounded()))),
                                  ac: batteryDebugAC >= 0.5,
                                  charging: batteryDebugCharging >= 0.5,
                                  mins: batteryDebugMins < 0.5 ? -1 : Int(batteryDebugMins.rounded()))
        }
        if let o = Self.batteryOverride { return o.pct >= 0 ? o : nil }
        if batteryPolledAt < 0 || wall - batteryPolledAt >= 1 {
            batteryPolledAt = wall
            batteryReading = Self.readPowerSource()
        }
        return batteryReading
    }

    /// The internal battery only: a UPS or a Bluetooth mouse is also a power
    /// source, and neither is what the top right corner is claiming to show.
    private static func readPowerSource() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let cap = d[kIOPSMaxCapacityKey] as? Int, cap > 0 else { continue }
            // "Charged" wins over "charging": at 100% on the mains macOS
            // leaves IsCharging true for a while, and a leading edge blinking
            // on a full bar is a lie.
            let charged = (d[kIOPSIsChargedKey] as? Bool) ?? false
            let charging = ((d[kIOPSIsChargingKey] as? Bool) ?? false) && !charged
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let mins = (charging ? d[kIOPSTimeToFullChargeKey]
                                 : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            let pct = Int((Double(cur) / Double(cap) * 100).rounded())
            return BatteryReading(pct: min(100, max(0, pct)), ac: ac,
                                  charging: charging, mins: mins)
        }
        return nil
    }

    /// What breaks the bottom rail: an estimate when there is one, the power
    /// source when there isn't. "still calculating" is not worth a word of
    /// its own — the rail simply says where the current is coming from.
    /// Split like `session 86.1k tokens`: the figure carries the weight, the
    /// words rest at the label grey.
    private func batteryRailLabel(_ b: BatteryReading) -> (figure: String, words: String) {
        func span(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
        if b.charging { return b.mins > 0 ? (span(b.mins), " to full") : ("", "charging") }
        if b.ac { return ("", b.pct >= 95 ? "charged \u{2219} on AC" : "on AC") }
        return b.mins > 0 ? (span(b.mins), " left") : ("", "on battery")
    }

    // Content changes once a second at most (the poll, or the charge blink),
    // so the whole build sits behind a content key and the per-frame cost is
    // one blit — the clock's arrangement, at a twentieth of its size.
    private struct BatteryCache {
        let key: String
        let image: CGImage
        let blitRect: NSRect
    }
    private var batteryCache: BatteryCache?

    /// Ink centre of a box-drawing rule below the top of a drawn line, so a
    /// rail set in one size can be laid on a rail set in another.
    private func railDrop(_ f: NSFont) -> CGFloat { f.pointSize * 0.67 }

    private func buildBatteryQuad(_ frame: inout BoomMetalRenderer.FrameInput,
                                  metal: BoomMetalRenderer, scale: CGFloat) {
        guard !Self.widgetsDisabled, let base = font else { return }
        guard let b = currentBattery(wall: Date().timeIntervalSince1970) else { return }
        let label = batteryRailLabel(b)
        // Quantised to whole seconds of the same clock the saver animates on:
        // one second lit, one second dark, never a fade. The epsilon is the
        // 1/30 accumulation drift PreviewMain warns about — without it a
        // frame asked for at exactly t=3s lands in the previous second.
        let lit = b.charging && Int((now + 1e-6).rounded(.down)) % 2 == 0
        let key = "\(b.pct)|\(b.ac)|\(b.charging)|\(label.figure)|\(label.words)|\(lit)|" +
            "\(Int(bounds.width))x\(Int(bounds.height))|\(scale)|\(base.pointSize)|\(clockTopFrac)"
        if batteryCache?.key != key {
            batteryCache = buildBatteryCache(key: key, b, label: label, lit: lit, scale: scale)
        }
        guard let cache = batteryCache else { return }
        // The gauge sits on the clock's rail to the RIGHT of the box. On a
        // narrow screen (portrait, or a 9:16 story render) the clock spans
        // most of the width and the two would overprint; a rail that can't
        // be shared is not shown at all.
        if clockVisible, let clock = clockCache?.blitRect,
           cache.blitRect.insetBy(dx: -charW * 2, dy: 0).intersects(clock) { return }
        metal.setUITexture("battery", image: cache.image)   // ≤1 Hz re-upload
        frame.quads.append(.init(key: "battery", rect: cache.blitRect,
                                 maskToWipedCells: intro == .boom))
    }

    private func buildBatteryCache(key: String, _ b: BatteryReading,
                                   label: (figure: String, words: String),
                                   lit: Bool, scale: CGFloat) -> BatteryCache? {
        guard let base = font else { return nil }
        let cells = 20                       // one cell = five percent
        // Every row is exactly this many cells:
        //   │ + sp + [ + bar + ] + sp + 5-cell value + sp + │
        let rowW = cells + 12
        let fillCh = "#", emptyCh = "-"

        let railC = NSColor(white: 0.26, alpha: 1)
        let labelC = NSColor(deviceRed: 0.31, green: 0.35, blue: 0.39, alpha: 1)   // the clock's date grey
        let valueC = NSColor(deviceRed: 0.43, green: 0.48, blue: 0.53, alpha: 1)
        let fillC = NSColor(white: 0.46, alpha: 1)
        let emptyC = NSColor(white: 0.18, alpha: 1)
        let edgeC = NSColor(white: 0.62, alpha: 1)      // reverse-video field
        let holeC = NSColor(white: 0.04, alpha: 1)      // the glyph punched out of it
        func run(_ s: String, _ c: NSColor, on bg: NSColor? = nil) -> NSAttributedString {
            var a: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: c]
            if let bg { a[.backgroundColor] = bg }
            return NSAttributedString(string: s, attributes: a)
        }

        // ── ╭─ /* battery */ ────╮ — the clock's comment style, because this
        // box shares the clock's line; the light rails keep it panel family.
        let head = "/* battery */"
        let top = NSMutableAttributedString()
        top.append(run("\u{256D}\u{2500} ", railC))
        top.append(run(head, labelC))
        top.append(run(" " + String(repeating: "\u{2500}", count: max(0, rowW - 5 - head.count))
                       + "\u{256E}", railC))

        // ── │ [##########----------]  54% │
        // At least one cell of fill while there is any charge at all: an
        // empty bracket is what "no battery" would look like.
        var k = Int((Double(b.pct) / 100 * Double(cells)).rounded())
        if b.pct > 0 { k = max(1, k) }
        k = min(cells, k)
        let mid = NSMutableAttributedString()
        mid.append(run("\u{2502} [", railC))
        if b.charging {
            // The leading edge: the last filled cell (or the first empty one
            // at zero), reverse video on the lit second.
            let lead = max(0, k - 1)
            mid.append(run(String(repeating: fillCh, count: lead), fillC))
            let edge = k > 0 ? fillCh : emptyCh
            mid.append(lit ? run(edge, holeC, on: edgeC) : run(edge, k > 0 ? fillC : emptyC))
            mid.append(run(String(repeating: fillCh, count: max(0, k - lead - 1)), fillC))
            mid.append(run(String(repeating: emptyCh, count: cells - max(k, lead + 1)), emptyC))
        } else {
            mid.append(run(String(repeating: fillCh, count: k), fillC))
            mid.append(run(String(repeating: emptyCh, count: cells - k), emptyC))
        }
        mid.append(run("] ", railC))
        // Five cells of value field, right aligned; ≤10% turns it inside out.
        let value = "\(b.pct)%"
        if b.pct <= 10 && !b.ac {
            mid.append(run(String(repeating: " ", count: max(0, 3 - value.count)), valueC))
            mid.append(run(" " + value + " ", holeC, on: valueC))
        } else {
            mid.append(run(String(repeating: " ", count: max(0, 5 - value.count)) + value, valueC))
        }
        mid.append(run(" \u{2502}", railC))

        // ── ╰──────── 4h 12m left ─╯
        let bot = NSMutableAttributedString()
        let labelLen = label.figure.count + label.words.count
        bot.append(run("\u{2570}" + String(repeating: "\u{2500}",
                                           count: max(0, rowW - 5 - labelLen)) + " ", railC))
        bot.append(run(label.figure, valueC))
        bot.append(run(label.words, labelC))
        bot.append(run(" \u{2500}\u{256F}", railC))

        let rows = [top, mid, bot]
        let pad: CGFloat = 6
        let width = rows.reduce(CGFloat(0)) { max($0, $1.size().width) }
        let size = NSSize(width: width + pad * 2, height: lineH * CGFloat(rows.count) + pad * 2)
        guard let img = rasterUI(size: size, scale: scale, {
            NSColor.black.withAlphaComponent(0.87).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                         xRadius: 3, yRadius: 3).fill()
            for (i, row) in rows.enumerated() {
                row.draw(at: NSPoint(x: pad, y: pad + CGFloat(i) * lineH))
            }
        }) else { return nil }

        // Right edge: the now-playing panel's, to the pixel. Top: the clock's
        // top rail — matched on the RULE's ink, not on the line box, or two
        // rails set fourteen points apart in size would sit visibly astray.
        let x = bounds.width - leftInset - CGFloat(rowW + 1) * charW - 12
        let clockRail = bounds.height * clockTopFrac
            + railDrop(monoFont(bounds.height * clockScale, .regular))
        let y = clockRail - railDrop(base) - pad
        return BatteryCache(key: key, image: img,
                            blitRect: NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    // MARK: - Widget panels (live Claude Code sessions + now playing)
    //
    // Reads widgets/feed.json — written into the app-group container by
    // `CodeSaver --feeds` (FeedsService.swift), which merges Claude Code
    // hook state, bifrocate CoT spools, and the local music player. Panels
    // follow the approved design: rounded TUI boxes bottom-left, one per
    // live session, glyph in Claude orange (orange = actual Claude Code;
    // violet stays the saver's own theater), music bottom-right. A stale
    // feed (daemon gone) removes every panel — never show frozen state as
    // if it were live. A session pinned in bifrocate (its pin daemon keeps
    // the prompt cache warm with keep-alive pings) rests as
    // `✻ Pinned (next ping in 35m ∙ 2h 32m ago)` and sits above the other
    // resting panels.
    //
    // The music panel's art box is there from a track's first frame, sized
    // from the saved tuning. While the cover is on its way it is a CRT seen
    // by a fast camera: no beam, no band — the whole box is one brightness
    // gradient, phosphor age since the write position passed, rolling down
    // and wrapping, every cell a symbol-ramp glyph; when the cover lands the
    // same pass writes it in. A track with no cover rests the field, still
    // and dim. Paused music stays — the feed holds it for half an hour — the
    // cover stepped back under a small ■ PAUSED box.

    private struct WidgetSession {
        var cwd = "?"
        var state = "done"
        var tool: String?
        var turnStarted: Double?
        var turnEnded: Double?
        var turnTokens: Int?
        var sessionTokens: Int?
        var lastActive: Double?
        var stateSince: Double?
        var bg: [String: Int] = [:]
        var pin: WidgetPin?
    }

    /// bifrocate's pin daemon has this session (feed `pin`). `fresh` is
    /// false when the daemon hasn't written its state lately.
    private struct WidgetPin {
        var pinnedAt: Double = 0
        var status: String?
        var nextPingAt: Double?
        var pingedAt: Double?
        var fresh = true
    }

    private struct WidgetFeed {
        var updated: Double = 0
        var sessions: [WidgetSession] = []
        var npApp: String?, npTitle = "", npArtist = ""
        var npPos: Double = 0, npDur: Double = 0, npTS: Double = 0
        /// "playing" or "paused" (the daemon drops a pause after 30 min).
        var npState: String?, npPausedSince: Double?
    }

    private var widgetFeed = WidgetFeed()
    private var widgetPollAt: Double = 0
    private var widgetFeedMTime: Date?

    // Album art (fed by widgets/albumart.json; on/off from widgets/settings.json)
    private var artOn = false
    private var artKey = ""                // "app|title|artist" the grid belongs to
    /// The published cover. nil under a key that matches the track means the
    /// daemon looked and the track has none.
    private var artGrid: AlbumArtGrid?
    private var artMTime: Date?
    private var artSettingsMTime: Date?
    /// The saved tuning's grid size, refreshed when the tuning file changes.
    /// The art box is sized from THIS before any cover arrives, so the panel
    /// is exactly as wide while loading as it will be with the cover in it.
    private var artParams = AlbumArtRamp.Params()
    private var artTuningMTime: Date?
    /// Laid-out art rows, cached per (track, font size). Caching the
    /// LAYOUT rather than a bitmap keeps the art on the panel's own character
    /// grid — a rasterized copy could only ever be composited at some pixel
    /// offset, which is what threw its columns out of line with the chrome.
    private var artRowsCache: (key: String, pt: CGFloat, cols: Int,
                               rows: [NSAttributedString])?
    /// Budget-fitted re-renders, once per (published grid, size, tuning) —
    /// `published` is albumart.json's mtime, so a knob turn or a new source
    /// image in the tuner re-renders even at the same size.
    private var artFitCache: (key: String, cols: Int, rows: Int,
                              tuning: Date?, published: Date?, grid: AlbumArtGrid?)?
    private var artPollAt: Double = 0
    /// The track the panel is on and when it first showed — the placeholder's
    /// clock — and when its cover landed — the reveal's.
    private var npTrackKey = ""
    private var npTrackSince: Double = 0
    private var artShownSince: Double?
    /// Whether the track on the panel replaced an earlier one in this saver
    /// session. The first track the saver sees is shown as it is; a change
    /// always earns the wave, even when title and cover land in one frame.
    private var npTrackChanged = false
    /// Pause/play as the panel last saw it, and when it changed — the dimming
    /// wave's clock. nil until the first sight, which is never animated.
    private var npPauseKnown: Bool?
    private var npPauseChangedAt: Double?
    /// Composited art rows (placeholder, reveal, paused overlay), keyed on
    /// everything they were built from: a static state costs one build, an
    /// animated one a build per quantised tick.
    private var artFXCache: (key: String, rows: [NSAttributedString])?
    /// Ceiling for the music panel, expressed as a LINE BUDGET — this is a
    /// text UI, and "N lines" means something here in a way that a percentage
    /// of the display never did. The effective ceiling is whichever sits
    /// lower, this budget or the statusline's bottom.
    /// TODO: deliberately absurd. On every display tested the statusline is
    /// the binding constraint and this never fires; it exists so an
    /// ultra-large display can't hand the panel a comical amount of room.
    /// Tune it the day one actually bites.
    private let npMaxLines: CGFloat = 60

    private let ccOrange = NSColor(displayP3Red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    private let ccOrangeHot = NSColor(displayP3Red: 0.941, green: 0.647, blue: 0.522, alpha: 1)

    /// CODESAVER_WIDGETS=0 leaves the live feed out entirely — the session
    /// timers tick with the wall clock, which is the one thing a seeded
    /// snapshot run cannot pin.
    private static let widgetsDisabled =
        ProcessInfo.processInfo.environment["CODESAVER_WIDGETS"] == "0"

    private func pollWidgetFeed() {
        guard !Self.widgetsDisabled, now >= widgetPollAt else { return }
        widgetPollAt = now + 1.0
        guard let url = CorpusStore.widgetsDirectory?
            .appendingPathComponent("feed.json") else { return }
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        if let m, m == widgetFeedMTime { return }   // unchanged since last decode
        widgetFeedMTime = m
        var feed = WidgetFeed()
        defer { widgetFeed = feed }
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        feed.updated = obj["updated"] as? Double ?? 0
        for raw in obj["sessions"] as? [[String: Any]] ?? [] {
            var w = WidgetSession()
            // Composed: the panel measures cells per Character, and a
            // decomposed syllable is several of those.
            w.cwd = (raw["cwd"] as? String ?? "?").precomposedStringWithCanonicalMapping
            w.state = raw["state"] as? String ?? "done"
            w.tool = (raw["tool"] as? String)?.precomposedStringWithCanonicalMapping
            w.turnStarted = raw["turn_started"] as? Double
            w.turnEnded = raw["turn_ended"] as? Double
            w.turnTokens = raw["turn_tokens"] as? Int
            w.sessionTokens = raw["session_tokens"] as? Int
            w.lastActive = raw["last_active"] as? Double
            w.stateSince = raw["state_since"] as? Double
            w.bg = raw["bg"] as? [String: Int] ?? [:]
            if let p = raw["pin"] as? [String: Any] {
                var pin = WidgetPin()
                pin.pinnedAt = p["pinned_at"] as? Double ?? 0
                pin.status = p["status"] as? String
                pin.nextPingAt = p["next_ping_at"] as? Double
                pin.pingedAt = p["pinged_at"] as? Double
                pin.fresh = p["fresh"] as? Bool ?? true
                w.pin = pin
            }
            feed.sessions.append(w)
        }
        if let np = obj["nowplaying"] as? [String: Any] {
            feed.npApp = np["app"] as? String
            feed.npTitle = (np["title"] as? String ?? "").precomposedStringWithCanonicalMapping
            feed.npArtist = (np["artist"] as? String ?? "").precomposedStringWithCanonicalMapping
            feed.npPos = np["position"] as? Double ?? 0
            feed.npDur = np["duration"] as? Double ?? 0
            feed.npTS = np["ts"] as? Double ?? 0
            feed.npState = np["state"] as? String
            feed.npPausedSince = np["paused_since"] as? Double
        }
    }

    private func widgetHexColor(_ s: String) -> NSColor? {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 4 Hz: the on/off switch from the host app, the saved tuning's size,
    /// and the art grid from the daemon — or from the tuning window, which
    /// republishes on every knob turn.
    private func pollAlbumArt() {
        guard !Self.widgetsDisabled, now >= artPollAt else { return }
        artPollAt = now + 0.25
        let fm = FileManager.default
        guard let dir = CorpusStore.widgetsDirectory else { return }
        func mtime(_ u: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        }
        let sURL = dir.appendingPathComponent("settings.json")
        let sM = mtime(sURL)
        if sM != artSettingsMTime {
            artSettingsMTime = sM
            // Anything but "none" is on: a settings file still naming the
            // retired braille style reads as on, not off.
            if let d = try? Data(contentsOf: sURL),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let st = o["albumArtStyle"] as? String {
                artOn = st != "none"
            } else {
                artOn = false
            }
        }
        guard artOn else { return }
        // Compare the OPTIONAL: a deleted tuning file means "back to the
        // defaults", which is a size change like any other.
        let tM = AlbumArtTuning.url.flatMap(mtime)
        if tM != artTuningMTime {
            artTuningMTime = tM
            artParams = AlbumArtRamp.Params(json: AlbumArtTuning.load()["ramp"] ?? [:])
        }
        let aURL = dir.appendingPathComponent("albumart.json")
        let aM = mtime(aURL)
        guard aM != artMTime else { return }
        artMTime = aM
        artRowsCache = nil
        artFitCache = nil
        artGrid = nil
        artKey = ""
        guard let d = try? Data(contentsOf: aURL),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let key = o["key"] as? String else { return }
        artKey = key
        if let g = o["ramp"] as? [String: Any] { artGrid = AlbumArtGrid(json: g) }
    }

    /// The art box for a height budget: a cols × rows grid, shrunk — both
    /// together, so the cover stays square — when its natural height overruns
    /// the room. nil when even that would be a smudge; then the panel has no
    /// art box at all. The placeholder (sized from the saved tuning) and the
    /// fitted cover go through this SAME rule, which is what keeps the
    /// panel's width from jumping when the cover lands. Never scales the
    /// FONT: glyphs at a scaled size have a different advance and can never
    /// sit on the panel's cell grid — that was the misalignment.
    private func artBox(cols: Int, rows: Int, room: CGFloat) -> (cols: Int, rows: Int)? {
        guard cols > 0, rows > 0 else { return nil }
        let naturalH = AlbumArtGrid.rowStep(charW: charW) * CGFloat(rows)
        if naturalH <= room { return (cols, rows) }
        let s = room / max(1, naturalH)
        guard s >= 0.45 else { return nil }          // below this it's a smudge
        return (max(8, Int((CGFloat(cols) * s).rounded(.down))),
                max(4, Int((CGFloat(rows) * s).rounded(.down))))
    }

    /// Rasterize the art grid once per (track, font size); the cached rows
    /// are then drawn into the per-frame panel raster.
    private func albumArtRows(_ grid: AlbumArtGrid) -> [NSAttributedString] {
        if let c = artRowsCache, c.key == artKey, c.pt == font!.pointSize,
           c.cols == grid.cols {
            return c.rows
        }
        let rows = grid.attributedRows(baseFont: font!)
        artRowsCache = (artKey, font!.pointSize, grid.cols, rows)
        return rows
    }

    /// The published grid when it fits the height budget; otherwise the art
    /// RE-RENDERED at the box's size (the renderer is native and in-process),
    /// so every glyph stays at the panel's own cell size, on cell boundaries.
    private func fittedArtGrid(room: CGFloat) -> AlbumArtGrid? {
        guard let g = artGrid,
              let box = artBox(cols: g.cols, rows: g.rows, room: room) else { return nil }
        if box.cols == g.cols, box.rows == g.rows { return g }   // native size fits
        if let c = artFitCache, c.key == artKey, c.cols == box.cols, c.rows == box.rows,
           c.tuning == artTuningMTime, c.published == artMTime {
            return c.grid
        }
        // Re-render from what the PUBLISHED grid was rendered from: the
        // tuner publishes its live knobs and the image it opened alongside
        // the grid, so a fit-down in the tuning window tracks the sliders
        // and the picked cover, not the last-saved tuning and whatever track
        // is playing. The daemon's grids carry neither, and fall back to the
        // saved tuning over the current track's art.
        var grid: AlbumArtGrid?
        let fm = FileManager.default
        let srcURL = g.sourcePath.flatMap { fm.isReadableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            ?? CorpusStore.widgetsDirectory?.appendingPathComponent("albumart-src.img")
        if let srcURL,
           let isrc = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) {
            var p = g.tuning.map { AlbumArtRamp.Params(json: $0["ramp"] ?? [:]) } ?? artParams
            p.cols = Double(box.cols)
            p.rows = Double(box.rows)
            grid = AlbumArtRamp.render(img, params: p).flatMap { AlbumArtGrid(json: $0) }
        }
        artFitCache = (artKey, box.cols, box.rows, artTuningMTime, artMTime, grid)
        return grid
    }

    // MARK: Art box compositing — the phosphor field, the write position, the paused box

    /// Per-cell jitter in 0..1, stable across frames: the lattice the field
    /// is sampled from, and each cell's own rounding offset for tone.
    private func artHash(_ i: Int, _ j: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: i &* 1619 &+ j &* 31337)
        x ^= x >> 16; x &*= 0x7feb352d; x ^= x >> 15; x &*= 0x846ca68b; x ^= x >> 16
        return Double(x & 0xffff) / 65535
    }

    /// Smoothed value noise over that lattice — four hashes and a cubic
    /// fade, no trig.
    private func artNoise(_ x: Double, _ y: Double) -> Double {
        let x0 = floor(x), y0 = floor(y)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let i0 = Int(x0), j0 = Int(y0)
        let a = artHash(i0, j0), b = artHash(i0 + 1, j0)
        let c = artHash(i0, j0 + 1), d = artHash(i0 + 1, j0 + 1)
        let top = a + (b - a) * sx, bot = c + (d - c) * sx
        return top + (bot - top) * sy
    }

    /// Measured ink per ramp glyph (ramp.py --measure), for colour
    /// compensation: a sparse glyph is handed a brighter colour so the two
    /// multiply back onto one tonal curve, exactly as the art does it.
    private static let artInk: [Character: Double] =
        Dictionary(uniqueKeysWithValues: AlbumArtRamp.ramp.map { ($0.glyph, $0.ink) })

    /// The tone ramp for everything the box draws itself: the art ramp's
    /// SYMBOLS only, in measured-ink order. A row of one letter — XXXXXXXX —
    /// reads as type; a row of these reads as tone.
    private static let artToneRamp: [Character] = [" ", "\u{00B7}", "-", ":", "!", "/", "+", "=", "*", "%", "#"]

    /// Tone → glyph, dithered: each cell rounds with its own stable offset,
    /// so a flat region is texture rather than a repeated character, and a
    /// moving gradient changes glyph a few cells at a time instead of a
    /// whole row at once.
    private func artToneGlyph(_ tone: Double, _ i: Int, _ j: Int) -> Character {
        let steps = Double(Self.artToneRamp.count)
        let idx = Int(min(steps - 1, max(0, floor(tone * steps + artHash(i, j) - 0.5))))
        return Self.artToneRamp[idx]
    }

    /// The box's three lights: the blue-grey the field sits in, the panel's
    /// own accent for the sweep's body, near-white for its crest.
    private static let artFieldC: SIMD3<Float> = [0.44, 0.52, 0.64]
    private static let artBeamC: SIMD3<Float> = [0.66, 0.90, 1.0]
    private static let artGlowC: SIMD3<Float> = [0.93, 0.98, 1.0]

    /// The phosphor's clock. LOADING: the write position crosses the box
    /// once every `artRoll` seconds, forever. REVEAL: the same beam, one
    /// faster lap (`artPaint`) that leaves the cover behind it, then
    /// `artSettle` for the rows it wrote last to cool off.
    private static let artRoll = 2.0            // one full roll; shipped at 3.5, then 20% and 30% faster on Michel's asks
    /// Loading breathes: the light the write position lays down swings
    /// between these levels on a slow sine. Each row then decays from the
    /// level it was WRITTEN at — the tail is the front's history scrolled
    /// down — so nothing pulses as a whole. Slow, because the breath's
    /// wavelength down the box is (breath / roll) box heights: at 4.3 s over
    /// a 2 s roll well under half a cycle is ever in view, a tilt rather
    /// than a band. Not a multiple of the roll, so no lap repeats exactly.
    private static let artBreathLo: Float = 0.60
    private static let artBreathHi: Float = 0.90
    private static let artBreath = 4.3
    private static let artPaint = artRoll        // the reveal IS the next wave: one lap at the roll's speed
    /// The pause wave: the paused look closes in from the box's edges over
    /// this many seconds, and opens back out from the centre on resume.
    private static let artPauseWave = 0.6              // was 0.9; Michel: "50% faster"
    /// The card's choreography, the spinner's teleport in miniature. On the
    /// way in (the wave has closed on the centre): a single-cell blip, a
    /// beat of nothing, then the card under a decaying arrival flash. On the
    /// way out (the wave starts to open): the card lifts under a departure
    /// flash, and a blip closes the spot.
    private static let artCardBlipIn = 0.06, artCardGapIn = 0.12, artCardFlashIn = 0.26
    private static let artCardFlashOut = 0.16, artCardBlipOut = 0.10

    /// The ■ PAUSED card's cells inside the art box: origin column and row,
    /// width, and its three rows. One definition for the glyphs and for the
    /// flash drawn over them.
    private func artCardRect(cols: Int, rows: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let w = (cols >= 16 ? " \u{25A0} PAUSED " : " PAUSED ").count + 2
        return ((cols - w) / 2, rows / 2 - 1, w, 3)
    }
    private static let artSettle = 0.30

    /// The beam's spot, in rows: how far AHEAD of the write position the
    /// phosphor is already lit. It is what turns the wrap from a cut into a
    /// seam — and it makes the whole thing continuous in time as well as in
    /// space, because a row rises to full over the last couple of rows
    /// instead of flashing on when the beam arrives.
    private static let artSpot = 1.0

    /// The field's tone floor and ceiling. The floor is high enough that
    /// every cell keeps a glyph — a blank cell in a dense field reads as a
    /// hole. The ceiling stops SHORT of the ramp's top on purpose: at 1.0
    /// every cell of the freshest rows clamps to '#' and they stack into a
    /// slab; held here they dither across * % #, which reads as a surface
    /// with light on it.
    private static let artToneLo = 0.15
    private static let artToneHi = 0.90
    private static let artToneFloor = 0.14           // after grain: still at least ·

    /// What the field lies at when there is no beam: the rest a coverless
    /// track settles into, and the field under the paused box.
    private static let artRestHot = 0.13

    /// Measured ink for the tone ramp's own glyphs, in ramp order, so a
    /// row's ink compensation can be interpolated ALONG the ramp instead of
    /// stepping as the gradient rolls past a glyph boundary.
    private static let artToneInk: [Double] =
        CodeSaverView.artToneRamp.map { CodeSaverView.artInk[$0] ?? 0 }

    /// Ink compensation from a measured coverage: a sparse glyph is handed
    /// a brighter colour so glyph and colour multiply back onto one tonal
    /// curve, exactly as the art's own compositing does it.
    @inline(__always) private func artInkComp(_ ink: Double) -> Float {
        Float(pow(AlbumArtRamp.aRef / max(ink, 1), 0.30))
    }

    /// Phosphor age → light, 0…1. Age is measured in LAPS of the box: 0
    /// where the beam has just written, 1 for the row it is about to reach,
    /// so the decay is spread over the whole box height — the box is the
    /// beam. Behind the write position the light falls off continuously;
    /// ahead of it the beam's own spot lifts the last rows back to full, so
    /// the only place the gradient turns sharply is the write position
    /// itself, and even there nothing jumps.
    ///
    /// A row the beam will never come back to — the reveal's wake — takes
    /// `wrapped: false`: no spot (the beam is a whole lap away, not about to
    /// arrive) and a gentler fall, so the cover it just printed stays
    /// overexposed for a while and settles evenly instead of dropping into
    /// its own blacks two rows behind the write position.
    private func artPhosphor(_ age: Double, rows: Int, wrapped: Bool = true) -> Double {
        let a = min(1, max(0, age))
        guard wrapped else { return pow(1 - a, 0.85) }
        // Two terms, because one will not do it. The exponential is the
        // phosphor's own fall — steep for the first rows after the beam, so
        // the crest stays a crest instead of stacking five bright rows —
        // and the linear tail carries the rest of the ramp all the way down
        // to · at the far side of the box.
        let decay = 0.55 * exp(-3.8 * a) + 0.45 * pow(1 - a, 1.35)   // "slightly more aggressive" than 3.0 / 1.1
        let ahead = (1 - a) * Double(rows) / Self.artSpot
        let spot = exp(-ahead * ahead)
        return decay + (1 - decay) * spot
    }

    /// A whole ROW's ink compensation, interpolated along the ramp from the
    /// row's own tone. Per cell this would hand every glyph its own colour
    /// and break the row into runs — and the eye reads those seams as
    /// tearing; per row it still keeps the dim end of the gradient from
    /// going thin, and the row stays one colour.
    private func artRowComp(_ tone: Double) -> Float {
        let n = Self.artToneRamp.count
        let p = min(Double(n - 1), max(1, tone * Double(n) - 0.5))
        let i0 = Int(p), i1 = min(n - 1, Int(p) + 1)
        let ink = Self.artToneInk[i0] + (Self.artToneInk[i1] - Self.artToneInk[i0]) * (p - Double(i0))
        return artInkComp(ink)
    }

    /// Everything a row's age decides, worked out once per row: the tone its
    /// glyphs are picked from, the one colour every cell in it is drawn in,
    /// and the halo under them.
    private struct ArtRowLight { var tone: Double; var color: SIMD3<Float>; var glow: Float }

    private func artRowLight(_ hot: Double, dim: Float) -> ArtRowLight {
        let tone = Self.artToneLo + (Self.artToneHi - Self.artToneLo) * hot
        let h = Float(hot)
        var c = mix3(Self.artFieldC, Self.artBeamC, min(1, h * 1.40))
        c = mix3(c, Self.artGlowC, max(0, min(1, (h - 0.75) / 0.25)))
        let v = min(1, (0.30 + 0.70 * h) * artRowComp(tone))
        // `dim` is the state's level — loading is held well under the reveal
        // so it never demands attention — and the halo follows it.
        return ArtRowLight(tone: tone, color: c * v * dim,
                           glow: max(0, min(1, (h - 0.78) / 0.22)) * 0.85 * dim)
    }

    /// The grain the field is written with: each cell's own stable offset,
    /// plus a slow swell over the lattice so the surface breathes. Together
    /// they are worth about one ramp step. Grain moves the GLYPH only —
    /// never the colour, never the halo — so the row is still one run and
    /// there is nothing for the eye to tear along.
    private func artGrain(_ i: Int, _ j: Int, t: Double) -> Double {
        (artHash(i &+ 7, j &+ 131) - 0.5) * 0.085
            + (artNoise(Double(i) * 0.30 + t * 0.13, Double(j) * 0.55 - t * 0.09) - 0.5) * 0.115
    }

    private struct ArtRunKey: Equatable { var r, g, b: UInt8; var glow: UInt8 }

    /// Attributed rows from a per-cell (glyph, colour, glow) painter.
    /// Neighbours sharing colour and glow merge into one run, so a flat
    /// region costs one attributed run rather than one per cell. Glow is
    /// phosphor bloom: a shadow of the run's own colour, blurred wider and
    /// laid heavier the brighter the cell — the same trick the hero glyph
    /// uses — in sixteen steps. (Eight was enough while glow varied per
    /// cell and steps bought run merges; here glow is a whole row's, so the
    /// only thing the steps cost is a visible tick in the halo as the
    /// gradient rolls through one.)
    private func artComposeRows(cols: Int, rows: Int, base: NSFont,
                                _ cell: (Int, Int) -> (Character, SIMD3<Float>, Float))
        -> [NSAttributedString] {
        func q8(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        var out: [NSAttributedString] = []
        out.reserveCapacity(rows)
        for j in 0..<rows {
            let row = NSMutableAttributedString()
            var run = ""
            var key: ArtRunKey?
            func flush() {
                guard let k = key, !run.isEmpty else { return }
                let color = NSColor(deviceRed: CGFloat(k.r) / 255, green: CGFloat(k.g) / 255,
                                    blue: CGFloat(k.b) / 255, alpha: 1)
                var attrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color]
                if k.glow > 0 {
                    // The typing cursor's halo, exactly: a near-white shadow
                    // blur at 0.6 × the font size, its intensity the cell's
                    // glow, drawn once under a crisp glyph. Wider, tinted,
                    // or doubled it stops being a halo and becomes a smear.
                    let g = CGFloat(k.glow) / 16
                    let sh = NSShadow()
                    sh.shadowColor = NSColor(deviceRed: CGFloat(Self.artGlowC.x),
                                             green: CGFloat(Self.artGlowC.y),
                                             blue: CGFloat(Self.artGlowC.z), alpha: 0.9 * g)
                    sh.shadowBlurRadius = base.pointSize * 0.6
                    sh.shadowOffset = .zero
                    attrs[.shadow] = sh
                }
                row.append(NSAttributedString(string: run, attributes: attrs))
                run = ""
            }
            for i in 0..<cols {
                let (ch, c, glow) = cell(i, j)
                let k = ArtRunKey(r: q8(c.x), g: q8(c.y), b: q8(c.z),
                                  glow: UInt8(max(0, min(16, (glow * 16).rounded()))))
                if k != key { flush(); key = k }
                run.append(ch)
            }
            flush()
            out.append(row)
        }
        return out
    }

    private static func artRGB(_ hex: String) -> SIMD3<Float> {
        var h = Substring(hex)
        if h.hasPrefix("#") { h = h.dropFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .zero }
        return SIMD3<Float>(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }

    /// What the art box shows this frame. The plain cover is the cached
    /// layout straight through; everything else — the phosphor field rolling
    /// while the cover is on its way (12 s, or until the daemon says the
    /// track has none), the roll's next wave printing the cover from the top
    /// once it has landed, the paused box over either — is composited per
    /// cell, animated states at a quantised clock.
    ///
    /// The whole box is the beam. There is no band and no background: the
    /// brightness of every row is the age of its phosphor, measured from the
    /// last time the write position passed it, decaying over one full box
    /// height. The gradient rolls down, and the only place it turns is the
    /// write position itself.
    private func artBoxRows(box: (cols: Int, rows: Int), grid: AlbumArtGrid?, key: String,
                            paused: Bool, pauseChangedAt: Double?, cardOn: Bool,
                            base: NSFont) -> [NSAttributedString] {
        let cols = box.cols, rows = box.rows
        let paint = Self.artPaint, settle = Self.artSettle   // the write lap, then its cooling
        // The cover is handed over whenever the daemon lands it, but the beam
        // only writes it from the TOP: the reveal waits for the roll's next
        // wrap and is the next wave down, at the roll's own speed. Until then
        // the field keeps rolling exactly as it was, cover in hand — the
        // handover is invisible. A lap started mid-box at another speed read
        // as the picture's opacity coming up, not as a wave writing it. If
        // the roll had already stopped (a coverless rest), the wave starts
        // at once.
        // No wave for the first track the saver sees when its cover is
        // already there — the saver starting with music on — the picture is
        // simply shown. Every later track change earns the wave, even when
        // title and cover land in the same frame: the daemon publishes them
        // about a second apart and the saver polls the feed once a second,
        // so "cover present at first sight" is the COMMON case for a change,
        // not a sign that nothing happened.
        let shownT = artShownSince.map { $0 - npTrackSince }
            .flatMap { $0 > 0.05 || npTrackChanged ? $0 : nil }
        let revealAt: Double? = shownT.map { s in
            let wait = s < 12
                ? (Self.artRoll - s.truncatingRemainder(dividingBy: Self.artRoll))
                    .truncatingRemainder(dividingBy: Self.artRoll)
                : 0
            return s + wait
        }
        let revealing = grid != nil
            && (revealAt.map { (now - npTrackSince) - $0 < paint + settle } ?? false)
        let loading = grid == nil && artKey != key && now - npTrackSince < 12
        let waving = pauseChangedAt.map { now - $0 < Self.artPauseWave } ?? false
        if let grid, !revealing, !paused, !waving { return albumArtRows(grid) }

        let live = loading || revealing || waving
        // One quantised clock for everything that moves, and it goes in the
        // cache key: a frame inside a tick is a hit, and a state that isn't
        // animated (tick 0, t 0) is built exactly once and then held. Paused
        // is static — the cover held under its box — unless the cover is
        // still on its way, when the field keeps shimmering beneath it.
        let fps: Double = live ? 30 : 0
        // The epsilon: a clock that advances in exact 1/30 s steps (the
        // snapshot harness) lands a hair under a tick boundary every few
        // frames, which repeats one build and then skips one — a stutter
        // that read as tearing in the clips. Real frame times are never on
        // the grid, but the nudge costs nothing there either.
        let tick = fps > 0 ? Int(now * fps + 1e-6) : 0
        let atQ = fps > 0 ? Double(tick) / fps : now
        let t = fps > 0 ? atQ - npTrackSince : 0            // the panel's own clock
        let el = revealAt.map { t - $0 } ?? 0               // since the wave began (negative: waiting)
        let pauseP = pauseChangedAt.map { min(1, (atQ - $0) / Self.artPauseWave) } ?? 1
        let fxKey = "\(key)|\(cols)x\(rows)|\(grid != nil)|\(loading)|\(revealing)|\(paused)|\(cardOn)|\(tick)"
        if let c = artFXCache, c.key == fxKey { return c.rows }

        // The cover's cells, parsed once per build.
        var art: [[(Character, SIMD3<Float>)]] = []
        if let grid {
            art = grid.chars.enumerated().map { j, line in
                let cs = j < grid.colors.count ? grid.colors[j] : []
                return Array(line).enumerated().map { i, ch in
                    (ch, i < cs.count ? Self.artRGB(cs[i]) : .zero)
                }
            }
        }

        // Where the write position is, in rows, on a continuous scale.
        // Rolling (loading, or the cover in hand and waiting for the wrap):
        // one lap every artRoll seconds. The wave: from the top, one lap at
        // the same speed, leaving the cover behind it — it begins at a wrap,
        // so it IS the roll's next lap and nothing jumps. Paused, there is
        // no beam: the field lies still under the box.
        var head: Double?
        var start: Double?
        if paused, pauseP >= 1 {
            head = nil
        } else if revealing, el >= 0 {
            start = 0
            head = Double(rows) * (el / paint)
        } else if loading || revealing {
            head = Double(rows) * (t / Self.artRoll)
        }
        // What is left of the reveal's overexposure. Most of it is gone
        // already — a row cools as it ages, and the lap takes a full box
        // height — this walks the last-written rows the rest of the way
        // into the plain cover.
        let fade = Float(max(0, min(1, 1 - (el - paint) / settle)))

        // Per ROW: how long ago the beam wrote it, and the light that
        // follows. The whole box is one gradient — no band, no background —
        // and the only place it turns is the write position. Colour and
        // halo come from here and from nowhere else, so a row is one run.
        var rowAge = [Double](repeating: 0, count: rows)
        var rowPainted = [Bool](repeating: false, count: rows)
        var rowOver = [Float](repeating: 0, count: rows)
        var rowLight: [ArtRowLight] = []
        rowLight.reserveCapacity(rows)
        for j in 0..<rows {
            var hot = Self.artRestHot
            if let head {
                let y = Double(j) + 0.5
                var age: Double
                if let start {
                    // The reveal's lap: the first crossing at or after the
                    // beam was handed over, so every row is written exactly
                    // once and none is written twice.
                    let cross = y + Double(rows) * ceil((start - y) / Double(rows))
                    let u = head - cross
                    if u >= 0 { age = u / Double(rows); rowPainted[j] = true }
                    else       { age = 1 + u / Double(rows) }
                } else {
                    age = (head - y) / Double(rows)
                    age -= floor(age)
                }
                rowAge[j] = age
                hot = artPhosphor(age, rows: rows, wrapped: !rowPainted[j])
            }
            rowOver[j] = Float(hot) * fade
            // Levels: the reveal at full — the cover arriving is the event —
            // loading breathing between 60% and 90% at the write position
            // (each row keeps the level it was written at), and a coverless
            // rest quieter still.
            let level: Float
            if revealing, rowPainted[j] {
                level = 1
            } else if loading || revealing {
                let written = t - rowAge[j] * Self.artRoll
                let breath = Float(0.5 + 0.5 * sin(2 * .pi * written / Self.artBreath))
                level = Self.artBreathLo + (Self.artBreathHi - Self.artBreathLo) * breath
            } else {
                level = 0.58
            }
            rowLight.append(artRowLight(hot, dim: level))
        }

        // Paused, the way a terminal would say it: the cover steps back —
        // part-desaturated, dimmed — and a small rounded box sits over its
        // centre, cut out of the picture, with the word at full brightness:
        //   ╭──────────╮
        //   │ ■ PAUSED │      (the panel's own corners, at the label grey; a
        //   ╰──────────╯       dim ■ — SF Mono's, centred on the caps' midline
        //                      — then the bright word)
        // Character cells only: nothing is drawn but glyphs, nothing blinks.
        let word = Array(cols >= 16 ? " \u{25A0} PAUSED " : " PAUSED ")
        let card = artCardRect(cols: cols, rows: rows)
        let boxW = card.w, boxC0 = card.x, boxR0 = card.y
        let rule = [Character](repeating: "\u{2500}", count: boxW - 2)
        let boxRows: [[Character]] = [["\u{256D}"] + rule + ["\u{256E}"],
                                      ["\u{2502}"] + word + ["\u{2502}"],
                                      ["\u{2570}"] + rule + ["\u{256F}"]]
        let frame: SIMD3<Float> = [0.31, 0.34, 0.38]                 // the panel's label grey
        let mark: SIMD3<Float> = [0.42, 0.46, 0.52]

        let sweeping = head != nil
        let out = artComposeRows(cols: cols, rows: rows, base: base) { i, j in
            var ch: Character = " "
            var c = SIMD3<Float>.zero
            var glow: Float = 0
            let lit = rowLight[j]
            let hasArt = j < art.count && i < art[j].count
            if hasArt, !revealing || !sweeping {
                (ch, c) = art[j][i]
            } else if hasArt, rowPainted[j] {
                // Behind the write position the cover is there — the same
                // gradient, now printing a picture: overexposed where the
                // beam has just been, settling as the row ages. Where the
                // cover is black the field dissolves out of it rather than
                // snapping off.
                let o = rowOver[j]
                let (ac, acolor) = art[j][i]
                if ac == " " {
                    ch = artToneGlyph((lit.tone + artGrain(i, j, t: t)) * Double(o), i, j)
                    c = lit.color
                    glow = lit.glow * o
                } else {
                    ch = ac
                    c = mix3(acolor, Self.artGlowC, 0.88 * o)
                    glow = 0.85 * o
                }
            } else {
                // The field: the row's tone, grained, rounded on this cell's
                // own dither. Every cell carries a glyph, so it reads as a
                // lit surface and not as a scatter.
                ch = artToneGlyph(max(Self.artToneFloor, lit.tone + artGrain(i, j, t: t)), i, j)
                c = lit.color
                glow = lit.glow
            }
            // The paused look — half its saturation, six tenths of its light;
            // still a picture, plainly not the live one — carried by a wave:
            // a rectangular front (the cell's distance to the nearest edge,
            // each axis on its own scale) closing in from the rim when
            // pausing and opening out from the centre when resuming. Weight
            // 1 is the settled paused look.
            var w: Float = paused ? 1 : 0
            var glint: Float = 0
            if pauseP < 1 {
                let dx = min(Double(i) + 0.5, Double(cols) - Double(i) - 0.5) / (Double(cols) / 2)
                let dy = min(Double(j) + 0.5, Double(rows) - Double(j) - 0.5) / (Double(rows) / 2)
                let d = min(dx, dy)                      // 0 at the rim … 1 at the centre
                let front = pauseP * 1.2                 // runs past 1 so the centre finishes
                let along = paused ? d : 1 - d           // where this cell sits on the wave's path
                let k = Float(max(0, min(1, (front - along) / 0.2)))
                w = paused ? k : 1 - k
                // The front shimmers: a glint of the accent riding the edge,
                // sparkling cell to cell, fading as the wave completes.
                glint = Float(max(0, 1 - abs(front - along) / 0.12))
                    * Float(0.7 + 0.3 * artHash(i, j)) * Float(pow(1 - pauseP, 0.3))
            }
            if w > 0 {
                let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                c = mix3(c, mix3(c, [y, y, y], 0.55) * 0.6, w)
                glow *= 1 - w
            }
            if glint > 0 {
                c = mix3(c, Self.artBeamC, 0.6 * glint)
                glow = max(glow, 0.9 * glint)
            }
            // The card: when it is on is the caller's call (its arrival and
            // departure are choreographed against the flash drawn over it).
            if cardOn {
                if j >= boxR0, j < boxR0 + 3, i >= boxC0, i < boxC0 + boxW {
                    ch = boxRows[j - boxR0][i - boxC0]
                    switch ch {
                    case "\u{25A0}":              c = mark                             // the dim square
                    case " ":                      c = .zero
                    case "P", "A", "U", "S", "E", "D": c = Self.artGlowC                 // full brightness
                    default:                       c = frame                            // the box itself
                    }
                }
            }
            return (ch, c, glow)
        }
        artFXCache = (fxKey, out)
        return out
    }

    /// Terminal-style marquee: rest at the head, then one continuous lap —
    /// the text walks out on the left and, after a gap of blank cells, comes
    /// back in on the right — then rest again. Featured-artist credits
    /// routinely run past any sane panel width, and clipping them drops the
    /// collaborators entirely. The earlier walk-to-the-end-and-snap-back read
    /// as a stutter; Michel tuned this in build/marquee-tuner (2026-09-07).
    /// The clock is the track's own, so a new track starts at rest instead of
    /// somewhere mid-lap.
    private func marqueeText(_ text: String, width: Int) -> String {
        let chars = Array(text)
        let cells = chars.map { widgetGlyph($0).cells }
        let total = cells.reduce(0, +)
        guard width > 0, total > width else { return text }
        let glyph = 0.13            // seconds per glyph
        let hold = 4.0              // rest at the head before each lap
        let gap = 7                 // blank cells between the tail and the head again
        // The ring is the text followed by the gap; a lap walks every glyph
        // of it once — a wide glyph is one step like any other.
        let ring = chars + Array(repeating: Character(" "), count: gap)
        let ringCells = cells + Array(repeating: 1, count: gap)
        let cycle = hold + Double(ring.count) * glyph
        let t = (now - npTrackSince).truncatingRemainder(dividingBy: cycle)
        let off = t < hold ? 0 : min(ring.count - 1, Int((t - hold) / glyph))
        var used = 0, out = ""
        for k in 0..<ring.count {
            let i = (off + k) % ring.count
            if used + ringCells[i] > width { break }
            used += ringCells[i]; out.append(ring[i])
        }
        return out
    }

    /// "~/Desktop/codesaver" from an absolute cwd.
    private func widgetTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "~/Desktop/codesaver" → ("~/Desktop/", "codesaver"): the top rail
    /// paints the two at different weights. A bare "~" or "/" — or a path
    /// truncated inside its last component — is all tail.
    private func widgetSplitLastDir(_ path: String) -> (String, String) {
        guard path.count > 1, let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    // MARK: Cell widths — CJK and other wide glyphs on the panel grid

    /// Per-glyph (cells, kern) at the current font size. SF Mono's own glyphs
    /// are one cell and need no kern; anything it falls back for — CJK,
    /// fullwidth forms, emoji, even ♪ — is measured once and rounded to whole
    /// cells, with the kern that makes its advance exactly that many cells.
    /// Counting `String.count` put a Chinese title's right rail wherever the
    /// fallback glyphs happened to end; the panel is a grid, and every glyph
    /// has to sit on it.
    private var widgetGlyphCache: [Character: (cells: Int, kern: CGFloat)] = [:]
    private var widgetGlyphCachePt: CGFloat = 0

    private func widgetGlyph(_ ch: Character) -> (cells: Int, kern: CGFloat) {
        if ch.isASCII { return (1, 0) }
        if widgetGlyphCachePt != font!.pointSize {
            widgetGlyphCache = [:]
            widgetGlyphCachePt = font!.pointSize
        }
        if let g = widgetGlyphCache[ch] { return g }
        let w = NSAttributedString(string: String(ch), attributes: [.font: font!]).size().width
        // Ceil, never round: a Hangul syllable falls back at 1.40 cells, and
        // rounding handed it ONE — a negative kern that squeezed every
        // syllable over its neighbour. Same rule as the main grid's
        // cellWidth: a glyph gets at least the cells its advance covers,
        // capped at two (an emoji at 2.1 cells takes a terminal's two).
        let n = min(2, max(1, Int(ceil(w / charW - 0.05))))
        var kern = CGFloat(n) * charW - w
        if abs(kern) < 0.05 { kern = 0 }
        let g = (cells: n, kern: kern)
        widgetGlyphCache[ch] = g
        return g
    }

    /// Cells a string takes on the panel grid.
    private func widgetCells(_ s: String) -> Int { s.reduce(0) { $0 + widgetGlyph($1).cells } }

    /// The longest prefix / suffix of `s` that fits in `cells` cells.
    private func widgetPrefix(_ s: String, cells: Int) -> String {
        var used = 0, out = ""
        for ch in s {
            let n = widgetGlyph(ch).cells
            if used + n > cells { break }
            used += n; out.append(ch)
        }
        return out
    }
    private func widgetSuffix(_ s: String, cells: Int) -> String {
        var used = 0, out: [Character] = []
        for ch in s.reversed() {
            let n = widgetGlyph(ch).cells
            if used + n > cells { break }
            used += n; out.append(ch)
        }
        return String(out.reversed())
    }

    /// `text` as attributed text with every glyph snapped to its cells: a
    /// wide fallback glyph is kerned out to exactly n × charW, so the rail
    /// after it lands where the fill arithmetic says it will.
    private func widgetRun(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        if text.allSatisfy({ $0.isASCII }) { return NSAttributedString(string: text, attributes: attrs) }
        let out = NSMutableAttributedString()
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain, attributes: attrs))
            plain = ""
        }
        for ch in text {
            let g = widgetGlyph(ch)
            if g.kern == 0 { plain.append(ch); continue }
            flush()
            var a = attrs
            a[.kern] = g.kern
            out.append(NSAttributedString(string: String(ch), attributes: a))
        }
        flush()
        return out
    }

    private func widgetStateLabel(_ w: WidgetSession) -> String {
        switch w.state {
        case "thinking":     return "Thinking"
        case "responding":   return "Responding"
        case "toolcall":     return "\(w.tool ?? "?"): emit"
        case "waiting_tool": return "\(w.tool ?? "?"): exec"
        case "permission":   return "Permissions required"
        default:             return w.pin != nil ? "Pinned" : "Done"
        }
    }

    /// "next ping in 35m", or the pin daemon's reason there isn't one.
    private func widgetPinNext(_ pin: WidgetPin, wall: Double) -> String {
        guard pin.fresh else { return "pin daemon silent" }
        switch pin.status {
        case "waiting":
            guard let n = pin.nextPingAt else { return "pinned" }
            return n > wall ? "next ping in " + spanString(n - wall) : "ping due"
        case "sent":     return "pinging\u{2026}"
        case "busy":     return "next ping after this turn"
        case "cold":     return "cache cold"
        case "held":     return "ping held"
        case "stalled":  return "pings stalled"
        case "error":    return "ping failed"
        case "gone":     return "session gone"
        case "no_spool", "not_claude", "no_registry": return "not pingable"
        default:         return "pinned"
        }
    }

    /// "2 agents, 1 monitor still running" from Stop's background_tasks.
    private func widgetBGLabel(_ bg: [String: Int]) -> String? {
        guard !bg.isEmpty else { return nil }
        let names: [(key: String, one: String, many: String)] = [
            ("subagent", "agent", "agents"), ("monitor", "monitor", "monitors"),
            ("shell", "shell", "shells"), ("workflow", "workflow", "workflows"),
            ("teammate", "teammate", "teammates"),
            ("cloud session", "cloud session", "cloud sessions"),
            ("MCP task", "MCP task", "MCP tasks"),
        ]
        var parts: [String] = []
        for n in names {
            if let c = bg[n.key], c > 0 { parts.append("\(c) \(c == 1 ? n.one : n.many)") }
        }
        for (k, c) in bg.sorted(by: { $0.key < $1.key })
        where !names.contains(where: { $0.key == k }) && c > 0 {
            parts.append("\(c) \(k)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + " still running"
    }

    /// The "(4m 12s ∙ 8.2k tokens ∙ …)" tail; nil during the latency window.
    private func widgetParen(_ w: WidgetSession, wall: Double) -> String? {
        var parts: [String] = []
        if w.state != "done" {
            // Active: time in THIS state, then the turn's totals.
            if let ss = w.stateSince, wall > ss { parts.append(timeString(wall - ss)) }
            if let tok = w.turnTokens, tok > 0 { parts.append("\(countString(Double(tok))) tokens") }
            if let t0 = w.turnStarted, wall > t0 + 1 {
                parts.append("elapsed " + timeString(wall - t0))
            }
            guard !parts.isEmpty else { return nil }
            return "(" + parts.joined(separator: " \u{2219} ") + ")"
        }
        if let pin = w.pin {
            // Pinned and resting: what the pin daemon does next, then how
            // long the pin has been held. The tokens/background tail gives
            // way — the pin is the story of a resting pinned panel.
            parts.append(widgetPinNext(pin, wall: wall))
            if pin.pinnedAt > 0, wall > pin.pinnedAt {
                parts.append(spanString(wall - pin.pinnedAt) + " ago")
            }
            return "(" + parts.joined(separator: " \u{2219} ") + ")"
        }
        if let tok = w.turnTokens, tok > 0 { parts.append("\(countString(Double(tok))) tokens") }
        if let bgl = widgetBGLabel(w.bg) { parts.append(bgl) }
        if let la = w.lastActive, wall - la > 5 {
            let ago = wall - la
            let label = ago < 60 ? "\(Int(ago))s"
                : ago < 5400 ? "\(Int((ago / 60).rounded()))m"
                : "\(Int((ago / 3600).rounded()))h"
            parts.append("\(label) ago")
        }
        guard !parts.isEmpty else { return nil }
        return "(" + parts.joined(separator: " \u{2219} ") + ")"
    }

    private struct WidgetRow { var runs: [(String, [NSAttributedString.Key: Any])] }

    /// Rasterizes one rounded TUI panel and appends its quad. `rows` are
    /// full-width strings of exactly `cols` characters (rails included).
    private func emitWidgetPanel(_ frame: inout BoomMetalRenderer.FrameInput,
                                 metal: BoomMetalRenderer, scale: CGFloat,
                                 key: String, rows: [WidgetRow],
                                 bottomLeft origin: NSPoint, mask: Bool,
                                 art: (rows: [NSAttributedString], step: CGFloat,
                                       cols: Int, afterRow: Int,
                                       card: (x: Int, y: Int, w: Int, h: Int,
                                              flash: CGFloat, blip: Bool)?)? = nil) {
        let step = lineH
        var width: CGFloat = 0
        let built: [NSAttributedString] = rows.map { row in
            let line = NSMutableAttributedString()
            for (text, attrs) in row.runs {
                line.append(widgetRun(text, attrs))
            }
            width = max(width, line.size().width)
            return line
        }
        let pad: CGFloat = 6
        let size = NSSize(width: width + pad * 2,
                          height: step * CGFloat(built.count) + pad * 2)
        guard let img = rasterUI(size: size, scale: scale, {
            NSColor.black.withAlphaComponent(0.87).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                         xRadius: 3, yRadius: 3).fill()
            var y = pad
            for (i, line) in built.enumerated() {
                line.draw(at: NSPoint(x: pad, y: y))
                y += step
                if let art, art.afterRow == i {
                    // Straight into this context, starting on a CELL BOUNDARY
                    // of the panel's own grid — the art shares the chrome's
                    // font, so its columns coincide with the rails and the
                    // text below. Pixel-centering here is what kept knocking
                    // the art off the grid.
                    let totalCells = Int((width / charW).rounded())
                    let lead = CGFloat(max(1, (totalCells - art.cols) / 2))
                    let ox = pad + lead * charW
                    AlbumArtGrid.draw(rows: art.rows, at: NSPoint(x: ox, y: y), step: art.step)
                    if let card = art.card, card.flash > 0 || card.blip {
                        // The spinner's own flash and blip, over the card's
                        // cells, in screen space (the panel's top-left plus
                        // this raster's offsets), drawn late — over the quad.
                        let px = origin.x + ox + CGFloat(card.x) * charW
                        let py = origin.y - size.height + y + CGFloat(card.y) * art.step
                        let rect = NSRect(x: px, y: py, width: CGFloat(card.w) * charW,
                                          height: CGFloat(card.h) * art.step)
                        if card.flash > 0 {
                            appendTeleportFlash(&frame.lateFills, rect: rect.insetBy(dx: -2, dy: -1),
                                                alpha: card.flash, scale: scale)
                        }
                        if card.blip {
                            appendBlip(&frame.lateFills,
                                       cell: NSRect(x: px + CGFloat(card.w / 2) * charW,
                                                    y: py + art.step, width: charW, height: art.step),
                                       scale: scale)
                        }
                    }
                }
            }
        }) else { return }
        metal.setUITexture(key, image: img, always: true)
        frame.quads.append(.init(key: key, rect: CGRect(
            x: origin.x, y: origin.y - size.height,
            width: size.width, height: size.height),
            maskToWipedCells: mask))
    }

    private func buildWidgetQuads(_ frame: inout BoomMetalRenderer.FrameInput,
                                  metal: BoomMetalRenderer, scale: CGFloat) {
        pollWidgetFeed()
        guard font != nil else { return }
        let mask = intro == .boom
        let wall = Date().timeIntervalSince1970
        guard wall - widgetFeed.updated < 20 else { return }   // daemon stale → nothing

        let base = font!
        let bold = NSFont(name: "SFMono-Semibold", size: base.pointSize)
            ?? .monospacedSystemFont(ofSize: base.pointSize, weight: .semibold)
        let railC = NSColor(white: 0.30, alpha: 1)
        let railDimC = NSColor(white: 0.20, alpha: 1)
        let labelC = NSColor(deviceRed: 0.31, green: 0.35, blue: 0.39, alpha: 1)
        let tokenC = NSColor(deviceRed: 0.43, green: 0.48, blue: 0.53, alpha: 1)
        let doneC = NSColor(white: 0.44, alpha: 1)
        func run(_ c: NSColor, _ f0: NSFont? = nil) -> [NSAttributedString.Key: Any] {
            [.font: f0 ?? base, .foregroundColor: c]
        }
        func glowRun(_ c: NSColor, halo: NSColor, blur: CGFloat) -> [NSAttributedString.Key: Any] {
            let sh = NSShadow()
            sh.shadowColor = halo
            sh.shadowBlurRadius = blur
            sh.shadowOffset = .zero
            return [.font: bold, .foregroundColor: c, .shadow: sh]
        }

        // Activity floats up, resting sinks: active panels (newest turn first)
        // above, done panels below. Sorted BEFORE the rack is capped, so the
        // cap keeps the sessions that are working (the feed arrives in
        // turn-start order, which would have kept four resting panels over
        // a long-running tool call or a parked permission prompt).
        let sessions = Array(widgetFeed.sessions.sorted { l, r in
            let la = l.state != "done", ra = r.state != "done"
            if la != ra { return la }
            let lp = l.pin != nil, rp = r.pin != nil      // pinned rests above resting
            if lp != rp { return lp }
            return (l.turnStarted ?? 0) > (r.turnStarted ?? 0)
        }.prefix(4))

        // Uniform rack width from the widest content, clamped.
        var contents: [(w: WidgetSession, label: String, paren: String?,
                        cwd: String, bottom: String)] = []
        var innerMax = 40
        for w in sessions {
            let label = widgetStateLabel(w)
            let paren = widgetParen(w, wall: wall)
            let cwd = widgetTilde(w.cwd)
            let bottom = w.sessionTokens.map {
                "session \(countString(Double($0))) tokens" } ?? ""
            let contentLen = 2 + 2 + label.count + (paren.map { $0.count + 1 } ?? 0) + 2
            innerMax = max(innerMax, contentLen, widgetCells(cwd) + 6, bottom.count + 6)
        }
        let inner = min(innerMax, 72)
        for w in sessions {
            var label = widgetStateLabel(w)
            var paren = widgetParen(w, wall: wall)
            // Status row spends: "│ " + glyph + " " + label + " (paren)" and
            // must leave the closing " │" on column inner+1, so label and
            // parenthetical together get inner-6 cells. An over-long label
            // loses its tail first, never the parenthetical's numbers — but
            // a parenthetical that can't fit beside even a stub of the label
            // (several background-task kinds at once) loses ITS tail, closing
            // paren kept: a row wider than the rails breaks the box.
            var budget = inner - 5 - (paren.map { $0.count + 1 } ?? 0)
            let labelStub = min(label.count, 6)
            if let p = paren, budget < labelStub {
                let parenMax = inner - 6 - labelStub
                paren = parenMax >= 5 ? String(p.prefix(parenMax - 2)) + "\u{2026})" : nil
                budget = inner - 5 - (paren.map { $0.count + 1 } ?? 0)
            }
            if label.count > budget, budget > 2 {
                label = String(label.prefix(budget - 1)) + "\u{2026}"
            }
            contents.append((w, label, paren, widgetTilde(w.cwd),
                             w.sessionTokens.map {
                                 "session \(countString(Double($0))) tokens" } ?? ""))
        }

        // The hero spinner panel owns its space: any session panel that
        // would climb into it is simply not shown. Count what fits first and
        // keep the HEAD of the sorted rack — stacking bottom-up in reverse
        // lands the first entry topmost, nearest the hero, and a break inside
        // that loop would have dropped exactly the active panels the sort
        // just promoted.
        let heroSize = spinnerAttributedString().size()
        let heroBottom = spinnerTextOrigin(for: heroSize).y + heroSize.height
            + uiFont.pointSize * 1.05 + lineH * 0.75
        let panelH = lineH * 3 + 12
        let pitch = lineH * 3 + 14 + lineH * 0.5
        let margin = lineH * 1.2
        var y = bounds.height - margin          // stack grows upward
        let fitCount = contents.indices.prefix {
            y - CGFloat($0) * pitch - panelH >= heroBottom
        }.count
        for (i, c) in contents.prefix(fitCount).enumerated().reversed() {
            let active = c.w.state != "done"
            let rC = active ? railC : railDimC
            // Frames 1...5 only: at panel scale the hero's "·" rest frame
            // reads as a dropout, not a beat.
            let glyphFrame = active
                ? Self.spinnerFrames[1 + Int(((1 - cos(2 * Double.pi * (now + Double(i) * 0.37) / 2.4)) / 2 * 4).rounded())]
                : "\u{273B}"

            // Top rail: ╭─ cwd ────╮ (truncate cwd from the left if huge)
            var cwd = c.cwd
            if widgetCells(cwd) > inner - 6 { cwd = "\u{2026}" + widgetSuffix(cwd, cells: inner - 7) }
            let topFill = max(0, inner - widgetCells(cwd) - 4)
            // The parents rest at the label weight; the final directory — the
            // name a project is actually recognised by — is the bright one.
            let (cwdHead, cwdTail) = widgetSplitLastDir(cwd)
            let top = WidgetRow(runs: [
                ("\u{256D}\u{2500} ", run(rC)),
                (cwdHead, run(labelC)),
                (cwdTail, run(tokenC)),
                (" " + String(repeating: "\u{2500}", count: topFill) + "\u{256E}", run(rC)),
            ])

            // Status row: │ ✻ Label (…) padded │
            var runs: [(String, [NSAttributedString.Key: Any])] = []
            runs.append(("\u{2502} ", run(rC)))
            var used = 2
            if active {
                runs.append((glyphFrame, glowRun(ccOrange.blended(withFraction: 0.25, of: ccOrangeHot) ?? ccOrange,
                    halo: ccOrangeHot.withAlphaComponent(0.85),
                    blur: base.pointSize * 0.55)))
                runs.append((" ", run(rC)))
                // The hero statusline's per-character glow ripple, in Claude
                // clay: orange base sweeping toward warm white, desynced per
                // panel so the rack never pulses in lockstep.
                let chars = Array(c.label)
                let period = Double(chars.count) + 16
                let pos = ((now + Double(i) * 2.13) * 13)
                    .truncatingRemainder(dividingBy: period) - 5
                for (k, ch) in chars.enumerated() {
                    let d = Double(k) - pos
                    let b = CGFloat(exp(-(d * d) / (2 * 1.9 * 1.9)))
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: bold,
                        .foregroundColor: ccOrange.mixed(with: glowText, 0.9 * b),
                    ]
                    if b > 0.1 {
                        let sh = NSShadow()
                        sh.shadowColor = ccOrangeHot.withAlphaComponent(0.9 * b)
                        sh.shadowBlurRadius = base.pointSize * 0.65 * b
                        sh.shadowOffset = .zero
                        attrs[.shadow] = sh
                    }
                    runs.append((String(ch), attrs))
                }
            } else if c.w.pin != nil {
                // Kept warm: the glyph in quiet clay, the words resting grey.
                runs.append((glyphFrame + " ",
                             run(ccOrange.blended(withFraction: 0.45, of: doneC) ?? doneC)))
                runs.append((c.label, run(doneC)))
            } else {
                runs.append((glyphFrame + " ", run(doneC)))
                runs.append((c.label, run(doneC)))
            }
            used += 2 + c.label.count
            if let paren = c.paren {
                runs.append((" ", run(rC)))
                runs.append((paren, run(active ? NSColor(white: 0.5, alpha: 1) : doneC)))
                used += 1 + paren.count
            }
            let fill = max(0, inner - used - 1)
            runs.append((String(repeating: " ", count: fill) + " \u{2502}", run(rC)))
            let status = WidgetRow(runs: runs)

            // Bottom rail: ╰────── session N tokens ─╯ — the count is the
            // bright word; "session … tokens" sits at the label weight.
            let bl = c.bottom
            let botFill = max(0, inner - bl.count - 4)
            var botRuns: [(String, [NSAttributedString.Key: Any])] = [
                ("\u{2570}" + String(repeating: "\u{2500}", count: botFill) + " ", run(rC)),
            ]
            if let n = c.w.sessionTokens {
                botRuns.append(("session ", run(labelC)))
                botRuns.append((countString(Double(n)), run(tokenC)))
                botRuns.append((" tokens", run(labelC)))
            }
            botRuns.append((" \u{2500}\u{256F}", run(rC)))
            let bottom = WidgetRow(runs: botRuns)

            emitWidgetPanel(&frame, metal: metal, scale: scale,
                            key: "widget-s\(i)", rows: [top, status, bottom],
                            bottomLeft: NSPoint(x: leftInset, y: y), mask: mask)
            y -= pitch
        }

        buildNowPlayingQuad(&frame, metal: metal, scale: scale, wall: wall,
                            mask: mask)
    }

    private func buildNowPlayingQuad(_ frame: inout BoomMetalRenderer.FrameInput,
                                     metal: BoomMetalRenderer, scale: CGFloat,
                                     wall: Double, mask: Bool) {
        guard let app = widgetFeed.npApp, !widgetFeed.npTitle.isEmpty,
              wall - widgetFeed.npTS < 15 else { return }
        // The panel is BUDGETED, never gated. Its ceiling is whichever sits
        // lower: a fixed share of the screen, or the bottom of the hero
        // statusline. The art then scales into whatever remains, so it can
        // never clip the statusline no matter how long the verb runs — the
        // old approach let a long verb make the art vanish entirely.
        let heroSize = spinnerAttributedString().size()
        let heroBottom = spinnerTextOrigin(for: heroSize).y + heroSize.height
            + uiFont.pointSize * 1.05 + lineH * 0.75
        let npMargin = lineH * 1.2
        let ceiling = max(bounds.height - npMaxLines * lineH, heroBottom)
            + lineH * 0.6
        let chromeH = lineH * 5 + 12
        guard bounds.height - npMargin - chromeH >= ceiling else { return }
        let base = font!
        let railC = NSColor(white: 0.26, alpha: 1)
        let labelC = NSColor(deviceRed: 0.31, green: 0.35, blue: 0.39, alpha: 1)
        let titleC = NSColor(deviceRed: 0.58, green: 0.65, blue: 0.72, alpha: 1)
        func run(_ c: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: base, .foregroundColor: c]
        }

        let paused = widgetFeed.npState == "paused"
        // A change of state starts the wave: in from the edges when pausing,
        // out from the centre when resuming. The first sight of a track is
        // never animated — there is nothing to transition from.
        if npPauseKnown == nil {
            npPauseKnown = paused
        } else if npPauseKnown != paused {
            npPauseKnown = paused
            npPauseChangedAt = now
        }
        let title0 = widgetFeed.npTitle, artist0 = widgetFeed.npArtist
        // Without art the panel still needs some width; WITH art, the art box
        // alone decides it — and the box is there from a track's first frame,
        // sized from the saved tuning, so the width never jumps when the
        // cover lands. Track metadata never widens the panel — a long feature
        // credit used to stretch it halfway across the screen.
        var inner = min(60, max(40, max(widgetCells(title0), widgetCells(artist0)) + 6))
        // The track the panel is on. A change restarts the placeholder's
        // clock and forgets the reveal, so the next cover lands with its own.
        let key = "\(app)|\(title0)|\(artist0)"
        if key != npTrackKey {
            npTrackChanged = !npTrackKey.isEmpty
            npTrackKey = key
            npTrackSince = now
            artShownSince = nil
            artFXCache = nil
        }
        var box: (cols: Int, rows: Int)?
        var grid: AlbumArtGrid?
        if artOn {
            let room = bounds.height - npMargin - chromeH - ceiling
            if artKey == key, let g = fittedArtGrid(room: room) {
                grid = g
                box = (g.cols, g.rows)
                if artShownSince == nil { artShownSince = now }
            } else {
                box = artBox(cols: artParams.colCount, rows: artParams.rowCount, room: room)
                artShownSince = nil
            }
            if let box { inner = max(24, box.cols + 3) }
        }
        // Title and artist both scroll when they overrun the field — bounded
        // by the art-derived width instead of being allowed to set it, and a
        // clipped title lost the half that names the song.
        let field = max(4, inner - 3)
        let title = marqueeText(title0, width: field)
        let artist = marqueeText(artist0, width: field)

        func timeMS(_ v: Double) -> String {
            let s = max(0, Int(v)); return "\(s / 60):" + String(format: "%02d", s % 60)
        }
        // Paused: the clock stops where the player stopped it.
        let pos = min(widgetFeed.npDur,
                      paused ? widgetFeed.npPos : widgetFeed.npPos + (wall - widgetFeed.npTS))
        let posS = timeMS(pos), durS = timeMS(widgetFeed.npDur)

        // ♪ now playing — or ♪ paused 12m, the hold counting up so it reads
        // as a held state rather than a live one.
        var head = "\u{266A} now playing"
        if paused {
            head = "\u{266A} paused"
            if let ps = widgetFeed.npPausedSince, wall - ps >= 60 {
                head += " " + spanString(wall - ps)
            }
        }
        let topFill = max(0, inner - widgetCells(head) - 4)
        let top = WidgetRow(runs: [
            ("\u{256D}\u{2500} ", run(railC)), (head, run(labelC)),
            (" " + String(repeating: "\u{2500}", count: topFill) + "\u{256E}", run(railC)),
        ])
        // Row-width invariant: every row is exactly inner+1 cells wide.
        func padRow(_ text: String, _ c: NSColor) -> WidgetRow {
            let fill = max(0, inner - widgetCells(text) - 3)
            return WidgetRow(runs: [
                ("\u{2502} ", run(railC)), (text, run(c)),
                (String(repeating: " ", count: fill) + " \u{2502}", run(railC)),
            ])
        }
        let titleRow = padRow(title, titleC)
        let artistRow = padRow(artist, NSColor(white: 0.40, alpha: 1))

        // 2:41 ───────●─────── 4:11
        let barW = max(6, inner - posS.count - durS.count - 5)
        let frac = widgetFeed.npDur > 0 ? pos / widgetFeed.npDur : 0
        let mark = min(barW - 1, max(0, Int(Double(barW) * frac)))
        var progRuns: [(String, [NSAttributedString.Key: Any])] = []
        progRuns.append(("\u{2502} ", run(railC)))
        progRuns.append((posS + " ", run(NSColor(white: 0.40, alpha: 1))))
        progRuns.append((String(repeating: "\u{2500}", count: mark), run(NSColor(white: 0.30, alpha: 1))))
        progRuns.append(("\u{25CF}", run(paused ? NSColor(white: 0.45, alpha: 1) : cursorColor)))
        progRuns.append((String(repeating: "\u{2500}", count: barW - mark - 1), run(NSColor(white: 0.22, alpha: 1))))
        progRuns.append((" " + durS, run(NSColor(white: 0.40, alpha: 1))))
        progRuns.append((" \u{2502}", run(railC)))
        let progRow = WidgetRow(runs: progRuns)

        let bl = app + ".app"
        let botFill = max(0, inner - widgetCells(bl) - 4)
        let bottom = WidgetRow(runs: [
            ("\u{2570}" + String(repeating: "\u{2500}", count: botFill) + " ", run(railC)),
            (bl, run(labelC)), (" \u{2500}\u{256F}", run(railC)),
        ])

        var rows = [top]
        var artPayload: (rows: [NSAttributedString], step: CGFloat,
                         cols: Int, afterRow: Int,
                         card: (x: Int, y: Int, w: Int, h: Int, flash: CGFloat, blip: Bool)?)?
        if let box {
            // Blank rows (│ + spaces + │) reserve the box's height AND supply
            // its side rails; whatever the box shows is drawn over them at
            // NATIVE cell size.
            let stepA = AlbumArtGrid.rowStep(charW: charW)
            let h = stepA * CGFloat(box.rows) + 4
            let n = max(1, Int((h / lineH).rounded(.up)))
            for _ in 0..<n { rows.append(padRow("", titleC)) }
            // The card's choreography against the wave: it arrives once the
            // wave has closed on the centre — blip, a beat, then the card
            // under an arrival flash — and leaves the moment the wave starts
            // to open: a departure flash, then a blip. First sight of a
            // paused track: the card is simply there.
            var cardOn = paused, flash: CGFloat = 0, blip = false
            if let t0 = npPauseChangedAt {
                if paused {
                    let tz = now - (t0 + 0.92 * Self.artPauseWave)
                    cardOn = tz >= Self.artCardGapIn
                    blip = tz >= 0 && tz < Self.artCardBlipIn
                    if tz >= Self.artCardGapIn, tz < Self.artCardFlashIn {
                        flash = (Self.artCardFlashIn - tz) / (Self.artCardFlashIn - Self.artCardGapIn) * 0.55
                    }
                } else {
                    let tz = now - (t0 + 0.08 * Self.artPauseWave)
                    cardOn = tz < 0
                    if tz >= 0, tz < Self.artCardFlashOut {
                        let a = 1 - tz / Self.artCardFlashOut
                        flash = 0.85 * a * a
                        blip = tz >= Self.artCardBlipOut
                    }
                }
            }
            let cr = artCardRect(cols: box.cols, rows: box.rows)
            artPayload = (artBoxRows(box: box, grid: grid, key: key, paused: paused,
                                     pauseChangedAt: npPauseChangedAt, cardOn: cardOn, base: base),
                          stepA, box.cols, 0,
                          flash > 0 || blip ? (cr.x, cr.y, cr.w, cr.h, flash, blip) : nil)
        }
        rows += [titleRow, artistRow, progRow, bottom]
        let width = CGFloat(inner + 2) * charW * 1.0
        let margin = lineH * 1.2
        emitWidgetPanel(&frame, metal: metal, scale: scale, key: "widget-np",
                        rows: rows,
                        bottomLeft: NSPoint(
                            x: bounds.width - leftInset - width - 12,
                            y: bounds.height - margin), mask: mask,
                        art: artPayload)
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
            // an extra tick just advances by dt ≈ 0. Not under the harness:
            // there, frame N of the timeline must be exactly N driven steps.
            if !externallyDriven { tick() }
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
        guard !externallyDriven, watchdog == nil else { return }
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
        guard !externallyDriven else { return }
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
        Self.liveViews -= 1
        if Self.liveViews <= 0 {
            Self.liveViews = 0
            BoomSession.release()
        }
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
        // ↑ prefill — data streaming to the model — surges the typing, scaled
        // by how hard the counter is climbing. Tool runs slow to a visible
        // 0.5× — not the full crawl, which is reserved for the spinner's rest
        // and a new turn waiting on the API.
        let streaming = phase == .working && now - phaseStart >= parenDelay
        let targetMul: Double = !streaming ? 0.22
            : step == .toolWait ? 0.5
            : arrowIsDown ? 1.0 : prefillSurge
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
            block = blockLines(at: Int.random(in: 0..<blockRefs.count, using: &saverRNG))
        } else {
            block = fallbackBlocks.randomElement(using: &saverRNG) ?? []
        }
        guard !block.isEmpty else { return [] }
        var slice: [String]
        let want = Int(rand(8, 24))
        if block.count > want {
            let start = Int.random(in: 0...(block.count - want), using: &saverRNG)
            slice = Array(block[start..<(start + want)])
        } else {
            slice = block
        }
        slice = slice.map(Self.expandTabs)
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

    /// Tabs → spaces on the terminal's own 4-column stops. A tab has no cell
    /// width (it paints nothing) so left in place it would silently swallow a
    /// line's indentation. The corpus CodeSaver.app fetches is already
    /// expanded; this covers the legacy corpus.txt path, the built-in
    /// fallback, and any corpus handed in through CODESAVER_RESOURCES.
    private static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        out.reserveCapacity(line.count + 8)
        var col = 0
        for ch in line {
            if ch == "\t" {
                let pad = 4 - (col % 4)
                out += String(repeating: " ", count: pad)
                col += pad
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }

    // MARK: Cell widths
    // The layout is a character-cell model, but CJK/emoji glyphs paint wider
    // than one cell. Widths are MEASURED per character (so the model matches
    // whatever font fallback actually draws) and quantized to the terminal's
    // own vocabulary: 0 (zero-width), 1 (narrow) or 2 (East Asian wide). The
    // glyph atlas then FITS the character into exactly that many cells, so
    // what is counted and what is painted can never disagree.
    //
    // The 2-cell ceiling matters. SF Mono has no CJK, so PingFang answers at
    // ~1.62 cells and Apple Color Emoji at ~2.11; a bare ceil() made every
    // emoji claim THREE cells — a blank column after each one, and the glyph
    // adrift in an over-wide atlas slot. Two is what a terminal gives them.
    //
    // Measured once per Character and cached (the cache is dropped when the
    // font changes), so the Metal path stays free of per-frame CoreText.
    private var cellWidthCache: [Character: Int] = [:]

    private func cellWidth(_ ch: Character) -> Int {
        // Fast path: printable ASCII is always exactly one cell. Control
        // characters are NOT — a tab measures three-and-a-bit cells but
        // paints nothing — so they take no column here; corpus decode
        // expands tabs to spaces before layout ever sees one.
        if let a = ch.asciiValue { return (a >= 0x20 && a != 0x7F) ? 1 : 0 }
        if let cached = cellWidthCache[ch] { return cached }
        let advance = (String(ch) as NSString).size(withAttributes: [.font: font!]).width
        // Zero-advance characters (ZWSP, BOM, a lone joiner or variation
        // selector) take no column either: claiming one would open a phantom
        // gap and shift the whole rest of the line off the grid.
        let w = advance < 0.05 ? 0 : min(2, max(1, Int(ceil(advance / charW - 0.05))))
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
        w.band = Int.random(in: 0..<bandCount, using: &saverRNG)
        // Gaussian placement around the band anchor: most chunks sit near it,
        // but the tails push writers well outside their "column" so the layout
        // never reads as a grid.
        let anchor = Double(w.band * bandWidth) + Double(bandWidth) * 0.08
        let spread = max(8.0, Double(bandWidth) * 0.2)
        w.col = max(0, min(cols - 36, Int(gaussRand(mean: anchor, sigma: spread))))
        var attempt = 0
        repeat {
            w.row = Int.random(in: 0..<rowCount, using: &saverRNG)
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
        // Exponential tail (median ~100s) mixed with a rare marathon arm —
        // an exponential alone would essentially never produce a 20-minute
        // turn, so the long tail has to be its own distribution.
        workDuration = ProcessInfo.processInfo.environment["CODESAVER_WORKDUR"].flatMap(Double.init)
            ?? (Double.random(in: 0...1, using: &saverRNG) < 0.05
                ? rand(360, 1500)
                : expTail(base: 50, mean: 70, cap: 600))
        doneDuration = rand(7, 14)
        if freshVerb, !verbs.isEmpty {
            var next = Int.random(in: 0..<verbs.count, using: &saverRNG)
            if verbs.count > 1 && next == verbIndex { next = (next + 1) % verbs.count }
            verbIndex = next
        }
        tokens = 0
        segEndsAt = -1
        arrowIsDown = true
        nextStatusRoll = now + rand(3, 7)
        statusShowing = false
        parenDelay = rand(1.2, 4.0)
    }

    private func updateSpinner(dt: Double) {
        switch phase {
        case .working:
            // The counter holds at zero until the first request streams up.
            // From there a turn is `while t < workDuration { prefill();
            // decode(); toolWait() }`. The deadline is only checked when a
            // decode completes, so a turn always ends on a finished reply —
            // never mid-upload, never mid-tool.
            if now - phaseStart >= parenDelay {
                if segEndsAt < 0 { beginRequest() }
                switch step {
                case .prefill:
                    // Straight lerp between the endpoints. Real prefill runs
                    // ~30k tok/s — negligible — so the ~3s window is network
                    // and scheduling overhead, and the real spinner smooths
                    // the climb into a ramp anyway.
                    let frac = clampd((now - segStart) / (segEndsAt - segStart), 0, 1)
                    tokens = prefillBase + prefillCount * frac
                case .decode:
                    // Ornstein-Uhlenbeck wobble: relax toward 1, kick with
                    // frame-rate-independent noise. Instantaneous rate = step
                    // mean × smoothstep ramps at both tail ends × this wobble.
                    rateJitter += (1 - rateJitter) * min(1, dt / 1.2)
                    rateJitter = clampd(rateJitter + gaussRand(mean: 0, sigma: 0.28 * dt.squareRoot()), 0.55, 1.6)
                    let edge = min(1.2, (segEndsAt - segStart) * 0.35)
                    let ease = smooth01((now - segStart) / edge) * smooth01((segEndsAt - now) / edge)
                    tokens += segRate * ease * rateJitter * dt
                case .toolWait:
                    break // tool running: number frozen, arrow ↑
                }
                if now >= segEndsAt {
                    switch step {
                    case .prefill:
                        beginStep(.decode)
                    case .decode:
                        if now - phaseStart >= workDuration {
                            frozenDoneText = "\u{273B} \(verbs[verbIndex].past) for \(timeString(now - phaseStart))"
                            phase = .done
                            phaseStart = now
                            // Turn finished: most of the corpus subset
                            // refreshes — the next task arrives with mostly
                            // new context, a little carryover.
                            rotateSubset(fraction: 0.7)
                            return
                        }
                        beginStep(.toolWait)
                    case .toolWait:
                        beginRequest()
                    }
                }
            }
            if statusShowing {
                // The stint's end was decided when it started; the step guards
                // only matter if the cycle was reset out from under it.
                if step != .decode || segEndsAt < 0 || now >= statusShowUntil {
                    statusShowing = false
                    nextStatusRoll = now + rand(3, 7)
                }
            } else if step == .decode, segEndsAt > 0, now >= nextStatusRoll {
                // Roll the stint's whole think time up front, capped to end
                // at least a second before the decode does — a reply never
                // lands on "still coding".
                let room = segEndsAt - now - 1
                if room >= 2 {
                    statusEnteredAt = now
                    statusShowUntil = now + min(expTail(base: 6, mean: 9, cap: 90), room)
                    statusShowing = true
                } else {
                    nextStatusRoll = now + rand(3, 7)
                }
            }
        case .done:
            if now - phaseStart >= doneDuration {
                startCycle(freshVerb: true)
            }
        }
    }

    /// Opens a new API request: the server-jitter walk advances once per
    /// request, then the request starts with its prefill.
    private func beginRequest() {
        decodeRateMean = clampd(decodeRateMean + gaussRand(mean: 0, sigma: 2.5)
            + (72 - decodeRateMean) * 0.06, 45, 110)
        beginStep(.prefill)
    }

    /// Starts the next step of a request. ↑ prefill lerps the tool result's
    /// tokens up over a few seconds of mostly network overhead; ↓ decode
    /// trickles the reply at a rate sampled around the session mean; the
    /// tool-use wait freezes the counter while the "tool" runs.
    private func beginStep(_ next: Step) {
        step = next
        arrowIsDown = next == .decode
        segStart = now
        switch next {
        case .prefill:
            prefillBase = tokens
            // Tool returns are two populations, not one curve: mostly small
            // (bash status, greps, small edits), with every ~fifth a big one
            // (file reads, test suites, page fetches) that gives the surge
            // its real dynamic range.
            prefillCount = Double.random(in: 0...1, using: &saverRNG) < 0.2
                ? rand(2000, 9000)
                : expTail(base: 100, mean: 450, cap: 2000)
            let dur = max(1.0, gaussRand(mean: 3.0, sigma: 1.0))
            segEndsAt = now + dur
            // Bigger uploads slam the screen harder: the typing surge scales
            // with the counter's climb rate, log-mapped 100→5k tok/s onto
            // 1.35×–2×, so even a small prefill visibly surges and a monster
            // tool result properly floors it.
            prefillSurge = 1.35 + 0.65 * smooth01(log(prefillCount / dur / 100) / log(50))
        case .decode:
            segRate = max(15, gaussRand(mean: decodeRateMean, sigma: decodeRateMean * 0.10))
            // Long-tailed dwells give status stints room to climb the ladder —
            // "almost done coding" needs 45s+ of decode still ahead of the
            // stint. The rare extended-thinking arm is what makes multi-minute
            // decodes possible at all — an exponential tail alone never gets
            // there.
            segEndsAt = now + (Double.random(in: 0...1, using: &saverRNG) < 0.08
                ? expTail(base: 30, mean: 150, cap: .infinity)
                : expTail(base: 5, mean: 9, cap: .infinity))
        case .toolWait:
            // Average ~3s, with ~5% stragglers — builds, tests, slow curls.
            segEndsAt = now + (Double.random(in: 0...1, using: &saverRNG) < 0.05
                ? rand(8, 30)
                : max(0.3, gaussRand(mean: 2.5, sigma: 0.8)))
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    /// "45s", "35m", "2h 32m" — the pin line's spans. `timeString` is for
    /// sub-hour turn timers and would read "152m 3s" here.
    private func spanString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    private func countString(_ v: Double) -> String {
        let n = Int(v)
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", v / 1000)
    }

    /// Claude Code's real escalation ladder and thresholds, verb swapped for
    /// the saver's own: thinking → still thinking → thinking more → thinking
    /// some more → almost done thinking, at 10/20/30/45s.
    private func statusText(since: Double) -> String {
        if since < 10 { return "coding with xhigh effort" }
        if since < 20 { return "still coding with xhigh effort" }
        if since < 30 { return "coding more with xhigh effort" }
        if since < 45 { return "coding some more with xhigh effort" }
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
        armedVerb = verbs.randomElement(using: &saverRNG)?.ing ?? "Idling"
        boomSession = nil
        boomCore = nil
        viewOriginCG = .zero
        for i in rows.indices { rows[i] = [] }
    }

    /// Re-runs the boom from the last origin (tuning-panel button).
    public func replayBoom() {
        armIntro(atNormalized: boomOriginNorm, countdown: 1.2)
    }

    // MARK: Preview harness driving
    //
    // The scrubbing previewer (Sources/PreviewMain.swift) owns the clock: it
    // steps the sim one 1/30 s frame at a time, so "timeline position N" is
    // exactly N runs of the same advance() the display link would have made,
    // and a rewind is a reset plus N steps. Nothing below is compiled out of
    // the shipping saver — it simply never sets `externallyDriven`.

    /// Silences the view's own clocks (display link, occlusion fallback,
    /// watchdog) and the click-to-detonate shortcut, so the harness can drive
    /// every frame itself.
    public var externallyDriven = false

    /// Reseeds the scene's random stream (corpus draws, verb picks, writer
    /// placement, dwell times). The snapshot harness pins it before building
    /// a view, so the same timestamps render the same frames run after run;
    /// the shipping saver never calls it and stays entropy-seeded.
    public static func seedSceneRNG(_ seed: UInt64) {
        saverRNG = SaverRNG(state: seed)
    }

    /// The captured desktop this view stands in front of. Production reads it
    /// off the session; the harness hands each display its own screenshot.
    public var previewBackdrop: CGImage?

    /// Rewinds to a fresh armed intro on `core`'s field `fieldIndex`: same
    /// seed and same knobs in, same frames out. Re-lays the row/writer grid
    /// too, so a resized window rebuilds cleanly.
    ///
    /// Every display's view shares ONE core, exactly as a session run does —
    /// that's what makes the fronts sweep continuously across the wall
    /// instead of each screen detonating its own private boom. Ticking it
    /// from each view is safe: advance(to:) is absolute, so the second view
    /// through a frame finds the work already done.
    public func previewReset(core: BoomCore, fieldIndex: Int,
                             arm: Double, seed: UInt64) {
        Self.seedSceneRNG(seed)
        setupSize = .zero          // makes ensureSetup rebuild rows + writers
        ensureSetup()
        startCycle(freshVerb: true)
        let field = core.fields[fieldIndex]
        let size = field.grid.size
        // Off-display origins land outside 0…1 — which is the point: only the
        // display holding the cursor draws the armed line and the flash.
        armIntro(atNormalized: CGPoint(
            x: (core.params.originCG.x - field.originCG.x) / size.width,
            y: (core.params.originCG.y - field.originCG.y) / size.height),
                 countdown: arm)
        boomCore = core
        boomFieldIndex = fieldIndex
        viewOriginCG = field.originCG
    }

    /// One driven frame: advance the sim, then paint it.
    public func previewStep(by dt: Double) {
        advance(by: dt)
        previewRepaint()
    }

    /// Repaints the sim state as it stands — all a paint-only knob needs, and
    /// the reason those knobs feel instant while sim knobs cost a replay.
    public func previewRepaint() {
        ensureMetalSurfaces()
        invalidateForFrame()
        renderMetalFrame()
    }

    /// Corpus lines for a harness-built core — the debris is made of these,
    /// so a multi-display preview should scatter real code like production
    /// rather than BoomCore's built-in fallback snippet.
    public func previewCodeLines() -> [String] { boomCodeLines() }

    /// Where the show stands, for the previewer's timeline readout.
    public struct PreviewState {
        public var beat: String        // armed / wave 1 / wave 2 / settling / steady
        public var sinceDetonation: Double
        public var front1: Double      // first front's sweep, 0…1
        public var front2: Double      // second front's, 0…1
        public var debris: Int         // particles still in flight
    }

    public var previewState: PreviewState {
        guard intro != .none, let core = boomCore else {
            let armLeft = intro == .armed ? armEndsAt - now : 0
            return PreviewState(beat: intro == .armed
                                    ? String(format: "armed  T−%.2f s", max(0, armLeft))
                                    : "steady state",
                                sinceDetonation: 0, front1: 0, front2: 0, debris: 0)
        }
        let t = now - boomStart
        let f1 = clampd(t / core.params.wave1, 0, 1)
        let f2 = clampd((t - core.params.gap) / core.params.wave2, 0, 1)
        let flying = core.particles.reduce(0) { $0 + ($1.settled ? 0 : 1) }
        let beat: String
        if f1 < 1 { beat = "wave 1 — pixelating" }
        else if f2 < 1 { beat = "wave 2 — wiping to black" }
        else if flying > 0 { beat = "debris settling" }
        else { beat = "steady state" }
        return PreviewState(beat: beat, sinceDetonation: t,
                            front1: f1, front2: f2, debris: flying)
    }

    /// Preview-window convenience: a click detonates at that point. The real
    /// saver never receives events (input ends the session first), and the
    /// scrubbing previewer routes clicks through its own rebuild instead.
    public override func mouseDown(with event: NSEvent) {
        guard bounds.width > 8, !externallyDriven else { return }
        let p = convert(event.locationInWindow, from: nil)
        armIntro(atNormalized: CGPoint(x: p.x / bounds.width, y: p.y / bounds.height),
                 countdown: 1.2)
    }

    /// CODESAVER_BOOM="x,y[,armSeconds]" (x/y as fractions) arms the intro at
    /// launch — the snapshot harness's deterministic trigger.
    private func configureIntroFromEnv() {
        guard let spec = ProcessInfo.processInfo.environment["CODESAVER_BOOM"] else { return }
        // Strict: every field must parse, in place. Dropping a bad field and
        // reading the survivors positionally armed the boom at the wrong
        // point with the wrong countdown, silently — the one thing a
        // deterministic snapshot trigger must never do.
        let fields = spec.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(fields.count),
              fields.allSatisfy({ $0.map(\.isFinite) == true }) else {
            viewLog.error("CODESAVER_BOOM=\"\(spec, privacy: .public)\" is not \"x,y[,armSeconds]\" — intro not armed")
            return
        }
        let parts = fields.compactMap { $0 }
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
        let wo = win.frame.origin
        // A view that turns up after the show is over (a display hot-plugged
        // or woken mid-session: the host builds it a fresh view, and the
        // cached session is still the activation's) has nothing to replay —
        // stepping the shared core through every missed tick would stall the
        // whole process for seconds per minute of age. It starts as the
        // ordinary saver, which is exactly where the others already are.
        let t = session.simTime
        if t > session.core.duration + 5 {
            BoomDiag.log(String(format: "%@ attach: session %.0f s old — boom over, plain saver",
                                diagID, t))
            return
        }
        // Which field is ours: appex service windows sit at their display's
        // CG origin (see clockVisible). No field for this origin (or for the
        // window's screen) means the manifest never described this display:
        // it is not one of the show's, so it never binds a field — binding
        // it to field 0 regardless would only make it a second claimant on
        // the main display, refused every frame and holding black for it.
        guard let idx = fieldIndex(in: session, for: win) else {
            BoomDiag.log(String(format: "%@ attach: window origin (%.0f, %.0f) matches no field — plain saver",
                                diagID, wo.x, wo.y))
            return
        }
        boomFieldIndex = idx
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
        if t < 0 {
            intro = .armed
            armEndsAt = now - t
            armTotal = session.armDuration
        } else {
            detonate(start: now - t)
        }
    }

    /// The session field a window belongs to: by frame origin first (where
    /// the host puts service windows), else by the window's screen — nil
    /// when the display is not one the manifest captured.
    private func fieldIndex(in session: BoomSession, for win: NSWindow) -> Int? {
        let wo = win.frame.origin
        if let i = session.core.fields.firstIndex(where: {
            abs($0.originCG.x - wo.x) < 0.5 && abs($0.originCG.y - wo.y) < 0.5
        }) { return i }
        guard let screen = win.screen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        let b = CGDisplayBounds(num)
        return session.core.fields.firstIndex {
            abs($0.originCG.x - b.origin.x) < 0.5 && abs($0.originCG.y - b.origin.y) < 0.5
        }
    }

    /// Drops out of the shared show and becomes the ordinary saver: no
    /// session, no core, no field — the plain steady state from the next
    /// frame. The session itself lives on for the sibling views.
    private func leaveBoomSession() {
        guard let session = boomSession else { return }
        session.releaseField(boomFieldIndex, by: ObjectIdentifier(self))
        boomSession = nil
        boomCore = nil
        intro = .none
        viewOriginCG = .zero
        fieldLostSince = 0
        fieldLostFrames = 0
        // A screen link chosen for the abandoned field is the wrong clock
        // now; re-engagement without a session picks the plain grid timer.
        reengageFallbackIfNeeded()
        setNeedsDisplay(bounds)
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
        // Same cap as the per-frame catch-up in advance(by:): past
        // duration+6 the field is fully transitioned, and a start handed in
        // from an old session clock must not replay every tick since.
        core.advance(to: min(max(0, now - boomStart), core.duration + 6))
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
    ///
    /// The boom field is a one-byte-per-cell ASCII grid — it has no way to
    /// carry a CJK glyph, and BoomCore drops any scalar outside 33…126. A
    /// line of Chinese comment would therefore stamp as a scatter of holes
    /// rather than code, so lines that are mostly non-ASCII are left out and
    /// the ASCII ones (every corpus has plenty) carry the spots.
    private func boomCodeLines() -> [String] {
        var lines: [String] = []
        for _ in 0..<6 {
            lines += randomChunk().map { String($0) }
        }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let stampable = lines.filter { line in
            let ink = line.unicodeScalars.filter { $0 != " " }
            guard !ink.isEmpty else { return false }
            return ink.filter { $0.value >= 33 && $0.value < 127 }.count * 4 >= ink.count * 3
        }
        if stampable.count >= 4 { return stampable }
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
        if let previewBackdrop { return previewBackdrop }
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


    // CODESAVER_CLOCK_EPOCH (unix seconds): pin the clock to epoch + sim time,
    // so offscreen snapshot renders tick at video speed instead of render speed.
    private static let clockEpoch: Date? = ProcessInfo.processInfo
        .environment["CODESAVER_CLOCK_EPOCH"].flatMap(Double.init)
        .map(Date.init(timeIntervalSince1970:))

    /// Refreshes the 1 Hz clock raster; shared by the CG path and the Metal
    /// quad builder.
    private func ensureClockCache() -> ClockCache? {
        let date = Self.clockEpoch?.addingTimeInterval(now) ?? Date()
        // Gregorian explicitly: day/year numerics must match the POSIX-locale
        // month/weekday names (a Buddhist-calendar system yields year 2569).
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second, .day, .year], from: date)
        let hh = c.hour ?? 0
        let hourStr = use24Hour ? String(format: "%02d", hh) : "\(hh % 12 == 0 ? 12 : hh % 12)"
        let minStr = String(format: "%02d", c.minute ?? 0)
        let secStr = String(format: "%02d", c.second ?? 0)
        let scale = window?.backingScaleFactor ?? 2

        // Keyed on the 24-hour `hh`, not just the rendered hour: in 12-hour
        // mode the raster also carries AM/PM, which hourStr cannot tell apart.
        let key = "\(hh)|\(hourStr):\(minStr):\(secStr)|\(c.day ?? 0)|\(use24Hour)|" +
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
        var f = monoFont(h * clockScale, .regular)
        var charW = ("\u{2588}" as NSString).size(withAttributes: [.font: f]).width
        // Slightly tighter than the natural line height so half-block rows
        // tile without seams (overdraw between rows is invisible).
        var step = (f.ascender - f.descender) * 0.9

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

        // Height-derived cells can overflow a narrow (portrait) screen —
        // shrink the font so the box always fits the width.
        let maxBoxW = bounds.width * 0.88
        let boxCols = CGFloat(inner + 2)
        if boxCols * charW > maxBoxW {
            f = monoFont(h * clockScale * maxBoxW / (boxCols * charW), .regular)
            charW = ("\u{2588}" as NSString).size(withAttributes: [.font: f]).width
            step = (f.ascender - f.descender) * 0.9
        }

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

