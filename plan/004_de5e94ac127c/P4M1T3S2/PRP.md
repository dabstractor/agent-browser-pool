# PRP — P4.M1.T3.S2: configuration.md caller subsection + SKILL.md orchestrator note

## Goal

**Feature Goal**: Document caller-scoped lanes (orchestrator mode) in the skill's deep
reference and agent contract, matching the semantics implemented by P4.M1.T3.S1
(owner = the invoking process's `$PPID`; TEST MODE hook outranks caller mode; dead or
reparented parent → `pool_die` with the exact message from that subtask).

**Deliverable**:
1. New `### Caller-scoped lanes (orchestrator mode)` subsection in
   `.agents/skills/agent-browser-pool/references/configuration.md`, placed inside the
   `## Environment variables` section immediately after the test-only-hooks blockquote
   (which ends at line ~46), plus two small touch-ups in that file: dispatch step 2
   (line ~56) and the acquire keying paragraph (line ~99).
2. New `### Orchestrator mode` sub-block in
   `.agents/skills/agent-browser-pool/SKILL.md` inserted after the Connection rules
   block (ends L53) and before `### Which commands trigger a lane` (L55), plus an
   extension of the §5 Reference pointer paragraph (L152–156, ends the file).

**Success Definition**: Both files updated in the established style (imperative second
person, backticked vars/commands, `→` arrows, no PRD `§` citations in skill docs).
The parallel-scrapers example prose is self-contained — P4.M3.T1.S1 (README) reuses it
verbatim. Chrome-free: no live runs needed; this subtask IS the Mode A documentation
for R3.

## Why

PRD §2.12 mode 1 (`ABPOOL_OWNER=caller`) is implemented in code (P4.M1.T3.S1) and its
env-table rows already exist (P4.M1.T2.S2, at `configuration.md:29`), which
cross-reference a "Caller-scoped lanes" subsection that does **not exist yet** — this
subtask creates it. The pool verbs vs. dispatch step-2 text and the acquire keying
paragraph still say "recognized-harness PID" unconditionally and must gain the
caller-mode branch. SKILL.md teaches the agent contract; an orchestrator subprocess
reading it must learn to set `ABPOOL_OWNER=caller` per subprocess (mirrors the PRD
§2.16 checklist line).

## What

### Success Criteria

- [ ] configuration.md has `### Caller-scoped lanes (orchestrator mode)` between the
      test-hooks blockquote (~L46) and `## Command dispatch` (~L47–48), documenting:
      what caller mode is (one lane per orchestrator subprocess, keyed on the caller,
      not the harness ancestor); parent-pid semantics (owner = the process that
      invoked the pool command); auto-reap when the subprocess exits; the
      parallel-scrapers usage example from PRD §2.12; harness fail-fast NOT applicable
      in caller mode; default path unchanged.
- [ ] configuration.md dispatch step 2 (ordered list, ~L56) and keying paragraph
      (~L98–99, "keyed on the owning harness **PID + starttime**") each mention the
      caller-mode branch.
- [ ] SKILL.md has `### Orchestrator mode` between L53 and L55: concise — when to set
      `ABPOOL_OWNER=caller` per subprocess, lane reaped on exit — plus the §5 pointer
      paragraph extended to mention orchestrator mode + configuration.md.
- [ ] No PRD `§` citations added anywhere in skill docs (existing `PRD §2.7` cites at
      configuration.md:20/35 are outside scope — leave them).
- [ ] No code files touched; no other doc surfaces (README, skill README, pitfalls
      bullet) touched — those belong to P4.M1.T4.S3 / P4.M3.T1.S1.
- [ ] Markdown renders sanely (table shapes preserved; no broken fences).

## All Needed Context

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/architecture/docs_map.md
  why: line-pinned survey of both files + style conventions (§2, §3, §7).
  critical: column header in configuration.md env table is `Variable`; troubleshooting
       is a 3-col matrix but we add NO row here (pin rows are P4.M1.T4.S3); voice is
       imperative second person, bold lead-ins, backticks everywhere, → arrows.

