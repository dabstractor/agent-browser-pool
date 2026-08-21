#!/usr/bin/env bash
#
# validate.sh — comprehensive validation for agent-browser-pool (repo root).
#
# TEMPORARY validation artifact (deleted after validation completes). It is NOT part of
# the repo's own test/ framework; it orchestrates static checks, the repo's suites, a
# real-Chrome E2E user-journey harness (modeled on test/concurrency.sh + transparency.sh
# hermetic patterns), doc/citation consistency checks, and a hygiene audit.
#
# SAFETY CONTRACT (repo AGENTS.md §1–§4 — every rule obeyed here):
#   - every live subprocess is wrapped in `timeout` (hard bound, never the global tool
#     timeout);
#   - all real-Chrome work runs in an ISOLATED sandbox: HOME, pool state, ephemeral
#     root, and master are redirected under fresh mktemp trees (the framework's own
#     isolated temp-tree pattern); the operator's real state/Chrome is never touched;
#   - single-setup discipline: the process-spawning setup() is called AT MOST ONCE
#     (AGENTS.md §4); each E2E scenario spawns/reaps its own short-lived owners;
#   - everything spawned is reaped: kill + wait for children we own, EXIT trap removes
#     every temp root, and a final audit asserts zero orphans + zero leftover temp dirs.
#
# Usage:
#   ./validate.sh              # full validation (static + unit + bootrace + real-Chrome
#                              # suites + E2E journeys + docs + hygiene)
#   SKIP_E2E=1 ./validate.sh   # skip every real-Chrome phase (phases 4+5-E2E)
#   ./validate.sh --help
#
# Exit 0 iff every phase passes. A phase failure is tallied and reported; validation
# continues so the report is complete.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ABPOOL_ADMIN="$REPO_DIR/bin/agent-browser-pool"

# --- verdict tallies -----------------------------------------------------------
V_PASS=0
V_FAIL=0
V_SKIP=0
declare -a V_FAILED=()

_record_pass() { V_PASS=$((V_PASS+1)); printf '   PASS: %s\n' "$1"; }
_record_fail() { V_FAIL=$((V_FAIL+1)); V_FAILED+=("$1"); printf '   FAIL: %s\n' "$1" >&2; }
_record_skip() { V_SKIP=$((V_SKIP+1)); printf '   SKIP: %s (%s)\n' "$1" "${2:-no reason}"; }

banner() { printf '\n=======================================================================\n%s\n=======================================================================\n' "$*"; }

# ==============================================================================
# Phase 0 — environment preflight (read-only; nothing is booted)
# ==============================================================================
phase0_preflight() {
    banner "PHASE 0: environment preflight"
    local missing=0 dep
    for dep in bash timeout jq curl flock setsid pgrep pkill cp date findmnt ss shellcheck; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            printf '   missing dependency: %s\n' "$dep" >&2
            missing=1
        fi
    done
    if (( missing )); then
        _record_fail "phase0: required tooling missing"
        return 1
    fi
    # Real Chrome + real agent-browser are required for the E2E phases only.
    E2E_OK=1
    if ! command -v google-chrome-stable >/dev/null 2>&1; then
        E2E_OK=0
        printf '   note: google-chrome-stable not on PATH\n'
    fi
    REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
    if [[ ! -x "$REAL_HOME/.local/bin/agent-browser" ]]; then
        E2E_OK=0
        printf '   note: real agent-browser binary missing at %s/.local/bin/agent-browser\n' "$REAL_HOME"
    fi
    if [[ "$(stat -f -c %T "$REAL_HOME" 2>/dev/null || true)" != "btrfs" ]]; then
        E2E_OK=0
        printf '   note: $REAL_HOME is not btrfs (reflink copies impossible)\n'
    fi
    _record_pass "phase0: all required tooling present"
    return 0
}

