"""Real authenticated FTP and SFTP fixtures; independent byte and resume checks.

Development-only dependencies are listed in requirements-test.txt. No server
binds to an external interface, and all credentials/host keys are disposable.
"""
import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import threading
import time

import paramiko
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
from pyftpdlib.log import config_logging
from integration import Harness, wait_for
from fixture import PAYLOAD


class SSHAuth(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("fixture", "protocol-secret") else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class ReadHandle(paramiko.SFTPHandle):
    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))


class FileAccess(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root=None, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(root).resolve()

    def local(self, path):
        candidate = (self.root / path.lstrip("/")).resolve()
        if candidate != self.root and self.root not in candidate.parents:
            raise PermissionError("Outside fixture")
        return candidate

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.local(path).stat())
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    lstat = stat

    def open(self, path, flags, attr):
        try:
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC):
                return paramiko.SFTP_PERMISSION_DENIED
            stream = open(self.local(path), "rb")
            handle = ReadHandle(flags)
            handle.readfile = stream
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno or 13)

    def canonicalize(self, path):
        return "/" + path.lstrip("/")


class SFTPFixture:
    def __init__(self, root):
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(8)
        self.socket.settimeout(0.3)
        self.port = self.socket.getsockname()[1]
        self.key = paramiko.RSAKey.generate(2048)
        self.transports = []
        self.root = root
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.serve, args=(connection,), daemon=True).start()

    def serve(self, connection):
        transport = paramiko.Transport(connection)
        self.transports.append(transport)
        try:
            transport.add_server_key(self.key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, FileAccess, root=self.root)
            transport.start_server(server=SSHAuth())
            while transport.is_active() and not self.stopped.wait(0.1):
                pass
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    def close(self):
        self.stopped.set()
        self.socket.close()
        for transport in self.transports:
            transport.close()
        self.thread.join(timeout=2)


def main():
    config_logging(level=50)
    passed = []
    with tempfile.TemporaryDirectory(prefix="current-protocols-") as temporary:
        folder = Path(temporary)
        source = folder / "source"
        source.mkdir()
        (source / "payload.bin").write_bytes(PAYLOAD)
        authorizer = DummyAuthorizer()
        authorizer.add_user("fixture", "protocol-secret", str(source), perm="elr")
        handler = type("FixtureFTPHandler", (FTPHandler,), {"authorizer": authorizer})
        ftp = FTPServer(("127.0.0.1", 0), handler)
        ftp_port = ftp.socket.getsockname()[1]
        ftp_stopped = threading.Event()
        def serve_ftp():
            while not ftp_stopped.is_set():
                ftp.serve_forever(timeout=0.1, blocking=False, handle_exit=False)
        ftp_thread = threading.Thread(target=serve_ftp, daemon=True)
        ftp_thread.start()
        sftp = SFTPFixture(source)
        h = Harness(folder)
        try:
            h.start()
            h.command("settings", settings={"downloadDirectory": str(folder / "downloads")})
            for scheme, port in [("ftp", ftp_port), ("sftp", sftp.port)]:
                job = h.add("%s://127.0.0.1:%s/payload.bin" % (scheme, port), username="fixture", password="protocol-secret", connections=2, speedLimit=1048576)
                def partial():
                    current = h.job(job["id"])
                    assert current["status"] != "error", (current, (folder / "state/engine.log").read_text()[-4000:])
                    return current["completedBytes"] > 500000
                wait_for(partial, label=scheme + " partial")
                h.command("pause", ids=[job["id"]])
                paused = h.job(job["id"])
                assert paused["status"] == "paused" and paused["completedBytes"] < len(PAYLOAD), paused
                h.command("resume", ids=[job["id"]])
                h.check_file(job, PAYLOAD)
                passed.append("authenticated %s pause/resume and independent SHA-256 byte verification" % scheme.upper())
            print(json.dumps({"passed": passed, "count": len(passed)}, indent=2))
        finally:
            h.stop()
            h.log.close()
            ftp_stopped.set()
            ftp_thread.join(timeout=2)
            ftp.close_all()
            sftp.close()


if __name__ == "__main__":
    main()
