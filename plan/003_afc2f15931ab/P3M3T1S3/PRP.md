# PRP — P3.M3.T1.S3: Update install.sh `--global-skill` help text to point at README per-harness table (OPTIONAL)

**Work item:** P3.M3.T1.S3 (0.5 points) — parent P3.M3.T1 (Sync changeset-level documentation),
milestone P3.M3 (Sync changeset-level documentation). PRD §2.17 (Install — per-harness skills-dir
table + Codex caveat). Decision O9 (Multi-harness owner resolution). delta_prd.md **R5 Mode B,
item (c) parenthetical**: *"optionally extend `install.sh` help/success text to reference them —
NOT required."* docs_map.md **File 5** (MODE B, OPTIONAL): *"No required change … Optional: point
`--global-skill` help text / success msg at README's new per-harness table. No new flag."*
**Type:** OPTIONAL documentation/help-text polish. **One file: `install.sh`.** No new behavior,
no new flag, no code/test/config/API change. **May be a no-op** (see §No-op option).
**Phase constraint:** PLANNING deliverable; AGENTS.md §1 static-only validation (the change is two
printed-text pointers; primary gates are `bash -n` + `shellcheck` — nothing to execute that could
launch Chrome/daemon/suite).

---

## Goal

**Feature Goal:** Make `install.sh`'s `--global-skill` opt-in self-documenting about its scope:
today the `--global-skill` flag (and its success message) only ever symlinks the skill into **pi's**
`~/.agents/skills/`, but the help/success text gives the user **zero hint** that Claude Code, Codex,
and Antigravity need a different per-harness skills dir (and that Codex can't use a symlink at all).
Add a **one-line pointer** (help heredoc) and a **one-line pointer** (success message) directing the
user to the README's `### Cross-harness skill installation` table for the other harnesses.

**Deliverable:** TWO small text insertions in **`install.sh` only** — (A) 2 continuation lines
appended to the `--global-skill` description inside the `--help` heredoc; (B) 1 `printf` line added
inside the existing `if (( global_skill )); then … fi` success block. Both point at README.md's
`Cross-harness skill installation` section. **No new flag. No new behavior. No new required action.**
The symlink action (L88–95) is unchanged.

**Success Definition:**
1. `install.sh --help` prints, within the `--global-skill` description, a one-line pointer to
   README.md's `Cross-harness skill installation` table noting `--global-skill` covers pi only.
2. A successful `--global-skill` run's success banner prints one extra pointer line (same reference)
   right after the existing `agent skill:` line.
3. `bash -n install.sh` exits 0 (syntax clean).
4. `shellcheck -s bash install.sh` introduces **no new** finding beyond the pre-existing SC1091
   info ("Not following lib/pool.sh").
5. `git diff --stat` touches **only** `install.sh`.
6. (Acceptable alternative — see No-op option) install.sh left 100% unchanged + a completion note.

---

## Why

- The `--global-skill` flag's **only** effect is the pi-only symlink into `~/.agents/skills/` (L88–95).
  With Decision O9 the pool now supports Claude Code / Codex / AGY / Antigravity as owners, and the
  README (via sibling P3.M3.T1.S2) now documents a per-harness skills-dir table + a Codex symlink
  caveat. But a user who runs `./install.sh --global-skill` and reads its help/success output gets
  **no signal** that the other harnesses need a different dir (and that Codex needs a real copy, not
  a symlink). This optional polish closes that one-directional gap with a pointer.
- delta_prd.md R5 explicitly allows it ("optionally extend `install.sh` help/success text … NOT
  required"); docs_map.md File 5 marks it MODE B / OPTIONAL. Near-zero risk: pure printed text.
- This is the last changeset-level doc sync of milestone P3.M3.

---

## What

### User-visible behavior
A user running `./install.sh --help` now sees, in the `--global-skill` entry, that it covers pi
only and that other harnesses are documented in README's `Cross-harness skill installation` table.
A user running `./install.sh --global-skill` successfully sees one extra pointer line in the banner
after `agent skill:`. **Nothing else changes** — no new flag, no changed symlink target, no changed
exit codes, no new required action.

### Technical change (confined to `install.sh`)
Exactly **ONE `edit` call with TWO `edits[]` entries** (both pure INSERT, both anchor on
host-verified-UNIQUE text):
- (A) append 2 continuation lines to the `--global-skill` description in the `--help` heredoc;
- (B) add 1 `printf` line inside the existing `if (( global_skill )); then … fi` success block.

No structural change; no flag/arg-parse/case/exit-flow change; the symlink action (L88–95) is
untouched.

### Success Criteria
- [ ] `--global-skill` help description (heredoc) contains a pointer to README.md
      `Cross-harness skill installation`, noting pi-only coverage, exactly once.
- [ ] Success banner prints exactly one extra pointer line after `agent skill:` (only when
      `--global-skill` ran), referencing the same README section.
- [ ] `bash -n install.sh` rc 0.
- [ ] `shellcheck -s bash install.sh` → no NEW finding beyond pre-existing SC1091 info.
- [ ] Only `install.sh` modified (`git diff --stat`).
- [ ] No new flag added; `--global-skill` symlink action (L88–95) byte-identical to before.

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact two `edit` entries (unique text anchors
+ the verbatim insertion text), the host-verified line map + uniqueness, the heredoc-is-quoted fact
(⇒ literal text, no expansion), the printf-no-`%s` fact (⇒ no format-string hazard), the exact
README section name to point at (`Cross-harness skill installation`, confirmed present at README
L83), the static-only validation commands + their verified baselines, and the explicit no-op
fallback. Nothing else required._

### Documentation & References
```yaml
- file: install.sh  (THE ONLY FILE EDITED — not in the AGENTS.md §5 read-only list)
  why: TARGET FILE. Two edit regions:
    (A) --help heredoc, --global-skill description (L48–50). Inside `cat <<'EOF'` (QUOTED delimiter
        ⇒ literal text, no $ / backtick expansion) ⇒ safe to add plain prose.
    (B) success block `if (( global_skill )); then … fi` (L117–118), the `agent skill:` printf.
        A plain `printf 'literal\n'` with NO %s ⇒ no SC2059 format-string hazard.
  pattern: existing help lines use a 18-space continuation indent (aligns under "  --global-skill  ");
           existing success lines use a 16-space continuation indent (aligns under "  agent skill:  ").
           MATCH THESE INDENTS so the output stays column-aligned.
  critical: The `--help)` case does `cat … ; exit 0` INSIDE the top arg-parse loop, BEFORE
            `source lib/pool.sh` (L79) and before any symlink/doctor action. So `./install.sh --help`
            is a benign print+exit — it cannot launch Chrome/touch state. It is safe for the
            implementer to run as an optional visual check, but NOT required (gates are static).

- file: README.md  (INPUT, READ ONLY — already edited by sibling P3.M3.T1.S2, which is DONE)
  why: The section to point at. `## Installation` (L51) contains `### Cross-harness skill
       installation` (L83) — a paragraph + 4-row per-harness table (pi / Claude Code / Codex /
       Antigravity) + a Codex caveat blockquote. The pointer text references this section by its
       EXACT heading: `Cross-harness skill installation`.
  critical: Do NOT edit README.md (S2 owns it and is complete). Do NOT restate the table inside
            install.sh — install.sh only POINTS at it (one line each), keeping help text concise.

- file: PRD.md §2.17  (READ ONLY — AGENTS.md §5)
  why: Source of truth for the per-harness table + Codex caveat that README (and thus this pointer)
       references. Confirms `--global-skill` is the pi `~/.agents/skills/` symlink path only.
  critical: Do NOT edit PRD.md. The pointer wording is NOT lifted verbatim from the PRD (it is a
            short human-facing reference); keep it factual and consistent with PRD §2.17 harness
            names (claude/codex/agy comm values).

- file: plan/003_afc2f15931ab/architecture/docs_map.md  (READ ONLY)
  why: File 5 scopes THIS item: "No required change. --global-skill (lines 29–34 arg-parse, 89–95
       symlink action, 117–118 success msg) only ever symlinks into pi's ~/.agents/skills/.
       Optional: point --global-skill help text (L49–51) / success msg at README's new per-harness
       table. No new flag." Cross-file constraints confirm "install.sh gains no new behavior."
  critical: This item is OPTIONAL polish. docs_map File 4 §4a–4d and File 5's "no new behavior" note
            bound the scope: ONLY the two help/success TEXT pointers; do NOT add a flag, do NOT change
            the symlink action, do NOT touch any other file.

- file: plan/003_afc2f15931ab/delta_prd.md  (READ ONLY)
  why: R5 Mode B item (c) parenthetical: "optionally extend install.sh help/success text to reference
       them — NOT required." Establishes the OPTIONality + the no-op acceptance.

- file: plan/003_afc2f15931ab/P3M3T1S2/PRP.md  (READ ONLY — the sibling whose OUTPUT is this item's INPUT)
  why: S2 produced the README `### Cross-harness skill installation` subsection (paragraph + table +
       Codex caveat) that this item points at. It is ALREADY LANDED (verified: README L83).
  critical: Assume S2 is complete (it is). This item only REFERENCES its section heading by name; it
            does not depend on S2's exact line numbers (README heading name is stable text).

