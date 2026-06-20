#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentSessionSync.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot

if ($config.SyncProjectGit) {
    Assert-GitRepository $config.ProjectRoot
    Write-Host '[1/2] Commit and push target project' -ForegroundColor Cyan
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
    Write-Host '[1/2] Target project Git sync disabled' -ForegroundColor DarkGray
}
Write-Host '[2/2] Snapshot and push Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Push-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session push failed.' }
Write-Host '[DONE] Project handoff completed.' -ForegroundColor Green

