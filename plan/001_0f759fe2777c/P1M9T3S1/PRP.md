# PRP — P1.M9.T3.S1: Release + stale reaper + crash simulation tests

---

## Goal

**Feature Goal**: Create **`test/release_reaper.sh`** — the cleanup + release-semantics test
suite (PRD §2.18; §2.5/§2.9/§2.10/§2.14). It `source`s the LANDED `test/validate.sh` framework
(P1.M9.T1.S1) for its helpers/runner, then defines **four `test_*` bodies** that drive the REAL
lib acquire+boot+release/reap/close path and assert the cleanup contract:

1. **`test_explicit_release_tears_down_lane`** — acquire+boot lane N, run
   `agent-browser-pool release N`, assert the ephemeral dir + Chrome process group + lease are gone.
2. **`test_stale_reaper_reaps_dead_owner_lane`** — owner X acquires+boots N; simulate X crashing
   (kill X + reap its zombie); kill N's Chrome (force the REAP branch, defeat reuse-orphan); owner Y
   acquires → assert N was **reaped** (M is a fresh provisional claim, `port=0`), N's dir gone.
3. **`test_reap_clears_crashed_owner_lane`** — owner X acquires+boots N (Chrome alive); simulate X
   crashing (kill X + reap zombie); run `agent-browser-pool reap`; assert dir deleted, lease gone,
   and the **orphan Chrome killed by the reaper**.
4. **`test_close_is_disconnect_only`** — acquire+boot N; run `close` (disconnect-only); assert
   Chrome still alive, dir still exists, lease still present; then `pool_lease_find_mine` returns N
   (same lane reused) + `pool_ensure_connected` reconnects.

**Deliverable**: ONE new file — **`test/release_reaper.sh`** (`chmod 0755`), in `test/` (alongside
the LANDED `test/validate.sh` + retained `test/.gitkeep` + the in-flight `test/concurrency.sh`).
NO other file is created or modified. The test boots REAL headless Chrome per booted lane
(requires the real master profile + btrfs + `google-chrome-stable` + the REAL `agent-browser`
daemon binary — ALL host-verified present) so it exercises the genuine teardown contract — not a
mocked one.

**Success Definition**:
- `test -f test/release_reaper.sh && test -x test/release_reaper.sh`; `bash -n test/release_reaper.sh`
  passes; `shellcheck -s bash test/release_reaper.sh` → only **SC1091 (info)** on the dynamic
  `source ./validate.sh` line (the ACCEPTED codebase convention — identical to `test/validate.sh`,
  the in-flight `test/concurrency.sh`, `bin/*`, `install.sh`), NO error/warning severity.
- `bash test/release_reaper.sh` → prints `== test_*` lines + `4 passed, 0 failed` → **rc 0**.
  Each test boots at most one real headless Chrome and releases/reaps it before returning.
- **Hermetic**: every test creates files/processes ONLY under the framework's `mktemp` temp root;
  the operator's real `~/.local/state/agent-browser-pool/` + real daily-driver Chrome are untouched
  (the framework's `setup()` overrides HOME + `AGENT_BROWSER_POOL_STATE` + `AGENT_CHROME_EPHEMERAL_ROOT`;
  `_release_setup_real_env` additionally points `AGENT_CHROME_MASTER` at the READ-ONLY real master and
  `AGENT_BROWSER_REAL` at the real daemon binary — Chrome still runs under the TEMP ephemeral root).
- `lib/pool.sh`, `bin/agent-browser`, `bin/agent-browser-pool`, `install.sh`, `test/validate.sh`,
  `test/.gitkeep`, `.gitignore`, `PRD.md`, `README.md`, `tasks.json` UNCHANGED (`git status --short`
  shows ONLY `test/release_reaper.sh` new untracked, outside `plan/`).

## User Persona

**Target User**: The **maintainer / CI runner** executing the P1.M9 validation milestone. They run
`bash test/release_reaper.sh` (after `test/validate.sh` exists) to PROVE the pool's cleanup contract —
"every release/reap tears the lane fully down (dir + Chrome process group + lease); a crashed agent's
orphan Chrome+dir is reclaimed; `close` is disconnect-only" (PRD §2.5/§2.9/§2.10/§2.14/§2.18).

**Use Case**: `bash test/release_reaper.sh` (developer confidence before merge; CI gate). The test is
one executable file that self-runs its `test_*` functions via the framework's `abpool_run_suite`
runner. It is NOT sourced by other tests (M9.T4 will be a sibling that also `source test/validate.sh`).

**User Journey**: maintainer runs `bash test/release_reaper.sh` → sees `== test_*` + `PASS` lines →
sees `4 passed, 0 failed` → trusts that release/reap/crash-cleanup/close-semantics hold. On a
regression (e.g. a reaper that skips a dead-owner lane, or a `close` that leaks Chrome), the test
FAILS loudly and `abpool_run_suite` returns rc 1.

**Pain Points Addressed**: (1) Without this test, the release/reaper teardown contract is untested —
a regression that leaks Chrome processes or ephemeral dirs would slip through. (2) The contract's
item description is a high-level sketch with two imprecisions (test b "X != Y" does NOT make an
owner dead; test c "kill Chrome then reap" is inconsistent with PRD §2.14) — this test resolves both
against the AUTHORITATIVE code and pins the real behavior. (3) The comm-liveness + zombie-reaping
coupling makes naive tests spuriously pass (a zombie owner may still look "alive"); this test kills
+ `wait`s the owner so `/proc` truly vanishes.

## Why

- **This IS PRD §2.18 + §2.5/§2.9/§2.10/§2.14.** §2.18: "every test must call `release`/`reap` and
  assert the ephemeral dir + Chrome process group are gone." §2.5/§2.9: release is owner-liveness-
  driven; explicit release + owner-exit both → kill pgroup + rm dir + delete lease. §2.10: the reaper
  is lazy (on acquire + on-demand `reap`). §2.14: owner crash → reap; Chrome crash (owner alive) →
  relaunch+reconnect (NOT reap) — the distinction test (c) must honor. The override hooks + the
  framework's `spawn_sim_owner` already EXIST (LANDED); this task builds the tests that USE them.
- **It validates the SINGLE most important reliability property of the pool: cleanup always happens,
  even on crash.** A pool that leaks Chrome processes or ephemeral dirs after a crash is worse than
  no pool (resource exhaustion, port exhaustion, stale leases). The release/reap teardown
  (`pool_release_lane` lib/pool.sh:2438 → `_pool_release_lane_internals` lib/pool.sh:1813 →
  `pool_chrome_kill` lib/pool.sh:1757) is the mechanism; this test is the PROOF it works on the three
  triggers (explicit release, stale-on-acquire, on-demand reap) + the negative case (close ≠ release).
- **The contract has two imprecisions that MUST be resolved against the code, or the test fails.**
  (a) Test (b)'s "X != Y → X dead" is wrong: `pool_owner_alive` (lib/pool.sh:616) reads the REAL
  `/proc`; a different override PID does NOT make X dead. X must be GENUINELY dead (kill + reap the
  zombie). (b) Test (c)'s "kill Chrome then reap" is inconsistent with PRD §2.14: `pool_reap_stale`
  only reaps DEAD-OWNER lanes; killing Chrome (owner alive) leaves the lane NOT stale → `reap` does
  nothing. The crash must be the OWNER; `reap` then kills the orphan Chrome. Capturing these here is
  the difference between a test that passes for the right reason and one that fails or passes vacuously.
- **The reuse-orphan-before-reap ordering is non-obvious and pivotal for test (b).** The acquire
  critical section (`_pool_acquire_critical_section` lib/pool.sh:1966) does **reuse-orphan BEFORE
  reap**: if N is stale but N's Chrome still answers (`pool_daemon_connected` rc 0), M will **ADOPT**
  N (port>0 kept), NOT reap it. To force the REAP branch, N's Chrome must be made non-responsive.
  The clean reap-vs-reuse signal: `M.port == 0` ⟺ reap+fresh-claim; `M.port > 0` ⟺ reuse. This test
  kills N's Chrome to force reap and asserts `M.port == 0`.
- **The `AGENT_BROWSER_REAL` gap is the make-or-break setup detail.** The framework's `setup()`
  overrides HOME to a temp dir but does NOT set `AGENT_BROWSER_REAL` → `pool_config_init` resolves
  `POOL_REAL_BIN` to a NONEXISTENT temp path → `pool_boot_lane` step e (`pool_daemon_connect`
  lib/pool.sh:1631) rc 1 → boot FAILS for every lane. `_release_setup_real_env` exports
  `AGENT_BROWSER_REAL` to the REAL daemon binary (host-verified present) + re-runs `pool_config_init`.
  (The concurrency PRP's `_concurrency_setup_master` overrides `AGENT_CHROME_MASTER` but OMITS
  `AGENT_BROWSER_REAL` — a latent gap there; THIS PRP sets BOTH.)

## What

