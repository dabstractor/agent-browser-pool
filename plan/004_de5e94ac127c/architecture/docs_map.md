# Documentation map — caller-scoped lanes (orchestrator mode) + lane pinning delta

Line-pinned survey of every documentation surface the feature delta must touch, with the
existing formats new content must match. Read-only research; no repo file was modified
except this map. Context: `PRD.md` §2.12 (lines 292-334, 353, 372-374, 390, 401) defines
`ABPOOL_OWNER=caller` + `ABPOOL_LANE=<N>` — PRD is human-owned/read-only, never edited here.

## 1. Root `README.md` (421 lines) — primary user doc

### Outline (heading → line)
| Line | Heading |
|---|---|
| 1 | `# agent-browser-pool` (intro + 4 bullets, ends ~16) |
| 24 | `## Status` |
| 31 | `## Prerequisites` (numbered list 1-4 + tooling ¶) |
| 51 | `## Installation` (3 benign things + 3 bash fences) |
| 83 | `### Cross-harness skill installation` (4-col harness table 91-96) |
| 101 | `## Usage (for agents)` |
| 129 | `## Commands` |
| 135 | `### Pool verbs (operator / read-only — work from any shell)` |
| 147 | `### Driving commands (agent — routed to your own lane)` |
| 174 | `## Admin commands` |
| 176 | `### status (default)` |
| 188 | `### reap` |
| 203 | `### release [<N>\|all]` |
| 221 | `### doctor` |
| 253 | `## Configuration reference` |
| 291 | `## How it works` (ASCII flow diagram 297-310 + lifecycle list 312-322) |
| 331 | `## Troubleshooting` |
| 342 | `### Driving command errored: "requires a supported agent harness"` |
| 356 | `### Pool exhaustion — an agent blocks, then force-reaps` |
| 371 | `### Leaks — orphan dirs, dead Chrome, stale leases` |
| 386 | `## Repository layout` (tree + runtime-state ¶ to 421) |

### Env-var table (README.md:260-272)
3-column, 11 data rows (262-272). Header row (260) + separator (261), exact text:
```
| Env var | Default | Meaning |
|---|---|---|
```
HARNESSES row at exactly line **272** (PRD said "near 272" — confirmed exact):
```
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
```
**Insert `ABPOOL_OWNER` + `ABPOOL_LANE` rows at README.md:273** (immediately after the
HARNESSES row, still inside the table before the blank line at 273/274). Keep the same
3-col shape: key and default in backticks, meaning plain prose.

### Troubleshooting structure (331-385)
NOT a table — three `###` blocks (342, 356, 371), each with bold-labelled paragraphs in
fixed order **Symptom:** / **Cause:** / **Fix:**. Example block shape (lines 343-354):
```
**Symptom:** an `agent-browser-pool` driving command fails with a message like
*"agent-browser-pool: driving commands require a supported agent harness …"*

**Cause:** by design. Driving commands acquire a lane keyed on your owning harness process …

**Fix:** run browser work under a supported harness …
```
A pinned-lane-conflict block (`ABPOOL_LANE` held by live foreign owner → fail-fast, PRD
§2.12/line 390) fits as a **new `###` block at README.md:370-371** (after Pool exhaustion,
before Leaks) or appended before line 386.

### Invocation-checklist section = `## Usage (for agents)` (101-127)
Structure: 1 intro ¶ ("the lane is selected by your process identity… never an argument") →
4-bullet command list (107-112, each `` `agent-browser-pool <verb>` `` + em-dash gloss) →
one bash fence (114-116) → `> **Driving commands require a supported-harness ancestor.**`
blockquote (118-123) → skill pointer ¶ (125-127). **Orchestrator-mode usage fits as a new
`### Orchestrator mode (parallel workers from one session)` under line 127** or a short ¶
after the blockquote; mirrors PRD's intended-usage example (PRD.md:330-334: two
`ABPOOL_OWNER=caller … &` backgrounded scrapers). `## Commands` (129) / driving-commands
`###` (147-172) may each need one sentence noting env-var lane selection.

### PRD section-number citations in README.md (§-sign lines)
- 81: `[PRD.md §2.17](./PRD.md)` (install non-disruptive)
- 250: `[PRD.md §2.12](./PRD.md)` command list + `§2.14` failure modes
- 286: `(PRD.md §2.18)` test-only owner hooks
- 369: `PRD.md §2.9` (exhaustion)
- 384: `PRD.md §2.14` (leaks)
Format: inline `[PRD.md §X.YY](./PRD.md)` or bare `(PRD.md §X.YY)` parenthetical.
**Collision risk:** line 250 already cites §2.12 for the command list while PRD's §2.12 is
now caller-scoped lane selection — renumbering means new README prose must re-verify every
§ above (5 sites) if PRD section numbers shift.

### "Modes" / usage-scenario sections today
None exist. No heading contains "mode"/"scenario". Orchestrator mode is genuinely new
top-level content; nearest anchors: `## Usage (for agents)` (101), `## How it works`
(291, esp. the ASCII dispatch diagram 297-310 and lifecycle steps 312-322 — step 3/line 314
"resolve the owning harness process" would need a caller-keyed branch mention).

