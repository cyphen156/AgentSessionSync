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

# 전송 단위는 프로젝트가 아니라 앱 인덱스다. 원본은 이 레포가 아니라 앱 내부 인덱스이고
# 레포는 그걸 옮기는 수단이므로, Codex(sessions/session_index)와 마찬가지로 Claude 쪽도
# ~/.claude/projects 전체를 폴더 이름 그대로 나른다. ProjectRoot 는 전송 범위를 정하지 않는다.
$ClaudeProjectsSrc = Join-Path $Config.ClaudeHome 'projects'
$ClaudeProjectsDst = Join-Path $RepoRoot 'Claude\projects'
$CodexSrc  = Join-Path $Config.CodexHome 'sessions'
$CodexDst  = Join-Path $RepoRoot 'Codex\sessions'
$CodexArchivedSrc = Join-Path $Config.CodexHome 'archived_sessions'
$CodexArchiveDst  = Join-Path $RepoRoot 'Codex\archive'
$CodexProjectsRepo = Join-Path $RepoRoot 'Codex\session_projects.jsonl'

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
    Where-Object { $_.ProcessName -match 'claude|codex|chatgpt' }
if ($running) {
    Write-Warning 'Claude/Codex 실행 중: 현재까지 기록된 append-only JSONL을 스냅숏으로 동기화합니다.'
}

# 3) *.jsonl only. Claude 앱 인덱스의 폴더 이름은 그대로 보존한다.
#    Codex 로컬 앱의 날짜 트리는 건드리지 않고, Vault 사본에만 rollout 내부 origin cwd 키를
#    한 단계 앞에 붙인다. Pull 때 이 축을 제거해 앱의 원래 날짜 트리로 되돌린다.
#    (앱 레지스트리 항목이 cwd 절대경로를 그대로 들고 다니므로, 여기서 이름을 바꾸면
#     오히려 레지스트리가 가리키는 위치와 어긋난다.)
New-Item -ItemType Directory -Force -Path $ClaudeProjectsDst, $CodexDst | Out-Null
$migratedCodex = (Move-CodexLegacyTransportTree -RepoRoot $RepoRoot -TreeRelative 'Codex/sessions') +
                 (Move-CodexLegacyTransportTree -RepoRoot $RepoRoot -TreeRelative 'Codex/archive')
if ($migratedCodex -gt 0) {
    Write-Host "  [layout] Codex 레거시 날짜 경로 $migratedCodex 건을 origin cwd 키 아래로 옮겼습니다." -ForegroundColor DarkCyan
}
$claudeDirs = @(Get-ChildItem -LiteralPath $ClaudeProjectsSrc -Directory -ErrorAction SilentlyContinue)
foreach ($dir in $claudeDirs) {
    $dst = Join-Path $ClaudeProjectsDst $dir.Name
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    robocopy $dir.FullName $dst *.jsonl /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy(Claude:$($dir.Name)) 실패 code=$LASTEXITCODE" }
}
if (Test-Path -LiteralPath $CodexSrc) {
    $copiedCodex = Copy-CodexNativeTreeToTransport -SourceRoot $CodexSrc -DestinationRoot $CodexDst
    Write-Host "  [layout] Codex 활성 세션 $copiedCodex 건을 cwd-key Vault 경로로 투영했습니다." -ForegroundColor DarkCyan
}

