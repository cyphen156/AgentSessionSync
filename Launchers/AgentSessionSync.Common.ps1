Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

function Expand-AgentSessionSyncPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
}

function ConvertTo-SessionPathKey {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = (Expand-AgentSessionSyncPath $Path).TrimEnd('\', '/')
    return ($fullPath -replace '[:\\/\s]', '-')
}

function Get-AgentSessionSyncConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'AgentSessionSync.config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Local configuration is missing: $path`nRun Initialize-AgentSessionSync.ps1 first."
    }
    $raw = Import-PowerShellDataFile -LiteralPath $path
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $claudeHome = if ($raw.ClaudeHome) { Expand-AgentSessionSyncPath $raw.ClaudeHome } else { Join-Path $userHome '.claude' }
    $codexHome = if ($raw.CodexHome) { Expand-AgentSessionSyncPath $raw.CodexHome } else { Join-Path $userHome '.codex' }
    [pscustomobject]@{
        ClaudeHome = $claudeHome
        CodexHome = $codexHome
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

function Get-CompressedJsonlIntegrityPath {
    param([Parameter(Mandatory)][string]$Compressed)
    $Compressed + '.integrity.json'
}

function Read-CompressedJsonlIntegrity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "gzip integrity metadata가 없습니다: $Path" }
    try { $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "gzip integrity metadata를 읽을 수 없습니다: $Path" }
    foreach ($name in @('schemaVersion','rawLength','rawSha256','gzipLength','gzipSha256')) {
        if (-not ($value.PSObject.Properties.Name -contains $name)) { throw "gzip integrity metadata 필드가 없습니다: $name ($Path)" }
    }
    if ([int]$value.schemaVersion -ne 1 -or [int64]$value.rawLength -lt 0 -or [int64]$value.gzipLength -lt 0 -or
        [string]$value.rawSha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$value.gzipSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "gzip integrity metadata가 유효하지 않습니다: $Path"
    }
    [pscustomobject]@{
        SchemaVersion = 1
        RawLength = [int64]$value.rawLength
        RawSha256 = ([string]$value.rawSha256).ToLowerInvariant()
        GzipLength = [int64]$value.gzipLength
        GzipSha256 = ([string]$value.gzipSha256).ToLowerInvariant()
    }
}

function New-CompressedJsonlIntegrityArtifact {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Compressed,
        [Parameter(Mandatory)][string]$PlanRoot,
        [string]$Name = 'gzip-integrity'
    )
    $metadata = [ordered]@{
        schemaVersion = 1
        rawLength = [int64](Get-Item -LiteralPath $Raw).Length
        rawSha256 = Get-AgentSessionFileSha256 $Raw
        gzipLength = [int64](Get-Item -LiteralPath $Compressed).Length
        gzipSha256 = Get-AgentSessionFileSha256 $Compressed
    }
    $safeName = $Name -replace '[^A-Za-z0-9._-]', '_'
    $path = Join-Path $PlanRoot ($safeName + '-' + [guid]::NewGuid().ToString('N') + '.integrity.json')
    Write-AgentSessionUtf8File -Path $path -Content ($metadata | ConvertTo-Json -Depth 3) -NoBom
    [pscustomobject]@{ Path=$path;Sha256=(Get-AgentSessionFileSha256 $path);Metadata=[pscustomobject]$metadata }
}

