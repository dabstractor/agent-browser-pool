# PRP — P1.M4.T1.S1: Update README.md overview sections for changeset-level changes (Mode B)

> **Bugfix context**: This is the FINAL subtask of **P1.M4** — the **Mode B** changeset-level
> documentation sync. It depends on ALL implementing subtasks (P1.M1–P1.M3) and runs LAST. It
> sweeps `README.md` **narrative/overview** sections that span multiple issues. Per-file docs
> (env var table, `pool_admin_help`, inline code comments) were ALREADY updated in **Mode A**
> by the implementing subtasks — this task does NOT re-touch them. README.md is EXCLUSIVELY
> this task's file (the parallel P1.M3.T1.S3 is test-only on `test/release_reaper.sh` — no
> conflict).

---

## Goal

**Feature Goal**: Sweep `README.md` overview/narrative sections so they accurately reflect the
changeset-level behavior changes from **Issue 1** (boolean env vars now accept
`1`/`true`/`yes`/`on`) and **Issue 4** (a bare `agent-browser` with no subcommand is now META
passthrough, not a Chrome-booting driving command). No stale documentation remains; every
narrative mention of the safety valve / boolean env vars / the META set agrees with the
already-updated env-var table and `pool_admin_help`.

**Deliverable**: **7 surgical, in-place text edits to `README.md`** (no new files, no other
files touched):
- **6 edits for Issue 1** — broaden each prose mention of `AGENT_BROWSER_POOL_DISABLE=1` /
  `AGENT_CHROME_ALLOW_SLOW_COPY=1` (which imply only `1` works) to name the accepted
  `1`/`true`/`yes`/`on` set, matching the env-var table (line 220, already Mode-A-updated).
- **1 edit for Issue 4** — add "bare invocation with no subcommand" to the enumerated META
  command list in "How it works".

**Success Definition**:
- After the edits, every narrative mention of a boolean pool env var agrees with the env-var
  table + `pool_admin_help` (all say `1`/`true`/`yes`/`on`); no prose implies "only `=1` works".
- The "How it works" META list explicitly includes bare/no-subcommand invocation.
- The 3 deliberately-unchanged sites stay unchanged (env table line 220 — Mode A; the
  "Three vars" behavior bullets 225–227; the internal-global lifecycle line 272).
- `git diff -- README.md` shows ONLY the 7 targeted hunks — no accidental reflow of the env
  table, no re-wrapping of unrelated paragraphs, markdown fences/tables intact.

## User Persona

**Target User**: Operators and `pi` agents reading `README.md` to understand the wrapper's
behavior — especially **during cutover** (PRD §2.17), where `AGENT_BROWSER_POOL_DISABLE` is the
ONLY per-session opt-out and Issue 1's most severe impact lives (key_findings §ISSUE 1:
"`AGENT_BROWSER_POOL_DISABLE=true` does NOT disable pooling" before the fix).

**Use Case**: An operator mid-cutover reads the **Safety valve** section (or the **Installation
cutover warning**) and sets the disable env var to the documented truthy form. After Issue 1
(code) + this task (docs), the docs they read match the code's accepted values — so
`AGENT_BROWSER_POOL_DISABLE=true` works as the docs imply.

**Pain Points Addressed**:
- **Docs/code contradiction (Issue 1 + Issue 5 root cause)**: Mode A fixed the code + the env
  table + help text; Mode B (this task) fixes the remaining NARRATIVE mentions so the whole
  README is internally consistent.
- **Bare-invocation surprise (Issue 4)**: before the fix, a no-subcommand `agent-browser`
  booted a full Chrome; after the fix it's passthrough. The "How it works" META list must now
  say so, so a reader probing the CLI knows it won't acquire a lane.

## Why

- **Mode B exists precisely for this.** Per-file docs ride with the implementing subtask (Mode
  A); cross-cutting narrative that spans issues is swept LAST in one dedicated pass so it stays
  consistent (no half-updated README). The implementing PRPs explicitly deferred the README
  narrative to this task — e.g. P1.M1.T2S1 (Issue 4): *"No README change needed … The Mode B
  final task (P1.M4.T1) will sweep README 'How it works' if a discrepancy is found."*
- **Issue 1's cutover-criticality.** key_findings §ISSUE 1 names the disable valve as "the only
  per-session opt-out during cutover … an operator will reach for `true`." The README's cutover
  warning (line 60) and Safety valve section (line 236) are the exact docs that operator reads;
  saying only `=1` there is the most damaging form of the staleness.
