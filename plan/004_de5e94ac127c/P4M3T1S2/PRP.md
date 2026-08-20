---
name: "P4.M3.T1.S2 — Final audit: citation sweep verification, die-text mirrors, cross-doc consistency, leak check"
description: Mode B closing audit of the complete P4 changeset. Static, read-only except for the recorded audit report. Produces documentation-complete / citation-complete / leak-free proof.
---

## Goal

**Feature Goal**: Close the P4 changeset with a recorded audit proving (a) the R1
citation renumber sweep is intact and correct after all subsequent code/doc landings,
(b) every `pool_die`/diagnostic text quoted in the docs mirrors the implemented strings,
(c) env-var defaults and mode vocabulary are consistent across all four doc surfaces,
(d) static gates are clean and `install.sh` is untouched, and (e) zero orphan processes
or leftover temp trees remain from the changeset's validation runs.

**Deliverable**: A recorded audit at
`plan/004_de5e94ac127c/P4M3T1S2/research/final_audit.md` (plus, optionally, referenced
log excerpts) — the closing artifact of the Mode B changeset. **No production file is
modified.**

**Success Definition**: Every audit gate below passes and is recorded with the actual
command output; any failure is fixed by routing back (or, if doc-only, minimally
corrected and re-audited) — the changeset cannot be called complete with a red gate.

## Why

- PRD R6 (Mode B) requires the changeset to end documentation- and citation-complete.
  Code landed *after* the R1 sweep (P4.M1.T2–T4, P4.M2) added new § citations — the
  audit must show those are exactly the deliberate, recorded additions, not sweep
  regressions, and that no pre-R1 citation token survived anywhere.
- AGENTS.md §6 demands zero orphans / zero leftover `/tmp/abpool-*` trees before the
  work can be called done. This subtask is where that checklist is formally executed.

## What

Read-only audit (static analysis + bounded, isolated checks only), producing a report.

### Success Criteria

