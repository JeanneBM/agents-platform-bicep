param operatorPrincipalId string = ''
param operatorPrincipalType string = 'User'
@description('Lowercase service name, 2-60 chars, globally unique.')
param name string
param location string
param tags object = {}

@allowed([ 'free', 'basic', 'standard' ])
@description('free: no semantic ranker, one per subscription. basic is the cheapest tier usable for a Knowledge Base.')
param sku string = 'basic'

@description('Principals that may query indexes (Search Index Data Reader).')
param readerPrincipalIds array = []

@description('Principals that may create indexes and load data (Service + Index Data Contributor). Test convenience.')
param contributorPrincipalIds array = []

var indexDataReaderRole = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
var indexDataContributorRole = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var serviceContributorRole = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

resource search 'Microsoft.Search/searchServices@2026-03-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'enabled'
    semanticSearch: sku == 'free' ? 'disabled' : 'free'
    knowledgeRetrieval: 'free'
    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' }
    }
  }
}

resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in readerPrincipalIds: {
  name: guid(search.id, pid, indexDataReaderRole)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', indexDataReaderRole)
    principalId: pid
    principalType: pid == operatorPrincipalId ? operatorPrincipalType : 'ServicePrincipal'
  }
}]

resource indexContributors 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in contributorPrincipalIds: {
  name: guid(search.id, pid, indexDataContributorRole)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', indexDataContributorRole)
    principalId: pid
    principalType: pid == operatorPrincipalId ? operatorPrincipalType : 'ServicePrincipal'
  }
}]

resource serviceContributors 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in contributorPrincipalIds: {
  name: guid(search.id, pid, serviceContributorRole)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceContributorRole)
    principalId: pid
    principalType: pid == operatorPrincipalId ? operatorPrincipalType : 'ServicePrincipal'
  }
}]

output id string = search.id
output name string = search.name
output endpoint string = 'https://${search.name}.search.windows.net'
output principalId string = search.identity.principalId
