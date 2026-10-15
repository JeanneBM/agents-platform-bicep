#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Invoke-Az {
    $result = & az @args
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE): az $($args -join ' ')" }
    return $result
}
function Get-StatePath([string] $ResourceGroup) {
    $subscription = Invoke-Az account show --query id -o tsv
    $dir = Join-Path $PSScriptRoot '../.state'
    New-Item -ItemType Directory -Force $dir | Out-Null
    return Join-Path $dir "$subscription-$ResourceGroup.json"
}
