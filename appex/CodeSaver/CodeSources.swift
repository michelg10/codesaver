//
//  CodeSources.swift
//  CodeSaver
//
//  What a refresh fetches: the GitHub connection, which repos, which local
//  folders, and the power rule. The app and the hourly `CodeSaver --refresh`
//  agent are the same bundle, so UserDefaults.standard is one domain
//  (com.michelg10.CodeSaver) for both — the route `GitHubOwner` has always
//  taken. Nothing here lives in the app-group container: these are settings,
//  and "delete downloaded code" must leave them standing. Host app only;
//  Foundation-only so the offline test harness can compile it bare.
//

import Foundation
import CryptoKit

enum CodeSources {
    // MARK: Defaults keys (com.michelg10.CodeSaver)

    /// String. Whose repos to fetch. With a token, empty/unset means the
    /// token's own account; on the public path it IS the connection.
    static let ownerKey = "GitHubOwner"
    /// Bool, default false. true = the "just my public repos" path: list and
    /// download without signing in, never read the Keychain. Explicit rather
    /// than inferred from "no token", so a token that merely failed to read
    /// can never quietly downgrade a private setup to public-only (and prune
    /// every private mirror as "gone").
    static let publicOnlyKey = "GitHubPublicOnly"
    /// String. The account the saved token signs in as — cached at connect and
    /// at every refresh, only so the app can say "connected · <login>"
    /// without a network call.
    static let loginKey = "GitHubLogin"
    /// [String: Bool]. Explicit per-repo choices, true = include. A repo with
    /// no entry follows the default: public in, private out. The key's mere
    /// presence also marks the selection migration as done.
    static let choicesKey = "GitHubRepoChoices"
    /// [[String: Any]], each {path: String, bookmark: Data}. Folders on this
    /// Mac to include, mirrored with the same filters as a GitHub tarball.
    static let foldersKey = "LocalFolders"
    /// Bool, default true. The hourly agent works only on AC power (a missing
    /// corpus is still fetched at once). Refresh Now ignores it.
    static let pluggedInKey = "RefreshOnlyWhenPluggedIn"

    static var defaults: UserDefaults { .standard }

    static var publicOnly: Bool { defaults.bool(forKey: publicOnlyKey) }

    static var owner: String? {
        let owner = defaults.string(forKey: ownerKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return owner.isEmpty ? nil : owner
    }

    static var onlyWhenPluggedIn: Bool {
        defaults.object(forKey: pluggedInKey) as? Bool ?? true
    }

    /// A GitHub username as GitHub allows them — letters, digits, single
    /// inner hyphens, 39 at most. Anything pasted around it (an @, a profile
    /// URL) is peeled off first; nil means it can't be a username at all.
    static func normalizedUsername(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "@"] where s.lowercased().hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasSuffix("/") { s.removeLast() }
        guard (1...39).contains(s.count), !s.hasPrefix("-"), !s.hasSuffix("-"), !s.contains("--"),
              s.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" })
        else { return nil }
        return s
    }

    // MARK: What a refresh reads

    struct Config {
        struct GitHub {
            let token: String?      // nil = public path
            let owner: String?      // nil = the token's own account
        }
        let github: GitHub?         // nil = GitHub not connected
        let folders: [LocalFolder]

        var hasAnySource: Bool { github != nil || !folders.isEmpty }
    }

    /// Reads the Keychain only on the token path. A token path whose token
    /// can't be read is "GitHub not connected" — the refresh then leaves
    /// every GitHub mirror alone rather than guessing.
    static func current(token: () -> String?) -> Config {
        let folders = LocalFolder.load()
        if publicOnly {
            return Config(github: owner.map { .init(token: nil, owner: $0) }, folders: folders)
        }
        return Config(github: token().map { .init(token: $0, owner: owner) }, folders: folders)
    }
}

// MARK: - Repo selection

enum RepoSelection {
    /// THE rule, shared by the picker's checkboxes and the refresh: an
    /// explicit choice wins; otherwise public repos are in and private repos
    /// are out (opt-in) — including repos that only appear later.
    static func isSelected(_ name: String, isPrivate: Bool, choices: [String: Bool]) -> Bool {
        choices[name] ?? !isPrivate
    }

    static func choices(_ defaults: UserDefaults = CodeSources.defaults) -> [String: Bool] {
        defaults.dictionary(forKey: CodeSources.choicesKey) as? [String: Bool] ?? [:]
    }

    static func setChoices(_ choices: [String: Bool], _ defaults: UserDefaults = CodeSources.defaults) {
        defaults.set(choices, forKey: CodeSources.choicesKey)
    }

    /// An install from before the picker keeps exactly the repos it has now —
    /// private ones included — as explicit choices, so a setup that fetched
    /// everything doesn't silently shrink to public-only on upgrade. Runs once
    /// (the key's presence is the marker), and before any refresh can prune;
    /// the app and the agent may race to it and write the same answer.
    static func migrateIfNeeded(_ defaults: UserDefaults = CodeSources.defaults,
                                existing: () -> Set<String> = existingRepos) {
        guard defaults.object(forKey: CodeSources.choicesKey) == nil else { return }
        var choices: [String: Bool] = [:]
        for name in existing() { choices[name] = true }
        setChoices(choices, defaults)
    }

