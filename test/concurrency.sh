#!/usr/bin/env bash
#
# test/concurrency.sh — concurrency & mutual-exclusion test (PRD §2.18; goals §1.3.2/§1.3.3).
#
# Validates: "N parallel agents (distinct owner PIDs via the override) must each get a
# distinct lane; assert no two share a lane and all release cleanly with no leftover
# dirs/processes." Drives the REAL acquire+boot path (pool_owner_resolve →
# pool_acquire_locked → pool_boot_lane) in N parallel subshells against ONE shared temp
# pool + lock file. Boots REAL headless Chrome per lane (requires the real master profile +
# btrfs + google-chrome-stable — ALL host-verified present).
#
# HOW IT WORKS (the concurrency seam): the pool entry point (bin/agent-browser-pool →
# pool_wrapper_main) TERMINATES via `exec "$POOL_REAL_BIN" …` — a pool-driven `open` test would hang on
# `wait` (the real agent-browser may not exit for `open`). Driving the lib's acquire+boot
# functions DIRECTLY in each subshell exercises the EXACT same flock + boot code path WITHOUT
# the terminal exec, so `wait` joins cleanly. This is the correct test boundary for a
# concurrency/mutual-exclusion test (it tests the SUT's locking, not the upstream `open`).
#
# SOURCES the LANDED test framework (P1.M9.T1.S1) for: spawn_sim_owner (the `pi`-comm owner
# engine — REQUIRED because pool_owner_alive reads the REAL /proc comm), setup/teardown
# (hermetic mktemp isolation), the 5 assertion helpers, run_test/abpool_run_suite.
set -euo pipefail

# --- repo + framework resolution (mirror test/validate.sh's symlink-safe bootstrap) ------
CONCURRENCY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=./validate.sh
source "$CONCURRENCY_DIR/validate.sh"
# (validate.sh already sourced lib/pool.sh + defined helpers + setup/teardown/runner.)