- file: AGENTS.md  (READ ONLY)
  why: §1 (static-only PLANNING validation — trivially met: text pointers, nothing to run); §2/§3
       (any live run must be isolated+timeout-bounded+reaped; N/A here — the implementer's optional
       `./install.sh --help` is a benign print+exit that runs before sourcing pool.sh); §5
       (README.md is editable but PRD.md/tasks.json/.gitignore/prd_snapshot.md are READ ONLY;
       install.sh is NOT in the read-only list → editable).
```

### Current codebase tree (relevant slice)
```
install.sh                         # TARGET (the only edited file)
README.md                          # INPUT — has ### Cross-harness skill installation (L83); NOT edited
PRD.md                             # §2.17 source of truth (READ ONLY)
plan/003_afc2f15931ab/architecture/docs_map.md   # File 5 scoping (READ ONLY)
plan/003_afc2f15931ab/P3M3T1S2/PRP.md            # sibling CONTRACT (its output is this item's input)
```

### Desired codebase tree (delta)
```
install.sh    # MODIFIED: +2 help-heredoc lines (Region A) +1 success printf line (Region B). No new behavior.
(no new files; no deletions; no other file touched.)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL — the --help heredoc uses a QUOTED delimiter: `cat <<'EOF'` (install.sh L36). Quoted =>
#   NO expansion inside. So a line like "see README.md ..." is printed literally — do NOT add $HOME
#   or backticks to Region A (they would be printed verbatim, not expanded). Region B is a real
#   printf in normal shell context, so it expands normally — but our added line has NO %s and NO $var
#   (pure literal string), so it is format-string-safe (no SC2059).

