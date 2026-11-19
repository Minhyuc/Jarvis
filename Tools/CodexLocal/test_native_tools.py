import json
import http.client
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import jarvis_app_server as app
import jarvis_codex_local as local


class FakeNativeRPC:
    instances = []
    exit_code = 0
    mcp_error = False
    def __init__(self, binary, home, **options):
        self.calls = []
        self.options = options
        self.cwd = options.get("cwd") or "/tmp/jarvis-native-scratch"
        self.closed = False
        self.instances.append(self)
    def request(self, method, params, **kwargs):
        self.calls.append((method, params))
        if method == "command/exec":
            return dict(exitCode=self.exit_code, stdout="fixture", stderr="")
        if method == "thread/start":
            return {"thread": {"id": "native-test-thread"}}
        if method == "mcpServerStatus/list":
            return {"data": [{"name": "jarvis_tool", "tools": {"echo": {"name": "echo"}}}]}
        if method == "mcpServer/tool/call":
            return {"content": [{"type": "text", "text": "fixture"}], "isError": self.mcp_error}
        raise AssertionError("Unexpected RPC: " + method)
    def close(self):
        self.closed = True


class NativeToolsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        self.engine = app.AppServerRunner("/fake/codex", self.root / "home")
        self.identity = self.root.stat()
        FakeNativeRPC.instances = []
        FakeNativeRPC.exit_code = 0
        FakeNativeRPC.mcp_error = False
    def tearDown(self):
        self.engine.close()
        self.folder.cleanup()
    def payload(self, operation="command", **extra):
        value = dict(operation=operation, root=str(self.root),
                     rootIdentity=f"{self.identity.st_dev}:{self.identity.st_ino}")
        if operation in ("command", "verify"):
            value["command"] = ["/usr/bin/git", "status"]
        else:
            value["server"] = {"command": "python3", "args": ["fixture.py"]}
        return json.dumps(dict(value, **extra))
    def test_invalid_roots_and_cross_operation_fields_fail_before_launch(self):
        for extra in (dict(root="/"), dict(rootIdentity="stale"),
                      dict(command=[]), dict(server={"command": "bad"})):
            with self.assertRaises(ValueError):
                app.native_request(self.payload(**extra))
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            app.native_request(self.payload(root=str(link)))
    def test_command_uses_bounded_networkless_project_sandbox(self):
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            state, output = app.native_tool(self.engine, self.payload())
        self.assertEqual(state, "succeeded")
        rpc = FakeNativeRPC.instances[0]
        method, params = rpc.calls[0]
        self.assertEqual(method, "command/exec")
        self.assertEqual(params["sandboxPolicy"]["writableRoots"], [str(self.root)])
        self.assertFalse(params["sandboxPolicy"]["networkAccess"])
        self.assertEqual(params["timeoutMs"], 30000)
        self.assertTrue(rpc.closed)
        self.assertEqual(json.loads(output)["exitCode"], 0)
    def test_command_failure_is_not_reported_as_success(self):
        FakeNativeRPC.exit_code = 7
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            state, output = app.native_tool(self.engine, self.payload())
        self.assertEqual(state, "failed")
        self.assertEqual(json.loads(output)["exitCode"], 7)
    def test_mcp_discovery_never_starts_a_model_turn(self):
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            state, output = app.native_tool(self.engine, self.payload("mcpList"))
        self.assertEqual(state, "succeeded")
        rpc = FakeNativeRPC.instances[0]
        self.assertEqual([v[0] for v in rpc.calls], ["thread/start", "mcpServerStatus/list"])
        self.assertIn("echo", json.loads(output)["tools"])
        self.assertTrue(rpc.closed)
    def test_explicit_mcp_arguments_and_error_are_preserved(self):
        FakeNativeRPC.mcp_error = True
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            state, _ = app.native_tool(self.engine, self.payload("mcpCall", tool="echo", arguments='{"text":"fixture"}'))
        self.assertEqual(state, "failed")
        params = FakeNativeRPC.instances[0].calls[-1][1]
        self.assertEqual(params["arguments"], {"text": "fixture"})
    def test_cancelled_job_never_launches_and_server_requests_stay_blocked(self):
        self.engine.cancelled.set()
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            self.assertEqual(app.native_tool(self.engine, self.payload())[0], "cancelled")
        self.assertFalse(FakeNativeRPC.instances)
        self.assertNotIn("turn/start", app.NativeToolRPC.METHODS)
        self.assertNotIn("thread/shellCommand", app.NativeToolRPC.METHODS)
        self.assertNotIn("config/value/write", app.NativeToolRPC.METHODS)
    def test_stop_closes_active_native_process(self):
        rpc = FakeNativeRPC("/fake/codex", self.root / "home")
        self.engine.native_rpc = rpc
        self.engine.stop()
        self.assertTrue(rpc.closed)
        self.assertTrue(self.engine.cancelled.is_set())
        self.assertIsNone(self.engine.native_rpc)
    def test_model_verification_is_readonly_for_source_and_never_arbitrary_shell(self):
        with self.assertRaises(ValueError):
            app.native_request(self.payload(operation="verify", command=["/bin/sh", "-c", "echo unsafe"]))
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            state, _ = app.native_tool(self.engine, self.payload(operation="verify", command=["swift", "test"]))
        self.assertEqual(state, "succeeded")
        params = FakeNativeRPC.instances[-1].calls[0][1]
        self.assertNotEqual(params["cwd"], str(self.root))
        self.assertNotIn(str(self.root), params["sandboxPolicy"]["writableRoots"])
        self.assertIn("--package-path", params["command"])
        self.assertFalse(params["sandboxPolicy"]["networkAccess"])
        self.assertEqual(params["timeoutMs"], 60000)
    def test_streamed_output_is_correlated_decoded_and_returned(self):
        import base64
        class StreamingRPC(FakeNativeRPC):
            def request(inner, method, params, **kwargs):
                if method == "command/exec":
                    data = "검증 출력\n".encode()
                    for chunk in (data[:1], data[1:]):
                        inner.on_notification("command/exec/outputDelta", {
                            "processId": params["processId"], "stream": "stdout",
                            "deltaBase64": base64.b64encode(chunk).decode(), "capReached": False})
                    return dict(exitCode=0, stdout="", stderr="")
                return super().request(method, params, **kwargs)
        received = []
        with patch.object(app, "NativeToolRPC", StreamingRPC):
            state, result = app.native_tool(self.engine, self.payload(), on_delta=received.append)
        self.assertEqual(state, "succeeded")
        self.assertEqual("".join(received), "검증 출력\n")
        self.assertEqual(json.loads(result)["stdout"], "검증 출력\n")


class NativeToolHTTPTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        self.engine = app.AppServerRunner("/fake/codex", self.root / "home")
        self.server = local.Bridge(object(), app_server=self.engine)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.engine.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.folder.cleanup()
    def post(self, identifier=None, token=True, origin=None, backend="appServer"):
        identity = self.root.stat()
        value = dict(operation="command", root=str(self.root),
                     rootIdentity=f"{identity.st_dev}:{identity.st_ino}", command=["/usr/bin/true"])
        body = dict(requestID=identifier or str(uuid.uuid4()), sessionID=self.server.session_id,
                    backend=backend, input=json.dumps(value))
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + self.server.token
        if origin:
            headers["Origin"] = origin
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.request("POST", "/nativeTool", json.dumps(body).encode(), headers)
        response = connection.getresponse()
        status, data = response.status, response.read()
        connection.close()
        return status, json.loads(data) if status == 200 else None
    def test_native_endpoint_rejects_browser_cli_and_unauthenticated_requests(self):
        self.assertEqual(self.post(token=False)[0], 403)
        self.assertEqual(self.post(origin="https://example.com")[0], 403)
        self.assertEqual(self.post(backend="cli")[0], 400)
    def test_native_endpoint_executes_exactly_once_and_reports_version(self):
        identifier = str(uuid.uuid4())
        FakeNativeRPC.exit_code = 0
        with patch.object(app, "NativeToolRPC", FakeNativeRPC):
            code, value = self.post(identifier)
            self.assertEqual(code, 200)
            self.assertEqual(value["status"], "succeeded")
            self.assertEqual(value["nativeVersion"], 1)
            self.assertEqual(self.post(identifier)[1]["status"], "busy")
