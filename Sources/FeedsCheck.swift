import Foundation

// The feed daemon's merge, run on fabricated files:
//
//   ./build.sh && ./build/feeds-check
//
// Points every directory FeedsService reads — CODESAVER_SESSIONS_DIR,
// CLAUDE_LIVE_DIR (and its pins/), CODESAVER_SPOOL_DIR — at a fresh temp
// directory BEFORE the first read (the daemon resolves them once), writes
// hook, live, pin and spool files for a set of made-up
// sessions, runs the merge and checks what it made of each. Never touches
// ~/.claude, ~/.bifrocate or the app-group feed, so it is safe beside a
// running daemon and real sessions. Exits 1 if any check fails.

@main
struct FeedsCheck {
    static var failures = 0
    static var root: URL?

    static func main() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("feeds-check-\(getpid())")
        // Every way out is exit(), which runs no `defer`: clean up at exit.
        Self.root = root
        atexit { if let r = FeedsCheck.root { try? FileManager.default.removeItem(at: r) } }
        func dir(_ name: String, _ env: String) -> URL {
            let u = root.appendingPathComponent(name)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            setenv(env, u.path, 1)
            return u
        }
        let sessionsDir = dir("sessions", "CODESAVER_SESSIONS_DIR")
        let liveDir = dir("live", "CLAUDE_LIVE_DIR")
        let spoolDir = dir("spool", "CODESAVER_SPOOL_DIR")
        _ = dir("widgets", "CODESAVER_WIDGETS_DIR")      // never written; belt and braces
        let pinsDir = liveDir.appendingPathComponent("pins")
        try? fm.createDirectory(at: pinsDir, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        func ms(_ t: Double) -> Double { (t * 1000).rounded() }
        let me = Int(getpid())
        // A pid that is certainly dead: a child that ran and was reaped.
        let dead: Int = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try? p.run()
            p.waitUntilExit()
            return Int(p.processIdentifier)
        }()
        if kill(pid_t(dead), 0) == 0 || errno != ESRCH {
            print("can't find a dead pid (\(dead) answers) — the liveness checks would lie")
            exit(1)
        }

