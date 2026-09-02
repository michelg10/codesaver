#!/usr/bin/env python3
"""
albumart.png -> COLOUR luminance-ramp ASCII for the CodeSaver now-playing panel.

Evolves ascii-ramp.py.  Three things are decided by measurement, not by convention:

1. A 21-STEP RAMP, ORDERED BY MEASURED INK.  Every glyph is rendered in SF Mono at
   the real cell size (15px type in a 9x18px cell, 8x supersampled) and its coverage
   counted; the ramp is then built strictly increasing in that number.  This is not
   the folklore ramp: in SF Mono '#'=20.5% > '%'=20.0% > '@'=19.8%, so ` .:-=+*#%@`
   actually goes DOWN across its last three steps.  Glyphs also have to sit still --
   candidates are filtered on ink centroid (`.` sits at cy=0.72, so a field of dots
   sags to the bottom of every row; '^' floats at 0.37) -- so only near-cy-0.50,
   full-advance glyphs survive.  See --measure to regenerate the whole table.

2. THE TOP OF THE RAMP IS BLOCKS, BECAUSE NO LETTER GOES ABOVE 24%.  The densest
   plain glyph in this font is 'Q' at 24.05% ink; 'B' 23.7, 'M' 23.7, '0' 23.3 tie
   under it.  That is the hard ceiling on what type can do.  The shade blocks measure
   in monotonically above it -- '' 60.03%, '' 83.33% (not 100: the block spans
   0.15..0.99 of the 18px line box) -- and SF Mono draws them on the SAME 0.6182em
   advance as every letter, so they tile the grid exactly.  They extend the ink axis
   3.5x past the letters, and the tone curve keeps them rare, so they read as the
   art's specular highlights rather than as filled rectangles.

3. GLYPH-INK AND COLOUR ARE MARRIED, NOT STACKED.  Naively you get double darkening:
   a mid cell picks a mid glyph (~15% ink) AND a mid colour, and what the eye
   integrates is the PRODUCT, so the picture collapses into the floor.  Here the
   glyph is chosen from tone, its measured coverage a_i is looked up, and the colour
   is then divided by that coverage -- (A_REF/a_i)**K -- so a sparse glyph is handed
   a brighter colour and a block is handed a dimmer one, and the two multiply back
   onto one smooth tonal curve.  K is the compensation strength; K=0 is the naive
   stack, K=1 is full division (which flattens the colour field to one brightness).

   Colour itself is the artwork's own linear-light cell mean.  Chroma is carried as
   a luma-normalised ratio, so saturation and brightness are independent: SAT opens
   the ratio around the achromatic axis without moving luma at all, and the tone
   curve then places that luma under a PEAK ceiling of ~175/255.  The floor stays at
   true black -- p2 clips to the space glyph -- so the art dissolves into the panel
   instead of ending on a visible dark rectangle.
"""
import sys
import numpy as np
from PIL import Image

import sys as _sys
_args = [a for a in _sys.argv[1:] if not a.startswith("--")]
SRC  = _args[0] if _args else "albumart.png"
BG   = "frame-0041.00s.png"       # 1728x1080 -- the page is sized to match, no stretch
COLS, ROWS = 44, 22               # 44 cols at 2:1 cell aspect renders the square cover square

FONT_PATH, FS, CW, CH = "/Library/Fonts/SF-Mono-Regular.otf", 15, 9, 18

# (glyph, measured ink coverage %) -- strictly increasing.  Regenerate with --measure.
RAMP = [
    (" ",  0.00), ("·",  2.30), ("-",  5.53), (":",  6.90), ("!",  8.02),
    ("/",  9.48), ("+", 10.25), ("=", 11.56), ("x", 12.73), ("*", 13.89),
    ("o", 15.36), ("X", 17.36), ("C", 18.21), ("%", 19.99), ("#", 20.52),
    ("D", 21.93), ("W", 22.42), ("0", 23.33), ("Q", 24.05),
]

# '●' 40.73% and '■' 47.26% also measure in monotonically here and are dead-centred
# (cy=cx=.50), which would smooth the 24->60 jump.  They are left out on the evidence
# of --probe: two extra steps hand the top ~9% of the tonal range to heavy marks, and
# the sky -- the cover's largest bright field -- collapses from a ramp into solid bars.
# At 21 steps the blocks take 20 of 968 cells and read as specular highlights instead.
RAMP_LETTERS = RAMP[:19]                       # the 24%-capped plain ramp
RAMP_FULL    = list(RAMP)  # blocks removed per user feedback

