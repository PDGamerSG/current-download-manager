"""Real CLI → bridge → aria2 → HTTP → disk acceptance checks."""
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from fixture import PAYLOAD, TINY, start_fixture

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("CURRENT_TEST_CLI", ROOT / ".build/debug/currentctl"))


def wait_for(fn, timeout=25, label="condition"):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = fn()
            if last: return last
        except (ConnectionError, OSError, KeyError, ValueError): pass
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for %s; last=%r" % (label, last))


def wait_for_fixture(process, ready, log, timeout=60):
    """Report an exited generator immediately, including its private test log."""
    def running():
        if process.poll() is not None:
            raise AssertionError("Media fixture exited with code %s:\n%s" % (process.returncode, Path(log).read_text(errors="replace")[-12000:]))
        return ready.exists()
    try:
        return wait_for(running, timeout, "media fixture readiness")
    except AssertionError as error:
        raise AssertionError("%s\nFixture log:\n%s" % (error, Path(log).read_text(errors="replace")[-12000:])) from error


class Harness:
    def __init__(self, folder):
        self.folder = Path(folder); self.env = {**os.environ, "CURRENT_STATE_DIR":str(self.folder / "state")}
        self.proc = None; self.descriptor = None
        self.log = open(self.folder / "service.log", "ab")

    def start(self):
        (self.folder / "state" / "bridge.json").unlink(missing_ok=True)
        self.proc = subprocess.Popen([str(CLI), "serve"], env=self.env, stdout=self.log, stderr=self.log)
        def ready():
            file = self.folder / "state" / "bridge.json"
            if not file.exists(): return False
            self.descriptor = json.loads(file.read_text())
            return self.call("status")["ok"]
        try: wait_for(ready, 12, "service readiness")
        except Exception:
            self.log.flush(); print((self.folder / "service.log").read_text(), file=sys.stderr); raise

    def call(self, action, **values):
        req = urllib.request.Request("http://127.0.0.1:%s/v1/command" % self.descriptor["port"], data=json.dumps({"action":action, **values}).encode(), headers={"Authorization":"Bearer "+self.descriptor["token"], "Content-Type":"application/json"})
        return json.load(urllib.request.urlopen(req, timeout=15))

    def command(self, action, **values):
        reply = self.call(action, **values)
        assert reply.get("ok"), reply
        return reply["result"]

    def job(self, job_id):
        return next(x for x in self.command("status")["jobs"] if x["id"] == job_id)

    def add(self, url, **request):
        return self.command("add", requests=[{"urls":[url], **request}])[0]

    def completed(self, job):
        result = wait_for(lambda: self.job(job["id"]) if self.job(job["id"])["status"] in ["complete","error"] else None, label="download completion")
        assert result["status"] == "complete", result
        return result

    def check_file(self, job, expected):
        job = self.completed(job)
        path = Path(job["directory"]) / job["filename"]
        assert hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(expected).digest(), path
        return job

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try: self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired: self.proc.kill(); self.proc.wait()
        self.proc = None


