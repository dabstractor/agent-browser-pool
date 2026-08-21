# Research — P1.M3.T1.S1: Final changeset regression gate (the complete matrix)

**Plan:** 004_de5e94ac127c/bugfix/001_ee35a7227ee8 · **Item:** P1.M3.T1.S1 (verification-only)
**Method:** static reads + git inspection only (AGENTS.md §1 — no suites launched during planning).

---

## 1. The direct precedent — P1.M1.T3.S1 (the MAJOR-fix gate, Complete)

`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/` ran this exact procedure for the M1 half
(bootrace R1-R4 + 4 repo suites + 4-file statics + leak sweep). Its `research/gate_results.md` is
the output FORMAT to mirror: preamble (date, HEAD sha, tree status, preflight, case-list snapshot)
→ summary table (suite | expected | got | rc | verdict) → per-case results (verbatim log tails) →
findings → verdict. Its PRP's Task structure (preflight → run suites under `timeout` → statics →
zero-orphan sweep → write record) is the procedure skeleton; **THIS gate extends it**: 9-file
statics (was 4), R1-R9 (was R1-R4), + the plan validate.sh FULL run (new), and it is the FINAL gate
(the record P1.M3.T2 cites).

## 2. Working-tree state observed (2026-08-20 ~23:30 — mid-parallel-item)

- HEAD = `1bbc3d0` (M2.T2.S1 doctor fix). Committed through M2.T2.S1.
- **Uncommitted**: `M lib/pool.sh` (the BUG-005 help fix IS present:
  `AGENT_BROWSER_POOL_HARNESSES … replaces the default pi,claude,codex,agy,antigravity;
  empty/unset -> default` at ~5214), `M test/bootrace.sh` (+36 lines = the
  `r8_bug005_help_harnesses_contract` case, present AND in the runner list), `M
  plan/004_de5e94ac127c/validate.sh` (ROOT fix present: `…/../../..`→ wait, exactly
  `dirname …/../..` + usage comment), `M tasks.json` (orchestrator-owned — never touch).
- **P1.M2.T3.S1 is marked FAILED** in the plan tree, yet its artifacts (help lines + r8) ARE in
  the working tree. **Preflight by CONTENT, not by task status** — grep for the fix and the case.
- **P1.M2.T4.S1 (parallel, Implementing)**: per its PRP it delivers (a) the validate.sh ROOT
  one-line fix (ALREADY in tree) and (b) **`r9_…` in test/bootrace.sh** (NOT yet present — runner
  list currently ends at r8). Its own success def is the `--fast` run green; **the FULL 88+/0 run
  is explicitly THIS task's responsibility** (its PRP says so verbatim).

## 3. The matrix — exact expectations

### (a) Statics — 9 files
`bash -n` + `shellcheck -s bash -S warning` on: `lib/pool.sh`, `bin/agent-browser-pool`,
`install.sh`, `test/validate.sh`, `test/release_reaper.sh`, `test/transparency.sh`,
`test/concurrency.sh` (the QA-time "7 shell files"), **plus** `test/bootrace.sh` and
`plan/004_de5e94ac127c/validate.sh`. Expect zero output / rc 0 for all 9. (QA h2.0: the 7 were
clean at HEAD; the changeset's touched files — pool.sh, bootrace.sh, plan validate.sh — must stay
clean; sweeping all 9 is cheap and closes the set.)

