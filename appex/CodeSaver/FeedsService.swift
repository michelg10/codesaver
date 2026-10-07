//
//  FeedsService.swift
//  CodeSaver
//
//  The widget feed daemon: `CodeSaver --feeds`, kept alive by the
//  com.michelg10.CodeSaver.feeds LaunchAgent. Merges five sources into
//  one widgets/feed.json in the app-group container (the only place the
//  sandboxed saver can read):
//
//    1. ~/.claude/codesaver/sessions/*.json — per-session state written by
//       the Claude Code hook script (feeds/cc-state-hook.py) and statusline
//       wrapper: coarse state machine, permission waits, background tasks,
//       token counts. The base record: the only source that sees a
//       permission dialog, and the only one for a session that doesn't
//       load the mods below.
//    2. $CLAUDE_LIVE_DIR/<sid>.json (default ~/.claude/live) — the live
//       state file claude-mods' pause mod keeps for its session (the
//       contract is ~/bin/claude-mods/PAUSE.md): every model request and
//       tool call in flight, main agent and subagents (thinking,
//       responding, writing a tool call, which tool is running, held at
//       the pause gate), how the last turn ended (`aborted` = Esc — no
//       more guessing an interrupt from silence), context size,
//       background tasks, and whether the session is paused and since
//       when. A session with a fresh one takes its state from it.
//    3. $CLAUDE_LIVE_DIR/pins/<sid>.json — the pin mod, one file per
//       pinned session (kept warm with keep-alive pings): what it will do
//       next. A pinned session stays on the rack while its pin lives,
//       even past the hour.
//    4. Now playing — Music.app / Spotify via AppleScript, polled only
//       while the player is actually running; a paused track is held for
//       half an hour.
//    5. LEGACY — ~/.bifrocate/cot/*.jsonl, bifrocate's main-agent CoT
//       spools. Read only for a session without a fresh live file. Since
//       Claude Code moved to server-side threads the spool misses most
//       requests; remove it (tailSpools, SpoolState, the spools
//       publisher) once the mods are loaded in every session.
//
//  Every directory honours an environment override — CLAUDE_LIVE_DIR as
//  the mods themselves do, CODESAVER_SESSIONS_DIR and CODESAVER_SPOOL_DIR
//  for the other two — so Sources/FeedsCheck.swift can run the merge on
//  fabricated files, never on a live session's.
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
//  Every loop here is a thread that never returns, and on such a thread
//  the autorelease pool Foundation opens at entry drains at exit — never.
//  So each poll and each publish runs inside a pool of its own. A
//  contentsOfDirectory, an attributesOfItem, a Data(contentsOf:), the NSURL
//  behind every appendingPathComponent — each hands back an autoreleased
//  object, and without a pool per iteration every one of them stayed
//  pending for the life of the daemon: 130 spool files stat'd once a second
//  is ~460 objects a second, and after two days the six threads held 94
//  million of them — 20 GB, nearly all of it in the compressor. A loop
//  that runs forever drains its own pool. Law, like the pipe fds below.
//
//  The merge: a fresh live file (its pid alive, written within the last
//  60 s) decides a session's state; without one, recency between the hook
//  file and the spool — the freshest signal wins. Either way a
//  PermissionRequest holds until any newer event for that session: the
//  live file doesn't report permission dialogs (v1).
//  Host app target only.
//

import CoreGraphics
import Foundation
import ImageIO
import ServiceManagement

enum FeedsService {

    // MARK: Paths

    /// `$name` when set, else `fallback` under home. Resolved ONCE (static
    /// lets): the publishers touch these per file per second, and
    /// ProcessInfo.environment copies the whole environment on every call.
    /// A test sets its overrides before the first read.
    private static func envDir(_ name: String, _ fallback: String) -> URL {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
    }
    private static let hookDir = envDir("CODESAVER_SESSIONS_DIR", ".claude/codesaver/sessions")
    private static let liveDir = envDir("CLAUDE_LIVE_DIR", ".claude/live")
    private static let pinsDir = liveDir.appendingPathComponent("pins", isDirectory: true)
    /// LEGACY: bifrocate's CoT spools — goes with tailSpools.
    private static let spoolDir = envDir("CODESAVER_SPOOL_DIR", ".bifrocate/cot")
    static var widgetsDir: URL? { CorpusStore.widgetsDirectory }

