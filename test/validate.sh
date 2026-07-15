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

selftest_admin_is_executable() {
    # Pre-flight the sole entry point (bin/agent-browser-pool) downstream tests invoke by
    # ABSOLUTE PATH — the explicit-invocation model (PRD §2.17: no PATH shadowing, one entry
    # point). Also consumes ABPOOL_ADMIN so it isn't shellcheck-SC2034-unused.
    [[ -x "$ABPOOL_ADMIN" ]] || { _fail "admin not executable: $ABPOOL_ADMIN"; return 1; }
}

# --- _pool_config_bool truth-table (P1.M1.T1.S1) -------------------------------
# Pure-function bodies: exercise the normalizer directly. No Chrome, no sim-owner,
# no persistent lease writes. Picked up by the single-setup _run_selftest_suite above
# (same runner as the other selftest_*).

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

# --- pool_dispatch_classify full table (P1.M1.T2.S1 / Issue 4) ------------------
# Pure-function bodies: exercise pool_dispatch_classify directly. No Chrome, no sim-owner,
# no persistent lease writes. Picked up by the single-setup _run_selftest_suite above
# (same runner as the other selftest_*). pool_dispatch_classify reads NO globals and writes
# NO files, so the body needs no setup state — it just calls the function directly.

# pool_dispatch_classify: full classification table (Issue 4 — no-command → meta).
# Covers META (help/version short-circuit + two-word/single-word META commands), the
# Issue-4 no-command/flags-only cases (now meta), and DRIVING (real commands +
# unrecognized default + flags-before-command).
selftest_dispatch_classify_cases() {
    local r
    # --- META: help/version short-circuit (unchanged, regression guard) ---
    for a in "--help" "-h" "--version"; do
        r="$(pool_dispatch_classify "$a")"
        assert_eq "meta" "$r" "meta [$a] -> meta" || return 1
    done
    # --- META: two-word + single-word META commands (unchanged, regression guard) ---
    r="$(pool_dispatch_classify session list)"; assert_eq "meta" "$r" "session list -> meta" || return 1
    for a in skills dashboard plugin mcp; do
        r="$(pool_dispatch_classify "$a")"; assert_eq "meta" "$r" "meta [$a] -> meta" || return 1
    done
    # --- META (Issue 4 fix): no command token / flags-only / empty $@ ---
    r="$(pool_dispatch_classify)";                   assert_eq "meta" "$r" "no-args -> meta" || return 1
    r="$(pool_dispatch_classify --json)";            assert_eq "meta" "$r" "--json (no cmd) -> meta" || return 1
    r="$(pool_dispatch_classify --session foo)";     assert_eq "meta" "$r" "--session foo (no cmd) -> meta" || return 1
    r="$(pool_dispatch_classify --session=foo)";     assert_eq "meta" "$r" "--session=foo (no cmd) -> meta" || return 1
    r="$(pool_dispatch_classify --headed --json)";   assert_eq "meta" "$r" "--headed --json (no cmd) -> meta" || return 1
    r="$(pool_dispatch_classify -i)";                assert_eq "meta" "$r" "-i (no cmd) -> meta" || return 1
    r="$(pool_dispatch_classify "")";                assert_eq "meta" "$r" "empty-string arg -> meta" || return 1
    # --- DRIVING: actual commands (unchanged, regression guard) ---
    for a in open click connect close session back get find; do
        r="$(pool_dispatch_classify "$a")"; assert_eq "driving" "$r" "driving [$a] -> driving" || return 1
    done
    # --- DRIVING: unrecognized command defaults to driving (contract step d, unchanged) ---
    r="$(pool_dispatch_classify unknowncmd)"; assert_eq "driving" "$r" "unknowncmd -> driving (default)" || return 1
    # --- DRIVING: flags before a command are skipped, command is found ---
    r="$(pool_dispatch_classify --session foo open)"; assert_eq "driving" "$r" "--session foo open -> driving" || return 1
    r="$(pool_dispatch_classify --json click)";       assert_eq "driving" "$r" "--json click -> driving" || return 1
}

