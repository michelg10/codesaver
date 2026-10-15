#!/bin/zsh
# Regenerate the sample code CodeSaver types before it has anyone's own:
#   ./scripts/make-sample-corpus.sh
#
# Writes appex/CodeSaverExtension/Resources/sample-corpus.bin + sample-corpus-
# index.json, the same pair CodeSaver.app writes into the app-group container
# (blocks packed back to back, a JSON index of [offset, length] per key, the
# index's last byte = the bin's last byte), so the saver reads it with the
# reader it already has. Both the saver and the app's hero fall back to it
# whenever the container holds no corpus; a user's own code always wins.
#
# The text is CodeSaver's own MIT-licensed source — Swift, Python and shell —
# cut into ~90-line blocks, never the whole tree: past SHARE bytes a file
# keeps evenly spaced blocks worth √(size·SHARE), which holds the bundle near
# 250 KB and lets the saver's long files show the most without a 5,000-line
# view crowding out the short ones (the writers pick blocks uniformly). Each
# file is its own index key, so the reader's per-repo share cap never bites.
# Lines naming Michel or pointing at private paths are dropped: this ships
# inside every download and types on strangers' screens.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=appex/CodeSaverExtension/Resources
SHARE=${SHARE:-6000}

exec python3 -I - "$OUT" "$SHARE" <<'PY'
import json, os, re, subprocess, sys, unicodedata

out_dir, share = sys.argv[1], int(sys.argv[2])

# Tracked files plus new ones not yet added, minus anything .gitignore'd —
# build products, SourcePackages checkouts and scratch never get in.
listed = subprocess.run(
    ["git", "ls-files", "-co", "--exclude-standard", "--", "*.swift", "*.py", "*.sh"],
    capture_output=True, text=True, check=True).stdout.splitlines()

# Whole files left out: the feeds daemon and its checks speak to one
# household's home-control bus and proxy spools — nothing a stranger's
# screen should be typing.
EXCLUDE = {"appex/CodeSaver/FeedsService.swift", "Sources/FeedsCheck.swift"}

# A line matching any of these is dropped outright (the gap is invisible in
# a 20-line typed window): the author's name and handle, home-directory and
# private-tool paths, email addresses, the signing team.
PRIVATE = re.compile(
    r"michel|/Users/|~/(bin|Desktop|Documents|Downloads|\.bifrocate)\b|bifrocate"
    r"|home-?control|homectl|miniforge|9K2XM38XLK|[\w.+-]+@[\w-]+\.[a-z]{2,}",
    re.IGNORECASE)
# Never sample a file holding key material, or anything token-shaped.
SECRET = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----|\bghp_[A-Za-z0-9]{20,}"
                    r"|\bgithub_pat_\w{20,}|\bsk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}")

CHUNK, CHUNK_MIN, CHUNK_MAX = 90, 60, 120
MAX_LINE = 200   # what CorpusIngest clips to

def clean(text):
    text = unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    for raw in text.split("\n"):
        line = "".join(c for c in raw.expandtabs(4)
                       if c == " " or c in "‌‍"
                       or unicodedata.category(c)[0] != "C").rstrip()
        if SECRET.search(line):
            return None
        if PRIVATE.search(line):
            continue
        lines.append(line[:MAX_LINE])
    return lines

def chunks(lines):
    """~CHUNK-line blocks, cut at a blank line when one falls in range."""
    out, i = [], 0
    while i < len(lines):
        end = min(len(lines), i + CHUNK)
        if end < len(lines):
            blanks = [j for j in range(i + CHUNK_MIN, min(len(lines), i + CHUNK_MAX))
                      if not lines[j].strip()]
            if blanks:
                end = min(blanks, key=lambda j: abs(j - (i + CHUNK)))
        block = lines[i:end]
        while block and not block[0].strip(): block.pop(0)
        while block and not block[-1].strip(): block.pop()
        if sum(1 for l in block if l.strip()) >= 8:
            out.append(("\n".join(block) + "\n").encode())
        i = end
    return out

blob, index, langs = bytearray(), {}, {}
for path in sorted(set(listed) - EXCLUDE):
    try:
        with open(path, encoding="utf-8") as f:
            lines = clean(f.read())
    except (OSError, UnicodeDecodeError):
        continue
    if not lines:
        continue
    blocks = chunks(lines)
    total = sum(map(len, blocks))
    budget = (total * share) ** 0.5   # past SHARE bytes, a file keeps √(size·SHARE)
    if total > budget and blocks:
        # Evenly spaced across the file, so a long one shows its range.
        keep = max(1, round(len(blocks) * budget / total))
        step = len(blocks) / keep
        blocks = [blocks[int(k * step + step / 2)] for k in range(keep)]
    for b in blocks:
        index.setdefault(path, []).append([len(blob), len(b)])
        blob += b
        ext = path.rsplit(".", 1)[-1]
        langs[ext] = langs.get(ext, 0) + len(b)

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "sample-corpus.bin"), "wb") as f:
    f.write(blob)
with open(os.path.join(out_dir, "sample-corpus-index.json"), "w") as f:
    json.dump(index, f, sort_keys=True, separators=(",", ":"))

print(f"sample corpus: {len(index)} files, {sum(map(len, index.values()))} blocks, "
      f"{len(blob) / 1024:.0f} KB (" +
      ", ".join(f"{k} {v / 1024:.0f} KB" for k, v in sorted(langs.items())) + f") → {out_dir}")
PY