# ==============================================================================
# Phase 1 — static analysis (bash -n + shellcheck at warning severity)
# ==============================================================================
phase1_static() {
    banner "PHASE 1: static analysis (syntax + shellcheck)"
    local f rc=0
    for f in lib/pool.sh bin/agent-browser-pool install.sh \
             test/validate.sh test/concurrency.sh test/release_reaper.sh \
             test/transparency.sh test/bootrace.sh; do
        if ! timeout 30 bash -n "$REPO_DIR/$f"; then
            _record_fail "phase1: bash -n FAILED: $f"
            rc=1
        fi
    done
    if (( rc == 0 )); then _record_pass "phase1: bash -n clean on all 8 shell files"; fi

    # NOTE: we fail only at severity warning+ (the SC1091/SC2016/SC2031 info notes are
    # expected for this repo's intentional patterns: sourced-relative files, deliberate
    # single-quoted heredoc-ish scripts, subshell pid flows).
    local sc_out=""
    sc_out="$(cd "$REPO_DIR" && timeout 120 shellcheck -s bash --severity=warning \
        lib/pool.sh bin/agent-browser-pool install.sh \
        test/validate.sh test/concurrency.sh test/release_reaper.sh \
        test/transparency.sh test/bootrace.sh 2>&1)" || true
    if [[ -n "$sc_out" ]]; then
        printf '%s\n' "$sc_out" >&2
        _record_fail "phase1: shellcheck reported warning-severity findings"
    else
        _record_pass "phase1: shellcheck clean (severity >= warning)"
    fi
    return 0
}

# ==============================================================================
# Phase 2 — Chrome-free unit suite (repo test/validate.sh; hermetic by design)
# ==============================================================================
phase2_unit() {
    banner "PHASE 2: unit suite (test/validate.sh — Chrome-free, hermetic)"
    local out rc=0
    out="$(cd "$REPO_DIR" && env -u AGENT_BROWSER_POOL_OWNER_PID \
              -u AGENT_BROWSER_POOL_OWNER_STARTTIME -u ABPOOL_OWNER -u ABPOOL_LANE \
              timeout 240 bash test/validate.sh 2>&1)" || rc=$?
    printf '%s\n' "$out" | tail -n 25
    if (( rc == 0 )); then
        _record_pass "phase2: validate.sh selftests green"
    else
        _record_fail "phase2: validate.sh selftests FAILED (rc=$rc)"
    fi
}

# ==============================================================================
# Phase 3 — bootrace regression suite (fake chrome/agent-browser; hermetic)
# ==============================================================================
phase3_bootrace() {
    banner "PHASE 3: boot-race regression suite (test/bootrace.sh — fake binaries)"
    local out rc=0
    out="$(cd "$REPO_DIR" && env -u AGENT_BROWSER_POOL_OWNER_PID \
              -u AGENT_BROWSER_POOL_OWNER_STARTTIME -u ABPOOL_OWNER -u ABPOOL_LANE \
              timeout 300 bash test/bootrace.sh 2>&1)" || rc=$?
    printf '%s\n' "$out" | tail -n 25
    if (( rc == 0 )); then
        _record_pass "phase3: bootrace suite green"
    else
        _record_fail "phase3: bootrace suite FAILED (rc=$rc)"
    fi
}

# ==============================================================================
# Phase 4 — real-Chrome repos suites (isolated by the suites themselves)
# ==============================================================================
phase4_suites() {
    banner "PHASE 4: real-Chrome suites (concurrency / release_reaper / transparency)"
    local suite out rc
    for suite in concurrency release_reaper transparency; do
        rc=0
        printf -- '-- %s --\n' "$suite"
        out="$(cd "$REPO_DIR" && env -u AGENT_BROWSER_POOL_OWNER_PID \
                  -u AGENT_BROWSER_POOL_OWNER_STARTTIME -u ABPOOL_OWNER -u ABPOOL_LANE \
                  AGENT_CHROME_HEADLESS=1 \
                  timeout 420 bash "test/$suite.sh" 2>&1)" || rc=$?
        printf '%s\n' "$out" | tail -n 20
        if (( rc == 0 )); then
            _record_pass "phase4: $suite.sh green"
        else
            _record_fail "phase4: $suite.sh FAILED (rc=$rc)"
        fi
        _hygiene_check "phase4/$suite" || true
    done
}

# ==============================================================================
# Phase 5 — E2E user journeys (real headless Chrome in an isolated sandbox)
# ==============================================================================
# Sources the repo's own test framework for its PROVEN hermetic helpers (spawn_sim_owner,
# asserts, setup/teardown + EXIT trap), then runs the PRD §2.16 invocation checklist as
# real user journeys through bin/agent-browser-pool.
E2E_BTRFS_ROOT=""
V_BG_PIDS=()

