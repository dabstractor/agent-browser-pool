name: "P1.M1.T2.S4 — widen the (3b) mid-boot cmdline sweep in _pool_release_lane_internals so positive-but-dead ids cannot leak a live Chrome"
description: >
  BUG-002 leak-class hardening (PRD h2.2/h3.1/h2.5, fix_design.md §2c): the release
  kernel's (3b) cmdline sweep fires only when BOTH recorded chrome ids are
  non-numeric/<=0; a positive-but-DEAD id (the clobber state from the same-owner boot
  race) defeats it — pool_chrome_kill on dead ids is a no-op and the rm -rf leaves a
  LIVE Chrome running on a deleted user-data-dir. Widen the gate so the anchored
  cmdline sweep runs whenever the id-based kill cannot be trusted. Post-condition of
  P1.M1.T2 (S2/S3 serialize the race; S4 makes release leak-proof even if the lease
  ids lie). Consumed by P1.M1.T3.S1 (integration gate).

---

## Goal

**Feature Goal**: `_pool_release_lane_internals` must never leave a live Chrome process
running on a removed ephemeral dir, even when the lease's `chrome_pid`/`chrome_pgid`
are positive-but-dead (or foreign). The (3b) cmdline sweep becomes a fallback that
fires whenever the recorded ids cannot be trusted to have identified the real Chrome —
not only when both ids are <=0/non-numeric.

**Deliverable**:
1. `lib/pool.sh` — the (3b) block (~lines 2083-2101, after `pool_chrome_kill` at ~2135
   in current numbering; find it by the comment `# (3b) MID-BOOT KILL RACE fallback`)
   with its `both-ids-<=0` precondition replaced by an "ids not confirmed
   alive-and-matching" gate. The anchored pattern `user-data-dir=$dir( |$)`, the
   `pgrep` guard (no match → no kill), and the `pkill` → `sleep 0.2` → `pkill -9`
   escalation stay VERBATIM. Updated block comment explaining the widened gate.
2. `test/bootrace.sh` — one NEW case `r3_neg_dead_ids_release_still_kills` (registered
   in the suite list like `r3_bug002_race_e2e`): a deterministic negative-control that
   manually writes dead-but-positive ids into the lease, spawns a live fake chrome on
   that lane dir, runs `release all`, and asserts the live fake is dead. Known-RED on
   current code, GREEN only with the fix. The existing R3 survivor assertion
   (`pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT"` empty after release)
   already covers the e2e path — do not duplicate it.

**Success Definition**: with the widened gate, `bash -n` + `shellcheck -s bash` clean on
both files; the new negative-control case passes; the full `test/bootrace.sh` suite
(R1-R4 + controls) passes in an isolated sandbox; zero orphaned fake-chrome processes
after the run (`pgrep -af user-data-dir=` → none). S4 depends on NO in-flight work —
it is a self-contained gate change in the release kernel — but it composes with
P1.M1.T2.S2 (done: `pool_lane_boot_lock` + serialized boot) and T2.S3 (in flight:
`pool_ensure_connected` hardening) which make the trigger rare; S4 is the
defense-in-depth backstop per fix_design.md §2c.

## User Persona (if applicable)

**Target User**: AI agent driving pooled Chrome via `agent-browser-pool` (and the
operator whose machine hosts the pool).

**Use Case**: Any `release`/`reap`/release-all path executing
`_pool_release_lane_internals` on a lane whose lease ids were clobbered (BUG-002 race
before S2/S3 land, or any future id corruption).

**User Journey**: lane released → kernel kills by ids → ids dead (no-op) → widened
sweep detects a live process on `user-data-dir=$dir` → pkill escalation → rm -rf →
zero leaked Chrome.

**Pain Points Addressed**: leaked Chrome on a deleted user-data-dir (unbounded zombie
browsers, sandbox wedge risk, AGENTS.md §3 violation).

## Why

- PRD h2.3/h3.1 (BUG-002): "a later `release all` kills by those dead ids (no-op) and
  rm -rf's the dir — leaving the REAL Chrome running with a deleted user-data-dir
  (leaked pid observed)" and "The (3b) MID-BOOT cmdline sweep … only fires when BOTH
  ids are <=0/non-numeric, so a positive-but-dead id defeats it — the exact leak class
  it was meant to close."
