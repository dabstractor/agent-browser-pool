# Research notes — P4.M2.T1.S2 (caller-mode resolve selftest)

## Verified code facts (static reads, 2026-06 session)

### lib/pool.sh — pool_owner_resolve (~:536–660)
Resolution order (CRITICAL for the precedence assertion):
1. **TEST MODE** (`AGENT_BROWSER_POOL_OWNER_PID` non-empty + numeric) → uses the hook pid
   directly, returns 0. This branch is checked FIRST — the hook **outranks** caller mode.
   (Invalid non-numeric hook pid is ignored with a log line and falls through.)
2. **CALLER MODE** (`POOL_OWNER_MODE == "caller"`, frozen by `pool_config_init` step 6b
   from `ABPOOL_OWNER` any non-empty value, ~:225–233):
   - Guard: `PPID == 1` or `/proc/$PPID` missing → `pool_die` ("requires a live parent").
   - Keys on `$PPID` (the **parent** — production: the orchestrator subprocess), NOT `$$`.
     Note: the PRD §2.12 text says `$$`, but the implemented contract (P4.M1.T3.S1, merged)
     uses `$PPID`. **Follow the code**; the item description also says `$PPID`.
   - Populates: `POOL_OWNER_PID=$PPID`, `POOL_OWNER_COMM=$(cat /proc/$PPID/comm)`,
     `POOL_OWNER_STARTTIME=$(_pool_get_starttime $PPID)`, `POOL_OWNER_CWD=$(readlink /proc/$PPID/cwd)`.
   - No harness fail-fast, no ppid walk. Never fatal on the happy path (rc 0).
3. REAL MODE ppid walk (irrelevant here).

- Globals reset to defaults (`POOL_OWNER_PID="0"` etc.) at the top of EVERY resolve call →
  re-runnable; but in the shared main shell a direct call would CLOBBER the harness's own
  `POOL_OWNER_*` state → the selftest must run resolve inside a child shell.
- `_pool_get_starttime PID` at :462 — echoes digits, rc 1 on unreadable /proc.
- `pool_owner_alive` not needed here.

### Wrapper gate (~:3779)
`pool_owner_resolve` in the wrapper is always rc 0; `POOL_OWNER_PID == 0` ⇒ passthrough
(human terminal / no-owner fail-fast path). So asserting `POOL_OWNER_PID != 0` proves the
fail-fast bypass in caller mode.

### test/validate.sh framework
- Discovery: `compgen -A function | grep '^selftest_' | sort` in `_run_selftest_suite`
  (~:1170 area) — no registration; just define `selftest_owner_resolves_caller_mode`.
- Bodies run in the MAIN shell via `if "$fn"` (no top-level `( )` — EXIT-trap hazard,
  AGENTS.md §4). Every assert must end `|| return 1`.
- Helpers: `assert_eq <want> <got> <label>` (:57), `_fail <msg>` (:45).
- setup() (:204–223): single-setup; exports `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`
  for its sim pi owner → **caller-mode cases MUST unset both hook vars** or the TEST MODE
  branch wins.
- Canonical child-shell idiom for "don't clobber main-shell globals":
  `selftest_cdp_is_ours_uses_socket_owner` (~:1182) writes a `body.sh` under
  `$ABPOOL_TEST_ROOT/...`, runs `bash "$script" _ "$ABPOOL_REPO" "$outdir"` with
  `rc=0; bash ... || rc=$?`, asserts rc + captured stdout. Same pattern fits perfectly:
  the child's `$PPID` is the (live) selftest main shell — a valid live parent for the
  caller-mode guard.
- Inline-env-override precedent: `selftest_owner_resolves_non_pi_harness` (:351) uses
  `AGENT_BROWSER_POOL_OWNER_PID="$pid" ... pool_owner_resolve` — but that runs resolve in
  the MAIN shell. For this selftest we prefer the child body.sh (also protects globals),
  while still proving precedence with the hook set inside the child.
- `$PPID` gotcha: inside `( )` subshells / `bash -c` children `$PPID` is the parent —
  stable across the child's lifetime. Read it FIRST in the child and reuse for /proc reads.

### Environment safety
- Pure logic test: no Chrome, no leases, no spawned daemons. One short-lived `bash` child,
  naturally reaped via `|| rc=$?` (synchronous foreground). No traps needed.
- Validation: `bash -n test/validate.sh`, `shellcheck -s bash test/validate.sh`,
  `timeout 120 bash test/validate.sh` in the isolated sandbox only.

### Relationship to P4.M2.T1.S1 (parallel item)
S1 adds `selftest_config_owner_mode_and_lane_pin` (config-subshell idioms, same framework).
No overlap: this PRP covers `pool_owner_resolve`'s caller branch + hook precedence only.
If S1's selftest lands first, place this fn after it; otherwise after
`selftest_preflight_accepts_bare_name_on_path` / the newest config selftest block.