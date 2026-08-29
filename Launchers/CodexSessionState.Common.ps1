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
            $idProperty = $record.payload.PSObject.Properties['id']
            $sessionIdProperty = $record.payload.PSObject.Properties['session_id']
            $cwdProperty = $record.payload.PSObject.Properties['cwd']
            $historyBaseProperty = $record.payload.PSObject.Properties['history_base']
            $id = if ($null -ne $idProperty) { [string]$idProperty.Value } else { '' }
            $sessionId = if ($null -ne $sessionIdProperty) { [string]$sessionIdProperty.Value } else { '' }
            $cwd = if ($null -ne $cwdProperty) { [string]$cwdProperty.Value } else { '' }
            # Older desktop rollouts use id for a page and session_id for the
            # canonical thread. Current rollouts may expose only id.
            $canonical = if ($sessionId) { $sessionId } else { $id }
            if (-not $canonical) { throw "Codex session_meta has no canonical ID: $Path" }
            $logicalName = [IO.Path]::GetFileName($Path) -replace '\.gz$', '' -replace '\.jsonl$', ''
            $uuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
            $pageId = if ($logicalName -match "_($uuidPattern)$") { [string]$Matches[1] } elseif ($id) { $id } else { $canonical }
            $historyBaseThreadId = ''
            $historyBaseEndByte = $null
            $historyBaseEndOrdinal = $null
            if ($null -ne $historyBaseProperty -and $null -ne $historyBaseProperty.Value) {
                $baseThreadProperty = $historyBaseProperty.Value.PSObject.Properties['thread_id']
                $baseByteProperty = $historyBaseProperty.Value.PSObject.Properties['end_byte_offset']
                $baseOrdinalProperty = $historyBaseProperty.Value.PSObject.Properties['end_ordinal_exclusive']
                if ($null -ne $baseThreadProperty) { $historyBaseThreadId = [string]$baseThreadProperty.Value }
                if ($null -ne $baseByteProperty) { $historyBaseEndByte = [int64]$baseByteProperty.Value }
                if ($null -ne $baseOrdinalProperty) { $historyBaseEndOrdinal = [int64]$baseOrdinalProperty.Value }
            }
            return [pscustomobject]@{
                Id = $canonical
                PageId = $pageId
                Cwd = $cwd
                HistoryBaseThreadId = $historyBaseThreadId
                HistoryBaseEndByte = $historyBaseEndByte
                HistoryBaseEndOrdinal = $historyBaseEndOrdinal
            }
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

function Get-CodexLogicalFileLength {
    param([Parameter(Mandatory)][string]$Path)
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($Path -notlike '*.gz') { return [int64]$info.Length }

    $rawStream = $null
    $gzipStream = $null
    try {
        $rawStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $false)
        $buffer = New-Object byte[] 65536
        [int64]$length = 0
        while (($read = $gzipStream.Read($buffer, 0, $buffer.Length)) -gt 0) { $length += $read }
        return $length
    } finally {
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($rawStream) { $rawStream.Dispose() }
    }
}

