# PRP — P1.M10.T1.S1: Update README.md — features, install, usage, configuration reference

> **Scope flag.** This is a **DOCS-ONLY** PRP (item contract §5: "[Mode B] this IS the
> documentation task — updates README.md as the changeset-level overview"). Its **sole**
> output is a rewritten `README.md` (+ this PRP). It adds **zero** source/lib/bin/test
> changes and **zero** runtime-state changes. It does NOT touch `PRD.md`, `AGENTS.md`,
> `install.sh`, `.gitignore`, or any `tasks.json` (all read-only per AGENTS.md §5).
>
> **Runs in parallel with P1.M9.T1.S1** (the `test/transparency.sh` transparency-checklist
> suite). That item is test-only and changes no behavior / no env vars / no CLI output, so
> it does not affect README content — except that the README may name `test/transparency.sh`
> as part of the suite. Treat P1.M9.T4.S1's PRP as a contract for the *file existing*, not
> for any README-visible surface.

---

## Goal

**Feature Goal**: Rewrite `README.md` so it is an accurate, self-contained user document
for the **implemented** agent-browser-pool MVP — replacing the pre-implementation
"Design / brainstorm" draft with the real features, install, usage, admin commands,
configuration reference, safety valve, and troubleshooting.

**Deliverable**: an updated `README.md` (~250–400 lines of Markdown) covering the nine
contract sections (a–i, item §3), whose every command/env-var/example-output matches the
shipped code (`lib/pool.sh`, `bin/*`, `install.sh`) exactly.

**Success Definition**: a user who has never seen this repo can, from `README.md` alone:
install the pool, drive it transparently as an agent, run the four admin commands and read
their output, configure every env var, invoke the safety valve, and diagnose pool
exhaustion / leaks. Every fenced code block parses; every env var in the README appears in
`agent-browser-pool --help` and vice-versa; the Status line no longer says "design/brainstorm".

---

## User Persona

**Target User**: (1) the **operator/human** who installs + administers the pool, and (2) the
**AI agent** (or its author) that consumes it transparently. README serves both: the agent
cares only about "type `agent-browser …`"; the human cares about install/admin/config/debug.
**Use Case**: first-time install + cutover; day-to-day `status`/`reap`; incident triage via `doctor`.
**User Journey**: read Prerequisites → `./install.sh` (confirm YES) → `doctor` → agent uses
`agent-browser` → human runs `agent-browser-pool status` → on trouble, `reap`/`release`/`doctor`.
**Pain Points Addressed**: the current README says "implementation pending" and has no
install/usage/admin/config/troubleshooting sections, so users cannot operate the shipped system.

---

## Why

- P1.M10 is the only **Planned** milestone left; its T1.S1 is the single doc task gating
  "MVP documentation matches the shipped system." The README is the project's primary user
  doc and is currently stale (written in the greenfield phase — see `system_context.md §1`).
- The implementation is complete (M1–M9) and exposes a real admin CLI whose output is
  deterministic but non-obvious (`status` columns, `doctor` sections). Undocumented output
  = users can't interpret `status`/`doctor` and will mistrust the pool.
- `install.sh` is already **Mode A** ("its output IS the cutover documentation"); the README
  must echo that cutover warning so users read it BEFORE running install (the README is
  browsed on GitHub; `install.sh`'s warning is seen only at install time).
- Sets up P1.M10.T1.S2 (verify `.gitignore` covers runtime artifacts) — the README's "Repo
  layout" section should correctly mark runtime dirs as gitignored so S2's check is consistent.

---

## What

A **rewrite of `README.md`** (overwrite in place) with these sections, in order. Each maps
1:1 to an item-contract clause (a–i, item §3):

| § | README section | Contract clause |
|---|---|---|
| 1 | Title + feature overview | (a) transparency, 1 agent=1 browser, cleanup-on-crash, discoverable pool |
| 2 | Prerequisites | (b) btrfs, master-profile, agent-browser ≥0.28, Chrome |
| 3 | Installation | (c) `./install.sh`, confirmation, cutover warning |
| 4 | Usage (for agents) | (d) just type `agent-browser` — nothing special |
| 5 | Admin commands | (e) status / reap / release / doctor, with example outputs |
| 6 | Configuration reference | (f) every env var from §2.11 with defaults |
| 7 | Safety valve | (g) `AGENT_BROWSER_POOL_DISABLE=1` |
| 8 | How it works (30-second version) | (h) verify accuracy of the existing block |
| 9 | Troubleshooting | (i) pool exhaustion, leaks, doctor |

### Success Criteria
- [ ] README contains all 9 sections above (a–i).
- [ ] The **env-var table** in §6 lists exactly the 11 vars in `agent-browser-pool --help`
      (`pool_admin_help`, lib/pool.sh:4286) with correct defaults — no extras, none missing.
- [ ] The **example outputs** in §5 use the exact labels/verdicts the functions emit
      (status header `LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`; doctor
      sections `[dependencies][binary][filesystem][master][lanes][dirs][summary]`; reap /
      release / summary strings — see research §4).
- [ ] §3 mirrors `install.sh`'s cutover warning (all-or-nothing, silently-intercepts-running-
      agents, type `YES`, absolute-path testing, disable env, uninstall one-liner).
- [ ] §8 ("How it works") matches the real lifecycle ordering (research §3).
- [ ] The "Status: Design / brainstorm" line is GONE (MVP is shipped).
- [ ] Every fenced ` ```bash ` block is syntactically valid bash (extracts to `bash -n` clean).
- [ ] All relative links resolve (`PRD.md`, `AGENTS.md`, `install.sh`); no dead anchors.

---

## All Needed Context

### Context Completeness Check
A writer who has never seen this repo can produce the README from: (1) the authoritative
facts file `research/readme-facts.md` (env defaults, admin output formats, lifecycle, Chrome
flags, cutover warning — all extracted verbatim from the code), (2) the current `README.md`
to preserve its good prose, (3) `install.sh` as the canonical cutover-warning wording, and
(4) the PRD sections quoted below. All four are provided/referenced. No live Chrome run is
required (and is forbidden during docs work — AGENTS.md §1).

### Documentation & References
```yaml
# --- AUTHORITATIVE FACTS (read FIRST; the single source of truth for this PRP) ---
- file: plan/001_0f759fe2777c/P1M10T1S1/research/readme-facts.md
  why: "env-var table (§2), admin output formats (§4), lifecycle (§3), Chrome flags (§5),
        cutover warning wording (§6), repo layout (§8). Every value lifted verbatim from
        lib/pool.sh / install.sh. README MUST match this file."
  critical: "§4 (admin output formats) and §2 (env defaults) are the two tables most likely
             to drift from the tool. Cross-check the finished README against them, AND
             against a live `agent-browser-pool --help` (static, no Chrome — safe)."

# --- the file being rewritten (preserve its good prose) ---
- file: README.md
  why: "current draft. KEEP: the 4-bullet overview + the 'How it works (30-second version)'
        ASCII block (verify accuracy vs research §3). REPLACE: the 'Status: Design / brainstorm'
        block. ADD: all 9 sections in the What table."
  pattern: "the existing prose voice (concise, bullet-driven, ASCII diagrams) is the house
            style — match it. Don't rewrite good sections from scratch."

# --- canonical cutover-warning wording (Mode A) ---
- file: install.sh
  why: "§3 (Installation) must mirror install.sh's warning sentences verbatim in spirit:
        '~/scripts PRECEDES ~/.local/bin', 'ALL-OR-NOTHING', 'silently intercepted',
        'type YES', absolute-path testing, AGENT_BROWSER_POOL_DISABLE, uninstall rm -f."
  pattern: "install.sh already prints a BAR-delimited warning + success block; the README
            should summarize it and point users at `./install.sh` (which re-prints it)."

# --- PRD (READ-ONLY; quote, don't edit) ---
- url: PRD.md#2.11   # h3.15 — Discovery & configuration: the authoritative env-var list
  why: "the README §6 table is the user-facing rendering of this list."
- url: PRD.md#2.12   # h3.16 — Admin CLI command list (status/reap/release/doctor)
  why: "README §5 documents these; example outputs come from research §4 (the code)."
- url: PRD.md#2.17   # h3.21 — Cutover & coexistence: the source of the install warning
  why: "README §3 (Install) + §7 (Safety valve) summarize this for end users."
- url: PRD.md#2.15   # h3.19 — Transparency checklist (the 'no-idea' contract)
  why: "README §4 (Usage for agents) should state this contract in one line."
- url: PRD.md#1.3    # h3.2 — Goals (transparency / 1-agent-1-browser / mutual-exclusion /
                     #         cleanup-on-crash / discoverable-unbounded) → README §1 overview.
- url: PRD.md#1.5    # h3.4 — User stories → README §4 (agent) + §5 (human admin) framing.

# --- system context (confirms host facts the README states as prerequisites) ---
- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: "§2 confirms the prerequisite claims (agent-browser 0.28.0, btrfs, master-profile
        4.8 GB, ~/scripts ahead of ~/.local/bin on PATH). README §2 (Prerequisites) states
        these as user requirements; system_context proves they hold on the target host."
  critical: "Do NOT copy host-specific PIDs/paths (e.g. /home/dustin/...) into user-facing
             README prose — use ~ / $HOME / 'your home'. Only the AGENT_BROWSER_REAL default
             is host-anchored by design (document it as '~/.local/bin/agent-browser')."

