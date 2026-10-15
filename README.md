# CodeSaver — a Claude Code-inspired screensaver for the agentic coding era

Your Mac idles. The agent doesn't.

![CodeSaver](docs/screenshot.png)

CodeSaver fills the screen with code from your own repos, typed out live in SF Mono by a fleet of invisible coders, while a Claude Code-style spinner grinds away in the center:

```
✽ Sprokbooking… (2m 7s · ↓ 1.6k lines · still coding with xhigh effort)
```

**[Download for macOS](https://codesaver.michelg10.com)** · free and open source · macOS 14 Sonoma or later · Apple silicon and Intel

## What you'll see

- **Your code, typing itself.** Chunks of real source from your repos type in across a pure-black screen, with glowing typing heads, block cursors, and lines that dim as they settle. A fresh mix every time the saver starts.
- **The spinner.** A made-up verb runs through a whole request: a pause, then streaming with elapsed time and a line counter, climbing Claude Code's real status ladder (`coding → still coding → coding more → … almost done coding with xhigh effort`), until `✻ Sprokbooked for 2m 7s`. Then a new request starts.
- **A clock** in a TUI box: the date as a `/* comment */`, the time in chunky half-block digits. You can switch it off or set it to 24-hour in the saver's Options.
- **Ignition** (optional): the saver opens on a screenshot of your actual desktop, which pixelates and blows apart into the code in two cell-quantized shockwaves.
- **Live widgets** (optional): one panel per running Claude Code session (`✽ Thinking (12s)`, `Bash: exec`, `Permissions required`, `✻ Done (2m 7s · 4.1k tokens)`), plus whatever Music or Spotify is playing, with the cover drawn as a text mosaic.

All displays act as one machine, and everything sits on pure black, so OLED and mini-LED screens render it borderless. A frame takes about 1–2 ms.

## Install

1. Download `CodeSaver.dmg` from **[codesaver.michelg10.com](https://codesaver.michelg10.com)** and drag CodeSaver into Applications. If you open it from somewhere else, it offers to move itself.
2. Open CodeSaver. The window is a short checklist:
   - **Screensaver**: *Enable* makes CodeSaver your screen saver on every display, and remembers the one you had so you can switch back.
   - **GitHub**: type your username to use your public repos, no token needed. To include private repos, create a read-only token: the *Create a token on GitHub…* button opens the right page, and you need *Contents: read-only*. You can also skip GitHub and add folders from this Mac.
   - **Refresh automatically**: checks for new code about once a day, by default only while the Mac is plugged in.
   - **Live widgets** and **Ignition** are optional and off until you switch them on.
3. Set *when* the saver starts the usual way, in System Settings → Lock Screen, or with a hot corner. Ignition can also start it from its own corners.

Until your code arrives, the saver types a built-in sample (its own source code).

**Updating:** the app checks once a day, while its window is open, for a new version and links you here. Replace the app in Applications, then **open it once**: it re-selects itself as your screen saver and restarts its helpers on the new version.

## Your code, your Mac

- **Private repos are opt-in.** *Choose repos* lists everything the token can see: public repos start ticked and private ones unticked, and new repos follow the same rule. Anyone walking past your screen sees what the saver types.
- **Nothing is uploaded.** Your code is downloaded to `~/Library/Group Containers/<team>.com.michelg10.CodeSaver/` and stays there; the app bundle contains none of it. The token lives in your Keychain.
- **What talks to the network:**
  - `api.github.com` and `codeload.github.com`, to list and download your repos.
  - Once a day while the window is open, `api.github.com`, to look for a CodeSaver update. You can switch this off under Advanced.
  - The Spotify artwork server, for the cover, only with Live widgets on and Spotify playing.
- **Ignition screenshots** never leave the Mac. They are excluded from Time Machine and deleted the moment you're back.
- **Live widgets** show project folder names and track titles on screen. Their state is small JSON files in `~/.claude/codesaver/`.

## Live widgets

Switch on **Live widgets**, then click **Connect Claude Code**. It shows exactly what it will add to `~/.claude/settings.json` before writing anything:
- an async hook on ten session events
- a wrapper around your status line, which keeps showing your status line untouched

Restart your Claude Code sessions and their panels appear.

- **Requirements:** Claude Code, and Apple's command line tools, for `/usr/bin/python3`. The app offers to install the tools if they're missing.
- **Undoing it:** *Disconnect* puts your settings back exactly as they were. Switching Live widgets off offers the same.
- **Now playing:** reads Music or Spotify. macOS asks once whether CodeSaver may do that. Paused music stays on the panel for half an hour. The album-art mosaic can be turned off under Advanced.

## Ignition

Switch on **Ignition** and macOS asks for Screen Recording permission for *CodeSaver Igniter*.

- **How it works:** after about 20 seconds idle, the igniter takes one screenshot per display, so that when the saver starts, its first frame is your desktop, which then blows apart.
- **Starting the saver:** use macOS's own trigger (the idle timeout or a hot corner), or let the igniter do it. It has its own corners, optionally behind ⌘ ⌥ ⌃ ⇧, and its own idle timeout. If you use the igniter's, leave macOS's hot corners unbound so the two don't race.
- **Modifier corners:** hold the key first, then move the cursor in.
- **Without permission, or at the lock screen:** the saver simply starts without the intro.

## Uninstall

Open CodeSaver → **Advanced** → **Uninstall CodeSaver…**. It lists what it will remove before doing anything:
- its background helpers
- the GitHub token
- downloaded code and settings
- the igniter
- its Claude Code wiring

It also switches your screen saver back to the previous one, then moves the app to the Trash.

## Troubleshooting

- **The saver is black, or CodeSaver isn't in the list.** Make sure the app is in /Applications, open it, and click *Enable* again; after an update, opening it once is enough. *Open Screen Saver settings* lets you pick it by hand.
- **"waiting for approval in Login Items".** macOS wants you to allow the background helper: click *Open Login Items* and switch CodeSaver on.
- **No intro.** The ignition intro needs Screen Recording for *CodeSaver Igniter* (System Settings → Privacy & Security → Screen & System Audio Recording) and a few idle seconds before the saver starts. Its log is `~/Library/Logs/CodeSaver/igniter.log`.
- **No session panels.** Click *Connect Claude Code*, then restart Claude Code sessions. Panels go away when the feed goes quiet for 20 s: stale state is never shown as live.

## Build from source

Building needs **Xcode 26 or later** (on macOS 15.6+); the result runs on macOS 14+.

```bash
./appex/install.sh                # build, sign with your Apple Development cert, install to /Applications
open /Applications/CodeSaver.app  # then the same checklist as above
```

- **Signing:** `install.sh` finds your Apple Development certificate in the keychain. A free Apple ID works (Xcode → Settings → Accounts → Manage Certificates → + → Apple Development), and `TEAM_ID=…` overrides the detected team.
- **The saver selection:** an upgrade re-selects CodeSaver if it was your screen saver, but a first install leaves that to the app's *Enable*. `NO_ACTIVATE=1` skips re-selection entirely.
- **Personal extras:** a couple of the author's own integrations sit behind compile flags that only a gitignored `appex/Local.xcconfig` turns on (see `Local.xcconfig.example`) and that releases always build without: a HomePod fallback for now playing, and a legacy session-spool reader.
- **Releases:** `scripts/release.sh` archives with a Developer ID, verifies every binary, notarizes, staples, and builds `CodeSaver.dmg`.

Command line, mostly for scripts:
- **`CodeSaver --refresh [--force]`** refreshes your code; `CODESAVER_GITHUB_TOKEN` overrides the Keychain.
- **Setup:** `--import-gh-token`, `--activate`, `--saver-active`.
- **Background helpers after an update:** `--register-agent`, `--reregister-feeds`, `--reregister-igniter`.
- **`python3 feeds/wire-settings.py`**: the Claude Code wiring without the app.
  - `--status` and `--dry-run` show it without writing; `--uninstall` removes it.
  - `--dev` runs the hooks from this checkout.

**Developer tools:**
- `./build.sh` builds the preview and snapshot harness (`build/preview`), the igniter's diagnostics (`build/codesaver-igniter --corners`), and an offline test of the widget feed (`build/feeds-check`).
- How everything works, and how the look was tuned: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repo layout

```
appex/                       the app, the screensaver, the igniter (CodeSaver.xcodeproj)
├── CodeSaverExtension/      the screensaver: CodeSaverView.swift is the whole show,
│                            BoomCore/BoomMetal.swift the ignition intro + Metal renderer
├── CodeSaver/               the app: setup checklist, GitHub fetch, background helpers,
│                            widget feed, album art, move/update/uninstall
├── CodeSaverIgniter/        the igniter helper app embedded in CodeSaver.app
├── install.sh               build from source + install
└── BACKGROUND.md            notes on the macOS appex screensaver format (upstream)
helper/Igniter.swift         the igniter's source (the helper target builds it)
feeds/                       Claude Code wiring: hook, status line wrapper, wire-settings.py
scripts/                     release.sh, make-sample-corpus.sh
Sources/                     preview/snapshot harness, feed checks, marquee tuner
site/                        codesaver.michelg10.com
```

## Credits

- The appex scaffolding is derived from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) by Guillaume Louel (MIT, see `appex/LICENSE`), whose reverse-engineering of the macOS appex screensaver format made this possible. `appex/BACKGROUND.md` is his write-up.
- An aesthetic homage to [Claude Code](https://claude.com/claude-code). CodeSaver is not affiliated with Anthropic.

## License

[MIT](LICENSE).
