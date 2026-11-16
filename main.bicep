// Test environment for four agents:
//   1. AKS Agentic Ops (diagnostic + remediation, separate identities)
//   2. Azure Foundry RAG agent (Azure AI Search + Foundry project)
//   3. LangGraph CI Repair agent (local; only needs model access)
//   4. Observability monitor (read-only)
// Every component has a deploy* switch so the same template builds the full
// test bench or a cheap minimal one. Everything lives in one resource group:
// Teardown verifies deletion and reports external resources.
//
// Local clients (RAG, CI) authenticate as the signed-in operator through Azure
// CLI, so only the identities that actually run in Azure are created here:
// diagnostic, remediation (AKS workload identity) and monitor (optional job).
targetScope = 'resourceGroup'

@description('Short lowercase prefix used in resource names (3-10 chars, letters/digits).')
@minLength(3)
@maxLength(10)
param prefix string

@description('Signed-in operator object ID for local RAG and CI clients. Empty for infrastructure-only deployment.')
param operatorPrincipalId string = ''
@allowed(['User', 'ServicePrincipal'])
param operatorPrincipalType string = 'User'

@description('Region for AKS, ACR, monitoring and the optional Container Apps job.')
param location string = resourceGroup().location
@description('Region for the AI Services account (models, Foundry project) and Azure AI Search. Model and knowledge-retrieval availability differ per region.')
param aiLocation string = location
param tags object = {
  workload: 'agents-test'
  managedBy: 'bicep'
}

// ---- component switches ------------------------------------------------
param deployAcr bool = true
param deployAi bool = true
param deployRag bool = true
param deployAks bool = true
param deployMonitor bool = true

// ---- AI / models -------------------------------------------------------
@description('Chat model used by every agent. gpt-4.1-mini 2025-04-14 is what the application repositories were validated against; it is deprecated (existing-customer access only, retirement 2027-04-14), so up.ps1 checks availability first.')
param chatModel string = 'gpt-4.1-mini'
param chatModelVersion string = '2025-04-14'
@description('GlobalStandard capacity in thousands of tokens per minute.')
param chatCapacity int = 10
@description('Model deployments; the first entry is the chat deployment used by every agent.')
param modelDeployments array = [
  {
    name: 'chat'
    model: chatModel
    version: chatModelVersion
    capacity: chatCapacity
  }
]
param deployFoundryProject bool = true

// ---- Search ------------------------------------------------------------
@allowed([ 'free', 'basic', 'standard' ])
param searchSku string = 'basic'

// ---- AKS ---------------------------------------------------------------
param aksNodeCount int = 1
param aksVmSize string = 'Standard_D2as_v4'
param agentsNamespace string = 'agentic-ops'
param diagnosticServiceAccount string = 'agentic-ops-diagnostic'
param remediationServiceAccount string = 'agentic-ops-remediation'

// ---- Monitor job -------------------------------------------------------
param monitorImage string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'
@description('true when monitorImage is in the ACR created here.')
param monitorImageFromAcr bool = false
@allowed([ 'Manual', 'Schedule' ])
param monitorTrigger string = 'Manual'
param monitorCron string = '0 */6 * * *'

var suffix = take(uniqueString(resourceGroup().id), 6)
var base = toLower(prefix)
var operatorIds = empty(operatorPrincipalId) ? [] : [ operatorPrincipalId ]

// ---- identities: one per Azure-hosted agent, least privilege ---------------
module idDiagnostic 'modules/identity.bicep' = {
  name: 'id-diagnostic'
  params: { name: '${base}-id-diagnostic', location: location, tags: tags }
}
module idRemediation 'modules/identity.bicep' = {
  name: 'id-remediation'
  params: { name: '${base}-id-remediation', location: location, tags: tags }
}
module idMonitor 'modules/identity.bicep' = {
  name: 'id-monitor'
  params: { name: '${base}-id-monitor', location: location, tags: tags }
}

// ---- observability -----------------------------------------------------
// The monitor identity gets Log Analytics Reader only: it can read, never write.
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    name: base
    location: location
    tags: tags
    readerPrincipalIds: [ idMonitor.outputs.principalId ]
  }
}

// ---- registry ----------------------------------------------------------
// Diagnostic, remediation and monitor identities get AcrPull (read) only.
// The operator builds images with `az acr build`, which needs AcrPush.
module acr 'modules/acr.bicep' = if (deployAcr) {
  name: 'acr'
  params: {
    name: '${replace(base, '-', '')}acr${suffix}'
    location: location
    tags: tags
    pullPrincipalIds: [
      idDiagnostic.outputs.principalId
      idRemediation.outputs.principalId
      idMonitor.outputs.principalId
    ]
    pushPrincipalIds: operatorIds
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
  }
}

