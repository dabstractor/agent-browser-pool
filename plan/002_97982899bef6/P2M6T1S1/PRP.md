# PRP — P2.M6.T1.S1: Complete rewrite of README.md for the no-shadow model

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `install.sh` + `.agents/skills/**`).
**Work item**: P2.M6.T1.S1 (2 points) — milestone P2.M6 (Sync Changeset-Level Documentation), task T1.
**DOCS mode**: **[Mode B]** — this IS the changeset-level documentation sync task (per PRD §5 Mode B).
  It summarizes the entire P2 pivot delta in the top-level `README.md`.
**Dependency / starting state**: The **full pivoted codebase is shipped** — all P2.M1–M5 subtasks are
  done (lib/pool.sh has no `POOL_DISABLE` + fail-fast no-pi-ancestor + preflight; `bin/agent-browser`
  shim is DELETED; `bin/agent-browser-pool` is the sole entry point; `install.sh` is the benign
  3-step installer; `.agents/skills/agent-browser-pool/SKILL.md` + `references/configuration.md` +
  `README.md` are rewritten; `test/*` is updated). **This item edits exactly ONE file:
  `README.md` (repo root). ZERO code changes — documentation only.**

---

## Goal

**Feature Goal**: Replace the current 373-line `README.md` — which describes the **obsolete
PATH-shadowing model** ("transparent PATH-shadowing wrapper", cutover warning, `~/scripts` symlink,
`AGENT_BROWSER_POOL_DISABLE` safety valve, static `master-profile` template) — with a README that
accurately describes the **shipped no-shadow explicit-invocation model** (PRD §2.17 / §1.3): the
command `agent-browser-pool <verb> <args>` is the sole, invariant entry point; the lane is selected
by the caller's process identity, never an argument; profiles are ephemeral CoW copies of the real
Chrome user-data-dir; install is three benign steps with no cutover. A new user reading it would
install via `install.sh` and run `agent-browser-pool open <url>`.

**Deliverable**: A rewritten `README.md` at the repo root whose every section reflects the shipped
artifacts (`install.sh`, `bin/agent-browser-pool`, `lib/pool.sh`, `.agents/skills/agent-browser-pool/`),
contains **zero** obsolete-model prose, and passes the deterministic grep-based content +
consistency gates in §Validation Loop.

**Success Definition** (all must hold — see §Validation Loop for exact commands):
- Every obsolete phrase reaches **0** hits in README.md: `PATH-shadow`, `transparent wrapper`,
  `transparent PATH`, `cutover`, `~/scripts`, `AGENT_BROWSER_POOL_DISABLE`, `safety valve`,
  `master-profile`, `all-or-nothing`.
- The new-model title/tagline + bullet points (Not a fork / Ephemeral profiles / 1 agent = 1 browser /
  Explicit invariant command) are present.
- The env-var table has **no** `AGENT_BROWSER_POOL_DISABLE` row and `AGENT_CHROME_MASTER` defaults to
  the real Chrome user-data-dir.
- The install section describes the 3 benign steps + single-symlink uninstall; the repo-layout block
  shows `bin/` with ONLY `agent-browser-pool`.
- No-pi-ancestor is described as **fail-fast**, not passthrough.
- `agent-browser-pool` (not `agent-browser`) is the documented command everywhere.
- Only `README.md` is modified by this item.

---

## User Persona

**Target User**: Two audiences, both served by ONE README:
1. **A human operator** installing/administering the pool (reads Prerequisites, Installation,
   Admin commands, Configuration, Troubleshooting, Architecture).
2. **An AI agent** (or its author) that needs the 10-second mental model of `agent-browser-pool`
   (reads the title/tagline + bullet points + Quick start, then is pointed at the skill
   `.agents/skills/agent-browser-pool/SKILL.md` for the procedural contract).

**Use Case**: A new user clones the repo, runs `./install.sh`, then an agent (or human under `pi`)
runs `agent-browser-pool open https://example.com` and gets a dedicated, logged-in, isolated Chrome.

**User Journey**:
1. Read the title + 4 bullet points → understand "this gives each agent its own Chrome, via one
   invariant command, by copying my real Chrome profile per-use."
2. Check Prerequisites (btrfs, real Chrome profile, `agent-browser` ≥ 0.28, `google-chrome-stable`).
3. Run `./install.sh` → see it do 3 benign things + run `doctor`.
4. (Agent) run `agent-browser-pool open <url>`; (Human) run `agent-browser-pool status` / `doctor`.
5. On any confusion → Troubleshooting (pool exhaustion, leaks, no-pi fail-fast).

**Pain Points Addressed**: The current README actively MISLEADS — it documents a model (PATH
shadowing, cutover, DISABLE safety valve, `master-profile` template) that **no longer exists**.
Following it (e.g. `export AGENT_BROWSER_POOL_DISABLE=1`, or expecting `<repo>/bin/agent-browser`)
would fail or do the wrong thing. The rewrite makes the README truthful again.

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21 — "There is **no PATH shadowing** … `agent-browser-pool` (the
  sole entry point)"), §1.3 (h3.2 — Goals: explicit invariant invocation), §2.11 (h3.15 — config:
  `AGENT_CHROME_MASTER` default = real Chrome dir; `AGENT_BROWSER_POOL_DISABLE` removed), §2.12
  (h3.16 — CLI), §2.16 (h3.20 — dependencies), §4 (h2.3 — Decision O5: no PATH shadowing; O6:
  invariant command, identity-keyed lanes).
- **Who it helps**: every new user/agent that reads the repo's front door. Right now the README is
  the single biggest source of confusion about the post-pivot product (it describes deleted
  components). The skill (SKILL.md) is correct; the README is the stale outlier.
- **Scope cohesion**: Item T1.S1 is the SOLE documentation-sync task of milestone P2.M6 and the
  ONLY top-level README touch in the whole pivot. Its job is the README rewrite — full stop. It does
  NOT touch `PRD.md`, `AGENTS.md`, `install.sh`, `lib/pool.sh`, `bin/*`, `.agents/skills/**`
  (SKILL.md/configuration.md/skill-README were rewritten in P2.M4), `test/*` (P2.M5), or any
  `plan/**` file. Those are shipped/owned by other items.

---

## What

**User-visible behavior**: The README's CONTENT changes end-to-end. The shipped PRODUCT does not
change at all (zero code edits). The README's *structure* largely follows the existing section
skeleton (Status → Prerequisites → Installation → Usage → Admin commands → Configuration → How it
works → Troubleshooting → Repository layout) but every section's PROSE is rewritten to the new model
per the item contract (points a–k below).

