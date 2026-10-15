//
//  GitHubCorpusFetcher.swift
//  CodeSaver
//
//  Native GitHub fetch + corpus build (host app only). Swift port of the
//  retired ingest.py / make_corpus.py pipeline: mirror non-fork repos (and
//  the user's local folders) into the app-group cache, then pack every
//  cleaned source file whole into corpus.bin with a repo-keyed byte index.
//  The saver samples and weights at runtime.
//

import Foundation
import CryptoKit
import Darwin

/// Every way talking to GitHub — or packing what came back — goes wrong, in
/// the words the app shows for it. This is the ONE place a status code, a
/// URLError or an empty build becomes a sentence: the UI and state.json only
/// ever see `headline`/`detail`, so no raw URL or bare HTTP code can reach a
/// headline.
enum FetchError: LocalizedError, Equatable {
    case tokenRejected                               // 401
    case rateLimited(resetsAt: Date?, signedIn: Bool) // 403/429 with the allowance spent
    case forbidden                                   // 403 that isn't the limit
    case noSuchUser(String)                          // 404 on a user's profile or listing
    case notFound                                    // 404 on one repo's download
    case offline                                     // no network, DNS, timeout
    case server(Int)                                 // 5xx, or any status nobody planned for
    case badResponse                                 // 2xx we couldn't parse
    case tarFailed
    case tooBig(bytes: Int)
    case emptyCorpus(String)                         // what was found, and why none of it counts

    /// Picks the UI's action (Replace token, a reset time, …) — stored in
    /// state.json, so the raw values are a file format.
    enum Kind: String {
        case tokenRejected, rateLimited, forbidden, noSuchUser, offline, empty, github, other
    }

    var kind: Kind {
        switch self {
        case .tokenRejected: return .tokenRejected
        case .rateLimited: return .rateLimited
        case .forbidden: return .forbidden
        case .noSuchUser: return .noSuchUser
        case .offline: return .offline
        case .emptyCorpus: return .empty
        case .notFound, .server, .badResponse, .tarFailed, .tooBig: return .github
        }
    }

    // MARK: Classification

    /// A non-2xx response. `missing` is what a 404 means at this call site —
    /// no such user for a listing, a vanished repo for a download.
    static func from(_ http: HTTPURLResponse, signedIn: Bool, missing: FetchError) -> FetchError {
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
        let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        let status = http.statusCode
        if status == 401 { return .tokenRejected }
        // GitHub signals both its hourly limit and its abuse throttle as 403
        // or 429; only the headers tell a spent allowance from a refusal.
        if status == 429 || (status == 403 && (remaining == "0" || retryAfter != nil)) {
            let resetsAt = retryAfter.map { Date().addingTimeInterval($0) }
                ?? reset.map { Date(timeIntervalSince1970: $0) }
            return .rateLimited(resetsAt: resetsAt, signedIn: signedIn)
        }
        if status == 403 { return .forbidden }
        if [404, 410, 451].contains(status) { return missing }
        return .server(status)
    }