## 2. `.agents/skills/agent-browser-pool/SKILL.md` (156 lines) — agent contract

### Outline (frontmatter 1-4; title 6)
| Line | Heading |
|---|---|
| 26 | `## 1. Get + connect to your lane (acquire is automatic)` |
| 44 | `### Connection rules (don't fight the pool)` |
| 55 | `### Which commands trigger a lane` |
| 71 | `## 2. Tear down when you're finished` |
| 73 | `### close is NOT a teardown — it's a disconnect` |
| 85 | `### The real teardown is automatic` |
| 96 | `### Do NOT run pool admin commands as routine cleanup` |
| 103 | `## 3. Safety` |
| 105 | `### Inspect your lane (read-only, always safe)` |
| 118 | `### Safety & identity rules (non-negotiable)` |
| 133 | `## 4. Common pitfalls` |
| 152 | `## 5. Reference` (pointer ¶ 154-156, ends file) |

### Pitfalls format (§4, 133-150) — quoted example (135-138)
```
- **"I ran a driving command outside a supported harness (`pi`/`claude`/`codex`/`agy`) and it errored."** By design: driving commands
  require a supported agent harness — that is how your lane is keyed to you. …
```
Each pitfall = one bullet, bold **"quoted complaint"** lead-in, em-dash explanation.
An orchestrator pitfall (e.g. *"I'm a subprocess in a scraper fleet and every worker got the
SAME lane"*) fits as a **new bullet at SKILL.md:150** (before the blank line ending §4).

### Env-var/reference rows in SKILL.md
There is **no env-var table in SKILL.md**. §5 (152-156) is a pointer:
```
For the full environment-variable table, the complete pool-verbs-vs-driving dispatch
classification, the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix, read
**`references/configuration.md`**.
```
So the `ABPOOL_OWNER`/`ABPOOL_LANE` *row* belongs in configuration.md (below), not here.
SKILL.md's role: extend §5's pointer sentence (154-156) to mention orchestrator mode, and/or
add an "### Orchestrator mode (when you are a worker subprocess)" sub-block under §1 — best
fit **after line 53** (end of Connection rules, before `### Which commands trigger a lane`
at 55), matching the existing "don't fight the pool" bullet style at 46-53.
The "command never names a lane" identity paragraph (18-21) and acquire steps (28-36) also
assert invariants the feature qualifies ("never by an argument" stays true — pin is via env
var, set by the orchestrator, not the agent).

### Style conventions (SKILL.md)
Imperative second person ("Do not pass a port", "Just end your session normally"); numbered
`## N. Section` headings; bold lead-in bullets; ```bash fences with inline `#` comments;
backticks for every command/env var/path; bold+italics sparingly for *emphasis*; em-dashes.

## 3. `.agents/skills/agent-browser-pool/references/configuration.md` (147 lines)

### Outline
| Line | Heading | Span |
|---|---|---|
| 1 | `# Agent Browser Pool — configuration & reference` (+ intro 1-9) |
| 11 | `## Environment variables (all optional)` | 11-43 (truthy note 13-14, table 16-28, "three that most affect behavior" bullets 30-38, test-only-hooks blockquote 40-43) |
| 45 | `## Command dispatch: pool verbs vs. driving` | 45-78 (ordered list 51-58, `### Driving commands` 61-78) |
| 80 | `## How acquire works (the lifecycle)` | 80-99 (ASCII diagram 84-96, keying ¶ 98-99) |
| 101 | `## Release lifecycle (teardown)` | 101-116 |
| 118 | `## Troubleshooting matrix` | 118-130 |
| 132 | `## Admin CLI (operator-facing)` | 132-147 (fence 138-146) |

### Env-var table (16-28) — header + HARNESSES row (exactly line 28, as PRD estimated)
```
| Variable | Default | Meaning |
|---|---|---|
```
```
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
```
Note first column header is **`Variable`** here vs README's `Env var`. **Insert
`ABPOOL_OWNER` + `ABPOOL_LANE` rows at configuration.md:29** (after HARNESSES, still in
table); keep 3-col shape. The "three that most affect behavior" bullet list (30-38) and
test-only-hooks blockquote (40-43) follow unchanged unless the PRD adds more shaping prose.
Also update dispatch §(45-58: step 2 owner resolution) and lifecycle keying ¶ (98-99: "keyed
on the owning harness PID + starttime") with the caller-key branch, matching PRD.md:292-294.

### Troubleshooting matrix (118-130) — 3-col table; quoted first row (122)
```
| Symptom | Likely cause | Fix / response |
|---|---|---|
| Wrong browser / no lane acquired | Driving command run outside a supported harness (no recognized-harness ancestor → fail-fast) | Run your browser work under a supported harness; for raw browser use call `agent-browser` directly |
```
**New row at configuration.md:131** (after `doctor` WARN row, before `## Admin CLI` at 132):
pinned foreign-live-lane → fail-fast (PRD.md:390 wording: "fail fast with clear error; never
take over (§2.12)" — but write it **without** the § citation; see below).

## 4. `.agents/skills/agent-browser-pool/references/` — complete listing
Only one file exists: **`configuration.md`** — env-var table, dispatch classification,
acquire/release lifecycle, troubleshooting matrix, admin CLI (the skill's sole deep
reference). No other reference file documents env vars, lanes, or ownership.
(Flag for future writers: if orchestrator mode needs deep coverage, this file absorbs it;
creating new reference files would also require updating the skill README `## Files` list
at lines 20-24.)

## 5. `.agents/skills/agent-browser-pool/README.md` (46 lines) — skill overview
Outline: 1 title, 8 `## What it covers` (3 bold-lead bullets 10-18), 20 `## Files`
(2 bullets 22-24), 26 `## Installation` (3 fences, pi tip 42-46).
Bullet format example (10-12): `- **Acquire + connect:** the lane is created automatically…`.
**One-paragraph orchestrator-mode mention fits as a 4th bullet at line 19** — e.g.
`- **Orchestrator mode:** … ABPOOL_OWNER=caller + ABPOOL_LANE …` — matching the
bold-lead-in bullet style; alternatively extend the Files bullet for configuration.md (23-24).

## 6. Root `docs/` directory — EMPTY
`find docs -type f` → zero files; directory exists but contains nothing. Nothing to update
there; no env-var/mode/lane/ownership/§ citations can exist in it (verified by grep).

## Section-sign (§) citation audit — docs/ + .agents/ (PRD claim: skill/reference docs cite none)
- `docs/` — no files → zero citations.
- `.agents/skills/agent-browser-pool/references/configuration.md:19` — `… May be live/in-use (PRD §2.7). …` (env-table MASTER row)
- `.agents/skills/agent-browser-pool/references/configuration.md:34` — `… It may even be live/in-use (PRD §2.7).` (prose bullet)
- `.agents/skills/agent-browser-pool/SKILL.md:68` — `… see §2 and §3. …` → **internal self-reference to SKILL.md's own sections 2/3, NOT a PRD citation** (the only § in SKILL.md).
**The PRD's claim is FALSE for configuration.md: two live `PRD §2.7` citations exist.**
Consequence for the delta: (a) new rows/sections should follow the cited-practice of
README (which cites PRD freely) but the skill's own convention is prose-without-§ — write
new configuration.md content §-free if the PRD intends skill docs to be PRD-number-agnostic;
(b) if PRD §2 renumbering is part of the delta, configuration.md:19/34 must be re-verified.

## 7. Observed wording/style conventions (for blend-in)
- **Tables:** always 3 columns for env vars (`Key | Default | Meaning`); README says `Env var`, configuration.md says `Variable`. Troubleshooting in configuration.md is `Symptom | Likely cause | Fix / response`; README troubleshooting is NOT a table but bold **Symptom/Cause/Fix** paragraphs under `###`.
- **Keys/default values in backticks** (`` `AGENT_BROWSER_POOL_HARNESSES` ``, `` `53420` ``); defaults that are "unset=refuse" style written as `unset = **refuse** on non-btrfs`; prose meanings use **bold** sparingly for hard rules (`**never empty**`, `**Never launch, mutate, or delete.**`), `→` arrows for mappings, `·` separators in status docs.
- **Code fences:** ```bash for commands (with trailing `# comment` glosses), bare fences for output/diagrams; ASCII diagrams indented with `│ ├ └`.
- **Voice:** imperative second person for agents ("Do not pass…", "Run…"); explanatory em-dash clauses; scare-quoted complaint strings in pitfalls (`"…"`) bolded.
- **Cross-refs:** relative md links; README → PRD uses `[PRD.md §X.YY](./PRD.md)`; skill files → each other by relative path in backticks or bold; file paths like `lib/pool.sh` in backticks.
- **Ownership vocabulary today:** "owner"/"owning harness process"/"owner PID/starttime"/"lane keyed on identity". New feature vocabulary from PRD: "caller-scoped", "caller", "orchestrator mode", "lane pin", "pinned lane", "foreign live owner". Keep `abpool-<N>` session naming convention when describing per-lane sessions.

## 8. Consolidated must-change file list (file → insertion points)
1. `README.md:272-273` env table rows (`ABPOOL_OWNER`, `ABPOOL_LANE`).
2. `README.md:~127` new `###` orchestrator usage under Usage (for agents); possibly one sentence each at 129-172 (Commands) and 312-322 (lifecycle step 3).
3. `README.md:370/385` new troubleshooting `###` block (pinned-lane conflict).
4. `.agents/skills/agent-browser-pool/references/configuration.md:28-29` env table rows; `:51-58` dispatch step 2; `:98-99` keying ¶; `:131` troubleshooting matrix row.
5. `.agents/skills/agent-browser-pool/SKILL.md:~53` orchestrator-mode sub-block (and/or pitfall bullet at `:150`; extend §5 pointer at `:154-156`; keep identity invariants at `:18-21` accurate).
6. `.agents/skills/agent-browser-pool/README.md:19` one-bullet mention in What it covers.