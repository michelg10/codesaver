//
//  FeedsService.swift
//  CodeSaver
//
//  The widget feed daemon: `CodeSaver --feeds`, kept alive by the
//  com.michelg10.CodeSaver.feeds LaunchAgent. Merges four sources into
//  one widgets/feed.json in the app-group container (the only place the
//  sandboxed saver can read):
//
//    1. ~/.claude/codesaver/sessions/*.json — per-session state written by
//       the Claude Code hook script (feeds/cc-state-hook.py) and statusline
//       wrapper: coarse state machine, permission waits, background tasks,
//       token counts.
//    2. ~/.bifrocate/cot/*.jsonl — bifrocate's main-agent CoT spools:
//       fine-grained thinking / toolcall-writing states and interrupt
//       (`superseded`) markers, ~1s off the wire.
//    3. Now playing — Music.app / Spotify via AppleScript, polled only
//       while the player is actually running; a paused track is held for
//       half an hour.
//    4. ~/.bifrocate/pins.json + pins.state.json — bifrocate's pin daemon:
//       which sessions are pinned (kept warm with keep-alive pings) and,
//       per pin, what the daemon will do next. A pinned session stays on
//       the rack while its pin lives, even past the hour.
//
//  Publish/subscribe. Each source is polled by its own PUBLISHER thread at
//  its own cadence, and the result — an immutable snapshot, stamped with
//  when the poll began — replaces that publisher's `latest` under a lock.
//  The main thread is the one SUBSCRIBER: every second it reads whatever is
//  latest from every publisher, merges, and writes feed.json. Nothing on
//  its path can block: it spawns no process and writes no file but the
//  feed. That is the point of the split. The daemon runs as a Background /
//  Nice / LowPriorityIO LaunchAgent, and under load one osascript spawn on
//  the old serial tick loop was measured stalling 10–16 s, holding every
//  publish behind it; past 20 s the saver blanked the whole rack. Now a
//  slow poll only ages its own value. Album art is a publisher too — one
//  that subscribes to now-playing and publishes a file (albumart.json)
//  rather than a snapshot.
//
//  The merge rule is recency: the freshest signal wins, except a
//  PermissionRequest holds until any newer event for that session.
//  Host app target only.
//

import CoreGraphics
import Foundation
import ImageIO
import ServiceManagement

enum FeedsService {

    // MARK: Paths

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var hookDir: URL { home.appendingPathComponent(".claude/codesaver/sessions") }
    private static var spoolDir: URL { home.appendingPathComponent(".bifrocate/cot") }
    private static var pinsURL: URL { home.appendingPathComponent(".bifrocate/pins.json") }
    private static var pinStateURL: URL { home.appendingPathComponent(".bifrocate/pins.state.json") }
    static var widgetsDir: URL? { CorpusStore.widgetsDirectory }

    // MARK: Per-session model

    private struct SpoolState {
        var state = ""          // thinking | responding | toolcall | waiting_tool | done
        var tool: String?
        var ts: TimeInterval = 0
        var turnStart: TimeInterval = 0   // first req after >20s quiet
        var cwd: String?
        var model: String?
    }

    private struct HookState: Decodable {
        var session_id: String?
        var cwd: String?
        var model: String?
        var hook_state: String?
        var hook_ts: Double?
        var tool: String?
        var turn_started: Double?
        var turn_ended: Double?
        var session_tokens: Int?      // context after the last request (in+out)
        var anchor_tokens: Int?       // context when this turn's prompt was sent
        var anchor_turn: Double?      // turn_started the anchor belongs to
        var bg: [String: Int]?
        var sl_ts: Double?
        var pid: LenientInt?          // the CLI's pid (CLAUDE_PID): liveness
    }

