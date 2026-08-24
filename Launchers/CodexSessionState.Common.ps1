Set-StrictMode -Version Latest

function Get-CodexSessionGroups {
    param([Parameter(Mandatory)][string]$Root)
    $groups = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $groups }
    $candidates = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' })
    $files = @($candidates | Group-Object { $_.FullName -replace '\.gz$', '' } | ForEach-Object {
        $raw = @($_.Group | Where-Object Name -like '*.jsonl' | Select-Object -First 1)
        if ($raw) { $raw[0] } else { $_.Group[0] }
    })
    foreach ($file in $files) {
        $meta = Get-CodexSessionMeta $file.FullName
        $cwdKey = if ([string]::IsNullOrWhiteSpace($meta.Cwd)) { '_no-cwd' } else { ConvertTo-ClaudeProjectKey $meta.Cwd }
        if (-not $groups.ContainsKey($meta.Id)) {
            $groups[$meta.Id] = [pscustomobject]@{
                Id = [string]$meta.Id
                CwdKey = $cwdKey
                Files = New-Object 'Collections.Generic.List[object]'
            }
        } elseif (-not [string]::Equals($groups[$meta.Id].CwdKey, $cwdKey, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Codex canonical ID가 서로 다른 cwd를 가리킵니다: $($meta.Id)"
        }
        [void]$groups[$meta.Id].Files.Add($file)
    }
    return $groups
}

function Get-CodexTierInventory {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $active = Get-CodexSessionGroups (Join-Path $RepoRoot 'Codex\sessions')
    $archived = Get-CodexSessionGroups (Join-Path $RepoRoot 'Codex\archive')
    foreach ($id in $active.Keys) {
        if ($archived.ContainsKey($id)) { throw "Codex 세션이 Active와 Archived에 동시에 있습니다: $id" }
    }
    [pscustomobject]@{ Active = $active; Archived = $archived }
}

function Get-CodexCheckpointPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($RepoRoot)).ToLowerInvariant()))
        $key = -join @($bytes | ForEach-Object { $_.ToString('x2') })
    } finally { $algorithm.Dispose() }
    Join-Path (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State') ($key + '.json')
}

function Read-CodexCheckpoint {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-CodexCheckpointPath $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Exists = $false; Commit = ''; ActiveIds = @() }
    }
    try {
        $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$value.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$value.commit)) {
            throw '지원하지 않는 checkpoint 형식입니다.'
        }
        [pscustomobject]@{
            Exists = $true
            Commit = [string]$value.commit
            ActiveIds = @($value.codexActiveIds | ForEach-Object { [string]$_ })
        }
    } catch { throw "Codex checkpoint를 읽을 수 없습니다: $path ($($_.Exception.Message))" }
}

function Write-CodexCheckpoint {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$ActiveIds
    )
    $commit = [string](& git -C $RepoRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) { throw 'Vault HEAD를 읽을 수 없습니다.' }
    $path = Get-CodexCheckpointPath $RepoRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $temporary = $path + '.tmp'
    [pscustomobject]@{
        schemaVersion = 1
        commit = $commit.Trim()
        codexActiveIds = @($ActiveIds | Sort-Object -Unique)
        writtenAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Remove-CodexGroupFiles {
    param([Parameter(Mandatory)]$Group)
    foreach ($file in $Group.Files) {
        if (Test-Path -LiteralPath $file.FullName) { Remove-Item -LiteralPath $file.FullName -Force }
    }
}

function Remove-CodexNativeIds {
    param([Parameter(Mandatory)][string[]]$Roots, [Parameter(Mandatory)][string[]]$Ids)
    $wanted = @{}
    foreach ($id in $Ids) { $wanted[$id] = $true }
    $removed = 0
    foreach ($root in $Roots) {
        $groups = Get-CodexSessionGroups $root
        foreach ($id in $wanted.Keys) {
            if (-not $groups.ContainsKey($id)) { continue }
            $removed += $groups[$id].Files.Count
            Remove-CodexGroupFiles $groups[$id]
        }
    }
    return $removed
}

function Copy-CodexNativeGroupToVault {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$NativeRoot,
        [Parameter(Mandatory)][string]$VaultActiveRoot
    )
    $sourceRoot = [IO.Path]::GetFullPath($NativeRoot).TrimEnd('\', '/')
    foreach ($file in $Group.Files) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $target = Join-Path (Join-Path $VaultActiveRoot $Group.CwdKey) $relative
        Copy-OpenFileSnapshot -Source $file.FullName -Destination $target
    }
}

