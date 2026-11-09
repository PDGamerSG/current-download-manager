"""HTTP servers for numeric loopback fixtures, independent of reverse DNS."""
from http.server import ThreadingHTTPServer
from socketserver import TCPServer


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally calls getfqdn even for 127.0.0.1. macOS hosted
        # runners can block there; fixture URLs and handlers use numeric IPs.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
