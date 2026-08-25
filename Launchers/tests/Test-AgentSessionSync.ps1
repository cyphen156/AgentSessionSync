#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$launchers = Split-Path -Parent $PSScriptRoot
. (Join-Path $launchers 'AgentSessionSync.Common.ps1')
. (Join-Path $launchers 'CodexSessionState.Common.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('CodexSessionPlan-' + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
$passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED [#$($script:passed + 1)]: $Message" }
    $script:passed++
}
function Write-Rollout([string]$Path, [string]$Id, [string]$Cwd, [string]$Timestamp, [switch]$IdOnly, [string]$SessionId = '') {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $payload = [ordered]@{id=$Id;cwd=$Cwd}
    if (-not $IdOnly) { $payload.session_id = if ($SessionId) { $SessionId } else { $Id } }
    $meta = [ordered]@{ type='session_meta';payload=$payload;timestamp=$Timestamp } | ConvertTo-Json -Compress
    $message = [ordered]@{ type='event_msg';payload=[ordered]@{type='message'};timestamp=$Timestamp } | ConvertTo-Json -Compress
    @($meta,$message) | Set-Content -LiteralPath $Path -Encoding UTF8
}
function New-Context([string]$Repo, $Config, [bool]$AllowAncestor = $false) {
    [pscustomobject]@{ SchemaVersion=1;RepoRoot=$Repo;Config=$Config;VaultCommit=(Get-AgentSessionVaultHead $Repo);NowUtc=[DateTime]::UtcNow;AllowCheckpointAncestor=$AllowAncestor }
}
function Apply-PlanOperations($Plans, [string]$Property, [string]$Repo, [string]$TxnRoot, [string]$PlanRoot) {
    $map = Get-AgentSessionRootMap -Plans $Plans -RepoRoot $Repo
    Assert-AgentSessionPlans -Plans $Plans -RootMap $map -ExpectedVaultCommit ([string]$Plans[0].ExpectedVaultCommit) -PlanRoot $PlanRoot -OperationProperties @($Property)
    $transaction = Start-AgentSessionFileTransaction -RootMap $map -TransactionRoot $TxnRoot
    try {
        $operations = @($Plans | ForEach-Object { $_.$Property })
        Add-AgentSessionOperations -Transaction $transaction -Operations @(Get-AgentSessionOrderedOperations $operations) -RepoRoot $Repo
        Complete-AgentSessionFileTransaction $transaction
    } catch {
        if (-not $transaction.Completed) { Undo-AgentSessionFileTransaction $transaction }
        throw
    }
}

try {
    $repo = Join-Path $root 'Vault'
    $remote = Join-Path $root 'Remote.git'
    $codexHome = Join-Path $root 'CodexHome'
    $env:LOCALAPPDATA = Join-Path $root 'LocalAppData'
    New-Item -ItemType Directory -Path $repo, $codexHome, $env:LOCALAPPDATA -Force | Out-Null
    $cwd = 'C:\Project\Demo'
    $key = ConvertTo-SessionPathKey $cwd
    $fresh = [DateTime]::UtcNow.ToString('o')
    $stale = '2026-05-01T00:00:00.000Z'
    $idA = '11111111-1111-4111-8111-111111111111'
    $idB = '22222222-2222-4222-8222-222222222222'
    $idC = '33333333-3333-4333-8333-333333333333'
    $idOnly = '44444444-4444-4444-8444-444444444444'
    $idOnlyPath = Join-Path $root 'IdOnly\rollout-id-only.jsonl'
    Write-Rollout $idOnlyPath $idOnly $cwd $fresh -IdOnly
    Assert-True ((Get-CodexSessionMeta $idOnlyPath).Id -eq $idOnly) 'session_meta accepts payload.id when session_id is absent under StrictMode'
    $pageId = '55555555-5555-4555-8555-555555555555'
    $threadId = '66666666-6666-4666-8666-666666666666'
    $legacyPagePath = Join-Path $root 'LegacyPage\rollout-page.jsonl'
    Write-Rollout $legacyPagePath $pageId $cwd $fresh -SessionId $threadId
    Assert-True ((Get-CodexSessionMeta $legacyPagePath).Id -eq $threadId) 'session_meta prefers session_id as the canonical thread when id identifies a page'
    Write-Rollout (Join-Path $repo "Codex\sessions\$key\2026\08\25\rollout-a.jsonl") $idA $cwd $fresh
    [ordered]@{id=$idA;title='A'} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $repo 'Codex\session_index.jsonl') -Encoding UTF8
    'NONE' | Set-Content -LiteralPath (Join-Path $repo 'ACTIVE_HOST.txt') -Encoding ASCII
    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    & git init --bare -q $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -qu origin HEAD

    $config = [pscustomobject]@{ CodexHome=$codexHome;ClaudeHome=(Join-Path $root 'ClaudeHome');ActiveWindowDays=30;TransportFileLimitBytes=99614720 }

    # First Start rejects any pre-existing local session without a checkpoint.
    Write-Rollout (Join-Path $codexHome 'sessions\2026\08\25\residue.jsonl') '99999999-9999-4999-8999-999999999999' $cwd $fresh
    $guard = $false
    try { [void](New-CodexStartPlan -Context (New-Context $repo $config) -PlanRoot (Join-Path $root 'GuardPlan')) } catch { $guard = $true }
    Assert-True $guard 'first Start rejects residual Codex state'
    Remove-Item -LiteralPath (Join-Path $codexHome 'sessions') -Recurse -Force

    $startRoot = Join-Path $root 'StartPlan'
    New-Item -ItemType Directory -Path $startRoot -Force | Out-Null
    $context = New-Context $repo $config
    $start = New-CodexStartPlan -Context $context -PlanRoot $startRoot
    Assert-True (-not (& git -C $repo status --porcelain)) 'Start planning does not mutate the Vault'
    Apply-PlanOperations @($start) LocalOperations $repo (Join-Path $root 'StartTxn') $startRoot
    $checkpointRoot = Join-Path $root 'StartCheckpoint'
    New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
    $checkpoint = New-CodexCheckpointPlan -Context $context -State $start.Result -PublishedCommit $context.VaultCommit -PlanRoot $checkpointRoot
    Apply-PlanOperations @($checkpoint) LocalOperations $repo (Join-Path $root 'CheckpointTxn') $checkpointRoot
    Assert-True ((Get-CodexSessionGroups (Join-Path $codexHome 'sessions')).ContainsKey($idA)) 'Start materializes Vault Active locally'
    Assert-True ((Read-CodexCheckpoint $repo).ActiveIds -contains $idA) 'Start checkpoint records the active ID'

    # A is deleted. B is a two-page live thread. C is a stale new thread.
    Remove-Item -LiteralPath (Join-Path $codexHome 'sessions') -Recurse -Force
    Write-Rollout (Join-Path $codexHome 'sessions\2026\08\25\rollout-b-page1.jsonl') $idB $cwd $fresh
    Write-Rollout (Join-Path $codexHome 'sessions\2026\08\25\rollout-b-page2.jsonl') $idB $cwd $fresh
    Write-Rollout (Join-Path $codexHome 'archived_sessions\2026\05\01\rollout-c.jsonl') $idC $cwd $stale
    @(
        ([ordered]@{id=$idB;title='B'} | ConvertTo-Json -Compress),
        ([ordered]@{id=$idC;title='C'} | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath (Join-Path $codexHome 'session_index.jsonl') -Encoding UTF8

    $finishRoot = Join-Path $root 'FinishPlan'
    New-Item -ItemType Directory -Path $finishRoot -Force | Out-Null
    $context = New-Context $repo $config
    $finish = New-CodexFinishPlan -Context $context -PlanRoot $finishRoot
    Assert-True (-not (& git -C $repo status --porcelain)) 'Finish planning does not mutate the Vault'
    Assert-True ($finish.Result.DeletedIds -contains $idA) 'missing native Codex session is deleted'
    Assert-True ($finish.Result.ActiveIds -contains $idB) 'live multi-page thread remains active'
    Assert-True ($finish.Result.ArchivedIds -contains $idC) 'stale thread passing through the app archive is preserved in the Vault archive'
    Assert-True (@($finish.VaultOperations | Group-Object { "$($_.TargetRoot)|$($_.RelativePath)" } | Where-Object Count -gt 1).Count -eq 0) 'Finish emits one operation per target'

    Apply-PlanOperations @($finish) VaultOperations $repo (Join-Path $root 'FinishVaultTxn') $finishRoot
    $commit = Commit-AgentSessionVault -RepoRoot $repo -Message finish
    $published = Push-AgentSessionVault $repo
    Assert-True ($commit -eq $published) 'Finish commit is verified at the remote'
    Apply-PlanOperations @($finish) LocalOperations $repo (Join-Path $root 'FinishLocalTxn') $finishRoot
    $publishedContext = [pscustomobject]@{SchemaVersion=1;RepoRoot=$repo;Config=$config;VaultCommit=$published;NowUtc=$context.NowUtc;AllowCheckpointAncestor=$false}
    $checkpointRoot = Join-Path $root 'FinishCheckpoint'
    New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
    $checkpoint = New-CodexCheckpointPlan -Context $publishedContext -State $finish.Result -PublishedCommit $published -PlanRoot $checkpointRoot
    Apply-PlanOperations @($checkpoint) LocalOperations $repo (Join-Path $root 'FinishCheckpointTxn') $checkpointRoot
    $tiers = Get-CodexTierInventory $repo
    Assert-True (-not $tiers.Active.ContainsKey($idA)) 'deleted thread is absent from both final active state'
    Assert-True ($tiers.Active.ContainsKey($idB) -and $tiers.Active[$idB].Files.Count -eq 2) 'multi-page thread is grouped and preserved'
    Assert-True ($tiers.Archived.ContainsKey($idC)) 'aged thread exists only in archive'
    Assert-True ((Get-CodexSessionGroups (Join-Path $codexHome 'sessions')).Keys.Count -eq 1) 'post-publish local cleanup leaves the final active set'
    Assert-True ((Get-CodexSessionGroups (Join-Path $codexHome 'archived_sessions')).Count -eq 0) 'post-publish cleanup removes the app archive copy'

    # Restore is also a plan and does not mutate until the common transaction applies it.
    $restoreRoot = Join-Path $root 'RestorePlan'
    New-Item -ItemType Directory -Path $restoreRoot -Force | Out-Null
    $restoreContext = New-Context $repo $config
    $restore = New-CodexRestorePlan -Context $restoreContext -PlanRoot $restoreRoot -SessionId $idC
    Assert-True ((Get-CodexTierInventory $repo).Archived.ContainsKey($idC)) 'Restore planning leaves Vault archive untouched'
    Apply-PlanOperations @($restore) VaultOperations $repo (Join-Path $root 'RestoreVaultTxn') $restoreRoot
    $restoreCommit = Commit-AgentSessionVault -RepoRoot $repo -Message restore
    [void](Push-AgentSessionVault $repo)
    Apply-PlanOperations @($restore) LocalOperations $repo (Join-Path $root 'RestoreLocalTxn') $restoreRoot
    Assert-True ((Get-CodexTierInventory $repo).Active.ContainsKey($idC)) 'Restore moves the final Vault state to active'
    Assert-True ((Get-CodexSessionGroups (Join-Path $codexHome 'sessions')).ContainsKey($idC)) 'Restore materializes the session locally after publish'

    Write-Host "[PASS] Codex session plans: $passed assertions" -ForegroundColor Green
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
