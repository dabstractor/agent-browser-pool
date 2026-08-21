# PRP — P1.M1.T2.S3: `pool_ensure_connected` — lock the connect/relaunch path, re-read lease under lock, verify recorded chrome pid is dead before relaunching

> **Bugfix context**: This is the **terminal fix of the BUG-002 chain** (Major —
> same-owner boot race, PRD h2.2/h3.1/h2.5). It takes the SAME per-lane boot lock
> introduced by **P1.M1.T2.S2** (`pool_lane_boot_lock N` + the fd-8 `flock -w 20`
> idiom wrapping `pool_boot_lane` — read that PRP first; treat it as a hard contract,
> it may still be landing in parallel) and applies it to the MUTATIVE portion of
> `pool_ensure_connected` (lib/pool.sh ~2744-2880), adds a post-lock lease re-read and
> a **dead-pid verification gate** before any relaunch. This is what turns the
> known-red **R3** case in `test/bootrace.sh` GREEN. Downstream: **P1.M1.T3.S1**
> (integration gate runs R1–R4 + all repo suites) consumes this; no downstream code
> consumer — behavior only.

## Goal

**Feature Goal**: `pool_ensure_connected` becomes race-free: a second same-owner command that arrives while the lane's Chrome is merely still booting (CDP port not open YET) must (a) serialize against the in-flight boot/connect on the lane's boot lock, (b) re-read the lease under the lock and take the reconnect path if the peer finished, (c) NEVER relaunch a Chrome whose recorded pid is still alive, and (d) never hang the wrapper (bounded `flock -w 20`, timeout → best-effort current behavior + `_pool_log`).

