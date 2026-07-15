# PRP — P2.M1.T2.S1: Add `_pool_preflight_real_bin()` function and call it in `pool_wrapper_main`

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M1.T2.S1
**Dependency**: Builds on the POST-**P2.M1.T1.S2** state (removes `POOL_DISABLE` + flips
no-pi-ancestor to fail-fast). The live working tree ALREADY reflects S2's output (verified:
exactly one `POOL_DISABLE` ref at `pool_admin_help:4597`, step d is fail-fast, step b is gone,
header comments updated). This item is **purely additive** — it adds one new function + one
new call + one consequential comment line. It touches a region DISJOINT from every other
in-flight item (no overlap with P2.M1.T3.S1's `pool_admin_help`, P2.M2.T1.S1's `bin/*`, etc.).
*(Status: the "live working tree reflects S2's output" claim above was true at the start of
research; a concurrent implementation agent then ALSO applied THIS item during research — see
the ⚠ STATUS NOTE just below. The applied change matches this spec byte-for-byte.)*
**Full research notes**: `plan/002_97982899bef6/P2M1T2S1/research/notes.md`

---

> ## ⚠ STATUS NOTE — concurrent implementation already applied to the working tree
>
> This research ran **in parallel** with P2.M1.T1.S2's implementation (per the
> `parallel_execution_context`). During research the working tree was concurrently modified
> (`git status` → `M lib/pool.sh`) and **this item's change is ALREADY APPLIED**. The applied
> implementation was verified to match this PRP **byte-for-byte**:
>
> - `_pool_preflight_real_bin()` defined at `lib/pool.sh:3551` with the exact Mode-A docstring
>   + `[[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]` check + the verbatim 3-arg `pool_die`.
> - Called unguarded as the tail of `pool_wrapper_main` step a at `lib/pool.sh:3629`.
> - RC-TAXONOMY no-guard list updated at `lib/pool.sh:3592`.
> - `bash -n lib/pool.sh` → exit 0; `shellcheck -s bash lib/pool.sh` → exit 0, zero output.
>
> **How to read this PRP now.** It remains the AUTHORITATIVE SPECIFICATION of the post-S2 →
> post-S1 delta (the definition of done). The `oldText`/`newText` "Implementation Tasks" describe
> the post-S2 **input** state and the intended result — they will **not** match the *current*
> tree, because the edit is already applied. An implementer / verifier should therefore treat the
> Tasks as a **VERIFICATION CHECKLIST** ("the tree must contain `newText`") rather than edits to
> re-apply. The Level 1-3 validation commands test the running code and remain fully valid as-is.
>
> This concurrent application does not change the spec; it confirms it. Research agents do not
> modify source (`lib/pool.sh` is untouched by this PRP author).

---

## Goal

**Feature Goal**: Add a `_pool_preflight_real_bin()` helper that fails fast (via `pool_die`)
when the real `agent-browser` binary (`$POOL_REAL_BIN`, frozen by `pool_config_init`) is
missing or non-executable, and wire it into `pool_wrapper_main` so it runs on **every**
invocation that reaches the wrapper (driving commands **and** meta passthrough) — **before**
any lane lookup, dispatch, owner resolution, port probe, or Chrome launch.

**Deliverable**: A modified `lib/pool.sh` in which:
1. A new `_pool_preflight_real_bin()` function is defined immediately before the
   `pool_wrapper_main` section divider, with a Mode-A docstring documenting the PRD §2.16
   enforcement.
2. `pool_wrapper_main` calls `_pool_preflight_real_bin` (unguarded) as the last line of its
   step-a block — after `pool_config_init` + `pool_state_init`, before `pool_dispatch_classify`.
3. The wrapper's RC-TAXONOMY header comment lists `_pool_preflight_real_bin` among the
   "rc 0 ALWAYS (no guard)" helpers (consequential hygiene — that comment is the file's
   authoritative guard reference).
4. `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` both remain clean (zero output).

**Success Definition**:
- `shellcheck -s bash lib/pool.sh` exits 0 with zero output (unchanged from the clean baseline).
- `bash -n lib/pool.sh` exits 0.
- `grep -n '_pool_preflight_real_bin' lib/pool.sh` shows exactly **two** hits: the function
  definition and the call site.