- PRD h2.5 recommendation: "widen the (3b) cmdline sweep to fire when the recorded
  ids are dead (not only <=0)".
- Goal 4 (guaranteed cleanup) + AGENTS.md §3 (never leak processes).

## What

The release kernel's step (3b) becomes: after `pool_chrome_kill "$chrome_pid"
"$chrome_pgid"`, run the anchored cmdline sweep UNLESS the recorded `chrome_pid` is
confirmed alive-and-matching — i.e. numeric >0 AND `/proc/$chrome_pid` exists AND the
pid's cmdline contains `user-data-dir=$dir`. In every other state (ids <=0 /
non-numeric, `/proc` gone = recorded id dead, or alive-but-mismatched), attempt the
sweep — still pgrep-guarded, so a no-match costs one pgrep fork and kills nothing.
Idempotent, non-fatal, returns 0 always.

### Success Criteria

- [ ] A lease with positive-but-DEAD chrome_pid/chrome_pgid plus a live process on
      `user-data-dir=$POOL_EPHEMERAL_ROOT/<lane>`: `release` kills that process
      (negative-control test passes).
- [ ] A lease whose recorded pid is alive but is a DIFFERENT process (foreign pid,
      cmdline does not match the dir): sweep still fires (cmdline-match check, not
      just `/proc` existence).
- [ ] Normal case (recorded pid alive and matching, already killed by
      `pool_chrome_kill`): pgrep finds nothing → no kill → unchanged behavior.
- [ ] Anchored pattern `user-data-dir=$dir( |$)`, pgrep guard, pkill/sleep-0.2/
      pkill -9 escalation preserved verbatim (prefix-colliding lanes never hit).
- [ ] `bash -n lib/pool.sh test/bootrace.sh` and `shellcheck -s bash` on both: clean.
- [ ] Full `test/bootrace.sh` suite green in an isolated sandbox; zero orphans after.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, could they implement this?_ Yes: the
exact block to change, its current text, the replacement gate logic, the test harness
patterns to copy, and the safety rules (errexit, liveness via /proc, never kill -0)
are all quoted below.

### Documentation & References

```yaml
- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  section: "§2c Widen the (3b) cmdline sweep in _pool_release_lane_internals"
  why: THE authoritative design for this change — gate semantics, what must stay verbatim
  critical: "drop the both-ids-≤0 precondition and sweep whenever pgrep -f matches and the recorded pid is not confirmed-alive-and-matching"

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  section: "§6"
  why: system-level teardown contract / leak guarantees

- file: lib/pool.sh (lines ~2110-2172: _pool_release_lane_internals; ~2055: pool_chrome_kill)
  why: the function to modify; (3b) block sits between the pool_chrome_kill call and the rm -rf
  pattern: idempotent non-fatal kernel — every kill/rm `2>/dev/null || true`, rc-1 pgrep inside `if`
  gotcha: runs under `set -euo pipefail` in the reap LOOP over many lanes; a bare pgrep/pkill rc≠0 ABORTS the pool — every new command must be guarded or errexit-exempt (`if` condition)

- file: test/bootrace.sh (r3_bug002_race_e2e, lines ~288-333)
  why: the test pattern to copy — snapshot → cleanup-always → assert; fake-chrome fixtures
  pattern: "_br_spawn_owner", FAKE_CHROME_COUNT_FILE, timeout-bounded pool invocations, trailing pkill -f -- \"user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT\" + rm lease/dir cleanup
  gotcha: SINGLE-setup runner — do NOT add per-case process-spawning setup; each case spawns/cleans its own resources; register the new case in the suite's case list