function Copy-CodexVaultGroupToNative {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$VaultRoot,
        [Parameter(Mandatory)][string]$NativeRoot
    )
    foreach ($file in $Group.Files) {
        $relative = Get-CodexNativeRelativePath -TransportRoot $VaultRoot -Path $file.FullName
        if ($file.Name -like '*.jsonl.gz') { $relative = $relative.Substring(0, $relative.Length - 3) }
        $target = Join-Path $NativeRoot $relative
        if ($file.Name -like '*.jsonl.gz') {
            [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $target)
        } else {
            [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($target))))
            [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
        }
    }
}

function Move-CodexVaultGroup {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )
    $sourceFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
    $repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    foreach ($file in $Group.Files) {
        $inside = $file.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
        $sourceRelative = $file.FullName.Substring($repoFull.Length).TrimStart('\', '/').Replace('\', '/')
        $targetFull = Join-Path $TargetRoot $inside
        $targetRelative = $targetFull.Substring($repoFull.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-Path -LiteralPath $targetFull) { throw "Codex 계층 이동 대상이 이미 있습니다: $targetFull" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetFull) -Force | Out-Null
        if (@(& git -C $RepoRoot ls-files -- $sourceRelative)) {
            & git -C $RepoRoot mv -- $sourceRelative $targetRelative
            if ($LASTEXITCODE -ne 0) { throw "Codex 계층 이동에 실패했습니다: $sourceRelative" }
        } else { Move-Item -LiteralPath $file.FullName -Destination $targetFull }
    }
}

function Get-CodexGroupLastActivity {
    param([Parameter(Mandatory)]$Group)
    $latest = $null
    foreach ($file in $Group.Files) {
        $candidate = Get-JsonlLastActivity $file.FullName
        if ($candidate -and ($null -eq $latest -or $candidate -gt $latest)) { $latest = $candidate }
    }
    return $latest
}

function Get-CodexIndexLinesById {
    param([string[]]$Paths)
    $byId = @{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $entry = $line | ConvertFrom-Json; $id = [string]$entry.id }
            catch { throw "Codex index JSON을 읽을 수 없습니다: $path" }
            if ($id) { $byId[$id] = $line }
        }
    }
    return $byId
}

function Write-FilteredCodexIndex {
    param(
        [Parameter(Mandatory)][string[]]$Inputs,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string[]]$AllowedIds
    )
    $allowed = @{}
    foreach ($id in $AllowedIds) { $allowed[$id] = $true }
    $lines = Get-CodexIndexLinesById $Inputs
    $selected = @($lines.Keys | Where-Object { $allowed.ContainsKey($_) } | Sort-Object | ForEach-Object { $lines[$_] })
    Write-CodexIndexLines -Path $Output -Lines $selected
}

