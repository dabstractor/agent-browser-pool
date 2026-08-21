# Final changeset regression gate — P1.M3.T1.S1

- **Date**: 2026-08-21 19:07–19:20 UTC
- **HEAD**: `03e4e25` (note: PRP referenced 1bbc3d0; tree has advanced)
- **Tree status at Task 0** (`git status --short`):
  - ` M plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/tasks.json` (orchestrator-owned, not this gate's change)
  - `?? …/P1M3T1S1/research/preflight.txt` (this gate)
- **All commands run from the repo root** (`/home/dustin/projects/agent-browser-pool`).

## Preflight (Task 0): PASS

All changeset artifacts confirmed by content-grep (see `preflight.txt`):

| artifact | evidence |
|---|---|
| BUG-005 help fix | `lib/pool.sh:5251` — `replaces the default pi,claude,codex,agy,antigravity` |
| r8 case + runner entry | `test/bootrace.sh` — 2 matches for `r8_bug005_help_harnesses_contract` |
| BUG-006 ROOT fix | `plan/004_de5e94ac127c/validate.sh:28` — `…/../.." && pwd)"` |
| r9 def | `test/bootrace.sh:672` — `r9_bug007_lock_timeout_grace()` |
| r9 runner entry | `test/bootrace.sh:775` — r9 in the runner for-list |
| boot lock sanity | `lib/pool.sh` — 9 matches for `pool_lane_boot_lock` |

**Case-list snapshot** (12 cases — the PRP expected 11; see Finding F2):

```
r1_bug001_guard_fs_agnostic, r2_bug001_recovery_e2e, r3_control_delayed_boot_succeeds,
r3_bug002_race_e2e, r3_neg_dead_ids_release_still_kills, r4_bug002_preport_race,
r5_bug003_corrupt_lease_reclaimed, r6_bug003_release_corrupt_lease, r7_bug004_doctor_fresh_install,
r8_bug005_help_harnesses_contract, r9_bug007_lock_timeout_grace, r10_bug009_pin_corrupt_lease_sweep
```

## Summary table

| item | expected | got | rc | verdict |
|---|---|---|---|---|
| statics: lib/pool.sh | bash -n + shellcheck clean | OK / OK | 0 | PASS |
| statics: bin/agent-browser-pool | clean | OK / OK | 0 | PASS |
| statics: install.sh | clean | OK / OK | 0 | PASS |
| statics: test/validate.sh | clean | OK / OK | 0 | PASS |
| statics: test/release_reaper.sh | clean | OK / OK | 0 | PASS |
| statics: test/transparency.sh | clean | OK / OK | 0 | PASS |
| statics: test/concurrency.sh | clean | OK / OK | 0 | PASS |
| statics: test/bootrace.sh | clean | OK / OK | 0 | PASS |
| statics: plan/004…/validate.sh | clean | OK / **SC2164, SC2034 ×2 (findings)** | 0 | **FAIL** (F3) |
| bootrace R1–R9(+10) | 11 cases, 0 failed | **12 cases: 11 passed, 1 failed** (r9 FAIL) | 1 | **FAIL** (F1, F2) |
| test/validate.sh | `33 passed, 0 failed` | `33 passed, 0 failed` | 0 | PASS |
| test/release_reaper.sh | `5 passed, 0 failed` | `5 passed, 0 failed` | 0 | PASS |
| test/transparency.sh | `10 passed, 0 failed` | `10 passed, 0 failed` | 0 | PASS |
| test/concurrency.sh | `3 passed, 0 failed` | `3 passed, 0 failed` | 0 | PASS |
| plan validate.sh FULL run | zero path failures; `passed: 88 failed: 0` or better | zero path failures; **`passed: 97  failed: 1`** | 1 | **FAIL** (F4) |
| sweep: processes | zero test-scoped hits | zero (all pgrep hits were the sweep's own argv) | — | PASS |
| sweep: temp roots | zero leftover roots | 21 `/tmp/fake-cdp.*` dirs → **F1 recurs**, cleaned, zero remain | — | PASS (after clean) |

## Per-item results (verbatim extracts)

### Statics (`static.log`)

8/9 files fully clean. `plan/004_de5e94ac127c/validate.sh` (bash -n OK) shellcheck findings:

```
line 29:  SC2164 (warning): Use 'cd ... || exit' …  (cd "$ROOT")
line 50:  SC2034 (warning): sc_errs appears unused.
line 468: SC2034 (warning): i appears unused.
```

### bootrace (`bootrace.log`, `timeout 300`, rc=1)

```
== r1_bug001_guard_fs_agnostic        PASS
== r2_bug001_recovery_e2e             PASS
== r3_control_delayed_boot_succeeds   PASS
== r3_bug002_race_e2e                 PASS
== r3_neg_dead_ids_release_still_kills PASS
== r4_bug002_preport_race             PASS
== r5_bug003_corrupt_lease_reclaimed  PASS
== r6_bug003_release_corrupt_lease    PASS
== r7_bug004_doctor_fresh_install     PASS
== r8_bug005_help_harnesses_contract  PASS
== r9_bug007_lock_timeout_grace       FAIL
== r10_bug009_pin_corrupt_lease_sweep PASS
final: 11 passed, 1 failed
```

R9 failure verbatim:

```
== r9_bug007_lock_timeout_grace
FAIL: R9: lease chrome_pid=59846 not among launched (none)
   FAIL
```

Note: r9's other assertions (rc_a=0, rc_b=0, `boot lock busy` fired, exactly 1 chrome launch) all
passed; only the final lease-pid-∈-launched cross-check failed. The case's fixture line
`awk '{print \$1}' "$FAKE_CHROME_COUNT_FILE"` (test/bootrace.sh, r9 body) contains an escaped `\$1`
inside single quotes, so the pid list it builds cannot ever match a numeric lease pid — a likely
fixture bug in the r9 case itself (owner: M2.T4.S1 / parallel item), not necessarily a product
regression. Recorded as observed; not fixed or weakened by this gate.

### Repo suites (exact tails, rc 0 each)

```
validate.log        → 33 passed, 0 failed   (rc 0)
release_reaper.log  → 5 passed, 0 failed    (rc 0)
transparency.log    → 10 passed, 0 failed   (rc 0)
concurrency.log     → 3 passed, 0 failed    (rc 0)
```

Reminder (M1T3S1 quirk, still true): `validate.log` contains an INTENTIONAL
`FAIL: assert_eq (intentional mismatch): expected [abc] got [xyz]` line — that is validate's own
self-test case PASSING. The summary line + rc 0 are the verdict.

### plan validate.sh FULL run (`planvalidate.log`, `timeout 1800`, from repo root, rc=1)

```
grep -c 'No such file or directory' → 0        (BUG-006 path promise: KEPT)
summary: passed: 97  failed: 1
Failed checks:
  - suite: test/bootrace.sh rc=1
```

97 checks ≥ the 88 promised; the single failure is the same r9 case as above (F1 cascades here).
No `--fast` fallback used — the full run completed in-environment.

vs `validation_report.md`: the report predates the current tree and contains no machine summary
line to diff (its prose cites per-area results, e.g. "33/33, 10/10, 5/5, 3/3" — all of which this
gate reconfirms). Nothing edited (orchestrator-owned).

## Findings

- **F1 — R9 bootrace case FAILs**: `FAIL: R9: lease chrome_pid=59846 not among launched (none)`.
  Only the pid cross-check fails; rc/grace-count/double-launch assertions pass. Likely fixture
  bug in the r9 case (escaped `\$1` in its awk pid extraction). Owner: M2.T4.S1 (parallel item).
  Not fixed, not weakened by this gate. This also makes `plan validate.sh` report 1 failed.
- **F2 — case-count drift**: bootrace now has **12** cases (r10_bug009_pin_corrupt_lease_sweep
  added) vs the PRP's expected 11. All 12 ran; 11 passed. Recorded as drift, not a failure.
- **F3 — shellcheck findings in plan/004_de5e94ac127c/validate.sh**: SC2164 (line 29),
  SC2034 ×2 (lines 50, 468) at `-S warning`. The file's own internal check runs shellcheck at a
  lower severity, so its self-run stays green. Owner: parallel item's file — not edited.
- **F1-recurs (temp-root leak, known from the M1 gate)**: 21 `/tmp/fake-cdp.*` dirs left by the
  suites (no processes held them). Cleaned (`rm -rf /tmp/fake-cdp.*`); zero remain. Attributed to
  suite fixtures — minor-fix candidate, not this gate's.

## Verdict

**GATE RED (PARTIAL)** — Preflight PASS; statics 8/9 clean (plan validate.sh has 3 warning-level
shellcheck findings — F3); repo suites exact-green **33 / 5 / 10 / 3, rc 0 each**; bootrace
**11 passed, 1 failed** of 12 cases (F1: the r9 case's lease-pid cross-check, likely a fixture
bug owned by M2.T4.S1 — F2: 12 cases present vs 11 expected); plan validate.sh full run from the
repo root: **zero path failures** (BUG-006 promise kept) and **`passed: 97  failed: 1`** — the 1
failure is the same r9 cascade. Sweep: zero orphan processes; F1-recurs temp roots cleaned to
zero. The single blocking item is the r9 bootrace case; once its owning subtask resolves it, this
gate's matrix should be re-run to convert the verdict to GATE GREEN.