- **Minimal, surgical scope.** The env table is already authoritative (Mode A). The narrative
  edits are token/phrase swaps — no section rewrites — so the risk of introducing NEW
  inaccuracy is near-zero. Issues 2/3/5 have **no** README narrative impact (§Why-out-of-scope
  below) and are deliberately untouched.

## What

### The 7 edits (exact sites, all verified against the current 372-line README.md)

**Issue 1 — boolean env vars accept `1/true/yes/on` (6 edits):**

| # | Line | Section | Change (summary) |
|---|------|---------|------------------|
| 1 | 33 | Prerequisites (item 1) | `AGENT_CHROME_ALLOW_SLOW_COPY=1` → name var + `1/true/yes/on` |
| 2 | 60 | Installation — cutover warning | `AGENT_BROWSER_POOL_DISABLE=1` → name var + `1/true/yes/on` (cutover-critical) |
| 3 | 236 | Safety valve (heading prose) | `AGENT_BROWSER_POOL_DISABLE=1 makes …` → `(set to 1/true/yes/on) makes …` |
| 4 | 242 | Safety valve (code block) | add inline comment: `# 1/true/yes/on all work; per-process` (keep `=1` value) |
| 5 | 254 | How it works — "passes through" bullet 1 | `AGENT_BROWSER_POOL_DISABLE=1 (safety valve)` → "is set to a truthy value (1/true/yes/on)" |
| 6 | 337 | Troubleshooting — "It didn't do anything" | `AGENT_BROWSER_POOL_DISABLE=1 is set` → "is set (to a truthy value)" |

**Issue 4 — bare invocation is now META passthrough (1 edit):**

| # | Line | Section | Change (summary) |
|---|------|---------|------------------|
| 7 | 255–256 | How it works — "passes through" bullet 2 (META list) | append "or a bare invocation with no subcommand (upstream just prints help)" |

### Deliberately LEFT UNCHANGED (3 sites — accurate / out of scope)

- **Lines 218–220** (env var table) — Mode A already says `1/true/yes/on`. This table is the
  authoritative value reference; the 6 Issue-1 narrative edits mirror ITS form.
- **Lines 225–227** ("Three vars shape behavior most") — describe *behavior* (refuse / slow-copy
  / headless), NOT the accepted value form. Not stale.
- **Line 272** (lifecycle step 2 ``2. `POOL_DISABLE=1` → passthrough``) — names the **internal
  normalized global** `POOL_DISABLE` (not the env var). After `pool_config_init` normalizes a
  truthy env to the literal `"1"`, the runtime gate `[[ "$POOL_DISABLE" == "1" ]]` is accurate.
  Changing it would conflate the env var with the internal global.

### Why Issues 2, 3, 5 have NO README narrative impact (out of scope)

- **Issue 2** (port-collision race recovery): internal boot-path resilience. README "How it
  works" lifecycle says "launch Chrome" generically and NEVER mentions "retries on
  EADDRINUSE". No user-visible behavior change → no narrative change.
