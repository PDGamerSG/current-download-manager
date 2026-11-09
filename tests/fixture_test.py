"""Local fixture startup must not depend on the host's reverse DNS service."""
import unittest
from unittest.mock import patch
import urllib.request

from fixture import TINY, start_fixture


class FixtureStartupTests(unittest.TestCase):
    def test_loopback_server_starts_without_reverse_dns(self):
        with patch("socket.getfqdn", side_effect=AssertionError("Fixture attempted reverse DNS")):
            fixture = start_fixture()
            try:
                self.assertEqual(fixture.server_name, "127.0.0.1")
                self.assertEqual(fixture.server_port, fixture.socket.getsockname()[1])
                with urllib.request.urlopen(fixture.url + "/tiny.bin", timeout=5) as response:
                    self.assertEqual(response.read(), TINY)
            finally:
                fixture.shutdown()
                fixture.server_close()


if __name__ == "__main__":
    unittest.main()
