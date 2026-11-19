"""Persisted development-agent history is private metadata, not an approval journal."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import uuid
import jarvis_app_server as app
from test_agent_runtime import DynamicRPC
from test_app_server import FakeRPC

class HistoryRPC(DynamicRPC):
    def request(self,method,params,**kwargs):
        if method in ('thread/start','thread/fork'):
            self.thread='thread-'+str(uuid.uuid4());self.calls.append((method,params));return {'thread':{'id':self.thread}}
        if method=='thread/resume':
            self.thread=params['threadId'];self.calls.append((method,params));return {'thread':{'id':self.thread}}
        return super().request(method,params,**kwargs)

class ManagementRPC(FakeRPC):
    def __init__(self,*args,**kwargs):super().__init__();self.fail_compaction=False
    def request(self,method,params,**kwargs):
        self.calls.append((method,params))
        if method=='thread/turns/list':return {'data':[{'id':'turn','status':'completed','items':[{'type':'agentMessage','text':'공개 답변'},{'type':'dynamicToolCall','arguments':'do not expose source'}]}],'nextCursor':None}
        if method=='thread/compact/start':
            if self.fail_compaction:raise app.ServerError('appserver_request_failed')
            self.events.put({'method':'item/completed','params':{'threadId':params['threadId'],'item':{'type':'contextCompaction'}}})
            self.events.put({'method':'turn/completed','params':{'threadId':params['threadId'],'turn':{'status':'completed'}}})
            return {}
        if method.startswith('thread/'):return {'thread':{'id':params['threadId']}}
        raise AssertionError(method)

class AgentHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.home=self.root/'profile'
        self.engine=app.AppServerRunner('/trusted/codex',self.home,rpc_factory=lambda *_:None)
        self.engine.agent_history=app.AgentHistoryRegistry(self.home);self.jobs=[]
        info=self.root.stat();self.alias=str(uuid.uuid4())
        self.data={'jobID':str(uuid.uuid4()),'conversationID':self.alias,'root':str(self.root),'rootIdentity':f'{info.st_dev}:{info.st_ino}',
            'model':'test-model','effort':'low','message':'비공개 사용자 질문','turns':[],'binding':'a'*64}
    def tearDown(self):
        for job in self.jobs:job.stop();job.worker.join(timeout=2)
        self.engine.stop();self.temp.cleanup()
    def run_job(self,extra=None,actions=None):
        data=dict(self.data,jobID=str(uuid.uuid4()));data.update(extra or {})
        rpc=HistoryRPC();rpc.actions=list(actions or [])
        job=app.AgentSession(self.engine,data,rpc_factory=lambda *a,**k:rpc);self.jobs.append(job);job.worker.start()
        expires=time.monotonic()+3
        while job.state=='running' and time.monotonic()<expires:time.sleep(.005)
        self.assertNotEqual(job.state,'running');return job,rpc
    def management(self,operation,alias=None):return {'operation':operation,'root':str(self.root),'rootIdentity':self.data['rootIdentity'],'conversationID':alias or self.alias,'jobID':str(uuid.uuid4())}
    def test_restart_resume_requires_ack_root_profile_and_completed_turn(self):
        first,_=self.run_job();self.assertEqual(first.state,'completed')
        self.engine.agent_history=app.AgentHistoryRegistry(self.home)
        second,rpc=self.run_job({'resumeTurn':first.turn})
        self.assertEqual(second.mode,'resumed');self.assertIn('thread/resume',[m for m,_ in rpc.calls])
        self.assertEqual(second.thread,first.thread)
        data=(self.home/'jarvis_agent_history.json').read_text()
        self.assertNotIn(self.data['message'],data);self.assertNotIn('공개 답변',data)
        self.assertEqual((self.home/'jarvis_agent_history.json').stat().st_mode&0o777,0o600)
    def test_missing_ack_or_changed_profile_reconstructs_and_retains_previous_history(self):
        first,_=self.run_job()
        second,rpc=self.run_job({'binding':'b'*64,'resumeTurn':first.turn})
        self.assertEqual(second.mode,'reconstructed');self.assertNotEqual(first.thread,second.thread)
        self.assertNotIn('thread/resume',[m for m,_ in rpc.calls]);self.assertEqual(len(self.engine.agent_history.entries),2)
        self.assertTrue(any(value['id']==first.thread for value in self.engine.agent_history.entries.values()))
    def test_pending_cancelled_turn_never_resumes_or_replays_tool(self):
        job,_=self.run_job(actions=[('jarvis_project_list',{})]);self.assertEqual(job.state,'awaitingApproval');job.stop()
        second,rpc=self.run_job({'resumeTurn':'unknown'})
        self.assertEqual(second.mode,'reconstructed');self.assertNotIn('thread/resume',[m for m,_ in rpc.calls])
        self.assertEqual(rpc.answers,[])
    def test_fork_pins_source_ack_and_root(self):
        original,_=self.run_job()
        branch,rpc=self.run_job({'conversationID':str(uuid.uuid4()),'forkSource':self.alias,'forkTurn':original.turn})
        self.assertEqual(branch.mode,'forked');self.assertNotEqual(branch.thread,original.thread)
        params=next(p for m,p in rpc.calls if m=='thread/fork');self.assertEqual(params['lastTurnId'],original.turn)
    def test_bad_registry_is_preserved(self):
        file=self.home/'jarvis_agent_history.json';file.write_text('{broken');file.chmod(0o600)
        registry=app.AgentHistoryRegistry(self.home);self.assertFalse(registry.available)
        with self.assertRaises(app.ServerError):registry.save(self.alias,None)
        self.assertEqual(file.read_text(),'{broken')
    def test_scope_archive_restore_delete_are_verified_and_no_authorization_is_restored(self):
        self.run_job();rpc=ManagementRPC()
        for operation,archived in [('archive',True),('unarchive',False)]:
            state,text=app.agent_history_operation(self.engine,'agentHistoryChange',self.management(operation),rpc_factory=lambda *a,**k:rpc)
            self.assertEqual(state,'succeeded');self.assertTrue(json.loads(text)['verified'])
            self.assertEqual(self.engine.agent_history.entries[self.alias]['archived'],archived)
        data=self.management('read')
        text=app.agent_history_operation(self.engine,'agentHistoryRead',data,rpc_factory=lambda *a,**k:rpc)[1]
        self.assertIn('공개 답변',text);self.assertNotIn('do not expose source',text)
        self.assertEqual(app.agent_history_operation(self.engine,'agentHistoryChange',self.management('delete'),rpc_factory=lambda *a,**k:rpc)[0],'succeeded')
        self.assertNotIn(self.alias,self.engine.agent_history.entries)
    def test_archived_session_cannot_silently_start_or_resume(self):
        first,_=self.run_job();entry=self.engine.agent_history.entries[self.alias]
        self.engine.agent_history.save(self.alias,dict(entry,archived=True))
        job,rpc=self.run_job({'resumeTurn':first.turn})
        self.assertEqual(job.state,'failed');self.assertNotIn('turn/start',[m for m,_ in rpc.calls])
    def test_archive_restore_cannot_clear_an_unacknowledged_task(self):
        first,_=self.run_job();entry=self.engine.agent_history.entries[self.alias]
        self.engine.agent_history.save(self.alias,dict(entry,pending=True))
        rpc=ManagementRPC()
        for operation in ('archive','unarchive'):
            app.agent_history_operation(self.engine,'agentHistoryChange',self.management(operation),rpc_factory=lambda *a,**k:rpc)
        self.assertTrue(self.engine.agent_history.entries[self.alias]['pending'])
        job,rpc=self.run_job({'resumeTurn':first.turn})
        self.assertEqual(job.mode,'reconstructed');self.assertNotIn('thread/resume',[m for m,_ in rpc.calls])
    def test_compaction_requires_real_completion_and_failure_preserves_uncertainty(self):
        self.run_job();rpc=ManagementRPC()
        self.assertEqual(app.agent_history_operation(self.engine,'agentHistoryChange',self.management('compact'),rpc_factory=lambda *a,**k:rpc)[0],'succeeded')
        self.assertFalse(self.engine.agent_history.entries[self.alias]['pending'])
        rpc=ManagementRPC();rpc.fail_compaction=True
        with self.assertRaises(app.ServerError):app.agent_history_operation(self.engine,'agentHistoryChange',self.management('compact'),rpc_factory=lambda *a,**k:rpc)
        self.assertTrue(self.engine.agent_history.entries[self.alias]['pending'])
    def test_cancelled_admin_request_never_touches_native_history(self):
        self.run_job();data=self.management('delete');self.engine.agent_stopped.add(data['jobID'])
        rpc=ManagementRPC()
        with self.assertRaises(app.ServerError):app.agent_history_operation(self.engine,'agentHistoryChange',data,rpc_factory=lambda *a,**k:rpc)
        self.assertEqual(rpc.calls,[]);self.assertIn(self.alias,self.engine.agent_history.entries)
    def test_cancel_during_native_mutation_preserves_pending_instead_of_reporting_success(self):
        self.run_job();data=self.management('archive');rpc=ManagementRPC()
        request=rpc.request
        def cancel(method,params,**kwargs):
            value=request(method,params,**kwargs)
            self.engine.agent_stopped.add(data['jobID']);self.engine.stop()
            return value
        rpc.request=cancel
        with self.assertRaises(app.ServerError):app.agent_history_operation(self.engine,'agentHistoryChange',data,rpc_factory=lambda *a,**k:rpc)
        self.assertTrue(self.engine.agent_history.entries[self.alias]['pending'])
        self.assertFalse(self.engine.agent_history.entries[self.alias]['archived'])
    def test_no_ack_reconstructs_and_large_session_requires_explicit_compaction(self):
        first,_=self.run_job()
        second,rpc=self.run_job()
        self.assertEqual(second.mode,'reconstructed');self.assertNotIn('thread/resume',[m for m,_ in rpc.calls])
        entry=self.engine.agent_history.entries[self.alias]
        self.engine.agent_history.save(self.alias,dict(entry,bytes=262145))
        large,rpc=self.run_job({'resumeTurn':second.turn})
        self.assertEqual(large.state,'failed');self.assertNotIn('turn/start',[m for m,_ in rpc.calls])
    def test_wrong_project_rejects_history_before_rpc(self):
        self.run_job();data=self.management('delete');data['rootIdentity']='1:2';rpc=ManagementRPC()
        with self.assertRaises(ValueError):app.agent_history_operation(self.engine,'agentHistoryChange',data,rpc_factory=lambda *a,**k:rpc)
        self.assertEqual(rpc.calls,[])
