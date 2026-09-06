#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Cancel', 'Complete')][string] $Operation,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string] $RunId,
    [ValidatePattern('^$|^[0-9a-fA-F]{40,64}$')][string] $BaselineCommit = '',
    [ValidatePattern('^$|^[0-9a-fA-F]{40,64}$')][string] $RemoteCommit = '',
    [ValidatePattern('^$|^[0-9a-fA-F]{40,64}$')][string] $PublishedCommit = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

# Claude app Finish. Reads this PC's Claude store, judges every session against
# the accepted comparison basis and the current remote, and returns two Git
# tree object ids. Finish does not implement Claude's native Archive operation:
# the 30-day archive is a Vault transport tier and does not mutate app-local data.
#
# The root never learns the paths below. It sends Prepare/Cancel/Complete and
# reads RESULT plus, for Prepare, PREPARED_TREE and LOCAL_BASE_TREE.
#
# Structure facts used here come from Surveys/Claude/2026-09-01.md:
#   app store    <AppData>\<accountId>\<deviceId>\
#                  local_<appSessionId>.json   app record
#                  deleted_<id>                tombstone, 13 bytes, epoch ms
#                  <cliSessionId>.desktop-released.json
#   transcripts  <Home>\projects\<slug>\<cliSessionId>.jsonl
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
    Write-Output "PHASE: Finish.$Operation"
    Write-Output "REASON: $Reason"
    Write-Output "DETAIL: $Detail"
    $reportedCommit = if ($Operation -eq 'Complete' -and $PublishedCommit) { $PublishedCommit } else { 'NONE' }
    Write-Output "PUBLISHED_COMMIT: $reportedCommit"
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
    # Fields the 2026-09-05 survey added. They are carried in the record bytes
    # and never rewritten; this only refuses a shape the survey did not record,
    # so that a later app change is reported instead of silently transported.
    #
    # bridgeSessionIds is deliberately absent from every lineage, identity and
    # deletion decision in this file. Its values matched no cliSessionId,
    # appSessionId, priorCliSessionIds entry, transcript name, transcript record
    # or LevelDB entry, so what they refer to is not established.
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

function Get-AcknowledgedMissingLineage {
    # Per-conversation approval that a lineage transcript is known to be gone.
    # Keyed by appSessionId because cliSessionId rotates on every rewind and
    # would stop naming the conversation the user approved. Nothing adds to this
    # map: it is written by the user in the private configuration only.
    param([hashtable] $Config)
    $map = @{}
    $claude = $Config['Claude']
    if (-not $claude.ContainsKey('AcknowledgedMissingLineage')) { return , $map }
    $declared = $claude['AcknowledgedMissingLineage']
    if ($declared -isnot [hashtable]) {
        throw 'Claude.AcknowledgedMissingLineage must be a hashtable of appSessionId to missing cliSessionId values.'
    }
    foreach ($key in $declared.Keys) {
        $appSessionId = [string]$key
        if (-not (Test-UuidString $appSessionId)) {
            throw "Claude.AcknowledgedMissingLineage key is not an appSessionId UUID: $appSessionId"
        }
        $ids = @($declared[$key] | ForEach-Object { [string]$_ })
        if ($ids.Count -eq 0) {
            throw "Claude.AcknowledgedMissingLineage lists no identifier for $appSessionId."
        }
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $ids) {
            if (-not (Test-UuidString $id) -or -not $seen.Add($id)) {
                throw "Claude.AcknowledgedMissingLineage holds an invalid or duplicate identifier for ${appSessionId}: $id"
            }
        }
        $map[$appSessionId] = $ids
    }
    return , $map
}

