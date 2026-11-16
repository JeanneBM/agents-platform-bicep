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
function Invoke-Retry([string]$What, [int]$Attempts, [scriptblock]$Action) {
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return (& $Action) } catch {
            if ($i -eq $Attempts) { throw }
            Write-Warning "$What failed (attempt $i/$Attempts): $($_.Exception.Message). Retrying in 30s; RBAC/registry propagation can lag."
            Start-Sleep -Seconds 30
        }
    }
}
Invoke-Az aks get-credentials -g $c.resourceGroup -n $c.aksName --file $kubeconfig --overwrite-existing | Out-Null
$registry = $c.acrLoginServer.Split('.')[0]
# --no-logs: streamed build logs break on some Windows consoles (upstream fix); the
# build result is still checked through the exit code. AcrPush for the operator is
# assigned by Bicep and may take a few minutes to propagate, hence the retries.
Invoke-Retry 'ACR build' 5 { Invoke-Az acr build --registry $registry --image 'agentic-ops:platform' --no-logs --only-show-errors $Repo | Out-Host }
Invoke-Retry 'ACR import' 5 { Invoke-Az acr import --name $registry --source docker.io/library/nginx:1.27 --image test-app:1.4.2 --force --only-show-errors | Out-Null }
foreach ($ns in @($c.agentsNamespace, 'test-app')) {
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
    MANAGED_NAMESPACE = 'test-app'
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
foreach ($source in @('demo-test-app.yaml','aks-agentic-ops.yaml')) {
    $manifest = Get-Content (Join-Path $Repo "deploy/$source") -Raw
    foreach ($key in $values.Keys) { $manifest = $manifest.Replace(('${'+$key+'}'), [string]$values[$key]) }
    $manifest = $manifest.Replace('/tset-app:1.4.2','/test-app:1.4.2')
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
    if ($source -eq 'demo-test-app.yaml') {
        Kube rollout status deployment/test-app -n test-app --timeout=600s | Out-Host
    }
}
foreach ($role in @('remediation','diagnostic')) {
    try {
        Kube rollout status "deployment/agentic-ops-$role" -n $c.agentsNamespace --timeout=600s | Out-Host
    } catch {
        # Keep the diagnosis in the report instead of a bare timeout.
        & kubectl --kubeconfig $kubeconfig get pods -n $c.agentsNamespace -l "role=$role" -o wide | Out-Host
        & kubectl --kubeconfig $kubeconfig describe pods -n $c.agentsNamespace -l "role=$role" | Select-String -Pattern 'Warning|Error|BackOff|Failed' | Select-Object -First 10 | Out-Host
        throw
    }
}
