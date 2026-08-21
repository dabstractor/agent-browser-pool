# PRP — P1.M1.T3.S1: Run R1–R4 + 4 repo suites + static checks in an isolated sandbox; zero-orphan leak sweep

> **Bugfix context**: This is the **major-fix integration gate** for changeset
> `plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8` (BUG-001/BUG-002). All upstream work is (per the
> task tree) Complete or Implementing: P1.M1.T1.S1 (BUG-001 copy guard + R1/R2), P1.M1.T2.S1
> (test/bootrace.sh harness), T2.S2 (per-lane boot lock), T2.S3 (ensure_connected hardening), and
> T2.S4 (widened (3b) release sweep — **in flight in parallel**; this gate RUNS AFTER S4 lands and
> treats its PRP as a contract). This subtask is **verification-only**: it changes NO source and NO
> test files. A failure is a **finding** to be recorded verbatim, never papered over by editing
> assertions (item contract §3d).
>
> **CRITICAL SAFETY (AGENTS.md)**: everything here launches real (fake) Chrome-shaped processes and
> process groups. Every suite invocation is wrapped in `timeout`. The four repo suites are
> self-isolating (they build their own temp trees under `$ABPOOL_TEST_ROOT`/`mktemp`), and
> test/bootrace.sh creates its sandbox via `mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX` with a
> suite-level trap — so the gate invokes them exactly as shipped and then performs its OWN
> independent zero-orphan sweep. Never run against the operator's real
> `~/.local/state/agent-browser-pool/` or `~/.agent-chrome-profiles/` — the sweep patterns below are
> deliberately scoped to TEST artifacts only (the operator has REAL Chrome lanes on
> `~/.agent-chrome-profiles/active/{1,7}` that must never be touched).

---

## Goal

**Feature Goal**: Execute the complete major-fix regression gate — (a) the bootrace suite (R1–R4 +
control + the S4 negative-control), (b) all four repo suites (validate, release_reaper,
transparency, concurrency), (c) static checks (bash -n + shellcheck) on the changed shell sources —
each under hard `timeout`, in isolated sandboxes, and (d) an independent zero-orphan/zero-leftover
leak sweep — producing a **pass/fail record per suite and per case** that confirms the BUG-001 and
BUG-002 fixes hold against the PRD h2.2 repros with zero leaked processes.

**Deliverable**: One results record at
`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/gate_results.md` (plus raw suite
logs alongside it in `research/`): a printable summary table (suite → expected/got counts → rc →
PASS/FAIL), the per-case PASS/FAIL lines grepped from each log, static-check results, and the leak
sweep evidence (empty pgrep output, no leftover temp roots). No source/test edits. Consumed by
P1.M3.T1.S1 (final changeset gate re-runs everything after the minor fixes land).

**Success Definition**:
- `timeout 300 bash test/bootrace.sh` → exit 0, `N passed, 0 failed` (currently 5 cases:
  `r1_bug001_guard_fs_agnostic`, `r2_bug001_recovery_e2e`, `r3_control_delayed_boot_succeeds`,
  `r3_bug002_race_e2e`, `r4_bug002_preport_race`; **+1 = `r3_neg_dead_ids_release_still_kills`**
  once the parallel T2.S4 PRP lands — re-grep the case list at run time, do not hardcode).
- All 4 repo suites exit 0 with the PRD h2.0 expected green counts: **validate 33/33**,
  **release_reaper 5/5**, **transparency 10/10**, **concurrency 3/3**.
- `bash -n` and `shellcheck -s bash -S warning` clean on `lib/pool.sh`, `bin/agent-browser-pool`,
  `test/bootrace.sh`, `install.sh` (the 4 files this changeset touched; the PRD confirms all 7 shell
  sources were clean at HEAD — gate on these 4, optionally sweep all 7).
- Leak sweep: `pgrep -af` over the TEST patterns (fake-chrome, fake-cdp, abpool-bootrace,
  fake agent-browser, test sim-owner sleeps) returns nothing; no leftover `abpool-bootrace.*`
  / `fake-cdp.*` / `abpool-*` temp roots under `$HOME` or `/tmp`.
