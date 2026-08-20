# PRP: configuration.md pin subsection + troubleshooting rows; SKILL.md pitfalls/reference; skill README

## Goal

**Feature Goal**: Complete the Mode A (skill-level) documentation for lane pinning (`ABPOOL_LANE`, R4) and the already-shipped caller mode, so the skill docs fully describe both owner modes plus the pin, with quoted error texts that are EXACT mirrors of the implemented `pool_die` strings.

**Deliverable**: Doc-only edits to three files in `.agents/skills/agent-browser-pool/`:
1. `references/configuration.md` — new `### Lane pinning (ABPOOL_LANE)` subsection after the Caller-scoped subsection + 3 new troubleshooting-matrix rows.
2. `SKILL.md` — one new §4 pitfall bullet + one §5 Reference sentence extension.
3. `README.md` — one new "What it covers" bullet.

**Success Definition**: All three docs describe the pin and both owner modes; every quoted die string matches the implemented string verbatim; no PRD § citations added; `bash -n`/`shellcheck` still clean (no code touched); zero behavioral changes.

## Why

The pin behavior (P4.M1.T4.S1/S2) and its config parsing (P4.M1.T2.S1) are implemented, and the caller-mode docs (P4.M1.T3.S2) exist, but nothing documents *pin semantics* at the skill level. P4.M3.T1.S2 audits that doc-quoted error texts mirror the implemented strings exactly, and P4.M3.T1.S1 reuses this wording for the top-level README — this subtask is the source of that wording.

## What

Doc-only changes; **no code changes whatsoever**.

### Success Criteria

- [ ] `configuration.md` has a "Lane pinning (ABPOOL_LANE)" subsection immediately after the "Caller-scoped lanes (orchestrator mode)" subsection, covering: free/stale→take (stale: reap-then-take, no orphan adoption), live-mine→idempotent reuse, live-foreign→hard error (never a takeover, never waits/force-reaps), already-holds-another-lane→hard error, malformed→pre-flock hard error at startup, works in both owner modes, pinned lanes obey the same reaping rules.
- [ ] Exactly 3 new troubleshooting-matrix rows in `configuration.md` (pinned live-foreign conflict; malformed `ABPOOL_LANE`; caller-mode parent dead/reparented), quoting the exact implemented die texts.
- [ ] `SKILL.md` §4 gains one `- **"quoted complaint"** …` bullet about live-foreign pin failing fast; §5 Reference paragraph mentions `ABPOOL_LANE`.
- [ ] `README.md` gains a 4th "What it covers" bullet covering orchestrator mode + pin.
- [ ] No PRD § references added anywhere in the skill docs.

## All Needed Context

### Context Completeness Check

An agent with no prior knowledge of this repo can do this: all target files, exact insertion anchors (by content, since line numbers drift), exact die strings, and style rules are below. It is a pure Markdown editing task.

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/P4M1T4S3/research/die_strings_and_anchors.md
  why: The five exact implemented die/diagnostic strings + current file anchors + style rules. THE contract for this task.
  critical: Quote die strings verbatim, including/excluding the `agent-browser-pool: ` prefix exactly as implemented.

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: Primary edit target. Env table already has ABPOOL_OWNER (L29) and ABPOOL_LANE (L30) rows from P4.M1.T2.S2 — do NOT duplicate; the new subsection is the narrative expansion of the ABPOOL_LANE row.
  pattern: Mirror the structure/tone of the existing `### Caller-scoped lanes (orchestrator mode)` subsection (L47–~74): bold lead-in bullets, a "Typical usage" code block, a "Default path unchanged" note.
  gotcha: Insert the new subsection AFTER the caller-scoped code block + closing paragraph, BEFORE the `## Command dispatch: pool verbs vs. driving` heading.

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: Edit target §4/§5. Pitfall bullet format is `- **"quoted complaint"** explanation…` (see the four existing bullets under `## 4. Common pitfalls`, L143+).
  gotcha: Add the bullet after the last existing pitfall ("Don't confuse `close` with release."); keep §5 an extension of the existing final paragraph (ends "…subsection for parallel-worker usage."), not a new paragraph.

- file: .agents/skills/agent-browser-pool/README.md
  why: Edit target; add one bullet after the third "## What it covers" bullet ("**Pitfalls:** …").
  gotcha: One bullet only — orchestrator mode + pin mention combined; keep the existing bullet style (`- **Label:** text`).

- file: plan/004_de5e94ac127c/P4M1T4S1/PRP.md
  why: Contract for the pin branch: the 5 cases + exact die strings (Task 3 of that PRP).
- file: plan/004_de5e94ac127c/P4M1T4S2/PRP.md
  why: Contract for the wrapper die text and the "no exhaustion fallback / never waits" rule.
- file: plan/004_de5e94ac127c/P4M1T3S1/PRP.md
  why: Contract for the caller-mode dead-parent die string.
- file: plan/004_de5e94ac127c/P4M1T3S2/PRP.md
  why: What the caller-scoped subsection already covers — do not duplicate; your pin subsection must sit after it and may reference it by name ("Caller-scoped lanes" subsection).
