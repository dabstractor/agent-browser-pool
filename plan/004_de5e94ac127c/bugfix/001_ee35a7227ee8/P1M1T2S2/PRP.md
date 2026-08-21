# PRP — P1.M1.T2.S2: Per-lane boot lock — `pool_lane_boot_lock` helper + serialize `pool_boot_lane` with idempotent re-check

> **Bugfix context**: This is the **lock half** of BUG-002 (Major — same-owner boot
> race, PRD h2.2/h3.1). It introduces the pool's FIRST per-lane lock (a new
> `$POOL_LANES_DIR/<N>.boot.lock` on fd 8) and wraps `pool_boot_lane` in it, with a
> post-lock idempotent re-check so a concurrent (or crash-recovery) second boot of the
> same lane becomes a no-op instead of a nested copy / duplicate Chrome / clobbered
> lease. It builds on **P1.M1.T1.S1** (idempotent `pool_copy_master` — in flight,
> treat its PRP as a hard contract) and the **P1.M1.T2.S1** harness (`test/bootrace.sh`
> with `FAKE_CHROME_DELAY` + `FAKE_CHROME_COUNT_FILE` + `_bootrace_setup`/`_bootrace_teardown`
> — read its PRP first; you EXTEND that file with case R4). Downstream, **P1.M1.T2.S3**
> takes the SAME lock in `pool_ensure_connected`, and **T2.S4**'s sweep widening is
> defense-in-depth behind it.

## Goal

**Feature Goal**: Make `pool_boot_lane` mutually exclusive per lane and idempotent: two same-owner commands that race into the pre-port boot window must serialize, the loser must detect that the winner already booted the lane (port>0 + CDP alive) and return 0 without re-copying or re-launching, and no wrapper may ever hang on the lock (bounded `flock -w 20`, timeout → current unlocked behavior + log).

**Deliverable**:
1. `lib/pool.sh` — NEW helper `pool_lane_boot_lock` (placed near `pool_state_init`, ~line 259) with a full docstring (fd-8 idiom, fd-9 self-deadlock hazard, glob-safety, stale-file harmlessness).
2. `lib/pool.sh` — `pool_boot_lane` body wrapped in `( flock -w 20 8; … ) 8>"$(pool_lane_boot_lock "$lane")"` with (a) a flock-timeout fallback to current behavior + `_pool_log`, (b) an in-lock lease re-check: `port>0` AND the lane's Chrome alive/CDP answering → `return 0` WITHOUT re-copying; else the existing copy → port → launch+verify → connect → finalize steps run unchanged (recoverable failures still `_pool_release_lane_internals "$lane"` + `return 1`).
3. `test/bootrace.sh` — NEW case **R4** (test_framework.md spec: second command fires during the copy, before the port write → both commands rc 0, exactly ONE line in `FAKE_CHROME_COUNT_FILE`, no nesting, lease `chrome_pid` matches the live fake chrome). R3 (the post-port race) may STILL be red — it goes green in T2.S3 when `pool_ensure_connected` takes the same lock. Do not implement T2.S3/T2.S4 here.

**Success Definition**:
- `bash -n lib/pool.sh` and `shellcheck -s bash -S warning lib/pool.sh` clean; same for `test/bootrace.sh`.
- In an isolated sandbox (`test/bootrace.sh` harness), R4 PASSES: both commands exit 0, the count file has exactly 1 line, no `master*` nesting inside `$EPH/<N>`, lease `chrome_pid` == live fake chrome pid.
- The control case and R1/R2 (from T1.S1/S2.S1) still PASS — no regression to single-boot behavior (the lock is invisible on the happy path).
- Zero orphan processes after the suite (per-case cleanup + teardown, AGENTS.md §3).
- No user-facing/config/API surface change; the helper docstring is the documentation.

## User Persona

**Target User**: Downstream implementer of P1.M1.T2.S3 (`pool_ensure_connected` takes the same fd-8 lock on the same file) and P1.M1.T3.S1 (integration gate running R1–R4). Secondary: any future contributor adding per-lane critical sections.

