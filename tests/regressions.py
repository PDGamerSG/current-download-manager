"""Reproductions for defects found by independent core review."""
import json
from pathlib import Path
import tempfile
import time
from integration import Harness, wait_for
from fixture import start_fixture, TINY


def main():
    fixture=start_fixture(); failures=[]; passed=[]
    with tempfile.TemporaryDirectory(prefix="current-regression-") as folder:
        h=Harness(folder)
        try:
            h.start(); h.command("settings",settings={"downloadDirectory":str(Path(folder)/"files")})
            def check(name,fn):
                try: fn(); passed.append(name)
                except Exception as error: failures.append(name+": "+str(error))

            def atomic_batch():
                before=len(h.command("status")["jobs"])
                response=h.call("add",requests=[{"urls":[fixture.url+"/tiny.bin"],"filename":"atomic.bin","startPaused":True},{"urls":[fixture.url+"/tiny.bin"],"directory":"/dev/null/not-a-folder"}])
                assert not response["ok"],response
                assert len(h.command("status")["jobs"])==before,"failed batch left an accepted orphan job"
            check("failed batch has no partial acceptance",atomic_batch)

            def replaced_file():
                job=h.add(fixture.url+"/tiny.bin",filename="reserved.bin",startPaused=True)
                target=Path(job["directory"])/job["filename"]
                target.write_bytes(b"unrelated user file")
                h.command("resume",ids=[job["id"]])
                wait_for(lambda:h.job(job["id"])["status"] in ["complete","error"],label="replacement guard")
                assert target.read_bytes()==b"unrelated user file","existing file was overwritten"
                assert h.job(job["id"])["status"]=="error","changed destination was not rejected"
            check("resuming never overwrites a changed destination",replaced_file)

            def unowned_media_delete():
                job=h.add(fixture.url+"/tiny.bin",kind="media",filename="media-unowned.mp4",startPaused=True)
                target=Path(job["directory"])/job["filename"]
                target.write_bytes(b"unrelated file created after media was queued")
                response=h.call("delete-file",ids=[job["id"]])
                assert not response["ok"],"media without a committed ownership record deleted an unrelated destination"
                assert target.read_bytes()==b"unrelated file created after media was queued","unowned media destination was removed"
                h.command("remove",ids=[job["id"]])
            check("media deletion requires recorded destination ownership",unowned_media_delete)

            def stale_finalization():
                scanner=Path(folder)/"slow-scanner.py"; started=Path(folder)/"scanner-started"
                scanner.write_text("#!/usr/bin/env python3\nimport time\nfrom pathlib import Path\nPath("+repr(str(started))+").touch()\ntime.sleep(3)\n")
                scanner.chmod(0o700)
                h.command("settings",settings={"scannerPath":str(scanner)})
                job=h.add(fixture.url+"/tiny.bin",filename="generation.bin")
                wait_for(lambda:started.exists(),label="scanner started")
                h.command("cancel",ids=[job["id"]]); h.command("settings",settings={"scannerPath":""})
                h.command("refresh",id=job["id"],url=fixture.url+"/expired.bin")
                time.sleep(4)
                current=h.job(job["id"])
                assert current["status"]!="complete","old attempt marked a changed URL complete"
                assert any(e["path"]=="/expired.bin" for e in fixture.events),"refreshed URL was never requested"
            check("stale scanner completion cannot complete a new attempt",stale_finalization)

            def replaced_during_scan():
                scanner=Path(folder)/"held-scanner.py"; started=Path(folder)/"held-started"; release=Path(folder)/"held-release"
                scanner.write_text("#!/usr/bin/env python3\nimport time\nfrom pathlib import Path\nPath("+repr(str(started))+").touch()\nwhile not Path("+repr(str(release))+").exists(): time.sleep(0.02)\n")
                scanner.chmod(0o700); h.command("settings",settings={"scannerPath":str(scanner)})
                try:
                    job=h.add(fixture.url+"/tiny.bin",filename="replace-during-scan.bin")
                    wait_for(started.exists,label="held scanner started")
                    target=Path(job["directory"])/job["filename"]
                    target.rename(target.with_name(target.name+".original"))
                    target.write_bytes(b"unrelated replacement while scanner was running")
                    release.touch()
                    current=wait_for(lambda:h.job(job["id"]) if h.job(job["id"])["status"] in ["complete","error"] else None,label="scan replacement result")
                    assert current["status"]=="error","a replaced file was accepted as the completed download"
                    assert not h.call("delete-file",ids=[job["id"]])["ok"],"scanner completion adopted unrelated replacement ownership"
                    assert target.read_bytes()==b"unrelated replacement while scanner was running"
                    h.command("remove",ids=[job["id"]])
                finally:
                    release.touch(); h.command("settings",settings={"scannerPath":""})
            check("scanner completion cannot adopt a replaced destination",replaced_during_scan)

            def unrelated_sidecar():
                job=h.check_file(h.add(fixture.url+"/tiny.bin",filename="sidecar-owned.bin"),TINY)
                target=Path(job["directory"])/job["filename"]
                sidecar=Path(str(target)+".aria2"); sidecar.write_bytes(b"unrelated sidecar created after completion")
                h.command("delete-file",ids=[job["id"]])
                assert not target.exists(),"owned output was not deleted"
                assert sidecar.read_bytes()==b"unrelated sidecar created after completion","unowned aria2 sidecar was deleted"
            check("explicit file deletion preserves an unowned sidecar",unrelated_sidecar)

            def no_hidden_children():
                job=h.add(fixture.url+"/input.meta4")
                h.completed(job); time.sleep(0.8)
                assert not any(e["path"]=="/extra.bin" for e in fixture.events),"aria2 created a transfer outside app queues"
                assert not (Path(job["directory"])/"untracked.bin").exists(),"hidden file was written"
            check("metalink response does not create untracked child transfers",no_hidden_children)

            def cookie_scope():
                before=len(fixture.events)
                job=h.add(fixture.url+"/cross-origin",headers={"Cookie":"session=fixture"})
                result=wait_for(lambda:h.job(job["id"]) if h.job(job["id"])["status"] in ["complete","error"] else None,label="redirect result")
                targets=[e for e in fixture.events[before:] if e["path"]=="/tiny.bin" and e["host"].startswith("localhost:")]
                assert all(not e["cookieSeen"] for e in targets),"session cookie was sent to another host"
            check("browser cookies remain bound to their source host on redirect",cookie_scope)

            def bounded_numbers():
                response=h.call("grab",url=fixture.url+"/page",depth=1e100)
                assert not response["ok"],"oversized depth was accepted"
                assert h.call("status")["ok"],"service stopped after invalid numeric input"
            check("oversized numeric input is rejected without terminating the service",bounded_numbers)

            print(json.dumps({"passed":passed,"failures":failures},indent=2))
            if failures: raise SystemExit(1)
        finally:
            h.stop(); h.log.close(); fixture.shutdown()


if __name__=="__main__":main()
