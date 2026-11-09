"""Compile and run standalone media/grabber checks with owned temporary fixtures."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from integration import wait_for
import json

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = ROOT / ".artifacts/unified-media-checks"
    output.parent.mkdir(exist_ok=True)
    subprocess.run([
        "swiftc", "-parse-as-library",
        *[str(ROOT / "Sources/CurrentCore" / name) for name in ["Models.swift", "Storage.swift", "SiteGrabber.swift", "MediaWorker.swift"]],
        str(ROOT / "tests/media_grabber_main.swift"), "-o", str(output)
    ], check=True, cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="current-media-checks-") as folder:
        folder = Path(folder)
        ready = folder / "ready.json"
        with open(folder / "fixture.log", "wb") as log:
            fixture = subprocess.Popen([
                sys.executable, str(ROOT / "tests/media_grabber_fixture.py"),
                "--directory", str(folder / "fixture"), "--ready", str(ready)
            ], stdout=log, stderr=log, cwd=ROOT)
            try:
                wait_for(ready.exists, 20, "media fixture")
                url = "http://127.0.0.1:%s" % json.loads(ready.read_text())["port"]
                for mode in ["all", "await-tree", "timeout"]:
                    subprocess.run([str(output), url, str(folder / mode), mode], check=True, cwd=ROOT, timeout=180)
            finally:
                fixture.terminate()
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait()


if __name__ == "__main__":
    main()
