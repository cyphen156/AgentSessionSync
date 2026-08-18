#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& git -C $repoRoot -c "safe.directory=$($repoRoot.Replace('\', '/'))" rev-parse --verify HEAD 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Commit this repository before running the integration test.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AgentSessionSync-Test-" + [guid]::NewGuid().ToString('N'))
$remote = Join-Path $testRoot 'remote.git'
$hostA = Join-Path $testRoot 'HostA'
$hostB = Join-Path $testRoot 'HostB'
$profileA = Join-Path $testRoot 'ProfileA'
$profileB = Join-Path $testRoot 'ProfileB'
$projectA = Join-Path $testRoot 'Projects\DemoA'
# 설정(ProjectRoot)에 등록되지 않은 프로젝트. 전송 단위가 앱 인덱스이므로 이것도 따라가야 한다.
$projectExtra = Join-Path $testRoot 'Projects\Unregistered'
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA

function Write-TestConfig([string]$Repo, [string]$Project, [string]$Profile) {
    $p = $Project.Replace("'", "''")
    $c = (Join-Path $Profile '.claude').Replace("'", "''")
    $x = (Join-Path $Profile '.codex').Replace("'", "''")
    $body = "@{`n ProjectRoot='$p'`n SyncProjectGit=`$false`n IncludeClaudeWorktrees=`$true`n ClaudeHome='$c'`n CodexHome='$x'`n TransportFileLimitBytes=1024`n SessionDataPushEnabled=`$true`n}`n"
    [IO.File]::WriteAllText((Join-Path $Repo 'AgentSessionSync.config.psd1'), $body, (New-Object Text.UTF8Encoding($true)))
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot, $projectA, $projectExtra | Out-Null
    $env:APPDATA = Join-Path $profileA 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileA 'AppData\Local'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
    & git clone --bare $repoRoot $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create temporary bare remote.' }
    & git -c core.longpaths=true clone $remote $hostA | Out-Null
    & git -c core.longpaths=true clone $remote $hostB | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create test clones.' }
    & git -C $hostA config core.longpaths true
    & git -C $hostB config core.longpaths true

    # 통합 테스트의 작은 전송 한도가 실제 Vault의 기존 세션까지 압축 대상으로 잡지 않도록
    # 임시 송신 저장소의 운반 데이터만 비우고 테스트 픽스처로 새 기준을 만든다.
    # 공개 템플릿처럼 운반 데이터가 애초에 없는 저장소에서는 지울 것이 없다. 그 경우
    # commit 은 "nothing to commit" 으로 실패하므로, 스테이지에 변화가 있을 때만 커밋한다.
    & git -C $hostA rm -r -q --ignore-unmatch -- Claude/projects Claude/archive Codex/sessions Codex/archive Codex/session_index.jsonl Codex/archive_index.jsonl Codex/session_projects.jsonl ClaudeApp/claude-code-sessions
    & git -C $hostA diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        & git -C $hostA commit -q -m 'prepare isolated transport fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to isolate temporary transport fixture.' }
        & git -C $hostA push | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to publish temporary transport fixture baseline.' }
    }

    # 두 호스트가 같은 ProjectRoot 를 쓰는 것이 실제 배치다. 앱 레지스트리 항목이 cwd
    # 절대경로를 그대로 들고 다니므로, 호스트마다 경로가 다르면 이름을 치환해도 어차피
    # 레지스트리 쪽이 깨진다. 전송은 폴더 이름을 보존한다.
    Write-TestConfig $hostA $projectA $profileA
    Write-TestConfig $hostB $projectA $profileB
    . (Join-Path $repoRoot 'Launchers\AgentSessionSync.Common.ps1')
    $keyA = ConvertTo-ClaudeProjectKey $projectA
    $keyExtra = ConvertTo-ClaudeProjectKey $projectExtra
    $codexOrigin = 'C:\Projects\DemoA'
    $codexKey = ConvertTo-ClaudeProjectKey $codexOrigin
    $codexMetaA = '{"timestamp":"2026-06-20T09:00:00.000Z","type":"session_meta","payload":{"cli_version":"99.0.0","cwd":' + ($codexOrigin | ConvertTo-Json -Compress) + '}}'

    $claudeA = Join-Path $profileA ".claude\projects\$keyA"
    $claudeExtra = Join-Path $profileA ".claude\projects\$keyExtra"
    $codexA = Join-Path $profileA '.codex\sessions\2026\06\20'
    New-Item -ItemType Directory -Force -Path $claudeA, $claudeExtra, $codexA | Out-Null
    '{"type":"user","message":"portable claude test"}' | Set-Content -LiteralPath (Join-Path $claudeA 'claude-test.jsonl') -Encoding UTF8
    '{"type":"user","message":"unregistered project test"}' | Set-Content -LiteralPath (Join-Path $claudeExtra 'extra-test.jsonl') -Encoding UTF8
    # 합성 rollout 에도 실제와 같은 session_meta.cli_version 을 넣는다. 이 값이 없으면
    # Repair-CodexThreadVisibility 의 버전 게이트가 건너뛰어지고, 합성 프로필에 실제 Codex
    # app-server 를 붙이려다 진단이 'failed' 로 끝난다. 호스트에 설치된 CLI 버전과 무관하게
    # 게이트가 결정적으로 걸리도록 도달 불가능한 버전을 박아 harness 를 밀폐한다.
    $codexFixtureVersion = '99.0.0'
    ('{"timestamp":"2026-06-20T09:00:00.000Z","type":"session_meta","payload":{"cli_version":"' + $codexFixtureVersion + '","cwd":' + ($codexOrigin | ConvertTo-Json -Compress) + '}}') |
        Set-Content -LiteralPath (Join-Path $codexA 'rollout-test.jsonl') -Encoding UTF8
    '{"type":"event_msg","payload":{"type":"user_message","message":"portable codex test"}}' | Add-Content -LiteralPath (Join-Path $codexA 'rollout-test.jsonl') -Encoding UTF8
    $largeCodexSource = Join-Path $codexA 'rollout-large-test.jsonl'
    $largeCodexPayload = '{"type":"event_msg","payload":{"type":"user_message","message":"' + ('compressible-' * 512) + '"}}'
    [IO.File]::WriteAllText($largeCodexSource, $codexMetaA + [Environment]::NewLine + $largeCodexPayload + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $largeCodexHash = (Get-FileHash -LiteralPath $largeCodexSource -Algorithm SHA256).Hash

    # 앱 목록 항목: HostA 는 트랜스크립트와 연결된(=cliSessionId 보유) 정상 항목을 가진다.
    $regRelative = 'org-1\account-1'
    $regA = Join-Path $env:APPDATA "Claude\claude-code-sessions\$regRelative"
    New-Item -ItemType Directory -Force -Path $regA | Out-Null
    '{"sessionId":"local_bound","cliSessionId":"claude-test","cwd":"X","title":"bound entry"}' |
        Set-Content -LiteralPath (Join-Path $regA 'local_bound.json') -Encoding UTF8

    # 폐기 선언된 항목: 앱이 대화를 지우면 남기는 deleted_ 마커를 함께 둔다.
    '{"sessionId":"local_tomb","cliSessionId":"gone","cwd":"X","title":"tombstoned entry"}' |
        Set-Content -LiteralPath (Join-Path $regA 'local_tomb.json') -Encoding UTF8
    'deleted' | Set-Content -LiteralPath (Join-Path $regA 'deleted_tomb') -Encoding UTF8

    # 저장소 활성 폴더에만 있고 로컬에는 없는 세션 = 앱이 보존 기간 뒤 정리한 것.
    # Push 는 이것을 지우지 않고 archive 로 옮겨야 한다.
    $agedDir = Join-Path $hostA "Claude\projects\$keyA"
    New-Item -ItemType Directory -Force -Path $agedDir | Out-Null
    '{"type":"user","message":"aged out locally"}' |
        Set-Content -LiteralPath (Join-Path $agedDir 'aged-test.jsonl') -Encoding UTF8

    # Codex 쪽 보관 계약: 앱이 대화를 보관하면 archived_sessions 로 옮겨진다. 그 신호를 받은
    # 세션은 저장소 활성에서 Codex/archive 로 내려가고, 상대 PC 로 복원되지 않아야 한다.
    $codexArchivedId = '019f0000-0000-7000-8000-00000000abcd'
    $codexArchivedName = "rollout-2026-07-26T11-51-08-$codexArchivedId.jsonl"
    $codexRepoDir = Join-Path $hostA 'Codex\sessions\2026\07\26'
    $codexArchivedLocal = Join-Path $profileA '.codex\archived_sessions'
    New-Item -ItemType Directory -Force -Path $codexRepoDir, $codexArchivedLocal | Out-Null
    ($codexMetaA + "`n" + '{"type":"event_msg","payload":{"type":"user_message","message":"archived codex session"}}') |
        Set-Content -LiteralPath (Join-Path $codexRepoDir $codexArchivedName) -Encoding UTF8
    ($codexMetaA + "`n" + '{"type":"event_msg","payload":{"type":"user_message","message":"archived codex session"}}') |
        Set-Content -LiteralPath (Join-Path $codexArchivedLocal $codexArchivedName) -Encoding UTF8

    # 보관 원문이 이 호스트에만 있는 경우: 저장소 어느 계층에도 없으므로 archive 로 직접 올라가야
    # 한다. 이 경로가 없으면 그 대화는 한 대의 PC 에만 남는다.
    $codexUploadId = '019f0000-0000-7000-8000-0000000aabb0'
    $codexUploadName = "rollout-2026-07-20T09-00-00-$codexUploadId.jsonl"
    ($codexMetaA + "`n" + '{"type":"event_msg","timestamp":"2026-07-20T09:00:00.000Z","payload":{"type":"user_message","message":"local archive only"}}') |
        Set-Content -LiteralPath (Join-Path $codexArchivedLocal $codexUploadName) -Encoding UTF8

    # 마지막 활동이 보존 기간 밖인 세션은 노화로 내려가고, 최근 활동이 있으면 남아야 한다.
    # 파일명 시작일은 둘 다 오래됐으므로 시작일 기준이면 구분되지 않는다.
    $codexAgedId  = '019f0000-0000-7000-8000-0000000a6ed0'
    $codexFreshId = '019f0000-0000-7000-8000-0000000f2e50'
    $codexAgedName  = "rollout-2026-05-01T09-00-00-$codexAgedId.jsonl"
    $codexFreshName = "rollout-2026-05-01T09-00-00-$codexFreshId.jsonl"
    $codexAgedRepoDir = Join-Path $hostA 'Codex\sessions\2026\05\01'
    $codexLocalActive = Join-Path $profileA '.codex\sessions\2026\05\01'
    New-Item -ItemType Directory -Force -Path $codexAgedRepoDir, $codexLocalActive | Out-Null
    $agedLine  = $codexMetaA + "`n" + '{"type":"event_msg","timestamp":"2026-05-02T09:00:00.000Z","payload":{"type":"user_message","message":"aged"}}'
    $freshLine = $codexMetaA + "`n" + '{"type":"event_msg","timestamp":"2026-05-01T09:00:00.000Z","payload":{"type":"user_message","message":"start"}}' + "`n" +
                 '{"type":"event_msg","timestamp":"' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '","payload":{"type":"user_message","message":"still going"}}'
    foreach ($pair in @(@($codexAgedName, $agedLine), @($codexFreshName, $freshLine))) {
        $pair[1] | Set-Content -LiteralPath (Join-Path $codexAgedRepoDir $pair[0]) -Encoding UTF8
        $pair[1] | Set-Content -LiteralPath (Join-Path $codexLocalActive $pair[0]) -Encoding UTF8
    }

    # 회귀: 중첩 payload 안의 timestamp 를 활동 시각으로 착각하면 안 된다.
    # 아래 두 세션은 최상위 timestamp 와 중첩 timestamp 가 서로 반대 방향으로 어긋나 있어,
    # 줄 안의 마지막 "timestamp" 를 집는 방식이면 둘 다 반대로 판정된다.
    $nestedAgedId   = '019f0000-0000-7000-8000-0000000e57ed'
    $nestedFreshId  = '019f0000-0000-7000-8000-0000000f8e51'
    $nestedNow      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $nestedAgedName  = "rollout-2026-05-03T09-00-00-$nestedAgedId.jsonl"
    $nestedFreshName = "rollout-2026-05-03T09-00-00-$nestedFreshId.jsonl"
    # 최상위는 오래됨 / 중첩은 최신  → 노화로 판정돼야 한다
    $nestedAgedLine = $codexMetaA + "`n" + '{"type":"event_msg","timestamp":"2026-05-04T09:00:00.000Z","payload":{"type":"session_meta","timestamp":"' + $nestedNow + '"}}'
    # 최상위는 최신 / 중첩은 오래됨  → 활성으로 남아야 한다
    $nestedFreshLine = $codexMetaA + "`n" + '{"type":"event_msg","timestamp":"' + $nestedNow + '","payload":{"type":"session_meta","timestamp":"2026-05-04T09:00:00.000Z"}}'
    $nestedRepoDir = Join-Path $hostA 'Codex\sessions\2026\05\03'
    $nestedLocalDir = Join-Path $profileA '.codex\sessions\2026\05\03'
    New-Item -ItemType Directory -Force -Path $nestedRepoDir, $nestedLocalDir | Out-Null
    foreach ($nestedPair in @(@($nestedAgedName, $nestedAgedLine), @($nestedFreshName, $nestedFreshLine))) {
        $nestedPair[1] | Set-Content -LiteralPath (Join-Path $nestedRepoDir $nestedPair[0]) -Encoding UTF8
        $nestedPair[1] | Set-Content -LiteralPath (Join-Path $nestedLocalDir $nestedPair[0]) -Encoding UTF8
    }

    # 원문이 어느 계층에도 없는 목록 항목은 자동으로 지우거나 archive 로 확정하면 안 된다.
    $codexUnresolvedId = '019f0000-0000-7000-8000-0000000000ff'
    $codexIndexRepo = Join-Path $hostA 'Codex\session_index.jsonl'
    Add-Content -LiteralPath $codexIndexRepo -Encoding UTF8 `
        -Value ('{"id":"' + $codexUnresolvedId + '","thread_name":"unresolved entry","updated_at":"2026-05-01T00:00:00.0000000Z"}')

    foreach ($senderFile in @(
        'Launchers\Push-Sessions.ps1',
        'Launchers\Pull-Sessions.ps1',
        'Launchers\AgentSessionSync.Common.ps1',
        'Launchers\Set-CodexSessionProjects.ps1',
        'Launchers\Test-SessionSecrets.ps1',
        '.gitignore'
    )) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $senderFile) -Destination (Join-Path $hostA $senderFile) -Force
    }
    & (Join-Path $hostA 'Launchers\Set-CodexSessionProjects.ps1') $codexFreshId -Projects @('DemoA', 'MultiAgent')
    if ($LASTEXITCODE -ne 0) { throw 'Codex semantic project tagging failed.' }
    & (Join-Path $hostA 'Launchers\Push-Sessions.ps1') -ForceOwnership
    if ($LASTEXITCODE -ne 0) { throw 'Host A push failed.' }
    if (Test-Path -LiteralPath (Join-Path $hostA "Codex\sessions\$codexKey\2026\06\20\rollout-large-test.jsonl")) {
        throw '한도 초과 Codex JSONL이 raw 파일로 저장소에 남았습니다.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\sessions\$codexKey\2026\06\20\rollout-large-test.jsonl.gz"))) {
        throw '한도 초과 Codex JSONL의 gzip 운반물이 생성되지 않았습니다.'
    }
    if (-not @(& git -C $hostA ls-files -- "Codex/sessions/$codexKey/2026/06/20/rollout-large-test.jsonl.gz")) {
        throw 'Codex gzip 운반물이 Git 추적 대상에 포함되지 않았습니다.'
    }

    # 변경 없는 대형 세션은 기존 gzip을 교체하지 않아야 한다. gzip을 읽기 전용 공유로
    # 열어 둔 채 두 번째 Push가 성공하면 재압축/교체 경로를 타지 않았다는 뜻이다.
    $largeTransportGzip = Join-Path $hostA "Codex\sessions\$codexKey\2026\06\20\rollout-large-test.jsonl.gz"
    $gzipLock = [IO.File]::Open($largeTransportGzip, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & (Join-Path $hostA 'Launchers\Push-Sessions.ps1') -ForceOwnership
        if ($LASTEXITCODE -ne 0) { throw 'Unchanged oversized-session Push failed while gzip was locked.' }
    }
    finally {
        $gzipLock.Dispose()
    }

    # append-only 원본이 늘어나면 기존 gzip을 재사용하지 않고 새 내용으로 교체해야 한다.
    '{"type":"event_msg","payload":{"type":"user_message","message":"large session appended"}}' |
        Add-Content -LiteralPath $largeCodexSource -Encoding UTF8
    $largeCodexHash = (Get-FileHash -LiteralPath $largeCodexSource -Algorithm SHA256).Hash
    & (Join-Path $hostA 'Launchers\Push-Sessions.ps1') -ForceOwnership
    if ($LASTEXITCODE -ne 0) { throw 'Changed oversized-session Push failed.' }

    # 보존은 하되 활성 폴더에서는 빠져야 한다. 삭제가 아니라 이동인지 둘 다 확인한다.
    if (Test-Path -LiteralPath (Join-Path $agedDir 'aged-test.jsonl')) {
        throw '로컬에서 사라진 세션이 활성 폴더에 그대로 남아 있습니다.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Claude\archive\$keyA\aged-test.jsonl"))) {
        throw '로컬에서 사라진 세션이 archive 로 옮겨지지 않았습니다(삭제되었을 수 있음).'
    }
    if (Test-Path -LiteralPath (Join-Path $hostA "ClaudeApp\claude-code-sessions\$regRelative\local_tomb.json")) {
        throw '폐기 선언된 항목이 저장소 활성 목록에 남아 있습니다.'
    }
    # 목록 항목은 메타데이터라 아카이브하지 않는다. 대화 원문만 보존 대상이다.
    if (Test-Path -LiteralPath (Join-Path $regA 'local_tomb.json')) {
        throw '폐기 선언된 항목이 이 PC 목록에 남아 있습니다(삭제가 반영되지 않음).'
    }
    if (Test-Path -LiteralPath (Join-Path $codexRepoDir $codexArchivedName)) {
        throw 'Archived Codex session is still in the repository active tree.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\archive\$codexKey\2026\07\26\$codexArchivedName"))) {
        throw 'Archived Codex session was not moved into Codex/archive (it may have been deleted).'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\archive\$codexKey\2026\07\20\$codexUploadName"))) {
        throw 'A rollout held only in local archived_sessions was not preserved into Codex/archive.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\archive\$codexKey\2026\05\01\$codexAgedName"))) {
        throw 'A session whose last activity is past the retention window was not archived.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\sessions\$codexKey\2026\05\01\$codexFreshName"))) {
        throw 'A session started long ago but still active was archived by mistake.'
    }
    # 노화된 세션은 이 호스트 활성 집합에서도 내려가야 다음 Push 때 되올라오지 않는다.
    if (Test-Path -LiteralPath (Join-Path $codexLocalActive $codexAgedName)) {
        throw 'An aged session was archived in the repository but left in the local working set.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $profileA ".codex\archived_sessions\$codexAgedName"))) {
        throw 'An aged session was removed from the local working set without landing in archived_sessions.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $codexLocalActive $codexFreshName))) {
        throw 'A still-active session was demoted out of the local working set.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\archive\$codexKey\2026\05\03\$nestedAgedName"))) {
        throw 'Age was read from a nested payload timestamp instead of the top-level one (aged session kept active).'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hostA "Codex\sessions\$codexKey\2026\05\03\$nestedFreshName"))) {
        throw 'Age was read from a nested payload timestamp instead of the top-level one (active session archived).'
    }
    # 원문 없는 목록 항목은 보류만 한다 — 지우지도, archive_index 로 확정하지도 않는다.
    if (-not (Select-String -LiteralPath $codexIndexRepo -SimpleMatch $codexUnresolvedId -Quiet)) {
        throw 'An index entry with no rollout was removed instead of being left unresolved.'
    }
    $codexArchiveIndex = Join-Path $hostA 'Codex\archive_index.jsonl'
    if ((Test-Path -LiteralPath $codexArchiveIndex) -and
        (Select-String -LiteralPath $codexArchiveIndex -SimpleMatch $codexUnresolvedId -Quiet)) {
        throw 'An index entry with no rollout was auto-filed into archive_index.'
    }
    $projectTags = Get-Content -LiteralPath (Join-Path $hostA 'Codex\session_projects.jsonl') -Raw -Encoding UTF8
    if ($projectTags -notmatch [regex]::Escape($codexFreshId) -or $projectTags -notmatch '"DemoA"' -or $projectTags -notmatch '"MultiAgent"') {
        throw 'Semantic project tags were not preserved independently of the rollout path.'
    }

    $env:APPDATA = Join-Path $profileB 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileB 'AppData\Local'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
    # Host A Push가 현재 작업 트리의 송수신 스크립트를 임시 원격에 함께 커밋했습니다.
    # Host B는 미커밋 덮어쓰기 없이 먼저 이를 받아야 Pull 내부의 git pull과 충돌하지 않습니다.
    & git -C $hostB pull --ff-only | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to update receiver scripts from the temporary remote.' }

    # HostB 는 같은 항목을 트랜스크립트 연결이 끊긴 상태로 갖고 있다(이 PC에 파일이 없어
    # 앱이 cliSessionId 를 떼어낸 상황). Pull 이 레포의 정상 항목으로 복구해야 한다.
    $regB = Join-Path $env:APPDATA "Claude\claude-code-sessions\$regRelative"
    New-Item -ItemType Directory -Force -Path $regB | Out-Null
    '{"sessionId":"local_bound","cwd":"X","title":"bound entry","transcriptUnavailable":true}' |
        Set-Content -LiteralPath (Join-Path $regB 'local_bound.json') -Encoding UTF8
    # HostB 는 폐기된 대화를 아직 자기 목록에 갖고 있다. 복사를 건너뛰는 것만으로는
    # 이 항목이 살아남으므로, Pull 이 마커를 받아 실제로 치워야 한다.
    '{"sessionId":"local_tomb","cliSessionId":"gone","cwd":"X","title":"tombstoned entry"}' |
        Set-Content -LiteralPath (Join-Path $regB 'local_tomb.json') -Encoding UTF8

    & (Join-Path $hostB 'Launchers\Pull-Sessions.ps1') -Force
    if ($LASTEXITCODE -ne 0) { throw 'Host B pull failed.' }

    # 폴더 이름을 보존하므로 송신측과 같은 키 아래에 복원된다.
    $claudeExpected = Join-Path $profileB ".claude\projects\$keyA\claude-test.jsonl"
    $extraExpected = Join-Path $profileB ".claude\projects\$keyExtra\extra-test.jsonl"
    $transportedClaude = Get-Item -LiteralPath $claudeExpected -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $extraExpected)) {
        throw "ProjectRoot 에 등록되지 않은 프로젝트의 세션이 전송되지 않았습니다 (expected $extraExpected)."
    }
    if (-not (Test-ClaudeAppEntryBound (Join-Path $regB 'local_bound.json'))) {
        throw '앱 목록 항목의 트랜스크립트 연결(cliSessionId)이 복구되지 않았습니다.'
    }
    if (Test-Path -LiteralPath (Join-Path $regB 'local_tomb.json')) {
        throw '상대 PC에서 지운 대화가 이 PC 목록에 그대로 남았습니다(삭제 미반영).'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $regB 'deleted_tomb'))) {
        throw '삭제 마커가 상대 PC로 운반되지 않았습니다.'
    }
    if (Test-Path -LiteralPath (Join-Path $profileB ".claude\projects\$keyA\aged-test.jsonl")) {
        throw 'archive 로 내려간 세션이 앱 인덱스로 복원되었습니다.'
    }
    if (Get-ChildItem (Join-Path $profileB '.codex\sessions') -Filter $codexArchivedName -Recurse -File -ErrorAction SilentlyContinue) {
        throw 'Archived Codex session was restored into the other host working set.'
    }
    $transportedCodex = Get-ChildItem (Join-Path $profileB '.codex\sessions') -Filter 'rollout-test.jsonl' -Recurse -File -ErrorAction SilentlyContinue
    $transportedLargeCodex = Get-ChildItem (Join-Path $profileB '.codex\sessions') -Filter 'rollout-large-test.jsonl' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $transportedClaude) { throw "Claude session was not restored (expected transport under $claudeExpected)." }
    if (-not $transportedCodex) { throw 'Codex session was not restored.' }
    if (-not $transportedLargeCodex) { throw '압축 운반된 Codex 세션이 JSONL로 복원되지 않았습니다.' }
    if (Test-Path -LiteralPath (Join-Path $profileB ".codex\sessions\$codexKey")) {
        throw 'Vault cwd-key 축이 로컬 Codex 앱 세션 트리에 누출됐습니다.'
    }
    if ((Get-FileHash -LiteralPath $transportedLargeCodex.FullName -Algorithm SHA256).Hash -ne $largeCodexHash) {
        throw '압축 왕복 뒤 Codex JSONL 해시가 원본과 다릅니다.'
    }
    $diagnosticPath = Join-Path $env:LOCALAPPDATA 'AgentSessionSync\Logs\latest.json'
    if (-not (Test-Path -LiteralPath $diagnosticPath)) { throw 'Codex visibility diagnostic log was not created.' }
    $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($diagnostic.schemaVersion -ne 1) { throw 'Unexpected Codex visibility diagnostic schema version.' }
    if ($diagnostic.inventory.rolloutFiles -lt 1) { throw 'Diagnostic log did not inventory restored rollouts.' }
    # 반대 방향(보호): 연결이 끊긴 원본은 연결이 살아 있는 대상을 덮어쓰지 못한다.
    $guardRoot = Join-Path $testRoot 'RegistryGuard'
    $guardSrc = Join-Path $guardRoot 'src'
    $guardDst = Join-Path $guardRoot 'dst'
    New-Item -ItemType Directory -Force -Path $guardSrc, $guardDst | Out-Null
    '{"sessionId":"local_x","transcriptUnavailable":true}' | Set-Content -LiteralPath (Join-Path $guardSrc 'local_x.json') -Encoding UTF8
    '{"sessionId":"local_x","cliSessionId":"keep-me"}' | Set-Content -LiteralPath (Join-Path $guardDst 'local_x.json') -Encoding UTF8
    (Get-Item -LiteralPath (Join-Path $guardSrc 'local_x.json')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(10)
    $guardStats = Merge-ClaudeAppRegistry -Source $guardSrc -Destination $guardDst
    if ($guardStats.Protected -ne 1) { throw "손상된 항목이 보호되지 않았습니다 (Protected=$($guardStats.Protected))." }
    if (-not (Test-ClaudeAppEntryBound (Join-Path $guardDst 'local_x.json'))) {
        throw '더 최신인 손상 항목이 멀쩡한 항목을 덮어썼습니다.'
    }

    # unresolved 항목은 복구 입력에서 제외되므로 'failed' 가 나오면 안 된다.
    if ($diagnostic.status -notin @('no-index', 'complete', 'partial', 'version-mismatch', 'no-compatible-cli')) {
        throw "Unexpected Codex visibility diagnostic status: $($diagnostic.status)"
    }

    # 하위호환: cwd-key 없이 날짜로 바로 시작하는 구 Vault 경로도 Pull 투영 함수가 읽는다.
    $legacyRoot = Join-Path $testRoot 'LegacyCompat\sessions'
    $legacyTarget = Join-Path $testRoot 'LegacyCompat\local'
    $legacyId = '019f0000-0000-7000-8000-00000000c0de'
    $legacyDir = Join-Path $legacyRoot '2026\08\01'
    New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
    ($codexMetaA + "`n" + '{"timestamp":"2026-08-01T00:00:00.000Z","type":"event_msg"}') |
        Set-Content -LiteralPath (Join-Path $legacyDir "rollout-2026-08-01T00-00-00-$legacyId.jsonl") -Encoding UTF8
    $legacyStats = Copy-CodexTransportTreeToNative -SourceRoot $legacyRoot -DestinationRoot $legacyTarget
    if ($legacyStats.Raw -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $legacyTarget "2026\08\01\rollout-2026-08-01T00-00-00-$legacyId.jsonl"))) {
        throw 'Legacy direct-date Codex Vault path was not restored compatibly.'
    }

    # 같은 UUID가 서로 다른 cwd-key 아래 있으면 임의 선택하지 않고 오류로 막는다.
    $duplicateRoot = Join-Path $testRoot 'DuplicateGuard'
    foreach ($duplicateKey in @('C--Projects-A', 'C--Projects-B')) {
        $duplicateDir = Join-Path $duplicateRoot "$duplicateKey\2026\08\01"
        New-Item -ItemType Directory -Force -Path $duplicateDir | Out-Null
        $codexMetaA | Set-Content -LiteralPath (Join-Path $duplicateDir "rollout-2026-08-01T00-00-00-$legacyId.jsonl") -Encoding UTF8
    }
    $duplicateRejected = $false
    try { Get-CodexRolloutIds $duplicateRoot | Out-Null } catch { $duplicateRejected = $true }
    if (-not $duplicateRejected) { throw 'Duplicate Codex UUIDs across cwd-key paths were silently accepted.' }

    Write-Host '[PASS] Temporary two-clone Claude/Codex round trip succeeded.' -ForegroundColor Green
}
finally {
    $env:APPDATA = $oldAppData
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
            # Cloned session trees can exceed the 260-char path limit and defeat
            # Remove-Item; mirror an empty directory over the tree first to flatten it.
            $emptyDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
            & robocopy $emptyDir $resolved /MIR /NFL /NDL /NJH /NJS /NC /NS > $null
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$global:LASTEXITCODE = 0
