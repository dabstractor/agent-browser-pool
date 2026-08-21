# PRP — P1.M3.T1.S1: Run the complete matrix in an isolated sandbox and record the summary

> **Bugfix context**: This is the **FINAL changeset regression gate** for bugfix 001
> (`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/` — BUG-001..BUG-006). Every implementing
> subtask has landed or is landing in parallel: guarded copy (M1.T1.S1), bootrace harness (M1.T2.S1),
> per-lane boot lock (M1.T2.S2), ensure_connected hardening (M1.T2.S3), sweep widening (M1.T2.S4),
> corrupt-lease reap/release (M2.T1.S1/S2), doctor fix (M2.T2.S1), help fix (M2.T3.S1), validate.sh
> ROOT fix (M2.T4.S1 — **IN PARALLEL**, treated as a CONTRACT below). This task executes the
> complete matrix once, in order, and records PASS/FAIL per item. **It is verification ONLY**: no
> source/test/doc edits, no assertion weakening; a failure is recorded precisely and the verdict
> says so. The record (`research/gate_results.md`) is the artifact **P1.M3.T2's doc sync cites** —
> this gate is what P1.M3.T2 depends on.
>
> **Direct precedent**: P1.M1.T3.S1 (the MAJOR-fix gate, Complete) ran this same procedure for the
> M1 half. Mirror its `research/gate_results.md` format exactly (preamble → summary table →
> per-case results → findings → verdict); its PRP's task structure is the skeleton. THIS gate
> widens it: 9-file statics (was 4), R1-R9 (was R1-R4+controls), plus the plan validate.sh FULL
> run (new — M2.T4.S1's PRP explicitly defers the full green run to this task).

---

## Goal

**Feature Goal**: Execute the complete changeset validation matrix — (a) static checks on all 9
shell files, (b) `test/bootrace.sh` R1-R9, (c) the 4 repo suites at their expected counts
(33/5/10/3), (d) `bash plan/004_de5e94ac127c/validate.sh` (FULL run from repo root — the BUG-006
reproducibility promise: zero rc-127/path failures, `passed: 88 failed: 0` or better), (e) a
zero-orphan leak sweep — and record a precise, per-item PASS/FAIL summary that P1.M3.T2 cites.
Any failure anywhere is REPORTED precisely — never weakened, never fixed in-flight (fixes belong
to their owning subtask).

**Deliverable**: `plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T1S1/research/` containing
`gate_results.md` (THE record) + raw logs (`static.log`, `bootrace.log`, `validate.log`,
`release_reaper.log`, `transparency.log`, `concurrency.log`, `planvalidate.log`, `sweep.log`).

**Success Definition**:
- Preflight confirms every changeset artifact is present (content-greps, §Task 0). If any is
  absent → the record says "gate blocked: \<artifact\> (owning subtask)" and the gate STOPS
  (never run a half-applied matrix).
- All matrix items executed and logged verbatim; the summary table has a row per item with
  expected vs got vs rc vs verdict.
- Verdict: **GATE GREEN** iff statics 9/9 clean, bootrace 11/11 (R1-R9 + 2 controls), suites
  33/5/10/3 exact (count drift = finding even when rc 0), plan validate.sh full run
  `passed: 88 failed: 0` or better with zero path failures, zero orphan processes, zero leftover
  test temp roots. Otherwise the verdict is GATE RED / PARTIAL with the precise findings.
- Zero source/test/doc modifications from the gate itself (`git status --short` before vs after
  identical except this `research/` dir). Zero orphan processes on return (AGENTS.md §6).

## User Persona

**Target User**: The orchestrator + P1.M3.T2 (the doc-sync task that cites these numbers) + any
future reader auditing the changeset. Internal verification — no operator surface.

**Use Case**: The changeset claims BUG-001..006 fixed. This gate is the single authoritative
record that the complete matrix passes at the final tree — per-suite counts, the validate.sh
summary line, and any findings — so the changeset can close and the docs can cite real numbers.

**Pain Points Addressed**: The prior committed validation artifact was path-broken (BUG-006 —
64/89 checks failed as shipped); this gate proves the reproducibility promise ("passed: 88
failed: 0" or better, run from the repo root as committed). It also catches cross-subtask
regressions the per-subtask gates (each scoped to their own cases) cannot see.

## Why

- **The changeset needs one final, complete, reproducible record.** Each subtask validated its own
  slice; only this gate runs everything together at the final tree (e.g. R8's help-contract check
  and the plan validate.sh full run have never both run in one recorded pass).
- **BUG-006's promise must be demonstrated, not assumed.** The committed validate.sh was
  path-broken; M2.T4.S1 fixed the bootstrap, but the FULL green run is explicitly this task's
  responsibility (its PRP defers it here). The record proves `passed: 88 failed: 0` or better.
- **Regression detection across the whole set.** The minor fixes touched reap/release/doctor/help;
  the 4 repo suites (33/5/10/3) guard the pre-existing guarantees; only a full-matrix run can show
  nothing regressed. Expected counts are contractual — drift is a finding even when rc 0.
- **AGENTS.md exit discipline.** The leak sweep proves the changeset's suites leave zero orphans
  (and re-checks the known F1 `/tmp/fake-cdp.*` leak from the M1 gate).

## What

Verification-only. The matrix, in execution order (each step logs to `research/`):

| # | Item | Expected | Drift/failure handling |
|---|---|---|---|
| a | `bash -n` + `shellcheck -s bash -S warning` on 9 files: `lib/pool.sh`, `bin/agent-browser-pool`, `install.sh`, `test/{validate,release_reaper,transparency,concurrency,bootrace}.sh`, `plan/004_de5e94ac127c/validate.sh` | zero output, rc 0 × 9 | any finding = FAIL row + verbatim output |
| b | `timeout 300 bash test/bootrace.sh` | **11 cases, 0 failed** (r1, r2, r3_control, r3, r3_neg, r4, r5, r6, r7, r8, r9), rc 0 | wrong count = finding; any FAIL case recorded verbatim; hang (rc 124) → sweep first, record as HANG, one bounded retry |
| c | `timeout 600 bash test/validate.sh`; `timeout 300 bash test/{release_reaper,transparency,concurrency}.sh` | **33 / 5 / 10 / 3** passed, 0 failed, rc 0 each | count drift = finding even if rc 0 |
| d | `timeout 1800 bash plan/004_de5e94ac127c/validate.sh` from repo root (FULL run) | zero `No such file or directory`/rc-127; summary `passed: 88 failed: 0` or better | `--fast` ONLY if the environment forbids real-Chrome phases → record the deviation as a finding |
| e | Leak sweep (test-scoped pgrep patterns + temp-root ls) | zero orphans; zero leftover roots | hits: reap unambiguous sandbox procs (kill process GROUP); record-only if ambiguous; re-check |

### Success Criteria

- [ ] Preflight (Task 0) passes for ALL artifacts: help fix text in `lib/pool.sh`, `r8_…` case +
      runner entry in `test/bootrace.sh`, ROOT `../..` fix in `plan/…/validate.sh`, `r9_…` case +
      runner entry in `test/bootrace.sh` (parallel contract). Any absence → "gate blocked" record
      + STOP.
- [ ] Statics: 9/9 files `bash -n` + `shellcheck -s bash -S warning` clean (recorded per file).
- [ ] bootrace: final line `11 passed, 0 failed`, rc 0; every `== <case>` shows PASS; R1-R9 all
      present (any missing case number = finding).
- [ ] Suites: exact tails `33 passed, 0 failed`, `5 passed, 0 failed`, `10 passed, 0 failed`,
      `3 passed, 0 failed`, rc 0 each — exact expected counts (drift = finding).
- [ ] plan validate.sh: full run, zero `No such file or directory` failures, summary
      `passed: 88 failed: 0` or better; rc 0. (`--fast` only as documented fallback + finding.)
- [ ] Leak sweep: all test-scoped pgrep patterns empty; no `$HOME/abpool-bootrace.*`, `/tmp/abpool-*`,
      `/tmp/fake-cdp.*` roots (F1 re-check — if present: clean them, record as recurring finding).
- [ ] `gate_results.md` written: preamble (date, HEAD sha, tree status, preflight, case-list
      snapshot) + summary table + per-case verbatim extracts + findings (F#…) + verdict line.
- [ ] No file outside this task's `research/` dir modified by the gate; zero orphans on return.
- [ ] If the fresh validate.sh summary differs from `plan/004_de5e94ac127c/validation_report.md`,
      the numbers are NOTED in the record — plan/ artifacts are orchestrator-owned (never edited).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed?"** → Yes. This
PRP enumerates: the exact matrix items with exact commands/timeout budgets/expected outputs; the
content-based preflight greps (incl. the parallel-item wrinkle and the FAILED-but-present help
fix); the M1T3S1 precedent (output format + procedure skeleton + its known quirks: validate.sh's
intentional FAIL-shaped self-test line, the F1 fake-cdp leak); the AGENTS.md isolation/reap rules;
the operator-process disambiguation rule for the sweep; and the exact output file contract.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  why: §1 (the approved single-setup runner pattern + suite invocation + "expected green counts
        are printed per suite"), §4 (the R1-R9 regression matrix — each case's name and contract),
        §5 (the per-test safety checklist the suites must satisfy — the gate checks the RESULT,
        never re-implements it). CRITICAL: "Do NOT restore any per-test runner, do NOT run any
        framework self-test that calls a spawning setup once per case" (AGENTS.md §4).
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: §11 (house style: timeouts everywhere, kill process groups, never kill -0, pool_die not
        catchable by || true) — the sweep/reap discipline follows this.
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/PRP.md
  why: the DIRECT PRECEDENT — the M1 gate's exact task structure (preflight → suites under
        timeout → statics → zero-orphan sweep → write record) and the stop-if-half-applied rule.
        THIS gate widens it (9 statics, R1-R9, plan validate.sh full run).
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/gate_results.md
  why: the output FORMAT to mirror: preamble → summary table → per-case results → findings →
        verdict. Also its two known quirks this gate will re-encounter: (1) test/validate.sh's log
        contains an INTENTIONAL `FAIL: assert_eq (intentional mismatch)` line (its own self-test
        PASSING — the summary line + rc are the verdict, do not misread it); (2) FINDING F1 — the
        suites leaked 98 /tmp/fake-cdp.* temp-root dirs (no processes held them) → this gate
        re-checks, cleans, and records whether it recurs.
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M2T4S1/PRP.md   # parallel — CONTRACT
  why: P1.M2.T4.S1 (Implementing in parallel) delivers the validate.sh ROOT fix
        (`ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"`) and the
        `r9_…` case in test/bootrace.sh. Its PRP says the FULL green run "is P1.M3.T1.S1's
        responsibility, not this item's" — i.e. THIS gate. Preflight greps for BOTH artifacts; if
        r9 is absent the gate is BLOCKED on the parallel item (record + stop), because the item
        contract expects R1-R9.
  gotcha: do NOT add r9 yourself or edit validate.sh — that is the parallel item's file.

- file: plan/004_de5e94ac127c/validate.sh
  why: the artifact under validation (item d). Header documents self-isolation (sandbox +
        redirects + kills fake Chromes/sim owners + removes the sandbox) and `--fast` semantics.
        Expected: zero `No such file or directory` and `passed: 88 failed: 0` or better from the
        repo root (the BUG-006 promise; the pre-fix committed state failed 64/89 on paths).
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T1S1/research/gate-matrix-findings.md
  why: THIS task's research note — the current working-tree state (help fix + r8 present but
        uncommitted; r9 pending; HEAD 1bbc3d0), the exact expectations table, the leak-sweep
        pattern set, the AGENTS.md rules, and the output contract.
- file: AGENTS.md
  why: §1-§4 + §6 — isolation, timeouts, reaping, no per-test runners, the pre-return checklist.
        This gate RUNS the real suites (self-isolating by design); the gate itself spawns nothing
        beyond the suites and must leave zero orphans + zero temp roots.

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: the gate's own runner snippets use `set +e` around `timeout … ; rc=$?; set -e` capture —
        the rc of a failing suite must be RECORDED, not abort the gate (errexit discipline).
- url: https://github.com/koalaman/shellcheck/wiki/SC2148
  why: shellcheck invocation (`-s bash -S warning`) — matches the M1T3S1 precedent exactly.
```

### Current Codebase tree (relevant subset)

```bash
agent-browser-pool/                       # HEAD 1bbc3d0 + uncommitted: lib/pool.sh (help fix),
├── lib/pool.sh                           #   test/bootrace.sh (r8), plan validate.sh (ROOT fix)
├── bin/agent-browser-pool                # ┐
├── install.sh                            # │ the 7 QA-time shell files
├── test/{validate,release_reaper,        # │  (lib, bin, install + 4 suites)
│         transparency,concurrency}.sh    # ┘
├── test/bootrace.sh                      # + the changeset's new suite (r1..r8 landed; r9 parallel)
└── plan/004_de5e94ac127c/
    ├── validate.sh                       # + the validation artifact (ROOT fix landed)
    ├── validation_report.md              # orchestrator-owned — READ ONLY (note diffs, never edit)
    └── bugfix/001_ee35a7227ee8/
        ├── architecture/{test_framework,system_context,fix_design}.md
        ├── P1M1T3S1/research/gate_results.md   # the format precedent
        └── P1M3T1S1/                     # THIS task — writes ONLY research/ below it
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (parallel-item coordination): P1.M2.T4.S1 is Implementing IN PARALLEL and owns
# test/bootrace.sh's r9 case + plan validate.sh's ROOT line. Do NOT edit either file. Preflight
# greps for the artifacts; if r9 (or any preflight item) is absent → record "gate blocked:
# <artifact> (owning subtask: …)" + STOP. Never gate a half-applied fix set (M1T3S1 rule).

# CRITICAL (FAILED-task wrinkle): P1.M2.T3.S1 (help fix) is marked FAILED in the plan tree, but
# its artifacts (the two help printf lines + the r8 case + runner entry) ARE present in the
# working tree (uncommitted). VERIFY BY CONTENT (grep), not by task status. If the greps pass,
# R8 runs like any other case; if R8 FAILs at runtime, record it verbatim as a finding — never
# weaken R8's assertions to close the changeset.

# CRITICAL (validate.sh's intentional FAIL line): test/validate.sh's log contains
# `FAIL: assert_eq (intentional mismatch): expected [abc] got [xyz]` — that is validate's OWN
# self-test case PASSING (a passing case printing a FAIL-shaped string). The summary line + rc 0
# are the verdict. Do not misread it as a suite failure (M1T3S1 documented this).

# CRITICAL (operator-process disambiguation): a bare `pgrep -af chrome` / `pgrep -af
# agent-browser` / `pgrep -af sleep` WILL match the OPERATOR's real browser/daemon/terminal —
# NEVER kill those. Use ONLY the test-scoped patterns (§Task 5): 'abpool-bootrace', 'fake-cdp',
# 'fakechrome', 'FAKE_CHROME', "user-data-dir=.*bootrace", 'user-data-dir=/tmp/tmp\.'. If a hit's
# argv unambiguously references a sandbox temp path → kill its process GROUP (`kill -- -<pgid>`
# then `kill -9 -- -<pgid>`, then `wait`), re-check, record. Ambiguous → RECORD ONLY.

# CRITICAL (KNOWN F1 — recurring leak): the M1 gate found 98 /tmp/fake-cdp.* dirs left by the
# suites (no processes held them; a suite fixture's trap evidently fires in a subshell). This
# gate re-checks after all runs; if present: `rm -rf /tmp/fake-cdp.*` (they are unambiguously
# test artifacts), verify zero remain, record as "F1 recurs" attributed to the suite fixtures.
# Sibling-session `/tmp/tmp.*` dirs are NOT ours — never touch them.

# GOTCHA (suite count drift is a FINDING, not a pass): expected counts are contractual
# (33/5/10/3; bootrace 11). rc 0 with a different count = drift finding (record expected vs got).
# bootrace showing 10 cases means r9 hasn't landed → blocked, not a drift.

# GOTCHA (rc capture discipline): wrap every suite invocation as `set +e; timeout N bash … >log
# 2>&1; rc=$?; set -e` — a red suite must be RECORDED, never abort the gate mid-matrix. rc 124 =
# timeout/HANG → run the leak sweep FIRST (reap before recording), then one bounded retry max.

# GOTCHA (orchestrator-owned artifacts): plan/**/tasks.json, plan/…/validation_report.md,
# prd_snapshot.md, prd_index.txt are NEVER edited. If the fresh plan-validate.sh summary differs
# from validation_report.md, note both numbers in gate_results.md — nothing more.

# GOTCHA (AGENTS.md §4): do NOT "restore" any per-test runner; do NOT run any framework
# self-test that calls a process-spawning setup once per case. The 4 repo suites +
# bootrace use single-setup runners AS SHIPPED — invoke `bash test/<suite>.sh` from the repo
# root and change nothing.
```

## Implementation Blueprint

### Data models and structure

None — verification-only. The "model" is the record itself (gate_results.md): preamble → summary
table → per-case extracts → findings → verdict (mirrors M1T3S1's format).

### Implementation Tasks (ordered; all outputs to `…/bugfix/001_ee35a7227ee8/P1M3T1S1/research/`)

```yaml
Task 0: PREFLIGHT — confirm every changeset artifact is present (content-greps; STOP if missing)
  - MKDIR: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T1S1/research/
  - RUN + EXPECT (each ≥1 match; ANY absence → write "gate blocked: <artifact> (owning subtask)"
        into gate_results.md and STOP — do not run the matrix):
      grep -n 'replaces the default pi,claude,codex,agy,antigravity' lib/pool.sh        # BUG-005 fix
      grep -c 'r8_bug005_help_harnesses_contract' test/bootrace.sh                      # ≥2 (def+runner)
      grep -n '\.\./\.\.' plan/004_de5e94ac127c/validate.sh                              # BUG-006 ROOT fix
      grep -cE '^r9_[a-z0-9_]+\(\)' test/bootrace.sh                                     # ≥1 (parallel M2.T4.S1)
      grep -n 'r9_' test/bootrace.sh | grep -v '()'                                      # r9 in runner for-list
      grep -cE 'pool_lane_boot_lock' lib/pool.sh                                         # ≥2 (M1 landed; sanity)
  - RUN (record the preamble): git rev-parse --short HEAD; git status --short; the full bootrace
        case list (grep -E '^r[0-9]' test/bootrace.sh / the for-list) — the M1T3S1 record's
        "case-list snapshot" pattern, so count drift is provable.

Task 1: STATICS — 9 files
  - RUN (single bounded loop; log rc per file):
        for f in lib/pool.sh bin/agent-browser-pool install.sh \
                  test/validate.sh test/release_reaper.sh test/transparency.sh \
                  test/concurrency.sh test/bootrace.sh plan/004_de5e94ac127c/validate.sh; do
            printf '== %s\n' "$f"
            timeout 60 bash -n "$f" && printf '   bash -n: OK\n' || printf '   bash -n: FAIL\n'
            timeout 120 shellcheck -s bash -S warning "$f" && printf '   shellcheck: OK\n' \
                || printf '   shellcheck: FINDINGS\n'
        done > …/research/static.log 2>&1
  - EXPECT: 9 × (bash -n OK + shellcheck OK, zero findings). Any finding → FAIL row + verbatim
        output in gate_results.md. (shellcheck prints findings to stdout — capture is the record.)

Task 2: BOOTRACE — R1-R9
  - RUN: set +e; timeout 300 bash test/bootrace.sh > …/research/bootrace.log 2>&1; rc=$?; set -e
  - EXPECT: rc 0; final line '11 passed, 0 failed'; every '== <case>' line followed by '   PASS';
        R1..R9 all represented (11 cases = r1, r2, r3_control, r3, r3_neg, r4, r5, r6, r7, r8, r9).
  - EXTRACT: grep -E '^== |PASS|FAIL' …/research/bootrace.log → paste into gate_results.md.
  - ON FAIL/DRIFT: record the case name + `grep -B1 -A3 'FAIL' …/research/bootrace.log` verbatim.
        rc 124 (hang) → Task 5 sweep FIRST (reap), record as HANG, then ONE bounded retry.
        Count != 11 → drift finding (10 = r9 missing → should have been caught by Task 0).

Task 3: THE 4 REPO SUITES — exact counts 33 / 5 / 10 / 3
  - RUN (from repo root; rc captured per suite; M1T3S1 budgets):
        set +e
        timeout 600 bash test/validate.sh       > …/research/validate.log        2>&1; rc1=$?
        timeout 300 bash test/release_reaper.sh > …/research/release_reaper.log  2>&1; rc2=$?
        timeout 300 bash test/transparency.sh   > …/research/transparency.log    2>&1; rc3=$?
        timeout 300 bash test/concurrency.sh    > …/research/concurrency.log     2>&1; rc4=$?
        set -e
  - EXPECT per suite: rc 0 AND the exact tail — validate '33 passed, 0 failed';
        release_reaper '5 passed, 0 failed'; transparency '10 passed, 0 failed';
        concurrency '3 passed, 0 failed'. Extract each log's final summary line verbatim.
  - GOTCHA: validate.log contains the INTENTIONAL 'FAIL: assert_eq (intentional mismatch)' line
        (validate's own self-test passing) — the summary line + rc are the verdict; note it in
        the record so a future reader doesn't misread it.
  - ON FAIL: record verbatim; do NOT modify any suite (regression → orchestrator finding).

Task 4: PLAN VALIDATE.SH — the FULL run (BUG-006's reproducibility promise)
  - RUN: set +e; timeout 1800 bash plan/004_de5e94ac127c/validate.sh \
              > …/research/planvalidate.log 2>&1; rc=$?; set -e     # from the REPO ROOT
  - EXPECT: rc 0; ZERO 'No such file or directory' lines
        (grep -c 'No such file or directory' …/planvalidate.log == 0); the summary line
        'passed: 88 failed: 0' OR BETTER (grep the 'passed:' tail verbatim into the record).
  - FALLBACK (--fast) ONLY if the environment genuinely forbids the real-Chrome phases (e.g. no
        display/socket available — record the exact blocker): rerun as
        `timeout 900 bash plan/004_de5e94ac127c/validate.sh --fast`, and record the fallback +
        its summary as a FINDING (the full-run promise is then unproven, not green).
  - ON FAIL: record the failing check names verbatim (grep 'FAIL' planvalidate.log). Do NOT edit
        plan/004_de5e94ac127c/validate.sh (parallel item's file) or any check.
  - NOTE vs validation_report.md: if the fresh summary differs from
        plan/004_de5e94ac127c/validation_report.md's numbers, record BOTH in gate_results.md —
        never edit the report (orchestrator-owned).

Task 5: ZERO-ORPHAN LEAK SWEEP (observational; test-scoped patterns ONLY)
  - RUN (all output → …/research/sweep.log; every pattern bounded):
        pgrep -af 'abpool-bootrace'                          || true
        pgrep -af 'fake-cdp'                                 || true
        pgrep -af 'fakechrome'                               || true
        pgrep -af 'FAKE_CHROME'                              || true
        pgrep -af 'user-data-dir=.*bootrace'                 || true
        pgrep -af 'user-data-dir=/tmp/tmp\.'                 || true
        ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-* /tmp/fake-cdp.* 2>/dev/null || true
  - EXPECT: every pgrep empty; the ls empty.
  - ON A PROCESS HIT: if the argv unambiguously references a sandbox temp path (abpool-bootrace. /
        fake-cdp. / fake-cdp marker / tmp. sandbox) → kill its process GROUP
        (`pgid=$(ps -o pgid= -p <pid> | tr -d ' '); kill -- -"$pgid" 2>/dev/null || true;
        sleep 1; kill -9 -- -"$pgid" 2>/dev/null || true; wait 2>/dev/null || true`), re-check,
        record pid + argv + the action. If ambiguous / possibly the OPERATOR's (real
        agent-browser/chrome paths, real profile dirs) → RECORD ONLY, never kill.
  - ON A TEMP-ROOT HIT (expected: the known F1 `/tmp/fake-cdp.*` leak): they are unambiguously
        test artifacts → `rm -rf /tmp/fake-cdp.*` + re-ls to confirm zero; record "F1 recurs:
        N dirs, cleaned" (attribute to suite fixtures — a minor-fix candidate, NOT this gate's).
        `$HOME/abpool-bootrace.*` / `/tmp/abpool-*` would be NEW findings (the M1 gate saw none).
  - RUN (final): git status --short  → EXPECT unchanged vs Task 0's snapshot except this
        research/ dir (untracked). Any new modification = gate bug → revert nothing, record it.

Task 6: WRITE THE RECORD — …/research/gate_results.md (mirror M1T3S1's format)
  - STRUCTURE:
        # Final changeset regression gate — P1.M3.T1.S1 (<date>, HEAD <sha>, tree <git status -s>)
        ## Preflight (Task 0): PASS/BLOCKED + the case-list snapshot
        ## Summary table
        | item | expected | got | rc | verdict |
        (rows: statics 9 files | bootrace R1-R9 | validate 33 | release_reaper 5 |
         transparency 10 | concurrency 3 | plan validate.sh full | sweep-processes | sweep-roots)
        ## Per-item results (verbatim log extracts: per-case ==/PASS/FAIL lines; each suite's
           summary tail; planvalidate's 'passed:' line + the zero-path-failure count)
        ## Findings (F1…: any drift, any FAIL case, F1-recurs, --fast fallback if used)
        ## Verdict: GATE GREEN / GATE RED / GATE BLOCKED — one paragraph, exact numbers.
  - THE NUMBERS P1.M3.T2 CITES: the per-suite counts + the plan validate.sh summary line must
        appear verbatim in this file.

Task 7: PRE-RETURN CHECKLIST (AGENTS.md §6)
  - RUN: pgrep -af 'abpool-bootrace|fake-cdp|fakechrome' || true  → empty
  - RUN: ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-* /tmp/fake-cdp.* 2>/dev/null || true → empty
  - RUN: git status --short → only the research/ additions (vs Task 0 snapshot)
  - CONFIRM: gate_results.md exists with the summary table + verdict; all 8 logs present.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: rc-capturing suite invocation (a red suite is DATA, not an abort) -------------
set +e
timeout 300 bash test/bootrace.sh > "$OUT/bootrace.log" 2>&1; rc=$?
set -e
printf 'bootrace: rc=%s tail=%s\n' "$rc" "$(tail -1 "$OUT/bootrace.log")"

# --- Pattern: verdict extraction (exact tails, not grep -c) -------------------------------
tail -1 "$OUT/validate.log"          # expect: 33 passed, 0 failed
grep 'passed:' "$OUT/planvalidate.log" | tail -1   # expect: passed: 88 failed: 0 (or better)
grep -c 'No such file or directory' "$OUT/planvalidate.log"   # expect: 0

# --- Pattern: safe reap of an unambiguous sandbox orphan (process GROUP, then wait) ---------
pid="<pid>"; pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
kill -- -"$pgid" 2>/dev/null || true; sleep 1
kill -9 -- -"$pgid" 2>/dev/null || true
# (record pid + argv + action in sweep.log; RECORD-ONLY if it might be the operator's)

# --- Critical micro-rules ------------------------------------------------------------------
#  * `timeout` on EVERY invocation incl. the statics loop and sweep (60-1800s per item).
#  * NEVER blanket-pkill; ONLY the 6 test-scoped patterns; ambiguous = record-only.
#  * NEVER edit: any suite, lib/pool.sh, bin/*, install.sh, plan/** (incl. tasks.json,
#    validation_report.md). The gate writes ONLY its research/ dir.
#  * A FAIL is recorded verbatim with its case/check name — never weakened, never fixed here.
#  * rc 124 = hang → sweep FIRST (reap), record as HANG, ONE bounded retry maximum.
#  * Count drift (suites/bootrace) = a FINDING row even when rc == 0.
```

### Integration Points

```yaml
GATE INPUTS (all landed or parallel-contract; verified by Task 0 preflight):
  - lib/pool.sh help fix (M2.T3.S1 artifacts — present in tree; verify by content).
  - test/bootrace.sh r1..r8 (landed) + r9 (parallel M2.T4.S1 contract).
  - plan/004_de5e94ac127c/validate.sh ROOT fix (parallel M2.T4.S1 contract).

GATE OUTPUT (what downstream consumes):
  - …/P1M3T1S1/research/gate_results.md — THE changeset validation record. P1.M3.T2.S1/S2
    (README + skill-doc sync) cite its per-suite counts + the plan validate.sh summary line.
  - Findings (F1-recurs, drift, any FAIL) go to the orchestrator as the changeset close-out
    inputs — the gate never fixes them.

CONFIG / DATABASE / ROUTES: none. Verification-only; no source/test/doc/config changes.
```

## Validation Loop

### Level 1: The record is complete and well-formed

```bash
# gate_results.md has the summary table, per-item extracts, findings, verdict:
grep -c '^|' …/P1M3T1S1/research/gate_results.md          # ≥ 10 table rows
grep -n '## Verdict' …/P1M3T1S1/research/gate_results.md  # present
ls …/P1M3T1S1/research/    # gate_results.md + static/bootrace/validate/release_reaper/
                           # transparency/concurrency/planvalidate/sweep .log — 9 files
```

### Level 2: Every matrix item has an explicit verdict

```bash
# Each row's "got" is a verbatim extract (not a paraphrase):
grep -E 'passed, [0-9]+ failed' …/research/{bootrace,validate,release_reaper,transparency,concurrency}.log | tail -1 each
grep 'passed:' …/research/planvalidate.log | tail -1
grep -c 'No such file or directory' …/research/planvalidate.log   # 0
```

### Level 3: Reproducibility of the gate itself

```bash
# The record's preamble pins the exact tree (HEAD sha + git status + case-list snapshot), so a
# future reader can diff. Spot-check one log against the table (e.g. bootrace):
grep -E '^== |   PASS|   FAIL' …/research/bootrace.log | tail -24   # matches the table's row
```

### Level 4: Exit discipline (AGENTS.md §6 checklist)

```bash
pgrep -af 'abpool-bootrace|fake-cdp|fakechrome' || echo "no test orphans"
ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-* /tmp/fake-cdp.* 2>/dev/null || echo "no test roots"
git status --short    # only this task's research/ additions vs the Task-0 snapshot
```

## Final Validation Checklist

### Technical Validation

- [ ] Task 0 preflight: all artifacts confirmed by content-grep (or "gate blocked" + STOP).
- [ ] Statics 9/9 clean (`bash -n` + `shellcheck -s bash -S warning`, per-file rc in static.log).
- [ ] bootrace: 11 cases, 0 failed, rc 0; R1-R9 all represented.
- [ ] Suites: exact 33/5/10/3, rc 0 each; tails recorded verbatim.
- [ ] plan validate.sh FULL run from repo root: zero path failures; `passed: 88 failed: 0` or
      better (or the documented `--fast` fallback + finding).
- [ ] Leak sweep: zero test-scoped process hits; zero leftover test temp roots (F1 re-checked).
- [ ] gate_results.md complete (table + extracts + findings + verdict); 9 files in research/.

### Feature Validation

- [ ] The record cites the exact per-suite counts + the plan validate.sh summary line (what
      P1.M3.T2 consumes).
- [ ] Any failure/drift recorded precisely — no assertion weakened, no in-flight fix.
- [ ] validation_report.md untouched; any number diff NOTED in the record only.

### Code Quality / Scope Validation

- [ ] `git status --short` before vs after: only this task's `research/` dir changed.
- [ ] No edits to any suite / lib / bin / install.sh / plan/** (incl. orchestrator-owned files).
- [ ] AGENTS.md §6 pre-return checklist all green (zero orphans, zero temp roots).

### Documentation & Deployment

- [ ] The record's preamble (date, HEAD, tree status, case-list snapshot) pins reproducibility.

---

## Anti-Patterns to Avoid

- ❌ Don't run the matrix on a half-applied tree — preflight by CONTENT; blocked → record + STOP.
- ❌ Don't add r9, edit validate.sh, or touch any suite/lib file — the gate only observes+records.
- ❌ Don't weaken an assertion or "fix" a red case to close the changeset — record it verbatim.
- ❌ Don't blanket-`pkill` chrome/agent-browser/sleep — operator processes live here; use ONLY the
  6 test-scoped patterns; ambiguous hits are record-only.
- ❌ Don't misread validate.sh's intentional `FAIL: assert_eq (intentional mismatch)` line — the
  summary + rc are the verdict.
- ❌ Don't treat count drift as a pass (33/5/10/3 and bootrace 11 are contractual).
- ❌ Don't run the plan validate.sh as `--fast` by default — full run first; `--fast` only with a
  recorded environmental blocker.
- ❌ Don't let a red suite abort the gate (`set +e; …; rc=$?; set -e` capture) or skip the sweep.
- ❌ Don't edit plan/**/tasks.json or validation_report.md — orchestrator-owned; note diffs only.
- ❌ Don't skip the pre-return checklist — zero orphans + zero temp roots or the gate isn't done.