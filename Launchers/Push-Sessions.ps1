#requires -Version 5.1
<#
.SYNOPSIS
  현재 PC의 Claude/Codex 세션을 레포로 내보내고 push 한다 (작업 종료 시 실행).
  세션 JSONL만 복사하며, 인증/DB/개인설정은 .gitignore 로 차단된다.
.NOTES
  기본은 baton(ACTIVE_HOST)을 NONE 으로 풀어 다른 PC가 Pull 할 수 있게 한다.
  -KeepBaton 이면 이 PC가 계속 소유한다.
  실행 중 세션도 append-only JSONL 스냅숏으로 복사하며, commit 전에 마지막 JSON 줄을 검증한다.
#>
[CmdletBinding()]
param(
    [switch]$Force,        # 이전 호출과의 호환성 유지용
    [switch]$ForceOwnership, # 다른 호스트의 baton 소유권까지 명시적으로 무시
    [switch]$KeepBaton,    # baton 을 풀지 않고 이 PC가 계속 소유
    [switch]$CheckOnly     # 현재 PC의 baton 소유권만 확인
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ThisHost = $env:COMPUTERNAME
$LockFile = Join-Path $RepoRoot 'ACTIVE_HOST.txt'

# Machine-local configuration is ignored by Git.
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot
if (-not $Config.SessionDataPushEnabled) {
    throw 'Session push is disabled. Enable it only in your own PRIVATE transport repository.'
}

# 메인 프로젝트뿐 아니라 그 worktree 폴더들까지 한꺼번에 동기화한다.
$ClaudeProjectsSrc = Join-Path $Config.ClaudeHome 'projects'
$ClaudeProjectsDst = Join-Path $RepoRoot 'Claude\projects'
$ProjectPattern    = $Config.ClaudeProjectPattern
$CodexSrc  = Join-Path $Config.CodexHome 'sessions'
$CodexDst  = Join-Path $RepoRoot 'Codex\sessions'

# 1) 원격 baton 최신화 및 소유권 확인
git -C $RepoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'git pull 실패 — 소유권을 확인할 수 없어 Push를 중단합니다.' }

$active = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $active) { $active = 'NONE' }
if ($active -ne $ThisHost -and -not $ForceOwnership)
{
    Write-Warning "baton 소유자는 현재 $active 입니다($ThisHost 아님 — 상대가 이어받았을 수 있음). 막지 않고 진행하며, push 충돌 시 머지로 합류합니다. (주의: 한 세션을 두 PC에서 동시에 잇지 마세요 — 같은 UUID 파일은 머지 충돌 시 이 호스트 것이 우선됩니다.)"
}

if ($CheckOnly)
{
    Write-Host "[OK] baton 소유권 확인: $ThisHost" -ForegroundColor Green
    return
}

# 2) 실행 중 세션은 종료를 요구하지 않고 스냅숏으로 처리한다.
$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'claude|codex' }
if ($running) {
    Write-Warning 'Claude/Codex 실행 중: 현재까지 기록된 append-only JSONL을 스냅숏으로 동기화합니다.'
}

# 3) *.jsonl only. Store Claude folders under path-neutral names so each PC may
#    use a different absolute ProjectRoot.
New-Item -ItemType Directory -Force -Path $ClaudeProjectsDst, $CodexDst | Out-Null
$claudeDirs = @(Get-ChildItem -LiteralPath $ClaudeProjectsSrc -Directory -Filter $ProjectPattern -ErrorAction SilentlyContinue)
foreach ($dir in $claudeDirs) {
    $suffix = $dir.Name.Substring($Config.ClaudeProjectKey.Length)
    $transportName = if ([string]::IsNullOrEmpty($suffix)) { 'primary' } else { "worktree$suffix" }
    $dst = Join-Path $ClaudeProjectsDst $transportName
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    robocopy $dir.FullName $dst *.jsonl /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Claude:$($dir.Name)) 실패 code=$LASTEXITCODE" }
}
if (Test-Path -LiteralPath $CodexSrc) {
    robocopy $CodexSrc $CodexDst *.jsonl /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Codex) 실패 code=$LASTEXITCODE" }
}

# 3b) Claude 데스크톱 앱 대화목록 레지스트리(claude-code-sessions)도 레포로 — 앱에 목록이 뜨게 하는 메타.
#     앱 데이터 경로는 머신마다 다르다(일반설치=Roaming, Store판=Packages\...\LocalCache\Roaming). 존재하는 것만 사용.
$appRegDst  = Join-Path $RepoRoot 'ClaudeApp\claude-code-sessions'
$appRegSrcs = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions')
) | Where-Object { Test-Path -LiteralPath $_ }
if ($appRegSrcs) {
    New-Item -ItemType Directory -Force -Path $appRegDst | Out-Null
    foreach ($src in $appRegSrcs) {
        robocopy $src $appRegDst local_*.json /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy(앱레지스트리) 실패 code=$LASTEXITCODE" }
    }
} else {
    Write-Warning 'Claude 앱 레지스트리(claude-code-sessions)를 못 찾음 — 앱 목록 동기화는 건너뜁니다.'
}

