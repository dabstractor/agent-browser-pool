# PRP — P2.M1.T1.S1: Remove POOL_DISABLE from pool_config_init and comments

**Project**: agent-browser-pool (bash)
**Work item**: P2.M1.T1.S1
**Dependency**: First step in the no-shadow pivot chain. Nothing precedes it; P2.M1.T1.S2 (remove
the passthrough consumer) depends on its output.
**Full research notes**: `plan/002_97982899bef6/P2M1T1S1/research/notes.md`

---

## Goal

**Feature Goal**: Remove the `AGENT_BROWSER_POOL_DISABLE` → `POOL_DISABLE` boolean wiring from
`pool_config_init` and its config-reference comment in `lib/pool.sh`, so the pool no longer
honors a disable/safety-valve knob. This is the "remove the knob at its source" half of the
pivot; the consumer code (passthrough branch) is deleted in P2.M1.T1.S2.

**Deliverable**: A modified `lib/pool.sh` in which `pool_config_init` no longer reads
`AGENT_BROWSER_POOL_DISABLE`, no longer declares the global `POOL_DISABLE`, and whose header
config-reference table no longer lists it. `bash -n` and `shellcheck -s bash` both remain clean.

**Success Definition**:
- `shellcheck -s bash lib/pool.sh` exits 0 with zero output (unchanged from the clean baseline).
- `bash -n lib/pool.sh` exits 0.
- An isolated micro-check confirms that after `pool_config_init` runs, `$POOL_DISABLE` is **unset**
  (prints `[]`), even when `AGENT_BROWSER_POOL_DISABLE=1` is exported.
- No other line in `pool_config_init` (or its doc comment) is altered beyond the four targeted
  deletions/edits below. `headless` and `allow_slow_copy` booleans are untouched.
- The `# shellcheck disable=SC2034` directive above `pool_config_init` (line ~130) is PRESERVED —
  other `POOL_*` globals still depend on it.

---

## Why

- **Business value**: PRD §4 decision O5 (No PATH shadowing / pivot) removes the cutover danger and
  the `AGENT_BROWSER_POOL_DISABLE` safety valve. The whole point of the new explicit-invocation
  model (`agent-browser-pool <verb>`) is that there is **nothing to bypass** — the real
  `agent-browser` is never intercepted. A disable knob is therefore meaningless and misleading.
- **Scope cohesion**: This is the **source** removal. The downstream consumer (the
  `POOL_DISABLE==1 → passthrough` branch in `pool_wrapper_main`) is a *separate* work item
  (P2.M1.T1.S2) that depends on this one. Removing the source first makes the consumer branch
  provably dead (inert) so S2 can delete it with confidence.
- **Who it helps**: Future maintainers (no dead config knob to reason about) and the pivot's later
  subtasks (install.sh, SKILL.md, docs, tests all stop referencing the knob).

---

## What

**User-visible behavior**: None. `POOL_DISABLE` was an internal/global contract, never a user-facing
CLI flag. The PRD-mandated removal simply makes the pool ignore the env var.

**Technical change** (4 edits, all inside `lib/pool.sh`):

1. **Comment block (line 109)** — delete the one table row:
   `#   AGENT_BROWSER_POOL_DISABLE     (unset = pooling active)                        POOL_DISABLE          bool (1=passthrough)`
2. **`local` declaration (line 181)** — drop the `disable` token:
   `    local headless disable allow_slow_copy` → `    local headless allow_slow_copy`
3. **disable assignment (line 183)** — delete:
   `    disable="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"`
4. **POOL_DISABLE global (line 186)** — delete:
   `    POOL_DISABLE="$disable"; declare -g POOL_DISABLE`

### Success Criteria

- [ ] The four edits above are applied exactly (no other changes to `pool_config_init` or its doc
      comment).
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with no output.
- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] Isolated micro-check: `POOL_DISABLE` is unset after `pool_config_init` even with
      `AGENT_BROWSER_POOL_DISABLE=1`.
- [ ] `headless` / `allow_slow_copy` wiring and the `# 5. Booleans` comment are untouched.
- [ ] The `# shellcheck disable=SC2034` directive (line ~130) is preserved.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the exact file, exact line numbers, exact old/new text, the shellcheck
directive nuance, and a safe validation recipe are all specified below.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: lib/pool.sh
  why: The ONLY file modified. Contains pool_config_init (doc comment lines ~96-131,
       function body 132-210) and the exact 4 target lines.
  pattern: >
    `pool_config_init` is a pure path/bool resolver. Section "5. Booleans" reads env vars via
    `_pool_config_bool` into locals, then assigns `LOCAL; declare -g POOL_LOCAL` globals. Every
    POOL_* global is mutable (not readonly) so the function is re-runnable by the test harness.
  gotcha: >
    A function-level `# shellcheck disable=SC2034` directive sits directly above
    `pool_config_init` (line ~130). It suppresses SC2034 for ALL assignments in the function
    because POOL_* globals are the lib's exported contract (read by tests + sibling functions).
    DO NOT remove or alter this directive — POOL_HEADLESS, POOL_ALLOW_SLOW_COPY, POOL_PORT_BASE,
    etc. still need it. Removing only the POOL_DISABLE line keeps the directive valid.

