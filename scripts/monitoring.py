"""Lifecycle of the local read-only monitor. Kubernetes credential is scoped to pod/log reads."""
from __future__ import annotations
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def health(directory, *, max_age=90):
    path = Path(directory) / 'monitor/health.json'
    if not path.exists() or not (path.parent / 'running').exists():
        raise RuntimeError('Monitor has no active worker/health report')
    report = json.loads(path.read_text())
    if time.time() - report['updatedAt'] > max_age:
        raise RuntimeError('Monitor heartbeat is stale; collector may have stopped')
    return report


def stop(directory, timeout=150):
    folder = Path(directory) / 'monitor'
    if not folder.exists():
        return
    (folder / 'stop').touch()
    deadline = time.monotonic() + timeout
    # A stale/dead PID must never be killed: cooperative stop avoids PID reuse risks.
    while (folder / 'running').exists():
        info = json.loads((folder / 'running').read_text())
        pid = info['pid']
        if os.name == 'nt':
            import ctypes
            handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
            if not handle:
                (folder / 'running').unlink(missing_ok=True)
                break
            exit_code = ctypes.c_ulong()
            alive = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            ctypes.windll.kernel32.CloseHandle(handle)
            if alive and exit_code.value != 259:
                (folder / 'running').unlink(missing_ok=True)
                break
        else:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                (folder / 'running').unlink(missing_ok=True)
                break
        if time.monotonic() > deadline:
            raise RuntimeError('Monitor has not acknowledged stop; inspect it before cleanup')
        time.sleep(0.5)


def start(config, directory, python, policy, run):
    directory = Path(directory)
    folder = directory / 'monitor'
    folder.mkdir(parents=True, exist_ok=True)
    stop(directory)
    for name in ('stop', 'health.json'):
        (folder / name).unlink(missing_ok=True)
    telemetry = directory / 'telemetry'
    telemetry.mkdir(exist_ok=True)
    for name in ('rag', 'ci'):
        (telemetry / f'{name}.jsonl').touch(exist_ok=True)
    # Provision read-only runtime RBAC using the operator; the monitor never sees
    # the operator kubeconfig or Azure CLI credentials in its configuration.
    admin = ['kubectl', '--kubeconfig', str(directory / 'kubeconfig')]
    namespace = config['agentsNamespace']
    manifest = '\n---\n'.join(json.dumps(item) for item in [
        {'apiVersion':'v1','kind':'ServiceAccount','metadata':{'name':'agent-monitor','namespace':namespace}},
        {'apiVersion':'rbac.authorization.k8s.io/v1','kind':'Role',
         'metadata':{'name':'agent-monitor-readonly','namespace':namespace},
         'rules':[{'apiGroups':[''],'resources':['pods'],'verbs':['get','list']},
                  {'apiGroups':[''],'resources':['pods/log'],'verbs':['get']}]},
        {'apiVersion':'rbac.authorization.k8s.io/v1','kind':'RoleBinding',
         'metadata':{'name':'agent-monitor-readonly','namespace':namespace},
         'subjects':[{'kind':'ServiceAccount','name':'agent-monitor','namespace':namespace}],
         'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':'Role','name':'agent-monitor-readonly'}},
    ])
    result = subprocess.run([*admin, 'apply', '-f', '-'], input=manifest, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Could not configure monitor read-only RBAC')
    token = run([*admin, '-n', namespace, 'create', 'token', 'agent-monitor', '--duration=24h'], capture=True)
    payload = token.split('.')[1]
    expiry = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))['exp']
    cluster = json.loads(run([*admin, 'config', 'view', '--minify', '--raw', '-o', 'json'], capture=True))['clusters'][0]['cluster']
    kube = directory / 'monitor-kubeconfig.json'
    atomic(kube, {'apiVersion':'v1','kind':'Config','clusters':[{'name':'observed','cluster':cluster}],
                 'users':[{'name':'monitor','user':{'token':token}}],
                 'contexts':[{'name':'monitor','context':{'cluster':'observed','user':'monitor','namespace':namespace}}],
                 'current-context':'monitor'})
    if os.name != 'nt':
        kube.chmod(0o600)
    for verb, resource in [('patch', 'deployments'), ('delete', 'pods'), ('get', 'secrets')]:
        check = subprocess.run(['kubectl', '--kubeconfig', str(kube), '-n', namespace,
                                'auth', 'can-i', verb, resource], text=True, capture_output=True)
        if check.stdout.strip() != 'no':
            raise RuntimeError('Monitor credential is not confirmed read-only')
    instance = uuid.uuid4().hex
    source_config = {'instance':instance,'policy':str(policy), 'retentionHours':24,
                     'sources':[
                         {'type':'kubernetes','name':'aks','namespace':namespace,'kubeconfig':str(kube),
                          'credentialExpiresAt':expiry},
                         {'type':'jsonl','name':'rag','agent':'rag','path':str(telemetry/'rag.jsonl')},
                         {'type':'jsonl','name':'ci','agent':'ci-repair','path':str(telemetry/'ci.jsonl')}]}
    atomic(folder / 'sources.json', source_config)
    # Remove common cloud credentials; the collector only gets its scoped kubeconfig.
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('AZURE_', 'ARM_', 'OPENAI_')) or key == 'KUBECONFIG':
            env.pop(key, None)
    command = [str(python), str(Path(__file__).with_name('monitor_worker.py')), str(folder)]
    kwargs = {'creationflags':subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS} if os.name == 'nt' else {'start_new_session':True}
    with (folder/'worker.log').open('a') as log:
        child = subprocess.Popen(command, stdout=log, stderr=log, stdin=subprocess.DEVNULL, env=env, **kwargs)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError('Monitor stopped during startup; inspect worker.log')
        try:
            report = health(directory)
            if report['instance'] == instance and report['status'] == 'watching':
                return {'mode':'continuous','pid':child.pid,'sources':['AKS','RAG','CI'],
                        'credentialExpiresAt':expiry}
        except RuntimeError:
            pass
        time.sleep(0.5)
    raise RuntimeError('Monitor sources did not become healthy; resources retained')
