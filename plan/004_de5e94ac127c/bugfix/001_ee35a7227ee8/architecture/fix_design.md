# Fix design & decision record — changeset 001 (BUG-001..BUG-006)

Chosen designs, grounded in system_context.md. Each section: the fix, why, and the
exact seams. Line numbers refer to HEAD at breakdown time — re-verify with grep
before editing (implementers MUST not trust stale line numbers blindly).

## §1 BUG-001 — existing-target guard in pool_copy_master

**Fix:** in `pool_copy_master` (lib/pool.sh:1278-1357), immediately after the
`mkdir -p -- "$parent"` (~1302) and BEFORE the reflink cp (~1304), insert:

```bash
# Crash-recovery guard (BUG-001): a previous boot may have died between the copy and
# the port write, leaving a stale/partial target dir. GNU cp with an EXISTING dst dir
# nests src INTO it (dst/<basename-src>) → the lane would run a FRESH empty profile.
# target_dir is validated non-empty + absolute above; this rm is idempotent.
if [[ -e "$target_dir" ]]; then
    rm -rf -- "$target_dir" 2>/dev/null \
        || pool_die "pool_copy_master: cannot remove stale target dir: $target_dir"
fi
```

**Why rm (not fail loudly):** the stuck-lane recovery path (wrapper ~3818-3834 →
`pool_boot_lane` step a, ~2628) is a DESIGNED re-boot of a crashed lane; the stale dir
is by definition untrusted partial state (crash between copy and port write — the lease
holds port=0/chrome_ids=0, so nothing live can own it... EXCEPT the BUG-002 concurrent
case — which §2's boot mutex makes impossible: two boots of one lane can no longer
overlap). Failing loudly would permanently wedge the very recovery the last changeset
added. The reflink copy is ~instant, so re-copying costs nothing.

**Also covers:** the slow-copy retry branch (cp -a nests identically) and any future
caller. No schema/API change. Keep the existing "NEVER mkdir the target" comment and
UPDATE it to note the rm guard.

**Test contract:** (a) btrfs/real-FS path — pre-create `$EPH/1` with junk + master
present → drive a boot → assert `$EPH/1` contains `Local State` at TOP level and NO
`$EPH/1/<master-basename>/` nesting; (b) wrapper-level: provisional lease port=0 with
pre-existing dir → next driving command succeeds and profile is the master's (PRD
§2.15 recovery). tmpfs-only hosts cannot catch the btrfs silent path — the guard test
must assert the GUARD ITSELF (dir removed → fresh copy), which works on any FS.

## §2 BUG-002 — per-lane boot/connect mutex + dead-pid verification + sweep widening

Three coordinated changes (all needed; any one alone leaves a leak window):

### 2a. Per-lane lock file + helper (new, ~30 lines, placed near pool_state_init)

```bash
# pool_lane_boot_lock N  — echo the per-lane lock path (creates nothing).
pool_lane_boot_lock() { printf '%s\n' "$POOL_LANES_DIR/$1.boot.lock"; }
```

