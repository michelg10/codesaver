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
import PaperSaverKit
import ServiceManagement

let args = CommandLine.arguments

// The widget feed daemon — merges Claude Code hook state + bifrocate CoT
// spools + now-playing into widgets/feed.json in the app-group container.
if args.contains("--feeds") {
    FeedsService.runDaemon()
}

// Headless mode for install.sh: reinstalling invalidates the wallpaper
// store's screen-saver selection, so the installer re-activates and exits.
if args.contains("--activate") {
    Task { @MainActor in
        do {
            try await PaperSaver().setScreensaverEverywhere(module: "CodeSaverExtension")
            print("activated")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("activation failed: \(error)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
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
// never starts one for a user who never chose it.
func feedsIsOn(_ s: SMAppService.Status) -> Bool { s == .enabled || s == .requiresApproval }

// Called by install.sh when the feeds agent's plist has changed: registering
// an already-enabled agent is a no-op and launchd keeps the job definition it
// first loaded, so the only way a new ProcessType (or anything else in the
// plist) takes effect is to unregister and register again. Also the recovery
// for a booted-out feeds agent (SMAppService keeps reporting .enabled after
// `launchctl bootout`, and after the bundle swap — the record is keyed by the
// /Applications path; cycling it starts the job again).
if args.contains("--reregister-feeds") {
    guard feedsIsOn(FeedsAgent.status) else {
        print("feeds agent: off — not registered (turn on Live widgets in the app)")
        exit(0)
    }
    FeedsAgent.unregister()
    let s = FeedsAgent.register(interactive: false)
    print("feeds agent: \(RefreshAgent.describe(s))")
    exit(feedsIsOn(s) ? 0 : 1)
}

// Called by install.sh once the app is at its stable /Applications path:
// the corpus refresher always (a no-op that self-heals a stale BTM record),
// the feeds agent only if it was already on.
if args.contains("--register-agent") {
    let s1 = RefreshAgent.register(interactive: false)
    print("refresh agent: \(RefreshAgent.describe(s1))")
    var ok = s1 == .enabled || s1 == .requiresApproval
    if feedsIsOn(FeedsAgent.status) {
        let s2 = FeedsAgent.register(interactive: false)
        print("feeds agent: \(RefreshAgent.describe(s2)) (kept)")
        ok = ok && feedsIsOn(s2)
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
