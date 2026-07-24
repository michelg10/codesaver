import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit

// codesaver-igniter — CodeSaver's capture scout.
//
// macOS's own screensaver trigger (idle timeout or hot corner) starts the
// saver; this agent's only job is to make sure a fresh capture manifest is
// waiting when it does. The saver plays the entire boom itself.
//
//   • Idle: once the user has been inactive for a bit, capture every display
//     and record the mouse. The screen and cursor are frozen *because* the
//     user is idle, so one capture stays valid until they return — at which
//     point the manifest is deleted. The saver plays a 5-second armed
//     pre-animation before detonating.
//   • Hot corner: when the cursor approaches a corner the Dock has bound to
//     "Start Screen Saver", capture pre-emptively; the saver sees a fresh
//     corner-kind manifest and detonates immediately, no countdown.
//   • Custom corner (config app → cornerTL/TR/BL/BR in this agent's defaults
//     domain; bit 0 armed, bits 1–4 required ⌘/⌥/⌃/⇧): CodeSaver's OWN
//     trigger. On a true corner hit — with the required modifiers held —
//     the agent captures (or rides a just-taken approach capture) and then
//     starts the saver itself via ScreenSaverEngine — capture strictly
//     precedes launch, so the boom's desktop can never be stale. Meant to
//     replace the macOS hot corner entirely (turn macOS's off; it would
//     race this one).
//
//   codesaver-igniter                 watcher mode (what the LaunchAgent runs)
//   codesaver-igniter --capture       capture + write manifest once, then exit
//   codesaver-igniter --corners       print corner config + geometry, then exit
//
// Screen Recording permission is required for the pixelated-desktop act;
// without it the saver simply starts normally.

// MARK: - Probes

/// Seconds since the last user input, no permissions required.
func idleSeconds() -> Double {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                .otherMouseDown, .leftMouseDragged, .keyDown,
                                .scrollWheel, .flagsChanged]
    return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        .min() ?? 0
}

/// True while something (video playback, a presentation…) holds a
/// display-sleep assertion — the system saver won't trigger either.
func displayKeptAwake() -> Bool {
    var dict: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
          let status = dict?.takeRetainedValue() as? [String: Int] else { return false }
    return (status["PreventUserIdleDisplaySleep"] ?? 0) > 0
}

func primaryHeight() -> CGFloat {
    NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
}

/// Mouse position in global CG (top-left origin) coordinates.
func mouseCG() -> CGPoint {
    let loc = NSEvent.mouseLocation
    return CGPoint(x: loc.x, y: primaryHeight() - loc.y)
}

func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    return count > 0 ? Array(ids.prefix(Int(count))) : [CGMainDisplayID()]
}

/// Corners the Dock has bound to "Start Screen Saver" (wvous value 5),
/// as global CG points. Re-read occasionally in case the user reconfigures.
func saverHotCorners() -> [CGPoint] {
    guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return [] }
    var corners: [CGPoint] = []
    for id in activeDisplays() {
        let b = CGDisplayBounds(id)
        let map: [(String, CGPoint)] = [
            ("wvous-tl-corner", CGPoint(x: b.minX, y: b.minY)),
            ("wvous-tr-corner", CGPoint(x: b.maxX, y: b.minY)),
            ("wvous-bl-corner", CGPoint(x: b.minX, y: b.maxY)),
            ("wvous-br-corner", CGPoint(x: b.maxX, y: b.maxY)),
        ]
        for (key, point) in map where dock.integer(forKey: key) == 5 {
            corners.append(point)
        }
    }
    return corners
}

// MARK: - Custom corners (CodeSaver's own trigger)

/// The agent's config domain. Deployed, this process IS
/// com.michelg10.CodeSaver.Igniter (the LaunchAgent app bundle), and macOS
/// refuses UserDefaults(suiteName:) matching your own bundle ID — reads
/// silently return zero. There the domain is simply .standard; the
/// suite-name path covers the bare build/ binary (no bundle ID).
func igniterDefaults() -> UserDefaults? {
    if Bundle.main.bundleIdentifier == "com.michelg10.CodeSaver.Igniter" {
        return .standard
    }
    return UserDefaults(suiteName: "com.michelg10.CodeSaver.Igniter")
}

struct CustomCorner {
    var point: CGPoint         // global CG (top-left origin)
    var flags: CGEventFlags    // required modifiers (empty = none)
}

