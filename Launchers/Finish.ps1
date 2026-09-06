#requires -Version 5.1
[CmdletBinding()]
param([switch] $KeepBaton)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vaultRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $vaultRoot 'AgentSessionSync.config.psd1'
$git = $null
$powerShellExe = (Get-Process -Id $PID).Path
$safeRoot = $vaultRoot.Replace('\', '/')
$publishedCommit = 'NONE'
$surveyRequired = $false
$publicationUnknown = $false
$attemptRemote = ''
$candidate = ''
$attemptedApps = New-Object 'Collections.Generic.List[object]'
$baselineCommit = ''
$originalHead = ''
$checkoutSnapshot = $null
$rollbackReport = 'Not needed; no app preparation was started.'
$script:finishWatch = [Diagnostics.Stopwatch]::StartNew()
$runId = [guid]::NewGuid().ToString('D')

function Write-FinishProgress {
    param([string] $Message)
    Write-Host ('PROGRESS: {0} +{1:N1}s {2}' -f (Get-Date -Format 'HH:mm:ss'), $script:finishWatch.Elapsed.TotalSeconds, $Message)
}

function Write-SyncResult {
    param([string] $Result, [string] $Reason, [string] $Detail)
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: AgentSessionSync'
    Write-Output 'PHASE: Finish'
    Write-Output "REASON: $Reason"
    Write-Output "DETAIL: $Detail"
    Write-Output "PUBLISHED_COMMIT: $script:publishedCommit"
    Write-Output "SURVEY_REQUIRED: $script:surveyRequired"
}


function ConvertTo-NativeArgument {
    param([string] $Value)
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-GitCommand {
    param([string[]] $ArgumentList, [switch] $AllowFailure, [string] $InputText, [string] $IndexFile)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:git
    $info.Arguments = ((@('-c', "safe.directory=$script:safeRoot", '-c', 'core.quotePath=true', '-C', $script:vaultRoot) + $ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    if ($IndexFile) { $info.EnvironmentVariables['GIT_INDEX_FILE'] = $IndexFile }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        $gitWatch = [Diagnostics.Stopwatch]::StartNew()
        $nextNotice = 5
        while (-not $process.WaitForExit(1000)) {
            if ($gitWatch.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-FinishProgress ("Git {0} still running ({1:N0}s)" -f $ArgumentList[0], $gitWatch.Elapsed.TotalSeconds)
                $nextNotice = $gitWatch.Elapsed.TotalSeconds + 5
            }
        }
        $code = $process.ExitCode
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
    }
    finally { $process.Dispose() }
    $lines = @($out -split '\r?\n' | Where-Object { $_ -ne '' })
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Git failed ($code): $($ArgumentList -join ' '): $err"
    }
    return [pscustomobject]@{ ExitCode=$code; Output=$lines; Error=$err }
}

function Get-GitValue {
    param([string[]] $Arguments)
    $result = Invoke-GitCommand $Arguments
    if ($result.Output.Count -ne 1) { throw "Expected one Git value: $($Arguments -join ' ')" }
    return ([string]$result.Output[0]).Trim()
}

function Get-RemoteHead {
    return Get-GitValue @('rev-parse', '--verify', 'refs/remotes/origin/main^{commit}')
}

function Update-RemoteObjects {
    # Fetch objects only. Never move HEAD, the index, or the worktree here.
    [void](Invoke-GitCommand @('fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main'))
    return Get-RemoteHead
}

function Test-CommitIsAncestor {
    param([string] $Ancestor, [string] $Descendant)
    $result = Invoke-GitCommand @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure
    if ($result.ExitCode -gt 1) { throw "Cannot verify commit ancestry: $($result.Error)" }
    return ($result.ExitCode -eq 0)
}

function Get-TreeEntries {
    param([string] $Treeish)
    $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if ($Treeish) {
        foreach ($line in (Invoke-GitCommand @('ls-tree', $Treeish)).Output) {
            if ($line -notmatch '^(\d{6} (?:blob|tree|commit) [0-9a-f]+)\t(.+)$') { throw 'Unexpected Git tree entry.' }
            $entries.Add($Matches[2], $Matches[1])
        }
    }
    return ,$entries
}

function Write-TreeEntries {
    param($Entries)
    $lines = @($Entries.Keys | Sort-Object -CaseSensitive | ForEach-Object { $Entries[$_] + "`t" + $_ })
    $inputText = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
    $result = Invoke-GitCommand @('mktree') -InputText $inputText
    return ([string]$result.Output[0]).Trim()
}

function Assert-TreeObject {
    param([string] $ObjectId)
    if ($ObjectId -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'An app did not return a valid tree object id.' }
    if ((Get-GitValue @('cat-file', '-t', $ObjectId)) -ne 'tree') { throw 'The app result is not a Git tree.' }
}

function Get-LocalBaseline {
    $result = Invoke-GitCommand @('rev-parse', '--verify', '--quiet', 'refs/agent-session-sync/local-base^{commit}') -AllowFailure
    if ($result.ExitCode -eq 1) { return '' }
    if ($result.ExitCode -ne 0 -or $result.Output.Count -ne 1) { throw 'Cannot read the local comparison basis.' }
    return ([string]$result.Output[0]).Trim()
}

function New-LocalBaseline {
    param([string] $Previous, $AppTrees)
    $entries = Get-TreeEntries $Previous
    foreach ($name in $AppTrees.Keys) {
        Assert-TreeObject $AppTrees[$name]
        $entries[$name] = '040000 tree ' + $AppTrees[$name]
    }
    $tree = Write-TreeEntries $entries
    $arguments = @('commit-tree', $tree)
    if ($Previous) { $arguments += @('-p', $Previous) }
    return Get-GitValue ($arguments + @('-m', 'local: accepted app comparison basis'))
}

function Set-LocalBaseline {
    param([string] $Previous, [string] $Next)
    $oldValue = if ($Previous) { $Previous } else { '0' * $Next.Length }
    [void](Invoke-GitCommand @('update-ref', 'refs/agent-session-sync/local-base', $Next, $oldValue))
}

function Get-Baton {
    param([string] $Commit)
    $entries = Get-TreeEntries $Commit
    if (-not $entries.ContainsKey('ACTIVE_HOST.txt')) { return 'NONE' }
    if ($entries['ACTIVE_HOST.txt'] -notmatch '^100644 blob ') { throw 'ACTIVE_HOST.txt is not a regular file.' }
    $value = Get-GitValue @('show', ($Commit + ':ACTIVE_HOST.txt'))
    if (-not $value -or $value -match '[\r\n]') { throw 'Invalid ACTIVE_HOST.txt.' }
    return $value
}

function Set-TreeBaton {
    param($Entries, [string] $Value)
    $blob = Invoke-GitCommand @('hash-object', '-w', '--stdin') -InputText ($Value + "`n")
    $Entries['ACTIVE_HOST.txt'] = '100644 blob ' + ([string]$blob.Output[0]).Trim()
}

function Get-CheckoutSnapshot {
    # A private Git index reads the working tree without staging user files or
    # making a commit. It is not an app staging/backup area and contains no policy.
    if ((Invoke-GitCommand @('ls-files', '--unmerged')).Output.Count) {
        throw 'The Vault has unresolved Git conflicts; no automatic resolution was attempted.'
    }
    $head = Get-GitValue @('rev-parse', 'HEAD')
    $indexEntries = (Invoke-GitCommand @('ls-files', '--stage', '-z')).Output -join "`n"
    $realIndex = Get-GitValue @('rev-parse', '--git-path', 'index')
    if (-not [IO.Path]::IsPathRooted($realIndex)) { $realIndex = Join-Path $script:vaultRoot $realIndex }
    $privateIndex = Join-Path (Split-Path $realIndex -Parent) ('finish-index-' + [guid]::NewGuid().ToString('N'))
    try {
        if ([IO.File]::Exists($realIndex)) { [IO.File]::Copy($realIndex, $privateIndex) }
        else { [void](Invoke-GitCommand @('read-tree', $head) -IndexFile $privateIndex) }
        [void](Invoke-GitCommand @('add', '-A', '--', '.') -IndexFile $privateIndex)
        $result = Invoke-GitCommand @('write-tree') -IndexFile $privateIndex
        if ($result.Output.Count -ne 1) { throw 'Cannot capture the Vault working tree.' }
        return [pscustomobject]@{ Head=$head; Tree=([string]$result.Output[0]).Trim(); IndexEntries=$indexEntries }
    }
    finally { if ([IO.File]::Exists($privateIndex)) { [IO.File]::Delete($privateIndex) } }
}

function Assert-UnchangedCheckout {
    param([string] $ExpectedHead)
    $now = Get-CheckoutSnapshot
    if ($now.Head -ne $ExpectedHead) { throw 'The Vault HEAD changed during this run; it was not overwritten.' }
    if ($now.Tree -ne $script:checkoutSnapshot.Tree -or $now.IndexEntries -cne $script:checkoutSnapshot.IndexEntries) {
        throw 'The Vault working tree or staged changes changed during Finish. Later edits were not overwritten or silently published.'
    }
}

function Install-PublishedCheckout {
    param([string] $Candidate, [string] $OriginalHead)
    Assert-UnchangedCheckout $OriginalHead
    # Publication and app Complete already succeeded. The captured worktree is
    # now published, so align the real index before installing the exact result.
    # No reset, preliminary commit, or pre-publication checkout is performed.
    [void](Invoke-GitCommand @('read-tree', $script:checkoutSnapshot.Tree))
    [void](Invoke-GitCommand @('restore', '--source', $Candidate, '--staged', '--worktree', '--', '.'))
    [void](Invoke-GitCommand @('update-ref', '-m', 'sync: published agent sessions', 'HEAD', $Candidate, $OriginalHead))
}

function Assert-InstallationPaths {
    param([array] $Apps)
    # Git plumbing does not enforce ignore rules; do not bypass the public
    # distribution's blocked app directories while composing a private tree.
    foreach ($app in $Apps) {
        $result = Invoke-GitCommand @('check-ignore', '--quiet', '--no-index', '--', ($app.Name + '/')) -AllowFailure
        if ($result.ExitCode -eq 0) { throw "App data is blocked by Git ignore rules: $($app.Name). Initialize the private installation before syncing." }
        if ($result.ExitCode -ne 1) { throw 'Cannot verify the installation app paths.' }
    }
}

function Invoke-AppCall {
    param($App, [string] $Operation='', [string] $RemoteCommit='', [string] $PublishedCommit='', [switch] $DiscardConfirmed)
    $appWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-FinishProgress ("{0} {1} started" -f $App.Name, $Operation)
    try {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $App.ScriptPath, '-RunId', $script:runId)
        if ($Operation) { $arguments += @('-Operation', $Operation) }
        if ($script:baselineCommit) { $arguments += @('-BaselineCommit', $script:baselineCommit) }
        if ($RemoteCommit) { $arguments += @('-RemoteCommit', $RemoteCommit) }
        if ($PublishedCommit) { $arguments += @('-PublishedCommit', $PublishedCommit) }
        if ($DiscardConfirmed) { $arguments += '-DiscardLocalChanges' }
        $fields = @{}
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $script:powerShellExe @arguments | ForEach-Object {
                $line = [string]$_
                Write-Host "[$($App.Name)] $line"
                if ($line -match '^SURVEY_REQUIRED:\s*True\s*$') { $script:surveyRequired = $true }
                if ($line -match '^(RESULT|PREPARED_TREE|LOCAL_BASE_TREE):\s*(\S+)\s*$') {
                    if ($fields.ContainsKey($Matches[1])) { $fields[$Matches[1]] = 'DUPLICATE' }
                    else { $fields[$Matches[1]] = $Matches[2] }
                }
            }
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($code -ne 0 -or $fields['RESULT'] -ne 'Success') { throw "$($App.Name) $Operation failed (exit $code). See the app report above." }
        $preparedTree = ''; $localTree = ''
        if ($Operation -eq 'Prepare') { $preparedTree = [string]$fields['PREPARED_TREE']; Assert-TreeObject $preparedTree }
        if ($Operation -eq 'Prepare' -or -not $Operation) { $localTree = [string]$fields['LOCAL_BASE_TREE']; Assert-TreeObject $localTree }
        return [pscustomobject]@{ Name=$App.Name; Success=$true; Reason='Completed'; PreparedTree=$preparedTree; LocalTree=$localTree }
    }
    catch {
        return [pscustomobject]@{ Name=$App.Name; Success=$false; Reason=$_.Exception.Message; PreparedTree=''; LocalTree='' }
    }
    finally { Write-FinishProgress ("{0} {1} returned after {2:N1}s" -f $App.Name, $Operation, $appWatch.Elapsed.TotalSeconds) }
}
function Get-RegisteredApps {
    param([hashtable] $Config)
    $result = New-Object 'Collections.Generic.List[object]'
    foreach ($name in @('Codex', 'Claude')) {
        if (-not $Config.ContainsKey($name)) { continue }
        $item = $Config[$name]
        if (-not $item.Enabled) { continue }
        $processNames = @($item.ProcessNames | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if (-not $item.AppId -or $processNames.Count -eq 0) {
            throw "Registered app configuration is incomplete: $name"
        }
        $scriptPath = Join-Path $script:vaultRoot "Launchers\$name\Finish.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Registered app Finish script is missing: $scriptPath"
        }
        $result.Add([pscustomobject]@{ Name=$name; ProcessNames=$processNames; ScriptPath=$scriptPath })
    }
    if ($result.Count -eq 0) { throw 'No apps are registered in AgentSessionSync.config.psd1.' }
    return $result.ToArray()
}

function Get-SystemProcessSnapshot {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath }
        })
    }
    catch {
        return @(Get-WmiObject Win32_Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ParentProcessId=[int]$_.ParentProcessId; Name=[string]$_.Name; ExecutablePath=[string]$_.ExecutablePath }
        })
    }
}

