#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]] $Paths = @((Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = 'Stop'
$Patterns = @(
    @{ Name = 'GitHub token'; Regex = '(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}(?![A-Za-z0-9_])' },
    @{ Name = 'GitHub fine-grained token'; Regex = '(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}(?![A-Za-z0-9_])' },
    @{ Name = 'Anthropic API key'; Regex = '(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])' },
    @{ Name = 'OpenAI API key'; Regex = '(?<![A-Za-z0-9_-])sk-(?!ant-)[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])' }
)

$Files = foreach ($path in $Paths)
{
    if (Test-Path -LiteralPath $path -PathType Leaf)
    {
        Get-Item -LiteralPath $path
    }
    elseif (Test-Path -LiteralPath $path -PathType Container)
    {
        Get-ChildItem -LiteralPath $path -Filter '*.jsonl' -File -Recurse
    }
}

$Findings = foreach ($file in $Files)
{
    $text = [IO.File]::ReadAllText($file.FullName)
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

if ($Findings)
{
    $Findings | Sort-Object Type, File -Unique | Format-Table -AutoSize | Out-String | Write-Host
    throw '세션 JSONL에서 공개하면 안 되는 토큰 후보를 발견했습니다. 실제 값을 출력하지 않고 Push를 중단합니다.'
}

Write-Host "[PASS] session secret scan ($(@($Files).Count) JSONL files)" -ForegroundColor Green
