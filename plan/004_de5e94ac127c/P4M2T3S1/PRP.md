# PRP — P4.M2.T3.S1: Unit matrix — validate.sh full suite green

## Goal

**Feature Goal**: Execute the PRD R5 unit acceptance gate for the caller-scoped /
lane-pinning feature: run the FULL `test/validate.sh` selftest suite (all pre-existing
selftests untouched + the four new selftest families from P4.M2.T1.S1–S4) in an
ISOLATED sandbox and produce a recorded GREEN run log (rc 0, all selftests passed).

**Deliverable**: No production code changes expected. Deliverables are:
1. A green full-suite run log saved at
   `plan/004_de5e94ac127c/P4M2T3S1/research/validate_full_run.log` (tee of the run).
2. Static-check proof (bash -n + shellcheck, zero warnings) in
   `plan/004_de5e94ac127c/P4M2T3S1/research/static_checks.log`.
3. If (and only if) a failure occurs, a fix confined to the OWNING subtask's scope
   (the selftest body from P4.M2.T1.Sx, or the lib/pool.sh code it covers) — never a
   weakened assert — plus a re-run until green.

**Success Definition**:
- `timeout 120 bash test/validate.sh` in an isolated sandbox → rc 0, `N passed, 0 failed`
  where N ≥ the pre-P4.M2 count + the new selftests (see expected list below).
