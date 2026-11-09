"""End-to-end checks for functionality added after the official manual audit."""
from pathlib import Path
import tempfile
import unittest
from integration import Harness
from fixture import start_fixture, TINY


class FeatureConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="current-features-v02-")
        self.h = Harness(self.folder.name)
        self.h.start()
        self.h.command("settings", settings={"downloadDirectory":str(Path(self.folder.name)/"downloads")})

    def tearDown(self):
        self.h.stop()
        self.h.log.close()
        self.folder.cleanup()

    def test_category_keeps_its_custom_destination(self):
        directory = str(Path(self.folder.name) / "custom-documents")
        saved = self.h.command("category-save", category={"id":"custom","name":"Custom","extensions":["pdf"],"hosts":[],"directory":directory})
        self.assertEqual(saved.get("directory"), directory)
        fixture = start_fixture()
        try:
            job = self.h.add(fixture.url + "/tiny.bin", categoryID="custom")
            self.h.check_file(job, TINY)
            self.assertEqual(job["directory"], directory)
        finally:
            fixture.shutdown()
            fixture.server_close()

    def test_invalid_category_directory_and_queue_policy_are_rejected(self):
        reply = self.h.call("category-save", category={"id":"bad","name":"Bad","extensions":[],"hosts":[],"directory":"relative/path"})
        self.assertFalse(reply["ok"])
        for changes in [
            {"synchronizationIntervalSeconds":0},
            {"synchronizationIntervalSeconds":59},
            {"synchronizationIntervalSeconds":1.5},
            {"schedule":{"start":"2026-01-01T00:00:00Z","daily":True,"weekdays":[]}},
            {"schedule":{"start":"2026-01-01T00:00:00Z","daily":True,"weekdays":[0,8]}},
            {"schedule":{"start":"2026-01-01T00:00:00Z","daily":False,"weekdays":[2]}},
        ]:
            reply = self.h.call("queue-save", queue={"id":"invalid","name":"Invalid","maxConcurrent":1,"enabled":True,**changes})
            self.assertFalse(reply["ok"], changes)

    def test_descriptions_are_editable_and_survive_restart(self):
        fixture = start_fixture()
        try:
            job = self.h.add(fixture.url + "/tiny.bin", startPaused=True)
            self.h.command("annotate", id=job["id"], description="Release archive\nKeep until January")
            self.assertEqual(self.h.job(job["id"])["description"], "Release archive\nKeep until January")
            self.h.stop()
            self.h.start()
            self.assertEqual(self.h.job(job["id"])["description"], "Release archive\nKeep until January")
            self.assertFalse(self.h.call("annotate", id=job["id"], description="x"*8193)["ok"])
        finally:
            fixture.shutdown()
            fixture.server_close()

    def test_server_rules_and_quota_window_are_preserved(self):
        rules = [{"id":"fixture","host":"example.org","maxConnections":2}]
        saved = self.h.command("settings", settings={"serverRules":rules,"quotaPeriodSeconds":14400})
        self.assertEqual(saved.get("serverRules"), rules)
        self.assertEqual(saved.get("quotaPeriodSeconds"), 14400)

    def test_weekday_schedule_is_preserved(self):
        schedule = {"start":"2026-01-01T00:00:00Z","daily":True,"weekdays":[2,4,6]}
        saved = self.h.command("queue-save", queue={"id":"weekdays","name":"Weekdays","maxConcurrent":1,"enabled":True,"schedule":schedule})
        self.assertEqual(saved.get("schedule",{}).get("weekdays"), [2,4,6])

    def test_quota_automatically_resets_after_configured_period(self):
        fixture = start_fixture()
        try:
            self.h.command("settings", settings={"hourlyQuota":len(TINY)})
            self.h.check_file(self.h.add(fixture.url+"/tiny.bin"), TINY)
            # Let the service account for the completed transfer before adding
            # the next job; the fixture body itself is independently checked.
            from integration import wait_for
            wait_for(lambda: self.h.command("status")["quotaBytes"] >= len(TINY), label="quota accounting")
            blocked = self.h.add(fixture.url+"/tiny.bin")
            self.assertEqual(self.h.job(blocked["id"])["completedBytes"], 0)
            self.h.command("settings", settings={"quotaPeriodSeconds":2})
            self.h.check_file(blocked, TINY)
        finally:
            fixture.shutdown()
            fixture.server_close()

    def test_website_project_commands_capture_and_persist_through_the_bridge(self):
        import threading
        from fixture_server import LoopbackHTTPServer
        from website_projects_fixture import Handler
        from integration import wait_for
        fixture = LoopbackHTTPServer(("127.0.0.1",0), Handler)
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        destination = (Path(self.folder.name)/"offline").resolve()
        destination.mkdir(mode=0o700)
        try:
            result = self.h.command("web-project-save", project={"name":"Bridge project","sourceURL":"http://127.0.0.1:%d/site/index.html" % fixture.server_port,"destinationDirectory":str(destination),"mode":"page","maxDepth":0})
            project_id = result["project"]["id"]
            self.h.command("web-project-run", id=project_id)
            def completed():
                project = next(p for p in self.h.command("web-project-list")["projects"] if p["id"] == project_id)
                return project if project["status"] in ["complete","error"] else None
            project = wait_for(completed, label="offline bridge capture")
            self.assertEqual(project["status"], "complete", project)
            entry = Path(project["outputDirectory"])/project["entryPath"]
            self.assertIn("Content-Security-Policy", entry.read_text())
            self.h.stop()
            self.h.start()
            self.assertEqual(self.h.command("web-project-list")["projects"][0]["outputDirectory"], project["outputDirectory"])
            self.h.command("web-project-delete", id=project_id)
            self.assertTrue(entry.exists())
            self.assertEqual(self.h.command("web-project-list")["projects"], [])
        finally:
            fixture.shutdown()
            fixture.server_close()


if __name__ == "__main__":
    unittest.main()