    /// Repos the current install already holds: the pushed_at manifest, every
    /// mirror on disk, and every repo the packed index names — any one of them
    /// alone means the user has that code today. (Before this release the
    /// index only ever held GitHub repos, and migration runs before the first
    /// build that could add a folder to it.)
    static func existingRepos() -> Set<String> {
        var names = Set(CorpusStore.loadState().repoPushedAt.keys)
        if let cache = CorpusStore.repoCacheDirectory {
            names.formUnion(CorpusIngest.mirrorDirectories(in: cache).map(\.lastPathComponent))
        }
        if let index = CorpusStore.corpusDirectory?.appendingPathComponent("corpus-index.json"),
           let data = try? Data(contentsOf: index),
           let repos = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            names.formUnion(repos.keys)
        }
        return names
    }
}

// MARK: - Local folders

struct LocalFolder: Equatable, Identifiable {
    let path: String
    let bookmark: Data?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    /// ~/Documents/x rather than /Users/me/Documents/x.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    /// The mirror's directory name: readable, but unique per path — two
    /// folders both called `src` must not share a mirror.
    var mirrorName: String {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return "\(safe.prefix(60))-\(digest)"
    }

    /// From an open-panel URL. A security-scoped bookmark is what lets a
    /// LATER process — the hourly agent — reopen a folder the user picked
    /// here, where macOS would otherwise keep a background job out of
    /// Desktop/Documents/Downloads; a plain bookmark still follows a moved
    /// folder. Either may be refused, and the path alone still works for
    /// unprotected locations.
    static func make(from url: URL) -> LocalFolder {
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                              includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        return LocalFolder(path: url.standardizedFileURL.path, bookmark: bookmark)
    }

    /// The folder's URL, with its security scope entered when the bookmark
    /// carries one — pair with `stopAccessingSecurityScopedResource()`.
    /// Never mounts a volume or shows UI: this runs in the background.
    func open() -> (url: URL, scoped: Bool) {
        if let bookmark {
            var stale = false
            for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI, .withoutMounting],
                                                           [.withoutUI, .withoutMounting]] {
                if let url = try? URL(resolvingBookmarkData: bookmark, options: options,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    return (url, url.startAccessingSecurityScopedResource())
                }
            }
        }
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    // MARK: Persistence

    static func load(_ defaults: UserDefaults = CodeSources.defaults) -> [LocalFolder] {
        let raw = defaults.array(forKey: CodeSources.foldersKey) as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
            return LocalFolder(path: path, bookmark: entry["bookmark"] as? Data)
        }
    }

    static func save(_ folders: [LocalFolder], _ defaults: UserDefaults = CodeSources.defaults) {
        if folders.isEmpty {
            defaults.removeObject(forKey: CodeSources.foldersKey)
            return
        }
        defaults.set(folders.map { f -> [String: Any] in
            var entry: [String: Any] = ["path": f.path]
            if let b = f.bookmark { entry["bookmark"] = b }
            return entry
        }, forKey: CodeSources.foldersKey)
    }

    /// A folder too broad to mirror usefully — the whole disk or home folder
    /// would walk hundreds of thousands of files for a 200 MB slice of them.
    static func isTooBroad(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == "/" || p == NSHomeDirectory() || p == "/Users" || p == "/Volumes"
    }

    // MARK: Why a folder couldn't be read

    /// The macOS-protected place a path sits in, by the name the user knows.
    static func protectedArea(of path: String) -> String? {
        let home = NSHomeDirectory()
        let areas = [("Desktop", "your Desktop"), ("Documents", "Documents"),
                     ("Downloads", "Downloads"), ("Library/Mobile Documents", "iCloud Drive")]
        for (dir, label) in areas where path == "\(home)/\(dir)" || path.hasPrefix("\(home)/\(dir)/") {
            return label
        }
        if path.hasPrefix("/Volumes/") { return "an external or network disk" }
        return nil
    }

    /// Plain words for a failed read, for "couldn't read <folder> — <reason>".
    /// EPERM is macOS's privacy wall (the agent runs with nobody at the
    /// screen to ask); EACCES is ordinary file permissions.
    static func reason(for error: Error, path: String) -> String {
        let ns = error as NSError
        let posix = (ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError)
            .flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        switch posix {
        case Int(EPERM):
            let area = protectedArea(of: path) ?? "this folder"
            return "macOS keeps background refreshes out of \(area) — use Refresh Now while this window is open, or allow CodeSaver under Privacy & Security › Files and Folders"
        case Int(EACCES):
            return "your account isn't allowed to read it"
        case Int(ENOENT), Int(ENOTDIR):
            if path.hasPrefix("/Volumes/") { return "its disk isn't connected" }
            return "it isn't there any more — moved or deleted? remove it and add it again"
        default:
            break
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError:
                return "macOS didn't allow reading it — allow CodeSaver under Privacy & Security › Files and Folders"
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return "it isn't there any more — moved or deleted? remove it and add it again"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Disk

enum DownloadedCode {
    /// What deleting would free: the packed text plus every mirror and any
    /// scratch left by an interrupted run. Allocated size, the number Finder
    /// shows. Walks every mirrored file — call off the main thread.
    static func bytesOnDisk() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func add(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        if let dir = CorpusStore.corpusDirectory {
            for name in ["corpus.bin", "corpus-index.json"] { add(dir.appendingPathComponent(name)) }
        }
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { continue }
            while let url = e.nextObject() as? URL { add(url) }
        }
        return total
    }

    /// Mirrors and scratch — everything under Caches the refresh owns.
    static var roots: [URL] {
        [CorpusStore.repoCacheDirectory, CorpusStore.folderCacheDirectory, CorpusStore.scratchDirectory]
            .compactMap { $0 }
    }
}
