// CodeSaver's site: static files from ./public, plus one dynamic piece — the
// latest GitHub release, fetched server-side, cached, and rendered into the
// page (download button + "what's new") and exposed as GET /api/release.
//
// Runs on Bun (production, `ship app`) and on Node >= 23 for a local check
// (`node site/server.ts`). Contract: listens on $PORT at $HOST (127.0.0.1),
// writes only under $DATA_DIR, reaches GitHub through $HTTPS_PROXY.

import { readFile, writeFile, rename, mkdir, stat } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, normalize, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(HERE, "public");
const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || "127.0.0.1";
const DATA_DIR = process.env.DATA_DIR || "";
const REPO = process.env.CODESAVER_REPO || "michelg10/codesaver";
const REPO_URL = `https://github.com/${REPO}`;
const STABLE_DMG = `${REPO_URL}/releases/latest/download/CodeSaver.dmg`;
const FIXTURE = process.env.RELEASE_FIXTURE || ""; // local testing: a saved API response
const TTL_MS = 10 * 60 * 1000;
const RETRY_MS = 60 * 1000;
const isBun = typeof (globalThis as any).Bun !== "undefined";

// ── Release ────────────────────────────────────────────────────────────────

type Release =
  | { status: "released"; version: string; publishedAt: string; dmgSize: number | null;
      dmgUrl: string; pageUrl: string; notesHtml: string }
  | { status: "coming-soon"; repoUrl: string };

const SOON: Release = { status: "coming-soon", repoUrl: REPO_URL };
let cache: { release: Release; at: number; ok: boolean } | null = null;
let inflight: Promise<Release> | null = null;

const cacheFile = DATA_DIR ? join(DATA_DIR, "cache", "release.json") : "";

async function loadDiskCache() {
  if (!cacheFile) return;
  try {
    const saved = JSON.parse(await readFile(cacheFile, "utf8"));
    if (saved?.release?.status) cache = { release: saved.release, at: 0, ok: true }; // stale: refetch soon
  } catch {}
}

async function saveDiskCache(release: Release) {
  if (!cacheFile) return;
  try {
    await mkdir(dirname(cacheFile), { recursive: true });
    const tmp = `${cacheFile}.${process.pid}.tmp`;
    await writeFile(tmp, JSON.stringify({ release, savedAt: new Date().toISOString() }));
    await rename(tmp, cacheFile);
  } catch (e) {
    console.error("release cache write failed:", (e as Error).message);
  }
}

