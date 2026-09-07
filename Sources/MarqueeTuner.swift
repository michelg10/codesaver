// Marquee tuner — a small window that shows the now-playing panel's title /
// artist roll and lets you tune it. Standalone on purpose: it carries a copy
// of the panel's chrome and of CodeSaverView.marqueeText (the loop mode is
// that function verbatim, with its constants exposed), so it builds and
// opens in a second and never touches the saver. Pick values here, then port
// them into marqueeText.
//
//   swiftc -O -parse-as-library Sources/MarqueeTuner.swift -framework AppKit -o build/marquee-tuner
//   build/marquee-tuner
//
// Every change is written to build/marquee-tuning.json (next to the binary)
// and reloaded on the next launch.

import AppKit

// MARK: - Tuning

enum MarqueeMode: String, CaseIterable {
    case snap, bounce, loop
    var label: String {
        switch self {
        case .snap: return "snap back"
        case .bounce: return "bounce"
        case .loop: return "loop"
        }
    }
}

struct MarqueeTuning: Codable, Equatable {
    var mode = "loop"           // snap | bounce | loop (saver: loop since 2026-09-07)
    var stepSeconds = 0.13      // seconds per glyph (saver: 0.13)
    var holdStart = 4.0         // rest before each lap (saver: 4.0)
    var holdEnd = 1.8           // snap/bounce: pause at the far end (loop ignores it)
    var loopGap = 7             // loop: cells between the tail and the head again (saver: 7)
    var separator = "spaces"    // loop: spaces | ∙ | ─
    var edgeMarks = false       // … on the edge where text continues
    var sync = false            // title and artist share one cycle
    var fieldCells = 44         // text field width = art columns (saver default 44)
    var fontSize = 15.4         // saver: width/125 clamped 11.5…16.5 → 15.4 on 1920

    var modeValue: MarqueeMode { MarqueeMode(rawValue: mode) ?? .snap }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        stepSeconds = try c.decodeIfPresent(Double.self, forKey: .stepSeconds) ?? stepSeconds
        holdStart = try c.decodeIfPresent(Double.self, forKey: .holdStart) ?? holdStart
        holdEnd = try c.decodeIfPresent(Double.self, forKey: .holdEnd) ?? holdEnd
        loopGap = try c.decodeIfPresent(Int.self, forKey: .loopGap) ?? loopGap
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? separator
        edgeMarks = try c.decodeIfPresent(Bool.self, forKey: .edgeMarks) ?? edgeMarks
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? sync
        fieldCells = try c.decodeIfPresent(Int.self, forKey: .fieldCells) ?? fieldCells
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
    }
}

// MARK: - The marquee

struct MarqueeText {
    let chars: [Character]
    let cells: [Int]
    let total: Int
    init(_ s: String, measure: (Character) -> Int) {
        chars = Array(s)
        cells = chars.map(measure)
        total = cells.reduce(0, +)
    }
}

struct MarqueeEngine {
    let tuning: MarqueeTuning
    let width: Int
    let measure: (Character) -> Int

    struct Plan {
        var text: MarqueeText
        var sep: [Character] = []
        var over = 0        // snap/bounce: glyphs to walk past until the tail fits
        var ring = 0        // loop: glyphs in the ring (text + gap)
        var scrolls = false
    }

    private var separatorGlyphs: [Character] {
        let n = max(1, tuning.loopGap)
        switch tuning.separator {
        case "∙":
            var g = Array(repeating: Character(" "), count: n)
            g[n / 2] = "∙"
            return g
        case "─":
            if n < 3 { return ["─"] }
            return [" "] + Array(repeating: Character("─"), count: n - 2) + [" "]
        default:
            return Array(repeating: " ", count: n)
        }
    }

