#requires -Version 5.1
<#
.SYNOPSIS
  archive 로 내려간 세션을 다시 활성 폴더로 되돌린다.
.DESCRIPTION
  Push-Sessions.ps1 은 로컬 앱 인덱스에서 사라진 세션을 지우지 않고 Claude/archive 로
  옮긴다. 이 스크립트는 그 반대 방향이다. 설계 기준을 다시 검토할 때처럼 예전 대화가
  필요해지면 여기로 꺼낸 뒤 Pull-Sessions.ps1 을 돌리면 앱 목록에 다시 뜬다.

  아카이브가 무덤이 되지 않으려면 꺼내는 경로가 있어야 한다. 이것이 그 경로다.
.PARAMETER Query
  세션 ID(파일명) 일부 또는 검색어. 생략하면 아카이브 목록만 보여준다.
.PARAMETER All
  -Query 에 걸린 항목을 확인 없이 전부 되돌린다.
.EXAMPLE
  .\Launchers\Restore-ArchivedSession.ps1
  .\Launchers\Restore-ArchivedSession.ps1 4d02bd27
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string] $Query = '',
    [switch] $All
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')

$ClaudeArchiveRoot = Join-Path $RepoRoot 'Claude\archive'
$CodexArchiveRoot  = Join-Path $RepoRoot 'Codex\archive'

$entries = @()
if (Test-Path -LiteralPath $ClaudeArchiveRoot) {
    $entries += @(Get-ChildItem -LiteralPath $ClaudeArchiveRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $folder = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Agent = 'Claude'
                Folder = $folder
                SessionId = $_.BaseName
                SizeMB = [math]::Round($_.Length / 1MB, 2)
                Relative = "Claude/archive/$folder/$($_.Name)"
                ActiveRoot = 'Claude/archive'
                TargetRoot = 'Claude/projects'
            }
        }
    })
}
# Codex 는 날짜 트리라 폴더 한 겹이 아니라 재귀로 훑는다.
if (Test-Path -LiteralPath $CodexArchiveRoot) {
    $codexRootFull = (Resolve-Path -LiteralPath $CodexArchiveRoot).Path.TrimEnd('\')
    $entries += @(Get-ChildItem -LiteralPath $codexRootFull -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' } | ForEach-Object {
            $sub = $_.FullName.Substring($codexRootFull.Length).TrimStart('\').Replace('\', '/')
            [pscustomobject]@{
                Agent = 'Codex'
                Folder = (Split-Path -Parent $sub) -replace '\\', '/'
                SessionId = (Get-CodexSessionId $_.Name)
                SizeMB = [math]::Round($_.Length / 1MB, 2)
                Relative = "Codex/archive/$sub"
                ActiveRoot = 'Codex/archive'
                TargetRoot = 'Codex/sessions'
            }
        })
}

if (-not $entries) {
    Write-Host '아카이브가 비어 있습니다.' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    return
}

if (-not $Query) {
    Write-Host "아카이브된 세션 $($entries.Count)건:" -ForegroundColor Cyan
    $entries | Sort-Object Agent, Folder, SessionId | Format-Table Agent, Folder, SessionId, SizeMB -AutoSize
    Write-Host '되돌리려면: Restore-ArchivedSession.ps1 <세션ID 또는 일부>' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    return
}

$matched = @($entries | Where-Object { $_.SessionId -like "*$Query*" -or $_.Folder -like "*$Query*" })
if (-not $matched) {
    Write-Warning "'$Query' 에 해당하는 아카이브 세션이 없습니다."
    $global:LASTEXITCODE = 1
    return
}

Write-Host "되돌릴 대상 $($matched.Count)건:" -ForegroundColor Cyan
$matched | Format-Table Agent, Folder, SessionId, SizeMB -AutoSize

if ($matched.Count -gt 1 -and -not $All) {
    Write-Warning '여러 건이 걸렸습니다. 검색어를 좁히거나 -All 을 지정하세요.'
    $global:LASTEXITCODE = 1
    return
}

foreach ($item in $matched) {
    $target = $item.TargetRoot + $item.Relative.Substring($item.ActiveRoot.Length)
    $targetFull = Join-Path $RepoRoot ($target.Replace('/', '\'))
    $targetDir = Split-Path -Parent $targetFull
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    if (Test-Path -LiteralPath $targetFull) {
        Write-Warning "이미 활성 폴더에 있습니다: $target"
        continue
    }
    if (@(& git -C $RepoRoot ls-files -- $item.Relative)) {
        & git -C $RepoRoot mv -- $item.Relative $target
        if ($LASTEXITCODE -ne 0) { throw "복원 실패: $($item.Relative)" }
    } else {
        Move-Item -LiteralPath (Join-Path $RepoRoot ($item.Relative.Replace('/', '\'))) -Destination $targetFull -Force
    }
    Write-Host "  복원: $($item.SessionId)" -ForegroundColor Green
}

Write-Host ''
Write-Host '활성 폴더로 되돌렸습니다. 이 PC에 내려받으려면 Pull-Sessions.ps1 을 실행하세요.' -ForegroundColor Cyan
Write-Host '앱 목록에도 다시 띄우려면 해당 대화의 deleted_ 마커를 지워야 할 수 있습니다.' -ForegroundColor DarkGray
$global:LASTEXITCODE = 0