# _v_run_foreground TIMEOUT ENV_HOOK_PID ENV_HOOK_ST [extra env K=V...] -- CMD...
#   Run a foreground pool command under `timeout` with the given owner hook. Asserts rc.
_v_fg() {
    local tmo="$1"; shift
    local hook_pid="$1"; shift
    local hook_st="$1"; shift
    local rc=0
    env AGENT_BROWSER_POOL_OWNER_PID="$hook_pid" \
        AGENT_BROWSER_POOL_OWNER_STARTTIME="$hook_st" \
        timeout --signal=KILL "$tmo" "$@" || rc=$?
    return "$rc"
}

# _v_wait_lane_for OWNER_PID — poll leases until a lane owned by OWNER_PID appears
# (≤30s). Echo the lane; rc 1 on timeout.
_v_wait_lane_for() {
    local want="$1" deadline lane n pid
    deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
        for n in $(pool_lanes_list); do
            pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
            if [[ "$pid" == "$want" ]]; then
                printf '%s\n' "$n"; return 0
            fi
        done
        sleep 0.3
    done
    return 1
}

# _v_wait_lane_gone LANE — poll until lane LANE's lease disappears (≤20s).
_v_wait_lane_gone() {
    local lane="$1" deadline=$(( $(date +%s) + 20 ))
    while (( $(date +%s) < deadline )); do
        [[ -f "$POOL_LANES_DIR/$lane.json" ]] || return 0
        sleep 0.3
    done
    return 1
}

# _v_kill_wait PID — kill a child we own AND reap its zombie (AGENTS.md §3).
_v_kill_wait() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# _v_lease_field LANE FIELD — jq read of one lease field (echoes value; rc 1 if missing).
_v_lease_field() {
    local lane="$1" field="$2" v
    v="$(pool_lease_field "$lane" "$field" 2>/dev/null)" || return 1
    printf '%s\n' "$v"
}

