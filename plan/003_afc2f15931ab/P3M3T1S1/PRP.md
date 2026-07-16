# PRP — P3.M3.T1.S1: Update README.md (root): env-var row, callouts, architecture, troubleshooting, phrasing sweep

**Work item:** P3.M3.T1.S1 (2 points) — parent P3.M3.T1 (Sync changeset-level documentation),
milestone P3.M3 (Sync changeset-level documentation). PRD §2.4 step 1 (owner resolution),
§2.11 (Discovery & configuration), §2.14 (Failure modes), §2.17 (Install — for boundary only),
Decision O9 (Multi-harness owner resolution). Depends on **P3.M1.T1.S1/S2/S3 (all Complete)** —
which generalized owner resolution to a recognized-harness set, added `AGENT_BROWSER_POOL_HARNESSES`,
and changed the `pool_die` fail-fast (R3) message. Also CONSUMES the already-landed Mode A edits to
`configuration.md` (the env-var row source of truth).
**Type:** Documentation-only (Mode B changeset-level). **One file: `README.md` (root).** No code.
No tests. No config/API surface change. **Phase constraint:** PLANNING deliverable; AGENTS.md §1
static-only validation is trivially satisfied (nothing to execute — no Chrome, no suite, no daemon).

---

## Goal

**Feature Goal:** Bring the root `README.md` into sync with the shipped multi-harness owner model
(P3.M1 / Decision O9): surface the new `AGENT_BROWSER_POOL_HARNESSES` env var in the config table,
and replace every pi-specific owner/fail-fast phrasing with the recognized-harness terminology
already used in `configuration.md`, the PRD, and the R3 `pool_die` message. After this item the
README is internally consistent and matches the rest of the docs set; **no "pi ancestor" / "owning
`pi` process" / "under `pi`" prose remains** (except the single intentional test-hooks callout +
the new explicit harness enumerations).

**Deliverable:** 17 surgical text edits inside `README.md` (1 added env-var table row + 16
pi→harness phrasing substitutions across 6 regions), verbatim before→after specified below. **No
other file changes. No new sections** (the cross-harness skill-install section is sibling S2).

**Success Definition:**
1. `AGENT_BROWSER_POOL_HARNESSES` row present in the env-var table, byte-identical (Default +
   Meaning) to `configuration.md:28`.
2. Every in-scope `pi ancestor` / `owning `pi` process` / `under `pi`` / `requires a `pi`
   ancestor` phrasing generalized (see substitution table) — zero such literals remain in the
   in-scope regions.
3. The troubleshooting section heading + symptom quote mirror the actual R3 `pool_die` text
   (`lib/pool.sh:3429-3430`).
4. The **only** remaining `` `pi` `` references in README are: (a) the test-only-hooks callout
   (L262, intentionally unchanged — matches `configuration.md`), and (b) the explicit harness
   enumerations `` (`pi`/`claude`/`codex`/`agy`) `` in the new generalized phrasings.
5. Markdown structure intact (3-column table still 3 columns; headings/blockquotes/diagram
   unchanged in shape). `git diff --stat` touches **only** `README.md`.

---

## Why

- P3.M1 generalized owner resolution (PRD §2.4 step 1 / Decision O9): the pool now treats a
  **recognized harness set** (`pi,claude,codex,agy,antigravity`, configurable) as valid lane
  owners, records the actual matched `comm`, and the fail-fast message names the supported
  harnesses. The root README still describes the **old pi-only** model (env-var table is missing
  the var; usage/classification/architecture/troubleshooting prose all say "pi ancestor" /
  "owning `pi` process"). This is the headline user-facing doc — it must reflect shipped behavior.
- This is the **README half** of the changeset-level docs sync (Mode B). The per-file Mode A docs
  (`configuration.md`, `SKILL.md`, skill `README.md`) already landed with the new terminology;
  `configuration.md` is the exact source of truth for the env-var row wording. README must match.
- Docs-only: zero runtime risk. The value is correctness/consistency for human readers + the agent
  skill's cross-references; there is no code or test impact.