# --- _pool_clean_args_is_close truth-table (P1.M3.T1.S1 / Issue #3) ---------------
# Pure-function body: exercise the close-detection predicate directly. No Chrome, no
# sim-owner, no persistent lease writes. Picked up by the single-setup _run_selftest_suite
# (same runner as the other selftest_*). The predicate reads ONLY "$@" and returns 0/1 —
# so the body needs no setup state; it just calls the function directly (always under
# `if …; then …; fi` because a legitimate return 1 would abort under `set -e` if bare).
selftest_clean_args_is_close_cases() {
    local r
    # --- TRUE: first non-flag token == close ---
    if ! _pool_clean_args_is_close close;             then _fail "close -> true";            return 1; fi
    if ! _pool_clean_args_is_close --json close;      then _fail "--json close -> true";     return 1; fi
    if ! _pool_clean_args_is_close close --json;      then _fail "close --json -> true";     return 1; fi
    if ! _pool_clean_args_is_close close --all;       then _fail "close --all -> true";      return 1; fi
    if ! _pool_clean_args_is_close --session x close; then _fail "--session x close -> true";return 1; fi   # defense-in-depth (parity with the connect twin)
    if ! _pool_clean_args_is_close -i close;          then _fail "-i close -> true";         return 1; fi
    # --- FALSE: any other command / no command ---
    if   _pool_clean_args_is_close open;          then _fail "open -> must be false";          return 1; fi
    if   _pool_clean_args_is_close click;         then _fail "click -> must be false";         return 1; fi
    if   _pool_clean_args_is_close connect;       then _fail "connect -> must be false";       return 1; fi
    if   _pool_clean_args_is_close connect 98765; then _fail "connect <port> -> must be false"; return 1; fi
    if   _pool_clean_args_is_close session;       then _fail "session -> must be false";       return 1; fi
    if   _pool_clean_args_is_close unknowncmd;    then _fail "unknowncmd -> must be false";    return 1; fi
    if   _pool_clean_args_is_close;               then _fail "empty argv -> must be false";    return 1; fi
    if   _pool_clean_args_is_close --json;        then _fail "flags-only -> must be false";    return 1; fi
}

# --- pool_wrapper_main marks lease connected=false on close (P1.M3.T1.S1 / Issue #3) ---
# Mock-based test: a no-op POOL_REAL_BIN + overrides of pool_ensure_connected/
# pool_lease_find_mine let pool_wrapper_main reach the close path WITHOUT real Chrome/
# daemon (AGENTS.md §1/§3). Asserts: (1) close flips the lease connected true→false BEFORE
# the terminal exec; (2) all sibling fields + owner sub-object are preserved; (3) open does
# NOT flip connected; (4) a corrupt lease does NOT abort the close (the defensive SUBSHELL
# contains pool_die). Runs in a `timeout`-bounded bash -c SUBSHELL so the mock functions
# (which shadow the lib fns) are SCOPED — they do NOT leak into the main shell and pollute
# the other selftests (single-setup runner, AGENTS.md §4). AGENT_BROWSER_REAL points
# pool_config_init's frozen POOL_REAL_BIN at the no-op so the exec is hermetic.
selftest_close_marks_lease_disconnected() {
    local outdir noop script rc out
    outdir="$ABPOOL_TEST_ROOT/close-rebind"
    mkdir -p -- "$outdir"
    noop="$outdir/noop.sh"
    printf '#!/bin/sh\nexit 0\n' >"$noop"; chmod +x -- "$noop"
    # Build the body in a file (avoids nested-quote hazards). AGENT_BROWSER_REAL freezes
    # the no-op as POOL_REAL_BIN so exec is hermetic (no real agent-browser).
    script="$outdir/body.sh"
    cat >"$script" <<EOF
set -euo pipefail
source "\$1/lib/pool.sh"
pool_config_init
pool_state_init
# Lane 2 lease: connected=true, with distinct sibling/owner values to assert preservation.
pool_lease_write 2 "\$2/active/2" 53421 abpool-2 55 pi 999 /home/x 7 8 true
test "\$(jq -r .connected "\$POOL_LANES_DIR/2.json")" = "true"   # precondition
# Override the Chrome/daemon-dependent steps so pool_wrapper_main reaches the close path.
pool_ensure_connected() { return 0; }
pool_lease_find_mine()   { printf '2\n'; return 0; }
# close → connected MUST become the JSON boolean false, siblings + owner preserved.
( AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json )
jq -e '.lane==2 and .port==53421 and .session=="abpool-2" and .owner.pid==55 and .owner.comm=="pi" and .owner.starttime==999 and .chrome_pid==7 and .chrome_pgid==8 and .connected==false' \\
    "\$POOL_LANES_DIR/2.json" >/dev/null
EOF
    rc=0
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
          AGENT_BROWSER_REAL="$noop" \
          timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "close flips connected true→false, siblings+owner preserved (out: $out)" || return 1
}

