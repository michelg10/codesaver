//
//  LiveWidgetsStep.swift
//  CodeSaver
//
//  Setup step 4, optional: the Live widgets switch (the background helper
//  that feeds the saver's panels), the Claude Code connection behind the
//  session panels, and the one ask to read the music player. ContentView
//  draws the checklist glyph + title and the shared Login Items row and
//  hands them in, so every step still looks alike.
//
//  The connection is offered only once the switch is on — hooks with no
//  panels to feed are pure cost — and stays visible while anything of it
//  is left in Claude Code's settings, so it can always be disconnected.
//

import SwiftUI

struct LiveWidgetsStep<Label: View, Approval: View>: View {
    @ObservedObject var refreshManager: RefreshManager
    let label: Label
    let approval: Approval

    @StateObject private var claude = ClaudeCodeConnection()
    @State private var askAlsoDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                label
                Text("optional · Claude Code sessions · now playing")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                Spacer()
                Toggle("Live widgets", isOn: Binding(get: { refreshManager.feedsEnabled },
                                                     set: { setLiveWidgets($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if refreshManager.feedsNeedsApproval {
                approval
            }
            if refreshManager.feedsEnabled || refreshManager.feedsNeedsApproval
                || claude.isWired || claude.error != nil {
                claudeRow
                    .padding(.leading, 24)
            }
            Text(caption)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
        }
        .onAppear { claude.refresh() }
        // Someone may wire or unwire from a terminal, or install the
        // command line tools, while the window is away.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            claude.refresh()
        }
        .sheet(isPresented: Binding(get: { claude.preview != nil },
                                    set: { if !$0 { claude.preview = nil } })) {
            ConnectSheet(preview: claude.preview ?? "",
                         cancel: { claude.preview = nil },
                         connect: { claude.connect() })
        }
        .confirmationDialog("Also disconnect Claude Code?", isPresented: $askAlsoDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect") {
                refreshManager.setLiveWidgets(false)
                claude.disconnect()
            }
            Button("Keep Connected") { refreshManager.setLiveWidgets(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While connected, Claude Code runs CodeSaver's hook on every session event, panels or not. Disconnecting removes it and puts your statusline back; you can connect again any time.")
        }
    }

    private func setLiveWidgets(_ on: Bool) {
        if on {
            refreshManager.setLiveWidgets(true)
            if refreshManager.feedsEnabled || refreshManager.feedsNeedsApproval {
                // The ask the caption announced, now that the user opted in.
                // A beat later, so the switch has moved before the probe
                // holds the main thread for macOS's consent dialog.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    CodeSaverApp.seedAutomationConsent()
                }
            }
            claude.refresh()
        } else if claude.isWired {
            askAlsoDisconnect = true
        } else {
            refreshManager.setLiveWidgets(false)
        }
    }

    // MARK: Claude Code

    private var claudeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(claudeStatus)
                    .font(Theme.mono(11))
                    .foregroundStyle(claudeStatusIsAlert ? Theme.alert : Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if claude.busy {
                    ProgressView().scaleEffect(0.5).frame(width: 20, height: 16)
                } else {
                    claudeButtons
                }
            }
            if let error = claude.error {
                Text(error)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.alert)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var claudeStatus: String {
        if claude.isWired, !refreshManager.feedsEnabled, !refreshManager.feedsNeedsApproval {
            // Left connected with the panels off: say what that costs.
            return "still connected — Claude Code runs the hook with the panels off"
        }
        switch claude.phase {
        case .checking:
            return "checking Claude Code…"
        case .unreadable(let message):
            return message
        case .blocked(.claudeCodeMissing):
            return ClaudeCodeWiring.Blocker.claudeCodeMissing.message
        case .blocked(.needsCommandLineTools):
            return "Claude Code sessions need Apple's command line tools"
        case .blocked(let b):
            return b.message
        case .ready(.disconnected):
            return "Claude Code not connected"
        case .ready(.connected):
            return "connected · restart Claude Code sessions to see them"
        case .ready(.connectedFromCheckout):
            return "connected from a source checkout · restart Claude Code sessions to see them"
        case .ready(.partial):
            return "Claude Code partly connected — connect again to repair it"
        }
    }

    private var claudeStatusIsAlert: Bool {
        switch claude.phase {
        case .blocked(.scriptsMissing), .ready(.partial), .unreadable: return true
        default: return false
        }
    }

    private var claudeButtons: some View {
        HStack(spacing: 6) {
            switch claude.phase {
            case .blocked(.needsCommandLineTools):
                Button("Install…") { claude.installCommandLineTools() }
                    .buttonStyle(.bordered)
            case .ready(.disconnected):
                Button("Connect Claude Code") { claude.prepareConnect() }
                    .buttonStyle(.borderedProminent)
            case .ready(.partial):
                Button("Connect") { claude.prepareConnect() }
                    .buttonStyle(.bordered)
                Button("Disconnect") { claude.disconnect() }
                    .buttonStyle(.bordered)
            case .ready(.connected), .ready(.connectedFromCheckout):
                Button("Disconnect") { claude.disconnect() }
                    .buttonStyle(.bordered)
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    // MARK: Caption

    private var caption: String {
        let undo = !refreshManager.feedsEnabled
            ? "switching on, CodeSaver will ask to read what Music or Spotify is playing"
            : claude.isWired ? "switch off to stop · Disconnect restores Claude Code's settings"
                             : "switch off to stop the panels"
        return [
            "panels show project folder names and track titles to anyone who can see the screen",
            "nothing leaves this Mac: sessions live in ~/.claude/codesaver, Spotify art comes from Spotify",
            undo,
        ].joined(separator: "\n")
    }
}

// MARK: - Connection state

/// Runs ClaudeCodeWiring off the main thread and publishes where things
/// stand. One instance, owned by the step.
@MainActor
final class ClaudeCodeConnection: ObservableObject {
    enum Phase: Equatable {
        case checking
        case blocked(ClaudeCodeWiring.Blocker)
        case ready(ClaudeCodeWiring.State)
        case unreadable(String)     // --status failed: an unparseable settings.json, say
    }

    @Published private(set) var phase = Phase.checking
    @Published private(set) var busy = false
    /// The last Connect / Disconnect that failed; cleared by the next one.
    @Published var error: String?
    /// The dry run awaiting confirmation; non-nil puts up the sheet.
    @Published var preview: String?

    /// Anything of ours in Claude Code's settings, working or not.
    var isWired: Bool {
        if case .ready(let s) = phase { return s != .disconnected }
        return false
    }

    func refresh() {
        guard !busy else { return }
        Task {
            let next = await Task.detached(priority: .userInitiated) { () -> Result<Phase, Error> in
                if let b = ClaudeCodeWiring.blocker() { return .success(.blocked(b)) }
                return Result { try .ready(ClaudeCodeWiring.status()) }
            }.value
            switch next {
            case .success(let p): phase = p
            case .failure(let e): phase = .unreadable(e.localizedDescription)
            }
        }
    }

    /// Step one of Connect: the dry run, for the confirm sheet.
    func prepareConnect() {
        perform({ try ClaudeCodeWiring.preview() }) { [weak self] text in self?.preview = text }
    }

    /// Step two, from the sheet.
    func connect() {
        preview = nil
        perform({ try ClaudeCodeWiring.wire() })
    }

    func disconnect() {
        perform({ try ClaudeCodeWiring.unwire() })
    }

    func installCommandLineTools() {
        Task.detached(priority: .userInitiated) { ClaudeCodeWiring.installCommandLineTools() }
    }

    private func perform<T>(_ work: @escaping () throws -> T,
                            then done: ((T) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busy = false
            switch result {
            case .success(let value): done?(value)
            case .failure(let e): error = e.localizedDescription
            }
            refresh()
        }
    }
}

// MARK: - Confirm sheet

private struct ConnectSheet: View {
    let preview: String
    let cancel: () -> Void
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("✽ Connect Claude Code")
                .font(Theme.mono(14, .semibold))
                .foregroundStyle(Theme.ink)
            Text("adds a small hook to Claude Code's settings so the saver can show your sessions. below is every change — a backup of settings.json is kept beside it, and Disconnect puts it all back.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(preview)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 280)
            .background(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack(spacing: 8) {
                Text("restart Claude Code sessions afterwards")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(22)
        .frame(width: 560)
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(Theme.violet)
    }
}
