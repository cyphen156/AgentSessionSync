#requires -Version 5.1
<#
.SYNOPSIS
  앱 목록 항목과 transcript 의 끊어진 연결(cliSessionId)을 되돌린다.
.DESCRIPTION
  트랜스크립트가 없는 PC에서 앱이 항목을 열면 cliSessionId 를 떼어내고
  transcriptUnavailable 을 찍는다. 나중에 그 transcript 가 다시 들어와도 연결은
  스스로 복구되지 않아 대화가 "디스크에서 세션을 찾을 수 없음"으로 남는다.

  이 스크립트는 그 연결만 되돌린다. 원문은 건드리지 않는다.

  Claude 앱이 실행 중이면 앱이 메모리에 든 항목을 종료 시점에 다시 쓸 수 있다.
  앱을 완전히 종료한 뒤 실행하는 것이 확실하다.
.PARAMETER AppSessionId
  목록 항목 파일명의 local_ 뒤 부분.
.PARAMETER CliSessionId
  연결할 transcript 파일명(확장자 제외).
.EXAMPLE
  .\Launchers\Repair-ClaudeEntryBinding.ps1 -AppSessionId a7d1d3f9-... -CliSessionId 3b17ee0d-...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppSessionId,
    [Parameter(Mandatory)][string] $CliSessionId,
    [switch] $Force
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot

if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) {
    if (-not $Force) {
        Write-Warning 'Claude 앱이 실행 중입니다. 종료 시 앱이 이 수정을 덮어쓸 수 있습니다.'
        Write-Warning '앱을 완전히 종료한 뒤 다시 실행하거나, 그대로 진행하려면 -Force 를 주세요.'
        $global:LASTEXITCODE = 1
        return
    }
    Write-Warning 'Claude 앱이 실행 중입니다(-Force). 앱 재시작 후 결과를 반드시 확인하세요.'
}

$registryRoots = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions')
) | Where-Object { Test-Path -LiteralPath $_ }
if (-not $registryRoots) { throw '앱 목록 레지스트리를 찾지 못했습니다.' }

$entries = @(foreach ($root in $registryRoots) {
    Get-ChildItem -LiteralPath $root -Filter "local_$AppSessionId.json" -File -Recurse -ErrorAction SilentlyContinue
})
if (-not $entries) { throw "목록 항목을 찾지 못했습니다: local_$AppSessionId.json" }

# 연결 대상 transcript 가 실제로 있는지 먼저 확인한다. 없는 곳을 가리키게 만들면
# 앱이 다시 연결을 떼어내고 같은 상태로 돌아간다.
$sample = [IO.File]::ReadAllText($entries[0].FullName, [Text.Encoding]::UTF8)
if ($sample -notmatch '"cwd"\s*:\s*"([^"]+)"') { throw '항목에서 cwd 를 읽지 못했습니다.' }
$cwd = $Matches[1] -replace '\\\\', '\'
$projectKey = ConvertTo-ClaudeProjectKey $cwd
$transcript = Join-Path (Join-Path (Join-Path $Config.ClaudeHome 'projects') $projectKey) ($CliSessionId + '.jsonl')
if (-not (Test-Path -LiteralPath $transcript)) {
    throw "연결할 transcript 가 이 PC에 없습니다: $transcript"
}
Write-Host "대상 transcript 확인: $transcript" -ForegroundColor DarkGray

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($entry in $entries) {
    $text = [IO.File]::ReadAllText($entry.FullName, [Text.Encoding]::UTF8)
    if ($text -match '"cliSessionId"\s*:\s*"([^"]+)"') {
        Write-Host "  이미 연결되어 있습니다($($Matches[1])): $($entry.FullName)" -ForegroundColor DarkGray
        continue
    }
    Copy-Item -LiteralPath $entry.FullName -Destination "$($entry.FullName).bak-$stamp" -Force

    $updated = $text -replace '("sessionId"\s*:\s*"[^"]*"\s*,)', ('$1"cliSessionId":"' + $CliSessionId + '",')
    if ($updated -eq $text) { throw "sessionId 필드를 찾지 못해 수정하지 못했습니다: $($entry.FullName)" }
    # 연결이 살아났으므로 "대화 없음" 표시는 함께 걷어낸다.
    $updated = $updated -replace '"transcriptUnavailable"\s*:\s*true\s*,', ''
    $updated = $updated -replace ',\s*"transcriptUnavailable"\s*:\s*true', ''

    [IO.File]::WriteAllText($entry.FullName, $updated, (New-Object Text.UTF8Encoding($false)))
    Write-Host "  복구: $($entry.FullName)" -ForegroundColor Green
    Write-Host "    백업: $($entry.FullName).bak-$stamp" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Claude 앱을 완전히 재시작하면 목록에서 열립니다.' -ForegroundColor Cyan
$global:LASTEXITCODE = 0
