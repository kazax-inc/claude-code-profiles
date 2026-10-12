# ccp.ps1 - Claude Code multi-profile manager for PowerShell (5.1 and 7+).
#
# Dot-sourced from the PowerShell profile by install-windows.ps1. Every profile
# is a directory under $env:CLAUDE_PROFILES_DIR (default: ~\.claude-profiles)
# that is handed to Claude Code through CLAUDE_CONFIG_DIR.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

function Get-CcRoot {
    if ($env:CLAUDE_PROFILES_DIR) { return $env:CLAUDE_PROFILES_DIR }
    return (Join-Path $HOME '.claude-profiles')
}

function Test-CcWindows { return ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows }

# Name of the command. The installer writes $CcpCommand to the PowerShell
# profile; it must never be `claude`, which this function has to call.
function Get-CcCmd {
    $name = "$CcpCommand"
    if ($name -match '^[A-Za-z][A-Za-z0-9_-]*$' -and $name -ne 'claude') { return $name }
    return 'ccp'
}

function Write-CcErr([string]$Message) { Write-Host "$(Get-CcCmd): $Message" -ForegroundColor Red }

function Test-CcName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $false }
    return @('default', 'add', 'list', 'ls', 'help') -notcontains $Name
}

# Get-Item also finds dangling links, which Test-Path reports as missing.
function Get-CcItem([string]$Path) { return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }

function Test-CcLink([string]$Path) {
    $item = Get-CcItem $Path
    return ($null -ne $item) -and [bool]$item.LinkType
}

function Get-CcLinkTarget([string]$Path) {
    $item = Get-CcItem $Path
    if ($null -eq $item -or -not $item.LinkType) { return $null }
    return ([string]@($item.Target)[0]).TrimEnd('\', '/')
}

# Remove a junction or symlink without ever touching what it points to.
function Remove-CcLink([string]$Path) {
    $item = Get-CcItem $Path
    if ($null -eq $item) { return }
    if ($item.PSIsContainer) { [System.IO.Directory]::Delete($Path) } else { [System.IO.File]::Delete($Path) }
}

# Junctions need no privilege on Windows; elsewhere use a symlink.
function New-CcDirLink([string]$Path, [string]$Target) {
    if (Test-CcWindows) {
        New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    }
}

function Get-CcProfiles {
    $root = Get-CcRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -Force |
            Where-Object { $_.Name -ne 'default' -and -not $_.Name.StartsWith('.') } |
            Sort-Object Name | ForEach-Object { $_.Name })
}

# Resolve an exact profile name or a unique prefix of one; $null on failure.
function Resolve-CcProfile([string]$Name) {
    if (-not (Test-CcName $Name)) {
        Write-CcErr "invalid profile name: '$Name'"
        return $null
    }
    $all = @(Get-CcProfiles)
    $exact = @($all | Where-Object { $_ -eq $Name })
    if ($exact.Count -ge 1) { return $exact[0] }
    $found = @($all | Where-Object { $_.StartsWith($Name, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) {
        Write-CcErr "'$Name' is ambiguous: $($found -join ', ')"
    } else {
        Write-CcErr "unknown profile or command: '$Name' (see: $(Get-CcCmd) list, $(Get-CcCmd) help)"
    }
    return $null
}

# Name of the profile the <root>\default link points to, or $null.
function Get-CcDefaultName {
    $target = Get-CcLinkTarget (Join-Path (Get-CcRoot) 'default')
    if (-not $target) { return $null }
    $name = Split-Path -Leaf $target
    if (Test-Path -LiteralPath (Join-Path (Get-CcRoot) $name) -PathType Container) { return $name }
    return $null
}

function Invoke-CcProfile([string]$Name, [object[]]$Rest) {
    $dir = Join-Path (Get-CcRoot) $Name
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-CcErr "profile directory missing: $dir"
        return
    }
    $exe = Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) {
        Write-CcErr 'claude was not found in PATH'
        return
    }
    $previous = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = $dir
    try {
        & $exe.Source @Rest
    } finally {
        if ($null -eq $previous) {
            Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CONFIG_DIR = $previous
        }
    }
}

# True if ~\.claude or ~\.claude.json exists as a real (non-link) entry.
function Test-CcNative {
    foreach ($p in @((Join-Path $HOME '.claude'), (Join-Path $HOME '.claude.json'))) {
        if ((Get-CcItem $p) -and -not (Test-CcLink $p)) { return $true }
    }
    return $false
}