        func write(_ url: URL, _ obj: Any) {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            try! data.write(to: url)
        }
        func hook(_ sid: String, _ fields: [String: Any]) {
            var o: [String: Any] = ["session_id": sid, "pid": me, "cwd": "/tmp/hook/\(sid)"]
            o.merge(fields) { $1 }
            write(sessionsDir.appendingPathComponent("\(sid).json"), o)
        }
        func turn(_ state: String, started: Double? = nil, ended: Double? = nil,
                  end: String? = nil, tokens: Int? = nil) -> [String: Any] {
            ["state": state, "started": started.map(ms) ?? NSNull(),
             "ended": ended.map(ms) ?? NSNull(), "end": end ?? NSNull(),
             "tokens": tokens.map { $0 as Any } ?? NSNull()]
        }
        func act(_ state: String, _ since: Double, agent: String = "main",
                 tool: String? = nil) -> [String: Any] {
            var a: [String: Any] = ["agent": agent, "label": agent, "state": state, "since": ms(since)]
            if let tool { a["tool"] = tool; a["detail"] = "x" }
            return a
        }
        // `changed` and `mainChanged` default to what the contract says they
        // are — the latest stamp in the file, and the latest of the main
        // conversation's — and are set by hand where a check is about them.
        // `changed` takes in subagents and holds, so a check fails if the
        // merge ever ranks a hook event against it. `legacy` writes the file
        // as a mod older than mainChanged / pausedSince / turn.tokens did.
        func live(_ sid: String, _ t: [String: Any], _ activities: [[String: Any]] = [],
                  paused: Bool = false, settled: Bool = false, pausedSince: Double? = nil,
                  background: [[String: Any]] = [], pid: Int? = nil, updated: Double? = nil,
                  changed: Double? = nil, mainChanged: Double? = nil, tokens: Int? = 50000,
                  legacy: Bool = false) {
            let turnStamps = [t["started"], t["ended"]].compactMap { $0 as? Double }
            let all = activities.compactMap { $0["since"] as? Double } + turnStamps
            let main = activities.filter { $0["agent"] as? String == "main" }
                .compactMap { $0["since"] as? Double } + turnStamps
            var o: [String: Any] = [
                "v": 1, "sid": sid, "pid": pid ?? me, "cwd": "/tmp/live/\(sid)",
                "model": "claude-opus-5-5",
                "context": ["tokens": tokens.map { $0 as Any } ?? NSNull(), "window": 1_000_000],
                "updated": ms(updated ?? now), "changed": changed.map(ms) ?? all.max() ?? ms(now),
                "turn": t,
                "paused": paused, "holds": paused ? ["all__suspend.json"] : [], "settled": settled,
                "activities": activities, "background": background,
            ]
            if legacy {
                var lt = t; lt["tokens"] = nil; o["turn"] = lt
            } else {
                o["mainChanged"] = mainChanged.map(ms) ?? main.max() ?? ms(now)
                o["pausedSince"] = pausedSince.map(ms) ?? NSNull()
            }
            write(liveDir.appendingPathComponent("\(sid).json"), o)
        }
        func pin(_ sid: String, status: String, updated: Double, pid: Int? = nil,
                 next: Double? = nil) {
            write(pinsDir.appendingPathComponent("\(sid).json"), [
                "v": 1, "sid": sid, "pid": pid ?? me, "updated": ms(updated),
                "pinnedAt": ms(now - 9000), "idleMinutes": 45, "maxHours": 24,
                "status": status, "nextPingAt": next.map(ms) ?? NSNull(),
                "pingedAt": ms(now - 2700), "pings": 3,
                "lastCacheRead": 152_096, "lastContext": 154_000,
            ] as [String: Any])
        }
        func spool(_ sid: String, _ events: [[String: Any]]) {
            let text = events.map {
                String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
            }.joined(separator: "\n") + "\n"
            try! text.write(to: spoolDir.appendingPathComponent("\(sid).jsonl"),
                            atomically: true, encoding: .utf8)
        }
        let restingHook: [String: Any] = ["hook_state": "done", "hook_ts": now - 7200,
                                          "turn_started": now - 7300, "turn_ended": now - 7200]

