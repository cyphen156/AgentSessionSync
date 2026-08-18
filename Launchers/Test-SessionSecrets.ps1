#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]] $Paths = @((Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [switch] $IncludeCompressed
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentSessionSync.Common.ps1')
$Patterns = @(
    @{ Name = 'GitHub token'; Regex = '(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}(?![A-Za-z0-9_])' },
    @{ Name = 'GitHub fine-grained token'; Regex = '(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}(?![A-Za-z0-9_])' },
    @{ Name = 'Anthropic API key'; Regex = '(?<![A-Za-z0-9_-])sk-ant-api\d{2,}-[A-Za-z0-9_-]{50,}(?![A-Za-z0-9_-])' },
    @{ Name = 'OpenAI API key'; Regex = '(?<![A-Za-z0-9_-])sk-(?!ant-)[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])' }
)

$Files = @(foreach ($path in $Paths)
{
    if (Test-Path -LiteralPath $path -PathType Leaf)
    {
        Get-Item -LiteralPath $path
    }
    elseif (Test-Path -LiteralPath $path -PathType Container)
    {
        Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object {
            $_.Name -like '*.jsonl' -or ($IncludeCompressed -and $_.Name -like '*.jsonl.gz')
        }
    }
})
$Files = @($Files | Sort-Object FullName -Unique)

$Findings = foreach ($file in $Files)
{
    $input = $null
    $gzip = $null
    $reader = $null
    try {
        if ($file.Name -like '*.jsonl.gz') {
            $input = [IO.File]::OpenRead((ConvertTo-ExtendedPath $file.FullName))
            $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress, $true)
            $reader = [IO.StreamReader]::new($gzip)
            while ($null -ne ($text = $reader.ReadLine())) {
                foreach ($pattern in $Patterns) {
                    if ([regex]::IsMatch($text, $pattern.Regex)) {
                        [pscustomobject]@{ Type = $pattern.Name; File = $file.FullName }
                    }
                }
            }
        } else {
            foreach ($text in [IO.File]::ReadLines((ConvertTo-ExtendedPath $file.FullName)))
            {
                foreach ($pattern in $Patterns)
                {
                    if ([regex]::IsMatch($text, $pattern.Regex))
                    {
                        [pscustomobject]@{
                            Type = $pattern.Name
                            File = $file.FullName
                        }
                    }
                }
            }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($gzip) { $gzip.Dispose() }
        if ($input) { $input.Dispose() }
    }
}

if ($Findings)
{
    $Findings | Sort-Object Type, File -Unique | Format-Table -AutoSize | Out-String | Write-Host
    throw '세션 JSONL에서 공개하면 안 되는 토큰 후보를 발견했습니다. 실제 값을 출력하지 않고 Push를 중단합니다.'
}

Write-Host "[PASS] session secret scan ($(@($Files).Count) files)" -ForegroundColor Green
