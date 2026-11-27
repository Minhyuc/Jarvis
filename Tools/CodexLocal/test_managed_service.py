"""Managed lifecycle without credentials, filesystem publication or model calls."""
import io
import json
import os
import threading
import unittest
from unittest.mock import patch
import jarvis_codex_local as local
from test_codex_local import FakeRunner


class ManagedServiceTests(unittest.TestCase):
    def test_private_bootstrap_and_eof_stop_both_owned_backends(self):
        cli, native = FakeRunner(), FakeRunner()
        server = local.Bridge(cli, app_server=native)
        reader, writer = os.pipe()
        output = io.StringIO()
        source = os.fdopen(reader, "rb")
        try:
            with patch.object(local, "publish_descriptor", side_effect=AssertionError("must not publish")):
                local.managed_bootstrap(server, cli, native, source, output)
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                descriptor = json.loads(output.getvalue())
                self.assertEqual(set(descriptor), {"format", "port", "sessionID", "token"})
                self.assertEqual(descriptor["port"], server.server_port)
                self.assertEqual(len(descriptor["token"]), 64)
                self.assertEqual(cli.calls + native.calls, 0)
                os.close(writer)
                worker.join(3)
                self.assertFalse(worker.is_alive())
                self.assertTrue(cli.cancelled.is_set())
                self.assertTrue(native.cancelled.is_set())
                self.assertEqual(cli.calls + native.calls, 0)
        finally:
            source.close()
            server.server_close()


class PortableBridgeTests(unittest.TestCase):
    def test_portable_mode_never_uses_desktop_cli_account(self):
        import uuid
        cli, native = FakeRunner(), FakeRunner()
        server = local.Bridge(cli, app_server=native)
        try:
            with patch.dict(os.environ, {"JARVIS_STORAGE_ROOT":"/Volumes/JARVIS/Jarvis"}):
                status, value = server.execute("probe",str(uuid.uuid4()),backend="cli")
            self.assertEqual(status,"failed")
            self.assertEqual(cli.calls + native.calls,0)
        finally: server.server_close()
