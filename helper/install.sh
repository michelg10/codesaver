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
[[ -f setup.conf ]] && source setup.conf
SIGN_ID="${SIGN_ID:-Apple Development}"
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "── warning: no '$SIGN_ID' certificate — ad-hoc signing (TCC grant won't survive rebuilds)"
  SIGN_ID="-"
fi

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

mkdir -p "$APP_DIR/Contents/MacOS"
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
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "── igniter installed and running (signed: $SIGN_ID)"
echo
echo "   macOS is the trigger: set System Settings → Lock Screen →"
echo "   'Start Screen Saver when inactive' to taste, and/or a hot corner."
echo "   Idle triggers play a 5s pre-animation; hot corners detonate at once."
echo "   Grant 'CodeSaver Igniter' Screen Recording permission when prompted —"
echo "   with a real signing certificate that grant now survives rebuilds."
echo "   Capture happens after this much idle (default 20s):"
echo "     defaults write $LABEL captureAfterIdle -float 20"