# --- the admin tool whose output README documents (for spot-checking, NOT editing) ---
- file: lib/pool.sh:4267  # pool_admin_help — the env-var/command list README §5/§6 must match
- file: lib/pool.sh:3594  # pool_admin_status — the table format (§5 example)
- file: lib/pool.sh:4011  # pool_admin_doctor — the section layout (§5 example)
- file: lib/pool.sh:3451  # pool_wrapper_main — the lifecycle (§8 accuracy check)
```

### Current Codebase tree (relevant subset)
```bash
agent-browser-pool/
├── README.md            ← REWRITE THIS (the deliverable)
├── PRD.md               ← READ-ONLY (quote §2.11/2.12/2.17/2.15/1.3/1.5)
├── AGENTS.md            ← READ-ONLY (do not duplicate its content in README)
├── install.sh           ← READ (canonical cutover warning)
├── bin/
│   ├── agent-browser      ← the transparent wrapper (documents itself via lib)
│   └── agent-browser-pool ← the admin CLI (its --help is the env-var source of truth)
├── lib/pool.sh          ← READ (env defaults @126-176; admin output @3594/3730/3830/4011/4267)
└── test/
    ├── validate.sh concurrency.sh release_reaper.sh   ← landed
    └── transparency.sh                                  ← from parallel P1.M9.T4.S1
