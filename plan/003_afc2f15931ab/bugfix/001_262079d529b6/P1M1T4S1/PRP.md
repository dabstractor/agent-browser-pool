# PRP — P1.M1.T4.S1: Sweep README.md and skill docs for accuracy post-fix

> **Bugfix context**: This is the **[Mode B] changeset-level documentation** subtask for the
> 3-issue bug-fix suite (`plan/003_afc2f15931ab/bugfix/001_262079d529b6/`). The three code
> fixes (Issue 1 reaper anchor, Issue 2 doctor `ss`-optional, Issue 3 ensure_connected
> identity) were implemented with **inline [Mode A] doc** (code comments + docstrings updated
> *by their own implementing subtasks* T1.S1/T2.S1/T3.S1/T3.S2). This subtask (T4.S1) owns
> ONLY the **changeset-level overview docs**: `README.md` and the skill docs under
> `.agents/skills/agent-browser-pool/`. Per the item contract (point 3): **"If a doc file is
> ALREADY accurate, do NOT change it. This is a verification + targeted update, not a rewrite."**
>
> **SCOPE BOUNDARY (CRITICAL):** This subtask edits ONLY `README.md` (two small prose regions,
> both about `ss` now being optional — driven by Issue 2). All other checked docs
> (`SKILL.md`, `references/configuration.md`, skill `README.md`, and the README §reap /
> §internals / §doctor-exit-code sections) are **verified ACCURATE and unchanged**. This
> subtask does NOT touch any code (`lib/pool.sh`, `bin/*`, `install.sh`, `test/*`), `PRD.md`,
> `AGENTS.md`, `tasks.json`, `prd_snapshot.md`, or `.gitignore`. It is the final documentation
> task (item contract point 5: "This IS the documentation task. No further doc subtask needed.").
>
> **PRECONDITIONS (verified in `research/notes.md` §0): all 3 fixes are ALREADY applied** to
> the working tree (`lib/pool.sh` is **4611 LOC**). Re-confirm with the Task-0 greps before
> editing. Research/analysis verdict table is in `research/notes.md` §1.

---

## Goal

**Feature Goal**: Reconcile the changeset-level user/operator docs (`README.md` + the agent
skill docs) against the FINAL, fixed state of `lib/pool.sh`, so that no shipped doc makes a
claim contradicted by (or now-incomplete relative to) the three fixes. Concretely: (1) verify
every doc surface named in the item contract, (2) make the **two** targeted updates where a
doc is now inaccurate (both are the `ss`-is-optional change from Issue 2), and (3) record the
per-file check+verdict so the audit is traceable.

**Deliverable**:
1. **`README.md` — Prerequisites §Dependencies** (`:47-48`): add `ss` to the optional note so
   the prose matches Issue 2's behavior (`ss` is optional; `pool_find_free_port` degrades to a
   curl-only probe when absent). Also add `findmnt` to the required list (adjacent accuracy fix
   — the code requires+prints it). See Task 1 for the exact old→new text.
2. **`README.md` — Admin/`doctor` `[dependencies]` example block** (`:230-231`): add the `ss`
   optional line (and `findmnt` to the required list) so the rendered example matches the
   actual `doctor` output. See Task 2 for the exact old→new text.
3. **`research/notes.md` §1 verdict table**: re-confirmed against the live tree by the
   implementer (the "what was checked + verdict" log the item contract requires — point 3).
4. **No other files changed.** Verified-accurate files (`SKILL.md`, `references/configuration.md`,
   skill `README.md`, README §reap / §internals / §doctor-exit-code) stay byte-unchanged; their
   verdicts are recorded in `research/notes.md`.

**Success Definition**:
- `grep -nE 'ss' README.md` shows `ss` in BOTH the Prerequisites §Dependencies note AND the
  `doctor` `[dependencies]` example block (as optional).
- `git diff --stat -- lib/pool.sh bin/ install.sh test/ PRD.md AGENTS.md` is **EMPTY** (no code
  or owned file touched).
- `git diff -- README.md` is SMALL (only the two named regions) and introduces no broken
  markdown (code fences balanced; the doctor example block still renders).
- Every doc surface in `research/notes.md` §1 has an explicit ACCURATE/UPDATED verdict the
  implementer re-confirmed against the live tree.
- Optional: `npx markdownlint-cli2 README.md .agents/skills/agent-browser-pool/*.md
  .agents/skills/agent-browser-pool/references/*.md` (if available) reports no NEW issues
  introduced by this subtask.

## User Persona

