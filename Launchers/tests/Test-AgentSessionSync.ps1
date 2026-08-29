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
function Write-Rollout([string]$Path, [string]$Id, [string]$Cwd, [string]$Timestamp, [switch]$IdOnly,
        [string]$SessionId = '', [string]$BasePageId = '', [Nullable[int64]]$BaseEndByte = $null,
        [Nullable[int64]]$BaseEndOrdinal = $null) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $payload = [ordered]@{id=$Id;cwd=$Cwd}
    if (-not $IdOnly) { $payload.session_id = if ($SessionId) { $SessionId } else { $Id } }
    if ($BasePageId) {
        $payload.history_mode = 'paginated'
        $payload.history_base = [ordered]@{
            thread_id=$BasePageId
            end_byte_offset=[int64]$BaseEndByte
            end_ordinal_exclusive=[int64]$BaseEndOrdinal
        }
    }
    $meta = [ordered]@{ type='session_meta';payload=$payload;timestamp=$Timestamp;ordinal=0 } | ConvertTo-Json -Compress
    $message = [ordered]@{ type='event_msg';payload=[ordered]@{type='message'};timestamp=$Timestamp;ordinal=1 } | ConvertTo-Json -Compress
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
    $duplicateDir = Join-Path $repo "Codex\sessions\$key\2026\08\24"
    New-Item -ItemType Directory -Path $duplicateDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo "Codex\sessions\$key\2026\08\25\rollout-a.jsonl") -Destination (Join-Path $duplicateDir 'rollout-a.jsonl')
    $duplicateRejected = $false
    try { [void](Get-CodexSessionGroups (Join-Path $repo 'Codex\sessions')) } catch { $duplicateRejected = $true }
    Assert-True $duplicateRejected 'duplicate logical rollout filename in different paths was accepted'
    Remove-Item -LiteralPath $duplicateDir -Recurse -Force
    $legacyVaultRaw = Join-Path $repo "Codex\sessions\$key\2026\08\25\rollout-a.jsonl"
    Compress-JsonlTransportFile -Source $legacyVaultRaw -Destination ($legacyVaultRaw + '.gz')
    Remove-Item -LiteralPath $legacyVaultRaw -Force
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

    # Synthetic transport fixtures are written with their intended bytes from the outset.
    $transportRoot = Join-Path $root 'Transport'
    New-Item -ItemType Directory -Path $transportRoot -Force | Out-Null
    $rawTransport = Join-Path $transportRoot 'raw.jsonl'
    [IO.File]::WriteAllText($rawTransport, "{`"type`":`"event_msg`"}`n", [Text.UTF8Encoding]::new($false))
    $gzipTransport = Join-Path $transportRoot 'raw.jsonl.gz'
    Compress-JsonlTransportFile -Source $rawTransport -Destination $gzipTransport
    $integrityArtifact = New-CompressedJsonlIntegrityArtifact -Raw $rawTransport -Compressed $gzipTransport -PlanRoot $transportRoot -Name 'raw'
    Assert-True (Test-CompressedJsonlTransportCurrent -Source $rawTransport -Compressed $gzipTransport -IntegrityPath $integrityArtifact.Path) 'gzip cache requires matching raw and gzip SHA-256 plus lengths'
    $differentRaw = Join-Path $transportRoot 'different.jsonl'
    [IO.File]::WriteAllText($differentRaw, "{`"type`":`"different`"}`n", [Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-CompressedJsonlTransportCurrent -Source $differentRaw -Compressed $gzipTransport -IntegrityPath $integrityArtifact.Path)) 'gzip cache rejects a different raw payload'
    $expandedTransport = Join-Path $transportRoot 'expanded.jsonl'
    Assert-True (Expand-JsonlTransportFile -Source $gzipTransport -Destination $expandedTransport -IntegrityPath $integrityArtifact.Path) 'verified gzip expands successfully'
    Assert-True ((Get-AgentSessionFileSha256 $expandedTransport) -eq (Get-AgentSessionFileSha256 $rawTransport)) 'expanded gzip reproduces the exact raw bytes'
    $corruptGzip = Join-Path $transportRoot 'corrupt.jsonl.gz'
    [IO.File]::WriteAllBytes($corruptGzip, [IO.File]::ReadAllBytes($gzipTransport))
    $corruptBytes = [IO.File]::ReadAllBytes($corruptGzip)
    $corruptBytes[$corruptBytes.Length - 1] = $corruptBytes[$corruptBytes.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($corruptGzip, $corruptBytes)
    $corruptRejected = $false
    try { [void](Expand-JsonlTransportFile -Source $corruptGzip -Destination (Join-Path $transportRoot 'corrupt-expanded.jsonl') -IntegrityPath $integrityArtifact.Path) } catch { $corruptRejected = $true }
    Assert-True $corruptRejected 'gzip restore rejects corrupted compressed bytes before expansion'
    $legacyExpanded = Join-Path $transportRoot 'legacy-expanded.jsonl'
    Assert-True (Expand-JsonlTransportFile -Source $gzipTransport -Destination $legacyExpanded) 'legacy gzip without integrity metadata still expands after gzip and JSONL validation'
    Assert-True ((Get-AgentSessionFileSha256 $legacyExpanded) -eq (Get-AgentSessionFileSha256 $rawTransport)) 'legacy gzip expansion preserves the exact raw bytes'

    $transportRepo = Join-Path $root 'TransportRepo'
    $transportClone = Join-Path $root 'TransportClone'
    New-Item -ItemType Directory -Path $transportRepo -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $launchers) '.gitattributes') -Destination (Join-Path $transportRepo '.gitattributes')
    [IO.File]::WriteAllBytes((Join-Path $transportRepo 'native-lf.jsonl'), [Text.UTF8Encoding]::new($false).GetBytes("{`"eol`":`"lf`"}`n"))
    [IO.File]::WriteAllBytes((Join-Path $transportRepo 'native-crlf.jsonl'), [Text.UTF8Encoding]::new($false).GetBytes("{`"eol`":`"crlf`"}`r`n"))
    [IO.File]::WriteAllBytes((Join-Path $transportRepo 'native.entry.json'), [Text.UTF8Encoding]::new($false).GetBytes("{`"entry`":true}`r`n"))
    & git -C $transportRepo init -q
    & git -C $transportRepo config user.email test@example.com
    & git -C $transportRepo config user.name Test
    & git -C $transportRepo add -A
    & git -C $transportRepo commit -qm transport
    & git -c core.autocrlf=true clone -q $transportRepo $transportClone
    foreach ($name in @('native-lf.jsonl','native-crlf.jsonl','native.entry.json')) {
        Assert-True ((Get-AgentSessionFileSha256 (Join-Path $transportRepo $name)) -eq (Get-AgentSessionFileSha256 (Join-Path $transportClone $name))) "Git checkout preserves exact transport bytes: $name"
    }

    # Diverged Vault histories rejoin, preserve unique paths and both parents, and prefer this host for overlaps.
    $mergeRemote = Join-Path $root 'MergeRemote.git'
    $mergeLocal = Join-Path $root 'MergeLocal'
    $mergePeer = Join-Path $root 'MergePeer'
    & git init --bare -q $mergeRemote
    & git clone -q $mergeRemote $mergeLocal
    & git -C $mergeLocal config user.email test@example.com
    & git -C $mergeLocal config user.name Test
    Write-AgentSessionUtf8File -Path (Join-Path $mergeLocal 'same.txt') -Content 'base'
    & git -C $mergeLocal add -A
    & git -C $mergeLocal commit -qm base
    & git -C $mergeLocal push -qu origin HEAD
    & git clone -q $mergeRemote $mergePeer
    & git -C $mergePeer config user.email test@example.com
    & git -C $mergePeer config user.name Test
    Write-AgentSessionUtf8File -Path (Join-Path $mergeLocal 'same.txt') -Content 'local'
    Write-AgentSessionUtf8File -Path (Join-Path $mergeLocal 'local.txt') -Content 'local-only'
    & git -C $mergeLocal add -A
    & git -C $mergeLocal commit -qm local
    Write-AgentSessionUtf8File -Path (Join-Path $mergePeer 'same.txt') -Content 'remote'
    Write-AgentSessionUtf8File -Path (Join-Path $mergePeer 'remote.txt') -Content 'remote-only'
    & git -C $mergePeer add -A
    & git -C $mergePeer commit -qm remote
    & git -C $mergePeer push -q
    Assert-True (Prepare-AgentSessionVaultMutation -RepoRoot $mergeLocal) 'diverged Vault histories merge and publish'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $mergeLocal 'same.txt')).Trim() -eq 'local') 'overlapping path prefers the current host copy'
    Assert-True ((Test-Path -LiteralPath (Join-Path $mergeLocal 'local.txt')) -and (Test-Path -LiteralPath (Join-Path $mergeLocal 'remote.txt'))) 'divergent unique paths are both preserved'
    $mergeParents = @(& git -C $mergeLocal rev-list --parents -n 1 HEAD)[0].Split(' ').Count - 1
    Assert-True ($mergeParents -eq 2) 'automatic convergence preserves both merge parents'
    Assert-True (((& git -C $mergeLocal rev-parse HEAD).Trim()) -eq ((& git -C $mergeLocal rev-parse '@{upstream}').Trim())) 'automatic convergence verifies the published remote head'

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

    # Start must not replace a local append-only continuation with a stale Vault prefix. Replacing
    # the prefix invalidates Codex thread_history byte offsets and hides every projected turn after
    # the stale boundary.
    $localA = Join-Path $codexHome 'sessions\2026\08\25\rollout-a.jsonl'
    $localLengthBeforeSuffix = (Get-Item -LiteralPath $localA).Length
    Add-Content -LiteralPath $localA -Value '{"type":"event_msg","payload":{"type":"local_suffix"},"timestamp":"2026-08-25T00:00:01.000Z"}' -Encoding UTF8
    $suffixLength = (Get-Item -LiteralPath $localA).Length
    $appendStartRoot = Join-Path $root 'AppendStartPlan'
    New-Item -ItemType Directory -Path $appendStartRoot -Force | Out-Null
    $appendStart = New-CodexStartPlan -Context (New-Context $repo $config) -PlanRoot $appendStartRoot
    Assert-True (@($appendStart.LocalOperations | Where-Object RelativePath -eq 'sessions/2026/08/25/rollout-a.jsonl').Count -eq 0) 'Start does not overwrite a local append-only suffix with the Vault prefix'
    Assert-True (@($appendStart.Warnings).Count -eq 1) 'Start reports the preserved local append-only suffix'
    Apply-PlanOperations @($appendStart) LocalOperations $repo (Join-Path $root 'AppendStartTxn') $appendStartRoot
    Assert-True ((Get-Item -LiteralPath $localA).Length -eq $suffixLength -and $suffixLength -gt $localLengthBeforeSuffix) 'Start preserves the complete local append-only rollout'

    $divergent = [IO.File]::ReadAllBytes($localA)
    $divergent[0] = if ($divergent[0] -eq 123) { 91 } else { 123 }
    [IO.File]::WriteAllBytes($localA, $divergent)
    $divergenceRejected = $false
    try { [void](New-CodexStartPlan -Context (New-Context $repo $config) -PlanRoot (Join-Path $root 'DivergentStartPlan')) } catch { $divergenceRejected = $true }
    Assert-True $divergenceRejected 'Start refuses a non-append rollout divergence instead of overwriting local history'

    # A is deleted. B is a two-page live thread. C is a stale new thread.
    Remove-Item -LiteralPath (Join-Path $codexHome 'sessions') -Recurse -Force
    $idBPage2 = '77777777-7777-4777-8777-777777777777'
    $idBRootPath = Join-Path $codexHome "sessions\2026\08\25\rollout-2026-08-25T00-00-00-$idB.jsonl"
    Write-Rollout $idBRootPath $idB $cwd $fresh
    $idBRootBytes = [IO.File]::ReadAllBytes($idBRootPath)
    $idBFirstBoundary = [Array]::IndexOf($idBRootBytes, [byte]10) + 1
    Write-Rollout (Join-Path $codexHome "sessions\2026\08\25\rollout-2026-08-25T00-01-00-${idB}_$idBPage2.jsonl") $idBPage2 $cwd $fresh `
        -SessionId $idB -BasePageId $idB -BaseEndByte $idBFirstBoundary -BaseEndOrdinal 1
    [IO.File]::AppendAllText($idBRootPath, (([ordered]@{type='event_msg';payload=[ordered]@{type='synthetic_large';text=('x' * 5000)};timestamp=$fresh;ordinal=2} | ConvertTo-Json -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Rollout (Join-Path $codexHome 'archived_sessions\2026\05\01\rollout-c.jsonl') $idC $cwd $stale
    @(
        ([ordered]@{id=$idB;title='B'} | ConvertTo-Json -Compress),
        ([ordered]@{id=$idC;title='C'} | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath (Join-Path $codexHome 'session_index.jsonl') -Encoding UTF8

    $finishRoot = Join-Path $root 'FinishPlan'
    New-Item -ItemType Directory -Path $finishRoot -Force | Out-Null
    $config.TransportFileLimitBytes = 1000
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

    $cachedGzip = Join-Path $repo "Codex\sessions\$key\2026\08\25\rollout-2026-08-25T00-00-00-$idB.jsonl.gz"
    Assert-True ((Test-Path -LiteralPath $cachedGzip) -and (Test-Path -LiteralPath (Get-CompressedJsonlIntegrityPath $cachedGzip))) 'first Finish publishes gzip with raw and gzip integrity metadata'
    $secondFinishRoot = Join-Path $root 'SecondFinishPlan'
    New-Item -ItemType Directory -Path $secondFinishRoot -Force | Out-Null
    $secondFinish = New-CodexFinishPlan -Context (New-Context $repo $config) -PlanRoot $secondFinishRoot
    Assert-True (@(Get-ChildItem -LiteralPath $secondFinishRoot -File -Recurse -Filter '*.gz').Count -eq 0) 'unchanged second Finish reuses verified gzip without recompression'

    # A stale checkpoint is advisory only and cannot authorize deletion inferred from local absence.
    Write-AgentSessionUtf8File -Path (Join-Path $repo 'tooling-drift.txt') -Content 'drift'
    & git -C $repo add -A
    & git -C $repo commit -qm tooling-drift
    Remove-Item -LiteralPath (Join-Path $codexHome 'sessions') -Recurse -Force
    $staleFinishRoot = Join-Path $root 'StaleFinishPlan'
    New-Item -ItemType Directory -Path $staleFinishRoot -Force | Out-Null
    $staleFinish = New-CodexFinishPlan -Context (New-Context $repo $config) -PlanRoot $staleFinishRoot
    Assert-True (@($staleFinish.Result.DeletedIds).Count -eq 0) 'stale checkpoint plus locally absent ID never infers deletion'

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
