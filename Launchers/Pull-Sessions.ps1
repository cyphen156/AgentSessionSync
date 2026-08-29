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

function New-AgentSessionStartPlanSet {
    param([Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$Root)
    $context = [pscustomobject]@{
        SchemaVersion = 1
        RepoRoot = $RepoRoot
        Config = $Config
        VaultCommit = $Commit
        NowUtc = [DateTime]::UtcNow
        AllowCheckpointAncestor = $false
    }
    $codexRoot = Join-Path $Root 'Codex'
    $claudeRoot = Join-Path $Root 'Claude'
    New-Item -ItemType Directory -Path $codexRoot, $claudeRoot -Force | Out-Null
    $codexPlan = New-CodexStartPlan -Context $context -PlanRoot $codexRoot
    $claudePlan = New-ClaudeStartPlan -Context $context -PlanRoot $claudeRoot
    $plans = @($codexPlan, $claudePlan)
    $rootMap = Get-AgentSessionRootMap -Plans $plans -RepoRoot $RepoRoot
    Assert-AgentSessionPlans -Plans $plans -RootMap $rootMap -ExpectedVaultCommit $Commit -PlanRoot $Root
    $operations = @($plans | ForEach-Object { $_.LocalOperations })
    Assert-AgentSessionVaultSources -Operations $operations -RepoRoot $RepoRoot
    [pscustomobject]@{ Context=$context;CodexPlan=$codexPlan;ClaudePlan=$claudePlan;Plans=$plans;RootMap=$rootMap;Operations=$operations }
}

function Undo-AgentSessionBatonClaim {
    param([Parameter(Mandatory)][string]$ClaimCommit, [Parameter(Mandatory)][string]$PreviousOwner)
    $head = Get-AgentSessionVaultHead $RepoRoot
    $upstream = (& git -C $RepoRoot rev-parse '@{u}' 2>$null | Select-Object -First 1)
    $currentOwner = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $dirtyNow = @(& git -C $RepoRoot status --porcelain)
    if (-not [string]::Equals($head,$ClaimCommit,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($upstream,$ClaimCommit,[StringComparison]::OrdinalIgnoreCase) -or
        $currentOwner -ne $ThisHost -or $dirtyNow) {
        Write-Warning 'Start 실패 후 baton 자동 해제 안전 조건이 맞지 않습니다. Vault 상태를 수동 확인하세요.'
        return
    }
    [IO.File]::WriteAllText($LockFile, $PreviousOwner + [Environment]::NewLine, [Text.Encoding]::ASCII)
    $releaseCommit = Commit-AgentSessionVault -RepoRoot $RepoRoot -Message "release failed claim by $ThisHost @ $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $released = Push-AgentSessionVault -RepoRoot $RepoRoot
    if (-not [string]::Equals($releaseCommit,$released,[StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning 'Start 실패 후 baton 해제 커밋의 원격 검증에 실패했습니다.'
    }
}

& git -C $RepoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Vault pull --ff-only failed.' }
$dirty = @(& git -C $RepoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Vault must be clean before Start claims the baton.' }

$preflightRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-StartPreflight'
try {
    $preflightCommit = Get-AgentSessionVaultHead $RepoRoot
    [void](New-AgentSessionStartPlanSet -Commit $preflightCommit -Root $preflightRoot)
} finally {
    if (Test-Path -LiteralPath $preflightRoot) { Remove-Item -LiteralPath $preflightRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

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
$claimActive = $true
try {
    $startSet = New-AgentSessionStartPlanSet -Commit $published -Root $PlanRoot
    $context = $startSet.Context
    $codexPlan = $startSet.CodexPlan
    $claudePlan = $startSet.ClaudePlan
    $plans = $startSet.Plans
    $rootMap = $startSet.RootMap
    $startOperations = $startSet.Operations
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
    $claimActive = $false

    Write-Host "  [Codex] Active $($codexPlan.Result.ActiveIds.Count)" -ForegroundColor DarkCyan
    Write-Host "  [Claude] Active $($claudePlan.Result.ActiveIds.Count)" -ForegroundColor DarkCyan
} catch {
    if ($transaction -and -not $transaction.Completed) { Undo-AgentSessionFileTransaction $transaction }
    if ($claimActive) {
        try { Undo-AgentSessionBatonClaim -ClaimCommit $claimCommit -PreviousOwner $active }
        catch { Write-Warning "Start 실패 후 baton 자동 해제 중 오류가 발생했습니다: $($_.Exception.Message)" }
    }
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