# 3a) 한 세션은 한 계층에만 있어야 한다. 두 PC의 보존 창이 다르면 한쪽이 archive 로 내린
#     세션을 아직 들고 있는 쪽이 활성으로 다시 올려, 같은 세션이 양쪽 계층에 남는다.
#     그러면 Pull 결과가 실행 순서에 따라 달라진다. 활성이 이긴다 — 어느 PC든 아직
#     작업 집합에 두고 있다는 뜻이기 때문이다. 내용이 같은 사본을 지우는 것이므로
#     보존되는 대화 수는 변하지 않는다.
$ClaudeArchiveDst = Join-Path $RepoRoot 'Claude\archive'
$dedupedCount = 0
foreach ($dir in @(Get-ChildItem -LiteralPath $ClaudeProjectsDst -Directory -ErrorAction SilentlyContinue)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
        $duplicate = Join-Path (Join-Path $ClaudeArchiveDst $dir.Name) $file.Name
        if (-not (Test-Path -LiteralPath $duplicate)) { continue }
        $relative = "Claude/archive/$($dir.Name)/$($file.Name)"
        if (@(& git -C $RepoRoot ls-files -- $relative)) {
            & git -C $RepoRoot rm -q -- $relative
            if ($LASTEXITCODE -ne 0) { throw "중복 사본 정리 실패: $relative" }
        } else {
            Remove-Item -LiteralPath $duplicate -Force
        }
        $dedupedCount++
    }
}
if ($dedupedCount -gt 0) {
    Write-Host "  [dedupe] 활성/아카이브 양쪽에 있던 세션 $dedupedCount 건의 아카이브 사본을 정리했습니다." -ForegroundColor DarkCyan
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
    # 통짜 복사(last-writer-wins)는 이 PC의 손상된 항목이 레포의 멀쩡한 항목을 덮어쓴다.
    # 항목 단위 보호 머지로 내보낸다.
    foreach ($src in $appRegSrcs) {
        $regStats = Merge-ClaudeAppRegistry -Source $src -Destination $appRegDst
        Write-ClaudeAppRegistryStats -Stats $regStats -Label 'push'
    }

    # 삭제 마커도 함께 운반한다. 이게 없으면 이 PC에서 지운 대화가 상대 PC의 Pull 때 되살아난다.
    $markerIds = @{}
    foreach ($src in $appRegSrcs) {
        Copy-ClaudeDeletionMarkers -Source $src -Destination $appRegDst | Out-Null
        foreach ($id in (Get-ClaudeDeletionMarkers $src).Keys) { $markerIds[$id] = $true }
    }
    # 폐기 선언된 목록 항목은 활성 레지스트리에서 뺀다. 목록 항목은 메타데이터일 뿐이라
    # 따로 아카이브하지 않는다 — 대화 원문은 Claude/projects · Claude/archive 에 보존되고,
    # 항목 자체도 git 히스토리에 남아 있어 되돌릴 수 있다.
    $tombstoned = Remove-TombstonedTransportEntries -RepoRoot $RepoRoot -RegistryDestination $appRegDst -Markers $markerIds
    if ($tombstoned -gt 0) {
        Write-Host "  [폐기] 삭제 선언된 목록 항목 $tombstoned 건을 저장소 활성 목록에서 뺐습니다(원문은 보존)." -ForegroundColor DarkCyan
    }

    # 이 PC 목록에도 반영한다. 머지에서 "복사하지 않음"만으로는, 그 대화를 원래 갖고 있던
    # PC에서 항목이 그대로 남아 삭제가 반영되지 않는다.
    foreach ($src in $appRegSrcs) {
        $localRemoved = Remove-TombstonedLocalEntries -RegistryRoot $src
        if ($localRemoved -gt 0) {
            Write-Host "  [폐기] 이 PC 목록에서 $localRemoved 건을 치웠습니다." -ForegroundColor DarkCyan
        }
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

# 3c-2) 앱에서 이미 보관된 세션은 ~/.codex/sessions 에 없으므로 위 robocopy 로는 올라가지 않는다.
#       저장소 어느 계층에도 없다면 원문이 이 PC에만 있다는 뜻이니 archive 로 직접 올린다.
#       이 경로가 없으면 "보관된 뒤 한 번도 동기화되지 않은 대화"는 영원히 전송되지 않는다.
#       활성으로 되돌리는 것이 아니다 — 보관 상태 그대로 보존만 한다.
$repoKnownCodexIds = @{}
foreach ($key in (Get-CodexRolloutIds $CodexDst).Keys)        { $repoKnownCodexIds[$key] = $true }
foreach ($key in (Get-CodexRolloutIds $CodexArchiveDst).Keys) { $repoKnownCodexIds[$key] = $true }
#       검사는 반드시 복사 '전' 에 로컬 원본을 대상으로 한다. 복사한 뒤에 검사하면 검사가
#       실패했을 때 민감한 원문이 이미 저장소 작업트리에 남는다.
$uploadedArchived = @()
foreach ($file in @(Get-ChildItem -LiteralPath $CodexArchivedSrc -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*.jsonl' })) {
    $sessionId = Get-CodexSessionId $file.Name
    if (-not $sessionId -or $repoKnownCodexIds.ContainsKey($sessionId)) { continue }
    Test-JsonlSnapshotComplete $file.FullName
    & (Join-Path $PSScriptRoot 'Test-SessionSecrets.ps1') -Paths @($file.FullName) | Out-Null
    # Vault 에만 origin cwd 축을 붙이고, 그 아래 날짜 트리는 앱과 동일하게 유지한다.
    $projectKey = Get-CodexTransportProjectKey $file.FullName
    $projectArchive = Join-Path $CodexArchiveDst $projectKey
    $dateDir = if ($file.Name -match '^rollout-(\d{4})-(\d{2})-(\d{2})T') {
        Join-Path (Join-Path (Join-Path $projectArchive $Matches[1]) $Matches[2]) $Matches[3]
    } else { Join-Path $projectArchive 'undated' }
    $target = Join-Path $dateDir $file.Name
    Copy-OpenFileSnapshot -Source $file.FullName -Destination $target
    $uploadedArchived += $target
}
if ($uploadedArchived.Count -gt 0) {
    Write-Host "  [archive] 이 PC에만 있던 보관 세션 $($uploadedArchived.Count) 건을 Codex/archive 로 보존했습니다(활성 복원 아님)." -ForegroundColor DarkCyan
}

# 3d) GitHub 파일당 한도(100MiB) 방어.
#     Codex 세션은 텍스트 반복률이 높으므로 한도에 근접한 JSONL만 gzip 운반물로 교체한다.
#     원본은 로컬 Codex 앱 인덱스에 그대로 두며, Pull 시 원래 JSONL 경로로 복원한다.
#     보관 계층도 같은 한도를 받으므로 함께 훑는다.
$TransportFileLimitBytes = $Config.TransportFileLimitBytes
$oversized = @(@($CodexDst, $CodexArchiveDst) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue
    } | Where-Object { $_.Length -gt $TransportFileLimitBytes })
if ($oversized) {
    $toCompress = @()
    $reused = 0
    foreach ($file in $oversized) {
        $compressed = $file.FullName + '.gz'
        if (Test-CompressedJsonlTransportCurrent -Source $file.FullName -Compressed $compressed) {
            Remove-Item -LiteralPath $file.FullName -Force
            $reused++
            continue
        }
        $toCompress += $file
    }
    if ($reused -gt 0) {
        Write-Host "  [gzip] 변경 없는 대형 Codex 세션 ${reused}개는 기존 압축본을 재사용합니다." -ForegroundColor DarkCyan
    }

    # 압축본은 시크릿 스캐너가 직접 읽을 수 없으므로 원본 운반 사본을 먼저 검사한다.
    if ($toCompress.Count -gt 0) {
        & (Join-Path $PSScriptRoot 'Test-SessionSecrets.ps1') -Paths @($toCompress | ForEach-Object FullName)
        Write-Host "  [gzip] 변경된 대형 Codex 세션 $($toCompress.Count)개를 압축합니다." -ForegroundColor DarkCyan
    }
    foreach ($file in $toCompress) {
        $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
        Test-JsonlSnapshotComplete $file.FullName
        $compressed = $file.FullName + '.gz'
        Compress-JsonlTransportFile -Source $file.FullName -Destination $compressed
        $compressedFile = Get-Item -LiteralPath $compressed
        if ($compressedFile.Length -gt $TransportFileLimitBytes) {
            Remove-Item -LiteralPath $compressed -Force
            throw "gzip 후에도 전송 한도를 넘습니다: $relative ($([math]::Round($compressedFile.Length / 1MB, 1)) MiB)"
        }
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Host ("    {0:N1} MiB -> {1:N1} MiB  {2}.gz" -f ($file.Length / 1MB), ($compressedFile.Length / 1MB), $relative) -ForegroundColor DarkGray
    }
    $global:LASTEXITCODE = 0
}

# 이전에 압축됐던 세션이 예외적으로 한도 아래로 작아졌다면 raw JSONL을 다시 기준으로 삼는다.
foreach ($compressed in @(Get-ChildItem -LiteralPath $CodexDst -Recurse -File -Filter '*.jsonl.gz' -ErrorAction SilentlyContinue)) {
    $raw = $compressed.FullName.Substring(0, $compressed.FullName.Length - '.gz'.Length)
    if ((Test-Path -LiteralPath $raw) -and (Get-Item -LiteralPath $raw).Length -le $TransportFileLimitBytes) {
        Remove-Item -LiteralPath $compressed.FullName -Force
    }
}

# 3e) 보존하되 작업 집합에서는 뺀다. 앱은 자체 보존 기간이 지난 transcript 를 로컬에서
#     정리하는데, 이 저장소가 그걸 계속 되돌려주면 앱 인덱스가 무한히 부푼다.
#     로컬에서 사라진 세션은 지우지 않고 Claude/archive 로 옮긴다. Pull 은 활성 폴더만
#     복원하므로 앱이 보는 표면에서만 빠지고 원문은 영구 보존된다.
#     상대 PC 가 방금 올린 세션을 잘못 내리지 않도록, 최근 ActiveWindowDays 안에 이 저장소에서
#     내용이 바뀐 경로는 건드리지 않는다.
$recentTransportPaths = Get-TransportRecentPaths -RepoRoot $RepoRoot -Days $Config.ActiveWindowDays -PathSpec 'Claude/projects'
$archivedCount = 0
foreach ($dir in @(Get-ChildItem -LiteralPath $ClaudeProjectsDst -Directory -ErrorAction SilentlyContinue)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $ClaudeProjectsSrc $dir.Name) $file.Name)) { continue }
        $relative = "Claude/projects/$($dir.Name)/$($file.Name)"
        if ($recentTransportPaths.ContainsKey($relative)) { continue }
        Move-ToTransportArchive -RepoRoot $RepoRoot -RelativePath $relative `
            -ActiveRoot 'Claude/projects' -ArchiveRoot 'Claude/archive' | Out-Null
        $archivedCount++
    }
}
if ($archivedCount -gt 0) {
    Write-Host "  [archive] 로컬에서 사라진 세션 $archivedCount 건을 Claude/archive 로 옮겼습니다(삭제 아님)." -ForegroundColor DarkCyan
    Write-Host "            되돌리려면: Launchers\Restore-ArchivedSession.ps1 <세션ID 또는 검색어>" -ForegroundColor DarkGray
}

# 3f) Codex 세션 아카이브. 신호가 둘이고, 둘 다 '로컬에 있는가' 와 무관하다.
#       명시적: 로컬 archived_sessions 에 실제 원문이 있음 = 사용자가 앱에서 보관한 것.
#               나이와 무관하게 항상 우선한다.
#       노화:   원문 안의 '마지막 이벤트 timestamp' 가 보존 기간을 넘김.
#
#     로컬 부재는 노화 신호가 아니다. Claude Code 는 자체 보존 기간이 있어 부재가 노화를 뜻하지만
#     Codex 에는 그런 정책이 없다. Codex 에서 파일이 사라지는 건 사용자가 지웠을 때뿐이라, 부재를
#     노화로 읽으면 영구삭제한 대화를 아카이브로 되살린다(9건이 그렇게 잘못 분류됐다).
#     시작일도 근거가 못 된다 — 오래전에 시작해 지금도 이어가는 대화를 노후로 오판한다.
#     mtime·복사 시각·미커밋 git 상태도 호스트마다 달라 쓰지 않는다.
#
#     아카이브는 기억을 지우는 곳이 아니라, 활성 컨텍스트에서만 내리고 원문은 남겨두는 곳이다.
$codexArchivedIds = Get-CodexRolloutIds $CodexArchivedSrc
$codexLocalActive = Get-CodexRolloutIds $CodexSrc
$codexAgeCutoff = (Get-Date).ToUniversalTime().AddDays(-$Config.ActiveWindowDays)
$codexArchivedCount = 0
$codexAgedCount = 0
$codexUndatable = 0
foreach ($file in @(Get-ChildItem -LiteralPath $CodexDst -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' })) {
    $sessionId = Get-CodexSessionId $file.Name
    if (-not $sessionId) { continue }
    $relative = 'Codex/sessions' + $file.FullName.Substring($CodexDst.Length).Replace('\', '/')

    $isExplicit = $codexArchivedIds.ContainsKey($sessionId)
    $isAged = $false
    if (-not $isExplicit) {
        $lastActivity = Get-JsonlLastActivity $file.FullName
        if ($null -eq $lastActivity) { $codexUndatable++ }   # 판정 불가 → 건드리지 않는다
        else { $isAged = $lastActivity -lt $codexAgeCutoff }
    }
    if (-not $isExplicit -and -not $isAged) { continue }

    Move-ToTransportArchive -RepoRoot $RepoRoot -RelativePath $relative `
        -ActiveRoot 'Codex/sessions' -ArchiveRoot 'Codex/archive' | Out-Null

    # 저장소에서만 내리면 이 PC 활성 집합에는 원문이 남아 다음 Push 때 다시 올라오고,
    # 사이드바에도 계속 뜬다. 목적이 활성 컨텍스트 축소이므로 로컬도 같이 내린다(삭제 아님).
    if (-not $isExplicit -and $codexLocalActive.ContainsKey($sessionId)) {
        $localOriginal = $codexLocalActive[$sessionId]
        New-Item -ItemType Directory -Force -Path $CodexArchivedSrc | Out-Null
        $localTarget = Join-Path $CodexArchivedSrc $localOriginal.Name
        if (Test-Path -LiteralPath $localTarget) { Remove-Item -LiteralPath $localOriginal.FullName -Force }
        else { Move-Item -LiteralPath $localOriginal.FullName -Destination $localTarget -Force }
    }
    if ($isExplicit) { $codexArchivedCount++ } else { $codexAgedCount++ }
}
if ($codexUndatable -gt 0) {
    Write-Warning "마지막 활동 시각을 읽지 못한 Codex 세션 $codexUndatable 건은 노화 판정에서 제외했습니다."
}
if ($codexArchivedCount -gt 0) {
    Write-Host "  [archive] 앱에서 보관된 Codex 세션 $codexArchivedCount 건을 Codex/archive 로 옮겼습니다(삭제 아님)." -ForegroundColor DarkCyan
}
if ($codexAgedCount -gt 0) {
    Write-Host "  [archive] 보존 기간($($Config.ActiveWindowDays)일)이 지난 Codex 세션 $codexAgedCount 건을 Codex/archive 로 옮겼습니다(삭제 아님)." -ForegroundColor DarkCyan
}