function Test-AgentDesktopProcess {
    param($Process)
    if ($Process.MainWindowHandle -ne 0) { return $true }
    try { $path = [string]$Process.Path } catch { $path = '' }
    return $path -match '(?i)\\WindowsApps\\'
}

function Get-AgentProcessTree {
    param($App, [array] $Snapshot = @(Get-SystemProcessSnapshot))
    $names = @{}
    foreach ($name in $App.ProcessNames) { $names[[string]$name] = $true }
    $ids = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($row in $Snapshot) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
        if ($names.ContainsKey($baseName) -and [string]$row.ExecutablePath -match '(?i)\\WindowsApps\\') {
            [void]$ids.Add([int]$row.ProcessId)
        }
    }
    foreach ($process in @(Get-Process -Name $App.ProcessNames -ErrorAction SilentlyContinue)) {
        if (Test-AgentDesktopProcess $process) { [void]$ids.Add([int]$process.Id) }
    }
    do {
        $added = $false
        foreach ($row in $Snapshot) {
            if ($ids.Contains([int]$row.ParentProcessId) -and $ids.Add([int]$row.ProcessId)) { $added = $true }
        }
    } while ($added)
    return @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Sort-Object Id -Unique)
}

function Get-CurrentProcessTreeIds {
    param([array] $Snapshot)
    $parents = @{}
    foreach ($row in $Snapshot) { $parents[[int]$row.ProcessId] = [int]$row.ParentProcessId }
    $ids = New-Object 'Collections.Generic.HashSet[int]'
    $current = [int]$PID
    while ($current -gt 0 -and $ids.Add($current) -and $parents.ContainsKey($current)) {
        $current = [int]$parents[$current]
    }
    return @($ids)
}

