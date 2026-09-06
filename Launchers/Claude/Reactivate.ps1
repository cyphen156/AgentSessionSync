#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string] $Query = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
$script:repo = ''
$script:git = ''
$script:safeRepo = ''
$script:publishedCommit = 'NONE'
$script:surveyRequired = $false
$script:runRoot = ''
$script:utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:recordRequiredFields = @(
    'alwaysAllowedReasons', 'classifierSummaryEnabled', 'cliSessionId',
    'completedTurns', 'createdAt', 'cwd', 'effort', 'enabledMcpTools',
    'isArchived', 'lastActivityAt', 'lastFocusedAt', 'lastSpawnRootDetected',
    'model', 'originCwd', 'permissionMode', 'remoteMcpServersConfig',
    'sessionId', 'sessionPermissionUpdates', 'spawnSeed'
)

function Report {
    param([string] $Result, [string] $Reason, [string] $Detail)
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: Claude'
    Write-Output 'PHASE: Reactivate'
    Write-Output ('REASON: ' + ($Reason -replace '[\r\n]+', ' '))
    Write-Output ('DETAIL: ' + ($Detail -replace '[\r\n]+', ' '))
    Write-Output "PUBLISHED_COMMIT: $script:publishedCommit"
    Write-Output "SURVEY_REQUIRED: $script:surveyRequired"
}