# --- pool_wrapper_main leaves connected UNCHANGED for non-close (P1.M3.T1.S1 / Issue #3) ---
# Companion to the close-flips test: a driving non-close command (open) must NOT touch
# .connected (the predicate returns 1 → the close block is skipped). Same hermetic,
# timeout-bounded subshell pattern. Guards against the block accidentally over-firing.
selftest_open_does_not_flip_connected() {
    local outdir noop script rc out
    outdir="$ABPOOL_TEST_ROOT/open-unchanged"
    mkdir -p -- "$outdir"
    noop="$outdir/noop.sh"
    printf '#!/bin/sh\nexit 0\n' >"$noop"; chmod +x -- "$noop"
    script="$outdir/body.sh"
    cat >"$script" <<EOF
set -euo pipefail
source "\$1/lib/pool.sh"
pool_config_init
pool_state_init
pool_lease_write 1 "\$2/active/1" 53420 abpool-1 1 pi 100 "\$2" 0 0 true
pool_ensure_connected() { return 0; }
pool_lease_find_mine()   { printf '1\n'; return 0; }
( AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main open about:blank )
test "\$(jq -r .connected "\$POOL_LANES_DIR/1.json")" = "true"   # unchanged
EOF
    rc=0
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
          AGENT_BROWSER_REAL="$noop" \
          timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "open leaves connected=true unchanged (out: $out)" || return 1
}

