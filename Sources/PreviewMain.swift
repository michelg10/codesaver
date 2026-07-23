import AppKit

// Harness for CodeSaverView outside the screensaver engine.
//
//   preview                                  — windowed live preview
//   preview --snapshot <outdir> <t1> <t2> …  — render offscreen PNGs at sim times (seconds)
//
// Set CODESAVER_RESOURCES to a directory containing corpus.txt / spinner-verbs.txt.
// Boom intro: click anywhere in the live window to detonate at that point, or
// set CODESAVER_BOOM="x,y[,armSeconds]" (fractions of the view) to arm it at
// launch — the deterministic path for snapshots.

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
        // CODESAVER_SNAPSIZE=WxH overrides — e.g. 5120x2880 for perf timing.
        var size = NSSize(width: 1728, height: 1080)
        if let spec = ProcessInfo.processInfo.environment["CODESAVER_SNAPSIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        guard let view = CodeSaverView(frame: NSRect(origin: .zero, size: size), isPreview: false) else {
            fatalError("failed to create view")
        }
        let step = 1.0 / 30.0
        var sim = 0.0
        for target in times.sorted() {
            while sim < target {
                view.advance(by: step)
                sim += step
            }
            // Metal is THE renderer: the snapshot is an offscreen GPU frame.
            guard let cg = view.metalDebugSnapshot() else {
                print(String(format: "t=%.2f — no Metal frame", target))
                continue
            }
            let url = URL(fileURLWithPath: outDir)
                .appendingPathComponent(String(format: "frame-%07.2fs.png", target))
            let rep = NSBitmapImageRep(cgImage: cg)
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path)")
        }
        // The renderer's perf counters arrive as async blocks on the main
        // queue; pump it briefly so 60-frame averages reach the diag log.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    static func runWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "CodeSaver Preview"
        // The saver view is 33pt taller than the window, with the extra hanging
        // off the top edge (unrendered) — a stand-in for the menu bar area a
        // windowed app can't cover, so vertical tuning matches fullscreen.
        let menuBarPhantom: CGFloat = 33
        guard let view = CodeSaverView(
            frame: NSRect(x: 0, y: 0, width: rect.width, height: rect.height + menuBarPhantom),
            isPreview: false
        ) else { fatalError() }
        let host = PhantomTopHost(frame: rect, saver: view, extra: menuBarPhantom)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        // No timer here: the view's own fallback timer takes over ~1s after it
        // lands in the window. Driving it from both places ran at 2x speed.
        tuning = TuningController(view: view)
        tuning?.showPanel(beside: window)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    static var tuning: TuningController?

    /// Boom stand-in capture: the harness can't (and shouldn't) take real
    /// screenshots, and a black stand-in makes the asciify act invisible.
    /// Preference order: CODESAVER_CAPTURE, then a user-dropped
    /// build/stand-in-capture.png (gitignored — it's a real screen), then a
    /// synthesized bright fake desktop (wallpaper, menu bar, windows, dock).
    static func ensureStandInCapture() {
        guard ProcessInfo.processInfo.environment["CODESAVER_CAPTURE"] == nil else { return }
        // Next to the executable (build/), regardless of launch cwd.
        let dropped = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("stand-in-capture.png")
        if FileManager.default.fileExists(atPath: dropped.path) {
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

/// Hosts the saver view bottom-anchored with `extra` points extending above
/// the window's top edge, simulating the menu bar area of a real screen.
final class PhantomTopHost: NSView {
    private let saver: CodeSaverView
    private let extra: CGFloat

    init(frame: NSRect, saver: CodeSaverView, extra: CGFloat) {
        self.saver = saver
        self.extra = extra
        super.init(frame: frame)
        addSubview(saver)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        saver.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + extra)
    }
}

/// Floating panel of debug sliders for the clock style. Every change applies
/// live and is dumped to build/clock-tuning.json for later hardcoding.
final class TuningController: NSObject {
    private struct Knob {
        let label: String
        let min, max: Double
        let integer: Bool
        let key: String
        let get: () -> Double
        let set: (Double) -> Void
    }

    private let view: CodeSaverView
    private var knobs: [Knob] = []
    private var valueLabels: [NSTextField] = []
    private var sliders: [NSSlider] = []
    private var launchDefaults: [Double] = []
    private var panel: NSPanel?

    init(view: CodeSaverView) {
        self.view = view
        super.init()
        knobs = [
            Knob(label: "Side padding (cells)", min: 0, max: 12, integer: true, key: "clockPadCells",
                 get: { Double(view.clockPadCells) }, set: { view.clockPadCells = CGFloat($0.rounded()) }),
            Knob(label: "Top offset (% height)", min: 1, max: 16, integer: false, key: "clockTopFrac",
                 get: { Double(view.clockTopFrac) * 100 }, set: { view.clockTopFrac = CGFloat($0 / 100) }),
            Knob(label: "Cell size (% height)", min: 1.0, max: 3.0, integer: false, key: "clockScale",
                 get: { Double(view.clockScale) * 100 }, set: { view.clockScale = CGFloat($0 / 100) }),
            Knob(label: "Backdrop opacity", min: 0.0, max: 1.0, integer: false, key: "clockBackdropAlpha",
                 get: { Double(view.clockBackdropAlpha) }, set: { view.clockBackdropAlpha = CGFloat($0) }),
            Knob(label: "Border brightness", min: 0.15, max: 0.7, integer: false, key: "clockBorderWhite",
                 get: { Double(view.clockBorderWhite) }, set: { view.clockBorderWhite = CGFloat($0) }),
            Knob(label: "Digit brightness", min: 0.4, max: 1.0, integer: false, key: "clockDigitWhite",
                 get: { Double(view.clockDigitWhite) }, set: { view.clockDigitWhite = CGFloat($0) }),
            Knob(label: "V-pad rows", min: 0, max: 3, integer: true, key: "clockVPadRows",
                 get: { Double(view.clockVPadRows) }, set: { view.clockVPadRows = Int($0.rounded()) }),
            Knob(label: "Panel gap (× line)", min: 0.5, max: 4.0, integer: false, key: "panelGapMult",
                 get: { Double(view.panelGapMult) }, set: { view.panelGapMult = CGFloat($0) }),
            Knob(label: "Panel bias (× cell)", min: -10, max: 4, integer: false, key: "panelBias",
                 get: { Double(view.panelBias) }, set: { view.panelBias = CGFloat($0) }),
            Knob(label: "Code: active alpha", min: 0.25, max: 0.9, integer: false, key: "codeActiveAlpha",
                 get: { Double(view.codeActiveAlpha) }, set: { view.codeActiveAlpha = CGFloat($0) }),
            Knob(label: "Code: settled floor", min: 0.03, max: 0.45, integer: false, key: "codeSettledFloor",
                 get: { Double(view.codeSettledFloor) }, set: { view.codeSettledFloor = CGFloat($0) }),
            Knob(label: "Code: settled boost", min: 0.0, max: 0.6, integer: false, key: "codeSettledBoost",
                 get: { Double(view.codeSettledBoost) }, set: { view.codeSettledBoost = CGFloat($0) }),
            Knob(label: "Code: fade tau (s)", min: 6, max: 90, integer: false, key: "codeFadeTau",
                 get: { Double(view.codeFadeTau) }, set: { view.codeFadeTau = CGFloat($0) }),
            Knob(label: "Code: comment dim", min: 0.3, max: 1.0, integer: false, key: "codeCommentDim",
                 get: { Double(view.codeCommentDim) }, set: { view.codeCommentDim = CGFloat($0) }),
            Knob(label: "Code: glow strength", min: 0.0, max: 2.0, integer: false, key: "codeGlowStrength",
                 get: { Double(view.codeGlowStrength) }, set: { view.codeGlowStrength = CGFloat($0) }),
            Knob(label: "Vignette darkness", min: 0.0, max: 0.7, integer: false, key: "vignetteMax",
                 get: { Double(view.vignetteMax) }, set: { view.vignetteMax = CGFloat($0) }),
            Knob(label: "Boom: front 1 sweep (s)", min: 0.4, max: 2.0, integer: false, key: "boomWave1",
                 get: { view.boomWave1 }, set: { view.boomWave1 = $0 }),
            Knob(label: "Boom: front gap (s)", min: 0.2, max: 2.0, integer: false, key: "boomGap",
                 get: { view.boomGap }, set: { view.boomGap = $0 }),
            Knob(label: "Boom: front 2 sweep (s)", min: 0.4, max: 2.5, integer: false, key: "boomWave2",
                 get: { view.boomWave2 }, set: { view.boomWave2 = $0 }),
            Knob(label: "Boom: debris density", min: 0, max: 0.25, integer: false, key: "boomDebrisDensity",
                 get: { view.boomDebrisDensity }, set: { view.boomDebrisDensity = $0 }),
        ]
        launchDefaults = knobs.map { $0.get() }
    }

    func showPanel(beside window: NSWindow) {
        let rowH: CGFloat = 32
        let panelW: CGFloat = 470
        let panelH = CGFloat(knobs.count) * rowH + 88
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Clock tuning — saves to build/clock-tuning.json"
        p.isFloatingPanel = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))

        for (i, knob) in knobs.enumerated() {
            let y = panelH - CGFloat(i + 1) * rowH - 24
            let label = NSTextField(labelWithString: knob.label)
            label.frame = NSRect(x: 14, y: y, width: 165, height: 20)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

            let slider = NSSlider(value: knob.get(), minValue: knob.min, maxValue: knob.max,
                                  target: self, action: #selector(slid(_:)))
            slider.frame = NSRect(x: 185, y: y, width: 200, height: 20)
            slider.tag = i
            if knob.integer {
                slider.numberOfTickMarks = Int(knob.max - knob.min) + 1
                slider.allowsTickMarkValuesOnly = true
            }
            sliders.append(slider)

            let value = NSTextField(labelWithString: format(knob, knob.get()))
            value.frame = NSRect(x: 395, y: y, width: 65, height: 20)
            value.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            value.alignment = .right
            valueLabels.append(value)

            content.addSubview(label)
            content.addSubview(slider)
            content.addSubview(value)
        }

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults(_:)))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 14, y: 12, width: 160, height: 26)
        content.addSubview(reset)

        let replay = NSButton(title: "Replay boom", target: self, action: #selector(replayBoom(_:)))
        replay.bezelStyle = .rounded
        replay.frame = NSRect(x: 184, y: 12, width: 130, height: 26)
        content.addSubview(replay)

        p.contentView = content
        let f = window.frame
        p.setFrameOrigin(NSPoint(x: f.maxX + 12, y: f.maxY - panelH))
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    @objc private func replayBoom(_ sender: Any?) {
        view.replayBoom()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        for i in knobs.indices {
            knobs[i].set(launchDefaults[i])
            sliders[i].doubleValue = launchDefaults[i]
            valueLabels[i].stringValue = format(knobs[i], knobs[i].get())
        }
        dump()
    }

    private func format(_ knob: Knob, _ v: Double) -> String {
        knob.integer ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    @objc private func slid(_ sender: NSSlider) {
        let knob = knobs[sender.tag]
        knob.set(sender.doubleValue)
        valueLabels[sender.tag].stringValue = format(knob, knob.get())
        dump()
    }

    private func dump() {
        var out: [String: Double] = [:]
        for k in knobs {
            // Store the raw property value, not the display-scaled one.
            let v = k.get()
            let percentScaled = k.key.hasSuffix("Frac") || k.key == "clockScale"
            out[k.key] = percentScaled ? v / 100 : v
        }
        if let data = try? JSONSerialization.data(withJSONObject: out.mapValues { Double(String(format: "%.4f", $0))! },
                                                  options: [.prettyPrinted, .sortedKeys]) {
            // Next to the executable (build/), regardless of launch cwd.
            let url = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("clock-tuning.json")
            try? data.write(to: url)
        }
    }
}