_v_e2e_journey() {
    # ---- isolated sandbox setup (concurrency.sh strategy B pattern) -------------
    local real_home="$REAL_HOME"
    local parent="$real_home/.cache/abpool-validate-eph"
    rm -rf -- "$parent"/ephemeral.* 2>/dev/null || true
    mkdir -p -- "$parent"
    E2E_BTRFS_ROOT="$(mktemp -d -p "$parent" ephemeral.XXXXXX)"

    # ONE setup() call for the whole E2E phase (single-setup discipline, AGENTS.md §4).
    setup
    # setup's own sim-owner is unused here — reap it now (kill + wait the zombie).
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _v_kill_wait "$ABPOOL_CUR_OWNER"
    ABPOOL_CUR_OWNER=""

    # Relocate to btrfs + minimal real-bootable master + real agent-browser (mirrors
    # test/concurrency.sh _concurrency_setup_master).
    export AGENT_CHROME_EPHEMERAL_ROOT="$E2E_BTRFS_ROOT/active"
    local m="$E2E_BTRFS_ROOT/master-real"
    mkdir -p -- "$m/Default"
    printf '{"minimal":true,"profile":{"name":"abpool-validate"}}' >"$m/Preferences"
    export AGENT_CHROME_MASTER="$m"
    local real_bin="$real_home/.local/bin/agent-browser" real_ab
    if [[ -x "$real_bin" ]]; then
        real_ab="$(readlink -f -- "$real_bin")"
        export AGENT_BROWSER_REAL="$real_ab"
    fi
    export AGENT_BROWSER_POOL_WAIT=15
    export AGENT_CHROME_ALLOW_SLOW_COPY=1
    pool_config_init
    pool_state_init
    # Make the framework's EXIT trap reap the btrfs root too (it iterates this array).
    ABPOOL_TEST_ROOTS+=("$E2E_BTRFS_ROOT")

    # Master read-only manifest (checked again at the end — the pool must never write
    # the CoW source; PRD §2.7/§2.14).
    local manifest_before
    manifest_before="$(cd "$m" && find . -type f -printf '%P %s\n' | sort | sha1sum | cut -d' ' -f1)"

    local pidA stA pidB stB laneA laneB portA rc=0 bgpid n
    printf -- '-- journey S1: acquire → reuse → status → close → rebind → isolation → teardown-on-death --\n'

    # (1) zero-prep open: lane acquired + booted + connected for owner A.
    pidA="$(spawn_sim_owner)"
    stA="$(_pool_get_starttime "$pidA")"
    export AGENT_BROWSER_POOL_OWNER_PID="$pidA" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stA"
    AGENT_BROWSER_POOL_OWNER_PID="$pidA" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stA" \
        timeout --signal=KILL 60 "$ABPOOL_ADMIN" open about:blank >/dev/null 2>&1 &
    bgpid=$!
    V_BG_PIDS+=("$bgpid")
    if ! laneA="$(_v_wait_lane_for "$pidA")"; then
        _record_fail "S1: no lane acquired for owner A (pid $pidA) within 30s"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "abpool-$laneA" "$(_v_lease_field "$laneA" session)" "S1 lease session" || { _v_e2e_cleanup; return 1; }
    portA="$(_v_lease_field "$laneA" port)"
    if ! [[ "$portA" =~ ^[0-9]+$ && "$portA" -gt 0 ]]; then
        _record_fail "S1: lease port not provisioned (port='$portA')"
        _v_e2e_cleanup; return 1
    fi

    # (2) same agent, later stateless call → SAME lane, Chrome answers CDP.
    if ! _v_fg 45 "$pidA" "$stA" "$ABPOOL_ADMIN" get cdp-url >"$E2E_BTRFS_ROOT/cdp.txt" 2>&1; then
        _record_fail "S1: second driving call (get cdp-url) failed for lane $laneA"
        _v_e2e_cleanup; return 1
    fi
    if ! grep -q "127.0.0.1:$portA" "$E2E_BTRFS_ROOT/cdp.txt" 2>/dev/null; then
        _record_fail "S1: get cdp-url output does not reference the lane's port $portA"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "$laneA" "$(pool_lease_find_mine 2>/dev/null)" "S1 lane reuse (find_mine)" || { _v_e2e_cleanup; return 1; }

    # (3) human workflow: status shows the lane + owner.
    local status_out=""
    status_out="$(timeout 30 "$ABPOOL_ADMIN" status 2>&1)" || true
    if ! grep -qE "^[[:space:]]*${laneA}[[:space:]]+${portA}" <<<"$status_out"; then
        _record_fail "S1: status does not show lane $laneA port $portA (got: $(head -3 <<<"$status_out"))"
        _v_e2e_cleanup; return 1
    fi

    # (4) close = disconnect-only: lease flips connected=false, Chrome + dir SURVIVE.
    if ! _v_fg 45 "$pidA" "$stA" "$ABPOOL_ADMIN" close >/dev/null 2>&1; then
        _record_fail "S1: close call failed"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "false" "$(_v_lease_field "$laneA" connected)" "S1 close flips connected=false" || { _v_e2e_cleanup; return 1; }
    if ! curl -sf --max-time 3 "http://127.0.0.1:$portA/json/version" >/dev/null 2>&1; then
        _record_fail "S1: Chrome died after disconnect-only close (should survive)"
        _v_e2e_cleanup; return 1
    fi
    [[ -d "$POOL_EPHEMERAL_ROOT/$laneA" ]] || { _record_fail "S1: ephemeral dir removed by close (should survive)"; _v_e2e_cleanup; return 1; }

    # (5) next driving call re-binds automatically (same lane, connected again).
    if ! _v_fg 45 "$pidA" "$stA" "$ABPOOL_ADMIN" get cdp-url >/dev/null 2>&1; then
        _record_fail "S1: post-close rebind (get cdp-url) failed"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "true" "$(_v_lease_field "$laneA" connected)" "S1 rebind sets connected=true" || { _v_e2e_cleanup; return 1; }

    # (6) isolation: owner B gets a DIFFERENT lane; A untouched.
    pidB="$(spawn_sim_owner 600 claude)"
    stB="$(_pool_get_starttime "$pidB")"
    AGENT_BROWSER_POOL_OWNER_PID="$pidB" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stB" \
        timeout --signal=KILL 60 "$ABPOOL_ADMIN" open about:blank >/dev/null 2>&1 &
    bgpid=$!
    V_BG_PIDS+=("$bgpid")
    if ! laneB="$(_v_wait_lane_for "$pidB")"; then
        _record_fail "S1: owner B got no lane"
        _v_e2e_cleanup; return 1
    fi
    if [[ "$laneA" == "$laneB" ]]; then
        _record_fail "S1: owners A and B share lane $laneA (isolation violated)"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "$pidA" "$(_v_lease_field "$laneA" owner.pid)" "S1 A still owns its lane" || { _v_e2e_cleanup; return 1; }

    # (7) B's `close --all` is scoped: B disconnects, A stays connected.
    if ! _v_fg 45 "$pidB" "$stB" "$ABPOOL_ADMIN" close --all >/dev/null 2>&1; then
        _record_fail "S1: B close --all failed"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "false" "$(_v_lease_field "$laneB" connected)" "S1 B disconnected by its close" || { _v_e2e_cleanup; return 1; }
    assert_eq "true" "$(_v_lease_field "$laneA" connected)" "S1 A unharmed by B's close --all" || { _v_e2e_cleanup; return 1; }

    # (8) teardown-on-death: A's owner dies → next acquire reaps A's lane completely.
    _v_kill_wait "$pidA"
    if ! _v_fg 60 "$pidB" "$stB" "$ABPOOL_ADMIN" get cdp-url >/dev/null 2>&1; then
        _record_fail "S1: B's driving call after A's death failed"
        _v_e2e_cleanup; return 1
    fi
    if ! _v_wait_lane_gone "$laneA"; then
        _record_fail "S1: dead owner A's lease not reaped"
        _v_e2e_cleanup; return 1
    fi
    assert_lane_gone "$laneA" || { _record_fail "S1: dead owner A's lane dir/lease survived"; _v_e2e_cleanup; return 1; }
    _v_kill_wait "$pidB"
    _record_pass "S1: full agent journey (acquire→reuse→status→close→rebind→isolation→teardown)"

    # ---- journey S2: caller-scoped lanes (ABPOOL_OWNER=caller, PRD §2.12) -------
    printf -- '-- journey S2: caller-scoped lane (ABPOOL_OWNER=caller) --\n'
    timeout --signal=KILL 60 env -u AGENT_BROWSER_POOL_OWNER_PID \
        -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        ABPOOL_OWNER=caller "$ABPOOL_ADMIN" open about:blank >/dev/null 2>&1 &
    bgpid=$!
    V_BG_PIDS+=("$bgpid")
    local clane="" found=0
    local deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
        for n in $(pool_lanes_list); do
            if [[ "$(_v_lease_field "$n" owner.comm 2>/dev/null)" == "timeout" ]] \
               && [[ "$(_v_lease_field "$n" owner.pid 2>/dev/null)" == "$bgpid" ]]; then
                clane="$n"; found=1; break
            fi
        done
        (( found )) && break
        sleep 0.3
    done
    if (( ! found )); then
        _record_fail "S2: no caller-mode lane acquired (owner.comm=timeout, pid=$bgpid)"
        _v_e2e_cleanup; return 1
    fi
    # Worker exits → owner dead → `reap` must tear the lane down.
    _v_kill_wait "$bgpid"
    timeout 45 "$ABPOOL_ADMIN" reap >/dev/null 2>&1 || true
    if ! _v_wait_lane_gone "$clane"; then
        _record_fail "S2: caller-mode lane not reaped after worker exit"
        _v_e2e_cleanup; return 1
    fi
    _record_pass "S2: caller-mode lane keyed on the invoking subprocess + reaped on its exit"

    # ---- journey S3: lane pinning (ABPOOL_LANE, PRD §2.12 mode 2) ---------------
    printf -- '-- journey S3: lane pinning (ABPOOL_LANE=7) --\n'
    local pidC stC
    pidC="$(spawn_sim_owner)"
    stC="$(_pool_get_starttime "$pidC")"
    # free lane 7 → claimed + booted for C.
    if ! env AGENT_BROWSER_POOL_OWNER_PID="$pidC" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stC" \
            ABPOOL_LANE=7 timeout --signal=KILL 60 "$ABPOOL_ADMIN" get cdp-url >/dev/null 2>&1; then
        _record_fail "S3: pinned acquire (free lane 7) failed"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "$pidC" "$(_v_lease_field 7 owner.pid)" "S3 lane 7 owner is C" || { _v_e2e_cleanup; return 1; }
    # live-mine pin → idempotent reuse.
    if ! env AGENT_BROWSER_POOL_OWNER_PID="$pidC" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stC" \
            ABPOOL_LANE=7 timeout --signal=KILL 45 "$ABPOOL_ADMIN" get cdp-url >/dev/null 2>&1; then
        _record_fail "S3: live-mine re-pin failed (should be idempotent reuse)"
        _v_e2e_cleanup; return 1
    fi
    # live-foreign pin → hard error, never a takeover; lease untouched.
    local pidD stD pin_out=""
    pidD="$(spawn_sim_owner 600 codex)"
    stD="$(_pool_get_starttime "$pidD")"
    rc=0
    pin_out="$(env AGENT_BROWSER_POOL_OWNER_PID="$pidD" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stD" \
        ABPOOL_LANE=7 timeout 45 "$ABPOOL_ADMIN" get cdp-url 2>&1)" || rc=$?
    if (( rc == 0 )); then
        _record_fail "S3: live-foreign pin SUCCEEDED (must hard-error; isolation break)"
        _v_e2e_cleanup; return 1
    fi
    if ! grep -q "never a takeover" <<<"$pin_out"; then
        _record_fail "S3: live-foreign pin error lacks the takeover diagnostic (got: $pin_out)"
        _v_e2e_cleanup; return 1
    fi
    assert_eq "$pidC" "$(_v_lease_field 7 owner.pid)" "S3 lane 7 still owned by C after foreign pin" || { _v_e2e_cleanup; return 1; }
    # malformed pin → startup hard error.
    rc=0
    pin_out="$(env ABPOOL_LANE=abc timeout 30 "$ABPOOL_ADMIN" get cdp-url 2>&1)" || rc=$?
    if (( rc == 0 )) || ! grep -q "must be a positive integer" <<<"$pin_out"; then
        _record_fail "S3: malformed ABPOOL_LANE did not fail fast with the documented error (rc=$rc, got: $pin_out)"
        _v_e2e_cleanup; return 1
    fi
    _v_kill_wait "$pidC"
    _v_kill_wait "$pidD"
    _record_pass "S3: pin matrix E2E (free→claim, mine→reuse, foreign→hard error, malformed→startup die)"

    # ---- journey S4: fail-fast outside a supported harness ----------------------
    printf -- '-- journey S4: driving outside a supported harness fails fast --\n'
    rc=0
    pin_out="$(setsid --fork env -u AGENT_BROWSER_POOL_OWNER_PID \
        -u AGENT_BROWSER_POOL_OWNER_STARTTIME -u ABPOOL_OWNER -u ABPOOL_LANE \
        timeout 30 "$ABPOOL_ADMIN" get cdp-url 2>&1)" || rc=$?
    if (( rc == 0 )) || ! grep -q "supported agent harness" <<<"$pin_out"; then
        _record_fail "S4: detached (no-harness) driving call did not fail fast with the harness message (rc=$rc)"
        _v_e2e_cleanup; return 1
    fi
    _record_pass "S4: no-harness driving fails fast with actionable message"

    # ---- journey S5: operator workflows (reap orphan dirs; release all) ---------
    printf -- '-- journey S5: operator workflows (orphan-dir reap, release all) --\n'
    mkdir -p -- "$POOL_EPHEMERAL_ROOT/99/junk"
    timeout 45 "$ABPOOL_ADMIN" reap >/dev/null 2>&1 || true
    if [[ -d "$POOL_EPHEMERAL_ROOT/99" ]]; then
        _record_fail "S5: orphan ephemeral dir survived operator reap"
        _v_e2e_cleanup; return 1
    fi
    timeout 60 "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    if [[ -n "$(pool_lanes_list)" ]]; then
        _record_fail "S5: release all left leases behind: $(pool_lanes_list | tr '\n' ' ')"
        _v_e2e_cleanup; return 1
    fi
    _record_pass "S5: operator reap/release workflows"

    # ---- master read-only invariant --------------------------------------------
    printf -- '-- invariant: CoW source untouched --\n'
    local manifest_after
    manifest_after="$(cd "$m" && find . -type f -printf '%P %s\n' | sort | sha1sum | cut -d' ' -f1)"
    if [[ "$manifest_before" != "$manifest_after" ]]; then
        _record_fail "invariant: master (CoW source) manifest changed during E2E ($manifest_before → $manifest_after)"
    else
        _record_pass "invariant: master (CoW source) untouched"
    fi

    _v_e2e_cleanup
    return 0
}

