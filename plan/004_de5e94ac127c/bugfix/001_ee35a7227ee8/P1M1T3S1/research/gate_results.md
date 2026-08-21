# Major-fix integration gate — P1.M1.T3.S1

- **Date**: 2026-08-20
- **HEAD**: `5cc6c24`
- **Tree status at start**: ` M plan/004_.../bugfix/001_ee35a7227ee8/tasks.json` (orchestrator-owned; predates the gate), `?? plan/.../P1M1T3S1/` (this gate's output dir). No source/test files modified.
- **Preflight (Task 0)**: PASS
  - `r3_neg_dead_ids_release_still_kills` present in `test/bootrace.sh` (line 349 def, line 473 runner list) → T2.S4 landed.
  - `pool_lane_boot_lock` in `lib/pool.sh`: 9 matches (≥2 required) → T2.S2 landed.
  - Widened `(3b)` gate comment present at `lib/pool.sh:2146` → S4 sweep landed.
  - **Bootrace case-list snapshot** (for P1.M3.T1.S1 to diff after R5–R9 land):
    1. `r1_bug001_guard_fs_agnostic`
    2. `r2_bug001_recovery_e2e`
    3. `r3_control_delayed_boot_succeeds`
    4. `r3_bug002_race_e2e`
    5. `r3_neg_dead_ids_release_still_kills`
    6. `r4_bug002_preport_race`

## Summary table

| suite | expected | got | rc | verdict |
|-------|----------|-----|----|---------|
| bootrace (R1–R4 + control + S4 neg-control) | 6 cases, 0 failed | 6 passed, 0 failed | 0 | PASS |
| validate | 33/33 | 33 passed, 0 failed | 0 | PASS |
| release_reaper | 5/5 | 5 passed, 0 failed | 0 | PASS |
| transparency | 10/10 | 10 passed, 0 failed | 0 | PASS |
| concurrency | 3/3 | 3 passed, 0 failed | 0 | PASS |
| static (bash -n + shellcheck -S warning, 4 files) | clean | clean (all 4 OK) | 0 | PASS |
| leak sweep — processes | 0 orphans | 0 (pgrep self-match only) | — | PASS |
| leak sweep — temp roots | 0 roots | 98 `/tmp/fake-cdp.*` dirs leaked | — | **FINDING (F1)** |

## Per-case results

### bootrace (`bootrace.log`)
```
== r1_bug001_guard_fs_agnostic          PASS
== r2_bug001_recovery_e2e               PASS
== r3_control_delayed_boot_succeeds     PASS
== r3_bug002_race_e2e                   PASS
== r3_neg_dead_ids_release_still_kills  PASS
== r4_bug002_preport_race               PASS
6 passed, 0 failed
```
Level-4 repro-fidelity grep: all four BUG-001/BUG-002 repro cases (`r1_bug001`, `r2_bug001`, `r3_bug002_race_e2e`, `r4_bug002_preport`) plus the S4 negative-control show `== <case>` followed by PASS — both major repros are exercised green.

### validate (`validate.log`) — `33 passed, 0 failed`, rc 0
Note: log line 4 contains `FAIL: assert_eq (intentional mismatch): expected [abc] got [xyz]` — this is the *expected output* of validate's own assert_eq self-test case (a passing case printing a FAIL-shaped string), not a failing case; the summary line and rc 0 confirm.

### release_reaper (`release_reaper.log`) — `5 passed, 0 failed`, rc 0
### transparency (`transparency.log`) — `10 passed, 0 failed`, rc 0
### concurrency (`concurrency.log`) — `3 passed, 0 failed`, rc 0

### static (`static.log`)
```
lib/pool.sh             bash -n: OK   shellcheck: OK
bin/agent-browser-pool  bash -n: OK   shellcheck: OK
test/bootrace.sh        bash -n: OK   shellcheck: OK
install.sh              bash -n: OK   shellcheck: OK
```

## Findings

### F1 (LEAK — temp roots, informational for upstream): the repo suites leave `/tmp/fake-cdp.*` dirs behind
- After Tasks 1–2, 98 `/tmp/fake-cdp.*` directories were present, ALL created within the gate's run window (timestamps span 22:06–22:56, exactly the five suite invocations; the oldest coincides with the bootrace start). They are unambiguously this gate's test artifacts (fake-cdp fixture sandboxes), not sibling-session state.
- **No processes** were found holding them (all six test-scoped pgrep patterns empty; the only pgrep "hits" were the sweep script matching its own cmdline — pid excluded on re-check).
- Per AGENTS.md §3 the gate cleaned them (`rm -rf /tmp/fake-cdp.*`; post-clean `ls` confirms zero remain). This is observational discipline for the gate itself, NOT a fix: **a suite-side trap is evidently not removing its fake-cdp temp roots on some path** (likely a fake-CDP fixture whose EXIT trap fires in a subshell, AGENTS.md §4 hazard). No `$HOME/abpool-bootrace.*` roots were left (bootrace teardown clean); no `/tmp/abpool-*` roots.
- **Owning subtask**: T2.S1 (bootrace harness) / suite fixture owners — recommend a minor-fix item in P1.M2.

No other findings. Zero FAIL cases, zero hangs, zero process leaks, zero source/test edits (`git status --short` before vs after the gate identical except this research/ dir).

## Verdict

**GATE GREEN** — all five suites green at PRD h2.0 expected counts (bootrace 6/6, validate 33/33, release_reaper 5/5, transparency 10/10, concurrency 3/3), static checks clean on all 4 changed files, zero process leaks. One non-blocking finding (F1: suite-side fake-cdp temp-root leak) recorded for P1.M2 triage. The BUG-001 and BUG-002 major fixes hold.