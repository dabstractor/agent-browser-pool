# PRP — P2.M5.T1.S1: Remove ABPOOL_WRAPPER and DISABLE selftest from validate.sh

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`).
**Work item**: P2.M5.T1.S1 (1 point) — milestone P2.M5 (Test Framework Updates), task T1.
**Dependency / starting state**: Builds on the SHIPPED POST-P2.M2 tree. **Verified LIVE**:
`grep -c 'POOL_DISABLE' lib/pool.sh` → **0** (P2.M1.T1.S1 done — DISABLE fully removed);
`ls bin/` → only `agent-browser-pool` + `.gitkeep` (P2.M2.T2.S1 done — `bin/agent-browser`
DELETED). Consequently `test/validate.sh` currently (a) defines `ABPOOL_WRAPPER` pointing at
the **non-existent** `bin/agent-browser` and (b) keeps a selftest (`selftest_config_bool_via_pool_config_init`)
that asserts `AGENT_BROWSER_POOL_DISABLE` flows to `POOL_DISABLE` — a variable that **no longer
exists**, so that selftest would now **FAIL** (`printf "%s" "$POOL_DISABLE"` → empty →
`assert_eq "1" ""` fails). Both must be removed. The parallel sibling P2.M4.T3.S1 (skill
README) does NOT touch `test/validate.sh` (disjoint). **This item edits exactly ONE file:
`test/validate.sh`.** Full research: `plan/002_97982899bef6/P2M5T1S1/research/notes.md`.

---

## Goal

**Feature Goal**: Make `test/validate.sh` consistent with the shipped no-DISABLE / no-wrapper-shim
explicit-invocation model — remove every reference to the `ABPOOL_WRAPPER` variable (its target
`bin/agent-browser` was deleted in P2.M2.T2.S1) and delete the `selftest_config_bool_via_pool_config_init`
selftest (the `AGENT_BROWSER_POOL_DISABLE → POOL_DISABLE` end-to-end test; `POOL_DISABLE` was
removed in P2.M1.T1.S1) — while keeping the `_pool_config_bool` normalizer selftests (the
normalizer is still used by `pool_config_init` for `headless`/`allow_slow_copy`) and the
`ABPOOL_ADMIN` executable-check (the sole entry point).

**Deliverable**: An edited `test/validate.sh` (4 surgical edits — E1–E4 — all verbatim below)
that: defines no `ABPOOL_WRAPPER`; contains no `POOL_DISABLE`/`AGENT_BROWSER_POOL_DISABLE`; runs
no DISABLE selftest; still pre-flights `bin/agent-browser-pool` (the sole entry point) via
`ABPOOL_ADMIN`; and passes `bash -n` + `shellcheck -s bash` with no NEW findings (the two
pure-normalizer `_pool_config_bool` selftests and all other ~16 selftests are untouched).
**No other file is modified by this item.**

**Success Definition**:
- `grep -c 'ABPOOL_WRAPPER' test/validate.sh` → **0** (the variable is fully gone — def + comment + check).
- `grep -cE 'POOL_DISABLE|AGENT_BROWSER_POOL_DISABLE' test/validate.sh` → **0**.
- `grep -c 'selftest_config_bool_via_pool_config_init' test/validate.sh` → **0** (function + comment deleted).
- `grep -c 'cutover' test/validate.sh` → **0** (the only hit was inside the deleted function's comment).
- `grep -c 'ABPOOL_ADMIN' test/validate.sh` → **≥2** (line-27 def + the kept executable-check; also used by `teardown`).
- `selftest_config_bool_truthy` + `selftest_config_bool_falsy` are PRESENT (the normalizer is still used).
- `bash -n test/validate.sh` → exit 0. `shellcheck -s bash test/validate.sh` → no SC2034/SC2154 for `ABPOOL_WRAPPER`, no new error/warning findings (only the pre-existing SC1091/SC2016 infos remain).
- `git status --short` → only `test/validate.sh` modified by this item.

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21) — "Removed: the `AGENT_BROWSER_POOL_DISABLE` safety valve
  (nothing to bypass)"; "There is **no PATH shadowing** — the real `agent-browser` is never
  intercepted … `agent-browser-pool` (the sole entry point)". The test framework must not keep
  assertions for dead mechanisms. Keeping `ABPOOL_WRAPPER` (→ deleted `bin/agent-browser`) makes
  the `selftest_wrapper_and_admin_are_executable` check fail on every run; keeping the DISABLE
  selftest makes `_run_selftest_suite` report a FAIL. Both now actively contradict shipped behavior.
- **Who it helps**: Anyone running `bash test/validate.sh` (the framework's built-in self-test) —
  right now it would FAIL (non-existent wrapper binary + non-existent `POOL_DISABLE` var). After
  this item the self-test suite is green again against the live model. It also unblocks the next
  test items: P2.M5.T2.S1 (transparency.sh rewrite) and P2.M5.T3.S1 (concurrency/release_reaper
  comments) build on a validate.sh that no longer references the removed symbols.
- **Scope cohesion**: This is item T1.S1 of milestone P2.M5. Its ONLY job is the validate.sh
  framework cleanup. It does NOT rewrite transparency.sh (P2.M5.T2.S1 owns that — it ALSO has
  `ABPOOL_WRAPPER` refs, but that is a separate, larger item). It does NOT touch concurrency.sh /
  release_reaper.sh (P2.M5.T3.S1). It does NOT touch lib/pool.sh, bin/*, install.sh, or any .md
  (each owned by completed/sibling/later items).

---

## What

**User-visible behavior**: None directly — `test/validate.sh` is a test harness, not a shipped
binary. The observable effect is: `bash test/validate.sh` (the self-test) no longer fails on the
removed `ABPOOL_WRAPPER`/`POOL_DISABLE` artifacts; the `_pool_config_bool` normalizer selftests
still run (the normalizer survives); the `ABPOOL_ADMIN` (sole entry point) executable pre-flight
still runs.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `lib/pool.sh` — SHIPPED behavior (P2.M1 done; read-only). `_pool_config_bool` is still used at lines 181-182.
- `bin/agent-browser-pool` — the sole entry point (P2.M2 done; read-only).
- `test/transparency.sh`, `test/concurrency.sh`, `test/release_reaper.sh` — owned by P2.M5.T2.S1 / T3.S1.
- All `*.md`, `install.sh`, `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — read-only / owned elsewhere.
- In `test/validate.sh` itself: every selftest EXCEPT `selftest_config_bool_via_pool_config_init`;
  the `_run_selftest_suite` runner (line 763); all assertion helpers; `setup`/`teardown`; `spawn_sim_owner`.

