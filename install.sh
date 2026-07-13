#!/usr/bin/env bash
#
# install.sh — install the agent-browser-pool cutover (PRD §2.1, §2.17).
#
# WHAT THIS DOES (a deliberate, all-or-nothing CUTOVER — read the warning):
#   1. symlinks bin/agent-browser      -> ~/scripts/agent-browser
#      (~/scripts PRECEDES ~/.local/bin on PATH -> the wrapper SHADOWS the real CLI)
#   2. symlinks bin/agent-browser-pool -> ~/.local/bin/agent-browser-pool
#   3. pre-creates the pool state dir (lanes/ + acquire.lock) via the lib
#   4. runs `doctor` to verify dependencies
#
# Mode A: this script's warning + success output IS the cutover documentation.
# Safety valve (per-session): export AGENT_BROWSER_POOL_DISABLE=1 to bypass the shadow.
set -euo pipefail

# --- resolve REPO dir (symlink-safe; mirrors bin/agent-browser bootstrap) ---
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- argument parsing ---
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            cat <<'EOF'
install.sh — install the agent-browser-pool cutover.

Once installed, bin/agent-browser is symlinked into ~/scripts/ (ahead of ~/.local/bin
on PATH), so EVERY `agent-browser` call in EVERY shell is intercepted by the wrapper.
This is ALL-OR-NOTHING; running agents on the old workflow will be silently intercepted.
The only per-session opt-out is AGENT_BROWSER_POOL_DISABLE=1.

Usage: ./install.sh [--force|-f]

  (no flag)   Print the cutover warning and require you to type YES to proceed.
  --force|-f  Skip the confirmation (re-install / scripted use).
  --help|-h   Show this help.
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

# --- stderr helper for all warnings / errors ---
warn() { printf '%s\n' "$*" >&2; }

# --- prominent cutover warning (PRD §2.17 — the exact "silently intercepted" + "all-or-nothing" sentences) ---
BAR='============================================================'
warn ""
warn "$BAR"
warn "  agent-browser-pool — CUTOVER INSTALL (read carefully)"
warn "$BAR"
warn ""
warn "  This will symlink bin/agent-browser into ~/scripts/, which is AHEAD of"
warn "  ~/.local/bin on your PATH. Once installed, the wrapper is GLOBAL and"
warn "  process-wide: EVERY 'agent-browser' call in EVERY shell resolves to it."
warn "  There is NO safe partial shadow — the PATH mechanism is all-or-nothing."
warn ""
warn "  RUNNING AGENTS WILL BE SILENTLY INTERCEPTED:"
warn "    Any agent still on the OLD manual workflow (acquire.sh + per-task"
warn "    --session + persistent profiles 1..10) will have its NEXT 'agent-browser'"
warn "    call intercepted: owner resolution finds its pi PID, the wrapper overrides"
warn "    its --session/connect args, and it lands on a fresh ephemeral lane —"
warn "    ABANDONING in-progress work on profile 3 (etc.). This BREAKS running work."
warn ""
warn "  Make sure no critical agents are mid-task before continuing. To test first"
warn "  WITHOUT installing, invoke the wrapper by ABSOLUTE PATH:"
warn "      $REPO_DIR/bin/agent-browser open https://example.com"
warn ""
warn "  Per-session bypass (old workflow / debugging):"
warn "      export AGENT_BROWSER_POOL_DISABLE=1"
warn "$BAR"
warn ""

# --- confirmation gate (unless --force) — set -e-safe (the || list harnesses read's EOF) ---
if [[ "$FORCE" != "1" ]]; then
    if ! read -r -p 'Type YES to continue: ' reply; then
        warn "Aborted (no input)."
        exit 1
    fi
    if [[ "${reply:-}" != "YES" ]]; then
        warn "Aborted."
        exit 1
    fi
fi

