// Search Index Data Reader for a principal that only exists once another module
// has run (the Foundry project's system identity). Assigned during the Bicep
// deployment so RBAC has propagated before the first agent run.
@description('Name of the existing Azure AI Search service in this resource group.')
param searchName string
param principalId string
@allowed([ 'ServicePrincipal', 'User' ])
param principalType string = 'ServicePrincipal'

var indexDataReaderRole = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

resource search 'Microsoft.Search/searchServices@2026-03-01-preview' existing = {
  name: searchName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, principalId, indexDataReaderRole)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', indexDataReaderRole)
    principalId: principalId
    principalType: principalType
  }
}