# =============================================================================
# _concurrency_setup_master — make a REAL (non-empty) master on a btrfs ephemeral root.
#
# WHY (the hermetic-real-Chrome gap): validate.sh's setup() points AGENT_CHROME_MASTER at an
# EMPTY temp dir ($ABPOOL_TEST_ROOT/master, just mkdir -p'd). pool_check_master (lib/pool.sh:266)
# pool_die's on an empty/missing master → pool_boot_lane would fail. AND pool_copy_master
# (lib/pool.sh:1253) needs the ephemeral root on btrfs (reflink) OR AGENT_CHROME_ALLOW_SLOW_COPY=1.
#
# SOLUTION: override the THREE host resources setup() does NOT provide:
#   - AGENT_CHROME_MASTER → a REAL master (the copy source):
#     (A) REUSE the operator's real master (fastest, zero-copy): point AGENT_CHROME_MASTER at the
#       real ~/.agent-chrome-profiles/master-profile (resolve via the REAL pre-override HOME,
#       captured before setup() overrides HOME). The master is READ-ONLY (PRD §2.7) → safe to
#       share. reflink copies are CoW → N concurrent copies of the same source are safe (btrfs
#       refcounts the shared blocks). Host-verified: the real master exists, is non-empty
#       (45 entries), and is on btrfs.
#     (B) FALLBACK: build a MINIMAL master if the real one is absent (so the test is runnable
#       on a fresh checkout): mkdir -p "$M/Default"; printf '{"minimal":true}' >"$M/Preferences".
#       A minimal master boots headless Chrome to CDP readiness (enough for the concurrency
#       contract) though it lacks the "trusted profile" anti-bot identity (irrelevant for a
#       plumbing concurrency test).
#   - AGENT_CHROME_EPHEMERAL_ROOT → a btrfs-backed temp dir (see the btrfs gotcha below):
#     setup() puts it under mktemp -d -t → /tmp (tmpfs here) → reflink fails. Relocate to a
#     fresh btrfs temp dir under the real $HOME; reap it at the body's cleanup point +
#     pre-emptively here (the framework trap can't see a subshell-created root).
#   - AGENT_BROWSER_REAL → the operator's real agent-browser binary (the connect step):
#     setup() overrides HOME → POOL_REAL_BIN = $HOME/.local/bin/agent-browser → the EMPTY temp
#     HOME → the binary is absent → pool_daemon_connect fails → pool_boot_lane drops every lane.
#     Resolve + override to the real binary (host-verified present).
# This function uses strategy (A) for the master when the real one is present; otherwise (B).
# It re-runs pool_config_init so POOL_MASTER_DIR / POOL_EPHEMERAL_ROOT / POOL_REAL_BIN reflect
# all overrides. The btrfs ephemeral root is reaped TWO ways for hermeticity: (1) explicitly
# at the test body's cleanup point (success path) + (2) pre-emptively here on the next run
# (failure-path backstop) — see the comments in the body below for why the framework's EXIT
# trap can't see it (subshell state loss).
#
# GOTCHA (btrfs ephemeral root — host-specific): validate.sh's setup() sets
# AGENT_CHROME_EPHEMERAL_ROOT="$ABPOOL_TEST_ROOT/active", where ABPOOL_TEST_ROOT comes from
# `mktemp -d -t abpool-test.XXXXXX`. `mktemp -d -t` uses $TMPDIR or /tmp — which on this host
# is a tmpfs (NOT btrfs). pool_copy_master needs the ephemeral root on btrfs for reflink (cp
# --reflink=always) OR AGENT_CHROME_ALLOW_SLOW_COPY=1 (a catastrophic 4.8 GB copy × N). The fix:
# relocate the ephemeral root to a FRESH btrfs temp dir under the real $HOME (btrfs here).
# Because the test body runs in a subshell whose state does NOT propagate to the main shell
# (where the framework's EXIT trap lives), the btrfs root is reaped explicitly at the body's
# cleanup point + pre-emptively here (reaping stale roots from prior failed runs). Stays
# hermetic across both success and failure paths.
# =============================================================================
_concurrency_setup_master() {
    local real_home real_master btrfs_parent="" fs_home fs_master new_root
    # Resolve the operator's REAL home + master BEFORE setup() clobbered HOME (setup already
    # ran by the time a test body executes; capture the real home from the passwd entry).
    real_home="$(getent passwd "${USER:-$(id -un)}" | cut -d: -f6)"
    real_master="$real_home/.agent-chrome-profiles/master-profile"

    # (1) Relocate the ephemeral root to btrfs FIRST (pool_copy_master needs reflink). Pick a
    #     btrfs parent: prefer the real $HOME (btrfs here); fall back to wherever the real
    #     master lives (also btrfs); only if NEITHER is btrfs do we force the slow-copy escape
    #     hatch (still correct, just slower). Track the new root for hermetic cleanup.
    [[ -n "${real_home:-}" ]] && fs_home="$(stat -f -c %T "$real_home" 2>/dev/null || true)"
    [[ -n "${real_master:-}" ]] && fs_master="$(stat -f -c %T "$real_master" 2>/dev/null || true)"
    if [[ "$fs_home" == "btrfs" ]]; then
        btrfs_parent="$real_home/.cache/abpool-test-ephemeral"
    elif [[ "$fs_master" == "btrfs" ]]; then
        btrfs_parent="$(dirname -- "$real_master")/abpool-test-ephemeral"
    fi
    if [[ -n "$btrfs_parent" ]]; then
        # Pre-emptive self-healing cleanup: reap any STALE btrfs roots from prior runs that
        # leaked (e.g. a mid-body assert failure prevented the body's own cleanup). The body
        # runs in a subshell whose ABPOOL_TEST_ROOTS+= is lost in the main shell (where the
        # framework EXIT trap lives), so the framework can't reap our btrfs root → we reap
        # stale ones here + our own at the body's cleanup point. Best-effort.
        rm -rf -- "$btrfs_parent"/ephemeral.* 2>/dev/null || true
        # Fresh btrfs-backed ephemeral root per test (mktemp -d -p needs the parent to exist).
        mkdir -p -- "$btrfs_parent"
        new_root="$(mktemp -d -p "$btrfs_parent" ephemeral.XXXXXX)"
        export AGENT_CHROME_EPHEMERAL_ROOT="$new_root"
        _concurrency_btrfs_root="$new_root"   # strategy-B master lands here (on btrfs)
    else
        # No btrfs available → allow the (slow) full copy so the test still runs.
        export AGENT_CHROME_ALLOW_SLOW_COPY=1
        # ABPOOL_TEST_ROOT (singular) is the framework's per-test temp root (set by setup);
        # ABPOOL_TEST_ROOTS (plural) is the array the trap iterates. Not a typo → silence SC2153.
        # shellcheck disable=SC2153
        _concurrency_btrfs_root="$ABPOOL_TEST_ROOT"
    fi

    # (2) Override AGENT_CHROME_MASTER to a REAL non-empty master (the hermetic-real-Chrome
    #     gap: setup() made an EMPTY temp master → pool_check_master pool_die's on boot).
    if [[ -d "$real_master" ]] && [[ -n "$(ls -A "$real_master" 2>/dev/null)" ]]; then
        # Strategy A: reuse the real master (read-only; reflink CoW → concurrent-copy safe).
        export AGENT_CHROME_MASTER="$real_master"
    else
        # Strategy B: build a minimal master on the (btrfs) ephemeral-root parent.
        local m="$_concurrency_btrfs_root/master-real"
        mkdir -p -- "$m/Default"
        printf '{"minimal":true,"profile":{"name":"abpool-concurrency-test"}}' >"$m/Preferences"
        export AGENT_CHROME_MASTER="$m"
    fi

    # (3) Override AGENT_BROWSER_REAL to the operator's real agent-browser binary (a SECOND
    #     hermetic-real-Chrome gap): setup() overrides HOME → pool_config_init derives
    #     POOL_REAL_BIN from $HOME/.local/bin/agent-browser → the EMPTY temp HOME → the binary
    #     is absent → pool_daemon_connect ('$POOL_REAL_BIN' --session ... connect ...) fails
    #     → pool_boot_lane drops every lane (rc 1). Resolve the real binary from the real
    #     HOME + only override if it actually exists (else leave it; the boot will fail loudly
    #     with a clear path, which is the honest signal on a host lacking agent-browser).
    local real_bin="$real_home/.local/bin/agent-browser"
    if [[ -x "$real_bin" ]]; then
        local real_bin_resolved
        real_bin_resolved="$(readlink -f -- "$real_bin")"
        export AGENT_BROWSER_REAL="$real_bin_resolved"
    fi

    # (4) Re-resolve POOL_MASTER_DIR + POOL_EPHEMERAL_ROOT + POOL_REAL_BIN (+ all POOL_*
    #     globals) against the overrides. Idempotent.
    pool_config_init
    pool_state_init
}

