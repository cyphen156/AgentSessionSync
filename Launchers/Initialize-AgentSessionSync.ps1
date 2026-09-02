#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $CodexHome = '',
    [string] $CodexAppId = 'OpenAI.Codex_2p2nqsd0c76g0!App',
    [string[]] $CodexProcessNames = @('ChatGPT', 'Codex'),
    [switch] $DisableCodex,
    [string] $ClaudeHome = '',
    [string] $ClaudeAppData = '',
    [string] $ClaudeAppId = 'Claude_pzs8sxrjxfjjc!Claude',
    [string[]] $ClaudeProcessNames = @('claude'),
    [switch] $DisableClaude
)

$ErrorActionPreference = 'Stop'
$vaultRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $vaultRoot 'AgentSessionSync.config.psd1'

function Quote-DataValue {
    param([AllowEmptyString()][string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Format-StringArray {
    param([string[]] $Values)
    $quoted = @($Values | ForEach-Object { Quote-DataValue ([string]$_) })
    return '@(' + ($quoted -join ', ') + ')'
}

function Resolve-RequiredDirectory {
    param([string] $Path, [string] $Label)
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Label directory does not exist: $full"
    }
    return (Get-Item -LiteralPath $full).FullName
}

function Write-InitializeResult {
    param(
        [ValidateSet('Success', 'Failure')][string] $Result,
        [string] $Reason,
        [string] $Detail
    )
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: AgentSessionSync'
    Write-Output 'PHASE: Initialize'
    Write-Output "REASON: $Reason"
    Write-Output "DETAIL: $Detail"
    Write-Output 'PUBLISHED_COMMIT: NONE'
    Write-Output 'SURVEY_REQUIRED: False'
}

try {
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $safeRoot = $vaultRoot.Replace('\', '/')
    $gitRoot = @(& $git -c "safe.directory=$safeRoot" -C $vaultRoot rev-parse --show-toplevel 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The copied AgentSessionSync folder must be a Git repository: $vaultRoot"
    }
    $gitRoot = (Get-Item -LiteralPath ([string]$gitRoot[0]).Trim()).FullName
    if (-not [string]::Equals($gitRoot, (Get-Item -LiteralPath $vaultRoot).FullName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Initialize must run from the root of the copied AgentSessionSync repository: $vaultRoot"
    }

    foreach ($relativePath in @(
        'Codex\Active',
        'Codex\Archived',
        'Codex\Deleted',
        'Claude\Active',
        'Claude\Archived',
        'Claude\Deleted',
        'Surveys\Codex',
        'Surveys\Claude'
    )) {
        New-Item -ItemType Directory -Path (Join-Path $vaultRoot $relativePath) -Force | Out-Null
    }

    $batonPath = Join-Path $vaultRoot 'ACTIVE_HOST.txt'
    if (-not (Test-Path -LiteralPath $batonPath -PathType Leaf)) {
        [IO.File]::WriteAllText($batonPath, ('NONE' + [char]10), (New-Object Text.UTF8Encoding($false)))
    }

    $attributesPath = Join-Path $vaultRoot '.gitattributes'
    $attributeRule = '* -text -working-tree-encoding -filter -ident'
    $attributeText = if (Test-Path -LiteralPath $attributesPath -PathType Leaf) {
        [IO.File]::ReadAllText($attributesPath)
    }
    else {
        ''
    }
    $attributeLines = @($attributeText -split '\r?\n' | Where-Object { $_ -ne $attributeRule })
    $attributeLines += $attributeRule
    $attributeText = (($attributeLines | Where-Object { $_ -ne '' }) -join [char]10) + [char]10
    [IO.File]::WriteAllText($attributesPath, $attributeText, (New-Object Text.UTF8Encoding($false)))

    $ignorePath = Join-Path $vaultRoot '.gitignore'
    $ignoreText = if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
        [IO.File]::ReadAllText($ignorePath)
    }
    else {
        @(
            '# Deny by default. This copied repository holds private session data.',
            '*',
            '!.gitignore',
            '!.gitattributes',
            '!LICENSE',
            '!README.md',
            '!docs/',
            '!docs/**',
            '!*.cmd',
            '!*.ps1',
            '!*.psd1',
            '!Launchers/',
            '!Launchers/**',
            'Launchers/Shortcuts/*.lnk',
            '',
            '# Machine-local configuration must never be committed.',
            'AgentSessionSync.config.psd1',
            ''
        ) -join [char]10
    }

    $privateRules = @(
        '# AgentSessionVault private session data',
        '!Codex/',
        '!Codex/**/',
        '!Codex/Active/**',
        '!Codex/Archived/**',
        '!Codex/Deleted/**',
        '!Claude/',
        '!Claude/**/',
        '!Claude/Active/**',
        '!Claude/Archived/**',
        '!Claude/Deleted/**',
        '!Surveys/',
        '!Surveys/**/',
        '!Surveys/Codex/**',
        '!Surveys/Claude/**',
        '# End AgentSessionVault private session data'
    )
    $oldPrivateRules = @(
        '# AgentSessionVault private session data',
        '# End AgentSessionVault private session data',
        '!Codex/',
        '!Codex/**',
        '!Codex/**/',
        '!Codex/Active/**',
        '!Codex/Archived/**',
        '!Codex/Deleted/**',
        '!Claude/',
        '!Claude/**',
        '!Claude/**/',
        '!Claude/Active/**',
        '!Claude/Archived/**',
        '!Claude/Deleted/**',
        '!Surveys/',
        '!Surveys/**',
        '!Surveys/**/',
        '!Surveys/Codex/**',
        '!Surveys/Claude/**'
    )
    $ignoreLines = @($ignoreText -split '\r?\n' | Where-Object { $oldPrivateRules -notcontains $_ })
    while ($ignoreLines.Count -gt 0 -and $ignoreLines[$ignoreLines.Count - 1] -eq '') {
        $ignoreLines = @($ignoreLines[0..($ignoreLines.Count - 2)])
    }
    $ignoreLines += ''
    $ignoreLines += $privateRules
    $ignoreLines += ''
    $ignoreText = $ignoreLines -join [char]10
    [IO.File]::WriteAllText($ignorePath, $ignoreText, (New-Object Text.UTF8Encoding($false)))

    $attributePaths = @(
        'Codex/Active/.attribute-check.jsonl',
        'Claude/Active/.attribute-check.jsonl',
        'Surveys/Codex/.attribute-check.md'
    )
    $attributeOutput = @(& $git -c "safe.directory=$safeRoot" -C $vaultRoot check-attr text working-tree-encoding filter ident -- $attributePaths 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Git attribute verification failed to run.'
    }
    $expectedAttributeCount = $attributePaths.Count * 4
    $invalidAttributes = @($attributeOutput | Where-Object { ([string]$_) -notmatch ': (text|working-tree-encoding|filter|ident): unset$' })
    if ($attributeOutput.Count -ne $expectedAttributeCount -or $invalidAttributes.Count -ne 0) {
        throw ('Git attributes do not preserve managed files as bytes: ' + ($attributeOutput -join '; '))
    }

    if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
    if (-not $ClaudeHome) { $ClaudeHome = Join-Path $env:USERPROFILE '.claude' }
    if (-not $ClaudeAppData) {
        $candidates = @((Join-Path $env:APPDATA 'Claude\claude-code-sessions'))
        $packageRoot = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $packageRoot -PathType Container) {
            $candidates += @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
                Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code-sessions'
            })
        }
        $existingClaudeAppData = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        if ($existingClaudeAppData.Count -gt 0) { $ClaudeAppData = [string]$existingClaudeAppData[0] }
        else { $ClaudeAppData = [string]$candidates[0] }
    }

    $codexEnabled = -not $DisableCodex.IsPresent
    $claudeEnabled = -not $DisableClaude.IsPresent
    if ($codexEnabled) {
        $CodexHome = Resolve-RequiredDirectory $CodexHome 'Codex Home'
        if (-not $CodexAppId -or -not $CodexProcessNames) { throw 'Codex AppId and ProcessNames are required.' }
    }
    if ($claudeEnabled) {
        $ClaudeHome = Resolve-RequiredDirectory $ClaudeHome 'Claude Home'
        $ClaudeAppData = Resolve-RequiredDirectory $ClaudeAppData 'Claude AppData'
        if (-not $ClaudeAppId -or -not $ClaudeProcessNames) { throw 'Claude AppId and ProcessNames are required.' }
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $codexFlag = if ($codexEnabled) { '$true' } else { '$false' }
        $claudeFlag = if ($claudeEnabled) { '$true' } else { '$false' }
        $body = @(
            '@{',
            '    ActiveWindowDays = 30',
            '    TransportFileLimitBytes = 99614720',
            '',
            '    Codex = @{',
            "        Enabled = $codexFlag",
            "        Home = $(Quote-DataValue $CodexHome)",
            "        AppId = $(Quote-DataValue $CodexAppId)",
            "        ProcessNames = $(Format-StringArray $CodexProcessNames)",
            '    }',
            '',
            '    Claude = @{',
            "        Enabled = $claudeFlag",
            "        Home = $(Quote-DataValue $ClaudeHome)",
            "        AppData = $(Quote-DataValue $ClaudeAppData)",
            "        AppId = $(Quote-DataValue $ClaudeAppId)",
            "        ProcessNames = $(Format-StringArray $ClaudeProcessNames)",
            '    }',
            '',
            '    GracefulCloseTimeoutSeconds = 8',
            '}',
            ''
        ) -join [char]10
        [IO.File]::WriteAllText($configPath, $body, (New-Object Text.UTF8Encoding($false)))
    }

    $shortcutDirectory = Join-Path $PSScriptRoot 'Shortcuts'
    New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    foreach ($item in @(
        @{ Name = 'AgentSession-Start'; Script = 'Start.ps1'; Icon = '137'; Description = 'AgentSessionSync: pull sessions and launch agents' },
        @{ Name = 'AgentSession-Finish'; Script = 'Finish.ps1'; Icon = '131'; Description = 'AgentSessionSync: close agents and push sessions' }
    )) {
        $scriptPath = Join-Path $PSScriptRoot $item.Script
        $shortcutPath = Join-Path $shortcutDirectory ($item.Name + '.lnk')
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $shortcut.Arguments = '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" & timeout /t 30'
        $shortcut.WorkingDirectory = $vaultRoot
        $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',' + $item.Icon
        $shortcut.Description = $item.Description
        $shortcut.Save()
    }

    Write-InitializeResult 'Success' 'Environment initialized' "Vault=$vaultRoot; Configuration=$configPath; Shortcuts=$shortcutDirectory"
    exit 0
}
catch {
    Write-InitializeResult 'Failure' 'Environment initialization failed' $_.Exception.Message
    exit 1
}
