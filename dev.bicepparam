using 'main.bicep'

// Full test bench: everything on. Regions follow the configurations the
// application repositories were validated against: AKS in Poland Central,
// models/Search in Sweden Central. Override aiLocation if your subscription
// has gpt-4.1-mini quota elsewhere.
param prefix = 'agtest'
param aiLocation = 'swedencentral'
param chatModel = 'gpt-4.1-mini'
param chatModelVersion = '2025-04-14'
param chatCapacity = 10

param deployAcr = true
param deployAi = true
param deployRag = true
param deployAks = true
param deployMonitor = false // real monitor CLI is launched by up.ps1 in batch mode

param searchSku = 'basic'
param aksNodeCount = 1
param aksVmSize = 'Standard_D2as_v4'
param monitorTrigger = 'Manual'
