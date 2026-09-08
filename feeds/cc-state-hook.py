#!/usr/bin/env python3
"""Claude Code -> CodeSaver session-state writer.

Registered (async) on ~10 hook events in ~/.claude/settings.json, and invoked
with --statusline from the statusline wrapper. Each call folds one event into
~/.claude/codesaver/sessions/<session_id>.json (atomic replace). The CodeSaver
feeds daemon (`CodeSaver --feeds`) merges these files with bifrocate's CoT
spools and mirrors the result into the app-group container for the saver.

Contract: NEVER write to stdout (UserPromptSubmit/SessionStart stdout is
injected into Claude's context), never exit non-zero, stay fast. Subagent
events (payload has agent_id) are ignored -- one state per session.
"""
import fcntl, json, os, sys, time, unicodedata

DIR = os.path.expanduser("~/.claude/codesaver/sessions")


def locked(sid):
    """Per-session advisory lock: the async hook writers and the 5s
    statusline writer race on the same file, and a stale read written back
    silently drops newer fields (lost hook_ts made dead sessions look
    heartbeat-fresh forever)."""
    os.makedirs(DIR, exist_ok=True)
    lk = open(os.path.join(DIR, f".{sid}.lock"), "w")
    fcntl.flock(lk, fcntl.LOCK_EX)
    return lk


def load(sid):
    # encoding= is explicit on every open here: the hook inherits whatever
    # environment Claude Code was launched from, and under LANG=C a bare
    # open() would pick a non-UTF-8 codec, blow up on a CJK cwd, and be
    # swallowed by the catch-all below -- the session would simply stop
    # updating, with nothing to show for it.
    try:
        with open(os.path.join(DIR, sid + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def store(sid, st):
    os.makedirs(DIR, exist_ok=True)
    tmp = os.path.join(DIR, f".{sid}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, os.path.join(DIR, sid + ".json"))


def nfc(v):
    """Compose a path before it goes on the wire. A directory named in
    Hangul or kana arrives decomposed from an HFS+ volume (한 as three
    jamo), and the saver's panel measures its width one Character at a
    time -- a decomposed syllable counts as several."""
    return unicodedata.normalize("NFC", v) if isinstance(v, str) else v


def main():
    try:
        # Read bytes and decode UTF-8 ourselves rather than trusting
        # sys.stdin's locale-derived codec, for the same reason as above.
        data = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except Exception:
        return
    now = time.time()

    if "--statusline" in sys.argv:
        sid = data.get("session_id")
        if not sid:
            return
        lk = locked(sid)
        st = load(sid)
        st["session_id"] = sid
        st["cwd"] = nfc(data.get("cwd") or (data.get("workspace") or {}).get(
            "current_dir") or st.get("cwd"))
        st["model"] = (data.get("model") or {}).get("display_name") or st.get("model")
        cw = data.get("context_window") or {}
        out = cw.get("total_output_tokens")
        inp = cw.get("total_input_tokens")
        if isinstance(out, (int, float)):
            # Despite the names, both are PER-REQUEST: input is the last
            # request's prompt (= the live context size), output is the last
            # request's reply. Their sum is the context after the last
            # request, so "tokens this turn" is its growth since the prompt:
            # the daemon shows session_tokens - anchor_tokens.
            total = int(out) + (int(inp) if isinstance(inp, (int, float)) else 0)
            prev = st.get("session_tokens")
            if st.get("anchor_turn") != st.get("turn_started"):
                # Fallback anchor for a turn whose UserPromptSubmit predates
                # the hooks; the hook-side anchor (set at prompt time) wins.
                st["anchor_turn"] = st.get("turn_started")
                st["anchor_tokens"] = total
            elif isinstance(prev, int) and total < prev:
                # Context shrank mid-turn (compaction, tool-result clearing).
                # Slide the anchor down by the drop so growth-so-far carries
                # across and the count keeps rising from where it was.
                st["anchor_tokens"] = st.get("anchor_tokens", 0) - (prev - total)
            st["session_tokens"] = total
        st["sl_ts"] = now
        store(sid, st)
        lk.close()
        return

    if data.get("agent_id"):        # subagent event: not this session's state
        return
    sid = data.get("session_id")
    if not sid:
        return
    ev = data.get("hook_event_name") or ""
    lk = locked(sid)
    st = load(sid)
    st["session_id"] = sid
    if data.get("cwd"):
        st["cwd"] = nfc(data["cwd"])
    st["hook_ts"] = now
    pid = os.environ.get("CLAUDE_PID") or ""
    if pid.isdigit():               # the CLI's pid: the daemon checks liveness
        st["pid"] = int(pid)

    if ev == "SessionStart":
        # A resumed session (--resume / --continue keep the id) arrives
        # still marked "gone" by its own SessionEnd; left alone it stayed
        # invisible until the first prompt of the new run.
        if st.get("hook_state") in (None, "gone"):
            st["hook_state"] = "done"
        if data.get("model"):
            st["model"] = data["model"]
    elif st.get("hook_state") == "gone" and ev != "UserPromptSubmit":
        # SessionEnd's async siblings can land after it (a Stop or
        # MessageDisplay from the final turn): a straggler must not
        # resurrect a closed session as "done" for the next hour. Only
        # SessionStart above or a new turn's prompt reopens it.
        lk.close()
        return
    elif ev == "UserPromptSubmit":
        st["hook_state"] = "working"
        st["turn_started"] = now
        # Anchor the context size here, before this turn's first request
        # lands; the statusline branch would anchor one response too late.
        st["anchor_turn"] = now
        st["anchor_tokens"] = st.get("session_tokens", 0)
        st.pop("turn_ended", None)
        st.pop("bg", None)
    elif ev == "PreToolUse":
        st["hook_state"] = "waiting_tool"
        st["tool"] = data.get("tool_name") or "?"
    elif ev in ("PostToolUse", "PostToolUseFailure"):
        st["hook_state"] = "working"
    elif ev == "PermissionRequest":
        st["hook_state"] = "permission"
        st["tool"] = data.get("tool_name") or "?"
    elif ev == "MessageDisplay":
        # Async hooks don't execute in fire order: the final text's display
        # hook can run AFTER Stop already wrote "done". A straggler must
        # never resurrect the turn (a real new turn always begins with
        # UserPromptSubmit -> "working" first).
        if st.get("hook_state") == "done":
            lk.close()
            return
        st["hook_state"] = "responding"
    elif ev in ("Stop", "StopFailure"):
        st["hook_state"] = "done"
        st["turn_ended"] = now
        counts = {}
        for t in data.get("background_tasks") or []:
            k = t.get("type") or "task"
            counts[k] = counts.get(k, 0) + 1
        if counts:
            st["bg"] = counts
    elif ev == "SessionEnd":
        st["hook_state"] = "gone"
    else:
        lk.close()
        return                      # unknown event: change nothing
    store(sid, st)
    lk.close()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass                        # never break a Claude Code session