---

## What

### User-visible behavior
None (documentation). The README's config table, callouts, architecture diagram, lane-lifecycle
list, and troubleshooting section now describe the multi-harness model and surface the new env var.

### Technical change (confined to `README.md`)
17 edits across 6 regions + 1 table-row insert. **No structural change** — every edit is a
wording/row substitution at an existing location; no section added/removed/moved. Full verbatim
before→after table in the Implementation Blueprint.

### Success Criteria
- [ ] `AGENT_BROWSER_POOL_HARNESSES` row in env-var table, matching `configuration.md:28`.
- [ ] Usage blockquote (L101–106), Classification callout (L151), How-it-works diagram (L278),
      Lane lifecycle list (L290), Troubleshooting section (L318–330) all generalized.
- [ ] Phrasing sweep applied at L16, L86, L172, L301, L304.
- [ ] Troubleshooting heading + symptom quote mirror R3 `pool_die` text.
- [ ] Zero `pi ancestor` / `owning `pi` process` / `requires a `pi` ancestor` literals remain
      in-scope; the only `` `pi` `` leftovers are L262 + the new harness enumerations.
- [ ] Only `README.md` modified.

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact source-of-truth message text (verbatim,
with line number), the exact source-of-truth env-var row (verbatim, cross-file invariant), a full
17-row before→after substitution table with verbatim current line text, the canonical terminology
map, the explicit out-of-scope boundary (siblings S2/S3 + L262), and static-only validation
commands verified runnable here. Nothing else required._

### Documentation & References
```yaml
- file: lib/pool.sh
  why: SOURCE OF TRUTH for the R3 fail-fast message. pool_wrapper_main step d calls pool_die at
       lines 3429-3430:
         pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
                  "For raw browser use without pooling, call 'agent-browser' directly."
       pool_die (lib/pool.sh:29-32) = `printf '%s\n' "$*"` → emits ONE line (args joined by $IFS/space):
       "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy). For raw browser use without pooling, call 'agent-browser' directly."
  pattern: README troubleshooting symptom quote + heading must mirror this emitted text.
  critical: DO NOT edit lib/pool.sh (M1 scope, already Complete). This PRP only CONSUMES the text.

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: SOURCE OF TRUTH for the env-var row (cross-file sync invariant, docs_map "Cross-file sync
       constraints"). ALREADY FULLY UPDATED (Mode A landed + committed — NOT in git modified list).
       Its row at line 28 is the EXACT target wording for README's new row:
         | `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
       Its dispatch/lifecycle/release/troubleshooting-matrix sections are ALREADY generalized →
       README must mirror the same terminology.
  critical: README's new row MUST be byte-identical to this (Default + Meaning). NOTE configuration.md's
            own test-only-hooks callout STILL says "without a real `pi` ancestor" → README L262 keeps the
            IDENTICAL wording (cross-doc consistency; do NOT "fix" it here).

- file: README.md
  why: TARGET FILE (the only file edited). 395 lines. In-scope regions: bullet L16; Usage para L86;
       Usage blockquote L101-106; Classification callout L151; `reap` section L172; env-var table L248
       (insert after); How-it-works diagram L278; Lane lifecycle list L290; Release para L301+L304;
       Troubleshooting section L318-330.
  pattern: 3-column pipe-table env-var block (header `| Env var | Default | Meaning |`); markdown
           blockquotes (`>`-prefixed); an ASCII art diagram inside a ``` fence; an ordered list.
  critical: Re-derive line numbers with the Task-1 grep before editing (sibling landings shift them;
            the contract's L275 for the diagram is actually L278). Line 262 (test-only hooks callout)
            is OUT OF SCOPE — leave unchanged.

- file: plan/003_afc2f15931ab/architecture/docs_map.md
  why: File 4 (README.md root) §4a-§4c defines this item's exact edit set; "Cross-file sync
       constraints" pins the env-var row invariant.
  critical: docs_map File 4d (cross-harness skill-install section) is SIBLING S2, NOT this item.
            docs_map File 4a marks the test-only-hooks callout "reference only, not edited".

- file: plan/003_afc2f15931ab/P3M3T1S1/research/notes.md
  why: THIS item's research — verbatim current line numbers for all 17 anchors, the canonical
       terminology map, the scope-boundary enumeration, the validation baseline. READ THIS.

- file: plan/003_afc2f15931ab/P3M2T1S3/PRP.md
  why: The parallel in-flight sibling. Edits test/transparency.sh ONLY → DISJOINT FILE, zero
       conflict/dependency. Confirms the R3 message substring `supported agent harness`.
  critical: This PRP does NOT depend on S3 landing (different file). No coordination needed.

- file: AGENTS.md
  why: §1 (static-only planning validation — trivially met: docs, nothing to run); §5 (README is
       NOT in the read-only list — editable; PRD.md/tasks.json/.gitignore ARE read-only).
```

