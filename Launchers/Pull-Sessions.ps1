#requires -Version 5.1
<#
.SYNOPSIS
  레포에서 최신 세션을 받아 이 PC로 병합한다 (작업 시작 전 실행).
  baton(ACTIVE_HOST)을 원격에 먼저 확보·검증한 뒤에만 세션을 복사한다.
.NOTES
  다른 호스트가 baton 을 쥔 채면(=상대가 Push 안 했으면) 중단한다. -Force 로 무시 가능.
#>
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ThisHost = $env:COMPUTERNAME
$LockFile = Join-Path $RepoRoot 'ACTIVE_HOST.txt'

# Machine-local configuration is ignored by Git.
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot

# 전송 단위는 프로젝트가 아니라 앱 인덱스다(Push-Sessions.ps1 와 동일 계약).
# ~/.claude/projects 전체를 폴더 이름 그대로 받는다.
$ClaudeProjectsSrc = Join-Path $RepoRoot 'Claude\projects'
$ClaudeProjectsDst = Join-Path $Config.ClaudeHome 'projects'
$CodexDst  = Join-Path $Config.CodexHome 'sessions'
# 마지막 요약 표시에만 쓰는 ProjectRoot 폴더 경로
$ClaudeDst = Join-Path $ClaudeProjectsDst $Config.ClaudeProjectKey

# 1) 최신 받기
git -C $RepoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'git pull 실패(히스토리 분기 가능). 동시에 양쪽에서 작업했는지 확인하세요.' }

# 2) baton 확인 — 막지 않는다. 다른 호스트가 쥔 채(=상대가 Finish 깜빡)여도 경고만 하고 이어받는다.
$active = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $active) { $active = 'NONE' }
if ($active -ne 'NONE' -and $active -ne $ThisHost) {
    Write-Warning "다른 호스트($active)가 baton 을 쥔 채였습니다. 이어받기는 시도하지만 원격이 분기되면 자동 merge하지 않고 중단합니다."
}

# 3) baton 이어받기. push 거부 시 자동 merge하지 않는다.
$ThisHost | Set-Content -Encoding ASCII $LockFile
git -C $RepoRoot add ACTIVE_HOST.txt
git -C $RepoRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {                       # 스테이지에 변경 있음 = baton 갱신 필요
    git -C $RepoRoot commit -q -m "claim by $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    if ($LASTEXITCODE -ne 0) { throw 'baton commit 실패.' }
}
git -C $RepoRoot push
if ($LASTEXITCODE -ne 0) { throw 'Vault push가 거부됐습니다. 자동 merge하지 않으며 로컬 세션을 변경하지 않습니다.' }

# 4) 앱 인덱스 폴더를 복원한다.
#    primary / worktree* 는 구버전 Push 가 남긴 경로 치환 이름이므로 ProjectRoot 키로
#    되돌려 받는다(읽기 전용 하위호환 — 새로 만들지는 않는다).
New-Item -ItemType Directory -Force -Path $ClaudeProjectsDst, $CodexDst | Out-Null
$claudeDirs = @(Get-ChildItem -LiteralPath $ClaudeProjectsSrc -Directory -ErrorAction SilentlyContinue)
foreach ($dir in $claudeDirs) {
    if ($dir.Name -eq 'primary') {
        $localName = $Config.ClaudeProjectKey
    } elseif ($dir.Name -like 'worktree*') {
        $localName = $Config.ClaudeProjectKey + $dir.Name.Substring('worktree'.Length)
    } else {
        $localName = $dir.Name
    }
    $dst = Join-Path $ClaudeProjectsDst $localName
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    robocopy $dir.FullName $dst *.jsonl /E /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Claude:$($dir.Name)) 실패 code=$LASTEXITCODE" }
}
$codexState = Invoke-CodexStartState -RepoRoot $RepoRoot -Config $Config
Write-Host "  [Codex] Vault Active $($codexState.Active)건, 로컬 활성 $($codexState.Local)건을 확인했습니다." -ForegroundColor DarkCyan

# 4b) Claude 앱 대화목록 레지스트리 복원 — 이 PC의 앱 저장소(존재하는 경로)로. 앱 재시작하면 목록에 뜸.
$appRegSrc = Join-Path $RepoRoot 'ClaudeApp\claude-code-sessions'
if (Test-Path -LiteralPath $appRegSrc) {
    $appRoots = @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    # 레포의 손상된 항목이 이 PC의 멀쩡한 항목을 덮어쓰지 않도록 항목 단위로 머지한다.
    # 삭제 마커를 먼저 내려받아 폐기 선언을 반영한 뒤 머지해야, 지운 대화가 되살아나지 않는다.
    foreach ($root in $appRoots) {
        $d = Join-Path $root 'claude-code-sessions'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Copy-ClaudeDeletionMarkers -Source $appRegSrc -Destination $d | Out-Null
        $tombstones = Get-ClaudeDeletionMarkers $d
        $regStats = Merge-ClaudeAppRegistry -Source $appRegSrc -Destination $d -Tombstones $tombstones
        Write-ClaudeAppRegistryStats -Stats $regStats -Label 'pull'
        # 상대 PC의 삭제를 이 PC 목록에도 반영한다. 복사를 건너뛰는 것만으로는 그 대화를
        # 원래 갖고 있던 PC에서 항목이 살아남는다.
        $localRemoved = Remove-TombstonedLocalEntries -RegistryRoot $d
        if ($localRemoved -gt 0) {
            Write-Host "  [폐기] 상대 PC에서 삭제된 대화 $localRemoved 건을 이 PC 목록에서도 치웠습니다(원문은 보존)." -ForegroundColor DarkCyan
        }
    }
    if ($appRoots) { Write-Host '  (앱 목록: Claude 앱을 완전 재시작하면 대화가 목록에 뜹니다.)' -ForegroundColor Cyan }
}

# 4c) Codex 인덱스는 Invoke-CodexStartState가 현재 로컬 활성 집합으로 제한한다.
& (Join-Path $PSScriptRoot 'Repair-CodexThreadVisibility.ps1') -CodexHome $Config.CodexHome
Write-Host '  (Codex 목록: 호환 버전은 누락 세션 등록을 시도하고, 결과는 로컬 진단 로그에 남깁니다.)' -ForegroundColor Cyan

Write-Host "[OK] Pull 완료 — 세션을 $ThisHost 로 가져왔습니다." -ForegroundColor Green
Write-Host '최근 Claude 세션(UUID = 파일명):' -ForegroundColor Cyan
if (Test-Path -LiteralPath $ClaudeDst) {
    Get-ChildItem $ClaudeDst -Filter *.jsonl |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 5 @{N='UUID';E={$_.BaseName}}, LastWriteTime |
        Format-Table -AutoSize
}
Write-Host "  재개:  claude --resume <UUID>   (반드시 $($Config.ProjectRoot) 에서 실행)"
Write-Host '         codex  resume  <UUID>'
$global:LASTEXITCODE = 0
