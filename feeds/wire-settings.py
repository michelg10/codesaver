#!/usr/bin/env python3
"""Wire Claude Code into CodeSaver's live session widgets.

Edits ~/.claude/settings.json so that Claude Code reports session state to
CodeSaver: the state-writer hook (cc-state-hook.py) on every session event,
and the statusline wrapper (cc-statusline-wrapper.sh) for the 5-second token
heartbeat. The wrapper passes the statusline you already had through
untouched -- recorded once, at first wiring, in ~/.claude/codesaver/
(statusline-original.json, statusline-passthrough.sh) -- and shows nothing
at all if you had none.

    python3 wire-settings.py              install (idempotent)
    python3 wire-settings.py --dry-run    say what would change, change nothing
    python3 wire-settings.py --status     print one line: wired |
                                          wired-from-dev | partial | not wired
    python3 wire-settings.py --uninstall  remove the hooks, restore the statusline
    python3 wire-settings.py --dev        reference this checkout's scripts
                                          instead of copying them to
                                          ~/.claude/codesaver/bin

CodeSaver.app ships this script and the two hook scripts in
Contents/Resources/claude-code/ and runs it with /usr/bin/python3 behind its
Connect / Disconnect buttons; a checkout has them in feeds/. Either way the
hook scripts are COPIED to ~/.claude/codesaver/bin, so the app can move or
update and the repo can go away. --dev points the hooks at the files right
here instead, for hacking on the hook.

The hooks run under /usr/bin/python3 -I (they are stdlib-only) unless --dev
or --python says otherwise: a venv or conda python baked into settings.json
breaks silently the day that env goes away, and -I keeps a PYTHONHOME or
PYTHONPATH from the shell Claude Code was started in out of it.

--status is for the app: `partial` means some of the wiring is there but not
all of it (a statusline replaced since, an event missing, a script or
interpreter gone) -- installing again repairs it, --uninstall removes it.

The state files land in ~/.claude/codesaver/sessions/; `CodeSaver --feeds`
(the background helper behind the app's Live widgets switch) merges them
into the saver's feed. A backup of settings.json is kept next to it before
every change; the newest three are kept.
"""
import argparse, difflib, glob, json, os, shlex, shutil, stat, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = "cc-state-hook.py"
WRAPPER = "cc-statusline-wrapper.sh"
SYSTEM_PYTHON = "/usr/bin/python3"
HEARTBEAT = 5           # statusline refreshInterval the token counts ride on
KEEP_BACKUPS = 3
# Every event the hook folds into session state (see cc-state-hook.py).
EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "MessageDisplay", "Stop",
    "StopFailure", "SessionEnd",
]


def is_ours(cmd):
    """Ours = names one of our scripts. By name, not by full command, so a
    wiring from a moved checkout, an older version or another python is
    still found and replaced (or removed), never duplicated."""
    return isinstance(cmd, str) and (HOOK in cmd or WRAPPER in cmd)


def words(cmd):
    try:
        return shlex.split(cmd)
    except ValueError:              # unbalanced quotes: not a command we wrote
        return []


def runnable(cmd):
    """Every absolute path in the command still exists: the script, and the
    interpreter when it is spelled out (a vanished venv python is the
    classic silent break)."""
    ws = words(cmd)
    return bool(ws) and all(os.path.exists(w) for w in ws if w.startswith("/"))


def script_dir(cmd):
    for w in words(cmd):
        if os.path.basename(w) in (HOOK, WRAPPER):
            return os.path.dirname(w)
    return None


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        sys.exit(f"{tilde(path)} is not valid JSON ({e}); fix it by hand first")
    if not isinstance(obj, dict):
        sys.exit(f"{tilde(path)} is not a JSON object; fix it by hand first")
    return obj


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, ValueError):
        return None


def write_atomic(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if mode is None and os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)   # a 0600 settings.json stays 0600
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def script_paths(bin_dir, dev):
    """Where the hooks will point: the checkout (--dev) or the copies."""
    base = HERE if dev else bin_dir
    return os.path.join(base, HOOK), os.path.join(base, WRAPPER)


def install_scripts(bin_dir):
    """Fresh copies, every run: re-running after an update refreshes them.
    Atomic, because a hook can fire mid-copy."""
    os.makedirs(bin_dir, exist_ok=True)
    for name in (HOOK, WRAPPER):
        dst = os.path.join(bin_dir, name)
        tmp = f"{dst}.{os.getpid()}.tmp"
        shutil.copyfile(os.path.join(HERE, name), tmp)
        os.chmod(tmp, 0o755)
        os.replace(tmp, dst)


