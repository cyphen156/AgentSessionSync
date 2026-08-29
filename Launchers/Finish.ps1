#requires -Version 5.1
<#
  -Preflight 는 앱을 닫기 전에 실행 가능성만 확인하고 끝낸다.

  통합 런처(All-Finish)가 등록된 모든 패키지를 먼저 이 모드로 돌려서, 하나라도
  실패하면 어느 앱도 닫지 않고 중단한다. 앱을 전부 죽인 뒤 계획 오류로 실패한
  사고가 이 계약을 만든 이유이므로, 사전검사는 앱별 계획까지 실제로 만들어 본다.

  이 모드는 아무것도 바꾸지 않는다. fetch·merge·push 하지 않고, 앱을 닫지 않으며,
  스냅숏도 만들지 않는다.
#>
[CmdletBinding()] param([switch]$Preflight)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentLauncher.Common.ps1')
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSessionState.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents found in Agents.' }
$timeout = [int]$config.GracefulCloseTimeoutSeconds
Assert-CurrentProcessOutsideAgentTrees $agents

Write-Host '[0/3] Preflight Vault, gzip transport, checkpoints, and per-agent plans...' -ForegroundColor Cyan
Test-AgentSessionFinishPreflight -RepoRoot $repoRoot -Config $config
[void](Test-AgentSessionCheckpointCurrent -RepoRoot $repoRoot -Checkpoint (Read-CodexCheckpoint $repoRoot) -AgentName 'Codex')
[void](Test-AgentSessionCheckpointCurrent -RepoRoot $repoRoot -Checkpoint (Read-ClaudeCheckpoint $repoRoot) -AgentName 'Claude')

if ($Preflight) {
    Write-Host '[OK] Finish preflight passed. No agent was closed and the Vault was not touched.' -ForegroundColor Green
    $global:LASTEXITCODE = 0
    return
}

Write-Host "[1/3] Closing all registered agent process trees..." -ForegroundColor Cyan
foreach ($agent in ($agents | Sort-Object Order -Descending)) {
    Stop-AgentGracefully $agent $timeout -ForceProcessTree
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