- **Issue 3** (close → rebind): user-visible behavior UNCHANGED ("close = disconnect-only; next
  call reuses the same browser"). The rebind is transparent (the agent never sees it) → no
  narrative change.
- **Issue 5** (help-text "if set" wording): `pool_admin_help` in `lib/pool.sh` was already fixed
  in Mode A; README has no parallel "if set" wording → no narrative change.

### Success Criteria

- [ ] All 7 edits applied to `README.md` exactly as specified in Implementation Tasks.
- [ ] The env-var table (218–220) is BYTE-UNCHANGED (Mode A owns it).
- [ ] Line 272 (internal `POOL_DISABLE=1`) is UNCHANGED.
- [ ] `grep -nE '1/true/yes/on' README.md` shows the value set in the table (3) AND in the 6
      narrative edits (Prerequisites, cutover warning, Safety valve prose, Safety valve comment,
      How-it-works bullet, and implied/by-reference where the prose names the var + set).
- [ ] `grep -nE 'bare invocation|no subcommand' README.md` shows the Issue-4 addition in the
      META bullet.
- [ ] No narrative prose remains that implies only `=1` works for a boolean pool env var.
- [ ] `git diff -- README.md` shows ONLY the 7 targeted hunks (no table reflow, no paragraph
      re-wrap, markdown fences/tables intact).
- [ ] No file other than `README.md` is modified.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **scope determination** (Issue 1 + Issue 4
only; 2/3/5 explicitly excluded with reasoning); the **7 exact edit sites** with current text +
replacement text (paste-ready into the `edit` tool); the **3 deliberately-unchanged sites** with
the reasoning each is accurate; the **parallel-task non-conflict** proof (P1.M3.T1.S3 is
test-only); the **consistency contract** (every Issue-1 edit uses the exact `1/true/yes/on`
token order Mode A settled); and copy-pasteable grep-based validation commands for a
markdown-only task.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: §ISSUE 1 (boolean env vars — root cause, the 5 consumer sites, the doc contradictions incl.
        README:218, and the fix RECOMMENDATION "accept truthy values" because the disable valve is
        cutover-critical); §ISSUE 4 (bare agent-browser → META passthrough); §ISSUE 5 (help "if set").
        Confirms the canonical value set is 1/true/yes/on.
  pattern: §ISSUE 1 "Fix Approach" + §ISSUE 4 "Fix Approach" are the behavior this task documents.
  gotcha: §ISSUE 1 says the disable valve is "the only per-session opt-out during cutover" — the
        cutover warning (README:60) + Safety valve (README:236) are the highest-value doc sites.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T1S1/PRP.md   # Issue 1 + 5 (Mode A — COMPLETE)
  why: the Mode-A subtask that LANDED the boolean fix + updated the env-var table (README:218–220),
        pool_admin_help (lib/pool.sh:4418–4420), the docstring, and the line-171 comment — all to
        `1/true/yes/on`. THIS task MIRRORS that exact token order in the narrative. Read it to
        confirm what Mode A already owns (so this task does NOT re-touch it).
  pattern: Task 4 of that PRP is the env-table edit (the authoritative form `1/true/yes/on`).
  gotcha: Mode A already updated README:218–220 — DO NOT re-edit the table here.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T2S1/PRP.md   # Issue 4 (Mode A — COMPLETE)
  why: the Mode-A subtask that made pool_dispatch_classify return `meta` for a no-command argv.
        Its "Documentation & Deployment" section EXPLICITLY deferred the README sweep: "No README
        change needed … The Mode B final task (P1.M4.T1) will sweep README 'How it works' if a
        discrepancy is found." THIS task IS that sweep (edit #7).
  pattern: the fix classifies bare invocation AS `meta`, so the README's "passes through" META list
        must include it.
  gotcha: the fix does NOT change which real commands are META/DRIVING — only the no-command case.
        So the README edit is ADDITIVE (append "or a bare invocation …"), not a list rewrite.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S3/PRP.md   # parallel task (CONTRACT)
  why: the parallel work item. It is TEST-ONLY on test/release_reaper.sh (adds test_close_then_rebind
        for Issue 3). Its PRP states: "It does NOT touch lib/pool.sh, test/validate.sh, other test
        files, or any docs." → ZERO conflict with this README-only task.
  pattern: confirms README.md is exclusively this task's file.

- file: README.md
  why: THE file being edited. Read lines 28–49 (Prerequisites), 50–88 (Installation + cutover
        warning), 201–247 (Configuration reference + Safety valve), 249–289 (How it works), 331–341
        (Troubleshooting). The 7 edit sites are at lines 33, 60, 236, 242, 254, 255–256, 337.
  pattern: narrative prose uses backticked env-var names; the env table (220) is the value
        reference; code blocks use ```bash fences.
  gotcha: line numbers shift as edits are applied — LOCATE each site by its unique current text
        (the oldText in Implementation Tasks), NOT by line number. The env table (218–220) and
        line 272 are HANDS-OFF.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M4T1S1/research/readme-sweep-stale-sites.md
  why: THIS task's research: §0 (scope = Issue 1 + 4 only), §1 (what Mode A already owns — skip),
        §2 (the 7 stale sites), §3 (the 3 deliberately-unchanged sites + reasoning), §4 (parallel
        non-conflict), §5 (the consistency contract — exact `1/true/yes/on` order), §6 (validation
        approach for a markdown task), §7 (anti-scope reminders).
  pattern: §2 is the edit table; §5 is the wording contract.
  gotcha: §3 explains why line 272 (internal POOL_DISABLE=1 global) MUST stay — do not "fix" it.

- file: PRD.md (bugfix snapshot)
  why: §2.17 (cutover & coexistence — the safety valve's reason for existing), §2.11 (configuration
        env vars), §2.4 step 0 (dispatch — the META vs DRIVING classification Issue 4 touches),
        §2.15 (transparency / no surprises — why a bare invocation must not boot Chrome).
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── README.md        # 372 lines — THE file edited (7 surgical edits). Env table 218–220 = Mode A (HANDS-OFF).
├── lib/pool.sh      # NOT edited (Mode A already updated pool_admin_help:4418-4420 + docstring + comment).
├── PRD.md           # READ-ONLY
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/{key_findings,system_context,external_deps}.md
    ├── P1M1T1S1/PRP.md   # Issue 1+5 Mode A (COMPLETE) — owns env table + help text
    ├── P1M1T2S1/PRP.md   # Issue 4 Mode A (COMPLETE) — owns pool_dispatch_classify
    ├── P1M2T1.{S1,S2}/   # Issue 2 (COMPLETE) — no README impact
    ├── P1M3T1.{S1,S2,S3}/# Issue 3 (S1/S2 COMPLETE; S3 parallel, test-only)
    └── P1M4T1S1/         # THIS subtask
        ├── PRP.md        # THIS FILE
        └── research/readme-sweep-stale-sites.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONE file MODIFIED in-place:
#   README.md  — 7 surgical text edits (6 for Issue 1, 1 for Issue 4). No section rewrites.
```

**File responsibility**: `README.md` remains the shipped-product user docs. This sweep makes
its overview/narrative sections agree with the Mode-A-updated env table + `pool_admin_help`,
closing the docs/code contradiction for Issue 1 and documenting Issue 4's bare-invocation
passthrough.

### Known Gotchas of our codebase & Library Quirks

```markdown
<!-- CRITICAL (Mode A already owns the env table): lines 218–220 already say `1/true/yes/on`.
     DO NOT re-edit the table — it is the authoritative value reference and is correct.
     Re-touching it is scope creep + merge-conflict risk. -->

<!-- CRITICAL (consistency contract): every Issue-1 narrative edit MUST use the EXACT token
     order `1/true/yes/on` (matching the table + pool_admin_help). Not `true/yes/on/1`, not
     omitting `/on` (the pre-Mode-A line 218 said `1/true/yes` and Mode A ADDED `/on`).
     Consistency across table + help + narrative is the whole point of Mode B. -->

<!-- CRITICAL (line 272 stays): `2. POOL_DISABLE=1 → passthrough` names the INTERNAL normalized
     global, not the env var. After pool_config_init normalizes a truthy env to "1", the
     runtime gate [[ "$POOL_DISABLE" == "1" ]] is accurate. Do NOT "fix" it — that would
     conflate the env var with the internal global. (research §3) -->

<!-- CRITICAL (Issue 4 is ADDITIVE): do NOT rewrite the META command list — APPEND "or a bare
     invocation with no subcommand" to it. The fix did not change which real commands are
     META/DRIVING; it only added the no-command case to META. -->

<!-- CRITICAL (the code-block VALUE stays =1): edit #4 ADDS an inline comment to
     `export AGENT_BROWSER_POOL_DISABLE=1`; it does NOT change the value. `=1` is a valid
     canonical example (it still works). Only the comment is new. -->

<!-- GOTCHA (locate by text, not line number): line numbers shift as edits land. LOCATE each
     site by its unique current text (the oldText in Implementation Tasks). Use the `edit`
     tool with the exact oldText → newText. -->

<!-- GOTCHA (no markdown linter in this repo): validation is grep assertions + manual review,
     NOT bash -n/shellcheck (README.md is prose). See Validation Loop. -->

<!-- GOTCHA (parallel non-conflict): P1.M3.T1.S3 (parallel) is test-only on
     test/release_reaper.sh — it does NOT touch README.md. README.md is exclusively this task's. -->

<!-- GOTCHA (Issues 2/3/5 are out of scope): they have NO README narrative impact.
     Issue 2 = internal port-race resilience (README never mentions EADDRINUSE retries).
     Issue 3 = transparent rebind (user-visible behavior unchanged).
     Issue 5 = help-text "if set" (already fixed in lib/pool.sh by Mode A; README has no parallel). -->
```

## Implementation Blueprint

### Data models and structure

Not applicable — no code, no schema, no globals. This is a prose edit to a markdown file. The
"structure" is the 7 (oldText, newText) pairs below, each a unique, non-overlapping region of
`README.md`.

### Implementation Tasks (ordered by file position — top to bottom)

> Each task gives the EXACT `oldText` (unique in README.md — locate by it, not by line number)
> and the `newText`. Apply with the `edit` tool. All 7 edits are independent and
> non-overlapping; they may be applied in a single `edit` call with 7 entries OR one call each.
>
> **CRITICAL — IDEMPOTENCY (parallel-execution safety):** a concurrent process may have
> ALREADY applied some/all of these edits (observed: a parallel run landed all 7 verbatim
> while the PRP was being written). **Task 0 MUST run first** to classify the current state;
> any edit whose `newText` is ALREADY present is a NO-OP (skip it — do not error). Any edit
> whose `oldText` is still present is applied normally. This makes the task safe whether the
> README is pre-edit, fully-edited, or partially-edited.

```yaml
Task 0: PRE-CHECK — classify each site's current state (idempotency gate — RUN FIRST)
  - RUN: for each of the 7 sites, grep for the NEW (post-edit) text. If present → ALREADY
        DONE (skip that edit). Else grep for the OLD text. If present → APPLY. Else → the
        site is in an UNEXPECTED state → STOP and report (do NOT guess).
  - ONE-LINER that lists which OLD-text markers still remain (empty output = all 7 done):
        grep -nE 'AGENT_CHROME_ALLOW_SLOW_COPY=1"\.|is `AGENT_BROWSER_POOL_DISABLE=1`\.|AGENT_BROWSER_POOL_DISABLE=1` makes|^- `AGENT_BROWSER_POOL_DISABLE=1` \(safety valve\)|plugin`\), which need no lane;|AGENT_BROWSER_POOL_DISABLE=1` is set in that shell' README.md || echo "ALL 7 EDITS ALREADY APPLIED (no-op)"
  - ONE-LINER that lists which NEW-text markers are present (count up to 7):
        grep -cE 'ALLOW_SLOW_COPY` \(to `1`/`true`/`yes`/`on`\)|POOL_DISABLE` \(set to `1`/`true`/`yes`/`on`\)|# 1/true/yes/on all work|is set to a truthy value|bare invocation with no subcommand|is set \(to a truthy value\) in that shell' README.md
  - EXPECT: the two counts sum to 7 (each site is either DONE or PENDING). If the OLD-grep is
        empty → ALL DONE → skip Tasks 1–7, go straight to Task 8 (verify). If a site matches
        NEITHER old nor new → unexpected state → STOP + report (someone restructured the prose).
  - NOTE: if ALL 7 are already applied, the implementer's deliverable is reduced to the Task 8
        verification (confirm the diff is exactly the 7 hunks + the 3 hands-off sites untouched).
        That is a CORRECT, complete outcome — the PRP is idempotent by design.

Task 1 (Issue 1) — Prerequisites item 1 (line ~33): AGENT_CHROME_ALLOW_SLOW_COPY
  - oldText: '   copy unless you set `AGENT_CHROME_ALLOW_SLOW_COPY=1`.'
  - newText: '   copy unless you set `AGENT_CHROME_ALLOW_SLOW_COPY` (to `1`/`true`/`yes`/`on`).'
  - WHY: Issue 1 broadened the accepted set to 1/true/yes/on; this mention implied only =1.

Task 2 (Issue 1) — Installation cutover warning (line ~60): AGENT_BROWSER_POOL_DISABLE
  - oldText: '> is `AGENT_BROWSER_POOL_DISABLE=1`. Once installed, **running agents on the OLD'
  - newText: '> is `AGENT_BROWSER_POOL_DISABLE` (set to `1`/`true`/`yes`/`on`). Once installed, **running agents on the OLD'
  - WHY: cutover-critical (key_findings §ISSUE 1 — the disable valve is the only per-session
        opt-out; an operator "will reach for true"). The cutover warning is the doc they read.

Task 3 (Issue 1) — Safety valve heading prose (line ~236): AGENT_BROWSER_POOL_DISABLE
  - oldText: '`AGENT_BROWSER_POOL_DISABLE=1` makes **this process** pass through to the real'
  - newText: '`AGENT_BROWSER_POOL_DISABLE` (set to `1`/`true`/`yes`/`on`) makes **this process** pass through to the real'
  - WHY: the Safety valve section is THIS var's dedicated reference; the contract explicitly
        asks for it to list the accepted values (not just =1).

Task 4 (Issue 1) — Safety valve code block (line ~242): add an inline comment
  - oldText: 'export AGENT_BROWSER_POOL_DISABLE=1\nagent-browser open https://example.com    # real ~/.local/bin/agent-browser, no lane'
  - newText: 'export AGENT_BROWSER_POOL_DISABLE=1   # 1/true/yes/on all work; per-process (not global)\nagent-browser open https://example.com    # real ~/.local/bin/agent-browser, no lane'
  - WHY: the canonical `=1` example stays (it is valid), but a comment points readers to the
        full accepted set. NOTE: the value is UNCHANGED (only a comment is added).
  - GOTCHA: preserve the second line's comment + its leading spaces EXACTLY (only the export
        line gains a trailing comment). If the exact second-line spacing is hard to match, apply
        this as TWO smaller edits (the export line alone) — see Task 4b fallback below.

  Task 4b (FALLBACK for Task 4 if the two-line oldText is finicky — use ONLY the export line):
  - oldText: 'export AGENT_BROWSER_POOL_DISABLE=1\n'
  - newText: 'export AGENT_BROWSER_POOL_DISABLE=1   # 1/true/yes/on all work; per-process (not global)\n'
  - (Prefer Task 4; fall back to 4b only if the editor cannot match the two-line block.)

