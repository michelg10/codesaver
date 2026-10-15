#!/bin/zsh
# Build CodeSaver.app (+ embedded CodeSaverExtension.appex) from source and
# install it to /Applications, registering the screen saver with pluginkit.
# For people building from source — everyone else downloads the notarized
# app from codesaver.michelg10.com. The code corpus is never baked at build
# time: the installed app fetches it from GitHub into the app-group container
# (connect GitHub once in the app).
#
# Needs: Xcode 26 or later (the PaperSaver package needs Swift tools 6.2), an
# "Apple Development" signing certificate (a free Apple ID works), and an
# account that can write to /Applications.
#
# Environment:
#   NO_ACTIVATE=1  On an upgrade, leave the screen saver selection alone. It is
#                  still re-selected when CodeSaver already WAS the active
#                  saver — replacing the bundle leaves macOS bound to the old
#                  copy, which starts black. Without it, an upgrade also makes
#                  CodeSaver the active saver. A first install never selects
#                  it either way: that's the app's “Enable” button.
#   SIGN_ID=…      Signing identity (SHA-1 or name). Default: the first valid
#                  “Apple Development” identity in your keychain.
#   TEAM_ID=…      Development team. Default: read from that certificate.
set -euo pipefail
cd "$(dirname "$0")"

die() { print -r -- "!! $*" >&2; exit 1 }

APP_DEST=/Applications/CodeSaver.app
APPEX_DEST=$APP_DEST/Contents/PlugIns/CodeSaverExtension.appex
WALLPAPER_INDEX="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

# ── preflight — say plainly what's missing, before a build fails opaquely.
command -v xcodebuild >/dev/null 2>&1 \
  || die "Xcode isn't installed. Install Xcode 26 or later from the App Store, open it once, then run this again."
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2; exit}' || true)"
[[ -n $XCODE_VERSION ]] \
  || die "xcodebuild is pointing at the Command Line Tools, not Xcode. Install Xcode 26 or later, then run:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
[[ $XCODE_VERSION == <->* && ${XCODE_VERSION%%.*} -ge 26 ]] \
  || die "Xcode $XCODE_VERSION is too old: CodeSaver needs Xcode 26 or later (its PaperSaver package uses Swift tools 6.2). Update Xcode, then run this again."
[[ -w /Applications ]] \
  || die "this account can't write to /Applications. Run this from an administrator account."
[[ ! -e $APP_DEST || -w $APP_DEST ]] \
  || die "$APP_DEST belongs to another account. Delete it (or run this as its owner), then run this again."

