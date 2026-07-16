# PRP — P1.M1.T1.S1: Delete step-c META passthrough block from `pool_wrapper_main`

> **Bugfix context**: This subtask is the **first half of the fix for Issue 1** (Critical)
> from the QA report (`plan/002_97982899bef6/bugfix/001_2f350a0ce445/TEST_RESULTS.md`).
> It removes the META-passthrough **execution path** from `pool_wrapper_main`. The
> `pool_dispatch_classify` function itself is left in place as dead code — it is deleted in
> the sibling subtask **S2** (`P1.M1.T1.S2`). This split is intentional and documented in
> the contract; do NOT delete the function here.
>
> **Why split S1/S2**: S1 alone closes the isolation breach (no code path exec's meta
> commands unchanged anymore). S2 is cleanup (removing the now-dead classifier + its
> selftest). Keeping them separate means a partial completion of M1.T1 still leaves the
> pool secure.

---

## Goal

**Feature Goal**: Remove the step-c META-passthrough block from `pool_wrapper_main` so that **all non-pool-verb tokens** (`--version`, `skills`, `mcp`, `dashboard`, `plugin`, `session list`, flags-only, and every unrecognized verb) flow through the driving path (owner resolve → fail-fast without `pi` → acquire/reuse lane → strip `--session` → force `AGENT_BROWSER_SESSION` → exec) instead of short-circuiting to an unchanged `exec` that bypasses session-forcing and owner-resolution. Sync the in-code comments and the `configuration.md` skill doc to describe the new "pool verbs vs driving" model.

**Deliverable**:
1. `lib/pool.sh` — step-c block deleted (the `class="$(pool_dispatch_classify "$@")"` assignment + the `if [[ "$class" == "meta" ]]` exec block).
2. `lib/pool.sh` — `class` removed from the `local class N port _has_json _a` declaration.
3. `lib/pool.sh` — `pool_wrapper_main` header comment updated: remove the `M6.T1.S1 pool_dispatch_classify (step c: meta vs driving)` line and the `GOTCHA — passthrough exec (c)` block; update the `GOTCHA — TERMINAL` line (exec exits are now `k` only, not `c/k`).
4. `lib/pool.sh` — `_pool_preflight_real_bin` comment updated: remove the "meta commands (skills/--version/…) exec it too" clause; note only driving commands exec it now.
5. `.agents/skills/agent-browser-pool/references/configuration.md` — § "Command dispatch: meta vs. driving" (lines 44–76) rewritten to "Command dispatch: pool verbs vs driving"; line 8 reference to `pool_dispatch_classify` removed.
6. `pool_dispatch_classify` function (lines 3012–3128) is **left in place as dead code** — S2 removes it.

**Success Definition**:
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` 0 findings.
- `grep -n 'class="$(pool_dispatch_classify\|class" == "meta"\|meta command → passthrough' lib/pool.sh` returns **nothing**.
- `grep -n 'local class N port' lib/pool.sh` returns **nothing** (`class` is gone from the decl).
- `pool_dispatch_classify()` still exists at ~line 3070 (dead code — S2's job to delete).
- An isolated micro-check confirms `--version`/`skills`/`mcp`/`session list` now reach the driving path (fail-fast with no `pi` ancestor) instead of exec'ing unchanged. (Verified statically — no real Chrome.)
- `configuration.md` describes "pool verbs vs driving" with no "Meta commands (passthrough)" subsection.

## User Persona

**Target User**: Agents invoking `agent-browser-pool` and operators running it. Primary beneficiary: **every agent in the pool** — the fix restores the #1 guarantee (lane isolation) by closing the cross-lane access hole.

**Use Case**: An agent that previously could run `agent-browser-pool mcp --session abpool-3` to attach an MCP server to lane 3's Chrome can no longer do so — `mcp` now flows through the driving path, gets `--session` stripped, and is forced to the caller's own `abpool-<N>`.

**Pain Points Addressed**:
- **Critical isolation breach** (Issue 1): `--session <X>` no longer passes through unstripped to `skills`/`mcp`/`dashboard`/`plugin`.
- **Fail-fast bypass** (Issue 2): `--version`/`skills`/`--json` now fail-fast without a `pi` ancestor, consistent with `open`/`screenshot`.
- **Docs/code drift** (Issue 3, docs half): skill doc no longer teaches the removed "meta → passthrough" model.

## Why

- **Issue 1 (Critical)** from the QA report: the META passthrough executes meta commands **unchanged and before owner resolution / session stripping**, so `--session <X>` reaches the real binary and can target any lane's daemon. Per `agent-browser mcp --help` (verified), `--session` is a documented Global Option and `mcp` exposes the full open/click/snapshot/eval surface — a complete read/write cross-lane breach.
- The Phase-2 delta (`plan/002_97982899bef6/delta_prd.md`, `D1.M1.T2`) explicitly mandates: "**Remove** the META passthrough step… there is no 'meta' class in the pool entry now."
- `bin/agent-browser-pool`'s dispatcher (lines 20–27) already correctly splits pool verbs (`status|reap|release|doctor|--help|-h|help`) from everything else; step-c in `pool_wrapper_main` is a **redundant** second classification that reintroduces the meta class the delta removed.
- PRD §1.3 Goal 3 + §2.13: "no command accepts a lane selector — one agent cannot reach another's lane through normal tool use."

## What

### Behavior change

Before: `pool_wrapper_main` step-c calls `pool_dispatch_classify "$@"`; if it returns `meta`, the function `exec "$POOL_REAL_BIN" "$@"` (original argv, no session strip/force) and never returns.

After: step-c is gone. Step a (config/state/preflight) runs, then control flows **directly** to step d (owner resolution). Every non-pool-verb token now takes the driving path: `pool_owner_resolve` → if `POOL_OWNER_PID==0` then `pool_die` (fail-fast) → else find-or-acquire lane → normalize args → strip `--session` → force `AGENT_BROWSER_SESSION=abpool-<N>` → `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"`.

