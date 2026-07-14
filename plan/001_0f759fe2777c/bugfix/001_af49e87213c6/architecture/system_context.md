# System Context — Bugfix 001

## Date: 2026-07-12
## Scope: End-to-end validation bugfix for agent-browser-pool

---

## 1. Codebase State — FULLY IMPLEMENTED (not greenfield)

The repository at `/home/dustin/projects/agent-browser-pool/` is **fully implemented**:
the original PRD was built out across 10 milestones (P1.M1–P1.M10). All source code
exists and passes its own test suite (when run in an isolated sandbox per AGENTS.md).

```
agent-browser-pool/
├── lib/pool.sh          ← 4424 LOC — the shared library (ALL logic lives here)
├── bin/agent-browser    ← 13 LOC  — wrapper shim (sources lib/pool.sh, calls pool_wrapper_main)
├── bin/agent-browser-pool← 25 LOC  — admin CLI shim (sources lib/pool.sh, calls pool_admin_main)
├── install.sh           ← 221 LOC — cutover installer (symlinks + doctor)
├── test/
│   ├── validate.sh      ← 364 LOC — test framework + pure-function self-tests
│   ├── release_reaper.sh← 411 LOC — release/reap/close tests (requires real Chrome)
│   ├── transparency.sh  ← 502 LOC — transparency checklist tests (requires real Chrome)
│   └── concurrency.sh   ← 429 LOC — N-parallel-agent concurrency test (requires real Chrome)
├── PRD.md               ← original product requirements (READ-ONLY)
├── README.md            ← user-facing documentation
└── AGENTS.md            ← operating rules for AI agents (CRITICAL — read first)
```

## 2. Bugfix Scope — 5 Issues (3 Major, 2 Minor)

This bugfix addresses 5 issues found during end-to-end validation:

| Issue | Severity | Root Cause | Fix Location |
|-------|----------|------------|--------------|
| 1 | Major | `_pool_config_bool` only accepts `"1"` | `lib/pool.sh:82-84` |
| 2 | Major | Port allocation TOCTOU race; no port re-pick on failure | `lib/pool.sh:1383, 2123, 1478` |
| 3 | Major | Close doesn't mark lease `connected=false`; ensure_connected skips rebind | `lib/pool.sh:3479, 2306` |
| 4 | Minor | Bare `agent-browser` classifies as `driving` (boots Chrome) | `lib/pool.sh:3085-3110` |
| 5 | Minor | `pool_admin_help` says "if set" (misleading given Issue 1) | `lib/pool.sh:4419-4421` |

Issues 1 and 5 share the same root cause (boolean normalization) and are resolved together.
Issue 4 is independent. Issues 2 and 3 are independent but more complex.

## 3. Architectural Patterns (from the implemented codebase)

### 3.1 Function Naming Convention
```
pool_*     ← public functions (entry points)
_pool_*    ← internal helpers
pool_config_*  ← configuration resolution
pool_lease_*   ← lease read/write/query
pool_dispatch_*← wrapper command dispatch
pool_admin_*   ← admin CLI commands
```

### 3.2 Error Handling Under `set -euo pipefail`
- **FATAL** (`pool_die`): genuine misconfiguration; exits the process. Used in
  `pool_chrome_launch` (instant-exit), `pool_copy_master` (non-btrfs), `pool_config_init`
  (bad config), `pool_lease_update` (corrupt lease).
- **NON-FATAL** (return 1): recoverable failures; caller decides. Used in
  `pool_find_free_port`, `pool_daemon_connected`, `pool_ensure_connected`, `pool_wait_cdp`.
- **RC 0 ALWAYS**: functions that must never fail. `pool_dispatch_classify`,
  `pool_normalize_close/connect`, `pool_strip_session_args`, `pool_chrome_kill`.

