Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-AgentSessionSyncPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
}

function ConvertTo-ClaudeProjectKey {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $fullPath = (Expand-AgentSessionSyncPath $ProjectRoot).TrimEnd('\', '/')
    return ($fullPath -replace '[:\\/\s]', '-')
}

function Get-AgentSessionSyncConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'AgentSessionSync.config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Local configuration is missing: $path`nRun Initialize-AgentSessionSync.ps1 first."
    }
    $raw = Import-PowerShellDataFile -LiteralPath $path
    if (-not $raw.ProjectRoot) { throw 'ProjectRoot is required in AgentSessionSync.config.psd1.' }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $claudeHome = if ($raw.ClaudeHome) { Expand-AgentSessionSyncPath $raw.ClaudeHome } else { Join-Path $userHome '.claude' }
    $codexHome = if ($raw.CodexHome) { Expand-AgentSessionSyncPath $raw.CodexHome } else { Join-Path $userHome '.codex' }
    $projectRoot = Expand-AgentSessionSyncPath $raw.ProjectRoot
    $key = ConvertTo-ClaudeProjectKey $projectRoot
    [pscustomobject]@{
        ProjectRoot = $projectRoot
        SyncProjectGit = [bool]$raw.SyncProjectGit
        IncludeClaudeWorktrees = if ($null -eq $raw.IncludeClaudeWorktrees) { $true } else { [bool]$raw.IncludeClaudeWorktrees }
        ClaudeHome = $claudeHome
        CodexHome = $codexHome
        ClaudeProjectKey = $key
        ClaudeProjectPattern = if ($raw.IncludeClaudeWorktrees) { "$key*" } else { $key }
        ActiveWindowDays = if ($raw.ContainsKey('ActiveWindowDays') -and $raw['ActiveWindowDays']) {
            [int]$raw['ActiveWindowDays']
        } else { 30 }
        TransportFileLimitBytes = if ($raw.ContainsKey('TransportFileLimitBytes') -and $raw['TransportFileLimitBytes']) {
            [int64]$raw['TransportFileLimitBytes']
        } else { 95MB }
        SessionDataPushEnabled = [bool]$raw.SessionDataPushEnabled
        GracefulCloseTimeoutSeconds = if ($raw.ContainsKey('GracefulCloseTimeoutSeconds') -and $raw['GracefulCloseTimeoutSeconds']) {
            [int]$raw['GracefulCloseTimeoutSeconds']
        } else { 8 }
    }
}

function Assert-GitRepository {
    param([Parameter(Mandatory)][string]$Path)
    & git -C $Path rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Not a Git repository: $Path" }
}

function ConvertTo-ExtendedPath {
    <#
      Win32 MAX_PATH(260자)를 넘기기 위한 확장 경로 접두사를 붙인다.
      앱 세션 트리는 조직/계정 GUID 폴더가 겹쳐 경로가 쉽게 길어지고, 거기에 임시 디렉터리나
      깊은 사용자 프로필이 더해지면 한계를 넘는다. 넘는 순간 복사가 "경로를 찾을 수 없음"으로
      실패하므로, 파일을 만지는 .NET 호출에는 항상 이 경로를 쓴다.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Test-JsonlSnapshotComplete {
    <#
      append-only JSONL 스냅숏의 마지막 비어 있지 않은 행이 완전한 JSON인지 확인한다.
      전체 파일을 메모리에 올리지 않으므로 100MiB를 넘는 세션에도 사용할 수 있다.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $lastLine = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($lastLine)) {
        throw "빈 JSONL 스냅숏: $Path"
    }
    try { $null = $lastLine | ConvertFrom-Json }
    catch { throw "기록 중간에서 잘린 JSONL 스냅숏: $Path. 잠시 후 Push를 다시 실행하세요." }
}

