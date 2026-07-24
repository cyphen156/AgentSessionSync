#requires -Version 5.1
# Generate machine-local taskbar-pinnable .lnk shortcuts for this tool's commands.
[CmdletBinding()]
param([string] $OutputDirectory = '')

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'Shortcuts' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Get-ChildItem -LiteralPath $OutputDirectory -Filter *.lnk -ErrorAction SilentlyContinue | Remove-Item -Force
$shell = New-Object -ComObject WScript.Shell

$items = @(
    @{ Name = 'AgentSession-Start';   Script = 'Start.ps1';                        Icon = '137'; Desc = 'AgentSessionSync: pull sessions and launch agents' }
    @{ Name = 'AgentSession-Finish';  Script = 'Finish.ps1';                       Icon = '131'; Desc = 'AgentSessionSync: close agents and push sessions' }
)

foreach ($item in $items) {
    $scriptPath = Join-Path $PSScriptRoot $item.Script
    $shortcutPath = Join-Path $OutputDirectory "$($item.Name).lnk"
    $sc = $shell.CreateShortcut($shortcutPath)
    $sc.TargetPath = "$env:SystemRoot\System32\cmd.exe"
    $sc.Arguments = "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" & timeout /t 30"
    $sc.WorkingDirectory = $RepoRoot
    $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,$($item.Icon)"
    $sc.Description = $item.Desc
    $sc.Save()
    Write-Host "Created: $shortcutPath"
}

Write-Host ""
Write-Host "Pin the .lnk files in '$OutputDirectory' to the taskbar for one-click access." -ForegroundColor Cyan
