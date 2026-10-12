# ccp.sh - Claude Code multi-profile manager for bash (>= 3.2) and zsh.
#
# Sourced from the shell rc file by the install script. Every profile is a
# directory under $CLAUDE_PROFILES_DIR (default: ~/.claude-profiles) that is
# handed to Claude Code through CLAUDE_CONFIG_DIR.
#
# Portability notes: this file must stay valid in bash 3.2 and zsh, so no
# arrays, no ${var,,}, and no variables named `path` or `status` (zsh).

# Name of the command. The installer writes CCP_COMMAND to the rc block; it
# must never be `claude`, which this function has to be able to call.
_CCP_CMD="${CCP_COMMAND:-ccp}"
case "$_CCP_CMD" in
    '' | [!A-Za-z]* | *[!A-Za-z0-9_-]* | [cC][lL][aA][uU][dD][eE])
        printf 'ccp: invalid command name "%s"; using ccp instead\n' "$_CCP_CMD" >&2
        _CCP_CMD=ccp
        ;;
esac
unalias "$_CCP_CMD" 2>/dev/null

_ccp_root() { printf '%s' "${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"; }

_ccp_err() { printf '%s: %s\n' "$_CCP_CMD" "$*" >&2; }

# Physical path of a directory, or failure if it cannot be entered.
_ccp_real() { (CDPATH='' cd -P -- "$1" >/dev/null 2>&1 && pwd -P); }

_ccp_valid_name() {
    case "${1-}" in
        '' | .* | -* | *[!A-Za-z0-9._-]*) return 1 ;;
        default | add | list | ls | help) return 1 ;;
    esac
    return 0
}

# Print one profile name per line.
_ccp_profiles() {
    [ -n "${ZSH_VERSION-}" ] && setopt local_options null_glob
    local d
    for d in "$(_ccp_root)"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        [ "$d" = default ] && continue
        printf '%s\n' "$d"
    done
}

# Resolve an exact profile name or a unique prefix of one. Prints the name.
_ccp_resolve() {
    local root name p match count
    root="$(_ccp_root)"
    name="${1-}"
    if ! _ccp_valid_name "$name"; then
        _ccp_err "invalid profile name: '$name'"
        return 1
    fi
    if [ -d "$root/$name" ]; then
        printf '%s' "$name"
        return 0
    fi
    match=""
    count=0
    while IFS= read -r p; do
        case "$p" in
            "$name"*)
                match="${match:+$match, }$p"
                count=$((count + 1))
                ;;
        esac
    done <<EOF
$(_ccp_profiles)
EOF
    if [ "$count" -eq 1 ]; then
        printf '%s' "$match"
        return 0
    fi
    if [ "$count" -gt 1 ]; then
        _ccp_err "'$name' is ambiguous: $match"
    else
        _ccp_err "unknown profile or command: '$name' (see: $_CCP_CMD list, $_CCP_CMD help)"
    fi
    return 1
}

# Name of the profile the <root>/default symlink points to.
_ccp_default_name() {
    local root real
    root="$(_ccp_root)"
    [ -L "$root/default" ] || return 1
    real="$(_ccp_real "$root/default")" || return 1
    printf '%s' "${real##*/}"
}

# Ask a question on stderr; the answer (or the default) lands in _CCP_REPLY.
_ccp_ask() {
    printf '%s' "$1" >&2
    _CCP_REPLY=""
    IFS= read -r _CCP_REPLY || true
    [ -n "$_CCP_REPLY" ] || _CCP_REPLY="${2-}"
}

_ccp_run() {
    local dir
    dir="$(_ccp_root)/$1"
    shift
    if [ ! -d "$dir" ]; then
        _ccp_err "profile directory missing: $dir"
        return 1
    fi
    CLAUDE_CONFIG_DIR="$dir" command claude "$@"
}

# True if ~/.claude or ~/.claude.json exists as a real (non-symlink) entry.
_ccp_has_native() {
    if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then return 0; fi
    if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then return 0; fi
    return 1
}

