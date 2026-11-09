#!/usr/bin/env python3
"""Local, deterministic HTTP fixtures for media and bounded crawl checks."""
import argparse
import collections
import http.server
import json
import pathlib
import shutil
import subprocess
import threading
import time
import urllib.parse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--ready", required=True)
    args = parser.parse_args()
    directory = pathlib.Path(args.directory)
    directory.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("Install ffmpeg before running the media fixture.")
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=16",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=16",
        "-c:v", "libx264", "-preset", "ultrafast", "-g", "12", "-c:a", "aac",
        "-f", "hls", "-hls_time", "1", "-hls_list_size", "0",
        str(directory / "stream.m3u8")
    ], check=True)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=16",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=16",
        "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "ultrafast", "-g", "12", "-c:a", "aac",
        "-f", "dash", "-seg_duration", "1", str(directory / "manifest.mpd")
    ], check=True)
    requests = collections.Counter()
    cross_requests = collections.Counter()

    class Foreign(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            cross_requests[self.path] += 1
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b'<a href="/forbidden.zip">outside origin</a>')

        def log_message(self, *_):
            pass

    foreign = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Foreign)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            requests[path] += 1
            if path == "/stats":
                return self.reply(json.dumps({"requests": requests, "foreign": cross_requests}).encode(), "application/json")
            if path == "/outside":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{foreign.server_port}/stolen")
                self.end_headers()
                return
            if path == "/redirect-same":
                self.send_response(302)
                self.send_header("Location", "/grab/index.html")
                self.end_headers()
                return
            if path == "/grab/index.html":
                html = f'''<!doctype html><html><head><base href="/grab/sub/"></head><body>
                <!-- <a href="/comment.zip">ignore comment</a> -->
                <script>const bait = '<a href="/script.zip">ignore script</a>';</script>
                <a href="clip.mp4?x=1&amp;y=2">clip</a>
                <video src="UPPER.MP4"></video><a href="archive%20one.zip#one">zip
                <a href="archive%20one.zip#two">same zip
                <a href="caf&eacute;.pdf">named entity</a>
                <a href="/grab/level1.html">next</a><a href="/outside">outside redirect</a>
                <a href="http://127.0.0.1:{foreign.server_port}/foreign.zip">foreign port</a>
                <a href="http://localhost:{self.server.server_port}/foreign.zip">foreign host</a>
                <a href="https://127.0.0.1:{self.server.server_port}/foreign.zip">foreign scheme</a>
                <a href="javascript:alert(1)">script</a><a href="data:text/plain,hi.zip">data</a>
                </body></html>'''
                return self.reply(html.encode())
            if path.startswith("/grab/level"):
                level = int(path.removeprefix("/grab/level").removesuffix(".html"))
                return self.reply(f'<a href="/depth-{level}.zip">resource</a><a href="/grab/level{level+1}.html">next</a>'.encode())
            if path == "/many-resources":
                return self.reply("".join(f'<a href="/resource-{i}.zip">r</a>' for i in range(700)).encode())
            if path == "/many-pages":
                return self.reply("".join(f'<a href="/page/{i}">page</a>' for i in range(80)).encode())
            if path.startswith("/page/"):
                return self.reply(f'<a href="/item-{path.split("/")[-1]}.zip">r</a>'.encode())
            if path == "/oversize":
                return self.reply(b" " * (2 * 1024 * 1024 + 1))
            if path == "/oversize-stream":
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                try:
                    for _ in range(36):
                        self.wfile.write(b" " * 65536)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if path.startswith("/media/"):
                filename = pathlib.Path(path).name
                file = directory / filename
                if not file.is_file():
                    self.send_error(404)
                    return
                if filename.endswith((".m3u8", ".mpd")):
                    if self.headers.get("Cookie") != "fixture=secret" or self.headers.get("Referer") != "https://fixture.invalid/private":
                        self.send_error(403)
                        return
                    return self.reply(file.read_bytes(), "application/dash+xml" if filename.endswith(".mpd") else "application/vnd.apple.mpegurl")
                data = file.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    # Delays make cancellation observable while keeping the fixture small.
                    for start in range(0, len(data), 2048):
                        self.wfile.write(data[start:start + 2048])
                        self.wfile.flush()
                        time.sleep(0.012)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            self.send_error(404)

        def reply(self, body, content_type="text/html; charset=utf-8"):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=foreign.serve_forever, daemon=True).start()
    pathlib.Path(args.ready).write_text(json.dumps({"port": server.server_port, "foreignPort": foreign.server_port}))
    server.serve_forever()


if __name__ == "__main__":
    main()
