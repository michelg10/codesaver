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
//     trigger, with macOS's grammar — hold the modifier FIRST, then drive
//     the cursor into the corner (CornerGesture). On a hit the agent
//     captures (or rides a just-taken approach capture) and then starts
//     the saver itself via ScreenSaverEngine — capture strictly precedes
//     launch, so the boom's desktop can never be stale. Meant to replace
//     the macOS hot corner entirely (turn macOS's off; it would race this
//     one).
//
//   codesaver-igniter                 watcher mode (what the LaunchAgent runs)
//   codesaver-igniter --capture       capture + write manifest once, then exit
//   codesaver-igniter --corners       print corner config + geometry, then exit
//
// Screen Recording permission is required for the pixelated-desktop act;
// without it the saver simply starts normally. Same at the lock screen:
// ScreenCaptureKit hands back zero displays there, so a corner hit at the
// lock screen starts the plain saver (there is no desktop to burn) — and
// must NOT be mistaken for a permission failure, whose ten-minute backoff
// would then swallow the boom for every hit that follows.
//
// Decisions and failures go to stderr with a timestamp; the LaunchAgent
// routes that to ~/Library/Logs/CodeSaver/igniter.log (helper/install.sh).

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

/// True while loginwindow's lock screen is up. Read from the session
/// dictionary — no permissions required. In this state ScreenCaptureKit
/// answers with an EMPTY display list (replayd logs "TCC Allow" and returns
/// content with no displays), so nothing can be captured.
func screenIsLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// stderr with a timestamp. The LaunchAgent plist points stderr at
/// ~/Library/Logs/CodeSaver/igniter.log, so the rare "why was there no
/// boom" line survives instead of vanishing into launchd's /dev/null.
func igniterLog(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) igniter: \(msg)\n".utf8))
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

