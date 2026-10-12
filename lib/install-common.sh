# install-common.sh - shared by the Linux and macOS install and uninstall scripts
# (bash >= 3.2).
# Usage: . lib/install-common.sh; cc_install_main <linux|macos> "$@"
#        . lib/install-common.sh; cc_uninstall_main <linux|macos> "$@"

CC_BLOCK_BEGIN='# >>> claude-profiles >>>'
CC_BLOCK_END='# <<< claude-profiles <<<'

_cci_usage() {
    cat <<EOF
Usage: $1 [options]

  --dir <path>     profiles directory (default: \$HOME/.claude-profiles)
  --shell <name>   bash or zsh (default: detected from \$SHELL)
  --name <command> name of the command to register (default: ccp)
  --yes            accept the defaults and skip the profile questions
  -h, --help       this help

To remove the command again, run uninstall-${1#install-}
EOF
}

_cci_ask() {
    printf '%s' "$1"
    _CCI_REPLY=""
    _CCI_EOF=0
    IFS= read -r _CCI_REPLY || _CCI_EOF=1
    [ -n "$_CCI_REPLY" ] || _CCI_REPLY="${2-}"
}

_cci_yes() {
    _cci_ask "$1" "$2"
    case "$_CCI_REPLY" in
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate a command name; prints the reason on failure.
_cci_check_name() {
    case "$1" in
        [cC][lL][aA][uU][dD][eE])
            printf '"claude" cannot be used: the command has to call the real claude.\n' >&2
            return 1
            ;;
        '' | [!A-Za-z]* | *[!A-Za-z0-9_-]*)
            printf 'Invalid command name "%s": start with a letter, then letters, digits, "_" or "-".\n' "$1" >&2
            return 1
            ;;
    esac
    return 0
}

# Warn about what a command name would shadow; fails if there was a warning.
_cci_warn_name() {
    local found
    if [ "$1" = cc ]; then
        printf 'Warning: "cc" is the standard name of the system C compiler. In your interactive\n'
        printf 'shell it will run Claude Code instead; anything you type or source there that\n'
        printf 'calls cc to compile will break (scripts, make and other programs are not affected).\n'
        return 1
    fi
    found="$(command -v -- "$1" 2>/dev/null)"
    if [ -n "$found" ]; then
        printf 'Warning: "%s" already exists on this system (%s) and will be shadowed\n' "$1" "$found"
        printf 'in your interactive shell.\n'
        return 1
    fi
    return 0
}

# Rewrite the rc file without our block; keeps the file itself (it may be a symlink).
_cci_strip_block() {
    local rc="$1" tmp
    [ -f "$rc" ] || return 0
    grep -qF "$CC_BLOCK_BEGIN" "$rc" || return 0
    tmp="$(mktemp)" || return 1
    sed "/^$CC_BLOCK_BEGIN\$/,/^$CC_BLOCK_END\$/d" "$rc" >"$tmp" && cat "$tmp" >"$rc"
    rm -f "$tmp"
}

