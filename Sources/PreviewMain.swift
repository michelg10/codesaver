import AppKit
import ScreenCaptureKit

// Harness for CodeSaverView outside the screensaver engine.
//
//   preview                                  — scrubbing previewer (below)
//   preview --snapshot <outdir> <t1> <t2> …  — render offscreen PNGs at sim times (seconds)
//
// Set CODESAVER_RESOURCES to a directory containing corpus.txt / spinner-verbs.txt.
// The previewer drops a stand-in desktop capture in for the boom; override it
// with CODESAVER_CAPTURE or by dropping build/stand-in-capture.png.
// Snapshots seed the scene RNG (corpus picks, verbs, writer placement) with a
// fixed constant so two runs — or two batches of one clip — line up;
// CODESAVER_SEED=<decimal|0xhex> picks a different deterministic scene.
// The live widget panels read the real feed (their timers follow the wall
// clock); CODESAVER_WIDGETS=0 leaves them out for byte-identical frames.
//
// CODESAVER_SAMPLE_CORPUS=1 is for anything that leaves this machine (site
// media, screenshots): the bundled sample instead of the container's corpus,
// the default verbs, no live feed unless CODESAVER_WIDGETS_DIR names a
// fixture, and never the dropped build/stand-in-capture.png. Snapshots take
// CODESAVER_SNAPSHOT_SIZE=WxH (alias CODESAVER_SNAPSIZE) for the simulated
// screen and CODESAVER_SNAPSHOT_SCALE=2 for Retina-density pixels.

@main
struct PreviewMain {
    static func main() {
        ensureStandInCapture()
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--snapshot" {
            snapshot(outDir: args[2], times: args.dropFirst(3).compactMap { Double($0) })
        } else {
            runWindow()
        }
    }

    static func snapshot(outDir: String, times: [Double]) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // CODESAVER_SNAPSIZE=WxH overrides — e.g. 5120x2880 for perf timing.
        let env = ProcessInfo.processInfo.environment
        var size = NSSize(width: 1728, height: 1080)
        if let spec = env["CODESAVER_SNAPSHOT_SIZE"] ?? env["CODESAVER_SNAPSIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        // Pixels per point: the layout stays the simulated screen's, the
        // bitmap gets denser (1440x900 at 2 = a 2880x1800 Retina frame).
        let scale = env["CODESAVER_SNAPSHOT_SCALE"].flatMap(Double.init)
            .map { CGFloat(max(1, $0)) } ?? 1
        // Seed BEFORE the view exists: init draws the first corpus subset,
        // verb, and writer bands off the scene RNG. detonate() pins its
        // BoomCore the same way; this is the other half of "deterministic".
        CodeSaverView.seedSceneRNG(sceneSeed)
        guard let view = CodeSaverView(frame: NSRect(origin: .zero, size: size), isPreview: false) else {
            fatalError("failed to create view")
        }
        if view.showingSampleCorpus {
            print("typing the bundled sample code")
        } else if CodeSaverView.sampleCorpusForced {
            print("CODESAVER_SAMPLE_CORPUS=1 but no sample found — typing the built-in fallback")
        }
        // CODESAVER_CLOCK_TOPFRAC overrides the clock's top offset (fraction
        // of height) — e.g. to clear app chrome in social-format renders.
        if let v = ProcessInfo.processInfo.environment["CODESAVER_CLOCK_TOPFRAC"]
            .flatMap(Double.init) {
            view.clockTopFrac = CGFloat(v)
        }
        let step = 1.0 / 30.0
        var steps = 0
        for target in times.sorted() {
            // Count steps rather than accumulating a running sum: the sum
            // drifts by an ulp every few frames and lands a hair under or
            // over a target requested on the same 1/30 grid, which renders
            // one instant twice and then skips one — a stutter baked into
            // every clip cut from these frames.
            while Double(steps) * step < target - 1e-9 {
                view.advance(by: step)
                steps += 1
            }
            // Metal is THE renderer: the snapshot is an offscreen GPU frame.
            // CODESAVER_PERF=1 also times the whole frame — quad build, UI
            // rasters, encode, GPU, readback — per snapshot: the live
            // renderer's 60-frame averages never fire offscreen (no completed
            // handler), and its cpu figure never covered the view's build
            // step anyway, so this is the harness's only per-frame number.
            let frameStart = CACurrentMediaTime()
            guard let cg = view.metalDebugSnapshot(scale: scale) else {
                print(String(format: "t=%.2f — no Metal frame", target))
                continue
            }
            if perfEnabled {
                print(String(format: "perf t=%.2f frame %.2f ms (build+encode+gpu+readback)",
                             target, (CACurrentMediaTime() - frameStart) * 1000))
            }
            let url = URL(fileURLWithPath: outDir)
                .appendingPathComponent(String(format: "frame-%07.2fs.png", target))
            let rep = NSBitmapImageRep(cgImage: cg)
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path)")
        }
        // Let anything queued on the main runloop (diag writes, deferred
        // teardown) drain before exit.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    static let perfEnabled = ProcessInfo.processInfo.environment["CODESAVER_PERF"] == "1"

    static var tuner: Tuner?

    /// Scene seed for the snapshot harness: CODESAVER_SEED (decimal or
    /// 0x-hex), else the constant detonate() pins its BoomCore to. A value
    /// that doesn't parse is reported, not silently swapped for the default.
    static var sceneSeed: UInt64 {
        let fallback: UInt64 = 0xC0DE_5AFE
        guard let raw = ProcessInfo.processInfo.environment["CODESAVER_SEED"]?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
        let lower = raw.lowercased()
        let parsed = lower.hasPrefix("0x")
            ? UInt64(lower.dropFirst(2), radix: 16)
            : UInt64(raw)
        guard let v = parsed else {
            FileHandle.standardError.write(
                Data("CODESAVER_SEED=\(raw) is not a UInt64; using default seed\n".utf8))
            return fallback
        }
        return v
    }

    /// The stand-in desktop, decoded once — the backdrop for any display we
    /// couldn't screenshot.
    static let standInImage: CGImage? = {
        guard let path = ProcessInfo.processInfo.environment["CODESAVER_CAPTURE"],
              let img = NSImage(contentsOfFile: path) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    static func standIn() -> CGImage? { standInImage }

    static func runWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // A menu bar, so ⌘Q always quits (an app without a Quit item has no
        // ⌘Q at all) and ⌘H hides the saver windows.
        tuner = Tuner()
        let menubar = NSMenu()
        let appItem = NSMenuItem(); menubar.addItem(appItem)
        let appMenu = NSMenu()
        let hide = NSMenuItem(title: "Hide saver windows", action: #selector(Tuner.hideScreensMenu(_:)),
                              keyEquivalent: "h")
        hide.target = tuner
        appMenu.addItem(hide)
        appMenu.addItem(withTitle: "Quit preview", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        app.mainMenu = menubar
        tuner?.show()
        app.activate(ignoringOtherApps: true)
        // Activation is cooperative: launched from a parent that isn't
        // frontmost, the first request is often refused and every keystroke
        // (esc included) keeps going to whatever was in front — under a
        // window that covers the screen. Keep asking for a few seconds.
        for delay in [0.3, 0.8, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                app.activate(ignoringOtherApps: true)
                tuner?.focusPanel()
            }
        }
        app.run()
    }

    /// Boom stand-in capture: the harness can't (and shouldn't) take real
    /// screenshots, and a black stand-in makes the asciify act invisible.
    /// Preference order: CODESAVER_CAPTURE, then a user-dropped
    /// build/stand-in-capture.png (gitignored — it's a real screen), then a
    /// synthesized bright fake desktop (wallpaper, menu bar, windows, dock).
    static func ensureStandInCapture() {
        guard ProcessInfo.processInfo.environment["CODESAVER_CAPTURE"] == nil else { return }
        // Next to the executable (build/), regardless of launch cwd. Never
        // under a forced sample: it is a real screen.
        let dropped = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("stand-in-capture.png")
        if !CodeSaverView.sampleCorpusForced, FileManager.default.fileExists(atPath: dropped.path) {
            setenv("CODESAVER_CAPTURE", dropped.path, 1)
            return
        }
        let size = NSSize(width: 1728, height: 1080)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.18, green: 0.28, blue: 0.45, alpha: 1),
                            NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.50, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 60)
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: 1052, width: 1728, height: 28).fill()
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(x: 124, y: 304, width: 752, height: 580).fill()
        NSColor(white: 0.55, alpha: 1).setFill()
        for i in 0..<22 {
            let y: CGFloat = 330 + CGFloat(i) * 24
            let w: CGFloat = 400 + CGFloat((i * 137) % 300)
            NSRect(x: 150, y: y, width: w, height: 10).fill()
        }
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 950, y: 180, width: 640, height: 540).fill()
        NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.5, alpha: 1).setFill()
        for i in 0..<16 {
            let y: CGFloat = 210 + CGFloat(i) * 30
            let w: CGFloat = 200 + CGFloat((i * 211) % 380)
            NSRect(x: 970, y: y, width: w, height: 8).fill()
        }
        NSColor(white: 0.85, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 500, y: 16, width: 728, height: 64),
                     xRadius: 16, yRadius: 16).fill()
        img.unlockFocus()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codesaver-fake-desktop.png")
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            setenv("CODESAVER_CAPTURE", url.path, 1)
        }
    }
}