**Use Case**: An agent fires two pool commands in parallel while lane N is mid-boot (the copy takes seconds on a real profile). Command B must not nest a master copy (BUG-001 trigger), must not launch a second Chrome, and must not clobber `chrome_pid`/`chrome_pgid`.

**User Journey**: cmd A boots lane 1 (holds `<1>.boot.lock` on fd 8) → cmd B enters `pool_boot_lane`, blocks on `flock -w 20 8` → A finishes (port>0, CDP up, connected=true) → B acquires the lock, re-reads the lease, sees port>0 + curl answers → returns 0 without touching the filesystem again → both commands succeed against the SAME Chrome.

**Pain Points Addressed**: PRD h3.1 — spurious failure, duplicate Chrome, clobbered lease ids, leaked Chrome surviving release; also the BUG-001 nested-copy trigger for the pre-port double-boot path.

## Why

- Today `pool_boot_lane` runs entirely OUTSIDE any lock (deliberate: the global acquire lock must not serialize 15s CDP waits — FINDING 2, see the design note at lib/pool.sh:3240-3256). The per-lane file scopes the mutual exclusion to exactly the colliding pair.
- Reusing `acquire.lock` (fd 9) is FORBIDDEN: a fresh open-file-description on a file the caller's process tree may hold self-deadlocks (flock(2) semantics, warned at lib/pool.sh:3250-3256).
- The idempotent re-check turns the crash-recovery re-boot (a lease stuck at port=0 with the dir already copied — the PRD BUG-001 repro path) into a safe no-op-refresh instead of a second copy/launch.

## What

### Success Criteria

- [ ] `pool_lane_boot_lock N` echoes `$POOL_LANES_DIR/N.boot.lock`; creates nothing; validates nothing (callers validate the lane).
- [ ] `pool_boot_lane` serializes on fd 8 with `flock -w 20`; on lock timeout it logs via `_pool_log` and proceeds UNLOCKED (current behavior) — the wrapper never hangs.
- [ ] Under the lock, if the lease has `port>0` and `curl -sf --max-time 2 http://127.0.0.1:$port/json/version` answers → `return 0` immediately (no `pool_copy_master`, no launch).
- [ ] All pre-existing failure semantics preserved: recoverable failures → `_pool_release_lane_internals` + `return 1`; `pool_die` paths still fatal (and now merely exit the flock subshell — rc must propagate).
- [ ] R4 case added to `test/bootrace.sh` and PASSES with this change; R3 remains permitted-red until T2.S3.
- [ ] No other call site changes; `pool_ensure_connected` is UNTOUCHED in this subtask.

## All Needed Context

### Context Completeness Check

If someone knew nothing about this codebase: they need the flock idiom to copy, the exact current body of `pool_boot_lane` (provided below), the fd/lock-file constraints, and the harness contract from T2.S1. All are inlined here.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: pool_acquire_locked (2415-2433) — the canonical `( flock 9; body ) 9>"$file"` idiom to mirror on fd 8
  pattern: subshell holds the lock; subshell rc == body rc; stdout propagates through $(...)
  gotcha: pool_die inside the subshell exits only the SUBSHELL — the rc still propagates; lock released on exit

- file: lib/pool.sh
  why: pool_wait_for_lane design comment (3240-3256) — the fd-9/acquire.lock SELF-DEADLOCK warning; why boot runs outside the global lock
  critical: NEVER open a fresh OFD on POOL_LOCK_FILE; the new lock is a NEW file on fd 8

- file: lib/pool.sh
  why: pool_boot_lane (2616-2699) — the function being wrapped; steps a-f with all guards
  pattern: keep every `if ! helper; then _pool_release_lane_internals "$lane"; return 1; fi` block VERBATIM inside the subshell
  gotcha: split every local capture (SC2155); `pool_lease_field` returns 1 on corrupt lease — always guard the capture

- file: lib/pool.sh
  why: pool_state_init (259-269) — placement anchor for the new helper; also ensures $POOL_LANES_DIR exists before the `8>` redirect opens
  gotcha: pool_boot_lane is only called after acquire, so the lanes dir exists; still, the redirect `8>"$POOL_LANES_DIR/N.boot.lock"` relies on that