    /// Anything thrown on the way: URLErrors become `.offline`/`.badResponse`,
    /// decoding failures `.badResponse`; our own errors pass through.
    static func wrap(_ error: Error) -> Error {
        if error is FetchError || error is CancellationError { return error }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .timedOut, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed, .callIsActive, .secureConnectionFailed:
                // secureConnectionFailed is what a captive portal looks like.
                return FetchError.offline
            default:
                return FetchError.badResponse
            }
        }
        if error is DecodingError { return FetchError.badResponse }
        return error
    }

    /// Failures that will hit every remaining repo the same way: a run stops
    /// at the first one instead of logging it twenty times.
    var abortsRun: Bool {
        switch self {
        case .tokenRejected, .rateLimited, .offline: return true
        default: return false
        }
    }

    // MARK: Words

    var errorDescription: String? { headline }

    var headline: String {
        switch self {
        case .tokenRejected:
            return "GitHub rejected the saved token — it has expired or was revoked"
        case .rateLimited(let resetsAt, _):
            return "GitHub's hourly request limit is used up — \(Self.whenReset(resetsAt))"
        case .forbidden:
            return "GitHub refused access — the token doesn't reach these repos"
        case .noSuchUser(let name):
            return "there's no GitHub user called \(name)"
        case .notFound:
            return "GitHub couldn't find a repo — it was renamed, deleted or is empty"
        case .offline:
            return "can't reach GitHub — offline? the next refresh will retry"
        case .server, .badResponse:
            return "GitHub isn't answering properly right now — the next refresh will retry"
        case .tarFailed:
            return "a download from GitHub arrived damaged — the next refresh will retry"
        case .tooBig(let bytes):
            return "too big to download (\(Self.size(bytes)))"
        case .emptyCorpus:
            return "found no code to show"
        }
    }

    /// The second line, where specifics belong. The only place a status code
    /// may appear, and then only for the "GitHub is broken" case.
    var detail: String? {
        switch self {
        case .tokenRejected:
            return "replace it with a new one — nothing downloaded so far is lost"
        case .rateLimited(_, let signedIn):
            return signedIn ? nil
                : "without a token GitHub allows 60 requests an hour; a token raises that to 5,000"
        case .forbidden:
            return "make a token with access to all repositories (or the ones you want) and Contents: read-only"
        case .server(let code):
            return "GitHub answered with error \(code)"
        case .emptyCorpus(let why):
            return why
        default:
            return nil
        }
    }

    /// The connect step's version: the same failure reads differently before
    /// anything was saved than it does about a token that used to work.
    var connectMessage: String {
        switch self {
        case .tokenRejected:
            return "GitHub didn't accept that token — check it was copied whole and hasn't expired"
        case .forbidden:
            return "GitHub accepted the token but won't list your account with it — make a new one as described above"
        case .offline:
            return "can't reach GitHub — check your connection and try again"
        default:
            return headline
        }
    }

    /// Short form for the skipped-repos list.
    var repoReason: String {
        switch self {
        case .tokenRejected: return "the token was rejected"
        case .rateLimited: return "hit GitHub's hourly limit"
        case .forbidden: return "the token has no access to it"
        case .notFound, .noSuchUser: return "not found — renamed, deleted or empty"
        case .offline: return "couldn't reach GitHub"
        case .server(let code): return "GitHub error \(code)"
        case .badResponse: return "GitHub sent something unreadable"
        case .tarFailed: return "the download arrived damaged"
        case .tooBig(let bytes): return "too big to download (\(Self.size(bytes)))"
        case .emptyCorpus: return "no source files"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A clock time, never "in 30 minutes": the headline is stored in
    /// state.json and read whenever the window next opens.
    static func whenReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date > now else { return "try again in an hour" }
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .short
        f.timeStyle = .short
        return "resets at \(f.string(from: date))"
    }

    /// What state.json keeps of a failed run. Errors that aren't GitHub's —
    /// a full disk, a missing container — keep their system description.
    static func problem(for error: Error) -> CorpusStore.State.Problem {
        switch error {
        case let fetch as FetchError:
            var resetsAt: Date?
            if case .rateLimited(let at, _) = fetch { resetsAt = at }
            return .init(kind: fetch.kind.rawValue, headline: fetch.headline,
                         detail: fetch.detail, resetsAt: resetsAt)
        default:
            return .init(kind: Kind.other.rawValue,
                         headline: error.localizedDescription, detail: nil, resetsAt: nil)
        }
    }
}

// MARK: - GitHub API

struct GitHubRepo: Decodable, Equatable {
    let name: String
    let fork: Bool
    let pushedAt: String?
    let isPrivate: Bool
    let sizeKB: Int          // GitHub's own figure: the whole repo, history included

    enum CodingKeys: String, CodingKey {
        case name, fork, size
        case pushedAt = "pushed_at"
        case isPrivate = "private"
    }

    init(name: String, fork: Bool = false, pushedAt: String? = nil,
         isPrivate: Bool = false, sizeKB: Int = 0) {
        self.name = name
        self.fork = fork
        self.pushedAt = pushedAt
        self.isPrivate = isPrivate
        self.sizeKB = sizeKB
    }

    // Lenient: a listing that drops `size` or `private` must not fail the
    // whole decode — unknown size means "try it", unknown visibility "public"
    // only when GitHub would never have shown us a private repo anyway.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        fork = try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false
        pushedAt = try c.decodeIfPresent(String.self, forKey: .pushedAt)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        sizeKB = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}

