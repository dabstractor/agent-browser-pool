# Key Findings — Bugfix 001

## Date: 2026-07-12
## Method: Static analysis (code reading + bash -n + shellcheck). No Chrome/daemon/test-suite launched.

---

## ISSUE 1: Boolean env vars only honor literal `"1"`

### Root Cause
`_pool_config_bool` (`lib/pool.sh:82-84`) treats ONLY the exact string `"1"` as ON;
every other value (`true`, `yes`, `on`, `TRUE`, `Yes`, `0`, unset) → OFF (`0`).

```bash
_pool_config_bool() {
    local val="${1:-}"
    if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
}
```

### Consumers (all use strict `== "1"`)
| Line | Global | Function |
|------|--------|----------|
| 84 | (input) | `_pool_config_bool` |
| 242 | `POOL_ALLOW_SLOW_COPY` | `pool_check_btrfs` |
| 1295 | `POOL_ALLOW_SLOW_COPY` | `pool_copy_master` |
| 1515 | `POOL_HEADLESS` | `pool_chrome_launch` |
| 3491 | `POOL_DISABLE` | `pool_wrapper_main` (safety valve) |
| 4222 | `POOL_ALLOW_SLOW_COPY` | `pool_admin_doctor` |

### Documentation Contradictions
- `README.md:218`: "set to `1`/`true`/`yes` to launch Chrome with `--headless=new`" — FALSE
- `lib/pool.sh:4419` (`pool_admin_help`): "launch Chrome headless if set (1/true/yes)" — FALSE
- `lib/pool.sh:4420-4421`: "if set" for ALLOW_SLOW_COPY and DISABLE — MISLEADING

### Fix Approach
Change `_pool_config_bool` to accept the common truthy set (`1`, `true`, `yes`, `on`,
case-insensitive). All 5 consumer sites already use `== "1"` and will automatically
benefit since the normalizer still outputs `"1"` for ON. Update the function docstring,
`pool_admin_help` text, and README env var table to match.

### Impact (most severe — cutover safety valve)
`AGENT_BROWSER_POOL_DISABLE=true` does NOT disable pooling. An operator following the
documented `1`/`true`/`yes` form during cutover believes they are bypassing the pool
when they are not. PRD §2.17 states this valve is the only per-session opt-out.

---

## ISSUE 2: Concurrent port allocation has an unmitigated race

### Root Cause
`pool_find_free_port` (`lib/pool.sh:1383`) runs OUTSIDE the acquire flock (deliberately,
per §2.19 — concurrent boots parallelize). The anti-collision mechanism (write port to
lease before launch, `pool_boot_lane` step b, line 2227) has a TOCTOU window: two
concurrent acquires can both select the same free port before either writes it.

### The Stale Comment (lines 1330, 1377-1379)
```
# GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can both
#   pick the same port — the launch (M4.T2.S2) is authoritative + retries on EADDRINUSE.
```
**This is inaccurate.** The launch does NOT retry on EADDRINUSE:
1. `pool_chrome_launch` (`lib/pool.sh:1478`) does `pool_die` (FATAL) on instant-exit —
   no retry.
2. `_pool_launch_and_verify` (`lib/pool.sh:2123`) retries on CDP timeout but uses the
   SAME port — the collision recurs.
3. At no point does the boot path re-pick a different port.

### Failure Paths (both FATAL for the colliding agent)
1. Chrome exits instantly (EADDRINUSE) → `pool_die` at line 1532-1534 → process dies.
2. Chrome stays up but can't bind CDP → `pool_wait_cdp` 30s timeout → retry same port →
   second 30s timeout → `pool_boot_lane` returns 1 → `pool_wrapper_main` `pool_die`.

### Test Mitigation (not a code fix)
`test/concurrency.sh:264`: `sleep 0.3` staggers launches to avoid the race. Real
concurrent agents have no stagger.

### Fix Approach
1. In `pool_chrome_launch`, detect EADDRINUSE-like errors in Chrome's log on instant-exit
   and return 1 (retryable) instead of `pool_die` (fatal). Keep `pool_die` for other
   instant-exit causes (broken binary, bad flags).