### Success Criteria

- [ ] `ABPOOL_WRAPPER` variable is fully removed from `test/validate.sh` (def + comment + check = 0 matches).
- [ ] `POOL_DISABLE` / `AGENT_BROWSER_POOL_DISABLE` are fully removed (0 matches).
- [ ] `selftest_config_bool_via_pool_config_init` function + its comment header are deleted (0 matches).
- [ ] `selftest_config_bool_truthy` + `selftest_config_bool_falsy` are UNCHANGED (the normalizer survives).
- [ ] `ABPOOL_ADMIN` is preserved (def line 27 + the kept executable-check + teardown use).
- [ ] The `selftest_wrapper_and_admin_are_executable` wrapper-check line is removed; its comment is rewritten; the admin check is kept (function renamed to `selftest_admin_is_executable` — recommended).
- [ ] `bash -n test/validate.sh` → exit 0; `shellcheck -s bash test/validate.sh` → no new error/warning findings, no SC2034/SC2154 for `ABPOOL_WRAPPER`.
- [ ] Only `test/validate.sh` is modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the 4 edits are given **verbatim** below (exact old → new text blocks,
copy-pasteable into `edit`), with current line numbers and the exact grep/shellcheck assertions.
The one reconciliation that could trip a naive implementer — that the contract/gap_analysis calls
the DISABLE selftest "selftest_config_disable" but its LIVE name is `selftest_config_bool_via_pool_config_init`
— is called out explicitly (§Known Gotchas). The auto-discovery runner (no list to edit) and the
`pool_wrapper_main`-is-unrelated distinction are both explained. No guessing.

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §8
  why: "§8 test/validate.sh — UPDATE: line 26 (ABPOOL_WRAPPER def) remove; line 314
        ([[ -x $ABPOOL_WRAPPER ]] check) remove; lines 346-357 (the DISABLE selftest)
        remove entirely; any other selftest/assertion using ABPOOL_WRAPPER."
  critical: "This IS the contract. NOTE: §8 calls the DISABLE selftest 'selftest_config_disable'
             — a LOOSE name. The LIVE function is 'selftest_config_bool_via_pool_config_init'
             (lines 346-358). Do NOT search for 'selftest_config_disable'; it does not exist."

- item_description: P2.M5.T1.S1 LOGIC (a)-(f)
  why: The precise edit map. (a) delete line 26 ABPOOL_WRAPPER; (b) line 314 wrapper check —
        prefer remove, keep ABPOOL_ADMIN check; (c) delete the DISABLE selftest entirely;
        (d) remove it from the suite-runner list [AUTO — runner uses compgen, see gotcha];
        (e) update wrapper/cutover comments → 'sole entry point'/'explicit invocation';
        (f) bash -n + shellcheck.
  critical: "(d) is a NO-OP on runner code: _run_selftest_suite auto-discovers via
             'compgen -A function | grep ^selftest_'. Deleting the function removes it from
             the suite automatically. Do NOT add/edit any list."

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "Removed: the AGENT_BROWSER_POOL_DISABLE safety valve (nothing to bypass)." + "agent-browser-pool
        (the sole entry point)". Source for deleting the DISABLE selftest and reframing the comment
        as 'sole entry point' / 'explicit invocation'.

- prd: PRD.md §2.18 (h3.22) — Testing & validation
  why: Context for the selftest framework + the single-setup runner constraint (setup() spawns a
        real sim-owner; the self-test BYPASSES abpool_run_suite and uses ONE setup() — see the
        _run_selftest_suite comment, lines 745-762).

