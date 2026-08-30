Set-StrictMode -Version Latest

<#
  Claude 세션 상태 어댑터. 계획만 만들고 아무것도 직접 쓰지 않는다.

  Codex 와 판정 축이 다르다. Codex 는 대화를 지우면 rollout 파일이 함께 사라져
  "파일이 없다 = 지웠다" 가 성립하지만 Claude 는 그렇지 않다. 실측 결과다.

      삭제 마커 134건 중 추적 가능 93건 → 원문이 로컬에 그대로 남은 것 87건
      나머지 6건도 앱이 지운 게 아니라 도구가 archive 로 내린 것
      앱이 원문을 지운 사례 0건

  그래서 Claude 의 삭제 신호는 원문의 부재가 아니라 deleted_<appSessionId> 마커뿐이다.
  마커는 앱 세션 ID 이고, 그것을 원문 ID 로 바꿔 줄 local_<appSessionId>.json 은 삭제와
  동시에 사라진다. 원문 안에도 앱 세션 ID 는 없다.

      살아 있는 목록 항목만으로 마커를 푸는 비율: 0 / 166

  따라서 변환표를 항목이 살아 있는 시점에 checkpoint 로 붙잡아 둔다.

  또 앱은 목록 항목이 없는 원문을 스스로 주워가지 않는다(고아 원문 180건). 원문만 보관하면
  복원해도 사이드바에 뜨지 않고, 항목을 새로 만들려면 앱 내부 필드를 위조해야 한다.
  그래서 보관 단위는 원문과 목록 항목의 쌍이다.
#>

$script:ClaudeVaultActive = 'Claude/sessions'
$script:ClaudeVaultArchive = 'Claude/archive'
$script:ClaudeEntrySuffix = '.entry.json'

function Get-ClaudeSessionCanonicalId {
    <#
      원문 안에 적힌 sessionId 만 정체성이다. 파일명은 근거가 아니라 대조 대상이다.
      첫 하나만 읽고 끝내면 뒤쪽에 다른 ID 가 섞인 파일을 통과시킨다. 전체를 훑어
      서로 다른 ID 가 나오면 신뢰할 수 없는 원문이므로 중단한다.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $found = @{}
    $stream = $null; $reader = $null
    try {
        $stream = [IO.FileStream]::new((ConvertTo-ExtendedPath $Path), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.IndexOf('"sessionId"', [StringComparison]::Ordinal) -lt 0) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if (-not ($record.PSObject.Properties.Name -contains 'sessionId')) { continue }
            $id = [string]$record.sessionId
            if ($id) { $found[$id] = $true }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    if ($found.Count -eq 0) { throw "Claude 원문에서 sessionId 를 읽을 수 없습니다: $Path" }
    if ($found.Count -gt 1) {
        throw ("Claude 원문에 서로 다른 sessionId 가 섞여 있습니다: $Path (" + (($found.Keys | Sort-Object) -join ', ') + ')')
    }
    return @($found.Keys)[0]
}

function Assert-ClaudeTranscriptIdentity {
    <# 파일명과 원문 내부 ID 가 같아야 한다. 다르면 어느 쪽도 믿을 수 없다. #>
    param([Parameter(Mandatory)][string]$Path)
    $id = Get-ClaudeSessionCanonicalId $Path
    $stem = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path))
    if (-not [string]::Equals($id, $stem, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Claude 원문의 sessionId 와 파일명이 다릅니다: $Path (sessionId=$id)"
    }
    return $id
}

function Get-ClaudeTranscriptSet {
    <# projects 트리의 *.jsonl 을 canonical ID 로 모은다. Key 는 프로젝트 폴더 이름이다. #>
    param([Parameter(Mandatory)][string]$Root)
    $found = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $found }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
        $id = Assert-ClaudeTranscriptIdentity $file.FullName
        if ($found.ContainsKey($id)) { throw "Claude canonical ID 가 두 파일에 있습니다: $id" }
        $found[$id] = [pscustomobject]@{
            Id = $id
            Key = Split-Path -Leaf (Split-Path -Parent $file.FullName)
            Path = $file.FullName
        }
    }
    return $found
}

function Get-ClaudeDirectoryIdentity {
    <#
      볼륨 일련번호 + 파일 인덱스로 디렉터리 실체를 식별한다. FILE_READ_ATTRIBUTES 로만 열어
      아무것도 쓰지 않는다. 계획 생성 중에는 앱 저장소에 한 바이트도 쓰면 안 되므로 탐침
      파일을 만들지 않는다.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('ClaudeSessionFsIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeSessionFsIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out ByHandleFileInformation info);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    public static string Get(string path) {
        IntPtr handle = CreateFileW(path, 0x80u, 0x7u, IntPtr.Zero, 3u, 0x02000000u, IntPtr.Zero);
        if (handle == new IntPtr(-1)) { return null; }
        try {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) { return null; }
            return info.VolumeSerialNumber.ToString("x8") + ":" +
                   info.FileIndexHigh.ToString("x8") + info.FileIndexLow.ToString("x8");
        } finally { CloseHandle(handle); }
    }
}
'@
    }
    [ClaudeSessionFsIdentity]::Get($Path)
}

