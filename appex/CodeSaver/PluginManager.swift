//
//  PluginManager.swift
//  CodeSaver
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Drives extension registration (via pluginkit) and screensaver activation
//  (via PaperSaverKit). SaverControl is the blocking half — subprocesses and
//  wallpaper-store reads and writes — shared by the app's Enable step and the
//  headless `--activate` install.sh runs; PluginManager is the UI's view of it
//  and never lets any of it touch the main thread.
//

import AppKit
import PaperSaverKit

private let logger = AppexLog.logger("PluginManager")

enum SaverControl {
    static let extensionID = "com.michelg10.CodeSaver.Extension"
    /// The wallpaper store's (and PaperSaver's) name for the saver: the
    /// extension's file name.
    static let module = "CodeSaverExtension"
    static let installedAppexPath = AppLocation.installedPath + "/Contents/PlugIns/CodeSaverExtension.appex"

    /// Set whenever CodeSaver is seen selected, cleared when it's seen not to
    /// be. A reinstall makes the selection binding stale (trap #2), and this
    /// is how the first launch of a new build knows to re-select it.
    static let wasActiveKey = "ScreenSaverWasActive"
    /// The saver CodeSaver replaced, for "restore previous screen saver".
    static let previousSaverKey = "PreviousScreenSaver"

    struct Registration: Equatable {
        let path: String
        let version: String?
        var isInstalledCopy: Bool { path.hasPrefix(AppLocation.installedPath + "/") }
    }

    // MARK: pluginkit