- file: lib/pool.sh   (READ only — SHIPPED behavior; P2.M1 done)
  why: >
    VERIFIED LIVE: grep -c POOL_DISABLE → 0; grep -c AGENT_BROWSER_POOL_DISABLE → 0. BUT
    _pool_config_bool is STILL USED at lines 181-182 (headless, allow_slow_copy) → its two
    truth-table selftests (selftest_config_bool_truthy/falsy) MUST STAY. Only the DISABLE
    end-to-end selftest is dead.
  gotcha: "pool_wrapper_main is a LIBRARY function (lib/pool.sh) that dispatches DRIVING commands.
           It is NOT the deleted bin/agent-browser shim. References to 'pool_wrapper_main' in
           validate.sh (lines 427,429,454,458,469,488,500,519) are CORRECT and must NOT be touched.
           Only ABPOOL_WRAPPER (the variable) and the DISABLE selftest are removed."

- file: test/validate.sh   (CURRENT file — EDITED by E1-E4)
  why: The file being edited. Read it to anchor the 4 edits against current line numbers.
  pattern: "The selftest functions are PURE/STATIC (no Chrome, no per-test owners) and run under
           the single-setup _run_selftest_suite. Edits are surgical: delete one var def, delete one
           check line, rewrite two comments, delete one function+comment. Preserve everything else."

- sibling: test/transparency.sh   (P2.M5.T2.S1 — OUT OF SCOPE)
  why: ALSO references ABPOOL_WRAPPER, but its rewrite is a SEPARATE item. Do NOT touch it here.
```

### Current codebase tree (relevant slice)

```bash
test/
├── validate.sh          # EDITED by E1-E4 (this item). ~805 lines → ~795 lines after edits.
├── transparency.sh       # UNTOUCHED (P2.M5.T2.S1 — also has ABPOOL_WRAPPER refs, separate item)
├── concurrency.sh        # UNTOUCHED (P2.M5.T3.S1 — comments only)
└── release_reaper.sh     # UNTOUCHED (P2.M5.T3.S1 — comments only)
bin/
├── agent-browser-pool    # UNTOUCHED (P2.M2 done — the sole entry point)
└── .gitkeep              # UNTOUCHED
# bin/agent-browser — DELETED in P2.M2.T2.S1 (ABPOOL_WRAPPER pointed here → now dangles)
lib/pool.sh               # UNTOUCHED (P2.M1 done; _pool_config_bool still used @181-182)
PRD.md                    # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
test/
└── validate.sh   # EDITED: no ABPOOL_WRAPPER, no POOL_DISABLE, no DISABLE selftest; admin pre-flight kept.
# No new files. No deletions (bin/agent-browser was already deleted in a prior item). No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: the contract/gap_analysis calls the DISABLE selftest "selftest_config_disable" — that
# name does NOT exist in the file. The LIVE function is 'selftest_config_bool_via_pool_config_init'
# (def @ line 350; comment header @ lines 346-349; body to line 358). It is the function whose
# comment says "End-to-end: AGENT_BROWSER_POOL_DISABLE=<truthy> flows through pool_config_init to
# POOL_DISABLE=1. This is the cutover safety-valve contract (PRD §2.17)". DELETE THAT ONE.

# CRITICAL: the selftest runner _run_selftest_suite (line 763) has NO hardcoded list of selftests —
# it does 'compgen -A function | grep ^selftest_ | sort'. Deleting the function AUTOMATICALLY removes
# it from the suite. Contract step (d) is satisfied by the deletion alone. Do NOT touch the runner,
# do NOT add a list. (Line 247 abpool_run_suite is the sourced-mode runner — also auto-discovery.)

# CRITICAL: 'wrapper' the substring will STILL appear ~8 times after a perfect edit — ALL are
# 'pool_wrapper_main' (a LIBRARY function that dispatches driving commands; unrelated to the deleted
# bin/agent-browser shim). They are at lines 427,429,454,458,469,488,500,519 and MUST STAY. The
# validation greps key on 'ABPOOL_WRAPPER' (the variable) — NOT on the bare substring 'wrapper'.

# CRITICAL: do NOT delete selftest_config_bool_truthy / selftest_config_bool_falsy. They test the
# _pool_config_bool NORMALIZER, which lib/pool.sh STILL uses (lines 181-182: headless, allow_slow_copy).
# ONLY the end-to-end DISABLE selftest (selftest_config_bool_via_pool_config_init) is dead.

# CRITICAL: ABPOOL_ADMIN (line 27) is NOT removed — only ABPOOL_WRAPPER (line 26) is. ABPOOL_ADMIN
# is the sole entry point; it is checked in the rewritten selftest AND invoked by teardown (line 224:
# "$ABPOOL_ADMIN" release all). Keep its definition and all its uses.

# CRITICAL (set -u): validate.sh runs under 'set -euo pipefail' (line 23). After deleting the
# ABPOOL_WRAPPER definition, ANY remaining '$ABPOOL_WRAPPER' reference aborts at runtime (unbound
# var). The edit removes the def (line 26), the comment mention (line 313), AND the check (line 314)
# — all three. 'grep -c ABPOOL_WRAPPER' MUST be 0 (the gate enforces this). shellcheck SC2154 also
# catches a stray reference.