/// The Screen Recording grant is keyed on code identity — the installed
/// LaunchAgent bundle's, which the bare build/ binary does not share (TCC
/// attributes a shell-launched binary to its responsible process, usually
/// the terminal). CLI diagnostics say so, or a preflight answer from build/
/// reads as the agent's and sends the user re-granting a permission it has.
func identityCaveat() -> String? {
    if Bundle.main.bundleIdentifier == "com.michelg10.CodeSaver.Igniter" { return nil }
    return "   ^ for THIS binary's identity, not the installed agent's (TCC keys the grant on code\n"
        + "     identity). The agent's own verdict is every 'capture denied' line in\n"
        + "     ~/Library/Logs/CodeSaver/igniter.log; its grant is 'CodeSaver Igniter' under\n"
        + "     System Settings → Privacy & Security → Screen Recording."
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

/// The hot-corner recognizer, with the grammar macOS's own hot corners
/// use: hold the modifier FIRST, then drive the cursor into the corner.
/// Fed one sample at a time (cursor, modifiers held right now, armed
/// corners); answers with at most one event, and a hit at most once per
/// visit — the cursor has to leave by `rearm` before the next.
///
/// The accident this rules out: the cursor already rests in or beside a
/// corner (the Apple menu, the clock, a close box) and the hand reaches for
/// ⌘ — ⌘Tab, ⌘Q, ⌘C. Contact and modifier both hold, and a recognizer that
/// only asks "chord down while the cursor is in the corner?" fires. macOS
/// never does, because it reads the modifier off the mouse-moved event that
/// ENTERS the corner: a key pressed while the cursor rests is not a move.
/// So the chord's press is placed. A chord that lands with the cursor
/// already within `vicinity` of the corner is not the start of a gesture;
/// that corner stays cold until the cursor has left the vicinity (the
/// modifier may stay held — going out and coming back in is the gesture)
/// or the chord is released. A corner bound without modifiers ("instant")
/// has no chord to place and fires on contact as it always did.
struct CornerGesture {
    /// Contact: the cursor is pinned in the corner (the edges clamp it there).
    static let contact: CGFloat = 5
    /// A chord pressed with the cursor this close to the corner is no gesture.
    static let vicinity: CGFloat = 70
    /// One shot per visit: the cursor must leave by this much to re-arm.
    static let rearm: CGFloat = 100

    enum Event {
        case hit(CustomCorner)
        /// The corner's chord went down `distance` points from it — ignored.
        case vetoed(CustomCorner, distance: CGFloat)
    }

    private var armed = true
    /// The nearest corner's chord was held at the previous sample.
    private var chordHeld = false
    /// The chord landed inside the vicinity: cold until it lifts or the
    /// cursor leaves.
    private var vetoed = false

    mutating func sample(mouse: CGPoint, held: CGEventFlags,
                         corners: [CustomCorner]) -> Event? {
        guard let nearest = corners
            .map({ ($0, hypot($0.point.x - mouse.x, $0.point.y - mouse.y)) })
            .min(by: { $0.1 < $1.1 })
        else {
            self = CornerGesture()
            return nil
        }
        let (corner, distance) = nearest
        let chord = held.contains(corner.flags)
        let pressed = chord && !chordHeld
        chordHeld = chord
        if distance > Self.rearm { armed = true }
        if !chord || distance >= Self.vicinity { vetoed = false }
        if pressed, !corner.flags.isEmpty, distance < Self.vicinity {
            vetoed = true
            return .vetoed(corner, distance: distance)
        }
        guard armed, chord, !vetoed, distance < Self.contact else { return nil }
        armed = false
        return .hit(corner)
    }
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
///
/// The RECT form of captureImage is the one that keeps window shadows. Its
/// filter sibling composites each window's own surface into the display rect
/// and leaves the WindowServer's framing behind it, so every window comes
/// back a flat cutout and the desktop reads as paper — measurably so: across
/// a window edge the framebuffer ramps 245→229 and the filter capture is a
/// dead-flat 247. `ignoreShadowsDisplay` is already false on that path and
/// toggling it changes nothing (nor does `capturesShadowsOnly`); the shadows
/// never enter it at all. captureImage(in:) takes global display POINTS, and
/// hands back native retina pixels with no cursor on its own — which is why
/// the display-mode lookup and showsCursor live only in the fallback.
func captureDisplays(completion: @escaping ([CGDirectDisplayID: CGImage], String?) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        guard let content else {
            let why = "shareable content: \(error?.localizedDescription ?? "nil, no error")"
            DispatchQueue.main.async { completion([:], why) }
            return
        }
        // This handler arrives on ScreenCaptureKit's replayd XPC queue
        // (com.apple.NSXPCConnection.m-user.com.apple.replayd), and the rect
        // capture below needs that same queue to deliver. Anything that blocks
        // it — the leak probe's semaphore did — makes captureImage(in:) give
        // up after ~5 s with a nil image and no error, which read as "probe
        // inconclusive, retry next time" forever: two days of unbalanced
        // captures (46 leaked surfaces) with the fix "installed". So the
        // captures run off this queue. Verified 2026-09-07 with a standalone
        // test: same probe, 5.09 s → nil on the callback queue, 0.13 s → image
        // (+1 leaked region) from a global queue.
        DispatchQueue.global(qos: .userInitiated).async {
            captureListedDisplays(content, completion: completion)
        }
    }
}

/// The per-display half of `captureDisplays`, on a queue of our own.
private func captureListedDisplays(_ content: SCShareableContent,
                                   completion: @escaping ([CGDirectDisplayID: CGImage], String?) -> Void) {
    // An empty display list is what the lock screen looks like — not an
    // error, and `captureImage` is never even called.
    let why = content.displays.isEmpty ? "shareable content lists no displays" : nil
    var result: [CGDirectDisplayID: CGImage] = [:]
    let lock = NSLock()
    let group = DispatchGroup()
    for display in content.displays {
        group.enter()
        let store: (CGImage?) -> Void = { image in
            if let image {
                lock.lock()
                result[display.displayID] = image
                lock.unlock()
            }
            group.leave()
        }
        if #available(macOS 15.2, *) {
            let balance = rectCaptureLeaks(on: display.displayID)
            SCScreenshotManager.captureImage(in: CGDisplayBounds(display.displayID)) { image, _ in
                // macOS 26.6: this form's completion block hands the CGImage
                // over at +1 and never releases it, so every capture leaks a
                // full-display IOSurface — charged to WindowServer, not to us.
                // Balance it, but only when the probe below has seen the leak
                // on this OS, so a fixed OS can't be over-released. Full story
                // at "captureImage(in:) leak probe".
                if balance, let image { Unmanaged.passUnretained(image).release() }
                store(image)
            }
        } else {
            let config = SCStreamConfiguration()
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            config.width = mode.map(\.pixelWidth) ?? display.width
            config.height = mode.map(\.pixelHeight) ?? display.height
            config.showsCursor = false
            SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: config
            ) { image, _ in store(image) }
        }
    }
    group.notify(queue: .main) {
        completion(result, result.isEmpty
            ? (why ?? "\(content.displays.count) display(s) listed, every capture came back nil")
            : nil)
    }
}


