# PRP — P2.M4.T3.S1: Update skill README.md for new model

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`); skill doc is Markdown.
**Work item**: P2.M4.T3.S1 (0.5 points)
**Dependency / starting state**: Builds on the POST-P2.M2 tree. The model this README **describes**
is already SHIPPED and verified: `AGENT_BROWSER_POOL_DISABLE` is **fully removed** from `lib/pool.sh`
(grep → 0; P2.M1 done); the old `bin/agent-browser` PATH-shadow shim is deleted (P2.M2.T2.S1 done);
driving commands outside `pi` **fail fast** via `pool_die` at `lib/pool.sh:3645-3646` with the exact
guidance "For raw browser use without pooling, call 'agent-browser' directly." The sibling
`.agents/skills/agent-browser-pool/SKILL.md` (P2.M4.T1.S1) is **COMPLETE and shipped** in the new
explicit-invocation model (0 matches for `AGENT_BROWSER_POOL_DISABLE`/`transparent`; describes
fail-fast; uses `agent-browser-pool` throughout). The sibling `references/configuration.md`
(P2.M4.T2.S1) is being updated **in parallel** to the same model. **This item edits exactly ONE
file**: `.agents/skills/agent-browser-pool/README.md` (currently **39 lines** — the contract's
"~50 lines" is an overestimate; the edit keeps it ~40). The README is the skill's high-level blurb
("what this skill IS + what it covers"); it must agree with SKILL.md + configuration.md but must NOT
duplicate their detail. **Full research notes**: `plan/002_97982899bef6/P2M4T3S1/research/notes.md`

---

## Goal

**Feature Goal**: Update `.agents/skills/agent-browser-pool/README.md` so it describes the skill as
teaching the **live** explicit-invocation model — `agent-browser-pool` as a **Chrome-profile pool**
(an explicit tool, not a "transparent wrapper") whose lane is created on the **first driving
`agent-browser-pool` command** and whose pitfalls include **failing fast without a `pi` ancestor**
— instead of the dead shadowing-era language it currently uses ("transparent Chrome-profile wrapper",
"`agent-browser` command", "passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`)").

**Deliverable**: An edited `.agents/skills/agent-browser-pool/README.md` (~40 lines) whose opening
paragraph calls `agent-browser-pool` a "Chrome-profile pool" (no "transparent … wrapper"); whose
"Acquire + connect" bullet says the lane is created on the first driving **`agent-browser-pool`**
command (not `agent-browser`); whose "Pitfalls" bullet says driving commands **fail fast without a
`pi` ancestor** (use `agent-browser` directly for raw access) with **zero** mention of
`AGENT_BROWSER_POOL_DISABLE` or "passthrough"; and whose "Teardown" bullet, "Files" section, and
"Installation" section are preserved verbatim. The exact final file is provided verbatim in
§Implementation Blueprint (Target README.md). **No other file is modified by this item.**

**Success Definition**:
- `.agents/skills/agent-browser-pool/README.md` exists and is valid Markdown (same 4 sections as today).
- `grep` confirms REMOVALS in the file: zero matches for `transparent`, `AGENT_BROWSER_POOL_DISABLE`,
  the dead phrase `passthrough`, and the wrong example `` `agent-browser` command ``.
- `grep` confirms ADDITIONS: `Chrome-profile pool`, `agent-browser-pool` command (the corrected
  example), `fail fast`/`fails fast` (the no-pi-ancestor framing), and the raw-access guidance
  `` `agent-browser` directly ``.
- The "Files" section still lists `SKILL.md` + `references/configuration.md`; the "Installation"
  section (both bash code fences) is unchanged.
- `shellcheck` passes on both embedded bash code-fence snippets (unchanged install snippets; lint for rigor).
- **Only** `.agents/skills/agent-browser-pool/README.md` is modified by this item (scope check tolerant
  of the parallel SKILL.md/configuration.md changes — see §Validation Loop Level 3).

---

## Why

- **PRD alignment**: PRD §1.3 (h3.2) goal #1 "Explicit, invariant invocation … The agent does not — and
  cannot — name a lane." PRD §2.4 (h3.8) fixes the entry-point model: `agent-browser-pool <verb>` is the
  sole router; step 1 "No pi ancestor → DRIVING fails fast ('requires a pi ancestor; for raw browser use
  call `agent-browser` directly')". PRD §2.17 (h3.21): "Removed: the `AGENT_BROWSER_POOL_DISABLE` safety
  valve (nothing to bypass)." The current README advertises the skill as teaching a "transparent
  Chrome-profile wrapper" with a "`AGENT_BROWSER_POOL_DISABLE` passthrough" pitfall — the **opposite** of
  the shipped model. It is the first doc an agent/human sees when discovering the skill, so if it's wrong
  it poisons expectations before SKILL.md even loads.
