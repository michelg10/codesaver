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

    var errorDescription: String? {
        switch self {
        case .noToken: return "GitHub not connected — open CodeSaver and import or paste a token"
        case .noContainer: return "app-group container unavailable"
        case .alreadyRunning: return "a refresh is already running in another process"
        }
    }
}

enum RefreshService {
    private static let log = AppexLog.logger("Refresh")

    /// Under 24h so the hourly tick that lands "about a day" after the last
    /// success qualifies — a hard 24h gate drifts later every day.
    static let staleAfter: TimeInterval = 23 * 3600

    /// Whose repos to fetch; empty/unset means the token's own account.
    static let ownerDefaultsKey = "GitHubOwner"

    static var configuredOwner: String? {
        let owner = UserDefaults.standard.string(forKey: ownerDefaultsKey)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return owner.isEmpty ? nil : owner
    }

    // MARK: Gates

    static func onBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == "Battery Power"  // vs "AC Power" / "UPS Power"
    }

    /// AC-only: refresh work waits until the machine is plugged in (and on
    /// desktops that's always). Flip to `onBatteryPower()` or `true` if you
    /// want different behavior.
    static func powerGateSatisfied() -> Bool { !onBatteryPower() }

    struct Gate {
        let run: Bool
        let reason: String
    }

    static func evaluateGates(force: Bool, now: Date = Date()) -> Gate {
        if force { return Gate(run: true, reason: "forced") }
        if !CorpusStore.corpusExists { return Gate(run: true, reason: "no corpus yet") }
        guard powerGateSatisfied() else { return Gate(run: false, reason: "on battery power") }
        if let last = CorpusStore.loadState().lastSuccess, now.timeIntervalSince(last) < staleAfter {
            return Gate(run: false, reason: "refreshed \(Int(now.timeIntervalSince(last) / 3600))h ago")
        }
        return Gate(run: true, reason: "stale, on AC power")
    }

    // MARK: Pipeline

    /// Fetch changed repos, rebuild the corpus, swap it into the app-group
    /// container. Returns a human summary. Throws without touching an existing
    /// corpus on failure.
    static func refresh(progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let token = TokenStore.current else { throw RefreshError.noToken }
        guard let corpusDir = CorpusStore.corpusDirectory,
              let repoCache = CorpusStore.repoCacheDirectory,
              let scratch = CorpusStore.scratchDirectory else { throw RefreshError.noContainer }
        // The app's Refresh Now and the hourly `--refresh` agent are separate
        // processes sharing scratch, the repo cache and the corpus tmp files;
        // only one may be in here at a time (the lock file lives in corpusDir).
        guard let lock = try CorpusStore.tryLockRefresh() else { throw RefreshError.alreadyRunning }
        defer { lock.release() }
        let fm = FileManager.default
        try fm.createDirectory(at: repoCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var state = CorpusStore.loadState()
        let client = GitHubClient(token: token)
        progress?("Listing repos…")
        let login = try await client.currentLogin()
        let owner = configuredOwner ?? login
        let listing = try await client.listSourceRepos(owner: owner, ownLogin: login)
        let repos = listing.repos.sorted { $0.name.lowercased() < $1.name.lowercased() }
        log.info("\(repos.count) source repos on github.com/\(owner, privacy: .public)")

        for (i, repo) in repos.enumerated() {
            let mirror = repoCache.appendingPathComponent(repo.name, isDirectory: true)
            if state.repoPushedAt[repo.name] == repo.pushedAt, fm.fileExists(atPath: mirror.path) {
                continue
            }
            progress?("Fetching \(repo.name) (\(i + 1)/\(repos.count))…")
            do {
                let tarball = try await client.downloadTarball(owner: owner, repo: repo.name)
                defer { try? fm.removeItem(at: tarball) }
                let size = (try? tarball.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < CorpusIngest.maxTarballBytes else {
                    log.warning("\(repo.name, privacy: .public): tarball \(size) bytes — skipped")
                    continue
                }
                let kept = try CorpusIngest.syncRepo(named: repo.name, tarball: tarball,
                                                     cacheDir: repoCache, scratchDir: scratch)
                state.repoPushedAt[repo.name] = repo.pushedAt
                CorpusStore.saveState(state)  // save-as-you-go: an interrupted run resumes
                log.info("\(repo.name, privacy: .public): \(kept) source files")
            } catch {
                // One failed repo must not kill the run; pushed_at stays stale
                // so the next refresh retries it.
                log.error("\(repo.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Drop mirrors of repos gone upstream — but only when the listing was
        // complete. Past the page ceiling, an unlisted name is unknown, not gone.
        if !listing.hitCeiling {
            let names = Set(repos.map(\.name))
            let mirrors = (try? fm.contentsOfDirectory(at: repoCache, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for mirror in mirrors where !names.contains(mirror.lastPathComponent) {
                try? fm.removeItem(at: mirror)
            }
            state.repoPushedAt = state.repoPushedAt.filter { names.contains($0.key) }
        }

        progress?("Building corpus…")
        let built = try CorpusIngest.buildCorpus(cacheDir: repoCache, corpusDir: corpusDir)
        state.lastSuccess = Date()
        state.lastError = nil
        state.repoCount = built.repoCount
        state.fileCount = built.fileCount
        state.corpusBytes = built.bytes
        CorpusStore.saveState(state)
        let summary = "\(built.fileCount) files from \(built.repoCount) repos "
            + "(\(String(format: "%.1f", Double(built.bytes) / 1_048_576)) MB)"
        log.notice("corpus refreshed: \(summary, privacy: .public)")
        return summary
    }

    /// `CodeSaver --refresh [--force]` — what the LaunchAgent runs. A gate
    /// skip exits 0 too, as does yielding to a refresh already under way in
    /// the app, so launchd never sees hourly "failures".
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
            var state = CorpusStore.loadState()
            state.lastError = error.localizedDescription
            CorpusStore.saveState(state)
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(Data("refresh failed: \(error.localizedDescription)\n".utf8))
            return false
        }
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

    /// One-time convenience: lift the token out of an authenticated gh CLI.
    static func importFromGH() -> Bool {
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: gh) {
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
            if !token.isEmpty { return store(token) }
        }
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
