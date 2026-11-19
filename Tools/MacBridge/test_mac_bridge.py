import hashlib
import http.client
import json
import os
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
import uuid
import jarvis_mac_bridge as bridge


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "project"
        self.root.mkdir()
        (self.root / "main.swift").write_text('let greeting = "안녕하세요"\n', encoding="utf-8")
        (self.root / "Sources").mkdir()
        (self.root / "Sources" / "other.swift").write_text("// greeting\n", encoding="utf-8")
        self.workspace = bridge.Workspace(self.root)

    def tearDown(self):
        self.workspace.close()
        self.temp.cleanup()

    def test_list_read_search_and_hash(self):
        entries, partial = self.workspace.listing("")
        self.assertFalse(partial)
        self.assertEqual({e["path"] for e in entries}, {"main.swift", "Sources"})
        value = self.workspace.read("main.swift")
        self.assertIn("안녕하세요", value["text"])
        self.assertEqual(value["sha256"], hashlib.sha256(value["text"].encode()).hexdigest())
        self.assertEqual(len(self.workspace.search("", "greeting")[0]), 2)
        self.assertEqual(self.workspace.search("", "[.*]")[0], [])

    def test_paths_links_hidden_and_sensitive_names_are_denied(self):
        outside = Path(self.temp.name) / "outside.swift"
        outside.write_text("private", encoding="utf-8")
        (self.root / "linked.swift").symlink_to(outside)
        os.link(outside, self.root / "hard.swift")
        (self.root / ".env").write_text("private", encoding="utf-8")
        (self.root / "secret.swift").write_text("private", encoding="utf-8")
        for path in ["../outside.swift", str(outside), "linked.swift", "hard.swift", ".env", "secret.swift", "Sources/../main.swift"]:
            with self.subTest(path=path), self.assertRaises(bridge.Denied):
                self.workspace.read(path)
        (self.root / "escape").symlink_to(Path(self.temp.name), target_is_directory=True)
        with self.assertRaises(bridge.Denied):
            self.workspace.listing("escape")

    def test_binary_large_and_secret_contents_are_denied(self):
        for name, data in [("binary.swift", b"hello\0world"), ("large.swift", b"x" * 65537),
                           ("settings.swift", b'let api_key = "sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'),
                           ("config.json", b'{"client_secret": "not-a-real-key-but-private"}')]:
            (self.root / name).write_bytes(data)
            with self.assertRaises(bridge.Denied):
                self.workspace.read(name)
        self.assertEqual(self.workspace.search("", "sk-")[0], [])

    def test_listing_bounded_and_source_is_not_executed(self):
        marker = Path(self.temp.name) / "executed"
        (self.root / "evil.py").write_text(f"open({str(marker)!r}, 'w').write('oops')", encoding="utf-8")
        self.workspace.read("evil.py")
        self.assertFalse(marker.exists())
        for index in range(100):
            (self.root / f"file{index}.txt").write_text("example", encoding="utf-8")
        entries, partial = self.workspace.listing("")
        self.assertEqual(len(entries), 80)
        self.assertTrue(partial)


class HTTPSTests(unittest.TestCase):
    def test_real_tls_auth_project_boundary_and_no_write_api(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            file = root / "demo.swift"
            file.write_text("let value = 7\n", encoding="utf-8")
            state = bridge.private_state(Path(temporary) / "identity")
            bridge.initialize(state, "127.0.0.1")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(state / "server.pem", state / "server.key")
            project, token = str(uuid.uuid4()), "test-only-authorization"
            workspace = bridge.Workspace(root)
            server = bridge.ReaderServer(("127.0.0.1", 0), workspace, context, token, project)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            def request(endpoint, authorized=True, project_id=project):
                connection = http.client.HTTPSConnection("127.0.0.1", server.server_port,
                    context=ssl.create_default_context(cafile=str(state / "server.pem")), timeout=5)
                headers = {"Content-Type": "application/json"}
                if authorized:
                    headers["Authorization"] = "Bearer " + token
                payload = dict(requestID=str(uuid.uuid4()), projectID=project_id, path="demo.swift", query="")
                try:
                    connection.request("POST", endpoint, body=json.dumps(payload), headers=headers)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()
            try:
                self.assertEqual(request("/v1/read", authorized=False)[0], 401)
                self.assertEqual(request("/v1/read", project_id=str(uuid.uuid4()))[0], 403)
                code, result = request("/v1/read")
                self.assertEqual(code, 200)
                self.assertEqual(result["file"]["text"], "let value = 7\n")
                self.assertEqual(request("/v1/write")[0], 403)
                self.assertEqual(request("/v1/execute")[0], 403)
                self.assertEqual(file.read_text(), "let value = 7\n")
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3)
                workspace.close()


if __name__ == "__main__":
    unittest.main()
