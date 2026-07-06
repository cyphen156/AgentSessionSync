#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& git -C $repoRoot rev-parse --verify HEAD 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Commit this repository before running the integration test.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AgentSessionSync-Test-" + [guid]::NewGuid().ToString('N'))
$remote = Join-Path $testRoot 'remote.git'
$hostA = Join-Path $testRoot 'HostA'
$hostB = Join-Path $testRoot 'HostB'
$profileA = Join-Path $testRoot 'ProfileA'
$profileB = Join-Path $testRoot 'ProfileB'
$projectA = Join-Path $testRoot 'Projects\DemoA'
$projectB = Join-Path $testRoot 'Projects\DemoB'
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA

function Write-TestConfig([string]$Repo, [string]$Project, [string]$Profile) {
    $p = $Project.Replace("'", "''")
    $c = (Join-Path $Profile '.claude').Replace("'", "''")
    $x = (Join-Path $Profile '.codex').Replace("'", "''")
    $body = "@{`n ProjectRoot='$p'`n SyncProjectGit=`$false`n IncludeClaudeWorktrees=`$true`n ClaudeHome='$c'`n CodexHome='$x'`n SessionDataPushEnabled=`$true`n}`n"
    [IO.File]::WriteAllText((Join-Path $Repo 'AgentSessionSync.config.psd1'), $body, (New-Object Text.UTF8Encoding($true)))
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot, $projectA, $projectB | Out-Null
    $env:APPDATA = Join-Path $profileA 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileA 'AppData\Local'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
    & git clone --bare $repoRoot $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create temporary bare remote.' }
    & git clone $remote $hostA | Out-Null
    & git clone $remote $hostB | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create test clones.' }

    Write-TestConfig $hostA $projectA $profileA
    Write-TestConfig $hostB $projectB $profileB
    . (Join-Path $hostA 'Launchers\AgentSessionSync.Common.ps1')
    $keyA = ConvertTo-ClaudeProjectKey $projectA
    $keyB = ConvertTo-ClaudeProjectKey $projectB

    $claudeA = Join-Path $profileA ".claude\projects\$keyA"
    $codexA = Join-Path $profileA '.codex\sessions\2026\06\20'
    New-Item -ItemType Directory -Force -Path $claudeA, $codexA | Out-Null
    '{"type":"user","message":"portable claude test"}' | Set-Content -LiteralPath (Join-Path $claudeA 'claude-test.jsonl') -Encoding UTF8
    '{"type":"event_msg","payload":{"type":"user_message","message":"portable codex test"}}' | Set-Content -LiteralPath (Join-Path $codexA 'rollout-test.jsonl') -Encoding UTF8

    & (Join-Path $hostA 'Launchers\Push-Sessions.ps1') -ForceOwnership
    if ($LASTEXITCODE -ne 0) { throw 'Host A push failed.' }
    $env:APPDATA = Join-Path $profileB 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileB 'AppData\Local'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
    & (Join-Path $hostB 'Launchers\Pull-Sessions.ps1') -Force
    if ($LASTEXITCODE -ne 0) { throw 'Host B pull failed.' }

    $claudeExpected = Join-Path $profileB ".claude\projects\$keyB\claude-test.jsonl"
    # Different project roots intentionally verify path-neutral remapping.
    $transportedClaude = Get-Item -LiteralPath $claudeExpected -ErrorAction SilentlyContinue
    $transportedCodex = Get-ChildItem (Join-Path $profileB '.codex\sessions') -Filter 'rollout-test.jsonl' -Recurse -File -ErrorAction SilentlyContinue
    if (-not $transportedClaude) { throw "Claude session was not restored (expected transport under $claudeExpected)." }
    if (-not $transportedCodex) { throw 'Codex session was not restored.' }
    Write-Host '[PASS] Temporary two-clone Claude/Codex round trip succeeded.' -ForegroundColor Green
}
finally {
    $env:APPDATA = $oldAppData
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