// MARK: - Knobs

/// What moving a knob costs. `.paint` values are read by the renderer every
/// frame, so a repaint is enough and the preview tracks the slider live;
/// `.sim` values are baked into the choreography when the boom is armed, so
/// changing one rewinds and replays to the current timeline position.
enum KnobCost { case paint, sim }

struct Knob {
    let label: String
    let key: String
    let min, max: Double
    var integer = false
    var cost = KnobCost.paint
    let get: (CodeSaverView) -> Double
    let set: (CodeSaverView, Double) -> Void
}

struct KnobSection {
    let title: String
    let knobs: [Knob]
    /// One-click states: each sets several knobs at once (key → value).
    var presets: [(String, [String: Double])] = []
}

enum Knobs {
    /// Origin and arm length aren't view properties — the previewer owns them
    /// and feeds them to previewReset — so they live in the transport row.
    static let sections: [KnobSection] = [
        KnobSection(title: "Battery widget (gauge) — presets, then dial", knobs: [
            Knob(label: "override (0 = live IOKit)", key: "batteryDebugEnabled", min: 0, max: 1, integer: true,
                 get: { $0.batteryDebugEnabled ? 1 : 0 }, set: { $0.batteryDebugEnabled = $1 >= 0.5 }),
            Knob(label: "present (0 = desktop)", key: "batteryDebugPresent", min: 0, max: 1, integer: true,
                 get: { $0.batteryDebugPresent }, set: { $0.batteryDebugPresent = $1.rounded() }),
            Knob(label: "percent", key: "batteryDebugPct", min: 0, max: 100, integer: true,
                 get: { $0.batteryDebugPct }, set: { $0.batteryDebugPct = $1.rounded() }),
            Knob(label: "on AC", key: "batteryDebugAC", min: 0, max: 1, integer: true,
                 get: { $0.batteryDebugAC }, set: { $0.batteryDebugAC = $1.rounded() }),
            Knob(label: "charging", key: "batteryDebugCharging", min: 0, max: 1, integer: true,
                 get: { $0.batteryDebugCharging }, set: { $0.batteryDebugCharging = $1.rounded() }),
            Knob(label: "minutes (0 = unknown)", key: "batteryDebugMins", min: 0, max: 600, integer: true,
                 get: { $0.batteryDebugMins }, set: { $0.batteryDebugMins = $1.rounded() }),
        ], presets: [
            ("live IOKit", ["batteryDebugEnabled": 0]),
            ("on battery", ["batteryDebugEnabled": 1, "batteryDebugPresent": 1, "batteryDebugPct": 54,
                            "batteryDebugAC": 0, "batteryDebugCharging": 0, "batteryDebugMins": 252]),
            ("charging",   ["batteryDebugEnabled": 1, "batteryDebugPresent": 1, "batteryDebugPct": 78,
                            "batteryDebugAC": 1, "batteryDebugCharging": 1, "batteryDebugMins": 41]),
            ("low",        ["batteryDebugEnabled": 1, "batteryDebugPresent": 1, "batteryDebugPct": 9,
                            "batteryDebugAC": 0, "batteryDebugCharging": 0, "batteryDebugMins": 17]),
            ("full on AC", ["batteryDebugEnabled": 1, "batteryDebugPresent": 1, "batteryDebugPct": 100,
                            "batteryDebugAC": 1, "batteryDebugCharging": 0, "batteryDebugMins": 0]),
            ("unknown",    ["batteryDebugEnabled": 1, "batteryDebugPresent": 1, "batteryDebugPct": 54,
                            "batteryDebugAC": 0, "batteryDebugCharging": 0, "batteryDebugMins": 0]),
            ("desktop",    ["batteryDebugEnabled": 1, "batteryDebugPresent": 0]),
        ]),
        KnobSection(title: "Boom — choreography (replays)", knobs: [
            Knob(label: "front 1 sweep (s)", key: "boomWave1", min: 0.4, max: 4.0, cost: .sim,
                 get: { $0.boomWave1 }, set: { $0.boomWave1 = $1 }),
            Knob(label: "front gap (s)", key: "boomGap", min: 0.05, max: 2.5, cost: .sim,
                 get: { $0.boomGap }, set: { $0.boomGap = $1 }),
            Knob(label: "front 2 sweep (s)", key: "boomWave2", min: 0.4, max: 4.0, cost: .sim,
                 get: { $0.boomWave2 }, set: { $0.boomWave2 = $1 }),
            Knob(label: "debris density", key: "boomDebrisDensity", min: 0, max: 0.25, cost: .sim,
                 get: { $0.boomDebrisDensity }, set: { $0.boomDebrisDensity = $1 }),
        ]),
        KnobSection(title: "Boom — paint (live)", knobs: [
            Knob(label: "mosaic dim", key: "boomMosaicDim", min: 0.2, max: 1.0,
                 get: { $0.boomMosaicDim }, set: { $0.boomMosaicDim = $1 }),
        ]),
        KnobSection(title: "Background code", knobs: [
            Knob(label: "active alpha", key: "codeActiveAlpha", min: 0.25, max: 0.9,
                 get: { Double($0.codeActiveAlpha) }, set: { $0.codeActiveAlpha = CGFloat($1) }),
            Knob(label: "settled floor", key: "codeSettledFloor", min: 0.03, max: 0.45,
                 get: { Double($0.codeSettledFloor) }, set: { $0.codeSettledFloor = CGFloat($1) }),
            Knob(label: "settled boost", key: "codeSettledBoost", min: 0.0, max: 0.6,
                 get: { Double($0.codeSettledBoost) }, set: { $0.codeSettledBoost = CGFloat($1) }),
            Knob(label: "fade tau (s)", key: "codeFadeTau", min: 6, max: 90,
                 get: { Double($0.codeFadeTau) }, set: { $0.codeFadeTau = CGFloat($1) }),
            Knob(label: "comment dim", key: "codeCommentDim", min: 0.3, max: 1.0,
                 get: { Double($0.codeCommentDim) }, set: { $0.codeCommentDim = CGFloat($1) }),
            Knob(label: "glow strength", key: "codeGlowStrength", min: 0.0, max: 2.0,
                 get: { Double($0.codeGlowStrength) }, set: { $0.codeGlowStrength = CGFloat($1) }),
            Knob(label: "vignette darkness", key: "vignetteMax", min: 0.0, max: 0.7,
                 get: { Double($0.vignetteMax) }, set: { $0.vignetteMax = CGFloat($1) }),
        ]),
        KnobSection(title: "Clock & panel", knobs: [
            Knob(label: "side padding (cells)", key: "clockPadCells", min: 0, max: 12, integer: true,
                 get: { Double($0.clockPadCells) }, set: { $0.clockPadCells = CGFloat($1.rounded()) }),
            Knob(label: "top offset (% h)", key: "clockTopFrac", min: 1, max: 16,
                 get: { Double($0.clockTopFrac) * 100 }, set: { $0.clockTopFrac = CGFloat($1 / 100) }),
            Knob(label: "cell size (% h)", key: "clockScale", min: 1.0, max: 3.0,
                 get: { Double($0.clockScale) * 100 }, set: { $0.clockScale = CGFloat($1 / 100) }),
            Knob(label: "backdrop opacity", key: "clockBackdropAlpha", min: 0.0, max: 1.0,
                 get: { Double($0.clockBackdropAlpha) }, set: { $0.clockBackdropAlpha = CGFloat($1) }),
            Knob(label: "border brightness", key: "clockBorderWhite", min: 0.15, max: 0.7,
                 get: { Double($0.clockBorderWhite) }, set: { $0.clockBorderWhite = CGFloat($1) }),
            Knob(label: "digit brightness", key: "clockDigitWhite", min: 0.4, max: 1.0,
                 get: { Double($0.clockDigitWhite) }, set: { $0.clockDigitWhite = CGFloat($1) }),
            Knob(label: "v-pad rows", key: "clockVPadRows", min: 0, max: 3, integer: true,
                 get: { Double($0.clockVPadRows) }, set: { $0.clockVPadRows = Int($1.rounded()) }),
            Knob(label: "panel gap (× line)", key: "panelGapMult", min: 0.5, max: 4.0,
                 get: { Double($0.panelGapMult) }, set: { $0.panelGapMult = CGFloat($1) }),
            Knob(label: "panel bias (× cell)", key: "panelBias", min: -10, max: 4,
                 get: { Double($0.panelBias) }, set: { $0.panelBias = CGFloat($1) }),
        ]),
    ]

