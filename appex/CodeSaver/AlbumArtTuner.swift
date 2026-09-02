//
//  AlbumArtTuner.swift
//  CodeSaver — the album-art tuning window (host app only).
//
//  The window IS the saver: a full-scale CodeSaverView, code rain, clock,
//  session panels and all. Art is never looked at in isolation on the glass,
//  so it isn't tuned in isolation either. The knobs live in a floating HUD
//  panel you can drag anywhere (or off the saver entirely).
//
//  Turning a knob re-renders with the SAME native renderer the daemon uses
//  and publishes the result straight into the app-group container, so the
//  saver view — and the real screensaver, if it's up — repaints within a
//  fraction of a second. `Save` then persists the values so the daemon keeps
//  using them for every future track.
//

import AppKit
import ImageIO
import SwiftUI

extension Notification.Name {
    /// Posted in-process whenever widgets/settings.json's `albumArtStyle` is
    /// rewritten — by the main window's picker or by this tuner — so every
    /// view showing the value re-reads it instead of trusting a seed taken
    /// at init. The saver polls the file; the app's own views need a nudge.
    static let albumArtStyleDidChange =
        Notification.Name("com.michelg10.CodeSaver.albumArtStyleDidChange")
}

// MARK: - Model

@MainActor
final class AlbumArtTunerModel: ObservableObject {
    @Published var style = "braille"
    @Published var ramp = AlbumArtRamp.Params()
    @Published var braille = AlbumArtBraille.Params()
    @Published var sourceLabel = "—"
    @Published var hint = ""
    @Published var renderMS = 0.0
    @Published var saved = false
    /// Album art is square; a text grid is not. Locked (the default), moving
    /// either size slider derives the other from the STYLE'S OWN cell aspect
    /// so the rendered block stays 1:1 on screen.
    @Published var lockSquare = true
    /// The app has album art switched off. The tuner still renders and
    /// publishes, but the saver draws nothing until a style is picked — say
    /// so, rather than silently switching art on for the user.
    @Published var artOff = false

    private var image: CGImage?
    /// The file `image` was decoded from — stamped into the published grid
    /// so a consumer re-rendering at another size uses the same pixels.
    private var imageURL: URL?
    /// Only an explicit pick in this window's style control may write the
    /// style back to settings.json. Loading, knob turns and the initial
    /// render must not: with art switched off in the app, the model's
    /// default style would otherwise be persisted as a side effect of merely
    /// opening the window.
    private var styleChosen = false
    /// What the preview is showing. In `.currentTrack` the artwork must be
    /// re-read when the daemon fetches a new one: publishing under the LIVE
    /// track's key while holding a stale image is how the panel ends up
    /// showing the previous track's cover.
    private enum Source { case currentTrack, file }
    private var source: Source = .currentTrack
    private var srcMTime: Date?
    private var follow: Timer?

    private var srcURL: URL? { widgets?.appendingPathComponent("albumart-src.img") }

    private func mtime(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[
            .modificationDate] as? Date
    }

    /// Cell height ÷ cell width, in the same units AlbumArtGrid draws with.
    /// Ramp cells are exactly 2:1 (rowStep = charW * 2). Braille rows are the
    /// Apple Braille line (18.8623/15 em) over SF Mono's 0.61816 em advance.
    private var cellAspect: Double {
        style == "ramp" ? 2.0 : (18.8623 / 15.0) / 0.61816
    }

    private func clamp(_ key: String, _ v: Double) -> Double {
        guard let t = tunables.first(where: { $0.key == key }) else { return v }
        return Swift.min(Swift.max(v, t.min), t.max)
    }

    private func write(_ key: String, _ v: Double) {
        if style == "ramp" { ramp[key] = v } else { braille[key] = v }
    }

    var tunables: [AlbumArtTunable] {
        style == "ramp" ? AlbumArtRamp.Params.tunables
                        : AlbumArtBraille.Params.tunables
    }

    // MARK: Lifecycle

