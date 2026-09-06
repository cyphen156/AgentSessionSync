#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string] $RunId,
    [ValidatePattern('^$|^[0-9a-fA-F]{40,64}$')][string] $BaselineCommit = '',
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40,64}$')][string] $RemoteCommit,
    [switch] $DiscardLocalChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

# Claude app Start. Applies one pinned remote Claude tree to the closed local
# store. It never fetches, pushes, changes shared refs, or controls processes.
#
# The root never learns the paths below. It supplies pinned Git object ids and
# reads the result contract plus LOCAL_BASE_TREE.
#
# Structure facts used here come from Surveys/Claude/2026-09-01.md:
#   app store    <AppData>\<accountId>\<deviceId>\
#                  local_<appSessionId>.json   app record
#                  deleted_<id>                tombstone, 13 bytes, epoch ms
#   transcripts  <Home>\projects\<slug>\<cliSessionId>.jsonl
#                  <cliSessionId>.desktop-released.json (beside transcript)
#                  slug = cwd with [^A-Za-z0-9] replaced by '-'
#   lineage      priorCliSessionIds (oldest first) then cliSessionId
#   tombstones   one per lineage cliSessionId plus one for appSessionId
#   appSessionId is stable across rewinds; cliSessionId rotates on every rewind

$vaultRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$configPath = Join-Path $vaultRoot 'AgentSessionSync.config.psd1'
$safeRoot = $vaultRoot.Replace('\', '/')
$git = $null
$gzipTool = $null
$runRoot = ''
$receipt = $null
$surveyRequired = $false
$notes = New-Object 'Collections.Generic.List[string]'
$transportLimit = 0
$transportCache = @{}
$validatedVaultTrees = @{}

$RECORD_REQUIRED_FIELDS = @(
    'alwaysAllowedReasons', 'classifierSummaryEnabled', 'cliSessionId',
    'completedTurns', 'createdAt', 'cwd', 'effort', 'enabledMcpTools',
    'isArchived', 'lastActivityAt', 'lastFocusedAt', 'lastSpawnRootDetected',
    'model', 'originCwd', 'permissionMode', 'remoteMcpServersConfig',
    'sessionId', 'sessionPermissionUpdates', 'spawnSeed'
)

function Write-ContractResult {
    param([string] $Result, [string] $Reason, [string] $Detail)
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: Claude'
    Write-Output 'PHASE: Start'
    Write-Output "REASON: $Reason"
    Write-Output "DETAIL: $Detail"
    Write-Output 'PUBLISHED_COMMIT: NONE'
    Write-Output "SURVEY_REQUIRED: $script:surveyRequired"
}

function ConvertTo-NativeArgument {
    param([string] $Value)
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-GitCommand {
    param([string[]] $ArgumentList, [switch] $AllowFailure, [string] $IndexFile)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:git
    $prefix = @('-c', "safe.directory=$script:safeRoot", '-C', $script:vaultRoot)
    $info.Arguments = (($prefix + $ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $previousIndexFile = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $(if ($IndexFile) { $IndexFile } else { $null }), [EnvironmentVariableTarget]::Process)
        [void]$process.Start()
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $previousIndexFile, [EnvironmentVariableTarget]::Process)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $code = $process.ExitCode
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
    }
    finally {
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $previousIndexFile, [EnvironmentVariableTarget]::Process)
        $process.Dispose()
    }
    $lines = @($out -split '\r?\n' | Where-Object { $_ -ne '' })
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Git failed ($code): $($ArgumentList -join ' '): $err"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines; Error = $err }
}

function Get-GitValue {
    param([string[]] $ArgumentList, [string] $IndexFile)
    $result = Invoke-GitCommand $ArgumentList -IndexFile $IndexFile
    if ($result.Output.Count -ne 1) { throw "Git did not return one line: $($ArgumentList -join ' ')" }
    return ([string]$result.Output[0]).Trim()
}

function Resolve-Within {
    param([string] $Root, [string] $RelativePath)
    if (-not $Root -or -not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "A relative path below the owned root is required: $RelativePath"
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the owned root: $RelativePath"
    }
    return $candidate
}

function Test-JsonMember {
    # Presence only. A value cannot answer this: an empty array unrolls to
    # nothing on return, so a present-but-empty field would read as absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonMember {
    # Scalars only, for the same unrolling reason. StrictMode also forbids
    # reading a member that does not exist on the object. The lookup goes
    # through PSObject because dotted access with a variable name silently
    # yields nothing when the name contains a character like '/', which the
    # group scope key does.
    param($Object, [string] $Name)
    if (-not (Test-JsonMember $Object $Name)) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Read-Utf8Json {
    param([string] $Path)
    # Explicit UTF-8. The measured default-encoding read failed on 40 of 400
    # transcript lines, so encoding is never left to the host default.
    $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey('DateKind')) {
        return $text | ConvertFrom-Json -DateKind String
    }
    return $text | ConvertFrom-Json
}

function ConvertTo-AsciiJson {
    param($Value, [int] $Depth)
    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', {
        param($match)
        return '\u' + ([int][char]$match.Value[0]).ToString('x4')
    })
}

function Test-UuidString {
    param([string] $Value)
    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
}

function Get-ProjectSlug {
    param([string] $Cwd)
    return ([regex]::Replace($Cwd, '[^A-Za-z0-9]', '-'))
}

function Assert-SingleChildDirectory {
    param([string] $Parent, [string] $Label)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw "Claude $Label directory is missing: $Parent"
    }
    $children = @(Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction Stop)
    if ($children.Count -ne 1) {
        $script:surveyRequired = $true
        throw "Expected exactly one $Label directory under $Parent, found $($children.Count). The surveyed structure records one."
    }
    return $children[0].FullName
}

# ---------------------------------------------------------------- app store

function Get-ClaudeStore {
    param([hashtable] $Config)
    if (-not $Config.ContainsKey('Claude')) { throw 'Claude is not present in the configuration.' }
    $claude = $Config['Claude']
    $claudeHome = [string]$claude.Home
    $appData = [string]$claude.AppData
    if (-not $claudeHome -or -not (Test-Path -LiteralPath $claudeHome -PathType Container)) { throw "Claude Home is missing: $claudeHome" }
    if (-not $appData -or -not (Test-Path -LiteralPath $appData -PathType Container)) { throw "Claude AppData is missing: $appData" }
    # Initialize stores the claude-code-sessions directory itself in AppData.
    $accountRoot = Assert-SingleChildDirectory $appData 'account'
    $deviceRoot = Assert-SingleChildDirectory $accountRoot 'device'
    $projectsRoot = Join-Path $claudeHome 'projects'
    if (-not (Test-Path -LiteralPath $projectsRoot -PathType Container)) { throw "Claude transcript root is missing: $projectsRoot" }
    return [pscustomobject]@{
        RecordRoot   = $deviceRoot
        ProjectsRoot = $projectsRoot
        ConfigPath   = Join-Path (Split-Path -Parent $appData) 'claude_desktop_config.json'
        AccountId    = Split-Path -Leaf $accountRoot
        DeviceId     = Split-Path -Leaf $deviceRoot
    }
}

function Get-Tombstones {
    param($Store)
    $set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $Store.RecordRoot -File -Filter 'deleted_*' -ErrorAction SilentlyContinue)) {
        $id = $file.Name.Substring('deleted_'.Length)
        if (-not (Test-UuidString $id)) {
            $script:surveyRequired = $true
            throw "Tombstone name is not a known identifier form: $($file.Name)"
        }
        # Measured content is 13 bytes of epoch milliseconds. A tombstone that
        # cannot be interpreted is a deletion signal, and guessing is forbidden.
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file.FullName))
        if ($text -notmatch '^[0-9]{13}$') {
            $script:surveyRequired = $true
            throw "Tombstone content is not epoch milliseconds: $($file.Name)"
        }
        [void]$set.Add($id)
    }
    # The comma keeps the set whole. Returning it bare would enumerate it, and
    # an empty set would arrive as $null.
    return , $set
}

function Get-TombstoneTime {
    param($Store, [string] $Id)
    # deletedAt comes from the verified deletion signal, never from the clock.
    $path = Join-Path $Store.RecordRoot ('deleted_' + $Id)
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
    $origin = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return $origin.AddMilliseconds([double]$text).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Assert-ConsistentTombstoneTimes {
    param($Store, [string[]] $Ids)
    $values = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $Ids) {
        $path = Join-Path $Store.RecordRoot ('deleted_' + $id)
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
        [void]$values.Add($text)
    }
    if ($values.Count -ne 1) {
        $script:surveyRequired = $true
        throw "The tombstones for one Claude lineage carry different deletion times: $($Ids -join ', ')."
    }
}

function Get-TranscriptIndex {
    param($Store)
    # cliSessionId -> path and project slug, built across every project
    # directory so a moved transcript is found rather than reported as absent,
    # and a duplicated identifier is caught instead of guessed.
    $byId = @{}
    foreach ($dir in @(Get-ChildItem -LiteralPath $Store.ProjectsRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($byId.ContainsKey($id)) {
                $script:surveyRequired = $true
                throw "The same transcript identifier exists in two project directories: $id"
            }
            $byId[$id] = [pscustomobject]@{ Path = $file.FullName; Slug = $dir.Name }
        }
    }
    return $byId
}

function Get-LastConversationTime {
    param([string] $Path)
    # The archive clock starts at the last valid conversation record, never at
    # mtime, a file name date or a Git timestamp. Each line is parsed and only
    # its top-level timestamp counts: the survey already recorded a nested
    # attachment timestamp being picked up by a text search, and a meta record
    # carries none at all. Times are compared as instants, not as strings.
    $latest = $null
    $lineNumber = 0
    $reader = New-Object IO.StreamReader($Path, (New-Object Text.UTF8Encoding($false)), $false)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($line -eq '' -or $line -notmatch '"timestamp"') { continue }
            try { $record = $line | ConvertFrom-Json }
            catch {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber is not readable JSON: $Path"
            }
            if (-not (Test-JsonMember $record 'timestamp')) { continue }
            $raw = [string]$record.timestamp
            $parsed = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber carries an unreadable timestamp '$raw': $Path"
            }
            if ($null -eq $latest -or $parsed -gt $latest) { $latest = $parsed }
        }
    }
    finally { $reader.Dispose() }
    return $latest
}