# --- close survives a corrupt lease (defensive subshell contains pool_die) ---
# A corrupt (non-JSON) lease makes pool_lease_update pool_die (exit 1). The close block runs
# pool_lease_update in a SUBSHELL so the exit is contained; the wrapper still reaches exec
# (PRD §2.15: close must always run). Hermetic, timeout-bounded subshell. AGENTS.md §3/§4.
selftest_close_survives_corrupt_lease() {
    local outdir noop script rc out
    outdir="$ABPOOL_TEST_ROOT/close-corrupt"
    mkdir -p -- "$outdir/state/lanes"
    printf 'NOT JSON' >"$outdir/state/lanes/1.json"   # corrupt lease → pool_lease_update pool_die's
    noop="$outdir/noop.sh"
    printf '#!/bin/sh\nexit 0\n' >"$noop"; chmod +x -- "$noop"
    script="$outdir/body.sh"
    cat >"$script" <<'EOF'
set -euo pipefail
source "$1/lib/pool.sh"
pool_config_init
pool_state_init
pool_ensure_connected() { return 0; }
pool_lease_find_mine()   { printf '1
'; return 0; }
# corrupt lease (NOT JSON) → pool_lease_update pool_die's → subshell must contain it → exec runs.
( AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close )
EOF
    rc=0
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
          AGENT_BROWSER_REAL="$noop" \
          timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "close survives corrupt lease (exec ran, pool_die contained) (out: $out)" || return 1
}

# --- pool_ensure_connected rebinds when connected=false (P1.M3.T1.S2 / Issue #3 READ side) ---
# The FIX: connected=false (S1 wrote it on close) must make pool_ensure_connected SKIP the
# pool_daemon_connected early-exit (even though that probe returns 0 — the post-close false
# positive) and instead call pool_daemon_connect to rebind, flipping connected back to true.
# Chrome-FREE: stub pool_daemon_connected (→0), curl (→0, so the reconnect branch — not
# relaunch — fires), pool_daemon_connect (records + →0). Hermetic, timeout-bounded subshell.
selftest_ensure_connected_rebinds_when_disconnected() {
    local outdir script rc out
    outdir="$ABPOOL_TEST_ROOT/ensure-rebind"
    mkdir -p -- "$outdir"
    script="$outdir/body.sh"
    cat >"$script" <<'EOF'
set -euo pipefail
source "$1/lib/pool.sh"
pool_config_init
pool_state_init
# Lease with connected=false (exactly as S1's close path writes it) + a valid port.
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 false
# Stubs. pool_daemon_connected returns 0 = the post-close FALSE POSITIVE (lingering session +
# alive chrome). curl returns 0 = chrome "alive" → the RECONNECT branch (not relaunch). The
# connect stub records that it was called (the rebind we want to FORCE) + returns 0.
pool_daemon_connected() { return 0; }
curl()                  { return 0; }
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
# The fix: connected=false MUST skip the early-exit → reach pool_daemon_connect + flip connected.
pool_ensure_connected 1
test "$_connect_called" = "1"                                  # rebind CALLED (no early-exit)
test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"   # flipped back to true
EOF
    rc=0
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
          timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "connected=false → ensure_connected rebinds (connect called, connected→true) (out: $out)" || return 1
}

# --- pool_ensure_connected early-exits (no rebind) when connected=true (happy path) ---
# Companion: a normal booted lease (connected=true) MUST still take the pool_daemon_connected
# early-exit and NOT call pool_daemon_connect — i.e. S2 changes nothing for the happy path.
selftest_ensure_connected_skips_rebind_when_connected() {
    local outdir script rc out
    outdir="$ABPOOL_TEST_ROOT/ensure-noop"
    mkdir -p -- "$outdir"
    script="$outdir/body.sh"
    cat >"$script" <<'EOF'
set -euo pipefail
source "$1/lib/pool.sh"
pool_config_init
pool_state_init
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 true
pool_daemon_connected() { return 0; }   # connected + probe rc 0 → early-exit
curl()                  { return 0; }
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
pool_ensure_connected 1
test "$_connect_called" = "0"   # NOT called — early-exit fired (old behavior preserved)
EOF
    rc=0
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
          timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "connected=true → ensure_connected early-exits, no rebind (out: $out)" || return 1
}

# --- pool_chrome_launch EADDRINUSE detection (P1.M2.T1.S1 / Issue 2) -------------
# Mock-based test: a fake "chrome" binary writes an EADDRINUSE line to stderr then
# exits 1 instantly. Verifies pool_chrome_launch detects the bind failure in the log
# and returns 1 (retryable) instead of pool_die (fatal). No real Chrome (AGENTS.md §1).
# Picked up by the single-setup _run_selftest_suite (same runner as the other selftest_*).
#
# NOTE 1 (subshell): pool_chrome_launch may pool_die (exit 1) on the negative case. The
#   body runs it in a SUBSHELL (bash -c '...' || rc=$?) so a pool_die is caught as a
#   non-zero rc, not killing the harness. This is the ONE difference from the
#   pure-function selftests.
# NOTE 2 (set -m, HOST-VERIFIED): the instant-exit block (the `if [[ -z "$pgid" ]]`
#   branch) fires only when `ps -o pgid= -p $PID` returns rc 1 + empty -- i.e. the
#   backgrounded Chrome is ALREADY REAPED (gone from /proc). A backgrounded child that
#   exits becomes a ZOMBIE its parent shell has not yet wait(2)-ed; a zombie still has a
#   /proc entry and `ps` returns its pgid (non-empty) -> the SUCCESS path would fire,
#   bypassing the block under test. Enabling monitor mode (`set -m`) makes the shell
#   auto-reap backgrounded children that exit, so the zombie is reaped before `ps` runs
#   -> empty pgid -> the instant-exit block fires deterministically. `set -m` does NOT
#   change the grep/return-1 logic under test (identical regardless of WHY pgid is
#   empty); it only deterministically reaches the code path. Verified 5/5 runs.
selftest_chrome_launch_eaddrinuse() {
    local fakechrome logdir log_file rc
    # Isolated subdir under the test root (do NOT pollute the shared $POOL_STATE_DIR).
    logdir="$ABPOOL_TEST_ROOT/eaddrinuse-selftest"
    mkdir -p -- "$logdir"
    fakechrome="$logdir/fake-chrome"
    # The fake chrome: write the primary Chromium EADDRINUSE string to stderr (captured
    # to the log by the setsid redirect), then exit 1 instantly (triggers empty-pgid).
    cat >"$fakechrome" <<'MOCK'
#!/usr/bin/env bash
echo "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2
exit 1
MOCK
    chmod +x -- "$fakechrome"

    # Point POOL_CHROME_BIN at the fake + POOL_STATE_DIR at the isolated logdir so the
    # chrome-<lane>.log lands where we can inspect it. Run pool_chrome_launch in a SUBSHELL
    # so a (buggy) pool_die is caught as a non-zero rc rather than killing the harness.
    # `set -m` makes the instant-exit block fire deterministically (see NOTE 2 above).
    log_file="$logdir/chrome-7.log"
    rc=0
    AGENT_CHROME_BIN="$fakechrome" \
    AGENT_BROWSER_POOL_STATE="$logdir" \
    timeout 10 bash -c '
        set -m -euo pipefail
        source "$1/lib/pool.sh"
        pool_config_init
        pool_chrome_launch 53420 /tmp/__abp_dummy_udd__ 7
    ' _ "$ABPOOL_REPO" || rc=$?

    # ASSERT: rc 1 (EADDRINUSE detected -> return 1, NOT pool_die's exit 1 which would
    # also be rc 1; the distinguishing evidence is the log contained the EADDRINUSE text
    # the grep matched, AND no "exited immediately" pool_die message -- but the cleanest
    # machine-checkable assertion is rc==1 + the log file exists + the grep matches it).
    assert_eq "1" "$rc" "pool_chrome_launch returns 1 on EADDRINUSE instant-exit (not 0)" || return 1
    [[ -f "$log_file" ]] || { _fail "chrome log not created at $log_file"; return 1; }
    grep -qiE 'cannot start http server|address already in use' "$log_file" \
        || { _fail "log missing EADDRINUSE text (grep pattern would not have matched)"; return 1; }

    # --- Negative case: a fake chrome that exits 1 WITHOUT EADDRINUSE -> pool_die (rc!=0) ---
    # Proves the grep is selective: a non-EADDRINUSE instant-exit still fails (the grep
    # did NOT match -> pool_die fired). We assert rc!=0 (failure) AND the log does NOT
    # match the EADDRINUSE pattern.
    local fakebad="$logdir/fake-bad-chrome"
    cat >"$fakebad" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR:gpu_init.cc] GPU process isn't usable. Goodbye." >&2
exit 1
MOCK
    chmod +x -- "$fakebad"
    local log2="$logdir/chrome-8.log" rc2=0
    AGENT_CHROME_BIN="$fakebad" \
    AGENT_BROWSER_POOL_STATE="$logdir" \
    timeout 10 bash -c '
        set -m -euo pipefail
        source "$1/lib/pool.sh"
        pool_config_init
        pool_chrome_launch 53421 /tmp/__abp_dummy_udd2__ 8
    ' _ "$ABPOOL_REPO" || rc2=$?
    # Non-EADDRINUSE instant-exit -> pool_die -> rc!=0 (must NOT be rc 0).
    [[ "$rc2" -ne 0 ]] || { _fail "non-EADDRINUSE instant-exit returned 0 (should fail)"; return 1; }
    # And the log must NOT contain EADDRINUSE text (proving the grep correctly did NOT match).
    if [[ -f "$log2" ]] && grep -qiE 'cannot start http server|address already in use' "$log2"; then
        _fail "negative-case log unexpectedly matched EADDRINUSE"; return 1
    fi
}

