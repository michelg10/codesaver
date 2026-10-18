//
//  IgnitionSection.swift
//  CodeSaver
//
//  The host app's Ignition section: one switch for the embedded igniter
//  (IgniterService), then the triggers it owns — an idle timeout of its own
//  and four hot corners, each optionally behind ⌘/⌥/⌃/⇧ — written straight
//  into the agent's defaults domain, which it re-reads within seconds.
//  Optional and off by default; the saver is whole without it. Nothing here
//  goes red: the only states are off, on, and "one more step" — Login Items
//  approval or Screen Recording — each with the button that takes it.
//

import SwiftUI
import ServiceManagement

@MainActor
final class IgnitionModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// The agent's own Screen Recording grant as it last published it; nil
    /// until it has run once.
    @Published private(set) var screenRecording: Bool?
    @Published private(set) var corners: [String: Int] = [:]
    @Published private(set) var idleTimeout = 0
    /// A standalone igniter is being retired for the embedded one.
    @Published private(set) var migrating = false
    /// A standalone igniter is installed and can't be taken over yet (the
    /// app isn't in /Applications).
    @Published private(set) var legacyWaiting = false
    /// One calm line after an action that couldn't complete.
    @Published private(set) var note: String?

    var isOn: Bool { IgniterService.isOn(status) }

    /// Per process, not per view: the window can be closed and reopened.
    private static var migrationStarted = false

    init() {
        reload()
        migrateLegacy()
    }

    func reload() {
        status = IgniterService.status
        screenRecording = IgniterService.screenRecordingGranted
        legacyWaiting = !migrating && IgniterService.legacyInstalled
        let d = IgniterService.defaults
        corners = Dictionary(uniqueKeysWithValues: IgniterService.cornerKeys.map {
            ($0, d?.integer(forKey: $0) ?? 0)
        })
        idleTimeout = d?.integer(forKey: IgniterService.idleTimeoutKey) ?? 0
    }

    func refreshGrant() {
        screenRecording = IgniterService.screenRecordingGranted
    }

    /// Automatic, once, on launch: the window's first appearance is the
    /// launch. A user of the old standalone igniter opens the new app and
    /// finds Ignition on, same grant, same corners — and a user whose
    /// registration went missing finds it back.
    private func migrateLegacy() {
        guard !Self.migrationStarted, IgniterService.isAtStablePath else { return }
        Self.migrationStarted = true
        let legacy = IgniterService.legacyInstalled
        migrating = legacy
        legacyWaiting = false
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                legacy ? IgniterService.migrateLegacy() : IgniterService.restoreIfWanted()
            }.value
            migrating = false
            reload()
            if legacy, let status, !IgniterService.isOn(status) {
                note = "the old igniter is still running — CodeSaver will take it over next time it opens"
            }
        }
    }

    func setOn(_ on: Bool) {
        note = nil
        guard on else {
            IgniterService.wanted = false
            IgniterService.disable()
            reload()
            return
        }
        guard IgniterService.isAtStablePath else {
            note = "move CodeSaver to /Applications first — ignition runs from there"
            return
        }
        IgniterService.wanted = true
        status = IgniterService.enable()
        if !isOn {
            note = "macOS didn't start it (\(RefreshAgent.describe(status))) — try the switch again"
        }
        // The agent asks for Screen Recording and publishes the answer on
        // its first tick; look again once it has had the chance.
        Task {
            try? await Task.sleep(for: .seconds(2))
            reload()
        }
    }

    func corner(_ key: String) -> Int { corners[key] ?? 0 }

    func setCorner(_ key: String, _ raw: Int) {
        corners[key] = raw
        IgniterService.defaults?.set(raw, forKey: key)
    }

    func setIdleTimeout(_ seconds: Int) {
        idleTimeout = seconds
        IgniterService.defaults?.set(seconds, forKey: IgniterService.idleTimeoutKey)
    }
}

struct IgnitionSection: View {
    @StateObject private var model = IgnitionModel()

    private struct Corner {
        let key: String, glyph: String, name: String
    }

    private static let cornerLayout: [[Corner]] = [
        [Corner(key: "cornerTL", glyph: "◸", name: "top-left"),
         Corner(key: "cornerTR", glyph: "◹", name: "top-right")],
        [Corner(key: "cornerBL", glyph: "◺", name: "bottom-left"),
         Corner(key: "cornerBR", glyph: "◿", name: "bottom-right")],
    ]

    private struct Modifier {
        let glyph: String, name: String, bit: Int
    }

    /// Bits 1–4 of a corner int, in the order macOS's own menus list them.
    private static let modifiers = [
        Modifier(glyph: "⌘", name: "Command", bit: 2), Modifier(glyph: "⌥", name: "Option", bit: 4),
        Modifier(glyph: "⌃", name: "Control", bit: 8), Modifier(glyph: "⇧", name: "Shift", bit: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switchRow
            Text("after ~20 s idle it takes one screenshot of each display so the saver can open by blowing up your actual desktop — the screenshots never leave this Mac, are deleted the moment you're back, and nothing runs while this is off")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            if let step = nextStep {
                stepRow(step)
            }
            triggers
                .disabled(!model.isOn)
                .opacity(model.isOn ? 1 : 0.4)
                .accessibilityHint(model.isOn ? "" : "Turn on ignition to use these")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
        // While on without a confirmed grant, look every few seconds the
        // window is in front: the answer is given in System Settings, and
        // the agent re-checks its own grant every 10 s.
        .task(id: model.isOn) {
            while model.isOn, model.screenRecording != true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if NSApp.isActive { model.refreshGrant() }
            }
        }
    }

