"""Configure the pinned RAG application against existing platform resources only."""
import argparse, json, os, subprocess, sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    global ROOT, SEARCH_API, CONNECTION_API
    ROOT = Path(args.repo).resolve()
    SEARCH_API = '2026-04-01'
    CONNECTION_API = '2025-10-01-preview'
    sys.path.insert(0, str(ROOT / 'scripts'))
    from lab_support import request, grant, az, LabError
    config = json.loads(Path(args.config).read_text())
    state = {'subscriptionId': config['subscriptionId']}
    endpoint = config['searchEndpoint']
    project = az('cognitiveservices', 'account', 'project', 'show', '-g', config['resourceGroup'],
                 '-n', config['aiAccountName'], '--project-name', config['foundryProject'],
                 subscription=config['subscriptionId'])
    principal = project['identity']['principalId']
    grant(state, principal, 'Search Index Data Reader', config['searchResourceId'])
    print("[3/5] Index and synthetic documents")
    index = {
        "name": "demo-docs",
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "title", "type": "Edm.String", "searchable": True},
            {"name": "content", "type": "Edm.String", "searchable": True},
        ],
        "semantic": {
            "defaultConfiguration": "demo-semantic",
            "configurations": [
                {
                    "name": "demo-semantic",
                    "prioritizedFields": {
                        "titleField": {"fieldName": "title"},
                        "prioritizedContentFields": [{"fieldName": "content"}],
                    },
                }
            ],
        },
    }
    request(state, f"{endpoint}/indexes/demo-docs?api-version={SEARCH_API}", "PUT", index)
    documents = json.loads((ROOT / "examples/lab-documents.json").read_text(encoding="utf-8"))
    indexed = request(
        state,
        f"{endpoint}/indexes/demo-docs/docs/index?api-version={SEARCH_API}",
        "POST",
        {"value": [{"@search.action": "mergeOrUpload", **doc} for doc in documents]},
    )
    if any(not result.get("status") for result in indexed["value"]):
        raise LabError("One or more demo documents failed indexing. Rerun setup.")
    print("[4/5] Knowledge source, base and managed-identity MCP connection")
    source = {
        "name": "demo-source",
        "kind": "searchIndex",
        "searchIndexParameters": {
            "searchIndexName": "demo-docs",
            "semanticConfigurationName": "demo-semantic",
            "sourceDataFields": [{"name": "title"}, {"name": "content"}],
            "searchFields": [{"name": "content"}],
        },
    }
    request(
        state, f"{endpoint}/knowledgesources('demo-source')?api-version={SEARCH_API}", "PUT", source
    )
    request(
        state,
        f"{endpoint}/knowledgebases('demo-kb')?api-version={SEARCH_API}",
        "PUT",
        {"name": "demo-kb", "knowledgeSources": [{"name": "demo-source"}]},
    )
    mcp = f"{endpoint}/knowledgebases/demo-kb/mcp?api-version={SEARCH_API}"
    request(
        state,
        f"https://management.azure.com{project['id']}/connections/demo-kb-mcp?api-version={CONNECTION_API}",
        "PUT",
        {
            "name": "demo-kb-mcp",
            "properties": {
                "authType": "ProjectManagedIdentity",
                "category": "RemoteTool",
                "target": mcp,
                "isSharedToAll": True,
                "audience": "https://search.azure.com/",
                "metadata": {"ApiType": "Azure"},
            },
        },
        audience="https://management.azure.com/",
    )
    env = os.environ.copy()
    env.update({
        'PROJECT_ENDPOINT': project['properties']['endpoints']['AI Foundry API'],
        'RAG_MCP_ENDPOINT': mcp, 'PROJECT_CONNECTION_NAME': 'demo-kb-mcp',
        'MODEL_DEPLOYMENT': config['chatDeployment'], 'AGENT_NAME': 'PlatformRag',
        'AGENT_VERSION': '', 'AZURE_CREDENTIAL_MODE': 'cli',
        'DEPLOYMENT_FILE': str(Path(args.config).parent / 'rag-deployment.json'),
    })
    for key in ('AZURE_CLIENT_ID', 'AZURE_OPENAI_API_KEY'):
        env.pop(key, None)
    subprocess.run([sys.executable, 'create_rag_agent.py'], cwd=ROOT, env=env, check=True)
    # Live retrieval check, using the project's actual application entrypoint.
    result = subprocess.run([sys.executable, 'chat.py', '--question', 'How many days after delivery can I return a product?', '--json'],
                            cwd=ROOT, env=env, text=True, capture_output=True, check=True)
    report = Path(os.environ['PLATFORM_RAG_REPORT'])
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(result.stdout, encoding='utf-8')
    answer = json.loads(result.stdout)
    if answer.get('unknown') or not answer.get('sources') or '30' not in answer.get('answer', ''):
        raise LabError('RAG smoke failed: expected grounded 30-day return policy.')

if __name__ == '__main__':
    main()
