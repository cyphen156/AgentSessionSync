#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentLauncher.Common.ps1')
. (Join-Path $repoRoot 'AgentSessionSync.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }

if ($config.SyncProjectGit) {
    Assert-GitRepository $config.ProjectRoot
    Write-Host '[1/3] Pull target project' -ForegroundColor Cyan
    & git -C $config.ProjectRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'Target project pull failed.' }
} else {
    Write-Host '[1/3] Target project Git sync disabled' -ForegroundColor DarkGray
}

Write-Host '[2/3] Restore Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Pull-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session pull failed; no agents were opened.' }

Write-Host "[3/3] Opening $($agents.Count) registered agent(s)..." -ForegroundColor Cyan
foreach ($agent in $agents) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($agent.AppId)"
    Write-Host "  Opened: $($agent.Name)"
}
Write-Host '[READY] Sync completed and all agents were launched.' -ForegroundColor Green
