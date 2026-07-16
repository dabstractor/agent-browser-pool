# Research Notes — P3.M3.T1.S1 (README.md root: env-var + callouts + architecture + troubleshooting + phrasing sweep)

Pure-docs item (Mode B, changeset-level README). **No code, no tests, no suite run.**
Planning validation = static grep/visual only (AGENTS.md §1 trivially satisfied — nothing to execute).

## 0. Source-of-truth anchors (host-verified, do not edit these files — only CONSUME)

### R3 fail-fast message — `lib/pool.sh:3429-3430` (landed by P3.M1.T1.S3, Complete)
```
3429:        pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
3430:                 "For raw browser use without pooling, call 'agent-browser' directly."
```
`pool_die` (lib/pool.sh:29-32) = `printf '%s\n' "$*"` → emits ONE line, args joined by `$IFS` (space):
`agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy). For raw browser use without pooling, call 'agent-browser' directly.`
→ README troubleshooting symptom quote + heading must mirror this.

### AGENT_BROWSER_POOL_HARNESSES config var — `lib/pool.sh:192,195` (landed by P3.M1.T1.S1, Complete)
Default = `pi,claude,codex,agy,antigravity` (lowercased comma-set; empty/unset → same default).

### configuration.md — ALREADY FULLY UPDATED (Mode A landed + committed) → SOURCE OF TRUTH for the env-var row
git status: `configuration.md` is NOT in the modified list (committed). Its env-var table (line 28):
```
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
```
→ README's NEW row must match this EXACTLY (same Default + same Meaning wording) — docs_map.md "Cross-file sync constraints".
configuration.md's troubleshooting matrix / dispatch / lifecycle / release / driving-commands are ALL already generalized — README must mirror the same terminology.

### Sibling PRP P3.M2.T1.S3 (parallel, in-flight)
Edits `test/transparency.sh` ONLY (TEST i substring poll). **DISJOINT FILE from README.md → zero conflict, zero dependency.** This item does NOT depend on S3.

## 1. README.md current state — authoritative line numbers (re-derived; contract's were approximate)

All `\`pi\`` / "pi ancestor" / "owning `pi` process" occurrences (grep -niE):

| # | Line | Region | Text (verbatim) | Scope |
|---|------|--------|-----------------|-------|
| 1 | 16 | bullet (1 agent=1 browser) | `keyed on the owning \`pi\` process (and` | **IN (g)** phrasing sweep |
| 2 | 86 | Usage para | `identity (your owning \`pi\` process and its start time)` | **IN (g)** |
| 3 | 101 | Usage blockquote | `**Driving commands require a \`pi\` ancestor.** From a plain terminal with no \`pi\` ancestor, a` | **IN (b)** |
| 4 | 103 | Usage blockquote | `under \`pi\`, or call \`agent-browser\` directly` | **IN (b)** |
| 5 | 105 | Usage blockquote | `command is a driving command that requires a \`pi\` ancestor.` | **IN (b)** |
| 6 | 151 | Classification callout | `command resolves your owning \`pi\` process, **fails fast** without a \`pi\` ancestor, and runs` | **IN (c)** |
| 7 | 172 | `reap` section | `Tear down lanes whose owning \`pi\` process has died` | **IN (g)** |
| 8 | 248 | env-var table | `AGENT_CHROME_ALLOW_SLOW_COPY` row (last row) | **IN (a)** insert AFTER |
| 9 | 262 | Test-only hooks callout | `without a real \`pi\` ancestor (PRD.md §2.18)` | **OUT — reference only** (docs_map File 4a; configuration.md keeps identical wording) |
| 10 | 278 | How-it-works diagram | `   │           resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST` | **IN (d)** |
| 11 | 290 | Lane lifecycle list | `3. **driving command → resolve the owning \`pi\` process**; if there is no \`pi\` ancestor,` | **IN (e)** |
| 12 | 301 | Release para | `**Release** happens when the owning \`pi\` process exits` | **IN (g)** |
| 13 | 304 | Release para | `crashed agent → its \`pi\` PID dies → next acquire reaps it.` | **IN (g)** |
| 14 | 318 | TS heading | `### Driving command errored: "requires a pi ancestor"` | **IN (f)** |
| 15 | 320-321 | TS symptom | `*"driving commands require a pi ancestor (owning pi process)."*` | **IN (f)** mirror R3 |
| 16 | 323-324 | TS cause | `keyed on your owning \`pi\` process; with no \`pi\` ancestor in the process tree` | **IN (f)** |
| 17 | 327-330 | TS fix | `under \`pi\` (e.g. inside a \`pi\` session)` ... `require a \`pi\` ancestor).` | **IN (f)** |

