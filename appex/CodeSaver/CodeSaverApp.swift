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

struct CodeSaverApp: App {
    /// Fire one trivial Apple Event at each running player from the host
    /// app's UI context. The background daemon can never show the Automation
    /// consent dialog (silently denied, no prompt, no TCC record), so the
    /// app asks on the bundle's behalf; one approval covers the daemon too.
    static func seedAutomationConsent() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/codesaver/consent-probe.log")
        var lines = ["probe @ \(Date()) pid \(ProcessInfo.processInfo.processIdentifier) ui"]
        for p in FeedsService.players {
            guard !NSRunningApplication.runningApplications(
                withBundleIdentifier: p.bundle).isEmpty else {
                lines.append("\(p.name): not running"); continue
            }
            var err: NSDictionary?
            let out = NSAppleScript(source: "tell application \"\(p.name)\" to get player state")?
                .executeAndReturnError(&err)
            lines.append("\(p.name): result=\(out?.stringValue ?? "nil") "
                + "err=\(err.map { String(describing: $0) } ?? "none")")
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: logURL, atomically: true, encoding: .utf8)
    }

    init() {
        // A real UI launch: seed the music Automation consent from
        // foreground context — the background feeds daemon can never show
        // the prompt itself. One approval covers the bundle id for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            CodeSaverApp.seedAutomationConsent()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Album art", id: "albumart") {
            AlbumArtTunerView()
        }
        .defaultSize(width: 1060, height: 720)

        Window("Preview", id: "preview") {
            PreviewViewRepresentable()
                .ignoresSafeArea()
        }
        .defaultSize(width: 640, height: 480)
    }
}
