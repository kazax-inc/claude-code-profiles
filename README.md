# Claude Code Profiles

Multi-profile manager for Claude Code: one `ccp` command to create profiles
(accounts), launch `claude` with any of them, and choose the default one.
Works on Linux (bash, zsh), macOS (zsh, bash) and Windows (PowerShell 5.1 / 7).

Each profile is a plain Claude Code config directory under `~/.claude-profiles/`
(settings, credentials, history, `.claude.json`), selected through
`CLAUDE_CONFIG_DIR`.

## Install

| OS      | Command                                                          | Registers `ccp` in                                       |
| ------- | ---------------------------------------------------------------- | -------------------------------------------------------- |
| Linux   | `./install-linux.sh`                                             | `~/.bashrc` or `~/.zshrc` (from `$SHELL`)                |
| macOS   | `./install-macos.sh`                                             | `~/.zshrc` (or `~/.bash_profile`)                        |
| Windows | `powershell -ExecutionPolicy Bypass -File .\install-windows.ps1` | the PowerShell profile (5.1 and 7 if both are installed) |

The installer:

1. asks for the profiles directory (default `~/.claude-profiles`; or pass
   `--dir <path>` / `-Dir <path>`),
2. asks for the command name (default `ccp`; or pass `--name <command>` /
   `-Name <command>`),
3. copies the `ccp` function to `<profiles>/.ccp/` and adds a small marked block
   to the shell rc file that loads it,
4. asks for a first profile. If `~/.claude` / `~/.claude.json` already exist it
   offers to **move** them into that profile,
5. asks whether that profile becomes the default, and how (see below).

Existing profiles are never touched: the installer only writes `<profiles>/.ccp/`
and the rc block. A directory that already holds profiles is used as it is, and
naming an existing profile at the prompt reuses it instead of creating it. What
is inside a profile directory belongs to Claude Code, not to `ccp`.

Other options: `--shell bash|zsh` and `--yes` (no questions, no profile
created); on Windows `-Yes`. Re-running the installer is safe; it replaces its
own block.

## Uninstall

| OS      | Command                                                            |
| ------- | ------------------------------------------------------------------ |
| Linux   | `./uninstall-linux.sh`                                             |
| macOS   | `./uninstall-macos.sh`                                             |
| Windows | `powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1` |

This removes the block from the shell rc files (or PowerShell profiles) and
deletes `<profiles>/.ccp/`, which also drops a persisted `env` default. It finds
the profiles directory from the rc block; pass `--dir <path>` / `-Dir <path>` to
name it yourself.

Profiles are **never** removed, and neither are `<profiles>/default` or the
`~/.claude` and `~/.claude.json` symlinks, so plain `claude` keeps working with
a `global` default.

## Usage

```text
ccp <profile> [claude args...]   run claude with a profile (unique prefixes work: ccp kaz)
ccp                              run claude with the default profile ("link" method);
                                without one, pick a profile from a list
ccp --resume                     same, with claude arguments
ccp add <profile> [--migrate]    create a profile (warns if it already exists)
ccp default <profile>            set the default profile; asks which method
ccp default <profile> --method env|global|link [--persist|--no-persist]
ccp default                      show the current defaults
ccp default --unset [--method env|global|link]
ccp list                         list profiles, tagged [link] [global] [env]
ccp help
```

Profile names use letters, digits, `.`, `_`, `-`; `default`, `add`, `list`,
`ls` and `help` are reserved.

### Default profile methods

| Method   | What it does                                                                                  | Scope                                                                              |
| -------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `env`    | exports `CLAUDE_CONFIG_DIR=<profiles>/<profile>`                                              | plain `claude` in the current shell session; with `--persist` also in new sessions |
| `global` | links `~/.claude` and `~/.claude.json` to `<profiles>/default` (and `default` to the profile) | every `claude`, in every shell, unless `CLAUDE_CONFIG_DIR` is set                  |
| `link`   | links `<profiles>/default` to the profile                                                     | `ccp` without a profile                                                            |

Notes:

- `env --persist` stores the profile name in `<profiles>/.ccp/env-default`; the
  rc block exports it in new shells unless `CLAUDE_CONFIG_DIR` is already set.
- `global` refuses to replace a real `~/.claude` directory; migrate it first
  with `ccp add <profile> --migrate`.
- Windows: directories are linked with junctions (no privilege needed), but the
  `~\.claude.json` file symlink needs Developer Mode or an elevated PowerShell.
- macOS: Claude Code keeps credentials in the Keychain, so a migrated profile
  may ask you to `/login` again.

### Command name

The command is `ccp` by default and can be anything else at install time. The
examples in this file assume `ccp`.

- `claude` is refused: the command has to call the real `claude`.
- `cc` is allowed after a warning: it is the standard name of the system C
  compiler, which the command would shadow in your interactive shell.
- Any other name that already exists on the system also triggers a warning and a
  confirmation.

To change the name later, run the installer again with `--name <command>`.

## Layout

```text
install-linux.sh    install-macos.sh    install-windows.ps1
uninstall-linux.sh  uninstall-macos.sh  uninstall-windows.ps1
lib/ccp.sh              the ccp function for bash and zsh
lib/ccp.ps1             the ccp function for PowerShell
lib/install-common.sh   shared by the Linux and macOS install/uninstall scripts
tests/test.sh           tests/test.sh [bash] [zsh]
```