**After this item, the ONLY remaining `\`pi\`` references in README.md are (EXPECTED, not a defect):**
- Line 262 — test-only hooks callout (intentional; matches configuration.md verbatim).
- New harness enumerations `(\`pi\`/\`claude\`/\`codex\`/\`agy\`)` at lines ~103 + ~327 (the generalized phrasing).
- (The R3 symptom quote ~320 uses plain `pi/claude/codex/agy` with NO backticks — inside the literal message text — so `\`pi\``-grep won't hit it.)

## 2. Canonical terminology (cross-doc consistent: PRD §2.4/§2.11 + configuration.md + sibling PRPs)

| Concept | Phrase to use |
|---------|---------------|
| "pi ancestor" (the owner concept) | **recognized-harness ancestor** |
| "owning `pi` process" | **owning harness process** |
| "owning pi PID" | **owning harness PID** |
| "its `pi` PID" | **its harness PID** |
| "under `pi`" (where to run) | **under a supported harness (`pi`/`claude`/`codex`/`agy`)** |
| "require a `pi` ancestor" (callout/fix prose) | **require a supported-harness ancestor** |
| The fail-fast MESSAGE text (quote verbatim) | **driving commands require a supported agent harness (pi/claude/codex/agy)** |
| TS heading / the error name | **"requires a supported agent harness"** |

## 3. Scope boundary — DO NOT TOUCH (siblings / out-of-scope)

- **§2.17 cross-harness skill-install paragraph + per-harness table + Codex caveat** = sibling **P3.M3.T1.S2** (docs_map File 4d; lands a NEW section after the Installation block ~L81). Disjoint region from all (a)-(g) edits → no conflict, but implementer must NOT add that section here.
- **install.sh `--global-skill` help text** = sibling **P3.M3.T1.S3** (optional). Not README.
- **Line 262** (test-only hooks callout) = reference-only; configuration.md keeps identical wording → leave UNCHANGED for cross-doc consistency.
- **README env-var table MASTER default** (`~/.config/google-chrome` vs configuration.md's `${XDG_CONFIG_HOME:-~/.config}/google-chrome`) = PRE-EXISTING minor inconsistency, NOT in this item's contract → do not "fix" (scope creep).
- **"Three vars shape behavior most" prose** (README ~L250-258) = not in contract; configuration.md doesn't list HARNESSES in its "three that most affect behavior" either → do NOT add AGENT_BROWSER_POOL_HARNESSES there. Just the table row.
- NO other files. NO code. NO tests. NO suite run.

## 4. Env-var row sync (the ONE cross-file invariant)

README NEW row MUST be byte-identical to configuration.md:28 in Default + Meaning:
```
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
```
README table header = `| Env var | Default | Meaning |` (3-col). configuration.md header = `| Variable | Default | Meaning |`. Both 3-col pipe tables with backticked name+value → row is directly portable. Place AFTER the `AGENT_CHROME_ALLOW_SLOW_COPY` row (line 248), BEFORE the blank line / "Three vars" section.

## 5. Validation baseline (no tooling needed)

- No `markdownlint` on PATH → validation is grep + visual + git-diff (all static, all safe).
- README.md is 395 lines today; after edits ~398 (3 net added lines: 1 table row + ~2 from the longer TS symptom quote / fix prose — minor).

## 6. Confidence
Docs-only, fully enumerated (17 anchor points with verbatim current text + before→after), source-of-truth message + row host-verified and already landed in siblings, terminology table locked to cross-doc usage. **9.5/10** for one-pass. −0.5 = residual risk the implementer wraps the multi-line TS quote differently than intended (mitigated: exact target text given verbatim).