        // ── the sessions ────────────────────────────────────────────────
        // The live file beats a newer hook "done"; tokens: context and the
        // turn's growth both off the live file, the hook's anchor only when
        // the file has no turn.tokens.
        let anchoredHook: [String: Any] = ["hook_state": "done", "hook_ts": now - 1,
                                           "turn_started": now - 100, "turn_ended": now - 60,
                                           "session_tokens": 60000, "anchor_tokens": 55000,
                                           "anchor_turn": now - 100]
        hook("live-thinking", anchoredHook)
        live("live-thinking", turn("working", started: now - 30, tokens: 1830),
             [act("thinking", now - 5)], tokens: 61234)
        hook("live-hook-tokens", anchoredHook)
        live("live-hook-tokens", turn("working", started: now - 30), [act("thinking", now - 5)])
        live("live-responding", turn("working", started: now - 30), [act("responding", now - 3)])
        // A streaming tool call carries its name; an older writer's didn't,
        // and the hook's tool is the previous call's, so it mustn't stand in.
        hook("live-emit", ["hook_state": "waiting_tool", "tool": "Read", "hook_ts": now - 10])
        live("live-emit", turn("working", started: now - 30),
             [act("writing-tool-call", now - 2, tool: "Bash")])
        hook("live-emit-old", ["hook_state": "waiting_tool", "tool": "Read", "hook_ts": now - 10])
        live("live-emit-old", turn("working", started: now - 30), [act("writing-tool-call", now - 2)],
             legacy: true)
        live("live-parallel", turn("working", started: now - 60), [
            act("tool", now - 50, tool: "Read"), act("tool", now - 42, tool: "Bash"),
            act("thinking", now - 1, agent: "a1"),
        ])
        hook("live-esc", ["hook_state": "working", "hook_ts": now - 3, "turn_started": now - 40])
        live("live-esc", turn("done", started: now - 40, ended: now - 2, end: "aborted"))
        hook("perm-holds", ["hook_state": "permission", "tool": "Bash", "hook_ts": now - 1])
        live("perm-holds", turn("working", started: now - 30), [act("tool", now - 10, tool: "Bash")])
        hook("perm-superseded", ["hook_state": "permission", "tool": "Bash", "hook_ts": now - 20])
        live("perm-superseded", turn("working", started: now - 30), [act("thinking", now - 5)])
        // `changed` moved with the subagent's step (and a hold since): the
        // main agent's prompt is still open.
        hook("perm-subagent", ["hook_state": "permission", "tool": "Edit", "hook_ts": now - 5])
        live("perm-subagent", turn("working", started: now - 30),
             [act("thinking", now - 1, agent: "a1")], changed: now)
        // The main agent's tool finished after the prompt (approved, ran,
        // cleared): no activity left to carry a stamp, but `mainChanged`
        // moved, and the prompt is over. A legacy file can't say so.
        hook("perm-mainchanged", ["hook_state": "permission", "tool": "Bash", "hook_ts": now - 5])
        live("perm-mainchanged", turn("working", started: now - 30), [], mainChanged: now - 1)
        hook("perm-legacy", ["hook_state": "permission", "tool": "Bash", "hook_ts": now - 5])
        live("perm-legacy", turn("working", started: now - 30), [], legacy: true)
        // Pause.
        live("paused-settled", turn("working", started: now - 700), [act("held", now - 100)],
             paused: true, settled: true, pausedSince: now - 600)
        live("pausing", turn("working", started: now - 200), [
            act("held", now - 55), act("tool", now - 30, agent: "a1", tool: "Bash"),
            act("thinking", now - 10, agent: "a2"), act("tool", now - 20, agent: "a3", tool: "Bash"),
        ], paused: true, settled: false, pausedSince: now - 60)
        live("paused-idle", turn("done", started: now - 1000, ended: now - 900, end: "answer"), [],
             paused: true, settled: true, pausedSince: now - 300,
             background: [["type": "shell", "description": "npm run dev"],
                          ["type": "shell", "description": "tail"],
                          ["type": "subagent", "description": "review"]])
        // A resumed session paused before its first turn here: the hook's
        // old turn must not tick "elapsed".
        hook("paused-resumed", ["hook_state": "done", "hook_ts": now - 1200,
                                "turn_started": now - 1300, "turn_ended": now - 1200])
        live("paused-resumed", turn("idle"), [], paused: true, settled: true,
             pausedSince: now - 600)
        // Freshness and the legacy spool.
        hook("stale-live", ["hook_state": "done", "hook_ts": now - 300, "turn_ended": now - 300,
                            "turn_started": now - 400])
        live("stale-live", turn("working", started: now - 200), [act("responding", now - 150)],
             updated: now - 120)
        spool("stale-live", [["e": "req", "t": now - 10], ["e": "think", "t": now - 9]])
        hook("spool-ignored", ["hook_state": "done", "hook_ts": now - 50])
        live("spool-ignored", turn("done", started: now - 60, ended: now - 40, end: "answer"))
        spool("spool-ignored", [["e": "req", "t": now - 5], ["e": "think", "t": now - 4]])
        live("dead-live", turn("working", started: now - 10), [act("thinking", now - 5)], pid: dead)
        live("live-only", turn("working", started: now - 10), [act("tool", now - 4, tool: "Grep")])
        hook("live-idle", ["hook_state": "done", "hook_ts": now - 20, "turn_ended": now - 20,
                           "turn_started": now - 50])
        live("live-idle", turn("idle"))
        hook("garbled", ["hook_state": "done", "hook_ts": now - 15, "turn_ended": now - 15])
        try! "{\"v\":1,\"sid\":\"garb".write(to: liveDir.appendingPathComponent("garbled.json"),
                                             atomically: true, encoding: .utf8)
        hook("resumed", ["hook_state": "gone", "hook_ts": now - 500])
        live("resumed", turn("working", started: now - 3), [act("thinking", now - 2)])
        hook("gone", ["hook_state": "gone", "hook_ts": now - 5])
        hook("hook-decay", ["hook_state": "working", "hook_ts": now - 200, "turn_started": now - 300])
        live("live-long-think", turn("working", started: now - 210), [act("thinking", now - 200)])
        live("live-long-tool", turn("working", started: now - 4300),
             [act("tool", now - 4200, tool: "Bash")])
        // Pins: kept past the hour while their pid lives and the pin mod has
        // been heard from within it.
        hook("pin-waiting", restingHook)
        pin("pin-waiting", status: "waiting", updated: now - 5, next: now + 600)
        hook("pin-silent", restingHook)
        pin("pin-silent", status: "waiting", updated: now - 300, next: now + 600)
        hook("pin-dead", restingHook)
        pin("pin-dead", status: "waiting", updated: now - 5, pid: dead, next: now + 600)
        hook("pin-expired", restingHook)
        pin("pin-expired", status: "cold", updated: now - 4000)
        hook("unpinned-old", restingHook)
        // Suspend lands on a session idle for two hours: its hold is a real
        // change (`changed` moves), but not a use — it stays off the rack.
        hook("suspend-idle", restingHook)
        live("suspend-idle", turn("done", started: now - 7300, ended: now - 7200, end: "answer"), [],
             paused: true, settled: true, pausedSince: now - 30, changed: now)
        live("continuity", turn("working", started: now - 10), [act("requesting", now - 8)])

