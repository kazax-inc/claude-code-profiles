#!/usr/bin/env bash
# Remove the `ccp` Claude Code profile manager on Linux. Profiles are never removed.
set -u

if [ "$(uname -s)" != Linux ]; then
    printf 'This uninstaller is for Linux; use uninstall-macos.sh or uninstall-windows.ps1.\n' >&2
    exit 1
fi

# shellcheck source=lib/install-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/install-common.sh"
cc_uninstall_main linux "$@"
