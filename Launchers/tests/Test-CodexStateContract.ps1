#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'Launchers\AgentSessionSync.Common.ps1')
. (Join-Path $repoRoot 'Launchers\CodexSessionState.Common.ps1')

$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Write-TestRollout {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string]$PageId,
        [string]$BasePageId = '',
        [Nullable[int64]]$BaseEndByte = $null,
        [Nullable[int64]]$BaseEndOrdinal = $null
    )
    $payload = [ordered]@{ session_id = $ThreadId; id = $PageId; cwd = 'C:\Projects\Demo' }
    if ($BasePageId) {
        $payload.history_mode = 'paginated'
        $payload.history_base = [ordered]@{
            thread_id = $BasePageId
            end_byte_offset = [int64]$BaseEndByte
            end_ordinal_exclusive = [int64]$BaseEndOrdinal
        }
    }
    $records = @(
        ([ordered]@{ timestamp = '2026-08-21T16:59:05.006Z'; ordinal = 0; type = 'session_meta'; payload = $payload } | ConvertTo-Json -Compress -Depth 8),
        ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); ordinal = 1; type = 'event_msg'; payload = @{ type = 'test' } } | ConvertTo-Json -Compress -Depth 8)
    )
    Write-AgentSessionUtf8File -Path $Path -Content (($records -join [Environment]::NewLine) + [Environment]::NewLine)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('CodexStateContract-' + [guid]::NewGuid().ToString('N'))
