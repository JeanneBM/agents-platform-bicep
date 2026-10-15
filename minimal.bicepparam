using 'main.bicep'

// Cheap bench: shared resources, models and the monitor job. No AKS, no Search.
param prefix = 'agmin'

param deployAcr = false
param deployAi = true
param deployRag = false
param deployAks = false
param deployMonitor = true
param deployFoundryProject = false
