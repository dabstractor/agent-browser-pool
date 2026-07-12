# Key Findings, Gotchas & Architectural Recommendations

## Date: 2026-07-12

---

## CRITICAL FINDING 1: `/proc/<pid>/stat` starttime Parsing

### The Bug in the PRD
The PRD (§2.19) states:
> Read starttime from the right (it's field 22 from the start → index NF-19 after awk split on space)

**This is WRONG.** Tested empirically:
- `/proc/$$/stat` has 52 fields total (for `comm=bash`)
- `awk '{print $(NF-19)}'` → field 33 (= 52-19), which is NOT starttime
- `awk '{print $22}'` → correct: field 22 = starttime ✓

### Root Cause
The NF-19 formula assumes the total field count is fixed at 41, but it's not — it
varies by process state and trailing fields. The actual NF on this host is 52.

### Correct Approach (Verified)
Since the owner process `pi` has a simple single-word comm (`pi`), `awk '{print $22}'`
or `cut -d' ' -f22` works. For maximum robustness against comm with spaces:

```bash
# Strip everything up to and including the last ')', then field 20 (= 22-2)
sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'
```

**Implementation must use the robust sed-based method or document the direct field 22
approach with a note about comm restrictions.**

---

## CRITICAL FINDING 2: flock Critical Section Must Be SHORT

The PRD correctly notes this in §2.19 but it's worth emphasizing:

```bash
# WRONG: Chrome launch inside flock → serializes all concurrent acquires
(
  flock 9
  scan_lanes
  reap_stale
  choose_lane
  launch_chrome    # ← 5-10 second Chrome boot BLOCKS other agents
  connect
  update_lease
) 9>"$LOCK"

# RIGHT: Claim under flock, boot Chrome AFTER releasing flock
(
  flock 9
  scan_lanes
  reap_stale
  choose_lane
  write_provisional_lease    # port=0, connected=false
) 9>"$LOCK"
# Lock released — other agents can claim their lanes now
launch_chrome                # concurrent with other agents' Chrome boots
connect
update_lease_connected       # port, chrome_pid, connected=true
```

---

## CRITICAL FINDING 3: No Bare `~` (§2.2)

Tilde expansion does NOT occur:
- After `=` in assignments: `DIR=~/.foo` → literally `~/.foo` (works in bash, but...)
- Inside quotes: `DIR="~/foo"` → literally `~/foo` (BROKEN)
- As arguments to subprocesses: `rm -rf ~/.foo` → may create a dir named `~`

**Rule:** Resolve ALL paths to absolute form at startup using `$HOME` and `realpath`.
Never emit `~` to Chrome, `rm`, log paths, or any subprocess.

```bash
HOME_DIR="$(realpath "$HOME")"
STATE_DIR="${AGENT_BROWSER_POOL_STATE:-$HOME_DIR/.local/state/agent-browser-pool}"
MASTER_DIR="${AGENT_CHROME_MASTER:-$HOME_DIR/.agent-chrome-profiles/master-profile}"
EPHEMERAL_ROOT="${AGENT_CHROME_EPHEMERAL_ROOT:-$HOME_DIR/.agent-chrome-profiles/active}"
REAL_BIN="${AGENT_BROWSER_REAL:-$HOME_DIR/.local/bin/agent-browser}"
```

---

## FINDING 4: agent-browser Daemon Is Already Running

On this host, `agent-browser-linux-x64` (PID 590833) is already running as a daemon
with many sessions (t7, curaihealthlane, weaveapply, etc.). These are from the
**existing manual workflow** using persistent profiles `1..10`.

**During testing:** The wrapper must not interfere with these existing sessions.
The pool uses its own session namespace `abpool-<N>`, which won't collide with
existing session names.

**During cutover:** Once installed, the wrapper will intercept new `agent-browser`
calls. Existing running agents will be intercepted on their next call. The
`AGENT_BROWSER_POOL_DISABLE=1` env allows a per-session opt-out during transition.

---

## FINDING 5: Leftover Temp Chrome Dirs

`/tmp/agent-browser-chrome-*` dirs accumulate from agent-browser's default Chrome
management (it uses temp dirs that aren't always cleaned up). This is exactly the
problem the pool solves — ephemeral dirs in `active/` are explicitly deleted on release.

The pool should NOT try to clean up these `/tmp/` dirs (that's agent-browser's
responsibility). The pool only manages `active/<N>/` dirs.

---

## FINDING 6: Chrome Process Group Teardown

Chrome launched with `setsid` becomes its own session leader → pgid == pid.

```bash
# Launch
setsid google-chrome-stable ... &
CHROME_PID=$!
CHROME_PGID=$(ps -o pgid= -p $CHROME_PID | tr -d ' ')
# pgid should equal CHROME_PID since setsid made it group leader

# Teardown
kill -- -"$CHROME_PGID"   # negative PID = signal the process group
# -- is required to prevent -<pgid> being interpreted as a flag
```

**Fallback if pgid lookup fails:** `pkill -P "$CHROME_PID"` then `kill "$CHROME_PID"`.
But `kill -- -<pgid>` is the primary mechanism and catches all children (renderers, GPU, etc.).

---

## FINDING 7: Lease Atomic Write Pattern

```bash
write_lease() {
  local lane=$1 lease_file="$STATE_DIR/lanes/$lane.json"
  local tmp_file="$lease_file.tmp"
  
  # Write to temp file
  jq -n \
    --argjson lane "$lane" \
    --arg ephemeral_dir "$EPHEMERAL_DIR" \
    ... \
    > "$tmp_file"
  
  # Atomic rename (same filesystem required)
  mv "$tmp_file" "$lease_file"
}
```

`mv` (rename) is atomic on the same filesystem. Since all lease files are in
`$STATE_DIR/lanes/`, the temp file and final file are on the same FS.

---

## FINDING 8: Test Hook Overrides

The PRD (§2.18) specifies testability overrides:
```bash
AGENT_BROWSER_POOL_OWNER_PID=<pid>        # simulate a specific owner PID
AGENT_BROWSER_POOL_OWNER_STARTTIME=<val>  # simulate starttime
```

When set, the wrapper skips the ppid walk and uses these values directly. This allows
the test harness to simulate distinct "agents" from distinct subshell PIDs without
needing actual `pi` ancestor processes.

**Implementation:** These should be narrowly-scoped — checked at the very start of
owner resolution, used only if set, and not exposed in any user-facing docs (they're
test-only hooks).

---

## ARCHITECTURAL RECOMMENDATION: Single Shared Library

All shared logic lives in `lib/pool.sh`. Both `bin/agent-browser` and
`bin/agent-browser-pool` source it:

```bash
# bin/agent-browser
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/pool.sh"

# Resolve real bin location (handle symlink)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"

pool_main "$@"
```

**Key:** `readlink -f` resolves symlinks so the library path works regardless of where
the binary is symlinked (~/scripts/ or ~/.local/bin/).

---

## ARCHITECTURAL RECOMMENDATION: Function Naming Convention

```
pool_*           ← public functions (entry points)
_pool_*          ← internal helpers
pool_config_*    ← configuration resolution
pool_owner_*     ← owner resolution
pool_lease_*     ← lease read/write/query
pool_lane_*      ← lane lifecycle (copy, launch, connect, teardown)
pool_reap_*      ← stale lane reaping
pool_acquire_*   ← acquire flow
pool_release_*   ← release flow
pool_dispatch_*  ← wrapper command dispatch
pool_admin_*     ← admin CLI commands
```
