#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentLauncher.Common.ps1')
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }

Write-Host '[1/2] Updating project and shared sessions...' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Start-Work.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Start sync failed; no agents were opened.' }

Write-Host "[2/2] Opening $($agents.Count) registered agent(s)..." -ForegroundColor Cyan
foreach ($agent in $agents) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($agent.AppId)"
    Write-Host "  Opened: $($agent.Name)"
}
Write-Host '[READY] Sync completed and all agents were launched.' -ForegroundColor Green