function Test-TranscriptStructure {
    param([string] $Path, [string] $ExpectedId)
    # Every measured line carries type and sessionId, and the sessionId equals
    # the file name in 16570 of 16570 lines. Lines are matched as text: the
    # payload is transported as bytes and is never re-serialised.
    $lineNumber = 0
    $reader = New-Object IO.StreamReader($Path, (New-Object Text.UTF8Encoding($false)), $false)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($line -eq '') { continue }
            if ($line -notmatch '"sessionId"\s*:\s*"([^"]+)"') {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber has no sessionId: $Path"
            }
            if ($Matches[1] -ne $ExpectedId) {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber claims session $($Matches[1]) but the file is $ExpectedId"
            }
            if ($line -notmatch '"type"\s*:\s*"') {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber has no type: $Path"
            }
        }
    }
    finally { $reader.Dispose() }
    if ($lineNumber -eq 0) {
        $script:surveyRequired = $true
        throw "Transcript is empty: $Path"
    }
}

function Assert-SurveyedOptionalFields {
    # Fields the 2026-09-05 survey added. Start neither writes nor rewrites
    # them; it refuses only a shape the survey did not record, so a later app
    # change is reported rather than silently applied.
    #
    # bridgeSessionIds is deliberately absent from every lineage and identity
    # decision in this file. Its values matched no local identifier of any kind,
    # so what they refer to is not established.
    param($Record, [string] $RecordName)

    if (Test-JsonMember $Record 'bridgeSessionIds') {
        # Read the property directly. A helper that returns the value would
        # enumerate it, turning a one-element array into a bare string and an
        # empty one into $null, so the array check could never fail.
        $bridges = $Record.PSObject.Properties['bridgeSessionIds'].Value
        if ($bridges -isnot [System.Array]) {
            $script:surveyRequired = $true
            throw "bridgeSessionIds is not the surveyed array in ${RecordName}."
        }
        foreach ($value in $bridges) {
            # Measured form: 'session_' followed by exactly 24 alphanumerics.
            if ($value -isnot [string] -or $value -notmatch '^session_[A-Za-z0-9]{24}$') {
                $script:surveyRequired = $true
                throw "bridgeSessionIds holds an unsurveyed value form in ${RecordName}: $value"
            }
        }
    }

    if (Test-JsonMember $Record 'promptAppendSnapshot') {
        $snapshot = Get-JsonMember $Record 'promptAppendSnapshot'
        $keys = @($snapshot.PSObject.Properties.Name | Sort-Object) -join ','
        if ($keys -ne 'append,cliVersion,cwd,settingsKey') {
            $script:surveyRequired = $true
            throw "promptAppendSnapshot has unsurveyed keys in ${RecordName}: $keys"
        }
        foreach ($key in @('append', 'cliVersion', 'cwd', 'settingsKey')) {
            if ($snapshot.PSObject.Properties[$key].Value -isnot [string]) {
                $script:surveyRequired = $true
                throw "promptAppendSnapshot.$key is not the surveyed string in ${RecordName}."
            }
        }
    }

    if (Test-JsonMember $Record 'contextExceededCount') {
        # The survey measured a 32-bit integer. A quoted number or a wider type
        # is a shape this tool has not seen, not a value to coerce into one.
        $count = $Record.PSObject.Properties['contextExceededCount'].Value
        if ($count -isnot [int] -or $count -lt 0) {
            $script:surveyRequired = $true
            throw "contextExceededCount is not the surveyed non-negative integer in ${RecordName}: $count"
        }
    }
}

function Get-LocalSessions {
    param($Store, $TranscriptIndex)
    $sessions = New-Object 'Collections.Generic.List[object]'
    $seenLineage = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Store.RecordRoot -File -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
        $record = Read-Utf8Json $file.FullName
        foreach ($field in $RECORD_REQUIRED_FIELDS) {
            if (-not (Test-JsonMember $record $field)) {
                $script:surveyRequired = $true
                throw "App record is missing the surveyed field '$field': $($file.Name)"
            }
        }
        $sessionIdValue = [string](Get-JsonMember $record 'sessionId')
        if ($sessionIdValue -ne [IO.Path]::GetFileNameWithoutExtension($file.Name)) {
            $script:surveyRequired = $true
            throw "App record sessionId '$sessionIdValue' does not match its file name: $($file.Name)"
        }
        if ($sessionIdValue -notmatch '^local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})$') {
            $script:surveyRequired = $true
            throw "App record sessionId is not the measured local_<uuid> form: $sessionIdValue"
        }
        $appSessionId = $Matches[1]
        Assert-SurveyedOptionalFields $record $file.Name

        $prior = @()
        if (Test-JsonMember $record 'priorCliSessionIds') {
            $prior = @($record.priorCliSessionIds | ForEach-Object { [string]$_ })
        }
        # Measured order: priorCliSessionIds runs oldest first, current is newest.
        $lineage = @($prior + @([string](Get-JsonMember $record 'cliSessionId')))
        foreach ($id in $lineage) {
            if (-not (Test-UuidString $id)) {
                $script:surveyRequired = $true
                throw "Lineage identifier is not a UUID in $($file.Name): $id"
            }
            if ($seenLineage.ContainsKey($id)) {
                $script:surveyRequired = $true
                throw "Lineage identifier $id is claimed by two app records: $($seenLineage[$id]) and $appSessionId"
            }
            $seenLineage[$id] = $appSessionId
        }

        $transcripts = New-Object 'Collections.Generic.List[object]'
        $missing = New-Object 'Collections.Generic.List[string]'
        $latest = $null
        foreach ($id in $lineage) {
            if (-not $TranscriptIndex.ContainsKey($id)) { $missing.Add($id); continue }
            $entry = $TranscriptIndex[$id]
            Test-TranscriptStructure $entry.Path $id
            $time = Get-LastConversationTime $entry.Path
            if ($null -ne $time -and ($null -eq $latest -or $time -gt $latest)) { $latest = $time }
            $transcripts.Add([pscustomobject]@{ Id = $id; Path = $entry.Path; Slug = $entry.Slug })
        }

        if ([bool](Get-JsonMember $record 'isArchived')) {
            $script:surveyRequired = $true
            throw "Claude app record $($file.Name) has isArchived=true. Its on-disk and UI behaviour was not measured, and Vault Archive does not write this field."
        }

        $sessions.Add([pscustomobject]@{
            AppSessionId       = $appSessionId
            RecordPath         = $file.FullName
            VaultSessionId     = ''
            TreeId             = ''
            SessionIdValue     = $sessionIdValue
            CurrentCliSessionId = [string](Get-JsonMember $record 'cliSessionId')
            PriorCliSessionIds = @($prior)
            Lineage            = $lineage
            Transcripts        = $transcripts.ToArray()
            MissingTranscripts = $missing.ToArray()
            ApprovedMissing    = @()
            Slug               = (Get-ProjectSlug ([string](Get-JsonMember $record 'cwd')))
            LastConversationAt = $latest
            Display            = [ordered]@{
                title          = [string](Get-JsonMember $record 'title')
                titleSource    = [string](Get-JsonMember $record 'titleSource')
                createdAt      = Get-JsonMember $record 'createdAt'
                lastActivityAt = Get-JsonMember $record 'lastActivityAt'
                completedTurns = Get-JsonMember $record 'completedTurns'
            }
        })
    }
    return $sessions.ToArray()
}

function Test-SessionComplete {
    param($Session)
    # A living session that refers to lineage payloads it cannot produce is the
    # incomplete state, not a new session. It is never published as if whole.
    if ($Session.MissingTranscripts.Count -ne 0 -and @($Session.ApprovedMissing).Count -eq 0) {
        throw ("Session $($Session.AppSessionId) claims lineage transcripts that are absent: " +
            ($Session.MissingTranscripts -join ', ') +
            '. The session cannot be published as a complete unit.')
    }
    if ($null -eq $Session.LastConversationAt) {
        $script:surveyRequired = $true
        throw "Session $($Session.AppSessionId) has no conversation record carrying a timestamp; the archive clock has no start."
    }
}

function Test-TombstoneCoverage {
    param([string[]] $RequiredIds, $Tombstones)
    # Measured rule: one tombstone per lineage cliSessionId plus one for the
    # appSessionId. Payload absence is never a deletion signal.
    $present = @($RequiredIds | Where-Object { $Tombstones.Contains($_) })
    if ($present.Count -eq 0) { return 'None' }
    if ($present.Count -eq $RequiredIds.Count) { return 'Deleted' }
    return 'Partial'
}

# ---------------------------------------------------------------- vault trees

function Get-TreeEntries {
    param([string] $TreeIsh)
    # Every return uses the comma: a bare dictionary would enumerate on return
    # and an empty one would arrive as $null.
    $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if (-not $TreeIsh) { return , $entries }
    $result = Invoke-GitCommand @('ls-tree', '-z', $TreeIsh) -AllowFailure
    if ($result.ExitCode -ne 0) { return , $entries }
    foreach ($line in (($result.Output -join "`n") -split "`0")) {
        if ($line -eq '') { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { throw "Unreadable ls-tree line: $line" }
        $entries[$parts[1]] = $parts[0]
    }
    return , $entries
}

function Get-VaultManifest {
    # A deleted session leaves no app record, so its lineage survives only in
    # the manifest this tool published. That is what lineageIds is read from.
    param([string] $TreeId)
    $entries = Get-TreeEntries $TreeId
    if (-not $entries.ContainsKey('manifest.json')) { throw "Vault session tree $TreeId has no manifest.json." }
    if ($entries['manifest.json'] -notmatch '^100644 blob ([0-9a-f]{40,64})$') {
        throw "Vault manifest is not a regular file in tree $TreeId."
    }
    $text = ((Invoke-GitCommand @('cat-file', 'blob', $Matches[1])).Output -join "`n")
    try { return $text | ConvertFrom-Json }
    catch {
        $script:surveyRequired = $true
        throw "Vault manifest is not JSON in tree $TreeId."
    }
}

function Get-ManifestUnavailable {
    # Lineage transcripts a published manifest already records as absent. The
    # field is written only from an explicit per-conversation approval, so a
    # manifest that carries it is that approval travelling with the session:
    # another machine must not be asked to approve the same loss again.
    param($Manifest, [string] $ExpectedVaultId)
    if (-not (Test-JsonMember $Manifest 'unavailablePriorCliSessionIds')) { return @() }
    $value = $Manifest.PSObject.Properties['unavailablePriorCliSessionIds'].Value
    if ($value -isnot [System.Array] -or $value.Count -eq 0) {
        $script:surveyRequired = $true
        throw "unavailablePriorCliSessionIds is not a non-empty array in Vault session $ExpectedVaultId."
    }
    $ids = @($value | ForEach-Object { [string]$_ })
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $ids) {
        if (-not (Test-UuidString $id) -or -not $seen.Add($id)) {
            $script:surveyRequired = $true
            throw "Invalid or duplicate unavailable lineage identifier in Vault session $ExpectedVaultId."
        }
    }
    return $ids
}

