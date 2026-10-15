#!/bin/bash
# CodeSaver statusline wrapper: passes the statusline JSON through to the
# statusline that was there before CodeSaver was wired in, unchanged, and
# tees it (in the background, so the bar's latency is untouched) into the
# CodeSaver state writer for session token counts / model / heartbeat.
#
# Installed by wire-settings.py, which records the previous statusline
# command once, at first wiring, as ~/.claude/codesaver/statusline-passthrough.sh
# and passes the hook's python as $1. Only that record is passed through: a
# record of none means there was no statusline before, so print nothing and
# Claude Code shows none. The one exception is a wiring older than the
# records, below.
input=$(/bin/cat)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${1:-/usr/bin/python3}"
printf '%s' "$input" | "$py" -I "$here/cc-state-hook.py" --statusline >/dev/null 2>&1 &
passthrough="$HOME/.claude/codesaver/statusline-passthrough.sh"
if [[ -s "$passthrough" ]]; then
  printf '%s' "$input" | /bin/bash "$passthrough"
elif [[ ! -e "$HOME/.claude/codesaver/statusline-original.json" \
        && -f "$HOME/.claude/statusline-command.sh" ]]; then
  # A wiring older than the records (no statusline-original.json at all,
  # not even a null one) relied on this fallback, and its settings.json
  # still runs this script: keep showing that statusline until the next
  # wiring makes it the record.
  printf '%s' "$input" | /bin/bash "$HOME/.claude/statusline-command.sh"
fi
