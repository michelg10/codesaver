# codesaver.michelg10.com

The marketing and download site for CodeSaver. Vanilla HTML/CSS/JS with no
framework and no build step, plus a small server (server.ts) for the one dynamic part:
the latest GitHub release.

```
site/
├── server.ts          Bun server (also runs on Node ≥ 23 for a local check)
├── .backupignore      cache/ under $DATA_DIR is disposable
├── tools/
│   └── make-data.py   regenerates public/data.json from the repo's own source
└── public/            everything the browser loads; works from any static root
    ├── index.html     the page; three <!--release:…--> slots the server fills
    ├── 404.html       served with status 404 (root-absolute asset paths)
    ├── styles.css
    ├── app.js         hero renderer, boom, widgets demo, transcript, checklist, reveals
    ├── data.json      sample code chunks + spinner verbs for the hero
    ├── icons/         favicons + apple-touch-icon (sips from the app icon)
    └── media/         og.png, poster.jpg, hero.webm/.mp4, boom.mp4,
                       boom-poster.jpg, widgets-1440.webp, widgets-2880.webp
```

## What's live and what's recorded

- **Hero**: a port of the saver's renderer to `<canvas>` (`Hero` in app.js): the
  typing writers, the spinner lifecycle and its "still coding" ladder, the
  half-block clock in the visitor's local time, all at the saver's 30 Hz. Click
  or tap anywhere in it (or press the "click anywhere to ignite" button) to run
  the ignition: a drawn stand-in desktop, the idle line, then BoomCore's two
  fronts cell for cell (mosaic, code spots, burns, flung glyphs, violet surge,
  the zap home). Pauses off screen and in background tabs. Under
  `prefers-reduced-motion` it renders one still frame and the boom is off.
- **Widgets**: a canvas character-grid demo of the session rack (orange = real
  Claude Code state) and the now-playing panel with a procedural cover through
  the saver's 19-step ink ramp.
- **Media**: rendered by the saver's own snapshot harness (`/tmp/cs-media`,
  see its README). Videos are `preload="none"`, start only when scrolled into
  view (never under reduced motion), and carry a pause toggle in the frame's
  bottom rail. If a file is missing, the frame falls back to its poster or to a
  line of text.

Counter label: the hero says `↓ 1.2k tokens`, matching what CodeSaverView.swift
draws today. If the saver switches to lines, change `UNIT` at the top of app.js.

## Release data

`GET /api/release` returns either

```json
{"status":"released","version":"v1.0.0","publishedAt":"…","dmgSize":9412337,
 "dmgUrl":"https://github.com/…/CodeSaver.dmg","pageUrl":"…","notesHtml":"<p>…</p>"}
```

or `{"status":"coming-soon","repoUrl":"https://github.com/michelg10/codesaver"}`
(GitHub answers 404 until a release is published). The server fetches
`api.github.com/repos/michelg10/codesaver/releases/latest` with
`Accept: application/vnd.github.html+json`, caches it 10 minutes (serving the
stale copy while it refreshes, retrying after 1 minute on errors), keeps the
last good answer in `$DATA_DIR/cache/release.json`, and re-sanitizes the notes
HTML (no scripts, styles, images, handlers). The same data is rendered into
the page server-side: the download button reads `download v1.0.0 · 9.4 MB`
(the asset named `CodeSaver.dmg`, else the first `.dmg`), and "what's new"
shows the notes. With no release, both slots say the first release is coming
soon and point at the source; nothing links to a download that doesn't exist.
Served as plain static files (no server), the page shows that coming-soon state.

Environment: `PORT`, `HOST` (127.0.0.1), `DATA_DIR`, `HTTPS_PROXY` (Bun's fetch
uses it), optional `GITHUB_TOKEN` (raises the 60/hour unauthenticated limit,
not needed at one request per 10 minutes), `CODESAVER_REPO` (default
`michelg10/codesaver`), `RELEASE_FIXTURE` (a saved API response, or `none`, for
local testing).

Every response carries a strict CSP (self only, the one inline boot script
allowed by hash, computed at startup), `nosniff`, and `no-referrer`. HTML, CSS,
JS and JSON revalidate on every load (`no-cache` + Last-Modified, so 304s);
media is cached for a day. Range requests are supported for video.

## Run locally

```sh
PORT=8080 bun site/server.ts            # or: PORT=8080 node site/server.ts
RELEASE_FIXTURE=/path/to/release.json PORT=8080 node site/server.ts   # released state
```

## Deploy (not done; for Michel)

```sh
ship egress add api.github.com
ship app codesaver ./site --run "bun server.ts"
```

## Regenerating

- `python3 site/tools/make-data.py` rebuilds `public/data.json`: chunks of
  CodeSaver's own MIT source (Swift, Python, shell) with any chunk dropped
  whole if a line mentions Michel, his private tools or paths, or looks like a
  secret, plus the bundled spinner verbs minus brand puns and crude ones.
- Favicons: `sips -z N N appex/CodeSaver/Assets.xcassets/AppIcon.appiconset/icon_1024.png --out public/icons/icon-N.png`
  for 16, 32, 192 and 180 (apple-touch-icon).
- Media: copy from `/tmp/cs-media` (or re-render with its scripts). The widgets
  still is converted with `cwebp -q 82 -sharp_yuv -m 6` (2880 px) and
  `-q 84 -resize 1440 900` (1440 px); the boom poster is
  `ffmpeg -ss 1.9 -i boom.mp4 -frames:v 1 -vf scale=1280:-2 -q:v 5 boom-poster.jpg`.
  `story.mp4` and `still-clock.png` aren't used.
