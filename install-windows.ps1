<#
.SYNOPSIS
    Install the `ccp` Claude Code profile manager for PowerShell (Windows).
.PARAMETER Dir
    Profiles directory (default: ~\.claude-profiles).
.PARAMETER Yes
    Accept the defaults and skip the profile questions.
.PARAMETER Name
    Name of the command to register (default: ccp). `claude` is refused.
#>
[CmdletBinding()]
param(
    [string]$Dir,
    [string]$Name,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$blockBegin = '# >>> claude-profiles >>>'
$blockEnd = '# <<< claude-profiles <<<'
$blockPattern = '(?ms)^' + [regex]::Escape($blockBegin) + '.*?^' + [regex]::Escape($blockEnd) + '[^\S\n]*\r?\n?'
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

# --- shell detection: the running PowerShell, plus the other edition if installed
$profileFiles = @($PROFILE.CurrentUserAllHosts)
if ($onWindows) {
    $documents = Split-Path -Parent (Split-Path -Parent $PROFILE.CurrentUserAllHosts)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
            $profileFiles += Join-Path (Join-Path $documents 'WindowsPowerShell') 'profile.ps1'
        }
    } elseif (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $profileFiles += Join-Path (Join-Path $documents 'PowerShell') 'profile.ps1'
    }
}
Write-Host "Shell: PowerShell $($PSVersionTable.PSVersion) ($($profileFiles -join ', '))"