    // MARK: Switch

    private var switchRow: some View {
        HStack(spacing: 10) {
            if model.isOn {
                Text("✻").font(Theme.mono(13)).foregroundStyle(Theme.slate)
            } else {
                Text("·").font(Theme.mono(13)).foregroundStyle(Theme.dim)
            }
            Text("Open on your desktop")
                .font(Theme.mono(13))
                .foregroundStyle(model.isOn ? Theme.ink : Theme.slate)
            Text("optional")
                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
            Spacer()
            Toggle("Ignition: open the saver on a screenshot of your desktop",
                   isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(model.migrating)
        }
    }

    // MARK: One more step

    private struct Step {
        let text: String
        var button: (title: String, action: () -> Void)?
    }

    /// At most one line, in the order they block: a takeover in progress,
    /// Login Items approval, the Screen Recording grant, an action's note.
    private var nextStep: Step? {
        if model.migrating {
            return Step(text: "moving your separately installed igniter into CodeSaver…")
        }
        if model.status == .requiresApproval {
            return Step(text: "waiting for your OK in Login Items",
                        button: ("Open Login Items", { SMAppService.openSystemSettingsLoginItems() }))
        }
        if model.status == .enabled, model.screenRecording == false {
            return Step(text: "turn on “CodeSaver Igniter” under Privacy & Security › \(Self.screenRecordingPane) — until then the saver opens without your desktop",
                        button: ("Open Screen Recording settings", Self.openScreenRecordingSettings))
        }
        if let note = model.note {
            return Step(text: note)
        }
        if model.legacyWaiting {
            return Step(text: "an older, separately installed igniter is still in place — CodeSaver takes it over once it lives in /Applications")
        }
        return nil
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("✽").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                .shadow(color: Theme.violet.opacity(0.9), radius: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.text)
                    .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                if let button = step.button {
                    Button(button.title, action: button.action)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    /// The pane's name as System Settings shows it on this macOS.
    private static var screenRecordingPane: String {
        if #available(macOS 15, *) { return "Screen & System Audio Recording" }
        return "Screen Recording"
    }

    private static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Triggers

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("idle").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                Picker("Start the saver after this much idle time",
                       selection: Binding(get: { model.idleTimeout },
                                          set: { model.setIdleTimeout($0) })) {
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
                    .padding(.top, 2)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Self.cornerLayout.indices, id: \.self) { row in
                        GridRow {
                            ForEach(Self.cornerLayout[row], id: \.key) { cornerControl($0) }
                        }
                    }
                }
            }
            Text(caption)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One corner as a row of character cells: the corner glyph arms it,
    /// the four keys after it are required held first. Reverse video = on.
    /// Picking a key arms the corner too; disarming keeps the keys, so the
    /// corner comes back as it was.
    private func cornerControl(_ c: Corner) -> some View {
        let raw = model.corner(c.key)
        let armed = raw & IgniterService.armedBit != 0
        return HStack(spacing: 3) {
            Toggle(isOn: Binding(
                get: { armed },
                set: { model.setCorner(c.key, $0 ? raw | IgniterService.armedBit
                                                 : raw & ~IgniterService.armedBit) })) {
                Text(c.glyph)
            }
            .toggleStyle(CellToggleStyle())
            .accessibilityLabel("\(c.name) corner starts the saver")
            .help("\(c.name) corner starts the saver")
            Spacer().frame(width: 3)
            ForEach(Self.modifiers, id: \.bit) { m in
                Toggle(isOn: Binding(
                    get: { raw & m.bit != 0 },
                    set: { model.setCorner(c.key, $0 ? raw | m.bit | IgniterService.armedBit
                                                     : raw & ~m.bit) })) {
                    Text(m.glyph)
                }
                .toggleStyle(CellToggleStyle())
                .opacity(armed ? 1 : 0.5)
                .accessibilityLabel("\(c.name) corner: hold \(m.name) first")
                .help("hold \(m.glyph) first, then push the cursor into the \(c.name) corner")
            }
        }
    }

    private var caption: String {
        let idle = model.idleTimeout > 0
            ? "idle: CodeSaver starts the saver itself after this long, screenshotting the desktop at that moment — set macOS's own screen saver timeout to Never so the two don't race"
            : "idle: macOS's own screen saver timeout starts the saver; CodeSaver keeps a fresh screenshot ready for it"
        return idle
            + "\ncorners: click one to arm it, add ⌘ ⌥ ⌃ ⇧ to require that key — hold it first, then push the cursor in; pressing it with the cursor already there is ignored"
            + "\nleave macOS's own hot corners unbound so they don't race these"
    }
}

/// A toggle drawn as one terminal character cell: reverse video when on,
/// a slate glyph on black when off — the saver's own vocabulary for state.
private struct CellToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(Theme.mono(12))
                .frame(width: 20, height: 18)
                .foregroundStyle(configuration.isOn ? Color.black : Theme.slate)
                .background(configuration.isOn ? Theme.ink : Color.clear)
                .overlay(Rectangle().strokeBorder(Theme.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
