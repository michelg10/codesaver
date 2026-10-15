//
//  Uninstaller.swift
//  CodeSaver
//
//  Advanced → "Uninstall CodeSaver…". Data first: `plan` is a pure function
//  of a few facts about this Mac, the confirm sheet lists its steps verbatim
//  (so the sheet can't promise anything the run doesn't do), and `run` walks
//  them through an Effects table — the whole sequence can be read, or driven
//  with fakes, without touching the machine. Only `Effects.live` does.
//

import AppKit

private let logger = AppexLog.logger("Uninstaller")

enum Uninstaller {
    /// The embedded igniter: its agent, a standalone copy if one is left,
    /// any capture that outlived both, its settings and logs. Blocking (the
    /// standalone bootout waits on launchd), so off the main actor. While
    /// nil the sheet doesn't list it and the run skips it.
    static let igniterRemoval: (@Sendable () async -> Void)? = {
        await Task.detached(priority: .userInitiated) { IgniterService.uninstall() }.value
    }
    /// Undoing "Connect Claude Code": the hooks and status line CodeSaver
    /// added to ~/.claude/settings.json (a no-op when it never connected).
    /// A failure — no command line tools, say — is logged and the rest of
    /// the uninstall still runs: the hooks are async and harmless without
    /// the app, and the sheet can't make them come off any other way.
    static let claudeCodeUnwiring: (@Sendable () async -> Void)? = {
        await Task.detached(priority: .userInitiated) {
            do { try ClaudeCodeWiring.unwire() } catch {
                logger.error("uninstall: Claude Code unwiring failed: \(String(describing: error), privacy: .public)")
            }
        }.value
    }

    enum Step: Hashable {
        case restoreSaver(String)
        case igniter
        case claudeCode
        case agents
        case token
        case containerData
        case registration
        case openSaverSettings
        case trashApp(URL)
        case defaults
    }

    struct Facts {
        var saverActive: Bool
        var previousSaver: String?
        var previousRestorable: Bool
        var appURL: URL
        var appOnReadOnlyVolume: Bool
        var hasIgniterRemoval: Bool
        var hasClaudeCodeUnwiring: Bool

        @MainActor
        static func current(plugin: PluginManager) -> Facts {
            Facts(saverActive: plugin.isActiveScreensaver,
                  previousSaver: plugin.previousSaver,
                  previousRestorable: plugin.previousRestorable,
                  appURL: AppLocation.originalURL,
                  appOnReadOnlyVolume: AppLocation.isOnReadOnlyVolume,
                  hasIgniterRemoval: igniterRemoval != nil,
                  hasClaudeCodeUnwiring: claudeCodeUnwiring != nil)
        }
    }

    /// In execution order. The saver goes back FIRST — unregistering the
    /// extension while it's still selected is the black screen this app
    /// exists to prevent — and the preferences go last, after every step that
    /// might still read them.
    static func plan(_ facts: Facts) -> [Step] {
        var steps: [Step] = []
        let restore = facts.saverActive && facts.previousRestorable
        if restore, let previous = facts.previousSaver { steps.append(.restoreSaver(previous)) }
        if facts.hasIgniterRemoval { steps.append(.igniter) }
        if facts.hasClaudeCodeUnwiring { steps.append(.claudeCode) }
        steps += [.agents, .token, .containerData, .registration]
        if facts.saverActive && !restore { steps.append(.openSaverSettings) }
        if !facts.appOnReadOnlyVolume { steps.append(.trashApp(facts.appURL)) }
        steps.append(.defaults)
        return steps
    }

    /// The sheet's line for each step.
    static func describe(_ step: Step) -> String {
        switch step {
        case .restoreSaver(let name):
            return "switch the screen saver back to \(SaverControl.displayName(name))"
        case .igniter:
            return "the igniter — hot corners and the idle start"
        case .claudeCode:
            return "CodeSaver's hooks and status line in Claude Code's settings"
        case .agents:
            return "the hourly code refresh and the live-widgets helper, from Login Items"
        case .token:
            return "the GitHub token saved in your Keychain"
        case .containerData:
            return "the downloaded code, widget state and verbs the screen saver reads"
        case .registration:
            return "CodeSaver from the list of screen savers"
        case .openSaverSettings:
            return "then open Screen Saver settings so you can pick another one"
        case .trashApp(let url):
            return "the app itself, moved to the Trash from \(url.deletingLastPathComponent().path)"
        case .defaults:
            return "CodeSaver's own settings"
        }
    }