_v_e2e_cleanup() {
    local p n
    # Kill + reap every bg timeout job we own (AGENTS.md §3: never leak a child).
    for p in "${V_BG_PIDS[@]:-}"; do
        [[ -n "$p" ]] && _v_kill_wait "$p"
    done
    V_BG_PIDS=()
    # Kill any sim-owner still alive (bin dirs are reaped by the framework trap + backstop).
    for p in $(pgrep -f '/abpool-pi\.[A-Za-z0-9]*/' 2>/dev/null || true); do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    # Scoped backstop: any Chrome still on OUR ephemeral root (release all should have
    # caught them; this is belt-and-suspenders, scoped ONLY to the test root).
    if pgrep -f -- "user-data-dir=$E2E_BTRFS_ROOT" >/dev/null 2>&1; then
        pkill    -f -- "user-data-dir=$E2E_BTRFS_ROOT" 2>/dev/null || true
        sleep 0.2
        pkill -9 -f -- "user-data-dir=$E2E_BTRFS_ROOT" 2>/dev/null || true
    fi
    timeout 60 "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    timeout 45 "$ABPOOL_ADMIN" reap       >/dev/null 2>&1 || true
    teardown
}

phase5_e2e() {
    banner "PHASE 5: E2E user journeys (real headless Chrome, isolated sandbox)"
    if [[ "${SKIP_E2E:-0}" == "1" ]]; then
        _record_skip "phase5: E2E journeys" "SKIP_E2E=1"
        return 0
    fi
    if [[ "${E2E_OK:-0}" != "1" ]]; then
        _record_skip "phase5: E2E journeys" "real chrome/agent-browser/btrfs not all available"
        return 0
    fi
    # Source the repo's own framework (defines helpers + trap; the source-vs-execute
    # gate prevents its selftests from running here).
    # shellcheck source=test/validate.sh
    source "$REPO_DIR/test/validate.sh"
    _v_e2e_journey
}

