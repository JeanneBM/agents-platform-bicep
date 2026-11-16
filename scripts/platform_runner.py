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
from monitoring import start as start_monitor, stop as stop_monitor, health as monitor_health

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
    expected = f"https://github.com/{spec['repository']}.git"
    if fresh:
        run(['git', 'clone', '--no-checkout', expected, path])
    if not fresh and run(['git', 'status', '--porcelain'], cwd=path, capture=True):
        raise RuntimeError(f'{name}: platform checkout has local changes')
    # Dedicated platform clones only: follow a renamed upstream repository, but
    # never adopt a checkout that points somewhere else entirely.
    origin = run(['git', 'remote', 'get-url', 'origin'], cwd=path, capture=True)
    if origin != expected:
        if not origin.startswith('https://github.com/JeanneBM/'):
            raise RuntimeError(f'{name}: unexpected origin {origin}')
        run(['git', 'remote', 'set-url', 'origin', expected], cwd=path)
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
               AZURE_OPENAI_USE_ENTRA='1', OPENAI_API_VERSION='2024-10-21', AGENT_TELEMETRY_STDOUT='0')
    return env


def start_apps(config, directory, repos):
    config_file = directory / 'config.json'
    write(config_file, config)
    reports = directory / 'reports' / str(time.time_ns())
    write(directory / 'latest-reports.json', {'path': str(reports)})
    project_step('ops', lambda: run(['pwsh', '-NoProfile', '-File', ROOT / 'scripts/adapters/ops.ps1',
                                    '-Repo', repos['ops'], '-Config', config_file]) or
                 'Kubernetes rollouts ready; no faults injected', reports / 'ops')
    project_step('monitor', lambda: start_monitor(config, directory, python_for(repos['monitor'], 'monitor'),
                                                 ROOT / 'monitor-policy.json', run), reports / 'monitor')
    project_step('rag', lambda: run([python_for(repos['rag'], 'rag'), ROOT / 'scripts/adapters/rag.py', '--repo', repos['rag'],
                                    '--config', config_file], env={**clean_env(config), 'PLATFORM_RAG_REPORT': str(reports / 'rag' / 'answer.txt'),
                                     'AGENT_TELEMETRY_FILE': str(directory / 'telemetry/rag.jsonl')}) or
                 'Agent deployed and live question completed; inspect answer evidence', reports / 'rag')
    def ci():
        ci_python = python_for(repos['ci'], 'ci')
        thread = f"platform-{time.time_ns()}"
        run([ci_python, '-m', 'ci_repair.cli', 'run', '--mode', 'azure', '--scenario', 'S01',
             '--thread', thread, '--output', reports / 'ci'], cwd=repos['ci'], env={**clean_env(config), 'AGENT_TELEMETRY_FILE': str(directory / 'telemetry/ci.jsonl')})
        evidence = json.loads((reports / 'ci' / thread / 'evidence.json').read_text())
        if evidence['status'] != 'awaiting_approval':
            raise RuntimeError('CI live run did not reach human approval')
        return {'status': 'awaiting_approval', 'thread': thread, 'humanApprovalPreserved': True}
    project_step('ci', ci, reports / 'ci')
    # Require the running monitor to have consumed both local startup executions.
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        report = monitor_health(directory)
        if report['status'] != 'watching':
            raise RuntimeError('Monitor collection degraded; inspect monitor/findings.json')
        if report['agents']['rag']['events'] and report['agents']['ci-repair']['events']:
            return
        time.sleep(1)
    raise RuntimeError('Monitor did not consume RAG/CI telemetry before startup deadline')


PROVIDERS = ('Microsoft.ContainerService', 'Microsoft.ContainerRegistry', 'Microsoft.CognitiveServices',
             'Microsoft.Search', 'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights',
             'Microsoft.Insights', 'Microsoft.Authorization')
MIN_AZ_VERSION = (2, 77, 0)


def version_tuple(text):
    return tuple(int(part) for part in text.split('.')[:3])


def bicepparam(path, name):
    for line in (ROOT / path).read_text(encoding='utf-8').splitlines():
        tokens = line.split('//')[0].split()
        if len(tokens) >= 4 and tokens[0] == 'param' and tokens[1] == name and tokens[2] == '=':
            return tokens[3].strip("'")
    return None