        // ── one merge ───────────────────────────────────────────────────
        var since: [String: (String, Double)] = [:]
        var byId = sessions(FeedsService.feedOnce(stateSince: &since))
        // …and a second, after the continuity session's request starts
        // thinking: the same "Thinking", so the same stamp.
        live("continuity", turn("working", started: now - 10), [act("thinking", now - 2)])
        let second = sessions(FeedsService.feedOnce(stateSince: &since))
        byId["continuity"] = second["continuity"]

        func expect(_ sid: String, _ what: String, _ ok: (([String: Any]) -> Bool)) {
            let e = byId[sid]
            if let e, ok(e) {
                print("ok    \(sid): \(what)")
            } else {
                failures += 1
                print("FAIL  \(sid): \(what)\n      got \(e.map { "\($0)" } ?? "no panel")")
            }
        }
        func absent(_ sid: String, _ why: String) {
            if byId[sid] == nil { print("ok    \(sid): no panel (\(why))") } else {
                failures += 1
                print("FAIL  \(sid): should have no panel (\(why))\n      got \(byId[sid]!)")
            }
        }
        func near(_ v: Any?, _ t: Double) -> Bool { (v as? Double).map { abs($0 - t) < 1.5 } ?? false }
        func state(_ e: [String: Any]) -> String { e["state"] as? String ?? "" }
        func pinOf(_ e: [String: Any]) -> [String: Any] { e["pin"] as? [String: Any] ?? [:] }

