#requires -Version 5.1
<#
.SYNOPSIS
  앱이 transcript 를 훑어 자동으로 만들어 둔 목록 항목을 걷어낸다.
.DESCRIPTION
  앱은 ~/.claude/projects 를 스캔해 CLI 로 생긴 transcript 마다 목록 항목을 만든다.
  그렇게 만들어진 항목은 실제 대화 항목과 두 가지로 구분된다.

    - sessionId 와 cliSessionId 가 같다 (앱이 transcript ID 를 그대로 항목 ID 로 쓴다)
    - completedTurns 가 0 이다 (앱에서 주고받은 적이 없다)

  한 번의 스캔이 수십 건을 한꺼번에 만들기 때문에 같은 제목이 사이드바에 여러 번 뜬다.
  실제 대화는 항상 sessionId 와 cliSessionId 가 다르고 completedTurns 가 1 이상이라,
  두 부류는 겹치지 않는다.

  걷어내는 것은 목록 항목뿐이다. 대화 원문(transcript)은 건드리지 않으므로 언제든
  다시 열 수 있고, 앱의 삭제 마커를 남겨 다른 PC 에도 같은 정리가 전파된다.

  Claude 앱이 실행 중이면 종료 시점에 메모리에 있던 항목을 다시 쓴다. 앱을 완전히
  종료한 뒤 실행해야 결과가 남는다.
.PARAMETER Apply
  실제로 제거한다. 없으면 대상만 보여준다.
.EXAMPLE
  .\Launchers\Remove-AdoptedSessionEntries.ps1
  .\Launchers\Remove-AdoptedSessionEntries.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $Force
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')

if ($Apply -and (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) -and -not $Force) {
    Write-Warning 'Claude 앱이 실행 중입니다. 종료 시 앱이 항목을 다시 써서 정리가 되돌아갑니다.'
    Write-Warning '앱을 완전히 종료한 뒤 다시 실행하세요(그래도 진행하려면 -Force).'
    $global:LASTEXITCODE = 1
    return
}

$registryRoots = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions')
) | Where-Object { Test-Path -LiteralPath $_ }
if (-not $registryRoots) { throw '앱 목록 레지스트리를 찾지 못했습니다.' }

# 일반 설치 경로와 Store 패키지 경로가 같은 저장소를 가리키는 머신이 있다. 항목 단위로
# 묶어 두 번 세지 않게 하고, 실제 제거는 발견한 모든 경로에 대해 수행한다.
$byId = @{}
$keptIds = @{}
foreach ($root in $registryRoots) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'local_*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        $appId = $file.BaseName -replace '^local_', ''
        $text = [IO.File]::ReadAllText((ConvertTo-ExtendedPath $file.FullName), [Text.Encoding]::UTF8)
        $cli = if ($text -match '"cliSessionId"\s*:\s*"([^"]+)"') { $Matches[1] } else { $null }
        $turns = if ($text -match '"completedTurns"\s*:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        if ($cli -ne $appId -or $turns -ne 0) { $keptIds[$appId] = $true; continue }
        if (-not $byId.ContainsKey($appId)) {
            $byId[$appId] = [pscustomobject]@{
                AppId = $appId
                Title = if ($text -match '"title"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
                Paths = New-Object System.Collections.ArrayList
            }
        }
        [void]$byId[$appId].Paths.Add($file.FullName)
    }
}
$targets = @($byId.Values)

Write-Host ("자동 편입 항목 {0}건 / 실제 대화 {1}건" -f $targets.Count, $keptIds.Count) -ForegroundColor Cyan
if (-not $targets) { $global:LASTEXITCODE = 0; return }

if (-not $Apply) {
    $targets | Group-Object Title | Sort-Object Count -Descending |
        Select-Object @{N = '제목'; E = { $_.Name } }, @{N = '건수'; E = { $_.Count } } -First 15 |
        Format-Table -AutoSize
    Write-Host '실제로 제거하려면 -Apply 를 붙이세요. 대화 원문은 지워지지 않습니다.' -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    return
}

$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
$removed = 0
foreach ($target in $targets) {
    foreach ($path in $target.Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        # 삭제 마커를 먼저 남긴다. 이것이 없으면 다음 Pull 에서 그대로 되살아난다.
        $marker = Join-Path (Split-Path -Parent $path) "deleted_$($target.AppId)"
        if (-not (Test-Path -LiteralPath $marker)) {
            [IO.File]::WriteAllText((ConvertTo-ExtendedPath $marker), $stamp, (New-Object Text.UTF8Encoding($false)))
        }
        Remove-Item -LiteralPath $path -Force
    }
    $removed++
}

Write-Host "목록 항목 $removed 건을 제거했습니다(대화 원문은 그대로)." -ForegroundColor Green
Write-Host '다른 PC 에도 반영하려면 Push-Sessions.ps1 또는 All-Finish 를 실행하세요.' -ForegroundColor Cyan
$global:LASTEXITCODE = 0