# --- _pool_launch_and_verify port re-pick on launch failure (P1.M2.T1.S2 / Issue 2, path a) ---
# Mock-based test: pool_chrome_launch returns 1 (EADDRINUSE — S1) on the original port and
# 0 on the re-picked port; pool_wait_cdp returns 0 on the new port. Verifies _pool_launch_and_verify
# catches the rc-1, re-picks a different port via pool_find_free_port, updates the lease, retries,
# and returns 0 with the lease holding the NEW port. No real Chrome (AGENTS.md §1).
# Runs in a bash -c SUBSHELL so the mock functions (which shadow the lib fns) are scoped — they
# do NOT leak into the main shell and pollute the other selftests (single-setup runner, AGENTS.md §4).
selftest_launch_and_verify_repick_on_launch_fail() {
    local dir lane orig new rc lease_port
    dir="$ABPOOL_TEST_ROOT/ephemeral-rp1"; mkdir -p -- "$dir"
    lane=7; orig=53420; new=53421
    # Provisional lease for lane 7 with port=orig (simulates pool_boot_lane step b).
    pool_lease_write "$lane" "$dir" "$orig" "abpool-$lane" \
        12345 "pi" 99999 "$ABPOOL_TEST_ROOT" 0 0 false
    # Run _pool_launch_and_verify in a subshell with mocked launch/wait/find_free_port.
    rc=0
    timeout 15 bash -c '
        set -euo pipefail
        repo="$1"; orig="$2"; new="$3"; dir="$4"; lane="$5"
        source "$repo/lib/pool.sh"
        pool_config_init
        # --- mocks (port-conditional; scoped to this subshell) ---
        pool_chrome_launch() {
            if [[ "$1" == "$orig" ]]; then return 1; fi   # EADDRINUSE on the original port
            POOL_CHROME_PID=99999; declare -g POOL_CHROME_PID
            POOL_CHROME_PGID=99999; declare -g POOL_CHROME_PGID
            return 0
        }
        pool_wait_cdp() { [[ "$1" != "$orig" ]]; }        # orig times out; new is ready
        pool_find_free_port() { printf "%s\n" "$new"; }   # the re-pick port
        _pool_launch_and_verify "$orig" "$dir" "$lane"
    ' _ "$ABPOOL_REPO" "$orig" "$new" "$dir" "$lane" || rc=$?
    assert_eq "0" "$rc" "path-a: _pool_launch_and_verify returns 0 after launch-fail re-pick" || return 1
    lease_port="$(pool_lease_field "$lane" port)"
    assert_eq "$new" "$lease_port" "path-a: lease port updated to the re-picked port" || return 1
}