- file: lib/pool.sh
  why: pool_lanes_list (1017) / pool_find_free_lane (1126-1135) / pool_reap_orphan_dirs (3131+) — glob-safety proof: *.boot.lock is invisible to all three
  pattern: cite in the helper docstring, no code change needed there

- file: lib/pool.sh
  why: curl aliveness probe idiom (line 1447): `curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1`
  gotcha: NEVER kill -0 (ESRCH/EPERM ambiguity — AGENTS.md §4)

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  why: §2a (helper) + §2c-boot paragraph ("wrap the whole pool_boot_lane body in the lane lock … post-lock lease re-read") + the "Why a new lock file" rationale
  section: "§2 BUG-002" (lines 42-118)

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  why: R4 spec (line 60): "second command DURING copy (before port write) → both succeed, ONE chrome launch"

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T2S1/PRP.md
  why: the harness CONTRACT this item consumes — fake chrome (FAKE_CHROME_DELAY, FAKE_CHROME_COUNT_FILE "pid port dir" lines), fake agent-browser, _bootrace_setup/_bootrace_teardown, single-setup runner, R3 known-red
  gotcha: call the setup AT MOST ONCE (AGENTS.md §4); run case bodies in the MAIN shell (no `( )` subshell bodies — EXIT-trap hazard)

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T1S1/PRP.md
  why: upstream contract — pool_copy_master becomes idempotent (rm -rf stale target before cp); the re-check + guarded copy together make re-boot safe