- An isolated, `timeout`-bounded micro-check with a missing binary + `pool_wrapper_main
  --version` (a META command) exits **1** and prints the actionable install message — and
  crucially **never reaches dispatch/owner/lane/Chrome** (proving the call sits before step c
  and covers the meta path too, per PRD §2.16 "on every driving call" + the item's
  "driving + meta passthrough" requirement).

---

## Why

- **Business value / PRD alignment**: PRD §2.16 declares `agent-browser ≥ 0.28` a **hard
  runtime dependency** called by absolute path on every driving command, and mandates it be
  "Enforced two ways: (a) `doctor`'s `[binary]` check …; (b) a **preflight** in the pool entry
  on every driving call that fails fast with an actionable 'install agent-browser ≥ 0.28'
  message rather than booting a lane it can't drive." Enforcement (a) already exists
  (`pool_admin_doctor` `[binary]` section). This item delivers enforcement (b). See also
  architecture/system_context.md **Gap 5**.
- **Who it helps**: An agent (or operator) whose `agent-browser` binary is missing/uninstalled/
  moved gets an immediate, actionable error at the pool entry — instead of either (i) booting a
  whole Chrome lane only to `exec` a nonexistent path, or (ii) a cryptic "command not found"
  from a later `exec`. It also protects meta passthrough (`agent-browser-pool --version`) from
  the same silent failure.
- **Scope cohesion**: This is the third and final change to `pool_wrapper_main` in milestone
  P2.M1 (after S1's config knob removal and S2's passthrough→fail-fast). It is additive and
  disjoint from S2's edits (S2 touched the header POOL_DISABLE comments + step b + step d;
  this item touches step a's tail + the RC-TAXONOMY line + adds a new function above the
  section). No merge collision possible.

---

## What

**User-visible behavior**: A caller that invokes **any** `agent-browser-pool` driving or meta
command when `$POOL_REAL_BIN` does not exist or is not executable now gets, on stderr and a
non-zero exit:

```
agent-browser-pool: the real agent-browser binary is missing or not executable: <POOL_REAL_BIN> Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path.
```

(one line — `pool_die` joins its args with a space via `"$*"`). When the binary **is** present
and executable, behavior is identical to today (preflight returns 0, control flows on to step c).

**Unchanged (explicitly preserved)**:
- Step c (`pool_dispatch_classify` → meta → `exec` passthrough) is byte-for-byte unchanged.
- Steps d→k (owner resolve, find-or-acquire, ensure-connected, normalize, session-force, exec)
  are unchanged.
- `pool_admin_doctor`'s `[binary]` check (PRD §2.16 enforcement (a)) is untouched.
- Every other function in `lib/pool.sh` is untouched.

### Success Criteria

- [ ] `_pool_preflight_real_bin()` is defined immediately before the `# ===` "Wrapper shim"
      section divider, with a Mode-A docstring citing PRD §2.16.
- [ ] Its check is exactly `[[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]` (matches doctor).
- [ ] Its failure path is the **3-arg** `pool_die` call with the verbatim message below.
- [ ] `pool_wrapper_main` calls `_pool_preflight_real_bin` (unguarded, own line) as the last
      line of step a — after `pool_state_init`, before the step-c comment.
- [ ] The RC-TAXONOMY comment lists `_pool_preflight_real_bin` in the "rc 0 ALWAYS (no guard)"
      group.