- [ ] **Citation re-audit passes**: for each of the 8 swept files,
      `grep -oE '§2\.1[3-9]|§2\.20' | wc -l` equals the R1 post-sweep baseline
      (pool 56, bin 1, install 2, validate 6, concurrency 4, release_reaper 12,
      transparency 10, README 5) **plus only** the citations each implementing
      subtask deliberately added and recorded (each subtask's PRP/research recorded
      them — e.g. pool.sh's caller-mode comments incl. 6×§2.12, validate.sh +3,
      concurrency.sh +1, README's S1 additions). Distribution across values matches
      baseline distribution (2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3
      2.19=16 2.20=11) plus recorded additions.
- [ ] **New §2.12 citations are legitimate**: every `§2.12` occurrence in
      lib/pool.sh, test/*, and README.md is read in context and points at
      caller-scoped-lane content (PRD §2.12 = "Caller-scoped lane selection") —
      never the old pre-R1 meaning (§2.12-was-command-list). Zero old-meaning
      survivors anywhere (`grep -rnE '§2\.1[2-9]'` reviewed line by line for §2.12;
      all others count via the totals gate).
- [ ] **Untouched sets byte-identical**: `§2.10` still exactly 10, `§2.11` still
      exactly 3 across the swept set; `§2.9`/`§2.8`/`§2.7` counts unchanged vs
      citation_audit §1.
- [ ] **PRD.md never swept**: `git status --porcelain PRD.md` clean / no
      changeset commit touches it.
- [ ] **Die-text mirrors**: every `pool_die`/diagnostic string the docs quote
      matches `lib/pool.sh` byte-for-byte (modulo variable substitution), checked by
      grepping BOTH sides. Known set: the four caller/pin die texts at lib/pool.sh
      L230, L590, L2318, L3797 (verbatim text in research notes §3) plus any
      exhaustion/doctor strings quoted in README/configuration.md/SKILL.md/skill
      README.md.
- [ ] **Cross-doc consistency**: same env-var names and defaults
      (`ABPOOL_OWNER` unset→harness-ancestor; `ABPOOL_LANE` unset→auto-assign /
      positive-int pin; `AGENT_BROWSER_POOL_WAIT`=600; `AGENT_CHROME_PORT_BASE`=53420,
      `_RANGE`=1000; harnesses default list) and the same mode vocabulary
      ("caller mode"/"orchestrator mode", "pinned lane", "never a takeover",
      "live parent", "auto-reaped on exit") across README.md,
      `.agents/skills/agent-browser-pool/references/configuration.md`,
      `.agents/skills/agent-browser-pool/SKILL.md`, and
      `.agents/skills/agent-browser-pool/README.md`.
- [ ] **Static gates clean**: `bash -n` + `shellcheck -s bash` zero-exit on
      `lib/pool.sh`, `install.sh`, `test/*.sh` (and `bin/agent-browser-pool` for
      bash -n); `install.sh` has `git status --porcelain install.sh` empty (PRD: no
      change).
- [ ] **Leak audit (AGENTS.md §6)**: `pgrep -af` for chrome / `abpool-` / agent
      processes spawned by any changeset validation run finds ZERO leftovers the
      changeset owns (exclude the operator's real Chrome / unrelated processes);
      `ls /tmp/abpool-* 2>/dev/null` empty; no orphan temp roots.
- [ ] **Report written** to `plan/004_de5e94ac127c/P4M3T1S2/research/final_audit.md`
      with per-gate commands + actual output + PASS/FAIL verdict.

## All Needed Context

### Context Completeness Check

An implementer with no prior knowledge gets: the exact baselines, grep recipes, die
texts, file lists, and the reconciliation rule (baseline + recorded additions) below.
No live execution beyond static/bounded commands is needed.

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/architecture/citation_audit.md
  why: §1 authoritative baseline (96 occ/92 lines; per-file 56/1/2/6/4/12/10/5;
        distribution 2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11;
        untouched §2.10=10 §2.11=3); §8 copy-pasteable verification commands; §3 token-form
        catalog (§2.17b attached-letter gotcha; slash chains; no ranges/entities exist).
  pattern: run §8's command set, but reconcile totals against baseline + recorded additions.
  gotcha: §2.20 is NOT matched by §2\.1[2-9] — always grep '§2\.1[3-9]|§2\.20'.

- file: plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md
  why: the recorded R1 execution — post-sweep per-file table (56/1/2/6/4/12/10/5 occ,
        lines 55/1/2/6/4/10/10/4), numstat proof (92+/92−), §2.17b location. This is the
        "recorded audit from P4.M1.T1.S1" the contract references as INPUT.
  pattern: the delta between this table and today's counts = exactly the deliberate additions.

- file: plan/004_de5e94ac127c/P4M3T1S1/PRP.md
  why: CONTRACT for the README changes implemented in parallel — defines exactly which
        citations/sections/die-text quotes README gains (env rows after HARNESSES,
        orchestrator section, lifecycle step-3 line, pinned-conflict block, checklist line;
        cites §2.12/§2.16). The README side of "recorded additions" comes from here.
  pattern: treat as spec; README's actual state must satisfy its Success Criteria before
        the audit can pass the cross-doc gates.

- file: lib/pool.sh
  why: implemented semantics + verbatim die texts: L230 (positive-integer), L590 (live
        parent), L2318 (live foreign owner / never a takeover), L3797 (pinned lane
        unavailable). Caller-mode code carries the new §2.12 citations (6 tokens at audit
        time; may grow — verify each in context).
  pattern: grep both doc side and code side for each quoted fragment.
  gotcha: line numbers drift; locate die texts by content grep, not line number.

- file: plan/004_de5e94ac127c/P4M3T1S2/research/research-notes.md
  why: this item's own research — mid-changeset observed counts, verbatim die strings,
        cross-doc surface list, grep set, leak-check recipe.

- file: AGENTS.md
  why: §6 checklist this audit executes (zero orphans, zero /tmp trees); §1 research-mode
        rules (static only; timeout-bounded micro-checks; never boot real Chrome here).
  section: "6. Quick checklist" and "1. MANDATORY"
```

### Current Codebase tree (audit-relevant)

```bash
lib/pool.sh  bin/agent-browser-pool  install.sh
test/{validate,concurrency,release_reaper,transparency}.sh
README.md
.agents/skills/agent-browser-pool/{SKILL.md,README.md,references/configuration.md}
PRD.md                              # read-only, human-owned, already renumbered — NEVER swept
plan/004_de5e94ac127c/…             # research + prior audits (inputs)
```

### Desired Codebase tree

```bash
plan/004_de5e94ac127c/P4M3T1S2/research/final_audit.md   # NEW — the only file written
# (no production file changes; a doc-side miss may be minimally fixed and re-audited,
#  recording the fix in the report)
```

### Known Gotchas

```text
# Reconcile, don't hardcode: post-R1 code additions shifted totals (pool.sh was 63 occ incl.
# 6×§2.12 at research time; validate 9; concurrency 5). Expected = sweep_audit baseline +
# additions recorded in each implementing subtask's PRP/research — enumerate them in the report.
# §2.12 dual meaning: NEW §2.12 = caller-scoped lanes (legit in code); OLD §2.12 = command list
#   (must be gone). Verify each §2.12 occurrence in context; only the new meaning may appear.
# §2.20 needs explicit alternation — '§2\.1[3-9]|§2\.20' — [2-9] misses the 0.
# Attached-letter §2.17b (pool.sh ~L3636) must still exist exactly once.
# pgrep exits 1 when nothing matches (fine) — guard with `|| true` / capture, never let a
#   bare pgrep abort a script. Never use kill -0 for liveness (AGENTS.md §4).
# The operator's real Chrome/profiles may be running — do NOT count or touch them; the leak
#   audit only owns processes/trees the changeset's validation runs spawned.
# PRD.md is human-owned and already correct — any § discrepancy there is NOT yours to fix.
```

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: RECONCILE expected citation totals
  - READ: citation_audit.md §1 (baseline), P4M1T1S1/research/sweep_audit.md (post-sweep
    per-file table), and each implementing subtask's PRP/research for its recorded
    citation additions (P4.M1.T2.S1/T3.S1/T4.S1 code comments; P4.M2 test additions;
    P4.M3.T1.S1 README additions).
  - PRODUCE: a per-file expected table = baseline + additions, with provenance notes.

Task 2: RUN the citation re-audit (static grep only)
  - RUN citation_audit.md §8 (a)–(c) adapted: per-value distribution, per-file totals vs
    the Task-1 table, untouched §2.10=10/§2.11=3 (plus §2.9/§2.8/§2.7 spot checks).
  - VERIFY every §2.12 occurrence in lib/pool.sh, test/*, README.md in context points at
    caller-scoped content; `grep -rnE '§2\.1[2-9]'` — no old-meaning token anywhere.
  - CONFIRM PRD.md untouched: git status/diff shows no changeset change to PRD.md.

Task 3: DIE-TEXT MIRROR CHECK
  - GREP both sides for each quoted fragment (the four caller/pin die texts, verbatim in
    research-notes §3, plus any other diagnostic strings the docs quote: grep docs for
    `agent-browser-pool:` and characteristic phrases like "never a takeover", "must be a
    positive integer", "requires a live parent", "held by a live owner").
  - FILES: README.md, references/configuration.md, SKILL.md, skill README.md vs lib/pool.sh.
  - PASS: byte-for-byte match modulo `$var` substitution; every doc quote has a code
    counterpart; no doc quotes a string that no longer exists.

Task 4: CROSS-DOC CONSISTENCY CHECK
  - GREP each env var (ABPOOL_OWNER, ABPOOL_LANE, AGENT_BROWSER_POOL_WAIT,
    AGENT_CHROME_PORT_BASE/RANGE, AGENT_BROWSER_POOL_HARNESSES, AGENT_BROWSER_REAL,
    AGENT_CHROME_MASTER/EPHEMERAL_ROOT/BIN/HEADLESS/ALLOW_SLOW_COPY,
    AGENT_BROWSER_POOL_STATE) across the four doc surfaces; assert same default values
    and same mode vocabulary ("caller mode"/"orchestrator mode", "pinned lane",
    "never a takeover", "live parent", "auto-reap").
  - VERIFY P4.M3.T1.S1's PRP Success Criteria are actually met in README.md (it is the
    parallel contract — its presence is a precondition for this audit passing).

Task 5: STATIC GATES + INSTALL.SH INVARIANCE
  - bash -n lib/pool.sh bin/agent-browser-pool install.sh test/*.sh
  - shellcheck -s bash lib/pool.sh install.sh test/*.sh   (zero warnings; note pool.sh
    relies on the in-file SC2034 disable — it must remain zero)
  - git status --porcelain install.sh → empty (PRD: install.sh unchanged).

Task 6: LEAK AUDIT (AGENTS.md §6) — bounded, read-only
  - pgrep -af 'chrome|abpool-|agent-browser-pool' (guard rc; `|| true`) and
    `ls /tmp/abpool-* 2>/dev/null` — assert zero changeset-owned leftovers; explicitly
    exclude operator processes. If leftovers are found, escalate per AGENTS.md §3
    (kill process groups, reap), record the remediation.
  - NEVER launch Chrome/tests to "check" anything — read-only pgrep/ls only.

Task 7: WRITE plan/004_de5e94ac127c/P4M3T1S2/research/final_audit.md
  - STRUCTURE: inputs (sweep_audit + subtask records) → reconciliation table → per-gate
    command + output + verdict (citation / §2.12-legitimacy / untouched / die-mirror /
    cross-doc / static / install.sh / leak) → conclusion line:
    "documentation-complete, citation-complete, leak-free".
  - ANY FAIL: record it, apply the minimal doc-side fix (if doc-only and safe), re-run
    the failed gate, record both runs. Code-side failures → report, do not fix (out of
    scope for the audit).
```

### Implementation Patterns & Key Details

```bash
# Core grep set (from citation_audit §8, adjusted):
FILES="lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh test/concurrency.sh test/release_reaper.sh test/transparency.sh README.md"
for f in $FILES; do printf '%s occ=%s lines=%s\n' "$f" \
  "$(grep -oE '§2\.1[3-9]|§2\.20' "$f" | wc -l)" "$(grep -cE '§2\.1[3-9]|§2\.20' "$f")"; done
# §2.12 legitimacy sweep (context review, not just count):
grep -rnE '§2\.12' lib bin install.sh test README.md .agents/skills/agent-browser-pool || true
# Die-text mirror (both sides):
grep -n "never a takeover" lib/pool.sh README.md .agents/skills/agent-browser-pool/references/configuration.md .agents/skills/agent-browser-pool/SKILL.md .agents/skills/agent-browser-pool/README.md || true
# Leak audit (read-only, rc-guarded):
pgrep -af 'chrome|abpool-' || true; ls /tmp/abpool-* 2>/dev/null || true
```

### Integration Points

```yaml
INPUTS:
  - plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md   (recorded R1 audit)
  - per-subtask PRP/research records of deliberate citation additions
  - complete P4 changeset (all deps Complete except P4.M3.T1.S1 — its PRP is the contract)
OUTPUT:
  - plan/004_de5e94ac127c/P4M3T1S2/research/final_audit.md   (closes the changeset)
NO CHANGES TO: PRD.md, tasks.json, prd_snapshot.md, .gitignore, lib/, bin/, test/, install.sh
```

## Validation Loop

### Level 1: Static (the audit IS static)

```bash
bash -n lib/pool.sh bin/agent-browser-pool install.sh test/*.sh
shellcheck -s bash lib/pool.sh install.sh test/*.sh
git status --porcelain install.sh    # empty
```

### Level 2: Self-consistency of the audit

```bash
# The report's reconciliation table must sum: baseline + additions == measured, per file.
# Every §2.12 occurrence listed with file:line and its context quoted.
# Every gate has command + observed output + PASS/FAIL.
```

### Level 3: Handoff verification

```bash
# The conclusion line "documentation-complete, citation-complete, leak-free" is only
# written when ALL gates are green. If any gate is red and unfixable doc-side, the report
# ends with the failure and the changeset is NOT declared complete.
```

### Level 4: Creative validation — none required

Read-only audit; no browsers, no servers.

## Final Validation Checklist

- [ ] `final_audit.md` exists with all gates recorded (citation totals, §2.12 context
      review, untouched sets, die mirrors, cross-doc env/vocab, static, install.sh
      invariance, leak audit)
- [ ] Reconciliation table provenance: every deviation from the 56/1/2/6/4/12/10/5
      baseline traced to a named subtask's recorded addition
- [ ] PRD.md confirmed untouched by the changeset
- [ ] Zero old-meaning citation tokens repo-wide; §2.17b intact
- [ ] Doc quotes mirror lib/pool.sh byte-for-byte (both sides grepped)
- [ ] bash -n + shellcheck clean; install.sh diff-clean
- [ ] AGENTS.md §6: zero changeset-owned orphan processes; zero /tmp/abpool-* trees
- [ ] No production file modified by this subtask (only research/final_audit.md written)

## Anti-Patterns to Avoid

- ❌ Don't hardcode expected totals from the pre-R1 world (73) or assume the sweep-time
  numbers still hold — reconcile against baseline + recorded additions
- ❌ Don't run the test suite or boot Chrome "to be thorough" — this is a static audit
- ❌ Don't fix code-side failures yourself; record and escalate
- ❌ Don't count/kill the operator's real Chrome in the leak audit
- ❌ Don't forget `§2\.20` needs the explicit alternation
- ❌ Don't let a bare pgrep/kill non-zero rc abort a script — guard everything