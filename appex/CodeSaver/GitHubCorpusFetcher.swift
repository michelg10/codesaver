//
//  GitHubCorpusFetcher.swift
//  CodeSaver
//
//  Native GitHub fetch + corpus build (host app only). Swift port of the
//  retired ingest.py / make_corpus.py pipeline: mirror non-fork repos into the
//  app-group cache, then pack every cleaned source file whole into corpus.bin
//  with a repo-keyed byte index. The saver samples and weights at runtime.
//

import Foundation
import CryptoKit
import Darwin

enum FetchError: LocalizedError {
    case badResponse
    case http(Int, String)
    case tarFailed(String)
    case emptyCorpus

    var errorDescription: String? {
        switch self {
        case .badResponse: return "unexpected response from GitHub"
        case .http(let code, let context): return "GitHub HTTP \(code) (\(context))"
        case .tarFailed(let repo): return "tar extraction failed for \(repo)"
        case .emptyCorpus: return "fetched zero usable source files — existing corpus left untouched"
        }
    }
}

// MARK: - GitHub API

struct GitHubRepo: Decodable {
    let name: String
    let fork: Bool
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, fork
        case pushedAt = "pushed_at"
    }
}

struct GitHubClient {
    let token: String

    private func request(_ urlString: String) -> URLRequest {
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("CodeSaver", forHTTPHeaderField: "User-Agent")  // GitHub rejects UA-less requests
        return req
    }

    private func get(_ urlString: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request(urlString))
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(http.statusCode, urlString)
        }
        return data
    }

    func currentLogin() async throws -> String {
        struct User: Decodable { let login: String }
        return try JSONDecoder().decode(User.self, from: try await get("https://api.github.com/user")).login
    }

    struct RepoListing {
        let repos: [GitHubRepo]   // non-forks only
        /// The raw walk filled every page it is allowed, so repos past it were
        /// never seen — their absence from `repos` means nothing.
        let hitCeiling: Bool
    }

    /// Non-fork repos owned by `owner` — what `gh repo list OWNER --source`
    /// used to return. Private repos appear only when `owner` is the token's
    /// own account (the /user/repos listing).
    func listSourceRepos(owner: String, ownLogin: String) async throws -> RepoListing {
        let base = owner.lowercased() == ownLogin.lowercased()
            ? "https://api.github.com/user/repos?affiliation=owner"
            : "https://api.github.com/users/\(owner)/repos?type=owner"
        var repos: [GitHubRepo] = []
        var hitCeiling = true
        for page in 1...10 {  // 1000-repo ceiling, same spirit as the old REPO_LIMIT
            let batch = try JSONDecoder().decode([GitHubRepo].self,
                                                 from: try await get("\(base)&per_page=100&page=\(page)"))
            repos.append(contentsOf: batch)
            if batch.count < 100 { hitCeiling = false; break }
        }
        // Forks are dropped AFTER the ceiling check: the filtered count says
        // nothing about whether the raw listing was complete.
        return RepoListing(repos: repos.filter { !$0.fork }, hitCeiling: hitCeiling)
    }

    /// Downloads the repo tarball to a temp file (URLSession follows the
    /// codeload redirect and streams to disk — constant memory).
    func downloadTarball(owner: String, repo: String) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(
            for: request("https://api.github.com/repos/\(owner)/\(repo)/tarball"))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tmp)
            throw FetchError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, "tarball \(repo)")
        }
        return tmp
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
            ("(api[_-]?key|passw|passwd|pwd|secret|token|credential"
             + "|private[_-]?key|access[_-]?key|signing[_-]?key|auth)[\\w-]*[\\s\"'\\]]*[:=]", [.caseInsensitive]),
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

    private static let unprintable = CharacterSet.controlCharacters
        .union(.newlines).union(.illegalCharacters)

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
        guard tar.terminationStatus == 0 else { throw FetchError.tarFailed(repo) }

        let dest = cacheDir.appendingPathComponent(repo, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)  // marker even for repos with no source files

        var kept = 0, written = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            let size = vals.fileSize ?? 0
            let rel = String(url.path.dropFirst(extractDir.path.count + 1))
            guard wanted(relPath: rel, size: size) else { continue }
            if written + size > maxRepoBytes { break }
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
                col += 1
            }
        }
        return out
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// nil = drop the whole file.
    static func cleanLines(_ raw: String) -> [String]? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
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

    /// Packs the whole cache into corpus.bin + corpus-index.json, deduplicating
    /// identical files across repos by content hash, then swaps both into place
    /// with two rename(2)s, bin first. Each rename is atomic but the pair is
    /// not, so the reader binds an index to its exact bin: every block must fit
    /// AND the bin's byte count must equal the index's last offset+length. A
    /// reader that catches the pair mid-swap (new bin with the old index, or
    /// old bin with the new) fails that check and falls back for one session
    /// instead of slicing the bin at the wrong boundaries.
    static func buildCorpus(cacheDir: URL, corpusDir: URL) throws -> BuildResult {
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

        let repoDirs = ((try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for repoDir in repoDirs {
            let repo = repoDir.lastPathComponent
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
                guard let lines = cleanLines(String(decoding: data, as: UTF8.self)) else { continue }
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
            throw FetchError.emptyCorpus
        }
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: idxTmp)
        try CorpusStore.replaceFile(at: corpusDir.appendingPathComponent("corpus.bin"), with: binTmp)
        try CorpusStore.replaceFile(at: corpusDir.appendingPathComponent("corpus-index.json"), with: idxTmp)
        return result
    }
}