function Assert-CurrentProcessOutsideApps {
    param([array] $Apps)
    $snapshot = @(Get-SystemProcessSnapshot)
    $self = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($id in @(Get-CurrentProcessTreeIds $snapshot)) { [void]$self.Add([int]$id) }
    foreach ($app in $Apps) {
        foreach ($process in @(Get-AgentProcessTree -App $app -Snapshot $snapshot)) {
            if ($self.Contains([int]$process.Id)) {
                throw "Finish is running inside the $($app.Name) process tree. Run it from an independent PowerShell window or shortcut."
            }
        }
    }
}

function Initialize-WindowApi {
    if ('AgentSessionSync.NativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace AgentSessionSync {
    public static class NativeMethods {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        public static IntPtr[] GetTopLevelWindows(int[] processIds) {
            var ids = new HashSet<int>(processIds);
            var windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);
                if (ids.Contains((int)processId)) windows.Add(hWnd);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
    }
}
'@
}

function Send-CloseRequests {
    param([int[]] $ProcessIds, $Posted)
    if ($ProcessIds.Count -eq 0) { return 0 }
    Initialize-WindowApi
    $windows = @([AgentSessionSync.NativeMethods]::GetTopLevelWindows($ProcessIds))
    foreach ($window in $windows) {
        if ($Posted.Add([long]$window)) {
            [void][AgentSessionSync.NativeMethods]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    }
    return $windows.Count
}

function Stop-AllAppsForFinish {
    param([array] $Apps, [int] $TimeoutSeconds)
    $postedByApp = @{}
    $forceImmediately = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($app in $Apps) {
        $posted = New-Object 'Collections.Generic.HashSet[long]'
        $postedByApp[$app.Name] = $posted
        $processes = @(Get-AgentProcessTree $app)
        if ($processes.Count -ne 0) {
            $windowCount = Send-CloseRequests ([int[]]@($processes | ForEach-Object Id)) $posted
            if ($windowCount -eq 0) { [void]$forceImmediately.Add([string]$app.Name) }
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $anyWaiting = $false
        foreach ($app in $Apps) {
            if ($forceImmediately.Contains([string]$app.Name)) { continue }
            $processes = @(Get-AgentProcessTree $app)
            if ($processes.Count -eq 0) { continue }
            $anyWaiting = $true
            [void](Send-CloseRequests ([int[]]@($processes | ForEach-Object Id)) $postedByApp[$app.Name])
        }
        $remaining = @($Apps | Where-Object { @(Get-AgentProcessTree $_).Count -ne 0 })
        if ($remaining.Count -eq 0) { return }
        if (-not $anyWaiting) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    Write-FinishProgress 'Force-closing remaining registered app process trees (up to 10s)'
    $forceDeadline = (Get-Date).AddSeconds(10)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    do {
        $snapshot = @(Get-SystemProcessSnapshot)
        $parents = @{}
        foreach ($row in $snapshot) { $parents[[int]$row.ProcessId] = [int]$row.ParentProcessId }
        $anyRunning = $false
        foreach ($app in $Apps) {
            $processes = @(Get-AgentProcessTree -App $app -Snapshot $snapshot)
            if ($processes.Count -eq 0) { continue }
            $anyRunning = $true
            $treeIds = New-Object 'Collections.Generic.HashSet[int]'
            foreach ($process in $processes) { [void]$treeIds.Add([int]$process.Id) }
            foreach ($processId in @($treeIds)) {
                if ($parents.ContainsKey($processId) -and $treeIds.Contains($parents[$processId])) { continue }
                & $taskkill /PID $processId /T /F | Out-Null
            }
        }
        if (-not $anyRunning) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $forceDeadline)
    $stillRunning = @($Apps | Where-Object { @(Get-AgentProcessTree $_).Count -ne 0 } | ForEach-Object Name)
    if ($stillRunning.Count -ne 0) {
        throw "Registered apps are still running after process-tree termination: $($stillRunning -join ', ')"
    }
}


function Join-NonSessionTrees {
    param([string] $Base, [string] $Local, [string] $Remote, $AppTrees, [string] $Prefix='')
    # Generic Git file reconciliation only. App subtrees are opaque replacements.
    $b = Get-TreeEntries $Base; $l = Get-TreeEntries $Local; $r = Get-TreeEntries $Remote
    $out = Get-TreeEntries ''
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($map in @($b,$l,$r)) { foreach ($key in $map.Keys) { [void]$keys.Add($key) } }
    if (-not $Prefix) { foreach ($key in $AppTrees.Keys) { [void]$keys.Add($key) } }
    foreach ($key in $keys) {
        if (-not $Prefix -and $AppTrees.ContainsKey($key)) {
            $out[$key] = '040000 tree ' + $AppTrees[$key]; continue
        }
        if (-not $Prefix -and $key -eq 'ACTIVE_HOST.txt') {
            if ($r.ContainsKey($key)) { $out[$key] = $r[$key] }; continue
        }
        $bv = if ($b.ContainsKey($key)) { $b[$key] } else { '' }
        $lv = if ($l.ContainsKey($key)) { $l[$key] } else { '' }
        $rv = if ($r.ContainsKey($key)) { $r[$key] } else { '' }
        if ($lv -ceq $bv) { $chosen = $rv }
        elseif ($rv -ceq $bv -or $lv -ceq $rv) { $chosen = $lv }
        elseif ($Prefix -eq '' -and $key -in @('Codex','Claude')) {
            throw "Unregistered app path changed on both sides: $key. No app can judge it in this run."
        }
        elseif (($bv -eq '' -or $bv.StartsWith('040000 tree ')) -and $lv.StartsWith('040000 tree ') -and $rv.StartsWith('040000 tree ')) {
            $bt = if ($bv) { ($bv -split ' ')[2] } else { '' }
            $child = Join-NonSessionTrees $bt ($lv -split ' ')[2] ($rv -split ' ')[2] $AppTrees ($Prefix + $key + '/')
            $chosen = '040000 tree ' + $child
        }
        else { throw "Git file conflict: $Prefix$key. Neither version was overwritten; resolve it before retrying Finish." }
        if ($chosen) { $out[$key] = $chosen }
    }
    return Write-TreeEntries $out
}

function Cancel-AppPreparation {
    if ($script:attemptedApps.Count -eq 0) { return }
    Write-FinishProgress 'Cancelling app preparation; pre-run work and commits are retained'
    $script:rollbackReport = 'Attempted; completion not yet confirmed.'
    $failures = New-Object 'Collections.Generic.List[string]'
    foreach ($app in $script:attemptedApps.ToArray()) {
        $result = Invoke-AppCall $app 'Cancel' $script:attemptRemote
        if (-not $result.Success) { $failures.Add($result.Reason) }
    }
    $script:attemptedApps.Clear()
    $script:rollbackReport = if ($failures.Count) { 'FAILED; retain app recovery material. ' + ($failures.ToArray() -join '; ') } else { 'Completed for every attempted app preparation.' }
    return $failures.ToArray()
}

function Assert-FinishBaton {
    param([string] $Remote)
    $owner = Get-Baton $Remote
    if ($owner -ne 'NONE' -and $owner -ne [Environment]::MachineName) {
        throw "ACTIVE_HOST is $owner. Finish is blocked; Start is required before Finish. Start may discard unpublished local work. Review this report and give instructions for preserving or reconciling that work before running Start. Finish did not invoke Start, take over the baton, or authorize discarding local work."
    }
}

function New-PublicationCommit {
    param([string] $OriginalHead, [string] $Remote, $AppTrees, [string] $LocalTree)
    Assert-FinishBaton $Remote
    $baseResult = Invoke-GitCommand @('merge-base', $OriginalHead, $Remote) -AllowFailure
    if ($baseResult.ExitCode -gt 1) { throw 'Cannot read the common Git ancestor.' }
    $base = if ($baseResult.Output.Count) { [string]$baseResult.Output[0] } else { '' }
    $tree = Join-NonSessionTrees $base $LocalTree $Remote $AppTrees
    $entries = Get-TreeEntries $tree
    $baton = Get-Baton $Remote
    if ($baton -eq [Environment]::MachineName -and -not $KeepBaton) { Set-TreeBaton $entries 'NONE' }
    $tree = Write-TreeEntries $entries
    $localAlreadyPublished = Test-CommitIsAncestor $OriginalHead $Remote
    if ($localAlreadyPublished -and $tree -eq (Get-GitValue @('rev-parse', ($Remote + '^{tree}')))) { return $Remote }
    $arguments = @('commit-tree', $tree, '-p', $Remote)
    # Preserve existing local-only commits (including Surveys). This records
    # parents of an explicitly built tree; it does not run Git content merge.
    if (-not $localAlreadyPublished) { $arguments += @('-p', $OriginalHead) }
    return Get-GitValue ($arguments + @('-m', 'sync: publish agent sessions'))
}

try {
    Write-FinishProgress 'Loading installation settings and registered apps'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Configuration is missing. Run Initialize-AgentSessionSync.ps1 first.' }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    $apps = @(Get-RegisteredApps $config)
    $timeout = [int]$config.GracefulCloseTimeoutSeconds
    if ($timeout -lt 1) { throw 'GracefulCloseTimeoutSeconds must be at least 1.' }
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    Assert-InstallationPaths $apps
    $originalHead = Get-GitValue @('rev-parse', 'HEAD')
    $baselineCommit = Get-LocalBaseline
    Write-FinishProgress 'Fetching remote state; local work is not replaced'
    $attemptRemote = Update-RemoteObjects
    Assert-FinishBaton $attemptRemote
    Write-FinishProgress 'Recording pre-run Vault changes without a commit; user staging and files remain intact'
    $checkoutSnapshot = Get-CheckoutSnapshot
    if ($checkoutSnapshot.Head -ne $originalHead) { throw 'Vault HEAD changed while recording pre-run work.' }

    Assert-CurrentProcessOutsideApps $apps
    Write-FinishProgress ("Closing registered apps; graceful wait up to {0}s" -f $timeout)
    Stop-AllAppsForFinish $apps $timeout
    foreach ($app in $apps) { if (@(Get-AgentProcessTree $app).Count) { throw "$($app.Name) is still running." } }
    Write-FinishProgress 'All registered apps closed; waiting 1s for file handles'
    Start-Sleep -Seconds 1

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $runId = [guid]::NewGuid().ToString('D')
        Write-FinishProgress ("Prepare attempt {0}/3; RunId={1}" -f $attempt, $runId)
        $trees = @{}
        $localTrees = @{}
        $failures = New-Object 'Collections.Generic.List[string]'
        foreach ($app in $apps) {
            # Cancel includes a failed Prepare: it may have changed app data.
            # Each app checks structure and secures recovery before any write.
            $attemptedApps.Add($app)
            $result = Invoke-AppCall $app 'Prepare' $attemptRemote
            if ($result.Success) {
                $trees[$app.Name] = $result.PreparedTree
                $localTrees[$app.Name] = $result.LocalTree
            }
            else { $failures.Add($result.Reason) }
        }
        if ($failures.Count) { throw ('An app was not ready. Nothing was published. ' + ($failures.ToArray() -join '; ')) }
        Assert-UnchangedCheckout $originalHead
        # Prepare already completed app-local normalisation. Capture its actual
        # local snapshots now; do not advance the accepted ref before publication.
        Write-FinishProgress 'All apps ready; composing one joint publication commit'
        $nextBaseline = New-LocalBaseline $baselineCommit $localTrees
        $candidate = New-PublicationCommit $originalHead $attemptRemote $trees $checkoutSnapshot.Tree
        $publicationUnknown = $true
        Write-FinishProgress ("Pushing joint candidate {0}" -f $candidate)
        $push = Invoke-GitCommand @('push', '--porcelain', 'origin', ($candidate + ':refs/heads/main')) -AllowFailure
        # A failed transport can still have published. Read back before cleanup.
        Write-FinishProgress 'Checking publication result before cleanup or rollback'
        $observed = Update-RemoteObjects
        if (Test-CommitIsAncestor $candidate $observed) {
            $publishedCommit = $candidate
            $publicationUnknown = $false
            break
        }
        if ($push.ExitCode -eq 0) { throw 'Push reported success but publication could not be verified. Local preparation is retained.' }
        $publicationUnknown = $false
        $cancelFailures = @(Cancel-AppPreparation)
        if ($cancelFailures.Count) { throw ('App rollback failed; retain recovery material: ' + ($cancelFailures -join '; ')) }
        $pushText = ($push.Output -join "`n") + "`n" + $push.Error
        if ($observed -eq $attemptRemote -or $pushText -notmatch '(?i)(\[rejected\].*(fetch first|non-fast-forward|stale info)|cannot lock ref.*is at.*but expected)') {
            throw "Push failed; no session conclusion follows from this Git error: $pushText"
        }
        $attemptRemote = $observed
        Assert-FinishBaton $attemptRemote
    }
    if ($publishedCommit -eq 'NONE') { throw 'Three publication attempts were rejected. Nothing was published by this run.' }

    Assert-UnchangedCheckout $originalHead
    # App changes are finished and published. Accept their Prepare snapshots
    # before disposing recovery material; cleanup failure cannot stale the basis.
    Write-FinishProgress 'Publication verified; saving accepted local comparison basis'
    Set-LocalBaseline $baselineCommit $nextBaseline
    # Complete with the same app script that prepared this run. Receiving a
    # remote code update first could replace that script mid-operation.
    # Complete only releases app-owned backups/scratch after publication.
    # It must not perform Archive/Delete or change the captured local snapshots.
    $completeFailures = New-Object 'Collections.Generic.List[string]'
    foreach ($app in $apps) {
        $result = Invoke-AppCall $app 'Complete' $attemptRemote $publishedCommit
        if (-not $result.Success) { $completeFailures.Add($result.Reason) }
    }
    if ($completeFailures.Count) { throw ('Published, but app backup/scratch cleanup failed: ' + ($completeFailures.ToArray() -join '; ')) }
    Assert-UnchangedCheckout $originalHead
    # Install the exact verified tree without a payload content merge.
    Write-FinishProgress 'App cleanup completed; advancing the Vault checkout'
    Install-PublishedCheckout $candidate $originalHead
    $attemptedApps.Clear()
    Write-SyncResult 'Success' 'Sessions published and local completion finished' "Published $publishedCommit. All registered apps completed."
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($publishedCommit -eq 'NONE' -and -not $publicationUnknown) {
        try {
            $cancelFailures = @(Cancel-AppPreparation)
            if ($cancelFailures.Count) { $message += '; Cancel failed: ' + ($cancelFailures -join '; ') }
        }
        catch { $message += '; Cancel failed: ' + $_.Exception.Message }
    }
    if ($publicationUnknown) { $message += "; Publication result unknown. Candidate=$candidate. Preparation retained; do not discard it." }
    elseif ($publishedCommit -ne 'NONE') { $message += "; Published=$publishedCommit. Publication was not rolled back. Rerun only after reviewing unfinished local completion." }
    if ($publicationUnknown) { $rollbackReport = 'Not attempted: publication is unknown. Preparation retained.' }
    elseif ($publishedCommit -ne 'NONE') { $rollbackReport = 'Not attempted: publication already succeeded.' }
    Write-Host ("APP_ROLLBACK: {0}" -f $rollbackReport)
    Write-Host ("LOCAL_COMMIT: no preliminary collection commit; pre-run HEAD={0}; candidate={1}" -f $(if ($originalHead) { $originalHead } else { 'UNKNOWN' }), $(if ($candidate) { $candidate } else { 'NONE' }))
    if ($publishedCommit -eq 'NONE') { Write-Host 'LOCAL_WORK: pre-run work and staging were not reset; app rollback is reported separately' }
    Write-Host ("REMOTE_PUBLICATION: {0}" -f $(if ($publicationUnknown) { 'UNKNOWN; retain recovery material' } elseif ($publishedCommit -ne 'NONE') { $publishedCommit } else { 'NONE; no publication confirmed for this run' }))
    Write-SyncResult 'Failure' 'Finish failed' $message
    exit 1
}
