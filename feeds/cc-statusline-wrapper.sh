#!/bin/bash
# CodeSaver statusline wrapper: passes the statusline JSON through to the
# statusline that was there before CodeSaver was wired in, unchanged, and
# tees it (in the background, so the bar's latency is untouched) into the
# CodeSaver state writer for session token counts / model / heartbeat.
#
# Installed by feeds/wire-settings.py, which also saves the previous
# statusline command as ~/.claude/codesaver/statusline-passthrough.sh. No
# saved command and no ~/.claude/statusline-command.sh means there was no
# statusline before: print nothing, and Claude Code shows none.
input=$(/bin/cat)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
printf '%s' "$input" | "$py" "$here/cc-state-hook.py" --statusline >/dev/null 2>&1 &
passthrough="$HOME/.claude/codesaver/statusline-passthrough.sh"
if [[ -s "$passthrough" ]]; then
  printf '%s' "$input" | bash "$passthrough"
elif [[ -f "$HOME/.claude/statusline-command.sh" ]]; then
  printf '%s' "$input" | bash "$HOME/.claude/statusline-command.sh"
fi
