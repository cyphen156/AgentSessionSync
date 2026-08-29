#requires -Version 5.1
<#
  -Preflight 는 복원을 시작할 수 있는지만 확인하고 끝낸다.

  통합 런처(All-Start)가 등록된 모든 패키지를 먼저 이 모드로 돌려서, 하나라도
  실패하면 어떤 파일도 적용하지 않고 baton 도 잡지 않고 앱도 열지 않는다.
  Git 상태만 봐서는 계획 오류를 못 잡으므로 앱별 계획까지 실제로 만들어 본다.

  이 모드는 아무것도 바꾸지 않는다. pull 하지 않고, baton 을 claim 하지 않으며,
  앱 저장소에 쓰지도 앱을 실행하지도 않는다.
#>
[CmdletBinding()] param([switch]$Preflight)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentLauncher.Common.ps1')
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
# 사전검사가 앱별 계획을 만들려면 어댑터가 필요하다.
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSessionState.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }

if ($Preflight) {
    Write-Host '[0/2] Preflight Vault, gzip transport, and per-agent plans...' -ForegroundColor Cyan
    Test-AgentSessionStartPreflight -RepoRoot $repoRoot -Config $config
    Write-Host '[OK] Start preflight passed. Nothing was restored and no agent was opened.' -ForegroundColor Green
    $global:LASTEXITCODE = 0
    return
}

Write-Host '[1/2] Restore Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Pull-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session pull failed; no agents were opened.' }

Write-Host "[2/2] Opening $($agents.Count) registered agent(s)..." -ForegroundColor Cyan
foreach ($agent in $agents) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($agent.AppId)"
    Write-Host "  Opened: $($agent.Name)"
}
Write-Host '[READY] Sync completed and all agents were launched.' -ForegroundColor Green
