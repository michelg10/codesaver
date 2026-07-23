//
//  ContentView.swift
//  CodeSaver
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Main view for the host application. Shows extension registration status
//  and provides install / uninstall and "set as active screensaver" actions.
//

import SwiftUI

private let logger = AppexLog.logger("HostApp")

/// The igniter LaunchAgent's defaults domain — the app writes hot-corner
/// config there; the agent re-reads it within seconds.
private let igniterDefaults = UserDefaults(suiteName: "com.michelg10.CodeSaver.Igniter")

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pluginManager = PluginManager()
    @State private var statusMessage = "Ready"
    @State private var cornerTL = igniterDefaults?.integer(forKey: "cornerTL") ?? 0
    @State private var cornerTR = igniterDefaults?.integer(forKey: "cornerTR") ?? 0
    @State private var cornerBL = igniterDefaults?.integer(forKey: "cornerBL") ?? 0
    @State private var cornerBR = igniterDefaults?.integer(forKey: "cornerBR") ?? 0
    @State private var idleTimeout = igniterDefaults?.integer(forKey: "idleTimeout") ?? 0

    var body: some View {
        VStack(spacing: 20) {
            // MARK: - Header
            Image(systemName: "tv")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("CodeSaver")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Screensaver Extension")
                .font(.title2)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Extension Status
            Text("Extension Status")
                .font(.headline)

            extensionStatusView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Screensaver Activation
            Text("Screensaver Activation")
                .font(.headline)

            screensaverActivationView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Hot Corners
            Text("Hot Corners")
                .font(.headline)

            hotCornersView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Idle Trigger
            Text("Idle Trigger")
                .font(.headline)

            idleTriggerView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Actions
            HStack(spacing: 12) {
                Button("Open Preview") {
                    openWindow(id: "preview")
                }
                .buttonStyle(.borderedProminent)

                Button("Open Screen Saver Settings") {
                    openScreenSaverSettings()
                }
                .buttonStyle(.bordered)
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .fixedSize()
    }

    @ViewBuilder
    private var extensionStatusView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(pluginManager.isInstalled ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)

                    if pluginManager.isInstalled {
                        Text("Installed")
                            .fontWeight(.medium)
                        if let version = pluginManager.installedVersion {
                            Text("(v\(version))")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Not Installed")
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if pluginManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button {
                            pluginManager.checkInstallationStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")
                    }
                }

                if pluginManager.isInstalled {
                    if let path = pluginManager.installedPath {
                        HStack(alignment: .top) {
                            Text("Path:")
                                .foregroundColor(.secondary)
                            Text(path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                } else {
                    if let embeddedVersion = pluginManager.embeddedVersion {
                        Text("Embedded version: \(embeddedVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = pluginManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    if pluginManager.isInstalled {
                        Button("Uninstall") {
                            uninstallExtension()
                        }
                        .buttonStyle(.bordered)
                        .disabled(pluginManager.isLoading)
                    } else {
                        Button("Install") {
                            installExtension()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pluginManager.isLoading)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var screensaverActivationView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(pluginManager.isActiveScreensaver ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)

                    if pluginManager.isActiveScreensaver {
                        Text("Active")
                            .fontWeight(.medium)
                    } else {
                        Text("Not Active")
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if pluginManager.isCheckingScreensaver {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button {
                            pluginManager.checkScreensaverStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")
                    }
                }

                if let error = pluginManager.screensaverError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if pluginManager.isInstalled && !pluginManager.isActiveScreensaver {
                    HStack {
                        Spacer()
                        Button("Enable as Screensaver") {
                            Task {
                                await pluginManager.enableAsScreensaver()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pluginManager.isCheckingScreensaver)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(8)
        }
    }

    // Corner config int: bit 0 = armed, bits 1–4 = required ⌘/⌥/⌃/⇧
    // (decoded by the igniter's cornerFlags). The picker covers single
    // modifiers; combos work via `defaults write` on the same keys.
    @ViewBuilder
    private var hotCornersView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        cornerPicker("Top Left", "cornerTL", $cornerTL)
                        cornerPicker("Top Right", "cornerTR", $cornerTR)
                    }
                    GridRow {
                        cornerPicker("Bottom Left", "cornerBL", $cornerBL)
                        cornerPicker("Bottom Right", "cornerBR", $cornerBR)
                    }
                }
                Text("""
                CodeSaver detects these corners itself: the igniter captures \
                your desktop at the moment of trigger, then starts the \
                screensaver — the capture can never go stale. Turn off \
                “Start Screen Saver” in System Settings → Desktop & Dock → \
                Hot Corners so macOS doesn’t race it. On multi-display \
                setups only corners that trap the cursor count; seams \
                between displays never trigger.
                """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var idleTriggerView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Start screensaver after", selection: Binding(
                    get: { idleTimeout },
                    set: { v in
                        idleTimeout = v
                        igniterDefaults?.set(v, forKey: "idleTimeout")
                    })) {
                    Text("Use macOS setting").tag(0)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
                .pickerStyle(.menu)
                .frame(width: 320, alignment: .leading)
                Text(idleTimeout > 0
                    ? """
                    CodeSaver starts the screensaver itself after this much \
                    inactivity, capturing the desktop at that exact moment — \
                    proactive idle captures are off in this mode. Set macOS's \
                    own screen saver to Never (System Settings → Lock Screen → \
                    “Start Screen Saver when inactive”) so the two don't race, \
                    and keep display sleep later than this timeout.
                    """
                    : """
                    macOS's own timeout starts the screensaver; CodeSaver \
                    pre-captures the desktop 20 seconds into idle and \
                    refreshes it every 5 minutes so the boom always shows the \
                    current screen.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private func cornerPicker(_ label: String, _ key: String,
                              _ state: Binding<Int>) -> some View {
        Picker(label, selection: Binding(
            get: { state.wrappedValue },
            set: { v in
                state.wrappedValue = v
                igniterDefaults?.set(v, forKey: key)
            })) {
            Text("Off").tag(0)
            Text("Instant").tag(1)
            Text("⌘ Command").tag(3)
            Text("⌥ Option").tag(5)
            Text("⌃ Control").tag(9)
            Text("⇧ Shift").tag(17)
        }
        .pickerStyle(.menu)
        .frame(width: 190, alignment: .leading)
    }

    private func installExtension() {
        statusMessage = "Installing extension..."
        do {
            try pluginManager.install()
            statusMessage = "Extension installed successfully"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
            logger.error("Install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uninstallExtension() {
        statusMessage = "Uninstalling extension..."
        do {
            try pluginManager.uninstall()
            statusMessage = "Extension uninstalled successfully"
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
            logger.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    ContentView()
}