# CRITICAL (shellcheck baseline): 'shellcheck -s bash test/validate.sh' exits 1 TODAY with ONLY
# info-level findings (SC1091 line 30 source; SC2016 lines 634/664/694/726 the deliberate single-
# quoted bash -c hermetic subshells). These are PRE-EXISTING and EXPECTED. The gate is NOT
# 'shellcheck exits 0' — it is 'no NEW error/warning findings, and no SC2034/SC2154 for ABPOOL_WRAPPER'.
# A half-edit (def removed but reference kept → SC2154; reference removed but def kept → SC2034) is caught.

# CRITICAL (AGENTS.md §1/§6): validation is STATIC ONLY — bash -n + shellcheck + grep + git status.
# Do NOT run 'bash test/validate.sh' (the selftest suite) as a gate: _run_selftest_suite → setup() →
# spawn_sim_owner spawns a REAL process (sandbox-wedge risk). The suite is optional in a FULLY
# isolated container only; the static checks are authoritative for this pure-removal task.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is 4 surgical edits to one bash test harness. The exact old→new
text for each edit is given verbatim below (copy-pasteable into the `edit` tool).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ + anchor (context — no writes)
  - READ: test/validate.sh  lines 24-27 (the var defs), 311-316 (the wrapper selftest fn),
          320-323 (the _pool_config_bool section-header comment), 346-358 (the DISABLE selftest fn),
          763-788 (the _run_selftest_suite runner — confirm it uses compgen, NO list).
  - CONFIRM (read-only): grep -c POOL_DISABLE lib/pool.sh → 0; ls bin/ → no agent-browser;
           grep -n '_pool_config_bool' lib/pool.sh → still used @181-182 (normalizer selftests stay).
  - WHY: anchor the 4 edits against current line numbers + confirm the shipped state justifies each removal.

Task 2: EDIT test/validate.sh  — apply E1, E2, E3, E4 (the deliverable)
  - EDIT (E1): delete the ABPOOL_WRAPPER definition line (current line 26).
  - EDIT (E2): rewrite the selftest_wrapper_and_admin_are_executable function (current lines 311-316)
               → renamed selftest_admin_is_executable, wrapper-check line removed, comment rewritten,
               admin check kept (verbatim target in §Edit Targets below).
  - EDIT (E3): update the _pool_config_bool section-header comment (current lines 320-323) — drop the
               "(+ one end-to-end through pool_config_init)" clause (that test is being deleted).
  - EDIT (E4): delete the DISABLE selftest's comment block + function (current lines 346-358) entirely;
               collapse surrounding blank lines to a single separator.
  - WHY: gap_analysis §8 + item LOGIC (a)-(f) + PRD §2.17. Removes dead artifacts (non-existent
         bin/agent-browser + non-existent POOL_DISABLE); keeps the surviving normalizer selftests
         and the sole-entry-point admin pre-flight.
  - NOTE: all 4 edits can be applied in ONE 'edit' call (4 entries in edits[]) since their oldText
          blocks are disjoint and unique. Each oldText below is verified unique in the current file.
  - BUCKET: required (the entire deliverable is these 4 edits to one file).

Task 3: STATIC VALIDATION  (AGENTS.md §1: static only — no execution)
  - RUN: bash -n test/validate.sh  (expect exit 0).
  - RUN: shellcheck -s bash test/validate.sh  (expect ONLY the pre-existing SC1091/SC2016 infos;
         assert NO SC2034/SC2154 for ABPOOL_WRAPPER, no new error/warning — see §Validation Loop L1).
  - RUN: the grep assertions in §Validation Loop Level 1 (removals → 0; ABPOOL_ADMIN preserved;
         normalizer selftests present).
  - RUN: git status --short  (expect ONLY test/validate.sh modified by this item).
  - WHY: contract step (f) + AGENTS.md §1/§6. No Chrome, no daemons, no test-suite run.
  - BUCKET: required.
