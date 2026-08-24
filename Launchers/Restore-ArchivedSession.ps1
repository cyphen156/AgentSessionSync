#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Query = '',
    [switch]$All
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
. (Join-Path $PSScriptRoot 'CodexSessionState.Common.ps1')
. (Join-Path $PSScriptRoot 'AgentLauncher.Common.ps1')
$Config = Get-AgentSessionSyncConfig $RepoRoot

$retriedPendingCommit = Prepare-AgentSessionVaultMutation -RepoRoot $RepoRoot
if ($retriedPendingCommit) {
    $subject = [string](& git -C $RepoRoot log -1 --pretty=%s)
    if ($subject -notlike 'sessions: restore *') {
        throw '미전송 commit을 Push했지만 Restore commit이 아닙니다. 원래 Finish 작업을 먼저 완료하세요.'
    }
    $codexAgent = @((Get-RegisteredAgents $RepoRoot) | Where-Object Name -eq 'Codex' | Select-Object -First 1)
    if (-not $codexAgent) { throw 'Enabled Codex agent definition이 없습니다.' }
    Assert-CurrentProcessOutsideAgentTrees $codexAgent
    Stop-AgentGracefully -Agent $codexAgent[0] -TimeoutSeconds ([int]$Config.GracefulCloseTimeoutSeconds)
    Assert-AllAgentsClosed $codexAgent
    [void](Invoke-CodexStartState -RepoRoot $RepoRoot -Config $Config)
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($codexAgent[0].AppId)"
    Write-Host '[OK] 이전 Restore commit을 Push하고 로컬 배치와 앱 재실행을 완료했습니다.' -ForegroundColor Green
    return
}

$entries = @()
$claudeArchiveRoot = Join-Path $RepoRoot 'Claude\archive'
if (Test-Path -LiteralPath $claudeArchiveRoot) {
    $root = [IO.Path]::GetFullPath($claudeArchiveRoot).TrimEnd('\', '/')
    $entries += @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Agent = 'Claude'
                SessionId = $_.BaseName
                Folder = (Split-Path -Parent $_.FullName).Substring($root.Length).TrimStart('\', '/')
                SizeMB = [math]::Round($_.Length / 1MB, 2)
                LegacyFile = $_
                Group = $null
                AlreadyActive = $false
            }
        })
}

$tiers = Get-CodexTierInventory $RepoRoot
foreach ($group in $tiers.Archived.Values) {
    $entries += [pscustomobject]@{
        Agent = 'Codex'
        SessionId = $group.Id
        Folder = $group.CwdKey
        SizeMB = [math]::Round((($group.Files | Measure-Object Length -Sum).Sum / 1MB), 2)
        LegacyFile = $null
        Group = $group
        AlreadyActive = $false
    }
}

if (-not $Query -and -not $entries) {
    Write-Host 'Vault Archived가 비어 있습니다.' -ForegroundColor DarkGray
    return
}
if (-not $Query) {
    $entries | Sort-Object Agent, Folder, SessionId | Format-Table Agent, Folder, SessionId, SizeMB -AutoSize
    Write-Host '복원: Restore-ArchivedSession.ps1 <세션 ID 또는 일부>' -ForegroundColor DarkGray
    return
}

$matched = @($entries | Where-Object { $_.SessionId -like "*$Query*" -or $_.Folder -like "*$Query*" })
if (-not $matched) {
    $matched = @($tiers.Active.Values | Where-Object { $_.Id -like "*$Query*" -or $_.CwdKey -like "*$Query*" } |
        ForEach-Object {
            [pscustomobject]@{
                Agent = 'Codex'
                SessionId = $_.Id
                Folder = $_.CwdKey
                SizeMB = [math]::Round((($_.Files | Measure-Object Length -Sum).Sum / 1MB), 2)
                LegacyFile = $null
                Group = $_
                AlreadyActive = $true
            }
        })
}
if (-not $matched) { throw "'$Query'에 해당하는 Archived 또는 Active 세션이 없습니다." }
if ($matched.Count -gt 1 -and -not $All) {
    $matched | Format-Table Agent, Folder, SessionId, SizeMB -AutoSize
    throw '여러 세션이 일치합니다. 검색어를 좁히거나 -All을 지정하세요.'
}

if (@($matched | Select-Object -ExpandProperty Agent -Unique).Count -ne 1) {
    throw '한 번의 Restore에서는 한 에이전트 종류만 선택하세요.'
}

if ($matched[0].Agent -eq 'Codex') {
    $agents = @(Get-RegisteredAgents $RepoRoot)
    $codexAgent = @($agents | Where-Object Name -eq 'Codex' | Select-Object -First 1)
    if (-not $codexAgent) { throw 'Enabled Codex agent definition이 없습니다.' }
    Assert-CurrentProcessOutsideAgentTrees $codexAgent
    Stop-AgentGracefully -Agent $codexAgent[0] -TimeoutSeconds ([int]$Config.GracefulCloseTimeoutSeconds)
    Assert-AllAgentsClosed $codexAgent

    $archiveRoot = Join-Path $RepoRoot 'Codex\archive'
    $activeRoot = Join-Path $RepoRoot 'Codex\sessions'
    foreach ($item in @($matched | Where-Object { -not $_.AlreadyActive })) {
        Move-CodexVaultGroup -RepoRoot $RepoRoot -Group $item.Group -SourceRoot $archiveRoot -TargetRoot $activeRoot
    }
    if (@($matched | Where-Object { -not $_.AlreadyActive }).Count -gt 0) {
        [void](Get-CodexTierInventory $RepoRoot)
        $ids = ($matched | Where-Object { -not $_.AlreadyActive } | ForEach-Object SessionId) -join ','
        Publish-AgentSessionVault -RepoRoot $RepoRoot -Message "sessions: restore $ids"
    }

    $state = Invoke-CodexStartState -RepoRoot $RepoRoot -Config $Config
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($codexAgent[0].AppId)"
    Write-Host "[OK] Codex $($matched.Count)건을 복원하고 앱을 다시 실행했습니다." -ForegroundColor Green
    Write-Host '사이드바 즉시 반영은 보장하지 않습니다. 안 보이면 앱 재실행 또는 업데이트 후 Start를 실행하세요.' -ForegroundColor DarkGray
    return
}

# Claude 전용 삭제 매핑과 목록 항목 계약은 Claude 측 개정 전까지 기존 파일 이동만 유지한다.
foreach ($item in $matched) {
    $source = $item.LegacyFile.FullName
    $inside = $source.Substring(([IO.Path]::GetFullPath($claudeArchiveRoot)).TrimEnd('\', '/').Length).TrimStart('\', '/')
    $target = Join-Path (Join-Path $RepoRoot 'Claude\projects') $inside
    if (Test-Path -LiteralPath $target) { throw "이미 Claude Active에 있습니다: $($item.SessionId)" }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Move-Item -LiteralPath $source -Destination $target
}
Write-Host 'Claude Archived 파일을 Active 작업 트리로 옮겼습니다. Claude 측 계약 개정 후 commit/push 경로를 연결해야 합니다.' -ForegroundColor Yellow
