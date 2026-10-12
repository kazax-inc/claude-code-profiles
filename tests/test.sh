#!/usr/bin/env bash
# Tests for lib/ccp.sh and the Unix installer, run in a throw-away $HOME.
# Usage: tests/test.sh [shell ...]     (default: bash, plus zsh when installed)
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
total=0
unset CLAUDE_CONFIG_DIR CLAUDE_PROFILES_DIR

# run <snippet>: evaluate a snippet in the shell under test with ccp.sh loaded.
run() {
    HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" CLAUDE_PROFILES_DIR="$root" \
        "$sh" -c ". '$repo/lib/ccp.sh'; $1" 2>&1 </dev/null
}

check() { # check <description> <expected substring> <actual>
    total=$((total + 1))
    case "$3" in
        *"$2"*) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL [%s] %s\n  expected: %s\n  actual:   %s\n' "$sh" "$1" "$2" "$3"
            ;;
    esac
}

suite() {
    sandbox="$(mktemp -d)"
    root="$sandbox/home/.claude-profiles"
    mkdir -p "$sandbox/home" "$sandbox/bin"
    printf '#!/bin/sh\necho "claude dir=${CLAUDE_CONFIG_DIR-unset} args=$*"\n' >"$sandbox/bin/claude"
    chmod +x "$sandbox/bin/claude"
    local h="$sandbox/home" out

    check 'list when empty' 'No profiles' "$(run 'ccp list')"
    check 'no profile message' 'no profile found' "$(run 'ccp')"
    check 'no profile shows help' 'ccp add <profile>' "$(run 'ccp')"
    check 'add' "Profile 'work' created" "$(run 'ccp add work')"
    check 'add twice warns' 'already exists' "$(run 'ccp add work')"
    check 'add twice fails' 'rc=1' "$(run 'ccp add work; echo rc=$?')"
    check 'reserved name' 'invalid profile name' "$(run 'ccp add default')"
    check 'bad name' 'invalid profile name' "$(run 'ccp add ../x')"
    run 'ccp add personal' >/dev/null
    run 'ccp add perso2' >/dev/null

    check 'run profile' "dir=$root/work args=-p hi there" "$(run 'ccp work -p "hi there"')"
    check 'unique prefix' "dir=$root/work args=" "$(run 'ccp w')"
    check 'ambiguous prefix' 'ambiguous' "$(run 'ccp pers')"
    check 'unknown profile' 'unknown profile' "$(run 'ccp nope')"
    check 'env not leaked' 'after=unset' "$(run 'ccp work >/dev/null; echo after=${CLAUDE_CONFIG_DIR-unset}')"

    pick() { printf '%s\n' "$1" | HOME="$h" PATH="$sandbox/bin:$PATH" CLAUDE_PROFILES_DIR="$root" "$sh" -c ". '$repo/lib/ccp.sh'; $2" 2>&1; }
    check 'pick lists profiles' '3) work' "$(pick 3 'ccp')"
    check 'pick by number' "dir=$root/work args=--resume" "$(pick 3 'ccp --resume')"
    check 'pick by name' "dir=$root/personal args=" "$(pick personal 'ccp')"
    check 'pick nothing' 'no profile selected' "$(run 'ccp')"
    check 'pick invalid' 'no profile selected' "$(pick 9 'ccp')"

    check 'method link' 'default -> work' "$(run 'ccp default work --method link')"
    check 'ccp uses link' "dir=$root/work args=" "$(run 'ccp')"
    check 'ccp passes flags' "dir=$root/work args=--resume" "$(run 'ccp --resume')"
    check 'ccp -- args' "dir=$root/work args=prompt" "$(run 'ccp -- prompt')"
    check 'relink' "dir=$root/personal" "$(run 'ccp default personal -m 3 >/dev/null; ccp')"

    check 'method env' "dir=$root/work" "$(run 'ccp default work -m env --no-persist >/dev/null; claude')"
    check 'env not persisted' 'dir=unset' "$(run 'claude')"
    run 'ccp default work -m env --persist' >/dev/null
    check 'env persisted' "dir=$root/work" "$(run 'claude')"
    check 'inherited env wins' 'CLAUDE_CONFIG_DIR=/elsewhere' "$(CLAUDE_CONFIG_DIR=/elsewhere run 'ccp default')"
    check 'unset env' 'dir=unset' "$(run 'ccp default --unset -m env >/dev/null; claude')"
    check 'unset env persisted' 'dir=unset' "$(run 'claude')"

    out="$(run 'ccp default work --method global')"
    check 'method global' "$h/.claude -> $root/default" "$out"
    check 'global dir link' "$root/default" "$(readlink "$h/.claude")"
    check 'global json link' "$root/default/.claude.json" "$(readlink "$h/.claude.json")"
    check 'list tags' 'work [link] [global]' "$(run 'ccp list')"
    check 'show' "global  ~/.claude -> $root/work" "$(run 'ccp default')"
    run 'ccp default --unset -m global' >/dev/null
    check 'unset global' 'gone' "$([ -L "$h/.claude" ] || [ -L "$h/.claude.json" ] || echo gone)"

    mkdir "$h/.claude"
    echo settings >"$h/.claude/settings.json"
    echo '{}' >"$h/.claude.json"
    check 'global refuses real dir' 'is not a symlink' "$(run 'ccp default work -m global')"
    check 'migrate' "Moved $h/.claude ->" "$(run 'ccp add old --migrate')"
    check 'migrated files' 'settings' "$(cat "$root/old/settings.json" 2>&1)"
    check 'migrated json' '{}' "$(cat "$root/old/.claude.json" 2>&1)"
    check 'nothing to migrate' 'nothing to migrate' "$(run 'ccp add again --migrate')"

    check 'interactive menu' 'default -> old' "$(printf '3\n' | HOME="$h" CLAUDE_PROFILES_DIR="$root" "$sh" -c ". '$repo/lib/ccp.sh'; ccp default old" 2>&1)"

    # Installer (always bash), registering into the rc file of the shell under test.
    local ihome="$sandbox/ihome" rc before
    mkdir -p "$ihome/.claude"
    echo '{}' >"$ihome/.claude.json"
    case "${sh##*/}" in zsh) rc="$ihome/.zshrc" ;; *) rc="$ihome/.bashrc" ;; esac
    printf 'export CLAUDE_CONFIG_DIR=/legacy\n' >"$rc"
    # answers: directory (default), command name (default), migrate, profile name, make default, method
    out="$(printf '\n\ny\nmain\ny\n2\n' | HOME="$ihome" SHELL="/bin/${sh##*/}" ZDOTDIR='' CLAUDE_PROFILES_DIR='' \
        bash "$repo/install-linux.sh" 2>&1)"
    check 'installer registers' "Registered the ccp command in $rc" "$out"
    check 'installer warns legacy' 'line 1:export CLAUDE_CONFIG_DIR=/legacy' "$out"
    check 'installer migrates' "$ihome/.claude-profiles/default" "$(readlink "$ihome/.claude")"
    HOME="$ihome" SHELL="/bin/${sh##*/}" ZDOTDIR='' bash "$repo/install-linux.sh" --yes >/dev/null 2>&1
    check 'installer idempotent' '1' "$(grep -c '>>> claude-profiles >>>' "$rc")"
    check 'rc loads ccp' "dir=$ihome/.claude-profiles/main" \
        "$(HOME="$ihome" PATH="$sandbox/bin:$PATH" "$sh" -c "unset CLAUDE_CONFIG_DIR; . '$rc'; unset CLAUDE_CONFIG_DIR; ccp")"
    before="$(cd "$ihome/.claude-profiles" && find . -path ./.ccp -prune -o -print | sort; readlink "$ihome/.claude" "$ihome/.claude.json")"
    out="$(HOME="$ihome" ZDOTDIR='' CLAUDE_PROFILES_DIR='' bash "$repo/uninstall-linux.sh" 2>&1)"
    check 'uninstall reports rc' "Removed the command from $rc" "$out"
    check 'uninstall reports dir' "Removed $ihome/.claude-profiles/.ccp" "$out"
    check 'uninstall strips rc' '0' "$(grep -c 'claude-profiles' "$rc")"
    check 'uninstall keeps rest of rc' 'export CLAUDE_CONFIG_DIR=/legacy' "$(cat "$rc")"
    check 'uninstall removes helper' 'gone' "$([ -e "$ihome/.claude-profiles/.ccp" ] || echo gone)"
    check 'uninstall keeps profiles and links' "$before" \
        "$(cd "$ihome/.claude-profiles" && find . -path ./.ccp -prune -o -print | sort; readlink "$ihome/.claude" "$ihome/.claude.json")"
    check 'uninstall keeps profile content' '{}' "$(cat "$ihome/.claude-profiles/main/.claude.json")"
    check 'uninstall twice' 'Nothing to uninstall' "$(HOME="$ihome" ZDOTDIR='' CLAUDE_PROFILES_DIR='' bash "$repo/uninstall-linux.sh" 2>&1)"
    # A custom profiles directory is found through the rc block.
    HOME="$ihome" SHELL="/bin/${sh##*/}" ZDOTDIR='' bash "$repo/install-linux.sh" --yes --dir "$sandbox/custom" >/dev/null 2>&1
    mkdir "$sandbox/custom/keepme"
    out="$(HOME="$ihome" ZDOTDIR='' CLAUDE_PROFILES_DIR='' bash "$repo/uninstall-linux.sh" 2>&1)"
    check 'uninstall custom dir' "Removed $sandbox/custom/.ccp" "$out"
    check 'uninstall custom dir keeps profiles' 'kept' "$([ -d "$sandbox/custom/keepme" ] && echo kept)"

    # Installing over a directory that already holds profiles must not touch them.
    local ehome="$sandbox/ehome" eroot="$sandbox/ehome/.claude-profiles" before
    mkdir -p "$eroot/alpha/projects" "$eroot/beta"
    echo creds >"$eroot/alpha/.credentials.json"
    echo '{"a":1}' >"$eroot/alpha/.claude.json"
    echo note >"$eroot/alpha/projects/x"
    ln -s beta "$eroot/default"
    before="$(cd "$eroot" && find alpha beta | sort | xargs ls -ld --time-style=full-iso; cat alpha/.credentials.json alpha/.claude.json)"
    # answers: directory (default), command name (default), existing profile name, make default, method link
    out="$(printf '\n\nalpha\ny\n3\n' | HOME="$ehome" SHELL="/bin/${sh##*/}" ZDOTDIR='' CLAUDE_PROFILES_DIR='' \
        bash "$repo/install-linux.sh" 2>&1)"
    check 'existing profiles listed' 'beta [link]' "$out"
    check 'existing profile reused' "Profile 'alpha' already exists; using it as it is." "$out"
    check 'existing profile made default' 'default -> alpha' "$out"
    HOME="$ehome" SHELL="/bin/${sh##*/}" ZDOTDIR='' bash "$repo/install-linux.sh" --yes >/dev/null 2>&1
    check 'existing profiles untouched' "$before" \
        "$(cd "$eroot" && find alpha beta | sort | xargs ls -ld --time-style=full-iso; cat alpha/.credentials.json alpha/.claude.json)"
    check 'existing profile usable' "dir=$eroot/alpha" \
        "$(HOME="$ehome" PATH="$sandbox/bin:$PATH" CLAUDE_PROFILES_DIR="$eroot" "$sh" -c ". '$eroot/.ccp/ccp.sh'; ccp alpha")"

    # Command name chosen at install time.
    local nhome="$sandbox/nhome" nrc
    mkdir -p "$nhome/.claude-profiles/solo"
    case "${sh##*/}" in zsh) nrc="$nhome/.zshrc" ;; *) nrc="$nhome/.bashrc" ;; esac
    inst() { HOME="$nhome" SHELL="/bin/${sh##*/}" ZDOTDIR='' CLAUDE_PROFILES_DIR='' bash "$repo/install-linux.sh" "$@" 2>&1; }
    check 'name claude refused' 'cannot be used' "$(inst --yes --name claude; echo "rc=$?")"
    check 'name claude not installed' 'absent' "$([ -e "$nrc" ] || echo absent)"
    check 'name Claude refused' 'cannot be used' "$(inst --yes --name Claude)"
    check 'invalid name refused' 'Invalid command name' "$(inst --yes --name 'a b')"
    check 'name cc declined' 'system C compiler' "$(printf 'n\n' | inst --name cc --dir "$nhome/.claude-profiles")"
    check 'name cc declined: nothing installed' 'absent' "$([ -e "$nrc" ] || echo absent)"
    # answers: directory, claude (refused), cc (warned, declined), cx, profile (skip)
    out="$(printf '\nclaude\ncc\nn\ncx\n\n' | inst)"
    check 'prompt refuses claude' 'cannot be used' "$out"
    check 'prompt warns on cc' 'system C compiler' "$out"
    check 'prompt registers custom name' "Registered the cx command in $nrc" "$out"
    check 'custom name runs' "dir=$nhome/.claude-profiles/solo" \
        "$(HOME="$nhome" PATH="$sandbox/bin:$PATH" "$sh" -c "unset CLAUDE_CONFIG_DIR; . '$nrc'; cx solo")"
    check 'custom name in messages' 'cx: unknown profile' \
        "$(HOME="$nhome" PATH="$sandbox/bin:$PATH" "$sh" -c ". '$nrc'; cx nope" 2>&1)"
    check 'default name not defined' 'undefined' \
        "$(HOME="$nhome" "$sh" -c ". '$nrc'; type ccp >/dev/null 2>&1 || echo undefined")"
    out="$(printf 'y\n\n' | inst --name cc --dir "$nhome/.claude-profiles")"
    check 'name cc accepted after warning' "Registered the cc command in $nrc" "$out"
    check 'cc runs' "dir=$nhome/.claude-profiles/solo" \
        "$(HOME="$nhome" PATH="$sandbox/bin:$PATH" "$sh" -c "unset CLAUDE_CONFIG_DIR; . '$nrc'; cc solo")"

    rm -rf "$sandbox"
}

if [ $# -eq 0 ]; then
    set -- bash
    command -v zsh >/dev/null 2>&1 && set -- bash zsh
fi
for sh in "$@"; do
    suite
done

printf '%d checks, %d failed\n' "$total" "$fail"
[ "$fail" -eq 0 ]
