Set-StrictMode -Version Latest

function Get-CodexSessionMeta {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Codex rollout does not exist: $Path" }
    $rawStream = $null; $gzipStream = $null; $reader = $null
    try {
        $rawStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($Path -like '*.gz') {
            $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $true)
            $reader = [IO.StreamReader]::new($gzipStream, [Text.Encoding]::UTF8, $true)
        } else { $reader = [IO.StreamReader]::new($rawStream, [Text.Encoding]::UTF8, $true) }
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($null -eq $record -or [string]$record.type -ne 'session_meta' -or $null -eq $record.payload) { continue }
            $id = [string]$record.payload.id
            $sessionId = [string]$record.payload.session_id
            if ($id -and $sessionId -and -not [string]::Equals($id,$sessionId,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Codex session_meta IDs disagree in $Path"
            }
            $canonical = if ($id) { $id } else { $sessionId }
            if (-not $canonical) { throw "Codex session_meta has no canonical ID: $Path" }
            return [pscustomobject]@{Id=$canonical;Cwd=[string]$record.payload.cwd}
        }
        throw "Codex rollout has no readable session_meta: $Path"
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($rawStream) { $rawStream.Dispose() }
    }
}

function Get-CodexNativeRelativePath {
    param([Parameter(Mandatory)][string]$TransportRoot,[Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($TransportRoot).TrimEnd('\','/')
    $relative = [IO.Path]::GetFullPath($Path).Substring($root.Length).TrimStart('\','/')
    $parts = @($relative -split '[\\/]')
    if ($parts.Count -lt 3) { throw "Codex transport path has no cwd/date boundary: $Path" }
    ($parts[1..($parts.Count-1)] -join [IO.Path]::DirectorySeparatorChar)
}

function Write-CodexIndexLines {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)
    $content = if ($Lines.Count -gt 0) { ($Lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-AgentSessionUtf8File -Path $Path -Content $content
}

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
        $cwdKey = if ([string]::IsNullOrWhiteSpace($meta.Cwd)) { '_no-cwd' } else { ConvertTo-SessionPathKey $meta.Cwd }
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

function New-CodexIndexArtifact {
    param([string[]]$Inputs, [string[]]$AllowedIds, [string]$PlanRoot, [string]$Name)
    $allowed = @{}
    foreach ($id in $AllowedIds) { $allowed[$id] = $true }
    $lines = Get-CodexIndexLinesById $Inputs
    $selected = @($lines.Keys | Where-Object { $allowed.ContainsKey($_) } | Sort-Object | ForEach-Object { $lines[$_] })
    $path = Join-Path $PlanRoot ($Name + '-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $content = if ($selected.Count -gt 0) { ($selected -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-AgentSessionUtf8File -Path $path -Content $content
    [pscustomobject]@{ Path = $path; Sha256 = Get-AgentSessionFileSha256 $path }
}

function Get-CodexRepoRelativePath {
    param([string]$RepoRoot, [string]$Path)
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    [IO.Path]::GetFullPath($Path).Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Get-CodexNativeRelativeFromFile {
    param([string]$NativeRoot, $File)
    $root = [IO.Path]::GetFullPath($NativeRoot).TrimEnd('\', '/')
    $File.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
}

function New-CodexPlanObject {
    param([string]$Phase, $Context, [array]$VaultOperations, [array]$LocalOperations, $Result, [string[]]$Warnings = @())
    [pscustomobject]@{
        SchemaVersion = 1
        Agent = 'Codex'
        Phase = $Phase
        ExpectedVaultCommit = [string]$Context.VaultCommit
        RootBindings = @{ CodexHome = [IO.Path]::GetFullPath([string]$Context.Config.CodexHome) }
        VaultOperations = @($VaultOperations)
        LocalOperations = @($LocalOperations)
        Result = $Result
        Warnings = @($Warnings)
    }
}

function New-CodexVaultFileOperation {
    param([string]$RepoRoot, [string]$Commit, [string]$SourcePath, [string]$TargetRoot, [string]$TargetRelative)
    $sourceRelative = Get-CodexRepoRelativePath -RepoRoot $RepoRoot -Path $SourcePath
    New-AgentSessionPutOperation -TargetRoot $TargetRoot -RelativePath $TargetRelative -SourceKind VaultFile `
        -SourceRelativePath $sourceRelative -SourceCommit $Commit -SourceSha256 (Get-AgentSessionFileSha256 $SourcePath)
}

function New-CodexStartPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    $config = $Context.Config
    $tiers = Get-CodexTierInventory $repoRoot
    $nativeActiveRoot = Join-Path $config.CodexHome 'sessions'
    $nativeArchivedRoot = Join-Path $config.CodexHome 'archived_sessions'
    $localActive = Get-CodexSessionGroups $nativeActiveRoot
    $localArchived = Get-CodexSessionGroups $nativeArchivedRoot
    foreach ($id in $localActive.Keys) {
        if ($localArchived.ContainsKey($id)) { throw "Codex 로컬 세션이 sessions와 archived_sessions에 동시에 있습니다: $id" }
    }
    $checkpoint = Read-CodexCheckpoint $repoRoot
    if (-not $checkpoint.Exists -and ($localActive.Count -gt 0 -or $localArchived.Count -gt 0)) {
        throw '첫 Start 전에 Codex sessions와 archived_sessions를 비워야 합니다.'
    }

    $operations = New-Object 'Collections.Generic.List[object]'
    $vaultActive = @{}
    foreach ($id in $tiers.Active.Keys) { $vaultActive[$id] = $true }
    if ($checkpoint.Exists) {
        foreach ($id in $checkpoint.ActiveIds) {
            if ($vaultActive.ContainsKey($id)) { continue }
            foreach ($rootInfo in @(@{ Root = $nativeActiveRoot; Prefix = 'sessions' }, @{ Root = $nativeArchivedRoot; Prefix = 'archived_sessions' })) {
                $groups = Get-CodexSessionGroups $rootInfo.Root
                if (-not $groups.ContainsKey($id)) { continue }
                foreach ($file in $groups[$id].Files) {
                    $relative = Get-CodexNativeRelativeFromFile -NativeRoot $rootInfo.Root -File $file
                    [void]$operations.Add((New-AgentSessionDeleteOperation -TargetRoot CodexHome -RelativePath ($rootInfo.Prefix + '/' + $relative)))
                }
            }
        }
    }

    foreach ($id in $tiers.Active.Keys) {
        if ($localArchived.ContainsKey($id)) {
            foreach ($file in $localArchived[$id].Files) {
                $relative = Get-CodexNativeRelativeFromFile -NativeRoot $nativeArchivedRoot -File $file
                [void]$operations.Add((New-AgentSessionDeleteOperation -TargetRoot CodexHome -RelativePath ('archived_sessions/' + $relative)))
            }
        }
        foreach ($file in $tiers.Active[$id].Files) {
            $nativeRelative = Get-CodexNativeRelativePath -TransportRoot (Join-Path $repoRoot 'Codex\sessions') -Path $file.FullName
            if ($file.Name -like '*.jsonl.gz') {
                $nativeRelative = $nativeRelative.Substring(0, $nativeRelative.Length - 3).Replace('\', '/')
                $expanded = Join-Path $PlanRoot ('codex-expand-' + [guid]::NewGuid().ToString('N') + '.jsonl')
                [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded)
                [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath ('sessions/' + $nativeRelative) `
                    -SourceKind StagedFile -SourcePath $expanded -SourceSha256 (Get-AgentSessionFileSha256 $expanded)))
            } else {
                [void]$operations.Add((New-CodexVaultFileOperation -RepoRoot $repoRoot -Commit $Context.VaultCommit -SourcePath $file.FullName `
                    -TargetRoot CodexHome -TargetRelative ('sessions/' + $nativeRelative.Replace('\', '/'))))
            }
        }
    }

    $preservedLocal = @($localActive.Keys | Where-Object { -not ($checkpoint.ActiveIds -contains $_) })
    $finalLocalIds = @($tiers.Active.Keys) + $preservedLocal | Sort-Object -Unique
    $indexArtifact = New-CodexIndexArtifact -Inputs @((Join-Path $repoRoot 'Codex\session_index.jsonl'), (Join-Path $config.CodexHome 'session_index.jsonl')) `
        -AllowedIds $finalLocalIds -PlanRoot $PlanRoot -Name 'codex-start-index'
    [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath 'session_index.jsonl' -SourceKind StagedFile `
        -SourcePath $indexArtifact.Path -SourceSha256 $indexArtifact.Sha256))

    New-CodexPlanObject -Phase Start -Context $Context -VaultOperations @() -LocalOperations @($operations | ForEach-Object { $_ }) `
        -Result ([pscustomobject]@{ ActiveIds = @($tiers.Active.Keys); DeletedIds = @(); ArchivedIds = @(); RestoredIds = @(); MissingIds = @(); LocalActiveIds = $finalLocalIds })
}

function Add-CodexDesiredVaultGroup {
    param([hashtable]$Desired, [string]$Tier, $Group, [string]$RepoRoot, [string]$Commit)
    $tierRelative = if ($Tier -eq 'Active') { 'Codex\sessions' } else { 'Codex\archive' }
    $targetPrefix = if ($Tier -eq 'Active') { 'Codex/sessions/' } else { 'Codex/archive/' }
    $tierRoot = Join-Path $RepoRoot $tierRelative
    foreach ($file in $Group.Files) {
        $inside = $file.FullName.Substring(([IO.Path]::GetFullPath($tierRoot).TrimEnd('\', '/')).Length).TrimStart('\', '/').Replace('\', '/')
        $target = $targetPrefix + $inside
        $sourceRelative = Get-CodexRepoRelativePath -RepoRoot $RepoRoot -Path $file.FullName
        $Desired[$target] = [pscustomobject]@{ SourceKind = 'VaultFile'; SourcePath = $file.FullName; SourceRelativePath = $sourceRelative; SourceCommit = $Commit; Sha256 = Get-AgentSessionFileSha256 $file.FullName; Id = $Group.Id; Tier = $Tier }
    }
}

function New-CodexFinishPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    $config = $Context.Config
    $checkpoint = Read-CodexCheckpoint $repoRoot
    Assert-AgentSessionCheckpointAtHead -RepoRoot $repoRoot -Checkpoint $checkpoint -AllowAncestor:$Context.AllowCheckpointAncestor
    $tiers = Get-CodexTierInventory $repoRoot
    $nativeActiveRoot = Join-Path $config.CodexHome 'sessions'
    $nativeArchivedRoot = Join-Path $config.CodexHome 'archived_sessions'
    $localActive = Get-CodexSessionGroups $nativeActiveRoot
    $localArchived = Get-CodexSessionGroups $nativeArchivedRoot
    foreach ($id in $localActive.Keys) {
        if ($localArchived.ContainsKey($id)) { throw "Codex 로컬 세션이 sessions와 archived_sessions에 동시에 있습니다: $id" }
    }
    $exists = @{}
    foreach ($id in @($localActive.Keys) + @($localArchived.Keys)) { $exists[$id] = $true }
    $deleted = @($checkpoint.ActiveIds | Where-Object { -not $exists.ContainsKey($_) })

    $desired = @{}
    foreach ($group in $tiers.Active.Values) { Add-CodexDesiredVaultGroup -Desired $desired -Tier Active -Group $group -RepoRoot $repoRoot -Commit $Context.VaultCommit }
    foreach ($group in $tiers.Archived.Values) { Add-CodexDesiredVaultGroup -Desired $desired -Tier Archived -Group $group -RepoRoot $repoRoot -Commit $Context.VaultCommit }
    foreach ($id in $deleted) {
        foreach ($key in @($desired.Keys | Where-Object { $desired[$_].Id -eq $id })) { $desired.Remove($key) }
    }

    $lastActivity = @{}
    foreach ($localSource in @(
        @{ Groups = $localActive; Root = $nativeActiveRoot },
        @{ Groups = $localArchived; Root = $nativeArchivedRoot }
    )) {
      foreach ($id in $localSource.Groups.Keys) {
        foreach ($key in @($desired.Keys | Where-Object { $desired[$_].Id -eq $id })) { $desired.Remove($key) }
        $lastActivity[$id] = Get-CodexGroupLastActivity $localSource.Groups[$id]
        foreach ($file in $localSource.Groups[$id].Files) {
            $nativeRelative = Get-CodexNativeRelativeFromFile -NativeRoot $localSource.Root -File $file
            $snapshot = New-AgentSessionStagedSnapshot -Source $file.FullName -PlanRoot $PlanRoot -Name ('codex-' + $id)
            Test-JsonlSnapshotComplete $snapshot.Path
            $target = 'Codex/sessions/' + $localSource.Groups[$id].CwdKey + '/' + $nativeRelative
            $sourcePath = $snapshot.Path
            if ((Get-Item -LiteralPath $sourcePath).Length -gt [int64]$config.TransportFileLimitBytes) {
                $compressed = $sourcePath + '.gz'
                Compress-JsonlTransportFile -Source $sourcePath -Destination $compressed
                if ((Get-Item -LiteralPath $compressed).Length -gt [int64]$config.TransportFileLimitBytes) { throw "Codex gzip transport limit exceeded: $id" }
                $sourcePath = $compressed
                $target += '.gz'
            }
            $desired[$target] = [pscustomobject]@{ SourceKind = 'StagedFile'; SourcePath = $sourcePath; SourceRelativePath = ''; SourceCommit = ''; Sha256 = Get-AgentSessionFileSha256 $sourcePath; Id = $id; Tier = 'Active' }
        }
      }
    }

    $cutoff = $Context.NowUtc.AddDays(-[int]$config.ActiveWindowDays)
    $aged = @()
    $activeIds = @($desired.Values | Where-Object Tier -eq Active | ForEach-Object Id | Sort-Object -Unique)
    foreach ($id in $activeIds) {
        $last = if ($lastActivity.ContainsKey($id)) { $lastActivity[$id] } elseif ($tiers.Active.ContainsKey($id)) { Get-CodexGroupLastActivity $tiers.Active[$id] } else { $null }
        if ($null -eq $last) { throw "Codex 마지막 활동 시각을 읽을 수 없습니다: $id" }
        if ($last -ge $cutoff) { continue }
        $aged += $id
        foreach ($key in @($desired.Keys | Where-Object { $desired[$_].Id -eq $id -and $desired[$_].Tier -eq 'Active' })) {
            $record = $desired[$key]
            $newKey = $key -replace '^Codex/sessions/', 'Codex/archive/'
            $desired.Remove($key)
            $record.Tier = 'Archived'
            $desired[$newKey] = $record
        }
    }

    $finalActiveIds = @($desired.Values | Where-Object Tier -eq Active | ForEach-Object Id | Sort-Object -Unique)
    $indexArtifact = New-CodexIndexArtifact -Inputs @((Join-Path $repoRoot 'Codex\session_index.jsonl'), (Join-Path $config.CodexHome 'session_index.jsonl')) `
        -AllowedIds $finalActiveIds -PlanRoot $PlanRoot -Name 'codex-vault-index'
    $desired['Codex/session_index.jsonl'] = [pscustomobject]@{ SourceKind='StagedFile';SourcePath=$indexArtifact.Path;SourceRelativePath='';SourceCommit='';Sha256=$indexArtifact.Sha256;Id='';Tier='Index' }

    $current = @{}
    foreach ($rootRel in @('Codex/sessions','Codex/archive')) {
        $root = Join-Path $repoRoot ($rootRel -replace '/', '\')
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz'
        })) {
            $relative = Get-CodexRepoRelativePath -RepoRoot $repoRoot -Path $file.FullName
            $current[$relative] = Get-AgentSessionFileSha256 $file.FullName
        }
    }
    $repoIndex = Join-Path $repoRoot 'Codex\session_index.jsonl'
    if (Test-Path -LiteralPath $repoIndex) { $current['Codex/session_index.jsonl'] = Get-AgentSessionFileSha256 $repoIndex }

    $vaultOps = New-Object 'Collections.Generic.List[object]'
    foreach ($path in $desired.Keys) {
        $record = $desired[$path]
        if ($current.ContainsKey($path) -and [string]::Equals($current[$path], $record.Sha256, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($record.SourceKind -eq 'VaultFile') {
            [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault -RelativePath $path -SourceKind VaultFile `
                -SourceRelativePath $record.SourceRelativePath -SourceCommit $record.SourceCommit -SourceSha256 $record.Sha256))
        } else {
            [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault -RelativePath $path -SourceKind StagedFile `
                -SourcePath $record.SourcePath -SourceSha256 $record.Sha256))
        }
    }
    foreach ($path in $current.Keys) { if (-not $desired.ContainsKey($path)) { [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath $path)) } }

    $localOps = New-Object 'Collections.Generic.List[object]'
    foreach ($rootInfo in @(
        @{ Groups = $localActive; Root = $nativeActiveRoot; Prefix = 'sessions' },
        @{ Groups = $localArchived; Root = $nativeArchivedRoot; Prefix = 'archived_sessions' }
    )) {
        foreach ($group in $rootInfo.Groups.Values) {
            if ($finalActiveIds -contains $group.Id) { continue }
            foreach ($file in $group.Files) {
                $relative = Get-CodexNativeRelativeFromFile -NativeRoot $rootInfo.Root -File $file
                [void]$localOps.Add((New-AgentSessionDeleteOperation -TargetRoot CodexHome -RelativePath ($rootInfo.Prefix + '/' + $relative)))
            }
        }
    }
    $localIndexArtifact = New-CodexIndexArtifact -Inputs @((Join-Path $repoRoot 'Codex\session_index.jsonl'), (Join-Path $config.CodexHome 'session_index.jsonl')) `
        -AllowedIds $finalActiveIds -PlanRoot $PlanRoot -Name 'codex-local-index'
    [void]$localOps.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath 'session_index.jsonl' -SourceKind StagedFile `
        -SourcePath $localIndexArtifact.Path -SourceSha256 $localIndexArtifact.Sha256))

    New-CodexPlanObject -Phase Finish -Context $Context -VaultOperations @($vaultOps | ForEach-Object { $_ }) -LocalOperations @($localOps | ForEach-Object { $_ }) `
        -Result ([pscustomobject]@{ ActiveIds=$finalActiveIds;DeletedIds=$deleted;ArchivedIds=$aged;RestoredIds=@();MissingIds=@() })
}

function New-CodexRestorePlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot, [Parameter(Mandatory)][string]$SessionId)
    $repoRoot = [string]$Context.RepoRoot
    $tiers = Get-CodexTierInventory $repoRoot
    $group = if ($tiers.Archived.ContainsKey($SessionId)) { $tiers.Archived[$SessionId] } elseif ($tiers.Active.ContainsKey($SessionId)) { $tiers.Active[$SessionId] } else { throw "Codex 세션을 찾을 수 없습니다: $SessionId" }
    $vaultOps = New-Object 'Collections.Generic.List[object]'
    $localOps = New-Object 'Collections.Generic.List[object]'
    $archiveRoot = Join-Path $repoRoot 'Codex\archive'
    $activeRoot = Join-Path $repoRoot 'Codex\sessions'
    foreach ($file in $group.Files) {
        $sourceTierRoot = if ($tiers.Archived.ContainsKey($SessionId)) { $archiveRoot } else { $activeRoot }
        $inside = $file.FullName.Substring(([IO.Path]::GetFullPath($sourceTierRoot).TrimEnd('\','/')).Length).TrimStart('\','/').Replace('\','/')
        if ($tiers.Archived.ContainsKey($SessionId)) {
            [void]$vaultOps.Add((New-CodexVaultFileOperation -RepoRoot $repoRoot -Commit $Context.VaultCommit -SourcePath $file.FullName -TargetRoot Vault -TargetRelative ('Codex/sessions/' + $inside)))
            [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath ('Codex/archive/' + $inside)))
        }
        $nativeRelative = Get-CodexNativeRelativePath -TransportRoot $sourceTierRoot -Path $file.FullName
        if ($file.Name -like '*.jsonl.gz') {
            $nativeRelative = $nativeRelative.Substring(0,$nativeRelative.Length-3).Replace('\','/')
            $expanded = Join-Path $PlanRoot ('codex-restore-' + [guid]::NewGuid().ToString('N') + '.jsonl')
            [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded)
            $snapshotPath = $expanded
        } else {
            $snapshot = New-AgentSessionStagedSnapshot -Source $file.FullName -PlanRoot $PlanRoot -Name 'codex-restore'
            $snapshotPath = $snapshot.Path
        }
        [void]$localOps.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath ('sessions/' + $nativeRelative.Replace('\','/')) `
            -SourceKind StagedFile -SourcePath $snapshotPath -SourceSha256 (Get-AgentSessionFileSha256 $snapshotPath)))
    }
    $activeIds = @($tiers.Active.Keys) + $SessionId | Sort-Object -Unique
    New-CodexPlanObject -Phase Restore -Context $Context -VaultOperations @($vaultOps | ForEach-Object { $_ }) -LocalOperations @($localOps | ForEach-Object { $_ }) `
        -Result ([pscustomobject]@{ ActiveIds=$activeIds;DeletedIds=@();ArchivedIds=@();RestoredIds=@($SessionId);MissingIds=@() })
}

function New-CodexCheckpointPlan {
    param([Parameter(Mandatory)]$Context, $State, [Parameter(Mandatory)][string]$PublishedCommit, [Parameter(Mandatory)][string]$PlanRoot)
    if ($null -eq $State) {
        $tiers = Get-CodexTierInventory ([string]$Context.RepoRoot)
        $State = [pscustomobject]@{ ActiveIds = @($tiers.Active.Keys) }
    }
    $path = Join-Path $PlanRoot ('codex-checkpoint-' + [guid]::NewGuid().ToString('N') + '.json')
    $content = [pscustomobject]@{ schemaVersion=1;commit=$PublishedCommit;codexActiveIds=@($State.ActiveIds | Sort-Object -Unique);writtenAtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 4
    Write-AgentSessionUtf8File -Path $path -Content $content
    $relative = Split-Path -Leaf (Get-CodexCheckpointPath ([string]$Context.RepoRoot))
    New-CodexPlanObject -Phase Checkpoint -Context $Context -VaultOperations @() `
        -LocalOperations @((New-AgentSessionPutOperation -TargetRoot CheckpointRoot -RelativePath $relative -SourceKind StagedFile -SourcePath $path -SourceSha256 (Get-AgentSessionFileSha256 $path))) `
        -Result $State
}
