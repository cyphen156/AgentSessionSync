#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RegisteredAgents {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $agentsRoot = Join-Path $RepoRoot 'Agents'
    $agents = foreach ($file in Get-ChildItem -LiteralPath $agentsRoot -Filter '*.psd1' -File) {
        $item = Import-PowerShellDataFile -LiteralPath $file.FullName
        $processNames = if ($item.ContainsKey('ProcessNames') -and $item.ProcessNames) {
            @($item.ProcessNames | ForEach-Object { [string]$_ } | Where-Object { $_ })
        } elseif ($item.ContainsKey('ProcessName') -and $item.ProcessName) {
            @([string]$item.ProcessName)
        } else {
            @()
        }
        if (-not $item.Name -or -not $item.AppId -or -not $processNames) {
            throw "Invalid agent definition: $($file.FullName)"
        }
        if ($item.Enabled) {
            [pscustomobject]@{
                Name = [string]$item.Name
                AppId = [string]$item.AppId
                ProcessNames = $processNames
                Order = [int]$item.Order
            }
        }
    }
    @($agents | Sort-Object Order, Name)
}

function Test-AgentDesktopProcess {
    param([Parameter(Mandatory)]$Process)
    if ($Process.MainWindowHandle -ne 0) { return $true }
    try {
        $executablePath = [string]$Process.Path
    } catch {
        $executablePath = ''
    }
    return $executablePath -match '(?i)\\WindowsApps\\'
}

function Get-SystemProcessSnapshot {
    try {
        @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                Name = [string]$_.Name
                ExecutablePath = [string]$_.ExecutablePath
            }
        })
    } catch {
        @(Get-WmiObject Win32_Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                Name = [string]$_.Name
                ExecutablePath = [string]$_.ExecutablePath
            }
        })
    }
}

function Get-AgentProcessTree {
    param(
        [Parameter(Mandatory)]$Agent,
        [array]$Snapshot = @(Get-SystemProcessSnapshot)
    )
    $names = @{}
    foreach ($name in $Agent.ProcessNames) { $names[[string]$name] = $true }

    $targetIds = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($row in $Snapshot) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
        if (-not $names.ContainsKey($baseName)) { continue }
        if ([string]$row.ExecutablePath -match '(?i)\\WindowsApps\\') {
            [void]$targetIds.Add([int]$row.ProcessId)
        }
    }
    # ExecutablePath can be unavailable for a packaged process. A real top-level window
    # is still sufficient to identify the desktop root; windowless AppData CLI processes
    # are deliberately not roots.
    foreach ($process in @(Get-Process -Name $Agent.ProcessNames -ErrorAction SilentlyContinue)) {
        if (Test-AgentDesktopProcess $process) { [void]$targetIds.Add([int]$process.Id) }
    }

    do {
        $added = $false
        foreach ($row in $Snapshot) {
            if ($targetIds.Contains([int]$row.ParentProcessId) -and $targetIds.Add([int]$row.ProcessId)) {
                $added = $true
            }
        }
    } while ($added)

    @($targetIds | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Sort-Object Id -Unique)
}

function Get-CurrentProcessTreeIds {
    param([array]$Snapshot = @(Get-SystemProcessSnapshot))
    $parents = @{}
    foreach ($row in $Snapshot) { $parents[[int]$row.ProcessId] = [int]$row.ParentProcessId }
    $result = New-Object 'Collections.Generic.HashSet[int]'
    $current = [int]$PID
    while ($current -gt 0 -and $result.Add($current) -and $parents.ContainsKey($current)) {
        $current = [int]$parents[$current]
    }
    @($result)
}

function Assert-CurrentProcessOutsideAgentTrees {
    param([Parameter(Mandatory)][array]$Agents)
    $snapshot = @(Get-SystemProcessSnapshot)
    $selfTree = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($id in (Get-CurrentProcessTreeIds $snapshot)) { [void]$selfTree.Add([int]$id) }
    foreach ($agent in $Agents) {
        $targets = @(Get-AgentProcessTree -Agent $agent -Snapshot $snapshot)
        if ($targets | Where-Object { $selfTree.Contains([int]$_.Id) }) {
            throw "Finish is running inside the $($agent.Name) process tree. Run Finish.ps1 from an independent PowerShell window or shortcut so session push is not terminated halfway."
        }
    }
}

