//
//  ContentView.swift
//  CodeSaver
//
//  The host app window: a live render of the saver on top, a four-step
//  setup checklist below (the fourth, live widgets, is optional), corpus
//  status at the bottom. The palette and the
//  ✽/✻ glyph vocabulary are the saver's own (CodeSaverView's constants): the
//  current setup step glows like a working spinner, finished steps rest grey.
//

import SwiftUI
import UniformTypeIdentifiers

private let logger = AppexLog.logger("HostApp")

/// The igniter LaunchAgent's defaults domain — the app writes hot-corner and
/// idle-trigger config there; the agent re-reads it within seconds.
private let igniterDefaults = UserDefaults(suiteName: "com.michelg10.CodeSaver.Igniter")

enum Theme {
    static let ink = Color(red: 0.93, green: 0.98, blue: 1.0)
    static let slate = Color(red: 0.58, green: 0.65, blue: 0.72)
    static let dim = Color.white.opacity(0.30)
    static let violet = Color(.displayP3, red: 0.494, green: 0.357, blue: 0.937)
    static let violetHot = Color(.displayP3, red: 0.75, green: 0.64, blue: 1.0)
    static let hairline = Color.white.opacity(0.08)
    static let alert = Color(red: 0.94, green: 0.45, blue: 0.45)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The saver itself, live at half scale — the hero is the product, not a mockup.
private struct HeroSaver: NSViewRepresentable {
    final class Host: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scaleUnitSquare(to: NSSize(width: 0.5, height: 0.5))
            if let saver = CodeSaverView(frame: NSRect(x: 0, y: 0, width: 960, height: 460),
                                         isPreview: false) {
                saver.autoresizingMask = [.width, .height]
                addSubview(saver)
            }
        }
        required init?(coder: NSCoder) { nil }
    }

    func makeNSView(context: Context) -> NSView { Host(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pluginManager = PluginManager()
    @StateObject private var refreshManager = RefreshManager()
    @State private var pastedToken = ""
    @State private var showAdvanced = false
    @State private var showVerbsImporter = false
    @State private var albumArtStyle: String = ContentView.loadAlbumArtStyle()
    @State private var igniterState = IgniterState.missing
    @State private var igniterDenied = false
    @State private var cornerTL = igniterDefaults?.integer(forKey: "cornerTL") ?? 0
    @State private var cornerTR = igniterDefaults?.integer(forKey: "cornerTR") ?? 0
    @State private var cornerBL = igniterDefaults?.integer(forKey: "cornerBL") ?? 0
    @State private var cornerBR = igniterDefaults?.integer(forKey: "cornerBR") ?? 0
    @State private var idleTimeout = igniterDefaults?.integer(forKey: "idleTimeout") ?? 0

    var body: some View {
        VStack(spacing: 0) {
            hero
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                eyebrow("SETUP")
                setupRows
                Rectangle().fill(Theme.hairline).frame(height: 1)
                eyebrow("CORPUS")
                corpusRow
                Rectangle().fill(Theme.hairline).frame(height: 1)
                eyebrow("IGNITION")
                ignitionRows
                if let error = firstError {
                    Text(error)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.alert)
                        .textSelection(.enabled)
                }
                advanced
            }
            .padding(22)
        }
        .frame(width: 480)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(Theme.violet)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            pluginManager.checkInstallationStatus()
            pluginManager.checkScreensaverStatus()
            refreshManager.reload()
            igniterState = Self.probeIgniter()
            igniterDenied = Self.igniterScreenRecordingDenied()
            albumArtStyle = Self.loadAlbumArtStyle()
        }
        // The tuning window writes the same key (picking a style there
        // selects it); re-read rather than show a value seeded at init.
        .onReceive(NotificationCenter.default.publisher(
            for: .albumArtStyleDidChange)) { _ in
            albumArtStyle = Self.loadAlbumArtStyle()
        }
        .onAppear {
            igniterState = Self.probeIgniter()
            igniterDenied = Self.igniterScreenRecordingDenied()
        }
        .fileImporter(isPresented: $showVerbsImporter,
                      allowedContentTypes: [.text, .tabSeparatedText]) { result in
            if case .success(let url) = result {
                refreshManager.importVerbs(from: url)
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroSaver()
            .frame(width: 480, height: 220)
            .clipped()
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)  // bleed under the hidden title bar
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline) {
                    Text("✽ CodeSaver")
                        .font(Theme.mono(16, .semibold))
                        .foregroundStyle(Theme.ink)
                        .shadow(color: Theme.violet.opacity(0.9), radius: 8)
                    Spacer()
                    Text(extensionStatusLine)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.slate)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
    }

    private var extensionStatusLine: String {
        if pluginManager.isInstalled {
            let version = pluginManager.installedVersion.map { " v\($0)" } ?? ""
            return "appex\(version) registered"
        }
        return "appex not registered yet"
    }

    // MARK: Setup checklist

    private enum StepState { case done, current, pending }

    private var saverDone: Bool { pluginManager.isActiveScreensaver }
    private var tokenDone: Bool { refreshManager.hasToken }
    private var agentDone: Bool { refreshManager.agentEnabled }
    private var feedsDone: Bool { refreshManager.feedsEnabled }

    /// The glowing step is the next one to do — the optional fourth included,
    /// once the three that make the saver work are done.
    private var currentStep: Int? {
        if !saverDone { return 0 }
        if !tokenDone { return 1 }
        if !agentDone { return 2 }
        if !feedsDone { return 3 }
        return nil
    }

    private func state(of index: Int, done: Bool) -> StepState {
        done ? .done : (currentStep == index ? .current : .pending)
    }

    @ViewBuilder
    private func glyph(_ state: StepState) -> some View {
        switch state {
        case .done:
            Text("✻").font(Theme.mono(13)).foregroundStyle(Theme.slate)
        case .current:
            Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                .shadow(color: Theme.violet.opacity(0.9), radius: 5)
        case .pending:
            Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
        }
    }

    private func stepTitle(_ text: String, _ state: StepState) -> some View {
        Text(text)
            .font(Theme.mono(13))
            .foregroundStyle(state == .pending ? Theme.dim : Theme.ink)
    }

    private var setupRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1 — the screensaver itself
            let saverState = state(of: 0, done: saverDone)
            HStack(spacing: 10) {
                glyph(saverState)
                stepTitle("Screensaver", saverState)
                Spacer()
                if saverDone {
                    Text("active").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                } else if pluginManager.isCheckingScreensaver || pluginManager.isLoading {
                    ProgressView().scaleEffect(0.5)
                } else {
                    Button("Enable") {
                        Task { await pluginManager.activate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // 2 — GitHub
            let githubState = state(of: 1, done: tokenDone)
            HStack(spacing: 10) {
                glyph(githubState)
                stepTitle("GitHub", githubState)
                Spacer()
                if tokenDone {
                    Text(refreshManager.owner.isEmpty ? "connected" : "connected · \(refreshManager.owner)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                }
            }
            if !tokenDone {
                HStack(spacing: 8) {
                    Button("Import from gh CLI") { refreshManager.importTokenFromGH() }
                        .buttonStyle(githubState == .current ? AnyButtonStyle(.borderedProminent)
                                                             : AnyButtonStyle(.bordered))
                        .controlSize(.small)
                    SecureField("or paste a token…", text: $pastedToken)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(11))
                        .onSubmit {
                            refreshManager.saveToken(pastedToken)
                            pastedToken = ""
                        }
                }
                .padding(.leading, 24)
            }

            // 3 — the refresh agent
            let agentState = state(of: 2, done: agentDone)
            HStack(spacing: 10) {
                glyph(agentState)
                stepTitle("Auto-refresh", agentState)
                Text("daily · plugged in · lowest priority")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                Spacer()
                Toggle("", isOn: Binding(get: { refreshManager.agentEnabled },
                                         set: { refreshManager.setAutoRefresh($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!tokenDone)
            }
            if refreshManager.agentNeedsApproval {
                approvalRow
            }

            // 4 — the widget feed daemon: its own LaunchAgent, its own
            // switch. Optional — the saver is whole without it — so nothing
            // gates it and nothing else turns it on.
            let feedsState = state(of: 3, done: feedsDone)
            HStack(spacing: 10) {
                glyph(feedsState)
                stepTitle("Live widgets", feedsState)
                Text("optional · Claude Code sessions · now playing")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                Spacer()
                Toggle("", isOn: Binding(get: { refreshManager.feedsEnabled },
                                         set: { refreshManager.setLiveWidgets($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if refreshManager.feedsNeedsApproval {
                approvalRow
            }
            Text(liveWidgetsCaption)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
        }
    }

    /// Both agents wait on the same Login Items approval when macOS asks.
    private var approvalRow: some View {
        HStack(spacing: 8) {
            Text("waiting for approval in Login Items")
                .font(Theme.mono(11)).foregroundStyle(Theme.alert)
            Button("Open Login Items") { refreshManager.openLoginItems() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.leading, 24)
    }

    private var liveWidgetsCaption: String {
        "sessions need Claude Code's hooks: python3 feeds/wire-settings.py — state lands in ~/.claude/codesaver/sessions"
        + "\nnow playing reads Music or Spotify; macOS asks for consent when this window opens"
        + "\nbifrocate is optional — without it the panels follow hook state alone"
    }

    // MARK: Corpus

    private var corpusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if refreshManager.isRefreshing {
                Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                    .shadow(color: Theme.violet.opacity(0.9), radius: 5)
                Text(refreshManager.progressText ?? "working…")
                    .font(Theme.mono(12)).foregroundStyle(Theme.ink)
            } else if refreshManager.state.lastSuccess != nil {
                Text("✻").font(Theme.mono(13)).foregroundStyle(Theme.slate)
                Text("\(refreshManager.state.fileCount.formatted()) files · \(refreshManager.state.repoCount) repos · \(refreshManager.corpusSizeDescription) · \(refreshManager.lastRefreshDescription)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.ink)
            } else {
                Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
                Text("no corpus yet — the first refresh builds it")
                    .font(Theme.mono(12)).foregroundStyle(Theme.slate)
            }
            Spacer()
            Button("Refresh Now") { refreshManager.refreshNow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(refreshManager.isRefreshing || !tokenDone)
        }
    }

    // MARK: Ignition
    //
    // Config for the igniter LaunchAgent (helper/install.sh) — it owns every
    // saver trigger, so the boom always opens on a fresh desktop capture. The
    // corner config int packs bit 0 = armed, bits 1–4 = required ⌘/⌥/⌃/⇧
    // (decoded by the igniter's cornerFlags); the pickers cover single
    // modifiers, combos work via `defaults write` on the same keys.

    private enum IgniterState { case missing, stopped, running }

    /// Missing = no LaunchAgent plist; stopped = bootstrapped but launchd
    /// shows no running process (the failure mode that looks exactly like
    /// "installed" from the filesystem alone).
    private static func probeIgniter() -> IgniterState {
        guard FileManager.default.fileExists(atPath: NSHomeDirectory()
            + "/Library/LaunchAgents/com.michelg10.CodeSaver.Igniter.plist") else { return .missing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/com.michelg10.CodeSaver.Igniter"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return .stopped }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        return text.contains("state = running") ? .running : .stopped
    }

    /// The igniter can't tell the app it was refused Screen Recording — TCC
    /// prompts once, at the first idle capture, while the user is away — but
    /// it logs every refusal. The last capture outcome in the log's tail
    /// decides: a denial that no capture-backed launch has followed, and
    /// less than a day old (a standing denial re-logs every ten idle
    /// minutes, so a grant fixed since goes quiet even before the next
    /// launch proves it). Runs on the probe's cadence: window activation.
    private static func igniterScreenRecordingDenied() -> Bool {
        let path = NSHomeDirectory() + "/Library/Logs/CodeSaver/igniter.log"
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let span: UInt64 = 16_384
        try? h.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? h.readToEnd() else { return false }
        // Lossy on purpose: the cut can land inside a multi-byte glyph.
        let text = String(decoding: data, as: UTF8.self)
        var lastDenial: Substring?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("capture denied — no Screen Recording permission") {
                lastDenial = line.prefix(20)      // the ISO-8601 stamp
            } else if line.contains("launching saver"), !line.contains("plain saver") {
                // Any capture-backed launch — "fresh capture", "riding the
                // approach capture", "riding it" — proves the grant; only
                // the plain-saver launches (lock screen, backoff, watchdog)
                // say nothing about it.
                lastDenial = nil
            }
        }
        guard let stamp = lastDenial,
              let when = ISO8601DateFormatter().date(from: String(stamp)) else { return false }
        return Date().timeIntervalSince(when) < 86_400
    }

    private var ignitionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if igniterState != .running {
                let (headline, command) = igniterState == .missing
                    ? ("igniter not installed — these triggers are dormant",
                       "./build.sh && ./helper/install.sh")
                    : ("igniter installed but not running — these triggers are dormant",
                       "launchctl kickstart gui/\(getuid())/com.michelg10.CodeSaver.Igniter")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.alert)
                        .shadow(color: Theme.alert.opacity(0.9), radius: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline)
                            .font(Theme.mono(12, .semibold)).foregroundStyle(Theme.alert)
                        Text("\(command) — settings below stick either way")
                            .font(Theme.mono(10)).foregroundStyle(Theme.slate)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if igniterState == .running, igniterDenied {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.alert)
                        .shadow(color: Theme.alert.opacity(0.9), radius: 5)
                    Text("no Screen Recording grant — the saver starts plain, no boom · System Settings › Privacy & Security › Screen Recording › CodeSaverIgniter")
                        .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open") { openScreenRecordingSettings() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Text("idle").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                Picker("", selection: Binding(
                    get: { idleTimeout },
                    set: { idleTimeout = $0; igniterDefaults?.set($0, forKey: "idleTimeout") })) {
                    Text("use macOS setting").tag(0)
                    Text("after 1 minute").tag(60)
                    Text("after 2 minutes").tag(120)
                    Text("after 5 minutes").tag(300)
                    Text("after 10 minutes").tag(600)
                    Text("after 15 minutes").tag(900)
                    Text("after 30 minutes").tag(1800)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("corners").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    .padding(.top, 3)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        cornerPicker("◸", "cornerTL", $cornerTL)
                        cornerPicker("◹", "cornerTR", $cornerTR)
                    }
                    GridRow {
                        cornerPicker("◺", "cornerBL", $cornerBL)
                        cornerPicker("◿", "cornerBR", $cornerBR)
                    }
                }
            }
            Text(ignitionCaption)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cornerPicker(_ glyph: String, _ key: String,
                              _ state: Binding<Int>) -> some View {
        HStack(spacing: 5) {
            Text(glyph).font(Theme.mono(11)).foregroundStyle(Theme.slate)
            Picker("", selection: Binding(
                get: { state.wrappedValue },
                set: { state.wrappedValue = $0; igniterDefaults?.set($0, forKey: key) })) {
                Text("off").tag(0)
                Text("instant").tag(1)
                Text("⌘ hold").tag(3)
                Text("⌥ hold").tag(5)
                Text("⌃ hold").tag(9)
                Text("⇧ hold").tag(17)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 108, alignment: .leading)
        }
    }

    private var ignitionCaption: String {
        let idle = idleTimeout > 0
            ? "the igniter starts the saver itself at this idle, capturing the desktop at that exact moment — set macOS's saver timeout to Never so the two don't race"
            : "macOS's own timeout starts the saver; the igniter keeps a fresh desktop capture ready for the boom"
        return idle + "\ncorners are detected by the igniter itself — leave macOS's hot corners unbound so they don't race it\na modifier corner works like macOS's: hold the key first, then drive the cursor in — pressing it with the cursor already there is ignored"
    }

    private var firstError: String? {
        refreshManager.lastActionError
            ?? refreshManager.state.lastError
            ?? pluginManager.screensaverError
            ?? pluginManager.lastError
    }

    // MARK: Album art style (shared with the saver via the group container)

    private static func artSettingsURL() -> URL? {
        CorpusStore.widgetsDirectory?.appendingPathComponent("settings.json")
    }

    static func loadAlbumArtStyle() -> String {
        guard let u = artSettingsURL(), let d = try? Data(contentsOf: u),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let s = o["albumArtStyle"] as? String else { return "none" }
        // One renderer now. A settings file still naming the retired braille
        // style reads as "on" rather than leaving the picker unselected.
        return s == "none" ? "none" : "ramp"
    }

    static func saveAlbumArtStyle(_ style: String) {
        guard let u = artSettingsURL() else { return }
        var o: [String: Any] = [:]
        if let d = try? Data(contentsOf: u),
           let e = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            o = e
        }
        o["albumArtStyle"] = style
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: the saver polls this file at 4 Hz and treats an unparseable
        // read (a truncate-then-write caught halfway) as "art off".
        if let d = try? JSONSerialization.data(withJSONObject: o),
           (try? d.write(to: u, options: .atomic)) != nil {
            NotificationCenter.default.post(name: .albumArtStyleDidChange, object: nil)
        }
    }

    // MARK: Advanced

    // A hand-rolled disclosure. The rows keep their layout space when hidden
    // and only fade — animated window resizing is what read as jank, and on a
    // pure-black window the reserved space is invisible when collapsed.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text(showAdvanced ? "▾" : "▸")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.dim)
                    eyebrow("ADVANCED")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            advancedRows
                .padding(.top, 12)
                .opacity(showAdvanced ? 1 : 0)
                .allowsHitTesting(showAdvanced)
                .accessibilityHidden(!showAdvanced)
        }
    }

    private var advancedRows: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("repos of").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    TextField("token's account", text: $refreshManager.owner)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(11))
                        .frame(width: 170)
                        .onSubmit { refreshManager.saveOwner() }
                }
                HStack(spacing: 8) {
                    Text("verbs").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    Text(refreshManager.customVerbCount.map { "custom list (\($0))" } ?? "bundled list")
                        .font(Theme.mono(11)).foregroundStyle(Theme.ink)
                    Button("Import…") { showVerbsImporter = true }
                        .buttonStyle(.bordered).controlSize(.small)
                    if refreshManager.customVerbCount != nil {
                        Button("Use bundled") { refreshManager.resetVerbs() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    Text("album art").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    Picker("", selection: Binding(
                        get: { albumArtStyle },
                        set: { albumArtStyle = $0; ContentView.saveAlbumArtStyle($0) })) {
                        Text("off").tag("none")
                        Text("on").tag("ramp")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 140, alignment: .leading)
                    Button("Tune…") { openWindow(id: "albumart") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                HStack(spacing: 16) {
                    Button("Preview window") { openWindow(id: "preview") }
                    Button("Screen Saver settings") { openScreenSaverSettings() }
                    if tokenDone {
                        Button("Forget token") { refreshManager.forgetToken() }
                    }
                }
                .buttonStyle(.link)
                .font(Theme.mono(11))
            }
    }

    // MARK: Helpers

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .tracking(3)
            .foregroundStyle(Theme.dim)
    }

    private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Type-erased button style so a button can switch prominence with state.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let apply: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        apply = { AnyView(Button($0).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        apply(configuration)
    }
}

#Preview {
    ContentView()
}