def ours_in(groups):
    return sum(1 for g in groups if isinstance(g, dict)
               for h in (g.get("hooks") if isinstance(g.get("hooks"), list) else [])
               if isinstance(h, dict) and is_ours(h.get("command")))


def strip_ours(groups):
    """Remove our entries from an event's matcher groups in place. Only a
    group that empties BECAUSE of it goes; everything else is left exactly
    as found. True if anything was removed."""
    removed, kept = False, []
    for g in groups:
        hs = g.get("hooks") if isinstance(g, dict) else None
        if isinstance(hs, list):
            rest = [h for h in hs if not (isinstance(h, dict) and is_ours(h.get("command")))]
            if len(rest) != len(hs):
                removed = True
                if not rest:
                    continue
                g["hooks"] = rest
        kept.append(g)
    groups[:] = kept
    return removed


def record(prev, original, passthrough):
    """Side files for the statusline that was there before CodeSaver: the
    whole object for --uninstall (null for none -- an explicit "you had
    none", so nothing is ever guessed), and its command as the script the
    wrapper pipes through. No command, no passthrough: a stale one would
    put an old statusline back on screen."""
    side = {original: dump(prev)}
    cmd = prev.get("command") if isinstance(prev, dict) and prev.get("type") == "command" else None
    if isinstance(cmd, str) and cmd.strip():
        side[passthrough] = (
            "#!/bin/bash\n# The statusline that was configured before CodeSaver was wired in;\n"
            "# cc-statusline-wrapper.sh pipes the statusline JSON through this.\n"
            f"{cmd}\n")
    else:
        side[passthrough] = None
    return side


def wire(settings, hook_cmd, wrapper_cmd, claude_dir):
    """Return (new settings, side files {path: text, or None to delete}) --
    pure on `settings`."""
    s = json.loads(json.dumps(settings))
    codesaver_dir = os.path.join(claude_dir, "codesaver")
    original = os.path.join(codesaver_dir, "statusline-original.json")
    passthrough = os.path.join(codesaver_dir, "statusline-passthrough.sh")

    if not isinstance(s.get("hooks"), dict):
        s["hooks"] = {}
    hooks = s["hooks"]
    want = {"hooks": [{"type": "command", "command": hook_cmd, "async": True}]}
    for ev in EVENTS:
        if not isinstance(hooks.get(ev), list):
            hooks[ev] = []
        groups = hooks[ev]
        if want in groups and ours_in(groups) == 1:
            continue                # exactly wired already: leave its place alone
        # Drop any earlier wiring of ours (a moved repo, a different python)
        # before adding the current one: one entry per event, ever.
        strip_ours(groups)
        groups.append(want)

    side = {}
    prev = s.get("statusLine")
    if isinstance(prev, dict) and is_ours(prev.get("command")):
        # Already wrapped: the record from the first wiring stands. A wiring
        # older than the records has none -- its wrapper fell back to
        # ~/.claude/statusline-command.sh, the file Claude Code's own
        # /statusline setup writes -- so make that the record, once, and the
        # passthrough holds and --uninstall can put it back.
        if not os.path.exists(original):
            legacy = os.path.join(claude_dir, "statusline-command.sh")
            side.update(record(
                {"type": "command", "command": "bash " + shlex.quote(legacy)}
                if os.path.isfile(legacy) else None, original, passthrough))
        new = dict(prev)
    else:
        # First wiring: keep what was there so the wrapper can pass it
        # through, and so --uninstall can put it back exactly.
        side.update(record(prev, original, passthrough))
        # The user's object stays -- padding and whatever else it carries --
        # and only its command is swapped for the wrapper.
        new = dict(prev) if isinstance(prev, dict) and prev.get("type") == "command" else {}
    new["type"] = "command"
    new["command"] = wrapper_cmd
    ri = new.get("refreshInterval")
    if isinstance(ri, bool) or not isinstance(ri, (int, float)) or not 0 < ri <= HEARTBEAT:
        new["refreshInterval"] = HEARTBEAT     # a faster one of the user's stays
    s["statusLine"] = new
    return s, side