function Get-ClaudeAppRegistryRoot {
    <#
      앱 목록 저장 경로는 설치 방식마다 다르다. 이 머신에서 실측하면 일반 설치 경로와 MSIX
      LocalCache 경로가 같은 실체다. 문자열로 세면 같은 폴더를 둘로 세고 임의로 한쪽을 버린다.
      동일성은 파일 시스템 identity 로만 증명한다. 증명하지 못하면 판정하지 않고 중단한다.
    #>
    param([switch]$AllowMissing)
    $candidates = @(@(
        (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($candidates.Count -eq 0) {
        if ($AllowMissing) { return '' }
        throw 'Claude 앱 목록 저장소를 찾지 못했습니다.'
    }
    $primary = [IO.Path]::GetFullPath($candidates[0]).TrimEnd('\', '/')
    if ($candidates.Count -eq 1) { return $primary }

    $primaryIdentity = Get-ClaudeDirectoryIdentity $primary
    if (-not $primaryIdentity) { throw "Claude 앱 저장소의 파일 시스템 identity 를 읽지 못했습니다: $primary" }
    foreach ($other in $candidates[1..($candidates.Count - 1)]) {
        $otherFull = [IO.Path]::GetFullPath($other).TrimEnd('\', '/')
        $otherIdentity = Get-ClaudeDirectoryIdentity $otherFull
        if (-not $otherIdentity) { throw "Claude 앱 저장소의 파일 시스템 identity 를 읽지 못했습니다: $otherFull" }
        if (-not [string]::Equals($primaryIdentity, $otherIdentity, [StringComparison]::OrdinalIgnoreCase)) {
            throw "서로 다른 Claude 앱 저장소가 둘 이상입니다. 설치 방식을 하나로 통일하세요: $primary / $otherFull"
        }
    }
    return $primary
}

function Get-ClaudeNativeEntries {
    param([string]$RegistryRoot)
    $entries = @{}
    if (-not $RegistryRoot -or -not (Test-Path -LiteralPath $RegistryRoot)) { return $entries }
    $rootFull = [IO.Path]::GetFullPath($RegistryRoot).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $RegistryRoot -File -Recurse -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
        $appSessionId = ($file.BaseName -replace '^local_', '')
        try { $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "Claude 목록 항목을 읽을 수 없습니다: $($file.FullName)" }
        $canonical = ''
        if ($content.PSObject.Properties.Name -contains 'cliSessionId') { $canonical = [string]$content.cliSessionId }
        # 같은 appSessionId 가 두 경로에 있으면 어느 것이 현재 항목인지 판단할 근거가 없다.
        # 조용히 마지막 것으로 덮으면 살아 있는 항목을 두고 다른 자리를 갱신하게 된다.
        if ($entries.ContainsKey($appSessionId)) {
            throw ("Claude 목록 항목이 두 경로에 있습니다: appSessionId=$appSessionId`n" +
                "  $($entries[$appSessionId].Path)`n  $($file.FullName)`n" +
                '어느 것이 현재 항목인지 정한 뒤 다시 실행하세요.')
        }
        $entries[$appSessionId] = [pscustomobject]@{
            AppSessionId = $appSessionId
            CanonicalId = $canonical
            Path = $file.FullName
            RelativePath = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        }
    }
    return $entries
}

function Get-ClaudeEntriesByCanonicalId {
    <#
      원문 하나에 목록 항목이 둘 이상 붙어 있으면 어느 것이 진짜인지 판단할 근거가 없다.
      마지막 것으로 조용히 덮으면 잘못된 항목을 Vault 에 보관하게 되므로 중단한다.
    #>
    param([Parameter(Mandatory)][hashtable]$Entries)
    $byCanonical = @{}
    foreach ($entry in $Entries.Values) {
        if (-not $entry.CanonicalId) { continue }
        if ($byCanonical.ContainsKey($entry.CanonicalId)) {
            throw ("한 Claude 원문에 목록 항목이 둘 이상 있습니다: $($entry.CanonicalId) " +
                   "($($byCanonical[$entry.CanonicalId].AppSessionId), $($entry.AppSessionId))")
        }
        $byCanonical[$entry.CanonicalId] = $entry
    }
    return $byCanonical
}

function Get-ClaudeEntryMap {
    param([string]$RegistryRoot)
    $map = @{}
    foreach ($entry in (Get-ClaudeNativeEntries $RegistryRoot).Values) {
        if ($entry.CanonicalId) { $map[$entry.AppSessionId] = $entry.CanonicalId }
    }
    return $map
}

function Get-ClaudeMarkerIds {
    <# 앱이 대화를 지우면 deleted_<appSessionId> 를 남긴다. Claude 의 유일한 삭제 신호다. #>
    param([string]$RegistryRoot)
    $markers = @{}
    if (-not $RegistryRoot -or -not (Test-Path -LiteralPath $RegistryRoot)) { return $markers }
    $rootFull = [IO.Path]::GetFullPath($RegistryRoot).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $RegistryRoot -File -Recurse -Filter 'deleted_*' -ErrorAction SilentlyContinue)) {
        $markers[($file.Name -replace '^deleted_', '')] =
            $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return $markers
}

function Get-ClaudeVaultGroups {
    <# Vault 한 계층을 canonical ID 로 모은다. 원문과 항목 사본은 한 쌍이다. #>
    param([Parameter(Mandatory)][string]$Root)
    $groups = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $groups }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
        # Vault 원문도 파일명만 믿지 않는다. 내부 sessionId 와 대조한다.
        $id = Assert-ClaudeTranscriptIdentity $file.FullName
        if ($groups.ContainsKey($id)) { throw "Claude Vault 에 같은 canonical ID 가 둘 있습니다: $id" }
        $entryPath = Join-Path (Split-Path -Parent $file.FullName) ($id + $script:ClaudeEntrySuffix)
        # 보관 단위는 원문과 목록 항목의 쌍이다. 원문만 있으면 복원해도 사이드바에 못 뜬다.
        if (-not (Test-Path -LiteralPath $entryPath)) {
            throw "Claude Vault 원문에 짝이 되는 항목 사본이 없습니다: $($file.FullName)"
        }
        [void](Read-ClaudeSidecar -Path $entryPath -CanonicalId $id)
        $groups[$id] = [pscustomobject]@{
            Id = $id
            Key = Split-Path -Leaf (Split-Path -Parent $file.FullName)
            Transcript = $file.FullName
            EntryPath = $entryPath
        }
    }
    foreach ($sidecar in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Filter ('*' + $script:ClaudeEntrySuffix) -ErrorAction SilentlyContinue)) {
        $id = $sidecar.Name.Substring(0, $sidecar.Name.Length - $script:ClaudeEntrySuffix.Length)
        if (-not $groups.ContainsKey($id)) { throw "원문 없는 Claude 항목 사본이 있습니다: $($sidecar.FullName)" }
    }
    return $groups
}