    /// The registration pluginkit has elected for our extension, nil when it
    /// lists none. Line format, tab-separated after the version:
    ///   `+    com.michelg10.CodeSaver.Extension(1.0)<TAB>uuid<TAB>date<TAB>/path/to.appex`
    static func registration() -> Registration? {
        let output = run("/usr/bin/pluginkit", ["-m", "-v", "-i", extensionID])
        for line in output.split(whereSeparator: \.isNewline) where line.contains(extensionID) {
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let path = fields.last(where: { $0.hasPrefix("/") }) else { continue }
            var version: String?
            if let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") {
                version = String(line[line.index(after: open)..<close])
            }
            return Registration(path: path, version: version)
        }
        return nil
    }

    static func register(_ appexPath: String) { run("/usr/bin/pluginkit", ["-a", appexPath]) }
    static func unregister(_ appexPath: String) { run("/usr/bin/pluginkit", ["-r", appexPath]) }

    /// Wait (up to `timeout`) for pluginkit to elect the /Applications copy,
    /// re-adding it every round — under load registration takes well over the
    /// couple of seconds an immediate activation assumed, and activating
    /// before it lands binds the selection to nothing: the pure-black saver.
    /// Any other copy holding the election (a Downloads or translocated run, a
    /// build folder) is dropped first: PaperSaver resolves the module through
    /// pluginkit, so whichever path wins is the one the selection binds to.
    static func waitUntilRegistered(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let elected = registration() {
                if elected.isInstalledCopy { return true }
                logger.notice("pluginkit elected \(elected.path, privacy: .public) — dropping it")
                unregister(elected.path)
            }
            register(installedAppexPath)
            guard Date() < deadline else { return registration()?.isInstalledCopy ?? false }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: wallpaper store

    /// Every saver named anywhere in the wallpaper store, all spaces and
    /// displays. By name only: a stale binding still reads as CodeSaver.
    static func activeSavers() -> [String] { PaperSaver().getActiveScreensavers() }
    static func isActive() -> Bool { activeSavers().contains(module) }

    /// The current space's saver — what "the previous screen saver" means to
    /// the person who picked it.
    static func currentSelection() -> String? {
        PaperSaver().getActiveScreensaver(for: nil)?.name ?? activeSavers().first
    }

    /// Whether PaperSaver can select `name` again: a module it can find on
    /// disk or through pluginkit. Wallpaper-as-saver, the dynamic desktop and
    /// the aerial videos decode to labels of PaperSaver's own, not modules —
    /// those go back by hand in Screen Saver settings.
    static func isRestorable(_ name: String) -> Bool {
        SystemPaths.screensaverModuleURL(for: name) != nil
    }

    static func displayName(_ name: String) -> String {
        if name == "Automatic" || name == "Dynamic Desktop" { return "your wallpaper" }
        if name.hasPrefix("Sequoia Video") { return "the aerial video" }
        return name
    }

    struct DidNotStick: LocalizedError {
        let name: String
        var errorDescription: String? { "macOS didn't keep \(displayName(name)) selected" }
    }

    /// Select `name` on every display and space, and check that it stuck.
    /// PaperSaver re-reads the store after restarting WallpaperAgent and, when
    /// that check fails, restores its backup and returns WITHOUT throwing — so
    /// success is our own read-back, never just the absence of an error.
    static func select(_ name: String, attempts: Int) async -> Error? {
        var last: Error?
        for attempt in 1...max(1, attempts) {
            do {
                try await PaperSaver().setScreensaverEverywhere(module: name)
                if activeSavers().contains(name) { return nil }
                last = DidNotStick(name: name)
            } catch {
                last = error
            }
            logger.warning("selecting \(name, privacy: .public), attempt \(attempt): \(String(describing: last), privacy: .public)")
            guard attempt < attempts else { break }
            if name == module { register(installedAppexPath) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return last
    }

    /// Note the saver about to be replaced. Never overwrites a remembered one
    /// with CodeSaver itself: re-enabling after an update keeps the original.
    static func rememberCurrentSelection() {
        guard let current = currentSelection(), current != module else { return }
        UserDefaults.standard.set(current, forKey: previousSaverKey)
    }

    enum EnableResult {
        case enabled, notInApplications, notRegistered
        case failed(String)
    }

    /// The whole of "Enable": remember what was selected, wait for the
    /// registration, select with retries and verification, and record that
    /// CodeSaver is the active saver. The app's Enable button and
    /// `CodeSaver --activate` (install.sh) are this one path.
    static func enable(progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> EnableResult {
        guard AppLocation.isInstalled else { return .notInApplications }
        rememberCurrentSelection()
        await progress("registering with macOS…")
        guard await waitUntilRegistered() else { return .notRegistered }
        await progress("switching the screen saver…")
        if let error = await select(module, attempts: 4) {
            return .failed(error.localizedDescription)
        }
        UserDefaults.standard.set(true, forKey: wasActiveKey)
        return .enabled
    }

    // MARK: subprocess

    /// Run a tool and return its combined output ("" if it couldn't start).
    /// pluginkit exits non-zero when nothing matches, so status isn't failure.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            logger.error("\(path, privacy: .public) didn't start: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // Drain before waiting: a child that fills the pipe never exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class PluginManager: ObservableObject {
    /// What went wrong, in words, plus what to pick by hand instead.
    enum Failure: Equatable {
        case notRegistered
        case couldNotSwitch(String)
        case repair
        case restore(String)

        var message: String {
            switch self {
            case .notRegistered:
                return "macOS hasn't listed CodeSaver as a screen saver yet, so it can't be switched on from here"
            case .couldNotSwitch(let why):
                return "couldn't switch the screen saver automatically (\(why))"
            case .repair:
                return "after the update, macOS still points at the old copy — the screen saver would start black"
            case .restore(let name):
                return "couldn't switch back to \(SaverControl.displayName(name)) automatically"
            }
        }

        /// The fallback's caption: what to pick in Screen Saver settings.
        var pickHint: String {
            if case .restore(let name) = self { return "pick \(SaverControl.displayName(name)) there" }
            return "pick CodeSaver there"
        }

        var canRetry: Bool {
            if case .restore = self { return false }
            return true
        }
    }

    @Published private(set) var registration: SaverControl.Registration?
    @Published private(set) var isActiveScreensaver = false
    @Published private(set) var hasProbed = false
    @Published private(set) var isWorking = false
    @Published private(set) var phase: String?
    @Published var failure: Failure?
    @Published private(set) var previousSaver: String?
    @Published private(set) var previousRestorable = false

    private var probes = 0

    /// pluginkit lists the /Applications copy.
    var isRegistered: Bool { registration?.isInstalledCopy ?? false }

    /// Selected AND trustworthy. After a failed post-update repair the store
    /// still names CodeSaver, but the binding is stale — the step must offer
    /// Enable again rather than claim "active".
    var isEnabled: Bool { isActiveScreensaver && failure != .repair }

    init() {
        refreshStatus()
    }

    /// Re-read registration + selection off the main thread (this runs on
    /// every window activation; pluginkit alone can take most of a second).
    func refreshStatus() {
        probes += 1
        let probe = probes
        Task.detached(priority: .utility) {
            let registration = SaverControl.registration()
            let active = SaverControl.isActive()
            let previous = UserDefaults.standard.string(forKey: SaverControl.previousSaverKey)
            let restorable = previous.map(SaverControl.isRestorable) ?? false
            await self.adopt(probe: probe, registration: registration, active: active,
                             previous: previous, restorable: restorable)
        }
    }

    private func adopt(probe: Int, registration: SaverControl.Registration?, active: Bool,
                       previous: String?, restorable: Bool) {
        guard probe == probes else { return }  // a newer probe is on its way
        self.registration = registration
        isActiveScreensaver = active
        previousSaver = previous
        previousRestorable = restorable
        hasProbed = true
        if active {
            UserDefaults.standard.set(true, forKey: SaverControl.wasActiveKey)
            // Picked by hand in System Settings after a failed Enable: done.
            if failure?.canRetry == true, failure != .repair { failure = nil }
        } else if !isWorking && !SelfRepair.isPending {
            // Switched away by hand after a failed restore: nothing to say.
            if case .restore = failure { failure = nil }
            // Mid-switch reads, and the launch that still has an update to
            // repair, must not forget that CodeSaver was the saver.
            UserDefaults.standard.set(false, forKey: SaverControl.wasActiveKey)
        }
    }

    /// The Enable button.
    func enable() {
        guard !isWorking, AppLocation.isInstalled else { return }
        isWorking = true
        failure = nil
        phase = "registering with macOS…"
        Task.detached(priority: .userInitiated) {
            let result = await SaverControl.enable { line in
                await MainActor.run { self.phase = line }
            }
            await self.finishEnable(result)
        }
    }

    private func finishEnable(_ result: SaverControl.EnableResult) {
        isWorking = false
        phase = nil
        switch result {
        case .enabled:
            isActiveScreensaver = true
            SelfRepair.saverFixed()
        case .notInApplications:
            break
        case .notRegistered:
            failure = .notRegistered
        case .failed(let why):
            failure = .couldNotSwitch(why)
        }
        refreshStatus()
    }

    /// The first launch of a new build: register again and, when CodeSaver
    /// was the saver, select it again. Returns whether the saver is whole.
    func repairAfterUpdate(wasActive: Bool) async -> Bool {
        isWorking = true
        phase = "registering with macOS…"
        let (registered, reselected) = await Task.detached(priority: .userInitiated) { () -> (Bool, Bool?) in
            let registered = await SaverControl.waitUntilRegistered()
            // The store keeps naming CodeSaver across a reinstall, so "named
            // now" also means "was the saver" — the flag covers the case where
            // the bundle swap made macOS fall back to another one.
            guard wasActive || SaverControl.isActive() else { return (registered, nil) }
            guard registered else { return (false, false) }
            return (true, await SaverControl.select(SaverControl.module, attempts: 4) == nil)
        }.value
        isWorking = false
        phase = nil
        if reselected == false { failure = .repair }
        refreshStatus()
        logger.notice("update repair: registered=\(registered) reselected=\(String(describing: reselected), privacy: .public)")
        return registered && reselected != false
    }

    /// Advanced and Uninstall: put back the saver CodeSaver replaced.
    func restorePrevious() {
        guard !isWorking, let name = previousSaver else { return }
        guard previousRestorable else {
            Self.openScreenSaverSettings()
            return
        }
        isWorking = true
        failure = nil
        phase = "switching back to \(SaverControl.displayName(name))…"
        Task.detached(priority: .userInitiated) {
            let error = await SaverControl.select(name, attempts: 2)
            await self.finishRestore(name, error)
        }
    }

    private func finishRestore(_ name: String, _ error: Error?) {
        isWorking = false
        phase = nil
        if error == nil {
            UserDefaults.standard.removeObject(forKey: SaverControl.previousSaverKey)
            UserDefaults.standard.set(false, forKey: SaverControl.wasActiveKey)
            previousSaver = nil
            isActiveScreensaver = false
        } else {
            failure = .restore(name)
        }
        refreshStatus()
    }

    nonisolated static func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