function Quote-NativeArgument {
    param([string] $Value)
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Git {
    param([string[]] $Arguments, [switch] $AllowFailure, [string] $InputText, [string] $OutputFile)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:git
    $info.Arguments = ((@('-c', "safe.directory=$script:safeRepo", '-c', 'core.quotePath=true', '-C', $script:repo) + $Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutTask = $null
        $output = $null
        if ($OutputFile) {
            $output = [IO.File]::Create($OutputFile)
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
        }
        else { $stdoutTask = $process.StandardOutput.ReadToEndAsync() }
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $bytes = $script:utf8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        $process.WaitForExit()
        if ($OutputFile) { $copyTask.GetAwaiter().GetResult(); $output.Dispose(); $output = $null; $stdout = '' }
        else { $stdout = $stdoutTask.GetAwaiter().GetResult() }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $code = $process.ExitCode
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        $process.Dispose()
    }
    if (-not $AllowFailure -and $code -ne 0) { throw "Git failed ($code): $($Arguments -join ' '): $stderr" }
    return [pscustomobject]@{ ExitCode = $code; Output = $stdout.TrimEnd("`r", "`n"); Error = $stderr }
}

function Git-Value {
    param([string[]] $Arguments)
    $result = Git $Arguments
    $lines = @($result.Output -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($lines.Count -ne 1) { throw "Expected one Git value: $($Arguments -join ' ')" }
    return ([string]$lines[0]).Trim()
}

function Require-Object {
    param([string] $Id, [string] $Type)
    if ($Id -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { throw "Invalid $Type object id: $Id" }
    if ((Git-Value @('cat-file', '-t', $Id)) -ne $Type) { throw "Object is not a ${Type}: $Id" }
}

function Get-Entries {
    param([string] $Tree)
    $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if (-not $Tree) { return ,$entries }
    Require-Object $Tree 'tree'
    $result = Git @('ls-tree', '-z', $Tree)
    foreach ($record in @($result.Output -split "`0")) {
        if (-not $record) { continue }
        if ($record -notmatch '^(\d{6} (?:blob|tree|commit) [0-9a-f]+)\t(.+)$') { throw "Unreadable tree entry: $record" }
        $entries[$Matches[2]] = $Matches[1]
    }
    return ,$entries
}

function Write-Entries {
    param($Entries)
    $lines = @($Entries.Keys | Sort-Object -CaseSensitive | ForEach-Object { $Entries[$_] + "`t" + $_ })
    $treeText = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
    return (Git @('mktree') -InputText $treeText).Output.Trim()
}

function Entry-Object {
    param([string] $Entry, [string] $ExpectedType)
    if ($Entry -notmatch "^\d{6} $ExpectedType ([0-9a-f]{40}([0-9a-f]{24})?)$") { throw "Expected a $ExpectedType tree entry." }
    return $Matches[1]
}

function Get-CommitTree {
    param([string] $Commit)
    Require-Object $Commit 'commit'
    return Git-Value @('rev-parse', "$Commit^{tree}")
}

function Get-RemoteHead {
    return Git-Value @('rev-parse', '--verify', 'refs/remotes/origin/main^{commit}')
}

function Fetch-Remote {
    [void](Git @('fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main'))
    return Get-RemoteHead
}

function Is-Ancestor {
    param([string] $Ancestor, [string] $Descendant)
    $result = Git @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure
    if ($result.ExitCode -gt 1) { throw "Cannot verify commit ancestry: $($result.Error)" }
    return ($result.ExitCode -eq 0)
}

function Read-JsonBlob {
    param([string] $Blob)
    Require-Object $Blob 'blob'
    $path = Join-Path $script:runRoot ([guid]::NewGuid().ToString('N') + '.json')
    try {
        [void](Git @('cat-file', 'blob', $Blob) -OutputFile $path)
        $text = [IO.File]::ReadAllText($path, $script:utf8)
        return $text | ConvertFrom-Json
    }
    catch { $script:surveyRequired = $true; throw "Stored JSON is not readable: $Blob" }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Has-Field {
    param($Object, [string] $Name)
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Is-Uuid {
    param([string] $Value)
    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
}

function Field {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    return $Object.PSObject.Properties[$Name].Value
}

function Hash-File {
    param([string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Safe-RelativePath {
    param([string] $Value)
    if (-not $Value -or $Value -match '(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])') { throw "Unsafe stored payload path: $Value" }
    return $Value
}

function Get-RecursiveEntries {
    param([string] $Tree)
    $result = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $listing = (Git @('ls-tree', '-r', '-z', $Tree)).Output
    foreach ($record in @($listing -split "`0")) {
        if (-not $record) { continue }
        if ($record -notmatch '^100644 blob ([0-9a-f]+)\t(.+)$') { throw "Unexpected stored session entry: $record" }
        $result[$Matches[2]] = $Matches[1]
    }
    return ,$result
}

function Test-TranscriptFile {
    param([string] $Path, [string] $ExpectedId)
    $lineNumber = 0
    $reader = New-Object IO.StreamReader($Path, $script:utf8, $false)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($line -eq '') { continue }
            if ($line -notmatch '"sessionId"\s*:\s*"([^"]+)"' -or $Matches[1] -ne $ExpectedId) {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber does not claim expected session $ExpectedId."
            }
            if ($line -notmatch '"type"\s*:\s*"') {
                $script:surveyRequired = $true
                throw "Transcript line $lineNumber has no type: $ExpectedId"
            }
        }
    }
    finally { $reader.Dispose() }
    if ($lineNumber -eq 0) { $script:surveyRequired = $true; throw "Transcript is empty: $ExpectedId" }
}

function Export-Blob {
    param([string] $Blob, [string] $Path)
    Require-Object $Blob 'blob'
    [void](Git @('cat-file', 'blob', $Blob) -OutputFile $Path)
}

function Validate-ArchivedSession {
    param([string] $VaultId, [string] $Tree)
    if (-not (Is-Uuid $VaultId)) { $script:surveyRequired = $true; throw "Archived Claude Vault id is invalid: $VaultId" }
    $top = Get-Entries $Tree
    $topNames = @($top.Keys | Sort-Object)
    if (($topNames -join ',') -ne 'manifest.json,record,transcripts') {
        $script:surveyRequired = $true
        throw "Archived Claude session $VaultId has unknown or missing top-level entries: $($topNames -join ', ')."
    }

    $manifest = Read-JsonBlob (Entry-Object $top['manifest.json'] 'blob')
    $manifestFields = @($manifest.PSObject.Properties.Name | Sort-Object)
    if (($manifestFields -join ',') -ne 'currentCliSessionId,display,priorCliSessionIds,schemaVersion,vaultSessionId' -or
        [int](Field $manifest 'schemaVersion') -ne 2 -or [string](Field $manifest 'vaultSessionId') -ne $VaultId) {
        $script:surveyRequired = $true
        throw "Archived Claude manifest has an unknown identity or schema: $VaultId"
    }
    $current = [string](Field $manifest 'currentCliSessionId')
    $prior = @((Field $manifest 'priorCliSessionIds' @()) | ForEach-Object { [string]$_ })
    $lineage = @($prior + @($current))
    $lineageSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $lineage) {
        if (-not (Is-Uuid $id) -or -not $lineageSet.Add($id)) {
            $script:surveyRequired = $true
            throw "Archived Claude lineage contains an invalid or duplicate identifier: $VaultId"
        }
    }

    $recordTree = Entry-Object $top['record'] 'tree'
    $recordEntries = Get-Entries $recordTree
    if ($recordEntries.Count -ne 1) { $script:surveyRequired = $true; throw "Archived Claude session $VaultId must carry exactly one app record." }
    $recordName = [string]@($recordEntries.Keys)[0]
    if ($recordName -notmatch '^local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})\.json$') {
        $script:surveyRequired = $true
        throw "Archived Claude app record has an unknown name: $recordName"
    }
    $record = Read-JsonBlob (Entry-Object $recordEntries[$recordName] 'blob')
    foreach ($fieldName in $script:recordRequiredFields) {
        if (-not (Has-Field $record $fieldName)) { $script:surveyRequired = $true; throw "Archived Claude app record is missing '$fieldName': $recordName" }
    }
    if ([string](Field $record 'sessionId') -ne [IO.Path]::GetFileNameWithoutExtension($recordName) -or [bool](Field $record 'isArchived')) {
        $script:surveyRequired = $true
        throw "Archived Claude app record identity or isArchived shape is unknown: $recordName"
    }
    $recordPrior = @()
    if (Has-Field $record 'priorCliSessionIds') { $recordPrior = @((Field $record 'priorCliSessionIds') | ForEach-Object { [string]$_ }) }
    $recordLineage = @($recordPrior + @([string](Field $record 'cliSessionId')))
    if (($recordLineage -join ',') -ne ($lineage -join ',')) {
        $script:surveyRequired = $true
        throw "Archived Claude app record does not describe the manifest lineage: $VaultId"
    }

    $transcriptTree = Entry-Object $top['transcripts'] 'tree'
    $transcriptEntries = Get-Entries $transcriptTree
    $allowed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $lineage) {
        $rawName = $id + '.jsonl'
        $gzipName = $rawName + '.gz'
        $integrityName = $gzipName + '.integrity.json'
        $hasRaw = $transcriptEntries.ContainsKey($rawName)
        $hasGzip = $transcriptEntries.ContainsKey($gzipName)
        if ($hasRaw -eq $hasGzip) {
            $script:surveyRequired = $true
            throw "Archived Claude session $VaultId must carry exactly one raw or gzip payload for $id."
        }
        $rawPath = Join-Path $script:runRoot ([guid]::NewGuid().ToString('N') + '.jsonl')
        $gzipPath = $rawPath + '.gz'
        try {
            if ($hasRaw) {
                [void]$allowed.Add($rawName)
                Export-Blob (Entry-Object $transcriptEntries[$rawName] 'blob') $rawPath
            }
            else {
                if (-not $transcriptEntries.ContainsKey($integrityName)) { $script:surveyRequired = $true; throw "Archived Claude gzip payload has no integrity record: $VaultId/$gzipName" }
                [void]$allowed.Add($gzipName); [void]$allowed.Add($integrityName)
                Export-Blob (Entry-Object $transcriptEntries[$gzipName] 'blob') $gzipPath
                $integrity = Read-JsonBlob (Entry-Object $transcriptEntries[$integrityName] 'blob')
                $integrityFields = @($integrity.PSObject.Properties.Name | Sort-Object)
                if (($integrityFields -join ',') -ne 'gzipLength,gzipSha256,rawLength,rawSha256' -or
                    [string](Field $integrity 'gzipSha256') -notmatch '^[0-9a-f]{64}$' -or
                    [string](Field $integrity 'rawSha256') -notmatch '^[0-9a-f]{64}$' -or
                    (Get-Item -LiteralPath $gzipPath).Length -ne [long](Field $integrity 'gzipLength') -or
                    (Hash-File $gzipPath) -ne [string](Field $integrity 'gzipSha256')) {
                    $script:surveyRequired = $true
                    throw "Archived Claude gzip integrity is invalid: $VaultId/$gzipName"
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
                if ((Get-Item -LiteralPath $rawPath).Length -ne [long](Field $integrity 'rawLength') -or
                    (Hash-File $rawPath) -ne [string](Field $integrity 'rawSha256')) {
                    $script:surveyRequired = $true
                    throw "Archived Claude restored payload is invalid: $VaultId/$gzipName"
                }
            }
            Test-TranscriptFile $rawPath $id
        }
        finally {
            Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $gzipPath -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($name in $transcriptEntries.Keys) {
        if (-not $allowed.Contains($name)) { $script:surveyRequired = $true; throw "Archived Claude session has unexplained transcript data: $VaultId/$name" }
    }

    $display = Field $manifest 'display'
    $displayFields = @($display.PSObject.Properties.Name | Sort-Object)
    if (($displayFields -join ',') -ne 'completedTurns,createdAt,lastActivityAt,title,titleSource') {
        $script:surveyRequired = $true
        throw "Archived Claude display sidecar has an unknown shape: $VaultId"
    }
    return [pscustomobject]@{
        VaultId = $VaultId
        CanonicalId = $current
        Tree = $Tree
        Manifest = $manifest
        Title = [string](Field $display 'title' '')
        Project = [string](Field $record 'cwd' '')
        LastActivity = [string](Field $display 'lastActivityAt' '')
    }
}
function Get-ClaudeTrees {
    param([string] $Commit)
    $root = Get-Entries (Get-CommitTree $Commit)
    if (-not $root.ContainsKey('Claude')) { throw "Commit $Commit has no Claude tree." }
    $claude = Get-Entries (Entry-Object $root['Claude'] 'tree')
    $active = if ($claude.ContainsKey('Active')) { Get-Entries (Entry-Object $claude['Active'] 'tree') } else { Get-Entries '' }
    $archived = if ($claude.ContainsKey('Archived')) { Get-Entries (Entry-Object $claude['Archived'] 'tree') } else { Get-Entries '' }
    $deleted = if ($claude.ContainsKey('Deleted')) { Get-Entries (Entry-Object $claude['Deleted'] 'tree') } else { Get-Entries '' }
    return [pscustomobject]@{ Root = $root; Claude = $claude; Active = $active; Archived = $archived; Deleted = $deleted }
}

function Read-ArchivedSummary {
    param([string] $VaultId, [string] $Tree)
    $entries = Get-Entries $Tree
    $entryNames = @($entries.Keys | Sort-Object)
    if (($entryNames -join ',') -ne 'manifest.json,record,transcripts') {
        $script:surveyRequired = $true
        throw "Archived Claude session $VaultId has unknown or missing top-level entries: $($entryNames -join ', ')."
    }
    $manifestBlob = Entry-Object $entries['manifest.json'] 'blob'
    $manifest = Read-JsonBlob $manifestBlob
    $manifestFields = @($manifest.PSObject.Properties.Name | Sort-Object)
    if (($manifestFields -join ',') -ne 'currentCliSessionId,display,priorCliSessionIds,schemaVersion,vaultSessionId' -or
        [int](Field $manifest 'schemaVersion') -ne 2 -or [string](Field $manifest 'vaultSessionId') -ne $VaultId) {
        $script:surveyRequired = $true
        throw "Archived Claude manifest has an unknown identity or schema: $VaultId"
    }
    $current = [string](Field $manifest 'currentCliSessionId')
    if (-not (Is-Uuid $VaultId) -or -not (Is-Uuid $current)) {
        $script:surveyRequired = $true
        throw "Archived Claude session or current lineage id is invalid: $VaultId"
    }
    $display = Field $manifest 'display'
    $displayFields = @($display.PSObject.Properties.Name | Sort-Object)
    if (($displayFields -join ',') -ne 'completedTurns,createdAt,lastActivityAt,title,titleSource') {
        $script:surveyRequired = $true
        throw "Archived Claude display sidecar has an unknown shape: $VaultId"
    }
    $recordTree = Entry-Object $entries['record'] 'tree'
    $recordEntries = Get-Entries $recordTree
    if ($recordEntries.Count -ne 1) {
        $script:surveyRequired = $true
        throw "Archived Claude session $VaultId must carry exactly one app record."
    }
    $recordName = [string]@($recordEntries.Keys)[0]
    if ($recordName -notmatch '^local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})\.json$') {
        $script:surveyRequired = $true
        throw "Archived Claude app record has an unknown name: $recordName"
    }
    $record = Read-JsonBlob (Entry-Object $recordEntries[$recordName] 'blob')
    if (-not (Has-Field $record 'cwd')) {
        $script:surveyRequired = $true
        throw "Archived Claude app record has no cwd: $recordName"
    }
    return [pscustomobject]@{
        VaultId = $VaultId
        CanonicalId = $current
        Tree = $Tree
        Title = [string](Field $display 'title' '')
        Project = [string](Field $record 'cwd' '')
        LastActivity = [string](Field $display 'lastActivityAt' '')
    }
}

function Find-Candidates {
    param([string] $Commit, [string] $Search)
    $trees = Get-ClaudeTrees $Commit
    $items = New-Object 'Collections.Generic.List[object]'
    foreach ($id in @($trees.Archived.Keys | Sort-Object)) {
        $tree = Entry-Object $trees.Archived[$id] 'tree'
        $candidate = Read-ArchivedSummary $id $tree
        if (-not $Search -or $candidate.VaultId.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $candidate.CanonicalId.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $candidate.Title.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $candidate.Project.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $items.Add($candidate) }
    }
    return $items.ToArray()
}

function Join-NonAppTrees {
    param([string] $Base, [string] $Local, [string] $Remote, [string] $Prefix = '')
    $b = Get-Entries $Base; $l = Get-Entries $Local; $r = Get-Entries $Remote
    $out = Get-Entries ''
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($map in @($b, $l, $r)) { foreach ($key in $map.Keys) { [void]$keys.Add($key) } }
    foreach ($key in $keys) {
        $bv = if ($b.ContainsKey($key)) { $b[$key] } else { '' }
        $lv = if ($l.ContainsKey($key)) { $l[$key] } else { '' }
        $rv = if ($r.ContainsKey($key)) { $r[$key] } else { '' }
        if (-not $Prefix -and $key -eq 'ACTIVE_HOST.txt') {
            if ($rv) { $out[$key] = $rv }
            continue
        }
        if (-not $Prefix -and $key -in @('Codex', 'Claude')) {
            if ($lv -ceq $rv -or $lv -ceq $bv) {
                if ($rv) { $out[$key] = $rv }
                continue
            }
            throw "Local $key Vault data differs from the pinned remote. Reactivate cannot judge or publish those unrelated app changes."
        }
        if ($lv -ceq $bv) { $chosen = $rv }
        elseif ($rv -ceq $bv -or $lv -ceq $rv) { $chosen = $lv }
        elseif (($bv -eq '' -or $bv.StartsWith('040000 tree ')) -and $lv.StartsWith('040000 tree ') -and $rv.StartsWith('040000 tree ')) {
            $baseTree = if ($bv) { ($bv -split ' ')[2] } else { '' }
            $child = Join-NonAppTrees $baseTree (($lv -split ' ')[2]) (($rv -split ' ')[2]) ($Prefix + $key + '/')
            $chosen = '040000 tree ' + $child
        }
        else { throw "Git file conflict outside session data: $Prefix$key. Neither version was overwritten." }
        if ($chosen) { $out[$key] = $chosen }
    }
    return Write-Entries $out
}

function Build-ReactivatedClaudeTree {
    param($Trees, $Selected)
    if ($Trees.Active.ContainsKey($Selected.VaultId)) { throw "Session already exists in Active: $($Selected.VaultId)" }
    if (-not $Trees.Archived.ContainsKey($Selected.VaultId)) { throw "Session is no longer Archived: $($Selected.VaultId)" }
    [void]$Trees.Archived.Remove($Selected.VaultId)
    $Trees.Active[$Selected.VaultId] = '040000 tree ' + $Selected.Tree
    $Trees.Claude['Active'] = '040000 tree ' + (Write-Entries $Trees.Active)
    $Trees.Claude['Archived'] = '040000 tree ' + (Write-Entries $Trees.Archived)
    return Write-Entries $Trees.Claude
}

function Build-Candidate {
    param([string] $OriginalHead, [string] $Remote, $Selected)
    $remoteTrees = Get-ClaudeTrees $Remote
    if (-not $remoteTrees.Archived.ContainsKey($Selected.VaultId)) { throw "Selected session is no longer Archived on the remote: $($Selected.VaultId)" }
    $currentTree = Entry-Object $remoteTrees.Archived[$Selected.VaultId] 'tree'
    if ($currentTree -ne $Selected.Tree) { throw "Selected Archived session changed after selection: $($Selected.VaultId)" }
    $claudeTree = Build-ReactivatedClaudeTree $remoteTrees $Selected
    $remoteRootTree = Get-CommitTree $Remote
    $localRootTree = Get-CommitTree $OriginalHead
    $baseResult = Git @('merge-base', $OriginalHead, $Remote) -AllowFailure
    if ($baseResult.ExitCode -gt 1) { throw 'Cannot read the common Git ancestor.' }
    $baseTree = if ($baseResult.Output) { Get-CommitTree $baseResult.Output.Trim() } else { '' }
    $root = Get-Entries (Join-NonAppTrees $baseTree $localRootTree $remoteRootTree)
    $root['Claude'] = '040000 tree ' + $claudeTree
    $tree = Write-Entries $root
    $arguments = @('commit-tree', $tree, '-p', $Remote)
    if (-not (Is-Ancestor $OriginalHead $Remote)) { $arguments += @('-p', $OriginalHead) }
    return Git-Value ($arguments + @('-m', "sessions: reactivate Claude $($Selected.VaultId)"))
}

function Is-NonFastForward {
    param($Push)
    $text = $Push.Output + "`n" + $Push.Error
    return ($text -match '(?i)(\[rejected\].*(fetch first|non-fast-forward|stale info)|cannot lock ref.*is at.*but expected)')
}

function Publish-Reactivation {
    param([string] $OriginalHead, $Selected)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $remote = Fetch-Remote
        $trees = Get-ClaudeTrees $remote
        if ($trees.Active.ContainsKey($Selected.VaultId)) {
            $activeTree = Entry-Object $trees.Active[$Selected.VaultId] 'tree'
            if ($activeTree -ne $Selected.Tree) { throw "The remote already has a different Active session at $($Selected.VaultId)." }
            return $remote
        }
        if ($trees.Deleted.ContainsKey($Selected.VaultId + '.json')) { throw "Deleted session restoration is not supported: $($Selected.VaultId)" }
        $candidate = Build-Candidate $OriginalHead $remote $Selected
        $push = Git @('push', '--porcelain', 'origin', ($candidate + ':refs/heads/main')) -AllowFailure
        $observed = Fetch-Remote
        if (Is-Ancestor $candidate $observed) { return $candidate }
        if ($push.ExitCode -eq 0) { throw "Push reported success but the reactivation commit could not be verified. Candidate: $candidate" }
        if (-not (Is-NonFastForward $push)) { throw "Reactivate push failed: $($push.Error)" }
    }
    throw 'Three Reactivate publication attempts were rejected.'
}

function Get-Baseline {
    $result = Git @('rev-parse', '--verify', '--quiet', 'refs/agent-session-sync/local-base^{commit}') -AllowFailure
    if ($result.ExitCode -eq 1) { return '' }
    if ($result.ExitCode -ne 0) { throw 'Cannot read the local comparison basis.' }
    return $result.Output.Trim()
}

function Set-ClaudeBaseline {
    param([string] $Previous, [string] $ClaudeTree)
    Require-Object $ClaudeTree 'tree'
    $entries = if ($Previous) { Get-Entries (Get-CommitTree $Previous) } else { Get-Entries '' }
    $entries['Claude'] = '040000 tree ' + $ClaudeTree
    $tree = Write-Entries $entries
    $arguments = @('commit-tree', $tree)
    if ($Previous) { $arguments += @('-p', $Previous) }
    $next = Git-Value ($arguments + @('-m', 'local: accepted Claude Reactivate basis'))
    $old = if ($Previous) { $Previous } else { '0' * $next.Length }
    [void](Git @('update-ref', 'refs/agent-session-sync/local-base', $next, $old))
}

function Get-SystemProcessSnapshot {
    try { return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath } }) }
    catch { return @(Get-WmiObject Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath } }) }
}

function Get-ClaudeProcesses {
    param($App)
    $snapshot = @(Get-SystemProcessSnapshot)
    $names = @{}; foreach ($name in @($App.ProcessNames)) { $names[[string]$name] = $true }
    $ids = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($row in $snapshot) {
        $base = [IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
        if ($names.ContainsKey($base) -and [string]$row.ExecutablePath -match '(?i)\\WindowsApps\\') { [void]$ids.Add([int]$row.ProcessId) }
    }
    do {
        $added = $false
        foreach ($row in $snapshot) { if ($ids.Contains([int]$row.ParentProcessId) -and $ids.Add([int]$row.ProcessId)) { $added = $true } }
    } while ($added)
    return @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Sort-Object Id -Unique)
}

function Initialize-WindowApi {
    if ('AgentSessionSync.ReactivateNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace AgentSessionSync {
    public static class ReactivateNative {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        public static IntPtr[] GetTopLevelWindows(int[] processIds) {
            var ids = new HashSet<int>(processIds); var result = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr state) { uint id; GetWindowThreadProcessId(hWnd, out id); if (ids.Contains((int)id)) result.Add(hWnd); return true; }, IntPtr.Zero);
            return result.ToArray();
        }
    }
}
'@
}

