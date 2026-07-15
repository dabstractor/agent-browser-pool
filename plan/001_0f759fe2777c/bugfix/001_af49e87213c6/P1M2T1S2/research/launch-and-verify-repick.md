# Research: _pool_launch_and_verify port re-pick + stale comment (P1.M2.T1.S2)

Date: 2026-07-14
Bugfix context: Issue 2 (concurrent port-allocation race). S2 is the SECOND of three
subtasks under P1.M2.T1. S1 (preceding, "Implementing") makes `pool_chrome_launch`
return 1 on an EADDRINUSE instant-exit (instead of `pool_die`). S2 (THIS task) adds the
port re-pick retry in `_pool_launch_and_verify` + fixes the stale comment. S3 (later)
updates the concurrency test.

---

## 1. THE S1 CONTRACT (what S2 consumes — assume S1 landed exactly as its PRP specifies)

`pool_chrome_launch` (lib/pool.sh:1483) return contract AFTER S1:

| Return | Meaning |
|---|---|
| 0 | Chrome launched, pgid captured, `POOL_CHROME_PID`/`POOL_CHROME_PGID` set |
| 1 | Instant-exit + log matches the EADDRINUSE grep pattern (retryable — caller re-picks) |
| pool_die (exit 1) | Bad args / instant-exit WITHOUT EADDRINUSE (genuine misconfig — fatal) |

S1's grep pattern (used AS-SPECIFIED, do not change):
`grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind'`

**CRITICAL consequence for S2**: the CURRENT `_pool_launch_and_verify` (lib/pool.sh:2128)
calls `pool_chrome_launch "$port" …` **UNGUARDED** (it was written for the pre-S1
`{0, pool_die}` contract). Under `set -euo pipefail` (lib/pool.sh line 1), a post-S1
`return 1` from `pool_chrome_launch` would **ABORT** `_pool_launch_and_verify` (unguarded
non-zero). So S2 MUST wrap both `pool_chrome_launch` calls in `if ! …; then` (catch the
return-1 and route to the re-pick). This is the core of the item's LOGIC.

S1 touches ONLY `pool_chrome_launch` + its docstring + `selftest_chrome_launch_eaddrinuse`
in validate.sh. S1 does NOT touch `_pool_launch_and_verify`, `pool_boot_lane`, the stale
comments, or the concurrency test → S2's edits to those are DISJOINT from S1 (no merge
conflict). Confirmed by reading S1's PRP scope + the current lib/pool.sh.

---

## 2. THE CURRENT `_pool_launch_and_verify` (lib/pool.sh:2128-2207) — exact edit site

```bash
_pool_launch_and_verify() {
    local port="${1:-}"
    local ephemeral_dir="${2:-}"
    local lane="${3:-}"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || return 1
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    # --- Attempt 1 ---
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # 0 or fatal pool_die  ← UNGUARDED (S2 fixes)
    _pool_boot_write_chrome_ids "$lane"
    if pool_wait_cdp "$port"; then
        return 0
    fi

    # --- Attempt 2 (retry once — PRD §2.14) ---
    if [[ -f "$POOL_STATE_DIR/chrome-$lane.log" ]]; then          # Issue #6 log-preserve
        mv -f -- "$POOL_STATE_DIR/chrome-$lane.log" \
                "$POOL_STATE_DIR/chrome-$lane.attempt1.log" 2>/dev/null || true
        _pool_log "_pool_launch_and_verify: preserved attempt-1 log: $POOL_STATE_DIR/chrome-$lane.attempt1.log"
    fi
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # relaunch  ← UNGUARDED (S2 fixes)
    _pool_boot_write_chrome_ids "$lane"
    if pool_wait_cdp "$port"; then
        return 0
    fi
    return 1
}
```

Two problems S2 fixes:
1. Both `pool_chrome_launch` calls are unguarded → a post-S1 `return 1` aborts under set -e.
2. The retry uses the SAME `$port` → a port collision recurs on both attempts → `return 1`
   → caller (`pool_boot_lane`) drops the lane → wrapper `pool_die`. No re-pick ever happens.

---

## 3. THE DESIGNED CONTROL FLOW (host-verified — see §6)

The re-pick must be reachable from THREE trigger points, execute ONCE (no loop), and
update the lease port. The cleanest bash structure (no goto, no helper fn) uses nested
`if pool_chrome_launch; then … fi` so a return-1 FALLS THROUGH to a shared re-pick block
at the end:

