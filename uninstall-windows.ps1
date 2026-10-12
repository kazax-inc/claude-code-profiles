<#
.SYNOPSIS
    Remove the `ccp` Claude Code profile manager from PowerShell (Windows).
    Profiles, their content and any ~\.claude links are never removed.
.PARAMETER Dir
    Profiles directory (default: the one recorded at install time).
#>
[CmdletBinding()]
param(
    [string]$Dir
)

$ErrorActionPreference = 'Stop'
$blockBegin = '# >>> claude-profiles >>>'
$blockEnd = '# <<< claude-profiles <<<'
$blockPattern = '(?ms)^' + [regex]::Escape($blockBegin) + '.*?^' + [regex]::Escape($blockEnd) + '[^\S\n]*\r?\n?'
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

# Every PowerShell profile the installer may have written: this edition's and
# the other one's.
$profileFiles = @($PROFILE.CurrentUserAllHosts)
if ($onWindows) {
    $documents = Split-Path -Parent (Split-Path -Parent $PROFILE.CurrentUserAllHosts)
    foreach ($folder in 'WindowsPowerShell', 'PowerShell') {
        $candidate = Join-Path (Join-Path $documents $folder) 'profile.ps1'
        if ($profileFiles -notcontains $candidate) { $profileFiles += $candidate }
    }
}

$roots = @()
$command = $null
$found = $false
foreach ($file in $profileFiles) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $text = [string](Get-Content -LiteralPath $file -Raw)
    $block = [regex]::Match($text, $blockPattern)
    if (-not $block.Success) { continue }
    $recorded = [regex]::Match($block.Value, "(?m)^\`$env:CLAUDE_PROFILES_DIR = '(.*?)'\s*$")
    if ($recorded.Success) { $roots += $recorded.Groups[1].Value }
    $recorded = [regex]::Match($block.Value, "(?m)^\`$CcpCommand = '(.*?)'\s*$")
    if ($recorded.Success -and -not $command) { $command = $recorded.Groups[1].Value }
    Set-Content -LiteralPath $file -Value ([regex]::Replace($text, $blockPattern, '')).TrimEnd() -Encoding UTF8
    Write-Host "Removed the command from $file"
    $found = $true
}

# An explicit -Dir wins; otherwise clean every directory a profile block named,
# plus the default location.
if ($Dir) {
    if ($Dir -eq '~') { $Dir = $HOME }
    elseif ($Dir.StartsWith('~/') -or $Dir.StartsWith('~\')) { $Dir = Join-Path $HOME $Dir.Substring(2) }
    $roots = @($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir))
} elseif ($env:CLAUDE_PROFILES_DIR) {
    $roots += $env:CLAUDE_PROFILES_DIR
} else {
    $roots += Join-Path $HOME '.claude-profiles'
}
foreach ($root in ($roots | Select-Object -Unique)) {
    $ccDir = Join-Path $root '.ccp'
    if (-not (Test-Path -LiteralPath $ccDir -PathType Container)) { continue }
    Remove-Item -LiteralPath $ccDir -Recurse -Force
    Write-Host "Removed $ccDir"
    Write-Host "Profiles in $root were left untouched."
    $found = $true
}

if (-not $found) {
    Write-Host 'Nothing to uninstall: no profile block and no .ccp directory found.'
    return
}
if (-not $command) { $command = 'ccp' }
Write-Host ''
Write-Host 'Profiles and any ~\.claude, ~\.claude.json links were kept.'
Write-Host "Open a new PowerShell window, or run:  Remove-Item Alias:$command"