Task 5 (Issue 1) — How it works "passes through unchanged when" bullet 1 (line ~254)
  - oldText: '- `AGENT_BROWSER_POOL_DISABLE=1` (safety valve);'
  - newText: '- `AGENT_BROWSER_POOL_DISABLE` is set to a truthy value (`1`/`true`/`yes`/`on`) — the safety valve;'
  - WHY: this quick-reference bullet implied only =1; now names the accepted set.

Task 6 (Issue 4) — How it works "passes through unchanged when" bullet 2, the META list (lines ~255–256)
  - oldText: '- the command is a **META** command (`skills`, `--help`, `--version`, `session\n  list`, `dashboard`, `plugin`), which need no lane;'
  - newText: '- the command is a **META** command (`skills`, `--help`, `--version`, `session\n  list`, `dashboard`, `plugin`) **or a bare invocation with no subcommand**\n  (upstream just prints help), which need no lane;'
  - WHY: after Issue 4, a no-subcommand `agent-browser` is classified `meta` → passthrough (it
        no longer boots Chrome). The enumerated META list must say so. ADDITIVE — do not rewrite
        the existing list.
  - GOTCHA: the list wraps across two lines ("session\n  list"); the newText continues that
        wrap style ("**or a bare invocation with no subcommand**\n  (upstream just prints help)").