    func start() {
        let t = AlbumArtTuning.load()
        if let r = t["ramp"] { ramp = AlbumArtRamp.Params(json: r) }
        if let b = t["braille"] { braille = AlbumArtBraille.Params(json: b) }
        if let s = try? String(contentsOf: settingsURL ?? URL(fileURLWithPath: "/dev/null")),
           let d = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let st = o["albumArtStyle"] as? String {
            if st == "none" { artOff = true } else { style = st }
        }
        loadCurrentTrack()
        // Follow the music: a track change swaps the artwork underneath us.
        follow = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    func stop() {
        follow?.invalidate()
        follow = nil
    }

    private func tick() {
        guard case .currentTrack = source, let u = srcURL,
              mtime(u) != srcMTime else { return }
        loadCurrentTrack()
    }

    // MARK: Sources

    func loadCurrentTrack() {
        source = .currentTrack
        guard let u = srcURL,
              FileManager.default.fileExists(atPath: u.path) else {
            sourceLabel = "no artwork yet"
            hint = "play something in Music so the daemon fetches artwork"
            return
        }
        load(u, label: "current track")
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { loadFile(u) }
    }

    /// An image the user chose (open panel or drop). Switch the source FIRST:
    /// `load` in `.currentTrack` mode stamps `srcMTime` from whatever it is
    /// given, which then reads as "the track's artwork changed" and `apply`
    /// swaps the chosen image straight back out for the track's.
    func loadFile(_ url: URL) {
        source = .file
        load(url)
    }

    func load(_ url: URL, label: String? = nil) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            sourceLabel = "could not decode \(url.lastPathComponent)"
            return
        }
        image = img
        imageURL = url
        if case .currentTrack = source { srcMTime = mtime(url) }
        sourceLabel = label ?? url.lastPathComponent
        apply()
    }

    /// The style control: the one place the style is a user decision rather
    /// than derived state, so the one place that may persist it.
    func selectStyle(_ s: String) {
        style = s
        styleChosen = true
        artOff = false
        apply()
    }

    // MARK: Params access

    func value(_ key: String) -> Double {
        style == "ramp" ? ramp[key] : braille[key]
    }

    func set(_ key: String, _ v: Double) {
        write(key, v)
        if lockSquare {
            if key == "cols" {
                write("rows", clamp("rows", (v / cellAspect).rounded()))
            } else if key == "rows" {
                write("cols", clamp("cols", (v * cellAspect).rounded()))
            }
        }
        saved = false
        apply()
    }

    /// Snap the current grid to 1:1 (used when the lock is switched on).
    func squareUp() {
        let cols = value("cols")
        write("rows", clamp("rows", (cols / cellAspect).rounded()))
        saved = false
        apply()
    }

    func reset() {
        if style == "ramp" { ramp = AlbumArtRamp.Params() }
        else { braille = AlbumArtBraille.Params() }
        saved = false
        apply()
    }

    func save() {
        AlbumArtTuning.save(["ramp": ramp.json, "braille": braille.json])
        saved = true
    }

    // MARK: Publish

    /// Render at the current settings and drop the result where the saver
    /// looks. The art is filed under the PLAYING track's key because that is
    /// what the panel matches on — tuning against an opened image still
    /// previews in place, it just borrows the current track's identity.
    func apply() {
        // Re-read before publishing: the key we stamp must describe the
        // pixels we render, not whatever was loaded when the window opened.
        if case .currentTrack = source, let u = srcURL, mtime(u) != srcMTime,
           let cs = CGImageSourceCreateWithURL(u as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(cs, 0, nil) {
            image = img
            srcMTime = mtime(u)
        }
        guard let image, let wdir = widgets else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        var payload: [String: Any] = ["key": currentTrackKey(),
                                      "ts": Date().timeIntervalSince1970]
        // Stamp the grid with the knobs as they are NOW and the image it came
        // from (AlbumArtGrid reads both back). The saver re-renders at a
        // smaller grid when the panel is short; without these it would use
        // the last SAVED values and the current track's artwork — so the
        // knobs would not respond until Save, and an opened image would not
        // survive the fit.
        let stamp: [String: Any] = [
            AlbumArtGrid.tuningKey: ["ramp": ramp.json, "braille": braille.json],
            AlbumArtGrid.sourceKey: imageURL?.path ?? srcURL?.path ?? "",
        ]
        if style == "ramp", let g = AlbumArtRamp.render(image, params: ramp) {
            payload["ramp"] = g.merging(stamp) { _, new in new }
        } else if style == "braille",
                  let g = AlbumArtBraille.render(image, params: braille) {
            payload["braille"] = g.merging(stamp) { _, new in new }
        }
        renderMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let dst = wdir.appendingPathComponent("albumart.json")
        let tmp = wdir.appendingPathComponent(".albumart.json.tuner")
        // Keep the other style's grid when it belongs to this same track, so
        // toggling ramp/braille doesn't strip the one you're not tuning.
        let other = style == "ramp" ? "braille" : "ramp"
        if let d = try? Data(contentsOf: dst),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           (o["key"] as? String) == (payload["key"] as? String),
           let keep = o[other] {
            payload[other] = keep
        }
        if let d = try? JSONSerialization.data(withJSONObject: payload),
           (try? d.write(to: tmp)) != nil {
            // rename(2) over the old file: the saver polls this at 4 Hz and
            // clears its grids the instant the file is missing.
            try? CorpusStore.replaceFile(at: dst, with: tmp)
        }
        if styleChosen { writeStyle() }
    }

    /// The saver only draws art for the style it is set to, so PICKING a
    /// style here selects it. Only a pick: `apply` gates this on
    /// `styleChosen`, so opening the window with art switched off in the app
    /// leaves it off.
    private func writeStyle() {
        guard let u = settingsURL else { return }
        var o: [String: Any] = [:]
        if let d = try? Data(contentsOf: u),
           let e = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { o = e }
        guard (o["albumArtStyle"] as? String) != style else { return }
        o["albumArtStyle"] = style
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              (try? d.write(to: u, options: .atomic)) != nil else { return }
        NotificationCenter.default.post(name: .albumArtStyleDidChange, object: nil)
    }

    private func currentTrackKey() -> String {
        guard let u = widgets?.appendingPathComponent("feed.json"),
              let d = try? Data(contentsOf: u),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let np = o["nowplaying"] as? [String: Any],
              let app = np["app"] as? String, let title = np["title"] as? String else {
            hint = "nothing playing — the panel only appears with music"
            return "tuner"
        }
        hint = ""
        return "\(app)|\(title)|\(np["artist"] as? String ?? "")"
    }

    private var widgets: URL? {
        CorpusStore.corpusDirectory?.appendingPathComponent("widgets", isDirectory: true)
    }
    private var settingsURL: URL? {
        widgets?.appendingPathComponent("settings.json")
    }
}

