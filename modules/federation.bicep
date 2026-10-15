@description('Name of an existing user-assigned managed identity in this resource group.')
param identityName string
param oidcIssuerUrl string
param namespace string
param serviceAccount string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Lets exactly one Kubernetes service account act as this identity.
resource fic 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'aks-${namespace}-${serviceAccount}'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${namespace}:${serviceAccount}'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}