// ---- search (RAG) ------------------------------------------------------
// The operator creates the index, knowledge source and knowledge base; the
// Foundry project identity only reads (assigned below, once the project exists).
module search 'modules/search.bicep' = if (deployRag) {
  name: 'search'
  params: {
    name: toLower('${base}-search-${suffix}')
    location: aiLocation
    tags: tags
    sku: searchSku
    readerPrincipalIds: []
    contributorPrincipalIds: operatorIds
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
  }
}

// ---- models + Foundry --------------------------------------------------
module ai 'modules/ai.bicep' = if (deployAi) {
  name: 'ai'
  params: {
    name: toLower('${base}-ai-${suffix}')
    location: aiLocation
    tags: tags
    deployments: modelDeployments
    deployFoundryProject: deployFoundryProject
    openAiUserPrincipalIds: concat([
      idDiagnostic.outputs.principalId
      idRemediation.outputs.principalId
      idMonitor.outputs.principalId
    ], operatorIds)
    aiUserPrincipalIds: operatorIds
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
  }
}

// The Foundry project's system identity queries the knowledge base over MCP.
// Assigning the role here (instead of at runtime) gives RBAC time to propagate
// before the first agent run.
module ragProjectSearchReader 'modules/search-reader.bicep' = if (deployRag && deployAi && deployFoundryProject) {
  name: 'rag-project-search-reader'
  params: {
    searchName: search!.outputs.name
    principalId: ai!.outputs.projectPrincipalId
  }
}

// ---- AKS + workload identity ------------------------------------------
module aks 'modules/aks.bicep' = if (deployAks) {
  name: 'aks'
  params: {
    name: '${base}-aks'
    location: location
    tags: tags
    nodeCount: aksNodeCount
    vmSize: aksVmSize
    workspaceId: monitoring.outputs.workspaceId
    acrName: deployAcr ? acr!.outputs.name : ''
  }
}

module fedDiagnostic 'modules/federation.bicep' = if (deployAks) {
  name: 'fed-diagnostic'
  params: {
    identityName: idDiagnostic.outputs.name
    oidcIssuerUrl: aks!.outputs.oidcIssuerUrl
    namespace: agentsNamespace
    serviceAccount: diagnosticServiceAccount
  }
}

module fedRemediation 'modules/federation.bicep' = if (deployAks) {
  name: 'fed-remediation'
  params: {
    identityName: idRemediation.outputs.name
    oidcIssuerUrl: aks!.outputs.oidcIssuerUrl
    namespace: agentsNamespace
    serviceAccount: remediationServiceAccount
  }
}

// ---- monitor job -------------------------------------------------------
module monitorJob 'modules/monitor-job.bicep' = if (deployMonitor) {
  name: 'monitor-job'
  params: {
    name: '${base}-monitor'
    location: location
    tags: tags
    workspaceName: monitoring.outputs.workspaceName
    workspaceCustomerId: monitoring.outputs.workspaceCustomerId
    identityId: idMonitor.outputs.id
    identityClientId: idMonitor.outputs.clientId
    image: monitorImage
    imageFromAcr: monitorImageFromAcr && deployAcr
    acrLoginServer: deployAcr ? acr!.outputs.loginServer : ''
    trigger: monitorTrigger
    cronExpression: monitorCron
    openAiEndpoint: deployAi ? ai!.outputs.openAiEndpoint : ''
    openAiDeployment: deployAi ? modelDeployments[0].name : ''
  }
}

// ---- outputs: what the agents' .env / k8s manifests need ---------------
output aksName string = deployAks ? aks!.outputs.name : ''
output acrLoginServer string = deployAcr ? acr!.outputs.loginServer : ''
output openAiEndpoint string = deployAi ? ai!.outputs.openAiEndpoint : ''
output foundryProject string = deployAi ? ai!.outputs.projectName : ''
output searchEndpoint string = deployRag ? search!.outputs.endpoint : ''
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceCustomerId
output monitorJobName string = deployMonitor ? monitorJob!.outputs.jobName : ''
output diagnosticClientId string = idDiagnostic.outputs.clientId
output remediationClientId string = idRemediation.outputs.clientId
output monitorClientId string = idMonitor.outputs.clientId

output agentsNamespace string = agentsNamespace
output diagnosticServiceAccount string = diagnosticServiceAccount
output remediationServiceAccount string = remediationServiceAccount
output chatDeployment string = deployAi && length(modelDeployments) > 0 ? modelDeployments[0].name : ''
output appInsightsConnectionString string = monitoring.outputs.connectionString

output aiAccountName string = deployAi ? ai!.outputs.name : ''
output aiAccountId string = deployAi ? ai!.outputs.id : ''
output aiLocation string = aiLocation
output searchResourceId string = deployRag ? search!.outputs.id : ''
output foundryProjectId string = deployAi ? ai!.outputs.projectId : ''
