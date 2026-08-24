#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$launchers = Split-Path -Parent $PSScriptRoot
. (Join-Path $launchers 'AgentSessionSync.Common.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('AgentSessionPlan-' + [guid]::NewGuid().ToString('N'))
$passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED [#$($script:passed + 1)]: $Message" }
    $script:passed++
}

try {
    $repo = Join-Path $root 'Vault'
    $local = Join-Path $root 'Local'
    $planRoot = Join-Path $root 'Plan'
    New-Item -ItemType Directory -Path $repo, $local, $planRoot -Force | Out-Null
    'vault-source' | Set-Content -LiteralPath (Join-Path $repo 'source.txt') -Encoding UTF8
    'vault-source-2' | Set-Content -LiteralPath (Join-Path $repo 'source2.txt') -Encoding UTF8
    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    $commit = Get-AgentSessionVaultHead $repo

    $vaultPut = New-AgentSessionPutOperation -TargetRoot Local -RelativePath 'from-vault.txt' -SourceKind VaultFile `
        -SourceRelativePath 'source.txt' -SourceCommit $commit -SourceSha256 (Get-AgentSessionFileSha256 (Join-Path $repo 'source.txt'))
    $plan = [pscustomobject]@{ SchemaVersion=1;Agent='Test';Phase='Start';ExpectedVaultCommit=$commit;RootBindings=@{Local=$local};VaultOperations=@();LocalOperations=@($vaultPut);Result=[pscustomobject]@{};Warnings=@() }
    $map = Get-AgentSessionRootMap -Plans @($plan) -RepoRoot $repo
    Assert-AgentSessionPlans -Plans @($plan) -RootMap $map -ExpectedVaultCommit $commit -PlanRoot $planRoot
    Assert-AgentSessionVaultSources -Operations @($vaultPut) -RepoRoot $repo
    Assert-True $true 'valid plan is accepted'

    $transaction = Start-AgentSessionFileTransaction -RootMap $map -TransactionRoot (Join-Path $root 'Txn1')
    Add-AgentSessionOperations -Transaction $transaction -Operations @($vaultPut) -RepoRoot $repo
    Complete-AgentSessionFileTransaction $transaction
    Assert-True ((Get-Content -LiteralPath (Join-Path $local 'from-vault.txt') -Raw).Trim() -eq 'vault-source') 'VaultFile Put copies the committed source'

    $duplicate = [pscustomobject]@{ SchemaVersion=1;Agent='Test2';Phase='Start';ExpectedVaultCommit=$commit;RootBindings=@{Local=$local};VaultOperations=@();LocalOperations=@($vaultPut);Result=[pscustomobject]@{};Warnings=@() }
    $duplicateRejected = $false
    try { Assert-AgentSessionPlans -Plans @($plan,$duplicate) -RootMap $map -ExpectedVaultCommit $commit -PlanRoot $planRoot } catch { $duplicateRejected = $true }
    Assert-True $duplicateRejected 'duplicate TargetRoot plus RelativePath is rejected'

    $escapeRejected = $false
    try { [void](New-AgentSessionDeleteOperation -TargetRoot Local -RelativePath '../escape.txt' | ForEach-Object { Resolve-AgentSessionOperationTarget -Operation $_ -RootMap $map }) } catch { $escapeRejected = $true }
    Assert-True $escapeRejected 'relative path escape is rejected'

    'outside' | Set-Content -LiteralPath (Join-Path $local 'outside.txt') -Encoding UTF8
    $outside = New-AgentSessionPutOperation -TargetRoot Local -RelativePath 'outside-copy.txt' -SourceKind StagedFile `
        -SourcePath (Join-Path $local 'outside.txt') -SourceSha256 (Get-AgentSessionFileSha256 (Join-Path $local 'outside.txt'))
    $outsidePlan = [pscustomobject]@{ SchemaVersion=1;Agent='Test';Phase='Start';ExpectedVaultCommit=$commit;RootBindings=@{Local=$local};VaultOperations=@();LocalOperations=@($outside);Result=[pscustomobject]@{};Warnings=@() }
    $outsideRejected = $false
    try { Assert-AgentSessionPlans -Plans @($outsidePlan) -RootMap $map -ExpectedVaultCommit $commit -PlanRoot $planRoot } catch { $outsideRejected = $true }
    Assert-True $outsideRejected 'StagedFile outside PlanRoot is rejected'

    $move1 = New-AgentSessionPutOperation -TargetRoot Vault -RelativePath 'copy1.txt' -SourceKind VaultFile `
        -SourceRelativePath 'source.txt' -SourceCommit $commit -SourceSha256 (Get-AgentSessionFileSha256 (Join-Path $repo 'source.txt'))
    $move2 = New-AgentSessionPutOperation -TargetRoot Vault -RelativePath 'copy2.txt' -SourceKind VaultFile `
        -SourceRelativePath 'source2.txt' -SourceCommit $commit -SourceSha256 (Get-AgentSessionFileSha256 (Join-Path $repo 'source2.txt'))
    Assert-AgentSessionVaultSources -Operations @($move1,$move2) -RepoRoot $repo
    $transaction = Start-AgentSessionFileTransaction -RootMap $map -TransactionRoot (Join-Path $root 'TxnVaultFiles')
    Add-AgentSessionOperations -Transaction $transaction -Operations @($move1,$move2) -RepoRoot $repo
    Assert-True ((Test-Path (Join-Path $repo 'copy1.txt')) -and (Test-Path (Join-Path $repo 'copy2.txt'))) 'multiple VaultFile sources apply after one clean preflight'
    Undo-AgentSessionFileTransaction $transaction

    'original' | Set-Content -LiteralPath (Join-Path $local 'existing.txt') -Encoding UTF8
    'replacement' | Set-Content -LiteralPath (Join-Path $planRoot 'replacement.txt') -Encoding UTF8
    'new-file' | Set-Content -LiteralPath (Join-Path $planRoot 'new.txt') -Encoding UTF8
    $replace = New-AgentSessionPutOperation -TargetRoot Local -RelativePath 'existing.txt' -SourceKind StagedFile `
        -SourcePath (Join-Path $planRoot 'replacement.txt') -SourceSha256 (Get-AgentSessionFileSha256 (Join-Path $planRoot 'replacement.txt'))
    $new = New-AgentSessionPutOperation -TargetRoot Local -RelativePath 'new.txt' -SourceKind StagedFile `
        -SourcePath (Join-Path $planRoot 'new.txt') -SourceSha256 ('0' * 64)
    $transaction = Start-AgentSessionFileTransaction -RootMap $map -TransactionRoot (Join-Path $root 'Txn2')
    $failed = $false
    try { Add-AgentSessionOperations -Transaction $transaction -Operations @($replace,$new) -RepoRoot $repo } catch { $failed = $true; Undo-AgentSessionFileTransaction $transaction }
    Assert-True $failed 'changed staged source hash aborts the transaction'
    Assert-True ((Get-Content -LiteralPath (Join-Path $local 'existing.txt') -Raw).Trim() -eq 'original') 'rollback restores the exact previous file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $local 'new.txt'))) 'rollback removes a newly created target'

    'dirty' | Set-Content -LiteralPath (Join-Path $repo 'dirty.txt') -Encoding UTF8
    $dirtyRejected = $false
    $transaction = Start-AgentSessionFileTransaction -RootMap $map -TransactionRoot (Join-Path $root 'Txn3')
    try { Assert-AgentSessionVaultSources -Operations @($vaultPut) -RepoRoot $repo } catch { $dirtyRejected = $true; Undo-AgentSessionFileTransaction $transaction }
    Assert-True $dirtyRejected 'VaultFile source requires a clean Vault worktree'

    Write-Host "[PASS] Plan engine: $passed assertions" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
