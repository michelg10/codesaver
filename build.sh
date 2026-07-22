#!/bin/zsh
# Build CodeSaver.saver (universal) + preview harness. Usage:
#   ./build.sh            build everything
#   ./build.sh install    build + install to ~/Library/Screen Savers
set -euo pipefail
cd "$(dirname "$0")"

SRC=(appex/CodeSaverExtension/CodeSaverView.swift appex/CodeSaver/Helpers/Logger.swift)
BUILD=build
BUNDLE=$BUILD/CodeSaver.saver
SDK=$(xcrun --show-sdk-path)
# User's own verbs list from setup.conf when configured; else the bundled copy.
[[ -f setup.conf ]] && source setup.conf
[[ -n ${VERBS:-} && -f ${VERBS:-} ]] || VERBS=appex/CodeSaverExtension/Resources/spinner-verbs.txt

mkdir -p "$BUILD"

# --- Resources -------------------------------------------------------------
if [[ ! -f $BUILD/corpus.bin || ! -f $BUILD/corpus-index.json || ${REFRESH_CORPUS:-0} == 1 ]]; then
  echo "── generating corpus from owned repos…"
  python3 make_corpus.py "$BUILD/corpus.bin"
fi

# --- Compile + link the .saver bundle binary (arm64 + x86_64) ---------------
echo "── compiling saver…"
for ARCH in arm64 x86_64; do
  swiftc -O -wmo -parse-as-library -module-name CodeSaver \
    -target "$ARCH-apple-macos13.0" -sdk "$SDK" \
    -c "${SRC[@]}" -o "$BUILD/CodeSaverView-$ARCH.o"
  xcrun clang -bundle -target "$ARCH-apple-macos13.0" -isysroot "$SDK" \
    "$BUILD/CodeSaverView-$ARCH.o" \
    -framework ScreenSaver -framework AppKit -framework QuartzCore \
    -L "$SDK/usr/lib/swift" -L /usr/lib/swift \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -o "$BUILD/CodeSaver-$ARCH"
done

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
lipo -create "$BUILD/CodeSaver-arm64" "$BUILD/CodeSaver-x86_64" -output "$BUNDLE/Contents/MacOS/CodeSaver"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$BUILD/corpus.bin" "$BUNDLE/Contents/Resources/corpus.bin"
cp "$BUILD/corpus-index.json" "$BUNDLE/Contents/Resources/corpus-index.json"
cp "$VERBS" "$BUNDLE/Contents/Resources/spinner-verbs.txt"
codesign --force --sign - "$BUNDLE"
echo "── built $BUNDLE"

# --- Preview / snapshot harness (native arch only) --------------------------
echo "── compiling preview harness…"
swiftc -O -parse-as-library -module-name CodeSaverPreview \
  "${SRC[@]}" Sources/PreviewMain.swift \
  -framework ScreenSaver -framework AppKit -framework QuartzCore \
  -o "$BUILD/preview"
echo "── built $BUILD/preview  (run it for a live window)"

# --- Install -----------------------------------------------------------------
if [[ ${1:-} == install ]]; then
  DEST="$HOME/Library/Screen Savers/CodeSaver.saver"
  rm -rf "$DEST"
  cp -R "$BUNDLE" "$DEST"
  # legacyScreenSaver caches loaded bundles; kill it so the new build is picked up.
  pkill -f legacyScreenSaver 2>/dev/null || true
  echo "── installed to $DEST"
  echo "   Select it in System Settings → Screen Saver → Other."
fi
