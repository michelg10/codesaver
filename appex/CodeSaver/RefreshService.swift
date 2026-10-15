//
//  RefreshService.swift
//  CodeSaver
//
//  The self-refreshing corpus: gates, orchestration, Keychain token, and the
//  SMAppService LaunchAgent that runs `CodeSaver --refresh` hourly at the
//  lowest QoS launchd offers. Host app target only.
//

import Foundation
import IOKit.ps
import Security
import ServiceManagement

enum RefreshError: LocalizedError {
    case noToken
    case noContainer
    case alreadyRunning
    case notConnected

    var errorDescription: String? {
        switch self {
        case .noToken: return "GitHub isn't connected — open CodeSaver to connect it"
        case .noContainer: return "CodeSaver can't open its own data folder — reinstalling the app fixes this"
        case .alreadyRunning: return "a refresh is already running"
        case .notConnected: return "nothing to fetch yet — connect GitHub or add a folder"
        }
    }
}

enum RefreshService {
    private static let log = AppexLog.logger("Refresh")

    /// Under 24h so the hourly tick that lands "about a day" after the last
    /// success qualifies — a hard 24h gate drifts later every day.
    static let staleAfter: TimeInterval = 23 * 3600

    /// Whose repos to fetch; empty/unset means the token's own account.
    static let ownerDefaultsKey = CodeSources.ownerKey

    static var configuredOwner: String? { CodeSources.owner }

    /// The headless run's view of the sources (reads the Keychain on the
    /// token path only).
    static func currentSources() -> CodeSources.Config {
        CodeSources.current(token: { TokenStore.current })
    }

    // MARK: Gates