function Assert-CheckpointAtVaultHead {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Checkpoint,
        [switch]$AllowAncestor
    )
    $head = ([string](& git -C $RepoRoot rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Vault HEAD를 읽을 수 없습니다.' }
    if (-not $Checkpoint.Exists) {
        throw '이 PC의 마지막 Start/Restore checkpoint가 현재 Vault HEAD와 다릅니다. Start를 먼저 실행하세요.'
    }
    if ([string]::Equals($Checkpoint.Commit, $head, [StringComparison]::OrdinalIgnoreCase)) { return }
    if ($AllowAncestor) {
        & git -C $RepoRoot merge-base --is-ancestor $Checkpoint.Commit $head
        if ($LASTEXITCODE -eq 0) { return }
    }
    throw '이 PC의 마지막 Start/Restore checkpoint가 현재 Vault HEAD와 다릅니다. Start를 먼저 실행하세요.'
}

function Prepare-AgentSessionVaultMutation {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Vault working tree 상태를 확인할 수 없습니다.' }
    if ($dirty) { throw 'Vault working tree에 미커밋 변경이 있습니다. 자동으로 포함하지 않으므로 먼저 정리하세요.' }
    & git -C $RepoRoot fetch --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Vault 원격 상태를 확인할 수 없습니다.' }
    $head = ([string](& git -C $RepoRoot rev-parse HEAD)).Trim()
    $upstream = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Vault upstream을 확인할 수 없습니다.' }
    if ([string]::Equals($head, $upstream, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    & git -C $RepoRoot merge-base --is-ancestor $upstream $head
    if ($LASTEXITCODE -eq 0) {
        & git -C $RepoRoot push
        if ($LASTEXITCODE -ne 0) { throw '미전송 Vault commit Push가 거부됐습니다. 자동 merge하지 않습니다.' }
        & git -C $RepoRoot fetch --quiet
        $verified = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
        if (-not [string]::Equals($head, $verified, [StringComparison]::OrdinalIgnoreCase)) {
            throw '미전송 Vault commit의 원격 반영을 확인하지 못했습니다.'
        }
        return $true
    }

    & git -C $RepoRoot merge-base --is-ancestor $head $upstream
    if ($LASTEXITCODE -eq 0) { throw '원격 Vault가 앞서 있습니다. Finish/Restore가 아니라 Start를 먼저 실행하세요.' }
    throw '로컬과 원격 Vault가 분기됐습니다. 자동 merge하지 않습니다.'
}

function Publish-AgentSessionVault {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Message)
    & git -C $RepoRoot add -A
    if ($LASTEXITCODE -ne 0) { throw 'Vault git add에 실패했습니다.' }
    & git -C $RepoRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        & git -C $RepoRoot commit -q -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'Vault commit에 실패했습니다.' }
    }
    & git -C $RepoRoot push
    if ($LASTEXITCODE -ne 0) {
        throw 'Vault push가 거부됐습니다. 자동 merge하지 않습니다. 로컬 commit은 재시도를 위해 유지됩니다.'
    }
    & git -C $RepoRoot fetch --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Push 후 원격 확인 fetch에 실패했습니다.' }
    $head = ([string](& git -C $RepoRoot rev-parse HEAD)).Trim()
    $upstream = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($head, $upstream, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Push 후 HEAD와 원격 branch가 일치하지 않습니다. 로컬 정리와 checkpoint 갱신을 중단합니다.'
    }
}

function Invoke-CodexStartState {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Config)
    $tiers = Get-CodexTierInventory $RepoRoot
    $nativeActiveRoot = Join-Path $Config.CodexHome 'sessions'
    $nativeArchivedRoot = Join-Path $Config.CodexHome 'archived_sessions'
    $localActiveBefore = Get-CodexSessionGroups $nativeActiveRoot
    $localArchivedBefore = Get-CodexSessionGroups $nativeArchivedRoot
    $checkpoint = Read-CodexCheckpoint $RepoRoot
    if (-not $checkpoint.Exists -and ($localActiveBefore.Count -gt 0 -or $localArchivedBefore.Count -gt 0)) {
        throw '첫 Start 전에 Codex sessions와 archived_sessions를 비워야 합니다. 초기 정리 절차를 먼저 실행하세요.'
    }
    $vaultActiveIds = @($tiers.Active.Keys)
    if ($checkpoint.Exists) {
        $absent = @($checkpoint.ActiveIds | Where-Object { $vaultActiveIds -notcontains $_ })
        if ($absent) { [void](Remove-CodexNativeIds -Roots @($nativeActiveRoot, $nativeArchivedRoot) -Ids $absent) }
    }
    if ($vaultActiveIds) {
        [void](Remove-CodexNativeIds -Roots @($nativeArchivedRoot) -Ids $vaultActiveIds)
        foreach ($id in $vaultActiveIds) {
            Copy-CodexVaultGroupToNative -Group $tiers.Active[$id] -VaultRoot (Join-Path $RepoRoot 'Codex\sessions') -NativeRoot $nativeActiveRoot
        }
    }
    $localAfter = Get-CodexSessionGroups $nativeActiveRoot
    $repoIndex = Join-Path $RepoRoot 'Codex\session_index.jsonl'
    $localIndex = Join-Path $Config.CodexHome 'session_index.jsonl'
    Write-FilteredCodexIndex -Inputs @($repoIndex, $localIndex) -Output $localIndex -AllowedIds @($localAfter.Keys)
    Write-CodexCheckpoint -RepoRoot $RepoRoot -ActiveIds $vaultActiveIds
    [pscustomobject]@{ Active = $vaultActiveIds.Count; Local = $localAfter.Count }
}