function Get-ApprovedMissing {
    # A loss is publishable only where an approval names exactly the transcripts
    # that are actually absent. Approving a superset would let a later loss ride
    # in unnoticed; approving a subset leaves an unapproved gap. Both fail.
    # Always returns an array, never $null: an empty result means "no approval
    # applies", and Test-SessionComplete is the single place that decides what
    # that means for a session that is actually missing transcripts.
    param($Session, $Acknowledged, $Basis, $Remote)
    $missing = @($Session.MissingTranscripts)

    # The recorded approval is read before anything else, including when
    # nothing is missing now. A transcript recorded as lost that has since
    # reappeared is a disagreement between the record and the disk, and it is
    # only visible by comparing the two sets.
    $approved = @()
    $source = ''
    foreach ($state in @($Remote, $Basis)) {
        if ($null -eq $state) { continue }
        if (-not $state.Sessions.ContainsKey($Session.VaultSessionId)) { continue }
        $recorded = @($state.Sessions[$Session.VaultSessionId].Unavailable)
        if ($recorded.Count -eq 0) { continue }
        # A published approval travels with the session. Another machine issues
        # its own appSessionId, so it must never be asked to approve again.
        $approved = $recorded
        $source = 'the published manifest'
        break
    }
    if ($approved.Count -eq 0 -and $Acknowledged.ContainsKey($Session.AppSessionId)) {
        $approved = @($Acknowledged[$Session.AppSessionId])
        $source = 'the private configuration'
    }
    if ($approved.Count -eq 0) { return @() }

    # An approval may only name earlier lineage entries. The current transcript
    # is the live conversation itself; a session without it is not a session,
    # and accepting its loss would publish an empty shell as if it were whole.
    foreach ($id in $approved) {
        if ($id -eq $Session.CurrentCliSessionId) {
            throw ("Session $($Session.VaultSessionId) has $source approving its current transcript $id." +
                ' Only earlier lineage entries can be accepted as lost. Nothing was published.')
        }
        if (@($Session.PriorCliSessionIds) -notcontains $id) {
            throw ("Session $($Session.VaultSessionId) has $source approving $id, which is not one of its" +
                ' earlier lineage entries. Nothing was published.')
        }
    }

    $missingSet = @($missing | Sort-Object)
    $approvedSet = @($approved | Sort-Object)
    if (($missingSet -join ',') -ne ($approvedSet -join ',')) {
        $found = @($approved | Where-Object { $missing -notcontains $_ })
        if ($found.Count -ne 0) {
            throw ("Session $($Session.VaultSessionId) has $source recording " + ($found -join ', ') +
                ' as lost, but those transcripts are present on this PC. The disagreement was not' +
                ' resolved automatically and nothing was published.')
        }
        throw ("Session $($Session.VaultSessionId) is missing " + ($missingSet -join ', ') +
            ' but ' + $source + ' approves ' + ($approvedSet -join ', ') +
            '. The approved set must name exactly the absent transcripts. Nothing was published.')
    }
    return $approved
}

