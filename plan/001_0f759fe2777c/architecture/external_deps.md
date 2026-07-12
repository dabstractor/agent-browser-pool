# External Dependencies & Interface Contracts

## Date: 2026-07-12

---

## 1. agent-browser CLI — The Wrapped Binary

**Location:** `/home/dustin/.local/bin/agent-browser` (symlink → node_modules binary)
**Version:** 0.28.0
**Type:** Rust binary (not shell script — cannot source/modify)
**Override path:** `$AGENT_BROWSER_REAL` (default: the absolute path above)

### 1.1 Commands the Wrapper Must Intercept/Route (DRIVING)

These commands operate on a browser and must route to the agent's lane:

```
open, click, dblclick, type, fill, press, keyboard, hover, focus,
check, uncheck, select, drag, upload, download, scroll, scrollintoview,
wait, screenshot, pdf, snapshot, eval, connect, close, session,
back, forward, reload,
get, is, find
```

### 1.2 Commands the Wrapper Must Pass Through (META/passthrough)

These commands don't drive a browser and should exec the real binary unchanged:

```
skills, skills list, skills get <name>, skills path
--help, -h, --version
dashboard, dashboard start, dashboard stop
plugin, plugin <...>
mcp, mcp <...>
session list (read-only, no lane needed)
```

**Note:** `session list` is a gray area — it's informational, not driving.
Passthrough is safe.

### 1.3 Session/Connection Commands (Special Handling)

| Agent Invocation | Wrapper Behavior |
|---|---|
| `agent-browser connect <port>` | **Ignore the arg.** Ensure MY lane is connected to MY Chrome. |
| `agent-browser connect <url>` | Same — ignore arg, ensure my lane connected. |
| `agent-browser --session <X> <cmd>` | **Override** `--session` to `abpool-<N>`. Strip the agent's `--session` flag. |
| `AGENT_BROWSER_SESSION=<X> agent-browser <cmd>` | **Override** env to `abpool-<N>`. |
| `agent-browser close` | Disconnect MY lane's daemon only. |
| `agent-browser close --all` | **Intercept:** disconnect MY lane only. NEVER close --all (would nuke peers). |

### 1.4 Key Subcommands for Pool Plumbing

```bash
# Connect daemon to Chrome on a port
agent-browser --session <name> connect <port>

# Check if daemon is connected (exit 0 = yes)
agent-browser --session <name> get cdp-url

# Close a specific session
agent-browser --session <name> close

# List sessions (informational)
agent-browser session list
```

---

## 2. Chrome Binary

**Location:** `/usr/bin/google-chrome-stable`
**Override:** `$AGENT_CHROME_BIN`

### 2.1 Launch Command (Per Lane)
```bash
setsid "$AGENT_CHROME_BIN" \
  --remote-debugging-port=<port> \
  --user-data-dir="<ABSOLUTE_PATH>" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-features=CalculateNativeWinOcclusion \
  --disable-back-forward-cache \
  > "$CHROME_LOG" 2>&1 &
```

- `setsid` → Chrome becomes its own session/group leader (pgid == pid)
- Teardown: `kill -- -<pgid>` kills the entire process group
- Windowed by default (no `--headless`). Headless via `AGENT_CHROME_HEADLESS=1`.
- Anti-throttle flags are REQUIRED on Wayland (verified — backgrounded windows get throttled)

### 2.2 CDP Readiness Check
```bash
# Wait for Chrome's CDP endpoint to respond
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:<port>/json/version" >/dev/null 2>&1; then
    return 0  # CDP ready
  fi
  sleep 0.5
done
return 1  # CDP boot timeout (30s)
```

### 2.3 Port Selection
- Base: `$AGENT_CHROME_PORT_BASE` (default 53420)
- Range: `$AGENT_CHROME_PORT_RANGE` (default 1000)
- Strategy: lowest free port in [BASE, BASE+RANGE) where:
  1. No `lanes/*.json` claims it
  2. `ss -tln` shows no listener
  3. `curl /json/version` gets no response (not held by a non-pool Chrome)

---

## 3. btrfs / CoW Copy

**Mount:** `/dev/nvme1n1p2[/@home]` at `/home` (btrfs, verified)
**Profile root:** `~/.agent-chrome-profiles/` (on btrfs)

### 3.1 Copy Command
```bash
cp -a --reflink=always "$MASTER_DIR" "$EPHEMERAL_DIR"
```
- Instant (CoW — no blocks copied until write)
- Deduplicated (shared blocks)
- **Fails on non-btrfs** → must catch and refuse unless `$AGENT_CHROME_ALLOW_SLOW_COPY=1`