function Get-ClaudeTierInventory {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $active = Get-ClaudeVaultGroups (Join-Path $RepoRoot ($script:ClaudeVaultActive -replace '/', '\'))
    $archived = Get-ClaudeVaultGroups (Join-Path $RepoRoot ($script:ClaudeVaultArchive -replace '/', '\'))
    foreach ($id in $active.Keys) {
        if ($archived.ContainsKey($id)) { throw "Claude 세션이 Active 와 Archived 에 동시에 있습니다: $id" }
    }
    [pscustomobject]@{ Active = $active; Archived = $archived }
}

function Get-ClaudeCheckpointPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($RepoRoot)).ToLowerInvariant()))
        $key = -join @($bytes | ForEach-Object { $_.ToString('x2') })
    } finally { $algorithm.Dispose() }
    Join-Path (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State') ($key + '.claude.json')
}

function Read-ClaudeCheckpoint {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-ClaudeCheckpointPath $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Exists = $false; Commit = ''; ActiveIds = @(); EntryMap = @{} }
    }
    try {
        $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$value.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$value.commit)) {
            throw '지원하지 않는 checkpoint 형식입니다.'
        }
        $map = @{}
        if (($value.PSObject.Properties.Name -contains 'entryMap') -and $value.entryMap) {
            foreach ($property in $value.entryMap.PSObject.Properties) { $map[$property.Name] = [string]$property.Value }
        }
        [pscustomobject]@{
            Exists = $true
            Commit = [string]$value.commit
            ActiveIds = @($value.claudeActiveIds | ForEach-Object { [string]$_ })
            EntryMap = $map
        }
    } catch { throw "Claude checkpoint 를 읽을 수 없습니다: $path ($($_.Exception.Message))" }
}

function Resolve-ClaudeDeletedIds {
    <#
      마커는 앱 세션 ID 다. 살아 있는 항목으로는 거의 풀리지 않으므로 checkpoint 변환표를 먼저
      본다. 그래도 못 푸는 마커는 Start 이후에 만들어 같은 사이클에 지운 대화이고, 목록 항목이
      이미 사라져 다음 Start 를 기다려도 복구되지 않는다. 그대로 진행하면 사용자가 지운 대화를
      신규로 올려 R3 을 깨므로 판정하지 않고 중단한다.
    #>
    param([string]$RegistryRoot, [Parameter(Mandatory)]$Checkpoint)
    $resolved = @{}
    $consumed = @{}
    $unresolved = @()
    $markers = Get-ClaudeMarkerIds $RegistryRoot
    $live = Get-ClaudeEntryMap $RegistryRoot
    foreach ($appSessionId in $markers.Keys) {
        $canonical = ''
        if ($Checkpoint.EntryMap.ContainsKey($appSessionId)) { $canonical = [string]$Checkpoint.EntryMap[$appSessionId] }
        elseif ($live.ContainsKey($appSessionId)) { $canonical = [string]$live[$appSessionId] }
        if ($canonical) { $resolved[$canonical] = $true; $consumed[$appSessionId] = $markers[$appSessionId] }
        else { $unresolved += $appSessionId }
    }
    if ($unresolved.Count -gt 0) {
        throw ("Claude 삭제 마커를 canonical ID 로 풀 수 없습니다: " + (($unresolved | Sort-Object) -join ', ') + "`n" +
               '해당 대화의 목록 항목이 이미 사라져 자동 판정이 불가능합니다. ' +
               '지울 원문을 직접 확인해 정리하거나, 보관하기로 했다면 마커 파일을 지운 뒤 다시 실행하세요.')
    }
    [pscustomobject]@{ Ids = @($resolved.Keys); ConsumedMarkers = $consumed }
}