    struct Effects {
        var restoreSaver: @Sendable (String) async -> Bool
        var openSaverSettings: @Sendable () -> Void
        var removeIgniter: @Sendable () async -> Void
        var unwireClaudeCode: @Sendable () async -> Void
        var unregisterAgents: @Sendable () -> Void
        var forgetToken: @Sendable () -> Void
        var removeContainerData: @Sendable () -> Bool
        var unregisterExtension: @Sendable () -> Void
        var trashApp: @Sendable (URL) -> Bool
        var removeDefaults: @Sendable () -> Void

        static let live = Effects(
            restoreSaver: { name in await SaverControl.select(name, attempts: 2) == nil },
            openSaverSettings: { PluginManager.openScreenSaverSettings() },
            removeIgniter: { await Uninstaller.igniterRemoval?() },
            unwireClaudeCode: { await Uninstaller.claudeCodeUnwiring?() },
            unregisterAgents: {
                RefreshAgent.unregister()
                FeedsAgent.unregister()
            },
            forgetToken: { TokenStore.forget() },
            removeContainerData: {
                // Everything CodeSaver keeps in the app-group container — the
                // corpus, the repo mirror, widgets/, the verbs — but not the
                // container manager's own metadata, which isn't ours to delete.
                guard let root = CorpusStore.containerURL else { return true }
                let fm = FileManager.default
                var ok = true
                for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                where !item.lastPathComponent.hasPrefix(".com.apple.containermanagerd") {
                    do { try fm.removeItem(at: item) } catch { ok = false }
                }
                return ok
            },
            unregisterExtension: {
                SaverControl.unregister(SaverControl.installedAppexPath)
                let here = Bundle.main.bundleURL
                    .appendingPathComponent("Contents/PlugIns/CodeSaverExtension.appex").path
                if here != SaverControl.installedAppexPath { SaverControl.unregister(here) }
            },
            trashApp: { url in (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil },
            removeDefaults: {
                UserDefaults.standard.removePersistentDomain(
                    forName: Bundle.main.bundleIdentifier ?? "com.michelg10.CodeSaver")
            })
    }

    /// Walk the plan. A saver that won't go back falls through to Screen Saver
    /// settings rather than stopping the uninstall. Returns the steps that
    /// didn't complete; quitting is the caller's.
    static func run(_ steps: [Step], _ effects: Effects) async -> [Step] {
        var failed: [Step] = []
        for step in steps {
            switch step {
            case .restoreSaver(let name):
                if !(await effects.restoreSaver(name)) {
                    failed.append(step)
                    effects.openSaverSettings()
                }
            case .igniter: await effects.removeIgniter()
            case .claudeCode: await effects.unwireClaudeCode()
            case .agents: effects.unregisterAgents()
            case .token: effects.forgetToken()
            case .containerData:
                if !effects.removeContainerData() { failed.append(step) }
            case .registration: effects.unregisterExtension()
            case .openSaverSettings: effects.openSaverSettings()
            case .trashApp(let url):
                if !effects.trashApp(url) { failed.append(step) }
            case .defaults: effects.removeDefaults()
            }
        }
        logger.notice("uninstalled; incomplete: \(String(describing: failed), privacy: .public)")
        return failed
    }

    /// After the run: say what couldn't be done (the one thing a person may
    /// have to finish is dragging the app to the Trash), then quit.
    @MainActor
    static func finish(failed: [Step]) {
        let trash = failed.first { if case .trashApp = $0 { return true }; return false }
        if case .trashApp(let url) = trash {
            let alert = NSAlert()
            alert.messageText = "CodeSaver couldn't move itself to the Trash"
            alert.informativeText = "Everything else is gone. Drag CodeSaver from \(url.deletingLastPathComponent().path) to the Trash to finish."
            alert.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        NSApp.terminate(nil)
    }
}
