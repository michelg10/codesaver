//
//  main.swift
//  CodeSaver
//
//  Explicit entry point so headless modes never touch SwiftUI or AppKit's
//  application machinery. SwiftUI's App.main() initializes NSApplication
//  BEFORE App.init runs, which made the KeepAlive feeds daemon (this same
//  executable) check in with the Dock as a GUI instance of the app: no event
//  loop -> "Application Not Responding", Finder clicks routed to the zombie,
//  LaunchServices -600 for real launches, force-quit resurrection. Branching
//  here keeps daemons plain processes; only a real UI launch reaches
//  CodeSaverApp.main().
//

import Foundation
import ServiceManagement

let args = CommandLine.arguments

// The widget feed daemon — merges Claude Code hook state + the mods' live
// state and pin files + now-playing into widgets/feed.json in the app-group
// container.
if args.contains("--feeds") {
    FeedsService.runDaemon()
}

// Headless mode for install.sh: reinstalling invalidates the wallpaper
// store's screen-saver selection, so the installer re-activates and exits.
// The app's Enable button, verbatim: wait for pluginkit to list the
// /Applications copy, select, read the selection back, retry.
if args.contains("--activate") {
    Task.detached {
        let failure: String
        switch await SaverControl.enable(progress: { print("   \($0)") }) {
        case .enabled:
            print("activated")
            exit(0)
        case .notInApplications:
            failure = "this copy isn't /Applications/CodeSaver.app — macOS only uses the screen saver from there"
        case .notRegistered:
            failure = "pluginkit never listed /Applications/CodeSaver.app's screen saver"
        case .failed(let why):
            failure = why
        }
        FileHandle.standardError.write(Data("activation failed: \(failure)\n".utf8))
        exit(1)
    }
    RunLoop.main.run()
}

// For install.sh, before it replaces the bundle: is CodeSaver the selected
// saver right now? Exit 0 = yes, 1 = no. Reads only — selects nothing.
if args.contains("--saver-active") {
    let active = SaverControl.isActive()
    print(active ? "active" : "not active")
    exit(active ? 0 : 1)
}

// Headless corpus refresh — what the refresh LaunchAgent runs hourly.
if args.contains("--refresh") {
    let force = args.contains("--force")
    Task { @MainActor in
        exit(await RefreshService.headlessRefresh(force: force) ? 0 : 1)
    }
    RunLoop.main.run()
}

// The widget feed daemon is opt-in: only the app's "Live widgets" toggle
// ever turns it on. Both install-time entry points below therefore act on it
// only when it is already on (enabled, or registered and waiting in Login
// Items) — a reinstall keeps a chosen daemon running on the new build and
// never starts one for a user who never chose it. Both go through
// AgentMaintenance, which the app's post-update repair calls too.

// Called by install.sh when the feeds agent's plist has changed: registering
// an already-enabled agent is a no-op and launchd keeps the job definition it
// first loaded, so the only way a new ProcessType (or anything else in the
// plist) takes effect is to unregister and register again. Also the recovery
// for a booted-out feeds agent (SMAppService keeps reporting .enabled after
// `launchctl bootout`, and after the bundle swap — the record is keyed by the
// /Applications path; cycling it starts the job again).
if args.contains("--reregister-feeds") {
    guard let s = AgentMaintenance.cycleFeedsIfOn() else {
        print("feeds agent: off — not registered (turn on Live widgets in the app)")
        exit(0)
    }
    print("feeds agent: \(RefreshAgent.describe(s))")
    exit(AgentMaintenance.isOn(s) ? 0 : 1)
}

// Called by install.sh once the app is at its stable /Applications path: the
// corpus refresher when it's on (a no-op that self-heals a stale BTM record)
// or a GitHub token makes it useful — never for a fresh install with no
// token, which got a "Background Items Added" notice for an agent that could
// only fail hourly — and the feeds agent only if it was already on.
// install.sh's counterpart for the embedded igniter: cycle it when it is on
// (the agent keeps running the replaced build otherwise), retiring a
// standalone igniter from an old source install on the way. Off: exit 0 and
// register nothing — a reinstall never switches ignition on.
// The Ignition switch turned on from a script — the recovery for an igniter
// whose registration was lost. Unlike --reregister-igniter it is a choice,
// so it starts from .notRegistered.
if args.contains("--enable-igniter") {
    IgniterService.wanted = true
    let s = IgniterService.enable(interactive: false)
    print("igniter agent: \(RefreshAgent.describe(s))")
    exit(IgniterService.isOn(s) ? 0 : 1)
}

if args.contains("--reregister-igniter") {
    // Read before the repair: for an install from before the choice was
    // recorded, "wanted" is the registration itself, which a failed repair
    // would turn into "off".
    let wanted = IgniterService.wanted || IgniterService.legacyInstalled
    let s = IgniterService.repairAfterUpdate()
    guard wanted else {
        print("igniter agent: off (turn on Ignition in the app)")
        exit(0)
    }
    print("igniter agent: \(RefreshAgent.describe(s))")
    // Wanted but not on is a failure, said so: it used to exit 0 here.
    exit(IgniterService.isOn(s) ? 0 : 1)
}

if args.contains("--register-agent") {
    var ok = true
    if let s1 = AgentMaintenance.registerRefresh(orIfToken: true) {
        print("refresh agent: \(RefreshAgent.describe(s1))")
        ok = AgentMaintenance.isOn(s1)
    } else {
        print("refresh agent: off (connect GitHub, then switch on Auto-refresh in the app)")
    }
    if let s2 = AgentMaintenance.registerFeedsIfOn() {
        print("feeds agent: \(RefreshAgent.describe(s2)) (kept)")
        ok = ok && AgentMaintenance.isOn(s2)
    } else {
        print("feeds agent: off (opt in with Live widgets in the app)")
    }
    exit(ok ? 0 : 1)
}

// Scripted one-shot of the UI's "Import from gh CLI" button.
if args.contains("--import-gh-token") {
    if TokenStore.importFromGH() {
        print("token imported from gh into the Keychain")
        exit(0)
    }
    FileHandle.standardError.write(Data("gh CLI not found or not signed in\n".utf8))
    exit(1)
}

CodeSaverApp.main()