def main():
    fixture = start_fixture()
    passed = []
    with tempfile.TemporaryDirectory(prefix="current-e2e-") as folder:
        h = Harness(folder)
        try:
            h.start()
            h.command("settings", settings={"downloadDirectory":str(Path(folder)/"downloads")})
            assert stat.S_IMODE((h.folder/"state/state.json").stat().st_mode) == 0o600
            req = urllib.request.Request("http://127.0.0.1:%s/v1/command" % h.descriptor["port"], data=b'{"action":"status"}', headers={"Content-Type":"application/json"})
            try: urllib.request.urlopen(req); raise AssertionError("unauthorized bridge accepted")
            except urllib.error.HTTPError as error: assert error.code == 401
            req.add_header("Authorization", "Bearer "+h.descriptor["token"]); req.add_header("Origin", "https://evil.example")
            try: urllib.request.urlopen(req); raise AssertionError("website-origin request accepted")
            except urllib.error.HTTPError as error: assert error.code == 403
            passed.append("private storage and authenticated, website-isolated bridge")

            job = h.add(fixture.url+"/file.bin", connections=4)
            h.check_file(job, PAYLOAD)
            assert any(e["range"] for e in fixture.events if e["path"] == "/file.bin")
            passed.append("segmented transfer and independent SHA-256 byte verification")

            job = h.add(fixture.url+"/slow.bin", connections=2, speedLimit=1048576)
            wait_for(lambda: h.job(job["id"])["completedBytes"] > 500000, label="partial bytes")
            h.command("pause", ids=[job["id"]]); time.sleep(0.3)
            partial = h.job(job["id"])
            assert partial["status"] == "paused" and 0 < partial["completedBytes"] < len(PAYLOAD), partial
            time.sleep(0.4); assert h.job(job["id"])["status"] == "paused"
            h.command("resume", ids=[job["id"]]); h.check_file(job, PAYLOAD)
            passed.append("pause/resume preserves partial data with a rate limit")

            for path in ["/redirect", "/retry.bin", "/no-range.bin", "/disconnect.bin"]:
                job = h.add(fixture.url+path)
                h.check_file(job, TINY if path in ["/redirect","/retry.bin"] else PAYLOAD)
            passed.append("redirects, transient retry, dropped connection recovery and non-Range fallback")

            h.check_file(h.add(fixture.url+"/auth.bin", username="test", password="secret"), TINY)
            h.check_file(h.add(fixture.url+"/cookie.bin", headers={"Cookie":"session=fixture", "Referer":fixture.url+"/page"}), TINY)
            exported = json.dumps(h.command("export"))
            assert "secret" not in exported and "session=fixture" not in exported
            passed.append("HTTP authentication, browser cookies/referer and credential-redacted export")

            jobs = h.command("add", requests=[{"urls":[fixture.url+"/tiny.bin"],"filename":"same.bin"}]*2)
            for job in jobs: h.check_file(job,TINY)
            assert jobs[0]["filename"] != jobs[1]["filename"]
            assert not h.call("add",requests=[{"urls":[fixture.url+"/tiny.bin"],"filename":"../escape"}])["ok"]
            assert not h.call("add",requests=[{"urls":["file:///etc/passwd"]}])["ok"]
            passed.append("batch downloads, filename collisions and unsafe-input rejection")

            queue = {"id":"scheduled","name":"Scheduled","maxConcurrent":1,"enabled":True,"schedule":{"start":(datetime.now(timezone.utc)+timedelta(seconds=3)).strftime("%Y-%m-%dT%H:%M:%SZ"),"daily":False}}
            h.command("queue-save",queue=queue)
            job = h.add(fixture.url+"/tiny.bin",queueID="scheduled")
            assert h.job(job["id"])["status"] == "waiting"
            h.check_file(job,TINY)
            queue["enabled"] = False; h.command("queue-save",queue=queue)
            job = h.add(fixture.url+"/tiny.bin",queueID="scheduled")
            time.sleep(0.7); assert h.job(job["id"])["completedBytes"] == 0
            h.command("pause",ids=[job["id"]]); queue["enabled"] = True; h.command("queue-save",queue=queue)
            time.sleep(0.7); assert h.job(job["id"])["status"] == "paused"
            h.command("resume",ids=[job["id"]]); h.check_file(job,TINY)
            passed.append("queue start scheduling, disable/enable and preserved manual pause")

            job = h.add(fixture.url+"/tiny.bin",checksum="sha-256="+"0"*64)
            wait_for(lambda: h.job(job["id"])["status"] == "error",label="checksum rejection")
            job = h.add(fixture.url+"/expired.bin")
            wait_for(lambda: h.job(job["id"])["status"] == "error",label="expired URL error")
            h.command("refresh",id=job["id"],url=fixture.url+"/tiny.bin"); h.check_file(job,TINY)
            passed.append("checksum mismatch rejection and expired-link refresh")

            job = h.add(fixture.url+"/restart.bin",connections=2,speedLimit=1048576)
            wait_for(lambda:h.job(job["id"])["completedBytes"]>500000,label="restart partial")
            h.stop(); h.start(); h.check_file(job,PAYLOAD)
            passed.append("persisted jobs and partial transfer recovery after service restart")

            # Queue concurrency is asserted while transfers are still partial.
            h.command("queue-save", queue={"id":"serial","name":"Serial","maxConcurrent":1,"enabled":True})
            serial = [h.add(fixture.url+"/slow.bin",queueID="serial",speedLimit=524288) for _ in range(2)]
            wait_for(lambda: any(h.job(j["id"])["completedBytes"] > 0 for j in serial), label="serial queue first bytes")
            serial_state = [h.job(j["id"]) for j in serial]
            assert sum(j["status"] == "active" for j in serial_state) == 1, serial_state
            assert sum(j["completedBytes"] == 0 for j in serial_state) == 1, serial_state
            h.command("cancel",ids=[serial[0]["id"]])
            wait_for(lambda:h.job(serial[1]["id"])["completedBytes"]>0,label="serial queue advancement")
            h.command("cancel",ids=[serial[1]["id"]])
            passed.append("per-queue concurrency and queue advancement after cancellation")

            h.command("settings",settings={"hourlyQuota":1})
            quota_job=h.add(fixture.url+"/tiny.bin")
            time.sleep(0.7); assert h.job(quota_job["id"])["completedBytes"] == 0
            h.command("settings",settings={"hourlyQuota":0}); h.check_file(quota_job,TINY)
            passed.append("hourly quota pauses new work and resumes when lifted")

            h.command("settings",settings={"proxy":fixture.url})
            h.check_file(h.add("http://proxy.example.invalid/tiny.bin"),TINY)
            assert any(e["proxy"] for e in fixture.events)
            h.command("settings",settings={"proxy":""})
            passed.append("HTTP proxy routing against an independently observed proxy fixture")

            category={"id":"custom","name":"Fixture files","extensions":[],"hosts":["127.0.0.1"]}
            h.command("category-save",category=category)
            categorized=h.add(fixture.url+"/tiny.bin")
            h.check_file(categorized,TINY)
            assert categorized["categoryID"] == "custom" and categorized["directory"].endswith("Fixture files")
            passed.append("custom host category routes files into its destination folder")

            scanner=Path(folder)/"scanner.py"; marker=Path(folder)/"scanned.txt"
            scanner.write_text("#!/usr/bin/env python3\nimport sys\nwith open("+repr(str(marker))+", 'a') as f: f.write(sys.argv[1]+'\\n')\n")
            scanner.chmod(0o700)
            h.command("settings",settings={"scannerPath":str(scanner)})
            scanned=h.add(fixture.url+"/tiny.bin"); scanned=h.check_file(scanned,TINY)
            assert scanned["scanResult"] == "Scanner passed"
            time.sleep(1); assert len(marker.read_text().splitlines()) == 1, marker.read_text()
            h.command("settings",settings={"scannerPath":""})
            passed.append("antivirus hook runs once before completion and does not repeat on polling")

            frame = json.dumps({"action":"add","requests":[{"urls":[fixture.url+"/tiny.bin"]}]}).encode()
            host = subprocess.Popen([str(CLI),"native-host"],env=h.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            # Fragment the native header/body to catch partial-read mistakes.
            for piece in [struct.pack("<I",len(frame))[:2],struct.pack("<I",len(frame))[2:],frame[:7],frame[7:]]:
                host.stdin.write(piece); host.stdin.flush(); time.sleep(0.02)
            host.stdin.close(); output=host.stdout.read(); host.wait(timeout=10)
            assert host.returncode == 0 and len(output)>=4, output
            size=struct.unpack("<I",output[:4])[0]; reply=json.loads(output[4:4+size]); assert reply["ok"],reply
            h.check_file(reply["result"][0],TINY)
            passed.append("fragmented browser native message → service → verified file")

            links = h.command("grab",url=fixture.url+"/page",depth=1,extensions=["bin","png","mp4"])
            urls=[x["url"] for x in links]
            assert fixture.url+"/tiny.bin" in urls and fixture.url+"/video.mp4" in urls and any("picture.png" in u for u in urls),urls
            assert all(u.startswith(fixture.url) for u in urls)
            passed.append("bounded same-origin site grabber with relative links and extension filters")

            print(json.dumps({"passed":passed,"count":len(passed)},indent=2))
        finally:
            h.stop(); h.log.close(); fixture.shutdown()


if __name__ == "__main__": main()
