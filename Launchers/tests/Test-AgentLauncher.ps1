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
    $fakeProcess = [pscustomobject]@{
        Id = 4242
        MainWindowHandle = 123
        Path = $hiddenPackageProcess.Path
    }
    $script:closeRequestWindow = $null
    function Send-AgentCloseRequest {
        param([IntPtr]$WindowHandle)
        $script:closeRequestWindow = [long]$WindowHandle
        return $true
    }
    function Get-AgentProcessTree {
        if ($script:testProcessRunning) { @($fakeProcess) } else { @() }
    }
    function Get-AgentTopLevelWindows { @([IntPtr]123) }
    $closeRejected = $false
    try {
        Stop-AgentGracefully ([pscustomobject]@{ Name = 'TestAgent'; ProcessNames = @('TestAgent') }) 0
    } catch {
        $closeRejected = $_.Exception.Message -match 'without force-terminating'
    }
    if ($script:closeRequestWindow -ne 123) {
        throw 'The top-level window did not receive a close request.'
    }
    if (-not $closeRejected -or -not $script:testProcessRunning) {
        throw 'A lingering process was force-terminated instead of cancelling the operation.'
    }

    Write-Host "[PASS] Loaded $($agents.Count) agents, validated shortcuts, and rejected force termination." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
