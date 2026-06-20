Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-AgentSessionSyncPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
}

function ConvertTo-ClaudeProjectKey {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $fullPath = (Expand-AgentSessionSyncPath $ProjectRoot).TrimEnd('\', '/')
    return ($fullPath -replace '[:\\/\s]', '-')
}

function Get-AgentSessionSyncConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'AgentSessionSync.config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Local configuration is missing: $path`nRun Initialize-AgentSessionSync.ps1 first."
    }
    $raw = Import-PowerShellDataFile -LiteralPath $path
    if (-not $raw.ProjectRoot) { throw 'ProjectRoot is required in AgentSessionSync.config.psd1.' }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $claudeHome = if ($raw.ClaudeHome) { Expand-AgentSessionSyncPath $raw.ClaudeHome } else { Join-Path $userHome '.claude' }
    $codexHome = if ($raw.CodexHome) { Expand-AgentSessionSyncPath $raw.CodexHome } else { Join-Path $userHome '.codex' }
    $projectRoot = Expand-AgentSessionSyncPath $raw.ProjectRoot
    $key = ConvertTo-ClaudeProjectKey $projectRoot
    [pscustomobject]@{
        ProjectRoot = $projectRoot
        SyncProjectGit = [bool]$raw.SyncProjectGit
        IncludeClaudeWorktrees = if ($null -eq $raw.IncludeClaudeWorktrees) { $true } else { [bool]$raw.IncludeClaudeWorktrees }
        ClaudeHome = $claudeHome
        CodexHome = $codexHome
        ClaudeProjectKey = $key
        ClaudeProjectPattern = if ($raw.IncludeClaudeWorktrees) { "$key*" } else { $key }
        SessionDataPushEnabled = [bool]$raw.SessionDataPushEnabled
        GracefulCloseTimeoutSeconds = if ($raw.ContainsKey('GracefulCloseTimeoutSeconds') -and $raw['GracefulCloseTimeoutSeconds']) {
            [int]$raw['GracefulCloseTimeoutSeconds']
        } else { 20 }
    }
}

function Assert-GitRepository {
    param([Parameter(Mandatory)][string]$Path)
    & git -C $Path rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Not a Git repository: $Path" }
}