try {
    $threadId = '01a02543-062b-72b3-8fbb-eeab303268be'
    $pageId = '01a0254b-9403-7833-a48e-32a41e8330fc'
    $tree = Join-Path $root 'sessions\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $tree | Out-Null
    $base = Join-Path $tree "rollout-2026-08-22T01-59-04-$threadId.jsonl"
    $continuation = Join-Path $tree "rollout-2026-08-22T02-08-25-${threadId}_$pageId.jsonl"
    Write-TestRollout -Path $base -ThreadId $threadId -PageId $threadId
    $baseBytes = [IO.File]::ReadAllBytes($base)
    $baseBoundary = [Array]::IndexOf($baseBytes, [byte]10) + 1
    Write-TestRollout -Path $continuation -ThreadId $threadId -PageId $pageId -BasePageId $threadId `
        -BaseEndByte $baseBoundary -BaseEndOrdinal 1

    $meta = Get-CodexSessionMeta $continuation
    Assert-True ($meta.Id -eq $threadId) 'Continuation canonical thread ID was not preserved.'
    Assert-True ($meta.PageId -eq $pageId) 'Continuation filename page ID was not detected.'
    Assert-True ($meta.HistoryBaseThreadId -eq $threadId) 'history_base predecessor page ID was not read.'
    Assert-True ($meta.HistoryBaseEndByte -eq $baseBoundary) 'history_base byte boundary was not read.'
    Assert-True ($meta.HistoryBaseEndOrdinal -eq 1) 'history_base ordinal boundary was not read.'

    $groups = Get-CodexSessionGroups (Join-Path $root 'sessions')
    Assert-True ($groups.Count -eq 1) 'One paginated thread was split into multiple groups.'
    Assert-True ($groups[$threadId].Files.Count -eq 2) 'The complete two-page set was not grouped.'
    Assert-True ($groups[$threadId].Pages.Count -eq 2) 'The page-ID map did not retain both pages.'
    $latestActivity = Get-CodexGroupLastActivity $groups[$threadId]
    Assert-True ($latestActivity -gt [DateTime]::UtcNow.AddMinutes(-5)) "Latest activity did not include the continuation page: $latestActivity"

    $incomplete = Join-Path $root 'incomplete\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $incomplete | Out-Null
    Copy-Item -LiteralPath $continuation -Destination (Join-Path $incomplete ([IO.Path]::GetFileName($continuation)))
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'incomplete') | Out-Null } catch { $rejected = $_.Exception.Message -like '*predecessor rollout*' }
    Assert-True $rejected 'A continuation page without its predecessor was accepted.'

    $shortTree = Join-Path $root 'short\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $shortTree | Out-Null
    $shortBase = Join-Path $shortTree ([IO.Path]::GetFileName($base))
    $shortContinuation = Join-Path $shortTree ([IO.Path]::GetFileName($continuation))
    Copy-Item -LiteralPath $base -Destination $shortBase
    Write-TestRollout -Path $shortContinuation -ThreadId $threadId -PageId $pageId -BasePageId $threadId -BaseEndByte 999999 -BaseEndOrdinal 1
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'short') | Out-Null } catch { $rejected = $_.Exception.Message -like '*바이트 경계보다 짧습니다*' }
    Assert-True $rejected 'A predecessor shorter than history_base.end_byte_offset was accepted.'

    $midTree = Join-Path $root 'midline\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $midTree | Out-Null
    Copy-Item -LiteralPath $base -Destination (Join-Path $midTree ([IO.Path]::GetFileName($base)))
    Write-TestRollout -Path (Join-Path $midTree ([IO.Path]::GetFileName($continuation))) -ThreadId $threadId -PageId $pageId `
        -BasePageId $threadId -BaseEndByte ($baseBoundary - 1) -BaseEndOrdinal 1
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'midline') | Out-Null } catch { $rejected = $_.Exception.Message -like '*레코드 경계가 아닙니다*' }
    Assert-True $rejected 'A history_base byte offset in the middle of a JSONL record was accepted.'

    $ordinalTree = Join-Path $root 'ordinal\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $ordinalTree | Out-Null
    Copy-Item -LiteralPath $base -Destination (Join-Path $ordinalTree ([IO.Path]::GetFileName($base)))
    Write-TestRollout -Path (Join-Path $ordinalTree ([IO.Path]::GetFileName($continuation))) -ThreadId $threadId -PageId $pageId `
        -BasePageId $threadId -BaseEndByte $baseBoundary -BaseEndOrdinal 99
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'ordinal') | Out-Null } catch { $rejected = $_.Exception.Message -like '*ordinal이 일치하지 않습니다*' }
    Assert-True $rejected 'A history_base ordinal inconsistent with the predecessor record was accepted.'

    $baseGzip = $base + '.gz'
    Compress-JsonlTransportFile -Source $base -Destination $baseGzip
    $transitionGroups = Get-CodexSessionGroups (Join-Path $root 'sessions')
    Assert-True ($transitionGroups[$threadId].Files.Count -eq 2) 'A raw/gzip transition pair was counted as two pages.'
    Assert-True (@($transitionGroups[$threadId].Files | Where-Object FullName -eq $base).Count -eq 1) 'Raw rollout was not preferred over matching gzip.'
    Assert-True ((Get-CodexLogicalFileLength $baseGzip) -eq (Get-Item -LiteralPath $base).Length) 'Gzip logical length did not match its decompressed rollout.'
    Assert-CodexHistoryBoundary -Path $baseGzip -EndByte $baseBoundary -EndOrdinalExclusive 1
    Assert-True $true 'Gzip history boundary validation failed.'

    $duplicateTree = Join-Path $root 'duplicate\C--Projects-Demo\2026\08\21'
    New-Item -ItemType Directory -Force -Path $duplicateTree | Out-Null
    Copy-Item -LiteralPath $base -Destination (Join-Path $duplicateTree ([IO.Path]::GetFileName($base)))
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'duplicate') | Out-Null } catch { $rejected = $_.Exception.Message -like '*논리 파일명이 여러 경로에 중복*' }
    Assert-True (-not $rejected) 'Single logical rollout was incorrectly rejected.'
    $secondDate = Join-Path $root 'duplicate\C--Projects-Demo\2026\08\22'
    New-Item -ItemType Directory -Force -Path $secondDate | Out-Null
    Copy-Item -LiteralPath $base -Destination (Join-Path $secondDate ([IO.Path]::GetFileName($base)))
    $rejected = $false
    try { Get-CodexSessionGroups (Join-Path $root 'duplicate') | Out-Null } catch { $rejected = $_.Exception.Message -like '*논리 파일명이 여러 경로에 중복*' }
    Assert-True $rejected 'Duplicate logical rollout filename in different paths was accepted.'

    "PASS: Codex state contract ($assertions assertions)"
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
