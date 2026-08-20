# PRP — P4.M2.T3.S2: Real-Chrome suites + orphan/temp-dir leak audit

## Goal

**Feature Goal**: Execute the PRD M2 acceptance gate for the caller-scoped /
lane-pinning feature: run ALL real-Chrome suites in an ISOLATED sandbox — the
converted `test/concurrency.sh` (P4.M2.T2.S1 runner + optional P4.M2.T2.S2 E2E body),
`test/release_reaper.sh`, and `test/transparency.sh` — all green, with a hard
post-suite audit proving ZERO orphaned processes and ZERO leftover temp trees.
Also static-check `install.sh` for the acceptance line (PRD R6: install.sh needs NO
change).

**Deliverable**: No production-code changes expected. Deliverables are recorded
artifacts under `plan/004_de5e94ac127c/P4M2T3S2/research/`:
1. `concurrency_run.log` — green run of `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh` (rc 0)
2. `release_reaper_run.log` — green run of `AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh` (rc 0)
3. `transparency_run.log` — green run of `AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh` (rc 0)
4. `install_static.log` — `bash -n` + `shellcheck -s bash install.sh`, zero warnings
5. `leak_audit.log` — per-suite and final pgrep/`/tmp` audits, all empty
6. `notes.md` — conclusions, incl. git-diff proof that install.sh is unchanged
If (and only if) a suite fails: a fix confined to the OWNING subtask's scope —
never a weakened assert, never framework-code edits — then a re-run to green.