- `bash -n` + `shellcheck -s bash` on `lib/pool.sh`, `install.sh`, `test/validate.sh` →
  zero warnings (shellcheck SC errors AND warnings; use `-S style` is NOT required —
  match the repo's existing bar: zero output from plain `shellcheck -s bash <file>`).
- Zero orphaned processes and zero leftover `/tmp/abpool-*` / temp roots after the run.

## Why

This is the unit-level half of the PRD acceptance gate "all existing suites pass
untouched + new selftests green" (PRD §2.19; synthesis.md §3). validate.sh is the
Chrome-free unit suite — it must pass with NO real Chrome booted, so it is the default
byte-identical/default-path acceptance proof: the pre-existing selftests running green
UNMODIFIED proves the P4 default path (no env vars) is behaviorally unchanged.

## What

1. **Static first** (always safe, no sandbox needed):
   ```bash
   bash -n lib/pool.sh && bash -n install.sh && bash -n test/validate.sh
   shellcheck -s bash lib/pool.sh; shellcheck -s bash install.sh; shellcheck -s bash test/validate.sh
   ```
   Expect zero output. Record to `research/static_checks.log` (append `2>&1`).
2. **Live run** in an ISOLATED sandbox only (AGENTS.md §1 — never the operator's live
   HOME / real `~/.local/state/agent-browser-pool/` / running Chrome):
   ```bash
   timeout 120 bash test/validate.sh 2>&1 | tee plan/004_de5e94ac127c/P4M2T3S1/research/validate_full_run.log
   echo "rc=${PIPESTATUS[0]}"
   ```
   `validate.sh`'s own `setup()` already redirects HOME/state/ephemeral root into a
   `mktemp -d` temp root with an EXIT trap that removes everything — running it is
   hermetic BY CONSTRUCTION (architecture/test_framework.md; validate.sh:204–228).
   Do NOT add any extra env overrides; the blessed invocation is bare
   (synthesis.md §3: `timeout 120 bash test/validate.sh`, expect rc 0).
3. **Assert the counters**: the summary line must show only passes (e.g.
   `<N> passed, 0 failed`), `ABPOOL_FAILED` empty, rc 0. The suite includes (current
   enumeration, ~35 bodies) — verify at minimum that the four NEW selftest families are
   present and green:
   - `selftest_config_owner_mode_and_lane_pin` (S1 — default-path identity, ABPOOL_OWNER
     any-value, ABPOOL_LANE validation incl. malformed `0`/`-1`/`abc` dies)
   - `selftest_owner_resolves_caller_mode` (S2)
   - `selftest_caller_mode_parallel_owners_distinct_lanes`,
     `selftest_caller_mode_lane_reaped_after_owner_death` (S3)
   - `selftest_lane_pin_matrix` (S4 — free/stale/live-mine/live-foreign/other-lane)
   Enumerate with: `bash -c 'source test/validate.sh >/dev/null 2>&1; true' 2>/dev/null; grep -c '^selftest_' test/validate.sh`
   — simplest: `grep -n '^selftest_' test/validate.sh` for the manifest, and cross-check
   every name appears with a PASS in the log.
4. **Pre-existing selftests untouched**: confirm via `git diff` that, relative to the
   pre-P4.M2 baseline, only ADDITIVE selftest bodies were introduced in P4.M2.T1 —
   i.e. `git log --oneline -- test/validate.sh` and/or `git diff <pre-P4.M2-commit> HEAD -- test/validate.sh`
   shows no deletions/modifications of pre-existing `selftest_*` bodies. If the diff
   does touch one, STOP and report — that violates the acceptance contract, not
   something to fix silently here.
5. **Failure handling**: if any selftest fails, diagnose and fix within the OWNING
   subtask's scope (the selftest body itself, or lib/pool.sh behavior it pinned down).
   NEVER weaken/delete an assert, NEVER change shared framework code (`run_test`,
   `setup`, assertion helpers, `_run_selftest_suite`) to make a test pass. Re-run to
   green and re-record the log.
6. **Post-run hygiene audit** (AGENTS.md §3/§6):
   ```bash
   pgrep -af 'chrome|abpool|agent-browser|sleep' || echo "no orphans"
   ls -d /tmp/abpool-test.* 2>/dev/null || echo "no leftover temp roots"
   ```
7. **Docs**: none (per item contract).

### Success Criteria

- [ ] `timeout 120 bash test/validate.sh` → rc 0, 0 failed, in isolated sandbox.
- [ ] All pre-existing selftests pass UNTOUCHED (git-diff proof of additivity).
- [ ] All four new selftest families (S1–S4) present and green.
- [ ] Static checks: zero warnings on lib/pool.sh, install.sh, test/validate.sh.
- [ ] Green run log + static log recorded under `plan/004_de5e94ac127c/P4M2T3S1/research/`.
- [ ] Zero orphan processes / leftover temp dirs after the run.

## All Needed Context

### Context Completeness Check

An agent new to this repo needs: what validate.sh is and how it isolates itself, the
blessed invocation, which selftests are new vs pre-existing, and where the logs go. All
pinned below; no external research needed (pure in-repo validation item).

### Documentation & References

```yaml
- file: test/validate.sh
  why: THE suite under test. Dual-mode (execute = run selftest_*, source = framework).
    DUAL MODE GATE at bottom: executing runs _run_selftest_suite (single process-spawning
    setup() at :204–228 — hermetic mktemp root + EXIT trap, called exactly ONCE; bodies
    run in the main shell via `if "$fn"`).
  gotcha: Do NOT run it via `source`. Do NOT add env overrides (AGENT_CHROME_* etc.) —
    the suite must pass bare. Do NOT re-run setup per anything.
- file: plan/004_de5e94ac127c/architecture/test_framework.md
  why: blessed invocations + landmines LM-1..LM-8. Key ones here: LM-2 (no runner
    subshells — already handled by the suite), LM-4 (kill+wait spawned owners — the
    suite teardown does this), LM-5 (guard rc-1 calls if you add any shell glue).
- file: plan/004_de5e94ac127c/architecture/synthesis.md (§3)
  why: "Blessed invocations (isolated sandbox + timeout only): `timeout 120 bash
    test/validate.sh` (expect rc 0)". Also lists the exact S1–S4 selftest inventory.
- file: AGENTS.md §1–§3, §6
  why: isolated sandbox mandate, timeout-wrap everything, reap everything, hygiene
    checklist before ending the turn.
- file: plan/004_de5e94ac127c/P4M2T1S1/research/ (…S2, S3, S4)
  why: owning subtasks' PRPs define the new selftests — the scope within which any
    failure fix must stay.
- file: plan/004_de5e94ac127c/P4M2T2S1/PRP.md, plan/004_de5e94ac127c/P4M2T2S2/PRP.md
  why: PARALLEL siblings touching test/concurrency.sh ONLY — out of scope here. This
    item validates validate.sh ONLY; concurrency/release_reaper/transparency are the
    NEXT item (P4.M2.T3.S2). Do not run those suites in this item.
```

### Current Codebase tree (relevant)

```bash
test/validate.sh     # SUT — execute mode runs all selftest_* bodies, single setup()
lib/pool.sh          # SUT internals (sourced by validate.sh) — static-check target
install.sh           # static-check target (per item contract)
plan/004_de5e94ac127c/P4M2T3S1/research/   # OUTPUT: validate_full_run.log, static_checks.log
```

### Known Gotchas of our codebase & Library Quirks

- **G1 — never run live suites against the operator's real HOME.** validate.sh's own
  setup() redirects everything, so the bare invocation IS hermetic — but do not
  "helpfully" pre-set AGENT_BROWSER_POOL_STATE or AGENT_CHROME_EPHEMERAL_ROOT; that
  could point somewhere real.
- **G2 — `timeout 120` is mandatory** even though the suite is Chrome-free; a wedged
  flock/`wait` must die at 120 s, not hang the session (AGENTS.md §2).
- **G3 — pipe rc**: `… | tee log` reports tee's rc. Check `${PIPESTATUS[0]}` for the
  suite's real rc (script runs `set -euo pipefail`, exits rc 1 on any failure).
- **G4 — set -e hygiene in any ad-hoc shell glue**: `pgrep`/`ls` return 1 when nothing
  matches — always `|| true` / `|| echo` guard them, or your audit command aborts.
- **G5 — the suite boots NO Chrome**: if a run hangs or shows chrome processes, that is
  a bug in a selftest (e.g. a body that leaked a launch) — treat as a failure to fix in
  the owning subtask's scope, not something to background.
- **G6 — `kill -0` is a trap** (AGENTS.md §4): never use it in glue; the suite's
  helpers already use /proc-aware liveness.

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: RECORD static checks
  - RUN: bash -n + shellcheck -s bash on lib/pool.sh, install.sh, test/validate.sh
  - WRITE: plan/004_de5e94ac127c/P4M2T3S1/research/static_checks.log (zero output = pass)

Task 2: CAPTURE the selftest manifest + additivity proof
  - RUN: grep -n '^selftest_' test/validate.sh
  - RUN: git log --oneline -- test/validate.sh; git diff <pre-P4.M2-commit> HEAD -- test/validate.sh
    → confirm only additive bodies since P4.M2.T1 baseline (no pre-existing body modified)
  - APPEND notes to research/notes.md

Task 3: RUN the full suite (isolated sandbox, bounded)
  - RUN: timeout 120 bash test/validate.sh 2>&1 | tee research/validate_full_run.log
  - ASSERT: rc 0 (PIPESTATUS[0]), "0 failed", all manifest names appear as passes

Task 4: (conditional) FIX failures in owning subtask scope → re-run Task 3 to green
  - NEVER weaken asserts; never touch framework helpers (setup/run_test/assert_*)
  - If a failure indicates a lib/pool.sh behavioral bug, fix the code — that's the point

Task 5: HYGIENE audit + wrap-up
  - RUN guarded pgrep/ls orphan checks; record in notes.md
```

### Validation Loop

Level 1/2/3 are literally Tasks 1–5 above; there is no Level 4 for this item (no new
code surface). The full-suite green log IS the deliverable.

## Final Validation Checklist

- [ ] Static: zero warnings on lib/pool.sh, install.sh, test/validate.sh
- [ ] Live: `timeout 120 bash test/validate.sh` → rc 0, 0 failed (log recorded)
- [ ] All four P4.M2.T1 selftest families green and present in the log
- [ ] Pre-existing selftests byte-untouched (git diff proof)
- [ ] Logs at plan/004_de5e94ac127c/P4M2T3S1/research/{validate_full_run.log,static_checks.log}
- [ ] Zero orphans / leftover temp dirs (`pgrep` + `/tmp` audit clean)
- [ ] No changes to validate.sh framework, lib/, bin/, docs (unless a genuine failure
      fix was required, confined to owning-subtask scope)

## Anti-Patterns to Avoid

- ❌ Never run the suite (or any live check) outside an isolated sandbox / without
  `timeout` (AGENTS.md §1–§2).
- ❌ Never make a failing test pass by weakening/deleting asserts or editing framework
  helpers (`setup`, `run_test`, `_fail`, assertion helpers, `_run_selftest_suite`).
- ❌ Never pre-set env overrides for the "blessed" run — it must pass bare.
- ❌ Don't run the other suites (concurrency/release_reaper/transparency) — that's
  P4.M2.T3.S2.
- ❌ Don't leave a hung process because "it should finish" — kill it at 120 s.

## Confidence Score

9/10 — this is a validation-only item; the suite, its hermetic setup, the blessed
invocation, and the selftest inventory are all already verified in-repo (synthesis.md
§3, test_framework.md). The only contingency path (fix-in-owning-scope on failure) is
explicitly bounded.