function Read-ClaudeSidecar {
    <#
      항목 사본은 Vault 에서 온 데이터다. 스키마·경로·정체성을 모두 검증한 뒤에만 쓴다.
      검증 없이 relativePath 를 결합하면 손상되거나 조작된 사이드카가 registry 밖을 가리킨다.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CanonicalId)
    try { $sidecar = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Claude 항목 사본을 읽을 수 없습니다: $Path" }

    if (-not ($sidecar.PSObject.Properties.Name -contains 'schemaVersion') -or [int]$sidecar.schemaVersion -ne 1) {
        throw "지원하지 않는 Claude 항목 사본 형식입니다: $Path"
    }
    $appSessionId = $(if ($sidecar.PSObject.Properties.Name -contains 'appSessionId') { [string]$sidecar.appSessionId } else { '' })
    $relative = $(if ($sidecar.PSObject.Properties.Name -contains 'relativePath') { ([string]$sidecar.relativePath).Replace('\', '/') } else { '' })
    if (-not $appSessionId -or -not $relative) { throw "Claude 항목 사본에 appSessionId 또는 relativePath 가 없습니다: $Path" }
    if (-not (Test-AgentSessionSafeRelativePath $relative)) { throw "Claude 항목 사본의 relativePath 가 안전하지 않습니다: $relative" }
    if (-not [string]::Equals((Split-Path -Leaf $relative), "local_$appSessionId.json", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Claude 항목 사본의 파일명이 appSessionId 와 맞지 않습니다: $relative"
    }
    if (-not ($sidecar.PSObject.Properties.Name -contains 'entry') -or $null -eq $sidecar.entry) {
        throw "Claude 항목 사본에 entry 가 없습니다: $Path"
    }
    $bound = $(if ($sidecar.entry.PSObject.Properties.Name -contains 'cliSessionId') { [string]$sidecar.entry.cliSessionId } else { '' })
    if (-not [string]::Equals($bound, $CanonicalId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Claude 항목 사본이 다른 원문을 가리킵니다: sidecar=$bound transcript=$CanonicalId"
    }
    [pscustomobject]@{ AppSessionId = $appSessionId; RelativePath = $relative; Entry = $sidecar.entry }
}

function New-ClaudePlanObject {
    param([string]$Phase, $Context, [array]$VaultOperations, [array]$LocalOperations, $Result, [string[]]$Warnings = @())
    $bindings = @{ ClaudeHome = [IO.Path]::GetFullPath([string]$Context.Config.ClaudeHome) }
    $registryRoot = Get-ClaudeAppRegistryRoot -AllowMissing
    if ($registryRoot) { $bindings['ClaudeRegistry'] = $registryRoot }
    [pscustomobject]@{
        SchemaVersion = 1
        Agent = 'Claude'
        Phase = $Phase
        ExpectedVaultCommit = [string]$Context.VaultCommit
        RootBindings = $bindings
        VaultOperations = @($VaultOperations)
        LocalOperations = @($LocalOperations)
        Result = $Result
        Warnings = @($Warnings)
    }
}

function New-ClaudeEntryArtifact {
    <#
      사이드카에서 앱이 읽을 원본 항목 JSON 을 풀어 PlanRoot 에 만든다.

      이 산출물만은 BOM 없이 써야 한다. 읽는 쪽이 우리가 아니라 Claude 앱의
      LocalSessionManager.loadSessions() 이고, 그것은 readFile(utf-8) 결과를 곧바로
      JSON.parse 에 넘긴다. BOM 이 있으면 parse 가 던지고, 앱은 그 예외를 warn 으로
      삼킨 뒤 항목을 통째로 버린다. 파일은 멀쩡히 있는데 사이드바에만 안 보인다.
    #>
    param([Parameter(Mandatory)][string]$SidecarPath, [Parameter(Mandatory)][string]$CanonicalId, [Parameter(Mandatory)][string]$PlanRoot)
    $sidecar = Read-ClaudeSidecar -Path $SidecarPath -CanonicalId $CanonicalId
    $path = Join-Path $PlanRoot ('claude-entry-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-AgentSessionUtf8File -Path $path -Content ($sidecar.Entry | ConvertTo-Json -Depth 40) -NoBom
    [pscustomobject]@{ RelativePath = $sidecar.RelativePath; Path = $path; Sha256 = Get-AgentSessionFileSha256 $path }
}

function New-ClaudeSidecarArtifact {
    <# 살아 있는 목록 항목을 Vault 보관용 사이드카로 감싼다. #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$CanonicalId, [Parameter(Mandatory)][string]$PlanRoot)
    $payload = Get-Content -LiteralPath $Entry.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $content = [pscustomobject]@{
        schemaVersion = 1
        appSessionId = $Entry.AppSessionId
        relativePath = $Entry.RelativePath
        entry = $payload
    } | ConvertTo-Json -Depth 40
    $path = Join-Path $PlanRoot ('claude-sidecar-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-AgentSessionUtf8File -Path $path -Content $content
    [pscustomobject]@{ Path = $path; Sha256 = Get-AgentSessionFileSha256 $path }
}

function Get-ClaudeVaultCurrentState {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $current = @{}
    foreach ($tier in @($script:ClaudeVaultActive, $script:ClaudeVaultArchive)) {
        $root = Join-Path $RepoRoot ($tier -replace '/', '\')
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*.jsonl' -or $_.Name -like ('*' + $script:ClaudeEntrySuffix) })) {
            $relative = $tier + '/' + $file.FullName.Substring(([IO.Path]::GetFullPath($root).TrimEnd('\', '/')).Length).TrimStart('\', '/').Replace('\', '/')
            $current[$relative] = Get-AgentSessionFileSha256 $file.FullName
        }
    }
    return $current
}

function Get-ClaudeLocalDeleteOperations {
    <# 한 세션의 로컬 원문과 목록 항목을 내리는 작업들. #>
    param([Parameter(Mandatory)][string]$Id, $Transcripts, $EntriesByCanonical)
    $operations = @()
    if ($Transcripts.ContainsKey($Id)) {
        $operations += New-AgentSessionDeleteOperation -TargetRoot ClaudeHome -RelativePath ('projects/' + $Transcripts[$Id].Key + '/' + $Id + '.jsonl')
    }
    if ($EntriesByCanonical.ContainsKey($Id)) {
        $operations += New-AgentSessionDeleteOperation -TargetRoot ClaudeRegistry -RelativePath $EntriesByCanonical[$Id].RelativePath
    }
    return $operations
}

function New-ClaudeStartPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    $projectsRoot = Join-Path $Context.Config.ClaudeHome 'projects'
    $registryRoot = Get-ClaudeAppRegistryRoot -AllowMissing
    $tiers = Get-ClaudeTierInventory $repoRoot
    $checkpoint = Read-ClaudeCheckpoint $repoRoot
    $transcripts = Get-ClaudeTranscriptSet $projectsRoot
    $entries = Get-ClaudeNativeEntries $registryRoot

    if (-not $checkpoint.Exists) {
        # 원문만 보면 부족하다. 목록 항목과 삭제 마커가 남아 있으면 첫 사이클의 판정 근거가
        # 이전 설치의 잔재와 섞인다. 앱 저장소 전체가 비어 있어야 한다.
        $residue = @()
        if ($transcripts.Count -gt 0) { $residue += '원문(projects)' }
        if ($entries.Count -gt 0) { $residue += '목록 항목(local_*.json)' }
        if ((Get-ClaudeMarkerIds $registryRoot).Count -gt 0) { $residue += '삭제 마커(deleted_*)' }
        if ($residue.Count -gt 0) {
            throw ('첫 Start 전에 Claude 앱 저장소를 비워야 합니다. 남아 있는 것: ' + ($residue -join ', '))
        }
    }

    $byCanonical = Get-ClaudeEntriesByCanonicalId $entries

    $operations = New-Object 'Collections.Generic.List[object]'
    $warnings = New-Object 'Collections.Generic.List[string]'
    $unknownToVault = @()
    $archivedMismatch = @()
    # 로컬에서 무엇을 내릴지는 checkpoint 가 아니라 지금 Vault 계층이 정한다.
    # Archived 는 Finish 가 이미 Vault 에 올려둔 뒤 활성 작업 집합에서 내린 것이므로
    # 로컬 사본을 지워도 원문이 남는다. 어느 계층에도 없으면 모르는 것이니 보존한다.
    foreach ($id in @($transcripts.Keys)) {
        if ($tiers.Active.ContainsKey($id)) { continue }
        if (-not $tiers.Archived.ContainsKey($id)) { $unknownToVault += $id; continue }
        # Vault Archived 사본과 바이트가 같을 때만 내린다. 다르면 아직 올라가지 않은
        # 로컬 변경이 있다는 뜻이므로 지우지 않고 보존한다.
        $localPath = Join-Path (Join-Path $projectsRoot $transcripts[$id].Key) ($id + '.jsonl')
        $archivedSha = Get-AgentSessionFileSha256 $tiers.Archived[$id].Transcript
        if (-not [string]::Equals((Get-AgentSessionFileSha256 $localPath), $archivedSha, [StringComparison]::OrdinalIgnoreCase)) {
            $archivedMismatch += $id
            continue
        }
        foreach ($operation in (Get-ClaudeLocalDeleteOperations -Id $id -Transcripts $transcripts -EntriesByCanonical $byCanonical)) {
            [void]$operations.Add($operation)
        }
    }
    # 보존 사실은 결과값만으로는 사용자에게 닿지 않는다. 사유별로 한 줄씩 묶어 낸다.
    # ID 마다 한 줄씩 내면 세션이 많을 때 출력이 그대로 묻힌다.
    $preservedLocal = @(@($unknownToVault) + @($archivedMismatch) | Sort-Object)
    foreach ($group in @(
        @{ Ids = $unknownToVault;   Reason = 'Vault 어느 계층에도 없어 판단하지 않고 보존합니다' },
        @{ Ids = $archivedMismatch; Reason = 'Vault Archived 사본과 원문이 달라 미게시 변경으로 보존합니다' }
    )) {
        $ids = @($group.Ids | Sort-Object)
        if ($ids.Count -eq 0) { continue }
        $shown = @($ids | Select-Object -First 5)
        $suffix = if ($ids.Count -gt $shown.Count) { ' 외 ' + ($ids.Count - $shown.Count) + '건' } else { '' }
        [void]$warnings.Add('Claude 로컬 원문 ' + $ids.Count + '건을 ' + $group.Reason + ': ' + ($shown -join ', ') + $suffix)
    }

    # 앱의 대화 정체성은 appSessionId 다. cliSessionId 는 같은 대화가 이어서 열릴 때마다
    # 새로 발급되므로, Vault 사이드카가 주장하는 원문이 그 항목의 현재 원문이 아닐 수 있다.
    # 그 상태로 항목을 덮어쓰면 살아 있는 대화가 과거 원문으로 되감긴다.
    #
    # 아래 조회표는 계획을 만들기 전에 한 번만 만든다. 사이드카 둘이 같은 항목을 주장하면
    # 뒤에서 묶음을 건너뛰는 순간 duplicate target 검사가 우회되므로 여기서 중단한다.
    # 사이드카 중복은 로컬 registry 가 있든 없든 성립해야 하는 조건이다. 묶음을 건너뛰면
    # 그 target 이 계획에서 빠져 기존 duplicate operation 검사가 우회되므로 여기서 막는다.
    $sidecarByApp = @{}
    $appByCanonical = @{}
    foreach ($id in $tiers.Active.Keys) {
        $sidecar = Read-ClaudeSidecar -Path $tiers.Active[$id].EntryPath -CanonicalId $id
        if ($sidecarByApp.ContainsKey($sidecar.AppSessionId)) {
            throw ("Claude Vault 사이드카 둘이 같은 목록 항목을 주장합니다: appSessionId=$($sidecar.AppSessionId) " +
                "원문=$($sidecarByApp[$sidecar.AppSessionId].CanonicalId), $id`n" +
                '한 대화에 원문이 둘 붙어 있습니다. 어느 쪽이 현재인지 정한 뒤 다시 실행하세요.')
        }
        $sidecarByApp[$sidecar.AppSessionId] = [pscustomobject]@{ CanonicalId = $id; RelativePath = $sidecar.RelativePath }
        $appByCanonical[$id] = $sidecar.AppSessionId
    }

    $rebound = @()
    foreach ($id in $tiers.Active.Keys) {
        $group = $tiers.Active[$id]

        # 로컬 항목은 appSessionId 로 찾는다. 사이드카에 적힌 상대경로는 올릴 당시의 것이고,
        # 앱이 같은 항목을 다른 account/window 하위로 옮기면 그 경로는 더 이상 맞지 않는다.
        # 경로로 찾으면 "로컬에 없음" 으로 오판해 옛 경로에 항목을 하나 더 만든다.
        $localEntry = $null
        if ($registryRoot -and $entries.ContainsKey($appByCanonical[$id])) { $localEntry = $entries[$appByCanonical[$id]] }

        # 같은 항목이 로컬에서 이미 다른 원문으로 옮겨갔으면 이 묶음은 통째로 건너뛴다.
        # 원문만 내려놓고 항목을 두면 반쪽이 되므로 원문 Put 도 내지 않는다.
        # 로컬 항목이 아무 원문에도 묶여 있지 않으면 되감기가 아니라 복구 대상이다.
        if ($localEntry -and $localEntry.CanonicalId -and
            -not [string]::Equals($localEntry.CanonicalId, $id, [StringComparison]::OrdinalIgnoreCase)) {
            $rebound += [pscustomobject]@{
                AppSessionId = $localEntry.AppSessionId; VaultId = $id; LocalId = $localEntry.CanonicalId
            }
            continue
        }

        $targetRelative = 'projects/' + $group.Key + '/' + $id + '.jsonl'
        $vaultSha = Get-AgentSessionFileSha256 $group.Transcript
        $localPath = Join-Path (Join-Path $projectsRoot $group.Key) ($id + '.jsonl')
        $needsPut = $true
        if (Test-Path -LiteralPath $localPath -PathType Leaf) {
            $needsPut = -not [string]::Equals((Get-AgentSessionFileSha256 $localPath), $vaultSha, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($needsPut) {
            [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot ClaudeHome -RelativePath $targetRelative `
                -SourceKind VaultFile -SourceRelativePath ($script:ClaudeVaultActive + '/' + $group.Key + '/' + $id + '.jsonl') `
                -SourceCommit $Context.VaultCommit -SourceSha256 $vaultSha))
        }
        if (-not $registryRoot) { continue }
        $artifact = New-ClaudeEntryArtifact -SidecarPath $group.EntryPath -CanonicalId $id -PlanRoot $PlanRoot
        # 로컬에 같은 항목이 있으면 그 자리를 갱신한다. 사이드카에 적힌 옛 경로에 쓰면
        # 앱이 항목을 옮긴 경우 같은 대화가 두 곳에 생긴다.
        $entryRelative = $(if ($localEntry) { $localEntry.RelativePath } else { $artifact.RelativePath })
        $entryTarget = Join-Path $registryRoot ($entryRelative -replace '/', '\')
        if ((Test-Path -LiteralPath $entryTarget -PathType Leaf) -and
            [string]::Equals((Get-AgentSessionFileSha256 $entryTarget), $artifact.Sha256, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$operations.Add((New-AgentSessionPutOperation -TargetRoot ClaudeRegistry -RelativePath $entryRelative `
            -SourceKind StagedFile -SourcePath $artifact.Path -SourceSha256 $artifact.Sha256))
    }

    foreach ($r in @($rebound | Sort-Object AppSessionId)) {
        [void]$warnings.Add('Claude 대화가 로컬에서 이미 다른 원문으로 옮겨가 Vault 묶음을 건너뜁니다: ' +
            'appSessionId=' + $r.AppSessionId + ' Vault=' + $r.VaultId + ' 로컬=' + $r.LocalId)
    }

    New-ClaudePlanObject -Phase Start -Context $Context -VaultOperations @() -LocalOperations @($operations | ForEach-Object { $_ }) `
        -Warnings @($warnings | ForEach-Object { $_ }) `
        -Result ([pscustomobject]@{ ActiveIds = @($tiers.Active.Keys); DeletedIds = @(); ArchivedIds = @(); RestoredIds = @(); MissingIds = @()
            PreservedLocalIds = @($preservedLocal) })
}

function New-ClaudeFinishPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    $config = $Context.Config
    $projectsRoot = Join-Path $config.ClaudeHome 'projects'
    $registryRoot = Get-ClaudeAppRegistryRoot -AllowMissing
    # checkpoint 는 삭제 마커를 canonical ID 로 옮기는 변환표로만 쓴다. 최신 여부 경고는
    # 사용자 진입점인 Finish 가 두 에이전트 몫을 한 번씩 낸다. 여기서 또 내면 Claude 만
    # 같은 경고를 두 번 출력한다.
    $checkpoint = Read-ClaudeCheckpoint $repoRoot

    $tiers = Get-ClaudeTierInventory $repoRoot
    $transcripts = Get-ClaudeTranscriptSet $projectsRoot
    $entries = Get-ClaudeNativeEntries $registryRoot
    $byCanonical = Get-ClaudeEntriesByCanonicalId $entries

    $deletion = Resolve-ClaudeDeletedIds -RegistryRoot $registryRoot -Checkpoint $checkpoint
    $deletedSet = @{}
    foreach ($id in $deletion.Ids) { $deletedSet[$id] = $true }

    # 최종 Vault 인벤토리를 먼저 만든다. 중간 이동은 작업으로 내지 않는다.
    $desired = @{}
    $tierOf = @{}
    $lastActivity = @{}
    foreach ($pair in @(@{ Groups = $tiers.Active; Tier = 'Active' }, @{ Groups = $tiers.Archived; Tier = 'Archived' })) {
        foreach ($group in $pair.Groups.Values) {
            if ($deletedSet.ContainsKey($group.Id)) { continue }
            $desired[$group.Id] = [pscustomobject]@{
                Id = $group.Id; Key = $group.Key
                TranscriptKind = 'VaultFile'; TranscriptSource = $group.Transcript
                TranscriptRelative = $(if ($pair.Tier -eq 'Active') { $script:ClaudeVaultActive } else { $script:ClaudeVaultArchive }) + '/' + $group.Key + '/' + $group.Id + '.jsonl'
                TranscriptSha = Get-AgentSessionFileSha256 $group.Transcript
                SidecarKind = $(if ($group.EntryPath) { 'VaultFile' } else { '' })
                SidecarSource = $group.EntryPath
                SidecarRelative = $(if ($group.EntryPath) { $(if ($pair.Tier -eq 'Active') { $script:ClaudeVaultActive } else { $script:ClaudeVaultArchive }) + '/' + $group.Key + '/' + $group.Id + $script:ClaudeEntrySuffix } else { '' })
                SidecarSha = $(if ($group.EntryPath) { Get-AgentSessionFileSha256 $group.EntryPath } else { '' })
            }
            $tierOf[$group.Id] = $pair.Tier
        }
    }

    # 로컬에 있는 원문은 현재 내용으로 덮는다. Archived 에 있던 것이 로컬에 나타났다면 복원이다.
    $restored = @()
    foreach ($id in $transcripts.Keys) {
        if ($deletedSet.ContainsKey($id)) { continue }
        $local = $transcripts[$id]
        $snapshot = New-AgentSessionStagedSnapshot -Source $local.Path -PlanRoot $PlanRoot -Name ('claude-' + $id)
        Test-JsonlSnapshotComplete $snapshot.Path
        $lastActivity[$id] = Get-JsonlLastActivity $snapshot.Path
        if ($tierOf.ContainsKey($id) -and $tierOf[$id] -eq 'Archived') { $restored += $id }
        # 보관 단위는 원문과 목록 항목의 쌍이다. 원문만 올리면 반대편 PC 가 사이드바 항목을
        # 복원할 수 없어 R1 이 깨진다. 로컬 항목이 없더라도 이미 보관해 둔 사이드카가 있으면
        # 그것을 유지하고, 둘 다 없으면 판정하지 않고 중단한다.
        if ($byCanonical.ContainsKey($id)) {
            $artifact = New-ClaudeSidecarArtifact -Entry $byCanonical[$id] -CanonicalId $id -PlanRoot $PlanRoot
            $sidecarKind = 'StagedFile'; $sidecarPath = $artifact.Path; $sidecarSha = $artifact.Sha256
        } elseif ($desired.ContainsKey($id) -and $desired[$id].SidecarKind) {
            $sidecarKind = 'VaultFile'; $sidecarPath = $desired[$id].SidecarSource; $sidecarSha = $desired[$id].SidecarSha
        } else {
            throw ("Claude 원문에 짝이 되는 목록 항목이 없습니다: $id`n" +
                   '앱 목록에 이 대화가 있는 상태에서 다시 실행하거나, 전송하지 않을 원문이면 정리하세요.')
        }
        $desired[$id] = [pscustomobject]@{
            Id = $id; Key = $local.Key
            TranscriptKind = 'StagedFile'; TranscriptSource = $snapshot.Path
            TranscriptRelative = $script:ClaudeVaultActive + '/' + $local.Key + '/' + $id + '.jsonl'
            TranscriptSha = $snapshot.Sha256
            SidecarKind = $sidecarKind; SidecarSource = $sidecarPath
            SidecarRelative = $(if ($sidecarKind) { $script:ClaudeVaultActive + '/' + $local.Key + '/' + $id + $script:ClaudeEntrySuffix } else { '' })
            SidecarSha = $sidecarSha
        }
        $tierOf[$id] = 'Active'
    }

    # 마커 없이 사라진 원문은 "모르겠다" 이지 삭제가 아니다. Vault 원문을 그대로 둔다.
    $warnings = @()
    $missing = @($checkpoint.ActiveIds | Where-Object { -not $transcripts.ContainsKey($_) -and -not $deletedSet.ContainsKey($_) })
    foreach ($id in $missing) {
        $warnings += "Claude 원문이 로컬에서 사라졌지만 삭제 마커가 없어 판정을 보류합니다: $id"
    }

    # 노화 판정은 삭제·신규·복원이 모두 반영된 뒤에 한다.
    $cutoff = $Context.NowUtc.AddDays(-[int]$config.ActiveWindowDays)
    $aged = @()
    foreach ($id in @($desired.Keys)) {
        if ($tierOf[$id] -ne 'Active') { continue }
        $last = $(if ($lastActivity.ContainsKey($id)) { $lastActivity[$id] } else { Get-JsonlLastActivity $desired[$id].TranscriptSource })
        if ($null -eq $last) { throw "Claude 마지막 활동 시각을 읽을 수 없습니다: $id" }
        if ($last -ge $cutoff) { continue }
        $aged += $id
        $tierOf[$id] = 'Archived'
        $record = $desired[$id]
        $record.TranscriptRelative = $script:ClaudeVaultArchive + '/' + $record.Key + '/' + $id + '.jsonl'
        if ($record.SidecarKind) { $record.SidecarRelative = $script:ClaudeVaultArchive + '/' + $record.Key + '/' + $id + $script:ClaudeEntrySuffix }
    }

    $desiredPaths = @{}
    foreach ($record in $desired.Values) {
        $desiredPaths[$record.TranscriptRelative] = [pscustomobject]@{ Kind = $record.TranscriptKind; Source = $record.TranscriptSource; Sha = $record.TranscriptSha }
        if ($record.SidecarKind) {
            $desiredPaths[$record.SidecarRelative] = [pscustomobject]@{ Kind = $record.SidecarKind; Source = $record.SidecarSource; Sha = $record.SidecarSha }
        }
    }

    $current = Get-ClaudeVaultCurrentState $repoRoot
    $vaultOps = New-Object 'Collections.Generic.List[object]'
    foreach ($path in $desiredPaths.Keys) {
        $record = $desiredPaths[$path]
        if ($current.ContainsKey($path) -and [string]::Equals($current[$path], $record.Sha, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($record.Kind -eq 'VaultFile') {
            $sourceRelative = $record.Source.Substring(([IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')).Length).TrimStart('\', '/').Replace('\', '/')
            [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault -RelativePath $path -SourceKind VaultFile `
                -SourceRelativePath $sourceRelative -SourceCommit $Context.VaultCommit -SourceSha256 $record.Sha))
        } else {
            [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault -RelativePath $path -SourceKind StagedFile `
                -SourcePath $record.Source -SourceSha256 $record.Sha))
        }
    }
    foreach ($path in $current.Keys) {
        if (-not $desiredPaths.ContainsKey($path)) { [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath $path)) }
    }

    $finalActive = @($desired.Keys | Where-Object { $tierOf[$_] -eq 'Active' } | Sort-Object)
    $activeSet = @{}
    foreach ($id in $finalActive) { $activeSet[$id] = $true }

    $localOps = New-Object 'Collections.Generic.List[object]'
    foreach ($id in $transcripts.Keys) {
        if ($activeSet.ContainsKey($id)) { continue }
        foreach ($operation in (Get-ClaudeLocalDeleteOperations -Id $id -Transcripts $transcripts -EntriesByCanonical $byCanonical)) {
            [void]$localOps.Add($operation)
        }
    }
    # 소비한 마커는 push 성공 후에 내린다. 실패하면 남아서 다음 실행이 같은 판정을 다시 한다.
    foreach ($relative in $deletion.ConsumedMarkers.Values) {
        [void]$localOps.Add((New-AgentSessionDeleteOperation -TargetRoot ClaudeRegistry -RelativePath $relative))
    }

    New-ClaudePlanObject -Phase Finish -Context $Context -VaultOperations @($vaultOps | ForEach-Object { $_ }) `
        -LocalOperations @($localOps | ForEach-Object { $_ }) -Warnings $warnings `
        -Result ([pscustomobject]@{
            ActiveIds = $finalActive
            DeletedIds = @($deletion.Ids | Sort-Object)
            ArchivedIds = @($aged | Sort-Object)
            RestoredIds = @($restored | Sort-Object)
            MissingIds = @($missing | Sort-Object)
        })
}

function New-ClaudeRestorePlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PlanRoot, [Parameter(Mandatory)][string]$SessionId)
    $repoRoot = [string]$Context.RepoRoot
    $registryRoot = Get-ClaudeAppRegistryRoot -AllowMissing
    $tiers = Get-ClaudeTierInventory $repoRoot
    if (-not $tiers.Archived.ContainsKey($SessionId) -and -not $tiers.Active.ContainsKey($SessionId)) {
        throw "Claude 세션을 찾을 수 없습니다: $SessionId"
    }
    $fromArchive = $tiers.Archived.ContainsKey($SessionId)
    $group = $(if ($fromArchive) { $tiers.Archived[$SessionId] } else { $tiers.Active[$SessionId] })
    $sourceTier = $(if ($fromArchive) { $script:ClaudeVaultArchive } else { $script:ClaudeVaultActive })

    $vaultOps = New-Object 'Collections.Generic.List[object]'
    $localOps = New-Object 'Collections.Generic.List[object]'

    $transcriptSha = Get-AgentSessionFileSha256 $group.Transcript
    $sourceRelative = $sourceTier + '/' + $group.Key + '/' + $SessionId + '.jsonl'
    if ($fromArchive) {
        [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault `
            -RelativePath ($script:ClaudeVaultActive + '/' + $group.Key + '/' + $SessionId + '.jsonl') `
            -SourceKind VaultFile -SourceRelativePath $sourceRelative -SourceCommit $Context.VaultCommit -SourceSha256 $transcriptSha))
        [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath $sourceRelative))
    }

    $snapshot = New-AgentSessionStagedSnapshot -Source $group.Transcript -PlanRoot $PlanRoot -Name ('claude-restore-' + $SessionId)
    [void]$localOps.Add((New-AgentSessionPutOperation -TargetRoot ClaudeHome `
        -RelativePath ('projects/' + $group.Key + '/' + $SessionId + '.jsonl') `
        -SourceKind StagedFile -SourcePath $snapshot.Path -SourceSha256 $snapshot.Sha256))

    if ($group.EntryPath) {
        $sidecarSha = Get-AgentSessionFileSha256 $group.EntryPath
        $sidecarSourceRelative = $sourceTier + '/' + $group.Key + '/' + $SessionId + $script:ClaudeEntrySuffix
        if ($fromArchive) {
            [void]$vaultOps.Add((New-AgentSessionPutOperation -TargetRoot Vault `
                -RelativePath ($script:ClaudeVaultActive + '/' + $group.Key + '/' + $SessionId + $script:ClaudeEntrySuffix) `
                -SourceKind VaultFile -SourceRelativePath $sidecarSourceRelative -SourceCommit $Context.VaultCommit -SourceSha256 $sidecarSha))
            [void]$vaultOps.Add((New-AgentSessionDeleteOperation -TargetRoot Vault -RelativePath $sidecarSourceRelative))
        }
        if ($registryRoot) {
            $artifact = New-ClaudeEntryArtifact -SidecarPath $group.EntryPath -CanonicalId $SessionId -PlanRoot $PlanRoot
            [void]$localOps.Add((New-AgentSessionPutOperation -TargetRoot ClaudeRegistry -RelativePath $artifact.RelativePath `
                -SourceKind StagedFile -SourcePath $artifact.Path -SourceSha256 $artifact.Sha256))
        }
    }

    $activeIds = @(@($tiers.Active.Keys) + $SessionId | Sort-Object -Unique)
    New-ClaudePlanObject -Phase Restore -Context $Context -VaultOperations @($vaultOps | ForEach-Object { $_ }) `
        -LocalOperations @($localOps | ForEach-Object { $_ }) `
        -Result ([pscustomobject]@{ ActiveIds = $activeIds; DeletedIds = @(); ArchivedIds = @(); RestoredIds = @($SessionId); MissingIds = @() })
}

function New-ClaudeCheckpointPlan {
    <#
      LocalOperations 가 적용된 뒤에 호출된다. 변환표는 그때의 registry 를 다시 읽어야
      정확하다 — 지워진 항목은 빠지고 복원된 항목은 들어와 있어야 한다.
    #>
    param([Parameter(Mandatory)]$Context, $State, [Parameter(Mandatory)][string]$PublishedCommit, [Parameter(Mandatory)][string]$PlanRoot)
    $repoRoot = [string]$Context.RepoRoot
    if ($null -eq $State) {
        $tiers = Get-ClaudeTierInventory $repoRoot
        $State = [pscustomobject]@{ ActiveIds = @($tiers.Active.Keys) }
    }
    $registryRoot = Get-ClaudeAppRegistryRoot -AllowMissing
    $live = Get-ClaudeEntryMap $registryRoot
    $entryMap = [ordered]@{}
    foreach ($appSessionId in @($live.Keys | Sort-Object)) { $entryMap[$appSessionId] = [string]$live[$appSessionId] }
    $path = Join-Path $PlanRoot ('claude-checkpoint-' + [guid]::NewGuid().ToString('N') + '.json')
    $content = [pscustomobject]@{
        schemaVersion = 1
        commit = $PublishedCommit
        claudeActiveIds = @($State.ActiveIds | Sort-Object -Unique)
        entryMap = $entryMap
        writtenAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5
    Write-AgentSessionUtf8File -Path $path -Content $content
    $relative = Split-Path -Leaf (Get-ClaudeCheckpointPath $repoRoot)
    New-ClaudePlanObject -Phase Checkpoint -Context $Context -VaultOperations @() `
        -LocalOperations @((New-AgentSessionPutOperation -TargetRoot CheckpointRoot -RelativePath $relative `
            -SourceKind StagedFile -SourcePath $path -SourceSha256 (Get-AgentSessionFileSha256 $path))) `
        -Result $State
}