    func plan(_ s: String) -> Plan {
        let mt = MarqueeText(s, measure: measure)
        var p = Plan(text: mt, sep: separatorGlyphs)
        guard width > 0, mt.total > width else { return p }
        p.scrolls = true
        // Walk one glyph at a time until the remainder fits the field — a wide
        // glyph is one step like any other, it just frees two cells. With edge
        // marks on, the far end also carries a leading … so the tail gets one
        // cell less.
        let endW = tuning.edgeMarks && tuning.modeValue != .loop ? width - 1 : width
        var over = 0, rest = mt.total
        while over < mt.chars.count, rest > endW { rest -= mt.cells[over]; over += 1 }
        p.over = over
        p.ring = mt.chars.count + p.sep.count
        return p
    }

    /// Length of this text's own cycle; 0 when it does not scroll.
    func ownCycle(_ p: Plan) -> Double {
        guard p.scrolls else { return 0 }
        let step = tuning.stepSeconds
        switch tuning.modeValue {
        case .snap:   return tuning.holdStart + Double(p.over) * step + tuning.holdEnd
        case .bounce: return tuning.holdStart + Double(p.over) * step * 2 + tuning.holdEnd
        case .loop:   return tuning.holdStart + Double(p.ring) * step
        }
    }

    /// Steps walked (for the caption).
    func steps(_ p: Plan) -> Int { tuning.modeValue == .loop ? p.ring : p.over }

    /// The visible text at `t` seconds into a cycle of length `cycle` — the
    /// text's own, or a shared one when title and artist are locked together.
    func window(_ p: Plan, t: Double, cycle: Double) -> String {
        guard p.scrolls else { return String(p.text.chars) }
        let step = tuning.stepSeconds, h0 = tuning.holdStart
        let mt = p.text
        switch tuning.modeValue {
        case .loop:
            // The ring is the text, the gap, then the text again. A shared
            // cycle pads the shorter ring with blanks so both wrap together.
            let ringUse = max(p.ring, Int(((cycle - h0) / step).rounded()))
            var ring = mt.chars + p.sep
            if ringUse > ring.count { ring += Array(repeating: " ", count: ringUse - ring.count) }
            let off = t < h0 ? 0 : min(ring.count - 1, max(0, Int((t - h0) / step)))
            var used = 0, out = ""
            for k in 0..<ring.count {
                let ch = ring[(off + k) % ring.count]
                let n = measure(ch)
                if used + n > width { break }
                used += n; out.append(ch)
            }
            return out
        case .snap, .bounce:
            var off: Int
            let backStart = cycle - Double(p.over) * step
            if tuning.modeValue == .bounce, t >= backStart {
                off = p.over - 1 - Int((t - backStart) / step)
            } else if t < h0 {
                off = 0
            } else {
                off = Int((t - h0) / step)
            }
            let start = min(p.over, max(0, off))
            let edge = tuning.edgeMarks
            let leftMark = edge && start > 0
            var avail = width - (leftMark ? 1 : 0)
            let restCells = mt.cells[start...].reduce(0, +)
            let rightMark = edge && restCells > avail
            if rightMark { avail -= 1 }
            var used = 0, out = ""
            for k in start..<mt.chars.count {
                if used + mt.cells[k] > avail { break }
                used += mt.cells[k]; out.append(mt.chars[k])
            }
            return (leftMark ? "\u{2026}" : "") + out + (rightMark ? "\u{2026}" : "")
        }
    }
}

// MARK: - The panel

final class PanelView: NSView {
    var tuning = MarqueeTuning() {
        didSet {
            if tuning.fontSize != oldValue.fontSize { font = nil }
            if tuning.fieldCells != oldValue.fieldCells { artCache = nil }
        }
    }
    var title = "" { didSet { restart() } }
    var artist = "" { didSet { restart() } }
    private(set) var caption = ""