function Stop-ClaudeGracefully {
    param($App, [int] $TimeoutSeconds)
    $processes = @(Get-ClaudeProcesses $App)
    if ($processes.Count -eq 0) { return }
    Initialize-WindowApi
    $posted = New-Object 'Collections.Generic.HashSet[long]'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $processes = @(Get-ClaudeProcesses $App)
        if ($processes.Count -eq 0) { return }
        $windows = @([AgentSessionSync.ReactivateNative]::GetTopLevelWindows([int[]]@($processes | ForEach-Object Id)))
        foreach ($window in $windows) { if ($posted.Add([long]$window)) { [void][AgentSessionSync.ReactivateNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (@(Get-ClaudeProcesses $App).Count) { throw "Claude did not close within $TimeoutSeconds seconds. Reactivate never force-terminates it." }
}

function Invoke-ClaudeStart {
    param([string] $Published, [string] $Baseline)
    $runId = [guid]::NewGuid().ToString('D')
    $scriptPath = Join-Path $script:repo 'Launchers\Claude\Start.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RunId', $runId, '-RemoteCommit', $Published)
    if ($Baseline) { $arguments += @('-BaselineCommit', $Baseline) }
    $fields = @{}
    & (Get-Process -Id $PID).Path @arguments | ForEach-Object {
        $line = [string]$_
        Write-Host "[Claude Start] $line"
        if ($line -match '^SURVEY_REQUIRED:\s*True\s*$') { $script:surveyRequired = $true }
        if ($line -match '^(RESULT|LOCAL_BASE_TREE):\s*(\S+)\s*$') {
            if ($fields.ContainsKey($Matches[1])) { $fields[$Matches[1]] = 'DUPLICATE' } else { $fields[$Matches[1]] = $Matches[2] }
        }
    }
    $code = $LASTEXITCODE
    if ($code -ne 0 -or $fields['RESULT'] -ne 'Success') { throw "Claude local application failed after publication (exit $code). The remote Active transition stands; run Start after resolving the reported issue." }
    $tree = [string]$fields['LOCAL_BASE_TREE']
    Require-Object $tree 'tree'
    return $tree
}

try {
    $script:repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\', '/')
    $script:safeRepo = $script:repo.Replace('\', '/')
    $script:git = (Get-Command git.exe -ErrorAction Stop).Source
    if ([IO.Path]::GetFullPath((Git-Value @('rev-parse', '--show-toplevel'))).TrimEnd('\', '/') -ne $script:repo) { throw 'Reactivate must run from this installation.' }
    $configPath = Join-Path $script:repo 'AgentSessionSync.config.psd1'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Configuration is missing. Run Initialize-AgentSessionSync.ps1 first.' }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    if (-not $config.ContainsKey('Claude') -or -not $config.Claude.Enabled) { throw 'Claude is not registered.' }
    if (-not $config.Claude.AppId -or @($config.Claude.ProcessNames).Count -eq 0) { throw 'Claude process registration is incomplete.' }
    if (-not $config.ContainsKey('GracefulCloseTimeoutSeconds') -or [int]$config.GracefulCloseTimeoutSeconds -lt 1) {
        throw 'GracefulCloseTimeoutSeconds must be at least 1.'
    }
    $status = (Git @('status', '--porcelain=v1', '--untracked-files=all')).Output
    if ($status) { throw 'The Vault worktree has uncommitted changes; Reactivate did not modify them.' }
    $gitDir = Git-Value @('rev-parse', '--absolute-git-dir')
    $script:runRoot = Join-Path $gitDir ('agent-session-sync\ClaudeReactivate\' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:runRoot) | Out-Null
    $remote = Fetch-Remote
    $candidates = @(Find-Candidates $remote $Query)
    if (-not $Query) {
        if ($candidates.Count) { $candidates | Select-Object VaultId,CanonicalId,Title,Project,LastActivity | Format-Table -AutoSize | Out-Host }
        Report 'Success' 'Archived Claude sessions listed' "Found $($candidates.Count). Run Reactivate.ps1 with an id, title or project fragment to select exactly one."
        exit 0
    }
    if ($candidates.Count -eq 0) { throw "No Archived Claude session matches '$Query'." }
    if ($candidates.Count -ne 1) {
        $candidates | Select-Object VaultId,CanonicalId,Title,Project,LastActivity | Format-Table -AutoSize | Out-Host
        throw "Reactivate query '$Query' matched $($candidates.Count) sessions; narrow the query."
    }
    $summary = $candidates[0]
    $selected = Validate-ArchivedSession $summary.VaultId $summary.Tree
    $originalHead = Git-Value @('rev-parse', 'HEAD^{commit}')
    $script:publishedCommit = Publish-Reactivation $originalHead $selected

    $app = [pscustomobject]@{ Name='Claude'; AppId=[string]$config.Claude.AppId; ProcessNames=@($config.Claude.ProcessNames | ForEach-Object { [string]$_ }) }
    try { Stop-ClaudeGracefully $app ([int]$config.GracefulCloseTimeoutSeconds) }
    catch { throw "Claude is Active in the published Vault at $script:publishedCommit, but local application was not attempted. $($_.Exception.Message) Close Claude and run Start." }
    Start-Sleep -Seconds 1
    $baseline = Get-Baseline
    $claudeBasis = Invoke-ClaudeStart $script:publishedCommit $baseline
    Set-ClaudeBaseline $baseline $claudeBasis
    [void](Git @('merge', '--ff-only', '--no-edit', $script:publishedCommit))
    Start-Process -WindowStyle Hidden -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppId)"
    Report 'Success' 'Archived Claude session reactivated' "$($selected.VaultId) moved to Active, was published, applied locally, and Claude was launched. Activity timestamps were not changed."
    exit 0
}
catch {
    Report 'Failure' 'Claude Reactivate failed' $_.Exception.Message
    exit 1
}
finally {
    if ($script:runRoot -and (Test-Path -LiteralPath $script:runRoot -PathType Container)) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
