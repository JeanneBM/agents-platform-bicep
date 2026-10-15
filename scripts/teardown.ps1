#Requires -Version 7
param([Parameter(Mandatory)] [string] $ResourceGroup, [switch] $Yes)
. (Join-Path $PSScriptRoot 'common.ps1')
$statePath = Get-StatePath $ResourceGroup
$exists = Invoke-Az group exists -n $ResourceGroup -o tsv
if ($exists -eq 'true') {
    $tag = Invoke-Az group show -n $ResourceGroup --query tags.workload -o tsv
    if ($tag -ne 'agents-test') { throw 'Refusing: resource group is not tagged workload=agents-test.' }
    if (-not $Yes -and (Read-Host "Delete '$ResourceGroup' and its infrastructure? (y/N)") -ne 'y') { return }
    # Retain the actual AKS node resource groups for post-deletion verification.
    $nodeGroups = @(Invoke-Az aks list -g $ResourceGroup --query '[].nodeResourceGroup' -o json | ConvertFrom-Json)
    @{ nodeGroups = $nodeGroups } | ConvertTo-Json | Set-Content "$statePath.cleanup"
    Invoke-Az group delete -n $ResourceGroup --yes
}
if ((Invoke-Az group exists -n $ResourceGroup -o tsv) -ne 'false') { throw 'Resource group deletion is not complete.' }
if (Test-Path "$statePath.cleanup") {
    $cleanup = Get-Content "$statePath.cleanup" -Raw | ConvertFrom-Json
    foreach ($nodeGroup in $cleanup.nodeGroups) {
        if ((Invoke-Az group exists -n $nodeGroup -o tsv) -ne 'false') {
            throw "AKS node resource group still exists: $nodeGroup. Retry teardown after Azure finishes cleanup."
        }
    }
}
# Network Watchers are regional/shared. Never delete one based only on its name.
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $watchers = @(Invoke-Az network watcher list -o json | ConvertFrom-Json)
    $newWatchers = @($watchers | Where-Object { $_.id -notin $state.watcherIdsBefore })
    if ($newWatchers.Count -gt 0) {
        Write-Warning 'Network Watchers appeared since the initial inventory. Ownership is not proven; inspect before removal:'
        $newWatchers | Select-Object name, resourceGroup, location, id | Format-Table
        throw 'Main resource group removed; external Network Watchers require review. Full cleanup is not confirmed.'
    }
} else { Write-Warning 'No initial inventory: external Network Watcher cleanup cannot be verified.' }
Write-Host 'Resource group and recorded AKS node groups removed. AI soft-delete retention may still reserve names.'
# AI purge is intentionally manual: az cognitiveservices account list-deleted