function Get-ManifestLineage {
    param($Manifest, [string] $ExpectedVaultId)
    $fields = @($Manifest.PSObject.Properties.Name | Where-Object { $_ -ne 'unavailablePriorCliSessionIds' } | Sort-Object)
    if (($fields -join ',') -ne 'currentCliSessionId,display,priorCliSessionIds,schemaVersion,vaultSessionId' -or
        [int](Get-JsonMember $Manifest 'schemaVersion') -ne 2 -or
        [string](Get-JsonMember $Manifest 'vaultSessionId') -ne $ExpectedVaultId) {
        $script:surveyRequired = $true
        throw "Unknown Claude portable manifest for Vault session $ExpectedVaultId."
    }
    $display = Get-JsonMember $Manifest 'display'
    if ($null -eq $display) {
        $script:surveyRequired = $true
        throw "Claude portable manifest has no display sidecar for Vault session $ExpectedVaultId."
    }
    $displayFields = @($display.PSObject.Properties.Name | Sort-Object)
    if (($displayFields -join ',') -ne 'completedTurns,createdAt,lastActivityAt,title,titleSource') {
        $script:surveyRequired = $true
        throw "Unknown Claude display sidecar for Vault session $ExpectedVaultId."
    }
    $prior = @((Get-JsonMember $Manifest 'priorCliSessionIds') | ForEach-Object { [string]$_ })
    $current = [string](Get-JsonMember $Manifest 'currentCliSessionId')
    $lineage = @($prior + @($current))
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $lineage) {
        if (-not (Test-UuidString $id) -or -not $seen.Add($id)) {
            $script:surveyRequired = $true
            throw "Invalid or duplicate lineage identifier in Vault session $ExpectedVaultId."
        }
    }
    foreach ($id in @(Get-ManifestUnavailable $Manifest $ExpectedVaultId)) {
        if ($lineage -notcontains $id) {
            $script:surveyRequired = $true
            throw "unavailablePriorCliSessionIds names $id, which is not in the lineage of Vault session $ExpectedVaultId."
        }
        if ($id -eq $current) {
            $script:surveyRequired = $true
            throw "unavailablePriorCliSessionIds names the current transcript of Vault session $ExpectedVaultId."
        }
    }
    return $lineage
}

function Export-GitBlob {
    param([string] $BlobId, [string] $Destination)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:git
    $arguments = @('-c', "safe.directory=$script:safeRoot", '-C', $script:vaultRoot, 'cat-file', 'blob', $BlobId)
    $info.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $output = [IO.File]::Create($Destination)
        try { $process.StandardOutput.BaseStream.CopyTo($output) }
        finally { $output.Dispose() }
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git could not read blob $BlobId`: $errorText" }
    }
    finally { $process.Dispose() }
}

function Get-RegularBlobId {
    param([string] $Entry, [string] $Description)
    if ($Entry -notmatch '^100644 blob ([0-9a-f]{40,64})$') {
        $script:surveyRequired = $true
        throw "$Description is not a regular Git blob."
    }
    return [string]$Matches[1]
}

function Assert-VaultSessionPayload {
    param([string] $TreeId, [string] $VaultSessionId, [string[]] $Lineage, [string[]] $Unavailable = @())
    $validationKey = $TreeId + '|' + $VaultSessionId
    if ($script:validatedVaultTrees.ContainsKey($validationKey)) { return }
    $entries = Get-TreeEntries $TreeId
    $names = @($entries.Keys | Sort-Object)
    if (($names -join ',') -ne 'manifest.json,record,transcripts') {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId has unknown or missing top-level entries: $($names -join ', ')."
    }
    if ($entries['record'] -notmatch '^040000 tree ([0-9a-f]{40,64})$') {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId has no valid record tree."
    }
    $recordEntries = Get-TreeEntries $Matches[1]
    if ($recordEntries.Count -ne 1) {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId must carry exactly one Claude app record."
    }
    $recordName = [string]@($recordEntries.Keys)[0]
    if ($recordName -notmatch '^local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})\.json$') {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId carries an unknown Claude app record name: $recordName."
    }
    $recordBlob = Get-RegularBlobId $recordEntries[$recordName] "Vault app record $recordName"
    $recordPath = Join-Path $script:runRoot ('verify-record-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Export-GitBlob $recordBlob $recordPath
        $record = Read-Utf8Json $recordPath
        foreach ($field in $RECORD_REQUIRED_FIELDS) {
            if (-not (Test-JsonMember $record $field)) {
                $script:surveyRequired = $true
                throw "Vault app record $recordName is missing the surveyed field '$field'."
            }
        }
        Assert-SurveyedOptionalFields $record $recordName
        if ([string](Get-JsonMember $record 'sessionId') -ne [IO.Path]::GetFileNameWithoutExtension($recordName)) {
            $script:surveyRequired = $true
            throw "Vault app record $recordName has a mismatched sessionId."
        }
        $recordPrior = @()
        if (Test-JsonMember $record 'priorCliSessionIds') { $recordPrior = @((Get-JsonMember $record 'priorCliSessionIds') | ForEach-Object { [string]$_ }) }
        $recordLineage = @($recordPrior + @([string](Get-JsonMember $record 'cliSessionId')))
        if (($recordLineage -join ',') -ne ($Lineage -join ',')) {
            $script:surveyRequired = $true
            throw "Vault app record $recordName does not describe the manifest lineage for $VaultSessionId."
        }
        if ([bool](Get-JsonMember $record 'isArchived')) {
            $script:surveyRequired = $true
            throw "Vault app record $recordName carries the unmeasured isArchived=true form."
        }
    }
    finally { Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue }

    if ($entries['transcripts'] -notmatch '^040000 tree ([0-9a-f]{40,64})$') {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId has no valid transcripts tree."
    }
    $transcriptEntries = Get-TreeEntries $Matches[1]
    $expectedNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($lineageId in $Lineage) {
        $rawName = $lineageId + '.jsonl'
        $gzipName = $rawName + '.gz'
        $integrityName = $gzipName + '.integrity.json'
        $hasRaw = $transcriptEntries.ContainsKey($rawName)
        $hasGzip = $transcriptEntries.ContainsKey($gzipName)
        if ($Unavailable -contains $lineageId) {
            # The manifest records this transcript as lost. A payload for it
            # contradicts that record, so its presence is reported, never
            # reconciled silently, and Start creates nothing in its place.
            if ($hasRaw -or $hasGzip) {
                throw "Vault session $VaultSessionId records lineage $lineageId as unavailable but carries a payload for it. This is a disagreement between the record and the stored bytes, not evidence that the app structure changed."
            }
            continue
        }
        if ($hasRaw -eq $hasGzip) {
            $script:surveyRequired = $true
            throw "Vault session $VaultSessionId must carry exactly one raw or gzip payload for lineage $lineageId."
        }

        if ($hasRaw) {
            [void]$expectedNames.Add($rawName)
            $blobId = Get-RegularBlobId $transcriptEntries[$rawName] "Vault transcript $rawName"
            $rawPath = Join-Path $script:runRoot ('verify-' + [guid]::NewGuid().ToString('N') + '.jsonl')
            try {
                Export-GitBlob $blobId $rawPath
                Test-TranscriptStructure $rawPath $lineageId
            }
            finally { Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue }
            continue
        }

        [void]$expectedNames.Add($gzipName)
        [void]$expectedNames.Add($integrityName)
        if (-not $transcriptEntries.ContainsKey($integrityName)) {
            $script:surveyRequired = $true
            throw "Vault gzip transcript $gzipName has no integrity record."
        }
        $gzipBlob = Get-RegularBlobId $transcriptEntries[$gzipName] "Vault gzip transcript $gzipName"
        $integrityBlob = Get-RegularBlobId $transcriptEntries[$integrityName] "Vault integrity record $integrityName"
        $integrityText = ((Invoke-GitCommand @('cat-file', 'blob', $integrityBlob)).Output -join "`n")
        try { $integrity = $integrityText | ConvertFrom-Json }
        catch {
            $script:surveyRequired = $true
            throw "Vault integrity record $integrityName is not JSON."
        }
        $integrityFields = @($integrity.PSObject.Properties.Name | Sort-Object)
        if (($integrityFields -join ',') -ne 'gzipLength,gzipSha256,rawLength,rawSha256' -or
            [string](Get-JsonMember $integrity 'rawSha256') -notmatch '^[0-9a-f]{64}$' -or
            [string](Get-JsonMember $integrity 'gzipSha256') -notmatch '^[0-9a-f]{64}$' -or
            [long](Get-JsonMember $integrity 'rawLength') -lt 0 -or
            [long](Get-JsonMember $integrity 'gzipLength') -lt 0) {
            $script:surveyRequired = $true
            throw "Vault integrity record $integrityName has an unknown shape or value."
        }

        $gzipPath = Join-Path $script:runRoot ('verify-' + [guid]::NewGuid().ToString('N') + '.jsonl.gz')
        $rawPath = $gzipPath.Substring(0, $gzipPath.Length - 3)
        try {
            Export-GitBlob $gzipBlob $gzipPath
            if ((Get-Item -LiteralPath $gzipPath).Length -ne [long]$integrity.gzipLength -or
                (Get-Sha256Hex $gzipPath) -ne [string]$integrity.gzipSha256) {
                $script:surveyRequired = $true
                throw "Vault gzip transcript $gzipName does not match its integrity record."
            }
            $source = [IO.File]::OpenRead($gzipPath)
            try {
                $gzip = New-Object IO.Compression.GZipStream($source, [IO.Compression.CompressionMode]::Decompress)
                try {
                    $destination = [IO.File]::Create($rawPath)
                    try { $gzip.CopyTo($destination) } finally { $destination.Dispose() }
                }
                finally { $gzip.Dispose() }
            }
            finally { $source.Dispose() }
            if ((Get-Item -LiteralPath $rawPath).Length -ne [long]$integrity.rawLength -or
                (Get-Sha256Hex $rawPath) -ne [string]$integrity.rawSha256) {
                $script:surveyRequired = $true
                throw "Vault gzip transcript $gzipName does not restore to its recorded raw payload."
            }
            Test-TranscriptStructure $rawPath $lineageId
        }
        catch {
            if (-not $script:surveyRequired) { $script:surveyRequired = $true }
            throw
        }
        finally {
            Remove-Item -LiteralPath $gzipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
        }
    }
    $actualNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $transcriptEntries.Keys) { [void]$actualNames.Add([string]$name) }
    if ($actualNames.Count -ne $expectedNames.Count -or @($actualNames | Where-Object { -not $expectedNames.Contains($_) }).Count -ne 0) {
        $script:surveyRequired = $true
        throw "Vault session $VaultSessionId has transcript entries that are not explained by its manifest lineage."
    }
    $script:validatedVaultTrees[$validationKey] = $true
}