    /// The hook stores CLAUDE_PID; files written before it coerced the
    /// value carry a string. Accept either shape and never fail the whole
    /// decode over it — a session without a usable pid just skips the
    /// liveness check.
    private struct LenientInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = Int(d) }
            else if let s = try? c.decode(String.self) {
                value = Int(s.trimmingCharacters(in: .whitespaces))
            } else { value = nil }
        }
    }

    // MARK: Publisher

    /// One data source on its own thread. `poll` runs every `interval`
    /// (measured from the start of the previous run) and its result becomes
    /// `latest`, stamped with when that poll began. A poll that blocks — a
    /// starved osascript spawn, a wedged player, throttled I/O — delays only
    /// this publisher's next value; nobody waits on it, and a subscriber
    /// reading `latest` gets the newest complete snapshot without ever
    /// touching the source.
    private final class Publisher<Value> {
        struct Snapshot {
            let value: Value
            let polledAt: Date
        }
        private let lock = NSLock()
        private var snapshot: Snapshot?

        init(_ name: String, every interval: TimeInterval, _ poll: @escaping () -> Value) {
            let thread = Thread { [self] in
                while true {
                    let started = Date()
                    let value = poll()
                    lock.lock()
                    snapshot = Snapshot(value: value, polledAt: started)
                    lock.unlock()
                    Thread.sleep(forTimeInterval:
                        max(0.05, interval - Date().timeIntervalSince(started)))
                }
            }
            thread.name = "feeds.\(name)"
            thread.qualityOfService = .utility
            thread.start()
        }

        var latest: Snapshot? {
            lock.lock(); defer { lock.unlock() }
            return snapshot
        }
    }

    // MARK: Snapshots

    /// A session file, read and decoded — what the sessions publisher hands
    /// the merge.
    private struct HookRecord {
        let sid: String
        let h: HookState
    }

    /// bifrocate's pins: which sessions are pinned, what its daemon last
    /// reported per pin, and whether that report is fresh (written at least
    /// every 30 s while the daemon runs; older than 90 s means nobody is
    /// pinging).
    private struct PinsSnapshot {
        var pins: [String: Any] = [:]
        var entries: [String: Any] = [:]
        var fresh = false
    }

    /// The player as last polled. `polledAt` is when the answer came back,
    /// so the subscriber can carry a playing position forward to the second
    /// it publishes.
    private struct NowPlaying {
        var app: String
        var state: String            // playing | paused
        var title: String
        var artist: String
        var position: Double
        var duration: Double
        var pausedSince: Double?
        var polledAt: Double
    }

    // MARK: Daemon

    static func runDaemon() -> Never {
        if let dir = widgetsDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Publishers. Each owns whatever its source needs across polls —
        // captured here, touched only from its own thread.
        var lastPrune = Date.distantPast
        let sessions = Publisher("sessions", every: 1.0) { () -> [HookRecord] in
            if Date().timeIntervalSince(lastPrune) > 3600 {
                lastPrune = Date()
                pruneSessionFiles()
            }
            return readSessionFiles()
        }

        var offsets: [String: UInt64] = [:]          // spool path -> bytes consumed
        var spool: [String: SpoolState] = [:]        // session id -> spool view
        let spools = Publisher("spools", every: 1.0) { () -> [String: SpoolState] in
            tailSpools(offsets: &offsets, spool: &spool)
            return spool
        }

        var pinsCache = JSONCache()
        var pinStateCache = JSONCache()
        let pins = Publisher("pins", every: 1.0) { () -> PinsSnapshot in
            let state = cachedJSON(pinStateURL, &pinStateCache)
            return PinsSnapshot(
                pins: (cachedJSON(pinsURL, &pinsCache)["pins"] as? [String: Any]) ?? [:],
                entries: (state["sessions"] as? [String: Any]) ?? [:],
                fresh: Date().timeIntervalSince1970 - ((state["updated_at"] as? Double) ?? 0) < 90)
        }

        // The one publisher that spawns processes (pgrep, osascript) — the
        // poll that stalled the old serial loop. It can take as long as it
        // likes here.
        var pausedSince: Double?                     // wall time the player was first seen paused
        var lastKnown: NowPlaying?                   // carried through polls that couldn't complete
        let nowPlaying = Publisher("nowplaying", every: 3.0) { () -> NowPlaying? in
            switch pollNowPlaying() {
            case .unknown:
                // A poll that could not complete — osascript starved past its
                // deadline under load, a spawn that failed — says nothing
                // about the player. Treating it as "nothing playing" made
                // the panel vanish for as long as the machine was busy. Keep
                // what we knew, polledAt and all: the subscriber carries the
                // position forward and lets go only after a minute and a
                // half without a completed poll.
                return lastKnown
            case .idle:
                pausedSince = nil
                lastKnown = nil
                return nil
            case .player(var np):
                // Paused music stays on the panel for half an hour — long
                // enough to come back to, short enough that a player left
                // paused overnight doesn't hold the corner all night. The
                // clock starts at the first paused poll; only a resume or a
                // stop resets it, so once it runs out the entry stays gone.
                if np.state == "paused" {
                    let since = pausedSince ?? np.polledAt
                    pausedSince = since
                    if np.polledAt - since > 1800 { lastKnown = nil; return nil }
                    np.pausedSince = since
                } else {
                    pausedSince = nil
                }
                lastKnown = np
                return np
            }
        }

        // Album art subscribes to now-playing and publishes a FILE. On a
        // track change it extracts + renders (extraction ~1s, the render
        // ~1s) right here, on a thread where that is fine. A tuning edit
        // re-renders the playing track: the tuning window saves, this
        // notices within a second, and the saver shows the new art — the
        // whole point of keeping the knobs out of the binary.
        var lastArtKey = ""                          // "app|title|artist" of last art run
        var lastTuningMTime: Date?                   // widgets/albumart-tuning.json
        _ = Publisher("albumart", every: 1.0) { () -> String in
            if let tu = AlbumArtTuning.url {
                // Compare the OPTIONAL: a deleted tuning file means "back to
                // defaults" and must re-render too, which a plain `if let`
                // silently skipped.
                let m = (try? FileManager.default.attributesOfItem(atPath: tu.path))?[
                    .modificationDate] as? Date
                if m != lastTuningMTime {
                    lastTuningMTime = m
                    lastArtKey = ""
                }
            }
            guard let np = nowPlaying.latest?.value else { return lastArtKey }
            let key = "\(np.app)|\(np.title)|\(np.artist)"
            if key != lastArtKey {
                lastArtKey = key
                refreshAlbumArt(app: np.app, key: key)
            }
            return lastArtKey
        }

        // The subscriber: once a second, merge whatever is latest and write.
        // Pure memory plus one small rename — never a spawn, never a wait on
        // a source.
        var stateSince: [String: (String, Double)] = [:]   // session id -> (state, since)
        var lastFeed = ""
        // Let the two local-file publishers land their first snapshot before
        // the first publish, so a daemon bounce doesn't flash an empty rack
        // for a second. Bounded: a stuck source must not hold the feed.
        let ready = Date().addingTimeInterval(3)
        while (sessions.latest == nil || spools.latest == nil), Date() < ready {
            Thread.sleep(forTimeInterval: 0.05)
        }
        while true {
            let started = Date()
            let feed = buildFeed(hooks: sessions.latest?.value ?? [],
                                 spool: spools.latest?.value ?? [:],
                                 pins: pins.latest?.value ?? PinsSnapshot(),
                                 nowPlaying: nowPlaying.latest,
                                 stateSince: &stateSince)
            if feed != lastFeed, let dir = widgetsDir {
                let tmp = dir.appendingPathComponent(".feed.json.tmp")
                let dst = dir.appendingPathComponent("feed.json")
                // rename(2) over the old file. A remove-then-move left a
                // window in which feed.json did not exist, and the saver's
                // 1Hz poll landing there installed an empty feed — every
                // panel blank for a second. `updated` bumps each tick, so
                // this republishes every second and the window was hit a
                // few times a night.
                if let data = feed.data(using: .utf8), (try? data.write(to: tmp)) != nil,
                   (try? CorpusStore.replaceFile(at: dst, with: tmp)) != nil {
                    lastFeed = feed
                }
            }
            Thread.sleep(forTimeInterval: max(0.2, 1.0 - Date().timeIntervalSince(started)))
        }
    }

    // MARK: Session files

    /// Every session file that could still matter, decoded. Untouched for
    /// 2h -> nothing inside can still be within the hour (every hook event
    /// and the 5s statusline heartbeat rewrite the file), so skip the read +
    /// decode: a stat is all a dead session costs per poll, and the
    /// directory holds every session ever run.
    private static func readSessionFiles() -> [HookRecord] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: hookDir.path)) ?? []
        let untouched = Date().addingTimeInterval(-2 * 3600)
        var out: [HookRecord] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = hookDir.appendingPathComponent(name)
            if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               m < untouched { continue }
            guard let data = try? Data(contentsOf: url),
                  let h = try? JSONDecoder().decode(HookState.self, from: data),
                  let sid = h.session_id else { continue }
            out.append(HookRecord(sid: sid, h: h))
        }
        return out
    }

    // MARK: Spool tailing

    private static func tailSpools(offsets: inout [String: UInt64],
                                   spool: inout [String: SpoolState]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: spoolDir.path) else { return }
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        for name in names where name.hasSuffix(".jsonl") {
            let url = spoolDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? UInt64 else { continue }
            let sid = String(name.dropLast(6))
            if mtime < cutoff && offsets[url.path] != nil { continue }
            if mtime < cutoff { offsets[url.path] = size; continue }  // old history: skip, don't parse
            var off = offsets[url.path] ?? 0
            if size < off { off = 0 }                 // truncated/rotated
            guard size > off, let fh = try? FileHandle(forReadingFrom: url) else {
                offsets[url.path] = size; continue
            }
            defer { try? fh.close() }
            try? fh.seek(toOffset: off)
            guard let data = try? fh.readToEnd(), !data.isEmpty else { continue }
            // Only consume complete lines; leave a trailing partial for next tick.
            var consumed = data.count
            if data.last != UInt8(ascii: "\n") {
                if let nl = data.lastIndex(of: UInt8(ascii: "\n")) {
                    consumed = nl + 1
                } else { continue }
            }
            offsets[url.path] = off + UInt64(consumed)
            var st = spool[sid] ?? SpoolState()
            for line in data.prefix(consumed).split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any],
                      let e = obj["e"] as? String else { continue }
                let t = (obj["t"] as? Double) ?? Date().timeIntervalSince1970
                switch e {
                case "meta":
                    st.cwd = obj["cwd"] as? String ?? st.cwd
                    st.model = obj["model"] as? String ?? st.model
                case "req":
                    if t - st.ts > 20 || st.state == "done" || st.turnStart == 0 {
                        st.turnStart = t
                    }
                    st.state = "thinking"; st.ts = t
                case "think_start", "think", "think_end":
                                        st.state = "thinking"; st.ts = t
                case "text":            st.state = "responding"; st.ts = t
                case "tool_start":      st.state = "toolcall"
                                        st.tool = obj["name"] as? String; st.ts = t
                case "tool":            st.state = "waiting_tool"
                                        st.tool = obj["name"] as? String ?? st.tool; st.ts = t
                case "msg_end":
                    // end_turn on the wire means the reply is finished — the
                    // worker's write can trail the Stop hook, and mapping it
                    // to "responding" left panels claiming activity for up
                    // to the 120s decay after every turn.
                    let reason = obj["reason"] as? String
                    st.state = reason == "tool_use" ? "waiting_tool" : "done"
                    st.ts = t
                case "superseded":      st.state = "done"; st.ts = t
                default: break
                }
            }
            spool[sid] = st
        }
    }

    // MARK: Session-file hygiene

    /// The hook never deletes a session file (SessionEnd only marks it
    /// "gone"), so the directory — and buildFeed's per-tick listing — grew
    /// with every session ever run. Sweep files nobody has touched for a
    /// day, plus their lock and any tmp a dying hook left behind. A live
    /// session rewrites its file at least every 5s (statusline heartbeat)
    /// or on every hook event, so a day-old one has no writer left; the
    /// lock must be just as old, since `locked()` recreates it per event.
    private static func pruneSessionFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: hookDir.path) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        func old(_ url: URL) -> Bool {
            guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return false }
            return m < cutoff
        }
        for name in names {
            let url = hookDir.appendingPathComponent(name)
            if name.hasSuffix(".json") && !name.hasPrefix(".") {
                let lock = hookDir.appendingPathComponent(".\(name.dropLast(5)).lock")
                guard old(url), !fm.fileExists(atPath: lock.path) || old(lock) else { continue }
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: lock)
            } else if name.hasPrefix("."), name.hasSuffix(".lock"), old(url),
                      !fm.fileExists(atPath: hookDir.appendingPathComponent(
                          "\(name.dropFirst().dropLast(5)).json").path) {
                try? fm.removeItem(at: url)               // lock outlived its session
            } else if name.hasPrefix("."), name.hasSuffix(".tmp"), old(url) {
                try? fm.removeItem(at: url)               // a hook died mid-store
            }
        }
    }

    // MARK: Pins (bifrocate's pin daemon)

    /// A decoded JSON object cached by mtime. Both pin files are tiny and
    /// rewritten rarely — pins.json on a toggle, pins.state.json on change or
    /// every ~30s — so a stat per poll is all they cost.
    private struct JSONCache { var mtime: Date?; var obj: [String: Any] = [:] }

    private static func cachedJSON(_ url: URL, _ cache: inout JSONCache) -> [String: Any] {
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        if m == cache.mtime { return cache.obj }
        cache.mtime = m
        guard m != nil, let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { cache.obj = [:]; return [:] }
        cache.obj = obj
        return obj
    }

    // MARK: Merge + feed

    /// The subscriber's merge: the latest snapshot from every publisher into
    /// the feed document. Nothing here touches a source.
    private static func buildFeed(hooks: [HookRecord], spool: [String: SpoolState],
                                  pins pinsSnap: PinsSnapshot,
                                  nowPlaying: Publisher<NowPlaying?>.Snapshot?,
                                  stateSince: inout [String: (String, Double)]) -> String {
        let now = Date().timeIntervalSince1970
        var sessions: [[String: Any]] = []
        let pins = pinsSnap.pins, pinEntries = pinsSnap.entries, pinStateFresh = pinsSnap.fresh

        for rec in hooks {
            let h = rec.h, sid = rec.sid
            if h.hook_state == "gone" { continue }
            // A dead CLI is a gone session whether or not SessionEnd ran:
            // a killed process or force-closed terminal never fires it,
            // and the sticky states below (waiting_tool / permission are
            // exempt from decay) would advertise "Permissions required"
            // for an hour. ESRCH only — EPERM means the pid exists, and a
            // recycled pid merely keeps today's behaviour.
            if let pid = h.pid?.value, pid > 1,
               kill(pid_t(pid), 0) != 0, errno == ESRCH { continue }
            let s = spool[sid]
            let hookTS = max(h.hook_ts ?? 0, 0)
            let activity = max(hookTS, s?.ts ?? 0)     // real events only
            // Unused for an hour -> panel disappears. An hour because that
            // is Claude Code's prompt-cache TTL: the panel dies exactly when
            // the session's cache does. The statusline heartbeat keeps
            // ticking while the CLI merely sits open, so it must not count.
            // No real event ever (or the fields were lost): don't show the
            // session at all. Falling back to the statusline heartbeat here
            // made ghost sessions immortal — the heartbeat ticks every 5s
            // in any open CLI, so "last used" always looked seconds old.
            guard activity > 0 else { continue }
            let lastUsed = activity
            // …unless the session is pinned: the pin is an explicit wish to
            // keep it warm, so its panel stays (showing the pin's state, cold
            // included) until the pin daemon drops the pin — which it does
            // within a minute of the CLI going away.
            let pin = pins[sid] as? [String: Any]
            if now - lastUsed > 3600, pin == nil { continue }

            // Recency merge; permission holds until something newer arrives.
            var state: String
            var tool = h.tool
            if h.hook_state == "permission" && hookTS >= (s?.ts ?? 0) {
                state = "permission"
            } else if let s, s.ts > hookTS {
                state = s.state
                if s.state == "toolcall" || s.state == "waiting_tool" {
                    tool = s.tool ?? tool
                }
            } else {
                state = h.hook_state ?? "done"
                if state == "working" { state = "thinking" }
            }
            // A STREAMING state whose signals went quiet is an interrupt or
            // a pre-hooks session: decay to done. waiting_tool and permission
            // are exempt — a 40-minute tool execution or a parked approval
            // dialog is legitimately silent (the statusline heartbeat never
            // counts as activity either way).
            if ["thinking", "responding", "toolcall"].contains(state),
               now - activity > 120 { state = "done" }

            // Stamp when this state began, so panels can show "(5s ∙ …)".
            // First sight of a session (daemon restart) seeds from the last
            // real event rather than `now` — a 40-minute tool wait must not
            // read as seconds old because the daemon bounced.
            let since: Double
            if let prev = stateSince[sid], prev.0 == state {
                since = prev.1
            } else if stateSince[sid] == nil {
                since = state == "done" ? (h.turn_ended ?? lastUsed)
                                        : (activity > 0 ? activity : now)
            } else {
                since = now
            }
            stateSince[sid] = (state, since)

            var entry: [String: Any] = ["id": sid, "state": state,
                                        "state_since": since]
            // Composed: a project directory named in Hangul or kana reaches
            // the hook decomposed whenever it came off an HFS+ volume or a
            // path the shell normalised, and the panel measures its cells per
            // Character — a decomposed syllable is several of those.
            entry["cwd"] = (h.cwd ?? s?.cwd ?? "?").precomposedStringWithCanonicalMapping
            if let tool, state == "toolcall" || state == "waiting_tool"
                        || state == "permission" { entry["tool"] = tool }
            if let ts = h.turn_started { entry["turn_started"] = ts }
            else if let s, s.turnStart > 0 { entry["turn_started"] = s.turnStart }
            if state == "done" {
                // Freeze Done elapsed: Stop's timestamp when hooks saw the
                // turn end, else the spool's last activity.
                entry["turn_ended"] = h.turn_ended ?? s?.ts ?? now
                entry["last_active"] = lastUsed
            }
            if let total = h.session_tokens {
                entry["session_tokens"] = total
                // "Tokens this turn" = context growth since the prompt: the
                // reply, tool results, and injected reminders alike — every
                // token the turn added. The statusline's counts are per
                // request (the live context), so growth is a plain
                // difference against the anchor the hook took at prompt
                // time. Only trust an anchor stamped for THIS turn.
                if let a = h.anchor_tokens, let at = h.anchor_turn,
                   at == h.turn_started, total > a {
                    entry["turn_tokens"] = total - a
                }
            }
            if state == "done", let bg = h.bg, !bg.isEmpty { entry["bg"] = bg }
            if let pin {
                var p: [String: Any] = ["pinned_at": pin["pinned_at"] as? Double ?? 0,
                                        "fresh": pinStateFresh]
                if let e = pinEntries[sid] as? [String: Any] {
                    if let st = e["status"] as? String { p["status"] = st }
                    if let n = e["next_ping_at"] as? Double { p["next_ping_at"] = n }
                    if let t = e["pinged_at"] as? Double { p["pinged_at"] = t }
                    if let c = e["pings"] as? Int { p["pings"] = c }
                }
                entry["pin"] = p
            }
            sessions.append(entry)
        }
        sessions.sort {
            (($0["turn_started"] as? Double) ?? 0) > (($1["turn_started"] as? Double) ?? 0)
        }

        var root: [String: Any] = ["updated": now, "sessions": sessions]
        if let snap = nowPlaying, let np = snap.value, now - np.polledAt < 90 {
            // Carried to THIS second: the position runs forward while
            // playing (and holds while paused), and `ts` is now — so the
            // saver's freshness gate sees a live entry for as long as the
            // poll is recent. A slow poll ages the value; it doesn't blank
            // the panel. Ninety seconds without a completed poll and the
            // entry goes: by then nobody knows what the player is doing.
            var pos = np.position
            if np.state == "playing" {
                pos += now - np.polledAt
                if np.duration > 0 { pos = min(pos, np.duration) }
            }
            var o: [String: Any] = ["app": np.app, "state": np.state, "title": np.title,
                                    "artist": np.artist, "position": pos,
                                    "duration": np.duration, "ts": now]
            if let ps = np.pausedSince { o["paused_since"] = ps }
            root["nowplaying"] = o
        }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: opts),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // MARK: Now playing

    static let players: [(bundle: String, name: String)] = [
        ("com.apple.Music", "Music"),
        ("com.spotify.client", "Spotify"),
    ]

    /// What a poll of the players came back with. `.idle` is a definite
    /// answer — no player running, or one that is stopped; `.unknown` is no
    /// answer at all — a spawn that failed or a query that ran out its
    /// deadline — and must not be mistaken for the former.
    private enum NowPlayingPoll {
        case player(NowPlaying)
        case idle
        case unknown
    }

    /// Player-running check via pgrep: NSRunningApplication is a
    /// LaunchServices query and this daemon must never speak to LS at all
    /// (its process shares the app bundle's identity). nil when pgrep itself
    /// could not answer (spawn failure, or an exit that isn't yes/no).
    private static func playerRunning(_ name: String) -> Bool? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        t.arguments = ["-xq", name]
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return nil }
        t.waitUntilExit()
        switch t.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    private static func pollNowPlaying() -> NowPlayingPoll {
        var unknown = false
        for p in players {
            switch playerRunning(p.name) {
            case .some(true): break
            case .some(false): continue
            case .none: unknown = true; continue
            }
            // One script, newline-joined fields; empty when stopped.
            // Executed via /usr/bin/osascript: the daemon must never
            // initialize the AppleEvents machinery in-process (it registers
            // an ASN that makes LaunchServices treat this process as the
            // running app). TCC attributes the child to CodeSaver anyway.
            // Nothing waits on this poll, so it can afford to: the
            // Apple-event timeout and the process deadline are generous —
            // under load, just spawning osascript has been measured at
            // 10–16 s — and a poll that still runs out is reported as
            // unknown, not as silence.
            let src = """
            with timeout of 8 seconds
                tell application "\(p.name)"
                    if player state is playing or player state is paused then
                        -- `ps`, not `st`: Music's dictionary claims `st`.
                        set ps to "paused"
                        if player state is playing then set ps to "playing"
                        set t to name of current track
                        set a to artist of current track
                        set pos to player position
                        set dur to duration of current track
                        return ps & "\\n" & t & "\\n" & a & "\\n" & (pos as text) & "\\n" & (dur as text)
                    end if
                    return ""
                end tell
            end timeout
            """
            // osascript writes its result to stdout as UTF-8 regardless of
            // locale (verified with LANG unset and LC_ALL=C, which is what
            // this LaunchAgent actually runs under), so a CJK track name
            // arrives intact. The lossy fallback is for the day some player
            // hands AppleScript a string it can't encode: better a panel with
            // one mangled character than no panel at all, which is what the
            // bare `String(data:encoding:)` nil did.
            guard let data = runProcess("/usr/bin/osascript", ["-e", src], deadline: 15) else {
                unknown = true; continue
            }
            let text = (String(data: data, encoding: .utf8)
                        ?? String(decoding: data, as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let parts = text.components(separatedBy: "\n")
            guard parts.count >= 5 else { unknown = true; continue }
            // AppleScript numbers can arrive comma-decimal under some locales.
            func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
            var dur = num(parts[4]) ?? 0
            // Spotify's `duration of current track` is milliseconds (its
            // sdef says seconds; it isn't) while `player position` is
            // seconds. Music returns seconds for both. The feed carries
            // seconds — the saver clocks the progress bar against it.
            if p.name == "Spotify" { dur /= 1000 }
            // Compose HERE, once, at the only place track text enters the
            // daemon. Music hands back whatever the file's tags hold, and tags
            // written on macOS are routinely decomposed (한 as ᄒ+ᅡ+ᆫ, が as
            // か+゛) — which the saver's cell grid then measures a jamo at a
            // time. Normalising at the source also keeps the album-art key and
            // the feed's title/artist derived from the SAME string: they are
            // compared for equality across two processes, so they must never
            // be normalised on only one side.
            return .player(NowPlaying(app: p.name, state: parts[0],
                                      title: parts[1].precomposedStringWithCanonicalMapping,
                                      artist: parts[2].precomposedStringWithCanonicalMapping,
                                      position: num(parts[3]) ?? 0, duration: dur,
                                      pausedSince: nil, polledAt: Date().timeIntervalSince1970))
        }
        return unknown ? .unknown : .idle
    }

    // MARK: Album art

    /// Run a subprocess, capture stdout. Pipe ends are always closed — a
    /// daemon polling every few seconds leaked 2 fds per poll overnight
    /// (2,500+ pipes) until Process.run() itself started failing, silently,
    /// because that path guards with try?. That lesson is law in this file.
    /// A `deadline` kills the child (SIGTERM) after that many seconds, for
    /// callers that shouldn't hang on a wedged player.
    private static func runProcess(_ path: String, _ args: [String],
                                   deadline: TimeInterval? = nil) -> Data? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        guard (try? t.run()) != nil else { return nil }
        var reaper: DispatchWorkItem?
        if let deadline {
            // SIGTERM at the deadline; SIGKILL a beat later if it was
            // ignored — a child blocked in an Apple-event wait can be — so
            // the read below can never hang this thread for good.
            let w = DispatchWorkItem {
                guard t.isRunning else { return }
                t.terminate()
                let pid = t.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if t.isRunning { kill(pid, SIGKILL) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: w)
            reaper = w
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        reaper?.cancel()
        return t.terminationStatus == 0 ? data : nil
    }

    /// Extract the current track's artwork, render it to the text grid with
    /// the tuned parameters, and publish widgets/albumart.json under the
    /// track's key. A track WITHOUT artwork — or one whose art can't be
    /// fetched — publishes the key alone: the saver reads that as "asked, and
    /// there is none" and rests its placeholder, rather than waiting on art
    /// that will never come.
    private static func refreshAlbumArt(app: String, key: String) {
        guard let wdir = widgetsDir else { return }
        var payload: [String: Any] = ["key": key,
                                      "ts": Date().timeIntervalSince1970]
        // The renderer was Python (PIL/numpy) while the style was being
        // tuned; the pipeline is settled now, so it lives in-process — no
        // interpreter dependency, no per-track subprocess, and the app works
        // on any machine. feeds/albumart/ramp.py stays in the repo as the
        // reference the port was verified against.
        if let cg = fetchArtwork(app: app, into: wdir.appendingPathComponent("albumart-src.img")),
           let ramp = AlbumArtRamp.render(
               cg, params: AlbumArtRamp.Params(json: AlbumArtTuning.load()["ramp"] ?? [:])) {
            payload["ramp"] = ramp
        }
        let tmp = wdir.appendingPathComponent(".albumart.json.tmp")
        let dst = wdir.appendingPathComponent("albumart.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           (try? data.write(to: tmp)) != nil {
            try? CorpusStore.replaceFile(at: dst, with: tmp)  // rename over the old: no gap
        }
    }

    /// The current track's cover, saved to `src` and decoded — nil when the
    /// player has none (or won't say). On nil the previous track's file is
    /// removed too, so nothing downstream (the tuner's "current track") can
    /// mistake it for this one's.
    private static func fetchArtwork(app: String, into src: URL) -> CGImage? {
        var ok = false
        if app == "Music" {
            let script = """
            tell application "Music"
                set d to raw data of artwork 1 of current track
            end tell
            set f to (open for access POSIX file "\(src.path)" with write permission)
            set eof f to 0
            write d to f
            close access f
            """
            ok = runProcess("/usr/bin/osascript", ["-e", script]) != nil
        } else {
            // Spotify exposes a URL, not bytes.
            let script = "tell application \"\(app)\" to artwork url of current track"
            if let d = runProcess("/usr/bin/osascript", ["-e", script]),
               let urlStr = String(data: d, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: urlStr) {
                let sem = DispatchSemaphore(value: 0)
                var img: Data?
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    img = data
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 15)
                if let img, (try? img.write(to: src)) != nil { ok = true }
            }
        }
        if ok, let isrc = CGImageSourceCreateWithURL(src as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(isrc, 0, nil) {
            return cg
        }
        try? FileManager.default.removeItem(at: src)
        return nil
    }
}

// MARK: - LaunchAgent registration (mirrors RefreshAgent)

enum FeedsAgent {
    static let plistName = "com.michelg10.CodeSaver.feeds.plist"
    static var service: SMAppService { .agent(plistName: plistName) }
    static var isAtStablePath: Bool { Bundle.main.bundlePath == "/Applications/CodeSaver.app" }
    static var status: SMAppService.Status { service.status }

    @discardableResult
    static func register(interactive: Bool) -> SMAppService.Status {
        guard isAtStablePath else { return service.status }
        if service.status != .enabled {
            try? service.register()
        }
        let status = service.status
        if status == .requiresApproval && interactive {
            SMAppService.openSystemSettingsLoginItems()
        }
        return status
    }

    static func unregister() {
        try? service.unregister()
    }
}
