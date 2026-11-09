"""Isolated network-policy checks against a real aria2 process and HTTP server."""
from http.server import BaseHTTPRequestHandler
from http.cookies import SimpleCookie
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from fixture_server import LoopbackHTTPServer


ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = bytes(range(251)) * 16384


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            # aria2 closes persistent connections when a request is removed.
            pass

    def do_GET(self):
        expected_agent = {"/manual": "CurrentPolicyFixture/1", "/browser": "BrowserFixture/12", "/updated": "UpdatedPolicyFixture/2"}.get(self.path)
        cookies = SimpleCookie()
        cookies.load(self.headers.get("Cookie", ""))
        if self.headers.get("User-Agent") != expected_agent or set(cookies) != {"session"} or cookies["session"].value != "fixture":
            print(f"Rejected fixture request {self.path}: agent={self.headers.get('User-Agent')!r}, cookie={self.headers.get('Cookie')!r}", flush=True)
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end = 0, len(PAYLOAD) - 1
        range_header = self.headers.get("Range")
        if range_header:
            lower, upper = range_header.removeprefix("bytes=").split("-", 1)
            start = int(lower)
            end = min(int(upper), end) if upper else end
        self.send_response(206 if range_header else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if range_header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(PAYLOAD)}")
        self.end_headers()
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(PAYLOAD[offset:min(offset + 16384, end + 1)])
                self.wfile.flush()
                time.sleep(0.004)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    with tempfile.TemporaryDirectory(prefix="current-network-policy-") as temporary:
        folder = Path(temporary)
        binary = folder / "network-policy-checks"
        # Compile independently of the shared SwiftPM output and installed state.
        core = ROOT / "Sources/CurrentCore"
        sources = [core / name for name in ["Models.swift", "Storage.swift", "RPC.swift", "NetworkPolicy.swift"] if (core / name).exists()]
        subprocess.run(["swiftc", "-parse-as-library", *map(str, sources), str(ROOT / "tests/network_policy_main.swift"), "-o", str(binary)], check=True, cwd=ROOT)
        expected = folder / "expected.bin"
        expected.write_bytes(PAYLOAD)
        fixture = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        try:
            subprocess.run([str(binary), str(folder / "state"), f"http://127.0.0.1:{fixture.server_port}", str(expected)], check=True, env={**os.environ, "CURRENT_STATE_DIR": str(folder / "state")}, timeout=40)
        finally:
            fixture.shutdown()
            fixture.server_close()


if __name__ == "__main__":
    main()