# =============================================================================
# _concurrency_run_one_lane OWNER_PID OWNER_ST RESULT_FILE
#
# The PER-AGENT body, designed to run inside a `( … ) &` subshell. Resolves THIS subshell's
# owner identity (via the override PID — already exported by the caller), acquires a lane
# under the shared flock, boots it (real headless Chrome), and records the lane number to
# RESULT_FILE for the parent's distinctness assertions. MUST exit non-zero on any failure
# (the parent's per-PID `wait` captures it).
#
# WHY DIRECT LIB CALLS (not via the pool entry point): see the header comment — pool_wrapper_main exec's into
# the real agent-browser and may not exit; direct acquire+boot avoids the hang.
# WHY pool_owner_resolve FIRST: it reads the override env vars into the POOL_OWNER_* globals
# (the lease identity). The subshell INHERITED the parent's POOL_OWNER_* (from setup) → we
# MUST re-resolve so THIS agent's PID/starttime land in the globals before acquire writes
# the lease.
# set -e GUARDS: pool_acquire_locked rc 1 (exhaustion) + pool_lease_field rc 1 (missing) +
#   pool_boot_lane rc 1 (recoverable boot failure) all ABORT bare → guard each.
# =============================================================================
_concurrency_run_one_lane() {
    # owner_st is part of the documented (OWNER_PID OWNER_ST RESULT_FILE) signature but
    # unused here: the owner identity is read via pool_owner_resolve from the EXPORTED
    # AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME env (the caller's subshell-scoped export).
    # shellcheck disable=SC2034
    local owner_pid="$1" owner_st="$2" result_file="$3" N port
    # Re-resolve owner identity for THIS subshell (reads the exported override).
    pool_owner_resolve
    if ! N="$(pool_acquire_locked)"; then
        printf 'acquire failed for owner %s\n' "$owner_pid" >&2
        exit 1
    fi
    # A freshly-claimed lane is PROVISIONAL (port=0). Boot it (copy+port+launch+connect).
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        if ! pool_boot_lane "$N"; then
            printf 'boot failed for lane %s (owner %s)\n' "$N" "$owner_pid" >&2
            # pool_boot_lane already cleaned up the lane on its rc-1 path. Record failure.
            printf 'FAIL\n' >"$result_file"
            exit 1
        fi
    fi
    # Record the lane number for the parent's distinctness assertions (single value).
    printf '%s\n' "$N" >"$result_file"
    exit 0
}

