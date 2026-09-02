#!/bin/bash
# CodeSaver statusline wrapper: passes the statusline JSON through to the
# user's real statusline script unchanged, and tees it (in the background,
# so the bar's latency is untouched) into the CodeSaver state writer for
# session token counts / model / heartbeat.
input=$(/bin/cat)
printf '%s' "$input" | /Users/michel/miniforge3/bin/python3 \
  /Users/michel/Desktop/codesaver/feeds/cc-state-hook.py --statusline \
  >/dev/null 2>&1 &
printf '%s' "$input" | bash "$HOME/.claude/statusline-command.sh"
