#requires -Version 5.1
<#
  Preflight 계약.

  통합 런처는 등록된 모든 패키지를 먼저 -Preflight 로 돌리고, 전부 통과했을 때만
  실제 적용을 시작한다. 계약은 셋이다.

    1. 운영 런처가 -Preflight 를 받는다.
    2. -Preflight 는 아무것도 바꾸지 않는다. Git 이력도 포함이다.
    3. -Preflight 가 앱별 계획을 실제로 만들어 검증한다.

  3번이 없으면 계약의 목적을 못 이룬다. Git 상태만 보고 통과시킨 뒤 앱을 다 죽이고
  나서 계획 오류로 실패하는 것이 이 계약을 만든 사고였다.

  2번 검사에서 .git 을 제외하면 안 된다. fetch·merge·push 는 작업 트리를 안 바꾸고
  .git 만 바꾸므로, 제외하면 상태를 바꾸는 구현이 그대로 통과한다.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$launchers = Split-Path -Parent $PSScriptRoot
$sourceRoot = Split-Path -Parent $launchers
. (Join-Path $launchers 'AgentSessionSync.Common.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PreflightContract-' + [guid]::NewGuid().ToString('N'))
$passed = 0

# 사전검사가 실제 계획을 만들면 Claude 앱 레지스트리를 찾아 나선다. 격리하지 않으면
# 이 머신의 진짜 대화 목록을 읽고, 테스트 결과가 개발자 PC 상태에 따라 달라진다.
$oldLocalAppData = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED [#$($script:passed + 1)]: $Message" }
    $script:passed++
}

function Get-VaultState {
    # 작업 트리 지문 + Git 이력 상태. 둘 다 봐야 mutating 구현을 잡는다.
    param([string]$Repo)
    $files = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Repo -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($file.FullName -like '*\.git\*') { continue }
        $files += ($file.FullName.Substring($Repo.Length) + '|' + (Get-AgentSessionFileSha256 $file.FullName))
    }
    [pscustomobject]@{
        Tree = ($files | Sort-Object) -join "`n"
        Head = ([string](& git -C $Repo rev-parse HEAD)).Trim()
        Refs = (@(& git -C $Repo for-each-ref --format='%(refname) %(objectname)') | Sort-Object) -join "`n"
        Log  = ([string](& git -C $Repo rev-list --count HEAD)).Trim()
    }
}

function Assert-Unchanged {
    param($Before, $After, [string]$What)
    Assert-True ($After.Tree -eq $Before.Tree) "$What : 작업 트리를 바꾸면 안 된다"
    Assert-True ($After.Head -eq $Before.Head) "$What : HEAD 를 옮기면 안 된다"
    Assert-True ($After.Refs -eq $Before.Refs) "$What : ref 를 바꾸면 안 된다 (fetch/merge/push 금지)"
    Assert-True ($After.Log -eq $Before.Log)   "$What : 커밋을 만들면 안 된다"
}

function Write-ClaudeTranscript {
    param([string]$Path, [string]$Id, [string]$Timestamp)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $title = [ordered]@{ type = 'custom-title'; customTitle = 'demo'; sessionId = $Id } | ConvertTo-Json -Compress
    $message = [ordered]@{ type = 'message'; sessionId = $Id; timestamp = $Timestamp } | ConvertTo-Json -Compress
    Write-AgentSessionUtf8File -Path $Path -Content (($title, $message) -join "`n")
}