function Get-DeletedRecord {
    param([string] $Entry, [string] $ExpectedVaultId)
    if ($Entry -notmatch '^100644 blob ([0-9a-f]{40,64})$') {
        $script:surveyRequired = $true
        throw "Deleted record is not a regular file for Vault session $ExpectedVaultId."
    }
    $blobId = $Matches[1]
    $text = ((Invoke-GitCommand @('cat-file', 'blob', $blobId)).Output -join "`n")
    try { $record = $text | ConvertFrom-Json }
    catch { $script:surveyRequired = $true; throw "Deleted record is not JSON for Vault session $ExpectedVaultId." }
    $fields = @($record.PSObject.Properties.Name | Sort-Object)
    if (($fields -join ',') -ne 'deletedAt,lineageIds,schemaVersion,source,vaultSessionId' -or
        [int](Get-JsonMember $record 'schemaVersion') -ne 1 -or
        [string](Get-JsonMember $record 'vaultSessionId') -ne $ExpectedVaultId) {
        $script:surveyRequired = $true
        throw "Invalid minimal Deleted record for Vault session $ExpectedVaultId."
    }
    $lineage = @((Get-JsonMember $record 'lineageIds') | ForEach-Object { [string]$_ })
    if ($lineage.Count -eq 0) { $script:surveyRequired = $true; throw "Deleted record has no lineage for Vault session $ExpectedVaultId." }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $lineage) {
        if (-not (Test-UuidString $id) -or -not $seen.Add($id)) {
            $script:surveyRequired = $true
            throw "Deleted record has an invalid or duplicate lineage for Vault session $ExpectedVaultId."
        }
    }
    if ([string](Get-JsonMember $record 'source') -ne 'verified-app-delete') {
        $script:surveyRequired = $true
        throw "Deleted record has an unknown source for Vault session $ExpectedVaultId."
    }
    return [pscustomobject]@{ Entry = $Entry; BlobId = $blobId; Record = $record; Lineage = $lineage }
}

function Get-SubtreeId {
    param([string] $Commit, [string] $Path)
    if (-not $Commit) { return '' }
    $result = Invoke-GitCommand @('rev-parse', '--verify', '--quiet', ($Commit + ':' + $Path)) -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Output.Count -ne 1) { return '' }
    return ([string]$result.Output[0]).Trim()
}

function Get-VaultState {
    param([string] $Commit)
    # vaultSessionId -> tier and subtree id for Active and Archived, plus the
    # Deleted records. Read from a commit, never from the worktree: the root
    # verifies the worktree is untouched across this call.
    $state = @{}
    $deleted = @{}
    foreach ($tier in @('Active', 'Archived')) {
        $tierId = Get-SubtreeId $Commit ('Claude/' + $tier)
        if (-not $tierId) { continue }
        foreach ($pair in (Get-TreeEntries $tierId).GetEnumerator()) {
            if (-not (Test-UuidString $pair.Key) -or $pair.Value -notmatch '^040000 tree ([0-9a-f]{40,64})$') {
                $script:surveyRequired = $true
                throw "Unknown entry in Claude/$tier at ${Commit}: $($pair.Key)."
            }
            if ($state.ContainsKey($pair.Key)) {
                throw "Vault holds session $($pair.Key) in both Active and Archived at $Commit."
            }
            $treeId = $Matches[1]
            $manifest = Get-VaultManifest $treeId
            $lineage = @(Get-ManifestLineage $manifest $pair.Key)
            $unavailable = @(Get-ManifestUnavailable $manifest $pair.Key)
            Assert-VaultSessionPayload $treeId $pair.Key $lineage $unavailable
            $state[$pair.Key] = [pscustomobject]@{
                Tier = $tier; TreeId = $treeId; Manifest = $manifest
                Lineage = $lineage; Unavailable = $unavailable
            }
        }
    }
    $deletedId = Get-SubtreeId $Commit 'Claude/Deleted'
    if ($deletedId) {
        foreach ($pair in (Get-TreeEntries $deletedId).GetEnumerator()) {
            if ($pair.Key -notmatch '^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})\.json$') {
                $script:surveyRequired = $true
                throw "Unknown entry in Claude/Deleted at ${Commit}: $($pair.Key)."
            }
            $id = $Matches[1]
            if ($state.ContainsKey($id)) {
                $script:surveyRequired = $true
                throw "Vault holds session $id in a survival tier and Deleted at $Commit."
            }
            $deleted[$id] = Get-DeletedRecord $pair.Value $id
        }
    }
    return [pscustomobject]@{ Sessions = $state; Deleted = $deleted }
}

# ---------------------------------------------------------------- composition

function New-IndexPath {
    param([string] $Name)
    $directory = Join-Path $script:runRoot 'index'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $path = Join-Path $directory ($Name + '.index')
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    return $path
}

function Add-BlobFromFile {
    param([string] $IndexFile, [string] $Path, [string] $TreePath)
    # --no-filters keeps the object identical to the bytes on disk whatever
    # attributes the installation carries. Payloads move byte for byte.
    $blob = Get-GitValue @('hash-object', '-w', '--no-filters', '--', $Path)
    [void](Invoke-GitCommand @('update-index', '--add', '--cacheinfo', "100644,$blob,$TreePath") -IndexFile $IndexFile)
    return $blob
}

