"""One entrypoint: shared Bicep infrastructure and pinned application adapters."""
from __future__ import annotations
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import venv

ROOT = Path(__file__).resolve().parents[1]


def run(argv, *, cwd=ROOT, env=None, capture=False):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE if capture else None, check=True)
    return result.stdout.strip() if capture else ''


def az(*args):
    return json.loads(run(['az', *args, '--only-show-errors', '-o', 'json'], capture=True) or 'null')


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def operator():
    token = az('account', 'get-access-token')['accessToken']
    payload = token.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
    return claims['oid'], 'ServicePrincipal' if claims.get('idtyp') == 'app' else 'User'


def checkout(name, spec):
    path = ROOT / '.projects' / name
    fresh = not path.exists()
    if fresh:
        run(['git', 'clone', '--no-checkout', f"https://github.com/{spec['repository']}.git", path])
    # Dedicated platform clones only. Never switch a user's existing checkout.
    expected = f"https://github.com/{spec['repository']}.git"
    if run(['git', 'remote', 'get-url', 'origin'], cwd=path, capture=True) != expected:
        raise RuntimeError(f'{name}: unexpected origin')
    if not fresh and run(['git', 'status', '--porcelain'], cwd=path, capture=True):
        raise RuntimeError(f'{name}: platform checkout has local changes')
    run(['git', 'fetch', 'origin', spec['ref']], cwd=path)
    run(['git', 'checkout', '--detach', spec['ref']], cwd=path)
    return path


def python_for(repo, name):
    directory = ROOT / '.venvs' / name
    if not directory.exists():
        venv.EnvBuilder(with_pip=True).create(directory)
    python = directory / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
    if name == 'rag':
        run([python, '-m', 'pip', 'install', '-r', repo / 'requirements.txt'])
    else:
        run([python, '-m', 'pip', 'install', '-e', repo])
    return python