**Target User**: (1) An operator reading `README.md` to install/verify the pool — the
Prerequisites §Dependencies and `doctor` example block are the canonical "what tools do I need"
reference; an operator on an `ss`-less minimal host must see `ss` is optional (Issue 2 made
this true, so the doc must now say so). (2) A maintainer/auditor confirming the docs match the
hardened isolation behavior (Issue 1/3) — the high-level summaries must not over-promise or
mislead.

**Use Case**: Operator runs `agent-browser-pool doctor` on a stripped container lacking
`iproute2`/`ss`; expects it to pass (Issue 2). The README must not list `ss` as required (it
currently omits it from the optional set, leaving the prereq prose incomplete).

**Pain Points Addressed**: A doc that omits a now-optional dependency (or that left a
doctor-output example stale) is a real correctness gap for an operator doing a greenfield
install/audit. Closing it makes the README's "verify the whole stack" promise honest.

## Why

- **Issue 2 (Minor)** has a genuine changeset-level doc surface: `ss` moved from "required
  (FAIL on missing)" to "optional (degrades to curl-only port probe)". The README names the
  optional tools but does NOT name `ss`, so the prose + the rendered `[dependencies]` example
  block are now **incomplete** relative to shipped behavior. This is the one accuracy gap the
  3-fix suite introduced at the overview-doc layer.
