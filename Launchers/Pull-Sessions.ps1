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
$Config = Get-AgentSessionSyncConfig $RepoRoot

# 전송 단위는 프로젝트가 아니라 앱 인덱스다(Push-Sessions.ps1 와 동일 계약).
# ~/.claude/projects 전체를 폴더 이름 그대로 받는다.
$ClaudeProjectsSrc = Join-Path $RepoRoot 'Claude\projects'
$ClaudeProjectsDst = Join-Path $Config.ClaudeHome 'projects'
$CodexSrc  = Join-Path $RepoRoot 'Codex\sessions'
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
    Write-Warning "다른 호스트($active)가 baton 을 쥔 채였습니다(상대가 Finish 안 함). 막지 않고 이어받습니다. 상대의 미Push 작업은 그 PC에만 남아 있을 수 있고, 나중에 그쪽에서 Finish하면 git 머지로 합쳐집니다(세션은 UUID가 달라 합집합)."
}

# 3) baton 이어받기 — push 거부 시 막지 말고 머지로 합류(reconcile)한다.
$ThisHost | Set-Content -Encoding ASCII $LockFile
git -C $RepoRoot add ACTIVE_HOST.txt
git -C $RepoRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {                       # 스테이지에 변경 있음 = baton 갱신 필요
    git -C $RepoRoot commit -q -m "claim by $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    if ($LASTEXITCODE -ne 0) { throw 'baton commit 실패.' }
    $pushed = $false
    for ($try = 1; $try -le 3 -and -not $pushed; $try++) {
        git -C $RepoRoot push
        if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
        # 원격이 앞서감(상대가 Push) → 막지 말고 머지로 합류.
        # 세션 jsonl 은 UUID가 달라 충돌 없이 합쳐지고, 충돌나는 단일 파일(ACTIVE_HOST)은 이 호스트로 확정(-X ours).
        Write-Warning "원격이 앞서 있어 머지로 합류합니다 (시도 $try/3)."
        git -C $RepoRoot pull --no-rebase --no-edit -X ours
        if ($LASTEXITCODE -ne 0) { throw 'git 머지 실패 — 충돌 파일을 수동 확인하세요(git status).' }
        $ThisHost | Set-Content -Encoding ASCII $LockFile
        git -C $RepoRoot add ACTIVE_HOST.txt
        git -C $RepoRoot diff --cached --quiet
        if ($LASTEXITCODE -ne 0) { git -C $RepoRoot commit -q -m "claim(reconcile) by $ThisHost" }
    }
    if (-not $pushed) { Write-Warning 'baton push가 계속 거부됨 — 네트워크/원격 확인 필요. 로컬 세션 복사는 계속 진행합니다.' }
}

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
if (Test-Path -LiteralPath $CodexSrc) {
    # Vault 의 첫 축은 rollout 원문의 origin cwd 키다. 로컬 Codex 앱은 이 축을 모르므로
    # 제거하고 원래 YYYY/MM/DD 트리로 복원한다. 날짜로 바로 시작하는 구 경로도 읽는다.
    $codexRestore = Copy-CodexTransportTreeToNative -SourceRoot $CodexSrc -DestinationRoot $CodexDst
    if ($codexRestore.Raw -gt 0) {
        Write-Host "  [layout] cwd-key Vault에서 Codex JSONL $($codexRestore.Raw)개를 앱 날짜 트리로 복원했습니다." -ForegroundColor DarkCyan
    }
    if ($codexRestore.Expanded -gt 0) {
        Write-Host "  [gzip] 압축 운반된 Codex 세션 $($codexRestore.Expanded)개를 JSONL로 복원했습니다." -ForegroundColor DarkCyan
    }
}

# Codex/archive 는 복원하지 않는다(위 robocopy 는 Codex/sessions 만 본다). 다만 상대 PC 가
# 보관 처리한 세션이 이 PC 작업 집합에 아직 있으면 내려줘야 보관이 양쪽에서 성립한다.
# 지우지 않고 앱이 쓰는 archived_sessions 로 옮긴다.
$CodexArchiveSrc  = Join-Path $RepoRoot 'Codex\archive'
$CodexArchivedDst = Join-Path $Config.CodexHome 'archived_sessions'
if (Test-Path -LiteralPath $CodexArchiveSrc) {
    $archivedIds = Get-CodexRolloutIds $CodexArchiveSrc
    $demotedCodex = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $CodexDst -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
        $sessionId = Get-CodexSessionId $file.Name
        if (-not $sessionId -or -not $archivedIds.ContainsKey($sessionId)) { continue }
        New-Item -ItemType Directory -Force -Path $CodexArchivedDst | Out-Null
        $target = Join-Path $CodexArchivedDst $file.Name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $file.FullName -Force }
        else { Move-Item -LiteralPath $file.FullName -Destination $target -Force }
        $demotedCodex++
    }
    if ($demotedCodex -gt 0) {
        Write-Host "  [archive] 보관 처리된 Codex 세션 $demotedCodex 건을 이 PC 작업 집합에서 내렸습니다(archived_sessions 로 이동)." -ForegroundColor DarkCyan
    }
}

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

# 4c) Codex 대화목록 인덱스 union 복원 → 로컬 (덮어쓰지 않고 양쪽 항목 합집합)
$CodexIdxLocal = Join-Path $Config.CodexHome 'session_index.jsonl'
$CodexIdxRepo  = Join-Path $RepoRoot 'Codex\session_index.jsonl'
if (Test-Path -LiteralPath $CodexIdxRepo) {
    & (Join-Path $PSScriptRoot 'Sync-CodexIndex.ps1') -Inputs @($CodexIdxRepo, $CodexIdxLocal) -OutPath $CodexIdxLocal
}
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
