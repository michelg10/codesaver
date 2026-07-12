#!/bin/zsh
# Build CodeSaver.app (+ embedded CodeSaverExtension.appex) and install to
# /Applications, registering the appex with pluginkit.
#
#   ./install.sh                  build + install
#   REFRESH_CORPUS=1 ./install.sh   also resample code from your repos
set -euo pipefail
cd "$(dirname "$0")"

[[ -f ../setup.conf ]] && source ../setup.conf
SIGN_ID="${SIGN_ID:-Apple Development}"
# Team ID: setup.conf/env, else detect from the signing certificate. The
# `|| true` matters: without it, pipefail+errexit silently kills the script
# on machines with no certificate — before the friendly error below.
TEAM_ID="${TEAM_ID:-$(security find-certificate -c "$SIGN_ID" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)}"
[[ -n $TEAM_ID ]] || { echo "no signing team — run ../setup.sh first"; exit 1; }

# Refresh verbs from the user's own list when configured; otherwise the
# bundled Resources copy is used as-is. Content-gated so identical lists
# never touch (or dirty) the tracked file.
if [[ -n ${VERBS:-} && -f ${VERBS:-} ]] && ! cmp -s "$VERBS" CodeSaverExtension/Resources/spinner-verbs.txt; then
  cp "$VERBS" CodeSaverExtension/Resources/spinner-verbs.txt
fi

if [[ ! -f CodeSaverExtension/Resources/corpus.bin || ! -f CodeSaverExtension/Resources/corpus-index.json || ${REFRESH_CORPUS:-0} == 1 ]]; then
  echo "── regenerating corpus…"
  python3 ../make_corpus.py CodeSaverExtension/Resources/corpus.bin
fi

echo "── building…"
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
if [[ ${NO_ACTIVATE:-0} != 1 ]]; then
  /Applications/CodeSaver.app/Contents/MacOS/CodeSaver --activate 2>/dev/null \
    && echo "── re-activated as the current screensaver" \
    || echo "── auto-activation failed — click “Enable as Screensaver” in the app"
fi

echo "── installed /Applications/CodeSaver.app"
pluginkit -m -v -p com.apple.screensaver 2>/dev/null | grep -i codesaver || echo "   (not yet visible to pluginkit — System Settings usually picks it up shortly)"
echo "   Pick “CodeSaver” in System Settings → Screen Saver."
