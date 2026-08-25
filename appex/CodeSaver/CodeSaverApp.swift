//
//  CodeSaverApp.swift
//  CodeSaver
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Host application for the screensaver extension. The host app exists so the
//  .appex can be bundled and registered with pluginkit; macOS does not load
//  appex bundles that aren't embedded inside an application.
//

import SwiftUI
import PaperSaverKit

@main
struct CodeSaverApp: App {
    init() {
        let args = CommandLine.arguments
        // Headless mode for install.sh: reinstalling invalidates the wallpaper
        // store's screen-saver selection (new bundle inode + registration
        // UUID), so the installer re-activates via PaperSaver and exits.
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
            RunLoop.main.run()  // Task exits the process; UI never launches.
        }
        // Headless corpus refresh — what the LaunchAgent runs hourly. The
        // battery/staleness gates live in RefreshService; a gate skip still
        // exits 0 so launchd never sees hourly "failures".
        if args.contains("--refresh") {
            let force = args.contains("--force")
            Task { @MainActor in
                exit(await RefreshService.headlessRefresh(force: force) ? 0 : 1)
            }
            RunLoop.main.run()
        }
        // Called by install.sh once the app is at its stable /Applications path.
        if args.contains("--register-agent") {
            let status = RefreshAgent.register(interactive: false)
            print("refresh agent: \(RefreshAgent.describe(status))")
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Preview", id: "preview") {
            PreviewViewRepresentable()
                .ignoresSafeArea()
        }
        .defaultSize(width: 640, height: 480)
    }
}