function Add-BlobFromText {
    param([string] $IndexFile, [string] $Text, [string] $TreePath)
    $temporary = Join-Path $script:runRoot ('blob-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    try { return Add-BlobFromFile $IndexFile $temporary $TreePath }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Copy-SubtreeIntoIndex {
    param([string] $IndexFile, [string] $TreeId, [string] $TreePath)
    # Carry a tree the Vault already holds without re-reading its blobs.
    [void](Invoke-GitCommand @('read-tree', ('--prefix=' + $TreePath + '/'), $TreeId) -IndexFile $IndexFile)
}

function New-SessionManifest {
    param($Session, [string] $Tier)
    # Deterministic by construction: every value derives from content, all
    # fields are ASCII, and -Compress removes the indentation that differs
    # between Windows PowerShell and PowerShell 7. An unchanged session must
    # produce an identical blob, or every run would look like a change.
    $manifest = [ordered]@{
        schemaVersion       = 2
        vaultSessionId      = $Session.VaultSessionId
        currentCliSessionId = $Session.CurrentCliSessionId
        priorCliSessionIds  = @($Session.PriorCliSessionIds)
        display             = $Session.Display
    }
    # Mirrors what Finish published: a loss already accepted for this Vault
    # session stays recorded, so the rebuilt tree matches the pinned remote.
    if (@($Session.ApprovedMissing).Count -ne 0) {
        $manifest['unavailablePriorCliSessionIds'] = @($Session.ApprovedMissing | Sort-Object)
    }
    return ConvertTo-AsciiJson $manifest 8
}

function Get-Sha256Hex {
    param([string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function New-GzipCopy {
    param([string] $Path)
    if (-not $script:gzipTool) {
        throw 'Git for Windows gzip.exe is required for deterministic large-payload transport.'
    }
    $target = Join-Path $script:runRoot ('gz-' + [guid]::NewGuid().ToString('N') + '.gz')
    # Git for Windows supplies one gzip implementation to both PowerShell hosts.
    # -n removes source name/time and makes identical input byte-identical across
    # Windows PowerShell 5.1 and PowerShell 7.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:gzipTool
    $info.Arguments = ((@('-n', '-9', '-c', '--', $Path) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $destination = [IO.File]::Create($target)
        try { $process.StandardOutput.BaseStream.CopyTo($destination) }
        finally { $destination.Dispose() }
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "gzip failed ($($process.ExitCode)): $errorText" }
    }
    finally { $process.Dispose() }
    return $target
}

function Get-TranscriptTransport {
    # Above the ceiling the payload is carried compressed rather than pushed
    # through Git LFS. The limit belongs to the destination repository, not to
    # either app, so both apps use the same one. Compression is done once per
    # file per run and remembered.
    param($Transcript)
    if ($script:transportCache.ContainsKey($Transcript.Path)) { return $script:transportCache[$Transcript.Path] }
    $raw = Get-Item -LiteralPath $Transcript.Path
    if ($raw.Length -le $script:transportLimit) {
        $result = [pscustomobject]@{
            Name = $Transcript.Id + '.jsonl'; Source = $Transcript.Path
            Bytes = $raw.Length; Integrity = ''
        }
    }
    else {
        $gz = New-GzipCopy $Transcript.Path
        $integrity = [ordered]@{
            rawLength  = $raw.Length
            rawSha256  = (Get-Sha256Hex $Transcript.Path)
            gzipLength = (Get-Item -LiteralPath $gz).Length
            gzipSha256 = (Get-Sha256Hex $gz)
        }
        $integrity = ConvertTo-AsciiJson $integrity 4
        $result = [pscustomobject]@{
            Name = $Transcript.Id + '.jsonl.gz'; Source = $gz
            Bytes = (Get-Item -LiteralPath $gz).Length; Integrity = $integrity
        }
    }
    $script:transportCache[$Transcript.Path] = $result
    return $result
}

function Resolve-VaultSessionId {
    param($Session, $Basis, $Remote)
    $localIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Session.Lineage) { [void]$localIds.Add([string]$id) }
    $candidateIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($state in @($Basis, $Remote)) {
        foreach ($pair in $state.Sessions.GetEnumerator()) {
            if (@($pair.Value.Lineage | Where-Object { $localIds.Contains([string]$_) }).Count -ne 0) { [void]$candidateIds.Add([string]$pair.Key) }
        }
        foreach ($pair in $state.Deleted.GetEnumerator()) {
            if (@($pair.Value.Lineage | Where-Object { $localIds.Contains([string]$_) }).Count -ne 0) { [void]$candidateIds.Add([string]$pair.Key) }
        }
    }
    if ($candidateIds.Count -gt 1) {
        throw "Claude lineage maps to multiple Vault sessions: $(@($candidateIds) -join ', '). Nothing was joined or published."
    }
    if ($candidateIds.Count -eq 1) {
        foreach ($candidateId in $candidateIds) { return [string]$candidateId }
    }

    # A genuinely new conversation has no mapping to recover. The oldest
    # measured lineage id is stable across rewinds and is already a globally
    # unique app-issued UUID, so it is the deterministic Vault identity.
    $newId = [string]$Session.Lineage[0]
    foreach ($state in @($Basis, $Remote)) {
        if ($state.Sessions.ContainsKey($newId) -or $state.Deleted.ContainsKey($newId)) {
            throw "New Claude lineage proposes Vault id $newId, but that id already belongs to an unrelated Vault session. Nothing was joined or published."
        }
    }
    return $newId
}

function Add-SessionToIndex {
    param([string] $IndexFile, $Session, [string] $Tier)
    $prefix = $Tier + '/' + $Session.VaultSessionId
    [void](Add-BlobFromText $IndexFile (New-SessionManifest $Session $Tier) ($prefix + '/manifest.json'))
    [void](Add-BlobFromFile $IndexFile $Session.RecordPath ($prefix + '/record/local_' + $Session.AppSessionId + '.json'))
    foreach ($transcript in $Session.Transcripts) {
        $transport = Get-TranscriptTransport $transcript
        [void](Add-BlobFromFile $IndexFile $transport.Source ($prefix + '/transcripts/' + $transport.Name))
        if ($transport.Integrity) {
            [void](Add-BlobFromText $IndexFile $transport.Integrity ($prefix + '/transcripts/' + $transport.Name + '.integrity.json'))
        }
    }
}

function Get-SessionTreeId {
    param($Session, [string] $Tier)
    # The session subtree alone, so it can be compared with the basis and the
    # remote by object id. Equal ids mean byte-identical content.
    $indexFile = New-IndexPath ('probe-' + $Session.VaultSessionId)
    Add-SessionToIndex $indexFile $Session $Tier
    return Get-GitValue @('write-tree', ('--prefix=' + $Tier + '/' + $Session.VaultSessionId)) -IndexFile $indexFile
}

# ---------------------------------------------------------------- Start apply

function Get-EmptyTree {
    $index = New-IndexPath 'empty'
    [void](Invoke-GitCommand @('read-tree', '--empty') -IndexFile $index)
    return Get-GitValue @('write-tree') -IndexFile $index
}

function Get-VaultMaterial {
    param($Session)
    $entries = Get-TreeEntries $Session.TreeId
    if ($entries['record'] -notmatch '^040000 tree ([0-9a-f]{40,64})$') { throw "Missing Claude record tree: $($Session.TreeId)" }
    $recordEntries = Get-TreeEntries $Matches[1]
    if ($recordEntries.Count -ne 1) { throw "Claude session $($Session.Manifest.vaultSessionId) does not carry one app record." }
    $recordName = [string]@($recordEntries.Keys)[0]
    $recordBlob = Get-RegularBlobId $recordEntries[$recordName] "Claude app record $recordName"
    $recordPath = Join-Path $script:runRoot ('remote-record-' + $Session.Manifest.vaultSessionId + '.json')
    Export-GitBlob $recordBlob $recordPath
    $record = Read-Utf8Json $recordPath
    if ($recordName -notmatch '^local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})\.json$') {
        $script:surveyRequired = $true
        throw "Unknown Claude app record name: $recordName"
    }
    $appSessionId = $Matches[1]
    $lineage = @($Session.Lineage | ForEach-Object { [string]$_ })
    $slug = Get-ProjectSlug ([string](Get-JsonMember $record 'cwd'))
    if ($entries['transcripts'] -notmatch '^040000 tree ([0-9a-f]{40,64})$') { throw "Missing Claude transcript tree: $($Session.TreeId)" }
    $transcriptEntries = Get-TreeEntries $Matches[1]
    $unavailable = @(Get-ManifestUnavailable $Session.Manifest $Session.Manifest.vaultSessionId)
    $payloads = @{}
    foreach ($id in $lineage) {
        # A lineage entry the manifest records as lost has no bytes to place.
        # Start writes nothing for it and invents nothing in its place.
        if ($unavailable -contains $id) { continue }
        $rawName = $id + '.jsonl'
        $gzipName = $rawName + '.gz'
        $target = Join-Path $script:runRoot ('remote-' + $id + '.jsonl')
        if ($transcriptEntries.ContainsKey($rawName)) {
            Export-GitBlob (Get-RegularBlobId $transcriptEntries[$rawName] "Claude transcript $rawName") $target
        }
        else {
            $integrityName = $gzipName + '.integrity.json'
            $gzipPath = $target + '.gz'
            Export-GitBlob (Get-RegularBlobId $transcriptEntries[$gzipName] "Claude transcript $gzipName") $gzipPath
            $integrityBlob = Get-RegularBlobId $transcriptEntries[$integrityName] "Claude integrity $integrityName"
            $integrityPath = $target + '.integrity.json'
            Export-GitBlob $integrityBlob $integrityPath
            $integrity = Read-Utf8Json $integrityPath
            if ((Get-Item -LiteralPath $gzipPath).Length -ne [long]$integrity.gzipLength -or
                (Get-Sha256Hex $gzipPath) -ne [string]$integrity.gzipSha256) {
                $script:surveyRequired = $true
                throw "Claude compressed payload failed integrity verification: $gzipName"
            }
            $source = [IO.File]::OpenRead($gzipPath)
            try {
                $gzip = New-Object IO.Compression.GZipStream($source, [IO.Compression.CompressionMode]::Decompress)
                try {
                    $destination = [IO.File]::Create($target)
                    try { $gzip.CopyTo($destination) } finally { $destination.Dispose() }
                } finally { $gzip.Dispose() }
            } finally { $source.Dispose() }
            if ((Get-Item -LiteralPath $target).Length -ne [long]$integrity.rawLength -or
                (Get-Sha256Hex $target) -ne [string]$integrity.rawSha256) {
                $script:surveyRequired = $true
                throw "Claude restored payload failed integrity verification: $gzipName"
            }
        }
        Test-TranscriptStructure $target $id
        $payloads[$id] = $target
    }
    return [pscustomobject]@{
        VaultSessionId = [string]$Session.Manifest.vaultSessionId
        TreeId = $Session.TreeId
        AppSessionId = $appSessionId
        RecordPath = $recordPath
        Slug = $slug
        Lineage = $lineage
        Unavailable = $unavailable
        Payloads = $payloads
    }
}

function Save-StartReceipt {
    $path = Join-Path $script:runRoot 'start-receipt.json'
    [IO.File]::WriteAllText($path, (ConvertTo-AsciiJson $script:receipt 8), (New-Object Text.UTF8Encoding($false)))
}

function Find-StartBackup {
    param([string]$Path)
    foreach ($item in @($script:receipt.backups)) {
        if ([string]::Equals([string]$item.path, $Path, [StringComparison]::OrdinalIgnoreCase)) { return $item }
    }
    return $null
}

function Backup-StartPath {
    param([string]$Path)
    if ($null -ne (Find-StartBackup $Path)) { return }
    $item = [ordered]@{ path=$Path; existed=[IO.File]::Exists($Path); beforeHash=''; backup='' }
    if ($item.existed) {
        $item.beforeHash = Get-Sha256Hex $Path
        $item.backup = Join-Path $script:runRoot ('backup-' + @($script:receipt.backups).Count + '.bin')
        [IO.File]::Copy($Path, $item.backup, $false)
        if ((Get-Sha256Hex $item.backup) -ne $item.beforeHash) { throw "Claude Start backup verification failed: $Path" }
    }
    $script:receipt.backups += @($item)
    Save-StartReceipt
}

function Write-StartFile {
    param([string]$Source, [string]$Destination)
    Backup-StartPath $Destination
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporary = $Destination + '.agent-session-sync-new'
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    [IO.File]::Copy($Source, $temporary, $false)
    if ((Get-Sha256Hex $temporary) -ne (Get-Sha256Hex $Source)) { throw "Claude Start copy verification failed: $Destination" }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $replaceBackup = Join-Path $script:runRoot ([guid]::NewGuid().ToString('N') + '.replace')
        [IO.File]::Replace($temporary, $Destination, $replaceBackup)
        Remove-Item -LiteralPath $replaceBackup -Force
    }
    else { [IO.File]::Move($temporary, $Destination) }
}

function Remove-StartFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    Backup-StartPath $Path
    Remove-Item -LiteralPath $Path -Force
}

function Restore-StartChanges {
    $failures = New-Object 'Collections.Generic.List[string]'
    $items = @($script:receipt.backups)
    [array]::Reverse($items)
    foreach ($item in $items) {
        $path = [string]$item.path
        try {
            if ([bool]$item.existed) {
                if (-not (Test-Path -LiteralPath $item.backup -PathType Leaf) -or
                    (Get-Sha256Hex $item.backup) -ne [string]$item.beforeHash) { throw 'backup is missing or corrupt' }
                $parent = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
                [IO.File]::Copy([string]$item.backup, $path, $true)
                if ((Get-Sha256Hex $path) -ne [string]$item.beforeHash) { throw 'restored bytes do not match the backup' }
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
        catch { $failures.Add("$path : $($_.Exception.Message)") }
    }
    if ($failures.Count -ne 0) { throw ('Claude Start recovery failed; recovery files were retained: ' + ($failures.ToArray() -join '; ')) }
}

function Get-LocalMap {
    param([array]$Sessions, $Basis, $Remote)
    $map = @{}
    foreach ($session in $Sessions) {
        $session.VaultSessionId = Resolve-VaultSessionId $session $Basis $Remote
        if ($map.ContainsKey($session.VaultSessionId)) {
            throw "Two Claude app records map to Vault session $($session.VaultSessionId)."
        }
        # Finish may classify unchanged app-local bytes as Vault Archived while
        # deliberately leaving Claude's own store untouched. Compare those
        # bytes in the tier recorded by the accepted basis (or, on a first
        # receive, by the pinned remote) so the transport-state label alone is
        # not mistaken for unpublished local conversation work.
        $comparisonTier = 'Active'
        if ($Basis.Sessions.ContainsKey($session.VaultSessionId)) {
            $comparisonTier = [string]$Basis.Sessions[$session.VaultSessionId].Tier
        }
        elseif ($Remote.Sessions.ContainsKey($session.VaultSessionId)) {
            $comparisonTier = [string]$Remote.Sessions[$session.VaultSessionId].Tier
        }
        # A loss already accepted for this Vault session is carried into the
        # rebuilt tree, or the local copy could never compare equal to the
        # remote that recorded it. Start never issues a new approval.
        foreach ($state in @($Remote, $Basis)) {
            if ($null -eq $state -or -not $state.Sessions.ContainsKey($session.VaultSessionId)) { continue }
            $recorded = @($state.Sessions[$session.VaultSessionId].Unavailable)
            if ($recorded.Count -ne 0) { $session.ApprovedMissing = $recorded; break }
        }
        $session.TreeId = Get-SessionTreeId $session $comparisonTier
        $map[$session.VaultSessionId] = $session
    }
    return $map
}

function Assert-StartDiscardPermission {
    param($LocalMap, $Basis, $Remote)
    $changed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $LocalMap.GetEnumerator()) {
        $id = [string]$pair.Key
        $localTree = [string]$pair.Value.TreeId
        $remoteEntry = if ($Remote.Sessions.ContainsKey($id)) { $Remote.Sessions[$id] } else { $null }
        $basisEntry = if ($Basis.Sessions.ContainsKey($id)) { $Basis.Sessions[$id] } else { $null }
        if ($remoteEntry -and $remoteEntry.Tier -eq 'Active' -and $remoteEntry.TreeId -eq $localTree) { continue }
        if ($basisEntry -and $basisEntry.Tier -ne 'Deleted' -and $basisEntry.TreeId -eq $localTree) { continue }
        [void]$changed.Add($id)
    }
    foreach ($pair in $Basis.Sessions.GetEnumerator()) {
        if ($pair.Value.Tier -ne 'Active' -or $LocalMap.ContainsKey($pair.Key)) { continue }
        $remoteEntry = if ($Remote.Sessions.ContainsKey($pair.Key)) { $Remote.Sessions[$pair.Key] } else { $null }
        if ($remoteEntry -and $remoteEntry.Tier -eq 'Active') { [void]$changed.Add([string]$pair.Key) }
    }
    if ($changed.Count -ne 0 -and -not $DiscardLocalChanges) {
        $changedText = @($changed | Sort-Object) -join ', '
        $answer = Read-Host ("Claude Start will replace unpublished local sessions: $changedText. Continue? [y/N]")
        if ($answer -notmatch '^(?i:y|yes)$') {
            throw "Claude Start was cancelled before changing app data. Unpublished local sessions: $changedText"
        }
    }
}

function Get-RemovedAppSessionIds {
    param($LocalMap, $Remote, $Basis)
    $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $LocalMap.GetEnumerator()) {
        if (-not $Remote.Sessions.ContainsKey($pair.Key) -or $Remote.Sessions[$pair.Key].Tier -ne 'Active') {
            [void]$ids.Add([string]$pair.Value.AppSessionId)
        }
    }
    $stored = @{}
    foreach ($pair in $Remote.Sessions.GetEnumerator()) {
        if ($pair.Value.Tier -eq 'Archived') { $stored[$pair.Key] = $pair.Value }
    }
    if ($null -ne $Basis) {
        foreach ($id in $Remote.Deleted.Keys) {
            if ($Basis.Sessions.ContainsKey($id)) { $stored[$id] = $Basis.Sessions[$id] }
        }
    }
    foreach ($session in $stored.Values) {
        # Resolve app identity from its transported record, not the Vault ID.
        # Do not unpack archived transcripts merely to remove a placement.
        $entries = Get-TreeEntries $session.TreeId
        if ($entries['record'] -notmatch '^040000 tree ([0-9a-f]{40,64})$') { throw 'Missing stored Claude record tree.' }
        $records = Get-TreeEntries $Matches[1]
        if ($records.Count -ne 1) { throw 'Stored Claude session does not carry one app record.' }
        $name = [string]@($records.Keys)[0]
        if ($name -notmatch '^local_([0-9a-fA-F-]{36})\.json$' -or -not (Test-UuidString $Matches[1])) { throw 'Invalid stored Claude app record name.' }
        $appId = $name.Substring(6, 36)
        $path = Join-Path $script:runRoot ('placement-record-' + $appId + '.json')
        Export-GitBlob (Get-RegularBlobId $records[$name] $name) $path
        $record = Read-Utf8Json $path
        if ([string](Get-JsonMember $record 'sessionId') -ne ('local_' + $appId)) { throw 'Stored Claude app identity differs from its record filename.' }
        [void]$ids.Add($appId)
    }
    return @($ids | Sort-Object)
}

function Initialize-ClaudeStorageBrowser {
if (-not ('ClaudeStorageCdp' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Net.WebSockets;
using System.Threading;
using System.Threading.Tasks;
public sealed class ClaudeStorageCdp : IDisposable {
    private readonly ClientWebSocket socket = new ClientWebSocket();
    public ClaudeStorageCdp(string url) {
        using (var timeout = new CancellationTokenSource(15000))
            socket.ConnectAsync(new Uri(url), timeout.Token).GetAwaiter().GetResult();
    }
    public void Send(string message) {
        byte[] bytes = Encoding.UTF8.GetBytes(message);
        using (var timeout = new CancellationTokenSource(15000))
            socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, timeout.Token).GetAwaiter().GetResult();
    }
    public string Read() {
        using (var timeout = new CancellationTokenSource(20000))
        using (var buffer = new MemoryStream()) {
            byte[] bytes = new byte[65536];
            WebSocketReceiveResult result;
            do {
                result = socket.ReceiveAsync(new ArraySegment<byte>(bytes), timeout.Token).GetAwaiter().GetResult();
                if (result.MessageType == WebSocketMessageType.Close) throw new IOException("Storage browser closed before replying.");
                buffer.Write(bytes, 0, result.Count);
                if (buffer.Length > 16777216) throw new IOException("Storage response exceeded the bounded inspection size.");
            } while (!result.EndOfMessage);
            return Encoding.UTF8.GetString(buffer.ToArray());
        }
    }
    public void Dispose() { socket.Dispose(); }
}
'@
}

}

function Send-StorageCommand {
    param($Channel, [string]$Method, $Parameters, [string]$Session = '')
    $script:storageSequence++
    $id = $script:storageSequence
    $request = @{ id=$id; method=$Method; params=$Parameters }
    if ($Session) { $request.sessionId=$Session }
    $Channel.Send(($request | ConvertTo-Json -Depth 50 -Compress))
    while ($true) {
        $message = $Channel.Read() | ConvertFrom-Json
        if ($message.PSObject.Properties['method'] -and $message.method -eq 'Fetch.requestPaused') {
            # Fulfil every page request locally; never contact Claude or other hosts.
            $script:storageSequence++
            $reply=@{id=$script:storageSequence;sessionId=$message.sessionId;method='Fetch.fulfillRequest';params=@{
                requestId=$message.params.requestId;responseCode=200;
                responseHeaders=@(@{name='Content-Type';value='text/html'},@{name='Cache-Control';value='no-store'});
                body=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('<!doctype html><title>Offline storage maintenance</title>'))
            }}
            $Channel.Send(($reply | ConvertTo-Json -Depth 20 -Compress))
        }
        elseif ($message.PSObject.Properties['id'] -and $message.id -eq $id) {
            if ($message.PSObject.Properties['error']) { throw ($message.error | ConvertTo-Json -Compress) }
            return $message.result
        }
    }
}