### What does NOT change

- `pool_dispatch_classify` function body (lines 3012–3128) — **untouched** (dead code; S2 deletes it).
- `bin/agent-browser-pool` dispatcher — unchanged (already correct).
- Pool verbs (`status|reap|release|doctor|--help|-h|help`) — unchanged (caught by the bin dispatcher before `pool_wrapper_main` is ever called).
- The driving path itself (steps d–k) — unchanged.
- `test/transparency.sh`, `test/validate.sh` — **NOT touched in this subtask**. (Issue 3's test updates are sibling subtask `P1.M2.T1.S1`. The existing `test_passthrough_skills`/`test_version_passthrough` will now FAIL against the fixed code — that is expected and is S1's known consequence; `P1.M2.T1.S1` replaces them. Do not "fix" the tests here.)

### Success Criteria

- [ ] `lib/pool.sh` step-c block (the 8 lines: comment header + `class=...` + the `if`/`_pool_log`/`exec`/`fi`) is deleted.
- [ ] `local class N port _has_json _a` → `local N port _has_json _a` (`class` removed).
- [ ] `pool_wrapper_main` header comment: no reference to `pool_dispatch_classify (step c)` or `passthrough exec (c)`.
- [ ] `_pool_preflight_real_bin` comment: no "meta commands … exec it too" clause.
- [ ] `pool_dispatch_classify()` still present (dead code, untouched).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` 0 findings.
- [ ] `configuration.md`: "Command dispatch: pool verbs vs driving" (no "meta vs driving", no "Meta commands (passthrough)" subsection); line 8 no longer lists `pool_dispatch_classify`.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP quotes the **exact current text** at every edit site (verified by direct read of `lib/pool.sh` at lines 3439–3548 and `configuration.md` at lines 1–90), gives the exact replacement text, and specifies the exact validation commands. The change is mechanical line deletion + comment sync — no new logic, no new patterns. The implementer needs no prior exposure beyond reading the quoted snippets.

### Documentation & References

```yaml
# MUST READ — project-internal (primary; this is a code-surgery task, not a library task)
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/system_context.md
  why: 'The "Code Change Map" table lists EVERY edit site for the full Issue-1 fix (S1+S2). S1 owns the pool_wrapper_main step-c deletion + comment syncs + configuration.md rewrite. S2 owns the pool_dispatch_classify deletion.'
  pattern: 'Section "Code Change Map" → rows for lib/pool.sh lines 3439-3440, 3462-3515, 3517, 3529-3536; and configuration.md lines 44-76, 8.'
  critical: 'S1 MUST NOT delete pool_dispatch_classify (lines 3012-3128) — that is S2. S1 leaves it as dead code. Deleting it here would break the S1/S2 split and steal S2's scope.'

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/system_context.md
  why: 'The "Dispatch Flow (After Fix)" diagram shows the exact post-fix flow: bin dispatcher → pool_wrapper_main → step a → [step c DELETED] → step d. And "Key Invariants Preserved" lists what NOT to touch (--help/-h/help are pool verbs; owner-passthrough at lines 580/1005/2089-2099 is UNRELATED).'
  section: 'Dispatch Flow (After Fix)' + 'Key Invariants Preserved'.

