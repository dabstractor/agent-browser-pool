# PRP — P1.M3.T2.S2: Skill-docs sync (.agents/skills/agent-browser-pool/) with changeset-001 deltas

> **Bugfix context**: Terminal doc-sync of changeset 001 (BUG-001..BUG-006, all landed at HEAD
> `5f2a702`). S1 (README sync) runs in parallel — its landed/reconciled README is the **wording
> source of truth**; the per-command README admin sentences already landed with the M2 commits.
> THIS task sweeps the three skill files for statements the changeset invalidated, applies
> **five minimal factual edits**, and records the verified no-ops. **Do not restructure the
> skill. Do not touch README.md (S1 owns it).** Docs-only: verify by grep, never run anything
> (AGENTS.md §1).

---

## Goal

**Feature Goal**: Make the skill docs (`.agents/skills/agent-browser-pool/SKILL.md` +
`references/configuration.md`; `README.md` verified untouched) agree with the landed code and
the reconciled README. Exactly **5 small edits + 4 recorded no-op decisions**:

- **E1** configuration.md lifecycle: add one "Boot serialization & crash recovery." paragraph
  (per-lane boot lock, crashed-lane wipe-and-re-copy) — mirrors S1's README paragraph.
- **E2** configuration.md troubleshooting STALE row: corrupt leases are reclaimable
  (`reap` after dir gone; `release <N>` even with dir present; `release all` skips corrupt).
- **E3** configuration.md doctor-WARN row: `reap` clears stale lanes, orphan dirs, **and
  corrupt leases**.
- **E4** configuration.md Admin CLI doctor line: creates the ephemeral root if missing →
  btrfs check exact on fresh installs.
- **E5** SKILL.md §1: one sentence — concurrent commands from your session are safe
  (serialized boots/reconnects).

No-ops (verify, record, edit nothing): no skill statement ever claimed concurrent
same-owner commands could fail/leak (the BUG-002 mode was never documented); HARNESSES
help = README:329 = configuration.md:28 all agree on **replace** semantics (no straggler);
env table matches `pool_config_init` on all 13 rows (AGENT_CHROME_PROFILE gap is
pre-existing and symmetric in README — out of changeset scope); skill README.md has no
invalidated claims.

**Deliverable**: `SKILL.md` and `references/configuration.md` modified per the verbatim hunks
below; research already recorded at `…/P1M3T2S2/research/skill-docs-sweep.md` (sweep matrix +
code evidence). No other file changes.

