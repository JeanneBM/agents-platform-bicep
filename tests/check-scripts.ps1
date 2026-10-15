# Offline native-command contract check; no Azure calls are made.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$global:platformMockCalls = [System.Collections.Generic.List[string]]::new()
function global:az {
    $global:platformMockCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { 'mock-subscription'; return }
    if ($line -like 'group exists*') { 'false'; return }
    if ($line -like 'network watcher list*') { '[]'; return }
    if ($line -like 'deployment group create*') { '{"aksName":{"value":""}}'; return }
}
try {
    & (Join-Path $root 'scripts/deploy.ps1') -ResourceGroup mock-contract -Yes -SkipKubernetesRbac -OperatorPrincipalId mock-operator -OperatorPrincipalType User
    $create = @($global:platformMockCalls | Where-Object { $_ -like 'deployment group create*' })
    if ($create.Count -ne 1 -or $create[0] -notlike '*operatorPrincipalId=mock-operator*' -or $create[0] -notlike '*operatorPrincipalType=User*') {
        throw 'Operator role parameters were not passed to native az invocation.'
    }
    function global:az { $global:LASTEXITCODE = 9 }
    . (Join-Path $root 'scripts/common.ps1')
    $caught = $false
    try { Invoke-Az account show } catch { $caught = $true }
    if (-not $caught) { throw 'Native CLI error was not propagated.' }
    $global:LASTEXITCODE = 0 # Expected failing mock must not leak into the CI shell exit status.
    Write-Output 'PASS: deployment argument contract and native failure propagation'
} finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'outputs.json') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root '.state/mock-subscription-mock-contract.json') -ErrorAction SilentlyContinue
}