- **Who it helps**: Anyone discovering the skill (an agent scanning `.agents/skills/*/`, or a human
  browsing the repo). They should immediately learn "this skill teaches `agent-browser-pool`, an explicit
  Chrome-profile pool" — not "a transparent wrapper with a DISABLE escape hatch." Correct framing here
  aligns the README with SKILL.md's headline invariant ("The command never names a lane") and
  configuration.md's fail-fast dispatch table.
- **Scope cohesion**: This is item T3.S1 of milestone P2.M4 (Skill & Reference Documentation). Its
  sibling P2.M4.T1.S1 (SKILL.md) is COMPLETE; P2.M4.T2.S1 (configuration.md) is in flight in parallel.
  The README references both via its "Files" section. The later P2.M6.T1.S1 rewrites the repo-level
  `README.md` to the same model. This item touches ONLY the skill's `README.md`; `lib/pool.sh`, `bin/*`,
  `SKILL.md`, `references/configuration.md`, repo `README.md`, `install.sh`, `test/*` are all untouched here.

---

## What

**User-visible behavior**: A reader of the skill's `README.md` learns, in ~40 lines, that this Agent
Skill teaches `agent-browser-pool` — an explicit **Chrome-profile pool** (not a transparent wrapper) —
and that it covers: (1) acquire+connect on the first driving **`agent-browser-pool`** command under `pi`
(agents don't pass ports/`--session`); (2) teardown (`close` = disconnect-only; real release is automatic
on `pi` exit; avoid `release`/`reap` as routine cleanup); (3) pitfalls — driving commands **fail fast
without a `pi` ancestor** (use `agent-browser` directly for raw access), pool-exhaustion hangs, ephemeral
profiles, and never launching Chrome directly. The "Files" and "Installation" sections are unchanged.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `lib/pool.sh` — the SHIPPED behavior this README summarizes (read-only; P2.M1 done).
- `bin/agent-browser-pool` — the entry point (P2.M2 done; read-only).
- `.agents/skills/agent-browser-pool/SKILL.md` — the procedural skill (P2.M4.T1.S1, COMPLETE).
- `.agents/skills/agent-browser-pool/references/configuration.md` — the detail reference (P2.M4.T2.S1, parallel).
- repo `README.md`, `install.sh`, `test/*` — each owned by a sibling/later item.
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.

### Success Criteria

- [ ] Opening paragraph calls `agent-browser-pool` a "Chrome-profile pool" (no "transparent … wrapper").
- [ ] "Acquire + connect" bullet says "first driving **`agent-browser-pool`** command under `pi`".
- [ ] "Pitfalls" bullet says driving commands **fail fast** without a `pi` ancestor; references using
      `agent-browser` directly for raw access.
- [ ] Zero matches for `transparent`, `AGENT_BROWSER_POOL_DISABLE`, `passthrough`, `` `agent-browser` command ``.
- [ ] "Teardown" bullet, "Files" section (SKILL.md + configuration.md), and "Installation" section (both
      bash code fences) are byte-for-byte unchanged.
- [ ] `shellcheck` passes on both embedded bash code-fence snippets.
- [ ] Only `.agents/skills/agent-browser-pool/README.md` modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the EXACT final README.md is provided verbatim in §Implementation Blueprint
(Target README.md, full file), so there is no ambiguity about what to write; plus a precise edit map
(E1-E4) explaining each change against shipped behavior; plus the exact grep assertions for every
removal/addition; plus the verified truth anchors (DISABLE count = 0 in lib/pool.sh; the exact fail-fast
guidance string at lib/pool.sh:3645-3646; sibling SKILL.md already shipped clean); plus the explicit
disjointness map (which sibling items own which files). No guessing.

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §7
  why: "Skill README.md — UPDATE (~50 lines). Remove 'transparent wrapper' language; remove
        AGENT_BROWSER_POOL_DISABLE pitfall mention."
  critical: "This IS the item's contract. The verbatim file in this PRP implements it exactly, plus
             the item-description LOGIC (a)-(d) which elaborates §7 into 4 precise edits."

- item_description: P2.M4.T3.S1 LOGIC (a)-(d)
  why: The precise edit map. (a) description: 'transparent Chrome-profile wrapper' → 'agent-browser-pool
        Chrome-profile pool' or similar; (b) 'first driving agent-browser command' → 'first driving
        agent-browser-pool command'; (c) pitfalls: remove AGENT_BROWSER_POOL_DISABLE; 'no pi ancestor →
        passthrough' → 'no pi ancestor → fails fast (use agent-browser directly for raw access)';
        (d) keep Files + Installation sections largely unchanged.
  critical: "The 4 edits E1-E4 in this PRP map 1:1 onto LOGIC (a)-(d)."