function Compress-JsonlTransportFile {
    <#
      GitHub 파일당 100MiB 제한을 넘는 JSONL을 gzip 운반물로 만든다.
      원본 앱 파일은 건드리지 않고, 저장소 안의 전송 사본만 교체한다.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $destinationDirectory = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $destinationDirectory))
    $temporary = "$Destination.tmp-$([guid]::NewGuid().ToString('N'))"
    $input = $null
    $output = $null
    $gzip = $null
    try {
        $input = [IO.File]::OpenRead((ConvertTo-ExtendedPath $Source))
        $output = [IO.File]::Create((ConvertTo-ExtendedPath $temporary))
        $gzip = [IO.Compression.GZipStream]::new($output, [IO.Compression.CompressionLevel]::Optimal, $true)
        $input.CopyTo($gzip)
        $gzip.Dispose()
        $gzip = $null
        $output.Dispose()
        $output = $null
        $input.Dispose()
        $input = $null
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
        [IO.File]::Move((ConvertTo-ExtendedPath $temporary), (ConvertTo-ExtendedPath $Destination))
        [IO.File]::SetLastWriteTimeUtc((ConvertTo-ExtendedPath $Destination), [IO.File]::GetLastWriteTimeUtc((ConvertTo-ExtendedPath $Source)))
    }
    finally {
        if ($gzip) { $gzip.Dispose() }
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Test-CompressedJsonlTransportCurrent {
    <#
      변경되지 않은 append-only JSONL을 매 Push마다 다시 검사·압축하지 않도록
      기존 gzip 운반물이 현재 raw 스냅숏과 같은지를 저비용으로 판정한다.

      Compress-JsonlTransportFile은 gzip의 LastWriteTimeUtc를 원본과 같게 보존한다.
      gzip footer의 ISIZE는 비압축 원본 길이 modulo 2^32를 담으므로, 두 값이 모두
      일치하면 이 워크플로의 append-only 계약 아래에서는 기존 운반물을 재사용한다.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Compressed
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Compressed -PathType Leaf)) { return $false }

    $sourceInfo = Get-Item -LiteralPath $Source
    $compressedInfo = Get-Item -LiteralPath $Compressed
    if ($sourceInfo.LastWriteTimeUtc -ne $compressedInfo.LastWriteTimeUtc) { return $false }
    if ($compressedInfo.Length -lt 4) { return $false }

    $stream = $null
    try {
        $stream = [IO.File]::OpenRead((ConvertTo-ExtendedPath $Compressed))
        [void]$stream.Seek(-4, [IO.SeekOrigin]::End)
        $footer = New-Object byte[] 4
        if ($stream.Read($footer, 0, 4) -ne 4) { return $false }
        $storedLength = [BitConverter]::ToUInt32($footer, 0)
        $expectedLength = [uint32]($sourceInfo.Length % ([int64]4294967296))
        return $storedLength -eq $expectedLength
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Expand-JsonlTransportFile {
    <#
      gzip 운반물을 로컬 앱이 읽는 원래 JSONL 경로로 복원한다.
      수신측 파일이 더 최신이면 기존 /XO 계약과 마찬가지로 덮어쓰지 않는다.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $sourceTime = [IO.File]::GetLastWriteTimeUtc((ConvertTo-ExtendedPath $Source))
    if (Test-Path -LiteralPath $Destination) {
        $destinationTime = [IO.File]::GetLastWriteTimeUtc((ConvertTo-ExtendedPath $Destination))
        if ($destinationTime -ge $sourceTime) { return $false }
    }
    $destinationDirectory = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $destinationDirectory))
    $temporary = "$Destination.tmp-$([guid]::NewGuid().ToString('N'))"
    $input = $null
    $gzip = $null
    $output = $null
    try {
        $input = [IO.File]::OpenRead((ConvertTo-ExtendedPath $Source))
        $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress, $true)
        $output = [IO.File]::Create((ConvertTo-ExtendedPath $temporary))
        $gzip.CopyTo($output)
        $output.Dispose()
        $output = $null
        $gzip.Dispose()
        $gzip = $null
        $input.Dispose()
        $input = $null
        Test-JsonlSnapshotComplete $temporary
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
        [IO.File]::Move((ConvertTo-ExtendedPath $temporary), (ConvertTo-ExtendedPath $Destination))
        [IO.File]::SetLastWriteTimeUtc((ConvertTo-ExtendedPath $Destination), $sourceTime)
        return $true
    }
    finally {
        if ($output) { $output.Dispose() }
        if ($gzip) { $gzip.Dispose() }
        if ($input) { $input.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Expand-CompressedJsonlTree {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $expanded = 0
    if (-not (Test-Path -LiteralPath $SourceRoot)) { return $expanded }
    $resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedSourceRoot -Filter '*.jsonl.gz' -File -Recurse -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($resolvedSourceRoot.Length).TrimStart('\', '/')
        $target = Join-Path $DestinationRoot $relative.Substring(0, $relative.Length - '.gz'.Length)
        if (Expand-JsonlTransportFile -Source $file.FullName -Destination $target) { $expanded++ }
    }
    return $expanded
}

function Get-TransportRecentPaths {
    <#
      최근 $Days 안에 이 저장소에서 내용이 실제로 바뀐 전송 경로 집합.
      폴더 이름 변경은 내용 변경이 아니므로 -M 으로 rename 을 걸러낸다(그러지 않으면
      전송 레이아웃을 한 번 바꾼 날 모든 파일이 "최근"으로 잡힌다).
      상대 PC 가 방금 올린 세션을 아카이브로 잘못 내리지 않게 하는 안전장치다.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][int]$Days,
        [Parameter(Mandatory)][string]$PathSpec
    )
    $set = @{}
    $lines = @(& git -C $RepoRoot log --since="$Days days ago" --format='' --name-status -M --diff-filter=AM -- $PathSpec)
    foreach ($line in $lines) {
        if ($line -match '^[AM]\S*\s+(.+)$') { $set[$Matches[1].Trim()] = $true }
    }
    return $set
}