```bash
_pool_launch_and_verify() {
    local port="${1:-}" ephemeral_dir="${2:-}" lane="${3:-}" new_port
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || return 1
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    # --- Attempt 1 (same port) ---
    if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then       # rc 1 → fall through
        _pool_boot_write_chrome_ids "$lane"
        if pool_wait_cdp "$port"; then return 0; fi
        # CDP timeout (Chrome pgroup already killed by pool_wait_cdp). Preserve attempt-1 log.
        if [[ -f "$POOL_STATE_DIR/chrome-$lane.log" ]]; then
            mv -f -- "$POOL_STATE_DIR/chrome-$lane.log" \
                    "$POOL_STATE_DIR/chrome-$lane.attempt1.log" 2>/dev/null || true
            _pool_log "_pool_launch_and_verify: preserved attempt-1 log: $POOL_STATE_DIR/chrome-$lane.attempt1.log"
        fi
        # --- Attempt 2 (same port retry — PRD §2.14) ---
        if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then   # rc 1 → fall through
            _pool_boot_write_chrome_ids "$lane"
            if pool_wait_cdp "$port"; then return 0; fi
        fi
    fi

    # --- Port re-pick (ONE retry with a different port; Issue 2 / S2) ---
    # Reached when: (a) pool_chrome_launch returned 1 (EADDRINUSE — S1) on attempt 1 or 2,
    # OR (b) both same-port CDP-timeout attempts failed. pool_find_free_port excludes ports
    # already in leases (incl. our current $port, written by pool_boot_lane step b), so the
    # new port is guaranteed different from the colliding one. ONE re-pick only (no loop).
    if ! new_port="$(pool_find_free_port)"; then
        _pool_log "_pool_launch_and_verify: no free port to re-pick for lane $lane; giving up"
        return 1
    fi
    pool_lease_update "$lane" port "$new_port"
    _pool_log "_pool_launch_and_verify: re-picked port $new_port for lane $lane (was $port)"
    if ! pool_chrome_launch "$new_port" "$ephemeral_dir" "$lane"; then
        return 1
    fi
    _pool_boot_write_chrome_ids "$lane"
    if pool_wait_cdp "$new_port"; then
        return 0
    fi
    return 1
}
```

Fall-through map (verified):
- Attempt-1 launch rc 1 → outer `if` false → skip whole `then` (incl. attempt 2) → re-pick. ✓ (path a, attempt 1)
- Attempt-1 launch rc 0, wait_cdp rc 1 → attempt 2; attempt-2 launch rc 1 → inner `if` false → fall through → re-pick. ✓ (path a, attempt 2)
- Attempt-1 rc 0 + wait rc 1 → attempt-2 rc 0 + wait rc 1 → both `if`s end → fall through → re-pick. ✓ (path b)
- Any launch rc 0 + wait rc 0 → `return 0`. ✓ (success)
- Re-pick: find_free_port rc 1 → return 1; launch rc 1 → return 1; wait rc 1 → return 1; wait rc 0 → return 0. ✓

---

## 4. THE pool_boot_lane INTEGRATION FIX (REQUIRED — not optional)

`pool_boot_lane` (lib/pool.sh:2208) calls `_pool_launch_and_verify` then uses the LOCAL
`$port` for the daemon connect (step e) + the provisioned log (step f):

```bash
    if ! _pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"; then
        _pool_log "pool_boot_lane: CDP not ready after retry for lane $lane port $port; dropping lane"
        _pool_release_lane_internals "$lane"
        return 1
    fi
    # --- e. CONNECT ---
    if ! pool_daemon_connect "abpool-$lane" "$port"; then     # ← STALE $port after a re-pick!
```

**The bug if left unfixed**: if `_pool_launch_and_verify` re-picks (Chrome now on
`new_port`, lease updated to `new_port`), `pool_boot_lane` still calls
`pool_daemon_connect "abpool-$lane" "$port"` with the OLD `$port` → the daemon connects to
the wrong port → connection refused → `pool_daemon_connect` rc 1 → `_pool_release_lane_internals`
+ `return 1` → **the lane is DROPPED despite a successful re-pick**. The feature S2 delivers
would be inert end-to-end.

**The fix** (4 lines, confined to the success path between `_pool_launch_and_verify` and
`pool_daemon_connect`): re-read the authoritative port from the lease:

```bash
    fi
    # _pool_launch_and_verify may have re-picked a different port (Issue 2 / S2) and updated
    # the lease; re-read the authoritative port so the daemon connect (step e) + provisioned
    # log (step f) use the REAL bound port, not the stale local $port. Guarded: a failed
    # re-read (truly exceptional — corrupt lease mid-boot) keeps the original $port.
    local reread_port
    reread_port="$(pool_lease_field "$lane" port 2>/dev/null)" || true
    if [[ "$reread_port" =~ ^[0-9]+$ && "$reread_port" -gt 0 ]]; then
        port="$reread_port"
    fi
    # --- e. CONNECT ---
```

