# PRP — P4.M1.T2.S2: configuration.md env-table rows for ABPOOL_OWNER + ABPOOL_LANE

## Goal

**Feature Goal**: Document the two new env vars `ABPOOL_OWNER` and `ABPOOL_LANE` in the
user-facing env-var table of `.agents/skills/agent-browser-pool/references/configuration.md`
by adding exactly two rows after the `AGENT_BROWSER_POOL_HARNESSES` row (L28), with
defaults and semantics that EXACTLY mirror the frozen implementation contract from
P4.M1.T2.S1 (`POOL_OWNER_MODE` / `POOL_LANE_PIN` in `pool_config_init`).

**Deliverable**: Two new table rows in the 3-column env-var table
(`| Variable | Default | Meaning |`), nothing else in the file changes.

**Success Definition**:
- Row 1: `ABPOOL_OWNER` — default unset; any non-empty value keys lane ownership on the
  calling process (`$$`) instead of the harness ancestor → caller/orchestrator mode;
  recommended conventional value `caller`; cross-reference the "Caller-scoped lanes"
  subsection (added later by P4.M1.T3.S2 — reference it by name, do not create it).
- Row 2: `ABPOOL_LANE` — default unset (auto-assign); positive integer N → adopt free or
  stale lane N, hard-error on a live foreign lease (never a takeover); malformed value →
  hard error at startup (before any lane work).
- Wording mirrors PRD §2.11 bullet lines ("Caller-scoped owner" / "Explicit lane pin").
- Skill docs carry **no PRD § citations** (style rule, docs_map.md §7). The existing PRD
  §2.7 citation at L19 in this file is OUTSIDE the sweep range — leave it untouched.
- Table remains valid Markdown with correct 3-column alignment.

## Why

PRD §2.12/§2.11 introduce caller-scoped ownership and lane pinning; P4.M1.T2.S1 implements
the config parsing in `lib/pool.sh`, and this subtask is the **Mode A documentation for R2**:
the env-var table is the reference agents consult for every variable. P4.M3.T1.S1 (README
sync) copies this wording verbatim and P4.M3.T1.S2 audits the mirror — exactness here
propagates through the whole docs chain.

## What

### Success Criteria

- [ ] Exactly two rows appended to the env-var table, positioned immediately after the
      `AGENT_BROWSER_POOL_HARNESSES` row (which ends at L28) — i.e. new L29–L30.
- [ ] Both defaults shown as `unset = <default behavior>` matching sibling style
      (`AGENT_CHROME_HEADLESS` uses "unset = **windowed**").
- [ ] Semantics match the implementation contract exactly:
      `ABPOOL_OWNER`: ANY non-empty value (not truthy parsing — `ABPOOL_OWNER=false` is
      still caller mode); `ABPOOL_LANE`: `^[1-9][0-9]*$` or hard error, no silent fallback.
