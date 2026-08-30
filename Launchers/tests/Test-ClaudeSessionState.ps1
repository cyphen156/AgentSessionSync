#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

# 어댑터는 공용 엔진에만 의존한다. Codex 어댑터는 불러오지 않는다.
$launchers = Split-Path -Parent $PSScriptRoot
. (Join-Path $launchers 'AgentSessionSync.Common.ps1')
. (Join-Path $launchers 'ClaudeSessionState.Common.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClaudeSessionState-' + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED [#$($script:passed + 1)]: $Message" }
    $script:passed++
}

function Write-TestTranscript {
    # 첫 레코드에 timestamp 가 없다. 실제 Claude 원문이 그렇고(533줄 중 488줄만 보유),
    # 마지막 한 줄만 읽는 구현이면 여기서 깨진다.
    param([string]$Path, [string]$Id, [string]$Timestamp)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $title = [ordered]@{ type = 'custom-title'; customTitle = 'demo'; sessionId = $Id } | ConvertTo-Json -Compress
    $message = [ordered]@{ type = 'message'; sessionId = $Id; timestamp = $Timestamp } | ConvertTo-Json -Compress
    Write-AgentSessionUtf8File -Path $Path -Content (($title, $message) -join "`n")
}

function Write-TestEntry {
    param([string]$RegistryRoot, [string]$AppSessionId, [string]$CanonicalId)
    $path = Join-Path $RegistryRoot "workspace\window\local_$AppSessionId.json"
    $content = [ordered]@{
        sessionId = "local_$AppSessionId"; cliSessionId = $CanonicalId
        cwd = 'C:\Project\Demo'; isArchived = $false; title = 'demo'
    } | ConvertTo-Json
    Write-AgentSessionUtf8File -Path $path -Content $content
}

function Test-Utf8Bom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Write-TestSidecar {
    param([string]$Path, [string]$AppSessionId, [string]$CanonicalId)
    $content = [pscustomobject]@{
        schemaVersion = 1; appSessionId = $AppSessionId
        relativePath = "workspace/window/local_$AppSessionId.json"
        entry = [ordered]@{ sessionId = "local_$AppSessionId"; cliSessionId = $CanonicalId; cwd = 'C:\Project\Demo' }
    } | ConvertTo-Json -Depth 10
    Write-AgentSessionUtf8File -Path $Path -Content $content
}

function Remove-TestEntry {
    # 앱이 대화를 지우면 목록 항목은 사라지고 마커만 남으며 원문은 그대로 남는다.
    param([string]$RegistryRoot, [string]$AppSessionId)
    $path = Join-Path $RegistryRoot "workspace\window\local_$AppSessionId.json"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Write-AgentSessionUtf8File -Path (Join-Path $RegistryRoot "workspace\window\deleted_$AppSessionId") `
        -Content ([string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

function Get-TreeFingerprint {
    param([string[]]$Roots)
    $entries = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.FullName -like '*\.git\*') { continue }
            $entries += ($file.FullName + '|' + (Get-AgentSessionFileSha256 $file.FullName))
        }
    }
    ($entries | Sort-Object) -join "`n"
}

function New-TestContext {
    param([string]$RepoRoot, $Config)
    [pscustomobject]@{
        SchemaVersion = 1; RepoRoot = $RepoRoot; Config = $Config
        VaultCommit = (Get-AgentSessionVaultHead $RepoRoot)
        NowUtc = [DateTime]::UtcNow
    }
}

function Invoke-TestApply {
    # Push-Sessions 와 같은 순서: 계획 검증 → Vault 적용 → commit/push → 로컬 적용 → checkpoint
    param([string]$RepoRoot, $Config, $Plan, [string]$PlanRoot, [switch]$SkipVault)
    $base = $Plan.ExpectedVaultCommit
    $published = $base
    if (-not $SkipVault -and @($Plan.VaultOperations).Count -gt 0) {
        $rootMap = Get-AgentSessionRootMap -Plans @($Plan) -RepoRoot $RepoRoot
        Assert-AgentSessionPlans -Plans @($Plan) -RootMap $rootMap -ExpectedVaultCommit $base -PlanRoot $PlanRoot
        Assert-AgentSessionVaultSources -Operations @($Plan.VaultOperations) -RepoRoot $RepoRoot
        $transaction = Start-AgentSessionFileTransaction -RootMap $rootMap -TransactionRoot (Join-Path $PlanRoot 'VaultTxn')
        Add-AgentSessionOperations -Transaction $transaction -Operations @(Get-AgentSessionOrderedOperations $Plan.VaultOperations) -RepoRoot $RepoRoot
        $commit = Commit-AgentSessionVault -RepoRoot $RepoRoot -Message 'claude test'
        Complete-AgentSessionFileTransaction $transaction
        $published = Push-AgentSessionVault -RepoRoot $RepoRoot
        if (-not [string]::Equals($commit, $published, [StringComparison]::OrdinalIgnoreCase)) { throw 'published commit mismatch' }
    }
    $localRootMap = Get-AgentSessionRootMap -Plans @($Plan) -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans @($Plan) -RootMap $localRootMap -ExpectedVaultCommit $base -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
    $localTransaction = Start-AgentSessionFileTransaction -RootMap $localRootMap -TransactionRoot (Join-Path $PlanRoot 'LocalTxn')
    Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations $Plan.LocalOperations) -RepoRoot $RepoRoot

    $publishedContext = [pscustomobject]@{
        SchemaVersion = 1; RepoRoot = $RepoRoot; Config = $Config; VaultCommit = $published
        NowUtc = [DateTime]::UtcNow
    }
    $checkpointRoot = Join-Path $PlanRoot ('Checkpoint-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
    $checkpointPlan = New-ClaudeCheckpointPlan -Context $publishedContext -State $Plan.Result -PublishedCommit $published -PlanRoot $checkpointRoot
    $checkpointRootMap = Get-AgentSessionRootMap -Plans @($Plan, $checkpointPlan) -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans @($checkpointPlan) -RootMap $checkpointRootMap -ExpectedVaultCommit $published -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
    Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations $checkpointPlan.LocalOperations) -RepoRoot $RepoRoot
    Complete-AgentSessionFileTransaction $localTransaction
}

