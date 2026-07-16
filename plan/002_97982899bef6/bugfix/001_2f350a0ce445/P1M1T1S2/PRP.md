# PRP — P1.M1.T1.S2: Delete `pool_dispatch_classify` function, contract comment, and obsolete selftest

> **Bugfix context**: This subtask is the **second half of the fix for Issue 1** (Critical) +
> the **whole of Issue 4** (Minor) from the QA report
> (`plan/002_97982899bef6/bugfix/001_2f350a0ce445/TEST_RESULTS.md`). The sibling subtask
> **S1** (`P1.M1.T1.S1`) deleted the *call site* (the step-c META block in
> `pool_wrapper_main`), leaving `pool_dispatch_classify` as **dead code** with zero call
> sites. **S2 removes the corpse**: the function body, its contract comment block, its
> dedicated selftest, and stale "mirrors pool_dispatch_classify" comment references in four
> sibling functions. After S2, `pool_dispatch_classify` no longer exists anywhere in the
> shipped code, and `bin/agent-browser-pool`'s `case` dispatcher is the single source of
> truth for the pool-verb/driving split (Issue 4 / delta `D1.M1.T2`).
>
> **Why split S1/S2**: S1 alone closes the isolation breach (no code path exec's meta
> commands unchanged anymore). S2 is cleanup that completes Issue 4. Keeping them separate
> means a partial completion of M1.T1 still leaves the pool secure.

---

## Goal

**Feature Goal**: Remove the now-dead `pool_dispatch_classify` function and all its lingering references so that the shipped `lib/pool.sh` contains no META-classification concept and no dead code; the only command classifier left is `bin/agent-browser-pool`'s `case` dispatcher (pool verbs vs. everything-else-is-driving). Replace the four "mirrors `pool_dispatch_classify`" comments in sibling arg-normalization functions with wording that references the shared flag-scan pattern instead of the deleted function. Delete the obsolete `selftest_dispatch_classify_cases` (the function it tests no longer exists). Update the agent skill's `SKILL.md` "Which commands trigger a lane" section to describe the post-fix "every non-pool-verb is driving" model.

**Deliverable**:
1. `lib/pool.sh` — delete the contract comment block (the `# ===...# Wrapper shim — command dispatch (P1.M6.T1.S1)` section through the GOTCHA notes) + the `pool_dispatch_classify() { … }` function body. One contiguous deletion (currently lines 3012–3128).
2. `lib/pool.sh` — reword 4 comment references in sibling functions that currently say "mirrors `pool_dispatch_classify`" (at lines 3135, 3176, 3352, 3658, 3707) to reference the shared flag-scan pattern without naming the deleted function. **Logic of those functions is UNCHANGED — comments only.**
3. `lib/pool.sh` — reword 2 comment references that describe the dispatch flow / rc-taxonomy (lines 3313, 3487) so they no longer describe a META classification step or list `pool_dispatch_classify`.
4. `test/validate.sh` — delete `selftest_dispatch_classify_cases` AND its header comment block (currently lines 345–384). The `compgen -A function | grep '^selftest_'` discovery runner then simply no longer finds it — no registration to undo.
5. `.agents/skills/agent-browser-pool/SKILL.md` — rewrite the "Which commands trigger a lane" § (lines 55–65) to remove the "meta commands pass straight through" clause; update the reference pointer at lines 143–145 to say "pool-verbs-vs-driving dispatch".

**Success Definition**:
- `bash -n lib/pool.sh` clean; `bash -n test/validate.sh` clean.
- `shellcheck -s bash lib/pool.sh` → 0 findings; `shellcheck -s bash test/validate.sh` → 0 findings.
- `grep -n 'pool_dispatch_classify' lib/pool.sh test/validate.sh` → **ZERO hits**.
- `grep -n 'selftest_dispatch_classify' test/validate.sh` → **ZERO hits**.
- `pool_normalize_close`, `pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close` still exist and their *bodies* are byte-identical to pre-S2 (only their header comments changed).
- `SKILL.md` no longer claims any command "passes straight through … WITHOUT acquiring a lane"; the reference pointer says "pool-verbs-vs-driving".
- DO NOT run the test suite or real Chrome (AGENTS.md §1/§2).

## User Persona

**Target User**: Future maintainers reading `lib/pool.sh` (who must not be misled by a dead classifier that contradicts the live `bin` dispatcher), and agents reading the skill (who must learn "every non-pool-verb is driving", not the removed "meta → passthrough" model).

**Use Case**: A maintainer greps for how commands are classified. After S2 they find exactly one place — `bin/agent-browser-pool`'s `case` — instead of two contradictory ones (the bin dispatcher + a dead `pool_dispatch_classify` that still described the old META set). An agent reading `SKILL.md` is told `--version`/`skills`/`mcp`/`session list` are driving commands (fail-fast without a `pi` ancestor), not passthrough.

**Pain Points Addressed**:
- **Issue 4 (Minor)**: duplicated/overlapping classification (the bin dispatcher already did the pool-verb split; `pool_dispatch_classify` was a redundant second classifier that became 100% dead code once S1 deleted step-c). Delta `D1.M1.T2` explicitly allows deleting it.
- **Dead-code confusion**: a reader finding `pool_dispatch_classify` after S1 would reasonably assume it's live and try to reason about META classification — a concept that no longer exists in the execution path.
- **Skill/code drift** (Issue 3, the `SKILL.md` half — `configuration.md` is owned by S1): the skill still teaches the removed model.

## Why

