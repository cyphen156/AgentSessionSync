#requires -Version 5.1
<#
.SYNOPSIS
  Record Codex session visibility diagnostics and repair compatible missing threads.
.DESCRIPTION
  Session transport intentionally does not copy Codex SQLite state. This script records
  enough machine-local evidence to diagnose visibility failures after Codex updates.
  When the newest usable Codex CLI is not older than the restored rollout format, it
  asks app-server to read only index entries missing from its state-backed thread list.

  Diagnostics never contain conversation bodies. Failures are logged and reported as
  warnings so session Pull remains usable even when Codex changes its local protocol.
#>
[CmdletBinding()]
param(
    [string] $CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\Logs'),
    [int] $Limit = 1000,
    [int] $TimeoutSeconds = 20,
    [int] $MaxRepairAttempts = 200,
    [int] $MaxLogFiles = 30,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$process = $null
$selectedProbe = $null
$indexIds = @{}
$protocolNoise = New-Object System.Collections.ArrayList

$report = [ordered]@{
    schemaVersion = 1
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $null
    host = $env:COMPUTERNAME
    status = 'started'
    codexHome = $CodexHome
    logDirectory = $LogDirectory
    maxLogFiles = $MaxLogFiles
    appPackages = @()
    cliCandidates = @()
    selectedCli = $null
    inventory = [ordered]@{
        rolloutFiles = 0
        invalidRolloutHeaders = 0
        rolloutCliVersions = @{}
        newestRolloutCliVersion = $null
        indexEntries = 0
    }
    visibility = [ordered]@{
        stateThreadsBefore = $null
        missingBefore = @()
        repairAttempted = 0
        repairSucceeded = @()
        repairFailed = @()
        stateThreadsAfter = $null
        missingAfter = @()
    }
    appServer = [ordered]@{
        initializeError = $null
        stderr = $null
        protocolNoise = @()
    }
    errors = @()
}

function Add-DiagnosticError([string] $Stage, [string] $Message) {
    $script:report.errors += [ordered]@{
        stage = $Stage
        message = $Message
    }
}

function ConvertTo-CoreVersion([string] $Text) {
    if ($Text -match '(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)') {
        return [version]::new(
            [int]$Matches.major,
            [int]$Matches.minor,
            [int]$Matches.patch
        )
    }
    return $null
}

function New-CodexProcessStartInfo([string] $Path, [string] $Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($Path) -ieq '.cmd') {
        $info.FileName = 'cmd.exe'
        $info.Arguments = '/d /s /c ""{0}" {1}"' -f $Path, $Arguments
    } else {
        $info.FileName = $Path
        $info.Arguments = $Arguments
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return $info
}

function Invoke-VersionProbe([string] $Path, [string] $Source) {
    $result = [ordered]@{
        path = $Path
        source = $Source
        usable = $false
        versionText = $null
        versionCore = $null
        error = $null
    }
    $versionObject = $null
    $probeProcess = $null
    try {
        $info = New-CodexProcessStartInfo $Path '--version'
        $probeProcess = New-Object System.Diagnostics.Process
        $probeProcess.StartInfo = $info
        $null = $probeProcess.Start()
        if (-not $probeProcess.WaitForExit(5000)) {
            $probeProcess.Kill()
            throw 'Version probe timed out.'
        }
        $stdout = $probeProcess.StandardOutput.ReadToEnd().Trim()
        $stderr = $probeProcess.StandardError.ReadToEnd().Trim()
        $text = if ($stdout) { $stdout } else { $stderr }
        if ($probeProcess.ExitCode -ne 0) {
            throw "Version probe exit code $($probeProcess.ExitCode): $text"
        }
        $versionObject = ConvertTo-CoreVersion $text
        if (-not $versionObject) {
            throw "Unable to parse version output: $text"
        }
        $result.usable = $true
        $result.versionText = $text
        $result.versionCore = $versionObject.ToString()
    }
    catch {
        $result.error = $_.Exception.Message
    }
    finally {
        if ($probeProcess) { $probeProcess.Dispose() }
    }
    return [pscustomobject]@{
        Report = $result
        VersionObject = $versionObject
    }
}

function Read-AppServerResponse([int] $RequestId) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $script:process.HasExited) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $script:process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "Timed out waiting for Codex app-server response id=$RequestId."
        }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $message = $line | ConvertFrom-Json
        }
        catch {
            if ($protocolNoise.Count -lt 20) { $null = $protocolNoise.Add($line) }
            continue
        }
        if ($message.id -eq $RequestId) { return $message }
    }
    throw "Codex app-server exited before response id=$RequestId."
}

function Get-ThreadIdsFromListResponse($Response) {
    $ids = @{}
    foreach ($thread in @($Response.result.data)) {
        if ($thread.id) { $ids[[string]$thread.id] = $true }
    }
    return $ids
}