# =============================================================================
# _assert_all_distinct_and_nonzero VALUES… — return 0 iff every value is non-empty, != "0",
# and no two are equal. Uses an associative-array dedup (no subshell). The "!= 0" guard is
# CRITICAL: a provisional lease (port=0, chrome_pid=0) must NOT masquerade as a valid
# distinct value — if any lane failed to boot, its port/chrome_pid is 0 and this catches it.
# =============================================================================
_assert_all_distinct_and_nonzero() {
    local v
    local -A seen=()
    for v in "$@"; do
        [[ -n "$v" && "$v" != "0" && "$v" != "null" ]] || return 1
        [[ -z "${seen[$v]:-}" ]] || return 1
        seen["$v"]=1
    done
    return 0
}

# =============================================================================
# THE CONCURRENCY TEST (PRD §2.18). N=3 (item §3a says 3-5; 3 is the minimum that proves
# mutual exclusion beyond a pair while keeping the parallel-boot window + Chrome resource
# cost modest). Each of N agents: distinct sim-owner PID → distinct lease owner.pid →
# distinct lane (under flock) → distinct port + chrome_pid (after boot).
# =============================================================================
test_n_agents_get_n_distinct_lanes() {
    local N=3 i pid st
    local -a owner_pids=() owner_sts=() bg_pids=() lane_nums=()
    local results_dir="$ABPOOL_TEST_ROOT/results"
    mkdir -p -- "$results_dir"

    # (1) Supply a REAL master (real-Chrome gap fix) + keep the ephemeral root on btrfs.
    _concurrency_setup_master

    # (2) Spawn N DISTINCT live "pi"-comm owners. setup() already spawned ONE (its
    #     AGENT_BROWSER_POOL_OWNER_PID) — use it as owner #0, spawn N-1 MORE here.
    #     spawn_sim_owner appends to ABPOOL_SIM_BINS (trap removes the bin dirs) + returns
    #     after the fork→exec settle (comm==pi). Each PID is UNIQUE (different processes).
    owner_pids+=("$AGENT_BROWSER_POOL_OWNER_PID")
    owner_sts+=("$AGENT_BROWSER_POOL_OWNER_STARTTIME")
    for (( i = 1; i < N; i++ )); do
        pid="$(spawn_sim_owner)"
        st="$(_pool_get_starttime "$pid")"   # split capture (SC2155); settles inside spawn
        owner_pids+=("$pid")
        owner_sts+=("$st")
    done

    # (3) Sanity: the N owner PIDs are themselves distinct (defensive — proves spawn worked).
    if ! _assert_all_distinct_and_nonzero "${owner_pids[@]}"; then
        _fail "owner PIDs not distinct/nonzero: ${owner_pids[*]}"; return 1
    fi

    # (4) Launch N parallel acquire+boot subshells. Each subshell OVERRIDES the owner env
    #     for ITSELF ONLY (subshell-scoped export → parent + siblings unaffected). They
    #     SHARE the temp pool state + lock file (inherited) → contend for the SAME flock.
    #     NO stagger (Issue 2 / S3): previously a ~0.3s sleep narrowed the pool_find_free_port
    #     TOCTOU window to AVOID port collisions. The boot path now HANDLES collisions
    #     transparently — pool_chrome_launch detects an EADDRINUSE instant-exit and returns 1
    #     (S1), and _pool_launch_and_verify re-picks a different port via pool_find_free_port
    #     and retries once (S2), updating the lease (pool_boot_lane re-reads it). So the N
    #     boots launch back-to-back to EXERCISE that recovery under genuine concurrent load;
    #     the distinct-port + clean-release assertions below (steps 7-9) verify it worked.
    #     BUG-1 fix: pool_wait_cdp additionally verifies via pool_cdp_is_ours that the CDP
    #     answerer is ACTUALLY this lane's Chrome (the lane's DevToolsActivePort file + pid
    #     liveness) — without it, a foreign lane answering our port would let two lanes
    #     silently share one Chrome. The identity mismatch now feeds the same re-pick path.
    #     (A rare 3-way collision where the re-picks themselves collide can still drop a lane;
    #     if that makes the test persistently flaky on a host, re-introduce a MINIMAL stagger
    #     — see the comment at the launch loop / research §3. Prefer no stagger.)
    for (( i = 0; i < N; i++ )); do
        (
            # Subshell-scoped export: sets the owner env for ONLY this subshell + its
            # children (env copied at fork). Parent + sibling subshells are UNAFFECTED →
            # N parallel subshells get N distinct owner PIDs with zero cross-talk. This is
            # INTENTIONAL (research §external-2) → SC2030 (local-to-subshell modification)
            # is the design, not a bug → silenced per-line below.
            # shellcheck disable=SC2030
            export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"
            # shellcheck disable=SC2030
            export AGENT_BROWSER_POOL_OWNER_STARTTIME="${owner_sts[$i]}"
            _concurrency_run_one_lane "${owner_pids[$i]}" "${owner_sts[$i]}" \
                "$results_dir/lane-$i"
        ) &
        bg_pids+=("$!")
        # No stagger (Issue 2 / S3): launch back-to-back so concurrent boots collide on the
        # pool_find_free_port TOCTOU window, exercising the port re-pick recovery (pool_chrome_launch
        # EADDRINUSE detect — S1; _pool_launch_and_verify re-pick + retry — S2). The distinct-port
        # + clean-release assertions below confirm all lanes still succeed. See the step-(4) comment.
    done

    # (5) JOIN per-PID. Bare `wait` returns 0 always (masks failures) → loop per PID.
    #     `wait "$p" || fail=1` is errexit-exempt (the || list).
    local fail=0
    for pid in "${bg_pids[@]}"; do
        wait "$pid" || fail=1
    done
    if (( fail != 0 )); then
        _fail "one or more parallel acquire+boot subshells failed"; return 1
    fi

    # (6) Collect the lane numbers (parent, AFTER wait — no race).
    for (( i = 0; i < N; i++ )); do
        local lf="$results_dir/lane-$i" ln
        [[ -s "$lf" ]] || { _fail "result file $lf missing/empty (subshell died)"; return 1; }
        ln="$(<"$lf")"
        [[ "$ln" == "FAIL" ]] && { _fail "subshell $i reported boot failure"; return 1; }
        lane_nums+=("$ln")
    done

    # (7) ASSERT exactly N lanes exist in the pool (pool_lanes_list rc 0 always → mapfile safe).
    local -a held_lanes
    mapfile -t held_lanes < <(pool_lanes_list)
    assert_eq "$N" "${#held_lanes[@]}" "exactly N lanes held" || return 1

    # (8) ASSERT distinct owner.pid / port / chrome_pid across the held lanes. Read each
    #     lease field with pool_lease_field GUARDED (rc 1 on missing/corrupt → `|| true`
    #     inside $(…) keeps it set -e-safe). Collect into arrays, then dedup-check.
    local ln fpid fport fcpid
    local -a held_pids=() held_ports=() held_cpids=()
    for ln in "${held_lanes[@]}"; do
        assert_lane_exists "$ln" || return 1
        fpid="$(pool_lease_field "$ln" owner.pid 2>/dev/null)" || fpid=""
        fport="$(pool_lease_field "$ln" port 2>/dev/null)" || fport=""
        fcpid="$(pool_lease_field "$ln" chrome_pid 2>/dev/null)" || fcpid=""
        held_pids+=("$fpid"); held_ports+=("$fport"); held_cpids+=("$fcpid")
    done
    # distinct owner.pid (the N sim owners) — THE core mutual-exclusion assertion.
    if ! _assert_all_distinct_and_nonzero "${held_pids[@]}"; then
        _fail "owner.pid not all distinct/nonzero: ${held_pids[*]}"; return 1
    fi
    # distinct port (all >0 → all booted; no two share a port — PRD §1.3.3).
    if ! _assert_all_distinct_and_nonzero "${held_ports[@]}"; then
        _fail "port not all distinct/nonzero: ${held_ports[*]}"; return 1
    fi
    # distinct chrome_pid (all >0 → each lane has its OWN Chrome — PRD §1.3.2).
    if ! _assert_all_distinct_and_nonzero "${held_cpids[@]}"; then
        _fail "chrome_pid not all distinct/nonzero: ${held_cpids[*]}"; return 1
    fi

    # (9) CLEANUP ASSERTIONS (PRD §2.18: "every test must release/reap and assert cleanup").
    #     release all AS A SUBPROCESS (pool_die inside the admin tool can't kill the harness).
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    # No lanes remain.
    local -a held_after
    mapfile -t held_after < <(pool_lanes_list)
    assert_eq "0" "${#held_after[@]}" "no lanes remain after release all" || return 1
    # Each lane's lease file + ephemeral dir is gone.
    for ln in "${lane_nums[@]}"; do
        assert_lane_gone "$ln" || return 1
    done
    # No Chrome processes scoped to the pool's ephemeral root (assert_no_chrome uses the
    # scoped pgrep — does NOT false-positive the operator's daily-driver Chrome).
    assert_no_chrome || return 1

    # (9b) Reap the btrfs ephemeral root dir itself (release all removed the lane SUBDIRS +
    #      killed Chrome; the root dir persists). Hermeticity (PRD §2.18 / AGENTS.md §3): the
    #      framework's EXIT trap runs in the MAIN shell + can't see this subshell's btrfs
    #      root, so reap it explicitly here. Best-effort; _concurrency_setup_master ALSO
    #      pre-emptively reaps stale roots on the next run (failure-path backstop).
    [[ -n "${_concurrency_btrfs_root:-}" ]] \
        && rm -rf -- "$_concurrency_btrfs_root" 2>/dev/null || true

    # (10) Kill the N-1 EXTRA sim owners spawned in this body (setup's one is killed by
    #      teardown). Best-effort (|| true); they'd otherwise linger until their 600s sleep.
    for (( i = 1; i < N; i++ )); do
        kill "${owner_pids[$i]}" 2>/dev/null || true
    done
}

