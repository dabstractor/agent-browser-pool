# Research: Codebase Concurrency Facts for PRD §2.18 Concurrency Test

**Date**: 2026-07-13  
**Purpose**: Precise codebase facts to support writing the CONCURRENCY test (N parallel agents with distinct owner PIDs get distinct lanes; assert no two share a lane and all release cleanly).

---

## Summary

The agent-browser-pool uses an exclusive `flock` on `$POOL_LOCK_FILE` during the acquire critical section (`pool_acquire_locked`, line 2043) to serialize lane selection — guaranteeing N parallel agents with distinct PIDs each get a distinct lane number. The critical section writes a provisional lease file before releasing the lock, so the next acquirer sees the lane as occupied. A real Chrome acquire additionally requires: a non-empty master profile (confirmed present on this host), btrfs or `AGENT_CHROME_ALLOW_SLOW_COPY=1` (cannot verify FS type from file reads alone), and `$POOL_REAL_BIN` (confirmed present as an ELF binary). The test framework (`test/validate.sh`, already LANDED) provides `spawn_sim_owner`, `setup`/`teardown`, and assertion helpers. The framework's `setup()` exports ONE owner PID, but `spawn_sim_owner` can be called N times in the test body for N distinct owners.

---

## 1. Key Function Reference (lib/pool.sh)

### pool_config_init() — line ~126 (no args)
- **What it does**: Resolves every configuration override to validated absolute POOL_* globals. Canonicalizes all paths via `realpath -m` against `$HOME`. Called once near the top of `bin/agent-browser` and `bin/agent-browser-pool` (re-callable for tests — globals are MUTABLE, not readonly).
- **rc contract**: rc 0 on success; `pool_die` (exit 1) if `$HOME` unset/unresolvable, a numeric var is non-numeric, or `PORT_RANGE <= 0`.
- **Globals WRITTEN**: `POOL_HOME_DIR`, `POOL_STATE_DIR`, `POOL_MASTER_DIR`, `POOL_EPHEMERAL_ROOT`, `POOL_REAL_BIN`, `POOL_CHROME_BIN`, `POOL_PORT_BASE`, `POOL_PORT_RANGE`, `POOL_WAIT`, `POOL_HEADLESS`, `POOL_DISABLE`, `POOL_ALLOW_SLOW_COPY`, `POOL_LANES_DIR`, `POOL_LOCK_FILE` (all via `declare -g`).
- **Env vars honored**: `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_MASTER`, `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_BROWSER_REAL`, `AGENT_CHROME_BIN`, `AGENT_CHROME_PORT_BASE`, `AGENT_CHROME_PORT_RANGE`, `AGENT_BROWSER_POOL_WAIT`, `AGENT_CHROME_HEADLESS`, `AGENT_BROWSER_POOL_DISABLE`, `AGENT_CHROME_ALLOW_SLOW_COPY`.
- **Key for concurrency test**: The test's `setup()` overrides `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_CHROME_MASTER` to a temp root, then calls `pool_config_init` + `pool_state_init` to re-resolve.

### pool_state_init() — line ~202 (no args)
- **What it does**: Creates `POOL_LANES_DIR` (`mkdir -p`) and touches `POOL_LOCK_FILE`. Idempotent.
- **rc contract**: rc 0 on success; `pool_die` if `mkdir`/`touch` fails for a real FS reason.
- **Globals READ**: `POOL_LANES_DIR`, `POOL_LOCK_FILE`.
- **Called by**: `pool_acquire_locked` (line 2043, first thing), `bin/agent-browser-pool` (unconditionally before dispatch).

### pool_check_btrfs() — line ~230 (no args)
- **What it does**: Refuses a non-btrfs ephemeral root unless `POOL_ALLOW_SLOW_COPY=1`. Uses `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"`. Echoes the detected FSTYPE on success.
- **rc contract**: rc 0 if btrfs OR slow-copy allowed; `pool_die` otherwise.
- **Globals READ**: `POOL_EPHEMERAL_ROOT`, `POOL_ALLOW_SLOW_COPY`.
- **NOTE**: This function is NOT called by `pool_copy_master` directly — `pool_copy_master` uses `cp --reflink=always` and its exit code IS the btrfs detection. `pool_check_btrfs` is a separate gate that can be called independently.

### pool_check_master() — line ~266 (no args)
- **What it does**: Verifies `$POOL_MASTER_DIR` exists (`-d`) and is non-empty (`ls -A`).
- **rc contract**: rc 0 when dir exists + non-empty; `pool_die` with a cp command otherwise.
- **Globals READ**: `POOL_MASTER_DIR`.

### pool_lease_write() — line ~682
```bash
pool_lease_write LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM \
                 OWNER_STARTTIME OWNER_CWD CHROME_PID CHROME_PGID CONNECTED
```
- **What it does**: Builds the full lease object via `jq -n` and publishes it atomically to `$POOL_LANES_DIR/<LANE>.json` (tmp+mv in same directory → same FS → atomic rename). Both `acquired_at` and `last_seen_at` are stamped to `_pool_now()` (captured once → they match).
- **rc contract**: rc 0 on success; `pool_die` if lane is non-numeric, `connected` is not `true`/`false`, jq build fails, or atomic write fails.
- **Globals READ**: `POOL_LANES_DIR` (via `_pool_atomic_write`).
- **Lease JSON schema produced** (EXACT, from the jq filter at line ~720):
```json
{
  "version": 1,
  "lane": <number>,
  "ephemeral_dir": <string>,
  "port": <number>,
  "session": <string>,
  "owner": {
    "pid": <number>,
    "comm": <string>,
    "starttime": <number>,
    "cwd": <string>
  },
  "chrome_pid": <number>,
  "chrome_pgid": <number>,
  "acquired_at": <number>,
  "last_seen_at": <number>,
  "connected": <boolean>
}
```
  **NOTE**: `session` is a TOP-LEVEL field, not nested under `owner`. The field is `ephemeral_dir` (not `dir`). `version` is fixed at 1.