# CRITICAL — MATCH the continuation indents: Region A continuation lines = 18 spaces (align under
#   "  --global-skill  "); Region B continuation = 16 spaces (align under "  agent skill:  ").
#   Misaligned continuation lines still function but look broken in the printed output.

# CRITICAL — This is OPTIONAL polish and MAY be a no-op (delta_prd.md R5; docs_map File 5). If the
#   team deems it too minor, leave install.sh 100% unchanged, run `bash -n install.sh` (trivially
#   rc 0), and record a one-line completion note. Both the edit path and the no-op path are valid.

# CRITICAL — SCOPE: do NOT add a new flag; do NOT change the --global-skill symlink action (L88–95);
#   do NOT change arg-parse (L29–34) or exit flow. The edit is PRINTED TEXT ONLY. Do NOT edit README.md
#   (S2 owns it, already done), lib/pool.sh, configuration.md, SKILL.md, any test file, PRD.md,
#   tasks.json, or .gitignore.

# shellcheck baseline: the ONLY finding on the current install.sh is SC1091 (info, "Not following
#   lib/pool.sh") — PRE-EXISTING and unrelated. The success gate is "no NEW finding beyond SC1091."
```

---

## Implementation Blueprint

### The single edit (the ENTIRE change — install.sh only)

Re-verify the anchors with the Task-1 grep first (line numbers below are host-verified but harmless
to re-confirm). Both `oldText`s are verbatim-unique in install.sh.

#### `edit` call — two `edits[]` entries

**Edit A — `--global-skill` help description (append 2 continuation lines).**

`oldText` (the existing 3-line description block — UNIQUE in install.sh; verbatim incl. the em-dash `—`):
```
  --global-skill  Also symlink the agent skill into ~/.agents/skills/, so pi sessions in
                  ANY project discover it (default: project-scoped — discovered only inside
                  this repo).
