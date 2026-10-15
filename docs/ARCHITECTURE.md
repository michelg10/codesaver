# How CodeSaver works

The README is for people using CodeSaver. This document is for people reading or changing it: how each part works, why it is built the way it is, and how the look was tuned.

## The pieces

| Piece | What it is | Where |
|---|---|---|
| The screensaver | An ExtensionKit `.appex`, run sandboxed by macOS's screen saver engine | `appex/CodeSaverExtension/` |
| The app | A SwiftUI host with the setup checklist, GitHub fetch, and move/update/uninstall. It runs headless as its own background agents (`--refresh`, `--feeds`) | `appex/CodeSaver/` |
| The igniter | A background-only helper app embedded at `Contents/Library/LoginItems/CodeSaver Igniter.app` and registered with `SMAppService` | `appex/CodeSaverIgniter/`, `helper/Igniter.swift` |
| Claude Code wiring | An async hook, a status line wrapper, and the script that installs both | `feeds/` (bundled into the app at `Contents/Resources/claude-code/`) |

There are three LaunchAgents, all embedded in the bundle (`Contents/Library/LaunchAgents/`) and all registered by the app itself:

- `com.michelg10.CodeSaver.refresh`: hourly, lowest priority.
- `com.michelg10.CodeSaver.feeds`: KeepAlive, only while Live widgets is on.
- `com.michelg10.CodeSaver.Igniter`: KeepAlive, only while Ignition is on.

The app only registers them from its stable `/Applications/CodeSaver.app` path.

## The scene

- **Background.** Chunks of code type in across the screen with a glowing typing head and a block cursor. Whitespace is skipped so the stream never stutters, and settled lines dim with age. Chunks land around loose band anchors with gaussian jitter, and new lines clip whatever they land on, terminal-style, so the layout never reads as a grid.
- **Spinner lifecycle.** The spinner cycles verbs from a tab-delimited `Gerund<TAB>Past` list through a full request lifecycle:
  - A latency window shows just the glyph and the glowing verb.
  - Then a streaming phase shows elapsed time, an asymptotic line counter, and ↓/↑ arrows with long-tailed dwell times. ↑ is upload bursts: rarer, with counter surges and faster typing.
  - The status climbs Claude Code's real escalation ladder at the real 10/20/30/45 s thresholds.
  - It finishes `✻ Verbed for 2m 7s` in flat grey while background typing eases to its slowest. Then a new request begins.
- **Status stints.** The status shows in continuous stints. Each stint restarts the ladder and rolls its think time up front, long-tailed, so the last rung takes the same rare 45-second think it does in the terminal. A stint is capped to end at least a second before its decode segment, so a reply never lands mid-"still coding".
- **Glyph and tempo.** The glyph ping-pongs through `· ✢ ✳ ✶ ✻ ✽`, the verb glows left to right, and the whole scene's tempo eases between states.
- **Clock.** A heavy box-drawing rail carries the date as a centered comment. The time is set in `▀▄█` half-block digits with ticking seconds, and AM/PM sits on the digits' baseline. The spinner panel re-centers under whatever the clock occupies.
- **Live widgets** draw as character grids like everything else. Session panels sit bottom-left with active sessions floating above resting ones, and now playing sits bottom-right. Orange marks real Claude Code state; violet stays the saver's own theater.

## Ignition

- **The intro** is the two-boom, cell-quantized sequence in `BoomCore.swift`. macOS's own trigger (idle timeout or hot corner) or the igniter's starts the saver. Its opening frame is the captured desktop, pixel for pixel what the system transition just left, so the handoff lands on a picture of itself.
- **The idle-start countdown.** Idle starts play a 5-second pre-animation first: a bordered `✽ Verbing… (T-5s)` line beside the resting mouse. Hot corners detonate at once.
- **The grid takes over.** Nothing ever draws between cells.
  - **First shockwave.** It pixelates the desktop into one color per cell behind a ragged, dithered front of flashing cells. The wave's shape is entirely emergent from per-cell flash-and-decay; no circle is ever drawn. It stamps random spots of real corpus code over the mosaic and flings code characters through the grid as inverse-video cells trailing cooling cells.
  - **Second shockwave.** A second, denser front flips each cell to its color's complement for a beat, with code glyphs knocked out in black, and then to black.
  - **Settling.** Flung glyphs decay from the end of their flight, settle onto cells, and fade through grey. Writers ignite in the second front's wake, the clock assembles piece-wise, and the idle line teleports to its panel.
