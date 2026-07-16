# Research Notes — P3.M3.T1.S2 (README §2.17 cross-harness skill-install section)

**Item:** Add a NEW `###` subsection to the README `## Installation` section (after the existing
`See [PRD.md §2.17]…` pointer, before `## Usage (for agents)`): a cross-harness paragraph +
4-row per-harness skills-dir table + Codex symlink caveat blockquote.
**Type:** Docs-only (Mode B changeset-level). **One file: `README.md` (root).**
**Source of truth:** PRD §2.17 (verbatim text supplied in the work-item's `selected_prd_content`).

---

## 1. Exact insertion point (re-derived, host-verified)

Current README (host-verified line numbers — but **match on TEXT, not line numbers**; sibling
landings shift them):

```
75: **Uninstall:** remove the symlink(s) …
…
81: See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).
82: (blank)
83: ## Usage (for agents)
```

- **Insert AFTER line 81** (the `See [PRD.md §2.17]…` pointer) **and BEFORE line 83**
  (`## Usage (for agents)`). Concretely: the new `###` subsection goes on the blank line 82
  position.
- **Both anchors are UNIQUE** in README (host-verified: `grep -c` = 1 for each):
  - `See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).`
  - `## Usage (for agents)`
  → a single `edit` call with these two lines as the bridge is safe and idempotent.

### Edit strategy (robust to sibling S1 landing before/after this item)
- `oldText` = the L81 pointer + blank line + the `## Usage (for agents)` heading (3 physical lines).
- `newText` = the L81 pointer + blank line + **NEW `### Cross-harness skill installation`
  subsection (paragraph + table + caveat)** + blank line + the `## Usage (for agents)` heading.
- This is a pure INSERT between two unique anchors; nothing in the existing Installation body is
  rewritten or displaced.

---

## 2. The content to insert (verbatim from PRD §2.17 — the source of truth)

A `###` heading is ADDED for README navigability (PRD §2.17 has no sub-heading; it's just a
paragraph). Everything else is reproduced **byte-for-byte** from the PRD table + caveat (the
`selected_prd_content` h3.21 block).

```
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
```

### Faithfulness decisions
- **Table separator format:** PRD uses the WIDE form (`| ----- |`). The README's only existing
  pipe table (env-var) uses the COMPACT form (`|---|---|---|`). **Both render identically on
  GitHub.** Reproduce the PRD's WIDE form verbatim — the PRD is the source of truth, and the
  implementer must not "tidy" it (risk of breaking column alignment). Documented in the PRP.
- **`openai/codex#11314` is kept PLAIN** (not a `[link](url)`) to match the PRD source-of-truth
  exactly. The README has **no existing per-issue GitHub link precedent** (host-verified:
  `grep -nE 'github\.com/.+/issues/|#[0-9]{3,}' README.md` = empty). Full verified URL for
  reference (do NOT inline in README): `https://github.com/openai/codex/issues/11314`.
- **Harness names** in column 1 are PLAIN text (no backticks): `pi`, `Claude Code`, `Codex`,
  `Antigravity (agy/IDE)` — exactly as the PRD table. Paths in cols 2–3 use backticks.
- **`Antigravity → "verify"`** is intentional (unconfirmed symlink-following). Keep as-is —
  faithful to PRD; do NOT upgrade to yes/no.
- **Heading wording:** `### Cross-harness skill installation` (an `h3` under `## Installation`,
  matching the README convention of `h3` subsections under `## Admin commands` / `## Troubleshooting`).

---

## 3. Load-bearing fact verification (external + local)

### (a) openai/codex#11314 — CONFIRMED REAL & as described
- **Title:** "Codex CLI doesn't load skills from `.agents/skills` when it is a symlink …"
- **URL:** https://github.com/openai/codex/issues/11314
- **Body:** "When `.agents/skills` is a symlink, no skills are discovered. Replacing the symlink
  with a real directory makes the skills appear."
- → The headline Codex caveat is accurate. The README's "real directory copy" guidance is correct.

### (b) Reinforcing evidence — openai/codex#17344
- **Title:** "Bug: user-installed skills under `~/.codex/skills` are skipped …"
- **Body:** Codex skips valid user skills under `~/.codex/skills/<slug>/SKILL.md` **when the
  `SKILL.md` file itself is a symlink**.
- → Corroborates the README guidance even more strongly: for Codex the *whole skill directory*
  must be a real copy (not a symlinked dir, and not a dir of symlinked files). This is why the
  caveat says "real directory copy into `~/.codex/skills/`" rather than "symlink". Documented as
  a gotcha in the PRP (the implementer should not soften "real directory copy" to "symlink").

### (c) pi skill dirs — CONFIRMED locally
- `~/.pi/agent/skills/` exists (drwxr-xr-x), contains `agent-browser`, `mdsel`. ✅ matches table.
- `.agents/skills/agent-browser-pool/` exists (project-scoped, this repo). ✅ matches table.
- (pi runtime docs + system skill paths also confirm `~/.pi/agent/skills/` and `~/.agents/skills/`.)

### (d) Claude Code / Antigravity dirs
- Not host-verifiable here (not installed), but the PRD §2.17 table (Decision O9, "Ready to
  build") is the authoritative source. Reproduced verbatim. `~/.claude/skills/` + `.claude/skills/`
  (follows symlinks: yes) and `~/.antigravity/skills/` + `.antigravity/skills/` (verify) per PRD.

---

## 4. Sibling coordination analysis (CRITICAL — parallel execution with S1)

| Aspect | S1 (P3.M3.T1.S1) | This item (S2) |
|---|---|---|
| File | `README.md` (root) | `README.md` (root) — SAME FILE |
| Edit regions | L16, L86, L101–106, L151, L172, L248, L278, L290, L301/304, L318–330 | **L81→L83 boundary ONLY** (Installation tail → Usage head) |
| Edit type | 1 table-row INSERT + 16 phrasing substitutions (in-place) | 1 pure INSERT of a new `###` subsection between two unique anchors |
| Text overlap | NONE in L51–82 (Installation body) or the `## Usage (for agents)` heading | NONE in S1's regions (all are L86+ inside Usage, or L248+ in Config) |

**Conclusion: ZERO textual conflict.** S1 never touches lines 51–82 nor the `## Usage` heading.
This item never touches S1's regions. The only hazard is **line-number drift**, which is fully
neutralized by anchoring the edit on the two UNIQUE text strings (not line numbers). Landing
order is irrelevant. No lock/coordination mechanism needed — both edits commute.

**Boundary discipline (what this item MUST NOT do — that's S1's / others' scope):**
- Do NOT add the `AGENT_BROWSER_POOL_HARNESSES` env-var table row (S1's row-1 edit).
- Do NOT generalize any `pi ancestor` / `owning pi process` phrasing (S1's rows 2–16).
- Do NOT touch the existing pi `--global-skill` opt-in paragraph (README L67–73) — it stays as
  the pi path; the new subsection COMPLEMENTSS it, does not displace it.
- Do NOT touch `install.sh` (sibling S3-doc, P3.M3.T1.S3 — optional help-text tweak).
- Do NOT touch `lib/pool.sh`, `configuration.md`, `SKILL.md`, any test file, `PRD.md`, `tasks.json`.

---

## 5. Constraints recap (from AGENTS.md + item contract)
- **AGENTS.md §1:** PLANNING deliverable → static-only validation. Do NOT boot Chrome, run the
  suite, or launch any daemon. Docs-only → trivially satisfied (nothing to execute).
- **AGENTS.md §5:** `README.md` is NOT in the read-only list → editable. `PRD.md`, `tasks.json`,
  `.gitignore`, `prd_snapshot.md` ARE read-only → do not touch.
- **Output scope:** write ONLY to `README.md`. `git diff --stat` must show exactly one file.
- **No markdownlint on PATH** → validation is grep + visual + git-diff (all static). Do NOT
  install tooling.

---

## 6. Validation design (static, runnable here)
1. New `### Cross-harness skill installation` heading present exactly once.
2. Per-harness table: 4 data rows (pi, Claude Code, Codex, Antigravity) + header + separator;
   each row has exactly 5 pipes (4 cols). Codex row contains `**no — openai/codex#11314**`.
3. Codex caveat blockquote present (`> **Codex caveat:**` …).
4. PRE-existing content UNCHANGED: `See [PRD.md §2.17]…` pointer (L81) still present once; pi
   `--global-skill` opt-in paragraph (`**The agent skill is opt-in.**`) still present once;
   `## Usage (for agents)` heading still present exactly once.
5. `git diff --stat` → exactly `README.md`.
6. README h-heading structure intact: a new `### ` under `## Installation` (consistent with the
   `### ` subsections already under `## Admin commands` and `## Troubleshooting`).