```

### Current Codebase tree (relevant slice)

```bash
lib/pool.sh          # the whole pool (bash); pool_boot_lane ~2616, pool_state_init 259
test/bootrace.sh     # created/extended by T1.S1 + T2.S1 (single-setup runner, fakes, R1-R3)
bin/agent-browser-pool  # wrapper CLI (UNTOUCHED by this item)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
lib/pool.sh          # MODIFIED: + pool_lane_boot_lock helper (near pool_state_init); pool_boot_lane wrapped
test/bootrace.sh     # MODIFIED: + R4 case function + summary line; nothing else
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: fd 9 / POOL_LOCK_FILE is RESERVED for pool_acquire_locked. A fresh OFD on it
#   from inside a waiter SELF-DEADLOCKS (lib/pool.sh:3250-3256). Use fd 8 on the NEW file.
# CRITICAL: `flock -w 20 8` returns rc 1 on TIMEOUT (and rc 0 on acquire). Under set -e,
#   an unguarded `flock -w 20 8` would ABORT the subshell → looks like success handling.
#   Pattern:
#     if ( flock -w 20 8; _pool_boot_lane_locked "$lane" ) 8>"$(pool_lane_boot_lock "$lane")"; then
#         return 0
#     else
#         rc=$?
#         if [[ $rc -eq 1 && <flock timed out> ]]; then <fallback unlocked>; fi
#     fi
#   Simplest robust split (recommended): extract the current body into
#   _pool_boot_lane_locked() (unchanged code, moved), then in pool_boot_lane:
#     local lock_rc
#     if ( flock -w 20 8 && _pool_boot_lane_locked "$lane" ) 8>"$(pool_lane_boot_lock "$lane")"; then
#         return 0
#     fi
#     lock_rc=$?
#     if (( lock_rc == 1 )) && ! ( flock -n 8 ) 8>"$(pool_lane_boot_lock "$lane")"; then
#         # timeout (peer still holds it) → fall back to current unlocked behavior
#         _pool_log "pool_boot_lane: boot lock busy for lane $lane; proceeding unlocked"
#         _pool_boot_lane_locked "$lane"; return $?
#     fi
#     return 1
#   (Distinguish timeout from body-rc-1 however you like — e.g. have the subshell
#   `exit 99` on flock timeout — as long as the timeout path NEVER hangs and the
#   body-rc-1 path still returns 1 to the caller.)
# CRITICAL: SC2155 — `local x; x="$(...)"` split for EVERY capture; `pool_lease_field`
#   returns 1 on corrupt/missing lease → always capture under `if !`.
# CRITICAL: never `kill -0` for aliveness (ESRCH vs EPERM) — use the curl probe.
# NOTE: `_pool_release_lane_internals` + `return 1` inside the flock SUBSHELL now
#   `return`s from `_pool_boot_lane_locked`, making the subshell exit 1 → propagates.
#   Verify no `exit` (vs `return`) sneaks into the moved body except pool_die (which
#   exits the subshell with rc 1 — same as today's process-level pool_die for the
#   caller: check the wrapper's pool_die behavior and keep it fatal-looking).
```

## Implementation Blueprint

### Data models and structure

No new data structures. One new filesystem artifact: `$POOL_LANES_DIR/<N>.boot.lock` (empty advisory-flock file; glob-safe; never cleaned).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD pool_lane_boot_lock helper to lib/pool.sh (near pool_state_init, ~line 275)
  - IMPLEMENT: |
      # pool_lane_boot_lock N — echo the per-lane boot/connect lock path (creates nothing).
      # ... docstring: fd-8 idiom; NEVER fd 9/POOL_LOCK_FILE (self-deadlock, see
      # pool_wait_for_lane note); glob-safe (pool_lanes_list globs *.json,
      # pool_find_free_lane tests n.json, pool_reap_orphan_dirs iterates ephemeral */);
      # stale files harmless (advisory flock on the open fd, not file age). Consumed by
      # pool_boot_lane (T2.S2) and pool_ensure_connected (T2.S3).
      pool_lane_boot_lock() { printf '%s\n' "$POOL_LANES_DIR/$1.boot.lock"; }
  - NAMING: pool_lane_boot_lock (matches pool_* helper naming)
  - PLACEMENT: immediately after pool_state_init (lib/pool.sh ~275)

Task 2: REFACTOR pool_boot_lane into _pool_boot_lane_locked (pure move)
  - IMPLEMENT: move the ENTIRE current body (steps a-f, all comments) into a new
    function `_pool_boot_lane_locked "$lane"` directly below pool_boot_lane; change
    NOTHING in the logic. pool_boot_lane becomes a thin wrapper (Task 3).
  - WHY first: keeps the diff reviewable; R1/R2/control must stay green after this move.

Task 3: WRAP pool_boot_lane in the per-lane lock with idempotent re-check + timeout fallback
  - IMPLEMENT (sketch — adapt, respect the gotchas above): |
      pool_boot_lane() {
          local lane="${1:-}" lock_rc port
          [[ "$lane" =~ ^[0-9]+$ ]] \
              || pool_die "pool_boot_lane: lane must be a non-negative integer, got: '$lane'"
          if ( flock -w 20 8 && _pool_boot_lane_locked "$lane" ) \
                  8>"$(pool_lane_boot_lock "$lane")"; then
              return 0
          fi
          lock_rc=$?
          if (( lock_rc == 1 )) && ! ( flock -n 8 ) 8>"$(pool_lane_boot_lock "$lane")"; then
              # peer still holds the lock after 20s — never hang the wrapper
              _pool_log "pool_boot_lane: boot lock busy >20s for lane $lane; proceeding unlocked"
              _pool_boot_lane_locked "$lane"
              return $?
          fi
          return "$lock_rc"
      }
  - GOTCHA: use a distinguishable exit code (e.g. subshell `exit 99` on flock timeout)
    instead of rc-1 + flock -n re-probe if cleaner — any scheme that (a) never hangs,
    (b) never misreports a genuine boot failure as timeout-fallback, (c) returns 1 to
    the caller on real failure.
  - IN _pool_boot_lane_locked, ADD the idempotent re-check AT THE TOP (inside the lock):
      local port
      if port="$(pool_lease_field "$lane" port 2>/dev/null)" \
         && [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
         && curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
          _pool_log "pool_boot_lane: lane $lane already booted (port=$port); skipping re-boot"
          return 0
      fi
    (Guarded capture — pool_lease_field rc 1 on corrupt lease MUST fall through to a
    normal boot, not abort.)
  - PRESERVE: every existing `if ! helper; then _pool_release_lane_internals "$lane"; return 1; fi`
    block; the port-exhaustion POOL_WAIT loop; the connected/last_seen_at finalize.

Task 4: ADD case R4 to test/bootrace.sh (consumes the T2.S1 harness — read its PRP)
  - IMPLEMENT: case function following the existing R3 pattern: extend/parametrize the
    fake-chrome COPY delay so the second command lands during the copy, before the port
    write. Options (pick what fits the harness): a `FAKE_CHROME_COPY_DELAY` knob via a
    slow `cp` in the master fixture, or make the master large enough that the real
    reflink cp takes >1s — DO NOT rely on real timing; the harness from S1 defines the
    knobs; if S1 shipped none for the copy phase, add `FAKE_CP_DELAY` support to the
    MASTER fixture creation (a hook the pool's cp can't see) OR block the copy
    deterministically (e.g. pre-create the target dir with a `crash-marker` and use
    T1.S1's idempotent-copy path). Keep it DETERMINISTIC: cmd A backgrounded, cmd B
    launched while A is provably pre-port (e.g. poll until $EPH/<N> exists, then fire B).
  - ASSERT (test_framework.md R4): both rc 0; `wc -l <"$FAKE_CHROME_COUNT_FILE"` == 1;
    no `master*` entry inside `$EPH/<N>` (no nesting); lease chrome_pid == the live fake
    chrome pid (parse from the count-file line or pgrep user-data-dir); named
    `R4:`-prefixed FAIL lines; per-case cleanup kills everything it spawned (trap-safe).
  - REGISTER: add R4 to the suite summary + the header's expected-state note
    (control PASS, R1/R2 PASS, R3 known-red until T2.S3, R4 PASS).
  - RUNNER: single `_bootrace_setup` call (AGENTS.md §4); case body in the MAIN shell.

Task 5: VALIDATE (see Validation Loop) — static checks + the bootrace suite in an
  isolated sandbox; confirm zero orphans.
```

