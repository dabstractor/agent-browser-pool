# PRP — P1.M9.T1.S1: Test framework — override hooks, headless config, assertion helpers

---

## Goal

**Feature Goal**: Create **`test/validate.sh`** — a single, dependency-free bash test
**framework** (NO bats/shunit2; PRD §3 names exactly this one file). It sources the LANDED
`lib/pool.sh` and supplies everything the subsequent test subtasks (M9.T2/T3/T4) need to
drive the pool: (a) the **5 contract assertion helpers** `assert_eq`, `assert_lane_exists`,
`assert_lane_gone`, `assert_no_chrome`, `assert_no_dir`; (b) a **`spawn_sim_owner`** engine
that creates a REAL process whose `/proc/<pid>/comm == "pi"` (required — see Gotchas —
because `pool_owner_alive` reads the *real* `/proc`, not the override hook); (c)
**hermetic setup/teardown** (`mktemp` temp root + `trap` + override of `HOME` /
`AGENT_BROWSER_POOL_STATE` / `AGENT_CHROME_EPHEMERAL_ROOT` / `AGENT_CHROME_MASTER` so the
harness NEVER touches the operator's real pool state or daily-driver Chrome) that exports
`AGENT_CHROME_HEADLESS=1` + a unique `AGENT_BROWSER_POOL_OWNER_PID` +
`_OWNER_STARTTIME` per test; (d) a **`run_test NAME FN`** runner that wraps setup → body
(subshell-isolated) → teardown, counts PASS/FAIL, records failures; (e)
**`abpool_run_suite [PREFIX]`** that enumerates functions by prefix and **exits non-zero if
any test fails**. It is **dual-mode**: executed directly → runs a Chrome-free framework
**self-test** (`selftest_*`); sourced by downstream → defines helpers + runner so they add
`test_*` bodies and call `abpool_run_suite test_`. The framework does NOT itself run the
concurrency/release/reaper/Chrome-lifecycle tests — those are M9.T2/T3/T4.

**Deliverable**: ONE new file — **`test/validate.sh`** (replacing the empty
`test/.gitkeep`-occupied placeholder dir's only runtime artifact; `.gitkeep` is RETAINED),
`chmod 0755`. NO other file is created or modified. The self-test is **Chrome-free**
(no master/btrfs needed) so `bash test/validate.sh` runs in <1s in CI.

**Success Definition**:
- `test -f test/validate.sh && test -x test/validate.sh`; `bash -n test/validate.sh` passes;
  `shellcheck -s bash test/validate.sh` → only **SC1091 (info)** on the dynamic `source
  ../lib/pool.sh` line (the ACCEPTED codebase convention — identical to `bin/agent-browser`
  + `bin/agent-browser-pool` + `install.sh`), NO error/warning severity.
- `bash test/validate.sh` → prints `== selftest_*` lines + `7 passed, 0 failed` → **rc 0**.
  (Each self-test exercises one facet: assert_eq pass, assert_eq fail-is-non-fatal,
  assert_no_dir, empty-pool assert_lane_gone, lane-exists after writing a lease file,
  simulated-owner is a live `pi`, wrapper+admin are executable.)
- `source test/validate.sh` from a scratch script does NOT run the suite (the source-vs-
  execute gate holds); after defining a `test_*` body + calling `abpool_run_suite test_`,
  the scratch script → rc 0 on pass / rc 1 on a forced failure.
- A **negative** self-test (force `assert_eq` to mismatch inside a `test_*` body) → the
  harness survives, prints `1 passed, 1 failed`, and `abpool_run_suite` returns **rc 1**.
- Hermetic: the self-test creates files ONLY under a `mktemp -d` root; the operator's real
  `~/.local/state/agent-browser-pool/` + `~/.agent-chrome-profiles/active/` are untouched
  (verified by the self-test running with no master + no real chrome interference).
- `lib/pool.sh`, `bin/agent-browser`, `bin/agent-browser-pool`, `install.sh`, `.gitignore`,
  `PRD.md`, `README.md`, `tasks.json`, `test/.gitkeep` UNCHANGED (`git status --short`
  shows ONLY `test/validate.sh` new untracked, outside `plan/`).

## User Persona

**Target User**: The **test author** — the implementing agents for M9.T2 (concurrency),
M9.T3 (release/reaper/crash), M9.T4 (transparency checklist), and any human running the
suite. They need a ready-made set of assertions + a runner so they write test *bodies*, not
test *plumbing*.

**Use Case**: `bash test/validate.sh` (developer smoke-check the framework is wired); then
downstream `source test/validate.sh` + `test_concurrent_agents_get_distinct_lanes() { … }`
+ `abpool_run_suite test_`. Every test body uses `assert_lane_exists`, `assert_no_chrome`,
etc., and owns its own release+assert-cleanup (PRD §2.18), with `setup`/`teardown` as the
backstop.

**User Journey**: author opens `test/validate.sh`, reads the helper doc-comments → writes a
`test_*` in a new file that `source`s validate.sh → calls `spawn_sim_owner`-driven
`AGENT_BROWSER_POOL_OWNER_PID` overrides to simulate N agents → asserts lanes/chrome/dirs
→ `run_test`/`abpool_run_suite` tallies → non-zero exit on leak.

**Pain Points Addressed**: (1) Without `spawn_sim_owner`, an override PID pointing at any
real non-`pi` process (e.g. the harness's own `bash`) is treated as STALE by
`pool_owner_alive` → every "live agent" test would spuriously reap/acquire-a-new-lane and
fail mysteriously. (2) Without hermetic isolation, the harness clobbers the real pool state
and could `pkill` the operator's real Chrome. (3) Without a non-fatal runner, the first
failing `assert` would `exit` the whole harness. This framework solves all three.

## Why

- **This IS PRD §2.18's "Implement as narrowly-scoped test hooks" + §3's `test/validate.sh`.**
  §2.18 mandates the override hooks (`AGENT_BROWSER_POOL_OWNER_PID` + `_OWNER_STARTTIME` to
  "simulate distinct agents from distinct subshell PIDs"), `AGENT_CHROME_HEADLESS=1` for
  unattended runs, and "every test must call release/reap and assert cleanup". Those hooks
  ALREADY EXIST in the lib (LANDED, M2.T1.S1); this task builds the harness that *uses* them
  correctly + the assertion helpers + the runner that enforces the assert-cleanup contract.
- **It is the foundation of the entire P1.M9 milestone.** M9.T2/T3/T4 are ALL blocked on
  this framework — they `source test/validate.sh` and add `test_*` bodies. A thin/wrong
  framework fails all four subtasks; a correct one unblocks them.
- **The comm-liveness coupling is non-obvious and pivotal.** The override hook sets the
  *identity*; `pool_owner_alive` (lib/pool.sh:616) reads the *real* `/proc/<pid>/comm` and
  requires `"pi"`. So a "simulated agent" is only LIVE if its PID points at a real process
  whose comm is `pi`. The framework's `spawn_sim_owner` (copy `/usr/bin/sleep` to a file
  named `pi`, exec it — HOST-VERIFIED 2026-07-13) is the engine. Capturing this here is the
  difference between tests that pass and tests that mysteriously reap everything.
- **It must be hermetic + non-fatal.** PRD §2.18: "The main interactive `pi` is long-lived,
  so a lease it takes persists until explicit release — every test must release/reap and
  assert cleanup." A non-isolated harness would race that long-lived `pi`; a fatal runner
  would die on the first assert. The framework isolates via `mktemp` + `trap` + env
  overrides, and isolates test *bodies* via a subshell behind `||`.
- **It reuses the LANDED lib (DRY), not re-implementing pooling logic.** The assertions
  reference `$POOL_LANES_DIR` / `$POOL_EPHEMERAL_ROOT` (canonical, from `pool_config_init`);
  `spawn_sim_owner` uses `_pool_get_starttime` (LANDED, M2.T1.S2) to read the real starttime;
  `setup` calls `pool_config_init` + `pool_state_init`. The framework owns ONLY plumbing.

## What

User-visible behavior: **a runnable `test/validate.sh`** that (1) when executed directly,
runs a Chrome-free framework self-test and exits 0/1; (2) when sourced, exports a
ready-made helper/runner API for downstream test files. For verification (no Chrome / master
/ `pi` ancestor needed), the observable contract is: the 5 assertions behave correctly on
known states, the runner tallies + survives failures, isolation uses a temp root, and the
simulated owner is a live `pi` process (`pool_owner_alive` accepts it).

### The `test/validate.sh` body (verbatim contract — authoritative from item §3 + design D1–D9)

```bash
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
ABPOOL_TMP_ROOT=""            # the suite temp root (created by setup; removed by trap)
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
    "$bin" "$dur" &           # background; basename("pi") → comm=="pi" once execve lands
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
    [[ -n "${ABPOOL_TMP_ROOT:-}" && -d "${ABPOOL_TMP_ROOT:-}" ]] \
        && rm -rf -- "$ABPOOL_TMP_ROOT" 2>/dev/null || true
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
    ABPOOL_TMP_ROOT="$ABPOOL_TEST_ROOT"
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
    # The lib's liveness check must ACCEPT the simulated live owner (real "pi" + match).
    pool_owner_alive "$pid" "${POOL_OWNER_STARTTIME:-0}" "pi" \
        || { _fail "pool_owner_alive rejected the simulated live owner"; return 1; }
}

selftest_wrapper_and_admin_are_executable() {
    # Pre-flight the two binaries downstream tests invoke by ABSOLUTE PATH (PRD §2.17).
    # (Also consumes ABPOOL_WRAPPER/ABPOOL_ADMIN so they aren't shellcheck-SC2034-unused.)
    [[ -x "$ABPOOL_WRAPPER" ]] || { _fail "wrapper not executable: $ABPOOL_WRAPPER"; return 1; }
    [[ -x "$ABPOOL_ADMIN"   ]] || { _fail "admin not executable: $ABPOOL_ADMIN";   return 1; }
}

# --- source-vs-execute gate: run the self-test ONLY when executed directly. -----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! abpool_run_suite selftest_; then
        exit 1
    fi
fi
```
Then `chmod 0755 test/validate.sh`.

### Success Criteria

- [ ] `test/validate.sh` created (NEW; `chmod 0755`); shebang `#!/usr/bin/env bash` + `set -euo pipefail`.
- [ ] Resolves `ABPOOL_REPO` symlink-safely via `readlink -f "${BASH_SOURCE[0]}"` → `dirname` → `cd && pwd`
      → parent (mirrors `bin/*`); sources `"$ABPOOL_REPO/lib/pool.sh"`.
- [ ] The 5 contract helpers defined EXACTLY: `assert_eq EXPECTED ACTUAL [LABEL]`,
      `assert_lane_exists N` (`[[ -f "$POOL_LANES_DIR/$N.json" ]]`), `assert_lane_gone N`
      (lease file AND ephemeral dir both absent), `assert_no_dir PATH`, `assert_no_chrome [ROOT]`
      (`pgrep -f -- "user-data-dir=$ROOT"` as an `if` condition).
- [ ] `_fail MSG` prints to **stderr** + `return 1` (NEVER `exit`).
- [ ] `spawn_sim_owner [SECONDS]` copies `/usr/bin/sleep` to a `mktemp -d` file named `pi`,
      `chmod +x`, backgrounds it, captures `$!`, **polls `/proc/$pid/comm` until `== pi`**
      (fork→exec settle), tracks the bin dir for the trap, echoes the pid.
- [ ] `setup` uses `mktemp -d`; exports `HOME`, `AGENT_BROWSER_POOL_STATE`,
      `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_CHROME_MASTER` (all under the temp root),
      `AGENT_CHROME_HEADLESS=1`; calls `pool_config_init` + `pool_state_init`; spawns a sim
      owner; exports `AGENT_BROWSER_POOL_OWNER_PID` + `_OWNER_STARTTIME` (its real starttime).
- [ ] `teardown` runs `"$ABPOOL_ADMIN" release all` as a **subprocess** (`|| true`) + kills
      `ABPOOL_CUR_OWNER`.
- [ ] `trap _abpool_global_cleanup EXIT INT TERM` installed; the trap kills the current
      sim-owner + removes tracked bin dirs + the temp root (all `|| true`).
- [ ] `run_test NAME FN` runs setup → `( set -e; "$fn" ) || rc=$?` → teardown; tallies via
      `$(( ))` expansion; `(( rc == 0 ))` inside `if`.
- [ ] `abpool_run_suite [PREFIX]` enumerates `compgen -A function | grep "^$prefix"`, runs
      each, prints `N passed, N failed`, **returns rc 1 iff any failed**.
- [ ] Source-vs-execute gate: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then if ! abpool_run_suite
      selftest_; then exit 1; fi; fi` — runs the self-test ONLY when executed directly.
- [ ] The 7 `selftest_*` functions present (assert_eq pass / assert_eq fail-is-non-fatal /
      assert_no_dir absent / empty-pool lane_gone / lane_exists after write / sim-owner is live pi /
      wrapper+admin are executable).
- [ ] `bash test/validate.sh` → `7 passed, 0 failed`, **rc 0**.
- [ ] `bash -n test/validate.sh` passes; `shellcheck -s bash test/validate.sh` → only SC1091
      (info) on the `source ../lib/pool.sh` line, NO error/warning severity.
- [ ] `lib/pool.sh`, `bin/agent-browser`, `bin/agent-browser-pool`, `install.sh`, `.gitignore`,
      `PRD.md`, `README.md`, `tasks.json`, `test/.gitkeep` UNCHANGED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **verbatim `test/validate.sh` body** (item §3 +
design D1–D9); the **single-deliverable + `test/` placement** decision (PRD §3 layout); the
**comm-liveness coupling** (the pivotal gotcha: `pool_owner_alive` reads real `/proc` comm, so a
simulated owner MUST be a real `pi`-comm process — `spawn_sim_owner` does this, HOST-VERIFIED);
the **fork→exec settle gotcha** (read comm/starttime only after execve lands, else you get the
parent's comm — cost a verification run); the **hermetic-isolation mandate** (override HOME + 3
roots or you clobber real state / pkill real Chrome); the **subshell-isolation runner pattern**
(`( set -e; "$fn" ) || rc=$?` — a test failure never kills the harness; Greg's BashFAQ/105); the
**source-vs-execute gate** (dual-mode: run self-test when executed, define API when sourced); the
**teardown-as-subprocess decision** (a `pool_die` inside the admin tool would exit the harness
shell — invoke `release all` as `"$ABPOOL_ADMIN" … || true`); the **`pgrep` scoping** for
`assert_no_chrome` (`--user-data-dir=$ROOT` — never false-positives the operator's Chrome); the
**shellcheck SC1091 convention** (info on the dynamic source — the accepted codebase norm, identical
to `bin/*` + `install.sh`); the **set -e hazards** (bare `(( 0 ))` aborts; `pgrep` rc 1 aborts
unless an `if` condition; `local x=$(…)` masks failure per SC2155; `kill -0` conflates ESRCH/EPERM);
host-verified tooling (`sleep`/`pgrep`/`pkill`/`mktemp` all at /usr/bin; bash 5.x; no master profile
on this checkout → self-test is Chrome-free by design); and a copy-pasteable Level-2 test.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.18 (Testing & validation — the override hooks + HEADLESS + "every test must
        release/reap and assert cleanup" + "simulate distinct agents from distinct subshell
        PIDs"; the hooks "implement as narrowly-scoped test hooks"). §3/§h2.2 (repo layout:
        "test/validate.sh ← concurrency / mutual-exclusion / release harness"). §2.2 (hard rule:
        resolve every path; the harness resolves $HOME + repo dir, never a bare ~).
  pattern: §2.18's hooks ARE the env vars setup exports; §3's single validate.sh IS the deliverable.
  gotcha: §2.18 — owner resolution needs a pi ancestor; a plain terminal has none → the harness
        uses the override + spawn_sim_owner to simulate real "pi" agents.

# This task's own research (THE factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M9T1S1/research/test-framework-facts.md
  why: §1 codebase facts (the LANDED override hooks @lib/pool.sh:478; the comm-liveness coupling
        @616; how a lane is held/gone; teardown primitives; pool_die-exits-the-process; the
        isolation mandate; host tooling). §2 the HOST-VERIFIED "fake pi" trick + the fork→exec
        settle gotcha. §4 design D1–D9. §5 validation. §6 scope boundaries.
  pattern: §2 IS spawn_sim_owner; §4 D1–D9 ARE the validate.sh body; §5 IS the Level-2 test.
  gotcha: §2 — the override hook sets identity, NOT the kernel process; spawn_sim_owner is REQUIRED
        or every "live agent" test spuriously reaps.

- file: plan/001_0f759fe2777c/P1M9T1S1/research/external-research.md
  why: the raw subagent research — §1 (run_test/subshell/source-vs-execute patterns + git
        test-lib/sharness refs), §2 (comm=basename confirmation + the copy trick), §3 (starttime
        field 22 + the greedy-`)`-strip parser), §4 (set -e hazards: SC2155/SC2181/BashFAQ/105),
        §5 (hermetic mktemp/trap), §6 (pgrep -f scoping). Primary URLs in its Sources section.
  pattern: §1.2 + §1.3 ARE run_test + abpool_run_suite; §4 IS the non-fatal-asserts discipline.
  gotcha: §4.1 — `local x="$(…)"` MASKS failure (does not abort) — that's the bug; use 2-statement.

# The LANDED lib functions validate.sh sources / calls
- file: lib/pool.sh
  why: pool_config_init @126 (canonical POOL_STATE_DIR/POOL_LANES_DIR/POOL_EPHEMERAL_ROOT +
        config validation; honors AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT/
        AGENT_CHROME_MASTER/HOME). pool_state_init @202 (mkdir POOL_LANES_DIR + touch acquire.lock;
        idempotent). pool_owner_resolve @478 (TEST MODE: reads AGENT_BROWSER_POOL_OWNER_PID +
        _OWNER_STARTTIME; comm forced to "pi"). pool_owner_alive @616 (THE comm-liveness check:
        reads REAL /proc/<pid>/comm; default expected_comm="pi"). pool_lanes_list @967 (enumerates
        numeric *.json). pool_lease_exists @918 (rc 0 valid / rc 1 missing-or-corrupt — aborts
        bare under set -e). _pool_get_starttime @404 (greedy `)`-strip → field 20; used to read the
        sim owner's real starttime). pool_die @30 (exit 1 — why teardown is a subprocess). The
        chrome launch flag --user-data-dir (pool_chrome_launch @1471) is what assert_no_chrome's
        pgrep matches.
  pattern: setup calls pool_config_init+pool_state_init; spawn_sim_owner calls _pool_get_starttime;
        selftest_sim_owner_is_alive_pi calls pool_owner_alive.
  gotcha: pool_owner_alive reads /proc/<pid>/comm DIRECTLY — the override hook does NOT satisfy it;
        spawn_sim_owner's "pi" binary does. pool_lease_exists rc 1 aborts bare → assert_lane_exists
        uses `[[ -f ]]` (presence), NOT pool_lease_exists (validity), to stay set-e-safe.

# The sibling binaries validate.sh invokes / references
- file: bin/agent-browser-pool
  why: `"$ABPOOL_ADMIN" release all` in teardown → pool_admin_release @3830 (snapshots lanes →
        pool_release_lane EACH; rc 0 always; idempotent). Confirms the admin binary exists + its
        `case release)` wiring. Its pool_config_init honors the harness's env overrides (subprocess
        inherits exports → operates on the temp tree).
  pattern: teardown's release target.
  gotcha: pool_die (config/state init) inside the admin tool would exit the HARNESS shell if called
        inline → teardown invokes it as a SUBPROCESS with `|| true` (D6).

- file: bin/agent-browser
  why: the wrapper validate.sh's ABPOOL_WRAPPER points at (downstream M9.T2/T3/T4 invoke it by
        ABSOLUTE PATH for pre-cutover testing, PRD §2.17). Its symlink-safe bootstrap (lines 1-8)
        IS the pattern validate.sh's VALIDATE_DIR/ABPOOL_REPO resolution mirrors.
  pattern: readlink -f "${BASH_SOURCE[0]}" → dirname → source.
  gotcha: validate.sh resolves to test/, then `..` for the repo root (one level up, like install.sh).

# Sibling PRPs (the shape to mirror — NEW file + chmod + shellcheck-SC1091-OK)
- file: plan/001_0f759fe2777c/P1M8T1S1/PRP.md
  why: install.sh (LANDED/in-flight) — the "new executable at a fixed path, chmod 0755, bash -n +
        shellcheck clean (SC1091 info OK), hermetic Level-2 test" pattern. validate.sh mirrors it
        for structure + validation. Its "doctor/teardown as subprocess, report-don't-abort" (D10)
        IS validate.sh's teardown-as-subprocess (D6).
  pattern: the verbatim-body + design-decisions + Level-2-hermetic-test structure.

# Architecture (host facts)
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 8 (Test Hook Overrides) @160-172 — confirms AGENT_BROWSER_POOL_OWNER_PID +
        _OWNER_STARTTIME are the narrowly-scoped hooks; "allows the test harness to simulate
        distinct agents from distinct subshell PIDs without needing actual pi ancestors."
  pattern: FINDING 8 IS the contract-(b) mechanism setup realizes.
  gotcha: FINDING 8 sets the IDENTITY; the REAL process must still have comm=="pi" for liveness —
        which is why spawn_sim_owner exists (not documented in key_findings — this PRP adds it).

# External primary sources (URLs — version-stable)
- url: https://man7.org/linux/man-pages/man5/proc.5.html
  why: /proc/[pid]/comm (basename of executed ELF, 15-char limit) + /proc/[pid]/stat field 22
        (starttime) + the parenthesized-comm parsing note (locate the last `)`).
  critical: comm = basename of the ELF, NOT argv[0] → the copy-to-"pi" trick is valid.
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "set -e is not a panacea" — commands in if/|| conditions are errexit-exempt → the
        `( set -e; "$fn" ) || rc=$?` runner pattern keeps a test failure non-fatal.
  critical: a bare `(( 0 ))`, bare `pgrep` (no match), bare `kill` (ESRCH) all ABORT under set -e.
- url: https://www.shellcheck.net/wiki/SC2155
  why: "declare and assign separately to avoid masking return values" — `local x="$(…)"` masks
        failure (local returns 0). validate.sh uses 2-statement captures in spawn_sim_owner.
- url: https://man7.org/linux/man-pages/man1/pgrep.1.html
  why: -f matches the FULL command line (how assert_no_chrome scopes to --user-data-dir); rc 1 on
        no-match (must be an if-condition, not a bare statement).
```

### Current Codebase tree

After **M1–M7** landed + **M8.T1.S1** (in-flight: `install.sh` staged at the repo root), the
repo root has `bin/{agent-browser,agent-browser-pool,.gitkeep}`, `lib/pool.sh` (4302 lines),
`install.sh`, `PRD.md`, `README.md`, `.gitignore`, `test/.gitkeep` (empty). **`test/validate.sh`
does NOT exist yet. THIS task creates it:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md                             # install section synced by M10.T1.S1 (NOT this task)
├── install.sh                            # M8.T1.S1 (in-flight) — UNCHANGED
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # M6.T3.S2 — UNCHANGED (ABPOOL_WRAPPER target)
│   └── agent-browser-pool                # M7.T5.S1 — UNCHANGED (ABPOOL_ADMIN target)
├── lib/
│   └── pool.sh                           # UNCHANGED (SOURCED by validate.sh; not edited). 4302 lines.
├── test/
│   └── .gitkeep                          # RETAINED
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M9T1S1/
        ├── PRP.md                         # THIS FILE
        └── research/{test-framework-facts,external-research}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── test/
    └── validate.sh                       # NEW (chmod 0755): the test FRAMEWORK. Dual-mode
                                          #   (executed→self-test; sourced→helpers+runner for
                                          #   M9.T2/T3/T4). 5 assertions + spawn_sim_owner +
                                          #   hermetic setup/teardown + run_test/abpool_run_suite.
                                          #   Chrome-free self-test. Sources lib/pool.sh (DRY).
```

**File responsibilities**:
- `test/validate.sh` — the test infrastructure. Owns NO pooling logic: it reuses the lib's
  `pool_config_init`/`pool_state_init`/`pool_owner_alive`/`_pool_get_starttime` + invokes
  `bin/agent-browser-pool release all`. Downstream test files `source` it + add `test_*` bodies.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the comm-liveness coupling): pool_owner_alive (lib/pool.sh:616) reads the REAL
#   /proc/<pid>/comm and compares to EXPECTED_COMM (default "pi") — it does NOT trust the
#   POOL_OWNER_COMM the override hook sets. So a simulated owner is LIVE only if its PID points at
#   a real process whose comm IS "pi". The env override sets the lease's identity; it does NOT fake
#   the kernel process. spawn_sim_owner (copy /usr/bin/sleep to a file named "pi", exec it —
#   HOST-VERIFIED) is the REQUIRED engine. Without it, every "live agent" test's lease looks STALE
#   → pool_lease_find_mine returns 1 → the wrapper acquires a NEW lane → "same browser for the
#   session" tests fail. (research §1.2, §2.)

# CRITICAL (the fork→exec settle): after `"$bin" "$dur" &`, the child EXISTS (fork done) but has
#   NOT yet execve'd the "pi" binary → its /proc/comm is still the PARENT's ("bash") for a few
#   hundred microseconds. Reading comm/starttime in that window returns wrong values (cost a
#   verification run: it returned "bash"). spawn_sim_owner POLLS /proc/$pid/comm until == "pi"
#   before returning. Downstream code that reads the sim owner's starttime MUST use the value
#   setup already captured (via _pool_get_starttime AFTER the settle), not re-read it prematurely.
#   (research §2 gotcha.)

# CRITICAL (hermetic isolation is MANDATORY, not optional): pool_config_init anchors EVERY default
#   on realpath($HOME) (lib/pool.sh:126-145). If the harness does NOT override HOME + the three pool
#   roots, it reads/writes the REAL ~/.local/state/agent-browser-pool/ (clobbering live leases),
#   pgrep/pkill's the operator's REAL Chrome, and rm -rf's real ephemeral dirs. setup overrides all
#   four to a mktemp temp root. PRD §2.18: the long-lived interactive pi holds leases until explicit
#   release — a non-isolated harness races/clobbers it. (research §1.6.)

# CRITICAL (teardown MUST be a subprocess): pool_die (lib/pool.sh:30) is `exit 1`. pool_admin_release
#   is rc-0-always, BUT it calls pool_config_init/pool_state_init which CAN pool_die on genuine
#   misconfig. An INLINE `pool_admin_release` that hit a config error would EXIT the harness shell.
#   teardown invokes `"$ABPOOL_ADMIN" release all` AS A SUBPROCESS with `|| true` so a pool_die inside
#   the admin tool cannot kill the harness. (Same lesson as M8.T1.S1 D10's doctor-as-subprocess.)

# CRITICAL (subshell isolation makes test failures non-fatal): `( set -e; "$fn" ) || rc=$?` — the
#   body runs in a subshell; its non-zero exit (a failing assert's `return 1` OR a set-e abort) is
#   the test's failure code, captured by `||`. The harness SURVIVES. This is Greg's BashFAQ/105:
#   commands in if/|| conditions are errexit-exempt. WITHOUT this, the first failing assert would
#   `exit` the whole suite. (research §3.1.)

# CRITICAL (set -e hazards the helpers respect): (a) bare `(( 0 ))` as a STATEMENT aborts (returns
#   1 when result is 0) — use `$(( ))` expansion OR put `(( ))` inside `if`; (b) `pgrep`/`grep`/
#   `curl`/`kill` returning non-zero (no-match/ESRCH) aborts bare — wrap in `if`/`|| true`;
#   `assert_no_chrome` uses pgrep as the `if` CONDITION (errexit-exempt); (c) `local x="$(…)"` MASKS
#   failure (SC2155 — local returns 0) — use 2-statement `local x; x="$(…)"` (spawn_sim_owner does);
#   (d) `kill -0` is a TRAP (kill(2): returns 1 for BOTH ESRCH-dead AND EPERM-foreign-alive) → use
#   pgrep / /proc, never kill -0. (research §3.3; all proven in lib/pool.sh too.)

# GOTCHA (assert_no_chrome is SCOPED, not global): pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"
#   matches the flag pool_chrome_launch writes → scopes to POOL chrome only → does NOT false-positive
#   the operator's daily-driver Chrome (whose --user-data-dir is ~/.config/google-chrome). pgrep -f is
#   a REGEX; the temp root has no metacharacters but downstream should escape if theirs might. A single
#   Chrome is MANY processes (renderer/GPU/utility) → use the BOOLEAN form (pgrep >/dev/null), never
#   `pgrep -c` for "is there any?". (research §3.5.)

# GOTCHA (assert_lane_exists uses file PRESENCE, not validity): `[[ -f "$POOL_LANES_DIR/$N.json" ]]`
#   = "lane N is claimed" (what pool_lanes_list enumerates). The lib's `pool_lease_exists N` is
#   STRICTER (also checks valid JSON) BUT returns rc 1 on missing/corrupt → a bare call ABORTS under
#   set -e. assert_lane_exists uses presence (set-e-safe). Downstream wanting validity: `if
#   pool_lease_exists N; then …`.

# GOTCHA (source-vs-execute gate): `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` is TRUE only when validate.sh
#   is EXECUTED directly (then $0 == the path); FALSE when sourced (then $0 == the caller). So the
#   self-test runs only on direct execution; `source test/validate.sh` defines helpers + runner
#   WITHOUT running anything. Downstream defines test_* then calls abpool_run_suite test_. (bash
#   manual, Bash Variables → BASH_SOURCE; research §3.2.)

# GOTCHA (PASS/FAIL counters use $(( )) expansion, never (( ))++): `PASS=$((PASS+1))` is always
#   errexit-safe; `(( PASS++ ))` returns the OLD value → 0 when PASS was 0 → ABORTS under set -e.
#   `(( rc == 0 ))` is safe ONLY inside `if`. (research §3.3; lib/pool.sh _pool_age_str documents it.)

# GOTCHA (shellcheck SC1091 (info) is EXPECTED + ACCEPTED): `shellcheck -s bash test/validate.sh`
#   emits ONE info: SC1091 on the dynamic `source ../lib/pool.sh` line. This is IDENTICAL to
#   bin/agent-browser, bin/agent-browser-pool, AND install.sh (host-verified) — the accepted codebase
#   convention. Validation passes if there are NO error/warning-severity issues. Equivalently:
#   `shellcheck --exclude=SC1091 -s bash test/validate.sh` → clean.

# GOTCHA (the self-test is Chrome-free by design): there is NO master profile under the real
#   ~/.agent-chrome-profiles/master-profile on this checkout, and real acquire needs master + btrfs +
#   ~10s Chrome boot. The self-test exercises the FRAMEWORK (assertions, runner, isolation,
#   owner-sim) against temp state + lib primitives — no Chrome. Chrome-lifecycle tests are M9.T2/T3/T4.

# GOTCHA (PRD §2.2: never pass bare ~ to a subprocess): validate.sh resolves $HOME (exported to an
#   absolute mktemp path) + the repo dir (cd && pwd → absolute); never emits a bare ~. Downstream
#   tests inherit the same discipline via the lib.
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk layout change beyond the new
`test/validate.sh` file, and NO new env vars (it CONSUMES the LANDED overrides
`AGENT_BROWSER_POOL_OWNER_PID` / `_OWNER_STARTTIME` / `AGENT_CHROME_HEADLESS` /
`AGENT_BROWSER_POOL_STATE` / `AGENT_CHROME_EPHEMERAL_ROOT` / `AGENT_CHROME_MASTER`). Module-level
state is a handful of `ABPOOL_*` globals (counters, temp-root vars, sim-owner tracking) + the
lib's `POOL_*` globals (resolved by `pool_config_init`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + the LANDED surfaces validate.sh consumes
  - RUN: test -f lib/pool.sh && test -f bin/agent-browser && test -f bin/agent-browser-pool && echo "OK bins+lib"
  - EXPECT: all exist (bin/agent-browser-pool from P1.M7.T5.S1; install.sh may or may not be present — irrelevant).
  - RUN (confirm this task is greenfield — NO existing validate.sh):
        test -e test/validate.sh && echo "STOP: validate.sh exists" || echo "OK: validate.sh greenfield"
  - EXPECT: OK: validate.sh greenfield (only test/.gitkeep present).
  - RUN (confirm the lib functions validate.sh sources + calls are defined):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_config_init pool_state_init pool_owner_alive _pool_get_starttime; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; echo "OK lib fns defined"'
  - EXPECT: OK lib fns defined (all LANDED: pool_config_init @126, pool_state_init @202,
        pool_owner_alive @616, _pool_get_starttime @404).
  - RUN (confirm the override hook + the admin release wiring):
        grep -q 'AGENT_BROWSER_POOL_OWNER_PID' lib/pool.sh && echo "OK override hook present"
        grep -q 'release)' bin/agent-browser-pool && grep -q 'pool_admin_release' lib/pool.sh && echo "OK release wired"
  - EXPECT: override hook present (pool_owner_resolve @478); release wired (pool_admin_release @3830).
  - RUN (host tooling for the spawn_sim_owner trick + assertions):
        bash --version | head -1
        for t in sleep pgrep pkill mktemp jq; do command -v "$t" >/dev/null && echo "$t OK ($(command -v $t))" || echo "$t MISSING"; done
  - EXPECT: bash 5.x; sleep/pgrep/pkill/mktemp at /usr/bin; jq present.
  - RUN (HOST-VERIFY the "fake pi" trick — the engine behind owner simulation):
        td=$(mktemp -d); cp /usr/bin/sleep "$td/pi"; chmod +x "$td/pi"; "$td/pi" 3 & pid=$!
        sleep 0.3; echo "comm=[$(cat /proc/$pid/comm 2>/dev/null)]"; kill "$pid" 2>/dev/null; rm -rf "$td"
  - EXPECT: comm=[pi] (this is THE proof the trick works on this host). If you get "bash", you read
        comm before execve settled — wait longer / poll (see spawn_sim_owner's settle loop).
  - RUN (confirm shellcheck SC1091 is the ONLY emission on the existing bin shims — the convention):
        shellcheck -s bash bin/agent-browser 2>&1 | grep -E 'SC[0-9]+' | sort -u
  - EXPECT: only SC1091 (info). validate.sh's source line will emit the same.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task only SOURCES the lib — must not break existing syntax).

Task 1: CREATE test/validate.sh (the verbatim body, executable)
  - PLACEMENT: test/validate.sh (NEW file in test/ — the dir currently holds only .gitkeep).
  - IMPLEMENT: paste the verbatim body from the "What → The test/validate.sh body" section above,
        EXACTLY (shebang + header + set -euo pipefail + VALIDATE_DIR/ABPOOL_REPO/ABPOOL_WRAPPER/
        ABPOOL_ADMIN resolution + source lib/pool.sh + ABPOOL_* globals + _fail + the 5 assertion
        helpers + spawn_sim_owner [with the settle poll] + _abpool_global_cleanup + trap +
        setup/teardown + run_test + abpool_run_suite + the 6 selftest_* functions + the
        BASH_SOURCE gate). Then `chmod 0755 test/validate.sh`.
  - MAKE EXECUTABLE: chmod 0755 test/validate.sh
  - NOTE on the `# shellcheck source=../lib/pool.sh` directive: it is a HINT for editors/`shellcheck
        -x`; `shellcheck -s bash test/validate.sh` (without -x) still emits SC1091 (info) on the
        dynamic source — that is ACCEPTED (matches bin/* + install.sh). Do NOT add
        `# shellcheck disable=SC1091` unless you want a fully-silent run; the convention tolerates
        the info.
  - VERIFY (immediately after):
        bash -n test/validate.sh && echo "OK syntax"
        shellcheck -s bash test/validate.sh; echo "(SC1091 info on the source line is ACCEPTED — matches bin/* + install.sh)"
        test -x test/validate.sh && echo "OK executable"
        test -f test/.gitkeep && echo "OK .gitkeep retained"
        git status --short | grep -qvE '^\?\? test/validate\.sh$|plan/' && echo "STOP: unexpected change!" || echo "OK only test/validate.sh new"
  - EXPECT: OK syntax; shellcheck shows at most SC1091 (info); OK executable; .gitkeep retained;
        git status shows ONLY test/validate.sh (untracked) outside plan/.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY `test/validate.sh` (new untracked) outside plan/ (plan/ changes are this PRP +
        research). lib/pool.sh, bin/*, install.sh, .gitignore, PRD.md, README.md, tasks.json,
        prd_snapshot.md, test/.gitkeep UNCHANGED. NO bats/shunit2, NO second test file.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe repo resolution (mirror bin/*, resolve to repo root via test/..):
VALIDATE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ABPOOL_REPO="$(cd "$VALIDATE_DIR/.." && pwd)"
#   readlink -f canonicalizes validate.sh (handles bash test/validate.sh, symlinks);
#   dirname → test/; cd && pwd → absolute; ABPOOL_REPO = one level up = repo root.

# PATTERN — the subshell-isolated runner (a test failure NEVER kills the harness):
run_test() {
    local name="$1" fn="$2" rc=0
    printf '== %s\n' "$name"
    setup
    ( set -e; "$fn" ) || rc=$?     # body non-zero = test fail, captured, harness survives
    teardown
    if (( rc == 0 )); then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
    else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$name"); printf '   FAIL\n' >&2; fi
}
#   `( set -e; "$fn" )` re-enables errexit INSIDE the body → first failing assert ends the test.
#   `|| rc=$?` is errexit-exempt (the || list) → harness survives ANY body exit code.
#   `ABPOOL_PASS=$((…+1))` (expansion) always safe; NEVER `(( ABPOOL_PASS++ ))` (aborts @0).

# PATTERN — spawn_sim_owner (THE engine; the settle poll is MANDATORY):
spawn_sim_owner() {
    local dur="${1:-600}" bin_dir bin pid comm tries
    bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"; bin="$bin_dir/pi"
    cp -- /usr/bin/sleep "$bin"; chmod +x -- "$bin"
    "$bin" "$dur" &; pid="$!"
    tries=0
    while (( tries++ < 50 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [[ "$comm" == "pi" ]] && break
        sleep 0.02
    done
    ABPOOL_SIM_BINS+=("$bin_dir"); printf '%s\n' "$pid"
}
#   basename("pi") → comm=="pi" once execve lands. The poll bridges the fork→exec window.

# PATTERN — hermetic setup (isolation is MANDATORY):
setup() {
    ABPOOL_TEST_ROOT="$(mktemp -d -t abpool-test.XXXXXX)"; ABPOOL_TMP_ROOT="$ABPOOL_TEST_ROOT"
    export HOME="$ABPOOL_TEST_ROOT/home"; mkdir -p -- "$HOME"
    export AGENT_BROWSER_POOL_STATE="$ABPOOL_TEST_ROOT/state"
    export AGENT_CHROME_EPHEMERAL_ROOT="$ABPOOL_TEST_ROOT/active"
    export AGENT_CHROME_MASTER="$ABPOOL_TEST_ROOT/master"; mkdir -p -- "$AGENT_CHROME_MASTER"
    export AGENT_CHROME_HEADLESS=1
    pool_config_init; pool_state_init           # re-resolve POOL_* against temp HOME
    local pid st; pid="$(spawn_sim_owner)"; st="$(_pool_get_starttime "$pid")"
    ABPOOL_CUR_OWNER="$pid"
    export AGENT_BROWSER_POOL_OWNER_PID="$pid"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
}

# PATTERN — teardown as a SUBPROCESS (pool_die can't kill the harness):
teardown() {
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && kill "$ABPOOL_CUR_OWNER" 2>/dev/null || true
}

# PATTERN — assert_no_chrome scoped via the --user-data-dir flag (pgrep is the if-condition):
assert_no_chrome() {
    local root="${1:-$POOL_EPHEMERAL_ROOT}"
    if pgrep -f -- "user-data-dir=$root" >/dev/null 2>&1; then
        _fail "assert_no_chrome: Chrome still running under --user-data-dir=$root"; return 1
    fi
}
#   pgrep rc 1 (no match) is errexit-exempt as the `if` condition → "no chrome" = success.

# GOTCHA — WHY spawn_sim_owner (not just the env var): pool_owner_alive reads REAL /proc comm;
#   the override sets identity, not the kernel process. (research §1.2/§2.)
# GOTCHA — WHY the settle poll: fork→exec window returns the parent's comm ("bash"). (research §2.)
# GOTCHA — WHY teardown is a subprocess: pool_die=exit1 would kill the harness shell. (research §1.5.)
# GOTCHA — WHY subshell isolation: a failing assert must end ONE test, not the suite. (research §3.1.)
# GOTCHA — WHY $(( )) not (( ))++ : bare (( 0 )) aborts under set -e. (research §3.3.)
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "test/validate.sh (NEW; chmod 0755; in test/ — the dir holds only .gitkeep today).
            Verbatim body from the 'What' section."

LIBRARY (lib/pool.sh — SOURCED, not edited):
  - sources: "validate.sh does 'source "$ABPOOL_REPO/lib/pool.sh"' → joins bin/agent-browser +
            bin/agent-browser-pool + install.sh as the FOURTH consumer."
  - calls:   "pool_config_init @126 + pool_state_init @202 (setup); _pool_get_starttime @404
            (spawn_sim_owner); pool_owner_alive @616 (self-test)."
  - consumes (env): "AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME (pool_owner_resolve @478);
            AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT/AGENT_CHROME_MASTER/HOME
            (pool_config_init @126); AGENT_CHROME_HEADLESS (pool_config_init @172)."

BINARIES (invoked as subprocesses by teardown / downstream):
  - invokes: "'$ABPOOL_ADMIN' release all (bin/agent-browser-pool → pool_admin_release @3830) in
            teardown, AS A SUBPROCESS (|| true) so a pool_die cannot kill the harness."
  - references: "ABPOOL_WRAPPER (bin/agent-browser) for downstream M9.T2/T3/T4 pre-cutover testing
            by ABSOLUTE PATH (PRD §2.17)."

DOWNSTREAM CONTRACT (what M9.T2/T3/T4 consume):
  - source:  "source test/validate.sh   (defines helpers + runner; does NOT run the suite — the
            BASH_SOURCE gate holds when sourced)."
  - add:     "test_* bodies (use assert_*, spawn_sim_owner [already called by setup], the
            ABPOOL_WRAPPER by absolute path)."
  - run:     "abpool_run_suite test_     (enumerates test_*, returns rc 1 on any failure)."
  - per-test: "EACH test body owns its cleanup assertions (release + assert_no_chrome +
            assert_no_dir) per PRD §2.18; teardown is the backstop."

GITIGNORE:
  - no change: "no rule matches test/validate.sh (it is a tracked repo file). .gitignore is
            orchestrator-owned (M10.T1.S2)."

NO CHANGES TO:
  - lib/pool.sh (sourced, not edited), bin/agent-browser (M6.T3.S2), bin/agent-browser-pool
    (M7.T5.S1), install.sh (M8.T1.S1), .gitignore, PRD.md / tasks.json / prd_snapshot.md
    (read-only), README.md (M10.T1.S1), test/.gitkeep (retained). NO bats/shunit2, NO second
    test file, NO docs (item §5: test infrastructure, no user-facing surface).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating test/validate.sh + chmod 0755 — fix before proceeding.
bash -n test/validate.sh && echo "OK bash -n"
shellcheck -s bash test/validate.sh; echo "(SC1091 info on the dynamic source line is ACCEPTED — matches bin/agent-browser + bin/agent-browser-pool + install.sh; host-verified)"
test -x test/validate.sh && echo "OK executable"
# Equivalently, a fully-silent shellcheck run (excludes the accepted info):
shellcheck --exclude=SC1091 -s bash test/validate.sh && echo "OK shellcheck (--exclude=SC1091)"
# Confirm ONLY test/validate.sh is new (no collateral edits):
git status --short | grep -vE 'plan/|^\?\? test/validate\.sh$' && echo "STOP: unexpected change" || echo "OK only test/validate.sh new"
# Expected: OK bash -n; shellcheck shows at most SC1091 (info); OK executable; only test/validate.sh new.
#   SC2155 does NOT fire (every `$(…)` capture is 2-statement: local x; x="$(…)" — spawn_sim_owner's
#   pid/comm/tries, etc.). SC2086 satisfied by quoting "$ABPOOL_REPO/...", "$POOL_LANES_DIR/...",
#   "${BASH_SOURCE[0]}", "${ABPOOL_CUR_OWNER:-}". The `(( tries++ < 50 ))` is inside `while` (exempt).
```

### Level 2: Functional Tests (HERMETIC — no Chrome/master/pi needed; the self-test)

validate.sh's self-test runs WITHOUT Chrome / a master profile / a real `pi` ancestor — it only
needs the LANDED lib. The self-test creates files ONLY under a `mktemp -d` root; the operator's
real `~/.local/state/agent-browser-pool/` + `~/.agent-chrome-profiles/active/` are NEVER touched.

```bash
# Run from the REPO ROOT.
# Case 1 — the self-test passes (the primary contract):
bash test/validate.sh; echo "rc=$?"
# Expected: prints "== selftest_*" (7 lines) + "   PASS" each + "7 passed, 0 failed"; rc=0.
#   Verifies: assert_eq pass/fail-is-non-fatal, assert_no_dir, empty-pool assert_lane_gone,
#   lane_exists after writing a lease file, AND the simulated owner is a live "pi"
#   (cat /proc/$pid/comm == pi AND pool_owner_alive accepts it).

# Case 2 — isolation: the self-test must NOT touch the real pool state. Snapshot first:
before="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
bash test/validate.sh >/dev/null 2>&1
after="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && echo "OK: real state untouched" || echo "FAIL: real state changed ($before → $after)"
# Expected: OK (HOME + the three pool roots are overridden to a temp root in setup).

# Case 3 — NEGATIVE: a failing assert must NOT kill the harness + must make the suite rc 1.
#   Write a throwaway test file that sources validate.sh + defines a failing test_ + runs the suite:
cat >/tmp/neg_test.sh <<'EOF'
set -euo pipefail
source test/validate.sh
test_passes() { assert_eq 1 1 ok; }
test_fails()  { assert_eq 1 2 "forced mismatch"; }
if ! abpool_run_suite test_; then echo "OK: suite returned rc 1 on a failure"; exit 0; fi
echo "FAIL: suite should have returned rc 1"; exit 1
EOF
bash /tmp/neg_test.sh; echo "rc=$?"; rm -f /tmp/neg_test.sh
# Expected: "1 passed, 1 failed" + "OK: suite returned rc 1 on a failure"; rc=0 (the wrapper's exit).

# Case 4 — source-vs-execute gate: sourcing must NOT run the suite.
bash -c 'source test/validate.sh; echo "sourced OK (no suite output above)"'
# Expected: NO "== selftest_" lines; just "sourced OK ...". (The gate holds when sourced.)

# Case 5 — no leftover processes/dirs after the suite (PRD §2.18 cleanup contract):
bash test/validate.sh >/dev/null 2>&1
# No lingering "pi"/sleep processes from the harness (the trap + teardown killed them):
n="$(pgrep -fc 'abpool-pi' 2>/dev/null || printf 0)"; [[ "$n" == "0" ]] && echo "OK: no leftover sim-owner bins running" || echo "WARN: $n leftover"
# (The temp roots are removed by the EXIT trap; verify with: ls -d /tmp/abpool-test.* 2>/dev/null | wc -l == 0)
```

### Level 3: Integration Testing (downstream-contract sanity)

```bash
# Verify a downstream-style test file can plug into the framework (the M9.T2/T3/T4 contract):
cat >/tmp/integ_test.sh <<'EOF'
set -euo pipefail
source test/validate.sh
# A minimal downstream test that uses the helpers + the sim owner + writes a lease.
test_downstream_writes_and_asserts_lane() {
    printf '{"lane":5}' >"$POOL_LANES_DIR/5.json"
    assert_lane_exists 5
    assert_no_dir "$POOL_LANES_DIR/99.json"   # absent → pass (sanity)
    # Cleanup assertion (PRD §2.18 — every test asserts cleanup):
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    assert_lane_gone 5
    assert_no_chrome
}
abpool_run_suite test_
EOF
bash /tmp/integ_test.sh; echo "rc=$?"; rm -f /tmp/integ_test.sh
# Expected: "1 passed, 0 failed"; rc=0. Proves source-mode + the helper API + the admin binary
# honoring the harness's env overrides (release all operates on the temp tree).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (Domain-specific: this task is FRAMEWORK infrastructure; the real domain tests are M9.T2/T3/T4.)
# Optional — verify spawn_sim_owner's settle actually works under load (race robustness):
bash -c 'source test/validate.sh; setup; pid="$AGENT_BROWSER_POOL_OWNER_PID"; \
  echo "comm=[$(cat /proc/$pid/comm)]"; teardown'
# Expected: comm=[pi] (the settle loop landed execve before the read).
# Optional — confirm the fake-pi process is accepted by the REAL liveness ladder:
bash -c 'source test/validate.sh; setup; \
  pool_owner_alive "$AGENT_BROWSER_POOL_OWNER_PID" "${POOL_OWNER_STARTTIME:-0}" pi && echo "OK alive"; teardown'
# Expected: OK alive.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n test/validate.sh` passes.
- [ ] `shellcheck -s bash test/validate.sh` → only SC1091 (info); NO error/warning severity.
- [ ] `bash test/validate.sh` → `6 passed, 0 failed`, rc 0.
- [ ] A forced failure → `abpool_run_suite` returns rc 1 (Case 3, Level 2).
- [ ] `source test/validate.sh` does NOT run the suite (Case 4, Level 2).
- [ ] Isolation: the real `~/.local/state/agent-browser-pool/lanes/` count unchanged (Case 2).
- [ ] No leftover sim-owner processes/temp roots after the suite (Case 5).

### Feature Validation

- [ ] The 5 contract helpers (`assert_eq`, `assert_lane_exists`, `assert_lane_gone`,
      `assert_no_chrome`, `assert_no_dir`) defined + exercised by the self-test.
- [ ] `run_test NAME FN` + `abpool_run_suite [PREFIX]` defined + counting pass/fail + rc-1-on-fail.
- [ ] `setup` exports `AGENT_CHROME_HEADLESS=1` + unique `AGENT_BROWSER_POOL_OWNER_PID` +
      `_OWNER_STARTTIME` per test (contract b).
- [ ] `teardown` calls `agent-browser-pool release all` (contract c).
- [ ] `spawn_sim_owner` produces a process whose `/proc/comm == "pi"` AND `pool_owner_alive`
      accepts it (the pivotal comm-liveness requirement).
- [ ] Hermetic isolation (temp HOME/state/ephemeral/master) — never touches the real pool.

### Code Quality Validation

- [ ] Follows existing codebase patterns (`set -euo pipefail`, symlink-safe `${BASH_SOURCE[0]}`
      bootstrap, 2-statement `$(…)` captures, `(( ))` only inside `if`).
- [ ] File placement matches the desired tree (`test/validate.sh`).
- [ ] Anti-patterns avoided (no bats/shunit2; no inline pool_die-capable calls in teardown; no
      bare `(( ))`/`pgrep`/`kill` statements; no `local x="$(…)"`).
- [ ] The lib is SOURCED not edited; `bin/*` + `install.sh` unchanged.

### Documentation & Deployment

- [ ] Code is self-documenting (helper doc-comments explain the comm-liveness gotcha, the settle,
      the subshell isolation, the teardown-as-subprocess rationale).
- [ ] No user-facing docs (item §5: test infrastructure, no user-facing surface) — README sync is
      M10.T1.S1.
- [ ] No new env vars introduced (consumes LANDED overrides only).

---

## Anti-Patterns to Avoid

- ❌ Don't rely on the env override ALONE to simulate a live agent — `pool_owner_alive` reads the
  REAL `/proc` comm; you MUST spawn a real `pi`-comm process (`spawn_sim_owner`).
- ❌ Don't read `/proc/$pid/comm` (or `starttime`) immediately after `&` — the fork→exec window
  returns the parent's comm; SETTLE/poll first.
- ❌ Don't skip isolation — without overriding HOME + the three pool roots, the harness clobbers
  real leases and could pkill the operator's real Chrome.
- ❌ Don't call `pool_admin_release` (or any pool_die-capable function) INLINE in teardown — run it
  as a SUBPROCESS so a config error can't exit the harness shell.
- ❌ Don't run test bodies in the harness's own shell — use the subshell `( set -e; "$fn" ) || rc=$?`
  so a failing assert ends ONE test, not the suite.
- ❌ Don't use `(( PASS++ ))` (aborts under set -e) — use `PASS=$((PASS+1))`.
- ❌ Don't use `kill -0` for liveness (conflates ESRCH/EPERM) — use pgrep / /proc.
- ❌ Don't use `pgrep -c` to count Chrome instances (one Chrome = many processes) — use the boolean
  `pgrep >/dev/null` form.
- ❌ Don't launch real Chrome in the FRAMEWORK self-test (needs master/btrfs + ~10s; that's M9.T2+).
- ❌ Don't create new patterns when existing ones work — mirror `bin/*` + `install.sh` for the
  bootstrap, shebang, chmod, shellcheck-SC1091-OK convention.
