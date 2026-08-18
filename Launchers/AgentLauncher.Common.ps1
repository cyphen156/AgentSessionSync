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

function Get-AgentWindowProcesses {
    param([Parameter(Mandatory)][string[]]$ProcessNames)
    @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 })
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

function Get-AgentDesktopProcesses {
    param([Parameter(Mandatory)][string[]]$ProcessNames)
    @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue |
        Where-Object { Test-AgentDesktopProcess $_ } |
        Sort-Object Id -Unique)
}

function Get-RunningProcessesById {
    param([Parameter(Mandatory)][int[]]$ProcessIds)
    @($ProcessIds | ForEach-Object {
        Get-Process -Id $_ -ErrorAction SilentlyContinue
    })
}

function Stop-AgentProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $taskkill /PID $ProcessId /T /F | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        throw "Failed to terminate process tree rooted at PID $ProcessId (taskkill exit code $LASTEXITCODE)."
    }
}

function Stop-AgentGracefully {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $processes = @(Get-AgentDesktopProcesses $Agent.ProcessNames)
    if (-not $processes) {
        Write-Host "[$($Agent.Name)] No running desktop process." -ForegroundColor DarkGray
        return
    }
    $processIds = @($processes.Id)
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            Write-Host "[$($Agent.Name)] Requesting graceful close (PID $($process.Id))..." -ForegroundColor Cyan
            $null = $process.CloseMainWindow()
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-RunningProcessesById $processIds)
    } while ($remaining -and (Get-Date) -lt $deadline)
    if ($remaining) {
        $remainingIds = @($remaining.Id)
        Write-Warning "$($Agent.Name) still has $($remainingIds.Count) process(es) after $TimeoutSeconds seconds. Terminating its registered desktop process tree."
        foreach ($processId in $remainingIds) {
            Stop-AgentProcessTree $processId
        }
        $forceDeadline = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 250
            $remaining = @(Get-RunningProcessesById $processIds)
        } while ($remaining -and (Get-Date) -lt $forceDeadline)
        if ($remaining) {
            throw "$($Agent.Name) is still running after process-tree termination. Push was cancelled."
        }
        Write-Host "[$($Agent.Name)] Closed with process-tree fallback." -ForegroundColor Yellow
        return
    }
    Write-Host "[$($Agent.Name)] Closed cleanly." -ForegroundColor Green
}

function Assert-AllAgentsClosed {
    param([Parameter(Mandatory)][array]$Agents)
    foreach ($agent in $Agents) {
        if (Get-AgentDesktopProcesses $agent.ProcessNames) {
            throw "$($agent.Name) still has a running desktop process. Push was cancelled."
        }
    }
}