- [ ] `bash -n lib/pool.sh` exits 0; `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] The 3 isolated micro-checks (Level 2) behave as specified.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?_ **Yes** — the exact file, the exact `oldText`/`newText` for every edit
(verified against the live post-S2 tree), the `pool_die` join semantics, the canonical check
predicate (reused from `pool_admin_doctor`), the placement rationale (file convention for
`_pool_*` helpers), the deterministic binary-override mechanism for validation, and safe
(Chrome-free, exec-free) validation recipes are all specified below.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: lib/pool.sh
  why: The ONLY file modified. Three disjoint edit regions, all anchor'd on exact text:
       (A) function definition — insert between pool_force_session's closing `}` and the
           `# ===` "Wrapper shim" divider (current ~line 3534→3536).
       (B) the call — insert as the last line of step a in pool_wrapper_main, after
           `pool_state_init`, before the step-c comment (current ~line 3571).
       (C) RC-TAXONOMY header comment — add `_pool_preflight_real_bin` to the no-guard list.
  pattern: >
    pool_wrapper_main step order: a (config+state init) → c (dispatch classify: meta→exec
    passthrough) → d (owner resolve: no pi ancestor → pool_die) → e..k (lane lifecycle). The
    preflight is folded into step a as its final line, so it runs BEFORE dispatch and thus
    guards BOTH meta and driving paths.
  gotcha: >
    POOL_REAL_BIN is frozen by pool_config_init via `_pool_config_canon_path` (realpath -m,
    which exits 0 even for MISSING paths). So the existence check is the preflight's job — it
    MUST run AFTER pool_config_init (which it does — it's the tail of step a).

- file: lib/pool.sh  (pool_die, line 30)
  why: The error-exit helper the preflight uses.
  pattern: >
    pool_die() { printf '%s\n' "$*" >&2; exit 1; }
    "$*" joins ALL args with a SPACE into ONE line. The required 3-arg call prints ONE stderr
    line. Keep the 3 literals on 3 source lines via `\` continuation (matches the file's
    multi-line pool_die style); do NOT collapse into one literal, do NOT add `\n`.
  gotcha: >
    The middle arg "$POOL_REAL_BIN" MUST be its own double-quoted arg (word-splitting safety),
    NOT interpolated into an adjacent literal.

- file: lib/pool.sh  (pool_admin_doctor `[binary]` section, ~line 4380)
  why: The canonical existence+executable predicate to REUSE for consistency (PRD §2.16 (a)).
  pattern: "if [[ -f \"$POOL_REAL_BIN\" && -x \"$POOL_REAL_BIN\" ]]; then"
  gotcha: >
    Do NOT use `command -v` — POOL_REAL_BIN is an ABSOLUTE PATH frozen by config_init, not a
    PATH lookup. `-f` catches missing/dangling-symlink; `-x` catches non-executable.

- file: lib/pool.sh  (_pool_acquire_critical_section, line 2021 → pool_acquire_locked, 2098)
  why: The file-convention precedent for placing a `_pool_*` private helper IMMEDIATELY BEFORE
       its consumer's `# ===` section divider.
  pattern: "helper function body } ; blank line ; # === consumer section divider ; consumer docstring ; consumer() {"

- file: lib/pool.sh  (pool_dispatch_classify, line 3172)
  why: Confirms `--version` → "meta" (first case arm), so the integration micro-check
       (pool_wrapper_main --version with a missing binary) provably exercises the
       preflight BEFORE dispatch.
  pattern: "--help|-h|--version → printf 'meta\\n'; return 0"

- file: plan/002_97982899bef6/P2M1T1S2/PRP.md
  why: The CONTRACT for the post-S2 starting state (which the live tree already reflects).
       S2 deleted step b, flipped step d to fail-fast, and cleaned the header comments. This
       item does NOT touch any S2 region (disjoint), so edits compose regardless of order.
  critical: >
    S2 explicitly did NOT add the preflight ("that is P2.M1.T2.S1"). This item is that work.
    No overlap, no conflict.

- file: plan/002_97982899bef6/architecture/system_context.md  (Gap 5)
  why: Authoritative gap statement: "No check for $POOL_REAL_BIN existence before lane logic."
       Required: "A preflight on every driving call that fails fast if agent-browser binary is
       missing."

- prd: PRD.md §2.16 (Dependencies — "Enforced two ways: (a) doctor's [binary] check; (b) a
       preflight in the pool entry on every driving call that fails fast …"), §2.4 (Request
       lifecycle — the pool entry, per invocation), §2.11 (Discovery & configuration).
  why: Mandates the preflight + pins the actionable message intent ('install agent-browser
       ≥ 0.28').

- file: plan/002_97982899bef6/P2M1T2S1/research/notes.md
  why: Full line-by-line findings: post-S2 baseline verification, check-predicate reuse,
       POOL_REAL_BIN provenance, pool_die join semantics, placement rationale, dispatch
       classification proof, validation strategy, test-impact map, out-of-scope table.
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh            # ~4601 lines, 61 functions, PURE lib (NO top-level execution — safe to `source`)
                       # pool_die:30 ; pool_config_init:131 (freezes POOL_REAL_BIN) ;
                       # pool_admin_doctor:4304 ([binary] check ~4380) ;
                       # pool_force_session:3526 ; pool_wrapper_main:3596 (header 3536-3595) ;
                       # pool_admin_help:4566 (the ONE remaining POOL_DISABLE ref @4597 — NOT this item)
bin/                   # entry points (NOT touched — P2.M2.T1.S1 rewires the `*)` arm later)
test/                  # test harness (NOT touched — P2.M5 owns the updates)
plan/002_97982899bef6/architecture/system_context.md   # Gap 5 (read-only)
plan/002_97982899bef6/P2M1T1S2/PRP.md                  # S2 contract (read-only)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONLY lib/pool.sh is modified (1 new function + 1 new call line + 1 comment line).
lib/pool.sh            # + _pool_preflight_real_bin() before pool_wrapper_main;
                       # + preflight call in pool_wrapper_main step a;
                       # + _pool_preflight_real_bin in the RC-TAXONOMY no-guard list.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (pool_die join semantics, lib/pool.sh:30):
#   pool_die() { printf '%s\n' "$*" >&2; exit 1; }
#   "$*" joins args with a SPACE into ONE line. The required 3-arg call prints ONE stderr line:
#     "agent-browser-pool: the real agent-browser binary is missing or not executable: <PATH> Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path."
#   Use `\` line-continuation to keep the 3 literals on 3 source lines (matches the file's
#   multi-line pool_die style, e.g. pool_wrapper_main step d). Do NOT add `\n` or collapse args.

# CRITICAL (preflight runs AFTER config_init, NOT before): POOL_REAL_BIN is frozen by
#   pool_config_init (lib/pool.sh:163) via `_pool_config_canon_path` (realpath -m, exits 0 for
#   MISSING paths). The preflight is the existence check — it MUST follow config_init. It is the
#   LAST line of step a, after pool_state_init. Placing it earlier would test an UNSET/empty
#   POOL_REAL_BIN (`[[ -f "" ]]` is false → spurious pool_die).

# CRITICAL (set -euo pipefail): callers run under `set -euo pipefail`, but lib/pool.sh itself
#   does NOT `set -e`. The preflight is `if [[ … ]]; then return 0; fi; pool_die …` — the `[[ ]]`
#   is in a condition (errexit-exempt); `return 0` and the `pool_die` (exit 1) are both terminal
#   for their branch. The UNGUARDED call `_pool_preflight_real_bin` in step a is safe because the
#   function's only return is rc 0 (success) — failure never returns (pool_die exits).

# CRITICAL (do NOT use `command -v`): POOL_REAL_BIN is an ABSOLUTE PATH. `command -v` would do a
#   PATH lookup and could match a DIFFERENT binary on PATH. Use `-f` + `-x` on the literal path,
#   exactly like pool_admin_doctor's [binary] check.

# CRITICAL (this is enforcement (b); do NOT touch enforcement (a)): pool_admin_doctor's [binary]
#   check already exists (PRD §2.16 (a)). Leave it as-is. The PRD future-note ("doctor should
#   assert --version ≥ 0.28") is NOT this item.

# CRITICAL (line-number drift / concurrent application): at the START of research the live tree
#   was POST-S2; a concurrent implementation agent then applied THIS item, so the tree is now
#   POST-S1 (function at lib/pool.sh:3551, call at 3629, post-application). ALL spec anchors
#   below are EXACT TEXT (the post-S2 INPUT state), NOT line numbers — line numbers are
#   approximate and shift as S2/this-item are applied; always match on text.

# CRITICAL (do NOT boot Chrome / do NOT run the suite against the shared sandbox — AGENTS.md §1):
#   validate with `bash -n`, `shellcheck`, and the isolated `timeout`-bounded micro-checks only.
#   The micro-checks die/return at the PREFLIGHT — before any lane/port/Chrome/exec work.

# SAFE TO SOURCE: lib/pool.sh has NO top-level executable code. `source lib/pool.sh` only
#   defines functions. The micro-checks override AGENT_BROWSER_REAL (or POOL_REAL_BIN directly)
#   and redirect HOME to a mktemp -d so pool_state_init's mkdir lands in an ephemeral tree.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This is a new guard function + a one-line call + a one-line comment
edit. The "model" is the rc contract: `_pool_preflight_real_bin` returns 0 on success and
`pool_die`'s (exit 1, never returns) on failure — same category as `pool_config_init` /
`pool_state_init`, hence unguarded at the call site.

### Implementation Tasks (ordered by dependencies)

> ⚠ Per the ⚠ STATUS NOTE near the top: the working tree ALREADY contains these three changes
> (applied by a concurrent implementation agent during research, verified byte-for-byte against
> this spec). Read the `oldText`/`newText` below as the SPECIFICATION of the post-S2 → post-S1
> delta and as a VERIFICATION checklist ("the tree must contain `newText`"). If instead starting
> from a CLEAN post-S2 checkout, the three edits MAY be applied in a SINGLE `edit` call with
> three `edits[]` entries (the tool matches each `oldText` against the original file
> independently; order does not matter; each `oldText` is unique in a post-S2 tree).
>
> The three regions are DISJOINT.

```yaml
Task 1: EDIT lib/pool.sh — DEFINE _pool_preflight_real_bin (insert before the wrapper section)
  - oldText (the pool_force_session tail + the wrapper section divider — 6 lines):
        export AGENT_BROWSER_SESSION="abpool-$lane"
        return 0
    }

    # =============================================================================
    # Wrapper shim — complete lifecycle (P1.M6.T3.S1)
    # =============================================================================
  - newText (same, with the new function + its Mode-A docstring inserted between `}` and `# ===`):
        export AGENT_BROWSER_SESSION="abpool-$lane"
        return 0
    }

    # _pool_preflight_real_bin
    #
    # PRD §2.16 enforcement (b): the real agent-browser binary ($POOL_REAL_BIN, frozen by
    # pool_config_init) is a HARD runtime dependency — every driving call exec's it, and meta
    # commands (skills/--version/…) exec it too. Fail FAST with an actionable message if it is
    # missing or non-executable, instead of booting a lane we can't drive (or exec'ing a bad
    # path). The per-invocation counterpart to `doctor`'s [binary] check (§2.16 (a)).
    #
    # PRECONDITION: pool_config_init has frozen $POOL_REAL_BIN (called as the tail of step a in
    #   pool_wrapper_main, BEFORE dispatch/owner/lane work — so it guards BOTH driving + meta).
    # RETURNS: 0 if the binary exists and is executable; otherwise it NEVER returns (pool_die).
    #   Same rc contract as pool_config_init / pool_state_init → the caller uses NO if-guard.
    _pool_preflight_real_bin() {
        if [[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]; then
            return 0
        fi
        pool_die "agent-browser-pool: the real agent-browser binary is missing or not executable:" \
                 "$POOL_REAL_BIN" \
                 "Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path."
    }

    # =============================================================================
    # Wrapper shim — complete lifecycle (P1.M6.T3.S1)
    # =============================================================================
  - WHY: places the helper immediately before its consumer's section divider, matching the
         `_pool_acquire_critical_section` → `pool_acquire_locked` convention. Keeps the
         wrapper's docstring contiguous with its function.
  - GOTCHA: the 3-arg pool_die uses `\` continuations + 16-space indent (aligns under the
            opening `pool_die`). `"$POOL_REAL_BIN"` is its own double-quoted arg.
  - BUCKET: required (item steps a + d [Mode A docstring]).

Task 2: EDIT lib/pool.sh — CALL _pool_preflight_real_bin in pool_wrapper_main step a
  - oldText (step-a tail + blank + step-c comment — 5 lines):
        pool_config_init
        pool_state_init

        # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
  - newText (preflight folded into step a as its final line):
        pool_config_init
        pool_state_init
        # preflight (PRD §2.16b): real agent-browser binary must exist + be executable, else
        # fail fast on EVERY invocation (driving + meta) before any lane/dispatch work.
        _pool_preflight_real_bin

        # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
  - WHY: runs after config_init (so POOL_REAL_BIN is frozen) + state_init, and before
         dispatch_classify — so it covers BOTH meta and driving paths on every invocation,
         per the item contract. Unguarded (function returns 0 or pool_die's).
  - BUCKET: required (item step b).

Task 3: EDIT lib/pool.sh — add _pool_preflight_real_bin to the RC-TAXONOMY no-guard list
  - oldText (3 header-comment lines):
        #   rc 0 ALWAYS (no guard):  pool_dispatch_classify, pool_normalize_close/connect,
        #                            pool_strip_session_args, pool_config_init, pool_state_init,
        #                            pool_owner_resolve (config/state/owner pool_die on FATAL misconfig)
  - newText (helper inserted; parenthetical updated):
        #   rc 0 ALWAYS (no guard):  pool_dispatch_classify, pool_normalize_close/connect,
        #                            pool_strip_session_args, pool_config_init, pool_state_init,
        #                            _pool_preflight_real_bin, pool_owner_resolve
        #                            (config/state/preflight/owner pool_die on FATAL misconfig)
  - WHY (not optional): the RC-TAXONOMY block is the file's authoritative "which helper needs
         an if/|| guard under set -e" reference. The new helper is rc-0-always (returns 0 or
         pool_die's) and MUST appear here, else a maintainer may wrongly guard the call or
         flag the guardless call as an oversight. Directly caused by Task 2.
  - BUCKET: consequential comment hygiene (caused by Task 2), same discipline S2 applied.

Task 4: VERIFY — static gates (no execution of browsers/daemons)
  - RUN: bash -n lib/pool.sh                       # exit 0
  - RUN: shellcheck -s bash lib/pool.sh            # exit 0, zero output
  - RUN: the isolated micro-checks in "Validation Loop → Level 2".
```

### Implementation Patterns & Key Details

```bash
# The new function (Task 1) must read EXACTLY:
#
#     _pool_preflight_real_bin() {
#         if [[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]; then
#             return 0
#         fi
#         pool_die "agent-browser-pool: the real agent-browser binary is missing or not executable:" \
#                  "$POOL_REAL_BIN" \
#                  "Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path."
#     }
#
# The step-a tail (Task 2) must read EXACTLY:
#
#     pool_config_init
#     pool_state_init
#     # preflight (PRD §2.16b): real agent-browser binary must exist + be executable, else
#     # fail fast on EVERY invocation (driving + meta) before any lane/dispatch work.
#     _pool_preflight_real_bin
#
#     # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
#
# DO NOT:
#   - use `command -v "$POOL_REAL_BIN"` — it is an absolute path; use -f/-x (matches doctor).
#   - guard the call (`_pool_preflight_real_bin || …`) — the function returns 0 or pool_die's.
#   - run the preflight BEFORE pool_config_init — POOL_REAL_BIN would be unset (spurious die).
#   - touch step c / pool_dispatch_classify / the meta→exec passthrough.
#   - touch pool_admin_doctor's [binary] check (enforcement (a)) or pool_admin_help (P2.M1.T3.S1).
#   - change the pool_die message wording or collapse its 3 args — verbatim from the item; "$*"
#     join already yields one stderr line.
#   - run test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command, and
#     do NOT boot Chrome / touch the shared $HOME (AGENTS.md §1).
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no new env vars, no routes, no external doc files.
  - The ONLY integration surface is pool_wrapper_main's behavior contract:
      * any invocation (driving OR meta) with a missing/non-executable $POOL_REAL_BIN
        → exit 1 + actionable install message (was: proceed to dispatch/lane/exec and fail later
        or, for meta, exec a bad path).
      * binary present → behavior identical to today (preflight returns 0).
  - Downstream consumers that will reflect this LATER (NOT here):
      * bin/agent-browser-pool `*)` arm → pool_wrapper_main "$@"   (P2.M2.T1.S1) — once wired,
        `agent-browser-pool <anything>` will hit this preflight automatically.
      * test/transparency.sh invocations                              (P2.M5.T2.S1)
      * SKILL.md / README.md mention of the fail-fast                 (P2.M4 / P2.M6)
```