        expect("live-thinking", "thinking from the live file over a newer hook done") {
            state($0) == "thinking" && near($0["state_since"], now - 5)
                && near($0["turn_started"], now - 30) && $0["turn_ended"] == nil
        }
        expect("live-thinking", "session and turn tokens off the live file") {
            $0["session_tokens"] as? Int == 61234 && $0["turn_tokens"] as? Int == 1830
        }
        expect("live-hook-tokens", "no turn.tokens: the hook's anchor still gives the turn's") {
            $0["turn_tokens"] as? Int == 5000
        }
        expect("live-thinking", "cwd from the hook first") { $0["cwd"] as? String == "/tmp/hook/live-thinking" }
        expect("live-responding", "responding") { state($0) == "responding" && near($0["state_since"], now - 3) }
        expect("live-emit", "toolcall, named by the streaming call") {
            state($0) == "toolcall" && $0["tool"] as? String == "Bash"
        }
        expect("live-emit-old", "toolcall, nameless, without the hook's stale tool") {
            state($0) == "toolcall" && $0["tool"] == nil
        }
        expect("live-parallel", "the newest main tool call, not the subagent") {
            state($0) == "waiting_tool" && $0["tool"] as? String == "Bash"
                && near($0["state_since"], now - 42)
        }
        expect("live-esc", "Esc is done at once, ended when the file says") {
            state($0) == "done" && near($0["turn_ended"], now - 2)
        }
        expect("perm-holds", "permission holds over an older live step") {
            state($0) == "permission" && $0["tool"] as? String == "Bash"
        }
        expect("perm-superseded", "a newer live step ends the permission") { state($0) == "thinking" }
        expect("perm-subagent", "a subagent's step doesn't end the main permission") {
            state($0) == "permission" && $0["tool"] as? String == "Edit"
        }
        expect("perm-mainchanged", "a newer mainChanged ends it, with no stamp to show") {
            state($0) == "thinking"
        }
        expect("perm-legacy", "without mainChanged, the main agent's stamps rank it") {
            state($0) == "permission"
        }
        expect("paused-settled", "paused, since pausedSince, mid-turn") {
            state($0) == "paused" && near($0["state_since"], now - 600)
                && $0["turn_ended"] == nil && near($0["turn_started"], now - 700)
        }
        expect("pausing", "pausing, waiting on any agent's work, oldest first, deduped") {
            state($0) == "pausing" && $0["waiting_for"] as? [String] == ["Bash", "model"]
                && near($0["state_since"], now - 60)
        }
        expect("paused-idle", "paused between turns: turn ended, background counted") {
            state($0) == "paused" && near($0["turn_ended"], now - 900)
                && $0["bg"] as? [String: Int] == ["shell": 2, "subagent": 1]
                && near($0["state_since"], now - 300)
        }
        expect("paused-resumed", "paused before this process's first turn: no turn clock") {
            state($0) == "paused" && $0["turn_ended"] != nil
        }
        expect("stale-live", "a stale live file is ignored; the legacy spool decides") {
            state($0) == "thinking"
        }
        expect("spool-ignored", "a fresh live file shuts the spool out") { state($0) == "done" }
        absent("dead-live", "live file of a dead pid, no hook record")
        expect("live-only", "a session the hooks never saw") {
            state($0) == "waiting_tool" && $0["tool"] as? String == "Grep"
                && $0["cwd"] as? String == "/tmp/live/live-only"
        }
        expect("live-idle", "no turn yet in the live file: the hook's record stands") {
            state($0) == "done" && near($0["turn_ended"], now - 20) && near($0["turn_started"], now - 50)
        }
        expect("garbled", "a half-written live file falls back to the hook") { state($0) == "done" }
        expect("resumed", "a fresh live file outranks a hook record still marked gone") {
            state($0) == "thinking"
        }
        absent("gone", "SessionEnd, no live file")
        expect("hook-decay", "hook-only streaming state still decays after 120 s") { state($0) == "done" }
        expect("live-long-think", "a live think doesn't decay") { state($0) == "thinking" }
        expect("live-long-tool", "a running live turn stays past the hour") {
            state($0) == "waiting_tool" && near($0["state_since"], now - 4200)
        }
        expect("pin-waiting", "pinned past the hour, times in seconds") {
            let p = pinOf($0)
            return state($0) == "done" && p["status"] as? String == "waiting"
                && near(p["next_ping_at"], now + 600) && near(p["pinned_at"], now - 9000)
                && near(p["pinged_at"], now - 2700) && p["pings"] as? Int == 3
                && p["fresh"] as? Bool == true
        }
        expect("pin-silent", "a pin not rewritten for a minute is silent") {
            pinOf($0)["fresh"] as? Bool == false
        }
        absent("pin-dead", "pin of a dead pid, past the hour")
        absent("pin-expired", "pin silent for over an hour, past the hour")
        absent("unpinned-old", "unused for an hour, no pin")
        absent("suspend-idle", "a pause isn't a use")
        expect("continuity", "requesting → thinking keeps one stamp") {
            state($0) == "thinking" && near($0["state_since"], now - 8)
        }

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func sessions(_ feed: String) -> [String: [String: Any]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(feed.utf8))) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]] else {
            print("the merge produced no feed: \(feed)")
            exit(1)
        }
        var out: [String: [String: Any]] = [:]
        for e in list { if let id = e["id"] as? String { out[id] = e } }
        return out
    }
}
