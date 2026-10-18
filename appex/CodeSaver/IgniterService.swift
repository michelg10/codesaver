//
//  IgniterService.swift
//  CodeSaver
//
//  Ignition's plumbing. The igniter (helper/Igniter.swift) ships inside the
//  app as Contents/Library/LoginItems/CodeSaver Igniter.app and runs as an
//  SMAppService LaunchAgent from com.michelg10.CodeSaver.Igniter.plist —
//  registered only by the app's Ignition switch, so it is off until the
//  user turns it on. This file registers it, reads what it publishes,
//  retires the standalone copy helper/install.sh used to install, and gives
//  the app's update and uninstall paths one call each. Host app target only.
//

import Foundation
import ServiceManagement

enum IgniterService {
    private static let log = AppexLog.logger("Igniter")

    /// One string, three jobs: the LaunchAgent label, the helper's bundle
    /// identifier, and its defaults domain. They match the standalone
    /// install's on purpose — TCC keys the Screen Recording grant on
    /// identifier + team, and the corner settings live in that domain, so an
    /// existing user keeps both when the embedded copy takes over.
    static let label = "com.michelg10.CodeSaver.Igniter"
    static let plistName = "\(label).plist"
    static var service: SMAppService { .agent(plistName: plistName) }

    /// SMAppService pins the registering app's path; like the refresh and
    /// feeds agents, only ever register from /Applications.
    static var isAtStablePath: Bool { Bundle.main.bundlePath == "/Applications/CodeSaver.app" }

    static var status: SMAppService.Status { service.status }