/// Decodes one corner config int: bit 0 = armed, bit 1 = ⌘, bit 2 = ⌥,
/// bit 3 = ⌃, bit 4 = ⇧. 0 (the unset default) = off.
func cornerFlags(_ raw: Int) -> CGEventFlags? {
    guard raw & 1 == 1 else { return nil }
    var f = CGEventFlags()
    if raw & 2 != 0 { f.insert(.maskCommand) }
    if raw & 4 != 0 { f.insert(.maskAlternate) }
    if raw & 8 != 0 { f.insert(.maskControl) }
    if raw & 16 != 0 { f.insert(.maskShift) }
    return f
}

/// The config app's armed corners as global CG points. Every display
/// contributes its copy of an armed corner, but only where the cursor is
/// actually TRAPPED: on a multi-display desktop, a display corner that
/// opens onto a neighbor (a seam corner, or a shorter display's edge
/// meeting a taller one) is a thoroughfare the cursor crosses all day —
/// never a trigger.
func customCorners(_ defaults: UserDefaults?) -> [CustomCorner] {
    guard let d = defaults else { return [] }
    let wanted: [(key: String, ix: CGFloat, iy: CGFloat)] = [
        ("cornerTL", 1, 1), ("cornerTR", -1, 1),
        ("cornerBL", 1, -1), ("cornerBR", -1, -1),
    ]
    let bounds = activeDisplays().map { CGDisplayBounds($0) }
    var out: [CustomCorner] = []
    for w in wanted {
        guard let flags = cornerFlags(d.integer(forKey: w.key)) else { continue }
        for b in bounds {
            let cx = w.ix > 0 ? b.minX : b.maxX
            let cy = w.iy > 0 ? b.minY : b.maxY
            // Escape probes just outside the two edges meeting at this
            // corner: if either lands on another display, the cursor can
            // slide past — not a corner it can be pinned into.
            let escH = CGPoint(x: cx - w.ix * 3, y: cy + w.iy * 3)
            let escV = CGPoint(x: cx + w.ix * 3, y: cy - w.iy * 3)
            if bounds.contains(where: { $0.contains(escH) || $0.contains(escV) }) {
                continue
            }
            out.append(CustomCorner(point: CGPoint(x: cx, y: cy), flags: flags))
        }
    }
    return out
}

/// Modifiers currently held — HID state, no permissions required.
func heldModifiers() -> CGEventFlags {
    CGEventSource.flagsState(.combinedSessionState)
}

/// True while a screensaver is on screen — the capture scout must never
/// photograph the saver itself (a refresh capturing boom frames would feed
/// the NEXT boom garbage if the saver process were ever restarted in
/// place). Checks the appex, the engine, and the legacy host by name.
func saverIsRunning() -> Bool {
    var pids = [pid_t](repeating: 0, count: 4096)
    let ret = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    let count = min(Int(ret), pids.count)
    guard count > 0 else { return false }
    var name = [CChar](repeating: 0, count: 64)
    for i in 0..<count where pids[i] > 0 {
        name[0] = 0
        proc_name(pids[i], &name, UInt32(name.count))
        let n = String(cString: name)
        if n == "CodeSaverExtension" || n == "ScreenSaverEngine"
            || n == "legacyScreenSaver" {
            return true
        }
    }
    return false
}

// MARK: - Capture + manifest

/// One-shot screenshots of every display at NATIVE pixel resolution.
/// SCDisplay.width/height are points; requesting them verbatim yields a 1×
/// capture — fine when it only fed the per-cell color averaging, visibly
/// soft now that the capture is the desktop the user stares at during the
/// armed settle. The retina pixel dimensions come from the display mode.
func captureDisplays(completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
        guard let content else { DispatchQueue.main.async { completion([:]) }; return }
        var result: [CGDirectDisplayID: CGImage] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for display in content.displays {
            group.enter()
            let config = SCStreamConfiguration()
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            config.width = mode.map(\.pixelWidth) ?? display.width
            config.height = mode.map(\.pixelHeight) ?? display.height
            config.showsCursor = false
            SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: config
            ) { image, _ in
                if let image {
                    lock.lock()
                    result[display.displayID] = image
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(result) }
    }
}

/// Both places the sandboxed appex and the unsandboxed harness can read.
func manifestDirs() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let rel = "Library/Application Support/CodeSaver"
    var dirs = [home.appendingPathComponent(rel)]
    let container = home.appendingPathComponent(
        "Library/Containers/com.michelg10.CodeSaver.Extension/Data")
    if FileManager.default.fileExists(atPath: container.path) {
        dirs.append(container.appendingPathComponent(rel))
    }
    return dirs
}

