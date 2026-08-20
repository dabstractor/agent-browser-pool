---
name: "P4.M2.T1.S4 — Pin matrix selftest (free/stale/live-mine/live-foreign/other-lane)"
---

## Goal

**Feature Goal**: Add one selftest to `test/validate.sh`, `selftest_lane_pin_matrix`, exercising ALL five matrix cases of the `ABPOOL_LANE=<N>` pinned-acquire path (`_pool_acquire_critical_section` pin branch, lib/pool.sh :2273–:2341) at the critical-section level: FREE, STALE, LIVE-MINE (idempotent), LIVE-FOREIGN (hard error, never a takeover), and ALREADY-HOLDS-ANOTHER-LANE (one-lane-per-owner invariant error). Chrome-free (pins write provisional port=0 leases; boot never runs).

**Deliverable**: `selftest_lane_pin_matrix` in `test/validate.sh`, using per-body isolated state roots + sim owners via the `AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME` hooks, with capture→reap→assert ordering and kill+wait on every spawned owner.

**Success Definition**: `timeout 120 bash test/validate.sh` (isolated sandbox only) reports the selftest PASS alongside all pre-existing selftests (including P4.M2.T1.S1–S3's); `bash -n` + `shellcheck -s bash` add zero warnings; zero orphaned processes.

## User Persona

**Target User**: Maintainer/agent validating PRD §2.12 mode 2 (`ABPOOL_LANE`) semantics.
**Use Case**: Regression gate for deterministic lane pinning: adopt free/stale, reuse own, hard-error on foreign live leases and on violating the ≤1-lane-per-owner invariant.
**Pain Points Addressed**: silent takeover of another agent's lane; a pin silently migrating owners; a pinned owner ending up with two lanes.

## Why

- PRD §2.12 mode 2: "N free or stale → take it; N has a live lease owned by another process → hard error... Never a takeover"; one owner holds ≤1 lane (§2.8).
- PRD §2.19 explicitly requires "Pinned-lane conflicts (`ABPOOL_LANE=N` with a live foreign lease) error cleanly" — this selftest is the required §2.19 pin coverage.
- Locks in P4.M1.T4.S1 (pin branch) + P4.M1.T4.S2 (wrapper skip) — this test asserts the **acquire-level** critical-section rc semantics (the wrapper's "never waits for pins" is S2's wrapper layer; here we assert the die/echo behavior of the critical section itself).

## What

One selftest function, five sequential scenarios sharing the body-script idiom. Each scenario gets its own fresh state roots (`$ABPOOL_TEST_ROOT/pinmatrix-<case>/{state,active}`) and its own sim owners. Never re-test malformed `ABPOOL_LANE` (config-level, covered by P4.M2.T1.S1).

### The five scenarios

1. **FREE**: owner A (hooked) with `ABPOOL_LANE=7`, lane 7 unleased → body calls `pool_config_init; pool_owner_resolve; N="$(pool_acquire_locked)"` → echoes 7; lease file `$state/lanes/7.json` exists; lease `port == 0` (provisional claim) read via `port="$(pool_lease_field 7 port 2>/dev/null)" || port=""`.
2. **STALE**: owner A acquires lane 7 (as above), main shell kills + **waits** A (LM-4), owner B (different pid+comm) pins 7 → echoes 7; new lease `owner.pid == pidB` (jq `-r '.owner.pid'` on the lease file — `owner` is nested; `pool_lease_field` supports dotted paths but jq-on-file is the safe fallback); old lease rewritten (owner triple is B's, not A's).
3. **LIVE-MINE**: owner A pins 7 twice (two body invocations, same hooks, same roots) → both echo 7 and the lease owner triple is UNCHANGED between calls (capture `owner.pid`+`owner.starttime` after each; idempotent reuse does NOT rewrite — lib :2312–2315).
4. **LIVE-FOREIGN**: owner A (alive) holds lane 7; owner B pins 7 in a body under `timeout 15` → body rc != 0 AND captured stderr contains `pinned lane 7 is held by a live owner` AND `pid $pidA` AND `never a takeover`; then assert lane 7's lease still shows `owner.pid == pidA` (untouched).
5. **ALREADY-HOLDS-ANOTHER-LANE**: owner B first acquires an AUTO lane M (no `ABPOOL_LANE`) in the same roots → M != 7; then B (still alive, same hooks) pins FREE lane 7 → body rc != 0 AND stderr contains `already holds live lane M` and `one-lane-per-owner invariant`; assert B still holds exactly M (lease `lanes/$M.json` `owner.pid == pidB`; no lease anywhere under `$state/lanes` for lane 7).

### Exact diagnostic strings to grep (from lib/pool.sh :2294 / :2318, recorded by P4.M1.T4.S1)

```
invariant (case 5): "owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE"
foreign  (case 4): "pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane"
```

Grep for stable substrings: `already holds live lane`, `one-lane-per-owner invariant`, `is held by a live owner`, `never a takeover`. pool_die exits nonzero (rc 1) and writes to stderr — capture with `2>&1` into the body-output var.

### Success Criteria
- [ ] All five scenarios assert as specified; selftest PASS.
- [ ] No other selftest modified or failing; no `ABPOOL_LANE` malformed-value testing here.
- [ ] Every spawned owner killed AND waited on every exit path.

## All Needed Context

### Context Completeness Check

The implementer needs: the pin branch code and its exact die strings, how `pool_acquire_locked`/critical section run Chrome-free with hook-based owners, the single-setup selftest framework idioms (body.sh + per-body roots + `|| rc=$?` + assert_eq), the die-assert idiom, LM-4/LM-6 landmines, and the nesting gotcha for `owner.pid`. All verified against HEAD below.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: code under test
  pattern: |
    _pool_acquire_critical_section pin branch (:2273–:2341):
      - requires POOL_OWNER_PID != 0 (:2274 — call pool_owner_resolve in every body first).
      - (5) invariant scan FIRST: any LIVE lease owned by ME on a lane != N → pool_die (:2294).
      - tri-state pool_lane_is_stale "$N": 0=stale → _pool_release_lane_internals + fresh claim;
        1=live → mine (pid+comm+starttime match) → echo N, NO rewrite; foreign → pool_die (:2318);
        2=no-lease → rm stale $EPHEMERAL_ROOT/$N debris + claim.
      - CLAIM (cases 1/2): pool_lease_write N ... port=0 ... "false" (provisional; no boot).
    pool_config_init (:226–:233): ABPOOL_LANE validated → POOL_LANE_PIN (positive int or die).
    pool_acquire_locked (:2394+): pool_state_init; ( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE".
    pool_lane_is_stale (:1224): TRI-STATE 0/1/2 — always capture via `pool_lane_is_stale X && rc=0 || rc=$?`
      or `if pool_lane_is_stale X; then …; fi` (set -e).
    pool_owner_resolve TEST MODE (~:537): AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME win; needs BOTH.
  gotcha: pool_die inside the body's `timeout 15 bash` exits that bash with rc 1 — the `|| rc=$?`
    capture pattern is mandatory; never let a die abort the MAIN-shell selftest.

- file: test/validate.sh
  why: selftest framework to extend
  pattern: |
    Discovery: auto via compgen -A function | grep '^selftest_' | sort in _run_selftest_suite
    (:1178+); no registration. ONE shared setup(); bodies run in MAIN shell as `if "$fn"` —
    every assert ends `|| return 1`.
    Per-body isolated-roots idiom (see selftest_doctor_dependencies / selftest_cdp_is_ours_uses_socket_owner,
    ~:1086–1230, and P4.M2.T1.S3's selftests): outdir="$ABPOOL_TEST_ROOT/<name>"; write body.sh;
    out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" \
      AGENT_BROWSER_POOL_OWNER_PID=… AGENT_BROWSER_POOL_OWNER_STARTTIME=… [ABPOOL_LANE=7] \
      timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?
    spawn_sim_owner [SECONDS=600] [COMM] (:128) — spawn owners in the MAIN shell; hook PAIR required.
    Die-assert idiom: selftest_preflight_accepts_bare_name_on_path (:896) — rc=0; ( … ) || rc=$?;
    assert_eq + grep the captured output for the diagnostic text.
    Lease field reads: x="$(pool_lease_field "$N" port 2>/dev/null)" || x=""  (LM-5).
    Inter-body sweep (:1192) rm -f MAIN $POOL_LANES_DIR/*.json only — per-body roots are YOUR cleanup.
  gotcha: assert_lane_exists/assert_lane_gone read the MAIN shell's $POOL_LANES_DIR — for per-body
    roots use explicit [[ -f "$outdir/state/lanes/$N.json" ]] checks instead.

- file: plan/004_de5e94ac127c/P4M2T1S3/PRP.md
  why: PARALLEL item adding selftest_caller_mode_* functions to the same file — assume they exist;
    place selftest_lane_pin_matrix adjacent/after them (alphabetical discovery makes placement cosmetic).
  gotcha: do NOT duplicate its acquire/reap assertions; this item is strictly the PIN branch matrix.

- file: plan/004_de5e94ac127c/P4M2T1S1
  why: config-level ABPOOL_LANE validation tests already exist — do not re-test malformed values.

- file: plan/004_de5e94ac127c/architecture/test_framework.md
  why: §12 recipe for adding a selftest; §13 landmines (LM-1..LM-8).

- file: plan/004_de5e94ac127c/architecture/synthesis.md
  why: §3 test-plan grounding for R5 pin-matrix coverage.
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh        # pin branch :2273–:2341; die strings :2294/:2318; pool_config_init :226; TEST MODE :537
test/validate.sh   # selftest framework; spawn_sim_owner :128; setup :204; _run_selftest_suite :1178
```

### Desired Codebase tree

```bash
test/validate.sh   # + selftest_lane_pin_matrix (~180–250 lines; five scenario blocks + shared body-script writers)
```

### Known Gotchas of our Codebase & Library Quirks

```bash
# CRITICAL (LM-4): kill "$pid" then WAIT "$pid" before ANY staleness/lease assert — an unreaped
#   zombie's /proc lingers → pool_lane_is_stale / pool_owner_alive read the owner as alive.
# CRITICAL: hook overrides travel as a PAIR (OWNER_PID + OWNER_STARTTIME); mismatched pair →
#   identity mismatch → lane immediately "stale" or live-mine checks fail.
# CRITICAL (LM-6): never overwrite ABPOOL_CUR_OWNER (setup's owner); your test-spawned owners are
#   your responsibility to kill+wait.
# CRITICAL: pool_die in a body must be CONTAINED — body runs under `timeout 15 bash` with output
#   captured via `|| rc=$?`; a die inside the main shell would abort the whole suite.
# GOTCHA: `owner` is a NESTED json object — read with jq -r '.owner.pid' "$lease" (pool_lease_field
#   does support dotted keys like owner.pid as seen in the lib's own invariant scan; either is fine).
# GOTCHA: for the STALE case the body must mkdir -p "$POOL_EPHEMERAL_ROOT/$N" after the first acquire
#   so the reap-on-pin has an observable dir to remove (acquire never creates it) — then assert the
#   dir is GONE after B's pinned acquire (stale ⇒ _pool_release_lane_internals ⇒ rm -rf dir + lease rewrite).
# GOTCHA: bodies are Chrome-free: pool_acquire_locked claims only; NO agent-browser, NO Chrome,
#   no real state (roots under $ABPOOL_TEST_ROOT).
# shellcheck: use separate `local x; x="$(…)"` (SC2155) in the main shell; bodies may use plain N=$(…).
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD selftest_lane_pin_matrix to test/validate.sh
  - PLACEMENT: after the P4.M2.T1.S3 selftest functions (fall back: after S1's config selftest);
    keep the `# name — description` comment style. Auto-discovered by _run_selftest_suite.
  - STRUCTURE: comment block (matrix cases 1–5, Chrome-free note, hooks, per-case roots).
    Helpers INSIDE the function (or small _pin_matrix_* helpers above it):
    a) a writer for the standard body script, parameterless, identity+pin from env:
        set -euo pipefail
        source "$1/lib/pool.sh"; pool_config_init; pool_owner_resolve
        N="$(pool_acquire_locked)"
        [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "BADN:$N"; exit 1; }
        echo "N|$N"
        echo "OWNERPID|$(jq -r '.owner.pid' "$POOL_LANES_DIR/$N.json")"
        echo "STARTTIME|$(jq -r '.owner.starttime' "$POOL_LANES_DIR/$N.json")"
       plus, when a MARKDIR env var is set, `mkdir -p -- "$POOL_EPHEMERAL_ROOT/$N"` (simulates
       the post-lock copy so case 2's reap is observable).
    b) a runner: out=…; rc=0; out="$(AGENT_BROWSER_POOL_STATE="$d/state" AGENT_CHROME_EPHEMERAL_ROOT="$d/active"
       AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$st" \
       ABPOOL_LANE=7 timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?  (ABPOOL_LANE omitted
       for the auto-acquire in case 5; MARKDIR=1 where a dir is needed).
  - SCENARIO 1 FREE: pidA pi; body(hooks A, ABPOOL_LANE=7) → assert rc 0; N|7; lease file exists;
    port read `p="$(pool_lease_field 7 port 2>/dev/null)" || p=""` run in a same-roots subshell OR
    read via jq on "$d/state/lanes/7.json" → assert_eq "0" "$p" "provisional port=0".
  - SCENARIO 2 STALE: fresh roots; pidA acquires 7 with MARKDIR=1 (dir created); kill+WAIT pidA;
    pidB claude; body(hooks B, ABPOOL_LANE=7, SAME roots) → rc 0; N|7; OWNERPID|pidB;
    assert "$d/active/7" dir GONE; assert lease owner.pid == pidB (A rewritten away).
  - SCENARIO 3 LIVE-MINE: fresh roots; pidA; body A (pin 7, MARKDIR=1) → capture OWNERPID/STARTTIME;
    body A again (pin 7) → rc 0; N|7; OWNERPID/STARTTIME identical to first call (no rewrite).
  - SCENARIO 4 LIVE-FOREIGN: fresh roots; pidA holds 7 (pin, MARKDIR=1, keep A ALIVE); pidB;
    body(hooks B, ABPOOL_LANE=7) → assert rc != 0; output grep: 'is held by a live owner',
    'never a takeover', and "$pidA" appears; then assert (same roots, jq) lane 7 lease owner.pid == pidA.
  - SCENARIO 5 OTHER-LANE: fresh roots; pidB claude; body(hooks B, NO ABPOOL_LANE) → rc 0;
    M="$(sed -n 's/^N|//p' <<<"$out")"; assert M != 7 and M numeric; then body(hooks B, ABPOOL_LANE=7,
    SAME roots) → rc != 0; output grep 'already holds live lane' and 'one-lane-per-owner invariant'
    (optionally "lane $M"); assert lease "$state/lanes/$M.json" still owner.pid == pidB and
    "$state/lanes/7.json" absent (jq/[[ -f ]] checks).
  - CLEANUP (unconditional before every return; simplest: a run-everything-then-assert layout, or
    explicit `kill pids… || true; wait pids… || true` on each early-return path): kill+wait pidA/pidB
    of the current scenario. Inter-body lease sweep only covers MAIN roots; per-case dirs live under
    $ABPOOL_TEST_ROOT until the suite trap — acceptable.

Task 2: STATIC VALIDATION
  - bash -n test/validate.sh
  - shellcheck -s bash test/validate.sh   (zero NEW warnings)

Task 3: LIVE VALIDATION (isolated sandbox ONLY — AGENTS.md §1/§2)
  - timeout 120 bash test/validate.sh → selftest_lane_pin_matrix PASS + all others green
  - pgrep -af 'abpool|sleep' → nothing new left behind
```

### Implementation Patterns & Key Details

```bash
# Die-assert idiom (case 4/5) — capture stderr, contain the exit:
rc=0
out="$(AGENT_BROWSER_POOL_STATE="$d/state" AGENT_CHROME_EPHEMERAL_ROOT="$d/active" \
      AGENT_BROWSER_POOL_OWNER_PID="$pidB" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stB" \
      ABPOOL_LANE=7 timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || { _fail "live-foreign pin must fail"; return 1; }
grep -q 'is held by a live owner' <<<"$out" || { _fail "missing foreign-owner diagnostic"; return 1; }
grep -q 'never a takeover' <<<"$out" || { _fail "missing never-a-takeover wording"; return 1; }
grep -q "pid $pidA" <<<"$out" || { _fail "diagnostic must name lane 7's live owner pid"; return 1; }

# Kill→wait discipline (LM-4) — before asserting staleness/rewrite in case 2:
kill "$pidA" 2>/dev/null || true
wait "$pidA" 2>/dev/null || true

# Provisional-lease assert (case 1) — jq on the body's own lease file:
p="$(jq -r '.port' "$d/state/lanes/7.json")"; assert_eq "0" "$p" "pin claim is provisional port=0"
```

### Integration Points

```yaml
NONE:
  - No lib/pool.sh changes (tests the existing P4.M1.T4 pin branch).
  - No docs (item contract: DOCS none). No new env vars; no real Chrome; no real state writes.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n test/validate.sh
shellcheck -s bash test/validate.sh
# Expected: zero errors, zero NEW warnings (SC1091/SC2016 infos pre-exist).
```

### Level 2: Suite (isolated sandbox only — never the operator's live HOME/state)

```bash
timeout 120 bash test/validate.sh
# Expected: selftest_lane_pin_matrix PASS; every pre-existing selftest PASS.
```

### Level 3: Leak audit

```bash
pgrep -af 'abpool|agent-browser|sleep' || true
ls /tmp/abpool-* 2>/dev/null || true
# Expected: nothing spawned by this selftest remains.
```

### Level 4: Creative / domain-specific
N/A (Chrome-free logic tests).

## Final Validation Checklist

- [ ] `bash -n` clean; `shellcheck -s bash` adds zero warnings
- [ ] `timeout 120 bash test/validate.sh` green in the isolated sandbox (new + all old selftests)
- [ ] Case matrix verified: FREE echoes 7 with port=0 lease; STALE reaped+rewritten to B; LIVE-MINE idempotent (owner triple unchanged); LIVE-FOREIGN rc!=0 with lane/pid/never-a-takeover diagnostics and A's lease untouched; OTHER-LANE rc!=0 with invariant diagnostic and B still holding exactly M
- [ ] No malformed-ABPOOL_LANE testing (owned by P4.M2.T1.S1)
- [ ] Every spawned owner killed AND waited on every exit path; no `ABPOOL_CUR_OWNER` mutation; no other selftest touched
- [ ] Function named exactly `selftest_lane_pin_matrix`

## Anti-Patterns to Avoid

- ❌ Don't assert staleness/lease state before `wait`ing a killed owner (LM-4)
- ❌ Don't override only `AGENT_BROWSER_POOL_OWNER_PID` — always the (PID, STARTTIME) pair
- ❌ Don't let a pool_die escape the body subshell (`timeout 15 bash … 2>&1) || rc=$?` containment)
- ❌ Don't use main-shell `assert_lane_exists` for body-local leases — explicit path checks against the body's `$d/state/lanes`
- ❌ Don't re-call setup() or test malformed ABPOOL_LANE values
- ❌ Don't run validate.sh against the operator's live state dirs — isolated sandbox only
- ❌ Don't boot real Chrome — the pin path is claim-only