_ccp_add() {
    local name="" migrate=0 root dir
    while [ $# -gt 0 ]; do
        case "$1" in
            --migrate) migrate=1 ;;
            -*)
                _ccp_err "add: unknown option: $1"
                return 2
                ;;
            *)
                if [ -n "$name" ]; then
                    _ccp_err "add: only one profile name expected"
                    return 2
                fi
                name="$1"
                ;;
        esac
        shift
    done
    if [ -z "$name" ]; then
        _ccp_err "usage: $_CCP_CMD add <profile> [--migrate]"
        return 2
    fi
    if ! _ccp_valid_name "$name"; then
        _ccp_err "invalid profile name: '$name' (letters, digits, '.', '_', '-'; reserved: default add list ls help)"
        return 2
    fi
    root="$(_ccp_root)"
    dir="$root/$name"
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        printf '%s: warning: profile '\''%s'\'' already exists: %s\n' "$_CCP_CMD" "$name" "$dir" >&2
        return 1
    fi
    if [ "$migrate" -eq 1 ] && ! _ccp_has_native; then
        _ccp_err "nothing to migrate: ~/.claude and ~/.claude.json are missing or already symlinks"
        return 1
    fi
    mkdir -p "$root" || return 1

    if [ "$migrate" -eq 1 ]; then
        if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then
            mv "$HOME/.claude" "$dir" || return 1
            printf 'Moved %s -> %s\n' "$HOME/.claude" "$dir"
        else
            mkdir "$dir" || return 1
        fi
        if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then
            mv "$HOME/.claude.json" "$dir/.claude.json" || return 1
            printf 'Moved %s -> %s\n' "$HOME/.claude.json" "$dir/.claude.json"
        fi
        printf 'Profile '\''%s'\'' created from the existing Claude Code configuration.\n' "$name"
        printf 'Plain `claude` no longer finds ~/.claude: run `%s default %s` (method "global" or "env").\n' "$_CCP_CMD" "$name"
    else
        mkdir "$dir" || return 1
        printf 'Profile '\''%s'\'' created: %s\n' "$name" "$dir"
        printf 'Start it with `%s %s` and log in with /login.\n' "$_CCP_CMD" "$name"
    fi
}

_ccp_set_link() {
    local root link
    root="$(_ccp_root)"
    link="$root/default"
    if [ -L "$link" ]; then
        rm -f "$link" || return 1
    elif [ -e "$link" ]; then
        _ccp_err "$link exists and is not a symlink"
        return 1
    fi
    # Relative target, so the profiles directory can be moved as a whole.
    ln -s "$1" "$link" || return 1
    printf 'default -> %s  (%s)\n' "$1" "$link"
}

_ccp_set_global() {
    local root f
    root="$(_ccp_root)"
    for f in "$HOME/.claude" "$HOME/.claude.json"; do
        if [ -e "$f" ] && [ ! -L "$f" ]; then
            _ccp_err "$f exists and is not a symlink; migrate it first ($_CCP_CMD add <profile> --migrate) or move it away"
            return 1
        fi
    done
    _ccp_set_link "$1" || return 1
    rm -f "$HOME/.claude" "$HOME/.claude.json" || return 1
    ln -s "$root/default" "$HOME/.claude" || return 1
    ln -s "$root/default/.claude.json" "$HOME/.claude.json" || return 1
    printf '%s -> %s\n' "$HOME/.claude" "$root/default"
    printf '%s -> %s\n' "$HOME/.claude.json" "$root/default/.claude.json"
    if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
        printf '%s: warning: CLAUDE_CONFIG_DIR is set in this shell (%s) and takes precedence over ~/.claude.\n' "$_CCP_CMD" "$CLAUDE_CONFIG_DIR" >&2
        printf '    Clear it with: %s default --unset --method env\n' "$_CCP_CMD" >&2
    fi
}

# $1 = profile, $2 = 1 | 0 | "" (ask)
_ccp_set_env() {
    local root persist
    root="$(_ccp_root)"
    persist="${2-}"
    export CLAUDE_CONFIG_DIR="$root/$1"
    printf 'CLAUDE_CONFIG_DIR=%s  (this shell session)\n' "$CLAUDE_CONFIG_DIR"
    if [ -n "${_CCP_INSTALLER-}" ]; then
        persist=1
    elif [ -z "$persist" ]; then
        _ccp_ask "Also use '$1' in new shell sessions? [y/N] " n
        case "$_CCP_REPLY" in
            [yY]*) persist=1 ;;
            *) persist=0 ;;
        esac
    fi
    if [ "$persist" = 1 ]; then
        mkdir -p "$root/.ccp" || return 1
        printf '%s\n' "$1" >"$root/.ccp/env-default" || return 1
        printf 'New shell sessions will export CLAUDE_CONFIG_DIR for '\''%s'\''.\n' "$1"
    fi
}