    private var t0 = CACurrentMediaTime()
    private var pausedAt: Double?
    var elapsed: Double { (pausedAt ?? CACurrentMediaTime()) - t0 }
    func restart() { t0 = CACurrentMediaTime(); if pausedAt != nil { pausedAt = t0 } }
    func setPaused(_ p: Bool) {
        if p, pausedAt == nil { pausedAt = CACurrentMediaTime() }
        else if !p, let pa = pausedAt { t0 += CACurrentMediaTime() - pa; pausedAt = nil }
    }

    override var isFlipped: Bool { true }

    // Cell metrics, as the saver computes them.
    private var font: NSFont?
    private var charW: CGFloat = 0
    private var lineH: CGFloat = 0
    private var glyphCache: [Character: (cells: Int, kern: CGFloat)] = [:]

    private func setupFont() {
        guard font == nil else { return }
        let base = CGFloat(tuning.fontSize)
        font = NSFont(name: "SFMono-Regular", size: base) ?? .monospacedSystemFont(ofSize: base, weight: .regular)
        charW = ("M" as NSString).size(withAttributes: [.font: font!]).width
        lineH = ceil(base * 1.55)
        glyphCache = [:]
        artCache = nil
    }

    private func glyph(_ ch: Character) -> (cells: Int, kern: CGFloat) {
        if ch.isASCII { return (1, 0) }
        if let g = glyphCache[ch] { return g }
        let w = NSAttributedString(string: String(ch), attributes: [.font: font!]).size().width
        let n = max(1, Int((w / charW).rounded()))
        var kern = CGFloat(n) * charW - w
        if abs(kern) < 0.05 { kern = 0 }
        let g = (cells: n, kern: kern)
        glyphCache[ch] = g
        return g
    }
    private func cells(_ s: String) -> Int { s.reduce(0) { $0 + glyph($1).cells } }

