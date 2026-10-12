#!/bin/bash
# Install the `ccp` Claude Code profile manager on macOS (zsh, or bash).
set -u

if [ "$(uname -s)" != Darwin ]; then
    printf 'This installer is for macOS; use install-linux.sh or install-windows.ps1.\n' >&2
    exit 1
fi

# shellcheck source=lib/install-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/install-common.sh"
cc_install_main macos "$@"