- prd: PRD.md §1.3 (h3.2) — Goals
  why: Goal #1 "Explicit, invariant invocation … cannot name a lane." Source for E1 (drop 'transparent
        wrapper' — the pool is now an EXPLICIT tool) and the framing 'Chrome-profile pool'.

- prd: PRD.md §2.4 (h3.8) — Request lifecycle
  why: step 1 "No pi ancestor → DRIVING fails fast ('requires a pi ancestor; for raw browser use call
        agent-browser directly')" + step 5 "EXEC the REAL binary: ... agent-browser <cleaned args>".
        Source for E2 (the USER types agent-browser-pool; the pool internally execs the real binary) +
        E3 (fail-fast framing + raw-access guidance).

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "Removed: the AGENT_BROWSER_POOL_DISABLE safety valve (nothing to bypass)." Source for E3 (DISABLE
        pitfall mention must be gone).

- file: lib/pool.sh   (READ only — the behavior the README summarizes; P2.M1 done)
  why: >
    VERIFIED LIVE: grep -c AGENT_BROWSER_POOL_DISABLE → 0 (DISABLE fully removed, P2.M1.T1).
    pool_wrapper_main step d (lib/pool.sh:3645-3646): no-pi-ancestor → pool_die with EXACT message
      "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." /
      "For raw browser use without pooling, call 'agent-browser' directly." ← the raw-access guidance
      the README's Pitfalls bullet echoes.

- file: .agents/skills/agent-browser-pool/SKILL.md   (sibling — COMPLETE/shipped; READ only)
  why: The procedural skill this README advertises. Already shipped in the new model (VERIFIED:
       grep -c 'AGENT_BROWSER_POOL_DISABLE|transparent' → 0; grep -c 'agent-browser-pool' → 14;
       describes fail-fast). The README's bullets are the one-line versions of SKILL.md's §1-§4. They
       MUST agree (no 'transparent wrapper'; fail-fast; agent-browser-pool as the command).
  critical: "SKILL.md is the source of truth for what the skill covers. The README is its summary. Do
             NOT duplicate SKILL.md's procedural detail (connection rules, meta list, safety rules) into
             the README — keep the README a high-level blurb."

- file: .agents/skills/agent-browser-pool/references/configuration.md   (sibling — P2.M4.T2.S1, parallel)
  why: The README's 'Files' section references it. It is being updated in parallel to the same model
       (no DISABLE; fail-fast dispatch). The README's Pitfalls bullet is the one-liner; the full matrix
       lives there. No conflict — disjoint files.

- file: .agents/skills/agent-browser-pool/README.md   (CURRENT 39-line file — EDITED)
  why: The file being updated. Read it to see exactly what changes: 'transparent Chrome-profile wrapper'
       (line 4); '`agent-browser` command under `pi`' (line 11); 'passthrough (no `pi` ancestor /
       AGENT_BROWSER_POOL_DISABLE)' (lines 16-17). Everything else stays.
  pattern: "KEEP the 4-section skeleton (intro / What it covers / Files / Installation) and BOTH bash
           code fences verbatim. EDIT only the 3 localized phrases (E1-E3)."
  gotcha: "The current line count is 39, not ~50 (the contract's estimate). The edit keeps it ~40.
           'Largely unchanged' (LOGIC d) applies — do NOT expand or restructure."
```

### Current codebase tree (relevant slice)

```bash
.agents/skills/agent-browser-pool/
├── SKILL.md                      # COMPLETE/shipped new model (P2.M4.T1.S1) — READ only
├── README.md                     # 39 lines — EDITED IN PLACE by this item (E1-E4)
└── references/
    └── configuration.md          # P2.M4.T2.S1 updating it IN PARALLEL — READ only
