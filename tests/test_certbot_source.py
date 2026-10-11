"""DNS API source binding remains local to the Certbot process and hostname."""
import socket
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "assets/remote/certbot-dns-setup.sh").read_text(encoding="utf-8")
RUNNER = SCRIPT.split("<<'RUNNER'\n", 1)[1].split("\nRUNNER\n", 1)[0]


class CertbotSourceTests(unittest.TestCase):
    def run_runner(self, source):
        calls = {"resolve": [], "connect": []}
        def resolve(*args):
            calls["resolve"].append(args)
            return []
        def connect(address, timeout=None, source_address=None, socket_options=None):
            calls["connect"].append((address, timeout, source_address, socket_options))
            return "connection"
        connection = types.ModuleType("urllib3.util.connection")
        connection.create_connection = connect
        util = types.ModuleType("urllib3.util")
        util.connection = connection
        certbot_main = types.ModuleType("certbot.main")
        def main():
            socket.getaddrinfo("api.cloudflare.com", 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
            socket.getaddrinfo("API.CLOUDFLARE.COM.", 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
            socket.getaddrinfo("acme-v02.api.letsencrypt.org", 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
            socket.getaddrinfo("api.cloudflare.com", 443, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
            connection.create_connection(("api.cloudflare.com", 443), 7, None, [])
            connection.create_connection(("acme-v02.api.letsencrypt.org", 443), 8, ("127.0.0.2", 0), [])
            connection.create_connection(("api.cloudflare.com.example.org", 443), 9, None, [])
            connection.create_connection(("api.cloudflare.com", 443), timeout=10)
            return 0
        certbot_main.main = main
        modules = {"urllib3.util": util, "urllib3.util.connection": connection,
                   "certbot": types.ModuleType("certbot"), "certbot.main": certbot_main}
        with patch.dict(sys.modules, modules), patch.object(socket, "getaddrinfo", resolve):
            with self.assertRaises(SystemExit) as stopped:
                exec(compile(RUNNER, "mxh-certbot-dns", "exec"), {"DNS_API_SOURCE": source})
            self.assertEqual(stopped.exception.code, 0)
        return calls

    def test_ipv4_preflight_source_is_used_for_dns_api(self):
        calls = self.run_runner("192.0.2.10")
        self.assertEqual(calls["resolve"][0][2], socket.AF_INET)
        self.assertEqual(calls["resolve"][1][2], socket.AF_INET)
        self.assertEqual(calls["connect"][0][2], ("192.0.2.10", 0))

    def test_ipv6_preflight_source_is_used_for_dns_api(self):
        calls = self.run_runner("2001:db8::10")
        self.assertEqual(calls["resolve"][0][2], socket.AF_INET6)
        self.assertEqual(calls["connect"][0][2], ("2001:db8::10", 0))

    def test_acme_and_other_hosts_keep_their_original_transport(self):
        calls = self.run_runner("192.0.2.10")
        self.assertEqual(calls["resolve"][2][2], socket.AF_UNSPEC)
        self.assertEqual(calls["connect"][1][2], ("127.0.0.2", 0))
        self.assertIsNone(calls["connect"][2][2])

    def test_socket_keywords_and_connection_defaults_are_preserved(self):
        calls = self.run_runner("192.0.2.10")
        self.assertEqual(calls["resolve"][3][2], socket.AF_INET)
        self.assertEqual(calls["connect"][3][1:3], (10, ("192.0.2.10", 0)))

    def test_invalid_source_is_rejected_before_any_request(self):
        with self.assertRaises(ValueError):
            exec(compile(RUNNER, "mxh-certbot-dns", "exec"), {"DNS_API_SOURCE": "not-an-address"})


if __name__ == "__main__":
    unittest.main()