- Any failure is recorded verbatim (suite, case name, log excerpt) in gate_results.md — NOT fixed
  by editing suites (a failure means an upstream fix (T1.S1/T2.S2/S3/S4) regressed; report it).

## User Persona

**Target User**: The changeset owner/orchestrator (and P1.M3.T1.S1's gate runner). Secondary: any
future reader auditing that the major fixes actually held.

**Use Case**: Before proceeding to the minor fixes (P1.M2) and the final gate (P1.M3.T1.S1), prove
the two MAJOR fixes (BUG-001 nested-master-copy guard; BUG-002 same-owner boot race + release leak)
did not regress anything the repo already guaranteed.

**User Journey**: Run the gate runbook (Tasks 1–5 below) from the repo root → capture logs → write
gate_results.md → hand the summary to the orchestrator → P1.M3.T1.S1 re-runs the same matrix later.

**Pain Points Addressed**: "Fixes landed but nothing re-proved the suites" — the classic 80% stall;
also the sandbox-wedge hazard of running process-spawning suites carelessly (AGENTS.md §1–§4).

## Why

- PRD h2.0 tested HEAD at green counts 33/5/10/3 — those four suites are the regression baseline
  every fix must preserve. BUG-001/BUG-002 fixes touched `pool_copy_master`, the boot path, the
  boot/connect locking, and the release kernel — the highest-blast-radius functions in the pool.
- PRD h2.2's repros (nested master copy; spurious second-command failure + double Chrome + clobbered
  lease ids + Chrome surviving `release all`) are exactly what bootrace R1–R4 encode; running the
  suite green is the direct confirmation the fixes hold.
- AGENTS.md §3/§4: the gate itself must not become the thing that wedges the sandbox — hence hard
  timeouts, the single-setup guarantee (already built into each suite — invoke them as shipped,
  never re-plumb them to per-test setup), and an independent post-run orphan sweep.

## What

Verification-only runbook. No user-visible behavior change, no code change, no test change.
Steps: (0) preflight (confirm S4 landed, tree state, case list); (1) bootrace suite; (2) the four
repo suites; (3) static checks; (4) leak sweep; (5) write gate_results.md.

### Success Criteria

- [ ] Preflight: `grep -n 'r3_neg_dead_ids_release_still_kills' test/bootrace.sh` matches (S4
      landed) — if absent, S4 has not landed yet: STOP and report (do not gate half a fix).