### Current codebase tree (relevant slice)
```
README.md                                                       # TARGET (the only edited file)
lib/pool.sh                                                     # R3 message source (READ ONLY; lines 29-32, 3429-3430)
.agents/skills/agent-browser-pool/references/configuration.md   # env-var row + terminology source of truth (READ ONLY; already generalized)
plan/003_afc2f15931ab/architecture/docs_map.md                  # File 4 scoping (READ ONLY)
install.sh                                                      # SIBLING S3 (not touched here)
test/transparency.sh                                            # SIBLING S3 (parallel, disjoint)
```

### Desired codebase tree (delta)
```
README.md    # MODIFIED: 1 env-var row added + 16 pi→harness phrasing edits across 6 regions.
(no new files; no deletions; no other file touched.)
```

### Known Gotchas of our codebase & Library Quirks
```markdown
<!-- CRITICAL — line numbers are APPROXIMATE; re-derive with the Task-1 grep before editing. The
     contract/docs_map say "L275" for the diagram; the ACTUAL current line is L278. Sibling landings
     (esp. the in-flight S3 on test/transparency.sh, and the future S2 README section) shift numbers.
     The before→after TEXT in the table is what matters; match on text, not line numbers. -->

<!-- CRITICAL — the env-var row is a CROSS-FILE INVARIANT. README's new row MUST equal
     configuration.md:28 byte-for-byte in Default + Meaning (docs_map "Cross-file sync constraints").
     Do NOT paraphrase the Meaning cell. Copy it verbatim from configuration.md:28. -->

<!-- CRITICAL — DO NOT touch line 262 (test-only hooks callout: "without a real `pi` ancestor").
     docs_map File 4a marks it "reference only". configuration.md's OWN test-hooks callout keeps the
     identical "without a real `pi` ancestor" wording → changing README alone would BREAK cross-doc
     consistency. Leave it. It is the one intentional residual `pi` reference. -->

<!-- CRITICAL — DO NOT add the §2.17 cross-harness skill-install section / per-harness table / Codex
     caveat here. That is sibling P3.M3.T1.S2 (docs_map File 4d — "DOES NOT EXIST YET, delta ADDS it",
     a NEW section after the Installation block ~L81). This item is edits (a)-(g) ONLY. Adding it is
     scope theft from S2. -->

<!-- CRITICAL — DO NOT add AGENT_BROWSER_POOL_HARNESSES to the README "Three vars shape behavior most"
     prose (~L250-258). configuration.md doesn't list it in its "three that most affect behavior"
     either. The contract is the table ROW only. Adding prose = scope creep. -->

<!-- CRITICAL — preserve markdown structure: the env-var row must have exactly 4 pipes (3 cols);
     the ASCII diagram line stays inside its ``` fence with the same `│`/`├─` glyphs; blockquote lines
     keep their `>` prefix; the ordered-list item keeps its `3.` prefix. Word-wrap inside a markdown
     paragraph is SOFT (a single newline = same paragraph) so re-wrapping the multi-line TS symptom
     quote / fix block is safe — just keep it readable. -->

<!-- NO markdownlint on PATH. Validation is grep + visual + git-diff (all static). Do NOT install
     tooling. -->