/// `token == nil` is the "just my public repos" path: listings come from the
/// unauthenticated API (60 requests an hour per IP — a listing is one request
/// per hundred repos) and tarballs from codeload, which that limit doesn't
/// count.
struct GitHubClient {
    let token: String?

    private func request(_ urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw FetchError.badResponse }
        var req = URLRequest(url: url)
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("CodeSaver", forHTTPHeaderField: "User-Agent")  // GitHub rejects UA-less requests
        return req
    }

    private func get(_ urlString: String, missing: FetchError) async throws -> Data {
        do {
            let (data, resp) = try await URLSession.shared.data(for: try request(urlString))
            guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.from(http, signedIn: token != nil, missing: missing)
            }
            return data
        } catch {
            throw FetchError.wrap(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw FetchError.badResponse }
    }

    private struct User: Decodable { let login: String }

    /// GET /user — who the token signs in as. This is the token's validation:
    /// a 401 here means the token is wrong, not that something else failed.
    func currentLogin() async throws -> String {
        try decode(User.self, try await get("https://api.github.com/user", missing: .tokenRejected)).login
    }

    /// GET /users/<name> — the public path's validation, and the account's
    /// canonical spelling (what the listing and codeload expect).
    func userLogin(_ name: String) async throws -> String {
        guard let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FetchError.noSuchUser(name)
        }
        return try decode(User.self, try await get("https://api.github.com/users/\(path)",
                                                    missing: .noSuchUser(name))).login
    }

    struct RepoListing {
        let repos: [GitHubRepo]   // non-forks only
        let forks: Int            // dropped from `repos` — counted for "found nothing" explanations
        /// The raw walk filled every page it is allowed, so repos past it were
        /// never seen — their absence from `repos` means nothing.
        let hitCeiling: Bool
    }

    /// Non-fork repos owned by `owner` — what `gh repo list OWNER --source`
    /// used to return. Private repos appear only when `owner` is the token's
    /// own account (the /user/repos listing); `ownLogin` is nil without one.
    func listSourceRepos(owner: String, ownLogin: String?) async throws -> RepoListing {
        guard let path = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FetchError.noSuchUser(owner)
        }
        let base = owner.lowercased() == ownLogin?.lowercased()
            ? "https://api.github.com/user/repos?affiliation=owner"
            : "https://api.github.com/users/\(path)/repos?type=owner"
        var repos: [GitHubRepo] = []
        var hitCeiling = true
        for page in 1...10 {  // 1000-repo ceiling, same spirit as the old REPO_LIMIT
            let batch = try decode([GitHubRepo].self,
                                   try await get("\(base)&per_page=100&page=\(page)",
                                                 missing: .noSuchUser(owner)))
            repos.append(contentsOf: batch)
            if batch.count < 100 { hitCeiling = false; break }
        }
        // Forks are dropped AFTER the ceiling check: the filtered count says
        // nothing about whether the raw listing was complete.
        let sources = repos.filter { !$0.fork }
        return RepoListing(repos: sources, forks: repos.count - sources.count, hitCeiling: hitCeiling)
    }

    /// Downloads the repo tarball to a temp file, streamed to disk (constant
    /// memory). With a token: the API endpoint, which redirects to a signed
    /// codeload URL and works for private repos. Without one: codeload
    /// directly — HEAD is the default branch — so tarballs never spend the
    /// 60-an-hour API allowance.
    func downloadTarball(owner: String, repo: String) async throws -> URL {
        guard let o = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let r = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FetchError.notFound
        }
        let url = token == nil
            ? "https://codeload.github.com/\(o)/\(r)/tar.gz/HEAD"
            : "https://api.github.com/repos/\(o)/\(r)/tarball"
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: try request(url))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
                throw FetchError.from(http, signedIn: token != nil, missing: .notFound)
            }
            return tmp
        } catch {
            throw FetchError.wrap(error)
        }
    }
}


// MARK: - Filtering + corpus packing (ports of ingest.py / make_corpus.py)