// MARK: - captureImage(in:) leak probe
//
// Found 2026-09-05 on macOS 26.6.2 (25G83), chasing "WindowServer uses 16 GB":
//
//   • WindowServer's footprint was 13 GB of "Owned physical footprint
//     (unmapped)": 435 IOSurfaces named "SL.205:CaptureSurface", 3456x2234
//     BGRA, 29.5 MiB each — one per rect-form capture this agent had taken in
//     three days. WindowServer creates every ScreenCaptureKit screenshot
//     surface and stays its memory-ledger owner, so a client that leaks
//     screenshots inflates WindowServer while its own footprint sits at
//     ~5 MB. Restarting this agent dropped WindowServer to 2.8 GB instantly.
//     (The hundreds of "Packages Display N Shield" windows people blame are a
//     separate, byte-sized leak — five per display sleep — a red herring.)
//   • `leaks` on a 30-line reproducer: the CGImage is a ROOT LEAK, retain
//     count 1, no referrers, owning CGDataProvider → IOSurface. Disassembly of
//     __60+[SCScreenshotManager captureImageInRect:completionHandler:]_block_invoke:
//     bl SLSDisplayCreateImage (SkyLight, returns +1) → mov x1, x0 → tear
//     down the frame → braa into the completion handler. A tail call: nothing
//     runs after the handler, so nothing can release. The nil-handler path
//     returns without releasing either.
//   • dtrace on every retain/release of that pointer: SkyLight balances its
//     own array bookkeeping and returns +1 correctly; the Swift handler
//     thunk's retain/release pair is balanced; nobody touches it afterwards.
//     The filter form (captureImageWithFilter:configuration: — an XPC round
//     trip to replayd, composited from each window's own surface, hence no
//     shadows) calls CFRelease right after its handler returns. Two unrelated
//     implementations; only the rect one — the shadowed one we want — has the
//     bug.
//   • Reported to Apple via Feedback Assistant (reproducer, evidence and the
//     analysis above in ~/Desktop/FB-SCK-leak).
//
// So the fix on our side is exactly one release — the +1 the block owes —
// done from inside the handler. It is gated by a runtime probe rather than an
// OS-version check: the day Apple adds the missing release, an unconditional
// extra one would be an over-release and a crash. The probe costs one capture
// and, on an affected OS, one leaked surface per process lifetime.
//
// The probe waits on a semaphore, so it must not run on ScreenCaptureKit's own
// callback queue: the rect capture is delivered through that queue and, when
// it is blocked, comes back nil (no error) after ~5 s — an "inconclusive"
// probe every time. `captureDisplays` hops to a global queue before calling
// it; keep it that way.

/// Mapped IOSurface regions >= 8 MB in this process — a leaked rect capture is
/// one full-display surface, so a probe capture that leaks shows up as +1 here.
/// Plain Mach VM introspection of our own task; no privileges needed.
private func bigIOSurfaceRegionCount() -> Int {
    var addr: mach_vm_address_t = 0
    var n = 0
    while true {
        var size: mach_vm_size_t = 0
        var depth: UInt32 = 0
        var info = vm_region_submap_info_data_64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<Int32>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                mach_vm_region_recurse(mach_task_self_, &addr, &size, &depth, $0, &count)
            }
        }
        if kr != KERN_SUCCESS { break }
        if info.user_tag == UInt32(VM_MEMORY_IOSURFACE), size >= 8 * 1024 * 1024 { n += 1 }
        addr += size
    }
    return n
}

private var rectCaptureLeakVerdict: Bool?