def project_step(name, fn, report_dir):
    report = {'project': name, 'startedUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'status': 'running'}
    write(report_dir / 'startup.json', report)
    try:
        detail = fn()
        report.update(status='ready', detail=detail)
    except Exception as exc:
        # Do not persist remote response bodies or command arguments/credentials.
        report.update(status='failed', error=type(exc).__name__)
        raise
    finally:
        report['finishedUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        write(report_dir / 'startup.json', report)


def clean_env(config):
    env = os.environ.copy()
    for key in ('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_CLIENT_SECRET',
                'AZURE_OPENAI_API_KEY', 'OPENAI_API_KEY'):
        env.pop(key, None)
    env.update(AZURE_OPENAI_ENDPOINT=config['openAiEndpoint'],
               AZURE_OPENAI_DEPLOYMENT=config['chatDeployment'],
               AZURE_OPENAI_USE_ENTRA='1', OPENAI_API_VERSION='2024-10-21')
    return env


def start_apps(config, directory, repos):
    config_file = directory / 'config.json'
    write(config_file, config)
    reports = directory / 'reports' / str(time.time_ns())
    write(directory / 'latest-reports.json', {'path': str(reports)})
    project_step('ops', lambda: run(['pwsh', '-NoProfile', '-File', ROOT / 'scripts/adapters/ops.ps1',
                                    '-Repo', repos['ops'], '-Config', config_file]) or
                 'Kubernetes rollouts ready; no faults injected', reports / 'ops')
    project_step('rag', lambda: run([python_for(repos['rag'], 'rag'), ROOT / 'scripts/adapters/rag.py', '--repo', repos['rag'],
                                    '--config', config_file], env={**clean_env(config), 'PLATFORM_RAG_REPORT': str(reports / 'rag' / 'answer.txt')}) or
                 'Agent deployed and live question completed; inspect answer evidence', reports / 'rag')
    def ci():
        ci_python = python_for(repos['ci'], 'ci')
        thread = f"platform-{time.time_ns()}"
        run([ci_python, '-m', 'ci_repair.cli', 'run', '--mode', 'azure', '--scenario', 'S01',
             '--thread', thread, '--output', reports / 'ci'], cwd=repos['ci'], env=clean_env(config))
        evidence = json.loads((reports / 'ci' / thread / 'evidence.json').read_text())
        if evidence['status'] != 'awaiting_approval':
            raise RuntimeError('CI live run did not reach human approval')
        return {'status': 'awaiting_approval', 'thread': thread, 'humanApprovalPreserved': True}
    project_step('ci', ci, reports / 'ci')
    # Current monitor is an offline JSONL consumer, not a long-running service.
    # Use actual CI outcome telemetry; never present synthetic eval as live monitoring.
    def monitor():
        monitor_python = python_for(repos['monitor'], 'monitor')
        sys.path.insert(0, str(ROOT / 'scripts/adapters'))
        from telemetry import ci_events
        events = ci_events(reports / 'ci')
        telemetry = reports / 'monitor' / 'events.jsonl'
        telemetry.parent.mkdir(parents=True, exist_ok=True)
        telemetry.write_text(''.join(json.dumps(e) + '\n' for e in events))
        result = subprocess.run([str(monitor_python), '-m', 'agent_monitor', 'analyze', str(telemetry), '--policy',
                                 str(ROOT / 'monitor-policy.json'), '--json'], cwd=repos['monitor'],
                                text=True, capture_output=True)
        (reports / 'monitor' / 'findings.json').write_text(result.stdout + '\n')
        if result.returncode != 0:
            raise RuntimeError('Monitor reported high/critical findings or analysis failed; inspect its report')
        return {'mode': 'batch', 'source': 'actual CI run evidence',
                'events': len(events), 'continuousMonitoring': False}
    project_step('monitor', monitor, reports / 'monitor')


def up(args):
    for command in ('az', 'pwsh', 'git', 'kubectl'):
        if not shutil.which(command):
            raise RuntimeError(f'Install {command} first')
    if sys.version_info < (3, 12):
        raise RuntimeError('Python 3.12+ required by the RAG dependencies')
    if args.params != 'dev.bicepparam':
        raise RuntimeError('Full up uses dev.bicepparam; use deploy.ps1 for infrastructure-only parameter sets')
    account = az('account', 'show')
    oid, kind = operator()
    specs = json.loads((ROOT / 'projects.json').read_text())
    repos = {name: checkout(name, spec) for name, spec in specs.items()}
    directory = ROOT / '.state' / f"{account['id']}-{args.group}"
    write(directory / 'run.json', {'subscriptionId': account['id'], 'resourceGroup': args.group,
                                 'projects': specs, 'status': 'provisioning'})
    command = ['pwsh', '-NoProfile', '-File', ROOT / 'scripts/deploy.ps1', '-ResourceGroup', args.group,
               '-Location', args.location, '-ParamFile', args.params,
               '-OperatorPrincipalId', oid, '-OperatorPrincipalType', kind, '-SkipKubernetesRbac']
    if args.yes:
        command.append('-Yes')
    run(command)
    outputs = json.loads((ROOT / 'outputs.json').read_text())
    config = {key: item['value'] for key, item in outputs.items()}
    config.update(subscriptionId=account['id'], resourceGroup=args.group)
    required = ('aksName', 'acrLoginServer', 'openAiEndpoint', 'chatDeployment',
                'searchEndpoint', 'foundryProject', 'aiAccountName')
    if any(not config.get(key) for key in required):
        raise RuntimeError('Full up requires AKS, ACR, AI and RAG enabled. Use deploy.ps1 for infrastructure subsets.')
    start_apps(config, directory, repos)
    write(directory / 'run.json', {'subscriptionId': account['id'], 'resourceGroup': args.group,
                                 'projects': specs, 'status': 'ready', 'monitorMode': 'batch'})
    print(f'UP COMPLETE: AKS, RAG, CI awaiting approval, monitor batch. Reports: {directory / "reports"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['up', 'down', 'status'])
    parser.add_argument('--group', default='rg-agents-test')
    parser.add_argument('--location', default='westeurope')
    parser.add_argument('--params', default='dev.bicepparam')
    parser.add_argument('--yes', action='store_true')
    args = parser.parse_args()
    if not all(c.isalnum() or c in '-_' for c in args.group) or not args.group:
        parser.error('Use letters/digits/-/_ for resource group')
    if args.action == 'up':
        up(args)
    elif args.action == 'down':
        # No background local client is started by up. Cloud runtimes live in this RG.
        command = ['pwsh', '-NoProfile', '-File', ROOT / 'scripts/teardown.ps1', '-ResourceGroup', args.group]
        if args.yes:
            command.append('-Yes')
        run(command)
    else:
        account = az('account', 'show')
        directory = ROOT / '.state' / f"{account['id']}-{args.group}"
        config = json.loads((directory / 'config.json').read_text())
        if not az('group', 'exists', '-n', args.group):
            raise RuntimeError('Resource group is absent')
        run(['kubectl', '--kubeconfig', directory / 'kubeconfig', 'rollout', 'status',
             'deployment/agentic-ops-diagnostic', '-n', config['agentsNamespace'], '--timeout=30s'])
        run(['kubectl', '--kubeconfig', directory / 'kubeconfig', 'rollout', 'status',
             'deployment/agentic-ops-remediation', '-n', config['agentsNamespace'], '--timeout=30s'])
        reports = Path(json.loads((directory / 'latest-reports.json').read_text())['path'])
        for name in ('ops', 'rag', 'ci', 'monitor'):
            print((reports / name / 'startup.json').read_text())
        print('RAG/CI/monitor entries describe their last completed startup, not continuous health.')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print(f'Platform operation stopped: {type(exc).__name__}. Resources/state retained; inspect reports and use down.', file=sys.stderr)
        sys.exit(1)