    /// PAUSE.md's staleness rule for live and pin files: a file not
    /// rewritten for a minute (the writers heartbeat every 15 s and 30 s)
    /// has no writer left, or one that is wedged.
    private static let liveStaleAfter: TimeInterval = 60

    // MARK: Per-session model

    /// LEGACY: one session's view off bifrocate's spool — goes with
    /// tailSpools once every session loads the mods.
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
            // Int(exactly:) — a plain Int(d) traps on a non-finite or
            // out-of-range double, and this decode runs on every file
            // every second: one bad value would crash-loop the daemon.
            else if let d = try? c.decode(Double.self) { value = Int(exactly: d.rounded()) }
            else if let s = try? c.decode(String.self) {
                value = Int(s.trimmingCharacters(in: .whitespaces))
            } else { value = nil }
        }
    }

    /// A live state file as the pause mod writes it (PAUSE.md, "Live state
    /// files"). Every field optional — the contract makes pid, model,
    /// context.tokens and the turn's times nullable, and a decode that
    /// demanded a field the writer left out would drop the whole session.
    /// Times are epoch MILLISECONDS here; LiveRecord carries seconds.
    private struct LiveFile: Decodable {
        struct Turn: Decodable {
            var state: String?           // working | done | idle
            var started: Double?
            var ended: Double?
            var end: String?             // answer | aborted | error | refusal
            var tokens: Double?          // context growth this turn
        }
        struct Activity: Decodable {
            var agent: String?           // "main", or a subagent's id
            var state: String?
            var tool: String?
            var since: Double?
        }
        struct Context: Decodable { var tokens: Double? }
        struct BackgroundTask: Decodable { var type: String? }
        var pid: LenientInt?
        var cwd: String?
        var updated: Double?
        var mainChanged: Double?         // the main conversation's last change
        var pausedSince: Double?         // the oldest hold's since
        var turn: Turn?
        var paused: Bool?
        var settled: Bool?
        var activities: [Activity]?
        var background: [BackgroundTask]?
        var context: Context?
    }

    /// One thing in flight off a live file — a model request or a tool
    /// call, the main agent's or a subagent's.
    private struct LiveActivity {
        var main: Bool
        var state: String    // held | requesting | thinking | responding | writing-tool-call | tool
        var tool: String?
        var since: Double
    }

    /// A live file, decoded, in seconds: what the live publisher hands the
    /// merge.
    private struct LiveRecord {
        var pid: Int?
        var updated: Double
        var cwd: String?
        var turnState: String        // working | done | idle
        var mainChanged: Double?     // nil from a writer older than the field
        var turnStarted: Double?
        var turnEnded: Double?
        var turnTokens: Int?         // context growth this turn, when the file knows
        var paused: Bool
        var settled: Bool
        var pausedSince: Double?     // when the current pause began
        var activities: [LiveActivity]
        var background: [String: Int]   // type -> count, the hook's `bg` shape
        var contextTokens: Int?

        init?(_ data: Data) {
            guard let f = try? JSONDecoder().decode(LiveFile.self, from: data),
                  let updated = f.updated else { return nil }
            func s(_ ms: Double?) -> Double? { ms.map { $0 / 1000 } }
            pid = f.pid?.value
            self.updated = updated / 1000
            cwd = f.cwd
            mainChanged = s(f.mainChanged)
            turnState = f.turn?.state ?? "idle"
            turnStarted = s(f.turn?.started)
            turnEnded = s(f.turn?.ended)
            turnTokens = f.turn?.tokens.flatMap { Int(exactly: $0.rounded()) }
            paused = f.paused ?? false
            settled = f.settled ?? false
            pausedSince = s(f.pausedSince)
            activities = (f.activities ?? []).compactMap { a in
                guard let st = a.state, let since = a.since else { return nil }
                return LiveActivity(main: (a.agent ?? "main") == "main", state: st,
                                    tool: a.tool, since: since / 1000)
            }
            // Counted by type, as the hook folds Stop's background_tasks:
            // the panel says "2 shells, 1 agent still running".
            var bg: [String: Int] = [:]
            for t in f.background ?? [] { bg[t.type ?? "task", default: 0] += 1 }
            background = bg
            contextTokens = f.context?.tokens.flatMap { Int(exactly: $0.rounded()) }
        }

        /// The main conversation's last change: what a hook timestamp — a
        /// permission prompt, which the hook only ever sees for the main
        /// agent — is ranked against. Never `updated` (the 15 s heartbeat),
        /// nor `changed`, which also moves with a subagent's step and any
        /// hold coming or going: a background subagent would end a prompt
        /// the main agent still has open. A writer older than `mainChanged`
        /// gets the same answer, nearly, from the main agent's own stamps.
        var mainChangedAt: Double {
            mainChanged ?? stamps(mainOnly: true)
        }

        /// The last real use, for the hour rule: any agent's step, the
        /// turn's start and end. Not `changed` either: a Suspend lands a
        /// hold on every session, and must not make one idle for hours
        /// look used again.
        var usedAt: Double {
            max(stamps(mainOnly: false), mainChanged ?? 0)
        }

        private func stamps(mainOnly: Bool) -> Double {
            var t = max(turnStarted ?? 0, turnEnded ?? 0)
            for a in activities where a.main || !mainOnly { t = max(t, a.since) }
            return t
        }
    }

    /// A pin file (PAUSE.md, "Pin files"), epoch milliseconds.
    private struct PinFile: Decodable {
        var pid: LenientInt?
        var updated: Double?
        var pinnedAt: Double?
        var status: String?          // waiting | busy | sent | cold | stalled | error
        var nextPingAt: Double?
        var pingedAt: Double?
        var pings: Double?
    }

    /// A pin file, decoded, in seconds.
    private struct PinRecord {
        var pid: Int?
        var updated: Double
        var pinnedAt: Double
        var status: String?
        var nextPingAt: Double?
        var pingedAt: Double?
        var pings: Int?

        init?(_ data: Data) {
            guard let f = try? JSONDecoder().decode(PinFile.self, from: data),
                  let updated = f.updated else { return nil }
            pid = f.pid?.value
            self.updated = updated / 1000
            pinnedAt = (f.pinnedAt ?? 0) / 1000
            status = f.status
            nextPingAt = f.nextPingAt.map { $0 / 1000 }
            pingedAt = f.pingedAt.map { $0 / 1000 }
            pings = f.pings.flatMap { Int(exactly: $0.rounded()) }
        }
    }

    // MARK: File metadata

    /// mtime + size straight from stat(2). FileManager.attributesOfItem
    /// builds (and autoreleases) a dictionary of every attribute per call —
    /// measured at 4.4 ms for the ~180 spool + session files the publishers
    /// stat each second, against 0.2 ms here. Follows symlinks, so a linked
    /// spool reports the data's own mtime.
    private static func fileStat(_ path: String) -> (mtime: Date, size: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let m = st.st_mtimespec
        return (Date(timeIntervalSince1970: Double(m.tv_sec) + Double(m.tv_nsec) / 1e9),
                UInt64(max(0, st.st_size)))
    }

    /// Whether `pid` still names a process. ESRCH only — EPERM means it
    /// exists, and a recycled pid merely keeps today's behaviour. No pid
    /// (a writer that had none to give) can't be checked and counts as
    /// alive, leaving the timestamps to decide.
    private static func pidAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 1, let p = pid_t(exactly: pid) else { return true }
        return !(kill(p, 0) != 0 && errno == ESRCH)
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
                    // One pool per poll: everything the poll autoreleased
                    // goes when the pool does, not when the thread does —
                    // which is never (see the header).
                    autoreleasepool {
                        let started = Date()
                        let value = poll()
                        lock.lock()
                        snapshot = Snapshot(value: value, polledAt: started)
                        lock.unlock()
                        Thread.sleep(forTimeInterval:
                            max(0.05, interval - Date().timeIntervalSince(started)))
                    }
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

        // The mods' live files, one per session, rewritten on every change
        // and at least every 15 s.
        var liveCache: [String: Cached<LiveRecord>] = [:]
        let live = Publisher("live", every: 1.0) { () -> [String: LiveRecord] in
            readLiveFiles(&liveCache)
        }

        // LEGACY: bifrocate's spools, the fallback for a session without a
        // fresh live file. Remove with tailSpools once the mods are loaded
        // everywhere.
        var offsets: [String: UInt64] = [:]          // spool path -> bytes consumed
        var spool: [String: SpoolState] = [:]        // session id -> spool view
        let spools = Publisher("spools", every: 1.0) { () -> [String: SpoolState] in
            tailSpools(offsets: &offsets, spool: &spool)
            return spool
        }

        // The pin mod's files, one per pinned session, rewritten on every
        // change and at least every 30 s.
        var pinCache: [String: Cached<PinRecord>] = [:]
        let pins = Publisher("pins", every: 1.0) { () -> [String: PinRecord] in
            readJSONDir(pinsDir, &pinCache) { PinRecord($0) }
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
                let m = fileStat(tu.path)?.mtime
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
        // Let the local-file publishers land their first snapshot before
        // the first publish, so a daemon bounce doesn't flash an empty rack
        // (or a pinned panel) for a second. Bounded: a stuck source must not
        // hold the feed.
        let ready = Date().addingTimeInterval(3)
        while (sessions.latest == nil || live.latest == nil || spools.latest == nil
               || pins.latest == nil), Date() < ready {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // The main thread has no run loop to drain a pool for it either:
        // one pool per tick, same as the publishers.
        while true {
            autoreleasepool {
                let started = Date()
                let feed = buildFeed(hooks: sessions.latest?.value ?? [],
                                     live: live.latest?.value ?? [:],
                                     spool: spools.latest?.value ?? [:],
                                     pins: pins.latest?.value ?? [:],
                                     nowPlaying: nowPlaying.latest,
                                     stateSince: &stateSince)
                if feed != lastFeed, let dir = widgetsDir {
                    let tmp = dir.appendingPathComponent(".feed.json.tmp")
                    let dst = dir.appendingPathComponent("feed.json")
                    // rename(2) over the old file. A remove-then-move left a
                    // window in which feed.json did not exist, and the
                    // saver's 1Hz poll landing there installed an empty feed
                    // — every panel blank for a second. `updated` bumps each
                    // tick, so this republishes every second and the window
                    // was hit a few times a night.
                    if let data = feed.data(using: .utf8), (try? data.write(to: tmp)) != nil,
                       (try? CorpusStore.replaceFile(at: dst, with: tmp)) != nil {
                        lastFeed = feed
                    }
                }
                Thread.sleep(forTimeInterval: max(0.2, 1.0 - Date().timeIntervalSince(started)))
            }
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
            if let m = fileStat(url.path)?.mtime, m < untouched { continue }
            guard let data = try? Data(contentsOf: url),
                  let h = try? JSONDecoder().decode(HookState.self, from: data),
                  let sid = h.session_id else { continue }
            out.append(HookRecord(sid: sid, h: h))
        }
        return out
    }

    // MARK: Spool tailing (LEGACY)

    /// bifrocate's CoT spools. Since Claude Code moved to server-side
    /// threads they miss most requests; the merge reads them only for a
    /// session without a fresh live file. Remove this, SpoolState, spoolDir
    /// and the spools publisher once the mods are loaded in every session.
    private static func tailSpools(offsets: inout [String: UInt64],
                                   spool: inout [String: SpoolState]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: spoolDir.path) else { return }
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        for name in names where name.hasSuffix(".jsonl") {
            let url = spoolDir.appendingPathComponent(name)
            guard let (mtime, size) = fileStat(url.path) else { continue }
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
            guard let m = fileStat(url.path)?.mtime else { return false }
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

    // MARK: Live and pin files (claude-mods)

    /// A decoded file and the stat it was decoded at.
    private struct Cached<T> { var mtime: Date; var size: UInt64; var value: T }

    /// Every `<sid>.json` in `dir`, decoded and keyed by session id. A file whose
    /// stat hasn't moved since the last poll comes out of `cache`, so a quiet
    /// session costs one stat a second. A decode that fails — the writer
    /// caught mid-write, which PAUSE.md allows ("a reader that hits a
    /// half-written file just tries again next poll") — keeps the last good
    /// value and is retried next poll. Files untouched for `maxAge` are
    /// skipped unread, and dot-files are a writer's temp.
    private static func readJSONDir<T>(_ dir: URL, maxAge: TimeInterval? = nil,
                                       _ cache: inout [String: Cached<T>],
                                       _ decode: (Data) -> T?) -> [String: T] {
        let base = dir.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        let cutoff = maxAge.map { Date().addingTimeInterval(-$0) }
        var out: [String: T] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = base + "/" + name
            guard let (mtime, size) = fileStat(path) else { continue }
            if let cutoff, mtime < cutoff { continue }
            let key = String(name.dropLast(5))
            if let c = cache[key], c.mtime == mtime, c.size == size {
                out[key] = c.value
            } else if let data = FileManager.default.contents(atPath: path),
                      let v = decode(data) {
                cache[key] = Cached(mtime: mtime, size: size, value: v)
                out[key] = v
            } else if let c = cache[key] {
                out[key] = c.value
            }
        }
        if cache.count > out.count { cache = cache.filter { out[$0.key] != nil } }
        return out
    }

    /// The live files that could still be fresh: one not rewritten for a
    /// minute is stale whatever it says, so it isn't even read.
    private static func readLiveFiles(_ cache: inout [String: Cached<LiveRecord>]) -> [String: LiveRecord] {
        readJSONDir(liveDir, maxAge: liveStaleAfter, &cache) { LiveRecord($0) }
    }

    /// One merge over the file sources, each read right here — what
    /// Sources/FeedsCheck.swift runs against fabricated files. No
    /// now-playing (its poll spawns processes), no prune, no write;
    /// `stateSince` carries across calls as the daemon's does across ticks.
    static func feedOnce(stateSince: inout [String: (String, Double)]) -> String {
        var offsets: [String: UInt64] = [:]
        var spool: [String: SpoolState] = [:]
        tailSpools(offsets: &offsets, spool: &spool)
        var liveCache: [String: Cached<LiveRecord>] = [:]
        var pinCache: [String: Cached<PinRecord>] = [:]
        return buildFeed(hooks: readSessionFiles(),
                         live: readLiveFiles(&liveCache),
                         spool: spool,
                         pins: readJSONDir(pinsDir, &pinCache) { PinRecord($0) },
                         nowPlaying: nil, stateSince: &stateSince)
    }

    // MARK: Merge + feed

    /// What a fresh live file says its session is doing, in the feed's
    /// words: the state, its tool, when the file says it began, and — while
    /// a pause still waits on work under way — what it waits for. nil when
    /// the file has nothing to say: no turn in this process yet (a session
    /// just started, or resumed), where the hook's record stands.
    private static func liveState(_ L: LiveRecord)
        -> (state: String, tool: String?, since: Double?, waitingFor: [String])? {
        if L.paused {
            // The gate stops every new step; what was under way finishes.
            // `settled` (PAUSE.md: paused, and every activity held or none
            // left) is "Paused". Until then the session is still working,
            // and the panel says on what — any agent's, oldest first: the
            // main turn can sit held while a subagent's Bash runs on. Model
            // requests all read alike ("model"), a tool by its name.
            if L.settled { return ("paused", nil, L.pausedSince, []) }
            var names: [String] = []
            for a in L.activities.filter({ $0.state != "held" }).sorted(by: { $0.since < $1.since }) {
                let n = a.state == "tool" ? (a.tool ?? "tool") : "model"
                if !names.contains(n) { names.append(n) }
            }
            return ("pausing", nil, L.pausedSince, names)
        }
        switch L.turnState {
        case "done":
            // However it ended — an answer, Esc (`aborted`), an error — the
            // turn is over the moment the file says so: an interrupt no
            // longer sits out 120 s of silence before it reads as Done.
            return ("done", nil, L.turnEnded, [])
        case "working":
            // The main agent's newest activity: parallel tool calls are
            // separate entries, and the newest is the freshest signal. None
            // at all is the beat between a reply's `stop` and its tools, or
            // between the tools and the next request — the model's turn, as
            // the hook's "working" always read.
            guard let a = L.activities.filter({ $0.main }).max(by: { $0.since < $1.since })
            else { return ("thinking", nil, nil, []) }
            switch a.state {
            case "responding":        return ("responding", nil, a.since, [])
            // Named since the contract added `tool` here; an older writer's
            // nameless one reads "Writing tool call".
            case "writing-tool-call": return ("toolcall", a.tool, a.since, [])
            case "tool":              return ("waiting_tool", a.tool, a.since, [])
            case "held":
                // At the gate in an unpaused session: the last hold just
                // went, and the step is released within half a second.
                return a.tool != nil ? ("waiting_tool", a.tool, a.since, [])
                                     : ("thinking", nil, a.since, [])
            default:                  return ("thinking", nil, a.since, [])  // requesting, thinking
            }
        default:
            return nil
        }
    }

    /// The subscriber's merge: the latest snapshot from every publisher into
    /// the feed document. Nothing here touches a source.
    private static func buildFeed(hooks: [HookRecord], live: [String: LiveRecord],
                                  spool: [String: SpoolState], pins: [String: PinRecord],
                                  nowPlaying: Publisher<NowPlaying?>.Snapshot?,
                                  stateSince: inout [String: (String, Double)]) -> String {
        let now = Date().timeIntervalSince1970
        var sessions: [[String: Any]] = []

        // A live file speaks for its session only while it is fresh
        // (PAUSE.md): its pid alive and its heartbeat under a minute old. A
        // stale one is a session that died without cleaning up, or a mod
        // unloaded mid-run — either way the hook file decides again.
        let fresh = live.filter { now - $0.value.updated < liveStaleAfter && pidAlive($0.value.pid) }
        var hooksBySid: [String: HookState] = [:]
        for rec in hooks { hooksBySid[rec.sid] = rec.h }

        // The hook files are the base, but a session they never saw (hooks
        // wired after it started, or not at all) still gets a panel from a
        // fresh live file. Sorted, so equal turn starts keep one order.
        for sid in Set(hooksBySid.keys).union(fresh.keys).sorted() {
            let h = hooksBySid[sid]
            let L = fresh[sid]
            // A fresh live file is a live session by definition — its pid
            // was just checked — even under a hook record a --resume hasn't
            // reopened yet. Without one, the hook record must vouch for it.
            if L == nil {
                guard let h, h.hook_state != "gone" else { continue }
                // A dead CLI is a gone session whether or not SessionEnd ran:
                // a killed process or force-closed terminal never fires it,
                // and the sticky states below (waiting_tool / permission are
                // exempt from decay) would advertise "Permissions required"
                // for an hour.
                guard pidAlive(h.pid?.value) else { continue }
            }
            // LEGACY: the spool only for a session without a fresh live file.
            let s = L == nil ? spool[sid] : nil
            let hookTS = max(h?.hook_ts ?? 0, 0)
            let liveMainTS = L?.mainChangedAt ?? 0
            let activity = max(hookTS, s?.ts ?? 0, L?.usedAt ?? 0)   // real events only
            // Unused for an hour -> panel disappears. An hour because that
            // is Claude Code's prompt-cache TTL: the panel dies exactly when
            // the session's cache does. The statusline heartbeat keeps
            // ticking while the CLI merely sits open, so it must not count —
            // nor must the live file's 15 s `updated`.
            // No real event ever (or the fields were lost): don't show the
            // session at all. Falling back to the statusline heartbeat here
            // made ghost sessions immortal — the heartbeat ticks every 5s
            // in any open CLI, so "last used" always looked seconds old.
            guard activity > 0 else { continue }
            // A turn the live file says is running is in use right now,
            // however old its last change: a 70-minute tool call changes
            // nothing in the file. A settled pause is not in use.
            let running = L.map { $0.turnState == "working" && !$0.settled } ?? false
            let lastUsed = running ? now : activity
            // …unless the session is pinned: the pin is an explicit wish to
            // keep it warm, so its panel stays (showing the pin's state, cold
            // included) until the pin mod deletes the file — on /unpin, at
            // maxHours, or when the session ends. One whose session died
            // without cleaning up has a dead pid; one whose writer went
            // quiet ("pin silent") holds the panel only through the hour
            // after it was last heard from, so a recycled pid can't keep a
            // ghost on the rack forever.
            var pin = pins[sid]
            if let p = pin, !pidAlive(p.pid) || now - p.updated > 3600 { pin = nil }
            if now - lastUsed > 3600, pin == nil { continue }

            // The live file decides — except that permission holds until
            // something newer arrives, the live file's `mainChanged`
            // included: the file doesn't see the dialog. Without a live file, the
            // recency merge of hook and spool.
            var state: String
            var tool = h?.tool
            var exactSince: Double?        // when the state began, if the source knows
            var waitingFor: [String] = []
            var fromLive = false
            if h?.hook_state == "permission" && hookTS >= max(s?.ts ?? 0, liveMainTS) {
                state = "permission"
            } else if let L, let ls = liveState(L) {
                fromLive = true
                state = ls.state
                tool = ls.tool             // nil too: the hook's tool is the previous call's
                exactSince = ls.since
                waitingFor = ls.waitingFor
            } else if let s, s.ts > hookTS {
                state = s.state
                if s.state == "toolcall" || s.state == "waiting_tool" {
                    tool = s.tool ?? tool
                }
            } else {
                state = h?.hook_state ?? "done"
                if state == "working" { state = "thinking" }
            }
            // A STREAMING state whose signals went quiet is an interrupt or
            // a pre-hooks session: decay to done. waiting_tool and permission
            // are exempt — a 40-minute tool execution or a parked approval
            // dialog is legitimately silent (the statusline heartbeat never
            // counts as activity either way). A live state is exempt too:
            // the file says when a turn ends, so a long think is just long.
            if !fromLive, ["thinking", "responding", "toolcall"].contains(state),
               now - activity > 120 { state = "done" }

            // Stamp when this state began, so panels can show "(5s ∙ …)".
            // Keyed with the tool — "Bash: exec" after "Read: exec" is a new
            // state, not the old one's timer — but a state that hasn't
            // changed keeps its stamp (requesting → thinking is one
            // "Thinking"). A change takes the source's own start when it has
            // one. Otherwise first sight of a session (daemon restart) seeds
            // from the last real event rather than `now` — a 40-minute tool
            // wait must not read as seconds old because the daemon bounced.
            let toolState = state == "toolcall" || state == "waiting_tool" || state == "permission"
            let key = toolState ? "\(state):\(tool ?? "?")" : state
            let since: Double
            if let prev = stateSince[sid], prev.0 == key {
                since = prev.1
            } else if let exactSince, exactSince <= now {
                since = exactSince
            } else if stateSince[sid] == nil {
                since = state == "done" ? (h?.turn_ended ?? lastUsed)
                                        : (activity > 0 ? activity : now)
            } else {
                since = now
            }
            stateSince[sid] = (key, since)

            var entry: [String: Any] = ["id": sid, "state": state,
                                        "state_since": since]
            // Composed: a project directory named in Hangul or kana reaches
            // the hook decomposed whenever it came off an HFS+ volume or a
            // path the shell normalised, and the panel measures its cells per
            // Character — a decomposed syllable is several of those. Both
            // follow the session; the hook's first, rewritten at every event
            // where the live file's is re-read after each main turn.
            entry["cwd"] = (h?.cwd ?? L?.cwd ?? s?.cwd ?? "?").precomposedStringWithCanonicalMapping
            if let tool, toolState { entry["tool"] = tool }
            if !waitingFor.isEmpty { entry["waiting_for"] = waitingFor }
            // The live turn's start (its first step), else the hook's (the
            // prompt), else the spool's guess from a 20 s gap.
            if let ts = L?.turnStarted ?? h?.turn_started { entry["turn_started"] = ts }
            else if let s, s.turnStart > 0 { entry["turn_started"] = s.turnStart }
            let liveEnded = (fromLive && L?.turnState == "done") ? L?.turnEnded : nil
            if state == "done" {
                // Freeze Done elapsed: the live file's end when it has the
                // turn, else Stop's timestamp when hooks saw it end, else the
                // spool's last activity.
                entry["turn_ended"] = liveEnded ?? h?.turn_ended ?? s?.ts ?? now
                entry["last_active"] = lastUsed
            } else if fromLive, let L, L.turnState != "working" {
                // Paused between turns — or before this process's first, a
                // resumed session whose turn_started is the hook's old one:
                // no turn clock left to run.
                entry["turn_ended"] = liveEnded ?? L.turnEnded ?? h?.turn_ended ?? activity
            }
            // Context: the live file's own measure, else the statusline's.
            if let total = L?.contextTokens ?? h?.session_tokens {
                entry["session_tokens"] = total
            }
            // "Tokens this turn" = context growth since the prompt: the
            // reply, tool results, and injected reminders alike — every
            // token the turn added. The live file counts it itself
            // (`turn.tokens`), and when it does, that is the number.
            // Otherwise the hook's: the statusline's counts are per request
            // (the live context), so growth is a plain difference against
            // the anchor the hook took at prompt time. Only trust an anchor
            // stamped for THIS turn, and keep both ends of the difference
            // the hook's own: across two sources' ideas of "context" it
            // would be noise.
            if let t = L?.turnTokens {
                if t > 0 { entry["turn_tokens"] = t }
            } else if let h, let total = h.session_tokens, let a = h.anchor_tokens,
                      let at = h.anchor_turn, at == h.turn_started, total > a {
                entry["turn_tokens"] = total - a
            }
            // Background work the last turn left running, on a resting
            // panel: the live file's list when it has the session, else
            // Stop's counts off the hook.
            if state == "done" || state == "paused",
               let bg = fromLive ? L?.background : h?.bg, !bg.isEmpty { entry["bg"] = bg }
            if let pin {
                // Fresh per pin: each session's pin mod writes its own file,
                // where bifrocate's one daemon had one flag for every pin.
                var p: [String: Any] = ["pinned_at": pin.pinnedAt,
                                        "fresh": now - pin.updated < liveStaleAfter]
                if let st = pin.status { p["status"] = st }
                if let n = pin.nextPingAt { p["next_ping_at"] = n }
                if let t = pin.pingedAt { p["pinged_at"] = t }
                if let c = pin.pings { p["pings"] = c }
                entry["pin"] = p
            }
            sessions.append(entry)
        }
        sessions.sort {
            let l = ($0["turn_started"] as? Double) ?? 0, r = ($1["turn_started"] as? Double) ?? 0
            return l != r ? l > r : (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "")
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