function Test-SessionComplete {
    param($Session)
    # A living session that refers to lineage payloads it cannot produce is the
    # incomplete state, not a new session. It is never published as if whole,
    # unless every absent transcript is named by an explicit approval, in which
    # case the session is published with that loss recorded rather than hidden.
    if ($Session.MissingTranscripts.Count -ne 0 -and $Session.ApprovedMissing.Count -eq 0) {
        throw ("Session $($Session.AppSessionId) claims lineage transcripts that are absent: " +
            ($Session.MissingTranscripts -join ', ') +
            '. The session cannot be published as a complete unit. If this loss is known and' +
            ' accepted, name exactly those identifiers under Claude.AcknowledgedMissingLineage' +
            " for appSessionId $($Session.AppSessionId) in the private configuration.")
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
            # The manifest records this transcript as lost. Carrying bytes for
            # it would contradict that record, so its presence is a difference
            # to report, never something to accept and reconcile silently.
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
    # Written only where an approval named exactly the absent transcripts. The
    # field records the loss so a later run, and every other machine, reads it
    # as accepted history instead of as a session that failed to assemble.
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

# ---------------------------------------------------------------- run state

function Get-StatePath { return Join-Path $script:runRoot 'state.json' }

function Write-RunState {
    param($State)
    $path = Get-StatePath
    $temporary = $path + '.new'
    $backup = $path + '.old'
    [IO.File]::WriteAllText($temporary, (ConvertTo-AsciiJson $State 5), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [IO.File]::Replace($temporary, $path, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    else { [IO.File]::Move($temporary, $path) }
}

function Initialize-RunState {
    if (Test-Path -LiteralPath (Get-StatePath) -PathType Leaf) { throw "Run $RunId already has preparation state." }
    Write-RunState ([ordered]@{
        schemaVersion  = 1
        runId          = $RunId
        status         = 'checking'
        appWrites      = $false
        baselineCommit = $BaselineCommit
        remoteCommit   = $RemoteCommit
        preparedTree   = ''
        localBaseTree  = ''
    })
}

function Save-RunState {
    param([string] $PreparedTree, [string] $LocalBaseTree)
    $state = [ordered]@{
        schemaVersion  = 1
        runId          = $RunId
        status         = 'prepared'
        appWrites      = $false
        baselineCommit = $BaselineCommit
        remoteCommit   = $RemoteCommit
        preparedTree   = $PreparedTree
        localBaseTree  = $LocalBaseTree
    }
    Write-RunState $state
}

function Get-RunState {
    # Cancel and Complete act only on a preparation this same run produced.
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $state = Read-Utf8Json $path
    if ([int](Get-JsonMember $state 'schemaVersion') -ne 1 -or [string](Get-JsonMember $state 'runId') -ne $RunId) {
        throw "Run state does not belong to this Claude Finish run: $RunId."
    }
    return $state
}

# ---------------------------------------------------------------- operations

function Invoke-Prepare {
    param([hashtable] $Config)
    Initialize-RunState
    $activeWindowDays = [int]$Config['ActiveWindowDays']
    if ($activeWindowDays -lt 1) { throw 'ActiveWindowDays must be at least 1.' }
    $script:transportLimit = [long]$Config['TransportFileLimitBytes']
    if ($script:transportLimit -lt 1) { throw 'TransportFileLimitBytes must be at least 1.' }

    $store = Get-ClaudeStore $Config
    $tombstones = Get-Tombstones $store
    $sessions = @(Get-LocalSessions $store (Get-TranscriptIndex $store))
    $basis = Get-VaultState $BaselineCommit
    $remote = Get-VaultState $RemoteCommit
    $acknowledged = Get-AcknowledgedMissingLineage $Config
    $mapped = @{}
    foreach ($session in $sessions) {
        $session.VaultSessionId = Resolve-VaultSessionId $session $basis $remote
        if ($mapped.ContainsKey($session.VaultSessionId)) {
            throw "Two Claude app records map to Vault session $($session.VaultSessionId): $($mapped[$session.VaultSessionId]) and $($session.AppSessionId)."
        }
        $mapped[$session.VaultSessionId] = $session.AppSessionId
        # A published approval outranks the configuration: it is the same
        # acceptance already carried across machines under this Vault key.
        $session.ApprovedMissing = @(Get-ApprovedMissing $session $acknowledged $basis $remote)
    }

    $archiveCutoff = [DateTimeOffset]::UtcNow.AddDays(-$activeWindowDays)
    $publish = @{}
    $localBasis = @{}
    $deletedRecords = @{}
    $conflicts = New-Object 'Collections.Generic.List[string]'
    $handled = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

    foreach ($session in $sessions) {
        # Vault paths and comparisons use the oldest app-issued lineage UUID;
        # tombstone lookup also knows this machine's separate appSessionId.
        # The two identifier spaces must never be conflated.
        $id = $session.VaultSessionId
        [void]$handled.Add($id)

        # A measured app deletion removes the app record, so a live record and a
        # tombstone for the same session cannot both be true. If they are, the
        # structure is not what was surveyed and nothing is concluded from it.
        if ((Test-TombstoneCoverage @($session.Lineage + @($session.AppSessionId)) $tombstones) -ne 'None') {
            $script:surveyRequired = $true
            throw "Session $id still has an app record while a tombstone exists for it. The measured deletion removes the record, so this state is unknown."
        }

        Test-SessionComplete $session
        if (@($session.ApprovedMissing).Count -ne 0) {
            $notes.Add("$id was published with its approved lineage loss recorded: " +
                (@($session.ApprovedMissing | Sort-Object) -join ', ') + '. Those transcripts were not fabricated.')
        }

        # The tier follows the content: both PCs read the same last conversation
        # record, so it is recomputed here rather than carried from the remote.
        $tier = if ($session.LastConversationAt -lt $archiveCutoff) { 'Archived' } else { 'Active' }
        $localTree = Get-SessionTreeId $session $tier
        $basisTree = if ($basis.Sessions.ContainsKey($id)) { $basis.Sessions[$id].TreeId } else { '' }
        $remoteEntry = if ($remote.Sessions.ContainsKey($id)) { $remote.Sessions[$id] } else { $null }
        $remoteTree = if ($remoteEntry) { $remoteEntry.TreeId } else { '' }
        $localChanged = ($localTree -ne $basisTree)
        $remoteChanged = ($remoteTree -ne $basisTree)
        $localBasis[$id] = [pscustomobject]@{ Tier = $tier; TreeId = $localTree }

        if ($null -eq $remoteEntry -and $basis.Sessions.ContainsKey($id) -and -not $remote.Deleted.ContainsKey($id)) {
            $conflicts.Add("$id existed in this PC's accepted basis but is absent from every remote state without a Deleted record.")
            continue
        }

        if ($remote.Deleted.ContainsKey($id)) {
            # A remote Deleted record and any locally present conversation
            # must be reported, including an unchanged stale copy. Do not infer
            # why it remains or silently skip it. The user decides what follows.
            $conflicts.Add("$id is Deleted on the remote but remains in this PC's Claude store (appSessionId=$($session.AppSessionId)). Review required regardless of local edits. No automatic local deletion or republication was performed.")
            continue
        }

        if ($remoteEntry -and $remoteEntry.Tier -eq 'Archived' -and $tier -eq 'Active') {
            $conflicts.Add("$id is Archived on the remote but this PC now classifies it Active. Finish does not perform the explicit Archived-to-Active Reactivate transition.")
            continue
        }

        if ($localChanged -and $remoteChanged -and $localTree -ne $remoteTree) {
            $conflicts.Add("$id changed on this PC and on the remote since the accepted basis.")
            continue
        }

        if ($localChanged -or $null -eq $remoteEntry) {
            $publish[$id] = [pscustomobject]@{ Session = $session; Tier = $tier; TreeId = $localTree }
            if ($tier -eq 'Archived') {
                $notes.Add("$id is carried in the Vault Archived tier. Claude app-local data was not changed.")
            }
        }
        else {
            # The remote moved and this PC did not. Keep the remote as it is;
            # an unchanged stale copy never undoes an accepted remote session.
            $publish[$id] = [pscustomobject]@{ Session = $null; Tier = $remoteEntry.Tier; TreeId = $remoteTree }
        }
    }

    # Sessions the Vault knows that this PC no longer stores. The app record is
    # gone, so the lineage comes from the published manifest. Absence alone is
    # never a deletion: only the tombstone set decides.
    $known = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($map in @($remote.Sessions, $basis.Sessions)) {
        foreach ($key in $map.Keys) { [void]$known.Add($key) }
    }
    foreach ($id in $known) {
        if ($handled.Contains($id)) { continue }
        $remoteEntry = if ($remote.Sessions.ContainsKey($id)) { $remote.Sessions[$id] } else { $null }
        if ($remote.Deleted.ContainsKey($id)) { continue }

        $knownEntry = if ($remoteEntry) { $remoteEntry } else { $basis.Sessions[$id] }
        $lineage = @($knownEntry.Lineage | ForEach-Object { [string]$_ })
        $coverage = Test-TombstoneCoverage $lineage $tombstones
        if ($coverage -ne 'None') {
            if ($coverage -ne 'Deleted') {
                $script:surveyRequired = $true
                throw "Session $id carries some but not all of its required tombstones. The deletion signal cannot be interpreted."
            }
            Assert-ConsistentTombstoneTimes $store $lineage
            if ($remoteEntry -and $basis.Sessions.ContainsKey($id) -and $remoteEntry.TreeId -ne $basis.Sessions[$id].TreeId) {
                $conflicts.Add("$id was deleted on this PC and changed on the remote since the accepted basis.")
                continue
            }
            # No payload, no title, no attachment, no MCP configuration. The
            # record exists so a stale PC cannot upload this session as new.
            $deletedRecord = [ordered]@{
                schemaVersion  = 1
                vaultSessionId = $id
                lineageIds     = $lineage
                deletedAt      = (Get-TombstoneTime $store ([string]$lineage[-1]))
                source         = 'verified-app-delete'
            }
            $deletedRecords[$id] = ConvertTo-AsciiJson $deletedRecord 6
            continue
        }

        if ($remoteEntry) {
            $publish[$id] = [pscustomobject]@{ Session = $null; Tier = $remoteEntry.Tier; TreeId = $remoteEntry.TreeId }
        }
        elseif ($basis.Sessions.ContainsKey($id)) {
            $conflicts.Add("$id existed in this PC's accepted basis but is absent from every remote state without a Deleted record, while this PC has no app record or complete deletion signal.")
        }
    }

    if ($conflicts.Count -ne 0) {
        throw ('Session conflict. Neither version was modified or published: ' + ($conflicts.ToArray() -join ' ') +
            " Resolve the conflict, then run Finish again. basis=$BaselineCommit remote=$RemoteCommit")
    }

    $prepared = New-IndexPath 'prepared'
    foreach ($pair in $publish.GetEnumerator()) {
        $entry = $pair.Value
        if ($null -ne $entry.Session) { Add-SessionToIndex $prepared $entry.Session $entry.Tier }
        else { Copy-SubtreeIntoIndex $prepared $entry.TreeId ($entry.Tier + '/' + $pair.Key) }
    }
    foreach ($pair in $remote.Deleted.GetEnumerator()) {
        if ($deletedRecords.ContainsKey($pair.Key)) { continue }
        [void](Invoke-GitCommand @('update-index', '--add', '--cacheinfo', "100644,$($pair.Value.BlobId),Deleted/$($pair.Key).json") -IndexFile $prepared)
    }
    foreach ($pair in $deletedRecords.GetEnumerator()) {
        [void](Add-BlobFromText $prepared $pair.Value ('Deleted/' + $pair.Key + '.json'))
    }
    $preparedTree = Get-GitValue @('write-tree') -IndexFile $prepared

    # The accepted basis records what this PC actually holds after the work
    # above, never the published result. Sessions only the remote has are not
    # in it: this PC never received them, and claiming otherwise would make the
    # next run read them as locally removed.
    $basisIndex = New-IndexPath 'localbasis'
    foreach ($pair in $localBasis.GetEnumerator()) {
        Copy-SubtreeIntoIndex $basisIndex $pair.Value.TreeId ($pair.Value.Tier + '/' + $pair.Key)
    }
    $localBaseTree = Get-GitValue @('write-tree') -IndexFile $basisIndex

    $detail = "Stored sessions $($sessions.Count); published entries $($publish.Count); deleted records $($remote.Deleted.Count + $deletedRecords.Count); app-local changes 0."
    if ($notes.Count -ne 0) { $detail += ' ' + ($notes.ToArray() -join ' ') }
    Save-RunState $preparedTree $localBaseTree
    # The tree ids are returned, never written here: anything this function
    # writes to the output stream would be folded into the caller's DETAIL.
    return [pscustomobject]@{ Detail = $detail; PreparedTree = $preparedTree; LocalBaseTree = $localBaseTree }
}

function Invoke-Cancel {
    $state = Get-RunState
    if ($null -eq $state) { throw "No preparation state exists for run $RunId; rollback was not claimed." }
    if ([string](Get-JsonMember $state 'status') -notin @('checking', 'prepared')) { throw "Run $RunId is not cancellable." }
    if ([bool](Get-JsonMember $state 'appWrites')) { throw "Run $RunId claims app-local writes that this Claude Finish version never performs; scratch was retained for review." }
    if (Test-Path -LiteralPath $script:runRoot -PathType Container) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force }
    return "Verified that run $RunId made no Claude app-local writes and released only this run's scratch."
}

function Invoke-Complete {
    if (-not $PublishedCommit) { throw 'Complete requires the verified published commit.' }
    $state = Get-RunState
    if ($null -eq $state) { throw "No preparation from run $RunId exists; there is nothing to complete." }
    if ([string](Get-JsonMember $state 'status') -ne 'prepared') { throw "Run $RunId did not finish Prepare; there is nothing to complete." }
    if ([string]$state.remoteCommit -ne $RemoteCommit) {
        throw "This run prepared against remote $($state.remoteCommit), but Complete was called with $RemoteCommit."
    }
    # This app performs no app-local writes, but its run scratch is still bound
    # to the exact tree it prepared. A non-empty commit string is not evidence.
    $publishedTree = Get-SubtreeId $PublishedCommit 'Claude'
    if (-not $publishedTree) { throw "Published commit $PublishedCommit has no Claude tree." }
    if ($publishedTree -ne [string]$state.preparedTree) {
        throw "Published commit $PublishedCommit carries Claude tree $publishedTree, not this run's prepared tree $($state.preparedTree). This run's scratch was retained."
    }
    # Publication is confirmed and the app changes were already made in Prepare.
    # Nothing here touches app data or recomputes a basis.
    if (Test-Path -LiteralPath $script:runRoot -PathType Container) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force }
    return "Verified $PublishedCommit carries this run's Claude tree, then released this run's scratch."
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration is missing. Run Initialize-AgentSessionSync.ps1 first: $configPath"
    }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $gitRoot = Split-Path (Split-Path $git -Parent) -Parent
    foreach ($candidate in @((Join-Path $gitRoot 'usr\bin\gzip.exe'), (Join-Path $gitRoot 'mingw64\bin\gzip.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $gzipTool = $candidate; break }
    }
    $gitDirectory = Get-GitValue @('rev-parse', '--absolute-git-dir')
    $runsRoot = Join-Path $gitDirectory 'agent-session-sync\ClaudeFinish'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) { [IO.Directory]::CreateDirectory($runsRoot) | Out-Null }
    $runRoot = Join-Path $runsRoot $RunId
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    }

    switch ($Operation) {
        'Prepare' {
            if (-not $RemoteCommit) { throw 'Prepare requires the remote commit to compare against.' }
            $result = Invoke-Prepare $config
            Write-ContractResult 'Success' 'Claude sessions prepared' $result.Detail
            Write-Output "PREPARED_TREE: $($result.PreparedTree)"
            Write-Output "LOCAL_BASE_TREE: $($result.LocalBaseTree)"
        }
        'Cancel' { Write-ContractResult 'Success' 'Claude preparation rolled back' (Invoke-Cancel) }
        'Complete' { Write-ContractResult 'Success' 'Claude local completion finished' (Invoke-Complete) }
    }
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($notes.Count -ne 0) { $message += ' ' + ($notes.ToArray() -join ' ') }
    Write-ContractResult 'Failure' "Claude Finish $Operation failed" $message
    exit 1
}
