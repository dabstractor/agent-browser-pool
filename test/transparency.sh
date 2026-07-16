#!/usr/bin/env bash
#
# test/transparency.sh — transparency checklist (PRD §2.15 "the no-idea contract")
#
# Proves that an agent issuing the EXACT commands the agent-browser-pool skill teaches
# (`skills get core`, `open`, `connect <port>`, `--session <X>`, `close --all`, …) is routed
# to its own locked ephemeral lane via the SOLE entry point bin/agent-browser-pool (explicit
# invocation — NO PATH shadowing) and CAN NEITHER DETECT NOR ESCAPE the pool. One test_* body
# per §2.15 clause (+ invocation-surface + fail-fast contracts):
#   (a)  agent-browser-pool skills get core → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
#   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
#   (b2) agent-browser-pool --version       → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
#   (c)  open <url> zero-prep               → lands MY lane (acquired+booted+connected+leased)
#   (d)  2nd open same owner                → reuses the SAME lane N (find_mine, not re-acquire)
#   (e)  connect <random>                   → routed to MY lane (the <port|url> arg is STRIPPED)
#   (f)  --session <X> open <url>           → forced to abpool-<N> (X is STRIPPED + env forced)
#   (g)  close --all                        → only MY lane's daemon session closed; PEER unaffected
#   (h)  next agent (distinct PID)          → a DIFFERENT lane (no collision)
#   (i)  driving cmd, no pi ancestor        → FAIL-FAST pool_die (exit 1 + 'pi ancestor'; §2.4 step 1)
#
# ★★★ THE 'open MAY HANG' GOTCHA (§gotcha 1) ★★★ A driving command's success path TERMINATES
# via `exec "$POOL_REAL_BIN" …` (the pool's driving-command dispatcher,
# step k, lib/pool.sh). A driving `open` may
# NOT exit (the real agent-browser can stay foregrounded). So item (c)/(d)/(f) NEVER `wait`
# an open bare; they background it under a HARD `timeout --signal=KILL`, then POLL
# `pool_lease_find_mine` for the lane (the lane is acquired+booted+connected+lease-WRITTEN
# BEFORE the terminal exec ⇒ observable while the driving open runs), then kill+wait the bg
# job. Chrome survives the driving-command kill (setsid → own session); the runner's
# inter-body `release all` reaps it.
#
# ★★★ THE SINGLE-SETUP CONSTRAINT (AGENTS.md §4) ★★★ The framework's setup() is
# process-spawning; the 3rd call HANGS this sandbox. So this file BYPASSES
# run_test/abpool_run_suite (they call setup() per-test): ONE setup() for the whole file
# (temp root + config + trap); each body runs via `if "$fn"; then` in the MAIN shell (NOT a
# subshell — no mid-suite EXIT-trap firing → the temp root survives all eight bodies); each
# body spawns its OWN owner via _transparency_spawn_owner (order-independent); ONE teardown().
#
# SOURCES test/validate.sh (P1.M9.T1.S1 — assertions + spawn_sim_owner + hermetic
# setup/teardown) and MIRRORS test/release_reaper.sh (P1.M9.T3.S1 — the real-env helper
# + acquire/boot + spawn-owner + kill/reap-zombie + the single-setup runner). It does NOT
# duplicate release_reaper's test_close_is_disconnect_only: item (g) here is a NEW,
# MULTI-owner `close --all` scope test (a PEER lane + Chrome must survive MY close --all).
set -euo pipefail

# --- repo + framework resolution (mirror test/validate.sh's symlink-safe bootstrap) ----------
TRANSPARENCY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=./validate.sh
source "$TRANSPARENCY_DIR/validate.sh"
# (validate.sh already sourced lib/pool.sh + defined helpers + setup/teardown/runner.)