/// Does SCScreenshotManager.captureImage(in:) leak its image on this OS?
/// Probed once per process: one capture, released at once, then check whether
/// a full-display IOSurface mapping stuck around. Costs one capture (~50 ms)
/// and, on an affected OS, one leaked surface for the life of the process.
/// An inconclusive probe (no image — lock screen, no permission) is retried
/// on the next call rather than cached.
@available(macOS 15.2, *)
private func rectCaptureLeaks(on display: CGDirectDisplayID) -> Bool {
    if let known = rectCaptureLeakVerdict { return known }
    let before = bigIOSurfaceRegionCount()
    let sem = DispatchSemaphore(value: 0)
    var got = false
    var answered = true
    autoreleasepool {
        SCScreenshotManager.captureImage(in: CGDisplayBounds(display)) { image, _ in
            got = image != nil
            sem.signal()
        }
        // Bounded: a healthy probe answers in ~0.13 s and a blocked delivery
        // queue in ~5 s. A replayd that never answers must not park this
        // thread forever with `capturing` latched — that would silence every
        // capture and queue every corner hit for good.
        answered = sem.wait(timeout: .now() + 15) == .success
    }
    guard answered else {
        igniterLog("captureImage(in:) leak probe: no answer in 15 s — inconclusive, will retry")
        return false
    }
    guard got else { return false }
    let leaks = bigIOSurfaceRegionCount() > before
    rectCaptureLeakVerdict = leaks
    igniterLog("captureImage(in:) leak probe: \(leaks ? "leaks on this OS — balancing releases enabled" : "clean")")
    return leaks
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
    private var gesture = CornerGesture()
    /// The recognizer's own clock; runs only while a custom corner is armed.
    private var gestureTimer: Timer?
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
                  !saverUp, !screenIsLocked() {
            // Proactive scout (macOS owns the trigger): capture once the
            // user has settled, then refresh every few minutes while they
            // stay away — never once the saver itself is on the glass, and
            // not at the lock screen (SCK lists no displays there; a failed
            // shot no longer latches this gate, so without the check it
            // would re-ask every tick until unlock).
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
            pollGesture(!custom.isEmpty)
        }
        let m = mouseCG()

        // Approach path (Dock corners and custom corners alike): cursor
        // nearing a trigger corner → capture NOW, so the trigger itself
        // needs no wait.
        // Never while the saver is on the glass: the cursor stays parked in
        // the corner after a hit, so without this guard the scout re-shoots
        // every 5 s — photographing the boom itself, and a rapid re-hit
        // would then ride that saver-photo as if it were the desktop.
        if captureOK, idle < captureAfterIdle, !capturing, !saverUp,
           Date().timeIntervalSince(lastCornerCapture) > 5 {
            let near = corners.contains(where: { hypot($0.x - m.x, $0.y - m.y) < cornerProximity })
                || custom.contains(where: { hypot($0.point.x - m.x, $0.point.y - m.y) < cornerProximity })
            if near, !screenIsLocked() {
                lastCornerCapture = Date()
                capture(kind: "corner")
            }
        }
    }

    /// Custom-corner HIT — CodeSaver's own trigger, replacing the macOS hot
    /// corner — runs on its own clock, not the scout's. The grammar rests
    /// on ORDER: the chord must be seen down before the cursor arrives, and
    /// at 5 Hz a flick from the vicinity into the corner fits inside one
    /// tick, so a ⌘ pressed with the cursor at rest in the corner and a ⌘
    /// held on the way in look the same. Cursor and modifier state are
    /// shared-memory reads (well under a microsecond each), so 50 Hz costs
    /// nothing and places the press within a few points of where it
    /// happened — and a real hit answers in 20 ms instead of 200.
    private func pollGesture(_ on: Bool) {
        if on, gestureTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                self?.gestureTick()
            }
            t.tolerance = 0.005
            gestureTimer = t
        } else if !on, let t = gestureTimer {
            t.invalidate()
            gestureTimer = nil
            gesture = CornerGesture()
        }
    }

    private func gestureTick() {
        switch gesture.sample(mouse: mouseCG(), held: heldModifiers(), corners: custom) {
        case .hit?:
            guard Date().timeIntervalSince(lastLaunch) > 3 else { return }
            lastLaunch = Date()
            triggerSaver(kind: "corner")
        case .vetoed(_, let distance)?:
            igniterLog(String(format: "corner ignored: modifier pressed with the cursor already %.0f pt from it (hold the modifier first, then enter)", distance))
        case nil:
            break
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
                  Date().timeIntervalSince(lastCornerCapture) < 4,
                  lastCornerCapture > lastSaverExit {
            // Only a capture taken since the last saver dismissal can be
            // ridden — anything older shows a desktop the user has since
            // changed (or the saver itself).
            launchSaver("\(kind): riding the approach capture")
        } else if screenIsLocked() {
            // Nothing to capture at the lock screen; don't even ask SCK.
            launchSaver("\(kind) at the lock screen: plain saver, no capture")
        } else if Date() < captureBackoffUntil {
            launchSaver("\(kind) during capture backoff: plain saver")
        } else {
            if kind == "corner" { lastCornerCapture = Date() }
            capture(kind: kind) { [weak self] in self?.launchSaver("\(kind): fresh capture") }
        }
    }

    private func launchSaver(_ why: String) {
        igniterLog("launching saver — \(why)")
        let url = URL(fileURLWithPath:
            "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                igniterLog("saver launch failed: \(error.localizedDescription)")
            }
        }
    }

    private func capture(kind: String, then: (() -> Void)? = nil) {
        capturing = true
        let mouse = mouseCG()
        captureDisplays { [weak self] images, why in
            var userReturned = false
            // No images: write nothing (the saver then starts normally) —
            // but only ONE of the possible reasons deserves the long backoff.
            //  • Screen Recording denied: asked directly, without prompting
            //    (CGPreflightScreenCaptureAccess). Ten minutes before the
            //    next try, so the TCC prompt isn't spammed.
            //  • Lock screen: ScreenCaptureKit lists zero displays there.
            //    Nothing to capture and nothing wrong — no backoff at all.
            //    (Inferring "no permission" from the empty result used to
            //    poison the next ten minutes: every corner hit, even from
            //    the unlocked desktop, launched a boomless saver.)
            //  • Anything else is a transient SCK/replayd hiccup: retry
            //    almost at once.
            if images.isEmpty {
                // Whatever manifest is on disk predates this attempt: a
                // corner hit must not ride it — and it is a screenshot of
                // the desktop, so it must not outlive its owner flag either
                // (the return-cleanup only sweeps what a flag says is
                // there; drop the flag alone and the file is orphaned).
                // Delete it and forget the attempt outright, so the retry
                // is a real one: the idle gate re-opens the moment the
                // backoff passes instead of waiting out idleRefreshEvery
                // on a latch that was set before the shot came back.
                deleteManifest()
                self?.idleCaptured = false
                self?.cornerCaptured = false
                if kind == "corner" { self?.lastCornerCapture = .distantPast }
                else { self?.lastIdleCapture = .distantPast }
                let detail = why ?? "no detail"
                if !CGPreflightScreenCaptureAccess() {
                    igniterLog("\(kind) capture denied — no Screen Recording permission (\(detail)); backing off 10 min")
                    self?.captureBackoffUntil = Date().addingTimeInterval(600)
                } else if screenIsLocked() {
                    igniterLog("\(kind) capture skipped — screen is locked, no desktop to capture (\(detail))")
                } else {
                    igniterLog("\(kind) capture empty — \(detail); retrying in 2 s")
                    self?.captureBackoffUntil = Date().addingTimeInterval(2)
                }
            } else if kind == "idle", idleSeconds() < 1.0 {
                // The user returned during the shot's latency. The return-
                // cleanup already ran (nothing to delete then) and reset
                // idleCaptured — writing now would orphan a screenshot on
                // disk with nothing left to delete it. Drop the capture —
                // and the launch that was waiting on it: an idle-timeout
                // launch decided 300 ms ago would otherwise start the saver
                // over a user who is back at the keyboard. (A corner hit
                // that landed mid-capture still rides below: that one was
                // the user's own hand.)
                userReturned = true
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
                self?.launchSaver("\(kind): hit landed mid-capture, riding it")
            }
            if userReturned {
                if then != nil {
                    igniterLog("\(kind) launch dropped — the user returned during the capture")
                }
            } else {
                then?()
            }
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
            print("screen locked = \(screenIsLocked())")
            print("screen recording granted (preflight) = \(CGPreflightScreenCaptureAccess())")
            if let caveat = identityCaveat() { print(caveat) }
            exit(0)
        }

        if CommandLine.arguments.contains("--capture") {
            captureDisplays { images, why in
                writeManifest(kind: "idle", mouse: mouseCG(), captures: images)
                print("manifest written (\(images.count) display(s) captured)"
                      + (why.map { " — \($0)" } ?? ""))
                if images.isEmpty, let caveat = identityCaveat() { print(caveat) }
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
