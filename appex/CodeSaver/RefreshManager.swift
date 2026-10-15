//
//  RefreshManager.swift
//  CodeSaver
//
//  Drives the Corpus parts of the host app UI: connecting GitHub (token or
//  public username), the repo + folder picker, spinner verbs, refreshes with
//  progress — this process's or the hourly agent's — and the agent toggle.
//

import AppKit
import Foundation
import ServiceManagement

@MainActor
final class RefreshManager: ObservableObject {
    @Published var hasToken = false
    @Published var owner = ""                  // the Advanced "repos of" field, live text
    @Published var state = CorpusStore.State()
    @Published var isRefreshing = false        // a refresh in THIS process
    /// The run being drawn — this process's, or one the agent is doing
    /// (`runIsElsewhere`), read from state.json. nil = nothing running.
    @Published var run: CorpusStore.State.Run?
    @Published var runIsElsewhere = false

    // Connection
    @Published var publicOnly = false
    @Published var savedOwner: String?         // GitHubOwner as saved, not as being typed
    @Published var login: String?
    @Published var connecting = false
    @Published var connectError: String?
    @Published var replacingToken = false      // "Replace token" reopened the token field
    @Published var ghInstalled = false

    // What to fetch
    @Published var choices: [String: Bool] = [:]
    @Published var folders: [LocalFolder] = []
    @Published var freshListing: CorpusStore.State.Listing?   // fetched by the picker itself
    @Published var isListing = false
    @Published var listingError: String?
    @Published var onlyWhenPluggedIn = true
    @Published var diskBytes: Int64?

    @Published var agentEnabled = false
    @Published var agentNeedsApproval = false
    @Published var feedsEnabled = false
    @Published var feedsNeedsApproval = false
    @Published var customVerbCount: Int?   // nil = bundled list in use
    @Published var lastActionError: String?

    /// Set by a change that the run already under way won't see (it read its
    /// settings at the start): run once more when it ends.
    private var refreshQueued = false
    private var stateStamp: Date?
    private var watcher: Timer?