### Implementation Patterns & Key Details

```bash
# The canonical lock idiom to mirror (pool_acquire_locked, lib/pool.sh:2415-2433) — on fd 8:
(
    flock -w 20 8          # bounded: peer holds ≤ copy + 15s CDP + margin
    _pool_boot_lane_locked "$lane"
) 8>"$(pool_lane_boot_lock "$lane")"
# subshell rc == body rc → caller sees 0/1; pool_die inside exits the SUBSHELL (lock
# released, rc propagates as today).

# In-lock idempotent re-check — ORDER MATTERS: it must run AFTER acquiring the lock,
# BEFORE pool_copy_master. This is what protects BOTH the concurrent loser AND the
# crash-recovery re-boot (lease stuck port=0 → falls through → guarded copy from T1.S1).
```

### Integration Points

```yaml
NO new config/env/API. Internal only.
DOWNSTREAM (do NOT implement here):
  - P1.M1.T2.S3: pool_ensure_connected takes the SAME lock on fd 8 via the SAME helper
    (connect and boot become mutually exclusive — that's what turns R3 green)
  - P1.M1.T2.S4: (3b) sweep widening in _pool_release_lane_internals — defense-in-depth
UPSTREAM:
  - P1.M1.T1.S1: idempotent pool_copy_master (re-boot of existing dir is safe)
  - P1.M1.T2.S1: test/bootrace.sh harness + R3 known-red case (R4 added by THIS item)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh
shellcheck -s bash -S warning lib/pool.sh
shellcheck -s bash -S warning test/bootrace.sh
# Expected: clean. SC2155/SC2086 must not appear in the new code.
```

### Level 2: Unit / Harness (Component Validation)

```bash
# Isolated sandbox run of the bootrace suite (it redirects HOME/state/ephemeral itself).
# AGENTS.md §1-§3: the suite must be run ONLY via its own isolated harness; never
# against the operator's real state. Bound it:
timeout 300 bash test/bootrace.sh; echo "suite rc=$?"
# Expected: control PASS, R1/R2 PASS, R4 PASS, R3 FAIL (known-red until T2.S3 — the
# suite's documented expected state for this subtask). Suite MAY exit 1 due to R3.
```

