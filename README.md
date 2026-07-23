# CodeSaver — a Claude Code-inspired screensaver for the agentic coding era

Your Mac idles. The agent doesn't.

![CodeSaver](docs/screenshot.png)

CodeSaver fills the screen with code sampled from your own GitHub repos, typed out live by a fleet of invisible coders in SF Mono, while a Claude Code-style spinner grinds away in the center:

```
✽ Sprokbooking… (2m 7s · ↓ 1.6k lines · still coding with xhigh effort)
```

## What it does

- **Background**: chunks of real code from your repos type in across the screen — glowing typing head, block cursor, whitespace skipped so the stream never stutters, settled lines dimming with age. Chunks place around loose band anchors with gaussian jitter, and new lines clip whatever they land on, terminal-style, so the layout never reads as a grid.
- **Spinner**: cycles verbs from a tab-delimited `Gerund<TAB>Past` list through a full request lifecycle — a latency window with just the glyph and glowing verb, then a streaming phase with elapsed time, an asymptotic line counter, ↓/↑ arrows with long-tailed dwell times (↑ = upload bursts: rarer, counter surges, typing speeds up), and a status that escalates `coding → still coding → almost done coding with xhigh effort` on a fixed clock each time it appears. Eventually:

  ```
  ✻ Sprokbooked for 2m 7s
  ```

  …flat grey, resting, background typing eased down to its slowest — then a new request begins.
- **Clock**: a TUI box in the spirit of Claude Code's welcome banner — heavy box-drawing rails with the date as a centered comment (`/* Sun Jul 12 2026 */`), the time in chunky `▀▄█` half-block digits with ticking seconds, and AM/PM on the digits' baseline. Toggleable (and switchable between 12/24-hour) from the **Options** sheet in System Settings; the spinner panel re-centers under whatever the clock occupies.
- The glyph ping-pongs through `· ✢ ✳ ✶ ✻ ✽`, the verb glows left-to-right, and the whole scene's tempo eases between states — everything on pure black, so OLED and miniLED displays render it borderless.
- **Ignition** (optional): a tiny LaunchAgent keeps a fresh capture of your desktop ready, and the saver itself opens with a **two-boom, cell-quantized intro** (`BoomCore.swift`). macOS's own trigger (idle timeout or hot corner) starts the saver; its opening frame is the captured desktop — pixel-for-pixel what the system transition just left — so the handoff lands on a picture of itself. Idle triggers play a 5-second pre-animation: a bordered `✽ Verbing… (T-5s)` line beside where your mouse rests, counting down; hot corners detonate immediately. Then the grid takes over — nothing ever draws between cells. The first shockwave pixelates the desktop into one color per cell behind a ragged, dithered front of flashing cells (the wave's shape is entirely emergent from per-cell flash-and-decay; no circle is ever drawn), stamps random spots of *actual code* from your corpus over the mosaic in barely-translucent white, and flings code characters *through* the grid as inverse-video cells trailing cooling cells. A second, denser front follows and flips the pixels over — each cell shows its own color's complement for a beat, code glyphs knocked out in black, then dies to black. Flung glyphs decay from the end of their flight, settle onto cells, and fade through grey into nothing; writers ignite in the second front's wake; the clock assembles piece-wise under the burst; and the idle line teleports to its home panel — a flash where it stood, a blocky blip where it lands, a beat of nothing, and then it simply is there. All displays act as one machine: a single shared session and clock spans every screen, the fronts share one radius so they cross bezels coherently, and glyphs flung on one display settle on another. Lock/password behavior stays stock — the boom is choreography inside the real system saver.

## Requirements

