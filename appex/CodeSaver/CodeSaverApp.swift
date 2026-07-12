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
        // Headless mode for install.sh: reinstalling invalidates the wallpaper
        // store's screen-saver selection (new bundle inode + registration
        // UUID), so the installer re-activates via PaperSaver and exits.
        if CommandLine.arguments.contains("--activate") {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Window("Preview", id: "preview") {
            PreviewViewRepresentable()
                .ignoresSafeArea()
        }
        .defaultSize(width: 640, height: 480)
    }
}
