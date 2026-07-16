# Recon: `pool_ensure_connected` (Issue #3) — connect/relaunch identity plumbing

All line numbers are in `lib/pool.sh` unless noted. Static read only — no processes run.

## 1. `pool_ensure_connected()` — `lib/pool.sh:2508-2625`

Signature: `pool_ensure_connected LANE` (single arg).

### jq extraction (lib/pool.sh:2534-2538) — ONLY 4 fields
```bash
    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")
    session="${_f[0]:-}"
    port="${_f[1]:-}"
    ephemeral_dir="${_f[2]:-}"
    connected="${_f[3]:-true}"
```
NOTE: `chrome_pid` is NOT extracted. It would need to be added as a 5th field for the
reconnect-branch identity check.

### (b) Early-exit branch — `lib/pool.sh:2555-2558`
```bash
    if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then
        pool_lease_update "$lane" last_seen_at "$now"
        return 0
    fi
```

### (c) RECONNECT branch — `lib/pool.sh:2561-2572` (chrome alive → rebind daemon)
```bash
    if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
        if pool_daemon_connect "$session" "$port"; then
            pool_lease_update "$lane" connected true
            pool_lease_update "$lane" last_seen_at "$now"
            _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
            return 0
        fi
        _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi
```
BUG: after curl succeeds, pool_daemon_connect rebinds WITHOUT verifying the answerer is
this lane's Chrome. A foreign Chrome answering on $port → silent isolation break.

### (c) RELAUNCH branch — `lib/pool.sh:2574-2625` (chrome dead → fresh chrome, same dir+port)
```bash
    # Singleton cleanup
    rm -f -- "$ephemeral_dir/SingletonLock" "$ephemeral_dir/SingletonCookie" "$ephemeral_dir/SingletonSocket" \
        2>/dev/null || true

    # Launch NEW chrome on same port + dir
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"

    # Early chrome-id write
    pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}"
    pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"

    # *** SINGLE-ARG CALL: identity check DISABLED ***
    if ! pool_wait_cdp "$port"; then
        _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi

    # re-bind daemon
    if ! pool_daemon_connect "$session" "$port"; then
        … return 1
    fi

    pool_lease_update "$lane" connected true
    pool_lease_update "$lane" last_seen_at "$now"
    return 0
```
ASYMMETRY: `pool_wait_cdp "$port"` at line 2597 uses a SINGLE argument → `check_identity=0`
inside pool_wait_cdp → BUG-1 identity check is DISABLED. The vars needed to enable identity
(`$ephemeral_dir` and `${POOL_CHROME_PID:-}`) are already in scope.

## 2. `pool_cdp_is_ours()` — `lib/pool.sh:1629-1652`

Signature: `pool_cdp_is_ours PORT USER_DATA_DIR EXPECTED_PID`. All three required (caller
guards). Returns 0 = provably ours; 1 = cannot prove / not ours (NON-FATAL, never pool_die).

Two-signal check:
```bash
pool_cdp_is_ours() {
    local port="${1:-}"
    local user_data_dir="${2:-}"
    local expected_pid="${3:-}"
    local dtap first_line

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$user_data_dir" && "$user_data_dir" == /* ]] || return 1
    [[ "$expected_pid" =~ ^[0-9]+$ ]] || return 1

    # Signal 1 — DevToolsActivePort first line must equal PORT
    dtap="$user_data_dir/DevToolsActivePort"
    first_line="$(head -n1 -- "$dtap" 2>/dev/null | tr -d '[:space:]')" || true
    [[ "$first_line" == "$port" ]] || return 1

    # Signal 2 — our launched Chrome must STILL be alive (/proc existence, NOT kill -0)
    [[ -d "/proc/$expected_pid" ]] || return 1

    return 0
}
```

## 3. `pool_wait_cdp()` — `lib/pool.sh:1697-1741`

Signature: `pool_wait_cdp PORT [USER_DATA_DIR [EXPECTED_PID]]`.

`check_identity` logic — `lib/pool.sh:1707-1712`:
```bash
    local check_identity=0
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # Enable the BUG-1 identity check only when BOTH args are supplied & well-formed.
    if [[ -n "$user_data_dir" && "$user_data_dir" == /* && "$expected_pid" =~ ^[0-9]+$ ]]; then
        check_identity=1
    fi
```

