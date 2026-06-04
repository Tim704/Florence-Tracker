#!/usr/bin/env python3
"""
Florence's Seismic Travel Bureau -- zero-dependency server.

Serves the static web app and proxies + caches the USGS earthquake GeoJSON
feeds, so the app keeps working when the upstream is briefly unreachable
(ideal for an always-on Raspberry Pi kiosk on a flaky network).

Standard library only -- no pip install, runs on the Python that ships with
Raspberry Pi OS (3.7+).

Configuration (environment variables, all optional):
  FLORENCE_HOST        bind address              (default 0.0.0.0)
  FLORENCE_PORT        bind port                 (default 8080)
  FLORENCE_STATIC_DIR  web root to serve         (default <repo>/public)
  FLORENCE_CACHE_DIR   on-disk feed cache        (default <repo>/cache)
  FLORENCE_CACHE_TTL   feed freshness in seconds (default 60)
  FLORENCE_UPSTREAM    USGS summary feed base    (default the USGS v1.0 summary URL)
  FLORENCE_TIMEOUT     upstream fetch timeout    (default 12)
  FLORENCE_LOG         log level                 (default INFO)
"""

import json
import logging
import mimetypes
import os
import posixpath
import signal
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, unquote, urlparse
from urllib.request import Request, urlopen

VERSION = "1.0.0"
START_TIME = time.time()

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))


def _env(name, default):
    val = os.environ.get(name)
    return default if val is None or val == "" else val


HOST = _env("FLORENCE_HOST", "0.0.0.0")
PORT = int(_env("FLORENCE_PORT", "8080"))
STATIC_DIR = os.path.abspath(_env("FLORENCE_STATIC_DIR", os.path.join(HERE, "public")))
CACHE_DIR = os.path.abspath(_env("FLORENCE_CACHE_DIR", os.path.join(HERE, "cache")))
CACHE_TTL = float(_env("FLORENCE_CACHE_TTL", "60"))
UPSTREAM = _env(
    "FLORENCE_UPSTREAM",
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/",
).rstrip("/") + "/"
TIMEOUT = float(_env("FLORENCE_TIMEOUT", "12"))
USER_AGENT = "FlorenceSeismicBureau/%s (+https://github.com/florence-tracker)" % VERSION

# Canonical USGS summary feed ids are {significance}_{window}. We validate every
# requested id against this allow-list so /api/feed can never be turned into an
# open proxy / SSRF vector.
_SIGNIFICANCE = ("significant", "4.5", "2.5", "1.0", "all")
_WINDOW = ("hour", "day", "week", "month")
ALLOWED_FEEDS = frozenset(
    "%s_%s" % (s, w) for s in _SIGNIFICANCE for w in _WINDOW
)

log = logging.getLogger("florence")