function Invoke-StorageBrowser {
    param([string]$Profile, [string]$Expression)
    Initialize-ClaudeStorageBrowser
    $edge=Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path -LiteralPath $edge -PathType Leaf)) { throw 'The installed Chromium storage engine (Microsoft Edge) is unavailable. No app storage was changed.' }
    $profilePath=[IO.Path]::GetFullPath($Profile)
    $portFile=Join-Path $profilePath 'DevToolsActivePort'
    if (Test-Path -LiteralPath $portFile) { Remove-Item -LiteralPath $portFile -Force }
    $arguments=@('--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-extensions','--disable-sync','--disable-features=OptimizationHints,MediaRouter','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',('--user-data-dir="'+$profilePath+'"'),'--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost"','about:blank')
    $browser=Start-Process -FilePath $edge -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $channel=$null
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        do {
            if ($browser.HasExited) { throw 'The isolated storage browser exited before startup.' }
            if (Test-Path -LiteralPath $portFile) { $portLines=@([IO.File]::ReadAllLines($portFile)); if ($portLines.Count -ge 2) { break } }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not (Test-Path -LiteralPath $portFile) -or $portLines.Count -lt 2) { throw 'The isolated storage browser did not become ready.' }
        $channel=[ClaudeStorageCdp]::new(('ws://127.0.0.1:'+ $portLines[0] + $portLines[1]))
        $script:storageSequence=0
        $target=Send-StorageCommand $channel 'Target.createTarget' @{url='about:blank'}
        $attached=Send-StorageCommand $channel 'Target.attachToTarget' @{targetId=$target.targetId;flatten=$true}
        $session=[string]$attached.sessionId
        [void](Send-StorageCommand $channel 'Fetch.enable' @{patterns=@(@{urlPattern='*';requestStage='Request'})} $session)
        [void](Send-StorageCommand $channel 'Page.enable' @{} $session)
        [void](Send-StorageCommand $channel 'Page.navigate' @{url='https://claude.ai/'} $session)
        $ready=Send-StorageCommand $channel 'Runtime.evaluate' @{expression="new Promise(resolve => { if(document.readyState === 'complete') resolve(location.origin); else addEventListener('load', () => resolve(location.origin), {once:true}); })";awaitPromise=$true;returnByValue=$true} $session
        if ($ready.result.value -ne 'https://claude.ai') { throw 'The isolated storage page did not acquire the expected origin.' }
        $value=Send-StorageCommand $channel 'Runtime.evaluate' @{expression=$Expression;returnByValue=$true;awaitPromise=$true} $session
        if ($value.PSObject.Properties['exceptionDetails']) { throw ('Storage operation rejected: '+($value.exceptionDetails | ConvertTo-Json -Depth 10 -Compress)) }
        if ($value.result.type -ne 'string') { throw 'Storage operation did not return its verification JSON.' }
        # Browser.close flushes the private profile before it is used as a candidate.
        $script:storageSequence++
        $channel.Send((@{id=$script:storageSequence;method='Browser.close'} | ConvertTo-Json -Compress))
        if (-not $browser.WaitForExit(15000)) { throw 'The isolated storage browser did not finish flushing its profile.' }
        return [string]$value.result.value
    }
    finally {
        if ($channel) { $channel.Dispose() }
        if (-not $browser.HasExited) { $browser.Kill(); [void]$browser.WaitForExit(5000) }
        $browser.Dispose()
    }
}

