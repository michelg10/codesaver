#!/bin/zsh
# Build CodeSaver.app (+ embedded CodeSaverExtension.appex) and install to
# /Applications, registering the appex with pluginkit. The code corpus is no
# longer baked at build time — the installed app fetches it from GitHub into
# the app-group container (connect GitHub once in the app).
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:-Apple Development}"
# Team ID: env override, else detect from the signing certificate. The
# `|| true` matters: without it, pipefail+errexit silently kills the script
# on machines with no certificate — before the friendly error below.
TEAM_ID="${TEAM_ID:-$(security find-certificate -c "$SIGN_ID" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)}"
[[ -n $TEAM_ID ]] || { echo "no signing team — need an 'Apple Development' certificate (a free Apple ID via Xcode → Settings → Accounts works)"; exit 1; }

echo "── building…"
mkdir -p build  # tee opens its log before xcodebuild creates the directory
# Build number = install timestamp (overrides BuildNumber.xcconfig without
# touching the tracked file), so "which build is installed?" has an answer.
BUILD_NUM="$(date +%y%m%d.%H%M)"
xcodebuild -project CodeSaver.xcodeproj -scheme CodeSaver -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  build 2>&1 | tee build/xcodebuild.log | tail -3 \
  || { echo "build failed — full log: appex/build/xcodebuild.log"; exit 1; }

APP=build/Build/Products/Release/CodeSaver.app
[[ -d $APP ]] || { echo "build product missing"; exit 1; }

# Migrate away from the legacy .saver if it's still installed.
rm -rf "$HOME/Library/Screen Savers/CodeSaver.saver"

# Replace any previous install, then register. One location only (/Applications):
# pluginkit caches discovery paths and prefers /Applications, so never register
# the DerivedData copy. Stage first so a failed copy can't destroy a working
# install.
STAGING="/Applications/.CodeSaver.staging.app"
rm -rf "$STAGING"
ditto "$APP" "$STAGING"
if [[ -d /Applications/CodeSaver.app ]]; then
  pluginkit -r /Applications/CodeSaver.app/Contents/PlugIns/CodeSaverExtension.appex 2>/dev/null || true
  rm -rf /Applications/CodeSaver.app
fi
mv "$STAGING" /Applications/CodeSaver.app
pluginkit -a /Applications/CodeSaver.app/Contents/PlugIns/CodeSaverExtension.appex \
  || echo "── pluginkit registration failed (macOS's /Applications scan usually picks it up anyway)"

# macOS auto-scans the DerivedData build folder and re-registers the freshly
# built appex there, clobbering the /Applications registration (the "pick ONE
# location" trap from AppexSaverMinimal's README). Unregister and delete the
# build copy so it can never win.
pluginkit -r "$APP/Contents/PlugIns/CodeSaverExtension.appex" 2>/dev/null || true
rm -rf "$APP" "$(dirname "$APP")/CodeSaverExtension.appex"

# Reinstalling breaks the active screen-saver selection (the wallpaper store's
# binding goes stale with the new bundle), so re-activate unless told not to.
# Activation races pluginkit registration right after install — an unbound
# selection makes the saver launch as pure black — so retry with the
# registration nudged in between.
if [[ ${NO_ACTIVATE:-0} != 1 ]]; then
  ACTIVATED=0
  for attempt in 1 2 3; do
    if /Applications/CodeSaver.app/Contents/MacOS/CodeSaver --activate 2>/dev/null; then
      ACTIVATED=1
      break
    fi
    pluginkit -a /Applications/CodeSaver.app/Contents/PlugIns/CodeSaverExtension.appex 2>/dev/null || true
    sleep 2
  done
  if [[ $ACTIVATED == 1 ]]; then
    echo "── re-activated as the current screensaver"
  else
    echo "── auto-activation failed — click “Enable as Screensaver” in the app"
    echo "   (until then the system saver selection is unbound and shows BLACK)"
  fi
fi

# (Re-)register the LaunchAgents (corpus refresh + widget feeds) now that the
# app sits at its stable /Applications path; a no-op when already enabled.
# RunAtLoad gives a first corpus fetch right away once a token is present.
/Applications/CodeSaver.app/Contents/MacOS/CodeSaver --register-agent 2>/dev/null \
  || echo "── agent registration failed — toggle “Refresh automatically” in the app"

# The feeds daemon is KeepAlive: it survived the bundle swap above on the
# unlinked inode, and re-registering an already-enabled agent never re-execs
# it — nor does it reload the plist, so a changed ProcessType would never
# take effect. Unregister + register loads the bundle's current plist and
# starts the daemon on the new build; the kickstart is the fallback for a
# job that was left loaded but not running.
# (The refresh agent needs none: StartInterval re-execs it every hour.)
FEEDS_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' \
  CodeSaver/com.michelg10.CodeSaver.feeds.plist 2>/dev/null || echo com.michelg10.CodeSaver.feeds)"
if /Applications/CodeSaver.app/Contents/MacOS/CodeSaver --reregister-feeds 2>/dev/null; then
  echo "── feeds daemon re-registered from the bundle's plist"
fi
sleep 1
if launchctl print "gui/$(id -u)/$FEEDS_LABEL" 2>/dev/null | grep -q "state = running"; then
  echo "── feeds daemon running on the new build"
elif launchctl kickstart -k "gui/$(id -u)/$FEEDS_LABEL" 2>/dev/null; then
  echo "── restarted the feeds daemon on the new build"
else
  echo "── feeds daemon not loaded yet (it starts with “Refresh automatically” / next login)"
fi

echo "── installed /Applications/CodeSaver.app"
pluginkit -m -v -p com.apple.screensaver 2>/dev/null | grep -i codesaver || echo "   (not yet visible to pluginkit — System Settings usually picks it up shortly)"
echo "   Pick “CodeSaver” in System Settings → Screen Saver."