function Add-CcProfile([object[]]$Arguments) {
    $name = $null
    $migrate = $false
    foreach ($a in $Arguments) {
        if ($a -eq '--migrate' -or $a -eq '-Migrate') { $migrate = $true }
        elseif ("$a".StartsWith('-')) { Write-CcErr "add: unknown option: $a"; return }
        elseif ($name) { Write-CcErr 'add: only one profile name expected'; return }
        else { $name = "$a" }
    }
    if (-not $name) { Write-CcErr "usage: $(Get-CcCmd) add <profile> [--migrate]"; return }
    if (-not (Test-CcName $name)) {
        Write-CcErr "invalid profile name: '$name' (letters, digits, '.', '_', '-'; reserved: default add list ls help)"
        return
    }
    $root = Get-CcRoot
    $dir = Join-Path $root $name
    if (Get-CcItem $dir) {
        Write-Warning "$(Get-CcCmd): profile '$name' already exists: $dir"
        return
    }
    if ($migrate -and -not (Test-CcNative)) {
        Write-CcErr 'nothing to migrate: ~\.claude and ~\.claude.json are missing or already links'
        return
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    if ($migrate) {
        $nativeDir = Join-Path $HOME '.claude'
        $nativeJson = Join-Path $HOME '.claude.json'
        if ((Get-CcItem $nativeDir) -and -not (Test-CcLink $nativeDir)) {
            Move-Item -LiteralPath $nativeDir -Destination $dir -ErrorAction Stop
            Write-Host "Moved $nativeDir -> $dir"
        } else {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
        if ((Get-CcItem $nativeJson) -and -not (Test-CcLink $nativeJson)) {
            $jsonTarget = Join-Path $dir '.claude.json'
            Move-Item -LiteralPath $nativeJson -Destination $jsonTarget -ErrorAction Stop
            Write-Host "Moved $nativeJson -> $jsonTarget"
        }
        Write-Host "Profile '$name' created from the existing Claude Code configuration."
        Write-Host "Plain 'claude' no longer finds ~\.claude: run '$(Get-CcCmd) default $name' (method `"global`" or `"env`")."
    } else {
        New-Item -ItemType Directory -Path $dir | Out-Null
        Write-Host "Profile '$name' created: $dir"
        Write-Host "Start it with '$(Get-CcCmd) $name' and log in with /login."
    }
}

function Set-CcDefaultLink([string]$Name) {
    $root = Get-CcRoot
    $link = Join-Path $root 'default'
    if (Test-CcLink $link) {
        Remove-CcLink $link
    } elseif (Get-CcItem $link) {
        Write-CcErr "$link exists and is not a link"
        return $false
    }
    New-CcDirLink $link (Join-Path $root $Name)
    Write-Host "default -> $Name  ($link)"
    return $true
}

function Set-CcDefaultGlobal([string]$Name) {
    $root = Get-CcRoot
    $nativeDir = Join-Path $HOME '.claude'
    $nativeJson = Join-Path $HOME '.claude.json'
    foreach ($p in @($nativeDir, $nativeJson)) {
        if ((Get-CcItem $p) -and -not (Test-CcLink $p)) {
            Write-CcErr "$p exists and is not a link; migrate it first ($(Get-CcCmd) add <profile> --migrate) or move it away"
            return
        }
    }
    if (-not (Set-CcDefaultLink $Name)) { return }
    $default = Join-Path $root 'default'
    $defaultJson = Join-Path $default '.claude.json'
    Remove-CcLink $nativeDir
    Remove-CcLink $nativeJson
    New-CcDirLink $nativeDir $default
    Write-Host "$nativeDir -> $default"
    try {
        New-Item -ItemType SymbolicLink -Path $nativeJson -Value $defaultJson -ErrorAction Stop | Out-Null
        Write-Host "$nativeJson -> $defaultJson"
    } catch {
        Write-CcErr "could not create the file symlink $nativeJson ($($_.Exception.Message))"
        Write-Host '    File symlinks on Windows need Developer Mode (Settings > System > For developers)'
        Write-Host '    or an elevated PowerShell. Enable one of them and run the command again.'
    }
    if ($env:CLAUDE_CONFIG_DIR) {
        Write-Warning "$(Get-CcCmd): CLAUDE_CONFIG_DIR is set in this session ($env:CLAUDE_CONFIG_DIR) and takes precedence over ~\.claude."
        Write-Warning "    Clear it with: $(Get-CcCmd) default --unset --method env"
    }
}

# $Persist: $true, $false or $null (ask)
function Set-CcDefaultEnv([string]$Name, $Persist) {
    $root = Get-CcRoot
    $env:CLAUDE_CONFIG_DIR = Join-Path $root $Name
    Write-Host "CLAUDE_CONFIG_DIR=$env:CLAUDE_CONFIG_DIR  (this PowerShell session)"
    if ($env:_CCP_INSTALLER) {
        $Persist = $true
    } elseif ($null -eq $Persist) {
        $Persist = (Read-Host "Also use '$Name' in new PowerShell sessions? [y/N]") -match '^[yY]'
    }
    if ($Persist) {
        New-Item -ItemType Directory -Path (Join-Path $root '.ccp') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $root '.ccp') 'env-default') -Value $Name -Encoding ASCII
        Write-Host "New PowerShell sessions will set CLAUDE_CONFIG_DIR for '$Name'."
    }
}

