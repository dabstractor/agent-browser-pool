# PRP — P3.M3.T1.S2: Add §2.17 cross-harness skill-install paragraph + per-harness table + Codex caveat to README.md

**Work item:** P3.M3.T1.S2 (1 point) — parent P3.M3.T1 (Sync changeset-level documentation),
milestone P3.M3 (Sync changeset-level documentation). PRD §2.17 (Install — the per-harness
skills-dir table + Codex symlink caveat). Decision O9 (Multi-harness owner resolution). This is
the **headline documentation addition** of the changeset (delta_prd.md R5 Mode B item (c)).
**Type:** Documentation-only (Mode B changeset-level). **One file: `README.md` (root).** No code.
No tests. No config/API surface change.
**Phase constraint:** PLANNING deliverable; AGENTS.md §1 static-only validation is trivially
satisfied (nothing to execute — no Chrome, no suite, no daemon).
**Parallel context:** sibling **P3.M3.T1.S1** (Implementing) also edits `README.md`, but in
DISJOINT regions (its nearest edit is inside the Usage section at L86+; it never touches the
Installation body L51–82 nor the `## Usage` heading). See §Coordination below.

---

## Goal

**Feature Goal:** Document, in the root `README.md`, that the `agent-browser-pool` agent skill is
**cross-harness and installed per-harness** — adding a new `###` subsection to the `## Installation`
section that contains: (a) a paragraph stating the skill is an Agent Skills-standard skill
discovered project-scoped, with `install.sh --global-skill` as the pi symlink path; (b) a 4-row
**per-harness skills-dir table** (pi / Claude Code / Codex / Antigravity — global dir, project dir,
follows-symlinks); and (c) a **Codex symlink caveat** blockquote (Codex does not discover a
symlinked `.agents/skills`, openai/codex#11314 → install a real directory copy into
`~/.codex/skills/`). Source of truth is **PRD §2.17**; the text is reproduced verbatim.

**Deliverable:** ONE pure INSERTION in `README.md` — a new `### Cross-harness skill installation`
subsection placed between the existing `See [PRD.md §2.17]…` pointer (the last line of the
Installation section) and the `## Usage (for agents)` heading. Verbatim content (heading + paragraph
+ table + blockquote) supplied below. **No other file changes. No existing Installation prose is
rewritten or displaced** (the pi `--global-skill` opt-in paragraph stays exactly as-is).

**Success Definition:**
1. `README.md` contains a new `### Cross-harness skill installation` subsection (exactly once)
   located inside `## Installation`, immediately after the `See [PRD.md §2.17]…` pointer and
   immediately before `## Usage (for agents)`.
