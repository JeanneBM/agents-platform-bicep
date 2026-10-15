param name string
param location string
param tags object = {}
param nodeCount int = 1
@description('Small by default; check quota/availability in your region.')
param vmSize string = 'Standard_D4s_v5'
param workspaceId string

@description('Registry to grant the kubelet AcrPull on. Leave empty to skip.')
param acrName string = ''

var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: name
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: vmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
    }
    // Workload Identity: pods authenticate as managed identities, no secrets.
    oidcIssuerProfile: { enabled: true }
    securityProfile: {
      workloadIdentity: { enabled: true }
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: workspaceId }
      }
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (!empty(acrName)) {
  name: acrName
}

resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrName)) {
  name: guid(aks.id, acrName, acrPullRole)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output name string = aks.name
output id string = aks.id
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