function Read-CcMethod([string]$Title) {
    Write-Host $Title
    Write-Host "  1) env     set `$env:CLAUDE_CONFIG_DIR            -> plain 'claude', this session"
    Write-Host "  2) global  link ~\.claude, ~\.claude.json        -> every 'claude', all shells"
    Write-Host "  3) link    link $(Join-Path (Get-CcRoot) 'default') -> '$(Get-CcCmd)' without a profile"
    return (Read-Host 'Method [1-3]')
}

function Show-CcDefault {
    $root = Get-CcRoot
    if ($env:CLAUDE_CONFIG_DIR) { Write-Host "env     CLAUDE_CONFIG_DIR=$env:CLAUDE_CONFIG_DIR" } else { Write-Host 'env     not set' }
    $state = Join-Path (Join-Path $root '.ccp') 'env-default'
    if (Test-Path -LiteralPath $state) {
        Write-Host "        new PowerShell sessions: $((Get-Content -LiteralPath $state -TotalCount 1))"
    }
    $nativeDir = Join-Path $HOME '.claude'
    if (Test-CcLink $nativeDir) {
        Write-Host "global  ~\.claude -> $(Get-CcLinkTarget $nativeDir)"
    } elseif (Get-CcItem $nativeDir) {
        Write-Host 'global  not managed (~\.claude is a real directory)'
    } else {
        Write-Host 'global  not set'
    }
    $name = Get-CcDefaultName
    if ($name) { Write-Host "link    default -> $name" } else { Write-Host 'link    not set' }
}

function Clear-CcDefault([string]$Method) {
    $root = Get-CcRoot
    $default = Join-Path $root 'default'
    switch ($Method) {
        'env' {
            Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path (Join-Path $root '.ccp') 'env-default') -ErrorAction SilentlyContinue
            Write-Host 'CLAUDE_CONFIG_DIR unset (this session and new ones).'
        }
        'global' {
            foreach ($p in @((Join-Path $HOME '.claude'), (Join-Path $HOME '.claude.json'))) {
                $target = Get-CcLinkTarget $p
                if (-not $target) { continue }
                if ($target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-CcLink $p
                    Write-Host "Removed link $p"
                } else {
                    Write-CcErr "$p does not point into $root; left untouched"
                }
            }
        }
        'link' {
            if (Test-CcLink $default) {
                Remove-CcLink $default
                Write-Host "Removed $default"
            }
            if ((Get-CcLinkTarget (Join-Path $HOME '.claude')) -eq $default) {
                Write-Warning "$(Get-CcCmd): ~\.claude still points to it ($(Get-CcCmd) default --unset --method global)"
            }
        }
    }
}

function Set-CcDefault([object[]]$Arguments) {
    $name = $null
    $method = $null
    $persist = $null
    $unset = $false
    $items = @($Arguments)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $a = "$($items[$i])"
        if ($a -eq '-m' -or $a -eq '--method' -or $a -eq '-Method') {
            if ($i + 1 -ge $items.Count) { Write-CcErr "default: $a needs a value (env, global or link)"; return }
            $i++
            $method = "$($items[$i])"
        }
        elseif ($a.StartsWith('--method=')) { $method = $a.Substring(9) }
        elseif ($a -eq '--persist' -or $a -eq '-Persist') { $persist = $true }
        elseif ($a -eq '--no-persist' -or $a -eq '-NoPersist') { $persist = $false }
        elseif ($a -eq '--unset' -or $a -eq '-Unset') { $unset = $true }
        elseif ($a.StartsWith('-')) { Write-CcErr "default: unknown option: $a"; return }
        else { $name = $a }
    }

    if (-not $unset) {
        if (-not $name) { Show-CcDefault; return }
        $name = Resolve-CcProfile $name
        if (-not $name) { return }
    }
    if (-not $method) {
        if ($unset) { $method = Read-CcMethod 'Which default should be removed?' }
        else { $method = Read-CcMethod "How should '$name' become the default profile?" }
    }
    switch ($method) {
        { $_ -in '1', 'env' } { $method = 'env'; break }
        { $_ -in '2', 'global' } { $method = 'global'; break }
        { $_ -in '3', 'link' } { $method = 'link'; break }
        default { Write-CcErr "default: unknown method '$method' (expected env, global or link)"; return }
    }

    if ($unset) { Clear-CcDefault $method; return }
    switch ($method) {
        'env' { Set-CcDefaultEnv $name $persist }
        'global' { Set-CcDefaultGlobal $name }
        'link' { Set-CcDefaultLink $name | Out-Null }
    }
}

