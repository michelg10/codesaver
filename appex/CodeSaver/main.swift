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

// Called by install.sh once the app is at its stable /Applications path.
if args.contains("--register-agent") {
    let s1 = RefreshAgent.register(interactive: false)
    print("refresh agent: \(RefreshAgent.describe(s1))")
    let s2 = FeedsAgent.register(interactive: false)
    print("feeds agent: \(RefreshAgent.describe(s2))")
    let ok1 = s1 == .enabled || s1 == .requiresApproval
    let ok2 = s2 == .enabled || s2 == .requiresApproval
    exit(ok1 && ok2 ? 0 : 1)
}

// Recovery for a booted-out feeds agent (SMAppService keeps reporting
// .enabled after `launchctl bootout`; cycle it).
if args.contains("--reregister-feeds") {
    FeedsAgent.unregister()
    let status = FeedsAgent.register(interactive: false)
    print("feeds agent: \(RefreshAgent.describe(status))")
    exit(status == .enabled || status == .requiresApproval ? 0 : 1)
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