Task 7 (Issue 1) — Troubleshooting "It didn't do anything" (line ~337): AGENT_BROWSER_POOL_DISABLE
  - oldText: 'ancestor), or `AGENT_BROWSER_POOL_DISABLE=1` is set in that shell.'
  - newText: 'ancestor), or `AGENT_BROWSER_POOL_DISABLE` is set (to a truthy value) in that shell.'
  - WHY: diagnostic text implied only =1; "is set (to a truthy value)" is accurate + concise.
  - SKIP IF the NEW text (`is set (to a truthy value) in that shell`) is already present (Task 0).

Task 8: VERIFY (run before claiming done — every command must pass; see Validation Loop)
  - RUN: the Level 1 + Level 2 grep assertions.
  - RUN: `git diff -- README.md` and confirm ONLY the 7 targeted hunks (no table reflow, no
        paragraph re-wrap, fences/tables intact).
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```markdown
<!-- Pattern A — the consistent Issue-1 narrative form (mirror the env table's `1/true/yes/on`):
     "name the env var, then (set to `1`/`true`/`yes`/`on`)" — used in edits 1, 2, 3, 5.
     Edits 4 (comment), 6 (troubleshooting, "truthy value" — concise), 7 (bare invocation) are
     the form-specific variants. NEVER write `true/yes/on` without `1`, NEVER drop `/on`. -->

<!-- Pattern B — locate-by-text, not line number: every oldText above is unique in README.md.
     Apply via the `edit` tool. Line numbers in the comments are approximate (they shift). -->

<!-- Pattern C — additive, not rewrite: edit #6 (Issue 4) APPENDS to the META list; it does not
     re-list the existing META commands. Edits 1–5/7 swap a token/phrase in place; they do not
     restructure sentences beyond the minimal accurate wording. -->
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — NOT edited by this task):
  - Issue 1 fix (P1.M1.T1.S1, COMPLETE): _pool_config_bool now accepts 1/true/yes/on (case-
        insensitive). pool_admin_help (lib/pool.sh:4418-4420) + env table (README:218-220) +
        docstring/comment already say 1/true/yes/on. THIS task makes the NARRATIVE agree.
  - Issue 4 fix (P1.M1.T2.S1, COMPLETE): pool_dispatch_classify returns `meta` for a no-command
        argv → pool_wrapper_main step c execs passthrough. THIS task documents it in the META list.

PROVIDED (this task adds): the 7 README narrative edits. No code, no test, no other doc.

CONFIG / DATABASE / ROUTES: none. Markdown prose only.

PARALLEL TASK (P1.M3.T1.S3 — test-only on test/release_reaper.sh): ZERO conflict (disjoint file).
```

