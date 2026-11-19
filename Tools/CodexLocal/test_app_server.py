import base64
import http.client
import json
import os
from pathlib import Path
import queue
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

import jarvis_app_server as app
import jarvis_codex_local as local
import test_codex_local as fixtures

LOGIN_URL = "https://auth.openai.com/oauth/authorize?response_type=code&state=synthetic&code_challenge=fake&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"


class FakeRPC:
    def __init__(self, *_):
        self.cwd = "/private/isolated-test"
        self.events = queue.Queue(); self.closed = False; self.failure = None; self.collecting = False
        self.calls = []; self.count = 0; self.turn_count = 0; self.auth = True; self.block = False
        self.started = threading.Event(); self.answer = "가상 응답"; self.fail_turn = False
        self.lock = threading.RLock(); self.login_results = {}
        self.rate_limits = {'rateLimits': {'primary': {'usedPercent': 25, 'windowDurationMins': 300, 'resetsAt': 1900000000}, 'secondary': None}}
    def begin_events(self):
        while not self.events.empty(): self.events.get_nowait()
        self.collecting = True
    def request(self, method, params, **_):
        self.calls.append((method, params))
        if self.closed: raise app.ServerError()
        if method == "account/read": return {"account": {"type": "chatgpt"} if self.auth else None}
        if method == 'account/rateLimits/read': return self.rate_limits
        if method == "account/login/start":
            self.auth = False
            return dict(type="chatgpt", loginId=str(uuid.uuid4()), authUrl=LOGIN_URL)
        if method == "account/login/cancel": return {}
        if method == "account/logout": self.auth = False; return {}
        if method == "model/list": return {"data": [{"model": "test-model", "displayName": "Test", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}
        if method == "thread/start":
            self.count += 1; return {"thread": {"id": "thread-" + str(self.count)}}
        if method == "turn/start":
            self.turn_count += 1; turn = "turn-" + str(self.turn_count); self.started.set()
            if self.fail_turn: raise app.ServerError()
            if not self.block:
                self.events.put({"method": "item/completed", "params": {"threadId": params["threadId"], "turnId": turn,
                    "item": {"id": "reply-" + turn, "type": "agentMessage", "text": self.answer}}})
                self.events.put({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": turn, "status": "completed"}}})
            return {"turn": {"id": turn}}
        if method == "turn/steer": return {"turnId": params["expectedTurnId"]}
        if method in ("turn/interrupt", "thread/unsubscribe"): return {}
        raise AssertionError("unexpected RPC method")
    def close(self):
        self.closed = True; self.events.put({"fatal": "appserver_disconnected"})


class AppServerTests(unittest.TestCase):
    def test_usage_is_read_only_and_only_returns_valid_quota_fields(self):
        state, _ = self.runner.usage()
        self.assertEqual(state, 'succeeded')
        rpc = self.connections[0]
        self.assertEqual(self.runner.quota['primary']['usedPercent'], 25)
        self.assertEqual(rpc.turn_count, 0)
        self.assertIn('account/rateLimits/read', app.StdioRPC.METHODS)
        self.assertNotIn('command/exec', app.StdioRPC.METHODS)
        rpc.rate_limits = {'rateLimits': {'primary': {'usedPercent': 101}}}
        self.assertEqual(self.runner.usage()[0], 'failed')
        self.assertIsNone(self.runner.quota)
        rpc.rate_limits = {'rateLimits': None}
        self.assertEqual(self.runner.usage()[0], 'succeeded')
        self.assertIsNone(self.runner.quota)
    def setUp(self):
        self.connections = []
        def factory(*args):
            rpc = FakeRPC(*args); self.connections.append(rpc); return rpc
        self.runner = app.AppServerRunner("/trusted/codex", "/private/home", rpc_factory=factory)
    def tearDown(self): self.runner.stop()
    def send(self, conversation, message="질문", turns=None):
        return self.runner.probe(model="test-model", input_text=json.dumps(dict(message=message, turns=turns or [])),
                                 effort="low", conversation=conversation)
    def test_browser_login_is_owned_bounded_and_success_requires_account_verification(self):
        self.assertEqual(self.runner.login_start()[0], "succeeded")
        rpc = self.connections[0]; identifier = self.runner.pending_login
        self.assertTrue(app.valid_login_url(self.runner.auth_url))
        self.assertEqual(self.runner.status()[0], "needsLogin")
        self.assertFalse(rpc.closed, "status killed the callback server during browser login")
        self.assertEqual(self.runner.login_poll()[0], "succeeded")
        self.assertEqual(self.runner.login_state, "pending")
        rpc.login_results[identifier] = True; rpc.auth = True
        self.assertEqual(self.runner.login_poll()[0], "succeeded")
        self.assertEqual(self.runner.login_state, "completed")
        self.assertEqual(rpc.turn_count, 0)
        self.assertNotIn("apiKey", str([p for m, p in rpc.calls if m == "account/login/start"]))
    def test_cancel_expiry_and_logout_do_not_generate_or_keep_pending_login(self):
        self.runner.login_start(); first = self.connections[0]; identifier = self.runner.pending_login
        self.assertEqual(self.runner.login_cancel()[0], "succeeded")
        self.assertTrue(first.closed); self.assertIsNone(self.runner.pending_login)
        self.assertIn(("account/login/cancel", {"loginId": identifier}), first.calls)
        first.login_results[identifier] = True
        self.runner.login_poll(); self.assertEqual(self.runner.login_state, "cancelled")
        self.runner.login_start(); self.runner.login_deadline = 0
        self.runner.login_poll(); self.assertEqual(self.runner.login_state, "expired")
        self.assertEqual(self.runner.logout()[0], "succeeded")
        self.assertTrue(all(rpc.turn_count == 0 for rpc in self.connections))
    def test_notification_alone_cannot_claim_login_success_and_hostile_url_is_rejected(self):
        self.runner.login_start(); rpc = self.connections[0]
        rpc.login_results[self.runner.pending_login] = True
        self.runner.login_poll()
        self.assertEqual(self.runner.login_state, "failed")
        for url in [LOGIN_URL.replace("auth.openai.com", "evil.test"),
                    LOGIN_URL.replace("127.0.0.1", "evil.test"), LOGIN_URL + "&state=duplicate",
                    LOGIN_URL.replace("S256", "plain"), LOGIN_URL + "#fragment"]:
            self.assertFalse(app.valid_login_url(url))
    def test_same_conversation_reuses_native_thread_and_other_conversation_is_isolated(self):
        first = str(uuid.uuid4()); second = str(uuid.uuid4())
        self.assertEqual(self.send(first), ("succeeded", "가상 응답"))
        self.assertEqual(self.send(first, "후속", [dict(user="질문", assistant="가상 응답")])[0], "succeeded")
        self.assertEqual(self.connections[0].count, 1)
        self.assertEqual(self.send(second)[0], "succeeded")
        self.assertEqual(self.connections[0].count, 2)
        calls = self.connections[0].calls
        starts = [params for method, params in calls if method == "thread/start"]
        self.assertTrue(all(p["ephemeral"] and p["sandbox"] == "read-only" and p["approvalPolicy"] == "never" for p in starts))
        turns = [params for method, params in calls if method == "turn/start"]
        self.assertNotIn("turns", turns[1]["input"][0]["text"])
        self.assertEqual(turns[1]["effort"], "low")
    def test_mismatched_local_history_and_context_limit_rotate_thread(self):
        identifier = str(uuid.uuid4()); self.send(identifier)
        self.send(identifier, "현재", [dict(user="다른 이력", assistant="이전 응답")])
        self.assertEqual(self.connections[0].count, 2)
        self.runner.threads[identifier]["count"] = 6
        self.send(identifier, "다음", [dict(user="현재", assistant="가상 응답")])
        self.assertEqual(self.connections[0].count, 3)
        self.assertTrue(any(m == "thread/unsubscribe" for m, _ in self.connections[0].calls))
    def test_disconnect_never_retries_generation_and_next_explicit_send_restores_context(self):
        self.runner.status(); self.connections[0].fail_turn = True
        self.assertEqual(self.send(str(uuid.uuid4()))[0], "failed")
        self.assertEqual(self.connections[0].turn_count, 1)
        self.assertEqual(len(self.connections), 1)
        self.assertEqual(self.send(str(uuid.uuid4()))[0], "succeeded")
        self.assertEqual(len(self.connections), 2)
    def test_cancel_interrupts_only_owned_connection_and_prevents_late_success(self):
        self.runner.status(); rpc = self.connections[0]; rpc.block = True
        result = []
        work = threading.Thread(target=lambda: result.append(self.send(str(uuid.uuid4()))))
        work.start(); self.assertTrue(rpc.started.wait(2))
        deadline = time.monotonic() + 2
        while self.runner.active_turn is None and time.monotonic() < deadline: time.sleep(0.01)
        self.runner.stop(); work.join(3)
        self.assertEqual(result[0][0], "cancelled")
        self.assertTrue(rpc.closed)
        self.assertTrue(any(m == "turn/interrupt" for m, _ in rpc.calls))
        self.assertEqual(len(self.runner.threads), 0)
    def test_login_and_metadata_do_not_generate_and_wrong_auth_mode_is_not_accepted(self):
        self.assertEqual(self.runner.status()[0], "succeeded")
        self.assertEqual(self.runner.models()[0], "succeeded")
        self.assertEqual(self.connections[0].turn_count, 0)
        self.connections[0].auth = False
        self.assertEqual(self.send(str(uuid.uuid4()))[0], "needsLogin")
        self.assertEqual(self.connections[0].turn_count, 0)
        self.assertEqual(self.runner.catalog[0]["reasoningEfforts"], ["low"])
    def test_steering_only_addresses_active_turn(self):
        self.runner.status()
        rpc = self.connections[0]
        self.assertEqual(self.runner.steer("idle")[0], "busy")
        self.runner.active_turn = ("thread-current", "turn-current")
        self.assertEqual(self.runner.steer("추가 입력")[0], "succeeded")
        self.assertEqual(rpc.calls[-1], ("turn/steer", {
            "threadId": "thread-current", "expectedTurnId": "turn-current",
            "input": [{"type": "text", "text": "추가 입력"}],
        }))
        self.runner.cancelled.set()
        self.assertEqual(self.runner.steer("cancelled")[0], "busy")

    def test_bridge_rejects_stale_request_target_and_duplicate_steer(self):
        bridge = object.__new__(local.Bridge)
        bridge.runner = self.runner
        bridge.app_server = self.runner
        bridge.job_lock = threading.Lock()
        bridge.active = str(uuid.uuid4())
        bridge.active_backend = "appServer"
        bridge.active_action = "chat"
        bridge.seen = set()
        bridge.steers = 0
        identifier = str(uuid.uuid4())
        with patch.object(self.runner, "steer", return_value=("succeeded", None)) as steer:
            self.assertEqual(bridge.execute("steer", identifier, input_text="추가",
                backend="appServer", target=str(uuid.uuid4()))[0], "busy")
            self.assertEqual(bridge.execute("steer", identifier, input_text="추가",
                backend="appServer", target=bridge.active)[0], "succeeded")
            self.assertEqual(bridge.execute("steer", identifier, input_text="추가",
                backend="appServer", target=bridge.active)[0], "busy")
            steer.assert_called_once_with("추가")

    def test_model_catalog_follows_cursor_and_uses_valid_server_defaults(self):
        self.runner.status()
        rpc = self.connections[0]
        request = rpc.request
        pages = {
            None: {"data": [{"model": "first"}, {"model": "hidden", "hidden": True}], "nextCursor": "second-page"},
            "second-page": {"data": [{"model": "first"}, {
                "model": "second", "defaultReasoningEffort": "high",
                "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "high"}]
            }]},
        }
        with patch.object(rpc, "request", side_effect=lambda method, params, **kw:
                          pages[params.get("cursor")] if method == "model/list" else request(method, params, **kw)):
            self.assertEqual(self.runner.models()[0], "succeeded")
        self.assertEqual([model["id"] for model in self.runner.catalog], ["first", "second"])
        self.assertEqual(self.runner.catalog[1]["defaultReasoningEffort"], "high")
        self.assertEqual(rpc.turn_count, 0)

    def test_model_catalog_rejects_repeated_cursor_without_publishing_partial_results(self):
        self.runner.status()
        rpc = self.connections[0]
        request = rpc.request
        with patch.object(rpc, "request", side_effect=lambda method, params, **kw:
                          {"data": [{"model": "first"}], "nextCursor": "repeat"}
                          if method == "model/list" else request(method, params, **kw)):
            self.assertEqual(self.runner.models()[0], "failed")
        self.assertEqual(self.runner.catalog, [])
        self.assertEqual(rpc.turn_count, 0)
    def test_private_home_rejects_configuration_import_and_cloud_locations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertEqual(app.private_home(root), root.resolve())
            (root/"config.toml").write_text('model_provider="untrusted"')
            with self.assertRaises(app.ServerError): app.private_home(root)
        with self.assertRaises(app.ServerError): app.private_home('/private/tmp/CloudStorage/test')
    def test_command_is_stdio_and_tools_stay_disabled(self):
        command = app.server_command('/trusted/codex')
        self.assertIn('--stdio', command)
        self.assertIn('forced_login_method="chatgpt"', command)
        self.assertIn('sandbox_mode="read-only"', command)
        for feature in local.DISABLED:
            self.assertIn(['--disable', feature], [command[i:i+2] for i in range(len(command)-1)])
        self.assertNotIn('--listen', command)
    def test_missing_login_closes_cache_and_later_explicit_status_can_reconnect(self):
        self.runner.status(); old = self.connections[0]; old.auth = False
        self.assertEqual(self.runner.status()[0], 'needsLogin')
        self.assertTrue(old.closed); self.assertIsNone(self.runner.rpc)
        self.assertEqual(self.runner.status()[0], 'succeeded')
        self.assertEqual(len(self.connections), 2)
        self.assertEqual(sum(rpc.turn_count for rpc in self.connections), 0)
    def test_precancel_never_starts_a_process_and_oversized_output_is_not_success(self):
        self.runner.cancelled.set()
        self.assertEqual(self.send(str(uuid.uuid4()))[0], 'cancelled')
        self.assertEqual(len(self.connections), 0)
        self.runner.cancelled.clear(); self.runner.status()
        self.connections[0].answer = 'x' * 8193
        self.assertEqual(self.send(str(uuid.uuid4()))[0], 'failed')
        self.assertTrue(self.connections[0].closed)
    def test_live_conversations_are_bounded(self):
        for _ in range(42): self.assertEqual(self.send(str(uuid.uuid4()))[0], 'succeeded')
        self.assertEqual(len(self.runner.threads), 40)
        self.assertEqual(sum(method == 'thread/unsubscribe' for method, _ in self.connections[0].calls), 2)
    def test_code_proposal_uses_schema_no_tools_and_cannot_leak_into_normal_chat(self):
        self.runner.status(); rpc = self.connections[0]
        rpc.answer = json.dumps(dict(summary='합성 변경', edits=[dict(path='View.swift', old='let n = 1', new='let n = 2')]))
        payload = json.dumps(dict(instruction='수정', files=[dict(path='View.swift', text='let n = 1', startLine=1)], tree=['View.swift']))
        self.assertEqual(self.runner.probe(model='test-model', input_text=payload, effort='low', conversation=str(uuid.uuid4()), code=True)[0], 'succeeded')
        self.assertEqual(len(self.runner.threads), 0)
        parameters = next(p for m, p in rpc.calls if m == 'turn/start')
        self.assertEqual(parameters['outputSchema'], app.CODE_SCHEMA)
        self.assertEqual(app.CODE_SCHEMA['properties']['reads']['maxItems'], 8)
        self.assertEqual(app.CODE_SCHEMA['properties']['reads']['items']['properties']['lineCount']['maximum'], 600)
        self.assertEqual(parameters['sandboxPolicy'], {'type': 'readOnly'})
        self.assertEqual(parameters['approvalPolicy'], 'never')
        rpc.answer = '일반 대화'
        self.assertEqual(self.send(str(uuid.uuid4()))[0], 'succeeded')
        turns = [p for m, p in rpc.calls if m == 'turn/start']
        self.assertNotIn('View.swift', turns[-1]['input'][0]['text'])
        with self.assertRaises(ValueError): local.code_prompt(json.dumps(dict(instruction='x', files=[dict(path='../outside.swift', text='x', startLine=1)], tree=[])))
        with self.assertRaises(ValueError): local.code_prompt(json.dumps(dict(instruction='x', files=[], tree=[], command='forbidden')))
    def test_conversation_can_request_approved_source_without_native_tools(self):
        self.runner.status(); rpc = self.connections[0]
        rpc.answer = json.dumps(dict(summary='화면 소스를 읽어도 될까요?', edits=[], reads=[dict(path='View.swift', startLine=1, lineCount=80)]))
        payload = json.dumps(dict(instruction='화면을 변경해줘', files=[], tree=['View.swift'], context=[dict(user='제목 변경', assistant='제목을 논의했습니다.')]))
        result, text = self.runner.probe(model='test-model', input_text=payload, effort='low', conversation=str(uuid.uuid4()), code=True)
        self.assertEqual(result, 'succeeded')
        self.assertEqual(json.loads(text)['reads'][0]['path'], 'View.swift')
        self.assertEqual(len(self.runner.threads), 0)
        with self.assertRaises(ValueError): local.code_prompt(json.dumps(dict(instruction='x', files=[], tree=[], context=[dict(user='x', assistant='y')] * 4)))
    def test_runtime_update_closes_old_process_without_replaying_and_preserves_credentials(self):
        with patch.object(app, 'executable_revision', return_value=(1, 2, 3, 4)):
            self.runner.status()
        first = self.connections[0]
        with patch.object(app, 'executable_revision', return_value=(1, 2, 3, 5)):
            self.assertEqual(self.runner.status()[0], 'failed')
            self.assertEqual(self.runner.last_problem, 'appserver_runtime_changed')
            self.assertTrue(first.closed)
            self.assertEqual(self.runner.status()[0], 'succeeded')
        self.assertFalse(any(method == 'account/logout' for rpc in self.connections for method, _ in rpc.calls))
        self.assertTrue(all(rpc.turn_count == 0 for rpc in self.connections))


class BackendBridgeTests(fixtures.LocalBridgeTests):
    def setUp(self):
        super().setUp()
        self.native = FakeNative(); self.server.app_server = self.native
    def test_explicit_backend_routes_without_cli_fallback_and_rejects_rpc_or_paths(self):
        self.assertEqual(self.post('/status', extra={'backend': 'appServer'})[1]['backend'], 'appServer')
        payload = dict(backend='appServer', conversationID=str(uuid.uuid4()), model='test-model',
                       input=json.dumps(dict(message='질문', turns=[])))
        self.assertEqual(self.post('/chat', extra=payload)[1]['status'], 'succeeded')
        self.assertEqual(self.native.calls, 1); self.assertEqual(self.runner.calls, 0)
        bad = dict(payload); bad['conversationID'] = '../other'
        self.assertEqual(self.post('/chat', extra=bad)[0], 400)
        bad = dict(payload); bad['method'] = 'command/exec'
        self.assertEqual(self.post('/chat', extra=bad)[0], 400)
        self.native.logged_in = False
        self.assertEqual(self.post('/status', extra={'backend': 'appServer'})[1]['status'], 'needsLogin')
        self.assertEqual(self.runner.calls, 0)
    def test_account_status_returns_only_allowlisted_plan(self):
        class AccountRPC(FakeRPC):
            plan = "plus"
            def request(self, method, params, **kwargs):
                if method == "account/read":
                    return {"account": {"type": "chatgpt", "planType": self.plan, "email": "synthetic@example.invalid"}}
                return super().request(method, params, **kwargs)

        rpc = AccountRPC()
        native = app.AppServerRunner("/trusted/codex", "/private/test-only", rpc_factory=lambda *_: rpc)
        self.server.app_server = native
        try:
            status, result = self.post("/status", extra={"backend": "appServer"})
            self.assertEqual(status, 200)
            self.assertEqual(result["accountPlan"], "plus")
            self.assertNotIn("synthetic@example.invalid", json.dumps(result))
            rpc.plan = "unknown-plan"
            self.assertIsNone(self.post("/status", extra={"backend": "appServer"})[1]["accountPlan"])
            self.assertEqual(rpc.turn_count, 0)
        finally:
            native.stop()

    def test_chat_image_is_owned_by_helper_and_removed_after_turn(self):
        jpeg = bytes.fromhex("ffd8ffd9")
        observed_paths = []
        case = self

        class ImageRPC(FakeRPC):
            def request(self, method, params, **kwargs):
                if method == "turn/start":
                    attachment = params["input"][1]
                    case.assertEqual(attachment["type"], "localImage")
                    path = Path(attachment["path"])
                    case.assertEqual(path.parent, Path(self.cwd))
                    case.assertEqual(path.read_bytes(), jpeg)
                    case.assertEqual(path.stat().st_mode & 0o077, 0)
                    observed_paths.append(path)
                return super().request(method, params, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            rpc = ImageRPC()
            rpc.cwd = directory
            native = app.AppServerRunner("/trusted/codex", "/private/test-only", rpc_factory=lambda *_: rpc)
            self.server.app_server = native
            payload = dict(backend="appServer", conversationID=str(uuid.uuid4()), model="test-model",
                           input=json.dumps(dict(message="사진 설명", turns=[])),
                           imageJPEG=base64.b64encode(jpeg).decode())
            try:
                self.assertEqual(self.post("/chat", token=False, extra=payload)[0], 403)
                self.assertEqual(self.post("/chat", extra=dict(payload, path="/other/photo.jpg"))[0], 400)
                self.assertEqual(self.post("/chat", extra=dict(payload, imageJPEG="invalid"))[0], 400)
                self.assertEqual(self.post("/chat", extra=payload)[1]["status"], "succeeded")
                self.assertEqual(len(observed_paths), 1)
                self.assertFalse(observed_paths[0].exists())
                self.assertTrue(all(entry["ephemeral"] for entry in native.threads.values()))
                self.assertIsNone(native.sessions)
            finally:
                native.stop()

    def test_chat_stream_emits_only_current_turn_deltas_before_final_reply(self):
        release = threading.Event()

        class StreamingRPC(FakeRPC):
            def request(self, method, params, **kwargs):
                if method != "turn/start":
                    return super().request(method, params, **kwargs)
                thread = params["threadId"]
                for target, turn, text in [(thread, "old", "stale turn"), ("other", "current", "other chat"),
                                           (thread, "current", "생성 중")]:
                    self.events.put({"method": "item/agentMessage/delta",
                                     "params": {"threadId": target, "turnId": turn, "delta": text}})
                def complete():
                    if release.wait(4):
                        self.events.put({"method": "item/completed", "params": {
                            "threadId": thread, "turnId": "current",
                            "item": {"type": "agentMessage", "id": "reply", "text": "최종 답변"},
                        }})
                        self.events.put({"method": "turn/completed", "params": {
                            "threadId": thread, "turn": {"id": "current", "status": "completed"},
                        }})
                threading.Thread(target=complete, daemon=True).start()
                return {"turn": {"id": "current"}}

        native = app.AppServerRunner("/trusted/codex", "/private/test-only", rpc_factory=StreamingRPC)
        self.server.app_server = native
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        request_id = str(uuid.uuid4())
        try:
            conn.request("POST", "/chat", json.dumps({
                "requestID": request_id, "sessionID": self.server.session_id, "backend": "appServer",
                "conversationID": str(uuid.uuid4()), "model": "test-model",
                "input": json.dumps({"message": "질문", "turns": []}),
            }), {"Authorization": "Bearer " + self.server.token, "Content-Type": "application/json",
                 "Accept": "application/x-ndjson"})
            response = conn.getresponse()
            self.assertEqual(response.getheader("Content-Type"), "application/x-ndjson")
            self.assertEqual(json.loads(response.readline()), {"delta": "생성 중"})
            release.set()
            result = json.loads(response.readline())
            self.assertEqual((result["requestID"], result["status"], result["reply"]),
                             (request_id, "succeeded", "최종 답변"))
            self.assertEqual(response.read(), b"")
        finally:
            release.set()
            conn.close()
            native.stop()

    def test_cancel_must_target_the_active_backend(self):
        self.native.block = True
        identifier = str(uuid.uuid4()); result = []
        payload = dict(backend='appServer', conversationID=str(uuid.uuid4()), model='test-model', input=json.dumps(dict(message='질문', turns=[])))
        work = threading.Thread(target=lambda: result.append(self.post('/chat', identifier, extra=payload)))
        work.start(); self.assertTrue(self.native.started.wait(2))
        self.assertEqual(self.post('/cancel', identifier)[1]['status'], 'failed')
        self.assertFalse(self.native.cancelled.is_set())
        self.assertEqual(self.post('/cancel', identifier, extra={'backend':'appServer'})[1]['status'], 'succeeded')
        work.join(3)
        self.assertEqual(result[0][1]['status'], 'cancelled')
        self.assertEqual(self.runner.calls, 0)
    def test_auth_routes_are_fixed_backend_scoped_and_diagnostics_contain_no_user_data(self):
        rpc = FakeRPC()
        native = app.AppServerRunner('/trusted/codex', '/private/test-only', rpc_factory=lambda *_: rpc)
        self.server.app_server = native
        try:
            self.assertEqual(self.post('/loginStart', token=False, extra={'backend': 'appServer'})[0], 403)
            self.assertEqual(self.post('/loginStart')[0], 400)
            self.assertEqual(self.post('/loginStart', extra={'backend': 'appServer', 'apiKey': 'forbidden'})[0], 400)
            value = self.post('/loginStart', extra={'backend': 'appServer'})[1]
            self.assertEqual(value['authVersion'], 1)
            self.assertTrue(app.valid_login_url(value['authURL']))
            self.assertEqual(self.post('/loginPoll', extra={'backend': 'appServer'})[1]['loginState'], 'pending')
            self.assertEqual(self.post('/loginCancel', extra={'backend': 'appServer'})[1]['loginState'], 'cancelled')
            value = self.post('/diagnostics')[1]['diagnostics']
            self.assertEqual(set(value), {'helperBuild', 'pythonMajor', 'pythonMinor', 'requests', 'active', 'managed'})
            self.assertEqual(self.runner.calls + rpc.turn_count, 0)
            self.assertEqual(self.server.execute('unknown', str(uuid.uuid4()))[0], 'failed')
            self.assertEqual(self.runner.calls, 0)
        finally: native.stop()
    def test_code_http_is_explicit_scoped_and_never_a_command_proxy(self):
        rpc = FakeRPC()
        rpc.answer = json.dumps(dict(summary='변경', edits=[dict(path='View.swift', old='let n = 1', new='let n = 2')]))
        native = app.AppServerRunner('/trusted/codex', '/private/test-only', rpc_factory=lambda *_: rpc)
        self.server.app_server = native
        payload = dict(backend='appServer', model='test-model', input=json.dumps(dict(instruction='변경', files=[dict(path='View.swift', text='let n = 1', startLine=1)], tree=['View.swift'])))
        try:
            self.assertEqual(self.post('/codeDraft', token=False, extra=payload)[0], 403)
            self.assertEqual(self.post('/codeDraft', extra=dict(payload, backend='cli'))[0], 400)
            self.assertEqual(self.post('/codeDraft', extra=dict(payload, command='forbidden'))[0], 400)
            value = self.post('/codeDraft', extra=payload)[1]
            self.assertEqual(value['codeVersion'], 3)
            self.assertEqual(value['status'], 'succeeded')
            self.assertEqual(self.runner.calls, 0)
            self.assertEqual(rpc.turn_count, 1)
            self.assertFalse(native.threads)
        finally: native.stop()
    def test_usage_http_requires_auth_and_does_not_enable_other_providers(self):
        rpc = FakeRPC()
        native = app.AppServerRunner('/trusted/codex', '/private/test-only', rpc_factory=lambda *_: rpc)
        self.server.app_server = native
        try:
            self.assertEqual(self.post('/usage', token=False, extra={'backend': 'appServer'})[0], 403)
            self.assertEqual(self.post('/usage', extra={'backend': 'appServer', 'command': 'forbidden'})[0], 400)
            self.assertEqual(self.post('/usage', extra={'backend': 'claude'})[0], 400)
            value = self.post('/usage', extra={'backend': 'appServer'})[1]
            self.assertEqual(value['quota']['primary']['usedPercent'], 25)
            self.assertEqual(rpc.turn_count, 0)
        finally: native.stop()


class FakeNative(fixtures.FakeRunner):
    def status(self): return ('succeeded' if self.logged_in else 'needsLogin'), None
    def probe(self, model=None, input_text=None, effort='low', conversation=None):
        self.conversation = conversation
        return super().probe(model=model, input_text=input_text, effort=effort)


class RealStdioProtocolTests(unittest.TestCase):
    def test_native_reader_keeps_auth_completion_without_collecting_model_events(self):
        source = '''#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
 v=json.loads(line)
 if v.get('method')=='initialize': print(json.dumps({'id':v['id'],'result':{}}),flush=True)
 elif v.get('method')=='account/login/start':
  print(json.dumps({'method':'account/login/completed','params':{'loginId':'11111111-1111-1111-1111-111111111111','success':True,'error':None}}),flush=True)
  print(json.dumps({'id':v['id'],'result':{}}),flush=True)
'''
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory)/'fake-codex'; binary.write_text(source); binary.chmod(0o700)
            rpc = app.StdioRPC(str(binary), Path(directory)/'state')
            try:
                with self.assertRaises(app.ServerError): rpc.request('account/login/start', {'type': 'apiKey', 'apiKey': 'fake'})
                with self.assertRaises(app.ServerError): rpc.request('account/login/start', {'type': 'chatgptAuthTokens', 'accessToken': 'fake'})
                with self.assertRaises(app.ServerError): rpc.request('account/logout', {'home': '/elsewhere'})
                with self.assertRaises(app.ServerError): rpc.request('account/login/cancel', {'loginId': '../wrong'})
                rpc.request('account/login/start', {'type': 'chatgpt'})
                self.assertEqual(rpc.login_results, {'11111111-1111-1111-1111-111111111111': True})
                self.assertTrue(rpc.events.empty())
            finally: rpc.close()
    def test_local_fake_process_correlates_requests_and_refuses_tool_approval(self):
        # This subprocess is a deterministic fake executable, not Codex or a
        # model-generated shell. No OpenAI service or user home is accessed.
        source = '''#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
 v=json.loads(line)
 if v.get('method')=='initialize': print(json.dumps({'id':v['id'],'result':{}}),flush=True)
 elif v.get('method')=='account/read': print(json.dumps({'id':v['id'],'result':{'account':None}}),flush=True)
 elif v.get('method')=='turn/start': print(json.dumps({'id':'approval','method':'item/commandExecution/requestApproval','params':{}}),flush=True)
'''
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory)/'fake-codex'; binary.write_text(source); binary.chmod(0o700)
            rpc = app.StdioRPC(str(binary), Path(directory)/'state')
            try:
                self.assertEqual(rpc.request('account/read', {'refreshToken':False}), {'account':None})
                with self.assertRaises(app.ServerError): rpc.request('command/exec', {})
                with self.assertRaises(app.ServerError): rpc.request('turn/start', {}, timeout=3)
                self.assertEqual(rpc.failure, 'appserver_tool_blocked')
            finally: rpc.close()


if __name__ == '__main__': unittest.main()
