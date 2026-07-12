import AppKit

// Harness for CodeSaverView outside the screensaver engine.
//
//   preview                                  — windowed live preview
//   preview --snapshot <outdir> <t1> <t2> …  — render offscreen PNGs at sim times (seconds)
//
// Set CODESAVER_RESOURCES to a directory containing corpus.txt / spinner-verbs.txt.

@main
struct PreviewMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--snapshot" {
            snapshot(outDir: args[2], times: args.dropFirst(3).compactMap { Double($0) })
        } else {
            runWindow()
        }
    }

    static func snapshot(outDir: String, times: [Double]) {
        let size = NSSize(width: 1728, height: 1080)
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
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let raw = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap") }
            // The view is flipped: use a flipped context plus a CTM flip so text renders upright.
            let ctx = NSGraphicsContext(cgContext: raw.cgContext, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            view.draw(view.bounds)
            ctx.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            let name = String(format: "frame-%07.2fs.png", target)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path)")
        }
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

        p.contentView = content
        let f = window.frame
        p.setFrameOrigin(NSPoint(x: f.maxX + 12, y: f.maxY - panelH))
        p.makeKeyAndOrderFront(nil)
        panel = p
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