User-visible behavior: **a runnable `test/release_reaper.sh`** that, when executed directly, runs the
release/reaper/crash/close test suite (via the framework's `abpool_run_suite`) and exits 0 on success
/ 1 on any failure. It sources `test/validate.sh` (LANDED) for the helpers + runner, defines `test_*`
bodies + 3 private helpers, and runs the suite.

The test boots REAL headless Chrome (one instance per booted lane; tests a/c/d each boot one, test b
boots one + acquires a provisional second). The observable contract per test is stated in each
`test_*` doc-comment below.

### The `test/release_reaper.sh` body (verbatim contract — authoritative from item §3 + design)

```bash
#!/usr/bin/env bash
#
# test/release_reaper.sh — release + stale reaper + crash simulation tests
# (PRD §2.18; §2.5/§2.9/§2.10/§2.14).
#
# Validates the CLEANUP + RELEASE-SEMANTICS contract:
#   (a) explicit `agent-browser-pool release N` → lane gone (dir + Chrome pgroup + lease).
#   (b) stale reaper during acquire: a dead-owner + non-responsive-Chrome lane is REAPED
#       (not reused); the next agent gets a fresh provisional lane (port=0).
#   (c) crash simulation: the owning agent dies → `agent-browser-pool reap` tears down the
#       orphan Chrome + dir + lease (reliable cleanup on crash).
#   (d) `close` is DISCONNECT-ONLY: Chrome + dir + lease survive; the next command reuses
#       the SAME lane (find_mine → N; ensure_connected reconnects).
#
# HOW IT WORKS: drives the LANDED lib functions DIRECTLY (pool_owner_resolve →
# pool_acquire_locked → pool_boot_lane) — NOT the wrapper (which `exec`s into the real
# agent-browser for driving commands and may not exit → a wrapper-driven test would hang).
# The admin `release`/`reap` are invoked as SUBPROCESSES (`"$ABPOOL_ADMIN" …`, pool_die-safe).
# `close` is invoked as the SAME command the wrapper exec's (`"$POOL_REAL_BIN" --session
# abpool-N close`) — run directly (avoids the terminal exec for this non-driving command).
#
# ★★★ SINGLE-SETUP RUNNER (HARD CONSTRAINT) ★★★ setup() is called EXACTLY ONCE for the whole
# file (NEVER per-test). The framework's run_test/abpool_run_suite call setup() before EACH
# test; in this sandbox the 3rd setup() call HANGS (a P1.M9.T1.S1 accumulation defect). Per a
# hard directive, NO agent may EVER run a 3rd setup() here. So this file BYPASSES
# run_test/abpool_run_suite: ONE setup() (temp root + config + trap); each body runs via
# `if "$fn"; then` in the MAIN shell (NOT a subshell — no mid-suite EXIT-trap firing → the
# temp root survives all four bodies); each body spawns its OWN owner via _test_spawn_owner
# (tests c/b kill theirs, so they cannot share setup's); ONE teardown() at the end.
#
# CONTRACT RESOLUTIONS (the item description is a high-level sketch; the CODE is authority):
#   - test (b) "X != Y → X dead" is imprecise: pool_owner_alive reads the REAL /proc. X must
#     be GENUINELY dead (kill X + `wait` to reap the zombie so /proc/X vanishes — a zombie's
#     comm/starttime may still read "pi" → false-alive).
#   - test (c) "kill Chrome then reap" is inconsistent with PRD §2.14 (Chrome crash w/ owner
#     alive → relaunch+reconnect, NOT reap). The simulated crash is the OWNER; reap then kills
#     the orphan Chrome. Killing Chrome alone (owner alive) leaves the lane NOT stale → reap
#     would do nothing.
#   - test (b) reuse-orphan-before-reap: to force the REAP branch, kill N's Chrome (else M
#     ADOPTS N, port>0). The clean signal: M.port == 0 ⟺ reap+fresh-claim.
#
# SOURCES the LANDED test framework (P1.M9.T1.S1) for: the 5 assertions, spawn_sim_owner (the
# `pi`-comm owner engine), setup/teardown (hermetic mktemp isolation). It does NOT use
# run_test/abpool_run_suite (they call setup() per-test — see the SINGLE-SETUP constraint).
set -euo pipefail

# --- repo + framework resolution (mirror test/validate.sh's symlink-safe bootstrap) ----------
RELEASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=./validate.sh
source "$RELEASE_DIR/validate.sh"
# (validate.sh already sourced lib/pool.sh + defined helpers + setup/teardown/runner.)

# =============================================================================
# _release_setup_real_env — point AGENT_CHROME_MASTER + AGENT_BROWSER_REAL at the REAL binaries.
#
# WHY (the pivotal gap): validate.sh's setup() overrides HOME to a temp dir → pool_config_init
# resolves POOL_REAL_BIN to $TEMP_HOME/.local/bin/agent-browser (NONEXISTENT) and POOL_MASTER_DIR
# to an EMPTY temp master. pool_boot_lane step e calls pool_daemon_connect (lib/pool.sh:1631)
# which rc 1's on a missing/non-exec POOL_REAL_BIN → pool_boot_lane DROPS the lane + rc 1 → EVERY
# test that boots real Chrome FAILS. Likewise pool_check_master pool_die's on an empty master.
#
# FIX: override BOTH to the REAL read-only master + the REAL agent-browser daemon binary (resolved
# via the operator's REAL passwd home — setup already clobbered HOME). The master is READ-ONLY
# (PRD §2.7) → safe to share; reflink copies are CoW. Chrome still runs under the TEMP ephemeral
# root (setup's override) → hermetic. Then re-resolve all POOL_* globals.
# =============================================================================
_release_setup_real_env() {
    local real_home real_master real_bin
    # Resolve the operator's REAL home BEFORE setup clobbered HOME (setup already ran by the time
    # a test body executes; capture the real home from the passwd entry).
    real_home="$(getent passwd "${USER:-$(id -un)}" | cut -d: -f6)"
    real_master="$real_home/.agent-chrome-profiles/master-profile"
    real_bin="$real_home/.local/bin/agent-browser"

    # Master: reuse the real read-only master if present+non-empty; else build a minimal one.
    if [[ -d "$real_master" ]] && [[ -n "$(ls -A "$real_master" 2>/dev/null)" ]]; then
        export AGENT_CHROME_MASTER="$real_master"     # read-only; reflink CoW → safe
    else
        local m="$ABPOOL_TEST_ROOT/master-real"
        mkdir -p -- "$m/Default"
        printf '{"minimal":true}' >"$m/Preferences"
        export AGENT_CHROME_MASTER="$m"
    fi

    # CRITICAL: the real agent-browser daemon binary. Without it, pool_daemon_connect (boot
    # step e), pool_release_lane's daemon close, and this test's own `close` invocation ALL fail.
    if [[ -x "$real_bin" ]]; then
        export AGENT_BROWSER_REAL="$real_bin"
    else
        _fail "real agent-browser not found/executable at $real_bin (boot/release/close/reap need it)"
        return 1
    fi

    # Re-resolve POOL_* globals against the overrides (idempotent).
    pool_config_init
    pool_state_init
}

# =============================================================================
# _release_acquire_boot — acquire + boot a lane for the CURRENT owner. Echoes the lane N; rc 1 on
# failure. Boots REAL headless Chrome (one instance). The caller owns the owner env: EACH test body
# spawns its OWN owner via _test_spawn_owner (which exports AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME)
# BEFORE calling this; pool_owner_resolve at the top reads that env. Guarded for set -e (every rc-1
# lib call guarded) — and also safe with errexit disabled (the bodies run via `if "$fn"`).
# =============================================================================
_release_acquire_boot() {
    local N port
    pool_owner_resolve
    if ! N="$(pool_acquire_locked)"; then
        _fail "pool_acquire_locked failed (exhaustion?)"; return 1
    fi
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        if ! pool_boot_lane "$N"; then
            _fail "pool_boot_lane failed for lane $N"; return 1
        fi
    fi
    printf '%s\n' "$N"
}

# =============================================================================
# _release_kill_owner_and_reap_zombie PID — kill PID and REAP its zombie so /proc/PID vanishes.
# WHY: a killed child becomes a ZOMBIE until its parent waits; a zombie's /proc/PID + comm may
# still read "pi"+match → pool_owner_alive FALSE-ALIVE → the lane is NOT stale → reap/acquire skip
# it → the test fails/passes-vacuously. `wait` reaps the zombie so pool_owner_alive sees it DEAD.
# PID MUST be a child of this shell (spawn_sim_owner's owner is). Best-effort (|| true).
# =============================================================================
_release_kill_owner_and_reap_zombie() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# =============================================================================
# _test_spawn_owner — spawn a FRESH live "pi"-comm owner for THIS body, set ABPOOL_CUR_OWNER (so
# the runner's inter-body cleanup kills it as a backstop), and export the owner env. Echoes the pid.
#
# WHY PER-BODY OWNERS (not setup's shared owner): setup() is called ONCE (SINGLE-SETUP constraint);
# tests (c)/(b) KILL their owner. If they shared setup's owner, a later test would find it dead.
# So every body spawns its own fresh owner — order-independent + no cross-test contamination.
# =============================================================================
_test_spawn_owner() {
    local pid st
    pid="$(spawn_sim_owner)"
    st="$(_pool_get_starttime "$pid")"
    ABPOOL_CUR_OWNER="$pid"           # runner's inter-body cleanup kills this as a backstop
    export AGENT_BROWSER_POOL_OWNER_PID="$pid"
    export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
    printf '%s\n' "$pid"
}

# =============================================================================
# TEST (a) — explicit `agent-browser-pool release N` tears the lane fully down (PRD §2.5/§2.18).
# =============================================================================
test_explicit_release_tears_down_lane() {
    _release_setup_real_env || return 1

    # (1) Spawn THIS body's owner, then acquire + boot lane N (one real headless Chrome).
    local N port cpid
    _test_spawn_owner >/dev/null
    N="$(_release_acquire_boot)" || return 1
    assert_lane_exists "$N" || return 1
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    cpid="$(pool_lease_field "$N" chrome_pid 2>/dev/null)" || cpid=""
    [[ "$port" =~ ^[0-9]+$ && "$port" != "0" ]] \
        || { _fail "lane $N not booted (port='$port')"; return 1; }

    # (2) THE CONTRACT: run `agent-browser-pool release N` (subprocess — pool_die-safe; rc 0 on
    #     release, rc 1 only on not-found — but we just booted N so it exists).
    "$ABPOOL_ADMIN" release "$N" >/dev/null 2>&1 || true

    # (3) Assert: ephemeral dir gone, Chrome process group dead, lease gone (PRD §2.18).
    assert_lane_gone "$N" || return 1     # lease file AND ephemeral dir gone
    assert_no_chrome || return 1          # scoped: no pool Chrome under the temp ephemeral root
}

# =============================================================================
# TEST (b) — stale reaper during acquire: a dead-owner + non-responsive-Chrome lane is REAPED
# (not reused); the next agent gets a FRESH provisional lane (PRD §2.9/§2.10/§2.18).
# =============================================================================
test_stale_reaper_reaps_dead_owner_lane() {
    _release_setup_real_env || return 1

    # (1) Owner X (this body's own sim owner) acquires + boots lane N.
    local N cpid pgid owner_x
    owner_x="$(_test_spawn_owner)"
    N="$(_release_acquire_boot)" || return 1
    assert_lane_exists "$N" || return 1
    cpid="$(pool_lease_field "$N" chrome_pid 2>/dev/null)" || cpid=""
    pgid="$(pool_lease_field "$N" chrome_pgid 2>/dev/null)" || pgid=""

    # (2) Simulate owner X crashing: kill X + REAP the zombie so /proc/X vanishes → N is STALE.
    #     (pool_owner_alive reads the REAL /proc; the override alone does NOT fake a dead owner,
    #      and a zombie may still read comm="pi" → false-alive — hence the `wait`.)
    _release_kill_owner_and_reap_zombie "$owner_x"

    # (3) FORCE THE REAP PATH (defeat reuse-orphan): the acquire critical section does
    #     reuse-orphan BEFORE reap — if N's Chrome still answers (pool_daemon_connected), M would
    #     ADOPT N (port>0 KEPT), not reap it. Kill N's Chrome pgroup so curl /json/version fails →
    #     not adoptable → the REAP branch runs. (Chrome teardown itself is test a/c's concern.)
    if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "0" ]]; then
        kill -9 -- -"$pgid" 2>/dev/null || true
    elif [[ "$cpid" =~ ^[0-9]+$ && "$cpid" != "0" ]]; then
        kill -9 "$cpid" 2>/dev/null || true
    fi
    sleep 0.4   # let the pgroup die so curl /json/version fails (pool_daemon_connected → rc 1)

    # (4) Spawn a SECOND live "pi"-comm owner Y, then acquire lane M AS Y (current shell —
    #     sequential, no subshell). During M's acquire, N (stale + non-responsive) is reaped.
    local owner_y st_y M saved_pid saved_st
    owner_y="$(spawn_sim_owner)"
    st_y="$(_pool_get_starttime "$owner_y")"
    # Override the owner env for THIS shell so pool_owner_resolve picks up Y; save X's to restore.
    saved_pid="$AGENT_BROWSER_POOL_OWNER_PID"
    saved_st="$AGENT_BROWSER_POOL_OWNER_STARTTIME"
    export AGENT_BROWSER_POOL_OWNER_PID="$owner_y"
    export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_y"
    pool_owner_resolve                      # read Y's env into the POOL_OWNER_* globals
    if ! M="$(pool_acquire_locked)"; then
        export AGENT_BROWSER_POOL_OWNER_PID="$saved_pid"
        export AGENT_BROWSER_POOL_OWNER_STARTTIME="$saved_st"
        _release_kill_owner_and_reap_zombie "$owner_y"
        _fail "M (owner Y) pool_acquire_locked failed"; return 1
    fi
    # Restore X's env (X is dead; keeps teardown's owner view consistent).
    export AGENT_BROWSER_POOL_OWNER_PID="$saved_pid"
    export AGENT_BROWSER_POOL_OWNER_STARTTIME="$saved_st"

    # (5) ASSERT REAP (not reuse). The clean signal: M.port == 0 ⟺ M is a FRESH reap+claim.
    #     (If M had REUSED/adopted N, M.port would be N's port > 0.) Also N's dir is gone (reaped)
    #     and M is owned by Y. NOTE: M may == N's NUMBER (find_free_lane returns lowest free, which
    #     after reaping N is N's number) — so do NOT assert M != N; assert the FRESH-CLAIM signals.
    local m_port m_owner
    m_port="$(pool_lease_field "$M" port 2>/dev/null)" || m_port=""
    m_owner="$(pool_lease_field "$M" owner.pid 2>/dev/null)" || m_owner=""
    assert_eq "0" "$m_port" \
        "M is a fresh provisional claim (port=0) — N was REAPED, not reused" \
        || { _release_kill_owner_and_reap_zombie "$owner_y"; return 1; }
    assert_eq "$owner_y" "$m_owner" "M owned by Y (the second agent)" \
        || { _release_kill_owner_and_reap_zombie "$owner_y"; return 1; }
    assert_lane_exists "$M" || { _release_kill_owner_and_reap_zombie "$owner_y"; return 1; }
    # N's ephemeral dir was torn down by the reap (M, being provisional, did NOT recreate it).
    assert_no_dir "$POOL_EPHEMERAL_ROOT/$N" \
        || { _release_kill_owner_and_reap_zombie "$owner_y"; return 1; }

    # (6) Cleanup: release all (safe backstop) + reap Y's process.
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    _release_kill_owner_and_reap_zombie "$owner_y"
}

