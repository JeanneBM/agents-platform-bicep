#Requires -Version 7
param([string]$ResourceGroup = 'rg-agents-test', [string]$Question)
$ErrorActionPreference = 'Stop'
$arguments = @((Join-Path $PSScriptRoot 'scripts/platform_runner.py'), 'chat', '--group', $ResourceGroup)
if ($Question) { $arguments += @('--question', $Question) }
& python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Monitored RAG session failed; inspect telemetry and monitor findings.' }
