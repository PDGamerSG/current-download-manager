"""Owned HTTP fixture for the standalone saved website project checks."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from fixture_server import LoopbackHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    revision = 1
    failing = False
    requests_seen = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        type(self).requests_seen.append((self.path, self.headers.get("Cookie", "")))
        if path == "/control/fail":
            type(self).failing = True
            return self.reply(b"ok")
        if path == "/control/update":
            type(self).revision += 1
            type(self).failing = False
            return self.reply(b"ok")
        if path == "/stats":
            return self.reply(json.dumps(type(self).requests_seen).encode(), "application/json")
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/site/index.html")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/outside":
            self.send_response(302)
            self.send_header("Location", "http://localhost:%d/foreign" % self.server.server_port)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", "1000000")
            self.end_headers()
            try:
                for _ in range(1000):
                    self.wfile.write(b"x" * 1000)
                    self.wfile.flush()
                    time.sleep(.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == "/oversize":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", "100000000")
            self.end_headers()
            self.close_connection = True
            return
        if path == "/stream-limit":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(9):
                    self.wfile.write(b"3e8\r\n" + b"x" * 1000 + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == "/delay":
            time.sleep(.8)
            return self.reply(b"<html>Delayed publication</html>", "text/html")
        if path == "/resource-depth":
            return self.reply(b'<html><link rel="stylesheet" href="/surprise.html"></html>', "text/html")
        if path == "/surprise.html":
            return self.reply(b'<html><a href="/unexpected-depth.html">Unexpected</a></html>', "text/html")
        if path == "/unexpected-depth.html":
            return self.reply(b"<html>Too deep</html>", "text/html")
        if path == "/site/index.html":
            if type(self).failing:
                return self.reply(b"Unavailable", "text/plain", 503)
            return self.reply(('''<!doctype html><html><head><base href="/assets/"><title>Revision %d</title>
                <link rel="stylesheet" href="main.css"><style>.inline{background:url('inline.png')}</style>
                <script src="danger.js"></script></head><body onclick="alert(1)">
                <a href="/site/child.html#part">Child</a><a href="/site/excluded.html">Exclude</a>
                <a href="/site/query.html?x=1&amp;y=2">Query</a><a href="http://localhost:%d/foreign">Other origin</a>
                <img src="picture.png" srcset="picture.png 1x, retina.png 2x">
                <video poster="poster.png"><source src="clip.mp4"></video>
                <p style="background:url(style.png)">Offline</p></body></html>''' % (self.revision, self.server.server_port)).encode(), "text/html")
        if path == "/site/child.html":
            return self.reply(b'<html><body id="part"><a href="/site/grandchild.html">Deep</a><img src="/assets/picture.png"></body></html>', "text/html")
        if path == "/site/query.html":
            return self.reply(b"<html>query page</html>", "text/html")
        if path in ["/site/excluded.html", "/site/grandchild.html", "/foreign", "/assets/danger.js"]:
            return self.reply(b"should not be fetched", "text/html")
        if path == "/assets/main.css":
            return self.reply(b'/* url(fake.png) */ @import "nested.css"; .hero{background:url("picture.png?asset=1&v=2")} @font-face{src:url(font.woff2)} .literal{content:"url(fake.png)"}', "text/css")
        if path == "/assets/nested.css":
            return self.reply(b"@import url('deep.css'); .nested{background:url(nested.png)}", "text/css")
        if path == "/assets/deep.css":
            return self.reply(b".deep{color:navy}", "text/css")
        if path.startswith("/assets/") and path.endswith((".png", ".mp4", ".woff2")):
            return self.reply(("fixture-bytes:" + self.path).encode(), "image/png")
        return self.reply(b"missing", "text/plain", 404)

    def reply(self, data, mime="text/plain", status=200):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", required=True)
    args = parser.parse_args()
    server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    Path(args.ready).write_text(json.dumps({"port": server.server_port}))
    server.serve_forever()
