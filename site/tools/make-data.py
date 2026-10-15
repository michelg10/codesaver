#!/usr/bin/env python3
"""Regenerates site/public/data.json: the hero's sample code and spinner verbs.

Sample code comes from CodeSaver's own MIT source (Swift, Python, shell) as
chunks of consecutive lines, the way the saver samples a corpus. A chunk is
dropped whole if any line mentions Michel, his private tooling or paths, or
looks like a secret; lines are tab-expanded and long chunks trimmed.

Verbs come from the saver's bundled list, minus the ones that read badly on a
public page with no context (brand puns, crude ones, private in-jokes).

    python3 site/tools/make-data.py            # from the repo root
"""
import json, os, random, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "site", "public", "data.json")

SOURCES = [
    "appex/CodeSaverExtension/CodeSaverView.swift",
    "appex/CodeSaverExtension/BoomCore.swift",
    "appex/CodeSaver/AlbumArtRamp.swift",
    "appex/CodeSaver/CorpusStore.swift",
    "appex/CodeSaver/GitHubCorpusFetcher.swift",
    "appex/CodeSaver/RefreshService.swift",
    "feeds/cc-state-hook.py",
    "build.sh",
]
FORBIDDEN = re.compile(
    r"michel|~/bin|/bin/|michelg10|bifrocate|home-?control|homectl|keychain|token\s*=|"
    r"secret|password|passwd|bearer|/Users/|@rice|apple id|TEAM_ID|teamid",
    re.I,
)
VERB_DENY = {
    "Relapsing", "Rehabing", "Codexing", "ByteDancin'", "Nuking", "Orphaning", "ChatGPTing",
    "Masculinating", "Choking", "Slapping", "BitDancin'", "Chinaing", "IB Risktaking",
    "CodeAssigning", "TikToking", "Drinking", "Stedouble1aing", "Jessing", "Cheating",
    "Edging", "Exposing", "Smurfing", "Shitposting", "WeChatting", "DeepSeeking",
    "Rawdogging", "Smoking", "Lying", "S&Ming", "Forking parents", "Killing child",
    "Replicating slaves", "Electing masters", "Fingering users", "Haluluing",
    "Matchamacalliting", "Omniauraling", "Ratatatouing", "Embedding spyware",
    "Claudemaxxing", "Claudestining", "Sunnying", "Slopperating", "Gene-iusing", "侬好ing",
}


def chunks_from(path, rng, want):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        lines = [l.rstrip("\n").expandtabs(4).rstrip() for l in f]
    out, tries = [], 0
    while len(out) < want and tries < want * 40:
        tries += 1
        n = rng.randint(4, 11)
        i = rng.randrange(0, max(1, len(lines) - n))
        chunk = lines[i:i + n]
        # Skip chunks that are mostly blank or start mid-expression on a blank.
        if not chunk[0].strip() or sum(1 for l in chunk if l.strip()) < 3:
            continue
        if any(FORBIDDEN.search(l) for l in chunk):
            continue
        if any(len(l) > 96 for l in chunk):
            continue
        if any(ord(c) > 0x2FFF for l in chunk for c in l):
            continue
        # Common indentation goes, like the saver's de-dent.
        ind = min((len(l) - len(l.lstrip(" ")) for l in chunk if l.strip()), default=0)
        chunk = [l[ind:] if l.strip() else "" for l in chunk]
        while chunk and not chunk[-1].strip():
            chunk.pop()
        key = "\n".join(chunk)
        if any(key == "\n".join(c) for c in out):
            continue
        out.append(chunk)
    return out


def main():
    rng = random.Random(0xC0DE5AFE)
    code = []
    for p in SOURCES:
        want = 10 if p.endswith("CodeSaverView.swift") else 5
        code += chunks_from(p, rng, want)
    rng.shuffle(code)

    verbs = []
    vpath = os.path.join(ROOT, "appex/CodeSaverExtension/Resources/spinner-verbs.txt")
    with open(vpath, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2 and parts[0] not in VERB_DENY:
                verbs.append(parts)

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"code": code, "verbs": verbs}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{OUT}: {len(code)} chunks, {len(verbs)} verbs, {os.path.getsize(OUT)} bytes")


if __name__ == "__main__":
    sys.exit(main())
