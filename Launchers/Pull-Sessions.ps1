#requires -Version 5.1
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ThisHost = $env:COMPUTERNAME
$LockFile = Join-Path $RepoRoot 'ACTIVE_HOST.txt'
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSessionState.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot

foreach ($required in @('New-CodexStartPlan','New-CodexCheckpointPlan','New-ClaudeStartPlan','New-ClaudeCheckpointPlan')) {
    if (-not (Get-Command $required -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Session adapter contract is incomplete: $required"
    }
}

& git -C $RepoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Vault pull --ff-only failed.' }
$dirty = @(& git -C $RepoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Vault must be clean before Start claims the baton.' }

$active = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $active) { $active = 'NONE' }
if ($active -ne 'NONE' -and $active -ne $ThisHost) {
    Write-Warning "다른 호스트($active)가 baton을 쥔 상태입니다. 원격 분기 시 자동 merge하지 않습니다."
}
[IO.File]::WriteAllText($LockFile, $ThisHost + [Environment]::NewLine, [Text.Encoding]::ASCII)
$claimCommit = Commit-AgentSessionVault -RepoRoot $RepoRoot -Message "claim by $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$published = Push-AgentSessionVault -RepoRoot $RepoRoot
if (-not [string]::Equals($claimCommit, $published, [StringComparison]::OrdinalIgnoreCase)) { throw 'Baton claim verification failed.' }

$PlanRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-Start'
$transaction = $null
try {
    $context = [pscustomobject]@{
        SchemaVersion = 1
        RepoRoot = $RepoRoot
        Config = $Config
        VaultCommit = $published
        NowUtc = [DateTime]::UtcNow
        AllowCheckpointAncestor = $false
    }
    $codexPlanRoot = Join-Path $PlanRoot 'Codex'
    $claudePlanRoot = Join-Path $PlanRoot 'Claude'
    New-Item -ItemType Directory -Path $codexPlanRoot, $claudePlanRoot -Force | Out-Null
    $codexPlan = New-CodexStartPlan -Context $context -PlanRoot $codexPlanRoot
    $claudePlan = New-ClaudeStartPlan -Context $context -PlanRoot $claudePlanRoot
    $plans = @($codexPlan, $claudePlan)
    $rootMap = Get-AgentSessionRootMap -Plans $plans -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $plans -RootMap $rootMap -ExpectedVaultCommit $published -PlanRoot $PlanRoot

    $startOperations = @($plans | ForEach-Object { $_.LocalOperations })
    Assert-AgentSessionVaultSources -Operations $startOperations -RepoRoot $RepoRoot
    $transaction = Start-AgentSessionFileTransaction -RootMap $rootMap -TransactionRoot (Join-Path $PlanRoot 'LocalTransaction')
    Add-AgentSessionOperations -Transaction $transaction -Operations @(Get-AgentSessionOrderedOperations $startOperations) -RepoRoot $RepoRoot

    $codexCheckpointRoot = Join-Path $PlanRoot 'CodexCheckpoint'
    $claudeCheckpointRoot = Join-Path $PlanRoot 'ClaudeCheckpoint'
    New-Item -ItemType Directory -Path $codexCheckpointRoot, $claudeCheckpointRoot -Force | Out-Null
    $codexCheckpoint = New-CodexCheckpointPlan -Context $context -State $codexPlan.Result -PublishedCommit $published -PlanRoot $codexCheckpointRoot
    $claudeCheckpoint = New-ClaudeCheckpointPlan -Context $context -State $claudePlan.Result -PublishedCommit $published -PlanRoot $claudeCheckpointRoot
    $checkpointPlans = @($codexCheckpoint, $claudeCheckpoint)
    $checkpointRootMap = Get-AgentSessionRootMap -Plans @($plans + $checkpointPlans) -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $checkpointPlans -RootMap $checkpointRootMap -ExpectedVaultCommit $published -PlanRoot $PlanRoot -OperationProperties @('LocalOperations')
    $checkpointOperations = @($checkpointPlans | ForEach-Object { $_.LocalOperations })
    Add-AgentSessionOperations -Transaction $transaction -Operations @(Get-AgentSessionOrderedOperations $checkpointOperations) -RepoRoot $RepoRoot
    Complete-AgentSessionFileTransaction $transaction

    Write-Host "  [Codex] Active $($codexPlan.Result.ActiveIds.Count)" -ForegroundColor DarkCyan
    Write-Host "  [Claude] Active $($claudePlan.Result.ActiveIds.Count)" -ForegroundColor DarkCyan
} catch {
    if ($transaction -and -not $transaction.Completed) { Undo-AgentSessionFileTransaction $transaction }
    throw
} finally {
    if (Test-Path -LiteralPath $PlanRoot) { Remove-Item -LiteralPath $PlanRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

try {
    & (Join-Path $PSScriptRoot 'Repair-CodexThreadVisibility.ps1') -CodexHome $Config.CodexHome
} catch {
    Write-Warning "Codex sidebar best-effort repair failed: $($_.Exception.Message)"
}
Write-Host "[OK] Start completed on $ThisHost." -ForegroundColor Green
$global:LASTEXITCODE = 0