**Success Definition**:
- `git diff` touches exactly 2 files (the two skill files); README.md, lib/, test/, plan/**
  (beyond this task's dir) untouched.
- Every new claim greps to exactly one occurrence per file and is backed by landed code
  (verification commands in the Validation Loop).
- The three HARNESSES surfaces still agree (help = README = configuration.md:28).
- No contradiction with README's landed admin sentences (reap "corrupt/unparseable … also
  removed"; release "(release all does not clear corrupt leases; use release N or reap.)";
  doctor "creates it — so the btrfs check is exact on fresh installs").
- Markdown hygiene: table rows stay single-line, fences balanced, no trailing whitespace.

## User Persona

**Target User**: AI agents loading the `agent-browser-pool` skill (SKILL.md) and their
operators/readers consulting `references/configuration.md`; future auditors diffing docs vs
code at changeset close.

**Use Case**: An agent that fires two driving commands in parallel (or whose lane crashed
mid-boot) reads the skill and learns the true current behavior: same-lane commands serialize,
a crashed lane re-copies a clean trusted profile, and corrupt leases are reclaimable by the
operator via `reap` / `release <N>` — no permanently burned lanes.

**Pain Points Addressed**: The skill's troubleshooting rows predate BUG-003's fix (they say
"the reaper will reclaim it" without the corrupt-lease precision, and the doctor WARN row
omits corrupt-lease cleanup); nothing documents the new serialization/crash-recovery
guarantees; the doctor line omits the fresh-install behavior README now documents.

## Why

- **The skill is the agent-facing API contract** — agents that load it trust it over the
  README. If it understates the reclamation/serialization guarantees, agents escalate
  (or, worse, run forbidden manual cleanup) for states the pool now handles.
- **Docs must match shipped behavior at changeset close** (Mode-B doc policy: this task IS the
  changeset-level skill-doc sweep — the final item of the changeset).
- **Minimal edits keep review trivial**: five anchored hunks + recorded no-ops, each tied to a
  landed commit and README wording.

## What

User-visible behavior: the skill renders as before with the additions below. Exact edits
(anchor by grep — line numbers are as-of-research and may drift):

### E1 — configuration.md: new paragraph closing "How acquire works (the lifecycle)"

**Anchor**: the paragraph ending "…the same staleness/reuse guarantees apply." (after the
lifecycle diagram, ~line 169-175), immediately before `## Release lifecycle (teardown)`.
Insert, separated by blank lines:

```markdown
**Boot serialization & crash recovery.** A lane's boot and any later reconnect/relaunch are
serialized by a short-lived per-lane boot lock (`lanes/<N>.boot.lock`) — a second command
from the same owner waits (up to ~20s) rather than racing a second Chrome onto the lane.
When a crashed lane is re-booted (its lease still says port 0 — the boot never finished),
`pool_copy_master` first wipes any stale partial dir left at `active/<N>` and re-copies
fresh from the master, so the lane always boots trusted master contents — never a
half-copied leftover.
```

(Condensed mirror of S1's README "Boot serialization & crash recovery." paragraph — keep the
function/lock names so the docs grep-agree.)

### E2 — configuration.md troubleshooting row "`status` shows my lane as `STALE` / field `?`" (~:204)

Replace the row's **Fix cell only**:

```markdown
The reaper will reclaim it; the operator can run `reap` (which also removes a corrupt `lanes/<N>.json` once its lane dir is gone) or `release <N>` (which clears a corrupt lease — and any Chrome still on its profile dir — even while the dir is still present; `release all` skips corrupt leases)
```

Symptom/cause cells unchanged. Do not introduce a literal `|` inside the cell.

### E3 — configuration.md troubleshooting row "`doctor` reports WARN lines" (~:205)

Replace the Fix cell's opening clause:

```diff
- Operator-only: `agent-browser-pool reap` clears stale lanes **and** orphan dirs; `release <N>` / `release all` for explicit teardown
+ Operator-only: `agent-browser-pool reap` clears stale lanes, orphan dirs, **and** corrupt leases; `release <N>` / `release all` for explicit teardown
```

### E4 — configuration.md Admin CLI `doctor` line (~:223)

```diff
- agent-browser-pool doctor          # diagnose the pool (exits 1 on a blocking FAIL only; WARNs are advisory)
+ agent-browser-pool doctor          # diagnose the pool (exits 1 on a blocking FAIL only; WARNs are advisory; creates the ephemeral root if missing, so the btrfs check is exact on fresh installs)
```

### E5 — SKILL.md §1: one sentence at the end of the acquire intro

**Anchor**: the paragraph "After that, **every** driving call in your session routes to that
same lane/browser/profile. You do not reconnect between calls." (~:41-42), before
`### Connection rules`. Append after it, as its own short paragraph:

```markdown
Concurrent commands from your session are safe: lane boots and reconnects are serialized
per lane, so parallel calls wait for each other rather than racing two browsers onto one
lane — and a lane that crashed mid-boot re-copies a clean profile from the master on the
next attempt.
```

(Agent voice, no internals — the paths/lock detail lives in configuration.md E1. This is the
layering: SKILL.md = guarantee, configuration.md = mechanism.)

### Verified no-ops (run the check; make NO edit)

- **(a) concurrency-invalidations**: `grep -rn 'concurren\|race\|two command\|same time' .agents/skills/agent-browser-pool/`
  → no skill text ever claimed same-owner concurrent commands can fail during boot or leak
  Chrome → nothing to fix; E1/E5 add the new guarantee instead.
- **(b2) boot-failure rows still accurate**: configuration.md:200 + SKILL.md:153-158
  ("fails to boot … will **not** self-heal") — true for genuine boot failures; the one now-
  self-healing case (crashed-boot stale dir) is documented by E1. No edit.
- **HARNESSES three-way agreement**: help (lib/pool.sh:5250-5251 "replaces the default
  pi,claude,codex,agy,antigravity; empty/unset -> default") = README:329 =
  configuration.md:28 ("Empty/unset → default (never empty)"). All agree — no straggler.
- **(d) env table vs `pool_config_init`**: all 13 rows match code defaults (STATE, MASTER
  `~/.config/google-chrome`, EPHEMERAL_ROOT, REAL, CHROME_BIN, PORT_BASE 53420, PORT_RANGE
  1000, WAIT 600, HEADLESS, ALLOW_SLOW_COPY, HARNESSES, ABPOOL_OWNER, ABPOOL_LANE). No env
  changed in this changeset → no edit. **Recorded gap (out of scope)**: `AGENT_CHROME_PROFILE`
  (`POOL_PROFILE_DIR`, pool_config_init:109/:204; help:5252) is missing from configuration.md's
  table **and equally missing from README's** — a pre-existing symmetric omission, not a
  changeset delta; do not fix here (would desync the two docs).
- **skill README.md**: all "What it covers" bullets remain true → byte-identical, no edit.

### Success Criteria

- [ ] `grep -c 'Boot serialization & crash recovery' …/references/configuration.md` == 1
- [ ] `grep -c 'corrupt leases' …/references/configuration.md` == 1 (E3) and the E2 cell
      phrases (`once its lane dir is gone`, `release all` skips corrupt) appear exactly once.
- [ ] `grep -c 'exact on fresh installs' …/references/configuration.md` == 1 (E4).
- [ ] `grep -c 'Concurrent commands from your session are safe' …/SKILL.md` == 1 (E5).
- [ ] `git status --porcelain` shows only ` M` on SKILL.md + references/configuration.md
      (+ untracked plan/…/P1M3T2S2/); `.agents/…/README.md` and root `README.md` untouched.
- [ ] Three-way HARNESSES greps still agree; no `|` characters added inside table cells;
      fence count even in both edited files; `git diff --check` clean.

## All Needed Context

### Context Completeness Check

**Zero prior knowledge → implementable?** Yes: both target files are small; every edit is
verbatim with grep anchors; every factual claim carries a code/README evidence grep; the
no-ops are pre-decided with their verification commands; the scope fence is explicit.

### Documentation & References

```yaml
- file: .agents/skills/agent-browser-pool/SKILL.md   # EDIT (E5 only)
  why: the procedural guide; §1 ends with the reuse paragraph where E5 lands.
  pattern: plain agent voice, bold lead-ins, short paragraphs — match it.
  gotcha: one sentence-pair max; no lock paths/function names here (that's configuration.md).

- file: .agents/skills/agent-browser-pool/references/configuration.md   # EDIT (E1-E4)
  why: the reference doc — lifecycle (:153-175), troubleshooting matrix (:193-207), Admin CLI
        (:210-225). All four edits land at greppable anchors given above.
  pattern: bold lead-in paragraphs ("**Boot serialization & crash recovery.**" mirrors
        "**Parent-pid semantics.**" etc.); single-line table rows.
  gotcha: never let a literal pipe into a table cell; keep rows on one line.

- file: .agents/skills/agent-browser-pool/README.md   # verified NO-OP
  why: meta/index doc — confirm untouched; its bullets make no invalidated claims.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T2S2/research/skill-docs-sweep.md
  why: THIS task's research — sweep matrix per contract item (a)-(d), code evidence lines,
        edit plan, scope fence. Read before editing.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M3T2S1/PRP.md   # parallel — CONTRACT
  why: S1's Edit 1 paragraph is E1's wording source ("Boot serialization & crash recovery.");
        its Edit 2 sentences are E2's wording source. If S1 has landed, diff-check phrasing
        against the live README; if not, use the verbatim text from S1's PRP (quoted here).
  gotcha: do NOT edit README.md yourself — S1 owns it.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: §1 repo shape (the 3 skill files are the only doc surfaces besides README; docs/ is
        empty); §2 locking model (boot-lock design) backing E1/E5 claims.

- file: README.md   # READ-ONLY wording source
  why: landed Mode-A admin sentences — reap § "corrupt/unparseable `lanes/<N>.json` … also
        removed, freeing the lane number"; release § "(release all does not clear corrupt
        leases; use release N or reap.)"; doctor § "creates it — so the btrfs check is exact
        on fresh installs". E2/E3/E4 must not contradict these.
  gotcha: README is mid-edit by S1 — re-anchor by grep, expect small line drift.

- file: lib/pool.sh   # READ-ONLY evidence (never edit)
  why: :267-296 pool_lane_boot_lock (`<N>.boot.lock`); :2703/:2957 `flock -w 20` fd 8;
        :1352/:1364 guarded wipe in pool_copy_master; pool_reap_orphan_dirs corrupt branch
        ("removed corrupt lease … (BUG-003)"); _pool_release_lane_internals corrupt +
        cmdline-sweep branches; :5250-5251 help HARNESSES replace semantics; :213 default.
```

### Current Codebase tree (relevant subset)

```bash
agent-browser-pool/                      # HEAD 5f2a702; BUG-001..006 landed
├── README.md                            # S1's, parallel — DO NOT TOUCH
├── lib/pool.sh · bin/ · test/ · install.sh   # read-only evidence
├── .agents/skills/agent-browser-pool/
│   ├── SKILL.md                         # ← EDIT E5
│   ├── README.md                        # ← verified no-op (untouched)
│   └── references/configuration.md      # ← EDIT E1-E4
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/system_context.md   # §1/§2 evidence
    └── P1M3T2S2/{PRP.md, research/skill-docs-sweep.md}   # THIS task
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (scope fence): edit ONLY the two skill files. Off-limits: README.md (S1, parallel),
#   lib/, bin/, test/, install.sh, PRD.md, plan/** (own research/ dir excepted), .agents
#   skills README.md (verified no-op).

# CRITICAL (docs-only): no live runs of anything (AGENTS.md §1) — verify every claim by
#   grep/read only. Zero processes, zero temp files.

# GOTCHA (anchor drift): line numbers cited are as-of-research (configuration.md :204/:205/
#   :223 etc.); ALWAYS re-anchor by the grep phrases given per edit.

# GOTCHA (markdown tables): troubleshooting rows are single-line; adding a literal `|`
#   inside a cell breaks the row. Long cells are fine (existing rows are already long).

# GOTCHA (doc layering): SKILL.md states the guarantee in agent voice (no `boot.lock`
#   paths/function names); configuration.md carries the mechanism. Do not cross-wire.

# GOTCHA (no restructure): no new sections, no reordering, no rewrapping untouched text.
#   Five hunks + nothing else; `git diff` must read as surgical.
```

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 0: RE-ANCHOR + consume inputs
  - RUN: grep -n '## Release lifecycle\|the same staleness/reuse guarantees apply\|STALE.*field\|doctor.*reports WARN\|agent-browser-pool doctor' .agents/skills/agent-browser-pool/references/configuration.md
  - RUN: grep -n 'You do not reconnect between calls' .agents/skills/agent-browser-pool/SKILL.md
  - RUN: grep -n 'replaces the default\|AGENT_BROWSER_POOL_HARNESSES' README.md .agents/skills/agent-browser-pool/references/configuration.md   # wording check
  - EXPECT: all anchors found (note current line numbers; use grep, not stale numbers).

Task 1: E1 — lifecycle paragraph (verbatim in "What › E1")
  - INSERT before '## Release lifecycle (teardown)', after the PID+starttime paragraph.
  - VERIFY: grep -c 'Boot serialization & crash recovery' == 1.

Task 2: E2 — STALE row Fix cell (verbatim in "What › E2")
  - REPLACE the Fix cell only; keep the row on one line; no stray pipes.
  - VERIFY: grep -c 'once its lane dir is gone' == 1.

Task 3: E3 — doctor WARN row (diff in "What › E3").  VERIFY: grep -c 'corrupt leases' == 1.

Task 4: E4 — Admin CLI doctor line (diff in "What › E4").
  - VERIFY: grep -c 'exact on fresh installs' == 1.

Task 5: E5 — SKILL.md sentence (verbatim in "What › E5")
  - INSERT after the 'You do not reconnect between calls.' paragraph.
  - VERIFY: grep -c 'Concurrent commands from your session are safe' == 1.

Task 6: NO-OP CHECKS (run; record in commit message or research addendum; edit nothing)
  - grep -rn 'concurren\|race\|two command\|same time' .agents/skills/… → expect no invalidated claim.
  - Three-way HARNESSES: grep the help line (lib/pool.sh), README row, configuration.md:28 → all "replace"/"never empty".
  - Env table: confirm the 13 rows; note the AGENT_CHROME_PROFILE pre-existing symmetric gap (no edit).
  - skill README.md: git diff shows no change to it.

Task 7: FINAL REVIEW
  - git diff --stat → exactly 2 files; git diff --check → clean; fences balanced; rows single-line.
  - Cross-check E2/E3/E4 phrasing against README's landed reap/release/doctor sentences — no contradiction.
```

### Integration Points

```yaml
INPUTS (all landed): changeset commits through 5f2a702 (code facts); README Mode-A admin
  sentences (M2 commits); S1's README paragraph (parallel — quoted verbatim here for E1).
OUTPUTS: skill docs agree with README and code → changeset 001 close-out. Terminal work
  item (Mode-B doc policy satisfied).
OFF-LIMITS: README.md, lib/**, bin/**, test/**, install.sh, PRD.md, plan/** (research/ excepted).
```

## Validation Loop

### Level 1 — Diff shape & hygiene

```bash
git diff --stat                                     # exactly 2 skill files
git diff --check                                    # no whitespace errors
for f in .agents/skills/agent-browser-pool/SKILL.md .agents/skills/agent-browser-pool/references/configuration.md; do
  [[ $(grep -c '^```' "$f") % 2 -eq 0 ]] && echo "$f fences OK"
done
```

### Level 2 — Content assertions

```bash
cd .agents/skills/agent-browser-pool
grep -c 'Boot serialization & crash recovery' references/configuration.md        # 1
grep -c 'once its lane dir is gone' references/configuration.md                  # 1
grep -c 'corrupt leases' references/configuration.md                             # 1
grep -c 'exact on fresh installs' references/configuration.md                    # 1
grep -c 'Concurrent commands from your session are safe' SKILL.md                # 1
grep -c 'lanes/<N>.boot.lock' references/configuration.md                        # 1
awk -F'|' '/STALE.*field/ || /reports WARN/ {print NF}' references/configuration.md   # same NF as neighboring rows (cell count preserved)
```

### Level 3 — Factual cross-checks vs code/README (read-only)

```bash
grep -n 'boot.lock' ../../lib/pool.sh | head -2                                  # pool_lane_boot_lock exists
grep -n 'flock -w 20' ../../lib/pool.sh | head -2                                # ~20s wait claim
grep -n 'replaces the default pi,claude,codex,agy,antigravity' ../../lib/pool.sh # help = replace
grep -n 'AGENT_BROWSER_POOL_HARNESSES' ../../README.md references/configuration.md   # both rows "never empty" — agree
grep -n 'release all. does not clear corrupt' ../../README.md                    # E2 consistent with README
grep -n 'removed corrupt lease' ../../lib/pool.sh                                # BUG-003 evidence
```

### Level 4 — Scope & consistency

```bash
git status --porcelain    # only the 2 skill files modified (+ untracked plan/…/P1M3T2S2/)
git diff .agents/skills/agent-browser-pool/README.md   # empty (no-op honored)
# No suites run, no Chrome booted, zero processes/temp left (AGENTS.md §1/§6).
```

## Final Validation Checklist

- [ ] Exactly 2 files modified (SKILL.md, references/configuration.md); READMEs untouched.
- [ ] E1-E5 content assertions pass (Level 2); diff --check clean; fences balanced.
- [ ] Factual cross-checks pass (Level 3); no contradiction with README admin sentences.
- [ ] No-ops recorded: (a) sweep found nothing invalidated; HARNESSES three-way agree;
      env table 13/13 rows match (AGENT_CHROME_PROFILE gap noted, not fixed); skill README
      untouched.
- [ ] Doc layering preserved (SKILL.md guarantee-voice / configuration.md mechanism).
- [ ] Zero live runs; zero processes/temp files left behind.

## Anti-Patterns to Avoid

- ❌ Don't restructure, re-wrap, or "improve" the skill — five surgical hunks only.
- ❌ Don't edit README.md (S1 owns it), lib/, test/, PRD.md, or plan-owned files.
- ❌ Don't add the AGENT_CHROME_PROFILE env row here — pre-existing symmetric gap, out of
  changeset scope; fixing one doc would desync the pair.
- ❌ Don't put lock paths/function names into SKILL.md, or strip them from configuration.md.
- ❌ Don't introduce pipes or line breaks inside table cells.
- ❌ Don't document the OLD bug behavior ("used to leak/fail") — state current guarantees only.
- ❌ Don't run anything to "verify" — grep the code; the gate owns runtime verification.
- ❌ Don't trust cited line numbers — re-anchor by grep (S1 is editing README concurrently;
  skill-file numbers may drift from parallel review fixes).

---

**Confidence Score: 9/10** — both target files are small and fully read; every edit is
verbatim with grep anchors and landed-code evidence; the no-ops are pre-decided; the only
residual risk is anchor drift, absorbed by Task 0's re-anchor step.