- file: plan/002_97982899bef6/architecture/gap_analysis.md
  why: Authoritative change spec. §1a gives the exact deletions (it lists lines 183-184 & 186;
       actual current line numbers are 183 & 186 — the file lists them as "~183"/"~186").
  section: "1a. pool_config_init (lines 132-210)"

- prd: PRD.md §2.11 (Discovery & configuration), §2.17 (Install — no cutover danger), §4 decision O5
  why: >
    Mandates the removal. §2.11: "(removed) AGENT_BROWSER_POOL_DISABLE and the ~/scripts
    PATH-shadow are gone — there is no interception to bypass." §2.17: "Removed: the
    AGENT_BROWSER_POOL_DISABLE safety valve (nothing to bypass)." §4 O5: "Removes ... and
    AGENT_BROWSER_POOL_DISABLE."

- file: plan/002_97982899bef6/P2M1T1S1/research/notes.md
  why: Full line-by-line table, the shellcheck SC2034 directive analysis (verified with isolated
       /tmp tests), the safe-source proof, and the explicit OUT-OF-SCOPE reference map.
  critical: >
    Lists the LATER-subtask-owned references that MUST NOT be touched here:
    pool_wrapper_main passthrough block (lib/pool.sh ~3585,3598,3606,3611-3617 → P2.M1.T1.S2);
    pool_admin_help printf (lib/pool.sh ~4609 → P2.M1.T3.S1); validate.sh selftest_config_disable
    (~346-357 → P2.M5.T1.S1); install.sh (~13,31,76,215 → P2.M3.T1.S1).
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh            # 4613 lines, 61 functions, PURE lib (no top-level execution)
bin/                   # entry points (NOT touched in this item)
test/                  # test harness (NOT touched in this item)
plan/002_97982899bef6/architecture/gap_analysis.md   # change spec (read-only)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONLY lib/pool.sh is modified (4 edits). Responsibility unchanged:
lib/pool.sh            # pool_config_init no longer sets POOL_DISABLE; doc comment updated.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (shellcheck SC2034 directive):
#   Line ~130 immediately above pool_config_init() is:
#     # shellcheck disable=SC2034 # POOL_* globals are the exported contract of this lib;
#   This suppresses SC2034 for the WHOLE function. Verified: with this directive present,
#   leaving the now-unused `disable` token in the `local` decl does NOT error (shellcheck exit 0).
#   STILL remove `disable` from the `local` decl (line 181) for hygiene + contract clarity —
#   step (e) "do NOT remove headless/allow_slow_copy" implies the disable token SHOULD go.
#   Removing the directive itself would BREAK the build (other POOL_* globals need it).

# CRITICAL (set -euo pipefail is active in callers, not in the lib):
#   lib/pool.sh itself does not `set -e`. pool_die (exit 1) is the failure path. The edits here
#   are pure deletions — they introduce no new commands, so errexit/pipefail interactions are N/A.

# CRITICAL (transient EXPECTED test failure — do NOT chase it):
#   After this change, test/validate.sh's `selftest_config_disable` (lines ~352-357) WILL FAIL
#   because it asserts POOL_DISABLE=1. That test is owned by P2.M5.T1.S1 and is EXPECTED to be
#   removed there. The S1 validation gates below intentionally AVOID running validate.sh.

# CRITICAL (do not run the full suite or boot Chrome during this item):
#   Per AGENTS.md §1: this is a surgical lib edit. Validate with `bash -n`, `shellcheck`, and ONE
#   isolated, timeout-bounded micro-check that sources the lib (safe — no top-level execution).
#   Do NOT boot real Chrome, do NOT run the real test suite against the shared sandbox.

# SAFE TO SOURCE: lib/pool.sh has NO top-level executable code (all 61 entries are functions;
# every pool_config_init/pool_state_init call is inside another function). `source lib/pool.sh`
# only defines functions — it spawns nothing.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This is a pure config-knob removal in a bash function. The "model" is the set
of `POOL_*` globals exported by `pool_config_init`; this item simply removes one member
(`POOL_DISABLE`) from that set.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — delete the config-reference comment row (line 109)
  - REMOVE exactly:
      #   AGENT_BROWSER_POOL_DISABLE     (unset = pooling active)                        POOL_DISABLE          bool (1=passthrough)
  - KEEP the neighboring rows verbatim (AGENT_CHROME_HEADLESS above, AGENT_CHROME_ALLOW_SLOW_COPY below).
  - DO NOT touch the surrounding "# Configuration reference (env var → POOL_* global):" header.