```

### Desired Codebase tree with files to be added/changed
```bash
agent-browser-pool/
├── README.md            ← MODIFIED (full rewrite of the body; ~250–400 lines)
└── (nothing else changes — docs-only PRP)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL: README env-var table MUST exactly equal `agent-browser-pool --help` output
#   (pool_admin_help, lib/pool.sh:4286-4300). Do NOT invent vars; do NOT drop one. The 11 are:
#   AGENT_BROWSER_POOL_STATE, AGENT_CHROME_MASTER, AGENT_CHROME_EPHEMERAL_ROOT,
#   AGENT_BROWSER_REAL, AGENT_CHROME_BIN, AGENT_CHROME_PORT_BASE, AGENT_CHROME_PORT_RANGE,
#   AGENT_BROWSER_POOL_WAIT, AGENT_CHROME_HEADLESS, AGENT_CHROME_ALLOW_SLOW_COPY,
#   AGENT_BROWSER_POOL_DISABLE.   (research/readme-facts.md §2)

# CRITICAL: example outputs are DETERMINISTIC (research §4). Do NOT boot real Chrome to
#   "capture" a status/doctor example — construct them from the format strings (AGENTS.md §1
#   forbids live Chrome during docs work). A status row literally is:
#   `   1  53420 abpool-1         836725 /home/dustin/projects/x     104816  2m13s live`

# CRITICAL: do NOT copy host-specific absolute paths (/home/dustin/...) into user-facing
#   prose. Use ~ , $HOME, or '<repo>/'. Exception: AGENT_BROWSER_REAL's default IS
#   '~/.local/bin/agent-browser' by design — state it as such.

# GOTCHA: the existing README's "Status: Design / brainstorm. Implementation pending…" block
#   (near the top) MUST be removed/rewritten — it is now factually wrong (MVP is shipped).

