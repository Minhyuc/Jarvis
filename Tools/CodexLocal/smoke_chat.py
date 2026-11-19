"""Opt-in live test: two synthetic text turns, no user files or project data."""
import argparse
import http.client
import json
import shutil
from pathlib import Path
import threading
import uuid
import jarvis_codex_local as local


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-usage", action="store_true", help="Authorize two model requests that may consume Codex usage")
    parser.add_argument("--model", help="Optional explicit model ID; otherwise use the first recent catalog model")
    parser.add_argument("--effort", choices=local.EFFORTS, default="low")
    parser.add_argument("--backend", choices=("cli", "appServer"), default="cli")
    args = parser.parse_args()
    if not args.confirm_usage:
        parser.error("Pass --confirm-usage to authorize two synthetic model requests")
    runner = local.CodexRunner(shutil.which("codex"))
    from jarvis_app_server import AppServerRunner
    native = AppServerRunner(runner.binary, Path.home()/"Library/Application Support/JARVISCodexLocal/AppServer")
    server = local.Bridge(runner, app_server=native)
    conversation = str(uuid.uuid4())
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    def post(action, extra=None):
        body = dict(requestID=str(uuid.uuid4()), sessionID=server.session_id)
        if args.backend == "appServer":
            body["backend"] = "appServer"
            if action == "chat": body["conversationID"] = conversation
        body.update(extra or {})
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=125)
        try:
            connection.request("POST", "/" + action, json.dumps(body, ensure_ascii=False).encode("utf-8"),
                               {"Authorization": "Bearer " + server.token, "Content-Type": "application/json"})
            response = connection.getresponse()
            if response.status != 200: raise RuntimeError("Local HTTP request failed")
            return json.loads(response.read(32769))
        finally: connection.close()
    try:
        if post("status")["status"] != "succeeded": raise RuntimeError("ChatGPT login required")
        models = post("models").get("models") or []
        model = args.model or (models[0]["id"] if models else None)
        if not local.valid_model(model): raise RuntimeError("Specify a valid model ID")
        question = "이번 대화에서 확인 단어를 '푸른별'로 정할게. 한 문장으로 확인해줘."
        first = post("chat", dict(model=model, effort=args.effort, input=json.dumps(dict(message=question, turns=[]), ensure_ascii=False)))
        if first["status"] != "succeeded": raise RuntimeError("First response failed: " + str(first.get("reason")))
        second = post("chat", dict(model=model, effort=args.effort, input=json.dumps(dict(message="방금 정한 확인 단어만 답해줘.",
                           turns=[dict(user=question, assistant=first["reply"])]), ensure_ascii=False)))
        if second["status"] != "succeeded" or "푸른별" not in (second.get("reply") or ""):
            raise RuntimeError("Follow-up response failed")
        if args.backend == "appServer":
            if len(native.threads) != 1 or native.threads[conversation]["count"] != 2:
                raise RuntimeError("Native session was not reused")
        print("PASS: authenticated loopback, selected model, first response and follow-up context. Backend:", args.backend, "Model:", model, "effort:", args.effort)
    finally:
        runner.stop(); native.stop(); server.shutdown(); server.server_close(); thread.join(2)


if __name__ == "__main__":
    main()