// GitHub already sanitizes body_html; this is a second, stricter pass so the
// page's CSP never has to loosen: no scripts, styles, frames, forms, images
// (they would be external requests), handlers, or javascript: URLs.
function sanitize(html: string): string {
  return html
    .replace(/<(script|style|iframe|object|embed|form|template|svg|math)\b[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<(script|style|iframe|object|embed|form|input|button|link|meta|base|svg|math|video|audio|source|picture)\b[^>]*>/gi, "")
    .replace(/<img\b[^>]*?\balt="([^"]*)"[^>]*>/gi, "$1")
    .replace(/<img\b[^>]*>/gi, "")
    .replace(/\s(on\w+|style|class|id|data-[\w-]+|aria-[\w-]+|dir|tabindex)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "")
    .replace(/\s(href|src)\s*=\s*("|')\s*(javascript|data|vbscript):[^"']*\2/gi, "")
    .replace(/<a\b(?![^>]*\brel=)/gi, '<a rel="noopener"');
}

function toRelease(j: any): Release {
  const assets: any[] = Array.isArray(j.assets) ? j.assets : [];
  const dmg =
    assets.find((a) => a?.name === "CodeSaver.dmg") ??
    assets.find((a) => typeof a?.name === "string" && a.name.toLowerCase().endsWith(".dmg"));
  const tag = String(j.tag_name || j.name || "").trim();
  return {
    status: "released",
    version: tag ? (/^v\d/i.test(tag) ? tag : /^\d/.test(tag) ? `v${tag}` : tag) : "latest",
    publishedAt: String(j.published_at || j.created_at || ""),
    dmgSize: dmg && Number.isFinite(dmg.size) ? Number(dmg.size) : null,
    dmgUrl: dmg?.browser_download_url || String(j.html_url || STABLE_DMG),
    pageUrl: String(j.html_url || `${REPO_URL}/releases/latest`),
    notesHtml: sanitize(String(j.body_html || "")),
  };
}

async function fetchRelease(): Promise<{ release: Release; ok: boolean }> {
  if (FIXTURE) {
    if (FIXTURE === "none") return { release: SOON, ok: true };
    return { release: toRelease(JSON.parse(await readFile(FIXTURE, "utf8"))), ok: true };
  }
  const headers: Record<string, string> = {
    Accept: "application/vnd.github.html+json",
    "User-Agent": "codesaver-site (+https://codesaver.michelg10.com)",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const init: any = { headers, signal: AbortSignal.timeout(6000) };
  // Bun honours $HTTPS_PROXY on its own; naming it explicitly costs nothing.
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
  if (isBun && proxy) init.proxy = proxy;
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, init);
  if (res.status === 404) return { release: SOON, ok: true }; // no release published yet
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  return { release: toRelease(await res.json()), ok: true };
}

function refresh(): Promise<Release> {
  if (inflight) return inflight;
  inflight = fetchRelease()
    .then(({ release }) => {
      cache = { release, at: Date.now(), ok: true };
      void saveDiskCache(release);
      return release;
    })
    .catch((e) => {
      console.error("release fetch failed:", (e as Error).message);
      // Keep serving what we had; try again in a minute instead of ten.
      const release = cache?.release ?? SOON;
      cache = { release, at: Date.now() - TTL_MS + RETRY_MS, ok: false };
      return release;
    })
    .finally(() => { inflight = null; });
  return inflight;
}

async function getRelease(): Promise<Release> {
  if (cache && Date.now() - cache.at < TTL_MS) return cache.release;
  if (cache) { void refresh(); return cache.release; } // stale-while-revalidate
  // Cold start: wait briefly, never hold a page hostage to GitHub.
  return Promise.race([refresh(), new Promise<Release>((r) => setTimeout(() => r(SOON), 2500))]);
}

// ── Rendering ──────────────────────────────────────────────────────────────

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const fmtSize = (b: number | null) => (b ? `${(b / 1e6).toFixed(b < 1e7 ? 1 : 0)} MB` : "");
const fmtDate = (iso: string) => {
  const d = new Date(iso);
  return isNaN(+d) ? "" : d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
};
const META = `<p class="get__meta">free · open source · macOS 14+ · universal</p>`;

function renderGet(r: Release): string {
  if (r.status === "released") {
    const size = fmtSize(r.dmgSize);
    const label = `download ${esc(r.version)}${size ? ` · ${size}` : ""}`;
    return `<div class="get__row"><a class="btn" href="${esc(r.dmgUrl)}" data-version="${esc(r.version)}"><span aria-hidden="true">↓ </span>${label}</a>` +
      `<a class="get__alt" href="${esc(REPO_URL)}">build from source</a></div>${META}`;
  }
  return `<p class="get__soon"><span class="g" aria-hidden="true">✽</span> first release coming soon</p>` +
    `<div class="get__row"><a class="btn" href="${esc(REPO_URL)}">build from source</a>` +
    `<a class="get__alt" href="${esc(REPO_URL)}/releases">watch for releases</a></div>${META}`;
}

function renderNotes(r: Release): string {
  if (r.status !== "released") {
    return `<p class="lead">No release yet. The first build is on its way.</p>` +
      `<p>Until then, CodeSaver builds from source with Xcode 15 or later:</p>` +
      `<pre class="code" tabindex="0"><code>git clone ${esc(REPO_URL)}\ncd codesaver\n./appex/install.sh\nopen /Applications/CodeSaver.app</code></pre>`;
  }
  const date = fmtDate(r.publishedAt);
  const notes = r.notesHtml.trim() || `<p>Release notes are on <a href="${esc(r.pageUrl)}">GitHub</a>.</p>`;
  return `<p class="lead"><span class="g g--done" aria-hidden="true">✻</span> ${esc(r.version)}` +
    `${date ? ` <span class="dim">· <time datetime="${esc(r.publishedAt)}">${esc(date)}</time></span>` : ""}</p>` +
    `<div class="notes">${notes}</div><p><a href="${esc(r.pageUrl)}">all releases on GitHub</a></p>`;
}

function fill(html: string, slot: string, content: string): string {
  const re = new RegExp(`(<!--release:${slot}-->)[\\s\\S]*?(<!--/release:${slot}-->)`, "g");
  return html.replace(re, (_m, a, b) => `${a}${content}${b}`);
}

// ── Static files ───────────────────────────────────────────────────────────

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
  ".svg": "image/svg+xml", ".ico": "image/x-icon", ".mp4": "video/mp4", ".webm": "video/webm",
  ".txt": "text/plain; charset=utf-8", ".webmanifest": "application/manifest+json",
};

// CSP: everything from this origin, nothing inline except the exact scripts
// the pages carry (hashed at boot), no external requests at all.
function cspFor(html: string): string {
  const hashes = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
    .map((m) => `'sha256-${createHash("sha256").update(m[1]).digest("base64")}'`);
  return [
    "default-src 'self'", `script-src 'self' ${hashes.join(" ")}`.trim(), "style-src 'self'",
    "img-src 'self' data:", "media-src 'self'", "connect-src 'self'", "font-src 'self'",
    "object-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
  ].join("; ");
}

const BASE_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), interest-cohort=()",
};

