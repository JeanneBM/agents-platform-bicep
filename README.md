# Agents Platform — one-command Azure lab

A shared Azure test bench for AKS Agentic Ops, Foundry RAG, LangGraph CI Repair
and the Observability Monitor. Bicep owns infrastructure; application adapters
reuse those resources. Each source repository retains its independent lab scripts.

## Up / status / down

Requirements: Python 3.12+, PowerShell 7+, Git, Azure CLI with Bicep, kubectl,
an Azure login and permission to deploy resources, build images in ACR and assign roles.
Docker is not required locally: image builds run in ACR.

```powershell
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
./up.ps1 -Yes
./status.ps1
./down.ps1 -Yes
```

For a different dedicated resource group/region:

```powershell
./up.ps1 -ResourceGroup rg-agents-demo -Location westeurope -Yes
./down.ps1 -ResourceGroup rg-agents-demo -Yes
```

`-Yes` skips the confirmation prompt. Without it, deployment shows what-if and
asks before applying. Region/model quotas can still reject a deployment. Set model
and VM parameters in `dev.bicepparam` before the first run. RAG uses preview Search
knowledge retrieval APIs, so region/API availability also matters.

## What one up does

| Step | Result |
|---|---|
| Checkout | Fetches the four repositories at immutable commits from `projects.json` into `.projects/` |
| Bicep | Creates shared AKS, ACR, model deployments, Foundry project, Search, monitoring and identities |
| AKS Ops | Builds the actual agent image, imports the demo image, deploys a healthy payments workload and both agents; waits for rollouts |
| RAG | Indexes the source repo's demo documents, creates the knowledge base/MCP connection and agent version; checks a live grounded answer |
| LangGraph | Runs real Azure inference for S01; checks that execution stops at human approval |
| Monitor | Runs the actual monitor CLI in batch mode on telemetry reconstructed from the real CI evidence |

The monitor currently receives the CI outcome, validation and escalation events.
It does **not** continuously monitor all agents. Reconstructed event ordering is
labelled; token costs, raw tool calls and latency are not invented. The placeholder
Container Apps job is disabled in the full profile because it does not run this
monitor. Continuous collection from AKS/Foundry remains separate follow-up work.

A CI run awaiting human approval is the intended ready state, not an automatically
approved repair. No PR is created. AKS startup does not inject failures or run S01–S10.

`status.ps1` checks the RG and current AKS rollouts, then displays the separate
startup reports. RAG/CI/monitor reports describe their last execution, not live health.

## Separate reports and reproducibility

Each invocation writes separate reports under:

```text
.state/<subscription>-<resource-group>/reports/<run>/
  ops/startup.json
  rag/startup.json
  rag/answer.txt
  ci/startup.json
  ci/<thread>/evidence.json
  monitor/startup.json
  monitor/events.jsonl
  monitor/findings.json
```

Configuration and an isolated kubeconfig are retained beside the reports. Each
Python project has its own `.venvs/` environment. Update a commit in `projects.json`
only after checking its adapter contract. Dirty platform checkouts are refused.
Reports/state/checkouts/environments are git-ignored. Keep local state until teardown.

On failure, up stops and retains cloud resources and reports for inspection. Retry
up with the same parameters or run down. A failed project prevents later projects
from being reported as ready. Setup routines reuse resources; a retry can create
another Foundry agent version and a new CI thread/report.

## Independent repo use

The original repository entrypoints still work on their own. Do not invoke their
standalone infrastructure setup scripts against the shared platform: those create
dedicated labs. The platform adapters use the pinned application entrypoints and
manifests without creating additional Azure infrastructure.

| Application | Platform integration |
|---|---|
| AKS Ops | `scripts/adapters/ops.ps1` + upstream Dockerfile/manifests |
| Foundry RAG | `scripts/adapters/rag.py` + upstream create/chat commands and Azure helpers |
| CI Repair | upstream `python -m ci_repair.cli run --mode azure` |
| Monitor | upstream `python -m agent_monitor analyze` + `scripts/adapters/telemetry.py` |

## Infrastructure-only use

```powershell
./scripts/deploy.ps1 -ResourceGroup rg-agents-min -ParamFile minimal.bicepparam
./scripts/teardown.ps1 -ResourceGroup rg-agents-min
```

Full `up.ps1` deliberately uses `dev.bicepparam`; partial profiles are for the
infrastructure-only command. For custom full settings, edit `dev.bicepparam`.

## Identity and cleanup

- Diagnostic and remediation use separate Workload Identities and upstream
  namespace-scoped Kubernetes roles. The full up skips the broader generic RBAC.
- Local RAG and CI clients use Azure CLI authentication. Bicep grants the signed-in
  operator scoped model/AI and Search bootstrap roles. Managed identity creation
  alone does not authenticate local applications.
- RAG's Foundry project identity gets Search Index Data Reader for the MCP connection.
- Model API keys are disabled; Search retains its existing RBAC/API-key compatibility.
- Down waits for RG deletion, verifies recorded AKS node groups and reports new
  Network Watchers from the saved inventory. Shared watchers are never blindly deleted.
- AI soft-delete retention can reserve names after deletion. Review/purge a specific
  deleted account before recreating the same name, or use a new resource group.
- No local background processes are started: AKS workloads and the Foundry agent
  persist in Azure; local RAG/CI/monitor commands complete before up returns.

AKS nodes, Search, ACR and observability can incur charges while retained; model
calls also consume quota/billing. Down affects the selected platform RG, not
independent labs created from other repositories.

## Validation

Bicep build/lint and both parameter builds are checked in CI, alongside PowerShell
syntax and offline orchestration tests. No live Azure deployment has been performed
as part of implementing this orchestration. A successful compile is not evidence
of live API availability, identity propagation or model quota.