```

#### Edit Targets (verbatim old → new — copy-pasteable into `edit`)

> All `oldText` blocks are verified UNIQUE in the current `test/validate.sh`. Apply as a single
> `edit` call with 4 `edits[]` entries, or as 4 sequential edits. Line numbers are current
> anchors (the edit matches on exact text, so line drift from earlier edits is irrelevant when
> applied as one call).

**E1 — delete the `ABPOOL_WRAPPER` definition (line 26):**

oldText (lines 26-27):
```
ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"
ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"
```
newText:
```
ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"
```
*(Removes line 26; keeps line 27 `ABPOOL_ADMIN`.)*

**E2 — rewrite the wrapper/admin executable-check selftest (lines 311-316):**

oldText (lines 311-316):
```
selftest_wrapper_and_admin_are_executable() {
    # Pre-flight the two binaries downstream tests invoke by ABSOLUTE PATH (PRD §2.17).
    # (Also consumes ABPOOL_WRAPPER/ABPOOL_ADMIN so they aren't shellcheck-SC2034-unused.)
    [[ -x "$ABPOOL_WRAPPER" ]] || { _fail "wrapper not executable: $ABPOOL_WRAPPER"; return 1; }
    [[ -x "$ABPOOL_ADMIN"   ]] || { _fail "admin not executable: $ABPOOL_ADMIN";   return 1; }
}
```
newText:
```
selftest_admin_is_executable() {
    # Pre-flight the sole entry point (bin/agent-browser-pool) downstream tests invoke by
    # ABSOLUTE PATH — the explicit-invocation model (PRD §2.17: no PATH shadowing, one entry
    # point). Also consumes ABPOOL_ADMIN so it isn't shellcheck-SC2034-unused.
    [[ -x "$ABPOOL_ADMIN" ]] || { _fail "admin not executable: $ABPOOL_ADMIN"; return 1; }
}
```
*(Renames the function so the name no longer lies; removes the `[[ -x "$ABPOOL_WRAPPER" ]]`
line; rewrites the comment (two binaries → sole entry point; drops the ABPOOL_WRAPPER SC2034
note; references explicit invocation); KEEPS the `[[ -x "$ABPOOL_ADMIN" ]]` check. The runner
auto-discovers by the `selftest_` prefix, so the rename needs zero runner changes.)*

**E3 — update the `_pool_config_bool` section-header comment (lines 320-323):**

oldText (lines 320-323):
```
# --- _pool_config_bool truth-table (P1.M1.T1.S1) -------------------------------
# Pure-function bodies: exercise the normalizer directly (+ one end-to-end through
# pool_config_init). No Chrome, no sim-owner, no persistent lease writes. Picked up
# by the single-setup _run_selftest_suite above (same runner as the other selftest_*).
```
newText:
```
# --- _pool_config_bool truth-table (P1.M1.T1.S1) -------------------------------
# Pure-function bodies: exercise the normalizer directly. No Chrome, no sim-owner,
# no persistent lease writes. Picked up by the single-setup _run_selftest_suite above
# (same runner as the other selftest_*).
```
*(Drops the "(+ one end-to-end through pool_config_init)" clause — that was the DISABLE
selftest being deleted in E4; the section now holds only the two normalizer selftests.)*

**E4 — delete the DISABLE selftest (comment block lines 346-349 + function lines 350-358):**

oldText (lines 345-359 — includes the leading blank separator through the closing brace + one
trailing blank, to collapse cleanly to a single separator):
```

# End-to-end: AGENT_BROWSER_POOL_DISABLE=<truthy> flows through pool_config_init to
# POOL_DISABLE=1. This is the cutover safety-valve contract (PRD §2.17) that motivated
# the fix. Runs pool_config_init in an ISOLATED subshell so it cannot clobber the
# selftest suite's own POOL_* globals (set by the single setup() call).
selftest_config_bool_via_pool_config_init() {
    local d
    d="$(AGENT_BROWSER_POOL_DISABLE=true bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=true -> POOL_DISABLE=1" || return 1
    d="$(AGENT_BROWSER_POOL_DISABLE=yes bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=yes -> POOL_DISABLE=1" || return 1
    d="$(AGENT_BROWSER_POOL_DISABLE=0 bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
    assert_eq "0" "$d" "AGENT_BROWSER_POOL_DISABLE=0 -> POOL_DISABLE=0" || return 1
}

```
newText:
```

```
*(Deletes the comment header + the entire `selftest_config_bool_via_pool_config_init`
function, collapsing the double blank (between `selftest_config_bool_falsy`'s `}` and the
next `# --- pool_dispatch_classify …` header) to a single separator. NOTE: if your editor
matches on the function alone (without the leading/trailing blanks), ensure exactly ONE blank
line remains between `selftest_config_bool_falsy`'s closing `}` and the
`# --- pool_dispatch_classify full table …` header.)*