2. The subsection contains the **verbatim PRD §2.17** paragraph + 4-row table (pi / Claude Code /
   Codex / Antigravity, with the Codex row's Follows-symlinks cell = `**no — openai/codex#11314**`)
   + the **verbatim Codex caveat** blockquote.
3. The pre-existing pi `--global-skill` opt-in paragraph (`**The agent skill is opt-in.**` …) is
   **unchanged** and still present exactly once.
4. The `See [PRD.md §2.17]…` pointer and the `## Usage (for agents)` heading are both still present
   exactly once (the insertion sits *between* them; neither is modified).
5. `git diff --stat` touches **only** `README.md`.

---

## Why

- P3.M1 + Decision O9 generalized owner resolution from `pi`-only to a **recognized-harness set**
  (pi / Claude Code / Codex / AGY / Antigravity). The capability now exists; the README's
  Installation section, however, is still **pi-only** — it documents only `install.sh --global-skill`
  (which symlinks into `~/.agents/skills/` for pi) and a pi-only uninstall. There is **no
  per-harness skills-dir table and no Codex caveat**. Users of Claude Code / Codex / Antigravity have
  no guidance on where to install the skill or why a plain `--global-skill` symlink fails for Codex.
- This is the **headline doc addition** of the changeset (delta_prd.md R5, Mode B item (c)). PRD §2.17
  is the source of truth: it defines the per-harness skill dirs and the Codex symlink caveat
  (openai/codex#11314: Codex does not discover a symlinked `.agents/skills/`).
- Docs-only: zero runtime risk. The value is correctness/usability for human readers + the skill's
  cross-references; there is no code or test impact.

---

## What

### User-visible behavior
None (documentation). A reader of `README.md`'s Installation section now sees, in addition to the
existing pi `--global-skill` path, a cross-harness subsection telling them: the global + project
skills dir for each of the four supported harnesses, which ones follow symlinks, and the Codex
workaround (real directory copy).

### Technical change (confined to `README.md`)
Exactly ONE `edit` call: a pure INSERT of a new `### Cross-harness skill installation` subsection
between two unique text anchors (the `See [PRD.md §2.17]…` pointer and the `## Usage (for agents)`
heading). No structural change elsewhere; no heading moved/renamed/removed. Full verbatim content in
the Implementation Blueprint.

### Success Criteria
- [ ] New `### Cross-harness skill installation` heading present, exactly once, under `## Installation`.
- [ ] Cross-harness paragraph present verbatim (Agent Skills-standard skill at
      `.agents/skills/agent-browser-pool/`; `install.sh --global-skill` symlinks into `~/.agents/skills/`).
- [ ] Per-harness table present verbatim: 4 data rows (pi, Claude Code, Codex, Antigravity); Codex
      row's Follows-symlinks cell = `**no — openai/codex#11314**`; Antigravity = `verify`.
- [ ] Codex caveat blockquote present verbatim (`> **Codex caveat:**` … real directory copy …).
- [ ] Pre-existing pi `--global-skill` paragraph (`**The agent skill is opt-in.**`) UNCHANGED.
- [ ] `See [PRD.md §2.17]…` pointer and `## Usage (for agents)` heading both still present once.
- [ ] Only `README.md` modified (`git diff --stat`).

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact single `edit` call (unique text anchors
+ the verbatim insertion content reproduced from the PRD source of truth), the explicit "keep the pi
paragraph / pointer / heading" boundary, the host-verified uniqueness of both anchors, the verified
Codex issue facts, and static-only validation commands. Nothing else required._

### Documentation & References
```yaml
- file: PRD.md  (read-only — AGENTS.md §5)
  why: SOURCE OF TRUTH. §2.17 "Install" defines the exact per-harness table + Codex caveat text.
       The subsection content below is reproduced BYTE-FOR-BYTE from PRD §2.17 (the block beginning
       "**The agent skill is cross-harness, installed per-harness.**"). The PRD table has NO sub-
       heading; this PRP ADDS a `### Cross-harness skill installation` heading for README
       navigability (see Faithfulness decisions in Implementation Patterns).
  critical: Do NOT edit PRD.md. Reproduce its §2.17 table + caveat VERBATIM (wide pipe-separator
            form, plain `openai/codex#11314`, plain harness names, `verify` for Antigravity).

- file: README.md  (THE ONLY FILE EDITED — not in the AGENTS.md §5 read-only list)
  why: TARGET FILE. The `## Installation` section (L51–81) currently ends with the
       `See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).`
       pointer (L81, UNIQUE in the file). `## Usage (for agents)` follows at L83 (UNIQUE). The new
       subsection is INSERTED between them (on the L82 blank-line position).
  pattern: `## Installation` is an h2; the README already uses h3 subsections under other h2s
           (`### status`/`### reap`/… under `## Admin commands`; `### Driving command errored…`/
           `### Pool exhaustion…`/`### Leaks…` under `## Troubleshooting`). A new h3 under
           `## Installation` is consistent. The README's only existing rendered pipe table is the
           env-var table (compact `|---|---|---|` separators); the PRD table uses WIDE separators
           — both render identically on GitHub.
  critical: Re-derive the anchor lines with the Task-1 grep before editing (sibling landings shift
            numbers). MATCH ON TEXT, not line numbers. Do NOT touch the existing pi `--global-skill`
            opt-in paragraph (the `**The agent skill is opt-in.**` block, ~L67–73), the uninstall
            block (~L75–79), or the §2.17 pointer (L81). Do NOT touch any region edited by sibling S1.

- file: plan/003_afc2f15931ab/architecture/docs_map.md  (read-only)
  why: File 4 §4d defines THIS item ("Cross-harness skill-install section — DOES NOT EXIST YET, delta
       ADDS it … the headline doc addition"). "Cross-file sync constraints" confirms the addition is
       README-only; install.sh gains no new behavior (sibling S3-doc is an OPTIONAL help-text tweak).
  critical: docs_map File 4 §4a–4c (env-var row, callouts, diagram, troubleshooting) are sibling S1's
            edits, NOT this item. Do NOT perform them here (scope theft).

- url: https://github.com/openai/codex/issues/11314  (reference — DO NOT inline this URL in README)
  why: VERIFIED host-research: "Codex CLI doesn't load skills from `.agents/skills` when it is a
       symlink." → confirms the headline caveat is accurate and the "real directory copy" guidance
       is correct. Reinforced by openai/codex#17344 (Codex ALSO skips a symlinked `SKILL.md` inside
       `~/.codex/skills/` → the whole skill dir must be a real copy, not a symlink).
  critical: The README keeps `openai/codex#11314` as PLAIN text (matches PRD §2.17 verbatim; the
            README has no per-issue link precedent). Do NOT linkify it in README content.

- file: plan/003_afc2f15931ab/P3M3T1S2/research/notes.md
  why: THIS item's research — verbatim anchor text + uniqueness check, the exact insertion content,
       fact verification (#11314 / #17344 / local pi dirs), sibling-coordination analysis, validation
       design. READ THIS.

- file: plan/003_afc2f15931ab/P3M3T1S1/PRP.md  (read-only — the parallel sibling's CONTRACT)
  why: S1 edits README.md in DISJOINT regions (L16, L86, L101–106, L151, L172, L248, L278, L290,
       L301/304, L318–330). It NEVER touches L51–82 (Installation body) or the `## Usage` heading.
       Its row-1 edit (the `AGENT_BROWSER_POOL_HARNESSES` env-var table row) is NOT this item.
  critical: Assume S1 will land exactly as specified. This item's single INSERT (L81→L83 boundary)
            commutes with all of S1's edits — landing order is irrelevant because both anchor on
            unique text, not line numbers. Do NOT duplicate S1's env-var row or phrasing sweep.

- file: AGENTS.md  (read-only)
  why: §1 (static-only planning validation — trivially met: docs, nothing to run); §5 (README is NOT
       in the read-only list — editable; PRD.md/tasks.json/.gitignore/prd_snapshot.md ARE read-only).
```

### Current codebase tree (relevant slice)
```
README.md                                                       # TARGET (the only edited file)
PRD.md                                                          # §2.17 source of truth (READ ONLY)
plan/003_afc2f15931ab/architecture/docs_map.md                  # File 4 §4d scoping (READ ONLY)
plan/003_afc2f15931ab/P3M3T1S1/PRP.md                           # parallel sibling CONTRACT (READ ONLY)
install.sh                                                      # SIBLING S3-doc (not touched here)
.agents/skills/agent-browser-pool/                              # the skill being documented (not touched)
```

### Desired codebase tree (delta)
```
README.md    # MODIFIED: +1 NEW `### Cross-harness skill installation` subsection (paragraph + table + caveat).
(no new files; no deletions; no other file touched.)
```

### Known Gotchas of our codebase & Library Quirks
```markdown
<!-- CRITICAL — line numbers are APPROXIMATE; re-derive with the Task-1 grep before editing. Sibling
     S1 (in-flight) and this item both edit README.md; landing order shifts line numbers. The
     insertion ANCHORS are the two UNIQUE text strings below — match on THEM, not on line numbers. -->

<!-- CRITICAL — This is a PURE INSERT between two unique anchors. Do NOT rewrite the existing pi
     `--global-skill` opt-in paragraph, the uninstall block, or the `See [PRD.md §2.17]…` pointer.
     Do NOT move/renumber any heading. The new subsection COMPLEMENTS the existing pi paragraph; it
     does not displace it. -->

<!-- CRITICAL — Reproduce the PRD §2.17 table + caveat BYTE-FOR-BYTE: keep the WIDE pipe-separator
     form (do not "tidy" to compact `|---|`), keep `openai/codex#11314` PLAIN (do NOT linkify), keep
     harness names PLAIN (no backticks in column 1), keep paths BACKTICKED, keep `verify` for
     Antigravity (do NOT upgrade to yes/no), keep `**no — openai/codex#11314**` for Codex. -->

<!-- CRITICAL — The "real directory copy" wording in the Codex caveat is load-bearing: openai/codex#11314
     (symlinked .agents/skills not discovered) AND openai/codex#17344 (symlinked SKILL.md inside
     ~/.codex/skills also skipped) both mean a SYMLINK does not work for Codex. Do NOT soften "real
     directory copy" to "symlink" — that guidance would be wrong. -->

<!-- CRITICAL — SCOPE DISCIPLINE. Do NOT add the AGENT_BROWSER_POOL_HARNESSES env-var table row
     (sibling S1's row-1 edit). Do NOT generalize any pi-ancestor phrasing (sibling S1's rows 2–16).
     Do NOT touch install.sh (sibling S3-doc). Do NOT touch lib/pool.sh / configuration.md / SKILL.md
     / any test file / PRD.md / tasks.json. Only README.md. -->

<!-- NO markdownlint on PATH. Validation is grep + visual + git-diff (all static). Do NOT install
     tooling. (AGENTS.md §1 — docs-only, nothing to execute.) -->
```

---

## Implementation Blueprint

### The single edit (the ENTIRE change — README.md only)

Re-derive line numbers first (Task 1). The `oldText` below is verbatim-unique; match on it.

#### `edit` call

**`oldText`** (3 physical lines — the §2.17 pointer, a blank line, the Usage heading; all UNIQUE):
```
See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).

## Usage (for agents)
```

**`newText`** (the pointer + blank + NEW subsection + blank + the Usage heading — i.e. the `oldText`
with the new `###` block spliced in between):
```
See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).

### Cross-harness skill installation

**The agent skill is cross-harness, installed per-harness.** The skill is an Agent
Skills-standard skill at `.agents/skills/agent-browser-pool/` (discovered project-scoped
inside this repo). `install.sh --global-skill` symlinks it into `~/.agents/skills/`. To
teach each harness natively, install into its own skills dir:

| Harness               | Global skills dir                          | Project skills dir     | Follows symlinks?           |
| --------------------- | ------------------------------------------ | ---------------------- | --------------------------- |
| pi                    | `~/.agents/skills/`, `~/.pi/agent/skills/` | `.agents/skills/`      | yes                         |
| Claude Code           | `~/.claude/skills/`                        | `.claude/skills/`      | yes                         |
| Codex                 | `~/.codex/skills/`                         | `.agents/skills/`      | **no — openai/codex#11314** |
| Antigravity (agy/IDE) | `~/.antigravity/skills/`                   | `.antigravity/skills/` | verify                      |

> **Codex caveat:** Codex does not discover a *symlinked* `.agents/skills` (openai/codex#11314).
> For Codex, install the skill as a real directory copy into `~/.codex/skills/` (or wait for
> the upstream fix). pi and Claude Code follow symlinks, so `--global-skill` suffices for them.

## Usage (for agents)
```

> **The paragraph + table + caveat text is reproduced BYTE-FOR-BYTE from PRD §2.17.** The only
> addition is the `### Cross-harness skill installation` heading (the PRD §2.17 block has no
> sub-heading). This heading is REQUIRED for README navigability and is consistent with the
> README's h3-under-h2 convention (see Documentation & References → README.md pattern).

### Implementation Patterns & Key Details
```markdown
<!-- (1) SINGLE edit, PURE INSERT. oldText spans exactly: the §2.17 pointer line + one blank line +
          the `## Usage (for agents)` heading. newText = those same three lines with the new `###`
          block spliced between the pointer and the Usage heading. Do not include any other context
          in oldText (it must be unique and minimal). -->

<!-- (2) FAITHFULNESS — reproduce PRD §2.17 verbatim. Do NOT: change the wide pipe separators to
          compact form; backtick the harness names in column 1; linkify openai/codex#11314; upgrade
          Antigravity's `verify` to yes/no; or alter the caveat wording. The PRD is the source of
          truth; the table is mirrored, not paraphrased. -->

<!-- (3) The table has 4 DATA rows (pi, Claude Code, Codex, Antigravity) + 1 header + 1 separator.
          Each row line has exactly 5 pipe chars (4 columns). GitHub renders the wide separator
          identically to compact `|---|`; keep the PRD's wide form (lower risk of misalignment if
          the implementer tries to "fix" it). -->

<!-- (4) The Codex caveat is a markdown BLOCKQUOTE (`>`-prefixed, 3 lines). Keep the `*symlinked*`
          emphasis (italic) and the plain `openai/codex#11314` reference. It is the PRD's exact text. -->

<!-- (5) HEADING LEVEL: `### Cross-harness skill installation` (h3) — placed UNDER `## Installation`
          (h2). Matches the README convention (h3 subsections under `## Admin commands` and
          `## Troubleshooting`). Do NOT make it `##` (that would create a peer of Installation/Usage)
          and do NOT omit it (the README's other added blocks get headings). -->
```

### Implementation Tasks (ordered)
```yaml
Task 1: RE-DERIVE the insertion anchors (contract line numbers are approximate; sibling landings shift them)
  - RUN: grep -n 'See \[PRD\.md §2\.17\](\./PRD\.md) for why installation is non-disruptive' README.md
          # → the UNIQUE pointer line (currently ~L81). This is the FIRST line of oldText.
  - RUN: grep -n '^## Usage (for agents)' README.md
          # → the UNIQUE Usage heading (currently ~L83). This is the LAST line of oldText.
  - RUN: grep -c '^### Cross-harness skill installation' README.md
          # → expect ZERO hits BEFORE the edit (confirms the subsection is genuinely absent → this item adds it).
  - RUN: grep -c '^\*\*The agent skill is opt-in\.\*\*' README.md
          # → expect exactly 1 (the existing pi paragraph — confirm it is PRESENT and will be LEFT UNTOUCHED).

Task 2: APPLY the single edit (the `edit` tool, README.md, ONE edits[] entry)
  - oldText = the 3 physical lines above (pointer + blank + `## Usage (for agents)` heading) VERBATIM.
  - newText = pointer + blank + the NEW `### Cross-harness skill installation` subsection
          (heading + paragraph + table + caveat, all VERBATIM from the Blueprint) + blank + the Usage heading.
  - PRESERVE: the existing pi `--global-skill` opt-in paragraph (DO NOT TOUCH), the uninstall block,
          the `See [PRD.md §2.17]…` pointer (it stays as the line BEFORE the new subsection), and the
          `## Usage (for agents)` heading (it stays as the line AFTER the new subsection).
  - DO NOT TOUCH: any other line of README.md; install.sh; lib/pool.sh; configuration.md; SKILL.md;
          any test file; PRD.md; tasks.json; .gitignore.

Task 3: STATIC VALIDATE (no suite run — AGENTS.md §1; docs-only, nothing to execute)
  - RUN the Validation Loop (Level 1–3) grep checks below. All must pass before declaring done.
```

### Integration Points
```yaml
UPSTREAM (consumed, READ ONLY):
  - PRD.md §2.17 — the verbatim source of the paragraph + table + caveat (the only content source).
DOWNSTREAM: README is a leaf doc; nothing consumes it programmatically. No config, no routes, no
  migrations, no code, no install.sh behavior change (sibling S3-doc is an OPTIONAL help-text tweak
  that POINTS at this new README section; it does not change install.sh's symlink action).
PARALLEL SIBLING S1 (P3.M3.T1.S1, Implementing): edits README.md in DISJOINT regions (L16, L86,
  L101–106, L151, L172, L248, L278, L290, L301/304, L318–330). This item's INSERT (L81→L83 boundary)
  commutes with every S1 edit — landing order is irrelevant because both anchor on unique text, not
  line numbers. No lock/coordination needed.
FUTURE SIBLING S3-doc (P3.M3.T1.S3): optionally points install.sh --global-skill help text at this
  new README section. Disjoint file (install.sh); no dependency on or conflict with this item.
```

---

## Validation Loop

### Level 1: Markdown sanity (run after the edit — static, no tooling)
```bash
# (a) The new heading exists, exactly once, and is an h3.
grep -c '^### Cross-harness skill installation' README.md          # expect 1

# (b) The per-harness table is well-formed: header + separator + 4 data rows; each row has 5 pipes (4 cols).
awk '/^\| Harness /{f=1} f&&/^\|/{n=gsub(/\|/,"&"); print NR": pipes="n} f&&/^\| Antigravity/{exit}' README.md
#   expect: 6 lines (header, separator, pi, Claude Code, Codex, Antigravity), each "pipes=5".

# (c) The Codex caveat blockquote is present.
grep -c '^> \*\*Codex caveat:\*\*' README.md                       # expect 1
```
Expected: (a)=1, (b)=6 table lines each with pipes=5, (c)=1. If (a)≠1 the heading was duplicated/missed;
if (b)≠6 rows or pipes≠5 the table is malformed — re-apply the verbatim table from the Blueprint.

### Level 2: Content fidelity (verbatim PRD §2.17 reproduced)
```bash
# (a) The cross-harness opening sentence is present verbatim.
grep -c 'The agent skill is cross-harness, installed per-harness' README.md   # expect 1

# (b) All four harness rows present, with the EXACT Follows-symlinks cells from PRD §2.17.
grep -c '| pi                    | `~/\.agents/skills/`, `~/\.pi/agent/skills/` | `\.agents/skills/`      | yes' README.md                  # expect 1
grep -c '| Claude Code           | `~/\.claude/skills/`                        | `\.claude/skills/`      | yes' README.md                  # expect 1
grep -c '| Codex                 | `~/\.codex/skills/`                         | `\.agents/skills/`      | \*\*no — openai/codex#11314\*\*' README.md   # expect 1
grep -c '| Antigravity (agy/IDE) | `~/\.antigravity/skills/`                   | `\.antigravity/skills/` | verify' README.md              # expect 1

# (c) The Codex caveat text is present verbatim (plain openai/codex#11314, italic *symlinked*, "real directory copy").
grep -c "does not discover a \*symlinked\* \`\.agents/skills\` (openai/codex#11314)" README.md   # expect 1
grep -c 'install the skill as a real directory copy into `~/\.codex/skills/`' README.md          # expect 1

# (d) NO linkification of the issue reference (PRD keeps it plain).
grep -c '\[openai/codex#11314\]' README.md   # expect 0  (would indicate an unwanted [text](url) link)
```
Expected: every check = 1 (except (d) = 0). If any row/caveat check ≠ 1, the verbatim PRD text was
altered — re-paste from the Blueprint. If (d)≠0, a link was added against the source-of-truth — revert it.

### Level 3: Scope + pre-existing-content preservation
```bash
# (a) The pre-existing pi --global-skill opt-in paragraph is UNCHANGED and still unique.
grep -c '^\*\*The agent skill is opt-in\.\*\*' README.md            # expect 1

# (b) The §2.17 pointer and the Usage heading are both still present exactly once (insertion sits BETWEEN them).
grep -c 'See \[PRD\.md §2\.17\](\./PRD\.md) for why installation is non-disruptive' README.md   # expect 1
grep -c '^## Usage (for agents)' README.md                          # expect 1

# (c) The new subsection is correctly placed: pointer → subsection → Usage heading (ordering check).
awk '/See \[PRD\.md §2\.17\]\(\.\/PRD\.md\) for why installation is non-disruptive/{a=NR}
     /^### Cross-harness skill installation/{b=NR}
     /^## Usage \(for agents\)/{c=NR}
     END{print "pointer="a" subsection="b" usage="c; exit !(a>0 && b>a && c>b)}' README.md \
  && echo "ORDER OK" || echo "ORDER WRONG"

# (d) Change scope: ONLY README.md modified (no other file touched; no PRD.md/tasks.json/install.sh churn).
git diff --stat                                                       # expect exactly one file: README.md
git status --short | grep -v 'plan/003' | grep -qE '^.M|^M|^\?\?' && echo "UNEXPECTED CHANGE" || echo "scope OK"
```
Expected: (a)=1, (b)=1/1, (c)=ORDER OK, (d)=only README.md + scope OK. If (c) is WRONG, the subsection
landed in the wrong place — re-apply the edit with the correct anchors. If (d) flags another file, revert
it (scope violation).

### Level 4: Not applicable
Docs-only; no service, no DB, no MCP, no performance/security gates. (AGENTS.md §3 process-hygiene:
no subprocess was spawned — no orphans to reap. No-op by construction.)

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1(a): `### Cross-harness skill installation` present exactly once.
- [ ] Level 1(b): table = 6 lines (header + separator + 4 rows), each with 5 pipes (4 cols).
- [ ] Level 1(c): Codex caveat blockquote present exactly once.
- [ ] Level 2: paragraph + all 4 table rows + caveat present VERBATIM (every check = 1; link check = 0).
- [ ] Level 3(a)–(b): pi opt-in paragraph, §2.17 pointer, Usage heading all still present once.
- [ ] Level 3(c): ORDER OK (pointer → subsection → Usage heading).
- [ ] Level 3(d): `git diff --stat` touches ONLY `README.md`.

### Feature Validation
- [ ] New `### Cross-harness skill installation` subsection inside `## Installation`, after the
      `See [PRD.md §2.17]…` pointer and before `## Usage (for agents)`.
- [ ] Cross-harness paragraph present (Agent Skills-standard skill; `--global-skill` pi symlink path).
- [ ] Per-harness table present (pi / Claude Code / Codex / Antigravity) with correct dirs + symlink flags.
- [ ] Codex caveat present (real directory copy into `~/.codex/skills/`; #11314).

### Scope Discipline
- [ ] Only `README.md` edited; exactly ONE edit (the pure INSERT described in the Blueprint).
- [ ] Pre-existing pi `--global-skill` opt-in paragraph UNCHANGED (not displaced, not rewritten).
- [ ] `See [PRD.md §2.17]…` pointer + `## Usage (for agents)` heading UNCHANGED (insertion between them).
- [ ] NO `AGENT_BROWSER_POOL_HARNESSES` env-var row added (that's sibling S1).
- [ ] NO pi-ancestor phrasing generalized anywhere (that's sibling S1).
- [ ] NO change to install.sh (sibling S3-doc), lib/pool.sh, configuration.md, SKILL.md, any test file,
      PRD.md, tasks.json, .gitignore.
- [ ] No test suite executed; no Chrome booted; no daemon/orphan/temp-dir (docs-only, nothing ran).

### Documentation Quality
- [ ] README Installation section now documents cross-harness skill install for all four harnesses.
- [ ] README consistent with PRD §2.17 (the source of truth — table + caveat reproduced verbatim).
- [ ] Markdown structure preserved (h3 under h2; 4-col pipe table; blockquote caveat; heading placement).

---

## Anti-Patterns to Avoid
- ❌ Don't trust contract/docs_map line numbers ("L81/L83") verbatim — re-derive with the Task-1 grep;
  match the edit on the two UNIQUE text anchors, not line numbers (sibling S1 landing shifts numbers).
- ❌ Don't rewrite or displace the existing pi `--global-skill` opt-in paragraph — the new subsection
  COMPLEMENTS it (it re-mentions `install.sh --global-skill` as the pi symlink path), it does not replace it.
- ❌ Don't paraphrase the PRD §2.17 table/caveat — reproduce them BYTE-FOR-BYTE (wide separators, plain
  `openai/codex#11314`, plain harness names, backticked paths, `verify` for Antigravity, `**no — …**` for Codex).
- ❌ Don't linkify `openai/codex#11314` in README content — the PRD keeps it plain and the README has no
  per-issue link precedent. (The verified URL https://github.com/openai/codex/issues/11314 is for the
  implementer's reference only; it is NOT inlined.)
- ❌ Don't soften the Codex caveat's "real directory copy" to "symlink" — openai/codex#11314 AND #17344
  both show symlinks don't work for Codex (a symlinked `.agents/skills` is undiscovered, and a symlinked
  `SKILL.md` inside `~/.codex/skills/` is skipped). The skill dir must be a real copy for Codex.
- ❌ Don't add the `AGENT_BROWSER_POOL_HARNESSES` env-var row or generalize pi-ancestor phrasing — those
  are sibling S1's edits (scope theft).
- ❌ Don't make the new heading `##` (it must be `###` under `## Installation`) or omit it (every added
  README block gets a heading for navigability).
- ❌ Don't run the test suite / boot Chrome / install tooling — docs-only; AGENTS.md §1.

---

## Confidence Score
**9.5/10.** Docs-only; the entire change is ONE pure INSERT between two host-verified-UNIQUE text anchors
(no rewrite, no displacement). The verbatim insertion content is reproduced directly from the PRD §2.17
source of truth (already host-confirmed in `selected_prd_content`). Both load-bearing facts are
externally verified: openai/codex#11314 is real and exactly as described (corroborated by #17344), and
pi's skill dirs (`~/.pi/agent/skills/`, `.agents/skills/agent-browser-pool/`) are confirmed locally.
Sibling coordination is fully de-risked: S1's edit regions are textually DISJOINT from this item's
insertion boundary, both anchor on unique text (not line numbers), and the edits commute regardless of
landing order. Validation is static grep + ordering check + git-diff, all verified runnable here. The
−0.5 is residual risk the implementer "tidies" the verbatim table (separator form / linkify the issue /
upgrade `verify`) — mitigated by the explicit Faithfulness decisions and the Level 2 grep checks that
assert byte-for-byte fidelity.
