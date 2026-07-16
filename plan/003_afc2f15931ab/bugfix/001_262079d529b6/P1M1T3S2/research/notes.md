# Research Notes — P1.M1.T3.S2 (relaunch branch identity args + docstrings)

Static read only (per AGENTS.md §1/§2). No Chrome, no shared-sandbox test runs.

## 0. Tree state observed (IMPORTANT — concurrent S1 edit)

S1 (P1.M1.T3.S1) is being implemented IN PARALLEL and is **already applied to the working
tree** as of this research session. Verified via `sed` (greps returned STALE cached data
during the concurrent write — trust the `sed` snapshots below, not intermediate greps):

- `pool_ensure_connected()` now reads **5 jq fields** incl. `.chrome_pid` (S1 Task 1 done):
  `mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected, .chrome_pid' <<<"$json")`
  + `local json session port ephemeral_dir connected chrome_pid now` + coalesce
  `[[ "$chrome_pid" =~ ^[0-9]+$ ]] || chrome_pid=0`.
- The **reconnect branch** now has S1's 3-way `if/elif/else` identity gate
  (`! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"` → fall through to relaunch).
- S1 added test `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect` at
  test/validate.sh:628.
- File grew: lib/pool.sh is now **4588 LOC** (was 4577 pre-S1).

**S2's baseline = S1 applied.** S2 depends on S1 (plan ordering), so by implementation
time S1 will be merged exactly as above.

## 1. S2's code target — the relaunch-branch pool_wait_cdp call