---

## Validation Loop

> Per AGENTS.md §1/§2: every command below is STATIC (`bash -n`, `shellcheck`) or an isolated,
> `timeout`-bounded micro-check that sources a pure library and dies/returns at the PREFLIGHT —
> BEFORE any lane/port/Chrome/exec work. No real Chrome, no daemons, no full test suite, no
> shared-$HOME writes.

### Level 1: Syntax & Style (run after the edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# Syntax — must exit 0
bash -n lib/pool.sh

# Lint — must exit 0 with ZERO output (matches the pre-change clean baseline)
shellcheck -s bash lib/pool.sh

# Expected: both exit 0; shellcheck prints nothing. If shellcheck flags the multi-line pool_die,
# check the `\` continuations are present and the continuation lines are indented (Task 1 newText).
```

### Level 2: Component Validation (isolated, timeout-bounded micro-checks)

```bash
cd /home/dustin/projects/agent-browser-pool

# --- (i) UNIT: preflight FAILS with a missing binary (direct call) --------------------------
# AGENT_BROWSER_REAL → bogus path → pool_config_init freezes POOL_REAL_BIN to it (realpath -m
# exits 0 for missing paths). _pool_preflight_real_bin must pool_die (exit 1) + print the message.
# HOME redirected to mktemp -d so pool_state_init (called inside pool_wrapper_main in (iii)) never
# touches the operator's real state dir.
timeout 10 bash -c '
  export HOME="$(mktemp -d)"
  export AGENT_BROWSER_REAL="/tmp/abpool-missing-bin-$$"
  source "$1/lib/pool.sh"
  pool_config_init                       # freeze POOL_REAL_BIN to the bogus path
  _pool_preflight_real_bin               # direct unit call