function Invoke-CodexFinishCollect {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Config,
        [switch]$AllowCheckpointAncestor
    )
    $checkpoint = Read-CodexCheckpoint $RepoRoot
    Assert-CheckpointAtVaultHead -RepoRoot $RepoRoot -Checkpoint $checkpoint -AllowAncestor:$AllowCheckpointAncestor
    $tiers = Get-CodexTierInventory $RepoRoot
    $nativeActiveRoot = Join-Path $Config.CodexHome 'sessions'
    $nativeArchivedRoot = Join-Path $Config.CodexHome 'archived_sessions'
    $localActive = Get-CodexSessionGroups $nativeActiveRoot
    $localArchived = Get-CodexSessionGroups $nativeArchivedRoot
    $currentExists = @{}
    foreach ($id in @($localActive.Keys) + @($localArchived.Keys)) { $currentExists[$id] = $true }
    $deleted = @($checkpoint.ActiveIds | Where-Object { -not $currentExists.ContainsKey($_) })
    foreach ($id in $deleted) {
        if ($tiers.Active.ContainsKey($id)) { Remove-CodexGroupFiles $tiers.Active[$id] }
    }
    $vaultActiveRoot = Join-Path $RepoRoot 'Codex\sessions'
    foreach ($id in $localActive.Keys) {
        if ($tiers.Archived.ContainsKey($id)) { Remove-CodexGroupFiles $tiers.Archived[$id] }
        Copy-CodexNativeGroupToVault -Group $localActive[$id] -NativeRoot $nativeActiveRoot -VaultActiveRoot $vaultActiveRoot
    }
    $tiers = Get-CodexTierInventory $RepoRoot
    $cutoff = [DateTime]::UtcNow.AddDays(-[int]$Config.ActiveWindowDays)
    $aged = @()
    foreach ($id in @($tiers.Active.Keys)) {
        $last = Get-CodexGroupLastActivity $tiers.Active[$id]
        if ($null -eq $last) { throw "Codex 마지막 활동 시각을 읽을 수 없습니다: $id" }
        if ($last -lt $cutoff) {
            Move-CodexVaultGroup -RepoRoot $RepoRoot -Group $tiers.Active[$id] -SourceRoot $vaultActiveRoot -TargetRoot (Join-Path $RepoRoot 'Codex\archive')
            $aged += $id
        }
    }
    $finalTiers = Get-CodexTierInventory $RepoRoot
    $repoIndex = Join-Path $RepoRoot 'Codex\session_index.jsonl'
    $localIndex = Join-Path $Config.CodexHome 'session_index.jsonl'
    Write-FilteredCodexIndex -Inputs @($repoIndex, $localIndex) -Output $repoIndex -AllowedIds @($finalTiers.Active.Keys)
    [pscustomobject]@{ ActiveIds = @($finalTiers.Active.Keys); DeletedIds = $deleted; ArchivedIds = $aged }
}

function Complete-CodexFinishState {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Result
    )
    $active = @{}
    foreach ($id in $Result.ActiveIds) { $active[$id] = $true }
    $nativeActiveRoot = Join-Path $Config.CodexHome 'sessions'
    $localGroups = Get-CodexSessionGroups $nativeActiveRoot
    $remove = @($localGroups.Keys | Where-Object { -not $active.ContainsKey($_) })
    if ($remove) { [void](Remove-CodexNativeIds -Roots @($nativeActiveRoot) -Ids $remove) }
    $remaining = Get-CodexSessionGroups $nativeActiveRoot
    $localIndex = Join-Path $Config.CodexHome 'session_index.jsonl'
    $repoIndex = Join-Path $RepoRoot 'Codex\session_index.jsonl'
    Write-FilteredCodexIndex -Inputs @($repoIndex, $localIndex) -Output $localIndex -AllowedIds @($remaining.Keys)
    Write-CodexCheckpoint -RepoRoot $RepoRoot -ActiveIds @($Result.ActiveIds)
}
