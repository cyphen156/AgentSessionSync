#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Query = '',
    [ValidateSet('Codex','Claude')][string]$Agent = ''
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'AgentLauncher.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot

foreach ($required in @('New-CodexRestorePlan','New-CodexCheckpointPlan','New-ClaudeRestorePlan','New-ClaudeCheckpointPlan')) {
    if (-not (Get-Command $required -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Session adapter contract is incomplete: $required"
    }
}

$retried = Prepare-AgentSessionVaultMutation -RepoRoot $RepoRoot
if ($retried) { throw 'A pending Vault commit was published. Run Start before Restore so local state and both checkpoints catch up.' }
$baseCommit = Get-AgentSessionVaultHead $RepoRoot
$context = [pscustomobject]@{SchemaVersion=1;RepoRoot=$RepoRoot;Config=$Config;VaultCommit=$baseCommit;NowUtc=[DateTime]::UtcNow;AllowCheckpointAncestor=$false}

$candidates = @()
$codexTiers = Get-CodexTierInventory $RepoRoot
foreach ($group in $codexTiers.Archived.Values) {
    $candidates += [pscustomobject]@{Agent='Codex';SessionId=$group.Id;Folder=$group.CwdKey;SizeMB=[math]::Round((($group.Files | Measure-Object Length -Sum).Sum / 1MB),2)}
}
$claudeArchive = Join-Path $RepoRoot 'Claude\archive'
if (Test-Path -LiteralPath $claudeArchive) {
    $archiveFull = [IO.Path]::GetFullPath($claudeArchive).TrimEnd('\','/')
    foreach ($file in @(Get-ChildItem -LiteralPath $claudeArchive -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
        $candidates += [pscustomobject]@{Agent='Claude';SessionId=$file.BaseName;Folder=(Split-Path -Parent $file.FullName).Substring($archiveFull.Length).TrimStart('\','/');SizeMB=[math]::Round($file.Length/1MB,2)}
    }
}
if ($Agent) { $candidates = @($candidates | Where-Object Agent -eq $Agent) }
if (-not $Query) {
    if (-not $candidates) { Write-Host 'Vault Archived is empty.' -ForegroundColor DarkGray; return }
    $candidates | Sort-Object Agent,Folder,SessionId | Format-Table Agent,Folder,SessionId,SizeMB -AutoSize
    Write-Host 'Restore: Restore-ArchivedSession.ps1 <session-id-or-part> [-Agent Codex|Claude]' -ForegroundColor DarkGray
    return
}
$matched = @($candidates | Where-Object { $_.SessionId -like "*$Query*" -or $_.Folder -like "*$Query*" })
if (-not $matched) { throw "No archived session matches '$Query'." }
if ($matched.Count -ne 1) {
    $matched | Format-Table Agent,Folder,SessionId,SizeMB -AutoSize
    throw 'Restore query must select exactly one session. Narrow the query or specify -Agent.'
}
$selected = $matched[0]
$PlanRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-Restore'
$vaultTransaction = $null
$vaultCommitted = $false
try {
    $adapterPlanRoot = Join-Path $PlanRoot $selected.Agent
    New-Item -ItemType Directory -Path $adapterPlanRoot -Force | Out-Null
    $restorePlan = if ($selected.Agent -eq 'Codex') {
        New-CodexRestorePlan -Context $context -PlanRoot $adapterPlanRoot -SessionId $selected.SessionId
    } else {
        New-ClaudeRestorePlan -Context $context -PlanRoot $adapterPlanRoot -SessionId $selected.SessionId
    }
    $rootMap = Get-AgentSessionRootMap -Plans @($restorePlan) -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans @($restorePlan) -RootMap $rootMap -ExpectedVaultCommit $baseCommit -PlanRoot $PlanRoot
    Assert-AgentSessionVaultSources -Operations @($restorePlan.VaultOperations) -RepoRoot $RepoRoot
    $vaultTransaction = Start-AgentSessionFileTransaction -RootMap $rootMap -TransactionRoot (Join-Path $PlanRoot 'VaultTransaction')
    Add-AgentSessionOperations -Transaction $vaultTransaction -Operations @(Get-AgentSessionOrderedOperations @($restorePlan.VaultOperations)) -RepoRoot $RepoRoot
    # Restore moves already-scanned Vault payloads; Finish -FullSecretScan remains the explicit rescan path.
    $commit = Commit-AgentSessionVault -RepoRoot $RepoRoot -Message "sessions: restore $($selected.Agent) $($selected.SessionId)"
    $vaultCommitted = $true
    Complete-AgentSessionFileTransaction $vaultTransaction
    $published = Push-AgentSessionVault -RepoRoot $RepoRoot
    if (-not [string]::Equals($commit,$published,[StringComparison]::OrdinalIgnoreCase)) { throw 'Restore publish verification failed.' }

    # The network operation is complete before the app is asked to close. A close failure
    # leaves the Vault valid and defers local materialization to the next Start.
    $registered = @((Get-RegisteredAgents $RepoRoot) | Where-Object Name -eq $selected.Agent | Select-Object -First 1)
    if (-not $registered) { throw "Vault restore succeeded, but no enabled $($selected.Agent) launcher is registered. Run Start." }
    Assert-CurrentProcessOutsideAgentTrees $registered
    try {
        Stop-AgentGracefully -Agent $registered[0] -TimeoutSeconds ([int]$Config.GracefulCloseTimeoutSeconds)
        Assert-AllAgentsClosed $registered
    } catch {
        throw "Vault restore succeeded, but $($selected.Agent) did not close. Local restore was not applied. Close it and run Start. $($_.Exception.Message)"
    }

    $publishedContext = [pscustomobject]@{SchemaVersion=1;RepoRoot=$RepoRoot;Config=$Config;VaultCommit=$published;NowUtc=$context.NowUtc;AllowCheckpointAncestor=$false}
    $localPlans = @($restorePlan)
    $localRootMap = Get-AgentSessionRootMap -Plans $localPlans -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $localPlans -RootMap $localRootMap -ExpectedVaultCommit $baseCommit -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
    Assert-AgentSessionVaultSources -Operations @($restorePlan.LocalOperations) -RepoRoot $RepoRoot
    $localTransaction = Start-AgentSessionFileTransaction -RootMap $localRootMap -TransactionRoot (Join-Path $PlanRoot 'LocalTransaction')
    try {
        Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations @($restorePlan.LocalOperations)) -RepoRoot $RepoRoot
        $codexState = if ($selected.Agent -eq 'Codex') { $restorePlan.Result } else { $null }
        $claudeState = if ($selected.Agent -eq 'Claude') { $restorePlan.Result } else { $null }
        $codexCheckpointRoot = Join-Path $PlanRoot 'CodexCheckpoint'
        $claudeCheckpointRoot = Join-Path $PlanRoot 'ClaudeCheckpoint'
        New-Item -ItemType Directory -Path $codexCheckpointRoot,$claudeCheckpointRoot -Force | Out-Null
        $codexCheckpoint = New-CodexCheckpointPlan -Context $publishedContext -State $codexState -PublishedCommit $published -PlanRoot $codexCheckpointRoot
        $claudeCheckpoint = New-ClaudeCheckpointPlan -Context $publishedContext -State $claudeState -PublishedCommit $published -PlanRoot $claudeCheckpointRoot
        $checkpointPlans = @($codexCheckpoint,$claudeCheckpoint)
        $checkpointRootMap = Get-AgentSessionRootMap -Plans @($localPlans + $checkpointPlans) -RepoRoot $RepoRoot
        Assert-AgentSessionPlans -Plans $checkpointPlans -RootMap $checkpointRootMap -ExpectedVaultCommit $published -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
        $checkpointOperations = @($checkpointPlans | ForEach-Object { $_.LocalOperations })
        Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations $checkpointOperations) -RepoRoot $RepoRoot
        Complete-AgentSessionFileTransaction $localTransaction
    } catch {
        if (-not $localTransaction.Completed) { Undo-AgentSessionFileTransaction $localTransaction }
        throw "Vault restore is published, but local completion failed. Run Start. $($_.Exception.Message)"
    }

    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($registered[0].AppId)"
    Write-Host "[OK] Restored $($selected.Agent) $($selected.SessionId) at $published" -ForegroundColor Green
    Write-Host 'Sidebar visibility is best-effort. Update or restart the app and run Start if needed.' -ForegroundColor DarkGray
} catch {
    if ($vaultTransaction -and -not $vaultTransaction.Completed -and -not $vaultCommitted) { Undo-AgentSessionFileTransaction $vaultTransaction }
    throw
} finally {
    if (Test-Path -LiteralPath $PlanRoot) { Remove-Item -LiteralPath $PlanRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