- **Multiple displays.** All displays share one session and clock, the fronts share one radius so they cross bezels coherently, and glyphs flung on one display settle on another. Lock and password behavior stay stock.

The igniter only scouts:

- **Capturing.** After about 20 s of inactivity it captures each display once and records the mouse. `captureAfterIdle` in the `com.michelg10.CodeSaver.Igniter` defaults domain tunes the delay. The screen is static precisely because you're idle, so one capture suffices.
- **Hot corners.** It watches the cursor approach saver-bound hot corners and captures pre-emptively, so corner launches detonate instantly.
- **Cleanup.** Captures are excluded from backups and deleted the moment you return or the agent stops.
- **Permission.** It asks for Screen Recording itself on its first tick, so the prompt names *CodeSaver Igniter* and arrives when the user has just switched Ignition on.
- **The lock screen.** ScreenCaptureKit lists no displays there, which is *not* a denial. Only `CGPreflightScreenCaptureAccess` decides that, and only a real denial triggers the ten-minute capture backoff.
- **Modifier corners.** They follow macOS's grammar: hold the key first, then drive the cursor in. A modifier pressed with the cursor already in the corner is a ⌘Tab, not a gesture.
- **Logs and diagnostics.** Launch decisions go to `~/Library/Logs/CodeSaver/igniter.log`, rolled at 1 MB. `build/codesaver-igniter --corners` prints corner config plus the lock/permission state; `--capture` writes a one-off manifest.

`helper/install.sh` is the legacy standalone installer. Today it only uninstalls (`./helper/install.sh uninstall`), and the app migrates a standalone igniter to the embedded one on launch.

## The corpus

The app owns its data; nothing is baked in at build time except the sample corpus, which is CodeSaver's own source and is described below.

- **Sources.**
  - Repos are listed through the GitHub API:
    - *Public only*: unauthenticated, `GitHubPublicOnly`, with tarballs from codeload.
    - *Token*: `/user/repos?affiliation=owner`, private repos included.
  - Plus any folders on this Mac (`LocalFolders`, stored with security-scoped bookmarks).
- **Selection.** `GitHubRepoChoices` holds explicit picks. A repo with no entry is in if public and out if private. An install that predates the picker had all its existing repos marked as explicit picks once, so nothing silently disappeared.
- **Filtering.** Each changed repo's tarball (skipped up front if its listing size exceeds the cap) and each folder go through one walk. The walk keeps an extension allowlist and size windows, skips `node_modules`-style, generated and bulk directories, drops secret-looking lines, and deduplicates by content hash. Every cleaned file is packed **whole** into `corpus.bin` with a source-keyed byte index.
- **Incremental runs.** A `pushed_at` manifest makes re-runs incremental. Sources that are deselected or removed are pruned from the next build.
- **Storage.** Everything lives in the shared app-group container (`~/Library/Group Containers/<TeamID>.com.michelg10.CodeSaver/`); the app and saver bundles embed none of it. *Delete downloaded code* clears the cache and the corpus but keeps the choices.
- **Progress and errors.** A run writes its progress and plain-language errors into `state.json` under the refresh lock, so the window can show a run happening in the background agent.
- **Spinner verbs.** These follow the same rule: a list imported under **Advanced** goes into the container, and the saver prefers it over the bundled one.

At runtime:

- **Reading.** The saver memory-maps the corpus and draws a fresh ~400-file subset each launch. Sources are weighted by √(file count) with a per-source share cap, files are decoded lazily, and half the subset is refreshed every time a spinner "request" completes.
- **Atomic swaps.** Corpus swaps are atomic renames, and the reader validates the index against the bin, so a refresh can never torn-read a running saver.
- **The sample.** With no valid corpus, the saver uses the bundled sample (`sample-corpus.bin`, generated by `scripts/make-sample-corpus.sh`).