### 3.3 Lease JSON Schema
File: `$POOL_LANES_DIR/<N>.json`
```json
{
  "version": 1, "lane": 7,
  "ephemeral_dir": "/home/dustin/.agent-chrome-profiles/active/7",
  "port": 53427, "session": "abpool-7",
  "owner": { "pid": 836725, "comm": "pi", "starttime": 1234567890, "cwd": "/home/dustin/projects/x" },
  "chrome_pid": 104816, "chrome_pgid": 104816,
  "acquired_at": 1720000000, "last_seen_at": 1720000123,
  "connected": true
}
```
- Atomic writes via `_pool_atomic_write` (temp file + `mv`).
- `pool_lease_update LANE FIELD VALUE` — splice one top-level field via jq.
- `connected` is a JSON boolean (`true`/`false`), NOT the number 1.

### 3.4 Test Framework
- **validate.sh**: hand-rolled, dependency-free bash test harness. Sources `lib/pool.sh`,
  provides `assert_eq`, `assert_lane_exists`, `assert_lane_gone`, `run_test`, `abpool_run_suite`.
  Dual mode: `bash test/validate.sh` (self-test) or `source test/validate.sh` (define `test_*`).
- **release_reaper.sh / transparency.sh / concurrency.sh**: Chrome-requiring tests.
  Single-setup runner pattern (setup called ONCE, NOT per-test — per AGENTS.md §4).
- **Owner simulation**: `AGENT_BROWSER_POOL_OWNER_PID` + `AGENT_BROWSER_POOL_OWNER_STARTTIME`
  env vars override the ppid walk for test isolation.
- **Isolation**: hermetic setup/teardown (mktemp temp root + EXIT trap). All tests redirect
  `$HOME`, state dirs, and ephemeral root to a temp tree.

### 3.5 Boot Flow (relevant to Issue 2)
```
pool_wrapper_main
  ├─ pool_acquire_locked ──── ( flock 9; _pool_acquire_critical_section ) 9>$LOCK
  │    └─ returns provisional lane (port=0)     [FLOCK RELEASED]
  ├─ pool_boot_lane (NO flock)
  │    ├─ a. pool_copy_master
  │    ├─ b. pool_find_free_port → port         (TOCTOU: outside flock)
  │    │    └─ pool_lease_update port $port      (anti-collision write)
  │    ├─ c+d. _pool_launch_and_verify $port $dir $lane
  │    │    ├─ attempt 1: pool_chrome_launch → pool_wait_cdp
  │    │    │    └─ instant-exit → pool_die (FATAL) ← Issue 2 gap
  │    │    │    └─ CDP timeout → kill pgroup → retry
  │    │    └─ attempt 2: pool_chrome_launch → pool_wait_cdp  (SAME port)
  │    │         └─ CDP timeout → return 1 → drop lane
  │    ├─ e. pool_daemon_connect
  │    └─ f. pool_lease_update connected=true
  └─ pool_ensure_connected → exec real binary
```

### 3.6 Close → Rebind Flow (relevant to Issue 3)
```
Invocation 1: agent-browser close
  pool_wrapper_main
    ├─ h. pool_ensure_connected → pool_daemon_connected → returns 0 → early-exit
    ├─ i. pool_normalize_close (strip --all)
    ├─ j. pool_force_session
    └─ k. exec close --session abpool-N    → daemon disconnects session
      [session LINGERS in list] [Chrome stays alive] [lease connected stays true]

Invocation 2: agent-browser <driving command>
  pool_wrapper_main
    ├─ h. pool_ensure_connected
    │    └─ pool_daemon_connected:
    │         probe 1: session in list? → YES (lingering) ✅
    │         probe 2: chrome alive? → YES ✅
    │         → returns 0 → EARLY-EXIT (SKIPS rebind) ← Issue 3 gap
    └─ k. exec <command> --session abpool-N → runs against DISCONNECTED binding
```

## 4. Sandbox Safety Constraints (AGENTS.md)

**CRITICAL**: All research was static (code reading, `bash -n`, `shellcheck`). No real
Chrome, daemon, or test suite was launched against the shared sandbox. Implementation
agents MUST follow AGENTS.md §1–§6:
- Test in isolated sandbox (container/VM/bwrap or isolated temp-tree).
- Hard `timeout` on every subprocess that could block.
- Reap all spawned processes (kill process groups, `wait` zombies).
- Single-setup test runner (NOT per-test setup).
- Never touch operator's real Chrome / state dirs.
