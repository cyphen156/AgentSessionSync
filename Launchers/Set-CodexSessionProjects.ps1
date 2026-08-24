#requires -Version 5.1
<#
.SYNOPSIS
  Codex 세션의 의미상 프로젝트 태그를 수정한다. rollout 파일은 이동하지 않는다.
.EXAMPLE
  .\Set-CodexSessionProjects.ps1 019f... -Projects MyEngine,MyWorkbench
.EXAMPLE
  .\Set-CodexSessionProjects.ps1 019f... -Remove
#>
[CmdletBinding(DefaultParameterSetName='Set')]
param(
    [Parameter(Mandatory, Position=0)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SessionId,
    [Parameter(Mandatory, ParameterSetName='Set')][ValidateNotNullOrEmpty()][string[]]$Projects,
    [Parameter(Mandatory, ParameterSetName='Remove')][switch]$Remove
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')

$tiers = Get-CodexTierInventory $RepoRoot
$known = @{}
foreach ($id in @($tiers.Active.Keys) + @($tiers.Archived.Keys)) { $known[$id] = $true }
if (-not $known.ContainsKey($SessionId)) { throw "Vault에서 Codex 세션을 찾지 못했습니다: $SessionId" }

$path = Join-Path $RepoRoot 'Codex\session_projects.jsonl'
$records = @()
if (Test-Path -LiteralPath $path) {
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json }
        catch { throw "session_projects.jsonl에 잘못된 JSON 행이 있습니다: $line" }
        if ([string]$record.id -ne $SessionId) { $records += $record }
    }
}

if (-not $Remove) {
    $normalized = @($Projects | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($normalized.Count -eq 0) { throw '비어 있지 않은 프로젝트 태그가 하나 이상 필요합니다.' }
    $records += [pscustomobject][ordered]@{
        id = $SessionId.ToLowerInvariant()
        projects = $normalized
        source = 'manual'
    }
}

$lines = @($records | Sort-Object { [string]$_.id } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
Write-CodexIndexLines -Path $path -Lines $lines
if ($Remove) { Write-Host "[OK] 프로젝트 태그 제거: $SessionId" -ForegroundColor Green }
else { Write-Host "[OK] 프로젝트 태그 설정: $SessionId -> $($normalized -join ', ')" -ForegroundColor Green }
