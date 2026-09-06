#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string] $Query = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:repo = ''
$script:git = ''
$script:safeRepo = ''
$script:publishedCommit = 'NONE'
$script:surveyRequired = $false
$script:runRoot = ''
$script:utf8 = New-Object Text.UTF8Encoding($false, $true)

function Report {
    param([string] $Result, [string] $Reason, [string] $Detail)
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: Codex'
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
    try { return (Git @('cat-file', 'blob', $Blob)).Output | ConvertFrom-Json }
    catch { $script:surveyRequired = $true; throw "Stored JSON is not readable: $Blob" }
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

$script:transportRaw=@{}
$script:transportSources=@{}
function Transport-Git([string[]]$Arguments,[string]$InputFile=$null) {
    if($InputFile){return (Git $Arguments -InputText ([IO.File]::ReadAllText($InputFile))).Output};return (Git $Arguments).Output
}
function Transport-Json($Value) { return ConvertTo-Json -InputObject $Value -Depth 30 -Compress }
function Transport-Blob($Value) {
    $file=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.marker')
    try{[IO.File]::WriteAllText($file,(Transport-Json $Value),(New-Object Text.UTF8Encoding($false)));return Transport-Git @('hash-object','-w','--no-filters','--',$file)}finally{if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
}
function Transport-Tree($Entries) {
    $dirs=@{};$leaves=@{}
    foreach($path in $Entries.Keys){
        if(-not$path-or$path-match'(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Unsafe transport marker path: $path"}
        $pieces=$path-split'/',2
        if($pieces.Count-eq1){$leaves[$path]=$Entries[$path]}else{if(-not$dirs.ContainsKey($pieces[0])){$dirs[$pieces[0]]=@{}};$dirs[$pieces[0]][$pieces[1]]=$Entries[$path]}
    }
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($name in $leaves.Keys){$oid=[string]$leaves[$name];if($oid-cnotmatch'^[0-9a-f]{40,64}$'){throw 'Invalid transport blob ID.'};$lines.Add("100644 blob $oid`t$name`0")}
    foreach($name in $dirs.Keys){if($leaves.ContainsKey($name)){throw 'Transport path collision.'};$tree=Transport-Tree $dirs[$name];$lines.Add("040000 tree $tree`t$name`0")}
    $file=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.tree')
    try{[IO.File]::WriteAllText($file,($lines-join''),(New-Object Text.UTF8Encoding($false)));return Transport-Git @('mktree','-z') $file}finally{if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
}
function Get-TransportMarkerRef($Payload) {
    if([string]$Payload.sha256-cnotmatch'^[0-9a-f]{64}$'-or[long]$Payload.length-lt0){throw 'Invalid transport marker raw identity.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$pathKey=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$Payload.sha256+"`n"+$Payload.length+"`n"+$Payload.path)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return 'refs/agent-session-sync/codex-gzip-v1/'+$pathKey
}
function Get-TransportFiles($Entries,[string]$Prefix,$Payload) {
    $relative=[string]$Payload.transportPath;$files=@{}
    $names=New-Object 'Collections.Generic.List[string]';$names.Add($relative)
    if($relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){
        if(-not$Entries.ContainsKey($Prefix+$relative)){throw "Transport descriptor missing: $relative"}
        $meta=Read-JsonBlob $Entries[$Prefix+$relative]
        $parts=$meta.PSObject.Properties['parts'].Value
        if($parts-isnot[Array]-or$parts.Count-lt2){throw "Invalid split transport parts: $relative"}
        $baseName=$relative.Substring(0,$relative.Length-'.parts.json'.Length)
        if($Entries.ContainsKey($Prefix+$baseName)){throw 'Single and split transport coexist.'}
        for($i=0;$i-lt$parts.Count;$i++){
            $expected=$baseName+('.part{0:D6}'-f($i+1))
            if($parts[$i].path-cne$expected){throw "Invalid split transport order: $relative"}
            $names.Add($expected)
        }
        foreach($entry in $Entries.Keys){
            if($entry.StartsWith($Prefix+$baseName+'.part',[StringComparison]::Ordinal)-and$entry-cne$Prefix+$relative-and-not$names.Contains($entry.Substring($Prefix.Length))){throw "Unlisted split transport part: $entry"}
        }
    }elseif($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){$names.Add($relative+'.integrity.json')}else{throw 'A gzip marker cannot describe raw transport.'}
    foreach($name in $names){
        if(-not$name-or$name-match'(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Unsafe transport marker path: $name"}
        if(-not$Entries.ContainsKey($Prefix+$name)){throw "Transport part or integrity record missing: $Prefix$name"}
        $files[$name]=$Entries[$Prefix+$name]
    }
    return $files
}
function New-TransportMarkerTree($Entries,[string]$Prefix,$Payload) {
    $files=Get-TransportFiles $Entries $Prefix $Payload
    $marker=[ordered]@{schemaVersion=1;codec='gzip-split-v1';payload=[ordered]@{path=[string]$Payload.path;transportPath=[string]$Payload.transportPath;length=[long]$Payload.length;sha256=[string]$Payload.sha256}}
    $tree=@{'marker.json'=(Transport-Blob $marker)}
    foreach($path in $files.Keys){$tree['data/'+$path]=$files[$path]}
    return Transport-Tree $tree
}
function Test-TransportMarker($Entries,[string]$Prefix,$Payload) {
    $ref=Get-TransportMarkerRef $Payload
    $stored=Transport-Git @('for-each-ref','--format=%(objectname)',$ref)
    if(-not$stored){return $false}
    return $stored-ceq(New-TransportMarkerTree $Entries $Prefix $Payload)
}
function Save-TransportMarker($Entries,[string]$Prefix,$Payload,[string]$RawPath='') {
    # A local marker binds the verified raw identity AND every transport blob.
    # The ref keeps cached blobs reachable across Cancel/GC; it is never pushed.
    $ref=Get-TransportMarkerRef $Payload;$tree=New-TransportMarkerTree $Entries $Prefix $Payload
    [void](Transport-Git @('update-ref',$ref,$tree))
    if($RawPath){$script:transportRaw[$ref]=$RawPath}
}
function Get-CachedTransport($Payload,[long]$Ceiling,$Entries) {
    $ref=Get-TransportMarkerRef $Payload;$tree=Transport-Git @('for-each-ref','--format=%(objectname)',$ref)
    if(-not$tree){return $null}
    $cached=@{}
    foreach($line in (Transport-Git @('ls-tree','-r','-z',$tree)).Split([char]0)){
        if(-not$line){continue};if($line-cnotmatch'^100644 blob ([0-9a-f]+)\t(.+)$'){throw 'Invalid transport cache entry.'};$cached[$Matches[2]]=$Matches[1]
    }
    if(-not$cached.ContainsKey('marker.json')){return $null}
    $marker=Read-JsonBlob $cached['marker.json'];$p=$marker.payload
    if($marker.schemaVersion-ne1-or$marker.codec-cne'gzip-split-v1'-or$p.path-cne$Payload.path-or$p.sha256-cne$Payload.sha256-or[long]$p.length-ne[long]$Payload.length){return $null}
    $files=@{};foreach($name in $cached.Keys){if($name.StartsWith('data/')){$files[$name.Substring(5)]=$cached[$name]}}
    if(-not(Test-TransportMarker $files '' $p)){return $null}
    foreach($name in $files.Keys){if([long](Transport-Git @('cat-file','-s',$files[$name]))-gt$Ceiling){return $null}}
    foreach($name in $files.Keys){$Entries[$name]=$files[$name]}
    return [ordered]@{path=[string]$p.path;transportPath=[string]$p.transportPath;length=[long]$p.length;sha256=[string]$p.sha256}
}

function Expand-SplitGzip($Entries,[string]$Prefix,[string]$Relative,$Allowed=$null) {
    # Parts are bytes of ONE gzip stream, never separately recompressed.
    [void](Safe-RelativePath $Relative)
    $descriptorPath=$Prefix+$Relative
    if(-not$Relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)-or-not$Entries.ContainsKey($descriptorPath)){throw "Split gzip descriptor missing: $descriptorPath"}
    $meta=Read-JsonBlob $Entries[$descriptorPath]
    if((@($meta.PSObject.Properties.Name|Sort-Object)-join ',')-cne'encoding,gzipLength,gzipSha256,parts,partSize,rawLength,rawSha256,schemaVersion'-or$meta.schemaVersion-ne1-or$meta.encoding-cne'gzip'){throw "Unknown split gzip descriptor: $descriptorPath"}
    foreach($key in @('partSize','rawLength','gzipLength')){
        $v=$meta.PSObject.Properties[$key].Value
        if(($v-isnot[int]-and$v-isnot[long])-or$v-le0){throw "Invalid split gzip length: $descriptorPath/$key"}
    }
    if($meta.partSize-gt99614720){throw "Split part size exceeds transport ceiling: $descriptorPath"}
    foreach($key in @('rawSha256','gzipSha256')){if($meta.PSObject.Properties[$key].Value-isnot[string]-or$meta.PSObject.Properties[$key].Value-cnotmatch'^[0-9a-f]{64}$'){throw "Invalid split gzip hash: $descriptorPath/$key"}}
    $parts=$meta.PSObject.Properties['parts'].Value
    if($parts-isnot[Array]-or$parts.Count-lt2-or$parts.Count-ne[Math]::Ceiling([double]$meta.gzipLength/[long]$meta.partSize)){throw "Invalid split gzip part count: $descriptorPath"}
    $gzipName=$Relative.Substring(0,$Relative.Length-'.parts.json'.Length)
    if($Entries.ContainsKey($Prefix+$gzipName)){throw "Split and single gzip coexist: $descriptorPath"}
    $joined=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.joined.gz')
    $raw=$joined+'.raw';$sink=$null
    try {
        $sink=[IO.File]::Create($joined)
        for($i=0;$i-lt$parts.Count;$i++){
            $part=$parts[$i];$expected=$gzipName+('.part{0:D6}'-f($i+1))
            $expectedLength=[Math]::Min([long]$meta.partSize,[long]$meta.gzipLength-([long]$i*[long]$meta.partSize))
            if((@($part.PSObject.Properties.Name|Sort-Object)-join ',')-cne'length,path,sha256'-or$part.path-cne$expected-or($part.length-isnot[int]-and$part.length-isnot[long])-or$part.length-ne$expectedLength-or$part.sha256-isnot[string]-or$part.sha256-cnotmatch'^[0-9a-f]{64}$'){throw "Invalid split gzip part/order: $descriptorPath part $($i+1)"}
            $entryPath=$Prefix+$expected
            if(-not$Entries.ContainsKey($entryPath)){throw "Split gzip part missing: $entryPath"}
            if($null-ne$Allowed){[void]$Allowed.Add($entryPath)}
            $piece=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.piece')
            try {
                [void](Git @('cat-file','blob',$Entries[$entryPath]) -OutputFile $piece)
                if((Get-Item -LiteralPath $piece).Length-ne$expectedLength-or(Hash-File $piece)-cne$part.sha256){throw "Split gzip part integrity failure: $entryPath"}
                $stream=[IO.File]::OpenRead($piece)
                try{$stream.CopyTo($sink)}finally{$stream.Dispose()}
            }finally{if([IO.File]::Exists($piece)){[IO.File]::Delete($piece)}}
        }
        $sink.Dispose();$sink=$null
        if((Get-Item -LiteralPath $joined).Length-ne[long]$meta.gzipLength-or(Hash-File $joined)-cne$meta.gzipSha256){throw "Reassembled gzip integrity failure: $descriptorPath"}
        $stream=[IO.File]::OpenRead($joined);$destination=[IO.File]::Create($raw)
        try{$gzip=New-Object IO.Compression.GZipStream($stream,[IO.Compression.CompressionMode]::Decompress,$true);try{$gzip.CopyTo($destination)}finally{$gzip.Dispose()}}finally{$stream.Dispose();$destination.Dispose()}
        if((Get-Item -LiteralPath $raw).Length-ne[long]$meta.rawLength-or(Hash-File $raw)-cne$meta.rawSha256){throw "Split gzip raw integrity failure: $descriptorPath"}
        return $raw
    }catch{if([IO.File]::Exists($raw)){[IO.File]::Delete($raw)};throw}
    finally{if($null-ne$sink){$sink.Dispose()};if([IO.File]::Exists($joined)){[IO.File]::Delete($joined)}}
}

function Validate-ArchivedSession {
    param([string] $VaultId, [string] $Tree)
    $entries = Get-RecursiveEntries $Tree
    foreach ($required in @('manifest.json', 'projection.json')) {
        if (-not $entries.ContainsKey($required)) { $script:surveyRequired = $true; throw "Archived Codex session $VaultId is missing $required." }
    }
    $manifest = Read-JsonBlob $entries['manifest.json']
    if ((Field $manifest 'schemaVersion') -ne 1 -or [string](Field $manifest 'vaultSessionId') -ne $VaultId) {
        $script:surveyRequired = $true
        throw "Archived Codex manifest has an unknown identity or schema: $VaultId"
    }
    $canonical = [string](Field $manifest 'canonicalId')
    if ($canonical -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { $script:surveyRequired = $true; throw "Archived Codex canonical id is invalid: $VaultId" }
    $lineage = @((Field $manifest 'lineageIds' @()) | ForEach-Object { [string]$_ })
    if ($lineage.Count -eq 0 -or $lineage -notcontains $canonical) { $script:surveyRequired = $true; throw "Archived Codex lineage is incomplete: $VaultId" }
    $lineageSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $lineage) {
        if ($id -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or -not $lineageSet.Add($id)) {
            $script:surveyRequired = $true
            throw "Archived Codex lineage contains an invalid or duplicate identifier: $VaultId"
        }
    }
    [void](Read-JsonBlob $entries['projection.json'])
    $allowed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    [void]$allowed.Add('manifest.json'); [void]$allowed.Add('projection.json')
    foreach ($payload in @((Field $manifest 'payloads' @()))) {
        $logical = Safe-RelativePath ([string](Field $payload 'path'))
        $transport = Safe-RelativePath ([string](Field $payload 'transportPath'))
        if (-not $entries.ContainsKey($transport)) { throw "Archived Codex payload is missing: $VaultId/$transport" }
        [void]$allowed.Add($transport)
        $compressed=$transport.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)-or$transport.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)
        if($compressed){
            $transportFiles=Get-TransportFiles $entries '' $payload
            foreach($path in $transportFiles.Keys){[void]$allowed.Add($path)}
            if(Test-TransportMarker $entries '' $payload){continue}
        }
        if ($transport.EndsWith('.gz.parts.json', [StringComparison]::Ordinal)) {
            $raw = Expand-SplitGzip $entries '' $transport $allowed
            if ((Get-Item -LiteralPath $raw).Length -ne [long](Field $payload 'length') -or (Hash-File $raw) -ne [string](Field $payload 'sha256')) { throw "Archived split payload verification failed: $VaultId/$logical" }
            Save-TransportMarker $entries '' $payload
            [IO.File]::Delete($raw)
            continue
        }
        $stored = Join-Path $script:runRoot ([guid]::NewGuid().ToString('N') + '.transport')
        [void](Git @('cat-file', 'blob', $entries[$transport]) -OutputFile $stored)
        $raw = $stored
        if ($transport.EndsWith('.gz', [StringComparison]::OrdinalIgnoreCase)) {
            $integrityPath = $transport + '.integrity.json'
            if (-not $entries.ContainsKey($integrityPath)) { throw "Archived Codex gzip integrity record is missing: $VaultId/$integrityPath" }
            [void]$allowed.Add($integrityPath)
            $integrity = Read-JsonBlob $entries[$integrityPath]
            if ((Get-Item -LiteralPath $stored).Length -ne [long](Field $integrity 'gzipLength') -or (Hash-File $stored) -ne [string](Field $integrity 'gzipSha256')) { throw "Archived Codex gzip bytes are invalid: $VaultId/$transport" }
            $raw = $stored + '.raw'
            $compressedStream = [IO.File]::OpenRead($stored); $rawStream = [IO.File]::Create($raw)
            try {
                $gzip = New-Object IO.Compression.GZipStream($compressedStream, [IO.Compression.CompressionMode]::Decompress, $true)
                try { $gzip.CopyTo($rawStream) } finally { $gzip.Dispose() }
            }
            finally { $compressedStream.Dispose(); $rawStream.Dispose() }
            if ((Get-Item -LiteralPath $raw).Length -ne [long](Field $integrity 'rawLength') -or (Hash-File $raw) -ne [string](Field $integrity 'rawSha256')) { throw "Archived Codex restored bytes are invalid: $VaultId/$transport" }
        }
        if ((Get-Item -LiteralPath $raw).Length -ne [long](Field $payload 'length') -or (Hash-File $raw) -ne [string](Field $payload 'sha256')) { throw "Archived Codex payload verification failed: $VaultId/$logical" }
        if($compressed){Save-TransportMarker $entries '' $payload}
    }
    foreach ($path in $entries.Keys) {
        if (-not $allowed.Contains($path)) { $script:surveyRequired = $true; throw "Archived Codex session has unexplained linked data: $VaultId/$path" }
    }
    return [pscustomobject]@{
        VaultId = $VaultId
        CanonicalId = $canonical
        Tree = $Tree
        Manifest = $manifest
        Title = [string](Field (Field $manifest 'comparison') 'title' '')
        Project = [string](Field (Field (Field $manifest 'comparison') 'metadata') 'projectId' '')
        LastActivity = [string](Field $manifest 'lastActivityAt' '')
    }
}

function Get-CodexTrees {
    param([string] $Commit)
    $root = Get-Entries (Get-CommitTree $Commit)
    if (-not $root.ContainsKey('Codex')) { throw "Commit $Commit has no Codex tree." }
    $codex = Get-Entries (Entry-Object $root['Codex'] 'tree')
    $active = if ($codex.ContainsKey('Active')) { Get-Entries (Entry-Object $codex['Active'] 'tree') } else { Get-Entries '' }
    $archived = if ($codex.ContainsKey('Archived')) { Get-Entries (Entry-Object $codex['Archived'] 'tree') } else { Get-Entries '' }
    $deleted = if ($codex.ContainsKey('Deleted')) { Get-Entries (Entry-Object $codex['Deleted'] 'tree') } else { Get-Entries '' }
    return [pscustomobject]@{ Root = $root; Codex = $codex; Active = $active; Archived = $archived; Deleted = $deleted }
}

function Read-ArchivedSummary {
    param([string] $VaultId, [string] $Tree)
    $entries = Get-Entries $Tree
    if (-not $entries.ContainsKey('manifest.json')) {
        $script:surveyRequired = $true
        throw "Archived Codex session $VaultId is missing manifest.json."
    }
    $manifestBlob = Entry-Object $entries['manifest.json'] 'blob'
    $manifest = Read-JsonBlob $manifestBlob
    if ((Field $manifest 'schemaVersion') -ne 1 -or [string](Field $manifest 'vaultSessionId') -ne $VaultId) {
        $script:surveyRequired = $true
        throw "Archived Codex manifest has an unknown identity or schema: $VaultId"
    }
    $canonical = [string](Field $manifest 'canonicalId')
    if ($canonical -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        $script:surveyRequired = $true
        throw "Archived Codex canonical id is invalid: $VaultId"
    }
    return [pscustomobject]@{
        VaultId = $VaultId
        CanonicalId = $canonical
        Tree = $Tree
        Title = [string](Field (Field $manifest 'comparison') 'title' '')
        Project = [string](Field (Field (Field $manifest 'comparison') 'metadata') 'projectId' '')
        LastActivity = [string](Field $manifest 'lastActivityAt' '')
    }
}

function Find-Candidates {
    param([string] $Commit, [string] $Search)
    $trees = Get-CodexTrees $Commit
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

function Build-ReactivatedCodexTree {
    param($Trees, $Selected)
    if ($Trees.Active.ContainsKey($Selected.VaultId)) { throw "Session already exists in Active: $($Selected.VaultId)" }
    if (-not $Trees.Archived.ContainsKey($Selected.VaultId)) { throw "Session is no longer Archived: $($Selected.VaultId)" }
    [void]$Trees.Archived.Remove($Selected.VaultId)
    $Trees.Active[$Selected.VaultId] = '040000 tree ' + $Selected.Tree
    $Trees.Codex['Active'] = '040000 tree ' + (Write-Entries $Trees.Active)
    $Trees.Codex['Archived'] = '040000 tree ' + (Write-Entries $Trees.Archived)
    return Write-Entries $Trees.Codex
}

function Build-Candidate {
    param([string] $OriginalHead, [string] $Remote, $Selected)
    $remoteTrees = Get-CodexTrees $Remote
    if (-not $remoteTrees.Archived.ContainsKey($Selected.VaultId)) { throw "Selected session is no longer Archived on the remote: $($Selected.VaultId)" }
    $currentTree = Entry-Object $remoteTrees.Archived[$Selected.VaultId] 'tree'
    if ($currentTree -ne $Selected.Tree) { throw "Selected Archived session changed after selection: $($Selected.VaultId)" }
    $codexTree = Build-ReactivatedCodexTree $remoteTrees $Selected
    $remoteRootTree = Get-CommitTree $Remote
    $localRootTree = Get-CommitTree $OriginalHead
    $baseResult = Git @('merge-base', $OriginalHead, $Remote) -AllowFailure
    if ($baseResult.ExitCode -gt 1) { throw 'Cannot read the common Git ancestor.' }
    $baseTree = if ($baseResult.Output) { Get-CommitTree $baseResult.Output.Trim() } else { '' }
    $root = Get-Entries (Join-NonAppTrees $baseTree $localRootTree $remoteRootTree)
    $root['Codex'] = '040000 tree ' + $codexTree
    $tree = Write-Entries $root
    $arguments = @('commit-tree', $tree, '-p', $Remote)
    if (-not (Is-Ancestor $OriginalHead $Remote)) { $arguments += @('-p', $OriginalHead) }
    return Git-Value ($arguments + @('-m', "sessions: reactivate Codex $($Selected.VaultId)"))
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
        $trees = Get-CodexTrees $remote
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

function Set-CodexBaseline {
    param([string] $Previous, [string] $CodexTree)
    Require-Object $CodexTree 'tree'
    $entries = if ($Previous) { Get-Entries (Get-CommitTree $Previous) } else { Get-Entries '' }
    $entries['Codex'] = '040000 tree ' + $CodexTree
    $tree = Write-Entries $entries
    $arguments = @('commit-tree', $tree)
    if ($Previous) { $arguments += @('-p', $Previous) }
    $next = Git-Value ($arguments + @('-m', 'local: accepted Codex Reactivate basis'))
    $old = if ($Previous) { $Previous } else { '0' * $next.Length }
    [void](Git @('update-ref', 'refs/agent-session-sync/local-base', $next, $old))
}

function Get-SystemProcessSnapshot {
    try { return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath } }) }
    catch { return @(Get-WmiObject Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath } }) }
}

