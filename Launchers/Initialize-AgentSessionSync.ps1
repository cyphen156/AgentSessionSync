[CmdletBinding()]
param([switch]$EnableSessionPush)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'AgentSessionSync.config.psd1'
$body = @"
@{
    ClaudeHome = ''
    CodexHome = ''
    ActiveWindowDays = 30
    TransportFileLimitBytes = 99614720
    SessionDataPushEnabled = `$$($EnableSessionPush.IsPresent.ToString().ToLower())
    GracefulCloseTimeoutSeconds = 8
}
"@
[IO.File]::WriteAllText($configPath, $body, (New-Object Text.UTF8Encoding($true)))
$lockPath = Join-Path $repoRoot 'ACTIVE_HOST.txt'
if (-not (Test-Path -LiteralPath $lockPath)) {
    [IO.File]::WriteAllText($lockPath, "NONE`n", (New-Object Text.ASCIIEncoding))
}
Write-Host "Created local configuration: $configPath" -ForegroundColor Green
& (Join-Path $PSScriptRoot 'Create-Shortcuts.ps1')
if (-not $EnableSessionPush) {
    Write-Warning 'Session push remains disabled. Re-run with -EnableSessionPush only in your own PRIVATE transport repository.'
}