function Get-ClaudeStorageFiles {
    param([string]$Directory)
    $files=@{}
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $item.Name -notmatch '^(CURRENT|LOCK|LOG(\.old)?|MANIFEST-[0-9]+|[0-9]+\.(ldb|log|sst|dbtmp))$') {
            $script:surveyRequired=$true
            throw 'Unmeasured entry in Claude Local Storage; nothing was rewritten.'
        }
        if ($item.Name -ne 'LOCK') { $files[$item.Name]=Get-Sha256Hex $item.FullName }
    }
    return $files
}

function Assert-ClaudeStorageFiles {
    param([string]$Directory, $Expected)
    $actual=Get-ClaudeStorageFiles $Directory
    if ($actual.Count -ne $Expected.Count) { throw 'Claude browser storage changed independently; backup is retained.' }
    foreach ($name in $Expected.Keys) {
        if (-not $actual.ContainsKey($name) -or $actual[$name] -ne $Expected[$name]) {
            throw 'Claude browser storage changed independently; backup is retained.'
        }
    }
}

function Prepare-ClaudePlacementStorage {
    param($Store, [string[]]$AppSessionIds)
    if ($AppSessionIds.Count -eq 0) { return $null }
    $directory=Join-Path (Split-Path -Parent $Store.ConfigPath) 'Local Storage\leveldb'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
    $lockPath=Join-Path $directory 'LOCK'
    if (-not [IO.File]::Exists($lockPath)) { throw 'Claude Local Storage exists without its lock file; no storage change was attempted.' }
    $profile=Join-Path $script:runRoot ('storage-profile-'+[guid]::NewGuid().ToString('N'))
    $candidate=Join-Path $profile 'Default\Local Storage\leveldb'
    [IO.Directory]::CreateDirectory($candidate) | Out-Null
    # The app is closed by the caller. Keep its database exclusively locked
    # while copying; Chromium is run only against this isolated private copy.
    $guard=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $before=Get-ClaudeStorageFiles $directory
        foreach ($name in $before.Keys) { [IO.File]::Copy((Join-Path $directory $name),(Join-Path $candidate $name),$false) }
        Assert-ClaudeStorageFiles $directory $before
        Assert-ClaudeStorageFiles $candidate $before
    } finally { $guard.Dispose() }
    $request=@{scope=($Store.AccountId+'/'+$Store.DeviceId);ids=@($AppSessionIds);apply=$true} | ConvertTo-Json -Compress
    $expression=Get-ClaudePlacementExpression $request
    try { $result=Invoke-StorageBrowser $profile $expression | ConvertFrom-Json }
    catch { if ($_.Exception.Message -match 'STRUCTURE:') { $script:surveyRequired=$true }; throw }
    # A browser must not silently reset an unreadable database and call that
    # a successful cleanup. A non-empty established store needs its sidebar.
    if (-not $result.values.PSObject.Properties['dframe-store']) {
        throw 'The copied Claude storage did not expose dframe-store. No app storage was replaced.'
    }
    if (@($result.changed).Count -eq 0) { return $null }
    $request=@{scope=($Store.AccountId+'/'+$Store.DeviceId);ids=@($AppSessionIds);apply=$false} | ConvertTo-Json -Compress
    $verified=Invoke-StorageBrowser $profile (Get-ClaudePlacementExpression $request) | ConvertFrom-Json
    $oldProperties=@($result.values.PSObject.Properties)
    if (@($verified.values.PSObject.Properties).Count -ne $oldProperties.Count) { throw 'Browser storage key count changed after reopening the candidate.' }
    foreach ($property in $oldProperties) {
        $actual=$verified.values.PSObject.Properties[$property.Name]
        if ($null -eq $actual -or $actual.Value -cne $property.Value) { throw 'Browser storage values changed after reopening the candidate.' }
    }
    return [pscustomobject]@{Directory=$directory;Before=$before;Candidate=$candidate;After=(Get-ClaudeStorageFiles $candidate);Changed=@($result.changed)}
}

