#!/usr/bin/env python3
"""Deterministic exit-vs-cancel fixture; it does not access the network."""
import json
import os
import pathlib
import shlex
import sys
import time

config = pathlib.Path(sys.argv[sys.argv.index("--config-locations") + 1])
options = shlex.split(config.read_text())
output = options[options.index("--output") + 1]
print("CURRENT_PROGRESS " + json.dumps({"downloaded": 1, "total": 2, "speed": 1, "file": output}), flush=True)
release = pathlib.Path(output + ".release")
deadline = time.monotonic() + 10
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
actual = pathlib.Path(output + ".mp4")
actual.write_bytes(b"complete-media-fixture")
print("CURRENT_FILE " + json.dumps(str(actual)), flush=True)
pathlib.Path(output + ".ready").write_text(str(os.getpid()))
os._exit(0 if "/success" in options[-1] else 1)
