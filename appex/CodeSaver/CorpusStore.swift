//
//  CorpusStore.swift
//  CodeSaver
//
//  Shared corpus location + refresh state. Compiled into the host app, the
//  sandboxed appex, AND the standalone swiftc builds in build.sh — keep this
//  file Foundation-only.
//

import Foundation

enum CorpusStore {
    /// Group ID = <TeamID>.com.michelg10.CodeSaver. The built bundles carry it
    /// in Info.plist (CodeSaverAppGroup, substituted from DEVELOPMENT_TEAM at
    /// build time, matching both entitlements files) so forks need zero edits.
    /// The bare-swiftc preview harness has no bundle and falls back to the
    /// stock team's literal.
    static let appGroupID: String = {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "CodeSaverAppGroup") as? String,
           !fromPlist.isEmpty, !fromPlist.hasPrefix(".") {  // "." = DEVELOPMENT_TEAM was unset
            return fromPlist
        }
        return "9K2XM38XLK.com.michelg10.CodeSaver"
    }()

    /// The shared app-group container. The sandboxed appex can only reach the
    /// corpus through this API — never hand-build the path there. The
    /// unsandboxed app and preview harness resolve to the same
    /// ~/Library/Group Containers URL.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// corpus.bin / corpus-index.json / state.json live here.
    static var corpusDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Application Support/CodeSaver",
                                             isDirectory: true)
    }

    /// widgets/ under the corpus: the feed, album art and settings the saver's
    /// panels read and the feeds daemon writes. CODESAVER_WIDGETS_DIR points
    /// the snapshot harness at a fixture directory instead, so a rendered
    /// frame can show a chosen panel state rather than whatever is playing.
    static var widgetsDirectory: URL? {
        if let p = ProcessInfo.processInfo.environment["CODESAVER_WIDGETS_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return corpusDirectory?.appendingPathComponent("widgets", isDirectory: true)
    }

    /// Per-repo filtered mirror of GitHub (what ingest/cache/ used to be).
    static var repoCacheDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/CodeSaver/cache", isDirectory: true)
    }

    /// Download + extraction scratch; deleted after every refresh.
    static var scratchDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/CodeSaver/tmp", isDirectory: true)
    }

    /// Filtered mirrors of the user's local folders, one per folder — kept
    /// apart from the GitHub mirrors so a folder named like a repo can't
    /// clobber it.
    static var folderCacheDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/CodeSaver/folders", isDirectory: true)
    }

    static var corpusExists: Bool {
        guard let dir = corpusDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("corpus.bin").path)
    }

    /// User-supplied spinner verbs ("Gerund<TAB>Past" per line). Lives in the same
    /// directory the corpus does, so the saver's resource-dir chain prefers it
    /// over the bundled list automatically.
    static var verbsURL: URL? { corpusDirectory?.appendingPathComponent("spinner-verbs.txt") }

    // MARK: State

    struct State: Codable {
        var lastSuccess: Date?
        var lastError: String?
        var repoPushedAt: [String: String] = [:]   // manifest: repo → pushed_at
        var repoCount = 0
        var fileCount = 0
        var corpusBytes = 0
        // Everything below is Optional ON PURPOSE: synthesized Decodable
        // requires every non-Optional key, so one new non-Optional field would
        // fail to decode every existing state.json — and loadState() would
        // then hand back an empty manifest and re-download the world.
        var problem: Problem?            // the last run's failure, already in plain words
        var skipped: [Skipped]?          // repos/folders the last run left out, and why
        var progress: Run?               // non-nil while a run is under way (any process)
        var listing: Listing?            // the last GitHub listing — the repo picker's rows

        struct Problem: Codable, Equatable {
            var kind: String             // FetchError.Kind raw value — picks the UI's action
            var headline: String
            var detail: String?
            var resetsAt: Date?
        }

        struct Skipped: Codable, Equatable {
            var name: String
            var isFolder: Bool
            var reason: String
        }

        /// Written by whichever process holds the refresh lock, so the app can
        /// draw a run happening in the hourly agent. `pid` is what tells a live
        /// run from one that was killed mid-flight and never cleared this.
        struct Run: Codable, Equatable {
            var pid: Int32
            var phase: String            // listing | repos | folders | packing
            var done = 0
            var total = 0
            var current: String?
        }

        struct Listing: Codable, Equatable {
            var owner: String
            var repos: [Repo]            // non-forks, the only ones ever fetched
            var forks: Int
            var complete: Bool           // false = hit the page ceiling

            struct Repo: Codable, Equatable {
                var name: String
                var isPrivate: Bool
                var sizeKB: Int
            }
        }
    }

    static var stateURL: URL? { corpusDirectory?.appendingPathComponent("state.json") }

    static func loadState() -> State {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    static func saveState(_ state: State) {
        guard let url = stateURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Atomic replace via rename(2): readers see the old file or the new one,
    /// never a torn write, and in-flight screensaver sessions keep their mmap
    /// of the old inode.
    static func replaceFile(at dest: URL, with source: URL) throws {
        try source.withUnsafeFileSystemRepresentation { src in
            try dest.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { throw POSIXError(.EINVAL) }
                guard rename(src, dst) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    // MARK: Cross-process refresh lock

    /// The app's "Refresh Now" and the `--refresh` LaunchAgent are separate
    /// processes sharing one scratch dir, one repo cache and one pair of
    /// corpus tmp files; nothing in-process can serialize them. An advisory
    /// flock(2) on this file does, and the kernel drops it if the holder dies.
    static var refreshLockURL: URL? { corpusDirectory?.appendingPathComponent(".refresh.lock") }

    /// Held for as long as the token lives, or until `release()`.
    final class RefreshLock: @unchecked Sendable {
        private var fd: Int32
        fileprivate init(fd: Int32) { self.fd = fd }
        deinit { release() }
        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// nil = another process holds the lock (a refresh is mid-flight there).
    /// Throws only when the lock file itself can't be opened.
    static func tryLockRefresh() throws -> RefreshLock? {
        guard let url = refreshLockURL else { throw POSIXError(.ENOENT) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)  // CLOEXEC: tar must not inherit it
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return RefreshLock(fd: fd)
    }
}