try {
    $repo = Join-Path $testRoot 'Vault'
    $remote = Join-Path $testRoot 'Remote.git'
    $claudeHome = Join-Path $testRoot 'ClaudeHome'
    $codexHome = Join-Path $testRoot 'CodexHome'
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalA'
    $env:APPDATA = Join-Path $testRoot 'RoamingA'
    $registry = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    New-Item -ItemType Directory -Path $repo, $claudeHome, $codexHome, $registry, `
        $env:LOCALAPPDATA, (Join-Path $repo 'Agents') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launchers') -Destination $repo -Recurse
    Add-Content -LiteralPath (Join-Path $repo 'Launchers\AgentLauncher.Common.ps1') `
        -Value "`nfunction Get-SystemProcessSnapshot { @() }" -Encoding ASCII

    $config = @"
@{
    ClaudeHome = '$($claudeHome.Replace("'", "''"))'
    CodexHome = '$($codexHome.Replace("'", "''"))'
    ActiveWindowDays = 30
    SessionDataPushEnabled = `$true
    GracefulCloseTimeoutSeconds = 1
}
"@
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'AgentSessionSync.config.psd1') -Content $config
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'ACTIVE_HOST.txt') -Content "NONE`n"
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'Agents\Codex.psd1') `
        -Content "@{ Name='Codex'; AppId='Test.App'; ProcessNames=@('PreflightNoSuchProcess'); Enabled=`$true; Order=10 }"

    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    & git init --bare -q $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -qu origin HEAD
    if ($LASTEXITCODE -ne 0) { throw 'fixture repository init failed' }

    $startScript = Join-Path $repo 'Launchers\Start.ps1'
    $finishScript = Join-Path $repo 'Launchers\Finish.ps1'
    $liveConfig = Get-AgentSessionSyncConfig $repo

    # --- 1) 두 런처가 -Preflight 를 받는다 ---
    foreach ($pair in @(@{ Path = $startScript; Name = 'Start' }, @{ Path = $finishScript; Name = 'Finish' })) {
        Assert-True ((Get-Command $pair.Path).Parameters.ContainsKey('Preflight')) `
            "$($pair.Name).ps1 이 -Preflight 를 받아야 한다"
    }

    # --- 2) 사전검사는 Git 이력을 포함해 아무것도 바꾸지 않는다 ---
    $before = Get-VaultState $repo
    & $startScript -Preflight | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Start -Preflight 는 성공해야 한다'
    Assert-Unchanged $before (Get-VaultState $repo) 'Start preflight'

    $before = Get-VaultState $repo
    & $finishScript -Preflight | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Finish -Preflight 는 성공해야 한다'
    Assert-Unchanged $before (Get-VaultState $repo) 'Finish preflight'

    Assert-True (-not (@(Get-ChildItem -LiteralPath $claudeHome -Recurse -File -ErrorAction SilentlyContinue)).Count) `
        '사전검사는 앱 저장소에 쓰면 안 된다'

    # --- 3) 로컬이 원격보다 앞선 상태에서도 push 하지 않는다 ---
    # 이전 구현은 Prepare-AgentSessionVaultMutation 을 불러 미게시 커밋을 push 했다.
    # 픽스처가 항상 HEAD == upstream 이면 그 경로가 발화하지 않아 통과해 버린다.
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'docs\note.md') -Content 'ahead'
    & git -C $repo add -A
    & git -C $repo commit -qm 'local ahead of remote'
    $remoteBefore = ([string](& git -C $remote rev-parse HEAD)).Trim()
    $before = Get-VaultState $repo

    & $startScript -Preflight | Out-Null
    Assert-Unchanged $before (Get-VaultState $repo) 'Start preflight (ahead)'
    & $finishScript -Preflight | Out-Null
    Assert-Unchanged $before (Get-VaultState $repo) 'Finish preflight (ahead)'
    Assert-True ((([string](& git -C $remote rev-parse HEAD)).Trim()) -eq $remoteBefore) `
        '사전검사는 미게시 커밋을 원격에 push 하면 안 된다'

    & git -C $repo push -q
    $before = Get-VaultState $repo

    # --- 4) 사전검사가 앱별 계획을 실제로 만든다 ---
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $launchers 'AgentSessionSync.Common.ps1'), [ref]$null, [ref]$null)
    function Get-Calls {
        param([string]$Name)
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if ($fn.Count -ne 1) { throw "함수를 찾지 못했습니다: $Name" }
        @($fn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
    foreach ($phase in @('Start', 'Finish')) {
        $calls = Get-Calls "Test-AgentSession${phase}Preflight"
        Assert-True ($calls -contains 'Test-AgentSessionPlanPreflight') `
            "$phase 사전검사는 앱별 계획을 검증해야 한다"
        Assert-True ($calls -contains 'Test-AgentSessionGzipIntegrity') `
            "$phase 사전검사는 공용 gzip 검사를 호출해야 한다"
        Assert-True ($calls -notcontains 'Prepare-AgentSessionVaultMutation') `
            "$phase 사전검사는 Prepare-AgentSessionVaultMutation 을 부르면 안 된다"
    }
    $planCalls = Get-Calls 'Test-AgentSessionPlanPreflight'
    Assert-True ($planCalls -contains 'Assert-AgentSessionPlans') '계획 사전검사는 계획을 검증해야 한다'
    Assert-True ($planCalls -notcontains 'Commit-AgentSessionVault' -and
                 $planCalls -notcontains 'Push-AgentSessionVault') '계획 사전검사는 commit·push 하면 안 된다'

    # --- 5) 계획이 실패하면 사전검사가 막는다 ---
    # Claude 원문에 짝이 되는 목록 항목이 없으면 Finish 계획이 실패한다.
    # 이전 구현은 이걸 못 잡아서 앱을 다 죽인 뒤 실패했다.
    $orphan = '99999999-9999-4999-8999-999999999999'
    Write-ClaudeTranscript (Join-Path $claudeHome "projects\C--Project-Demo\$orphan.jsonl") `
        $orphan ([DateTime]::UtcNow.ToString('o'))

    $tripped = $false
    try { Test-AgentSessionFinishPreflight -RepoRoot $repo -Config $liveConfig } catch { $tripped = $true }
    Assert-True $tripped '짝 없는 Claude 원문은 Finish 사전검사가 막아야 한다'
    Assert-Unchanged $before (Get-VaultState $repo) 'Finish preflight (계획 실패)'

    # 런처를 통해서도 같은 실패가 나야 한다. Finish.ps1 은 ErrorActionPreference=Stop
    # 이라 종료 오류가 그대로 전파되므로 여기서 받아준다.
    $launcherTripped = $false
    try { & $finishScript -Preflight | Out-Null } catch { $launcherTripped = $true }
    Assert-True $launcherTripped '계획이 실패하면 Finish -Preflight 도 실패해야 한다'
    Assert-Unchanged $before (Get-VaultState $repo) 'Finish -Preflight (런처, 계획 실패)'

    Remove-Item -LiteralPath (Join-Path $claudeHome "projects\C--Project-Demo\$orphan.jsonl") -Force

    # --- 6) 손상된 gzip integrity 는 양쪽 사전검사가 막는다 ---
    $gzDir = Join-Path $repo 'Codex\sessions\C--Project-Demo\2026\01\01'
    New-Item -ItemType Directory -Path $gzDir -Force | Out-Null
    $raw = Join-Path $testRoot 'big.jsonl'
    Write-AgentSessionUtf8File -Path $raw -Content ('{"type":"session_meta"}' + "`n") -NoBom
    $gz = Join-Path $gzDir 'rollout-a.jsonl.gz'
    Compress-JsonlTransportFile -Source $raw -Destination $gz
    Write-AgentSessionUtf8File -Path (Get-CompressedJsonlIntegrityPath $gz) -NoBom -Content (
        [ordered]@{
            schemaVersion = 1
            rawLength = (Get-Item -LiteralPath $raw).Length
            rawSha256 = Get-AgentSessionFileSha256 $raw
            gzipLength = 1                      # 실제와 다른 값
            gzipSha256 = Get-AgentSessionFileSha256 $gz
        } | ConvertTo-Json -Depth 3)
    & git -C $repo add -A
    & git -C $repo commit -qm broken-gzip

    foreach ($phase in @('Start', 'Finish')) {
        $tripped = $false
        try { & "Test-AgentSession${phase}Preflight" -RepoRoot $repo -Config $liveConfig } catch { $tripped = $true }
        Assert-True $tripped "손상된 gzip integrity 는 $phase 사전검사가 막아야 한다"
    }

    # --- 7) Vault dirty 는 양쪽이 막는다 ---
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'dirty.txt') -Content 'dirty'
    $tripped = $false
    try { Test-AgentSessionVaultReadable -RepoRoot $repo } catch { $tripped = $true }
    Assert-True $tripped 'Vault working tree 가 dirty 면 사전검사가 막아야 한다'

    Write-Host "[PASS] Preflight contract: $passed assertions" -ForegroundColor Green
    Write-Host '       -Preflight 수용, Git 이력 포함 무변경, ahead 시 push 금지,' -ForegroundColor DarkGray
    Write-Host '       앱별 계획 검증, 계획 실패 차단, gzip integrity, dirty 차단' -ForegroundColor DarkGray
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