- [ ] "Never a takeover" / live-foreign-lease hard error stated for `ABPOOL_LANE`.
- [ ] Recommended conventional value `caller` mentioned for `ABPOOL_OWNER`.
- [ ] Forward reference to the "Caller-scoped lanes" subsection (P4.M1.T3.S2 will add it;
      a plain-name mention is fine — the subsection does not exist yet, that's expected).
- [ ] No other section of configuration.md modified (troubleshooting rows, subsections, and
      prose belong to P4.M1.T3.S2 / P4.M1.T4.S3).
- [ ] Existing PRD §2.7 citation at L19 untouched; no new PRD citations added.

## All Needed Context

### Documentation & References

```yaml
- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: THE file to modify. Env-var table header `| Variable | Default | Meaning |` at L16,
       table body L17–L28, `AGENT_BROWSER_POOL_HARNESSES` row is exactly L28 → insert at L29.
  pattern: copy row style of AGENT_BROWSER_POOL_HARNESSES (longest existing row):
       backticked variable name, backticked/`unset = X` default cell, dense meaning cell.
  gotcha: skill reference docs carry NO PRD § citations (docs_map.md §7 style); do not
       "fix" or remove the pre-existing PRD §2.7 cite at L19 — out of scope.

- file: plan/004_de5e94ac127c/P4M1T2S1/PRP.md
  why: the frozen implementation contract this doc must mirror: ABPOOL_OWNER any-non-empty →
       caller mode (raw-string check, NOT truthy); ABPOOL_LANE ^[1-9][0-9]*$ or pool_die
       with raw value, pre-flock, fires on every verb.
  critical: do not document truthy semantics ("set to 1/true") for ABPOOL_OWNER — the
       doc header at L14 defines "Truthy" for other vars; ABPOOL_OWNER deliberately does
       NOT use it. Say "any non-empty value".

- url: (PRD, in-repo) PRD.md §2.11 last two bullets + §2.12
  why: authoritative wording to mirror — "**Caller-scoped owner:** `ABPOOL_OWNER=caller`
       (any value = key ownership on the calling process `$$` instead of the harness
       ancestor)" and "**Explicit lane pin:** `ABPOOL_LANE=<N>` (positive integer; adopt
       free/stale lane N or hard-error on a live foreign lease)".
```

### Current Codebase tree (relevant slice)

```bash
.agents/skills/agent-browser-pool/references/configuration.md  # 147 lines; table L16–L28
```

### Desired Codebase tree

```bash
.agents/skills/agent-browser-pool/references/configuration.md  # +2 table rows (L29–L30), 149 lines
```

### Known Gotchas

```markdown
<!-- CRITICAL: this is a docs-only subtask in a bash repo — validate with NO code execution.
     Read the file, edit the two rows, re-read to confirm placement and Markdown table validity. -->
<!-- GOTCHA: table rows must keep pipe alignment/3-column structure; no blank line between
     L28 and the new rows (a blank line would end the table and render the rows as text). -->
<!-- GOTCHA: ABPOOL_OWNER is NOT truthy — do not reuse the header's "Truthy" definition. -->
<!-- GOTCHA: markdownlint-style line length: existing rows run long (the HARNESSES row ~170
     chars); long single-line rows are the file's convention — do not wrap mid-cell. -->
```

## Implementation Blueprint

### Implementation Tasks

```yaml
Task 1: EDIT .agents/skills/agent-browser-pool/references/configuration.md
  - INSERT exactly two rows immediately after the AGENT_BROWSER_POOL_HARNESSES row (L28):
    | `ABPOOL_OWNER` | unset = harness-ancestor ownership | any non-empty value (recommended: `caller`) → key lane ownership on the calling process itself (`$$`) instead of the harness ancestor → each parallel subprocess gets its own lane, reaped when it exits. See the "Caller-scoped lanes" subsection. The recognized-harness fail-fast does not apply in caller mode |
    | `ABPOOL_LANE` | unset = auto-assign (lowest free lane) | positive integer N → pin lane N: adopt it if free or stale (reaping a stale lease first); a live lease owned by another process → hard error — **never a takeover**. Malformed value (not a positive integer) → hard error at startup, before any lane work. For deterministic assignment ("scraper X always gets lane 3"), not for reaching another agent's lane |
  - NAMING/STYLE: variables in backticks; defaults as `unset = <behavior>`; bold for
    **never a takeover**; imperative/dense voice; no PRD § citations.
  - DEPENDENCIES: wording frozen from P4.M1.T2.S1's contract (any-non-empty owner; strict
    positive-integer lane) — do not invent looser semantics.
  - PRESERVE: everything else in the file byte-identical (L1–L28, L29+ prose, troubleshooting
    matrix, admin CLI section, the PRD §2.7 cite at L19).
```

### Integration Points

```yaml
DOWNSTREAM CONSUMERS:
  - P4.M1.T3.S2: adds the "Caller-scoped lanes" subsection this row name-drops (safe forward
    reference; do not create the subsection here).
  - P4.M1.T4.S3: adds the pin subsection + troubleshooting rows (NOT this subtask).
  - P4.M3.T1.S1: README env-table copies this wording verbatim — keep it self-contained.
  - P4.M3.T1.S2: final audit mirrors README ↔ configuration.md; exactness matters.
```

## Validation Loop

### Level 1: Static checks (docs-only — no execution)

```bash
sed -n '14,32p' .agents/skills/agent-browser-pool/references/configuration.md
# expect: header at L16, HARNESSES row at L28, the two new rows at L29–L30,
# no blank line inside the table, blank line after L30 before "The three that most affect"
grep -c '^| `ABPOOL_' .agents/skills/agent-browser-pool/references/configuration.md   # expect 2
grep -n 'PRD §' .agents/skills/agent-browser-pool/references/configuration.md
# expect: exactly the pre-existing L19 (§2.7) and L34 occurrences — unchanged count
wc -l .agents/skills/agent-browser-pool/references/configuration.md                    # expect 149
git diff .agents/skills/agent-browser-pool/references/configuration.md
# expect: exactly +2 lines, zero deletions/modifications elsewhere
```

### Level 2–4: NOT IN SCOPE
No browsers, no shell execution, no test suite (docs-only; AGENTS.md §1 static rule).

## Final Validation Checklist

- [ ] Two rows added at L29–L30, directly after AGENT_BROWSER_POOL_HARNESSES.
- [ ] ABPOOL_OWNER: any-non-empty semantics, recommended value `caller`, caller/$$ meaning,
      fail-fast exemption, forward ref to "Caller-scoped lanes" subsection.
- [ ] ABPOOL_LANE: positive-integer pin, free/stale adopt, live-foreign hard error
      ("never a takeover"), malformed → startup hard error.
- [ ] Semantics exactly match P4.M1.T2.S1's POOL_OWNER_MODE / POOL_LANE_PIN contract.
- [ ] No truthy-style wording for ABPOOL_OWNER; no PRD § citations added.
- [ ] Nothing else in the file changed (`git diff` = +2 lines only); L19/L34 cites intact.
- [ ] No processes launched, no temp dirs created.

## Anti-Patterns to Avoid

- ❌ Do NOT document `ABPOOL_OWNER` as truthy ("set to 1/true") — any non-empty value counts.
- ❌ Do NOT add the subsections, prose, or troubleshooting rows — those are T3.S2 / T4.S3.
- ❌ Do NOT cite PRD sections in skill docs, and do NOT touch existing citations.
- ❌ Do NOT reorder or reformat the existing table (alignment-only cosmetic churn breaks
     the P4.M3.T1.S2 mirror audit).
- ❌ Do NOT run any code to "verify" — this subtask is read/edit/diff only.

**Confidence Score: 9/10** — two-row docs insert with exact placement, frozen source
wording (PRD §2.11) and a downstream mirror audit; only risk is accidental over-editing,
guarded by the +2-line diff check.