    private func run(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        if text.allSatisfy({ $0.isASCII }) { return NSAttributedString(string: text, attributes: attrs) }
        let out = NSMutableAttributedString()
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain, attributes: attrs))
            plain = ""
        }
        for ch in text {
            let g = glyph(ch)
            if g.kern == 0 { plain.append(ch); continue }
            flush()
            var a = attrs
            a[.kern] = g.kern
            out.append(NSAttributedString(string: String(ch), attributes: a))
        }
        flush()
        return out
    }

    // A stand-in cover: the ramp's own glyphs over a soft two-light field,
    // dimmed to the rest tone. Only its WIDTH matters to the roll.
    private static let ramp: [Character] = [" ", "·", "-", ":", "!", "/", "+", "=", "x", "*",
                                            "o", "X", "C", "%", "#", "D", "W", "0", "Q"]
    private var artCache: (cols: Int, rows: [NSAttributedString])?

    private func artRows(cols: Int, rows: Int) -> [NSAttributedString] {
        if let c = artCache, c.cols == cols { return c.rows }
        func hash(_ i: Int, _ j: Int) -> Double {
            let v = sin(Double(i) * 12.9898 + Double(j) * 78.233) * 43758.5453
            return v - floor(v)
        }
        var out: [NSAttributedString] = []
        for j in 0..<rows {
            let line = NSMutableAttributedString()
            for i in 0..<cols {
                let u = (Double(i) + 0.5) / Double(cols), v = (Double(j) + 0.5) / Double(rows)
                let d1 = hypot(u - 0.38, v - 0.42) / 0.5, d2 = hypot(u - 0.72, v - 0.70) / 0.45
                let b = max(0, 1 - d1) * 0.7 + max(0, 1 - d2) * 0.5
                let tone = min(1, 0.10 + 0.6 * b)
                let steps = Double(Self.ramp.count)
                let idx = Int(min(steps - 1, max(0, floor(tone * steps + hash(i, j) - 0.5))))
                let cool: [Double] = [0.44, 0.52, 0.64], warm: [Double] = [0.80, 0.50, 0.38]
                let k = (0.35 + 0.65 * tone) * 0.62
                let c = NSColor(deviceRed: (cool[0] + (warm[0] - cool[0]) * u) * k,
                                green: (cool[1] + (warm[1] - cool[1]) * u) * k,
                                blue: (cool[2] + (warm[2] - cool[2]) * u) * k, alpha: 1)
                line.append(NSAttributedString(string: String(Self.ramp[idx]),
                                               attributes: [.font: font!, .foregroundColor: c]))
            }
            out.append(line)
        }
        artCache = (cols, out)
        return out
    }

    private struct Row { var runs: [(String, [NSAttributedString.Key: Any])] }

    override func draw(_ dirty: NSRect) {
        setupFont()
        NSColor(white: 0.05, alpha: 1).setFill()
        bounds.fill()

        let field = tuning.fieldCells
        let inner = field + 3
        let engine = MarqueeEngine(tuning: tuning, width: field) { [unowned self] in self.glyph($0).cells }
        let pt = engine.plan(title), pa = engine.plan(artist)
        let ct = engine.ownCycle(pt), ca = engine.ownCycle(pa)
        let e = elapsed
        let shared = max(ct, ca)
        func tIn(_ c: Double) -> Double { c > 0 ? e.truncatingRemainder(dividingBy: c) : 0 }
        let titleS: String, artistS: String
        if tuning.sync {
            titleS = engine.window(pt, t: tIn(shared), cycle: shared)
            artistS = engine.window(pa, t: tIn(shared), cycle: shared)
        } else {
            titleS = engine.window(pt, t: tIn(ct), cycle: ct)
            artistS = engine.window(pa, t: tIn(ca), cycle: ca)
        }

        let base = font!
        let railC = NSColor(white: 0.26, alpha: 1)
        let labelC = NSColor(deviceRed: 0.31, green: 0.35, blue: 0.39, alpha: 1)
        let titleC = NSColor(deviceRed: 0.58, green: 0.65, blue: 0.72, alpha: 1)
        let cursorC = NSColor(deviceRed: 0.66, green: 0.90, blue: 1.0, alpha: 1)
        func a(_ c: NSColor) -> [NSAttributedString.Key: Any] { [.font: base, .foregroundColor: c] }
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: max(0, n)) }

        let head = "\u{266A} now playing"
        let topFill = max(0, inner - cells(head) - 4)
        let top = Row(runs: [("\u{256D}\u{2500} ", a(railC)), (head, a(labelC)),
                             (" " + rep("\u{2500}", topFill) + "\u{256E}", a(railC))])
        func padRow(_ text: String, _ c: NSColor) -> Row {
            let fill = max(0, inner - cells(text) - 3)
            return Row(runs: [("\u{2502} ", a(railC)), (text, a(c)),
                              (rep(" ", fill) + " \u{2502}", a(railC))])
        }
        var rows = [top, padRow(titleS, titleC), padRow(artistS, NSColor(white: 0.40, alpha: 1))]

        // The art box: cols = the field, rows from the 1:1 lock; its height is
        // reserved by blank rail rows and the cover drawn over them.
        let artCols = field, artRowsN = max(4, field / 2)
        let stepA = charW * 2
        let artH = stepA * CGFloat(artRowsN) + 4
        let blank = max(1, Int((artH / lineH).rounded(.up)))
        for _ in 0..<blank { rows.append(padRow("", titleC)) }

        let dur = 251.0
        let pos = e.truncatingRemainder(dividingBy: dur)
        func ms(_ v: Double) -> String { let s = max(0, Int(v)); return "\(s / 60):" + String(format: "%02d", s % 60) }
        let posS = ms(pos), durS = ms(dur)
        let barW = max(6, inner - posS.count - durS.count - 5)
        let mark = min(barW - 1, max(0, Int(Double(barW) * pos / dur)))
        rows.append(Row(runs: [
            ("\u{2502} ", a(railC)),
            (posS + " ", a(NSColor(white: 0.40, alpha: 1))),
            (rep("\u{2500}", mark), a(NSColor(white: 0.30, alpha: 1))),
            ("\u{25CF}", a(cursorC)),
            (rep("\u{2500}", barW - mark - 1), a(NSColor(white: 0.22, alpha: 1))),
            (" " + durS, a(NSColor(white: 0.40, alpha: 1))),
            (" \u{2502}", a(railC)),
        ]))
        let bl = "Music.app"
        rows.append(Row(runs: [("\u{2570}" + rep("\u{2500}", max(0, inner - bl.count - 4)) + " ", a(railC)),
                               (bl, a(labelC)), (" \u{2500}\u{256F}", a(railC))]))

        var width: CGFloat = 0
        let built: [NSAttributedString] = rows.map { row in
            let line = NSMutableAttributedString()
            for (t, at) in row.runs { line.append(run(t, at)) }
            width = max(width, line.size().width)
            return line
        }
        let pad: CGFloat = 6
        let plate = NSSize(width: width + pad * 2, height: lineH * CGFloat(built.count) + pad * 2)
        let px = bounds.width - 28 - plate.width
        let py = bounds.height - lineH * 1.2 - plate.height
        NSColor.black.withAlphaComponent(0.87).setFill()
        NSBezierPath(roundedRect: NSRect(origin: NSPoint(x: px, y: py), size: plate),
                     xRadius: 3, yRadius: 3).fill()
        var y = py + pad
        for (i, line) in built.enumerated() {
            line.draw(at: NSPoint(x: px + pad, y: y))
            y += lineH
            if i == 2 {
                let totalCells = Int((width / charW).rounded())
                let lead = CGFloat(max(1, (totalCells - artCols) / 2))
                let ox = px + pad + lead * charW
                for (r, row) in artRows(cols: artCols, rows: artRowsN).enumerated() {
                    row.draw(at: NSPoint(x: ox, y: y + CGFloat(r) * stepA))
                }
            }
        }

        // Caption: what the roll is doing, in numbers.
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
        func desc(_ p: MarqueeEngine.Plan, _ c: Double) -> String {
            p.scrolls ? "\(engine.steps(p)) steps, cycle \(fmt(c)) s" : "fits"
        }
        var cap = "\(tuning.modeValue.label) \u{00B7} \(String(format: "%.2f", tuning.stepSeconds)) s/glyph"
        cap += " \u{00B7} hold \(fmt(tuning.holdStart)) s"
        if tuning.modeValue != .loop { cap += " / \(fmt(tuning.holdEnd)) s" }
        cap += " \u{00B7} field \(field) cells"
        cap += "\ntitle: \(desc(pt, ct))    artist: \(desc(pa, ca))"
        if tuning.sync, shared > 0 { cap += "    shared cycle \(fmt(shared)) s" }
        cap += "\nt = \(fmt(e)) s" + (pausedAt != nil ? "  (paused)" : "")
        caption = cap
        let capFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        NSAttributedString(string: cap, attributes: [.font: capFont,
                                                     .foregroundColor: NSColor(white: 0.42, alpha: 1)])
            .draw(at: NSPoint(x: 16, y: 14))
    }
}

