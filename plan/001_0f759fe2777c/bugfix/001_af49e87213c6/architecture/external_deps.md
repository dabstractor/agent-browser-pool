# External Dependencies & Interface Contracts — Bugfix 001

## Date: 2026-07-12

---

## 1. agent-browser CLI (the wrapped binary)

**Location:** `/home/dustin/.local/bin/agent-browser` (symlink → node_modules binary)
**Version:** 0.28.0
**Type:** Rust binary (not shell script — cannot source/modify)
**Override path:** `$AGENT_BROWSER_REAL`

### Relevant behaviors for bugfixes

| Behavior | Relevance | Notes |
|----------|-----------|-------|
| `--session <name> --json session list` | Issue 3 | Read-only; lists sessions. Session LINGERS after `close`. |
| `--session <name> connect <port>` | Issue 3 | Binds daemon to Chrome CDP on port. Used by `pool_daemon_connect`. |
| `--session <name> close` | Issue 3 | Disconnects daemon session ONLY. Chrome stays alive. Session lingers in list. |
| `--session <name> get cdp-url` | Issue 3 | FORBIDDEN in pool code (per M4.T3.S1 §2). Replaced by `pool_daemon_connected`. |
| Driving commands (`open`, `click`, ...) | Issue 3 | Whether they auto-rebind a closed session is UNVERIFIED (PRD §2.5 `[OPEN — confirm]`). |

### Close semantics (PRD §2.5)
`agent-browser close` = disconnect-only. The daemon detaches but the lane, Chrome, and
ephemeral dir stay alive. The session name LINGERS in the daemon's session list after
close. This is the root cause of Issue 3: `pool_daemon_connected` cannot distinguish
"bound" from "lingering-after-close."

---

## 2. Chrome binary

**Location:** `/usr/bin/google-chrome-stable`
**Override:** `$AGENT_CHROME_BIN`

### Relevant behaviors for bugfixes

| Behavior | Relevance | Notes |
|----------|-----------|-------|
| `--remote-debugging-port=<port>` | Issue 2 | If port is in use, Chrome may exit instantly or fail to expose CDP. |
| Instant-exit on EADDRINUSE | Issue 2 | Chrome writes an error to stderr (captured in `chrome-<N>.log`). The log contains messages like "Address already in use" or "Cannot start http server for devtools". |
| CDP endpoint (`/json/version`) | Issues 2, 3 | `curl -sf http://127.0.0.1:<port>/json/version` — HTTP 200 = alive. Used by `pool_wait_cdp` and `pool_daemon_connected`. |
| `--headless=new` flag | Issue 1 | Added to Chrome flags iff `POOL_HEADLESS == "1"` (line 1515). |
| `setsid` process group | Issue 2 | Chrome launched with `setsid` → pgid == pid. Teardown: `kill -- -<pgid>`. |

### Chrome log format (for EADDRINUSE detection — Issue 2)
Chrome's stderr (captured to `$POOL_STATE_DIR/chrome-<N>.log`) typically contains:
- `[ERROR:devtools_http_handler.cc(...)] Cannot start http server for devtools on port <PORT>. Address already in use.`
- or `ERROR: ... Couldn't bind to port <PORT>`

The fix should `grep -qiE` the log for patterns like:
`address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn't bind`

---

## 3. Configuration Variables (boolean env vars — Issue 1)

| Variable | Default | Global | Consumer Lines |
|----------|---------|--------|----------------|
| `AGENT_CHROME_HEADLESS` | unset (windowed) | `POOL_HEADLESS` | 1515 (`pool_chrome_launch`) |
| `AGENT_BROWSER_POOL_DISABLE` | unset (active) | `POOL_DISABLE` | 3491 (`pool_wrapper_main`) |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset (refuse) | `POOL_ALLOW_SLOW_COPY` | 242 (`pool_check_btrfs`), 1295 (`pool_copy_master`), 4222 (`pool_admin_doctor`) |

All three pass through `_pool_config_bool` (`lib/pool.sh:82-84`) which only accepts `"1"`.