    static var all: [Knob] { sections.flatMap(\.knobs) }
}

// MARK: - The previewer

/// The saver, running for real on every attached display, with a floating
/// panel to scrub and tune it.
///
/// Each display gets a borderless screen-saver-level window at that display's
/// exact frame, so the views see true geometry — real point sizes, real cell
/// grids, real per-display cost. All of them share ONE BoomCore built from the
/// displays' CG rects, exactly as a session run does, so the fronts sweep
/// across the whole wall as one event instead of each screen booming alone.
///
/// The clock is the panel's, not the saver's (`externallyDriven`), and the
/// timeline is measured in whole 1/30 s frames — the beat the shipping saver
/// ticks on. A position on the slider is exactly N calls to advance() on every
/// view, so:
///
///   • scrubbing forward is stepping (what playback does),
///   • scrubbing back, or moving a `.sim` knob, replays from frame 0 against
///     the same seeds, so only the knob you moved differs,
///   • a `.paint` knob is a bare repaint at the current frame, which is what
///     makes those sliders feel attached to the picture.
final class Tuner: NSObject {
    private static let fps = 30.0

    /// One attached display: its CG rect (the space BoomCore works in) and
    /// the screenshot standing in for its desktop.
    private struct Display {
        let screen: NSScreen
        let cg: CGRect
        var capture: CGImage?