// MARK: - Window: the saver, full scale

struct AlbumArtTunerView: View {
    @StateObject private var model = AlbumArtTunerModel()
    @State private var panel: NSPanel?

    var body: some View {
        PreviewViewRepresentable()
            .ignoresSafeArea()
            .onAppear {
                model.start()
                openControls()
            }
            .onDisappear {
                model.stop()
                panel?.close()
                panel = nil
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.loadFile(url) }
                }
                return true
            }
    }

    /// A real floating panel, not an overlay card: it can be dragged clear of
    /// the art entirely, and it stays on top while the saver animates behind.
    private func openControls() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false)
        p.title = "Album art"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: AlbumArtControls(model: model))
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 360,
                                     y: screen.visibleFrame.midY - 310))
        }
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - The controls (inside the HUD panel)

private struct AlbumArtControls: View {
    @ObservedObject var model: AlbumArtTunerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(get: { model.style },
                                              set: { model.selectStyle($0) })) {
                    Text("ramp").tag("ramp")
                    Text("braille").tag("braille")
                }
                .pickerStyle(.segmented).labelsHidden()
                if model.artOff {
                    Text("album art is off in the app — pick a style above to turn it on")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Button("Current track") { model.loadCurrentTrack() }
                    Button("Image…") { model.openPanel() }
                }
                .controlSize(.small)

                Text(model.sourceLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !model.hint.isEmpty {
                    Text(model.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.self) { g in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(g.uppercased())
                                    .font(.system(size: 9, weight: .semibold,
                                                  design: .monospaced))
                                    .tracking(1.5)
                                    .foregroundStyle(.tertiary)
                                if g.lowercased() == "size" {
                                    Spacer()
                                    Toggle("1:1", isOn: Binding(
                                        get: { model.lockSquare },
                                        set: { model.lockSquare = $0
                                               if $0 { model.squareUp() } }))
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 9, design: .monospaced))
                                }
                            }
                            ForEach(model.tunables.filter { $0.group == g }, id: \.key) {
                                knob($0)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                Button("Defaults") { model.reset() }
                Spacer()
                Text(model.saved ? "saved" : String(format: "%.0f ms", model.renderMS))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(12)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for t in model.tunables where !seen.contains(t.group) { seen.append(t.group) }
        return seen
    }

    private func knob(_ t: AlbumArtTunable) -> some View {
        HStack(spacing: 6) {
            Text(t.label)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 86, alignment: .leading)
            Slider(value: Binding(get: { model.value(t.key) },
                                  set: { model.set(t.key, $0) }),
                   in: t.min...t.max)
            Text(fmt(model.value(t.key)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 10000 ? String(format: "%.0f", v)
                                           : String(format: "%.3g", v)
    }
}
