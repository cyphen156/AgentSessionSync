[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [switch]$EnableProjectGitSync,
    [switch]$EnableSessionPush
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$configPath = Join-Path $repoRoot 'AgentSessionSync.config.psd1'
$escapedProject = [IO.Path]::GetFullPath($ProjectRoot).Replace("'", "''")
$body = @"
@{
    ProjectRoot = '$escapedProject'
    SyncProjectGit = `$$($EnableProjectGitSync.IsPresent.ToString().ToLower())
    IncludeClaudeWorktrees = `$$true
    ClaudeHome = ''
    CodexHome = ''
    SessionDataPushEnabled = `$$($EnableSessionPush.IsPresent.ToString().ToLower())
}
"@
[IO.File]::WriteAllText($configPath, $body, (New-Object Text.UTF8Encoding($true)))
Set-Content -LiteralPath (Join-Path $repoRoot 'ACTIVE_HOST.txt') -Value 'NONE' -Encoding ASCII
Write-Host "Created local configuration: $configPath" -ForegroundColor Green
if (-not $EnableSessionPush) {
    Write-Warning 'Session push remains disabled. Re-run with -EnableSessionPush only in your own PRIVATE transport repository.'
}