## Validation Loop

> **CRITICAL**: this is a MARKDOWN-ONLY task. There is no bash code to `bash -n`/`shellcheck`
> and no markdown linter configured in this repo. Validation = **grep assertions + manual
> review + git diff inspection**. No Chrome, no daemon, no test suite — pure static doc checks.

### Level 1: Stale-exclusivity sweep (no prose implies "only =1 works")

```bash
# 1a. After the edits, every remaining `=1`-only boolean mention must be a KNOWN-OK site.
#     Run this and confirm each hit is either the env table (Mode A), line 272 (internal global),
#     or the code-block export (now commented). NO narrative prose should say "VAR=1" implying
#     exclusivity.
grep -nE 'AGENT_BROWSER_POOL_DISABLE=1|AGENT_CHROME_ALLOW_SLOW_COPY=1|AGENT_CHROME_HEADLESS=1' README.md
# Expected hits (all OK):
#   <table line 220>         — env table (Mode A; HANDS-OFF) — OK
#   <line ~242> export ...=1 # 1/true/yes/on ...  — code example + NEW comment — OK
#   <line ~272> 2. POOL_DISABLE=1 → passthrough  — internal global (deliberately kept) — OK
# If you see a narrative-prose "=1" hit that is NOT one of the above, an edit was missed.

# 1b. The truthy set appears in the narrative (the 6 Issue-1 edits) + the table.
grep -nE '1/true/yes/on' README.md
# Expected: ≥ the env-table rows (3) + the narrative edits (Prerequisites, cutover warning,
#           Safety valve prose, Safety valve comment, How-it-works bullet). At least 6–9 hits.
```