        var id: CGDirectDisplayID {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) ?? CGMainDisplayID()
        }
    }

    private var displays: [Display] = []
    private var views: [CodeSaverView] = []
    private var screenWindows: [NSWindow] = []
    private var hosts: [ScreenHost] = []
    private var panel: NSPanel!
    private var core: BoomCore?
    private var screensVisible = true

    // Timeline
    private var frame = 0                 // whole 1/30 s steps since arm start
    private var frameCount = 1
    private var seed: UInt64 = 0xC0DE_5AFE
    /// Detonation point in global CG coordinates — the space the displays are
    /// laid out in, so it can sit on any screen (or in a gap between them).
    private var origin = CGPoint.zero
    private var arm = 1.2
    private var playing = false
    private var playTimer: Timer?
    /// Coalesces a burst of slider events into one replay per runloop pass.
    private var pendingSeek: Int?
    private var pendingRebuild = false
    /// Leftover scroll distance below one frame's worth.
    private var scrollAccum: CGFloat = 0

    // Controls
    private var scrub: NSSlider!
    private var frameField: NSTextField!
    private var frameStepper: NSStepper!
    private var playButton: NSButton!
    private var screensButton: NSButton!
    private var readout: NSTextField!
    private var beatLabel: NSTextField!
    private var geometryLabel: NSTextField!
    private var armField: NSSlider!
    private var armLabel: NSTextField!
    private var sliders: [String: NSSlider] = [:]
    private var values: [String: NSTextField] = [:]
    private var defaults: [String: Double] = [:]

    private var lead: CodeSaverView? { views.first }

    // MARK: Bring-up

    func show() {
        displays = Self.attachedDisplays()
        // Centre of the main display, until you click somewhere.
        origin = CGPoint(x: displays[0].cg.midX, y: displays[0].cg.midY)
        buildScreenWindows()
        buildPanel()
        for k in Knobs.all { defaults[k.key] = lead.map(k.get) ?? 0 }
        rebuild()
        installKeyMonitor()
        // Real screenshots land a beat later; the stand-in covers until then.
        captureDisplays { [weak self] shots in
            guard let self else { return }
            var got = 0
            for i in self.displays.indices {
                if let img = shots[self.displays[i].id] { self.displays[i].capture = img; got += 1 }
            }
            print(got > 0 ? "captured \(got)/\(self.displays.count) displays"
                          : "no screen capture (grant Screen Recording, or drop build/stand-in-capture.png) — using the stand-in")
            fflush(stdout)
            self.rebuild()
        }
    }

    /// Every attached display, in CG coordinates — the same rects the igniter
    /// writes into its manifest, so the preview's geometry IS production's.
    private static func attachedDisplays() -> [Display] {
        let found = NSScreen.screens.compactMap { screen -> Display? in
            guard let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return Display(screen: screen, cg: CGDisplayBounds(num), capture: nil)
        }
        return found.isEmpty
            ? [Display(screen: NSScreen.main!, cg: CGDisplayBounds(CGMainDisplayID()), capture: nil)]
            : found
    }

    private func buildScreenWindows() {
        for d in displays {
            guard let saver = CodeSaverView(frame: NSRect(origin: .zero, size: d.cg.size),
                                            isPreview: false) else { continue }
            saver.externallyDriven = true
            let host = ScreenHost(saver: saver, cgOrigin: d.cg.origin)
            host.onClick = { [weak self] p in self?.setOrigin(p) }
            host.onScroll = { [weak self] delta in self?.shuttle(by: delta) }
            let w = ScreenWindow(contentRect: d.screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false, screen: d.screen)
            w.level = .screenSaver
            w.isOpaque = true
            w.backgroundColor = .black
            w.hidesOnDeactivate = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = host
            w.setFrame(d.screen.frame, display: true)
            w.orderFrontRegardless()
            views.append(saver)
            hosts.append(host)
            screenWindows.append(w)
        }
    }

    // MARK: Panel

    private static let panelW: CGFloat = 430
    private static let transportH: CGFloat = 206
    private static let footerH: CGFloat = 40

    private func buildPanel() {
        let h: CGFloat = 780
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelW, height: h),
                        styleMask: [.titled, .closable, .utilityWindow, .resizable],
                        backing: .buffered, defer: false)
        p.title = "CodeSaver — scrub & tune   (esc or ⌘Q quits · h hides)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        // Above the preview windows, which sit at screen-saver level.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The chrome is hand-painted dark, and modern AppKit buttons draw a
        // translucent bezel that picks up whatever is behind them while their
        // label follows the app appearance — in a light-mode session that's
        // black text on our dark grey. Pin it dark so controls match.
        p.appearance = NSAppearance(named: .darkAqua)

        let root = Panel(frame: NSRect(x: 0, y: 0, width: Self.panelW, height: h))
        root.fillColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        root.clipsToBounds = true
        root.autoresizingMask = [.width, .height]

        let transport = buildTransport(width: Self.panelW)
        transport.frame = NSRect(x: 0, y: h - Self.transportH,
                                 width: Self.panelW, height: Self.transportH)
        transport.autoresizingMask = [.width, .minYMargin]
        root.addSubview(transport)

        let scroll = buildKnobScroll(width: Self.panelW,
                                     height: h - Self.transportH - Self.footerH)
        scroll.frame = NSRect(x: 0, y: Self.footerH, width: Self.panelW,
                              height: h - Self.transportH - Self.footerH)
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)

        for (i, b) in [button("Reset", x: 10, y: 8, w: 72) { [weak self] in self?.resetKnobs() },
                       button("Reroll", x: 86, y: 8, w: 72) { [weak self] in self?.reroll() },
                       button("Save JSON", x: 162, y: 8, w: 96) { [weak self] in self?.dump() },
                       button("Hide", x: 262, y: 8, w: 72) { [weak self] in self?.toggleScreens() },
                       button("Quit", x: 338, y: 8, w: 72) { NSApp.terminate(nil) }].enumerated() {
            b.autoresizingMask = [.maxYMargin]
            if i == 3 { screensButton = b }
            root.addSubview(b)
        }

        p.contentView = root
        // Bottom-left of the main display, out of the way of the show.
        let f = displays[0].screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.minX + 24, y: f.minY + 24))
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
    }

    private func buildTransport(width: CGFloat) -> NSView {
        let bar = Panel(frame: NSRect(x: 0, y: 0, width: width, height: Self.transportH))
        bar.fillColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        bar.clipsToBounds = true

        var y = Self.transportH - 36
        playButton = button("▶", x: 14, y: y, w: 40) { [weak self] in self?.togglePlay() }
        bar.addSubview(playButton)
        bar.addSubview(button("⏮", x: 58, y: y, w: 34) { [weak self] in self?.nudge(-1 << 20) })
        // Spelled out rather than ◀ ▶: those read as rewind next to the play
        // button, and single-frame is the whole point of them.
        bar.addSubview(button("−1f", x: 96, y: y, w: 44) { [weak self] in self?.nudge(-1) })
        bar.addSubview(button("+1f", x: 144, y: y, w: 44) { [weak self] in self?.nudge(1) })

        frameField = NSTextField(string: "0")
        frameField.frame = NSRect(x: width - 96, y: y + 1, width: 52, height: 21)
        frameField.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        frameField.alignment = .right
        frameField.target = self
        frameField.action = #selector(frameTyped(_:))
        frameField.autoresizingMask = [.minXMargin]
        bar.addSubview(frameField)

        let stepper = NSStepper(frame: NSRect(x: width - 40, y: y, width: 16, height: 23))
        stepper.minValue = 0
        stepper.maxValue = 1
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        stepper.autoresizingMask = [.minXMargin]
        frameStepper = stepper
        bar.addSubview(stepper)

        y -= 30
        scrub = NSSlider(value: 0, minValue: 0, maxValue: 1,
                         target: self, action: #selector(scrubbed(_:)))
        scrub.frame = NSRect(x: 14, y: y, width: width - 28, height: 20)
        scrub.autoresizingMask = [.width]
        scrub.isContinuous = true
        bar.addSubview(scrub)

        y -= 24
        readout = mono("", x: 14, y: y, w: width - 28, size: 11, bold: true)
        readout.autoresizingMask = [.width]
        bar.addSubview(readout)

        y -= 20
        beatLabel = mono("", x: 14, y: y, w: width - 28, size: 10)
        beatLabel.textColor = NSColor(calibratedRed: 0.72, green: 0.66, blue: 1.0, alpha: 1)
        beatLabel.autoresizingMask = [.width]
        bar.addSubview(beatLabel)

        // Beat jumps: the show's landmarks, so "the moment wave 2 starts" is
        // one click instead of a hunt along the slider.
        y -= 32
        let beats: [(String, Beat)] = [("arm", .arm), ("boom", .detonation),
                                       ("½ w1", .halfWave1), ("wave 2", .wave2),
                                       ("settle", .settle), ("end", .end)]
        let bw = (width - 28 - CGFloat(beats.count - 1) * 4) / CGFloat(beats.count)
        for (i, (title, at)) in beats.enumerated() {
            let b = button(title, x: 14 + CGFloat(i) * (bw + 4), y: y, w: bw) {
                [weak self] in self?.jump(to: at)
            }
            b.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            bar.addSubview(b)
        }

        y -= 30
        armLabel = mono("arm 1.20 s", x: 14, y: y + 2, w: 68, size: 10)
        bar.addSubview(armLabel)
        armField = NSSlider(value: arm, minValue: 0.3, maxValue: 6,
                            target: self, action: #selector(armChanged(_:)))
        armField.frame = NSRect(x: 86, y: y + 1, width: 110, height: 20)
        armField.isContinuous = true
        bar.addSubview(armField)

        geometryLabel = mono("", x: 202, y: y + 2, w: width - 216, size: 10)
        geometryLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        geometryLabel.autoresizingMask = [.width]
        bar.addSubview(geometryLabel)

        return bar
    }

    private func buildKnobScroll(width: CGFloat, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let rowH: CGFloat = 30, headH: CGFloat = 28
        var docH: CGFloat = 12
        func presetRows(_ s: KnobSection) -> Int { (s.presets.count + 3) / 4 }
        for s in Knobs.sections {
            docH += headH + CGFloat(s.knobs.count + presetRows(s)) * rowH + 8
        }
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: width - 16, height: docH))

        var y = docH - 12
        for section in Knobs.sections {
            y -= headH
            let h = mono(section.title, x: 12, y: y + 6, w: width - 40, size: 10, bold: true)
            h.textColor = NSColor(calibratedRed: 0.72, green: 0.66, blue: 1.0, alpha: 1)
            doc.addSubview(h)
            // Preset buttons, four to a row, above the section's sliders.
            for chunk in stride(from: 0, to: section.presets.count, by: 4)
                .map({ Array(section.presets[$0..<min($0 + 4, section.presets.count)]) }) {
                y -= rowH
                let bw = (width - 40 - 3 * 4) / 4
                for (i, (title, preset)) in chunk.enumerated() {
                    let b = button(title, x: 12 + CGFloat(i) * (bw + 4), y: y + 3, w: bw) {
                        [weak self] in self?.applyPreset(preset)
                    }
                    b.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                    doc.addSubview(b)
                }
            }
            for knob in section.knobs {
                y -= rowH
                doc.addSubview(mono(knob.label, x: 12, y: y + 4, w: 168, size: 10))
                let value = lead.map(knob.get) ?? knob.min
                let s = NSSlider(value: value, minValue: knob.min, maxValue: knob.max,
                                 target: self, action: #selector(knobMoved(_:)))
                s.frame = NSRect(x: 184, y: y + 3, width: 170, height: 20)
                s.isContinuous = true
                s.identifier = NSUserInterfaceItemIdentifier(knob.key)
                if knob.integer {
                    s.numberOfTickMarks = Int(knob.max - knob.min) + 1
                    s.allowsTickMarkValuesOnly = true
                }
                sliders[knob.key] = s
                doc.addSubview(s)
                let v = mono(fmt(knob, value), x: 360, y: y + 4, w: 52, size: 10, bold: true)
                v.alignment = .right
                values[knob.key] = v
                doc.addSubview(v)
            }
            y -= 8
        }
        scroll.documentView = doc
        // An unflipped document view starts scrolled to its BOTTOM, which
        // opens the panel on the last knob section. Show the first.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, docH - height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll
    }

    // MARK: The shared core

    /// One core over every display, mirroring BoomSession.loadIfNeeded: a
    /// field per display at its CG rect, and a radius reaching the farthest
    /// corner of the whole wall so one sweep covers all of them.
    private func makeCore() -> BoomCore? {
        guard !views.isEmpty else { return nil }
        let stand = PreviewMain.standIn()
        var fields: [BoomField] = []
        var radius: CGFloat = 0
        for d in displays {
            let grid = BoomGrid(size: d.cg.size)
            let img = d.capture ?? stand
            let color = img.map { BoomCore.colorize($0, grid: grid) } ?? []
            fields.append(BoomField(grid: grid, originCG: d.cg.origin, color: color))
            for c in [CGPoint(x: d.cg.minX, y: d.cg.minY), CGPoint(x: d.cg.maxX, y: d.cg.minY),
                      CGPoint(x: d.cg.minX, y: d.cg.maxY), CGPoint(x: d.cg.maxX, y: d.cg.maxY)] {
                radius = max(radius, hypot(c.x - origin.x, c.y - origin.y))
            }
        }
        guard let lead else { return nil }
        return BoomCore(
            params: BoomCore.Params(originCG: origin, radius: max(radius, 1), seed: seed | 1,
                                    wave1: lead.boomWave1, gap: lead.boomGap,
                                    wave2: lead.boomWave2,
                                    debrisDensity: lead.boomDebrisDensity,
                                    codeLines: lead.previewCodeLines()),
            fields: fields)
    }

    // MARK: Timeline

    private enum Beat { case arm, detonation, halfWave1, wave2, settle, end }

    private var armFrames: Int { Int((arm * Self.fps).rounded()) }

    /// The whole show, plus a few seconds of steady state to scrub into.
    private func recomputeLength() {
        guard let lead else { return }
        let tail = lead.boomGap + lead.boomWave2 + 4.5
        frameCount = max(2, armFrames + Int((tail * Self.fps).rounded()))
        scrub.minValue = 0
        scrub.maxValue = Double(frameCount)
        // One tick per frame, values-only: dragging lands on whole frames
        // instead of a float we'd have to round behind your back.
        scrub.numberOfTickMarks = frameCount + 1
        scrub.allowsTickMarkValuesOnly = true
        scrub.tickMarkPosition = .below
        frameStepper.maxValue = Double(frameCount)
    }

    private func jump(to beat: Beat) {
        guard let lead else { return }
        pause()
        let f: Int
        switch beat {
        case .arm:        f = 0
        case .detonation: f = armFrames
        case .halfWave1:  f = armFrames + Int(lead.boomWave1 * 0.5 * Self.fps)
        case .wave2:      f = armFrames + Int(lead.boomGap * Self.fps)
        case .settle:     f = armFrames + Int((lead.boomGap + lead.boomWave2) * Self.fps)
        case .end:        f = frameCount
        }
        seek(to: f)
    }

    private func nudge(_ delta: Int) {
        pause()
        seek(to: frame + delta)
    }

    @objc private func scrubbed(_ s: NSSlider) {
        pause()
        seek(to: Int(s.doubleValue.rounded()))
    }

    @objc private func stepped(_ s: NSStepper) {
        nudge(Int(s.doubleValue.rounded()) - frame)
    }

    @objc private func frameTyped(_ f: NSTextField) {
        pause()
        seek(to: Int(f.doubleValue.rounded()))
    }

    /// Scroll over any preview screen to walk the timeline — a trackpad flick
    /// is the closest thing to shuttling frame by frame. One frame per ~8
    /// points of scroll, whichever axis you push.
    private func shuttle(by points: CGFloat) {
        scrollAccum += points
        let steps = Int(scrollAccum / 8)
        guard steps != 0 else { return }
        scrollAccum -= CGFloat(steps) * 8
        nudge(steps)
    }

    /// Requests a timeline position. The work is deferred one runloop hop so a
    /// drag that fires twenty events replays once, not twenty times.
    private func seek(to f: Int) {
        let clamped = max(0, min(frameCount, f))
        let had = pendingSeek != nil || pendingRebuild
        pendingSeek = clamped
        if !had { DispatchQueue.main.async { [weak self] in self?.flush() } }
    }

    /// Replays from frame 0 at the current knob values — what a `.sim` knob, a
    /// new origin/arm, or a fresh screenshot needs.
    private func rebuild() {
        recomputeLength()
        let had = pendingSeek != nil || pendingRebuild
        pendingRebuild = true
        if pendingSeek == nil { pendingSeek = min(frame, frameCount) }
        if !had { DispatchQueue.main.async { [weak self] in self?.flush() } }
    }

    private func flush() {
        guard let target = pendingSeek else { pendingRebuild = false; return }
        pendingSeek = nil
        let replay = pendingRebuild || target < frame
        pendingRebuild = false
        if replay {
            // makeCore() draws the debris code pool off the scene RNG. Seed
            // FIRST, or the pool depends on how many draws the previous
            // replay's stepping consumed — and a .sim knob replay would
            // compare two different pictures. previewReset reseeds per view
            // right after, as before.
            CodeSaverView.seedSceneRNG(seed)
            core = makeCore()
            if let core {
                let stand = PreviewMain.standIn()
                for (i, v) in views.enumerated() {
                    v.previewBackdrop = displays[i].capture ?? stand
                    // A seed per display: same run every replay, but each
                    // screen types its own code rather than a chorus.
                    v.previewReset(core: core, fieldIndex: i, arm: arm,
                                   seed: seed &+ UInt64(i) &* 0x9E37_79B9)
                }
            }
            frame = 0
        }
        let dt = 1.0 / Self.fps
        while frame < target {
            for v in views { v.advance(by: dt) }
            frame += 1
        }
        for v in views { v.previewRepaint() }
        updateReadout()
    }

    private func updateReadout() {
        guard let lead else { return }
        let st = lead.previewState
        let t = Double(frame) / Self.fps - arm
        readout.stringValue = String(format: "t %+.2f s   ·   %d frames   ·   %d display%@",
                                     t, frameCount, displays.count,
                                     displays.count == 1 ? "" : "s")
        beatLabel.stringValue = String(
            format: "%@ · front 1 %3.0f%% · front 2 %3.0f%% · debris %d",
            st.beat, st.front1 * 100, st.front2 * 100, st.debris)
        let on = displays.firstIndex { $0.cg.contains(origin) }
        geometryLabel.stringValue = String(
            format: "boom at %.0f, %.0f  (%@)", origin.x, origin.y,
            on.map { "screen \($0 + 1)" } ?? "off-screen")
        if Int(scrub.doubleValue.rounded()) != frame { scrub.doubleValue = Double(frame) }
        if Int(frameStepper.doubleValue.rounded()) != frame {
            frameStepper.doubleValue = Double(frame)
        }
        // Don't yank the text out from under someone mid-edit.
        if panel.firstResponder !== frameField.currentEditor() {
            frameField.stringValue = String(frame)
        }
    }

    // MARK: Playback

    private func togglePlay() { playing ? pause() : play() }

    private func play() {
        if frame >= frameCount { seek(to: 0) }
        playing = true
        playButton.title = "⏸"
        let t = Timer(timeInterval: 1.0 / Self.fps, repeats: true) { [weak self] _ in
            guard let self, self.playing else { return }
            if self.frame >= self.frameCount { self.pause(); return }
            self.seek(to: self.frame + 1)
        }
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
    }

    private func pause() {
        playing = false
        playButton.title = "▶"
        playTimer?.invalidate()
        playTimer = nil
    }

    // MARK: Knobs

    @objc private func knobMoved(_ s: NSSlider) {
        guard let key = s.identifier?.rawValue,
              let knob = Knobs.all.first(where: { $0.key == key }) else { return }
        for v in views { knob.set(v, s.doubleValue) }
        values[key]?.stringValue = fmt(knob, lead.map(knob.get) ?? s.doubleValue)
        switch knob.cost {
        case .paint:
            // Read fresh by the renderer every frame: repaint and you're done.
            for v in views { v.previewRepaint() }
        case .sim:
            // Baked into the choreography when the boom arms: only a replay
            // can show it.
            rebuild()
        }
        dump()
    }

    @objc private func armChanged(_ s: NSSlider) {
        arm = s.doubleValue
        armLabel.stringValue = String(format: "arm %.2f s", arm)
        rebuild()
    }

    /// A click anywhere on the wall — including the screen the cursor isn't
    /// on — moves the detonation point there.
    private func setOrigin(_ globalCG: CGPoint) {
        origin = globalCG
        rebuild()
    }

    /// Pull focus to the panel so esc / h / space land here.
    func focusPanel() {
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc func hideScreensMenu(_ sender: Any?) { toggleScreens() }

    private func toggleScreens() {
        screensVisible.toggle()
        screensButton.title = screensVisible ? "Hide" : "Show"
        for w in screenWindows {
            if screensVisible { w.orderFrontRegardless() } else { w.orderOut(nil) }
        }
    }

    private func resetKnobs() {
        for knob in Knobs.all {
            guard let d = defaults[knob.key] else { continue }
            for v in views { knob.set(v, d) }
            sliders[knob.key]?.doubleValue = d
            values[knob.key]?.stringValue = fmt(knob, d)
        }
        rebuild()
        dump()
    }

    /// A preset sets several knobs at once and repaints; the sliders follow.
    private func applyPreset(_ preset: [String: Double]) {
        for (key, value) in preset {
            guard let knob = Knobs.all.first(where: { $0.key == key }) else { continue }
            for v in views { knob.set(v, value) }
            sliders[key]?.doubleValue = value
            values[key]?.stringValue = fmt(knob, value)
        }
        for v in views { v.previewRepaint() }
        dump()
    }

    /// New corpus text, verb and writer placement — the boom's own seed rides
    /// along, so the choreography you're tuning shifts too. Cheap variety.
    private func reroll() {
        seed &+= 0x9E37_79B9
        rebuild()
    }

    private func dump() {
        guard let lead else { return }
        var out: [String: Double] = [:]
        for k in Knobs.all {
            // Store the raw property value, not the display-scaled one.
            let v = k.get(lead)
            let percentScaled = k.key.hasSuffix("Frac") || k.key == "clockScale"
            out[k.key] = Double(String(format: "%.4f", percentScaled ? v / 100 : v))!
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Next to the executable (build/), regardless of launch cwd.
        let url = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("clock-tuning.json")
        try? data.write(to: url)
    }

    // MARK: Keyboard
    //
    // A local monitor rather than keyDown on a view: the preview windows never
    // take key (the panel keeps it), and the moment you touch a slider the
    // focus is gone — "arrows step frames" has to keep working wherever the
    // focus ended up. Only text editing wins over it.

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !(self.panel.firstResponder is NSTextView) else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.charactersIgnoringModifiers {
        case " ": togglePlay(); return true
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!), ",":  nudge(-step); return true
        case String(UnicodeScalar(NSRightArrowFunctionKey)!), ".": nudge(step); return true
        case String(UnicodeScalar(NSHomeFunctionKey)!): nudge(-1 << 20); return true
        case String(UnicodeScalar(NSEndFunctionKey)!):  nudge(1 << 20); return true
        case "\u{1B}": NSApp.terminate(nil); return true       // esc — the way out
        case "h": toggleScreens(); return true
        case "r": reroll(); return true
        default: return false
        }
    }

    // MARK: Small builders

    private func fmt(_ knob: Knob, _ v: Double) -> String {
        knob.integer ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    private func mono(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat,
                      size: CGFloat, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.frame = NSRect(x: x, y: y, width: w, height: 18)
        f.font = .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        f.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        return f
    }

    private func button(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat,
                        action: @escaping () -> Void) -> NSButton {
        let b = ActionButton(title: title, target: nil, action: nil)
        b.run = action
        b.target = b
        b.action = #selector(ActionButton.fire)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: y, width: w, height: 26)
        return b
    }
}

// MARK: - Screen capture

/// One-shot screenshots of every display at NATIVE pixel resolution — the
/// igniter's capture, verbatim (including the rect form that keeps window
/// shadows; see captureDisplays in helper/Igniter.swift), so the preview's
/// backdrops are the same pixels production would have handed the saver.
/// Needs Screen Recording; without it the caller falls back to the stand-in
/// desktop.
private func captureDisplays(_ completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
    guard #available(macOS 14.0, *) else { completion([:]); return }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
        guard let content else {
            if let err { print("screen capture unavailable: \(err.localizedDescription)") }
            DispatchQueue.main.async { completion([:]) }
            return
        }
        var result: [CGDirectDisplayID: CGImage] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for display in content.displays {
            group.enter()
            let store: (CGImage?) -> Void = { image in
                if let image {
                    lock.lock(); result[display.displayID] = image; lock.unlock()
                }
                group.leave()
            }
            if #available(macOS 15.2, *) {
                SCScreenshotManager.captureImage(in: CGDisplayBounds(display.displayID)) {
                    image, _ in store(image)
                }
            } else {
                let config = SCStreamConfiguration()
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                config.width = mode.map(\.pixelWidth) ?? display.width
                config.height = mode.map(\.pixelHeight) ?? display.height
                config.showsCursor = false
                SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: config
                ) { image, _ in store(image) }
            }
        }
        group.notify(queue: .main) { completion(result) }
    }
}