function Assert-CodexHistoryBoundary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$EndByte,
        [Nullable[int64]]$EndOrdinalExclusive = $null
    )
    if ($EndByte -lt 0) { throw "Codex history_base 바이트 경계가 음수입니다: $Path ($EndByte)" }

    $rawStream = $null
    $gzipStream = $null
    try {
        $rawStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        [byte[]]$lastCompleteLine = $null
        [byte[]]$nextCompleteLine = $null

        if ($Path -notlike '*.gz') {
            if ($rawStream.Length -lt $EndByte) {
                throw "Codex predecessor rollout이 요구 바이트 경계보다 짧습니다: $Path ($($rawStream.Length) < $EndByte)"
            }
            if ($EndByte -gt 0) {
                [void]$rawStream.Seek($EndByte - 1, [IO.SeekOrigin]::Begin)
                if ($rawStream.ReadByte() -ne 10) {
                    throw "Codex history_base 바이트 위치가 JSONL 레코드 경계가 아닙니다: $Path ($EndByte)"
                }
                [int64]$lineStart = 0
                [int64]$scanEnd = $EndByte - 2
                $scanBuffer = New-Object byte[] 65536
                $found = $false
                while ($scanEnd -ge 0 -and -not $found) {
                    $scanStart = [Math]::Max([int64]0, $scanEnd - $scanBuffer.Length + 1)
                    $scanCount = [int]($scanEnd - $scanStart + 1)
                    [void]$rawStream.Seek($scanStart, [IO.SeekOrigin]::Begin)
                    $actual = $rawStream.Read($scanBuffer, 0, $scanCount)
                    for ($i = $actual - 1; $i -ge 0; $i--) {
                        if ($scanBuffer[$i] -eq 10) { $lineStart = $scanStart + $i + 1; $found = $true; break }
                    }
                    $scanEnd = $scanStart - 1
                }
                $lineLength = [int](($EndByte - 1) - $lineStart)
                $lastCompleteLine = New-Object byte[] $lineLength
                [void]$rawStream.Seek($lineStart, [IO.SeekOrigin]::Begin)
                if ($lineLength -gt 0) { [void]$rawStream.Read($lastCompleteLine, 0, $lineLength) }
            }
            if ($rawStream.Length -gt $EndByte) {
                [void]$rawStream.Seek($EndByte, [IO.SeekOrigin]::Begin)
                $nextBuffer = [IO.MemoryStream]::new()
                try {
                    while (($value = $rawStream.ReadByte()) -ge 0 -and $value -ne 10) { $nextBuffer.WriteByte([byte]$value) }
                    $nextCompleteLine = $nextBuffer.ToArray()
                } finally { $nextBuffer.Dispose() }
            }
        } else {
            $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $true)
            $buffer = New-Object byte[] 65536
            $currentLine = [IO.MemoryStream]::new()
            try {
                [int64]$position = 0
                while ($position -lt $EndByte) {
                    $wanted = [int][Math]::Min([int64]$buffer.Length, $EndByte - $position)
                    $read = $gzipStream.Read($buffer, 0, $wanted)
                    if ($read -le 0) { throw "Codex predecessor rollout이 요구 바이트 경계보다 짧습니다: $Path ($position < $EndByte)" }
                    $segmentStart = 0
                    while ($segmentStart -lt $read) {
                        $newline = [Array]::IndexOf($buffer, [byte]10, $segmentStart, $read - $segmentStart)
                        if ($newline -lt 0) { $currentLine.Write($buffer, $segmentStart, $read - $segmentStart); break }
                        if ($newline -gt $segmentStart) { $currentLine.Write($buffer, $segmentStart, $newline - $segmentStart) }
                        $lastCompleteLine = $currentLine.ToArray()
                        $currentLine.SetLength(0)
                        $segmentStart = $newline + 1
                    }
                    $position += $read
                }
                if ($EndByte -gt 0 -and $currentLine.Length -ne 0) {
                    throw "Codex history_base 바이트 위치가 JSONL 레코드 경계가 아닙니다: $Path ($EndByte)"
                }
                $nextBuffer = [IO.MemoryStream]::new()
                try {
                    $done = $false
                    while (-not $done -and ($read = $gzipStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $newline = [Array]::IndexOf($buffer, [byte]10, 0, $read)
                        if ($newline -ge 0) { if ($newline -gt 0) { $nextBuffer.Write($buffer, 0, $newline) }; $done = $true }
                        else { $nextBuffer.Write($buffer, 0, $read) }
                    }
                    if ($nextBuffer.Length -gt 0) { $nextCompleteLine = $nextBuffer.ToArray() }
                } finally { $nextBuffer.Dispose() }
            } finally { $currentLine.Dispose() }
        }

        $lastOrdinal = $null
        if ($EndByte -gt 0) {
            if ($null -eq $lastCompleteLine) { throw "Codex history_base 앞에 완전한 JSONL 레코드가 없습니다: $Path ($EndByte)" }
            try {
                $lastText = [Text.Encoding]::UTF8.GetString($lastCompleteLine).TrimStart([char]0xFEFF).TrimEnd("`r")
                $lastRecord = $lastText | ConvertFrom-Json
                $lastOrdinalProperty = $lastRecord.PSObject.Properties['ordinal']
                if ($null -ne $lastOrdinalProperty) { $lastOrdinal = [int64]$lastOrdinalProperty.Value }
            } catch { throw "Codex history_base 직전 JSONL 레코드를 읽을 수 없습니다: $Path ($EndByte)" }
        }

        $nextOrdinal = $null
        if ($null -ne $nextCompleteLine -and $nextCompleteLine.Length -gt 0) {
            try {
                $nextText = [Text.Encoding]::UTF8.GetString($nextCompleteLine).TrimStart([char]0xFEFF).TrimEnd("`r")
                $nextRecord = $nextText | ConvertFrom-Json
                $nextOrdinalProperty = $nextRecord.PSObject.Properties['ordinal']
                if ($null -ne $nextOrdinalProperty) { $nextOrdinal = [int64]$nextOrdinalProperty.Value }
            } catch { throw "Codex history_base 직후 JSONL 레코드를 읽을 수 없습니다: $Path ($EndByte)" }
        }

        if ($null -ne $EndOrdinalExclusive) {
            if ($EndByte -gt 0 -and ($null -eq $lastOrdinal -or $lastOrdinal -ne ($EndOrdinalExclusive - 1))) {
                throw "Codex history_base 직전 ordinal이 일치하지 않습니다: $Path ($lastOrdinal != $($EndOrdinalExclusive - 1))"
            }
            if ($null -ne $nextOrdinal -and $nextOrdinal -ne $EndOrdinalExclusive) {
                throw "Codex history_base 직후 ordinal이 일치하지 않습니다: $Path ($nextOrdinal != $EndOrdinalExclusive)"
            }
        }
    } finally {
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($rawStream) { $rawStream.Dispose() }
    }
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
    $logicalFiles = @{}
    foreach ($file in $files) {
        $logicalName = $file.Name -replace '\.gz$', ''
        if ($logicalFiles.ContainsKey($logicalName)) {
            throw ("Codex rollout 논리 파일명이 여러 경로에 중복되어 있습니다: $logicalName`n" +
                "$($logicalFiles[$logicalName])`n$($file.FullName)")
        }
        $logicalFiles[$logicalName] = $file.FullName
    }
    foreach ($file in $files) {
        $meta = Get-CodexSessionMeta $file.FullName
        $cwdKey = if ([string]::IsNullOrWhiteSpace($meta.Cwd)) { '_no-cwd' } else { ConvertTo-SessionPathKey $meta.Cwd }
        if (-not $groups.ContainsKey($meta.Id)) {
            $groups[$meta.Id] = [pscustomobject]@{
                Id = [string]$meta.Id
                CwdKey = $cwdKey
                Files = New-Object 'Collections.Generic.List[object]'
                Pages = @{}
                HistoryBases = New-Object 'Collections.Generic.List[object]'
            }
        } elseif (-not [string]::Equals($groups[$meta.Id].CwdKey, $cwdKey, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Codex canonical ID가 서로 다른 cwd를 가리킵니다: $($meta.Id)"
        }
        if ($groups[$meta.Id].Pages.ContainsKey($meta.PageId)) {
            throw "Codex page ID가 여러 rollout에 중복되어 있습니다: $($meta.PageId)"
        }
        $groups[$meta.Id].Pages[$meta.PageId] = $file
        if ($meta.HistoryBaseThreadId) {
            [void]$groups[$meta.Id].HistoryBases.Add([pscustomobject]@{
                PageId = $meta.PageId
                BasePageId = $meta.HistoryBaseThreadId
                BaseEndByte = $meta.HistoryBaseEndByte
                BaseEndOrdinal = $meta.HistoryBaseEndOrdinal
            })
        }
        [void]$groups[$meta.Id].Files.Add($file)
    }
    foreach ($group in $groups.Values) {
        foreach ($historyBase in $group.HistoryBases) {
            if (-not $group.Pages.ContainsKey($historyBase.BasePageId)) {
                throw "Codex continuation의 predecessor rollout이 없습니다: $($historyBase.PageId) -> $($historyBase.BasePageId)"
            }
            if ($null -ne $historyBase.BaseEndByte) {
                $baseFile = $group.Pages[$historyBase.BasePageId]
                Assert-CodexHistoryBoundary -Path $baseFile.FullName -EndByte ([int64]$historyBase.BaseEndByte) `
                    -EndOrdinalExclusive $historyBase.BaseEndOrdinal
            }
        }
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

function Test-CodexFileHasPrefix {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrefixPath
    )
    $pathInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    $prefixInfo = Get-Item -LiteralPath $PrefixPath -ErrorAction Stop
    if ($prefixInfo.Length -gt $pathInfo.Length) { return $false }

    $pathStream = $null; $prefixStream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $pathStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $pathInfo.FullName), [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $prefixStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $prefixInfo.FullName), [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $pathBuffer = New-Object byte[] 65536
        $prefixBuffer = New-Object byte[] 65536
        while (($prefixRead = $prefixStream.Read($prefixBuffer, 0, $prefixBuffer.Length)) -gt 0) {
            $pathRead = $pathStream.Read($pathBuffer, 0, $prefixRead)
            if ($pathRead -ne $prefixRead) { return $false }
            for ($i = 0; $i -lt $prefixRead; $i++) {
                if ($pathBuffer[$i] -ne $prefixBuffer[$i]) { return $false }
            }
        }
        return $true
    } finally {
        if ($prefixStream) { $prefixStream.Dispose() }
        if ($pathStream) { $pathStream.Dispose() }
    }
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
    $warnings = New-Object 'Collections.Generic.List[string]'
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
            $sourcePath = $file.FullName
            $sourceKind = 'VaultFile'
            if ($file.Name -like '*.jsonl.gz') {
                $nativeRelative = $nativeRelative.Substring(0, $nativeRelative.Length - 3).Replace('\', '/')
                $expanded = Join-Path $PlanRoot ('codex-expand-' + [guid]::NewGuid().ToString('N') + '.jsonl')
                $integrityPath = Get-CompressedJsonlIntegrityPath $file.FullName
                if (Test-Path -LiteralPath $integrityPath -PathType Leaf) {
                    [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded -IntegrityPath $integrityPath)
                } else {
                    Write-Warning "legacy gzip에 integrity metadata가 없습니다. CRC/JSONL 검증 후 읽기 전용으로 복원합니다: $($file.FullName)"
                    [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded)
                }
                $sourcePath = $expanded
                $sourceKind = 'StagedFile'
            }

            $targetRelative = 'sessions/' + $nativeRelative.Replace('\', '/')
            $targetPath = Join-Path $config.CodexHome ($targetRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $sourceSha = Get-AgentSessionFileSha256 $sourcePath
            $shouldPut = $true
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                $targetSha = Get-AgentSessionFileSha256 $targetPath
                if ([string]::Equals($sourceSha, $targetSha, [StringComparison]::OrdinalIgnoreCase)) {
                    $shouldPut = $false
                } elseif (Test-CodexFileHasPrefix -Path $targetPath -PrefixPath $sourcePath) {
                    $shouldPut = $false
                    [void]$warnings.Add("Codex 로컬 rollout의 append 전용 최신 suffix를 보존합니다: $targetRelative")
                } elseif (-not (Test-CodexFileHasPrefix -Path $sourcePath -PrefixPath $targetPath)) {
                    throw "Codex rollout이 append 전용 계보가 아닌 상태로 갈라졌습니다: $targetRelative`n로컬과 Vault 원문을 백업한 뒤 충돌을 정리하세요."
                }
            }
            if (-not $shouldPut) { continue }

            if ($sourceKind -eq 'StagedFile') {
                [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath $targetRelative `
                    -SourceKind StagedFile -SourcePath $sourcePath -SourceSha256 $sourceSha))
            } else {
                [void]$operations.Add((New-CodexVaultFileOperation -RepoRoot $repoRoot -Commit $Context.VaultCommit -SourcePath $file.FullName `
                    -TargetRoot CodexHome -TargetRelative $targetRelative))
            }
        }
    }

    $preservedLocal = @($localActive.Keys | Where-Object { -not ($checkpoint.ActiveIds -contains $_) })
    $finalLocalIds = @($tiers.Active.Keys) + $preservedLocal | Sort-Object -Unique
    $indexArtifact = New-CodexIndexArtifact -Inputs @((Join-Path $repoRoot 'Codex\session_index.jsonl'), (Join-Path $config.CodexHome 'session_index.jsonl')) `
        -AllowedIds $finalLocalIds -PlanRoot $PlanRoot -Name 'codex-start-index'
    [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot CodexHome -RelativePath 'session_index.jsonl' -SourceKind StagedFile `
        -SourcePath $indexArtifact.Path -SourceSha256 $indexArtifact.Sha256))

    New-CodexPlanObject -Phase Start -Context $Context -VaultOperations @() -LocalOperations @($operations | ForEach-Object { $_ }) -Warnings @($warnings | ForEach-Object { $_ }) `
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
        if ($file.Name -like '*.jsonl.gz') {
            $integrityPath = Get-CompressedJsonlIntegrityPath $file.FullName
            if (Test-Path -LiteralPath $integrityPath -PathType Leaf) {
                $integrityTarget = $target + '.integrity.json'
                $integrityRelative = Get-CodexRepoRelativePath -RepoRoot $RepoRoot -Path $integrityPath
                $Desired[$integrityTarget] = [pscustomobject]@{ SourceKind = 'VaultFile'; SourcePath = $integrityPath; SourceRelativePath = $integrityRelative; SourceCommit = $Commit; Sha256 = Get-AgentSessionFileSha256 $integrityPath; Id = $Group.Id; Tier = $Tier }
            }
        }
    }
}

function New-CodexFinishPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    $config = $Context.Config
    $checkpoint = Read-CodexCheckpoint $repoRoot
    $checkpointCurrent = Test-AgentSessionCheckpointCurrent -RepoRoot $repoRoot -Checkpoint $checkpoint -AgentName 'Codex'
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
    $deleted = @()
    if ($checkpointCurrent) { $deleted = @($checkpoint.ActiveIds | Where-Object { -not $exists.ContainsKey($_) }) }

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
            $target = 'Codex/sessions/' + $localSource.Groups[$id].CwdKey + '/' + $nativeRelative
            Test-JsonlSnapshotComplete $file.FullName
            if ($file.Length -gt [int64]$config.TransportFileLimitBytes) {
                $gzipTarget = $target + '.gz'
                $vaultGzip = Join-Path $repoRoot ($gzipTarget.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $vaultIntegrity = Get-CompressedJsonlIntegrityPath $vaultGzip
                if (Test-CompressedJsonlTransportCurrent -Source $file.FullName -Compressed $vaultGzip -IntegrityPath $vaultIntegrity) {
                    $gzipRelative = Get-CodexRepoRelativePath -RepoRoot $repoRoot -Path $vaultGzip
                    $integrityRelative = Get-CodexRepoRelativePath -RepoRoot $repoRoot -Path $vaultIntegrity
                    $desired[$gzipTarget] = [pscustomobject]@{ SourceKind = 'VaultFile'; SourcePath = $vaultGzip; SourceRelativePath = $gzipRelative; SourceCommit = $Context.VaultCommit; Sha256 = Get-AgentSessionFileSha256 $vaultGzip; Id = $id; Tier = 'Active' }
                    $desired[$gzipTarget + '.integrity.json'] = [pscustomobject]@{ SourceKind = 'VaultFile'; SourcePath = $vaultIntegrity; SourceRelativePath = $integrityRelative; SourceCommit = $Context.VaultCommit; Sha256 = Get-AgentSessionFileSha256 $vaultIntegrity; Id = $id; Tier = 'Active' }
                    continue
                }
                $snapshot = New-AgentSessionStagedSnapshot -Source $file.FullName -PlanRoot $PlanRoot -Name ('codex-' + $id)
                Test-JsonlSnapshotComplete $snapshot.Path
                $compressed = $snapshot.Path + '.gz'
                Compress-JsonlTransportFile -Source $snapshot.Path -Destination $compressed
                if ((Get-Item -LiteralPath $compressed).Length -gt [int64]$config.TransportFileLimitBytes) { throw "Codex gzip transport limit exceeded: $id" }
                $integrity = New-CompressedJsonlIntegrityArtifact -Raw $snapshot.Path -Compressed $compressed -PlanRoot $PlanRoot -Name ('codex-' + $id)
                $desired[$gzipTarget] = [pscustomobject]@{ SourceKind = 'StagedFile'; SourcePath = $compressed; SourceRelativePath = ''; SourceCommit = ''; Sha256 = Get-AgentSessionFileSha256 $compressed; Id = $id; Tier = 'Active' }
                $desired[$gzipTarget + '.integrity.json'] = [pscustomobject]@{ SourceKind = 'StagedFile'; SourcePath = $integrity.Path; SourceRelativePath = ''; SourceCommit = ''; Sha256 = $integrity.Sha256; Id = $id; Tier = 'Active' }
                continue
            }
            $snapshot = New-AgentSessionStagedSnapshot -Source $file.FullName -PlanRoot $PlanRoot -Name ('codex-' + $id)
            Test-JsonlSnapshotComplete $snapshot.Path
            $desired[$target] = [pscustomobject]@{ SourceKind = 'StagedFile'; SourcePath = $snapshot.Path; SourceRelativePath = ''; SourceCommit = ''; Sha256 = Get-AgentSessionFileSha256 $snapshot.Path; Id = $id; Tier = 'Active' }
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
            $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' -or $_.Name -like '*.jsonl.gz.integrity.json'
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
            if ($file.Name -like '*.jsonl.gz') {
                $integrityPath = Get-CompressedJsonlIntegrityPath $file.FullName
                if (Test-Path -LiteralPath $integrityPath -PathType Leaf) {
                    [void]$vaultOps.Add((New-CodexVaultFileOperation -RepoRoot $repoRoot -Commit $Context.VaultCommit -SourcePath $integrityPath -TargetRoot Vault -TargetRelative ('Codex/sessions/' + $inside + '.integrity.json')))
                    [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath ('Codex/archive/' + $inside + '.integrity.json')))
                } else {
                    Write-Warning "legacy gzip에 integrity metadata가 없습니다. 원문 운반물만 활성 계층으로 옮깁니다: $($file.FullName)"
                }
            }
        }
        $nativeRelative = Get-CodexNativeRelativePath -TransportRoot $sourceTierRoot -Path $file.FullName
        if ($file.Name -like '*.jsonl.gz') {
            $nativeRelative = $nativeRelative.Substring(0,$nativeRelative.Length-3).Replace('\','/')
            $expanded = Join-Path $PlanRoot ('codex-restore-' + [guid]::NewGuid().ToString('N') + '.jsonl')
            $integrityPath = Get-CompressedJsonlIntegrityPath $file.FullName
            if (Test-Path -LiteralPath $integrityPath -PathType Leaf) {
                [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded -IntegrityPath $integrityPath)
            } else {
                Write-Warning "legacy gzip에 integrity metadata가 없습니다. CRC/JSONL 검증 후 읽기 전용으로 복원합니다: $($file.FullName)"
                [void](Expand-JsonlTransportFile -Source $file.FullName -Destination $expanded)
            }
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
