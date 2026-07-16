# PRP — P3.M2.T1.S3: Update `transparency.sh` fail-fast poll to match new R3 message text

**Work item:** P3.M2.T1.S3 (0.5 points) — parent P3.M2.T1 (Multi-harness owner-simulation test
coverage), milestone P3.M2 (Test coverage). PRD §2.18 (Testing & validation), §2.4 step 1
(owner resolution → fail-fast). Depends on **P3.M1.T1.S3 (Complete)** which changed the
`pool_die` fail-fast message wording.
**Type:** Test-only — substring-literal + comment edits inside ONE existing test function in
`test/transparency.sh`. **No user/config/API surface change. No docs. No structural change.**
**Phase constraint:** This is a PLANNING-phase deliverable. Per AGENTS.md §1, validation here
is **static only** (`bash -n`, `shellcheck`). **Do NOT run the test suite** (it spawns
real Chrome / `setsid` processes). The implementing agent runs the suite isolated + bounded
per AGENTS.md §2 (and only after the residual-risk item in §"Residual Risk" is also landed —
see that section).

---

## Goal

**Feature Goal:** Make `test/transparency.sh::test_driving_no_pi_ancestor_fails_fast` (and its
header comment) assert against P3.M1.T1.S3's NEW fail-fast message text instead of the now-stale
literal substring `pi ancestor`. P3.M1.T1.S3 (Complete) generalized owner resolution (PRD §2.4
step 1 / Decision O9) and changed the `pool_die` first line from
"…require a pi ancestor…" to "…require a supported agent harness (pi/claude/codex/agy)…". The
test polls a temp file for that message via a `[[ "$msg" == *"pi ancestor"* ]]` substring match
— a guaranteed **false-negative** against the new text (the poll never matches → the test loops
to its 10s deadline → reports "did NOT fail fast"). This item restores the match.

**Deliverable:** In `test/transparency.sh`, within `test_driving_no_pi_ancestor_fails_fast`
(function body) and its header comment block, replace the literal `pi ancestor` substring polls
with `supported agent harness` (the stable, specific substring now present in the `pool_die`
text at `lib/pool.sh:3429`) and update the comment/label wording to match. Structure untouched.

**Success Definition:**
1. The two `[[ "$msg" == *"<substr>"* ]]` match sites in `test_driving_no_pi_ancestor_fails_fast`
   use the substring `supported agent harness` (matching the current `pool_die` text), verified
   by `grep` to be exactly the new message text in `lib/pool.sh:3429`.
2. Every literal `pi ancestor` occurrence **inside the scoped block** (function + its header
   comment) is updated to `recognized-harness ancestor` (concept) or `supported agent harness`
   (message text); zero `pi ancestor` literals remain in that block.
3. **Structure preserved:** `setsid --fork` detach, `env -u` owner-override strip, temp-file +
   bounded-deadline (10s) poll, `mktemp`/`rm -f`, the `_fail`-on-timeout branch, and the
   function NAME (`test_driving_no_pi_ancestor_fails_fast`) are all byte-for-byte unchanged.
4. `bash -n test/transparency.sh` → rc 0; `shellcheck -S warning -s bash test/transparency.sh`
   → rc 0; the edits introduce **zero new** shellcheck findings at any severity.
5. Scope discipline: NO edit outside `test_driving_no_pi_ancestor_fails_fast` + its header
   comment. In particular the **shared helper `_transparency_assert_driving_no_pi_fails_fast`
   (lines 242–260) and TEST (a)/(b2) are NOT touched here** — they are a known, separately-tracked
   gap (see "Residual Risk").

---

## Why

- P3.M1.T1.S3 (Complete) changed the driving fail-fast message text. `test_driving_no_pi_ancestor_fails_fast`
  proves the fail-fast contract (PRD §2.4 step 1) by polling a detached child's stderr for that
  message. A LITERAL substring poll that names the OLD wording is now a dead check — it can never
  match, so the test is silently broken (it would time out and report a false "did NOT fail fast").
