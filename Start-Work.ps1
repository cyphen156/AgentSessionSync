#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentSessionSync.Common.ps1')
$config = Get-AgentSessionSyncConfig $repoRoot

if ($config.SyncProjectGit) {
    Assert-GitRepository $config.ProjectRoot
    Write-Host '[1/2] Pull target project' -ForegroundColor Cyan
    & git -C $config.ProjectRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'Target project pull failed.' }
} else {
    Write-Host '[1/2] Target project Git sync disabled' -ForegroundColor DarkGray
}
Write-Host '[2/2] Restore Claude/Codex sessions' -ForegroundColor Cyan
& (Join-Path $repoRoot 'Pull-Sessions.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session pull failed.' }
Write-Host "[READY] $($config.ProjectRoot)" -ForegroundColor Green