' _ "$(pwd)" >/dev/null 2>/tmp/s1_fail.txt
echo "exit=$?"                           # Expected: exit=1
if grep -Fq "the real agent-browser binary is missing or not executable:" /tmp/s1_fail.txt \
   && grep -Fq "Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path." /tmp/s1_fail.txt; then
  echo "OK: fail message present (both distinctive parts)"
else
  echo "FAIL: message missing/incomplete — see /tmp/s1_fail.txt"
fi

# --- (ii) UNIT: preflight PASSES with a valid executable (direct call) ----------------------
# /bin/true exists + is executable → preflight returns 0, no output.
timeout 10 bash -c '
  export HOME="$(mktemp -d)"
  export AGENT_BROWSER_REAL="/bin/true"
  source "$1/lib/pool.sh"
  pool_config_init
  _pool_preflight_real_bin
  echo "rc=$?"
' _ "$(pwd)" >/tmp/s1_pass.txt 2>&1
echo "exit=$?"                           # Expected: exit=0 (the bash -c itself)
if grep -Fq "rc=0" /tmp/s1_pass.txt && [[ ! -s /tmp/s1_pass.txt || $(wc -l </tmp/s1_pass.txt) -eq 1 ]]; then
  echo "OK: preflight passed (rc=0, no die message)"
