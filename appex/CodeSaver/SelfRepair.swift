//
//  SelfRepair.swift
//  CodeSaver
//
//  The first launch of a new build puts back what replacing the bundle broke.
//  A drag-installed update is a bundle swap, and a bundle swap is exactly what
//  install.sh spends half its length repairing: pluginkit has to elect the new
//  extension, the wallpaper store's selection binding goes stale (trap #2 — a
//  black saver), and the KeepAlive feeds daemon keeps running the old binary's
//  unlinked inode. DMG users have no install.sh, so the app does the same steps
//  itself, through the same functions `--register-agent` / `--reregister-feeds`
//  call.
//

import Foundation
import Security
import ServiceManagement

private let logger = AppexLog.logger("SelfRepair")

@MainActor
enum SelfRepair {
    /// CFBundleVersion of the last build that finished its repair. install.sh
    /// writes it too (`defaults write com.michelg10.CodeSaver LastRunBuild`)
    /// once it has done these same steps, so a source build doesn't repeat them.
    static let lastBuildKey = "LastRunBuild"
    /// Set by "Move to Applications": a swap of the same build number still
    /// leaves a stale binding behind.
    static let forceKey = "RepairOnNextLaunch"

    private static var ran = false

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Only at the stable path: anywhere else pluginkit and SMAppService would
    /// be pointed at a copy that's about to move.
    static var isPending: Bool {
        guard AppLocation.isInstalled else { return false }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: forceKey) || defaults.string(forKey: lastBuildKey) != currentBuild
    }

    /// Once per process, from the window's first appearance.
    static func runIfNeeded(plugin: PluginManager) {
        guard !ran, isPending else { return }
        ran = true
        // Read before any status probe can land: probes clear the flag when
        // they see another saver, and a stale binding may read as one.
        let wasActive = UserDefaults.standard.bool(forKey: SaverControl.wasActiveKey)
        logger.notice("first launch of build \(currentBuild, privacy: .public) — repairing (was active: \(wasActive))")
        Task {
            await Task.detached(priority: .utility) { AgentMaintenance.repairAfterUpdate() }.value
            // A failed repair stays pending: the next launch tries again, and
            // the Enable step offers it in the meantime.
            if await plugin.repairAfterUpdate(wasActive: wasActive) { markDone() }
        }
    }

    /// A manual Enable that works after a failed repair completes it.
    static func saverFixed() {
        if ran, isPending { markDone() }
    }

    private static func markDone() {
        UserDefaults.standard.set(currentBuild, forKey: lastBuildKey)
        UserDefaults.standard.removeObject(forKey: forceKey)
    }
}

/// The agent half of an install, shared by the CLI entry points install.sh
/// calls and the app's post-update repair — one code path, two callers.
enum AgentMaintenance {
    static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Whether a GitHub token is stored — attributes only, never the secret,
    /// so asking can't raise a Keychain prompt from a script. The environment
    /// override counts, as it does for the refresh itself.
    static var hasToken: Bool {
        if let env = ProcessInfo.processInfo.environment["CODESAVER_GITHUB_TOKEN"], !env.isEmpty {
            return true
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: TokenStore.service,
                                    kSecAttrAccount as String: TokenStore.account,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The refresh agent, when it's on — registering an enabled agent is a
    /// no-op that self-heals a stale Login Items record. `orIfToken` is
    /// install.sh's extra case: a token makes the agent useful, so a source
    /// install turns it on. Without one, registering is how a fresh install
    /// got a "Background Items Added" notice and an agent failing hourly.
    /// Nil = left off.
    @discardableResult
    static func registerRefresh(orIfToken: Bool) -> SMAppService.Status? {
        guard isOn(RefreshAgent.status) || (orIfToken && hasToken) else { return nil }
        return RefreshAgent.register(interactive: false)
    }

    /// Keep an on feeds agent registered; never turn one on (that's the
    /// app's Live widgets switch alone). Nil = off.
    static func registerFeedsIfOn() -> SMAppService.Status? {
        guard isOn(FeedsAgent.status) else { return nil }
        return FeedsAgent.register(interactive: false)
    }

    /// Unregister + register an on feeds agent. Registering an enabled agent
    /// is a no-op and launchd keeps the job it first loaded, so this is the
    /// only way the KeepAlive daemon restarts on the new build and a changed
    /// plist takes effect. Nil = off.
    @discardableResult
    static func cycleFeedsIfOn() -> SMAppService.Status? {
        guard isOn(FeedsAgent.status) else { return nil }
        FeedsAgent.unregister()
        return FeedsAgent.register(interactive: false)
    }

    /// After an update: what install.sh's `--register-agent` and
    /// `--reregister-feeds` do, minus ever switching something on.
    static func repairAfterUpdate() {
        let refresh = registerRefresh(orIfToken: false)
        let feeds = cycleFeedsIfOn()
        reregisterIgniterIfOn()
        logger.notice("agents after update: refresh \(refresh.map(RefreshAgent.describe) ?? "off", privacy: .public), feeds \(feeds.map(RefreshAgent.describe) ?? "off", privacy: .public)")
    }

    /// The embedded igniter, when it was on, the way cycleFeedsIfOn does the
    /// feeds daemon: it too runs from inside the bundle that was just
    /// replaced (KeepAlive on the old inode). Also retires a standalone
    /// igniter left from a source install. Blocking — the caller is already
    /// off the main thread.
    static func reregisterIgniterIfOn() {
        let s = IgniterService.repairAfterUpdate()
        logger.notice("igniter after update: \(RefreshAgent.describe(s), privacy: .public)")
    }
}