# =============================================================================
# _transparency_setup_real_env — point AGENT_CHROME_MASTER + AGENT_BROWSER_REAL at the REAL
# binaries. COPIED VERBATIM from test/release_reaper.sh:_release_setup_real_env (P1.M9.T3.S1's
# host-proven fix). Renamed only to avoid cross-file clashes if a future aggregator sources
# multiple test files in one shell.
#
# WHY (the pivotal gap): validate.sh's setup() overrides HOME to a temp dir → pool_config_init
# resolves POOL_REAL_BIN to $TEMP_HOME/.local/bin/agent-browser (NONEXISTENT) and POOL_MASTER_DIR
# to an EMPTY temp master. pool_boot_lane step e calls pool_daemon_connect which rc 1's on a
# missing/non-exec POOL_REAL_BIN → pool_boot_lane DROPS the lane → EVERY test that boots real
# Chrome FAILS. Likewise pool_check_master pool_die's on an empty master.
#
# FIX: override BOTH to the REAL read-only master + the REAL agent-browser daemon binary
# (resolved via the operator's REAL passwd home — setup already clobbered HOME). The master is
# READ-ONLY (PRD §2.7) → safe to share; reflink copies are CoW. Chrome still runs under the
# TEMP ephemeral root (relocated to btrfs — see below) → hermetic. Then re-resolve all globals.
# =============================================================================
_transparency_setup_real_env() {
    local real_home real_master real_bin
    # Resolve the operator's REAL home BEFORE setup clobbered HOME (setup already ran by the
    # time a test body executes; capture the real home from the passwd entry).
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
    # step e), pool_release_lane's daemon close, and every driving exec ALL fail.
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
# _transparency_acquire_boot — acquire + boot a lane for the CURRENT owner. Echoes the lane N;
# rc 1 on failure. Boots REAL headless Chrome (one instance). COPIED from release_reaper.sh.
# The caller owns the owner env: EACH test body spawns its OWN owner via
# _transparency_spawn_owner (which exports AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME) BEFORE
# calling this; pool_owner_resolve at the top reads that env. Guarded for set -e.
# =============================================================================
_transparency_acquire_boot() {
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
# _transparency_kill_owner PID — kill PID and REAP its zombie so /proc/PID vanishes.
# COPIED from release_reaper.sh. WHY: a killed child becomes a ZOMBIE until its parent waits;
# a zombie's /proc/PID + comm may still read "pi"+match → pool_owner_alive FALSE-ALIVE → the
# lane is NOT stale → reap/acquire skip it → the test passes/passes-vacuously for the wrong
# reason. `wait` reaps the zombie so pool_owner_alive sees it DEAD. PID MUST be a child of this
# shell (spawn_sim_owner's owner is). Best-effort (|| true).
# =============================================================================
_transparency_kill_owner() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# =============================================================================
# _transparency_spawn_owner — spawn a FRESH live "pi"-comm owner for THIS body, set
# ABPOOL_CUR_OWNER (so the runner's inter-body cleanup kills it as a backstop), and export the
# owner env. Echoes the pid. COPIED from release_reaper.sh:_test_spawn_owner.
#
# WHY PER-BODY OWNERS (not setup's shared owner): setup() is called ONCE (SINGLE-SETUP
# constraint); bodies are order-independent. So every body spawns its own fresh owner — no
# cross-test contamination. The pool_owner_resolve call refreshes POOL_OWNER_* globals in THIS
# shell from the just-exported env (REQUIRED when this helper runs in the current shell and the
# lane is then acquired via `N="$(...)"` — a subshell whose internal pool_owner_resolve does NOT
# propagate back; without it the global stays stale → find_mine finds nothing).
# =============================================================================
_transparency_spawn_owner() {
    local pid st
    pid="$(spawn_sim_owner)"
    st="$(_pool_get_starttime "$pid")"
    ABPOOL_CUR_OWNER="$pid"           # runner's inter-body cleanup kills this as a backstop
    export AGENT_BROWSER_POOL_OWNER_PID="$pid"
    export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
    pool_owner_resolve                # refresh POOL_OWNER_* globals in THIS shell from the env
    printf '%s\n' "$pid"
}

# =============================================================================
# _transparency_run_open_bg — the poll-then-kill open driver (items c/d/f).
#
# WHY: a driving `open` may NOT exit (the real agent-browser can stay foregrounded —
# §gotcha 1). The lane is acquired+booted+connected and the lease WRITTEN before the terminal
# exec ⇒ observable while open runs. So background the driving command under a HARD `timeout
# --signal=KILL` (AGENTS.md §2 — every blocking subprocess bounded), >/dev/null 2>&1 (we assert
# on the LANE, not open's output), then poll pool_lease_find_mine.
# =============================================================================
TRANSPARENCY_BG_PID=""
_transparency_run_open_bg() {
    # $@ = driving args (e.g. "open about:blank" or "--session agent-x open about:blank").
    # $! = the `timeout` job (it kills its child — the driving command — on expiry).
    timeout --signal=KILL 25 "$ABPOOL_ADMIN" "$@" >/dev/null 2>&1 &
    TRANSPARENCY_BG_PID=$!
}

# _transparency_wait_my_lane — poll pool_lease_find_mine up to ~20s; echo N on success, rc 1 on
# timeout. The lane must be found via the lib's find_mine (the same seam the pool's reuse
# step uses) so this proves the lease is genuinely MINE + LIVE. rc-1 safe (pool_lease_find_mine
# returns 1 when no lane is found — guarded by the `if`).
_transparency_wait_my_lane() {
    local deadline lane
    deadline=$(( $(date +%s) + 20 ))
    lane=""
    while (( $(date +%s) < deadline )); do
        if lane="$(pool_lease_find_mine 2>/dev/null)" && [[ -n "$lane" ]]; then
            printf '%s\n' "$lane"; return 0
        fi
        sleep 0.3
    done
    return 1
}

# _transparency_reap_bg — kill + wait the bg timeout job (reap the zombie so /proc clears).
# Chrome survives the driving-command kill (setsid → own session); the POOL owns it (the runner's
# inter-body `release all` reaps it). Best-effort (|| true). Resets the pid var.
_transparency_reap_bg() {
    [[ -n "${TRANSPARENCY_BG_PID:-}" ]] || return 0
    kill "$TRANSPARENCY_BG_PID" 2>/dev/null || true
    wait "$TRANSPARENCY_BG_PID" 2>/dev/null || true
    TRANSPARENCY_BG_PID=""
}

# _transparency_reap_all_sim_owners — DEFENSE-IN-DEPTH backstop (AGENTS.md §3: never leak).
# Multi-owner bodies (g)/(h) spawn TWO owners but only ONE is tracked in ABPOOL_CUR_OWNER; an
# early-return mid-body (a failed assert / acquire) can leak the un-tracked one. This reaps
# EVERY live sim-owner this suite spawned (spawn_sim_owner copies /usr/bin/sleep to a temp dir
# named 'pi' → their /proc/comm=='pi' AND their exe path matches /tmp/abpool-pi.*/pi). Called
# between bodies by the runner + at suite end. Best-effort (|| true); orphans reparent to init.
_transparency_reap_all_sim_owners() {
    local pid
    for pid in $(pgrep -f 'abpool-pi\..*/pi' 2>/dev/null || true); do
        kill "$pid" 2>/dev/null || true
    done
}

# =============================================================================
# _transparency_assert_driving_no_pi_fails_fast CMD... — shared verifier: assert that a driving
# command (CMD...) with NO pi ancestor fail-fasts with the 'pi ancestor' pool_die message.
# Mirrors the proven mechanism of test_driving_no_pi_ancestor_fails_fast (item i):
#   - `setsid --fork` ALWAYS forks → the detached child is reparented to the subreaper/init,
#     so its ppid chain no longer contains `pi` (bare `setsid` only forks conditionally → flaky;
#     `--wait` is FATAL — it keeps setsid as the parent → chain intact → no fail-fast).
#   - `env -u` strips AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME so pool_owner_resolve's TEST MODE
#     cannot short-circuit (validate.sh::setup exports them; without -u the child would inherit
#     a fake owner → no fail-fast).
#   - redirect to a TEMP FILE (setsid --fork exits immediately after forking → `$()` capture is
#     racy + could wedge on a regression) + bounded poll (10s ceiling; pool_die is sub-second).
# pool_die fires at pool_wrapper_main step d, BEFORE any Chrome/lane work → no orphan
# (the detached child self-exits; setsid pid reaped by `wait`). AGENTS.md §1-§3 compliant.
_transparency_assert_driving_no_pi_fails_fast() {
    local tmp bg deadline msg
    tmp="$(mktemp)"
    env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        setsid --fork "$ABPOOL_ADMIN" "$@" >"$tmp" 2>&1 &
    bg=$!
    wait "$bg" 2>/dev/null || true              # reap the setsid zombie (AGENTS.md §3); setsid exits immediately after forking
    # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
    deadline=$(( $(date +%s) + 10 ))
    msg=""
    while (( $(date +%s) < deadline )); do
        msg="$(cat "$tmp" 2>/dev/null || true)"
        [[ "$msg" == *"pi ancestor"* ]] && break
        sleep 0.2
    done
    rm -f -- "$tmp"
    [[ "$msg" == *"pi ancestor"* ]] \
        || { _fail "no-pi '$*' did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
}

# TEST (a) — `agent-browser-pool skills get core` with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
# Post P1.M1.T1.S1 (the step-c exec-to-real-binary path deleted), `skills` is a DRIVING command: it has no
# case arm in bin/agent-browser-pool → falls to pool_wrapper_main → step d (owner resolve) →
# POOL_OWNER_PID==0 (no pi ancestor) → pool_die 'driving commands require a pi ancestor …'.
# Same fail-fast mechanism as test_driving_no_pi_ancestor_fails_fast (item i): detach via
# `setsid --fork` (reparent the child away from the pi/bash chain) + `env -u` (strip owner
# overrides) + capture to a temp file + poll for 'pi ancestor'. pool_die fires at step d,
# BEFORE any Chrome/lane work → sub-second, no orphan. (A pi ancestor is deliberately NOT
# spawned — that is the condition under test.)
# =============================================================================
test_skills_fail_fast_no_pi() {
    _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
    _transparency_assert_driving_no_pi_fails_fast skills get core || return 1
}

# =============================================================================
# TEST (b1) — `agent-browser-pool --help` → POOL help (NOT passthrough).
# PRD §2.15 / §2.4 step 0: `--help` is a POOL VERB caught by bin/agent-browser-pool's dispatch
# case (`--help|-h|help) → pool_admin_help`) BEFORE the pool's driving-command dispatcher +
# meta classifier run.
# So the output is the POOL's help text — NOT the real agent-browser's help. The byte-equal
# assertion that held under PATH-shadowing is now WRONG. Assert the output CONTAINS the pool's
# signature phrase 'agent-browser-pool' (the real agent-browser --help never emits '-pool').
# (A pi ancestor is irrelevant to a pool verb, but spawn one for parity with the other bodies.)
# =============================================================================
test_help_shows_pool_help() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local out
    out="$(timeout 15 "$ABPOOL_ADMIN" --help 2>&1 || true)"
    [[ "$out" == *"agent-browser-pool"* ]] \
        || { _fail "--help did not show pool help (missing 'agent-browser-pool'); got: $out"; return 1; }
}

# =============================================================================
# TEST (b2) — `agent-browser-pool --version` with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
# Post P1.M1.T1.S1 (the step-c exec-to-real-binary path deleted), `--version` is a DRIVING command: it has
# no case arm in bin/agent-browser-pool → falls to pool_wrapper_main → step d (owner resolve) →
# POOL_OWNER_PID==0 (no pi ancestor) → pool_die 'driving commands require a pi ancestor …'.
# Same fail-fast mechanism as test_driving_no_pi_ancestor_fails_fast (item i). pool_die fires
# at step d, BEFORE any Chrome/lane work → sub-second, no orphan.
# =============================================================================
test_version_fail_fast_no_pi() {
    _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
    _transparency_assert_driving_no_pi_fails_fast --version || return 1
}

# =============================================================================
# TEST (c) — `open <url>` zero-prep → lands MY lane (acquired+booted+connected+leased).
# PRD §2.15: an agent issuing a zero-prep open is silently routed to its own lane.
# Backgrounds the driving open (may not exit), polls for the lane, asserts it exists + is live,
# then reaps the bg job (Chrome survives; release all reaps it). Uses about:blank (local, no
# network, fastest nav, least flake).
# =============================================================================
test_open_zero_prep_lands_lane() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    _transparency_run_open_bg open about:blank
    local N
    N="$(_transparency_wait_my_lane)" \
        || { _transparency_reap_bg; _fail "no lane acquired for zero-prep open"; return 1; }
    assert_lane_exists "$N" || { _transparency_reap_bg; return 1; }
    _transparency_reap_bg
}

# =============================================================================
# TEST (d) — 2nd `open` same owner → reuses the SAME lane N (find_mine, not re-acquire).
# PRD §2.15: the pool is stateless from the agent's view — repeated commands reuse the lane.
# Boots lane N via a 1st open; reaps it; a 2nd open (same owner) must return N again
# (pool_lease_find_mine finds the existing live lease). Asserts N1 == N2.
# =============================================================================
test_second_open_reuses_lane() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local N1 N2
    _transparency_run_open_bg open about:blank
    N1="$(_transparency_wait_my_lane)" \
        || { _transparency_reap_bg; _fail "1st open: no lane acquired"; return 1; }
    _transparency_reap_bg                       # let the 1st open finish/be-killed; Chrome stays
    _transparency_run_open_bg open about:blank
    N2="$(_transparency_wait_my_lane)" \
        || { _transparency_reap_bg; _fail "2nd open: no lane acquired"; return 1; }
    _transparency_reap_bg
    assert_eq "$N1" "$N2" "2nd open reuses the SAME lane (find_mine, not re-acquire)" || return 1
}