    /// On = registered: running, or waiting for approval in Login Items.
    static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// The user's choice, kept apart from the registration: macOS can refuse
    /// or drop a registration (a migration that raced Background Items, a
    /// launch cut short mid-way), and the update paths must tell "switched
    /// off" from "meant to be on but isn't". Installs from before the key
    /// have none, and their registration was the choice.
    static let wantedKey = "IgnitionWanted"
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? isOn(service.status) }
        set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
    }

    /// The agent's defaults domain. The app is unsandboxed, so this is the
    /// same ~/Library/Preferences file the agent reads as .standard (it re-
    /// reads corner config every 5 s, so edits land without a restart).
    static let defaults = UserDefaults(suiteName: label)

    // MARK: Trigger config (keys the agent reads — see Igniter.swift)

    /// Corner config ints: bit 0 = armed, bits 1–4 = ⌘ ⌥ ⌃ ⇧ held first
    /// (decoded by the agent's cornerFlags). Modifier bits survive with the
    /// corner disarmed — the agent ignores them without bit 0 — so turning
    /// a corner off and on again keeps its keys.
    static let cornerKeys = ["cornerTL", "cornerTR", "cornerBL", "cornerBR"]
    static let armedBit = 1

    /// Seconds of idle after which the agent starts the saver itself; 0 =
    /// macOS's own screen saver timeout does it.
    static let idleTimeoutKey = "idleTimeout"

    /// What the running agent last found for its own Screen Recording grant
    /// (written on change, see Igniter.publishScreenRecording); nil until it
    /// has run once. Only the agent can ask — TCC answers per code identity,
    /// and the app's own preflight would be about the app. Synchronized
    /// first: another process wrote it, and this process's cache would
    /// otherwise keep serving the old value.
    static var screenRecordingGranted: Bool? {
        CFPreferencesAppSynchronize(label as CFString)
        return defaults?.object(forKey: "screenRecordingGranted") as? Bool
    }

    // MARK: Switch

    /// Register the agent; launchd starts it at once (RunAtLoad), and its
    /// first act is to ask for Screen Recording — the prompt arrives while
    /// the user is still looking at the switch they flipped.
    @discardableResult
    static func enable(interactive: Bool = true) -> SMAppService.Status {
        guard isAtStablePath else { return service.status }
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                log.error("igniter register: \(String(describing: error), privacy: .public)")
            }
        }
        let status = service.status
        if status == .requiresApproval && interactive {
            SMAppService.openSystemSettingsLoginItems()
        }
        return status
    }

    /// Unregister: launchd stops the agent, whose SIGTERM handler deletes
    /// any capture still on disk on its way out.
    static func disable() {
        do {
            try service.unregister()
        } catch {
            log.info("igniter unregister: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: The standalone igniter (helper/install.sh, before it shipped here)

    static var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName)")
    }

    static var legacyApp: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeSaver/CodeSaverIgniter.app")
    }

    static var legacyInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: legacyPlist.path) || fm.fileExists(atPath: legacyApp.path)
    }

    /// Where a standalone igniter waits while the embedded one is registered
    /// in its place — set aside, not deleted, so a refusal can put it back.
    static var legacyBackup: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeSaver/igniter-migration")
    }

    private static let migrationLock = NSLock()

    /// The app's launch-time migration: if the standalone igniter is still
    /// installed, retire it and register the embedded one in its place —
    /// the user installed it, so they want ignition on. Order matters: both
    /// jobs carry the same label, and launchd holds one job per label, so
    /// the old one must be gone before the new one can load. Transactional:
    /// the old job is set aside, and comes back if the new one won't
    /// register. Returns the embedded agent's status, or nil when there was
    /// nothing to do (or the app isn't in /Applications yet — retiring a
    /// working igniter for a registration that can't happen would leave
    /// none at all). Blocking, up to ~2.5 min when macOS is slow to let go
    /// of the old job: call off the main thread. Serialized, so the
    /// launch-time call and an update path's can't both cycle the agent.
    static func migrateLegacy() -> SMAppService.Status? {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard legacyInstalled, isAtStablePath else { return nil }
        log.notice("retiring the standalone igniter for the embedded one")
        wanted = true
        launchctl("bootout", "gui/\(getuid())/\(label)")
        guard waitUntilUnloaded() else {
            log.error("the standalone igniter is still loaded — left in place")
            return service.status
        }
        guard setAsideLegacy() else {
            log.error("couldn't set the standalone igniter aside — put back as it was")
            restoreLegacy()
            return service.status
        }
        // A registration made while the old job still held the label never
        // loaded — and the bootout above stopped the embedded job if it was
        // the one loaded — yet SMAppService keeps saying .enabled, and
        // registering an enabled service is a no-op. Cycle it so launchd
        // loads it fresh.
        if isOn(service.status) {
            disable()
            waitUntilUnloaded()
        }
        let status = enableOutlastingLegacyRecord()
        if isOn(status) {
            try? FileManager.default.removeItem(at: legacyBackup)
        } else {
            log.error("embedded igniter refused (\(RefreshAgent.describe(status), privacy: .public)) — the standalone one goes back")
            restoreLegacy()
        }
        log.notice("embedded igniter: \(RefreshAgent.describe(status), privacy: .public)")
        return status
    }

    /// Background Items keeps the standalone job's record until it notices
    /// its plist is gone — about a minute on macOS 27 — and registering the
    /// same label meanwhile throws "Operation not permitted". Retry past it.
    private static func enableOutlastingLegacyRecord() -> SMAppService.Status {
        let deadline = Date().addingTimeInterval(120)
        var status = enable(interactive: false)
        while !isOn(status), Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            status = enable(interactive: false)
        }
        return status
    }

    /// Move the standalone plist and app into legacyBackup. False if either
    /// couldn't go (whatever did move is put back by the caller).
    private static func setAsideLegacy() -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: legacyBackup)
        guard (try? fm.createDirectory(at: legacyBackup, withIntermediateDirectories: true)) != nil else { return false }
        for item in [legacyPlist, legacyApp] where fm.fileExists(atPath: item.path) {
            guard (try? fm.moveItem(at: item, to: legacyBackup.appendingPathComponent(item.lastPathComponent))) != nil
            else { return false }
        }
        return true
    }

    /// Put the set-aside standalone igniter back where it was and load it
    /// again, so a refused migration leaves the user exactly the igniter
    /// they had. The next launch tries the migration again.
    private static func restoreLegacy() {
        let fm = FileManager.default
        for item in [legacyPlist, legacyApp] {
            let saved = legacyBackup.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: saved.path), !fm.fileExists(atPath: item.path) {
                try? fm.moveItem(at: saved, to: item)
            }
        }
        // Only an emptied backup goes: anything that couldn't move back is
        // the user's igniter, and stays where it can be found.
        if (try? fm.contentsOfDirectory(atPath: legacyBackup.path))?.isEmpty == true {
            try? fm.removeItem(at: legacyBackup)
        }
        if fm.fileExists(atPath: legacyPlist.path) {
            launchctl("bootstrap", "gui/\(getuid())", legacyPlist.path)
        }
    }

    /// Boot out the old job, wait for launchd to let go of the label, then
    /// delete its plist and app. Uninstall only — a migration sets it aside.
    private static func retireLegacy() {
        launchctl("bootout", "gui/\(getuid())/\(label)")
        waitUntilUnloaded()
        try? FileManager.default.removeItem(at: legacyPlist)
        try? FileManager.default.removeItem(at: legacyApp)
    }

    /// Stopping a job returns before launchd has torn it down, and loading
    /// the same label while that is in flight fails ("Bootstrap failed: 5",
    /// install.sh's old race) and leaves no igniter running at all. Wait
    /// until launchd no longer knows the label — past its 20 s ExitTimeOut,
    /// though the agent's own SIGTERM handler makes it a moment. False if
    /// it never let go.
    @discardableResult
    private static func waitUntilUnloaded() -> Bool {
        let target = "gui/\(getuid())/\(label)"
        for _ in 0..<50 {
            if launchctl("print", target) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Lifecycle hooks

    /// Post-update self-repair. The agent is KeepAlive: after the app bundle
    /// is replaced it keeps running the OLD build off the unlinked inode,
    /// and re-registering an enabled agent neither restarts it nor reloads
    /// its plist. Unregister + register does both. Only when the user wants
    /// it — an update never turns ignition on for a user who left it off,
    /// and a registration that was lost comes back. Also retires a
    /// standalone igniter if one is still around. Blocking (the migration
    /// may wait on launchd): call off the main thread.
    @discardableResult
    static func repairAfterUpdate() -> SMAppService.Status {
        if let migrated = migrateLegacy() { return migrated }
        guard wanted, isAtStablePath else { return service.status }
        if isOn(service.status) {
            disable()
            waitUntilUnloaded()
        }
        return enable(interactive: false)
    }

    /// The launch-time backstop: the user's choice is on, yet nothing is
    /// registered — a migration cut short mid-way, a registration macOS
    /// dropped. Nil when there was nothing to do.
    static func restoreIfWanted() -> SMAppService.Status? {
        guard UserDefaults.standard.bool(forKey: wantedKey), !legacyInstalled,
              isAtStablePath, !isOn(service.status) else { return nil }
        log.notice("ignition is meant to be on but isn't registered — registering")
        return enable(interactive: false)
    }

    /// Everything ignition ever put on this Mac, for the app's uninstall:
    /// the agent (unregistered — launchd stops it), a standalone copy if one
    /// is left, any capture that outlived both, the trigger settings and
    /// the agent's logs. Blocking (the standalone bootout waits on launchd):
    /// call off the main thread.
    static func uninstall() {
        disable()
        if legacyInstalled { retireLegacy() }
        try? FileManager.default.removeItem(at: legacyBackup)
        sweepCaptures()
        UserDefaults.standard.removePersistentDomain(forName: label)
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodeSaver")
        for name in ["igniter.log", "igniter.log.1"] {
            try? FileManager.default.removeItem(at: logs.appendingPathComponent(name))
        }
    }

    /// The agent's captures — every "boom-" file in the two directories its
    /// manifestDirs() writes (the unsandboxed harness's, and the saver
    /// extension's container). The agent deletes them itself whenever the
    /// user is back or it is stopped; this is the backstop for one that was
    /// killed outright.
    static func sweepCaptures() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let rel = "Library/Application Support/CodeSaver"
        let dirs = [home.appendingPathComponent(rel),
                    home.appendingPathComponent("Library/Containers/com.michelg10.CodeSaver.Extension/Data")
                        .appendingPathComponent(rel)]
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("boom-") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
