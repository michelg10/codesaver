#!/bin/zsh
# Build the windowed preview / snapshot harness (the tuning workflow):
#   ./build.sh
#   ./build/preview                            live window + tuning panel
#   ./build/preview --snapshot <dir> <t1> <t2>…  offscreen PNG frames
#
# The harness reads the corpus + verbs CodeSaver.app maintains in the
# app-group container (CODESAVER_RESOURCES overrides, e.g. for video renders).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
echo "── compiling preview harness…"
swiftc -O -parse-as-library -module-name CodeSaverPreview \
  appex/CodeSaverExtension/CodeSaverView.swift \
  appex/CodeSaverExtension/BoomCore.swift \
  appex/CodeSaverExtension/BoomMetal.swift \
  appex/CodeSaver/Helpers/Logger.swift \
  appex/CodeSaver/CorpusStore.swift \
  appex/CodeSaver/AlbumArtShared.swift \
  appex/CodeSaver/AlbumArtRamp.swift \
  Sources/PreviewMain.swift \
  -framework ScreenSaver -framework AppKit -framework QuartzCore -framework Metal \
  -framework ScreenCaptureKit -framework ImageIO -framework IOKit \
  -o build/preview
echo "── built build/preview  (run it for a live window)"

# --- Igniter helper (idle watcher → boom → screensaver) ----------------------
echo "── compiling igniter helper…"
swiftc -O -parse-as-library helper/Igniter.swift \
  -framework AppKit -framework IOKit -framework ScreenCaptureKit \
  -o build/codesaver-igniter
echo "── built build/codesaver-igniter  (helper/install.sh installs the LaunchAgent)"

# --- Marquee tuner (standalone window for the now-playing title roll) --------
echo "── compiling marquee tuner…"
swiftc -O -parse-as-library Sources/MarqueeTuner.swift -framework AppKit -o build/marquee-tuner
echo "── built build/marquee-tuner  (opens in a second; writes build/marquee-tuning.json)"