try {
    $repo = Join-Path $testRoot 'Vault'
    $remote = Join-Path $testRoot 'Remote.git'
    $claudeHome = Join-Path $testRoot 'ClaudeHome'
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalA'
    $env:APPDATA = Join-Path $testRoot 'RoamingA'
    $registry = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    New-Item -ItemType Directory -Path $repo, $claudeHome, $env:LOCALAPPDATA, $registry -Force | Out-Null

    $key = 'C--Project-Demo'
    $fresh = [DateTime]::UtcNow.ToString('o')
    $stale = [DateTime]::UtcNow.AddDays(-90).ToString('o')
    $ids = @{
        Held    = '11111111-1111-4111-8111-111111111111'
        Deleted = '22222222-2222-4222-8222-222222222222'
        Aged    = '33333333-3333-4333-8333-333333333333'
        New     = '44444444-4444-4444-8444-444444444444'
    }
    $apps = @{
        Held    = 'aaaa1111-1111-4111-8111-111111111111'
        Deleted = 'bbbb2222-2222-4222-8222-222222222222'
        Aged    = 'cccc3333-3333-4333-8333-333333333333'
        New     = 'eeee4444-4444-4444-8444-444444444444'
    }

    $vaultActive = Join-Path $repo "Claude\sessions\$key"
    foreach ($name in @('Held', 'Deleted', 'Aged')) {
        $timestamp = if ($name -eq 'Aged') { $stale } else { $fresh }
        Write-TestTranscript (Join-Path $vaultActive ($ids[$name] + '.jsonl')) $ids[$name] $timestamp
        Write-TestSidecar (Join-Path $vaultActive ($ids[$name] + '.entry.json')) $apps[$name] $ids[$name]
    }

    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    & git init --bare -q $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -qu origin HEAD

    $config = [pscustomobject]@{ ClaudeHome = $claudeHome; ActiveWindowDays = 30 }
    $projects = Join-Path $claudeHome 'projects'
    $planRoot = New-AgentSessionPlanRoot -Prefix 'ClaudeTest'

    # --- 1) 첫 Start 는 앱 저장소 전체가 비어 있어야 한다 ---
    Write-TestTranscript (Join-Path $projects "$key\99999999-9999-4999-8999-999999999999.jsonl") '99999999-9999-4999-8999-999999999999' $fresh
    $tripped = $false
    try { [void](New-ClaudeStartPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '첫 Start 전에 원문이 남아 있으면 중단해야 한다'
    Remove-Item -LiteralPath $projects -Recurse -Force

    Write-TestEntry $registry 'dddd4444-4444-4444-8444-444444444444' '55555555-5555-4555-8555-555555555555'
    $tripped = $false
    try { [void](New-ClaudeStartPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '첫 Start 전에 목록 항목이 남아 있으면 중단해야 한다'
    Remove-Item -LiteralPath (Join-Path $registry 'workspace\window\local_dddd4444-4444-4444-8444-444444444444.json') -Force

    Write-AgentSessionUtf8File -Path (Join-Path $registry 'workspace\window\deleted_eeee5555-5555-4555-8555-555555555555') -Content '1'
    $tripped = $false
    try { [void](New-ClaudeStartPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '첫 Start 전에 삭제 마커가 남아 있으면 중단해야 한다'
    Remove-Item -LiteralPath (Join-Path $registry 'workspace\window\deleted_eeee5555-5555-4555-8555-555555555555') -Force

    # --- 2) 계획 생성만으로는 아무것도 바꾸지 않는다 ---
    $before = Get-TreeFingerprint @($repo, $claudeHome, $registry)
    $startPlan = New-ClaudeStartPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ((Get-TreeFingerprint @($repo, $claudeHome, $registry)) -eq $before) '계획 생성은 Vault·앱 저장소를 바꾸지 않아야 한다'
    Assert-True (@($startPlan.VaultOperations).Count -eq 0) 'Start 는 Vault 를 수정하지 않는다'
    Assert-True ($startPlan.Agent -eq 'Claude' -and $startPlan.Phase -eq 'Start') '계획 객체가 계약 형태여야 한다'

    $keys = @($startPlan.LocalOperations | ForEach-Object { $_.TargetRoot + '|' + $_.RelativePath })
    Assert-True ($keys.Count -eq (@($keys | Sort-Object -Unique)).Count) 'TargetRoot + RelativePath 는 한 번만 등장해야 한다'

    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $startPlan -PlanRoot $planRoot -SkipVault
    $local = Get-ClaudeTranscriptSet $projects
    Assert-True ($local.Count -eq 3) "Start 후 로컬 원문 3건이어야 한다 (실제 $($local.Count))"
    Assert-True (Test-Path -LiteralPath (Join-Path $registry "workspace\window\local_$($apps.Held).json")) 'Start 가 목록 항목을 되돌려야 한다'
    $checkpoint = Read-ClaudeCheckpoint $repo
    Assert-True ($checkpoint.Exists -and $checkpoint.ActiveIds.Count -eq 3) 'checkpoint 에 Active 3건이 기록돼야 한다'
    Assert-True ($checkpoint.EntryMap[$apps.Deleted] -eq $ids.Deleted) 'checkpoint 가 변환표를 들고 있어야 한다'

    # --- 3) 앱에서 하나를 지운다: 항목은 사라지고 마커만 남으며 원문은 남는다 ---
    Remove-TestEntry $registry $apps.Deleted
    Assert-True (Test-Path -LiteralPath (Join-Path $projects "$key\$($ids.Deleted).jsonl")) '앱 삭제 후에도 원문은 로컬에 남는다'

    # --- 4) 새 대화 하나 (아직 Vault 에 없다). 원문만 있으면 중단해야 한다 ---
    Write-TestTranscript (Join-Path $projects "$key\$($ids.New).jsonl") $ids.New $fresh
    $tripped = $false
    try { [void](New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '목록 항목 없는 원문은 전송하지 않고 중단해야 한다'
    Write-TestEntry $registry $apps.New $ids.New

    # --- 5) 풀리지 않는 마커가 있으면 판정하지 않고 중단한다 ---
    $orphan = Join-Path $registry 'workspace\window\deleted_ffffffff-ffff-4fff-8fff-ffffffffffff'
    Write-AgentSessionUtf8File -Path $orphan -Content '1'
    $tripped = $false
    try { [void](New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '풀리지 않는 삭제 마커가 있으면 계획 생성을 중단해야 한다'
    Remove-Item -LiteralPath $orphan -Force

    # --- 6) Finish 계획 ---
    $before = Get-TreeFingerprint @($repo, $claudeHome, $registry)
    $finishPlan = New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ((Get-TreeFingerprint @($repo, $claudeHome, $registry)) -eq $before) 'Finish 계획 생성도 아무것도 바꾸지 않아야 한다'

    Assert-True ($finishPlan.Result.DeletedIds -contains $ids.Deleted) '마커로 확정된 삭제가 결과에 있어야 한다'
    Assert-True ($finishPlan.Result.ArchivedIds -contains $ids.Aged) '30일 경과 세션은 Archived 로 내려가야 한다'
    Assert-True ($finishPlan.Result.ActiveIds -contains $ids.New) '새 대화는 Active 로 올라가야 한다'
    Assert-True ($finishPlan.Result.ActiveIds -contains $ids.Held) '계속 활성인 대화는 유지돼야 한다'

    $vaultKeys = @($finishPlan.VaultOperations | ForEach-Object { $_.TargetRoot + '|' + $_.RelativePath })
    Assert-True ($vaultKeys.Count -eq (@($vaultKeys | Sort-Object -Unique)).Count) 'Vault 작업 키가 중복되면 안 된다'
    $puts = @($finishPlan.VaultOperations | Where-Object Kind -eq 'Put' | ForEach-Object RelativePath)
    $deletes = @($finishPlan.VaultOperations | Where-Object Kind -eq 'Delete' | ForEach-Object RelativePath)
    Assert-True (-not (@($puts | Where-Object { $deletes -contains $_ })).Count) '같은 경로가 Put 과 Delete 에 동시에 나오면 안 된다'

    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $finishPlan -PlanRoot $planRoot

    $tiers = Get-ClaudeTierInventory $repo
    Assert-True (-not $tiers.Active.ContainsKey($ids.Deleted) -and -not $tiers.Archived.ContainsKey($ids.Deleted)) '삭제된 세션은 어느 계층에도 없어야 한다'
    Assert-True ($tiers.Archived.ContainsKey($ids.Aged)) 'Aged 는 Archived 계층에 있어야 한다'
    Assert-True ($tiers.Archived[$ids.Aged].EntryPath -ne '') '계층 이동은 항목 사본도 함께 옮겨야 한다'
    Assert-True ($tiers.Active[$ids.New].EntryPath -ne '') '신규 대화도 원문과 항목이 쌍으로 올라가야 한다'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projects "$key\$($ids.Deleted).jsonl"))) '삭제 확정 후 로컬 원문도 지워야 부활하지 않는다'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projects "$key\$($ids.Aged).jsonl"))) 'Archived 는 로컬 활성 집합에서 빠져야 한다'
    Assert-True (Test-Path -LiteralPath (Join-Path $projects "$key\$($ids.Held).jsonl")) '활성 대화는 로컬에 남아야 한다'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $registry "workspace\window\deleted_$($apps.Deleted)"))) '소비한 마커는 제거돼야 한다'
    Assert-True ((Read-ClaudeCheckpoint $repo).ActiveIds.Count -eq 2) 'Finish 후 checkpoint Active 2건이어야 한다'

    # --- 7) 복원 ---
    $restorePlan = New-ClaudeRestorePlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot -SessionId $ids.Aged
    Assert-True ($restorePlan.Result.RestoredIds -contains $ids.Aged) 'Restore 결과에 대상이 있어야 한다'
    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $restorePlan -PlanRoot $planRoot
    $tiers = Get-ClaudeTierInventory $repo
    Assert-True ($tiers.Active.ContainsKey($ids.Aged) -and -not $tiers.Archived.ContainsKey($ids.Aged)) '복원은 Archived 에서 Active 로 이동해야 한다'
    Assert-True (Test-Path -LiteralPath (Join-Path $projects "$key\$($ids.Aged).jsonl")) '복원은 로컬 원문도 배치해야 한다'

    # --- 8) 복원 후 활동이 없으면 다시 노화된다. 중간 이동은 작업으로 나오지 않는다 ---
    $reagePlan = New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ($reagePlan.Result.ArchivedIds -contains $ids.Aged) '활동 없는 복원본은 다시 Archived 로 내려간다'
    $reageKeys = @($reagePlan.VaultOperations | ForEach-Object { $_.TargetRoot + '|' + $_.RelativePath })
    Assert-True ($reageKeys.Count -eq (@($reageKeys | Sort-Object -Unique)).Count) '재노화 계획에도 중복 키가 없어야 한다'
    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $reagePlan -PlanRoot $planRoot
    $tiers = Get-ClaudeTierInventory $repo
    Assert-True (-not $tiers.Active.ContainsKey($ids.Aged)) '재노화 후 Active 에 남으면 안 된다'

    # --- 9) 목록 항목만 마커 없이 사라져도 중단하지 않고 기존 사이드카를 유지한다 ---
    #        항목 부재는 삭제 신호가 아니다. 무조건 중단하거나 사이드카를 버리면 R4 를 해친다.
    $newEntryPath = Join-Path $registry "workspace\window\local_$($apps.New).json"
    Remove-Item -LiteralPath $newEntryPath -Force
    $keepPlan = New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ($keepPlan.Result.ActiveIds -contains $ids.New) '목록 항목이 사라져도 Vault 원문은 유지돼야 한다'
    Assert-True ($keepPlan.Result.DeletedIds.Count -eq 0) '항목 부재는 삭제 신호가 아니다'
    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $keepPlan -PlanRoot $planRoot

    $tiers = Get-ClaudeTierInventory $repo
    Assert-True ($tiers.Active[$ids.New].EntryPath -ne '') '기존 사이드카를 버리면 안 된다'
    Assert-True (-not (Test-Path -LiteralPath $newEntryPath)) 'Finish 는 목록 항목을 되살리지 않는다'

    $recoverPlan = New-ClaudeStartPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Invoke-TestApply -RepoRoot $repo -Config $config -Plan $recoverPlan -PlanRoot $planRoot -SkipVault
    Assert-True (Test-Path -LiteralPath $newEntryPath) '다음 Start 가 사이드카로 목록 항목을 복원해야 한다'
    Assert-True ((Read-ClaudeCheckpoint $repo).EntryMap[$apps.New] -eq $ids.New) 'Start 가 checkpoint 변환표를 다시 캡처해야 한다'

    # --- 10) 마커 없이 원문이 사라지면 판정하지 않고 Vault 원문을 지킨다 (R4) ---
    Remove-Item -LiteralPath (Join-Path $projects "$key\$($ids.Held).jsonl") -Force
    $missingPlan = New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ($missingPlan.Result.MissingIds -contains $ids.Held) '마커 없는 부재는 보류로 보고돼야 한다'
    Assert-True ($missingPlan.Result.ActiveIds -contains $ids.Held) '마커 없이 사라진 원문을 Vault 에서 지우면 안 된다'
    Assert-True ($missingPlan.Result.DeletedIds.Count -eq 0) '마커가 없으면 어떤 삭제도 확정하지 않는다'
    Assert-True (@($missingPlan.Warnings).Count -gt 0) '보류는 경고로 보고돼야 한다'

    # --- 10) 항목 사본 경로·정체성 검증 ---
    $badSidecar = Join-Path $testRoot 'bad.entry.json'
    Write-AgentSessionUtf8File -Path $badSidecar -Content ([pscustomobject]@{
        schemaVersion = 1; appSessionId = 'zzzz0000-0000-4000-8000-000000000000'
        relativePath = '../../escape/local_zzzz0000-0000-4000-8000-000000000000.json'
        entry = [ordered]@{ cliSessionId = $ids.Held }
    } | ConvertTo-Json -Depth 10)
    $tripped = $false
    try { [void](New-ClaudeEntryArtifact -SidecarPath $badSidecar -CanonicalId $ids.Held -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped 'registry 루트를 벗어나는 relativePath 는 거부해야 한다'

    Write-AgentSessionUtf8File -Path $badSidecar -Content ([pscustomobject]@{
        schemaVersion = 1; appSessionId = 'zzzz0000-0000-4000-8000-000000000000'
        relativePath = 'workspace/window/local_zzzz0000-0000-4000-8000-000000000000.json'
        entry = [ordered]@{ cliSessionId = '00000000-0000-4000-8000-000000000000' }
    } | ConvertTo-Json -Depth 10)
    $tripped = $false
    try { [void](New-ClaudeEntryArtifact -SidecarPath $badSidecar -CanonicalId $ids.Held -PlanRoot $planRoot) } catch { $tripped = $true }
    Assert-True $tripped '다른 원문을 가리키는 항목 사본은 거부해야 한다'

    $orphanSidecar = Join-Path $repo "Claude\sessions\$key\00000000-0000-4000-8000-000000000000.entry.json"
    Write-AgentSessionUtf8File -Path $orphanSidecar -Content '{}'
    $tripped = $false
    try { [void](Get-ClaudeTierInventory $repo) } catch { $tripped = $true }
    Assert-True $tripped '원문 없는 항목 사본은 거부해야 한다'
    Remove-Item -LiteralPath $orphanSidecar -Force

    Write-AgentSessionUtf8File -Path $badSidecar -Content ([pscustomobject]@{
        schemaVersion = 2; appSessionId = $apps.Held
        relativePath = "workspace/window/local_$($apps.Held).json"
        entry = [ordered]@{ cliSessionId = $ids.Held }
    } | ConvertTo-Json -Depth 10)
    $tripped = $false
    try { [void](Read-ClaudeSidecar -Path $badSidecar -CanonicalId $ids.Held) } catch { $tripped = $true }
    Assert-True $tripped '지원하지 않는 사이드카 스키마는 거부해야 한다'

    # --- 10b) 앱이 읽는 목록 항목은 BOM 없는 UTF-8 이어야 한다 ---
    # 앱은 readFile(utf-8) 결과를 JSON.parse 에 그대로 넘긴다. 선행 BOM 이면 parse 가
    # 던지고 앱은 그 항목을 조용히 버린다. 파일 개수·해시가 다 맞아도 사이드바에서만
    # 사라지므로, 산출물의 바이트를 직접 본다.
    $encodeSidecar = Join-Path $testRoot 'encoding.entry.json'
    Write-TestSidecar -Path $encodeSidecar -AppSessionId $apps.Held -CanonicalId $ids.Held
    $encodeArtifact = New-ClaudeEntryArtifact -SidecarPath $encodeSidecar -CanonicalId $ids.Held -PlanRoot $planRoot

    $artifactBytes = [IO.File]::ReadAllBytes($encodeArtifact.Path)
    Assert-True ($artifactBytes.Length -ge 3) '항목 산출물이 비어 있으면 안 된다'
    Assert-True (-not (Test-Utf8Bom $artifactBytes)) `
        '앱이 읽는 목록 항목에 UTF-8 BOM 이 있으면 안 된다 (앱의 JSON.parse 가 던진다)'
    Assert-True ($artifactBytes[0] -eq 0x7B) '항목 산출물은 여는 중괄호로 시작해야 한다'

    # 엄격 UTF-8 디코딩: 잘못된 바이트열이면 여기서 던진다.
    $strict = [Text.UTF8Encoding]::new($false, $true)
    $decoded = $null
    $decodeFailed = $false
    try { $decoded = $strict.GetString($artifactBytes) } catch { $decodeFailed = $true }
    Assert-True (-not $decodeFailed) '항목 산출물은 엄격 UTF-8 로 디코딩돼야 한다'
    Assert-True ($decoded[0] -eq '{') '엄격 디코딩 결과의 첫 문자가 U+FEFF 면 안 된다'

    $reparsed = $null
    $parseFailed = $false
    try { $reparsed = $decoded | ConvertFrom-Json } catch { $parseFailed = $true }
    Assert-True (-not $parseFailed) '항목 산출물은 JSON 으로 파싱돼야 한다'
    Assert-True ($reparsed.cliSessionId -eq $ids.Held) '파싱된 항목이 원문 ID 를 그대로 보존해야 한다'

    # BOM 을 뺀 것이 한글 보존을 깨뜨리지 않는지 확인한다. BOM 은 애초에 그 목적이었다.
    $koreanPath = Join-Path $testRoot 'korean-nobom.json'
    Write-AgentSessionUtf8File -Path $koreanPath -Content '{"title":"통합 포트폴리오 구현 계획"}' -NoBom
    $koreanBytes = [IO.File]::ReadAllBytes($koreanPath)
    Assert-True ($koreanBytes[0] -eq 0x7B) '-NoBom 은 BOM 을 쓰지 않아야 한다'
    Assert-True ((($strict.GetString($koreanBytes)) | ConvertFrom-Json).title -eq '통합 포트폴리오 구현 계획') `
        'BOM 없이도 한글이 왕복해야 한다'

    # 기본 호출은 BOM 을 유지한다. 우리가 -Encoding 없이 다시 읽는 설정·사이드카·
    # checkpoint 는 PowerShell 5.1 에서 BOM 이 없으면 CP949 로 오독된다.
    $defaultPath = Join-Path $testRoot 'default-bom.json'
    Write-AgentSessionUtf8File -Path $defaultPath -Content '{"title":"기본값"}'
    $defaultBytes = [IO.File]::ReadAllBytes($defaultPath)
    Assert-True (Test-Utf8Bom $defaultBytes) '-NoBom 없는 기본 호출은 기존대로 BOM 을 유지해야 한다'

    # --- 11) 원문 정체성 검증 ---
    $mixed = Join-Path $testRoot 'mixed.jsonl'
    Write-AgentSessionUtf8File -Path $mixed -Content (@(
        ([ordered]@{ type = 'message'; sessionId = $ids.Held; timestamp = $fresh } | ConvertTo-Json -Compress),
        ([ordered]@{ type = 'message'; sessionId = $ids.New; timestamp = $fresh } | ConvertTo-Json -Compress)
    ) -join "`n")
    $tripped = $false
    try { [void](Get-ClaudeSessionCanonicalId $mixed) } catch { $tripped = $true }
    Assert-True $tripped '한 원문에 서로 다른 sessionId 가 섞이면 거부해야 한다'

    $renamed = Join-Path $repo "Claude\sessions\$key\77777777-7777-4777-8777-777777777777.jsonl"
    Write-TestTranscript $renamed $ids.Held $fresh
    $tripped = $false
    try { [void](Get-ClaudeTierInventory $repo) } catch { $tripped = $true }
    Assert-True $tripped 'Vault 원문의 파일명과 내부 sessionId 가 다르면 거부해야 한다'
    Remove-Item -LiteralPath $renamed -Force

    # --- 12) 한 원문에 목록 항목이 둘이면 임의로 고르지 않는다 ---
    Write-TestEntry $registry '99999999-8888-4888-8888-888888888888' $ids.Held
    $tripped = $false
    try { [void](Get-ClaudeEntriesByCanonicalId (Get-ClaudeNativeEntries $registry)) } catch { $tripped = $true }
    Assert-True $tripped '한 원문에 목록 항목이 둘 이상이면 중단해야 한다'
    Remove-Item -LiteralPath (Join-Path $registry 'workspace\window\local_99999999-8888-4888-8888-888888888888.json') -Force

    # --- 13) 앱 저장소 탐색은 읽기 전용이어야 한다 ---
    $registryBefore = Get-TreeFingerprint @($registry)
    [void](Get-ClaudeAppRegistryRoot -AllowMissing)
    Assert-True ((Get-TreeFingerprint @($registry)) -eq $registryBefore) '앱 저장소 탐색은 아무 파일도 만들지 않아야 한다'
    Assert-True (-not (@(Get-ChildItem -LiteralPath $registry -Recurse -Force -Filter '.assync-probe-*' -ErrorAction SilentlyContinue)).Count) '탐침 파일이 남으면 안 된다'

    # --- 11) checkpoint 는 보조 정보다. Vault HEAD 와 어긋나도 계획을 막지 않는다 ---
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'drift.txt') -Content 'drift'
    & git -C $repo add -A
    & git -C $repo commit -qm drift
    $driftPlan = New-ClaudeFinishPlan -Context (New-TestContext $repo $config) -PlanRoot $planRoot
    Assert-True ($null -ne $driftPlan) 'checkpoint 가 Vault HEAD 와 달라도 경고 후 Finish 계획을 만들어야 한다'

    # --- 12) Start 의 로컬 삭제는 checkpoint 가 아니라 Vault 계층이 정한다 ---
    # 예전 규칙은 "checkpoint.ActiveIds 에 있는데 지금 Vault Active 가 아니면 지운다" 였다.
    # 그러면 상대 머신이 아직 올리지 않은 대화나, Vault 가 아예 모르는 로컬 대화까지
    # Start 가 지운다. 새 규칙은 Vault Archived 에 같은 바이트가 있을 때만 내린다.
    $s2 = Join-Path $testRoot 'TierRule'
    $s2Repo = Join-Path $s2 'Vault'
    $s2Home = Join-Path $s2 'ClaudeHome'
    $s2Local = Join-Path $s2 'LocalA'
    $s2Roaming = Join-Path $s2 'RoamingA'
    $s2Registry = Join-Path $s2Roaming 'Claude\claude-code-sessions'
    New-Item -ItemType Directory -Path $s2Repo, $s2Home, $s2Local, $s2Registry -Force | Out-Null

    $tierIds = @{
        Active   = 'aaaa1111-1111-4111-8111-111111111111'  # Vault Active  → 유지
        Same     = 'bbbb2222-2222-4222-8222-222222222222'  # Vault Archived, 바이트 동일 → 내린다
        Diff     = 'cccc3333-3333-4333-8333-333333333333'  # Vault Archived, 바이트 다름  → 보존
        Unknown  = 'dddd4444-4444-4444-8444-444444444444'  # 어느 계층에도 없음          → 보존
    }
    $tierApps = @{
        Active  = 'aaaa1111-0000-4000-8000-000000000000'
        Same    = 'bbbb2222-0000-4000-8000-000000000000'
        Diff    = 'cccc3333-0000-4000-8000-000000000000'
        Unknown = 'dddd4444-0000-4000-8000-000000000000'
    }

    & git -C $s2Repo init -q
    & git -C $s2Repo config user.email 'test@example.com'
    & git -C $s2Repo config user.name 'test'
    Write-TestTranscript (Join-Path $s2Repo "Claude\sessions\$key\$($tierIds.Active).jsonl") $tierIds.Active $fresh
    Write-TestTranscript (Join-Path $s2Repo "Claude\archive\$key\$($tierIds.Same).jsonl") $tierIds.Same $stale
    Write-TestTranscript (Join-Path $s2Repo "Claude\archive\$key\$($tierIds.Diff).jsonl") $tierIds.Diff $stale
    Write-TestSidecar (Join-Path $s2Repo "Claude\sessions\$key\$($tierIds.Active).entry.json") $tierApps.Active $tierIds.Active
    Write-TestSidecar (Join-Path $s2Repo "Claude\archive\$key\$($tierIds.Same).entry.json") $tierApps.Same $tierIds.Same
    Write-TestSidecar (Join-Path $s2Repo "Claude\archive\$key\$($tierIds.Diff).entry.json") $tierApps.Diff $tierIds.Diff
    & git -C $s2Repo add -A
    & git -C $s2Repo commit -qm 'tier fixture'

    $oldLocal2 = $env:LOCALAPPDATA
    $oldRoaming2 = $env:APPDATA
    $env:LOCALAPPDATA = $s2Local
    $env:APPDATA = $s2Roaming
    try {
        # 로컬: Same 은 Vault Archived 와 바이트 동일, Diff 는 이후에 더 진행되어 달라졌다.
        Copy-Item (Join-Path $s2Repo "Claude\archive\$key\$($tierIds.Same).jsonl") `
                  (New-Item -ItemType Directory -Path (Join-Path $s2Home "projects\$key") -Force | ForEach-Object { Join-Path $_.FullName "$($tierIds.Same).jsonl" })
        Write-TestTranscript (Join-Path $s2Home "projects\$key\$($tierIds.Diff).jsonl") $tierIds.Diff $fresh
        Write-TestTranscript (Join-Path $s2Home "projects\$key\$($tierIds.Unknown).jsonl") $tierIds.Unknown $fresh
        Write-TestEntry $s2Registry $tierApps.Same $tierIds.Same
        Write-TestEntry $s2Registry $tierApps.Unknown $tierIds.Unknown

        # checkpoint 에는 Unknown 과 Same 이 활성으로 적혀 있다. 예전 규칙이라면 둘 다 지운다.
        Write-AgentSessionUtf8File -Path (Get-ClaudeCheckpointPath $s2Repo) -Content ([pscustomobject]@{
            schemaVersion = 1; commit = (Get-AgentSessionVaultHead $s2Repo)
            claudeActiveIds = @($tierIds.Unknown, $tierIds.Same)
            entryMap = @{}
        } | ConvertTo-Json -Depth 10)

        $s2Config = [pscustomobject]@{ ClaudeHome = $s2Home; ActiveWindowDays = 30 }
        $s2PlanRoot = New-AgentSessionPlanRoot -Prefix 'ClaudeTierRule'
        $tierPlan = New-ClaudeStartPlan -Context (New-TestContext $s2Repo $s2Config) -PlanRoot $s2PlanRoot

        $deleted = @($tierPlan.LocalOperations | Where-Object { $_.Kind -eq 'Delete' })
        $deletedTranscripts = @($deleted | Where-Object { $_.RelativePath -like '*.jsonl' } | ForEach-Object { $_.RelativePath })

        Assert-True ($deletedTranscripts.Count -eq 1) "Vault Archived 와 동일한 원문 하나만 내려야 한다 (실제 $($deletedTranscripts.Count)건)"
        Assert-True ($deletedTranscripts[0] -eq "projects/$key/$($tierIds.Same).jsonl") 'Archived 와 바이트가 같은 원문을 내려야 한다'
        Assert-True (@($deleted | Where-Object { $_.RelativePath -like "*$($tierIds.Unknown)*" }).Count -eq 0) `
            'Vault 가 모르는 로컬 원문은 checkpoint 에 활성으로 적혀 있어도 지우면 안 된다'
        Assert-True (@($deleted | Where-Object { $_.RelativePath -like "*$($tierIds.Diff)*" }).Count -eq 0) `
            'Archived 와 바이트가 다르면 아직 올라가지 않은 변경이므로 지우면 안 된다'
        Assert-True (@($deleted | Where-Object { $_.TargetRoot -eq 'ClaudeRegistry' -and $_.RelativePath -like "*$($tierApps.Same)*" }).Count -eq 1) `
            '원문을 내릴 때 목록 항목도 함께 내려야 한다'
        Assert-True (@($deleted | Where-Object { $_.TargetRoot -eq 'ClaudeRegistry' -and $_.RelativePath -like "*$($tierApps.Unknown)*" }).Count -eq 0) `
            '보존한 원문의 목록 항목은 남아 있어야 한다'

        # 결과값만으로는 사용자에게 닿지 않는다. 사유별로 묶인 경고가 함께 나와야 한다.
        $tierWarnings = @($tierPlan.Warnings)
        Assert-True ($tierWarnings.Count -eq 2) "보존 사유 두 종류가 각각 한 줄로 보고돼야 한다 (실제 $($tierWarnings.Count)줄)"
        Assert-True (@($tierWarnings | Where-Object { $_ -like "*$($tierIds.Unknown)*" -and $_ -like '*어느 계층에도 없어*' }).Count -eq 1) `
            'Vault 미지 보존이 사유와 함께 보고돼야 한다'
        Assert-True (@($tierWarnings | Where-Object { $_ -like "*$($tierIds.Diff)*" -and $_ -like '*미게시 변경*' }).Count -eq 1) `
            'Archived 불일치 보존이 사유와 함께 보고돼야 한다'
        Assert-True (-not (@($tierWarnings | Where-Object { $_ -like "*$($tierIds.Same)*" }).Count)) '내린 원문은 경고 대상이 아니다'

        $preserved = @($tierPlan.Result.PreservedLocalIds)
        Assert-True ($preserved -contains $tierIds.Unknown) '보존 사유를 결과로 보고해야 한다 (Vault 미지 원문)'
        Assert-True ($preserved -contains $tierIds.Diff) '보존 사유를 결과로 보고해야 한다 (Archived 와 불일치)'
        Assert-True (-not ($preserved -contains $tierIds.Same)) '내린 원문은 보존 목록에 들어가면 안 된다'
        Assert-True (-not ($preserved -contains $tierIds.Active)) 'Vault Active 는 보존 목록 대상이 아니다'
    }
    finally {
        $env:LOCALAPPDATA = $oldLocal2
        $env:APPDATA = $oldRoaming2
    }

    Write-Host "[PASS] ClaudeSessionState: $passed assertions" -ForegroundColor Green
    Write-Host '       계획 무변경, 첫 Start 전체 가드, 마커 전용 삭제, 마커 없는 부재 보존, 최종 상태 diff,' -ForegroundColor DarkGray
    Write-Host '       30일 아카이브, 복원·재노화, 미해결 마커 중단, 사이드카 검증, checkpoint 드리프트 비차단,' -ForegroundColor DarkGray
    Write-Host '       Start 로컬 삭제의 Vault 계층 기준화' -ForegroundColor DarkGray
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