### pool_lease_field() — line ~884
```bash
pool_lease_field LANE FIELD
```
- **What it does**: Reads one field from `$POOL_LANES_DIR/<LANE>.json` and echoes its raw value. FIELD is a jq-style DOTTED PATH — top-level (`port`, `connected`, `chrome_pid`, `last_seen_at`, `session`, `lane`) OR nested (`owner.pid`, `owner.starttime`, `owner.comm`, `owner.cwd`).
- **rc contract**: rc 0 + echoes value on success (even echoes `null` for a missing path — rc 0); rc 1 (silent, no output) on missing file, corrupt JSON, invalid lane, or empty field.
- **set -e HAZARD**: Returns 1 on missing/corrupt → bare call ABORTS under `set -e`. MUST guard: `pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || true` or `if pid="$(...)"; then`.
- **Globals READ**: `POOL_LANES_DIR`.

### pool_lease_exists() — line ~918
```bash
pool_lease_exists LANE
```
- **What it does**: Predicate — does lane N have a VALID lease file (exists + valid JSON)?
- **rc contract**: rc 0 (valid) / rc 1 (missing/corrupt/non-numeric lane). NEVER fatal.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if pool_lease_exists "$n"; then`.

### pool_lanes_list() — line ~967 (no args)
- **What it does**: Enumerates every numeric lane stem from `$POOL_LANES_DIR/*.json`, numerically sorted ascending. **Always returns 0** — empty/missing dir is valid (no-match glob → 0 iterations → no output).
- **rc contract**: rc 0 ALWAYS.
- **Usage**: `for n in $(pool_lanes_list); do ...; done` — the unquoted command substitution is intentional (word-splits on newlines into lane numbers).
- **set -e SAFE**: rc 0 always → bare iteration is safe.

### pool_lease_find_mine() — line ~1010 (no args)
- **What it does**: Finds MY valid lease — scans every lane for the first whose `owner.pid == POOL_OWNER_PID` AND `pool_owner_alive(pid, starttime, comm)` is true. Echoes lane N + return 0 on match; return 1 on no match.
- **rc contract**: rc 0 (found) / rc 1 (not found). Non-fatal.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if n="$(pool_lease_find_mine)"; then`.
- **Globals READ**: `POOL_OWNER_PID`, `POOL_LANES_DIR`.

### pool_find_free_lane() — line 1101 (no args)
- **What it does**: Walks N = 1, 2, 3, … and echoes the first N where BOTH `$POOL_EPHEMERAL_ROOT/$N` dir is absent AND `$POOL_LANES_DIR/$N.json` lease file is absent. **Always echoes a value and returns 0** — there is no "no free lane" failure (lanes are unbounded). Used INSIDE the flock critical section.
- **rc contract**: rc 0 ALWAYS (echoes a lane number).
- **set -e SAFE**: Bare `N="$(pool_find_free_lane)"` is safe (no `if` guard needed).
- **Globals READ**: `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`.
- **KEY for concurrency**: This is what guarantees distinct lanes — the provisional lease is written by `_pool_acquire_critical_section` BEFORE releasing the flock, so the next acquirer sees the lane as occupied.

### pool_lane_is_stale() — line ~1164
```bash
pool_lane_is_stale LANE
```
- **What it does**: TRI-STATE verdict: rc 0 = STALE (owner dead/recycled), rc 1 = LIVE (owner alive + identity matches), rc 2 = NO LEASE (missing/corrupt).
- **rc contract**: TRI-STATE (0/1/2). NEVER fatal. The rc convention is INVERTED vs `pool_owner_alive` (which returns 0=alive / 1=dead).
- **set -e HAZARD**: Bare call with rc 1 or 2 ABORTS under `set -e`. MUST use `if pool_lane_is_stale "$n"; then <reap>; fi` (rc 1/2 fall through) or `pool_lane_is_stale "$n" && rc=0 || rc=$?`.
- **Globals READ**: `POOL_LANES_DIR` (via `pool_lease_read`).

### pool_copy_master() — line ~1253
```bash
pool_copy_master TARGET_DIR
```
- **What it does**: Copies `$POOL_MASTER_DIR` → `TARGET_DIR` as a flat profile via `cp -a --reflink=always` (instant CoW on btrfs). On non-btrfs: retries with `cp -a` only if `POOL_ALLOW_SLOW_COPY=1`; otherwise `pool_die`. Removes stale Singleton* locks afterward.
- **rc contract**: rc 0 on success; `pool_die` on any failure (non-btrfs + no slow-copy, slow copy fail, rm fail).
- **Globals READ**: `POOL_MASTER_DIR`, `POOL_ALLOW_SLOW_COPY`, `POOL_EPHEMERAL_ROOT` (parent mkdir).
- **Env vars honored**: `AGENT_CHROME_ALLOW_SLOW_COPY` (via `POOL_ALLOW_SLOW_COPY`).

### pool_find_free_port() — line ~1376 (no args)
- **What it does**: Echoes the lowest free TCP port in `[POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE)` and returns 0; returns 1 if the whole range is occupied. Three-stage free test: not claimed by any lease, not listening (`ss -tlnH`), not answering CDP (`curl /json/version`). Runs OUTSIDE the flock.
- **rc contract**: rc 0 (echoes port) / rc 1 (exhausted). Non-fatal.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if port="$(pool_find_free_port)"; then`.
- **Globals READ**: `POOL_PORT_BASE`, `POOL_PORT_RANGE`, `POOL_LANES_DIR` (via helpers).

### pool_chrome_launch() — line 1471
```bash
pool_chrome_launch PORT USER_DATA_DIR LANE
```
- **What it does**: Launches Chrome via `setsid` (pgid==pid) on PORT with USER_DATA_DIR, writing combined stdout/stderr to `$POOL_STATE_DIR/chrome-<LANE>.log`. Exports globals `POOL_CHROME_PID` and `POOL_CHROME_PGID` (via `declare -g`). Flag list: `--remote-debugging-port`, `--user-data-dir`, `--no-first-run`, `--no-default-browser-check`, `--disable-background-timer-throttling`, `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`, `--disable-features=CalculateNativeWinOcclusion`, `--disable-back-forward-cache`, (+ `--headless=new` iff `POOL_HEADLESS==1`).
- **rc contract**: rc 0 on success; `pool_die` on bad args, instant Chrome death (pgid capture empty), or missing log dir.
- **Globals WRITTEN**: `POOL_CHROME_PID`, `POOL_CHROME_PGID` (declare -g).
- **Globals READ**: `POOL_CHROME_BIN`, `POOL_HEADLESS`, `POOL_STATE_DIR`.
- **Env vars honored**: `AGENT_CHROME_BIN`, `AGENT_CHROME_HEADLESS`.

### pool_wait_cdp() — line 1570
```bash
pool_wait_cdp PORT
```
- **What it does**: Polls Chrome's CDP HTTP endpoint (`http://127.0.0.1:<PORT>/json/version`) until it answers (curl -sf rc 0) or the budget is exhausted (60 × 0.5s = 30s). On timeout: kills the Chrome process group (`kill -- -<POOL_CHROME_PGID>`), then returns 1.
- **rc contract**: rc 0 (CDP ready) / rc 1 (timeout, Chrome pgroup already killed). Non-fatal — never `pool_die`.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if pool_wait_cdp "$port"; then`.
- **Globals READ**: `POOL_CHROME_PGID` (for the timeout kill).

### pool_daemon_connect() — line 1631
```bash
pool_daemon_connect SESSION PORT
```
- **What it does**: Binds the agent-browser daemon session SESSION to the pooled Chrome on PORT by running `$POOL_REAL_BIN --session "$SESSION" connect "$PORT"`. Returns the subprocess rc.
- **rc contract**: rc 0 on success (live chrome + binds); rc 1 on failure (dead port / unreachable). Non-fatal.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if pool_daemon_connect ...; then`.
- **Globals READ**: `POOL_REAL_BIN`.

### pool_boot_lane() — line 2185
```bash
pool_boot_lane LANE
```
- **What it does**: Provisions a lane from provisional (port=0) to fully-provisioned: COPY master → PORT → LAUNCH+WAIT (retry once) → CONNECT daemon → finalize LEASE. Runs OUTSIDE the flock.
- **rc contract**: rc 0 (provisioned) / rc 1 (cleaned up via `_pool_release_lane_internals`) / `pool_die` (fatal misconfiguration: non-btrfs copy fail, chrome instant-exit).
- **Recoverable failures (→ rc 1, lane cleaned up)**: port range exhausted, CDP timeout twice, daemon connect fail.
- **Fatal failures (→ pool_die propagates)**: pool_copy_master non-btrfs/no-slow-copy, pool_chrome_launch instant-exit.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if pool_boot_lane "$N"; then` or `pool_boot_lane "$N" || <handle>`.
- **Globals READ**: `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR` (via helpers), `POOL_REAL_BIN` (via `pool_daemon_connect`), `POOL_CHROME_PID`/`POOL_CHROME_PGID` (via `_pool_boot_write_chrome_ids`).

### pool_ensure_connected() — line 2288
```bash
pool_ensure_connected LANE
```
- **What it does**: Per-invocation self-heal. Given an already-booted lane (port>0), verifies it's STILL drivable; if not, reconnects (re-bind daemon) or relaunches (restart Chrome on same dir+port). Returns 0 if connected (was-already OR reconnected OR relaunched); 1 on failure.
- **rc contract**: rc 0 / rc 1. NEVER drops the lane (that's the wrapper's/reaper's job). NEVER `pool_die` in its body (pool_chrome_launch instant-exit is fatal + propagates).
- **set -e HAZARD**: rc 1 aborts bare. MUST use `pool_ensure_connected "$N" || <handle>`.
- **Globals READ**: `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`, `POOL_CHROME_PID`/`POOL_CHROME_PGID` (via helpers).

### pool_acquire_locked() — line 2043 (no args)
- **What it does**: PUBLIC ENTRY POINT — acquires a lane under an exclusive flock on `$POOL_LOCK_FILE`. Runs `_pool_acquire_critical_section` inside `( flock 9; <body> ) 9>"$POOL_LOCK_FILE"`. The lock is held ONLY for scan+reap+reuse+choose+claim (NO Chrome launch/copy/wait inside the lock). Echoes the claimed/adopted lane N + return 0 on success; echoes nothing + return 1 on exhaustion.
- **rc contract**: rc 0 (echoes lane N) / rc 1 (exhaustion). Non-fatal.
- **set -e HAZARD**: rc 1 aborts bare. MUST use `if N="$(pool_acquire_locked)"; then`.
- **Globals READ**: `POOL_LOCK_FILE` (+ everything `_pool_acquire_critical_section` reads).
- **CRITICAL SECTION TRACE** (`_pool_acquire_critical_section`, line ~1960):
  1. Guard: `POOL_OWNER_PID` must be numeric and != 0.
  2. For each lane in `pool_lanes_list`: `pool_lane_is_stale` rc 0 (stale) → if Chrome responsive (`pool_daemon_connected`) → ADOPT (reuse-orphan, skip boot); else REAP (`_pool_release_lane_internals`).
  3. CHOOSE-N: `pool_find_free_lane` → N (always echoes + rc 0).
  4. CLAIM: `pool_lease_write N "$ephemeral_dir" 0 "abpool-$N" "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" "${POOL_OWNER_CWD:-}" 0 0 "false"` — writes the PROVISIONAL lease (port=0, chrome_pid=0, chrome_pgid=0, connected=false).
  5. echo N; return 0.

### pool_wrapper_main() — line 3452 (called with `"$@"`)
- **What it does**: The COMPLETE lifecycle — PRD §2.4 steps 0→5. Called by `bin/agent-browser` as its FINAL statement. TERMINAL by design: every success path ends in `exec "$POOL_REAL_BIN" ...`; every fatal path ends in `pool_die`.
- **Flow**: config+state init → POOL_DISABLE? → dispatch classify (meta/driving) → owner resolve (pid==0? passthrough) → find-or-acquire lane → boot/adopt → ensure_connected → normalize close/connect → strip+force session → `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"`.
- **POOL_REAL_BIN usage in exec**: `exec "$POOL_REAL_BIN" "$@"` (passthrough — meta/no-owner/disable, original args unchanged) OR `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (driving — cleaned args + AGENT_BROWSER_SESSION=abpool-<N> exported).
- **What happens if POOL_REAL_BIN doesn't exist**: `exec /nonexistent` → the shell exits with rc 127 (bash behavior for exec of a non-existent file). Under `set -e`, this is a fatal exit. The exec REPLACES the process, so there is no recovery. For the daemon connect/close subprocess calls, if POOL_REAL_BIN doesn't exist, the subprocess fails (rc 127) → `pool_daemon_connect` returns 1, `pool_release_lane`'s close is `|| true` (ignored).

### pool_release_lane() — line 2438
```bash
pool_release_lane LANE
```
- **What it does**: Full teardown of one lane: (1) read lease for session; (2) daemon disconnect: `$POOL_REAL_BIN --session "$session" close`; (3) delegate to `_pool_release_lane_internals` (kill Chrome pgroup + rm dir + rm lease). Idempotent.
- **rc contract**: rc 0 ALWAYS (non-fatal, idempotent). Missing lease → return 0; bad lane → return 0.
- **set -e SAFE**: rc 0 always → bare call is safe.
- **Globals READ**: `POOL_REAL_BIN`, `POOL_LANES_DIR` (via helpers).

### pool_admin_release() — line 3830
```bash
pool_admin_release [TARGET]
```
- **What it does**: User-facing release command. TARGET=="all" → snapshot `pool_lanes_list`, `pool_release_lane` each, print "Released N lane(s)." TARGET numeric → probe `pool_lease_exists`, delegate `pool_release_lane`, print "Released lane N." / "Lane N has no active lease." Empty/invalid → usage to stderr.
- **rc contract**: rc 0 for successful releases; rc 1 for usage-error + targeted-not-found.
- **`release all` vs calling `pool_release_lane` directly**: `release all` is equivalent to iterating `pool_lanes_list` and calling `pool_release_lane` for each. The difference: `release all` is invoked as a SUBPROCESS (`"$ABPOOL_ADMIN" release all`), so a `pool_die` inside the admin tool cannot kill the test harness. Direct `pool_release_lane` calls run in-process (faster, but a `pool_die` would exit the shell — however, `pool_release_lane` itself never `pool_die`s).

---

## 2. Lease JSON Schema (CONFIRMED from pool_lease_write, line ~682)

EXACT field names + nesting:

| Field | Type | Level | Notes |
|---|---|---|---|
| `version` | number | top | Fixed at 1 |
| `lane` | number | top | The lane number N |
| `ephemeral_dir` | string | top | `$POOL_EPHEMERAL_ROOT/$N` |
| `port` | number | top | Chrome DevTools port (0 = provisional) |
| `session` | string | top | `abpool-$N` |
| `owner.pid` | number | nested | The owning pi PID |
| `owner.comm` | string | nested | Always "pi" |
| `owner.starttime` | number | nested | /proc/pid/stat field 22 (clock ticks) |
| `owner.cwd` | string | nested | Owner's working dir |
| `chrome_pid` | number | top | Chrome process PID (0 = provisional) |
| `chrome_pgid` | number | top | Chrome process-group ID (== pid; 0 = provisional) |
| `acquired_at` | number | top | Unix epoch seconds |
| `last_seen_at` | number | top | Unix epoch seconds (heartbeat) |
| `connected` | boolean | top | true/false (JSON boolean, NOT 1/0) |

**Important**: `session` is TOP-LEVEL, not nested under `owner`. The field name is `ephemeral_dir` (not `dir`). `connected` is a JSON boolean literal (`true`/`false`), never the number `1`.

**Provisional lease** (written by `_pool_acquire_critical_section`): `port=0`, `chrome_pid=0`, `chrome_pgid=0`, `connected=false`. After `pool_boot_lane`: `port>0`, `chrome_pid>0`, `chrome_pgid>0`, `connected=true`.

---

## 3. POOL_REAL_BIN Usage

| Location | Usage | What happens if missing |
|---|---|---|
| `pool_wrapper_main` step k (line ~3505) | `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` | Shell exits rc 127 (exec of non-existent file). Fatal. |
| `pool_wrapper_main` passthrough (lines ~3462, 3469, 3474) | `exec "$POOL_REAL_BIN" "$@"` | Same — shell exits rc 127. |
| `pool_daemon_connect` (line ~1656) | `"$POOL_REAL_BIN" --session "$session" connect "$port"` | Subprocess fails → returns 1 (non-fatal). |
| `pool_daemon_connected` (line ~1711) | `"$POOL_REAL_BIN" --session "$session" --json session list` | Subprocess fails → returns 1 (non-fatal). |
| `pool_release_lane` (line ~2460) | `"$POOL_REAL_BIN" --session "$session" close` | Guarded by `[[ -n "${POOL_REAL_BIN:-}" ]]` + `|| true`. Ignored. |

**Confirmed present**: `/home/dustin/.local/bin/agent-browser` EXISTS as an ELF binary (verified by reading — it's a real executable). This is the default `POOL_REAL_BIN` when `AGENT_BROWSER_REAL` is unset.

---

## 4. bin/agent-browser and bin/agent-browser-pool — Full Content + Dispatch

### bin/agent-browser (complete, 10 lines)
```bash
#!/usr/bin/env bash
set -euo pipefail
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"
```
- **Dispatch**: Sources `lib/pool.sh`, delegates entirely to `pool_wrapper_main "$@"`. TERMINAL — runs nothing after.

### bin/agent-browser-pool (complete, ~20 lines)
```bash
#!/usr/bin/env bash
set -euo pipefail
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
```
- **Dispatch**: `pool_config_init` + `pool_state_init` unconditionally, then `case` on `$cmd`. Default command is `status`. `release` passes `${2:-}` (the target) to `pool_admin_release`.

---

## 5. Test Framework API (test/validate.sh — ALREADY LANDED)

**STATUS**: `test/validate.sh` EXISTS (verified by reading — 6 selftest functions, not 7; the `selftest_wrapper_and_admin_are_executable` is absent in the landed version, but the core API is complete and matches the PRP).

### Module-level globals
```bash
VALIDATE_DIR   # test/ dir (absolute)
ABPOOL_REPO    # repo root (absolute)
ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"
ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"
ABPOOL_PASS, ABPOOL_FAIL  # counters
ABPOOL_FAILED              # array of failed test names
ABPOOL_TMP_ROOT, ABPOOL_TEST_ROOT  # temp roots
ABPOOL_CUR_OWNER           # the CURRENT test's sim-owner PID (killed by teardown)
ABPOOL_SIM_BINS            # array of temp dirs holding "pi" binaries (cleaned by trap)
```

### Helper API (verbatim signatures)

```bash
_fail()                    # _fail MSG — prints to stderr + return 1. NEVER exits.

assert_eq()                # assert_eq EXPECTED ACTUAL [LABEL] — returns 0/1
assert_lane_exists()       # assert_lane_exists N — $POOL_LANES_DIR/N.json file present?
assert_lane_gone()         # assert_lane_gone N — no lease file AND no ephemeral dir
assert_no_dir()            # assert_no_dir PATH — path does not exist
assert_no_chrome()         # assert_no_chrome [ROOT] — no Chrome under --user-data-dir=$ROOT

spawn_sim_owner()          # spawn_sim_owner [SECONDS=600] — echoes PID of a LIVE "pi"-comm process

setup()                    # Hermetic per-test env: mktemp root, exports HOME/STATE/EPHEMERAL/MASTER/HEADLESS,
                           # calls pool_config_init + pool_state_init, spawns ONE sim owner,
                           # exports AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME

teardown()                 # "$ABPOOL_ADMIN" release all (subprocess) || true; kill ABPOOL_CUR_OWNER

run_test()                 # run_test NAME FN — setup; ( set -e; "$fn" ) || rc=$?; teardown; tally

abpool_run_suite()         # abpool_run_suite [PREFIX=test_] — enumerate functions by prefix, run each, exit rc 1 on any fail
```

### What setup() exports (per test)
- `HOME` = `$ABPOOL_TEST_ROOT/home`
- `AGENT_BROWSER_POOL_STATE` = `$ABPOOL_TEST_ROOT/state`
- `AGENT_CHROME_EPHEMERAL_ROOT` = `$ABPOOL_TEST_ROOT/active`
- `AGENT_CHROME_MASTER` = `$ABPOOL_TEST_ROOT/master` (mkdir -p'd but EMPTY — just a dir)
- `AGENT_CHROME_HEADLESS=1`
- `AGENT_BROWSER_POOL_OWNER_PID` = the ONE sim-owner PID
- `AGENT_BROWSER_POOL_OWNER_STARTTIME` = the sim-owner's real starttime (via `_pool_get_starttime`)

### What spawn_sim_owner returns
- Echoes the PID of a background process whose `/proc/<pid>/comm == "pi"` (settled via poll loop).
- Appends the temp bin dir to `ABPOOL_SIM_BINS` (for the EXIT trap cleanup).
- Each call returns a UNIQUE PID (different process). Can be called N times.

### The EXIT/INT/TERM trap
```bash
_abpool_global_cleanup() {
    kill "$ABPOOL_CUR_OWNER" 2>/dev/null || true    # kills ONE owner
    for d in "${ABPOOL_SIM_BINS[@]:-}"; do rm -rf "$d" || true; done  # removes ALL bin dirs
    rm -rf "$ABPOOL_TMP_ROOT" || true               # removes the temp root
}
```
- Kills only `ABPOOL_CUR_OWNER` (the ONE setup-allocated owner). Additional owners spawned in the test body are NOT killed by the trap — the test body must kill them.

---

## 6. Host Environment Conditions (checked via file reads)

### Master profile
- **`/home/dustin/.agent-chrome-profiles/master-profile`** — **EXISTS** (EISDIR on read → it's a directory). **NON-EMPTY**: contains `Local State` (66.5KB Chrome profile file). So `pool_check_master` would PASS here.
- This CONTRADICTS the PRP's claim "there is NO master profile under the real ~/.agent-chrome-profiles/master-profile on this checkout" — a master profile IS present now.

### POOL_REAL_BIN
- **`/home/dustin/.local/bin/agent-browser`** — **EXISTS** as an ELF binary (confirmed by read). So `pool_admin_doctor`'s binary check would PASS.

### Filesystem type
- **CANNOT verify from file reads alone.** The test author MUST run `stat -f -c %T .` or `findmnt -nno FSTYPE -T "$HOME"` to confirm btrfs. The PRP notes the host was verified for findmnt -T behavior. If NOT btrfs, `AGENT_CHROME_ALLOW_SLOW_COPY=1` must be set for a real acquire (otherwise `pool_copy_master` → `pool_die`).

### Ephemeral dirs at ~/.agent-chrome-profiles/
- **`/home/dustin/.agent-chrome-profiles/active`** — **EXISTS** (directory).
- **`/home/dustin/.agent-chrome-profiles/active/1`** — **EXISTS** (directory), but `active/1/Local State` does NOT exist → likely an EMPTY leftover directory.
- **DO NOT MATTER for an isolated test**: The test's `setup()` overrides `AGENT_CHROME_EPHEMERAL_ROOT` to a temp root (`$ABPOOL_TEST_ROOT/active`). The real `~/.agent-chrome-profiles/active/` is never touched. These are leftover artifacts from a prior real pool run.

### test/validate.sh existence
- **EXISTS** — already landed by M9.T1.S1 (6 selftest functions present).

---

## 7. Ephemeral Leftover Dirs

The dirs at `~/.agent-chrome-profiles/active/` and `~/.agent-chrome-profiles/{1..10}` are leftovers from prior real pool operations. They are **irrelevant for an isolated test** because:
1. `setup()` exports `AGENT_CHROME_EPHEMERAL_ROOT` to a `mktemp -d` temp root.
2. `setup()` exports `AGENT_BROWSER_POOL_STATE` to a temp root (different `POOL_LANES_DIR`).
3. `setup()` exports `HOME` to a temp root (different `POOL_HOME_DIR`).
4. `pool_config_init` anchors ALL defaults on `realpath($HOME)`, so every derived path is under the temp root.

The ONLY way these leftovers would matter is if the test does NOT override `HOME` or the pool roots (which `setup()` does).

---

## Critical Questions A–G

### A. Can a test body call the wrapper by ABSOLUTE PATH with AGENT_BROWSER_POOL_OWNER_PID and get a REAL acquire?

**YES, under these preconditions:**

1. **`AGENT_BROWSER_POOL_OWNER_PID` must be set + numeric + point at a REAL `pi`-comm process.** The override sets the lease's owner IDENTITY, but `pool_owner_alive` (line 616) reads the REAL `/proc/<pid>/comm` and requires `"pi"`. `spawn_sim_owner` handles this (copies `/usr/bin/sleep` to a file named `pi`, exec's it → comm=="pi").

2. **Master template must exist + be non-empty** (`pool_check_master`, line 266). `setup()` creates an EMPTY `$ABPOOL_TEST_ROOT/master` — it would FAIL `pool_check_master`. For a real acquire, the test must populate it (e.g., `cp -a ~/.agent-chrome-profiles/master-profile/* "$ABPOOL_TEST_ROOT/master/"` or point `AGENT_CHROME_MASTER` at the real master). **Confirmed: the real master at `~/.agent-chrome-profiles/master-profile` EXISTS and is non-empty.**

3. **btrfs OR `AGENT_CHROME_ALLOW_SLOW_COPY=1`** (`pool_copy_master`, line 1253). `cp --reflink=always` fails on non-btrfs; without the escape hatch, `pool_die`. **Cannot verify FS type from file reads.**

4. **`$POOL_REAL_BIN` must exist + be executable** (for `pool_daemon_connect` and the final `exec`). `setup()` does NOT override `AGENT_BROWSER_REAL` → it defaults to `$POOL_HOME_DIR/.local/bin/agent-browser` = `$ABPOOL_TEST_ROOT/home/.local/bin/agent-browser` (does NOT exist). **The test MUST override `AGENT_BROWSER_REAL`** to point at the real binary OR symlink/copy it. **Confirmed: `/home/dustin/.local/bin/agent-browser` EXISTS.**

5. **`$POOL_CHROME_BIN` must exist** (default: `google-chrome-stable` in PATH).

6. **Chrome must boot within 30s** (`pool_wait_cdp`, 60 × 0.5s budget).

**The wrapper flow for a driving command (e.g., `open`)**:
`pool_config_init` → `pool_state_init` → `pool_dispatch_classify` ("open" = driving) → `pool_owner_resolve` (TEST MODE: reads `AGENT_BROWSER_POOL_OWNER_PID`) → `pool_lease_find_mine` (no existing lease → acquire) → `pool_acquire_locked` (flock → provisional lease) → `pool_boot_lane` (copy+port+launch+connect) → `pool_ensure_connected` → `exec "$POOL_REAL_BIN" ...`.

**The exec replaces the wrapper** — so the subshell's exit code = the real agent-browser's exit code. The `open` command may NOT exit (it opens a browser window), which is a problem for testing (see Question E).

---

### B. Does pool_acquire_locked's flock guarantee DISTINCT lane numbers for N parallel subshells?

**YES — GUARANTEED.** Trace of the critical section:

1. `pool_acquire_locked` (line 2043): `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` — `flock 9` acquires an EXCLUSIVE lock (default). Only ONE subshell holds the lock at a time; others BLOCK.

2. Inside `_pool_acquire_critical_section` (line ~1960):
   - REAP-STALE: for each lane, `pool_lane_is_stale` — since all N owners are LIVE (real `pi`-comm processes), their lanes are NOT stale. (No reaping happens.)
   - CHOOSE-N: `pool_find_free_lane` walks N=1,2,3,... — first N where `[[ ! -d "$POOL_EPHEMERAL_ROOT/$N" && ! -f "$POOL_LANES_DIR/$N.json" ]]`.
   - CLAIM: `pool_lease_write N ... "false"` — writes `$POOL_LANES_DIR/$N.json` (provisional lease with this owner's PID).
   - echo N; return 0.

3. The subshell exits → `flock` released (kernel closes fd 9).

4. Next acquirer enters: `pool_find_free_lane` sees `$N.json` present → skips N → gets N+1.

Because each owner has a UNIQUE `owner.pid` (different sim-owner PIDs), `pool_lease_find_mine` (line 1010) matches only the owner's OWN lane — it will not reuse another agent's lane.

**The guarantee holds even with N=many**: lane numbers are unbounded (`pool_find_free_lane` walks forever), so the Nth acquirer gets lane N (or a higher number if reaping freed lower-numbered lanes).

---

### C. How to assert "no two share a lane" / "no two share a port" / "each has its own Chrome"

After all N acquire (all booted), read the lease fields for each lane:

```bash
# Assert N distinct lanes exist (pool_lanes_list returns rc 0 always — safe)
local -a lanes
mapfile -t lanes < <(pool_lanes_list)
assert_eq "$N" "${#lanes[@]}" "lane count"

# Assert each lane has unique owner.pid, unique port (>0), unique chrome_pid (>0)
local -A seen_pids=() seen_ports=() seen_chromes=()
local n pid port chrome_pid
for n in "${lanes[@]}"; do
    # pool_lease_field returns 1 on missing — MUST guard with || true INSIDE $()
    pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
    port="$(pool_lease_field "$n" port 2>/dev/null || true)"
    chrome_pid="$(pool_lease_field "$n" chrome_pid 2>/dev/null || true)"

    assert_eq "0" "${seen_pids[$pid]:-0}" "owner.pid $pid unique"   # not seen before
    seen_pids[$pid]=1

    assert_eq "0" "${seen_ports[$port]:-0}" "port $port unique"
    seen_ports[$port]=1

    # chrome_pid must be > 0 (booted) and unique
    assert_eq "0" "${seen_chromes[$chrome_pid]:-0}" "chrome_pid $chrome_pid unique"
    seen_chromes[$chrome_pid]=1
done
```

**set -e hazards**:
- `pool_lease_field` returns 1 on missing/corrupt → bare capture ABORTS. Use `|| true` inside `$()`.
- `pool_lanes_list` returns 0 always → bare `mapfile` is safe.
- `assert_eq` returns 1 on failure → must run inside the `( set -e; ... )` subshell (run_test handles this).

---

### D. How to release all and assert cleanup

**Option 1: `agent-browser-pool release all` (subprocess, safest)**
```bash
"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
```
- Snapshots `pool_lanes_list`, calls `pool_release_lane` for each. Idempotent, rc 0 always.
- Run as a SUBPROCESS so a `pool_die` inside the admin tool cannot kill the harness.

**Option 2: Call `pool_release_lane` directly for each lane (in-process, faster)**
```bash
for n in $(pool_lanes_list); do
    pool_release_lane "$n" >/dev/null   # rc 0 always — safe bare call
done
```
- `pool_release_lane` never `pool_die`s in its body → safe in-process.

**Assertions after release**:
```bash
# No lanes remain
local -a lanes_after
mapfile -t lanes_after < <(pool_lanes_list)
assert_eq "0" "${#lanes_after[@]}" "all lanes released"

# No Chrome under the pool's ephemeral root
assert_no_chrome "$POOL_EPHEMERAL_ROOT"

# Each lane's dir + lease gone
for n in 1 2 3 ... N; do
    assert_lane_gone "$n"
done

# No ephemeral dirs at all
assert_no_dir "$POOL_EPHEMERAL_ROOT"   # or check it's empty / doesn't exist
```

---

### E. Timing/Race Concerns and Safe `wait`

**Chrome boot takes ~seconds** (pool_wait_cdp: 60 × 0.5s = 30s budget). Each wrapper's flow:
1. Acquire (fast, flock-serialized, ~ms inside the lock)
2. Boot (SLOW: copy + launch + CDP wait, ~seconds, OUTSIDE the flock — concurrent across N agents)
3. `pool_ensure_connected`
4. `exec "$POOL_REAL_BIN" ...` — **REPLACES the wrapper process**

**The exec problem**: For a driving command like `open`, the exec'd `agent-browser open` may NOT exit (it opens a browser window and blocks). This means `wait` would hang indefinitely.

**Two approaches:**

**Approach 1 (RECOMMENDED): Call the lib functions directly, bypassing the wrapper's exec.** Instead of running `bin/agent-browser open` (which exec's into agent-browser and may hang), the test body calls the acquire/boot functions directly:
```bash
# In each subshell, with a unique AGENT_BROWSER_POOL_OWNER_PID:
pool_owner_resolve                    # TEST MODE: reads the override PID
local N
if ! N="$(pool_acquire_locked)"; then
    _fail "acquire failed"; return 1
fi
local port
port="$(pool_lease_field "$N" port)" || port=""
if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
    pool_boot_lane "$N" || { _fail "boot failed for lane $N"; return 1; }
fi
# Lane is acquired + booted. Do NOT exec the real agent-browser.
# Record the lane number for the parent to assert on.
echo "$N" > "$ABPOOL_TEST_ROOT/lane-$owner_index"
```
This avoids the exec entirely. The subshell exits after boot → `wait` returns.

**Approach 2: Use the wrapper with a command that exits quickly.** E.g., `agent-browser screenshot` or `agent-browser get title` — these might fail quickly without a page. But this is FRAGILE (depends on agent-browser behavior with no page open). NOT recommended.

**Safe `wait` pattern:**
```bash
declare -a pids=()
for i in $(seq 1 $N); do
    (
        # subshell: set unique owner PID, acquire, boot
        ...
    ) &
    pids+=($!)
done

# wait for ALL background subshells
local fail=0
for pid in "${pids[@]}"; do
    wait "$pid" || fail=1
done
```
Each subshell's exit code = its last command's exit code (NOT exec'd away). `wait "$pid"` blocks until that specific subshell exits, capturing its exit code.

---

### F. setup() spawns ONE sim owner — how to create N for a concurrency test?

**The conflict**: `setup()` exports ONE `AGENT_BROWSER_POOL_OWNER_PID` (line: `export AGENT_BROWSER_POOL_OWNER_PID="$pid"`). The concurrency test needs N distinct ones.

**The solution**: Call `spawn_sim_owner` N times in the test body, then run each acquire in a subshell that OVERRIDES the env var:

```bash
test_concurrent_agents_get_distinct_lanes() {
    local N=3 i pid st
    local -a owner_pids=() owner_starttimes=()

    # Spawn N distinct sim owners (each a unique "pi"-comm process)
    for (( i = 0; i < N; i++ )); do
        pid="$(spawn_sim_owner)"
        st="$(_pool_get_starttime "$pid")"
        owner_pids+=("$pid")
        owner_starttimes+=("$st")
    done

    # Run N parallel acquires, each with a DIFFERENT owner PID
    declare -a bg_pids=()
    for (( i = 0; i < N; i++ )); do
        (
            # Override the owner PID for THIS subshell only
            export AGENT_BROWSER_POOL_OWNER_PID="${owner_pids[$i]}"
            export AGENT_BROWSER_POOL_OWNER_STARTTIME="${owner_starttimes[$i]}"

            pool_owner_resolve
            local N_lane
            if ! N_lane="$(pool_acquire_locked)"; then
                exit 1
            fi
            # Boot if provisional
            local port
            port="$(pool_lease_field "$N_lane" port)" || port=""
            if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
                pool_boot_lane "$N_lane" || exit 1
            fi
            # Record the lane number for assertions
            echo "$N_lane" > "$ABPOOL_TEST_ROOT/lane-$i"
        ) &
        bg_pids+=($!)
    done

    # Wait for all
    for pid in "${bg_pids[@]}"; do
        wait "$pid" || { _fail "parallel acquire $pid failed"; return 1; }
    done

    # Assertions (see Question C)
    ...

    # Cleanup: kill the extra sim owners (setup's one is killed by teardown)
    for (( i = 0; i < N; i++ )); do
        kill "${owner_pids[$i]}" 2>/dev/null || true
    done
    # Release all lanes
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    # Assert cleanup
    ...
}
```

**Key points**:
- `spawn_sim_owner` can be called N times — each returns a unique PID. Each appends to `ABPOOL_SIM_BINS` (trap cleanup removes all bin dirs).
- The subshell's `export` overrides the env var for THAT subshell only (does not affect the parent or other subshells).
- The extra sim owners are NOT tracked by `ABPOOL_CUR_OWNER` (only setup's one is). The test body MUST kill them explicitly (or they persist until their 600s sleep expires).
- `teardown()` kills `ABPOOL_CUR_OWNER` (setup's one) + runs `release all`. The extra owners survive teardown unless killed in the body.

---

### G. set -e Hazards Specific to This Test

| Hazard | What happens | Fix |
|---|---|---|
| **`pool_lease_field` rc 1** | Returns 1 on missing/corrupt lease. Bare call ABORTS under `set -e`. | `\|\| true` inside `$()` or `if` guard. |
| **`pool_lanes_list`** | Returns 0 ALWAYS. | Safe for bare iteration: `for n in $(pool_lanes_list)`. |
| **`pool_lane_is_stale` TRI-STATE** | rc 1 (live) / rc 2 (no lease) ABORT bare. | `if pool_lane_is_stale "$n"; then ...; fi`. |
| **`pool_acquire_locked` rc 1** | Returns 1 on exhaustion. Bare capture ABORTS. | `if N="$(pool_acquire_locked)"; then`. |
| **`pool_boot_lane` rc 1** | Returns 1 on recoverable failure (lane cleaned up). Bare call ABORTS. | `pool_boot_lane "$N" \|\| <handle>`. |
| **`pool_ensure_connected` rc 1** | Returns 1 when lane unusable. Bare call ABORTS. | `pool_ensure_connected "$N" \|\| <handle>`. |
| **`pool_lease_exists` rc 1** | Returns 1 on missing/corrupt. Bare call ABORTS. | `if pool_lease_exists "$n"; then`. |
| **`pool_lease_read` rc 1** | Returns 1 on missing/corrupt. Bare capture ABORTS. | `if ! json="$(pool_lease_read "$n" 2>/dev/null)"; then`. |
| **Bare `(( expr ))`** | Returns rc 1 when result is 0 → ABORTS under `set -e`. | Use `$(( ))` expansion OR put `(( ))` inside `if`/`&&`/`\|\|`. |
| **`(( var++ ))`** | Returns OLD value → 0 when var was 0 → ABORTS. | Use `var=$((var+1))`. |
| **`local x="$(cmd)"`** | SC2155: `local` returns 0, masking `cmd`'s failure. | Split: `local x; x="$(cmd)"`. |
| **Parallel subshell exit codes** | `wait "$pid"` captures each subshell's exit. | `wait "$pid" \|\| fail=1` — the `\|\|` is errexit-exempt. |
| **`pgrep` rc 1** | No-match returns rc 1 → ABORTS bare. | Use as `if` condition (assert_no_chrome does this). |
| **`kill` rc 1** | ESRCH (dead target) returns rc 1 → ABORTS bare. | Always `kill ... 2>/dev/null \|\| true`. |
| **`pool_release_lane`** | Returns rc 0 ALWAYS. | Safe for bare call. |
| **`pool_admin_release "all"` as subprocess** | rc 0 always (all released) or rc 1 (empty pool prints "No active lanes"). | `\|\| true` (the test wants to continue regardless). |

---

## Residual Notes for the Test Author

1. **The test's `setup()` creates an EMPTY master dir** (`mkdir -p "$AGENT_CHROME_MASTER"`). For a REAL Chrome acquire, either:
   - Point `AGENT_CHROME_MASTER` at the real master: `export AGENT_CHROME_MASTER="$HOME_REAL/.agent-chrome-profiles/master-profile"` — but this BREAKS hermetic isolation.
   - Copy the real master into the temp dir in the test body BEFORE acquire.
   - OR the test can test acquire WITHOUT real Chrome (test the lane allocation + lease logic only, skip boot). This avoids needing a master/btrfs/Chrome entirely.

2. **For a pure lane-allocation concurrency test (no real Chrome boot)**: The test can call `pool_owner_resolve` + `pool_acquire_locked` in N subshells, then assert distinct lane numbers + distinct owner.pids. This does NOT require master/btrfs/Chrome. The provisional lease has `port=0`, `chrome_pid=0`, `connected=false` — the assertions for "distinct port" and "distinct chrome_pid" would need to check that they're all distinct 0s (which is trivially true but meaningless). For a MEANINGFUL concurrency test, either boot real Chrome (needs preconditions) or write the provisional leases manually.

3. **Cannot verify FS type from file reads.** The test author should run `stat -f -c %T .` to determine if the host FS is btrfs. If not, set `AGENT_CHROME_ALLOW_SLOW_COPY=1` or skip the real Chrome boot.

4. **`/home/dustin/.local/bin/agent-browser` EXISTS** (confirmed ELF binary). The test should override `AGENT_BROWSER_REAL` to this path (or the default `$HOME/.local/bin/agent-browser` if the test's temp `HOME` has it symlinked). Actually — `setup()` overrides `HOME` to a temp dir, so `$POOL_HOME_DIR/.local/bin/agent-browser` resolves to the temp HOME, which does NOT have it. The test MUST `export AGENT_BROWSER_REAL="/home/dustin/.local/bin/agent-browser"` (or wherever the real binary is) BEFORE `pool_config_init` runs.