# ==============================================================================
# Phase 6 — documentation / citation consistency
# ==============================================================================
phase6_docs() {
    banner "PHASE 6: documentation + citation consistency"
    local files=(lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh \
                 test/concurrency.sh test/release_reaper.sh test/transparency.sh README.md)
    local f tok bad=0 n

    # (a) no citation references a PRD section that does not exist (§2.1–§2.20 only).
    for f in "${files[@]}"; do
        for tok in $(grep -ho '§2\.[0-9]*' "$REPO_DIR/$f" 2>/dev/null | sort -u || true); do
            n="${tok#§2.}"
            if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > 20 )); then
                printf '   bad citation %s in %s\n' "$tok" "$f" >&2
                bad=1
            fi
        done
    done
    if (( bad )); then _record_fail "phase6: out-of-range §2.N citations found"
    else _record_pass "phase6: all §2.N citations reference existing PRD sections"; fi

    # (b) every §2.12 citation in code/docs concerns caller-scoped selection (spot-check
    #     the anchor sections exist in the PRD with the expected content).
    if grep -q "2.12 Caller-scoped lane selection" "$REPO_DIR/PRD.md"; then
        _record_pass "phase6: PRD §2.12 is the caller-scoped section (renumber verified)"
    else
        _record_fail "phase6: PRD §2.12 is NOT the caller-scoped section"
    fi

    # (c) user-facing error texts mirror the implementation byte-for-byte (core phrases).
    local -a needles=(
        "ABPOOL_LANE must be a positive integer"
        "never a takeover"
        "already holds live lane"
        "requires a live parent process"
        "pinned lane unavailable"
        "driving commands require a supported agent harness"
    )
    local nd code_hit doc_hit bad2=0
    for nd in "${needles[@]}"; do
        code_hit="$(grep -rlF "$nd" "$REPO_DIR/lib/pool.sh" 2>/dev/null || true)"
        doc_hit="$(grep -rlF "$nd" "$REPO_DIR/.agents/skills/agent-browser-pool/references/configuration.md" \
                                  "$REPO_DIR/README.md" 2>/dev/null || true)"
        if [[ -z "$code_hit" ]]; then
            printf '   implementation missing error text: %s\n' "$nd" >&2
            bad2=1
        elif [[ -z "$doc_hit" ]]; then
            printf '   docs missing error text mirror: %s\n' "$nd" >&2
            bad2=1
        fi
    done
    if (( bad2 )); then _record_fail "phase6: error-text mirrors incomplete"
    else _record_pass "phase6: error texts mirrored between implementation and docs"; fi

    # (d) env-table consistency: ABPOOL_OWNER / ABPOOL_LANE documented in both tables.
    for f in README.md .agents/skills/agent-browser-pool/references/configuration.md; do
        if grep -q '^| `ABPOOL_OWNER`' "$REPO_DIR/$f" && grep -q '^| `ABPOOL_LANE`' "$REPO_DIR/$f"; then
            _record_pass "phase6: $f documents ABPOOL_OWNER + ABPOOL_LANE env rows"
        else
            _record_fail "phase6: $f missing ABPOOL_OWNER/ABPOOL_LANE env rows"
        fi
    done

    # (e) help output mentions the new knobs (runtime check of the user-facing surface).
    local help_out=""
    help_out="$(timeout 30 "$ABPOOL_ADMIN" help 2>&1)" || true
    if grep -q "ABPOOL_OWNER" <<<"$help_out" && grep -q "ABPOOL_LANE" <<<"$help_out"; then
        _record_pass "phase6: `help` documents ABPOOL_OWNER + ABPOOL_LANE"
    else
        _record_fail "phase6: help output lacks ABPOOL_OWNER/ABPOOL_LANE"
    fi
}

