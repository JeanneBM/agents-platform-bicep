import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

platform = module('platform_runner', ROOT / 'scripts/platform_runner.py')
monitoring = module('monitoring_test', ROOT / 'scripts/monitoring.py')

class PlatformTests(unittest.TestCase):
    def test_failed_step_records_failure_and_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            with self.assertRaises(RuntimeError):
                platform.project_step('ops', lambda: (_ for _ in ()).throw(RuntimeError()), target)
            self.assertEqual(json.loads((target / 'startup.json').read_text())['status'], 'failed')

    def test_local_clients_do_not_inherit_api_key_or_managed_identity(self):
        with patch.dict('os.environ', {'AZURE_OPENAI_API_KEY': 'ignored', 'AZURE_CLIENT_ID': 'ignored'}):
            env = platform.clean_env({'openAiEndpoint': 'https://example.test', 'chatDeployment': 'chat'})
            self.assertNotIn('AZURE_OPENAI_API_KEY', env)
            self.assertNotIn('AZURE_CLIENT_ID', env)
            self.assertEqual(env['AZURE_OPENAI_USE_ENTRA'], '1')

    def test_ops_failure_prevents_all_other_startup(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            with patch.object(platform, 'run', side_effect=RuntimeError('rollout failed')), \
                 patch.object(platform, 'python_for') as install:
                with self.assertRaises(RuntimeError):
                    platform.start_apps({}, directory, {'ops': directory})
                install.assert_not_called()
                reports = Path(json.loads((directory / 'latest-reports.json').read_text())['path'])
                self.assertEqual(json.loads((reports / 'ops/startup.json').read_text())['status'], 'failed')
                self.assertFalse((reports / 'rag').exists())

    def test_monitor_starts_before_rag_and_ci_and_gets_real_event_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            order = []
            environments = {}
            def fake_run(argv, **kwargs):
                if str(argv[0]) == 'pwsh': order.append('ops')
                elif '--repo' in argv:
                    order.append('rag'); environments['rag'] = kwargs['env']
                elif 'ci_repair.cli' in argv:
                    order.append('ci'); environments['ci'] = kwargs['env']
                    report = Path(argv[argv.index('--output') + 1])
                    thread = argv[argv.index('--thread') + 1]
                    (report / thread).mkdir(parents=True)
                    (report / thread / 'evidence.json').write_text(json.dumps({'status': 'awaiting_approval'}))
                return ''
            def fake_monitor(*args):
                order.append('monitor')
                return {'mode':'continuous'}
            with patch.object(platform, 'run', side_effect=fake_run), \
                 patch.object(platform, 'python_for', return_value='python'), \
                 patch.object(platform, 'start_monitor', side_effect=fake_monitor), \
                 patch.object(platform, 'monitor_health', return_value={'status':'watching','agents':{'rag':{'events':1},'ci-repair':{'events':1}}}):
                platform.start_apps({'openAiEndpoint': 'https://example.test', 'chatDeployment': 'chat'},
                                    directory, {name: directory for name in ('ops','rag','ci','monitor')})
            self.assertEqual(order, ['ops','monitor','rag','ci'])
            for name in ('rag','ci'):
                self.assertEqual(environments[name]['AGENT_TELEMETRY_FILE'], str(directory/'telemetry'/f'{name}.jsonl'))

    def test_stale_collector_is_not_reported_as_healthy(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'monitor'; path.mkdir()
            (path/'health.json').write_text(json.dumps({'updatedAt':time.time()-200}))
            with self.assertRaises(RuntimeError): monitoring.health(tmp)

    def test_stop_does_not_kill_or_ignore_live_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'monitor';path.mkdir()
            (path/'running').write_text(json.dumps({'pid':12345}))
            with patch.object(monitoring.os,'kill') as kill:
                with self.assertRaises(RuntimeError): monitoring.stop(tmp,timeout=0)
                kill.assert_called_once_with(12345,0)
            self.assertTrue((path/'stop').exists())

    def test_monitor_runtime_has_only_pod_log_reads_and_all_sources(self):
        import base64
        import subprocess
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)
            token='header.'+base64.urlsafe_b64encode(json.dumps({'exp':time.time()+3600}).encode()).decode().rstrip('=')+'.sig'
            def fake_run(argv, **kwargs):
                if 'token' in argv:return token
                return json.dumps({'clusters':[{'cluster':{'server':'https://cluster.test','certificate-authority-data':'ca'}}]})
            manifests=[]
            def fake_subprocess(argv, **kwargs):
                if 'apply' in argv:
                    manifests.append(kwargs['input'])
                    return subprocess.CompletedProcess(argv,0,'','')
                return subprocess.CompletedProcess(argv,1,'no','')
            def fake_health(*args, **kwargs):
                config=json.loads((directory/'monitor/sources.json').read_text())
                return {'instance':config['instance'],'status':'watching'}
            child=Mock(pid=42);child.poll.return_value=None
            with patch.object(monitoring.subprocess,'run',side_effect=fake_subprocess), \
                 patch.object(monitoring.subprocess,'Popen',return_value=child) as spawn, \
                 patch.object(monitoring,'health',side_effect=fake_health), \
                 patch.dict('os.environ',{'AZURE_CLIENT_SECRET':'never-inherit'}):
                result=monitoring.start({'agentsNamespace':'agentic-ops'},directory,'python','policy.json',fake_run)
            self.assertEqual(result['mode'],'continuous')
            self.assertNotIn('AZURE_CLIENT_SECRET',spawn.call_args.kwargs['env'])
            resources=[json.loads(x) for x in manifests[0].split('\n---\n')]
            role=next(x for x in resources if x['kind']=='Role')
            self.assertEqual({v for rule in role['rules'] for v in rule['verbs']},{'get','list'})
            config=json.loads((directory/'monitor/sources.json').read_text())
            self.assertEqual([x['name'] for x in config['sources']],['aks','rag','ci'])
            kube=json.loads((directory/'monitor-kubeconfig.json').read_text())
            self.assertEqual(kube['users'][0]['user'],{'token':token})

    def test_pins_are_immutable_and_all_components_present(self):
        projects = json.loads((ROOT / 'projects.json').read_text())
        self.assertEqual(set(projects), {'ops','rag','ci','monitor'})
        for project in projects.values(): self.assertRegex(project['ref'], r'^[a-f0-9]{40}$')

if __name__ == '__main__': unittest.main()
