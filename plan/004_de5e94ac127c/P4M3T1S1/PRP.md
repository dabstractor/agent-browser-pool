---
name: "P4.M3.T1.S1 — README.md: env rows + orchestrator-mode section + troubleshooting + checklist"
description: Mode B changeset-level documentation sync of root README.md for ABPOOL_OWNER / ABPOOL_LANE. Doc-only.
---

## Goal

**Feature Goal**: Make the root `README.md` fully document caller-scoped lanes
(`ABPOOL_OWNER=caller`) and lane pinning (`ABPOOL_LANE=<N>`) in exact lockstep with the
implemented semantics (lib/pool.sh) and the skill docs (configuration.md / SKILL.md), with
zero stale PRD citations and zero forked wording.

**Deliverable**: Modified `README.md` only — 5 changes:
1. Two env-table rows (`ABPOOL_OWNER`, `ABPOOL_LANE`) inserted immediately after the
   HARNESSES row (currently line 272; insert at line 273).
2. New `### Orchestrator mode (caller-scoped lanes)` subsection under `## Usage (for agents)`
   (after the skill-pointer paragraph at ~L127, before `## Commands` at L129).
3. Caller-keyed mention in the "How it works" lifecycle step 3 (~L318, the numbered list item
   "**driving command → resolve the owning harness process**").
4. New troubleshooting `###` block for the pinned live-foreign conflict, placed between the
   "Pool exhaustion" block (ends ~L369) and "### Leaks — orphan dirs…" (L371), i.e. at ~L370.