- file: plan/004_de5e94ac127c/architecture/synthesis.md §4
  why: Mode A documentation plan this subtask executes (caller subsection + SKILL
       orchestrator sub-block + §5 pointer; pitfalls bullet/README deferred).

- file: plan/004_de5e94ac127c/P4M1T3S1/PRP.md
  why: the CONTRACT for implemented semantics this PRP documents. Assume it lands
       exactly as specified.
  critical: owner = `$PPID` of the pool process (production: the orchestrator
       subprocess that invoked bin/agent-browser-pool); precedence TEST MODE hook >
       caller mode > ancestor walk; dead/reparented parent ($PPID==1 or no /proc/$PPID)
       → pool_die "agent-browser-pool: ABPOOL_OWNER=caller requires a live parent
       process (got ppid $PPID); invoke agent-browser-pool as a child of the
       long-lived orchestrator process". Downstream (find-mine, liveness, reaper,
       teardown-on-owner-exit) all work unchanged.

- file: .agents/skills/agent-browser-pool/references/configuration.md (147+2 lines)
  why: primary edit target.
  pattern: env table L16–L30 (ABPOOL_OWNER row at :29 already links "See the
       'Caller-scoped lanes' subsection" — match that anchor name in your heading);
       bullets "three that most affect behavior" L32–40 style; test-hooks blockquote
       L43–46; dispatch ordered list L51–58 (step 2 = **Everything else → DRIVING**);
       keying ¶ L98–99 under `## How acquire works`.
  gotcha: do NOT add a troubleshooting matrix row in this subtask (pin conflicts are
       T4.S3). Do NOT cite PRD § numbers in new prose.

- file: .agents/skills/agent-browser-pool/SKILL.md (156 lines)
  why: second edit target.
  pattern: `### Connection rules (don't fight the pool)` L44–53 — bullet style with
       bold lead-ins ("Do not pass…") to mimic loosely; `### Which commands trigger
       a lane` at L55 — insert before it, after the blank line following L53; §5
       Reference pointer ¶ L152–156 is one sentence paragraph — extend, don't
       restructure.
  gotcha: §5 has NO env table — pointer paragraph only. Keep the identity invariants
       at L18–21 true ("never by an argument" still holds; the env var is set by the
       orchestrator, not an agent CLI arg).

- url: PRD §2.12 / §2.16 (selected_prd_content above, in-repo PRD.md)
  why: source for the parallel-scrapers example and the checklist line.
  critical: reuse the example shape — two backgrounded `ABPOOL_OWNER=caller` workers
       from one session → distinct lanes, each torn down when its worker exits.
```

### Current anchors (verified against working tree)

- `configuration.md`: `## Environment variables` L11; ABPOOL_OWNER row L29; ABPOOL_LANE
  row L30; test-hooks blockquote L43–46; `## Command dispatch` L47; step 2 of the
  ordered list L56; `### Driving commands` L63; `## How acquire works` L82; keying ¶
  L98–99; `## Release lifecycle` L103.
- `SKILL.md`: Connection rules L44–53; `### Which commands trigger a lane` L55; §4
  Common pitfalls L133; §5 Reference L152–156 (file end).
- Line numbers may drift ±few from the concurrently-landing P4.M1.T3.S1 (lib-only) —
  it does not touch these files; re-verify anchors with `grep -n` before editing.

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: MODIFY .agents/skills/agent-browser-pool/references/configuration.md
  — add caller subsection
  - LOCATE: the blank line after the test-only-hooks blockquote (~L46), before
    `## Command dispatch` (~L47).
  - INSERT a `### Caller-scoped lanes (orchestrator mode)` subsection covering:
    1. What it is: with `ABPOOL_OWNER` set to any non-empty value (recommended
       `caller`), lane ownership keys on the **calling process** — the subprocess that
       invoked `agent-browser-pool` — instead of the recognized-harness ancestor. One
       orchestrator session can run many parallel browser-driving subprocesses, each
       with its own lane.
    2. Parent-pid semantics: the owner is the process that invoked the pool command;
       the pool records its pid + starttime. If that parent is already dead or
       reparented, the command fails fast (quote the pool_die message from
       P4.M1.T3.S1 verbatim — see Context above) — an owner that died on arrival
       would claim an instantly-stale lane.
    3. Auto-reap: when the subprocess exits, its lane is reaped by the existing lazy
       reaper (next acquire or `reap`) — no manual cleanup.
    4. Fail-fast exemption: the recognized-harness fail-fast does NOT apply in caller
       mode; caller mode with no harness ancestor is fine.
    5. Usage example (self-contained, prose + bash fence, adapted from PRD §2.12):
       ```bash
       ABPOOL_OWNER=caller .venv/bin/python scrapers/linkedin_discover.py --no-ping &
       ABPOOL_OWNER=caller .venv/bin/python scrapers/indeed_discover.py --no-ping &
       wait
       ```
       Each subprocess resolves to its own lane; each lane is reaped when its
       subprocess exits. (Keep this wording — README reuses it verbatim in
       P4.M3.T1.S1.)
    6. Default path unchanged: with `ABPOOL_OWNER` unset, ownership keys on the
       harness ancestor exactly as before.
  - STYLE: `###` heading (nested under `## Environment variables`); backticked
    `ABPOOL_OWNER`, `agent-browser-pool`; `→` arrows; bold sparingly; NO PRD § cites.

Task 2: MODIFY configuration.md — dispatch step 2 (~L56) + keying ¶ (~L98–99)
  - Step 2 currently reads "resolve the owning recognized-harness PID; if there is no
    recognized-harness ancestor, fail-fast…". Append a caller-mode clause, e.g.:
    "With `ABPOOL_OWNER` set (caller mode), ownership keys on the calling process —
    no harness ancestor is required (see *Caller-scoped lanes* below)." Adjust
    reference direction if the subsection sits after dispatch (it sits above — use
    "above" or the heading name; pick whichever reads naturally).
  - Keying ¶ (~L98–99) currently: "Lane identity is keyed on the owning harness
    **PID + starttime**…". Add one sentence: in caller mode the same
    **PID + starttime** triple keys on the invoking subprocess instead of the
    harness ancestor — same staleness/reuse guarantees.

Task 3: MODIFY .agents/skills/agent-browser-pool/SKILL.md — orchestrator sub-block
  - INSERT after the blank line ending Connection rules (L53) and before
    `### Which commands trigger a lane` (L55):
    `### Orchestrator mode (parallel workers from one session)`
    Content (concise, imperative, bullet style matching Connection rules):
    - If you are one of several browser-driving subprocesses spawned by one
      orchestrator session, have the orchestrator set `ABPOOL_OWNER=caller` **per
      subprocess** → each worker gets its own lane automatically.
    - Your lane is reaped when your subprocess exits — end normally, no manual
      cleanup (mirrors the PRD §2.16 checklist line, but written §-free).
    - One short inline example (single backgrounded worker) or pointer to the
      full example in `references/configuration.md`.
  - KEEP the L18–21 identity invariants accurate (the command still never names a
    lane; the env var is orchestrator-set, not an agent argument).

Task 4: MODIFY SKILL.md §5 Reference pointer (L152–156)
  - EXTEND the existing sentence to mention orchestrator mode, e.g. append:
    "…including the **caller-scoped lanes (orchestrator mode)** subsection for
    parallel-worker usage." Keep it one pointer paragraph — NO env table here.

Task 5: VERIFY (static only — no live runs)
  - grep both files for new stray `§` citations (only pre-existing PRD §2.7 cites
    remain); confirm markdownlint-ish sanity (blank lines around headings/fences);
    confirm no other files changed (`git status` / `git diff --stat`).
```

### Known Gotchas of our codebase & Library Quirks

```markdown
# CRITICAL: skill docs convention is NO PRD § citations — the existing `PRD §2.7`
#   cites at configuration.md:20/:35 are pre-existing; add none.
# CRITICAL: the env-table row at configuration.md:29 says "See the 'Caller-scoped
#   lanes' subsection" — the new heading must start with "Caller-scoped lanes".
# The subsection lives INSIDE `## Environment variables` (a `###`), per the contract
#   definition — not a new `##` section.
# Do not add: troubleshooting matrix rows (T4.S3), ABPOOL_LANE docs (T4.S3), README
#   changes (P4.M3.T1.S1), skill README bullet (T4.S3 owns it — verify against its
#   PRP when it lands; this PRP does not touch it), pitfalls bullet (deferred).
# Do not document `$$` mechanics from the PRD verbatim — the implemented semantics
#   (P4.M1.T3.S1) resolve owner = invoking process's parent ($PPID); user-facing
#   wording is simply "the calling process / the subprocess that invoked the pool".
# Markdown tables: never let a `|` inside new prose break the existing table — new
#   prose goes OUTSIDE the table (bullets/subsection), not new rows.
```

## Validation Loop

### Level 1: Static checks (docs-only subtask — this is all that applies)

```bash
bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh   # confirm untouched by diff
git diff --stat    # expect exactly the two .md files under .agents/skills/
grep -n '§' .agents/skills/agent-browser-pool/SKILL.md \
        .agents/skills/agent-browser-pool/references/configuration.md
# Expected: only the pre-existing `PRD §2.7` cites (config :20/:35) and SKILL.md's
# internal self-reference at :68 — zero NEW § citations.
grep -n "Caller-scoped lanes" .agents/skills/agent-browser-pool/references/configuration.md
# Expected: the env-table row (:29) AND the new `###` heading both present.
# Optional: render sanity via any local markdown viewer/lint; at minimum eyeball the
# diff for balanced fences and heading hierarchy (### nested under ##).
```

### Level 2: Cross-doc consistency spot-check

```bash
# The pool_die message quoted in the subsection must match P4.M1.T3.S1's exact string:
grep -n "requires a live parent process" lib/pool.sh
# Compare word-for-word with the quoted message in configuration.md.
```

## Final Validation Checklist

- [ ] `### Caller-scoped lanes (orchestrator mode)` present in configuration.md env-vars
      section (after test-hooks blockquote), covering: definition, parent-pid
      semantics, dead-parent fail-fast (exact message), auto-reap, fail-fast
      exemption, parallel-scrapers example, default-path unchanged
- [ ] Dispatch step 2 and acquire keying ¶ both mention the caller-mode branch
- [ ] SKILL.md `### Orchestrator mode` between L53 and L55; §5 pointer extended; no
      env table added to §5
- [ ] Zero new § citations; backticked vars; → arrows; imperative voice throughout
- [ ] Parallel-scrapers example wording self-contained (README will reuse verbatim)
- [ ] `git diff --stat` shows ONLY the two skill doc files; no code, no README,
      no skill README, no tests
- [ ] No live runs performed; no processes/temp dirs left behind

## Anti-Patterns to Avoid

- ❌ Don't document `ABPOOL_LANE` here — that's P4.M1.T4.S3 (subsection + rows)
- ❌ Don't add README.md content — Mode B (P4.M3.T1.S1)
- ❌ Don't cite PRD section numbers inside skill docs
- ❌ Don't restructure §5 or add env tables to SKILL.md
- ❌ Don't paraphrase the pool_die message — quote it exactly as implemented
- ❌ Don't describe internals as `$$`/`$PPID` mechanics in user-facing prose — say
     "the calling process / the subprocess that invoked the pool"

**Confidence Score: 9/10** — all insertion anchors re-verified against the current
working tree; the only risk is minor line drift from the parallel lib-only S1 change
(re-grep anchors before editing).