# --- profiles directory
if (-not $Dir) {
    $Dir = if ($env:CLAUDE_PROFILES_DIR) { $env:CLAUDE_PROFILES_DIR } else { Join-Path $HOME '.claude-profiles' }
    if (-not $Yes) {
        $answer = Read-Host "Profiles directory [$Dir]"
        if ($answer) { $Dir = $answer }
    }
}
if ($Dir -eq '~') { $Dir = $HOME }
elseif ($Dir.StartsWith('~/') -or $Dir.StartsWith('~\')) { $Dir = Join-Path $HOME $Dir.Substring(2) }
$Dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir)
if ($Dir.Contains("'")) { throw 'The profiles directory must not contain quotes.' }
$ccDir = Join-Path $Dir '.ccp'

function Remove-CcBlock([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $text = [string](Get-Content -LiteralPath $File -Raw)
    return [regex]::Replace($text, $blockPattern, '')
}

# --- command name
function Test-CcpName([string]$Candidate) {
    if ($Candidate -eq 'claude') {
        Write-Host '"claude" cannot be used: the command has to call the real claude.' -ForegroundColor Red
        return $false
    }
    if ($Candidate -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
        Write-Host "Invalid command name `"$Candidate`": start with a letter, then letters, digits, `"_`" or `"-`"." -ForegroundColor Red
        return $false
    }
    return $true
}

# Warn about what a command name would shadow; $false if there was a warning.
function Test-CcpNameFree([string]$Candidate) {
    if ($Candidate -eq 'cc') {
        Write-Warning '"cc" is the standard name of the system C compiler. In your interactive'
        Write-Warning 'shell it will run Claude Code instead; anything you type there that calls cc'
        Write-Warning 'to compile will break (scripts and other programs are not affected).'
        return $false
    }
    $existing = Get-Command $Candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing -and $existing.Definition -ne 'Invoke-Ccp') {
        Write-Warning "`"$Candidate`" already exists on this system ($($existing.CommandType): $($existing.Definition)) and will be shadowed in PowerShell."
        return $false
    }
    return $true
}

if ($Name) {
    if (-not (Test-CcpName $Name)) { exit 2 }
    if (-not (Test-CcpNameFree $Name) -and -not $Yes) {
        if ((Read-Host "Use `"$Name`" anyway? [y/N]") -notmatch '^[yY]') { exit 1 }
    }
} elseif ($Yes) {
    $Name = 'ccp'
} else {
    while ($true) {
        $Name = Read-Host 'Command name [ccp]'
        if (-not $Name) { $Name = 'ccp' }
        if (-not (Test-CcpName $Name)) { continue }
        if (Test-CcpNameFree $Name) { break }
        if ((Read-Host "Use `"$Name`" anyway? [y/N]") -match '^[yY]') { break }
    }
}

# --- install
# Only <profiles>\.cc is written here. Profile directories and their content
# are never created, modified or replaced by the installer.
New-Item -ItemType Directory -Path $ccDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'lib') 'ccp.ps1') -Destination (Join-Path $ccDir 'ccp.ps1') -Force
Write-Host "Installed $(Join-Path $ccDir 'ccp.ps1')"

$block = @(
    $blockBegin
    "`$env:CLAUDE_PROFILES_DIR = '$Dir'"
    "`$CcpCommand = '$Name'"
    'if (Test-Path -LiteralPath (Join-Path $env:CLAUDE_PROFILES_DIR ''.ccp/ccp.ps1'')) { . (Join-Path $env:CLAUDE_PROFILES_DIR ''.ccp/ccp.ps1'') }'
    $blockEnd
) -join [Environment]::NewLine

foreach ($file in $profileFiles) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    $text = (Remove-CcBlock $file).TrimEnd()
    if ($text -match ('(?m)^\s*(function\s+' + [regex]::Escape($Name) + '\b|\$env:CLAUDE_CONFIG_DIR\s*=)')) {
        Write-Warning "$file already defines its own $Name function and/or CLAUDE_CONFIG_DIR."
        Write-Warning 'A hard-coded CLAUDE_CONFIG_DIR overrides the "global" and persisted "env" defaults. Remove those lines.'
    }
    if ($text) { $text += [Environment]::NewLine + [Environment]::NewLine }
    Set-Content -LiteralPath $file -Value ($text + $block) -Encoding UTF8
    Write-Host "Registered the $Name command in $file"
}

if ($onWindows -and (Get-ExecutionPolicy) -in 'Restricted', 'AllSigned') {
    Write-Warning "The execution policy '$(Get-ExecutionPolicy)' prevents the PowerShell profile from loading."
    Write-Warning 'Allow local scripts with: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
}

# --- first profile
$env:CLAUDE_PROFILES_DIR = $Dir
$CcpCommand = $Name
. (Join-Path $ccDir 'ccp.ps1')

if (-not $Yes) {
    Write-Host ''
    $profileName = $null
    if (@(Get-CcProfiles).Count -gt 0) {
        Write-Host 'Existing profiles (kept as they are, ready to use):'
        Show-CcProfiles
    }
    if (Test-CcNative) {
        Write-Host 'Found an existing Claude Code configuration (~\.claude, ~\.claude.json).'
        if ((Read-Host 'Migrate it into a new profile (the files are moved)? [Y/n]') -notmatch '^[nN]') {
            $profileName = Read-Host 'Name of the profile'
            if ($profileName) {
                Invoke-Ccp add $profileName --migrate
                if (@(Get-CcProfiles) -notcontains $profileName) { $profileName = $null }
            }
        }
    }
    if (-not $profileName) {
        if (@(Get-CcProfiles).Count -eq 0) {
            $profileName = Read-Host 'Name of your first profile (empty to skip)'
        } else {
            $profileName = Read-Host 'Name of a profile to create or reuse (empty to skip)'
        }
        if ($profileName -and @(Get-CcProfiles) -contains $profileName) {
            Write-Host "Profile '$profileName' already exists; using it as it is."
        } elseif ($profileName) {
            Invoke-Ccp add $profileName
            if (@(Get-CcProfiles) -notcontains $profileName) { $profileName = $null }
        }
    }
    if ($profileName -and (Read-Host "Make '$profileName' the default profile? [Y/n]") -notmatch '^[nN]') {
        $env:_CCP_INSTALLER = '1'
        try { Invoke-Ccp default $profileName } finally { Remove-Item Env:_CCP_INSTALLER -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
Write-Host "Done. Open a new PowerShell window or run:  . `"$($profileFiles[0])`""
Write-Host "Then try:  $Name help"