Consumers use the existing canonical idiom on a NEW fd (fd 8), NEVER fd 9 on
`POOL_LOCK_FILE` (self-deadlock hazard, lib/pool.sh:3250-3256). `$POOL_LANES_DIR`
already exists (pool_state_init); `*.boot.lock` is invisible to `pool_lanes_list`
(globs `*.json`), `pool_find_free_lane` (`[[ -f n.json ]]`), and
`pool_reap_orphan_dirs` (iterates `$POOL_EPHEMERAL_ROOT/*/`). No cleanup needed
(stale lock files are harmless — flock is advisory on the open fd, not the file's age).

### 2b. Serialize + double-check in pool_ensure_connected (lib/pool.sh:2744-2880)

Wrap the CONNECT/RELAUNCH portion (from the curl probe at ~2812 through the relaunch
success path ~2875) in:

```bash
(
    flock -w 20 8          # bounded wait: a peer boot holds this ≤ copy+15s CDP
    <re-read lease; re-check fast path + curl; relaunch only if truly dead>
) 8>"$(pool_lane_boot_lock "$lane")"
```

Inside the lock: **re-read the lease** (a peer may have finished the boot and flipped
`connected=true` — then just proceed/rebind) and **verify the recorded chrome pid is
actually dead before relaunching**: `/proc/<pid>` existence (NEVER `kill -0` —
ESRCH/EPERM ambiguity, AGENTS.md §4). If `/proc/$chrome_pid` exists → the Chrome is
alive (it just hadn't opened CDP yet) → do NOT relaunch; re-probe curl briefly /
retry `pool_daemon_connect`; only a confirmed-dead pid (or ids=0 with no
`user-data-dir=` cmdline match) proceeds to relaunch. `flock -w 20` bounds the wait so
a wedged peer cannot hang the wrapper forever (timeout → fall back to current
behavior + `_pool_log`; wrapper surfaces a clean error, not a hang). Set `-w` ≥ CDP
budget (15s) + margin.

**Crash-window chrome-ids:** the relaunch branch's early chrome-id write (2847-2849)
stays — but now only ONE process at a time can be in it, so it can no longer clobber
live ids with a doomed second chrome's ids.

### 2c. Widen the (3b) cmdline sweep in _pool_release_lane_internals (2083-2101)

Current gate: fires only when BOTH ids non-numeric/≤0. Change to: ALWAYS attempt the
anchored `user-data-dir=$dir( |$)` cmdline sweep as a **fallback when the id-based
kill found nothing live** — i.e. after `pool_chrome_kill`, if `/proc/<chrome_pid>`
still exists (foreign/alive) OR ids were ≤0, run the sweep. Simplest correct form:
drop the `both-ids-≤0` precondition and sweep whenever `pgrep -f` matches and the
recorded pid is not confirmed-alive-and-matching. This closes the positive-but-dead
clobber leak (the exact class (3b) was written for) AND the BUG-002 clobber state.
Keep the anchored pattern + `pkill`/`pkill -9` + `sleep 0.2` escalation verbatim.

**Why a new lock file (not reuse acquire.lock):** boot intentionally runs OUTSIDE the
global flock (FINDING 2 — concurrent boots are the design); blocking the global
acquire lock on a 15s CDP wait would serialize ALL agents' acquires. The per-lane
file scopes the wait to exactly the colliding pair.

**Composition with same-owner guards:** the 2nd command takes the reuse path
(`pool_lease_find_mine` → port>0) → `pool_ensure_connected` → blocks on the lane lock
→ peer finishes boot → 2nd command re-reads lease, sees `connected=true` (or curl now
succeeds) → rebinds/returns 0. Spurious failure, duplicate chrome, clobber, and leak
all eliminated. If the 2nd command instead arrives pre-port-write, both land in
`pool_boot_lane`; the same lane lock must therefore also wrap `pool_boot_lane`'s
copy+launch (or at minimum the copy — where §1's guard then makes the second boot's
copy a clean no-op-refresh). Prefer: wrap the whole `pool_boot_lane` body in the lane
lock with the same `-w` bound and a post-lock lease re-read (if port>0 now, another
wrapper already booted it → return 0 without re-copying).

**Test contract:** fake chrome with a startup delay knob (sleep N before serving
/json/version — see test_framework.md §3); launch cmd A backgrounded, cmd B at ~0.8s;
assert: B rc=0, exactly ONE chrome launch, lease chrome_pid == live chrome pid,
`release all` leaves ZERO chrome processes (pgrep user-data-dir) and zero dirs.

## §3 BUG-004 — doctor probes an existing ancestor

**Fix (doctor-side, chosen over install.sh-side):** in `pool_admin_doctor`
(lib/pool.sh:4643-4661) replace the bare probe with the pool_copy_master pattern —
probe the nearest EXISTING ancestor, and mkdir the root so future checks are exact:

```bash
# BUG-004: the ephemeral root may not exist yet on a fresh install (first created by
# pool_copy_master at first acquire). findmnt -T on a MISSING path exits 1 EMPTY →
# false "not btrfs". Mirror pool_copy_master: ensure the dir, then probe it.
mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true
fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
```

`doctor` is an operator diagnostic — creating the (documented, default
`~/.agent-chrome-profiles/active`) directory is a safe, user-visible improvement and
also makes repeat runs exact. Keep `findmnt -T` (MANDATORY on this host). Do NOT touch
`pool_check_btrfs` (acquire-time gate; its GOTCHA comments at 268-271 explain why it
must stay as-is). install.sh needs NO change (chosen minimal path; README doctor
section gets a Mode-A note that doctor creates the dir if absent).

**Test contract:** fresh temp tree, `AGENT_CHROME_EPHEMERAL_ROOT=$T/active-missing`
(nonexistent) → doctor's `[filesystem]` line must be `OK (btrfs)` on a btrfs host (or
WARN with slow-copy allowed), rc reflects real FS only; and the dir now exists.

## §4 BUG-003 — corrupt leases become reclaimable (reap + release), keep safety

Two surgical seams; `pool_lane_is_stale` rc=2 and `pool_find_free_lane`'s `[[ -f ]]`
stay UNTOUCHED (deliberate collision safety, system_context.md §7):

1. `pool_reap_orphan_dirs` (3131-3202), orphan branch: after the prefix-guarded
   `rm -rf -- "$dir"`, ALSO remove a present-but-invalid lease file:
   `if [[ -f "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base"; then
    rm -f -- "$POOL_LANES_DIR/$base.json"; _pool_log ...; fi` — frees the lane number.
   (Dir gone + corrupt lease = definitionally unowned; safe.)
2. `pool_admin_release` numeric branch (4394-4420): probe `[[ -f
   "$POOL_LANES_DIR/$target.json" ]]` in addition to `pool_lease_exists`. If the file
   exists but is INVALID → treat as releasable: run the teardown directly (rm lease
   with the same prefix/numeric guards `_pool_release_lane_internals` uses + kill any
   `user-data-dir=$POOL_EPHEMERAL_ROOT/$target` cmdline match — cannot trust lease
   ids) and report `Released lane N (corrupt lease).` rc 0. Clean lease → current path.

**fsync decision (PRD recommendation 'consider fsync'):** NO code change —
`_pool_atomic_write`'s no-fsync is deliberate, documented (302-345), and atomic-rename
already prevents TORN files; power-loss leaves OLD-intact + orphan .tmp. Instead: (a)
the reclaim paths above make any corrupt lease (from ANY cause) clearable, and (b)
extend `pool_reap_orphan_dirs` (or doctor) to also sweep stale `lanes/*.tmp` orphans.
Record this decision in the implementing subtask's DOCS line (comment update only).

**Test contract:** corrupt `7.json` + orphan dir 7 → `reap` removes BOTH (dir count 1,
lane freed: `pool_find_free_lane` returns 7 or status shows no row); `release 7` on
corrupt lease (dir present or absent) → rc 0, lease gone, no chrome with
user-data-dir=.../7 survives; status no longer shows the `? STALE` row.

## §5 BUG-005 — help text only

Rewrite lib/pool.sh:4879-4880 to match code + README.md:320 +
`.agents/skills/agent-browser-pool/references/configuration.md:28`:
"recognized harness command names (comma-separated; REPLACES the default set
pi,claude,codex,agy,antigravity — empty/unset → default)". Text-only; no behavior,
no schema. Contract test: `help` output contains "replaces" + "antigravity" and NOT
"appended".