# ==============================================================================
# Phase 7 — hygiene audit (zero orphans, zero leftover temp trees)
# ==============================================================================
_hygiene_check() {
    local tag="$1" leaks=0
    if pgrep -f -- 'user-data-dir=.*abpool-(test|validate)' >/dev/null 2>&1; then
        printf '   [%s] leftover test Chrome processes\n' "$tag" >&2
        leaks=1
    fi
    if pgrep -f '/abpool-pi\.[A-Za-z0-9]*/' >/dev/null 2>&1; then
        printf '   [%s] leftover sim-owner processes\n' "$tag" >&2
        leaks=1
    fi
    local leftover=""
    leftover="$(ls -d /tmp/abpool-test.* /tmp/abpool-pi.* \
                     "$REAL_HOME/.cache/abpool-test-ephemeral"/ephemeral.* \
                     "$REAL_HOME/.cache/abpool-validate-eph"/* 2>/dev/null || true)"
    if [[ -n "$leftover" ]]; then
        printf '   [%s] leftover temp trees:\n%s\n' "$tag" "$leftover" >&2
        leaks=1
    fi
    return "$leaks"
}

phase7_hygiene() {
    banner "PHASE 7: hygiene audit (orphans + temp-tree leaks)"
    if _hygiene_check "final"; then
        _record_pass "phase7: zero orphan processes, zero leftover temp trees"
    else
        _record_fail "phase7: leaks detected (see above)"
    fi
}