### Level 3: Integration (System Validation)

```bash
# Prove the lock actually serializes: run R4 with the count file and inspect manually
# if R4 fails — exactly-one-launch is the core assertion.
# Prove the timeout fallback: (optional micro-check) hold the lock manually
#   ( sleep 25 ) 8>"$POOL_LANES_DIR/1.boot.lock" & in the sandbox, then boot lane 1
#   with a bounded timeout — expect the _pool_log line and an unlocked-boot outcome,
#   never a hang. Static reasoning suffices if impractical to script.
# Zero-orphan sweep (AGENTS.md checklist):
pgrep -af 'fake-cdp|fake-agent-browser|user-data-dir=.*bootrace' || echo "clean"
```

### Level 4: Domain-Specific Validation

```bash
# Full repo regression (isolated sandbox, per AGENTS.md): the 4 existing suites must
# stay green (the refactor moved pool_boot_lane's body — copy/connect paths must be
# behavior-identical). Run only inside the suite framework's own isolated temp trees:
for s in concurrency release_reaper transparency validate; do
    timeout 600 bash "test/$s.sh" || echo "SUITE $s FAILED"
done
# Expected: all green (these suites already isolate themselves).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` + `shellcheck` clean on lib/pool.sh and test/bootrace.sh
- [ ] `test/bootrace.sh`: control, R1, R2 PASS; R4 PASS; R3 documented known-red (until T2.S3)
- [ ] 4 existing repo suites green in isolated sandbox
- [ ] Zero orphan processes / temp trees after every run (`pgrep -af` sweep)

### Feature Validation

- [ ] `pool_lane_boot_lock` echoes the path, creates nothing, sits near `pool_state_init` with the full docstring
- [ ] fd 8 used exclusively; NO new open of `POOL_LOCK_FILE` anywhere
- [ ] `flock -w 20` timeout → `_pool_log` + unlocked fallback (wrapper never hangs)
- [ ] In-lock re-check: port>0 + curl `/json/version` answers → return 0, no copy, no launch
- [ ] Recoverable failures still `_pool_release_lane_internals` + return 1; pool_die still fatal to the caller
- [ ] R4: both cmds rc 0, exactly ONE launch, no nesting, lease ids match the live chrome

### Code Quality Validation

- [ ] Moved body is a VERBATIM move (reviewable diff) — only the re-check added
- [ ] All captures split (SC2155); all rc-1 helpers guarded (set -e safe)
- [ ] No changes outside `pool_lane_boot_lock` + `pool_boot_lane` (+ R4 in the test file)

### Documentation & Deployment

- [ ] Helper docstring covers: contract, fd choice, deadlock hazard, glob-safety, stale-file harmlessness, consumers (T2.S3)
- [ ] test/bootrace.sh header expected-state note updated (R4 now PASS)

## Anti-Patterns to Avoid

- ❌ Do NOT open fd 9 / POOL_LOCK_FILE from the boot path (self-deadlock)
- ❌ Do NOT use an unbounded `flock 8` — the wrapper must never hang
- ❌ Do NOT let a `flock -w` timeout look identical to a body failure (distinguish them)
- ❌ Do NOT re-check the lease BEFORE acquiring the lock (defeats the purpose)
- ❌ Do NOT touch `pool_ensure_connected` or `_pool_release_lane_internals` (T2.S3/S4 own them)
- ❌ Do NOT rely on `kill -0` or on real-timing sleeps in the R4 test (use the harness knobs / deterministic poll)
- ❌ Do NOT call `_bootrace_setup` more than once; do NOT run case bodies in `( )` subshells

## Confidence Score

**8/10** — the design (fix_design §2a/§2c-boot) is explicit and the codebase idiom to mirror exists; the two risk points are (1) cleanly distinguishing flock-timeout from body-failure rc under `set -e`, and (2) making R4's "second command during copy" deterministic given the harness knobs shipped by the still-in-flight T2.S1 — both mitigated with explicit patterns above.