def preflight(args, account, oid):
    """Fail fast, before any resource exists, on the things a compile cannot check."""
    problems = []
    for command in ('az', 'pwsh', 'git', 'kubectl'):
        if not shutil.which(command):
            problems.append(f'Install {command} first')
    if sys.version_info < (3, 12):
        problems.append('Python 3.12+ required by the RAG dependencies')
    if problems:
        raise RuntimeError('; '.join(problems))
    versions = az('version')
    if version_tuple(versions['azure-cli']) < MIN_AZ_VERSION:
        problems.append(f"Azure CLI {versions['azure-cli']} is too old; {'.'.join(map(str, MIN_AZ_VERSION))}+ is required (Foundry project and Search knowledge retrieval commands)")
    run(['az', 'bicep', 'install', '--only-show-errors'])  # latest Bicep knows the 2026 API versions used here
    if 'project' not in run(['az', 'cognitiveservices', 'account', '--help'], capture=True):
        problems.append('Azure CLI lacks `az cognitiveservices account project`; upgrade the CLI')
    kube = json.loads(run(['kubectl', 'version', '--client', '-o', 'json'], capture=True))['clientVersion']
    if (int(kube['major']), int(kube['minor'].rstrip('+'))) < (1, 24):
        problems.append('kubectl 1.24+ is required (kubectl create token)')
    # Resource providers: register the missing ones instead of failing mid-deployment.
    for provider in PROVIDERS:
        state = az('provider', 'show', '-n', provider, '--query', 'registrationState')
        if state != 'Registered':
            print(f'Registering resource provider {provider}...')
            run(['az', 'provider', 'register', '-n', provider, '--wait', '--only-show-errors'])
    # Role assignments in main.bicep need Owner or User Access Administrator.
    roles = az('role', 'assignment', 'list', '--assignee', oid, '--include-inherited', '--include-groups',
               '--scope', f"/subscriptions/{account['id']}", '--query', '[].roleDefinitionName')
    if not {'Owner', 'User Access Administrator', 'Role Based Access Control Administrator'} & set(roles or []):
        problems.append('Signed-in principal lacks Owner/User Access Administrator on the subscription; Bicep role assignments would fail')
    # The chat model must be deployable in aiLocation (deprecated models are only
    # available to subscriptions that already deployed that exact version).
    model = bicepparam(args.params, 'chatModel') or 'gpt-4.1-mini'
    version = bicepparam(args.params, 'chatModelVersion') or '2025-04-14'
    models = az('cognitiveservices', 'model', 'list', '-l', args.ai_location,
                '--query', f"[?model.name=='{model}' && model.version=='{version}'].{{status:model.lifecycleStatus,skus:model.skus[].name}}")
    if not models:
        problems.append(f'{model} {version} is not listed for {args.ai_location}; pick another aiLocation or model')
    else:
        status = models[0].get('status') or ''
        if status == 'Deprecated':
            problems.append(f'{model} {version} is retired in {args.ai_location}')
        elif status == 'Deprecating':
            print(f'Note: {model} {version} is deprecated (existing-customer access only); the deployment will fail if this subscription never deployed it.')
        skus = models[0].get('skus') or []
        if skus and 'GlobalStandard' not in skus:
            problems.append(f'{model} {version} has no GlobalStandard SKU in {args.ai_location} (offered: {", ".join(skus)})')
    # Compute quota for the single system node.
    size = bicepparam(args.params, 'aksVmSize') or 'Standard_D2as_v4'
    sku = az('vm', 'list-skus', '-l', args.location, '--size', size, '--resource-type', 'virtualMachines',
             '--query', "[0].{family:family,cores:capabilities[?name=='vCPUs'].value|[0],restricted:restrictions[?type=='Location'].reasonCode}")
    if not sku:
        problems.append(f'{size} is not offered in {args.location}')
    else:
        if sku['restricted']:
            problems.append(f'{size} is restricted for this subscription in {args.location}: {sku["restricted"]}')
        needed = int(sku['cores']) * int(bicepparam(args.params, 'aksNodeCount') or 1)
        usage = az('vm', 'list-usage', '-l', args.location, '--query', f"[?name.value=='{sku['family']}'] | [0]")
        if usage and int(usage['limit']) - int(usage['currentValue']) < needed:
            problems.append(f"Quota {sku['family']} in {args.location}: {usage['currentValue']}/{usage['limit']} vCPU used, {needed} needed")
    search = az('search', 'service', 'list', '--query', "[?sku.name=='free'] | length(@)") if (bicepparam(args.params, 'searchSku') == 'free') else 0
    if search:
        problems.append('A free Search service already exists in this subscription (limit one); use searchSku basic')
    if problems:
        raise RuntimeError('Preflight failed:\n  - ' + '\n  - '.join(problems))
    print(f"Preflight OK: az {versions['azure-cli']}, {model} {version} in {args.ai_location}, {size} in {args.location}.")