try {
    $sessionsRoot = Join-Path $CodexHome 'sessions'
    $rolloutFiles = @(
        Get-ChildItem -LiteralPath $sessionsRoot -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue
    )
    $report.inventory.rolloutFiles = $rolloutFiles.Count

    $rolloutVersionCounts = @{}
    $newestRolloutVersion = $null
    foreach ($file in $rolloutFiles) {
        $reader = $null
        try {
            $reader = New-Object IO.StreamReader($file.FullName, [Text.Encoding]::UTF8, $true)
            $firstLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($firstLine)) {
                $report.inventory.invalidRolloutHeaders++
                continue
            }
            $first = $firstLine | ConvertFrom-Json
            if ($first.type -ne 'session_meta') {
                $report.inventory.invalidRolloutHeaders++
                continue
            }
            $cliVersion = [string]$first.payload.cli_version
            if ($cliVersion) {
                if (-not $rolloutVersionCounts.ContainsKey($cliVersion)) {
                    $rolloutVersionCounts[$cliVersion] = 0
                }
                $rolloutVersionCounts[$cliVersion]++
                $core = ConvertTo-CoreVersion $cliVersion
                if ($core -and (-not $newestRolloutVersion -or $core -gt $newestRolloutVersion)) {
                    $newestRolloutVersion = $core
                }
            }
        }
        catch {
            $report.inventory.invalidRolloutHeaders++
        }
        finally {
            if ($reader) { $reader.Dispose() }
        }
    }
    $report.inventory.rolloutCliVersions = $rolloutVersionCounts
    if ($newestRolloutVersion) {
        $report.inventory.newestRolloutCliVersion = $newestRolloutVersion.ToString()
    }

    $indexPath = Join-Path $CodexHome 'session_index.jsonl'
    if (Test-Path -LiteralPath $indexPath) {
        foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.id) { $indexIds[[string]$entry.id] = $true }
            }
            catch {
                Add-DiagnosticError 'index-parse' $_.Exception.Message
            }
        }
    }
    $report.inventory.indexEntries = $indexIds.Count

    $candidatePaths = [ordered]@{}
    try {
        foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
            $report.appPackages += [ordered]@{
                name = $package.Name
                version = [string]$package.Version
                packageFullName = $package.PackageFullName
                installLocation = $package.InstallLocation
            }
            foreach ($relativePath in @('app\resources\codex.exe', 'app\resources\codex')) {
                $candidate = Join-Path $package.InstallLocation $relativePath
                if (Test-Path -LiteralPath $candidate) {
                    $candidatePaths[$candidate] = 'app-package'
                }
            }
        }
    }
    catch {
        Add-DiagnosticError 'app-package-discovery' $_.Exception.Message
    }

    foreach ($command in @(Get-Command codex -All -ErrorAction SilentlyContinue)) {
        $path = [string]$command.Path
        if (-not $path) { continue }
        $extension = [IO.Path]::GetExtension($path)
        if ($extension -in @('.exe', '.cmd')) {
            if (-not $candidatePaths.Contains($path)) {
                $candidatePaths[$path] = 'path'
            }
        }
    }

    foreach ($candidate in $candidatePaths.GetEnumerator()) {
        $probe = Invoke-VersionProbe ([string]$candidate.Key) ([string]$candidate.Value)
        $report.cliCandidates += $probe.Report
        if ($probe.Report.usable -and
            (-not $selectedProbe -or $probe.VersionObject -gt $selectedProbe.VersionObject)) {
            $selectedProbe = $probe
        }
    }

    if ($selectedProbe) {
        $report.selectedCli = $selectedProbe.Report
    }

    if ($indexIds.Count -eq 0) {
        $report.status = 'no-index'
    }
    elseif (-not $selectedProbe) {
        $report.status = 'no-compatible-cli'
    }
    elseif ($newestRolloutVersion -and $selectedProbe.VersionObject -lt $newestRolloutVersion) {
        $report.status = 'version-mismatch'
        Add-DiagnosticError 'version-gate' (
            "Selected CLI $($selectedProbe.Report.versionCore) is older than rollout $($newestRolloutVersion.ToString())."
        )
    }
    else {
        $startInfo = New-CodexProcessStartInfo ([string]$selectedProbe.Report.path) 'app-server'
        $startInfo.RedirectStandardInput = $true
        $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome
        $startInfo.EnvironmentVariables['CODEX_SQLITE_HOME'] = $CodexHome

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()

        $initialize = @{
            id = 1
            method = 'initialize'
            params = @{
                clientInfo = @{
                    name = 'AgentSessionSync'
                    title = 'AgentSessionSync Codex visibility diagnostics'
                    version = '2.0.0'
                }
                capabilities = @{}
            }
        } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($initialize)

        $initializeResponse = Read-AppServerResponse 1
        if ($initializeResponse.error) {
            $report.appServer.initializeError = [string]$initializeResponse.error.message
            throw "Codex app-server initialize failed: $($initializeResponse.error.message)"
        }
        $process.StandardInput.WriteLine((@{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress))

        $beforeRequest = @{
            id = 2
            method = 'thread/list'
            params = @{
                limit = $Limit
                archived = $false
                useStateDbOnly = $true
                sortKey = 'updated_at'
                sortDirection = 'desc'
            }
        } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($beforeRequest)
        $beforeResponse = Read-AppServerResponse 2
        if ($beforeResponse.error) {
            throw "Codex state-only thread/list failed: $($beforeResponse.error.message)"
        }

        $beforeIds = Get-ThreadIdsFromListResponse $beforeResponse
        $report.visibility.stateThreadsBefore = $beforeIds.Count
        $missingBefore = @($indexIds.Keys | Where-Object { -not $beforeIds.ContainsKey($_) } | Sort-Object)
        $report.visibility.missingBefore = $missingBefore

        $requestId = 10
        foreach ($threadId in @($missingBefore | Select-Object -First $MaxRepairAttempts)) {
            $report.visibility.repairAttempted++
            $readRequest = @{
                id = $requestId
                method = 'thread/read'
                params = @{
                    threadId = $threadId
                    includeTurns = $false
                }
            } | ConvertTo-Json -Compress -Depth 8
            $process.StandardInput.WriteLine($readRequest)
            try {
                $readResponse = Read-AppServerResponse $requestId
                if ($readResponse.error) {
                    $report.visibility.repairFailed += [ordered]@{
                        id = $threadId
                        code = $readResponse.error.code
                        message = [string]$readResponse.error.message
                    }
                } else {
                    $report.visibility.repairSucceeded += $threadId
                }
            }
            catch {
                $report.visibility.repairFailed += [ordered]@{
                    id = $threadId
                    code = $null
                    message = $_.Exception.Message
                }
            }
            $requestId++
        }

        $afterRequestId = $requestId + 1
        $afterRequest = @{
            id = $afterRequestId
            method = 'thread/list'
            params = @{
                limit = $Limit
                archived = $false
                useStateDbOnly = $true
                sortKey = 'updated_at'
                sortDirection = 'desc'
            }
        } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($afterRequest)
        $afterResponse = Read-AppServerResponse $afterRequestId
        if ($afterResponse.error) {
            throw "Codex post-repair thread/list failed: $($afterResponse.error.message)"
        }

        $afterIds = Get-ThreadIdsFromListResponse $afterResponse
        $report.visibility.stateThreadsAfter = $afterIds.Count
        $missingAfter = @($indexIds.Keys | Where-Object { -not $afterIds.ContainsKey($_) } | Sort-Object)
        $report.visibility.missingAfter = $missingAfter
        $report.status = if ($missingAfter.Count -eq 0) { 'complete' } else { 'partial' }
    }
}
catch {
    if ($report.status -eq 'started') { $report.status = 'failed' }
    Add-DiagnosticError 'top-level' $_.Exception.Message
}
finally {
    if ($process) {
        try {
            if (-not $process.HasExited) {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(5000)) { $process.Kill() }
            }
            $stderr = $process.StandardError.ReadToEnd().Trim()
            if ($stderr) { $report.appServer.stderr = $stderr }
        }
        catch {
            Add-DiagnosticError 'app-server-shutdown' $_.Exception.Message
        }
        finally {
            $process.Dispose()
        }
    }
    $report.appServer.protocolNoise = @($protocolNoise)
    $report.finishedAtUtc = [DateTime]::UtcNow.ToString('o')

    try {
        New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $safeHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
        $logPath = Join-Path $LogDirectory ("Pull-{0}-{1}.json" -f $safeHost, $stamp)
        $json = $report | ConvertTo-Json -Depth 12
        $utf8NoBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($logPath, $json + "`n", $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $LogDirectory 'latest.json'), $json + "`n", $utf8NoBom)
        if ($MaxLogFiles -gt 0) {
            $expiredLogs = @(
                Get-ChildItem -LiteralPath $LogDirectory -Filter 'Pull-*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip $MaxLogFiles
            )
            foreach ($expiredLog in $expiredLogs) {
                Remove-Item -LiteralPath $expiredLog.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $Quiet) {
            Write-Host "[codex-visibility] status=$($report.status) log=$logPath" -ForegroundColor DarkCyan
        }
        if ($report.status -notin @('complete', 'no-index')) {
            Write-Warning "Codex visibility is not fully repaired (status=$($report.status)). Diagnostic log: $logPath"
        }
    }
    catch {
        Write-Warning "Unable to write Codex visibility diagnostic log: $($_.Exception.Message)"
    }
}

$global:LASTEXITCODE = 0