# Read a method into _CCP_REPLY (env | global | link).
_ccp_pick_method() {
    local root
    root="$(_ccp_root)"
    {
        printf '%s\n' "$1"
        printf '  1) %-24s%18s -> env     export CLAUDE_CONFIG_DIR\n' 'this shell session' '(`claude` command)'
        printf '  2) %-24s%18s -> symlink ~/.claude, ~/.claude.json\n' 'global, all shells' '(`claude` command)'
        printf '  3) %-24s%18s -> link    symlink %s/default\n' "\`$_CCP_CMD\` without a profile" "(\`$_CCP_CMD\` command)" "$root"
    } >&2
    _ccp_ask 'Method [1-3]: ' ''
}

_ccp_default_show() {
    local root name target
    root="$(_ccp_root)"

    if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
        printf 'env     CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
    else
        printf 'env     not set\n'
    fi
    if [ -r "$root/.ccp/env-default" ]; then
        IFS= read -r name <"$root/.ccp/env-default"
        printf '        new shell sessions: %s\n' "$name"
    fi

    if [ -L "$HOME/.claude" ]; then
        target="$(_ccp_real "$HOME/.claude")" || target="$(readlink "$HOME/.claude") (broken)"
        printf 'global  ~/.claude -> %s\n' "$target"
    elif [ -e "$HOME/.claude" ]; then
        printf 'global  not managed (~/.claude is a real directory)\n'
    else
        printf 'global  not set\n'
    fi

    if name="$(_ccp_default_name)"; then
        printf 'link    default -> %s\n' "$name"
    else
        printf 'link    not set\n'
    fi
}

