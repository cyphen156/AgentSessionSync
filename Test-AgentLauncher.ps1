#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'AgentLauncher.Common.ps1')
$agents = @(Get-RegisteredAgents $repoRoot)
if (-not $agents) { throw 'No enabled agents were loaded.' }
if (($agents | Group-Object Name | Where-Object Count -gt 1)) { throw 'Duplicate agent names found.' }
if (($agents | Group-Object ProcessName | Where-Object Count -gt 1)) { throw 'Duplicate process names found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AgentLauncher-Test-" + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $repoRoot 'Create-Shortcuts.ps1') -OutputDirectory $testRoot
    $links = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.lnk' -File)
    if ($links.Count -ne 2) { throw "Expected two shortcuts, found $($links.Count)." }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in @('Start','Finish')) {
        $link = Join-Path $testRoot "$name.lnk"
        $shortcut = $shell.CreateShortcut($link)
        if ($shortcut.TargetPath -notlike '*\cmd.exe') { throw "Invalid target: $link" }
        if ($shortcut.Arguments -notmatch "$name\.cmd") { throw "Invalid arguments: $link" }
    }
    Write-Host "[PASS] Loaded $($agents.Count) agents and validated Start/Finish shortcuts without launching apps." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
