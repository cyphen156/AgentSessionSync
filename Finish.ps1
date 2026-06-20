#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentLauncher.Common.ps1')
. (Join-Path $repoRoot 'AgentSessionSync.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }
$timeout = [int]$config.GracefulCloseTimeoutSeconds

Write-Host "[1/3] Closing $($agents.Count) registered agent(s) without force kill..." -ForegroundColor Cyan
foreach ($agent in ($agents | Sort-Object Order -Descending)) {
    Stop-AgentGracefully $agent $timeout
}
Write-Host '[2/3] Verifying all registered agents are closed...' -ForegroundColor Cyan
Assert-AllAgentsClosed $agents
Start-Sleep -Seconds 1
Write-Host '[3/3] Saving project and shared sessions...' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Finish-Work.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Finish sync failed.' }
Write-Host '[DONE] All agents closed and sessions pushed.' -ForegroundColor Green