function Get-ClaudeDeletionMarkers {
    # 앱이 대화를 지우면 deleted_<appSessionId> 파일을 남긴다. 이것이 "이 대화는 폐기했다"는
    # 사용자의 명시적 선언이고, 이 도구가 쓸 수 있는 유일한 삭제 신호다.
    param([Parameter(Mandatory)][string]$RegistryRoot)
    $ids = @{}
    if (-not (Test-Path -LiteralPath $RegistryRoot)) { return $ids }
    Get-ChildItem -LiteralPath $RegistryRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'deleted_*' } |
        ForEach-Object { $ids[($_.Name -replace '^deleted_', '')] = $true }
    return $ids
}

function Copy-ClaudeDeletionMarkers {
    # 마커도 운반한다. 마커가 없으면 한쪽에서 지운 대화가 반대편 Pull 때 되살아난다.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $copied = 0
    if (-not (Test-Path -LiteralPath $Source)) { return $copied }
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'deleted_*' })) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $target = Join-Path $Destination $relative
        if (Test-Path -LiteralPath $target) { continue }
        # 세션 트리는 GUID 두 단계가 겹쳐 경로가 길다. 프로바이더를 거치지 않는 .NET 호출로
        # 디렉터리를 만들고 복사한다(PowerShell 프로바이더 경로는 여기서 한계에 먼저 걸린다).
        [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($target))))
        [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
        $copied++
    }
    return $copied
}

