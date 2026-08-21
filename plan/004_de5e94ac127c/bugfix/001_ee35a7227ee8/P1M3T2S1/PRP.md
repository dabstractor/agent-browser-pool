# PRP — P1.M3.T2.S1: README.md — reconcile crash-recovery / leases / doctor / repo-layout sections with the changeset

> **Bugfix context**: Final doc-sync for changeset 001 (`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/`,
> BUG-001..BUG-006). All code fixes have landed (HEAD `6fdbd82`; M1: `8ad9fc5`/`1cbca8d`/`039e88a`/`5cc6c24`,
> M2: `1f966b1`/`1837ca8`/`1bbc3d0`/`6fdbd82`). The per-command Admin sentences (reap/release/doctor)
> were already synced **by those M2 commits** ("Mode-A lines" — verified, do not re-edit). THIS task
> reconciles the remaining OVERVIEW surfaces: one crash-recovery paragraph in "How it works", two
> facts in Troubleshooting › Leaks, and the missing `test/bootrace.sh` entry in Repository layout.
> The parallel gate (P1.M3.T1.S1) produces the validation record; Status cites counts **only if it
> already enumerates them** (it does not — verified). **Keep edits minimal and factual. No marketing.**

---

## Goal

**Feature Goal**: Make README.md's overview sections describe the code as it now is, without
rewriting anything that is already correct. Exactly three content edits:

1. **"How it works"** — insert ONE short paragraph (between the numbered lane-lifecycle list and
   the **Release** paragraph): same-owner lane boots/connects are serialized by a per-lane boot
   lock (`lanes/<N>.boot.lock`), and a re-booted crashed lane wipes its stale partial dir before
   re-copying the master (trusted identity preserved).
2. **Troubleshooting › Leaks** — append to the Fix paragraph: corrupt leases are now reclaimable
   by `reap` / `release N`, and the release sweep kills any Chrome still on a lane dir even when
   the lease's recorded ids are dead.
3. **"Repository layout"** — add the missing `test/bootrace.sh` line to the test/ block.

Plus two **verified no-op decisions** (record the check, make no edit): (d) Status does NOT
enumerate suite counts → no refresh; (e) the `AGENT_BROWSER_POOL_HARNESSES` config row already
documents replace semantics correctly → no change (BUG-005 was help-text-only).

**Deliverable**: `README.md` modified with exactly those three hunks (plus zero-content-consistency
fixes if — and only if — a contradiction with the landed Mode-A lines is found; expectation: none).
Research already recorded at `…/P1M3T2S1/research/readme-reconciliation.md` (line map, verbatim
anchors, code evidence, no-op decisions). No other file changes.

**Success Definition**:
- `git diff README.md` shows exactly the three hunks (expected shape: +~3 lines in How it works,
  ±0-2 lines in Leaks, +1/-1 lines in Repository layout) and `git diff --check README.md` is clean
  (no trailing whitespace).
- Each new factual claim greps to exactly one occurrence in README and is backed by landed code
  (verification commands in the Validation Loop).