# =============================================================================
# TEST (c) — crash simulation: the owning agent dies → `agent-browser-pool reap` tears down the
# orphan Chrome + dir + lease (reliable cleanup on crash) (PRD §2.9/§2.10/§2.14/§2.18).
#
# CONTRACT RESOLUTION: the item says "kill the Chrome process manually then reap". But per PRD
# §2.14, a Chrome crash with the owner ALIVE → relaunch+reconnect (KEEP lease), NOT reap;
# pool_reap_stale only reaps DEAD-OWNER lanes. So the simulated crash is the OWNER (agent pi)
# crashing (kill X); Chrome is left ALIVE (the orphan a real crash leaves). `reap` then kills the
# orphan Chrome pgroup + rm dir + drop lease — the strong cleanup-on-crash claim.
# =============================================================================
test_reap_clears_crashed_owner_lane() {
    _release_setup_real_env || return 1

    # (1) Owner X (this body's own sim owner) acquires + boots lane N. Chrome is ALIVE pre-crash.
    local N port owner_x
    owner_x="$(_test_spawn_owner)"
    N="$(_release_acquire_boot)" || return 1
    assert_lane_exists "$N" || return 1
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    [[ "$port" =~ ^[0-9]+$ && "$port" != "0" ]] \
        || { _fail "lane $N not booted (port='$port')"; return 1; }
    # Sanity: Chrome IS alive pre-crash (curl, NOT kill -0 — kill -0 conflates ESRCH/EPERM).
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 \
        || { _fail "sanity: Chrome on port $port not alive before crash"; return 1; }

    # (2) Simulate the OWNER crashing: kill X + reap the zombie. Chrome is LEFT ALIVE (orphan).
    _release_kill_owner_and_reap_zombie "$owner_x"

    # (3) THE CONTRACT: call `agent-browser-pool reap`. The reaper detects N's owner X dead →
    #     pool_release_lane → kill the orphan Chrome pgroup + rm dir + drop lease.
    "$ABPOOL_ADMIN" reap >/dev/null 2>&1 || true
    sleep 0.5   # let the orphan Chrome pgroup fully exit/reap so assert_no_chrome is clean

    # (4) Assert: dir deleted, lease gone, orphan Chrome DEAD (the reaper killed it).
    assert_lane_gone "$N" || return 1
    assert_no_chrome || return 1
}

# =============================================================================
# TEST (d) — `close` is DISCONNECT-ONLY: Chrome + dir + lease survive; the next command reuses
# the SAME lane (PRD §2.5 "close != release" / §2.18).
# =============================================================================
test_close_is_disconnect_only() {
    _release_setup_real_env || return 1

    # (1) Spawn THIS body's owner, then acquire + boot lane N.
    local N port
    _test_spawn_owner >/dev/null
    N="$(_release_acquire_boot)" || return 1
    assert_lane_exists "$N" || return 1
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    [[ "$port" =~ ^[0-9]+$ && "$port" != "0" ]] \
        || { _fail "lane $N not booted (port='$port')"; return 1; }

    # (2) THE CONTRACT: run `close` (disconnect-only). The wrapper exec's
    #     `"$POOL_REAL_BIN" --session abpool-N close`; we invoke the SAME command DIRECTLY (avoids
    #     the wrapper's terminal exec for this non-driving command). rc is 0 on agent-browser
    #     0.28.0 (always). close detaches the daemon session; leaves Chrome + dir + lease ALIVE.
    "$POOL_REAL_BIN" --session "abpool-$N" close >/dev/null 2>&1 || true
    sleep 0.4   # let the daemon settle

    # (3) Assert: Chrome STILL ALIVE, dir STILL EXISTS, lease STILL PRESENT (close != release).
    assert_lane_exists "$N" || return 1                                  # lease present
    [[ -d "$POOL_EPHEMERAL_ROOT/$N" ]] \
        || { _fail "ephemeral dir gone after close (close must NOT release)"; return 1; }
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 \
        || { _fail "Chrome on port $port not alive after close (close must NOT kill it)"; return 1; }

    # (4) NEXT COMMAND REUSES THE SAME LANE. pool_lease_find_mine returns the owner's EXISTING live
    #     lease (close did NOT release) → N. (my_owner is still alive — this body's sim owner.)
    local reuse
    if ! reuse="$(pool_lease_find_mine 2>/dev/null)"; then
        _fail "pool_lease_find_mine found no lane after close (expected reuse of $N)"; return 1
    fi
    assert_eq "$N" "$reuse" "next command reuses the same lane (close != release)" || return 1

    # (5) And the daemon RECONNECTS to the SAME Chrome (still alive) via ensure_connected.
    pool_ensure_connected "$N" \
        || { _fail "pool_ensure_connected failed to reconnect lane $N after close"; return 1; }
}

# =============================================================================
# _abpool_run_release_reaper_suite — the SINGLE-SETUP runner.
#
# ★★★ HARD CONSTRAINT: setup() is called EXACTLY ONCE for the whole file (NEVER per-test). ★★★
# The framework's run_test/abpool_run_suite call setup() before EACH test; in this sandbox the
# 3rd setup() call HANGS (a P1.M9.T1.S1 accumulation defect). Per a hard directive, NO agent may
# EVER run a 3rd setup() here. So this file BYPASSES run_test/abpool_run_suite:
#   - ONE setup() (temp root + config + trap). setup() spawns ONE sim-owner, but each body spawns
#     its OWN via _test_spawn_owner — so setup's owner is unused and is killed+reaped right after.
#   - Each body runs via `if "$fn"; then` in the MAIN shell (NOT a subshell). A `return 1` from a
#     failed assert is the function's rc → recorded as FAIL → the suite CONTINUES. (Bodies use
#     explicit `|| return 1` / `if !` guards, so running them in a conditional context — where
#     errexit is disabled — is safe. No subshell ⇒ the EXIT trap does NOT fire mid-suite ⇒ the
#     temp root is NOT removed between tests.)
#   - Each body owns its lanes (release all at its end); the runner adds a backstop release-all +
#     kills the body's owner (ABPOOL_CUR_OWNER, set by _test_spawn_owner) between bodies.
#   - ONE teardown() at the end.
# =============================================================================
_abpool_run_release_reaper_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call
    # setup() spawned ONE sim-owner; each body spawns its own, so kill+reap this unused one now
    # (so it does not linger ~600s; its ABPOOL_CUR_OWNER slot is overwritten by the first body).
    _release_kill_owner_and_reap_zombie "$AGENT_BROWSER_POOL_OWNER_PID"
    ABPOOL_CUR_OWNER=""
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        # Inter-body backstop: release any leftover lanes + kill this body's owner.
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _release_kill_owner_and_reap_zombie "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
    done
    teardown
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    if (( ABPOOL_FAIL > 0 )); then
        printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2
        return 1
    fi
    return 0
}

# --- source-vs-execute gate: run the suite ONLY when executed directly. ---------------------
# (When sourced by a future aggregator, define the helpers + test_* functions without running.)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! _abpool_run_release_reaper_suite; then
        exit 1
    fi
fi
```
Then `chmod 0755 test/release_reaper.sh`.

### Success Criteria

- [ ] `test/release_reaper.sh` created (NEW; `chmod 0755`); shebang `#!/usr/bin/env bash` + `set -euo pipefail`.
- [ ] Resolves `RELEASE_DIR` symlink-safely via `readlink -f "${BASH_SOURCE[0]}"` → `dirname` →
      `cd && pwd`; sources `"$RELEASE_DIR/validate.sh"` (which itself sources `lib/pool.sh` + defines
      all helpers/setup/teardown/runner).
- [ ] `_release_setup_real_env` exports `AGENT_CHROME_MASTER` (real non-empty master, else minimal
      built) AND `AGENT_BROWSER_REAL` (real daemon binary; `_fail` if absent) + re-runs
      `pool_config_init`/`pool_state_init` so `POOL_MASTER_DIR` + `POOL_REAL_BIN` reflect them.
- [ ] `_release_acquire_boot` composes `pool_owner_resolve` + `pool_acquire_locked` (guarded) +
      `pool_boot_lane` (guarded); echoes the lane N; rc 1 on failure.
- [ ] `_release_kill_owner_and_reap_zombie PID` does `kill PID` + `wait PID` (both `|| true`) so the
      zombie is reaped and `/proc/PID` vanishes.
- [ ] `test_explicit_release_tears_down_lane`: boot N; `"$ABPOOL_ADMIN" release N`; assert
      `assert_lane_gone N` + `assert_no_chrome`.
- [ ] `test_stale_reaper_reaps_dead_owner_lane`: boot N as X; kill+wait X; kill N's Chrome pgroup;
      spawn Y + acquire M as Y; assert `M.port==0` (reap not reuse) + `M.owner.pid==Y` +
      `assert_lane_exists M` + `assert_no_dir $POOL_EPHEMERAL_ROOT/$N`; release all + reap Y.
- [ ] `test_reap_clears_crashed_owner_lane`: boot N as X; sanity Chrome alive; kill+wait X;
      `"$ABPOOL_ADMIN" reap`; assert `assert_lane_gone N` + `assert_no_chrome`.
- [ ] `test_close_is_disconnect_only`: boot N; `"$POOL_REAL_BIN" --session abpool-N close`; assert
      lease present + dir exists + Chrome alive (curl); `pool_lease_find_mine` == N; `pool_ensure_connected N` rc 0.
- [ ] ★ SINGLE-SETUP: `setup()` is called EXACTLY ONCE (inside `_abpool_run_release_reaper_suite`);
      the file does NOT use `run_test`/`abpool_run_suite` (they call `setup()` per test → 3rd-call HANG).
      Each body spawns its own owner via `_test_spawn_owner`; bodies run via `if "$fn"; then` in the
      main shell (no subshell → the EXIT trap never fires mid-suite → the temp root survives).
