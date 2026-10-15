@description('Account name; also the custom subdomain, so it must be globally unique.')
@maxLength(64)
param name string
param location string
param tags object = {}

@description('Model deployments: [{ name, model, version, capacity, sku? }]')
param deployments array

@description('Create a Foundry project under the account (needed for Foundry agents).')
param deployFoundryProject bool = true

@description('Principals that may call models (Cognitive Services OpenAI User).')
param openAiUserPrincipalIds array = []

@description('Principals that may use Foundry agents in the project (Azure AI User).')
param aiUserPrincipalIds array = []

var openAiUserRole = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var azureAiUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

// One AIServices account hosts both the OpenAI model deployments and Foundry projects.
resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true // Entra ID only, no API keys
    allowProjectManagement: true
  }
}

@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [for d in deployments: {
  parent: account
  name: d.name
  sku: {
    name: d.?sku ?? 'GlobalStandard'
    capacity: d.capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: d.model
      version: d.version
    }
  }
}]

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = if (deployFoundryProject) {
  parent: account
  name: 'agents-project'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
  dependsOn: [
    modelDeployments
  ]
}

resource openAiUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in openAiUserPrincipalIds: {
  name: guid(account.id, pid, openAiUserRole)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRole)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

resource aiUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in aiUserPrincipalIds: {
  name: guid(account.id, pid, azureAiUserRole)
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiUserRole)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
output openAiEndpoint string = 'https://${name}.openai.azure.com/'
output projectName string = deployFoundryProject ? project.name : ''