## §6 BUG-006 — validate.sh ROOT walks to repo root

**Fix:** plan/004_de5e94ac127c/validate.sh:24 →
`ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"`.
(Comment line 25's `cd "$ROOT"` stays — everything downstream assumes repo-root CWD.)
Optionally add a one-line usage comment: run `bash plan/004_de5e94ac127c/validate.sh
[--fast]` from anywhere. Only `ROOT` exists; no other variables to touch. The plan/
dir is NOT in AGENTS.md's read-only list and the PRD explicitly mandates this fix.

## §7 Ordering & dependencies (canonical — matches tasks.json IDs)

- **P1.M1.T1.S1** — BUG-001 guard in pool_copy_master (+ R1/R2 regressions). No deps.
- **P1.M1.T2.S1** — test/bootrace.sh skeleton + fake-chrome/agent-browser fixtures
  (delay + launch-count knobs). No deps; provides the harness every later case uses.
- **P1.M1.T2.S2** — per-lane lock helper + wrap pool_boot_lane (+ idempotent
  re-check; R4). Deps: T1.S1 (re-boot path calls the guarded copy), T2.S1.
- **P1.M1.T2.S3** — pool_ensure_connected: lock the connect/relaunch path, re-read
  lease under lock, verify recorded pid dead before relaunch (R3). Deps: T2.S2.
- **P1.M1.T2.S4** — widen the (3b) release sweep (defense-in-depth leak closure).
  Deps: T2.S2 (same file region; avoid merge churn).
- **P1.M1.T3.S1** — major-fix integration gate: R1–R4 + all 4 repo suites green in
  an isolated sandbox, zero orphans. Deps: T2.S3, T2.S4.
- **P1.M2.T1.S1** (reap clears corrupt lease), **P1.M2.T1.S2** (release N clears
  corrupt lease), **P1.M2.T2.S1** (doctor ancestor probe), **P1.M2.T3.S1** (help
  text), **P1.M2.T4.S1** (validate.sh ROOT) — mutually independent.
- **P1.M3.T1.S1** — final changeset regression gate (everything incl. the fixed
  validation artifact run from repo root). Deps: every implementing subtask.
- **P1.M3.T2.S1 / S2** — Mode-B changeset-level doc sync (README; then skill docs).
  Deps: all implementing subtasks + the gate. LAST work in the changeset.