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

import ServiceManagement
import SwiftUI
import PaperSaverKit

struct CodeSaverApp: App {
    /// Fire one trivial Apple Event at each running player from the host
    /// app's UI context. The background daemon can never show the Automation
    /// consent dialog (silently denied, no prompt, no TCC record), so the
    /// app asks on the bundle's behalf; one approval covers the daemon too.
    ///
    /// Only for someone who switched Live widgets on — the switch's caption
    /// says this ask is coming, and the switch fires it itself when turned
    /// on (LiveWidgetsStep); launch repeats it while the switch stays on, for
    /// a player that wasn't running then. Synchronous on the main thread, by
    /// design: it is the UI context the consent dialog needs.
    static func seedAutomationConsent() {
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
        #if DEBUG
        // Development builds only: what each player answered, for debugging
        // the consent flow. A release build writes nothing anywhere.
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodeSaver", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: logDir.appendingPathComponent("consent-probe.log"), atomically: true, encoding: .utf8)
        #endif
    }

    /// The Live widgets switch as RefreshManager reads it: the feeds agent's
    /// registration — on, or on and waiting for Login Items approval.
    static var liveWidgetsOn: Bool {
        let s = FeedsAgent.status
        return s == .enabled || s == .requiresApproval
    }

    init() {
        // A real UI launch with Live widgets on: seed the music Automation
        // consent from foreground context — the background feeds daemon can
        // never show the prompt itself. One approval covers the bundle id
        // for good. Off, nothing is sent at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard CodeSaverApp.liveWidgetsOn else { return }
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