def up(args):
    if args.params != 'dev.bicepparam':
        raise RuntimeError('Full up uses dev.bicepparam; use deploy.ps1 for infrastructure-only parameter sets')
    account = az('account', 'show')
    oid, kind = operator()
    preflight(args, account, oid)
    specs = json.loads((ROOT / 'projects.json').read_text())
    repos = {name: checkout(name, spec) for name, spec in specs.items()}
    directory = ROOT / '.state' / f"{account['id']}-{args.group}"
    write(directory / 'run.json', {'subscriptionId': account['id'], 'resourceGroup': args.group,
                                 'projects': specs, 'status': 'provisioning'})
    command = ['pwsh', '-NoProfile', '-File', ROOT / 'scripts/deploy.ps1', '-ResourceGroup', args.group,
               '-Location', args.location, '-AiLocation', args.ai_location, '-ParamFile', args.params,
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
                                 'projects': specs, 'status': 'ready', 'monitorMode': 'continuous'})
    print(f'UP COMPLETE: AKS, RAG, CI awaiting approval, monitor watching AKS/RAG/CI. Reports: {directory / "reports"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['up', 'down', 'status', 'chat', 'ci'])
    parser.add_argument('--group', default='rg-agents-test')
    parser.add_argument('--location', default='polandcentral')
    parser.add_argument('--ai-location', default='swedencentral', help='Region for models, Foundry project and Search')
    parser.add_argument('--params', default='dev.bicepparam')
    parser.add_argument('--yes', action='store_true')
    parser.add_argument('--question')
    parser.add_argument('--scenario', choices=['S01','S02','S03','S04','S05'], default='S01')
    args = parser.parse_args()
    if not all(c.isalnum() or c in '-_' for c in args.group) or not args.group:
        parser.error('Use letters/digits/-/_ for resource group')
    if args.action == 'up':
        up(args)
    elif args.action == 'down':
        if not args.yes and input(f"Stop monitor and delete platform '{args.group}'? (y/N) ") != 'y':
            return
        account = az('account', 'show')
        directory = ROOT / '.state' / f"{account['id']}-{args.group}"
        stop_monitor(directory)
        command = ['pwsh', '-NoProfile', '-File', ROOT / 'scripts/teardown.ps1', '-ResourceGroup', args.group]
        command.append('-Yes')
        run(command)
    elif args.action in ('chat', 'ci'):
        account = az('account', 'show')
        directory = ROOT / '.state' / f"{account['id']}-{args.group}"
        config = json.loads((directory / 'config.json').read_text())
        if monitor_health(directory)['status'] != 'watching':
            raise RuntimeError('Monitor sources are degraded; rerun up before monitored work')
        name = 'rag' if args.action == 'chat' else 'ci'
        python = ROOT / '.venvs' / name / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
        env = clean_env(config)
        env['AGENT_TELEMETRY_FILE'] = str(directory / 'telemetry' / f'{name}.jsonl')
        if name == 'rag':
            env.update(json.loads((directory / 'rag-environment.json').read_text()))
            command = [python, 'chat.py'] + (['--question', args.question] if args.question else [])
        else:
            command = [python, '-m', 'ci_repair.cli', 'run', '--mode', 'azure', '--scenario', args.scenario,
                       '--thread', f"monitored-{time.time_ns()}", '--output', directory / 'reports/ci-sessions']
        run(command, cwd=ROOT / '.projects' / name, env=env)
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
        report = monitor_health(directory)
        print(json.dumps(report, indent=2))
        if report['status'] != 'watching' or report['highFindings']:
            raise RuntimeError('Monitor reports degraded collection or high/critical findings')
        print('Monitor is continuous. RAG/CI startup reports describe their last application execution.')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print(f'Platform operation stopped: {type(exc).__name__}. Resources/state retained; inspect reports and use down.', file=sys.stderr)
        sys.exit(1)
