#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$ForceOwnership,
    [switch]$KeepBaton,
    [switch]$CheckOnly,
    [Alias('Full')][switch]$FullSecretScan
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ThisHost = $env:COMPUTERNAME
$LockFile = Join-Path $RepoRoot 'ACTIVE_HOST.txt'
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSessionState.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot
if (-not $Config.SessionDataPushEnabled) { throw 'Session push is disabled. Enable it only in a private Vault.' }

foreach ($required in @('New-CodexFinishPlan','New-CodexCheckpointPlan','New-ClaudeFinishPlan','New-ClaudeCheckpointPlan')) {
    if (-not (Get-Command $required -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Session adapter contract is incomplete: $required"
    }
}

$retriedPendingCommit = Prepare-AgentSessionVaultMutation -RepoRoot $RepoRoot
$active = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $active) { $active = 'NONE' }
if ($active -ne $ThisHost -and -not $ForceOwnership) {
    Write-Warning "baton 소유자는 $active 입니다($ThisHost 아님). 분기 시 자동 merge하지 않습니다."
}
if ($CheckOnly) { Write-Host "[OK] Vault and baton checked for $ThisHost." -ForegroundColor Green; return }

$PlanRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-Finish'
$vaultTransaction = $null
$vaultCommitted = $false
try {
    $baseCommit = Get-AgentSessionVaultHead $RepoRoot
    $context = [pscustomobject]@{
        SchemaVersion = 1
        RepoRoot = $RepoRoot
        Config = $Config
        VaultCommit = $baseCommit
        NowUtc = [DateTime]::UtcNow
        AllowCheckpointAncestor = [bool]$retriedPendingCommit
    }
    $codexPlanRoot = Join-Path $PlanRoot 'Codex'
    $claudePlanRoot = Join-Path $PlanRoot 'Claude'
    New-Item -ItemType Directory -Path $codexPlanRoot, $claudePlanRoot -Force | Out-Null
    $codexPlan = New-CodexFinishPlan -Context $context -PlanRoot $codexPlanRoot
    $claudePlan = New-ClaudeFinishPlan -Context $context -PlanRoot $claudePlanRoot

    $batonArtifact = Join-Path $PlanRoot 'ACTIVE_HOST.txt'
    $batonValue = if ($KeepBaton) { $ThisHost } else { 'NONE' }
    [IO.File]::WriteAllText($batonArtifact, $batonValue + [Environment]::NewLine, [Text.Encoding]::ASCII)
    $systemPlan = [pscustomobject]@{
        SchemaVersion = 1; Agent = 'System'; Phase = 'Finish'; ExpectedVaultCommit = $baseCommit; RootBindings = @{}
        VaultOperations = @((New-AgentSessionPutOperation -TargetRoot Vault -RelativePath 'ACTIVE_HOST.txt' -SourceKind StagedFile `
            -SourcePath $batonArtifact -SourceSha256 (Get-AgentSessionFileSha256 $batonArtifact)))
        LocalOperations = @(); Result = [pscustomobject]@{}; Warnings = @()
    }
    $plans = @($codexPlan, $claudePlan, $systemPlan)
    $rootMap = Get-AgentSessionRootMap -Plans $plans -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $plans -RootMap $rootMap -ExpectedVaultCommit $baseCommit -PlanRoot $PlanRoot

    $vaultOperations = @($plans | ForEach-Object { $_.VaultOperations })
    Assert-AgentSessionVaultSources -Operations $vaultOperations -RepoRoot $RepoRoot
    $vaultTransaction = Start-AgentSessionFileTransaction -RootMap $rootMap -TransactionRoot (Join-Path $PlanRoot 'VaultTransaction')
    Add-AgentSessionOperations -Transaction $vaultTransaction -Operations @(Get-AgentSessionOrderedOperations $vaultOperations) -RepoRoot $RepoRoot

    foreach ($path in @((Join-Path $RepoRoot 'Codex'), (Join-Path $RepoRoot 'Claude'))) {
        if (Test-Path -LiteralPath $path) { & (Join-Path $PSScriptRoot 'Test-SessionSecrets.ps1') -Paths @($path) -IncludeCompressed }
    }
    foreach ($operation in @($plans | ForEach-Object { $_.VaultOperations }) | Where-Object {
        $_.Kind -eq 'Put' -and $_.TargetRoot -eq 'Vault' -and $_.RelativePath -like '*.jsonl' -and
        ($_.RelativePath -match '^(Codex|Claude)/(sessions|archive)/')
    }) {
        Test-JsonlSnapshotComplete (Resolve-AgentSessionOperationTarget -Operation $operation -RootMap $rootMap)
    }

    $commit = Commit-AgentSessionVault -RepoRoot $RepoRoot -Message "sessions: finish $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $vaultCommitted = $true
    Complete-AgentSessionFileTransaction $vaultTransaction
    $published = Push-AgentSessionVault -RepoRoot $RepoRoot
    if (-not [string]::Equals($commit, $published, [StringComparison]::OrdinalIgnoreCase)) { throw 'Published commit mismatch.' }

    $publishedContext = [pscustomobject]@{
        SchemaVersion = 1; RepoRoot = $RepoRoot; Config = $Config; VaultCommit = $published
        NowUtc = $context.NowUtc; AllowCheckpointAncestor = $false
    }
    $localPlans = @($codexPlan, $claudePlan)
    $localRootMap = Get-AgentSessionRootMap -Plans $localPlans -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $localPlans -RootMap $localRootMap -ExpectedVaultCommit $baseCommit -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
    $localOperations = @($localPlans | ForEach-Object { $_.LocalOperations })
    Assert-AgentSessionVaultSources -Operations $localOperations -RepoRoot $RepoRoot
    $localTransaction = Start-AgentSessionFileTransaction -RootMap $localRootMap -TransactionRoot (Join-Path $PlanRoot 'LocalTransaction')
    try {
        Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations $localOperations) -RepoRoot $RepoRoot
        $codexCheckpointRoot = Join-Path $PlanRoot 'CodexCheckpoint'
        $claudeCheckpointRoot = Join-Path $PlanRoot 'ClaudeCheckpoint'
        New-Item -ItemType Directory -Path $codexCheckpointRoot, $claudeCheckpointRoot -Force | Out-Null
        $codexCheckpoint = New-CodexCheckpointPlan -Context $publishedContext -State $codexPlan.Result -PublishedCommit $published -PlanRoot $codexCheckpointRoot
        $claudeCheckpoint = New-ClaudeCheckpointPlan -Context $publishedContext -State $claudePlan.Result -PublishedCommit $published -PlanRoot $claudeCheckpointRoot
        $checkpointPlans = @($codexCheckpoint, $claudeCheckpoint)
        $checkpointRootMap = Get-AgentSessionRootMap -Plans @($localPlans + $checkpointPlans) -RepoRoot $RepoRoot
        Assert-AgentSessionPlans -Plans $checkpointPlans -RootMap $checkpointRootMap -ExpectedVaultCommit $published -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
        $checkpointOperations = @($checkpointPlans | ForEach-Object { $_.LocalOperations })
        Add-AgentSessionOperations -Transaction $localTransaction -Operations @(Get-AgentSessionOrderedOperations $checkpointOperations) -RepoRoot $RepoRoot
        Complete-AgentSessionFileTransaction $localTransaction
    } catch {
        if (-not $localTransaction.Completed) { Undo-AgentSessionFileTransaction $localTransaction }
        throw "Vault was published, but local completion failed. Run Start before continuing. $($_.Exception.Message)"
    }

    Write-Host "  [Codex] Active $($codexPlan.Result.ActiveIds.Count), Deleted $($codexPlan.Result.DeletedIds.Count), Archived $($codexPlan.Result.ArchivedIds.Count)" -ForegroundColor DarkCyan
    Write-Host "  [Claude] Active $($claudePlan.Result.ActiveIds.Count), Deleted $($claudePlan.Result.DeletedIds.Count), Archived $($claudePlan.Result.ArchivedIds.Count)" -ForegroundColor DarkCyan
    Write-Host "[OK] Finish published $published" -ForegroundColor Green
} catch {
    if ($vaultTransaction -and -not $vaultTransaction.Completed -and -not $vaultCommitted) {
        Undo-AgentSessionFileTransaction $vaultTransaction
    }
    throw
} finally {
    if (Test-Path -LiteralPath $PlanRoot) { Remove-Item -LiteralPath $PlanRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
$global:LASTEXITCODE = 0