function Apply-ClaudePlacementStorage {
    param($Plan)
    if ($null -eq $Plan) { return }
    $guard=[IO.File]::Open((Join-Path $Plan.Directory 'LOCK'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Assert-ClaudeStorageFiles $Plan.Directory $Plan.Before
        Assert-ClaudeStorageFiles $Plan.Candidate $Plan.After
        # Back up every original and record every new path before the first
        # replacement, so Start's existing rollback can restore the full set.
        foreach ($name in @(@($Plan.Before.Keys)+@($Plan.After.Keys) | Sort-Object -Unique)) {
            Backup-StartPath (Join-Path $Plan.Directory $name)
        }
        foreach ($name in $Plan.Before.Keys) {
            if (-not $Plan.After.ContainsKey($name)) { Remove-StartFile (Join-Path $Plan.Directory $name) }
        }
        foreach ($name in $Plan.After.Keys) {
            Write-StartFile (Join-Path $Plan.Candidate $name) (Join-Path $Plan.Directory $name)
        }
        Assert-ClaudeStorageFiles $Plan.Directory $Plan.After
    } finally { $guard.Dispose() }
}

function Get-ClaudePlacementExpression {
    param([string]$Request)
    $template = @'
(() => {
  const request=JSON.parse(atob('__REQUEST__'));
  if(location.origin!=='https://claude.ai') throw Error('Unexpected storage origin');
  const targets=new Set(request.ids.map(id=>'code:local_'+id));
  const before=Object.fromEntries(Object.entries(localStorage));
  const after={...before};
  const changed=[];
  const object=(x,label)=>{if(!x||typeof x!=='object'||Array.isArray(x)) throw Error('STRUCTURE: '+label);return x};
  const strings=(x,label)=>{if(!Array.isArray(x)||!x.every(v=>typeof v==='string')) throw Error('STRUCTURE: '+label);return x};
  function pins(x,field) {if(field in x)x[field]=strings(x[field],field).filter(v=>!targets.has(v))}
  function scope(x) {
    object(x,'group scope');object(x.assignments,'assignments');object(x.order,'order');
    if(!Array.isArray(x.groups))throw Error('STRUCTURE: groups');
    for(const [key,value] of Object.entries(x.assignments)) {
      if(typeof value!=='string') throw Error('STRUCTURE: assignment value');
      if(targets.has(key))delete x.assignments[key];
    }
    for(const [key,value] of Object.entries(x.order))x.order[key]=strings(value,'group order').filter(v=>!targets.has(v));
  }
  function scopes(x){object(x,'group scopes');if(request.scope in x)scope(x[request.scope])}
  function edit(key,fn) {
    if(!(key in before))return;
    const value=JSON.parse(before[key]);const snapshot=JSON.stringify(value);
    fn(object(value,key));
    if(JSON.stringify(value)!==snapshot){after[key]=JSON.stringify(value);changed.push(key)}
  }
  edit('dframe-store',x=>{
    if(x.version!==1)throw Error('STRUCTURE: dframe-store version');
    const state=object(x.state,'dframe-store state');
    scopes(state.customGroupsByScope);
    if(state.pendingLegacyGroupMigration!==null)throw Error('STRUCTURE: legacy group migration not settled');
    pins(state,'pinnedOrder');pins(state,'homeProjectsPinnedOrder');
  });
  edit('LSS-persisted.dframe-group-scopes',x=>scopes(x.value));
  edit('LSS-persisted.dframe-local-slice',x=>{
    object(x.value,'local slice');
    if(['customGroups','customGroupAssignments','customGroupOrder'].some(k=>k in x.value))throw Error('STRUCTURE: legacy local slice');
    pins(x.value,'pinnedOrder');pins(x.value,'homeProjectsPinnedOrder');
  });
  if(!request.apply && changed.length)throw Error('Non-Active Claude placements remain in browser storage');
  for(const key of changed)localStorage.setItem(key,after[key]);
  const actual=Object.fromEntries(Object.entries(localStorage));
  if(Object.keys(actual).length!==Object.keys(before).length || Object.entries(after).some(([k,v])=>actual[k]!==v))throw Error('Storage values changed outside the exact replacement set');
  return JSON.stringify({changed,values:actual});
})()

'@
    return $template.Replace('__REQUEST__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Request)))
}

function Get-ClaudePlacementScope {
    param($Config, $Store)
    $preferences = Get-JsonMember $Config 'preferences'
    $epitaxy = Get-JsonMember $preferences 'epitaxyPrefs'
    $scopes = Get-JsonMember $epitaxy 'dframe-group-scopes'
    $scope = Get-JsonMember $scopes ($Store.AccountId + '/' + $Store.DeviceId)
    if ($null -eq $scope) { return $null }
    foreach ($field in @('assignments', 'order')) {
        $value = Get-JsonMember $scope $field
        if ($null -eq $value -or $value -isnot [pscustomobject]) {
            $script:surveyRequired = $true
            throw "Unknown Claude placement $field shape in the current account/device scope."
        }
    }
    foreach ($property in @($scope.order.PSObject.Properties)) {
        if ($property.Value -isnot [Array] -or @($property.Value | Where-Object { $_ -isnot [string] }).Count -ne 0) {
            $script:surveyRequired = $true
            throw 'Unknown Claude placement order value; no placement was rewritten.'
        }
    }
    return $scope
}

function Assert-ClaudeAssignmentsRemoved {
    param($Store, [string[]]$AppSessionIds)
    if ($AppSessionIds.Count -eq 0 -or -not [IO.File]::Exists($Store.ConfigPath)) { return }
    $scope = Get-ClaudePlacementScope (Read-Utf8Json $Store.ConfigPath) $Store
    if ($null -eq $scope) { return }
    foreach ($appId in $AppSessionIds) {
        $key = 'code:local_' + $appId
        if (Test-JsonMember $scope.assignments $key) { throw "Non-Active Claude assignment remains: $appId" }
        foreach ($property in @($scope.order.PSObject.Properties)) {
            if (@($property.Value) -contains $key) { throw "Non-Active Claude order entry remains: $appId" }
        }
    }
}

function Remove-ClaudeAssignments {
    param($Store, [string[]]$AppSessionIds)
    if ($AppSessionIds.Count -eq 0 -or -not (Test-Path -LiteralPath $Store.ConfigPath -PathType Leaf)) { return }
    $config = Read-Utf8Json $Store.ConfigPath
    $targetScope = Get-ClaudePlacementScope $config $Store
    if ($null -eq $targetScope) { return }
    $changed = $false
    foreach ($scope in @($targetScope)) {
        $assignments = Get-JsonMember $scope 'assignments'
        $order = Get-JsonMember $scope 'order'
        if ($null -eq $assignments -or $null -eq $order) {
            $script:surveyRequired = $true
            throw 'Unknown Claude group scope shape in the current account/device scope.'
        }
        foreach ($appSessionId in $AppSessionIds) {
            $key = 'code:local_' + $appSessionId
            if ($null -ne $assignments.PSObject.Properties[$key]) {
                $assignments.PSObject.Properties.Remove($key)
                $changed = $true
            }
            foreach ($orderProperty in @($order.PSObject.Properties)) {
                $before = @($orderProperty.Value | ForEach-Object { [string]$_ })
                $after = @($before | Where-Object { $_ -ne $key })
                if ($after.Count -ne $before.Count) { $orderProperty.Value = @($after); $changed = $true }
            }
        }
    }
    if ($changed) {
        $temporary = Join-Path $script:runRoot 'claude-desktop-config.new'
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
        Write-StartFile $temporary $Store.ConfigPath
    }
    Assert-ClaudeAssignmentsRemoved $Store $AppSessionIds
}

function Apply-RemoteClaude {
    param($Store, $LocalMap, $Remote, $Tombstones, [string[]]$RemovedAppSessionIds, $PlacementStoragePlan)
    $active = @{}
    $activeAppIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $Remote.Sessions.GetEnumerator()) {
        if ($pair.Value.Tier -ne 'Active') { continue }
        $material = Get-VaultMaterial $pair.Value
        if (-not $activeAppIds.Add($material.AppSessionId)) {
            $script:surveyRequired = $true
            throw "Two remote Claude sessions use appSessionId $($material.AppSessionId)."
        }
        $active[$pair.Key] = $material
    }
    foreach ($appId in $RemovedAppSessionIds) {
        if ($activeAppIds.Contains($appId)) { throw "Claude app identity is both active and selected for placement removal: $appId" }
    }
    foreach ($pair in $LocalMap.GetEnumerator()) {
        $desired = if ($active.ContainsKey($pair.Key)) { $active[$pair.Key] } else { $null }
        if ($desired -and $desired.AppSessionId -ne $pair.Value.AppSessionId) {
            $script:surveyRequired = $true
            throw ("Claude appSessionId differs for Vault session $($pair.Key): " +
                "local=$($pair.Value.AppSessionId), remote=$($desired.AppSessionId). " +
                'Cross-PC remapping has not been measured; nothing was changed.')
        }
        if ($null -ne $desired) { continue }
        Remove-StartFile $pair.Value.RecordPath
        foreach ($transcript in $pair.Value.Transcripts) { Remove-StartFile $transcript.Path }
    }
    Apply-ClaudePlacementStorage $PlacementStoragePlan
    Remove-ClaudeAssignments $Store $RemovedAppSessionIds
    foreach ($material in $active.Values) {
        $recordTarget = Join-Path $Store.RecordRoot ('local_' + $material.AppSessionId + '.json')
        Write-StartFile $material.RecordPath $recordTarget
        foreach ($id in $material.Lineage) {
            # An entry recorded as unavailable has no bytes to write. Its
            # tombstone and sidecar are still cleared: the session is being
            # received as live, and leaving those would contradict that.
            if (@($material.Unavailable) -notcontains $id) {
                $target = Resolve-Within $Store.ProjectsRoot ($material.Slug + '/' + $id + '.jsonl')
                Write-StartFile $material.Payloads[$id] $target
            }
            if ($Tombstones.Contains($id)) { Remove-StartFile (Join-Path $Store.RecordRoot ('deleted_' + $id)) }
            Remove-StartFile (Resolve-Within $Store.ProjectsRoot ($material.Slug + '/' + $id + '.desktop-released.json'))
        }
        if ($Tombstones.Contains($material.AppSessionId)) {
            Remove-StartFile (Join-Path $Store.RecordRoot ('deleted_' + $material.AppSessionId))
        }
    }
}

function Assert-ClaudeApplied {
    param($Store, $Remote, [string[]]$RemovedAppSessionIds)
    $actual = @(Get-LocalSessions $Store (Get-TranscriptIndex $Store))
    $actualMap = Get-LocalMap $actual $Remote $Remote
    foreach ($pair in $actualMap.GetEnumerator()) {
        if (-not $Remote.Sessions.ContainsKey($pair.Key) -or $Remote.Sessions[$pair.Key].Tier -ne 'Active') {
            throw "Non-Active Claude session remains in the local active store: $($pair.Key)"
        }
        if ($pair.Value.TreeId -ne $Remote.Sessions[$pair.Key].TreeId) {
            throw "Applied Claude session does not match the pinned remote: $($pair.Key)"
        }
        foreach ($id in @($pair.Value.Lineage) + @($pair.Value.AppSessionId)) {
            if ([IO.File]::Exists((Join-Path $Store.RecordRoot ('deleted_' + $id)))) { throw "Active Claude deletion tombstone remains: $id" }
        }
        foreach ($id in $pair.Value.Lineage) {
            $sidecar = Resolve-Within $Store.ProjectsRoot ($pair.Value.Slug + '/' + $id + '.desktop-released.json')
            if ([IO.File]::Exists($sidecar)) { throw "Active Claude release sidecar remains: $id" }
        }
    }
    foreach ($pair in $Remote.Sessions.GetEnumerator()) {
        if ($pair.Value.Tier -eq 'Active' -and -not $actualMap.ContainsKey($pair.Key)) {
            throw "Remote Active Claude session was not applied: $($pair.Key)"
        }
    }
    Assert-ClaudeAssignmentsRemoved $Store $RemovedAppSessionIds
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Configuration is missing. Run Initialize-AgentSessionSync.ps1 first: $configPath" }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $gitRoot = Split-Path (Split-Path $git -Parent) -Parent
    foreach ($candidate in @((Join-Path $gitRoot 'usr\bin\gzip.exe'), (Join-Path $gitRoot 'mingw64\bin\gzip.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $gzipTool = $candidate; break }
    }
    $gitDirectory = Get-GitValue @('rev-parse', '--absolute-git-dir')
    $runsRoot = Join-Path $gitDirectory 'agent-session-sync\ClaudeStart'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) { [IO.Directory]::CreateDirectory($runsRoot) | Out-Null }
    $runRoot = Resolve-Within $runsRoot $RunId
    if (Test-Path -LiteralPath $runRoot) { throw "RunId already exists: $RunId" }
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $transportLimit = [long]$config['TransportFileLimitBytes']
    if ($transportLimit -ne 99614720) { throw 'Expected the agreed 99614720-byte transport threshold.' }
    $store = Get-ClaudeStore $config
    $receipt = [ordered]@{ schemaVersion=1; runId=$RunId; status='validating'; backups=@() }
    Save-StartReceipt
    $basis = Get-VaultState $BaselineCommit
    $remote = Get-VaultState $RemoteCommit
    $local = @(Get-LocalSessions $store (Get-TranscriptIndex $store))
    $localMap = Get-LocalMap $local $basis $remote
    $tombstones = Get-Tombstones $store
    Assert-StartDiscardPermission $localMap $basis $remote
    $removedAppSessionIds = @(Get-RemovedAppSessionIds $localMap $remote $basis)
    $placementStoragePlan = Prepare-ClaudePlacementStorage $store $removedAppSessionIds
    $receipt.status = 'applying'
    Save-StartReceipt
    Apply-RemoteClaude $store $localMap $remote $tombstones $removedAppSessionIds $placementStoragePlan
    Assert-ClaudeApplied $store $remote $removedAppSessionIds
    if ($placementStoragePlan) { Assert-ClaudeStorageFiles $placementStoragePlan.Directory $placementStoragePlan.After }
    $localTree = Get-SubtreeId $RemoteCommit 'Claude'
    if (-not $localTree) { $localTree = Get-EmptyTree }
    $receipt.status = 'applied'
    Save-StartReceipt
    Remove-Item -LiteralPath $runRoot -Recurse -Force
    Write-ContractResult 'Success' 'Pinned Claude state applied' "Known structure and payload integrity passed for $($remote.Sessions.Count + $remote.Deleted.Count) Vault sessions. UI and future app interpretation are not claimed."
    Write-Output "LOCAL_BASE_TREE: $localTree"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $retain = $false
    if ($receipt -and [string]$receipt.status -eq 'applying') {
        try { Restore-StartChanges; $message += ' This Start attempt was restored.' }
        catch { $message += ' ' + $_.Exception.Message; $retain = $true }
    }
    if (-not $retain -and $runRoot -and (Test-Path -LiteralPath $runRoot)) {
        try { Remove-Item -LiteralPath $runRoot -Recurse -Force }
        catch { $message += ' Scratch cleanup failed: ' + $_.Exception.Message }
    }
    Write-ContractResult 'Failure' 'Claude Start could not complete' $message
    exit 1
}
