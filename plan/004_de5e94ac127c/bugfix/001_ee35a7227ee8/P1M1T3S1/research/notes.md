# Research Notes — P1.M1.T3.S1 (major-fix integration gate runbook)

Static read only — no suites were run during research (AGENTS.md §1: research must not execute the
process-spawning suites; the gate itself is the implementer's job).

## Verified state at research time

- `test/bootrace.sh` EXISTS (21,758 B, T2.S1 landed). Static-clean: `bash -n` OK,
  `shellcheck -s bash -S warning` OK.
- Case list hardcoded in `_br_run_suite` (~line 418): `r1_bug001_guard_fs_agnostic`,
  `r2_bug001_recovery_e2e`, `r3_control_delayed_boot_succeeds`, `r3_bug002_race_e2e`,
  `r4_bug002_preport_race` — **5 cases today; T2.S4's PRP adds
  `r3_neg_dead_ids_release_still_kills` → 6 at gate time.** Grep the list; don't hardcode.
- `_bootrace_setup` uses `mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX` → sandbox under $HOME
  (real FS/btrfs — deliberate for BUG-001), NOT /tmp. Sweep $HOME for abpool-bootrace.* roots.
- Suite summaries: `printf '\n%d passed, %d failed\n'` + `(( BR_FAIL > 0 )) && return 1`.
- `git status --short` shows ` M lib/pool.sh` — T2.S4 in flight (boot lock/widened sweep landing).
  Gate preflight MUST confirm S4's case exists before running.
- Repo suites are self-isolating; canonical invocation per test_framework.md §1: `bash
  test/<suite>.sh` from repo root, exits 0 iff all cases pass. Expected green (PRD h2.0):
  validate 33/33, release_reaper 5/5, transparency 10/10, concurrency 3/3.

## Key runbook decisions (reflected in the PRP)

1. **Preflight gate**: grep for `r3_neg_dead_ids_release_still_kills` in test/bootrace.sh +
   `pool_lane_boot_lock` in lib/pool.sh — if absent, S4 hasn't landed → STOP, record, do not run.
2. **Timeouts**: bootrace 300s (its own inner timeouts are 30–90s per command); validate 600s
   (largest, 1639 LOC / 33 cases); the other three 300s each. Suite-timeout (rc 124) = HANG finding:
   sweep first, one bounded retry max.
3. **Leak sweep is observational, test-scoped**: the operator runs REAL pooled Chromes on
   `~/.agent-chrome-profiles/active/{1,7}` plus sibling pi sessions (observed live during research).
   Patterns: `abpool-bootrace`, `fake-cdp`, `fakechrome`, `FAKE_CHROME`,
   `user-data-dir=.*bootrace`, `user-data-dir=/tmp/tmp\.`. Never blanket-pkill; kill only
   unambiguous test fakes, by process group, with wait.
4. **Leftover temp roots**: $HOME/abpool-bootrace.*, /tmp/abpool-*, /tmp/fake-cdp.*.
   Sibling-session /tmp/tmp.* dirs are NOT ours.
5. **Finding discipline** (item contract §3): record failures verbatim with the owning subtask
   (T1.S1=copy guard, T2.S2=boot lock, T2.S3=ensure_connected, T2.S4=release sweep); never edit
   suites/lib to make red green.
6. **Output**: research/gate_results.md (summary table + per-case lines + findings + verdict) +
   raw logs — consumed as-is by P1.M3.T1.S1, which re-runs the matrix after P1.M2 adds R5–R9
   (hence: record the case-list snapshot).

## References used

- architecture/test_framework.md §1/§4/§5 (runner contract, R-matrix, safety checklist)
- architecture/system_context.md §11 (house style), §6 (teardown contract)
- P1M1T2S4/PRP.md (the in-flight dependency: widened (3b) sweep + negative-control case)
- prd_snapshot.md h2.0 (baseline counts), h2.2 (BUG-001/002 repros R1–R4 encode)