// Raw capture format ("CSRW" v1) — the decoded-pixel handoff. The capture is
// already a decoded bitmap in this process; JPEG-encoding it only forced the
// saver to burn hundreds of milliseconds decoding it back. Instead the pixels
// go to disk verbatim and the saver mmaps them: with the capture seconds old,
// the pages are still in the unified page cache, so the "load" is a handful
// of page-table entries — and Metal reads the mapping directly as a texture.
// Layout (little-endian UInt32s; mirrored by BoomCaptureBuffer in the saver):
//   [0] magic 0x43535257  [1] version 1  [2] width px  [3] height px
//   [4] bytesPerRow (256-aligned)  [5] pixelOffset (page-aligned)
// Pixels: BGRA8888, premultiplied-first, byte-order-32-little (.bgra8Unorm).
private let rawMagic: UInt32 = 0x4353_5257
private let rawPixelOffset = 16384   // ≥ any Apple page size, Metal-alignable

func rawCaptureData(_ cg: CGImage) -> Data? {
    let w = cg.width, h = cg.height
    guard w > 0, h > 0 else { return nil }
    let bpr = (w * 4 + 255) & ~255
    var data = Data(count: rawPixelOffset + h * bpr)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        let header = base.assumingMemoryBound(to: UInt32.self)
        header[0] = rawMagic
        header[1] = 1
        header[2] = UInt32(w)
        header[3] = UInt32(h)
        header[4] = UInt32(bpr)
        header[5] = UInt32(rawPixelOffset)
        guard let ctx = CGContext(data: base + rawPixelOffset, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? data : nil
}

func writeManifest(kind: String, mouse: CGPoint, captures: [CGDirectDisplayID: CGImage]) {
    var displays: [[String: Any]] = []
    var images: [(name: String, data: Data)] = []
    for (i, id) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(id)
        var entry: [String: Any] = ["x": b.origin.x, "y": b.origin.y,
                                    "w": b.width, "h": b.height]
        if let cg = captures[id], let raw = rawCaptureData(cg) {
            let name = "boom-display-\(i).raw"
            entry["image"] = name
            images.append((name, raw))
        }
        displays.append(entry)
    }
    let manifest: [String: Any] = [
        "kind": kind,
        "capturedAt": Date().timeIntervalSince1970,
        "mouseX": mouse.x, "mouseY": mouse.y,
        "displays": displays,
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: manifest) else { return }
    let fm = FileManager.default
    var primary: URL?
    for dir in manifestDirs() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in images {
            let dst = dir.appendingPathComponent(name)
            if let primary {
                // Same volume: hard-link instead of duplicating the pixels.
                // Link under a temp name, then rename(2) over the target —
                // atomic replace, so a reader holding the PREVIOUS manifest
                // never catches the image name momentarily absent. (The tmp
                // name keeps the boom- prefix: deleteManifest sweeps strays.)
                let tmp = dir.appendingPathComponent(name + ".tmp")
                try? fm.removeItem(at: tmp)
                if (try? fm.linkItem(at: primary.appendingPathComponent(name), to: tmp)) != nil,
                   rename(tmp.path, dst.path) == 0 {
                    // linked atomically over the old image
                } else {
                    try? fm.removeItem(at: tmp)
                    try? data.write(to: dst, options: .atomic)
                }
            } else {
                try? data.write(to: dst, options: .atomic)
            }
        }
        if primary == nil { primary = dir }
        // Manifest last: readers never see it before its images exist.
        try? json.write(to: dir.appendingPathComponent("boom-manifest.json"), options: .atomic)
    }
}

