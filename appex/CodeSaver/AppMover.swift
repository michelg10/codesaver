//
//  AppMover.swift
//  CodeSaver
//
//  "Move to Applications". macOS only runs the saver, and SMAppService only
//  keeps the agents, from one stable path — /Applications/CodeSaver.app — so a
//  copy opened anywhere else (Downloads, the disk image, a build folder) offers
//  to put itself there, relaunches from there, and trashes the original.
//

import AppKit
import Darwin

private let logger = AppexLog.logger("AppMover")

/// Where this copy of the app lives, and where it should.
enum AppLocation {
    static let installedPath = "/Applications/CodeSaver.app"
    static var installedURL: URL { URL(fileURLWithPath: installedPath, isDirectory: true) }

    /// The one path everything keys on: pluginkit's election, the wallpaper
    /// store's module URL, RefreshAgent/FeedsAgent's isAtStablePath.
    static var isInstalled: Bool { Bundle.main.bundlePath == installedPath }

    /// Where the person actually put the app. A quarantined download opened
    /// in place runs translocated — Gatekeeper's random read-only mount under
    /// /private/var/folders — and copying or trashing "the bundle" must mean
    /// the original, not the mount.
    static let originalURL: URL = translocatedOriginal(of: Bundle.main.bundleURL) ?? Bundle.main.bundleURL

    /// Copied into /Applications by something other than Finder (cp, a
    /// script), so still quarantined and translocated from its right place.
    static var isTranslocatedInPlace: Bool {
        !isInstalled && originalURL.standardizedFileURL.path == installedPath
    }

    static var isOnReadOnlyVolume: Bool {
        (try? originalURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }

    /// Re-checked on every tap: a standard (non-admin) account can't add to
    /// /Applications, and the copy has to happen in Finder with a password.
    static var applicationsWritable: Bool { FileManager.default.isWritableFile(atPath: "/Applications") }

    /// "Downloads", "the disk image" — for the move row's one-line reason.
    static var friendlyLocation: String {
        if isTranslocatedInPlace { return "a temporary copy macOS made" }
        if isOnReadOnlyVolume { return "the disk image" }
        let parent = originalURL.deletingLastPathComponent()
        return parent.path == NSHomeDirectory() ? "your home folder" : parent.lastPathComponent
    }

    /// App Translocation's SPI, looked up by name: Security.framework is
    /// already linked (the Keychain token), so this adds no dependency and no
    /// link-time reference to a private symbol. Both functions have shipped
    /// unchanged since 10.12; if either goes missing the app simply treats its
    /// bundle path as the original.
    static func translocatedOriginal(of url: URL) -> URL? {
        typealias IsTranslocated = @convention(c)
            (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
        typealias OriginalPath = @convention(c)
            (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil) != 0,
              translocated,
              let original = unsafeBitCast(originalSym, to: OriginalPath.self)(url as CFURL, nil) else { return nil }
        return original.takeRetainedValue() as URL
    }

    /// CFBundleShortVersionString / CFBundleVersion of a bundle on disk.
    static func versions(of bundle: URL) -> (short: String, build: String) {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleShortVersionString"] as? String ?? "?",
                info?["CFBundleVersion"] as? String ?? "?")
    }
}

@MainActor
final class AppMover: ObservableObject {
    /// The copy already in /Applications, for the replace confirmation.
    struct ExistingCopy {
        let version: String
        let build: String

        var message: String {
            let mine = AppLocation.versions(of: Bundle.main.bundleURL)
            let age = UpdateCheck.isNewer(version, than: mine.short) ? " — newer than this one" : ""
            return "Applications already has CodeSaver \(version) (\(build))\(age). This copy is "
                + "\(mine.short) (\(mine.build)). Replacing moves the old one to the Trash."
        }
    }

    @Published private(set) var isMoving = false
    @Published var error: String?
    @Published var confirmReplace: ExistingCopy?

    func moveTapped() {
        error = nil
        guard AppLocation.applicationsWritable else {
            error = "this account can't add apps to Applications — drag CodeSaver there in Finder"
            return
        }
        // Translocated in place: "replacing" the install means replacing
        // this very copy with an unquarantined one — nothing to confirm.
        if FileManager.default.fileExists(atPath: AppLocation.installedPath),
           !AppLocation.isTranslocatedInPlace {
            let v = AppLocation.versions(of: AppLocation.installedURL)
            confirmReplace = ExistingCopy(version: v.short, build: v.build)
        } else {
            move(replacing: AppLocation.isTranslocatedInPlace)
        }
    }