# Tone curve, inherited from the monochrome study: linear-light downsample lifts
# everything, so it is paired with a gamma ABOVE 1 to push the bulk back down.
# The monochrome study ran gamma 1.30 / unsharp 0.45.  With colour carrying part of
# the tone the picture can afford to sit a little higher (1.15), and the three white
# rules under CALVIN / HARRIS / 18 MONTHS -- each ~6px of white averaged into a 27px
# cell, so barely 0.1 of tone above the wall -- need the cell-grid unsharp opened to
# 0.75 before they separate from the brickwork at all.
GAMMA, LO_PCT, HI_PCT, SHARP = 1.15, 2.0, 99.5, 0.75

# Colour management.
PEAK  = 175.0     # ceiling on emitted colour luma (0..255) -- nothing glares
A_EXP = 1.00      # tone exponent applied to the colour before ink compensation
K     = 0.42      # ink-compensation strength (see note 3)
A_REF = 24.05     # pivot: the densest plain glyph. comp == 1 there.
SAT   = 1.30      # chroma gain about the achromatic axis (luma-preserving).  Past
                  # ~1.35 the sky is already on the sRGB boundary (its red channel
                  # hits 0) and further gain only flattens 100+ cells onto the same
                  # hue line, so "quite blue" and "very blue" stop being different.

W709 = np.array([0.2126, 0.7152, 0.0722])


def to_lin(a):
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def to_srgb(a):
    a = np.clip(a, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * a ** (1 / 2.4) - 0.055)


def sample_rgb(path, cols, rows):
    """Area-average each cell in LINEAR light -> (rows, cols, 3).

    The cover's signature graphic is three ~6px white rules under CALVIN / HARRIS /
    18 MONTHS in a 27px-tall cell.  Averaged in gamma space they vanish and the
    sleeve stops being recognisable; linear light is the physically correct
    downscale and keeps them."""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    lin = to_lin(a)
    h, w = lin.shape[:2]
    ys = (np.arange(rows + 1) * h) // rows
    xs = (np.arange(cols + 1) * w) // cols
    out = np.empty((rows, cols, 3))
    for j in range(rows):
        band = lin[ys[j]:ys[j + 1]]
        for i in range(cols):
            out[j, i] = band[:, xs[i]:xs[i + 1]].reshape(-1, 3).mean(axis=0)
    return out


def unsharp(cells, amount):
    """Local-contrast boost on the CELL grid -- recovers edges the downsample softened."""
    if amount <= 0:
        return cells
    p = np.pad(cells, 1, mode="edge")
    blur = sum(p[j:j + cells.shape[0], i:i + cells.shape[1]]
               for j in range(3) for i in range(3)) / 9.0
    return cells + amount * (cells - blur)


def tone(rgb_lin, gamma=GAMMA, lo_pct=LO_PCT, hi_pct=HI_PCT, sharp=SHARP):
    """linear cell RGB -> t in 0..1, the tone every later decision is taken from."""
    v = unsharp(to_srgb(rgb_lin @ W709), sharp)
    lo, hi = np.percentile(v, lo_pct), np.percentile(v, hi_pct)
    return np.clip((v - lo) / max(hi - lo, 1e-6), 0.0, 1.0) ** gamma


def gamut_fit(chroma, Y):
    """Pull chroma toward the achromatic axis just far enough to fit in sRGB.

    Scaling chroma about 1.0 leaves dot(chroma, W709) == 1, so this never moves the
    cell's luma -- an out-of-gamut colour loses saturation, never brightness."""
    s = 1.0
    mx, mn = chroma.max(), chroma.min()
    if Y > 1e-9 and mx > 1.0 and mx * Y > 1.0:
        s = min(s, (1.0 / Y - 1.0) / (mx - 1.0))
    if mn < 0.0:
        s = min(s, 1.0 / (1.0 - mn))
    s = max(0.0, min(1.0, s))
    return 1.0 + s * (chroma - 1.0)