**Staying fresh.** The refresh agent ticks hourly at the lowest priority launchd offers (`ProcessType Background`, `Nice 20`, low-priority I/O). The process gates itself:

- At most one run per ~day.
- With `RefreshOnlyWhenPluggedIn` (the default), only on AC power.
- A missing corpus is fetched immediately.
- *Refresh Now* ignores the gates.

## Live widgets

These three parts are independent of each other.

1. **The feed daemon.** `CodeSaver --feeds`, behind the app's Live widgets switch.
   - Once a second it merges its sources into `widgets/feed.json` in the app-group container (the only place the sandboxed saver can read), and the saver polls that file.
   - A feed older than 20 s removes every panel: frozen state is never shown as live.
   - No sources means an empty feed and no panels.
2. **Claude Code hooks.** *Connect Claude Code* runs the bundled `wire-settings.py` with `/usr/bin/python3 -I`.
   - It puts `cc-state-hook.py` on ten session events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `MessageDisplay`, `Stop`, `StopFailure`, `SessionEnd`, all `async`).
   - It wraps the status line with `cc-statusline-wrapper.sh`. The wrapper tees the status line JSON into the same writer (model name, token counts) and passes the user's original status line through. That original is recorded once, at first wiring, as `~/.claude/codesaver/statusline-original.json` + `statusline-passthrough.sh`.
   - The scripts are copied to `~/.claude/codesaver/bin`, so they outlive the app.
   - State lands in `~/.claude/codesaver/sessions/`, one small JSON per session, pruned after a day.
   - The newest three backups of `settings.json` are kept, and `--uninstall` restores the original status line object exactly.
3. **Now playing.**
   - Polled from Music and Spotify by AppleScript, only while a player is running.
   - The app asks for Automation consent when Live widgets is switched on, because the background daemon can't prompt; one approval covers both.
   - Paused music stays on the panel for half an hour.
   - Spotify artwork is fetched over https only.

Optional sources, read when present and ignored otherwise:

- **A live state file per session at `~/.claude/live/<session>.json`** (`$CLAUDE_LIVE_DIR`), as written by a pause mod:
  - Contents: every model request and tool call in flight, how the last turn ended, context size, background tasks, and pause state.
  - What it adds: *thinking*, *responding* and *writing the tool call* are told apart as they happen, *Done* is instant on Escape, and pauses show (`✽ Pausing… waiting for Bash (42s ∙ …)`, `✻ Paused (12m ∙ elapsed 15m)`).
  - Pin files in `~/.claude/live/pins/` rest on the rack as `✻ Pinned (next ping in 35m ∙ 2h 32m ago)`.
- **Behind compile flags** that only a gitignored `appex/Local.xcconfig` turns on and that `scripts/release.sh` always blanks:
  - `HOME_CONTROL`: now playing falls back to a pair of HomePods on a home-control bus.
  - `LEGACY_SPOOLS`: older session spools are read as a fallback.

`./build.sh && ./build/feeds-check` runs the daemon's merge on fabricated files in a temp directory, never on `~/.claude`.

## The app's lifecycle

- **Move** (`AppMover.swift`). Run from anywhere but `/Applications/CodeSaver.app`, the app offers to move itself. It resolves App Translocation to find the original, strips quarantine from the copy, relaunches from there, and trashes the original. Enable waits until it's in place.
- **Enable** (`PluginManager.swift`):
  1. Registers the extension with pluginkit and waits until pluginkit lists the `/Applications` copy (up to 15 s, unregistering any other copy that holds the slot).
  2. Selects it on every display and checks the selection actually stuck. PaperSaver can roll back silently.
  3. Remembers the previous screen saver for *Restore previous screen saver* and uninstall.