- file: AGENTS.md (§2 §3 §4)
  why: hard operational rules — timeout every subprocess, reap everything, /proc liveness NEVER kill -0 (ESRCH vs EPERM ambiguity)
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh              # ~2900 lines; target: _pool_release_lane_internals step (3b)
test/bootrace.sh         # 438 lines; fake-chrome race harness (T2.S1); add one case
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
lib/pool.sh              # MODIFIED: widened (3b) gate in _pool_release_lane_internals
test/bootrace.sh         # MODIFIED: + r3_neg_dead_ids_release_still_kills case
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: set -euo pipefail — a bare `pgrep` with no match (rc 1) ABORTS the function
#   and the whole reap loop. Keep pgrep inside `if pgrep … >/dev/null 2>&1; then` and
#   every pkill as `pkill … 2>/dev/null || true`.
# CRITICAL: liveness = `[[ -d /proc/$pid ]]` or a /proc/<pid>/cmdline read. NEVER `kill -0`
#   (AGENTS.md §4: rc≠0 for BOTH dead ESRCH and foreign-alive EPERM).
# GOTCHA: the anchored pattern `user-data-dir=$dir( |$)` is ERE for pgrep/pkill -f;
#   keep it VERBATIM (prefix-collision safety: lane 1 must never match lane 10).
# GOTCHA: the gate's skip-condition must read the RECORDED pid's cmdline, not just
#   /proc existence — the BUG-002 clobber can write a FOREIGN live pid.
# GOTCHA: pgrep -f pattern length limit (~4096 chars) is irrelevant here (dir paths are short).
# GOTCHA: do NOT change pool_chrome_kill, the rm -rf prefix guards, or the lease-file
#   rm — S4 touches ONLY the (3b) gate + comment.
# GOTCHA: shellcheck: `/proc/$pid/cmdline` is NUL-separated — read with
#   `tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null` (guard the rc; a process dying between
#   the -d check and the read makes the redirect fail) and grep -F the literal string.
```

## Implementation Blueprint

### Data models and structure

None — no schema change. The lease fields consumed (`chrome_pid`, `chrome_pgid`,
`ephemeral_dir`) are already extracted by the existing `mapfile -t _f < <(jq …)` at
step (2).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lib/pool.sh — _pool_release_lane_internals step (3b)
  - LOCATE: the block starting `# (3b) MID-BOOT KILL RACE fallback` (search that exact
    comment; currently ~line 2083 in the docstring numbering / ~2139 in the file —
    it sits immediately after the `pool_chrome_kill "$chrome_pid" "$chrome_pgid"` call).
  - REPLACE the gate:
      OLD (to delete):
        if [[ ! ( "$chrome_pid"  =~ ^[0-9]+$ && "$chrome_pid"  -gt 0 )
              && ! ( "$chrome_pgid" =~ ^[0-9]+$ && "$chrome_pgid" -gt 0 ) ]]; then
      NEW (skip-sweep only when the recorded pid is confirmed alive-and-matching):
        local pid_cmd=""
        if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )) \
           && [[ -d "/proc/$chrome_pid" ]]; then
            pid_cmd="$(tr '\0' ' ' < "/proc/$chrome_pid/cmdline" 2>/dev/null || true)"
        fi
        if [[ "$pid_cmd" != *"user-data-dir=$dir"* ]]; then
    - i.e. run the sweep unless the recorded pid is alive AND its own cmdline carries
      this lane's user-data-dir (that pid was already killed by pool_chrome_kill in
      step (3); sweeping again would be redundant but harmless — we skip it as a
      one-fork optimization and to keep the log line meaningful).
  - KEEP VERBATIM inside the gate (body unchanged):
        local pat="user-data-dir=$dir( |\$)"
        if pgrep -f -- "$pat" >/dev/null 2>&1; then
            _pool_log "pool_acquire(reap): lane $lane chrome ids untrusted → cmdline sweep"
            pkill    -f -- "$pat" 2>/dev/null || true
            sleep 0.2
            pkill    -9 -f -- "$pat" 2>/dev/null || true
        fi
    (note `sleep 0.2` comment "let renderer/GPU/utility children exit" stays).
  - UPDATE the (3b) block comment: explain the WIDENED gate — fires when ids are
    <=0/non-numeric (original mid-boot window), OR the recorded pid is dead
    (/proc gone — the BUG-002 clobber state), OR alive-but-foreign (cmdline lacks
    this lane's dir). Reference BUG-002 / fix_design §2c. Keep the existing note
    about the anchored `( |$)` pattern preventing prefix-colliding-lane hits.
  - NAMING/PLACEMENT: local vars inside the function (`pid_cmd`); no new globals.
  - CONSTRAINT: touch nothing else in the function (steps 1,2,3,4,5 unchanged).

Task 2: ADD test case to test/bootrace.sh
  - NAME: r3_neg_dead_ids_release_still_kills
  - REGISTER it in the suite's case list next to r3_bug002_race_e2e (single-setup
    runner — the harness setup already ran; spawn/clean this case's own resources).
  - BODY (follow the snapshot→cleanup-always→assert shape of r3_bug002_race_e2e):
    1. `_br_spawn_owner`.
    2. Harvest a REAL dead positive pid: `sleep 300 & local dp=$!; kill "$dp" 2>/dev/null || true; wait "$dp" 2>/dev/null || true` — the kill+wait reaps it,
       so /proc/$dp is gone and $dp is a positive dead pid.
    2b. (Do NOT bare-`kill` without `wait` — an unreaped child stays a zombie whose
       /proc entry persists and would read as alive; AGENTS.md §3.)
    3. Boot one lane normally (FAKE_CHROME_DELAY unset, `timeout 60 … open about:blank`,
       rc must be 0 — else `_fail` fixture problem).
    4. Read the lease `"$AGENT_BROWSER_POOL_STATE/lanes/1.json"`, then REWRITE it with
       `jq --argjson pid "$dp" --argjson pgid "$dp" '.chrome_pid=$pid | .chrome_pgid=$pgid'`
       via a plain `> file` write (this is a test, atomicity irrelevant) — simulating
       the BUG-002 clobber: lease ids now point at the dead pid while the fake chrome
       (recorded in FAKE_CHROME_COUNT_FILE) is live.
    5. `timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true`.
    6. `sleep 0.3` settle, then snapshot: `survivors="$(pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true)"`.
    7. CLEANUP ALWAYS (copy the R3 tail): pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" || true; rm -f lanes/1.json; rm -rf $EPH/1.
    8. ASSERT: `[[ -z "$survivors" ]]` else `_fail "R3-neg: live chrome on lane 1 survived release with dead lease ids: $survivors"; return 1`.
    Also assert `[[ ! -e "$AGENT_CHROME_EPHEMERAL_ROOT/1" ]]` (dir removed) before cleanup.
  - KNOWN-RED on unmodified lib/pool.sh (the sweep is gated out by the dead-but-positive
    ids) — verify that red by temporarily reverting the gate if you want, but do NOT
    leave a red suite: the final state is fixed lib + green test.

Task 3: STATIC + ISOLATED VALIDATION (see Validation Loop)
```

### Implementation Patterns & Key Details

```bash
# The widened gate, complete (drop-in for Task 1):
dir="$POOL_EPHEMERAL_ROOT/$lane"
local pid_cmd=""
if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )) \
   && [[ -d "/proc/$chrome_pid" ]]; then
    pid_cmd="$(tr '\0' ' ' < "/proc/$chrome_pid/cmdline" 2>/dev/null || true)"
