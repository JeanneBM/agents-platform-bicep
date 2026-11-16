#Requires -Version 7
param([Parameter(Mandatory)] [string] $ResourceGroup, [switch] $Yes)
. (Join-Path $PSScriptRoot 'common.ps1')
$statePath = Get-StatePath $ResourceGroup
$exists = Invoke-Az group exists -n $ResourceGroup -o tsv
if ($exists -eq 'true') {
    $tag = Invoke-Az group show -n $ResourceGroup --query tags.workload -o tsv
    if ($tag -ne 'agents-test') { throw 'Refusing: resource group is not tagged workload=agents-test.' }
    if (-not $Yes -and (Read-Host "Delete '$ResourceGroup' and its infrastructure? (y/N)") -ne 'y') { return }
    # Retain the actual AKS node resource groups and AI account names for post-deletion work.
    $nodeGroups = @(Invoke-Az aks list -g $ResourceGroup --query '[].nodeResourceGroup' -o json | ConvertFrom-Json)
    $aiAccounts = @(Invoke-Az cognitiveservices account list -g $ResourceGroup --query '[].{name:name,location:location}' -o json | ConvertFrom-Json)
    @{ nodeGroups = $nodeGroups; aiAccounts = $aiAccounts } | ConvertTo-Json -Depth 5 | Set-Content "$statePath.cleanup"
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
    # Deleted AI Services accounts stay soft-deleted and reserve their name (and
    # custom subdomain). The name is derived from the resource group, so the next
    # up with the same group would collide: purge our own accounts explicitly.
    foreach ($account in @($cleanup.aiAccounts)) {
        $purged = $false
        for ($attempt = 1; $attempt -le 6 -and -not $purged; $attempt++) {
            $deleted = @(Invoke-Az cognitiveservices account list-deleted -o json | ConvertFrom-Json) |
                Where-Object { $_.name -eq $account.name -and $_.location -eq $account.location }
            if (-not $deleted) { Start-Sleep -Seconds 10; continue }
            Invoke-Az cognitiveservices account purge -n $account.name -g $ResourceGroup -l $account.location | Out-Null
            $purged = $true
            Write-Host "Purged soft-deleted AI account $($account.name)."
        }
        if (-not $purged) { Write-Warning "AI account $($account.name) was not found among deleted accounts; if the next up reports a name conflict, run: az cognitiveservices account purge -n $($account.name) -g $ResourceGroup -l $($account.location)" }
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
Write-Host 'Resource group, recorded AKS node groups and soft-deleted AI accounts removed.'