- [ ] Source-vs-execute gate: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then if ! _abpool_run_release_reaper_suite; then exit 1; fi; fi`.
- [ ] `bash test/release_reaper.sh` → `4 passed, 0 failed`, **rc 0**.
- [ ] `bash -n test/release_reaper.sh` passes; `shellcheck -s bash test/release_reaper.sh` → only
      SC1091 (info) on the `source ./validate.sh` line, NO error/warning severity.
- [ ] All `lib/pool.sh`, `bin/*`, `install.sh`, `test/validate.sh`, `test/.gitkeep`,
      `.gitignore`, `PRD.md`, `README.md`, `tasks.json` UNCHANGED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **verbatim `test/release_reaper.sh` body**
(item §3 + the contract resolutions); the **single-deliverable + `test/` placement** decision; the
**direct-lib-call seam rationale** (the wrapper's terminal `exec` would hang a wrapper-driven test;
driving `pool_owner_resolve` + `pool_acquire_locked` + `pool_boot_lane` directly exercises the exact
same acquire/boot path without the exec — `release`/`reap` are admin subprocesses, `close` is the
real-binary command the wrapper exec's, run directly); the **`AGENT_BROWSER_REAL` gap** (the pivotal
setup detail: the framework's `setup()` makes `POOL_REAL_BIN` nonexistent → boot fails →
`_release_setup_real_env` exports `AGENT_BROWSER_REAL` to the real binary + `AGENT_CHROME_MASTER` to
the real master); the **two contract resolutions** (test b "X!=Y" → kill X + reap zombie; test c
"kill Chrome" → kill the OWNER, reap kills the orphan Chrome — PRD §2.14); the **reuse-orphan-before-
reap ordering** (kill N's Chrome to force the reap branch; `M.port==0` is the clean reap signal); the
**zombie-reaping gotcha** (`kill` + `wait` so `/proc` truly vanishes, else a zombie false-alives); the
**release/reap/close teardown contracts** (which lib functions + their rc semantics); the **set -e
hazards** (every rc-1 lib call guarded); the **scoped-pgrep cleanup assertion** (never false-positives
the operator's Chrome); host-verified prerequisites (real master 45 entries on btrfs, real
`agent-browser` daemon symlink present, `google-chrome-stable` in PATH, `test/validate.sh` LANDED);
the **★ SINGLE-SETUP constraint** (the framework's per-test `setup()` hangs on the 3rd call in this
sandbox, so this file calls `setup()` exactly once and bypasses `run_test`/`abpool_run_suite`);
copy-pasteable Level-1/2 tests.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.18 (Testing & validation — "every test must call release/reap and assert the ephemeral dir
        + Chrome process group are gone"; + AGENT_CHROME_HEADLESS=1 for unattended). §2.5 (Release
        semantics — close = disconnect-only; explicit release + owner-exit → kill pgroup + rm dir +
        delete lease). §2.9 (the release-trigger table). §2.10 (Reaper — lazy, on acquire + on-demand
        `reap`). §2.14 (Failure modes — owner crash → reap; Chrome crash w/ owner alive → relaunch +
        reconnect KEEP lease — the distinction test c honors). §2.8 (lease schema).
  pattern: §2.18 IS the assert-cleanup contract; §2.5 IS the close-!=-release contract; §2.10 IS the
        reaper contract; §2.14 IS the failure-mode resolution for test c.
  gotcha: §2.14 — killing Chrome (owner alive) does NOT make a lane stale; only owner death does.

# The TEST FRAMEWORK this test sources (LANDED by P1.M9.T1.S1 — the contract for every helper)
- file: test/validate.sh
  why: defines _fail, the 5 assertions (assert_eq/assert_lane_exists/assert_lane_gone/assert_no_dir/
        assert_no_chrome), spawn_sim_owner (the `pi`-comm owner engine — REQUIRED for liveness),
        setup (hermetic mktemp isolation + ONE sim owner + AGENT_CHROME_HEADLESS=1; exports
        AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME), teardown (release all as subprocess + kill
        ABPOOL_CUR_OWNER), run_test (subshell-isolated body), abpool_run_suite (enumerate test_* +
        rc 1 on any fail). ALSO sources lib/pool.sh.
  pattern: release_reaper.sh sources validate.sh → inherits ALL helpers + the lib. It adds test_*
        bodies + 3 private helpers (_release_setup_real_env, _release_acquire_boot,
        _release_kill_owner_and_reap_zombie).
  gotcha: setup() makes an EMPTY temp master + resolves POOL_REAL_BIN to a nonexistent temp path →
        _release_setup_real_env overrides BOTH AGENT_CHROME_MASTER + AGENT_BROWSER_REAL. setup() spawns
        ONE sim owner (owner X); tests that need a 2nd owner (test b) call spawn_sim_owner again.

# This task's own research (THE factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M9T3S1/research/codebase-release-reaper-facts.md
  why: §1 the EXACT lib function reference (pool_acquire_locked @2043; _pool_acquire_critical_section
        @1966 REUSE-BEFORE-REAP; pool_boot_lane @2185 → pool_daemon_connect @1631; pool_release_lane
        @2438; _pool_release_lane_internals @1813; pool_chrome_kill @1757; pool_reap_stale @2549;
        pool_lane_is_stale @1164; pool_owner_alive @616; pool_ensure_connected @2288;
        pool_daemon_connected @1689; pool_lease_find_mine @1003; pool_admin_release @3830;
        pool_admin_reap @3730). §2 the lease schema. §3 THE AGENT_BROWSER_REAL GAP (boot needs it).
        §4 the two contract resolutions + the reuse-orphan trap + the M.port==0 reap signal. §5 set -e
        hazards. §6 the zombie-reaping gotcha. §7 the framework-baseline risk. §8 hermetic isolation.
  pattern: §1 IS the lib surface the test drives; §4 IS the test bodies' logic; §6 IS
        _release_kill_owner_and_reap_zombie.
  gotcha: §3 — without AGENT_BROWSER_REAL, every boot fails. §4(b) — reuse-orphan runs BEFORE reap;
        kill Chrome to force reap. §6 — a zombie owner may false-alive; `wait` to reap it.

# The LANDED lib functions the test drives (READ the docstrings — they are the contracts)
- file: lib/pool.sh
  why: pool_owner_resolve @478 (TEST MODE reads the override). pool_acquire_locked @2043 (flock;
        rc 1 exhaustion → GUARD). _pool_acquire_critical_section @1966 (reuse-orphan-before-reap;
        reaps via _pool_release_lane_internals, NOT pool_release_lane — no daemon close under the
        flock). pool_boot_lane @2185 (copy+port+launch+connect; rc 1 → dropped → GUARD).
        pool_release_lane @2438 (daemon close + _pool_release_lane_internals; rc 0 always).
        _pool_release_lane_internals @1813 (chrome_kill + rm dir + rm lease; rc 0 always).
        pool_chrome_kill @1757 (SIGTERM→sleep 0.5→SIGKILL pgroup + bare-pid fallback; idempotent).
        pool_reap_stale @2549 (scan + pool_lane_is_stale + pool_release_lane; rc 0 always).
        pool_lane_is_stale @1164 (tri-state; delegates to pool_owner_alive INVERTED). pool_owner_alive
        @616 (reads REAL /proc; comm=="pi" + starttime match). pool_ensure_connected @2288
        (connected?/reconnect/relaunch; NEVER drops the lane). pool_daemon_connected @1689 (session
        known + curl /json/version). pool_lease_find_mine @1003 (owner's existing live lease).
        pool_lease_field @876 (rc 1 on missing → `|| true` inside $(…)). pool_admin_release @3830 /
        pool_admin_reap @3730 (the admin commands invoked as subprocesses).
  pattern: _release_acquire_boot composes pool_owner_resolve + pool_acquire_locked + pool_boot_lane;
        the release/reap tests invoke "$ABPOOL_ADMIN" release/reap; the close test invokes
        "$POOL_REAL_BIN" --session abpool-N close.
  gotcha: pool_acquire_locked / pool_boot_lane / pool_lease_field / pool_lease_find_mine /
        pool_ensure_connected all return rc 1 on a legitimate failure/missing → bare calls ABORT under
        set -e → GUARD each. pool_release_lane / pool_chrome_kill / pool_lanes_list are rc 0 always.

# The framework PRP (the contract release_reaper.sh consumes — READ to confirm the helper API)
- file: plan/001_0f759fe2777c/P1M9T1S1/PRP.md
  why: the verbatim test/validate.sh body (the helpers + setup/teardown/runner this test sources).
        Confirms: setup exports ONE AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME + AGENT_CHROME_HEADLESS=1
        + overrides HOME/STATE/EPHEMERAL/MASTER (MASTER to an EMPTY temp dir; REAL_BIN to a nonexistent
        temp path — the gaps _release_setup_real_env fixes). teardown runs `"$ABPOOL_ADMIN" release all`
        as a subprocess + kills ABPOOL_CUR_OWNER. spawn_sim_owner returns a settled `pi`-comm PID +
        appends its bin dir to ABPOOL_SIM_BINS (trap removes the DIR, NOT the PID — so extra owners
        spawned in a test body must be killed explicitly). The BASH_SOURCE source-vs-execute gate.
  pattern: release_reaper.sh MIRRORS validate.sh's bootstrap + BASH_SOURCE gate.
  gotcha: validate.sh's selftest_ functions are NOT prefixed test_ → abpool_run_suite test_ in
        release_reaper.sh runs ONLY release_reaper.sh's test_* (no collision).

# The concurrency PRP (the in-flight SIBLING — the pattern to mirror + the AGENT_BROWSER_REAL gap)
- file: plan/001_0f759fe2777c/P1M9T2S1/PRP.md
  why: the verbatim test/concurrency.sh body (the sibling that ALSO sources validate.sh). Its
        _concurrency_setup_master IS the pattern _release_setup_real_env mirrors — EXCEPT it sets
        only AGENT_CHROME_MASTER, NOT AGENT_BROWSER_REAL (a latent gap there; this PRP sets BOTH).
        Its _concurrency_run_one_lane (direct acquire+boot, avoiding the wrapper exec) IS the pattern
        _release_acquire_boot mirrors. Its per-test cleanup discipline (release all as subprocess +
        kill extra sim owners) IS mirrored here.
  pattern: _release_setup_real_env mirrors _concurrency_setup_master (+ AGENT_BROWSER_REAL);
        _release_acquire_boot mirrors _concurrency_run_one_lane (sequential, not parallel).
  gotcha: the concurrency PRP drives acquire+boot DIRECTLY (not the wrapper) for the same reason
        this PRP does — the wrapper's terminal exec hangs a wrapper-driven driving-command test.

# Architecture (host facts + the flock/reuse contract)
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (short-flock acquire split: claim under flock, boot AFTER — reap+reuse inlined in
        the critical section). FINDING 6 (setsid → pgid==pid — what pool_chrome_kill signals).
        FINDING 7 (atomic lease write). FINDING 8 (test-hook overrides — AGENT_BROWSER_POOL_OWNER_PID
        + _STARTTIME simulate distinct agents).
  pattern: FINDING 2 IS why the acquire reap uses _pool_release_lane_internals (no daemon close
        under the flock); FINDING 8 IS the override mechanism the tests exploit.
  gotcha: FINDING 8 sets the IDENTITY; the REAL process must still have comm=="pi" for liveness
        (spawn_sim_owner) AND must be genuinely dead (kill+wait) for staleness.

# External primary sources (URLs — version-stable)
- url: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-wait
  why: the `wait` builtin — reaps a finished child (clears the zombie) AND returns its exit status.
        _release_kill_owner_and_reap_zombie uses `wait "$pid"` so the killed sim-owner's zombie is
        reaped → /proc/$pid vanishes → pool_owner_alive sees it dead.
  critical: without `wait`, a killed child stays a zombie; its /proc/$pid (and possibly comm="pi")
        persist → pool_owner_alive FALSE-ALIVE → the lane is NOT stale → reap/acquire skip it.
- url: https://man7.org/linux/man-pages/man5/proc.5.html
  why: /proc/[pid]/comm (basename of the executed ELF) + /proc/[pid]/stat field 22 (starttime) — the
        two identity tokens pool_owner_alive checks. A zombie retains these until reaped.
  critical: a zombie's comm/starttime may still match → "alive" → must `wait` to clear it.
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "set -e is not a panacea" — commands in if/|| conditions are errexit-exempt → the
        `if ! N="$(pool_acquire_locked)"`, `pool_boot_lane "$N" || { …; return 1; }`, and
        `cpid="$(pool_lease_field …)" || cpid=""` guards keep rc-1 returns non-fatal to the harness.
  critical: a bare `pool_acquire_locked`/`pool_boot_lane`/`pool_lease_field`/`pool_lease_find_mine`/
        `pool_ensure_connected` returning rc 1 ABORTS the test under set -e → GUARD each.
- url: https://man7.org/linux/man-pages/man1/pgrep.1.html
  why: -f matches the FULL command line (how assert_no_chrome scopes to --user-data-dir=$ROOT); rc 1
        on no-match (must be an if-condition, not a bare statement).
  critical: pgrep rc 1 (no match) is the GOOD case → it MUST be the `if` condition (errexit-exempt).
- url: https://linux.die.net/man/1/flock
  why: the canonical `( flock 9; critical_section ) 9>lockfile` idiom + auto-release — the SUT's
        lane-serialization mechanism; release/reap operate OUTSIDE it (lane-local, idempotent).
  critical: flock auto-releases on subshell exit → the lock can never be held by a dead acquirer.
```

### Current Codebase tree

After **M1–M8** landed + **M9.T1.S1** (LANDED: `test/validate.sh`, 13585 bytes, executable) +
**M9.T2.S1** (in-flight: `test/concurrency.sh`), the repo root has `bin/{agent-browser,
agent-browser-pool,.gitkeep}`, `lib/pool.sh` (4302 lines), `install.sh`, `test/{validate.sh,
[concurrency.sh],.gitkeep}`, `PRD.md`, `README.md`, `.gitignore`. **`test/release_reaper.sh` does NOT
exist yet. THIS task creates it:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md                             # install section synced by M10.T1.S1 (NOT this task)
├── install.sh                            # M8.T1.S1 (LANDED) — UNCHANGED
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # M6.T3.S2 (LANDED) — UNCHANGED (ABPOOL_WRAPPER; NOT driven)
│   └── agent-browser-pool                # M7.T5.S1 (LANDED) — UNCHANGED (ABPOOL_ADMIN; release/reap invoked)
├── lib/
│   └── pool.sh                           # UNCHANGED (SOURCED transitively via validate.sh). 4302 lines.
├── test/
│   ├── .gitkeep                          # RETAINED
│   ├── validate.sh                       # M9.T1.S1 (LANDED) — SOURCED by release_reaper.sh (NOT edited)
│   └── concurrency.sh                    # M9.T2.S1 (in-flight) — UNCHANGED sibling
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M9T3S1/
        ├── PRP.md                         # THIS FILE
        └── research/codebase-release-reaper-facts.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── test/
    └── release_reaper.sh                 # NEW (chmod 0755): the CLEANUP + RELEASE-SEMANTICS test.
                                          #   Sources test/validate.sh (LANDED framework). Defines
                                          #   test_explicit_release_tears_down_lane (a),
                                          #   test_stale_reaper_reaps_dead_owner_lane (b),
                                          #   test_reap_clears_crashed_owner_lane (c),
                                          #   test_close_is_disconnect_only (d) + 3 private helpers.
                                          #   Boots REAL headless Chrome per booted lane.
```

**File responsibilities**:
- `test/release_reaper.sh` — the cleanup/release-semantics test. Owns NO pooling logic: it drives the
  LANDED lib's `pool_owner_resolve` / `pool_acquire_locked` / `pool_boot_lane` / `pool_lease_field` /
  `pool_lease_find_mine` / `pool_ensure_connected` + invokes `bin/agent-browser-pool release`/`reap`
  + the real `agent-browser close`. It composes the LANDED framework's helpers (`spawn_sim_owner`,
  `setup`/`teardown`, the 5 assertions, `run_test`/`abpool_run_suite`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the AGENT_BROWSER_REAL gap — make-or-break): the framework's setup() overrides HOME to a
#   temp dir → pool_config_init resolves POOL_REAL_BIN to $TEMP_HOME/.local/bin/agent-browser
#   (NONEXISTENT) + POOL_MASTER_DIR to an EMPTY temp master. pool_boot_lane step e (pool_daemon_connect
#   lib/pool.sh:1631) rc 1's on a missing POOL_REAL_BIN → pool_boot_lane DROPS the lane + rc 1 → EVERY
#   test that boots real Chrome FAILS. _release_setup_real_env exports AGENT_BROWSER_REAL to the REAL
#   daemon binary (resolved via getent passwd, since setup clobbered HOME) + AGENT_CHROME_MASTER to the
#   real master, then re-runs pool_config_init. (research §3.)

# CRITICAL (contract resolution — test c "kill Chrome then reap" is WRONG per PRD §2.14): a Chrome
#   crash with the owner ALIVE → relaunch+reconnect (KEEP lease), NOT reap; pool_reap_stale only reaps
#   DEAD-OWNER lanes. Killing Chrome alone leaves the lane NOT stale → reap does NOTHING. So the
#   simulated crash is the OWNER (kill X); Chrome is left ALIVE (the orphan); reap then kills the
#   orphan Chrome pgroup + rm dir + drop lease. (research §4(c).)

# CRITICAL (reuse-orphan-before-reap — test b): _pool_acquire_critical_section (lib/pool.sh:1966) does
#   reuse-orphan BEFORE reap — if N is stale but N's Chrome answers (pool_daemon_connected rc 0), M
#   ADOPTS N (port>0 KEPT), NOT reaps it. To force the REAP branch, kill N's Chrome pgroup (curl
#   /json/version fails → not adoptable). The clean reap-vs-reuse signal: M.port == 0 ⟺ reap+fresh-
#   claim; M.port > 0 ⟺ reuse. (research §4(b).)

# CRITICAL (the zombie-reaping gotcha): after `kill "$owner_x"`, the sim-owner (child of this shell)
#   becomes a ZOMBIE until the parent waits. A zombie's /proc/$pid + comm may still read "pi"+match →
#   pool_owner_alive FALSE-ALIVE → the lane is NOT stale → reap/acquire skip it → test fails/passes
#   vacuously. _release_kill_owner_and_reap_zombie does `kill PID` + `wait PID` so the zombie is reaped
#   and /proc/$pid vanishes. (research §6.)

# CRITICAL (the comm-liveness coupling): pool_owner_alive (lib/pool.sh:616) reads the REAL /proc/$pid
#   and requires comm=="pi". The override hook sets the lease's owner IDENTITY; it does NOT fake the
#   kernel process. So owner X (setup's sim owner) is LIVE only because spawn_sim_owner made a real
#   "pi"-comm process; making X "dead" requires killing THAT process (+wait to clear the zombie).
#   (research §1, §4(b).)

# CRITICAL (the direct-lib-call seam): the wrapper (bin/agent-browser → pool_wrapper_main lib/pool.sh:3451)
#   TERMINATES via `exec "$POOL_REAL_BIN" …` for driving commands. A wrapper-driven driving-command test
#   would exec into the real agent-browser which may not exit → hang. Driving pool_owner_resolve +
#   pool_acquire_locked + pool_boot_lane DIRECTLY exercises the SAME acquire/boot path WITHOUT the exec.
#   release/reap are admin SUBPROCESSES (quick, exit clean); close is the real-binary command the
#   wrapper exec's, run DIRECTLY (rc 0 on agent-browser 0.28.0). (research §1.)

# CRITICAL (set -e hazards on rc-1 lib calls): pool_acquire_locked (rc 1 exhaustion), pool_boot_lane
#   (rc 1 dropped), pool_lease_field (rc 1 missing), pool_lease_find_mine (rc 1 none), pool_ensure_connected
#   (rc 1 not connected) ALL abort a bare call under set -e (the body runs in `( set -e; "$fn" )`).
#   GUARD each: `if ! N="$(pool_acquire_locked)"`, `pool_boot_lane "$N" || { _fail …; return 1; }`,
#   `cpid="$(pool_lease_field … 2>/dev/null)" || cpid=""`, `if ! reuse="$(pool_lease_find_mine 2>/dev/null)"`,
#   `pool_ensure_connected "$N" || { _fail …; return 1; }`. pool_release_lane / pool_chrome_kill /
#   pool_lanes_list are rc 0 ALWAYS → safe bare. (research §5.)

# GOTCHA (assert_no_chrome is SCOPED): pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT" matches the flag
#   pool_chrome_launch writes → scopes to POOL chrome only → does NOT false-positive the operator's
#   daily-driver Chrome. pgrep rc 1 (no match) is the GOOD case → it is the `if` CONDITION. Use the
#   BOOLEAN form (pgrep >/dev/null), never `pgrep -c` (one Chrome = many processes). (framework gotcha.)

# GOTCHA (extra sim owners are NOT auto-killed): spawn_sim_owner tracks its bin DIR in ABPOOL_SIM_BINS
#   (the EXIT trap removes the DIR) but does NOT track the PID (only ABPOOL_CUR_OWNER, set by setup, is
#   killed by teardown/trap). So owner Y spawned in a test body MUST be killed explicitly
#   (_release_kill_owner_and_reap_zombie) on every exit path — else it lingers ~600s. (research §1.)

# GOTCHA (M may == N's lane number after a reap): pool_find_free_lane returns the LOWEST free lane;
#   after reaping N (=lowest), M may claim N's NUMBER. So test (b) does NOT assert M != N — it asserts
#   the FRESH-CLAIM signals (M.port==0, M.owner.pid==Y, N's dir gone). (research §4(b).)

# GOTCHA (shellcheck SC1091 (info) is EXPECTED + ACCEPTED): `shellcheck -s bash test/release_reaper.sh`
#   emits ONE info: SC1091 on the dynamic `source ./validate.sh` line. This is IDENTICAL to
#   test/validate.sh, test/concurrency.sh, bin/*, AND install.sh — the accepted codebase convention.
#   Validation passes if there are NO error/warning-severity issues.

# GOTCHA (★ SINGLE-SETUP CONSTRAINT — non-negotiable): the framework's run_test/abpool_run_suite
#   call setup() before EACH test; in this sandbox the 3rd setup() call HANGS (a P1.M9.T1.S1
#   accumulation defect). Per a hard directive, NO agent may EVER run a 3rd setup() here. This file
#   BYPASSES run_test/abpool_run_suite and calls setup() EXACTLY ONCE (_abpool_run_release_reaper_suite),
#   with each body spawning its own owner via _test_spawn_owner. DO NOT "restore" abpool_run_suite, and
#   DO NOT run `bash test/validate.sh` (its self-test makes 7 setup() calls → hangs) — Task 0 verifies
#   the framework by SOURCING it + confirming setup() works ONCE, never by running its self-test.
#   (research §7.)
```

## Implementation Blueprint

### Data models and structure

**None NEW.** This task CONSUMES the LANDED lease JSON schema (PRD §2.8): each
`$POOL_LANES_DIR/<N>.json` has top-level `lane`, `ephemeral_dir`, `port`, `session`, `chrome_pid`,
`chrome_pgid`, `connected`, `acquired_at`, `last_seen_at` + nested `owner.{pid,comm,starttime,cwd}`.
The test READS `port`, `chrome_pid`, `chrome_pgid`, `owner.pid` via `pool_lease_field`
(nested-path-aware). It introduces NO on-disk layout change beyond the new `test/release_reaper.sh`
file. Module-level state is the framework's `ABPOOL_*` globals + the lib's `POOL_*` globals
(resolved by `pool_config_init`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + the LANDED surfaces release_reaper.sh consumes + the framework baseline
  - RUN: test -f test/validate.sh && test -x test/validate.sh && echo "OK framework landed"
  - EXPECT: OK (test/validate.sh from P1.M9.T1.S1 — LANDED; host-verified 13585 bytes).
  - RUN (confirm this task is greenfield — NO existing release_reaper.sh):
        test -e test/release_reaper.sh && echo "STOP: release_reaper.sh exists" || echo "OK: release_reaper.sh greenfield"
  - EXPECT: OK: release_reaper.sh greenfield.
  - RUN (★ FRAMEWORK BASELINE — verify WITHOUT running the self-test: the self-test makes 7 setup()
        calls and HANGS on the 3rd in this sandbox. Source the framework + confirm setup() works ONCE):
        bash -c 'set -euo pipefail; source test/validate.sh; \
          test -n "$ABPOOL_ADMIN" || { echo "STOP: framework did not set ABPOOL_ADMIN"; exit 1; }; \
          setup; test -d "$ABPOOL_TEST_ROOT" || { echo "STOP: setup() did not create the temp root"; exit 1; }; \
          teardown; echo "OK framework sourceable + setup() works once"'
  - EXPECT: OK framework sourceable + setup() works once. (Do NOT run `bash test/validate.sh` — its
        self-test calls setup() per selftest and hangs on the 3rd call. release_reaper.sh's single-setup
        runner calls setup() exactly ONCE, so it never hits that hang.)
  - RUN (confirm the framework defines the helpers + runner release_reaper.sh sources):
        bash -c 'set -euo pipefail; source test/validate.sh; \
          for f in _fail assert_eq assert_lane_exists assert_lane_gone assert_no_dir assert_no_chrome \
                   spawn_sim_owner setup teardown run_test abpool_run_suite; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; echo "OK framework helpers defined"'
  - EXPECT: OK framework helpers defined (validate.sh LANDED).
  - RUN (confirm the lib functions release_reaper.sh drives are defined — sourced transitively):
        bash -c 'set -euo pipefail; source test/validate.sh; \
          for f in pool_owner_resolve pool_acquire_locked pool_boot_lane pool_release_lane \
                   pool_reap_stale pool_lease_field pool_lease_find_mine pool_ensure_connected \
                   pool_config_init pool_state_init _pool_get_starttime; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; echo "OK lib fns defined"'
  - EXPECT: OK lib fns defined (all LANDED).
  - RUN (confirm real-Chrome + real-daemon prerequisites — required for the boots):
        real_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
        test -d "$real_home/.agent-chrome-profiles/master-profile" && \
          [[ -n "$(ls -A "$real_home/.agent-chrome-profiles/master-profile" 2>/dev/null)" ]] && echo "OK real master non-empty"
        [[ "$(stat -f -c %T "$real_home/.agent-chrome-profiles/master-profile")" == "btrfs" ]] && echo "OK btrfs"
        command -v google-chrome-stable >/dev/null && echo "OK chrome in PATH"
        [[ -x "$real_home/.local/bin/agent-browser" ]] && echo "OK real agent-browser daemon present"
  - EXPECT: all OK (host-verified 2026-07-13). If the real daemon is absent, _release_setup_real_env
        _fail's clearly (boot/release/close/reap need it).
  - RUN (confirm the release/reap wiring the tests invoke):
        grep -q 'release)' bin/agent-browser-pool && grep -q 'pool_admin_release' lib/pool.sh && echo "OK release wired"
        grep -q 'reap)' bin/agent-browser-pool && grep -q 'pool_admin_reap' lib/pool.sh && echo "OK reap wired"
  - EXPECT: release + reap wired (pool_admin_release @3830; pool_admin_reap @3730).
  - RUN (confirm shellcheck SC1091 is the ONLY emission on the LANDED validate.sh — the convention):
        shellcheck -s bash test/validate.sh 2>&1 | grep -E 'SC[0-9]+' | sort -u
  - EXPECT: only SC1091 (info). release_reaper.sh's source line will emit the same.
  - RUN: bash -n test/validate.sh && echo "OK framework syntax (baseline preserved)"
  - EXPECT: OK (this task only SOURCES validate.sh — must not break existing syntax).

Task 1: CREATE test/release_reaper.sh (the verbatim body, executable)
  - PLACEMENT: test/release_reaper.sh (NEW file in test/ — alongside the LANDED validate.sh + retained
        .gitkeep + the in-flight concurrency.sh).
  - IMPLEMENT: paste the verbatim body from the "What → The test/release_reaper.sh body" section above,
        EXACTLY (shebang + header + set -euo pipefail + RELEASE_DIR resolution + source validate.sh +
        _release_setup_real_env + _release_acquire_boot + _release_kill_owner_and_reap_zombie + the
        four test_* functions + the BASH_SOURCE gate). Then `chmod 0755 test/release_reaper.sh`.
  - MAKE EXECUTABLE: chmod 0755 test/release_reaper.sh
  - NOTE on the `# shellcheck source=./validate.sh` directive: it is a HINT for editors/`shellcheck
        -x`; `shellcheck -s bash test/release_reaper.sh` (without -x) still emits SC1091 (info) on the
        dynamic source — that is ACCEPTED (matches validate.sh + concurrency.sh + bin/* + install.sh).
  - VERIFY (immediately after):
        bash -n test/release_reaper.sh && echo "OK syntax"
        shellcheck -s bash test/release_reaper.sh; echo "(SC1091 info on the source line is ACCEPTED)"
        test -x test/release_reaper.sh && echo "OK executable"
        test -f test/.gitkeep && test -f test/validate.sh && echo "OK siblings retained"
        git status --short | grep -qvE '^\?\? test/release_reaper\.sh$|^\?\? test/concurrency\.sh$|plan/' && echo "STOP: unexpected change!" || echo "OK only release_reaper.sh new"
  - EXPECT: OK syntax; shellcheck shows at most SC1091 (info); OK executable; siblings retained;
        git status shows ONLY release_reaper.sh (untracked) outside plan/ (concurrency.sh may also be
        untracked if M9.T2.S1 landed in the same window — that is the sibling, not this task's concern).

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY `test/release_reaper.sh` (new untracked) outside plan/ (plan/ changes are this PRP +
        research). lib/pool.sh, bin/*, install.sh, test/validate.sh, test/.gitkeep, .gitignore, PRD.md,
        README.md, tasks.json, prd_snapshot.md UNCHANGED. NO edits to validate.sh, NO second test file
        beyond release_reaper.sh.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe repo resolution (mirror test/validate.sh + concurrency.sh):
RELEASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$RELEASE_DIR/validate.sh"
#   readlink -f canonicalizes release_reaper.sh; dirname → test/; cd && pwd → absolute; source the
#   sibling validate.sh (which sources the lib).

# PATTERN — the real-env setup (the AGENT_BROWSER_REAL gap fix — MANDATORY):
_release_setup_real_env() {
    local real_home real_master real_bin
    real_home="$(getent passwd "${USER:-$(id -un)}" | cut -d: -f6)"   # REAL home (setup clobbered HOME)
    real_master="$real_home/.agent-chrome-profiles/master-profile"
    real_bin="$real_home/.local/bin/agent-browser"
    if [[ -d "$real_master" ]] && [[ -n "$(ls -A "$real_master" 2>/dev/null)" ]]; then
        export AGENT_CHROME_MASTER="$real_master"      # read-only; reflink CoW → safe
    else
        local m="$ABPOOL_TEST_ROOT/master-real"; mkdir -p -- "$m/Default"
        printf '{"minimal":true}' >"$m/Preferences"; export AGENT_CHROME_MASTER="$m"
    fi
    [[ -x "$real_bin" ]] || { _fail "real agent-browser not found at $real_bin"; return 1; }
    export AGENT_BROWSER_REAL="$real_bin"
    pool_config_init; pool_state_init                  # re-resolve POOL_MASTER_DIR + POOL_REAL_BIN
}

# PATTERN — the owner-crash simulation (kill + REAP the zombie so /proc vanishes):
_release_kill_owner_and_reap_zombie() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true      # reaps the zombie → /proc/$pid gone → pool_owner_alive DEAD
}

# PATTERN — the acquire+boot seam (direct lib calls; avoids the wrapper's terminal exec):
_release_acquire_boot() {
    local N port
    pool_owner_resolve
    if ! N="$(pool_acquire_locked)"; then _fail "acquire failed"; return 1; fi
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        if ! pool_boot_lane "$N"; then _fail "boot failed lane $N"; return 1; fi
    fi
    printf '%s\n' "$N"
}

# PATTERN — force the reap branch (defeat reuse-orphan) + the reap signal:
#   after killing owner X, kill N's Chrome pgroup: `kill -9 -- -"$pgid" 2>/dev/null || true`
#   then acquire M as Y → assert `M.port == 0` (reap+fresh-claim; NOT reuse which keeps port>0).

# PATTERN — scoped cleanup assertion (does NOT false-positive the operator's Chrome):
"$ABPOOL_ADMIN" release "$N" >/dev/null 2>&1 || true   # subprocess (pool_die can't kill harness)
assert_lane_gone "$N"                                   # lease file AND ephemeral dir gone
assert_no_chrome                                        # pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"

# PATTERN — the SINGLE-SETUP runner (★ non-negotiable — NEVER call setup() a 3rd time):
_abpool_run_release_reaper_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ONE setup() — its owner is unused (bodies spawn their own)
    _release_kill_owner_and_reap_zombie "$AGENT_BROWSER_POOL_OWNER_PID"; ABPOOL_CUR_OWNER=""
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'       # main shell, NOT a subshell
        else          ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true                     # inter-body backstop
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _release_kill_owner_and_reap_zombie "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
    done
    teardown
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    (( ABPOOL_FAIL > 0 )) && { printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2; return 1; }
    return 0
}
#   `if "$fn"; then` runs the body in a CONDITIONAL → errexit is disabled inside it → the body's
#   explicit `|| return 1` / `if !` guards drive control flow; a failing assert's `return 1` is the
#   function's rc → FAIL → the suite continues. NO subshell → the EXIT trap does NOT fire between
#   bodies → the temp root survives all four. setup() is invoked EXACTLY ONCE.

# GOTCHA — WHY single setup + main-shell bodies (★): the framework's run_test/abpool_run_suite call
#   setup() per test; the 3rd setup() HANGS in this sandbox. ONE setup() + `if "$fn"` bodies (no
#   subshell) sidestep that AND keep the EXIT trap from firing mid-suite (which would rm the temp root).

# GOTCHA — WHY direct lib calls (not the wrapper): the wrapper exec's into the real agent-browser for
#   driving commands (may not exit) → hang. Direct acquire+boot/release/close test the SAME code path.
#   (research §codebase-1.)
# GOTCHA — WHY wait after kill (zombie): a zombie's /proc/comm may still read "pi" → false-alive → the
#   lane is NOT stale → reap/acquire skip it. `wait` clears the zombie. (research §6.)
# GOTCHA — WHY kill Chrome in test b (force reap): reuse-orphan runs BEFORE reap in the acquire critical
#   section; an adoptable (responsive-Chrome) stale lane is ADOPTED, not reaped. (research §4(b).)
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "test/release_reaper.sh (NEW; chmod 0755; in test/ — alongside the LANDED validate.sh +
            retained .gitkeep + the in-flight concurrency.sh). Verbatim body from the 'What' section."

FRAMEWORK (test/validate.sh — SOURCED, not edited):
  - sources: "release_reaper.sh does 'source "$RELEASE_DIR/validate.sh"' → joins validate.sh as the
            THIRD consumer (M9.T2 concurrency is second; M9.T4 will be fourth). validate.sh sources
            lib/pool.sh, so release_reaper.sh does NOT re-source it."
  - calls:   "spawn_sim_owner (the 2nd owner Y in test b); setup/teardown (via run_test); the 5
            assertions; run_test/abpool_run_suite (the runner)."
  - consumes (env from setup): "AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME (owner X); HOME +
            AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT + AGENT_CHROME_MASTER (overridden
            by _release_setup_real_env) + AGENT_BROWSER_REAL (overridden by _release_setup_real_env)
            + AGENT_CHROME_HEADLESS=1."

LIBRARY (lib/pool.sh — SOURCED transitively via validate.sh, not edited):
  - calls: "pool_owner_resolve @478; pool_acquire_locked @2043; pool_boot_lane @2185;
            pool_lease_field @876; pool_lease_find_mine @1003; pool_ensure_connected @2288;
            _pool_get_starttime @404; pool_config_init @126; pool_state_init @202."
  - consumes (env): "AGENT_BROWSER_POOL_OWNER_PID + _STARTTIME (pool_owner_resolve @478);
            AGENT_CHROME_MASTER (pool_config_init → POOL_MASTER_DIR); AGENT_BROWSER_REAL
            (pool_config_init → POOL_REAL_BIN); AGENT_CHROME_HEADLESS (pool_config_init →
            POOL_HEADLESS → pool_chrome_launch adds --headless=new)."

BINARIES (invoked as subprocesses by the tests):
  - invokes: "'$ABPOOL_ADMIN' release N (bin/agent-browser-pool → pool_admin_release @3830) in test a;
            '$ABPOOL_ADMIN' reap (→ pool_admin_reap @3730 → pool_reap_stale @2549) in test c; both AS
            A SUBPROCESS (|| true) so a pool_die cannot kill the harness. teardown also runs
            '$ABPOOL_ADMIN' release all."
  - invokes: "'$POOL_REAL_BIN' --session abpool-N close in test d (the SAME command the wrapper exec's;
            run DIRECTLY to avoid the terminal exec; rc 0 on agent-browser 0.28.0)."
  - references: "ABPOOL_WRAPPER (bin/agent-browser) is NOT driven by this test (the wrapper exec's →
            the test drives acquire+boot/release/close directly)."

DOWNSTREAM CONTRACT (what M9.T4 sees):
  - pattern: "M9.T4 is a SIBLING file that ALSO sources test/validate.sh + defines its own test_*
            bodies + its own BASH_SOURCE gate. release_reaper.sh does NOT export anything it depends
            on (its _release_* helpers are private, underscore-prefixed)."

GITIGNORE:
  - no change: "no rule matches test/release_reaper.sh (it is a tracked repo file). .gitignore is
            orchestrator-owned (M10.T1.S2)."

NO CHANGES TO:
  - lib/pool.sh (sourced transitively, not edited), test/validate.sh (sourced, not edited),
    test/concurrency.sh (the in-flight sibling, not edited), bin/agent-browser (M6.T3.S2),
    bin/agent-browser-pool (M7.T5.S1), install.sh (M8.T1.S1), .gitignore, PRD.md / tasks.json /
    prd_snapshot.md (read-only), README.md (M10.T1.S1), test/.gitkeep (retained). NO second test file
    beyond release_reaper.sh, NO docs (item §5: test code, no user-facing surface).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating test/release_reaper.sh + chmod 0755 — fix before proceeding.
bash -n test/release_reaper.sh && echo "OK bash -n"
shellcheck -s bash test/release_reaper.sh; echo "(SC1091 info on the dynamic source line is ACCEPTED — matches test/validate.sh + concurrency.sh + bin/* + install.sh)"
test -x test/release_reaper.sh && echo "OK executable"
# Equivalently, a fully-silent shellcheck run (excludes the accepted info):
shellcheck --exclude=SC1091 -s bash test/release_reaper.sh && echo "OK shellcheck (--exclude=SC1091)"
# Confirm ONLY test/release_reaper.sh is new (no collateral edits):
git status --short | grep -vE 'plan/|^\?\? test/release_reaper\.sh$|^\?\? test/concurrency\.sh$' && echo "STOP: unexpected change" || echo "OK only release_reaper.sh new"
# Expected: OK bash -n; shellcheck shows at most SC1091 (info); OK executable; only release_reaper.sh new.
#   SC2155 does NOT fire (every $(…) capture is split: local x; x="$(…)" — owner_y/st_y/N/port/etc.,
#   and the _pool_get_starttime/spawn_sim_owner captures). SC2086 satisfied by quoting "$RELEASE_DIR/...",
#   "$ABPOOL_ADMIN", "$POOL_REAL_BIN", "${BASH_SOURCE[0]}", "$owner_x", "$pgid". The `(( ))`/`[[ =~ ]]`
#   are inside `if`/`while` (exempt). The `|| true`/`|| cpid=""` lists are errexit-exempt.
```

### Level 2: Functional Tests (HERMETIC — real Chrome booted under the temp tree)

The release/reaper tests boot REAL headless Chrome (one instance per booted lane: tests a/c/d boot
one each, test b boots one + a provisional second). They need the real master profile + btrfs +
`google-chrome-stable` + the REAL `agent-browser` daemon binary (ALL host-verified present). The tests
create files/processes ONLY under the framework's `mktemp` temp root; the operator's real
`~/.local/state/agent-browser-pool/` + real daily-driver Chrome are NEVER touched.

```bash
# Run from the REPO ROOT. First, clean any leftover sim-owner/Chrome from prior runs:
pkill -9 -f 'abpool-pi' 2>/dev/null; pkill -9 -f 'user-data-dir=/tmp/abpool' 2>/dev/null; rm -rf /tmp/abpool-test.* /tmp/abpool-pi.* 2>/dev/null; sleep 1

# Case 1 — the full suite passes (the primary contract; boots 4 real headless Chromes total):
bash test/release_reaper.sh; echo "rc=$?"
# Expected: prints "== test_explicit_release_tears_down_lane" + "   PASS" + "== test_stale_reaper_reaps_dead_owner_lane"
#   + "   PASS" + "== test_reap_clears_crashed_owner_lane" + "   PASS" + "== test_close_is_disconnect_only"
#   + "   PASS" + "4 passed, 0 failed"; rc=0. Wall time ~10-30s (4 Chrome boots ~1-3s each + teardowns).
#   Verifies: (a) release N → dir/Chrome/lease gone; (b) dead-owner+non-responsive lane reaped
#   (M.port==0); (c) owner crash → reap kills orphan Chrome + rm dir + drop lease; (d) close leaves
#   Chrome/dir/lease alive + next cmd reuses lane N + reconnects.

# Case 2 — isolation: the test must NOT touch the real pool state. Snapshot first:
before="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
bash test/release_reaper.sh >/dev/null 2>&1
after="$(ls -1 ~/.local/state/agent-browser-pool/lanes/ 2>/dev/null | wc -l)"
[[ "$before" == "$after" ]] && echo "OK: real state untouched" || echo "FAIL: real state changed ($before → $after)"
# Expected: OK (HOME + AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT overridden to a temp root
#   in setup; AGENT_CHROME_MASTER points at the read-only real master — never written; AGENT_BROWSER_REAL
#   points at the real daemon — operates on temp-scoped sessions).

# Case 3 — NEGATIVE: a forced failure must NOT kill the harness + must yield rc 1.
#   Uses the SAME single-setup pattern as release_reaper.sh (NOT abpool_run_suite — that calls setup()
#   per test and hangs on the 3rd here). ONE setup(), one failing body via `if "$fn"`, expect rc 1.
cat >/tmp/neg_rel.sh <<'EOF'
set -euo pipefail
source test/validate.sh
test_force_fail() {
    assert_eq "reaped" "LEAKED" "forced reaper leak"
}
setup
rc=0; if test_force_fail; then rc=0; else rc=1; fi
teardown
if (( rc == 1 )); then echo "OK: a failing body yields rc 1 (non-fatal runner)"; exit 0; fi
echo "FAIL: a failing body should yield rc 1"; exit 1
EOF
bash /tmp/neg_rel.sh; echo "rc=$?"; rm -f /tmp/neg_rel.sh
# Expected: "OK: a failing body yields rc 1 (non-fatal runner)"; rc=0 (the wrapper's exit). Proves a
#   failing assert (return 1) is captured as the body's rc without aborting the harness — the exact
#   contract _abpool_run_release_reaper_suite relies on.

# Case 4 — no leftover processes/dirs after the suite (PRD §2.18 cleanup contract):
bash test/release_reaper.sh >/dev/null 2>&1
n_pi="$(pgrep -fc 'abpool-pi' 2>/dev/null || printf 0)"; [[ "$n_pi" == "0" ]] && echo "OK: no leftover sim-owner bins running" || echo "WARN: $n_pi leftover pi"
n_chrome="$(pgrep -fc 'user-data-dir=/tmp/abpool' 2>/dev/null || printf 0)"; [[ "$n_chrome" == "0" ]] && echo "OK: no leftover test Chrome" || echo "WARN: $n_chrome leftover Chrome"
# Expected: OK / OK (the trap + teardown + the bodies' release-all kill the sim owners + Chromes; the
#   temp roots are removed by the framework's EXIT trap).

# Case 5 — the real master is never mutated (read-only contract, PRD §2.7):
before_cksum="$(find ~/.agent-chrome-profiles/master-profile -type f -printf '%s %p\n' 2>/dev/null | sort | cksum)"
bash test/release_reaper.sh >/dev/null 2>&1
after_cksum="$(find ~/.agent-chrome-profiles/master-profile -type f -printf '%s %p\n' 2>/dev/null | sort | cksum)"
[[ "$before_cksum" == "$after_cksum" ]] && echo "OK: real master unchanged" || echo "FAIL: real master mutated"
# Expected: OK (reflink CoW shares blocks; the master is read-only; reflink copies are written to the
#   TEMP ephemeral root, never back to the master).
```

### Level 3: Integration Testing (the SUT's real teardown behavior)

```bash
# Verify the tests actually exercise the real teardown (not mocks): drive one lane manually + confirm
# release/reap tear it down exactly as the tests assert.
bash -c '
  set -euo pipefail
  source test/validate.sh
  setup
  real_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  export AGENT_CHROME_MASTER="$real_home/.agent-chrome-profiles/master-profile"
  export AGENT_BROWSER_REAL="$real_home/.local/bin/agent-browser"
  pool_config_init; pool_state_init
  pool_owner_resolve
  N="$(pool_acquire_locked)"; pool_boot_lane "$N"
  port="$(pool_lease_field "$N" port)"; cpid="$(pool_lease_field "$N" chrome_pid)"
  echo "booted lane $N: port=$port chrome_pid=$cpid"
  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "Chrome ALIVE (pre-release)"
  "$ABPOOL_ADMIN" release "$N" >/dev/null 2>&1 || true
  sleep 0.5
  [[ -e "$POOL_LANES_DIR/$N.json" ]] && echo "FAIL: lease remains" || echo "OK: lease gone"
  [[ -e "$POOL_EPHEMERAL_ROOT/$N" ]] && echo "FAIL: dir remains" || echo "OK: dir gone"
  pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT" >/dev/null && echo "FAIL: chrome remains" || echo "OK: chrome gone"
  teardown
'
# Expected: booted lane 1: port=53420+ chrome_pid=<pid>; Chrome ALIVE; then OK lease gone / OK dir gone /
#   OK chrome gone. Proves pool_release_lane → _pool_release_lane_internals → pool_chrome_kill works
#   end-to-end against a real boot — exactly what test (a) asserts.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Domain-specific: these tests ARE the domain validation (PRD §2.18). Additional checks:

# (a) Confirm the reap ACTUALLY kills the orphan Chrome (test c's strong claim): inspect the chrome
#     pid pre-reap + confirm it is GONE post-reap (not just assert_no_chrome's boolean).
bash -c '
  set -euo pipefail; source test/validate.sh; setup
  real_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  export AGENT_CHROME_MASTER="$real_home/.agent-chrome-profiles/master-profile"
  export AGENT_BROWSER_REAL="$real_home/.local/bin/agent-browser"
  pool_config_init; pool_state_init; pool_owner_resolve
  N="$(pool_acquire_locked)"; pool_boot_lane "$N"
  cpid="$(pool_lease_field "$N" chrome_pid)"; owner_x="$AGENT_BROWSER_POOL_OWNER_PID"
  echo "chrome_pid=$cpid alive_pre=$(curl -sf http://127.0.0.1:$(pool_lease_field "$N" port)/json/version >/dev/null && echo yes || echo no)"
  kill "$owner_x" 2>/dev/null || true; wait "$owner_x" 2>/dev/null || true
  "$ABPOOL_ADMIN" reap >/dev/null 2>&1 || true; sleep 0.5
  # The specific chrome leader must be DEAD (the reaper killed the orphan pgroup).
  if [[ -d "/proc/$cpid" ]]; then echo "FAIL: chrome leader $cpid still in /proc"; else echo "OK: chrome leader $cpid reaped"; fi
  teardown
'
# Expected: chrome_pid=<pid> alive_pre=yes; OK: chrome leader <pid> reaped. Proves the reaper's
#   pool_chrome_kill (SIGTERM→SIGKILL pgroup) killed the still-alive orphan Chrome.

# (b) Confirm close leaves Chrome ALIVE + find_mine reuses (test d's claim) end-to-end:
bash -c '
  set -euo pipefail; source test/validate.sh; setup
  real_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  export AGENT_CHROME_MASTER="$real_home/.agent-chrome-profiles/master-profile"
  export AGENT_BROWSER_REAL="$real_home/.local/bin/agent-browser"
  pool_config_init; pool_state_init; pool_owner_resolve
  N="$(pool_acquire_locked)"; pool_boot_lane "$N"
  port="$(pool_lease_field "$N" port)"
  "$POOL_REAL_BIN" --session "abpool-$N" close >/dev/null 2>&1 || true; sleep 0.4
  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK: chrome alive after close" || echo "FAIL: chrome died on close"
  reuse="$(pool_lease_find_mine 2>/dev/null)" && [[ "$reuse" == "$N" ]] && echo "OK: find_mine reuses lane $N" || echo "FAIL: find_mine=$reuse"
  teardown
'
# Expected: OK: chrome alive after close; OK: find_mine reuses lane 1.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n test/release_reaper.sh` passes.
- [ ] `shellcheck -s bash test/release_reaper.sh` → only SC1091 (info); NO error/warning severity.
- [ ] `bash test/release_reaper.sh` → `4 passed, 0 failed`, rc 0 (boots 4 real headless Chromes total).
- [ ] A forced failure → `abpool_run_suite` returns rc 1 (Case 3, Level 2).
- [ ] Isolation: the real `~/.local/state/agent-browser-pool/lanes/` count unchanged (Case 2).
- [ ] No leftover sim-owner processes / test Chrome / temp roots after the suite (Case 4).
- [ ] The real master profile is never mutated (Case 5).

### Feature Validation

- [ ] `test_explicit_release_tears_down_lane` (a): boots N; `"$ABPOOL_ADMIN" release N`; asserts
      `assert_lane_gone N` + `assert_no_chrome`.
- [ ] `test_stale_reaper_reaps_dead_owner_lane` (b): boots N as X; kill+wait X; kill N's Chrome pgroup;
      spawn Y + acquire M as Y; asserts `M.port==0` (reap not reuse) + `M.owner.pid==Y` +
      `assert_lane_exists M` + `assert_no_dir $POOL_EPHEMERAL_ROOT/$N`; release all + reap Y.
- [ ] `test_reap_clears_crashed_owner_lane` (c): boots N as X; sanity Chrome alive (curl); kill+wait X;
      `"$ABPOOL_ADMIN" reap`; asserts `assert_lane_gone N` + `assert_no_chrome`.
- [ ] `test_close_is_disconnect_only` (d): boots N; `"$POOL_REAL_BIN" --session abpool-N close`; asserts
      lease present + dir exists + Chrome alive (curl); `pool_lease_find_mine` == N;
      `pool_ensure_connected N` rc 0.
- [ ] `_release_setup_real_env` exports `AGENT_CHROME_MASTER` (real/minimal) AND `AGENT_BROWSER_REAL`
      (real daemon; `_fail` if absent) + re-runs `pool_config_init`/`pool_state_init`.
- [ ] `_release_acquire_boot` drives `pool_owner_resolve` + `pool_acquire_locked` + `pool_boot_lane`
      directly (NOT the wrapper) — avoiding the terminal exec hang.
- [ ] `_release_kill_owner_and_reap_zombie` does `kill PID` + `wait PID` (clears the zombie so
      `/proc/PID` vanishes).
- [ ] Cleanup is `"$ABPOOL_ADMIN" release …` as a subprocess (pool_die-safe) + the scoped
      `assert_no_chrome` (no false-positive on the operator's Chrome).

### Code Quality Validation

- [ ] Follows existing codebase patterns (`set -euo pipefail`, symlink-safe `${BASH_SOURCE[0]}`
      bootstrap mirroring validate.sh + concurrency.sh + bin/*, 2-statement `$(…)` captures,
      `(( ))`/`[[ =~ ]]` only inside `if`/`while`, subprocess release/reap, direct-lib-call seam).
- [ ] File placement matches the desired tree (`test/release_reaper.sh`).
- [ ] Anti-patterns avoided (no wrapper-driven driving-command that would hang on exec; no bare
      `pool_acquire_locked`/`pool_boot_lane`/`pool_lease_field`/`pool_lease_find_mine`/
      `pool_ensure_connected` (all rc-1-guarded); no bare `kill`/`curl`/`pgrep` (all `|| true` or in
      `if`); no `pgrep -c` for Chrome; no `local x="$(…)"`; no `(( PASS++ ))`; no inline
      pool_die-capable calls in the cleanup; no leaving owner Y un-killed on a return path).
- [ ] The framework + lib are SOURCED not edited; `bin/*` + `install.sh` + `test/validate.sh` +
      `test/concurrency.sh` + `test/.gitkeep` unchanged.

### Documentation & Deployment

- [ ] Code is self-documenting (helper + test doc-comments explain the AGENT_BROWSER_REAL gap, the
      two contract resolutions, the reuse-orphan-before-reap trap, the zombie-reaping gotcha, the
      M.port==0 reap signal, the close-!=-release semantics).
- [ ] No user-facing docs (item §5: test code, no user-facing surface) — README sync is M10.T1.S1.
- [ ] No new env vars introduced (consumes LANDED overrides + the framework's setup exports only;
      `_release_setup_real_env` exports `AGENT_CHROME_MASTER` + `AGENT_BROWSER_REAL` which are LANDED
      `pool_config_init` env vars, not new).

---

## Anti-Patterns to Avoid

- ❌ ★ Don't call `setup()` more than ONCE, and DON'T use `run_test`/`abpool_run_suite` — they call
  `setup()` before each test and the 3rd `setup()` call HANGS in this sandbox (a P1.M9.T1.S1
  accumulation defect; HARD DIRECTIVE: no agent may ever run a 3rd `setup()`). Use the file's
  `_abpool_run_release_reaper_suite` (ONE `setup()`; bodies via `if "$fn"` in the main shell — no
  subshell, so the EXIT trap never fires mid-suite). Each body spawns its OWN owner via
  `_test_spawn_owner` (tests c/b kill theirs, so they can't share setup's). And DON'T run
  `bash test/validate.sh` to "check the framework" — its self-test makes 7 `setup()` calls and hangs.
- ❌ Don't drive the WRAPPER (`"$ABPOOL_WRAPPER" open/close …`) for a driving command — it `exec`s
  into the real agent-browser which may not exit → hang. Drive `pool_owner_resolve` +
  `pool_acquire_locked` + `pool_boot_lane` DIRECTLY; invoke `release`/`reap` as admin subprocesses;
  invoke `close` as `"$POOL_REAL_BIN" --session abpool-N close` directly. (close DOES exit rc 0 on
  agent-browser 0.28.0, so it's safe to run directly — but NOT via the wrapper's full lifecycle.)
- ❌ Don't skip `_release_setup_real_env` — the framework's `setup()` makes `POOL_REAL_BIN` nonexistent
  (temp HOME) + the master empty → `pool_boot_lane` fails → every boot test fails. You MUST export
  `AGENT_BROWSER_REAL` (real daemon) + `AGENT_CHROME_MASTER` (real master) + re-run `pool_config_init`.
- ❌ Don't rely on the env override ALONE to make an owner dead — `pool_owner_alive` reads the REAL
  `/proc`; kill the sim-owner process (+ `wait` to reap the zombie so `/proc` vanishes). A zombie may
  still read comm="pi" → false-alive.
- ❌ Don't kill CHROME (owner alive) and expect `reap` to clear the lane — PRD §2.14: Chrome crash w/
  owner alive → relaunch+reconnect (KEEP lease), NOT reap. The crash must be the OWNER; `reap` then
  kills the orphan Chrome.
- ❌ Don't expect the stale reaper to REAP a lane whose Chrome is still responsive — the acquire
  critical section does reuse-orphan BEFORE reap; an adoptable lane is ADOPTED (port>0), not reaped.
  Kill the Chrome pgroup to force the reap branch; assert `M.port==0` to PROVE reap.
- ❌ Don't assert `M != N` after a reap — `pool_find_free_lane` returns the lowest free lane, which
  after reaping N is N's number. Assert the FRESH-CLAIM signals (`M.port==0`, `M.owner.pid==Y`,
  N's dir gone) instead.
- ❌ Don't call `pool_acquire_locked` / `pool_boot_lane` / `pool_lease_field` / `pool_lease_find_mine` /
  `pool_ensure_connected` bare under set -e — they return rc 1 on a legitimate failure/missing →
  ABORT the test. GUARD each (`if ! …`, `|| { _fail …; return 1; }`, `|| var=""` inside `$(…)`).
- ❌ Don't use `pgrep -c` to assert "no Chrome left" — one Chrome is many processes. Use the boolean
  `pgrep -f -- "user-data-dir=$ROOT" >/dev/null` inside `if` (assert_no_chrome does this).
- ❌ Don't use `kill -0` for liveness — it conflates ESRCH (dead) and EPERM (foreign-alive). Use
  `curl -sf http://127.0.0.1:$port/json/version` (Chrome) or `pgrep` / `/proc` (process).
- ❌ Don't call `pool_admin_release`/`pool_admin_reap` (or any pool_die-capable function) INLINE —
  run `"$ABPOOL_ADMIN" release/reap …` as a SUBPROCESS (`|| true`) so a config error can't exit the
  harness shell.
- ❌ Don't leave the 2nd sim owner (Y) un-killed on a return path — `spawn_sim_owner` tracks only its
  bin DIR (trap removes the dir), NOT its PID. Kill Y (`_release_kill_owner_and_reap_zombie`) on every
  early-return + at the end of test (b), else it lingers ~600s.
- ❌ Don't use `(( PASS++ ))` / bare `(( 0 ))` (aborts under set -e) — use `$(( ))` expansion or put
  `(( ))` inside `if`/`while`.
- ❌ Don't launch real Chrome against the operator's REAL ephemeral root — `setup()` overrides
  `AGENT_CHROME_EPHEMERAL_ROOT` to a temp root; `AGENT_CHROME_MASTER` points at the read-only real
  master (never written); `AGENT_BROWSER_REAL` points at the real daemon (operates on temp-scoped
  sessions). Hermetic isolation is mandatory.
- ❌ Don't create new patterns when existing ones work — mirror `test/validate.sh` +
  `test/concurrency.sh` for the bootstrap, shebang, chmod, shellcheck-SC1091-OK convention + the
  framework's helper API + the direct-lib-call seam.
```
