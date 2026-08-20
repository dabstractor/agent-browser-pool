# P4.M2.T3.S2 notes — Real-Chrome suites + leak audit

## Results

| Suite | Invocation | rc | Summary |
|---|---|---|---|
| test/concurrency.sh | `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh` | 0 | 3 passed, 0 failed |
| test/release_reaper.sh | `AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh` | 0 | 5 passed, 0 failed |
| test/transparency.sh | `AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh` | 0 | 10 passed, 0 failed (after fix below) |

All bodies present in the logs match the `grep -n '^test_'` manifests:
- concurrency.sh: test_n_agents_get_n_distinct_lanes, test_caller_mode_children_get_distinct_lanes,
  test_n_provisional_lanes_are_distinct (E2E caller-mode body from P4.M2.T2.S2 was present and green).
- All 10 transparency bodies + 5 reaper bodies PASS individually.

## install.sh (R6)

`bash -n install.sh` OK; `shellcheck -s bash install.sh` → only SC1091 (info, not-following
sourced file — pre-existing/acceptable per PRP). `git status --porcelain install.sh` empty and
`git diff --stat install.sh` vs HEAD is empty → untouched. Proof in `install_static.log`.

## Leak audit

Per-suite + final audits in `leak_audit.log`:
- No abpool/test-attributable processes after any suite or at the end.
- Zero `/tmp/abpool-test.*` and `/tmp/abpool-pi.*` trees (trap glob backstops worked — nothing
  pre-deleted before runs, per G8).
- Baseline snapshot in `baseline_pids.txt` (40 processes: operator's 2 Chrome lanes on
  ~/.agent-chrome-profiles/active/{1,2}, ports 53420/53421, plus crashpads/Brave etc.).
- Initial pgrep diff after concurrency.sh showed net-new chrome renderers + `sleep 5`/`sleep 0.5`:
  attributed to the OPERATOR — renderers are children of the baseline lanes (same user-data-dirs /
  ports); the sleeps churn under persistent bash ppids 1891/1893 (operator polling loops, new pid
  every 5 s; earlier pids exited during verification). Operator lanes still healthy at final audit.
  → VERDICT: no leaks attributable to these runs.

## Failure fixed (owning scope: suite file itself, per PRP Task 6)

First transparency.sh run: 8 passed, 2 failed —
`test_skills_fail_fast_no_pi` and `test_version_fail_fast_no_pi` asserted the stale pool_die
substring `"pi ancestor"`. Production (lib/pool.sh:3782, pool_wrapper_main step d) had its
message broadened by the M2 caller-scoped work to "driving commands require a supported agent
harness (pi/claude/codex/agy)" (commit "List supported harnesses in fail-fast message"); the
sibling body `test_driving_no_pi_ancestor_fails_fast` had already been updated to assert
`"supported agent harness"` but the shared helper `_transparency_assert_driving_no_pi_fails_fast`
(used by exactly those two bodies) was missed.

Fix: updated the helper's expected substring to `"supported agent harness"` (fail-fast still
strictly asserted; same mechanism: setsid --fork detach + env -u + bounded poll) and refreshed
the two stale comments. No assert weakened, no validate.sh framework code touched, no
production code changed. Re-run: 10 passed, 0 failed, rc 0.

## AGENTS.md §6 checklist

- No processes from these runs still running (verified via guarded pgrep audits).
- No temp roots left under /tmp.
- All live runs were timeout-bounded (240/300/180) and reaped by the suites' own traps.
- Static checks (bash -n/shellcheck) used for everything else.

## Artifacts

concurrency_run.log, release_reaper_run.log, transparency_run.log, install_static.log,
leak_audit.log, baseline_pids.txt, notes.md (this file).