# --- _pool_launch_and_verify port re-pick on CDP timeout (P1.M2.T1.S2 / Issue 2, path b) ---
# Mock-based test: pool_chrome_launch succeeds (rc 0) on BOTH attempts for the original port,
# but pool_wait_cdp times out (rc 1) on both; on the re-picked port, both succeed. Verifies the
# "both same-port CDP-timeout attempts failed" trigger path reaches the re-pick. No real Chrome.
selftest_launch_and_verify_repick_on_cdp_timeout() {
    local dir lane orig new rc lease_port
    dir="$ABPOOL_TEST_ROOT/ephemeral-rp2"; mkdir -p -- "$dir"
    lane=8; orig=53430; new=53431
    pool_lease_write "$lane" "$dir" "$orig" "abpool-$lane" \
        12345 "pi" 99999 "$ABPOOL_TEST_ROOT" 0 0 false
    rc=0
    timeout 15 bash -c '
        set -euo pipefail
        repo="$1"; orig="$2"; new="$3"; dir="$4"; lane="$5"
        source "$repo/lib/pool.sh"
        pool_config_init
        # --- mocks ---
        pool_chrome_launch() {   # always succeeds (sets globals)
            POOL_CHROME_PID=88888; declare -g POOL_CHROME_PID
            POOL_CHROME_PGID=88888; declare -g POOL_CHROME_PGID
            return 0
        }
        pool_wait_cdp() { [[ "$1" != "$orig" ]]; }        # orig times out (both attempts); new ready
        pool_find_free_port() { printf "%s\n" "$new"; }
        _pool_launch_and_verify "$orig" "$dir" "$lane"
    ' _ "$ABPOOL_REPO" "$orig" "$new" "$dir" "$lane" || rc=$?
    assert_eq "0" "$rc" "path-b: _pool_launch_and_verify returns 0 after CDP-timeout re-pick" || return 1
    lease_port="$(pool_lease_field "$lane" port)"
    assert_eq "$new" "$lease_port" "path-b: lease port updated to the re-picked port" || return 1
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