```

---

## Implementation Blueprint

### Canonical terminology map (use these EXACT phrases — cross-doc consistent)
| Concept | Use | Do NOT use |
|---------|-----|-----------|
| "pi ancestor" (concept) | **recognized-harness ancestor** | "harness ancestor" (too vague) |
| "owning `pi` process" | **owning harness process** | "owning agent process" |
| "owning pi PID" / "its `pi` PID" | **owning harness PID** / **its harness PID** | — |
| "under `pi`" (where to run) | **under a supported harness (`pi`/`claude`/`codex`/`agy`)** | "under a harness" |
| "require a `pi` ancestor" (prose) | **require a supported-harness ancestor** | — |
| fail-fast MESSAGE (quote verbatim) | **driving commands require a supported agent harness (pi/claude/codex/agy)** | (the bare concept phrase) |
| TS error heading/name | **"requires a supported agent harness"** | — |

### Substitution table (the ENTIRE change — 17 edits, README.md only)
Re-derive line numbers first (Task 1). The BEFORE text is verbatim-unique; match on it. `…` = unchanged tail.

#### (a) Env-var table — INSERT one row
| # | After line | BEFORE (anchor; insert a new line immediately AFTER this full row) | AFTER (anchor row + NEW row beneath it) |
|---|-----------|-------------------------------------------------------------------|------------------------------------------|
| 1 | 248 | `\| \`AGENT_CHROME_ALLOW_SLOW_COPY\` \| unset = **refuse** on non-btrfs \| set to \`1\`/\`true\`/\`yes\`/\`on\` to permit a real (slow) ~4.8 GB copy per acquire \|` | same row, then NEW line:<br>`\| \`AGENT_BROWSER_POOL_HARNESSES\` \| \`pi,claude,codex,agy,antigravity\` \| comma-separated \`comm\` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) \|` |

> The NEW row is **byte-identical** to `configuration.md:28` (Default + Meaning). This is the cross-file sync invariant.

#### (b) Usage blockquote (L101–106) — 3 edits
| # | Line | BEFORE (exact, unique) | AFTER |
|---|------|------------------------|-------|
| 2 | 101 | `> **Driving commands require a \`pi\` ancestor.** From a plain terminal with no \`pi\` ancestor, a` | `> **Driving commands require a supported-harness ancestor.** From a plain terminal with no recognized-harness ancestor, a` |
| 3 | 103 | `> under \`pi\`, or call \`agent-browser\` directly for raw access without pooling. Pool verbs` | `> under a supported harness (\`pi\`/\`claude\`/\`codex\`/\`agy\`), or call \`agent-browser\` directly for raw access without pooling. Pool verbs` |
| 4 | 105 | `> command is a driving command that requires a \`pi\` ancestor.` | `> command is a driving command that requires a supported-harness ancestor.` |

#### (c) Classification-detail callout (L151) — 1 edit
| # | Line | BEFORE | AFTER |
|---|------|--------|-------|
| 5 | 151 | `> command resolves your owning \`pi\` process, **fails fast** without a \`pi\` ancestor, and runs` | `> command resolves your owning harness process, **fails fast** without a recognized-harness ancestor, and runs` |

#### (d) How-it-works architecture diagram (L278) — 1 edit
| # | Line | BEFORE | AFTER |
|---|------|--------|-------|
| 6 | 278 | `   │           resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST` | `   │           resolve owning harness PID + starttime; no recognized-harness ancestor → FAIL-FAST` |

> Keep the diagram inside its ``` fence; preserve the leading `   │           ` indent + `→` glyph exactly.

#### (e) Lane lifecycle list (L290) — 1 edit
| # | Line | BEFORE | AFTER |
|---|------|--------|-------|
| 7 | 290 | `3. **driving command → resolve the owning \`pi\` process**; if there is no \`pi\` ancestor,` | `3. **driving command → resolve the owning harness process**; if there is no recognized-harness ancestor,` |