- **Self-repair** (`SelfRepair.swift`). Replacing the bundle makes the screen saver selection stale and leaves the KeepAlive agents running the old binary. On the first launch of a new build (`LastRunBuild`), the app re-registers the extension, re-selects it if it was active (`ScreenSaverWasActive`), and cycles whichever agents were on. `install.sh` does the same for source builds.
- **Updates** (`UpdateCheck.swift`). At most once a day while the window is open, the app asks GitHub for the latest release and compares its tag with `CFBundleShortVersionString`. `CheckForUpdates` switches this off.
- **Uninstall** (`Uninstaller.swift`). A pure plan the sheet lists word for word, then the effects:
  - the agents and the igniter (including a standalone one)
  - the Claude Code wiring
  - the Keychain token
  - the group container and the defaults
  - the extension's registration
  - the previous screen saver, put back
  - the app itself, moved to the Trash

## Releasing

`scripts/release.sh`:

1. Archives with a Developer ID, blanking `SWIFT_ACTIVE_COMPILATION_CONDITIONS` so no personal flag can reach a release.
2. Exports (developer-id).
3. Walks every Mach-O in the bundle. Each must have the runtime flag, a secure timestamp, no `get-task-allow`, arm64 + x86_64 slices, and none of the personal-code markers.
4. Notarizes and staples the app.
5. Wraps it in a signed, notarized and stapled `CodeSaver.dmg`.
6. Checks both with Gatekeeper.
7. Prints the `gh release create` line (it never runs it).

The site links to `releases/latest/download/CodeSaver.dmg`, so the asset name is fixed.

The version lives in one place: `MARKETING_VERSION` in `appex/BuildNumber.xcconfig`. The build number is a timestamp stamped by the scheme's pre-action, or by `install.sh` and `release.sh`.

## Tuning and the snapshot harness

`./build.sh && ./build/preview` runs a live windowed preview with a floating tuning panel.

> **It covers every display.** Esc quits (the panel needs focus), `h` hides the saver windows, and the panel has a Quit button.

- **Sliders.** They cover the clock's geometry and brightness, the spinner panel's position, the background code's alphas, fade rate, glow strength and vignette, and the boom's front sweep times, gap and debris density. All of them apply live and auto-save to `build/clock-tuning.json`, so chosen values can be promoted to the defaults in `CodeSaverView.swift`.
- **The boom.** Click anywhere to detonate there.
- **Window offset.** The preview view hangs 33 pt off the top edge so vertical positions match the menu-bar-less fullscreen saver.

`./build/preview --snapshot <dir> <t1> <t2>…` renders deterministic frames offscreen:

| Variable | Effect |
|---|---|
| `CODESAVER_SAMPLE_CORPUS=1` | types the bundled sample. Use it for anything you'll publish: otherwise the harness reads the real corpus. |
| `CODESAVER_WORKDUR` | pins the spinner cycle length |
| `CODESAVER_CLOCK_EPOCH` | pins the clock |
| `CODESAVER_SEED` | pins the scene |
| `CODESAVER_SNAPSHOT_SIZE=WxH`, `CODESAVER_SNAPSHOT_SCALE=2` | set the simulated screen |
| `CODESAVER_WIDGETS=0` | leaves the live panels out |
| `CODESAVER_WIDGETS_DIR=<dir>` | points them at a fixture `feed.json` |
| `CODESAVER_BOOM="x,y,armSeconds"` | arms the boom deterministically (fractions of the view) |
| `CODESAVER_CAPTURE=/path.png` | supplies the stand-in desktop; otherwise a bright fake one is synthesized |

For example: `CODESAVER_SAMPLE_CORPUS=1 CODESAVER_BOOM="0.3,0.6,1" ./build/preview --snapshot /tmp/boom 1.25 1.7 2.1 4.6`.

Everything not on a slider is a constant in `CodeSaverView.swift`:
- the palette (`accent`, glow colors)
- typing speeds and newline cost in the writer logic
- dwell and duration distributions in `startCycle`/`updateSpinner`
- the status thresholds in `statusText(since:)`
- the glyph cadence in `workingString()`

Flash decay, code-spot density, darkening and settle physics live in `BoomCore.swift`.
