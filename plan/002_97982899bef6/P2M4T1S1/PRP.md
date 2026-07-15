# PRP — P2.M4.T1.S1: Complete rewrite of SKILL.md — agent-browser-pool as sole command

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`); skill doc is Markdown.
**Work item**: P2.M4.T1.S1 (2 points)
**Dependency / starting state**: Builds on the POST-P2.M2 tree. The core behavior this skill
**teaches** is already SHIPPED and verified in `lib/pool.sh` + `bin/agent-browser-pool`:
`AGENT_BROWSER_POOL_DISABLE` is **fully removed** (P2.M1 complete — `grep` in lib/pool.sh returns
nothing); `pool_wrapper_main` fail-fasts on no-pi-ancestor (P2.M1.T1.S2); `_pool_preflight_real_bin`
guards driving calls (P2.M1.T2.S1); `pool_admin_help` already prints the new "Driving commands"
section + new env list (P2.M1.T3.S1); `bin/agent-browser-pool`'s `*)` arm routes every non-admin
token to `pool_wrapper_main` (P2.M2.T1.S1); the old `bin/agent-browser` PATH-shadow shim is gone
(P2.M2.T2.S1). **This item rewrites exactly ONE file**: `.agents/skills/agent-browser-pool/SKILL.md`
in place. The parallel item **P2.M3.T1.S1** (install.sh) is DISJOINT and its success message already
prints `agent-browser-pool open <url>` examples consistent with this skill.
**Full research notes**: `plan/002_97982899bef6/P2M4T1S1/research/notes.md`

---

## Goal

**Feature Goal**: Replace the current SKILL.md (which teaches the **dead** `agent-browser`
PATH-shadowing model — "transparent wrapper", `AGENT_BROWSER_POOL_DISABLE`, "no pi ancestor →
passthrough", `agent-browser open <url>`) with a SKILL.md that teaches the **live** explicit-
invocation model: `agent-browser-pool <verb> <args>` is the **one invariant browser command**, the
lane is selected by the agent's own process identity and **never named as an argument**, it is **not**
a transparent wrapper but an explicit tool, driving commands outside `pi` **fail fast** (not
passthrough), and every example uses the `agent-browser-pool` command.

**Deliverable**: A rewritten `.agents/skills/agent-browser-pool/SKILL.md` (~115-125 lines) whose
frontmatter `description` is the exact mandated string, whose opening paragraph states the invariant
+ "the command never names a lane", whose five sections (1 Get + connect; 2 Tear down; 3 Safety;
4 Common pitfalls; 5 Reference) all use `agent-browser-pool <verb>` examples, and which contains
**zero** references to `transparent`/`PATH-shadowing`/`AGENT_BROWSER_POOL_DISABLE`/passthrough-as-
human-terminal. The exact final file is provided verbatim in §Implementation Blueprint (a complete
rewrite ⇒ the artifact is the spec). **No other file is modified.**

**Success Definition**:
- `.agents/skills/agent-browser-pool/SKILL.md` exists and is valid Markdown with YAML frontmatter.
- The frontmatter `name: agent-browser-pool` and `description:` equal the exact mandated strings.
- `grep` confirms the REMOVALS: zero matches for `AGENT_BROWSER_POOL_DISABLE`, `transparent`,
  `PATH-shadowing`, `shadowing`, `human terminal`, and the canonical wrong example `agent-browser open`.
- `grep` confirms the ADDITIONS: `agent-browser-pool open`, "The command never names a lane",
  "fails fast"/"pi ancestor", and the meta list (`skills`, `--version`, `session list`,
  `dashboard`, `plugin`, `mcp`).
- The `references/configuration.md` link target exists in the tree.
- **Only** `.agents/skills/agent-browser-pool/SKILL.md` is modified by this item (`git status --short`).

---

## Why

- **PRD alignment**: PRD §2.15 (h3.19) is *literally* "the contract the skill teaches" — it is a
  checklist where the very first item is `agent-browser-pool open <url>` and the invariant is
  "The command is identical no matter which lane I'm on; I never pass a lane/port/session."
  PRD §1.3 goal #1 (h3.2) "Explicit, invariant invocation … The agent does not — and cannot — name a
  lane." PRD §2.4 (h3.8) fixes the entry-point model: `agent-browser-pool <verb>` is the sole router;
  step 1 "No pi ancestor → DRIVING fails fast ('requires a pi ancestor; for raw browser use call
  `agent-browser` directly')". PRD §2.13 (h3.17) carries the non-negotiable safety rules. The current
  SKILL.md teaches the **opposite** of all of these (a shadowing wrapper with a DISABLE safety valve
  and silent human-terminal passthrough). It is actively misleading to any agent that reads it.
- **Who it helps**: Every AI agent that drives a browser through pi. An agent reading the rewritten
  skill will type `agent-browser-pool open <url>` (correct) instead of `agent-browser open <url>`
  (which now either runs the raw unshadowed CLI without lane isolation, or — outside pi — is just the
  real binary). The skill is the single source of truth for the command surface; getting it wrong
  defeats the entire pool.
- **Scope cohesion**: This is item T1 of milestone P2.M4 (Skill & Reference Documentation). Its
  sibling P2.M4.T2.S1 updates `references/configuration.md` in parallel (this skill's §5 points to
  it). The later P2.M6.T1.S1 (README) will mirror this skill's command model. It touches ONLY the
  SKILL.md; `lib/pool.sh`, `bin/*`, `references/*`, `README.md`, `test/*` are all untouched here.

---

## What

**User-visible behavior**: An AI agent (or human) reading the skill's frontmatter `description` and
body learns a single, invariant command model — `agent-browser-pool <verb> <args>` — and types
`agent-browser-pool open https://example.com`, never `agent-browser open ...`. They learn the lane is
theirs by identity (never an argument), that `connect`/`--session` args are harmlessly overridden,
that `close` is disconnect-only while release is automatic on session end, that driving outside `pi`
fails fast (not silently passes through), and that the source profile must never be driven directly.
The file is ~115-125 lines of Markdown + YAML frontmatter.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `lib/pool.sh` — the SHIPPED behavior the skill describes (read-only reference; P2.M1 done).
- `bin/agent-browser-pool` — the entry point the skill teaches (P2.M2 done; read-only).
- `references/configuration.md` — the detail reference this skill's §5 points at (P2.M4.T2.S1, parallel).
- `README.md`, `install.sh`, `test/*` — each owned by a sibling/later item.
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.

### Success Criteria

- [ ] SKILL.md rewritten in place; ~110-135 lines; valid Markdown with YAML frontmatter.
- [ ] Frontmatter `name: agent-browser-pool`; `description:` = exact mandated string (ends
      "...open pages, connect, close, scrape, or automate.").
- [ ] Title `# Agent Browser Pool — how to use your Chrome lane`.
- [ ] Opening paragraph states: `agent-browser-pool <verb> <args>` is the explicit (not transparent)
      command, plus the "command never names a lane" invariant.
- [ ] All examples use `agent-browser-pool <verb>` (open, connect, close, close --all, status, doctor).
- [ ] §1 "Get + connect" + connection rules + "Which commands trigger a lane" (meta = skills,
      --version, session list, dashboard, plugin, mcp; NO --help/-h, NO DISABLE, NO passthrough).
- [ ] §2 "Tear down": close = disconnect-only; release automatic on pi exit; don't run admin cleanup.
- [ ] §3 "Safety": never enter credentials, verify URLs, never drive the source profile directly /
      never launch Chrome yourself, isolation by construction. (status/doctor inspection folded in.)
- [ ] §4 "Common pitfalls": driving outside pi fails fast; exhaustion; close≠release.
- [ ] Zero matches for `AGENT_BROWSER_POOL_DISABLE`, `transparent`, `PATH-shadowing`, `shadowing`,
      `human terminal`, `agent-browser open`.
- [ ] Only `.agents/skills/agent-browser-pool/SKILL.md` modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the EXACT final SKILL.md is provided verbatim in §Implementation Blueprint
(a complete rewrite, so the artifact is the spec), plus: the exact frontmatter strings, the exact
grep assertions for every removal/addition, the behavior contracts the skill describes (verified
against the live `lib/pool.sh`/`bin/agent-browser-pool` and pinned to function names + line anchors),
the meta-vs-driving classification nuance (why `--help`/`-h` are pool verbs, not meta-passthrough),
the close/connect/`--session` arg-cleaning semantics, the master-profile default, and the explicit
disjointness map (which sibling items own which files). No guessing.

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §5
  why: "SKILL.md — COMPLETE REWRITE. Current: teaches agent-browser (PATH-shadowing). New: teaches
        agent-browser-pool <verb> (explicit invocation). Key changes: frontmatter description,
        all examples, remove 'transparent wrapper', add 'command never names a lane', remove
        passthrough/DISABLE, no-pi-ancestor = 'fails fast'."
  critical: "This IS the item's contract. The verbatim file in this PRP implements it exactly."

- prd: PRD.md §2.15 (h3.19) — Invocation checklist (the contract the skill teaches)
  why: The literal checklist this skill must make an agent able to satisfy. First item:
        "agent-browser-pool open <url> with zero prep". Invariant: "The command is identical no
        matter which lane I'm on; I never pass a lane/port/session." This is the structural guide.
  critical: "Use §2.15 as the structural guide (item LOGIC j). Every checklist item maps to a claim
             the skill must support."

- prd: PRD.md §1.3 (h3.2) — Goals
  why: Goal #1 "Explicit, invariant invocation … never an argument … cannot name a lane." Source of
        the headline invariant phrasing.

- prd: PRD.md §2.4 (h3.8) — Request lifecycle
  why: step 0 classify (POOL VERB vs DRIVING) + step 1 "No pi ancestor → DRIVING fails fast" + the
        agent-facing invariants ("The command never names a lane … --session stripped/overridden;
        connect positional dropped; close stays disconnect-only"). Source for §1 connection rules.

- prd: PRD.md §2.13 (h3.17) — Safety & identity rules
  why: The non-negotiable safety rules this skill's §3 carries verbatim: never enter credentials;
        verify URL before every click; never drive the source profile directly (it is only ever
        COPIED); isolation by construction (no lane-selector argument).

- prd: PRD.md §2.5 (h3.9) — Release semantics
  why: "agent-browser close (mid-task) = disconnect-only … lane, Chrome, and ephemeral dir stay
        alive … The ephemeral dir is deleted only on true release (owner exit / explicit)."
        Source for §2 close-vs-release distinction + "profile is ephemeral".

- file: .agents/skills/agent-browser-pool/SKILL.md   (CURRENT ~125-line shadowing skill — REWRITTEN)
  why: The file being replaced. Read it to see exactly what is being removed (transparent wrapper,
        AGENT_BROWSER_POOL_DISABLE, human-terminal passthrough, agent-browser open examples).
  pattern: "KEEP the 5-section skeleton (Get+connect / Tear down / Inspect / Pitfalls / Reference)
           and the reference-pointer to configuration.md. REWRITE every command example + the
           framing + the meta list + the pitfalls' 1st bullet."
  gotcha: "The CURRENT meta list includes --help/-h. In the NEW model --help/-h/help are POOL VERBS
           (caught by the dispatcher before pool_wrapper_main). They must NOT be in the new meta list."

- file: bin/agent-browser-pool   (READ only — the command the skill teaches)
  why: Confirms dispatch: cmd="${1:-status}"; pool verbs status|reap|release|doctor|--help|-h|help;
       *) pool_wrapper_main "$@". A bare invocation defaults to status (NOT help). The meta commands
       that actually reach the real binary pass through pool_wrapper_main's classify step.

- file: lib/pool.sh  (READ only — the behavior the skill describes; P2.M1 done)
  why: >
    pool_dispatch_classify (@3173): meta = --help/-h/--version (flag pos), skills/dashboard/plugin/mcp,
    session list, flags-only/no-command. driving = everything else incl. unrecognized. NOTE --help/-h
    are intercepted by the dispatcher as the 'help' pool verb, so they never reach classify.
    pool_wrapper_main step d: no-pi-ancestor DRIVING → pool_die exit 1 with the actionable message.
    pool_normalize_connect (@3357): strips the connect <port|url> positional. pool_normalize_close
    (@3284): strips every --all for a close command. pool_strip_session_args (@3461)+pool_force_session
    (@3527): strip --session <X>, force AGENT_BROWSER_SESSION=abpool-<N>.
  critical: "pool_config_init (@154) default POOL_MASTER_DIR = ~/.config/google-chrome (the REAL
             Chrome dir), NOT master-profile. The skill's 'source profile (your real
             ~/.config/google-chrome)' claim is accurate. AGENT_BROWSER_POOL_DISABLE is ABSENT from
             the whole file (grep: nothing) — P2.M1 complete."

- file: .agents/skills/agent-browser-pool/references/configuration.md   (sibling — READ only)
  why: This skill's §5 points to it. NOTE it still reflects the OLD model (DISABLE row, master-profile
       default, passthrough dispatch) — P2.M4.T2.S1 updates it IN PARALLEL. So this skill must NOT
       duplicate configuration.md-owned content (full env table, full dispatch table, troubleshooting
       matrix); it only references it. The few inline claims here are verified against lib/pool.sh.

- file: plan/002_97982899bef6/P2M3T1S1/PRP.md   (parallel sibling — CONTRACT for install.sh)
  why: "install.sh's success message prints 'agent-browser-pool open <url>' examples — CONSISTENT
        with this skill. DISJOINT file → composes in either order."
```

### Current codebase tree (relevant slice)

```bash
.agents/skills/agent-browser-pool/
├── SKILL.md                      # ~125 lines — OLD shadowing skill (REWRITTEN IN PLACE by this item)
├── README.md                     # UNTOUCHED (P2.M4.T3.S1)
└── references/
    └── configuration.md          # UNTOUCHED here (P2.M4.T2.S1 updates it in parallel)
bin/agent-browser-pool            # UNTOUCHED (P2.M2 done; the command the skill teaches — READ only)
bin/agent-browser                 # DELETED (P2.M2.T2.S1) — the skill must never reference it
lib/pool.sh                       # UNTOUCHED (P2.M1 done; the behavior the skill describes — READ only)
install.sh                        # UNTOUCHED (P2.M3.T1.S1, parallel)
README.md                         # UNTOUCHED (P2.M6.T1.S1)
test/*                            # UNTOUCHED (P2.M5). NOT run here (AGENTS.md §1).
PRD.md                            # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
.agents/skills/agent-browser-pool/
└── SKILL.md   # REWRITTEN (~115-125 lines): teaches agent-browser-pool <verb> as the sole command.
# No new files. No deletions. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
CRITICAL (the frontmatter description is an EXACT mandated string — do not paraphrase): it MUST be:
  "Drive a browser through agent-browser-pool — get a dedicated, isolated Chrome profile lane,
   reuse it across calls, and tear it down correctly. Use whenever you run agent-browser-pool to
   open pages, connect, close, scrape, or automate."
  (ends at "or automate." — the old skill's trailing "and want to know how your lane is acquired,
  pinned to you, and released." is DROPPED.) Item LOGIC (a) pins this verbatim.

CRITICAL (the canonical example is `agent-browser-pool open`, NOT `agent-browser open`): every
  code-fence example in the file must use the `-pool` command. `grep 'agent-browser open' SKILL.md`
  must return NOTHING (that is the old-model tell). Use `agent-browser-pool open https://example.com`.

CRITICAL (--help/-h are POOL VERBS, not meta-passthrough): in the new dispatch, `--help`/`-h`/`help`
  are caught by the dispatcher's case arm → pool_admin_help. They do NOT reach the real binary. So
  the skill's meta list must be skills, --version, session list, dashboard, plugin, mcp — and must
  NOT include --help/-h. (The OLD skill listed --help/-h as meta; that is now wrong.)

CRITICAL (no-pi-ancestor is FAIL-FAST, not passthrough): the OLD pitfalls' 1st bullet ("You were in
  passthrough: no pi ancestor, or AGENT_BROWSER_POOL_DISABLE set") is DEAD. The NEW 1st bullet states
  driving commands require a pi ancestor and fail fast with an actionable message. Never say
  "passthrough" for no-pi-ancestor. (Item LOGIC i.)

CRITICAL (remove the word/concept "passthrough-as-human-terminal" entirely): the skill may still use
  the phrase "pass straight through" to describe META commands (that behavior is real + unchanged),
  but must never describe no-pi-ancestor as passthrough. The safest enforcement is the literal grep
  targets: AGENT_BROWSER_POOL_DISABLE, transparent, PATH-shadowing, shadowing, "human terminal",
  `agent-browser open` — all must be absent.

CRITICAL (master default is the REAL Chrome dir): the skill says the source profile is "your real
  ~/.config/google-chrome" — ACCURATE (pool_config_init @154; system_context). Do NOT say
  "master-profile" (the old default). configuration.md still wrongly says master-profile until
  P2.M4.T2.S1 fixes it; this skill leads with the correct value.

CRITICAL (close --all is SAFE — scoped to your lane): the skill states --all is stripped and the
  session forced to abpool-<N>, so close --all can never kill a peer. This is pool_normalize_close
  (@3284) + pool_force_session (@3527). Accurate. (The OLD skill already said this; keep it.)

CRITICAL (do NOT duplicate configuration.md): the skill references references/configuration.md for
  the full env table, the full dispatch table, and the troubleshooting matrix. Keep those OUT of the
  skill (configuration.md owns them and P2.M4.T2.S1 is updating it in parallel). The skill owns the
  procedural "how to use your lane" guide + the headline invariants only.

CRITICAL (validation is STATIC ONLY — AGENTS.md §1): a Markdown edit cannot hang the sandbox, but we
  STILL never boot Chrome, never run test/*, never run install.sh. Validation = grep + structural
  checks + a link-target existence test. No execution of anything.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is a complete rewrite of one Markdown skill file. The file is the
deliverable; the exact final content is given in §Implementation Tasks (Task 2, verbatim block).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the current SKILL.md + the live behavior sources (context — no writes)
  - READ: .agents/skills/agent-browser-pool/SKILL.md   (the file being replaced)
  - READ: bin/agent-browser-pool   (the command + dispatch the skill teaches)
  - CONFIRM (grep, read-only): lib/pool.sh has ZERO 'AGENT_BROWSER_POOL_DISABLE'; pool_admin_help
           (@4592) already prints the new 'Driving commands' section; pool_dispatch_classify (@3173)
           meta set = skills/dashboard/plugin/mcp/session list/--version/--help; pool_normalize_close
           (@3284) strips --all for close; pool_config_init (@154) master default = real Chrome dir.
  - WHY: anchors every claim in the rewritten skill against SHIPPED behavior (no guesses).

Task 2: REWRITE .agents/skills/agent-browser-pool/SKILL.md  (the entire deliverable)
  - WRITE: .agents/skills/agent-browser-pool/SKILL.md   (overwrite the existing file IN PLACE)
  - CONTENT: the EXACT Markdown in the "Target SKILL.md (verbatim)" block below.
  - WHY: gap_analysis §5 + PRD §2.15/§2.13/§2.4/§2.5 + item LOGIC (a)–(j). Replaces the shadowing
         skill with the explicit-invocation skill.
  - STRUCTURE (top → bottom), matching item LOGIC (a)–(j) + PRD §2.15 as structural guide:
      a. YAML frontmatter: name + the exact mandated description string.
      b. Title: "# Agent Browser Pool — how to use your Chrome lane".
      c. Opening: "`agent-browser-pool <verb> <args>` is your one browser command … NOT a transparent
         wrapper … explicit tool" + 3 bullets (1 agent=1 browser; dedicated profile; one browser for
         session) + a "The command never names a lane" paragraph (the headline invariant) + "You do
         not manage lanes — agent-browser-pool does. Just type the command."
      d. ## 1. Get + connect: `agent-browser-pool open https://example.com`; behind-the-scenes 4 steps.
      e. ### Connection rules: `agent-browser-pool connect <port>` → arg stripped; `--session <X>` →
         overridden.
      f. ### Which commands trigger a lane: driving (open/connect/close/get/screenshot/click/type/
         eval/find + unrecognized); meta (skills, --version, session list, dashboard, plugin, mcp).
         NO --help/-h, NO DISABLE, NO no-pi-ancestor-passthrough.
      g. ## 2. Tear down: `close` = disconnect-only (`close --all` safe/scoped); release auto on pi
         exit; profile is ephemeral; do NOT run release/reap as routine cleanup.
      h. ## 3. Safety: inspect (status/doctor read-only) + safety rules (never enter creds; verify
         URL; never drive source profile directly / never launch Chrome; isolation by construction).
      + ## 4. Common pitfalls: driving outside pi fails fast; exhaustion; close≠release.
      + ## 5. Reference → references/configuration.md.
  - REMOVED (item LOGIC i — verify by grep): "transparent PATH-shadowing wrapper", any
         AGENT_BROWSER_POOL_DISABLE, "human terminal passthrough", all bare `agent-browser <verb>`
         examples, the old pitfalls' passthrough/DISABLE bullet, the old meta-list --help/-h entry.
  - BUCKET: required (the entire deliverable is this one file).

Task 3: STATIC VALIDATION  (AGENTS.md §1: static only — no execution)
  - RUN: the grep + structural assertions in §Validation Loop Level 1 (removals + additions +
         frontmatter + link target + section headers).
  - RUN: git status --short   (expect EXACTLY one path: .agents/skills/agent-browser-pool/SKILL.md)
  - WHY: contract + AGENTS.md §1. No Chrome, no daemons, no test suite.
  - BUCKET: required.
```

#### Target SKILL.md (verbatim — the exact artifact to write in Task 2)

> This is the complete, final SKILL.md. Write it to
> `.agents/skills/agent-browser-pool/SKILL.md`, overwriting the existing file.
> ~118 lines. Valid Markdown with YAML frontmatter.

```markdown
---
name: agent-browser-pool
description: Drive a browser through agent-browser-pool — get a dedicated, isolated Chrome profile lane, reuse it across calls, and tear it down correctly. Use whenever you run agent-browser-pool to open pages, connect, close, scrape, or automate.
---

# Agent Browser Pool — how to use your Chrome lane

`agent-browser-pool <verb> <args>` is your one browser command. It is **not** a transparent
wrapper around something else — it is the explicit tool you call. Every call means *your own
locked Chrome with a dedicated ephemeral profile*, for the lifetime of your session:

- **1 agent = 1 browser.** No other agent shares your lane, and you cannot reach theirs.
- **Dedicated profile.** It starts from a trusted master template (Google login, password
  manager, the agent-browser extension are already present).
- **One browser for the whole session.** Your first driving call boots it; every later call
  reuses it.

**The command never names a lane.** `agent-browser-pool <verb> <args>` is **identical every
time** — the same on lane 1 or lane 99. Your lane is selected by your own process identity
(your owning `pi` process and its start time), never by an argument. You do not — and cannot —
pass a lane number, port, or session.

**You do not manage lanes — `agent-browser-pool` does. Just type the command.** That is the
entire API. The sections below exist so you understand what is happening and don't fight the pool.

## 1. Get + connect to your lane (acquire is automatic)

Your lane is acquired on your **first driving command**. There is no separate "create lane" or
"connect to port" step for you to run:

```bash
agent-browser-pool open https://example.com     # this single call does everything
```

Behind the scenes it:
1. Finds a free lane just for you, keyed on your owning `pi` process (and its start time, so a
   recycled PID can never steal your lane).
2. Copy-on-writes a fresh profile from the master template.
3. Launches Chrome on the lane's port and connects the agent-browser daemon to it.
4. Pins your session to `abpool-<N>` (you never type this).

After that, **every** driving call in your session routes to that same lane/browser/profile.
You do not reconnect between calls.

### Connection rules (don't fight the pool)

- **Do not pass a port or CDP URL.** The pool owns the connection. If you type
  `agent-browser-pool connect <port>` / `connect <url>`, the argument is silently dropped and
  the call routes to your already-connected lane. A bare `agent-browser-pool connect` is an
  automatic no-op success.
- **Do not pass `--session <name>`.** The pool strips it and forces
  `AGENT_BROWSER_SESSION=abpool-<N>`. If you pass one anyway, it is harmlessly overridden.
- These overrides are intentional: the pool owns connection + session + lifecycle so the
  command is the same regardless of which lane you're on.

### Which commands trigger a lane

**Driving** commands acquire/use your lane. They include `open`, `connect`, `close`, `get`,
`screenshot`, `click`, `type`, `eval`, `find`, and **any unrecognized command** — an unknown
verb still gets your lane rather than erroring out.

A small set of **meta** commands pass straight through to the real `agent-browser` WITHOUT
acquiring a lane (so they work with no lane): `skills`, `--version`, `session list`,
`dashboard`, `plugin`, and `mcp`. (The pool's own verbs — `status`, `reap`, `release`,
`doctor`, and `help`/`--help`/`-h` — run pool functions, not the real binary; see §2 and §3.)
See `references/configuration.md` for the full dispatch table.

## 2. Tear down when you're finished

### `close` is NOT a teardown — it's a disconnect

```bash
agent-browser-pool close          # disconnects your lane's daemon ONLY
agent-browser-pool close --all    # also safe: --all is stripped and scoped to YOUR lane
```

`close` detaches the daemon↔Chrome binding but **leaves the browser and profile alive for
reuse** within your session. Your next driving command re-binds automatically. Use `close`
mid-session to drop the connection; do not mistake it for "release." `--all` is safe because
the pool strips it and forces `--session abpool-<N>` — it can never kill a peer's session.

### The real teardown is automatic

**Just end your session normally.** When your owning `pi` process exits, the lane is released:
the Chrome process group is killed, the ephemeral profile directory is deleted, and the lease
is dropped. You normally do nothing explicit.

Corollary: **the profile is ephemeral.** Anything you change during the session (new logins,
cookies, downloads, history) lives only in your lane's copy and is **deleted on release** —
never written back to the master template. Re-establish session state each time; don't expect
it to survive.

### Do NOT run pool admin commands as routine cleanup

`agent-browser-pool release <N>`, `release all`, and `reap` are **operator** tools.
Critically, `release <N>` is **not** scoped to your lane — releasing the wrong number (or
`all`) tears down **other agents'** lanes. Run them only if a human operator explicitly asks
you to. The correct agent teardown is: stop using the browser and let your session end.

## 3. Safety

### Inspect your lane (read-only, always safe)

```bash
agent-browser-pool status     # read-only table of all active lanes
agent-browser-pool doctor     # read-only diagnostic of the whole pool
```

In `status`, find your row by your working directory / owner PID. The `STATE` column is:

- `live` — Chrome reachable.
- `disconnected` — lane leased but the daemon dropped; your next driving call re-binds.
- `STALE` — owner process died (the reaper will reclaim it on the next acquire).

### Safety & identity rules (non-negotiable)

Each ephemeral profile starts as a clone of the master identity:

- **Never enter credentials; never unlock a password manager.** Existing SSO/Google login is
  fine to *use*; never type a password.
- **Verify the target URL before every click/fill/navigate.**
- **Never drive the source profile directly, and never launch `google-chrome-stable` yourself.**
  The source (your real `~/.config/google-chrome`) is only ever **copied** — agents drive
  ephemeral CoW copies, never the source. A direct Chrome launch bypasses the pool, conflicts
  with it, and risks mutating the master.
- **Isolation by construction.** Because no command accepts a lane selector, you physically
  cannot reach another agent's lane through normal tool use. The next agent gets the next free
  lane.

## 4. Common pitfalls

- **"I ran a driving command outside `pi` and it errored."** By design: driving commands
  require a `pi` ancestor — that is how your lane is keyed to you. The call fails fast with an
  actionable message pointing you at the real `agent-browser` for raw browser use. Run your
  browser work under `pi`; don't try to bypass it.
- **"My `agent-browser-pool` call hangs a long time."** The pool may be **exhausted** (all
  lanes busy). It self-heals — it reaps dead owners and, after `AGENT_BROWSER_POOL_WAIT`
  (default 600s), force-reclaims one. Do **not** try to "fix" this by booting Chrome directly.
- **Don't confuse `close` with release.** `close` keeps your browser alive for reuse; release
  (which happens automatically when your session ends) destroys it.

## 5. Reference

For the full environment-variable table, the complete meta-vs-driving command dispatch
classification, the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix, read
**`references/configuration.md`**.
```

### Implementation Patterns & Key Details

```markdown
PATTERN — the headline invariant is stated TWICE for emphasis (mirrors PRD §2.15 + §1.3):
  once in the opening ("identical every time … never by an argument") and once as a bold
  lead-in paragraph ("The command never names a lane."). This is the single most important
  behavior an agent must internalize.

PATTERN — every code-fence example uses the `agent-browser-pool` command. There is NO
  `agent-browser <verb>` example anywhere. The only bare `agent-browser` mention is inside
  prose explaining the meta-passthrough target and the fail-fast message's "for raw browser
  use, call 'agent-browser' directly" (both are CORRECT: they describe the real unshadowed
  binary, not a command the agent should type for pooled driving).

GOTCHA — "pass straight through" (meta commands) is KEPT (real behavior, unchanged); the
  removed concept is "no pi ancestor → passthrough (human terminal)". The grep targets enforce
  the distinction: 'human terminal' must be absent; 'straight through' may be present.

GOTCHA — the meta list omits --help/-h on purpose (they are pool verbs now). Do NOT re-add them.

GOTCHA — do NOT add env-var documentation to the skill (configuration.md owns it; P2.M4.T2.S1
  updates it). The only env var named in the skill is AGENT_BROWSER_POOL_WAIT (in the
  exhaustion pitfall) and AGENT_BROWSER_SESSION=abpool-<N> (in connection rules) — both are
  behavioral facts, not a config table.
```

### Integration Points

```yaml
NONE for this item beyond the skill file tree (one Markdown file rewritten in place).
  - No code, no config, no env vars are introduced by this item (it is documentation only).
  - The skill CONSUMES (does not modify):
      * lib/pool.sh + bin/agent-browser-pool — the SHIPPED behavior it describes (P2.M1/P2.M2 done).
      * references/configuration.md — the detail reference its §5 points at (P2.M4.T2.S1, parallel).
  - Downstream consumers that build on this LATER (NOT here):
      * references/configuration.md   (P2.M4.T2.S1 — will be made consistent with this skill)
      * README.md                     (P2.M6.T1.S1 — will mirror this skill's command model)
      * test/transparency.sh          (P2.M5.T2.S1 — exercises the live agent-browser-pool commands
        this skill teaches, in an isolated sandbox)
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`grep`, `test`, `sed`, `git`). **Do NOT boot
> Chrome, do NOT run any `agent-browser`/`agent-browser-pool` driving command, do NOT run
> install.sh, do NOT run test/*.sh during this item.** A Markdown edit cannot hang the sandbox, but
> we still execute nothing. Levels 2-4 are N/A by design (a doc has no runtime to validate here).

### Level 1: Structure & content (run after the rewrite)

```bash
cd /home/dustin/projects/agent-browser-pool
F=.agents/skills/agent-browser-pool/SKILL.md

# --- frontmatter: name + exact description ---
sed -n '1,4p' "$F"
grep -q '^name: agent-browser-pool$' "$F" && echo "OK: name" || echo "FAIL: name"
grep -Fq 'description: Drive a browser through agent-browser-pool — get a dedicated, isolated Chrome profile lane, reuse it across calls, and tear it down correctly. Use whenever you run agent-browser-pool to open pages, connect, close, scrape, or automate.' "$F" \
  && echo "OK: exact description" || echo "FAIL: description not exact"

# --- title ---
grep -Fxq '# Agent Browser Pool — how to use your Chrome lane' "$F" && echo "OK: title" || echo "FAIL: title"

# --- section headers (PRD §2.15 structural guide) ---
for h in '## 1. Get + connect' '## 2. Tear down' '## 3. Safety' '## 4. Common pitfalls' '## 5. Reference'; do
  grep -Fq "$h" "$F" && echo "OK: header $h" || echo "FAIL: missing header $h"
done

# --- REMOVALS: each grep MUST find zero matches ---
for pat in 'AGENT_BROWSER_POOL_DISABLE' 'transparent' 'PATH-shadowing' '[Ss]hadowing' 'human terminal' 'agent-browser open'; do
    if grep -nE "$pat" "$F"; then echo "FAIL: found removed pattern: $pat"; else echo "OK: absent: $pat"; fi
done

# --- ADDITIONS: each grep MUST find a match ---
grep -Fq 'agent-browser-pool open https://example.com' "$F" && echo "OK: canonical example" || echo "FAIL: no canonical example"
grep -Fq 'The command never names a lane.' "$F" && echo "OK: invariant" || echo "FAIL: no invariant"
grep -Eq 'fails fast|require a pi ancestor' "$F" && echo "OK: fail-fast stated" || echo "FAIL: no fail-fast"
grep -Fq 'agent-browser-pool connect <port>' "$F" && echo "OK: connect example" || echo "FAIL: no connect example"
grep -Fq 'agent-browser-pool close' "$F" && echo "OK: close example" || echo "FAIL: no close example"
grep -Fq 'agent-browser-pool close --all' "$F" && echo "OK: close --all example" || echo "FAIL: no close --all"
grep -Fq 'agent-browser-pool status' "$F" && echo "OK: status example" || echo "FAIL: no status"
grep -Fq 'agent-browser-pool doctor' "$F" && echo "OK: doctor example" || echo "FAIL: no doctor"
for meta in '\-\-version' 'skills' 'session list' 'dashboard' 'plugin' 'mcp'; do
  grep -Fq "$meta" "$F" && echo "OK: meta $meta" || echo "FAIL: meta $meta missing"
done
# --- meta list must NOT include --help/-h as passthrough ---
if grep -Eq 'meta.*--help|--help.*meta|pass(ing|ed)? straight through.*--help' "$F"; then
  echo "FAIL: --help/-h wrongly listed as meta-passthrough"
else
  echo "OK: --help/-h not listed as meta-passthrough"
fi

# --- the link target EXISTS ---
grep -Fq 'references/configuration.md' "$F" && echo "OK: references config.md" || echo "FAIL: no config.md reference"
test -f .agents/skills/agent-browser-pool/references/configuration.md && echo "OK: config.md exists" || echo "FAIL: config.md missing"

# --- line count sanity (~110-135) ---
n=$(wc -l < "$F"); echo "lines: $n"
test "$n" -ge 105 -a "$n" -le 145 && echo "OK: line count in range" || echo "FAIL: line count out of range"

# --- scope: ONLY this skill file changed by this item ---
git status --short
git status --short | grep -qvE '^.M? \.agents/skills/agent-browser-pool/SKILL\.md$' \
  && echo "FAIL: unexpected changed files" || echo "OK: only SKILL.md changed"
```

**Expected**: every assertion prints `OK:`; the 6 removed-pattern greps find nothing; all addition
greps match; the meta list excludes `--help`/`-h`; `references/configuration.md` exists; line count
~118; `git status --short` shows only `.agents/skills/agent-browser-pool/SKILL.md`.

### Level 2: Component Validation — N/A

A Markdown skill has no component runtime. Its "correctness" is its fidelity to the SHIPPED behavior
in `lib/pool.sh` + `bin/agent-browser-pool`, which is enforced by the Level-1 grep assertions (each
claim in the verbatim file is pinned to a function + line anchor in §Documentation & References).
Live exercise of `agent-browser-pool open <url>` is P2.M5.T2.S1's job (isolated sandbox), not here.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# The behavior the skill describes is SHIPPED (sanity greps — read-only, no execution):
grep -q 'AGENT_BROWSER_POOL_DISABLE' lib/pool.sh && echo "FAIL: lib still has DISABLE" || echo "OK: lib has no DISABLE (skill is truthful)"
grep -q '*) pool_wrapper_main "$@" ;;' bin/agent-browser-pool && echo "OK: dispatch routes driving to pool_wrapper_main" || echo "FAIL: dispatch not rewired"
grep -q 'driving commands require a pi ancestor' lib/pool.sh && echo "OK: fail-fast shipped" || echo "FAIL: fail-fast not shipped"

# No OTHER doc/code file was modified by this item:
git diff --name-only | grep -vE '^\.agents/skills/agent-browser-pool/SKILL\.md$' \
  && echo "FAIL: unexpected files modified" || echo "OK: only SKILL.md modified"

# Confirm siblings are untouched (owned by other items):
for f in lib/pool.sh bin/agent-browser-pool install.sh README.md .agents/skills/agent-browser-pool/references/configuration.md .agents/skills/agent-browser-pool/README.md; do
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done

# Do NOT run: test/*.sh, install.sh, or any agent-browser / Chrome command (AGENTS.md §1).
```

### Level 4: Creative & Domain-Specific Validation — N/A

A documentation rewrite has no domain runtime. The skill's accuracy is fully pinned by Level 1-3
checks + the verbatim artifact + the behavior contracts in §Documentation & References.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: every assertion prints `OK:`; no removed pattern present; all additions present.
- [ ] Frontmatter `name` + exact `description` present; title correct.
- [ ] All 5 section headers present; line count ~110-135.
- [ ] `references/configuration.md` link target exists.
- [ ] `git status --short` shows ONLY `.agents/skills/agent-browser-pool/SKILL.md`.

### Feature Validation

- [ ] Opening states `agent-browser-pool <verb> <args>` is the explicit (not transparent) command.
- [ ] "The command never names a lane" invariant is prominent.
- [ ] Every example uses `agent-browser-pool <verb>`; zero `agent-browser open` examples.
- [ ] Meta list = skills, --version, session list, dashboard, plugin, mcp (NO --help/-h, NO DISABLE).
- [ ] §2: close = disconnect-only; close --all safe/scoped; release automatic on pi exit; profile ephemeral.
- [ ] §3: never enter creds; verify URL; never drive source profile / never launch Chrome; isolation by construction.
- [ ] §4: driving outside pi fails fast (NOT passthrough); exhaustion; close≠release.
- [ ] Zero references to transparent/PATH-shadowing/AGENT_BROWSER_POOL_DISABLE/human-terminal-passthrough.

### Code Quality / Scope Validation

- [ ] **Only** `.agents/skills/agent-browser-pool/SKILL.md` is modified; no other file touched.
- [ ] `lib/pool.sh`, `bin/*`, `install.sh`, `references/configuration.md`, `README.md`, `test/*` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no test suite) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] SKILL.md IS the documentation artifact (the user-facing contract doc). No separate
      doc file is written by this item.
- [ ] No env-var table duplicated into the skill (configuration.md owns it; §5 references it).

---

## Anti-Patterns to Avoid

- ❌ Don't leave any `agent-browser open` (or any bare `agent-browser <verb>`) example — every pooled
      example must be `agent-browser-pool <verb>`. `grep 'agent-browser open' SKILL.md` must be empty.
- ❌ Don't paraphrase the frontmatter `description` — it is an exact mandated string (item LOGIC a).
- ❌ Don't list `--help`/`-h` as meta-passthrough — they are POOL VERBS now (caught by the dispatcher).
- ❌ Don't describe no-pi-ancestor as "passthrough" — it FAILS FAST now. The pitfalls' 1st bullet is
      replaced, not kept. (Item LOGIC i.)
- ❌ Don't re-introduce `AGENT_BROWSER_POOL_DISABLE`, "transparent", "PATH-shadowing", or "human
      terminal" anywhere — all must be absent (enforced by grep).
- ❌ Don't say the master source is "master-profile" — it is the real `~/.config/google-chrome`.
- ❌ Don't duplicate the full env-var table / dispatch table / troubleshooting matrix into the skill —
      `references/configuration.md` owns those (P2.M4.T2.S1 updates it). The skill references it.
- ❌ Don't edit `references/configuration.md`, `lib/pool.sh`, `bin/*`, `install.sh`, `README.md`, or
      `test/*` — each is owned by a sibling/later item (P2.M4.T2 / P2.M1-done / P2.M2-done /
      P2.M3.T1.S1 / P2.M6 / P2.M5).
- ❌ Don't run `test/*.sh`, `install.sh`, or any `agent-browser`/Chrome command during this item —
      AGENTS.md §1 (sandbox-hang prevention). All validation is static (Level 1).

---

## Confidence Score

**9/10** — one-pass success likelihood. The item is a single-file complete rewrite of a Markdown
skill, and the PRP supplies the **exact final SKILL.md verbatim** (the artifact is the spec), so there
is no ambiguity about what to write. Every behavioral claim in the file is pinned to a SHIPPED
function + line anchor in `lib/pool.sh`/`bin/agent-browser-pool` (verified live: DISABLE fully gone,
fail-fast shipped, dispatch rewired, close/connect/`--session` semantics, master default = real Chrome
dir), so the skill is guaranteed truthful. The subtlest nuance — that `--help`/`-h` are now pool
verbs, not meta-passthrough — is called out explicitly and enforced by a Level-1 grep. The exact
frontmatter `description` is given verbatim. Validation is entirely static (grep + structural + a
link-target existence test + `git status` scope check) and cannot wedge the sandbox (AGENTS.md §1).
Not 10/10 only because the live runtime fidelity (an agent actually typing `agent-browser-pool open`
and getting a lane) is validated later by P2.M5.T2.S1 in an isolated sandbox, not by this item.