# =============================================================================
# TEST (e) — `connect <random>` → routed to MY lane; the <port|url> arg is STRIPPED.
# PRD §2.15: the upstream skill teaches `connect <port>`; the pool owns the real connection
# (pool_ensure_connected), so the agent's arg is ignored. TWO LAYERS:
#   LAYER 1 (deterministic unit of the pure normalizer — NO Chrome): pool_normalize_connect
#     strips the FIRST non-flag positional after connect. Verify 98765 is gone from POOL_NORM_ARGS.
#   LAYER 2 (routing integ): with a live lane N, a driving `connect <random>` must NOT move us
#     off N. After Issue #1 the pool SHORT-CIRCUITS the resulting bare connect to a success
#     no-op (rc 0) instead of erroring; we still IGNORE its rc and assert ROUTING via
#     find_mine == N (the contract is about routing, not the connect rc).
# =============================================================================
test_connect_random_ignored() {
    # LAYER 1 — pure normalizer unit check (no Chrome, no real env).
    pool_normalize_connect connect 98765 >/dev/null
    local found=0 t
    for t in "${POOL_NORM_ARGS[@]}"; do
        [[ "$t" == "98765" ]] && found=1
    done
    [[ "$found" -eq 0 ]] \
        || { _fail "connect arg 98765 NOT stripped from POOL_NORM_ARGS"; return 1; }

    # LAYER 2 — routing: with a live lane N, connect <random> keeps us on N.
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local N before after
    before="$(_transparency_acquire_boot)" || return 1     # acquire+boot lane N (lib direct)
    # Bare connect: post-Issue #1 the pool short-circuits to a success no-op (rc 0).
    # We IGNORE its rc either way (the contract is ROUTING, not the connect rc).
    timeout --signal=KILL 15 "$ABPOOL_ADMIN" connect 98765 >/dev/null 2>&1 || true
    after="$(pool_lease_find_mine 2>/dev/null || true)"
    assert_eq "$before" "$after" "connect <random> kept us on lane $before (arg ignored)" || return 1
}

