using 'main.bicep'

// Full test bench: everything on.
param prefix = 'agtest'

param deployAcr = true
param deployAi = true
param deployRag = true
param deployAks = true
param deployMonitor = false // real monitor CLI is launched by up.ps1 in batch mode

param searchSku = 'basic'
param aksNodeCount = 1
param monitorTrigger = 'Manual'
