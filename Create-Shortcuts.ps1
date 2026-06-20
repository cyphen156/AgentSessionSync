#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'Shortcuts'))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$shell = New-Object -ComObject WScript.Shell
$items = @(
    @{ Name='Start'; Icon="$env:SystemRoot\System32\shell32.dll,137" },
    @{ Name='Finish'; Icon="$env:SystemRoot\System32\shell32.dll,131" }
)
foreach ($item in $items) {
    $cmdPath = Join-Path $PSScriptRoot "$($item.Name).cmd"
    $shortcutPath = Join-Path $OutputDirectory "$($item.Name).lnk"
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\cmd.exe"
    $shortcut.Arguments = "/c `"$cmdPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = $item.Icon
    $shortcut.Description = "$($item.Name) all registered AI agents and session sync"
    $shortcut.Save()
    Write-Host "Created: $shortcutPath"
}
