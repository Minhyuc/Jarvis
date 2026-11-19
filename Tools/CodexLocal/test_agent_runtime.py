"""Agent protocol tests use synthetic events, no account credentials or paid model calls."""
import json
from pathlib import Path
import queue
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch
import jarvis_app_server as app
from test_app_server import FakeRPC

class DynamicRPC(FakeRPC):
    def __init__(self,*args,**kwargs):
        super().__init__(); self.actions=[]; self.answers=[]; self.turn='agent-turn'; self.thread='agent-thread'
    def request(self,method,params,**kwargs):
        if method=='thread/start':
            self.calls.append((method,params)); return {'thread':{'id':self.thread}}
        if method=='turn/start':
            self.calls.append((method,params)); self.next(); return {'turn':{'id':self.turn}}
        return super().request(method,params,**kwargs)
    def next(self):
        if self.actions:
            tool,args=self.actions.pop(0)
            self.events.put({'serverRequest':{'id':'native-'+str(len(self.answers)), 'method':'item/tool/call',
                'params':{'threadId':self.thread,'turnId':self.turn,'callId':str(uuid.uuid4()),'tool':tool,'arguments':args}}})
        else:
            self.events.put({'method':'item/agentMessage/delta','params':{'threadId':self.thread,'turnId':self.turn,'delta':'결과 확인'}})
            self.events.put({'method':'item/completed','params':{'threadId':self.thread,'turnId':self.turn,'item':{'type':'agentMessage','id':'final','text':'결과 확인'}}})
            self.events.put({'method':'turn/completed','params':{'threadId':self.thread,'turn':{'id':self.turn,'status':'completed'}}})
    def _write(self,value):
        self.answers.append(value); self.next()

class AgentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name).resolve()
        self.rpc=DynamicRPC(); self.engine=app.AppServerRunner('/trusted/codex',self.root/'AppServer',rpc_factory=lambda *_:self.rpc)
        info=self.root.stat()
        self.data={'jobID':str(uuid.uuid4()),'root':str(self.root),'rootIdentity':f'{info.st_dev}:{info.st_ino}',
                   'model':'test-model','effort':'low','message':'프로젝트 확인','turns':[]}
        self.job=None
    def tearDown(self):
        if self.job:
            self.job.stop(); self.job.worker.join(timeout=2)
        self.engine.stop(); self.temp.cleanup()
    def wait(self,condition):
        deadline=time.monotonic()+3
        while not condition() and time.monotonic()<deadline: time.sleep(.005)
        self.assertTrue(condition())
    def start(self,actions):
        self.rpc.actions=list(actions)
        self.job=app.AgentSession(self.engine,self.data,rpc_factory=lambda *a,**k:self.rpc)
        self.job.worker.start(); return self.job
    def test_native_tool_loop_waits_for_correlated_host_results(self):
        job=self.start([('jarvis_project_list',{}),('jarvis_project_read',{'path':'View.swift','startLine':1,'lineCount':10})])
        self.wait(lambda:job.pending is not None)
        first=job.snapshot()['pending']; self.assertEqual(job.state,'awaitingApproval'); self.assertEqual(self.rpc.answers,[])
        with self.assertRaises(ValueError): job.respond({'approvalID':str(uuid.uuid4()),'success':True,'output':'wrong'})
        job.respond({'approvalID':first['approvalID'],'success':True,'output':'View.swift'})
        self.wait(lambda:job.pending is not None and job.pending['approvalID']!=first['approvalID'])
        with self.assertRaises(ValueError): job.respond({'approvalID':first['approvalID'],'success':True,'output':'duplicate'})
        job.respond({'approvalID':job.pending['approvalID'],'success':True,'output':'let n = 1'})
        self.wait(lambda:job.state=='completed')
        self.assertEqual(len(self.rpc.answers),2)
        start=next(p for m,p in self.rpc.calls if m=='thread/start')
        self.assertEqual(start['cwd'],str(self.root)); self.assertEqual(start['sandbox'],'read-only')
        self.assertTrue(start['ephemeral']); self.assertEqual(start['dynamicTools'],app.AGENT_TOOLS)
        self.assertEqual(job.reply,'결과 확인')
    def test_denial_is_a_failed_tool_result_not_permission(self):
        job=self.start([('jarvis_project_list',{})]); self.wait(lambda:job.pending is not None)
        job.respond({'approvalID':job.pending['approvalID'],'success':False,'output':'User declined'})
        self.wait(lambda:job.state=='completed')
        result=self.rpc.answers[0]['result']
        self.assertFalse(result['success']); self.assertEqual(result['contentItems'][0]['type'],'inputText')
    def test_cancel_revokes_pending_and_stale_response(self):
        job=self.start([('jarvis_project_edit',{'path':'View.swift','old':'a','new':'b'})]); self.wait(lambda:job.pending is not None)
        old=job.pending['approvalID']; job.stop()
        with self.assertRaises(ValueError): job.respond({'approvalID':old,'success':True,'output':'late'})
        self.assertEqual(job.state,'cancelled'); self.assertIsNone(job.pending); self.assertEqual(self.rpc.answers,[])
    def test_wrong_thread_and_unknown_tool_fail_closed(self):
        job=self.start([('native_shell',{'command':'touch forbidden'})])
        self.wait(lambda:job.state=='failed'); self.assertEqual(self.rpc.answers,[])
    def test_call_turn_identity_is_checked(self):
        job=self.start([('jarvis_project_list',{})]); self.wait(lambda:job.pending is not None)
        self.assertEqual(job.pending['threadID'],self.rpc.thread); self.assertEqual(job.pending['turnID'],self.rpc.turn)
        self.assertGreater(job.pending['expiresAt'],time.time())
    def test_control_rejects_wrong_job_and_oversized_result(self):
        job=self.start([('jarvis_project_list',{})]); self.engine.agent=job; self.wait(lambda:job.pending is not None)
        with self.assertRaises(ValueError): app.agent_operation(self.engine,'agentPoll',json.dumps({'jobID':str(uuid.uuid4())}))
        with self.assertRaises(ValueError): app.agent_operation(self.engine,'agentRespond',json.dumps({'jobID':job.id,'approvalID':job.pending['approvalID'],'success':True,'output':'x'*32769}))
        self.assertEqual(self.rpc.answers,[])
    def test_stop_before_start_is_a_tombstone(self):
        app.agent_operation(self.engine,'agentStop',json.dumps({'jobID':self.data['jobID']}))
        state,_=app.agent_operation(self.engine,'agentStart',json.dumps(self.data))
        self.assertEqual(state,'cancelled'); self.assertIsNone(self.engine.agent)
    def test_unsupported_runtime_never_starts_model_turn(self):
        with patch.object(app,'agent_capabilities',return_value={'supported':False}):
            self.assertEqual(app.agent_operation(self.engine,'agentStart',json.dumps(self.data))[0],'failed')
        self.assertEqual(self.rpc.calls,[])
    def test_parent_stop_terminates_agent(self):
        job=self.start([('jarvis_project_list',{})]); self.engine.agent=job; self.wait(lambda:job.pending is not None)
        self.engine.stop(); self.assertEqual(job.state,'cancelled'); self.assertTrue(self.rpc.closed)
    def test_steering_is_scoped_to_active_native_turn(self):
        job=self.start([('jarvis_project_list',{})]); self.wait(lambda:job.pending is not None)
        with self.assertRaises(ValueError): job.steer('추가 지시')
        # Approval waiting is not an arbitrary confirmation opportunity.
        self.assertEqual(self.rpc.answers,[])
    def test_stop_still_works_when_cancellation_capacity_is_exhausted(self):
        job=self.start([('jarvis_project_list',{})]); self.engine.agent=job; self.wait(lambda:job.pending is not None)
        self.engine.agent_stopped={str(uuid.uuid4()) for _ in range(128)}
        self.assertEqual(app.agent_operation(self.engine,'agentStop',json.dumps({'jobID':job.id}))[0],'succeeded')
        self.assertEqual(job.state,'cancelled'); self.assertTrue(self.engine.agent_stop_exhausted)