- file: lib/pool.sh
  why: THE file being edited. The exact text of every edit site is quoted in the Implementation Tasks below (verified by direct read on 2026-07-15). Line numbers cited are current as of that read.
  pattern: 'Existing comment style: PRD-section citations (§2.4 step N), GOTCHA — PREFIX blocks, rc-taxonomy comments. Match this style in all rewrites.'
  gotcha: 'Line numbers shift as edits are applied. ALWAYS match by TEXT (the quoted oldText), never by line number. The edit tool requires exact text match.'

- file: bin/agent-browser-pool
  why: 'Confirms pool verbs are caught BEFORE pool_wrapper_main (lines 20-27: status/reap/release/doctor/--help/-h/help → pool_admin_*; *) → pool_wrapper_main). This is WHY deleting step-c is safe — the bin dispatcher already split pool verbs out, so pool_wrapper_main only ever sees non-pool-verb tokens, all of which should be driving.'
  pattern: 'case "$cmd" in ... *) pool_wrapper_main "$@" ;; esac'
  gotcha: 'Do NOT touch bin/agent-browser-pool — it is already correct.'

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: 'The skill doc to rewrite. Lines 44-76 are the "Command dispatch: meta vs. driving" section (rewrite target); line 8 references pool_dispatch_classify (edit target).'
  pattern: 'Markdown ## / ### headings, numbered list, blockquote callouts. Match the existing doc voice.'
  gotcha: 'Line 8 says "reflects the shipped behavior in lib/pool.sh (pool_config_init, pool_dispatch_classify, pool_wrapper_main, pool_admin_*)" — remove pool_dispatch_classify from that list (it is dead code after S1, deleted in S2).'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                          # 4533 LOC — edit step-c (3529-3536), local decl (3517),
│                                        #             header comment (3462-3515), preflight comment (3439-3440)
├── bin/agent-browser-pool               # dispatcher (lines 20-27) — UNCHANGED, read-only reference
└── .agents/skills/agent-browser-pool/
    └── references/configuration.md      # rewrite §44-76, edit line 8
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh                                              — delete step-c, drop `class` local, sync 2 comment blocks
#   .agents/skills/agent-browser-pool/references/configuration.md — rewrite dispatch section, edit line 8
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (S1/S2 SPLIT): pool_dispatch_classify (lib/pool.sh:3012-3128) MUST be left in
# place as DEAD CODE. S2 (P1.M1.T1.S2) deletes it + its contract comment + its selftest.
# If you delete it here, you steal S2's scope and break the task split. After S1, the
# function has zero call sites (grep 'pool_dispatch_classify "\$@"' returns nothing) —
# that is the expected, intended state.

# GOTCHA: line numbers shift as edits apply. The edit tool matches by EXACT TEXT, not
# line number. The "oldText" blocks quoted in Implementation Tasks are byte-accurate
# (verified by direct read on 2026-07-15). Copy them verbatim.

# GOTCHA: the `local class N port _has_json _a` line — remove ONLY `class`, keep the rest
# (`N port _has_json _a` are all used by the driving path: N=lane, port=lease port,
# _has_json=normalize connect, _a=arg loop in strip_session). Verify with
# `grep -n '\bN\b\|\bport\b\|_has_json\|_a\b' lib/pool.sh` after the edit — all four still used.

# GOTCHA: the header comment has TWO references to step-c that must both go:
#   1. line ~3468: "#   - M6.T1.S1 pool_dispatch_classify   (step c: meta vs driving)"
#   2. lines ~3499-3501: the "GOTCHA — passthrough exec (c) passes the ORIGINAL..." block
#   3. line ~3497: "GOTCHA — TERMINAL: exits are exec (c/k) or pool_die..." — change "(c/k)" to "(k)"
# All three are in the same comment block (3462-3515). The Implementation Tasks quote exact text.

# GOTCHA: the _pool_preflight_real_bin comment (3439-3440) says "every driving call exec's
# it, and meta commands (skills/--version/…) exec it too" — the "and meta commands..." clause
# is now FALSE (meta commands no longer have a separate exec path; they go through driving).
# Rewrite to: "every driving call exec's it". Also the PRECONDITION comment (~3445-3446) says
# "it guards BOTH driving + meta" — change to "it guards the driving path".

# GOTCHA: do NOT touch test/transparency.sh or test/validate.sh. The existing tests
# test_passthrough_skills (transparency.sh:229) and test_version_passthrough (:265) WILL FAIL
# after this fix — that is EXPECTED. P1.M2.T1.S1 replaces them. If you "fix" the tests here
# you steal that subtask's scope. (You MAY note in a comment that they're known-failing, but
# do not edit them.)