def render(rgb_lin, t, peak=PEAK, a_exp=A_EXP, k=K, sat=SAT):
    """-> glyph grid, colour grid.  Character from tone, colour from the artwork."""
    inks = np.array([c[1] for c in RAMP])
    idx = np.rint(t * (len(RAMP) - 1)).astype(int)
    Y_src = np.clip(rgb_lin @ W709, 1e-9, None)

    glyphs, colors = [], []
    for j in range(t.shape[0]):
        gr, cr = [], []
        for i in range(t.shape[1]):
            ch, a = RAMP[idx[j, i]]
            # colour luma: tone, then divided by the glyph's measured ink coverage
            comp = (A_REF / max(a, 1e-6)) ** k if a > 0 else 1.0
            v = min(peak * (t[j, i] ** a_exp) * comp, 255.0)
            Y = to_lin(np.array([v / 255.0]))[0]
            chroma = 1.0 + sat * (rgb_lin[j, i] / Y_src[j, i] - 1.0)
            rgb = gamut_fit(chroma, Y) * Y
            r, g, b = np.rint(to_srgb(rgb) * 255.0).astype(int)
            gr.append(ch)
            cr.append("#%02X%02X%02X" % (r, g, b))
        glyphs.append(gr); colors.append(cr)
    return glyphs, colors


def art_rows(glyphs, colors):
    """One HTML string per art row, run-length merged on colour."""
    rows = []
    for gr, cr in zip(glyphs, colors):
        parts, i = [], 0
        while i < len(gr):
            j = i
            while j < len(gr) and cr[j] == cr[i]:
                j += 1
            seg = "".join(gr[i:j]).replace("&", "&amp;").replace("<", "&lt;")
            parts.append(seg if cr[i] == "#000000"
                         else f'<span style="color:{cr[i]}">{seg}</span>')
            i = j
        rows.append("".join(parts))
    return rows


# ---------------------------------------------------------------- page

PANEL_HEAD = ('<span class="r">╭─</span> <span class="lbl"><span class="w1">♪</span>'
              ' now playing</span> <span class="r">──────────────────────────────╮</span>')
PANEL_PAD  = '<span class="r">│</span>                                              <span class="r">│</span>'
PANEL_TAIL = [
    PANEL_PAD,
    '<span class="r">│</span>  <span class="t">Feel so Close (Radio Edit)</span>                  <span class="r">│</span>',
    '<span class="r">│</span>  <span class="a">Calvin Harris</span>                               <span class="r">│</span>',
    PANEL_PAD,
    '<span class="r">│</span>  <span class="tm">1:23</span> <span class="done">────────────</span>'
    '<span class="dot w1">●</span><span class="left">───────────────────</span>'
    ' <span class="tm">3:27</span>  <span class="r">│</span>',
    '<span class="r">╰──────────────────────────────────</span>'
    '<span class="src"> Music.app </span><span class="r">─╯</span>',
]

CSS = """
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: 1728px; height: 1080px; overflow: hidden; background: #000; }
  body {
    position: relative;
    /* the capture is natively 1728x1080 -- shown 1:1, never stretched */
    background: #000 url('frame-0041.00s.png') 0 0 / 1728px 1080px no-repeat;
    font-family: "SF Mono", ui-monospace, Menlo, monospace;
  }
  .panel {
    position: absolute;
    right: 24px; bottom: 26px;
    padding: 9px 10px;
    background: rgba(0, 0, 0, 0.985);   /* opaque enough to hide the capture's own music panel */
    border-radius: 7px;
    box-shadow: 0 0 28px 20px rgba(0, 0, 0, 0.6);   /* melts the hard edge into the black */
  }
  .panel pre {
    font-family: inherit;
    font-size: 15px;
    /* 15px type on an 18px line = a 9x18px cell = exactly the 2:1 aspect the art was
       sampled for, and the same cell the ramp's ink was measured in. */
    line-height: 18px;
    white-space: pre;
  }
  .w1   { display: inline-block; width: 1ch; text-align: center; }
  .r    { color: #4D4D4D; }
  .lbl  { color: #4F595F; }
  .t    { color: #94A6B8; }
  .a    { color: #666; }
  .tm   { color: #666; }
  .done { color: #7A8894; }
  .left { color: #3A3F44; }
  .dot  { color: #A8E5FF; text-shadow: 0 0 6px rgba(168, 229, 255, 0.55); }
  .src  { color: #4F595F; }
"""


def emit_page(rows, path):
    body = [PANEL_HEAD, PANEL_PAD]
    body += ['<span class="r">│</span> ' + r + ' <span class="r">│</span>' for r in rows]
    body += PANEL_TAIL
    with open(path, "w") as f:
        f.write("<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
                "<title>CodeSaver — ASCII Album Art (colour ramp)</title>\n"
                "<style>" + CSS + "</style>\n</head>\n<body>\n"
                '  <div class="panel"><pre>' + "\n".join(body) + "</pre></div>\n"
                "</body>\n</html>\n")


# ---------------------------------------------------------------- measurement

