#Requires -Version 7
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'westeurope',
    [string] $ParamFile = 'dev.bicepparam',
    [string] $OperatorPrincipalId = '',
    [string] $OperatorPrincipalType = 'User',
    [switch] $SkipKubernetesRbac,
    [switch] $Yes
)
. (Join-Path $PSScriptRoot 'common.ps1')
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $statePath = Get-StatePath $ResourceGroup
    $exists = Invoke-Az group exists -n $ResourceGroup -o tsv
    if ($exists -eq 'true') {
        $tag = Invoke-Az group show -n $ResourceGroup --query tags.workload -o tsv
        if ($tag -ne 'agents-test') { throw 'Refusing to use a resource group not tagged workload=agents-test.' }
    }
    # Preserve the original inventory across retries, including partial deployments.
    if (-not (Test-Path $statePath)) {
        $watchers = @(Invoke-Az network watcher list -o json | ConvertFrom-Json)
        @{ resourceGroup = $ResourceGroup; watcherIdsBefore = @($watchers | ForEach-Object { $_.id }) } |
            ConvertTo-Json -Depth 10 | Set-Content $statePath
    }
    Invoke-Az bicep build --file main.bicep --stdout | Out-Null
    Invoke-Az group create -n $ResourceGroup -l $Location --tags workload=agents-test | Out-Null
    $operatorArgs = @("operatorPrincipalId=$OperatorPrincipalId", "operatorPrincipalType=$OperatorPrincipalType")
    Invoke-Az deployment group what-if -g $ResourceGroup -p $ParamFile @operatorArgs
    if (-not $Yes -and (Read-Host 'Apply this deployment? (y/N)') -ne 'y') { throw 'Deployment cancelled.' }
    $out = Invoke-Az deployment group create -g $ResourceGroup -p $ParamFile @operatorArgs --query properties.outputs -o json | ConvertFrom-Json
    $out | ConvertTo-Json -Depth 10 | Set-Content ./outputs.json
    if ($out.aksName.value -and -not $SkipKubernetesRbac) {
        Invoke-Az aks get-credentials -g $ResourceGroup -n $out.aksName.value --overwrite-existing | Out-Null
        $manifest = Get-Content ./k8s/agents-rbac.yaml -Raw
        $values = @{
            '__DIAGNOSTIC_CLIENT_ID__' = $out.diagnosticClientId.value
            '__REMEDIATION_CLIENT_ID__' = $out.remediationClientId.value
            '__AGENTS_NAMESPACE__' = $out.agentsNamespace.value
            '__DIAGNOSTIC_SERVICE_ACCOUNT__' = $out.diagnosticServiceAccount.value
            '__REMEDIATION_SERVICE_ACCOUNT__' = $out.remediationServiceAccount.value
        }
        foreach ($key in $values.Keys) { $manifest = $manifest.Replace($key, $values[$key]) }
        $manifest | kubectl apply -f -
        if ($LASTEXITCODE -ne 0) { throw 'kubectl apply failed.' }
    }
    Write-Host 'Infrastructure ready. Outputs: outputs.json. Deploy agents using their own repositories.'
} finally { Pop-Location }
