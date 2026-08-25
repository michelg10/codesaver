//
//  RefreshManager.swift
//  CodeSaver
//
//  Drives the Corpus parts of the host app UI: token setup, owner, spinner
//  verbs, manual refresh with progress, and the auto-refresh agent toggle.
//

import Foundation
import ServiceManagement

@MainActor
final class RefreshManager: ObservableObject {
    @Published var hasToken = false
    @Published var owner = ""
    @Published var state = CorpusStore.State()
    @Published var isRefreshing = false
    @Published var progressText: String?
    @Published var agentEnabled = false
    @Published var agentNeedsApproval = false
    @Published var customVerbCount: Int?   // nil = bundled list in use
    @Published var lastActionError: String?

    init() {
        reload()
    }

    func reload() {
        hasToken = TokenStore.current != nil
        state = CorpusStore.loadState()
        owner = RefreshService.configuredOwner ?? ""
        let status = RefreshAgent.status
        agentEnabled = status == .enabled
        agentNeedsApproval = status == .requiresApproval
        customVerbCount = CorpusStore.verbsURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(Self.verbCount)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: Token

    func importTokenFromGH() {
        lastActionError = TokenStore.importFromGH()
            ? nil : "gh CLI not found or not signed in (run `gh auth login`)"
        reload()
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastActionError = TokenStore.store(trimmed) ? nil : "couldn't store the token in the Keychain"
        reload()
    }

    func forgetToken() {
        TokenStore.forget()
        reload()
    }

    // MARK: Owner (UserDefaults — config, not derived state)

    func saveOwner() {
        let trimmed = owner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: RefreshService.ownerDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: RefreshService.ownerDefaultsKey)
        }
    }

    // MARK: Spinner verbs

    /// The saver's format: "Gerund<TAB>Past" per line, tabs only — verbs are
    /// free to contain commas.
    static func parseVerbs(_ text: String) -> [(ing: String, past: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (ing: parts[0], past: parts[1])
        }
    }

    static func verbCount(_ text: String) -> Int { parseVerbs(text).count }

    func importVerbs(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastActionError = "couldn't read \(url.lastPathComponent)"
            return
        }
        let verbs = Self.parseVerbs(text)
        guard !verbs.isEmpty else {
            lastActionError = "no tab-delimited \"Gerund\\tPast\" lines in \(url.lastPathComponent)"
            return
        }
        guard let dest = CorpusStore.verbsURL else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let normalized = verbs.map { "\($0.ing)\t\($0.past)" }.joined(separator: "\n") + "\n"
            try Data(normalized.utf8).write(to: dest, options: .atomic)
            lastActionError = nil
        } catch {
            lastActionError = error.localizedDescription
        }
        reload()
    }

    func resetVerbs() {
        if let url = CorpusStore.verbsURL {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    // MARK: Refresh

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        progressText = "Starting…"
        lastActionError = nil
        Task {
            do {
                // .utility, not .background: the user is watching this one.
                _ = try await Task.detached(priority: .utility) {
                    try await RefreshService.refresh { line in
                        Task { @MainActor in self.progressText = line }
                    }
                }.value
            } catch {
                lastActionError = error.localizedDescription
                var s = CorpusStore.loadState()
                s.lastError = error.localizedDescription
                CorpusStore.saveState(s)
            }
            isRefreshing = false
            progressText = nil
            reload()
        }
    }

    var lastRefreshDescription: String {
        guard let date = state.lastSuccess else { return "never" }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 90 { return "just now" }
        if seconds < 90 * 60 { return "\(seconds / 60)m ago" }
        if seconds < 36 * 3600 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var corpusSizeDescription: String {
        String(format: "%.1f MB", Double(state.corpusBytes) / 1_048_576)
    }

    // MARK: Auto-refresh agent

    func setAutoRefresh(_ enabled: Bool) {
        if enabled {
            if !RefreshAgent.isAtStablePath {
                lastActionError = "auto-refresh needs the app to live in /Applications"
            }
            let status = RefreshAgent.register(interactive: true)
            agentEnabled = status == .enabled
            agentNeedsApproval = status == .requiresApproval
        } else {
            RefreshAgent.unregister()
            reload()
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
