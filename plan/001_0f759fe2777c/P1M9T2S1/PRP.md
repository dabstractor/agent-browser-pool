# PRP — P1.M9.T2.S1: Concurrency — N agents get N distinct lanes, no collision

---

## Goal

**Feature Goal**: Create **`test/concurrency.sh`** — a hermetic concurrency / mutual-exclusion
test (PRD §2.18: "N parallel agents (distinct owner PIDs via override) must each get a
distinct lane; assert no two share a lane and all release cleanly with no leftover
dirs/processes"). It `source`s the LANDED `test/validate.sh` framework (P1.M9.T1.S1) for
its helpers/runner, then defines `test_*` bodies that: spawn **N distinct LIVE simulated
`pi`-comm owners** (N `spawn_sim_owner` calls — the pivotal engine, since `pool_owner_alive`
reads the REAL `/proc/<pid>/comm`), launch **N parallel subshells** each `export`ing a
UNIQUE `AGENT_BROWSER_POOL_OWNER_PID` and running the REAL acquire+boot path
(`pool_owner_resolve` → `pool_acquire_locked` → `pool_boot_lane`) against ONE shared temp
pool state + lock file, `wait` per-PID, then **assert** the N lanes have DISTINCT
`owner.pid`, DISTINCT `port` (all >0), and DISTINCT `chrome_pid` (all >0) — and finally
**release all and assert full cleanup** (no leases, no ephemeral dirs, no Chrome scoped to
the ephemeral root). This validates the flock-serialized mutual-exclusion contract
(FINDING 2: lane assignment is serialized under the short flock; boots run concurrently
OUTSIDE the lock).

**Deliverable**: ONE new file — **`test/concurrency.sh`** (`chmod 0755`), in `test/`
(alongside the LANDED `test/validate.sh` + retained `test/.gitkeep`). NO other file is
created or modified. The test boots REAL headless Chrome per lane (requires the real
master profile + btrfs + `google-chrome-stable`, ALL host-verified present) so it
exercises the genuine concurrency contract — not a mocked one.

**Success Definition**:
- `test -f test/concurrency.sh && test -x test/concurrency.sh`; `bash -n test/concurrency.sh`
  passes; `shellcheck -s bash test/concurrency.sh` → only **SC1091 (info)** on the dynamic
  `source ./validate.sh` line (the ACCEPTED codebase convention — identical to the sibling
  `test/validate.sh`, `bin/*`, `install.sh`), NO error/warning severity.
- `bash test/concurrency.sh` → prints `== test_*` lines + `N passed, 0 failed` → **rc 0**.
  The concurrency test must: (a) boot N REAL headless Chromes (one per lane), (b) prove the
  N lanes have distinct owner.pid / port / chrome_pid, (c) release all and leave ZERO
  leases, ZERO ephemeral dirs, ZERO pool Chrome processes.
- **Hermetic**: the test creates files/processes ONLY under the framework's `mktemp` temp
  root; the operator's real `~/.local/state/agent-browser-pool/` + real Chrome are untouched
  (the framework's `setup()` overrides HOME + AGENT_BROWSER_POOL_STATE +
  AGENT_CHROME_EPHEMERAL_ROOT; the test additionally overrides `AGENT_CHROME_MASTER` to a
  **btrfs** copy of the real master so a real headless Chrome can boot — see Gotchas).
- **Isolation sanity**: `before`/`after` snapshot of the real lanes dir is unchanged after
  the run (verified by a Level-2 case).
- `lib/pool.sh`, `bin/agent-browser`, `bin/agent-browser-pool`, `install.sh`,
  `test/validate.sh`, `test/.gitkeep`, `.gitignore`, `PRD.md`, `README.md`, `tasks.json`
  UNCHANGED (`git status --short` shows ONLY `test/concurrency.sh` new untracked, outside
  `plan/`).

## User Persona

**Target User**: The **maintainer / CI runner** executing the P1.M9 validation milestone.
They run `bash test/concurrency.sh` (after `test/validate.sh` exists) to PROVE the pool's
core invariant — "1 agent = 1 browser = 1 ephemeral profile; held lanes can't be grabbed"
(PRD §1.3 goals 2+3) — holds under genuine parallel contention.

**Use Case**: `bash test/concurrency.sh` (developer confidence before merge; CI gate). The
test is one executable file that self-runs its `test_*` functions via the framework's
`abpool_run_suite` runner. It is NOT sourced by other tests (M9.T3/T4 will be sibling files
that also `source test/validate.sh`).

**User Journey**: maintainer runs `bash test/concurrency.sh` → sees `== test_*` + `PASS`
lines → sees `N passed, 0 failed` → trusts that concurrent agents get distinct lanes. On a
regression (e.g. a broken flock), the test FAILS loudly (a duplicate lane/port/chrome_pid,
or leftover Chrome after release) and `abpool_run_suite` returns rc 1.

**Pain Points Addressed**: (1) Without this test, the flock mutual-exclusion contract is
untested — a regression that makes two agents share a lane would slip through. (2) The
comm-liveness coupling makes naive tests spuriously pass (a non-`pi` owner PID looks STALE
→ its lane gets reaped mid-test → the test sees fewer lanes than N and "passes" vacuously);
this test spawns REAL `pi`-comm owners so liveness holds. (3) The `exec`-replaces-process
behavior of the wrapper (`bin/agent-browser open` exec's into the real agent-browser which
may not exit) would hang a naive wrapper-driven test; this test drives the lib's
acquire+boot functions DIRECTLY in the subshell, avoiding the exec entirely.

## Why

- **This IS PRD §2.18's concurrency harness + §1.3 goals 2+3.** §2.18 mandates: "N parallel
  'agents' (distinct owner PIDs via the override) must each get a distinct lane; assert no
  two share a lane and all release cleanly with no leftover dirs/processes." The override
  hooks (`AGENT_BROWSER_POOL_OWNER_PID` + `_OWNER_STARTTIME`) + `spawn_sim_owner` (the
  `pi`-comm engine) already EXIST (LANDED: lib/pool.sh:478 test mode + the framework's
  `spawn_sim_owner`); this task builds the test that USES them to drive N parallel real
  acquires against one shared pool.
- **It validates the SINGLE most important invariant of the pool.** PRD §1.3 goal 3
  ("Mutual exclusion — held lanes can't be grabbed; the next agent gets the next free one")
  + goal 2 ("No two agents ever share a Chrome") are the pool's reason for existing. The
  flock critical section (`pool_acquire_locked` lib/pool.sh:2043 →
  `_pool_acquire_critical_section` lib/pool.sh:1966) is the mechanism; this test is the
  PROOF it works under genuine parallel contention. A thin/wrong test fails to catch a
  regression; a correct one is the CI gate for the core design.
- **The direct-lib-call seam is the correct test boundary.** The wrapper
  (`bin/agent-browser` → `pool_wrapper_main` lib/pool.sh:3451) TERMINATES via
  `exec "$POOL_REAL_BIN" …` (process replacement). A wrapper-driven test
  (`"$ABPOOL_WRAPPER" open https://example.com`) would `exec` into the real agent-browser,
  which for `open` does not reliably exit → `wait` hangs. Driving `pool_owner_resolve` +
  `pool_acquire_locked` + `pool_boot_lane` DIRECTLY in the subshell exercises the EXACT same
  concurrency-critical code path (the flock + the boot) WITHOUT the terminal exec — so
  `wait` joins cleanly. This is the right abstraction level for a concurrency test (it tests
  the SUT's locking, not the upstream tool's `open` behavior).
- **The comm-liveness coupling is non-obvious and pivotal.** `pool_owner_alive`
  (lib/pool.sh:616) reads the REAL `/proc/<pid>/comm` and requires `"pi"`. The override hook
  sets the lease's owner IDENTITY; it does NOT fake the kernel-visible process. So each of
  the N parallel agents is only LIVE (and thus only holds its lane without being reaped) if
  its `AGENT_BROWSER_POOL_OWNER_PID` points at a real `pi`-comm process. `spawn_sim_owner`
  (copies `/usr/bin/sleep` to a file named `pi`, execs it — HOST-VERIFIED 2026-07-13) is the
  REQUIRED engine, called N times. Capturing this here is the difference between a test that
  passes for the right reason and one that passes vacuously.
- **Real Chrome is required (not mockable).** PRD §2.18: "Smoke tests launch a real,
  windowed Chrome — for unattended harness runs set `AGENT_CHROME_HEADLESS=1`." A concurrency
  test that only writes provisional leases (`port=0`) would assert "distinct ports" on N
  zeros — meaningless. Booting real headless Chrome (one per lane) makes the
  distinct-port + distinct-chrome_pid + cleanup assertions MEANINGFUL. Host-verified
  prerequisites: real master at `~/.agent-chrome-profiles/master-profile` (non-empty, 45
  entries), btrfs FS (`stat -f -c %T` → btrfs), `google-chrome-stable` in PATH.

## What

User-visible behavior: **a runnable `test/concurrency.sh`** that, when executed directly,
runs the concurrency + mutual-exclusion test suite (via the framework's `abpool_run_suite`)
and exits 0 on success / 1 on any failure. It sources `test/validate.sh` (LANDED) for the
helpers + runner, defines `test_*` bodies, and runs the suite.

The test boots REAL headless Chrome (N instances). The observable contract:
- N parallel subshells each acquire a distinct lane under the shared flock → N distinct
  lane numbers.
- Each booted lane's lease has a unique `owner.pid` (the N sim-owner PIDs), a unique `port`
  >0 (from `pool_find_free_port`), and a unique `chrome_pid` >0 (from `pool_chrome_launch`).
- After `agent-browser-pool release all`, ZERO lanes remain, ZERO ephemeral dirs remain,
  and ZERO Chrome processes scoped to the ephemeral root remain (asserted via `pgrep -f --
  "user-data-dir=$POOL_EPHEMERAL_ROOT"`).

### The `test/concurrency.sh` body (verbatim contract — authoritative from item §3 + design D1–D8)

```bash
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
# HOW IT WORKS (the concurrency seam): the wrapper (bin/agent-browser → pool_wrapper_main)
# TERMINATES via `exec "$POOL_REAL_BIN" …` — a wrapper-driven `open` test would hang on
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
# SOLUTION: override AGENT_CHROME_MASTER to a REAL master. Two strategies:
#   (A) REUSE the operator's real master (fastest, zero-copy): point AGENT_CHROME_MASTER at the
#       real ~/.agent-chrome-profiles/master-profile (resolve via the REAL pre-override HOME,
#       captured before setup() overrides HOME). The master is READ-ONLY (PRD §2.7) → safe to
#       share. reflink copies are CoW → N concurrent copies of the same source are safe (btrfs
#       refcounts the shared blocks). Host-verified: the real master exists, is non-empty
#       (45 entries), and is on btrfs.
#   (B) FALLBACK: build a MINIMAL master if the real one is absent (so the test is runnable
#       on a fresh checkout): mkdir -p "$M/Default"; printf '{"minimal":true}' >"$M/Preferences".
#       A minimal master boots headless Chrome to CDP readiness (enough for the concurrency
#       contract) though it lacks the "trusted profile" anti-bot identity (irrelevant for a
#       plumbing concurrency test).
# This function uses strategy (A) when the real master is present; otherwise (B). It re-runs
# pool_config_init so POOL_MASTER_DIR reflects the override. The ephemeral root stays on the
# (btrfs) $HOME-backed temp tree → reflink works.
# =============================================================================
_concurrency_setup_master() {
    local real_home real_master
    # Resolve the operator's REAL home + master BEFORE setup() clobbered HOME (setup already
    # ran by the time a test body executes; capture the real home from the passwd entry).
    real_home="$(getent passwd "${USER:-$(id -un)}" | cut -d: -f6)"
    real_master="$real_home/.agent-chrome-profiles/master-profile"
    if [[ -d "$real_master" ]] && [[ -n "$(ls -A "$real_master" 2>/dev/null)" ]]; then
        # Strategy A: reuse the real master (read-only; reflink CoW → concurrent-copy safe).
        export AGENT_CHROME_MASTER="$real_master"
    else
        # Strategy B: build a minimal master in the temp tree (stays on btrfs via $HOME-backed mktemp).
        local m="$ABPOOL_TEST_ROOT/master-real"
        mkdir -p -- "$m/Default"
        printf '{"minimal":true,"profile":{"name":"abpool-concurrency-test"}}' >"$m/Preferences"
        export AGENT_CHROME_MASTER="$m"
    fi
    # Re-resolve POOL_MASTER_DIR (+ all POOL_* globals) against the override. Idempotent.
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
# WHY DIRECT LIB CALLS (not the wrapper): see the header comment — the wrapper exec's into
# the real agent-browser and may not exit; direct acquire+boot avoids the hang.
# WHY pool_owner_resolve FIRST: it reads the override env vars into the POOL_OWNER_* globals
# (the lease identity). The subshell INHERITED the parent's POOL_OWNER_* (from setup) → we
# MUST re-resolve so THIS agent's PID/starttime land in the globals before acquire writes
# the lease.
# set -e GUARDS: pool_acquire_locked rc 1 (exhaustion) + pool_lease_field rc 1 (missing) +
#   pool_boot_lane rc 1 (recoverable boot failure) all ABORT bare → guard each.
# =============================================================================
_concurrency_run_one_lane() {
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
    #     A ~0.3s stagger narrows the pool_find_free_port TOCTOU window (port is written to
    #     the lease BEFORE launch → later find_free_port calls see it claimed).
    for (( i = 0; i < N; i++ )); do
        (
            export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"
            export AGENT_BROWSER_POOL_OWNER_STARTTIME="${owner_sts[$i]}"
            _concurrency_run_one_lane "${owner_pids[$i]}" "${owner_sts[$i]}" \
                "$results_dir/lane-$i"
        ) &
        bg_pids+=("$!")
        sleep 0.3   # narrow the port-allocation TOCTOU (research G2)
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

    owner_pids+=("$AGENT_BROWSER_POOL_OWNER_PID")
    owner_sts+=("$AGENT_BROWSER_POOL_OWNER_STARTTIME")
    for (( i = 1; i < N; i++ )); do
        pid="$(spawn_sim_owner)"
        st="$(_pool_get_starttime "$pid")"
        owner_pids+=("$pid"); owner_sts+=("$st")
    done

    # Parallel PROVISIONAL acquires (NO boot — fast; exercises ONLY the flock + claim).
    for (( i = 0; i < N; i++ )); do
        (
            export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"
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
```
Then `chmod 0755 test/concurrency.sh`.

### Success Criteria

- [ ] `test/concurrency.sh` created (NEW; `chmod 0755`); shebang `#!/usr/bin/env bash` + `set -euo pipefail`.
- [ ] Resolves `CONCURRENCY_DIR` symlink-safely via `readlink -f "${BASH_SOURCE[0]}"` →
      `dirname` → `cd && pwd`; sources `"$CONCURRENCY_DIR/validate.sh"` (which itself sources
      `lib/pool.sh` + defines all helpers/setup/teardown/runner).
- [ ] `_concurrency_setup_master` exports `AGENT_CHROME_MASTER` to a REAL non-empty master
      (the operator's real master if present + non-empty; else a minimal built master) and
      re-runs `pool_config_init` + `pool_state_init` so `POOL_MASTER_DIR` reflects it.
- [ ] `_concurrency_run_one_lane OWNER_PID OWNER_ST RESULT_FILE` re-resolves the owner
      (`pool_owner_resolve`), acquires under flock (`pool_acquire_locked` guarded by `if !`),
      boots the provisional lane (`pool_boot_lane` guarded by `if !`), writes the lane number
      (or `FAIL`) to RESULT_FILE, exits 0/1.
- [ ] `_assert_all_distinct_and_nonzero VALUES…` returns 0 iff every value is non-empty, not
      `"0"`, not `"null"`, AND no two equal (associative-array dedup).
- [ ] `test_n_agents_get_n_distinct_lanes` (N=3): spawns N distinct sim owners; launches N
      parallel `( export AGENT_BROWSER_POOL_OWNER_PID=…; _concurrency_run_one_lane … ) &`
      subshells with a ~0.3s stagger; joins per-PID (`wait "$p" || fail=1`); collects lane
      numbers from per-job result files; asserts exactly N lanes held; asserts distinct
      owner.pid / port / chrome_pid (all >0); releases all; asserts no lanes / no dirs /
      no scoped Chrome; kills the extra sim owners.
- [ ] `test_n_provisional_lanes_are_distinct` (N=4): a Chrome-free sanity test that acquires
      N PROVISIONAL lanes in parallel (no boot) + asserts distinct lane numbers + distinct
      owner.pid; releases all + asserts cleanup.
- [ ] Source-vs-execute gate: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then if ! abpool_run_suite
      test_; then exit 1; fi; fi`.
- [ ] `bash test/concurrency.sh` → `2 passed, 0 failed`, **rc 0** (boots 3 real headless Chromes
      in the first test; 4 provisional acquires in the second).
- [ ] `bash -n test/concurrency.sh` passes; `shellcheck -s bash test/concurrency.sh` → only
      SC1091 (info) on the `source ./validate.sh` line, NO error/warning severity.
- [ ] All `lib/pool.sh`, `bin/*`, `install.sh`, `test/validate.sh`, `test/.gitkeep`,
      `.gitignore`, `PRD.md`, `README.md`, `tasks.json` UNCHANGED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **verbatim `test/concurrency.sh` body**
(item §3 + design D1–D8); the **single-deliverable + `test/` placement** decision; the
**direct-lib-call seam rationale** (the wrapper's terminal `exec` would hang a wrapper-driven
`open` test; driving `pool_owner_resolve` + `pool_acquire_locked` + `pool_boot_lane` directly
exercises the exact same concurrency-critical code path without the exec); the
**comm-liveness coupling** (the pivotal gotcha: `pool_owner_alive` reads real `/proc` comm, so
each of N agents must have a REAL `pi`-comm owner — `spawn_sim_owner` called N times); the
**hermetic-real-Chrome gap** (the framework's `setup()` makes an EMPTY temp master →
`_concurrency_setup_master` overrides `AGENT_CHROME_MASTER` to a real non-empty master on the
btrfs-backed temp tree); the **flock mutual-exclusion contract** (FINDING 2: lane assignment
serialized under the short flock; boots concurrent outside); the **per-PID `wait` discipline**
(bare `wait` returns 0 always + masks failures); the **per-job-result-file collection pattern**
(race-free; read by parent after `wait`); the **distinctness assertion** (associative-array
dedup with a non-zero/non-null guard so a provisional `port=0` can't masquerade as valid); the
**port-allocation TOCTOU** (mitigated by the ~0.3s stagger + write-port-before-launch); the
**set -e hazards** (`pool_acquire_locked`/`pool_lease_field`/`pool_boot_lane` rc 1 abort bare
→ guard each; `(( ))` only inside `if`; split captures for SC2155); the **scoped-pgrep cleanup
assertion** (`pgrep -f -- "user-data-dir=$ROOT"` — never false-positives the operator's Chrome);
host-verified prerequisites (real master non-empty 45 entries on btrfs; `google-chrome-stable`
in PATH; real `agent-browser` symlink present; `test/validate.sh` LANDED 13585 bytes); and
copy-pasteable Level-2/3 tests.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.18 (Testing & validation — THE concurrency contract: "N parallel agents (distinct
        owner PIDs via override) must each get a distinct lane; assert no two share a lane and
        all release cleanly with no leftover dirs/processes"; + "every test must call
        release/reap and assert the ephemeral dir + Chrome process group are gone"; +
        AGENT_CHROME_HEADLESS=1 for unattended). §1.3 (goals 2+3: "No two agents ever share a
        Chrome"; "Mutual exclusion — held lanes can't be grabbed"). §2.7 (master is read-only;
        concurrent reflink copies safe). §2.8 (lease schema — owner.pid/port/chrome_pid).
  pattern: §2.18's harness IS this test's contract; §1.3.2/§1.3.3 ARE the assertions.
  gotcha: §2.18 — owner resolution needs a pi ancestor; the harness uses the override +
        spawn_sim_owner to simulate real "pi" agents (the override sets identity, NOT the
        kernel process).

# The TEST FRAMEWORK this test sources (LANDED by P1.M9.T1.S1 — the contract for every helper)
- file: test/validate.sh
  why: defines _fail, the 5 assertions (assert_eq/assert_lane_exists/assert_lane_gone/
        assert_no_dir/assert_no_chrome), spawn_sim_owner (the `pi`-comm owner engine — REQUIRED
        for liveness), setup (hermetic mktemp isolation + ONE sim owner + AGENT_CHROME_HEADLESS=1),
        teardown (release all as subprocess + kill ABPOOL_CUR_OWNER), run_test (subshell-isolated
        body), abpool_run_suite (enumerate test_* + rc 1 on any fail). ALSO sources lib/pool.sh
        (so concurrency.sh does NOT re-source it).
  pattern: concurrency.sh sources validate.sh → inherits ALL helpers + the lib. It adds test_*
        bodies + 3 private helpers (_concurrency_setup_master, _concurrency_run_one_lane,
        _assert_all_distinct_and_nonzero).
  gotcha: validate.sh's setup() makes an EMPTY temp master → pool_check_master pool_die's on a
        real boot → _concurrency_setup_master overrides AGENT_CHROME_MASTER to a real master.
        setup() spawns ONE sim owner → the test body spawns N-1 MORE (owner_pids[0] = setup's).

# This task's own research (THE factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M9T2S1/research/codebase-concurrency-facts.md
  why: §1 the EXACT lib function reference (pool_acquire_locked @2043 flock idiom;
        _pool_acquire_critical_section @1966 reap+reuse+choose+claim; pool_find_free_lane @1101
        lowest-free-N; pool_boot_lane @2185 copy+port+launch+connect; pool_chrome_launch @1471
        setsid pgid==pid; pool_wait_cdp @1570 60×0.5s=30s budget; pool_find_free_port @1376
        OUTSIDE the flock; pool_release_lane @2438 idempotent rc 0; pool_admin_release @3830
        release all; pool_owner_resolve @478 TEST MODE; pool_owner_alive @616 REAL /proc comm;
        pool_lanes_list @967 rc 0 always; pool_lease_field @884 rc 0/1; pool_lease_write @682
        schema). §2 the EXACT lease JSON schema (owner.pid/port/chrome_pid/chrome_pgid/session/
        connected — session is TOP-LEVEL, not nested). §5 the framework API (verbatim). §6
        host-verified master/real-bin presence. §7 leftover dirs irrelevant under isolation.
        Questions A-G answered (flock guarantees distinct lanes; boot after lock; release
        idempotent; cleanup assertions; real Chrome required; concurrent reflink safe; port
        TOCTOU outside flock).
  pattern: §1 IS the lib surface the test drives; §3.A IS _concurrency_run_one_lane; §3.C IS
        the distinctness assertion block; §3.D IS the cleanup block.
  gotcha: §7.E — the wrapper exec's into the real agent-browser (may not exit) → the test drives
        acquire+boot DIRECTLY, not via the wrapper. §7.F — setup spawns ONE owner; the body
        spawns N-1 MORE.

- file: plan/001_0f759fe2777c/P1M9T2S1/research/internal-research.md
  why: §1 the concurrency contract (flock serializes lane assignment; FINDING 2; boots
        concurrent outside the lock). §2 the boot sequence + timing (~1-3s/lane; copy ~17ms
        reflink; CDP ~0.5s observed / 30s budget). §3 the release/cleanup contract (close →
        kill pgroup → rm dir → rm lease; idempotent rc 0). §4 the EXACT cleanup assertions
        (no lanes/*.json, no active/<N>/, no pgrep -f user-data-dir=$ROOT). §5 real-Chrome
        requirements (master + headless + btrfs; the framework's empty-master gap). §6 the
        framework API verbatim. §7 gotchas (comm-liveness; port TOCTOU outside flock; concurrent
        reflink safe; SC2155; rc-1 guards; kill -0 trap; fork→exec settle; one-owner-one-lane;
        release-as-subprocess; distinctness fields).
  pattern: §1.A IS the guarantee the test proves; §2 IS the timing the per-PID wait absorbs;
        §4 IS the cleanup block; §5 IS _concurrency_setup_master.
  gotcha: §7.G2 — pool_find_free_port runs OUTSIDE the flock → narrow TOCTOU; mitigated by the
        ~0.3s stagger + write-port-before-launch.

- file: plan/001_0f759fe2777c/P1M9T2S1/research/external-research.md
  why: §1-2 the parallel-spawn pattern (`( export VAR; … ) &` + `$!` + per-PID `wait`;
        subshell-scoped export → N distinct owner PIDs with zero cross-talk). §3 the
        tmp-file-per-job result collection (race-free; mapfile read). §4 the per-PID wait
        discipline (bare `wait` returns 0 always → masks failures). §5 flock auto-release on
        subshell exit (the SUT's lane-serialization mechanism). §6 the distinctness idiom
        (associative-array dedup + the zero/empty guard). §7 the scoped-pgrep cleanup. §8 the
        timeout-wrapping pattern (optional; the per-PID wait + pool_wait_cdp's own 30s budget
        usually suffice). §10 the pitfalls table (mapfile not arr=($()); (( )) only in if;
        SC2155; kill tracked PIDs in a trap; ${arr[@]:-}).
  pattern: §(1) IS the parallel loop; §(3) IS the result-file collection; §(4) IS the join;
        §(6) IS _assert_all_distinct_and_nonzero; §(7) IS assert_no_chrome.
  gotcha: §1.2 — bare `wait` always returns 0 → the test MUST wait per-PID. §10.g — `$$` is the
        parent PID in a subshell; use $BASHPID if a subshell needs its own PID (NOT needed here
        — the test passes an EXPLICIT owner_pid per subshell).

# The LANDED lib functions the test drives (READ the docstrings — they are the contracts)
- file: lib/pool.sh
  why: pool_owner_resolve @478 (TEST MODE reads AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME; comm
        forced "pi"). pool_acquire_locked @2043 (`( flock 9; _pool_acquire_critical_section )
        9>"$POOL_LOCK_FILE"`; echoes lane N + rc 0; rc 1 on exhaustion → GUARD). pool_boot_lane
        @2185 (copy+port+launch+connect; rc 1 on recoverable failure having cleaned up → GUARD).
        pool_lease_field @884 (rc 0 echoes value / rc 1 missing → GUARD with `|| true` in $(…)).
        pool_lanes_list @967 (rc 0 ALWAYS; mapfile-safe). pool_release_lane @2438 (rc 0 always;
        idempotent). pool_wait_cdp @1570 (60×0.5s=30s budget — the per-lane boot latency the
        per-PID wait absorbs). pool_chrome_launch @1471 (setsid → pgid==pid; --user-data-dir is
        what assert_no_chrome's pgrep matches). _pool_get_starttime @404 (the sim owner's real
        starttime). pool_owner_alive @616 (THE comm-liveness check — why spawn_sim_owner is
        required).
  pattern: _concurrency_run_one_lane composes pool_owner_resolve + pool_acquire_locked +
        pool_boot_lane; the cleanup block composes pool_lanes_list + assert_lane_gone +
        assert_no_chrome.
  gotcha: pool_acquire_locked / pool_boot_lane / pool_lease_field all return rc 1 on a legitimate
        "not found / failed / missing" → bare calls ABORT under set -e → GUARD each (`if ! …` or
        `|| true` inside $(…)). pool_lanes_list rc 0 always → bare mapfile is safe.

# The framework PRP (the contract concurrency.sh consumes — READ to confirm the helper API)
- file: plan/001_0f759fe2777c/P1M9T1S1/PRP.md
  why: the verbatim test/validate.sh body (the helpers + setup/teardown/runner this test sources).
        Confirms: setup exports ONE AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME + AGENT_CHROME_HEADLESS=1
        + overrides HOME/STATE/EPHEMERAL/MASTER (MASTER to an EMPTY temp dir → the gap
        _concurrency_setup_master fixes). teardown runs `"$ABPOOL_ADMIN" release all` as a
        subprocess + kills ABPOOL_CUR_OWNER. spawn_sim_owner returns a settled `pi`-comm PID +
        appends its bin dir to ABPOOL_SIM_BINS (trap removes it). The BASH_SOURCE source-vs-execute
        gate (validate.sh does NOT run its selftest when sourced → concurrency.sh's test_* are
        the only functions abpool_run_suite sees).
  pattern: concurrency.sh MIRRORS validate.sh's bootstrap (readlink -f → dirname → cd && pwd) +
        its BASH_SOURCE gate.
  gotcha: validate.sh's selftest_ functions are NOT prefixed test_ → abpool_run_suite test_ in
        concurrency.sh runs ONLY concurrency.sh's test_* (no collision with the framework's
        selftests).

# Sibling PRPs (the pattern to mirror — NEW file + chmod + shellcheck-SC1091-OK)
- file: plan/001_0f759fe2777c/P1M8T1S1/PRP.md
  why: install.sh (LANDED) — the "new executable at a fixed path, chmod 0755, bash -n +
        shellcheck clean (SC1091 info OK), hermetic Level-2 test" pattern. concurrency.sh mirrors
        it for structure + validation.
  pattern: the verbatim-body + design-decisions + Level-2-hermetic-test structure.

# Architecture (host facts + the flock contract)
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (the short-flock acquire split: claim under flock, boot AFTER releasing — no
        launch/copy/wait inside the lock — THIS is what guarantees distinct lanes + concurrent
        boots). FINDING 6 (setsid → pgid==pid). FINDING 7 (atomic lease write — the claim is
        visible to the next acquirer). FINDING 8 (test-hook overrides — AGENT_BROWSER_POOL_OWNER_PID
        + _STARTTIME simulate distinct agents).
  pattern: FINDING 2 IS the concurrency guarantee the test proves; FINDING 8 IS the override
        mechanism the test exploits.
  gotcha: FINDING 8 sets the IDENTITY; the REAL process must still have comm=="pi" for liveness
        (spawn_sim_owner). FINDING 2 means port allocation (pool_find_free_port) is OUTSIDE the
        flock → narrow TOCTOU (mitigated by stagger + write-before-launch).

# External primary sources (URLs — version-stable)
- url: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-wait
  why: the `wait` builtin semantics — bare `wait` (no args) "return[s] … zero" (masks failures);
        `wait <pid>` returns that job's exit status; 127 on unknown pid. The test's per-PID
        `wait "$p" || fail=1` loop is MANDATORY (bare `wait` would mask a failing subshell).
  critical: bare `wait` always returns 0 → cannot detect a failing acquire+boot subshell.
- url: https://www.gnu.org/software/bash/manual/html_node/Environment.html
  why: a subshell-scoped `( export VAR=val; … ) &` sets VAR for ONLY that subshell + its
        children (env copied at fork → parent + siblings unaffected). This is how N parallel
        subshells get N distinct AGENT_BROWSER_POOL_OWNER_PID with zero cross-talk.
  critical: the export inside `( )` does NOT leak to the parent or sibling subshells.
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "set -e is not a panacea" — commands in if/|| conditions are errexit-exempt → the per-PID
        `wait "$p" || fail=1` and the `if ! N="$(pool_acquire_locked)"` guards keep rc-1 returns
        non-fatal to the harness.
  critical: a bare `pool_acquire_locked` / `pool_boot_lane` / `pool_lease_field` returning rc 1
        ABORTS the test under set -e → GUARD each.
- url: https://linux.die.net/man/1/flock
  why: the canonical `( flock 9; critical_section ) 9>lockfile` idiom + auto-release on fd close
        (even on SIGKILL) — the SUT's lane-serialization mechanism the test validates.
  critical: flock auto-releases on subshell exit → the lock can NEVER be held by a dead acquirer.
- url: https://man7.org/linux/man-pages/man1/pgrep.1.html
  why: -f matches the FULL command line (how assert_no_chrome scopes to --user-data-dir=$ROOT);
        rc 1 on no-match (must be an if-condition, not a bare statement); -c is the wrong
        predicate for "any Chrome left" (one Chrome = many processes).
  critical: pgrep rc 1 (no match) is the GOOD case → it MUST be the `if` condition (errexit-exempt).
- url: https://www.shellcheck.net/wiki/SC2155
  why: `local x="$(…)"` masks failure (local returns 0). The test uses split captures
        (`local x; x="$(…)"`) — see spawn_sim_owner's pid/st/comm in the framework + the
        owner_pids/owner_sts loops here.
```

### Current Codebase tree

After **M1–M8** landed + **M9.T1.S1** (LANDED in parallel: `test/validate.sh`, 13585 bytes,
executable) the repo root has `bin/{agent-browser,agent-browser-pool,.gitkeep}`,
`lib/pool.sh` (4302 lines), `install.sh`, `test/{validate.sh,.gitkeep}`, `PRD.md`,
`README.md`, `.gitignore`. **`test/concurrency.sh` does NOT exist yet. THIS task creates it:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md                             # install section synced by M10.T1.S1 (NOT this task)
├── install.sh                            # M8.T1.S1 (LANDED) — UNCHANGED
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # M6.T3.S2 (LANDED) — UNCHANGED (ABPOOL_WRAPPER target; NOT driven by this test)
│   └── agent-browser-pool                # M7.T5.S1 (LANDED) — UNCHANGED (ABPOOL_ADMIN; teardown + cleanup invoke `release all`)
├── lib/
│   └── pool.sh                           # UNCHANGED (SOURCED transitively via validate.sh). 4302 lines.
├── test/
│   ├── .gitkeep                          # RETAINED
│   └── validate.sh                       # M9.T1.S1 (LANDED) — SOURCED by concurrency.sh (NOT edited)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M9T2S1/
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-concurrency-facts,internal-research,external-research}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── test/
    └── concurrency.sh                    # NEW (chmod 0755): the CONCURRENCY test. Sources
                                          #   test/validate.sh (LANDED framework). Defines
                                          #   test_n_agents_get_n_distinct_lanes (N=3 real
                                          #   headless Chrome boots under parallel contention;
                                          #   asserts distinct owner.pid/port/chrome_pid + full
                                          #   cleanup) + test_n_provisional_lanes_are_distinct
                                          #   (N=4 Chrome-free locking sanity) + 3 private
                                          #   helpers. Boots REAL Chrome per lane.
```

**File responsibilities**:
- `test/concurrency.sh` — the concurrency + mutual-exclusion test. Owns NO pooling logic: it
  drives the LANDED lib's `pool_owner_resolve` / `pool_acquire_locked` / `pool_boot_lane` /
  `pool_lanes_list` / `pool_lease_field` + invokes `bin/agent-browser-pool release all`. It
  composes the LANDED framework's helpers (`spawn_sim_owner`, `setup`/`teardown`, the 5
  assertions, `run_test`/`abpool_run_suite`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the direct-lib-call seam): the wrapper (bin/agent-browser → pool_wrapper_main
#   lib/pool.sh:3451) TERMINATES via `exec "$POOL_REAL_BIN" …` (process replacement). A
#   wrapper-driven `open` test (`"$ABPOOL_WRAPPER" open https://example.com`) would exec into
#   the real agent-browser, which for `open` does not reliably exit → `wait` hangs. Driving
#   pool_owner_resolve + pool_acquire_locked + pool_boot_lane DIRECTLY in each subshell
#   exercises the EXACT same concurrency-critical code path (the flock + the boot) WITHOUT the
#   terminal exec → `wait` joins cleanly. This is the correct test boundary for a concurrency
#   test (it tests the SUT's locking, not the upstream `open` behavior). (research §codebase-7.E.)

# CRITICAL (the comm-liveness coupling, ×N): pool_owner_alive (lib/pool.sh:616) reads the REAL
#   /proc/<pid>/comm and requires "pi". The override hook sets the lease's owner IDENTITY; it
#   does NOT fake the kernel-visible process. So each of the N parallel agents is LIVE (and thus
#   holds its lane without being reaped mid-test) ONLY if its AGENT_BROWSER_POOL_OWNER_PID points
#   at a real "pi"-comm process. spawn_sim_owner (HOST-VERIFIED) is the engine; it MUST be called
#   N times (setup spawns ONE → the body spawns N-1 MORE). Without this, the lanes look STALE →
#   the acquire's reap loop releases them → the test sees <N lanes and fails (or passes vacuously).
#   (research §internal-7.G1, §codebase-Q.F.)

# CRITICAL (the hermetic-real-Chrome gap): validate.sh's setup() exports AGENT_CHROME_MASTER to
#   an EMPTY temp dir ($ABPOOL_TEST_ROOT/master, just mkdir -p'd). pool_check_master
#   (lib/pool.sh:266) pool_die's on an empty/missing master → pool_boot_lane would fail for every
#   lane. _concurrency_setup_master overrides AGENT_CHROME_MASTER to a REAL non-empty master (the
#   operator's real ~/.agent-chrome-profiles/master-profile — HOST-VERIFIED present, 45 entries,
#   on btrfs — or a minimal built master as fallback) + re-runs pool_config_init. The master is
#   READ-ONLY (PRD §2.7) → safe to share; N concurrent reflink copies are CoW-safe (btrfs
#   refcounts the shared blocks). (research §internal-§5.3, §codebase-§7.)

# CRITICAL (bare `wait` masks failures): `wait` with NO args "return[s] … zero" (bash manual) —
#   a crashing acquire+boot subshell would pass silently. The test MUST join per-PID:
#   `for p in "${bg_pids[@]}"; do wait "$p" || fail=1; done`. The `|| fail=1` is errexit-exempt.
#   (research §external-§4.)

# CRITICAL (subshell-scoped export for distinct owner PIDs): `( export
#   AGENT_BROWSER_POOL_OWNER_PID="$pid"; … ) &` sets the var for ONLY that subshell + its
#   children (env copied at fork). Parent + sibling subshells are UNAFFECTED → N parallel
#   subshells get N distinct owner PIDs with zero cross-talk. (research §external-§2.)

# CRITICAL (set -e hazards on rc-1 lib calls): pool_acquire_locked (rc 1 on exhaustion),
#   pool_boot_lane (rc 1 on recoverable failure), pool_lease_field (rc 1 on missing/corrupt),
#   pool_lease_exists (rc 1 on missing) ALL abort a bare call under set -e. GUARD each:
#   `if ! N="$(pool_acquire_locked)"; then …`, `if ! pool_boot_lane "$N"; then …`,
#   `fport="$(pool_lease_field "$ln" port 2>/dev/null)" || fport=""` (the || true INSIDE $(…)).
#   pool_lanes_list + pool_release_lane are rc 0 ALWAYS → safe bare. (research §codebase-Q.G,
#   §internal-§7.G5.)

# CRITICAL (the port-allocation TOCTOU): pool_find_free_port (lib/pool.sh:1376) runs OUTSIDE the
#   flock (FINDING 2). Two concurrent boots CAN both pick the same port in a narrow window.
#   Mitigations in the SUT: pool_boot_lane writes the port to the lease BEFORE launch (so later
#   find_free_port calls see it claimed). Mitigation in the test: a ~0.3s stagger between
#   subshell launches narrows the window further. If the test sees spurious pool_die on Chrome
#   instant-exit, suspect a port collision → increase the stagger. (research §internal-§7.G2.)

# GOTCHA (one owner ≤ one lane — PRD §2.8): pool_lease_find_mine (lib/pool.sh:1003) finds an
#   existing valid lease for the current owner BEFORE acquire. If two "agents" shared the SAME
#   AGENT_BROWSER_POOL_OWNER_PID, the second would REUSE the first's lane (not get a new one) →
#   the test would see <N lanes. The test gives each subshell a DISTINCT sim-owner PID → each
#   gets a distinct lane. (research §internal-§7.G8.)

# GOTCHA (the fork→exec settle in spawn_sim_owner): after `"$bin" "$dur" &, the child EXISTS but
#   has NOT yet execve'd → its /proc/comm is still "bash" for a few hundred µs. spawn_sim_owner
#   POLLS /proc/$pid/comm until == "pi" before returning. The test reads the sim owner's
#   starttime via _pool_get_starttime AFTER spawn_sim_owner returns (settled) — never re-reads it
#   prematurely. (research §internal-§7.G7.)

# GOTCHA (assert_no_chrome is SCOPED): pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT" matches
#   the flag pool_chrome_launch writes → scopes to POOL chrome only → does NOT false-positive the
#   operator's daily-driver Chrome (whose --user-data-dir is ~/.config/google-chrome). pgrep rc 1
#   (no match) is the GOOD case → it is the `if` CONDITION (errexit-exempt). Use the BOOLEAN form
#   (pgrep >/dev/null), never `pgrep -c` (one Chrome = many processes). (research §external-§7.)

# GOTCHA (PASS/FAIL counters + (( )) discipline): the framework's run_test uses `ABPOOL_PASS=$((…+1))`
#   (expansion, always errexit-safe); NEVER `(( ABPOOL_PASS++ ))` (aborts @0). The test's own
#   `(( fail != 0 ))` is inside `if` (exempt). `_assert_all_distinct_and_nonzero` returns 0/1 and
#   is called inside `if ! …; then …; return 1; fi` (the ! inverts + the if exempts). (research
#   §external-§10.b, §framework §3.3.)

# GOTCHA (SC2155 — split every $(…) capture): `local x="$(…)"` masks failure (local returns 0).
#   The test uses `local pid; pid="$(spawn_sim_owner)"` + `local st; st="$(_pool_get_starttime …)"`.
#   The framework's spawn_sim_owner already follows this. (research §external-§10.c.)

# GOTCHA (shellcheck SC1091 (info) is EXPECTED + ACCEPTED): `shellcheck -s bash test/concurrency.sh`
#   emits ONE info: SC1091 on the dynamic `source ./validate.sh` line. This is IDENTICAL to
#   test/validate.sh, bin/agent-browser, bin/agent-browser-pool, AND install.sh (host-verified) —
#   the accepted codebase convention. Validation passes if there are NO error/warning-severity
#   issues. Equivalently: `shellcheck --exclude=SC1091 -s bash test/concurrency.sh` → clean.

# GOTCHA (PRD §2.2: never pass bare ~ to a subprocess): the test resolves $HOME (exported to an
#   absolute mktemp path by setup) + the repo dir (cd && pwd → absolute); _concurrency_setup_master
#   resolves the real master via `getent passwd` (absolute). Never emits a bare ~.

# GOTCHA (the second test is Chrome-free by design): test_n_provisional_lanes_are_distinct acquires
#   N PROVISIONAL lanes (port=0, NO boot) in parallel + asserts distinct lane numbers + owner.pid.
#   This is a FAST (sub-second) regression gate for the LOCKING itself, independent of Chrome /
#   master / btrfs. If a host lacks Chrome, this test still proves mutual exclusion at the
#   lane-allocation layer. (Its cleanup still runs release all + asserts no leases remain — but
#   provisional lanes have no Chrome/dir to assert gone beyond the lease file.)
```

## Implementation Blueprint

### Data models and structure

**None NEW.** This task CONSUMES the LANDED lease JSON schema (PRD §2.8): each
`$POOL_LANES_DIR/<N>.json` has top-level `lane`, `ephemeral_dir`, `port`, `session`,
`chrome_pid`, `chrome_pgid`, `connected`, `acquired_at`, `last_seen_at` + a nested `owner`
object `{pid, comm, starttime, cwd}`. The test READS `owner.pid`, `port`, `chrome_pid` via
`pool_lease_field` (nested-path-aware). It introduces NO on-disk layout change beyond the new
`test/concurrency.sh` file + the per-job result files (written under `$ABPOOL_TEST_ROOT/results/`,
removed by the framework's EXIT trap). Module-level state is the framework's `ABPOOL_*` globals
+ the lib's `POOL_*` globals (resolved by `pool_config_init`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + the LANDED surfaces concurrency.sh consumes
  - RUN: test -f test/validate.sh && test -x test/validate.sh && echo "OK framework landed"
  - EXPECT: OK (test/validate.sh from P1.M9.T1.S1 — LANDED in parallel; host-verified 13585 bytes).
  - RUN (confirm this task is greenfield — NO existing concurrency.sh):
        test -e test/concurrency.sh && echo "STOP: concurrency.sh exists" || echo "OK: concurrency.sh greenfield"
  - EXPECT: OK: concurrency.sh greenfield.
  - RUN (confirm the framework defines the helpers + runner concurrency.sh sources):
        bash -c 'set -euo pipefail; source test/validate.sh; \
          for f in _fail assert_eq assert_lane_exists assert_lane_gone assert_no_dir assert_no_chrome \
                   spawn_sim_owner setup teardown run_test abpool_run_suite; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; echo "OK framework helpers defined"'
  - EXPECT: OK framework helpers defined (validate.sh LANDED).
  - RUN (confirm the lib functions concurrency.sh drives are defined — sourced transitively):
        bash -c 'set -euo pipefail; source test/validate.sh; \
          for f in pool_owner_resolve pool_acquire_locked pool_boot_lane pool_lanes_list \
                   pool_lease_field pool_release_lane _pool_get_starttime pool_config_init pool_state_init; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; echo "OK lib fns defined"'
  - EXPECT: OK lib fns defined (all LANDED).
  - RUN (confirm real-Chrome prerequisites — required for test_n_agents_get_n_distinct_lanes):
        test -d ~/.agent-chrome-profiles/master-profile && \
          [[ -n "$(ls -A ~/.agent-chrome-profiles/master-profile 2>/dev/null)" ]] && echo "OK real master non-empty"
        [[ "$(stat -f -c %T ~/.agent-chrome-profiles/master-profile)" == "btrfs" ]] && echo "OK btrfs"
        command -v google-chrome-stable >/dev/null && echo "OK chrome in PATH"
        test -e ~/.local/bin/agent-browser && echo "OK real agent-browser present"
  - EXPECT: all OK (host-verified 2026-07-13: master 45 entries, btrfs, chrome at /usr/bin/google-chrome-stable,
        agent-browser symlink present). If the real master is ABSENT, _concurrency_setup_master builds a
        minimal one (strategy B) — the test still runs.
  - RUN (confirm the release wiring the cleanup uses):
        grep -q 'release)' bin/agent-browser-pool && grep -q 'pool_admin_release' lib/pool.sh && echo "OK release wired"
  - EXPECT: release wired (pool_admin_release @3830).
  - RUN (confirm shellcheck SC1091 is the ONLY emission on the LANDED validate.sh — the convention):
        shellcheck -s bash test/validate.sh 2>&1 | grep -E 'SC[0-9]+' | sort -u
  - EXPECT: only SC1091 (info). concurrency.sh's source line will emit the same.
  - RUN: bash -n test/validate.sh && echo "OK framework syntax (baseline preserved)"
  - EXPECT: OK (this task only SOURCES validate.sh — must not break existing syntax).

Task 1: CREATE test/concurrency.sh (the verbatim body, executable)
  - PLACEMENT: test/concurrency.sh (NEW file in test/ — alongside the LANDED validate.sh + .gitkeep).
  - IMPLEMENT: paste the verbatim body from the "What → The test/concurrency.sh body" section above,
        EXACTLY (shebang + header + set -euo pipefail + CONCURRENCY_DIR resolution + source
        validate.sh + _concurrency_setup_master + _concurrency_run_one_lane +
        _assert_all_distinct_and_nonzero + test_n_agents_get_n_distinct_lanes +
        test_n_provisional_lanes_are_distinct + the BASH_SOURCE gate). Then
        `chmod 0755 test/concurrency.sh`.
  - MAKE EXECUTABLE: chmod 0755 test/concurrency.sh
  - NOTE on the `# shellcheck source=./validate.sh` directive: it is a HINT for editors/`shellcheck
        -x`; `shellcheck -s bash test/concurrency.sh` (without -x) still emits SC1091 (info) on the
        dynamic source — that is ACCEPTED (matches validate.sh + bin/* + install.sh).
  - VERIFY (immediately after):
        bash -n test/concurrency.sh && echo "OK syntax"
        shellcheck -s bash test/concurrency.sh; echo "(SC1091 info on the source line is ACCEPTED — matches validate.sh + bin/* + install.sh)"
        test -x test/concurrency.sh && echo "OK executable"
        test -f test/.gitkeep && test -f test/validate.sh && echo "OK siblings retained"
        git status --short | grep -qvE '^\?\? test/concurrency\.sh$|plan/' && echo "STOP: unexpected change!" || echo "OK only test/concurrency.sh new"
  - EXPECT: OK syntax; shellcheck shows at most SC1091 (info); OK executable; siblings retained;
        git status shows ONLY test/concurrency.sh (untracked) outside plan/.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY `test/concurrency.sh` (new untracked) outside plan/ (plan/ changes are this PRP +
        research). lib/pool.sh, bin/*, install.sh, test/validate.sh, test/.gitignore, .gitignore,
        PRD.md, README.md, tasks.json, prd_snapshot.md UNCHANGED. NO second test file beyond
        concurrency.sh, NO edits to validate.sh.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe repo resolution (mirror test/validate.sh + bin/*):
CONCURRENCY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$CONCURRENCY_DIR/validate.sh"
#   readlink -f canonicalizes concurrency.sh (handles bash test/concurrency.sh, symlinks);
#   dirname → test/; cd && pwd → absolute; source the sibling validate.sh (which sources the lib).

# PATTERN — the parallel-spawn-and-per-PID-wait (a subshell failure NEVER passes silently):
declare -a bg_pids=()
for (( i = 0; i < N; i++ )); do
    (
        export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"   # subshell-scoped → siblings unaffected
        export AGENT_BROWSER_POOL_OWNER_STARTTIME="${owner_sts[$i]}"
        _concurrency_run_one_lane "${owner_pids[$i]}" "${owner_sts[$i]}" "$results_dir/lane-$i"
    ) &
    bg_pids+=("$!")
    sleep 0.3    # narrow the pool_find_free_port TOCTOU (research G2)
done
local fail=0
for pid in "${bg_pids[@]}"; do wait "$pid" || fail=1; done   # per-PID (bare `wait` returns 0 always)
if (( fail != 0 )); then _fail "..."; return 1; fi
#   `( export …; body ) &` gives N subshells N distinct owner PIDs with zero cross-talk.
#   `wait "$pid" || fail=1` is errexit-exempt (the || list) → harness survives any subshell exit.

# PATTERN — the per-agent body (direct lib calls; avoids the wrapper's terminal exec):
_concurrency_run_one_lane() {
    local owner_pid="$1" owner_st="$2" result_file="$3" N port
    pool_owner_resolve                                          # reads the override into POOL_OWNER_* globals
    if ! N="$(pool_acquire_locked)"; then exit 1; fi            # rc 1 on exhaustion → GUARD
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port="" # rc 1 on missing → || true INSIDE $(…)
    if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        if ! pool_boot_lane "$N"; then printf 'FAIL\n' >"$result_file"; exit 1; fi  # rc 1 → cleaned up
    fi
    printf '%s\n' "$N" >"$result_file"; exit 0
}
#   pool_owner_resolve FIRST: the subshell inherited setup's POOL_OWNER_* → re-resolve so THIS
#   agent's PID/starttime land in the globals before acquire writes the lease.

# PATTERN — distinctness with a non-zero guard (a provisional port=0 must NOT pass):
_assert_all_distinct_and_nonzero() {
    local v; local -A seen=()
    for v in "$@"; do
        [[ -n "$v" && "$v" != "0" && "$v" != "null" ]] || return 1
        [[ -z "${seen[$v]:-}" ]] || return 1
        seen["$v"]=1
    done
    return 0
}
#   Called inside `if ! _assert_all_distinct_and_nonzero "${vals[@]}"; then _fail "..."; return 1; fi`.

# PATTERN — hermetic real-Chrome master (the gap fix):
_concurrency_setup_master() {
    local real_home real_master
    real_home="$(getent passwd "${USER:-$(id -un)}" | cut -d: -f6)"   # REAL home (before setup clobbered HOME)
    real_master="$real_home/.agent-chrome-profiles/master-profile"
    if [[ -d "$real_master" ]] && [[ -n "$(ls -A "$real_master" 2>/dev/null)" ]]; then
        export AGENT_CHROME_MASTER="$real_master"   # strategy A: reuse real (read-only; reflink CoW safe)
    else
        local m="$ABPOOL_TEST_ROOT/master-real"; mkdir -p -- "$m/Default"   # strategy B: minimal
        printf '{"minimal":true}' >"$m/Preferences"; export AGENT_CHROME_MASTER="$m"
    fi
    pool_config_init; pool_state_init   # re-resolve POOL_MASTER_DIR against the override
}
#   The master is READ-ONLY (PRD §2.7); N concurrent reflink copies are CoW-safe.

# PATTERN — scoped cleanup assertion (does NOT false-positive the operator's Chrome):
"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true          # subprocess (pool_die can't kill harness)
mapfile -t held_after < <(pool_lanes_list)                   # rc 0 always → mapfile safe
assert_eq "0" "${#held_after[@]}" "no lanes remain"          # inside the subshell body (assert returns 1 → ends test)
for ln in "${lane_nums[@]}"; do assert_lane_gone "$ln"; done # no lease file AND no ephemeral dir
assert_no_chrome                                             # pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"

# GOTCHA — WHY direct lib calls (not the wrapper): the wrapper exec's into the real agent-browser
#   (may not exit for `open`) → wait hangs. Direct acquire+boot tests the SAME locking. (research §codebase-7.E.)
# GOTCHA — WHY N spawn_sim_owner calls (not 1): one owner ≤ one lane (PRD §2.8) → N agents need N
#   distinct LIVE pi-comm owners. (research §internal-7.G8.)
# GOTCHA — WHY per-PID wait (not bare): bare `wait` returns 0 always → masks failures. (research §external-4.)
# GOTCHA — WHY the non-zero guard in distinctness: a provisional port=0/chrome_pid=0 must NOT
#   masquerade as a valid distinct value. (research §external-6.)
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "test/concurrency.sh (NEW; chmod 0755; in test/ — alongside the LANDED validate.sh +
            retained .gitkeep). Verbatim body from the 'What' section."

FRAMEWORK (test/validate.sh — SOURCED, not edited):
  - sources: "concurrency.sh does 'source "$CONCURRENCY_DIR/validate.sh"' → joins validate.sh as the
            SECOND consumer (M9.T3/T4 will be the third/fourth). validate.sh sources lib/pool.sh,
            so concurrency.sh does NOT re-source it."
  - calls:   "spawn_sim_owner (N-1 extra owners); setup/teardown (via run_test); the 5 assertions;
            run_test/abpool_run_suite (the runner)."
  - consumes (env from setup): "AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME (owner #0); HOME +
            AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT + AGENT_CHROME_MASTER (overridden
            by _concurrency_setup_master) + AGENT_CHROME_HEADLESS=1."

LIBRARY (lib/pool.sh — SOURCED transitively via validate.sh, not edited):
  - calls: "pool_owner_resolve @478; pool_acquire_locked @2043; pool_boot_lane @2185;
            pool_lanes_list @967; pool_lease_field @884; _pool_get_starttime @404;
            pool_config_init @126; pool_state_init @202."
  - consumes (env): "AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME (pool_owner_resolve @478);
            AGENT_CHROME_MASTER (pool_config_init @135 → POOL_MASTER_DIR); AGENT_CHROME_HEADLESS
            (pool_config_init @172 → POOL_HEADLESS → pool_chrome_launch adds --headless=new)."

BINARIES (invoked as subprocesses by the cleanup):
  - invokes: "'$ABPOOL_ADMIN' release all (bin/agent-browser-pool → pool_admin_release @3830) in the
            test body + teardown, AS A SUBPROCESS (|| true) so a pool_die cannot kill the harness."
  - references: "ABPOOL_WRAPPER (bin/agent-browser) is NOT driven by this test (the wrapper exec's →
            the test drives acquire+boot directly). It remains the SUT for M9.T3/T4."

DOWNSTREAM CONTRACT (what M9.T3/T4 see):
  - pattern: "M9.T3/T4 are SIBLING files that ALSO source test/validate.sh + define their own test_*
            bodies + their own BASH_SOURCE gate. concurrency.sh does NOT export anything they depend
            on (its _concurrency_* + _assert_* helpers are private, underscore-prefixed)."

GITIGNORE:
  - no change: "no rule matches test/concurrency.sh (it is a tracked repo file). .gitignore is
            orchestrator-owned (M10.T1.S2)."

NO CHANGES TO:
  - lib/pool.sh (sourced transitively, not edited), test/validate.sh (sourced, not edited),
    bin/agent-browser (M6.T3.S2), bin/agent-browser-pool (M7.T5.S1), install.sh (M8.T1.S1),
    .gitignore, PRD.md / tasks.json / prd_snapshot.md (read-only), README.md (M10.T1.S1),
    test/.gitkeep (retained). NO second test file beyond concurrency.sh, NO docs (item §5: test
    code, no user-facing surface).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating test/concurrency.sh + chmod 0755 — fix before proceeding.
bash -n test/concurrency.sh && echo "OK bash -n"
shellcheck -s bash test/concurrency.sh; echo "(SC1091 info on the dynamic source line is ACCEPTED — matches test/validate.sh + bin/* + install.sh; host-verified)"
test -x test/concurrency.sh && echo "OK executable"
# Equivalently, a fully-silent shellcheck run (excludes the accepted info):
shellcheck --exclude=SC1091 -s bash test/concurrency.sh && echo "OK shellcheck (--exclude=SC1091)"
# Confirm ONLY test/concurrency.sh is new (no collateral edits):
git status --short | grep -vE 'plan/|^\?\? test/concurrency\.sh$' && echo "STOP: unexpected change" || echo "OK only test/concurrency.sh new"
# Expected: OK bash -n; shellcheck shows at most SC1091 (info); OK executable; only test/concurrency.sh new.
#   SC2155 does NOT fire (every $(…) capture is 2-statement: local x; x="$(…)" — the owner_pids/owner_sts
#   loops, the result-file reads via $(<…)). SC2086 satisfied by quoting "$CONCURRENCY_DIR/...",
#   "$ABPOOL_ADMIN", "${BASH_SOURCE[0]}", "${bg_pids[@]}", "${owner_pids[$i]}". The `(( ))` are inside
#   `for`/`if` (exempt). The `wait "$pid" || fail=1` is the || list (exempt).
```

### Level 2: Functional Tests (HERMETIC — real Chrome booted under the temp tree)

The concurrency test boots REAL headless Chrome (3 instances in test_n_agents_get_n_distinct_lanes).
It needs the real master profile + btrfs + google-chrome-stable (ALL host-verified present). The test
creates files/processes ONLY under the framework's `mktemp` temp root; the operator's real
`~/.local/state/agent-browser-pool/` + real daily-driver Chrome are NEVER touched (HOME + the pool
roots are overridden by setup; AGENT_CHROME_MASTER points at the READ-ONLY real master which is never
mutated/deleted).

```bash
# Run from the REPO ROOT.
# Case 1 — the full suite passes (the primary contract; boots 3 + 0 real Chromes):
bash test/concurrency.sh; echo "rc=$?"
# Expected: prints "== test_n_agents_get_n_distinct_lanes" + "   PASS" + "== test_n_provisional_lanes_are_distinct"
#   + "   PASS" + "2 passed, 0 failed"; rc=0. Wall time ~5-15s (3 parallel Chrome boots ~1-3s each +
#   the 4 fast provisional acquires). Verifies: 3 distinct lanes with distinct owner.pid/port/chrome_pid
#   (all >0), full cleanup (no leases/dirs/scoped Chrome), AND 4 distinct provisional lane numbers.

# Case 2 — isolation: the test must NOT touch the real pool state. Snapshot first:
before="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
bash test/concurrency.sh >/dev/null 2>&1
after="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && echo "OK: real state untouched" || echo "FAIL: real state changed ($before → $after)"
# Expected: OK (HOME + AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT overridden to a temp root
#   in setup; AGENT_CHROME_MASTER points at the read-only real master — never written).

# Case 3 — isolation: the test must NOT leave Chrome running against the REAL ephemeral root. Snapshot
#   the operator's real Chrome count (if any) before + after:
before_chrome="$(pgrep -fc 'user-data-dir=/home/.*/\.agent-chrome-profiles/active' 2>/dev/null || printf 0)"
bash test/concurrency.sh >/dev/null 2>&1
after_chrome="$(pgrep -fc 'user-data-dir=/home/.*/\.agent-chrome-profiles/active' 2>/dev/null || printf 0)"
[[ "$before_chrome" == "$after_chrome" ]] && echo "OK: no real-ephemeral Chrome touched" || echo "WARN: count changed ($before_chrome → $after_chrome)"
# Expected: OK (the test's Chrome runs under the TEMP ephemeral root; assert_no_chrome scoped to it).

# Case 4 — NEGATIVE: a forced failure must NOT kill the harness + must make the suite rc 1.
#   Write a throwaway wrapper that sources concurrency.sh's framework + defines a failing test_ +
#   runs the suite (simulates a regression where two lanes share a port):
cat >/tmp/neg_conc.sh <<'EOF'
set -euo pipefail
source test/validate.sh
# Inject a failing test BEFORE the suite runs (mimics a duplicate-port regression).
test_force_fail() {
    assert_eq "distinct" "DUPLICATE" "forced port collision"
}
if ! abpool_run_suite test_; then echo "OK: suite returned rc 1 on a failure"; exit 0; fi
echo "FAIL: suite should have returned rc 1"; exit 1
EOF
bash /tmp/neg_conc.sh; echo "rc=$?"; rm -f /tmp/neg_conc.sh
# Expected: "0 passed, 1 failed" + "OK: suite returned rc 1 on a failure"; rc=0 (the wrapper's exit).
#   Proves the framework's non-fatal runner + rc-1-on-fail contract holds for concurrency-style tests.

# Case 5 — no leftover processes/dirs after the suite (PRD §2.18 cleanup contract):
bash test/concurrency.sh >/dev/null 2>&1
# No lingering "pi"/sleep processes from the harness (the trap + teardown + the body's kill killed them):
n_pi="$(pgrep -fc 'abpool-pi' 2>/dev/null || printf 0)"; [[ "$n_pi" == "0" ]] && echo "OK: no leftover sim-owner bins running" || echo "WARN: $n_pi leftover"
# No pool Chrome under ANY temp ephemeral root (the test released all):
n_chrome="$(pgrep -fc 'user-data-dir=/tmp/abpool-test' 2>/dev/null || printf 0)"; [[ "$n_chrome" == "0" ]] && echo "OK: no leftover test Chrome" || echo "WARN: $n_chrome leftover"
# (The temp roots are removed by the framework's EXIT trap; verify: ls -d /tmp/abpool-test.* 2>/dev/null | wc -l == 0)
```

### Level 3: Integration Testing (the SUT's real mutual-exclusion behavior)

```bash
# Verify the test actually exercises the flock (not a mock): inspect the lease files mid-run by
# adding a temporary debug sleep, OR run the core assertion manually:
bash -c '
  set -euo pipefail
  source test/validate.sh
  # Manually drive 2 parallel acquires (mirroring _concurrency_run_one_lane) + inspect the leases.
  setup
  _concurrency_setup_master 2>/dev/null || true   # if concurrency.sh helpers are in scope
  pid1="$(spawn_sim_owner)"; st1="$(_pool_get_starttime "$pid1")"
  pid2="$(spawn_sim_owner)"; st2="$(_pool_get_starttime "$pid2")"
  (
    export AGENT_BROWSER_POOL_OWNER_PID="$pid1"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st1"
    pool_owner_resolve; N="$(pool_acquire_locked)"; pool_boot_lane "$N"; echo "agent1 → lane $N"
  ) &
  p1=$!
  (
    export AGENT_BROWSER_POOL_OWNER_PID="$pid2"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st2"
    pool_owner_resolve; N="$(pool_acquire_locked)"; pool_boot_lane "$N"; echo "agent2 → lane $N"
  ) &
  p2=$!
  wait "$p1"; wait "$p2"
  # The two lanes MUST be distinct (1 and 2) with distinct ports + chrome_pids:
  for n in $(pool_lanes_list); do
    printf "lane %s: owner.pid=%s port=%s chrome_pid=%s\n" "$n" \
      "$(pool_lease_field "$n" owner.pid)" "$(pool_lease_field "$n" port)" "$(pool_lease_field "$n" chrome_pid)"
  done
  "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
  teardown
'
# Expected: two lines "agent1 → lane 1" + "agent2 → lane 2" (or 2/1 — order nondeterministic but
#   DISTINCT), + the lease dump shows distinct owner.pid / port / chrome_pid (all >0). Proves the
#   flock serializes lane assignment + boots run concurrently.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Domain-specific: the concurrency test IS the domain validation (PRD §2.18). Additional checks:

# (a) Stress: bump N to 5 in test_n_agents_get_n_distinct_lanes temporarily + re-run (the contract
#   must hold for 3-5 per item §3a). Edit N=5, run bash test/concurrency.sh, expect PASS, revert.
#   (This is a MANUAL spot-check, NOT part of the landed test — N=3 is the default to keep CI fast.)

# (b) Port-uniqueness under contention: after the test passes, confirm no two held lanes ever shared
#   a port by checking the chrome-<N>.log files don't show EADDRINUSE:
bash test/concurrency.sh >/dev/null 2>&1 || true
# (The temp state is removed by the trap; to inspect logs, temporarily comment out the trap's rm in
#   a scratch copy. If EADDRINUSE appears, increase the ~0.3s stagger in the parallel loop.)

# (c) Confirm the real master is never mutated (read-only contract, PRD §2.7):
before_master_cksum="$(find ~/.agent-chrome-profiles/master-profile -type f -printf '%s %p\n' | sort | cksum)"
bash test/concurrency.sh >/dev/null 2>&1
after_master_cksum="$(find ~/.agent_chrome-profiles/master-profile -type f -printf '%s %p\n' 2>/dev/null | sort | cksum || true)"
# (If the find fails the 2nd time, the master moved — otherwise the cksums must match. reflink CoW
#   shares blocks; the master is never written.)
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n test/concurrency.sh` passes.
- [ ] `shellcheck -s bash test/concurrency.sh` → only SC1091 (info); NO error/warning severity.
- [ ] `bash test/concurrency.sh` → `2 passed, 0 failed`, rc 0 (boots 3 real headless Chromes).
- [ ] A forced failure → `abpool_run_suite` returns rc 1 (Case 4, Level 2).
- [ ] Isolation: the real `~/.local/state/agent-browser-pool/lanes/` count unchanged (Case 2).
- [ ] No leftover sim-owner processes / test Chrome / temp roots after the suite (Case 5).
- [ ] The real master profile is never mutated (Level 4c).

### Feature Validation

- [ ] `test_n_agents_get_n_distinct_lanes` (N=3): spawns 3 distinct sim owners; 3 parallel
      acquire+boot subshells; asserts exactly 3 lanes held with distinct owner.pid / port /
      chrome_pid (all >0); releases all; asserts no lanes / no dirs / no scoped Chrome.
- [ ] `test_n_provisional_lanes_are_distinct` (N=4): 4 parallel provisional acquires (no boot);
      asserts 4 distinct lane numbers + distinct owner.pid; releases all + asserts cleanup.
- [ ] `_concurrency_setup_master` overrides AGENT_CHROME_MASTER to a real non-empty master (or a
      minimal built one) + re-runs pool_config_init.
- [ ] `_concurrency_run_one_lane` drives pool_owner_resolve + pool_acquire_locked + pool_boot_lane
      directly (NOT the wrapper) — avoiding the terminal exec hang.
- [ ] The parallel loop uses subshell-scoped `export AGENT_BROWSER_POOL_OWNER_PID` (N distinct
      owners) + per-PID `wait` (not bare `wait`).
- [ ] The distinctness assertion rejects `0`/`null`/empty + duplicates (a provisional port=0
      cannot masquerade as valid).
- [ ] Cleanup is `"$ABPOOL_ADMIN" release all` as a subprocess (pool_die-safe) + the scoped
      `assert_no_chrome` (no false-positive on the operator's Chrome).

### Code Quality Validation

- [ ] Follows existing codebase patterns (`set -euo pipefail`, symlink-safe `${BASH_SOURCE[0]}`
      bootstrap mirroring test/validate.sh + bin/*, 2-statement `$(…)` captures, `(( ))` only
      inside `if`/`for`, per-PID `wait`, subprocess release).
- [ ] File placement matches the desired tree (`test/concurrency.sh`).
- [ ] Anti-patterns avoided (no wrapper-driven `open` that would hang on exec; no bare
      `pool_acquire_locked`/`pool_boot_lane`/`pool_lease_field` (all rc-1-guarded); no bare
      `wait` (per-PID instead); no `pgrep -c` for Chrome; no `local x="$(…)"`; no
      `(( PASS++ ))`; no inline pool_die-capable calls in the cleanup).
- [ ] The framework + lib are SOURCED not edited; `bin/*` + `install.sh` +
      `test/validate.sh` + `test/.gitkeep` unchanged.

### Documentation & Deployment

- [ ] Code is self-documenting (helper doc-comments explain the direct-lib-call seam, the
      comm-liveness coupling, the hermetic-real-Chrome gap, the per-PID wait, the port TOCTOU
      stagger, the non-zero distinctness guard).
- [ ] No user-facing docs (item §5: test code, no user-facing surface) — README sync is M10.T1.S1.
- [ ] No new env vars introduced (consumes LANDED overrides + the framework's setup exports only).

---

## Anti-Patterns to Avoid

- ❌ Don't drive the WRAPPER (`"$ABPOOL_WRAPPER" open …`) for the concurrency test — it `exec`s
  into the real agent-browser which may not exit → `wait` hangs. Drive `pool_owner_resolve` +
  `pool_acquire_locked` + `pool_boot_lane` DIRECTLY (same locking code path, no exec).
- ❌ Don't use ONE sim owner for N agents — one owner ≤ one lane (PRD §2.8); the 2nd-Nth would
  REUSE the 1st's lane. Call `spawn_sim_owner` N times (setup's 1 + N-1 more in the body).
- ❌ Don't rely on the env override ALONE to simulate a live agent — `pool_owner_alive` reads the
  REAL `/proc` comm; each agent's PID must point at a real `pi`-comm process (`spawn_sim_owner`).
- ❌ Don't use bare `wait` (returns 0 always → masks a failing acquire+boot subshell) — join
  per-PID: `for p in "${bg_pids[@]}"; do wait "$p" || fail=1; done`.
- ❌ Don't assert distinctness WITHOUT a non-zero guard — a provisional `port=0`/`chrome_pid=0`
  would pass a naive "all distinct" check on N zeros. `_assert_all_distinct_and_nonzero` rejects
  `0`/`null`/empty.
- ❌ Don't skip the real-master override — validate.sh's `setup()` makes an EMPTY temp master →
  `pool_check_master` pool_die's on boot. `_concurrency_setup_master` points at a real master.
- ❌ Don't call `pool_acquire_locked` / `pool_boot_lane` / `pool_lease_field` bare under set -e —
  they return rc 1 on a legitimate failure/missing → ABORT the test. GUARD each (`if ! …` or
  `|| true` inside `$(…)`).
- ❌ Don't use `pgrep -c` to assert "no Chrome left" — one Chrome is many processes. Use the
  boolean `pgrep -f -- "user-data-dir=$ROOT" >/dev/null` inside `if` (assert_no_chrome does this).
- ❌ Don't call `pool_admin_release` (or any pool_die-capable function) INLINE in the cleanup —
  run `"$ABPOOL_ADMIN" release all` as a SUBPROCESS so a config error can't exit the harness shell.
- ❌ Don't use `(( PASS++ ))` / bare `(( 0 ))` (aborts under set -e) — use `$(( ))` expansion or
  put `(( ))` inside `if`/`for`.
- ❌ Don't launch real Chrome against the operator's REAL ephemeral root — the test's
  `setup()` overrides `AGENT_CHROME_EPHEMERAL_ROOT` to a temp root; `AGENT_CHROME_MASTER` points
  at the read-only real master (never written). Hermetic isolation is mandatory.
- ❌ Don't create new patterns when existing ones work — mirror `test/validate.sh` for the
  bootstrap, shebang, chmod, shellcheck-SC1091-OK convention + the framework's helper API.
```
