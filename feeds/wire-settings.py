#!/usr/bin/env python3
"""Wire Claude Code into CodeSaver's live session widgets.

Edits ~/.claude/settings.json so that Claude Code reports session state to
CodeSaver: the state-writer hook (cc-state-hook.py) on every session event,
and the statusline wrapper (cc-statusline-wrapper.sh) for the 5-second token
heartbeat. The wrapper passes the statusline you already had through
untouched -- it is saved as ~/.claude/codesaver/statusline-passthrough.sh.

    python3 feeds/wire-settings.py              install (idempotent)
    python3 feeds/wire-settings.py --dry-run    show the settings.json diff only
    python3 feeds/wire-settings.py --uninstall  remove the hooks, restore the statusline
    python3 feeds/wire-settings.py --dev        reference this checkout's scripts
                                                instead of copying them to
                                                ~/.claude/codesaver/bin

By default the two scripts are COPIED to ~/.claude/codesaver/bin so the
repo can move or go away afterwards (a prebuilt CodeSaver.app has no repo).
--dev points the hooks at the files right here, for hacking on the hook.

The state files land in ~/.claude/codesaver/sessions/; `CodeSaver --feeds`
(the LaunchAgent the app's "Auto-refresh" toggle registers) merges them into
the saver's feed. A backup of settings.json is kept next to it before every
change.
"""
import argparse, difflib, json, os, shutil, stat, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = "cc-state-hook.py"
WRAPPER = "cc-statusline-wrapper.sh"
# Every event the hook folds into session state (see cc-state-hook.py).
EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "MessageDisplay", "Stop",
    "StopFailure", "SessionEnd",
]


def is_ours(cmd):
    return isinstance(cmd, str) and (HOOK in cmd or WRAPPER in cmd)


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        sys.exit(f"{path}: not valid JSON ({e}); fix it by hand first")


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def write_atomic(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def install_scripts(bin_dir, dev):
    """Where the hooks will point: the checkout (--dev) or fresh copies."""
    if dev:
        return os.path.join(HERE, HOOK), os.path.join(HERE, WRAPPER)
    os.makedirs(bin_dir, exist_ok=True)
    out = []
    for name in (HOOK, WRAPPER):
        dst = os.path.join(bin_dir, name)
        shutil.copyfile(os.path.join(HERE, name), dst)
        os.chmod(dst, os.stat(dst).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        out.append(dst)
    return tuple(out)


def wire(settings, hook_path, wrapper_path, python, codesaver_dir):
    """Return (new settings, side files to write) -- pure on `settings`."""
    s = json.loads(json.dumps(settings))
    hook_cmd = f"{python} {hook_path}"
    hooks = s.setdefault("hooks", {})
    for ev in EVENTS:
        groups = hooks.setdefault(ev, [])
        # Drop any earlier wiring of ours (a moved repo, a different python)
        # before adding the current one: one entry per event, ever.
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h.get("command"))]
        groups[:] = [g for g in groups if g.get("hooks")]
        groups.append({"hooks": [{"type": "command", "command": hook_cmd, "async": True}]})

    side = {}
    prev = s.get("statusLine")
    if not (isinstance(prev, dict) and is_ours(prev.get("command"))):
        # First wiring: keep what was there so the wrapper can pass it
        # through, and so --uninstall can put it back exactly.
        if isinstance(prev, dict) and prev.get("type") == "command" and prev.get("command"):
            side[os.path.join(codesaver_dir, "statusline-original.json")] = dump(prev)
            side[os.path.join(codesaver_dir, "statusline-passthrough.sh")] = (
                "#!/bin/bash\n# The statusline that was configured before CodeSaver was wired in;\n"
                "# cc-statusline-wrapper.sh pipes the statusline JSON through this.\n"
                f"{prev['command']}\n")
    s["statusLine"] = {"type": "command", "command": f"bash {wrapper_path}",
                       "refreshInterval": 5}
    return s, side


def unwire(settings, codesaver_dir):
    s = json.loads(json.dumps(settings))
    hooks = s.get("hooks", {})
    for ev in list(hooks):
        groups = hooks[ev]
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h.get("command"))]
        hooks[ev] = [g for g in groups if g.get("hooks")]
        if not hooks[ev]:
            del hooks[ev]
    if not hooks:
        s.pop("hooks", None)
    prev = s.get("statusLine")
    if isinstance(prev, dict) and is_ours(prev.get("command")):
        original = os.path.join(codesaver_dir, "statusline-original.json")
        try:
            with open(original, encoding="utf-8") as f:
                s["statusLine"] = json.load(f)
        except (OSError, json.JSONDecodeError):
            del s["statusLine"]
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print the diff, change nothing")
    ap.add_argument("--uninstall", action="store_true", help="remove the wiring")
    ap.add_argument("--dev", action="store_true",
                    help="point the hooks at this checkout instead of copying the scripts")
    ap.add_argument("--python", default=None,
                    help="python3 to run the hook with (default: the python3 on PATH)")
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"),
                    help=argparse.SUPPRESS)  # tests point this at a copy
    a = ap.parse_args()

    claude_dir = os.path.dirname(os.path.abspath(a.settings))
    codesaver_dir = os.path.join(claude_dir, "codesaver")
    bin_dir = os.path.join(codesaver_dir, "bin")
    before = load(a.settings)

    side = {}
    if a.uninstall:
        after = unwire(before, codesaver_dir)
    else:
        python = a.python or shutil.which("python3") or sys.executable
        if a.dry_run:
            hook_path, wrapper_path = (
                (os.path.join(HERE, HOOK), os.path.join(HERE, WRAPPER)) if a.dev
                else (os.path.join(bin_dir, HOOK), os.path.join(bin_dir, WRAPPER)))
        else:
            hook_path, wrapper_path = install_scripts(bin_dir, a.dev)
        after, side = wire(before, hook_path, wrapper_path, python, codesaver_dir)

    old, new = dump(before), dump(after)
    diff = "".join(difflib.unified_diff(
        old.splitlines(True), new.splitlines(True),
        fromfile=a.settings, tofile=a.settings + " (new)"))
    if old == new and not side:
        print("already " + ("clean" if a.uninstall else "wired") + f": {a.settings}")
        return
    if a.dry_run:
        sys.stdout.write(diff or "(no change)\n")
        for p in side:
            print(f"would write {p}")
        return

    for p, text in side.items():
        write_atomic(p, text, mode=0o755 if p.endswith(".sh") else None)
    if os.path.exists(a.settings):
        backup = f"{a.settings}.bak-widgets-{time.strftime('%Y%m%d-%H%M%S')}"
        if os.path.exists(backup):          # two runs in one second
            backup += f".{os.getpid()}"
        shutil.copyfile(a.settings, backup)
        print(f"backup: {backup}")
    write_atomic(a.settings, new)
    if a.uninstall:
        shutil.rmtree(bin_dir, ignore_errors=True)
        print(f"unwired: {a.settings}")
        print("session state files stay in " + os.path.join(codesaver_dir, "sessions"))
    else:
        print(f"wired: {a.settings}")
        print(f"hooks -> {hook_path}")
        print(f"statusline -> {wrapper_path}")
        if any(p.endswith("statusline-passthrough.sh") for p in side):
            print("previous statusline kept, passed through by the wrapper")
        print("Claude Code reloads settings on its next start; the widgets need "
              "the feeds daemon (Auto-refresh toggle in CodeSaver.app).")


if __name__ == "__main__":
    main()
