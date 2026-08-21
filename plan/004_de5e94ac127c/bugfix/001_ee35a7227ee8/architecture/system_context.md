# System context — bugfix changeset 001 (BUG-001..BUG-006)

Verified by direct read of HEAD (`lib/pool.sh`, 4889 lines; `install.sh`, 141; `test/*`;
`plan/004_de5e94ac127c/validate.sh`, 586) plus three read-only scout runs. NO live
execution was performed (AGENTS.md §1 planning rules). Every claim below was confirmed
in source; PRD line references were cross-checked and are accurate as of HEAD.

## 1. Repo shape (confirmed)

- `lib/pool.sh` — the entire library (single file, sourced by everything).
- `bin/agent-browser-pool` — CLI entry (`source lib/pool.sh` + dispatch).
- `install.sh` — symlink + `pool_state_init` + doctor subprocess.
- `test/{validate,concurrency,release_reaper,transparency}.sh` — 4 suites (green at HEAD).
- `docs/` is EMPTY. User docs: `README.md` + skill dir
  `.agents/skills/agent-browser-pool/` (`SKILL.md`, `README.md`,
  `references/configuration.md`). NOTE: the PRD's "references/configuration.md" means
  `.agents/skills/agent-browser-pool/references/configuration.md` (no top-level
  `references/` exists).
- `plan/004_de5e94ac127c/validate.sh` — prior changeset's validation artifact (BUG-006).

## 2. Locking model (critical for BUG-002 design)

- ONE global lock: `POOL_LOCK_FILE="$POOL_STATE_DIR/acquire.lock"` (set in
  `pool_config_init`, lib/pool.sh:238-241). The ONLY flock site is
  `pool_acquire_locked` (lib/pool.sh:2415-2433):
  `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`.
- The lock is held ONLY for scan/reap/reuse/choose/claim. Boot work
  (`pool_copy_master` → port → `pool_chrome_launch` → `pool_wait_cdp` →
  `pool_daemon_connect`) runs OUTSIDE the flock by design ("key_findings FINDING 2").
- Everything else is deliberately lock-free (`pool_reap_stale`, `pool_release_lane`,
  `_pool_release_lane_internals`, `pool_wait_for_lane`, `pool_ensure_connected`).
  Design note at lib/pool.sh:3250-3256 warns: a fresh OFD on `POOL_LOCK_FILE` from
  inside a waiter would SELF-DEADLOCK — any new lock MUST be a NEW file.
- **No per-lane locks exist anywhere.** There are no `pool_lock`/`with_pool_lock`
  helpers. A per-lane boot mutex is a new pattern.
- **Glob safety for a new lock file:** `pool_lanes_list` globs `"$POOL_LANES_DIR"/*.json`
  only; `pool_find_free_lane` tests `[[ -f "$POOL_LANES_DIR/$n.json" ]]`. A file named
  `$POOL_LANES_DIR/<N>.lock` is invisible to both (and to `pool_reap_orphan_dirs`,
  which iterates `$POOL_EPHEMERAL_ROOT/*/`). Safe location, no mkdir needed
  (`pool_state_init` already creates `lanes/`).

## 3. Lease JSON schema (pool_lease_write, lib/pool.sh:732-785)

```
{version, lane, ephemeral_dir, port, session,
 owner:{pid, comm, starttime, cwd},
 chrome_pid, chrome_pgid, acquired_at, last_seen_at, connected}
```
Provisional claim: `port=0, chrome_pid=0, chrome_pgid=0, connected=false`
(lib/pool.sh:2367-2369, 2384-2386). `connected=false` + port>0 = booted but daemon
unbound (the state a second concurrent command sees).

## 4. Wrapper flow (pool_wrapper_main, lib/pool.sh:3784-3902) — where both majors enter

1. `pool_config_init` + `pool_state_init` + `_pool_preflight_real_bin`
2. `pool_owner_resolve` (die if no recognized-harness ancestor)
3. Pin mode → `pool_acquire_locked`; else `pool_lease_find_mine` (lib/pool.sh:1053-1078,
   matches `owner.pid` + `pool_owner_alive`):
   - **Reuse path (lib/pool.sh:3818-3834):** live lease found. If `port==0|null` →
     stuck-lane recovery sets `_lane_fresh=1` → re-boot below. Else `_lane_fresh=""` →
     straight to `pool_ensure_connected` (the BUG-002 entry for a booting lane).
   - Acquire path → `pool_wait_for_lane` fallback on exhaustion.
