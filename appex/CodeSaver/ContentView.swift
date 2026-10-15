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

enum Theme {
    static let ink = Color(red: 0.93, green: 0.98, blue: 1.0)
    static let slate = Color(red: 0.58, green: 0.65, blue: 0.72)
    /// Captions and pending steps. 0.48 white on the black window is 4.9:1
    /// (WCAG AA asks 4.5) and still well under slate's 8.4:1, so the
    /// ink > slate > dim ladder reads the same; 0.30 was 2.5:1.
    static let dim = Color.white.opacity(0.48)
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
    @StateObject private var mover = AppMover()
    @StateObject private var updates = UpdateCheck()
    @State private var showUninstall = false
    /// The checklist's natural height, for the window's ideal and max size.
    @State private var checklistHeight: CGFloat = 760
    @State private var showAdvanced = false
    @State private var showVerbsImporter = false
    @State private var albumArtStyle: String = ContentView.loadAlbumArtStyle()

    var body: some View {
        VStack(spacing: 0) {
            hero
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // The checklist scrolls under a fixed hero: at its natural height
            // (~1000 pt) the window ran off the bottom of a 13" screen.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if let version = updates.available {
                        UpdateAvailableRow(version: version)
                    }
                    eyebrow("SETUP")
                    setupRows
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    eyebrow("YOUR CODE")
                    corpusRow
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    eyebrow("IGNITION")
                    IgnitionSection()
                    if let error = firstError {
                        Text(error)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.alert)
                            .textSelection(.enabled)
                    }
                    advanced
                }
                .padding(22)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { checklistHeight = $0 }
            }
            .scrollIndicators(.automatic)
        }
        // Resizable in height only (the app's .contentSize resizability reads
        // these): never shorter than the hero plus a few rows, never taller
        // than the content, and opening no taller than the screen it lands on.
        .frame(width: 480)
        .frame(minHeight: Self.minWindowHeight, idealHeight: idealWindowHeight,
               maxHeight: naturalWindowHeight)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(Theme.violet)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            pluginManager.refreshStatus()
            updates.checkIfDue()
            refreshManager.reload()
            albumArtStyle = Self.loadAlbumArtStyle()
        }
        // The tuning window writes the same key (picking a style there
        // selects it); re-read rather than show a value seeded at init.
        .onReceive(NotificationCenter.default.publisher(
            for: .albumArtStyleDidChange)) { _ in
            albumArtStyle = Self.loadAlbumArtStyle()
        }
        .onAppear {
            SelfRepair.runIfNeeded(plugin: pluginManager)
            updates.checkIfDue()
        }
        .sheet(isPresented: $showUninstall) {
            UninstallSheet(plugin: pluginManager, refreshing: refreshManager.isRefreshing)
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
        // The saver reads its code once, when it is made: keyed on the last
        // successful build, the hero is remade with the user's own code the
        // moment the first fetch lands (instead of typing the bundled
        // sample until the window is next opened), and after every refresh.
        HeroSaver()
            .id(refreshManager.state.lastSuccess)
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
        let version = "v" + UpdateCheck.currentVersion
        if !AppLocation.isInstalled { return "\(version) · not in Applications yet" }
        guard pluginManager.hasProbed else { return version }
        return pluginManager.isRegistered
            ? "\(version) · in Screen Saver settings"
            : "\(version) · not in Screen Saver settings yet"
    }

    // MARK: Window size

    private static let heroHeight: CGFloat = 221  // hero + hairline
    private static let minWindowHeight: CGFloat = 460

    private var naturalWindowHeight: CGFloat {
        max(Self.minWindowHeight, Self.heroHeight + checklistHeight)
    }

    /// Clear of the title bar with a little air, on whichever screen the
    /// window opens; AppKit would clamp it anyway, but not to a tidy size.
    private var idealWindowHeight: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        return max(Self.minWindowHeight, min(naturalWindowHeight, screen))
    }

    // MARK: Setup checklist

    private enum StepState {
        case done, current, pending

        /// What the glyph says, for VoiceOver: state is never glyph-only.
        var spoken: String {
            switch self {
            case .done: return "done"
            case .current: return "next step"
            case .pending: return "not yet"
            }
        }
    }

    private var saverDone: Bool { pluginManager.isEnabled }
    private var tokenDone: Bool { refreshManager.hasToken }
    private var agentDone: Bool { refreshManager.agentEnabled }
    private var feedsDone: Bool { refreshManager.feedsEnabled }

    /// The glowing step is the next one to do — the optional fourth included,
    /// once the three that make the saver work are done.
    private var currentStep: Int? {
        if !saverDone { return 0 }
        if !refreshManager.hasSource { return 1 }
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
                .accessibilityHidden(true)
        case .current:
            Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                .shadow(color: Theme.violet.opacity(0.9), radius: 5)
                .accessibilityHidden(true)
        case .pending:
            Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
                .accessibilityHidden(true)
        }
    }

    private func stepTitle(_ text: String, _ state: StepState) -> some View {
        Text(text)
            .font(Theme.mono(13))
            .foregroundStyle(state == .pending ? Theme.dim : Theme.ink)
            .accessibilityValue(state.spoken)
    }

    private var setupRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1 — the screensaver itself
            let saverState = state(of: 0, done: saverDone)
            HStack(spacing: 10) {
                glyph(saverState)
                stepTitle("Screensaver", saverState)
                Spacer()
                ScreensaverStepControl(plugin: pluginManager)
            }
            ScreensaverStepDetail(plugin: pluginManager, mover: mover)

            // 2 — GitHub (or folders on this Mac), and 3 — the refresh agent
            GitHubStep(refresh: refreshManager, isCurrent: currentStep == 1)
            AutoRefreshStep(refresh: refreshManager, isCurrent: currentStep == 2)

            // 4 — the widget feed daemon: its own LaunchAgent, its own
            // switch. Optional — the saver is whole without it — so nothing
            // gates it and nothing else turns it on. The switch, the Claude
            // Code connection and the music consent: LiveWidgetsStep.swift.
            let feedsState = state(of: 3, done: feedsDone)
            LiveWidgetsStep(refreshManager: refreshManager,
                            label: HStack(spacing: 10) { glyph(feedsState); stepTitle("Live widgets", feedsState) },
                            approval: approvalRow)
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

    // MARK: Corpus

    private var corpusRow: some View { CodeStatus(refresh: refreshManager) }

    /// The screen saver's own failures sit under its step, with their way
    /// out (ScreensaverStepDetail), and a refresh's under the code status
    /// (CodeStatus); this line is for everything else.
    private var firstError: String? {
        refreshManager.lastActionError
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
                    Picker("album art", selection: Binding(
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
                    Button("Screen Saver settings") { PluginManager.openScreenSaverSettings() }
                    if tokenDone {
                        Button("Forget token") { refreshManager.forgetToken() }
                    }
                }
                .buttonStyle(.link)
                .font(Theme.mono(11))
                LifecycleAdvancedRows(plugin: pluginManager, updates: updates) {
                    showUninstall = true
                }
            }
    }

    // MARK: Helpers

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .tracking(3)
            .foregroundStyle(Theme.dim)
    }
}

#Preview {
    ContentView()
}
