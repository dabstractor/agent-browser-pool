# PRP — P4.M2.T2.S1: Convert test/concurrency.sh to a single-setup runner

## Goal

**Feature Goal**: `test/concurrency.sh` stops using the framework's per-test runner
`abpool_run_suite` (which calls the process-spawning `setup()` once per `test_` body) and
instead uses a release_reaper-style **single-setup runner**: exactly ONE `setup()` call for
the whole file, bodies executed via `if "$fn"` in the **MAIN shell**, an inter-body
backstop, and ONE `teardown()` at the end. After this change the file safely tolerates 3+
`test_` bodies — removing the documented shared-sandbox hang (3rd `setup()` call) and
unlocking P4.M2.T2.S2 (the caller-mode two-child E2E that adds a 3rd body).

**Deliverable**: Modified `test/concurrency.sh` only (a new local runner function
`_abpool_run_concurrency_suite` mirroring `_abpool_run_release_reaper_suite`, plus a local
kill+reap helper, plus zombie-safe owner cleanup in the two existing bodies). No framework
(`test/validate.sh`) changes. No other files.

**Success Definition**:
- `bash -n test/concurrency.sh` and `shellcheck -s bash test/concurrency.sh` are clean.
- `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh` in an isolated sandbox:
  both existing tests (`test_n_agents_get_n_distinct_lanes`,
  `test_n_provisional_lanes_are_distinct`) still PASS.
- Post-run audit: zero orphaned `chrome`/`sleep` processes and zero leftover
  `abpool-test.*` / `abpool-test-eph.*` / `abpool-pi.*` temp dirs (AGENTS.md §3/§6).
- `setup()` is provably called exactly once (code inspection: single call site in the new
  runner; `abpool_run_suite` no longer referenced).

## Why

