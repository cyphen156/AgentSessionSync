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

Write-Host "[1/4] Closing $($agents.Count) registered agent(s) without force kill..." -ForegroundColor Cyan
foreach ($agent in ($agents | Sort-Object Order -Descending)) {
    Stop-AgentGracefully $agent $timeout
}
Write-Host '[2/4] Verifying all registered agents are closed...' -ForegroundColor Cyan
Assert-AllAgentsClosed $agents
Start-Sleep -Seconds 1

if ($config.SyncProjectGit) {
    Assert-GitRepository $config.ProjectRoot
    Write-Host '[3/4] Commit and push target project' -ForegroundColor Cyan
    & git -C $config.ProjectRoot add -A
    if ($LASTEXITCODE -ne 0) { throw 'Target project add failed.' }
    & git -C $config.ProjectRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        & git -C $config.ProjectRoot commit -m "sync from $env:COMPUTERNAME @ $stamp"
        if ($LASTEXITCODE -ne 0) { throw 'Target project commit failed.' }
    }
    & git -C $config.ProjectRoot push
    if ($LASTEXITCODE -ne 0) { throw 'Target project push failed; sessions were not pushed.' }
} else {
    Write-Host '[3/4] Target project Git sync disabled' -ForegroundColor DarkGray
}

Write-Host '[4/4] Snapshot and push Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Push-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session push failed.' }
Write-Host '[DONE] All agents closed and sessions pushed.' -ForegroundColor Green