```

`newText` (the same 3 lines + 2 new continuation lines; 18-space indent; ASCII-safe prose):
```
  --global-skill  Also symlink the agent skill into ~/.agents/skills/, so pi sessions in
                  ANY project discover it (default: project-scoped — discovered only inside
                  this repo). Covers pi only; for other harnesses (claude/codex/agy) see
                  README.md "Cross-harness skill installation" (per-harness install).
```

**Edit B — success banner `agent skill:` line (add 1 printf line).**

`oldText` (the existing printf line — UNIQUE in install.sh; verbatim):
```
    printf '  agent skill:  %s/.agents/skills/agent-browser-pool (global; every project)\n' "$HOME"
```

`newText` (the same line + 1 new printf; 16-space indent; pure literal string, NO `%s`, NO `$var`):
```
    printf '  agent skill:  %s/.agents/skills/agent-browser-pool (global; every project)\n' "$HOME"
    printf '                (pi only; other harnesses see README.md "Cross-harness skill installation")\n'
```

> Both pointers reference the README section by its **exact heading** `Cross-harness skill
> installation` (present at README.md L83, under `## Installation`). The harness list in Edit A
> (`claude/codex/agy`) matches the PRD §2.4/§2.11 recognized-harness **comm** values (pi is the one
> `--global-skill` covers, so it is named separately as "Covers pi only").

### Implementation Patterns & Key Details
```bash
# (1) ONE edit call, TWO edits[] entries (A = help heredoc, B = success printf). Both are PURE
#     INSERTs anchored on verbatim-unique text. Do not rewrite the surrounding lines — oldText for
#     each edit is the EXISTING text, newText = that same text + the appended pointer.

# (2) HEREDOC IS QUOTED (`cat <<'EOF'`, L36) => Region A's added lines are printed LITERALLY. Do not
#     put $HOME / backticks / command-substitution in Region A (they'd print verbatim). Region A is
#     pure prose; that's correct and intended.

# (3) REGION B is a real printf in normal shell context. The added line has NO %s and NO $var — it is
#     a pure literal — so it is immune to SC2059 (format-string) warnings. Do NOT add %s there.

# (4) INDENT FIDELITY: Region A continuation = 18 spaces (under "  --global-skill  "); Region B
#     continuation = 16 spaces (under "  agent skill:  "). Copy the exact leading whitespace from
#     the existing continuation line above each insertion so the printed output stays aligned.

# (5) WORDING: both pointers name the README section by its EXACT heading "Cross-harness skill
#     installation" and the filename "README.md". Do NOT paraphrase the heading (a wrong name would
#     make the pointer a dead reference). Do NOT inline the table contents into install.sh (keep
#     help text concise; the README is the source of truth).
```