### (b) test/bootrace.sh — R1-R9, expect **11 cases, 0 failed**
Case list (verified in tree + r9 per the parallel contract): `r1_bug001_guard_fs_agnostic`,
`r2_bug001_recovery_e2e`, `r3_control_delayed_boot_succeeds`, `r3_bug002_race_e2e`,
`r3_neg_dead_ids_release_still_kills`, `r4_bug002_preport_race`, `r5_bug003_corrupt_lease_reclaimed`,
`r6_bug003_release_corrupt_lease`, `r7_bug004_doctor_fresh_install`,
`r8_bug005_help_harnesses_contract`, `r9_…` (name fixed by the parallel item — read its PRP/grep).
Runner = `_br_run_suite` hardcoded `for fn in …` list; per-case lines print `== <name>` then
`   PASS`/`   FAIL`; final line `N passed, M failed`; rc 0 iff all pass. Invoke:
`timeout 300 bash test/bootrace.sh` from repo root (it self-isolates: mktemp sandbox, redirected
HOME/state/ephemeral/master, fakes, EXIT trap). **Count drift = finding** (e.g. 10 cases means r9
hasn't landed → gate blocked on the parallel item; record precisely, never run a half set).

### (c) The 4 repo suites — expected **33 / 5 / 10 / 3**
From repo root, each under `timeout` (M1T3S1 precedent): `timeout 600 bash test/validate.sh`,
`timeout 300 bash test/release_reaper.sh`, `timeout 300 bash test/transparency.sh`,
`timeout 300 bash test/concurrency.sh`. Grep each log's `passed/failed` tail; record the exact
line. rc 0 + exact expected count = PASS. rc 0 with a DIFFERENT count = FINDING (drift), not a
pass. NOTE: validate.sh's log contains an **intentional** `FAIL: assert_eq (intentional
mismatch)` line — that is validate's own self-test passing (M1T3S1 documented this); the summary
line + rc are the verdict.

### (d) plan/004_de5e94ac127c/validate.sh — FULL run from repo root
`timeout 1800 bash plan/004_de5e94ac127c/validate.sh` (from repo root; the script now cds itself).
Expect **zero `No such file or directory` / rc-127 failures** and a green summary —
**`passed: 88 failed: 0` or better** (the BUG-006 reproducibility promise; the prior committed
state failed 64/89 on paths). `--fast` (timeout 900) ONLY if the environment genuinely forbids
the real-Chrome phases — and then RECORD the deviation as a finding, not silently. The script
self-isolates (its header: sandbox + redirects + kills fake Chromes/sim owners + removes the
sandbox; suites only run when prerequisites exist).

### (e) Zero-orphan leak sweep — test-scoped patterns, NEVER blanket-pkill
M1T3S1's exact pattern set (proven; disambiguates from the OPERATOR's real agent-browser/Chrome):
`pgrep -af 'abpool-bootrace'`, `'fake-cdp'`, `'fakechrome'`, `'FAKE_CHROME'`,
`"user-data-dir=.*bootrace"`, `'user-data-dir=/tmp/tmp\.'` → every pattern empty. Temp roots:
`ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-* /tmp/fake-cdp.* 2>/dev/null` → none (NOTE: sibling
pi-session `/tmp/tmp.*` dirs are NOT ours). **KNOWN F1 (from the prior gate): the suites leak
`/tmp/fake-cdp.*` dirs (98 last time) — re-check; if present they are this gate's to CLEAN
(`rm -rf /tmp/fake-cdp.*`) + re-record as a recurring finding, attributed to the suite fixtures.**
A bare `pgrep -af chrome` WILL match the operator's real browser — use ONLY the test-scoped
patterns above; if a hit's argv unambiguously references a sandbox temp path → kill its process
GROUP (`kill -- -<pgid>` then `-9`) + `wait` + re-check + record; if it might be the operator's →
RECORD ONLY, never kill. Also: `pgrep -af 'sleep'` is too broad — scope to sandbox paths.

## 4. AGENTS.md hard rules for this gate (§1-§4, §6)

- Real suites ONLY in an isolated context — the suites self-isolate (temp trees + redirects);
  run them EXACTLY as shipped (`bash test/<suite>.sh`); **do NOT restore any per-test runner**
  and **do NOT run any framework self-test that spawns setup per case** (the validate.sh suite
  self-test is fine — it is assert-helpers only).
- `timeout` on EVERY invocation (incl. the gate's own `pgrep`/`ls` sweep — cheap, but bounded).
- Reap what you spawn; zero orphans before returning; trap-clean the gate's own temp files.
- **Never weaken an assertion to close the changeset** — a failure is recorded verbatim and the
  verdict says FAIL; fixes belong to their owning subtask, not the gate.
- Do NOT edit `plan/…/tasks.json`, `plan/…/validation_report.md`, or any `prd_*` file
  (orchestrator-owned). If the fresh validate.sh summary differs from validation_report.md,
  NOTE the numbers in the record — do not edit plan/ artifacts.

## 5. Output contract (what P1.M3.T2 cites)

`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T1S1/research/`:
- `gate_results.md` — THE record: preamble (date, HEAD sha, `git status -s` snapshot, preflight
  results, bootrace case-list snapshot), summary table (statics | bootrace | 4 suites | plan
  validate.sh | process sweep | temp-roots sweep), per-case verbatim extracts, findings (F#…),
  verdict line.
- Raw logs: `static.log`, `bootrace.log`, `validate.log`, `release_reaper.log`,
  `transparency.log`, `concurrency.log`, `planvalidate.log`, `sweep.log`.

## 6. Preflight checks (content-based — do not gate a half-applied fix set)

1. `grep -n 'replaces the default pi,claude,codex,agy,antigravity' lib/pool.sh` → ≥1 (BUG-005 fix landed).
2. `grep -n 'r8_bug005_help_harnesses_contract' test/bootrace.sh` → ≥2 (def + runner list).
3. `grep -n 'dirname "$(readlink -f "${BASH_SOURCE\[0\]}")"/\.\./\.\.' plan/004_de5e94ac127c/validate.sh`
   → ≥1 (BUG-006 ROOT fix landed).
4. `grep -cE '^r9_[a-z0-9_]+\(\)' test/bootrace.sh` → ≥1 AND `grep -n 'r9_' <runner for-list>` →
   present (parallel P1.M2.T4.S1 landed). If ANY of 1-4 is ABSENT → record "gate blocked:
   <missing artifact> (owning subtask)" in gate_results.md and STOP — do not run the matrix
   against a half-applied changeset (M1T3S1 precedent).
5. Record `git rev-parse --short HEAD` + `git status -s` + the full bootrace case list.