enum CorpusIngest {
    static let allowedExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "c", "cc", "cpp", "h", "hpp",
        "m", "mm", "rs", "go", "java", "kt", "rb", "sh", "zsh", "css", "scss",
        "html", "vue", "svelte", "sql", "metal", "cu", "hs", "ml", "lua", "jl",
    ]
    static let skipDirs: Set<String> = [
        "node_modules", ".git", "build", "dist", ".build", "Pods", "vendor", "venv",
        ".venv", "__pycache__", "DerivedData", ".next", "target", "out", ".cache",
    ]
    static let generatedPatterns = [
        "*.min.js", "*.min.css", "*_pb2.py", "*.pb.go", "*.pb.cc", "*.pb.h",
        "*.generated.*", "*.g.dart", "*.bundle.js", "*.map",
    ]
    static let minSize = 64, maxSize = 200_000
    static let maxDirFiles = 150              // more source files than this in one dir → vendored/generated
    static let maxRepoBytes = 200 * 1024 * 1024
    static let maxTarballBytes = 300 * 1024 * 1024
    /// Entries one walk may visit. A tarball never gets near it; a local
    /// folder can be someone's whole disk, and this bounds that walk.
    static let maxWalkEntries = 400_000
    static let maxLineLength = 200
    static let minLines = 4
    static let maxSecretHits = 3              // a file this secret-dense is dropped entirely

    // This text renders on an always-visible screen, so scrub aggressively —
    // a false positive only blanks one line of screensaver background.
    static let secretRegexes: [NSRegularExpression] = {
        let patterns: [(String, NSRegularExpression.Options)] = [
            // key-ish identifier (with any tail, so password/SECRET_KEY/aws_access_key_id
            // all match) directly assigned — bare (API_KEY = …), or quoted /
            // subscripted the way dict, JSON and header literals spell it
            // ("api_key": …, 'password': …, config["token"] = …)
            //
            // The punctuation classes carry the FULLWIDTH forms too. CJK source
            // is written with them — `api_key ："…"`, `密钥＝"…"`, 「token」 for
            // quotes — and an ASCII-only [:=] walked straight past every one of
            // those, leaving the literal on screen. Same reason the identifier
            // list names the words a Chinese, Japanese or Korean codebase
            // actually uses; `\w` is already Unicode-aware in ICU, so the tail
            // matches 密钥_测试 as happily as api_key_test. A false positive
            // still only blanks one line of screensaver background.
            ("(api[_-]?key|passw|passwd|pwd|secret|token|credential"
             + "|private[_-]?key|access[_-]?key|signing[_-]?key|auth"
             + "|密码|密碼|密钥|密鑰|口令|令牌|秘密|凭证|憑證"
             + "|パスワード|トークン|秘密鍵|認証"
             + "|비밀번호|암호|토큰|인증)"
             + "[\\w-]*[\\s\"'\\]”’」』）］]*[:=：＝]", [.caseInsensitive]),
            // value-shaped: known token prefixes, JWTs, creds-in-URL
            ("AKIA[0-9A-Z]{16}", []),
            ("\\bghp_[A-Za-z0-9]{20,}|\\bgithub_pat_[A-Za-z0-9_]{20,}", []),
            ("\\bsk-[A-Za-z0-9_-]{20,}", []),
            ("\\bxox[baprs]-[A-Za-z0-9-]{10,}", []),
            ("\\bAIza[0-9A-Za-z_-]{30,}", []),
            ("\\beyJ[A-Za-z0-9_-]{10,}\\.", []),
            ("://[^/\\s:]+:[^@\\s]+@", []),
        ]
        return patterns.map { try! NSRegularExpression(pattern: $0.0, options: $0.1) }
    }()
    static let pemRegex = try! NSRegularExpression(pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----")

    /// Cc/Cf/illegal, MINUS the two zero-width joiners. `controlCharacters` is
    /// Cc *and Cf*, and U+200D ZWJ is Cf: stripping it shattered every ZWJ
    /// emoji sequence into its pieces (👨‍👩‍👧‍👦 became four glyphs, four cells
    /// wide instead of two) and broke ZWNJ-dependent scripts. Everything else
    /// Cf still goes — BOM, bidi overrides, the invisible separators a
    /// screensaver must never render.
    private static let unprintable = CharacterSet.controlCharacters
        .union(.newlines).union(.illegalCharacters)
        .subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))

    static func wanted(relPath: String, size: Int) -> Bool {
        let parts = relPath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { skipDirs.contains($0) || $0.hasPrefix(".") }) {
            return false
        }
        if generatedPatterns.contains(where: { fnmatch($0, name, 0) == 0 }) { return false }
        guard allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
            return false
        }
        return size > minSize && size < maxSize
    }

    /// Extract a downloaded tarball and mirror its wanted source files into
    /// cache/<repo>/, wholesale-replacing any previous mirror. Returns the
    /// number of files kept.
    static func syncRepo(named repo: String, tarball: URL, cacheDir: URL, scratchDir: URL) throws -> Int {
        let fm = FileManager.default
        let extractDir = scratchDir.appendingPathComponent(repo, isDirectory: true)
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // --strip-components 1 drops the owner-repo-sha/ prefix GitHub adds.
        tar.arguments = ["-x", "-z", "-f", tarball.path, "-C", extractDir.path, "--strip-components", "1"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw FetchError.tarFailed }

        let dest = cacheDir.appendingPathComponent(repo, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)  // marker even for repos with no source files
        return mirrorTree(from: extractDir, into: dest)
    }

    /// Mirror a folder on this Mac the same way a tarball is mirrored — same
    /// walk, same filters. Unlike a tarball the source can be unreadable (moved,
    /// unmounted, or a folder macOS keeps background processes out of), so the
    /// root is opened first and its error thrown as-is for the caller to put
    /// into words; the walk then builds in scratch and swaps in whole, so a
    /// run that can't read the folder leaves its previous mirror standing.
    static func mirrorFolder(at root: URL, into dest: URL, scratchDir: URL) throws -> Int {
        let fm = FileManager.default
        _ = try fm.contentsOfDirectory(atPath: root.path)
        let staging = scratchDir.appendingPathComponent("folder-" + dest.lastPathComponent,
                                                        isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let kept = mirrorTree(from: root, into: staging)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)
        return kept
    }

    /// The one walk both sources share: copy every wanted file under `root`
    /// into `dest` (which exists), then prune bulk directories. Returns the
    /// number of files kept.
    private static func mirrorTree(from root: URL, into dest: URL) -> Int {
        let fm = FileManager.default
        var kept = 0, written = 0, visited = 0
        // Walk by RELATIVE path. The old walk took the absolute URL the
        // enumerator handed back and trimmed `extractDir.path.count + 1`
        // Characters off the front — two counts that have to agree and don't:
        // `enumerator(at:)` returns symlink-RESOLVED paths (/private/tmp/… for
        // a /tmp base), and on an HFS+ volume it returns decomposed filenames
        // while the URL we built holds composed ones, where 한 is three
        // Characters on one side and one on the other. Either mismatch slices
        // the relative path in the wrong place, and every file then fails
        // `wanted` or lands at a bogus depth in the mirror.
        // `enumerator(atPath:)` yields the relative path itself — nothing to
        // measure. Its attributes come from lstat, so a symlink is not a
        // regular file and is skipped, which is also what we want: copying one
        // only ever put a dangling link in the mirror.
        let enumerator = fm.enumerator(atPath: root.path)
        while let rel = enumerator?.nextObject() as? String {
            visited += 1
            if visited > maxWalkEntries { break }
            guard let attrs = enumerator?.fileAttributes else { continue }
            // Don't descend where `wanted` would refuse every file anyway —
            // pure speed for a tarball, the difference between seconds and
            // minutes for a local checkout full of node_modules.
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                let name = (rel as NSString).lastPathComponent
                if skipDirs.contains(name) || name.hasPrefix(".") { enumerator?.skipDescendants() }
                continue
            }
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard wanted(relPath: rel, size: size) else { continue }
            if written + size > maxRepoBytes { break }
            let url = root.appendingPathComponent(rel)
            let target = dest.appendingPathComponent(rel)
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: url, to: target)) != nil else { continue }
            kept += 1
            written += size
        }
        pruneBulkDirs(dest)
        return kept
    }

    /// Bottom-up: any subdirectory holding an implausible number of source
    /// files is vendored/generated — drop it whole. The mirror root itself is
    /// exempt: a flat repo (a solutions dump, a script collection) keeps its
    /// top-level files, bounded by the per-file filters and maxRepoBytes;
    /// deleting the root would drop the repo and its marker, so it would
    /// re-download on every refresh and never reach the corpus.
    private static func pruneBulkDirs(_ root: URL) {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let url = e.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    dirs.append(url)
                }
            }
        }
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {  // children before parents
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            let fileCount = entries.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }.count
            if fileCount > maxDirFiles { try? fm.removeItem(at: dir) }
        }
    }

    // MARK: Line cleaning

    /// Cells one character occupies in a terminal — 2 for East Asian Wide and
    /// Fullwidth (UAX #11 W/F) and for emoji presentation, 1 otherwise. There
    /// is no East-Asian-Width in `Unicode.Scalar.Properties`, and this file
    /// runs with no font loaded, so it classifies by scalar range. The saver's
    /// renderer measures the real glyph instead; the two agree on everything
    /// that matters here (tab stops), and this side never needs to be exact —
    /// only to stop counting 漢 as one column.
    static func cells(_ ch: Character) -> Int {
        guard let u = ch.unicodeScalars.first, u.value >= 0x1100 else { return 1 }
        switch u.value {
        case 0x1100...0x115F,            // Hangul Jamo initial
             0x2E80...0x303E,            // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,            // kana, Hangul compat jamo, CJK compat
             0x3400...0x4DBF,            // CJK ext A
             0x4E00...0x9FFF,            // CJK unified
             0xA000...0xA4CF,            // Yi
             0xAC00...0xD7A3,            // Hangul syllables
             0xF900...0xFAFF,            // CJK compat ideographs
             0xFE10...0xFE19,            // vertical forms
             0xFE30...0xFE6F,            // CJK compat forms, small forms
             0xFF00...0xFF60,            // fullwidth forms
             0xFFE0...0xFFE6,            // fullwidth signs
             0x1F300...0x1F64F,          // emoji
             0x1F900...0x1F9FF,
             0x20000...0x3FFFD:          // CJK ext B+
            return 2
        default:
            return 1
        }
    }

    /// Tab stops the way the author's editor set them: a wide character
    /// advances the column by two. Counting every character as one column put
    /// the stops in the wrong place for every CJK-bearing line, so indentation
    /// that lined up in the repo arrived ragged.
    private static func expandTabs(_ s: some StringProtocol, width: Int = 4) -> String {
        guard s.contains("\t") else { return String(s) }
        var out = ""
        var col = 0
        for ch in s {
            if ch == "\t" {
                let pad = width - (col % width)
                out += String(repeating: " ", count: pad)
                col += pad
            } else {
                out.append(ch)
                col += cells(ch)
            }
        }
        return out
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A source file's text, or nil when nothing can read it confidently.
    ///
    /// `String(decoding:as: UTF8.self)` NEVER fails — it substitutes U+FFFD
    /// for every byte it can't parse — so a Shift-JIS or GB18030 source (still
    /// common in CJK repos) used to be packed into the corpus as a solid wall
    /// of replacement characters and typed across the screen as ����. It also
    /// sailed through every filter below, U+FFFD being a perfectly printable
    /// character.
    ///
    /// So: decode strictly, and only then guess. The guess is Foundation's own
    /// detector (what TextEdit's "guess encoding" runs) — the legacy CJK
    /// codecs overlap far too much to pick between by trial decode, since
    /// Shift-JIS happily accepts GB18030 bytes and returns fluent-looking
    /// nonsense. A file that neither path can read is dropped rather than
    /// shipped as mojibake.
    static func decodeSource(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let enc = NSString.stringEncoding(for: data, encodingOptions: nil,
                                          convertedString: &converted,
                                          usedLossyConversion: &lossy)
        guard enc != 0, !lossy.boolValue, let s = converted as String?,
              !s.unicodeScalars.contains("\u{FFFD}") else { return nil }
        return s
    }

    /// nil = drop the whole file.
    static func cleanLines(_ raw: String) -> [String]? {
        // NFC first. Music metadata, HFS+ paths and plenty of repos carry
        // decomposed text (한 as ᄒ+ᅡ+ᆫ, が as か+゛); composed is the form the
        // renderer measures cleanly and the one every other stage assumes.
        let normalized = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var longCount = 0, secretHits = 0
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = expandTabs(rawLine)
            var scalars = String.UnicodeScalarView()
            for u in line.unicodeScalars where u == " " || !unprintable.contains(u) {
                scalars.append(u)
            }
            line = String(scalars)
            while let last = line.unicodeScalars.last, CharacterSet.whitespaces.contains(last) {
                line.unicodeScalars.removeLast()
            }
            if matches(pemRegex, line) { return nil }  // never sample a file holding key material
            if secretRegexes.contains(where: { matches($0, line) }) {
                secretHits += 1
                line = ""
            }
            // CHARACTERS, deliberately — not bytes and not cells. Bytes would
            // reject a CJK line at a third of the length of an ASCII one and
            // cut it mid-sequence; cells would make the "too many long lines →
            // minified" heuristic below fire on ordinary Chinese source and
            // throw the file away. `prefix` on a String walks grapheme
            // clusters, so the cut can never split a character or an emoji
            // sequence. Over-long lines are the writer's problem, and it
            // already clips to the screen by measured cell width.
            if line.count > maxLineLength {
                longCount += 1
                line = String(line.prefix(maxLineLength))
            }
            lines.append(line)
        }
        if secretHits >= maxSecretHits { return nil }
        if lines.isEmpty || longCount * 10 > lines.count * 3 { return nil }  // likely minified/generated
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.count >= minLines ? lines : nil
    }

    // MARK: Corpus packing

    struct BuildResult {
        var repoCount = 0
        var fileCount = 0
        var bytes = 0
    }

    struct Source {
        let name: String
        let dir: URL
    }

    /// The per-repo (or per-folder) mirror directories under one cache root.
    static func mirrorDirectories(in root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// Packs the given mirrors into corpus.bin + corpus-index.json, deduplicating
    /// identical files across repos by content hash, then swaps both into place
    /// with two rename(2)s, bin first. Each rename is atomic but the pair is
    /// not, so the reader binds an index to its exact bin: every block must fit
    /// AND the bin's byte count must equal the index's last offset+length. A
    /// reader that catches the pair mid-swap (new bin with the old index, or
    /// old bin with the new) fails that check and falls back for one session
    /// instead of slicing the bin at the wrong boundaries.
    ///
    /// `sources` names each mirror's index key: a GitHub mirror is keyed by its
    /// repo, a folder mirror by the folder's own name — so the saver's
    /// per-repo weighting treats a folder like one more repo, and a folder
    /// that IS a checkout of a listed repo merges into that repo's key.
    static func buildCorpus(sources: [Source], corpusDir: URL) throws -> BuildResult {
        let fm = FileManager.default
        try fm.createDirectory(at: corpusDir, withIntermediateDirectories: true)
        let binTmp = corpusDir.appendingPathComponent("corpus.bin.tmp")
        let idxTmp = corpusDir.appendingPathComponent("corpus-index.json.tmp")
        fm.createFile(atPath: binTmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: binTmp)

        var index: [String: [[Int]]] = [:]
        var seen = Set<Data>()  // SHA-1 digests: same file vendored into several repos
        var offset = 0
        var result = BuildResult()

        for source in sources.sorted(by: { ($0.name, $0.dir.path) < ($1.name, $1.dir.path) }) {
            let repo = source.name, repoDir = source.dir
            var files: [URL] = []
            if let e = fm.enumerator(at: repoDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = e.nextObject() as? URL {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        files.append(url)
                    }
                }
            }
            for fileURL in files.sorted(by: { $0.path < $1.path }) {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let digest = Data(Insecure.SHA1.hash(data: data))
                guard !seen.contains(digest) else { continue }
                seen.insert(digest)
                guard let text = decodeSource(data), let lines = cleanLines(text) else { continue }
                let block = Data((lines.joined(separator: "\n") + "\n").utf8)
                try out.write(contentsOf: block)
                index[repo, default: []].append([offset, block.count])
                offset += block.count
                result.fileCount += 1
            }
        }
        try out.close()
        result.repoCount = index.count
        result.bytes = offset

        guard result.fileCount > 0 else {
            try? fm.removeItem(at: binTmp)
            throw FetchError.emptyCorpus("")  // the caller knows what was fetched; it explains
        }
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: idxTmp)
        try CorpusStore.replaceFile(at: corpusDir.appendingPathComponent("corpus.bin"), with: binTmp)
        try CorpusStore.replaceFile(at: corpusDir.appendingPathComponent("corpus-index.json"), with: idxTmp)
        return result
    }
}