# =============================================================================
# A SMALLER, Chrome-free sanity test — proves the flock distinctness WITHOUT the real-Chrome
# boot cost. Acquires N PROVISIONAL lanes (port=0) in parallel + asserts distinct lane
# numbers + distinct owner.pid. This is a fast (sub-second) regression gate for the locking
# itself, independent of Chrome/master/btrfs availability. (If real Chrome is unavailable on
# a host, this test still proves mutual exclusion at the lane-allocation layer.)
# =============================================================================
test_n_provisional_lanes_are_distinct() {
    local N=4 i pid st
    local -a owner_pids=() owner_sts=() bg_pids=() lane_nums=()
    local results_dir="$ABPOOL_TEST_ROOT/results"
    mkdir -p -- "$results_dir"

    # SC2031 (info) is a cross-function false positive: shellcheck saw test 1's subshell
    # `export AGENT_BROWSER_POOL_OWNER_PID` + flags every later read/export of the same
    # name as "modified in a subshell, might be lost". The env var is set fresh by setup()
    # in the MAIN shell each test (no cross-test state) → the info is inapplicable here.
    # shellcheck disable=SC2031
    owner_pids+=("$AGENT_BROWSER_POOL_OWNER_PID")
    # shellcheck disable=SC2031
    owner_sts+=("$AGENT_BROWSER_POOL_OWNER_STARTTIME")
    for (( i = 1; i < N; i++ )); do
        pid="$(spawn_sim_owner)"
        st="$(_pool_get_starttime "$pid")"
        owner_pids+=("$pid"); owner_sts+=("$st")
    done

    # Parallel PROVISIONAL acquires (NO boot — fast; exercises ONLY the flock + claim).
    for (( i = 0; i < N; i++ )); do
        (
            # Subshell-scoped export (same intentional pattern as test 1; SC2031 silenced).
            # shellcheck disable=SC2031
            export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"
            # shellcheck disable=SC2031
            export AGENT_BROWSER_POOL_OWNER_STARTTIME="${owner_sts[$i]}"
            pool_owner_resolve
            local ln
            if ! ln="$(pool_acquire_locked)"; then exit 1; fi
            printf '%s\n' "$ln" >"$results_dir/prov-$i"
            exit 0
        ) &
        bg_pids+=("$!")
    done
    local fail=0
    for pid in "${bg_pids[@]}"; do wait "$pid" || fail=1; done
    if (( fail != 0 )); then _fail "a provisional-acquire subshell failed"; return 1; fi

    # Collect + assert N DISTINCT lane numbers (all nonzero — pool_find_free_lane yields N>=1).
    local lf ln
    for (( i = 0; i < N; i++ )); do
        lf="$results_dir/prov-$i"
        [[ -s "$lf" ]] || { _fail "result $lf missing"; return 1; }
        ln="$(<"$lf")"; lane_nums+=("$ln")
    done
    if ! _assert_all_distinct_and_nonzero "${lane_nums[@]}"; then
        _fail "provisional lane numbers not distinct/nonzero: ${lane_nums[*]}"; return 1
    fi
    # And the owner.pids are distinct too (the lease identity is per-agent).
    local pl fpid; local -a ppids=()
    for pl in "${lane_nums[@]}"; do
        fpid="$(pool_lease_field "$pl" owner.pid 2>/dev/null)" || fpid=""
        ppids+=("$fpid")
    done
    if ! _assert_all_distinct_and_nonzero "${ppids[@]}"; then
        _fail "provisional owner.pid not distinct: ${ppids[*]}"; return 1
    fi

    # Cleanup: release all + assert no leases (no Chrome was booted → assert_no_chrome is
    # trivially true, but assert_lane_gone for each + no lanes remain is the real check).
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    local -a after; mapfile -t after < <(pool_lanes_list)
    assert_eq "0" "${#after[@]}" "no provisional lanes remain" || return 1
    for pl in "${lane_nums[@]}"; do assert_lane_gone "$pl" || return 1; done

    for (( i = 1; i < N; i++ )); do kill "${owner_pids[$i]}" 2>/dev/null || true; done
}

# --- source-vs-execute gate: run the suite ONLY when executed directly. -----------------
# (When sourced by a future aggregator, define the test_* functions without running.)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! abpool_run_suite test_; then
        exit 1
    fi
fi
