#!/usr/bin/env bash
#
# install.sh — install agent-browser-pool (PRD §2.1, §2.17).
#
# Three benign things — NO PATH interception, so installing CANNOT disrupt running
# agents or other agent-browser users (lane selection is by caller identity, never
# a PATH rewrite):
#   1. symlinks bin/agent-browser-pool -> ~/.local/bin/agent-browser-pool (sole entry point)
#   2. pre-creates the pool state dir (lanes/ + acquire.lock)
#   3. runs `doctor` to verify the real agent-browser, Chrome, btrfs, and the master profile
#
# Mode A (PRD §2.15): this script's success output IS the install documentation.
set -euo pipefail

# --- resolve REPO dir (symlink-safe; same pattern as the prior installer) ---
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- argument parsing ---
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            # Backward-compat / scripted use. There is no confirmation to skip (this installer
            # is benign), so this is intentionally a no-op.
            ;;
        --help|-h)
            cat <<'EOF'
install.sh — install agent-browser-pool.

Creates one symlink (~/.local/bin/agent-browser-pool -> this repo's
bin/agent-browser-pool), pre-creates the pool state dir, and runs `doctor`.
There is NO PATH interception and NO disruptive takeover — installing cannot
disrupt running agents.

Usage: ./install.sh [--force|-f]

  (no flag)   Install (no confirmation needed — benign).
  --force|-f  Accepted for backward compatibility / scripted use (no-op).
  --help|-h   Show this help.

Uninstall: rm -f ~/.local/bin/agent-browser-pool
EOF
            exit 0
            ;;
        *)
            printf 'install.sh: unknown option: %s\n' "$arg" >&2
            printf 'Usage: ./install.sh [--force|-f]\n' >&2
            exit 1
            ;;
    esac
done

# --- pre-flight: the two repo files we symlink + source must exist & be usable ---
[[ -f "$REPO_DIR/bin/agent-browser-pool" && -x "$REPO_DIR/bin/agent-browser-pool" ]] \
    || { printf 'install.sh: missing or not executable: %s/bin/agent-browser-pool\n' "$REPO_DIR" >&2; exit 1; }
[[ -f "$REPO_DIR/lib/pool.sh" && -r "$REPO_DIR/lib/pool.sh" ]] \
    || { printf 'install.sh: missing or not readable: %s/lib/pool.sh\n' "$REPO_DIR" >&2; exit 1; }

# --- source the shared lib + freeze config globals (validates $HOME, etc.) ---
# shellcheck source=lib/pool.sh
source "$REPO_DIR/lib/pool.sh"
# Resolve canonical POOL_STATE_DIR / POOL_LANES_DIR / POOL_LOCK_FILE + validate config.
# (Normal host -> rc 0. Can pool_die on genuine misconfig — a config error SHOULD abort.)
pool_config_init

# --- 1. create the sole entry-point symlink (idempotent; $HOME is absolute) ---
mkdir -p -- "$HOME/.local/bin"
# -sfnv: symbolic / force / no-deref / verbose. Source is absolute (PRD §2.2: never bare ~).
ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"

# --- 2. pre-create the pool state dir (lanes/ + acquire.lock) — idempotent ---
pool_state_init

# --- 3. run doctor to verify runtime dependencies (SUBPROCESS: insulates its rc / pool_die) ---
printf 'Running dependency check (doctor)...\n'
doctor_ok=1
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    doctor_ok=0
fi

# --- success message (Mode A: this IS the install documentation) — to stdout ---
printf '\n'
printf '============================================================\n'
printf '  Installed agent-browser-pool.\n'
printf '============================================================\n'
printf '\n'
printf '  entry point:  %s/.local/bin/agent-browser-pool\n' "$HOME"
printf '                -> %s/bin/agent-browser-pool\n' "$REPO_DIR"
printf '  state dir:    %s/{lanes,acquire.lock}\n' "$POOL_STATE_DIR"
if (( doctor_ok )); then
    printf '  doctor:       healthy.\n'
else
    printf '  doctor:       found problems (see the report above). The symlink + state\n'
    printf '                dir were created; fix the reported issues, then re-run:\n'
    printf '                  agent-browser-pool doctor\n'
fi
printf '\n'
printf 'USAGE: agent-browser-pool is the sole command for pool verbs AND driving:\n'
printf '  agent-browser-pool status            # show active lanes\n'
printf '  agent-browser-pool doctor            # re-check dependencies\n'
printf '  agent-browser-pool open <url>        # drive your lane (acquired/reused by identity)\n'
printf '  agent-browser-pool release [<N>|all] # tear down one lane (or all)\n'
printf '  agent-browser-pool help              # full command + env reference\n'
printf '\n'
printf 'UNINSTALL: rm -f %s/.local/bin/agent-browser-pool\n' "$HOME"
printf '\n'