- The Leaks addition agrees verbatim-in-spirit with the landed release § sentence ("`release all`
  does not clear corrupt leases") — no contradiction.
- Status section, configuration table, Admin sections, and everything under `.agents/` are
  **byte-identical** before vs after (verified by diff-scope check).

## User Persona

**Target User**: (1) the human operator reading the README to understand what the pool guarantees
(crash recovery, leak reclamation) and what lives in the repo; (2) AI agents onboarding via the
README before reading the skill dir; (3) future auditors of changeset 001 diffing docs vs code.

**Use Case**: An agent's lane crashed mid-boot or a previous session leaked state; the operator
reads "How it works" + "Leaks" to learn that the next same-owner command serializes on a boot
lock, re-copies a clean profile, and that `reap`/`release` can clear even corrupt leases and
dead-id Chromes — no manual cleanup needed.

**Pain Points Addressed**: README currently (a) documents the boot lifecycle but not its
serialization or crash-recovery re-copy — the exact guarantees BUG-001/002 added; (b) documents
leak flags but not that corrupt leases and dead-id Chromes are now reclaimable — the exact
guarantees BUG-003/002-fix added; (c) omits `test/bootrace.sh` from the layout, so the changeset's
regression harness is invisible.

## Why

- **Docs must match shipped behavior at changeset close.** The six bug fixes changed observable
  guarantees (boot serialization, guarded re-copy, corrupt-lease reclamation, dead-id sweep,
  doctor on fresh installs). The Admin verbs' sections were synced by the M2 commits; the overview
  sections that promise system-level behavior were not — this task closes that gap.
- **The repo layout is the entry map.** A reader scanning the layout cannot find the bootrace
  harness that guards the two major bugs; one line fixes it.
- **Minimal, verifiable edits.** Every edit is anchored to landed code (commit + line evidence in
  the research note), so review is a three-hunk diff check, not a judgment call.

## What

User-visible behavior: README renders as before with three additions. Exact edits:

### Edit 1 — "How it works": insert one paragraph

**Anchor**: `grep -n '\*\*Release\*\* happens' README.md` (currently ~line 387). Insert the new
paragraph — separated by blank lines — immediately BEFORE that line (i.e., after the numbered
"Lane lifecycle ordering" list, item 8).

**New paragraph (verbatim)**:

```markdown
**Boot serialization & crash recovery.** A lane's boot and any later reconnect/relaunch are
serialized by a short-lived per-lane boot lock (`lanes/<N>.boot.lock`), so two same-owner
commands cannot race two Chromes onto one lane — a reconnect waits (up to ~20s) rather than
launching alongside an in-flight boot. When a crashed lane is re-booted (its lease still says
port 0 — the boot never finished), `pool_copy_master` first wipes any stale partial dir left at
`active/<N>` and re-copies fresh from the master, so the lane always boots trusted master
contents — never a half-copied leftover.
```

Facts check (landed code): lock path `pool_lane_boot_lock` → `$POOL_LANES_DIR/$1.boot.lock`
(lib/pool.sh:293-296); `flock -w 20` on fd 8 around `pool_boot_lane` (~:2703) and
`_pool_ensure_connected_locked` (~:2957); guarded wipe in `pool_copy_master` (~:1272, rm -rf
paths :1352/:1364, commit `8ad9fc5`).

### Edit 2 — Troubleshooting › Leaks: append to the Fix paragraph

**Anchor**: the Fix ¶ ends "…`WARN`s are advisory cruft that `reap`/`release` clear and do not
change the exit code. See PRD.md §2.15." Insert the new sentences AFTER "…change the exit code."
and BEFORE "See PRD.md §2.15." (same paragraph).

**Insert (verbatim)**:

```markdown
Corrupt leases are reclaimable too: `reap` removes a corrupt `lanes/<N>.json` once its lane
dir is gone, and `release <N>` clears it — killing any Chrome still on that lane's profile dir
even when the lease's recorded ids are dead (`release all` skips corrupt leases; use
`release <N>` or `reap`).
```

Must not contradict the landed release § (255-259): both say `release all` skips corrupt leases. ✓

### Edit 3 — Repository layout: add test/bootrace.sh

**Anchor**: the test/ block (currently ~479-484). Replace the last two lines:

```diff
-    └── transparency.sh        ← dispatch + classification contract checks
+    ├── transparency.sh        ← dispatch + classification contract checks
+    └── bootrace.sh            ← boot-race regression harness (serialized lane boot, guarded master copy, crash recovery)
```

(Insertion position: after `transparency.sh`, becoming the new last entry — smallest diff; the
block's ordering stays "framework first, then suites". Match the existing arrow-column alignment;
`bootrace.sh` and `validate.sh` are both 11 chars so the padding mirrors exactly.)

### Verified no-ops (record the check; make NO edit)

- **(d) Status (24-29)**: does NOT enumerate suite counts ("…implemented and tested. See
  **Installation**…") → no refresh. If (unexpectedly) counts ARE found: update them from the
  parallel gate record `…/P1M3T1S1/research/gate_results.md` (suites 33/5/10/3; bootrace
  `11 passed, 0 failed`; plan validate.sh `passed: 88 failed: 0` or better) — cite verbatim.
- **(e) `AGENT_BROWSER_POOL_HARNESSES` row (~329)**: already documents replace semantics
  ("Empty/unset → default (never empty)") matching the fixed help text
  (`grep -n 'replaces the default pi,claude,codex,agy,antigravity' lib/pool.sh`) → no change.

### Success Criteria

- [ ] Edit 1 present: `grep -c 'Boot serialization & crash recovery' README.md` == 1, and
      `lanes/<N>.boot.lock` appears exactly once in README.
- [ ] Edit 2 present: `grep -c 'Corrupt leases are reclaimable too' README.md` == 1; the sentence
      sits before "See PRD.md §2.15." in the Leaks Fix ¶.
- [ ] Edit 3 present: `grep -c 'bootrace.sh' README.md` == 1 (Repository layout) and the block's
      tree glyphs remain well-formed (one `└──` as the last test/ entry).
- [ ] No-op checks recorded: Status has no suite counts; HARNESSES row unchanged
      (`git diff README.md` contains no hunk touching either region).
- [ ] `git diff README.md` == exactly 3 hunks; `git diff --check README.md` clean.
- [ ] No other file modified (`git status --porcelain` shows only `M README.md` + this task's
      `plan/` research additions).
- [ ] No contradiction with the landed Mode-A sentences (reap 238-243 / release 255-259 /
      doctor 281-283) — compared line-by-line.

## All Needed Context

### Context Completeness Check

**Could someone with zero codebase knowledge implement this?** → Yes. The three edits are given
verbatim with grep-based anchors (robust to the +9-line drift the M2 commits introduced); every
factual claim is tied to a landed commit + lib/pool.sh line; the two no-op decisions are spelled
out with their verification greps; the scope fence (what NOT to touch) is explicit; the research
note carries the full line map and code evidence.

### Documentation & References

```yaml
- file: README.md
  why: THE file being edited — 502 lines at HEAD. Line anchors in the item outline are ~9-11
        lines stale (M2 doc commits); locate sections by grep, not line number.
  pattern: existing prose style — bold lead-ins ("**Boot serialization & crash recovery.**"
        mirrors "**Release** happens…"), inline code ticks for paths/functions, one-line arrows
        ("← …") in the layout tree.
  gotcha: do NOT reflow or re-wrap untouched paragraphs; the diff must be minimal.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T2S1/research/readme-reconciliation.md
  why: THIS task's research — line map, the five contract decisions with landed-code evidence
        (lock path/fd/timeout, copy guard, sweep widening, bootrace case list), Mode-A
        verification, doc-surface scope fence.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: §1 doc surfaces (docs/ EMPTY; user docs = README.md + .agents/skills/agent-browser-pool/ —
        the skill dir is P1.M3.T2.S2's, NOT this task's); §2 locking model background for the
        boot-lock paragraph; §5-§10 the six bug confirmations.
  gotcha: scope fence — touch nothing under .agents/.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T1S1/PRP.md   # parallel — CONTRACT
  why: the gate running in parallel produces …/P1M3T1S1/research/gate_results.md (per-suite
        counts + plan validate.sh summary). This PRP consumes it ONLY in the Status-refresh
        branch — which resolves to no-op (Status has no counts). Do not cite numbers that
        aren't already in README.
  gotcha: gate_results.md may not exist yet (parallel); the no-op decision does not depend on it.

- file: lib/pool.sh   (READ-ONLY evidence)
  why: :267-296 pool_lane_boot_lock (path + fd 8 + flock -w 20 idiom); ~:1272 pool_copy_master
        guarded wipe; ~:2703 pool_boot_lane flock; ~:2957 _pool_ensure_connected_locked;
        corrupt-lease reap/release branches; help text 'replaces the default…' (:grep).
  gotcha: never edit lib/pool.sh from this task.

- file: test/bootrace.sh   (READ-ONLY evidence)
  why: the harness being added to the layout — single-setup runner, fake Chrome (launch-delay
        knob) + fake agent-browser; 11 cases r1..r9 + r3_control/r3_neg (r9 from parallel
        M2.T4.S1).
  gotcha: do not run it (AGENTS.md §1 — research/planning forbids live execution).
```

### Current Codebase tree (relevant subset)

```bash
agent-browser-pool/            # HEAD 6fdbd82; all bugfix commits landed
├── README.md                  # ← THE ONLY FILE THIS TASK EDITS (502 lines)
├── lib/pool.sh                # evidence: boot lock / copy guard / sweep / help text
├── bin/agent-browser-pool · install.sh          # read-only
├── test/{validate,concurrency,release_reaper,transparency,bootrace}.sh  # read-only
├── .agents/skills/agent-browser-pool/           # P1.M3.T2.S2's scope — DO NOT TOUCH
└── plan/004_de5e94ac127c/
    ├── validate.sh · validation_report.md       # orchestrator-owned — read-only
    └── bugfix/001_ee35a7227ee8/
        ├── P1M3T1S1/           # parallel gate (research/gate_results.md when done)
        └── P1M3T2S1/           # THIS task (PRP.md + research/ — already written)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (line drift): the item outline's anchors predate the M2 doc commits (+~9 lines in the
#   Admin section). ALWAYS locate by grep anchor ('\*\*Release\*\* happens', '### Leaks',
#   '## Repository layout'), never by line number.

# CRITICAL (Mode-A fence): the reap/release/doctor sentences (238-243 / 255-259 / 281-283) were
#   landed BY the M2 commits. Verify them for consistency; do NOT re-edit, rephrase, or "improve".

# CRITICAL (scope fence): edit ONLY README.md. Off-limits: .agents/** (P1.M3.T2.S2), PRD.md,
#   plan/** (orchestrator-owned), lib/, test/, bin/, install.sh.

# GOTCHA (factual precision): the lock file is `lanes/<N>.boot.lock` (NOT <N>.lock), held on
#   fd 8 with `flock -w 20`; the re-copy wipe targets `active/<N>` ONLY on the crashed-boot
#   (port 0) path. Write exactly what the code does — no more.

# GOTCHA (markdown hygiene): the layout tree must keep well-formed glyphs (last test/ entry is
#   `└──`, others `├──`); match the existing arrow column (bootrace.sh == validate.sh width).
#   No trailing whitespace (git diff --check).

# GOTCHA (no live runs): this is a docs task. Verify claims by grep/read, NEVER by running the
#   suites or booting Chrome (AGENTS.md §1). The gate (P1.M3.T1.S1) owns runtime verification.
```

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 0: RE-BASE ANCHORS (the research line map may drift if parallel edits land)
  - RUN: grep -n '## Status\|### reap\|### release\|### doctor\|## Configuration reference' README.md
  - RUN: grep -n 'AGENT_BROWSER_POOL_HARNESSES\|## How it works\|\*\*Release\*\* happens\|### Leaks\|## Repository layout' README.md
  - EXPECT: all anchors found; note current line numbers. If any anchor moved, use the new
        location — the edits are text-anchored.

Task 1: EDIT 1 — How it works paragraph (verbatim text in "What › Edit 1")
  - INSERT the paragraph immediately BEFORE the '**Release** happens' line, blank lines either side.
  - VERIFY: grep -c 'Boot serialization & crash recovery' README.md == 1

Task 2: EDIT 2 — Leaks sentences (verbatim text in "What › Edit 2")
  - INSERT after "…do not change the exit code." and before "See PRD.md §2.15."
  - VERIFY: grep -c 'Corrupt leases are reclaimable too' README.md == 1

Task 3: EDIT 3 — Repository layout bootrace line (diff in "What › Edit 3")
  - CHANGE transparency.sh connector └── → ├──; APPEND the bootrace.sh └── line.
  - VERIFY: grep -c 'bootrace.sh' README.md == 1

Task 4: NO-OP CHECKS (record; edit nothing)
  - RUN: sed -n '/## Status/,/## Prerequisites/p' README.md → confirm NO suite counts → no edit.
  - RUN: grep -n -A2 'AGENT_BROWSER_POOL_HARNESSES' README.md → confirm replace semantics already
        documented ("Empty/unset → default (never empty)") → no edit.
  - RUN (consistency): read reap 238-243 / release 255-259 / doctor 281-283 (or their re-based
        locations) → confirm Edit 2's "release all skips corrupt leases" matches the release §.
        Only if a CONTRADICTION exists: fix the single inconsistent sentence (record why).

Task 5: FINAL REVIEW
  - RUN: git diff README.md   → expect exactly 3 hunks; git diff --check README.md → clean.
  - RUN: git status --porcelain → only ' M README.md' (+ this task's plan/ research, untracked).
```

### Integration Points

```yaml
INPUTS (all landed):
  - Changeset commits 8ad9fc5/1cbca8d/039e88a/5cc6c24/1f966b1/1837ca8/1bbc3d0/6fdbd82 (code facts).
  - M2 commits' README additions (Mode-A lines — verified, untouched).
  - Parallel gate P1.M3T1S1 → research/gate_results.md (consumed ONLY by the Status branch = no-op).

OUTPUTS:
  - README.md reconciled → consumed by P1.M3.T2.S2 (skill-doc sync, next task) as the source of
        truth for what the README now promises, and by the changeset close-out review.

OFF-LIMITS: .agents/**, PRD.md, plan/**, lib/, test/, bin/, install.sh.
```

## Validation Loop

### Level 1 — Diff shape

```bash
git diff --stat README.md        # 1 file, ~+5/-1 lines
git diff README.md               # exactly 3 hunks: How it works / Leaks / Repository layout
git diff --check README.md       # no whitespace errors
```

### Level 2 — Content assertions

```bash
grep -c 'Boot serialization & crash recovery' README.md          # 1
grep -c 'lanes/<N>.boot.lock' README.md                          # 1
grep -c 'Corrupt leases are reclaimable too' README.md           # 1
grep -c 'bootrace.sh' README.md                                  # 1
grep -n 'Corrupt leases are reclaimable' README.md               # line < the 'See PRD.md §2.15' line in Leaks
sed -n '/### Leaks/,/See PRD.md/p' README.md | tail -3           # new sentences end the Fix ¶
```

### Level 3 — Factual cross-checks against code (read-only)

```bash
grep -n 'boot.lock' lib/pool.sh | head -3                        # pool_lane_boot_lock echoes <N>.boot.lock
grep -n 'flock -w 20' lib/pool.sh | head -2                      # the ~20s wait claim
grep -n 'replaces the default pi,claude,codex,agy,antigravity' lib/pool.sh   # help text matches README row
ls test/bootrace.sh                                              # exists (layout line is truthful)
```

### Level 4 — Scope & hygiene

```bash
git status --porcelain          # only ' M README.md' (+ untracked plan/…/P1M3T2S1/)
grep -n 'release all' README.md # both occurrences (release § + Leaks §) agree on skipping corrupt leases
# markdown sanity: code fences balanced
[[ $(grep -c '^```' README.md) % 2 -eq 0 ]] && echo "fences balanced"
```

## Final Validation Checklist

- [ ] Exactly 3 hunks in `git diff README.md`; `git diff --check` clean.
- [ ] Edit 1/2/3 content assertions all pass (Level 2).
- [ ] Factual cross-checks pass (Level 3) — lock path, timeout, help text, bootrace existence.
- [ ] No-ops recorded: Status (no counts), HARNESSES row (already correct).
- [ ] Mode-A lines byte-identical (no contradiction introduced).
- [ ] Nothing outside README.md modified; `.agents/**` untouched.
- [ ] No suites run, no Chrome booted, zero processes/temp files left (AGENTS.md §1/§6).

## Anti-Patterns to Avoid

- ❌ Don't rewrite, re-wrap, or "improve" untouched sections — minimal diff is the contract.
- ❌ Don't re-edit the Mode-A Admin sentences (reap/release/doctor) — they landed with the M2
  commits; this task only verifies consistency.
- ❌ Don't add suite counts to Status or numbers from the gate record — Status has none today;
  the contract refreshes counts ONLY where they already exist.
- ❌ Don't touch the configuration table (BUG-005 was help-only; the row is already correct).
- ❌ Don't edit `.agents/skills/**` (P1.M3.T2.S2), PRD.md, plan/**, or any code/test file.
- ❌ Don't inflate prose — no marketing, no "robust/revolutionary"; state exactly what the code does.
- ❌ Don't run test suites to "verify" the docs — this task is text-only; the parallel gate owns
  runtime verification.
- ❌ Don't trust the item outline's line numbers — the M2 commits shifted anchors ~+9 lines;
  always re-base by grep.

---

**Confidence Score: 9/10** — the three edits are verbatim-ready with code-backed facts and
grep-anchored insertion points; the only residual risk is anchor drift from parallel work, which
Task 0's re-base step absorbs.