2. In `_pool_launch_and_verify`, after any launch failure, call `pool_find_free_port`
   (which will exclude the current port since it's in the lease) and retry with the new
   port. Limit to one port re-pick.
3. Fix the stale "retries on EADDRINUSE" comment.
4. Update the concurrency test to exercise collision recovery (reduce/remove stagger).

---

## ISSUE 3: `close` then next driving command may skip a needed daemon rebind

### Root Cause
`pool_daemon_connected` (`lib/pool.sh:1696`) uses two read-only probes:
1. Is the session in `--json session list`?
2. Does Chrome answer `curl /json/version`?

After `close` (disconnect-only), the session LINGERS in the list and Chrome stays alive →
both probes pass → `pool_daemon_connected` returns 0 → `pool_ensure_connected`
(`lib/pool.sh:2306`) early-exits at line 2339-2341, SKIPPING the `pool_daemon_connect`
rebind. The next driving command execs against a daemon whose binding was just detached.

### The Close Path Does NOT Mark `connected=false`
`pool_wrapper_main` (`lib/pool.sh:3479`) handles close like any driving command:
1. Step h: `pool_ensure_connected` (ensures connected BEFORE close)
2. Step i: `pool_normalize_close` (strips `--all` only — pure argv rewriter)
3. Step k: `exec "$POOL_REAL_BIN"` (runs close — process replaced, nothing runs after)

No code path sets `connected=false` after a close. The lease's `connected` field stays
`true`. `pool_ensure_connected` does NOT read the `connected` field — it only reads
`session`, `port`, `ephemeral_dir` and relies on `pool_daemon_connected`'s probes.

### Fix Approach
1. In `pool_wrapper_main`, after arg normalization (step i), if the command is `close`,
   set `pool_lease_update "$N" connected false` BEFORE exec (between steps j and k).
2. In `pool_ensure_connected`, read the `connected` flag from the lease. If `connected`
   is `false`, skip the `pool_daemon_connected` early-exit and proceed to the reconnect
   path (which checks Chrome liveness and re-binds via `pool_daemon_connect`).
3. Add a test that verifies: close → next driving command succeeds (daemon re-binds).

### Confidence
Medium — requires runtime verification against real `agent-browser` + Chrome to confirm
whether driving commands auto-rebind a closed session. The fix is defensive: even if
agent-browser auto-rebinds, marking `connected=false` and having `pool_ensure_connected`
re-bind is harmless (redundant rebind).

---

## ISSUE 4: Bare `agent-browser` boots a full Chrome for a no-op/help invocation

### Root Cause
`pool_dispatch_classify` (`lib/pool.sh:3085-3110`) returns `"driving"` when no non-flag
command token is present (the "everything else → driving" default):

```bash
if [[ -z "$cmd" ]]; then
    printf 'driving\n'
    return 0
fi
```

This causes `pool_wrapper_main` to resolve the owner, acquire a lane, and boot Chrome
(CoW copy + launch + CDP wait + daemon connect), then `exec` the real binary with no
args — which typically just prints help and exits 0. The lane persists (owner alive)
until the `pi` process exits, wasting a Chrome process + ephemeral profile.

### Fix Approach
Change the empty-command case to return `"meta"` instead of `"driving"`:
```bash
if [[ -z "$cmd" ]]; then
    printf 'meta\n'
    return 0
fi
```
This mirrors the `--help`/`-h`/`--version` short-circuit. A subcommand-less invocation
is not a driving action. The existing test in `validate.sh` that checks "no-args default"
expects `"driving"` — update it to expect `"meta"`.

---

## ISSUE 5: `pool_admin_help` describes DISABLE / ALLOW_SLOW_COPY as "if set"

### Root Cause
Same as Issue 1. `lib/pool.sh:4419-4421`:
```
AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes)
AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set
AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set
```
"If set" implies any non-empty value works. Given Issue 1, only `"1"` works.

### Fix Approach
Resolve together with Issue 1. If Issue 1's fix accepts truthy values, update the help
text to say "set to 1/true/yes/on" for all three. If Issue 1's fix is rejected (keep
strict `"1"` only), update to say "set to 1" explicitly.

**Recommended**: Accept truthy values (Issue 1 fix) and update help text accordingly.

---

## Testing Architecture Notes

### Pure-function tests (Issues 1, 4, 5)
These can be tested in isolation by sourcing `lib/pool.sh` and calling the function
directly — no Chrome needed. The existing `validate.sh` self-tests already cover
`pool_dispatch_classify` (22 cases) and `_pool_config_bool` (via `pool_config_init`).

### Chrome-requiring tests (Issues 2, 3)
These require real Chrome and MUST follow AGENTS.md §1–§6:
- Isolated sandbox (temp `$HOME`, temp state dir, temp ephemeral root).
- Hard `timeout` on every subprocess.
- Single-setup runner (NOT per-test setup — the 3rd `setup()` call hangs).
- Reap all spawned processes (kill process groups, `wait` zombies).
- The `release_reaper.sh` pattern (`_abpool_run_release_reaper_suite`) is the approved
  single-setup runner. The `concurrency.sh` pattern staggers launches by 0.3s.

### Test files and their scope
| File | Scope | Chrome? | Setup pattern |
|------|-------|---------|---------------|
| `validate.sh` | Pure functions, self-tests | No | Per-test (safe — no process spawning) |
| `release_reaper.sh` | Release, reap, close semantics | Yes | Single-setup (`_abpool_run_release_reaper_suite`) |
| `transparency.sh` | Transparency checklist (§2.15) | Yes | Single-setup |
| `concurrency.sh` | N-parallel-agent concurrency | Yes | Single-setup with 0.3s stagger |
