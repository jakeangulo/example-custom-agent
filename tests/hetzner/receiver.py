#!/usr/bin/env python3
"""Test receiver for installer events, run on a throwaway Hetzner server.

POST /events/<job_id>  stores the JSON body; requires "Authorization: Bearer <token>".
GET  /events/<job_id>  returns the stored events as a JSON list; same token.
GET  /health           returns 200 (for the readiness check).

Usage: receiver.py PORT TOKEN   (listens on 127.0.0.1; Caddy terminates TLS)
"""
import hmac
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EVENTS = {}
LOCK = threading.Lock()
MAX_BODY = 64 * 1024


class Handler(BaseHTTPRequestHandler):
    def _authorized(self):
        got = self.headers.get("Authorization", "")
        return hmac.compare_digest(got, "Bearer " + TOKEN)

    def _reply(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _job(self):
        parts = self.path.strip("/").split("/")
        return parts[1] if len(parts) == 2 and parts[0] == "events" else None

    def do_GET(self):
        if self.path == "/health":
            return self._reply(200, {"ok": True})
        job = self._job()
        if job is None:
            return self._reply(404)
        if not self._authorized():
            return self._reply(401)
        with LOCK:
            return self._reply(200, EVENTS.get(job, []))

    def do_POST(self):
        job = self._job()
        if job is None:
            return self._reply(404)
        if not self._authorized():
            return self._reply(401)
        length = int(self.headers.get("Content-Length", "0"))
        if length > MAX_BODY:
            return self._reply(413)
        try:
            event = json.loads(self.rfile.read(length))
        except ValueError:
            return self._reply(400)
        with LOCK:
            EVENTS.setdefault(job, []).append(event)
        return self._reply(204)

    def log_message(self, fmt, *args):  # keep tokens out of the console
        sys.stderr.write("%s %s\n" % (self.command, self.path))


if __name__ == "__main__":
    port, TOKEN = int(sys.argv[1]), sys.argv[2]
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