def measure():
    """Re-derive the ink table.  Every number in RAMP came out of here."""
    from PIL import ImageDraw, ImageFont
    SS = 8
    font = ImageFont.truetype(FONT_PATH, FS * SS)
    asc, desc = font.getmetrics()
    top = (CH * SS - (asc + desc)) / 2.0
    cands = list(" .'`^\",:;-_~!|/\\+=<>*ilrcvxznuoshaeytkfjqpdbgw%&$#@"
                 "ABCDEFGHKMNOPQRSUVWXZ0123456789()[]{}") + list("░▒▁▂▃▄▅▆▇■□●○•·…∙")
    seen, out = set(), []
    for ch in cands:
        if ch in seen:
            continue
        seen.add(ch)
        W, H = CW * SS, CH * SS
        img = Image.new("L", (W, H), 0)
        ImageDraw.Draw(img).text((0, top), ch, font=font, fill=255)
        px = np.asarray(img, dtype=np.float64)
        cov, tot = px.mean() / 255.0, px.sum()
        cy = (px.sum(axis=1) @ np.arange(H)) / tot / H if tot else 0.5
        cx = (px.sum(axis=0) @ np.arange(W)) / tot / W if tot else 0.5
        out.append((cov, cy, cx, ch))
    out.sort()
    print(f"{'ink':>7}  {'cy':>4} {'cx':>4}  glyph   (centred = |cy-.5|<=.09 and |cx-.5|<=.09)")
    for cov, cy, cx, ch in out:
        flag = "  <-- centred" if abs(cy - .5) <= .09 and abs(cx - .5) <= .09 else ""
        print(f"{cov*100:6.2f}%  {cy:.2f} {cx:.2f}  {ch!r:6}{flag}")


if __name__ == "__main__":
    if "--measure" in sys.argv:
        measure(); sys.exit(0)

    assert all(RAMP[i][1] < RAMP[i + 1][1] for i in range(len(RAMP) - 1)), "ramp not monotonic"

    rgb = sample_rgb(SRC, COLS, ROWS)
    t = tone(rgb)

    if "--stats" in sys.argv:
        for p in (0, 5, 25, 50, 75, 95, 99, 100):
            print(f"tone p{p}: {np.percentile(t, p):.3f}")
        hist = np.bincount(np.rint(t * (len(RAMP) - 1)).astype(int).ravel(),
                           minlength=len(RAMP))
        for (ch, ink), n in zip(RAMP, hist):
            print(f"  {ch!r:5} ink={ink:5.2f}%  cells={n:4d}  {'#' * (n // 4)}")
        sys.exit(0)

    if "--probe" in sys.argv:
        variants = [("letters(19)", RAMP_LETTERS), ("shade(21)", list(RAMP)),
                    ("full(23)", RAMP_FULL)]
        blocks = []
        for name, rp in variants:
            for k in (0.00, 0.25, 0.42, 0.60):
                RAMP[:] = rp
                g, c = render(rgb, t, k=k, sat=1.40)
                blocks.append(f'<div class="lab">{name}  K={k:.2f}</div>'
                              '<pre>' + "\n".join(art_rows(g, c)) + '</pre>')
        with open("probe-color.html", "w") as f:
            f.write('<!doctype html><meta charset="utf-8"><style>'
                    'body{background:#000;margin:0;padding:16px;'
                    'font-family:"SF Mono",monospace;display:flex;flex-wrap:wrap;gap:18px}'
                    'pre{font-size:15px;line-height:18px;white-space:pre;margin:0}'
                    '.lab{color:#6a7784;font-size:12px;padding-bottom:4px}'
                    'div.cell{}</style>' +
                    "".join(f'<div>{b}</div>' for b in blocks))
        print("wrote probe-color.html", file=sys.stderr)
        sys.exit(0)

    glyphs, colors = render(rgb, t)

    if "--json" in sys.argv:
        # Machine mode for the CodeSaver feeds daemon: rows of glyphs plus
        # per-cell hex colors. The saver draws these directly.
        import json as _json
        print(_json.dumps({
            "style": "ramp",
            "cols": COLS, "rows": ROWS,
            "chars": ["".join(r) for r in glyphs],
            "colors": [[c for c in row] for row in colors],
        }))
        sys.exit(0)

    print(f"# {COLS}x{ROWS}  ramp={len(RAMP)} steps  gamma={GAMMA} unsharp={SHARP} "
          f"peak={PEAK:.0f} K={K} sat={SAT}")
    for r in glyphs:
        print("".join(r))
    emit_page(art_rows(glyphs, colors), "albumart-ramp-color.html")
    print("\nwrote albumart-ramp-color.html", file=sys.stderr)