_ccp_default_unset() {
    local root f
    root="$(_ccp_root)"
    case "$1" in
        env)
            unset CLAUDE_CONFIG_DIR
            rm -f "$root/.ccp/env-default"
            printf 'CLAUDE_CONFIG_DIR unset (this session and new ones).\n'
            ;;
        global)
            for f in "$HOME/.claude" "$HOME/.claude.json"; do
                if [ -L "$f" ]; then
                    case "$(readlink "$f")" in
                        "$root"/*)
                            rm -f "$f"
                            printf 'Removed symlink %s\n' "$f"
                            ;;
                        *) _ccp_err "$f does not point into $root; left untouched" ;;
                    esac
                fi
            done
            ;;
        link)
            if [ -L "$root/default" ]; then
                rm -f "$root/default"
                printf 'Removed %s\n' "$root/default"
            fi
            if [ -L "$HOME/.claude" ] && [ "$(readlink "$HOME/.claude")" = "$root/default" ]; then
                _ccp_err "warning: ~/.claude still points to it ($_CCP_CMD default --unset --method global)"
            fi
            ;;
    esac
}

_ccp_default() {
    local name="" method="" persist="" unset_mode=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -m | --method)
                if [ $# -lt 2 ]; then
                    _ccp_err "default: $1 needs a value (env, global or link)"
                    return 2
                fi
                method="$2"
                shift
                ;;
            --method=*) method="${1#*=}" ;;
            --persist) persist=1 ;;
            --no-persist) persist=0 ;;
            --unset) unset_mode=1 ;;
            -*)
                _ccp_err "default: unknown option: $1"
                return 2
                ;;
            *) name="$1" ;;
        esac
        shift
    done

    if [ "$unset_mode" -eq 0 ]; then
        if [ -z "$name" ]; then
            _ccp_default_show
            return 0
        fi
        name="$(_ccp_resolve "$name")" || return 1
    fi

    if [ -z "$method" ]; then
        if [ "$unset_mode" -eq 1 ]; then
            _ccp_pick_method 'Which default should be removed?'
        else
            _ccp_pick_method "How should '$name' become the default profile?"
        fi
        method="$_CCP_REPLY"
    fi
    case "$method" in
        1 | env) method=env ;;
        2 | global) method=global ;;
        3 | link) method=link ;;
        *)
            _ccp_err "default: unknown method '$method' (expected env, global or link)"
            return 2
            ;;
    esac

    if [ "$unset_mode" -eq 1 ]; then
        _ccp_default_unset "$method"
        return $?
    fi
    case "$method" in
        env) _ccp_set_env "$name" "$persist" ;;
        global) _ccp_set_global "$name" ;;
        link) _ccp_set_link "$name" ;;
    esac
}

_ccp_list() {
    local root p tags link_name env_real global_real real any=0
    root="$(_ccp_root)"
    link_name="$(_ccp_default_name)" || link_name=""
    env_real=""
    if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
        env_real="$(_ccp_real "$CLAUDE_CONFIG_DIR")" || env_real=""
    fi
    global_real=""
    if [ -L "$HOME/.claude" ]; then
        global_real="$(_ccp_real "$HOME/.claude")" || global_real=""
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        any=1
        tags=""
        real="$(_ccp_real "$root/$p")" || real=""
        [ "$p" = "$link_name" ] && tags="$tags [link]"
        [ -n "$real" ] && [ "$real" = "$global_real" ] && tags="$tags [global]"
        [ -n "$real" ] && [ "$real" = "$env_real" ] && tags="$tags [env]"
        printf '  %s%s\n' "$p" "$tags"
    done <<EOF
$(_ccp_profiles)
EOF
    if [ "$any" -eq 0 ]; then
        printf 'No profiles in %s. Create one with: %s add <profile>\n' "$root" "$_CCP_CMD"
    fi
}

_ccp_help() {
    local c="$_CCP_CMD"
    printf 'Claude Code profile manager - profiles live in %s\n\n' "$(_ccp_root)"
    printf '  %s\n      %s\n' \
        "$c [claude args...]" \
        'run claude with the default profile (method "link"), or pick a profile from a list when no default is set' \
        "$c <profile> [claude args...]" \
        'run claude with a profile (unique prefixes work)' \
        "$c -- [claude args...]" \
        'run the default profile with arguments that do not start with "-"' \
        "$c add <profile> [--migrate]" \
        'create a profile; --migrate moves ~/.claude and ~/.claude.json into it' \
        "$c default" \
        'show the current defaults' \
        "$c default <profile> [--method env|global|link] [--persist|--no-persist]" \
        'set the default profile (asks for the method if omitted)'
    printf '      %s\n' \
        'env     export CLAUDE_CONFIG_DIR: plain `claude` in this shell session' \
        '        (--persist: also in new shell sessions)' \
        'global  symlink ~/.claude and ~/.claude.json to the profile: every `claude`' \
        "link    symlink <profiles>/default to the profile: \`$c\` without a profile"
    printf '  %s\n      %s\n' \
        "$c default --unset [--method env|global|link]" \
        'remove a default' \
        "$c list" \
        'list profiles and which default points at them' \
        "$c help" \
        'this help'
}

# No default profile: let the user choose one from a numbered list. The chosen
# name lands in _CCP_REPLY. Without any profile, say so and show the help.
_ccp_pick_profile() {
    local p n=0 choice picked=""
    if [ -z "$(_ccp_profiles)" ]; then
        _ccp_err "no profile found in $(_ccp_root)"
        _ccp_help >&2
        return 1
    fi
    printf 'No default profile. Select a profile:\n' >&2
    while IFS= read -r p; do
        n=$((n + 1))
        printf '  %d) %s\n' "$n" "$p" >&2
    done <<EOF
$(_ccp_profiles)
EOF
    _ccp_ask "Profile [1-$n]: " ''
    choice="$_CCP_REPLY"
    n=0
    while IFS= read -r p; do
        n=$((n + 1))
        if [ "$choice" = "$n" ] || [ "$choice" = "$p" ]; then picked="$p"; fi
    done <<EOF
$(_ccp_profiles)
EOF
    if [ -z "$picked" ]; then
        _ccp_err "no profile selected (set a default with: $_CCP_CMD default <profile>)"
        return 1
    fi
    _CCP_REPLY="$picked"
}

_ccp_main() {
    local cmd="${1-}" name
    case "$cmd" in
        add)
            shift
            _ccp_add "$@"
            ;;
        default)
            shift
            _ccp_default "$@"
            ;;
        list | ls) _ccp_list ;;
        help | -h | --help) _ccp_help ;;
        '' | -*)
            [ "$cmd" = "--" ] && shift
            if ! name="$(_ccp_default_name)"; then
                _ccp_pick_profile || return 1
                name="$_CCP_REPLY"
            fi
            _ccp_run "$name" "$@"
            ;;
        *)
            shift
            name="$(_ccp_resolve "$cmd")" || return 1
            _ccp_run "$name" "$@"
            ;;
    esac
}

# Default persisted by `ccp default <profile> --method env --persist`. An
# inherited CLAUDE_CONFIG_DIR wins, so shells started from `ccp <profile>`
# keep that profile.
if [ -z "${CLAUDE_CONFIG_DIR-}" ] && [ -r "$(_ccp_root)/.ccp/env-default" ]; then
    IFS= read -r _CCP_REPLY <"$(_ccp_root)/.ccp/env-default"
    if _ccp_valid_name "$_CCP_REPLY" && [ -d "$(_ccp_root)/$_CCP_REPLY" ]; then
        export CLAUDE_CONFIG_DIR="$(_ccp_root)/$_CCP_REPLY"
    fi
fi
unset _CCP_REPLY

eval "$_CCP_CMD() { _ccp_main \"\$@\"; }"
