#requires -Version 5.1
# One-time local session disposal. No receive, publication, or Git ref changes.
# Never invoked by Start, Finish, Initialize, or the workbench adapter.
[CmdletBinding()]
param([switch]$ConfirmDiscard)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:survey=$false
$script:surveyRequired=$false
$script:mutating=$false
$script:runRoot=''
$script:utf8=New-Object Text.UTF8Encoding($false,$true)
$vaultRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Assert-AppClosed($App) {
    $names=@($App.ProcessNames)
    if($names.Count-eq0){throw 'Initialize must configure app ProcessNames before local reset.'}
    foreach($name in $names){
        if($name-isnot[string]-or$name-notmatch '^[A-Za-z0-9_.-]+$'){throw 'Invalid configured process name.'}
        $found=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue)
        if($found.Count){throw "Close the configured app before resetting sessions: $name. No process was stopped."}
    }
}
function Report-Reset([string]$Result,[string]$Detail) {
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: Claude'
    Write-Output 'PHASE: ResetLocalSessions'
    Write-Output 'REASON: Manual local session reset'
    Write-Output "DETAIL: $Detail"
    Write-Output 'PUBLISHED_COMMIT: NONE'
    Write-Output ('SURVEY_REQUIRED: '+[string]($script:survey-or$script:surveyRequired))
}
function Clear-ResetScratch {
    if(-not$script:runRoot){return}
    $full=[IO.Path]::GetFullPath($script:runRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full)-ne$parent-or[IO.Path]::GetFileName($full)-notmatch '^ass-reset-[0-9a-f]{32}$'){throw 'Unsafe reset scratch path.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
function Test-JsonMember {
    # Presence only. A value cannot answer this: an empty array unrolls to
    # nothing on return, so a present-but-empty field would read as absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
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

function Assert-ClaudeReceivePath([string]$Path,$Store) {
    $full=[IO.Path]::GetFullPath($Path)
    $roots=@([IO.Path]::GetFullPath($Store.RecordRoot).TrimEnd('\','/'),[IO.Path]::GetFullPath($Store.ProjectsRoot).TrimEnd('\','/'),[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Store.ConfigPath)))
    if(@($roots|Where-Object{$full.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count-eq0){throw "Claude receive path escapes configured storage: $full"}
    $cursor=$full
    while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Claude receive path is a reparse point: $cursor"}};$cursor=[IO.Path]::GetDirectoryName($cursor)}
    return $full
}

function New-ClaudeResetPlan($Store) {
    $files=New-Object 'Collections.Generic.List[string]';$ids=New-Object 'Collections.Generic.HashSet[string]'
    foreach($file in Get-ChildItem -LiteralPath $Store.RecordRoot -File -Force){
        if($file.Name-match '^local_([0-9a-fA-F-]{36})\.json$'){
            $id=$Matches[1];$parsed=[guid]::Empty;if(-not[guid]::TryParseExact($id,'D',[ref]$parsed)){throw "Unknown Claude record filename: $($file.Name)"}
            [void]$ids.Add($id);$files.Add((Assert-ClaudeReceivePath $file.FullName $Store))
        }elseif($file.Name-match '^deleted_([0-9a-fA-F-]{36})$'){$files.Add((Assert-ClaudeReceivePath $file.FullName $Store))}
        elseif($file.Name-like 'local_*'-or$file.Name-like 'deleted_*'){throw "Unknown Claude session file: $($file.Name)"}
    }
    $pending=New-Object 'Collections.Generic.Queue[string]';$pending.Enqueue($Store.ProjectsRoot)
    while($pending.Count){$dir=$pending.Dequeue();foreach($file in Get-ChildItem -LiteralPath $dir -Force){
        Assert-ClaudeReceivePath $file.FullName $Store|Out-Null
        if($file.PSIsContainer){$pending.Enqueue($file.FullName);continue}
        if($file.Name-match '^[0-9a-fA-F-]{36}\.(jsonl|desktop-released\.json)$'){$files.Add($file.FullName)}
    }}
    return [pscustomobject]@{Files=$files.ToArray();Ids=@($ids)}
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
    if ($actual.Count -ne $Expected.Count) { throw 'Claude browser storage changed independently; reset was stopped.' }
    foreach ($name in $Expected.Keys) {
        if (-not $actual.ContainsKey($name) -or $actual[$name] -ne $Expected[$name]) {
            throw 'Claude browser storage changed independently; reset was stopped.'
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
        foreach ($name in $Plan.Before.Keys) {
            if (-not $Plan.After.ContainsKey($name)) { Remove-ResetFile (Join-Path $Plan.Directory $name) }
        }
        foreach ($name in $Plan.After.Keys) {
            Write-ResetFile (Join-Path $Plan.Candidate $name) (Join-Path $Plan.Directory $name)
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
        Write-ResetFile $temporary $Store.ConfigPath
    }
    Assert-ClaudeAssignmentsRemoved $Store $AppSessionIds
}

function Write-ResetFile([string]$Source,[string]$Destination) {
    $Destination=Assert-ClaudeReceivePath $Destination $script:store
    $temporary=$Destination+'.reset-'+[guid]::NewGuid().ToString('N')
    [IO.File]::Copy($Source,$temporary,$false)
    if((Get-Sha256Hex $temporary)-ne(Get-Sha256Hex $Source)){throw 'Reset copy verification failed.'}
    if([IO.File]::Exists($Destination)){[IO.File]::Replace($temporary,$Destination,[NullString]::Value)}else{[IO.File]::Move($temporary,$Destination)}
    if((Get-Sha256Hex $Destination)-ne(Get-Sha256Hex $Source)){throw 'Reset file verification failed.'}
}
function Remove-ResetFile([string]$Path) {
    [IO.File]::Delete((Assert-ClaudeReceivePath $Path $script:store))
}
try {
    if(-not$ConfirmDiscard){throw 'Explicit -ConfirmDiscard is required. This standalone tool discards existing local sessions WITHOUT BACKUP; it does not receive remote sessions.'}
    $config=Import-PowerShellDataFile -LiteralPath (Join-Path $vaultRoot 'AgentSessionSync.config.psd1')
    if(-not$config.ContainsKey('Claude')){throw 'The app is not configured. Run Initialize first.'}
    Assert-AppClosed $config.Claude
    $script:store=Get-ClaudeStore $config
    Assert-ClaudeReceivePath (Join-Path $store.RecordRoot '.reset-probe') $store|Out-Null
    Assert-ClaudeReceivePath (Join-Path $store.ProjectsRoot '.reset-probe') $store|Out-Null
    Assert-ClaudeReceivePath $store.ConfigPath $store|Out-Null
    $storageDirectory=Join-Path (Split-Path -Parent $store.ConfigPath) 'Local Storage\leveldb'
    Assert-ClaudeReceivePath (Join-Path $storageDirectory 'LOCK') $store|Out-Null
    Write-Host 'PROGRESS: Inspecting the configured local Claude session stores'
    $plan=New-ClaudeResetPlan $store
    if([IO.File]::Exists($store.ConfigPath)){Get-ClaudePlacementScope (Read-Utf8Json $store.ConfigPath) $store|Out-Null}
    $script:runRoot=Join-Path ([IO.Path]::GetTempPath()) ('ass-reset-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:runRoot)|Out-Null
    $placement=Prepare-ClaudePlacementStorage $store $plan.Ids
    Assert-AppClosed $config.Claude
    Write-Host 'PROGRESS: Discarding approved local Claude sessions without backup'
    $script:mutating=$true
    Remove-ClaudeAssignments $store $plan.Ids
    Apply-ClaudePlacementStorage $placement
    foreach($path in $plan.Files){Remove-ResetFile $path}
    Assert-ClaudeAssignmentsRemoved $store $plan.Ids
    if($placement){Assert-ClaudeStorageFiles $placement.Directory $placement.After}
    $remaining=New-ClaudeResetPlan $store
    if($remaining.Files.Count){throw 'Claude session data remains after reset.'}
    Clear-ResetScratch
    Report-Reset 'Success' 'Local session reset finished. Login, settings and project definitions were retained. No Vault content, baton, baseline or remote was changed. Run ordinary Start separately to receive the Vault.'
    exit 0
} catch {
    $detail=$_.Exception.Message
    if($script:mutating){$detail+=' Reset may be incomplete. No rollback or backup is available. Do not run Finish; resolve this failure before running Start.'}
    else{$detail+=' No app state was changed.'}
    if($script:runRoot){$detail+=' Inspection scratch: '+$script:runRoot}
    Report-Reset 'Failure' $detail
    exit 1
}