Task 2: EDIT lib/pool.sh — drop `disable` from the local declaration (line 181)
  - CHANGE:
      local headless disable allow_slow_copy
    TO:
      local headless allow_slow_copy
  - WHY: after Task 3 & 4 remove the assignment and the global, `disable` would be dead.
    (The function's SC2034 disable suppresses the lint warning, but the token is still wrong to keep.)

Task 3: EDIT lib/pool.sh — delete the disable assignment (line 183)
  - REMOVE exactly:
      disable="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"
  - KEEP line 182 (headless=...) and line 184 (allow_slow_copy=...) verbatim.

Task 4: EDIT lib/pool.sh — delete the POOL_DISABLE global line (line 186)
  - REMOVE exactly:
      POOL_DISABLE="$disable"; declare -g POOL_DISABLE
  - KEEP line 185 (POOL_HEADLESS=...) and line 187 (POOL_ALLOW_SLOW_COPY=...) verbatim.

Task 5: VERIFY — static gates (no execution of browsers/daemons)
  - RUN: bash -n lib/pool.sh                       # exit 0
  - RUN: shellcheck -s bash lib/pool.sh            # exit 0, zero output
  - RUN: the isolated micro-check in "Validation Loop → Level 2" below.

# NOTE: Tasks 1-4 can be done in a SINGLE `edit` call with 4 disjoint edits[] entries (the edit
# tool matches each oldText against the ORIGINAL file). Order in the array does not matter; each
# oldText must be unique and non-overlapping. All four target lines are distinct and unique.
```

### Implementation Patterns & Key Details

```bash
# The "5. Booleans" section AFTER all 4 edits should read exactly:
#
#     # 5. Booleans — 1/true/yes/on (case-insensitive) → on, else off.
#     local headless allow_slow_copy
#     headless="$(_pool_config_bool "${AGENT_CHROME_HEADLESS:-}")"
#     allow_slow_copy="$(_pool_config_bool "${AGENT_CHROME_ALLOW_SLOW_COPY:-}")"
#     POOL_HEADLESS="$headless"; declare -g POOL_HEADLESS
#     POOL_ALLOW_SLOW_COPY="$allow_slow_copy"; declare -g POOL_ALLOW_SLOW_COPY
#
# The config-reference comment block AFTER the edit drops exactly the one DISABLE row; columns of
# the remaining rows stay aligned (do not reflow other rows — they are already aligned).

# DO NOT:
#   - remove or alter the `# shellcheck disable=SC2034` directive at line ~130.
#   - touch any line outside the four named targets.
#   - "clean up" pool_wrapper_main (~3585-3617) or pool_admin_help (~4609) — those are P2.M1.T1.S2
#     and P2.M1.T3.S1 respectively.
#   - run validate.sh / transparency.sh / install.sh during this item.
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no routes, no new env vars.
  - The ONLY integration surface is the global `POOL_DISABLE`, which ceases to be set. Its sole
    remaining reader (pool_wrapper_main, line ~3613, uses `${POOL_DISABLE:-0}`) safely defaults to
    "0" → its passthrough branch becomes provably inert until P2.M1.T1.S2 deletes it. This is the
    intended, contract-documented behavior (item OUTPUT step 4).
```

---

## Validation Loop

> Per AGENTS.md: every command below is STATIC (`bash -n`, `shellcheck`) or an isolated,
> `timeout`-bounded micro-check that sources a pure library (no top-level execution → spawns
> nothing). No real Chrome, no daemons, no full test suite.

### Level 1: Syntax & Style (run after the edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# Syntax check — must exit 0
bash -n lib/pool.sh

# Lint — must exit 0 with ZERO output (matches the pre-change clean baseline)
shellcheck -s bash lib/pool.sh

# Expected: both exit 0; shellcheck prints nothing. If shellcheck emits SC2034 for `disable`,
# you forgot Task 2 (drop `disable` from the local decl) — apply it and re-run.
```

### Level 2: Component Validation (isolated, timeout-bounded micro-check)

```bash
cd /home/dustin/projects/agent-browser-pool

# Isolated + bounded: fresh HOME (so no real state dir is touched), 10s deadline.
# Safe because lib/pool.sh has NO top-level execution — sourcing only defines functions,
# and pool_config_init only resolves paths + sets globals (spawns nothing).
timeout 10 bash -c '
  set -euo pipefail
  export HOME="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "$1/lib/pool.sh"
  pool_config_init
  # POOL_DISABLE must be UNSET now, even when the env var is truthy.
  printf "POOL_DISABLE=[%s]\n" "${POOL_DISABLE-}"
' _ "$(pwd)" </dev/null

# Expected output:  POOL_DISABLE=[]
# (empty brackets == unset). If it prints [1] or [0], the removal is incomplete.

# Stronger variant: force the env var truthy and confirm it is now ignored.
timeout 10 env AGENT_BROWSER_POOL_DISABLE=1 bash -c '
  set -euo pipefail
  export HOME="$(mktemp -d)"
  source "$1/lib/pool.sh"
  pool_config_init
  printf "POOL_DISABLE=[%s]\n" "${POOL_DISABLE-}"
' _ "$(pwd)" </dev/null

# Expected output:  POOL_DISABLE=[]   (env var is now a no-op — exactly the PRD §2.11 contract)

# Cleanup any stray mktemp dirs from aborted runs (defensive; the snippets above use HOME, not /tmp roots):
# (none created outside the process-private mktemp -d, which dies with the shell)
```

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
# Confirm the OUT-OF-SCOPE consumer still references POOL_DISABLE (it must — P2.M1.T1.S2 owns it).
# This is a GREP (read-only), NOT an execution. Expected: the pool_wrapper_main block is still present.
grep -n 'POOL_DISABLE' lib/pool.sh
# Expected hits (do NOT remove these here):
#   ~3585, ~3598, ~3606, ~3613  (pool_wrapper_main — owned by P2.M1.T1.S2)
#   ~4609                       (pool_admin_help   — owned by P2.M1.T1.S3 / T1.S1 help text)
# And NO hit at line 109 / 181 / 183 / 186 (those are gone).

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command.
# (validate.sh selftest_config_disable is EXPECTED to fail post-S1 and is fixed in P2.M5.T1.S1.)
```

### Level 4: Domain-Specific Validation

N/A — this item has no user-facing surface, no network, no DB, no performance dimension. Levels 1-3
are complete and sufficient.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] Level 2 micro-check prints `POOL_DISABLE=[]` (unset) both unconditionally and with
      `AGENT_BROWSER_POOL_DISABLE=1` exported.
- [ ] `grep -n POOL_DISABLE lib/pool.sh` shows NO hits at former lines 109/181/183/186 and STILL
      shows the ~3585-3613 + ~4609 hits (owned by later subtasks).

### Feature Validation

- [ ] Exactly four edits applied: comment row (109) deleted; `disable` dropped from `local` (181);
      disable assignment (183) deleted; POOL_DISABLE global (186) deleted.
- [ ] `headless` and `allow_slow_copy` wiring is byte-for-byte unchanged.
- [ ] The `# shellcheck disable=SC2034` directive (line ~130) is preserved verbatim.
- [ ] No file other than `lib/pool.sh` was modified.

### Code Quality Validation

- [ ] No dead `disable` local left in the declaration.
- [ ] Comment-block columns remain aligned (only the DISABLE row removed; neighbors unchanged).
- [ ] No "fix" applied to pool_wrapper_main / pool_admin_help / validate.sh / install.sh
      (those belong to P2.M1.T1.S2 / P2.M1.T3.S1 / P2.M5.T1.S1 / P2.M3.T1.S1).

### Documentation & Deployment

- [ ] No new env vars introduced; no env var removal needs documenting beyond the comment-row
      deletion already done in Task 1 (Mode A: comment block only — no external doc files change
      in THIS item; configuration.md is P2.M4.T2.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't remove the `# shellcheck disable=SC2034` directive — other `POOL_*` globals need it.
- ❌ Don't leave `disable` in the `local` declaration (dead token; contract step (e) implies removal).
- ❌ Don't "also clean up" pool_wrapper_main's passthrough block or pool_admin_help's printf — those
  are explicitly later subtasks; touching them here blurs ownership and risks merge conflicts.
- ❌ Don't run `test/validate.sh` to "verify" — its `selftest_config_disable` is EXPECTED to fail
  post-S1 (owned by P2.M5.T1.S1). Use the Level 2 micro-check instead.
- ❌ Don't boot Chrome, don't run the real suite against the shared `$HOME` (AGENTS.md §1).
- ❌ Don't reflow or realign the other rows of the config-reference comment table — only the
  DISABLE row is removed.

---

## Confidence Score

**9/10** — one-pass success likelihood. The change is surgical (4 edits in one file), the exact
old/new text is specified, the shellcheck directive nuance is documented and verified, a safe
isolated validation recipe is provided, and the out-of-scope boundary is explicit. The single
point of residual risk is an implementer who reads the item's literal steps (a-f) and skips
dropping `disable` from the `local` decl (Task 2) — this PRP calls that out explicitly and notes it
is the correct reading of the contract even though the SC2034 directive would not error on it.
