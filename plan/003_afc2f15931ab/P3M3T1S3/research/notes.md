# Research notes — P3.M3.T1.S3: install.sh `--global-skill` help text → README per-harness table (OPTIONAL)

> **Scope:** OPTIONAL 0.5-point polish (delta_prd.md R5 Mode B, item (c) parenthetical:
> "optionally extend `install.sh` help/success text to reference them — NOT required").
> docs_map.md File 5: "No required change … Optional: point `--global-skill` help text /
> success msg at README's new per-harness table. No new flag."
> This subtask MAY be a no-op (mark complete with a note) if deemed too minor.

## 1. INPUT (already exists) — the README per-harness table from P3.M3.T1.S2

P3.M3.T1.S2 is **already implemented** (verified by reading README.md). The root `README.md`
`## Installation` section (L51) now contains a new `### Cross-harness skill installation`
subsection (L83) with:
- an opening paragraph ("The agent skill is cross-harness, installed per-harness …"),
- a 4-row per-harness table (pi / Claude Code / Codex / Antigravity: global dir, project dir,
  follows-symlinks), and
- a Codex caveat blockquote (real directory copy into `~/.codex/skills/`; openai/codex#11314).

**This is the single thing S3 points at.** The exact section name to reference from install.sh
is: `### Cross-harness skill installation` (under `## Installation`).

## 2. install.sh structure (host-verified line map)

File: `install.sh` (~139 lines). Relevant regions:

| Region | Lines | Content |
|---|---|---|
| arg-parse `--global-skill\|--skill)` case | 29–34 | sets `global_skill=1` |
| `--help\|-h)` heredoc | 36–56 | `cat <<'EOF'` … `EOF`; **quoted delimiter ⇒ literal, no expansion**; prints + `exit 0` BEFORE sourcing pool.sh / any action |
| `--global-skill` description in heredoc | 48–50 | the 3-line help block (see §4) |
| Uninstall hint in heredoc | 53–54 | `(add ~/.agents/skills/agent-browser-pool if you used --global-skill)` |
| `source lib/pool.sh` | 79 | (help has already exited before this) |
| `--global-skill` symlink ACTION | 88–95 | `if (( global_skill )); then … ln -sfnv … fi` |
| success message `agent skill:` printf | 117–118 | `if (( global_skill )); then printf '…(global; every project)\n' "$HOME"; fi` |

**Key fact:** the `--global-skill` flag's ONLY behavior is the pi-only symlink into
`~/.agents/skills/` (lines 88–95). It does NOT cover Claude Code / Codex / Antigravity, but the
help text + success message currently give the user ZERO hint of that. That gap is what this
OPTIONAL edit closes with a one-line pointer (no new behavior, no new flag).

## 3. Baseline static validation (run now — pure static, never blocks)

```
$ bash -n install.sh            → rc 0 (clean)
$ shellcheck -s bash install.sh → only SC1091 (info): "Not following lib/pool.sh" — PRE-EXISTING,
                                   unrelated to this change (it's about the sourced lib, not help text).
```
So the validation gate for S3 is: `bash -n install.sh` rc 0 + `shellcheck` introduces NO NEW
finding beyond the pre-existing SC1091 info.

## 4. The two edit regions (exact current text)

### Region A — help heredoc `--global-skill` description (L48–50, UNIQUE in file)
```
  --global-skill  Also symlink the agent skill into ~/.agents/skills/, so pi sessions in
                  ANY project discover it (default: project-scoped — discovered only inside
                  this repo).
```
Continuation indent = **18 spaces** (aligns under "  --global-skill  "). The block is inside a
`cat <<'EOF'` (quoted) heredoc ⇒ added text is **literal**, no `$`/backtick expansion. Safe.

### Region B — success message `agent skill:` printf (L117, UNIQUE in file)
```
    printf '  agent skill:  %s/.agents/skills/agent-browser-pool (global; every project)\n' "$HOME"
```
Inside `if (( global_skill )); then … fi` (L117–118). Continuation indent = **16 spaces**
(aligns under "  agent skill:  "). A plain `printf '…\n'` string literal is the safe addition
(no `%s` ⇒ no format-string hazard, no SC2059).

## 5. Proposed pointer wording (recommended edit)

Both pointers reference the README section by its EXACT heading `Cross-harness skill
installation` (verified present at README L83) and filename `README.md`. ASCII-only in the
printf (Region B) to avoid any encoding edge case; Region A keeps the existing em-dash style.

- **Region A (help):** append 2 continuation lines after "this repo).":
  ```
                  this repo). Covers pi only; for other harnesses (claude/codex/agy) see
                  README.md "Cross-harness skill installation" (per-harness install).
  ```
- **Region B (success):** add one printf line after the existing `agent skill:` line:
  ```bash
      printf '                (pi only; other harnesses see README.md "Cross-harness skill installation")\n'
  ```

## 6. The no-op option (contractually allowed)

The work-item description + docs_map File 5 + delta_prd.md R5 all state this is OPTIONAL and
"may be a no-op (mark complete with a note)." If the team judges the pointer too minor:
- leave install.sh 100% unchanged;
- `bash -n install.sh` trivially rc 0;
- record a one-line completion note ("no-op: deemed too minor; README §Installation already
  documents per-harness install"). Both paths are valid. The PRP makes the edit the PRIMARY
  path (genuine usability value, near-zero risk) and documents the no-op as the fallback.

## 7. Scope discipline / sibling coordination

- **Only `install.sh` is edited** (the sole file in scope). README.md is the INPUT (already done
  by S2) — NOT touched. lib/pool.sh, configuration.md, SKILL.md, PRD.md, tasks.json, .gitignore,
  any test file: untouched.
- **NO new flag, NO new behavior.** The edit only adds printed TEXT (2 help lines + 1 printf).
  The symlink action (L88–95) is unchanged; `--global-skill` still only symlinks into pi's
  `~/.agents/skills/`.
- **AGENTS.md §1:** PLANNING = static-only (`bash -n`, `shellcheck`, read). I did not boot
  Chrome, run the suite, or launch any daemon. `./install.sh --help` (a benign print+exit-0 that
  runs before `source`/symlink/doctor) is safe for the IMPLEMENTER to run as an optional check,
  but is NOT required — the primary gates are static.
