using 'main.bicep'

// Full test bench: everything on.
param prefix = 'agtest'

param deployAcr = true
param deployAi = true
param deployRag = true
param deployAks = true
param deployMonitor = true

param searchSku = 'basic'
param aksNodeCount = 1
param monitorTrigger = 'Manual'
