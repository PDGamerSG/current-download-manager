"""Compile isolated website checks and run them against an owned local server."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="current-web-checks-") as temporary:
        folder = Path(temporary).resolve()
        executable = folder / "website-checks"
        sources = [ROOT / "Sources/CurrentCore/Models.swift", ROOT / "Sources/CurrentCore/NetworkPolicy.swift", *sorted((ROOT / "Sources/CurrentCore").glob("WebsiteProjects*.swift")), *sorted((ROOT / "Sources/CurrentCore").glob("Offline*.swift")), ROOT / "tests/website_projects_main.swift"]
        subprocess.run(["swiftc", "-parse-as-library", *map(str, sources), "-o", str(executable)], check=True, cwd=ROOT)
        ready = folder / "ready.json"
        with (folder / "fixture.log").open("wb") as log:
            server = subprocess.Popen([sys.executable, str(ROOT / "tests/website_projects_fixture.py"), "--ready", str(ready)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not ready.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Website fixture did not start: " + (folder / "fixture.log").read_text())
                    time.sleep(.05)
                base = "http://127.0.0.1:%d" % json.loads(ready.read_text())["port"]
                options = ["--quick"] if "--quick" in sys.argv else []
                subprocess.run([str(executable), base, str(folder / "test-state"), *options], check=True, cwd=ROOT, timeout=110)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
