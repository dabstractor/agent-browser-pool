# Docs Map — Plan/003 (Multi-Harness Owner Resolution)

Static research map of every DOC file the delta touches. For each file: exact line numbers and
verbatim snippets. Determines Mode A (per-file, ride with work) vs Mode B (changeset-level README).

---

## File 1 — `.agents/skills/agent-browser-pool/references/configuration.md`  [MODE A]

### 1a. Env-var table (lines 16–27) — add `AGENT_BROWSER_POOL_HARNESSES` row after L27
```
16: | Variable | Default | Meaning |
17: |---|---|---|
...
27: | `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = refuse on non-btrfs | truthy → permit ... |
```
Format = 3-column pipe table. New row (mirror README wording):
`| AGENT_BROWSER_POOL_HARNESSES | pi,claude,codex,agy,antigravity | comma-separated comm values treated as valid lane owners; walk matches first ancestor whose comm is in this set. Empty/unset → default (never empty) |`

### 1b. Test-only hooks callout (lines 41–43) — reference only, not edited
### 1c. Dispatch (lines 53–56)
- L53 "resolve the owning `pi` PID" → "resolve the owning recognized-harness PID"
- L54 "no `pi` ancestor" → "no recognized-harness ancestor"
- L54–55 inline `pool_die` quote → mirror R3 message: `"… requires a supported agent harness (pi/claude/codex/agy) …"`

### 1d. Driving-commands (line 72)
- L72 "fails fast without a `pi` ancestor" → "without a recognized-harness ancestor"

### 1e. Acquire lifecycle (line 85) ★ — the key `comm == 'pi'` line
- L81 "under `pi`" → "under a supported harness"
- L85 `resolve owning pi PID (walk ppid → comm == 'pi')` → set-membership wording

### 1f. Release lifecycle (line 101)
- L101 "owning `pi` process exits" → "owning harness process exits"

### 1g. Troubleshooting (line 121) — all three cells generalize
- Cause: "outside `pi` (no pi ancestor → fail-fast)" → "outside a supported harness (no recognized-harness ancestor → fail-fast)"
- Fix: "under `pi`" → "under a supported harness (`pi`/`claude`/`codex`/`agy`)"

### configuration.md edit summary
| Line | Change |
|---|---|
| 27 (after) | ADD `AGENT_BROWSER_POOL_HARNESSES` table row |
| 53, 54, 54-55 | generalize dispatch + mirror R3 message |
| 72 | pi ancestor → recognized-harness ancestor |
| 81, 85 | under `pi` → supported harness; comm=='pi' → set-membership |
| 101 | owning pi process → owning harness process |
| 121 | troubleshooting row generalize |

---

## File 2 — `.agents/skills/agent-browser-pool/SKILL.md`  [MODE A]

### All `pi`/owner mentions
```
20: (your owning `pi` process ...)
36: keyed on your owning `pi` process ...
58: resolves your pi owner ...
87: your owning `pi` process exits ...
```
### Common pitfalls — §4 (lines 133–139) ★
```
135: - **"I ran a driving command outside `pi` and it errored."** By design: driving commands
136:   require a `pi` ancestor — that is how your lane is keyed to you. ...
138:   browser work under `pi`; don't try to bypass it.
```
Edits:
- L135 "outside `pi`" → "outside a supported harness (`pi`/`claude`/`codex`/`agy`)"
- L136 "require a `pi` ancestor" → "require a supported-harness ancestor" (+ mention lanes owned by harness process)
- L138 "under `pi`" → "under a supported harness"

### SKILL.md edit summary
| Line | Current | → |
|---|---|---|
| 20, 36, 58, 87 | owning `pi` process / pi owner | owning harness process / harness owner |
| 135 | outside `pi` | outside a supported harness (pi/claude/codex/agy) |
| 136 | require a `pi` ancestor | require a supported-harness ancestor |
| 138 | under `pi` | under a supported harness |

---

## File 3 — `.agents/skills/agent-browser-pool/README.md`  [MODE A]

### The "without a `pi` ancestor" pitfall line (line 16) ★
```
16: - **Pitfalls:** driving commands fail fast without a `pi` ancestor (use `agent-browser` ...
```
- L16 "without a `pi` ancestor" → "without a supported-harness ancestor"
- L9 "under `pi`" → "under a supported harness" (phrasing); L11 "owning `pi` process" → "owning harness process" (phrasing)

---

## File 4 — `README.md` (root)  [MODE B — depends on R1–R4]

### 4a. Env-var table (lines 237–248) — add `AGENT_BROWSER_POOL_HARNESSES` row after L248
Format = 3-column pipe table (header col 1 = "Env var"). Test-only hooks callout L260–262 (reference only).

### 4b. "requires a `pi` ancestor" callouts
- **Usage blockquote (L101–106):** generalize L101, L103, L105.
- **Classification-detail blockquote (L151–152):** "owning `pi` process" → "owning harness process"; "without a `pi` ancestor" → "without a recognized-harness ancestor".

### 4c. Architecture "resolve owning `pi`" line
- **How-it-works diagram (L275):** `resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST` → `resolve owning harness PID + starttime; no recognized-harness ancestor → FAIL-FAST`
- **Lane lifecycle list (L290):** generalize.
- **Troubleshooting (L318–330):** heading + quote (mirror R3) + cause + fix generalize.
- **Other owning-`pi` mentions (phrasing sweep):** L16, L86, L172, L301, L304.

### 4d. Cross-harness skill-install section — DOES NOT EXIST YET (delta ADDS it) ★★★
**This is the headline doc addition.** Current Installation section (L51–81) is pi-only
(`--global-skill` paragraph L65–69, pi-only uninstall L74–76). **No per-harness table, no Codex caveat.**

Add (after R1–R4, after L81):
1. NEW paragraph describing cross-harness skill installation.
2. Per-harness skills-dir TABLE: pi / Claude Code / Codex / Antigravity (global + project skills dirs, follows symlinks?).
3. **Codex symlink caveat** (`openai/codex#11314`): Codex does NOT discover a symlinked `.agents/skills/`; for Codex install a **real copy**.

### README.md edit summary (Mode B)
| Line(s) | Change |
|---|---|
| 248 (after) | ADD `AGENT_BROWSER_POOL_HARNESSES` env-var row |
| 101–106 | generalize Usage blockquote callout |
| 151–152 | generalize Classification-detail callout |
| 275 | architecture diagram: resolve owning pi → harness |
| 290 | lifecycle list step 3 generalize |
| 318–330 | troubleshooting "requires a pi ancestor" section generalize (mirror R3) |
| 16, 86, 172, 301, 304 | phrasing sweep |
| NEW (after L81) | ADD §2.17 cross-harness skill-install paragraph + per-harness table + Codex caveat |

---

## File 5 — `install.sh`  [MODE B, OPTIONAL]

No required change. `--global-skill` (lines 29–34 arg-parse, 89–95 symlink action, 117–118
success msg) only ever symlinks into pi's `~/.agents/skills/`. **Optional:** point
`--global-skill` help text (L49–51) / success msg at README's new per-harness table. No new flag.

---

## Cross-file sync constraints
- The two env-var table rows (configuration.md L27-after, README.md L248-after) MUST use the same Default (`pi,claude,codex,agy,antigravity`) and Meaning wording.
- All inline `pool_die` quotes (configuration.md L54–55, README.md L318/L321) MUST mirror R3's new message text exactly.
- The §2.17 cross-harness addition is README-only; install.sh gains no new behavior.

## Mode A vs Mode B subtask assignment
- **Mode A (per-file, ride with R1/R2/R3):** configuration.md, SKILL.md, skill-README.md.
- **Mode B (changeset-level, depends on R1–R4):** README.md (root) + optional install.sh.