- `abpool_run_suite`/`run_test` call `setup()` before EACH body (test/validate.sh:246,
  :267). `setup()` spawns a sim-owner process every call; **the 3rd call HANGS the shared
  sandbox** (documented P1.M9.T1.S1 accumulation defect; AGENTS.md §4; architecture
  `test_framework.md` LM-1). concurrency.sh currently has exactly 2 bodies — at the hang
  threshold. Any future body (S2's E2E) would hang it.
- AGENTS.md §4 explicitly endorses converting TOWARD single-setup ("never the reverse").
- The approved pattern already exists and is battle-tested:
  `_abpool_run_release_reaper_suite` (test/release_reaper.sh:440–467).

## What

1. Add `_abpool_run_concurrency_suite()` to `test/concurrency.sh` — a local copy (do NOT
   source-share from release_reaper.sh; do NOT touch validate.sh's exported surface) that:
   - initializes `ABPOOL_PASS/ABPOOL_FAIL/ABPOOL_FAILED`,
   - calls `setup` exactly ONCE,
   - kills + zombie-reaps setup's sim-owner (`$AGENT_BROWSER_POOL_OWNER_PID`) if the file's
     bodies don't need it (see Gotcha G3 below for the concurrency-specific decision),
   - loops `for fn in $(compgen -A function | grep '^test_' | sort)` executing each body
     via `if "$fn"; then …` in the MAIN shell (never a `( … )` subshell — LM-2: the EXIT
     trap inherits into subshells and would `rm -rf` the shared temp root mid-suite),
   - after each body (backstop, every command `|| true`-guarded):
     `"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true`, then kill+wait any owners the
     body spawned (see G4), then clear `ABPOOL_CUR_OWNER` if used,
   - calls `teardown` once at the end, prints the pass/fail tally, returns rc 1 iff any
     body failed (mirror release_reaper.sh:460–466 verbatim).
2. Replace the `:441`-area call `abpool_run_suite test_` in the source-vs-execute gate with
   `_abpool_run_concurrency_suite`.
3. Keep BOTH existing `test_` bodies and their assertions/semantics unchanged, EXCEPT for
   the two main-shell-safety adjustments required by LM-4 (below, G4/G5): convert bare
   `kill "${owner_pids[$i]}" 2>/dev/null || true` cleanup loops into kill + `wait` so no
   zombies survive (bodies now run in the main shell, so the spawned sim-owners are the
   MAIN shell's children — unwaited kills leave zombies whose `/proc/<pid>` lingers and can
   read false-alive).
4. Update the file-header comment block (the "SOURCES the LANDED test framework" line at
   :20 mentions `run_test/abpool_run_suite`) and the source-vs-execute gate comment to
   document the single-setup constraint, mirroring release_reaper.sh's ★★★ header note.

### Success Criteria

- [ ] Exactly one `setup()` call site in concurrency.sh (grep `^    setup` → 1 hit); zero
      references to `abpool_run_suite`/`run_test` remain.
- [ ] Both bodies pass; runner returns 0.
- [ ] No body runs in a `( … )` wrapper at the runner level (internal subshells inside
      bodies — the parallel-acquire `( … ) &` blocks — are fine and MUST be kept; they are
      the concurrency seam, and they `exit`, not `return`).
- [ ] Inter-body backstop releases all lanes and kills+waits body-spawned owners.
- [ ] Static checks clean; isolated-sandbox run passes with a zero-orphan/zero-tempdir audit.

## All Needed Context

### Context Completeness Check

An agent knowing nothing about this repo needs: the two runner implementations to compare,
the landmine list (why single-setup, why no subshell bodies, why kill+wait), the ownership
model of setup's sim-owner vs body-spawned owners, and the blessed validation invocation.
All are quoted/pinned below.

### Documentation & References

```yaml
- file: test/release_reaper.sh
  why: THE pattern to mirror — _abpool_run_release_reaper_suite at :440–467
  pattern: |
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _release_kill_owner_and_reap_zombie "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
    done
    teardown
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    (( ABPOOL_FAIL > 0 )) && { printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2; return 1; }
    return 0
  gotcha: copy LOCALLY; do not source release_reaper.sh from concurrency.sh (it would run
    nothing — its gate checks BASH_SOURCE — but it would re-define its test_ functions and
    pollute compgen enumeration). Also copy its kill+reap helper pattern.

- file: test/release_reaper.sh:135–147 (_release_kill_owner_and_reap_zombie)
  why: kill + zombie-reap helper — kill PID, then `wait PID` so /proc/PID truly vanishes
  pattern: add an equivalent `_concurrency_kill_owner_and_reap_zombie()` local helper
  gotcha: a zombie's /proc entry (and comm) persist after kill → false-alive reads (LM-4)

- file: test/validate.sh:239–273 (run_test + abpool_run_suite)
  why: what you are REPLACING and why — run_test calls setup() per body and wraps bodies in
    a `( set -e; "$fn" )` subshell. Both behaviors are the hazard being removed.
  gotcha: DO NOT modify validate.sh. Keep concurrency.sh's internal body subshells
    (`( … ) &` parallel acquire workers) — they are the test's concurrency mechanism and
    are unaffected by LM-2 (they exit before the body returns; the EXIT trap firing in them
    at their own exit is inherited but they never exit the suite — verify: they call `exit`,
    the trap runs inside the worker subshell, which is why the bodies' cleanup comments say
    the btrfs root is reaped explicitly — keep that logic unchanged).

- file: test/concurrency.sh:1–28 (header), :77+ (_concurrency_setup_master), :217+ and
    :368+ (the two test bodies), :438–444 (the gate to edit)
  why: the file being modified; both bodies currently rely on setup()'s sim-owner as
    "owner #0" (AGENT_BROWSER_POOL_OWNER_PID/STARTTIME set by setup) and spawn N-1 more.

- file: plan/004_de5e94ac127c/architecture/test_framework.md (§13 Landmines LM-1..LM-8)
  why: the authoritative landmine list. Relevant here: LM-1 (per-test setup hangs on 3rd
    call), LM-2 (no subshell bodies in single-setup suites), LM-3 (`ABPOOL_SIM_BINS+=` lost
    in $() — irrelevant since spawn_sim_owner is called in main shell here), LM-4 (kill+wait
    zombies), LM-6 (single-slot ABPOOL_CUR_OWNER), LM-8 (don't simplify away the real
    master/agent-browser env overrides).

- file: plan/004_de5e94ac127c/architecture/synthesis.md §3 (concurrency.sh landmine bullet)
  why: sanctions this exact conversion and names the mirror lines (:440–467).

- file: AGENTS.md §1–§4, §6
  why: hard operating rules — isolated sandbox only, timeout on every live run, reap
    everything, single-setup discipline.
```

### Current Codebase tree (relevant slice)

```bash
test/
├── validate.sh          # framework: setup/teardown/run_test/abpool_run_suite + selftests (DO NOT MODIFY)
├── release_reaper.sh    # single-setup reference (READ ONLY — pattern source)
├── concurrency.sh       # ★ THE FILE TO MODIFY (444 lines)
└── transparency.sh
lib/pool.sh              # SUT (read only)
```

### Desired Codebase tree

```bash
test/
└── concurrency.sh       # + _concurrency_kill_owner_and_reap_zombie (near top, after
                         #   _concurrency_setup_master), + _abpool_run_concurrency_suite
                         #   (after last test body, before the gate), gate switched,
                         #   header comment updated, owner cleanup loops made wait-safe
```

### Known Gotchas of our codebase & Library Quirks

- **G1 (LM-1)**: Never call `setup()` more than once per file execution. The single-setup
  runner calls it exactly once. Do NOT "restore" `abpool_run_suite` later (AGENTS.md §4).
- **G2 (LM-2)**: Bodies MUST run via `if "$fn"` in the main shell. Under `if`, errexit is
  disabled inside the body — that is exactly why every assert in these bodies already ends
  in `|| return 1` (verified: both bodies use `_fail …; return 1` / `assert_eq … || return 1`
  / `if !` guards). Do not add new unguarded rc-1 calls (LM-5).
- **G3 (setup's owner is LIVE state across bodies)**: `setup()` exports
  `AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME` and both bodies use it as owner #0. Unlike
  release_reaper.sh (which kills setup's owner immediately because its bodies each spawn
  their own), concurrency's bodies CONSUME it. Decision: KEEP setup's owner alive — do not
  kill it after setup; the runner's inter-body backstop must NOT kill
  `$AGENT_BROWSER_POOL_OWNER_PID` (that would break body 2). Instead:
  - backstop kills only owners registered in a tracking array (G4) and does `release all`.
  - teardown already kills setup's owner — leave that to teardown (unchanged).
- **G4 (LM-4/LM-6, the concurrency-specific delta vs release_reaper)**: each body spawns
  N-1 extra sim-owners via `spawn_sim_owner` and currently kills them at body end with
  `kill … || true` (no wait — safe under abpool_run_suite because the subshell parent died
  and reparented them). With main-shell bodies they are the main shell's children →
  kills MUST be followed by `wait <pid>` or zombies linger (false-alive /proc reads,
  audit failures). Implement: a file-global array `ABPOOL_CUR_OWNERS=()` appended by the
  bodies where they currently record `owner_pids+=`, and the runner's backstop:
  `for p in "${ABPOOL_CUR_OWNERS[@]:-}"; do [[ -n "$p" ]] && _concurrency_kill_owner_and_reap_zombie "$p"; done; ABPOOL_CUR_OWNERS=()`
  (array-assignment in main shell — bodies run in main shell, so appends persist; unlike
  LM-3's `$(…)` case). ALSO convert each body's final cleanup loop
  `for (( i = 1; i < N; i++ )); do kill "${owner_pids[$i]}" 2>/dev/null || true; done`
  to kill+wait (call the new helper). Keep `|| true`-style guards so a dead pid never
  aborts the body.
- **G5**: `wait` on a non-child returns rc 127 — guard (`wait "$pid" 2>/dev/null || true`).
- **G6**: `(( ABPOOL_FAIL > 0 ))` as a bare statement aborts under `set -e` — use the
  `if (( … )); then … return 1; fi` form exactly as release_reaper.sh:463–466 does.
- **G7**: Do NOT change `_concurrency_setup_master`, the btrfs ephemeral-root logic, the
  parallel-acquire subshells, or any assertion. This is a runner-conversion, not a test
  rewrite (LM-8: the real master/binary overrides are load-bearing).
- **G8**: Because both bodies re-read `$AGENT_BROWSER_POOL_OWNER_PID` fresh (main shell env
  persists from the ONE setup call), and each body ends with `release all`, body 2 starts
  from a clean lane store — but a FAILED body 1 might leave leases/Chromes; the runner's
  inter-body `release all` backstop covers exactly that. Keep it.
- **G9**: All live runs must be `timeout`-wrapped and isolated (AGENTS.md §1/§2): the run
  boots REAL headless Chrome and redirects state to temp trees via the framework — run it
  only in the isolated sandbox (the framework's setup already redirects HOME/state; the
  blessed invocation is in Validation below). Never run it against the live operator HOME
  by sourcing around setup.

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD _concurrency_kill_owner_and_reap_zombie to test/concurrency.sh
  - PLACEMENT: after _concurrency_setup_master (~line 155), before the first test body.
  - IMPLEMENT: kill -TERM PID (|| true), then wait PID (|| true) — mirror
    release_reaper.sh:141–147; name it with the _concurrency_ prefix (local copy policy).
  - GOTCHA: accept already-dead pids gracefully (every command guarded).

Task 2: UPDATE both test bodies' owner bookkeeping + cleanup (semantics preserved)
  - In test_n_agents_get_n_distinct_lanes (~:354) and test_n_provisional_lanes_are_distinct
    (~:428): replace the trailing `for (( i = 1; i < N; i++ )); do kill … || true; done`
    loops with kill+wait via the Task-1 helper.
  - ADD: append each spawned owner pid to a file-global ABPOOL_CUR_OWNERS array where
    spawn_sim_owner results are collected (`owner_pids+=("$pid")` sites — add
    `ABPOOL_CUR_OWNERS+=("$pid")` alongside), so the runner backstop can reap them even on
    a FAIL-exit mid-body. Declare `ABPOOL_CUR_OWNERS=()` at file scope near the top.
  - PRESERVE: all assertions, the parallel-acquire subshells, _concurrency_setup_master
    call, release-all cleanup, and comment text (only add kill→wait).

Task 3: ADD _abpool_run_concurrency_suite (mirror release_reaper.sh:440–467)
  - PLACEMENT: after the last test body, before the source-vs-execute gate.
  - STRUCTURE: as quoted in the yaml references block above, with the concurrency deltas:
    * NO kill of setup's owner after setup (G3 — bodies consume it; teardown kills it).
    * Inter-body backstop: `"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true` +
      kill+wait every pid in ABPOOL_CUR_OWNERS + `ABPOOL_CUR_OWNERS=()`.
    * Comment block explaining the SINGLE-SETUP constraint (mirror the ★★★ note,
      release_reaper.sh:23–33, adapted: why concurrency keeps setup's owner alive).
  - RETURN: 0 iff ABPOOL_FAIL==0 (if-form, G6).

Task 4: REPLACE the gate call + update header comments
  - :441: `abpool_run_suite test_` → `_abpool_run_concurrency_suite`.
  - Header (:20) and gate comments: drop the run_test/abpool_run_suite mention; add the
    single-setup note.
  - VERIFY: grep -n 'abpool_run_suite\|run_test' test/concurrency.sh → only comments, or
    none; grep -cn '^    setup$' (exact single call) → 1.

Task 5: VALIDATE (see Validation Loop — static first, then the one isolated live run)
```

### Implementation Patterns & Key Details

```bash
# The runner skeleton (concurrency-flavored; see release_reaper.sh:440 for the original)
_abpool_run_concurrency_suite() {
    local fn p
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    ABPOOL_CUR_OWNERS=()
    setup                                  # ★ the ONE AND ONLY setup() call
    # NOTE: unlike release_reaper, we KEEP setup's sim-owner alive — both bodies use it as
    # owner #0. teardown kills it. (G3)
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then                      # MAIN shell — never ( … ) (LM-2)
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
        for p in "${ABPOOL_CUR_OWNERS[@]:-}"; do
            [[ -n "$p" ]] && _concurrency_kill_owner_and_reap_zombie "$p"
        done
        ABPOOL_CUR_OWNERS=()
    done
    teardown
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    if (( ABPOOL_FAIL > 0 )); then
        printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2
        return 1
    fi
    return 0
}
```

### Integration Points

None. Pure test-infra refactor inside `test/concurrency.sh`. No lib/, bin/, docs, or
framework changes. Runs AFTER the P4.M1.T1.S1 citation sweep (already landed) — verify the
file's PRD citation comments are current before editing near them but do not renumber
anything.

## Validation Loop

### Level 1: Static (run FIRST, always safe, no sandbox needed)

```bash
bash -n test/concurrency.sh                      # syntax
shellcheck -s bash test/concurrency.sh           # lint — expect clean (existing SC2031
                                                 # disables stay)
grep -n 'abpool_run_suite\|run_test' test/concurrency.sh   # expect: none (or comment-only)
grep -c '^    setup$' test/concurrency.sh        # expect: 1
```

### Level 2: Isolated-sandbox live run (real headless Chrome — REQUIRED before done)

```bash
# ONLY in an isolated sandbox (AGENTS.md §1). Never against the live operator HOME.
AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh
# Expected: "1 passed" per test in name order (n_agents_get_n_distinct_lanes sorts before
# n_provisional_lanes_are_distinct), final "2 passed, 0 failed", rc 0.
```

### Level 3: Orphan / leak audit (immediately after Level 2, same sandbox)

```bash
pgrep -af 'chrome|abpool-pi|sleep 600' || echo "no orphans"     # expect no orphans
ls -d /tmp/abpool-test.* /tmp/abpool-pi.* "$HOME"/abpool-test-eph.* 2>/dev/null \
  || echo "no leftover temp dirs"                                # expect none
```

### Level 4: Third-body tolerance proof (optional, cheap, static-only)

Do NOT actually add a 3rd body (that's S2's job). Instead confirm by inspection: the new
runner has no per-body setup/teardown, so body count is unbounded. If you want a live
proof, add a TEMPORARY trivial `test_zzz_smoke() { assert_eq 1 1 "trivial" || return 1; }`
inside the isolated sandbox run only, then delete it before committing.

## Final Validation Checklist

- [ ] `bash -n` + `shellcheck -s bash` clean on test/concurrency.sh
- [ ] Zero `abpool_run_suite`/`run_test` references; exactly one `setup` call
- [ ] Bodies run via `if "$fn"` in main shell; no runner-level subshells
- [ ] Isolated-sandbox run: 2 passed, 0 failed, rc 0, within timeout
- [ ] Zero orphan processes / leftover temp dirs after the run
- [ ] Existing assertions, subshell workers, and env-override logic untouched
- [ ] validate.sh, release_reaper.sh, lib/, bin/, docs untouched (git status clean except
      test/concurrency.sh)
- [ ] File is now safe for a 3rd `test_` body (precondition handed to P4.M2.T2.S2)

## Anti-Patterns to Avoid

- ❌ Don't source release_reaper.sh for its helpers/runner — local copy (its `test_`
  functions would pollute `compgen` enumeration and could double-run under an aggregator).
- ❌ Don't modify validate.sh or "share" the runner into the framework.
- ❌ Don't run bodies in `( … )` (LM-2) or restore the per-test runner (AGENTS.md §4).
- ❌ Don't kill setup's sim-owner in the runner — bodies consume it (G3).
- ❌ Don't leave unwaited killed owners (LM-4 zombies → false-alive + audit failures).
- ❌ Don't run the suite outside an isolated sandbox or without `timeout` (AGENTS.md §1/§2).
- ❌ Don't touch the bodies' assertion semantics — this is a runner conversion only.

## Confidence Score

9/10 — the target pattern is fully landed and battle-tested in the same repo; the only
novel delta is keeping setup's owner alive across bodies + array-tracked owner reaping,
both specified above with line-level anchors.