cc_install_main() {
    local os="$1" script_dir root="" shell_name="" assume_yes=0 rc name legacy cmd=""
    shift
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)
                root="${2-}"
                shift
                ;;
            --dir=*) root="${1#*=}" ;;
            --shell)
                shell_name="${2-}"
                shift
                ;;
            --shell=*) shell_name="${1#*=}" ;;
            --name)
                cmd="${2-}"
                [ $# -ge 2 ] && shift
                if [ -z "$cmd" ]; then
                    printf -- '--name needs a value\n' >&2
                    return 2
                fi
                ;;
            --name=*) cmd="${1#*=}" ;;
            --yes | -y) assume_yes=1 ;;
            -h | --help)
                _cci_usage "install-$os.sh"
                return 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                _cci_usage "install-$os.sh" >&2
                return 2
                ;;
        esac
        shift
    done

    # --- shell detection -------------------------------------------------
    if [ -z "$shell_name" ]; then
        shell_name="${SHELL##*/}"
        case "$shell_name" in
            bash | zsh) ;;
            *)
                if [ "$os" = macos ]; then shell_name=zsh; else shell_name=bash; fi
                printf 'Could not detect a supported shell from $SHELL (%s); using %s.\n' "${SHELL-}" "$shell_name"
                ;;
        esac
    fi
    case "$shell_name" in
        zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash) if [ "$os" = macos ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
        *)
            printf 'Unsupported shell: %s (expected bash or zsh)\n' "$shell_name" >&2
            return 2
            ;;
    esac
    printf 'Shell: %s (%s)\n' "$shell_name" "$rc"

    # --- profiles directory ----------------------------------------------
    if [ -z "$root" ]; then
        root="${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
        if [ "$assume_yes" -eq 0 ]; then
            _cci_ask "Profiles directory [$root]: " "$root"
            root="$_CCI_REPLY"
        fi
    fi
    case "$root" in
        "~") root="$HOME" ;;
        "~/"*) root="$HOME/${root#\~/}" ;;
        /*) ;;
        *) root="$PWD/$root" ;;
    esac
    root="${root%/}"
    case "$root" in
        *\'* | *'
'*)
            printf 'The profiles directory must not contain quotes or newlines.\n' >&2
            return 2
            ;;
    esac

    # --- command name ----------------------------------------------------
    if [ -n "$cmd" ]; then
        _cci_check_name "$cmd" || return 2
        if ! _cci_warn_name "$cmd" && [ "$assume_yes" -eq 0 ]; then
            _cci_yes "Use \"$cmd\" anyway? [y/N] " n || return 1
        fi
    elif [ "$assume_yes" -eq 1 ]; then
        cmd=ccp
    else
        while :; do
            _cci_ask 'Command name [ccp]: ' ccp
            cmd="$_CCI_REPLY"
            if ! _cci_check_name "$cmd"; then
                [ "$_CCI_EOF" -eq 0 ] || return 1
                continue
            fi
            _cci_warn_name "$cmd" && break
            _cci_yes "Use \"$cmd\" anyway? [y/N] " n && break
            [ "$_CCI_EOF" -eq 0 ] || return 1
        done
    fi

    # --- install ---------------------------------------------------------
    # Only <profiles>/.ccp is written here. Profile directories and their
    # content are never created, modified or replaced by the installer.
    mkdir -p "$root/.ccp" || return 1
    cp "$script_dir/lib/ccp.sh" "$root/.ccp/ccp.sh" || return 1
    printf 'Installed %s/.ccp/ccp.sh\n' "$root"

    legacy=""
    if [ -f "$rc" ]; then
        _cci_strip_block "$rc" || return 1
        legacy="$(grep -nE '^[[:space:]]*(function[[:space:]]+'"$cmd"'([[:space:]]|\(|\{|$)|'"$cmd"'[[:space:]]*\(\)|alias[[:space:]]+'"$cmd"'=|(export[[:space:]]+)?CLAUDE_CONFIG_DIR=)' "$rc")"
    fi
    {
        [ -s "$rc" ] && printf '\n'
        printf '%s\n' "$CC_BLOCK_BEGIN"
        printf "export CLAUDE_PROFILES_DIR='%s'\n" "$root"
        printf "CCP_COMMAND='%s'\n" "$cmd"
        printf '[ -r "$CLAUDE_PROFILES_DIR/.ccp/ccp.sh" ] && . "$CLAUDE_PROFILES_DIR/.ccp/ccp.sh"\n'
        printf '%s\n' "$CC_BLOCK_END"
    } >>"$rc" || return 1
    printf 'Registered the %s command in %s\n' "$cmd" "$rc"

    if [ -n "$legacy" ]; then
        printf '\nWarning: %s already has its own %s function/alias and/or CLAUDE_CONFIG_DIR setting:\n' "$rc" "$cmd"
        printf '%s\n' "$legacy" | sed 's/^/    line /'
        printf 'The new command replaces an older one, but a hard-coded CLAUDE_CONFIG_DIR\n'
        printf 'overrides the "global" default and the persisted "env" default. Remove those lines.\n'
    fi

    # --- first profile ---------------------------------------------------
    export CLAUDE_PROFILES_DIR="$root"
    CCP_COMMAND="$cmd"
    # shellcheck source=lib/ccp.sh
    . "$root/.ccp/ccp.sh"

    # Three cases, one question each:
    #   profiles already there        -> only offer to pick the default among them
    #   none, native config found     -> offer to migrate it
    #   none, nothing to migrate      -> offer to create the first profile
    name=""
    if [ "$assume_yes" -eq 0 ]; then
        printf '\n'
        if [ -n "$(_ccp_profiles)" ]; then
            printf 'Profiles found in %s (kept as they are, ready to use):\n' "$root"
            _ccp_list
            if _ccp_has_native; then
                printf 'Note: ~/.claude is not managed by %s. To move it into a profile later:\n' "$cmd"
                printf '  %s add <profile> --migrate\n' "$cmd"
            fi
            _cci_ask 'Which of these profiles should be the default (empty to skip)? ' ''
            if [ -n "$_CCI_REPLY" ] && name="$(_ccp_resolve "$_CCI_REPLY")"; then
                _CCP_INSTALLER=1 _ccp_main default "$name"
            elif [ -n "$_CCI_REPLY" ]; then
                printf 'No default set. Later: %s default <profile>, or %s add <profile> for a new one.\n' "$cmd" "$cmd"
            fi
            name=""
        elif _ccp_has_native; then
            printf 'Found your current Claude Code configuration (~/.claude, ~/.claude.json).\n'
            printf 'Migrating moves it into a %s profile, so you keep your settings, history and login.\n' "$cmd"
            _cci_ask 'Profile name to migrate it to (empty to skip): ' ''
            name="$_CCI_REPLY"
            if [ -n "$name" ]; then
                _ccp_main add "$name" --migrate || name=""
            else
                printf 'Not migrated. Later: %s add <profile> --migrate\n' "$cmd"
            fi
        else
            _cci_ask 'Name of your first profile (empty to skip): ' ''
            name="$_CCI_REPLY"
            if [ -n "$name" ]; then _ccp_main add "$name" || name=""; fi
        fi
        if [ -n "$name" ] && _cci_yes "Make '$name' the default profile? [Y/n] " y; then
            _CCP_INSTALLER=1 _ccp_main default "$name"
        fi
    fi

    printf '\nDone. Open a new terminal or run:  . %s\n' "$rc"
    printf 'Then try:  %s help\n' "$cmd"
}

# Remove what the installer added: the rc block (from every rc file we may have
# written) and <profiles>/.ccp. Profiles are never removed.
cc_uninstall_main() {
    local os="$1" root="" rc dir cmd="" roots="" found=0
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)
                root="${2-}"
                [ $# -ge 2 ] && shift
                ;;
            --dir=*) root="${1#*=}" ;;
            -h | --help)
                cat <<EOF
Usage: uninstall-$os.sh [--dir <path>]

Removes the profile command from the shell rc files and deletes <profiles>/.ccp.
Profiles, their content and any ~/.claude symlinks are never removed.

  --dir <path>   profiles directory (default: the one recorded at install time)
EOF
                return 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
        shift
    done

    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "${ZDOTDIR:+$ZDOTDIR/.zshrc}"; do
        [ -n "$rc" ] && [ -f "$rc" ] || continue
        grep -qF "$CC_BLOCK_BEGIN" "$rc" || continue
        dir="$(sed -n "s/^export CLAUDE_PROFILES_DIR='\\(.*\\)'\$/\\1/p" "$rc" | tail -n 1)"
        [ -z "$cmd" ] && cmd="$(sed -n "s/^CCP_COMMAND='\\(.*\\)'\$/\\1/p" "$rc" | tail -n 1)"
        [ -n "$dir" ] && roots="$roots$dir
"
        _cci_strip_block "$rc" || return 1
        printf 'Removed the command from %s\n' "$rc"
        found=1
    done

    # An explicit --dir wins; otherwise clean every directory an rc block named,
    # plus the default location.
    if [ -n "$root" ]; then
        case "$root" in
            "~") root="$HOME" ;;
            "~/"*) root="$HOME/${root#\~/}" ;;
            /*) ;;
            *) root="$PWD/$root" ;;
        esac
        roots="${root%/}"
    else
        roots="$roots${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
    fi
    while IFS= read -r dir; do
        [ -n "$dir" ] && [ -d "$dir/.ccp" ] || continue
        rm -rf "$dir/.ccp" || return 1
        printf 'Removed %s/.ccp\n' "$dir"
        printf 'Profiles in %s were left untouched.\n' "$dir"
        found=1
    done <<EOF
$(printf '%s\n' "$roots" | sort -u)
EOF

    if [ "$found" -eq 0 ]; then
        printf 'Nothing to uninstall: no rc block and no .ccp directory found.\n'
        return 0
    fi
    printf '\nProfiles and any ~/.claude, ~/.claude.json symlinks were kept.\n'
    printf 'Open a new terminal, or run:  unset -f %s\n' "${cmd:-ccp}"
}