### Level 2: Issue-4 (bare invocation) presence + render sanity

```bash
# 2a. The META bullet now mentions bare/no-subcommand invocation.
grep -nE 'bare invocation with no subcommand|no subcommand' README.md
# Expected: 1 hit in the "How it works" META bullet (~line 255).

# 2b. Markdown structure intact: the env table still has its 3 boolean rows + fences balanced.
grep -cE '^\| `AGENT_(BROWSER_POOL_DISABLE|CHROME_HEADLESS|CHROME_ALLOW_SLOW_COPY)`' README.md   # expect 3
grep -c '```' README.md   # expect an EVEN number (balanced fences) — same parity as before the edit
```

### Level 3: Minimal-diff inspection (no accidental reflow)

```bash
# 3a. ONLY README.md changed; no other file touched.
git status --porcelain --untracked-files=all
# Expected: only `M README.md` (plus any pre-existing unrelated changes NOT made by this task).

# 3b. The diff is surgical: ~7 hunks, each a small token/phrase swap. NO env-table reflow,
#     NO paragraph re-wrap, NO fence changes.
git diff -- README.md
# Expected: 7 hunks at lines ~33, ~60, ~236, ~242, ~254, ~255–256, ~337. The env table
#           (218–220) and line 272 MUST NOT appear in the diff.

# 3c. (Automated guard) assert the env table + line 272 are UNTOUCHED:
git diff -- README.md | grep -E '^[+-].*POOL_DISABLE=1.*passthrough|^[+-]\| `AGENT_BROWSER_POOL_DISABLE`' \
  && echo "FAIL: env table or line 272 was touched" || echo "OK: table + line 272 untouched"
# Expected: OK: table + line 272 untouched.
```

### Level 4: Cross-source consistency + manual render

```bash
# 4a. README narrative, env table, and pool_admin_help ALL agree on 1/true/yes/on.
grep -oE '1/true/yes/on' README.md | sort -u                     # → 1/true/yes/on
grep -oE '1/true/yes/on' lib/pool.sh | sort -u | head -1         # → 1/true/yes/on (Mode A)
# Expected: both print exactly "1/true/yes/on" (the canonical form).

# 4b. Manual render check — read each edited section and confirm it reads naturally + the
#     markdown is still valid (table renders, code block fence intact, bullets aligned):
#       - Prerequisites item 1 (~line 33)
#       - Installation cutover warning (~line 60)
#       - Safety valve section (~lines 234–247) — prose + code block comment
#       - How it works "passes through unchanged when" list (~lines 251–257) — both bullets
#       - Troubleshooting "It didn't do anything" (~line 337)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1a: no narrative-prose `=1`-only boolean mention remains (only the table, the
      commented code example, and line 272 — all known-OK).
