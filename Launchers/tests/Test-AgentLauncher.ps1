#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$launchers = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $launchers
. (Join-Path $launchers 'AgentLauncher.Common.ps1')
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents were loaded.' }
if (($agents | Group-Object Name | Where-Object Count -gt 1)) { throw 'Duplicate agent names found.' }
$processNames = @($agents | ForEach-Object { $_.ProcessNames })
if (($processNames | Group-Object | Where-Object Count -gt 1)) { throw 'Duplicate process names found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AgentLauncher-Test-" + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $launchers 'Create-Shortcuts.ps1') -OutputDirectory $testRoot
    $links = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.lnk' -File)
    if ($links.Count -ne 2) { throw "Expected two shortcuts, found $($links.Count)." }
    $shell = New-Object -ComObject WScript.Shell
    $expected = [ordered]@{
        'AgentSession-Start'   = 'Start.ps1'
        'AgentSession-Finish'  = 'Finish.ps1'
    }
    foreach ($name in $expected.Keys) {
        $link = Join-Path $testRoot "$name.lnk"
        if (-not (Test-Path -LiteralPath $link)) { throw "Missing shortcut: $link" }
        $shortcut = $shell.CreateShortcut($link)
        if ($shortcut.TargetPath -notlike '*\cmd.exe') { throw "Invalid target: $link" }
        if ($shortcut.Arguments -notmatch [regex]::Escape($expected[$name])) { throw "Invalid arguments: $link" }
    }

    $hiddenPackageProcess = [pscustomobject]@{
        Id = 4242
        MainWindowHandle = 0
        Path = 'C:\Program Files\WindowsApps\Example.Agent_1.0.0.0_x64__test\Agent.exe'
    }
    $cliProcess = [pscustomobject]@{
        Id = 4243
        MainWindowHandle = 0
        Path = 'C:\Tools\agent.exe'
    }
    if (-not (Test-AgentDesktopProcess $hiddenPackageProcess)) {
        throw 'A hidden packaged desktop process was not recognized.'
    }
    if (Test-AgentDesktopProcess $cliProcess) {
        throw 'A windowless non-packaged CLI process was incorrectly recognized as a desktop app.'
    }

    $script:testProcessRunning = $true
    $script:fallbackProcessId = $null
    $fakeProcess = [pscustomobject]@{
        Id = 4242
        MainWindowHandle = 0
        Path = $hiddenPackageProcess.Path
    }
    function Get-AgentDesktopProcesses { @($fakeProcess) }
    function Get-RunningProcessesById {
        if ($script:testProcessRunning) { @($fakeProcess) } else { @() }
    }
    function Stop-AgentProcessTree {
        param([int]$ProcessId)
        $script:fallbackProcessId = $ProcessId
        $script:testProcessRunning = $false
    }
    Stop-AgentGracefully ([pscustomobject]@{ Name = 'TestAgent'; ProcessNames = @('TestAgent') }) 0
    if ($script:fallbackProcessId -ne 4242) {
        throw 'The lingering hidden desktop process did not use the process-tree fallback.'
    }

    Write-Host "[PASS] Loaded $($agents.Count) agents, validated shortcuts, and covered lingering desktop-process shutdown without launching apps." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
