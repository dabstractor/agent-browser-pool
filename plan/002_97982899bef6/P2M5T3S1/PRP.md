# PRP — P2.M5.T3.S1: Update comments in concurrency.sh & release_reaper.sh

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`).
**Work item**: P2.M5.T3.S1 (1 point) — milestone P2.M5 (Test Framework Updates), task T3.
**Dependency / starting state**: Builds on the **SHIPPED POST-P2.M2 tree** (`bin/agent-browser`
PATH-shadowing shim is DELETED; `bin/agent-browser-pool` is the sole entry point) + the
**P2.M5.T1.S1 validate.sh contract** (ABPOOL_ADMIN defined; ABPOOL_WRAPPER gone) + the
**P2.M5.T2.S1 transparency.sh contract** (in flight — comment-only sibling; no overlap with this
item's two files). Both target files already PASS `bash -n` + `shellcheck -s bash` (baseline =
only 2× SC1091 infos each); their test LOGIC is correct and unchanged by this item.
**This item edits exactly TWO files: `test/concurrency.sh` + `test/release_reaper.sh` — comments
only. ZERO functional changes.**

---

## Goal

**Feature Goal**: Make the prose comments in `test/concurrency.sh` and `test/release_reaper.sh`
consistent with the shipped **no-shadow explicit-invocation** model (PRD §2.17): every stale
reference to "the wrapper (bin/agent-browser → pool_wrapper_main)" — i.e. the DELETED
`bin/agent-browser` PATH-shadowing shim — becomes accurate vocabulary: "the pool entry point
(`bin/agent-browser-pool` → `pool_wrapper_main`)" or the real function name `pool_wrapper_main`.
This is a **language/comment-only** task: no test logic, no assertions, no calls change.

**Deliverable**: Two edited test files where (1) no prose comment says "the wrapper",
"wrapper-driven", "the wrapper exec's", or "the wrapper's …" anymore; (2) the **real function
symbol `pool_wrapper_main`** and its **direct call** in `release_reaper.sh` test e are PRESERVED
(they are real code, not stale comments); (3) every reference to "the real agent-browser" /
`$POOL_REAL_BIN` / `~/.local/bin/agent-browser` (the REAL Vercel CLI) is PRESERVED unchanged
(those were already correct); (4) the `agent-browser-pool release/reap` admin-verb references
are PRESERVED (already correct); (5) both files still pass `bash -n` + `shellcheck -s bash` with
ONLY the pre-existing SC1091 infos.

**Success Definition**:
- `grep -cE 'wrapper' test/concurrency.sh` → **0** (this file has no `pool_wrapper_main` symbol).
- `bash -c "grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main'"` → **empty**
  (every remaining `wrapper` is the `pool_wrapper_main` symbol — the real function; NOT prose).
- `bash -n test/concurrency.sh test/release_reaper.sh` → exit 0 (no syntax regression).
- `shellcheck -s bash test/concurrency.sh` and `shellcheck -s bash test/release_reaper.sh` →
  exit 1 with **ONLY** the 2× SC1091 infos each (no NEW codes — comments-only can't add any).
- PRESERVED (count non-decreasing vs current): `grep -c 'real agent-browser\|POOL_REAL_BIN'`
  in both files; `grep -c 'agent-browser-pool'` in release_reaper.sh.
- `git status --short` → only `test/concurrency.sh` + `test/release_reaper.sh` modified.

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21) — "There is **no PATH shadowing** … `agent-browser-pool`
  (the sole entry point)". The deleted `bin/agent-browser` shim no longer exists; comments that
  name it ("the wrapper (bin/agent-browser → pool_wrapper_main)") describe a component that was
  REMOVED in P2.M2.T2.S1. PRD §2.18 (h3.22) — the testing contract these two files implement.
- **Who it helps**: Future readers/maintainers of the concurrency + release/reaper suites. The
  current comments point at a binary (`bin/agent-browser`) that isn't there, muddying the
  "why direct lib calls" rationale. Accurate comments keep the (subtle) test-boundary reasoning
  — "driving via the pool entry point exec's into the real agent-browser and may not exit, so we
  call the lib directly" — trustworthy.
- **Scope cohesion**: Item T3.S1, the LAST test-framework sub-task of milestone P2.M5. Its ONLY
  job is the comment cleanup in these two files. It does NOT touch `test/transparency.sh`
  (P2.M5.T2.S1 — the in-flight sibling, a much larger rewrite), `test/validate.sh`
  (P2.M5.T1.S1 — shipped), `lib/pool.sh`, `bin/*`, `install.sh`, or any `*.md` (later milestones).
- **Why NOT functional**: The item contract (point 2/3) is explicit — "No functional changes
  needed. The test logic is correct. Only language/comments are stale." Renaming the real
  `pool_wrapper_main` symbol or its call would be a forbidden functional change.

---

## What

**User-visible behavior**: None. These are test-harness files; their COMMENTS are the deliverable.
The tests themselves (assertions, lib calls, the `pool_wrapper_main close` call in test e, the
`$ABPOOL_ADMIN release/reap` calls) are byte-for-byte unchanged in their executable logic.

**Unchanged (explicitly preserved — do NOT edit)**:
- `lib/pool.sh`, `bin/agent-browser-pool`, `install.sh` — SHIPPED (read-only).
- `test/validate.sh` (T1.S1), `test/transparency.sh` (T2.S1) — owned by sibling/completed items.
- All `*.md`, `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — read-only.
- In the two target files themselves:
  - Every **executable line** (every assertion, every `pool_*` / `$ABPOOL_ADMIN` / `$POOL_REAL_BIN`
    call, the `( pool_wrapper_main close )` call at release_reaper.sh:395) — UNCHANGED.
  - Every `pool_wrapper_main` **symbol** reference (release_reaper.sh L365, L368, L376, L395) —
    UNCHANGED (real symbol).
  - Every "real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser` reference —
    UNCHANGED (the REAL Vercel CLI; correct per item contract point 1).
  - Every `agent-browser-pool release/reap` admin-verb reference — UNCHANGED (already correct).

### Success Criteria

- [ ] ZERO prose "wrapper" in concurrency.sh (`grep -cE 'wrapper'` → 0).
- [ ] ZERO prose "wrapper" in release_reaper.sh (`grep wrapper | grep -v pool_wrapper_main` → empty).
- [ ] `pool_wrapper_main` symbol + its direct call in release_reaper.sh test e PRESERVED.
- [ ] All "real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser` refs PRESERVED.
- [ ] All `agent-browser-pool release/reap` admin-verb refs PRESERVED.
- [ ] `bash -n` → 0 on both files; `shellcheck -s bash` → only the 2× SC1091 infos on both.
- [ ] Only `test/concurrency.sh` + `test/release_reaper.sh` modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes.** Every edit is given **verbatim** below (C1–C2 for concurrency.sh, R1–R5 for
release_reaper.sh: exact old → new blocks, copy-pasteable into `edit`). The one non-obvious trap —
that `pool_wrapper_main` is a REAL FUNCTION (lib/pool.sh:3619) that test e CALLS directly, so its
symbol + call must NOT be renamed even though it contains the substring "wrapper" — is spelled out
in §Known Gotchas with the exact grep that distinguishes "prose wrapper" (update) from "symbol
wrapper" (keep). The other trap — that "the real agent-browser" / `$POOL_REAL_BIN` /
`~/.local/bin/agent-browser` are the REAL Vercel CLI and are ALREADY correct (must NOT change) —
is likewise pinned.

### Documentation & References

```yaml
# MUST READ — the sole entry point whose existence makes "bin/agent-browser" comments stale
- file: bin/agent-browser-pool
  why: "Its `case` (lines 20-26): status|reap|release|doctor|--help|-h|help → pool_admin_*;
        *) pool_wrapper_main \"$@\". So driving commands route THROUGH pool_wrapper_main. The
        OLD bin/agent-browser shim (the 'wrapper') is GONE (P2.M2.T2.S1 deleted it)."
  critical: "agent-browser-pool is the SOLE entry point (PRD §2.17). Comments must say
             'bin/agent-browser-pool' (or pool_wrapper_main, the function), NOT 'bin/agent-browser'."

- file: lib/pool.sh   pool_wrapper_main  (line 3619)
  why: "pool_wrapper_main is a REAL FUNCTION (the driving-command dispatcher), called by the bin's
        *) arm AND called DIRECTLY by release_reaper.sh test e (line 395: ( pool_wrapper_main close )).
        For driving commands it TERMINATES via `exec \"$POOL_REAL_BIN\" …`."
  critical: "pool_wrapper_main is a SYMBOL, not 'the wrapper' prose. Its name CONTAINS 'wrapper'.
             Do NOT rename it. The gate for release_reaper.sh is grep 'wrapper' MINUS 'pool_wrapper_main'."

- contract: plan/002_97982899bef6/architecture/gap_analysis.md   §10 + §11
  why: "§10 (concurrency.sh): line-12 comment 'the wrapper (bin/agent-browser → pool_wrapper_main)'
        → update; no functional changes. §11 (release_reaper.sh): comments referencing 'wrapper' →
        update; no functional changes (already uses agent-browser-pool release/reap)."
  critical: "Both sections say COMMENT UPDATES ONLY. The line numbers in the item_description
             (~12, ~17, ~20) are APPROXIMATE — match on the verbatim oldText below, not line numbers."

- prd: PRD §2.17 (h3.21 — sole entry point, no PATH shadowing), §2.18 (h3.22 — testing & validation)
  why: "§2.17 establishes the vocabulary: agent-browser-pool is the sole entry point; the deleted
        bin/agent-browser shim was the PATH-shadowing 'wrapper'. §2.18 is the contract these two
        test files implement (N-distinct-lanes concurrency; release/reap/crash/close semantics)."

- file: test/concurrency.sh   (CURRENT — EDITED by C1 + C2)
  why: "440 lines. Drives the REAL acquire+boot path via DIRECT lib calls (pool_acquire_locked,
        pool_boot_lane) in N parallel subshells. The header 'HOW IT WORKS' + the _concurrency_run_one_lane
        'WHY DIRECT LIB CALLS' comments are the 2 stale 'wrapper' sites."
  critical: "concurrency.sh has NO pool_wrapper_main symbol — so its gate is grep -c wrapper → 0
             (cleaner than release_reaper.sh). Its real-agent-browser / $POOL_REAL_BIN refs (L14,55-56,
             129,131,135-136,159) are the REAL Vercel CLI → KEEP."

- file: test/release_reaper.sh   (CURRENT — EDITED by R1 + R2 + R3 + R4 + R5)
  why: "474 lines. Drives lib functions DIRECTLY; invokes admin verbs via $ABPOOL_ADMIN
        (release/reap) and close via $POOL_REAL_BIN. test e (test_close_then_rebind) CALLS
        pool_wrapper_main directly (L395) — that call + its symbol refs are REAL CODE."
  critical: "release_reaper.sh HAS the pool_wrapper_main symbol → its gate is
             grep 'wrapper' | grep -v 'pool_wrapper_main' → empty (NOT grep -c wrapper → 0).
             Setting grep -c wrapper → 0 would force renaming the real symbol = forbidden functional change."
```

### Current codebase tree (relevant slice)

```bash
test/
├── concurrency.sh    # EDITED by this item (C1+C2 — 2 comment blocks). The deliverable.
├── release_reaper.sh # EDITED by this item (R1..R5 — 5 comment/string blocks). The deliverable.
├── transparency.sh   # UNTOUCHED (P2.M5.T2.S1 — in-flight sibling).
└── validate.sh       # UNTOUCHED (P2.M5.T1.S1 — shipped; defines ABPOOL_ADMIN).
bin/
├── agent-browser-pool # UNTOUCHED (P2.M2 done — sole entry point).
└── .gitkeep           # UNTOUCHED
lib/pool.sh            # UNTOUCHED (defines pool_wrapper_main — the real symbol referenced by test e).
PRD.md                 # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
test/
├── concurrency.sh    # EDITED: 2 comment blocks rewritten (wrapper→pool entry point vocabulary).
└── release_reaper.sh # EDITED: 5 comment/string blocks rewritten (wrapper→pool entry point / pool_wrapper_main).
# No new files. No deletions. No other modifications. No functional/executable-line changes.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL — pool_wrapper_main is a REAL FUNCTION, not prose. lib/pool.sh:3619 defines it; the bin's
#   `*)` arm calls it; AND release_reaper.sh test e calls it DIRECTLY (line 395: ( pool_wrapper_main close )).
#   Its NAME contains the substring "wrapper". So `grep -c wrapper release_reaper.sh` is NOT a valid
#   "all stale prose gone" gate — it would still count the symbol. The CORRECT gate is:
#     grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main'   # must be EMPTY
#   (concurrency.sh has NO pool_wrapper_main symbol, so there grep -c wrapper → 0 IS valid.)
#   NEVER rename the pool_wrapper_main symbol or its call — that is a functional change (forbidden).

# CRITICAL — "the real agent-browser" / $POOL_REAL_BIN / ~/.local/bin/agent-browser are the REAL
#   Vercel `agent-browser` CLI binary — they are ALREADY CORRECT (item contract point 1). Do NOT
#   "fix" them to agent-browser-pool. Only PROSE that says "the wrapper (bin/agent-browser → ...)"
#   is stale (that bin/agent-browser was the DELETED PATH-shadowing shim, P2.M2.T2.S1).

# CRITICAL — the line numbers in the item_description (~12, ~17, ~20) are APPROXIMATE anchors.
#   The verbatim oldText blocks below (C1,C2,R1-R5) are the source of truth — match on TEXT, not
#   line numbers (comments drift; the edit tool matches exact text anyway).

# CRITICAL (shellcheck baseline): BOTH files exit 1 TODAY with ONLY 2× SC1091 each (the
#   `# shellcheck source=./validate.sh` infos). rc=1 is EXPECTED, not a failure. The gate is
#   "no NEW codes" — and since this item is comments-only, no new code CAN appear. Assert it anyway.

# CRITICAL (AGENTS.md §1/§6): validation is STATIC ONLY — bash -n + shellcheck + grep + git status.
#   Do NOT run `bash test/concurrency.sh` or `bash test/release_reaper.sh`: both boot REAL headless
#   Chrome + spawn sim-owners (sandbox-wedge risk). They are OPTIONAL Level-3 checks in a fully
#   isolated container ONLY — never a gate, never in the shared sandbox.

# GOTCHA — R4 edits an ASSERTION MESSAGE STRING ("S1: close (via wrapper) marked ..."), not a
#   comment. That is fine: the string is human-readable prose (assert label), not executable logic;
#   changing "via wrapper" → "via pool_wrapper_main" does not alter any assertion's pass/fail
#   behavior (assert_eq compares $actual vs $expected, not the label). It IS in scope (item: any
#   comment referencing 'wrapper' → update; an assertion label is comment-like prose).

# GOTCHA — keep the nuance that test e calls pool_wrapper_main DIRECTLY (sourced function), NOT via
#   the agent-browser-pool binary. So test e comments should say "pool_wrapper_main" (the function),
#   while header/HOW-IT-WORKS comments about the entry point should say "the pool entry point
#   (bin/agent-browser-pool)". Both are accurate; they name different things.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is 7 surgical comment edits across 2 bash test files. The
semantic edits (C1–C2, R1–R5) are given **verbatim** below (exact old → new, copy-pasteable into
`edit`). No executable line changes.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ + anchor (context — no writes)
  - READ: test/concurrency.sh lines 11-16 (header HOW IT WORKS) + 157-160 (_concurrency_run_one_lane WHY).
  - READ: test/release_reaper.sh lines 14-21 (header HOW IT WORKS) + 331-335 (test d close) +
          363-406 (test e header + body + the pool_wrapper_main close call at 395).
  - CONFIRM (read-only, already verified in research): bin/ has ONLY agent-browser-pool (no
           bin/agent-browser shim — P2.M2.T2.S1 deleted it); pool_wrapper_main is a real fn at
           lib/pool.sh:3619; both files pass bash -n + shellcheck (only SC1091).
  - WHY: anchor the verbatim edits + confirm the stale "wrapper" prose is the ONLY thing changing.

Task 2: EDIT test/concurrency.sh — apply C1 + C2 (2 edits)
  - C1: rewrite the header "HOW IT WORKS" 2-line block (wrapper→pool entry point; wrapper-driven→pool-driven).
  - C2: rewrite the _concurrency_run_one_lane "WHY DIRECT LIB CALLS" line (not the wrapper→not via
        the pool entry point; the wrapper exec's→pool_wrapper_main exec's).
  - VERIFY after: `grep -cE 'wrapper' test/concurrency.sh` → 0.
  - WHY: gap_analysis §10 + item point 3a. concurrency.sh has NO pool_wrapper_main symbol → clean 0.

Task 3: EDIT test/release_reaper.sh — apply R1, R2, R3, R4, R5 (5 edits)
  - R1: rewrite the header "HOW IT WORKS" 6-line block (NOT the wrapper→NOT via pool entry point;
        keep "real agent-browser" + add "$POOL_REAL_BIN"; wrapper-driven→pool-driven; the wrapper
        exec's→pool_wrapper_main exec's; the wrapper's terminal exec→pool_wrapper_main's terminal exec).
  - R2: rewrite test d close 3-line comment (The wrapper exec's→pool_wrapper_main exec's; the
        wrapper's terminal exec→pool_wrapper_main's terminal exec; keep "rc is 0 on agent-browser 0.28.0").
  - R3: rewrite test e 2-line comment (THROUGH the wrapper (pool_wrapper_main)→THROUGH pool_wrapper_main;
        The wrapper ends in exec→pool_wrapper_main ends in exec).
  - R4: rewrite test e assertion STRING (close (via wrapper)→close (via pool_wrapper_main)).
  - R5: rewrite test e 1-line comment (the wrapper's step h→pool_wrapper_main's step h).
  - VERIFY after: `grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main'` → EMPTY.
  - WHY: gap_analysis §11 + item point 3b. PRESERVES every pool_wrapper_main symbol + its L395 call.

Task 4: STATIC VALIDATION (AGENTS.md §1: static only — NO execution)
  - RUN: bash -n test/concurrency.sh test/release_reaper.sh  (expect exit 0).
  - RUN: shellcheck -s bash test/concurrency.sh ; shellcheck -s bash test/release_reaper.sh
        (expect rc=1 + ONLY SC1091 each; assert NO new codes — see §Validation Loop L1).
  - RUN: the grep assertions in §Validation Loop Level 1 (prose wrapper→0; symbol/correct-refs preserved).
  - RUN: git status --short  (expect ONLY test/concurrency.sh + test/release_reaper.sh modified).
  - WHY: contract step 4 (OUTPUT) + AGENTS.md §1/§6. No Chrome, no daemons, no test-suite run.
  - BUCKET: required.
```

#### Edit Targets (verbatim old → new — copy-pasteable into `edit`)

> All `oldText` blocks are verified UNIQUE in their respective files. concurrency.sh edits (C1–C2)
> can be ONE `edit` call (2 `edits[]` entries); release_reaper.sh edits (R1–R5) can be ONE `edit`
> call (5 `edits[]` entries) — all oldText blocks are disjoint + unique. Line numbers are current
> anchors (the edit matches on exact text, so drift is irrelevant).

---

**C1 — rewrite concurrency.sh header "HOW IT WORKS" (current lines 12-13):**

oldText:
```
# HOW IT WORKS (the concurrency seam): the wrapper (bin/agent-browser → pool_wrapper_main)
# TERMINATES via `exec "$POOL_REAL_BIN" …` — a wrapper-driven `open` test would hang on
```
newText:
```
# HOW IT WORKS (the concurrency seam): the pool entry point (bin/agent-browser-pool →
# pool_wrapper_main) TERMINATES via `exec "$POOL_REAL_BIN" …` — a pool-driven `open` test would hang on
```
*("the wrapper (bin/agent-browser → pool_wrapper_main)" → "the pool entry point (bin/agent-browser-pool
→ pool_wrapper_main)"; "a wrapper-driven `open` test" → "a pool-driven `open` test". The next line's
"the real agent-browser may not exit for `open`" is PRESERVED — it's the REAL Vercel CLI.)*

---

**C2 — rewrite concurrency.sh `_concurrency_run_one_lane` "WHY DIRECT LIB CALLS" (current line 158):**

oldText:
```
# WHY DIRECT LIB CALLS (not the wrapper): see the header comment — the wrapper exec's into
```
newText:
```
# WHY DIRECT LIB CALLS (not via the pool entry point): see the header comment — pool_wrapper_main exec's into
```
*("not the wrapper" → "not via the pool entry point"; "the wrapper exec's into" → "pool_wrapper_main
exec's into" — it IS the function. The next line "the real agent-browser and may not exit" is PRESERVED.)*

---

**R1 — rewrite release_reaper.sh header "HOW IT WORKS" (current lines 16-21):**

oldText:
```
# pool_acquire_locked → pool_boot_lane) — NOT the wrapper (which `exec`s into the real
# agent-browser for driving commands and may not exit → a wrapper-driven test would hang).
# The admin `release`/`reap` are invoked as SUBPROCESSES (`"$ABPOOL_ADMIN" …`, pool_die-safe).
# `close` is invoked as the SAME command the wrapper exec's (`"$POOL_REAL_BIN" --session
# abpool-N close`) — run directly (avoids the wrapper's terminal exec for this non-driving
# command).
```
newText:
```
# pool_acquire_locked → pool_boot_lane) — NOT via the pool entry point (agent-browser-pool),
# which for driving commands `exec`s into the real agent-browser ($POOL_REAL_BIN) and may not
# exit → a pool-driven test would hang). The admin `release`/`reap` are invoked as SUBPROCESSES
# (`"$ABPOOL_ADMIN" …`, pool_die-safe). `close` is invoked as the SAME command pool_wrapper_main
# exec's (`"$POOL_REAL_BIN" --session abpool-N close`) — run directly (avoids pool_wrapper_main's
# terminal exec for this non-driving command).
```
*("NOT the wrapper" → "NOT via the pool entry point (agent-browser-pool)"; KEEPS "the real
agent-browser" (REAL CLI) + adds "($POOL_REAL_BIN)"; "a wrapper-driven test" → "a pool-driven test";
"the wrapper exec's" → "pool_wrapper_main exec's" (the function); "the wrapper's terminal exec" →
"pool_wrapper_main's terminal exec". Satisfies item line-17 instruction: "agent-browser-pool for
driving commands" now appears as "agent-browser-pool), which for driving commands".)*

---

**R2 — rewrite release_reaper.sh test d close comment (current lines 331-333):**

oldText:
```
    # (2) THE CONTRACT: run `close` (disconnect-only). The wrapper exec's
    #     `"$POOL_REAL_BIN" --session abpool-N close`; we invoke the SAME command DIRECTLY (avoids
    #     the wrapper's terminal exec for this non-driving command). rc is 0 on agent-browser
```
newText:
```
    # (2) THE CONTRACT: run `close` (disconnect-only). pool_wrapper_main exec's
    #     `"$POOL_REAL_BIN" --session abpool-N close`; we invoke the SAME command DIRECTLY (avoids
    #     pool_wrapper_main's terminal exec for this non-driving command). rc is 0 on agent-browser
```
*("The wrapper exec's" → "pool_wrapper_main exec's"; "the wrapper's terminal exec" →
"pool_wrapper_main's terminal exec". KEEPS "rc is 0 on agent-browser 0.28.0" — that names the REAL
CLI's version, correct.)*

---

**R3 — rewrite release_reaper.sh test e body comment (current lines 390-391):**

oldText:
```
    # (2) THE CONTRACT (S1): run `close` THROUGH the wrapper (pool_wrapper_main) so S1's
    #     close→connected=false block fires end-to-end. The wrapper ends in exec → run it
```
newText:
```
    # (2) THE CONTRACT (S1): run `close` THROUGH pool_wrapper_main so S1's
    #     close→connected=false block fires end-to-end. pool_wrapper_main ends in exec → run it
```
*("THROUGH the wrapper (pool_wrapper_main)" → "THROUGH pool_wrapper_main" (drop the redundant
"the wrapper"; test e CALLS this function at L395); "The wrapper ends in exec" → "pool_wrapper_main
ends in exec".)*

---

**R4 — rewrite release_reaper.sh test e assertion STRING (current line 400):**

oldText:
```
        "S1: close (via wrapper) marked lane $N connected=false" || return 1
```
newText:
```
        "S1: close (via pool_wrapper_main) marked lane $N connected=false" || return 1
```
*(This is an `assert_eq` LABEL string (human-readable prose), not executable logic — changing
"via wrapper" → "via pool_wrapper_main" does NOT alter pass/fail (assert_eq compares its 1st two
args, not the label). In scope per item: "any comment referencing 'wrapper' → update".)*

---

**R5 — rewrite release_reaper.sh test e body comment (current line 405):**

oldText:
```
    #       the wrapper's step h runs on the agent's NEXT driving command.)
```
newText:
```
    #       pool_wrapper_main's step h runs on the agent's NEXT driving command.)
```
*("the wrapper's step h" → "pool_wrapper_main's step h" — the step-h self-heal runs inside the
function test e calls.)*

---

### Implementation Patterns & Key Details

```bash
# PATTERN — three DIFFERENT things all legitimately contain "agent-browser" / "wrapper"; do not
#   conflate them:
#   (1) bin/agent-browser-pool   — the SOLE entry point binary (NEW model). Comments that name the
#       entry point say THIS.
#   (2) pool_wrapper_main        — the REAL driving-dispatcher FUNCTION (lib/pool.sh:3619), called by
#       the bin's *) arm AND directly by release_reaper.sh test e. Comments about the function say THIS.
#       Its name contains "wrapper" → it is a SYMBOL, kept.
#   (3) the real agent-browser / $POOL_REAL_BIN / ~/.local/bin/agent-browser — the REAL Vercel CLI.
#       ALREADY CORRECT → kept.
#   The ONLY stale thing is PROSE "the wrapper" (meant the DELETED bin/agent-browser shim). C1,C2,R1-R5
#   rewrite that prose to (1) or (2); they never touch (3).

# PATTERN — concurrency.sh gate is `grep -c wrapper → 0` (no pool_wrapper_main symbol in this file).
#   release_reaper.sh gate is `grep wrapper | grep -v pool_wrapper_main → empty` (the symbol STAYS).
#   These are DIFFERENT gates because the files differ — do not copy-paste the gate blindly.

# PATTERN — match on TEXT, not line numbers. The item_description's ~12/~17/~20 are approximate;
#   the verbatim oldText blocks above are authoritative (and the edit tool matches exact text anyway).

# GOTCHA — R4 is an assertion LABEL string, not a comment, but it is in scope (comment-like prose)
#   and safe to edit (assert_eq ignores its label arg for pass/fail). Do not skip it.

# GOTCHA — do NOT "also fix" the real-agent-browser / $POOL_REAL_BIN / ~/.local/bin/agent-browser
#   references to agent-browser-pool. They are the REAL CLI and were ALWAYS correct (item point 1).

# GOTCHA — shellcheck rc=1 is EXPECTED (2× SC1091 infos from `source ./validate.sh`). Since this
#   item is comments-only, no new shellcheck code CAN appear — but assert it (defensive).
```

### Integration Points

```yaml
NONE for this item beyond the two test files.
  - This item CONSUMES (does not modify):
      * bin/agent-browser-pool — the sole entry point whose existence makes "bin/agent-browser" stale.
      * lib/pool.sh — defines pool_wrapper_main (the real symbol test e references + calls).
      * test/validate.sh — sourced by both files (defines $ABPOOL_ADMIN); UNCHANGED (T1.S1).
  - Sibling in flight (NO overlap — different files):
      * test/transparency.sh (P2.M5.T2.S1) — its own rewrite; this item does NOT touch it.
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`bash -n`, `shellcheck`, `grep`, `git`).
> **Do NOT run `bash test/concurrency.sh` or `bash test/release_reaper.sh`, do NOT boot Chrome, do
> NOT invoke `agent-browser`/`agent-browser-pool` during this item.** The static checks are
> authoritative. (An optional isolated-sandbox suite run is Level 3 and is NOT a gate.)

### Level 1: Syntax, lint & content (run after all edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# --- syntax (comments-only, but assert no accidental breakage) ---
bash -n test/concurrency.sh   && echo "OK: bash -n concurrency.sh"   || echo "FAIL: bash -n concurrency.sh"
bash -n test/release_reaper.sh && echo "OK: bash -n release_reaper.sh" || echo "FAIL: bash -n release_reaper.sh"

# --- lint: rc=1 EXPECTED (pre-existing 2× SC1091); assert NO new codes ---
for f in test/concurrency.sh test/release_reaper.sh; do
  shellcheck -s bash "$f" > "/tmp/sc_$(basename "$f").txt" 2>&1
  codes=$(grep -oE 'SC[0-9]+' "/tmp/sc_$(basename "$f").txt" | sort -u | tr '\n' ' ')
  echo "$f shellcheck codes: $codes"
  bad=0
  for c in $codes; do
    case "$c" in
      SC1091) : ;;                 # pre-existing info (source ./validate.sh) — expected
      *) echo "FAIL: $f has unexpected NEW shellcheck code $c"; bad=1;;
    esac
  done
  [ "$bad" -eq 0 ] && echo "OK: $f only the pre-existing SC1091 info"
done

# --- REMOVALS: prose 'wrapper' MUST reach zero ---
#   concurrency.sh: NO pool_wrapper_main symbol → plain grep -c → 0.
n=$(grep -cE 'wrapper' test/concurrency.sh || true)
[ "$n" -eq 0 ] && echo "OK: concurrency.sh has no 'wrapper' (prose or symbol)" || echo "FAIL: concurrency.sh still has $n 'wrapper' hit(s)"

#   release_reaper.sh: pool_wrapper_main symbol is KEPT → every remaining 'wrapper' must BE that symbol.
if grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main' | grep -q .; then
  echo "FAIL: release_reaper.sh has PROSE 'wrapper' (not the pool_wrapper_main symbol):"
  grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main'
else
  echo "OK: release_reaper.sh — every 'wrapper' is the pool_wrapper_main symbol (prose gone)"
fi

# --- PRESERVES: correct references MUST still be present (count non-decreasing vs baseline) ---
#   baseline (verified live): concurrency.sh 'real agent-browser|POOL_REAL_BIN' = 9 hits;
#   release_reaper.sh = 8 hits. Assert >= baseline (comments preserved them).
conc_real=$(grep -cE 'real agent-browser|POOL_REAL_BIN' test/concurrency.sh || true)
rel_real=$(grep -cE 'real agent-browser|POOL_REAL_BIN' test/release_reaper.sh || true)
[ "$conc_real" -ge 9 ] && echo "OK: concurrency.sh real-agent-browser/POOL_REAL_BIN preserved ($conc_real)" || echo "FAIL: concurrency.sh real-CLI refs dropped ($conc_real < 9)"
[ "$rel_real"  -ge 8 ] && echo "OK: release_reaper.sh real-agent-browser/POOL_REAL_BIN preserved ($rel_real)"  || echo "FAIL: release_reaper.sh real-CLI refs dropped ($rel_real < 8)"

#   release_reaper.sh admin verbs (agent-browser-pool release/reap) preserved.
rel_admin=$(grep -cE 'agent-browser-pool (release|reap)' test/release_reaper.sh || true)
[ "$rel_admin" -ge 4 ] && echo "OK: release_reaper.sh agent-browser-pool admin verbs preserved ($rel_admin)" || echo "FAIL: release_reaper.sh admin-verb refs dropped ($rel_admin < 4)"

#   release_reaper.sh pool_wrapper_main SYMBOL + its direct CALL preserved.
grep -q '( pool_wrapper_main close )' test/release_reaper.sh && echo "OK: test e pool_wrapper_main call preserved" || echo "FAIL: test e pool_wrapper_main call lost"
sym=$(grep -cE 'pool_wrapper_main' test/release_reaper.sh || true)
[ "$sym" -ge 7 ] && echo "OK: release_reaper.sh pool_wrapper_main symbol refs preserved ($sym)" || echo "FAIL: pool_wrapper_main symbol refs dropped ($sym < 7)"
```

**Expected**: `bash -n` → OK on both; shellcheck → only SC1091 on both (no new codes);
concurrency.sh `wrapper` → 0; release_reaper.sh prose `wrapper` (excl. `pool_wrapper_main`) → empty;
real-CLI refs preserved (≥9 / ≥8); admin verbs preserved (≥4); `pool_wrapper_main` symbol + call
preserved (symbol ≥7, call present).

### Level 2: Component Validation — N/A (static by design)

The edits are comments/labels only — there is no executable logic to unit-test. Runtime
correctness of the suites is unchanged (zero executable-line edits). Per AGENTS.md §1 we do NOT
execute the suites. The Level-1 static checks are authoritative.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Scope: ONLY the two target files modified by THIS item.
git status --short
git status --short | grep -vE '^.{2} test/(concurrency|release_reaper)\.sh$' | grep . \
  && echo "FAIL: changes outside the two target files" || echo "OK: only concurrency.sh + release_reaper.sh modified"

# Confirm siblings / SHIPPED files untouched:
for f in test/validate.sh test/transparency.sh lib/pool.sh bin/agent-browser-pool bin/.gitkeep \
         install.sh README.md PRD.md .gitignore; do
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done

# Shipped-behavior anchors (read-only — NO binary execution) that justify keeping pool_wrapper_main:
grep -q '^pool_wrapper_main() {' lib/pool.sh && echo "OK: pool_wrapper_main is a real fn (symbol refs are correct, not stale)" || echo "FAIL: pool_wrapper_main fn missing"
test -e bin/agent-browser-pool && ! test -e bin/agent-browser && echo "OK: sole entry point confirmed (shim gone)" || echo "FAIL: bin state unexpected"

# OPTIONAL (NOT a gate; ONLY in a fully isolated container/bwrap per AGENTS.md §1/§3):
#   running each suite confirms the (unchanged) tests still pass against live Chrome. Both boot real
#   headless Chrome + spawn sim-owners → NEVER run in the shared sandbox. If run isolated:
#     AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh; echo rc=$?
#     AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh; echo rc=$?
#   expect rc 0. The static Level-1 checks are authoritative; these runs are extra confidence only
#   AND since this item changed ZERO executable lines, they CANNOT regress.
```

### Level 4: Creative & Domain-Specific Validation — N/A

A comment-only edit has no domain runtime beyond Levels 1-3. The one domain-specific concern — that
the comments now accurately describe the sole-entry-point model — is pinned by the shipped-behavior
anchors (bin/ has only agent-browser-pool; pool_wrapper_main is a real fn) verified live in research.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n test/concurrency.sh test/release_reaper.sh` → exit 0.
- [ ] `shellcheck -s bash test/concurrency.sh` → only the 2× SC1091 infos; no new codes.
- [ ] `shellcheck -s bash test/release_reaper.sh` → only the 2× SC1091 infos; no new codes.
- [ ] Scope: only `test/concurrency.sh` + `test/release_reaper.sh` modified by this item.

### Feature Validation

- [ ] ZERO prose "wrapper" in concurrency.sh (`grep -cE 'wrapper'` → 0).
- [ ] ZERO prose "wrapper" in release_reaper.sh (`grep wrapper | grep -v pool_wrapper_main` → empty).
- [ ] `pool_wrapper_main` symbol + its direct call (release_reaper.sh:395) PRESERVED.
- [ ] All "real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser` refs PRESERVED.
- [ ] All `agent-browser-pool release/reap` admin-verb refs PRESERVED.
- [ ] Header comments now name "the pool entry point (bin/agent-browser-pool)" / `pool_wrapper_main`.

### Code Quality / Scope Validation

- [ ] **Only** `test/concurrency.sh` + `test/release_reaper.sh` are modified by this item.
- [ ] `test/validate.sh`, `test/transparency.sh`, `lib/pool.sh`, `bin/*`, `install.sh`, all `*.md` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] ZERO executable-line changes (every assertion, call, and `$ABPOOL_ADMIN`/`$POOL_REAL_BIN` invocation byte-identical).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no suite run) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] No external doc files change (the contract's DOCS note). Internal test comments are
      updated inline (header HOW-IT-WORKS blocks, the _concurrency_run_one_lane WHY comment, the test
      d close comment, the test e body comments + assertion label).
- [ ] Comments now accurately describe the no-shadow explicit-invocation model (PRD §2.17): the pool
      entry point is `bin/agent-browser-pool`; driving routes through `pool_wrapper_main`; the real
      agent-browser is `$POOL_REAL_BIN`.

---

## Anti-Patterns to Avoid

- ❌ Don't rename the `pool_wrapper_main` symbol or its direct call in test e — it is a REAL FUNCTION
      (lib/pool.sh:3619) the test invokes. Renaming it is a functional change (forbidden). Its name
      contains "wrapper" → that's fine; the gate excludes it (`grep -v pool_wrapper_main`).
- ❌ Don't set `grep -c wrapper → 0` as the gate for release_reaper.sh — it WOULD pass only by
      renaming the real symbol. Use `grep wrapper | grep -v pool_wrapper_main → empty` instead.
      (concurrency.sh has no such symbol, so `grep -c wrapper → 0` IS valid there.)
- ❌ Don't "fix" the "real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser`
      references to `agent-browser-pool` — they name the REAL Vercel CLI and were ALWAYS correct
      (item contract point 1).
- ❌ Don't touch the `agent-browser-pool release/reap` admin-verb references — they are already
      correct (item contract point 3b line 20).
- ❌ Don't edit `test/transparency.sh` (P2.M5.T2.S1, in flight) or `test/validate.sh` (T1.S1) —
      owned by sibling/completed items. This item's files are concurrency.sh + release_reaper.sh ONLY.
- ❌ Don't match edits on line numbers — the item_description's ~12/~17/~20 are approximate. Match
      on the verbatim oldText blocks (the edit tool matches exact text anyway).
- ❌ Don't skip R4 because it's an assertion string — it's comment-like prose (an `assert_eq` LABEL),
      in scope, and safe (assert_eq ignores its label for pass/fail).
- ❌ Don't treat `shellcheck` exit 1 as failure — it's 1 TODAY (2× SC1091 infos from
      `source ./validate.sh`). The gate is "no NEW codes"; comments-only can't add any.
- ❌ Don't run `bash test/concurrency.sh` / `bash test/release_reaper.sh` as a gate or in the shared
      sandbox — they boot real Chrome + spawn sim-owners (sandbox-wedge risk, AGENTS.md §1/§3/§4).
      Static checks suffice; the suites are optional in a fully isolated container only, and since
      this item changed ZERO executable lines they cannot regress anyway.
