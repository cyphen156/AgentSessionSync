#requires -Version 5.1
<#
.SYNOPSIS
  Codex 대화목록 인덱스(session_index.jsonl)를 union 머지한다.
  양쪽 PC가 같은 파일에 각자 항목을 쓰므로, 덮어쓰면 한쪽이 사라진다 → id 기준 합집합(최신 updated_at 우선).
.PARAMETER Inputs
  머지할 입력 인덱스 파일들(레포본 + 로컬본).
.PARAMETER OutPath
  union 결과를 쓸 경로(여러 곳에 쓰려면 반복 호출).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $Inputs,
    [Parameter(Mandatory)][string]   $OutPath
)
$ErrorActionPreference = 'Stop'

$byId = @{}
foreach ($p in $Inputs) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o.id) { continue }
        $key = [string]$o.id
        $upd = [string]$o.updated_at
        if (-not $byId.ContainsKey($key) -or ($upd -gt $byId[$key].upd)) {
            $byId[$key] = [pscustomobject]@{ upd = $upd; line = $line }
        }
    }
}

$merged = $byId.Values | Sort-Object upd | ForEach-Object { $_.line }
$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
# 후행 개행 포함, UTF8(BOM 없음)로 기록
[IO.File]::WriteAllText($OutPath, (($merged -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[codex-index] union $($byId.Count)개 항목 -> $OutPath" -ForegroundColor DarkCyan
