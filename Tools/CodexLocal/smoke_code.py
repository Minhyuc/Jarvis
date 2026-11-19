"""Opt-in: two synthetic conversational code turns; no real project files/tools."""
import argparse
import http.client
import json
from pathlib import Path
import shutil
import threading
import uuid
import jarvis_codex_local as local
from jarvis_app_server import AppServerRunner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-usage", action="store_true")
    args = parser.parse_args()
    if not args.confirm_usage: parser.error("Explicit usage confirmation is required")
    binary = shutil.which("codex") or "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    cli = local.CodexRunner(binary)
    native = AppServerRunner(binary, Path.home()/"Library/Application Support/JARVISCodexLocal/AppServer")
    server = local.Bridge(cli, app_server=native)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        def send(payload):
            body = dict(requestID=str(uuid.uuid4()), sessionID=server.session_id, backend='appServer', model='gpt-6.1-sol', effort='low', input=json.dumps(payload, ensure_ascii=False))
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=125)
            try:
                client.request('POST', '/codeDraft', json.dumps(body, ensure_ascii=False).encode(), {'Authorization': 'Bearer '+server.token, 'Content-Type': 'application/json'})
                response = client.getresponse(); data = json.loads(response.read(196609))
            finally: client.close()
            assert response.status == 200 and data['status'] == 'succeeded', 'Code proposal failed: '+str(data.get('reason'))
            assert data['codeVersion'] == 2
            return data
        instruction = 'View.swift의 count 값을 1에서 2로 바꿔줘. 소스가 없으면 먼저 reads로 View.swift의 첫 20줄을 요청하고, 소스가 있으면 기존 줄 하나만 교체해줘.'
        initial = send(dict(instruction=instruction, files=[], tree=['View.swift']))
        reading = json.loads(initial['reply'])
        assert reading['edits'] == [] and reading['reads'][0]['path'] == 'View.swift'
        assert not native.threads, 'Read request retained source thread'
        # Synthetic fixture sharing is explicitly covered by --confirm-usage.
        data = send(dict(instruction=instruction, files=[dict(path='View.swift', text='let count = 1\n', startLine=1)], tree=['View.swift']))
        proposal = json.loads(data['reply'])
        assert set(proposal) == {'summary', 'edits', 'reads'} and proposal['reads'] == [] and len(proposal['edits']) == 1
        edit = proposal['edits'][0]
        assert edit['path'] == 'View.swift' and edit['old'] in 'let count = 1\n' and '2' in edit['new']
        assert not native.threads, 'Code snapshot was retained for later chat'
        Path('/tmp/jarvis-code-live-proposal.json').write_text(data['reply'], encoding='utf-8')
        print('PASS: real model read request -> synthetic approved snapshot -> schema-constrained proposal; two model calls, no real project access/writes/shell')
    finally:
        cli.stop(); native.stop(); server.shutdown(); server.server_close(); worker.join(2)


if __name__ == '__main__': main()
