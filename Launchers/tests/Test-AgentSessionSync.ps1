#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$launchers = Split-Path -Parent $PSScriptRoot
. (Join-Path $launchers 'AgentSessionSync.Common.ps1')
. (Join-Path $launchers 'CodexSessionState.Common.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AgentSessionSync-Contract-' + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA

function Write-TestRollout {
    param([string]$Path, [string]$Id, [string]$Timestamp, [string]$Cwd = 'C:\Project\Demo')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $meta = [ordered]@{
        timestamp = $Timestamp
        type = 'session_meta'
        payload = [ordered]@{ id = $Id; session_id = $Id; cwd = $Cwd }
    } | ConvertTo-Json -Compress
    $event = [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{ type = 'user_message' }
    } | ConvertTo-Json -Compress
    @($meta, $event) | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
    $repo = Join-Path $testRoot 'Vault'
    $remote = Join-Path $testRoot 'Remote.git'
    $codexA = Join-Path $testRoot 'CodexA'
    $codexB = Join-Path $testRoot 'CodexB'
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalA'
    New-Item -ItemType Directory -Path $repo, $codexA, $codexB, $env:LOCALAPPDATA -Force | Out-Null

    $fresh = [DateTime]::UtcNow.ToString('o')
    $ids = @{
        Deleted = '01a00000-0000-7000-8000-000000000001'
        Held = '01a00000-0000-7000-8000-000000000002'
        Aged = '01a00000-0000-7000-8000-000000000003'
        New = '01a00000-0000-7000-8000-000000000004'
    }
    $activeRoot = Join-Path $repo 'Codex\sessions\C--Project-Demo\2026\08\24'
    Write-TestRollout (Join-Path $activeRoot 'rollout-deleted.jsonl') $ids.Deleted $fresh
    Write-TestRollout (Join-Path $activeRoot 'rollout-held-page1.jsonl') $ids.Held $fresh
    Write-TestRollout (Join-Path $activeRoot 'rollout-held-page2.jsonl') $ids.Held $fresh
    Write-TestRollout (Join-Path $activeRoot 'rollout-aged.jsonl') $ids.Aged '2026-06-01T00:00:00Z'

    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    & git init --bare -q $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -qu origin HEAD

    $configA = [pscustomobject]@{ CodexHome = $codexA; ActiveWindowDays = 30 }
    [void](Invoke-CodexStartState -RepoRoot $repo -Config $configA)
    $local = Get-CodexSessionGroups (Join-Path $codexA 'sessions')
    if ($local.Count -ne 3 -or $local[$ids.Held].Files.Count -ne 2) {
        throw 'Start did not group and materialize every page by canonical ID.'
    }

    'pending' | Set-Content -LiteralPath (Join-Path $repo 'pending-test.txt') -Encoding ASCII
    & git -C $repo add pending-test.txt
    & git -C $repo commit -qm 'pending previous finish'
    $retriedPending = Prepare-AgentSessionVaultMutation -RepoRoot $repo
    if (-not $retriedPending) { throw 'A local-only pending commit was not retried.' }

    Remove-CodexGroupFiles $local[$ids.Deleted]
    $held = (Get-CodexSessionGroups (Join-Path $codexA 'sessions'))[$ids.Held]
    $nativeArchive = Join-Path $codexA 'archived_sessions'
    New-Item -ItemType Directory -Path $nativeArchive -Force | Out-Null
    foreach ($file in $held.Files) { Move-Item $file.FullName (Join-Path $nativeArchive $file.Name) }
    Write-TestRollout (Join-Path $codexA 'sessions\2026\08\24\rollout-new.jsonl') $ids.New $fresh

    $result = Invoke-CodexFinishCollect -RepoRoot $repo -Config $configA -AllowCheckpointAncestor:$retriedPending
    $tiers = Get-CodexTierInventory $repo
    if ($tiers.Active.ContainsKey($ids.Deleted)) { throw 'A finally deleted session remained in Vault Active.' }
    if (-not $tiers.Active.ContainsKey($ids.Held)) { throw 'Native archived_sessions was treated as a Vault state signal.' }
    if (-not $tiers.Active.ContainsKey($ids.New)) { throw 'A local-only new session was lost.' }
    if (-not $tiers.Archived.ContainsKey($ids.Aged)) { throw 'An aged session was not moved to Vault Archived.' }

    & git -C $repo add -A
    & git -C $repo commit -qm finish
    Complete-CodexFinishState -RepoRoot $repo -Config $configA -Result $result

    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalB'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    $configB = [pscustomobject]@{ CodexHome = $codexB; ActiveWindowDays = 30 }
    [void](Invoke-CodexStartState -RepoRoot $repo -Config $configB)
    $received = Get-CodexSessionGroups (Join-Path $codexB 'sessions')
    if ($received.ContainsKey($ids.Deleted) -or $received.ContainsKey($ids.Aged)) {
        throw 'Deleted or Vault Archived data was materialized on the second PC.'
    }
    if (-not $received.ContainsKey($ids.Held) -or -not $received.ContainsKey($ids.New)) {
        throw 'Vault Active did not materialize on the second PC.'
    }

    $beforeRestore = Get-CodexTierInventory $repo
    Move-CodexVaultGroup -RepoRoot $repo -Group $beforeRestore.Archived[$ids.Aged] -SourceRoot (Join-Path $repo 'Codex\archive') -TargetRoot (Join-Path $repo 'Codex\sessions')
    Publish-AgentSessionVault -RepoRoot $repo -Message ('sessions: restore ' + $ids.Aged)
    [void](Invoke-CodexStartState -RepoRoot $repo -Config $configB)
    $afterRestore = Get-CodexTierInventory $repo
    $receivedAfterRestore = Get-CodexSessionGroups (Join-Path $codexB 'sessions')
    if (-not $afterRestore.Active.ContainsKey($ids.Aged) -or $afterRestore.Archived.ContainsKey($ids.Aged) -or
        -not $receivedAfterRestore.ContainsKey($ids.Aged)) {
        throw 'Restore did not commit an exclusive Archived-to-Active transition and materialize it locally.'
    }

    Write-Host '[PASS] Codex Active, Archived, Deleted, Restore, native archive existence, pending push retry, new-session preservation, and multi-page grouping.' -ForegroundColor Green
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
