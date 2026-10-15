@description('Globally unique, alphanumeric registry name (5-50 chars).')
@minLength(5)
@maxLength(50)
param name string
param location string
param tags object = {}

@description('Principals that may pull / read images (AcrPull). Read-only by design.')
param pullPrincipalIds array = []

var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

resource pullAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in pullPrincipalIds: {
  name: guid(acr.id, pid, acrPullRole)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

output name string = acr.name
output id string = acr.id
output loginServer string = acr.properties.loginServer
