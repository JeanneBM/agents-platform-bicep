#Requires -Version 7
param([string]$ResourceGroup = 'rg-agents-test', [ValidateSet('S01','S02','S03','S04')][string]$Scenario = 'S01')
& python (Join-Path $PSScriptRoot 'scripts/platform_runner.py') ci --group $ResourceGroup --scenario $Scenario
if ($LASTEXITCODE -ne 0) { throw 'Monitored CI execution failed; inspect reports and monitor findings.' }
