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

    /// Per-repo filtered mirror of GitHub (what ingest/cache/ used to be).
    static var repoCacheDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/CodeSaver/cache", isDirectory: true)
    }

    /// Download + extraction scratch; deleted after every refresh.
    static var scratchDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/CodeSaver/tmp", isDirectory: true)
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
}