- [ ] Level 1b: `1/true/yes/on` appears in the narrative edits + the table.
- [ ] Level 2a: the META bullet mentions bare/no-subcommand invocation.
- [ ] Level 2b: env table still has 3 boolean rows; code fences balanced (even count).
- [ ] Level 3a: ONLY `README.md` modified.
- [ ] Level 3b: `git diff -- README.md` shows ~7 surgical hunks; env table + line 272 absent.
- [ ] Level 3c: "OK: table + line 272 untouched".
- [ ] Level 4a: README + lib/pool.sh both print exactly `1/true/yes/on`.

### Feature Validation

- [ ] Issue 1: all 6 narrative mentions of a boolean pool env var agree with the env table.
- [ ] Issue 4: "How it works" META list includes bare/no-subcommand invocation.
- [ ] No narrative implies "only `=1` works" for any boolean pool env var.
- [ ] The 3 deliberately-unchanged sites (table 218–220, bullets 225–227, lifecycle 272) are
      byte-unchanged.

### Code Quality / Documentation

- [ ] Every Issue-1 edit uses the exact `1/true/yes/on` token order (Mode A consistency).
- [ ] Edits are surgical (token/phrase swaps), not section rewrites.
- [ ] Markdown table + code fences + bullet alignment preserved.
- [ ] Comments are accurate and not verbose.
- [ ] No scope creep into Issues 2/3/5 (no README narrative impact).

### Documentation & Deployment

- [ ] README narrative now agrees with the env table + `pool_admin_help` (Mode A) — the
      docs/code contradiction from Issue 1 + Issue 5 is fully closed across all README surfaces.
- [ ] No new env vars, no config changes, no code changes, no test changes — README prose only.

---

## Anti-Patterns to Avoid

- ❌ Don't re-edit the env-var table (lines 218–220) — Mode A (P1.M1.T1.S1) owns it; it is
  correct. Re-touching it is scope creep + merge-conflict risk.
- ❌ Don't edit `lib/pool.sh`, `test/*`, `PRD.md`, `tasks.json`, or any file other than
  `README.md` — this is Mode B (README narrative only). Per-file docs were Mode A's job.
- ❌ Don't change the code-block `export …=1` VALUE — `=1` is valid; only ADD a comment (Task 4).
- ❌ Don't "fix" line 272 (`POOL_DISABLE=1 → passthrough`) — it names the INTERNAL normalized
  global, not the env var; it is accurate (research §3).
- ❌ Don't rewrite the META command list — APPEND "or a bare invocation with no subcommand"
  (Task 6). The Issue-4 fix only ADDED the no-command case to META; it didn't change real commands.
- ❌ Don't use a different value-token order (`true/yes/on`, `yes/true/on`, …) — the canonical
  Mode-A form is exactly `1/true/yes/on`; match it everywhere.
- ❌ Don't add Issue 2/3/5 narrative — they have no user-visible/README behavior change
  (Issue 2 internal, Issue 3 transparent, Issue 5 already in lib/pool.sh).
- ❌ Don't locate edit sites by line number — they shift as edits land. Locate by the unique
  `oldText` given in Implementation Tasks.
- ❌ Don't reflow/re-wrap unrelated paragraphs or the env table — the diff must be the 7
  targeted hunks only (Level 3b/3c).
- ❌ Don't run `bash -n`/`shellcheck`/a test suite as a "validation gate" for this task —
  README.md is prose; validation is grep + manual review + git diff (Validation Loop).

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: this is a pure-prose edit to one file with **7 exactly-specified (oldText, newText)
pairs**, each verified unique in the current README.md. The scope is tightly bounded (Issue 1 +
Issue 4 narrative only; Issues 2/3/5 explicitly excluded with reasoning), the 3
deliberately-unchanged sites are named with their rationale, and the consistency contract
(exact `1/true/yes/on` token order) is pinned. The parallel task (P1.M3.T1.S3) is test-only on a
disjoint file → no conflict. The -1 reflects the usual markdown-edit residual risk: if the
implementer's editor rewraps a paragraph or mis-matches a multi-line `oldText` (Tasks 4 and 6
span two lines), the diff could grow beyond the 7 hunks — Level 3b/3c catches that immediately,
and Task 4b provides a fallback for the two-line Task 4 block.