5. An orchestrator-mode line in the Usage invocation-checklist context matching PRD §2.16's
   final checklist line ("`ABPOOL_OWNER=caller` per subprocess → each subprocess gets its own
   lane and reaps it on exit").

**Success Definition**: A reader of README.md alone can (a) run parallel scraper subprocesses
with one lane each, (b) pin a lane deterministically and predict every outcome
(free/stale → take, live-mine → reuse, live-foreign → hard error, malformed → startup error),
(c) recognize the pinned-conflict error and know the fix; and `grep -n "PRD.md §" README.md`
shows only the new numbering (§2.9, §2.13, §2.15, §2.18, §2.19 today, plus §2.12/§2.16 if the
new prose cites them — never the old pre-R1 numbers like §2.12-for-command-list).

## Why

- P4.M1/M2 implemented and unit-documented the feature; the root README (the primary user doc)
  still knows nothing about it. This subtask IS the Mode B changeset-level documentation
  (P4.M3.T1.S1), feeding the final audit (P4.M3.T1.S2).
- PRD §2.12 "Docs impact" and §2.16's checklist line explicitly require README coverage of
  both modes, including the parallel-scrapers use case.

## What

Doc-only changes to `README.md` (no code, no other files). All new content must **reuse the
wording** already shipped in `.agents/skills/agent-browser-pool/references/configuration.md`
(P4.M1.T2.S2 / T3.S2 / T4.S3) — README is the summary; configuration.md is the deep dive.

### Success Criteria

- [ ] Two env rows added at the table under `## Configuration reference`, immediately after
      the `AGENT_BROWSER_POOL_HARNESSES` row; 3-col shape (`| Env var | Default | Meaning |`),
      keys and defaults in backticks.
- [ ] `### Orchestrator mode (caller-scoped lanes)` under `## Usage (for agents)` covers:
      what `ABPOOL_OWNER=caller` does (one lane per orchestrator subprocess, keyed on the
      invoking subprocess, auto-reaped on exit via the lazy reaper), the parallel-scrapers
      bash example, `ABPOOL_LANE` pin rules (free/stale→take — stale reaped, orphan Chrome NOT
      adopted; live-mine→reuse; live-foreign→hard error, never a takeover, no wait/force-reap;
      malformed→startup error), and the isolation note (both modes preserve cross-agent
      isolation; the default path with no env vars is unchanged; the recognized-harness
      fail-fast does not apply in caller mode).
- [ ] Lifecycle step 3 under "Lane lifecycle ordering (`pool_wrapper_main`)" mentions that in
      caller mode (`ABPOOL_OWNER` set) the owner key is the calling subprocess (its live
      parent), not a harness ancestor.
- [ ] New troubleshooting `###` block titled e.g. `### Pinned lane conflict — ABPOOL_LANE held by a live foreign owner`
      with **Symptom:** / **Cause:** / **Fix:** paragraphs; the Symptom quotes the implemented
      die text verbatim (see context below).
- [ ] Orchestrator-mode checklist line present in the Usage section (mirroring PRD §2.16).
- [ ] No stale citations introduced; existing § citations (L81 §2.18, L250 §2.13/§2.15,
      L286 §2.19, L369 §2.9, L384 §2.15) untouched.

## All Needed Context

### Context Completeness Check

An implementer who knows nothing about this repo can apply this PRP purely against README.md
plus the quoted die texts below; every anchor, wording source, and format rule is given here.

### Documentation & References

```yaml
- file: README.md
  why: THE file being modified. Sections: Usage (for agents) L101–127; ## Commands L129;
        ## Configuration reference env table (header L259-260, HARNESSES row ends L272);
        ## How it works lifecycle numbered list ~L312-322 (step 3 = "driving command → resolve
        the owning harness process"); ## Troubleshooting ### blocks at L342/356/371.
  pattern: Troubleshooting blocks = ### heading + bold **Symptom:**/**Cause:**/**Fix:** paragraphs
        (copy the shape of the block at L342). Env rows = 3 cols, backticked key+default.
  gotcha: Do NOT renumber or re-point existing PRD citations. Do NOT touch anything else.

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: WORDING SOURCE — sync, do not fork. Env rows at L29-30; "### Caller-scoped lanes
        (orchestrator mode)" L46-74 (incl. parallel-scrapers fence L68-71); "### Lane pinning
        (ABPOOL_LANE)" L76-105; troubleshooting matrix rows L206-208.
  pattern: Copy the parallel-scrapers example fence verbatim into the README section.
  gotcha: configuration.md keys caller ownership on the invoking subprocess's LIVE PARENT
        ($PPID), not $$ — README wording must say "the calling subprocess / the process that
        invoked agent-browser-pool", never "your own PID".

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: Secondary wording source (orchestrator note ~L58, pitfall bullet ~L161, §5 pointer
        ~L170). Keep terminology identical: "caller mode", "orchestrator mode", "pinned lane",
        "never a takeover".
- file: lib/pool.sh
  why: Verbatim die texts (see below) — L230, L2294, L2318, L590.
- file: plan/004_de5e94ac127c/architecture/docs_map.md
  why: §1 (README line map — note line numbers drift a few lines after each insertion; re-locate
        anchors by content, not raw line numbers), §7 (style conventions).
  section: "1. Root README.md" and "7. Observed wording/style conventions"
```

### Current Codebase tree (README-relevant)

```bash
README.md                            ← the ONLY file to modify (421 lines, pre-change)
.agents/skills/agent-browser-pool/SKILL.md
.agents/skills/agent-browser-pool/README.md
.agents/skills/agent-browser-pool/references/configuration.md
lib/pool.sh                          ← implemented semantics (read-only)
PRD.md                               ← read-only, cite-only
```

### Desired changes

```bash
README.md   # +2 env rows, +1 ### section under Usage, ~1 line in lifecycle step 3,
            # +1 troubleshooting ### block, +1 orchestrator checklist line
# (no other file changes)
```

### Known Gotchas

```text
# Line anchors drift: after inserting the Usage section (~L127), every later line number
# shifts by the inserted length. Locate each subsequent anchor by CONTENT (e.g. the
# HARNESSES row, the "### Leaks —" heading), not by the pre-change line numbers.
# README env-table header is "Env var" (configuration.md's is "Variable") — match README.
# Caller-mode owner = the invoking subprocess (live parent), NOT $$ — sync with configuration.md.
# Pin + stale lane: even a responsive orphan Chrome is NOT adopted — pin guarantees fresh state.
# Pin errors NEVER wait (AGENT_BROWSER_POOL_WAIT / force-reap do not apply) — say so.
# Isolation note is mandatory: cross-agent isolation holds in both modes; default path
#   (no env vars) byte-identical; live-foreign pin error preserves isolation.
```

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: EDIT README.md — env-table rows (## Configuration reference)
  - FIND: the `AGENT_BROWSER_POOL_HARNESSES` row (last table row, ~L272)
  - INSERT after it, same 3-col shape, synced with configuration.md L29-30 but with the
    README "Env var" header convention:
    | `ABPOOL_OWNER` | unset = harness-ancestor ownership | any non-empty value
      (recommended: `caller`) → key lane ownership on the calling subprocess (each parallel
      worker gets its own lane, auto-reaped when it exits); the recognized-harness fail-fast
      does not apply in caller mode. See [Orchestrator mode](#orchestrator-mode-caller-scoped-lanes) |
    | `ABPOOL_LANE` | unset = auto-assign (lowest free lane) | positive integer N → pin lane N:
      free or stale → take it (stale lease reaped first; orphan Chrome never adopted);
      live lease owned by you → reuse; live foreign lease → hard error — **never a takeover**;
      malformed value → hard error at startup |
  - NAMING/SHAPE: backticked key and default; meaning plain prose; `→` arrows; bold sparingly

Task 2: EDIT README.md — new "### Orchestrator mode (caller-scoped lanes)" under ## Usage (for agents)
  - PLACE: after the skill-pointer paragraph ("For the full procedural contract …SKILL.md"),
    immediately before "## Commands"
  - CONTENT (all synced with configuration.md §Caller-scoped lanes / §Lane pinning):
    1. What ABPOOL_OWNER=caller does: ownership keys on the calling subprocess (the process
       that invoked agent-browser-pool — must have a live parent) instead of the harness
       ancestor; each parallel subprocess transparently gets its own lane; lane reaped by
       the lazy reaper when the subprocess exits; fail-fast exemption (no harness ancestor needed).
    2. Parallel-scrapers example — copy the fence verbatim from configuration.md L68-71:
       ABPOOL_OWNER=caller .venv/bin/python scrapers/linkedin_discover.py --no-ping &
       ABPOOL_OWNER=caller .venv/bin/python scrapers/indeed_discover.py --no-ping &
       wait
    3. ABPOOL_LANE pin rules (condensed 4-outcome list: free/stale→take with fresh-state
       note; live-mine→idempotent reuse; live-foreign→hard error, never a takeover, no wait
       and no force-reap; malformed→startup error before any lane work).
    4. Isolation note: both modes preserve cross-agent isolation — a pin can only create/adopt
       a free or stale lane, never take over a live foreign one; with no env vars set the
       default path is unchanged.
  - POINTER: close with a relative link to configuration.md's two subsections for full semantics.

Task 3: EDIT README.md — lifecycle step 3 (## How it works → "Lane lifecycle ordering" list)
  - FIND: item 3, "**driving command → resolve the owning harness process**; if there is no
    recognized-harness ancestor, **fail fast** …"
  - APPEND one sentence: with `ABPOOL_OWNER` set (caller mode), the owner key is the calling
    subprocess (its live parent) instead of a harness ancestor — no fail-fast applies;
    with `ABPOOL_LANE=<N>` the lane is pinned rather than auto-assigned (see Configuration
    reference).

Task 4: EDIT README.md — new troubleshooting block (~L370, between "Pool exhaustion" and "Leaks")
  - HEADING: "### Pinned lane conflict — `ABPOOL_LANE` names a lane held by a live foreign owner"
  - FORMAT: bold **Symptom:** / **Cause:** / **Fix:** paragraphs (mirror the L342 block's shape)
  - SYMPTOM quotes the implemented die text VERBATIM:
    "pinned lane N is held by a live owner (pid …, comm …); a pinned lane is never a takeover —
    unset ABPOOL_LANE or choose a free lane" (wrapped in `agent-browser-pool: ABPOOL_LANE=N:
    pinned lane unavailable` by the wrapper). Optionally also name the sibling errors: the
    one-lane-per-owner conflict and the malformed-value startup error
    (`agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw>'`).
  - CAUSE: by design — a pin never takes over a live foreign lease and never waits
    (the exhaustion block/force-reap path does not apply); isolation is preserved.
  - FIX: unset ABPOOL_LANE (auto-assign), choose a free lane, or wait for that owner to
    release; if you already hold another lane, release it first or unset the pin.
  - CITE: end with `See [PRD.md §2.12](./PRD.md).` (new numbering only)

Task 5: EDIT README.md — orchestrator checklist line in ## Usage (for agents)
  - ADD one bullet/line to the Usage bullet list (or the tail of the new ### section if it
    reads better), mirroring PRD §2.16's final checklist item:
    "Orchestrator mode: `ABPOOL_OWNER=caller` per subprocess → each subprocess gets its own
    lane and reaps it on exit."
```

### Implementation Patterns & Key Details

```markdown
<!-- Env row shape (match neighboring rows exactly) -->
| `ABPOOL_OWNER` | unset = harness-ancestor ownership | any non-empty value … → … |

<!-- Troubleshooting block shape (copy from the L342 block) -->
### <Title>
**Symptom:** … quotes the die text *in italics or quotes* …
**Cause:** by design. …
**Fix:** … See [PRD.md §2.12](./PRD.md).
```

### Integration Points

```yaml
DOCS:
  - file: README.md only
  - citation format: "[PRD.md §X.YY](./PRD.md)" — §2.12 (caller/pin), §2.16 (checklist) for new prose
  - no changes to: PRD.md, SKILL.md, configuration.md, skill README.md, lib/, bin/, test/
```

## Validation Loop

### Level 1: Static (the only executable checks — this is a doc-only task)

```bash
bash -n lib/pool.sh bin/agent-browser-pool        # sanity: nothing broke (no code change expected)
git diff --stat                                   # MUST show README.md only
grep -n "ABPOOL_OWNER\|ABPOOL_LANE" README.md     # expect: 2 env rows + orchestrator section
                                                  # + lifecycle step + troubleshooting + checklist line
```

### Level 2: Consistency checks

```bash
# Every quoted die text in README matches lib/pool.sh verbatim (modulo variable substitution):
grep -n "never a takeover" README.md lib/pool.sh .agents/skills/agent-browser-pool/references/configuration.md
grep -n "must be a positive integer" README.md lib/pool.sh
grep -n "requires a live parent" README.md lib/pool.sh   # if referenced
# Citations: new numbering only — none of README's § cites may point at a pre-R1 mapping:
grep -n "PRD.md §" README.md    # expect only §2.9/§2.12/§2.13/§2.15/§2.16/§2.18/§2.19
# Markdown table integrity: the two new rows have exactly 2 pipes … 3 columns, pipe-count
# equal to the HARNESSES row; no blank line inside the table.
# Parallel-scrapers fence byte-matches configuration.md's example.
```

### Level 3: Rendered-doc review

```bash
# Render or visually inspect README (e.g. glow/mdcat/VS Code preview): the new ###
# nests correctly under ## Usage (for agents), anchors resolve, table renders, no
# duplicated headings, ## Commands still directly follows the new section's end.
```

### Level 4: Cross-doc audit handoff (feeds P4.M3.T1.S2)

```bash
# Leave a clean state for the final audit: no TODOs, no stale line-number claims in README,
# terminology identical to SKILL.md/configuration.md ("caller mode", "pinned lane",
# "never a takeover", "auto-reap on exit").
```

## Final Validation Checklist

- [ ] `git diff --stat` shows exactly one file: `README.md`
- [ ] 5 changes present: env rows (after HARNESSES), orchestrator `###` under Usage, lifecycle
      step-3 caller mention, pinned-conflict troubleshooting block, orchestrator checklist line
- [ ] All quoted error texts mirror `lib/pool.sh` verbatim
- [ ] Wording synced with (not forked from) `references/configuration.md`; parallel-scrapers
      example identical
- [ ] Caller-mode semantics say "calling subprocess / live parent", NOT `$$`
- [ ] Isolation + default-path-unchanged note present
- [ ] No stale PRD citations; new cites use `[PRD.md §X.YY](./PRD.md)` format
- [ ] Markdown structure valid (table columns, heading levels, anchors)

## Anti-Patterns to Avoid

- ❌ Don't fork wording — README summarizes configuration.md, links to it for depth
- ❌ Don't cite PRD's `$$` sketch; the implementation keys on the live parent
- ❌ Don't describe pin live-foreign as "waits then force-reaps" — it hard-errors immediately
- ❌ Don't insert rows/sections by raw line number after earlier insertions shift lines —
  locate by content
- ❌ Don't touch any file other than README.md (the citation sweep audit is P4.M3.T1.S2)
- ❌ Don't reintroduce old PRD section numbers in new prose