else
  echo "FAIL: preflight did not pass cleanly — see /tmp/s1_pass.txt"
fi

# --- (iii) INTEGRATION: pool_wrapper_main runs preflight BEFORE dispatch (meta path) ---------
# Missing binary + a META command (--version). The preflight must fire BEFORE pool_dispatch_classify
# → exit 1 + binary message. Proves: (a) the call sits in step a before step c; (b) it covers META,
# not just driving. Crucially it NEVER reaches the real-binary exec.
timeout 10 bash -c '
  export HOME="$(mktemp -d)"
  export AGENT_BROWSER_REAL="/tmp/abpool-missing-bin-$$"
  source "$1/lib/pool.sh"
  pool_wrapper_main --version            # meta → would normally exec real binary; preflight stops it
' _ "$(pwd)" >/dev/null 2>/tmp/s1_integration.txt
echo "exit=$?"                           # Expected: exit=1
if grep -Fq "the real agent-browser binary is missing or not executable:" /tmp/s1_integration.txt; then
  echo "OK: meta command hit the preflight (call placed before dispatch; covers meta)"
else
  echo "FAIL: --version did NOT hit the preflight — call placement wrong, or step c ran first?"
fi

# Cleanup (defensive)
rm -f /tmp/s1_fail.txt /tmp/s1_pass.txt /tmp/s1_integration.txt
```

Expected: (i) exit=1 + both message parts; (ii) rc=0 + no die line; (iii) exit=1 + binary message.
If (i) or (iii) hang past ~1s, ABORT — that would mean execution reached dispatch/lane/Chrome
(step c+), i.e. the preflight call is missing or misplaced. Do not wait for the `timeout 10`.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Exactly two hits: the function definition and the call site.
grep -n '_pool_preflight_real_bin' lib/pool.sh
# Expected: TWO hits — one `_pool_preflight_real_bin() {` (definition, just above the # === divider)
# and one `    _pool_preflight_real_bin` (call, in step a). A third hit would be the RC-TAXONOMY
# comment line (acceptable — it's a comment mention). If the DEFINITION or the CALL is missing, fail.

# The check predicate matches the doctor's [binary] check exactly (consistency).
grep -n '\-f "\$POOL_REAL_BIN" && -x "\$POOL_REAL_BIN"' lib/pool.sh
# Expected: TWO hits — pool_admin_doctor (~4380) and _pool_preflight_real_bin (new). Same predicate.

# POOL_DISABLE state unchanged from the post-S2 baseline (still exactly ONE ref, in pool_admin_help).
grep -n 'POOL_DISABLE' lib/pool.sh
# Expected: exactly ONE hit at pool_admin_help (~4597) — owned by P2.M1.T3.S1, NOT this item.

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command.
```

### Level 4: Creative & Domain-Specific Validation

N/A — this item has no user-facing surface beyond the stderr message, no network, no DB, no
performance dimension. Levels 1-3 are complete and sufficient. The fail-fast message wording is
pinned verbatim by the item description / PRD §2.16.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] Level 2 micro-check (i): missing binary → exit=1 + both message parts.
- [ ] Level 2 micro-check (ii): `/bin/true` → rc=0, no die line.
- [ ] Level 2 micro-check (iii): `pool_wrapper_main --version` + missing binary → exit=1 + binary
      message (proves preflight runs before dispatch and covers meta).