- This is the **test-side follow-through** of the R3 message change. The contract decomposes the
  transparency.sh fixes per-test; THIS item owns TEST (i) (`test_driving_no_pi_ancestor_fails_fast`).
- The fix is mechanical (substring + comment text), but the **substring choice is load-bearing**:
  it must (a) actually appear in the new `pool_die` text, (b) be contiguous within one
  `pool_die` arg (independent of `$*` arg-joining format), and (c) be specific to this fail-fast
  path. `supported agent harness` satisfies all three (host-verified — see Context).

---

## What

### User-visible behavior
None — `test_*` functions are test-internal; never shipped, never called by the pool binary.
They run only when `test/transparency.sh` is executed directly under its single-setup runner.

### Technical change (confined to `test/transparency.sh`, scoped block only)
Replace the literal `pi ancestor` substring in the two poll sites + the 6 other literal `pi
ancestor` references inside `test_driving_no_pi_ancestor_fails_fast` and its header comment,
with `supported agent harness` (message text) / `recognized-harness ancestor` (concept). **No
structural change.** Full verbatim substitution table in the Implementation Blueprint.

### Success Criteria
- [ ] Both `[[ "$msg" == *"<substr>"* ]]` match sites (poll `&& break` + final assert) use
      `supported agent harness`.
- [ ] The `_fail` timeout label and all header-comment references to the old message/concept are
      updated; zero `pi ancestor` literals remain in the scoped block.
- [ ] Structure unchanged: `setsid --fork`, `env -u …`, temp-file poll, 10s deadline, `rm -f`,
      function name — all identical.