fi
if [[ "$pid_cmd" != *"user-data-dir=$dir"* ]]; then
    local pat="user-data-dir=$dir( |\$)"
    if pgrep -f -- "$pat" >/dev/null 2>&1; then
        _pool_log "pool_acquire(reap): lane $lane chrome ids untrusted → cmdline sweep"
        pkill    -f -- "$pat" 2>/dev/null || true
        sleep 0.2
        pkill    -9 -f -- "$pat" 2>/dev/null || true
    fi
fi
# PATTERN: skip only when the recorded pid is alive AND its cmdline names THIS lane's
#   dir (it was the id-kill's target). Every other state sweeps — dead ids (BUG-002
#   clobber), foreign-live ids, provisional 0/0 (original mid-boot window).
# GOTCHA: `(( chrome_pid > 0 ))` inside `&&` chain is errexit-safe (condition context);
#   a bare `(( ))` statement is NOT — keep it inside the if-condition.
# GOTCHA: the `tr <` redirect failure (process died between checks) is covered by
#   `|| true` → pid_cmd empty → sweep fires → correct.
# CRITICAL: `local` at function scope, declared before first use; pid_cmd/pat are new.
```

### Integration Points

```yaml
UPSTREAM (consume, do NOT modify):
  - pool_chrome_kill PID PGID — stays the primary id-based teardown at step (3)
  - lease fields chrome_pid/chrome_pgid/ephemeral_dir from the existing jq extraction
  - P1.M1.T2.S2's pool_lane_boot_lock (boot serialization) — orthogonal; makes the
    clobber rare, S4 makes release leak-proof anyway (defense-in-depth)
  - P1.M1.T2.S3's restructured pool_ensure_connected — parallel work; does NOT touch
    _pool_release_lane_internals, no interface to reconcile
DOWNSTREAM:
  - P1.M1.T3.S1 integration gate runs the full matrix incl. this suite — no code
    consumer; behavior contract only: release never leaks a chrome on a pool dir
