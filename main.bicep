// Test environment for four agents:
//   1. AKS Agentic Ops (diagnostic + remediation, separate identities)
//   2. Azure Foundry RAG agent (Azure AI Search + Foundry project)
//   3. LangGraph CI Repair agent (local; only needs model access)
//   4. Observability monitor (read-only)
// Every component has a deploy* switch so the same template builds the full
// test bench or a cheap minimal one. Everything lives in one resource group:
// Teardown verifies deletion and reports external resources.
targetScope = 'resourceGroup'

@description('Short lowercase prefix used in resource names (3-10 chars, letters/digits).')
@minLength(3)
@maxLength(10)
param prefix string

@description('Signed-in operator object ID for local RAG and CI clients. Empty for infrastructure-only deployment.')
param operatorPrincipalId string = ''
@allowed(['User', 'ServicePrincipal'])
param operatorPrincipalType string = 'User'

param location string = resourceGroup().location
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
@description('Check model/version/SKU availability and quota for your region before deploying.')
param modelDeployments array = [
  {
    name: 'chat'
    model: 'gpt-4o-mini'
    version: '2024-07-18'
    capacity: 10
  }
  {
    name: 'embed'
    model: 'text-embedding-3-small'
    version: '1'
    capacity: 10
  }
]
param deployFoundryProject bool = true

// ---- Search ------------------------------------------------------------
@allowed([ 'free', 'basic', 'standard' ])
param searchSku string = 'basic'
@description('Give the RAG identity rights to create indexes (test convenience). false = query-only.')
param ragCanManageIndex bool = true

// ---- AKS ---------------------------------------------------------------
param aksNodeCount int = 1
param aksVmSize string = 'Standard_D4s_v5'
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
var base = prefix

// ---- identities: one per agent, least privilege ----------------------------
module idDiagnostic 'modules/identity.bicep' = {
  name: 'id-diagnostic'
  params: { name: '${base}-id-diagnostic', location: location, tags: tags }
}
module idRemediation 'modules/identity.bicep' = {
  name: 'id-remediation'
  params: { name: '${base}-id-remediation', location: location, tags: tags }
}
module idRag 'modules/identity.bicep' = {
  name: 'id-rag'
  params: { name: '${base}-id-rag', location: location, tags: tags }
}
module idCiRepair 'modules/identity.bicep' = {
  name: 'id-ci-repair'
  params: { name: '${base}-id-ci-repair', location: location, tags: tags }
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
  }
}

// ---- search (RAG) ------------------------------------------------------
module search 'modules/search.bicep' = if (deployRag) {
  name: 'search'
  params: {
    name: toLower('${base}-search-${suffix}')
    location: location
    tags: tags
    sku: searchSku
    readerPrincipalIds: ragCanManageIndex ? [] : [ idRag.outputs.principalId ]
    contributorPrincipalIds: concat(ragCanManageIndex ? [ idRag.outputs.principalId ] : [], empty(operatorPrincipalId) ? [] : [operatorPrincipalId])
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
  }
}

// ---- models + Foundry --------------------------------------------------
// Search's own identity needs model access for vectorization / Knowledge Base.
module ai 'modules/ai.bicep' = if (deployAi) {
  name: 'ai'
  params: {
    name: toLower('${base}-ai-${suffix}')
    location: location
    tags: tags
    deployments: modelDeployments
    deployFoundryProject: deployFoundryProject
    openAiUserPrincipalIds: concat([
      idDiagnostic.outputs.principalId
      idRemediation.outputs.principalId
      idRag.outputs.principalId
      idCiRepair.outputs.principalId
      idMonitor.outputs.principalId
    ], deployRag ? [ search!.outputs.principalId ] : [], empty(operatorPrincipalId) ? [] : [operatorPrincipalId])
    aiUserPrincipalIds: concat([ idRag.outputs.principalId ], empty(operatorPrincipalId) ? [] : [operatorPrincipalId])
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
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
output ragClientId string = idRag.outputs.clientId
output ciRepairClientId string = idCiRepair.outputs.clientId
output monitorClientId string = idMonitor.outputs.clientId

output agentsNamespace string = agentsNamespace
output diagnosticServiceAccount string = diagnosticServiceAccount
output remediationServiceAccount string = remediationServiceAccount
output chatDeployment string = deployAi && length(modelDeployments) > 0 ? modelDeployments[0].name : ''
output appInsightsConnectionString string = monitoring.outputs.connectionString

output aiAccountName string = deployAi ? ai!.outputs.name : ''
output aiAccountId string = deployAi ? ai!.outputs.id : ''
output searchResourceId string = deployRag ? search!.outputs.id : ''
output foundryProjectId string = deployAi ? ai!.outputs.projectId : ''