LOCATED (content-grep, robust to line drift): the ONLY 1-arg `pool_wait_cdp "$port"` call
in `pool_ensure_connected` is at **lib/pool.sh:2618** (current S1-applied tree; was 2597
pre-S1 — S1's reconnect restructure shifted it DOWN ~21 lines).

Surrounding relaunch-branch context (verified by `sed -n '2574,2625p'`):
```bash
    # --- c. Chrome DEAD → RELAUNCH on the SAME dir+port (PRD §2.14 "Chrome crash mid-task"). ---
    ...
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"          # ~2584 — sets POOL_CHROME_PID/PGID (declare -g)
    ...
    pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}" # ~2605 (was 2591 pre-S1)
    pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
    ...
    if ! pool_wait_cdp "$port"; then                              # ← LINE 2618 — S2 TARGET (1 arg → identity OFF)
        _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi
```

**The fix (1 line, change arity only):**
- FROM: `    if ! pool_wait_cdp "$port"; then`
- TO:   `    if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then`

Both vars are ALREADY in scope:
- `$ephemeral_dir` — extracted from lease at top of function (jq `_f[2]`).
- `${POOL_CHROME_PID:-}` — set by `pool_chrome_launch` (line ~2584) which runs BEFORE
  pool_wait_cdp. `${:-}` keeps it set -u safe. This mirrors the acquire path's hardened
  reference `_pool_launch_and_verify` (3-arg calls at lib/pool.sh:2302, 2321).

## 2. Why this is correct (pool_wait_cdp's check_identity guard)

pool_wait_cdp (lib/pool.sh:1697) enables identity ONLY when BOTH:
`$user_data_dir` is a non-empty absolute path AND `$expected_pid` matches `^[0-9]+$`.

- After S2: relaunch passes `"$ephemeral_dir"` (abs path, from lease) + `"${POOL_CHROME_PID:-}"`
  (numeric, set by pool_chrome_launch). → `check_identity=1` → after curl succeeds,
  `pool_cdp_is_ours` verifies DevToolsActivePort line1==port AND /proc/$POOL_CHROME_PID exists.
- Defensive edge: if POOL_CHROME_PID is empty (should never happen post pool_chrome_launch),
  the `^[0-9]+$` guard rejects it → identity stays disabled → legacy behavior preserved.

BEHAVIOR on a foreign-Chrome-on-port-after-relaunch race (our relaunched Chrome dies on
EADDRINUSE, a foreign Chrome grabs the port): pool_wait_cdp's identity check keeps polling
→ times out (30s) → kills our pgroup → returns 1 → connected:false (correct: we do NOT
bind to the foreign Chrome). Mirrors _pool_launch_and_verify exactly.

## 3. Docstring targets (2 edits — S2 owns BOTH; untouched by S1/S2-siblings)

Both contain the now-false claim about the ensure_connected relaunch path. Verified
stable at current line numbers (no sibling touches them):

### pool_cdp_is_ours docstring — lib/pool.sh:1613-1615 (function def at 1629)
Current text:
```
# CONSUMER: pool_wait_cdp, immediately after a successful curl /json/version probe.
#   Called ONLY when an identity check is requested (USER_DATA_DIR + EXPECTED_PID both
#   supplied and non-empty); otherwise pool_wait_cdp keeps the legacy probe-only behavior
#   (back-compat for standalone tests / the ensure_connected relaunch path).
```
The 4th line (1615) is the S2 edit: `(back-compat for standalone tests / the ensure_connected relaunch path).`

### pool_wait_cdp docstring — lib/pool.sh:1666-1669 (function def at 1697)
Current text (the IDENTITY VERIFICATION block tail):
```
# ... When the optional
# args are OMITTED, the legacy probe-only behavior is preserved (standalone tests + the
# ensure_connected relaunch path, which already knows its Chrome is bound).
```
Lines 1668-1669 are the S2 edit: `# ensure_connected relaunch path, which already knows its Chrome is bound).`

## 4. Test plan (coexists with S1's tests)

S1 added `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect` (test/validate.sh:628),
which STUBS pool_wait_cdp entirely (`pool_wait_cdp() { return 1; }`) — it proves the
foreign-Chrome fall-through but does NOT verify the relaunch passes identity ARGS. That
is S2's gap.

S2 adds ONE test: `selftest_ensure_connected_relaunch_passes_identity_args` (place
IMMEDIATELY AFTER S1's test at :628, before the `# --- pool_chrome_launch EADDRINUSE
detection` comment). Pattern = S1's test (hermetic subshell, quoted heredoc, single-setup
auto-discovery via `selftest_*` prefix).

Key stubs (the load-bearing part):
- `curl() { return 1; }` — Chrome DEAD → skip reconnect → RELAUNCH branch.
- `pool_chrome_launch() { declare -g POOL_CHROME_PID=4242; declare -g POOL_CHROME_PGID=4242; return 0; }`
  — must `declare -g` (mirrors real pool_chrome_launch) so POOL_CHROME_PID is visible to
  pool_wait_cdp; return 0 (bare call under set -e). No REAL Chrome.
- `pool_wait_cdp() { _wcdp_argc=$#; _wcdp_arg2="${2:-}"; _wcdp_arg3="${3:-}"; return 0; }`
  — RECORDER: capture argc + $2/$3; return 0 so relaunch succeeds (pool_daemon_connect → 0).
- Assert: `_wcdp_argc==3` AND `_wcdp_arg2==<ephemeral_dir>` AND `_wcdp_arg3==4242`.
  This proves the arity change (the load-bearing invariant) WITHOUT booting Chrome.

The deeper BUG-1 identity behavior (foreign Chrome → poll → timeout → kill) is already
covered by the existing pool_wait_cdp identity selftests + _pool_launch_and_verify tests
(test/validate.sh:757, 791) — S2 does not duplicate that.

## 5. set -e / shellcheck considerations

- The edit is arity-only on a line already under `if !` → errexit-exempt. No set -e hazard.
- `${POOL_CHROME_PID:-}` is already used elsewhere (lib/pool.sh:2302 etc.) → SC-clean.
- The 2 docstring edits are comment-only → SC-clean.
- The test's pool_chrome_launch stub uses `declare -g` (not `local`) — correct for globals.
- All existing tests still pass (S1's rebind test stubs pool_cdp_is_ours→0; S2 doesn't touch
  the reconnect branch, so S1's tests are unaffected by S2's relaunch-branch change).

## 6. Validation commands (verified to be the project gates)

- `timeout 30 bash -n lib/pool.sh` (syntax)
- `timeout 60 shellcheck -s bash -S warning lib/pool.sh` (lint — project gate)
- `timeout 30 bash -n test/validate.sh`
- `timeout 60 shellcheck -s bash -S warning test/validate.sh`
- `timeout 600 bash test/validate.sh` (full selftest suite — single-setup runner; isolated
  temp trees; auto-discovers selftest_* via compgen. Must exit 0.)

All wrapped in `timeout` per AGENTS.md §2.
