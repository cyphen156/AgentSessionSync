#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentLauncher.Common.ps1')
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }
$timeout = [int]$config.GracefulCloseTimeoutSeconds
Assert-CurrentProcessOutsideAgentTrees $agents

Write-Host "[1/3] Closing all registered agent process trees..." -ForegroundColor Cyan
foreach ($agent in ($agents | Sort-Object Order -Descending)) {
    Stop-AgentGracefully $agent $timeout
}
Write-Host '[2/3] Verifying all registered agents are closed...' -ForegroundColor Cyan
Assert-AllAgentsClosed $agents
# The process tree is gone, but the kernel can release the final session-file handle
# slightly later. Settle briefly before reading the files.
Start-Sleep -Seconds 1

Write-Host '[3/3] Snapshot and push Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Push-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session push failed.' }
Write-Host '[DONE] All agents closed and sessions pushed.' -ForegroundColor Green
