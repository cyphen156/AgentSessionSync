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

function Send-AgentCloseRequests {
    <#
      Posts WM_CLOSE to every top-level window the given processes own, skipping handles
      that were already asked once. Returns how many windows those processes own now.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ProcessIds,
        [Parameter(Mandatory)]$PostedWindows
    )
    if (-not $ProcessIds) { return 0 }
    $windows = @(Get-AgentTopLevelWindows $ProcessIds)
    foreach ($window in $windows) {
        if ($PostedWindows.Add([long]$window)) { [void](Send-AgentCloseRequest $window) }
    }
    $windows.Count
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

    # A PID identifies a process only while that process is alive. Windows reuses freed
    # PIDs right away and this function frees dozens at once, so a remembered id can name
    # an unrelated process moments later — killing it, or making the final check report a
    # still-running agent and cancel a push that should have succeeded. Every decision
    # below therefore re-enumerates the tree, which re-validates process name and the
    # WindowsApps path each time, and no id outlives the iteration that observed it.
    $postedWindows = New-Object 'Collections.Generic.HashSet[long]'
    $windowCount = Send-AgentCloseRequests -ProcessIds @($processes | ForEach-Object Id) -PostedWindows $postedWindows
    if ($windowCount -gt 0) {
        Write-Host "[$($Agent.Name)] Requested close for $windowCount top-level window(s); waiting for the complete process tree to exit..." -ForegroundColor Cyan
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 250
            $processes = @(Get-AgentProcessTree $Agent)
            if (-not $processes) {
                Write-Host "[$($Agent.Name)] Complete process tree exited cleanly." -ForegroundColor Green
                return
            }
            # A tray app can open a window after the first request; ask the new ones too.
            [void](Send-AgentCloseRequests -ProcessIds @($processes | ForEach-Object Id) -PostedWindows $postedWindows)
        } while ((Get-Date) -lt $deadline)
    } else {
        Write-Host "[$($Agent.Name)] No top-level window; terminating the registered process tree immediately." -ForegroundColor Yellow
    }

    Write-Warning "$($Agent.Name) still has registered app processes. Terminating the complete process tree."
    $forceDeadline = (Get-Date).AddSeconds(5)
    do {
        $processes = @(Get-AgentProcessTree $Agent)
        if (-not $processes) { break }
        foreach ($processId in @($processes | ForEach-Object Id)) {
            Stop-AgentProcessTree $processId
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $forceDeadline)
    if (Get-AgentProcessTree $Agent) {
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