- **Issues 1 & 3 are internal hardening with no user-visible behavior change.** Issue 1 changes
  HOW the orphan kill is *scoped* (anchored pattern), not WHAT it does ("kill the orphan's own
  Chrome") — the §reap description stays accurate. Issue 3 adds defense-in-depth identity
  verification on a path that still "reconnects if the daemon died" — the §internals summary
  stays accurate. Hence no prose change for them; just a verified-accurate verdict.
- **Traceability**: the item contract requires documenting "each file checked + verdict" so the
  audit is reviewable. That verdict log lives in `research/notes.md` §1 (re-confirmed live).
- **Scope discipline**: this subtask must NOT rewrite docs that are already correct, must NOT
  add Issue-1/Issue-3 narrative, and must NOT touch code. It is a precision surgical update.

## What

User-visible behavior: the README's "what tools are required/optional" statements become
accurate w.r.t. Issue 2. No behavior, no API, no config change.

### Doc-sweep verdict (authoritative — re-confirm live in Task 0; full table in `research/notes.md` §1)

| Doc surface | Verdict | Action |
|-------------|---------|--------|
| `README.md` Prerequisites §Dependencies (`:47-48`) | **NOW INACCURATE** (omits optional `ss`; pre-existing: omits required `findmnt`) | **UPDATE** (Task 1) |
| `README.md` Admin/`doctor` `[dependencies]` example block (`:230-231`) | **NOW INACCURATE** (example omits the `ss` optional line the code emits; pre-existing: omits `findmnt`) | **UPDATE** (Task 2) |
| `README.md` `doctor` "Exits `0`/`1` only if a blocking … check fails" (`:224`) | **ACCURATE (more so than before)** — Issue 2 made a previously-slightly-wrong claim finally true | verify, NO CHANGE |
| `README.md` §reap "killing any orphaned Chrome still pointed at them" (`:193`) | **ACCURATE** — Issue 1 changed kill *scoping*, not the described behavior; the anchored fix makes it *more* literally true | verify, NO CHANGE |
| `README.md` §internals lifecycle item 6 "pool_ensure_connected (reconnect if the daemon died)" (`:320`) | **ACCURATE** — high-level summary; Issue 3 hardening is not user-visible and not misleading | verify, NO CHANGE |
| `README.md` §troubleshooting/Leaks `reap` + `doctor` exit-code (`:381`,`:383`) | **ACCURATE** | verify, NO CHANGE |
| `.agents/skills/agent-browser-pool/SKILL.md` §2 teardown (`:87-88`) | **ACCURATE** — describes lease-driven release teardown (Issue 1 was the orphan-dir sweep, a different path); no deps/identity claim | NO CHANGE |
| `.agents/skills/agent-browser-pool/references/configuration.md` troubleshooting (`:129`) + admin CLI `doctor` (`:144`) | **ACCURATE** — Issue 2 makes the `doctor` exit-code claim finally true; no deps list; no identity claim | NO CHANGE |
| `.agents/skills/agent-browser-pool/README.md` | **ACCURATE** — high-level overview; no deps/identity/orphan-matching detail | NO CHANGE |

### The two precise edits

**Task 1 — `README.md:47-48` (Prerequisites §Dependencies)**

FIND (exact current text):
````
A handful of coreutils/util-linux/procps tools are also required (`flock`, `setsid`, `pgrep`,
`pkill`, `cp`, `curl`, `jq`; `notify-send` is optional). Run `agent-browser-pool doctor` to
verify the whole stack — see [Admin commands](#admin-commands).
````
REPLACE WITH (RECOMMENDED — accurate: `ss` in-scope + `findmnt` adjacent):
````
A handful of coreutils/util-linux/procps tools are also required (`flock`, `setsid`, `pgrep`,
`pkill`, `cp`, `curl`, `jq`, `findmnt`; `notify-send` and `ss` are optional). Run
`agent-browser-pool doctor` to verify the whole stack — see [Admin commands](#admin-commands).
````
> **MINIMAL variant** (if you must keep scope to the 3-fix changeset only, drop `findmnt`):
> `... \`cp\`, \`curl\`, \`jq\`; \`notify-send\` and \`ss\` are optional). ...` — i.e. only add
> `and \`ss\`` to the optional clause. `findmnt` is a recommended adjacent accuracy fix, not a
> changeset from the 3 fixes; see "Known Gotchas".

**Task 2 — `README.md:230-231` (Admin/`doctor` `[dependencies]` example block)**

FIND (exact current text — it is a fenced ``` block):
````
[dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, chrome → OK / MISSING;
                 notify-send → OK / MISSING (optional)
````
REPLACE WITH (RECOMMENDED — matches actual `doctor` output: required loop is
`flock setsid pgrep pkill cp curl jq findmnt`, then `chrome`, then optional `notify-send` + `ss`):
````
[dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, findmnt, chrome → OK / MISSING;
                 notify-send → OK / MISSING (optional);  ss → OK / MISSING (optional; port-probe degrades to curl-only)
````
> **MINIMAL variant** (changeset-only): keep the required list as-is and just add an `ss` line:
> append a 3rd line `                 ss → OK / MISSING (optional; port-probe degrades to curl-only)`
> after the `notify-send` line. (Adding `findmnt` to the required list is the recommended
> adjacent accuracy fix; the code genuinely requires+prints it at `lib/pool.sh:4290`.)

### Success Criteria

- [ ] The 3 code fixes are confirmed present in `lib/pool.sh` (Task 0 greps).
- [ ] `README.md:47-48` lists `ss` as optional (and, recommended, `findmnt` as required).
- [ ] `README.md:230-231` `doctor` `[dependencies]` example shows the `ss` optional line (and,
      recommended, `findmnt` in the required list).
- [ ] All other checked doc surfaces carry an explicit ACCURATE/UPDATED verdict in
      `research/notes.md` §1, re-confirmed against the live tree (no edits to those files).
- [ ] `git diff --stat` confirms ONLY `README.md` (and `research/notes.md`) changed; NO code /
      `PRD.md` / `AGENTS.md` / `tasks.json` / `prd_snapshot.md` / `.gitignore` changes.
- [ ] README.md code fences remain balanced (the doctor example block still renders).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. The PRP pins every edit site by exact current text + line number,
gives the exact old→new replacement (with a RECOMMENDED accurate variant and a MINIMAL
changeset-only variant for each), explains WHY each location is accurate/inaccurate relative to
the confirmed final code state, provides the full per-file verdict table, and specifies the
non-obvious adjacent gap (`findmnt`). The implementer needs no prior exposure beyond the quoted
snippets + the Task-0 verification greps.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: README.md
  why: 'THE file being edited (2 regions). Read §Prerequisites (lines ~40-50) and §Admin/doctor
        (lines ~220-245) to confirm the exact current text matches Task 1/Task 2 FIND blocks.'
  pattern: 'the doctor "[dependencies]" block (line 230-231) is a FENCED ``` block — preserve
            the fence + the leading 17-space indent alignment of continuation lines.'
  gotcha: 'the "→" arrows and exact spacing in the [dependencies] block are cosmetic but should
            match the style of the existing lines. Do not reflow the block.'

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: 'checked for accuracy (reaper behavior, doctor deps, ensure_connected identity). Verdict:
        ACCURATE, NO CHANGE. Read §2 teardown (line ~87-88) + §3 safety to confirm no claim is
        contradicted by the 3 fixes.'
  gotcha: 'do NOT add reaper/identity narrative — the skill is the procedural agent guide, not a
            changelog.'

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: 'checked for accuracy. Verdict: ACCURATE, NO CHANGE. Read troubleshooting matrix (line
        ~129) + admin CLI (line ~144) to confirm the "doctor exits 1 on a blocking FAIL only"
        claim (now MORE accurate post-Issue-2) and the reap description.'
  gotcha: 'no dependency list exists here (deps live in README §Prerequisites), so the ss-optional
            change has NO surface in this file. Confirm and leave it alone.'

- file: .agents/skills/agent-browser-pool/README.md
  why: 'checked for accuracy. Verdict: ACCURATE, NO CHANGE. High-level skill overview; no
        deps/identity/orphan-matching detail.'
  gotcha: 'do not edit — no claim is contradicted by the 3 fixes.'

- file: lib/pool.sh
  why: 'THE source of truth for what the docs must match. Read ONLY (do NOT edit this subtask):
        pool_reap_orphan_dirs (~2870-2930, the anchored pat at 2925 — Issue 1), pool_admin_doctor
        (deps loop at 4290 + optional-ss block at 4335-4341 + docstring at 4200 — Issue 2),
        pool_ensure_connected (reconnect gate at 2581 + relaunch 3-arg call at 2620 — Issue 3).'
  pattern: 'the doctor [dependencies] output order is: flock setsid pgrep pkill cp curl jq
            findmnt (required, FAIL on missing), then chrome, then notify-send (optional), then
            ss (optional). The README example block should reflect this.'
  gotcha: 'locate by CONTENT grep, not line number (line numbers drift). DO NOT EDIT lib/pool.sh
            — the code fixes are owned by T1.S1/T2.S1/T3.S1/T3.S2 and are already applied.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/system_context.md
  why: 'the "Documentation Surface" table maps each issue → its doc surface. Confirms Issue 1/3
        have NO README change (verify-only) and Issue 2 has the ss-optional README surface
        ("§doctor [dependencies] list at README.md:230 doesn''t mention ss — verify (may want to
        add)"). EXACTLY this PRP.'
  pattern: '"Documentation Surface" table + "Issue Independence".'
  gotcha: 'system_context line numbers predate the fixes; trust its SURFACE verdicts, re-confirm
            current lines via grep.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T4S1/research/notes.md
  why: 'THE per-location verdict table (§1) + code evidence (§0). Re-confirm each verdict live,
            perform the 2 updates, append any final "what changed" note.'
  gotcha: 'the verdicts were authored during research against the 4611-LOC tree; if the tree
            changed since, re-verify before editing.'

# External authoritative docs (minimal — this is a 2-region markdown prose edit)
- url: https://spec.commonmark.org/0.30/#fenced-code-blocks
  why: 'the doctor [dependencies] block is a fenced code block; the edit must keep the opening
        / closing ``` fence intact and preserve the internal alignment. No markdown subtlety
        beyond fence balance.'
  section: 'Fenced code blocks (info string + closing fence).'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── README.md                                       # 421 LOC — EDIT 2 regions (Prereq §Dependencies + doctor [dependencies] block)
├── PRD.md                                          # READ-ONLY (human-owned)
├── AGENTS.md                                       # READ-ONLY (operating rules)
├── install.sh                                      # DO NOT TOUCH
├── bin/agent-browser-pool                          # DO NOT TOUCH
├── lib/pool.sh                                     # 4611 LOC — READ ONLY (all 3 fixes applied: 2925, 2581, 2620, 4290, 4340)
├── .agents/skills/agent-browser-pool/
│   ├── SKILL.md                                    # 149 LOC — verify ACCURATE, NO CHANGE
│   ├── README.md                                   # skill overview — verify ACCURATE, NO CHANGE
│   └── references/configuration.md                 # verify ACCURATE, NO CHANGE (no deps list here)
└── test/                                           # DO NOT TOUCH
└── plan/003_afc2f15931ab/bugfix/001_262079d529b6/
    ├── architecture/system_context.md              # "Documentation Surface" table = this PRP's scope
    ├── P1M1T4S1/
    │   ├── PRP.md                                  # THIS FILE
    │   └── research/notes.md                       # verdict table + code evidence (EDIT: append final log)
    └── ... (T1.S1/T2.S1/T3.S1/T3.S2 PRPs — sibling code subtasks, done)
```

### Desired Codebase tree with files to be added

```bash
# NO new files. All edits are IN-PLACE in 1 existing file:
#   README.md        — 2 small prose regions (Task 1 + Task 2)
# Plus a verification-log append in:
#   plan/.../P1M1T4S1/research/notes.md — re-confirm verdicts + record "what changed" (Task 4)
```

### Known Gotchas of our codebase & Library Quirks

```markdown
<!-- CRITICAL (this is a VERIFICATION-first task): the item contract (point 3) says "If a doc
     file is ALREADY accurate, do NOT change it." 8 of the 9 checked surfaces are ACCURATE and
     must stay byte-unchanged — only the 2 ss-related README regions get edited. Resist the urge
     to "improve" accurate prose or to add Issue-1/Issue-3 narrative. -->

<!-- CRITICAL (locate edit sites by EXACT text, not line number): README is 421 lines and the
     two target regions have stable content. The Task 1/Task 2 FIND blocks are quoted verbatim;
     match them exactly. Line numbers (47-48, 230-231) are orientation only. -->

<!-- CRITICAL (the doctor [dependencies] block is a FENCED ``` block): preserve the opening and
     closing ``` fences and the 17-space indent of the continuation line(s). The "→ OK / MISSING"
     arrows are stylistic — match the existing lines' style. Do not reflow. -->

<!-- GOTCHA (ss is from iproute2, not coreutils/util-linux/procps): the Prerequisites sentence
     says "coreutils/util-linux/procps tools". ss (iproute2) + notify-send (libnotify) are the
     OPTIONAL exceptions. The recommended Task 1 edit lists "`notify-send` and `ss` are optional"
     which is accurate without needing to name iproute2/libnotify (the doctor output already
     explains the degradation). -->

<!-- GOTCHA (findmnt is the recommended adjacent fix, NOT a changeset from the 3 fixes): the code
     requires+prints findmnt (lib/pool.sh:4290 FAIL loop; pool_check_btrfs pool_die's without it),
     but the README Prerequisites + doctor example block have ALWAYS omitted it. Adding it is a
     genuine accuracy improvement discovered during the sweep. It is RECOMMENDED (RECOMMENDED
     variant) but optional — the MINIMAL variant adds ss only. Document the choice either way. -->

<!-- GOTCHA (do NOT add ss/findmnt to the skill docs): configuration.md + SKILL.md have NO
     dependency list (that lives in README §Prerequisites). So the ss-optional change has NO
     surface there. Confirm and leave them alone. -->

<!-- GOTCHA (Issue 1/3 have NO changeset-level doc change): Issue 1 (anchored reaper) changes HOW
     the orphan kill is scoped, not the described behavior — §reap "killing any orphaned Chrome
     still pointed at them" stays accurate (and is now MORE literally true). Issue 3 (identity
     hardening) is defense-in-depth on a path that still "reconnects if the daemon died" — the
     §internals summary stays accurate. Do NOT add changelog-style notes about these. -->

<!-- GOTCHA (scope: do NOT touch): lib/pool.sh, bin/*, install.sh, test/* (code is DONE and owned
     by the sibling subtasks), PRD.md + AGENTS.md (human/operator-owned), tasks.json +
     prd_snapshot.md (orchestrator-owned), .gitignore. This subtask edits README.md (2 regions)
     + research/notes.md (log) ONLY. -->
```

## Implementation Blueprint

### Data models and structure

Not applicable — no code, no data models. This is a markdown prose edit + a verification log.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY preconditions — all 3 code fixes are present + locate the 2 edit sites by CONTENT
  - RUN (static only — safe per AGENTS.md §1):
        # Issue 1 (reaper anchored):
        grep -n 'user-data-dir=\$dir( |\$)' lib/pool.sh     # → ~2925  (MUST match)
        # Issue 2 (doctor ss optional): ss NOT in FAIL loop, IS optional:
        grep -n 'for dep in flock setsid pgrep pkill cp curl jq findmnt; do' lib/pool.sh  # → ~4290 (MUST match, no ss)
        grep -n 'MISSING (optional; port-probe degrades to curl-only)' lib/pool.sh        # → ~4340 (MUST match)
        # Issue 3 reconnect (S1) + relaunch (S2):
        grep -n '! pool_cdp_is_ours "\$port" "\$ephemeral_dir" "\$chrome_pid"' lib/pool.sh # → ~2581 (MUST match)
        grep -n 'if ! pool_wait_cdp "\$port" "\$ephemeral_dir" "\${POOL_CHROME_PID:-}"; then' lib/pool.sh  # → ~2620 (MUST match)
        ! grep -n 'if ! pool_wait_cdp "\$port"; then' lib/pool.sh                          # → no match (good; S2 done)
  - RUN (locate the 2 README edit sites by exact text):
        grep -n 'A handful of coreutils/util-linux/procps tools' README.md                 # → ~47
        grep -n '\[dependencies\]   flock, setsid' README.md                               # → ~230
  - CONFIRM: all 5 code-fix greps match (the fixes are applied) + the 2 README regions exist
        with the exact text quoted in Task 1 / Task 2. If ANY code-fix grep does NOT match, STOP
        — the sibling code subtask is not applied yet; this doc task cannot complete accurately
        until it is. (Per the parallel-execution contract, T3.S2 is assumed applied; verify.)
  - READ README.md:40-50 and :220-245 to confirm the exact current text matches the FIND blocks.

Task 1: EDIT README.md — Prerequisites §Dependencies (add optional `ss` [+ required `findmnt`])
  - LOCATE the region starting "A handful of coreutils/util-linux/procps tools are also required"
    (README.md:~47-48).
  - FIND (exact):
        A handful of coreutils/util-linux/procps tools are also required (`flock`, `setsid`, `pgrep`,
        `pkill`, `cp`, `curl`, `jq`; `notify-send` is optional). Run `agent-browser-pool doctor` to
        verify the whole stack — see [Admin commands](#admin-commands).
  - REPLACE WITH (RECOMMENDED):
        A handful of coreutils/util-linux/procps tools are also required (`flock`, `setsid`, `pgrep`,
        `pkill`, `cp`, `curl`, `jq`, `findmnt`; `notify-send` and `ss` are optional). Run
        `agent-browser-pool doctor` to verify the whole stack — see [Admin commands](#admin-commands).
    (MINIMAL variant — add only `and \`ss\`` to the optional clause, leave `findmnt` out — if you
    choose to keep scope to the strict 3-fix changeset. Document which variant you applied.)
  - WHY: Issue 2 made `ss` optional (pool_find_free_port degrades to a curl-only probe when absent);
    the prose must name it. `findmnt` (util-linux) is genuinely required (pool_check_btrfs pool_die's
    without it) and the code's doctor loop prints it — naming it fixes a pre-existing gap.
  - GOTCHA: do NOT change the sentence's other wording, the link, or the surrounding list. Only the
    parenthetical required/optional clause changes.

Task 2: EDIT README.md — Admin/`doctor` `[dependencies]` example block (add `ss` line [+ `findmnt`])
  - LOCATE the fenced ``` block whose first line is "[dependencies]   flock, setsid, pgrep, pkill,
    cp, curl, jq, chrome → OK / MISSING;" (README.md:~230-231). It is INSIDE a ``` fence.
  - FIND (exact — the 2 lines inside the fence):
        [dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, chrome → OK / MISSING;
                         notify-send → OK / MISSING (optional)
  - REPLACE WITH (RECOMMENDED — matches actual doctor output order):
        [dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, findmnt, chrome → OK / MISSING;
                         notify-send → OK / MISSING (optional);  ss → OK / MISSING (optional; port-probe degrades to curl-only)
    (MINIMAL variant — leave the required list unchanged and append a 3rd line
     "                 ss → OK / MISSING (optional; port-probe degrades to curl-only)" — if you
     keep scope to the strict 3-fix changeset. Document which variant you applied.)
  - WHY: the code's doctor [dependencies] output now emits an `ss` optional line (lib/pool.sh:4340)
    and always emitted `findmnt` as required (lib/pool.sh:4290). The rendered README example must
    match so operators can predict the output.
  - GOTCHA: PRESERVE the ``` fences around the whole 8-section block (do not delete/duplicate them).
    PRESERVE the column alignment (the continuation line's leading spaces align under the deps list).
    The "→ OK / MISSING" + "(optional; port-probe degrades to curl-only)" wording mirrors the code's
    printf at lib/pool.sh:4340 exactly.
  - GOTCHA: this block is part of a LARGER fenced listing (it includes [binary], [filesystem],
    [master], [lanes], [dirs], [summary]). Edit ONLY the [dependencies] lines; leave the rest.

Task 3: VERIFY (no edits) the ACCURATE doc surfaces — record verdicts in research/notes.md §1
  - For EACH of these, READ the cited lines and CONFIRM the verdict is ACCURATE post-fix (do NOT
    edit — if one is NOT accurate, STOP and surface it; the PRP's premise is they are accurate):
      * README.md:224 — "Exits `0` if healthy, `1` only if a blocking infrastructure check fails"
        (now MORE accurate post-Issue-2; was slightly wrong before).
      * README.md:193 — §reap "killing any orphaned Chrome still pointed at them" (Issue 1: kill
        scoping changed, not behavior; the description is now MORE literally true).
      * README.md:320 — §internals item 6 "pool_ensure_connected (reconnect if the daemon died)"
        (Issue 3: defense-in-depth; summary not misleading).
      * README.md:381,:383 — §troubleshooting reap + doctor exit-code.
      * .agents/skills/agent-browser-pool/SKILL.md:87-88 (§2 teardown) — no deps/identity claim.
      * .agents/skills/agent-browser-pool/references/configuration.md:129 (troubleshooting),
        :144 (admin CLI doctor) — no deps list; doctor exit-code claim now accurate.
      * .agents/skills/agent-browser-pool/README.md — high-level overview; no relevant detail.
  - WHY: the item contract requires "each file checked + verdict." This is the audit trail. If you
    find an ACCURATE surface that you are tempted to "improve," DON'T — point 3 says leave accurate
    docs alone.

Task 4: RECORD the audit — append a "Final sweep result" section to research/notes.md
  - APPEND to plan/.../P1M1T4S1/research/notes.md a short section:
        ## 5. Final sweep result (implemented <date>)
        - README.md §Dependencies (Task 1): variant applied = {RECOMMENDED ss+findmnt | MINIMAL ss-only}
        - README.md §doctor [dependencies] (Task 2): variant applied = {RECOMMENDED ss+findmnt | MINIMAL ss-only}
        - All other 7 surfaces: ACCURATE, unchanged (verdicts re-confirmed live in §1).
        - Code untouched: `git diff --stat -- lib/pool.sh bin/ install.sh test/` empty.
  - WHY: closes the item contract's "brief note in the PRP/research of what was checked and what
    (if anything) changed" (point 3/4).

Task 5: VERIFY (the Validation Loop below) — run BEFORE claiming done.
```

### Implementation Patterns & Key Details

```markdown
<!-- Pattern A — surgical single-clause edit (Task 1): change ONLY the parenthetical required/optional
     clause. The link, the surrounding sentence, and the rest of §Prerequisites are untouched. -->

<!-- Pattern B — fenced-block line edit (Task 2): edit lines INSIDE an existing ``` fence without
     touching the fence lines themselves. Preserve column alignment of continuation lines (the
     "notify-send →" / "ss →" lines are indented to align under the first dep after the label). -->

<!-- Pattern C — verdict log: a table or bullet list of (file:line, claim, verdict, action). The
     authoritative table is already in research/notes.md §1; Task 4 only appends the "what I did"
     result + the variant choice. -->
```

### Integration Points

```yaml
DOCS (README.md — the only edited shipped file):
  - edit: "Prerequisites §Dependencies required/optional clause (Task 1)"
  - edit: "Admin/doctor [dependencies] example block lines (Task 2)"
  - effect: "README now states ss is optional + (recommended) findmnt is required, matching Issue 2's
             shipped behavior and the actual doctor output."

RESEARCH LOG (research/notes.md):
  - append: "§5 Final sweep result (Task 4)" — variant choice + per-surface re-confirmed verdict.

NO other integration points: no code, no config, no test, no skill-doc change. The 7 other
checked doc surfaces are verified-accurate and untouched. This is the final doc subtask.
```

## Validation Loop

> **AGENTS.md §1/§2**: every command below is non-blocking (grep/git diff/markdown) and wrapped
> in `timeout`. No Chrome, no daemon, no test-suite execution — this is a doc edit.

### Level 1: Edits landed (Immediate Feedback)

```bash
# (a) Task 1 — README Prerequisites now names ss as optional (+ findmnt as required, RECOMMENDED):
timeout 10 bash -c 'grep -nq "notify-send\` and \`ss\` are optional" README.md' \
  && echo "Task1: ss optional note PRESENT" || echo "Task1: MISSING ss note"
# (RECOMMENDED variant also check:)
timeout 10 bash -c 'grep -nq "\`jq\`, \`findmnt\`;" README.md' \
  && echo "Task1: findmnt required PRESENT (RECOMMENDED)" || echo "Task1: findmnt NOT added (MINIMAL variant or missing)"

# (b) Task 2 — README doctor [dependencies] block now shows the ss optional line:
timeout 10 bash -c 'grep -nq "ss → OK / MISSING (optional; port-probe degrades to curl-only)" README.md' \
  && echo "Task2: ss optional line PRESENT" || echo "Task2: MISSING ss line"
# Expected: both Task1+Task2 checks pass.
```

### Level 2: Diff scope (confirms ONLY README.md + the research log changed)

```bash
# (a) Shipped CODE + owned files UNTOUCHED:
timeout 30 git -C "$PWD" --no-pager diff --stat -- lib/pool.sh bin/ install.sh test/ PRD.md AGENTS.md tasks.json prd_snapshot.md .gitignore
# Expected: EMPTY output (no changes). Any line here = scope violation — revert it.

# (b) Only README.md changed among shipped docs:
timeout 30 git -C "$PWD" --no-pager diff --stat -- README.md .agents/skills/agent-browser-pool/SKILL.md .agents/skills/agent-browser-pool/README.md .agents/skills/agent-browser-pool/references/configuration.md
# Expected: ONLY README.md listed. The 3 skill docs must NOT appear (verified-accurate, untouched).

# (c) README.md diff is SMALL and localized to the 2 regions:
timeout 30 git -C "$PWD" --no-pager diff -- README.md
# Expected: 2 hunks — one around line 47-48 (Prerequisites), one around line 230-231 (doctor block).
# Inspect manually: no other prose changed; fences intact.
```

### Level 3: Markdown sanity (the doctor block still renders)

```bash
# (a) Code-fence balance in README.md (``` count must be EVEN):
timeout 10 bash -c 'n=$(grep -c "^```" README.md); [ $((n % 2)) -eq 0 ]' \
  && echo "README fences balanced ($(...))" || echo "README fences UNBALANCED — fix before done"

# (b) Optional — markdownlint if available (do not fail the task on pre-existing issues, only on NEW ones):
if command -v markdownlint-cli2 >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
  timeout 60 npx --no-install markdownlint-cli2 README.md .agents/skills/agent-browser-pool/*.md .agents/skills/agent-browser-pool/references/*.md 2>/dev/null \
    || echo "(markdownlint reported issues — compare against pre-edit baseline; only NEW issues introduced by this diff are blockers)"
else
  echo "(markdownlint not installed — skip; manual render review in Level 2 (c) suffices)"
fi
# Expected: no NEW lint issues introduced by the 2-region README edit.
```

### Level 4: Audit completeness (the verdict log exists)

```bash
# research/notes.md has the §5 Final sweep result appended (Task 4):
timeout 10 bash -c 'grep -q "Final sweep result" plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T4S1/research/notes.md' \
  && echo "verdict log PRESENT" || echo "MISSING verdict log (run Task 4)"
# Expected: present.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `README.md` names `ss` as optional in BOTH the Prerequisites clause and the `doctor`
      `[dependencies]` example block (Level 1 (a)+(b)).
- [ ] `git diff --stat` over code + owned files is EMPTY (Level 2 (a)); only `README.md` changed
      among shipped docs (Level 2 (b)).
- [ ] README.md code fences balanced; doctor example block still renders (Level 3).
- [ ] `research/notes.md` §5 "Final sweep result" appended (Level 4).

### Feature Validation

- [ ] The 2 README edits applied (RECOMMENDED or MINIMAL variant — documented in the log).
- [ ] All 7 other checked doc surfaces carry an ACCURATE verdict in `research/notes.md` §1,
      re-confirmed live; none were edited.
- [ ] Every doc surface named in the item contract (README §doctor, §reap, §internals,
      §Dependencies; SKILL.md; configuration.md) was checked and has a verdict.
- [ ] No claim in any shipped doc is now contradicted by the final `lib/pool.sh` state.

### Code Quality Validation

- [ ] The README edits follow the existing prose style (no reflow, fences + alignment preserved).
- [ ] Scope respected: code, PRD.md, AGENTS.md, tasks.json, prd_snapshot.md, .gitignore, and all
      skill docs untouched.
- [ ] No "improvements" to accurate prose; no changelog narrative added (per item contract point 3).

### Documentation & Deployment

- [ ] The README "verify the whole stack" promise is now honest w.r.t. `ss`/`findmnt`.
- [ ] The verdict log is traceable (per-file:line, claim, verdict, action).

---

## Anti-Patterns to Avoid

- ❌ Don't rewrite or "improve" prose that is already accurate — the item contract (point 3)
  explicitly forbids it ("If a doc file is ALREADY accurate, do NOT change it").
- ❌ Don't add Issue-1 / Issue-3 changelog narrative to the docs — they are internal hardening
  with no user-visible behavior change; the existing high-level summaries already cover them.
- ❌ Don't touch code (`lib/pool.sh`/`bin/*`/`install.sh`/`test/*`) — the fixes are DONE and owned
  by the sibling subtasks; this is the doc task.
- ❌ Don't touch `PRD.md`, `AGENTS.md`, `tasks.json`, `prd_snapshot.md`, or `.gitignore`.
- ❌ Don't add `ss`/`findmnt` to the skill docs — they have no dependency list (that lives in
  README §Prerequisites); the change has no surface there.
- ❌ Don't delete or duplicate the ``` fence around the doctor example block (Task 2) — edit the
  lines inside it only.
- ❌ Don't locate edits by fixed line number — match the exact quoted FIND text (lines drift).
- ❌ Don't claim "verified accurate" without re-confirming each verdict against the live tree
  (Task 0 + Task 3). If the tree changed since research, re-verify before editing.