/// The captures encode the user's screen; they exist only while the user is
/// away (or a corner approach is in flight).
func deleteManifest() {
    for dir in manifestDirs() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { continue }
        for name in names where name.hasPrefix("boom-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - Watcher

final class Igniter {
    private let defaults = igniterDefaults()
    /// Idle seconds before the idle-kind capture is taken. Well under any
    /// sane system saver timeout, so the manifest is ready when macOS fires.
    private var captureAfterIdle: Double {
        let v = defaults?.double(forKey: "captureAfterIdle") ?? 0
        return v == 0 ? 20 : max(5, v)
    }
    private let cornerProximity: CGFloat = 60

    /// Custom idle timeout (seconds; 0/absent = off): CodeSaver starts the
    /// saver ITSELF after this much inactivity — capture at the moment of
    /// launch, proactive scouting off. The user disables macOS's own saver
    /// timeout in this mode. Clamped ≥10 s against defaults-write typos
    /// (10 is also the hands-on test value, set via defaults write — the
    /// app UI's smallest offering stays 1 minute).
    private var customIdleTimeout: Double? {
        let v = defaults?.integer(forKey: "idleTimeout") ?? 0
        return v > 0 ? Double(max(10, v)) : nil
    }
    /// Proactive idle captures refresh on this cadence — an "idle" desktop
    /// still drifts (notifications, finishing builds, ticking widgets).
    private let idleRefreshEvery: Double = 300

    private var idleCaptured = false
    private var idleLaunched = false
    private var lastIdleCapture = Date.distantPast
    private var cornerCaptured = false
    private var capturing = false
    private var lastCornerCapture = Date.distantPast
    private var corners: [CGPoint] = []
    private var custom: [CustomCorner] = []
    private var cornersReadAt = Date.distantPast
    /// One shot per corner visit: fires on entry, re-arms only after the
    /// cursor has properly left (>100 px from every armed corner).
    private var cornerArmed = true
    private var lastLaunch = Date.distantPast
    private var pendingLaunch = false
    private var saverWasRunning = false
    /// Stamped when the saver leaves the screen. A dismissal can leave no
    /// HID trace (Touch ID unlock; the secure-input lock screen swallows
    /// the wake event), so by the raw HID clock the user still looks
    /// "away" — and a corner-launched saver watched past idleTimeout
    /// would relaunch on the very next tick.
    private var lastSaverExit = Date.distantPast
    /// After a failed capture (permission denied), don't keep re-triggering
    /// the TCC prompt — retry occasionally.
    private var captureBackoffUntil = Date.distantPast

    init() {
        deleteManifest()   // never trust leftovers from a previous session
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        // After a permission-denied capture, captures back off — but corner
        // HITS keep working (the saver just starts without a boom).
        let captureOK = Date() >= captureBackoffUntil
        let saverUp = saverIsRunning()
        if saverWasRunning, !saverUp { lastSaverExit = Date() }
        saverWasRunning = saverUp
        // Idle as this agent scores it: a saver dismissal ends the idle
        // episode even when it left no HID trace, so every launch decision
        // starts a fresh clock from the moment the saver went away.
        let idle = min(idleSeconds(), Date().timeIntervalSince(lastSaverExit))

        // The user is here: no captures should exist. Corner captures get a
        // grace window (the saver may be about to consume them), then go too.
        if idle < 1.0 {
            idleLaunched = false
            if idleCaptured {
                deleteManifest()
                idleCaptured = false
            }
        }
        if cornerCaptured, idle < captureAfterIdle,
           Date().timeIntervalSince(lastCornerCapture) > 30 {
            deleteManifest()
            cornerCaptured = false
        }

        if let timeout = customIdleTimeout {
            // Self-triggered idle: CodeSaver owns the timeout. Capture at
            // the moment of launch (fresh by construction) — no proactive
            // scouting at all in this mode. One shot per idle episode.
            if idle >= timeout, !idleLaunched, !capturing,
               !displayKeptAwake(), !saverUp {
                idleLaunched = true
                triggerSaver(kind: "idle")
                return
            }
        } else if captureOK, idle >= captureAfterIdle, !capturing,
                  !displayKeptAwake(),
                  !idleCaptured
                      || Date().timeIntervalSince(lastIdleCapture) > idleRefreshEvery,
                  !saverUp {
            // Proactive scout (macOS owns the trigger): capture once the
            // user has settled, then refresh every few minutes while they
            // stay away — never once the saver itself is on the glass.
            lastIdleCapture = Date()
            capture(kind: "idle")
            idleCaptured = true
            return
        }

        // Corner geometry + config, refreshed often enough that config-app
        // edits and display re-arrangements land within seconds.
        if Date().timeIntervalSince(cornersReadAt) > 5 {
            corners = saverHotCorners()
            custom = customCorners(defaults)
            cornersReadAt = Date()
        }
        let m = mouseCG()

        // Approach path (Dock corners and custom corners alike): cursor
        // nearing a trigger corner → capture NOW, so the trigger itself
        // needs no wait.
        if captureOK, idle < captureAfterIdle, !capturing,
           Date().timeIntervalSince(lastCornerCapture) > 5 {
            let near = corners.contains(where: { hypot($0.x - m.x, $0.y - m.y) < cornerProximity })
                || custom.contains(where: { hypot($0.point.x - m.x, $0.point.y - m.y) < cornerProximity })
            if near {
                lastCornerCapture = Date()
                capture(kind: "corner")
            }
        }

        // Custom-corner HIT — CodeSaver's own trigger, replacing the macOS
        // hot corner. Requires the corner's modifiers held at the moment of
        // contact.
        if !custom.isEmpty {
            let nearest = custom.map { hypot($0.point.x - m.x, $0.point.y - m.y) }
                .min() ?? .infinity
            if nearest > 100 { cornerArmed = true }
            if cornerArmed, Date().timeIntervalSince(lastLaunch) > 8 {
                let held = heldModifiers()
                let hit = custom.contains {
                    hypot($0.point.x - m.x, $0.point.y - m.y) < 5
                        && held.contains($0.flags)
                }
                if hit {
                    cornerArmed = false
                    lastLaunch = Date()
                    triggerSaver(kind: "corner")
                }
            }
        }
    }

    /// Corner hit: make sure a fresh capture is on disk, then start the
    /// saver — strictly in that order; staleness is impossible by
    /// construction. A just-taken approach capture (the cursor was near
    /// this corner moments ago) is already fresh and rides for free.
    private func triggerSaver(kind: String) {
        if capturing {
            pendingLaunch = true
        } else if kind == "corner", cornerCaptured,
                  Date().timeIntervalSince(lastCornerCapture) < 4 {
            launchSaver()   // ride the approach pre-capture: still warm
        } else if Date() < captureBackoffUntil {
            launchSaver()   // no permission for the boom; plain saver still works
        } else {
            if kind == "corner" { lastCornerCapture = Date() }
            capture(kind: kind) { [weak self] in self?.launchSaver() }
        }
    }

    private func launchSaver() {
        let url = URL(fileURLWithPath:
            "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                FileHandle.standardError.write(
                    Data("igniter: saver launch failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func capture(kind: String, then: (() -> Void)? = nil) {
        capturing = true
        let mouse = mouseCG()
        captureDisplays { [weak self] images in
            // No images means no Screen Recording permission (or capture
            // failure): write nothing — the saver then starts normally —
            // and back off so we don't spam the TCC prompt.
            if images.isEmpty {
                FileHandle.standardError.write(Data("igniter: capture unavailable (screen recording permission?)\n".utf8))
                self?.captureBackoffUntil = Date().addingTimeInterval(600)
            } else if kind == "idle", idleSeconds() < 1.0 {
                // The user returned during the shot's latency. The return-
                // cleanup already ran (nothing to delete then) and reset
                // idleCaptured — writing now would orphan a screenshot on
                // disk with nothing left to delete it. Drop the capture.
            } else {
                writeManifest(kind: kind, mouse: mouse, captures: images)
                // Mark what's on disk so the return-cleanup knows to sweep
                // it — including custom-timeout launches, whose capture
                // doesn't come through the proactive path.
                if kind == "corner" { self?.cornerCaptured = true }
                else { self?.idleCaptured = true }
            }
            self?.capturing = false
            // A hit that landed while this capture was in flight rides it:
            // the capture (fresh either way) is on disk before the launch.
            if self?.pendingLaunch == true {
                self?.pendingLaunch = false
                self?.launchSaver()
            }
            then?()
        }
    }
}

// MARK: - Main

@main
struct IgniterMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        if CommandLine.arguments.contains("--corners") {
            let d = igniterDefaults()
            for key in ["cornerTL", "cornerTR", "cornerBL", "cornerBR"] {
                print("\(key) = \(d?.integer(forKey: key) ?? 0)")
            }
            for id in activeDisplays() {
                let b = CGDisplayBounds(id)
                print(String(format: "display %u: (%.0f, %.0f) %.0f×%.0f",
                             id, b.minX, b.minY, b.width, b.height))
            }
            for c in customCorners(d) {
                print(String(format: "ARMED corner (%.0f, %.0f) modifiers 0x%llx",
                             c.point.x, c.point.y, c.flags.rawValue))
            }
            for p in saverHotCorners() {
                print(String(format: "dock saver corner (%.0f, %.0f)", p.x, p.y))
            }
            exit(0)
        }

        if CommandLine.arguments.contains("--capture") {
            captureDisplays { images in
                writeManifest(kind: "idle", mouse: mouseCG(), captures: images)
                print("manifest written (\(images.count) display(s) captured)")
                exit(0)
            }
            app.run()
        }

        let igniter = Igniter()
        withExtendedLifetime(igniter) {
            app.run()
        }
    }
}