### Implementation Tasks (ordered)
```yaml
Task 1: RE-VERIFY the two anchors (contract line numbers are host-verified but re-confirm)
  - RUN: grep -n 'Also symlink the agent skill into ~/.agents/skills/, so pi sessions in' install.sh
          # → UNIQUE (currently L48). First line of Edit A oldText.
  - RUN: grep -n "printf '  agent skill:  %s/.agents/skills/agent-browser-pool (global; every project)\\\\n'" install.sh
          # → UNIQUE (currently L117). Edit B oldText.
  - RUN: grep -c 'Cross-harness skill installation' install.sh
          # → expect ZERO hits BEFORE the edit (confirms the pointer is genuinely absent → this item adds it).
  - RUN: grep -c '^### Cross-harness skill installation' README.md
          # → expect 1 (confirms the README target section EXISTS — the input from S2 is present).

Task 2: APPLY the single edit (the `edit` tool, install.sh, TWO edits[] entries — A and B above)
  - Edit A oldText = the 3-line --global-skill description (verbatim, incl. em-dash).
  - Edit A newText = those 3 lines + the 2 new 18-space-indented continuation lines (Blueprint verbatim).
  - Edit B oldText = the single agent-skill printf line (verbatim).
  - Edit B newText = that line + the 1 new 16-space-indented printf line (Blueprint verbatim).
  - PRESERVE: arg-parse (L29–34), the `--help)`/`exit 0` flow, the symlink action (L88–95), every
          other line. Do NOT add a flag. Do NOT change behavior.
  - DO NOT TOUCH: README.md, lib/pool.sh, configuration.md, SKILL.md, any test file, PRD.md,
          tasks.json, .gitignore.

Task 3: STATIC VALIDATE (no suite run — AGENTS.md §1; text-only change, nothing meaningful to execute)
  - RUN the Validation Loop (Level 1–3) below. All must pass before declaring done.
```

### Integration Points
```yaml
UPSTREAM (consumed, READ ONLY):
  - README.md `### Cross-harness skill installation` (sibling P3.M3.T1.S2, ALREADY LANDED) — the
    section both pointers reference by name.
  - PRD.md §2.17 — source of truth for the per-harness dirs / Codex caveat the README table encodes.
DOWNSTREAM: none. install.sh is a leaf installer; its help/success text is human-facing only. No
  config, no routes, no migrations, no code consumes it. No new behavior introduced.
PARALLEL SIBLINGS: P3.M3.T1.S1 (README env-var/phrasing sweep — DONE) and P3.M3.T1.S2 (README
  cross-harness section — DONE) both edit README.md in regions DISJOINT from install.sh. No file
  overlap; no coordination needed. install.sh is solely this item's.
```

---

## Validation Loop

### Level 1: Syntax & lint (run after the edit — static; AGENTS.md §1)
```bash
# (a) Bash syntax check — MUST be rc 0 (never executes anything).
bash -n install.sh && echo "bash -n OK" || echo "bash -n FAILED"

# (b) shellcheck — MUST introduce NO NEW finding beyond the pre-existing SC1091 info.
shellcheck -s bash install.sh
#   baseline (before this change): ONLY "SC1091 (info): Not following: lib/pool.sh …".
#   after this change: expect the SAME (SC1091 info only). Any NEW warning/error (e.g. SC2059 on the
#   new printf, SC2086, indent/whitespace note) → the edit introduced a defect; fix before proceeding.
```
Expected: (a) prints `bash -n OK`; (b) shows only the pre-existing SC1091 info line. If (b) shows a
new finding, READ it — most likely a stray `%s`/`$var` in the Region B printf (remove it; the line is
a pure literal) or an unquoted var (none expected — both insertions are literal text).

### Level 2: Content presence (the two pointers landed, exactly once each)
```bash
# (a) Edit A — help heredoc pointer present exactly once.
grep -c 'Covers pi only; for other harnesses (claude/codex/agy) see' install.sh   # expect 1
grep -c 'README.md "Cross-harness skill installation" (per-harness install)' install.sh   # expect 1