function Get-CodexProcesses {
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

function Stop-CodexGracefully {
    param($App, [int] $TimeoutSeconds)
    $processes = @(Get-CodexProcesses $App)
    if ($processes.Count -eq 0) { return }
    Initialize-WindowApi
    $posted = New-Object 'Collections.Generic.HashSet[long]'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $processes = @(Get-CodexProcesses $App)
        if ($processes.Count -eq 0) { return }
        $windows = @([AgentSessionSync.ReactivateNative]::GetTopLevelWindows([int[]]@($processes | ForEach-Object Id)))
        foreach ($window in $windows) { if ($posted.Add([long]$window)) { [void][AgentSessionSync.ReactivateNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (@(Get-CodexProcesses $App).Count) { throw "Codex did not close within $TimeoutSeconds seconds. Reactivate never force-terminates it." }
}

function Invoke-CodexStart {
    param([string] $Published, [string] $Baseline)
    $runId = [guid]::NewGuid().ToString('D')
    $scriptPath = Join-Path $script:repo 'Launchers\Codex\Start.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RunId', $runId, '-RemoteCommit', $Published)
    if ($Baseline) { $arguments += @('-BaselineCommit', $Baseline) }
    $fields = @{}
    & (Get-Process -Id $PID).Path @arguments | ForEach-Object {
        $line = [string]$_
        Write-Host "[Codex Start] $line"
        if ($line -match '^SURVEY_REQUIRED:\s*True\s*$') { $script:surveyRequired = $true }
        if ($line -match '^(RESULT|LOCAL_BASE_TREE):\s*(\S+)\s*$') {
            if ($fields.ContainsKey($Matches[1])) { $fields[$Matches[1]] = 'DUPLICATE' } else { $fields[$Matches[1]] = $Matches[2] }
        }
    }
    $code = $LASTEXITCODE
    if ($code -ne 0 -or $fields['RESULT'] -ne 'Success') { throw "Codex local application failed after publication (exit $code). The remote Active transition stands; run Start after resolving the reported issue." }
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
    if (-not $config.ContainsKey('Codex') -or -not $config.Codex.Enabled) { throw 'Codex is not registered.' }
    if (-not $config.Codex.AppId -or @($config.Codex.ProcessNames).Count -eq 0) { throw 'Codex process registration is incomplete.' }
    $status = (Git @('status', '--porcelain=v1', '--untracked-files=all')).Output
    if ($status) { throw 'The Vault worktree has uncommitted changes; Reactivate did not modify them.' }
    $gitDir = Git-Value @('rev-parse', '--absolute-git-dir')
    $script:runRoot = Join-Path $gitDir ('agent-session-sync\CodexReactivate\' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:runRoot) | Out-Null
    $remote = Fetch-Remote
    $candidates = @(Find-Candidates $remote $Query)
    if (-not $Query) {
        if ($candidates.Count) { $candidates | Select-Object VaultId,CanonicalId,Title,Project,LastActivity | Format-Table -AutoSize | Out-Host }
        Report 'Success' 'Archived Codex sessions listed' "Found $($candidates.Count). Run Reactivate.ps1 with an id, title or project fragment to select exactly one."
        exit 0
    }
    if ($candidates.Count -eq 0) { throw "No Archived Codex session matches '$Query'." }
    if ($candidates.Count -ne 1) {
        $candidates | Select-Object VaultId,CanonicalId,Title,Project,LastActivity | Format-Table -AutoSize | Out-Host
        throw "Reactivate query '$Query' matched $($candidates.Count) sessions; narrow the query."
    }
    $summary = $candidates[0]
    $selected = Validate-ArchivedSession $summary.VaultId $summary.Tree
    $originalHead = Git-Value @('rev-parse', 'HEAD^{commit}')
    $script:publishedCommit = Publish-Reactivation $originalHead $selected

    $app = [pscustomobject]@{ Name='Codex'; AppId=[string]$config.Codex.AppId; ProcessNames=@($config.Codex.ProcessNames | ForEach-Object { [string]$_ }) }
    try { Stop-CodexGracefully $app ([int]$config.GracefulCloseTimeoutSeconds) }
    catch { throw "Codex is Active in the published Vault at $script:publishedCommit, but local application was not attempted. $($_.Exception.Message) Close Codex and run Start." }
    Start-Sleep -Seconds 1
    $baseline = Get-Baseline
    $codexBasis = Invoke-CodexStart $script:publishedCommit $baseline
    Set-CodexBaseline $baseline $codexBasis
    [void](Git @('merge', '--ff-only', '--no-edit', $script:publishedCommit))
    Start-Process -WindowStyle Hidden -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppId)"
    Report 'Success' 'Archived Codex session reactivated' "$($selected.VaultId) moved to Active, was published, applied locally, and Codex was launched. Activity timestamps were not changed."
    exit 0
}
catch {
    Report 'Failure' 'Codex Reactivate failed' $_.Exception.Message
    exit 1
}
finally {
    if ($script:runRoot -and (Test-Path -LiteralPath $script:runRoot -PathType Container)) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
