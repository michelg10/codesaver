#!/usr/bin/env python3
"""Sampling stage: build corpus.bin + corpus-index.json from the GitHub mirror
in ingest/cache/ (populated by ingest.py — run that first, occasionally).

corpus.bin        every cleaned source file, WHOLE, concatenated as UTF-8
corpus-index.json { "<repo>": [[byteOffset, byteLength], ...], ... }

No sampling happens here: selection and repo weighting are done at runtime,
which is why the index preserves repo provenance. Identical files appearing
in several repos are deduplicated by content hash.
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(ROOT, "ingest", "cache")

# This text renders on an always-visible screen, so scrub aggressively —
# a false positive only blanks one line of screensaver background.
SECRET_RES = [
    # key-ish identifier (with any tail, so password/SECRET_KEY/aws_access_key_id
    # all match) directly assigned
    re.compile(r"(api[_-]?key|passw|passwd|pwd|secret|token|credential"
               r"|private[_-]?key|access[_-]?key|signing[_-]?key|auth)[\w-]*\s*[:=]", re.I),
    # value-shaped: known token prefixes, JWTs, creds-in-URL
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"\bghp_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\."),
    re.compile(r"://[^/\s:]+:[^@\s]+@"),
]
PEM_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
MAX_SECRET_HITS = 3  # a file this secret-dense is dropped entirely
MAX_LINE_LEN = 200
MIN_LINES = 4


def clean_lines(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            raw = f.read().splitlines()
    except OSError:
        return None
    lines = []
    long_count = secret_hits = 0
    for line in raw:
        line = line.expandtabs(4).rstrip()
        line = "".join(ch for ch in line if ch == " " or ch.isprintable())
        if PEM_RE.search(line):
            return None  # never sample a file holding key material
        if any(r.search(line) for r in SECRET_RES):
            secret_hits += 1
            line = ""
        if len(line) > MAX_LINE_LEN:
            long_count += 1
            line = line[:MAX_LINE_LEN]
        lines.append(line)
    if secret_hits >= MAX_SECRET_HITS:
        return None
    if not lines or long_count > len(lines) * 0.3:  # likely minified/generated
        return None
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines if len(lines) >= MIN_LINES else None


def main(bin_path):
    if not os.path.isdir(CACHE) or not os.listdir(CACHE):
        sys.exit("ingest cache is empty — run ./ingest.py first")
    index_path = os.path.join(os.path.dirname(bin_path) or ".", "corpus-index.json")

    index = {}
    seen = set()
    offset = 0
    files = blocks = 0
    # Write to temp names and rename both at the end, so an interrupted run
    # can never leave a new corpus.bin next to a stale index (or vice versa).
    with open(bin_path + ".tmp", "wb") as out:
        for repo in sorted(os.listdir(CACHE)):
            base = os.path.join(CACHE, repo)
            if not os.path.isdir(base):
                continue
            for dirpath, _, filenames in os.walk(base):
                for name in sorted(filenames):
                    path = os.path.join(dirpath, name)
                    files += 1
                    try:
                        with open(path, "rb") as f:
                            digest = hashlib.sha1(f.read()).hexdigest()
                    except OSError:
                        continue
                    if digest in seen:  # same file vendored into several repos
                        continue
                    seen.add(digest)
                    lines = clean_lines(path)
                    if lines is None:
                        continue
                    data = ("\n".join(lines) + "\n").encode("utf-8")
                    out.write(data)
                    index.setdefault(repo, []).append([offset, len(data)])
                    offset += len(data)
                    blocks += 1

    with open(index_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(index, f, separators=(",", ":"), sort_keys=True)
    os.replace(bin_path + ".tmp", bin_path)
    os.replace(index_path + ".tmp", index_path)

    mb = offset / 1_048_576
    print(f"wrote {blocks} whole-file blocks from {len(index)} repos "
          f"({files} candidates) — {mb:.1f} MB -> {bin_path}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "corpus.bin")
