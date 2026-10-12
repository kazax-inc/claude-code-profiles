#!/usr/bin/env bash
# Install the `ccp` Claude Code profile manager on Linux (bash or zsh).
set -u

if [ "$(uname -s)" != Linux ]; then
    printf 'This installer is for Linux; use install-macos.sh or install-windows.ps1.\n' >&2
    exit 1
fi

# shellcheck source=lib/install-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/install-common.sh"
cc_install_main linux "$@"