```

### Current Codebase tree (skill dir)

```bash
.agents/skills/agent-browser-pool/
├── README.md                     # 46 lines; "## What it covers" 3 bullets at L10–L18
├── SKILL.md                      # 167 lines; §4 pitfalls L143–~156; §5 Reference L162–167
└── references/
    └── configuration.md          # 182 lines; caller subsection L47–~74; matrix L153–165
```

### Known Gotchas

```text
# Line numbers in the work-item contract (L118–L130, L133–L150, etc.) are STALE estimates.
# Anchor every insertion by CONTENT, not line number (exact anchors in the research file).
# The env-table rows for ABPOOL_OWNER/ABPOOL_LANE already exist — adding them again duplicates.
# Die-string mirroring: keep the `agent-browser-pool: ` prefix where the implementation has one
#   (malformed-value die, wrapper "pinned lane unavailable", caller dead-parent) and omit it where
#   it doesn't (the two critical-section diagnostics from P4.M1.T4.S1).
# No PRD § citations in any skill doc (SKILL.md / configuration.md / README.md).
# NO code edits: lib/pool.sh, bin/*, test/* are out of scope and must remain untouched.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT .agents/skills/agent-browser-pool/references/configuration.md — pin subsection
  - INSERT `### Lane pinning (ABPOOL_LANE)` immediately AFTER the Caller-scoped subsection
    (after its closing paragraph, before `## Command dispatch: pool verbs vs. driving`).
  - CONTENT (narrative expansion of the existing ABPOOL_LANE env-table row; mirror the
    caller subsection's bullet style; no § citations):
    * What the pin does: skip auto-assignment; use lane N directly.
    * Semantics bullets:
      - free → claim; stale → reap the stale lease first, then claim (even a
        responsive orphan Chrome is NOT adopted under a pin — deterministic fresh state).
      - live lease owned by you → idempotent reuse (same lane, same browser).
      - live lease owned by another process → hard error, quoting verbatim:
        `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`
        plus the wrapper terminal line: `agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)`
        Emphasize: never a takeover, never waits (no AGENT_BROWSER_POOL_WAIT), never force-reaps.
      - you already hold a different live lane → hard error, quoting verbatim:
        `owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE`
      - malformed value (not a positive integer; leading zeros, 0, negatives, non-numeric) → hard error
        at startup before any lane work, quoting verbatim:
        `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw value>'`
    * Works in both owner modes (harness-ancestor default and ABPOOL_OWNER=caller);
      pinned lanes obey the same reaping rules (owner death → stale → reaped).
    * Purpose: deterministic assignment ("scraper X always gets lane 3"), NOT reaching
      another live agent's lane — the live-foreign error preserves cross-agent isolation.
    * Typical usage snippet, e.g.:
      ABPOOL_LANE=3 ABPOOL_OWNER=caller ./scrape.sh   # worker pinned to lane 3

Task 2: EDIT .agents/skills/agent-browser-pool/references/configuration.md — 3 matrix rows
  - APPEND after the LAST row of `## Troubleshooting matrix` (the `doctor` WARN row),
    keeping the 3-col format `| Symptom | Likely cause | Fix / response |`:
    1. | Pinned-lane call dies: "pinned lane N is held by a live owner …" | `ABPOOL_LANE=N` but lane N has a live lease owned by another process | By design — a pinned lane is never a takeover and never waits; unset `ABPOOL_LANE`, pick a free lane, or wait for that owner to release |
    2. | Pool dies at startup: "ABPOOL_LANE must be a positive integer, got: '<raw>'" | `ABPOOL_LANE` is malformed (non-numeric, 0, negative, leading zeros) | Fix the value to a positive integer or unset it (auto-assign) |
    3. | Caller-mode call dies: "ABPOOL_OWNER=caller requires a live parent process …" | The invoking subprocess's parent is dead/reparented (an instantly-stale owner) | Invoke `agent-browser-pool` as a child of the long-lived orchestrator process |
  - Wording of the quoted fragments inside the rows must match the implemented die texts
    verbatim (research file §"die strings").

Task 3: EDIT .agents/skills/agent-browser-pool/SKILL.md — §4 bullet + §5 extension
  - APPEND after the last pitfall bullet in `## 4. Common pitfalls`:
    `- **"ABPOOL_LANE is set but the pool errors: the pinned lane is in use."** By design — a pinned lane is never a takeover: a live foreign lease on lane N fails fast (no wait, no force-reap). Unset ABPOOL_LANE, choose a free lane, or wait for that owner to release.`
  - EXTEND the §5 Reference paragraph's final sentence (currently ends "…subsection for
    parallel-worker usage.") with: " and the **lane pinning (ABPOOL_LANE)** subsection for
    deterministic lane assignment."

Task 4: EDIT .agents/skills/agent-browser-pool/README.md — 4th bullet
  - APPEND after the third bullet in "## What it covers":
    `- **Orchestrator mode + lane pinning:** set `ABPOOL_OWNER=caller` per subprocess for one
    lane per parallel worker (auto-reaped on exit), and optionally `ABPOOL_LANE=<N>` for
    deterministic assignment — a pinned lane adopts only free/stale lanes and hard-errors on
    a live foreign lease (never a takeover).`
  - Keep to the existing single-bullet density; no § citations.

Task 5: VERIFY
  - Re-read each edited region; grep for accidental "PRD §"/"§2." citations added to skill docs.
  - Confirm no source files touched: `git status` shows only the three doc files (+ nothing under lib/, bin/, test/).
```

### Implementation Patterns & Key Details

```markdown
<!-- Subsection skeleton (Task 1) -->
### Lane pinning (ABPOOL_LANE)

Optional deterministic assignment... skip auto-assignment, use lane N directly.

- **Free or stale lane → take it.** (stale: reap the lease first; a responsive orphan
  Chrome is not adopted under a pin)
- **Live, owned by you → idempotent reuse.**
- **Live, owned by another process → hard error, never a takeover.**
  `pinned lane ...` (exact string) — the wrapper adds
  `agent-browser-pool: ABPOOL_LANE=...: pinned lane unavailable (see the error above)`.
  No wait, no force-reap.
- **You already hold a different live lane → hard error** (exact string).
- **Malformed value → hard error at startup**, before any lane work:
  `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw value>'`
- Works in both owner modes; pinned lanes obey the same reaping rules.

Typical usage: ...
```

### Integration Points

```yaml
DOCS:
  - .agents/skills/agent-browser-pool/references/configuration.md (subsection + 3 rows)
  - .agents/skills/agent-browser-pool/SKILL.md (§4 bullet, §5 sentence extension)
  - .agents/skills/agent-browser-pool/README.md (1 bullet)
CODE: none (read-only for this task)
```

## Validation Loop

### Level 1: Static (docs are the artifact)

```bash
git status --porcelain   # ONLY the three skill doc files modified
grep -rn "§" .agents/skills/agent-browser-pool/ | grep -v "references/" # expect none added in edited regions (existing docs already avoid § citations; new text must not introduce any)
```

### Level 2: Die-string mirror check (the P4.M3.T1.S2 audit pre-pass)

```bash
# For each quoted string in the docs, diff against the implemented strings in lib/pool.sh:
grep -n "must be a positive integer" lib/pool.sh
grep -n "is held by a live owner" lib/pool.sh
grep -n "one-lane-per-owner" lib/pool.sh
grep -n "pinned lane unavailable" lib/pool.sh
grep -n "requires a live parent process" lib/pool.sh
# Then read each doc quote next to its code string and confirm VERBATIM match
# (allowing only that shell variable names like $POOL_LANE_PIN stand in for runtime values).
# NOTE: S1/S2 implementation may still be in flight; if a string is not yet in lib/pool.sh,
# treat the PRP-recorded contract string (research file) as authoritative and note the
# pending-mirror in the subtask output for P4.M3.T1.S2 to re-audit.
```

### Level 3: Structural checks

```bash
# configuration.md: pin subsection after caller subsection, before Command dispatch heading
grep -n "^### \|^## " .agents/skills/agent-browser-pool/references/configuration.md
# matrix still well-formed: every new row has exactly 3 columns (2 unescaped pipes inside → count colons)
awk '/## Troubleshooting/,/## Admin CLI/' .agents/skills/agent-browser-pool/references/configuration.md | grep -c '^|'  # grew by exactly 3
# SKILL.md: bullet count in §4 grew by 1; §5 paragraph extended (still one paragraph)
# README.md: 4 bullets under "## What it covers"
grep -c '^- ' .agents/skills/agent-browser-pool/README.md
```

### Level 4: Markdown render sanity

```bash
# Render check (any available: glow, mdcat, or just read) — confirm no broken tables/code fences:
grep -c '```' .agents/skills/agent-browser-pool/references/configuration.md   # even number (fences balanced)
```

## Final Validation Checklist

- [ ] Pin subsection present in configuration.md after the Caller-scoped subsection, covering all 5 semantic cases + both-owner-modes + same-reaping-rules + purpose.
- [ ] Exactly 3 new troubleshooting rows; quoted texts verbatim mirrors of implemented strings.
- [ ] SKILL.md §4 pin bullet in `- **"quoted complaint"** …` format; §5 sentence extended with ABPOOL_LANE mention.
- [ ] README.md 4th bullet added (orchestrator mode + pin).
- [ ] No PRD § citations added to skill docs.
- [ ] `git status` shows ONLY the three doc files changed; lib/, bin/, test/ untouched.
- [ ] Any strings not yet present in lib/pool.sh (S1/S2 in flight) flagged for P4.M3.T1.S2 re-audit.

## Anti-Patterns to Avoid

- ❌ Don't duplicate the env-table rows (they already exist from P4.M1.T2.S2).
- ❌ Don't paraphrase die strings — the audit (P4.M3.T1.S2) requires exact mirrors.
- ❌ Don't add PRD section citations in skill docs.
- ❌ Don't touch any code file.
- ❌ Don't anchor edits to stale line numbers — anchor by content.

**Confidence Score: 9/10** (pure doc task with exact contracts recorded; only residual risk is S1/S2 implementation drift on die-string wording, handled by the Level-2 note).