bin/agent-browser-pool            # UNTOUCHED (P2.M2 done; the entry point — READ only)
bin/agent-browser                 # DELETED (P2.M2.T2.S1) — README must never advertise it
lib/pool.sh                       # UNTOUCHED (P2.M1 done; the behavior the README summarizes — READ only)
install.sh                        # UNTOUCHED (P2.M3.T1.S1)
README.md                         # UNTOUCHED (P2.M6.T1.S1, later)
test/*                            # UNTOUCHED (P2.M5). NOT run here (AGENTS.md §1).
PRD.md                            # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
.agents/skills/agent-browser-pool/
└── README.md   # EDITED (~40 lines): accurate for the no-DISABLE/fail-fast explicit-invocation model.
# No new files. No deletions. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
CRITICAL (the description phrase is an EXACT swap — preserve the sentence structure): the current
  sentence is "how to use the [`agent-browser-pool`](../..) transparent Chrome-profile wrapper correctly".
  Replace ONLY "transparent Chrome-profile wrapper" → "Chrome-profile pool", keeping the markdown link
  [`agent-browser-pool`](../..) and the trailing "correctly:". The result reads "...the agent-browser-pool
  Chrome-profile pool correctly" — the mild "agent-browser-pool ... pool" repetition is SANCTIONED by
  item LOGIC a ('agent-browser-pool Chrome-profile pool' or similar) and mirrors the original's
  "agent-browser-pool ... wrapper" structure. Do NOT invent a different sentence. (E1.)

CRITICAL (the corrected example is `agent-browser-pool`, NOT `agent-browser`): the "Acquire + connect"
  bullet's "the first driving `agent-browser` command under `pi`" becomes "the first driving
  `agent-browser-pool` command under `pi`". The backticks + "command under `pi`" framing stay. This is
  the one place the README names the typed command — it must be `agent-browser-pool`. (E2.) NOTE: a bare
  `` `agent-browser` `` DOES legitimately reappear in the NEW Pitfalls bullet ("use `agent-browser`
  directly for raw access") — that is CORRECT (it names the real unshadowed binary, the fail-fast
  guidance's escape hatch), NOT the old driving-command example. The grep for the removal is specifically
  `` `agent-browser` command `` (backtick-agent-browser-backtick-space-command), i.e. the wrong driving
  example — NOT every `agent-browser` mention.

CRITICAL (the Pitfalls bullet must DROP both DISABLE and the dead 'passthrough' framing): the old bullet
  "passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`)" is doubly dead — 'passthrough' for
  no-pi-ancestor is false (it fails fast now), and DISABLE no longer exists. Replace with "driving
  commands fail fast without a `pi` ancestor (use `agent-browser` directly for raw access)". This echoes
  the shipped pool_die guidance (lib/pool.sh:3646) verbatim in spirit. (E3.) The word "passthrough" is
  FULLY REMOVED from this README (it appears nowhere else here — unlike SKILL.md/configuration.md, which
  KEEP "pass straight through" for meta commands; this README doesn't discuss meta passthrough at all).

CRITICAL (the "Teardown" bullet is ALREADY correct — leave it alone): it already says "`close` is
  disconnect-only", "the real release happens automatically when the owning `pi` process exits", and
  "avoid `agent-browser-pool release`/`reap` (operator tools; `release <N>` is not owner-scoped)". All
  accurate under the new model. Do NOT touch it. (E4.)

CRITICAL (the Files + Installation sections are directory-structure docs, not command docs — leave them
  alone): they reference `.agents/skills/agent-browser-pool/`, `~/.agents/skills/agent-browser-pool`, and
  `pi --skill ...` — none of which changed in the pivot. Both bash code fences are unchanged installation
  snippets. (E4 / LOGIC d.) Lint them with shellcheck for rigor but expect zero changes.

CRITICAL (do NOT duplicate SKILL.md / configuration.md): the README is a ~40-line blurb. Do NOT pull in
  the connection rules, the meta/driving command list, the env-var table, the dispatch table, or the
  troubleshooting matrix — SKILL.md and configuration.md own those. The README's job is the one-line
  "what it covers" summary + where to find more.

CRITICAL (validation is STATIC ONLY — AGENTS.md §1/§6): a Markdown edit cannot hang the sandbox, but we
  STILL never boot Chrome, never run test/*, never run install.sh, never invoke agent-browser /
  agent-browser-pool. Validation = grep + shellcheck on the 2 bash snippets + a Markdown structure
  check + a git status scope check. No execution of anything.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is a targeted edit of one Markdown skill README. The file is the
deliverable; the exact final content is given in the "Target README.md (verbatim)" block below.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the current file + the live behavior sources (context — no writes)
  - READ: .agents/skills/agent-browser-pool/README.md   (39 lines — the file being edited)
  - CONFIRM (grep/read-only): lib/pool.sh has ZERO 'AGENT_BROWSER_POOL_DISABLE' (P2.M1 done);
           pool_wrapper_main @3645-3646 no-pi-ancestor → pool_die with the exact guidance string
           ("...require a pi ancestor..." / "For raw browser use without pooling, call 'agent-browser'
           directly.").
  - CONFIRM (read-only): sibling .agents/skills/agent-browser-pool/SKILL.md is shipped in the new model
           (0 matches for DISABLE/transparent; describes fail-fast; uses agent-browser-pool throughout).
  - WHY: anchors every claim in the rewritten README against SHIPPED behavior (no guesses).

Task 2: EDIT .agents/skills/agent-browser-pool/README.md  (the deliverable)
  - EDIT: .agents/skills/agent-browser-pool/README.md   (edit IN PLACE — overwrite or surgical edits)
  - CONTENT: the EXACT Markdown in the "Target README.md (verbatim)" block below.
  - WHY: gap_analysis §7 + item LOGIC (a)-(d) + PRD §1.3/§2.4/§2.17. Makes the skill README accurate for
         the no-DISABLE/fail-fast explicit-invocation model + consistent with the shipped SKILL.md.
  - APPLY these edits (edit map; each is a localized phrase change — everything else preserved verbatim):
      E1 (LOGIC a) line 4   "transparent Chrome-profile wrapper" → "Chrome-profile pool"
            (keep the [`agent-browser-pool`](../..) link and the trailing "correctly:").
      E2 (LOGIC b) line 11  "`agent-browser` command under `pi`" → "`agent-browser-pool` command under `pi`".
      E3 (LOGIC c) lines 16-17  "passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`)"
            → "driving commands fail fast without a `pi` ancestor (use `agent-browser` directly for raw
            access)".
      E4 (LOGIC d) lines 1-3, 5-6, 8-15, 19-39   PRESERVED VERBATIM (intro remainder, What-it-covers
            header + Acquire/Teardown bullets, Files section, Installation section + both bash fences).
  - BUCKET: required (the entire deliverable is this one file).

Task 3: STATIC VALIDATION  (AGENTS.md §1: static only — no execution)
  - RUN: the grep + shellcheck + Markdown + scope assertions in §Validation Loop Level 1.
  - RUN: git status --short   (expect README.md; scope-tolerant of the parallel SKILL.md/configuration.md
         — assert NO change OUTSIDE .agents/skills/agent-browser-pool/).
  - WHY: contract + AGENTS.md §1. No Chrome, no daemons, no test suite.
  - BUCKET: required.
```

#### Target README.md (verbatim — the exact artifact to write in Task 2)

> This is the complete, final `.agents/skills/agent-browser-pool/README.md`. Write it to that path,
> overwriting the existing file. ~40 lines. Valid Markdown. Every behavioral claim is pinned to a
> SHIPPED function + line anchor in `lib/pool.sh` (see §Documentation & References).

```markdown
# agent-browser-pool (Agent Skill)

An [Agent Skill](https://github.com/earendil-works/pi-coding-agent) that teaches AI agents
how to use the [`agent-browser-pool`](../..) Chrome-profile pool correctly: how their
dedicated lane is acquired and connected, how it's reused across calls, and how to tear it
down.

## What it covers

- **Acquire + connect:** the lane is created automatically on the first driving
  `agent-browser-pool` command under `pi`; agents don't pass ports or `--session` (the pool
  owns them).
- **Teardown:** `close` is disconnect-only; the real release happens automatically when the
  owning `pi` process exits. Agents should avoid `agent-browser-pool release`/`reap`
  (operator tools; `release <N>` is not owner-scoped).
- **Pitfalls:** driving commands fail fast without a `pi` ancestor (use `agent-browser`
  directly for raw access), pool exhaustion hangs, ephemeral profiles, and why to never
  launch Chrome directly.

## Files

- `SKILL.md` — procedural guide loaded by the agent.
- `references/configuration.md` — env-var table, command dispatch, lifecycle, troubleshooting
  matrix (read on demand).

## Installation

This skill is project-scoped (lives at `.agents/skills/agent-browser-pool/`), so any
Agent Skills-compatible client working in this repo discovers it automatically. To make it
available **globally** (every project), symlink it into your user skills dir:

```bash
ln -s "$(pwd)/.agents/skills/agent-browser-pool" ~/.agents/skills/agent-browser-pool
```

In Pi specifically, you can also load just this skill for a quick check:

```bash
pi --no-skills --skill .agents/skills/agent-browser-pool
```
```

### Implementation Patterns & Key Details

```markdown
PATTERN — a surgical phrase swap, not a rewrite. The file is 39 lines and 3 of them hold the only
  stale text. The verbatim target above is provided so there is zero ambiguity, but a surgical
  implementer can equally apply E1+E2+E3 as 3 `edit` calls and leave the rest byte-identical. Both
  approaches produce the same file (grep validation is content-based, not line-wrap-based).

PATTERN — "fail fast" is the headline behavioral pivot. The OLD README's pitfall was "passthrough (no
  pi ancestor ...)" implying silent human-terminal use. The NEW README states driving commands FAIL
  FAST without a pi ancestor, mirroring SKILL.md §4 ("fails fast") and configuration.md's dispatch
  table (item 2: no pi ancestor → fail-fast). The raw-access parenthetical "use `agent-browser` directly"
  echoes the shipped pool_die guidance (lib/pool.sh:3646) verbatim.

GOTCHA — a bare `agent-browser` mention is NOT automatically wrong. The NEW Pitfalls bullet legitimately
  says "use `agent-browser` directly for raw access" — that names the real unshadowed binary (the
  fail-fast escape hatch), which is CORRECT. The DEAD thing is the driving-COMMAND example
  ("`agent-browser` command under `pi`"). The Level-1 removal grep is the specific string
  `` `agent-browser` command `` (with the backticks + space + "command"), not every `agent-browser`.

GOTCHA — the word "passthrough" is FULLY gone from this README. It appeared only once (the dead
  no-pi-ancestor pitfall). This README does not discuss meta-command passthrough at all (that is
  SKILL.md/configuration.md territory), so there is no legitimate "passthrough"/"pass straight through"
  to preserve here. Contrast: SKILL.md and configuration.md KEEP "pass straight through" for meta
  commands; this README does not need to.

GOTCHA — do NOT touch the "Teardown" bullet, the "Files" section, or the "Installation" section (both
  bash code fences). They are already accurate under the new model (LOGIC d). The scope is E1-E4, and
  E4 is "preserve verbatim".
```

### Integration Points

```yaml
NONE for this item beyond the skill file tree (one Markdown file edited in place).
  - No code, no config, no env vars are introduced by this item (it is documentation only).
  - The README CONSUMES (does not modify):
      * lib/pool.sh + bin/agent-browser-pool — the SHIPPED behavior it summarizes (P2.M1/P2.M2 done).
      * SKILL.md (P2.M4.T1.S1, COMPLETE) + references/configuration.md (P2.M4.T2.S1, parallel) — the
        docs its "Files" section points at.
      * PRD §1.3/§2.4/§2.17 — the contract it reflects.
  - Downstream consumers that build on this LATER (NOT here):
      * repo README.md (P2.M6.T1.S1) — will mirror the same command model at the repo level.
      * test/transparency.sh (P2.M5.T2.S1) — exercises the live agent-browser-pool commands.
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
F=.agents/skills/agent-browser-pool/README.md

# --- structure: section headers (all preserved) ---
for h in '# agent-browser-pool (Agent Skill)' '## What it covers' '## Files' '## Installation'; do
  grep -Fxq "$h" "$F" && echo "OK: header $h" || echo "FAIL: missing header $h"
done

# --- REMOVALS: each grep MUST find zero matches ---
for pat in 'transparent' 'AGENT_BROWSER_POOL_DISABLE' 'passthrough'; do
    if grep -nE "$pat" "$F"; then echo "FAIL: found removed pattern: $pat"; else echo "OK: absent: $pat"; fi
done
# the DEAD driving-command example: a backtick-quoted `agent-browser` immediately followed by "command"
grep -nE '`agent-browser` command' "$F" && echo "FAIL: found dead '\`agent-browser\` command' example" || echo "OK: absent: dead driving-command example"

# --- ADDITIONS: each grep MUST find a match ---
grep -Fq 'Chrome-profile pool' "$F" && echo "OK: new description phrase" || echo "FAIL: missing 'Chrome-profile pool'"
grep -Fq '`agent-browser-pool` command under `pi`' "$F" && echo "OK: corrected driving-command example" || echo "FAIL: driving-command example not corrected"
grep -Eq 'fail fast|fails fast' "$F" && echo "OK: fail-fast stated" || echo "FAIL: no fail-fast"
grep -Fq 'use `agent-browser`' "$F" && echo "OK: raw-access guidance" || echo "FAIL: no raw-access guidance"

# --- PRESERVED: the "Files" + "Installation" sections are byte-identical ---
grep -Fq '`SKILL.md` — procedural guide loaded by the agent.' "$F" && echo "OK: Files/SKILL.md preserved" || echo "FAIL: Files/SKILL.md changed"
grep -Fq '`references/configuration.md` — env-var table, command dispatch, lifecycle, troubleshooting' "$F" && echo "OK: Files/configuration.md preserved" || echo "FAIL: Files/configuration.md changed"
grep -Fq 'ln -s "$(pwd)/.agents/skills/agent-browser-pool" ~/.agents/skills/agent-browser-pool' "$F" && echo "OK: symlink fence preserved" || echo "FAIL: symlink fence changed"
grep -Fq 'pi --no-skills --skill .agents/skills/agent-browser-pool' "$F" && echo "OK: pi-load fence preserved" || echo "FAIL: pi-load fence changed"
# the "Teardown" bullet is preserved verbatim
grep -Fq '**Teardown:** `close` is disconnect-only' "$F" && echo "OK: Teardown bullet preserved" || echo "FAIL: Teardown bullet changed"

# --- shellcheck on both embedded bash code-fence snippets (unchanged install snippets; lint for rigor) ---
tmp=$(mktemp -d)
awk '/^```$/{n++; next} /^```bash$/{n++; next} n>0{print > tmp"/block"n".sh"}' "$F"
ok=1
for b in "$tmp"/block*.sh; do
  [ -s "$b" ] || continue
  if ! shellcheck -s bash "$b" >/dev/null 2>&1; then
    echo "shellcheck issues in $b:"; shellcheck -s bash "$b"; ok=0
  fi
done
[ "$ok" = 1 ] && echo "OK: shellcheck clean on both embedded snippets" || echo "FAIL: shellcheck issues (review above)"
rm -rf "$tmp"

# --- line count sanity (~35-45) ---
n=$(wc -l < "$F"); echo "lines: $n"
test "$n" -ge 35 -a "$n" -le 45 && echo "OK: line count in range" || echo "FAIL: line count out of range"
```

**Expected**: every assertion prints `OK:`; the 4 removed-pattern greps (`transparent`,
`AGENT_BROWSER_POOL_DISABLE`, `passthrough`, `` `agent-browser` command ``) find nothing; all addition
greps match; the Files + Installation sections + Teardown bullet are verbatim-preserved; shellcheck
clean on both bash snippets; line count ~40.

### Level 2: Component Validation — N/A

A Markdown README has no component runtime. Its "correctness" is its fidelity to the SHIPPED behavior
in `lib/pool.sh` + the shipped `SKILL.md`, enforced by the Level-1 grep assertions (each claim is pinned
to a function + line anchor / sibling-doc claim in §Documentation & References). Live exercise of
`agent-browser-pool open <url>` is P2.M5.T2.S1's job (isolated sandbox), not here.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# The behavior the README summarizes is SHIPPED (sanity greps — read-only, no execution):
grep -q 'AGENT_BROWSER_POOL_DISABLE' lib/pool.sh && echo "FAIL: lib still has DISABLE" || echo "OK: lib has no DISABLE (README is truthful)"
grep -q 'driving commands require a pi ancestor' lib/pool.sh && echo "OK: fail-fast shipped (README echoes it)" || echo "FAIL: fail-fast not shipped"

# Cross-doc consistency: the shipped SKILL.md is already in the new model (the README must agree):
grep -q 'AGENT_BROWSER_POOL_DISABLE\|transparent' .agents/skills/agent-browser-pool/SKILL.md && echo "FAIL: SKILL.md not in new model" || echo "OK: SKILL.md in new model (README agrees)"

# Scope: NO file OUTSIDE the skill directory was modified by this item.
# (README.md is this item's file; SKILL.md/configuration.md may also appear if the parallel siblings
#  ran in the same tree — those are not failures for THIS item's scope.)
git status --short
git status --short | grep -vE '^.{2} \.agents/skills/agent-browser-pool/' \
  && echo "FAIL: changes outside the skill dir" || echo "OK: all changes inside the skill dir"

# Confirm the SHIPPED code + siblings are untouched by this item:
for f in lib/pool.sh bin/agent-browser-pool install.sh README.md \
         .agents/skills/agent-browser-pool/SKILL.md \
         .agents/skills/agent-browser-pool/references/configuration.md; do
  # SKILL.md (COMPLETE) and configuration.md (parallel) are EXPECTED to possibly be touched by
  # siblings — not a failure for THIS item's scope. Skip them here.
  case "$f" in
    .agents/skills/agent-browser-pool/SKILL.md|.agents/skills/agent-browser-pool/references/configuration.md) continue;;
  esac
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done
test -f .agents/skills/agent-browser-pool/README.md && echo "OK: README.md present" || echo "FAIL: README.md missing"

# Do NOT run: test/*.sh, install.sh, or any agent-browser / Chrome command (AGENTS.md §1).
```

### Level 4: Creative & Domain-Specific Validation — N/A

A documentation edit has no domain runtime. The README's accuracy is fully pinned by Level 1-3 checks +
the verbatim artifact + the behavior contracts in §Documentation & References.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: every assertion prints `OK:`; no removed pattern present; all additions present.
- [ ] `shellcheck` clean on both embedded bash code-fence snippets.
- [ ] All 4 section headers present; line count ~35-45.
- [ ] Scope check: all changes inside `.agents/skills/agent-browser-pool/`; no change to `lib/pool.sh`,
      `bin/*`, `install.sh`, repo `README.md`, `test/*`.

### Feature Validation

- [ ] Opening paragraph: `agent-browser-pool` is a "Chrome-profile pool" (no "transparent … wrapper").
- [ ] "Acquire + connect" bullet: "first driving **`agent-browser-pool`** command under `pi`".
- [ ] "Pitfalls" bullet: driving commands **fail fast** without a `pi` ancestor; raw-access guidance present.
- [ ] Zero references to `transparent` / `AGENT_BROWSER_POOL_DISABLE` / `passthrough` / `` `agent-browser` command ``.
- [ ] "Teardown" bullet + "Files" section + "Installation" section preserved verbatim.

### Code Quality / Scope Validation

- [ ] **Only** `.agents/skills/agent-browser-pool/README.md` is modified by this item.
- [ ] `lib/pool.sh`, `bin/*`, `install.sh`, `SKILL.md`, `references/configuration.md`, repo `README.md`,
      `test/*` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no test suite) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] README.md IS the documentation artifact (the skill's discovery blurb). No separate doc
      file is written by this item.
- [ ] Cross-doc consistency: README.md agrees with the shipped SKILL.md (and parallel configuration.md)
      on no-DISABLE, fail-fast, and `agent-browser-pool` as the command.

---

## Anti-Patterns to Avoid

- ❌ Don't keep "transparent Chrome-profile wrapper" — the pool is an EXPLICIT tool now; call it a
      "Chrome-profile pool". (E1 / LOGIC a.)
- ❌ Don't keep the `agent-browser` driving-command example — it must be `agent-browser-pool`. (E2 / LOGIC b.)
      NOTE: a bare `agent-browser` in the raw-access parenthetical IS correct (names the real binary).
- ❌ Don't keep "passthrough (no `pi` ancestor ...)" or `AGENT_BROWSER_POOL_DISABLE` in the Pitfalls
      bullet — no-pi-ancestor FAILS FAST now, and DISABLE no longer exists. (E3 / LOGIC c.)
- ❌ Don't restructure or expand the README — it's a ~40-line blurb, not a second SKILL.md. Do NOT pull in
      the connection rules, meta/driving command list, env table, dispatch table, or troubleshooting matrix.
- ❌ Don't touch the "Teardown" bullet, "Files" section, or "Installation" section (both bash fences) —
      they are already accurate (E4 / LOGIC d).
- ❌ Don't edit `lib/pool.sh`, `bin/*`, `install.sh`, `SKILL.md`, `references/configuration.md`, repo
      `README.md`, or `test/*` — each is owned by a sibling/done/later item.
- ❌ Don't run `test/*.sh`, `install.sh`, or any `agent-browser`/Chrome command during this item —
      AGENTS.md §1 (sandbox-hang prevention). All validation is static (Level 1).

---

## Confidence Score

**9/10** — one-pass success likelihood. The item is a single-file targeted edit of a 39-line Markdown
README, and the PRP supplies the **exact final file verbatim** (the artifact is the spec), so there is
no ambiguity about what to write; a precise edit map (E1-E4) explains each change against shipped
behavior for implementers who prefer surgical edits over a full overwrite. Every behavioral claim is
pinned to a VERIFIED SHIPPED anchor: `grep -c AGENT_BROWSER_POOL_DISABLE lib/pool.sh` → 0; the exact
fail-fast guidance string at `lib/pool.sh:3645-3646`; the sibling SKILL.md already shipped clean (0
DISABLE/transparent, fail-fast described, `agent-browser-pool` throughout). The subtlest nuance — that
a bare `agent-browser` in the raw-access parenthetical is CORRECT while the `` `agent-browser` command ``
driving example is the DEAD thing to remove — is called out explicitly and enforced by a targeted
Level-1 grep (so an over-eager "remove all agent-browser mentions" pass won't break the raw-access
guidance). Validation is entirely static (grep + shellcheck + structure + scope) and cannot wedge the
sandbox (AGENTS.md §1). Not 10/10 only because the cross-doc consistency with the parallel
configuration.md (P2.M4.T2.S1) depends on both items landing their respective artifacts; this PRP
guarantees THIS file's side of the contract, and SKILL.md is already shipped on the same side.
