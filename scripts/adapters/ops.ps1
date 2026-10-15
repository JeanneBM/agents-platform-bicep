#Requires -Version 7
param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Config)
. (Join-Path $PSScriptRoot '../common.ps1')
$c = Get-Content $Config -Raw | ConvertFrom-Json
$work = Split-Path $Config -Parent
$kubeconfig = Join-Path $work 'kubeconfig'
function Kube {
    $result = & kubectl --kubeconfig $kubeconfig @args
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($args[0])" }
    return $result
}
Invoke-Az aks get-credentials -g $c.resourceGroup -n $c.aksName --file $kubeconfig --overwrite-existing | Out-Null
$registry = $c.acrLoginServer.Split('.')[0]
Invoke-Az acr build --registry $registry --image 'agentic-ops:platform' $Repo | Out-Host
Invoke-Az acr import --name $registry --source docker.io/library/nginx:1.27 --image payments-api:1.4.2 --force | Out-Null
foreach ($ns in @($c.agentsNamespace, 'payments')) {
    "apiVersion: v1`nkind: Namespace`nmetadata:`n  name: $ns" | & kubectl --kubeconfig $kubeconfig apply -f - | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Namespace apply failed.' }
}
# Stop watchers before resetting the healthy demo on a repeated up.
$existing = Kube get deployments -n $c.agentsNamespace -o json | ConvertFrom-Json
foreach ($d in $existing.items) {
    if ($d.metadata.name -in @('agentic-ops-diagnostic','agentic-ops-remediation')) {
        Kube scale "deployment/$($d.metadata.name)" -n $c.agentsNamespace --replicas=0 | Out-Host
        Kube rollout status "deployment/$($d.metadata.name)" -n $c.agentsNamespace --timeout=300s | Out-Host
    }
}
$values = @{
    ACR_LOGIN_SERVER = $c.acrLoginServer
    AGENTIC_OPS_IMAGE = "$($c.acrLoginServer)/agentic-ops:platform"
    MANAGED_NAMESPACE = 'payments'
    AZURE_AI_FOUNDRY_ENDPOINT = $c.openAiEndpoint
    AZURE_AI_FOUNDRY_DEPLOYMENT = $c.chatDeployment
    DIAGNOSTIC_AZURE_CLIENT_ID = $c.diagnosticClientId
    REMEDIATION_AZURE_CLIENT_ID = $c.remediationClientId
}
$bytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$secret = @{apiVersion='v1'; kind='Secret'; metadata=@{name='agentic-ops-remediation';namespace=$c.agentsNamespace}; type='Opaque'; data=@{token=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Convert]::ToBase64String($bytes)))}}
$secret | ConvertTo-Json -Depth 8 | & kubectl --kubeconfig $kubeconfig apply -f - | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Secret apply failed.' }
$bytes=$null; $secret=$null
foreach ($source in @('demo-payments-api.yaml','aks-agentic-ops.yaml')) {
    $manifest = Get-Content (Join-Path $Repo "deploy/$source") -Raw
    foreach ($key in $values.Keys) { $manifest = $manifest.Replace(('${'+$key+'}'), [string]$values[$key]) }
    $manifest = $manifest.Replace('/paymnets-api:1.4.2','/payments-api:1.4.2')
    # The pinned upstream manifests use these service-account and namespace names.
    $manifest = $manifest.Replace('agentic-ops.svc.cluster.local', "$($c.agentsNamespace).svc.cluster.local")
    $manifest = $manifest.Replace('namespace: agentic-ops', "namespace: $($c.agentsNamespace)")
    $manifest = $manifest.Replace('serviceAccountName: agentic-ops-diagnostic', "serviceAccountName: $($c.diagnosticServiceAccount)")
    $manifest = $manifest.Replace('serviceAccountName: agentic-ops-remediation', "serviceAccountName: $($c.remediationServiceAccount)")
    # Rename SA resources/subjects without renaming workload and service names.
    $manifest = $manifest -replace '(?m)(kind: ServiceAccount\r?\nmetadata:\r?\n  name: )agentic-ops-diagnostic', "`${1}$($c.diagnosticServiceAccount)"
    $manifest = $manifest -replace '(?m)(kind: ServiceAccount\r?\nmetadata:\r?\n  name: )agentic-ops-remediation', "`${1}$($c.remediationServiceAccount)"
    $manifest = $manifest -replace '(?m)(- kind: ServiceAccount\r?\n    name: )agentic-ops-diagnostic', "`${1}$($c.diagnosticServiceAccount)"
    $manifest = $manifest -replace '(?m)(- kind: ServiceAccount\r?\n    name: )agentic-ops-remediation', "`${1}$($c.remediationServiceAccount)"
    if ($manifest -match '\$\{[^}]+\}') { throw "Unresolved placeholder: $source" }
    $file = Join-Path $work $source
    Set-Content $file $manifest
    Kube apply -f $file | Out-Host
    if ($source -eq 'demo-payments-api.yaml') {
        Kube rollout status deployment/payments-api -n payments --timeout=300s | Out-Host
    }
}
foreach ($role in @('remediation','diagnostic')) {
    Kube rollout status "deployment/agentic-ops-$role" -n $c.agentsNamespace --timeout=300s | Out-Host
}
