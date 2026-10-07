#!/usr/bin/env python3
"""timeline endpoint — serves the r1 timeline day-cards to the creation.

Reads data/timeline.json (written by the OS3-side generator) and answers the
creation's HTTPS request. Read-only: it never writes timeline data and never
touches the journal, memory or recordings itself.

Routes:
  GET /health          -> {"ok": true, ...}
  GET /timeline.json   -> the full feed
  GET /timeline.json?since=YYYY-MM-DD  -> only cards strictly after that date
  GET /                -> same as /timeline.json

Pairing token (optional):
  If TIMELINE_TOKEN is set in the environment, every request must carry
  `Authorization: Bearer <token>` or it is answered 401. If it is unset the
  endpoint stays open, so an existing single-owner setup is unchanged.

CORS:
  Access-Control-Allow-Headers names `Authorization` explicitly. The `*`
  wildcard alone does NOT cover the Authorization header in the r1 WebView —
  the preflight fails unless the header is listed by name (pilot finding,
  2026-10-07).
"""

import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.environ.get(
    "TIMELINE_DATA_FILE",
    os.path.join(HERE, "..", "data", "timeline.json"),
)
PORT = int(os.environ.get("TIMELINE_PORT", "8791"))
HOST = os.environ.get("TIMELINE_HOST", "127.0.0.1")
TOKEN = os.environ.get("TIMELINE_TOKEN", "").strip()
ACCESS_LOG = os.environ.get("TIMELINE_ACCESS_LOG", "").strip()

ALLOW_HEADERS = "Authorization, Content-Type, X-Requested-With, *"


def append_access(rec):
    """Opt-in JSONL access log. Records whether a token was present, never its
    value. Used to verify the pairing flow from the device side."""
    if not ACCESS_LOG:
        return
    try:
        with open(ACCESS_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def load_feed():
    try:
        with open(DATA_FILE, "r", encoding="utf-8") as fh:
            feed = json.load(fh)
    except FileNotFoundError:
        return None
    except (ValueError, OSError):
        return None
    if not isinstance(feed, dict):
        return None
    feed.setdefault("cards", [])
    return feed


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    server_version = "timeline-endpoint/1.1"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", ALLOW_HEADERS)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")

    def _send(self, status, payload, content_type="application/json; charset=utf-8"):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _authorised(self):
        """True when no token is configured, or the request carries it."""
        if not TOKEN:
            return True
        header = self.headers.get("Authorization", "") or ""
        if header.startswith("Bearer "):
            return header[7:].strip() == TOKEN
        return header.strip() == TOKEN

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Max-Age", "86400")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        auth = self.headers.get("Authorization", "") or ""
        append_access(
            {
                "t": iso_now(),
                "method": self.command,
                "path": path,
                "query": parsed.query,
                "auth_present": bool(auth),
                "auth_ok": self._authorised(),
                "ua": self.headers.get("User-Agent", ""),
                "origin": self.headers.get("Origin", ""),
                "cf_ip": self.headers.get("CF-Connecting-IP", ""),
            }
        )

        if not self._authorised():
            self._send(
                401,
                {
                    "ok": False,
                    "error": "unauthorized",
                    "message": "a valid pairing token is required",
                    "time": iso_now(),
                },
            )
            return

        if path == "/health":
            feed = load_feed()
            self._send(
                200,
                {
                    "ok": True,
                    "service": "r1-timeline-endpoint",
                    "time": iso_now(),
                    "hasFeed": feed is not None,
                    "cardCount": len(feed["cards"]) if feed else 0,
                    "generatedAt": feed.get("generatedAt") if feed else None,
                    "authRequired": bool(TOKEN),
                },
            )
            return

        if path in ("/", "/timeline.json", "/index.json"):
            feed = load_feed()
            if feed is None:
                self._send(
                    503,
                    {
                        "ok": False,
                        "error": "no_feed",
                        "message": "timeline feed has not been generated yet",
                        "time": iso_now(),
                    },
                )
                return

            since = parse_qs(parsed.query).get("since", [None])[0]
            cards = feed["cards"]
            if since:
                since_day = since[:10]
                cards = [c for c in cards if str(c.get("date", ""))[:10] > since_day]

            self._send(
                200,
                {
                    "ok": True,
                    "generatedAt": feed.get("generatedAt"),
                    "timezone": feed.get("timezone", "UTC"),
                    "since": since,
                    "count": len(cards),
                    "cards": cards,
                },
            )
            return

        self._send(404, {"ok": False, "error": "not_found", "path": path})

    def log_message(self, fmt, *args):
        sys.stderr.write(
            "%s - %s\n" % (self.address_string(), fmt % args)
        )


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(
        "timeline endpoint listening on http://%s:%d (data: %s, auth: %s)\n"
        % (HOST, PORT, DATA_FILE, "token" if TOKEN else "open")
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