#### (f) Troubleshooting section (L318–330) — 4 edits (heading + symptom + cause + fix)
| # | Line(s) | BEFORE (exact, unique) | AFTER |
|---|---------|------------------------|-------|
| 8 | 318 | `### Driving command errored: "requires a pi ancestor"` | `### Driving command errored: "requires a supported agent harness"` |
| 9 | 320-321 | `**Symptom:** an \`agent-browser-pool\` driving command fails with a message like *"driving`<br>`commands require a pi ancestor (owning pi process)."*` | `**Symptom:** an \`agent-browser-pool\` driving command fails with a message like`<br>*"agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy). For raw browser use without pooling, call 'agent-browser' directly."*` |
| 10 | 323-324 | `**Cause:** by design. Driving commands acquire a lane keyed on your owning \`pi\` process; with`<br>`no \`pi\` ancestor in the process tree, there is no identity to key the lease on, so the command` | `**Cause:** by design. Driving commands acquire a lane keyed on your owning harness process; with`<br>`no recognized-harness ancestor in the process tree, there is no identity to key the lease on, so the command` |
| 11 | 327-330 | `**Fix:** run browser work under \`pi\` (e.g. inside a \`pi\` session), or — for raw browser use`<br>`without pooling — call the real \`agent-browser\` directly. Pool verbs (\`status\`, \`doctor\`,`<br>`reap\`, \`release\`, \`help\`) work from any shell; all other commands are driving (they`<br>`require a \`pi\` ancestor).` | `**Fix:** run browser work under a supported harness (e.g. inside a \`pi\`/\`claude\`/\`codex\`/\`agy\``<br>`session), or — for raw browser use without pooling — call the real \`agent-browser\` directly. Pool`<br>`verbs (\`status\`, \`doctor\`, \`reap\`, \`release\`, \`help\`) work from any shell; all other commands are`<br>`driving (they require a supported-harness ancestor).` |

> Row 9 (symptom) mirrors the R3 `pool_die` emitted text verbatim (lib/pool.sh:3429-3430). The
> `(pi/claude/codex/agy)` inside the quote is PLAIN text (no backticks) — it's literal message text.

#### (g) Phrasing sweep (L16, L86, L172, L301, L304) — 5 edits
| # | Line | BEFORE (exact, unique) | AFTER |
|---|------|------------------------|-------|
| 12 | 16 | `Mutual exclusion via leases keyed on the owning \`pi\` process (and` | `Mutual exclusion via leases keyed on the owning harness process (and` |
| 13 | 86 | `identity (your owning \`pi\` process and its start time) — **the command never names a lane**,` | `identity (your owning harness process and its start time) — **the command never names a lane**,` |
| 14 | 172 | `Tear down lanes whose owning \`pi\` process has died (kill the Chrome process group, delete the` | `Tear down lanes whose owning harness process has died (kill the Chrome process group, delete the` |
| 15 | 301 | `**Release** happens when the owning \`pi\` process exits (the next acquire reaps it), on` | `**Release** happens when the owning harness process exits (the next acquire reaps it), on` |
| 16 | 304 | `crashed agent → its \`pi\` PID dies → next acquire reaps it. \`close\` mid-task is` | `crashed agent → its harness PID dies → next acquire reaps it. \`close\` mid-task is` |

