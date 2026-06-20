#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RegisteredAgents {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $agentsRoot = Join-Path $RepoRoot 'Agents'
    $agents = foreach ($file in Get-ChildItem -LiteralPath $agentsRoot -Filter '*.psd1' -File) {
        $item = Import-PowerShellDataFile -LiteralPath $file.FullName
        if (-not $item.Name -or -not $item.AppId -or -not $item.ProcessName) {
            throw "Invalid agent definition: $($file.FullName)"
        }
        if ($item.Enabled) {
            [pscustomobject]@{
                Name = [string]$item.Name
                AppId = [string]$item.AppId
                ProcessName = [string]$item.ProcessName
                Order = [int]$item.Order
            }
        }
    }
    @($agents | Sort-Object Order, Name)
}

function Get-AgentWindowProcesses {
    param([Parameter(Mandatory)][string]$ProcessName)
    @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 })
}

function Stop-AgentGracefully {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $windows = @(Get-AgentWindowProcesses $Agent.ProcessName)
    if (-not $windows) {
        Write-Host "[$($Agent.Name)] No open desktop window." -ForegroundColor DarkGray
        return
    }
    foreach ($process in $windows) {
        Write-Host "[$($Agent.Name)] Requesting graceful close (PID $($process.Id))..." -ForegroundColor Cyan
        $null = $process.CloseMainWindow()
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-AgentWindowProcesses $Agent.ProcessName)
    } while ($remaining -and (Get-Date) -lt $deadline)
    if ($remaining) {
        throw "$($Agent.Name) did not close within $TimeoutSeconds seconds. Push was cancelled; no force kill was used."
    }
    Write-Host "[$($Agent.Name)] Closed cleanly." -ForegroundColor Green
}

function Assert-AllAgentsClosed {
    param([Parameter(Mandatory)][array]$Agents)
    foreach ($agent in $Agents) {
        if (Get-AgentWindowProcesses $agent.ProcessName) {
            throw "$($agent.Name) is still open. Push was cancelled."
        }
    }
}
