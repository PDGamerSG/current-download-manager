"""Real service media acceptance: serialized restart, aggregate rate policy, shutdown."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

from integration import Harness, wait_for
from fixture import PAYLOAD, start_fixture


ROOT = Path(__file__).resolve().parents[1]
HEADERS = {"Cookie": "fixture=secret", "Referer": "https://fixture.invalid/private"}


def process_commands(state):
    lines = subprocess.check_output(["/bin/ps", "-axo", "pid=,args="], text=True).splitlines()
    found = []
    for line in lines:
        pieces = line.strip().split(None, 1)
        if len(pieces) != 2:
            continue
        try:
            args = shlex.split(pieces[1])
        except ValueError:
            continue
        if "--config-locations" in args and any(str(state) in value for value in args):
            found.append((int(pieces[0]), args))
    return found


def configurations(state):
    result = []
    for file in (state / "media").glob("run-*/options.conf"):
        try:
            args = shlex.split(file.read_text())
        except FileNotFoundError:
            continue
        result.append((file, args))
    return result


def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def config_limit(args):
    return int(args[args.index("--limit-rate") + 1]) if "--limit-rate" in args else 0


def media_limits_match(state, count, predicate):
    configs = configurations(state)
    return len(configs) == count and all(predicate(config_limit(args)) for _, args in configs)


def decoded_video_hash(ffmpeg, path):
    # Decode the fixture and downloaded media independently: container metadata cannot disguise missing segments.
    result = subprocess.check_output([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(path), "-map", "0:v:0",
        "-an", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"
    ], stderr=subprocess.PIPE)
    return hashlib.sha256(result).hexdigest(), len(result)


def assert_media(harness, job, ffmpeg, expected):
    job = harness.completed(job)
    path = Path(job["directory"]) / job["filename"]
    assert decoded_video_hash(ffmpeg, path) == expected, (job, path)
    return job


def main():
    for name in ["yt-dlp", "ffmpeg", "ffprobe", "aria2c"]:
        if not shutil.which(name):
            raise SystemExit("Install %s before running service media acceptance checks." % name)
    ffmpeg = shutil.which("ffmpeg")
    passed = []
    file_fixture = start_fixture()
    with tempfile.TemporaryDirectory(prefix="current-media-service-") as folder:
        folder = Path(folder)
        ready = folder / "fixture-ready.json"
        media_folder = folder / "fixture"
        fixture_log = open(folder / "fixture.log", "ab")
        fixture = subprocess.Popen([
            sys.executable, str(ROOT / "tests/media_grabber_fixture.py"),
            "--directory", str(media_folder), "--ready", str(ready)
        ], stdout=fixture_log, stderr=fixture_log)
        h = Harness(folder)
        state = folder / "state"
        try:
            wait_for(ready.exists, 15, "media fixture readiness")
            media_url = "http://127.0.0.1:%s/media/stream.m3u8" % json.loads(ready.read_text())["port"]
            expected = decoded_video_hash(ffmpeg, media_folder / "stream.m3u8")
            assert expected[1] == 96 * 64 * 3 // 2 * 12 * 16, expected
            h.start()
            h.command("settings", settings={"downloadDirectory": str(folder / "downloads"), "maxConcurrent": 3})

            protected_directory = folder / "protected-downloads"
            protected_directory.mkdir()
            protected = []
            original = b"UNRELATED-LOCAL-FILE-" * 100
            for index, suffix in enumerate([".part", ".f137.mp4.part", ".f0.mp4.part", ".ytdl", ".part.ytdl"]):
                target = folder / ("unrelated-%s.txt" % index)
                target.write_bytes(original)
                sidecar = protected_directory / ("owned.mp4" + suffix)
                sidecar.symlink_to(target)
                protected.append((target, sidecar))
            guarded = h.add(media_url, kind="media", filename="owned.mp4", directory=str(protected_directory), headers=HEADERS, connections=1)
            assert_media(h, guarded, ffmpeg, expected)
            for target, sidecar in protected:
                assert target.read_bytes() == original, "media overwrote an unrelated destination sidecar target"
                assert sidecar.is_symlink() and sidecar.readlink() == target, "media removed an unrelated destination sidecar symlink"
            passed.append("private staging isolates real media writes from malicious destination part/format/resume symlinks")

            job = h.add(media_url, kind="media", filename="pause-resume.mp4", headers=HEADERS, connections=1, speedLimit=65536)
            wait_for(lambda: h.job(job["id"])["completedBytes"] > 16000, label="media partial before immediate pause/resume")
            for _ in range(3):
                old_groups = [pid for pid, _ in process_commands(state)]
                h.command("pause", ids=[job["id"]])
                paused = h.job(job["id"])
                assert paused["status"] in ["paused", "complete"], paused
                assert not process_commands(state), "pause returned with a media process still writing"
                assert not any(group_alive(pid) for pid in old_groups), "pause returned with a media descendant still running"
                assert not configurations(state), "pause returned before private file cleanup"
                # Intentionally no sleep between pause acknowledgement and resume.
                h.command("resume", ids=[job["id"]])
                if h.job(job["id"])["status"] == "complete":
                    break
                wait_for(lambda: h.job(job["id"])["status"] == "active", label="immediate media resume")
            assert_media(h, job, ffmpeg, expected)
            passed.append("immediate service media pause/resume waits for group cleanup and preserves all decoded HLS frames")

            capped = h.add(media_url, kind="media", filename="per-job-limit.mp4", headers=HEADERS, connections=4, speedLimit=40000)
            wait_for(lambda: len(configurations(state)) == 1, label="per-job media config")
            config_file, args = configurations(state)[0]
            assert config_limit(args) == 40000, args
            assert args[args.index("--concurrent-fragments") + 1] == "1", args
            assert stat.S_IMODE(config_file.stat().st_mode) == 0o600
            wait_for(lambda: h.job(capped["id"])["completedBytes"] > 8000, label="per-job limited media partial")
            h.command("settings", settings={"speedLimit": 180000})
            wait_for(lambda: media_limits_match(state, 1, lambda limit: limit == 40000), label="per-job cap survives higher global limit")
            h.command("pause", ids=[capped["id"]])
            assert not process_commands(state)
            h.command("cancel", ids=[capped["id"]])
            passed.append("media per-job cap and single-fragment enforcement survive settings changes")

            h.command("settings", settings={"speedLimit": 180000})
            jobs = h.command("add", requests=[
                {"urls": [media_url], "kind": "media", "filename": "fair-a.mp4", "headers": HEADERS, "connections": 1},
                {"urls": [media_url], "kind": "media", "filename": "fair-b.mp4", "headers": HEADERS, "connections": 1},
                {"urls": [file_fixture.url + "/slow.bin"], "filename": "shared-file.bin", "connections": 1}
            ])
            def fair_share_ready():
                return media_limits_match(state, 2, lambda limit: 0 < limit <= 60000)
            wait_for(fair_share_ready, 15, "aggregate global bandwidth allocation among two media jobs and one file job")
            media_rates = [config_limit(args) for _, args in configurations(state)]
            assert sum(media_rates) <= 120000, media_rates
            commands = process_commands(state)
            assert len(commands) == 2, commands
            assert all("fixture=secret" not in " ".join(args) and "stream.m3u8" not in " ".join(args) for _, args in commands), commands
            wait_for(lambda: all(h.job(job["id"])["completedBytes"] > 5000 for job in jobs), label="concurrent file and media partials")
            # This settings change forces a live media replacement at a new lower effective rate.
            h.command("settings", settings={"speedLimit": 90000})
            wait_for(lambda: media_limits_match(state, 2, lambda limit: 0 < limit <= 30000), 15, "awaited rate-change worker restart")
            assert len(process_commands(state)) == 2, process_commands(state)
            h.command("settings", settings={"speedLimit": 0})
            for job in jobs[:2]:
                assert_media(h, job, ffmpeg, expected)
            h.check_file(jobs[2], PAYLOAD)
            passed.append("aggregate file/media rate allocation and immediate settings restarts preserve independently verified bytes")

            shutdown_job = h.add(media_url, kind="media", filename="shutdown.mp4", headers=HEADERS, connections=1, speedLimit=40000)
            wait_for(lambda: h.job(shutdown_job["id"])["completedBytes"] > 8000, label="media partial before service shutdown")
            shutdown_groups = [pid for pid, _ in process_commands(state)]
            h.stop()
            assert not process_commands(state), process_commands(state)
            assert not any(group_alive(pid) for pid in shutdown_groups), "service shutdown left a media descendant running"
            assert not list((state / "media").glob("run-*")), "shutdown left private media files"
            partials = list((state / "media" / "jobs" / shutdown_job["id"].lower()).rglob("*"))
            assert any(".part" in file.name or file.name.endswith(".ytdl") for file in partials), partials
            assert not list(Path(shutdown_job["directory"]).glob(shutdown_job["filename"] + ".part*")), "media wrote a destination sidecar"
            h.start()
            h.command("resume", ids=[shutdown_job["id"]])
            assert_media(h, shutdown_job, ffmpeg, expected)
            passed.append("service shutdown awaits media process cleanup, retains native resume state, and restarts with all frames")
            discard_job = h.add(media_url, kind="media", filename="discard-partial.mp4", headers=HEADERS, connections=1, speedLimit=40000)
            wait_for(lambda: h.job(discard_job["id"])["completedBytes"] > 8000, label="media partial before explicit file deletion")
            h.command("cancel", ids=[discard_job["id"]])
            discard_folder = state / "media" / "jobs" / discard_job["id"].lower()
            assert discard_folder.exists() and any(".part" in file.name for file in discard_folder.rglob("*")), discard_folder
            h.command("delete-file", ids=[discard_job["id"]])
            assert not discard_folder.exists(), "delete-file retained private media partials"
            assert not any(job["id"] == discard_job["id"] for job in h.command("status")["jobs"]), "delete-file retained the job"
            passed.append("explicit file deletion removes cancelled media partial staging and its job")
            print(json.dumps({"passed": passed, "count": len(passed)}, indent=2))
        finally:
            h.stop()
            for pid, _ in process_commands(state):
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            h.log.close()
            fixture.terminate()
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.kill(); fixture.wait()
            fixture_log.close()
            file_fixture.shutdown()


if __name__ == "__main__":
    main()
