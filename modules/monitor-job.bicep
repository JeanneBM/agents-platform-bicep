param name string
param location string
param tags object = {}
param workspaceName string
param identityId string
param identityClientId string
param workspaceCustomerId string

@description('Container image. The default is a placeholder; push the agent-monitor image and override.')
param image string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

@description('Set true when `image` lives in the ACR below; wires pull via the managed identity.')
param imageFromAcr bool = false
param acrLoginServer string = ''

@allowed([ 'Manual', 'Schedule' ])
param trigger string = 'Manual'
param cronExpression string = '0 */6 * * *'

@description('Optional endpoint for LLM triage (the job still works without it).')
param openAiEndpoint string = ''
param openAiDeployment string = ''

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${name}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: '${name}-job'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: env.id
    configuration: {
      triggerType: trigger
      replicaTimeout: 600
      replicaRetryLimit: 0
      scheduleTriggerConfig: trigger == 'Schedule' ? {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      } : null
      manualTriggerConfig: trigger == 'Manual' ? {
        parallelism: 1
        replicaCompletionCount: 1
      } : null
      registries: imageFromAcr ? [
        {
          server: acrLoginServer
          identity: identityId
        }
      ] : []
    }
    template: {
      containers: [
        {
          name: 'monitor'
          image: image
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'LOG_ANALYTICS_WORKSPACE_ID', value: workspaceCustomerId }
            { name: 'AZURE_OPENAI_ENDPOINT', value: openAiEndpoint }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: openAiDeployment }
          ]
        }
      ]
    }
  }
}

output jobName string = job.name