# ==============================================================================
# main
# ==============================================================================
main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        sed -n '2,30p' "${BASH_SOURCE[0]}"
        exit 0
    fi
    printf 'validate.sh — agent-browser-pool comprehensive validation\n'
    printf 'repo: %s\n' "$REPO_DIR"
    printf 'started: %s\n' "$(date -Is)"

    phase0_preflight || true
    phase1_static
    phase2_unit
    phase3_bootrace
    if [[ "${SKIP_E2E:-0}" == "1" || "${E2E_OK:-0}" != "1" ]]; then
        banner "PHASE 4+5: real-Chrome phases SKIPPED"
        _record_skip "phase4: real-Chrome suites" "${SKIP_E2E:+SKIP_E2E=1}${E2E_OK:+ / chrome stack unavailable}"
    else
        phase4_suites
    fi
    phase5_e2e
    phase6_docs
    phase7_hygiene

    banner "VALIDATION SUMMARY"
    printf 'passed: %d   failed: %d   skipped: %d\n' "$V_PASS" "$V_FAIL" "$V_SKIP"
    if (( V_FAIL > 0 )); then
        printf 'FAILED CHECKS:\n'
        printf '  - %s\n' "${V_FAILED[@]}"
        printf '\nVERDICT: ISSUES FOUND\n'
        exit 1
    fi
    printf '\nVERDICT: ALL CHECKS PASSED\n'
    exit 0
}

main "$@"