class AgentHTTPTests(unittest.TestCase):
    def test_authenticated_control_and_stop_before_start(self):
        import http.client
        import jarvis_codex_local as local
        from test_codex_local import FakeRunner
        with tempfile.TemporaryDirectory() as temporary:
            engine=app.AppServerRunner('/trusted/codex',Path(temporary).resolve()/'AppServer',rpc_factory=lambda *_:None)
            server=local.Bridge(FakeRunner(),app_server=engine)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            def post(action,payload,token=True,backend='appServer'):
                connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
                body={'sessionID':server.session_id,'requestID':str(uuid.uuid4()),'backend':backend,'input':json.dumps(payload)}
                headers={'Content-Type':'application/json'}
                if token:headers['Authorization']='Bearer '+server.token
                connection.request('POST','/'+action,json.dumps(body),headers)
                response=connection.getresponse();data=response.read();connection.close()
                return response.status,json.loads(data) if response.status==200 else None
            try:
                with patch.object(app,'agent_capabilities',return_value={'agentVersion':2,'supported':False}):
                    self.assertEqual(post('agentPoll',{'capabilities':True},token=False)[0],403)
                    self.assertEqual(post('agentPoll',{'capabilities':True},backend='cli')[0],400)
                    code,result=post('agentPoll',{'capabilities':True})
                    self.assertEqual(code,200);self.assertEqual(result['agentVersion'],2)
                    self.assertFalse(json.loads(result['reply'])['supported'])
                jobID=str(uuid.uuid4())
                self.assertEqual(post('agentStop',{'jobID':jobID})[1]['status'],'succeeded')
                self.assertIn(jobID,engine.agent_stopped)
                before=len(server.seen)
                for _ in range(5): self.assertEqual(post('agentPoll',{'jobID':jobID})[1]['status'],'failed')
                self.assertEqual(len(server.seen),before)
                self.assertEqual(post('agentRespond',{'jobID':jobID,'approvalID':'stale','success':True,'output':'not accepted'})[1]['status'],'failed')
            finally:
                engine.stop();server.shutdown();server.server_close();thread.join(2)

class AgentWireTests(unittest.TestCase):
    def test_dynamic_server_request_is_forwarded_but_builtin_permission_is_rejected(self):
        source='''#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
 v=json.loads(line)
 if v.get('method')=='initialize':
  assert v['params']['capabilities']['experimentalApi'] is True
  print(json.dumps({'id':v['id'],'result':{}}),flush=True)
 elif v.get('method')=='thread/start': print(json.dumps({'id':v['id'],'result':{'thread':{'id':'thread'}}}),flush=True)
 elif v.get('method')=='turn/start':
  print(json.dumps({'id':'server-call','method':'item/tool/call','params':{'threadId':'thread','turnId':'turn','callId':'call','tool':'jarvis_project_list','arguments':{}}}),flush=True)
  print(json.dumps({'id':v['id'],'result':{'turn':{'id':'turn'}}}),flush=True)
 elif v.get('id')=='server-call' and 'result' in v:
  assert v['result']=={'success':False,'contentItems':[{'type':'inputText','text':'Denied'}]}
  print(json.dumps({'id':'permission','method':'item/permissions/requestApproval','params':{}}),flush=True)
'''
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();binary=root/'fake-codex';binary.write_text(source);binary.chmod(0o700)
            rpc=app.AgentRPC(str(binary),root/'AppServer',cwd=str(root))
            try:
                rpc.begin_events();rpc.request('thread/start',{})
                rpc.request('turn/start',{})
                event=rpc.events.get(timeout=3);self.assertEqual(event['serverRequest']['id'],'server-call')
                rpc._write({'id':'server-call','result':{'success':False,'contentItems':[{'type':'inputText','text':'Denied'}]}})
                deadline=time.monotonic()+3
                while rpc.failure is None and time.monotonic()<deadline:time.sleep(.005)
                self.assertEqual(rpc.failure,'appserver_tool_blocked')
            finally:rpc.close()

class AgentCancellationTests(unittest.TestCase):
    setUp = AgentTests.setUp
    tearDown = AgentTests.tearDown
    wait = AgentTests.wait
    start = AgentTests.start
    def test_matching_stop_closes_inflight_native_verification(self):
        job=self.start([('jarvis_project_verify',{'argv':['swift','test'],'purpose':'verification'})])
        self.engine.agent=job; self.wait(lambda:job.pending is not None)
        native=FakeRPC();self.engine.native_rpc=native
        self.assertEqual(app.agent_operation(self.engine,'agentStop',json.dumps({'jobID':job.id}))[0],'succeeded')
        self.assertTrue(native.closed);self.assertTrue(self.engine.cancelled.is_set())
        self.assertEqual(job.state,'cancelled')
