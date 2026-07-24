#requires -Version 5.1
<#
.SYNOPSIS
  Ask the installed Codex app-server to rescan rollout JSONL files and repair its local thread DB.
.DESCRIPTION
  Session transport intentionally does not copy state_*.sqlite. After restored JSONL files are in
  place, thread/list with useStateDbOnly=false is Codex's compatibility path for discovering them.
  Failure is reported as a warning so a Codex update cannot make session Pull fail completely.
#>
[CmdletBinding()]
param(
    [int] $Limit = 1000,
    [int] $TimeoutSeconds = 20,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Warning 'Codex CLI was not found; skipped thread visibility repair.'
    exit 0
}

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = 'cmd.exe'
$startInfo.Arguments = '/d /s /c "codex app-server"'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$null = $process.Start()

function Read-AppServerResponse([int] $RequestId) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "Timed out waiting for Codex app-server response id=$RequestId."
        }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($message.id -eq $RequestId) { return $message }
    }
    throw "Codex app-server exited before response id=$RequestId."
}

try {
    $initialize = @{
        id = 1
        method = 'initialize'
        params = @{
            clientInfo = @{
                name = 'AgentSessionSync'
                title = 'AgentSessionSync Codex visibility repair'
                version = '1.0.0'
            }
            capabilities = @{}
        }
    } | ConvertTo-Json -Compress -Depth 8
    $process.StandardInput.WriteLine($initialize)

    $initializeResponse = Read-AppServerResponse 1
    if ($initializeResponse.error) {
        throw "Codex app-server initialize failed: $($initializeResponse.error.message)"
    }

    $process.StandardInput.WriteLine((@{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress))
    $listRequest = @{
        id = 2
        method = 'thread/list'
        params = @{
            limit = $Limit
            archived = $false
            useStateDbOnly = $false
            sortKey = 'updated_at'
            sortDirection = 'desc'
        }
    } | ConvertTo-Json -Compress -Depth 8
    $process.StandardInput.WriteLine($listRequest)

    $listResponse = Read-AppServerResponse 2
    if ($listResponse.error) {
        throw "Codex thread/list failed: $($listResponse.error.message)"
    }
    $threadCount = @($listResponse.result.data).Count
    if (-not $Quiet) {
        Write-Host "[codex-visibility] scan-and-repair complete: $threadCount interactive thread(s)" -ForegroundColor DarkCyan
    }
}
catch {
    Write-Warning "Codex thread visibility repair skipped: $($_.Exception.Message)"
}
finally {
    if (-not $process.HasExited) {
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
        }
    }
    $process.Dispose()
}

$global:LASTEXITCODE = 0