---

## 4. Lease JSON `connected` field (Issue 3)

The `connected` field in the lease JSON is a JSON boolean (`true`/`false`), NOT the
number 1. It is validated by `pool_lease_write` (line 700: `[[ "$connected" == "true" || "$connected" == "false" ]]`).

### Current write sites
| Line | Location | Value | Context |
|------|----------|-------|---------|
| 2251 | `pool_boot_lane` step f | `true` | Initial provisioning success |
| 2348 | `pool_ensure_connected` reconnect | `true` | Daemon re-bound (chrome alive) |
| 2383 | `pool_ensure_connected` relaunch CDP timeout | `false` | Relaunched chrome CDP timed out |
| 2393 | `pool_ensure_connected` relaunch connect fail | `false` | Relaunched chrome won't bind |
| 2399 | `pool_ensure_connected` relaunch success | `true` | Relaunch + re-bind succeeded |

### Current read sites
- `pool_acquire_locked` (line ~2007): checks `connected` to distinguish provisional
  (port:0/connected:false) from adopted (port>0/connected:true) lanes.
- `pool_ensure_connected`: does NOT read `connected` — only reads session, port, ephemeral_dir.
  This is the gap for Issue 3.

### `pool_lease_update` API
```bash
pool_lease_update LANE FIELD VALUE
# VALUE must be valid JSON: number, true/false, or a quoted string.
# Example: pool_lease_update "$N" connected false
# Example: pool_lease_update "$N" port 53425
```
Uses `jq --argjson v "$value" --arg f "$field" '.[$f] = $v'` to splice one field.
Atomic re-publish via `_pool_atomic_write` (temp file + `mv`).

---

## 5. Test Framework (validate.sh)

### Assertion helpers
```bash
assert_eq EXPECTED ACTUAL "message"     # fail if EXPECTED != ACTUAL
assert_lane_exists N                    # fail if lease for lane N missing
assert_lane_gone N                      # fail if lease for lane N present
assert_no_chrome PGID                   # fail if Chrome process group alive
assert_no_dir PATH                      # fail if directory exists
_fail "message"                         # record failure, return 1
```

### Owner simulation
```bash
# Test-only env vars (not for users):
AGENT_BROWSER_POOL_OWNER_PID=<pid>        # simulate a specific owner PID
AGENT_BROWSER_POOL_OWNER_STARTTIME=<val>  # simulate starttime
```

### Runner pattern
```bash
# Source the framework:
source test/validate.sh

# Define test functions:
test_my_feature() {
    setup  # creates temp root, config, trap
    # ... test body ...
    teardown  # cleans up
}

# Run:
abpool_run_suite test_
```

**CRITICAL (AGENTS.md §4):** `setup()` spawns a process. The 3rd `setup()` call HANGS
in a shared sandbox. Use the single-setup runner pattern (see `release_reaper.sh`'s
`_abpool_run_release_reaper_suite`). NEVER call `setup()` per-test in a shared sandbox.

---

## 6. Port allocation (Issue 2)

### `pool_find_free_port` logic
1. Build claimed-port set from all leases (ports > 0).
2. Snapshot listening sockets via `ss -tlnH` (once).
3. Iterate [POOL_PORT_BASE, POOL_PORT_BASE + POOL_PORT_RANGE):
   - Skip if claimed by a lease.
   - Skip if `ss` shows a listener.
   - Skip if `curl /json/version` responds (non-pool Chrome).
   - First port that passes all three → return it.
4. If none found → return 1 (NON-FATAL).

### Anti-collision mechanism
`pool_boot_lane` writes the chosen port to the lease BEFORE launching Chrome (line 2227).
Later `pool_find_free_port` callers see it claimed. TOCTOU window: between
`pool_find_free_port` returning and `pool_lease_update port` executing.

### Retry behavior (current — broken for collisions)
`_pool_launch_and_verify` retries on CDP timeout with the SAME port (designed for
"Chrome slow to boot," NOT for collision recovery). Does NOT re-pick a port.