# GOTCHA: agent-browser-pool has NO subcommand named 'acquire'/'connect'/'lane' — the four
#   admin verbs are EXACTLY: status | reap | release [<N>|all] | doctor (+ help/--help/-h).
#   Do not document verbs that don't exist.

# GOTCHA: 'close' (mid-task) is DISCONNECT-ONLY (lane/Chrome/dir survive for reuse). Do not
#   document 'agent-browser close' as a release. Release = owner-exit / explicit
#   'agent-browser-pool release' / exhaustion force-reap. (PRD §2.5; research §3.)

# GOTCHA: paths are resolved absolute before any subprocess — README should state this as a
#   GUARANTEE ("the wrapper never passes a bare ~ to Chrome/rm"), not as a user gotcha.
```

---

## Implementation Blueprint

### Data models and structure
_N/A — this is a Markdown documentation task. There is no data model. The closest analog is
the two reference tables the README must contain: the **env-var table** (research §2) and the
**admin command reference** (research §4). Both are fully specified in `research/readme-facts.md`._

### Implementation Tasks (ordered: top-of-file → bottom-of-file; no inter-task deps)

```yaml
Task 1: PRESERVE — keep the title + 4-bullet feature overview
  - KEEP verbatim: the H1 title `# agent-browser-pool`, the 1-line description, and the
    4 bullets (Not a fork / Ephemeral profiles / 1 agent = 1 browser / Fully invisible).
  - WHY: these are accurate and in the house voice; rewriting adds risk for no gain.
  - SOURCE: existing README.md lines 1–11 (approx).

