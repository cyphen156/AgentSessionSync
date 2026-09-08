#requires -Version 5.1
[CmdletBinding()]
param([switch]$DiscardLocalChanges)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vaultRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $vaultRoot 'AgentSessionSync.config.psd1'
$git = $null
$powerShellExe = (Get-Process -Id $PID).Path
$safeRoot = $vaultRoot.Replace('\', '/')
$appResults = New-Object 'Collections.Generic.List[object]'
$publishedCommit = 'NONE'
$surveyRequired = $false
$apps = @()
$launchAttempted = $false

$baselineCommit = ''
$runId = [guid]::NewGuid().ToString('D')

$script:startWatch = [Diagnostics.Stopwatch]::StartNew()
function Write-StartProgress([string] $Message) {
    Write-Host ('PROGRESS: {0} +{1:N1}s {2}' -f (Get-Date -Format 'HH:mm:ss'), $script:startWatch.Elapsed.TotalSeconds, $Message)
}

function Write-SyncResult {
    param([string] $Result, [string] $Reason, [string] $Detail)
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: AgentSessionSync'
    Write-Output 'PHASE: Start'
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
    param([string[]] $ArgumentList, [switch] $AllowFailure, [string] $InputText)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:git
    $info.Arguments = ((@('-c', "safe.directory=$script:safeRoot", '-c', 'core.quotePath=true', '-C', $script:vaultRoot) + $ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
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
                Write-StartProgress ("Git {0} still running ({1:N0}s)" -f $ArgumentList[0], $gitWatch.Elapsed.TotalSeconds)
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

function Assert-UnchangedCheckout {
    param([string] $ExpectedHead)
    if ((Get-GitValue @('rev-parse', 'HEAD')) -ne $ExpectedHead) { throw 'The Vault HEAD changed during this run; it was not overwritten.' }
    if ((Invoke-GitCommand @('status', '--porcelain', '--untracked-files=all')).Output.Count) {
        throw 'The Vault has uncommitted changes; they were not overwritten. Commit them and retry.'
    }
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
    try {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $App.ScriptPath, '-RunId', $script:runId)
        if ($Operation) { $arguments += @('-Operation', $Operation) }
        if ($script:baselineCommit) { $arguments += @('-BaselineCommit', $script:baselineCommit) }
        if ($RemoteCommit) { $arguments += @('-RemoteCommit', $RemoteCommit) }
        if ($PublishedCommit) { $arguments += @('-PublishedCommit', $PublishedCommit) }
        if ($DiscardConfirmed) { $arguments += '-DiscardLocalChanges' }
        $fields = @{}
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:powerShellExe
        $info.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        $appWatch = [Diagnostics.Stopwatch]::StartNew()
        Write-StartProgress ("{0} Start started" -f $App.Name)
        try {
            [void]$process.Start()
            $outRead = $process.StandardOutput.ReadLineAsync()
            $errRead = $process.StandardError.ReadLineAsync()
            $nextNotice = 5
            while ($null -ne $outRead -or $null -ne $errRead -or -not $process.HasExited) {
                foreach ($stream in @('stdout','stderr')) {
                    $pending = if ($stream -eq 'stdout') { $outRead } else { $errRead }
                    if ($null -eq $pending -or -not $pending.IsCompleted) { continue }
                    $line = $pending.GetAwaiter().GetResult()
                    if ($null -ne $line) {
                        Write-Host "[$($App.Name)] $line"
                        # Only stdout carries the app result contract. Diagnostics
                        # and heartbeat messages never become a root RESULT.
                        if ($stream -eq 'stdout') {
                            if ($line -match '^SURVEY_REQUIRED:\s*True\s*$') { $script:surveyRequired = $true }
                            if ($line -match '^DETAIL:\s*(.*)$') { $fields['DETAIL']=$Matches[1] }
                            if ($line -match '^(RESULT|PREPARED_TREE|LOCAL_BASE_TREE|DISCARD_REQUIRED):\s*(\S+)\s*$') {
                                if ($fields.ContainsKey($Matches[1])) { $fields[$Matches[1]] = 'DUPLICATE' }
                                else { $fields[$Matches[1]] = $Matches[2] }
                            }
                        }
                    }
                    if ($stream -eq 'stdout') {
                        $outRead = if ($null -ne $line) { $process.StandardOutput.ReadLineAsync() } else { $null }
                    } else {
                        $errRead = if ($null -ne $line) { $process.StandardError.ReadLineAsync() } else { $null }
                    }
                }
                if ($appWatch.Elapsed.TotalSeconds -ge $nextNotice) {
                    Write-StartProgress ("{0} Start still running ({1:N0}s); waiting for app result" -f $App.Name, $appWatch.Elapsed.TotalSeconds)
                    $nextNotice = $appWatch.Elapsed.TotalSeconds + 5
                }
                # Drain output without throttling every line; sleep only while
                # both streams are waiting so long reports cannot fill a pipe.
                if (($null -eq $outRead -or -not $outRead.IsCompleted) -and ($null -eq $errRead -or -not $errRead.IsCompleted)) { Start-Sleep -Milliseconds 50 }
            }
            $process.WaitForExit()
            $code = $process.ExitCode
        }
        finally {
            $process.Dispose()
            Write-StartProgress ("{0} Start returned after {1:N1}s" -f $App.Name, $appWatch.Elapsed.TotalSeconds)
        }
        if($code-ne0-and$fields['RESULT']-eq'Failure'-and$fields['DISCARD_REQUIRED']-eq'True'){
            return [pscustomobject]@{Name=$App.Name;Success=$false;Reason=[string]$fields['DETAIL'];PreparedTree='';LocalTree='';DiscardRequired=$true}
        }
        if ($code -ne 0 -or $fields['RESULT'] -ne 'Success') { throw "$($App.Name) $Operation failed (exit $code). See the app report above." }
        $preparedTree = ''; $localTree = ''
        if ($Operation -eq 'Prepare') { $preparedTree = [string]$fields['PREPARED_TREE']; Assert-TreeObject $preparedTree }
        if ($Operation -eq 'Complete' -or -not $Operation) { $localTree = [string]$fields['LOCAL_BASE_TREE']; Assert-TreeObject $localTree }
        return [pscustomobject]@{ Name=$App.Name; Success=$true; Reason='Completed'; PreparedTree=$preparedTree; LocalTree=$localTree; DiscardRequired=$false }
    }
    catch {
        return [pscustomobject]@{ Name=$App.Name; Success=$false; Reason=$_.Exception.Message; PreparedTree=''; LocalTree=''; DiscardRequired=$false }
    }
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
        $scriptPath = Join-Path $script:vaultRoot "Launchers\$name\Start.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Registered app Start script is missing: $scriptPath"
        }
        $result.Add([pscustomobject]@{
            Name = $name
            AppId = [string]$item.AppId
            ProcessNames = $processNames
            ScriptPath = $scriptPath
        })
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

function Stop-AppGracefully {
    param($App, [int] $TimeoutSeconds)
    $processes = @(Get-AgentProcessTree $App)
    if ($processes.Count -eq 0) { return }
    Initialize-WindowApi
    $posted = New-Object 'Collections.Generic.HashSet[long]'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $processes = @(Get-AgentProcessTree $App)
        if ($processes.Count -eq 0) { return }
        $windows = @([AgentSessionSync.NativeMethods]::GetTopLevelWindows([int[]]@($processes | ForEach-Object Id)))
        foreach ($window in $windows) {
            if ($posted.Add([long]$window)) {
                [void][AgentSessionSync.NativeMethods]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (@(Get-AgentProcessTree $App).Count -ne 0) {
        throw "$($App.Name) did not close within $TimeoutSeconds seconds. Start never force-terminates an app."
    }
}

function Start-AppliedApps {
    $script:launchAttempted = $true
    $failures = New-Object 'Collections.Generic.List[string]'
    foreach ($app in $script:apps) {
        $matches = @($script:appResults.ToArray() | Where-Object { $_.Name -eq $app.Name })
        if ($matches.Count -ne 1 -or -not $matches[0].Success) { continue }
        try {
            Start-Process -WindowStyle Hidden -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppId)"
        }
        catch {
            $failures.Add("$($app.Name): $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

try {
    Write-StartProgress 'Loading settings and checking the Vault checkout'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Configuration is missing. Run Initialize-AgentSessionSync.ps1 first.' }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    $apps = @(Get-RegisteredApps $config)
    $timeout = [int]$config.GracefulCloseTimeoutSeconds
    if ($timeout -lt 1) { throw 'GracefulCloseTimeoutSeconds must be at least 1.' }
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    Assert-InstallationPaths $apps
    $originalHead = Get-GitValue @('rev-parse', 'HEAD')
    Assert-UnchangedCheckout $originalHead
    $baselineCommit = Get-LocalBaseline
    Write-StartProgress 'Fetching remote state; no app data has been changed'
    $remoteCommit = Update-RemoteObjects
    $baton = Get-Baton $remoteCommit
    $localBaton = Get-Baton $originalHead
    $thisHost = [Environment]::MachineName
    $discardConfirmed = [bool]$DiscardLocalChanges
    $hasLocalCommits = -not (Test-CommitIsAncestor $originalHead $remoteCommit)
    if ($baton -ne 'NONE' -and $baton -ne $thisHost) {
        Write-Warning "ACTIVE_HOST is $baton. This records use, not authority over this PC's unpublished work."
    }
    if (-not $discardConfirmed -and ($baton -eq $thisHost -or $localBaton -eq $thisHost -or $hasLocalCommits)) {
        $prompt = 'Start replaces local sessions with remote state. Unpublished app work and local-only Vault commits may be discarded. Continue? [y/N]'
        $answer = Read-Host $prompt
        if ($answer -notmatch '^(?i:y|yes)$') { throw 'Start cancelled. Fetch completed; HEAD, worktree and app data were not changed.' }
        $discardConfirmed = $true
    }
    # App Start reads the pinned remote directly, before any checkout change.
    # Confirmation is owned by this interactive parent, never a redirected child.
    foreach ($app in $apps) {
        try {
            Write-StartProgress ("Closing {0}; graceful wait up to {1}s" -f $app.Name, $timeout)
            Stop-AppGracefully $app $timeout
            Write-StartProgress ("{0} closed; settling file handles" -f $app.Name)
            Start-Sleep -Seconds 1
            $result=Invoke-AppCall $app -RemoteCommit $remoteCommit -DiscardConfirmed:$discardConfirmed
            if($result.DiscardRequired){
                Write-Warning $result.Reason
                $answer=Read-Host ("{0}: discard the reported unpublished local session state and apply the fetched remote? No keeps it unchanged for separate reconciliation. [y/N]" -f $app.Name)
                if($answer-notmatch '^(?i:y|yes)$'){
                    $result.Reason='Discard declined. Local data was retained; automatic Start stopped. Preservation/reconciliation requires user instructions.'
                    $appResults.Add($result)
                    break
                }
                # Approval is for this app and these reported differences, not
                # an automatic authorization to discard another app's work.
                $script:runId=[guid]::NewGuid().ToString('D')
                $result=Invoke-AppCall $app -RemoteCommit $remoteCommit -DiscardConfirmed
            }
            $appResults.Add($result)
        }
        catch { $appResults.Add([pscustomobject]@{ Name=$app.Name; Success=$false; Reason=$_.Exception.Message; LocalTree='' }) }
    }
    $failed = @($appResults.ToArray() | Where-Object { -not $_.Success })
    if ($failed.Count -or $appResults.Count -ne $apps.Count) {
        throw 'Start was not fully applied. Successful local applications remain; baton and comparison basis were not advanced. Run Start again for every registered app.'
    }
    Write-StartProgress 'All apps applied; recording comparison basis and preparing baton notification'
    $localTrees = @{}
    foreach ($result in $appResults.ToArray()) { $localTrees[$result.Name] = $result.LocalTree }
    $nextBaseline = New-LocalBaseline $baselineCommit $localTrees
    Assert-UnchangedCheckout $originalHead
    if ($hasLocalCommits) {
        if (-not $discardConfirmed) { throw 'Refusing to discard local-only commits without confirmation.' }
        [void](Invoke-GitCommand @('reset', '--hard', $remoteCommit))
    }
    else { [void](Invoke-GitCommand @('merge', '--ff-only', '--no-edit', $remoteCommit)) }

    # Application is complete before a claim is even constructed.
    $entries = Get-TreeEntries $remoteCommit
    Set-TreeBaton $entries $thisHost
    $tree = Write-TreeEntries $entries
    $candidate = $remoteCommit
    if ($tree -ne (Get-GitValue @('rev-parse', ($remoteCommit + '^{tree}')))) {
        $candidate = Get-GitValue @('commit-tree', $tree, '-p', $remoteCommit, '-m', "sync: claim baton for $thisHost")
    }
    Write-StartProgress 'Sending baton notification to origin/main'
    $push = Invoke-GitCommand @('push', '--porcelain', 'origin', ($candidate + ':refs/heads/main')) -AllowFailure
    if ($push.ExitCode -ne 0) {
        $pushText = ($push.Output -join "`n") + "`n" + $push.Error
        throw "Baton push did not report success (exit $($push.ExitCode)). Publication is not confirmed. Candidate=$candidate. App data was applied. $pushText"
    }
    # A successful push acknowledges the baton notification. It is not a lock;
    # do not require another remote read before finishing the local work.
    $publishedCommit = $candidate
    Assert-UnchangedCheckout $remoteCommit
    [void](Invoke-GitCommand @('merge', '--ff-only', '--no-edit', $candidate))
    Set-LocalBaseline $baselineCommit $nextBaseline
    Write-StartProgress 'Baton push succeeded; launching applied apps'
    $launchFailures = @(Start-AppliedApps)
    if ($launchFailures.Count) { throw ('Application launch failed: ' + ($launchFailures -join '; ')) }
    Write-SyncResult 'Success' 'Remote state applied by known structure rules' "All registered apps applied $remoteCommit. UI behaviour has not been surveyed."
    exit 0
}
catch {
    $message = $_.Exception.Message
    if (-not $launchAttempted -and $appResults.Count) {
        try { $launchFailures = @(Start-AppliedApps); if ($launchFailures.Count) { $message += '; Launch failed: ' + ($launchFailures -join '; ') } }
        catch { $message += '; Launch failed: ' + $_.Exception.Message }
    }
    foreach ($result in $appResults.ToArray()) { $message += "; $($result.Name): $($result.Reason)" }
    Write-SyncResult 'Failure' 'Start failed' $message
    exit 1
}
