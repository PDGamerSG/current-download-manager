"""Deterministic local HTTP fixture. Never needs Internet access."""
import base64
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from urllib.parse import urlsplit

PAYLOAD = bytes(range(256)) * (48 * 1024)  # 12 MiB, independently hashable.
TINY = b"Current fixture\n" * 4096


class Fixture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.events = []
        self.attempts = {}

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_port

    def handle_error(self, request, client_address):
        # Closing a paused or cancelled HTTP connection is an expected fixture path.
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_GET(self, head=False):
        path = urlsplit(self.path).path
        self.server.events.append({"path": path, "range": self.headers.get("Range"), "proxy": self.path.startswith("http://"), "host":self.headers.get("Host"), "cookieSeen":bool(self.headers.get("Cookie")), "authorizationSeen":bool(self.headers.get("Authorization"))})
        self.server.attempts[path] = self.server.attempts.get(path, 0) + 1
        if path == "/redirect":
            self.send_response(302); self.send_header("Location", "/tiny.bin"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/cross-origin":
            self.send_response(302); self.send_header("Location", "http://localhost:%d/tiny.bin" % self.server.server_port); self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/auth.bin" and self.headers.get("Authorization") != "Basic " + base64.b64encode(b"test:secret").decode():
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="fixture"'); self.send_header("Content-Length", "0"); self.end_headers(); return
        cookies = SimpleCookie(); cookies.load(self.headers.get("Cookie", ""))
        valid_session = cookies.get("session") is not None and cookies["session"].value == "fixture"
        if path in ["/cookie.bin","/cookie-slow.bin"] and (not valid_session or not self.headers.get("Referer", "").endswith("/page")):
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/expired.bin":
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/retry.bin" and self.server.attempts[path] <= 2:
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        pages = {
            "/page": '<!doctype html><title>Current browser fixture</title><a id="tiny" href="/tiny.bin">File</a><a id="download" href="/slow.bin">Large download</a><a id="cookie-download" href="/cookie-slow.bin">Session download</a><a href="/next">Next</a><video controls src="/video.mp4"></video><a href="https://example.org/outside.zip">Outside</a>',
            "/next": '<a href="/picture.png?x=1&amp;y=2">Image</a><a href="/page">Back</a>',
        }
        if path == "/input.meta4":
            data = ('<?xml version="1.0"?><metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="untracked.bin"><url>'+self.server.url+'/extra.bin</url></file></metalink>').encode(); content_type="application/metalink4+xml"
        elif path in pages:
            data = pages[path].encode(); content_type = "text/html"
        elif path == "/stats":
            data = json.dumps(self.server.events).encode(); content_type = "application/json"
        else:
            data = TINY if path in ["/tiny.bin", "/auth.bin", "/cookie.bin", "/retry.bin", "/video.mp4", "/picture.png"] else PAYLOAD
            content_type = "video/mp4" if path == "/video.mp4" else "application/octet-stream"
        start, end = 0, len(data) - 1
        ranged = self.headers.get("Range") if path != "/no-range.bin" else None
        if ranged:
            parts = ranged.removeprefix("bytes=").split("-", 1)
            start = int(parts[0]); end = min(int(parts[1]) if parts[1] else end, end)
            if start > end:
                self.send_response(416); self.send_header("Content-Range", "bytes */%d" % len(data)); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(end - start + 1))
        if path != "/no-range.bin": self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"current-fixture-v1"')
        if ranged: self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
        self.end_headers()
        if head: return
        try:
            for offset in range(start, end + 1, 65536):
                self.wfile.write(data[offset:min(offset+65536, end+1)]); self.wfile.flush()
                if path == "/disconnect.bin" and self.server.attempts[path] == 1 and offset >= 1048576:
                    self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
                time.sleep(0.03 if path in ["/slow.bin", "/restart.bin", "/cookie-slow.bin"] else 0.004)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def start_fixture():
    server = Fixture()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


if __name__ == "__main__":
    import faulthandler
    # Hosted macOS can stall during system hostname resolution. Keep a stack
    # trace if fixture startup blocks so browser failures retain the cause.
    faulthandler.dump_traceback_later(8)
    fixture = start_fixture()
    faulthandler.cancel_dump_traceback_later()
    print(fixture.url, flush=True)
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt: fixture.shutdown()