# =============================================================================
# TEST (f) — `--session <X> open <url>` → forced to abpool-<N> (X is STRIPPED + env forced).
# PRD §2.15: the agent cannot bypass its lane via the upstream --session flag. The pool
# strips every --session (pool_strip_session_args) AND forces AGENT_BROWSER_SESSION=abpool-<N>
# (pool_force_session). Verify the lease's .session == abpool-<N> and ≠ <X>. The lease .session
# is written as abpool-<N> during acquire (lib/pool.sh:2004) — so the forced env + lease agree.
# =============================================================================
test_session_override_forced() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local X="agent-evil-7777" N sess
    _transparency_run_open_bg --session "$X" open about:blank
    N="$(_transparency_wait_my_lane)" \
        || { _transparency_reap_bg; _fail "no lane acquired for --session open"; return 1; }
    _transparency_reap_bg
    sess="$(pool_lease_field "$N" session 2>/dev/null)" || sess=""   # rc 1 on missing/corrupt
    assert_eq "abpool-$N" "$sess" "lane $N session forced to abpool-$N" || return 1
    [[ "$sess" != *"$X"* ]] \
        || { _fail "agent's --session '$X' LEAKED into lease session '$sess'"; return 1; }
}

# =============================================================================
# TEST (g) — `close --all` → only MY lane's daemon closed; PEER lane+Chrome unaffected.
# PRD §2.15: "close --all → cannot harm other agents' lanes." This is the MULTI-owner scope
# test (NOT a dup of release_reaper's test_close_is_disconnect_only, which is single-owner +
# bare close). TWO LAYERS:
#   LAYER 1 (unit): pool_normalize_close strips --all + sets POOL_CLOSE_ALL_SEEN=1.
#   LAYER 2 (multi-owner scope): owner A (me) + owner B (peer) on distinct lanes; run A's
#     `close --all` through the pool (scoped to abpool-NA after strip+force); PEER lane B's
#     lease MUST still be present AND peer Chrome (port B) MUST still respond.
# The pool exec's `"$POOL_REAL_BIN" --session abpool-NA close` (after strip+force) → only
# A's daemon session. NB's daemon is a SEPARATE session ⇒ survives.
# =============================================================================
test_close_all_scoped_no_peer_harm() {
    # LAYER 1 — unit: --all is stripped + flagged.
    POOL_CLOSE_ALL_SEEN=0
    pool_normalize_close close --all >/dev/null
    assert_eq "1" "${POOL_CLOSE_ALL_SEEN:-0}" "close --all set POOL_CLOSE_ALL_SEEN=1" || return 1
    local t allgone=1
    for t in "${POOL_NORM_ARGS[@]}"; do
        [[ "$t" == "--all" ]] && allgone=0
    done
    [[ "$allgone" -eq 1 ]] || { _fail "--all NOT stripped from close POOL_NORM_ARGS"; return 1; }

    # LAYER 2 — multi-owner scope: peer lane+Chrome survive MY close --all.
    _transparency_setup_real_env || return 1
    local A B NA NB portB st_A st_B
    # Owner switching MUST happen in the MAIN shell: _transparency_spawn_owner's exports do NOT
    # propagate out of a `$()` capture (subshell), so the subsequent _transparency_acquire_boot
    # (also a `$()` subshell) would inherit a STALE owner env → both acquires would use the same
    # (dead setup) owner → collision. So: spawn+resolve in the main shell, acquire in a `$()`.
    # owner A (me): spawn + resolve in the MAIN shell (globals == A), then acquire+boot lane NA.
    A="$(spawn_sim_owner)"; st_A="$(_pool_get_starttime "$A")"
    ABPOOL_CUR_OWNER="$A"; export AGENT_BROWSER_POOL_OWNER_PID="$A"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_A"
    pool_owner_resolve
    NA="$(_transparency_acquire_boot)" || return 1
    assert_lane_exists "$NA"
    # owner B (peer): spawn + resolve in the MAIN shell (globals now == B), then acquire+boot NB.
    B="$(spawn_sim_owner)"; st_B="$(_pool_get_starttime "$B")"
    export AGENT_BROWSER_POOL_OWNER_PID="$B"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_B"
    pool_owner_resolve
    NB="$(_transparency_acquire_boot)" || return 1
    assert_lane_exists "$NB"
    portB="$(pool_lease_field "$NB" port 2>/dev/null)" || portB=""

    # Switch back to owner A, run its close --all through the pool (scoped to abpool-NA).
    export AGENT_BROWSER_POOL_OWNER_PID="$A"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_A"
    pool_owner_resolve

    timeout --signal=KILL 15 "$ABPOOL_ADMIN" close --all >/dev/null 2>&1 || true

    # PEER lane B MUST still be alive: lease present AND Chrome responds (curl, NOT kill -0).
    assert_lane_exists "$NB" \
        || { _fail "peer lane $NB lease gone after my close --all (--all was NOT scoped)"; return 1; }
    curl -sf "http://127.0.0.1:${portB}/json/version" >/dev/null 2>&1 \
        || { _fail "peer Chrome (port $portB) died after my close --all (--all was NOT scoped)"; return 1; }
    # Reap BOTH owners this body spawned (the runner's inter-body `release all` tears down the
    # lanes/Chrome; ABPOOL_CUR_OWNER only tracks ONE owner, so kill the extra here to avoid a
    # leak — AGENTS.md §3: never leave orphan processes).
    _transparency_kill_owner "$A"; _transparency_kill_owner "$B"
    ABPOOL_CUR_OWNER=""
}