// MARK: - Views

/// NSButton with a closure, so the transport reads as a list of verbs.
private final class ActionButton: NSButton {
    var run: () -> Void = {}
    @objc func fire() { run() }
}

/// A view that actually paints its background (NSView doesn't).
///
/// Fills `bounds`, not `dirtyRect`, and clips: since macOS 14 clipsToBounds
/// defaults to false, so a panel that fills the dirty rect happily paints
/// over its siblings — the whole window ends up the colour of whichever
/// panel draws last.
private final class Panel: NSView {
    var fillColor = NSColor.black
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// A preview screen. Never takes key — the panel keeps focus and the keyboard
/// shortcuts with it — but still answers clicks, which is where the boom
/// origin comes from.
private final class ScreenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Fills one display with the saver and turns a click into a point in GLOBAL
/// CG coordinates — the space BoomCore lays its fields out in, so clicking
/// screen 2 detonates on screen 2.
private final class ScreenHost: NSView {
    private let saver: CodeSaverView
    private let cgOrigin: CGPoint
    var onClick: ((CGPoint) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    init(saver: CodeSaverView, cgOrigin: CGPoint) {
        self.saver = saver
        self.cgOrigin = cgOrigin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(saver)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        saver.frame = bounds
    }

    /// Swallows every hit in its area. Otherwise the click lands on the
    /// saver's Metal host, walks up the responder chain to CodeSaverView —
    /// whose mouseDown is a no-op under `externallyDriven` — and dies there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// The preview windows are never key, so without this every click would
    /// be eaten as an activation click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Any click on the saver pulls focus here, so esc works right after.
        NSApp.activate(ignoringOtherApps: true)
        PreviewMain.tuner?.focusPanel()
        // Into the saver's own space first: it's flipped, so this is already
        // x-from-left / y-from-top, which is what CG global coords want.
        let p = saver.convert(event.locationInWindow, from: nil)
        guard saver.bounds.contains(p) else { return }
        onClick?(CGPoint(x: cgOrigin.x + p.x, y: cgOrigin.y + p.y))
    }

    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : -event.scrollingDeltaY
        onScroll?(d)
    }
}
