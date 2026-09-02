#!/usr/bin/env python3
"""
ascii-braille-color.py -- album art -> COLOURED Unicode braille (U+2800..U+28FF).

Design #5: the braille dot matrix of ascii-braille.py, but every cell is tinted
with the real RGB of the 2x4 source region it stands for, instead of being
quantised onto a 5-step slate ramp.

WHY THE ODD CONSTANTS (all measured from the real macOS fonts, not assumed):

  SF Mono advance        = 1266/2048 = 0.61816 em
  Apple Braille advance  = 1400/2048 = 0.68359 em

  SF Mono, Menlo, Monaco and Andale Mono contain ZERO glyphs in U+2800..U+28FF.
  On macOS the only font covering the block is Apple Braille, so any braille in
  an "SF Mono" run is silently rendered by a different font at a 10.6% wider
  advance -- it will not sit on the surrounding character grid.

  Apple Braille dot geometry: dot diameter 248 units, horizontal dot pitch 482,
  vertical dot pitch 490. Two dots span 964 units but the advance is 1400, so
  the gap between the last dot of one cell and the first dot of the next is 918
  units -- 1.9x the intra-cell pitch. Left alone the dot lattice is striped at
  the character period and any dithered image combs vertically.

  Fix: letter-spacing = -(1400-964)/2048 em = -0.21289 em. That squares the
  lattice AND lands the cell advance back on the SF Mono column grid:
      font-size 19.70px * (964/2048) = 9.272px  ==  SF Mono 15px advance.
  Uniform vertical lattice needs line-height 1961/2048 em = 0.95752 em.

  Result: 46 cols x 23 rows = 92 x 92 dots, dot pitch 4.636 x 4.714 px (square
  to within 1.7%), art block exactly 46 SF Mono columns wide.

TONE PIPELINE (unchanged, so the dot pattern is identical to design #4): the
cover is a photo with a large flat bright sky that otherwise swallows the whole
ink budget. A local-contrast (unsharp, r=8 dots) pass before the dither
redistributes it: it textures the flat sky, restores the breeze-block wall, and
sharpens the "CALVIN HARRIS / 18 MONTHS" lettering and the crouching figure.
Gamma 2.10 lands the whole frame at ~34% ink.

COLOUR PIPELINE (new):
  * The cover is supersampled 6x per dot, linearised, and box-averaged down to
    one linear-light RGB per DOT (92x92).
  * A cell's colour is the linear-light mean of the dots that are actually
    INKED. That matters: a dot is a piece of *light*, so averaging the whole
    2x4 region would drag every cell toward the shadow it chose not to draw.
    Cells with no ink fall back to the whole region (they render nothing).
  * Chroma is lifted, because braille is a ~26%-coverage halftone: each glyph
    is 8 small discs on black, so the eye integrates cell colour against ~74%
    black and reads it as greyer and darker than the same hex painted solid.

    The curve has THREE joints, and all of them matter:

      TOE.  Anything under SAT_TOE is pinned to grey. A plain gain lifts the
      LOW end hardest, which is exactly backwards -- the sidewalk's near-neutral
      concrete (s~0.06, hue wandering between green and cyan on pixel noise)
      blooms into a lurid band while the sky barely moves.

      DARK GATE.  HSV saturation is a RATIO, so it stays large as a pixel goes
      to black: measured on the Garrix cover, the darkest decile of cells carries
      mean S = 0.85 at mean V = 0.034 -- JPEG noise on near-black, with no hue
      information in it at all. Left alone (and especially once the luma stage
      below re-brightens those cells so their dots can be seen) the cover's black
      background renders as blue and green confetti. So chroma evidence is
      discounted by how much light the cell actually has, fading to nothing under
      CHROMA_DARK_TOE. A hue is only real if there is light to see it by.

      KNEE (convex).  Above the toe the curve is NOT a flat gain. A flat 1.85x
      doubles the MIDDLE of the range, and mid-saturation cells are precisely
      the ones that turn muddy: they arrive with enough chroma to colour-cast
      but not enough to read as a hue, and doubling them paints the whole frame
      in half-committed colour. So the lift is convex instead:

          gate = clamp01((v - CHROMA_DARK_TOE)/(CHROMA_DARK_KNEE - ...TOE))
          u    = min(1, (s - SAT_TOE)/(SAT_KNEE - SAT_TOE)) * gate
          sat  = SAT_MAX * u**SAT_POW          (SAT_POW > 1)

      SAT_KNEE is set to the source saturation at which the old flat gain hit
      SAT_MAX, so the TOP of the range is untouched -- every cell that used to
      peg at 0.92 still pegs at 0.92. Only the middle is pulled back down
      toward its true chroma, and it falls away faster than linearly.

  * VALUE IS LUMA-FIRST, not HSV-value-first. This is the other half of the
    same bug. HSV's V is not brightness: hsv(240, 0.92, 1.0) is a fully "bright"
    blue whose Rec.709 luma is 0.15. Setting V from a luminance ramp and then
    lifting S therefore DARKENS every cell it colours, which is why a saturated
    cover rendered as dark mush. Here the ramp produces a target LUMA, and V is
    solved for it -- chroma rides along as a ratio:

          v = target_luma / luma(hsv(h, sat, 1.0))

    A deep hue cannot physically reach a high luma (pure red tops out at 54/255),
    so the divisor is floored at HUE_LUMA_FLOOR and the quotient goes through a
    soft knee rather than a hard clip: without it every saturated cell would
    slam to v=1 and the region would lose all its tonal structure.

  * The ramp itself is compressed (t**LUM_POW, LUM_POW < 1, over a
    LUM_FLOOR..LUM_PEAK span) and fed GAMMA-ENCODED luminance. Compressed
    because the dot density already encodes most of the luminance, so a second
    full-strength luminance term would double-darken the shadows into a void;
    gamma-encoded because percentiles taken on linear light crush the midtones
    against the shadow end and the wall stops reading as sunlit.

  * The ramp is auto-scaled so the 99.5th percentile of cell luma lands on
    PEAK_LUMA (216/255). Dots run hotter than solid blocks would: brightness
    dilutes against the black lattice exactly as hard as chroma does, and
    brightness is what makes the dots READ.
"""
import colorsys, html, math
from PIL import Image

