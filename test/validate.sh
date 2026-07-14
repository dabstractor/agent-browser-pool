#!/usr/bin/env bash
#
# test/validate.sh — test framework for agent-browser-pool (PRD §2.18, §3).
#
# A hand-rolled, dependency-free bash test harness (NO bats/shunit2). Sources
# lib/pool.sh for the LANDED primitives (lease I/O, lanes_list, owner liveness,
# config/state init) and provides:
#   - assertion helpers:  assert_eq, assert_lane_exists, assert_lane_gone,
#                         assert_no_chrome, assert_no_dir  (+ _fail)
#   - owner simulation:   spawn_sim_owner  (a REAL process whose /proc/comm=="pi")
#   - isolation:          hermetic setup/teardown (mktemp temp root + trap)
#   - runner:             run_test NAME FN  +  abpool_run_suite [PREFIX]
#
# DUAL MODE (source vs execute — the BASH_SOURCE gate, Bash manual §Shell Variables):
#   bash test/validate.sh      → run the built-in self-test (selftest_*) and exit
#                                non-zero on any failure.
#   source test/validate.sh    → define helpers + runner; the caller defines test_*
#                                functions then calls `abpool_run_suite test_`.
#
# Subsequent test subtasks (M9.T2/T3/T4) source this file and add test_* bodies.
set -euo pipefail

# --- repo + bin resolution (mirror bin/* symlink-safe bootstrap) ----------------
VALIDATE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ABPOOL_REPO="$(cd "$VALIDATE_DIR/.." && pwd)"
ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"
ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"
# Source the shared lib (also activates set -euo pipefail — pool.sh line 18).
# shellcheck source=../lib/pool.sh
source "$ABPOOL_REPO/lib/pool.sh"

# --- counters + state (module-level; NOT local to functions) --------------------
ABPOOL_PASS=0
ABPOOL_FAIL=0
declare -a ABPOOL_FAILED=()
declare -a ABPOOL_TEST_ROOTS=() # EVERY per-test temp root (setup appends; trap removes ALL)
ABPOOL_TEST_ROOT=""           # the per-test temp root (set by setup)
ABPOOL_CUR_OWNER=""           # the simulated owner PID for the CURRENT test (teardown kills it)
declare -a ABPOOL_SIM_BINS=() # temp dirs holding "pi" binaries (removed by the trap)

# =============================================================================
# _fail MSG    — record a failure line to stderr + return 1. NEVER exits the
# process. Asserts call _fail then `return 1`; run_test runs the body in a
# subshell behind `||`, so a helper's `return 1` ends the (subshell) test only.
# =============================================================================
_fail() {
    printf '    FAIL: %s\n' "$*" >&2
    return 1
}

# =============================================================================
# Assertion helpers. Each returns 0 on success, 1 (+ _fail) on failure. They are
# NON-FATAL to the harness: a test body runs in a subshell, so a helper's
# `return 1` (under the body's `set -e`) ends THAT test, not the suite.
# =============================================================================

# assert_eq EXPECTED ACTUAL [LABEL]
assert_eq() {
    local expected="$1" actual="$2" label="${3:-}"
    [[ "$expected" == "$actual" ]] \
        || { _fail "assert_eq${label:+ ($label)}: expected [$expected] got [$actual]"; return 1; }
}

# assert_lane_exists N   — lane N has a present lease file ($POOL_LANES_DIR/N.json).
# (Lane "held" ⟺ lease file present — this is what pool_lanes_list enumerates. For
#  a STRICTER valid-JSON check use the lib's `pool_lease_exists N` — guard it with
#  `if`, it returns rc 1 on missing/corrupt and aborts bare under set -e.)
assert_lane_exists() {
    local lane="$1"
    [[ -f "$POOL_LANES_DIR/$lane.json" ]] \
        || { _fail "assert_lane_exists: lane $lane lease file missing ($POOL_LANES_DIR/$lane.json)"; return 1; }
}

# assert_lane_gone N     — lane N has NO lease file AND NO ephemeral dir.
assert_lane_gone() {
    local lane="$1"
    [[ ! -e "$POOL_LANES_DIR/$lane.json" ]] \
        || { _fail "assert_lane_gone: lane $lane lease file still present"; return 1; }
    [[ ! -e "$POOL_EPHEMERAL_ROOT/$lane"  ]] \
        || { _fail "assert_lane_gone: lane $lane ephemeral dir still present"; return 1; }
}