function Remove-TombstonedLocalEntries {
    <#
      마커가 붙은 목록 항목을 이 PC에서도 실제로 치운다.
      머지에서 "복사하지 않음"만으로는 부족하다. 그 대화를 원래 갖고 있던 PC에서는
      로컬 항목이 그대로 남아 삭제가 반영되지 않기 때문이다.

      목록 항목은 메타데이터일 뿐이고 대화 원문(transcript)은 건드리지 않는다.
      저장소 히스토리에도 그대로 남아 있으므로 되돌릴 수 있다.
    #>
    param([Parameter(Mandatory)][string]$RegistryRoot)
    $removed = 0
    if (-not (Test-Path -LiteralPath $RegistryRoot)) { return $removed }
    $markers = Get-ClaudeDeletionMarkers $RegistryRoot
    if ($markers.Count -eq 0) { return $removed }
    foreach ($file in @(Get-ChildItem -LiteralPath $RegistryRoot -Filter 'local_*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        $appId = $file.BaseName -replace '^local_', ''
        if (-not $markers.ContainsKey($appId)) { continue }
        Remove-Item -LiteralPath $file.FullName -Force
        $removed++
    }
    return $removed
}

function Remove-TombstonedTransportEntries {
    # 폐기된 목록 항목은 저장소 활성 레지스트리에서도 뺀다. 항목은 아카이브 가치가 없다
    # (원문은 Claude/projects · Claude/archive 에 따로 보존되고, git 히스토리에도 남는다).
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RegistryDestination,
        [Parameter(Mandatory)][hashtable]$Markers
    )
    $removed = 0
    if (-not (Test-Path -LiteralPath $RegistryDestination)) { return $removed }
    foreach ($file in @(Get-ChildItem -LiteralPath $RegistryDestination -Filter 'local_*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        $appId = $file.BaseName -replace '^local_', ''
        if (-not $Markers.ContainsKey($appId)) { continue }
        Remove-Item -LiteralPath $file.FullName -Force
        $removed++
    }
    return $removed
}

function Move-ToTransportArchive {
    <#
      활성 폴더에서 archive 폴더로 옮기기만 한다. 삭제하지 않는다.
      Pull 은 활성 폴더만 복원하므로 앱이 보는 표면에서는 사라지지만 원문은 저장소에 남고
      Restore-ArchivedSession.ps1 로 언제든 되돌릴 수 있다.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ActiveRoot,
        [Parameter(Mandatory)][string]$ArchiveRoot
    )
    $targetRelative = $ArchiveRoot + $RelativePath.Substring($ActiveRoot.Length)
    $sourceFull = Join-Path $RepoRoot ($RelativePath.Replace('/', '\'))
    $targetFull = Join-Path $RepoRoot ($targetRelative.Replace('/', '\'))
    $targetDir = Split-Path -Parent $targetFull
    [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $targetDir))
    if ([IO.File]::Exists((ConvertTo-ExtendedPath $targetFull))) { [IO.File]::Delete((ConvertTo-ExtendedPath $targetFull)) }

    if (@(& git -C $RepoRoot ls-files -- $RelativePath)) {
        & git -C $RepoRoot mv -- $RelativePath $targetRelative
        if ($LASTEXITCODE -ne 0) { throw "archive 이동 실패: $RelativePath" }
    } else {
        [IO.File]::Move((ConvertTo-ExtendedPath $sourceFull), (ConvertTo-ExtendedPath $targetFull))
    }
    return $targetRelative
}

function Get-CodexSessionId {
    # rollout 파일명 끝의 UUID 가 세션 id 다. .jsonl / .jsonl.gz 양쪽을 받는다.
    param([Parameter(Mandatory)][string]$FileName)
    $bare = $FileName -replace '\.gz$', '' -replace '\.jsonl$', ''
    if ($bare -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { return $Matches[1] }
    return $null
}

function Get-CodexRolloutIds {
    param([Parameter(Mandatory)][string]$Root)
    $ids = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $ids }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' })) {
        $id = Get-CodexSessionId $file.Name
        if (-not $id) { continue }
        if ($ids.ContainsKey($id) -and
            -not [string]::Equals($ids[$id].FullName, $file.FullName, [StringComparison]::OrdinalIgnoreCase)) {
            $knownCanonical = $ids[$id].FullName -replace '\.gz$', ''
            $fileCanonical = $file.FullName -replace '\.gz$', ''
            if ([string]::Equals($knownCanonical, $fileCanonical, [StringComparison]::OrdinalIgnoreCase)) {
                # Push가 최신 raw 스냅숏을 만든 뒤 gzip 단계에서 기존 .gz를 교체하기 전의
                # 정상 과도기다. 같은 cwd/date/file의 두 표현만 허용하고 raw를 우선한다.
                if ($file.Name -like '*.jsonl') { $ids[$id] = $file }
                continue
            }
            throw "같은 Codex 세션 ID가 둘 이상의 경로에 있습니다: $id`n  $($ids[$id].FullName)`n  $($file.FullName)"
        }
        $ids[$id] = $file
    }
    return $ids
}

function Get-CodexSessionOriginCwd {
    <# rollout 의 첫 session_meta.payload.cwd 를 읽는다. 파일 위치나 현재 호스트 cwd 는
       세션의 출처가 아니므로 사용하지 않는다. raw/gzip 모두 스트리밍으로 처리한다. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $rawStream = $null; $gzipStream = $null; $reader = $null
    try {
        if ($Path -like '*.gz') {
            $rawStream = [IO.File]::OpenRead((ConvertTo-ExtendedPath $Path))
            $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $true)
            $reader = [IO.StreamReader]::new($gzipStream)
        } else {
            $rawStream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
                [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader = [IO.StreamReader]::new($rawStream, [Text.Encoding]::UTF8, $true)
        }

        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $record = $null
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($null -eq $record -or [string]$record.type -ne 'session_meta') { continue }
            if ($null -eq $record.payload) { continue }
            $cwd = [string]$record.payload.cwd
            if (-not [string]::IsNullOrWhiteSpace($cwd)) { return $cwd }
        }
        return $null
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($rawStream) { $rawStream.Dispose() }
    }
}

function Copy-OpenFileSnapshot {
    <# 실행 중인 append-only JSONL도 FileShare.ReadWrite로 현재까지의 바이트를 복사한다. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $directory = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $directory))
    $temporary = "$Destination.tmp-$([guid]::NewGuid().ToString('N'))"
    $input = $null; $output = $null
    try {
        $input = [IO.FileStream]::new((ConvertTo-ExtendedPath $Source), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $output = [IO.File]::Create((ConvertTo-ExtendedPath $temporary))
        $input.CopyTo($output)
        $output.Dispose(); $output = $null
        $input.Dispose(); $input = $null
        if ([IO.File]::Exists((ConvertTo-ExtendedPath $Destination))) {
            [IO.File]::Delete((ConvertTo-ExtendedPath $Destination))
        }
        [IO.File]::Move((ConvertTo-ExtendedPath $temporary), (ConvertTo-ExtendedPath $Destination))
        [IO.File]::SetLastWriteTimeUtc((ConvertTo-ExtendedPath $Destination),
            [IO.File]::GetLastWriteTimeUtc((ConvertTo-ExtendedPath $Source)))
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ([IO.File]::Exists((ConvertTo-ExtendedPath $temporary))) { [IO.File]::Delete((ConvertTo-ExtendedPath $temporary)) }
    }
}

function Get-CodexTransportProjectKey {
    param([Parameter(Mandatory)][string]$Path)
    $cwd = Get-CodexSessionOriginCwd $Path
    if ([string]::IsNullOrWhiteSpace($cwd)) { return '_no-cwd' }
    try { return ConvertTo-ClaudeProjectKey $cwd }
    catch { return '_no-cwd' }
}

function Get-CodexNativeRelativePath {
    <#
      새 Vault 경로: <cwd-key>/YYYY/MM/DD/file
      구 Vault 경로: YYYY/MM/DD/file
      로컬 앱에는 두 경우 모두 YYYY/MM/DD/file 로 복원한다.
    #>
    param(
        [Parameter(Mandatory)][string]$TransportRoot,
        [Parameter(Mandatory)][string]$Path
    )
    $root = [IO.Path]::GetFullPath($TransportRoot).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    $relative = $full.Substring($root.Length).TrimStart('\', '/')
    $parts = @($relative -split '[\\/]')
    if ($parts.Count -lt 2) { throw "Codex 전송 경로 형식을 판정할 수 없습니다: $Path" }
    if ($parts[0] -match '^\d{4}$' -or $parts[0] -eq 'undated') { return $relative }
    if ($parts.Count -lt 3) { throw "cwd-key 뒤 날짜 경로가 없습니다: $Path" }
    return ($parts[1..($parts.Count - 1)] -join [IO.Path]::DirectorySeparatorChar)
}

function Copy-CodexNativeTreeToTransport {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $copied = 0
    if (-not (Test-Path -LiteralPath $SourceRoot)) { return $copied }
    $source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
        $nativeRelative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        $key = Get-CodexTransportProjectKey $file.FullName
        $target = Join-Path (Join-Path $DestinationRoot $key) $nativeRelative
        Copy-OpenFileSnapshot -Source $file.FullName -Destination $target
        $copied++
    }
    return $copied
}

function Copy-CodexTransportTreeToNative {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $stats = [ordered]@{ Raw = 0; Expanded = 0 }
    if (-not (Test-Path -LiteralPath $SourceRoot)) { return [pscustomobject]$stats }
    Get-CodexRolloutIds $SourceRoot | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' })) {
        $nativeRelative = Get-CodexNativeRelativePath -TransportRoot $SourceRoot -Path $file.FullName
        if ($file.Name -like '*.jsonl.gz') { $nativeRelative = $nativeRelative.Substring(0, $nativeRelative.Length - '.gz'.Length) }
        $target = Join-Path $DestinationRoot $nativeRelative
        if ($file.Name -like '*.jsonl.gz') {
            if (Expand-JsonlTransportFile -Source $file.FullName -Destination $target) { $stats.Expanded++ }
            continue
        }
        $sourceTime = $file.LastWriteTimeUtc
        if (Test-Path -LiteralPath $target) {
            $targetTime = [IO.File]::GetLastWriteTimeUtc((ConvertTo-ExtendedPath $target))
            if ($targetTime -ge $sourceTime) { continue }
        }
        [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($target))))
        [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
        [IO.File]::SetLastWriteTimeUtc((ConvertTo-ExtendedPath $target), $sourceTime)
        $stats.Raw++
    }
    return [pscustomobject]$stats
}