# 3c) Codex 대화목록 인덱스(session_index.jsonl) — 양쪽이 같은 파일에 쓰므로 덮어쓰면 한쪽 소실 → id 기준 union 머지.
$CodexIdxLocal = Join-Path $Config.CodexHome 'session_index.jsonl'
$CodexIdxRepo  = Join-Path $RepoRoot 'Codex\session_index.jsonl'
if (Test-Path -LiteralPath $CodexIdxLocal) {
    & (Join-Path $PSScriptRoot 'Sync-CodexIndex.ps1') -Inputs @($CodexIdxRepo, $CodexIdxLocal) -OutPath $CodexIdxRepo
    & (Join-Path $PSScriptRoot 'Sync-CodexIndex.ps1') -Inputs @($CodexIdxRepo) -OutPath $CodexIdxLocal
}

# 4) 본문 시크릿 검사 — JSONL + 앱 레지스트리(local_*.json) + Codex 인덱스. 실제 값 출력 없이 Push를 차단한다.
$regFiles = @(Get-ChildItem -Path $appRegDst -Filter 'local_*.json' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
$scanPaths = @($ClaudeProjectsDst, $CodexDst) + $regFiles
if (Test-Path -LiteralPath $CodexIdxRepo) { $scanPaths += $CodexIdxRepo }
& (Join-Path $PSScriptRoot 'Test-SessionSecrets.ps1') -Paths $scanPaths

# 5) 이번 복사로 변경된 JSONL의 마지막 비어 있지 않은 줄이 완전한 JSON인지 검증한다.
$changed = @(
    git -C $RepoRoot diff --name-only -- '*.jsonl'
    git -C $RepoRoot ls-files --others --exclude-standard -- '*.jsonl'
) | Sort-Object -Unique

foreach ($relativePath in $changed) {
    $snapshot = Join-Path $RepoRoot $relativePath
    $lastLine = Get-Content -LiteralPath $snapshot -Encoding UTF8 -Tail 8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($lastLine)) {
        throw "빈 JSONL 스냅숏: $relativePath"
    }
    try { $null = $lastLine | ConvertFrom-Json }
    catch { throw "기록 중간에서 잘린 JSONL 스냅숏: $relativePath. 잠시 후 Push를 다시 실행하세요." }
}

# 6) baton 처리
if ($KeepBaton) { $ThisHost | Set-Content -Encoding ASCII $LockFile }
else            { 'NONE'    | Set-Content -Encoding ASCII $LockFile }

# 7) commit & push (성공 확인)
git -C $RepoRoot add -A
git -C $RepoRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {                       # 변경 있을 때만 커밋
    git -C $RepoRoot commit -q -m "push from $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    if ($LASTEXITCODE -ne 0) { throw 'commit 실패.' }
}
$pushed = $false
for ($try = 1; $try -le 3 -and -not $pushed; $try++) {
    git -C $RepoRoot push
    if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
    # 원격이 앞서감(상대가 Push) → 막지 말고 머지로 합류 후 재시도.
    # 세션 jsonl 은 UUID가 달라 합집합으로 머지되고, 충돌나는 단일 파일은 이 호스트 것이 우선(-X ours).
    Write-Warning "원격이 앞서 있어 머지로 합류 후 재시도합니다 (시도 $try/3)."
    git -C $RepoRoot pull --no-rebase --no-edit -X ours
    if ($LASTEXITCODE -ne 0) { throw 'git 머지 실패 — 충돌 파일을 수동 확인하세요(git status).' }
    git -C $RepoRoot add -A
    git -C $RepoRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git -C $RepoRoot commit -q -m "merge push from $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
}
if (-not $pushed) { throw 'git push가 계속 거부됨 — 네트워크/원격 확인 필요.' }

if ($KeepBaton) {
    Write-Host "[OK] Push 완료 ($ThisHost). baton 유지 — 다른 PC는 Pull 시 -Force 필요." -ForegroundColor Yellow
} else {
    Write-Host "[OK] Push 완료 ($ThisHost). baton 해제 — 다른 PC에서 Pull-Sessions 하세요." -ForegroundColor Green
}
$global:LASTEXITCODE = 0
