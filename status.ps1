#Requires -Version 7
param([string]$ResourceGroup = 'rg-agents-test')
& python (Join-Path $PSScriptRoot 'scripts/platform_runner.py') status --group $ResourceGroup
if ($LASTEXITCODE -ne 0) { throw 'Some platform checks failed.' }