    /// Copy into place (staged, so a failed copy can't cost a working
    /// install), relaunch from /Applications, trash the original, quit.
    func move(replacing: Bool) {
        guard !isMoving else { return }
        isMoving = true
        error = nil
        let source = Bundle.main.bundleURL
        Task.detached(priority: .userInitiated) {
            let failure = Self.install(from: source, replacing: replacing)
            await self.finishMove(failure)
        }
    }

    /// Someone opened a second copy by mistake: use the installed one instead
    /// — bring it forward if it's already running, else launch it.
    func openInstalledCopy() {
        if let running = Self.runningInstalledCopies().first {
            running.activate()
            NSApp.terminate(nil)
        } else {
            relaunch(trashingOriginal: false)
        }
    }

    func revealOriginal() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLocation.originalURL])
    }

    private func finishMove(_ failure: String?) {
        if let failure {
            isMoving = false
            error = failure
            return
        }
        // The bundle swap leaves the wallpaper store's selection binding stale
        // even when the build number didn't change (the same version
        // downloaded twice), so the relaunched app repairs unconditionally.
        UserDefaults.standard.set(true, forKey: SelfRepair.forceKey)
        relaunch(trashingOriginal: true)
    }

    private func relaunch(trashingOriginal: Bool) {
        let config = NSWorkspace.OpenConfiguration()
        // Same bundle id is running (us): without this LaunchServices would
        // just bring this copy forward.
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: AppLocation.installedURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    self.isMoving = false
                    self.error = "couldn't open the copy in Applications: \(error.localizedDescription)"
                    return
                }
                if trashingOriginal { Self.trashOriginal() }
                NSApp.terminate(nil)
            }
        }
    }

    /// The copy the person launched. Nothing to trash on a disk image (it's
    /// read-only, and ejecting it is theirs to do), nor when it IS the install.
    private static func trashOriginal() {
        let original = AppLocation.originalURL
        guard original.standardizedFileURL.path != AppLocation.installedPath,
              !AppLocation.isOnReadOnlyVolume else { return }
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: nil)
        } catch {
            logger.warning("left the original at \(original.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The blocking part, off the main thread. Returns a plain-language
    /// failure, nil on success.
    nonisolated private static func install(from source: URL, replacing: Bool) -> String? {
        let fm = FileManager.default
        let dest = AppLocation.installedURL
        let staging = URL(fileURLWithPath: "/Applications/.CodeSaver.staging.app", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            return "couldn't copy CodeSaver into Applications: \(error.localizedDescription)"
        }
        // The copy carries the download's quarantine flag, and a quarantined
        // app that wasn't moved by Finder gets translocated all over again on
        // the relaunch. This bundle already passed Gatekeeper to get here.
        SaverControl.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])

        if fm.fileExists(atPath: dest.path) {
            guard replacing else {
                try? fm.removeItem(at: staging)
                return "Applications already has a CodeSaver"
            }
            if let reason = quitInstalledCopy() {
                try? fm.removeItem(at: staging)
                return reason
            }
            SaverControl.unregister(SaverControl.installedAppexPath)
            do {
                try fm.trashItem(at: dest, resultingItemURL: nil)
            } catch {
                do { try fm.removeItem(at: dest) } catch {
                    try? fm.removeItem(at: staging)
                    return "couldn't replace the CodeSaver in Applications: \(error.localizedDescription)"
                }
            }
        }
        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            return "couldn't put CodeSaver into Applications: \(error.localizedDescription)"
        }
        // This copy's own extension may hold pluginkit's election (macOS
        // registers the plug-ins of any app it launches); left there, it would
        // outrank the install until it vanished.
        let here = source.appendingPathComponent("Contents/PlugIns/CodeSaverExtension.appex").path
        if here != SaverControl.installedAppexPath { SaverControl.unregister(here) }
        logger.notice("installed \(source.path, privacy: .public) → \(dest.path, privacy: .public)")
        return nil
    }

    /// A running /Applications copy would keep its window open on a bundle
    /// that's in the Trash. Ask it to quit and give it a few seconds.
    nonisolated private static func quitInstalledCopy() -> String? {
        let running = runningInstalledCopies()
        guard !running.isEmpty else { return nil }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            usleep(100_000)
        }
        return running.contains(where: { !$0.isTerminated })
            ? "the CodeSaver in Applications is still open — quit it, then try again" : nil
    }

    /// Windowed instances of the /Applications copy. The refresh and feeds
    /// agents run the same executable but never become regular apps
    /// (main.swift branches before NSApplication), and asking them to quit
    /// would only stall here — the update repair restarts them instead.
    nonisolated private static func runningInstalledCopies() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.michelg10.CodeSaver")
            .filter { $0 != NSRunningApplication.current
                && $0.activationPolicy == .regular
                && $0.bundleURL?.standardizedFileURL.path == AppLocation.installedPath }
    }
}