function Stop-AgentProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $taskkill /PID $ProcessId /T /F | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        throw "Failed to terminate process tree rooted at PID $ProcessId (taskkill exit code $LASTEXITCODE)."
    }
}

function Initialize-AgentWindowApi {
    if (-not ('AgentSessionSync.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace AgentSessionSync {
    public static class NativeMethods {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
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
}

function Get-AgentTopLevelWindows {
    param([Parameter(Mandatory)][int[]]$ProcessIds)
    Initialize-AgentWindowApi
    @([AgentSessionSync.NativeMethods]::GetTopLevelWindows($ProcessIds))
}

function Send-AgentCloseRequest {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    Initialize-AgentWindowApi
    [AgentSessionSync.NativeMethods]::PostMessage($WindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Stop-AgentGracefully {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $processes = @(Get-AgentProcessTree $Agent)
    if (-not $processes) {
        Write-Host "[$($Agent.Name)] No running desktop process." -ForegroundColor DarkGray
        return
    }

    $knownIds = New-Object 'Collections.Generic.HashSet[int]'
    $postedWindows = New-Object 'Collections.Generic.HashSet[long]'
    foreach ($process in $processes) { [void]$knownIds.Add([int]$process.Id) }
    $windows = @(Get-AgentTopLevelWindows @($knownIds))
    foreach ($window in $windows) {
        if ($postedWindows.Add([long]$window)) {
            [void](Send-AgentCloseRequest $window)
        }
    }
    if ($windows) {
        Write-Host "[$($Agent.Name)] Requested close for $($windows.Count) top-level window(s); waiting for the complete process tree to exit..." -ForegroundColor Cyan
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 250
            $processes = @(Get-AgentProcessTree $Agent)
            foreach ($process in $processes) { [void]$knownIds.Add([int]$process.Id) }
            if (-not $processes) {
                Write-Host "[$($Agent.Name)] Complete process tree exited cleanly." -ForegroundColor Green
                return
            }
            foreach ($window in @(Get-AgentTopLevelWindows @($processes.Id))) {
                if ($postedWindows.Add([long]$window)) { [void](Send-AgentCloseRequest $window) }
            }
        } while ((Get-Date) -lt $deadline)
    } else {
        Write-Host "[$($Agent.Name)] No top-level window; terminating the registered process tree immediately." -ForegroundColor Yellow
    }

    Write-Warning "$($Agent.Name) still has registered app processes. Terminating the complete process tree."
    $forceDeadline = (Get-Date).AddSeconds(5)
    do {
        $processes = @(Get-AgentProcessTree $Agent)
        foreach ($process in $processes) { [void]$knownIds.Add([int]$process.Id) }
        $remaining = @($knownIds | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Sort-Object Id -Unique)
        if (-not $remaining -and -not $processes) { break }
        $forceIds = @(@($remaining | ForEach-Object Id) + @($processes | ForEach-Object Id) | Sort-Object -Unique)
        foreach ($processId in $forceIds) {
            Stop-AgentProcessTree $processId
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $forceDeadline)
    $processes = @(Get-AgentProcessTree $Agent)
    $remaining = @($knownIds | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($remaining -or $processes) {
        throw "$($Agent.Name) is still running after process-tree termination. Push was cancelled."
    }
    Write-Host "[$($Agent.Name)] Complete process tree terminated and verified." -ForegroundColor Yellow
}

function Assert-AllAgentsClosed {
    param([Parameter(Mandatory)][array]$Agents)
    foreach ($agent in $Agents) {
        if (Get-AgentProcessTree $agent) {
            throw "$($agent.Name) still has a registered app process tree. Push was cancelled."
        }
    }
}
