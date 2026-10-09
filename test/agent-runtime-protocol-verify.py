#!/usr/bin/env python3
"""Production runtime protocol tests; Pi and desktop IPC fixtures exist only here.

No host configuration, credentials, compositor, model endpoint or desktop is used.
The separate real-model suite verifies actual model-driven application actions.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / 'bin/cornice-agent-runtime'
SECRET = 'fixture-model-secret-9a4f00'
TERMINAL = ('completed', 'cancelled', 'blocked', 'failed', 'needs_attention')
PI_FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
job = pathlib.Path(os.environ['CORNICE_AGENT_JOB'])
mode = os.environ['FIXTURE_MODE']
token = os.environ['CORNICE_MODEL_TOKEN']
def event(value):
    print(json.dumps(value), flush=True)
def message(error=None, content=None):
    event({'type':'message_end','message':{'role':'assistant',
      'stopReason':'error' if error else 'stop', 'errorMessage':error,
      'content':content or []}})
def bridge(operation, params):
    result = subprocess.run([os.environ['CORNICE_AGENT_BRIDGE'],'bridge',operation],
      input=json.dumps(params),text=True,capture_output=True,check=True)
    return json.loads(result.stdout)
assert '--no-builtin-tools' in sys.argv and '--no-extensions' in sys.argv
assert '--no-mcp' not in sys.argv
assert 'builtin:mcp' in sys.argv
assert any(pathlib.Path(sys.argv[i+1]).is_file() for i,v in enumerate(sys.argv[:-1]) if v == '--extension')
assert pathlib.Path.cwd().is_relative_to(job/'workspace')
assert pathlib.Path(os.environ['PI_CODING_AGENT_DIR']).is_relative_to(job/'pi')
if mode == 'early-startup':
    sys.stderr.write('Provider cannot start: missing model definition\n');sys.stderr.flush()
    sys.exit(2)
assert json.loads(sys.stdin.readline())['type'] == 'prompt'
if mode == 'startup':
    # Split a credential across writes to exercise stderr buffering/redaction.
    sys.stderr.write('Cannot load desktop extension. Authorization: Bearer ' + token[:12]);sys.stderr.flush()
    time.sleep(.03)
    sys.stderr.write(token[12:] + '\n');sys.stderr.flush()
    sys.exit(2)
if mode == 'delayed-success':
    (job/'fixture.starting').touch()
    while not (job/'fixture.continue').exists(): time.sleep(.02)
event({'type':'response','command':'prompt','success':True,'data':{'disposition':'started'}})
error = 'Connection error at http://127.0.0.1:1/v1?api_key=query-secret; Authorization: Bearer '+token
if mode in ('retry-failed','retry-recovered'):
    message(error)
    event({'type':'auto_retry_start','attempt':1,'errorMessage':error})
    (job/'fixture.retry').touch()
    # Parent observes the job alive after the first error, before continuation.
    while not (job/'fixture.continue').exists(): time.sleep(.02)
    if mode == 'retry-failed':
        for attempt in range(2,5):
            message(error)
            if attempt < 4:
                event({'type':'auto_retry_start','attempt':attempt,'errorMessage':error})
        event({'type':'auto_retry_end','success':False,'attempt':3,'finalError':error})
if mode in ('success','delayed-success','retry-recovered','finish-then-error'):
    frame = bridge('capture',{})
    event({'type':'tool_execution_end','toolName':'desktop_capture','result':frame})
    result = bridge('input',{'frameId':frame['frameId'],'action':'text','text':'真实协议 中文'})
    event({'type':'tool_execution_end','toolName':'desktop_input','result':result})
    bridge('finish',{'outcome':'completed','reason':'Verified fixture protocol actions'})
    if mode == 'finish-then-error': message(error)
    else:
        message(content=[{'type':'text','text':'Verified fixture protocol actions'}])
        if mode == 'retry-recovered': event({'type':'auto_retry_end','success':True,'attempt':1})
elif mode == 'extension-error':
    event({'type':'extension_error','event':'tool_call','error':'Desktop extension broke token='+token})
else:
    if mode != 'retry-failed': message(content=[{'type':'text','text':'I plan to operate the desktop'}])
event({'type':'agent_settled','aborted':False})
for line in sys.stdin: pass
'''


class RuntimeProtocol(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cornice-runtime-protocol.')
        self.base = Path(self.temp.name)
        self.fixture = self.base / 'pi-fixture'
        self.fixture.write_text(PI_FIXTURE)
        self.fixture.chmod(0o700)
        self.config = self.base / 'model.json'
        self.instance = 'private-protocol'
        self.directory = self.base / 'cornice' / self.instance / 'jobs' / 'agent1'
        self.socket_path = self.base / 'cornice' / self.instance / 'desktop.sock'
        self.socket_path.parent.mkdir(parents=True)
        self.requests = []
        self.state = dict(name='agent1',seatId='fixture-seat',controlMode='agent',
                          generation=1,available=True,humanLocked=False)
        self.stop = threading.Event()
        self.broker = socket.socket(socket.AF_UNIX)
        self.broker.bind(str(self.socket_path))
        self.broker.listen()
        self.broker.settimeout(.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.base),
                        HYPRLAND_INSTANCE_SIGNATURE=self.instance,
                        CORNICE_AGENT_CONFIG=str(self.config), FIXTURE_MODE='success',
                        PYTHONDONTWRITEBYTECODE='1')
        self.configure()

    def tearDown(self):
        if self.directory.exists():
            self.call('cancel', 'agent1')
            status = self.read_status()
            if status.get('pid'):
                # Worker owns and terminates its Pi process group; wait for its
                # inherited lock to close before deleting the private fixture.
                import fcntl
                def released():
                    with open(self.directory/'lock', 'a') as lock:
                        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError: return False
                        return True
                self.wait(released)
        self.stop.set()
        self.thread.join(2)
        self.broker.close()
        self.temp.cleanup()

    def serve(self):
        while not self.stop.is_set():
            try: connection, _ = self.broker.accept()
            except socket.timeout: continue
            with connection:
                raw = b''
                while b'\n' not in raw: raw += connection.recv(65536)
                request = json.loads(raw.split(b'\n', 1)[0])
                self.requests.append(request)
                method = request['method']
                if method == 'state':
                    result = dict(self.state)
                elif method == 'bind':
                    result = dict(name='agent1',seatId='fixture-seat',generation=1,token='fixture-desktop-binding')
                elif method == 'desktop.capture':
                    result = dict(frameId='fixture-frame',pixelSize=[1280,800],pngBase64='fixture-image-data',
                                  metadata=dict(unchanged=['capture',1]))
                elif method == 'desktop.input':
                    result = dict(sent=True,params=request['params'])
                else: result = {}
                connection.sendall(json.dumps(dict(ok=True,result=result)).encode()+b'\n')

    def call(self, command, *args, input=None, succeeds=True):
        process = subprocess.run([str(RUNTIME),command,*args],input=input,env=self.env,
                                 text=True,capture_output=True,timeout=5)
        if succeeds: self.assertEqual(process.returncode,0,process.stderr)
        else: self.assertNotEqual(process.returncode,0)
        return json.loads(process.stdout if succeeds else process.stderr)

    def configure(self, **changes):
        config = dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',
                      token=SECRET,pi=str(self.fixture))
        config.update(changes)
        return self.call('configure',input=json.dumps(config))

    def wait(self, predicate):
        end = time.monotonic()+8
        while time.monotonic()<end:
            value = predicate()
            if value: return value
            time.sleep(.02)
        self.fail('Timed out: '+json.dumps(self.read_status()))

    def read_status(self):
        path = self.directory/'status.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def start(self, mode):
        self.env['FIXTURE_MODE'] = mode
        accepted = self.call('start','agent1',input='Only test the private protocol fixture')
        self.assertTrue(accepted['started'] and accepted['accepted'])
        self.assertEqual(len(accepted['runId']),32)
        self.assertEqual(accepted['runId'],self.read_status()['runId'])
        self.assertEqual(accepted['name'],'agent1')
        return accepted

    def terminal(self, accepted):
        result = self.wait(lambda: (s if (s:=self.read_status()).get('phase') in TERMINAL else None))
        self.assertEqual(result['runId'],accepted['runId'])
        return result

    def assert_redacted(self):
        for name in ('status.json','events.jsonl','pi.stderr.log'):
            text = (self.directory/name).read_text()
            self.assertNotIn(SECRET,text,name)
            self.assertNotIn('query-secret',text,name)

    def test_model_retries_exhaust_with_actual_error(self):
        accepted = self.start('retry-failed')
        self.wait(lambda:(self.directory/'fixture.retry').exists())
        self.wait(lambda: self.read_status().get('phase') == 'running')
        self.assertEqual(self.read_status()['phase'],'running')
        self.assertNotIn(self.read_status()['phase'],TERMINAL)
        (self.directory/'fixture.continue').touch()
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Connection error',result['message'])
        events = [json.loads(line) for line in (self.directory/'events.jsonl').read_text().splitlines()]
        self.assertEqual(sum(e['type']=='message_end' for e in events),4)
        self.assert_redacted()

    def short_token_failure(self, token):
        self.configure(token=token)
        accepted = self.start('retry-failed')
        self.wait(lambda:(self.directory/'fixture.retry').exists())
        self.wait(lambda: self.read_status().get('phase') == 'running')
        self.assertEqual(self.read_status()['phase'],'running')
        (self.directory/'fixture.continue').touch()
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Connection',result['message'])
        self.assertNotIn('Bearer '+token,result['message'])

    def test_short_agent_token_cannot_change_event_type(self):
        self.short_token_failure('agent')

    def test_short_error_token_cannot_change_stop_reason(self):
        self.short_token_failure('error')

    def test_short_agent_token_keeps_successful_completion(self):
        self.configure(token='agent')
        accepted = self.start('success')
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()

    def test_retry_recovery_keeps_production_tools_and_finish(self):
        accepted = self.start('retry-recovered')
        self.wait(lambda:(self.directory/'fixture.retry').exists())
        self.wait(lambda: self.read_status().get('phase') == 'running')
        self.assertEqual(self.read_status()['phase'],'running')
        (self.directory/'fixture.continue').touch()
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()
        self.assert_redacted()

    def assert_tool_stream(self):
        events = [json.loads(line) for line in (self.directory/'events.jsonl').read_text().splitlines()]
        capture = next(e for e in events if e.get('toolName')=='desktop_capture')['result']
        self.assertEqual(capture,dict(frameId='fixture-frame',pixelSize=[1280,800],
                                     pngBase64='fixture-image-data',metadata=dict(unchanged=['capture',1])))
        sent = next(r for r in self.requests if r['method']=='desktop.input')
        self.assertEqual(sent['token'],'fixture-desktop-binding')
        self.assertEqual(sent['params'],dict(frameId='fixture-frame',action='text',text='真实协议 中文'))
        self.assertEqual(json.loads((self.directory/'result.json').read_text())['outcome'],'completed')

    def test_success_requires_desktop_finish(self):
        accepted = self.start('success')
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()

    def test_acceptance_is_not_prompt_readiness(self):
        accepted = self.start('delayed-success')
        self.wait(lambda:(self.directory/'fixture.starting').exists())
        self.assertEqual(self.read_status()['phase'],'starting')
        (self.directory/'fixture.continue').touch()
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()

    def test_plain_assistant_stop_is_not_completion(self):
        accepted = self.start('no-finish')
        self.assertEqual(self.terminal(accepted)['phase'],'needs_attention')
        self.assertFalse((self.directory/'result.json').exists())

    def test_failed_model_cannot_be_overridden_by_finish_file(self):
        accepted = self.start('finish-then-error')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Connection error',result['message'])
        self.assert_redacted()

    def test_startup_stderr_is_reported_and_redacted(self):
        accepted = self.start('startup')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Cannot load desktop extension',result['message'])
        self.assertIn('[REDACTED]',result['message'])
        self.assert_redacted()

    def test_missing_pi_executable_reports_startup_failure(self):
        self.configure(pi=str(self.base/'missing-pi'))
        accepted = self.start('success')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('No such file',result['message'])

    def test_pi_exits_before_reading_prompt_reports_diagnostic(self):
        accepted = self.start('early-startup')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Provider cannot start: missing model definition',result['message'])

    def test_extension_runtime_error_is_failure(self):
        accepted = self.start('extension-error')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertIn('Desktop extension broke',result['message'])
        self.assert_redacted()

    def test_config_requires_exactly_one_token_source(self):
        for config in (
            dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model'),
            dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',token=SECRET,tokenEnv='MISSING'),
            dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',token=''),
        ):
            error = self.call('configure',input=json.dumps(config),succeeds=False)
            self.assertIn('token',error['error'])
            self.assertNotIn(SECRET,error['error'])
        self.assertNotIn('token',self.call('config-status'))

    def test_token_file_source_is_supported(self):
        token_file = self.base/'fixture-token'
        token_file.write_text(SECRET+'\n')
        config = dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',
                      tokenFile=str(token_file),pi=str(self.fixture))
        self.call('configure',input=json.dumps(config))
        accepted = self.start('success')
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()

    def test_environment_token_source_is_supported(self):
        self.env['CORNICE_TEST_TOKEN'] = SECRET
        config = dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',
                      tokenEnv='CORNICE_TEST_TOKEN',pi=str(self.fixture))
        self.call('configure',input=json.dumps(config))
        accepted = self.start('success')
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()

    def test_missing_environment_token_is_concrete_failure(self):
        config = dict(endpoint='http://127.0.0.1:1/v1',model='fixture-model',
                      tokenEnv='CORNICE_TEST_ABSENT_TOKEN',pi=str(self.fixture))
        self.env.pop('CORNICE_TEST_ABSENT_TOKEN',None)
        self.call('configure',input=json.dumps(config))
        accepted = self.start('success')
        result = self.terminal(accepted)
        self.assertEqual(result['phase'],'failed')
        self.assertEqual(result['message'],'模型 token 不可用')

    def test_metadata_redacts_unlabelled_path_credentials_from_each_source(self):
        token_file = self.base/'fixture-token'
        token_file.write_text(SECRET+'\n')
        self.env['CORNICE_TEST_TOKEN'] = SECRET
        for source in (dict(token=SECRET),dict(tokenFile=str(token_file)),dict(tokenEnv='CORNICE_TEST_TOKEN')):
            config = dict(endpoint='http://127.0.0.1:1/private/'+SECRET+'/invoke',
                          model='fixture-model',pi=str(self.fixture),**source)
            configured = self.call('configure',input=json.dumps(config))
            metadata = self.call('config-status')
            for value in (configured,metadata):
                self.assertNotIn(SECRET,json.dumps(value))
                self.assertIn('[REDACTED]',value['endpoint'])
            # The actual provider URL is not rewritten by metadata redaction.
            self.assertEqual(json.loads(self.config.read_text())['endpoint'],config['endpoint'])

    def test_unavailable_credential_keeps_metadata_safe_and_available(self):
        for source in (dict(tokenFile=str(self.base/'absent-token')),
                       dict(tokenEnv='CORNICE_TEST_ABSENT_TOKEN')):
            self.env.pop('CORNICE_TEST_ABSENT_TOKEN',None)
            config = dict(endpoint='http://user:password@127.0.0.1:1/unknown-private-token/invoke',
                          model='fixture-model',pi=str(self.fixture),**source)
            configured = self.call('configure',input=json.dumps(config))
            metadata = self.call('config-status')
            self.assertEqual(configured['endpoint'],'http://127.0.0.1:1')
            self.assertEqual(metadata['endpoint'],'http://127.0.0.1:1')
            self.assertEqual(metadata['model'],'fixture-model')

    def test_preauthorized_continue_policy_permits_task_during_human_lock(self):
        self.state.update(humanLocked=True,lockScope='human',humanLockPolicy='continue')
        accepted = self.start('success')
        self.assertEqual(self.terminal(accepted)['phase'],'completed')
        self.assert_tool_stream()
        self.assertFalse(any(r['method']=='resume' for r in self.requests))

    def denied_start(self, **state):
        self.state.update(state)
        result = self.call('start','agent1',input='This task must be refused',succeeds=False)
        self.assertIn('End human takeover and unlock',result['error'])
        self.assertFalse((self.directory/'identity.json').exists())
        self.assertFalse(any(r['method']!='state' for r in self.requests))

    def test_full_lock_denies_task_even_with_continue_policy(self):
        self.denied_start(humanLocked=True,lockScope='full',humanLockPolicy='continue')

    def test_default_human_lock_pause_policy_denies_task(self):
        self.denied_start(humanLocked=True,lockScope='human',humanLockPolicy='pause')

    def test_human_takeover_cannot_be_resumed_by_task_submission(self):
        self.denied_start(controlMode='human',humanLocked=True,lockScope='human',humanLockPolicy='continue')

    def test_unavailable_desktop_denies_task(self):
        self.denied_start(available=False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