function Test-CompressedJsonlTransportCurrent {
    <# 기존 gzip은 raw/gzip 길이와 SHA-256 네 값이 모두 맞을 때만 재사용한다. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Compressed,
        [Parameter(Mandatory)][string]$IntegrityPath
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf) -or -not (Test-Path -LiteralPath $Compressed -PathType Leaf) -or
        -not (Test-Path -LiteralPath $IntegrityPath -PathType Leaf)) { return $false }
    try { $metadata = Read-CompressedJsonlIntegrity $IntegrityPath } catch { return $false }
    if ((Get-Item -LiteralPath $Source).Length -ne $metadata.RawLength -or
        (Get-Item -LiteralPath $Compressed).Length -ne $metadata.GzipLength) { return $false }
    if (-not [string]::Equals((Get-AgentSessionFileSha256 $Source), $metadata.RawSha256, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals((Get-AgentSessionFileSha256 $Compressed), $metadata.GzipSha256, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $true
}

function Expand-JsonlTransportFile {
    <#
      gzip 운반물을 로컬 앱이 읽는 원래 JSONL 경로로 복원한다.
      수신측 파일이 더 최신이면 기존 /XO 계약과 마찬가지로 덮어쓰지 않는다.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$IntegrityPath = ''
    )
    $integrity = $null
    if ($IntegrityPath) {
        $integrity = Read-CompressedJsonlIntegrity $IntegrityPath
        $sourceInfo = Get-Item -LiteralPath $Source
        if ($sourceInfo.Length -ne $integrity.GzipLength -or
            -not [string]::Equals((Get-AgentSessionFileSha256 $Source), $integrity.GzipSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "gzip 운반물 SHA-256 또는 길이가 metadata와 다릅니다: $Source"
        }
    }
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
        if ($integrity -and ((Get-Item -LiteralPath $temporary).Length -ne $integrity.RawLength -or
            -not [string]::Equals((Get-AgentSessionFileSha256 $temporary), $integrity.RawSha256, [StringComparison]::OrdinalIgnoreCase))) {
            throw "gzip 복원 원문의 SHA-256 또는 길이가 metadata와 다릅니다: $Source"
        }
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

function Get-JsonlLastActivity {
    <#
      세션 원문 안의 마지막 timestamp 를 읽어 [datetime](UTC) 로 돌려준다. 못 찾으면 $null.

      나이 판정에 파일 mtime 이나 복사 시각을 쓰면 안 된다. git checkout 이 mtime 을 덮어쓰고
      robocopy 는 호스트 시계를 따르므로 두 PC 에서 다른 값이 나온다. 파일명의 시작일도 안 된다 —
      40일 전에 시작해 오늘까지 이어온 대화를 노후로 오판한다. 내용에 적힌 마지막 활동만이
      호스트와 무관하게 같은 값을 준다.

      .jsonl.gz 는 탐색이 안 되므로 스트리밍으로 한 번 훑는다.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fullPath = ConvertTo-ExtendedPath $Path

    # 각 줄은 JSON 객체다. 최상위 timestamp만 활동 시각이다. 마지막 수백 줄에 timestamp가
    # 있다는 가정도 하지 않는다. 스트리밍으로 전체를 읽되 마지막 유효 값 하나만 보관한다.
    $state = [pscustomobject]@{ Latest = $null }
    $inspectLine = {
        param($line)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        try { $record = $line | ConvertFrom-Json } catch { return }
        if ($null -eq $record -or $record.PSObject.Properties.Name -notcontains 'timestamp') { return }
        try {
            $timestamp = $record.timestamp
            if ($timestamp -is [datetimeoffset]) {
                $state.Latest = $timestamp.UtcDateTime
            } elseif ($timestamp -is [datetime]) {
                $state.Latest = $timestamp.ToUniversalTime()
            } else {
                $state.Latest = ([datetimeoffset]([string]$timestamp)).UtcDateTime
            }
        } catch {}
    }

    if ($Path -like '*.gz') {
        $rawStream = $null; $gzipStream = $null; $reader = $null
        try {
            $rawStream = [IO.File]::OpenRead($fullPath)
            $gzipStream = [IO.Compression.GZipStream]::new($rawStream, [IO.Compression.CompressionMode]::Decompress, $true)
            $reader = [IO.StreamReader]::new($gzipStream)
            while ($null -ne ($line = $reader.ReadLine())) { & $inspectLine $line }
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($gzipStream) { $gzipStream.Dispose() }
            if ($rawStream) { $rawStream.Dispose() }
        }
    } else {
        foreach ($line in [IO.File]::ReadLines($fullPath)) { & $inspectLine $line }
    }
    return $state.Latest
}

function Get-AgentSessionFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $sha = [Security.Cryptography.SHA256]::Create()
        ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Write-AgentSessionUtf8File {
    <#
      기본값은 BOM 있는 UTF-8 이다. Windows PowerShell 5.1 은 -Encoding 없이 읽을 때
      BOM 없는 UTF-8 을 CP949 로 오독하므로, 우리가 다시 읽는 설정·사이드카·checkpoint
      에는 BOM 이 필요하다.

      -NoBom 은 그 반대편을 위한 것이다. 외부 런타임이 읽는 산출물에는 BOM 을 붙이면
      안 된다. 특히 Node 의 JSON.parse 는 선행 BOM 에서 예외를 던지므로, Claude 앱이
      읽는 목록 항목에 BOM 이 붙으면 앱이 그 항목을 조용히 버리고 사이드바에서 사라진다.
      호출부는 "누가 이 파일을 읽는가" 로 선택해야 한다.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$NoBom
    )
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $parent))
    $encoding = New-Object Text.UTF8Encoding(-not $NoBom)
    [IO.File]::WriteAllText((ConvertTo-ExtendedPath $Path), $Content, $encoding)
}

