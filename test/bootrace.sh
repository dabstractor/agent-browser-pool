#!/usr/bin/env bash
# bootrace.sh — BUG-001/002 regression suite for changeset 001 (agent-browser-pool).
#
# Purpose: regressions for the crash-recovery master-copy bug (BUG-001) and, later,
# the concurrent-boot race (BUG-002, added by sibling subtask T2.S1).
#
# Safety contract (AGENTS.md):
#   - SINGLE process-spawning setup for the whole suite (never per-test).
#   - Every potentially-blocking subprocess wrapped in `timeout`.
#   - Zero orphan processes left behind (suite trap sweeps everything, `|| true` per line).
#   - Hermetic: HOME/state/ephemeral/config all redirected under one mktemp tree;
#     fake chrome + fake agent-browser only; no operator state touched.
#
# Invocation: bash test/bootrace.sh   (exit 0 iff all cases pass)

set -euo pipefail

# --- repo resolution (mirror test/validate.sh) ---------------------------------
BOOTRACE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ABPOOL_REPO="$(cd "$BOOTRACE_DIR/.." && pwd)"

# --- counters + helpers ---------------------------------------------------------
BR_PASS=0
BR_FAIL=0
declare -a BR_FAILED=()
declare -a BR_OWNERS=()

_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-}"
    [[ "$expected" == "$actual" ]] \
        || { _fail "assert_eq${label:+ ($label)}: expected [$expected] got [$actual]"; return 1; }
}

# --- sandbox setup (ONE call for the whole suite) -------------------------------
# -p "$HOME": keep the temp tree on the real (btrfs) FS so lanes exercise real cp.
BR_T="$(mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX)"
mkdir -p -- "$BR_T/home" "$BR_T/state" "$BR_T/active" "$BR_T/master/Default" \
         "$BR_T/bin" "$BR_T/profile-home/.local/bin"

# A minimal VALID master (pool_check_master requires content — 'Local State' + Default/):
printf '{"user-experience-enrollment":{"prevalence":0}}\n' >"$BR_T/master/Local State"
printf '{"marker":"trusted-identity"}\n' >"$BR_T/master/Default/Preferences"
# TRUSTED-PROFILE MARKER for R2: must land at the lane top level after recovery.
printf 'master-marker\n' >"$BR_T/master/Default/master-marker.txt"

trap '_br_teardown' EXIT INT TERM

HOME="$BR_T/home"
export HOME
AGENT_BROWSER_POOL_STATE="$BR_T/state"
AGENT_CHROME_EPHEMERAL_ROOT="$BR_T/active"
AGENT_CHROME_MASTER="$BR_T/master"
AGENT_CHROME_BIN="$BR_T/bin/fake-chrome"
AGENT_BROWSER_REAL="$BR_T/bin/fake-agent-browser"
AGENT_CHROME_ALLOW_SLOW_COPY=1
export AGENT_BROWSER_POOL_STATE AGENT_CHROME_EPHEMERAL_ROOT AGENT_CHROME_MASTER \
       AGENT_CHROME_BIN AGENT_BROWSER_REAL AGENT_CHROME_ALLOW_SLOW_COPY

# --- fixtures -------------------------------------------------------------------

_br_make_fake_chrome() {
    cat >"$BR_T/bin/fake-chrome" <<'EOF'
#!/usr/bin/env bash
# fake chrome: parse --remote-debugging-port from argv; serve /json/version; block.
port=""
for a in "$@"; do
    [[ "$a" == --remote-debugging-port=* ]] && port="${a##*=}"
done
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
d="$(mktemp -d -t fake-cdp.XXXXXX)"
mkdir -p -- "$d/json"
printf '{"Browser":"FakeChrome/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/fake"}\n' "$port" \
    >"$d/json/version"
cd -- "$d" || exit 1
trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT INT TERM
exec python3 -m http.server "$port" --bind 127.0.0.1
EOF
    chmod +x -- "$BR_T/bin/fake-chrome"
}

_br_make_fake_ab() {
    cat >"$BR_T/bin/fake-agent-browser" <<'EOF'
#!/usr/bin/env bash
# fake agent-browser: satisfy pool_daemon_connect (`--session X connect P` → rc 0)
# and the final exec (any args → rc 0).
exit 0
EOF
    chmod +x -- "$BR_T/bin/fake-agent-browser"
}