    static func onBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == "Battery Power"  // vs "AC Power" / "UPS Power"
    }

    /// "Refresh only when plugged in" (RefreshOnlyWhenPluggedIn, default on):
    /// on, the hourly agent waits for AC power (on desktops that's always);
    /// off, it runs on battery too. Read fresh every tick — the app's switch
    /// writes the same defaults domain the agent reads.
    static func powerGateSatisfied() -> Bool {
        !CodeSources.onlyWhenPluggedIn || !onBatteryPower()
    }

    struct Gate {
        let run: Bool
        let reason: String
    }

    static func evaluateGates(force: Bool, now: Date = Date()) -> Gate {
        if force { return Gate(run: true, reason: "forced") }
        let state = CorpusStore.loadState()
        // A spent GitHub allowance resets at a known time; asking again before
        // then only spends the next hour's too.
        if state.problem?.kind == FetchError.Kind.rateLimited.rawValue,
           let reset = state.problem?.resetsAt, reset > now {
            return Gate(run: false, reason: "GitHub rate limit until \(reset)")
        }
        var reason = "no corpus yet"
        if CorpusStore.corpusExists {
            guard powerGateSatisfied() else { return Gate(run: false, reason: "on battery power") }
            if let last = state.lastSuccess, now.timeIntervalSince(last) < staleAfter {
                return Gate(run: false, reason: "refreshed \(Int(now.timeIntervalSince(last) / 3600))h ago")
            }
            reason = CodeSources.onlyWhenPluggedIn ? "stale, on AC power" : "stale"
        }
        // Last, and without reading the token itself: nothing connected is a
        // fresh install, not a failure — no error in state.json for the app to
        // show before the user has done anything.
        let connected = CodeSources.publicOnly ? CodeSources.owner != nil : TokenStore.exists
        guard connected || !LocalFolder.load().isEmpty else {
            return Gate(run: false, reason: "nothing connected yet")
        }
        return Gate(run: true, reason: reason)
    }

    // MARK: Pipeline

    typealias Run = CorpusStore.State.Run

    /// Fetch changed repos and folders, rebuild the corpus, swap it into the
    /// app-group container. Returns a human summary. Throws without touching
    /// an existing corpus on failure — and records the failure, in plain
    /// words, in state.json while it still holds the lock (so the agent's
    /// failures reach the app, and no two processes write the file at once).
    ///
    /// `progress` sees every step; state.json sees the ones that do work, so
    /// the app can draw a run happening in the agent's process.
    static func refresh(progress: (@Sendable (Run) -> Void)? = nil) async throws -> String {
        guard let corpusDir = CorpusStore.corpusDirectory,
              let repoCache = CorpusStore.repoCacheDirectory,
              let folderCache = CorpusStore.folderCacheDirectory,
              let scratch = CorpusStore.scratchDirectory else { throw RefreshError.noContainer }
        // The app's Refresh Now and the hourly `--refresh` agent are separate
        // processes sharing scratch, the repo cache and the corpus tmp files;
        // only one may be in here at a time (the lock file lives in corpusDir).
        guard let lock = try CorpusStore.tryLockRefresh() else { throw RefreshError.alreadyRunning }
        defer { lock.release() }
        RepoSelection.migrateIfNeeded()  // before anything below can prune a mirror
        let sources = currentSources()
        guard sources.hasAnySource else { throw RefreshError.notConnected }
        let fm = FileManager.default
        try fm.createDirectory(at: repoCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: folderCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let pass = Pass(state: CorpusStore.loadState(), progress: progress)
        do {
            var mirrors = try await pass.github(sources.github, repoCache: repoCache, scratch: scratch)
            mirrors += pass.folders(sources.folders, folderCache: folderCache, scratch: scratch)
            pass.report(Run(pid: getpid(), phase: "packing"))
            let built: CorpusIngest.BuildResult
            do {
                built = try CorpusIngest.buildCorpus(sources: mirrors, corpusDir: corpusDir)
            } catch FetchError.emptyCorpus {
                // Normally a failed build leaves the saver its old text. Not
                // when nothing is left to build from: everything was unticked
                // or removed, and code the user took out must not stay on
                // screen. The saver falls back to its built-in text.
                if mirrors.isEmpty {
                    for name in ["corpus.bin", "corpus-index.json"] {
                        try? fm.removeItem(at: corpusDir.appendingPathComponent(name))
                    }
                    pass.state.lastSuccess = nil
                    pass.state.repoCount = 0
                    pass.state.fileCount = 0
                    pass.state.corpusBytes = 0
                }
                throw FetchError.emptyCorpus(pass.tally.explanation)
            }
            pass.state.lastSuccess = Date()
            pass.state.lastError = nil
            pass.state.problem = nil
            pass.state.progress = nil
            pass.state.skipped = pass.skipped.isEmpty ? nil : pass.skipped
            pass.state.repoCount = built.repoCount
            pass.state.fileCount = built.fileCount
            pass.state.corpusBytes = built.bytes
            CorpusStore.saveState(pass.state)
            let summary = "\(built.fileCount) files from \(built.repoCount) repos "
                + "(\(String(format: "%.1f", Double(built.bytes) / 1_048_576)) MB)"
            log.notice("corpus refreshed: \(summary, privacy: .public)")
            return summary
        } catch {
            let problem = FetchError.problem(for: error)
            pass.state.problem = problem
            pass.state.lastError = problem.headline
            pass.state.progress = nil
            if !pass.skipped.isEmpty { pass.state.skipped = pass.skipped }
            CorpusStore.saveState(pass.state)
            throw error
        }
    }

    /// One run's working state. A class so the steps can share `state`
    /// without threading an inout through every await.
    private final class Pass {
        var state: CorpusStore.State
        var skipped: [CorpusStore.State.Skipped] = []
        var tally = Tally()
        let progress: (@Sendable (Run) -> Void)?
        let fm = FileManager.default

        init(state: CorpusStore.State, progress: (@Sendable (Run) -> Void)?) {
            self.state = state
            self.progress = progress
        }

        /// Steps that do work also land in state.json for the app to watch.
        func report(_ run: Run, save: Bool = true) {
            progress?(run)
            guard save else { return }
            state.progress = run
            CorpusStore.saveState(state)
        }

        // MARK: GitHub

        /// Lists, fetches what changed among the selected repos, prunes
        /// mirrors that are deselected or gone, and returns the GitHub mirrors
        /// to pack. Not connected: every existing mirror stays and is packed —
        /// disconnecting isn't deleting (that's "delete downloaded code").
        func github(_ gh: CodeSources.Config.GitHub?, repoCache: URL, scratch: URL) async throws -> [CorpusIngest.Source] {
            guard let gh else { return mirrorSources(repoCache) }
            let client = GitHubClient(token: gh.token)
            report(Run(pid: getpid(), phase: "listing"))
            var login: String?
            if gh.token != nil {
                let me = try await client.currentLogin()
                login = me
                CodeSources.defaults.set(me, forKey: CodeSources.loginKey)
            }
            guard let owner = gh.owner ?? login else { throw RefreshError.notConnected }
            let listing = try await client.listSourceRepos(owner: owner, ownLogin: login)
            let repos = listing.repos.sorted { $0.name.lowercased() < $1.name.lowercased() }
            log.info("\(repos.count) source repos on github.com/\(owner, privacy: .public)")
            state.listing = .init(owner: owner,
                                  repos: repos.map { .init(name: $0.name, isPrivate: $0.isPrivate, sizeKB: $0.sizeKB) },
                                  forks: listing.forks, complete: !listing.hitCeiling)

            let choices = RepoSelection.choices()
            let selected = repos.filter { RepoSelection.isSelected($0.name, isPrivate: $0.isPrivate, choices: choices) }
            tally.owner = owner
            tally.listed = repos.count
            tally.forks = listing.forks
            tally.privateOff = repos.filter { $0.isPrivate && choices[$0.name] == nil }.count
            tally.unticked = repos.count - selected.count - tally.privateOff
            tally.chosen = selected.count
            report(Run(pid: getpid(), phase: "repos", done: 0, total: selected.count))

            for (i, repo) in selected.enumerated() {
                let mirror = repoCache.appendingPathComponent(repo.name, isDirectory: true)
                if state.repoPushedAt[repo.name] == repo.pushedAt, fm.fileExists(atPath: mirror.path) {
                    report(Run(pid: getpid(), phase: "repos", done: i + 1, total: selected.count), save: false)
                    continue
                }
                // GitHub's size is the whole repo, history included — an upper
                // bound on the tarball, known before a byte is downloaded.
                if repo.sizeKB * 1024 >= CorpusIngest.maxTarballBytes {
                    skip(repo.name, FetchError.tooBig(bytes: repo.sizeKB * 1024).repoReason)
                    tally.tooBig += 1
                    continue
                }
                report(Run(pid: getpid(), phase: "repos", done: i + 1, total: selected.count, current: repo.name))
                do {
                    let tarball = try await client.downloadTarball(owner: owner, repo: repo.name)
                    defer { try? fm.removeItem(at: tarball) }
                    let size = (try? tarball.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size < CorpusIngest.maxTarballBytes else {
                        skip(repo.name, FetchError.tooBig(bytes: size).repoReason)
                        tally.tooBig += 1
                        continue
                    }
                    let kept = try CorpusIngest.syncRepo(named: repo.name, tarball: tarball,
                                                         cacheDir: repoCache, scratchDir: scratch)
                    state.repoPushedAt[repo.name] = repo.pushedAt
                    CorpusStore.saveState(state)  // save-as-you-go: an interrupted run resumes
                    log.info("\(repo.name, privacy: .public): \(kept) source files")
                } catch let error as FetchError where error.abortsRun {
                    throw error  // every remaining repo would fail the same way
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One failed repo must not kill the run; pushed_at stays
                    // stale so the next refresh retries it. An empty repo has
                    // no tarball to give — that's not worth a line in the UI.
                    log.error("\(repo.name, privacy: .public): \(String(describing: error), privacy: .public)")
                    if repo.sizeKB == 0, (error as? FetchError) == .notFound { continue }
                    skip(repo.name, (error as? FetchError)?.repoReason ?? error.localizedDescription)
                    tally.failed += 1
                }
            }

            // Deselected repos leave now, always. Repos missing from the
            // listing leave only when it was complete — past the page ceiling,
            // an unlisted name is unknown, not gone.
            let listed = Set(repos.map(\.name))
            let chosen = Set(selected.map(\.name))
            for mirror in CorpusIngest.mirrorDirectories(in: repoCache) {
                let name = mirror.lastPathComponent
                let deselected = listed.contains(name) && !chosen.contains(name)
                let gone = !listing.hitCeiling && !listed.contains(name)
                if deselected || gone { try? fm.removeItem(at: mirror) }
            }
            state.repoPushedAt = state.repoPushedAt.filter { name, _ in
                listing.hitCeiling ? !(listed.contains(name) && !chosen.contains(name)) : chosen.contains(name)
            }
            CorpusStore.saveState(state)
            return mirrorSources(repoCache)
        }

        private func mirrorSources(_ root: URL) -> [CorpusIngest.Source] {
            CorpusIngest.mirrorDirectories(in: root).map { .init(name: $0.lastPathComponent, dir: $0) }
        }

        // MARK: Local folders

        /// Mirrors every folder it can read. One it can't — moved, unmounted,
        /// or behind macOS's privacy wall for a background job — is recorded
        /// and skipped, and its previous mirror (if any) is packed as-is.
        func folders(_ folders: [LocalFolder], folderCache: URL, scratch: URL) -> [CorpusIngest.Source] {
            tally.folders = folders.count
            var sources: [CorpusIngest.Source] = []
            for (i, folder) in folders.enumerated() {
                report(Run(pid: getpid(), phase: "folders", done: i + 1, total: folders.count, current: folder.name))
                let dest = folderCache.appendingPathComponent(folder.mirrorName, isDirectory: true)
                let (url, scoped) = folder.open()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let kept = try CorpusIngest.mirrorFolder(at: url, into: dest, scratchDir: scratch)
                    log.info("folder \(folder.name, privacy: .public): \(kept) source files")
                } catch {
                    log.error("folder \(folder.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    skipped.append(.init(name: folder.displayPath, isFolder: true,
                                         reason: LocalFolder.reason(for: error, path: folder.path)))
                    tally.unreadable += 1
                }
                if fm.fileExists(atPath: dest.path) { sources.append(.init(name: folder.name, dir: dest)) }
            }
            // Folders removed from the list leave with their mirrors.
            let keep = Set(folders.map(\.mirrorName))
            for mirror in CorpusIngest.mirrorDirectories(in: folderCache) where !keep.contains(mirror.lastPathComponent) {
                try? fm.removeItem(at: mirror)
            }
            return sources
        }

        private func skip(_ repo: String, _ reason: String) {
            log.warning("\(repo, privacy: .public): skipped — \(reason, privacy: .public)")
            skipped.append(.init(name: repo, isFolder: false, reason: reason))
        }
    }

    /// What a run found, kept only to explain an empty result in words:
    /// "found no code to show" is useless without the why.
    struct Tally {
        var owner: String?
        var listed = 0, forks = 0, privateOff = 0, unticked = 0, chosen = 0
        var tooBig = 0, failed = 0
        var folders = 0, unreadable = 0

        var explanation: String {
            func n(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
            var parts: [String] = []
            if let owner {
                if listed + forks == 0 {
                    parts.append("\(owner) has no repos CodeSaver can see")
                } else {
                    parts.append("\(owner): \(n(listed + forks, "repo"))")
                }
                if forks > 0 { parts.append("\(n(forks, "fork")) skipped — a fork is mostly someone else's code") }
                if privateOff > 0 { parts.append("\(n(privateOff, "private repo")) off until you tick them in choose repos") }
                if unticked > 0 { parts.append("\(unticked) unticked") }
                if tooBig > 0 { parts.append("\(tooBig) too big to download") }
                if failed > 0 { parts.append("\(failed) failed to download") }
            } else if folders == 0 {
                parts.append("GitHub isn't connected and no folders are added")
            }
            if unreadable > 0 { parts.append("\(n(unreadable, "folder")) couldn't be read") }
            let read = max(0, chosen - tooBig - failed) + max(0, folders - unreadable)
            if read > 0 {
                parts.append("what was read had no source files CodeSaver shows (.swift, .py, .js, .go and the like) — only tiny, generated or vendored ones")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// `CodeSaver --refresh [--force]` — what the LaunchAgent runs. A gate
    /// skip exits 0 too, as does yielding to a refresh already under way in
    /// the app, so launchd never sees hourly "failures". Failures are already
    /// in state.json (refresh() wrote them under the lock).
    static func headlessRefresh(force: Bool) async -> Bool {
        let gate = evaluateGates(force: force)
        guard gate.run else {
            log.info("refresh skipped: \(gate.reason, privacy: .public)")
            print("refresh skipped: \(gate.reason)")
            return true
        }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "corpus refresh")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            let summary = try await Task.detached(priority: .background) {
                try await refresh()
            }.value
            print("refreshed: \(summary)")
            return true
        } catch RefreshError.alreadyRunning {
            log.info("refresh skipped: already running in another process")
            print("refresh skipped: already running in another process")
            return true
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(Data("refresh failed: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    // MARK: Delete downloaded code

    /// Clears every mirror, scratch, and the packed text the saver reads;
    /// keeps settings (connection, repo choices, folders, verbs, widgets) and
    /// the last listing so the picker still has rows. Takes the refresh lock:
    /// deleting under a running refresh would hand it a half-empty cache.
    static func deleteDownloadedCode() throws {
        guard let corpusDir = CorpusStore.corpusDirectory else { throw RefreshError.noContainer }
        guard let lock = try CorpusStore.tryLockRefresh() else { throw RefreshError.alreadyRunning }
        defer { lock.release() }
        let fm = FileManager.default
        for root in DownloadedCode.roots { try? fm.removeItem(at: root) }
        for name in ["corpus.bin", "corpus-index.json", "corpus.bin.tmp", "corpus-index.json.tmp"] {
            try? fm.removeItem(at: corpusDir.appendingPathComponent(name))
        }
        var state = CorpusStore.loadState()
        state.repoPushedAt = [:]
        state.lastSuccess = nil
        state.lastError = nil
        state.problem = nil
        state.skipped = nil
        state.progress = nil
        state.repoCount = 0
        state.fileCount = 0
        state.corpusBytes = 0
        CorpusStore.saveState(state)
        log.notice("downloaded code deleted")
    }
}

// MARK: - Keychain token

enum TokenStore {
    static let service = "CodeSaver GitHub"
    static let account = "github-token"

    /// Env override (scripted/headless use) → Keychain.
    static var current: String? {
        if let env = ProcessInfo.processInfo.environment["CODESAVER_GITHUB_TOKEN"],
           !env.isEmpty {
            return env
        }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a token is saved, asking for the item's attributes only — the
    /// hourly gate runs this every tick, and has no use for the secret itself.
    /// Any failure (a locked keychain included) reads as "not connected": the
    /// tick skips quietly and the next one asks again.
    static var exists: Bool {
        if let env = ProcessInfo.processInfo.environment["CODESAVER_GITHUB_TOKEN"], !env.isEmpty {
            return true
        }
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func store(_ token: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func forget() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Where GitHub's `gh` tool lands with Homebrew (both prefixes), MacPorts,
    /// or a manual install. A GUI app gets no shell PATH, so look, don't ask.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh"]

    static var ghInstalled: Bool {
        ghCandidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum GHToken {
        case notInstalled
        case notSignedIn
        case token(String)
    }

    /// The token an installed, signed-in gh already holds. Blocks on a
    /// subprocess — call off the main thread.
    static func tokenFromGH() -> GHToken {
        var installed = false
        for gh in ghCandidates where FileManager.default.isExecutableFile(atPath: gh) {
            installed = true
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }
            let token = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return .token(token) }
        }
        return installed ? .notSignedIn : .notInstalled
    }

    /// One-time convenience: lift the token out of an authenticated gh CLI
    /// (the scripted `--import-gh-token`; the app validates first instead).
    static func importFromGH() -> Bool {
        if case .token(let token) = tokenFromGH() { return store(token) }
        return false
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

// MARK: - LaunchAgent registration

enum RefreshAgent {
    static let plistName = "com.michelg10.CodeSaver.refresh.plist"
    static var service: SMAppService { .agent(plistName: plistName) }

    /// SMAppService pins the registering app's path; install.sh installs to
    /// /Applications and deletes the DerivedData build afterwards, so only
    /// ever register from there.
    static var isAtStablePath: Bool { Bundle.main.bundlePath == "/Applications/CodeSaver.app" }

    static var status: SMAppService.Status { service.status }

    /// Re-registering an enabled agent is a cheap no-op that self-heals a
    /// stale BTM record, so install.sh calls this on every install.
    @discardableResult
    static func register(interactive: Bool) -> SMAppService.Status {
        guard isAtStablePath else { return service.status }
        if service.status != .enabled {
            try? service.register()
        }
        let status = service.status
        if status == .requiresApproval && interactive {
            SMAppService.openSystemSettingsLoginItems()
        }
        return status
    }

    static func unregister() {
        try? service.unregister()
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "awaiting approval in Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
