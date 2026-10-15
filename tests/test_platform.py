import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

platform = module('platform_runner', ROOT / 'scripts/platform.py')
telemetry = module('telemetry', ROOT / 'scripts/adapters/telemetry.py')

class PlatformTests(unittest.TestCase):
    def test_failed_step_records_failure_and_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            with self.assertRaises(RuntimeError):
                platform.project_step('ops', lambda: (_ for _ in ()).throw(RuntimeError()), target)
            self.assertEqual(json.loads((target / 'startup.json').read_text())['status'], 'failed')

    def test_telemetry_preserves_human_approval_without_claiming_fix(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'run1'
            target.mkdir()
            (target / 'evidence.json').write_text(json.dumps({'status': 'awaiting_approval',
                'history': [{'result': 'sufficient'}]}))
            events = telemetry.ci_events(Path(tmp))
            self.assertEqual([e['type'] for e in events],
                             ['run_started', 'verification', 'escalation', 'run_finished'])
            self.assertEqual(events[-1]['status'], 'escalated')
            self.assertFalse(any(e.get('status') == 'fixed' for e in events))
            self.assertTrue(all(e['attrs']['timeBasis'] == 'reconstructed-order' for e in events))

    def test_monitor_rejects_missing_real_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                telemetry.ci_events(Path(tmp))

    def test_local_clients_do_not_inherit_api_key_or_managed_identity(self):
        with patch.dict('os.environ', {'AZURE_OPENAI_API_KEY': 'ignored', 'AZURE_CLIENT_ID': 'ignored'}):
            env = platform.clean_env({'openAiEndpoint': 'https://example.test', 'chatDeployment': 'chat'})
            self.assertNotIn('AZURE_OPENAI_API_KEY', env)
            self.assertNotIn('AZURE_CLIENT_ID', env)
            self.assertEqual(env['AZURE_OPENAI_USE_ENTRA'], '1')

    def test_ops_failure_prevents_rag_ci_and_monitor_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            with patch.object(platform, 'run', side_effect=RuntimeError('rollout failed')), \
                 patch.object(platform, 'python_for') as install:
                with self.assertRaises(RuntimeError):
                    platform.start_apps({}, directory, {'ops': directory})
                install.assert_not_called()
                latest = json.loads((directory / 'latest-reports.json').read_text())
                reports = Path(latest['path'])
                self.assertEqual(json.loads((reports / 'ops/startup.json').read_text())['status'], 'failed')
                self.assertFalse((reports / 'rag').exists())

    def test_complete_application_sequence_keeps_separate_reports(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            order = []
            def fake_run(argv, **kwargs):
                if str(argv[0]) == 'pwsh':
                    order.append('ops')
                elif '--repo' in argv:
                    order.append('rag')
                elif 'ci_repair.cli' in argv:
                    order.append('ci')
                    report = Path(argv[argv.index('--output') + 1])
                    thread = argv[argv.index('--thread') + 1]
                    (report / thread).mkdir(parents=True)
                    (report / thread / 'evidence.json').write_text(json.dumps({
                        'status': 'awaiting_approval', 'history': [{'result': 'sufficient'}]}))
                return ''
            with patch.object(platform, 'run', side_effect=fake_run), \
                 patch.object(platform, 'python_for', return_value='python'), \
                 patch.object(platform.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '[]', '')):
                platform.start_apps({'openAiEndpoint': 'https://example.test', 'chatDeployment': 'chat'},
                                    directory, {name: directory for name in ('ops','rag','ci','monitor')})
            self.assertEqual(order, ['ops', 'rag', 'ci'])
            reports = Path(json.loads((directory / 'latest-reports.json').read_text())['path'])
            for name in ('ops','rag','ci','monitor'):
                self.assertEqual(json.loads((reports / name / 'startup.json').read_text())['status'], 'ready')
            self.assertTrue((reports / 'monitor/events.jsonl').exists())

    def test_pins_are_immutable_and_all_components_present(self):
        projects = json.loads((ROOT / 'projects.json').read_text())
        self.assertEqual(set(projects), {'ops', 'rag', 'ci', 'monitor'})
        for project in projects.values():
            self.assertRegex(project['ref'], r'^[a-f0-9]{40}$')

if __name__ == '__main__':
    unittest.main()
