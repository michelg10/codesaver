#!/usr/bin/env python3
"""Ingest stage: mirror source files from every GitHub repo owned by OWNER
into ingest/cache/<repo>/, one tarball download per repo. Forks are excluded.
Repos are re-downloaded only when their pushedAt changes (tracked in
ingest/manifest.json); pass --force to re-download everything.

Requires an authenticated `gh` CLI. Run occasionally; make_corpus.py samples
from the cache at build time.
"""
import fnmatch
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.abspath(__file__))


def _conf_owner():
    try:
        with open(os.path.join(ROOT, "setup.conf")) as f:
            for line in f:
                if line.startswith("OWNER="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return None


OWNER = os.environ.get("CODESAVER_OWNER") or _conf_owner() or "michelg10"
INGEST_DIR = os.path.join(ROOT, "ingest")
CACHE = os.path.join(INGEST_DIR, "cache")
MANIFEST_PATH = os.path.join(INGEST_DIR, "manifest.json")

EXTS = {
    ".swift", ".py", ".js", ".jsx", ".ts", ".tsx", ".c", ".cc", ".cpp", ".h", ".hpp",
    ".m", ".mm", ".rs", ".go", ".java", ".kt", ".rb", ".sh", ".zsh", ".css", ".scss",
    ".html", ".vue", ".svelte", ".sql", ".metal", ".cu", ".hs", ".ml", ".lua", ".jl",
}
SKIP_DIRS = {
    "node_modules", ".git", "build", "dist", ".build", "Pods", "vendor", "venv",
    ".venv", "__pycache__", "DerivedData", ".next", "target", "out", ".cache",
}
GENERATED = [
    "*.min.js", "*.min.css", "*_pb2.py", "*.pb.go", "*.pb.cc", "*.pb.h",
    "*.generated.*", "*.g.dart", "*.bundle.js", "*.map",
]
MIN_SIZE, MAX_SIZE = 64, 200_000
MAX_DIR_FILES = 150       # more source files than this in one dir → vendored/generated
MAX_REPO_BYTES = 200 * 1024 * 1024  # sanity ceiling on extracted bytes per repo
REPO_LIMIT = 1000


def wanted(relpath, size):
    parts = relpath.split("/")
    if any(p in SKIP_DIRS or p.startswith(".") for p in parts[:-1]):
        return False
    name = parts[-1]
    if any(fnmatch.fnmatch(name, pat) for pat in GENERATED):
        return False
    if os.path.splitext(name)[1].lower() not in EXTS:
        return False
    return MIN_SIZE < size < MAX_SIZE


def extract(tar_bytes, dest):
    count = written = 0
    os.makedirs(dest, exist_ok=True)  # marker even for repos with no source files
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tf:
        for member in tf:
            if not member.isfile():
                continue
            parts = member.name.split("/")[1:]  # drop the owner-repo-sha/ prefix
            if not parts or ".." in parts:
                continue
            if not wanted("/".join(parts), member.size):
                continue
            if written + member.size > MAX_REPO_BYTES:
                print(f"    stopping extraction at {written // 1_048_576} MB (cap)", file=sys.stderr)
                break
            target = os.path.join(dest, *parts)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            src = tf.extractfile(member)
            with open(target, "wb") as f:
                shutil.copyfileobj(src, f)
            count += 1
            written += member.size
    return count


def prune_bulk_dirs(root):
    for dirpath, _, filenames in os.walk(root, topdown=False):
        if len(filenames) > MAX_DIR_FILES:
            shutil.rmtree(dirpath)
            rel = os.path.relpath(dirpath, root)
            print(f"    pruned {rel} ({len(filenames)} files)", file=sys.stderr)


def load_manifest():
    try:
        with open(MANIFEST_PATH) as f:
            return json.load(f)
    except OSError:
        return {}
    except json.JSONDecodeError:
        print("manifest.json is corrupt — ignoring it (everything re-downloads)", file=sys.stderr)
        return {}


def list_repos():
    try:
        out = subprocess.run(
            ["gh", "repo", "list", OWNER, "--source", "--limit", str(REPO_LIMIT),
             "--json", "name,pushedAt"],
            capture_output=True, text=True, check=True,
        ).stdout
    except FileNotFoundError:
        sys.exit("gh CLI not found — install it (https://cli.github.com) and run `gh auth login`")
    except subprocess.CalledProcessError as e:
        sys.exit(f"gh repo list failed:\n{e.stderr.strip()}")
    return json.loads(out)


def main():
    force = "--force" in sys.argv
    os.makedirs(CACHE, exist_ok=True)
    manifest = {} if force else load_manifest()

    repos = list_repos()
    truncated = len(repos) >= REPO_LIMIT
    if truncated:
        print(f"warning: repo list hit the {REPO_LIMIT} limit — skipping stale cleanup", file=sys.stderr)
    print(f"{len(repos)} source repos on github.com/{OWNER}", file=sys.stderr)

    def save(m):
        with open(MANIFEST_PATH, "w") as f:
            json.dump(m, f, indent=1, sort_keys=True)

    # Start from the loaded manifest so an interrupted run never forgets
    # repos it hasn't reached yet.
    fresh = dict(manifest)
    for repo in sorted(repos, key=lambda r: r["name"].lower()):
        name, pushed = repo["name"], repo["pushedAt"]
        dest = os.path.join(CACHE, name)
        if manifest.get(name) == pushed and os.path.isdir(dest):
            fresh[name] = pushed
            continue
        try:
            tar_bytes = subprocess.run(
                ["gh", "api", f"repos/{OWNER}/{name}/tarball"],
                capture_output=True, check=True,
            ).stdout
        except subprocess.CalledProcessError as e:
            print(f"  ! {name}: download failed ({e.stderr.decode(errors='ignore').strip()[:120]})",
                  file=sys.stderr)
            continue
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        try:
            count = extract(tar_bytes, dest)
            prune_bulk_dirs(dest)
        except Exception as e:  # one hostile/corrupt tarball must not kill the run
            print(f"  ! {name}: extraction failed ({e}) — skipped", file=sys.stderr)
            shutil.rmtree(dest, ignore_errors=True)
            fresh.pop(name, None)
            save(fresh)
            continue
        fresh[name] = pushed
        save(fresh)  # incremental, so an interrupted run resumes
        print(f"  + {name}: {count} source files", file=sys.stderr)

    # Drop cached copies (and manifest entries) of repos gone upstream.
    if not truncated:
        names = {r["name"] for r in repos}
        for stale in set(os.listdir(CACHE)) - names:
            path = os.path.join(CACHE, stale)
            if not os.path.isdir(path):
                continue  # .DS_Store and friends
            shutil.rmtree(path)
            print(f"  - {stale} (removed)", file=sys.stderr)
        fresh = {k: v for k, v in fresh.items() if k in names}

    save(fresh)
    total = sum(len(files) for _, _, files in os.walk(CACHE))
    print(f"cache: {total} source files across {len(fresh)} repos", file=sys.stderr)


if __name__ == "__main__":
    main()