### 3.2 btrfs Detection
```bash
# Check the filesystem type at the ephemeral root
FSTYPE=$(findmnt -nno FSTYPE "$EPHEMERAL_ROOT" 2>/dev/null)
if [ "$FSTYPE" != "btrfs" ] && [ "$AGENT_CHROME_ALLOW_SLOW_COPY" != "1" ]; then
  echo "ERROR: $EPHEMERAL_ROOT is not btrfs (got: $FSTYPE)" >&2
  exit 1
fi
```

### 3.3 Singleton Lock Cleanup
After CoW copy, remove stale Chrome single-instance locks:
```bash
rm -f "$EPHEMERAL_DIR/SingletonLock" \
      "$EPHEMERAL_DIR/SingletonCookie" \
      "$EPHEMERAL_DIR/SingletonSocket"
```

---

## 4. Linux Process Utilities

| Tool | Path | Usage |
|---|---|---|
| `flock` | `/usr/bin/flock` (util-linux) | Acquire lock for critical section: `flock "$LOCK_FILE" -c '...'` or `( flock 9; ... ) 9>"$LOCK_FILE"` |
| `setsid` | `/usr/bin/setsid` (util-linux) | Launch Chrome in its own process group |
| `pgrep` | `/usr/bin/pgrep` (procps-ng) | Check if a PID is alive, find processes |
| `pkill` | `/usr/bin/pkill` (procps-ng) | Kill by pattern (used by reaper fallback) |
| `curl` | `/usr/bin/curl` | Probe CDP endpoint `/json/version` |
| `jq` | `/usr/bin/jq` | Read/write lease JSON files |
| `notify-send` | `/usr/bin/notify-send` (libnotify) | Desktop alert on pool exhaustion |
| `cp` | `/usr/bin/cp` (coreutils) | CoW copy with `--reflink=always` |
| `kill` | built-in | Process group teardown: `kill -- -<pgid>` |
| `findmnt` | `/usr/bin/findmnt` (util-linux) | Detect btrfs filesystem |

### flock Pattern (Short Critical Section)
```bash
# CRITICAL: Keep flock section short. Only scan + claim.
# Release BEFORE launching Chrome so concurrent acquires boot in parallel.
(
  flock 9
  # ... scan lanes, reap stale, choose N, write lease ...
) 9>"$STATE_DIR/acquire.lock"
# Lock released here — Chrome launch happens AFTER this block
```

---

## 5. Configuration Variables (All Env Vars)

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_BROWSER_REAL` | `/home/dustin/.local/bin/agent-browser` | Real CLI binary path |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary |
| `AGENT_CHROME_MASTER` | `$HOME/.agent-chrome-profiles/master-profile` | Master template |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `$HOME/.agent-chrome-profiles/active` | Ephemeral lanes root |
| `AGENT_BROWSER_POOL_STATE` | `$HOME/.local/state/agent-browser-pool` | Lease store + logs |
| `AGENT_CHROME_PORT_BASE` | `53420` | Lowest pool port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | Port range width |
| `AGENT_BROWSER_POOL_WAIT` | `600` | Exhaustion wait (seconds) |
| `AGENT_CHROME_HEADLESS` | (unset = windowed) | Headless Chrome for tests |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | (unset = refuse non-btrfs) | Allow real 4.8GB copy |
| `AGENT_BROWSER_POOL_DISABLE` | (unset = pooling active) | Per-process passthrough |
| `AGENT_BROWSER_POOL_OWNER_PID` | (unset = auto-resolve) | Test hook: simulate owner PID |
| `AGENT_BROWSER_POOL_OWNER_STARTTIME` | (unset = auto-resolve) | Test hook: simulate starttime |

---

## 6. Lease JSON Schema (v1)

File: `$STATE_DIR/lanes/<N>.json`

```json
{
  "version": 1,
  "lane": 7,
  "ephemeral_dir": "/home/dustin/.agent-chrome-profiles/active/7",
  "port": 53427,
  "session": "abpool-7",
  "owner": {
    "pid": 836725,
    "comm": "pi",
    "starttime": 1234567890,
    "cwd": "/home/dustin/projects/x"
  },
  "chrome_pid": 104816,
  "chrome_pgid": 104816,
  "acquired_at": 1720000000,
  "last_seen_at": 1720000123,
  "connected": true
}
```

**Atomic writes:** Write to `lanes/<N>.json.tmp`, then `mv` (rename is atomic on same FS).

---

## 7. Cutover Constraints

1. **PATH shadow is all-or-nothing.** Once `~/scripts/agent-browser` exists, ALL
   `agent-browser` calls route through the wrapper. There is no partial shadow.
2. **`AGENT_BROWSER_POOL_DISABLE=1`** is the per-process escape valve.
3. **Running agents on the old workflow** will be silently intercepted on install.
   `install.sh` must warn and require confirmation.
4. **Testing before cutover:** invoke wrapper by absolute path
   (`<repo>/bin/agent-browser ...`) — exercises all logic without touching PATH.