- macOS 14 (Sonoma) or later — the screensaver is a modern ExtensionKit `.appex`
- Xcode 15+
- An authenticated [`gh`](https://cli.github.com) CLI (for corpus ingestion)

## Build & install

```bash
./setup.sh                  # interactive: GitHub username, verbs list, signing team
./ingest.py                 # mirror source from your GitHub repos into ingest/cache/
./appex/install.sh          # sample a corpus, build, install to /Applications, register
./build.sh && ./helper/install.sh   # optional: the ignition LaunchAgent
```

With the igniter installed, use **macOS's own trigger**: set System Settings → Lock Screen → "Start Screen Saver when inactive" to taste, and/or bind a hot corner to Start Screen Saver. The agent only scouts: after ~20 s of inactivity (tunable: `defaults write com.michelg10.CodeSaver.Igniter captureAfterIdle -float 20`) it captures each display once and records the mouse — the screen is static precisely because you're idle, so one capture suffices and costs nothing. It also watches the cursor approach saver-bound hot corners and captures pre-emptively, so corner launches detonate instantly. Captures are deleted the moment you return. Grant the igniter **Screen Recording** permission for the pixelated-desktop act — without it (or without a fresh capture, e.g. a surprise activation) the saver simply starts normally. `build/codesaver-igniter --capture` writes a one-off manifest for testing.

Then pick **CodeSaver** in System Settings → Screen Saver. `open /Applications/CodeSaver.app` gives you a host app with install status and a live preview window.

`setup.sh` writes a gitignored `setup.conf` with your GitHub username (non-fork repos only; a manifest makes ingest re-runs incremental), your Apple team ID (auto-detected from your signing certificate when possible), and optionally the path to your own spinner-verbs list — tab-delimited lines of `Gerund<TAB>Past`. If you don't supply one, the bundled list is used.

`ingest.py` filters out non-source files (extension allowlist, size windows, `node_modules`-style dirs, generated-file patterns, bulk directories). `make_corpus.py` packs every cleaned file **whole** into `corpus.bin` with a repo-keyed byte index (`corpus-index.json`), deduplicating by content hash and dropping secret-looking lines. At runtime the saver memory-maps the corpus and draws a fresh ~400-file subset each launch — repos weighted by √(file count) with a per-repo share cap, so big projects dominate only within reason — decoding files lazily and refreshing half the subset every time a spinner "request" completes. **The corpus files are gitignored on purpose** — they embed your actual code, private repos included, and so does the built app.

## Repo layout

```
ingest.py                      stage 1: GitHub → ingest/cache/ (run occasionally)
make_corpus.py                 stage 2: cache → corpus.txt (runs at build)
appex/                         the screensaver (ExtensionKit appex + host app)
├── CodeSaverExtension/        the .appex — CodeSaverView.swift is the whole show
├── CodeSaver/                 SwiftUI host app (install / preview UI)
├── install.sh                 build + install to /Applications + pluginkit
└── BACKGROUND.md              appex screensaver architecture notes (upstream)
helper/                        ignition scout: idle/corner watcher → desktop capture
├── Igniter.swift              the codesaver-igniter agent (single file)
└── install.sh                 install/uninstall the LaunchAgent
build.sh                       legacy .saver build + offscreen snapshot harness
Sources/PreviewMain.swift      windowed preview / PNG snapshot renderer
harness/loadtest.swift         bundle load smoke test
```

The snapshot harness is how the aesthetics were tuned: `./build.sh && ./build/preview --snapshot <dir> <t1> <t2>…` renders deterministic frames offscreen (`CODESAVER_WORKDUR` pins the cycle length).

## Tuning

Run `./build.sh && ./build/preview` for a live windowed preview with a floating **tuning panel**: sliders for the clock's geometry and brightness, the spinner panel's position, and the background code's alphas, fade rate, glow strength, and vignette — all applying live, all auto-saved to `build/clock-tuning.json` so chosen values can be promoted to the defaults in `CodeSaverView.swift`. (The preview view is drawn 33pt taller than the window, hanging off the top edge, so vertical positions match the menu-bar-less fullscreen saver; a "Reset to defaults" button restores the compiled values.)

Everything not on a slider lives as constants in `appex/CodeSaverExtension/CodeSaverView.swift`: the palette (`accent`, glow colors), typing speeds and newline cost in the writer logic, dwell/duration distributions in `startCycle`/`updateSpinner`, status escalation thresholds in `statusText(since:)`, and the glyph cadence in `workingString()`.

The boom is tunable the same way: click anywhere in the live preview to detonate at that point (the tuning panel's **Replay boom** re-fires the last origin), sliders cover both fronts' sweep times, the gap between them, and debris density, and `CODESAVER_BOOM="x,y,armSeconds"` (fractions of the view) arms it deterministically for the snapshot harness — e.g. `CODESAVER_BOOM="0.3,0.6,1" ./build/preview --snapshot /tmp/boom 1.25 1.7 2.1 4.6`. `CODESAVER_CAPTURE=/path.png` supplies the stand-in "desktop" the first front pixelates; without it the preview uses `build/stand-in-capture.png` if you've dropped a screenshot there (gitignored — it's your real screen), else it synthesizes a bright fake desktop (wallpaper, windows, dock) so the pixelation act is actually visible. Flash decay, code-spot density, darkening, and settle physics live as constants in `BoomCore.swift`.

## Credits

- Appex scaffolding derived from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) by Guillaume Louel (MIT — see `appex/LICENSE`), whose reverse-engineering of the macOS appex screensaver format made this possible. `appex/BACKGROUND.md` is his write-up.
- Aesthetic homage to [Claude Code](https://claude.com/claude-code).

## License

[MIT](LICENSE). The appex scaffolding is derived from AppexSaverMinimal (MIT, Guillaume Louel — see `appex/LICENSE`).