### Implementation Tasks (ordered)
```yaml
Task 1: RE-DERIVE exact line numbers (contract/docs_map numbers are approximate; sibling landings shift them)
  - RUN: grep -nE 'pi ancestor|owning .pi. process|under .pi.|requires a .pi. ancestor|resolve owning pi' README.md
          # → the 16 phrasing anchors (rows 2-7, 8-11, 12-16) + confirms row 1's table position.
  - RUN: grep -n 'AGENT_CHROME_ALLOW_SLOW_COPY' README.md
          # → the env-var table's current last row (insert the new row immediately AFTER it).
  - RUN: grep -n 'AGENT_BROWSER_POOL_HARNESSES' README.md
          # → expect ZERO hits BEFORE the edit (confirms the row is genuinely missing → this item adds it).
  - RUN: grep -c '`pi`' README.md    # baseline (expect ~12 BEFORE); record it.

Task 2: VERIFY source-of-truth wording BEFORE editing (do not edit these — just confirm they match the table)
  - RUN: sed -n '3429,3430p' lib/pool.sh   # → the R3 pool_die text (row 8 heading + row 9 symptom mirror this).
  - RUN: grep -n 'AGENT_BROWSER_POOL_HARNESSES' .agents/skills/agent-browser-pool/references/configuration.md
          # → line 28; the EXACT row README's new row (row 1) must equal byte-for-byte.

Task 3: EDIT README.md — apply substitution-table rows 1-16 (the `edit` tool, one edits[] entry per row,
        exact BEFORE snippet as oldText). 16 edits; all in README.md.
  - ROW 1 (table insert): oldText = the AGENT_CHROME_ALLOW_SLOW_COPY row verbatim; newText = that row + "\n"
          + the AGENT_BROWSER_POOL_HARNESSES row verbatim from configuration.md:28.
  - ROWS 2-16: oldText/newText exactly as the table; match on the verbatim BEFORE text (unique per row).
  - PRESERVE: markdown structure (3-col table = 4 pipes/row; ``` fence around the diagram; `>` blockquote
          prefixes; `3.` / `### ` list/heading prefixes; the `│`/`├─`/`→` diagram glyphs + indent).
  - DO NOT TOUCH: line 262 (test-only hooks callout), the Installation section (~L51-81, sibling S2's
          region), install.sh, lib/pool.sh, configuration.md, any test file, any other file.

Task 4: STATIC VALIDATE (no suite run — AGENTS.md §1; nothing to run for docs anyway)
  - RUN the Validation Loop (Level 1-3) grep checks below. All must pass before declaring done.
```

### Implementation Patterns & Key Details
```markdown
<!-- (1) Row 1 is an INSERT, not a replace: oldText = the existing ALLOW_SLOW_COPY row (unique);
          newText = that SAME row + a newline + the NEW HARNESSES row. This appends the row in place. -->

<!-- (2) Row 9 (TS symptom) is a 2-physical-line block → give the edit tool BOTH lines as one oldText
          (the two source lines joined by a real newline) and the full 2-line newText. Same for rows
          10 and 11 (cause = 2 lines; fix = 4 lines). One edit-tool entry per multi-line block. -->

<!-- (3) The harness enumeration uses BACKTICKED short names in PROSE: (`pi`/`claude`/`codex`/`agy`)
          (rows 3, 11). Inside the LITERAL R3 message quote (row 9) it is PLAIN text with no backticks:
          (pi/claude/codex/agy) — because it's quoting emitted CLI output, not naming the tools. -->

<!-- (4) "supported-harness ancestor" (HYPHENATED adjective before "ancestor") in prose/callouts
          (rows 2, 4, 5, 7, 11) vs "supported agent harness" (the literal message substring) in the
          heading (row 8) + symptom quote (row 9). Do not mix these up. -->
```

### Integration Points
```yaml
UPSTREAM (consumed, READ ONLY):
  - lib/pool.sh:3429-3430 — R3 fail-fast message text (landed P3.M1.T1.S3, Complete).
  - lib/pool.sh:192,195 — AGENT_BROWSER_POOL_HARNESSES default (landed P3.M1.T1.S1, Complete).
  - .agents/skills/agent-browser-pool/references/configuration.md:28 — env-var row wording source of
    truth (Mode A landed + committed).
DOWNSTREAM: README is a leaf doc; nothing consumes it programmatically. No config, no routes, no
  migrations, no code.
PARALLEL SIBLING S3 (P3.M2.T1.S3): edits test/transparency.sh — DISJOINT FILE, no conflict, no
  dependency. No coordination needed.
FUTURE SIBLINGS S2 (P3.M3.T1.S2, cross-harness install section) + S3-doc (P3.M3.T1.S3, install.sh
  help): disjoint regions/files. S2 lands a NEW README section after the Installation block; its
  implementer re-derives line numbers independently. This item does NOT block or depend on them.
