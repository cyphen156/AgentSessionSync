#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AgentSessionIntegration-' + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED [#$($script:passed + 1)]: $Message" }
    $script:passed++
}

function Write-Utf8File([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Write-CodexRollout([string]$Path, [string]$Id, [string]$Timestamp) {
    $meta = [ordered]@{
        type = 'session_meta'
        payload = [ordered]@{ id = $Id; session_id = $Id; cwd = 'C:\Project\Demo' }
        timestamp = $Timestamp
    } | ConvertTo-Json -Compress
    $message = [ordered]@{ type = 'event_msg'; payload = [ordered]@{ type = 'message' }; timestamp = $Timestamp } | ConvertTo-Json -Compress
    Write-Utf8File $Path (($meta, $message) -join "`n")
}

function Write-ClaudeTranscript([string]$Path, [string]$Id, [string]$Timestamp, [string]$SecondId = '') {
    $records = @(
        ([ordered]@{ type = 'custom-title'; customTitle = 'demo'; sessionId = $Id } | ConvertTo-Json -Compress),
        ([ordered]@{ type = 'message'; sessionId = $Id; timestamp = $Timestamp } | ConvertTo-Json -Compress)
    )
    if ($SecondId) {
        $records += ([ordered]@{ type = 'message'; sessionId = $SecondId; timestamp = $Timestamp } | ConvertTo-Json -Compress)
    }
    Write-Utf8File $Path ($records -join "`n")
}

function Write-ClaudeEntry([string]$RegistryRoot, [string]$AppId, [string]$SessionId) {
    $entry = [ordered]@{
        sessionId = "local_$AppId"
        cliSessionId = $SessionId
        cwd = 'C:\Project\Demo'
        isArchived = $false
        title = 'demo'
    } | ConvertTo-Json
    Write-Utf8File (Join-Path $RegistryRoot "workspace\window\local_$AppId.json") $entry
}

function Get-FileTreeFingerprint([string[]]$Roots) {
    $rows = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $rows += "$rootFull|$relative|$sha"
        }
    }
    ($rows | Sort-Object) -join "`n"
}

function Get-TrackedVaultFingerprint([string]$RepoRoot) {
    $rows = @()
    foreach ($relative in @(& git -C $RepoRoot ls-files)) {
        if (-not $relative) { continue }
        $path = Join-Path $RepoRoot ($relative -replace '/', '\')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $rows += ($relative + '|' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)
        }
    }
    ($rows | Sort-Object) -join "`n"
}