import sys as _sys
_args = [a for a in _sys.argv[1:] if not a.startswith("--")]
SRC        = _args[0] if _args else "albumart.png"
OUT        = "albumart-braille-color.html"
COLS, ROWS = 46, 23
DW, DH     = COLS * 2, ROWS * 4        # 92 x 92 dots

# --- tone (identical to ascii-braille.py) ---------------------------------
BLUR_R     = 8.0     # dots; local-contrast radius
SHARPEN    = 0.40    # unsharp amount
LO_PCT     = 1.0
HI_PCT     = 96.0
GAMMA      = 2.10
FLOOR      = 0.03
CEIL       = 0.98

# --- colour ---------------------------------------------------------------
SUPER      = 6       # source pixels per dot edge before linear-light averaging
SAT_TOE    = 0.035   # below this the cell is treated as neutral, not tinted
SAT_KNEE_MIN = 0.474  # source saturation that maps to SAT_MAX -- the FLOOR of
                      # the adaptive knee, and the exact point at which the old
                      # flat 1.85x gain hit the cap. The knee never goes below
                      # it, so a genuinely muted cover is never bloomed.
SAT_KNEE_PCT = 96.0   # ... but on a cover whose own chroma runs hotter than
                      # that, the knee rises to this percentile of it, so only
                      # the top few percent of cells reach the cap. SAT_MAX
                      # itself never moves: the peaks stay exactly as hot, they
                      # just stop being a whole field. On Harry's cover a fixed
                      # knee pegged 33% of cells at full chroma and on Garrix's
                      # 55% -- at which point "peak" means nothing, and (since
                      # a saturated hue physically cannot carry much luma: pure
                      # red tops out at 54/255) it is also what was keeping
                      # those covers dark.
SAT_POW    = 1.55    # >1 == CONVEX: the middle of the range falls away faster
                     # than linearly, so mid-saturation cells stop being dragged
                     # into half-committed colour. The peak is unaffected.
SAT_MAX    = 0.92
CHROMA_DARK_TOE  = 0.05   # source V under this carries no usable hue at all
CHROMA_DARK_KNEE = 0.28   # ... and full chroma is only trusted from here up

LUM_FLOOR  = 0.46    # target Rec.709 luma (0..1, sRGB code) of the darkest cell
LUM_PEAK   = 0.88    # ... and of the brightest, before the PEAK_LUMA auto-scale
LUM_POW    = 0.56    # <1 == lifts the MIDS of the luminance ramp
HUE_LUMA_FLOOR = 0.30  # a hue this dark can't reach its target; stop dividing
V_KNEE     = 0.80    # soft-clip joint for v, so deep hues keep tonal structure
                     # instead of all slamming flat against v = 1
