#Requires -Version 7
param([string]$ResourceGroup = 'rg-agents-test', [switch]$Yes)
$ErrorActionPreference = 'Stop'
& python (Join-Path $PSScriptRoot 'scripts/platform_runner.py') down --group $ResourceGroup @($(if ($Yes) { '--yes' }))
if ($LASTEXITCODE -ne 0) { throw 'Platform cleanup is incomplete; inspect output and retry.' }
