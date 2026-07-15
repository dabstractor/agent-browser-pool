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

    # btrfs ephemeral root (HOST-SPECIFIC): setup's AGENT_CHROME_EPHEMERAL_ROOT points under
    # /tmp, which is tmpfs on this host. pool_copy_master does `cp --reflink=always master →
    # ephemeral`, which FAILS on tmpfs and pool_die's (PRD §2.19) → Chrome can't boot. Re-point
    # the ephemeral root at a btrfs temp dir under the real home (btrfs here): the reflink CoW
    # copy from the read-only real master is instant + ~0 space, the dir is test-specific, and
    # it is reaped by the EXIT trap (ABPOOL_SIM_BINS is the framework's rm list; this runs in
    # the MAIN shell — bodies run via `if "$fn"` — so the append survives to the trap).
    local eph_root
    eph_root="$(mktemp -d "$real_home/abpool-test-eph.XXXXXX")"
    export AGENT_CHROME_EPHEMERAL_ROOT="$eph_root"
    ABPOOL_SIM_BINS+=("$eph_root")

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
    # Refresh the POOL_OWNER_* GLOBALS in THIS shell from the env just exported. REQUIRED when
    # this helper runs in the current shell (`_test_spawn_owner >/dev/null`, tests a/c/d): the
    # lane is then acquired via `N="$(...)"` — a subshell whose internal pool_owner_resolve does
    # NOT propagate back here — and pool_lease_find_mine (test d) runs in THIS shell reading
    # POOL_OWNER_PID. Without this, the global stays stale (setup's owner, which the runner
    # killed) → find_mine finds nothing → test d fails for the wrong reason. (When this helper
    # is itself called via `owner_x="$(...)"` — a subshell, test b — this call is lost, but
    # test b resolves its own owner in the parent, so it is unaffected.)
    pool_owner_resolve
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

    # (1) Owner X (this body's own sim owner) acquires + boots lane N. Spawn X in the CURRENT
    #     shell (NOT via `$(…)`) so X's owner env + POOL_OWNER_* globals propagate to this body;
    #     N's acquire (a subshell) then inherits X, so N is genuinely OWNED by X. (A `$()` here
    #     would lose X's export → N would be owned by a prior test's dead owner → the "X crashes"
    #     step below would kill the wrong process and the reaper would pass VACUOUSLY.)
    local N cpid pgid owner_x
    _test_spawn_owner >/dev/null
    owner_x="$ABPOOL_CUR_OWNER"         # _test_spawn_owner registered this pid (main shell → visible)
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
# TEST (e) — `close` (via the WRAPPER) marks the lease connected=false, and the NEXT
# pool_ensure_connected RE-BINDS the daemon (connected false→true) instead of trusting the
# lingering pool_daemon_connected probe (P1.M3.T1.S1+S2 / Issue #3 / PRD §2.4 step 4 /
# §2.5 / §2.15).
#
# WHY THIS IS DISTINCT FROM test_close_is_disconnect_only (test d): test d invokes close
# DIRECTLY on $POOL_REAL_BIN → BYPASSES pool_wrapper_main → S1's connected=false block
# NEVER fires → connected stays true → S2's gate lets the lingering probe win →
# pool_ensure_connected EARLY-EXITS without re-binding. test d passes before AND after the
# fix; it never proves a rebind. THIS test runs close THROUGH pool_wrapper_main (so S1
# fires end-to-end) and asserts the connected false→true transition (the ONLY signal that
# distinguishes "rebind ran" from "early-exit on a lingering probe").
# =============================================================================
test_close_then_rebind() {
    _release_setup_real_env || return 1

    # (1) Spawn THIS body's owner (CURRENT shell — owner env + POOL_OWNER_* globals must
    #     propagate to the `( pool_wrapper_main close )` subshell), then acquire + boot
    #     lane N (one real headless Chrome).
    local N port session
    _test_spawn_owner >/dev/null
    N="$(_release_acquire_boot)" || return 1
    assert_lane_exists "$N" || return 1
    port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
    session="$(pool_lease_field "$N" session 2>/dev/null)" || session="abpool-$N"
    [[ "$port" =~ ^[0-9]+$ && "$port" != "0" ]] \
        || { _fail "lane $N not booted (port='$port')"; return 1; }
    # Precondition: a freshly-booted lane has connected=true (pool_boot_lane step f).
    assert_eq "true" "$(pool_lease_field "$N" connected)" \
        "precondition: booted lane $N connected=true" || return 1

    # (2) THE CONTRACT (S1): run `close` THROUGH the wrapper (pool_wrapper_main) so S1's
    #     close→connected=false block fires end-to-end. The wrapper ends in exec → run it
    #     in a SUBSHELL (exec replaces the subshell process; the real close detaches the
    #     daemon and exits; the parent shell continues). Bounded by exec's determinism
    #     (AGENTS.md §2; close is ms-fast). Owner env is inherited → find_mine reuses N.
    ( pool_wrapper_main close ) >/dev/null 2>&1 || true
    sleep 0.4   # let the daemon settle after the disconnect-only close (parity w/ test d)

    # (3) Assert S1 fired: the lease now has connected=false (the post-close signal S2 reads).
    assert_eq "false" "$(pool_lease_field "$N" connected)" \
        "S1: close (via wrapper) marked lane $N connected=false" || return 1

    # (4+5) THE CONTRACT (S2): pool_ensure_connected reads connected=false → SKIPS the
    #       lingering pool_daemon_connected early-exit → curl (Chrome still alive) →
    #       pool_daemon_connect RE-BINDS → connected=true → rc 0. (This is the self-heal
    #       the wrapper's step h runs on the agent's NEXT driving command.)
    pool_ensure_connected "$N" \
        || { _fail "S2: pool_ensure_connected failed to rebind lane $N after close"; return 1; }
    assert_eq "true" "$(pool_lease_field "$N" connected)" \
        "S2: pool_ensure_connected rebound lane $N (connected false→true)" || return 1

    # (6) Assert the daemon is GENUINELY bound (session in list + Chrome alive) — now
    #     because pool_daemon_connect re-attached, NOT because of a lingering entry. (The
    #     connected false→true transition above is the actual proof; this is the live-binding
    #     sanity check.)
    pool_daemon_connected "$session" "$port" \
        || { _fail "daemon not genuinely bound after rebind (pool_daemon_connected rc!=0)"; return 1; }

    # Cleanup is the runner's inter-body backstop (release all + kill owner); nothing extra.
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
