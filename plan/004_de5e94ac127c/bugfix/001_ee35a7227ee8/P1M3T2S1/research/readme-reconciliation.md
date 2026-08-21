# Research — README.md reconciliation for changeset 001 (BUG-001..006)

**Date:** 2026-07-13 · **Task:** P1.M3.T2.S1 (bugfix `001_ee35a7227ee8`)
**Method:** read-only — full `cat -n README.md` (502 lines at HEAD `6fdbd82`), `git diff
7154d99..HEAD -- README.md`, `git log`, targeted greps of `lib/pool.sh` / `test/bootrace.sh`.
No suites run, no Chrome booted (AGENTS.md §1).

---

## 1. Line map — and the DRIFT warning

The item outline's anchors predate the M2 doc commits (`1f966b1`, `1837ca8`, `1bbc3d0`),
which added ~9 lines to the Admin section. Actual current anchors:

| Section | outline | ACTUAL | locate-by (robust) |
|---|---|---|---|
| Status | 24 | **24-29** | `## Status` |
| Admin: reap / release / doctor | 236/251/269 | **236 / 253 / 275** | `### reap` / `### release` / `### doctor` |
| Configuration reference | 301 | **310** | `## Configuration reference` |
| AGENT_BROWSER_POOL_HARNESSES row | 320 | **329** | `grep -n 'AGENT_BROWSER_POOL_HARNESSES'` |
| How it works | 341 | **350** | `## How it works` |
| Troubleshooting (harness/exhaust/pinned/Leaks) | 384/395/409/424/443 | **393/404/418/433/452** | `### Leaks` |
| Repository layout | 458 | **467** | `## Repository layout` |

**Rule for the implementer: locate by TEXT anchor (grep), never by line number.**

## 2. The five contract decisions, with landed-code evidence

### (a) How it works — ADD one paragraph (the ONLY new content besides (c))

Verified landed behavior (lib/pool.sh):
- `pool_lane_boot_lock N` (line 293) echoes **`$POOL_LANES_DIR/<N>.boot.lock`** — empty
  advisory flock target, fd 8 exclusively (fd 9/acquire.lock reserved), harmless if stale.
- `pool_boot_lane` wraps copy/port/launch/connect in `( flock -w 20 8 && … )
  8>"$(pool_lane_boot_lock "$lane")"` (line ~2703) with a post-lock idempotent re-boot check
  (commit `1cbca8d`).
- `pool_ensure_connected` takes the SAME lock on fd 8 (line ~2957, `_pool_ensure_connected_locked`)
  so reconnect and boot are mutually exclusive (commit `039e88a`).
- `pool_copy_master TARGET_DIR` (line 1272) is guarded (commit `8ad9fc5`, BUG-001): any stale
  leftover dir at the target is wiped (`rm -rf` on the guard paths, lines 1352/1364) before the
  fresh `cp -a --reflink=always` from the master — the copy can never nest inside / trust a
  stale partial dir.

Insertion point: between the numbered "Lane lifecycle ordering (`pool_wrapper_main`)" list
(item 8 "exec …") and the "**Release** happens …" paragraph (~387). Anchor:
`grep -n '\*\*Release\*\* happens' README.md` — insert immediately BEFORE that line.

### (b) Troubleshooting › Leaks — APPEND two facts to the Fix ¶

Contract: mention (i) corrupt leases are now reclaimable by reap/release, and (ii) release
sweeps any Chrome still on a lane dir even when the lease ids are dead.

The Fix ¶ currently ends: "… `WARN`s are advisory cruft that `reap`/`release` clear and do not
change the exit code. See PRD.md §2.15." → insert the new sentences BEFORE "See PRD.md §2.15."

Code evidence: corrupt-lease branches landed in `1f966b1` (reap removes corrupt `lanes/<N>.json`
once its dir is gone) and `1837ca8` (release N clears it, killing Chrome on the dir; release all
skips corrupt); the dead-id sweep widening landed in `5cc6c24` (mid-boot cmdline sweep fires when
recorded ids are positive-but-dead, not only ≤0).

