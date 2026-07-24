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

# 메인 프로젝트뿐 아니라 그 worktree 폴더들까지 한꺼번에 받는다.
$ClaudeProjectsSrc = Join-Path $RepoRoot 'Claude\projects'
$ClaudeProjectsDst = Join-Path $Config.ClaudeHome 'projects'
$ProjectPattern    = $Config.ClaudeProjectPattern
$CodexSrc  = Join-Path $RepoRoot 'Codex\sessions'
$CodexDst  = Join-Path $Config.CodexHome 'sessions'
# 목록 표시에 쓰는 메인 폴더 경로(패턴에서 끝의 * 제거)
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

# 4) Restore path-neutral Claude folders using this PC's derived project key.
New-Item -ItemType Directory -Force -Path $ClaudeProjectsDst, $CodexDst | Out-Null
$claudeDirs = @(Get-ChildItem -LiteralPath $ClaudeProjectsSrc -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'primary' -or $_.Name -like 'worktree*' })
foreach ($dir in $claudeDirs) {
    $localName = if ($dir.Name -eq 'primary') {
        $Config.ClaudeProjectKey
    } else {
        $Config.ClaudeProjectKey + $dir.Name.Substring('worktree'.Length)
    }
    $dst = Join-Path $ClaudeProjectsDst $localName
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    robocopy $dir.FullName $dst *.jsonl /E /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Claude:$($dir.Name)) 실패 code=$LASTEXITCODE" }
}
if (Test-Path -LiteralPath $CodexSrc) {
    robocopy $CodexSrc $CodexDst *.jsonl /E /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Codex) 실패 code=$LASTEXITCODE" }
}

# 4b) Claude 앱 대화목록 레지스트리 복원 — 이 PC의 앱 저장소(존재하는 경로)로. 앱 재시작하면 목록에 뜸.
$appRegSrc = Join-Path $RepoRoot 'ClaudeApp\claude-code-sessions'
if (Test-Path -LiteralPath $appRegSrc) {
    $appRoots = @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    foreach ($root in $appRoots) {
        $d = Join-Path $root 'claude-code-sessions'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        robocopy $appRegSrc $d local_*.json /E /XO /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy(앱레지스트리 복원) 실패 code=$LASTEXITCODE" }
    }
    if ($appRoots) { Write-Host '  (앱 목록: Claude 앱을 완전 재시작하면 대화가 목록에 뜹니다.)' -ForegroundColor Cyan }
}

# 4c) Codex 대화목록 인덱스 union 복원 → 로컬 (덮어쓰지 않고 양쪽 항목 합집합)
$CodexIdxLocal = Join-Path $Config.CodexHome 'session_index.jsonl'
$CodexIdxRepo  = Join-Path $RepoRoot 'Codex\session_index.jsonl'
if (Test-Path -LiteralPath $CodexIdxRepo) {
    & (Join-Path $PSScriptRoot 'Sync-CodexIndex.ps1') -Inputs @($CodexIdxRepo, $CodexIdxLocal) -OutPath $CodexIdxLocal
    & (Join-Path $PSScriptRoot 'Repair-CodexThreadVisibility.ps1')
    Write-Host '  (Codex 목록: rollout 복원 후 로컬 thread DB 스캔·복구를 요청했습니다.)' -ForegroundColor Cyan
}

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