WHY this is in S2's scope (not scope creep): the item's OUTPUT contract is "The lease's
port field is updated to the new port if a re-pick occurred." That output is only MEANINGFUL
if the caller reads it. The lease-port update + pool_boot_lane re-read are the two halves of
ONE mechanism. Without the re-read, S2's deliverable is broken. S1 does NOT touch
pool_boot_lane (confirmed) → no conflict. S3 is a test-only task → won't fix it. So S2 must.

`pool_lease_field` (lib/pool.sh:881) echoes the field + returns 0 (or 1 on missing/corrupt).
Under set -e the capture MUST be guarded (`|| true`); the `[[ =~ && -gt ]] && port=` form is
errexit-safe (inside `if`).

---

## 5. THE STALE COMMENTS (lib/pool.sh ~1328-1331 section banner + ~1377-1379 GOTCHA)

Both say "the launch (M4.T2.S2) is authoritative + retries on EADDRINUSE" — inaccurate
(it implies pool_chrome_launch itself retries; it doesn't — `_pool_launch_and_verify` does
the re-pick, and only after S1+S2). After S1+S2 the mitigation IS real, so the comment is
corrected to NAME the real mechanism precisely (per the item's exact wording):

- Section banner (~1330): `…selection is BEST-EFFORT: the launch in M4.T2.S2 is the authoritative bind and retries on EADDRINUSE).`
  → `…selection is BEST-EFFORT: the launch is the authoritative bind; on a launch/CDP failure, _pool_launch_and_verify re-picks a different port via pool_find_free_port and retries once (Issue 2 / S1+S2).`
- GOTCHA (~1377-1379): `…the launch (M4.T2.S2) is authoritative + retries on EADDRINUSE.`
  → `…the launch is authoritative; on a launch/CDP failure, _pool_launch_and_verify re-picks a different port via pool_find_free_port and retries once (Issue 2 / S1+S2).`

Exact current text quoted in the PRP's Task 3 for verbatim `edit` oldText.

---

## 6. HOST-VERIFIED CONTROL-FLOW PROOF (this session, mock-based, no real Chrome)

A scratch script sourced lib/pool.sh (real lease helpers), overrode
`pool_chrome_launch`/`pool_wait_cdp`/`pool_find_free_port` with port-conditional stubs,
defined the §3 `_pool_launch_and_verify`, and ran 4 scenarios against real lease files:

```
PATH (a): launch rc 1 on orig, rc 0 on new              → rc=0  lease_port=53421 ✓
PATH (b): launch rc 0 on orig, wait_cdp rc 1 twice, re-pick rc 0 → rc=0  lease_port=53431 ✓
NEGATIVE: pool_find_free_port rc 1 (exhausted)          → rc=1 ✓
NEGATIVE: re-pick launch rc 1 (fails again)             → rc=1  lease_port=53431 (updated before the failed retry) ✓
```

All 4 scenarios pass. The control flow is correct. (The mock approach mirrors the test
design: function-shadowing inside a `bash -c` subshell so it does NOT leak into the
validate.sh main shell — see §7.)

---

## 7. TEST DESIGN — subshell-scoped mocks (matches S1's selftest pattern)

`_run_selftest_suite` (validate.sh:~474) runs each `selftest_*` body in the **MAIN shell**
(single setup — AGENTS.md §4: at most ONE process-spawning `setup()`). A mock defined in
the main shell would SHADOW the lib function for ALL subsequent selftests (leakage). So the
test MUST run `_pool_launch_and_verify` in a `bash -c '…'` SUBSHELL that sources lib/pool.sh
fresh and defines the mocks there (scoped to the subshell). This is EXACTLY S1's
`selftest_chrome_launch_eaddrinuse` pattern (`bash -c '…' _ "$ABPOOL_REPO" || rc=$?`).

Mock contract (3 stubs, all port-conditional):
- `pool_chrome_launch PORT DIR LANE`: rc 1 (EADDRINUSE) for the ORIGINAL port; rc 0 + set
  `POOL_CHROME_PID`/`POOL_CHROME_PGID` (via `declare -g`) for the NEW port. (The globals are
  read by the real `_pool_boot_write_chrome_ids` → `pool_lease_update`.)
- `pool_wait_cdp PORT`: rc 1 (timeout) for the ORIGINAL port; rc 0 for the NEW port.
- `pool_find_free_port`: echoes the NEW port (deterministic — no `ss`/`curl` host dependency).
  Mocked for determinism (NOT because it launches Chrome); pool_find_free_port's own
  exclusion property is tested elsewhere.

The body (main shell) writes a PROVISIONAL lease for the lane (real `pool_lease_write`,
port=ORIG — simulating pool_boot_lane step b), runs the subshell, then asserts
`rc==0` AND `pool_lease_field "$lane" port` == NEW port (the lease was updated). The
subshell inherits `AGENT_BROWSER_POOL_STATE` (exported by setup) → its `pool_config_init`
resolves the SAME `POOL_LANES_DIR` → the subshell's `pool_lease_update` writes to the file
the main shell then reads. Inter-body backstop (`rm -f lanes/*.json`) cleans up.

TWO bodies (the contract says "two failure paths trigger the re-pick" — test BOTH):
- `selftest_launch_and_verify_repick_on_launch_fail` — path (a): launch rc 1 on orig.
- `selftest_launch_and_verify_repick_on_cdp_timeout` — path (b): launch rc 0, wait_cdp rc 1 twice.

Both are S1-independent (the mock returns 1 directly; they do NOT rely on S1's grep). The
real end-to-end path-(a) recovery additionally requires S1's `pool_chrome_launch` edit to
have landed (S1 is the immediately-preceding subtask). NOTE this dependency in the PRP.

---

## 8. STRICT-MODE TRAPS (set -euo pipefail, lib/pool.sh line 1) — baked into the design

| Trap | Fix (used) |
|---|---|
| unguarded `pool_chrome_launch` returns 1 → aborts under set -e | wrap in `if pool_chrome_launch …; then … fi` (rc 1 = false condition = fall-through, errexit-exempt) |
| `new_port="$(pool_find_free_port)"` rc 1 aborts | `if ! new_port="$(pool_find_free_port)"; then return 1; fi` |
| `pool_lease_field` rc 1 (in pool_boot_lane re-read) aborts | `reread_port="$(… 2>/dev/null)" \|\| true` + `if [[ =~ && -gt ]]; then port=…; fi` |
| `pool_lease_update` rc (missing lease) → pool_die | trust the lease exists (pool_boot_lane step b just wrote it; same pattern as the existing step-b call) — matches the item's direct call |
| `local x="$(cmd)"` (SC2155) | two-statement `local x; x="$(cmd)"` for `new_port`/`reread_port` |
| bare `(( ))` / standalone `[[ =~ ]]` | inside `if`/`[[ ]] &&` (exempt) |

---

## 9. SCOPE BOUNDARY (S2 vs S1 vs S3)

| Concern | S1 (preceding) | S2 (THIS) | S3 (later) |
|---|---|---|---|
| `pool_chrome_launch` EADDRINUSE grep + return 1 | ✅ | — | — |
| `_pool_launch_and_verify` guard + re-pick + docstring | — | ✅ | — |
| `pool_boot_lane` re-read lease port (integration fix) | — | ✅ (required) | — |
| stale comment fix (§5) | — | ✅ | — |
| `validate.sh` selftests for the re-pick | — | ✅ | — |
| `test/concurrency.sh` collision-recovery test | — | — | ✅ |

S2 does NOT touch: `pool_chrome_launch` (S1), `pool_wait_cdp`, `pool_find_free_port` body,
`pool_ensure_connected`, the close-rebind path (P1.M3), `test/concurrency.sh` (S3).

## 10. SOURCES

- key_findings.md ISSUE 2 (root cause + Fix Approach #2 = "In _pool_launch_and_verify, after
  any launch failure, call pool_find_free_port … retry with the new port. Limit to one port
  re-pick." + #3 "Fix the stale comment").
- lib/pool.sh: current `_pool_launch_and_verify` (2128-2207), `pool_boot_lane` (2208-2310),
  `pool_chrome_launch` (1483-1581), `pool_wait_cdp` (1582-1642), `pool_find_free_port`
  (1388-1482, stale comments ~1328-1331 + ~1377-1379), `pool_lease_update` (768-827),
  `pool_lease_field` (881-922), `pool_lease_write` (687-767).
- test/validate.sh: `_run_selftest_suite` (single-setup, main-shell bodies), `setup`/`assert_eq`/
  `_fail`, S1's `selftest_chrome_launch_eaddrinuse` (the subshell-mock pattern to mirror).
- P1M2T1S1/PRP.md: the S1 contract (pool_chrome_launch return-1-on-EADDRINUSE; grep pattern;
  S1 touches ONLY pool_chrome_launch + its docstring + its selftest — disjoint from S2).