# Spawn a live sim owner (sleep process) + export the owner env; echo the pid.
_br_spawn_owner() {
    local pid st
    sleep 600 &
    pid=$!
    BR_OWNERS+=("$pid")
    # refresh starttime via the lib helper
    st="$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && _pool_get_starttime "$pid" ) 2>/dev/null || true )"
    AGENT_BROWSER_POOL_OWNER_PID="$pid"
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
    export AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME
    BR_LAST_OWNER="$pid"
    BR_LAST_OWNER_COMM="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
}

# --- regression cases -------------------------------------------------------------

# R1 — BUG-001 guard, FS-agnostic: pre-existing junk dir must be replaced by a clean
# top-level copy (never nested, never merged).
r1_bug001_guard_fs_agnostic() {
    mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
    printf 'partial-crash-state\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
    if ! ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && \
           pool_copy_master "$AGENT_CHROME_EPHEMERAL_ROOT/1" ) ; then
        _fail "R1: pool_copy_master failed on pre-existing target"; return 1
    fi
    if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Local State" ]]; then
        _fail "R1: no top-level 'Local State' in the lane dir (nested or empty copy)"; return 1
    fi
    if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" || -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/$(basename -- "$AGENT_CHROME_MASTER")" ]]; then
        _fail "R1: nested <master-basename>/ dir inside the lane dir (BUG-001 reproduced)"; return 1
    fi
    if [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker" ]]; then
        _fail "R1: stale junk survived (guard did not rm the pre-existing dir)"; return 1
    fi
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
}

# R2 — BUG-001 crash recovery end-to-end: provisional port=0 lease + remnant dir →
# next driving command re-boots the lane and the trusted master copy lands at top level.
r2_bug001_recovery_e2e() {
    local owner rc
    _br_spawn_owner
    owner="$BR_LAST_OWNER"
    # 1) Provisional lease: lane 1, port=0 — the crashed-boot state.
    ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && pool_state_init && \
      pool_lease_write 1 "$AGENT_CHROME_EPHEMERAL_ROOT/1" 0 abpool-1 "$owner" "$BR_LAST_OWNER_COMM" \
      "$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && _pool_get_starttime "$owner" ) 2>/dev/null || true )" \
      "$BR_T" 0 0 false )
    # 2) Simulate crash-AFTER-copy: the dir exists (partial/junk state).
    mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
    printf 'crash-remnant\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
    # 3) Next driving command through the real wrapper → stuck-lane recovery re-boot.
    rc=0
    timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        _fail "R2: recovery boot failed rc=$rc (expected 0)"; return 1
    fi
    # 4) Trusted-profile assertion: master's marker file at the LANE TOP level.
    if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Default/master-marker.txt" ]]; then
        _fail "R2: master marker missing — lane did not get a clean trusted copy"; return 1
    fi
    # 5) NO nesting.
    if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" ]]; then
        _fail "R2: nested master dir inside lane 1 (BUG-001 reproduced at e2e level)"; return 1
    fi
    # 6) Clean up THIS test's lane.
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
}

# --- single-setup runner -----------------------------------------------------------

_br_run_suite() {
    local fn
    for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e; do
        printf '== %s\n' "$fn"
        if "$fn"; then BR_PASS=$((BR_PASS+1)); printf '   PASS\n';
        else BR_FAIL=$((BR_FAIL+1)); BR_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
    done
    printf '\n%d passed, %d failed\n' "$BR_PASS" "$BR_FAIL"
    (( BR_FAIL > 0 )) && return 1
    return 0
}

_br_teardown() {
    local pid
    # Guard against spurious fires: subshells/command substitutions inherit the EXIT
    # trap. Do nothing until the runner marks the suite as finishing (AGENTS.md §4).
    [[ "${BR_TEARDOWN_FINAL:-0}" == 1 ]] || return 0
    BR_TEARDOWN_FINAL=0
    for pid in "${BR_OWNERS[@]:-}"; do kill "$pid" 2>/dev/null || true; done 2>/dev/null || true
    pkill -f -- 'fake-cdp\.' 2>/dev/null || true
    pkill -f -- "user-data-dir=$BR_T/active" 2>/dev/null || true
    pkill -f -- 'http.server' 2>/dev/null || true
    [[ -n "${BR_T:-}" ]] && rm -rf -- "$BR_T" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _br_make_fake_chrome
    _br_make_fake_ab
    BR_TEARDOWN_FINAL=1
    _br_run_suite || exit 1
fi