> **E4 leading-blank caveat:** the `oldText` above begins with a blank line (the separator
> AFTER `selftest_config_bool_falsy`'s `}` at line 343/344). If the file has the blank at line
> 345, this matches. Verify with `sed -n '343,360p' test/validate.sh` before editing. The goal:
> after E4, exactly ONE blank line separates `selftest_config_bool_falsy`'s `}` from the
> `# --- pool_dispatch_classify` header.

### Implementation Patterns & Key Details

```bash
# PATTERN — pure removal, no logic change. None of the ~16 SURVIVING selftests change behavior.
#   The edit only (a) drops a dangling var, (b) drops a dead check line + renames its fn,
#   (c) trims a comment clause, (d) deletes a dead function. The harness's runners, helpers,
#   setup/teardown, and all other selftests are byte-identical afterward.

# PATTERN — the runner is auto-discovery, so deletion IS the suite update. _run_selftest_suite
#   (line 767): 'for fn in $(compgen -A function | grep "^selftest_" | sort)'. Delete the fn →
#   it's gone from the suite next run. No list edit. (Same for abpool_run_suite @ line 247,
#   the sourced-mode runner — unrelated to selftests but same compgen pattern.)

# GOTCHA — 'wrapper' ≠ 'ABPOOL_WRAPPER'. After the edit, 'grep wrapper test/validate.sh' still
#   returns ~8 lines: all 'pool_wrapper_main' (the LIBRARY driving-dispatcher; lines 427,429,
#   454,458,469,488,500,519). Those are CORRECT — leave them. The validation keys on the
#   VARIABLE 'ABPOOL_WRAPPER' (→ must be 0), not the bare substring 'wrapper'.

# GOTCHA — the renamed function (selftest_admin_is_executable) is still auto-discovered. The
#   runner sorts 'selftest_*' alphabetically; the rename changes sort position cosmetically but
#   breaks nothing (the runner tallies pass/fail per fn, order-independent). If you prefer NOT to
#   rename, you may keep 'selftest_wrapper_and_admin_are_executable' — but you MUST still remove
#   the [[ -x "$ABPOOL_WRAPPER" ]] line and rewrite the comment (a lying name is the only cost).
#   The rename is RECOMMENDED for honesty.

# GOTCHA — keep selftest_config_bool_truthy + selftest_config_bool_falsy. They test _pool_config_bool,
#   which lib/pool.sh STILL uses (lines 181-182). Only the END-TO-END DISABLE test is dead.

# GOTCHA — shellcheck exit code. 'shellcheck -s bash test/validate.sh' exits 1 TODAY (pre-existing
#   SC1091 + SC2016 infos). Do not treat exit 1 as failure. Assert: no SC2034, no SC2154, no new
#   error/warning-level codes. (See §Validation Loop L1 for the exact assertion.)
```

### Integration Points

```yaml
NONE for this item beyond the single test file.
  - No code, no config, no env vars, no binaries are introduced or removed BY THIS ITEM (bin/agent-browser
    was deleted by the PRIOR item P2.M2.T2.S1; POOL_DISABLE was removed by P2.M1.T1.S1).
  - This item CONSUMES (does not modify):
      * lib/pool.sh — the SHIPPED no-DISABLE behavior (P2.M1 done). _pool_config_bool still used @181-182.
      * bin/agent-browser-pool — the sole entry point whose executability the kept admin-check pre-flights.
  - Downstream consumers that build on this LATER (NOT here):
      * test/transparency.sh (P2.M5.T2.S1) — will rewrite its own ABPOOL_WRAPPER invocations → ABPOOL_ADMIN.
      * test/concurrency.sh + release_reaper.sh (P2.M5.T3.S1) — comment updates only.
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`bash -n`, `shellcheck`, `grep`, `sed`, `git`).
> **Do NOT run `bash test/validate.sh`, do NOT run any `test/*.sh`, do NOT boot Chrome, do NOT invoke
> `agent-browser`/`agent-browser-pool` during this item.** This is a pure-removal edit; the static
> checks below are authoritative. (An optional isolated-sandbox selftest run is discussed in Level 3
> but is NOT a gate.)

### Level 1: Syntax, lint & content (run after the 4 edits)

```bash
cd /home/dustin/projects/agent-browser-pool
F=test/validate.sh

# --- syntax (contract step f) ---
bash -n "$F" && echo "OK: bash -n" || echo "FAIL: bash -n"

# --- lint (contract step f): assert NO SC2034/SC2154 for ABPOOL_WRAPPER + no NEW error/warning ---
# Baseline today = only SC1091 (info, line 30) + SC2016 (info, x4). Capture full output:
shellcheck -s bash "$F" > /tmp/sc_after.txt 2>&1; sc_rc=$?
# 1) no ABPOOL_WRAPPER unbound/unused:
if grep -qE 'SC2034|SC2154' /tmp/sc_after.txt && grep -qi 'ABPOOL_WRAPPER' /tmp/sc_after.txt; then
  echo "FAIL: shellcheck flags ABPOOL_WRAPPER (SC2034/SC2154 — half-removed)"; grep -E 'SC2034|SC2154' /tmp/sc_after.txt
else
  echo "OK: no shellcheck SC2034/SC2154 for ABPOOL_WRAPPER"
fi
# 2) only the pre-existing info codes remain (SC1091, SC2016) — no new error/warning:
newcodes=$(grep -oE 'SC[0-9]+' /tmp/sc_after.txt | sort -u | tr '\n' ' ')
echo "shellcheck codes present: $newcodes"
for c in $newcodes; do
  case "$c" in
    SC1091|SC2016) : ;;                      # pre-existing infos — expected
    *) echo "FAIL: unexpected NEW shellcheck code $c (review /tmp/sc_after.txt)";;
  esac
done
echo "(if no FAIL above) OK: no new error/warning findings"

# --- REMOVALS: each grep MUST find ZERO matches ---
for pat in 'ABPOOL_WRAPPER' 'POOL_DISABLE' 'AGENT_BROWSER_POOL_DISABLE' \
           'selftest_config_bool_via_pool_config_init' 'cutover'; do
    n=$(grep -cE "$pat" "$F" || true)
    [ "$n" -eq 0 ] && echo "OK: absent: $pat" || echo "FAIL: found $n x [$pat]"
done

# --- the DEAD function name is gone, and the OLD lying name is gone (if renamed) ---
grep -q 'selftest_wrapper_and_admin_are_executable' "$F" \
  && echo "NOTE: old fn name kept (acceptable iff wrapper line+comment fixed; rename was recommended)" \
  || echo "OK: old fn name removed (renamed to selftest_admin_is_executable)"
grep -q 'selftest_admin_is_executable' "$F" \
  && echo "OK: renamed fn present" \
  || echo "NOTE: renamed fn absent (old name kept — verify E2 still dropped the wrapper line)"

# --- ADDITIONS / PRESERVES: each MUST match ---
grep -q 'ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"' "$F" && echo "OK: ABPOOL_ADMIN def preserved" || echo "FAIL: ABPOOL_ADMIN def lost"
grep -q '[[ -x "$ABPOOL_ADMIN" ]]' "$F" && echo "OK: admin executable-check kept" || echo "FAIL: admin check lost"
grep -q 'selftest_config_bool_truthy' "$F" && echo "OK: normalizer truthy selftest kept" || echo "FAIL: truthy selftest lost"
grep -q 'selftest_config_bool_falsy' "$F"  && echo "OK: normalizer falsy selftest kept"  || echo "FAIL: falsy selftest lost"
grep -q 'sole entry point' "$F" && echo "OK: rewritten comment (sole entry point)" || echo "FAIL: comment not rewritten"

# --- the runner is UNCHANGED (auto-discovery intact) ---
grep -q 'compgen -A function | grep '"'"'^selftest_'"'"' | sort' "$F" && echo "OK: _run_selftest_suite auto-discovery intact" || echo "FAIL: runner changed (must stay compgen)"

# --- 'wrapper' substring is allowed to remain ONLY as pool_wrapper_main (library fn) ---
bad=$(grep -n 'wrapper' "$F" | grep -v 'pool_wrapper_main' || true)
[ -z "$bad" ] && echo "OK: all remaining 'wrapper' refs are pool_wrapper_main (correct)" || { echo "FAIL: non-pool_wrapper_main 'wrapper' refs:"; echo "$bad"; }
```

**Expected**: `bash -n` → OK; shellcheck → no SC2034/SC2154 for ABPOOL_WRAPPER, only SC1091/SC2016
infos; all 5 removal greps → 0; ABPOOL_ADMIN def + admin check + both normalizer selftests +
'sole entry point' comment + compgen runner all present; every remaining 'wrapper' is `pool_wrapper_main`.

### Level 2: Component Validation — N/A (static by design)

The selftest functions are PURE/STATIC (no Chrome, no per-test owners); their "correctness" after
this edit is enforced by Level 1 (the surviving selftests are byte-identical; only the dead DISABLE
selftest + the wrapper var/check are gone). There is no component runtime to exercise here — and
per AGENTS.md §1 we do NOT execute the suite. Live exercise of the full selftest suite is the
optional Level-3 check.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# The behavior validate.sh tracks is SHIPPED (read-only sanity greps — no execution):
grep -q 'POOL_DISABLE' lib/pool.sh && echo "FAIL: lib still has POOL_DISABLE (P2.M1 not done?)" || echo "OK: lib has no POOL_DISABLE (selftest deletion is justified)"
ls bin/agent-browser 2>/dev/null && echo "FAIL: bin/agent-browser still present (P2.M2 not done?)" || echo "OK: bin/agent-browser absent (ABPOOL_WRAPPER removal is justified)"
grep -q '_pool_config_bool' lib/pool.sh && echo "OK: _pool_config_bool still in lib (normalizer selftests correctly kept)" || echo "FAIL: _pool_config_bool gone (then truthy/falsy selftests are dead too)"

# Scope: NO file OUTSIDE test/validate.sh was modified by THIS item.
git status --short
git status --short | grep -vE '^.{2} test/validate\.sh$' \
  && echo "FAIL: changes outside test/validate.sh" || echo "OK: only test/validate.sh modified"

# Confirm siblings/SHIPPED files are untouched by this item:
for f in lib/pool.sh bin/agent-browser-pool install.sh README.md \
         .agents/skills/agent-browser-pool/SKILL.md \
         .agents/skills/agent-browser-pool/README.md \
         .agents/skills/agent-browser-pool/references/configuration.md \
         test/transparency.sh test/concurrency.sh test/release_reaper.sh; do
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done
test -f test/validate.sh && echo "OK: validate.sh present" || echo "FAIL: validate.sh missing"

# OPTIONAL (NOT a gate; ONLY in a fully isolated container/bwrap/temp-tree per AGENTS.md §1/§3):
#   running the selftest suite confirms the remaining ~16 selftests still pass (they should —
#   unchanged) and that the deleted DISABLE selftest no longer runs. It spawns a REAL sim-owner
#   process (spawn_sim_owner via the single setup()), so NEVER run it in the shared sandbox.
#   If you do run it isolated: 'timeout 120 bash test/validate.sh; echo rc=$?' — expect rc 0.
#   The static Level-1 checks are authoritative; this run is extra confidence only.
```

### Level 4: Creative & Domain-Specific Validation — N/A

A test-harness comment/function removal has no domain runtime. Its correctness is fully pinned by
Level 1-3 (static syntax/lint/content + scope) + the shipped-behavior anchors in §Documentation.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n test/validate.sh` → exit 0.
- [ ] `shellcheck -s bash test/validate.sh` → no SC2034/SC2154 for `ABPOOL_WRAPPER`; only the
      pre-existing SC1091/SC2016 infos remain (no new error/warning codes).
- [ ] All 5 removal greps → 0 (`ABPOOL_WRAPPER`, `POOL_DISABLE`, `AGENT_BROWSER_POOL_DISABLE`,
      `selftest_config_bool_via_pool_init`...``, `cutover`).
- [ ] Scope: only `test/validate.sh` modified by this item.

### Feature Validation

- [ ] `ABPOOL_WRAPPER` variable fully removed (def + comment + check).
- [ ] `ABPOOL_ADMIN` def + admin executable-check preserved; the DISABLE selftest deleted.
- [ ] `selftest_config_bool_truthy` + `selftest_config_bool_falsy` UNCHANGED (normalizer survives).
- [ ] The wrapper/admin selftest: wrapper-check line removed, comment rewritten ("sole entry point"),
      admin check kept (function renamed `selftest_admin_is_executable` — recommended).
- [ ] `_run_selftest_suite` runner UNCHANGED (compgen auto-discovery intact).
- [ ] Every remaining `wrapper` reference is `pool_wrapper_main` (the library driving-dispatcher).

### Code Quality / Scope Validation

- [ ] **Only** `test/validate.sh` is modified by this item.
- [ ] `lib/pool.sh`, `bin/*`, `install.sh`, all `*.md`, `test/transparency.sh`,
      `test/concurrency.sh`, `test/release_reaper.sh` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no test-suite run) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] No external doc files change (the contract's DOCS note). Internal test comments are
      updated inline (E2 comment rewrite + E3 section-header trim).
- [ ] The test harness no longer references dead mechanisms (`ABPOOL_WRAPPER`, `POOL_DISABLE`),
      consistent with the shipped no-DISABLE / sole-entry-point model (PRD §2.17).

---

## Anti-Patterns to Avoid

- ❌ Don't search for a function literally named `selftest_config_disable` — it does NOT exist. The
      DISABLE selftest is `selftest_config_bool_via_pool_config_init` (lines 346-358). Delete THAT.
- ❌ Don't edit the `_run_selftest_suite` runner to "remove the DISABLE selftest from the list" —
      there is NO list (it uses `compgen` auto-discovery). Deleting the function IS the removal.
- ❌ Don't delete `selftest_config_bool_truthy` / `selftest_config_bool_falsy` — they test the
      `_pool_config_bool` normalizer, which `lib/pool.sh` STILL uses (lines 181-182). Only the
      end-to-end DISABLE selftest is dead.
- ❌ Don't remove `ABPOOL_ADMIN` (line 27) — only `ABPOOL_WRAPPER` (line 26) goes. `ABPOOL_ADMIN` is
      the sole entry point; it's checked in the rewritten selftest + invoked by `teardown`.
- ❌ Don't touch `pool_wrapper_main` references (lines 427,429,454,458,469,488,500,519) — that's a
      LIBRARY function (driving-command dispatcher), NOT the deleted `bin/agent-browser` shim. They stay.
- ❌ Don't leave a dangling `$ABPOOL_WRAPPER` reference (under `set -u` it aborts at runtime; shellcheck
      SC2154 catches it). The edit removes def + comment + check — `grep -c ABPOOL_WRAPPER` must be 0.
- ❌ Don't treat `shellcheck` exit 1 as failure — it's 1 TODAY (pre-existing SC1091/SC2016 infos). The
      gate is "no SC2034/SC2154 for ABPOOL_WRAPPER + no new error/warning codes".
- ❌ Don't run `bash test/validate.sh` (the selftest suite) as a gate or in the shared sandbox — it
      spawns a real sim-owner process (sandbox-wedge risk, AGENTS.md §1/§3/§4). Static checks suffice.
- ❌ Don't edit `test/transparency.sh` / `concurrency.sh` / `release_reaper.sh` here — each is a sibling
      item (P2.M5.T2.S1 / T3.S1). This item touches ONLY `test/validate.sh`.

---

## Confidence Score

**9/10** — one-pass success likelihood. The item is a pure-removal edit of ONE bash file, and the
PRP supplies all 4 edits **verbatim** (exact old→new text blocks, copy-pasteable into `edit`), so
there is no ambiguity about what to write. The one trap that could stall a naive implementer —
the contract/gap_analysis calls the DISABLE selftest `selftest_config_disable` but its LIVE name is
`selftest_config_bool_via_pool_config_init` — is called out in §Known Gotchas, §Documentation, and
§Anti-Patterns (three reinforcements). The auto-discovery runner (no list to edit) and the
`pool_wrapper_main`-is-unrelated distinction are both explicit. Validation is entirely static
(`bash -n` + `shellcheck` + `grep` + `git`) and CANNOT wedge the sandbox (AGENTS.md §1); shellcheck
SC2034/SC2154 specifically catches any half-removal of `ABPOOL_WRAPPER`. Every claim is pinned to a
verified LIVE anchor (`grep -c POOL_DISABLE lib/pool.sh` → 0; `ls bin/` → no agent-browser;
`_pool_config_bool` still used @181-182). Not 10/10 only because the E4 blank-line collapse depends
on the exact surrounding whitespace (the PRP gives the precise oldText including the leading blank +
a `sed` pre-check command to confirm it), and the function rename, while recommended, is technically
optional — both are fully addressed but introduce minor implementer discretion.