### (c) Repository layout — ADD test/bootrace.sh (currently MISSING)

The `test/` block (verbatim, lines 479-484):

```
└── test/
    ├── validate.sh            ← test framework (assertions, owner sim, hermetic setup/teardown)
    ├── concurrency.sh         ← N agents → N distinct lanes, no collision
    ├── release_reaper.sh      ← release + stale reaper + crash simulation
    └── transparency.sh        ← dispatch + classification contract checks
```

`test/bootrace.sh` exists on disk (confirmed) and is NOT listed. Edit: `transparency.sh`
becomes `├──`, append `└── bootrace.sh` line after it (smallest diff; ordering stays
"framework first, then suites"). 11 cases on disk: `r1_bug001_guard_fs_agnostic`,
`r2_bug001_recovery_e2e`, `r3_control_delayed_boot_succeeds`, `r3_bug002_race_e2e`,
`r3_neg_dead_ids_release_still_kills`, `r4_bug002_preport_race`, `r5_bug003_corrupt_lease_reclaimed`,
`r6_bug003_release_corrupt_lease`, `r7_bug004_doctor_fresh_install`, `r8_bug005_help_harnesses_contract`
(+ `r9_…` from parallel M2.T4.S1). Harness: fake Chrome (launch-delay knob) + fake
agent-browser; single-setup runner (AGENTS.md §4 compliant).

### (d) Status — NO edit (verified: it does NOT enumerate suite counts)

Lines 24-29 say "…implemented and tested. See **Installation**…". No per-suite counts → the
contract's "refresh only if it enumerates suite counts" resolves to **no change**. IF it had
counts, the numbers would come from the parallel gate's record
`…/P1M3T1S1/research/gate_results.md` (suites 33/5/10/3; bootrace 11 passed 0 failed; plan
validate.sh `passed: 88 failed: 0` or better) — record the decision, don't add counts that
weren't there.

### (e) Configuration table — NO edit (verified: row already correct)

Row 329 (`AGENT_BROWSER_POOL_HARNESSES`) already reads "…Empty/unset → default (never empty)"
— replace semantics, matching the fixed help text in lib/pool.sh
(`grep -n 'replaces the default pi,claude,codex,agy,antigravity' lib/pool.sh`, commit `6fdbd82`,
BUG-005 was help-only). README was already right.

## 3. Mode-A lines — verify consistent, do NOT re-edit

Landed by the M2 commits (git diff `7154d99..HEAD` confirms):
- reap (238-243): "A corrupt/unparseable `lanes/<N>.json` left behind after its lane dir is
  gone is also removed, freeing the lane number."
- release (255-259): "A corrupt or unparseable `lanes/<N>.json` is also cleared (killing any
  Chrome still on that lane's profile dir — the lease contents can't be trusted), freeing the
  lane number. (`release all` does not clear corrupt leases; use `release N` or `reap`.)"
  + example "Released lane 7 (corrupt lease cleared)."
- doctor (281-283): "If the ephemeral root directory does not exist yet, `doctor` creates it —
  so the btrfs check is exact on fresh installs …"

Consistency read: all three agree with each other and with (b)'s new sentences
(release-all-skips-corrupt appears in the release §; the Leaks addition must repeat the same
rule, not contradict it). Expectation: zero edits here; only flag if a contradiction exists.

## 4. Doc surfaces (system_context §1) — scope fence

- `docs/` is EMPTY. User docs = `README.md` (this task) + `.agents/skills/agent-browser-pool/`
  (`SKILL.md`, `README.md`, `references/configuration.md`) — **the skill dir is P1.M3.T2.S2's
  job, NOT this task's. Touch nothing under `.agents/`.**
- README is the only file this task edits. PRD.md, plan/** (tasks.json, validation_report.md,
  validate.sh), lib/, test/, bin/, install.sh: read-only.