**Deliverable**:
1. `lib/pool.sh` — `pool_ensure_connected` restructured: the fast path (connected==true && `pool_daemon_connected` → heartbeat + return 0) stays LOCK-FREE (hot path, read-only); everything from the curl `/json/version` probe through the relaunch success path runs inside `( flock -w 20 8; … ) 8>"$(pool_lane_boot_lock "$lane")"` with (a) an in-lock lease RE-READ, (b) a `/proc/<chrome_pid>` dead-pid gate before relaunch, (c) a bounded "alive but CDP not up yet" wait-and-rebind path instead of relaunch.
2. `test/bootrace.sh` — flip the header KNOWN-RED note: `r3_bug002_race_e2e` is now expected PASS (update only the comment/expected-state; the case itself is unchanged — it already exists from T2.S1). No new cases required (R3's four assertions ARE the acceptance gate), though optional extra asserts are fine if deterministic.
3. No doc changes (internal behavior; PRD §2.16 same-browser semantics are restored, not changed).

**Success Definition**:
- `bash -n lib/pool.sh` / `test/bootrace.sh` and `shellcheck -s bash -S warning` clean on both.
- Isolated-sandbox run of `test/bootrace.sh` (timeout 300): control, R1, R2, R3-control, **R3 (now green)**, and R4 (added by T2.S2) ALL PASS — suite exit 0.
- R3's four assertions each hold: cmd B rc=0; exactly 1 line in `$FAKE_CHROME_COUNT_FILE`; lease `chrome_pid` is live and matches the launched pid; `release all` leaves zero `user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT` processes and no lane dir.
- The 4 existing repo suites (`concurrency`, `release_reaper`, `transparency`, `validate`) stay green — all pre-existing return-1/pool_die/never-drop-lane semantics preserved.
- Zero orphan processes after every run.

## User Persona

**Target User**: The implementation gate P1.M1.T3.S1 (runs the full matrix) and any agent issuing parallel pool tool calls (pi supports parallel tool calls — the exact trigger).

**Use Case**: Agent runs `open about:blank` (cmd A) and, 0.8s later while Chrome's CDP listener is still in its 4s startup delay, `get cdp-url` (cmd B). B must succeed against the SAME Chrome A booted.

**User Journey**: B enters `pool_ensure_connected` (port>0, connected=false) → fast path misses → acquires the lane boot lock (A's boot already released it, or B waits ≤20s for A's `pool_wait_cdp`) → re-reads lease → curl now succeeds → `pool_daemon_connect` rebinds → heartbeat → return 0. Exactly one Chrome ever launched; lease ids point at the live one.

**Pain Points Addressed** (PRD h3.1): spurious 'lane N not connected; aborting'; duplicate Chrome; lease `chrome_pid`/`chrome_pgid` clobbered to the doomed second chrome; real Chrome surviving `release all` with a deleted user-data-dir (AGENTS.md §3 leak).

## Why

- Today `pool_ensure_connected` is lock-free and treats ANY curl failure on the CDP probe as "Chrome dead" → relaunch. During the boot window (copy + port write + up to 15s CDP wait) curl fails while the FIRST chrome is perfectly alive — the misdiagnosis that causes every symptom above.
- `pool_boot_lane` (T2.S2) is now serialized under `$POOL_LANES_DIR/<N>.boot.lock` on fd 8, but the reuse path (lease already port>0) never enters `pool_boot_lane` — it goes straight to `pool_ensure_connected`. Without this item the lock doesn't cover the race R3 reproduces.
- PRD h2.5 recommendation verbatim: "have ensure_connected verify the recorded chrome pid is actually dead before relaunching".

## What

### Success Criteria

- [ ] Fast path (b: `connected==true && pool_daemon_connected` → `last_seen_at` + return 0) is UNCHANGED and LOCK-FREE (no flock open on the happy connected path).
- [ ] The curl probe, identity gate, reconnect, Singleton strip, `pool_chrome_launch`, early chrome-id write, `pool_wait_cdp`, and `pool_daemon_connect` ALL execute inside the fd-8 lane-lock subshell.
- [ ] Under the lock, the lease is RE-READ before any decision: if `connected==true` and `pool_daemon_connected` → heartbeat + return 0; if curl now answers (and `pool_cdp_is_ours` passes when pid>0) → reconnect path + return 0. A peer's completed boot must never be relaunched over.
- [ ] Dead-pid gate: relaunch (`pool_chrome_launch`) happens ONLY if the lease's `chrome_pid` is confirmed dead — `[[ ! -e /proc/$chrome_pid ]]` (NEVER `kill -0` — ESRCH/EPERM ambiguity, AGENTS.md §4) — or pid<=0 AND no `pgrep -f` match on `user-data-dir=$ephemeral_dir`. If `/proc/$chrome_pid` exists (alive, still booting): do NOT relaunch; wait bounded for CDP (reuse the `pool_wait_cdp` 15s budget, e.g. call `pool_wait_cdp "$port" "$ephemeral_dir" "$chrome_pid"` directly), then `pool_daemon_connect` → connected/last_seen_at updates → return 0; if wait_cdp times out → connected:false + last_seen_at + return 1 (existing semantics).
- [ ] `flock -w 20` timeout → `_pool_log` + best-effort current (pre-fix) branch behavior; NEVER hang. Timeout must be distinguishable from a genuine failure rc (T2.S2's exit-code scheme is the pattern).
- [ ] The early chrome-id write (relaunch branch, ~2847-2849) is KEPT — it is now race-free (only one process at a time in the relaunch branch).
- [ ] Subshell-locality handled: `POOL_CHROME_PID`/`POOL_CHROME_PGID` set by `pool_chrome_launch` inside the subshell are subshell-local — verify no caller consumes them after `pool_ensure_connected` returns (today they don't; grep to confirm), and the lease (authoritative store) carries ids outward.
- [ ] All pre-existing semantics preserved: return 1 (never `pool_die`) on every soft failure; never drops the lane; `pool_die` from `pool_chrome_launch` still fatal-looking to the caller (exits the subshell, rc propagates — same as T2.S2's analysis); `last_seen_at` touched on EVERY path.
- [ ] `test/bootrace.sh` header updated: R3 no longer KNOWN-RED; suite expected exit 0 with all cases passing.

## All Needed Context

### Context Completeness Check

If someone knew nothing about this codebase: they need the current body of `pool_ensure_connected` (steps a–e with all guards — read it in full, lib/pool.sh ~2744-2880), the fd-8 lock idiom and helper from T2.S2, the harness contract from T2.S1, and `pool_wait_cdp`'s identity-kill contract. All referenced below.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: pool_ensure_connected (~2744-2880) — THE function being changed; extensive inline docstring (caller contract, GOTCHAs, heartbeat rule)
  pattern: steps a (lease read, one jq fork) → b (fast path, lock-free) → c (curl probe + pool_cdp_is_ours identity gate + pool_daemon_connect reconnect) → e (relaunch: Singleton strip, pool_chrome_launch, early chrome-id write, pool_wait_cdp, pool_daemon_connect, finalize)
  gotcha: default connected=true for leases lacking the field; jq -r absent field → literal `null` (coalesce); chrome_pid coalesced to 0; `[[ ]] && probe` errexit-exempt idioms

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T2S2/PRP.md
  why: THE upstream contract — pool_lane_boot_lock helper (near pool_state_init, ~line 275), the `( flock -w 20 8 && body ) 8>"$(pool_lane_boot_lock "$lane")"` idiom, timeout-distinguishable exit codes, fd-8-only rule (fd 9/acquire.lock SELF-DEADLOCKS, lib/pool.sh ~3250-3256)
  pattern: mirror T2.S2's wrapper structure (thin wrapper + `_…_locked` body extraction + timeout fallback)
  gotcha: use the SAME lock FILE and SAME fd 8 — boot and connect must be mutually exclusive; do NOT invent a second lock file

- file: test/bootrace.sh
  why: the harness this item makes green — r3_bug002_race_e2e (case code at ~261-306), r3_control_delayed_boot_succeeds green gate, _bootrace_setup/_br_teardown single-setup contract, FAKE_CHROME_DELAY / FAKE_CHROME_COUNT_FILE knobs, KNOWN-RED header note to update (~lines 36-38)
  pattern: case bodies run in the MAIN shell; snapshot-then-clean-then-assert; every subprocess under `timeout`
  gotcha: NEVER call _bootrace_setup more than once (AGENTS.md §4); EXIT trap guards on BR_TEARDOWN_FINAL

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  why: §2b (this exact fix, with the wrap-from-curl-probe scope, re-read-under-lock, /proc/<pid> gate, alive-→-wait-+-rebind path, flock -w ≥ CDP budget + margin) and §2c-boot paragraph (composition narrative)
  section: "## §2 BUG-002" — specifically "### 2b"

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: §6 — pool_ensure_connected contract context, wrapper pool_die propagation
  section: "§6"

- file: lib/pool.sh
  why: pool_wait_cdp (~1813-1895) — the bounded CDP wait you REUSE for the "alive but not up yet" path; POOL_CDP_TRIES=30 × 0.5s = 15s budget; identity check via pool_cdp_is_ours; KILLS THE PGROUP on timeout before returning 1
  pattern: `pool_wait_cdp "$port" "$ephemeral_dir" "$chrome_pid"` — third arg enables the identity loop
  gotcha: if wait_cdp kills the pgroup on timeout the chrome it killed is the LIVE one only if identity matched; a mismatched answerer loops to timeout — that's fine, return 1 per existing semantics

- file: lib/pool.sh
  why: pool_cdp_is_ours (~1733) PORT DIR PID — non-fatal identity gate (returns 1, never pool_die); pool_daemon_connect (~1897) SESSION PORT → rc 1 on failure; pool_daemon_connected (~1955) SESSION PORT probe; pool_lease_read/update/field (~813-900) — the lease helpers (pool_lease_field returns 1 on corrupt → guard captures)
  gotcha: all captures split (SC2155); every rc-1 helper guarded under set -e

- file: lib/pool.sh
  why: pool_chrome_launch (~1538-1650) — sets POOL_CHROME_PID/PGID via `declare -g`; pool_die's on instant exit (FATAL, propagates)
  gotcha: globals set inside your flock SUBSHELL are subshell-local; the ids reach the outside world via pool_lease_update (already the case in the early-write block)

- file: lib/pool.sh
  why: pool_acquire_locked idiom (~2415-2433) and pool_wait_for_lane fd-9 deadlock note (~3240-3256)
  pattern: canonical flock subshell; NEVER a fresh OFD on POOL_LOCK_FILE

- file: bin/agent-browser-pool
  why: the wrapper that calls ensure_connected and surfaces 'lane N not connected; aborting' — confirm NO wrapper code consumes POOL_CHROME_PID after the call (grep it), and that pool_die rc propagation stays fatal-looking
```

### Current Codebase tree (relevant slice)

```bash
lib/pool.sh              # pool_ensure_connected ~2744-2880 (being restructured); pool_lane_boot_lock ~275 (from T2.S2); pool_wait_cdp ~1813; pool_chrome_launch ~1538
test/bootrace.sh         # harness with r3_control (green gate) + r3_bug002_race_e2e (KNOWN-RED → this item flips it)
bin/agent-browser-pool   # wrapper (UNTOUCHED)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
lib/pool.sh              # MODIFIED: pool_ensure_connected — lock-free fast path + locked mutative section (+ optional _pool_ensure_connected_locked body extraction); docstring updated
test/bootrace.sh         # MODIFIED: header expected-state note only (R3 now PASS); no case-logic changes required
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: SAME lock file, SAME fd 8 as pool_boot_lane (T2.S2). A second lock file or
#   fd 9 (POOL_LOCK_FILE) breaks mutual exclusion or self-deadlocks (lib/pool.sh ~3250-3256).
# CRITICAL: `flock -w 20 8` rc 1 on TIMEOUT. Under set -e an unguarded call ABORTS the
#   subshell (looks like handled success). Distinguish timeout from body failure (T2.S2
#   uses a sentinel exit code, e.g. subshell `exit 99` on flock timeout) — timeout →
#   _pool_log + best-effor current-branch behavior, never a hang, never a false success.
# CRITICAL: NEVER kill -0 for liveness — ESRCH (dead) and EPERM (foreign-alive) are
#   indistinguishable. Use `[[ -e /proc/$pid ]]` (AGENTS.md §4).
# CRITICAL: SC2155 — split every `local x; x="$(...)"`; pool_lease_field/pool_lease_read
#   return 1 on corrupt/missing lease → capture under `if !`.
# CRITICAL: pool_wait_cdp KILLS the pgroup on timeout before returning 1 — if you call it
#   against the live first chrome's pid and it times out, verify whether the kill targets
#   the identity-matched pid (it does: identity loop kills only on mismatch of ANSWERER vs
#   expected pid — read pool_wait_cdp 1795-1860 before relying on this).
# NOTE: POOL_CHROME_PID/PGID set inside the flock subshell are subshell-local. They are
#   consumed only within the same scope today (early lease write + wait_cdp arg + log
#   line). GREP to confirm nothing after pool_ensure_connected's return reads them; if a
#   value must escape, echo it through the lease (authoritative store), not globals.
# NOTE: the fast path (step b) MUST stay lock-free: it runs on EVERY driving command;
#   opening a lock file there would add an open+flock syscall to the hot path and could
#   serialize healthy concurrent commands. Only the post-fast-path mutative section locks.
# NOTE: subshell wrapping means `return 1` inside the body must become the SUBSHELL's
#   exit status → wrapper maps it to `return 1`. pool_die inside still exits the subshell
#   with its fatal rc — verify propagation matches today's process-level behavior.
```

## Implementation Blueprint

### Data models and structure

None — no new files, config, or schema. Uses the existing `$POOL_LANES_DIR/<N>.boot.lock` from T2.S2.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the contracts
  - READ lib/pool.sh pool_ensure_connected (~2744-2880) IN FULL, pool_wait_cdp (~1795-1895),
    pool_cdp_is_ours, pool_chrome_launch docstring, and pool_lane_boot_lock + the wrapped
    pool_boot_lane from T2.S2 (if not yet landed, implement against its PRP contract).
  - GREP: `grep -n 'POOL_CHROME_PID' lib/pool.sh bin/*` — confirm the globals are not
    consumed after pool_ensure_connected returns.

Task 1: REFACTOR pool_ensure_connected into wrapper + _pool_ensure_connected_locked (pure move)
  - MOVE steps c (curl probe) through e (relaunch finalize) VERBATIM into
    `_pool_ensure_connected_locked "$lane"` (re-reading its own fields — see Task 2).
    Keep step a (lease read/validate) and step b (fast path) in the LOCK-FREE wrapper.
  - WRAPPER shape (mirrors T2.S2):
      pool_ensure_connected() {
          <validate lane; read lease; port gate; fast path — UNCHANGED, lock-free>
          # mutative section under the SAME lane lock as pool_boot_lane
          if ( flock -w 20 8 && _pool_ensure_connected_locked "$lane" ) \
                  8>"$(pool_lane_boot_lock "$lane")"; then
              return 0
          fi
          local lock_rc=$?
          if (( lock_rc == 99 )); then   # sentinel: flock timed out (T2.S2 scheme)
              _pool_log "pool_ensure_connected: lane $lane boot lock busy >20s; proceeding unlocked (best effort)"
              _pool_ensure_connected_locked "$lane"   # current pre-fix behavior, bounded by its own budgets
              return $?
          fi
          return 1
      }
    (Adapt the sentinel/detection scheme to whatever T2.S2 actually shipped — the
    requirements are: never hang, never misreport failure as timeout, return 1 on
    genuine failure.)
  - GOTCHA: `_pool_ensure_connected_locked` must RE-READ the lease itself (Task 2) — do
    not pass pre-lock field values in, they are stale by definition.

Task 2: IN-LOCK LEASE RE-READ + fast-path/curl re-check at the top of _pool_ensure_connected_locked
  - IMPLEMENT (at function top): |
      # RE-READ the lease under the lock (peer boot may now be complete).
      local json session port ephemeral_dir connected chrome_pid now
      if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
          _pool_log "pool_ensure_connected: lease vanished for lane $lane"
          return 1
      fi
      mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected, .chrome_pid' <<<"$json")
      <same field normalization as step a — including the `null`/empty coalescing>
      <port>0 gate; defensive session/ephemeral_dir reconstruct — same as step a>
  - THEN re-run the SAME fast-path check (connected==true && pool_daemon_connected →
    heartbeat + return 0) and the SAME curl-probe reconnect block (curl + pool_cdp_is_ours
    + pool_daemon_connect → connected/last_seen_at + return 0). Reuse code (extract small
    local helpers or duplicate the guarded blocks — keep it readable, shellcheck clean).
  - WHY: a peer's boot may have completed while we waited on the lock — relaunching over
    it is the exact BUG-002 symptom.

Task 3: DEAD-PID GATE before the relaunch branch
  - IMPLEMENT (in _pool_ensure_connected_locked, after the re-checked curl block fails): |
      # BUG-002: verify the recorded chrome pid is ACTUALLY DEAD before relaunching.
      # /proc existence, NEVER kill -0 (ESRCH/EPERM ambiguity — AGENTS.md §4).
      if [[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 && -e "/proc/$chrome_pid" ]]; then
          # Chrome ALIVE — CDP merely not open yet (peer boot / slow start). Wait bounded,
          # then rebind. NEVER relaunch.
          if pool_wait_cdp "$port" "$ephemeral_dir" "$chrome_pid"; then
              if pool_daemon_connect "$session" "$port"; then
                  pool_lease_update "$lane" connected true
                  pool_lease_update "$lane" last_seen_at "$now"
                  _pool_log "pool_ensure_connected: lane $lane waited for live chrome pid=$chrome_pid; reconnected"
                  return 0
              fi
              pool_lease_update "$lane" connected false
              pool_lease_update "$lane" last_seen_at "$now"
              return 1
          fi
          # wait_cdp timeout (its identity kill only ever targets a mismatched answerer;
          # our pid was /proc-alive at gate time) — soft fail, existing semantics.
          _pool_log "pool_ensure_connected: lane $lane chrome pid=$chrome_pid alive but CDP never opened"
          pool_lease_update "$lane" connected false
          pool_lease_update "$lane" last_seen_at "$now"
          return 1
      fi
      # pid<=0: only relaunch if NOTHING matches our user-data-dir on the cmdline.
      if [[ "$chrome_pid" -le 0 ]] \
         && pgrep -f -- "user-data-dir=$ephemeral_dir( |$)" >/dev/null 2>&1; then
          <same alive-wait-and-rebind block, or wait_cdp with empty pid arg + connect>
      fi
      # confirmed dead (or pid<=0 with no cmdline match) → proceed to the EXISTING
      # relaunch block (Singleton strip → pool_chrome_launch → early chrome-id write →
      # pool_wait_cdp → pool_daemon_connect → finalize), VERBATIM.
  - GOTCHA: `pgrep -f` rc 1 when no match — guard with `if` (errexit). Anchor the pattern.
  - NOTE: `now="$(_pool_now)"` recompute inside the locked body.

Task 4: UPDATE pool_ensure_connected's docstring
  - DOCUMENT: the lock-free fast path; the locked mutative section (same lock as
    pool_boot_lane — boot/connect mutual exclusion); the re-read-under-lock; the
    dead-pid gate; the timeout fallback; subshell-locality of POOL_CHROME_PID/PGID
    (lease is the authoritative outward channel).

Task 5: UPDATE test/bootrace.sh header only
  - CHANGE the KNOWN-RED note (~lines 36-38): r3_bug002_race_e2e is now EXPECTED PASS
    after T2.S2 + T2.S3; suite exit 0. Do NOT modify r3_bug002_race_e2e's logic (its
    four assertions are the acceptance gate). Optionally strengthen asserts ONLY if
    deterministic (e.g. also assert cmd A's rc==0).

Task 6: VALIDATE (see Validation Loop) — static checks, bootrace suite green in an
  isolated sandbox, repo suites green, zero-orphan sweep.
```

### Implementation Patterns & Key Details

```bash
# The locked mutative section — canonical shape (mirrors pool_boot_lane post-T2.S2):
(
    flock -w 20 8 || exit 99          # sentinel for timeout; body rc propagates otherwise
    _pool_ensure_connected_locked "$lane"
) 8>"$(pool_lane_boot_lock "$lane")"
# wrapper maps rc 99 → _pool_log + unlocked best-effort; rc 0 → return 0; else return 1.

# In-lock ORDER (critical):
#   1. re-read lease (normalize fields exactly like step a)
#   2. fast-path re-check (connected && daemon_connected → 0)
#   3. curl probe → pool_cdp_is_ours → pool_daemon_connect reconnect → 0
#   4. dead-pid gate (/proc/<pid>) → alive: bounded wait_cdp + rebind → 0/1
#   5. relaunch block (verbatim existing code)
# Steps 2-3 are what fix the R3 race; step 4 is the PRD h2.5 belt-and-suspenders for a
# peer chrome that is up as a process but whose CDP listener dies permanently.
```

### Integration Points

```yaml
NO new config/env/API/files. Internal only.
UPSTREAM (do NOT reimplement): pool_lane_boot_lock + fd-8 idiom + timeout sentinel scheme (T2.S2);
  harness knobs FAKE_CHROME_DELAY / FAKE_CHROME_COUNT_FILE (T2.S1).
DOWNSTREAM: P1.M1.T3.S1 runs R1-R4 + repo suites — this item must leave the suite exit 0.
  T2.S4 (release sweep widening) is defense-in-depth BEHIND this item — do not implement it here.
DO NOT TOUCH: pool_boot_lane (T2.S2 owns), _pool_release_lane_internals (T2.S4 owns),
  bin/agent-browser-pool, PRD.md, tasks.json.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh
shellcheck -s bash -S warning lib/pool.sh
shellcheck -s bash -S warning test/bootrace.sh
# Expected: clean; no SC2155/SC2086 in new code.
```

### Level 2: Harness (Component Validation)

```bash
# Isolated-sandbox suite (it redirects HOME/state/ephemeral itself; single setup).
timeout 300 bash test/bootrace.sh; echo "suite rc=$?"
# Expected: rc=0, ALL cases PASS — control, R1, R2, R3-control, r3_bug002_race_e2e (NOW
# GREEN), R4 (from T2.S2). This is the acceptance gate for this item.
# If R3 fails: inspect the count file + lease chrome_pid + the _pool_log lines to see
# which in-lock step misfired (order bug vs lock-not-taken vs gate inverted).
```

### Level 3: Integration / Behavior Checks (System Validation)

```bash
# Repo regression — ONLY inside each suite's own isolated temp trees (AGENTS.md §1):
for s in concurrency release_reaper transparency validate; do
    timeout 600 bash "test/$s.sh" || echo "SUITE $s FAILED"
done
# Expected: all green (ensure_connected's external contract is unchanged: same rc
# semantics, same lease writes, heartbeat on every path).

# Dead-pid gate micro-reasoning (script only if cheap+deterministic): a lease whose
# chrome_pid points at a LIVE unrelated process (e.g. the suite's own sleep) with curl
# dead → must take the wait-and-fail path, never launch a second chrome.
# Optional static check: grep the new code for 'kill -0' — must be ABSENT.
grep -n 'kill -0' lib/pool.sh   # expect: no hits in the ensure_connected section

# Zero-orphan sweep (AGENTS.md checklist):
pgrep -af 'fake-cdp|fake-agent-browser|user-data-dir=.*bootrace' || echo "clean"
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Lock-timeout path (optional, only if deterministic): in the sandbox, hold the lane
# lock >20s (( sleep 25 ) 8>"$POOL_LANES_DIR/1.boot.lock" &) then drive a lane — expect
# the _pool_log 'boot lock busy' line and a bounded outcome, never a hang. Static
# reasoning from the T2.S2-verified pattern suffices if scripting is fragile.
# Confirm the hot path stays lock-free: strace not required — code review: no `8>`
# redirect before the fast-path return 0.
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` + `shellcheck -S warning` clean on lib/pool.sh and test/bootrace.sh
- [ ] `timeout 300 bash test/bootrace.sh` → rc 0, ALL cases pass (R3 GREEN)
- [ ] 4 repo suites green in isolated sandbox
- [ ] Zero orphan processes / temp trees (`pgrep -af` sweep)

### Feature Validation

- [ ] Fast path lock-free and unchanged; heartbeat on every path
- [ ] Mutative section (curl probe → relaunch finalize) under the SAME fd-8 lock as `pool_boot_lane`
- [ ] Lease RE-READ under lock; peer-completed boot → reconnect/return 0, never relaunch
- [ ] Dead-pid gate: `/proc/<pid>` (never `kill -0`); alive → bounded `pool_wait_cdp` + rebind; only confirmed-dead relaunches
- [ ] pid<=0 + cmdline match on `user-data-dir=$dir` also treated as alive (no relaunch)
- [ ] `flock -w 20` timeout → `_pool_log` + best-effort, never a hang, timeout ≠ failure
- [ ] All return-1 semantics, never-pool_die, never-drop-lane rules preserved; `pool_die` still fatal-looking
- [ ] Early chrome-id write kept (now race-free); lease is the outward id channel (globals subshell-local — verified unused after return)

### Code Quality Validation

- [ ] Moved relaunch block is VERBATIM (reviewable diff); docstring updated with the new contract
- [ ] All captures split (SC2155); all rc-1 helpers guarded under `set -e`
- [ ] No changes outside `pool_ensure_connected` (+ `_pool_ensure_connected_locked`) and the test header note

### Documentation & Deployment

- [ ] Docstring covers: lock scope, re-read, dead-pid gate, timeout fallback, subshell-local globals
- [ ] test/bootrace.sh header: R3 no longer KNOWN-RED
- [ ] No README/skill changes (deferred to P1.M3.T2.S1 if warranted)

## Anti-Patterns to Avoid

- ❌ Do NOT lock the fast path / hot path (healthy commands must stay lock-free)
- ❌ Do NOT create a second lock file or use fd 9 / POOL_LOCK_FILE (self-deadlock)
- ❌ Do NOT use `kill -0` for liveness
- ❌ Do NOT relaunch while `/proc/<chrome_pid>` exists
- ❌ Do NOT pass pre-lock lease fields into the locked body — re-read inside
- ❌ Do NOT let a flock timeout look like success or like a genuine body failure
- ❌ Do NOT touch pool_boot_lane / _pool_release_lane_internals / the wrapper (sibling items own them)
- ❌ Do NOT modify r3_bug002_race_e2e's case logic (only the expected-state header)
- ❌ Do NOT call `_bootrace_setup` more than once; case bodies in the MAIN shell
- ❌ Do NOT rely on `POOL_CHROME_PID` escaping the flock subshell — the lease is the store

## Confidence Score

**8/10** — high: the fix design (§2b) is fully specified, the lock idiom is contracted by T2.S2, and the acceptance test (R3) already exists and encodes the exact four failure symptoms. Residual risk: T2.S2 is landing in parallel (interface drift in its timeout-sentinel scheme must be reconciled at implementation time), and the alive-wait path's interaction with `pool_wait_cdp`'s identity-kill needs the implementer to read pool_wait_cdp 1795-1860 carefully before relying on it.