function Move-CodexLegacyTransportTree {
    <# 날짜로 바로 시작하는 구 Vault 경로를 rollout 내부 cwd 키 아래로 git mv 한다. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TreeRelative
    )
    $tree = Join-Path $RepoRoot ($TreeRelative.Replace('/', '\'))
    $moved = 0
    if (-not (Test-Path -LiteralPath $tree)) { return $moved }
    foreach ($file in @(Get-ChildItem -LiteralPath $tree -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like '*.jsonl.gz' })) {
        $relativeInside = $file.FullName.Substring($tree.Length).TrimStart('\', '/')
        $first = ($relativeInside -split '[\\/]')[0]
        if ($first -notmatch '^\d{4}$' -and $first -ne 'undated') { continue }
        $key = Get-CodexTransportProjectKey $file.FullName
        $targetInside = Join-Path $key $relativeInside
        $targetFull = Join-Path $tree $targetInside
        if (Test-Path -LiteralPath $targetFull) {
            throw "Codex 레거시 경로 마이그레이션 대상이 이미 있습니다: $targetFull"
        }
        [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($targetFull))))
        $sourceRelative = ($TreeRelative.TrimEnd('/') + '/' + $relativeInside.Replace('\', '/'))
        $targetRelative = ($TreeRelative.TrimEnd('/') + '/' + $targetInside.Replace('\', '/'))
        if (@(& git -C $RepoRoot ls-files -- $sourceRelative)) {
            & git -C $RepoRoot mv -- $sourceRelative $targetRelative
            if ($LASTEXITCODE -ne 0) { throw "Codex cwd-key 마이그레이션 실패: $sourceRelative" }
        } else {
            [IO.File]::Move((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $targetFull))
        }
        $moved++
    }
    Get-CodexRolloutIds $tree | Out-Null
    return $moved
}

function Get-JsonlLastActivity {
    <#
      세션 원문 안의 마지막 timestamp 를 읽어 [datetime](UTC) 로 돌려준다. 못 찾으면 $null.

      나이 판정에 파일 mtime 이나 복사 시각을 쓰면 안 된다. git checkout 이 mtime 을 덮어쓰고
      robocopy 는 호스트 시계를 따르므로 두 PC 에서 다른 값이 나온다. 파일명의 시작일도 안 된다 —
      40일 전에 시작해 오늘까지 이어온 대화를 노후로 오판한다. 내용에 적힌 마지막 활동만이
      호스트와 무관하게 같은 값을 준다.

      .jsonl.gz 는 탐색이 안 되므로 스트리밍으로 한 번 훑는다.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TailLineCount = 400
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fullPath = ConvertTo-ExtendedPath $Path

    # 각 줄은 JSON 객체다. 최상위 timestamp 만 활동 시각이며, session_meta.payload.timestamp 나
    # 대화 본문에 박힌 시각은 아니다. 정규식으로 줄 안의 마지막 "timestamp" 를 집으면 중첩된
    # 값을 골라 경계 날짜에서 오분류된다. 그러므로 파싱해서 최상위 속성만 읽는다.
    # 전체를 파싱하면 100MiB 급에서 느리므로 끝의 몇 줄만 보관했다가 뒤에서부터 확인한다.
    $tail = New-Object System.Collections.Generic.Queue[string]
    $pushLine = {
        param($line)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $tail.Enqueue($line)
        while ($tail.Count -gt $TailLineCount) { [void]$tail.Dequeue() }
    }

    if ($Path -like '*.gz') {
        $rawStream = $null; $gzipStream = $null; $reader = $null
        try {
            $rawStream = [IO.File]::OpenRead($fullPath)
            $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $true)
            $reader = [IO.StreamReader]::new($gzipStream)
            while ($null -ne ($line = $reader.ReadLine())) { & $pushLine $line }
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($gzipStream) { $gzipStream.Dispose() }
            if ($rawStream) { $rawStream.Dispose() }
        }
    } else {
        foreach ($line in [IO.File]::ReadLines($fullPath)) { & $pushLine $line }
    }

    $lines = @($tail.ToArray())
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $record = $null
        try { $record = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($null -eq $record) { continue }
        if ($record.PSObject.Properties.Name -notcontains 'timestamp') { continue }
        $value = $record.timestamp
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        try { return ([datetimeoffset]([string]$value)).UtcDateTime } catch { continue }
    }
    return $null
}

function Split-CodexSessionIndex {
    <#
      Codex 목록 인덱스를 세 갈래로 나눈다.
        active  : 활성 rollout 이 있는 항목
        archived: 보관된 rollout 이 있는 항목 — 지우지 않고 archive 인덱스로 옮긴다
        orphan  : 어디에도 원문이 없는 항목 — 목록에만 남은 껍데기
      인덱스는 Sync-CodexIndex.ps1 이 id 기준 union 으로 합치므로, 보관 항목을 활성
      인덱스에서 그냥 지우면 상대 PC 에서 되살아난다. 옮겨 담아야 한다.
    #>
    param(
        [Parameter(Mandatory)][string]$IndexPath,
        [Parameter(Mandatory)][hashtable]$ActiveIds,
        [Parameter(Mandatory)][hashtable]$ArchivedIds
    )
    $result = @{ Active = @(); Archived = @(); Orphan = @() }
    if (-not (Test-Path -LiteralPath $IndexPath)) { return $result }
    foreach ($line in (Get-Content -LiteralPath $IndexPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $id = $null
        if ($line -match '"id"\s*:\s*"([^"]+)"') { $id = $Matches[1] }
        if (-not $id) { continue }
        if ($ActiveIds.ContainsKey($id))        { $result.Active   += $line }
        elseif ($ArchivedIds.ContainsKey($id))  { $result.Archived += $line }
        else                                    { $result.Orphan   += $line }
    }
    return $result
}

function Write-CodexIndexLines {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines = @())
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $body = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    [IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-ClaudeAppEntryBound {
    # 앱 목록 항목이 트랜스크립트와 연결되어 있는지(= cliSessionId 보유) 판정한다.
    # 앱은 트랜스크립트를 못 찾으면 이 필드를 떼어내고 transcriptUnavailable 을 찍는다.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = [IO.File]::ReadAllText((ConvertTo-ExtendedPath $Path), [Text.Encoding]::UTF8)
    return [regex]::IsMatch($text, '"cliSessionId"\s*:\s*"[^"]+"')
}

function Merge-ClaudeAppRegistry {
    <#
    .SYNOPSIS
      앱 대화목록 레지스트리(local_*.json)를 항목 단위로 머지한다.
    .NOTES
      robocopy 통짜 복사는 last-writer-wins 이다. 트랜스크립트가 없는 PC에서 앱이
      cliSessionId 를 떼어낸 항목을 만들면, 그 손상본이 상대 PC의 멀쩡한 항목까지
      덮어써 연결이 영구히 사라진다. Codex 인덱스가 Sync-CodexIndex.ps1 로 union
      머지를 하는 것과 같은 이유로, 이 다리도 항목 단위 규칙이 필요하다.

        삭제 마커 보유     -> 건너뜀(폐기 선언 존중)
        대상에 없음        -> 복사
        원본만 바인딩 보유 -> 복사(복구)
        대상만 바인딩 보유 -> 건너뜀(보호)
        그 외              -> 원본이 더 최신일 때만 복사(robocopy /XO 와 동일)
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [hashtable]$Tombstones = @{}
    )
    $stats = [ordered]@{ New = 0; Repaired = 0; Protected = 0; Updated = 0; Unchanged = 0; Tombstoned = 0 }
    if (-not (Test-Path -LiteralPath $Source)) { return $stats }
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')

    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Filter 'local_*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        $appId = $file.BaseName -replace '^local_', ''
        if ($Tombstones.ContainsKey($appId)) { $stats.Tombstoned++; continue }
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $target = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($target))))

        if (-not (Test-Path -LiteralPath $target)) {
            [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
            $stats.New++
            continue
        }

        $sourceBound = Test-ClaudeAppEntryBound $file.FullName
        $targetBound = Test-ClaudeAppEntryBound $target
        if ($sourceBound -and -not $targetBound) {
            [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
            $stats.Repaired++
        } elseif ($targetBound -and -not $sourceBound) {
            $stats.Protected++
        } elseif ($file.LastWriteTimeUtc -gt (Get-Item -LiteralPath $target).LastWriteTimeUtc) {
            [IO.File]::Copy((ConvertTo-ExtendedPath $file.FullName), (ConvertTo-ExtendedPath $target), $true)
            $stats.Updated++
        } else {
            $stats.Unchanged++
        }
    }
    return $stats
}

function Write-ClaudeAppRegistryStats {
    param(
        [Parameter(Mandatory)]$Stats,
        [Parameter(Mandatory)][string]$Label
    )
    Write-Host ("  [{0}] 앱 목록 항목: 신규 {1} / 복구 {2} / 보호 {3} / 갱신 {4} / 유지 {5} / 폐기 {6}" -f `
        $Label, $Stats.New, $Stats.Repaired, $Stats.Protected, $Stats.Updated, $Stats.Unchanged, $Stats.Tombstoned) -ForegroundColor DarkCyan
    if ($Stats.Protected -gt 0) {
        Write-Host "    (보호 = 상대편 항목이 트랜스크립트 연결을 잃은 상태라 덮어쓰지 않음)" -ForegroundColor DarkGray
    }
    if ($Stats.Tombstoned -gt 0) {
        Write-Host "    (폐기 = 삭제 마커가 있어 목록에 되살리지 않음. 원문 transcript 는 보존)" -ForegroundColor DarkGray
    }
}