- [ ] `bash -n test/transparency.sh` rc 0; `shellcheck -S warning -s bash test/transparency.sh` rc 0.
- [ ] No edit outside the scoped block (helper / TEST a / TEST b2 untouched — see Residual Risk).

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact source-of-truth message text
(verbatim, with line number), the exact current line numbers in the target file (with a grep to
re-derive them, since the contract's "~528" is approximate), a verbatim before→after substitution
table for every in-scope edit, the rationale for the chosen substring, the static-only validation
commands (verified runnable in this tree), and the explicit scope boundary. Nothing else required._

### Documentation & References
```yaml
- file: lib/pool.sh
  why: SOURCE OF TRUTH for the new fail-fast message. pool_wrapper_main step d (the driving
       dispatcher) calls pool_die at lines 3429-3430:
         pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
                  "For raw browser use without pooling, call 'agent-browser' directly."
  pattern: pool_die (lib/pool.sh:29-32) = `printf '%s\n' "$*" >&2; exit 1` → "$*" joins args
           with $IFS (space) → emits ONE line. "supported agent harness" is FULLY CONTIGUOUS
           within the FIRST arg → the substring match is robust regardless of arg-joining.
  critical: DO NOT edit lib/pool.sh (M1 scope, already Complete). This PRP only CONSUMES its
            message text. The substring to match is `supported agent harness` (appears exactly
            once in the whole repo — host-verified — so it is specific to this fail-fast path).

- file: test/transparency.sh
  why: TARGET FILE. test_driving_no_pi_ancestor_fails_fast() body = lines 515-541; its header
       comment block = lines 498-514. The 8 literal "pi ancestor" occurrences in that block are
       at lines 499, 500, 502, 511, 517, 535, 539, 540. The two LOAD-BEARING substring polls are
       535 (`[[ "$msg" == *"pi ancestor"* ]] && break`) and 539 (`[[ "$msg" == *"pi ancestor"* ]] \`).
  pattern: temp-file + bounded-deadline poll: detach the driving child via `setsid --fork` (reparent
           away from any harness ancestor → POOL_OWNER_PID=0 → fail-fast at step d, BEFORE any
           Chrome/lane work → sub-second, no orphan), strip owner overrides via `env -u`, redirect
           the detached child's output to a `mktemp` file, poll it (10s ceiling) for the message,
           then `rm -f` the temp file and `_fail`-and-`return 1` if the message never appeared.
  critical: the work-item contract says "line ~528" — that is APPROXIMATE/STALE. The actual
            current poll site is line 535 (re-derive with grep before editing — see Task 1). Do
            NOT trust the contract's line numbers verbatim. ONLY edit the scoped block
            (498-541); the shared helper (242-260) + TEST a (262-275) + TEST b2 (297-313) are
            OUT OF SCOPE here (Residual Risk).

- file: plan/003_afc2f15931ab/architecture/test_code_map.md
  why: §3 (transparency.sh table) and §6 (residual risk) — the research that scoped this item.
       NOTE: §6 flagged ONLY transparency.sh:498-532 (TEST i); it MISSED the shared helper
       _transparency_assert_driving_no_pi_fails_fast (242-260) and TEST a/b2 (Residual Risk).
  critical: treat test_code_map's line numbers as approximate; re-derive with grep.

- file: plan/003_afc2f15931ab/P3M2T1S3/research/notes.md
  why: this item's own research — verbatim current line numbers, the full 8-row substitution
       table, the blast-radius enumeration, and the static-validation baselines. READ THIS.

- file: AGENTS.md
  why: §1 forbids running the suite / booting Chrome during planning; §2 mandates `timeout` on
       any live subprocess; §3 mandates reaping. This item's planning validation is STATIC ONLY.
  critical: NO `bash test/transparency.sh`, NO `setsid`, NO Chrome during planning.
```

### Current codebase tree (relevant slice)
```
lib/pool.sh              # pool_die (29-32), pool_wrapper_main fail-fast pool_die (3429-3430) — SOURCE OF TRUTH, READ ONLY
test/transparency.sh     # TARGET: test_driving_no_pi_ancestor_fails_fast (515-541) + header comment (498-514)
test/validate.sh         # framework (spawn_sim_owner, setup, runner) — NOT touched
plan/003_afc2f15931ab/architecture/test_code_map.md   # §3/§6 scoping research (approximate line numbers)
```

### Desired codebase tree (delta)
```
test/transparency.sh    # MODIFIED: 8 in-scope substring/comment edits in test_driving_no_pi_ancestor_fails_fast + header.
(no new files; no deletions; lib/pool.sh, validate.sh, and the shared helper untouched.)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL — the substring must survive pool_die's arg-joining: pool_die = `printf '%s\n' "$*"`
# (lib/pool.sh:30). "$*" joins args with $IFS (space). "supported agent harness" lies ENTIRELY
# within the FIRST pool_die arg ("…require a supported agent harness (pi/claude/codex/agy)."),
# so it is contiguous no matter how args join. Do NOT pick a substring that spans the arg
# boundary (e.g. "harness (pi/claude" would break if joining changed). "supported agent harness"
# is the safe, specific, host-verified choice.

# CRITICAL — the contract's line numbers are STALE/approximate. It says "line ~528" for the poll;
# the ACTUAL current poll site is line 535 (final assert at 539, _fail label at 540). ALWAYS
# re-derive with the grep in Task 1 before editing. Sibling landings shift these numbers.

# CRITICAL — scope boundary (do NOT over-edit): ONLY the 8 literal "pi ancestor" occurrences in
# the scoped block (498-541) are in scope. Bare-`pi` references in that block (lines 504-508,
# 521, 525) describe the REAL test environment ("suite launched BY `pi`") and the determinism
# reasoning ("ppid walk finds no 'pi'") — they name the `pi` PROCESS, remain FACTUALLY TRUE
# (the test runs with NO harness ancestor at all), and are OUTSIDE the literal-"pi ancestor" scan.
# Leave them unchanged. Editing them is drift + scope creep.

# CRITICAL — do NOT rename test_driving_no_pi_ancestor_fails_fast. Its name still contains
# "pi ancestor"; that is fine (stable identifier; discovered by `compgen -A function | grep
# '^test_'`). The contract says "only the matched substring + comment text" — a rename is a
# STRUCTURAL change and is forbidden.

# CRITICAL — do NOT touch the shared helper _transparency_assert_driving_no_pi_fails_fast
# (242-260) or TEST (a)/(b2). They have the SAME bug but are a SEPARATE, known gap
# (Residual Risk). Expanding scope without orchestrator sign-off violates scope discipline.

# shellcheck baseline (verified): `shellcheck -S warning -s bash test/transparency.sh` is rc 0
# today. The 8 edits change only substring literals + comment words → introduce ZERO new findings
# (no new unquoted expansions, no new patterns). The full `shellcheck -s bash` (no -S) is rc 1
# with a handful of PRE-EXISTING info/style findings — do NOT "fix" those here.
```

---

## Implementation Blueprint

### Substitution table (the ENTIRE change — 8 edits, scoped block only)

Re-derive exact line numbers first (Task 1). The table below uses the CURRENT verified line
numbers; if grep returns different numbers, apply the same before→after to the matching text.

| # | Line (current) | BEFORE (exact, unique) | AFTER |
|---|----------------|------------------------|-------|
| 1 | 499 | `# TEST (i) — driving command with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).` | `# TEST (i) — driving command with NO recognized-harness ancestor → FAIL-FAST pool_die (§2.4 step 1).` |
| 2 | 500 | `# PRD §2.4 step 1 / shipped P2.M1.T1.S2: "No pi ancestor → DRIVING fails fast" — the pool's` | `# PRD §2.4 step 1 / shipped P2.M1.T1.S2 (msg text: P3.M1.T1.S3): "No recognized-harness ancestor → DRIVING fails fast" — the pool's` |
| 3 | 502 | `# 'agent-browser' directly').` *(preceded by line 501's `…stderr contains 'pi ancestor … for raw browser use call`)* | `# 'agent-browser' directly').` with line 501's `'pi ancestor …` → `'supported agent harness …` |
| 4 | 511 | `# child's output to a TEMP FILE and poll (bounded) for 'pi ancestor'. pool_die fires at step d,` | `# child's output to a TEMP FILE and poll (bounded) for 'supported agent harness'. pool_die fires at step d,` |
| 5 | 517 | `    # Deliberately NO _transparency_spawn_owner — this body has NO pi ancestor.` | `    # Deliberately NO _transparency_spawn_owner — this body has NO recognized-harness ancestor.` |
| 6 | 535 | `        [[ "$msg" == *"pi ancestor"* ]] && break` | `        [[ "$msg" == *"supported agent harness"* ]] && break` |
| 7 | 539 | `    [[ "$msg" == *"pi ancestor"* ]] \` | `    [[ "$msg" == *"supported agent harness"* ]] \` |
| 8 | 540 | `        || { _fail "driving cmd with no pi ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }` | `        || { _fail "driving cmd with no recognized-harness ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }` |

**Rows 6 & 7 are the LOAD-BEARING edits** (the actual substring polls). Rows 1–5 + 8 are
comment/label accuracy (keep the test self-documenting + grep-able for the new wording).
Row 3 spans two physical lines (501+502): line 501 is the long comment line whose tail reads
`…stderr contains 'pi ancestor … for raw browser use call`; update ONLY the `'pi ancestor …`
token to `'supported agent harness …` on line 501 (leave line 502 unchanged — it just closes
the comment). Row 2 additionally annotates that the message TEXT changed in P3.M1.T1.S3 (the
fail-fast BEHAVIOR origin stays P2.M1.T1.S2); this keeps the provenance accurate.

### Implementation Tasks (ordered)

```yaml
Task 1: RE-DERIVE exact line numbers (the contract's "~528" is stale)
  - RUN: grep -nE '"\$\{?msg\}?" == \*"pi ancestor"\*' test/transparency.sh
          # → the two LOAD-BEARING poll sites (expect current lines ~535 and ~539).
  - RUN: grep -n 'pi ancestor' test/transparency.sh
          # → confirm EXACTLY 8 hits in the range that spans
          # test_driving_no_pi_ancestor_fails_fast's header comment + body.
  - RUN: grep -nE '^test_driving_no_pi_ancestor_fails_fast\(\)' test/transparency.sh
          # → the function header (current line 515). The scoped block = its preceding
          # `# ====…` header-comment run through the function's closing `}`.

Task 2: EDIT test/transparency.sh — apply substitution-table rows 1–8 (scoped block ONLY).
  - USE the `edit` tool with one edits[] entry per row (8 entries), each oldText an EXACT
            unique snippet from the current file. For row 3, target the unique substring
            `contains 'pi ancestor … for raw browser use call` on line 501.
  - PRESERVE: structure byte-for-byte (setsid --fork detach; env -u strip; mktemp temp file;
            10s deadline; sleep 0.2 poll cadence; rm -f; _fail+return 1 branch; function name).
  - PRESERVE: bare-`pi` process-name references in the block (lines ~504-508, ~521, ~525) —
            they are accurate environmental facts, NOT the "pi ancestor" phrase. Leave them.
  - DO NOT TOUCH: the shared helper _transparency_assert_driving_no_pi_fails_fast (242-260),
            test_skills_fail_fast_no_pi (272-275), test_version_fail_fast_no_pi (304-313),
            the file header (1-25), lib/pool.sh, validate.sh, any other file. (Residual Risk.)

Task 3: STATIC VALIDATE (no suite run — AGENTS.md §1)
  - RUN: bash -n test/transparency.sh                                      # expect rc 0
  - RUN: shellcheck -S warning -s bash test/transparency.sh                # expect rc 0
  - RUN: shellcheck -s bash test/transparency.sh 2>&1 | wc -l              # informational; the
          # full (-s bash, no -S) run is rc 1 with PRE-EXISTING info/style findings. Confirm the
          # finding COUNT did not INCREASE (the 8 edits add no new patterns). Do NOT "fix" the
          # pre-existing findings.
  - RUN: sed -n '498,541p' test/transparency.sh | grep -c 'pi ancestor'    # expect 0 (scoped
          # block is fully swept). NOTE: `grep -c 'pi ancestor' test/transparency.sh` over the
          # WHOLE file will still be >0 (the shared helper + TEST a/b2 + header are untouched by
          # design — Residual Risk). That is EXPECTED and correct for this item's scope.
  - RUN: sed -n '498,541p' test/transparency.sh | grep -c 'supported agent harness'
          # expect ≥2 (the two load-bearing polls) — confirms the new substring is in place.
```

### Implementation Patterns & Key Details
```bash
# (1) The load-bearing poll shape — ONLY the substring token changes (structure identical):
#   BEFORE:
        [[ "$msg" == *"pi ancestor"* ]] && break
#   AFTER:
        [[ "$msg" == *"supported agent harness"* ]] && break
#   (and the matching final-assert line 539 identically.)

# (2) Why "supported agent harness" (not "agent harness" / "supported" / the whole sentence):
#   - It is the LONGEST stable phrase that is (a) present verbatim in lib/pool.sh:3429's
#     pool_die first arg, (b) contiguous within that single arg (robust to "$*" joining), and
#     (c) unique to this fail-fast path in the whole repo. Shorter tokens ("supported",
#     "agent harness") risk matching unrelated future output; the full sentence risks breaking
#     on punctuation/arg-boundary formatting. "supported agent harness" is the sweet spot.

# (3) The _fail label (row 8) is CONCEPT text, not a poll — use "recognized-harness ancestor"
#     (the generalized concept from PRD §2.4 step 1 / Decision O9), NOT the message substring.
#     Same for the conceptual comment refs (rows 1, 2, 5). Use the message substring
#     "supported agent harness" only where the comment describes the MESSAGE TEXT being polled
#     (rows 3, 4) and in the polls themselves (rows 6, 7).
```

### Integration Points
```yaml
UPSTREAM (consumed, READ ONLY): lib/pool.sh:3429-3430 — the new pool_die fail-fast message text
  (landed by P3.M1.T1.S3, Complete). This PRP ONLY reads it to derive the poll substring.
DOWNSTREAM: nothing consumes this test beyond the transparency suite runner. No config, no
  routes, no migrations, no user docs (test-internal).
NO conflict with the parallel P3.M2.T1.S2 (it lands a selftest in validate.sh; disjoint file).
NO conflict with P3.M2.T1.S1 (validate.sh spawn_sim_owner generalization; disjoint file).
```

---

## Residual Risk — ⚠️ READ THIS (a known gap OUTSIDE this item's scope)

**One-pass SUITE success is blocked by a sibling breakage this item does NOT fix.** The
contract + architecture/test_code_map.md §6 scoped this item to `test_driving_no_pi_ancestor_fails_fast`
(TEST i) ONLY. But `grep -c 'pi ancestor' test/transparency.sh` = **21** total, and the SAME
literal-substring bug exists in a **shared helper + two sibling tests** that test_code_map §3/§6
did NOT enumerate:

1. **`_transparency_assert_driving_no_pi_fails_fast` (lines 242–260)** — the SHARED verifier
   used by TEST (a) `test_skills_fail_fast_no_pi` (272) and TEST (b2) `test_version_fail_fast_no_pi`
   (304). It has the identical temp-file + bounded poll matching `*"pi ancestor"*` at **lines 254
   and 258** (+ a `_fail` label at 259 + header comment 229–241). → TEST (a) and TEST (b2) WILL
   time out (false-negative) exactly like TEST (i).
2. **File header lines 10, 12, 19** — the `(a)`/`(b2)`/`(i)` one-line test manifest comments.
3. **TEST (a) comment lines 265, 266, 268** and **TEST (b2) comment lines 300, 301** — both still
   quote the old "pool_die 'driving commands require a pi ancestor …'" wording.

**This PRP delivers EXACTLY the contract (TEST i + its header) and does NOT expand scope**
(scope discipline; the implementer must not silently broaden it). **Recommended follow-up:** a
sibling item (e.g. P3.M2.T1.S4) that applies the identical fix to the shared helper
(`_transparency_assert_driving_no_pi_fails_fast`: polls at 254/258, `_fail` at 259, header
229–241) and the TEST (a)/(b2) comments. Until that lands, `test/transparency.sh` will still
fail TEST (a)/(b2) when the suite is run — even though THIS item's static gates pass and TEST (i)
itself is fixed. **Flag this to the orchestrator; do not absorb it into this item unilaterally.**

---

## Validation Loop

### Level 1: Syntax & Style (run after the edit; STATIC ONLY — AGENTS.md §1)
```bash
bash -n test/transparency.sh                                   # rc 0
shellcheck -S warning -s bash test/transparency.sh             # rc 0
# Full picture (pre-existing info/style findings expected & out of scope):
shellcheck -s bash test/transparency.sh 2>&1 | wc -l           # finding COUNT must NOT increase
```
Expected: rc 0 for `bash -n` and `shellcheck -S warning`. If a NEW finding lands in the scoped
block, fix it. Do NOT "fix" pre-existing findings.

### Level 2: Scope sweep (confirm the scoped block is clean + the new substring is present)
```bash
sed -n '498,541p' test/transparency.sh | grep -c 'pi ancestor'              # expect 0
sed -n '498,541p' test/transparency.sh | grep -c 'supported agent harness'  # expect ≥2 (the polls)
grep -c 'pi ancestor' test/transparency.sh                                  # still >0 (helper/TEST a/b2 — EXPECTED, Residual Risk)
```

### Level 3: Integration (DO NOT RUN THE SUITE HERE — AGENTS.md §1)
The implementing agent runs the suite isolated + bounded per AGENTS.md §2 **only AFTER the
Residual-Risk sibling item also lands** (otherwise TEST a/b2 still time out). Illustrative
(not prescriptive; implementer owns the exact invocation):
```bash
timeout 120 env -i HOME="$(mktemp -d)" PATH="/usr/bin:/bin" bash test/transparency.sh
```
Expected (when run, post-sibling-fix): `test_driving_no_pi_ancestor_fails_fast` PASSES (the
detached child's stderr contains `supported agent harness` → the poll matches sub-second → no
timeout). **Before the sibling fix, only TEST (i) passes; TEST (a)/(b2) still fail.**

### Level 4: Process hygiene (AGENTS.md §3 — only if a live run was performed)
```bash
pgrep -af 'setsid|agent-browser|google-chrome' || true   # expect empty (no live run during planning)
```
Planning does NO live run, so this is a no-op here. If the implementer ran the suite isolated,
they must reap every spawned `setsid`/Chrome/sim-owner and leave zero orphans/temp dirs.

---

## Final Validation Checklist

### Technical Validation
- [ ] `bash -n test/transparency.sh` → rc 0.
- [ ] `shellcheck -S warning -s bash test/transparency.sh` → rc 0.
- [ ] `shellcheck -s bash` finding count did NOT increase (8 edits add no new patterns).

### Feature Validation
- [ ] Both `[[ "$msg" == *"supported agent harness"* ]]` polls present (lines ~535 + ~539).
- [ ] Zero `pi ancestor` literals remain in the scoped block (`sed -n '498,541p' | grep -c` = 0).
- [ ] Comment/label wording updated (concept = "recognized-harness ancestor"; message = "supported
      agent harness"); the chosen substring is host-verified against `lib/pool.sh:3429`.

### Scope Discipline
- [ ] Only `test/transparency.sh` touched; only the 8 in-scope edits (scoped block 498–541).
- [ ] Structure byte-for-byte unchanged (setsid --fork, env -u, temp-file poll, 10s deadline,
      rm -f, _fail+return 1, function name).
- [ ] Bare-`pi` process-name references in the block left unchanged (accurate env facts).
- [ ] Shared helper `_transparency_assert_driving_no_pi_fails_fast` + TEST (a)/(b2) + file
      header NOT modified (Residual Risk — separately tracked).
- [ ] `lib/pool.sh`, `validate.sh`, and all other files untouched.
- [ ] No test suite executed during planning; no Chrome booted; no orphan processes/temp dirs.

---

## Anti-Patterns to Avoid
- ❌ Don't trust the contract's line numbers ("~528") verbatim — they're stale; re-derive with
  grep (Task 1). The actual current poll site is ~535.
- ❌ Don't pick a substring that spans a `pool_die` arg boundary (e.g. "harness (pi/claude") —
  `$*`-joining could split it. Use `supported agent harness` (wholly within the first arg).
- ❌ Don't rename `test_driving_no_pi_ancestor_fails_fast` — a rename is a structural change
  the contract forbids; the name is a stable `compgen`-discovered identifier.
- ❌ Don't edit the bare-`pi` process-name references in the block (lines ~504-508, ~521, ~525) —
  they describe the real `pi` harness environment and remain factually true.
- ❌ Don't expand scope to the shared helper / TEST (a)/(b2) without orchestrator sign-off —
  that's a separately-tracked gap (Residual Risk), not this item.
- ❌ Don't "fix" the pre-existing `shellcheck` info/style findings — intentional, out of scope.
- ❌ Don't run the suite / boot Chrome during planning (AGENTS.md §1).

---

## Confidence Score
**9/10** for the CONTRACT scope (TEST i + its header). The change is 8 mechanical
substring/comment edits, fully specified verbatim with a before→after table, exact current line
numbers (re-derived, with a grep to confirm), a host-verified source-of-truth message
(lib/pool.sh:3429) and substring (`supported agent harness`), and static-only validation gates
confirmed runnable in this tree. The −1 is residual empirical risk that the implementer, when
running the suite isolated post-sibling-fix, observes the detached child's stderr actually
contain `supported agent harness` (it must, since the poll runs the real `agent-browser-pool`
binary whose step-d `pool_die` is unchanged code) — that run is the final proof and is explicitly
the implementer's job per AGENTS.md §1/§2.

**NOTE on one-pass SUITE success:** scoped to TEST (i), confidence is 9/10. Suite-wide success
is **blocked** by the Residual-Risk sibling breakage (shared helper + TEST a/b2) until a
follow-up item lands; that gap is documented, not hidden.
