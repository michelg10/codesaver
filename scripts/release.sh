#!/bin/zsh
# Build the public CodeSaver.dmg: archive, Developer ID export, notarize and
# staple the app, wrap it in a signed + notarized + stapled disk image, and
# check both with Gatekeeper. Publishing stays a manual step — the script
# prints the `gh release create` line, it never runs it.
#
#   scripts/release.sh            → build/release/CodeSaver.dmg
#                                   build/release/CodeSaver-<version>-dSYMs.zip
#
# The version is MARKETING_VERSION in appex/BuildNumber.xcconfig; the build
# number is a timestamp, as install.sh stamps one.
#
# One-time setup on the Mac that releases:
#   1. A "Developer ID Application" certificate with its private key in the
#      login keychain (Xcode → Settings → Accounts → Manage Certificates → +,
#      as the team's Account Holder).
#   2. Notary credentials in the keychain under a profile name:
#        xcrun notarytool store-credentials codesaver --apple-id <apple-id> --team-id <team-id>
#      (it asks for an app-specific password, made at account.apple.com).
#      NOTARY_PROFILE picks another profile name; TEAM_ID picks a team when
#      the keychain holds Developer ID identities for more than one.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-codesaver}"
OUT=build/release
DD=$OUT/DerivedData
ARCHIVE=$OUT/CodeSaver.xcarchive
EXPORT=$OUT/export
STAGE=$OUT/dmg
LOGS=$OUT/logs
NOTARY_ZIP=$OUT/CodeSaver-notarize.zip
DMG=$OUT/CodeSaver.dmg
APP=$EXPORT/CodeSaver.app

# Strings found only in the personal code behind HOME_CONTROL and
# LEGACY_SPOOLS (see appex/Local.xcconfig.example): none may reach a
# release. Swift keeps a literal of 15 bytes or fewer inside the
# instructions rather than as a string, so ".bifrocate/cot" never shows up
# to grep even when compiled in; CODESAVER_SPOOL_DIR, its neighbour in the
# same declaration, does.
PERSONAL_MARKERS=(michelg10.com/v1/home .bifrocate CODESAVER_SPOOL_DIR)

# --- preflight ---------------------------------------------------------------
# Every check runs before anything is built, and every failure names its fix.
FAILED=()
fail() { FAILED+=("$1"); }
warn() { echo "── warning: $1"; }

XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p' || true)"
if [[ -z $XCODE_MAJOR ]] || (( XCODE_MAJOR < 26 )); then
  fail "Xcode 26 or newer is required (found: ${XCODE_MAJOR:-none}) — fix: install it, then sudo xcode-select -s /Applications/Xcode.app"
fi

