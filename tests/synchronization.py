"""Real HTTP validator, queue policy and immutable file-update acceptance checks."""
import hashlib
from pathlib import Path
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler
from fixture_server import LoopbackHTTPServer
from integration import Harness, wait_for


class SyncFixture(LoopbackHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), SyncHandler)
        self.version = 1
        self.fail = False
        self.slow = False
        self.redirect = None
        self.validators = True
        self.vary_representation = False
        self.etags = True
        self.head_unsupported = False
        self.events = []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/resource.bin" % self.server_port

    @property
    def payload(self):
        return (b"Current synchronized version %d\n" % self.version) * 65536

    @property
    def etag(self):
        return '"fixture-%d"' % self.version


class SyncHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(True)

    def do_GET(self):
        self.serve(False)

    def serve(self, head):
        fixture = self.server
        fixture.events.append({"method":self.command,"path":self.path,"headers":dict(self.headers)})
        etag = fixture.etag
        if fixture.vary_representation:
            representation = self.headers.get("User-Agent", "") + "/" + self.headers.get("Accept-Encoding", "")
            etag = '"%s-%s"' % (fixture.version, hashlib.sha256(representation.encode()).hexdigest()[:16])
        modified = "Mon, %02d Nov 2026 00:00:00 GMT" % fixture.version
        if head and fixture.head_unsupported:
            self.send_error(405)
            return
        if fixture.redirect:
            self.send_response(302)
            self.send_header("Location", fixture.redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if fixture.fail:
            self.send_error(404)
            return
        if fixture.validators and head and ((fixture.etags and self.headers.get("If-None-Match") == etag) or (not fixture.etags and self.headers.get("If-Modified-Since") == modified)):
            self.send_response(304)
            if fixture.etags: self.send_header("ETag", etag)
            self.send_header("Last-Modified", modified)
            self.end_headers()
            return
        if fixture.validators and ((self.headers.get("If-Match") not in (None, etag)) or (self.headers.get("If-Unmodified-Since") not in (None, modified))):
            self.send_error(412)
            return
        payload = fixture.payload
        start = 0
        end = len(payload)-1
        if self.headers.get("Range"):
            value = self.headers["Range"].removeprefix("bytes=").split("-", 1)
            start = int(value[0])
            if value[1]: end = min(end, int(value[1]))
        data = payload[start:end+1]
        self.send_response(206 if self.headers.get("Range") else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Accept-Ranges", "bytes")
        if self.headers.get("Range"):
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(payload)))
        if fixture.validators:
            if fixture.etags: self.send_header("ETag", etag)
            self.send_header("Last-Modified", modified)
        if fixture.vary_representation: self.send_header("Vary", "User-Agent, Accept-Encoding")
        self.end_headers()
        if head: return
        try:
            for offset in range(0, len(data), 65536):
                self.wfile.write(data[offset:offset+65536])
                self.wfile.flush()
                if fixture.slow: time.sleep(0.08)
        except (OSError, ConnectionError):
            pass


class SynchronizationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="current-sync-")
        self.fixture = SyncFixture()
        self.h = Harness(self.folder.name)
        self.h.start()
        self.h.command("settings", settings={"downloadDirectory":str(Path(self.folder.name)/"downloads")})
        self.queue = {"id":"updates","name":"Updates","maxConcurrent":1,"enabled":True,"synchronizationIntervalSeconds":60}
        self.h.command("queue-save", queue=self.queue)

    def tearDown(self):
        self.h.stop()
        self.h.log.close()
        self.fixture.shutdown()
        self.fixture.server_close()
        self.folder.cleanup()

    @staticmethod
    def path(job):
        return Path(job["directory"]) / job["filename"]

    def original(self, **values):
        return self.h.check_file(self.h.add(self.fixture.url, queueID="updates", **values), self.fixture.payload)

    def check(self, job):
        before = self.h.job(job["id"]).get("synchronization", {}).get("checkCount", 0)
        self.h.command("synchronize", id=job["id"])
        return wait_for(lambda: self.h.job(job["id"]) if self.h.job(job["id"]).get("synchronization",{}).get("checkCount",0) > before and self.h.job(job["id"]).get("synchronization",{}).get("status") in ["idle","error"] else None, timeout=30, label="synchronization check")

    def baseline(self, **values):
        job = self.original(**values)
        latest = self.check(job)
        self.assertEqual(latest["synchronization"]["status"], "idle", latest)
        self.assertEqual(self.path(latest).read_bytes(), self.fixture.payload)
        return job, latest

    def test_changed_versions_unchanged_validators_and_restart(self):
        original, current = self.baseline()
        old_path = self.path(original)
        old_bytes = old_path.read_bytes()
        get_count = sum(e["method"] == "GET" for e in self.fixture.events)
        unchanged = self.check(current)
        self.assertEqual(self.path(unchanged), self.path(current))
        self.assertEqual(sum(e["method"] == "GET" for e in self.fixture.events), get_count)
        self.assertTrue(any(e["method"] == "HEAD" and e["headers"].get("If-None-Match") == self.fixture.etag for e in self.fixture.events))
        self.fixture.version = 2
        updated = self.check(current)
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)
        self.assertNotEqual(self.path(updated), self.path(current))
        self.assertEqual(old_path.read_bytes(), old_bytes)
        self.assertEqual(self.path(current).read_bytes(), old_bytes)
        self.assertEqual(len(self.h.command("status")["jobs"]), 1)
        self.assertEqual(len(self.h.command("export")), 1)
        self.assertGreaterEqual(len(updated["synchronization"]["versions"]), 2)
        self.h.stop()
        self.h.start()
        persisted = self.h.job(original["id"])
        self.assertEqual(self.path(persisted), self.path(updated))
        self.assertEqual(persisted["synchronization"]["etag"], self.fixture.etag)

    def test_failure_and_external_replacement_preserve_existing_bytes(self):
        _, current = self.baseline()
        path = self.path(current)
        before = path.read_bytes()
        self.fixture.fail = True
        failed = self.check(current)
        self.assertEqual(failed["status"], "complete")
        self.assertEqual(failed["synchronization"]["status"], "error")
        self.assertEqual(path.read_bytes(), before)
        self.fixture.fail = False
        path.rename(path.with_suffix(".kept"))
        path.write_bytes(b"unrelated replacement")
        self.fixture.version = 2
        rejected = self.check(current)
        self.assertEqual(rejected["synchronization"]["status"], "error")
        self.assertEqual(path.read_bytes(), b"unrelated replacement")
        self.assertEqual(path.with_suffix(".kept").read_bytes(), before)

    def test_queue_disable_and_manual_pause_are_respected(self):
        _, current = self.baseline()
        self.queue["enabled"] = False
        self.h.command("queue-save", queue=self.queue)
        count = len(self.fixture.events)
        self.assertFalse(self.h.call("synchronize", id=current["id"])["ok"])
        time.sleep(0.6)
        self.assertEqual(len(self.fixture.events), count)
        self.queue["enabled"] = True
        self.h.command("queue-save", queue=self.queue)
        self.h.command("synchronization-pause", id=current["id"])
        self.assertTrue(self.h.job(current["id"])["synchronization"]["paused"])
        self.h.stop()
        self.h.start()
        self.assertTrue(self.h.job(current["id"])["synchronization"]["paused"])
        self.fixture.version = 2
        resumed = self.check(current)
        self.assertEqual(self.path(resumed).read_bytes(), self.fixture.payload)

    def test_interval_changes_recalculate_the_next_check(self):
        from datetime import datetime
        _, current = self.baseline()
        original = datetime.fromisoformat(current["synchronization"]["nextCheckAt"])
        self.queue["synchronizationIntervalSeconds"] = 86400
        self.h.command("queue-save", queue=self.queue)
        later = datetime.fromisoformat(self.h.job(current["id"])["synchronization"]["nextCheckAt"])
        self.assertGreater((later-original).total_seconds(), 80000)
        self.queue["synchronizationIntervalSeconds"] = 60
        self.h.command("queue-save", queue=self.queue)
        earlier = datetime.fromisoformat(self.h.job(current["id"])["synchronization"]["nextCheckAt"])
        self.assertLess((earlier-original).total_seconds(), 5)

    def test_moving_a_download_does_not_resume_manually_paused_updates(self):
        _, current = self.baseline()
        self.h.command("synchronization-pause", id=current["id"])
        self.h.command("move", ids=[current["id"]], queueID="main")
        moved = self.h.job(current["id"])
        self.assertTrue(moved["synchronization"]["paused"])
        self.assertEqual(moved["synchronization"]["status"], "paused")

    def test_probe_and_transfer_share_user_agent_and_encoding(self):
        self.fixture.vary_representation = True
        _, current = self.baseline()
        get_count = sum(e["method"] == "GET" for e in self.fixture.events)
        unchanged = self.check(current)
        self.assertEqual(unchanged["synchronization"]["status"], "idle")
        self.assertEqual(sum(e["method"] == "GET" for e in self.fixture.events), get_count)

    def test_last_modified_only_and_unsupported_head(self):
        self.fixture.etags = False
        _, current = self.baseline()
        get_count = sum(e["method"] == "GET" for e in self.fixture.events)
        unchanged = self.check(current)
        self.assertEqual(self.path(unchanged), self.path(current))
        self.assertEqual(sum(e["method"] == "GET" for e in self.fixture.events), get_count)
        self.fixture.head_unsupported = True
        self.fixture.version = 2
        updated = self.check(current)
        self.assertEqual(updated["synchronization"]["status"], "idle", updated)
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)

    def test_active_update_pause_and_resume_preserve_both_versions(self):
        _, current = self.baseline()
        previous = self.path(current).read_bytes()
        self.fixture.version = 2
        self.fixture.slow = True
        self.h.command("synchronize", id=current["id"])
        wait_for(lambda: self.h.job(current["id"])["synchronization"]["receivedBytes"] > 0, label="active update before pause")
        self.h.command("synchronization-pause", id=current["id"])
        time.sleep(.8)
        received = self.h.job(current["id"])["synchronization"]["receivedBytes"]
        time.sleep(.8)
        paused = self.h.job(current["id"])
        self.assertTrue(paused["synchronization"]["paused"])
        self.assertEqual(paused["synchronization"]["receivedBytes"], received)
        self.assertEqual(self.path(current).read_bytes(), previous)
        self.h.command("synchronize", id=current["id"])
        updated = wait_for(lambda: self.h.job(current["id"]) if self.h.job(current["id"])["synchronization"]["status"] == "idle" else None, label="resumed update")
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)
        self.assertEqual(self.path(current).read_bytes(), previous)

    def test_update_quota_wait_and_scanner_rejection_keep_existing_file(self):
        _, current = self.baseline()
        previous = self.path(current).read_bytes()
        self.fixture.version = 2
        self.fixture.slow = True
        allowance = self.h.command("status")["quotaBytes"] + 100000
        self.h.command("settings", settings={"hourlyQuota":allowance})
        self.h.command("synchronize", id=current["id"])
        wait_for(lambda: self.h.command("status")["quotaBytes"] >= allowance, label="update reaches quota")
        time.sleep(.8)
        received = self.h.job(current["id"])["synchronization"]["receivedBytes"]
        time.sleep(.8)
        self.assertEqual(self.h.job(current["id"])["synchronization"]["receivedBytes"], received)
        self.assertEqual(self.path(current).read_bytes(), previous)
        self.h.command("settings", settings={"hourlyQuota":0})
        updated = wait_for(lambda: self.h.job(current["id"]) if self.h.job(current["id"])["synchronization"]["status"] == "idle" else None, label="update after quota lifted")
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)
        scanner = Path(self.folder.name)/"reject-scanner.py"
        scanner.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(7)\n")
        scanner.chmod(0o700)
        self.h.command("settings", settings={"scannerPath":str(scanner)})
        self.fixture.version = 3
        rejected = self.check(updated)
        self.assertEqual(rejected["synchronization"]["status"], "error")
        self.assertIn("scanner rejected", rejected["synchronization"]["lastError"])
        self.assertEqual(self.path(rejected), self.path(updated))
        self.assertEqual(self.path(current).read_bytes(), previous)

    def test_cross_origin_probe_refuses_credentials(self):
        _, current = self.baseline(headers={"Cookie":"sync-session=secret","Referer":self.fixture.url})
        foreign = SyncFixture()
        try:
            self.fixture.redirect = foreign.url
            failed = self.check(current)
            self.assertEqual(failed["synchronization"]["status"], "error")
            self.assertEqual(foreign.events, [])
        finally:
            foreign.shutdown()
            foreign.server_close()

    def test_update_can_resume_after_restart_and_keeps_old_version(self):
        _, current = self.baseline()
        previous = self.path(current).read_bytes()
        self.fixture.version = 2
        self.fixture.slow = True
        self.h.command("synchronize", id=current["id"])
        wait_for(lambda: self.h.job(current["id"]).get("synchronization",{}).get("receivedBytes",0) > 0, label="partial update bytes")
        self.h.stop()
        self.assertEqual(self.path(current).read_bytes(), previous)
        self.h.start()
        updated = wait_for(lambda: self.h.job(current["id"]) if self.h.job(current["id"]).get("synchronization",{}).get("status") == "idle" else None, timeout=30, label="restarted update")
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)
        self.assertEqual(self.path(current).read_bytes(), previous)

    def test_periodic_check_runs_automatically_after_restart(self):
        _, current = self.baseline()
        previous = self.path(current).read_bytes()
        before = current["synchronization"]["checkCount"]
        self.h.stop()
        self.fixture.version = 2
        self.h.start()
        updated = wait_for(lambda: self.h.job(current["id"]) if self.h.job(current["id"]).get("synchronization",{}).get("checkCount",0) > before and self.h.job(current["id"]).get("synchronization",{}).get("status") == "idle" else None, timeout=75, label="automatic periodic update")
        self.assertEqual(self.path(updated).read_bytes(), self.fixture.payload)
        self.assertEqual(self.path(current).read_bytes(), previous)
        self.assertEqual(len(self.h.command("status")["jobs"]), 1)


if __name__ == "__main__":
    unittest.main()