# ----------------------------------------------------------------------------
# feed cache
# ----------------------------------------------------------------------------
class FeedCache:
    """In-memory + on-disk cache of USGS feeds with conditional refresh.

    Fresh (< TTL): served from memory, no upstream call.
    Stale: a single conditional GET is made; on success the cache updates, on
    failure (or a 304) the last-good copy keeps being served. The on-disk copy
    means a fresh restart can serve real data instantly even while offline.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._fetch_locks = {}        # id -> Lock (avoid herd of upstream fetches)
        self._mem = {}                # id -> entry dict
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
        except OSError as exc:
            log.warning("cache dir unavailable (%s); running memory-only", exc)
        self._load_disk()

    # -- disk persistence ----------------------------------------------------
    def _paths(self, feed_id):
        return (
            os.path.join(CACHE_DIR, feed_id + ".geojson"),
            os.path.join(CACHE_DIR, feed_id + ".meta.json"),
        )

    def _load_disk(self):
        if not os.path.isdir(CACHE_DIR):
            return
        for name in os.listdir(CACHE_DIR):
            if not name.endswith(".geojson"):
                continue
            feed_id = name[: -len(".geojson")]
            if feed_id not in ALLOWED_FEEDS:
                continue
            body_path, meta_path = self._paths(feed_id)
            try:
                with open(body_path, "rb") as fh:
                    body = fh.read()
                meta = {}
                if os.path.exists(meta_path):
                    with open(meta_path, "r") as fh:
                        meta = json.load(fh)
                self._mem[feed_id] = {
                    "body": body,
                    "fetched_at": float(meta.get("fetched_at", 0)),
                    "etag": meta.get("etag"),
                    "last_modified": meta.get("last_modified"),
                    "count": meta.get("count"),
                    "generated": meta.get("generated"),
                    "ok": True,
                    "error": None,
                }
                log.info("loaded cached feed %s (%d bytes) from disk", feed_id, len(body))
            except (OSError, ValueError) as exc:
                log.warning("could not load cached feed %s: %s", feed_id, exc)

    def _save_disk(self, feed_id, entry):
        if not os.path.isdir(CACHE_DIR):
            return
        body_path, meta_path = self._paths(feed_id)
        try:
            # write-then-rename so a crash mid-write can't corrupt the cache
            tmp = body_path + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(entry["body"])
            os.replace(tmp, body_path)
            with open(meta_path, "w") as fh:
                json.dump(
                    {
                        "fetched_at": entry["fetched_at"],
                        "etag": entry["etag"],
                        "last_modified": entry["last_modified"],
                        "count": entry["count"],
                        "generated": entry["generated"],
                    },
                    fh,
                )
        except OSError as exc:
            log.warning("could not persist feed %s: %s", feed_id, exc)

    # -- locking helper ------------------------------------------------------
    def _fetch_lock(self, feed_id):
        with self._lock:
            lk = self._fetch_locks.get(feed_id)
            if lk is None:
                lk = threading.Lock()
                self._fetch_locks[feed_id] = lk
            return lk

    # -- public API ----------------------------------------------------------
    def get(self, feed_id):
        """Return (body_bytes, status) where status is fresh|stale|live.

        Raises RuntimeError if there is no cached copy and the fetch failed.
        """
        with self._lock:
            entry = self._mem.get(feed_id)
        now = time.time()
        if entry and (now - entry["fetched_at"]) < CACHE_TTL:
            return entry["body"], "fresh"

        # Serialize refresh per feed so concurrent clients don't all hammer USGS.
        with self._fetch_lock(feed_id):
            with self._lock:
                entry = self._mem.get(feed_id)
            now = time.time()
            if entry and (now - entry["fetched_at"]) < CACHE_TTL:
                return entry["body"], "fresh"
            try:
                refreshed = self._fetch(feed_id, entry)
                with self._lock:
                    self._mem[feed_id] = refreshed
                self._save_disk(feed_id, refreshed)
                return refreshed["body"], "live"
            except Exception as exc:  # noqa: BLE001 - any failure -> serve stale
                log.warning("upstream fetch failed for %s: %s", feed_id, exc)
                if entry and entry.get("body"):
                    with self._lock:  # keep all entry field writes under the lock
                        entry["ok"] = False
                        entry["error"] = str(exc)
                    return entry["body"], "stale"
                raise RuntimeError(str(exc))

    def _fetch(self, feed_id, prev):
        url = UPSTREAM + feed_id + ".geojson"
        headers = {"User-Agent": USER_AGENT, "Accept": "application/geo+json, application/json"}
        if prev:
            if prev.get("etag"):
                headers["If-None-Match"] = prev["etag"]
            if prev.get("last_modified"):
                headers["If-Modified-Since"] = prev["last_modified"]
        req = Request(url, headers=headers)
        try:
            resp = urlopen(req, timeout=TIMEOUT)
        except HTTPError as exc:
            if exc.code == 304 and prev and prev.get("body"):
                # upstream unchanged -- mark fresh again, keep the body
                prev = dict(prev)
                prev["fetched_at"] = time.time()
                prev["ok"] = True
                prev["error"] = None
                return prev
            raise
        with resp:
            body = resp.read()
            etag = resp.headers.get("ETag")
            last_modified = resp.headers.get("Last-Modified")
        count, generated = self._metadata(body)
        return {
            "body": body,
            "fetched_at": time.time(),
            "etag": etag,
            "last_modified": last_modified,
            "count": count,
            "generated": generated,
            "ok": True,
            "error": None,
        }

    @staticmethod
    def _metadata(body):
        # Pull just metadata.count / metadata.generated for /healthz. Skip huge
        # payloads (e.g. all_month) so we never burn a Pi's CPU parsing tens of MB.
        if len(body) > 8 * 1024 * 1024:
            return None, None
        try:
            meta = json.loads(body.decode("utf-8")).get("metadata", {})
            return meta.get("count"), meta.get("generated")
        except (ValueError, AttributeError):
            return None, None

    def stats(self):
        out = {}
        now = time.time()
        with self._lock:
            for feed_id, entry in self._mem.items():
                out[feed_id] = {
                    "age_s": round(now - entry["fetched_at"], 1),
                    "bytes": len(entry["body"]),
                    "count": entry.get("count"),
                    "generated": entry.get("generated"),
                    "last_fetch_ok": entry.get("ok", True),
                    "last_error": entry.get("error"),
                }
        return out


CACHE = FeedCache()


# ----------------------------------------------------------------------------
# HTTP handler
# ----------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "FlorenceBureau/" + VERSION
    protocol_version = "HTTP/1.1"  # keep-alive; we always send Content-Length
    timeout = 60  # drop idle keep-alive connections so threads/fds can't pile up

    # -- low-level send helpers ---------------------------------------------
    def _send(self, code, body, content_type, extra_headers=None, head_only=False):
        if isinstance(body, str):
            body = body.encode("utf-8")
        # once we've begun a response, _route must not try to emit a second one
        self._response_started = True
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer-when-downgrade")
        for key, val in (extra_headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        if not head_only and self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, code, obj, extra_headers=None):
        payload = json.dumps(obj).encode("utf-8")
        self._send(code, payload, "application/json; charset=utf-8", extra_headers)

    # -- routing -------------------------------------------------------------
    def do_GET(self):
        self._route()

    def do_HEAD(self):
        self._route()

    def _route(self):
        self._response_started = False
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/healthz":
                return self._handle_health()
            if path == "/api/feeds":
                return self._handle_feed_list()
            if path == "/api/feed":
                return self._handle_feed(parse_qs(parsed.query))
            return self._handle_static(path)
        except ConnectionError:
            # client (browser/kiosk Wi-Fi) dropped mid-response; abandon this
            # connection rather than risk writing onto a half-sent stream.
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001 - last-resort 500, keep server up
            log.exception("unhandled error serving %s", self.path)
            if self._response_started:
                # headers/body already committed -> a second response would
                # desync keep-alive framing; just drop the connection.
                self.close_connection = True
            else:
                try:
                    self._send_json(500, {"error": "internal", "detail": str(exc)})
                except Exception:
                    self.close_connection = True

    # -- endpoints -----------------------------------------------------------
    def _handle_health(self):
        body = {
            "status": "ok",
            "service": "florence-seismic-bureau",
            "version": VERSION,
            "uptime_s": round(time.time() - START_TIME, 1),
            "now": datetime.now(timezone.utc).isoformat(),
            "upstream": UPSTREAM,
            "cache_ttl_s": CACHE_TTL,
            "static_dir": STATIC_DIR,
            "feeds": CACHE.stats(),
        }
        self._send_json(200, body, {"Cache-Control": "no-store"})

    def _handle_feed_list(self):
        self._send_json(
            200,
            {"feeds": sorted(ALLOWED_FEEDS)},
            {"Cache-Control": "public, max-age=3600"},
        )

    def _handle_feed(self, query):
        feed_id = (query.get("id") or [""])[0]
        if feed_id not in ALLOWED_FEEDS:
            return self._send_json(
                400,
                {"error": "unknown feed id", "id": feed_id, "allowed": sorted(ALLOWED_FEEDS)},
            )
        try:
            body, status = CACHE.get(feed_id)
        except RuntimeError as exc:
            return self._send_json(
                502, {"error": "upstream unavailable and no cached copy", "detail": str(exc)}
            )
        self._send(
            200,
            body,
            "application/geo+json; charset=utf-8",
            {
                "Cache-Control": "public, max-age=30",
                "Access-Control-Allow-Origin": "*",
                "X-Florence-Cache": status,  # fresh | live | stale
            },
        )

    def _handle_static(self, url_path):
        full = self._safe_path(url_path)
        if full is None:
            return self._send_json(403, {"error": "forbidden"})
        if os.path.isdir(full):
            full = os.path.join(full, "index.html")
        if not os.path.isfile(full):
            return self._send_json(404, {"error": "not found", "path": url_path})
        ctype, _ = mimetypes.guess_type(full)
        ctype = ctype or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
            ctype += "; charset=utf-8"
        # index.html must never be cached (it carries the live config); long-lived
        # static assets (vendored leaflet etc.) can be cached aggressively.
        is_index = os.path.basename(full) == "index.html"
        cache_ctl = "no-cache" if is_index else "public, max-age=86400"
        try:
            with open(full, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            return self._send_json(500, {"error": "read failed", "detail": str(exc)})
        self._send(200, data, ctype, {"Cache-Control": cache_ctl})

    @staticmethod
    def _safe_path(url_path):
        """Resolve a URL path under STATIC_DIR, refusing any traversal."""
        clean = posixpath.normpath(unquote(url_path))
        if clean in ("/", ".", ""):
            clean = "/index.html"
        parts = [p for p in clean.split("/") if p not in ("", ".", "..")]
        candidate = os.path.abspath(os.path.join(STATIC_DIR, *parts))
        root = STATIC_DIR + os.sep
        if candidate != STATIC_DIR and not candidate.startswith(root):
            return None
        return candidate

    # quieter, single-line access log -> journald/stdout
    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
def main():
    logging.basicConfig(
        level=os.environ.get("FLORENCE_LOG", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # make sure .js / .css / .geojson resolve to sensible types everywhere
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("text/css", ".css")
    mimetypes.add_type("application/geo+json", ".geojson")
    mimetypes.add_type("image/png", ".png")

    if not os.path.isdir(STATIC_DIR):
        log.error("static dir %s does not exist", STATIC_DIR)
        raise SystemExit(2)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True

    stop = threading.Event()

    def _shutdown(signum, _frame):
        log.info("signal %s received, shutting down", signum)
        stop.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server_thread = threading.Thread(target=httpd.serve_forever, name="http", daemon=True)
    server_thread.start()
    log.info(
        "Florence's Seismic Travel Bureau v%s serving %s on http://%s:%d",
        VERSION, STATIC_DIR, HOST, PORT,
    )
    log.info("health: http://%s:%d/healthz", HOST, PORT)
    try:
        stop.wait()
    finally:
        httpd.shutdown()
        httpd.server_close()
        log.info("stopped")


if __name__ == "__main__":
    main()
