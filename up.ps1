#Requires -Version 7
param(
    [string]$ResourceGroup = 'rg-agents-test',
    [string]$Location = 'westeurope',
    [string]$ParamFile = 'dev.bicepparam',
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
& python (Join-Path $PSScriptRoot 'scripts/platform_runner.py') up --group $ResourceGroup --location $Location --params $ParamFile @($(if ($Yes) { '--yes' }))
if ($LASTEXITCODE -ne 0) { throw 'Platform up failed. See the per-project reports; resources are retained for inspection/down.' }