PEAK_LUMA  = 216.0   # target 99.5th-pct Rec.709 luma of the rendered cells
CH_CLIP    = 238     # hard channel ceiling
QUANT      = 3       # colour quantisation step -> longer run-length runs

# --- panel ----------------------------------------------------------------
FS   = 15.0                                 # SF Mono px (matches the capture)
CW   = 1266 / 2048 * FS                     # 9.27246 px advance
LH   = 22.0                                 # measured line pitch in the frame
FB   = CW / (964 / 2048)                    # braille px so its cell == CW
BLS  = CW - (1400 / 2048) * FB              # negative letter-spacing
ALH  = 1961 / 2048 * FB                     # uniform vertical dot lattice
TOTAL = COLS + 4                            # "| " + art + " |" = 50 columns

TITLE, ARTIST, APP = "Feel so Close (Radio Edit)", "Calvin Harris", "Music.app"
ELAPSED, TOTALT = "1:23", "3:27"

S2L = [(c / 255.0 / 12.92) if c / 255.0 <= 0.04045
       else (((c / 255.0) + 0.055) / 1.055) ** 2.4 for c in range(256)]


def lin_to_srgb(v):
    v = 0.0 if v < 0 else (1.0 if v > 1 else v)
    return v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def bit_for(c, r):
    """Unicode braille dot bit order for cell column c (0..1), row r (0..3)."""
    return (6 + c) if r == 3 else (c * 3 + r)


def box_blur(g, w, h, radius):
    """Separable box blur, run 3x to approximate a gaussian. No scipy needed."""
    r = max(1, int(round(radius)))
    cur = [row[:] for row in g]
    for _ in range(3):
        tmp = [[0.0] * w for _ in range(h)]
        for y in range(h):
            row = cur[y]
            for x in range(w):
                a, b = max(0, x - r), min(w - 1, x + r)
                tmp[y][x] = sum(row[a:b + 1]) / (b - a + 1)
        nxt = [[0.0] * w for _ in range(h)]
        for x in range(w):
            col = [tmp[y][x] for y in range(h)]
            for y in range(h):
                a, b = max(0, y - r), min(h - 1, y + r)
                nxt[y][x] = sum(col[a:b + 1]) / (b - a + 1)
        cur = nxt
    return cur


def pct(vals, p):
    s = sorted(vals)
    return s[min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))]


def clamp01(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)


def soft_knee(x, k=V_KNEE):
    """Clip to 1.0 asymptotically instead of hard.

    A hard min(1, x) makes every deep-hue cell identical the moment its demanded
    v exceeds 1 -- and for a saturated hue that is most of the ramp, so the whole
    region goes tonally flat. This keeps the mapping strictly increasing, so a
    brighter cell still renders brighter even far past the joint.
    """
    if x < 0.0:
        return 0.0
    if x <= k:
        return x
    return k + (1.0 - k) * (1.0 - math.exp(-(x - k) / (1.0 - k)))


def dot_colours():
    """92x92 grid of linear-light (r,g,b), box-averaged from a 6x supersample."""
    n = SUPER
    im = Image.open(SRC).convert("RGB").resize((DW * n, DH * n), Image.LANCZOS)
    px = im.load()
    inv = 1.0 / (n * n)
    out = []
    for dy in range(DH):
        row = []
        y0 = dy * n
        for dx in range(DW):
            x0 = dx * n
            r = g = b = 0.0
            for yy in range(y0, y0 + n):
                for xx in range(x0, x0 + n):
                    p = px[xx, yy]
                    r += S2L[p[0]]; g += S2L[p[1]]; b += S2L[p[2]]
            row.append((r * inv, g * inv, b * inv))
        out.append(row)
    return out