4. Boot branch (lib/pool.sh:3853-3861): `_lane_fresh` && port==0 → `pool_boot_lane "$N"`.
5. `pool_ensure_connected "$N" || pool_die "lane N not connected; aborting"` (line ~3868).
6. normalize/force-session → (close marks `connected=false`) → terminal `exec`.

## 5. BUG-001 — CONFIRMED (PRD h2.2/h3.0)

- `pool_copy_master` spans **lib/pool.sh:1278-1357**. The reflink copy at ~1304:
  `if ! cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null; then`
  has **NO guard for a pre-existing `$target_dir`**. GNU cp with an existing dst dir
  nests src INTO it (`dst/<basename-src>/`). The `rm -rf -- "$target_dir"` at ~1306 is
  on the reflink-FAILURE branch only. The slow-copy retry (~1313) would nest the same
  way (cp -a src existing-dst also nests).
- Reachable from the stuck-lane recovery: `pool_boot_lane` step a
  (lib/pool.sh:2628, `pool_copy_master "$ephemeral_dir"`) with the dir left behind by a
  crash between copy and the port write (port write is step b, lib/pool.sh:2651).
  Recoverable failure paths DO `_pool_release_lane_internals` (rm -rf dir, masking);
  fatal `pool_die` paths leave the dir → nesting on the next boot.
- **Fix seam:** immediately after `mkdir -p -- "$parent"` (~1302) and before the cp
  (~1304): `rm -rf -- "$target_dir" 2>/dev/null || true` (target is already validated
  non-empty + absolute at 1279-1296; a defensive prefix guard is optional). This also
  fixes the slow-copy path. Regression must cover BOTH fs paths (see test_framework.md).
- On tmpfs the bug is masked (reflink fails → rm-rf retry path); on btrfs it is silent
  corruption → fresh untrusted profile, exit 0.

## 6. BUG-002 — CONFIRMED (PRD h2.2/h3.1)

- `pool_ensure_connected` spans **lib/pool.sh:2744-2880**, lock-free. Flow: lease read
  (a) → port>0 gate (2783) → fast path `connected==true && pool_daemon_connected`
  (2804-2810) → curl `/json/version` probe (2812) + identity gate `pool_cdp_is_ours`
  → relaunch branch (2832+): strip Singleton*, `pool_chrome_launch "$port" "$dir" "$lane"`
  (2840), **early chrome-id write clobbers the lease** (2847-2849), `pool_wait_cdp`
  (2854; 30×0.5s = 15s budget, kills the pgroup on timeout, lib/pool.sh:1795-1860).
- Race: owner's 2nd concurrent command reuses the live lease (port>0, connected=false),
  curl fails only because Chrome's CDP isn't open YET → 2nd Chrome launched on the same
  port+dir → loses port race → wait_cdp identity loop (socket-owner pid != doomed pid)
  → 15s timeout → pgroup kill of the WRONG (2nd) chrome → `return 1` → wrapper
  `pool_die` (spurious). Lease now holds dead ids of the 2nd chrome.
- Leak: `_pool_release_lane_internals` (lib/pool.sh:2060-2118) kills by the clobbered
  dead ids (no-op), then rm -rf's the dir → REAL Chrome survives with a deleted
  user-data-dir. The (3b) sweep at **2083-2101** fires only when BOTH ids
  non-numeric/≤0 — positive-but-dead defeats it.
- Same-owner guards that the fix must compose with: in-lock one-lane-per-owner
  (auto path step 0, lib/pool.sh:2329-2348 — idempotent reuse; pinned path step 5,
  2265-2282 — die) and pre-lock `pool_lease_find_mine`. A 2nd concurrent command lands
  in the REUSE path with NO boot synchronization — that is the missing piece.
- **Fix seams (chosen design in fix_design.md):** (1) per-lane boot/connect flock;
  (2) re-read the lease under the lock (double-checked); (3) verify the recorded
  chrome pid is actually dead before relaunching (`/proc/<pid>` — NEVER `kill -0`);
  (4) widen (3b) to always sweep by cmdline when releasing.

## 7. BUG-003 — CONFIRMED (PRD h2.3/h3.2)

- `pool_lane_is_stale` (lib/pool.sh:1189-1225): rc 0=STALE / 1=LIVE / **2=NO LEASE
  (missing OR corrupt → skip)**. `pool_reap_stale` (3040-3094) skips rc 2 forever.
- `pool_reap_orphan_dirs` (3131-3202): orphan branch fires when `pool_lease_exists`
  rc 1 (missing OR corrupt); removes the DIR but never `lanes/N.json`.
