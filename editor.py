#!/usr/bin/env python3
"""Local input window for the sticker-board wallpaper.

The wallpaper lives behind the Windows desktop, so keystrokes land on icons.
This server opens a normal page where typing has a real focus, then hands the
text back to the wallpaper.
"""

import json
import re
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ZIP_PATH = ROOT.parent / "Sticker-Board.zip"
HOST = "127.0.0.1"
PORT = 47831
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{4,32}$")
FIELDS = {"title", "task", "add"}
FILES = {
    "/": "index.html",
    "/index.html": "index.html",
    "/compose": "compose.html",
    "/compose.html": "compose.html",
    "/thumbnail.png": "thumbnail.png",
    "/LivelyInfo.json": "LivelyInfo.json",
    "/LivelyProperties.json": "LivelyProperties.json",
}
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
}

results = deque(maxlen=40)
seen = set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def _send(self, code, body, content_type):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._json(200, {"ok": True})
            return
        if path == "/Sticker-Board.zip":
            if not ZIP_PATH.is_file():
                self._json(404, {"error": "zip missing"})
                return
            data = ZIP_PATH.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Disposition", 'attachment; filename="Sticker-Board.zip"')
            self.send_header("Cache-Control", "no-store")
            self._cors()
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/results":
            self._json(200, list(results))
            return
        name = FILES.get(path)
        if not name:
            self._json(404, {"error": "not found"})
            return
        file_path = ROOT / name
        content_type = TYPES.get(file_path.suffix, "application/octet-stream")
        self._send(200, file_path.read_bytes(), content_type)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/commit":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 10000:
            self._json(413, {"error": "too large"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "bad json"})
            return
        token = str(payload.get("token") or "")
        field = str(payload.get("field") or "")
        status = str(payload.get("status") or "")
        if not TOKEN_RE.match(token) or field not in FIELDS or status not in {"commit", "cancel"}:
            self._json(400, {"error": "bad edit"})
            return
        if token in seen:
            self._json(200, {"ok": True, "duplicate": True})
            return
        text = str(payload.get("text") or "").replace("\r", " ").replace("\n", " ").strip()
        if status == "commit" and not text:
            self._json(400, {"error": "empty"})
            return
        seen.add(token)
        results.append({
            "token": token,
            "noteId": str(payload.get("noteId") or ""),
            "taskId": str(payload.get("taskId") or ""),
            "field": field,
            "status": status,
            "text": text[:140],
        })
        self._json(200, {"ok": True})


def main():
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError:
        print("The editor is already running. Close this window.", flush=True)
        try:
            input("Press Enter to close... ")
        except EOFError:
            pass
        return
    print("Sticker editor: http://%s:%s" % (HOST, PORT), flush=True)
    print("Leave this window open while you edit the wallpaper.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
