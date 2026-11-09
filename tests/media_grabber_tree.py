#!/usr/bin/env python3
"""A controlled process tree: the leader exits on INT, its child requires KILL."""
import os
import pathlib
import shlex
import signal
import subprocess
import sys

config = pathlib.Path(sys.argv[sys.argv.index("--config-locations") + 1])
options = shlex.split(config.read_text())
output = options[options.index("--output") + 1]
child = subprocess.Popen([
    sys.executable, "-c",
    "import pathlib,signal,sys,time; "
    "signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); "
    "p=pathlib.Path(sys.argv[1]); "
    "exec('while True:\\n p.write_text(str(time.monotonic_ns()))\\n time.sleep(0.05)')",
    output + ".heartbeat"
])
pathlib.Path(output + ".childpid").write_text(str(child.pid))
try:
    child.wait()
except KeyboardInterrupt:
    os._exit(130)