Task 2: REPLACE — rewrite the "Status" block (was "Design / brainstorm")
  - REMOVE: "**Design / brainstorm.** Implementation pending final confirmation…"
  - ADD: a one-line status indicating the MVP is implemented/shipped (e.g. "Status: MVP
    shipped (transparent wrapper + admin CLI + installer). See §Installation.").
  - WHY: the current line is factually false after M1–M9.
  - CONTRACT clause: implied by "accurately reflects the final system" (item §3 OUTPUT).

Task 3: EXPAND §2 Prerequisites (contract clause b)
  - LIST, as a numbered or bulleted list, the four prerequisites from research/system_context §2:
    1. btrfs at the pool root (~/.agent-chrome-profiles) — enables instant dedup'd CoW.
    2. Master template at ~/.agent-chrome-profiles/master-profile (full Chrome profile:
       Google login, Bitwarden, agent-browser extension). NEVER launch Chrome against it
       directly (static template; wrapper CoW-copies per lane + strips Singleton* locks).
    3. agent-browser ≥ 0.28 at ~/.local/bin/agent-browser (supplies --session / connect /
       get cdp-url / AGENT_BROWSER_SESSION env). Stays upgradable (wrapper calls it by abs path).
    4. google-chrome-stable (or whatever $AGENT_CHROME_BIN points at).
  - ALSO mention util-linux deps implicitly via "run `agent-browser-pool doctor` to verify"
    (flock, setsid, pgrep, pkill, cp, curl, jq, notify-send-optional) — doctor checks them.
  - NAMING: section header "## Prerequisites".

Task 4: CREATE §3 Installation (contract clause c) — mirror install.sh's Mode-A warning
  - STATE: `./install.sh` symlinks bin/agent-browser→~/scripts/agent-browser (AHEAD of
    ~/.local/bin on PATH → SHADOWS the real CLI) and bin/agent-browser-pool→
    ~/.local/bin/agent-browser-pool, pre-creates the state dir, runs `doctor`.
  - WARN (paraphrase install.sh verbatim-in-spirit): ALL-OR-NOTHING; no safe partial shadow;
    running agents on the OLD workflow are SILENTLY INTERCEPTED (next `agent-browser` call
    overrides their --session/connect → abandons in-progress work on persistent profiles
    1..10 → BREAKS running work).
  - STATE the install gate: `./install.sh` prints the warning and requires typing `YES`
    (or `./install.sh --force` to skip; `./install.sh --help` for help).
  - STATE pre-cutover testing: invoke the wrapper BY ABSOLUTE PATH
    (`<repo>/bin/agent-browser open https://example.com`) — exercises all logic without
    touching the PATH-resolved agent-browser running agents use.
  - STATE uninstall: `rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool`.
  - Example block:
        ./install.sh            # prints warning, asks YES
        ./install.sh --force    # scripted / re-install
        ./install.sh --help
  - CROSS-REF: point users to PRD.md §2.17 for the full cutover & coexistence rationale.

Task 5: CREATE §4 Usage for agents (contract clause d)
  - ONE-LINE contract: "Just type `agent-browser …` exactly as the upstream skill teaches.
    The wrapper routes every call to your locked ephemeral lane. You cannot tell pooling
    is happening." (PRD §2.15 / §1.3 goal 1.)
  - STATE the absorption guarantees (PRD §2.4) as what the agent does NOT need to know:
    `connect <anything>`, `--session <X>`, and `close [--all]` all route to YOUR lane and
    cannot escape it or harm other agents' lanes.
  - EXAMPLE block (the canonical zero-prep open):
        agent-browser open https://example.com     # your lane, same browser for the session
  - NOTE: humans in a plain terminal (no pi ancestor) get raw passthrough (no lane magic) —
    so `agent-browser` from a shell still works normally for the operator.

Task 6: CREATE §5 Admin commands (contract clause e) — `agent-browser-pool`
  - INTRO: "Admin tool (for the human operator). Default command is `status`."
  - For EACH of status / reap / release / doctor: one-line purpose + an example-output
    block built from research §4 (DETERMINISTIC — do NOT boot Chrome):
      * status  → show the table header + 1 realistic row + the empty-pool line.
        Header:  `LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`
        Row e.g: `   1  53420 abpool-1         836725 /home/dustin/projects/x   104816  2m13s live`
        Empty:   `No active lanes.`
        States:  live | disconnected | STALE.
      * reap    → `No stale lanes found.`  |  `Reaped 2 stale lane(s).`
      * release → `release 1` → `Released lane 1.` ; `release all` → `Released 2 lane(s).`
                  ; `release 99` → `Lane 99 has no active lease.` (rc 1).
      * doctor  → show the 7 section headers + a healthy summary:
        `[dependencies][binary][filesystem][master][lanes][dirs][summary]` →
        `OK=N  WARN=0  FAIL=0` + `Healthy.` (rc 0; rc 1 + `Problems found.` on any FAIL).
  - ALSO list `help` / `--help` / `-h`.
  - NOTE: `release` with no/invalid arg → stderr usage + rc 1.
  - CROSS-REF: PRD.md §2.12 for the command list; §2.14 (failure modes) for what each fixes.

Task 7: CREATE §6 Configuration reference (contract clause f) — the env-var table
  - RENDER research §2's 11-row table verbatim (var | default | meaning). This table MUST
    equal `agent-browser-pool --help` output (pool_admin_help).
  - STATE: all optional; all paths resolved absolute before subprocesses (no bare ~).
  - CALL OUT the three behavior-shaping ones: AGENT_BROWSER_POOL_DISABLE (→ §7),
    AGENT_CHROME_ALLOW_SLOW_COPY (refuse vs allow slow non-btrfs copy), AGENT_CHROME_HEADLESS.
  - NOTE test-only hooks (AGENT_BROWSER_POOL_OWNER_PID / _OWNER_STARTTIME) are for the test
    harness only (PRD §2.18) — list them separately, clearly marked "testing, not for users".

Task 8: CREATE §7 Safety valve (contract clause g)
  - STATE: `export AGENT_BROWSER_POOL_DISABLE=1` → THIS process passes through to the real
    agent-browser with NO pooling (per-process, not global). Used for cutover coexistence
    (stay on the old workflow) or debugging.
  - EXAMPLE:
        export AGENT_BROWSER_POOL_DISABLE=1
        agent-browser open https://example.com    # real ~/.local/bin/agent-browser, no lane
  - CROSS-REF: PRD.md §2.17 (cutover & coexistence) + §3 (Install) above.

Task 9: VERIFY §8 How it works (30-second version) (contract clause h)
  - KEEP the existing ASCII lifecycle block (it is accurate), but VERIFY it against research
    §3 ordering: disable→meta→no-pi-ancestor passthrough; else find-mine/acquire→boot/adopt
    →ensure-connected→normalize(close/connect)→strip-session→force abpool-<N>→exec real binary.
  - IF the existing block omits the safety-valve / passthrough branches, ADD a one-liner:
    "passthrough if AGENT_BROWSER_POOL_DISABLE=1, for META commands (skills/--help/session
    list), or when no pi ancestor (human terminal) — otherwise the lane lifecycle below."
  - PRESERVE the release explanation (kill pgroup + rm ephemeral dir + drop lease; crashed
    agent → its pi dies → next acquire reaps it). Confirm close = disconnect-only.

