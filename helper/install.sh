#!/bin/zsh
# Install the CodeSaver igniter LaunchAgent — the capture scout that keeps a
# fresh desktop screenshot ready for the saver's boom intro. Usage:
#   ./helper/install.sh              install + start
#   ./helper/install.sh uninstall    stop + remove
#
# The binary is wrapped in a minimal signed .app bundle with a fixed bundle
# identifier: TCC ties the Screen Recording grant to "identifier + team", so
# the permission survives rebuilds. A bare ad-hoc binary re-prompts on every
# rebuild because its only identity is its own hash.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.michelg10.CodeSaver.Igniter
LOG_DIR="$HOME/Library/Logs/CodeSaver"
APP_DIR="$HOME/Library/Application Support/CodeSaver/CodeSaverIgniter.app"
BIN="$APP_DIR/Contents/MacOS/codesaver-igniter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

if [[ ${1:-} == uninstall ]]; then
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP_DIR"
  echo "── igniter removed"
  exit 0
fi

[[ -f build/codesaver-igniter ]] || { echo "run ./build.sh first"; exit 1 }

# Signing identity: same detection as appex/install.sh. A real certificate
# gives TCC a stable designated requirement; ad-hoc falls back to per-build
# identity (the permission will re-prompt after rebuilds).
SIGN_ID="${SIGN_ID:-Apple Development}"
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "── warning: no '$SIGN_ID' certificate — ad-hoc signing (TCC grant won't survive rebuilds)"
  SIGN_ID="-"
fi

# Not loaded yet (first install) is the normal failure here; keep its message
# in case the job is genuinely stuck instead.
BOOTOUT_ERR=$(launchctl bootout "gui/$UID_NUM/$LABEL" 2>&1 >/dev/null || true)
# launchd tears the old instance down asynchronously; bootstrapping while
# that is still in flight fails with "Bootstrap failed: 5: Input/output
# error" and leaves NO igniter running (the only saver trigger). Wait it out
# — past launchd's default 20 s ExitTimeOut — and refuse to go on while the
# old job is still loaded: every bootstrap below would fail, yet `launchctl
# print` would still answer for the OLD instance and read as success.
OLD_GONE=0
for _ in {1..50}; do
  launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || { OLD_GONE=1; break }
  sleep 0.5
done
if (( ! OLD_GONE )); then
  echo "── the previous igniter is still loaded after 25 s; not replacing it"
  [[ -n $BOOTOUT_ERR ]] && echo "   launchctl bootout: $BOOTOUT_ERR"
  echo "   stop it, then re-run:  launchctl bootout gui/$UID_NUM/$LABEL"
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$LOG_DIR"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleName</key><string>CodeSaver Igniter</string>
    <key>CFBundleExecutable</key><string>codesaver-igniter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
cp build/codesaver-igniter "$BIN"
codesign --force --sign "$SIGN_ID" --identifier "$LABEL" "$APP_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/igniter.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/igniter.log</string>
</dict>
</plist>
PLIST

# Success means OUR bootstrap was accepted — not merely that some job with
# this label is loaded (see the wait above). Keep the last error to show.
BOOTSTRAPPED=0
BOOTSTRAP_ERR=""
for attempt in {1..5}; do
  if BOOTSTRAP_ERR=$(launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>&1); then
    BOOTSTRAPPED=1
    break
  fi
  sleep 1
done
if (( ! BOOTSTRAPPED )); then
  echo "── igniter did NOT start: ${BOOTSTRAP_ERR:-bootstrap failed}"
  echo "   re-run:  launchctl bootstrap gui/$UID_NUM $PLIST"
  exit 1
fi
launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 \
  || { echo "── igniter bootstrapped but is not loaded: launchctl bootstrap gui/$UID_NUM $PLIST"; exit 1 }

echo "── igniter installed and running (signed: $SIGN_ID)"
echo "   launch decisions + capture failures: $LOG_DIR/igniter.log"
echo
echo "   macOS is the trigger: set System Settings → Lock Screen →"
echo "   'Start Screen Saver when inactive' to taste, and/or a hot corner."
echo "   Idle triggers play a 5s pre-animation; hot corners detonate at once."
echo "   Grant 'CodeSaver Igniter' Screen Recording permission when prompted —"
echo "   with a real signing certificate that grant now survives rebuilds."
echo "   Capture happens after this much idle (default 20s):"
echo "     defaults write $LABEL captureAfterIdle -float 20"