- [ ] `timeout 300 bash test/bootrace.sh` → rc 0, `0 failed` in the summary line.
- [ ] `timeout 600 bash test/validate.sh` → rc 0, 33 passed / 0 failed.
- [ ] `timeout 300 bash test/release_reaper.sh` → rc 0, 5 passed / 0 failed.
- [ ] `timeout 300 bash test/transparency.sh` → rc 0, 10 passed / 0 failed.
- [ ] `timeout 300 bash test/concurrency.sh` → rc 0, 3 passed / 0 failed.
- [ ] `bash -n` clean + `shellcheck -s bash -S warning` clean on the 4 files (Task 3).
- [ ] Leak sweep (Task 4): every pgrep pattern empty; no test temp roots left.
- [ ] `plan/004_.../P1M1T3S1/research/gate_results.md` written with the full record.
- [ ] Zero edits to `lib/pool.sh`, `test/*.sh`, `bin/*`, `install.sh` (verify with git status).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, could they implement this?_ Yes: the exact commands
with timeouts, the expected counts (PRD h2.0), where the case lists live, what the leak-sweep
patterns are (and why they must NOT match the operator's real lanes), where to write the record,
and what to do on failure (record, don't fix). No source knowledge required beyond reading logs.

### Documentation & References

```yaml
- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  section: "§1 (single-setup runner + suite invocation), §4 (R1–R9 matrix), §5 (safety checklist)"
  why: THE contract for how suites are invoked (`bash test/<suite>.sh` from repo root, each exits 0
       iff all cases pass) and what the bootrace cases assert.
  critical: "release_reaper + concurrency use the single-setup runner — call setup exactly once,
       never per-test (AGENTS.md §4; the 3rd per-test setup() call HANGS a shared sandbox). Invoking
       the suites as shipped already honors this — never wrap individual cases yourself."

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  section: "§11 house style, §6 teardown contract"
  why: "kill process groups + wait; never kill -0; every blocking subprocess under timeout."

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T2S4/PRP.md
  section: "Deliverable + Success Definition"
  why: "the PARALLEL in-flight item this gate depends on: it adds case
       r3_neg_dead_ids_release_still_kills to test/bootrace.sh and widens the (3b) sweep in
       lib/pool.sh. Gate runs AFTER it lands; expect 6 bootrace cases (5 current + 1 new)."
  critical: "if r3_neg_dead_ids_release_still_kills is ABSENT from test/bootrace.sh at preflight,
       S4 has not landed — STOP and report; do not gate a half-applied fix set."

- file: test/bootrace.sh
  why: "the suite under gate. Runner = _br_run_suite (case list hardcoded at ~line 418: r1, r2,
       r3_control, r3_bug002_race_e2e, r4). Sandbox = mktemp -d -p \"$HOME\" -t abpool-bootrace.XXXXXX
       with a suite trap (_bootrace_teardown). Prints 'N passed, M failed' + rc 0 iff M==0."
  pattern: "grep the case list at run time: grep -nE '^    for fn in|^              r[0-9]' test/bootrace.sh"
  gotcha: "bootrace lives under $HOME (real FS / btrfs — deliberate, BUG-001 is fs-sensitive), NOT
       /tmp. Sweep BOTH $HOME and /tmp for abpool-bootrace.* roots."

- file: test/validate.sh, test/release_reaper.sh, test/transparency.sh, test/concurrency.sh
  why: "the 4 repo suites. Self-isolating (own temp trees, own traps, own fakes). Invoke exactly:
       bash test/<suite>.sh from the repo root. Expected green: 33 / 5 / 10 / 3 (PRD h2.0)."
  gotcha: "DO NOT re-implement their setup, DO NOT run their internals per-test, DO NOT 'fix' a red
       case by editing assertions — item contract §3: a failure is a FINDING."

- file: PRD.md (plan/004_.../bugfix/001_ee35a7227ee8/prd_snapshot.md)
  section: "h2.0 (baseline green counts), h2.2 (BUG-001/BUG-002 repros the gate re-proves)"
  why: "the authoritative expected counts + the repro semantics R1–R4 encode."

- url: https://github.com/koalaman/shellcheck#installing
  why: "the project lint gate is `shellcheck -s bash -S warning` (confirmed clean at HEAD on all 7
       shell files, PRD h2.0). Do NOT use a stricter severity — style-level annotations exist by design."
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                 # 5139 LOC — MODIFIED by this changeset (T1.S1 + T2.S2/S3/S4)
├── bin/agent-browser-pool       # 27 LOC wrapper
├── install.sh                   # 141 LOC
├── test/
│   ├── bootrace.sh              # 21.7 KB — NEW this changeset (T2.S1 + T2.S4's case); the gate's subject
│   ├── validate.sh              # 1639 LOC — 33 cases (PRD h2.0)
│   ├── release_reaper.sh        # 475 LOC — 5 cases (single-setup runner: the canonical pattern)
│   ├── transparency.sh          # 611 LOC — 10 cases
│   └── concurrency.sh           # 683 LOC — 3 cases
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/{test_framework.md, system_context.md, fix_design.md}
    ├── TEST_RESULTS.md          # the QA report (BUG-001..006)
    ├── P1M1T2S4/PRP.md          # parallel in-flight item (gate's dependency)
    └── P1M1T3S1/                # THIS subtask — OUTPUT: research/gate_results.md + research/*.log
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO source/test files added or modified. Only:
#   plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/
#     gate_results.md   ← the deliverable: per-suite + per-case pass/fail record + summary
#     bootrace.log validate.log release_reaper.log transparency.log concurrency.log
#     static.log  sweep.log     ← raw captured outputs (evidence for the record)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (operator's REAL lanes): the host runs REAL pooled Chromes on
# ~/.agent-chrome-profiles/active/{1,7} and real agent-browser daemons. The leak sweep patterns must
# be TEST-SCOPED (abpool-bootrace / fake-cdp / fakechrome / FAKE_ env markers / user-data-dir=.*bootrace)
# — a bare `pgrep -af chrome` will always "match" and is meaningless. NEVER pkill anything from the
# gate: the sweep is OBSERVATIONAL (record + report). If a test-pattern process IS found, record it as
# a LEAK finding with its pid/argv; only kill it if it is unambiguously a test fake (its cmdline
# contains the sandbox temp path) — and then kill the process GROUP and wait.

# CRITICAL (S4 dependency): lib/pool.sh was ' M' (modified, S4 in flight) at research time. The gate
# MUST run only after S4's PRP deliverables are present. Preflight (Task 0) verifies this by grepping
# test/bootrace.sh for r3_neg_dead_ids_release_still_kills. If absent → STOP, report, do not proceed.

# GOTCHA (bootrace temp root is under $HOME, not /tmp): _bootrace_setup uses
# mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX (deliberate: BUG-001 is btrfs/real-FS sensitive).
# The leftover check must sweep $HOME for abpool-bootrace.* AND /tmp for fake-cdp.* / abpool-* roots.

# GOTCHA (suite rc semantics): every suite prints a final "N passed, M failed" and exits non-zero iff
# M>0. Capture rc with `|| rc=$?` (never bare under set -e). The gate records rc + counts per suite.

# GOTCHA (timeouts): wrap each SUITE in timeout (300s default; 600s for validate — it is the largest
# at 1639 LOC / 33 cases). If a suite hits the timeout, that is a HANG FINDING (record it; do not
# re-run blindly — first check pgrep for orphaned fakes, sweep, then optionally one retry).

# GOTCHA (parallel pi sessions): this host runs sibling pi/orchestrator sessions. Do not interpret
# their processes (pi, git, curl to localhost event bus) as leaks. Only TEST patterns count.

# GOTCHA (single-setup): release_reaper + concurrency spawn sim-owner processes from a setup() called
# ONCE per suite by their own runners. Invoking `bash test/<suite>.sh` is safe. NEVER extract a case
# and run it standalone through any run_test/abpool_run_suite-style harness — that is the §4 hang.
```

## Implementation Blueprint

### Data models and structure

Not applicable — verification only. The only "data" is gate_results.md (Markdown: a summary table +
per-case PASS/FAIL lines + findings).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: PREFLIGHT — confirm the gate's inputs exist (do not gate a half-applied fix set)
  - RUN: cd /home/dustin/projects/agent-browser-pool && git status --short
  - RUN: grep -n 'r3_neg_dead_ids_release_still_kills' test/bootrace.sh
    # EXPECT: ≥1 match (T2.S4 landed). If ABSENT → STOP: record "S4 not landed; gate blocked" in
    #         gate_results.md and END (do not run the matrix against a half-applied changeset).
  - RUN: grep -cE 'pool_lane_boot_lock' lib/pool.sh    # EXPECT: ≥2 (def + use — T2.S2 landed)
  - RUN: grep -n 'ids not confirmed\|(3b)' lib/pool.sh | head   # EXPECT: the widened (3b) gate comment
  - RUN: grep -nE 'for fn in r1_bug001' test/bootrace.sh        # capture the CURRENT case list
  - MKDIR: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/
  - RECORD the case list + git HEAD (git rev-parse --short HEAD) into gate_results.md preamble.

Task 1: RUN the bootrace suite (R1–R4 + control + S4 negative-control)
  - RUN: set +e; timeout 300 bash test/bootrace.sh >plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/bootrace.log 2>&1; rc=$?; set -e
  - ASSERT-RECORD: rc == 0 AND the log's final line matches '[0-9]+ passed, 0 failed'.
  - EXTRACT per-case results: grep -E '^== |   PASS|   FAIL' research/bootrace.log
  - EXPECTED cases (verify against Task 0's list; 6 once S4 lands): r1_bug001_guard_fs_agnostic,
        r2_bug001_recovery_e2e, r3_control_delayed_boot_succeeds, r3_bug002_race_e2e,
        r4_bug002_preport_race, r3_neg_dead_ids_release_still_kills — each PASS.
  - ON FAIL: record the case name + the FAIL lines verbatim (`grep -B1 -A3 'FAIL' research/bootrace.log`).
        Do NOT edit bootrace.sh or lib/pool.sh. If the suite TIMED OUT (rc 124): sweep (Task 4) FIRST,
        record as HANG finding, then one bounded retry is allowed.

Task 2: RUN the four repo suites (invoked exactly as shipped, each under timeout)
  - RUN (one per line, from the repo root; capture rc per suite):
        timeout 600 bash test/validate.sh        > …/P1M1T3S1/research/validate.log        2>&1; rc_validate=$?
        timeout 300 bash test/release_reaper.sh  > …/P1M1T3S1/research/release_reaper.log  2>&1; rc_rr=$?
        timeout 300 bash test/transparency.sh    > …/P1M1T3S1/research/transparency.log    2>&1; rc_tr=$?
        timeout 300 bash test/concurrency.sh     > …/P1M1T3S1/research/concurrency.log     2>&1; rc_cc=$?
    (… = plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8)
  - ASSERT-RECORD per suite (PRD h2.0 baseline):
        validate        : rc 0, '33 passed, 0 failed' (33/33)
        release_reaper  : rc 0, '5 passed, 0 failed'  (5/5)
        transparency    : rc 0, '10 passed, 0 failed' (10/10)
        concurrency     : rc 0, '3 passed, 0 failed'  (3/3)
    (Suites print their own summary phrasing — grep the 'passed'/'failed' tail of each log and
     record the exact line; if a suite's count line differs from the expected number, that is a
     FINDING even when rc==0 — record expected vs got.)
  - EXTRACT per-case lines the same way as Task 1 (`grep -E '^== |PASS|FAIL'` per log).
  - ON FAIL: record verbatim; do NOT modify any suite. A red repo-suite case means an upstream
        fix (T1.S1 / T2.S2 / S3 / S4) regressed repo-guaranteed behavior — that finding goes to
        the orchestrator before P1.M2 starts.

Task 3: STATIC CHECKS on the changed shell sources
  - RUN for f in lib/pool.sh bin/agent-browser-pool test/bootrace.sh install.sh; do
        bash -n "$f" && shellcheck -s bash -S warning "$f"
    done > …/P1M1T3S1/research/static.log 2>&1; record rc per file.
  - EXPECT: zero output, rc 0 for all four. (PRD h2.0: all 7 shell files were clean at HEAD; the
        changeset must keep its touched files clean. Optionally sweep all 7 — the other 3 are
        test/{validate,release_reaper,transparency,concurrency}.sh minus one = pick from git ls
        if desired, but the 4 named are the gate.)

Task 4: ZERO-ORPHAN LEAK SWEEP (observational; never blanket-pkill)
  - RUN (record raw output into …/P1M1T3S1/research/sweep.log):
        pgrep -af 'abpool-bootrace'          || true     # fake chromes / sandbox procs (cmdline has the temp root)
        pgrep -af 'fake-cdp'                 || true     # fake CDP listeners
        pgrep -af 'fakechrome'               || true     # fake chrome fixture scripts
        pgrep -af 'FAKE_CHROME'              || true     # env-marker leakage into argv
        pgrep -af "user-data-dir=.*bootrace" || true     # chromes still holding a sandbox dir
        pgrep -af 'user-data-dir=/tmp/tmp\.' || true     # chromes on mktemp tmpfs roots (fake-agent-browser default)
    - ASSERT: every pattern returns NOTHING. Any hit = LEAK FINDING: record pid + full argv. If the
      argv unambiguously references a sandbox temp path (abpool-bootrace./fake-cdp./tmp.), kill its
      process GROUP (setsid'd: kill -- -<pgid> then -9), wait, re-check, and record the action.
      If it might be a sibling session's process, RECORD ONLY — do not kill.
  - RUN: ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-* /tmp/fake-cdp.* 2>/dev/null || true
    - ASSERT: no leftover test temp roots. (NOTE: /tmp/tmp.* dirs from SIBLING pi sessions may
      exist and are NOT ours — only abpool-*/fake-cdp.*/abpool-bootrace.* patterns count.)
  - RUN (final): git status --short   # EXPECT: no NEW modifications from the gate itself (lib/pool.sh
        may still show ' M' from S4's landing — that predates the gate; record it in the preamble).

Task 5: WRITE the record — research/gate_results.md
  - STRUCTURE:
        # Major-fix integration gate — P1.M1.T3.S1 (<date>, HEAD <sha>, tree status <git status -s>)
        ## Summary table
        | suite | expected | got | rc | verdict |
        |-------|----------|-----|----|---------|
        | bootrace (R1–R4+controls) | N cases, 0 failed | <from log> | <rc> | PASS/FAIL |
        | validate | 33/33 | … | … | … |
        | release_reaper | 5/5 | … | … | … |
        | transparency | 10/10 | … | … | … |
        | concurrency | 3/3 | … | … | … |
        | static (bash -n + shellcheck, 4 files) | clean | … | … | … |
        | leak sweep | 0 orphans, 0 roots | <evidence> | — | … |
        ## Per-case results   (grepped == / PASS / FAIL lines per suite log)
        ## Findings           (verbatim FAIL/HANG/LEAK excerpts + which upstream subtask owns each)
        ## Verdict            (GATE GREEN / GATE RED + blockers)
  - The record is the sole deliverable consumed by P1.M3.T1.S1.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — safe suite invocation (capture rc; never bare under errexit):
#   set +e; timeout 300 bash test/<suite>.sh >research/<suite>.log 2>&1; rc=$?; set -e
# WHY: suites exit non-zero on any red case — the gate RECORDS rc, it does not abort on it.

# Pattern B — per-case extraction:
#   grep -E '^== |PASS|FAIL' research/<suite>.log
# WHY: every suite prints '== <case>' headers + PASS/FAIL verdicts (bootrace: '   PASS'/'   FAIL');
#      these lines ARE the per-case record the item contract demands.

# Pattern C — observational sweep (never blanket-pkill):
#   pgrep -af '<TEST pattern>' || true   # record; kill ONLY unambiguous test fakes, by GROUP, + wait
# WHY: the host runs real Chromes (~/.agent-chrome-profiles/active/*) + sibling pi sessions; a bare
#      'pgrep chrome' always matches and a blanket pkill would violate AGENTS.md (operator state).

# Pattern D — finding discipline:
#   a failure ⇒ { record suite+case+verbatim log excerpt; attribute to owning subtask
#   (T1.S1=copy guard, T2.S2=boot lock, T2.S3=ensure_connected, T2.S4=release sweep);
#   DO NOT edit suites/lib; DO NOT retry more than once (hang case only) }.
```

### Integration Points

```yaml
CODE: NONE — verification-only. Zero edits to lib/pool.sh, test/*, bin/*, install.sh.
OUTPUT:
  - plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/gate_results.md   (the record)
  - plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/research/*.log            (raw evidence)
CONSUMERS:
  - P1.M3.T1.S1 (final changeset gate): re-runs this exact matrix after P1.M2's minor fixes; it
    relies on this record's format (summary table + per-case lines + findings) and on the expected
    counts (bootrace grows again with R5–R9 from P1.M2 — this gate's bootrace count is a snapshot,
    record the case list explicitly so M3 can diff).
UPSTREAM (must have landed before the gate runs):
  - P1.M1.T1.S1 (BUG-001 guard + R1/R2)      — Complete
  - P1.M1.T2.S1 (bootrace harness)           — Complete
  - P1.M1.T2.S2 (boot lock)                  — Complete
  - P1.M1.T2.S3 (ensure_connected hardening) — Complete
  - P1.M1.T2.S4 (widened (3b) sweep + negative-control case) — Implementing (verify via Task 0)
CONFIG/ROUTES/DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
# The gate's own tooling is ad-hoc bash — nothing to lint. The static checks ARE part of the
# deliverable (Task 3): bash -n + shellcheck -s bash -S warning on the 4 changed files, clean.
```

### Level 2: Component (per-suite)

```bash
# Tasks 1–2 ARE this level: each suite's rc + count line + per-case PASS/FAIL recorded.
# Re-verify any surprising result by reading the log BEFORE recording the verdict —
# e.g. a suite that printed 33 passed but rc!=0, or vice versa, is itself a finding.
```

### Level 3: Integration (the whole matrix, one session)

```bash
# Run Tasks 0→4 in ORDER in one session (preflight → bootrace → 4 suites → static → sweep),
# so the leak sweep reflects ALL suites' cumulative effect. Verify after Task 4:
#   - research/ contains: gate_results.md + 6 logs (bootrace, validate, release_reaper,
#     transparency, concurrency, static) + sweep.log
#   - git status --short shows no NEW modifications attributable to the gate
```

### Level 4: Domain-Specific (repro fidelity)

```bash
# Confirm the PRD h2.2 repros are actually exercised (sanity-grep the bootrace log, not just rc):
grep -E 'r1_bug001|r2_bug001' research/bootrace.log     # BUG-001: guard + crash-recovery e2e
grep -E 'r3_bug002_race_e2e|r4_bug002_preport' research/bootrace.log  # BUG-002: race + pre-port race
grep -E 'r3_neg_dead_ids' research/bootrace.log         # S4: dead-ids release still kills
# Each must show '== <case>' followed by PASS. If any shows FAIL, the corresponding repro is
# NOT fixed — record as the headline finding.
```

## Final Validation Checklist

### Technical Validation

- [ ] Task 0 preflight passed (S4 case present; boot lock + widened sweep in lib/pool.sh).
- [ ] bootrace: rc 0, 0 failed, all cases PASS (R1–R4 + control + negative-control).
- [ ] validate 33/33, release_reaper 5/5, transparency 10/10, concurrency 3/3 — all rc 0.
- [ ] Static: bash -n + shellcheck -S warning clean on the 4 changed files.
- [ ] Leak sweep: all test-scoped pgrep patterns empty; no leftover abpool-bootrace.*/fake-cdp.* roots.

### Feature Validation

- [ ] gate_results.md written with summary table + per-case record + findings + verdict.
- [ ] Every FAIL (if any) attributed to its owning upstream subtask, verbatim log excerpt included.
- [ ] No suite, lib, bin, or install.sh file was modified by this gate (git status check).

### Code Quality Validation

- [ ] Verification-only discipline held (no assertion edits, no source edits, ≤1 bounded retry on hang only).
- [ ] Record format matches what P1.M3.T1.S1 will re-consume (table + '== case'/PASS lines).

### Documentation & Deployment

- [ ] gate_results.md documents the bootrace case-list snapshot (so M3 can diff after R5–R9 land).
- [ ] Raw logs preserved in research/ as evidence.

---

## Anti-Patterns to Avoid

- ❌ Don't run the gate before T2.S4 lands (preflight exists for this) — half-gating proves nothing.
- ❌ Don't edit any suite or lib file to turn a red case green — a failure is a finding (item contract).
- ❌ Don't run suites without `timeout`, and don't re-run a hung suite repeatedly — sweep first, one retry max.
- ❌ Don't extract cases into a per-test harness — single-setup runners only, invoked as shipped (AGENTS.md §4).
- ❌ Don't blanket-`pkill chrome`/`pkill -f agent-browser` in the sweep — the operator's REAL lanes and sibling sessions must never be touched; test-scoped patterns only, observational first.
- ❌ Don't hardcode the bootrace case count — grep the case list at preflight (S4 adds a case; P1.M2 adds R5–R9 later).
- ❌ Don't count a suite as green on rc alone — verify the expected N-passed count line too (count drift is a finding).