# (b) Edit B — success banner pointer present exactly once.
grep -c '(pi only; other harnesses see README.md "Cross-harness skill installation")' install.sh   # expect 1

# (c) The README target section actually EXISTS (the pointer is not a dead reference).
grep -c '^### Cross-harness skill installation' README.md   # expect 1
```
Expected: every check = 1. If (a)/(b) ≠ 1, the verbatim pointer text was altered — re-apply from the
Blueprint. If (c) ≠ 1, the README input from S2 is missing — STOP (S2 must land first; it already
has on this host, so this is a sanity check).

### Level 3: Scope + no-behavior-change preservation
```bash
# (a) No NEW flag was added: the arg-parse still has exactly the same flag cases.
grep -c -- '--global-skill|--skill)' install.sh   # expect 1 (unchanged)
grep -c -- '--force|-f)' install.sh               # expect 1 (unchanged)
grep -c -- '--help|-h)' install.sh                # expect 1 (unchanged)

# (b) The symlink ACTION (the real behavior) is byte-identical: still only pi's ~/.agents/skills/.
grep -c 'ln -sfnv -- "\$REPO_DIR/.agents/skills/agent-browser-pool" "\$HOME/.agents/skills/agent-browser-pool"' install.sh   # expect 1

# (c) Change scope: ONLY install.sh modified.
git diff --stat                                                          # expect exactly one file: install.sh
git status --short | grep -v 'plan/003' | grep -qE '^.M|^M|^\?\?' && echo "UNEXPECTED CHANGE" || echo "scope OK"
```
Expected: (a) 1/1/1, (b) 1, (c) only install.sh + scope OK. If (a) shows a new case or (b) ≠ 1, the
edit accidentally changed behavior — revert and re-apply text-only. If (c) flags another file, revert
it (scope violation).

### Level 4 (optional, benign) — visual help-output check
```bash
# ./install.sh --help prints the heredoc and exits 0 BEFORE sourcing pool.sh / any action (benign;
# no Chrome, no daemon, no state). Optional sanity check that the new pointer renders + columns align.
timeout 10 ./install.sh --help | grep -A3 -- '--global-skill'
# Expected: the --global-skill block now ends with the 2 new pointer lines; column-aligned; rc 0.
# (AGENTS.md §1/§2: this is a benign print+exit, but if you prefer pure-static validation, Levels 1–3
#  are sufficient and Level 4 may be skipped.)
```

---

## No-op option (contractually allowed)

delta_prd.md R5 ("optionally … NOT required"), docs_map.md File 5 ("No required change … Optional"),
and the work-item description all state this subtask **may be a no-op**. If the team judges the
pointer too minor to be worth the diff:

1. Leave `install.sh` 100% unchanged.
2. Run `bash -n install.sh` (trivially rc 0) as the sole gate.
3. Record a one-line completion note, e.g.:
   *"P3.M3.T1.S3: no-op — install.sh help/success text left unchanged; README §Installation's
   `Cross-harness skill installation` table (S2) already documents per-harness install, so the
   pointer was deemed too minor. `bash -n install.sh` rc 0."*

Both the **edit path** (Levels 1–3, optionally 4) and the **no-op path** are valid completions. The
edit path is the PRIMARY recommendation (genuine usability value at near-zero risk); the no-op path
is the documented fallback.

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1(a): `bash -n install.sh` rc 0 (`bash -n OK`).
- [ ] Level 1(b): `shellcheck -s bash install.sh` → only the pre-existing SC1091 info (no NEW finding).
- [ ] Level 2(a): help-heredoc pointer present exactly once (both grep checks = 1).
- [ ] Level 2(b): success-banner pointer present exactly once.
- [ ] Level 2(c): README `### Cross-harness skill installation` exists (= 1).
- [ ] Level 3(a): arg-parse flag cases unchanged (1/1/1); NO new flag.
- [ ] Level 3(b): symlink action byte-identical (= 1); no behavior change.
- [ ] Level 3(c): `git diff --stat` touches ONLY `install.sh`.
- [ ] (Optional) Level 4: `./install.sh --help` renders the new pointer lines, column-aligned.