# 3g) 목록 인덱스를 계층에 맞춘다. 옮기는 것은 '원문이 실제로 archive 계층에 있는' 항목뿐이다.
#     원문이 어디에도 없는 항목(unresolved)은 지우지도, archive_index 로 확정하지도 않는다.
#     이 호스트에 원문이 없다는 사실만으로는 판정할 수 없다 — 상대 PC 에 있을 수 있고, 실제로
#     019fc765 를 그렇게 잘못 지웠다. 경고만 남기고 활성 인덱스에 보류한다.
$CodexArchiveIdxRepo = Join-Path $RepoRoot 'Codex\archive_index.jsonl'
$repoArchivedIds = Get-CodexRolloutIds $CodexArchiveDst
$repoActiveIds   = Get-CodexRolloutIds $CodexDst
$split = Split-CodexSessionIndex -IndexPath $CodexIdxRepo -ActiveIds $repoActiveIds -ArchivedIds $repoArchivedIds
if ($split.Archived.Count -gt 0) {
    $archiveLines = @()
    if (Test-Path -LiteralPath $CodexArchiveIdxRepo) {
        $archiveLines = @(Get-Content -LiteralPath $CodexArchiveIdxRepo -Encoding UTF8 | Where-Object { $_.Trim() })
    }
    $seen = @{}
    $merged = @()
    foreach ($line in ($archiveLines + $split.Archived)) {
        if ($line -match '"id"\s*:\s*"([^"]+)"') { if ($seen.ContainsKey($Matches[1])) { continue }; $seen[$Matches[1]] = $true }
        $merged += $line
    }
    Write-CodexIndexLines -Path $CodexArchiveIdxRepo -Lines $merged
}
# unresolved 는 활성 인덱스에 그대로 둔다(자동 판단 금지).
$retainedActive = @($split.Active + $split.Orphan)
if ($split.Archived.Count -gt 0) {
    Write-CodexIndexLines -Path $CodexIdxRepo -Lines $retainedActive
    Write-CodexIndexLines -Path $CodexIdxLocal -Lines $retainedActive
    Write-Host ("  [archive] 목록 인덱스: 활성 {0} / 보관 이관 {1}" -f $split.Active.Count, $split.Archived.Count) -ForegroundColor DarkCyan
}
if ($split.Orphan.Count -gt 0) {
    Write-Warning "원문을 찾지 못한 목록 항목 $($split.Orphan.Count) 건은 판정을 보류했습니다(자동 삭제·자동 아카이브 안 함):"
    foreach ($line in $split.Orphan) {
        $unresolvedId = if ($line -match '"id"\s*:\s*"([^"]+)"') { $Matches[1] } else { '<id 없음>' }
        $unresolvedTitle = if ($line -match '"thread_name"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
        Write-Warning ("  {0}  {1}" -f $unresolvedId, $unresolvedTitle)
    }
    Write-Warning '  상대 PC 에 원문이 있을 수 있습니다. 처리하려면 명시적으로 지시해 주세요.'
}

# 4) 본문 시크릿 검사 — JSONL + 앱 레지스트리(local_*.json) + Codex 인덱스. 실제 값 출력 없이 Push를 차단한다.
$regFiles = @(Get-ChildItem -Path $appRegDst -Filter 'local_*.json' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
$scanPaths = @($ClaudeProjectsDst, $CodexDst) + $regFiles
# 보관 계층도 저장소에 올라가는 내용이므로 검사 범위에 포함한다.
foreach ($archiveScanRoot in @((Join-Path $RepoRoot 'Claude\archive'), $CodexArchiveDst)) {
    if (Test-Path -LiteralPath $archiveScanRoot) { $scanPaths += $archiveScanRoot }
}
if (Test-Path -LiteralPath $CodexIdxRepo) { $scanPaths += $CodexIdxRepo }
if (Test-Path -LiteralPath $CodexArchiveIdxRepo) { $scanPaths += $CodexArchiveIdxRepo }
if (Test-Path -LiteralPath $CodexProjectsRepo) { $scanPaths += $CodexProjectsRepo }
& (Join-Path $PSScriptRoot 'Test-SessionSecrets.ps1') -Paths $scanPaths

# 5) 이번 복사로 변경된 JSONL의 마지막 비어 있지 않은 줄이 완전한 JSON인지 검증한다.
$changed = @(
    git -C $RepoRoot diff --name-only -- '*.jsonl'
    git -C $RepoRoot ls-files --others --exclude-standard -- '*.jsonl'
) | Sort-Object -Unique

foreach ($relativePath in $changed) {
    $snapshot = Join-Path $RepoRoot $relativePath
    if (-not (Test-Path -LiteralPath $snapshot)) { continue }
    if ([string]::Equals($relativePath.Replace('\', '/'), 'Codex/session_projects.jsonl', [StringComparison]::OrdinalIgnoreCase) -and
        (Get-Item -LiteralPath $snapshot).Length -eq 0) { continue }
    Test-JsonlSnapshotComplete $snapshot
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
