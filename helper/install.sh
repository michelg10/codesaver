#!/bin/zsh
# Legacy. The igniter used to be installed from here as a standalone
# LaunchAgent (~/Library/Application Support/CodeSaver/CodeSaverIgniter.app +
# ~/Library/LaunchAgents/com.michelg10.CodeSaver.Igniter.plist). It now ships
# inside CodeSaver.app, switched on from the app's Ignition section — and the
# app retires a standalone copy by itself the first time it opens from
# /Applications, keeping its Screen Recording grant and corner settings
# (same bundle identifier, same team, same defaults domain). Usage:
#   ./helper/install.sh              says so, installs nothing
#   ./helper/install.sh uninstall    removes a standalone install by hand
#
# For --corners / --capture debugging, ./build.sh still builds the bare
# build/codesaver-igniter.
set -euo pipefail

LABEL=com.michelg10.CodeSaver.Igniter
APP_DIR="$HOME/Library/Application Support/CodeSaver/CodeSaverIgniter.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

if [[ ${1:-} == uninstall ]]; then
  # The app's own igniter runs under the same label. Boot out only the
  # standalone job — its plist is still here, or launchd's record runs the
  # standalone app — so this never stops an igniter the app switched on.
  JOB=$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null || true)
  if [[ -f $PLIST || $JOB == *"$APP_DIR"* ]]; then
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    JOB=""
  fi
  rm -f "$PLIST"
  rm -rf "$APP_DIR"
  # Captures a killed igniter can leave behind — screenshots of the desktop,
  # the boom- files in both places the saver reads them from.
  for dir in "$HOME/Library/Application Support/CodeSaver" \
             "$HOME/Library/Containers/com.michelg10.CodeSaver.Extension/Data/Library/Application Support/CodeSaver"; do
    rm -f "$dir"/boom-*(N)
  done
  echo "── standalone igniter removed (corner settings and ~/Library/Logs/CodeSaver kept)"
  [[ -n $JOB ]] && echo "   CodeSaver.app's own igniter is still on — switch Ignition off in the app to stop it"
  exit 0
fi

echo "── the igniter now ships inside CodeSaver.app — turn on Ignition in the app"
echo "   (nothing installed; a standalone copy from this script is taken over"
echo "   automatically the next time CodeSaver opens from /Applications, or"
echo "   removed by hand with: ./helper/install.sh uninstall)"
exit 0