CONFIG/DOCS: none — internal teardown hardening; no user-facing surface change
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh          # Expected: silent success
shellcheck -s bash lib/pool.sh                            # Expected: no NEW warnings
shellcheck -s bash test/bootrace.sh
```

### Level 2: Targeted Unit (the new negative-control, isolated sandbox)

Run ONLY this case first via the harness's case-selection mechanism (see the runner
at the bottom of test/bootrace.sh; if it runs all cases, run the full suite — it is
fast and single-setup):

```bash
# ISOLATED temp tree — copy the env redirection the harness itself performs; NEVER
# run against the operator's real state (AGENTS.md §1).
timeout 300 bash test/bootrace.sh
# Expected: all cases incl. r3_neg_dead_ids_release_still_kills PASS (grep 'R3-neg')
```

### Level 3: Integration (system validation, isolated sandbox only)

```bash
# Zero-leak sweep after the suite — MANDATORY per AGENTS.md §3/§6 checklist:
pgrep -af 'user-data-dir=' || echo "clean: no orphan chrome"
# Expected: clean (the harness also self-cleans; verify nothing escaped)
pgrep -af 'fake-chrome|FAKE_CHROME' || echo "clean: no fake chrome left"
```

### Level 4: Regression Matrix (this item's own gate; full matrix is P1.M1.T3.S1)

```bash
# In the isolated sandbox: the four repo suites must stay green (S4 touches shared
# teardown — reap/release are composed by acquire, release, and reap):
timeout 600 bash test/release_reaper.sh
timeout 600 bash test/bootrace.sh
# + the other suites listed in the repo's test/ dir (run what P1.M1.T3.S1's PRP lists;
# at minimum release_reaper + bootrace here)
# Expected: all green, zero orphans (pgrep sweep above)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh test/bootrace.sh` clean
- [ ] `shellcheck -s bash lib/pool.sh test/bootrace.sh` no new findings
- [ ] `test/bootrace.sh` fully green in isolated sandbox, including new R3-neg
- [ ] `test/release_reaper.sh` still green (shared teardown path untouched in behavior)
- [ ] Zero orphaned processes after all runs (`pgrep -af 'user-data-dir='` empty)

### Feature Validation

- [ ] Dead-but-positive lease ids + live chrome on the dir → release kills it (R3-neg)
- [ ] Foreign-live recorded pid (cmdline mismatch) → sweep still fires
- [ ] Normal path (ids valid, chrome killed by pool_chrome_kill) → no behavior change
- [ ] Anchored pattern + escalation preserved verbatim; prefix-collision safety intact
- [ ] Idempotent: second release on same lane is a clean no-op (kernel returns 0)

### Code Quality Validation

- [ ] Only the (3b) gate + comment changed in `_pool_release_lane_internals`
- [ ] All new commands errexit-safe (`if`-context or `|| true`)
- [ ] No new globals; `local` for pid_cmd/pat
- [ ] Test follows snapshot→cleanup-always→assert; registered in single-setup runner

### Documentation & Deployment

- [ ] Block comment updated to document the widened gate + BUG-002 reference
- [ ] No user-facing docs needed (internal hardening — PRD item 5: "DOCS: none")

## Anti-Patterns to Avoid

- ❌ Do NOT rewrite pool_chrome_kill or the rm -rf guards — S4 is a GATE change only
- ❌ Do NOT use `kill -0` for liveness (ESRCH/EPERM ambiguity, AGENTS.md §4)
- ❌ Do NOT unanchor the pgrep pattern (`user-data-dir=$dir` without `( |$)` hits lane 10 from lane 1)
- ❌ Do NOT add per-test setup to bootrace.sh (single-setup runner; AGENTS.md §4)
- ❌ Do NOT run the suite against the real $HOME / real state dirs
- ❌ Do NOT leave any unguarded pgrep/pkill (set -e aborts the reap loop)

---

**Confidence Score**: 9/10 — the change is a precisely-located, fully-specified gate
widening with the authoritative design (fix_design §2c), the exact current code quoted,
a deterministic known-red/known-green test contract, and clear safety rules. Residual
risk: minor line-number drift from the parallel S3 landing (locate by comment, not
line number — already instructed) and the /proc cmdline read racing process death
(handled by `|| true` → sweep fires).