# GOTCHA: shellcheck must remain 0 findings. The current code is clean (verified:
# `shellcheck -s bash lib/pool.sh` exits 0). Removing the `class="$(...)"` line removes a
# command substitution — that cannot INTRODUCE a shellcheck warning. The comment edits are
# inert to shellcheck. So the post-edit baseline should remain 0 findings. If it does not,
# you accidentally changed code beyond the quoted edits — revert and redo.

# GOTCHA (AGENTS.md §1/§2): validation is STATIC ONLY. Do NOT run the test suite or boot
# real Chrome. `bash -n` + `shellcheck` + `grep` are the only validation commands. The
# isolation-breach micro-check in Level 3 is a STATIC code-read assertion (confirm the exec
# path is gone), NOT a live Chrome run.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models, no schemas, no new types. This is line deletion + comment/doc sync.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — delete the step-c META block
  - FIND this EXACT block (currently at lines 3529-3536; match by text, not line number):
      ----------------------------------------------------------------
      # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
      # pool_dispatch_classify is rc 0 ALWAYS (no guard); prints exactly one token meta|driving.
      # Plain assignment (class declared above) → SC2155-clean + errexit-safe (classify never fails).
      class="$(pool_dispatch_classify "$@")"
      if [[ "$class" == "meta" ]]; then
          _pool_log "pool_wrapper_main: meta command → passthrough"
          exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — skills/--help/session list/etc.
      fi

      # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
      ----------------------------------------------------------------
  - REPLACE WITH (delete the step-c block; keep step-d header; the blank line between stays):
      ----------------------------------------------------------------
      # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
      ----------------------------------------------------------------
  - NOTE: this single edit removes 8 lines (the comment header + classify call + the
    if/log/exec/fi block). Step-d's comment line is KEPT (it documents the next step).
    After this edit, step a (_pool_preflight_real_bin) flows directly to step d
    (pool_owner_resolve). Verify: `grep -n 'pool_dispatch_classify "\$@"' lib/pool.sh`
    returns nothing.

Task 2: EDIT lib/pool.sh — remove `class` from the local declaration
  - FIND the EXACT line (currently line 3517):
      local class N port _has_json _a
  - REPLACE WITH:
      local N port _has_json _a
  - WHY: `class` was only used by the deleted step-c. `N port _has_json _a` are all still
    used by the driving path — do NOT remove them. (shellcheck SC2034 "unused variable"
    would fire if you left `class` in; removing it keeps the file clean.)

Task 3: EDIT lib/pool.sh — update the pool_wrapper_main header comment (3 sub-edits in one block)
  - This is ONE edit covering the comment block at lines 3462-3515. Three changes:
    (a) remove the "M6.T1.S1 pool_dispatch_classify (step c: meta vs driving)" line;
    (b) update the "GOTCHA — TERMINAL" line: "(c/k)" → "(k)";
    (c) remove the entire "GOTCHA — passthrough exec (c)" 3-line block.
  - SUB-EDIT (a) — FIND:
        #   - M6.T1.S1 pool_dispatch_classify   (step c: meta vs driving)
        #   - M6.T1.S2 pool_normalize_close/connect (step i: scope close --all, strip connect positional)
    - REPLACE WITH:
        #   - M6.T1.S2 pool_normalize_close/connect (step i: scope close --all, strip connect positional)
  - SUB-EDIT (b) — FIND:
        # GOTCHA — TERMINAL: exits are exec (c/k) or pool_die (d + error branches). NO return on success.
    - REPLACE WITH:
        # GOTCHA — TERMINAL: exits are exec (k) or pool_die (d + error branches). NO return on success.
  - SUB-EDIT (c) — FIND (the full 3-line GOTCHA block):
        # GOTCHA — passthrough exec (c) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:
        #   "exec real binary unchanged"; §2.15: "skills get core → passthrough (unaffected)"). ONLY
        #   step k (driving) uses the cleaned "${POOL_CLEAN_ARGS[@]}".
    - REPLACE WITH (nothing — delete the whole block):
        # GOTCHA — step k exec uses the cleaned "${POOL_CLEAN_ARGS[@]}" (driving path only;
        #   pool_strip_session_args + pool_force_session ran first). The original "$@" is never
        #   exec'd unchanged — every non-pool-verb token gets a scoped session.
  - WHY the replacement (not pure deletion): preserves the "CLEAN_ARGS is the exec input"
    invariant documentation that the deleted block's last sentence carried, now stated for
    the driving path only. Keeps the comment block self-consistent.

