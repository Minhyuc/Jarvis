"""Restart, attachment and native-tool regressions without model calls or user credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch
import jarvis_app_server as app
from test_app_server import FakeRPC


class PersistentRPC(FakeRPC):
    def request(self, method, params, **kwargs):
        if method in ('thread/resume', 'thread/fork'):
            self.calls.append((method, params))
            return {'thread': {'id': 'forked-thread' if method == 'thread/fork' else params['threadId']}}
        return super().request(method, params, **kwargs)


class ExpansionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / 'AppServer'
        self.alias = str(uuid.uuid4())
        self.runners = []
    def tearDown(self):
        for runner in self.runners: runner.stop()
        self.temporary.cleanup()
    def runner(self):
        rpc = PersistentRPC(); rpc.cwd = str(self.root)
        runner = app.AppServerRunner('/trusted/codex', self.home, rpc_factory=lambda *_: rpc)
        runner.sessions = app.SessionRegistry(self.home)
        self.runners.append(runner)
        return runner, rpc
    def send(self, runner, message='질문', turns=None, **extra):
        return runner.probe('test-model', json.dumps({'message':message,'turns':turns or []}),
                            conversation=self.alias, **extra)
    def test_restart_resumes_only_matching_acknowledged_private_session(self):
        first, _ = self.runner()
        self.assertEqual(self.send(first)[0], 'succeeded')
        first.close()
        second, rpc = self.runner()
        self.assertEqual(self.send(second, '계속', [{'user':'질문','assistant':'가상 응답'}])[0], 'succeeded')
        self.assertIn('thread/resume', [method for method, _ in rpc.calls])
        self.assertEqual(second.last_session_status, 'resumed')
        stored = (self.home/'jarvis_sessions.json').read_text()
        self.assertNotIn('질문', stored); self.assertNotIn('가상 응답', stored)
        self.assertEqual((self.home/'jarvis_sessions.json').stat().st_mode & 0o777, 0o600)
    def test_stale_history_or_pending_turn_never_resumes(self):
        first, _ = self.runner(); self.send(first)
        entry = dict(first.sessions.entries[self.alias], pending=True)
        first.sessions.save(self.alias, entry); first.close()
        second, rpc = self.runner()
        self.assertEqual(self.send(second, '다시', [{'user':'질문','assistant':'가상 응답'}])[0], 'succeeded')
        self.assertNotIn('thread/resume', [method for method, _ in rpc.calls])
        second.close()
        third, rpc = self.runner(); self.send(third, '다른 문맥')
        self.assertNotIn('thread/resume', [method for method, _ in rpc.calls])
    def test_fork_uses_verified_source_and_turn(self):
        first, _ = self.runner(); self.send(first)
        source = self.alias; self.alias = str(uuid.uuid4())
        self.assertEqual(self.send(first, '분기 질문', [{'user':'질문','assistant':'가상 응답'}], fork_source=source)[0], 'succeeded')
        self.assertEqual(first.last_session_status, 'forked')
        self.assertNotEqual(first.sessions.entries[source]['id'], first.sessions.entries[self.alias]['id'])
    def test_corrupt_registry_is_preserved_and_not_used(self):
        self.home.mkdir(mode=0o700)
        path = self.home/'jarvis_sessions.json'; path.write_text('{broken'); path.chmod(0o600)
        runner, _ = self.runner()
        self.assertFalse(runner.sessions.available)
        self.assertEqual(self.send(runner)[0], 'succeeded')
        self.assertEqual(path.read_text(), '{broken')
        self.assertTrue(next(iter(runner.threads.values()))['ephemeral'])
    def test_failed_turn_keeps_uncertain_marker(self):
        runner, rpc = self.runner(); rpc.fail_turn = True
        self.assertEqual(self.send(runner)[0], 'failed')
        self.assertTrue(app.SessionRegistry(self.home).entries[self.alias]['pending'])
    def test_verification_command_proposal_is_accepted(self):
        runner, rpc = self.runner()
        rpc.answer = json.dumps({'summary':'테스트 제안','edits':[], 'commands':[{'argv':['swift','test'],'reason':'검증'}]})
        # Use the same schema emitted by Swift, with no execution approval.
        value = {'instruction':'테스트해줘','files':[], 'tree':['View.swift'], 'context':[], 'toolResults':[]}
        self.assertEqual(runner.probe('test-model', json.dumps(value), conversation=self.alias, code=True)[0], 'succeeded')
        self.assertFalse(runner.threads)
    def test_documents_remain_data_and_images_are_ephemeral(self):
        runner, rpc = self.runner()
        value = {'message':'요약', 'turns':[], 'documents':[{'name':'test.txt','text':'외부 자료','truncated':False}]}
        self.assertEqual(runner.probe('test-model', json.dumps(value), conversation=self.alias,
                                     image=[bytes.fromhex('ffd8ffd9')]*2)[0], 'succeeded')
        self.assertFalse(runner.sessions.entries)
        images = next(params['input'] for method, params in rpc.calls if method == 'turn/start')
        self.assertEqual(len([v for v in images if v['type']=='localImage']), 2)
        self.assertTrue(all(not Path(v['path']).exists() for v in images if v['type']=='localImage'))
        self.assertEqual(self.send(runner, '그 자료에서', [{'user':'요약','assistant':'가상 응답'}])[0], 'succeeded')
        self.assertFalse(runner.sessions.entries)
    def request(self, operation, **extra):
        info = self.root.stat()
        return json.dumps(dict(operation=operation,root=str(self.root),rootIdentity=f'{info.st_dev}:{info.st_ino}',**extra))
    def test_http_and_plugin_selectors_reject_credentials_and_injection(self):
        for url in ['https://example.com/mcp', 'http://127.0.0.1:1234/mcp']:
            app.native_request(self.request('mcpLogin', server={'command':'','args':[],'url':url}))
        for url in ['http://example.com/mcp','https://user:secret@example.com/mcp','https://example.com/?token=abc','https://example.com:abc/mcp']:
            with self.assertRaises(ValueError): app.native_request(self.request('mcpLogin', server={'command':'','args':[],'url':url}))
        for operation, command in [('pluginAdd',['--help']),('pluginRemove',['bad;rm']),('gitDiff',['../other']),('gitDiff',['.git/config'])]:
            with self.assertRaises(ValueError): app.native_request(self.request(operation,command=command))
    def test_real_git_lists_and_compares_without_mutation(self):
        subprocess.run(['/usr/bin/git','init','-q',str(self.root)],check=True)
        file=self.root/'View.swift'; file.write_text('let n = 1\n')
        subprocess.run(['/usr/bin/git','-C',str(self.root),'add','View.swift'],check=True)
        file.write_text('let n = 2\n')
        marker=self.root/'filter-executed'
        (self.root/'.gitattributes').write_text('*.swift filter=unsafe\n')
        subprocess.run(['/usr/bin/git','-C',str(self.root),'config','filter.unsafe.clean','/usr/bin/touch '+str(marker)],check=True)
        subprocess.run(['/usr/bin/git','-C',str(self.root),'config','filter.unsafe.required','true'],check=True)
        runner, _ = self.runner()
        state, text = app.native_tool(runner,self.request('gitStatus',command=[]))
        self.assertEqual(state,'succeeded')
        self.assertIn('View.swift',[v['path'] for v in json.loads(text)['files']])
        state, text = app.native_tool(runner,self.request('gitDiff',command=['View.swift']))
        self.assertEqual(state,'succeeded')
        self.assertIn('+let n = 2',json.loads(text)['working'])
        self.assertIn('+let n = 1',json.loads(text)['staged'])
        self.assertEqual(file.read_text(),'let n = 2\n')
        self.assertFalse(marker.exists(), 'Git read-only inspection executed a repository filter')
    def test_plugin_install_is_fixed_cli_in_separate_profile(self):
        runner,_=self.runner()
        with patch.object(app,'native_program',return_value=(0,'{"installed":true}')) as program:
            self.assertEqual(app.native_tool(runner,self.request('pluginAdd',command=['example@local']))[0],'succeeded')
            argv,env=program.call_args.args[1:3]
            self.assertEqual(argv,['/trusted/codex','--disable','hooks','plugin','add','example@local','--json'])
            self.assertEqual(env['CODEX_HOME'],str(self.root/'PluginLibrary'))
    def test_http_mcp_oauth_keeps_rpc_only_until_completion(self):
        runner,_=self.runner()
        server={'command':'','args':[],'url':'https://example.com/mcp'}
        class OAuthRPC:
            def __init__(self,*args,**kwargs): self.closed=False
            def request(self,method,params,**kwargs):
                if method=='thread/start': return {'thread':{'id':'test-thread'}}
                if method=='mcpServer/oauth/login': return {'authorizationUrl':'https://example.com/authorize'}
                raise AssertionError(method)
            def close(self): self.closed=True
        with patch.object(app,'NativeToolRPC',OAuthRPC):
            state,text=app.native_tool(runner,self.request('mcpLogin',server=server))
            self.assertEqual(state,'succeeded'); self.assertEqual(json.loads(text)['status'],'pending')
            rpc=runner.mcp_login['rpc']; self.assertFalse(rpc.closed)
            rpc.on_notification('mcpServer/oauthLogin/completed',{'name':'jarvis_'+app.hashlib.sha256(server['url'].encode()).hexdigest()[:16],'success':True})
            state,text=app.native_tool(runner,self.request('mcpLoginPoll',server=server))
            self.assertEqual(json.loads(text)['status'],'completed'); self.assertTrue(rpc.closed)
            self.assertIsNone(runner.mcp_login)

    def test_cancelled_native_program_never_starts_a_child(self):
        runner, _ = self.runner(); runner.stop()
        with patch.object(app.subprocess, 'Popen') as spawn:
            with self.assertRaises(app.ServerError):
                app.native_program(runner, ['/usr/bin/true'], {}, str(self.root))
            spawn.assert_not_called()
