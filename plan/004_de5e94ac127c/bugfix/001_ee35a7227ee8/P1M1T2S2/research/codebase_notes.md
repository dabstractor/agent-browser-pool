# Research notes — P1.M1.T2.S2 (per-lane boot lock)

## 1. Codebase facts verified (static reads only, per AGENTS.md §1)

- `pool_acquire_locked` (lib/pool.sh:2415-2433) is the ONLY flock today:
  `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` — subshell idiom,
  rc of subshell == rc of body function, stdout propagates through `$(...)`.
- The self-deadlock warning lives at lib/pool.sh:3250-3256 (pool_wait_for_lane
  design note): flock(2) locks are per OPEN FILE DESCRIPTION; opening a FRESH fd on
  POOL_LOCK_FILE from inside a waiter self-deadlocks. ⇒ the per-lane lock MUST be a
  NEW file, opened on fd 8 (never fd 9 / acquire.lock).
- `pool_boot_lane` (lib/pool.sh:2616+): validate lane → step a `pool_copy_master
  "$ephemeral_dir"` → step b port loop + `pool_lease_update "$lane" port "$port"`
  → step c+d `_pool_launch_and_verify` (guarded `if !`; on failure
  `_pool_release_lane_internals "$lane"; return 1`) → re-read port guard
  (`reread_port` split-local) → step e `pool_daemon_connect "abpool-$lane" "$port"`
  → step f connected=true + last_seen_at. Fatal path: `pool_die` on bad lane arg.
- `pool_state_init` (lib/pool.sh:259): mkdir -p lanes dir + touch acquire.lock.
  Helper `pool_lane_boot_lock` should sit near here per fix_design §2a.
- `pool_lease_field LANE FIELD` (lib/pool.sh:926): rc 1 on missing/corrupt lease —
  ALWAYS capture guarded (`if ! x="$(pool_lease_field ...)"`).
- Glob-safety verified: `pool_lanes_list` (1017) globs `*.json`; `pool_find_free_lane`
  tests `[[ -f n.json ]]`; `pool_reap_orphan_dirs` iterates `$POOL_EPHEMERAL_ROOT/*/`.
  A `<N>.boot.lock` file in `$POOL_LANES_DIR` is invisible to all three. Stale lock
  files are harmless (advisory flock on the open fd).
- `pool_die` inside a subshell exits the SUBSHELL only — with the `( flock ... )`
  idiom the rc still propagates to the caller (same as pool_acquire_locked's
  composition; the lock is released on subshell exit).

## 2. fix_design.md §2a + §2c-boot (the contract for this item)

- Helper: `pool_lane_boot_lock() { printf '%s\n' "$POOL_LANES_DIR/$1.boot.lock"; }`
  — creates nothing; docstring must cover fd-8 idiom, self-deadlock warning,
  glob-safety, stale-file harmlessness.
- Wrap pool_boot_lane body in `( flock -w 20 8; ... ) 8>"$(pool_lane_boot_lock "$lane")"`;
  `-w` must be ≥ 15s CDP budget + margin (20s chosen). On flock timeout (rc 1):
  fall back to current unlocked behavior + `_pool_log` — never hang the wrapper.
- Inside the lock: re-read lease; if `port>0` AND chrome alive/CDP answers → return 0
  WITHOUT re-copying (idempotent). Else run the normal guarded copy→port→launch→connect.
- Preserve `_pool_release_lane_internals` + `return 1` recoverable paths verbatim.

## 3. Downstream/upstream contracts

- Upstream P1.M1.T1.S1: `pool_copy_master` becomes idempotent (rm -rf stale target
  before cp) — makes a guarded second boot's copy safe.
- Upstream P1.M1.T2.S1 (PRP read): `test/bootrace.sh` provides
  `_bootrace_setup`/`_bootrace_teardown`, fake chrome with `FAKE_CHROME_DELAY` +
  `FAKE_CHROME_COUNT_FILE` (append "pid port dir" per launch), fake agent-browser,
  control case + known-red R3. This item ADDS case R4 (test_framework.md line 60:
  second command during copy, before port write → both succeed, ONE launch, lease
  ids match live chrome).
- Downstream P1.M1.T2.S3: `pool_ensure_connected` takes the SAME lock (fd 8) so
  connect and boot are mutually exclusive. Downstream T2.S4: sweep widening is
  defense-in-depth behind the lock.

## 4. Aliveness check idiom

Curl probe (project-canonical, lib/pool.sh:1447):
`curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1`
NEVER `kill -0` (ESRCH/EPERM ambiguity, AGENTS.md §4).