Task 4: EDIT lib/pool.sh — update _pool_preflight_real_bin comment (2 sub-edits)
  - SUB-EDIT (a) — FIND (currently line 3440):
        # pool_config_init) is a HARD runtime dependency — every driving call exec's it, and meta
        # commands (skills/--version/…) exec it too. Fail FAST with an actionable message if it is
    - REPLACE WITH:
        # pool_config_init) is a HARD runtime dependency — every driving call exec's it. Fail FAST
        # with an actionable message if it is
  - SUB-EDIT (b) — FIND (currently lines 3445-3446, the PRECONDITION comment):
        # PRECONDITION: pool_config_init has frozen $POOL_REAL_BIN (called as the tail of step a in
        #   pool_wrapper_main, BEFORE dispatch/owner/lane work — so it guards BOTH driving + meta).
    - REPLACE WITH:
        # PRECONDITION: pool_config_init has frozen $POOL_REAL_BIN (called as the tail of step a in
        #   pool_wrapper_main, BEFORE owner/lane work — so it guards the driving path).
  - WHY: the "meta" references are now stale (no meta path exists). The preflight still
    runs at step a and still guards every invocation — but now every invocation IS driving
    (pool verbs never reach pool_wrapper_main at all).

Task 5: EDIT .agents/skills/agent-browser-pool/references/configuration.md — rewrite §44-76
  - FIND the EXACT block (lines 44-76, from "## Command dispatch: meta vs. driving" through
    the end of "### Driving commands (use your lane)" list, just before "## How acquire works"):
      ----------------------------------------------------------------
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
      ----------------------------------------------------------------
  - REPLACE WITH:
      ----------------------------------------------------------------
      ## Command dispatch: pool verbs vs. driving

      The entry-point dispatcher (`bin/agent-browser-pool`) splits each invocation **before** any
      lane work. Decisions (in order, first match wins):

      1. **Pool verb** → admin function (no lane — no Chrome, no owner resolution):
         `status`, `reap`, `release [<N>|all]`, `doctor`, `--help`/`-h`/`help`. A bare
         `agent-browser-pool` (no arguments) defaults to `status`. These print pool state or
         the pool's own help and never touch a browser.
      2. **Everything else → DRIVING** → `pool_wrapper_main`: resolve the owning `pi` PID; if
         there is no `pi` ancestor, **fail-fast** (`pool_die`: "agent-browser-pool: driving
         commands require a pi ancestor... For raw browser use without pooling, call
         'agent-browser' directly."). Otherwise acquire/reuse the caller's lane, strip any
         `--session`, force `AGENT_BROWSER_SESSION=abpool-<N>`, and exec the real binary with
         the cleaned args.

      ### Driving commands (use your lane)

      Every non-pool-verb token is a driving command — it resolves the caller's owner identity,
      fails fast without a `pi` ancestor, and runs scoped to the caller's own lane. This
      includes:

      - `open <url>`, `connect <port|url>` (arg ignored — pool owns connection), `close [--all]`
      - `get <resource>` (e.g. `get cdp-url`), `screenshot`, scrape/automate commands
      - `--version`, `skills`, `dashboard`, `plugin`, `mcp`, `session list` — all driving now
        (they previously short-circuited to an unchanged exec; that path is removed for lane
        isolation: a caller-supplied `--session <X>` must never target another lane)
      - A flags-only invocation (e.g. `agent-browser-pool --json`) — driving (fails fast
        without a `pi` ancestor, same as any unrecognized verb)
      - **Any unrecognized command** (defaults to driving, so unknown verbs still get a lane)

      > There is no "meta / passthrough" class. The only commands that run without a lane are
      > the pool verbs above, caught by `bin/agent-browser-pool` before `pool_wrapper_main`.
      > See "Admin CLI" below.
      ----------------------------------------------------------------
  - WHY this structure: matches the post-fix dispatch flow exactly (bin dispatcher → pool
    verb OR pool_wrapper_main → driving). Removes the "Meta commands (passthrough)"
    subsection entirely (per contract). Preserves the driving-commands list (still accurate)
    and ADDS the formerly-meta verbs to it with a one-line rationale (so readers understand
    why `--version` is now driving, not a regression).

Task 6: EDIT configuration.md — remove pool_dispatch_classify from line 8
  - FIND (line 8):
        All of this reflects the shipped behavior in `lib/pool.sh` (`pool_config_init`,
        `pool_dispatch_classify`, `pool_wrapper_main`, `pool_admin_*`). Defaults assume the standard
  - REPLACE WITH:
        All of this reflects the shipped behavior in `lib/pool.sh` (`pool_config_init`,
        `pool_wrapper_main`, `pool_admin_*`). Defaults assume the standard
  - WHY: pool_dispatch_classify is dead code after S1 (deleted in S2); listing it as
    "shipped behavior" is misleading.

Task 7: VERIFY — static validation only (AGENTS.md §1/§2: no Chrome, no test suite)
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -s bash lib/pool.sh
      grep -n 'class="\$(pool_dispatch_classify\|class" == "meta"\|meta command → passthrough' lib/pool.sh
      grep -n 'local class N port' lib/pool.sh
      grep -n 'pool_dispatch_classify()' lib/pool.sh
      grep -nE 'meta vs\. driving|Meta commands \(passthrough' .agents/skills/agent-browser-pool/references/configuration.md
  - EXPECTED:
      bash -n           → no output (clean)
      shellcheck        → no output, exit 0 (0 findings)
      grep class=...    → no output (step-c gone)
      grep 'local class'→ no output (class removed)
      grep 'classify()' → ONE line (pool_dispatch_classify() { ... still present as dead code)
      grep config.md    → no output (section rewritten, no "meta vs driving" / "Meta commands (passthrough)")
  - FIX any failure before claiming done.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — delete a step block but preserve the next step's header comment:
#   The step-c block ends with a blank line then "# --- d. owner resolution ...".
#   KEEP step-d's header. Delete from "# --- c. dispatch ..." through the step-c "fi",
#   plus the trailing blank line, so step-d's header follows step-a's last line cleanly.

# Pattern B — edit-tool exact-match discipline:
#   Every oldText below is byte-accurate (verified by direct read). Copy verbatim. If an
#   edit fails to match, DO NOT "approximate" — re-read the file at the cited region
#   (the line number may have drifted from a prior edit in this same session) and use the
#   current exact text. The edit tool matches against the ORIGINAL file for each call, so
#   if you batch multiple edits to nearby regions, do them as SEPARATE edit calls or ensure
#   non-overlapping oldText regions.

# Pattern C — leave intentional dead code for a sibling subtask:
#   pool_dispatch_classify (lib/pool.sh:3012-3128) has ZERO call sites after Task 1.
#   shellcheck will NOT flag it (it's a defined function, not an unused variable — SC2034
#   applies to vars, not functions). Leave it. S2 (P1.M1.T1.S2) deletes it + its contract
#   comment + the selftest_dispatch_classify_cases test body.
```

### Integration Points

```yaml
CODE (in-place edits in 2 files, no new files):
  - lib/pool.sh:3529-3536       step-c META block (DELETE 8 lines)
  - lib/pool.sh:3517            local decl: drop `class` (1 line edit)
  - lib/pool.sh:~3468           header comment: drop classify line (1 line edit)
  - lib/pool.sh:~3497           header comment: "(c/k)" → "(k)" (1 line edit)
  - lib/pool.sh:~3499-3501      header comment: drop passthrough-exec GOTCHA (3-line edit)
  - lib/pool.sh:~3440           preflight comment: drop "meta commands exec it too" (1-line edit)
  - lib/pool.sh:~3445-3446      preflight comment: "BOTH driving + meta" → "the driving path" (1-line edit)
  - .agents/.../configuration.md:44-76  rewrite dispatch section (block edit)
  - .agents/.../configuration.md:8      drop pool_dispatch_classify from list (1-line edit)

DO NOT TOUCH:
  - lib/pool.sh:3012-3128       pool_dispatch_classify function (S2 deletes it)
  - bin/agent-browser-pool      dispatcher (already correct)
  - test/transparency.sh        tests (P1.M2.T1.S1 updates them; they WILL fail after S1 — expected)
  - test/validate.sh            selftest_dispatch_classify_cases (S2 removes it)
  - README.md                   (P1.M3.T1.S1 syncs cross-cutting docs in Mode B)
  - lib/pool.sh:580,1005,2089-2099  owner-passthrough (POOL_OWNER_PID==0) — UNRELATED to meta dispatch

CONFIG: none (no env vars change).
ROUTES: none.
DATABASE: none.
```

## Validation Loop

> **AGENTS.md §1/§2 compliance**: ALL validation here is STATIC. `bash -n` + `shellcheck`
> + `grep` only. Do NOT run the test suite (it will fail on the not-yet-updated
> transparency.sh tests — that's P1.M2.T1.S1's concern). Do NOT boot Chrome.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                       # parse check. MUST be clean (no output).
shellcheck -s bash lib/pool.sh            # MUST exit 0 with 0 findings (matches project gate).
# Expected: zero output from both, shellcheck exit 0.
# The current (pre-edit) baseline is already clean (verified). The edits only DELETE code
# and sync comments, so they CANNOT introduce a shellcheck warning. If shellcheck fires,
# you changed code beyond the quoted edits — revert and redo.
```

### Level 2: Unit Tests (Component Validation)

```bash
# There is NO new unit test in this subtask. The existing pure-function micro-check pattern
# (source lib/pool.sh, call pool_wrapper_main with fake args) is how S1 is verified, but
# running it requires the full pool_config_init/pool_state_init dance + a fake real-binary.
# That live micro-check is in Level 3 (static) and Level 4 (isolated, optional).
#
# The test SUITE (test/validate.sh, test/transparency.sh) is INTENTIONALLY NOT RUN here —
# test/transparency.sh's test_passthrough_skills + test_version_passthrough WILL FAIL after
# this fix (they assert the old meta-passthrough behavior). P1.M2.T1.S1 replaces them.
# Running the suite now would produce known failures that are out of S1's scope.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Confirm the step-c execution path is GONE (static grep — the core contract):
grep -n 'class="$(pool_dispatch_classify' lib/pool.sh
# Expected: NO output (the assignment is deleted).
grep -n 'class" == "meta"' lib/pool.sh
# Expected: NO output (the if-block is deleted).
grep -n 'meta command → passthrough' lib/pool.sh
# Expected: NO output (the _pool_log line is deleted).

# 3b. Confirm `class` local is gone but the other 4 locals remain:
grep -n 'local class N port' lib/pool.sh     # Expected: NO output
grep -n 'local N port _has_json _a' lib/pool.sh  # Expected: ONE line (the edited decl)

# 3c. Confirm pool_dispatch_classify is STILL PRESENT (dead code — S2's job):
grep -n 'pool_dispatch_classify()' lib/pool.sh
# Expected: ONE line (~3070) — the function definition. (If absent, you accidentally deleted
#           it — that's S2's scope; revert.)

# 3d. Confirm pool_dispatch_classify has ZERO call sites (it is now dead code):
grep -n 'pool_dispatch_classify "\$@"' lib/pool.sh
# Expected: NO output (the only call site was in the deleted step-c).

# 3e. Confirm the docs are synced:
grep -nE 'meta vs\. driving|Meta commands \(passthrough' .agents/skills/agent-browser-pool/references/configuration.md
# Expected: NO output.
grep -n 'pool verbs vs driving\|Command dispatch: pool verbs' .agents/skills/agent-browser-pool/references/configuration.md
# Expected: ONE match (the new section heading).
grep -n 'pool_dispatch_classify' .agents/skills/agent-browser-pool/references/configuration.md
# Expected: NO output (removed from line 8; the rewrite doesn't mention it).

# 3f. Confirm step a still flows to step d (no orphaned/dangling code between them):
sed -n '/_pool_preflight_real_bin/,/pool_owner_resolve/p' lib/pool.sh | head -20
# Expected: _pool_preflight_real_bin call → blank line → "# --- d. owner resolution" →
# pool_owner_resolve call. NO step-c lines in between.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. STATIC isolation-breach assertion (the motivating bug — verified by code reading, NOT
#     a live Chrome run per AGENTS.md). Confirm there is NO code path that exec's the real
#     binary with the ORIGINAL "$@" unchanged:
grep -n 'exec "$POOL_REAL_BIN" "$@"' lib/pool.sh
# Expected: NO output. The only remaining exec is 'exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"'
#           (the driving path, step k), which uses the CLEANED args.
grep -n 'exec "$POOL_REAL_BIN"' lib/pool.sh
# Expected: ONE line — the step-k exec with "${POOL_CLEAN_ARGS[@]}". (Confirm it is the
#           cleaned-args form, not "$@".)

# 4b. (OPTIONAL, isolated, timeout-bounded — ONLY if you want live confirmation; safe to SKIP
#     since 4a is definitive). In a throwaway temp tree, confirm --version now fail-fasts
#     instead of passthrough. This does NOT boot Chrome (it dies at owner resolution):
timeout 10 bash -c '
  set -euo pipefail
  ROOT=$(mktemp -d); trap "rm -rf $ROOT" EXIT
  export HOME=$ROOT/home; mkdir -p $HOME/.local/bin
  printf "#!/usr/bin/env bash\nexit 0\n" > $HOME/.local/bin/agent-browser; chmod +x $HOME/.local/bin/agent-browser
  export AGENT_BROWSER_POOL_STATE=$ROOT/state AGENT_CHROME_EPHEMERAL_ROOT=$ROOT/active \
         AGENT_CHROME_MASTER=$ROOT/master AGENT_BROWSER_REAL=$HOME/.local/bin/agent-browser
  unset AGENT_BROWSER_POOL_OWNER_PID
  # Source the lib + call pool_wrapper_main with --version (a formerly-meta token):
  source lib/pool.sh
  pool_config_init; pool_state_init
  pool_wrapper_main --version 2>&1 || echo "rc=$?"
' 2>&1 | tail -5
# Expected: the pool_die fail-fast message ("driving commands require a pi ancestor...")
#           and rc=1. BEFORE this fix it would have exec'd the real binary (rc=0).
# If you skip this, 4a is sufficient (the exec path is statically proven gone).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck -s bash lib/pool.sh` exits 0, 0 findings.
- [ ] Level 3 snippet 3a: the three step-c `grep`s return nothing.
- [ ] Level 3 snippet 3b: `class` gone, other 4 locals retained.
- [ ] Level 3 snippet 3c: `pool_dispatch_classify()` still present (dead code).
- [ ] Level 3 snippet 3d: zero call sites for `pool_dispatch_classify "$@"`.
- [ ] Level 4 snippet 4a: no `exec "$POOL_REAL_BIN" "$@"` (only the cleaned-args exec remains).

### Feature Validation

- [ ] Step-c block deleted (8 lines gone).
- [ ] `local class N port ...` → `local N port ...`.
- [ ] Header comment: classify line gone, "(c/k)"→"(k)", passthrough-exec GOTCHA replaced.
- [ ] Preflight comment: "meta commands exec it too" gone; "BOTH driving + meta" → "the driving path".
- [ ] `configuration.md`: "pool verbs vs driving" section; no "Meta commands (passthrough)".
- [ ] `configuration.md` line 8: `pool_dispatch_classify` removed from the function list.
- [ ] `pool_dispatch_classify` function body untouched (S2's scope).

### Code Quality Validation

- [ ] Edit-tool oldText blocks matched byte-for-byte (no approximations).
- [ ] No code beyond the quoted edits was touched (diff is exactly: 8 lines deleted + 1 local edit + ~6 comment-line edits + 1 doc-block rewrite + 1 doc-line edit).
- [ ] shellcheck baseline preserved (was 0 findings, still 0 findings).
- [ ] No scope creep into S2 (function deletion), P1.M2.T1.S1 (test updates), or P1.M3.T1.S1 (README).
- [ ] Comment style matches existing (PRD §-citations, GOTCHA — PREFIX, rc-taxonomy).

### Documentation & Deployment

- [ ] `configuration.md` describes the post-fix dispatch model accurately.
- [ ] No new env vars; no config changes; no path changes.
- [ ] Mode A satisfied: the skill doc (`configuration.md`) rode with the code in this subtask.
- [ ] README.md NOT touched (it is Mode B — P1.M3.T1.S1; its META references are cross-cutting and sync'd separately).

---

## Anti-Patterns to Avoid

- ❌ Don't delete `pool_dispatch_classify` (lines 3012–3128) — that's S2 (`P1.M1.T1.S2`). Leave it as dead code. Deleting it here steals S2's scope and breaks the task split.
- ❌ Don't touch `test/transparency.sh` or `test/validate.sh` — the existing passthrough tests WILL fail after S1 (expected); `P1.M2.T1.S1` replaces them. "Fixing" them here steals that subtask's scope.
- ❌ Don't touch `README.md` — it's Mode B cross-cutting docs (`P1.M3.T1.S1`).
- ❌ Don't touch `bin/agent-browser-pool` — the dispatcher is already correct.
- ❌ Don't touch the owner-passthrough references (lines 580, 1005, 2089–2099, `POOL_OWNER_PID==0`) — that concept is UNRELATED to meta dispatch.
- ❌ Don't run the test suite or boot Chrome (AGENTS.md §1/§2) — validation is `bash -n` + `shellcheck` + `grep` only.
- ❌ Don't match edit oldText by line number — line numbers drift as edits apply. Match by the exact quoted text; re-read the region if a match fails.
- ❌ Don't leave stale "meta"/"step c"/"passthrough" references in the comments you touch — every edited comment block must be internally consistent with the post-fix model.
- ❌ Don't change the driving path (steps d–k) — only step-c and its comment/doc consequences are in scope.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: pure mechanical deletion + comment/doc sync on a fully-documented codebase. Every edit site is quoted byte-for-byte (verified by direct read on 2026-07-15), the replacement text is given verbatim, and the change only REMOVES code (cannot introduce new behavior or new shellcheck warnings — the baseline is already clean). The S1/S2 boundary is crisp and restated in multiple places. The -1 reflects residual risk in Task 3's three sub-edits within the header comment block — if the implementer edits them as overlapping regions in one `edit` call, the tool may reject; the mitigation (separate non-overlapping oldText regions, or sequential calls) is documented in Pattern C. Level 3 snippet 3f catches any dangling/broken step-a→step-d flow immediately.
