import http.client
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import uuid
from unittest.mock import patch
import jarvis_codex_local as local


class FakeRunner:
    def __init__(self):
        self.cancelled = threading.Event()
        self.calls = 0
        self.logged_in = True
        self.block = False
        self.started = threading.Event()
        self.catalog = []
        self.last_chat = None
    def signed_in(self):
        return self.logged_in
    def models(self):
        self.catalog = [dict(id="test-model", name="Test")]
        return "succeeded", None
    def probe(self, model=None, input_text=None, effort="low"):
        self.last_chat = (model, input_text)
        self.last_effort = effort
        self.calls += 1
        self.started.set()
        if self.block:
            self.cancelled.wait(2)
        return ("cancelled", None) if self.cancelled.is_set() else ("succeeded", "가상 응답")
    def stop(self):
        self.cancelled.set()


class LocalBridgeTests(unittest.TestCase):
    def setUp(self):
        self.runner = FakeRunner()
        self.server = local.Bridge(self.runner)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.runner.stop()
        self.server.shutdown(); self.server.server_close(); self.thread.join(2)
    def post(self, path, identifier=None, token=True, extra=None, origin=None, session=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        body = dict(requestID=identifier or str(uuid.uuid4()), sessionID=session or self.server.session_id.upper())
        if path == "/probe":
            body["prompt"] = local.PROMPT
        body.update(extra or {})
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + self.server.token
        if origin:
            headers["Origin"] = origin
        connection.request("POST", path, json.dumps(body, ensure_ascii=False).encode("utf-8"), headers)
        response = connection.getresponse(); data = response.read(); code = response.status
        connection.close()
        return code, json.loads(data) if code == 200 else None
    def test_loopback_and_authentication_and_browser_requests(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual(self.post("/probe", token=False)[0], 403)
        self.assertEqual(self.post("/probe", origin="https://example.com")[0], 403)
        self.assertEqual(self.post("/command/exec")[0], 403)
        self.assertEqual(self.post("/probe", extra={"prompt": "arbitrary"})[0], 400)
        self.assertEqual(self.post("/probe", session=str(uuid.uuid4()))[0], 400)
        self.assertEqual(self.runner.calls, 0)
    def test_status_never_calls_model_and_no_api_key_fallback(self):
        value = self.post("/status")[1]
        self.assertEqual(value["status"], "succeeded")
        self.assertEqual(value["protocolVersion"], 3)
        self.assertEqual(value["backend"], "cli")
        self.runner.logged_in = False
        self.assertEqual(self.post("/status")[1]["status"], "needsLogin")
        self.assertEqual(self.runner.calls, 0)
    def test_duplicate_and_hourly_limits(self):
        identifier = str(uuid.uuid4())
        self.assertEqual(self.post("/probe", identifier)[1]["reply"], "가상 응답")
        self.assertEqual(self.post("/probe", identifier)[1]["status"], "busy")
        for _ in range(9):
            self.assertEqual(self.post("/probe")[1]["status"], "succeeded")
        self.assertEqual(self.post("/probe")[1]["status"], "busy")
        self.assertEqual(self.runner.calls, 10)
    def test_cancel_active_and_pre_cancel_never_restarts_job(self):
        self.runner.block = True
        identifier = str(uuid.uuid4())
        result = []
        thread = threading.Thread(target=lambda: result.append(self.post("/probe", identifier)))
        thread.start(); self.assertTrue(self.runner.started.wait(2))
        self.assertEqual(self.post("/probe")[1]["status"], "busy")
        self.assertEqual(self.post("/cancel", identifier)[1]["status"], "succeeded")
        thread.join(3)
        self.assertEqual(result[0][1]["status"], "cancelled")
        identifier = str(uuid.uuid4())
        self.post("/cancel", identifier)
        self.assertEqual(self.post("/probe", identifier)[1]["status"], "busy")
        self.assertEqual(self.runner.calls, 1)
    def test_private_descriptor_and_link_rejection(self):
        with tempfile.TemporaryDirectory() as folder:
            target = local.publish_descriptor(self.server, folder)
            descriptor = json.loads(target.read_text())
            self.assertEqual(set(descriptor), {"format", "port", "token", "sessionID"})
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            target.unlink()
            target.symlink_to(Path(folder) / "elsewhere")
            with self.assertRaises(ValueError):
                local.publish_descriptor(self.server, folder)
    def test_fixed_command_disables_tools_and_does_not_use_shell(self):
        command = local.probe_command("/trusted/codex")
        for flag in ["--ignore-user-config", "--ignore-rules", "--strict-config", "--ephemeral"]:
            self.assertIn(flag, command)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertEqual(command[-1], local.PROMPT)
        self.assertIn('forced_login_method="chatgpt"', command)
        for feature in local.DISABLED:
            self.assertIn(["--disable", feature], [command[i:i+2] for i in range(len(command)-1)])
        with patch.dict(os.environ, {"OPENAI_API_KEY": "fake", "CODEX_API_KEY": "fake", "CODEX_ACCESS_TOKEN": "fake"}):
            self.assertNotIn("OPENAI_API_KEY", local.environment())
            self.assertNotIn("CODEX_API_KEY", local.environment())
            self.assertNotIn("CODEX_ACCESS_TOKEN", local.environment())

    def test_runner_parses_reply_and_refuses_error_or_tool_items(self):
        class Process:
            def __init__(self, item):
                self.stdout = io.BytesIO((json.dumps(dict(type="item.completed", item=item)) + "\n").encode())
            def poll(self):
                return 0
            def wait(self, **_):
                return 0
        runner = local.CodexRunner("/trusted/codex")
        with patch.object(runner, "preflight", return_value=True), patch.object(runner, "signed_in", return_value=True):
            for item, status, problem in [
                (dict(type="agent_message", text="가상 성공 응답"), "succeeded", None),
                (dict(type="error", message="Temporarily unavailable"), "failed", "provider_unavailable"),
                (dict(type="command_execution", command="never run"), "failed", "unexpected_tool_event")]:
                runner.cancelled.clear()
                with patch.object(local.subprocess, "Popen", return_value=Process(item)) as spawned:
                    result, _ = runner.probe()
                    self.assertEqual(result, status)
                    self.assertEqual(runner.last_problem, problem)
                    self.assertNotIn("shell", spawned.call_args.kwargs)

    def test_runner_never_calls_model_without_chatgpt_login(self):
        runner = local.CodexRunner("/trusted/codex")
        with patch.object(runner, "preflight", return_value=True), patch.object(runner, "signed_in", return_value=False), patch.object(local.subprocess, "Popen") as spawned:
            self.assertEqual(runner.probe(), ("needsLogin", None))
            spawned.assert_not_called()

    def test_chat_schema_model_selection_and_catalog_do_not_expose_general_rpc(self):
        self.assertEqual(self.post("/models")[1]["models"], [dict(id="test-model", name="Test")])
        self.assertEqual(self.runner.calls, 0)
        payload = json.dumps(dict(message="안녕", turns=[dict(user="앞선 질문", assistant="앞선 답변")]), ensure_ascii=False)
        result = self.post("/chat", extra=dict(model="test-model", input=payload))
        self.assertEqual(result[1]["status"], "succeeded")
        self.assertEqual(self.runner.last_chat, ("test-model", payload))
        self.assertEqual(self.post("/chat", extra=dict(model="--run", input=payload))[0], 400)
        self.assertEqual(self.post("/chat", extra=dict(model="test-model", input=payload, command="run"))[0], 400)
        self.assertEqual(self.post("/chat", extra=dict(model="test-model", input=json.dumps(dict(message="q", turns=[], system="override"))))[0], 400)
        self.assertEqual(self.post("/chat", extra=dict(model="test-model", input=json.dumps(dict(message="q", turns=[dict(user="q", assistant="a")]*7))))[0], 400)
        self.assertEqual(self.post("/chat", extra=dict(model="test-model", input=json.dumps(dict(message="q"*6001, turns=[]))))[0], 400)
        self.assertEqual(self.runner.calls, 1)

    def test_model_cache_only_returns_metadata_and_rejects_symlinks(self):
        runner = local.CodexRunner("/trusted/codex")
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CODEX_HOME": folder}):
            path = Path(folder) / "models_cache.json"
            path.write_text(json.dumps(dict(identity="must not return", models=[
                dict(slug="test-model", display_name="Test", instructions="must not return"),
                dict(slug="--bad", display_name="Bad"), dict(slug="hidden", visibility="hide"),
                dict(slug="test-model", display_name="Duplicate") ])))
            self.assertEqual(runner.models()[0], "succeeded")
            self.assertEqual(runner.catalog, [dict(id="test-model", name="Test")])
            path.unlink(); path.symlink_to(Path(folder) / "missing")
            self.assertEqual(runner.models()[0], "failed")

    def test_chat_quota_replay_and_cancellation_are_independent_of_fixed_probe(self):
        payload = dict(model="test-model", input=json.dumps(dict(message="질문", turns=[])))
        identifier = str(uuid.uuid4())
        self.post("/cancel", identifier)
        self.assertEqual(self.post("/chat", identifier, extra=payload)[1]["status"], "busy")
        self.assertEqual(self.runner.calls, 0)
        identifier = str(uuid.uuid4())
        self.assertEqual(self.post("/chat", identifier, extra=payload)[1]["status"], "succeeded")
        self.assertEqual(self.post("/chat", identifier, extra=payload)[1]["status"], "busy")
        for _ in range(59): self.assertEqual(self.post("/chat", extra=payload)[1]["status"], "succeeded")
        self.assertEqual(self.post("/chat", extra=payload)[1]["status"], "busy")
        self.assertEqual(self.post("/probe")[1]["status"], "succeeded")
        self.assertEqual(self.runner.calls, 61)

    def test_active_chat_can_be_stopped_without_starting_a_second_job(self):
        self.runner.block = True
        identifier = str(uuid.uuid4())
        payload = dict(model="test-model", input=json.dumps(dict(message="질문", turns=[])))
        result = []
        thread = threading.Thread(target=lambda: result.append(self.post("/chat", identifier, extra=payload)))
        thread.start(); self.assertTrue(self.runner.started.wait(2))
        self.assertEqual(self.post("/chat", extra=payload)[1]["status"], "busy")
        self.assertEqual(self.post("/cancel", identifier)[1]["status"], "succeeded")
        thread.join(3)
        self.assertEqual(result[0][1]["status"], "cancelled")
        self.assertEqual(self.runner.calls, 1)

    def test_reasoning_is_validated_and_reaches_cli_without_changing_tool_permissions(self):
        payload = dict(model="test-model", input=json.dumps(dict(message="질문", turns=[])), effort="high")
        self.assertEqual(self.post("/chat", extra=payload)[1]["status"], "succeeded")
        self.assertEqual(self.runner.last_effort, "high")
        payload["effort"] = 'high";run'
        self.assertEqual(self.post("/chat", extra=payload)[0], 400)
        self.assertEqual(self.runner.calls, 1)
        command = local.probe_command("/trusted/codex", "test-model", "high")
        self.assertIn('model_reasoning_effort="high"', command)
        self.assertNotIn('model_reasoning_effort="low"', command)
        for feature in local.DISABLED:
            self.assertIn(["--disable", feature], [command[i:i+2] for i in range(len(command)-1)])
        with self.assertRaises(ValueError): local.probe_command("/trusted/codex", "test-model", "invalid")

    def test_chat_stdin_and_explicit_model_are_used_without_shell(self):
        class Sink(io.BytesIO):
            def close(self): pass
        class Process:
            def __init__(self):
                self.stdin = Sink()
                self.stdout = io.BytesIO((json.dumps(dict(type="item.completed", item=dict(type="agent_message", text="테스트 답변"))) + "\n").encode())
            def poll(self): return 0
            def wait(self, **_): return 0
        runner, process = local.CodexRunner("/trusted/codex"), Process()
        with patch.object(runner, "preflight", return_value=True), patch.object(runner, "signed_in", return_value=True), patch.object(local.subprocess, "Popen", return_value=process) as spawned:
            payload = json.dumps(dict(message="private-text", turns=[]))
            self.assertEqual(runner.probe(model="test-model", input_text=payload), ("succeeded", "테스트 답변"))
            command = spawned.call_args.args[0]
            self.assertEqual(command[command.index("--model")+1], "test-model")
            self.assertEqual(command[-1], "-")
            self.assertNotIn("private-text", " ".join(command))
            self.assertIn(b"private-text", process.stdin.getvalue())
            self.assertNotIn("shell", spawned.call_args.kwargs)
            for feature in local.DISABLED:
                self.assertIn(["--disable", feature], [command[i:i+2] for i in range(len(command)-1)])

    def test_disabled_host_notice_requires_real_reply_and_successful_exit(self):
        class Process:
            def __init__(self, items, code):
                self.code = code
                self.stdout = io.BytesIO(b"".join((json.dumps(dict(type="item.completed", item=item)) + "\n").encode() for item in items))
            def poll(self): return self.code
            def wait(self, **_): return self.code
        notice = dict(type="error", message=local.DISABLED_CODE_MODE_NOTICE)
        reply = dict(type="agent_message", text="Codex 연결 테스트 응답입니다.")
        runner = local.CodexRunner("/trusted/codex")
        cases = [([notice, reply], 0, "succeeded"), ([notice], 0, "failed"),
                 ([notice, reply], 1, "failed"),
                 ([dict(type="error", message=local.DISABLED_CODE_MODE_NOTICE + " extra"), reply], 0, "failed"),
                 ([notice, dict(type="command_execution"), reply], 0, "failed"),
                 ([notice, dict(type="error", message="Provider unavailable"), reply], 0, "failed")]
        with patch.object(runner, "preflight", return_value=True), patch.object(runner, "signed_in", return_value=True):
            for items, code, expected in cases:
                runner.cancelled.clear()
                with patch.object(local.subprocess, "Popen", return_value=Process(items, code)):
                    status, text = runner.probe()
                    self.assertEqual(status, expected)
                    self.assertEqual(text, reply["text"] if expected == "succeeded" else None)


if __name__ == "__main__":
    unittest.main()