```

---

## Validation Loop

### Level 1: Markdown sanity (run after the edit — static, no tooling)
```bash
# (a) env-var table still well-formed: the new row has exactly 4 pipes (3 cols) like its siblings.
awk '/^\| `Env var`|^\| Variable/{t=1} t&&/AGENT_BROWSER_POOL_HARNESSES/{n=gsub(/\|/,"|");print "pipes="n; t=0}' README.md
#   expect: pipes=4   (3 columns => 4 pipe chars). Compare: any other row also = 4.

# (b) diagram line still inside its fence + glyph/indent preserved.
grep -n 'resolve owning harness PID + starttime; no recognized-harness ancestor → FAIL-FAST' README.md
#   expect: exactly 1 hit, on the diagram line (leading "   │           " indent intact).
```
Expected: the new table row is a valid 3-column row; the diagram line is intact. If pipes != 4, the
row is malformed — re-apply row 1.

### Level 2: Wording sweep (confirm in-scope generalization is complete)
```bash
# (a) ZERO stale "pi ancestor" anywhere in README (all removed).
grep -c 'pi ancestor' README.md                                       # expect 0

# (b) ZERO stale "owning `pi` process" / "requires a `pi` ancestor" / "under `pi`" (prose forms).
grep -nE 'owning `pi` process|requires a `pi` ancestor|under `pi`' README.md   # expect NO hits

# (c) The ONLY remaining backtick-pi references are the intentional ones: L262 (test hooks) + the
#     new harness enumerations. (Should be ~3 lines: L~103, L262, L~327.)
grep -n '`pi`' README.md

# (d) New generalized wording IS present (spot-check each region).
grep -n 'supported-harness ancestor' README.md          # expect ≥5 (usage×2, classification, lifecycle, TS fix)
grep -n 'recognized-harness ancestor' README.md         # expect ≥4 (usage, classification, diagram, lifecycle, TS cause)
grep -n 'owning harness process' README.md              # expect ≥5 (bullet, usage, reap, lifecycle, release, TS cause)
grep -n 'supported agent harness (pi/claude/codex/agy)' README.md  # expect 2 (TS heading + symptom quote)
```
Expected: (a)=0, (b)=empty, (c)=the ~3 intentional lines, (d)=all present. If (a)>0 or (b) non-empty,
an in-scope edit was missed — re-check the substitution table.

### Level 3: Cross-file sync (the env-var row invariant + change scope)
```bash
# (a) README's new row EQUALS configuration.md:28 (Default + Meaning byte-identical).
diff <(grep 'AGENT_BROWSER_POOL_HARNESSES' README.md) \
     <(grep 'AGENT_BROWSER_POOL_HARNESSES' .agents/skills/agent-browser-pool/references/configuration.md)
#   expect: EMPTY diff (identical). NOTE: the two files' table headers differ in name only
#   (README "| Env var |" vs config "| Variable |") — that's the existing convention, not a defect.

# (b) Line 262 (test-only hooks) is UNCHANGED — still matches configuration.md's test-hooks wording.
grep -n 'without a real `pi` ancestor' README.md        # expect exactly 1 hit (L262)