let pages: { index: string; notFound: string; indexCsp: string; notFoundCsp: string } | null = null;
// Cloudflare stretches every asset's browser TTL to hours whatever this
// server sends, so the pages name their CSS and JS by content: a deploy
// changes the URL, and a phone holding the old file fetches the new one.
async function stamp(html: string): Promise<string> {
  for (const f of ["styles.css", "app.js"]) {
    const v = createHash("sha256").update(await readFile(join(PUBLIC, f))).digest("hex").slice(0, 10);
    html = html.replace(new RegExp(`(["/])${f.replace(".", "\\.")}"`, "g"), `$1${f}?v=${v}"`);
  }
  return html;
}

async function loadPages() {
  if (pages && process.env.NODE_ENV === "production") return pages;
  const index = await stamp(await readFile(join(PUBLIC, "index.html"), "utf8"));
  const notFound = await stamp(await readFile(join(PUBLIC, "404.html"), "utf8"));
  pages = { index, notFound, indexCsp: cspFor(index), notFoundCsp: cspFor(notFound) };
  return pages;
}

function cacheControl(path: string): string {
  if (/\.(html|css|js|json)$/.test(path)) return "no-cache"; // revalidate (304s): no stale JS after a deploy
  if (path.includes(`${sep}media${sep}`)) return "public, max-age=86400";
  if (path.includes(`${sep}icons${sep}`)) return "public, max-age=604800";
  return "public, max-age=600";
}

function fileBody(path: string, start?: number, end?: number): any {
  if (isBun) {
    const f = (globalThis as any).Bun.file(path);
    return start === undefined ? f : f.slice(start, end! + 1);
  }
  const s = createReadStream(path, start === undefined ? {} : { start, end });
  return new ReadableStream({
    start(c) {
      s.on("data", (d) => c.enqueue(typeof d === "string" ? new TextEncoder().encode(d) : new Uint8Array(d)));
      s.on("end", () => c.close());
      s.on("error", (e) => c.error(e));
    },
    cancel() { s.destroy(); },
  });
}