### Feature Validation
- [ ] `--global-skill` help description notes pi-only coverage + points at README per-harness table.
- [ ] Success banner (when `--global-skill` ran) prints one extra pointer line to the same section.
- [ ] Both pointers name the README section by its EXACT heading `Cross-harness skill installation`.

### Scope Discipline
- [ ] Only `install.sh` edited; exactly ONE `edit` call with TWO `edits[]` entries (A + B).
- [ ] NO new flag; NO change to arg-parse (L29–34), `--help`/exit flow, or symlink action (L88–95).
- [ ] NO edit to README.md (S2 owns it, done), lib/pool.sh, configuration.md, SKILL.md, any test
      file, PRD.md, tasks.json, .gitignore.
- [ ] No test suite executed; no Chrome booted; no daemon/orphan/temp-dir (text-only change).
- [ ] (If no-op path taken) install.sh unchanged + `bash -n` rc 0 + completion note recorded.

### Documentation Quality
- [ ] install.sh `--global-skill` help is now accurate about its pi-only scope.
- [ ] Pointers are concise (one logical line each) and reference the README by exact section name.
- [ ] No table/caveat content duplicated into install.sh (README remains the single source of truth).

---

## Anti-Patterns to Avoid
- ❌ Don't add a new flag or change the `--global-skill` symlink action — this item is PRINTED TEXT
  ONLY (docs_map File 5: "No new flag"; "install.sh gains no new behavior").
- ❌ Don't put `$HOME` / backticks / command-substitution in Region A — the `--help` heredoc uses a
  QUOTED delimiter (`cat <<'EOF'`), so they'd print verbatim. Region A is pure prose by design.
- ❌ Don't add `%s`/`$var` to the Region B printf — a pure literal string avoids SC2059. (The line
  intentionally has no variables.)
- ❌ Don't misalign the continuation indents — Region A = 18 spaces (under `--global-skill`),
  Region B = 16 spaces (under `agent skill:`). Copy the existing line's leading whitespace.
- ❌ Don't paraphrase the README heading — reference `Cross-harness skill installation` EXACTLY or
  the pointer becomes a dead reference.
- ❌ Don't inline the per-harness table / Codex caveat into install.sh — keep help text concise;
  point at the README (single source of truth). Don't edit README.md (S2 owns it).
- ❌ Don't run the test suite / boot Chrome / install tooling — text-only change; AGENTS.md §1.
  (`./install.sh --help` is an optional benign print+exit, not required.)
- ❌ Don't forget the no-op is valid — if the team deems it too minor, leave install.sh unchanged,
  run `bash -n`, and record a note. Don't force an edit the work item explicitly makes optional.

---

## Confidence Score
**9.5/10.** The entire change is TWO pure-INSERT text pointers in one file, each anchored on
host-verified-UNIQUE text (the 3-line `--global-skill` description; the single `agent skill:` printf).
The two load-bearing facts are confirmed: (1) the `--help` heredoc uses a quoted `<<'EOF'` ⇒ Region A
is literal prose (no expansion pitfall); (2) the README target section `Cross-harness skill
installation` exists (verified at README L83, produced by the already-landed S2). Validation is
static (`bash -n` rc 0 + `shellcheck` no-new-finding + grep presence/scope), all verified runnable
here, with an optional benign `--help` visual check. The contractually-allowed no-op path removes
all residual implementation risk. The −0.5 is residual risk the implementer mis-indents a
continuation line or alters the verbatim pointer text — mitigated by the explicit indent specs and
the Level 2 grep checks that assert byte-for-byte presence.
