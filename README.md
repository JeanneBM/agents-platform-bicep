# Agents Platform — Bicep

Infrastructure for a four-agent test bench on Azure, with a switch for every component:

| Agent | What it needs from this repo |
|---|---|
| AKS Agentic Ops | AKS (Workload Identity), ACR, two separate identities (diagnostic = read-only, remediation = narrow), model access |
| Foundry RAG | Foundry project, Azure AI Search, model + embedding deployments |
| LangGraph CI Repair | model access only (the workflow itself runs locally) |
| Observability monitor | Container Apps Job, Log Analytics Reader, **no write rights to anything** |

Shared: Log Analytics + Application Insights. Primary resources sit in one resource group. AKS also creates a managed node resource group; teardown verifies its removal and reports new external Network Watchers.

## Security choices

- **One managed identity per agent**, so permissions are never shared.
- **Agent model access uses Entra ID.** The AI account has `disableLocalAuth: true`; agents authenticate with Entra ID. Workload Identity federates each AKS service account to exactly one Azure identity.
- **Monitor has no remediation permissions:** Log Analytics Reader, AcrPull and model inference access for optional triage. Container Apps logging uses a workspace shared key internally.
- Diagnostic and remediation get registry read access (AcrPull), never push.
- Kubernetes-side limits are in `k8s/agents-rbac.yaml` (diagnostic: read-only; remediation: patch Deployments in one namespace).

## Layout

```
main.bicep            wiring + switches + outputs
modules/              monitoring, identity, acr, ai, search, aks, federation, monitor-job
dev.bicepparam        everything on
minimal.bicepparam    shared + models + monitor; no AKS, no Search
k8s/agents-rbac.yaml  in-cluster RBAC and service accounts
scripts/              deploy.ps1 (what-if, confirm, apply), teardown.ps1
```

## Deploy

```powershell
az login
./scripts/deploy.ps1 -ResourceGroup rg-agents-test -Location westeurope                 # everything
./scripts/deploy.ps1 -ResourceGroup rg-agents-min  -ParamFile minimal.bicepparam        # cheap
```

Or by hand:

```bash
az group create -n rg-agents-test -l westeurope --tags workload=agents-test
az deployment group what-if -g rg-agents-test -p dev.bicepparam
az deployment group create  -g rg-agents-test -p dev.bicepparam
```

Switch single components with `--parameters deployAks=false deployRag=false`.
Outputs (endpoints, client IDs) are what your agents' `.env` files and manifests need.

Tear down: `./scripts/teardown.ps1 -ResourceGroup rg-agents-test`.

## Cost

Bicep is free; you pay for the resources. The main running costs are the AKS node, Azure AI Search (`basic` tier and up) and model tokens. Most other items are small or usage-based. Check the Azure pricing calculator for your region, and delete the resource group when you are not testing.

## Before the first deploy

- **Model availability and quota** vary by region and subscription. Adjust `modelDeployments` (name, version, capacity) if the deployment is rejected.
- **AKS VM size** (`aksVmSize`, default `Standard_D4s_v5`) must be available in your region and quota.
- **Globally unique names** (ACR, AI account, Search) get a suffix from the resource group id.
- Deleted AI accounts are soft-deleted and keep their name; see the note in `scripts/teardown.ps1`.
- Search is created with RBAC **and** API keys enabled (`aadOrApiKey`) for compatibility; set `disableLocalAuth: true` in `modules/search.bicep` once your RAG client uses Entra ID only.

## Status

- Static review completed; run the included CI to confirm Bicep compilation and PowerShell syntax. No live deployment has been performed.
- **Not deployed against a real subscription**, so `what-if` and a real deployment may still surface region, quota or API-version issues.
- The monitor job runs a placeholder image until you push an `agent-monitor` image and set `monitorImage` (+ `monitorImageFromAcr=true`).
- The monitor currently reads JSONL files; reading telemetry from Log Analytics (what its Reader role is for) is a planned adapter, not built yet.
- Foundry Knowledge Base / MCP connection setup is not in Bicep; configure it in the Foundry project after deployment.

## Responsibility boundary

This repository provisions infrastructure only. Build, deploy and test each agent
using its own repository scripts, configured to reuse these resources rather than
create duplicates. `outputs.json` provides endpoints, identity client IDs, the chat
deployment name, service account names and the Application Insights connection string.
Keep individual test reports in each agent repository.

Local LangGraph execution must use the developer's Entra identity with appropriate
model access, or a separately configured federation. Creating its managed identity
here does not authenticate a local process. Foundry connections and telemetry
instrumentation remain the responsibility of the agent projects.

The default monitor image is a placeholder; deploying the job does not demonstrate
that agent monitoring works. Supply a real image and telemetry adapter first.

Teardown waits for deletion and checks recorded AKS node groups. An initial Network
Watcher inventory is retained in `.state/` per subscription/resource group, including
across retries. Newly observed watchers are reported for ownership review, never
blindly removed because they may be shared. Keep this local state until cleanup is
complete. The script refuses to reuse an existing untagged resource group.
