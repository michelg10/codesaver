//
//  UpdateCheck.swift
//  CodeSaver
//
//  A quiet "update available" row. Only the app window asks — at most once a
//  day, one unauthenticated GET to GitHub's latest-release endpoint — and
//  nothing headless ever does: the refresh and feeds agents run this same
//  executable, and an hourly agent phoning home is not what anyone opted into.
//

import Foundation

private let logger = AppexLog.logger("UpdateCheck")

@MainActor
final class UpdateCheck: ObservableObject {
    static let enabledKey = "CheckForUpdates"
    static let lastCheckKey = "UpdateCheckedAt"
    static let latestTagKey = "UpdateLatestTag"
    nonisolated static let releaseURL = URL(string: "https://api.github.com/repos/michelg10/codesaver/releases/latest")!
    nonisolated static let siteURL = URL(string: "https://codesaver.michelg10.com")!

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Advanced → "check for updates"; on unless switched off.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { checkIfDue() } else { available = nil }
        }
    }

    /// "v1.2.0" when the latest release is newer than this build.
    @Published private(set) var available: String?

    private var inFlight = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        adopt(UserDefaults.standard.string(forKey: Self.latestTagKey))
    }

    /// Called on window appearance and activation. The day gate counts
    /// attempts, not successes: offline today means asking again tomorrow,
    /// not on every click back into the window.
    func checkIfDue(now: Date = Date()) {
        guard enabled, !inFlight else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < 86_400, now >= last {
            return
        }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        inFlight = true
        Task {
            let tag = await Self.fetchLatestTag()
            inFlight = false
            if let tag {
                UserDefaults.standard.set(tag, forKey: Self.latestTagKey)
                adopt(tag)
            }
        }
    }

    private func adopt(_ tag: String?) {
        guard enabled, let tag, Self.isNewer(tag, than: Self.currentVersion) else {
            available = nil
            return
        }
        available = tag.lowercased().hasPrefix("v") ? "v" + tag.dropFirst() : "v" + tag
    }

    nonisolated private static func fetchLatestTag() async -> String? {
        var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodeSaver/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else { return nil }
            return tag
        } catch {
            logger.info("update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// "v1.2.0" / "1.2" → [1, 2, 0] / [1, 2]; nil for anything else. A
    /// pre-release or build suffix is cut (the latest-release endpoint never
    /// returns pre-releases anyway).
    nonisolated static func components(_ version: String) -> [Int]? {
        var core = Substring(version.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = core[..<cut] }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Numeric, component by component, missing components as 0 (1.2 == 1.2.0).
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