def dither():
    """Return the 92x92 ink bitmap (unchanged pipeline from design #4)."""
    im = Image.open(SRC).convert("RGB").resize((DW, DH), Image.LANCZOS)
    px = im.load()
    base = [[(0.2126 * px[x, y][0] + 0.7152 * px[x, y][1] + 0.0722 * px[x, y][2]) / 255.0
             for x in range(DW)] for y in range(DH)]
    low = box_blur(base, DW, DH, BLUR_R)
    sharp = [[base[y][x] + SHARPEN * (base[y][x] - low[y][x])
              for x in range(DW)] for y in range(DH)]

    flat = [v for row in sharp for v in row]
    lo, hi = pct(flat, LO_PCT), pct(flat, HI_PCT)
    span = max(1e-6, hi - lo)
    grid = [[FLOOR + (clamp01((sharp[y][x] - lo) / span) ** GAMMA) * (CEIL - FLOOR)
             for x in range(DW)] for y in range(DH)]

    bits = [[0] * DW for _ in range(DH)]
    for y in range(DH):
        fwd = (y % 2 == 0)
        for x in (range(DW) if fwd else range(DW - 1, -1, -1)):
            old = grid[y][x]
            new = 1.0 if old >= 0.5 else 0.0
            bits[y][x] = int(new)
            err = old - new
            nx = 1 if fwd else -1
            for dx, dy, f in ((nx, 0, 7 / 16), (-nx, 1, 3 / 16),
                              (0, 1, 5 / 16), (nx, 1, 1 / 16)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < DW and 0 <= yy < DH:
                    grid[yy][xx] += err * f
    return bits


def esc(s):
    return html.escape(s).replace(" ", "&#160;")


def main():
    bits = dither()
    dots = dot_colours()

    # ---- one linear-light colour per CELL, from the inked dots ------------
    cells = []          # (h, s, luminance-of-source, inked?)
    lums = []
    for cr in range(ROWS):
        row = []
        for cc in range(COLS):
            r = g = b = 0.0
            ar = ag = ab = 0.0
            n = 0
            for dr in range(4):
                for dc in range(2):
                    p = dots[cr * 4 + dr][cc * 2 + dc]
                    ar += p[0]; ag += p[1]; ab += p[2]
                    if bits[cr * 4 + dr][cc * 2 + dc]:
                        r += p[0]; g += p[1]; b += p[2]; n += 1
            ar, ag, ab = ar / 8.0, ag / 8.0, ab / 8.0
            inked = n > 0
            if inked:
                r, g, b = r / n, g / n, b / n
            else:                               # renders nothing; keep a colour
                r, g, b = ar, ag, ab            # anyway so runs can merge
            # luminance from the INKED dots -- a dot is a piece of light, so the
            # shadow the cell declined to draw must not drag its level down.
            y = lin_to_srgb(0.2126 * r + 0.7152 * g + 0.0722 * b)
            # hue/sat from a blend toward the whole region, weighted by how many
            # dots actually voted: one lit dot is a noisy colour sample.
            a = n / (n + 2.0)
            cr_, cg_, cb_ = (a * r + (1 - a) * ar,
                             a * g + (1 - a) * ag,
                             a * b + (1 - a) * ab)
            # V comes back too: it gates the chroma. Saturation is a ratio and
            # survives all the way to black, where it is only noise.
            h, s, vs = colorsys.rgb_to_hsv(lin_to_srgb(cr_), lin_to_srgb(cg_),
                                           lin_to_srgb(cb_))
            row.append([h, s, vs, y, inked])
            if inked:
                lums.append(y)
        cells.append(row)

    ylo, yhi = pct(lums, 2.0), pct(lums, 99.0)
    yspan = max(1e-6, yhi - ylo)

    dknee = max(1e-6, CHROMA_DARK_KNEE - CHROMA_DARK_TOE)

    # ---- where the chroma cap lands, per cover ----------------------------
    # The quantile is taken on saturation ALREADY multiplied by the dark gate,
    # or it would be set by the very noise the gate exists to throw away: on
    # the ABBA cover the raw 80th percentile of S is 0.994 (dark gold on navy,
    # plus near-black border pixels), which would drive the knee to nonsense.
    eff = [c[1] * clamp01((c[2] - CHROMA_DARK_TOE) / dknee)
           for row in cells for c in row if c[4]]
    sat_knee = max(SAT_KNEE_MIN, pct(eff, SAT_KNEE_PCT)) if eff else SAT_KNEE_MIN
    knee = max(1e-6, sat_knee - SAT_TOE)

    def render(scale):
        """Build every cell's hex at a given luma-ramp scale; report peak luma."""
        grid, peaks = [], []
        for cr in range(ROWS):
            out = []
            for cc in range(COLS):
                h, s, vs, y, inked = cells[cr][cc]
                # --- chroma: toe, dark-gate, then a CONVEX lift pinned at
                #     the peak. The gate discounts a near-black cell's hue,
                #     which is JPEG noise, not colour.
                gate = clamp01((vs - CHROMA_DARK_TOE) / dknee)
                u = clamp01((s - SAT_TOE) / knee) * gate
                sat = SAT_MAX * (u ** SAT_POW)
                # --- luma: the ramp is a target BRIGHTNESS, not an HSV V ----
                t = clamp01((y - ylo) / yspan) ** LUM_POW
                target = (LUM_FLOOR + t * (LUM_PEAK - LUM_FLOOR)) * scale
                # solve v for that luma; chroma rides along as a ratio, so
                # saturating a cell no longer darkens it.
                fr, fg, fb = colorsys.hsv_to_rgb(h, sat, 1.0)
                l1 = 0.2126 * fr + 0.7152 * fg + 0.0722 * fb
                v = soft_knee(target / max(HUE_LUMA_FLOOR, l1))
                fr, fg, fb = colorsys.hsv_to_rgb(h, sat, v)
                rgb = tuple(min(CH_CLIP, int(round(c * 255))) for c in (fr, fg, fb))
                rgb = tuple(min(255, (c // QUANT) * QUANT + QUANT // 2) for c in rgb)
                out.append(rgb)
                if inked:
                    peaks.append(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2])
            grid.append(out)
        return grid, pct(peaks, 99.5)

    scale = 1.0
    for _ in range(8):                       # converge the ramp on PEAK_LUMA
        grid, p = render(scale)
        if abs(p - PEAK_LUMA) < 0.8:
            break
        # a cover whose brightest cells are all deep hues can never reach
        # PEAK_LUMA (pure red tops out at 54/255); cap the chase so it doesn't
        # run away and bleach every near-neutral cell to white.
        scale = min(2.4, scale * (PEAK_LUMA / max(1.0, p)) ** 0.85)
    grid, peak = render(scale)

    chars = []
    for cr in range(ROWS):
        line = []
        for cc in range(COLS):
            v = 0
            for dr in range(4):
                for dc in range(2):
                    if bits[cr * 4 + dr][cc * 2 + dc]:
                        v |= 1 << bit_for(dc, dr)
            line.append(chr(0x2800 + v))
        chars.append("".join(line))

    ink = sum(sum(r) for r in bits) / float(DW * DH)

    if "--json" in _sys.argv:
        # Machine mode for the CodeSaver feeds daemon. The metrics block is
        # the Apple Braille -> SF Mono grid fix, derived from the font files:
        # at 15px SF Mono (9.2725px advance), braille must render at
        # 19.6992px with -4.19377px tracking on an 18.8623px line.
        import json as _json
        print(_json.dumps({
            "style": "braille",
            "cols": COLS, "rows": ROWS, "ink": round(ink, 4),
            "chars": chars,
            "colors": [["#%02X%02X%02X" % grid[cr][cc] for cc in range(COLS)]
                       for cr in range(ROWS)],
            "metrics": {"fontSize": 19.6992, "letterSpacing": -4.19377,
                        "lineHeight": 18.8623, "baseFontSize": 15.0},
        }))
        return

    # ---- colour class table ----------------------------------------------
    order, idx = [], {}
    for cr in range(ROWS):
        for cc in range(COLS):
            if chars[cr][cc] == "⠀":     # blank: no ink, no colour needed
                continue
            k = grid[cr][cc]
            if k not in idx:
                idx[k] = len(order); order.append(k)
    css = "\n".join("    .c%d{color:#%02X%02X%02X}" % ((i,) + c)
                    for i, c in enumerate(order))

    art_rows = []
    for cr in range(ROWS):
        parts, run, cur = [], [], None
        for cc in range(COLS):
            ch = chars[cr][cc]
            k = None if ch == "⠀" else idx[grid[cr][cc]]
            if k is not None and cur is not None and k != cur:
                parts.append((cur, run)); run, cur = [], k
            elif k is not None and cur is None:
                cur = k
            run.append("&#%d;" % ord(ch))
        parts.append((cur, run))
        h = "".join(('<span class="c%d">%s</span>' % (k, "".join(r))) if k is not None
                    else "".join(r) for k, r in parts)
        art_rows.append('<div class="row art"><span class="r">&#9474;</span>&#160;'
                        '<span class="bd">' + h + "</span>"
                        '&#160;<span class="r">&#9474;</span></div>')

    # ---- panel chrome (identical to albumart-braille.html) ----------------
    top = ('<span class="r">&#9581;&#9472;</span>'
           '<span class="np">&#160;<span class="sym">&#9834;</span>&#160;now&#160;playing&#160;</span>'
           # 2 corner/dash + 15-cell label + dashes + 1 corner == TOTAL
           '<span class="r">' + "&#9472;" * (TOTAL - 18) + "&#9582;</span>")
    dashes = TOTAL - 3 - (len(APP) + 2)
    bot = ('<span class="r">&#9584;' + "&#9472;" * dashes + "</span>"
           '<span class="app">&#160;' + APP + "&#160;</span>"
           '<span class="r">&#9472;&#9583;</span>')

    def textrow(inner):
        return ('<div class="row"><span class="r">&#9474;</span>&#160;'
                + inner + '&#160;<span class="r">&#9474;</span></div>')

    def pad(s):
        return esc(s) + "&#160;" * (COLS - len(s))

    track = COLS - len(ELAPSED) - len(TOTALT) - 2
    pos = round(83 / 207 * (track - 1))
    prog = ('<span class="t">' + ELAPSED + "</span>&#160;"
            '<span class="bar">' + "&#9472;" * pos + "</span>"
            '<span class="dot">&#9679;</span>'
            '<span class="bar">' + "&#9472;" * (track - pos - 1) + "</span>"
            '&#160;<span class="t">' + TOTALT + "</span>")

    doc = f"""<!doctype html>
<meta charset="utf-8">
<title>CodeSaver &mdash; braille album art (colour)</title>
<style>
  html,body{{margin:0;padding:0;}}
  body{{
    width:1728px; height:1080px; overflow:hidden;
    background:#000 url('frame-0041.00s.png') no-repeat 0 0;
    background-size:1728px 1080px;
  }}
  .panel{{
    position:absolute; right:13px; bottom:17px;
    padding:9px 11px;
    background:rgba(0,0,0,0.9);
    font-family:'SF Mono','SFMono-Regular',ui-monospace,Menlo,monospace;
    font-size:{FS:.0f}px; line-height:{LH:.0f}px;
    -webkit-font-smoothing:antialiased;
  }}
  /* pre lives on the rows, NOT the container: with pre on .panel, the HTML
     source's newlines between row divs render as {LH:.0f}px blank lines. */
  .row{{height:{LH:.0f}px; white-space:pre;}}
  .r{{color:#4D4D4D;}}                 /* rounded rails */
  .np{{color:#4F595F;}}                /* label breaking the top rail */
  .sym{{display:inline-block;width:{CW:.4f}px;text-align:center;}}
  .app{{color:#59616B;}}
  .title{{color:#94A6B8;}}
  .artist{{color:#666;}}
  .t{{color:#7C8892;}}
  .bar{{color:#3D4247;}}
  .dot{{color:#A8E5FF;}}

  /* --- braille art block ------------------------------------------------
     SF Mono has no U+2800..U+28FF glyphs, so this run is rendered by Apple
     Braille (advance 0.68359em vs SF Mono's 0.61816em). The negative
     letter-spacing pulls the cell advance back onto the SF Mono column grid
     AND squares up the dot lattice, whose intra-cell pitch is 482 units
     against an inter-cell gap of 918.                                     */
  .art{{height:{ALH:.4f}px; line-height:{ALH:.4f}px;}}
  .bd{{
    font-family:'Apple Braille';
    font-size:{FB:.4f}px;
    letter-spacing:{BLS:.5f}px;
  }}

  /* per-cell true colour: linear-light mean of each cell's INKED dots, with a
     convex chroma lift (peak pinned, middle compressed) and a luma-first value
     solve, so a 26%-coverage halftone on black reads bright rather than muddy. */
{css}
</style>

<div class="panel">
  <div class="row">{top}</div>
{chr(10).join("  " + r for r in art_rows)}
  <div style="height:6px"></div>
  {textrow('<span class="title">' + pad(TITLE) + "</span>")}
  {textrow('<span class="artist">' + pad(ARTIST) + "</span>")}
  {textrow(prog)}
  <div class="row">{bot}</div>
</div>
"""
    open(OUT, "w").write(doc)
    print(f"# {COLS}x{ROWS} chars = {DW}x{DH} dots | ink {ink:.1%} | "
          f"{len(order)} colours | sat knee {sat_knee:.3f} | "
          f"value scale {scale:.3f} | peak luma {peak:.1f}")
    print(f"panel {TOTAL} cols = {TOTAL*CW + 22:.1f}px wide, "
          f"{LH + ROWS*ALH + 6 + 4*LH + 18:.1f}px tall")


if __name__ == "__main__":
    main()