# Signing: the first VALID "Apple Development" identity — `-v` drops expired
# and revoked ones, which a name lookup alone happily picks and codesign then
# rejects. Signing by SHA-1 keeps two same-named certificates unambiguous.
if [[ -z ${SIGN_ID:-} ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' || true)"
  SIGN_ID="$(print -r -- "$IDENTITY" | awk '{print $2}')"
  SIGN_NAME="$(print -r -- "$IDENTITY" | sed -n 's/.*"\(.*\)".*/\1/p')"
fi
[[ -n ${SIGN_ID:-} ]] || die "no valid “Apple Development” signing certificate. Create one — a free Apple ID works:
   Xcode → Settings → Accounts → add your Apple ID → Manage Certificates… → + → Apple Development
   then run this again."

# Team ID = the certificate subject's OU (the parenthetical in its name is NOT
# the team). The `|| true`s matter: without them pipefail+errexit kills the
# script silently, before the friendly error below.
signing_cert() {
  if [[ ${#1} -eq 40 && $1 != *[^0-9A-Fa-f]* ]]; then
    security find-certificate -a -Z -p 2>/dev/null | awk -v h="${1:u}" '
      /^SHA-1 hash:/ { on = (toupper($3) == h); next }
      on { print; if (/-----END CERTIFICATE-----/) exit }' || true
  else
    security find-certificate -c "$1" -p 2>/dev/null || true
  fi
}
TEAM_ID="${TEAM_ID:-$(signing_cert "$SIGN_ID" \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)}"
[[ -n $TEAM_ID ]] || die "couldn't read the team ID from the “${SIGN_NAME:-$SIGN_ID}” certificate. Set it yourself:  TEAM_ID=XXXXXXXXXX ./appex/install.sh"

echo "── building with Xcode $XCODE_VERSION, signing as “${SIGN_NAME:-$SIGN_ID}” (team $TEAM_ID)…"
mkdir -p build
LOG=build/xcodebuild.log
# Build number = install timestamp (overrides BuildNumber.xcconfig without
# touching the tracked file), so "which build is installed?" has an answer.
BUILD_NUM="$(date +%y%m%d.%H%M)"
if ! xcodebuild -project CodeSaver.xcodeproj -scheme CodeSaver -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    build >"$LOG" 2>&1; then
  echo "!! build failed:" >&2
  # The error lines themselves, de-duplicated in order — the log's tail is
  # just xcodebuild's summary of which step failed, not why.
  ERRORS="$(grep -E '(error|fatal error): |^xcodebuild: error|^error: |Signing for .* requires|No signing certificate' "$LOG" \
    | awk '!seen[$0]++' | head -40 || true)"
  if [[ -n $ERRORS ]]; then print -r -- "$ERRORS" >&2; else tail -20 "$LOG" >&2; fi
  die "full log: appex/$LOG"
fi
echo "── built"

APP=build/Build/Products/Release/CodeSaver.app
[[ -d $APP ]] || die "build product missing ($APP)"

# Ask BEFORE replacing anything whether CodeSaver is the selected saver: once
# the bundle is swapped the store's binding is stale, and that question has no
# reliable answer. The new build answers (it reads the store, selects nothing);
# if it can't run at all, look for our module in the store directly.
UPGRADE=0
[[ -d $APP_DEST ]] && UPGRADE=1
WAS_ACTIVE=0
ACTIVE_RC=0
"$APP/Contents/MacOS/CodeSaver" --saver-active >/dev/null 2>&1 || ACTIVE_RC=$?
if (( ACTIVE_RC == 0 )); then
  WAS_ACTIVE=1
elif (( ACTIVE_RC != 1 )) && grep -qa 'CodeSaverExtension.appex' "$WALLPAPER_INDEX" 2>/dev/null; then
  WAS_ACTIVE=1
fi

# Migrate away from the legacy .saver — but only if it IS CodeSaver's: the
# name alone could be anyone's.
LEGACY="$HOME/Library/Screen Savers/CodeSaver.saver"
if [[ -d $LEGACY ]]; then
  LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY/Contents/Info.plist" 2>/dev/null || true)"
  if [[ ${LEGACY_ID:l} == com.michelg10.codesaver ]]; then
    rm -rf "$LEGACY"
    echo "── removed the legacy CodeSaver.saver"
  else
    echo "── left $LEGACY alone (bundle id “$LEGACY_ID” isn't CodeSaver's)"
  fi
fi

# Replace any previous install, then register. One location only (/Applications):
# pluginkit caches discovery paths and prefers /Applications, so never register
# the DerivedData copy. Stage first so a failed copy can't destroy a working
# install.
STAGING="/Applications/.CodeSaver.staging.app"
rm -rf "$STAGING"
ditto "$APP" "$STAGING"
if [[ -d $APP_DEST ]]; then
  pluginkit -r "$APPEX_DEST" 2>/dev/null || true
  rm -rf "$APP_DEST"
fi
mv "$STAGING" "$APP_DEST"
pluginkit -a "$APPEX_DEST" \
  || echo "── pluginkit registration failed (macOS's /Applications scan usually picks it up anyway)"

# macOS auto-scans the DerivedData build folder and re-registers the freshly
# built appex there, clobbering the /Applications registration (the "pick ONE
# location" trap from AppexSaverMinimal's README). Unregister and delete the
# build copy so it can never win.
pluginkit -r "$APP/Contents/PlugIns/CodeSaverExtension.appex" 2>/dev/null || true
rm -rf "$APP" "$(dirname "$APP")/CodeSaverExtension.appex"

# Selecting the saver. --activate is the app's Enable button: it waits (up to
# ~15 s, re-adding each round) for pluginkit to list the /Applications copy —
# activating before that binds the selection to nothing, a pure-black saver —
# then selects, reads the selection back, and retries. A failure is reported
# at the very end, after the agents below are registered: an early exit here
# used to leave a half-installed app.
ACTIVATE=0
if (( WAS_ACTIVE )); then
  ACTIVATE=1
elif [[ ${NO_ACTIVATE:-0} != 1 ]] && (( UPGRADE )); then
  ACTIVATE=1
fi
ACTIVATION_FAILED=0
if (( ACTIVATE )); then
  if "$APP_DEST/Contents/MacOS/CodeSaver" --activate; then
    echo "── CodeSaver is the active screen saver"
  else
    ACTIVATION_FAILED=1
  fi
elif (( UPGRADE )); then
  echo "── left the screen saver selection alone (NO_ACTIVATE=1 and CodeSaver wasn't active)"
else
  echo "── first install: open CodeSaver and click “Enable” to make it your screen saver"
fi

# (Re-)register the corpus refresh LaunchAgent now that the app sits at its
# stable /Applications path — when it's already on, or a GitHub token makes it
# useful; a fresh install with neither gets no agent (and no "Background Items
# Added" notice) until the app's Auto-refresh switch. RunAtLoad gives a first
# corpus fetch right away. The widget feeds agent is opt-in (the app's "Live
# widgets" switch): re-registered only if it was already on.
"$APP_DEST/Contents/MacOS/CodeSaver" --register-agent 2>/dev/null \
  || echo "── agent registration failed — toggle “Auto-refresh” in the app"

# The feeds daemon is KeepAlive: it survived the bundle swap above on the
# unlinked inode, and re-registering an already-enabled agent never re-execs
# it — nor does it reload the plist, so a changed ProcessType would never
# take effect. Unregister + register loads the bundle's current plist and
# starts the daemon on the new build; the kickstart is the fallback for a
# job that was left loaded but not running. Both only when the agent is on:
# --reregister-feeds exits 0 without registering for a user who never
# switched Live widgets on, and the launchctl checks then find no job.
# (The refresh agent needs none: StartInterval re-execs it every hour.)
FEEDS_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' \
  CodeSaver/com.michelg10.CodeSaver.feeds.plist 2>/dev/null || echo com.michelg10.CodeSaver.feeds)"
if "$APP_DEST/Contents/MacOS/CodeSaver" --reregister-feeds 2>/dev/null; then
  echo "── feeds daemon re-registered from the bundle's plist"
fi
sleep 1
# Captured, not piped into grep -q: under pipefail an early-exiting grep can
# SIGPIPE launchctl and turn a running daemon into a "not running" verdict.
FEEDS_STATE="$(launchctl print "gui/$(id -u)/$FEEDS_LABEL" 2>/dev/null || true)"
if [[ $FEEDS_STATE == *"state = running"* ]]; then
  echo "── feeds daemon running on the new build"
elif launchctl kickstart -k "gui/$(id -u)/$FEEDS_LABEL" 2>/dev/null; then
  echo "── restarted the feeds daemon on the new build"
else
  echo "── feeds daemon off (opt in with “Live widgets” in the app)"
fi

# The embedded igniter: cycled onto the new build when Ignition is on (a
# KeepAlive agent otherwise keeps running the replaced binary), and a
# standalone igniter from helper/install.sh is retired on the way. Off: a
# no-op — a reinstall never switches ignition on.
if IGNITER_OUT="$("$APP_DEST/Contents/MacOS/CodeSaver" --reregister-igniter 2>/dev/null)"; then
  [[ $IGNITER_OUT == *enabled* ]] && echo "── igniter re-registered on the new build"
else
  echo "── igniter re-registration failed — toggle Ignition off and on in the app"
fi

echo "── installed $APP_DEST"
PK_LINE="$(pluginkit -m -v -i com.michelg10.CodeSaver.Extension 2>/dev/null || true)"
if [[ $PK_LINE == *"$APP_DEST"* ]]; then
  print -r -- "   ${PK_LINE%%$'\n'*}"
else
  echo "   (not yet visible to pluginkit — System Settings usually picks it up shortly)"
fi

if (( ACTIVATION_FAILED )); then
  # Loud, and fatal: an unbound selection means macOS quietly shows one of
  # its own savers instead — or a black screen. Not a warning to scroll past.
  echo "!! AUTO-ACTIVATION FAILED — the screen saver selection still points at the replaced copy."
  echo "!! Open CodeSaver and click “Enable” next to Screensaver,"
  echo "!! or pick CodeSaver in System Settings → Screen Saver,"
  echo "!! or run: $APP_DEST/Contents/MacOS/CodeSaver --activate"
  exit 1
fi

# The app repairs a new build on its first launch (re-register, re-select,
# cycle the agents — SelfRepair.swift); this script just did all of that, so
# mark the build done and spare the next window open a second WallpaperAgent
# restart.
INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DEST/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n $INSTALLED_BUILD ]]; then
  defaults write com.michelg10.CodeSaver LastRunBuild -string "$INSTALLED_BUILD"
fi