function New-AgentSessionPlanRoot {
    param([string]$Prefix = 'AgentSessionSync-Plan')
    $root = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [IO.Path]::GetFullPath($root)
}

function New-AgentSessionStagedSnapshot {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PlanRoot,
        [Parameter(Mandatory)][string]$Name
    )
    $safeName = $Name -replace '[^A-Za-z0-9._-]', '_'
    $target = Join-Path $PlanRoot ($safeName + '-' + [guid]::NewGuid().ToString('N'))
    Copy-OpenFileSnapshot -Source $Source -Destination $target
    [pscustomobject]@{ Path = $target; Sha256 = Get-AgentSessionFileSha256 $target }
}

function New-AgentSessionPutOperation {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][ValidateSet('StagedFile', 'VaultFile')][string]$SourceKind,
        [string]$SourcePath = '',
        [string]$SourceRelativePath = '',
        [Parameter(Mandatory)][string]$SourceSha256,
        [string]$SourceCommit = ''
    )
    [pscustomobject]@{
        Kind = 'Put'
        TargetRoot = $TargetRoot
        RelativePath = $RelativePath.Replace('\', '/')
        SourceKind = $SourceKind
        SourcePath = $SourcePath
        SourceRelativePath = $SourceRelativePath.Replace('\', '/')
        SourceSha256 = $SourceSha256.ToLowerInvariant()
        SourceCommit = $SourceCommit
    }
}

function New-AgentSessionDeleteOperation {
    param([Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][string]$RelativePath)
    [pscustomobject]@{
        Kind = 'Delete'
        TargetRoot = $TargetRoot
        RelativePath = $RelativePath.Replace('\', '/')
        SourceKind = ''
        SourcePath = ''
        SourceRelativePath = ''
        SourceSha256 = ''
        SourceCommit = ''
    }
}

function Test-AgentSessionSafeRelativePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) { return $false }
    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized.StartsWith('/') -or $normalized.EndsWith('/')) { return $false }
    foreach ($segment in $normalized.Split('/')) {
        if (-not $segment -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

function Resolve-AgentSessionOperationTarget {
    param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][hashtable]$RootMap)
    if (-not $RootMap.ContainsKey([string]$Operation.TargetRoot)) {
        throw "Unknown TargetRoot: $($Operation.TargetRoot)"
    }
    if (-not (Test-AgentSessionSafeRelativePath ([string]$Operation.RelativePath))) {
        throw "Unsafe relative path: $($Operation.RelativePath)"
    }
    $root = [IO.Path]::GetFullPath([string]$RootMap[[string]$Operation.TargetRoot]).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath((Join-Path $root ([string]$Operation.RelativePath -replace '/', '\')))
    if (-not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Operation target escapes its root: $target"
    }
    $target
}

function Assert-AgentSessionPlans {
    param(
        [Parameter(Mandatory)][array]$Plans,
        [Parameter(Mandatory)][hashtable]$RootMap,
        [Parameter(Mandatory)][string]$ExpectedVaultCommit,
        [Parameter(Mandatory)][string]$PlanRoot,
        [string[]]$OperationProperties = @('VaultOperations', 'LocalOperations')
    )
    $planRootFull = [IO.Path]::GetFullPath($PlanRoot).TrimEnd('\', '/')
    $keys = @{}
    foreach ($plan in $Plans) {
        if ([int]$plan.SchemaVersion -ne 1) { throw "Unsupported plan schema: $($plan.SchemaVersion)" }
        if (-not [string]::Equals([string]$plan.ExpectedVaultCommit, $ExpectedVaultCommit, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Plan commit mismatch: $($plan.Agent) $($plan.ExpectedVaultCommit)"
        }
        foreach ($property in $OperationProperties) {
            if (-not ($plan.PSObject.Properties.Name -contains $property)) { continue }
            foreach ($operation in @($plan.$property)) {
                if ([string]$operation.Kind -notin @('Put', 'Delete')) { throw "Unsupported operation kind: $($operation.Kind)" }
                [void](Resolve-AgentSessionOperationTarget -Operation $operation -RootMap $RootMap)
                $key = ([string]$operation.TargetRoot).ToLowerInvariant() + '|' + ([string]$operation.RelativePath).Replace('\', '/').ToLowerInvariant()
                if ($keys.ContainsKey($key)) { throw "Duplicate operation target: $key" }
                $keys[$key] = $true
                if ([string]$operation.Kind -eq 'Put') {
                    if ([string]$operation.SourceKind -notin @('StagedFile', 'VaultFile')) { throw "Unsupported Put source: $($operation.SourceKind)" }
                    if ([string]$operation.SourceKind -eq 'StagedFile') {
                        $stagedPath = [IO.Path]::GetFullPath([string]$operation.SourcePath)
                        if (-not $stagedPath.StartsWith($planRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            throw "Staged source is outside PlanRoot: $stagedPath"
                        }
                        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) { throw "Missing staged source: $stagedPath" }
                    } else {
                        if (-not (Test-AgentSessionSafeRelativePath ([string]$operation.SourceRelativePath))) { throw "Unsafe Vault source: $($operation.SourceRelativePath)" }
                        if (-not [string]::Equals([string]$operation.SourceCommit, $ExpectedVaultCommit, [StringComparison]::OrdinalIgnoreCase)) {
                            throw "VaultFile source commit mismatch: $($operation.SourceRelativePath)"
                        }
                    }
                    if ([string]$operation.SourceSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Put operation has an invalid SHA-256.' }
                }
            }
        }
    }
}

function Get-AgentSessionOrderedOperations {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Operations)
    @($Operations | Where-Object Kind -eq 'Put') + @($Operations | Where-Object Kind -eq 'Delete')
}

function Get-AgentSessionRootMap {
    param(
        [Parameter(Mandatory)][array]$Plans,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $checkpointRoot = Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State'
    $map = @{ Vault = [IO.Path]::GetFullPath($RepoRoot); CheckpointRoot = [IO.Path]::GetFullPath($checkpointRoot) }
    foreach ($plan in $Plans) {
        if (-not ($plan.PSObject.Properties.Name -contains 'RootBindings') -or -not $plan.RootBindings) { continue }
        foreach ($name in $plan.RootBindings.Keys) {
            $binding = [string]$plan.RootBindings[$name]
            if (-not [IO.Path]::IsPathRooted($binding)) { throw "RootBinding must be absolute: $name" }
            $path = [IO.Path]::GetFullPath($binding).TrimEnd('\', '/')
            if ($map.ContainsKey([string]$name) -and -not [string]::Equals([string]$map[[string]$name], $path, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Conflicting RootBinding: $name"
            }
            $map[[string]$name] = $path
        }
    }
    $map
}

function Start-AgentSessionFileTransaction {
    param([Parameter(Mandatory)][hashtable]$RootMap, [string]$TransactionRoot = '')
    if (-not $TransactionRoot) { $TransactionRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-Txn' }
    $backup = Join-Path $TransactionRoot 'backup'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    [pscustomobject]@{
        RootMap = $RootMap
        TransactionRoot = [IO.Path]::GetFullPath($TransactionRoot)
        BackupRoot = [IO.Path]::GetFullPath($backup)
        Records = New-Object 'Collections.Generic.List[object]'
        AppliedKeys = @{}
        Completed = $false
    }
}

function Assert-AgentSessionVaultFileSource {
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$RequireCleanTree
    )
    $head = ([string](& git -C $RepoRoot rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($head, [string]$Operation.SourceCommit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Vault HEAD changed before apply: $($Operation.SourceRelativePath)"
    }
    if ($RequireCleanTree) {
        $dirty = @(& git -C $RepoRoot status --porcelain)
        if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Vault working tree is not clean while applying a VaultFile source.' }
    }
    $source = [IO.Path]::GetFullPath((Join-Path $RepoRoot ([string]$Operation.SourceRelativePath -replace '/', '\')))
    $repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if (-not $source.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Invalid VaultFile source: $($Operation.SourceRelativePath)"
    }
    $source
}

function Assert-AgentSessionVaultSources {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Operations,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $vaultFileOperations = @($Operations | Where-Object { $_.Kind -eq 'Put' -and $_.SourceKind -eq 'VaultFile' })
    if ($vaultFileOperations.Count -eq 0) { return }

    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Vault working tree is not clean before applying VaultFile sources.' }
    foreach ($operation in $vaultFileOperations) {
        $source = Assert-AgentSessionVaultFileSource -Operation $operation -RepoRoot $RepoRoot
        $actualHash = Get-AgentSessionFileSha256 $source
        if (-not [string]::Equals($actualHash, [string]$operation.SourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "VaultFile source changed after planning: $source"
        }
    }
}

function Add-AgentSessionOperations {
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Operations,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    foreach ($operation in $Operations) {
        $target = Resolve-AgentSessionOperationTarget -Operation $operation -RootMap $Transaction.RootMap
        $key = ([string]$operation.TargetRoot).ToLowerInvariant() + '|' + ([string]$operation.RelativePath).Replace('\', '/').ToLowerInvariant()
        if ($Transaction.AppliedKeys.ContainsKey($key)) { throw "Operation target already applied: $key" }

        $recordIndex = $Transaction.Records.Count
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        $backupPath = Join-Path $Transaction.BackupRoot ($recordIndex.ToString('D6') + '.bak')
        if ($existed) {
            [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath ([IO.Path]::GetDirectoryName($backupPath))))
            [IO.File]::Copy((ConvertTo-ExtendedPath $target), (ConvertTo-ExtendedPath $backupPath), $true)
        }
        [void]$Transaction.Records.Add([pscustomobject]@{ Target = $target; Existed = $existed; Backup = $backupPath })
        $Transaction.AppliedKeys[$key] = $true

        if ([string]$operation.Kind -eq 'Delete') {
            if ($existed) { [IO.File]::Delete((ConvertTo-ExtendedPath $target)) }
            continue
        }

        $source = if ([string]$operation.SourceKind -eq 'VaultFile') {
            Assert-AgentSessionVaultFileSource -Operation $operation -RepoRoot $RepoRoot
        } else { [string]$operation.SourcePath }
        $actualHash = Get-AgentSessionFileSha256 $source
        if (-not [string]::Equals($actualHash, [string]$operation.SourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Put source changed after planning: $source"
        }
        $parent = [IO.Path]::GetDirectoryName($target)
        [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $parent))
        $temporary = Join-Path $parent ('.assync-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy((ConvertTo-ExtendedPath $source), (ConvertTo-ExtendedPath $temporary), $true)
            if (-not [string]::Equals((Get-AgentSessionFileSha256 $temporary), [string]$operation.SourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Put target snapshot verification failed: $target"
            }
            if (Test-Path -LiteralPath $target) { [IO.File]::Delete((ConvertTo-ExtendedPath $target)) }
            [IO.File]::Move((ConvertTo-ExtendedPath $temporary), (ConvertTo-ExtendedPath $target))
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function Undo-AgentSessionFileTransaction {
    param([Parameter(Mandatory)]$Transaction)
    for ($index = $Transaction.Records.Count - 1; $index -ge 0; $index--) {
        $record = $Transaction.Records[$index]
        if ($record.Existed) {
            $parent = [IO.Path]::GetDirectoryName([string]$record.Target)
            [void][IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $parent))
            [IO.File]::Copy((ConvertTo-ExtendedPath ([string]$record.Backup)), (ConvertTo-ExtendedPath ([string]$record.Target)), $true)
        } elseif (Test-Path -LiteralPath ([string]$record.Target) -PathType Leaf) {
            [IO.File]::Delete((ConvertTo-ExtendedPath ([string]$record.Target)))
        }
    }
    $Transaction.Completed = $true
}

function Complete-AgentSessionFileTransaction {
    param([Parameter(Mandatory)]$Transaction)
    $Transaction.Completed = $true
}

function Get-AgentSessionVaultHead {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $head = ([string](& git -C $RepoRoot rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Vault HEAD를 읽을 수 없습니다.' }
    $head
}

function Test-AgentSessionCheckpointCurrent {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Checkpoint,
        [string]$AgentName = 'Agent'
    )
    $head = Get-AgentSessionVaultHead $RepoRoot
    if (-not $Checkpoint.Exists) {
        Write-Warning "$AgentName checkpoint가 없습니다. checkpoint 기반 삭제 추론 없이 Finish를 계속합니다."
        return $false
    }
    if ([string]::Equals([string]$Checkpoint.Commit, $head, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    Write-Warning "$AgentName checkpoint가 현재 Vault HEAD와 다릅니다. checkpoint 기반 삭제 추론 없이 Finish를 계속합니다."
    return $false
}

function Prepare-AgentSessionVaultMutation {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Vault working tree 상태를 확인할 수 없습니다.' }
    if ($dirty) { throw 'Vault working tree에 미커밋 변경이 있습니다.' }
    $hadPendingCommit = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & git -C $RepoRoot fetch --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Vault 원격 상태를 확인할 수 없습니다.' }
        $head = Get-AgentSessionVaultHead $RepoRoot
        $upstream = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Vault upstream을 확인할 수 없습니다.' }
        if ([string]::Equals($head, $upstream, [StringComparison]::OrdinalIgnoreCase)) { return $hadPendingCommit }

        & git -C $RepoRoot merge-base --is-ancestor $head $upstream
        if ($LASTEXITCODE -eq 0) {
            Write-Warning '원격 Vault가 앞서 있어 fast-forward로 합류합니다.'
            & git -C $RepoRoot merge --ff-only $upstream | Out-Null
            if ($LASTEXITCODE -ne 0) { throw '원격 Vault fast-forward에 실패했습니다.' }
            continue
        }

        & git -C $RepoRoot merge-base --is-ancestor $upstream $head
        if ($LASTEXITCODE -ne 0) {
            $base = ([string](& git -C $RepoRoot merge-base $head $upstream)).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $base) { throw '로컬과 원격 Vault의 공통 기준을 찾을 수 없습니다.' }
            $localPaths = @(& git -C $RepoRoot -c core.quotepath=false diff --name-only "$base..$head")
            $remotePaths = @(& git -C $RepoRoot -c core.quotepath=false diff --name-only "$base..$upstream")
            $remoteSet = @{}; foreach ($path in $remotePaths) { if ($path) { $remoteSet[$path] = $true } }
            $overlaps = @($localPaths | Where-Object { $_ -and $remoteSet.ContainsKey($_) } | Sort-Object -Unique)
            Write-Warning "로컬과 원격 Vault가 분기돼 merge로 합류합니다 (시도 $attempt/3)."
            foreach ($path in $overlaps) { Write-Warning "  겹친 경로는 현재 호스트 사본 우선: $path" }
            & git -C $RepoRoot merge --no-edit -X ours $upstream | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Vault 자동 merge에 실패했습니다. git status로 충돌을 확인하세요.' }
            $hadPendingCommit = $true
            $head = Get-AgentSessionVaultHead $RepoRoot
        } else {
            $hadPendingCommit = $true
        }

        & git -C $RepoRoot push
        if ($LASTEXITCODE -eq 0) {
            & git -C $RepoRoot fetch --quiet
            $verified = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
            if ([string]::Equals((Get-AgentSessionVaultHead $RepoRoot), $verified, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        Write-Warning "Vault push가 거부되어 원격을 다시 확인합니다 (시도 $attempt/3)."
    }
    throw 'Vault push가 3회 연속 거부됐습니다. 네트워크와 원격 상태를 확인하세요.'
}

function Test-AgentSessionGzipIntegrity {
    <#
      Vault 의 gzip 운반물이 자기 integrity metadata 와 맞는지 확인한다.
      Start 는 이걸 풀어 로컬에 복원하고 Finish 는 재사용 여부를 판단하므로
      양쪽 사전검사가 같은 검사를 쓴다.

      metadata 가 없는 legacy gzip 은 실패로 보지 않는다. 경고하고 CRC·JSONL 로만
      확인한 뒤 통과시키며, metadata 는 다음 Finish 가 만든다.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $planRoot = New-AgentSessionPlanRoot -Prefix 'AgentSessionSync-Gzip'
    try {
        foreach ($gzip in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'Codex') -Recurse -File -Filter '*.jsonl.gz' -ErrorAction SilentlyContinue)) {
            $integrityPath = Get-CompressedJsonlIntegrityPath $gzip.FullName
            if (Test-Path -LiteralPath $integrityPath -PathType Leaf) {
                $integrity = Read-CompressedJsonlIntegrity $integrityPath
                if ($gzip.Length -ne $integrity.GzipLength -or
                    -not [string]::Equals((Get-AgentSessionFileSha256 $gzip.FullName), $integrity.GzipSha256, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "gzip 운반물 SHA-256 또는 길이가 metadata와 다릅니다: $($gzip.FullName)"
                }
                continue
            }
            Write-Warning "legacy gzip에 integrity metadata가 없습니다. CRC/JSONL 검증 후 계속하며 다음 Finish에서 metadata를 생성합니다: $($gzip.FullName)"
            $expanded = Join-Path $planRoot ($gzip.BaseName + '-' + [guid]::NewGuid().ToString('N'))
            [void](Expand-JsonlTransportFile -Source $gzip.FullName -Destination $expanded)
        }
    } finally {
        if (Test-Path -LiteralPath $planRoot) { Remove-Item -LiteralPath $planRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AgentSessionVaultReadable {
    <#
      Vault 를 읽을 수 있는 상태인지만 본다.

      Prepare-AgentSessionVaultMutation 을 쓰지 않는다. 그 함수는 fetch·merge 를 하고
      미게시 커밋을 push 까지 하므로 사전검사가 부르면 "아무것도 바꾸지 않는다" 가
      거짓이 된다. 그 준비는 실제 적용 단계(Pull-Sessions / Push-Sessions)가 한다.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    Assert-GitRepository $RepoRoot
    $dirty = @(& git -C $RepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Vault working tree 상태를 확인할 수 없습니다.' }
    if ($dirty) { throw 'Vault working tree에 미커밋 변경이 있습니다. 먼저 정리하세요.' }
}

function Test-AgentSessionPlanPreflight {
    <#
      앱별 계획을 실제로 만들어 검증한다. 이게 사전검사의 핵심이다.

      Git 상태와 gzip 만 봐서는 계획 단계 오류를 못 잡는다. 고아 원문, 계보 단절,
      동일 target 중복 같은 것은 계획을 만들어야 드러나고, 그걸 앱을 다 죽인 뒤에
      발견하면 이 계약을 만든 사고가 그대로 재현된다.

      계획 생성은 어댑터 계약상 저장소를 바꾸지 않으므로 사전검사에서 불러도 된다.

      현재 HEAD 기준으로만 검증한다. pull 은 하지 않는다. 실제 Start 는 pull·claim
      이후 계획을 다시 만들므로, 여기서 통과했다고 그 계획까지 보장하지는 않는다.
      여기서 잡는 것은 지금 이 머신과 이 Vault 의 구조적 오류다.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('Start', 'Finish')][string]$Phase
    )
    foreach ($required in @("New-Codex${Phase}Plan", "New-Claude${Phase}Plan")) {
        if (-not (Get-Command $required -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Session adapter contract is incomplete: $required"
        }
    }
    $head = Get-AgentSessionVaultHead $RepoRoot
    $context = [pscustomobject]@{
        SchemaVersion = 1
        RepoRoot = $RepoRoot
        Config = $Config
        VaultCommit = $head
        NowUtc = [DateTime]::UtcNow
        AllowCheckpointAncestor = $true
    }
    $planRoot = New-AgentSessionPlanRoot -Prefix "AgentSessionSync-${Phase}Preflight"
    try {
        $claudeRoot = Join-Path $planRoot 'Claude'
        $codexRoot = Join-Path $planRoot 'Codex'
        New-Item -ItemType Directory -Path $claudeRoot, $codexRoot -Force | Out-Null
        $claudePlan = & "New-Claude${Phase}Plan" -Context $context -PlanRoot $claudeRoot
        $codexPlan = & "New-Codex${Phase}Plan" -Context $context -PlanRoot $codexRoot
        $plans = @($claudePlan, $codexPlan)
        $rootMap = Get-AgentSessionRootMap -Plans $plans -RepoRoot $RepoRoot
        $properties = if ($Phase -eq 'Start') { @('LocalOperations') } else { @('VaultOperations', 'LocalOperations') }
        Assert-AgentSessionPlans -Plans $plans -RootMap $rootMap -ExpectedVaultCommit $head `
            -PlanRoot $planRoot -OperationProperties $properties
        foreach ($plan in $plans) {
            foreach ($warning in @($plan.Warnings)) { Write-Warning "[$($plan.Agent) preflight] $warning" }
        }
    } finally {
        if (Test-Path -LiteralPath $planRoot) { Remove-Item -LiteralPath $planRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AgentSessionStartPreflight {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Config)
    Test-AgentSessionVaultReadable -RepoRoot $RepoRoot
    Test-AgentSessionGzipIntegrity -RepoRoot $RepoRoot
    Test-AgentSessionPlanPreflight -RepoRoot $RepoRoot -Config $Config -Phase 'Start'
}

function Test-AgentSessionFinishPreflight {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Config)
    Test-AgentSessionVaultReadable -RepoRoot $RepoRoot
    Test-AgentSessionGzipIntegrity -RepoRoot $RepoRoot
    Test-AgentSessionPlanPreflight -RepoRoot $RepoRoot -Config $Config -Phase 'Finish'
}

function Commit-AgentSessionVault {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Message)
    & git -C $RepoRoot add -A
    if ($LASTEXITCODE -ne 0) { throw 'Vault git add에 실패했습니다.' }
    & git -C $RepoRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        & git -C $RepoRoot commit -q -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'Vault commit에 실패했습니다.' }
    }
    Get-AgentSessionVaultHead $RepoRoot
}

function Push-AgentSessionVault {
    param([Parameter(Mandatory)][string]$RepoRoot)
    & git -C $RepoRoot push
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Vault push가 거부되어 원격과 merge로 합류한 뒤 재시도합니다.'
        [void](Prepare-AgentSessionVaultMutation -RepoRoot $RepoRoot)
    }
    & git -C $RepoRoot fetch --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Push 후 원격 확인 fetch에 실패했습니다.' }
    $head = Get-AgentSessionVaultHead $RepoRoot
    $upstream = ([string](& git -C $RepoRoot rev-parse '@{upstream}')).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($head, $upstream, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Push 후 HEAD와 원격 branch가 일치하지 않습니다.'
    }
    $head
}

function Publish-AgentSessionVault {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Message)
    [void](Commit-AgentSessionVault -RepoRoot $RepoRoot -Message $Message)
    Push-AgentSessionVault -RepoRoot $RepoRoot
}
