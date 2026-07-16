# Research Notes — P1.M1.T3.S1 (BUG-1 identity gate on reconnect branch)

Static read only — no processes run (AGENTS.md §1). All line numbers verified against the
**current** working tree (post-P1.M1.T1.S1 reaper fix; the reaper is at ~2874, BELOW
pool_ensure_connected at 2508, so T1's ~8-line insertion did NOT shift our edit sites).

## Verified edit sites (lib/pool.sh)

| Site | Line | Current content | Verified |
|------|------|-----------------|----------|
| jq extraction comment | 2524 | `# Extract the 4 fields we need in ONE jq fork (comma → N lines; mapfile -t strips \n):` | ✓ |
| jq extraction mapfile | 2532 | `mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")` | ✓ |
| field assignments | 2533-2538 | session/port/ephemeral_dir/connected + connected coalesce | ✓ |
| reconnect-branch comment | 2560 | `# --- c. NOT connected. Chrome alive? curl /json/version (NOT kill -0 — research §2). ---` | ✓ |
| reconnect branch body | 2561-2572 | `if curl ...; then if pool_daemon_connect ...; fi ... fi` | ✓ |

## Verified identity primitives (lib/pool.sh)

- `pool_cdp_is_ours()` at **1629-1652** — 3 args (PORT UDD PID); 2-signal check (DevToolsActivePort
  line1==PORT AND /proc/PID exists); returns 0=ours, 1=not-provably-ours (NON-FATAL). Args guarded
  internally (bad arg → return 1). ✓
- `pool_wait_cdp()` at **1697-1741** — `check_identity=1` only when UDD abs-path AND PID numeric.
  Single-arg call → `check_identity=0` (legacy probe-only). **The relaunch branch's `pool_wait_cdp
  "$port"` (1-arg) is S2's scope, NOT S1.** S1 touches ONLY the reconnect branch + jq extraction. ✓

## pool_lease_write field order (lib/pool.sh:713) — VERIFIED

Args (positional): LANE(1) EPHEMERAL_DIR(2) PORT(3) SESSION(4) OWNER_PID(5) OWNER_COMM(6)
OWNER_STARTTIME(7) OWNER_CWD(8) **CHROME_PID(9)** CHROME_PGID(10) CONNECTED(11).
JSON key for chrome pid = **`chrome_pid`** (lib/pool.sh:38 `--argjson chrome_pid`, :46
`chrome_pid:$chrome_pid`). So the jq 5th field must read `.chrome_pid`. ✓

## Test impact — VERIFIED

`selftest_ensure_connected_rebinds_when_disconnected` (test/validate.sh:560-588):
- Lease: `pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 false` → chrome_pid=**200**.
- Stubs (lines 575-578): `pool_daemon_connected()→0`, `curl()→0`, `pool_daemon_connect()` records
  `_connect_called=1`+→0. The `pool_daemon_connected() { return 0; }` line (575, comment-free) is
  **unique** in the file (the skips_rebind variant at :608 carries a trailing comment).
- After the fix: jq reads chrome_pid=200 → guard `200>0` TRUE → `pool_cdp_is_ours` called. With NO
  DevToolsActivePort file + dead /proc/200 → returns 1 → fall through to relaunch →
  pool_chrome_launch (REAL CHROME — AGENTS.md violation) + `_connect_called` stays 0 → assertion
  `test "$_connect_called" = "1"` FAILS. **CONFIRMED the test breaks.**
- FIX (Option A, preferred per item spec): add stub `pool_cdp_is_ours() { return 0; }` to the body
  → gate passes → reconnect fires → `_connect_called=1`, connected→true. Lease write UNCHANGED
  (chrome_pid=200 is a valid positive int; the stub overrides the /proc check).

`selftest_ensure_connected_skips_rebind_when_connected` (test/validate.sh:593-615): connected=true +
pool_daemon_connected→0 → early-exit at step b → curl/identity-gate NEVER reached. **UNAFFECTED.** ✓

## Regression test design decision — foreign-chrome-on-reconnect

The naive assertion "pool_daemon_connect NOT called" is **insufficient**: if the identity gate fails
and we fall through to the relaunch branch, the relaunch ALSO calls pool_daemon_connect (after a
successful pool_wait_cdp), so `_connect_called` would be 1 regardless. To make the assertion
load-bearing and the test HERMETIC (no real Chrome), the body MUST:
1. stub `pool_chrome_launch() → no-op` (prevent REAL Chrome — AGENTS.md §1; record `_relaunch_called=1`
   to prove we fell through to relaunch), AND
2. stub `pool_wait_cdp() → 1` (simulate relaunch "CDP timeout" → pool_ensure_connected returns 1
   BEFORE the relaunch's pool_daemon_connect), AND
3. assert `_connect_called==0` (proves the RECONNECT branch did not bind the foreign Chrome) +
   `_relaunch_called==1` (proves fall-through) + rc!=0.

Chose **connected=true + pool_daemon_connected()→1** (faithful to the PRD 5-step "daemon restarted"
scenario; makes BOTH the connected flag and the daemon stub meaningful — no dead-code stubs).
Stubbing curl→0, pool_cdp_is_ours→1 models the foreign Chrome answering our port.

## Parallel-subtask safety (CONTRACT)

- **P1.M1.T1.S1** (reaper) — COMPLETE. Edited pool_reap_orphan_dirs (~2874) + added
  selftest_reap_orphan_dirs_kills_only_target_lane. DISJOINT function from pool_ensure_connected (2508).
  Its ~8-line insertion at ~2889 is BELOW pool_ensure_connected → did NOT shift our line numbers. ✓
- **P1.M1.T2.S1** (doctor/ss) — IN PARALLEL. Edits pool_admin_doctor (~4258+) + adds
  selftest_doctor_ss_optional_when_missing (after selftest_doctor_flags_disconnected_lease ~882).
  DISJOINT function (doctor vs ensure_connected) + DISJOINT test region (852-990 vs our 560-620). Its
  edits are all BELOW pool_ensure_connected AND below our test region → no line-number shift for us. ✓
- S1's OWN scope (this PRP): reconnect branch + jq extraction + comment (lib/pool.sh 2524-2572) +
  fix selftest_ensure_connected_rebinds_when_disconnected (test/validate.sh 560-588) + add
  selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (after :615). The relaunch-branch
  `pool_wait_cdp` 3-arg fix + pool_wait_cdp/pool_cdp_is_ours docstring updates are **S2's scope** —
  S1 MUST NOT touch them.

## Baseline static gates (research-safe)

- `bash -n lib/pool.sh` → OK
- `bash -n test/validate.sh` → OK
- `shellcheck -s bash -S warning lib/pool.sh` → OK (project gate is `-S warning`)