    init() {
        RepoSelection.migrateIfNeeded()  // before the picker shows a single checkbox
        reload()
        ghInstalled = TokenStore.ghInstalled
        // Watch state.json: the hourly agent is another process, and this is
        // the only way its progress, its end and its failures reach the window.
        // A stat per tick; the file is decoded only when it changed.
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.watchState() }
        }
    }

    func reload() {
        hasToken = TokenStore.current != nil
        state = CorpusStore.loadState()
        stateStamp = Self.stateModified()
        owner = RefreshService.configuredOwner ?? ""
        savedOwner = RefreshService.configuredOwner
        publicOnly = CodeSources.publicOnly
        login = CodeSources.defaults.string(forKey: CodeSources.loginKey)
        choices = RepoSelection.choices()
        folders = LocalFolder.load()
        onlyWhenPluggedIn = CodeSources.onlyWhenPluggedIn
        adoptRun()
        updateDiskUsage()
        adoptAgentStatus(RefreshAgent.status)
        adoptFeedsStatus(FeedsAgent.status)
        customVerbCount = CorpusStore.verbsURL
            .flatMap(Self.readVerbFile)
            .map(Self.verbCount)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: Connection

    /// Connected = the chosen path has what it needs: a username on the
    /// public path, a token otherwise.
    var githubConnected: Bool { publicOnly ? savedOwner != nil : hasToken }

    /// Anything for a refresh to fetch — GitHub, or folders alone.
    var hasSource: Bool { githubConnected || !folders.isEmpty }

    /// The account the label names: the public username, the "repos of"
    /// owner, or the token's own login.
    var accountName: String? { publicOnly ? savedOwner : (savedOwner ?? login) }

    /// "include private repos": validate with GET /user, and only then store.
    /// A failure says why in plain words and leaves the Keychain untouched.
    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !connecting else { return }
        connect { try await self.adoptToken(trimmed) }
    }

    /// The secondary path: borrow what an installed, signed-in gh holds —
    /// validated like a pasted one.
    func importTokenFromGH() {
        guard !connecting else { return }
        connect {
            let result = await Task.detached(priority: .userInitiated) { TokenStore.tokenFromGH() }.value
            switch result {
            case .token(let token):
                try await self.adoptToken(token)
            case .notInstalled:
                throw ConnectFailure("gh isn't installed — use a token instead")
            case .notSignedIn:
                // A GUI user mustn't be sent to Terminal without the why.
                throw ConnectFailure("gh is installed but not signed in, and gh only signs in from Terminal (gh auth login) — or skip it: create a token above, no Terminal needed")
            }
        }
    }

    private func adoptToken(_ token: String) async throws {
        let login = try await GitHubClient(token: token).currentLogin()
        guard TokenStore.store(token) else {
            throw ConnectFailure("couldn't save the token in your keychain — is it locked?")
        }
        let d = CodeSources.defaults
        d.removeObject(forKey: CodeSources.publicOnlyKey)
        d.set(login, forKey: CodeSources.loginKey)
    }

    /// "just my public repos": no token, nothing stored but the username —
    /// checked against GitHub first, and saved in GitHub's own spelling.
    func connectPublic(_ username: String) {
        guard !connecting else { return }
        guard let name = CodeSources.normalizedUsername(username) else {
            connectError = "that isn't a GitHub username — letters, digits and hyphens, like octocat"
            return
        }
        connect {
            let login = try await GitHubClient(token: nil).userLogin(name)
            let d = CodeSources.defaults
            d.set(true, forKey: CodeSources.publicOnlyKey)
            d.set(login, forKey: CodeSources.ownerKey)
        }
    }

    /// Validate, save, then fetch at once: the first refresh runs here, with
    /// progress in the window, instead of waiting up to an hour for the agent.
    private func connect(_ attempt: @escaping () async throws -> Void) {
        connecting = true
        connectError = nil
        Task {
            do {
                try await attempt()
                connecting = false
                replacingToken = false
                freshListing = nil
                reload()
                refreshNow(afterCurrent: true)
            } catch {
                connecting = false
                connectError = (error as? ConnectFailure)?.message
                    ?? (FetchError.wrap(error) as? FetchError)?.connectMessage
                    ?? error.localizedDescription
            }
        }
    }

    private struct ConnectFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Forget the connection — the token, or the public username. What was
    /// already downloaded stays until "delete downloaded code".
    func disconnect() {
        let d = CodeSources.defaults
        if publicOnly {
            d.removeObject(forKey: CodeSources.publicOnlyKey)
            d.removeObject(forKey: CodeSources.ownerKey)
        } else {
            TokenStore.forget()
            d.removeObject(forKey: CodeSources.loginKey)
        }
        freshListing = nil
        replacingToken = false
        connectError = nil
        reload()
    }

    func forgetToken() {
        TokenStore.forget()
        CodeSources.defaults.removeObject(forKey: CodeSources.loginKey)
        reload()
    }

    func openTokenPage() {
        if let url = URL(string: "https://github.com/settings/personal-access-tokens/new") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Owner (UserDefaults — config, not derived state)

    func saveOwner() {
        let trimmed = owner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: RefreshService.ownerDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: RefreshService.ownerDefaultsKey)
        }
        // A different account means different repos: the picker's rows go.
        savedOwner = RefreshService.configuredOwner
        freshListing = nil
    }

    // MARK: Spinner verbs

    /// Whitespace plus the invisibles a hand-edited list carries in: a BOM
    /// that survived a re-encode, and the zero-width space some CJK input
    /// methods emit. Neither is whitespace to Foundation, and both would ride
    /// into the spinner as a phantom leading cell.
    private static let verbTrim = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))

    /// The saver's format: "Gerund<TAB>Past" per line, tabs only — verbs are
    /// free to contain commas.
    ///
    /// Split on `isNewline`, NOT on "\n": Swift makes CRLF a single Character,
    /// so `split(separator: "\n")` finds no separator at all in a CRLF file
    /// and hands back the WHOLE FILE as one line — a single bogus verb whose
    /// past tense is every remaining byte. Any list saved by a Windows editor
    /// (the likely origin of a hand-written CJK list) landed exactly there.
    static func parseVerbs(_ text: String) -> [(ing: String, past: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
                .map { $0.trimmingCharacters(in: verbTrim).precomposedStringWithCanonicalMapping }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (ing: parts[0], past: parts[1])
        }
    }

    static func verbCount(_ text: String) -> Int { parseVerbs(text).count }

    /// UTF-8 first, then whatever Foundation can work out. A list typed in a
    /// Windows editor and saved as "Unicode" is UTF-16, which the strict UTF-8
    /// read rejects outright — the user got "couldn't read" for a perfectly
    /// good file. The import re-writes it as UTF-8 either way.
    static func readVerbFile(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &used)
    }

    func importVerbs(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = Self.readVerbFile(url) else {
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

    /// Start a refresh in this process, watched in the window. `afterCurrent`
    /// is for changes a run already under way won't pick up (a new
    /// connection, the picker): it queues one more run instead of dropping.
    func refreshNow(afterCurrent: Bool = false) {
        if isRefreshing || runIsElsewhere {
            if afterCurrent { refreshQueued = true }
            return
        }
        isRefreshing = true
        run = CorpusStore.State.Run(pid: getpid(), phase: "listing")
        lastActionError = nil
        Task {
            var yielded = false
            do {
                // .utility, not .background: the user is watching this one.
                _ = try await Task.detached(priority: .utility) {
                    try await RefreshService.refresh { run in
                        Task { @MainActor in if self.isRefreshing { self.run = run } }
                    }
                }.value
            } catch RefreshError.alreadyRunning {
                // The agent got there first: draw its run, and go again after
                // it if this one was asked for by a change it can't have seen.
                yielded = true
                if afterCurrent { refreshQueued = true }
            } catch let error as RefreshError {
                // Thrown before the lock — the only failures refresh() can't
                // record in state.json itself.
                lastActionError = error.localizedDescription
            } catch {
                // Recorded in state.json as a plain-words problem; shown from there.
            }
            isRefreshing = false
            run = nil
            reload()
            if !yielded { runFinished() }
        }
    }

    /// A run ended, here or in the agent.
    private func runFinished() {
        freshListing = nil
        drainQueue()
    }

    /// The queued run starts once nothing is visibly running. If the agent
    /// still holds the lock without having written progress yet, the attempt
    /// yields and re-queues — the watcher's next tick tries again.
    private func drainQueue() {
        guard refreshQueued, !refreshActive else { return }
        refreshQueued = false
        refreshNow(afterCurrent: true)
    }

    private static func stateModified() -> Date? {
        guard let path = CorpusStore.stateURL?.path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func watchState() {
        let stamp = Self.stateModified()
        if stamp != stateStamp {
            stateStamp = stamp
            state = CorpusStore.loadState()
        }
        adoptRun()
        drainQueue()
    }

    /// state.json's `progress` is a run only while its process lives: a run
    /// the agent didn't finish (killed, crashed) leaves it behind, and a pid
    /// can be reused — so the pid must be alive AND be this app's executable.
    private func adoptRun() {
        guard !isRefreshing else { return }  // our own callback drives `run`
        let was = runIsElsewhere
        let elsewhere = state.progress.flatMap { p in
            p.pid != getpid() && Self.isRefreshProcess(p.pid) ? p : nil
        }
        runIsElsewhere = elsewhere != nil
        run = elsewhere
        if was && !runIsElsewhere {
            updateDiskUsage()
            runFinished()
        }
    }

    nonisolated static func isRefreshProcess(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(cString: name) == ProcessInfo.processInfo.processName
    }

    var refreshActive: Bool { isRefreshing || runIsElsewhere }

    /// Kept for callers that only want a line of text.
    var progressText: String? { run.map(Self.describe) }

    /// "refreshing · 7 of 23 repos" and its kin.
    static func describe(_ run: CorpusStore.State.Run) -> String {
        switch run.phase {
        case "listing": return "listing your repos…"
        case "repos" where run.total > 0: return "refreshing · \(run.done) of \(run.total) repos"
        case "folders": return "reading folders · \(run.done) of \(run.total)"
        case "packing": return "packing code for the saver…"
        default: return "refreshing…"
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

    // MARK: Repo picker

    /// The rows: what the picker listed itself, else the last refresh's
    /// listing — if it is for the account currently connected.
    var listing: CorpusStore.State.Listing? {
        if let fresh = freshListing { return fresh }
        guard githubConnected, let saved = state.listing else { return nil }
        if let name = accountName, saved.owner.lowercased() != name.lowercased() { return nil }
        return saved
    }

    func isSelected(_ repo: CorpusStore.State.Listing.Repo) -> Bool {
        RepoSelection.isSelected(repo.name, isPrivate: repo.isPrivate, choices: choices)
    }

    /// Every tick is an explicit choice, saved at once (the agent reads the
    /// same key). The picker's Done applies it with a refresh.
    func setSelected(_ repo: CorpusStore.State.Listing.Repo, _ on: Bool) {
        choices[repo.name] = on
        RepoSelection.setChoices(choices)
    }

    func setAll(_ on: Bool) {
        for repo in listing?.repos ?? [] { choices[repo.name] = on }
        RepoSelection.setChoices(choices)
    }

    var selectedCount: Int { listing?.repos.filter(isSelected).count ?? 0 }

    /// The picker's own listing, for when no refresh has listed this account
    /// yet. Costs one request per hundred repos (of 60 an hour without a token).
    func loadListing() {
        guard githubConnected, !isListing else { return }
        isListing = true
        listingError = nil
        let token: String? = publicOnly ? nil : TokenStore.current
        let owner = savedOwner
        Task {
            do {
                let client = GitHubClient(token: token)
                let login = token == nil ? nil : try await client.currentLogin()
                if let login {
                    CodeSources.defaults.set(login, forKey: CodeSources.loginKey)
                    self.login = login
                }
                guard let target = owner ?? login else { throw RefreshError.notConnected }
                let found = try await client.listSourceRepos(owner: target, ownLogin: login)
                freshListing = .init(owner: target,
                                     repos: found.repos.sorted { $0.name.lowercased() < $1.name.lowercased() }
                                        .map { .init(name: $0.name, isPrivate: $0.isPrivate, sizeKB: $0.sizeKB) },
                                     forks: found.forks, complete: !found.hitCeiling)
            } catch {
                listingError = (FetchError.wrap(error) as? FetchError)?.headline ?? error.localizedDescription
            }
            isListing = false
        }
    }

    /// The picker closed. Changes apply by refreshing now — a ticked repo
    /// should show up, an unticked one leave, without waiting for tomorrow.
    func pickerClosed(changed: Bool) {
        if changed && hasSource { refreshNow(afterCurrent: true) }
    }

    // MARK: Local folders

    /// From the open panel. A folder too broad to be "a folder of code" is
    /// refused with the reason; duplicates are ignored.
    func addFolders(_ urls: [URL]) {
        var list = folders
        for url in urls {
            if LocalFolder.isTooBroad(url) {
                lastActionError = "pick a folder of code, not \((url.path as NSString).abbreviatingWithTildeInPath) itself — it would walk every file you own"
                continue
            }
            let folder = LocalFolder.make(from: url)
            if !list.contains(where: { $0.path == folder.path }) { list.append(folder) }
        }
        LocalFolder.save(list)
        folders = list
    }

    func removeFolder(_ folder: LocalFolder) {
        folders.removeAll { $0.path == folder.path }
        LocalFolder.save(folders)
    }

    /// Open panel, folders only, several at once. `completion(true)` when
    /// something was added.
    func chooseFolders(completion: @escaping (Bool) -> Void = { _ in }) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of code to show — the same filters as GitHub repos apply"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { completion(false); return }
                let before = self.folders.count
                self.addFolders(panel.urls)
                completion(self.folders.count > before)
            }
        }
    }

    /// The last run's complaint about this folder, if it couldn't be read.
    func folderProblem(_ folder: LocalFolder) -> String? {
        state.skipped?.first { $0.isFolder && $0.name == folder.displayPath }?.reason
    }

    // MARK: Disk

    func updateDiskUsage() {
        Task {
            diskBytes = await Task.detached(priority: .utility) { DownloadedCode.bytesOnDisk() }.value
        }
    }

    func deleteDownloadedCode() {
        do {
            try RefreshService.deleteDownloadedCode()
            lastActionError = nil
        } catch RefreshError.alreadyRunning {
            lastActionError = "a refresh is running — delete once it's done"
        } catch {
            lastActionError = error.localizedDescription
        }
        reload()
    }

    // MARK: Auto-refresh agent

    /// The corpus refresher only. The widget feed daemon used to ride this
    /// toggle (one switch, two agents) — which meant a KeepAlive daemon for
    /// anyone who merely wanted their corpus fresh. It has its own step now.
    func setAutoRefresh(_ enabled: Bool) {
        if enabled {
            if !RefreshAgent.isAtStablePath {
                lastActionError = "auto-refresh needs the app to live in /Applications"
            }
            adoptAgentStatus(RefreshAgent.register(interactive: true))
        } else {
            RefreshAgent.unregister()
            reload()
        }
    }

    private func adoptAgentStatus(_ refresh: SMAppService.Status) {
        agentEnabled = refresh == .enabled
        agentNeedsApproval = refresh == .requiresApproval
    }

    /// "refresh only when plugged in" — the agent reads it every tick.
    func setOnlyWhenPluggedIn(_ on: Bool) {
        onlyWhenPluggedIn = on
        CodeSources.defaults.set(on, forKey: CodeSources.pluggedInKey)
    }

    // MARK: Live widgets agent

    /// The widget feed daemon (`CodeSaver --feeds`): opt-in, and this toggle
    /// is the only path that ever turns it on — install.sh's
    /// `--register-agent` re-registers it only when it is already enabled.
    func setLiveWidgets(_ enabled: Bool) {
        if enabled {
            if !FeedsAgent.isAtStablePath {
                lastActionError = "live widgets need the app to live in /Applications"
            }
            adoptFeedsStatus(FeedsAgent.register(interactive: true))
        } else {
            FeedsAgent.unregister()
            reload()
        }
    }

    private func adoptFeedsStatus(_ feeds: SMAppService.Status) {
        feedsEnabled = feeds == .enabled
        feedsNeedsApproval = feeds == .requiresApproval
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