# =============================================================================
# TEST (h) — next agent (distinct PID) → a DIFFERENT lane; no collision.
# PRD §2.15: each agent gets its own locked lane. Two distinct owners (distinct
# spawn_sim_owner PIDs+starttimes) acquire lanes N and M; assert N != M (no collision), each
# lane owned by its respective owner. SEQUENTIAL (no parallel subshells ⇒ no wait-hang risk).
# =============================================================================
test_next_agent_distinct_lane() {
    _transparency_setup_real_env || return 1
    local A B NA NB st_A st_B
    # Owner switching MUST happen in the MAIN shell (see test_close_all_scoped_no_peer_harm for
    # why: _transparency_spawn_owner's exports do NOT propagate out of a `$()` capture). So
    # spawn+resolve each owner in the main shell, then acquire in a `$()` subshell that
    # inherits the freshly-exported owner env. Distinct owners (distinct spawn_sim_owner PIDs +
    # starttimes) acquire distinct lanes.
    A="$(spawn_sim_owner)"; st_A="$(_pool_get_starttime "$A")"
    ABPOOL_CUR_OWNER="$A"; export AGENT_BROWSER_POOL_OWNER_PID="$A"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_A"
    pool_owner_resolve
    NA="$(_transparency_acquire_boot)" || return 1
    assert_lane_exists "$NA"
    B="$(spawn_sim_owner)"; st_B="$(_pool_get_starttime "$B")"
    export AGENT_BROWSER_POOL_OWNER_PID="$B"; export AGENT_BROWSER_POOL_OWNER_STARTTIME="$st_B"
    pool_owner_resolve
    NB="$(_transparency_acquire_boot)" || return 1
    assert_lane_exists "$NB"
    [[ "$NA" != "$NB" ]] \
        || { _fail "two distinct owners got the SAME lane $NA (collision!)"; return 1; }
    assert_eq "$A" "$(pool_lease_field "$NA" owner.pid 2>/dev/null || true)" "lane NA owned by A" || { _transparency_kill_owner "$A"; _transparency_kill_owner "$B"; return 1; }
    assert_eq "$B" "$(pool_lease_field "$NB" owner.pid 2>/dev/null || true)" "lane NB owned by B" || { _transparency_kill_owner "$A"; _transparency_kill_owner "$B"; return 1; }
    # Reap BOTH owners this body spawned (the runner's inter-body `release all` tears down the
    # lanes/Chrome; ABPOOL_CUR_OWNER only tracks ONE owner, so kill the extra here — AGENTS.md §3).
    _transparency_kill_owner "$A"; _transparency_kill_owner "$B"
    ABPOOL_CUR_OWNER=""
}