// MARK: - The window

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    static var shared: AppDelegate!
    static func main() {
        let app = NSApplication.shared
        shared = AppDelegate()
        app.delegate = shared
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var window: NSWindow!
    private let panel = PanelView()
    private var tuning = MarqueeTuning()
    private var titleField: NSTextField!
    private var artistField: NSTextField!
    private var presetPop: NSPopUpButton!
    private var modeCtl: NSSegmentedControl!
    private var sepPop: NSPopUpButton!
    private var sliders: [String: NSSlider] = [:]
    private var values: [String: NSTextField] = [:]
    private var knobLabels: [String: NSTextField] = [:]
    private var edgeBox: NSButton!
    private var syncBox: NSButton!
    private var pauseBox: NSButton!
    private var status: NSTextField!
    private var timer: Timer?

    private static let presets: [(String, String)] = [
        ("Bohemian Rhapsody (Remastered 2011)", "Queen"),
        ("Everything In Its Right Place - Live at the Roundhouse, London, 2016", "Radiohead"),
        ("SICKO MODE", "Travis Scott feat. Drake, Big Hawk & Swae Lee"),
        ("Symphony No. 9 in D Minor, Op. 125 \"Choral\": IV. Presto - Allegro assai",
         "Berliner Philharmoniker, Herbert von Karajan, Wiener Singverein"),
        ("\u{591C}\u{306B}\u{99C6}\u{3051}\u{308B} (Yoru ni Kakeru) - From THE BOOK", "YOASOBI"),
        ("Kill Bill (feat. Doja Cat) [Remix] \u{1F3B5}", "SZA"),
        ("Short", "Fits the field"),
    ]

    private struct Knob {
        let key: String, label: String, min: Double, max: Double, integer: Bool, fmt: String
    }
    private static let knobs: [Knob] = [
        Knob(key: "stepSeconds", label: "step per glyph", min: 0.05, max: 0.60, integer: false, fmt: "%.2f s"),
        Knob(key: "holdStart", label: "hold at start", min: 0, max: 4, integer: false, fmt: "%.1f s"),
        Knob(key: "holdEnd", label: "hold at end", min: 0, max: 4, integer: false, fmt: "%.1f s"),
        Knob(key: "loopGap", label: "loop gap", min: 1, max: 12, integer: true, fmt: "%.0f cells"),
        Knob(key: "fieldCells", label: "field width", min: 16, max: 60, integer: true, fmt: "%.0f cells"),
        Knob(key: "fontSize", label: "font", min: 11.5, max: 16.5, integer: false, fmt: "%.1f pt"),
    ]

    private static let fileURL: URL = {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("marquee-tuning.json")
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        if let d = try? Data(contentsOf: Self.fileURL),
           let t = try? JSONDecoder().decode(MarqueeTuning.self, from: d) {
            tuning = t
        }
        buildMenu()
        buildWindow()
        let p = Self.presets[0]
        titleField.stringValue = p.0
        artistField.stringValue = p.1
        panel.title = p.0
        panel.artist = p.1
        apply()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.panel.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Marquee Tuner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func mono(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 11,
                      bold: Bool = false, in parent: NSView) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        l.frame = NSRect(x: x, y: y, width: w, height: 18)
        l.textColor = NSColor(white: 0.80, alpha: 1)
        parent.addSubview(l)
        return l
    }

    private func buildWindow() {
        let W: CGFloat = 1100, H: CGFloat = 660
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "CodeSaver \u{2014} title roll"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        w.contentView = content

        panel.frame = NSRect(x: 0, y: 0, width: 660, height: H)
        content.addSubview(panel)

        let x0: CGFloat = 684, cw: CGFloat = 396
        var top: CGFloat = 22
        func place(_ v: NSView, x: CGFloat, w: CGFloat, h: CGFloat) {
            v.frame = NSRect(x: x, y: H - top - h, width: w, height: h)
            content.addSubview(v)
        }

        // Text
        _ = mono("title", x: x0, y: H - top - 18, w: 60, in: content)
        titleField = NSTextField(string: "")
        titleField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        titleField.delegate = self
        place(titleField, x: x0 + 60, w: cw - 60, h: 22)
        top += 30
        _ = mono("artist", x: x0, y: H - top - 18, w: 60, in: content)
        artistField = NSTextField(string: "")
        artistField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        artistField.delegate = self
        place(artistField, x: x0 + 60, w: cw - 60, h: 22)
        top += 30
        _ = mono("preset", x: x0, y: H - top - 18, w: 60, in: content)
        presetPop = NSPopUpButton(frame: .zero, pullsDown: false)
        presetPop.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for p in Self.presets {
            let t = p.0.count > 34 ? String(p.0.prefix(33)) + "\u{2026}" : p.0
            presetPop.addItem(withTitle: "\(t) \u{2014} \(p.1)")
        }
        presetPop.target = self
        presetPop.action = #selector(presetPicked(_:))
        place(presetPop, x: x0 + 60, w: cw - 60, h: 24)
        top += 40

        // Mode
        _ = mono("mode", x: x0, y: H - top - 18, w: 60, in: content)
        modeCtl = NSSegmentedControl(labels: MarqueeMode.allCases.map(\.label),
                                     trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeCtl.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        place(modeCtl, x: x0 + 60, w: cw - 60, h: 24)
        top += 36

        // Knobs
        for k in Self.knobs {
            let l = mono(k.label, x: x0, y: H - top - 18, w: 120, in: content)
            knobLabels[k.key] = l
            let s = NSSlider(value: k.min, minValue: k.min, maxValue: k.max,
                             target: self, action: #selector(knobMoved(_:)))
            s.isContinuous = true
            s.identifier = NSUserInterfaceItemIdentifier(k.key)
            if k.integer {
                s.numberOfTickMarks = Int(k.max - k.min) + 1
                s.allowsTickMarkValuesOnly = true
            }
            place(s, x: x0 + 124, w: 190, h: 20)
            sliders[k.key] = s
            let v = mono("", x: x0 + 322, y: H - top - 18, w: 74, bold: true, in: content)
            v.alignment = .right
            values[k.key] = v
            if k.key == "loopGap" {
                top += 28
                _ = mono("separator", x: x0, y: H - top - 18, w: 120, in: content)
                sepPop = NSPopUpButton(frame: .zero, pullsDown: false)
                sepPop.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                sepPop.addItems(withTitles: ["spaces", "\u{2219}", "\u{2500}"])
                sepPop.target = self
                sepPop.action = #selector(sepChanged(_:))
                place(sepPop, x: x0 + 124, w: 120, h: 24)
            }
            top += 30
        }
        top += 6

        // Switches
        edgeBox = NSButton(checkboxWithTitle: "\u{2026} on the edge where text continues",
                           target: self, action: #selector(toggled(_:)))
        edgeBox.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        place(edgeBox, x: x0, w: cw, h: 20)
        top += 26
        syncBox = NSButton(checkboxWithTitle: "title and artist share one cycle",
                           target: self, action: #selector(toggled(_:)))
        syncBox.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        place(syncBox, x: x0, w: cw, h: 20)
        top += 26
        pauseBox = NSButton(checkboxWithTitle: "pause", target: self, action: #selector(toggled(_:)))
        pauseBox.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        place(pauseBox, x: x0, w: 120, h: 20)
        let restart = NSButton(title: "restart cycle", target: self, action: #selector(restartTapped(_:)))
        restart.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        restart.bezelStyle = .rounded
        place(restart, x: x0 + 124, w: 130, h: 24)
        top += 40

        // Actions
        let reset = NSButton(title: "reset to saver", target: self, action: #selector(resetTapped(_:)))
        reset.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reset.bezelStyle = .rounded
        place(reset, x: x0, w: 130, h: 24)
        let copy = NSButton(title: "copy JSON", target: self, action: #selector(copyTapped(_:)))
        copy.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        copy.bezelStyle = .rounded
        place(copy, x: x0 + 140, w: 110, h: 24)
        top += 36

        status = NSTextField(wrappingLabelWithString: "")
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.textColor = NSColor(white: 0.55, alpha: 1)
        status.isSelectable = true
        place(status, x: x0, w: cw, h: H - top - 16)

        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    // MARK: State → controls, file

    private func value(_ key: String) -> Double {
        switch key {
        case "stepSeconds": return tuning.stepSeconds
        case "holdStart": return tuning.holdStart
        case "holdEnd": return tuning.holdEnd
        case "loopGap": return Double(tuning.loopGap)
        case "fieldCells": return Double(tuning.fieldCells)
        case "fontSize": return tuning.fontSize
        default: return 0
        }
    }
    private func set(_ key: String, _ v: Double) {
        switch key {
        case "stepSeconds": tuning.stepSeconds = (v * 100).rounded() / 100
        case "holdStart": tuning.holdStart = (v * 10).rounded() / 10
        case "holdEnd": tuning.holdEnd = (v * 10).rounded() / 10
        case "loopGap": tuning.loopGap = Int(v.rounded())
        case "fieldCells": tuning.fieldCells = Int(v.rounded())
        case "fontSize": tuning.fontSize = (v * 10).rounded() / 10
        default: break
        }
    }

    private func apply() {
        let mode = tuning.modeValue
        modeCtl.selectedSegment = MarqueeMode.allCases.firstIndex(of: mode) ?? 0
        for k in Self.knobs {
            let v = value(k.key)
            sliders[k.key]?.doubleValue = v
            values[k.key]?.stringValue = String(format: k.fmt, v)
            let on: Bool
            switch k.key {
            case "loopGap": on = mode == .loop
            case "holdEnd": on = mode != .loop
            default: on = true
            }
            sliders[k.key]?.isEnabled = on
            values[k.key]?.textColor = NSColor(white: on ? 0.90 : 0.40, alpha: 1)
            knobLabels[k.key]?.textColor = NSColor(white: on ? 0.80 : 0.40, alpha: 1)
        }
        sepPop.isEnabled = mode == .loop
        sepPop.selectItem(withTitle: tuning.separator)
        if sepPop.indexOfSelectedItem < 0 { sepPop.selectItem(at: 0) }
        edgeBox.state = tuning.edgeMarks ? .on : .off
        edgeBox.isEnabled = mode != .loop
        syncBox.state = tuning.sync ? .on : .off
        panel.tuning = tuning
        panel.needsDisplay = true
        save()
    }

    private func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(tuning)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func save() {
        try? json().write(to: Self.fileURL, atomically: true, encoding: .utf8)
        status.stringValue = "saved \u{2192} \(Self.fileURL.path)\n\n" + json()
    }

    // MARK: Actions

    @objc private func knobMoved(_ s: NSSlider) {
        guard let key = s.identifier?.rawValue else { return }
        set(key, s.doubleValue)
        apply()
    }
    @objc private func modeChanged(_ c: NSSegmentedControl) {
        tuning.mode = MarqueeMode.allCases[c.selectedSegment].rawValue
        panel.restart()
        apply()
    }
    @objc private func sepChanged(_ p: NSPopUpButton) {
        tuning.separator = p.titleOfSelectedItem ?? "spaces"
        apply()
    }
    @objc private func toggled(_ b: NSButton) {
        if b === edgeBox { tuning.edgeMarks = b.state == .on }
        if b === syncBox { tuning.sync = b.state == .on; panel.restart() }
        if b === pauseBox { panel.setPaused(b.state == .on); return }
        apply()
    }
    @objc private func presetPicked(_ p: NSPopUpButton) {
        let i = max(0, min(Self.presets.count - 1, p.indexOfSelectedItem))
        titleField.stringValue = Self.presets[i].0
        artistField.stringValue = Self.presets[i].1
        panel.title = Self.presets[i].0
        panel.artist = Self.presets[i].1
    }
    @objc private func restartTapped(_ b: NSButton) { panel.restart() }
    @objc private func resetTapped(_ b: NSButton) {
        tuning = MarqueeTuning()
        panel.restart()
        apply()
    }
    @objc private func copyTapped(_ b: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json(), forType: .string)
        status.stringValue = "copied to the clipboard\n\n" + json()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === titleField { panel.title = f.stringValue }
        if f === artistField { panel.artist = f.stringValue }
    }
}
