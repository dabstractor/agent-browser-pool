# PRP — P2.M4.T2.S1: Update configuration.md — remove DISABLE, fix master default, update dispatch

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`); reference doc is Markdown.
**Work item**: P2.M4.T2.S1 (1 point)
**Dependency / starting state**: Builds on the POST-P2.M2 tree. The behavior this reference doc
**describes** is already SHIPPED and verified in `lib/pool.sh` + `bin/agent-browser-pool`:
`AGENT_BROWSER_POOL_DISABLE` is **fully removed** from `lib/pool.sh` (grep → nothing; P2.M1.T1.S1
done); `pool_wrapper_main` fail-fasts on no-pi-ancestor via `pool_die` (P2.M1.T1.S2 done);
`_pool_preflight_real_bin` guards driving calls (P2.M1.T2.S1 done); `pool_admin_help` already
ships the corrected env list (master = `~/.config/google-chrome`, no DISABLE row; P2.M1.T3.S1 done);
`bin/agent-browser-pool`'s `*)` arm routes driving to `pool_wrapper_main` and its outer case
intercepts `--help|-h|help` as the `help` pool verb (P2.M2.T1.S1 done); the old `bin/agent-browser`
PATH-shadow shim is deleted (P2.M2.T2.S1 done). **This item edits exactly ONE file**:
`.agents/skills/agent-browser-pool/references/configuration.md` (currently **134 lines**).
**PARALLEL**: sibling P2.M4.T1.S1 rewrites `.agents/skills/agent-browser-pool/SKILL.md` in parallel;
its §5 points at THIS file. The two docs MUST agree (no DISABLE; master = real Chrome dir;
--help/-h = pool verbs). This PRP's full-target-file + edit map is engineered so the docs compose.
**Full research notes**: `plan/002_97982899bef6/P2M4T2S1/research/notes.md`

---

## Goal

**Feature Goal**: Update `references/configuration.md` so it accurately reflects the shipped
no-`DISABLE`, explicit-invocation, fail-fast model — instead of the dead shadowing-era model it
currently documents (`AGENT_BROWSER_POOL_DISABLE`, `master-profile` default, "no pi ancestor →
passthrough", `agent-browser open`).

**Deliverable**: An edited `.agents/skills/agent-browser-pool/references/configuration.md` whose
env table has no `AGENT_BROWSER_POOL_DISABLE` row and whose `AGENT_CHROME_MASTER` default is
`${XDG_CONFIG_HOME:-~/.config}/google-chrome` (the real Chrome user-data-dir, may be live/in-use);
whose "three that most affect behavior" lists `AGENT_CHROME_MASTER` (not DISABLE); whose command-
dispatch table is the 3-step (meta→passthrough / no-pi→**fail-fast** / otherwise→acquire) order;
whose meta-commands list excludes `--help`/`-h` (they are pool verbs intercepted by the entry-point
dispatcher) and keeps `--version`; whose "How acquire works" diagram uses `agent-browser-pool open`;
and whose troubleshooting matrix's first row references fail-fast (not DISABLE). The exact final
file is provided verbatim in §Implementation Blueprint (Target configuration.md). **No other file
is modified by this item.**

**Success Definition**:
- `references/configuration.md` exists and is valid Markdown (same section headers as today).
- `grep` confirms REMOVALS in the file: zero matches for `AGENT_BROWSER_POOL_DISABLE`, `master-profile`,
  `agent-browser open`, and `AGENT_BROWSER_POOL_DISABLE`'s "safety valve" phrasing.
- `grep` confirms ADDITIONS: the real-Chrome-dir default `${XDG_CONFIG_HOME:-~/.config}/google-chrome`;
  the fail-fast dispatch wording ("fail-fast" + "pi ancestor"); the `agent-browser-pool open` example;
  the `AGENT_CHROME_MASTER` bullet in "three that most affect behavior".
- The dispatch table is the 3-step order: (1) meta → passthrough, (2) no pi ancestor → fail-fast,
  (3) otherwise → acquire/find lane.
- The meta-commands list does NOT include `--help`/`-h` as passthrough (they are pool verbs).
- `shellcheck` passes on every embedded bash code-fence snippet (AGENTS.md §6 / item LOGIC h).
- **Only** `.agents/skills/agent-browser-pool/references/configuration.md` is modified by this item
  (scope check tolerant of the parallel SKILL.md change — see §Validation Loop Level 3).

---

## Why

- **PRD alignment**: PRD §2.11 (h3.15) pins the config contract: `AGENT_CHROME_MASTER` default is
  `${XDG_CONFIG_HOME:-~/.config}/google-chrome` — "your real Chrome user-data-dir … May be
  live/in-use (see §2.7)" — and "(removed) `AGENT_BROWSER_POOL_DISABLE` and the `~/scripts` PATH-
  shadow are gone — there is no interception to bypass (see §2.17)." PRD §2.4 (h3.8) step 1: "No pi
  ancestor → DRIVING fails fast ('requires a pi ancestor; for raw browser use call `agent-browser`
  directly')." PRD §2.17 (h3.21): "Removed: the `AGENT_BROWSER_POOL_DISABLE` safety valve (nothing to
  bypass)." The current configuration.md documents the OPPOSITE of all of these. It is the detail
  reference SKILL.md §5 points agents at, so it must be truthful or it actively misleads.
- **Who it helps**: Every AI agent (or human) who needs exact env-var values, the full dispatch
  table, or the troubleshooting matrix — i.e. the readers SKILL.md deliberately defers here. An
  agent reading the corrected doc will know: the source profile is its real Chrome (so new logins
  propagate), there is no DISABLE escape hatch, driving outside `pi` fails fast (not silently passes
  through), and `--help` is a pool verb not a passthrough.
- **Scope cohesion**: This is item T2.S1 of milestone P2.M4 (Skill & Reference Documentation). Its
  sibling P2.M4.T1.S1 rewrites SKILL.md in parallel; SKILL.md's §5 references THIS file. The later
  P2.M4.T3.S1 updates the skill README, and P2.M6.T1.S1 rewrites the repo README — both mirror the
  same command model. This item touches ONLY configuration.md; `lib/pool.sh`, `bin/*`, SKILL.md,
  README.md, install.sh, test/* are all untouched here.

---

## What

**User-visible behavior**: A reader of `references/configuration.md` finds an environment-variable
table whose `AGENT_CHROME_MASTER` row says the default is their real Chrome user-data-dir
(`${XDG_CONFIG_HOME:-~/.config}/google-chrome`), which may be live/in-use (PRD §2.7), and which is
only ever copied (never launched/mutated/deleted); there is no `AGENT_BROWSER_POOL_DISABLE` row. The
"three that most affect behavior" lists `AGENT_CHROME_MASTER`, `AGENT_CHROME_ALLOW_SLOW_COPY`, and
`AGENT_CHROME_HEADLESS`. The command-dispatch table is a 3-step ordered decision (meta→passthrough;
no pi ancestor→fail-fast via `pool_die`; otherwise→acquire/find lane) with the exact fail-fast
guidance string. The meta-commands list (`--version`, `skills`, `dashboard`, `plugin`, `mcp`,
`session list`, flags-only/no-subcommand) excludes `--help`/`-h` (those are pool verbs →
`pool_admin_help`, intercepted by `bin/agent-browser-pool` before `pool_wrapper_main`) and is
followed by a callout explaining this. The "How acquire works" lifecycle diagram opens with
`agent-browser-pool open <url>`. The troubleshooting matrix's first row's cause is "driving command
run outside `pi` (no pi ancestor → fail-fast)" and its fix is "Run under `pi`; for raw browser use
call `agent-browser` directly." The file is ~135-145 lines.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `lib/pool.sh` — the SHIPPED behavior this doc describes (read-only; P2.M1 done).
- `bin/agent-browser-pool` — the entry point (P2.M2 done; read-only).
- `.agents/skills/agent-browser-pool/SKILL.md` — the procedural skill (P2.M4.T1.S1, parallel).
- `.agents/skills/agent-browser-pool/README.md`, `README.md`, `install.sh`, `test/*` — each owned by
  a sibling/later item.
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.

### Success Criteria

- [ ] `AGENT_CHROME_MASTER` env-table row default = `${XDG_CONFIG_HOME:-~/.config}/google-chrome`;
      meaning reflects real Chrome dir, may be live/in-use (PRD §2.7), never launch/mutate/delete.
- [ ] `AGENT_BROWSER_POOL_DISABLE` row DELETED from the env table.
- [ ] The "safety valve" DISABLE callout DELETED; replaced by an `AGENT_CHROME_MASTER` bullet in
      "three that most affect behavior".
- [ ] Command-dispatch numbered list is the 3-step order: (1) meta → passthrough, (2) no pi ancestor
      → fail-fast (`pool_die` with the exact guidance string), (3) otherwise → acquire/find lane.
- [ ] Meta-commands list does NOT include `--help`/`-h` (pool verbs); DOES include `--version`,
      `skills`, `dashboard`, `plugin`, `mcp`, `session list`; followed by the pool-verb callout.
- [ ] "How acquire works" diagram uses `agent-browser-pool open <url>` (not `agent-browser open`).
- [ ] Troubleshooting row 1 cause/fix updated to fail-fast framing (no DISABLE, no "unset DISABLE").
- [ ] Zero matches for `AGENT_BROWSER_POOL_DISABLE`, `master-profile`, `agent-browser open`,
      "safety valve".
- [ ] `shellcheck` passes on all embedded bash code-fence snippets.
- [ ] Only `references/configuration.md` modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the EXACT final configuration.md is provided verbatim in §Implementation
Blueprint (Target configuration.md, full file), so there is no ambiguity about what to write; plus a
precise edit map (E1-E11) explaining each change against shipped behavior; plus the exact fail-fast
guidance string, the exact master-dir default expression, the exact meta-vs-pool-verb classification
(why `--help`/`-h` are intercepted upstream while `--version` passes through), the exact grep
assertions for every removal/addition, and the explicit disjointness map (which sibling items own
which files). No guessing.

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §6
  why: "references/configuration.md — UPDATE. Remove AGENT_BROWSER_POOL_DISABLE row; update
        AGENT_CHROME_MASTER default master-profile → real Chrome dir; update dispatch table
        (remove DISABLE passthrough, no-pi-ancestor → fail-fast); update troubleshooting matrix."
  critical: "This IS the item's contract. The full-target file in this PRP implements §6 exactly."

- prd: PRD.md §2.11 (h3.15) — Discovery & configuration
  why: Pins the config contract verbatim: AGENT_CHROME_MASTER default =
        "${XDG_CONFIG_HOME:-~/.config}/google-chrome — your real Chrome user-data-dir … May be
        live/in-use (see §2.7)"; and "(removed) AGENT_BROWSER_POOL_DISABLE … there is no
        interception to bypass (see §2.17)." Source for E1 (master row) + E2/E3 (DISABLE removal).

- prd: PRD.md §2.4 (h3.8) — Request lifecycle
  why: step 0 classify (POOL VERB vs DRIVING) + step 1 "No pi ancestor → DRIVING fails fast
        ('requires a pi ancestor; for raw browser use call agent-browser directly')". Source for
        E4/E5 (dispatch table reorder + fail-fast) and the exact guidance string to quote.

- prd: PRD.md §2.7 (h3.11) — Copy / source-profile hygiene
  why: The master may be live/in-use; agents CoW-copy current state on each acquire, so new logins
        propagate. Source for E1's "may be live/in-use" + E3's AGENT_CHROME_MASTER bullet.

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "Removed: the AGENT_BROWSER_POOL_DISABLE safety valve (nothing to bypass)". Source for
        E2/E3 (DISABLE row + callout removal).

- prd: PRD.md §2.14 (h3.18) — Failure modes & recovery
  why: "source profile missing/empty → fail with guidance: use Chrome so the default exists, or set
        AGENT_CHROME_MASTER to an existing user-data-dir". Source for E1's never-launch/mutate/delete.

- file: lib/pool.sh  (READ only — the behavior the doc describes; P2.M1 done)
  why: >
    pool_config_init (@133-184): POOL_MASTER_DIR default = ${AGENT_CHROME_MASTER:-$xdg_cfg/google-chrome}
      where xdg_cfg=${XDG_CONFIG_HOME:-$HOME/.config} (lines 144-148). The source "may be live/in-use
      (PRD §2.7)" (comment line 145). AGENT_BROWSER_POOL_DISABLE is ABSENT (grep → nothing).
    pool_wrapper_main step d (@3641-3646): no-pi-ancestor → pool_die with EXACT message
      "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." /
      "For raw browser use without pooling, call 'agent-browser' directly."
    pool_dispatch_classify (@3173-3223): meta = --help|-h|--version (flag pos), session list,
      skills|dashboard|plugin|mcp, empty/flags-only. (NOTE --help/-h intercepted upstream — see
      bin/agent-browser-pool — so they never reach classify.)
    pool_admin_help (@4624): ships the CORRECT env-doc text to mirror —
      "AGENT_CHROME_MASTER  CoW source profile (default: ~/.config/google-chrome — your real Chrome
      user-data-dir)" with NO DISABLE row.

- file: bin/agent-browser-pool   (READ only — the entry point + dispatch)
  why: Outer dispatcher: cmd="${1:-status}"; case status|reap|release|doctor|--help|-h|help → pool
      admin; *) pool_wrapper_main. PROVES --help/-h/help are pool verbs (→ pool_admin_help)
      intercepted BEFORE pool_wrapper_main, while --version is NOT in the case → falls to *) →
      pool_wrapper_main → classify → meta → passthrough. A bare invocation defaults to `status`.
      Source for E6 (--help/-h callout) + E7 (bare→status).

- file: .agents/skills/agent-browser-pool/references/configuration.md   (CURRENT 134-line file — EDITED)
  why: The file being updated. Read it to see exactly what changes (DISABLE row @28, DISABLE
        callout @32-35, master-profile default @19, DISABLE dispatch item @48, no-pi passthrough @50,
        --help/-h in meta list @55, bare-agent-browser meta item @58, agent-browser open @73,
        DISABLE troubleshooting @110).
  pattern: "KEEP the section skeleton (Env table / three-that-affect / Command dispatch / How acquire
           works / Release lifecycle / Troubleshooting / Admin CLI). EDIT the ~7 stale regions.
           Preserve every unchanged row/line verbatim."

- file: plan/002_97982899bef6/P2M4T1S1/PRP.md   (parallel sibling — CONTRACT for SKILL.md)
  why: SKILL.md's §5 points at THIS file. SKILL.md hard-asserts: zero DISABLE/transparent/shadowing/
        `agent-browser open`; meta list = skills/--version/session list/dashboard/plugin/mcp (NO
        --help/-h); master = real ~/.config/google-chrome. configuration.md MUST agree → the --help/-h
        callout (E6) is the linchpin of cross-doc consistency. DISJOINT file → composes in either order.
```

### Current codebase tree (relevant slice)

```bash
.agents/skills/agent-browser-pool/
├── SKILL.md                      # UNTOUCHED here (P2.M4.T1.S1 rewrites it IN PARALLEL)
├── README.md                     # UNTOUCHED (P2.M4.T3.S1)
└── references/
    └── configuration.md          # 134 lines — EDITED IN PLACE by this item (E1-E11)
bin/agent-browser-pool            # UNTOUCHED (P2.M2 done; the entry point — READ only)
bin/agent-browser                 # DELETED (P2.M2.T2.S1)
lib/pool.sh                       # UNTOUCHED (P2.M1 done; the behavior the doc describes — READ only)
install.sh                        # UNTOUCHED (P2.M3.T1.S1, done)
README.md                         # UNTOUCHED (P2.M6.T1.S1)
test/*                            # UNTOUCHED (P2.M5). NOT run here (AGENTS.md §1).
PRD.md                            # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
.agents/skills/agent-browser-pool/
└── references/
    └── configuration.md   # EDITED (~135-145 lines): accurate for the no-DISABLE/fail-fast model.
# No new files. No deletions. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
CRITICAL (the AGENT_CHROME_MASTER default is an EXACT expression, not a path): it MUST read
  `${XDG_CONFIG_HOME:-~/.config}/google-chrome` (the shell-style default), matching pool_config_init
  (lib/pool.sh:146-148) and pool_admin_help's "~/.config/google-chrome — your real Chrome user-data-dir"
  (lib/pool.sh:4624). Do NOT write a literal expanded path and do NOT write "master-profile"
  (the old default). Item LOGIC a.

CRITICAL (no-pi-ancestor is FAIL-FAST, not passthrough): the OLD dispatch item 3 ("No pi ancestor →
  passthrough (human in a terminal)") is DEAD. The NEW item states the call pool_die's with the exact
  guidance string. Never say "passthrough" for no-pi-ancestor. The word "passthrough" is KEPT ONLY for
  META commands (that behavior is real + unchanged). Item LOGIC e.

CRITICAL (quote the exact fail-fast guidance string): the dispatch table + troubleshooting fix must
  echo the shipped pool_die message (lib/pool.sh:3645-3646): "driving commands require a pi ancestor;
  for raw browser use call 'agent-browser' directly". Do not paraphrase the actionable part.

CRITICAL (--help/-h/help are POOL VERBS, not meta-passthrough): bin/agent-browser-pool's outer case
  intercepts --help|-h|help → pool_admin_help BEFORE pool_wrapper_main/pool_dispatch_classify. So the
  meta-commands list must NOT include --help/-h. KEEP --version (it falls through to *)→classify→meta→
  passthrough). This is REQUIRED for consistency with the parallel SKILL.md (P2.M4.T1.S1), whose meta
  list also omits --help/-h. Add the callout explaining it. Item LOGIC e + cross-doc consistency.

CRITICAL (bare `agent-browser-pool` defaults to `status`, NOT meta): bin/agent-browser-pool does
  cmd="${1:-status}", so a bare invocation hits the status) arm. The OLD meta-list item "A bare
  'agent-browser' with no subcommand (upstream prints help)" is doubly wrong. Replace with a
  flags-only invocation (e.g. `agent-browser-pool --json`) → classify → meta → help.

CRITICAL (the canonical example is `agent-browser-pool open`, NOT `agent-browser open`): the "How
  acquire works" diagram must open with `agent-browser-pool open <url>`. The bottom line "exec the
  real agent-browser with cleaned args" stays as-is (the pool DOES internally exec the real binary).
  Item LOGIC g.

CRITICAL (the "three that most affect behavior" must drop DISABLE): replace the DISABLE bullet with an
  AGENT_CHROME_MASTER bullet — it now "defaults to your real Chrome user-data-dir, so agents pick up
  new auth/logins automatically". Keep AGENT_CHROME_ALLOW_SLOW_COPY and AGENT_CHROME_HEADLESS bullets.
  Item LOGIC d.

CRITICAL (validation is STATIC ONLY — AGENTS.md §1/§6): a Markdown edit cannot hang the sandbox, but
  we STILL never boot Chrome, never run test/*, never run install.sh, never invoke
  agent-browser/agent-browser-pool. Validation = grep + shellcheck on the embedded bash snippets +
  a Markdown structure check + a git status scope check. No execution of anything.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is a targeted edit of one Markdown reference file. The file is the
deliverable; the exact final content is given in the "Target configuration.md (verbatim)" block below.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the current file + the live behavior sources (context — no writes)
  - READ: .agents/skills/agent-browser-pool/references/configuration.md   (134 lines — the file being edited)
  - CONFIRM (grep/read-only): lib/pool.sh has ZERO 'AGENT_BROWSER_POOL_DISABLE' (P2.M1.T1.S1);
           pool_config_init @144-148 master default = $xdg_cfg/google-chrome (real Chrome dir);
           pool_wrapper_main @3641-3646 no-pi-ancestor → pool_die with the exact guidance string;
           pool_admin_help @4624 prints "AGENT_CHROME_MASTER ... default: ~/.config/google-chrome
           — your real Chrome user-data-dir" with NO DISABLE row.
  - CONFIRM (read-only): bin/agent-browser-pool outer case intercepts --help|-h|help → pool_admin_help;
           --version falls through to *) → pool_wrapper_main → classify → meta → passthrough;
           bare invocation → cmd="${1:-status}" → status) arm.
  - WHY: anchors every claim in the rewritten doc against SHIPPED behavior (no guesses).

Task 2: REWRITE .agents/skills/agent-browser-pool/references/configuration.md  (the deliverable)
  - WRITE: .agents/skills/agent-browser-pool/references/configuration.md  (overwrite IN PLACE)
  - CONTENT: the EXACT Markdown in the "Target configuration.md (verbatim)" block below.
  - WHY: gap_analysis §6 + PRD §2.11/§2.4/§2.7/§2.17/§2.14 + item LOGIC (a)-(h). Makes the reference
         accurate for the no-DISABLE/fail-fast model + consistent with the parallel SKILL.md.
  - APPLY these edits (edit map; each is a localized change — unchanged regions preserved verbatim):
      E1 (LOGIC a) line 19  AGENT_CHROME_MASTER row → default ${XDG_CONFIG_HOME:-~/.config}/google-chrome;
            meaning: real Chrome user-data-dir, may be live/in-use (PRD §2.7), never launch/mutate/delete.
      E2 (LOGIC b) line 28  DELETE the AGENT_BROWSER_POOL_DISABLE env-table row.
      E3 (LOGIC d) lines 32-35  REPLACE the "DISABLE — the safety valve" bullet with an
            AGENT_CHROME_MASTER bullet (defaults to real Chrome → agents pick up new auth).
      E4 (LOGIC e) line 48  DELETE dispatch item 1 ("DISABLE truthy → passthrough").
      E5 (LOGIC e) lines 49-51  RENUMBER + reframe dispatch items: (1) meta→passthrough;
            (2) no pi ancestor→fail-fast (pool_die with exact guidance); (3) otherwise→acquire/find.
      E6 (LOGIC e, consistency) line 55  meta-list: drop --help/-h (pool verbs); keep --version;
            add callout that --help/-h/help are pool verbs intercepted by bin/agent-browser-pool.
      E7 (accuracy) line 58  meta-list "bare agent-browser no subcommand" → flags-only invocation
            (e.g. --json); note bare agent-browser-pool defaults to status.
      E8 (accuracy) line 66  drop "with pooling active" (DISABLE-era vestige; pooling unconditional).
      E9 (LOGIC g) line 73  diagram: agent-browser open <url> → agent-browser-pool open <url>.
      E10 (LOGIC f) line 110  troubleshooting row 1: cause → "driving run outside pi (no pi ancestor
            → fail-fast)"; fix → "Run under pi; for raw browser use call agent-browser directly".
      E11 (g spirit) line 112  troubleshooting row 3 symptom: "agent-browser call hangs" →
            "agent-browser-pool call hangs".
  - PRESERVED VERBATIM (do NOT touch): title + intro (1-8); env-table rows except MASTER/DISABLE;
      test-only-hooks callout; "Driving commands" subsection; "How acquire works" prose + rest of
      diagram; entire "Release lifecycle"; troubleshooting rows 2,4-8; "Admin CLI" section.
  - BUCKET: required (the entire deliverable is this one file).

Task 3: STATIC VALIDATION  (AGENTS.md §1: static only — no execution)
  - RUN: the grep + shellcheck + Markdown + scope assertions in §Validation Loop Level 1.
  - RUN: git status --short   (expect configuration.md; scope-tolerant of the parallel SKILL.md —
         assert NO change OUTSIDE .agents/skills/agent-browser-pool/).
  - WHY: contract + AGENTS.md §1. No Chrome, no daemons, no test suite.
  - BUCKET: required.
```

#### Target configuration.md (verbatim — the exact artifact to write in Task 2)

> This is the complete, final `references/configuration.md`. Write it to
> `.agents/skills/agent-browser-pool/references/configuration.md`, overwriting the existing file.
> ~140 lines. Valid Markdown. Every behavioral claim is pinned to a SHIPPED function + line anchor
> in `lib/pool.sh`/`bin/agent-browser-pool` (see §Documentation & References).

```markdown
# Agent Browser Pool — configuration & reference

Detailed lookup material for the `agent-browser-pool` skill. Read this when you need exact
env-var values, the full command dispatch table, the acquire lifecycle, or a
troubleshooting matrix. For the procedural "how to use your lane" guide, see `SKILL.md`.

All of this reflects the shipped behavior in `lib/pool.sh` (`pool_config_init`,
`pool_dispatch_classify`, `pool_wrapper_main`, `pool_admin_*`). Defaults assume the standard
install; this host may override any of them via environment.

## Environment variables (all optional)

Every path is resolved to an **absolute** path before any subprocess — a bare `~` is never
passed to Chrome, `rm`, or a log. "Truthy" means `1`/`true`/`yes`/`on` (case-insensitive).

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `~/.local/state/agent-browser-pool` | state dir: `lanes/<N>.json` leases, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log` |
| `AGENT_CHROME_MASTER` | `${XDG_CONFIG_HOME:-~/.config}/google-chrome` | CoW source — your real Chrome user-data-dir. Agents copy current state on each acquire, so new logins propagate. May be live/in-use (PRD §2.7). **Never launch, mutate, or delete.** |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/` (deleted on release) |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL `agent-browser` CLI (called by absolute path; stays upgradable) |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; a path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | number of ports → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (seconds) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | truthy → launch Chrome with `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | truthy → permit a real (slow) ~4.8 GB copy per acquire |

The three that most affect behavior:

- **`AGENT_CHROME_MASTER`** — the CoW source, defaulting to your real Chrome user-data-dir
  (`~/.config/google-chrome`). Agents copy it fresh on each acquire, so new logins/auth you
  create in Chrome propagate to agents automatically. It may even be live/in-use (PRD §2.7).
  Point it at a dedicated template if you want a fixed source instead.
- **`AGENT_CHROME_ALLOW_SLOW_COPY`** — on non-btrfs the wrapper refuses the expensive copy
  by default; set this only if you accept a slow acquire.
- **`AGENT_CHROME_HEADLESS`** — off by default (trusted profiles must look real; headless is
  detectable). Set it for headless/server hosts.

> **Test-only hooks** (not for users): `AGENT_BROWSER_POOL_OWNER_PID` and
> `AGENT_BROWSER_POOL_OWNER_STARTTIME` simulate distinct agent owners without a real `pi`
> ancestor. Never set these in normal use.

## Command dispatch: meta vs. driving

The wrapper classifies each invocation **before** touching a lane. Decisions (in order, first
match wins) from `pool_wrapper_main`:

1. **meta** command → **passthrough** (no lane — the real binary runs unchanged).
2. No `pi` ancestor in the process tree → **fail-fast**: `pool_die` with
   "agent-browser-pool: driving commands require a pi ancestor (owning pi process). For raw
   browser use without pooling, call 'agent-browser' directly."
3. Otherwise → acquire/find your lane, then run the command against it.

### Meta commands (passthrough — never acquire a lane)

These reach the real `agent-browser` unchanged, without acquiring a lane:

- `--version`
- `skills`, `dashboard`, `plugin`, `mcp`
- `session list`
- A flags-only invocation with no subcommand (e.g. `agent-browser-pool --json`) — upstream prints help/usage

> `--help`, `-h`, and `help` are **pool verbs**, not meta-passthrough: the entry-point
> dispatcher (`bin/agent-browser-pool`) catches them first and prints the pool's own help
> (`pool_admin_help`), so they never reach the real binary. A bare `agent-browser-pool`
> (no arguments) is also a pool verb — it defaults to `status`. See "Admin CLI" below.

### Driving commands (use your lane)

Everything else, including:

- `open <url>`, `connect <port|url>` (arg ignored — pool owns connection), `close [--all]`
- `get <resource>` (e.g. `get cdp-url`), `screenshot`, scrape/automate commands
- **Any unrecognized command** (defaults to driving, so unknown verbs still get a lane)

## How acquire works (the lifecycle)

For a driving command under `pi`:

```
agent-browser-pool open <url>
 │ 1. resolve owning pi PID (walk ppid → comm == 'pi'); record (pid, starttime) identity
 ├─ already hold a lease for me?  → reuse my lane (skip boot)
 ├─ else acquire (under flock):
 │     reap stale lanes → reuse an orphaned-but-live lane  OR
 │     CoW-copy master → ephemeral → pick a free port → launch Chrome (setsid pgroup) →
 │     wait for CDP → connect the agent-browser daemon
 ├─ ensure connected (reconnect if the daemon died since last call)
 ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
 └─ exec the real agent-browser with cleaned args   (process replacement)
```

Lane identity is keyed on the owning `pi` **PID + starttime** (not PID alone — PID recycling
is real). That triple is what guarantees a crashed agent's lane is detected as stale and
reclaimed, and that a recycled PID can never hijack your lane.

## Release lifecycle (teardown)

Release happens when **any** of these occurs:

- **Your owning `pi` process exits** → the lane becomes stale → the next acquire's reaper
  (or `agent-browser-pool reap`) tears it down. This is the normal path for agents.
- **Explicit `agent-browser-pool release <N>` / `release all`** → operator-driven teardown.
- **Pool exhaustion** → after `AGENT_BROWSER_POOL_WAIT`, the oldest dead-owner lane is
  force-reclaimed (with a desktop alert + `alerts.log` entry).

Release = kill the Chrome **process group** (`SIGTERM` → `SIGKILL`), `rm -rf` the ephemeral
profile dir, drop the lease. There is **no idle TTL** — a lane persists until its owner dies
or it's explicitly released.

`close` is **not** release: it disconnects the daemon only; the lane, Chrome, and ephemeral
dir survive for reuse within the session.

## Troubleshooting matrix

| Symptom | Likely cause | Fix / response |
|---|---|---|
| Wrong browser / no lane acquired | Driving command run outside `pi` (no pi ancestor → fail-fast) | Run your browser work under `pi`; for raw browser use call `agent-browser` directly |
| `connect <port>` "did nothing" | By design — the pool owns the connection and drops your arg | It worked; your lane is already connected. Use `agent-browser-pool status` to confirm |
| `agent-browser-pool` call hangs a long time | Pool exhausted (all lanes busy); self-healing reaper running | Wait; it reaps dead owners and force-reclaims after `AGENT_BROWSER_POOL_WAIT` (600s). Don't boot Chrome directly |
| `close` didn't free my lane / Chrome still running | By design — `close` is disconnect-only; lane survives for reuse | End your session to release; or ask the operator to run `release <N>` |
| Session logins/cookies didn't persist | Ephemeral profile is deleted on release, never written to master | By design — re-establish each session |
| `status` shows my lane as `disconnected` | Daemon dropped but Chrome alive | Your next driving command re-binds automatically |
| `status` shows my lane as `STALE` / field `?` | Owner process died or lease is corrupt | The reaper will reclaim it; the operator can run `reap` |
| `doctor` reports WARN lines | Cruft from crashed agents (orphan dirs, dead Chrome, stale leases) | Operator-only: `agent-browser-pool reap` then `release <N>` / `release all` |

## Admin CLI (operator-facing)

`agent-browser-pool` is the **operator** admin tool. With no command, `status` is assumed.
**Read-only and safe for any process:** `status`, `doctor`. **Mutating — operator use:**
`reap`, `release [<N>|all]`. As an agent, prefer leaving teardown to the automatic reaper
and only touch these if asked.

```
agent-browser-pool                 # status (default)
agent-browser-pool status
agent-browser-pool reap            # tear down lanes whose owner died
agent-browser-pool release 1       # explicit teardown of one lane
agent-browser-pool release all     # clear the whole pool
agent-browser-pool doctor          # diagnose the pool (exits 1 if unhealthy)
agent-browser-pool help            # aliases: --help, -h
```
```

### Implementation Patterns & Key Details

```markdown
PATTERN — the dispatch table is a 3-step ordered decision, first-match-wins, mirroring
  pool_wrapper_main's actual step order (config→preflight→classify-meta→owner-resolve→acquire).
  The contract's mandated order (meta / no-pi / acquire) matches the shipped order exactly, so the
  doc is truthful, not aspirational.

PATTERN — "passthrough" is retained ONLY for META commands (real, unchanged behavior: the real
  binary runs unchanged). The DEAD concept is "no pi ancestor → passthrough (human terminal)".
  The grep targets enforce the distinction: "AGENT_BROWSER_POOL_DISABLE" and "safety valve" must be
  absent; "passthrough" may remain (for meta).

GOTCHA — --help/-h/help are the subtlest point. pool_dispatch_classify WOULD classify --help/-h as
  'meta', but bin/agent-browser-pool's OUTER case intercepts them → pool_admin_help first. So the
  user-facing truth is "pool verb". --version is NOT in the outer case → reaches classify → meta →
  passthrough. The callout + meta-list exclusion of --help/-h make configuration.md agree with the
  parallel SKILL.md (whose meta list also omits --help/-h). Do NOT re-add --help/-h to the meta list.

GOTCHA — the bottom line of the "How acquire works" diagram ("exec the real agent-browser with
  cleaned args") STAYS as-is. The pool DOES internally exec the real agent-browser; that is accurate.
  Only the TOP line changes (agent-browser open → agent-browser-pool open), because that is the
  command the user TYPES.

GOTCHA — do NOT touch the Admin CLI section, the Release lifecycle, or the unchanged env-table rows.
  Those are already accurate. The scope is E1-E11 only.
```

### Integration Points

```yaml
NONE for this item beyond the reference file tree (one Markdown file edited in place).
  - No code, no config, no env vars are introduced by this item (it is documentation only).
  - The doc CONSUMES (does not modify):
      * lib/pool.sh + bin/agent-browser-pool — the SHIPPED behavior it describes (P2.M1/P2.M2 done).
      * PRD §2.11/§2.4/§2.7/§2.14/§2.17 — the contract it reflects.
  - Cross-doc consumer (parallel):
      * SKILL.md (P2.M4.T1.S1) §5 points at THIS file and hard-asserts the same invariants
        (no DISABLE; master = real Chrome; --help/-h = pool verbs). The two docs compose.
  - Downstream consumers that build on this LATER (NOT here):
      * skill README.md (P2.M4.T3.S1) and repo README.md (P2.M6.T1.S1) mirror the same command model.
      * test/transparency.sh (P2.M5.T2.S1) exercises the live agent-browser-pool commands.
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`grep`, `sed`, `shellcheck`, `test`, `git`).
> **Do NOT boot Chrome, do NOT run any `agent-browser`/`agent-browser-pool` command, do NOT run
> install.sh, do NOT run test/*.sh during this item.** A Markdown edit cannot hang the sandbox, but
> we still execute nothing. Levels 2-4 are N/A by design (a doc has no runtime to validate here).

### Level 1: Structure & content (run after the edit)

```bash
cd /home/dustin/projects/agent-browser-pool
F=.agents/skills/agent-browser-pool/references/configuration.md

# --- structure: section headers (all preserved) ---
for h in '## Environment variables' '## Command dispatch: meta vs. driving' \
         '### Meta commands' '### Driving commands' '## How acquire works' \
         '## Release lifecycle' '## Troubleshooting matrix' '## Admin CLI'; do
  grep -Fq "$h" "$F" && echo "OK: header $h" || echo "FAIL: missing header $h"
done

# --- REMOVALS: each grep MUST find zero matches ---
for pat in 'AGENT_BROWSER_POOL_DISABLE' 'master-profile' 'agent-browser open' 'safety valve'; do
    if grep -nE "$pat" "$F"; then echo "FAIL: found removed pattern: $pat"; else echo "OK: absent: $pat"; fi
done
# the DEAD concept: "no pi ancestor → passthrough" must be gone (meta passthrough may remain)
grep -nE 'No .*pi.*ancestor.*passthrough|no .pi. ancestor.*→.*passthrough' "$F" \
  && echo "FAIL: no-pi-ancestor still described as passthrough" || echo "OK: no-pi-ancestor not passthrough"

# --- ADDITIONS: each grep MUST find a match ---
grep -Fq '${XDG_CONFIG_HOME:-~/.config}/google-chrome' "$F" && echo "OK: master default expression" || echo "FAIL: master default"
grep -Eq 'fail-fast|fails fast' "$F" && echo "OK: fail-fast stated" || echo "FAIL: no fail-fast"
grep -Fq 'driving commands require a pi ancestor' "$F" && echo "OK: exact guidance string" || echo "FAIL: no guidance string"
grep -Fq 'for raw browser use' "$F" && echo "OK: raw-browser guidance" || echo "FAIL: no raw-browser guidance"
grep -Fq 'agent-browser-pool open <url>' "$F" && echo "OK: canonical diagram example" || echo "FAIL: diagram not updated"
# master bullet in "three that most affect behavior"
grep -Eq 'three that most affect' "$F" && grep -nE '^- \*\*`AGENT_CHROME_MASTER' "$F" >/dev/null \
  && echo "OK: MASTER in three-that-affect" || echo "FAIL: MASTER not in three-that-affect"

# --- dispatch table is the 3-step order (1 meta / 2 no-pi fail-fast / 3 otherwise acquire) ---
grep -Eq '^1\. .*\*\*meta\*\* command .*passthrough' "$F" && echo "OK: dispatch (1) meta→passthrough" || echo "FAIL: dispatch (1)"
grep -Eq '^2\. No .pi. ancestor.*fail-fast' "$F" && echo "OK: dispatch (2) no-pi→fail-fast" || echo "FAIL: dispatch (2)"
grep -Eq '^3\. Otherwise.*acquire' "$F" && echo "OK: dispatch (3) otherwise→acquire" || echo "FAIL: dispatch (3)"

# --- meta list excludes --help/-h as passthrough; keeps --version ---
sed -n '/### Meta commands/,/### Driving commands/p' "$F" | grep -Eq '^\- `--help`|^\- `-h`|^\- `--help, -h' \
  && echo "FAIL: --help/-h listed as meta-passthrough" || echo "OK: --help/-h not in meta list"
sed -n '/### Meta commands/,/### Driving commands/p' "$F" | grep -Fq '`--version`' && echo "OK: --version kept in meta" || echo "FAIL: --version missing from meta"
grep -Eq 'pool verbs|pool_admin_help|entry-point dispatcher' "$F" && echo "OK: --help/-h callout present" || echo "FAIL: no --help/-h callout"

# --- troubleshooting row 1 is fail-fast framing (no DISABLE, no unset DISABLE) ---
grep -Fq 'Run your browser work under `pi`; for raw browser use call `agent-browser` directly' "$F" \
  && echo "OK: troubleshooting fix updated" || echo "FAIL: troubleshooting fix stale"
grep -qi 'unset AGENT_BROWSER_POOL_DISABLE' "$F" && echo "FAIL: stale 'unset DISABLE' present" || echo "OK: no 'unset DISABLE'"

# --- shellcheck on the embedded bash snippet(s) (LOGIC h) ---
# The file has two fenced blocks: (1) the acquire ASCII lifecycle DIAGRAM (box-drawing chars,
# <placeholder> tokens, non-shell prose — NOT lintable) and (2) the Admin CLI command list
# (real shell). Toggle in/out of fences; lint only blocks that are real shell.
tmp=$(mktemp -d)
awk -v out="$tmp" '
  /^```/ { if (inblk) { inblk=0; close(out"/block"n".sh") } else { inblk=1; n++ }; next }
  inblk  { print > out"/block"n".sh" }
' "$F"
ok=1
for b in "$tmp"/block*.sh; do
  [ -s "$b" ] || continue
  # skip non-shell blocks (ASCII diagrams: box-drawing chars or <placeholder> tokens)
  if grep -qE '[│├└─]|<[a-zA-Z-]+>' "$b"; then
    echo "skip (illustrative diagram, not shell): $(basename "$b")"; continue
  fi
  if ! shellcheck -s bash "$b" >/dev/null 2>&1; then
    echo "shellcheck issues in $b:"; shellcheck -s bash "$b"; ok=0
  fi
done
[ "$ok" = 1 ] && echo "OK: shellcheck clean on shell snippet(s)" || echo "FAIL: shellcheck issues (review above)"
rm -rf "$tmp"

# --- line count sanity (~130-150) ---
n=$(wc -l < "$F"); echo "lines: $n"
test "$n" -ge 128 -a "$n" -le 152 && echo "OK: line count in range" || echo "FAIL: line count out of range"
```

**Expected**: every assertion prints `OK:`; the 4 removed-pattern greps + the no-pi-passthrough grep
find nothing; all addition greps match; the dispatch table is the exact 3-step order; the meta list
excludes `--help`/`-h` and keeps `--version` with the callout present; troubleshooting fix updated with
no "unset DISABLE"; shellcheck clean on all embedded bash snippets; line count ~140.

### Level 2: Component Validation — N/A

A Markdown reference doc has no component runtime. Its "correctness" is its fidelity to the SHIPPED
behavior in `lib/pool.sh` + `bin/agent-browser-pool`, enforced by the Level-1 grep assertions (each
claim is pinned to a function + line anchor in §Documentation & References). Live exercise of
`agent-browser-pool open <url>` is P2.M5.T2.S1's job (isolated sandbox), not here.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# The behavior the doc describes is SHIPPED (sanity greps — read-only, no execution):
grep -q 'AGENT_BROWSER_POOL_DISABLE' lib/pool.sh && echo "FAIL: lib still has DISABLE" || echo "OK: lib has no DISABLE (doc is truthful)"
grep -q 'driving commands require a pi ancestor' lib/pool.sh && echo "OK: fail-fast shipped (doc quotes it accurately)" || echo "FAIL: fail-fast not shipped"
grep -Eq 'google-chrome' lib/pool.sh && echo "OK: real-Chrome master default shipped" || echo "FAIL: master default not shipped"

# Scope: NO file OUTSIDE the skill directory was modified by this item.
# (configuration.md is this item's file; SKILL.md may also appear if P2.M4.T1.S1 ran in the same tree.)
git status --short
git status --short | grep -vE '^.{2} \.agents/skills/agent-browser-pool/' \
  && echo "FAIL: changes outside the skill dir" || echo "OK: all changes inside the skill dir"

# Confirm the SHIPPED code + siblings are untouched by this item:
for f in lib/pool.sh bin/agent-browser-pool install.sh README.md \
         .agents/skills/agent-browser-pool/README.md \
         .agents/skills/agent-browser-pool/SKILL.md; do
  # SKILL.md is EXPECTED to be touched by the parallel sibling — not a failure for THIS item's scope.
  if [ "$f" = ".agents/skills/agent-browser-pool/SKILL.md" ]; then continue; fi
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done
test -f .agents/skills/agent-browser-pool/references/configuration.md && echo "OK: config.md present" || echo "FAIL: config.md missing"

# Do NOT run: test/*.sh, install.sh, or any agent-browser / Chrome command (AGENTS.md §1).
```

### Level 4: Creative & Domain-Specific Validation — N/A

A documentation edit has no domain runtime. The doc's accuracy is fully pinned by Level 1-3 checks +
the verbatim artifact + the behavior contracts in §Documentation & References.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: every assertion prints `OK:`; no removed pattern present; all additions present.
- [ ] `shellcheck` clean on all embedded bash code-fence snippets (item LOGIC h).
- [ ] All 8 section headers present; line count ~130-150.
- [ ] Scope check: all changes inside `.agents/skills/agent-browser-pool/`; no change to `lib/pool.sh`,
      `bin/*`, `install.sh`, `README.md`, skill `README.md`, `test/*`.

### Feature Validation

- [ ] `AGENT_CHROME_MASTER` default = `${XDG_CONFIG_HOME:-~/.config}/google-chrome` (real Chrome dir).
- [ ] `AGENT_BROWSER_POOL_DISABLE` row + "safety valve" callout removed.
- [ ] "three that most affect behavior" lists `AGENT_CHROME_MASTER` (not DISABLE).
- [ ] Dispatch table = 3-step order: (1) meta → passthrough, (2) no pi ancestor → fail-fast, (3) acquire.
- [ ] Meta list excludes `--help`/`-h` (pool verbs), keeps `--version`, has the callout.
- [ ] "How acquire works" diagram uses `agent-browser-pool open <url>`.
- [ ] Troubleshooting row 1 = fail-fast framing; no "unset DISABLE".
- [ ] Zero references to `AGENT_BROWSER_POOL_DISABLE` / `master-profile` / `agent-browser open`.

### Code Quality / Scope Validation

- [ ] **Only** `.agents/skills/agent-browser-pool/references/configuration.md` is modified by this item.
- [ ] `lib/pool.sh`, `bin/*`, `install.sh`, `SKILL.md`, skill `README.md`, `README.md`, `test/*` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no test suite) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] configuration.md IS the documentation artifact (the detail reference). No separate doc
      file is written by this item.
- [ ] Cross-doc consistency: configuration.md agrees with the parallel SKILL.md (P2.M4.T1.S1) on
      no-DISABLE, real-Chrome master default, and --help/-h-as-pool-verb.

---

## Anti-Patterns to Avoid

- ❌ Don't write the master default as a literal expanded path or as "master-profile" — it is the
      shell-style expression `${XDG_CONFIG_HOME:-~/.config}/google-chrome` (matches pool_config_init).
- ❌ Don't describe no-pi-ancestor as "passthrough" or "human terminal" — it FAILS FAST via `pool_die`.
      Keep "passthrough" ONLY for META commands. (Item LOGIC e.)
- ❌ Don't re-add `AGENT_BROWSER_POOL_DISABLE` anywhere (env row, callout, dispatch item, troubleshooting)
      — all four must be gone. (Item LOGIC b/c/e/f.)
- ❌ Don't list `--help`/`-h` as meta-passthrough — they are POOL VERBS intercepted by the entry-point
      dispatcher (→ `pool_admin_help`). This contradicts the parallel SKILL.md if left wrong.
- ❌ Don't change the bottom line of the acquire diagram ("exec the real agent-browser") — that is
      accurate (the pool internally execs the real binary). Only the top line (`... open <url>`) changes.
- ❌ Don't edit `lib/pool.sh`, `bin/*`, `install.sh`, `SKILL.md`, skill `README.md`, `README.md`, or
      `test/*` — each is owned by a sibling/done/later item.
- ❌ Don't run `test/*.sh`, `install.sh`, or any `agent-browser`/Chrome command during this item —
      AGENTS.md §1 (sandbox-hang prevention). All validation is static (Level 1).
- ❌ Don't skip `shellcheck` on the embedded bash snippets — item LOGIC h requires it.

---

## Confidence Score

**9/10** — one-pass success likelihood. The item is a single-file targeted edit of a Markdown
reference, and the PRP supplies the **exact final configuration.md verbatim** (the artifact is the
spec), so there is no ambiguity about what to write; a precise edit map (E1-E11) explains each change
against shipped behavior for implementers who prefer surgical edits over a full overwrite. Every
behavioral claim is pinned to a SHIPPED function + line anchor in `lib/pool.sh`/`bin/agent-browser-pool`
(verified live: DISABLE fully gone, master default = real Chrome dir, fail-fast message quoted verbatim,
--help/-h intercepted as pool verbs while --version passes through), so the doc is guaranteed truthful.
The subtlest nuance — that `--help`/`-h` are pool verbs, not meta-passthrough — is called out explicitly,
enforced by a Level-1 grep, and made consistent with the parallel SKILL.md. Validation is entirely
static (grep + shellcheck + structure + scope) and cannot wedge the sandbox (AGENTS.md §1). Not 10/10
only because the cross-doc consistency with the parallel SKILL.md depends on both items landing their
respective artifacts; this PRP guarantees THIS file's side of the contract.