# (c) Change scope: ONLY README.md modified.
git diff --stat                                          # expect exactly one file: README.md
git status --short | grep -v 'plan/003' | grep -qE '^.M|^M' && echo "UNEXPECTED MODIFIED FILE" || echo "scope OK"
```
Expected: (a) empty diff, (b) exactly 1 hit at L262, (c) only README.md. If (a) differs, fix the row
to match `configuration.md:28` verbatim. If (c) flags another file, revert it (scope violation).

### Level 4: Not applicable
Docs-only; no service, no DB, no MCP, no performance/security gates. (AGENTS.md §3 process-hygiene:
no subprocess was spawned — no orphans to reap. No-op by construction.)

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: new env-var row has 4 pipes (3 cols); diagram line intact inside its fence.
- [ ] Level 2(a): `grep -c 'pi ancestor' README.md` = 0.
- [ ] Level 2(b): `grep -nE 'owning `pi` process|requires a `pi` ancestor|under `pi`'` = empty.
- [ ] Level 2(c): only intentional `` `pi` `` refs remain (L262 + the new enumerations).
- [ ] Level 2(d): all generalized phrases present in every edited region.
- [ ] Level 3(a): README HARNESSES row byte-identical to `configuration.md:28` (empty diff).
- [ ] Level 3(c): `git diff --stat` touches ONLY `README.md`.

### Feature Validation
- [ ] `AGENT_BROWSER_POOL_HARNESSES` row present in the env-var table (after ALLOW_SLOW_COPY).
- [ ] Usage blockquote (L101–106), Classification callout (L151), diagram (L278), lifecycle (L290),
      Troubleshooting (L318–330) all generalized.
- [ ] TS heading + symptom quote mirror R3 `lib/pool.sh:3429-3430` text.
- [ ] Phrasing sweep applied at L16, L86, L172, L301, L304.

### Scope Discipline
- [ ] Only `README.md` edited; exactly the 16 table rows (1 insert + 15 substitutions).
- [ ] Line 262 (test-only hooks callout) UNCHANGED (matches configuration.md; intentional).
- [ ] NO §2.17 cross-harness install section/table/Codex caveat added (that's sibling S2).
- [ ] NO change to install.sh, lib/pool.sh, configuration.md, any test file, PRD.md, tasks.json.
- [ ] NO "Three vars shape behavior most" prose edit; NO MASTER-default "fix" (pre-existing, OOS).
- [ ] No test suite executed; no Chrome booted; no daemon/orphan/temp-dir (docs-only, nothing ran).

### Documentation Quality
- [ ] README internally consistent (no mixed pi-only + harness phrasings).
- [ ] README consistent with configuration.md / PRD §2.4/§2.11 terminology.
- [ ] Markdown structure (tables, fence, blockquotes, list/heading prefixes) preserved.

---

## Anti-Patterns to Avoid
- ❌ Don't trust the contract's/docs_map's line numbers verbatim ("L275" diagram is really L278) —
  re-derive with the Task-1 grep; match edits on verbatim TEXT, not line numbers.
- ❌ Don't paraphrase the env-var Meaning cell — copy `configuration.md:28` byte-for-byte (cross-file
  invariant; Level 3(a) diff must be empty).
- ❌ Don't touch line 262 (test-only hooks) — configuration.md keeps the identical "real `pi`
  ancestor" wording there; changing README alone breaks cross-doc consistency.
- ❌ Don't add the cross-harness skill-install section / per-harness table / Codex caveat — that's
  sibling P3.M3.T1.S2 (docs_map File 4d). Scope theft.
- ❌ Don't add AGENT_BROWSER_POOL_HARNESSES to the "Three vars shape behavior most" prose, or "fix"
  the pre-existing MASTER-default mismatch — both out of scope (scope creep).
- ❌ Don't backtick the harness names inside the literal R3 message quote (row 9) — emitted CLI text
  is plain `(pi/claude/codex/agy)`; backticks are only for PROSE enumerations (rows 3, 11).
- ❌ Don't conflate "supported-harness ancestor" (prose adjective) with "supported agent harness"
  (the literal message substring in the heading/quote) — see Implementation Patterns (4).
- ❌ Don't run the test suite / boot Chrome / install tooling — docs-only; AGENTS.md §1.

---

## Confidence Score
**9.5/10.** Docs-only; all 17 anchors enumerated with verbatim current text + exact before→after;
the two source-of-truth inputs (R3 message at lib/pool.sh:3429-3430; env-var row at
configuration.md:28) are host-verified and already landed; the canonical terminology map is locked
to cross-doc usage (PRD + configuration.md + sibling PRPs); the scope boundary (siblings S2/S3 +
intentional L262 exclusion) is explicit; validation is static grep + cross-file diff, all verified
runnable here. The −0.5 is residual risk the implementer wraps the multi-line TS symptom/fix blocks
differently than the verbatim target — mitigated by giving the exact 2-/4-line target text and the
note that markdown soft-wrapping makes re-wrap safe.