# --- pre-flight: the repo files we symlink + source must exist & be executable ---
for f in "$REPO_DIR/bin/agent-browser" "$REPO_DIR/bin/agent-browser-pool" "$REPO_DIR/lib/pool.sh"; do
    [[ -f "$f" ]] || { warn "install.sh: missing repo file: $f"; exit 1; }
done
[[ -x "$REPO_DIR/bin/agent-browser" ]]      || { warn "install.sh: not executable: $REPO_DIR/bin/agent-browser"; exit 1; }
[[ -x "$REPO_DIR/bin/agent-browser-pool" ]] || { warn "install.sh: not executable: $REPO_DIR/bin/agent-browser-pool"; exit 1; }

# --- source the shared lib (canonical path resolution + idempotent state init) ---
# shellcheck source=lib/pool.sh
source "$REPO_DIR/lib/pool.sh"
# Resolve canonical POOL_STATE_DIR / POOL_LANES_DIR / POOL_LOCK_FILE + validate config.
# (Normal host -> rc 0. Can pool_die on genuine misconfig — a config error SHOULD abort.)
pool_config_init

# --- target dirs (defensive, idempotent; $HOME is absolute -> never a bare ~ to a subprocess) ---
mkdir -p -- "$HOME/scripts" "$HOME/.local/bin"

# --- create the symlinks (ABSOLUTE source; -sfnv: symbolic/force/no-deref/verbose) ---
ln -sfnv -- "$REPO_DIR/bin/agent-browser"      "$HOME/scripts/agent-browser"
ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"

# --- pre-create the pool state dir (lanes/ + acquire.lock) — reuses the lib's canonical paths ---
# pool_state_init: mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE. Idempotent.
pool_state_init

# --- run doctor to verify dependencies (SUBPROCESS insulates us from its exit code / pool_die) ---
warn ""
warn "Running dependency check (doctor)..."
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    warn ""
    warn "$BAR"
    warn "  doctor found problems (see the report above). The wrapper + admin symlinks"
    warn "  and the state dir were created successfully, but one or more RUNTIME"
    warn "  dependencies are missing (e.g. chrome, the real binary, btrfs, master)."
    warn "  The pool will not work until these are fixed. Re-check with:"
    warn "      $REPO_DIR/bin/agent-browser-pool doctor"
    warn "$BAR"
else
    warn "doctor: healthy."
fi

# --- success message (Mode A: this IS the cutover documentation) — to stdout ---
printf '\n%s\n' "$BAR"
printf '  Installed agent-browser-pool.\n'
printf '%s\n' "$BAR"
printf '\n'
printf '  wrapper:  %s\n' "$HOME/scripts/agent-browser"
printf '            -> %s\n' "$REPO_DIR/bin/agent-browser"
printf '            (shadows %s/.local/bin/agent-browser)\n' "$HOME"
printf '  admin:    %s/.local/bin/agent-browser-pool\n' "$HOME"
printf '            -> %s\n' "$REPO_DIR/bin/agent-browser-pool"
printf '  state:    %s/{lanes,acquire.lock}\n' "$POOL_STATE_DIR"
printf '\n'
printf 'TEST FIRST (before relying on the shadow): invoke the wrapper by ABSOLUTE PATH to\n'
printf "exercise all logic WITHOUT touching the PATH-resolved \`agent-browser\` running\n"
printf 'agents use:\n'
printf '    %s/bin/agent-browser open https://example.com\n' "$REPO_DIR"
printf '\n'
printf 'BYPASS (per-session): export AGENT_BROWSER_POOL_DISABLE=1 to make THIS shell use\n'
printf 'the real %s/.local/bin/agent-browser directly (old workflow / debugging).\n' "$HOME"
printf '\n'
printf "ADMIN:  agent-browser-pool status | reap | 'release [<N>|all]' | doctor\n"
printf '\n'
printf 'UNINSTALL: rm -f %s/scripts/agent-browser %s/.local/bin/agent-browser-pool\n' "$HOME" "$HOME"
printf '\n'