VERSION="$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' appex/BuildNumber.xcconfig | tail -1)"
if [[ ! $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  fail "no x.y.z MARKETING_VERSION in appex/BuildNumber.xcconfig (found: ${VERSION:-none}) — fix: set e.g. MARKETING_VERSION = 1.0.0 there"
fi

# The identity, by name and by hash, and its team (the 10 characters in
# parentheses). `security find-identity -v` lists only identities whose
# certificate is valid and whose private key is present.
SIGN_NAME="" SIGN_HASH=""
for line in ${(f)"$(security find-identity -v -p codesigning 2>/dev/null || true)"}; do
  if [[ $line =~ '^ *[0-9]+\) ([0-9A-F]{40}) "(Developer ID Application: .*\(([A-Z0-9]{10})\))"$' ]] \
     && [[ -z ${TEAM_ID:-} || $match[3] == $TEAM_ID ]]; then
    SIGN_HASH=$match[1] SIGN_NAME=$match[2] TEAM_ID=$match[3]
    break
  fi
done
if [[ -z $SIGN_NAME ]]; then
  fail "no valid \"Developer ID Application\" identity${TEAM_ID:+ for team $TEAM_ID} in the keychain — fix: create one in Xcode → Settings → Accounts → Manage Certificates → + (Account Holder only)"
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  fail "notarytool can't use the keychain profile \"$PROFILE\" — fix: xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id ${TEAM_ID:-<team-id>}"
fi

if (( $#FAILED )); then
  for f in $FAILED; do echo "!! $f"; done
  exit 1
fi

# A tree with changes builds a release no commit describes. (The build
# number stamp lives in the gitignored BuildStamp.xcconfig, so a build alone
# leaves the tree clean.)
CHANGES="$(git status --porcelain 2>/dev/null || true)"
[[ -z $CHANGES ]] || warn "the git tree has uncommitted changes, so this release matches no commit (commit first to fix; carrying on)"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  warn "v$VERSION is already tagged — bump MARKETING_VERSION in appex/BuildNumber.xcconfig to fix (carrying on)"
fi
[[ ! -f appex/Local.xcconfig ]] || warn "appex/Local.xcconfig exists — the release blanks its compilation conditions, but any other setting in it still applies"

# --- clean slate, and a trap that keeps it clean -------------------------------
# Every CodeSaver.app this script makes — DerivedData's, the archive's, the
# export, the disk image's staging copy — carries an appex macOS registers
# the moment it sees one on disk, and that registration clobbers the one in
# /Applications. Unregister and delete them all on the way out, success or
# not; only the disk image and the dSYMs stay (and the logs, after a failure).
cleanup() {
  local code=$1 a
  for a in $OUT/**/*.appex(N/); do
    pluginkit -r "${a:A}" 2>/dev/null || true
  done
  rm -rf $DD $ARCHIVE $EXPORT $STAGE $NOTARY_ZIP $OUT/ExportOptions.plist
  if (( code == 0 )); then
    rm -rf $LOGS
  else
    rm -f $DMG
    [[ ! -d $LOGS ]] || echo "── logs kept in $LOGS"
  fi
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM
cleanup 0
rm -f $DMG $OUT/CodeSaver-*-dSYMs.zip(N)
mkdir -p $LOGS

COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_NUM="$(date +%y%m%d.%H%M)"
echo "── CodeSaver $VERSION ($BUILD_NUM), signed as $SIGN_NAME"

# --- archive -------------------------------------------------------------------
# SWIFT_ACTIVE_COMPILATION_CONDITIONS is blanked on the command line, where it
# outranks every xcconfig: Local.xcconfig's HOME_CONTROL / LEGACY_SPOOLS can
# never reach a release. (It reaches the package targets too; PaperSaverKit
# has no #if of its own.) MARKETING_VERSION is passed again for the same
# reason: the tag, the plist and the disk image must agree. No base
# entitlements: Xcode would otherwise inject get-task-allow, which
# notarization refuses.
echo "── archiving…"
xcodebuild archive -project appex/CodeSaver.xcodeproj -scheme CodeSaver -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $DD -archivePath $ARCHIVE \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_NAME" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  2>&1 | tee $LOGS/archive.log | tail -3 \
  || { echo "archive failed — full log: $LOGS/archive.log"; exit 1; }

# --- export --------------------------------------------------------------------
echo "── exporting for Developer ID…"
cp scripts/ExportOptions.plist $OUT/ExportOptions.plist
plutil -replace teamID -string "$TEAM_ID" $OUT/ExportOptions.plist
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT \
  -exportOptionsPlist $OUT/ExportOptions.plist \
  2>&1 | tee $LOGS/export.log | tail -3 \
  || { echo "export failed — full log: $LOGS/export.log"; exit 1; }
[[ -d $APP ]] || { echo "export made no $APP"; exit 1; }

# --- verify --------------------------------------------------------------------
# Every Mach-O in the bundle, found by walking it — the app, the saver, any
# helper app under Contents/Library and whatever else gets embedded later —
# not by a list that would go stale.
echo "── verifying…"
codesign --verify --deep --strict "$APP" 2>$LOGS/verify.log \
  || { echo "codesign --verify --deep --strict fails on the app: $(tail -1 $LOGS/verify.log)"; exit 1; }
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - $APP/Contents/Info.plist 2>/dev/null || true)"
[[ $BUILT_VERSION == $VERSION ]] || { echo "the app says version ${BUILT_VERSION:-none}, not $VERSION"; exit 1; }

MACHOS=()
for f in $APP/**/*(.DN); do
  [[ "$(file -b "$f")" != Mach-O* ]] || MACHOS+=("$f")
done
(( $#MACHOS )) || { echo "no Mach-O found in $APP"; exit 1; }
PROBLEMS=()
for m in $MACHOS; do
  rel=${m#$EXPORT/}
  if ! codesign --verify --strict "$m" 2>/dev/null; then PROBLEMS+=("$rel: fails codesign --verify --strict"); fi
  info="$(codesign -dvvv "$m" 2>&1 || true)"
  if [[ ! $info =~ 'flags=0x[0-9a-f]+\([^)]*runtime' ]]; then PROBLEMS+=("$rel: no hardened runtime"); fi
  if [[ $info != *$'\n'Timestamp=* ]]; then PROBLEMS+=("$rel: no secure timestamp"); fi
  ents="$(codesign -d --entitlements - --xml "$m" 2>/dev/null || true)"
  if [[ $ents == *get-task-allow* ]]; then PROBLEMS+=("$rel: has get-task-allow"); fi
  archs=(${=$(lipo -archs "$m" 2>/dev/null || true)})
  if (( ! ${archs[(Ie)arm64]} || ! ${archs[(Ie)x86_64]} )); then
    PROBLEMS+=("$rel: not universal (${archs:-no architectures})")
  fi
  for s in $PERSONAL_MARKERS; do
    if LC_ALL=C grep -aqF -- "$s" "$m"; then PROBLEMS+=("$rel: contains \"$s\""); fi
  done
done
if (( $#PROBLEMS )); then
  for p in $PROBLEMS; do echo "!! $p"; done
  exit 1
fi
echo "   $#MACHOS Mach-O files: signed, hardened, timestamped, universal, nothing personal"

# --- notarize the app ----------------------------------------------------------
# Judged by the status in notarytool's JSON, not by its exit code: --wait
# says the submission finished, not that it passed.
notarize() {
  local result verdict id
  echo "── notarizing ${1:t} (this takes a few minutes)…"
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json \
            2>>$LOGS/notary.log || true)"
  verdict="$(print -r -- "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
  id="$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
  if [[ $verdict != Accepted ]]; then
    echo "notarization of ${1:t}: ${verdict:-no answer} — ${result:-see $LOGS/notary.log}"
    [[ -z $id ]] || echo "   why: xcrun notarytool log $id --keychain-profile $PROFILE"
    exit 1
  fi
}
ditto -c -k --keepParent $APP $NOTARY_ZIP
notarize $NOTARY_ZIP
xcrun stapler staple -q $APP || { echo "stapling the app failed"; exit 1; }

# --- disk image ----------------------------------------------------------------
# The app inside is already stapled, so it opens offline once copied out.
echo "── building the disk image…"
mkdir -p $STAGE
ditto $APP $STAGE/CodeSaver.app
ln -s /Applications $STAGE/Applications
hdiutil create -volname CodeSaver -srcfolder $STAGE -fs HFS+ -format UDZO -ov $DMG \
  >$LOGS/hdiutil.log 2>&1 || { echo "hdiutil failed — full log: $LOGS/hdiutil.log"; exit 1; }
codesign --sign "$SIGN_HASH" --timestamp $DMG || { echo "signing the disk image failed"; exit 1; }
notarize $DMG
xcrun stapler staple -q $DMG || { echo "stapling the disk image failed"; exit 1; }

# --- Gatekeeper ----------------------------------------------------------------
# What a downloaded copy meets: the app as launched, the image as opened.
echo "── asking Gatekeeper…"
spctl -a -vv $APP 2>&1 | sed 's/^/   app: /' \
  || { echo "Gatekeeper rejects the app"; exit 1; }
spctl -a -vv -t open --context context:primary-signature $DMG 2>&1 | sed 's/^/   dmg: /' \
  || { echo "Gatekeeper rejects the disk image"; exit 1; }

# --- done ----------------------------------------------------------------------
# The dSYMs symbolicate a crash report from this build; the archive holding
# them goes with the cleanup. Missing ones cost a warning, not the release.
ditto -c -k --keepParent $ARCHIVE/dSYMs $OUT/CodeSaver-$VERSION-dSYMs.zip 2>/dev/null \
  || warn "the archive has no dSYMs to keep"
echo "── built $DMG  (dSYMs: $OUT/CodeSaver-$VERSION-dSYMs.zip)"
shasum -a 256 $DMG
echo "── to publish, push $COMMIT, then run:"
echo "   gh release create v$VERSION $DMG --repo michelg10/codesaver --target $COMMIT --title \"CodeSaver $VERSION\" --generate-notes"