def unwire(settings, claude_dir):
    s = json.loads(json.dumps(settings))
    codesaver_dir = os.path.join(claude_dir, "codesaver")
    original = os.path.join(codesaver_dir, "statusline-original.json")
    passthrough = os.path.join(codesaver_dir, "statusline-passthrough.sh")
    hooks = s.get("hooks")
    if isinstance(hooks, dict):
        touched = False
        for ev in list(hooks):
            groups = hooks[ev]
            if isinstance(groups, list) and strip_ours(groups):
                touched = True
                if not groups:
                    del hooks[ev]
        if touched and not hooks:
            del s["hooks"]
    prev = s.get("statusLine")
    if isinstance(prev, dict) and is_ours(prev.get("command")):
        try:
            with open(original, encoding="utf-8") as f:
                restored = json.load(f)
        except (OSError, ValueError):
            restored = None         # no record: there is nothing to put back
        if restored is None:
            del s["statusLine"]
        else:
            s["statusLine"] = restored
    # The records go with the wiring: left behind, the next first wiring's
    # record would be judged against a statusline that is long gone.
    return s, {original: None, passthrough: None}


def status(settings, bin_dir):
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    cmds, events = [], set()
    for ev, groups in hooks.items():
        for g in groups if isinstance(groups, list) else []:
            hs = g.get("hooks") if isinstance(g, dict) else None
            for h in hs if isinstance(hs, list) else []:
                if isinstance(h, dict) and is_ours(h.get("command")):
                    cmds.append(h["command"])
                    events.add(ev)
    sl = settings.get("statusLine")
    sl_ours = isinstance(sl, dict) and is_ours(sl.get("command"))
    if sl_ours:
        cmds.append(sl["command"])
    if not cmds:
        return "not wired"
    if not sl_ours or not set(EVENTS) <= events or not all(runnable(c) for c in cmds):
        return "partial"
    return "wired" if {script_dir(c) for c in cmds} == {bin_dir} else "wired-from-dev"


def summary(before, after, uninstall, dev, hook_cmd, settings_path, bin_dir):
    """What --dry-run says before the diff, in words: the app shows this in
    its confirm sheet."""
    def wired_events(s):
        hooks = s.get("hooks") if isinstance(s.get("hooks"), dict) else {}
        return {ev for ev, gs in hooks.items() if isinstance(gs, list) and ours_in(gs)}

    def statusline(s):
        sl = s.get("statusLine")
        return sl if isinstance(sl, dict) else None

    lines = [f"settings: {tilde(settings_path)} (a backup is kept beside it)"]
    b_sl, a_sl = statusline(before), statusline(after)
    if uninstall:
        n = len(wired_events(before))
        lines.append(f"- removes CodeSaver's hook from {n} Claude Code events" if n
                     else "= no CodeSaver hooks to remove")
        if b_sl and is_ours(b_sl.get("command")):
            lines.append(f"~ statusline: puts yours back ({a_sl['command']})"
                         if a_sl and a_sl.get("command") else
                         "- statusline: removes CodeSaver's (you had none)")
        else:
            lines.append("= statusline: not CodeSaver's, left alone")
        lines.append(f"- deletes {tilde(bin_dir)}; session files in "
                     f"{tilde(os.path.join(os.path.dirname(bin_dir), 'sessions'))} stay")
        return "\n".join(lines)

    b_hooks = before.get("hooks") if isinstance(before.get("hooks"), dict) else {}
    todo = [ev for ev in EVENTS if after["hooks"].get(ev) != b_hooks.get(ev)]
    if todo:
        lines.append(f"+ adds CodeSaver's hook to {len(todo)} Claude Code events "
                     f"({', '.join(todo)}): {hook_cmd}")
        lines.append("  it writes one small file per session; Claude Code doesn't wait for it")
    else:
        lines.append("= hooks already in place")
    if b_sl and is_ours(b_sl.get("command")):
        lines.append("= statusline: already wrapped" if b_sl == a_sl
                     else "~ statusline: CodeSaver's wrapper updated")
    elif b_sl and b_sl.get("type") == "command" and b_sl.get("command"):
        lines.append(f"~ statusline: yours ({b_sl['command']}) keeps showing -- CodeSaver's "
                     "wrapper runs it and reads the model and token counts on the way")
    else:
        lines.append("+ statusline: CodeSaver's, which shows nothing -- you have none -- "
                     "and only reads the model and token counts")
    if not dev:
        lines.append(f"+ copies {HOOK} and {WRAPPER} to {tilde(bin_dir)}")
    lines.append("undo: Disconnect in CodeSaver, or wire-settings.py --uninstall")
    return "\n".join(lines)