Task 10: CREATE §9 Troubleshooting (contract clause i)
  - THREE subsections, each: symptom → cause → fix:
      1. Pool exhaustion: agent blocks up to 10 min, then force-reaps + alerts (desktop
         notify-send + a line in ~/.local/state/agent-browser-pool/alerts.log). Fix:
         `agent-browser-pool reap` then `release all`; investigate the LEAK (hitting the
         alert at all means sessions accumulated without cleanup). Tune AGENT_BROWSER_POOL_WAIT.
      2. Leaks (orphan dirs / dead Chrome / stale leases): run `agent-browser-pool doctor`
         — [lanes]/[dirs] flag LEAK(...)/ORPHAN DIR; fix with `reap` (stale-only) or
         `release <N>|all` (explicit). RC 1 from doctor = problems found.
      3. "It didn't do anything / wrong browser": likely passthrough — you're a human in a
         terminal (no pi ancestor) OR AGENT_BROWSER_POOL_DISABLE=1. For agents, confirm a pi
         ancestor; run `agent-browser-pool status` to see the lane.
  - STATE the canonical triage sequence: `agent-browser-pool status` → `doctor` →
    `reap` / `release [<N>|all]`.
  - CROSS-REF: PRD.md §2.9 (exhaustion), §2.14 (failure modes & recovery), §2.16 (deps).

Task 11: POLISH — links, footer, consistency pass
  - Ensure relative links resolve: [PRD.md](./PRD.md), [AGENTS.md](./AGENTS.md),
    [install.sh](./install.sh). Optionally link the relevant PRD § anchors.
  - Add a short "Repository layout" block (research §8) showing bin/ lib/ test/ + noting
    runtime dirs (~/.local/state/agent-browser-pool, ~/.agent-chrome-profiles/{master,active})
    are gitignored / created at install.
  - Do NOT duplicate AGENTS.md content (agent operating rules) in the README — link it.
  - Final: re-read top-to-bottom for voice consistency with the preserved §1 prose.
```

### Implementation Patterns & Key Details
```markdown
# House style (match the preserved §1 prose): concise, bullet-driven, ASCII diagrams in
# fenced ``` blocks, tables for reference data. One H2 (##) per section. No emojis.

# Example-output construction rule: outputs are DETERMINISTIC (research §4). Build them from
# the format strings, NOT a live run. A `status` row is literally:
#   printf '%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n' 1 53420 abpool-1 836725 /path 104816 2m13s live
# →  "   1  53420 abpool-1         836725 /home/dustin/projects/x     104816  2m13s live"

# Every ```bash fenced block must be valid bash. Avoid command-substitution or unbalanced
# quotes in examples. The `release 99` → "Lane 99 has no active lease." line is stdout (not
# an error echo) — render it as normal output, but note rc 1 in prose.

# Env-var table row shape (render all 11; order matches pool_admin_help):
# | `AGENT_BROWSER_POOL_DISABLE` | unset = pooling active | `1` = per-process passthrough (safety valve) |
```

### Integration Points
```yaml
LINKS:
  - add: "[PRD.md](./PRD.md)" (full spec) — top of file, near overview.
  - add: "[AGENTS.md](./AGENTS.md)" (agent operating rules) — do NOT inline its content.
  - add: "[install.sh](./install.sh)" — in §3 (Installation).
  - optional anchors: PRD.md#2.11 (config), #2.12 (admin), #2.17 (cutover), #2.15 (transparency).

FILES REFERENCED (read-only; README points at them):
  - install.sh       → §3 cutover warning source (Mode A).
  - bin/agent-browser-pool --help → §5/§6 source of truth (the env-var list + command list).
  - lib/pool.sh      → §5/§8 output formats + lifecycle (research §3/§4; do NOT edit).