### The item contract (points a–k) — the README MUST contain exactly this

- **(a) Title + tagline**: `# \`agent-browser-pool\`` then the tagline **"dedicated Chrome profile
  lanes for AI agents, via a single invariant command."** — NOT "transparent PATH-shadowing wrapper".
  Keep the one-line lead-in + link to `PRD.md` (unchanged file). The 4 bullet points become:
  1. **Not a fork** — a thin bash wrapper + the `agent-browser-pool` CLI; the real `agent-browser` is
     called by absolute path and stays upgradable.
  2. **Ephemeral profiles** — each acquire **copy-on-writes** a fresh profile from your **REAL
     Chrome profile** (default `~/.config/google-chrome`), deleted on release. (NOT `master-profile`.)
  3. **1 agent = 1 browser** — mutual exclusion via leases keyed on the owning `pi` process.
  4. **Explicit invariant command** — agents run `agent-browser-pool <verb> <args>`; the lane is
     selected by process identity, never an argument.
- **(b) [covered by (a) bullets]**.
- **(c) Status**: **"MVP V2 — explicit invocation model (no PATH shadowing)."** (replaces "MVP
  shipped — transparent wrapper …"). May note the components are implemented + tested.
- **(d) Prerequisites** (exactly these 4, in order):
  1. **btrfs** at the pool root (`~/.agent-chrome-profiles/active`). Non-btrfs → pool refuses the
     ~4.8 GB copy unless `AGENT_CHROME_ALLOW_SLOW_COPY` is set.
  2. **Real Chrome profile** at `~/.config/google-chrome` (or set `AGENT_CHROME_MASTER` to any
     user-data-dir). It may be live/in-use; the pool treats it as read-only (never launched/written/
     deleted).
  3. **`agent-browser` ≥ 0.28** at `~/.local/bin/agent-browser` (hard runtime dependency; supplies
     `--session`, `connect`, `get cdp-url`, `AGENT_BROWSER_SESSION`). Stays upgradable.
  4. **`google-chrome-stable`** (or whatever `$AGENT_CHROME_BIN` points at).
  Plus the coreutils/util-linux/procps tools list + "run `agent-browser-pool doctor`".
- **(e) Installation**: `install.sh` does **three benign things** — (1) symlinks
  `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool`, (2) pre-creates the state dir
  (`lanes/` + `acquire.lock`), (3) runs `doctor`. **NO cutover warning.** State explicitly:
  "Because there is no PATH shadowing, installing cannot disrupt running agents." Usage:
  `./install.sh`, `./install.sh --help` (note `--force`/`-f` exists but is a no-op). **Uninstall**:
  `rm -f ~/.local/bin/agent-browser-pool` (ONE symlink).
- **(f) Quick start**: `agent-browser-pool open https://example.com` — "your lane, the same browser
  for the whole session." One fenced block.
- **(g) Commands section**: show `agent-browser-pool` for BOTH driving commands AND admin verbs.
  Include an example table/section per PRD §2.12 (pool verbs: `status`/`reap`/`release [<N>|all]`/
  `doctor`/`help`; driving: `open`/`screenshot`/`close`/`get cdp-url`/`click`/`type`/`eval`/`find`/…).
  Mirror the shipped `pool_admin_help` output (§All Needed Context → Documentation).
- **(h) Configuration**: the full env-var table (§All Needed Context → the 10-row table). Default
  for `AGENT_CHROME_MASTER` = real Chrome dir. **NO `AGENT_BROWSER_POOL_DISABLE` row.**
- **(i) Admin commands**: `status` / `reap` / `release [<N>|all]` / `doctor` — same capabilities as
  before but invoked through `agent-browser-pool` (the README already used these verbs; keep the
  status/doctor output examples, corrected for the `[master]` = real-Chrome-dir meaning).
- **(j) Architecture**: describe `lib/pool.sh` + `bin/agent-browser-pool` (sole entry point); the
  real `agent-browser` is called by **absolute path** (`$AGENT_BROWSER_REAL`). The repo-layout block
  must show `bin/` with ONLY `agent-browser-pool` (the `agent-browser` shim is gone).
- **(k) Remove ALL references to**: `PATH-shadowing`, `transparent wrapper`, `cutover`, `~/scripts`,
  `AGENT_BROWSER_POOL_DISABLE`, `safety valve`, `master-profile`. (Also drop `all-or-nothing` and the
  "human terminal → passthrough" no-pi-ancestor behavior; no-pi is now fail-fast — see (b) of §Known
  Gotchas.)

### Success Criteria

- [ ] Title/tagline = "dedicated Chrome profile lanes for AI agents, via a single invariant command."
- [ ] 4 bullet points present (Not a fork / Ephemeral from REAL Chrome / 1 agent = 1 browser /
      Explicit invariant command).
- [ ] Status = "MVP V2 — explicit invocation model (no PATH shadowing)".
- [ ] Prerequisites = the 4 shipped items (btrfs / real Chrome profile / agent-browser ≥ 0.28 /
      google-chrome-stable).
- [ ] Installation = 3 benign things + "cannot disrupt running agents" + 1-symlink uninstall.
- [ ] Commands section shows `agent-browser-pool` for BOTH driving + admin verbs (mirrors `help`).
- [ ] Config table has the 10 shipped rows; NO `AGENT_BROWSER_POOL_DISABLE`; `AGENT_CHROME_MASTER`
      default = real Chrome dir.
- [ ] Architecture names `lib/pool.sh` + sole entry point `bin/agent-browser-pool`; real binary by
      absolute path; repo-layout shows `bin/` with ONLY `agent-browser-pool`.
- [ ] No-pi-ancestor described as **fail-fast** (not passthrough).
- [ ] ALL obsolete phrases → 0 hits (see §Validation Loop Level 1).
- [ ] Only `README.md` modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes.** Every fact the README must state is pinned to a **verbatim, first-party**
source below: the shipped `pool_admin_help` output (the canonical command+env reference), the
shipped `pool_admin_doctor`/`pool_admin_status` printf labels, the shipped `pool_config_init`
defaults, the shipped `install.sh` header + steps, and the shipped top-level dispatch in
`bin/agent-browser-pool`. The audit note
(`plan/002_97982899bef6/P2M6T1S1/research/audit-shipped-contract.md`) consolidates all of it. The
item contract (points a–k) fixes the exact section list and bullet wording. The "No Prior Knowledge"
test passes: an implementer can write the README purely from this PRP + `cat`-ing the cited files.

### Documentation & References

```yaml
# MUST READ — the file being rewritten (the deliverable's baseline; ~373 lines of obsolete prose)
- file: README.md
  why: "The CURRENT README. It is the source of EVERY obsolete phrase that must reach 0 (PATH-shadow,
        cutover, ~/scripts, AGENT_BROWSER_POOL_DISABLE, safety valve, master-profile, all-or-nothing,
        'human terminal → passthrough'). Read it fully to know what to replace; then REWRITE, do not
        patch — a near-total rewrite is cleaner than surgical edits across 373 lines."
  pattern: "Keep the SECTION SKELETON (Status/Prerequisites/Installation/Usage/Admin/Config/How it
            works/Troubleshooting/Repo layout) — it is sound; rewrite each section's PROSE."
  gotcha: "The current 'How it works (30-second version)' + 'Troubleshooting → It didn't do
           anything' sections encode the PASSTHROUGH model (POOL_DISABLE / META / no-pi → passthrough).
           The no-pi case is now FAIL-FAST; POOL_DISABLE is GONE. Rewrite both sections."

# MUST READ — the canonical command + env-var reference (verbatim output of `agent-browser-pool help`)
- file: lib/pool.sh   function pool_admin_help   (line 4592)
  why: "This IS the user-facing command + configuration reference. The README's Commands + Configuration
        sections should mirror it (status/reap/release/doctor/help + driving; the 10 env vars with
        defaults). Cite or paraphrase faithfully — do not invent vars or defaults."
  critical: "Defaults printed there (PORT_BASE=53420, PORT_RANGE=1000, WAIT=600) MUST match the README's
             config table. AGENT_CHROME_MASTER default text = '~/.config/google-chrome — your real
             Chrome user-data-dir'. There is NO AGENT_BROWSER_POOL_DISABLE line."

# MUST READ — the authoritative config defaults (the README's config table is a UI over these)
- file: lib/pool.sh   function pool_config_init   (line ~132)
  why: "Source of truth for every env-var default. AGENT_CHROME_MASTER default =
        ${XDG_CONFIG_HOME:-~/.config}/google-chrome (REAL Chrome dir). AGENT_BROWSER_REAL default =
        ~/.local/bin/agent-browser. PORT_BASE=53420, PORT_RANGE=1000, WAIT=600. No POOL_DISABLE var
        is read or set anywhere."
  critical: "If any default in your README draft disagrees with this function, the README is wrong.
             Cross-check (§Validation Level 1 does this automatically)."

# MUST READ — the entry-point dispatch (drives the README's 'Commands' classification)
- file: bin/agent-browser-pool   (25 lines)
  why: "The top-level `case`: status|reap|release|doctor|--help|-h|help → pool_admin_*; *) →
        pool_wrapper_main. Default (no args) = status. This is why --help/-h/help are POOL VERBS
        (→ pool_admin_help), NOT meta-passthrough, and why a bare invocation = status."
  critical: "The OLD README treated --help/--version as META passthrough. That is WRONG now for
             --help (it's a pool verb). Only --version is still meta. Get this right in 'Commands'."

# MUST READ — meta-vs-driving classification (drives the README's 'How it works' + 'Usage')
- file: lib/pool.sh   function pool_dispatch_classify
  why: "META (passthrough, no lane): --version; skills/dashboard/plugin/mcp; session list;
        flags-only/no-subcommand. DRIVING (acquire lane): everything else incl. unrecognized tokens.
        This is the authoritative list — mirror it in the README's 'Which commands trigger a lane'."
  critical: "Do NOT list --help/-h as meta in the README — they are pool verbs (caught earlier).
             'session list' (two words) is meta; bare 'session' is NOT."

# MUST READ — the install behavior (drives the README's 'Installation' section verbatim)
- file: install.sh
  why: "Header comment states the 3 benign things. ln -sfnv to ~/.local/bin (NOT ~/scripts).
        pool_state_init pre-creates lanes/+acquire.lock. Runs doctor as subprocess. --force/-f is a
        documented NO-OP. Help says 'NO PATH interception'. Uninstall = rm -f ~/.local/bin/agent-browser-pool."
  critical: "NO YES-gate, NO cutover warning, NO ~/scripts, NO PATH-ordering check. If your README
             'Installation' section contains any of those, it is wrong."

# SHOULD READ — the agent contract (the README's 'Usage' should point agents here)
- file: .agents/skills/agent-browser-pool/SKILL.md
  why: "The procedural 'how to use your lane' guide (P2.M4 rewrite). The README's Usage gives the
        10-second version + a pointer to this skill for the full contract. Steal the exact invariant
        phrasing: 'The command never names a lane.'"
  pattern: "SKILL.md already uses the correct vocabulary (agent-browser-pool, identity-keyed, fail-fast
            no-pi, close=disconnect). Keep the README consistent with it."

# SHOULD READ — the detailed reference (the README's 'Configuration' links here for depth)
- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: "The 10-row env table, the dispatch table, the acquire lifecycle, and the troubleshooting matrix
        — all already correct for the new model (P2.M4). The README's Config/Troubleshooting should be
        consistent with this (the README is the summary; configuration.md is the detail)."
  critical: "configuration.md has NO AGENT_BROWSER_POOL_DISABLE row and AGENT_CHROME_MASTER default =
             real Chrome dir. The README must match."

# SHOULD READ — the exact change list for THIS file
- contract: plan/002_97982899bef6/architecture/gap_analysis.md   §12
  why: "§12 (README.md — COMPLETE REWRITE) lists: remove PATH-shadow language; change examples to
        agent-browser-pool <verb>; update install (no ~/scripts, no cutover); remove
        AGENT_BROWSER_POOL_DISABLE; update source-profile default (real Chrome dir); update failure
        modes/troubleshooting. This is the authoritative change list for the deliverable."

# SHOULD READ — the consolidated first-party audit (all verified facts in one place)
- docfile: plan/002_97982899bef6/P2M6T1S1/research/audit-shipped-contract.md
  why: "Consolidates verbatim: the sole-entry-point dispatch, the meta/driving/admin classification,
        install.sh's 3 steps, the 10-row env table with shipped defaults, the pool_admin_help output,
        the doctor section labels, the status table format, the fail-fast no-pi behavior, and the
        exact obsolete-phrase hit counts that must reach 0. Cite this rather than re-deriving."

- prd: PRD §2.17 (h3.21), §2.11 (h3.15), §2.12 (h3.16), §1.3 (h3.2), §2.16 (h3.20), §2.7 (h3.11), §4 (h2.3)
  why: "The product source of truth for the model. §2.17 = no PATH shadowing / sole entry point;
        §2.11 = config (incl. AGENT_BROWSER_POOL_DISABLE removed); §2.12 = CLI verbs; §1.3 = goals;
        §2.16 = dependencies; §2.7 = source-profile hygiene (live/in-use OK, read-only); §4 = decisions
        O5/O6 (no shadow; invariant command)."
```

### Current codebase tree (relevant slice — verified on disk)

```bash
agent-browser-pool/
├── README.md                  ← THIS FILE (the deliverable; 373 lines of OBSOLETE prose to rewrite)
├── PRD.md                     ← READ-ONLY (product spec; link to it, don't duplicate)
├── AGENTS.md                  ← READ-ONLY (agent operating rules; README links to it at the bottom)
├── install.sh                 ← SHIPPED (benign 3-step installer — the README 'Installation' source)
├── bin/
│   ├── agent-browser-pool     ← SHIPPED sole entry point (the README 'Commands'/'Architecture' source)
│   └── .gitkeep               ← (bin/agent-browser shim is DELETED — README must NOT reference it)
├── lib/
│   └── pool.sh                ← SHIPPED (pool_admin_help/doctor/status/config_init — the README's facts)
├── .agents/skills/agent-browser-pool/
│   ├── SKILL.md               ← SHIPPED (agent contract — README 'Usage' points here)
│   ├── README.md              ← SHIPPED (skill overview — NOT this PRP's target)
│   └── references/
│       └── configuration.md   ← SHIPPED (detailed config/dispatch/troubleshooting — README 'Config' depth)
└── test/                      ← SHIPPED (validate/concurrency/release_reaper/transparency — NOT referenced by README)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── README.md   ← REWRITTEN (the sole deliverable): accurate no-shadow explicit-invocation model.
                  No new files. No deletions. No code changes. Every other file UNTOUCHED.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL — no-pi-ancestor is FAIL-FAST, NOT passthrough. The OLD README's "Note for humans: from a
#   plain terminal with no pi ancestor, the wrapper passes through to the real agent-browser" is WRONG.
#   pool_wrapper_main step d (gap_analysis §1b Change 2) does:
#     pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
#              "For raw browser use without pooling, call 'agent-browser' directly."
#   The README's Usage + Troubleshooting MUST say fail-fast. (Pool verbs status/doctor/reap/release/help
#   work from any shell — they run in the top-level case before owner resolution. META commands also
#   passthrough before the no-pi check. ONLY driving commands fail-fast without pi.)

# CRITICAL --help / -h / help are POOL VERBS, NOT meta. The OLD README grouped --help/--version as META
#   passthrough. Now: the entry-point `case` catches --help|-h|help → pool_admin_help (prints pool help,
#   never reaches the real binary). ONLY --version is still meta (not in the top-level case). A bare
#   `agent-browser-pool` (no args) defaults to `status`. Get the 'Commands' classification right.

# CRITICAL — AGENT_BROWSER_POOL_DISABLE does not exist. Do NOT add an env-var row for it, do NOT mention
#   a "safety valve", do NOT include a "Safety valve" section. The OLD README had a whole section for it
#   (~lines 232-247) — delete that section entirely.

# CRITICAL — the source profile is the REAL Chrome dir, NOT master-profile. AGENT_CHROME_MASTER default
#   = ${XDG_CONFIG_HOME:-~/.config}/google-chrome. It may be LIVE/IN-USE (agents copy current state each
#   acquire → new logins propagate); the pool treats it as READ-ONLY (never launched/written/deleted).
#   Remove every "~/.agent-chrome-profiles/master-profile" reference and the "Never launch Chrome
#   directly against master-profile: it is a static template" note (that template no longer exists).

# CRITICAL — install target is ~/.local/bin, NOT ~/scripts. ONE symlink
#   (~/.local/bin/agent-browser-pool). Uninstall = `rm -f ~/.local/bin/agent-browser-pool` (ONE path,
#   not two). The OLD README's `rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool` is WRONG.

# CRITICAL — bin/ has ONLY agent-browser-pool. The OLD README's repo-layout block listed BOTH
#   bin/agent-browser (wrapper) and bin/agent-browser-pool. The shim is DELETED. Show ONLY
#   agent-browser-pool (+ .gitkeep). Do NOT tell users to "test before cutover by invoking the wrapper
#   by absolute path <repo>/bin/agent-browser open …" — that file does not exist.

# GOTCHA — keep legitimate uses of 'wrapper'/'passthrough'/'transparent'. pool_wrapper_main is a real
#   internal symbol; META commands genuinely 'pass through' to the real binary. Use these words where
#   ACCURATE (META), but NEVER describe the overall tool as 'a transparent PATH-shadowing wrapper'.
#   The validation gate is the PHRASE 'transparent wrapper'/'PATH-shadow' → 0, NOT the word 'wrapper' → 0.

# GOTCHA — the [master] doctor section LABEL is unchanged (doctor still prints '[master]'). But it now
#   checks $AGENT_CHROME_MASTER (default real Chrome dir) exists + non-empty, NOT a master-profile
#   template. In the README's doctor subsection, describe it as 'the source/master profile' and show the
#   shipped OK/FAIL text; do NOT resurrect the master-profile path in the example.

# GOTCHA — 'wrapper' appears in 'thin bash wrapper' (bullet 1: 'Not a fork — a thin bash wrapper + the
#   agent-browser-pool CLI'). That is CORRECT and REQUIRED by item point (a). The gate excludes it
#   because the gate targets the PHRASE 'transparent wrapper', not the bare word 'wrapper'.

# GOTCHA — PRD section anchors. The OLD README linked 'PRD.md §2.17' for 'cutover & coexistence' and
#   'PRD.md §2.12' for 'command list'. §2.17 is now 'Install (no cutover danger)'; keep the §2.17 link
#   but fix the link text. Verify any §-anchor text matches the current PRD.md section titles.

# GOTCHA (AGENTS.md §1/§6) — validation is STATIC ONLY: grep/read/git. Do NOT run install.sh, do NOT
#   run agent-browser-pool doctor/status, do NOT boot Chrome. The shipped artifacts are the source of
#   truth; the README documents them, it does not execute them.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item rewrites one Markdown file. The "structure" is the README's
section skeleton (kept) + per-section prose (rewritten). The exact section list + bullet wording is
fixed by the item contract (points a–k, reproduced in §What). No code, no schemas.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ANCHOR — read the shipped artifacts (no writes)
  - READ: README.md (current; the baseline of obsolete prose — know what you are replacing).
  - READ (verbatim): lib/pool.sh pool_admin_help (line 4592) — the canonical command+env reference.
  - READ: lib/pool.sh pool_config_init — the shipped env-var defaults (cross-check any draft table).
  - READ: bin/agent-browser-pool — the top-level dispatch (status default; --help/-h/help = pool verb;
          *) → driving).
  - READ: install.sh — the 3 benign steps + uninstall.
  - SKIM: .agents/skills/agent-browser-pool/SKILL.md + references/configuration.md — steal exact
          invariant phrasing + confirm the env table / troubleshooting matrix to stay consistent.
  - CONFIRM (read-only): bin/ has ONLY agent-browser-pool (no agent-browser shim); no POOL_DISABLE
          var anywhere in lib/pool.sh.
  - WHY: pin every fact the README states to a first-party source so the rewrite is truthful.

Task 2: WRITE the new README.md (single `write` — near-total rewrite, NOT surgical edits)
  - DECIDE: rewrite the whole file with `write` (cleaner than 15+ disjoint `edit`s across 373 lines).
  - FOLLOW the section skeleton (Status/Prerequisites/Installation/Usage/Admin commands/Configuration/
          How it works/Troubleshooting/Repository layout) but rewrite EVERY section's prose to the new
          model per item contract (a)-(k) reproduced in §What.
  - MIRROR pool_admin_help for the Commands + Configuration sections (verbatim paraphrase; do not
          invent vars/defaults).
  - POINT agents to .agents/skills/agent-browser-pool/SKILL.md from Usage; link configuration.md from
          Configuration for depth; link PRD.md + AGENTS.md as before.
  - WHY: this is the deliverable. One coherent write beats stitch-edits for a model pivot.

Task 3: STATIC VALIDATION (AGENTS.md §1: static only — NO execution)
  - RUN the §Validation Loop Level 1 gate block (obsolete phrases → 0; required phrases present;
          env-table cross-check vs pool_admin_help; markdown sanity).
  - RUN: git status --short (expect ONLY README.md modified).
  - WHY: contract step 4 (OUTPUT) + AGENTS.md §1/§6. No Chrome, no install, no agent-browser-pool run.
  - BUCKET: required.

Task 4: SELF-REVIEW against item contract (a)-(k)
  - WALK the checklist in §Final Validation Checklist (Feature Validation) — tick each box against
          the written README.
  - WHY: the item contract is unusually prescriptive; a line-by-line check guarantees nothing is missed.
  - BUCKET: required.
```

### Implementation Patterns & Key Details

```markdown
# PATTERN — the title + tagline block (item a). EXACT wording:
#   # `agent-browser-pool`
#
#   **dedicated Chrome profile lanes for AI agents, via a single invariant command.**
#
#   Then a 1-2 sentence lead-in + a link: "See [PRD.md](./PRD.md) for the full product
#   requirements and technical spec." Then the 4 bullets (item a). NOT "transparent wrapper".

# PATTERN — the 4 bullets (item a). The 4th is the model's heart; lead with the invariant:
#   - **Not a fork.** A thin bash wrapper + the `agent-browser-pool` CLI. The real
#     `agent-browser` is called by absolute path and stays upgradable.
#   - **Ephemeral profiles.** Each acquire copy-on-writes a fresh profile from your **real
#     Chrome profile** (default `~/.config/google-chrome`) and deletes it on release. Because
#     the pool lives on **btrfs**, `cp --reflink=always` makes every copy instant and deduplicated.
#   - **1 agent = 1 browser.** Mutual exclusion via leases keyed on the owning `pi` process.
#     The next agent gets the next free lane.
#   - **Explicit invariant command.** Agents run `agent-browser-pool <verb> <args>`; the lane
#     is selected by the caller's process identity, never an argument. The command is identical
#     on lane 1 or lane 99.

# PATTERN — Installation (item e). Lead with "three benign things" + the safety guarantee:
#   `install.sh` does three benign things — NO PATH interception, so installing cannot disrupt
#   running agents:
#     1. symlinks `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool` (sole entry point);
#     2. pre-creates the pool state dir (`lanes/` + `acquire.lock`);
#     3. runs `doctor` to verify the real `agent-browser` ≥ 0.28, Chrome, btrfs, and the source profile.
#   Then usage fenced block: ./install.sh ; ./install.sh --help (note --force/-f is a no-op).
#   Then: "Uninstall: `rm -f ~/.local/bin/agent-browser-pool`." (ONE symlink.)
#   NO cutover warning. NO ~/scripts. NO YES gate.

# PATTERN — Commands (item g). Two groups under `agent-browser-pool`:
#   Pool verbs (operator/read-only): status | reap | release [<N>|all] | doctor | help (--help, -h)
#   Driving (agent): open <url> | screenshot | close [--all] | get cdp-url | click | type | eval | find | ...
#   State: "Any token that isn't a pool verb is a DRIVING command routed to YOUR lane (chosen by your
#   identity, never an argument)." Mirror pool_admin_help's wording.

# PATTERN — Configuration (item h). Render the 10-row table from §audit §4 / pool_config_init.
#   CRITICAL rows:
#     AGENT_CHROME_MASTER | ${XDG_CONFIG_HOME:-~/.config}/google-chrome | CoW source (your REAL Chrome
#        user-data-dir); read-only to the pool; may be live/in-use.
#     AGENT_BROWSER_REAL  | ~/.local/bin/agent-browser | the REAL CLI; called by absolute path.
#   NO AGENT_BROWSER_POOL_DISABLE row. Mention test-only hooks (OWNER_PID/OWNER_STARTTIME) as
#   "not for users".

# PATTERN — How it works (rewritten). Replace the OLD passthrough tree with the fail-fast model:
#   agent-browser-pool open <url>        ← agent types this, nothing else
#      │ 1. classify: pool verb? → run it (no lane). meta? → passthrough to real binary (no lane).
#      │ 2. else DRIVING: resolve owning pi PID (+ starttime); no pi → FAIL-FAST (not passthrough).
#      ├─ already hold my lease? reuse my lane
#      ├─ else acquire: reap-stale → reuse-orphan OR cp --reflink master(real Chrome)→ephemeral
#      │                 → launch Chrome (setsid pgroup, anti-throttle) → connect daemon
#      ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
#      └─ exec the real agent-browser with cleaned args
#   Then: "Release happens when the owning pi exits (next acquire reaps it), on explicit
#   `agent-browser-pool release`, or on pool-exhaustion force-reap. close mid-task is disconnect-only."

# PATTERN — Troubleshooting (rewritten). Mirror configuration.md's matrix. REMOVE the OLD
#   "It didn't do anything / wrong browser → caused by POOL_DISABLE or no-pi passthrough" entry.
#   REPLACE no-pi entry with: "Driving command errored 'requires a pi ancestor' → by design; run
#   browser work under pi, or call agent-browser directly for raw access." Keep pool-exhaustion +
#   leaks (reap/release/doctor) entries (still accurate).

# PATTERN — Repository layout (rewritten). bin/ shows ONLY agent-browser-pool:
#   ├── bin/
#   │   └── agent-browser-pool     ← sole entry point: pool verbs + driving router  (→ lib/pool.sh)
#   Add the .agents/skills/agent-browser-pool/ subtree (SKILL.md, references/configuration.md).
#   install.sh comment: "benign 3-step installer (symlink + state dir + doctor)". Remove "cutover".
#   Runtime state note: source = ~/.config/google-chrome (or $AGENT_CHROME_MASTER); ephemeral =
#   ~/.agent-chrome-profiles/active/<N>/. Remove "master-profile/ (static template)".
```

### Integration Points

```yaml
NONE for this item beyond README.md.
  - This item CONSUMES (does not modify) the shipped artifacts it documents:
      * install.sh, bin/agent-browser-pool, lib/pool.sh — the product the README describes.
      * .agents/skills/agent-browser-pool/{SKILL.md,references/configuration.md,README.md} — the
        detailed agent docs the README links to / stays consistent with.
      * PRD.md, AGENTS.md — linked from the README (unchanged).
  - Sibling context (P2.M5.T3.S1, in flight): comment-only edits to test/concurrency.sh +
    release_reaper.sh. ZERO overlap with this item (different files; that item touches test/* only).
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`grep`, `awk`, `git`, `read`). **Do NOT run
> `./install.sh`, do NOT run `agent-browser-pool doctor`/`status`, do NOT boot Chrome during this
> item.** The shipped artifacts are the source of truth; the README documents them. There is no
> pytest/shellcheck for Markdown — the gates below are DETERMINISTIC content + consistency checks,
> which is the correct validation level for a docs-only task.

### Level 1: Content & consistency gates (run after the rewrite)

```bash
cd /home/dustin/projects/agent-browser-pool

# ──────────────────────────────────────────────────────────────────────────
# (1) OBSOLETE-PHRASE REMOVALS — each MUST print 0 (phrase-based, not word-based)
# ──────────────────────────────────────────────────────────────────────────
fail=0
for phrase in 'PATH-shadow' 'transparent wrapper' 'transparent PATH' 'cutover' \
              '~/scripts' 'AGENT_BROWSER_POOL_DISABLE' 'safety valve' \
              'master-profile' 'all-or-nothing'; do
  n=$(grep -cE -- "$phrase" README.md || true)
  if [ "$n" -eq 0 ]; then
    echo "OK: '$phrase' removed (0 hits)"
  else
    echo "FAIL: '$phrase' still appears $n time(s):"; grep -nE -- "$phrase" README.md; fail=1
  fi
done
# 'passes through to the real' in the no-pi/human sense must be gone (META passthrough is OK —
# the gate is the specific phrase used by the OLD README's "human terminal" note).
n=$(grep -cE 'passes? through to the real' README.md || true)
[ "$n" -eq 0 ] && echo "OK: no 'passes through to the real' (no-pi passthrough prose gone)" \
  || { echo "FAIL: no-pi passthrough prose remains"; grep -nE 'passes? through to the real' README.md; fail=1; }

# ──────────────────────────────────────────────────────────────────────────
# (2) REQUIRED NEW-MODEL PHRASES — each MUST be present (≥1)
# ──────────────────────────────────────────────────────────────────────────
for phrase in 'agent-browser-pool' 'invariant command' 'pi ancestor' \
              'Ephemeral' 'CoW' 'identity' 'read-only'; do
  n=$(grep -cEi -- "$phrase" README.md || true)
  [ "$n" -ge 1 ] && echo "OK: '$phrase' present ($n)" \
    || { echo "FAIL: '$phrase' MISSING"; fail=1; }
done
# Title + tagline (item a) — exact-ish wording
grep -qE '^# `agent-browser-pool`' README.md && echo "OK: title is '# \`agent-browser-pool\`'" \
  || { echo "FAIL: title line missing/wrong"; fail=1; }
grep -qiE 'dedicated Chrome profile lanes for AI agents.*single invariant command' README.md \
  && echo "OK: tagline present" || { echo "FAIL: tagline (item a) missing/wrong"; fail=1; }
grep -qiE 'MVP V2.*explicit invocation model' README.md \
  && echo "OK: Status = MVP V2 explicit invocation" || { echo "FAIL: Status line (item c) missing"; fail=1; }

# ──────────────────────────────────────────────────────────────────────────
# (3) CONFIG TABLE CONSISTENCY vs the shipped pool_admin_help / pool_config_init
# ──────────────────────────────────────────────────────────────────────────
# No DISABLE row anywhere (belt-and-suspenders with gate 1):
grep -qiE 'AGENT_BROWSER_POOL_DISABLE' README.md \
  && { echo "FAIL: AGENT_BROWSER_POOL_DISABLE row/text present"; fail=1; } || echo "OK: no DISABLE row"
# AGENT_CHROME_MASTER default = real Chrome dir (NOT master-profile):
grep -qE 'AGENT_CHROME_MASTER.*google-chrome' README.md \
  && echo "OK: AGENT_CHROME_MASTER default = real Chrome dir" \
  || { echo "FAIL: AGENT_CHROME_MASTER default not the real Chrome dir"; fail=1; }
# The shipped defaults must appear (cross-check vs pool_admin_help):
for def in '53420' '1000' '600' 'google-chrome-stable' '~/.local/bin/agent-browser'; do
  grep -qF -- "$def" README.md && echo "OK: shipped default '$def' present" \
    || { echo "FAIL: shipped default '$def' missing from config table"; fail=1; }
done

# ──────────────────────────────────────────────────────────────────────────
# (4) NO-PI = FAIL-FAST (not passthrough) — the single most common rewrite error
# ──────────────────────────────────────────────────────────────────────────
grep -qiE 'fail.?fast|requires? a pi ancestor' README.md \
  && echo "OK: no-pi-ancestor described as fail-fast" \
  || { echo "FAIL: no-pi fail-fast not documented (still passthrough?)"; fail=1; }

# ──────────────────────────────────────────────────────────────────────────
# (5) INSTALL = benign 3-step + 1-symlink uninstall; NO cutover/YES-gate
# ──────────────────────────────────────────────────────────────────────────
grep -qiE 'cannot disrupt running agents|no PATH (interception|shadow)' README.md \
  && echo "OK: install 'cannot disrupt' guarantee present" \
  || { echo "FAIL: install safety guarantee (item e) missing"; fail=1; }
grep -qE 'rm -f ~/.local/bin/agent-browser-pool' README.md \
  && echo "OK: 1-symlink uninstall present" \
  || { echo "FAIL: uninstall should be 'rm -f ~/.local/bin/agent-browser-pool' (ONE path)"; fail=1; }
# Uninstall must NOT mention the deleted ~/scripts path:
grep -qE 'rm -f .*~/scripts' README.md \
  && { echo "FAIL: uninstall still references ~/scripts (deleted)"; fail=1; } || echo "OK: no ~/scripts in uninstall"

# ──────────────────────────────────────────────────────────────────────────
# (6) REPO LAYOUT — bin/ shows ONLY agent-browser-pool (shim deleted)
# ──────────────────────────────────────────────────────────────────────────
# The layout block must list bin/agent-browser-pool and must NOT list bin/agent-browser as a wrapper.
grep -qE 'agent-browser-pool +←.*sole entry point|agent-browser-pool.*sole entry' README.md \
  && echo "OK: layout names agent-browser-pool as sole entry point" \
  || { echo "WARN: layout sole-entry-point label not found (check wording)"; }
grep -qE 'bin/agent-browser +←.*wrapper|agent-browser +←.*PATH-shadow' README.md \
  && { echo "FAIL: layout still lists the DELETED bin/agent-browser wrapper"; fail=1; } \
  || echo "OK: layout does not reference the deleted bin/agent-browser shim"

# ──────────────────────────────────────────────────────────────────────────
# (7) MARKDOWN SANITY — heading depth, code fences balanced, no broken [..](.) links
# ──────────────────────────────────────────────────────────────────────────
fences=$(grep -cE '^```' README.md || true)
(( fences % 2 == 0 )) && echo "OK: code fences balanced ($fences)" \
  || { echo "FAIL: unbalanced code fences ($fences is odd)"; fail=1; }
# Every ](./...) / ](file) link target should resolve (README links to PRD.md, AGENTS.md, the skill)
while IFS= read -r tgt; do
  [ -e "$tgt" ] && echo "OK: link target exists: $tgt" || { echo "FAIL: broken link target: $tgt"; fail=1; }
done < <(grep -oE '\]\(\.?/?[^)]+\)' README.md | sed -E 's/^\]\(//; s/\)$//' | sed -E 's#^\./##' \
          | grep -vE '^https?://' | sed -E 's/#.*//' | sort -u)

echo
[ "$fail" -eq 0 ] && echo "=== ALL LEVEL-1 GATES PASSED ===" || { echo "=== LEVEL-1 GATES FAILED ($fail) — fix before proceeding ==="; exit 1; }
```

**Expected**: all obsolete phrases → 0; all required phrases present; title/tagline/status exact;
no DISABLE row; `AGENT_CHROME_MASTER` default = real Chrome dir; shipped defaults present; no-pi =
fail-fast; install = benign + 1-symlink uninstall; layout shows only `agent-browser-pool`; code fences
balanced; all link targets resolve.

### Level 2: Component Validation — N/A (static by design)

A README has no executable component. There is no unit test for prose. The Level-1 content +
consistency gates are authoritative. (Runtime correctness of the product is unchanged — zero code
edits — and is owned by the shipped artifacts + `test/*`, not by this item.)

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Scope: ONLY README.md modified by THIS item.
git status --short
git status --short | grep -vE '^.{2} README\.md$' | grep . \
  && echo "FAIL: changes outside README.md" || echo "OK: only README.md modified"

# Confirm every shipped artifact the README documents is UNTOUCHED by this item:
for f in install.sh bin/agent-browser-pool bin/.gitkeep lib/pool.sh \
         .agents/skills/agent-browser-pool/SKILL.md \
         .agents/skills/agent-browser-pool/README.md \
         .agents/skills/agent-browser-pool/references/configuration.md \
         PRD.md AGENTS.md test/validate.sh test/concurrency.sh test/release_reaper.sh \
         test/transparency.sh .gitignore; do
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done

# Confirm the shipped facts the README cites still hold (read-only — NO execution):
test -e bin/agent-browser-pool && ! test -e bin/agent-browser \
  && echo "OK: sole entry point confirmed (shim gone — README must not reference bin/agent-browser)" \
  || echo "FAIL: bin state unexpected"
grep -q 'AGENT_BROWSER_POOL_DISABLE' lib/pool.sh \
  && echo "WARN: POOL_DISABLE still in lib/pool.sh (README must still not document it)" \
  || echo "OK: no POOL_DISABLE in lib/pool.sh (README correctly omits it)"
grep -qE 'AGENT_CHROME_MASTER.*google-chrome' lib/pool.sh \
  && echo "OK: lib/pool.sh master default = real Chrome dir (README matches)" \
  || echo "FAIL: lib/pool.sh master default mismatch"

# OPTIONAL (NOT a gate; NEVER run in the shared sandbox — AGENTS.md §1): rendering the README in a
#   browser/markdown previewer to eyeball formatting. This is a human-readability check, not a
#   correctness gate; the Level-1 gates are authoritative.
```

### Level 4: Creative & Domain-Specific Validation — N/A

A docs-only rewrite has no domain runtime beyond Levels 1–3. The one domain-specific concern — that
the README is internally consistent with the shipped skill (`SKILL.md` + `references/configuration.md`)
— is pinned by reading those files in Task 1 and by the consistency gates in Level 1 (env table +
no-pi behavior + command list). No Chrome, no daemons, no suite run.

---

## Final Validation Checklist

### Technical Validation

- [ ] §Validation Loop Level 1 gate block exits 0 (all content + consistency gates pass).
- [ ] §Validation Loop Level 3: `git status --short` shows ONLY `README.md` modified.
- [ ] Every shipped artifact the README documents is UNTOUCHED (install.sh, bin/*, lib/pool.sh,
      `.agents/skills/**`, PRD.md, AGENTS.md, test/*, .gitignore).
- [ ] Validation used ONLY static commands (grep/awk/git/read) — no Chrome, no install, no
      `agent-browser-pool` run (AGENTS.md §1/§6).

### Feature Validation (item contract a–k)

- [ ] **(a)** Title = `# \`agent-browser-pool\``; tagline = "dedicated Chrome profile lanes for AI
      agents, via a single invariant command."; 4 bullets (Not a fork / Ephemeral from REAL Chrome /
      1 agent = 1 browser / Explicit invariant command).
- [ ] **(c)** Status = "MVP V2 — explicit invocation model (no PATH shadowing)".
- [ ] **(d)** Prerequisites = btrfs / real Chrome profile (`~/.config/google-chrome` or
      `AGENT_CHROME_MASTER`) / `agent-browser` ≥ 0.28 / `google-chrome-stable`.
- [ ] **(e)** Installation = 3 benign things + "cannot disrupt running agents" + uninstall
      `rm -f ~/.local/bin/agent-browser-pool`; NO cutover/`~/scripts`/YES-gate.
- [ ] **(f)** Quick start = `agent-browser-pool open https://example.com`.
- [ ] **(g)** Commands section shows `agent-browser-pool` for BOTH driving + admin verbs (mirrors
      `pool_admin_help`).
- [ ] **(h)** Configuration = 10-row env table; NO `AGENT_BROWSER_POOL_DISABLE`; `AGENT_CHROME_MASTER`
      default = real Chrome dir.
- [ ] **(i)** Admin commands (status/reap/release/doctor) via `agent-browser-pool`; doctor `[master]`
      described as the source profile (real Chrome dir).
- [ ] **(j)** Architecture names `lib/pool.sh` + sole entry point `bin/agent-browser-pool`; real
      binary by absolute path; repo-layout shows `bin/` with ONLY `agent-browser-pool`.
- [ ] **(k)** ALL obsolete phrases → 0: `PATH-shadowing`, `transparent wrapper`, `cutover`,
      `~/scripts`, `AGENT_BROWSER_POOL_DISABLE`, `safety valve`, `master-profile`.
- [ ] No-pi-ancestor described as **fail-fast** (not passthrough).

### Code Quality / Scope Validation

- [ ] **Only** `README.md` is modified by this item (one file, docs-only).
- [ ] README is internally consistent with the shipped skill (`SKILL.md` +
      `references/configuration.md`) — same vocabulary, same env table, same no-pi behavior.
- [ ] Env-var defaults in the README match `pool_config_init` / `pool_admin_help` exactly.
- [ ] Command classification matches `bin/agent-browser-pool` dispatch + `pool_dispatch_classify`
      (esp. `--help`/`-h`/`help` = pool verb; `--version` = meta; default = `status`).
- [ ] Code fences balanced; all `](./…)` link targets resolve; heading depth sane.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).

### Documentation & Deployment

- [ ] **[Mode B]** This README IS the changeset-level documentation sync for the P2 pivot — it
      summarizes the entire delta (no PATH shadowing, sole entry point, ephemeral-from-real-Chrome,
      identity-keyed lanes, benign install) at the repo's front door.
- [ ] A new user reading only this README could: run `./install.sh`, then run
      `agent-browser-pool open <url>` and get a dedicated lane — without reading anything else.
- [ ] Links to `PRD.md` (spec), `AGENTS.md` (operating rules), and the skill
      (`.agents/skills/agent-browser-pool/SKILL.md`) are present and correct.

---

## Anti-Patterns to Avoid

- ❌ Don't surgically `edit` 15+ disjoint regions across the 373-line file — the model pivot touches
      nearly every section. Use `write` for a coherent near-total rewrite (keep the section skeleton).
- ❌ Don't describe the tool as a "transparent PATH-shadowing wrapper" anywhere — that model is gone
      (PRD §2.17 / O5). It is an explicit, invariant command.
- ❌ Don't carry over `AGENT_BROWSER_POOL_DISABLE` in any form — no env row, no "safety valve"
      section, no troubleshooting entry. The var does not exist in `lib/pool.sh` anymore.
- ❌ Don't say no-pi-ancestor "passes through to the real agent-browser" — it **fails fast**. Only
      META commands (and pool verbs) work without a `pi` ancestor.
- ❌ Don't group `--help`/`-h`/`help` as META passthrough — they are POOL VERBS (`pool_admin_help`).
      Only `--version` is meta. A bare `agent-browser-pool` defaults to `status`.
- ❌ Don't reference `bin/agent-browser` (the deleted shim) or `~/scripts` or `master-profile` — none
      exist. Install target is `~/.local/bin`; source profile is the real Chrome dir.
- ❌ Don't show a 2-path uninstall — it's ONE symlink: `rm -f ~/.local/bin/agent-browser-pool`.
- ❌ Don't invent env vars or defaults — mirror `pool_config_init` / `pool_admin_help` verbatim. If a
      draft table disagrees with those, the draft is wrong.
- ❌ Don't run `./install.sh`, `agent-browser-pool doctor/status`, or any Chrome during this item —
      static checks only (AGENTS.md §1/§6). The README documents shipped behavior; it doesn't execute it.
- ❌ Don't edit `install.sh`, `lib/pool.sh`, `bin/*`, `.agents/skills/**`, `PRD.md`, `AGENTS.md`,
      `test/*`, or any `plan/**` file — this item touches ONLY `README.md`.
- ❌ Don't blanket-zero the WORDS `wrapper`/`passthrough`/`transparent` — they have legitimate uses
      (pool_wrapper_main is a real symbol; META genuinely passes through; "thin bash wrapper" is a
      required bullet). The gate is the obsolete PHRASES (§Validation Level 1), not the bare words.

---

## Confidence Score

**9 / 10** for one-pass implementation success.

Rationale: the deliverable is a single Markdown rewrite whose exact content is pinned by (a) the
prescriptive item contract (points a–k), (b) verbatim first-party sources for every fact
(`pool_admin_help`, `pool_config_init`, `install.sh`, `bin/agent-browser-pool`,
`pool_dispatch_classify`, the shipped skill), and (c) deterministic grep-based validation gates that
catch the three real failure modes (stale phrase survival, env-table drift, no-pi/passthrough error).
The only residual risk is a stylistic/wording miss the gates don't phrase-match — mitigated by the
explicit "required new-model phrases" gate + the item-contract walkthrough checklist. No code risk
(zero code edits); no sandbox risk (static validation only).