function Show-CcProfiles {
    $root = Get-CcRoot
    $all = @(Get-CcProfiles)
    if ($all.Count -eq 0) {
        Write-Host "No profiles in $root. Create one with: $(Get-CcCmd) add <profile>"
        return
    }
    $linkName = Get-CcDefaultName
    $globalTarget = Get-CcLinkTarget (Join-Path $HOME '.claude')
    $envDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR.TrimEnd('\', '/') } else { $null }
    foreach ($p in $all) {
        $dir = Join-Path $root $p
        $tags = ''
        if ($p -eq $linkName) { $tags += ' [link]' }
        if ($globalTarget -and ($globalTarget -eq $dir -or ($p -eq $linkName -and $globalTarget -eq (Join-Path $root 'default')))) {
            $tags += ' [global]'
        }
        if ($envDir -and $envDir -eq $dir) { $tags += ' [env]' }
        Write-Host "  $p$tags"
    }
}

function Show-CcHelp {
    $c = Get-CcCmd
    Write-Host @"
Claude Code profile manager - profiles live in $(Get-CcRoot)

  $c [claude args...]
      run claude with the default profile (method "link"), or pick a profile from a list when no default is set
  $c <profile> [claude args...]
      run claude with a profile (unique prefixes work)
  $c add <profile> [--migrate]
      create a profile; --migrate moves ~\.claude and ~\.claude.json into it
  $c default
      show the current defaults
  $c default <profile> [--method env|global|link] [--persist|--no-persist]
      set the default profile (asks for the method if omitted)
      env     set CLAUDE_CONFIG_DIR: plain 'claude' in this PowerShell session
              (--persist: also in new sessions)
      global  link ~\.claude and ~\.claude.json to the profile: every 'claude'
      link    link <profiles>\default to the profile: '$c' without a profile
  $c default --unset [--method env|global|link]
      remove a default
  $c list
      list profiles and which default points at them
  $c help
      this help
"@
}

# No default profile: let the user choose one from a numbered list. Without
# any profile, say so and show the help. Returns the name or $null.
function Read-CcProfile {
    $all = @(Get-CcProfiles)
    if ($all.Count -eq 0) {
        Write-CcErr "no profile found in $(Get-CcRoot)"
        Show-CcHelp
        return $null
    }
    Write-Host 'No default profile. Select a profile:'
    for ($i = 0; $i -lt $all.Count; $i++) { Write-Host "  $($i + 1)) $($all[$i])" }
    $choice = "$(Read-Host "Profile [1-$($all.Count)]")".Trim()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($choice -eq "$($i + 1)" -or $choice -eq $all[$i]) { return $all[$i] }
    }
    Write-CcErr "no profile selected (set a default with: $(Get-CcCmd) default <profile>)"
    return $null
}

function Invoke-Ccp {
    $rest = @()
    if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
    $cmd = if ($args.Count -gt 0) { "$($args[0])" } else { '' }

    if ($cmd -eq 'add') { Add-CcProfile $rest }
    elseif ($cmd -eq 'default') { Set-CcDefault $rest }
    elseif ($cmd -eq 'list' -or $cmd -eq 'ls') { Show-CcProfiles }
    elseif ($cmd -eq 'help' -or $cmd -eq '-h' -or $cmd -eq '--help') { Show-CcHelp }
    elseif ($cmd -eq '' -or $cmd.StartsWith('-')) {
        $name = Get-CcDefaultName
        if (-not $name) { $name = Read-CcProfile }
        if (-not $name) { return }
        Invoke-CcProfile $name @($args)
    }
    else {
        $name = Resolve-CcProfile $cmd
        if ($name) { Invoke-CcProfile $name $rest }
    }
}

# Default persisted by `ccp default <profile> --method env --persist`. An
# inherited CLAUDE_CONFIG_DIR wins, so shells started from `ccp <profile>`
# keep that profile.
if (-not $env:CLAUDE_CONFIG_DIR) {
    $ccState = Join-Path (Join-Path (Get-CcRoot) '.ccp') 'env-default'
    if (Test-Path -LiteralPath $ccState) {
        $ccName = "$(Get-Content -LiteralPath $ccState -TotalCount 1)".Trim()
        if ((Test-CcName $ccName) -and (Test-Path -LiteralPath (Join-Path (Get-CcRoot) $ccName) -PathType Container)) {
            $env:CLAUDE_CONFIG_DIR = Join-Path (Get-CcRoot) $ccName
        }
        Remove-Variable ccName -ErrorAction SilentlyContinue
    }
    Remove-Variable ccState -ErrorAction SilentlyContinue
}

Set-Alias -Name (Get-CcCmd) -Value Invoke-Ccp