# assert_no_dir PATH     — PATH does not exist (file, dir, or symlink).
assert_no_dir() {
    local path="$1"
    [[ ! -e "$path" ]] \
        || { _fail "assert_no_dir: path still exists: $path"; return 1; }
}

# assert_no_chrome [ROOT] — no Chrome process running under the pool's ephemeral root.
# Scoped via the --user-data-dir flag pool_chrome_launch writes, so the operator's
# daily-driver Chrome never false-positives. pgrep returns rc 1 on no-match → it is
# the `if` CONDITION (errexit-exempt), so "no chrome" = success. (kill -0 is a TRAP:
# it conflates ESRCH-dead and EPERM-foreign-alive — use pgrep / /proc, never kill -0.)
assert_no_chrome() {
    local root="${1:-$POOL_EPHEMERAL_ROOT}"
    if pgrep -f -- "user-data-dir=$root" >/dev/null 2>&1; then
        _fail "assert_no_chrome: Chrome still running under --user-data-dir=$root"
        return 1
    fi
}

# =============================================================================
# spawn_sim_owner [SECONDS] — echo the PID of a LIVE process whose /proc/comm=="pi".
#
# WHY THIS EXISTS (the pivotal gotcha): pool_owner_alive (lib/pool.sh:616) reads the
# REAL /proc/<pid>/comm and requires "pi". The env override (AGENT_BROWSER_POOL_OWNER_PID)
# sets the lease's owner IDENTITY; it does NOT fake the kernel-visible process. So for a
# lease to be "mine"/"live", its owner PID must point at a real running "pi". The kernel
# sets /proc/<pid>/comm to the BASENAME of the executed ELF (proc(5)), NOT argv[0] — so
# copying /usr/bin/sleep to a file named "pi" and exec'ing it yields comm=="pi"
# (HOST-VERIFIED 2026-07-13). `exec -a pi sleep` does NOT work (argv[0] only).
#
# Tracks the pid (ABPOOL_CUR_OWNER, set by setup) + its temp bin dir (trap removes it).
# SETTLES on a poll loop: after fork the child briefly shows the PARENT's comm until
# execve completes — reading comm/starttime in that window returns the wrong value
# (cost a verification run: it returned "bash"). The poll guarantees a ready-to-use pid.
# Host tooling verified: /usr/bin/sleep present.
# =============================================================================
spawn_sim_owner() {
    local dur="${1:-600}" bin_dir bin pid comm tries
    bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"
    bin="$bin_dir/pi"
    cp -- /usr/bin/sleep "$bin"
    chmod +x -- "$bin"
    # Detach the child's fds (</dev/null >/dev/null 2>&1) so it does NOT inherit the
    # command-substitution pipe. spawn_sim_owner is consumed via `pid="$(spawn_sim_owner)"`
    # (setup + test bodies); without this the child is killed on subshell exit (or holds the
    # pipe → the caller blocks): the returned pid is dead → _pool_get_starttime fails → setup()
    # aborts under set -e. HOST-VERIFIED: redirected → pid ALIVE, comm=="pi", starttime OK.
    "$bin" "$dur" </dev/null >/dev/null 2>&1 &
    pid="$!"
    # Settle: poll until execve completes and comm flips to "pi" (fork→exec race window).
    tries=0
    while (( tries++ < 50 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [[ "$comm" == "pi" ]] && break
        sleep 0.02
    done
    ABPOOL_SIM_BINS+=("$bin_dir")
    printf '%s\n' "$pid"
}

# =============================================================================
# Hermetic setup / teardown
# =============================================================================

# _abpool_global_cleanup — EXIT/INT/TERM trap. Kills the current test's sim-owner +
# removes all tracked "pi" bin dirs + the suite temp root. Best-effort (`|| true`);
# must never abort the exit path.
_abpool_global_cleanup() {
    local d
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && kill "$ABPOOL_CUR_OWNER" 2>/dev/null || true
    for d in "${ABPOOL_SIM_BINS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf -- "$d" 2>/dev/null || true
    done
    # Remove EVERY per-test temp root setup created. setup() runs in the MAIN shell (run_test
    # calls it directly — only the body runs in a subshell), so ABPOOL_TEST_ROOTS accumulates
    # across all tests in the suite; the EXIT trap (main shell) sees the full list. The PRP's
    # original single-var design removed ONLY the last test's root → N-1 orphans per run
    # (AGENTS.md §3: never leak temp roots). This array reaps them all.
    local r
    for r in "${ABPOOL_TEST_ROOTS[@]:-}"; do
        [[ -n "$r" ]] && rm -rf -- "$r" 2>/dev/null || true
    done
    # Backstop glob for the mktemp prefix (belt-and-suspenders; the loop above is authoritative).
    rm -rf -- /tmp/abpool-test.* 2>/dev/null || true
    # Backstop for leaked sim-owner bin dirs: spawn_sim_owner's ABPOOL_SIM_BINS+= runs inside
    # the `$(…)` subshell and is lost in the parent, so the loop above is a no-op for them.
    # Glob the specific mktemp prefix (abpool-pi.XXXXXX) to reap any it left behind.
    rm -rf -- /tmp/abpool-pi.* 2>/dev/null || true
}
trap _abpool_global_cleanup EXIT INT TERM

# setup — hermetic per-test environment + a LIVE simulated "pi" owner.
#
# Isolation (MANDATORY): pool_config_init anchors EVERY default on realpath($HOME)
# (lib/pool.sh:126-145); overriding HOME + the three pool roots keeps the harness off
# the operator's real state/Chrome. Without this the harness clobbers real leases and
# could pkill the operator's daily-driver Chrome.
# Contract (b): export AGENT_CHROME_HEADLESS=1 + unique OWNER_PID + OWNER_STARTTIME per
# test. The owner is a real "pi"-comm process (spawn_sim_owner) so liveness checks pass;
# _OWNER_STARTTIME is its REAL starttime (via the lib's _pool_get_starttime).
setup() {
    local pid st
    ABPOOL_TEST_ROOT="$(mktemp -d -t abpool-test.XXXXXX)"
    ABPOOL_TEST_ROOTS+=("$ABPOOL_TEST_ROOT")   # track EVERY root for the EXIT trap (no orphans)
    ABPOOL_CUR_OWNER=""
    export HOME="$ABPOOL_TEST_ROOT/home";            mkdir -p -- "$HOME"
    export AGENT_BROWSER_POOL_STATE="$ABPOOL_TEST_ROOT/state"
    export AGENT_CHROME_EPHEMERAL_ROOT="$ABPOOL_TEST_ROOT/active"
    export AGENT_CHROME_MASTER="$ABPOOL_TEST_ROOT/master"; mkdir -p -- "$AGENT_CHROME_MASTER"
    export AGENT_CHROME_HEADLESS=1
    # Re-resolve all POOL_* globals against the temp HOME (MUTABLE globals → re-runnable).
    pool_config_init
    pool_state_init
    # Simulate a distinct LIVE "pi" agent for this test (unique PID per test).
    pid="$(spawn_sim_owner)"
    st="$(_pool_get_starttime "$pid")"
    ABPOOL_CUR_OWNER="$pid"
    export AGENT_BROWSER_POOL_OWNER_PID="$pid"
    export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
}

# teardown — SAFETY NET. The per-test CLEANUP ASSERTIONS (release + assert_no_chrome +
# assert_no_dir) live in EACH test body (PRD §2.18: "every test must release/reap and
# assert cleanup"). teardown is the backstop so a CRASHED body cannot contaminate the next
# test: best-effort `release all` AS A SUBPROCESS (a pool_die inside the admin tool would
# otherwise exit the harness shell) + kill this test's sim-owner.
teardown() {
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && kill "$ABPOOL_CUR_OWNER" 2>/dev/null || true
}

# =============================================================================
# Runner
# =============================================================================

# run_test NAME FN — run setup, the body in a SUBSHELL, then teardown; tally pass/fail.
#
# The body runs in `( set -e; "$fn" )` so the FIRST failing assert (return 1) ends the
# test (no need for bodies to thread `|| exit 1` everywhere). `|| rc=$?` makes that
# non-zero exit a controlled branch → the harness SURVIVES any body exit code (assert
# fail OR a set-e abort). PASS/FAIL use the `$(( ))` EXPANSION (always errexit-safe);
# `(( rc == 0 ))` is INSIDE `if` (exempt — a bare `(( 0 ))` would abort).
run_test() {
    local name="$1" fn="$2" rc=0
    printf '== %s\n' "$name"
    setup
    ( set -e; "$fn" ) || rc=$?
    teardown
    if (( rc == 0 )); then
        ABPOOL_PASS=$((ABPOOL_PASS+1))
        printf '   PASS\n'
    else
        ABPOOL_FAIL=$((ABPOOL_FAIL+1))
        ABPOOL_FAILED+=("$name")
        printf '   FAIL\n' >&2
    fi
}

# abpool_run_suite [PREFIX=test_] — enumerate functions matching PREFIX, run each.
# Returns rc 1 iff any test failed (so the caller / script exits non-zero).
abpool_run_suite() {
    local prefix="${1:-test_}" fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    for fn in $(compgen -A function | grep "^${prefix}" | sort); do
        run_test "$fn" "$fn"
    done
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    if (( ABPOOL_FAIL > 0 )); then
        printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2
        return 1
    fi
    return 0
}

# =============================================================================
# Built-in self-test (selftest_*) — exercises the FRAMEWORK, not the pool lifecycle.
# Chrome-free: temp state + lib primitives only (no master/btrfs needed). Runs when
# validate.sh is EXECUTED directly (the BASH_SOURCE gate below), NOT when sourced.
# =============================================================================

selftest_assert_eq_passes() {
    assert_eq "abc" "abc" "equal strings"
    assert_eq "" "" "both empty"
}

selftest_assert_eq_fails_correctly() {
    # A mismatch MUST make assert_eq return 1 (and _fail) WITHOUT killing the harness.
    # Run it in a nested subshell; we EXPECT failure → invert: if it returned 0, that's a bug.
    if ( set -e; assert_eq "abc" "xyz" "intentional mismatch" ); then
        _fail "assert_eq did NOT fail on a mismatch (or the subshell masked it)"; return 1
    fi
}

selftest_assert_no_dir_absent() {
    assert_no_dir "$ABPOOL_TEST_ROOT/does-not-exist"   # absent path → pass
}

selftest_empty_pool_lane_is_gone() {
    # Fresh setup → no leases, no dirs. assert_lane_gone(1) must pass.
    assert_lane_gone 1
}

selftest_lane_exists_after_write() {
    # Minimal valid lease file (assert_lane_exists checks file PRESENCE). Downstream
    # tests use the lib's pool_lease_write for a real lease; the self-test keeps the
    # assertion decoupled from that signature.
    printf '{"lane":3}' >"$POOL_LANES_DIR/3.json"
    assert_lane_exists 3
}

selftest_sim_owner_is_alive_pi() {
    local pid comm
    pid="$AGENT_BROWSER_POOL_OWNER_PID"          # set by setup via spawn_sim_owner
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    assert_eq "pi" "$comm" "simulated owner /proc comm"
    # The lib's liveness check must ACCEPT the simulated live owner. pool_owner_alive
    # (lib/pool.sh:616) requires THREE matches: /proc/<pid> exists, comm=="pi", AND the
    # starttime matches. setup captured the sim owner's REAL starttime into
    # AGENT_BROWSER_POOL_OWNER_STARTTIME (via _pool_get_starttime AFTER the execve settle);
    # that is the exact identity token to pass. (NOTE: POOL_OWNER_STARTTIME is only
    # populated by pool_owner_resolve, which setup does NOT call — so it is unset here →
    # ${POOL_OWNER_STARTTIME:-0} would be 0 → guaranteed starttime mismatch → spurious
    # REJECT. Pass the env var setup actually exported, not the unset global.)
    pool_owner_alive "$pid" "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-0}" "pi" \
        || { _fail "pool_owner_alive rejected the simulated live owner"; return 1; }
}

selftest_wrapper_and_admin_are_executable() {
    # Pre-flight the two binaries downstream tests invoke by ABSOLUTE PATH (PRD §2.17).
    # (Also consumes ABPOOL_WRAPPER/ABPOOL_ADMIN so they aren't shellcheck-SC2034-unused.)
    [[ -x "$ABPOOL_WRAPPER" ]] || { _fail "wrapper not executable: $ABPOOL_WRAPPER"; return 1; }
    [[ -x "$ABPOOL_ADMIN"   ]] || { _fail "admin not executable: $ABPOOL_ADMIN";   return 1; }
}

# --- _pool_config_bool truth-table (P1.M1.T1.S1) -------------------------------
# Pure-function bodies: exercise the normalizer directly (+ one end-to-end through
# pool_config_init). No Chrome, no sim-owner, no persistent lease writes. Picked up
# by the single-setup _run_selftest_suite above (same runner as the other selftest_*).

# _pool_config_bool: truthy inputs (1/true/yes/on, case-insensitive) -> "1".
selftest_config_bool_truthy() {
    local v r
    for v in 1 true TRUE True yes YES Yes on ON On; do
        r="$(_pool_config_bool "$v")"
        assert_eq "1" "$r" "truthy [$v] -> 1" || return 1
    done
}

# _pool_config_bool: falsy inputs (0/false/no/off/empty/random) -> "0".
selftest_config_bool_falsy() {
    local v r
    for v in 0 false no off random; do
        r="$(_pool_config_bool "$v")"
        assert_eq "0" "$r" "falsy [$v] -> 0" || return 1
    done
    # empty/unset (no arg) — the set -u-safe ${1:-} path
    r="$(_pool_config_bool "")"
    assert_eq "0" "$r" "falsy [empty] -> 0" || return 1
    r="$(_pool_config_bool)"
    assert_eq "0" "$r" "falsy [no-arg] -> 0" || return 1
}

# End-to-end: AGENT_BROWSER_POOL_DISABLE=<truthy> flows through pool_config_init to
# POOL_DISABLE=1. This is the cutover safety-valve contract (PRD §2.17) that motivated
# the fix. Runs pool_config_init in an ISOLATED subshell so it cannot clobber the
# selftest suite's own POOL_* globals (set by the single setup() call).
selftest_config_bool_via_pool_config_init() {
    local d
    d="$(AGENT_BROWSER_POOL_DISABLE=true bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=true -> POOL_DISABLE=1" || return 1
    d="$(AGENT_BROWSER_POOL_DISABLE=yes bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=yes -> POOL_DISABLE=1" || return 1
    d="$(AGENT_BROWSER_POOL_DISABLE=0 bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "0" "$d" "AGENT_BROWSER_POOL_DISABLE=0 -> POOL_DISABLE=0" || return 1
}

# --- source-vs-execute gate: run the self-test ONLY when executed directly. -----
# ★★★ SINGLE-SETUP RUNNER (HARD CONSTRAINT — AGENTS.md §4 / Issue #3) ★★★
# setup() spawns a REAL sim-owner process (spawn_sim_owner) every time it is called. The
# framework's run_test/abpool_run_suite call setup() ONCE PER TEST; this self-test has 7
# bodies → 7 setup() calls, and in a shared sandbox the 3rd setup() HANGS (a documented
# P1.M9.T1.S1 accumulation hazard). Per AGENTS.md §4 a suite MUST call a process-spawning
# setup() AT MOST ONCE. So the self-test BYPASSES abpool_run_suite and uses a single-setup
# runner (mirrors test/release_reaper.sh's _abpool_run_release_reaper_suite):
#   - ONE setup() (temp root + config + trap + ONE sim-owner).
#   - Each body runs via `if "$fn"` in the MAIN shell (NOT a subshell). A failed assert's
#     `return 1` is the function's rc → recorded as FAIL → the suite CONTINUES. No subshell
#     ⇒ the EXIT trap does NOT fire mid-suite ⇒ the temp root is NOT removed between bodies.
#   - Inter-body backstop: clear any lease a body wrote (rm the lanes dir contents) + confirm
#     the shared sim-owner is still alive (selftest_sim_owner_is_alive_pi reads it). The
#     bodies are pure-logic (no Chrome, no per-body owners), so no release-all / owner-swap is
#     needed — only the lease-write residue is swept between bodies.
#   - ONE teardown() at the end.
_run_selftest_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call
    for fn in $(compgen -A function | grep '^selftest_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        # Inter-body backstop: clear any lease file a body wrote (selftest_lane_exists_after_write
        # creates 3.json). A stray lease would pollute selftest_empty_pool_lane_is_gone. Pure
        # rm of the lanes dir CONTENTS (not the dir — pool_state_init re-mkdirs it).
        rm -f -- "${POOL_LANES_DIR:?}/"*.json 2>/dev/null || true
    done
    teardown
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    if (( ABPOOL_FAIL > 0 )); then
        printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! _run_selftest_suite; then
        exit 1
    fi
fi
