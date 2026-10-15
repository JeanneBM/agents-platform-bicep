@description('Name prefix for the monitoring resources.')
param name string
param location string
param tags object = {}
param retentionDays int = 30

@description('Principals allowed to run queries on the workspace (Log Analytics Reader).')
param readerPrincipalIds array = []

var logAnalyticsReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: '${name}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

resource readerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in readerPrincipalIds: {
  name: guid(law.id, pid, logAnalyticsReaderRole)
  scope: law
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRole)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

output workspaceId string = law.id
output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
output appInsightsId string = appi.id

output connectionString string = appi.properties.ConnectionString