- `pool_lease_exists` (968-983): `[[ -f ]] && _pool_json_valid` → corrupt = rc 1.
- `pool_admin_release` numeric branch (4394-4420): corrupt → "Lane N has no active
  lease." rc 1. (`_pool_release_lane_internals` early-returns 0 on unreadable lease,
  so it can't clean it either.)
- `pool_find_free_lane` (1126-1135) uses `[[ -f ... ]]` DELIBERATELY (comment 1108-1110:
  corrupt lease = occupied, collision safety). **Do not change this** — make the
  corrupt state reclaimable instead.
- `pool_admin_status` corrupt row: lib/pool.sh:4147-4153 → permanent `? ? … STALE`.
- `_pool_atomic_write` (302-345): no fsync, deliberate + documented (rename is atomic
  same-FS; power-loss leaves OLD intact + orphan .tmp). See fix_design.md §5 for the
  fsync decision.

## 8. BUG-004 — CONFIRMED (PRD h2.3/h3.3)

- Doctor `[filesystem]` probe: lib/pool.sh:4643-4661, `fstype="$(findmnt -nno FSTYPE -T
  "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"` (~4649). `findmnt -T` on a NONEXISTENT
  path exits 1 EMPTY → `fstype=""` → `FAIL (unknown; not btrfs)` on a fully-btrfs host.
  It is the ONLY doctor probe that conflates "absent" with "not btrfs" (deps use
  `command -v`; master uses `-d` + `ls -A`).
- `pool_state_init` (259-267) creates only lanes/ + acquire.lock. install.sh step 2
  (line 98) calls it; step 3 (103-111) runs `"$REPO_DIR/bin/agent-browser-pool" doctor`.
  Nothing pre-creates `$POOL_EPHEMERAL_ROOT` (default `~/.agent-chrome-profiles/active`).
- The pattern to copy: `pool_copy_master` mkdir's the parent then probes the parent
  (lib/pool.sh:1295-1300, 1321). See fix_design.md §3 for the chosen variant.

## 9. BUG-005 — CONFIRMED (PRD h2.3/h3.4)

- Help lines **lib/pool.sh:4879-4880** (inside `pool_admin_help`, 4806-4890): says
  "extra recognized harness command names (comma-separated; **appended to
  pi/claude/codex/agy**)" — two errors: append (code REPLACES) and antigravity omitted.
- Code: `pool_config_init` lib/pool.sh:207-213 — `${AGENT_BROWSER_POOL_HARNESSES:-pi,
  claude,codex,agy,antigravity}`, lowercased, comma-squeezed, empty→default. REPLACE
  semantics. README.md:320 and
  `.agents/skills/agent-browser-pool/references/configuration.md:28` both already
  document replace correctly — **only the built-in help is wrong** (text-only fix).

## 10. BUG-006 — CONFIRMED (PRD h2.3/h3.5)

- `plan/004_de5e94ac127c/validate.sh:24-25`:
  `ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; cd "$ROOT"`
  → ROOT = `plan/004_de5e94ac127c/`, then repo-relative invocations rc-127:
  lint loop :43, `bash bin/agent-browser-pool` :73/:278/:448/:482/:496/:540/:550,
  `bash install.sh` :310, `bash test/validate.sh` :153. Only path variable is `ROOT`
  (no REPO_ROOT). Script lives at `<repo>/plan/004_de5e94ac127c/validate.sh` →
  repo root is `dirname/../../`. Verified underlying checks are green when paths
  resolve (88/0), so ONLY the bootstrap is broken.
- NOTE: `plan/**/tasks.json`, `PRD.md`, `prd_snapshot.md`, `prd_index.txt` are
  orchestrator/human-owned — `validate.sh` is NOT in that list and the PRD explicitly
  requires fixing it.

## 11. House style constraints for implementers (from AGENTS.md + code)

- `set -euo pipefail` everywhere; errexit-exempt idioms (`if !`, `||`, `&&`) for every
  rc-1 call; NEVER `local x="$(…)"` (SC2155); never a bare `kill`/`pgrep`/`curl`.
- NEVER `kill -0` for liveness (ESRCH vs EPERM ambiguity) — use `/proc/<pid>`, `pgrep`,
  or a real probe. Kill process GROUPS (`kill -- -"$pgid"` then `-9`), `wait` after kill.
- `findmnt -T` is MANDATORY for fs probes (bare `findmnt "$dir"` breaks on this host).
- Every blocking subprocess under `timeout`. Tests: single-setup runner only.
- pool_die (exit 1) is NOT catchable with `|| true` — wrap in a subshell to contain.