Probe loop — `lib/pool.sh:1714-1731`:
```bash
    for (( i = 0; i < POOL_CDP_TRIES; i++ )); do   # 60 ×0.5s = 30s budget
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            if [[ "$check_identity" -eq 1 ]]; then
                if pool_cdp_is_ours "$port" "$user_data_dir" "$expected_pid"; then
                    return 0
                fi
                # Not (yet) ours — loop and retry within the budget.
            else
                return 0      # legacy probe-only behavior
            fi
        fi
        sleep 0.5
    done
```

Timeout/kill tail — `lib/pool.sh:1733-1741`:
```bash
    if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then
        kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true
    fi
    return 1
```

The docstring (~lib/pool.sh:1687-1689) states the optional-args-omitted path is deliberately
preserved "for standalone tests + the ensure_connected relaunch path, which already knows its
Chrome is bound." After the Issue #3 fix, this statement becomes FALSE and must be updated.

## 4. `_pool_launch_and_verify()` — the hardened reference — `lib/pool.sh:2282-2351`

ALL `pool_wait_cdp` call sites here pass **3 args** (identity ENABLED):
```bash
    # Attempt 1 (2297-2302)
    if pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then   # 3 args
        return 0
    fi
    # Attempt 2 (2319-2324)
    if pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then   # 3 args
        return 0
    fi
    # Port re-pick (2346-2348)
    if pool_wait_cdp "$new_port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then # 3 args
        return 0
    fi
```

Reference pattern to replicate in `pool_ensure_connected`'s relaunch branch.

## 5. `ensure_connected` / connected-state self-tests — `test/validate.sh`

### `selftest_ensure_connected_rebinds_when_disconnected` — `test/validate.sh:560-588`
```bash
# Lease: lane 1, connected=false, chrome_pid=200 (dead)
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 false
# Stubs
pool_daemon_connected() { return 0; }   # false positive
curl()                  { return 0; }   # chrome "alive" → RECONNECT branch
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
pool_ensure_connected 1
test "$_connect_called" = "1"                    # rebind CALLED
test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"
```
**CRITICAL**: This test WILL BREAK with the reconnect-branch identity fix. It stubs curl→0
(chrome "alive" → reconnect branch) but has NO DevToolsActivePort file and chrome_pid=200
(dead). After the fix, pool_cdp_is_ours returns 1 → falls through to relaunch → _connect_called
stays 0 → test FAILS. MUST be updated: stub pool_cdp_is_ours()→0, or create a DevToolsActivePort
file + use pid 1.

### `selftest_ensure_connected_skips_rebind_when_connected` — `test/validate.sh:593-615`
Happy-path: connected=true + pool_daemon_connected→0 → early-exit. curl never reached.
**Unaffected by the fix.**

## Architecture / data flow

```
pool_wrapper_main (every driving cmd)
        │
        ▼
pool_ensure_connected LANE                  [pool.sh:2508]
  ├─ read lease → {session, port, ephemeral_dir, connected}   (ONE jq fork)
  ├─ (b) connected==true && pool_daemon_connected ?  → heartbeat, return 0   [2555]
  ├─ (c) curl /json/version ALIVE ?
  │      └─ pool_daemon_connect → connected=true, return 0   (RECONNECT)     [2561-2572]
  └─ (c) else DEAD → RELAUNCH                                                   [2574-2625]
         ├─ rm -f Singleton*                                                    [2578]
         ├─ pool_chrome_launch (sets POOL_CHROME_PID/PGID)                       [2584]
         ├─ write chrome_pid/pgid → lease                                       [2593-2594]
         ├─ pool_wait_cdp "$port"   ← SINGLE ARG (identity OFF) ← ASYMMETRY     [2597]
         └─ pool_daemon_connect → connected=true, return 0                      [2607]

pool_wait_cdp PORT [UDD [PID]]                [pool.sh:1697]
  └─ check_identity = (UDD abs-path AND PID numeric) ? 1 : 0                    [1707-1712]
      └─ on curl success: if check_identity → pool_cdp_is_ours ? return 0 : keep polling
                         else                → return 0 (legacy)
      └─ timeout → kill -- -POOL_CHROME_PGID, return 1

pool_cdp_is_ours PORT UDD PID                [pool.sh:1629]
  ├─ UDD/DevToolsActivePort line1 == PORT ?
  └─ /proc/PID exists ?
```

## Start here

- `lib/pool.sh:2597` — the relaunch branch's `if ! pool_wait_cdp "$port"; then` → change to 3 args.
- `lib/pool.sh:2561-2572` — the reconnect branch → add pool_cdp_is_ours gate after curl.
- `lib/pool.sh:2534` — the jq extraction → add `.chrome_pid` as 5th field.
- `test/validate.sh:560-588` — the test that WILL BREAK → must be updated.