- [ ] `grep -n '_pool_preflight_real_bin' lib/pool.sh` shows the definition + the call (≥2 hits).

### Feature Validation

- [ ] `_pool_preflight_real_bin()` defined just above the `# ===` "Wrapper shim" divider (Task 1).
- [ ] Check is `[[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]` (matches doctor; no `command -v`).
- [ ] Failure path is the verbatim 3-arg `pool_die` call.
- [ ] Mode-A docstring cites PRD §2.16 enforcement (b).
- [ ] Call is the last line of step a, unguarded, after `pool_state_init`, before step c (Task 2).
- [ ] RC-TAXONOMY comment lists the new helper in the no-guard group (Task 3).
- [ ] Step c (dispatch classify + meta→exec) is byte-for-byte unchanged.

### Code Quality Validation

- [ ] Only `lib/pool.sh` modified; no other file touched.
- [ ] Edits anchor on exact text (not line numbers); robust to the post-S2 line shift.
- [ ] `pool_admin_doctor`, `pool_admin_help` (~4597), `bin/*`, `test/*`, install.sh,
      configuration.md, SKILL.md, README.md all untouched (owned by other items).

### Documentation & Deployment

- [ ] [Mode A] `_pool_preflight_real_bin` has a docstring documenting PRD §2.16 enforcement.
- [ ] No external doc files change in THIS item (configuration.md is P2.M4.T2.S1; SKILL/README are
      P2.M4.T1.S1 / P2.M6.T1.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't use `command -v "$POOL_REAL_BIN"` — it's an absolute path; use `-f`/`-x` (matches doctor).
- ❌ Don't guard the call (`|| …`, `if …; then`) — the function returns 0 or pool_die's (never rc 1).
- ❌ Don't run the preflight before `pool_config_init` — `POOL_REAL_BIN` would be unset → spurious die.
- ❌ Don't touch step c / `pool_dispatch_classify` / the meta→exec passthrough — meta still passes
  through WHEN the binary is present (the preflight only stops the missing-binary case).
- ❌ Don't touch `pool_admin_doctor`'s `[binary]` check (PRD §2.16 enforcement (a)) — leave as-is.
- ❌ Don't touch `pool_admin_help`'s `AGENT_BROWSER_POOL_DISABLE` printf (~4597) — P2.M1.T3.S1.
- ❌ Don't run `test/validate.sh` / `test/transparency.sh` / `install.sh`, and don't boot Chrome or
  touch the shared `$HOME` (AGENTS.md §1). Use the Level 2 micro-checks instead.
- ❌ Don't change the `pool_die` message wording or collapse its 3 args — verbatim from the item;
  `"$*"` join already yields one stderr line.
- ❌ Don't forget Task 3 (RC-TAXONOMY) — it's the consequential hygiene that keeps the header's
  guard-reference accurate for the new helper (same discipline S2 applied to its comment edits).

---

## Confidence Score

**9/10** — one-pass success likelihood. The change is surgical (3 disjoint text edits in one
file: a new function, a one-line call, a one-line comment update), every `oldText`/`newText` is
given verbatim and verified against the live post-S2 tree, the check predicate is reused verbatim
from the existing `pool_admin_doctor`, the `pool_die` join semantics are documented, the
deterministic binary-override makes the micro-checks environment-independent and Chrome-free, and
the dispatch classification of `--version` as meta is proven (so the integration micro-check
validates the before-dispatch ordering). The item is purely additive — it adds a fail-fast path
that only triggers when the binary is actually absent, so it introduces ZERO new expected test
failures (the only existing expected failure, validate.sh:selftest_config_disable, is from S2 and
owned by P2.M5.T1.S1). The single residual risk is an implementer skipping Task 3 (RC-TAXONOMY
hygiene) as "just a comment" — this PRP marks it explicitly as in-scope hygiene caused by Task 2,
so the header's authoritative guard-reference is not left stale.