CONFIG: none (no env var is added/changed — README only DOCUMENTS the existing 11).
ROUTES: none.
DATABASE: none.
GITIGNORE: none (this PRP must NOT touch .gitignore — that is P1.M10.T1.S2's job).
```

---

## Validation Loop

### Level 1: Markdown & bash-block syntax (immediate, static — AGENTS.md §1 compliant)

```bash
# (a) every fenced ```bash block in the README parses as bash. Extract + check:
tmp=$(mktemp); awk '/^```bash$/{f=1;next} /^```$/{f=0} f' README.md > "$tmp"; bash -n "$tmp" && echo "bash-blocks OK"; rm -f "$tmp"
# Expected: "bash-blocks OK". If bash -n errors, a code block has a syntax error — fix it.

# (b) optional markdown lint (only if a linter is present; NOT a repo dependency):
#     markdownlint README.md 2>/dev/null || mdformat --check README.md 2>/dev/null || true
# Expected: clean (or skipped — not mandatory).

# (c) no leftover "Design / brainstorm" / "implementation pending" / "TODO":
grep -niE 'design.?/?.?brainstorm|implementation pending|TODO|FIXME|XXX' README.md || echo "no stale markers"
# Expected: "no stale markers".
```

### Level 2: Internal consistency (README ↔ tool's own --help ↔ research facts)

```bash
# (a) the README's env-var set == `agent-browser-pool --help` set (pool_admin_help).
#     doctor/init are static (no Chrome) — safe to run (AGENTS.md §1: static checks only).
# Extract README's AGENT_* vars vs the help's; diff:
readme_vars=$(grep -oE 'AGENT_[A-Z_]+' README.md | sort -u)
help_vars=$(bash bin/agent-browser-pool --help | grep -oE 'AGENT_[A-Z_]+' | sort -u)
diff <(printf '%s\n' "$readme_vars") <(printf '%s\n' "$help_vars") && echo "env-var sets MATCH"
# Expected: "env-var sets MATCH". (NOTE: AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME are test
# hooks; if README lists them under a clearly-marked "testing" note, that is fine — they
# appear in pool.sh but NOT in pool_admin_help, so exclude them from the diff or document
# them only in prose, not in the main config table.)

# (b) README documents EXACTLY the four admin verbs (+help) — no phantom verbs:
grep -nE 'agent-browser-pool (status|reap|release|doctor|help)' README.md   # sanity
grep -niE 'agent-browser-pool (acquire|connect|lane|start|stop)\b' README.md && echo "PHANTOM VERB!" || echo "verbs OK"
# Expected: "verbs OK" (no phantom verbs).

# (c) status header in README == the real header (research §4.1):
grep -F 'LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE' README.md && echo "status header OK"
# Expected: match + "status header OK".
```

### Level 3: Accuracy spot-checks against the code (static reads; NO Chrome)

```bash
# (a) env-var defaults in README == pool_config_init defaults (lib/pool.sh:126-176):
grep -nE '53420|:-.*/.local/(state/agent-browser-pool|bin/agent-browser)|master-profile|/active' lib/pool.sh | head
# Cross-check these literals appear (with correct defaults) in README §6.

# (b) cutover wording in README §3 mirrors install.sh's warning sentences:
grep -nE 'silently intercept|all-or-nothing|YES|absolute path|AGENT_BROWSER_POOL_DISABLE' install.sh
# Confirm README §3/§7 echo these concepts.

# (c) lifecycle in README §8 matches pool_wrapper_main ordering (lib/pool.sh:3451):
sed -n '3451,3560p' lib/pool.sh | grep -vE '^\s*(#|$)'
# Confirm README §8 lists: disable-passthrough → meta-passthrough → no-pi-passthrough →
# find-mine/acquire → boot/adopt → ensure-connected → normalize → force-session → exec.

# Expected: README prose matches the code at every spot-check. No live Chrome is launched.
```

### Level 4: Render & human-readability (the doc-specific gate)

```bash
# (a) render preview (if a renderer is available; optional):
#     glow README.md | head -80   OR   mdcat README.md | head -80
# Expected: clean layout, readable tables, no raw markdown leaking.

# (b) link integrity (relative links resolve to real files):
for l in PRD.md AGENTS.md install.sh; do test -f "$l" && echo "link OK: $l"; done
grep -oE '\]\(\./[^)]+\)' README.md | sed 's/].(\(.*\))/\1/' | while read p; do test -e "$p" && echo "OK $p" || echo "BROKEN $p"; done
# Expected: all "OK", none "BROKEN".

# (c) the "No Prior Knowledge" read: a reader who has never seen this repo can, from README
#     alone, install + use + administer + configure + bypass + troubleshoot the pool.
#     (Self-review pass; the 9 success-criteria checkboxes in §What must all be tickable.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `bash -n` clean on every fenced bash block; no stale "design/brainstorm/TODO" markers.
- [ ] Level 2: README env-var set == `agent-browser-pool --help` set; no phantom admin verbs;
      status header matches the function's format string.
- [ ] Level 3: defaults/cutover/lifecycle in README match `lib/pool.sh` / `install.sh` spot-checks.
- [ ] Level 4: relative links resolve; render is clean; "No Prior Knowledge" read passes.

### Feature Validation (the 9 contract sections a–i)
- [ ] (a) Feature overview: transparency, 1-agent-1-browser, cleanup-on-crash, discoverable pool.
- [ ] (b) Prerequisites: btrfs, master-profile, agent-browser ≥0.28, Chrome.
- [ ] (c) Installation: `./install.sh`, YES confirmation, cutover warning (mirrors install.sh).
- [ ] (d) Usage for agents: "just type `agent-browser`".
- [ ] (e) Admin commands: status / reap / release / doctor with accurate example outputs.
- [ ] (f) Configuration reference: all 11 env vars with defaults (== `--help`).
- [ ] (g) Safety valve: `AGENT_BROWSER_POOL_DISABLE=1`.
- [ ] (h) How it works (30-second version): verified accurate vs the real lifecycle.
- [ ] (i) Troubleshooting: pool exhaustion, leaks, doctor.

### Code Quality / Hygiene
- [ ] Only `README.md` modified (no PRD.md / AGENTS.md / install.sh / .gitignore / tasks.json /
      lib/ / bin/ / test/ changes — AGENTS.md §5 + FORBIDDEN OPERATIONS).
- [ ] House voice preserved (concise, bullet-driven, ASCII diagrams); no emojis.
- [ ] No host-specific absolute paths (/home/dustin/...) in user-facing prose (use ~ / $HOME).
- [ ] No duplicate of AGENTS.md content (link it, don't inline it).

### Documentation & Deployment
- [ ] README is self-contained for a first-time user (install → use → admin → config → bypass → debug).
- [ ] Cross-references to PRD.md sections are correct (§2.11/2.12/2.17/2.15/1.3/1.5).
- [ ] Runtime dirs correctly noted as gitignored / created-at-install (consistent with S2).

---

## Anti-Patterns to Avoid

- ❌ Don't boot real Chrome or run the test suite to "capture" example outputs — they are
  deterministic (research §4); construct them from the format strings. (AGENTS.md §1.)
- ❌ Don't invent or drop env vars / admin verbs — the README MUST equal `agent-browser-pool --help`
  and the four real verbs (status|reap|release|doctor + help).
- ❌ Don't copy host-specific paths (/home/dustin/...) into user prose — use ~ / $HOME.
- ❌ Don't document `agent-browser close` as a release — it's disconnect-only (PRD §2.5).
- ❌ Don't duplicate AGENTS.md (agent operating rules) — link it.
- ❌ Don't touch `.gitignore` (that's P1.M10.T1.S2), `PRD.md`, `tasks.json`, or any code.
- ❌ Don't leave the "Status: Design / brainstorm" line — it's now false.

---

## Confidence Score

**9/10** for one-pass success. The task is pure documentation with all authoritative facts
already extracted verbatim into `research/readme-facts.md` (env table, output formats,
lifecycle, cutover warning, repo layout). The only residual risk is a copy drift between the
README's tables and the tool's `--help` — mitigated by the Level-2 diff validation gate. No
code is touched, so there is no behavioral/regression risk; the worst case is a wording
polish round, not a reimplementation.