**Success Definition**:
- All three real-Chrome suites rc 0 (`N passed, 0 failed`), in the isolated sandbox only.
- After EVERY suite and at the end: `pgrep -af` for chrome/chromium/abpool/agent-browser/sleep
  spawned by the run finds nothing attributable to the run; `ls -d /tmp/abpool-test.* /tmp/abpool-pi.*`
  finds nothing (the traps cleaned up — verify they did, don't assume).
- `install.sh` unchanged (`git diff --stat install.sh` empty vs HEAD) + static-clean.

## Why

This is the real-Chrome half of the PRD acceptance gate (PRD §2.19; synthesis.md §3).
P4.M2.T2.S1 converted concurrency.sh from the 2-call per-test runner (documented hang
threshold, LM-1) to a single-setup runner; the R1 citation sweep (P4.M1.T1) renumbered
PRD-section references in comments. This item PROVES those changes regressed nothing:
same bodies, same green result, plus the leak discipline AGENTS.md §3/§6 demands.

## What

1. **Static first** (safe anywhere):
   ```bash
   bash -n install.sh; shellcheck -s bash install.sh
   bash -n test/concurrency.sh; bash -n test/release_reaper.sh; bash -n test/transparency.sh
   ```
   Expect zero output (SC1091/SC2016 info in the test files is pre-existing/acceptable).
   `git status --porcelain install.sh` must be empty (R6: no change needed) — record it.
2. **Live suites — ISOLATED SANDBOX ONLY** (AGENTS.md §1: never against the operator's
   real HOME/running Chrome; these suites re-point at the REAL master profile and REAL
   agent-browser binary — they boot real headless Chrome). One at a time, each
   timeout-wrapped, each followed immediately by the leak audit:
   ```bash
   AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh 2>&1 \
     | tee plan/004_de5e94ac127c/P4M2T3S2/research/concurrency_run.log; echo "rc=${PIPESTATUS[0]}"
   AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh 2>&1 \
     | tee plan/004_de5e94ac127c/P4M2T3S2/research/release_reaper_run.log; echo "rc=${PIPESTATUS[0]}"
   AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh 2>&1 \
     | tee plan/004_de5e94ac127c/P4M2T3S2/research/transparency_run.log; echo "rc=${PIPESTATUS[0]}"
   ```
   Do NOT add other env overrides — the blessed invocations above are exactly what
   prior sessions used (test_framework.md §10). Verify each log's summary shows
   `0 failed` and every discovered body name appears as a PASS.
3. **Leak audit after EVERY suite** (and once at the very end), all outputs appended to
   `research/leak_audit.log`:
   ```bash
   pgrep -af 'chrome|chromium|abpool|agent-browser|sleep' || echo "no orphans"
   ls -d /tmp/abpool-test.* /tmp/abpool-pi.* 2>/dev/null || echo "no leftover temp roots"
   ```
   - The pgrep audit is "attributable to this run": the operator may legitimately run
     their own Chrome — snapshot `pgrep -af 'chrome|chromium'` BEFORE the suite, diff
     after. Record both snapshots. Anything net-new must be killed (process GROUP:
     `kill -- -<pgid>`; then `wait` if you own it) and treated as a suite failure to
     fix in the owning subtask's scope.
   - `/tmp/abpool-test.*` and `/tmp/abpool-pi.*` MUST be absent — the EXIT trap's glob
     backstops (validate.sh:171–193) remove them; this item verifies they did. If a
     tree survives, `rm -rf` it (it is a test artifact, never operator state) and treat
     the surviving-trap as a failure to investigate, not silently clean.
4. **Conditional failure handling**: if a suite fails or leaks, fix in the OWNING
   subtask's scope only:
   - concurrency.sh runner conversion bugs → scope of P4.M2.T2.S1
   - the caller-mode E2E body → scope of P4.M2.T2.S2
   - release_reaper/transparency bodies → the suite file itself, minimal fix
   - lib/pool.sh behavioral bug → fix the code (that's the point of the gate)
   NEVER weaken/delete asserts; NEVER edit shared framework code in validate.sh
   (`setup`/`run_test`/assert helpers/`_run_selftest_suite`). Re-run to green.
5. **Optional-skip logic**: if P4.M2.T2.S2 was skipped (its body absent), that is fine —
   run whatever `test_` bodies concurrency.sh contains (the two pre-existing ones) and
   report the manifest: `grep -n '^test_' test/concurrency.sh`.
6. **Docs**: none (per item contract).

### Success Criteria

- [ ] All three suites rc 0, `0 failed`, logs recorded under `P4M2T3S2/research/`.
- [ ] Per-suite + final leak audits empty (no net-new chrome/abpool/sleep processes;
      zero `/tmp/abpool-*` trees).
- [ ] install.sh: static-clean + untouched (git proof recorded).
- [ ] Any fix confined to owning-subtask scope; no framework/assert weakening.

## All Needed Context

### Context Completeness Check

An agent new to this repo needs: the blessed invocations, what the suites do (real
Chrome, real master profile, real agent-browser), how the traps clean up, and exactly
what "zero leaks" means operationally. All pinned below; no external research needed.

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/architecture/test_framework.md
  why: THE map. §10 blessed invocations (exact forms quoted in What/step 2); §3 hermetic
    setup + EXIT-trap glob backstops (/tmp/abpool-test.*, /tmp/abpool-pi.*); §8 the
    approved single-setup runner; §13 landmines LM-1..LM-8 (esp. LM-4 kill+wait,
    LM-6 single-slot ABPOOL_CUR_OWNER, LM-8 suites touch REAL master/binary).
- file: plan/004_de5e94ac127c/architecture/synthesis.md (§3)
  why: acceptance gate definition + blessed invocations + S1–S4/E2E inventory.
- file: plan/004_de5e94ac127c/P4M2T2S1/PRP.md
  why: CONTRACT for the concurrency.sh single-setup runner (_abpool_run_concurrency_suite,
    one setup() call, `if "$fn"` main-shell bodies). Assume delivered exactly as written;
    its runner is what this item exercises.
- file: plan/004_de5e94ac127c/P4M2T2S2/PRP.md
  why: CONTRACT for the optional caller-mode two-child E2E body. If present it must be
    green under the same 240 s budget; if absent, step 5 logic applies.
- file: plan/004_de5e94ac127c/P4M2T3S1/PRP.md
  why: PARALLEL sibling covering test/validate.sh ONLY (Chrome-free). Do not run or
    touch validate.sh's suite here beyond the fact that the others source its framework.
- file: test/concurrency.sh; test/release_reaper.sh; test/transparency.sh
  why: SUTs. Source ./validate.sh for framework. release_reaper + concurrency re-point
    AGENT_CHROME_MASTER/AGENT_BROWSER_REAL at the REAL host resources (LM-8) — do not
    "fix" that; hermetic for pool state only.
  gotcha: real windowed Chrome would pop on Hyprland — AGENT_CHROME_HEADLESS=1 is
    part of the blessed invocation, not optional styling.
- file: AGENTS.md §1–§3, §6
  why: isolated-sandbox mandate, timeout everything, reap process groups, hygiene
    checklist before ending the turn (this item's §6 IS the deliverable's audit).
- file: install.sh
  why: static-check target only (R6). Must remain untouched.
```

### Current Codebase tree (relevant)

```bash
test/concurrency.sh      # SUT — single-setup runner (P4M2T2.S1) + optional E2E body (S2)
test/release_reaper.sh   # SUT — real-Chrome release/reaper semantics
test/transparency.sh     # SUT — agent-facing transparency of wrapper errors
test/validate.sh         # framework (sourced; NOT run in this item)
install.sh               # static-check only
plan/004_de5e94ac127c/P4M2T3S2/research/   # OUTPUT: run logs, static log, leak audit
```

### Known Gotchas of our codebase & Library Quirks

- **G1 — real Chrome, real master, real binary.** These suites boot REAL headless
  Chrome, CoW-copy the REAL master profile, and call the REAL `~/.local/bin/agent-browser`.
  Isolated sandbox mandatory (AGENTS.md §1); the suites self-hermeticize POOL state
  (temp-tree HOME/state/ephemeral) but not those host reads.
- **G2 — timeout is non-negotiable** (240/300/180 per suite). If a suite shows no
  output for more than a few seconds of wall time beyond a normal boot (~4–5 s per
  real-Chrome test; whole suites are seconds), assume hang, abort, diagnose — do not
  wait out the timeout.
- **G3 — pipe rc**: `… | tee` reports tee's rc; assert on `${PIPESTATUS[0]}`.
- **G4 — guarded audits**: `pgrep`/`ls -d` return rc 1 on no match — always
  `|| echo`-guard or the audit itself aborts under `set -e`.
- **G5 — kill -0 is a trap** (AGENTS.md §4): ESRCH vs EPERM conflation. Use
  `pgrep -af` / `/proc` existence in any glue you write.
- **G6 — orphans must be killed as GROUPS**: `kill -- -<pgid>` (note `--`), then
  `wait` any child you own, else zombies false-alive (LM-4).
- **G7 — concurrent sibling**: P4.M2.T3.S1 (validate.sh) runs in parallel — do not
  collide with its run; sequence live suites serially, one at a time, in your sandbox.
- **G8 — the trap glob backstops are the cleanup mechanism being audited** — do not
  pre-delete `/tmp/abpool-*` before the suite runs (that would mask a trap failure).

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: STATIC checks + install.sh proof
  - RUN: bash -n + shellcheck on install.sh + the three test files
  - RUN: git status --porcelain install.sh (expect empty)
  - WRITE: research/install_static.log

Task 2: BASELINE process snapshot
  - RUN: pgrep -af 'chrome|chromium|abpool|agent-browser' | sort > research/baseline_pids.txt || true
  - WHY: the post-suite diff must distinguish operator's own Chrome from our leaks (G1 audit)

Task 3: RUN concurrency.sh (isolated sandbox, headless, bounded)
  - RUN: AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh 2>&1 | tee research/concurrency_run.log
  - ASSERT: rc 0 (PIPESTATUS[0]), "0 failed", body manifest grep -n '^test_' all PASS
  - AUDIT: pgrep diff vs baseline + /tmp glob check → append research/leak_audit.log

Task 4: RUN release_reaper.sh
  - RUN: AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh 2>&1 | tee research/release_reaper_run.log
  - ASSERT + AUDIT: same as Task 3

Task 5: RUN transparency.sh
  - RUN: AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh 2>&1 | tee research/transparency_run.log
  - ASSERT + AUDIT: same as Task 3

Task 6: (conditional) FIX any failure/leak in OWNING subtask scope → re-run that suite
  - NEVER weaken asserts; never edit validate.sh framework helpers
  - lib/pool.sh bugs → fix the code, that is the gate's purpose

Task 7: FINAL hygiene audit + wrap-up (AGENTS.md §6 checklist)
  - RUN: guarded pgrep/ls audit; record final block in leak_audit.log
  - RUN: git status --porcelain (expect only plan/004_de5e94ac127c/P4M2T3S2/research/* additions)
  - CONFIRM: zero orphaned chrome/sleep/timeout/bash processes from your runs
```

### Integration Points

None — validation-only item. No source, config, or docs changes (except
owning-scope failure fixes per Task 6).

## Validation Loop

Levels 1–3 ARE Tasks 1–7: static (L1), each green suite (L2/L3 — the suites are the
system-level validation), leak audit (the domain-specific L4). No additional
validation exists or is needed.

## Final Validation Checklist

- [ ] Static: zero warnings on install.sh (+ syntax-clean on all three suites)
- [ ] install.sh untouched (git proof in install_static.log)
- [ ] All three real-Chrome suites rc 0, 0 failed, logs recorded
- [ ] Per-suite + final leak audits empty (no net-new processes; zero /tmp/abpool-* trees)
- [ ] No weakened asserts, no framework edits, fixes confined to owning scope
- [ ] Nothing left running; no temp dirs from these runs remain
- [ ] research/ contains: 3 run logs, install_static.log, leak_audit.log, baseline_pids.txt, notes.md

## Anti-Patterns to Avoid

- ❌ Never run a real-Chrome suite outside the isolated sandbox or without its
  `timeout` (AGENTS.md §1–§2) — this is THE rule this repo exists around.
- ❌ Never make a leak "disappear" by pre-cleaning `/tmp/abpool-*` before a run (G8)
  or by killing-orphaning without `wait` (G6).
- ❌ Never weaken/delete an assert or touch validate.sh framework helpers to get green.
- ❌ Never run suites in parallel with each other or with the S1 validate.sh run (G7).
- ❌ Don't add env overrides to the blessed invocations — they must pass as written.

## Confidence Score

9/10 — validation-only; every invocation, timeout, trap path, and landmine is already
documented in-repo (test_framework.md §10/§13), and the sibling PRP contracts define
the runner/E2E under test. The only contingency (owning-scope fix on failure) is
explicitly bounded.