def prune_backups(settings_path):
    for old in sorted(glob.glob(glob.escape(settings_path) + ".bak-widgets-*"))[:-KEEP_BACKUPS]:
        try:
            os.remove(old)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true",
                      help="print one line: wired | wired-from-dev | partial | not wired")
    mode.add_argument("--uninstall", action="store_true", help="remove the wiring")
    ap.add_argument("--dry-run", action="store_true", help="say what would change, change nothing")
    ap.add_argument("--dev", action="store_true",
                    help="point the hooks at this checkout instead of copying the scripts")
    ap.add_argument("--python", default=None,
                    help=f"python3 to run the hook with (default: {SYSTEM_PYTHON}; "
                         "with --dev, the one running this script)")
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"),
                    help=argparse.SUPPRESS)  # tests point this at a copy
    a = ap.parse_args()

    settings_path = os.path.abspath(a.settings)
    claude_dir = os.path.dirname(settings_path)
    codesaver_dir = os.path.join(claude_dir, "codesaver")
    bin_dir = os.path.join(codesaver_dir, "bin")
    before = load(settings_path)

    if a.status:
        print(status(before, bin_dir))
        return

    hook_cmd = None
    if a.uninstall:
        after, side = unwire(before, claude_dir)
    else:
        python = a.python or (sys.executable if a.dev else SYSTEM_PYTHON)
        hook_path, wrapper_path = script_paths(bin_dir, a.dev)
        q = shlex.quote
        hook_cmd = f"{q(python)} -I {q(hook_path)}"
        # The wrapper tees into the hook with the same interpreter: one
        # choice of python, recorded in settings.json, nowhere else.
        wrapper_cmd = f"/bin/bash {q(wrapper_path)} {q(python)}"
        after, side = wire(before, hook_cmd, wrapper_cmd, claude_dir)

    # Only the side files that would actually change: what makes a second
    # run a no-op.
    side = {p: t for p, t in side.items()
            if (os.path.exists(p) if t is None else read_text(p) != t)}
    old, new = dump(before), dump(after)

    if a.dry_run:
        print(summary(before, after, a.uninstall, a.dev, hook_cmd, settings_path, bin_dir))
        diff = "".join(difflib.unified_diff(
            old.splitlines(True), new.splitlines(True),
            fromfile=tilde(settings_path), tofile=tilde(settings_path) + " (new)"))
        print()
        sys.stdout.write(diff or "settings.json: no change\n")
        for p, t in side.items():
            print(f"would {'delete' if t is None else 'write'} {tilde(p)}")
        return

    if not a.uninstall and not a.dev:
        install_scripts(bin_dir)
    if old == new and not side:
        if a.uninstall:
            shutil.rmtree(bin_dir, ignore_errors=True)
        print("already " + ("clean" if a.uninstall else "wired") + f": {settings_path}")
        return

    for p, text in side.items():
        if text is None:
            os.remove(p)
        else:
            write_atomic(p, text, mode=0o755 if p.endswith(".sh") else None)
    if old != new:
        if os.path.exists(settings_path):
            backup = f"{settings_path}.bak-widgets-{time.strftime('%Y%m%d-%H%M%S')}"
            if os.path.exists(backup):          # two runs in one second
                backup += f".{os.getpid()}"
            shutil.copyfile(settings_path, backup)
            shutil.copymode(settings_path, backup)  # settings.json can hold API keys
            prune_backups(settings_path)
            print(f"backup: {backup}")
        # Through a symlink, not over it: a settings.json kept in a dotfiles
        # repo stays a link into it.
        write_atomic(os.path.realpath(settings_path), new)
    if a.uninstall:
        shutil.rmtree(bin_dir, ignore_errors=True)
        print(f"unwired: {settings_path}")
        print("session state files stay in " + os.path.join(codesaver_dir, "sessions"))
    else:
        print(f"wired: {settings_path}")
        print(f"hooks -> {hook_cmd}")
        print(f"statusline -> {after['statusLine']['command']}")
        if os.path.exists(os.path.join(codesaver_dir, "statusline-passthrough.sh")):
            print("previous statusline kept, passed through by the wrapper")
        print("Claude Code reads its hooks when a session starts: restart running "
              "sessions. The panels need Live widgets switched on in CodeSaver.app.")


if __name__ == "__main__":
    main()