async function serveStatic(req: Request, pathname: string): Promise<Response | null> {
  let rel: string;
  try { rel = decodeURIComponent(pathname); } catch { return null; }
  if (rel.includes("\0")) return null;
  let path = normalize(join(PUBLIC, rel));
  if (path !== PUBLIC && !path.startsWith(PUBLIC + sep)) return null;
  let st = await stat(path).catch(() => null);
  if (st?.isDirectory()) { path = join(path, "index.html"); st = await stat(path).catch(() => null); }
  if (!st?.isFile()) return null;
  if (/(^|[\\/])\./.test(path.slice(PUBLIC.length))) return null; // dotfiles stay private

  const headers: Record<string, string> = {
    ...BASE_HEADERS,
    "Content-Type": TYPES[extname(path).toLowerCase()] || "application/octet-stream",
    "Cache-Control": cacheControl(path),
    "Last-Modified": st.mtime.toUTCString(),
    "Accept-Ranges": "bytes",
  };
  const ims = req.headers.get("if-modified-since");
  if (ims && Math.floor(+st.mtime / 1000) <= Math.floor(Date.parse(ims) / 1000)) {
    return new Response(null, { status: 304, headers });
  }
  const size = st.size;
  const range = req.headers.get("range");
  const m = range && /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (m && (m[1] || m[2])) {
    let start = m[1] ? Number(m[1]) : Math.max(0, size - Number(m[2]));
    let end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
    if (start >= size || start > end) {
      return new Response(null, { status: 416, headers: { ...headers, "Content-Range": `bytes */${size}` } });
    }
    headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
    headers["Content-Length"] = String(end - start + 1);
    return new Response(req.method === "HEAD" ? null : fileBody(path, start, end), { status: 206, headers });
  }
  headers["Content-Length"] = String(size);
  return new Response(req.method === "HEAD" ? null : fileBody(path), { status: 200, headers });
}

// ── Routes ─────────────────────────────────────────────────────────────────

async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const p = url.pathname;
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method not allowed\n", { status: 405, headers: { ...BASE_HEADERS, Allow: "GET, HEAD" } });
  }
  try {
    if (p === "/api/release") {
      const r = await getRelease();
      return new Response(JSON.stringify(r), {
        headers: { ...BASE_HEADERS, "Content-Type": "application/json; charset=utf-8",
                   "Cache-Control": "public, max-age=300", "Access-Control-Allow-Origin": "*" },
      });
    }
    if (p === "/" || p === "/index.html") {
      const pg = await loadPages();
      const r = await getRelease();
      let html = fill(pg.index, "hero", renderGet(r));
      html = fill(html, "setup", renderGet(r));
      html = fill(html, "notes", renderNotes(r));
      return new Response(req.method === "HEAD" ? null : html, {
        headers: { ...BASE_HEADERS, "Content-Type": TYPES[".html"], "Cache-Control": "no-cache",
                   "Content-Security-Policy": pg.indexCsp },
      });
    }
    const res = await serveStatic(req, p);
    if (res) return res;
    const pg = await loadPages();
    return new Response(req.method === "HEAD" ? null : pg.notFound, {
      status: 404,
      headers: { ...BASE_HEADERS, "Content-Type": TYPES[".html"], "Cache-Control": "no-cache",
                 "Content-Security-Policy": pg.notFoundCsp },
    });
  } catch (e) {
    console.error(`${req.method} ${p} failed:`, e);
    return new Response("internal error\n", { status: 500, headers: BASE_HEADERS });
  }
}

await loadDiskCache();
void refresh();

if (isBun) {
  (globalThis as any).Bun.serve({ port: PORT, hostname: HOST, fetch: handle });
} else {
  const http = await import("node:http");
  const { Readable } = await import("node:stream");
  http.createServer(async (req, res) => {
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) if (typeof v === "string") headers.set(k, v);
    const out = await handle(new Request(`http://${req.headers.host || "localhost"}${req.url}`,
                                         { method: req.method, headers }));
    res.writeHead(out.status, Object.fromEntries(out.headers));
    if (out.body) Readable.fromWeb(out.body as any).pipe(res); else res.end();
  }).listen(PORT, HOST);
}
console.log(`codesaver site on http://${HOST}:${PORT} (${isBun ? "bun" : "node"}, repo ${REPO})`);