function Invoke-ExpectedFailure([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-True $failed $Message
}

try {
    $repo = Join-Path $testRoot 'Vault'
    $remote = Join-Path $testRoot 'Remote.git'
    $codexHome = Join-Path $testRoot 'CodexHome'
    $claudeHome = Join-Path $testRoot 'ClaudeHome'
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    $env:APPDATA = Join-Path $testRoot 'Roaming'
    $registry = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    New-Item -ItemType Directory -Path $repo, $codexHome, $claudeHome, $env:LOCALAPPDATA, $registry -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launchers') -Destination (Join-Path $repo 'Launchers') -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.gitignore') -Destination (Join-Path $repo '.gitignore')
    # The sandbox denies both CIM and WMI process enumeration. Override only the
    # copied test launcher so Restore sees the intended "app is not running" state.
    Add-Content -LiteralPath (Join-Path $repo 'Launchers\AgentLauncher.Common.ps1') `
        -Value "`nfunction Get-SystemProcessSnapshot { @() }" -Encoding ASCII

    $config = @"
@{
    ClaudeHome = '$($claudeHome.Replace("'", "''"))'
    CodexHome = '$($codexHome.Replace("'", "''"))'
    ActiveWindowDays = 30
    TransportFileLimitBytes = 99614720
    SessionDataPushEnabled = `$true
    GracefulCloseTimeoutSeconds = 1
}
"@
    Write-Utf8File (Join-Path $repo 'AgentSessionSync.config.psd1') $config
    Write-Utf8File (Join-Path $repo 'ACTIVE_HOST.txt') "NONE`n"
    Write-Utf8File (Join-Path $repo 'Agents\Codex.psd1') "@{ Name='Codex'; AppId='Test.App'; ProcessNames=@('AgentSessionSyncNoSuchProcess'); Enabled=`$true; Order=10 }"

    $key = 'C--Project-Demo'
    $fresh = [DateTime]::UtcNow.ToString('o')
    $restoreId = '33333333-3333-4333-8333-333333333333'
    Write-CodexRollout (Join-Path $repo "Codex\archive\$key\2026\01\01\rollout-restore.jsonl") $restoreId '2026-01-01T00:00:00.000Z'

    & git -C $repo init -q
    & git -C $repo config user.email test@example.com
    & git -C $repo config user.name Test
    & git -C $repo add -A
    & git -C $repo commit -qm baseline
    & git init --bare -q $remote
    & git -C $repo remote add origin $remote
    & git -C $repo push -qu origin HEAD
    if ($LASTEXITCODE -ne 0) { throw 'test repository initialization failed' }

    $pull = Join-Path $repo 'Launchers\Pull-Sessions.ps1'
    $push = Join-Path $repo 'Launchers\Push-Sessions.ps1'
    $restore = Join-Path $repo 'Launchers\Restore-ArchivedSession.ps1'
    & $pull
    Assert-True ($LASTEXITCODE -eq 0) 'Start core succeeds against a local remote'

    $codexId = '11111111-1111-4111-8111-111111111111'
    $claudeId = '22222222-2222-4222-8222-222222222222'
    $claudeAppId = 'aaaa2222-2222-4222-8222-222222222222'
    Write-CodexRollout (Join-Path $codexHome 'sessions\2026\08\25\rollout-codex.jsonl') $codexId $fresh
    Write-ClaudeTranscript (Join-Path $claudeHome "projects\$key\$claudeId.jsonl") $claudeId $fresh
    Write-ClaudeEntry $registry $claudeAppId $claudeId

    $beforeCount = [int](& git -C $repo rev-list --count HEAD)
    & $push
    Assert-True ($LASTEXITCODE -eq 0) 'Finish core publishes both adapters'
    $afterCount = [int](& git -C $repo rev-list --count HEAD)
    Assert-True (($afterCount - $beforeCount) -eq 1) 'one Finish creates exactly one commit for both adapters'
    Assert-True (Test-Path -LiteralPath (Join-Path $repo "Codex\sessions\$key\2026\08\25\rollout-codex.jsonl")) 'Codex data is present in the published Vault tree'
    Assert-True (Test-Path -LiteralPath (Join-Path $repo "Claude\sessions\$key\$claudeId.jsonl")) 'Claude data is present in the same published Vault tree'

    $checkpointFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State') -File -Filter '*.json')
    Assert-True ($checkpointFiles.Count -eq 2) 'both adapter checkpoints are written'
    $head = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $checkpointCommits = @($checkpointFiles | ForEach-Object { [string]((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).commit) } | Sort-Object -Unique)
    Assert-True ($checkpointCommits.Count -eq 1 -and $checkpointCommits[0] -eq $head) 'both checkpoints reference the same published commit'

    function global:Start-Process { param([string]$FilePath, [object[]]$ArgumentList) }
    try { & $restore $restoreId -Agent Codex } finally { Remove-Item Function:\global:Start-Process -ErrorAction SilentlyContinue }
    Assert-True ($LASTEXITCODE -eq 0) 'one-agent Restore completes through the public launcher'
    $restoreHead = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $checkpointCommits = @($checkpointFiles | ForEach-Object { [string]((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).commit) } | Sort-Object -Unique)
    Assert-True ($checkpointCommits.Count -eq 1 -and $checkpointCommits[0] -eq $restoreHead) 'one-agent Restore advances both checkpoints together'

    $badCodexId = '44444444-4444-4444-8444-444444444444'
    $badClaudeId = '55555555-5555-4555-8555-555555555555'
    $otherClaudeId = '66666666-6666-4666-8666-666666666666'
    $badAppId = 'bbbb5555-5555-4555-8555-555555555555'
    $badCodexPath = Join-Path $codexHome 'sessions\2026\08\25\rollout-plan-failure.jsonl'
    $badClaudePath = Join-Path $claudeHome "projects\$key\$badClaudeId.jsonl"
    $badEntryPath = Join-Path $registry "workspace\window\local_$badAppId.json"
    Write-CodexRollout $badCodexPath $badCodexId $fresh
    Write-ClaudeTranscript $badClaudePath $badClaudeId $fresh $otherClaudeId
    Write-ClaudeEntry $registry $badAppId $badClaudeId
    $vaultBefore = Get-TrackedVaultFingerprint $repo
    $localBefore = Get-FileTreeFingerprint @($codexHome, $claudeHome, $registry, (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State'))
    $headBefore = ([string](& git -C $repo rev-parse HEAD)).Trim()
    Invoke-ExpectedFailure { & $push } 'a failing adapter plan aborts the whole Finish'
    Assert-True (([string](& git -C $repo rev-parse HEAD)).Trim() -eq $headBefore) 'plan failure creates no commit'
    Assert-True ((Get-TrackedVaultFingerprint $repo) -eq $vaultBefore) 'plan failure leaves the Vault unchanged'
    Assert-True ((Get-FileTreeFingerprint @($codexHome, $claudeHome, $registry, (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State'))) -eq $localBefore) 'plan failure leaves local state and checkpoints unchanged'
    Remove-Item -LiteralPath $badCodexPath, $badClaudePath, $badEntryPath -Force

    $applyCodexId = '77777777-7777-4777-8777-777777777777'
    $applyClaudeId = '88888888-8888-4888-8888-888888888888'
    $applyAppId = 'cccc8888-8888-4888-8888-888888888888'
    $blockedRelative = "Claude/sessions/$key/$applyClaudeId.jsonl/"
    Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Value $blockedRelative -Encoding UTF8
    & git -C $repo add .gitignore
    & git -C $repo commit -qm 'test: ignore blocked target directory'
    & git -C $repo push -q
    & $pull
    Assert-True ($LASTEXITCODE -eq 0) 'Start advances both checkpoints after an external Vault commit'

    Write-CodexRollout (Join-Path $codexHome 'sessions\2026\08\25\rollout-apply-failure.jsonl') $applyCodexId $fresh
    Write-ClaudeTranscript (Join-Path $claudeHome "projects\$key\$applyClaudeId.jsonl") $applyClaudeId $fresh
    Write-ClaudeEntry $registry $applyAppId $applyClaudeId
    $blockedTarget = Join-Path $repo "Claude\sessions\$key\$applyClaudeId.jsonl"
    New-Item -ItemType Directory -Path $blockedTarget -Force | Out-Null
    $vaultBefore = Get-TrackedVaultFingerprint $repo
    $localBefore = Get-FileTreeFingerprint @($codexHome, $claudeHome, $registry, (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State'))
    $headBefore = ([string](& git -C $repo rev-parse HEAD)).Trim()
    Invoke-ExpectedFailure { & $push } 'a Vault apply failure aborts before publish'
    Assert-True (([string](& git -C $repo rev-parse HEAD)).Trim() -eq $headBefore) 'apply failure creates no commit'
    Assert-True ((Get-TrackedVaultFingerprint $repo) -eq $vaultBefore) 'apply failure rolls back earlier Vault operations'
    Assert-True ((Get-FileTreeFingerprint @($codexHome, $claudeHome, $registry, (Join-Path $env:LOCALAPPDATA 'AgentSessionSync\State'))) -eq $localBefore) 'apply failure leaves all local state and checkpoints unchanged'
    Assert-True (-not (& git -C $repo status --porcelain)) 'apply failure leaves the tracked Vault worktree clean'

    Write-Host "[PASS] AgentSession integration: $passed assertions" -ForegroundColor Green
} finally {
    Remove-Item Function:\global:Start-Process -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