# =============================================================================
# TEST (i) — driving command with NO recognized-harness ancestor → FAIL-FAST pool_die (§2.4 step 1).
# PRD §2.4 step 1 / shipped P2.M1.T1.S2 (msg text: P3.M1.T1.S3): "No recognized-harness ancestor → DRIVING fails fast" — the pool's
# driving-command dispatcher step d calls pool_die (exit 1, stderr contains 'supported agent harness … for raw browser use call
# 'agent-browser' directly').
#
# DETERMINISM: pool_owner_resolve REAL MODE walks ppid from $$. This suite is often launched BY
# `pi` (the coding harness), so a normally-spawned driving subprocess's ppid chain INCLUDES pi →
# it would find an owner → NOT fail-fast → flaky. There is no "force no-owner" env var. So DETACH
# the driving command from this shell's tree via `setsid` (no --wait): setsid forks the child into
# a NEW session and exits; the child reparents to the subreaper / pid 1 (systemd, comm != 'pi') →
# ppid walk finds no 'pi' → POOL_OWNER_PID=0 → fail-fast. `env -u` strips any inherited owner
# override. Because setsid exits before the child, $() capture is racy → redirect the detached
# child's output to a TEMP FILE and poll (bounded) for 'supported agent harness'. pool_die fires at step d,
# BEFORE any Chrome/lane work → sub-second. No hang, no orphan (child self-exits via pool_die;
# setsid pid reaped by `wait`; grandchild reaped by its new parent/subreaper — AGENTS.md §3).
# =============================================================================
test_driving_no_pi_ancestor_fails_fast() {
    _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
    # Deliberately NO _transparency_spawn_owner — this body has NO recognized-harness ancestor.
    local tmp bg deadline msg
    tmp="$(mktemp)"
    # Fully detach: setsid --fork (always fork → the child is reparented to the subreaper /
    # init, so its ppid chain no longer contains `pi`) + strip owner overrides. The bare
    # `setsid` (no --fork) only takes a new session and does NOT reliably change ppid
    # (util-linux only forks when the caller is already a pgroup leader), which made this
    # test flaky — pool_owner_resolve still walked up to `pi` and the cmd proceeded instead
    # of failing fast. --fork guarantees the reparent so the no-pi-ancestor path is taken.
    env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        setsid --fork "$ABPOOL_ADMIN" open about:blank >"$tmp" 2>&1 &
    bg=$!
    wait "$bg" 2>/dev/null || true              # setsid --fork exits immediately after forking the detached child
    # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
    deadline=$(( $(date +%s) + 10 ))
    msg=""
    while (( $(date +%s) < deadline )); do
        msg="$(cat "$tmp" 2>/dev/null || true)"
        [[ "$msg" == *"supported agent harness"* ]] && break
        sleep 0.2
    done
    rm -f -- "$tmp"
    [[ "$msg" == *"supported agent harness"* ]] \
        || { _fail "driving cmd with no recognized-harness ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
}

# =============================================================================
# _abpool_run_transparency_suite — the SINGLE-SETUP runner.
#
# ★★★ HARD CONSTRAINT: setup() is called EXACTLY ONCE for the whole file (NEVER per-test). ★★★
# (MIRRORS test/release_reaper.sh:_abpool_run_release_reaper_suite.) The framework's
# run_test/abpool_run_suite call setup() before EACH test; in this sandbox the 3rd setup() call
# HANGS (a P1.M9.T1.S1 accumulation defect — AGENTS.md §4). So this file BYPASSES them:
#   - ONE setup() (temp root + config + trap). setup() spawns ONE sim-owner, but each body
#     spawns its OWN via _transparency_spawn_owner — so setup's owner is unused + killed now.
#   - Each body runs via `if "$fn"; then` in the MAIN shell (NOT a subshell). A `return 1` from
#     a failed assert is the function's rc → recorded as FAIL → the suite CONTINUES. (Bodies
#     use explicit `|| return 1` / `if !` guards, so running them in a conditional context —
#     where errexit is disabled — is safe. No subshell ⇒ the EXIT trap does NOT fire mid-suite
#     ⇒ the temp root is NOT removed between tests.)
#   - Each body owns its lanes (release all at its end); the runner adds a backstop release-all
#     + kills the body's owner (ABPOOL_CUR_OWNER, set by _transparency_spawn_owner) between
#     bodies. Also reaps any lingering bg open.
#   - ONE teardown() at the end.
# =============================================================================
_abpool_run_transparency_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call
    # setup() spawned ONE sim-owner; each body spawns its own, so kill+reap this unused one now
    # (so it does not linger ~600s; its ABPOOL_CUR_OWNER slot is overwritten by the first body).
    _transparency_kill_owner "$AGENT_BROWSER_POOL_OWNER_PID"
    ABPOOL_CUR_OWNER=""
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        # Inter-body backstop: reap any lingering bg open, release any leftover lanes, kill this
        # body's owner, AND reap any un-tracked sim-owner (multi-owner bodies may early-return and
        # leak the extra owner). Chrome from a bg'd open survives driving-command kill (setsid) — release
        # all reaps it.
        _transparency_reap_bg
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _transparency_kill_owner "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
        _transparency_reap_all_sim_owners
    done
    teardown
    _transparency_reap_all_sim_owners    # final backstop after teardown
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
    if ! _abpool_run_transparency_suite; then
        exit 1
    fi
fi
