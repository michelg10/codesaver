//
//  LifecycleViews.swift
//  CodeSaver
//
//  The app-lifecycle pieces of the window: the Screensaver step's control and
//  the rows under it (Move to Applications, progress, a failed Enable's way
//  out), the update row, Advanced's update/restore/uninstall rows, and the
//  uninstall sheet. Same vocabulary as ContentView: SF Mono, the Theme
//  palette, terse lowercase captions.
//

import SwiftUI

/// Step 1's trailing control.
struct ScreensaverStepControl: View {
    @ObservedObject var plugin: PluginManager

    var body: some View {
        if plugin.isEnabled {
            Text("active").font(Theme.mono(11)).foregroundStyle(Theme.slate)
        } else if plugin.isWorking || !plugin.hasProbed {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(plugin.phase ?? "checking the screen saver")
        } else {
            Button("Enable") { plugin.enable() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!AppLocation.isInstalled)
                .help(AppLocation.isInstalled
                      ? "make CodeSaver the screen saver on every display"
                      : "move CodeSaver to Applications first")
                .accessibilityHint(AppLocation.isInstalled
                                   ? "Makes CodeSaver the screen saver on every display"
                                   : "Unavailable until CodeSaver is in the Applications folder")
        }
    }
}

/// The rows under step 1, indented like the GitHub step's token row. Empty —
/// no rows, no spacing — when there's nothing to say.
struct ScreensaverStepDetail: View {
    @ObservedObject var plugin: PluginManager
    @ObservedObject var mover: AppMover

    var body: some View {
        if !AppLocation.isInstalled {
            MoveToApplicationsRow(mover: mover)
                .padding(.leading, 24)
        }
        if plugin.isWorking, let phase = plugin.phase {
            Text(phase)
                .font(Theme.mono(10)).foregroundStyle(Theme.slate)
                .padding(.leading, 24)
        }
        if let failure = plugin.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.message)
                    .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Open Screen Saver settings") { PluginManager.openScreenSaverSettings() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text(failure.pickHint)
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    if failure.canRetry && !plugin.isWorking {
                        Button("Try again") { plugin.enable() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .padding(.leading, 24)
        }
    }
}

/// Why Enable is greyed out, and the one click that fixes it.
struct MoveToApplicationsRow: View {
    @ObservedObject var mover: AppMover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if AppLocation.applicationsWritable {
                Text("running from \(AppLocation.friendlyLocation) — macOS only uses screen savers from the Applications folder")
                    .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Move to Applications") { mover.moveTapped() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(mover.isMoving)
                        .accessibilityHint("Copies CodeSaver into Applications, reopens it from there, and moves this copy to the Trash")
                    if mover.isMoving {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("moving to Applications")
                    }
                }
            } else {
                Text("this account can't add apps to Applications — in Finder, drag CodeSaver into Applications (macOS asks for an administrator's password), then open it from there")
                    .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show CodeSaver in Finder") { mover.revealOriginal() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let error = mover.error {
                Text(error)
                    .font(Theme.mono(11)).foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .alert("Replace the CodeSaver in Applications?",
               isPresented: Binding(get: { mover.confirmReplace != nil },
                                    set: { if !$0 { mover.confirmReplace = nil } }),
               presenting: mover.confirmReplace) { _ in
            Button("Replace", role: .destructive) { mover.move(replacing: true) }
            Button("Open the One in Applications") { mover.openInstalledCopy() }
            Button("Cancel", role: .cancel) {}
        } message: { existing in
            Text(existing.message)
        }
    }
}

/// Quiet: one slate line above the checklist, the whole row a link.
struct UpdateAvailableRow: View {
    let version: String

    var body: some View {
        Link(destination: UpdateCheck.siteURL) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("·").font(Theme.mono(13)).foregroundStyle(Theme.violetHot)
                    .accessibilityHidden(true)
                Text("update available · \(version)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.slate)
                Spacer()
                Text("codesaver.michelg10.com ↗")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Update available, \(version)")
        .accessibilityHint("Opens codesaver.michelg10.com")
        .accessibilityAddTraits(.isLink)
    }
}

/// Advanced's lifecycle rows; they flatten into Advanced's own stack.
struct LifecycleAdvancedRows: View {
    @ObservedObject var plugin: PluginManager
    @ObservedObject var updates: UpdateCheck
    let uninstall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("updates").font(Theme.mono(11)).foregroundStyle(Theme.slate)
            Toggle("check for updates", isOn: $updates.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityHint("Once a day while this window is open, asks GitHub whether a newer CodeSaver exists")
            Text(updates.enabled ? "once a day while this window is open · asks github.com"
                                 : "off — switch on to hear about new versions")
                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
        }
        if plugin.isActiveScreensaver, let previous = plugin.previousSaver {
            HStack(spacing: 8) {
                Text("before").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                Text(SaverControl.displayName(previous)).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                if plugin.previousRestorable {
                    Button("Restore previous screen saver") { plugin.restorePrevious() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(plugin.isWorking)
                } else {
                    Button("Open Screen Saver settings") { PluginManager.openScreenSaverSettings() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text("pick it there").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
            }
        }
        Button("Uninstall CodeSaver…", action: uninstall)
            .buttonStyle(.link)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.alert)
            .accessibilityHint("Lists everything that would be removed and asks before doing anything")
    }
}

/// The confirm sheet: exactly the plan's steps, in order, then quit.
struct UninstallSheet: View {
    @ObservedObject var plugin: PluginManager
    /// A corpus refresh would write into the container while it's deleted.
    let refreshing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var running = false

    private var steps: [Uninstaller.Step] { Uninstaller.plan(.current(plugin: plugin)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall CodeSaver")
                .font(Theme.mono(14, .semibold)).foregroundStyle(Theme.ink)
            Text("this removes, in this order:")
                .font(Theme.mono(11)).foregroundStyle(Theme.slate)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps, id: \.self) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("·").foregroundStyle(Theme.dim).accessibilityHidden(true)
                        Text(Uninstaller.describe(step)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.mono(11))
                }
            }
            Text("then CodeSaver quits. Nothing outside this list is touched.")
                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if refreshing {
                Text("a code refresh is running — wait for it to finish first")
                    .font(Theme.mono(11)).foregroundStyle(Theme.alert)
            }
            HStack(spacing: 10) {
                if running {
                    ProgressView().controlSize(.small).accessibilityLabel("uninstalling")
                    Text("uninstalling…").font(Theme.mono(11)).foregroundStyle(Theme.slate)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button("Uninstall", role: .destructive) { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.alert)
                    .disabled(running || refreshing || plugin.isWorking)
            }
            .controlSize(.small)
        }
        .padding(22)
        .frame(width: 440)
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private func start() {
        running = true
        let plan = steps
        Task {
            let failed = await Task.detached(priority: .userInitiated) {
                await Uninstaller.run(plan, .live)
            }.value
            Uninstaller.finish(failed: failed)
        }
    }
}