- **Issue 4 (Minor)** + delta `D1.M1.T2`: "`pool_dispatch_classify` is either deleted or reduced to the pool-verb/driving split already done by the dispatcher (avoid duplication)." Since S1 deleted the only call site, deletion is the clean choice — the bin dispatcher is already the single source of truth.
- **Issue 1 (Critical) cleanup**: S1 closed the breach (no exec path). S2 removes the function that *defined* the breached classification, so the dead code can never be accidentally re-wired into a new call site.
- **Consistency with S1**: S1's PRP left `pool_dispatch_classify` as dead code *deliberately* and named S2 as its owner. This PRP fulfills that contract.
- **Skill doc accuracy** (`SKILL.md`): S1 owns `references/configuration.md`; this subtask owns the `SKILL.md` "Which commands trigger a lane" section (per the item contract's DOCS clause). Both must stop teaching "meta → passthrough".

## What

### Behavior change

**None at runtime.** `pool_dispatch_classify` had zero call sites after S1 (verified: `grep -n 'pool_dispatch_classify "\$@"' lib/pool.sh` returns nothing post-S1). Deleting a never-called function changes no execution path. The four sibling functions (`pool_normalize_close`, `pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close`) only *mention* `pool_dispatch_classify` in comments — their code never calls it. The selftest only ran when explicitly invoked via `_run_selftest_suite`, and tested a function that is being deleted.

### What does NOT change

- `bin/agent-browser-pool` dispatcher (already correct, untouched).
- The driving path (steps d–k in `pool_wrapper_main`) — S1 already fixed it; S2 does not touch `pool_wrapper_main`.
- The bodies (logic) of `pool_normalize_close`, `pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close` — **only their header comments are reworded**.
- `test/transparency.sh` — owned by `P1.M2.T1.S1` (it contains a `pool_dispatch_classify` comment at line 267 inside `test_version_passthrough`, but that test + comment are P1.M2.T1.S1's scope; see "Known Gotchas").
- `README.md` — owned by `P1.M3.T1.S1` (Mode B cross-cutting docs).

### Success Criteria

- [ ] `lib/pool.sh` no longer defines `pool_dispatch_classify` (the `===...Wrapper shim — command dispatch (P1.M6.T1.S1)...===` section header, the full contract comment, and the function body are gone).
- [ ] `lib/pool.sh` has ZERO occurrences of the string `pool_dispatch_classify`.
- [ ] The four sibling functions still exist with byte-identical *bodies* (only header comments changed): `pool_normalize_close`, `pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close`.
- [ ] `test/validate.sh` no longer defines `selftest_dispatch_classify_cases` (header comment + function body both deleted).
- [ ] `test/validate.sh` has ZERO occurrences of `pool_dispatch_classify` and ZERO of `selftest_dispatch_classify`.
- [ ] `bash -n` clean on both files; `shellcheck -s bash` 0 findings on both files.
- [ ] `SKILL.md` "Which commands trigger a lane" § describes every non-pool-verb as driving; no "meta"/"passes straight through … WITHOUT acquiring a lane" clause.
- [ ] `SKILL.md` reference pointer (lines 143–145) says "pool-verbs-vs-driving" not "meta-vs-driving".

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP quotes the **exact current text** of every edit site (verified by direct read of `lib/pool.sh`, `test/validate.sh`, and `SKILL.md` on 2026-07-15), gives exact replacement text for every comment rewrite, specifies the exact line ranges for the two block deletions, and lists the exact validation commands (all verified to pass on the pre-S2 baseline). The change is mechanical deletion + comment/doc sync — no new logic, no judgment calls. The implementer needs no prior exposure beyond reading the quoted snippets.

### Documentation & References

```yaml
# MUST READ — project-internal (primary; this is code-surgery, not a library task)
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_meta_refs.md
  why: THE reference map. §1 gives the exact line ranges of the contract comment (3012–3069) and function body (3070–3128) and confirms "The next function (pool_normalize_close) begins at line 3181" — so the deletion is a clean contiguous block 3012–3128 with a safe boundary. §4 lists EVERY `pool_dispatch_classify` hit across the whole repo with file:line, which is the master checklist for "did I miss a reference?". §0 disambiguates the two unrelated "passthrough" concepts (META dispatch vs owner-passthrough) — ONLY touch concept #1.
  critical: §0's concept #2 (owner-passthrough at lib/pool.sh:580, 1005, 2089–2099) is UNRELATED and MUST NOT be touched. The "passthrough" word at those lines refers to POOL_OWNER_PID==0 (no pi ancestor), not META dispatch.
  pattern: §4's "lib/pool.sh — META dispatch (concept #1 — in scope)" bullet list is the exact hit list to scrub; the "Owner passthrough (concept #2 — UNRELATED, out of scope)" list is the DO-NOT-TOUCH list.

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/system_context.md
  why: "Code Change Map" table assigns S2's exact edit sites (lib/pool.sh 3012–3128 delete; the 4 sibling-function comment rewording; validate.sh 345–384 delete; SKILL.md 55–65 + 143–145). "Dispatch Flow (After Fix)" confirms bin dispatcher is the sole classifier post-fix.
  pattern: Section "Code Change Map" → S2 rows.

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M1T1S1/PRP.md
  why: S1's PRP is the CONTRACT for what already exists when S2 starts. S1 deleted the step-c call site, dropped `class` from `pool_wrapper_main`'s locals, and rewrote `configuration.md` + 2 comment blocks in pool_wrapper_main. S1 EXPLICITLY left pool_dispatch_classify (3012–3128) as dead code and named S2 as its owner.
  critical: S1 already changed lib/pool.sh lines ~3439–3447, ~3468, ~3499–3501, ~3517, ~3529–3536 and configuration.md lines 8 + 44–76. S2 MUST NOT re-touch those (they are S1's deliverable, already correct post-S1). S2's pool.sh edits are at 3012–3128 (delete) + 3135/3176/3313/3352/3487/3658/3707 (comment rewording) — none of which overlap S1's edit sites.
  gotcha: S1 may have shifted line numbers in lib/pool.sh vs the research_meta_refs.md baseline (S1 deleted ~10 lines around 3517/3529). The contract-comment + function at 3012–3128 are ABOVE S1's edits (S1 touched ~3439+), so 3012–3128 line numbers are STABLE across S1. The 4 sibling functions (3176/3352/3658/3707) are also above S1's edits except 3352/3658/3707 — wait, those ARE above 3439. All S2 edit sites (3012–3128, 3135, 3176, 3313, 3352, 3487, 3658, 3707) are at or below line 3707, and S1's lowest edit was ~3439. THEREFORE: S2 sites at 3313, 3352, 3487, 3658, 3707 may have SHIFTED if S1 deleted lines above them. But S1 deleted lines at 3517 (1 line) + 3529–3536 (8 lines) = 9 lines deleted, ALL ABOVE 3707. So 3487→3478, 3658→3649, 3707→3698 after S1. ALWAYS match by TEXT, never by line number — the quoted oldText blocks below are byte-accurate.

- file: lib/pool.sh
  why: THE file. Exact text of every edit site is quoted in Implementation Tasks (verified by direct read 2026-07-15). The contract-comment block 3012–3128 is a clean contiguous unit bounded above by the previous function's closing `}` (pool_wait_for_lane, line 3011) and below by the `===...Wrapper shim — arg normalization (P1.M6.T1.S2)...===` header (line ~3130).
  pattern: existing comment style: `===...` section banners, `# GOTCHA — PREFIX` blocks, PRD §-citations. Match this in the (minimal) comment rewording.
  gotcha: line numbers shift across edits. The edit tool matches by EXACT TEXT. Copy the quoted oldText verbatim; if a match fails, re-read the region and use the current text.

- file: test/validate.sh
  why: contains selftest_dispatch_classify_cases (lines 345–384: header comment 345–354, function 355–384). Bounded above by the previous selftest's closing `}` (line 343, end of selftest_pool_config_bool_cases) and below by a blank line (385) then the next block's header comment (386: `# --- _pool_clean_args_is_close truth-table ...`).
  pattern: selftests are auto-discovered by `_run_selftest_suite` via `compgen -A function | grep '^selftest_'` (validate.sh:752). Deleting the function DEFINITION removes it from discovery — no registration list to edit. (Same mechanism as `run_test`/`abpool_run_suite` at validate.sh:246 for `test_*`.)
  gotcha: do NOT touch the `compgen` discovery code (246 or 752) — it is generic and correct; it simply won't find the deleted function.

- file: bin/agent-browser-pool
  why: confirms the live dispatcher is already the single source of truth (case at lines 30–37: status/reap/release/doctor/--help|-h|help → pool_admin_*; *) → pool_wrapper_main). After S2, this is the ONLY command classifier. Zero occurrences of meta/passthrough/dispatch_classify (verified).
  gotcha: do NOT touch bin/agent-browser-pool — read-only reference.

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: the skill doc to update. § "Which commands trigger a lane" (lines 55–65) currently teaches "A small set of meta commands pass straight through … WITHOUT acquiring a lane: skills, --version, session list, dashboard, plugin, mcp." — this is the removed model. Lines 143–145 reference "the complete meta-vs-driving dispatch classification".
  pattern: existing markdown voice (bold lead-ins, backticked command lists, parenthetical asides pointing at references/configuration.md).
  gotcha: S1 already rewrote references/configuration.md (the OTHER skill doc) to "pool verbs vs driving". This subtask syncs SKILL.md to match. Do NOT re-touch configuration.md (S1's deliverable).
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                 # 4533 LOC (pre-S2; ~4524 post-S1, depending on S1's exact deletions)
│                               #   DELETE contract comment + pool_dispatch_classify (3012–3128, ~117 lines)
│                               #   REWORD 7 comment refs (3135, 3176, 3313, 3352, 3487, 3658, 3707)
├── test/validate.sh            # DELETE selftest_dispatch_classify_cases (345–384, ~40 lines)
├── bin/agent-browser-pool      # UNCHANGED (read-only; already the sole classifier)
└── .agents/skills/agent-browser-pool/
    ├── SKILL.md                # REWRITE "Which commands trigger a lane" (55–65); edit ref pointer (143–145)
    └── references/configuration.md  # UNCHANGED (S1's deliverable, already "pool verbs vs driving")
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 3 existing files:
#   lib/pool.sh                                              — delete dead classifier + reword 7 comments
#   test/validate.sh                                         — delete obsolete selftest (+ its header comment)
#   .agents/skills/agent-browser-pool/SKILL.md               — sync "Which commands trigger a lane" + ref pointer
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (S1/S2 BOUNDARY): S1 already deleted the step-c CALL SITE in pool_wrapper_main
# (lib/pool.sh ~3529–3536) and dropped `class` from the locals. S2 does NOT touch
# pool_wrapper_main at all. S2's pool.sh edits are exclusively: (a) the 3012–3128 block
# delete, (b) 7 comment rewording in OTHER functions. If you find yourself editing
# pool_wrapper_main, STOP — that's S1's scope (already done).

# CRITICAL (research_meta_refs.md §0): TWO unrelated "passthrough" concepts exist.
#   Concept #1 (META dispatch — IN SCOPE): pool_dispatch_classify + step-c. DELETE.
#   Concept #2 (owner-passthrough — OUT OF SCOPE): POOL_OWNER_PID==0 at lib/pool.sh:580,
#       1005, 2089–2099. These say "passthrough" but mean "no pi ancestor found → fail-fast".
#       DO NOT TOUCH concept #2 lines. grep 'passthrough' lib/pool.sh will STILL return hits
#       after S2 — those are the owner-passthrough comments, correctly retained.

# CRITICAL (test/transparency.sh:267 is NOT yours): transparency.sh line 267 contains a
# comment "pool_dispatch_classify classifies `--version` as meta → exec ...". That comment
# lives inside test_version_passthrough(), which is OWNED BY P1.M2.T1.S1 (per the plan tree
# and S1's PRP). P1.M2.T1.S1 replaces test_version_passthrough + test_passthrough_skills.
# THEREFORE: the item contract's "grep pool_dispatch_classify lib/pool.sh test/validate.sh
# → ZERO hits" is scoped to lib/pool.sh + test/validate.sh ONLY. transparency.sh is a known
# cross-cutting residual that P1.M2.T1.S1 cleans up. Do NOT edit transparency.sh here.

# GOTCHA (line numbers drift across S1): S1 deleted ~9 lines in lib/pool.sh at ~3517/3529.
# S2's edit sites at 3487/3658/3707 are BELOW S1's deletions, so their line numbers SHIFTED
# DOWN by ~9 after S1. The research_meta_refs.md line numbers (3487/3658/3707) are the
# PRE-S1 baseline. ALWAYS match by the exact TEXT quoted in Implementation Tasks (byte-
# accurate), never by line number. The edit tool matches text, not numbers.

# GOTCHA (the 3012–3128 block is contiguous and cleanly bounded): above it is the closing
# `}` of pool_wait_for_lane (line 3011); below it is the `# ===...` banner for the arg-
# normalization section (P1.M6.T1.S2, line ~3130). Deleting 3012–3128 leaves pool_wait_for_lane's
# `}` directly followed by the arg-normalization banner — no orphaned code. Verified by read.

# GOTCHA (shellcheck must stay 0 findings on BOTH files): pre-S2 baseline is clean on both
# (verified: `shellcheck -s bash lib/pool.sh` rc=0; `shellcheck -s bash test/validate.sh`
# rc=0 — note validate.sh emits SC1091/SC2016 INFO-level wiki links, not findings; rc=0).
# Deleting a function + its callers cannot introduce a warning. The comment edits are inert.
# If shellcheck fires post-edit, you changed CODE beyond the quoted edits — revert and redo.

# GOTCHA (the 4 sibling-function edits are COMMENT-ONLY): pool_normalize_close, pool_strip_
# session_args, _pool_clean_args_is_bare_connect, _pool_clean_args_is_close have headers
# that say "mirrors pool_dispatch_classify's scan". Their BODIES implement an INDEPENDENT
# flag-scan (they do not call pool_dispatch_classify). Rewording the comment to "mirrors the
# flag-scan pattern" is accurate — the scan logic is shared, the function reference is not.
# Do NOT change a single line of code in these 4 functions.

# GOTCHA (AGENTS.md §1/§2): validation is STATIC ONLY. Do NOT run test/validate.sh's
# _run_selftest_suite, do NOT boot Chrome, do NOT run the test suite. bash -n + shellcheck
# + grep are the only validation commands. The selftest deletion is verified by grep (the
# function is gone from compgen discovery), not by running it.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models, no schemas, no new types. This is line/block deletion + comment/doc sync.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — delete the contract comment block + pool_dispatch_classify function
  - FIND this EXACT contiguous block (currently lines 3012–3128; match by text). It starts
    at the `# ===...` section banner and ends at the function's closing `}`, immediately
    before the NEXT `# ===...` banner ("Wrapper shim — arg normalization (P1.M6.T1.S2)").
  - The block to delete is EVERYTHING from:
        # =============================================================================
        # Wrapper shim — command dispatch (P1.M6.T1.S1)
        # =============================================================================
    ...through the closing `}` of:
        pool_dispatch_classify() {
            ... (entire body) ...
        }
  - I.e. delete from the banner line "# Wrapper shim — command dispatch (P1.M6.T1.S1)" up
    to AND INCLUDING the line `}` that closes `pool_dispatch_classify()`. Do NOT delete the
    FOLLOWING "# Wrapper shim — arg normalization (P1.M6.T1.S2)" banner — that belongs to
    pool_normalize_close (the next function, kept).
  - The exact text of the full block is large (~117 lines). Rather than quote it all here,
    DELETE BY BOUNDARY: use the edit tool with oldText = the section's opening banner
        # =============================================================================
        # Wrapper shim — command dispatch (P1.M6.T1.S1)
        # =============================================================================
    through the function's final lines:
            # Everything else → 'driving' (DRIVING set + unrecognized; contract c & d).
            printf 'driving\n'
            return 0
        }
    (Read lib/pool.sh lines 3012–3128 to capture the exact byte-accurate oldText. The block
    is self-contained: it begins right after pool_wait_for_lane's `}` and ends right before
    the arg-normalization banner.)
  - VERIFY after: `grep -n 'pool_dispatch_classify' lib/pool.sh` returns ZERO hits among
    lines <= ~3130. (The 7 remaining hits at 3135/3176/3313/3352/3487/3658/3707 are
    comment references in OTHER functions — Tasks 2–4 reword them.)
  - WHY contiguous delete: the contract comment + function are one logical unit (the
    comment is the function's contract). Splitting them would leave an orphaned comment
    describing a non-existent function.

Task 2: EDIT lib/pool.sh — reword the comment reference inside the arg-normalization section header
  - FIND (currently ~line 3135, inside the "# Wrapper shim — arg normalization (P1.M6.T1.S2)"
    banner block, the line that says):
        # lifecycle (M6.T3.S1) AFTER pool_dispatch_classify returned 'driving' and the lane is
  - REPLACE WITH:
        # lifecycle (M6.T3.S1) AFTER the bin dispatcher routed a non-pool-verb token to driving, and the lane is
  - WHY: the original described the call sequence "classify → driving → normalize". Post-fix
    there is no classify step; the bin dispatcher does the routing. The new wording names
    the actual mechanism (bin dispatcher + non-pool-verb → driving).

Task 3: EDIT lib/pool.sh — reword TWO "mirrors pool_dispatch_classify" comments in pool_normalize_close + pool_strip_session_args
  - SUB-EDIT (a) — FIND (currently ~line 3157, inside pool_normalize_close's header):
        #   a. Scan $@ (mirroring pool_dispatch_classify) to find the COMMAND (first non-flag):
    - REPLACE WITH:
        #   a. Scan $@ (mirroring the shared flag-scan pattern) to find the COMMAND (first non-flag):
  - SUB-EDIT (b) — FIND (currently ~line 3176, inside pool_normalize_close's header):
        # GOTCHA — MIRRORS pool_dispatch_classify's scan exactly so the two siblings agree on the
        #   command token (do NOT enumerate agent-browser value-flags). Safe for close --all.
    - REPLACE WITH:
        # GOTCHA — uses the SAME flag-scan pattern as the other arg/clean helpers so all siblings
        #   agree on the command token (do NOT enumerate agent-browser value-flags). Safe for close --all.
  - SUB-EDIT (c) — FIND (currently ~line 3186, inside pool_normalize_close's BODY, a comment):
        # --- a. Find the COMMAND (mirror pool_dispatch_classify's flag-scan), index-based. ---
    - REPLACE WITH:
        # --- a. Find the COMMAND (shared flag-scan pattern), index-based. ---
  - SUB-EDIT (d) — FIND (currently ~line 3313, inside pool_strip_session_args's header):
        # pool_dispatch_classify returned 'driving', AFTER M6.T1.S2's close/connect normalize,
    - REPLACE WITH:
        # the bin dispatcher routed a non-pool-verb token to driving, AFTER M6.T1.S2's close/connect normalize,
  - SUB-EDIT (e) — FIND (currently ~line 3352, inside pool_strip_session_args's header):
        # GOTCHA — MIRRORS pool_dispatch_classify's scan case-arms (--session / --session=*) so the
        #   wrapper-shim siblings agree on what a --session token is.
    - REPLACE WITH:
        # GOTCHA — uses the SAME --session / --session=* case-arms as the other arg/clean helpers so
        #   the wrapper-shim siblings agree on what a --session token is.
  - WHY: these 5 comments describe the SHARED scanning pattern by naming one implementation
    of it (pool_dispatch_classify). With that function deleted, name the pattern itself.
    LOGIC UNCHANGED — these are all comments.

Task 4: EDIT lib/pool.sh — reword the rc-taxonomy comment + the two _pool_clean_args_is_* headers
  - SUB-EDIT (a) — FIND (currently ~line 3487, the "RC TAXONOMY" comment block in pool_wrapper_main's header):
        #   rc 0 ALWAYS (no guard):  pool_dispatch_classify, pool_normalize_close/connect,
        #                            pool_strip_session_args, pool_config_init, pool_state_init,
    - REPLACE WITH (drop pool_dispatch_classify from the list; keep the rest):
        #   rc 0 ALWAYS (no guard):  pool_normalize_close/connect,
        #                            pool_strip_session_args, pool_config_init, pool_state_init,
  - SUB-EDIT (b) — FIND (currently ~line 3658, inside _pool_clean_args_is_bare_connect's header):
        # LOGIC (mirrors pool_normalize_connect / pool_dispatch_classify's flag-vs-command scan):
    - REPLACE WITH:
        # LOGIC (mirrors pool_normalize_connect / the shared flag-vs-command scan pattern):
  - SUB-EDIT (c) — FIND (currently ~line 3707, inside _pool_clean_args_is_close's header):
        # token (skipping --session/--session=/--*/-*, mirroring pool_dispatch_classify) equals
    - REPLACE WITH:
        # token (skipping --session/--session=/--*/-*, using the shared flag-scan pattern) equals
  - WHY: same as Task 3 — name the pattern, not the deleted function. rc-taxonomy list no
    longer contains a dead function. LOGIC UNCHANGED.

Task 5: EDIT test/validate.sh — delete selftest_dispatch_classify_cases + its header comment block
  - FIND this EXACT block (currently lines 345–384). It starts at the header comment and
    ends at the function's closing `}`. The block is bounded above by the previous selftest's
    closing `}` (line 343, selftest_pool_config_bool_cases) + a blank line (344), and below
    by a blank line (385) + the next block's header comment (386).
  - DELETE from:
        # --- pool_dispatch_classify full table (P1.M1.T2.S1 / Issue 4) ------------------
    ...through:
            r="$(pool_dispatch_classify --json click)";       assert_eq "driving" "$r" "--json click -> driving" || return 1
        }
    (Read test/validate.sh lines 345–384 to capture the exact byte-accurate oldText — it is
    ~40 lines including the header comment block + the full function body.)
  - DELETE the trailing blank line (385) too, so the previous function's `}` (343) is
    followed by exactly ONE blank line then the next block's header (386). (Match the
    prevailing 1-blank-line separator style.)
  - WHY delete the header comment too: it describes the selftest's purpose and names
    pool_dispatch_classify. Leaving it would be an orphaned comment about a deleted function.
  - VERIFY after:
        grep -n 'pool_dispatch_classify' test/validate.sh   → ZERO hits
        grep -n 'selftest_dispatch_classify' test/validate.sh → ZERO hits
  - NOTE on discovery: validate.sh:752 `_run_selftest_suite` uses
    `compgen -A function | grep '^selftest_'`. Deleting the function definition removes it
    from `compgen -A function` output automatically. DO NOT touch the compgen line.

Task 6: EDIT .agents/skills/agent-browser-pool/SKILL.md — rewrite "Which commands trigger a lane"
  - FIND the EXACT block (lines 55–65, from "### Which commands trigger a lane" through the
    "See `references/configuration.md` for the full dispatch table." line):
      ----------------------------------------------------------------
      ### Which commands trigger a lane

      **Driving** commands acquire/use your lane. They include `open`, `connect`, `close`, `get`,
      `screenshot`, `click`, `type`, `eval`, `find`, and **any unrecognized command** — an unknown
      verb still gets your lane rather than erroring out.

      A small set of **meta** commands pass straight through to the real `agent-browser` WITHOUT
      acquiring a lane (so they work with no lane): `skills`, `--version`, `session list`,
      `dashboard`, `plugin`, and `mcp`. (The pool's own verbs — `status`, `reap`, `release`,
      `doctor`, and `help`/`--help`/`-h` — run pool functions, not the real binary; see §2 and §3.)
      See `references/configuration.md` for the full dispatch table.
      ----------------------------------------------------------------
  - REPLACE WITH:
      ----------------------------------------------------------------
      ### Which commands trigger a lane

      Every command except pool verbs (status/reap/release/doctor/help) is a driving command — it
      resolves your pi owner, acquires/reuses your lane, and runs scoped to `abpool-<N>` with
      `--session` stripped. This includes `open`, `connect`, `close`, `get`, `screenshot`,
      `click`, `type`, `eval`, `find`, and **any unrecognized command** (an unknown verb still
      gets your lane rather than erroring out). It also includes `--version`, `skills`,
      `dashboard`, `plugin`, `mcp`, and `session list` — these are driving now (they previously
      passed through unchanged; that path was removed for lane isolation: a caller-supplied
      `--session <X>` must never target another lane).

      The only commands that run WITHOUT a lane are the pool verbs (`status`, `reap`, `release`,
      `doctor`, and `help`/`--help`/`-h`), caught by the entry-point dispatcher before any lane
      work — see §2 and §3. There is no "meta / passthrough" class. See
      `references/configuration.md` for the full dispatch table.
      ----------------------------------------------------------------
  - WHY this structure: removes the "meta commands pass straight through … WITHOUT acquiring a
    lane" clause (the removed model). Preserves the driving-commands list (still accurate).
    ADDS the formerly-meta verbs to the driving set with a one-line rationale (so readers
    understand why `--version` is now driving, not a regression). Matches the post-fix
    contract exactly and stays consistent with S1's `configuration.md` rewrite.

Task 7: EDIT SKILL.md — update the reference pointer (lines 143–145)
  - FIND:
        For the full environment-variable table, the complete meta-vs-driving dispatch classification,
        the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix, read
        **`references/configuration.md`**.
  - REPLACE WITH:
        For the full environment-variable table, the complete pool-verbs-vs-driving dispatch
        classification, the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix, read
        **`references/configuration.md`**.
  - WHY: "meta-vs-driving" names the removed model; "pool-verbs-vs-driving" matches S1's
    configuration.md section heading ("Command dispatch: pool verbs vs driving").

Task 8: VERIFY — static validation only (AGENTS.md §1/§2: no Chrome, no test suite)
  - RUN (in order):
      bash -n lib/pool.sh
      bash -n test/validate.sh
      shellcheck -s bash lib/pool.sh
      shellcheck -s bash test/validate.sh
      grep -n 'pool_dispatch_classify' lib/pool.sh test/validate.sh
      grep -n 'selftest_dispatch_classify' test/validate.sh
      grep -n 'meta-vs-driving\|meta vs\. driving' .agents/skills/agent-browser-pool/SKILL.md
  - EXPECTED:
      bash -n (both)               → no output (clean)
      shellcheck (both)            → rc 0, 0 findings (lib/pool.sh fully silent; validate.sh
                                     may emit SC1091/SC2016 INFO wiki links but rc=0 — same
                                     as pre-S2 baseline)
      grep pool_dispatch_classify  → ZERO hits in BOTH lib/pool.sh and test/validate.sh
      grep selftest_dispatch_classify → ZERO hits in test/validate.sh
      grep SKILL.md meta-vs-driving → ZERO hits
  - ADDITIONAL regression grep (the 4 sibling functions are intact, logic unchanged):
      grep -n 'pool_normalize_close()\|pool_strip_session_args()\|_pool_clean_args_is_bare_connect()\|_pool_clean_args_is_close()' lib/pool.sh
      # EXPECT: exactly 4 hits — all 4 functions still defined.
  - FIX any failure before claiming done.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — delete a contiguous function+contract unit by boundary:
#   The contract comment (3012–3069) and function body (3070–3128) are ONE logical unit.
#   Delete both in a single edit call (oldText = the full block from the `# ===...` banner
#   through the closing `}`). Read the current lib/pool.sh:3012–3128 to capture the exact
#   bytes — do NOT retype from memory. The block is cleanly bounded (prev `}` above, next
#   `# ===...` banner below), so there is no ambiguity about where it ends.

# Pattern B — comment-only rewording (LOGIC UNCHANGED):
#   For the 7 comment references in Tasks 2–4, the oldText is the COMMENT line(s) only.
#   Do NOT include adjacent code lines in the oldText. The replacement is a same-shape
#   comment (same # prefix, same indent, same line count where possible). This guarantees
#   the function bodies are byte-identical pre/post.

# Pattern C — match by TEXT, never line number:
#   research_meta_refs.md line numbers are the PRE-S1 baseline. S1 shifted lines below
#   ~3439 down by ~9. The edit tool matches exact text, so use the quoted oldText. If a
#   match fails, re-read the region (grep for a unique substring like "MIRRORS pool_dispatch_classify"
#   or "rc 0 ALWAYS (no guard)") to find the current exact text, then edit.

# Pattern D — selftest deletion removes it from compgen discovery:
#   validate.sh's _run_selftest_suite (line 752) discovers selftests via
#   `compgen -A function | grep '^selftest_'`. Deleting the function DEFINITION removes it
#   from compgen output — no registration list, no _run_selftest_suite edit needed. (Same
#   mechanism as run_test at line 246 for test_* functions.) Do NOT touch the compgen code.

# Pattern E — respect the S1/S2 boundary (DO NOT touch):
#   * pool_wrapper_main (S1's scope — step-c already deleted, locals already edited).
#   * lib/pool.sh ~3439–3447, ~3468, ~3499–3501 (S1's comment edits — already correct).
#   * references/configuration.md (S1's doc rewrite — already "pool verbs vs driving").
#   * test/transparency.sh (P1.M2.T1.S1 — owns the passthrough tests + their comments).
#   * README.md (P1.M3.T1.S1 — Mode B cross-cutting docs).
#   * bin/agent-browser-pool (read-only; already the sole classifier).
```

### Integration Points

```yaml
CODE (in-place edits in 2 files, no new files):
  - lib/pool.sh:3012–3128     contract comment + pool_dispatch_classify (DELETE ~117 lines)
  - lib/pool.sh:~3135         arg-normalization banner comment (reword 1 line)
  - lib/pool.sh:~3157,3176,3186  pool_normalize_close header/body comments (reword 3 lines)
  - lib/pool.sh:~3313,3352    pool_strip_session_args header comments (reword 2 lines)
  - lib/pool.sh:~3487         rc-taxonomy comment (drop pool_dispatch_classify from list)
  - lib/pool.sh:~3658         _pool_clean_args_is_bare_connect header comment (reword 1 line)
  - lib/pool.sh:~3707         _pool_clean_args_is_close header comment (reword 1 line)
  - test/validate.sh:345–384  selftest_dispatch_classify_cases + header (DELETE ~40 lines)

DOCS:
  - .agents/skills/agent-browser-pool/SKILL.md:55–65  rewrite "Which commands trigger a lane"
  - .agents/skills/agent-browser-pool/SKILL.md:143–145 "meta-vs-driving" → "pool-verbs-vs-driving"

DO NOT TOUCH:
  - lib/pool.sh pool_wrapper_main (~3439–3548)        S1's scope (already done)
  - .agents/.../references/configuration.md            S1's doc deliverable (already correct)
  - test/transparency.sh                               P1.M2.T1.S1 (passthrough tests + comments)
  - README.md                                          P1.M3.T1.S1 (Mode B cross-cutting docs)
  - bin/agent-browser-pool                             read-only; already the sole classifier
  - lib/pool.sh:580,1005,2089–2099                     owner-passthrough (concept #2, UNRELATED)

CONFIG: none (no env vars change).
ROUTES: none.
DATABASE: none.
```

## Validation Loop

> **AGENTS.md §1/§2 compliance**: ALL validation here is STATIC. `bash -n` + `shellcheck`
> + `grep` only. Do NOT run `_run_selftest_suite`, do NOT run the test suite, do NOT boot
> Chrome. The selftest deletion is verified by grep (function absent from compgen
> discovery), not by execution.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH file's edits — fix before proceeding.
bash -n lib/pool.sh                       # parse check. MUST be clean (no output).
bash -n test/validate.sh                  # MUST be clean (no output).
shellcheck -s bash lib/pool.sh            # MUST rc 0, 0 findings (fully silent).
shellcheck -s bash test/validate.sh       # MUST rc 0 (may emit SC1091/SC2016 INFO wiki
                                         #   links — same as pre-S2 baseline; those are not findings).
# Expected: bash -n silent on both; shellcheck rc 0 on both.
# The pre-S2 baseline is already clean on both files (verified). The edits only DELETE a
# function + its selftest caller and reword comments — they CANNOT introduce a shellcheck
# warning. If shellcheck fires, you changed code beyond the quoted edits — revert and redo.
```

### Level 2: Unit Tests (Component Validation)

```bash
# There is NO new unit test in this subtask, and NO existing selftest is run (the one that
# tested pool_dispatch_classify is itself deleted in Task 5). Validation is by STATIC GREP:

# 2a. pool_dispatch_classify is GONE from lib/pool.sh and test/validate.sh:
grep -n 'pool_dispatch_classify' lib/pool.sh test/validate.sh
# Expected: ZERO output.

# 2b. selftest_dispatch_classify_cases is GONE from test/validate.sh:
grep -n 'selftest_dispatch_classify' test/validate.sh
# Expected: ZERO output.

# 2c. The 4 sibling functions are INTACT (logic unchanged — only comments edited):
grep -n 'pool_normalize_close()\|pool_strip_session_args()\|_pool_clean_args_is_bare_connect()\|_pool_clean_args_is_close()' lib/pool.sh
# Expected: exactly 4 hits (one per function definition).

# 2d. The deleted function is absent from compgen discovery (the mechanism, not a live run):
bash -c 'set -euo pipefail; source lib/pool.sh; compgen -A function | grep pool_dispatch_classify' ; echo "exit=$?"
# Expected: no output + exit=1 (grep found nothing). This is the static proof that
#           _run_selftest_suite (which uses the same compgen pipeline for '^selftest_') will
#           no longer find selftest_dispatch_classify_cases.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. lib/pool.sh still parses + sources cleanly under strict mode (S1's deliverable intact):
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_wrapper_main pool_normalize_close pool_strip_session_args _pool_clean_args_is_bare_connect _pool_clean_args_is_close'
# Expected: all 5 reported as functions. (Confirms the deletion didn't orphan anything.)

# 3b. test/validate.sh still parses + its discovery runner is intact:
bash -c 'set -euo pipefail; source test/validate.sh; type _run_selftest_suite run_test'
# Expected: both reported as functions. (Confirms the selftest deletion didn't break the runner.)
# NOTE: validate.sh may require setup() state to RUN; this only checks it SOURCES + the
#       runner functions exist. Do NOT call _run_selftest_suite (it spawns processes — AGENTS.md).

# 3c. SKILL.md no longer teaches the removed model:
grep -n 'pass straight through\|WITHOUT acquiring a lane\|meta-vs-driving' .agents/skills/agent-browser-pool/SKILL.md
# Expected: ZERO output.
grep -n 'pool-verbs-vs-driving\|Every command except pool verbs' .agents/skills/agent-browser-pool/SKILL.md
# Expected: at least one hit (the new wording).

# 3d. configuration.md (S1's deliverable) is UNCHANGED by S2 (regression guard):
grep -n 'Command dispatch: pool verbs vs driving' .agents/skills/agent-browser-pool/references/configuration.md
# Expected: ONE hit (S1's heading — still present, S2 did not touch it).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm ZERO `pool_dispatch_classify` references remain in the SHIPPED code+S2-owned docs:
grep -rn 'pool_dispatch_classify' lib/pool.sh test/validate.sh .agents/skills/agent-browser-pool/SKILL.md
# Expected: ZERO output across all three files.

# 4b. Confirm the KNOWN cross-cutting residual is correctly LEFT for P1.M2.T1.S1 (not S2's job):
grep -n 'pool_dispatch_classify' test/transparency.sh
# Expected: ONE hit at line ~267 (a comment inside test_version_passthrough). This is OWNED BY
#           P1.M2.T1.S1 (the test-replacement subtask). Do NOT fix it here. Documenting it so
#           the implementer knows the non-zero grep on transparency.sh is EXPECTED post-S2.
#           (The item contract's grep-zero goal is scoped to lib/pool.sh + test/validate.sh.)

# 4c. Confirm the owner-passthrough "passthrough" comments are correctly RETAINED (concept #2):
grep -n 'passthrough' lib/pool.sh | head -20
# Expected: several hits around lines 402–403, 497–498, 580–581, 1005–1006, 2089–2099, 2149
#           (owner-passthrough = POOL_OWNER_PID==0). These are UNRELATED to META dispatch and
#           MUST remain. Their presence is correct, not a missed cleanup.

# 4d. Confirm the bin dispatcher is now the SOLE command classifier (Issue 4 closed):
grep -n 'pool_dispatch_classify\|case "\$cmd"\|pool_wrapper_main "\$@"' bin/agent-browser-pool
# Expected: ZERO pool_dispatch_classify hits; the case statement + pool_wrapper_main "$@" arm
#           are the single routing point. (bin was already correct; this confirms S2 didn't
#           need to touch it and didn't.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `bash -n test/validate.sh` clean (zero output).
- [ ] `shellcheck -s bash lib/pool.sh` rc 0, 0 findings.
- [ ] `shellcheck -s bash test/validate.sh` rc 0 (INFO wiki links OK).
- [ ] Level 2 snippet 2a: `grep pool_dispatch_classify lib/pool.sh test/validate.sh` → zero.
- [ ] Level 2 snippet 2b: `grep selftest_dispatch_classify test/validate.sh` → zero.
- [ ] Level 2 snippet 2c: the 4 sibling functions still defined (4 hits).
- [ ] Level 2 snippet 2d: `compgen -A function` no longer lists `pool_dispatch_classify` (grep exit 1).

### Feature Validation

- [ ] `lib/pool.sh` no longer defines `pool_dispatch_classify` (Task 1).
- [ ] `lib/pool.sh` has ZERO `pool_dispatch_classify` string occurrences (Tasks 1–4).
- [ ] The 4 sibling functions' BODIES are byte-identical to pre-S2 (Tasks 2–4 touched comments only).
- [ ] `test/validate.sh` no longer defines `selftest_dispatch_classify_cases` + its header (Task 5).
- [ ] `SKILL.md` "Which commands trigger a lane" describes every non-pool-verb as driving (Task 6).
- [ ] `SKILL.md` reference pointer says "pool-verbs-vs-driving" (Task 7).

### Code Quality Validation

- [ ] Edit-tool oldText blocks matched byte-for-byte (no approximations; re-read on mismatch).
- [ ] No CODE beyond the quoted edits was touched (diff = 1 block delete in pool.sh + 7 comment-line rewording + 1 block delete in validate.sh + 2 SKILL.md edits).
- [ ] shellcheck baseline preserved on both files (were 0 findings, still 0 findings).
- [ ] No scope creep into S1 (pool_wrapper_main, configuration.md), P1.M2.T1.S1 (transparency.sh), or P1.M3.T1.S1 (README.md).
- [ ] Comment style matches existing (`# GOTCHA — PREFIX`, PRD §-citations, `===...` banners).
- [ ] Owner-passthrough comments (concept #2) correctly retained (Level 4 snippet 4c).

### Documentation & Deployment

- [ ] `SKILL.md` describes the post-fix dispatch model accurately (no "meta → passthrough").
- [ ] `SKILL.md` and S1's `configuration.md` are now consistent (both say "pool verbs vs driving").
- [ ] Mode A satisfied: the skill doc (`SKILL.md`) rode with the code in this subtask.
- [ ] README.md NOT touched (Mode B — P1.M3.T1.S1; its META references sync separately).
- [ ] No new env vars; no config changes; no path changes.

---

## Anti-Patterns to Avoid

- ❌ Don't touch `pool_wrapper_main` or any of S1's edit sites (lib/pool.sh ~3439–3548, configuration.md) — S1 already shipped them.
- ❌ Don't touch `test/transparency.sh` — line 267's `pool_dispatch_classify` comment is inside `test_version_passthrough`, owned by `P1.M2.T1.S1`. "Fixing" it steals that subtask's scope.
- ❌ Don't touch `README.md` — Mode B cross-cutting docs (`P1.M3.T1.S1`).
- ❌ Don't touch `bin/agent-browser-pool` — already the sole classifier (read-only).
- ❌ Don't touch the owner-passthrough comments (lib/pool.sh:580, 1005, 2089–2099) — concept #2, UNRELATED to META dispatch. grep 'passthrough' will STILL return hits after S2; those are correct.
- ❌ Don't touch the `compgen -A function` discovery code (validate.sh:246, 752) — it's generic and correct; deleting the selftest definition is all that's needed.
- ❌ Don't change the BODIES of `pool_normalize_close`, `pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close` — Tasks 2–4 are COMMENT-ONLY rewording.
- ❌ Don't run `_run_selftest_suite`, the test suite, or real Chrome (AGENTS.md §1/§2) — validation is `bash -n` + `shellcheck` + `grep` only.
- ❌ Don't match edit oldText by line number — research_meta_refs.md numbers are pre-S1; S1 shifted lines below ~3439. Match by the exact quoted text; re-read on mismatch.
- ❌ Don't split the contract-comment + function deletion across two edits if they're contiguous — delete as one block (oldText = banner-through-`}`) to avoid an orphaned comment describing a deleted function.
- ❌ Don't leave any `pool_dispatch_classify` reference in lib/pool.sh or test/validate.sh — the contract requires grep-zero on those two files. (transparency.sh is the documented exception, owned by P1.M2.T1.S1.)

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: pure mechanical deletion + comment/doc sync on a fully-documented codebase. Every edit site is quoted byte-for-byte or precisely bounded (verified by direct read on 2026-07-15 of lib/pool.sh, test/validate.sh, and SKILL.md). The change only DELETES dead code (zero call sites post-S1, confirmed) and rewords comments — it cannot introduce new behavior or new shellcheck warnings (both baselines verified clean). The S1/S2 and P1.M2/P1.M3 boundaries are crisp and restated in multiple places, including the one subtle cross-cutting residual (transparency.sh:267) which is explicitly documented as out-of-scope. The -1 reflects residual risk in Task 1's single large block-deletion oldText (~117 lines) — if the implementer retypes it from memory instead of reading the current file, a whitespace mismatch could fail the edit; the mitigation (read lib/pool.sh:3012–3128, copy verbatim) is documented in Pattern A. Level 2 snippet 2a catches any missed reference immediately.
