# PRP — P1.M7.T2.S1: `pool_admin_reap()` — trigger pool_reap_stale and report

---

## Goal

**Feature Goal**: Implement **`pool_admin_reap()`** — the user-facing reap report
wrapper for the `agent-browser-pool reap` admin command (PRD §2.12 / §2.10). It
takes **no input**, calls the LANDED **`pool_reap_stale`** (M5.T3.S1,
`lib/pool.sh:2549`) which scans every lane and releases the stale ones, **captures
the reaped count from pool_reap_stale's stdout**, then prints a human-friendly
report to stdout: `"Reaped N stale lane(s)."` when N>0, or `"No stale lanes
found."` when N==0. It returns 0 always. This is the **`reap`** half of the admin
CLI's user-facing surface; the `status` command (M7.T1.S1, LANDED), the
`release`/`doctor` commands (M7.T3/M7.T4), and the `bin/agent-browser-pool`
**dispatcher** (M7.T5.S1) are all SEPARATE tasks.

**Deliverable**: ONE new PUBLIC function `pool_admin_reap()`, **APPENDED** to
`lib/pool.sh` directly after the LANDED `pool_admin_status` (current EOF
`lib/pool.sh:3681`), introduced by a NEW section banner
`# Admin CLI — reap (P1.M7.T2.S1)`. **Pure addition: no edits to any existing
function, no new private helpers, no new env-vars/globals, no new files.** It
COMPOSES three LANDED functions — `pool_config_init` + `pool_state_init`
(precondition, M1.T1.S2/S3) + `pool_reap_stale` (M5.T3.S1) — plus `printf`/`(( ))`
(already used throughout the lib).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init`, given an
  **empty pool** (no lanes / no stale lanes), calling `pool_admin_reap` returns
  **rc 0** and prints EXACTLY the single line `No stale lanes found.` — and no
  raw integer leaks to stdout.
- Given a pool with **stale lanes** (dead owners), calling `pool_admin_reap`
  returns **rc 0** and prints EXACTLY the single line `Reaped N stale lane(s).`
  where N is the integer count returned by `pool_reap_stale` (e.g. `Reaped 2
  stale lane(s).`). Again, no raw integer leaks — the count is **captured**, not
  passed through.
- **stdout discipline**: stdout is PURELY the one report line — safely capturable
  (`out="$(pool_admin_reap)"` yields exactly the message). `_pool_log` writes to
  the log file + stderr (never stdout); `pool_reap_stale`'s raw integer is
  captured into a local, not echoed.
- **Non-fatal always**: `pool_admin_reap` NEVER calls `pool_die` in its own body
  and NEVER returns non-zero (reaping 0 lanes is not an error). (The precondition
  helpers `pool_config_init`/`pool_state_init` may `pool_die` on genuine
  misconfiguration — that is their contract and is correct.)
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file,
  ZERO warnings — host-verified ShellCheck 0.11.0); all prior deliverables
  (M1–M7.T1.S1) unchanged and still callable; `lib/pool.sh`'s only diff is the
  appended banner + function.

## User Persona

**Target User**: Human admin (PRD §2.10 "on demand via `agent-browser-pool reap`";
§1.5). The function is called indirectly — the `bin/agent-browser-pool` dispatcher
(M7.T5.S1) wires `case "$cmd" in reap) pool_admin_reap ;; …`. This task builds the
LIBRARY function only; the dispatcher binary is future work.

**Use Case**: One or more pi agents crashed mid-task — their owner pids died but
their Chromes (process groups) + ephemeral dirs + lease files linger (a leak). The
admin runs `agent-browser-pool reap` to reclaim them all in one sweep; `pool_reap_stale`
tears each stale lane down (daemon close + Chrome pgroup kill + rm dir + delete
lease), and `pool_admin_reap` prints `Reaped N stale lane(s.` so the admin knows it
worked (or `No stale lanes found.` if the pool was already clean).

**User Journey**: `agent-browser-pool reap` → reads the one-line report → (if N>0)
runs `agent-browser-pool status` (M7.T1.S1) to confirm the pool is now clean.

**Pain Points Addressed**: Without `reap`, dead-owner lanes accumulate forever
(Chrome processes, disk dirs, lease files) until the next `acquire` happens to
inline-reap. `reap` gives the admin explicit, on-demand cleanup (PRD §2.10) with a
clear success/failure report — no hand-parsing of `lanes/*.json`.

## Why

- **This IS PRD §2.12's `reap` command** (`reap # kill+delete dead-owner lanes`) and
  the on-demand half of PRD §2.10 ("on demand via `agent-browser-pool reap`"). It is
  the PRIMARY documented consumer of the LANDED `pool_reap_stale` (M5.T3.S1 — which
  names M7.T2's reap command as its real consumer in its own docstring,
  `lib/pool.sh:2510-2513`).
- **It is a THIN wrapper — it delegates, it does not duplicate.** ALL the reap logic
  (lane enumeration, tri-state staleness verdict, full teardown) lives in the LANDED,
  validated, non-fatal `pool_reap_stale`. `pool_admin_reap` only: init → capture count
  → print human message → return 0. Re-implementing the reap loop would duplicate a
  carefully-verified function (M5.T3.S1) + risk divergence. (DRY.)
- **Its single non-trivial decision is stdout discipline.** `pool_reap_stale` writes
  the raw integer count to ITS stdout (for `count=$(pool_reap_stale)` capture by any
  caller). `pool_admin_reap` MUST capture that integer (else it leaks to the user
  alongside the message) and print ONLY the human report. This is the dominant
  correctness constraint (design-decisions D3 / D7).
- **It must NOT duplicate or conflict with sibling tasks.** M7.T1.S1 (`status`,
  LANDED), M7.T3.S1 (`release`), M7.T4.S1 (`doctor`), M7.T5.S1 (the dispatcher +
  `--help` wiring) are all separate. This task owns ONLY `pool_admin_reap()` in
  `lib/pool.sh`. Treat their PRPs as siblings: the dispatcher will call
  `pool_admin_reap` by name (`case reap) pool_admin_reap ;;`).

## What

User-visible behavior: **`agent-browser-pool reap` prints exactly one report line**
to stdout — either `Reaped N stale lane(s).` (N = lanes reaped) or `No stale lanes
found.` — and tears down every stale lane as a side effect (via `pool_reap_stale`).
For this task's verification (no Chrome needed for the core logic), the contract is
exercised two ways: (1) a **unit test** that overrides `pool_reap_stale` to echo a
fixed count (isolates the message logic), and (2) an **integration test** with a
synthetic stale lease (dead-owner-pid trick) for one end-to-end case.

### The contract (authoritative from item description + research)

**Input**: none.

**Logic (item contract, verbatim):**
a. Precondition: `pool_config_init` + `pool_state_init` (mirrors `pool_admin_status`
   `lib/pool.sh:3604-3606` + `pool_wrapper_main` step "a").
b. Capture the reaped count: `count="$(pool_reap_stale)"`.
c. Print the report: if `count == 0` → `No stale lanes found.`; else →
   `Reaped N stale lane(s).` (N = count).
d. `return 0`.

### Success Criteria

- [ ] `pool_admin_reap()` appended to `lib/pool.sh` under banner
      `# Admin CLI — reap (P1.M7.T2.S1)`; no other function touched.
- [ ] `bash -n lib/pool.sh` → exit 0; `shellcheck -s bash lib/pool.sh` → ZERO warnings.
- [ ] Empty pool (0 stale) → prints exactly `No stale lanes found.\n`,
      rc 0, NO raw integer on stdout.
- [ ] N>0 stale lanes → prints exactly `Reaped N stale lane(s).\n` (N = the integer
      from `pool_reap_stale`), rc 0, NO raw integer on stdout.
- [ ] stdout is PURELY the one report line (capturable: `out="$(pool_admin_reap)"`).
- [ ] Returns 0 always; never calls `pool_die` in its own body.
- [ ] `lib/pool.sh` diff is append-only (banner + function); `bin/`, `.gitignore`,
      `PRD.md`, `tasks.json` untouched.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **verbatim function
contract** (item description + research, re-stated with copy-pasteable code); the
**single critical gotcha** — `pool_reap_stale` writes a raw integer to stdout that
MUST be captured (design-decisions D3/D7); the **fact that NO `if` guard is needed
on the capture** because `pool_reap_stale` returns 0 always (the one simplification
vs the sibling); the **pinned message strings** (verbatim from the item contract);
the **`(( count == 0 ))`-inside-`if`** safety rule; the **append site** (after the
LANDED `pool_admin_status`, EOF @3681); the **banner convention**; host-verified
tooling (bash 5.3, ShellCheck 0.11); and copy-pasteable, **no-Chrome** validation
(unit tests that override `pool_reap_stale` + one synthetic-stale integration case).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.12 (admin CLI: `reap # kill+delete dead-owner lanes`). §2.10 (Reaper —
        lazy, "on demand via `agent-browser-pool reap`"; NO background daemon). §1.5
        (user story: the admin operates the pool).
  pattern: §2.12's `reap` IS this command; §2.10's "on demand" names it.
  gotcha: §2.10 — `reap` is the on-demand trigger; the lazy-on-acquire reap is a
        SEPARATE code path (acquire's inlined loop). This task calls pool_reap_stale.

# This task's own research (the factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M7T2S1/research/codebase-reap-facts.md
  why: §1 pool_reap_stale's EXACT contract (echoes one integer to stdout; rc 0 ALWAYS
        → bare capture is set -e-safe, NO guard). §2 the LANDED sibling pool_admin_status
        (the shape to mirror: precondition + locals-up-front + return 0). §3 the append
        site (after pool_admin_status, EOF @3681) + banner convention. §4 THE stdout-
        discipline gotcha (must capture, else integer leaks). §5 the set -e / SC2155 /
        (( )) gotchas. §6 the precondition. §7 the DOCS/--help boundary (Mode A). §8
        pool_release_lane's close is fast + rc 0 (test feasibility). §9 the sibling
        boundaries.
  pattern: §1's contract IS the call this function makes; §2's shape IS the structure;
        §4's capture IS the correctness fix.
  gotcha: §1 + §4 — pool_reap_stale rc 0 always (no capture guard) BUT writes an integer
        to stdout (MUST capture or it leaks).

- file: plan/001_0f759fe2777c/P1M7T2S1/research/design-decisions.md
  why: D1 (lib-only, append after pool_admin_status, own banner). D2 (precondition =
        config_init + state_init). D3 (CAPTURE count, NO guard — the key decision). D4
        (PINNED messages: "Reaped N stale lane(s)." / "No stale lanes found."; literal
        lane(s)). D5 ((( count == 0 )) inside if). D6 (return 0 always). D7 (stdout =
        one report line). D8 (DOCS via header + suggested --help). D9 (unit-override +
        synthetic-stale validation).
  pattern: D3's capture + D4's if/else ARE the implementation.
  gotcha: D5 — bare `(( count == 0 ))` statement returns 1 → FATAL under set -e; MUST
        be inside `if`.

# The LANDED sibling (the shape to mirror — same lib-only, append-under-banner form)
- file: plan/001_0f759fe2777c/P1M7T1S1/PRP.md
  why: pool_admin_status() (LANDED @ lib/pool.sh:3594) is the closest analog — also a
        lib-only admin command, also precondition (config_init + state_init), also
        locals-up-front, also non-fatal, also appended under an "# Admin CLI — X" banner.
        Its header doc-comment style + house rules ARE the pattern to follow.
  pattern: "append to lib/pool.sh under banner X; compose landed helpers; never die;
        return 0" is the exact shape of THIS task (even simpler — no tri-state guards).
  gotcha: status is READ-ONLY; reap is DESTRUCTIVE (via pool_reap_stale). But
        pool_admin_reap itself only captures+prints — the destruction is delegated.

# The function being wrapped (the ONE real dependency)
- file: plan/001_0f759fe2777c/P1M5T3S1/PRP.md
  why: pool_reap_stale() (LANDED @ lib/pool.sh:2549) is what pool_admin_reap CALLS. Its
        contract (echoes one integer; rc 0 always; non-fatal) is the foundation. Its own
        docstring (@ lib/pool.sh:2510-2513) names M7.T2's reap command as its REAL consumer.
  pattern: the CALLER CONTRACT `reaped="$(pool_reap_stale)"` (lib/pool.sh:2523-2525) is
        EXACTLY what pool_admin_reap implements.
  gotcha: pool_reap_stale writes the count to ITS stdout — pool_admin_reap must capture
        it (NOT pass it through) or the raw integer leaks alongside the message.

# The library this function is appended to (read header + EOF to confirm append site)
- file: lib/pool.sh
  why: line 23 (set -euo pipefail — every gotcha is live). pool_reap_stale @2549 (echoes
        count @2599, return 0 @2601). pool_admin_status @3594 (LANDED sibling — the shape
        to mirror; its precondition @3604-3606, locals @3595-3599, return 0 @3680). EOF
        @3681 (closing } of pool_admin_status) — the append site.
  pattern: pool_admin_status's body (@3594-3681) is the EXACT structure to reuse
        (precondition → logic → return 0), minus the read-loop complexity.
  gotcha: pool_reap_stale returns 0 always → the `count="$(pool_reap_stale)"` capture
        needs NO `if` guard (unlike pool_lease_read/pool_lane_is_stale in the sibling).
```

### Current Codebase tree

After **M1–M7.T1.S1** landed, `lib/pool.sh` (3681 lines) ends at `pool_admin_status`
(closing `}` @3681). `bin/agent-browser` exists (M6.T3.S2). The admin CLI binary does
NOT exist yet (M7.T5.S1). **THIS task appends `pool_admin_reap()` to `lib/pool.sh`:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   ├── .gitkeep                          # retained (admin CLI bin/agent-browser-pool is M7.T5.S1)
│   └── agent-browser                     # M6.T3.S2 (the wrapper shim) — UNCHANGED
├── lib/
│   └── pool.sh                           # EOF @3681 (pool_admin_status). THIS task APPENDS
│                                         #   the banner "# Admin CLI — reap (P1.M7.T2.S1)"
│                                         #   + pool_admin_reap() after line 3681.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M7T2S1/
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-reap-facts,design-decisions}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                           # MODIFIED (append-only): +banner +pool_admin_reap() at EOF
└── (no other files change)
```

**File responsibility**: `pool_admin_reap()` is the **user-facing reap report** backing
`agent-browser-pool reap`. It owns NO reap logic — it delegates entirely to
`pool_reap_stale`, captures the count, and prints the human report. It is consumed by
the future dispatcher (M7.T5.S1: `case reap) pool_admin_reap ;;`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (stdout discipline — design-decisions D3/D7): pool_reap_stale writes the raw
#   integer count to ITS stdout (lib/pool.sh:2599). If pool_admin_reap calls it WITHOUT
#   capturing, the integer leaks to the user:
#       2                                  ← leaked raw integer
#       Reaped 2 stale lane(s).            ← the message
#   FIX: count="$(pool_reap_stale)". Then pool_admin_reap's stdout is ONLY the message.

# CRITICAL (NO capture guard needed — design-decisions D3): pool_reap_stale returns 0
#   ALWAYS (lib/pool.sh:2601, "NON-FATAL always"). So `count="$(pool_reap_stale)""` is a
#   bare capture that is SAFE under set -e — NO `if !` guard. (Contrast the sibling
#   pool_admin_status, which MUST guard pool_lease_read rc 1 / pool_lane_is_stale rc 1/2.)
#   This is the ONE place pool_admin_reap is SIMPLER than status.

# CRITICAL (SC2155 — never `local x="$(…)"`): declare ALL locals up front, then assign.
#   The lib's house rule (pool_admin_status @lib/pool.sh:3595-3599). Applies to `count`.

# CRITICAL (`(( ))` as a STATEMENT returns 1 when result is 0 — design-decisions D5):
#   FATAL under set -e. Keep arithmetic inside `if`/`elif`. So `if (( count == 0 )); then …`
#   (inside if — safe); a BARE `(( count == 0 ))` when count==0 would ABORT. (Alternatively
#   use the string comparison `[[ "$count" == "0" ]]` — no arithmetic at all.)

# GOTCHA (literal `lane(s)` — design-decisions D4): the item contract's string is literally
#   "Reaped N stale lane(s)." — the `(s)` convention handles both N=1 and N>0. Do NOT
#   special-case the singular. printf 'Reaped %d stale lane(s).\n' "$count".

# GOTCHA (printf %d needs an integer — design-decisions D4): pool_reap_stale echoes a bare
#   integer token (digits only); `$()` strips the trailing newline. So count is always a
#   valid integer for `printf '%d'`. (If somehow non-numeric, %d would print 0 + a stderr
#   warning — but pool_reap_stale's contract guarantees digits-only.)

# GOTCHA (precondition can pool_die): pool_config_init / pool_state_init are rc-0-or-pool_die.
#   This is CORRECT — a misconfigured pool must fail loudly, not silently print "No stale
#   lanes found." No guard needed (matches pool_admin_status + pool_wrapper_main step "a").

# GOTCHA (the reap is DESTRUCTIVE but the wrapper is not): pool_admin_reap triggers
#   pool_reap_stale which tears down stale lanes (kills Chromes, rm dirs, deletes leases).
#   But pool_admin_reap ITSELF only captures + prints. The destruction is delegated. Do NOT
#   add a confirmation prompt — that is the DISPATCHER's job (M7.T5.S1 may add one), not the
#   library function's.
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk change, NO new env-vars/globals.
It captures one integer from `pool_reap_stale` and prints a formatted message. The only
local is the scalar `count`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the compose targets exist
  - RUN: test -f lib/pool.sh && echo "OK lib present"
  - EXPECT: present.
  - RUN (confirm this task is greenfield — NO existing pool_admin_reap):
        grep -n 'pool_admin_reap' lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield (no matches).
  - RUN (confirm the compose targets are defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_reap_stale pool_config_init pool_state_init; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; \
          done; echo "OK all compose targets defined"'
  - EXPECT: OK all compose targets defined.
  - RUN (confirm pool_reap_stale's contract — rc 0 always + echoes one integer):
        sed -n '2599,2602p' lib/pool.sh
  - EXPECT: `printf '%s\n' "$reaped"` … `return 0` (the count echo + always-0 return).
  - RUN (confirm the LANDED sibling pool_admin_status + its append site):
        grep -n '^pool_admin_status()' lib/pool.sh; wc -l lib/pool.sh; tail -2 lib/pool.sh
  - EXPECT: pool_admin_status defined @3594; EOF @3681 = its closing `}`. APPEND after it.
  - RUN (host tooling):
        bash --version | head -1
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not break existing syntax).

Task 1: APPEND pool_admin_reap() to lib/pool.sh (the verbatim contract)
  - PLACEMENT: APPEND at end of lib/pool.sh (after the closing `}` of pool_admin_status),
        preceded by the new banner. NO edits to any existing line.
  - IMPLEMENT (verbatim — paste exactly; the header doc-comment satisfies the item's
        DOCS step by documenting the reap command's behavior + output messages):

# ============================================================================
# Admin CLI — reap (P1.M7.T2.S1)
# ============================================================================
# pool_admin_reap
#
# PRD §2.12 `reap` / §2.10 — the USER-FACING reap report for
# `agent-browser-pool reap`. No input. Calls the LANDED pool_reap_stale
# (M5.T3.S1 — the lazy reaper: scans every lane, releases every stale one,
# echoes the reaped count), CAPTURES that count, and prints a human report to
# stdout. Returns 0 always.
#
# OUTPUT (the ONLY stdout — exactly one line):
#   N == 0  → "No stale lanes found."
#   N  > 0  → "Reaped N stale lane(s)."   (N = the integer from pool_reap_stale)
#
# The literal "lane(s)" handles both singular and plural (do not special-case N=1).
#
# CONTRACT:
#   - DELEGATE: ALL reap logic (lane enumeration, tri-state staleness verdict,
#     full teardown: daemon close + Chrome pgroup kill + rm dir + delete lease)
#     lives in pool_reap_stale. This function does NOT re-implement any of it.
#   - CAPTURE the count: pool_reap_stale writes the raw integer to ITS stdout
#     (for any caller's `count=$(…)»). This function MUST capture it
#     (count="$(pool_reap_stale)") so the integer does NOT leak to the user
#     alongside the message. pool_admin_reap's stdout is PURELY the one report.
#   - NON-FATAL always: NEVER calls pool_die in its own body; NEVER returns
#     non-zero. Reaping 0 lanes is NOT an error → "No stale lanes found." + rc 0.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_reap_stale returns rc 0 ALWAYS (lib/pool.sh:2601) → a bare capture
#     `count="$(pool_reap_stale)"` is SAFE — NO `if !` guard needed. (This is the
#     one place this function is SIMPLER than its sibling pool_admin_status, which
#     must guard pool_lease_read rc 1 / pool_lane_is_stale rc 1/2.)
#   - never `local x="$(…)"` (SC2155); declare then assign.
#   - `(( count == 0 ))` MUST be inside `if` (a bare `(( ))` statement returns 1
#     when the value is 0 → FATAL under set -e). The `$(( ))` expansion form is
#     always safe.
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case reap) pool_admin_reap ;;`.
pool_admin_reap() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`).
    local count

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3604-3606) + pool_wrapper_main step "a"
    # (lib/pool.sh:3455-3459). pool_state_init's idempotent mkdir -p guarantees
    # POOL_LANES_DIR exists (so a fresh pool's first reap works cleanly).
    pool_config_init
    pool_state_init

    # --- b. CAPTURE the reaped count from pool_reap_stale -----------------------
    # pool_reap_stale (M5.T3.S1): scans every lane, releases each stale one (full
    # teardown: close+kill+rm+rmlease), echoes ONE integer = the count reaped, rc 0
    # ALWAYS (non-fatal). The capture is MANDATORY: pool_reap_stale writes the raw
    # integer to ITS stdout — if we did NOT capture it, the integer would leak to
    # the user alongside our message. $() strips the trailing newline → bare token.
    # NO `if !` guard: pool_reap_stale rc 0 always (unlike pool_lease_read/pool_lane_is_stale).
    count="$(pool_reap_stale)"

    # --- c. print the human report (the ONLY stdout write in this function) -----
    # Bare `(( count == 0 ))` returns 1 when count==0 → FATAL under set -e. Inside
    # `if` it is errexit-exempt. count is digits-only (pool_reap_stale's contract),
    # so the arithmetic is always valid. The literal "lane(s)" handles N=1 and N>0.
    if (( count == 0 )); then
        printf 'No stale lanes found.\n'
    else
        printf 'Reaped %d stale lane(s).\n' "$count"
    fi

    # --- d. NON-FATAL always — never pool_die in body, never non-zero -----------
    return 0
}

  - VERIFY (immediately after):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (whole file)
        grep -n 'pool_admin_reap' lib/pool.sh | head -1          # the definition line
        git diff --stat lib/pool.sh                              # append-only diff
  - EXPECT: all OK; the only change to lib/pool.sh is the appended banner + function.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY lib/pool.sh modified (append-only). bin/, .gitignore, PRD.md,
        tasks.json, prd_snapshot.md UNCHANGED. NO new files outside plan/.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the wrapper spine (3 statements + the message):
pool_admin_reap() {
    local count
    pool_config_init          # precondition (rc 0 or pool_die)
    pool_state_init           # precondition (rc 0 or pool_die)
    count="$(pool_reap_stale)"   # CAPTURE (rc 0 always → no guard); prevents integer leak
    if (( count == 0 )); then    # inside if → errexit-exempt (bare (( )) is fatal @0)
        printf 'No stale lanes found.\n'
    else
        printf 'Reaped %d stale lane(s).\n' "$count"   # literal lane(s); %d needs integer
    fi
    return 0
}

# PATTERN — capture a rc-0-always function's stdout (NO guard, unlike non-zero helpers):
count="$(pool_reap_stale)"
#   pool_reap_stale returns 0 ALWAYS (lib/pool.sh:2601) → bare capture is set -e-safe.
#   CONTRAST the sibling pool_admin_status which MUST guard:
#     if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …   # pool_lease_read rc 1
#   This function has NO such guard because its ONE dependency never fails.

# GOTCHA — WHY capture pool_reap_stale and not let it write directly:
#   pool_reap_stale writes the raw integer ("2") to stdout. The user wants the MESSAGE
#   ("Reaped 2 stale lane(s)."), not the raw integer. Capturing lets us print ONLY the
#   message. Without capture the user sees BOTH the integer and the message (broken UX).

# GOTCHA — WHY `if (( count == 0 ))` and not bare `(( count == 0 ))`:
#   a bare `(( ))` statement returns rc 1 when the expression is 0 → FATAL under set -e.
#   Inside `if` it is exempt. (Alternatively `[[ "$count" == "0" ]]` avoids arithmetic.)

# GOTCHA — WHY literal "lane(s)" and not a pluralization branch:
#   the item contract (step 3b) literally says 'Reaped N stale lane(s).' — the "(s)"
#   convention is the spec for both N=1 and N>0. No `if (( count == 1 ))` branch.

# GOTCHA — WHY no confirmation prompt before the destructive reap:
#   pool_reap_stale is DESTRUCTIVE (kills Chromes, rm dirs). But pool_admin_reap is a
#   LIBRARY function (no stdin interaction). Any confirmation prompt is the DISPATCHER's
#   job (M7.T5.S1, which may add `read -p` before calling pool_admin_reap). This function
#   just runs the reap + reports. (PRD §2.12 lists `reap` with no `[--yes]` flag → no
#   confirmation is the current spec.)
```

### Integration Points

```yaml
FILESYSTEM:
  - modify: "lib/pool.sh (APPEND-ONLY: banner + pool_admin_reap() after line 3681)"

LIBRARY (lib/pool.sh):
  - composes: "pool_config_init + pool_state_init (precondition); pool_reap_stale (the
              reap). All LANDED + contract-documented — pool_reap_stale rc 0 always."

GITIGNORE:
  - no change: ".gitignore is orchestrator-owned (M10.T1.S2); no rule matches the diff."

CONSUMERS (the dispatcher, FUTURE — NOT this task):
  - M7.T5.S1 bin/agent-browser-pool: "case \"\$cmd\" in reap) pool_admin_reap ;; …".
            This task does NOT create the binary. It only provides the function the
            binary will call by name."

SUGGESTED --help TEXT (for M7.T5.S1 to reference — NOT wired by this task):
  - "  reap                     kill+delete dead-owner lanes; print a reap report"
  - The dispatcher (M7.T5.S1) will echo this under the global `agent-browser-pool --help`
            usage block. This task documents the reap command's behavior in the function's
            header doc-comment (Mode A) so the dispatcher author has the source of truth.

NO CHANGES TO:
  - any existing lib/pool.sh function (append-only), bin/ (M6.T3.S2 owns agent-browser;
    M7.T5.S1 owns agent-browser-pool), .gitignore, PRD.md / tasks.json / prd_snapshot.md
    (read-only), test/ (M9.T1.S1 owns the harness).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the function — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (WHOLE file)
grep -n 'pool_admin_reap' lib/pool.sh | head -1          # the definition exists
git diff --stat lib/pool.sh                              # append-only (no -/= churn in middle)
# Expected: all OK. The diff should be purely additive (~55 + lines, 0 deletions).
#   shellcheck zero warnings: watch SC2155 (declare-then-assign for `count`),
#   SC2086 (quote "$count" in printf). The `(( count == 0 ))` inside `if` is clean.
```

### Level 2: Unit Tests (Component Validation — NO Chrome needed)

`pool_admin_reap` is a thin capture+format wrapper. Its message logic is fully
verifiable WITHOUT Chrome / a master profile / a real reap by **overriding
`pool_reap_stale`** in the test to echo a fixed count — isolating pool_admin_reap's
formatting from the reap teardown entirely. PLUS one integration case with a real
synthetic stale lease.

```bash
# Save as /tmp/test_reap.sh and run: bash /tmp/test_reap.sh
# Run from the REPO ROOT.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/lib/pool.sh" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1" >&2; }

# --- fresh isolated state dir (the precondition needs valid config) ---
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"
mkdir -p "$STATE/lanes"
export AGENT_CHROME_MASTER="$STATE/master" AGENT_CHROME_EPHEMERAL_ROOT="$STATE/active"
export POOL_LOG_PATH=/dev/null   # keep stderr clean

source ./lib/pool.sh
pool_config_init   # freezes globals (POOL_LANES_DIR, POOL_REAL_BIN, etc.)

# ============================================================================
# PART A — UNIT TESTS: override pool_reap_stale to echo a fixed count, isolating
# pool_admin_reap's MESSAGE logic from the reap teardown. Fully deterministic,
# no Chrome, no close subprocess, no FS mutation.
# ============================================================================

# ---- Case A1: count==0 → "No stale lanes found." + rc 0 ----------------------
pool_reap_stale() { printf '%s\n' "0"; }   # override
out="$(pool_admin_reap)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "A1-zero: rc 0" || bad "A1-zero: rc=$rc"
[[ "$out" == "No stale lanes found." ]] && ok "A1-zero: exact message" \
    || bad "A1-zero: got [$out]"
# exactly ONE line (no raw integer leaked):
[[ "$(grep -c . <<<"$out")" -eq 1 ]] && ok "A1-zero: one line (no int leak)" \
    || bad "A1-zero: multiline [$out]"

# ---- Case A2: count==1 → "Reaped 1 stale lane(s)." + rc 0 --------------------
pool_reap_stale() { printf '%s\n' "1"; }
out="$(pool_admin_reap)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "A2-one: rc 0" || bad "A2-one: rc=$rc"
[[ "$out" == "Reaped 1 stale lane(s)." ]] && ok "A2-one: exact message (literal lane(s))" \
    || bad "A2-one: got [$out]"
[[ "$(grep -c . <<<"$out")" -eq 1 ]] && ok "A2-one: one line" || bad "A2-one: multiline"

# ---- Case A3: count==5 → "Reaped 5 stale lane(s)." ---------------------------
pool_reap_stale() { printf '%s\n' "5"; }
out="$(pool_admin_reap)"
[[ "$out" == "Reaped 5 stale lane(s)." ]] && ok "A3-five: plural message" \
    || bad "A3-five: got [$out]"

# ---- Case A4: stdout is PURELY the message (capturable, no integer leak) -----
pool_reap_stale() { printf '%s\n' "3"; }
out="$(pool_admin_reap)"
# the raw "3" must NOT appear on its own line (it was captured, not passed through):
! grep -qx '3' <<<"$out" && ok "A4-discipline: no raw integer line" \
    || bad "A4-discipline: raw integer leaked [$out]"
[[ "$out" == "Reaped 3 stale lane(s)." ]] && ok "A4-discipline: only the message" \
    || bad "A4-discipline: [$out]"

# ---- Case A5: large count (e.g. 12) → "Reaped 12 stale lane(s)." ------------
pool_reap_stale() { printf '%s\n' "12"; }
out="$(pool_admin_reap)"
[[ "$out" == "Reaped 12 stale lane(s)." ]] && ok "A5-twelve: two-digit count" \
    || bad "A5-twelve: got [$out]"

# ============================================================================
# PART B — INTEGRATION TEST: the REAL pool_reap_stale against a synthetic stale
# lease (dead-owner-pid trick). Confirms the capture path works end-to-end.
# NO real Chrome needed: pool_release_lane's close is fast + rc 0 on a missing
# daemon; kill/rm of nonexistent pid/dir are || true.
# ============================================================================
unset -f pool_reap_stale   # restore the REAL function

# B-pre: empty pool → real reap echoes 0 → "No stale lanes found."
out="$(pool_admin_reap)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "B-empty: rc 0" || bad "B-empty: rc=$rc"
[[ "$out" == "No stale lanes found." ]] && ok "B-empty: real-empty message" \
    || bad "B-empty: got [$out]"

# B-stale: write a synthetic stale lease (dead owner pid 99998 — not alive).
# pool_lane_is_stale → rc 0 (stale) → pool_release_lane tears it down → count 1.
NOW="$(date +%s)"
jq -n --argjson lane 1 --argjson port 53421 --arg session "abpool-1" \
      --argjson owner_pid 99998 --arg owner_cwd "$STATE" --argjson chrome_pid 9999999 \
      --argjson acquired_at "$NOW" --argjson connected false \
      '{version:1, lane:$lane, ephemeral_dir:"", port:$port, session:$session,
        owner:{pid:$owner_pid, comm:"pi", starttime:1111, cwd:$owner_cwd},
        chrome_pid:$chrome_pid, chrome_pgid:$chrome_pid,
        acquired_at:$acquired_at, last_seen_at:$acquired_at, connected:$connected}' \
      > "$STATE/lanes/1.json"

out="$(pool_admin_reap)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "B-stale: rc 0" || bad "B-stale: rc=$rc"
[[ "$out" == "Reaped 1 stale lane(s)." ]] && ok "B-stale: real-reap message (count=1)" \
    || bad "B-stale: got [$out]"
# the stale lease was reaped (deleted):
[[ ! -f "$STATE/lanes/1.json" ]] && ok "B-stale: lease reaped (gone)" \
    || bad "B-stale: lease still present"

# B-idempotent: re-reap → 0 stale → "No stale lanes found."
out="$(pool_admin_reap)"
[[ "$out" == "No stale lanes found." ]] && ok "B-idempotent: re-reap → 0" \
    || bad "B-idempotent: got [$out]"

rm -rf "$STATE"
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≥15, fail=0. (Part A is fully deterministic — the message contract.
#   Part B confirms the real capture path: empty→message, stale→message+lease-gone,
#   idempotent re-reap→0. No real Chrome — the dead-owner-pid trick + close=rc0-fast.)
```

### Level 3: Integration Testing (System Validation)

The full end-to-end (a real pooled Chrome lane exists, its owner dies, and `reap`
cleans it up) needs a real Chrome + master profile + a `pi` ancestor — the domain
of the M9 harness. **For this task, Level 2's tests ARE the integration proof**
(Part B exercises the real `pool_reap_stale` capture path against a synthetic
stale lease). A smoke once the dispatcher (M7.T5.S1) lands + a real lane is acquired:

```bash
# PREREQ: a lane acquired via the wrapper (run inside pi). Then KILL the owning pi
# (so the lane goes stale). Then, from a human terminal:
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool}" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_reap'
# Expected: "Reaped 1 stale lane(s)." (the dead-owner lane torn down). Re-run →
# "No stale lanes found." (idempotent). Verify with `pool_admin_status` → empty.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Capturability (PRD §2.12 admin ergonomics): the report is exactly one capturable line.
out="$(bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_reap')"
echo "captured: [$out]"   # exactly "No stale lanes found." or "Reaped N stale lane(s)."

# Pipeability: reap | grep Reaped works (stdout is one clean line).
bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_reap' | grep -E '^(Reaped|No stale)' || true

# Non-fatal under a corrupt lease (pool_reap_stale skips rc-2 corrupt leases — they are
# NOT reaped, NOT counted). A pool with a corrupt lease + 0 stale → "No stale lanes found."
# (Already covered by pool_reap_stale's own M5.T3.S1 contract; pool_admin_reap just reports
# the count it returns.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` zero
      warnings (whole file) + `git diff --stat lib/pool.sh` is append-only (0 deletions).
- [ ] Level 2 passes (pass≥15, fail=0): Part A (override pool_reap_stale → exact messages
      for N=0/1/5/12 + no integer leak), Part B (real reap: empty→message, stale→message+
      lease-gone, idempotent re-reap→0).

### Feature Validation

- [ ] `pool_admin_reap()` appended under banner `# Admin CLI — reap (P1.M7.T2.S1)`.
- [ ] Empty pool / 0 stale → exactly `No stale lanes found.\n` (rc 0; no raw integer).
- [ ] N>0 stale → exactly `Reaped N stale lane(s).\n` (N from pool_reap_stale; rc 0; no
      raw integer).
- [ ] stdout is purely the one report line (capturable; no `_pool_log`/raw-integer leak).
- [ ] Returns 0 always; never calls `pool_die` in its own body.

### Code Quality Validation

- [ ] Follows house style: `set -euo pipefail`-safe (the capture needs NO guard because
      pool_reap_stale rc 0 always), SC2155 (declare-then-assign for `count`), `(( ))` only
      inside `if`, banner convention, doc-comment header.
- [ ] Composes ONLY landed helpers (no new system interaction, no flock, no Chrome, no
      re-implementation of the reap loop).
- [ ] Anti-patterns avoided: no bare `(( count == 0 ))` statement (fatal @0); no
      pass-through of pool_reap_stale's stdout (would leak the integer); no `pool_die` in
      the body (non-fatal); no edits to existing functions; no confirmation prompt (that is
      the dispatcher's job).
- [ ] The header doc-comment documents the output messages + non-fatal contract (item DOCS).

### Documentation & Deployment

- [ ] The function is self-documenting via its header doc-comment (messages + contract).
- [ ] No new env-vars; no `.gitignore` change; no new files; the dispatcher + `--help` wiring
      is M7.T5.S1.
- [ ] The suggested `--help` text ("reap  kill+delete dead-owner lanes; print a reap report")
      is provided in Integration Points for M7.T5.S1 to reference.

---

## Anti-Patterns to Avoid

- ❌ Don't build `bin/agent-browser-pool` or wire `--help` — that is M7.T5.S1. This task is
      **lib-only**: append `pool_admin_reap()` to `lib/pool.sh`. Nothing else.
- ❌ Don't edit any existing function in `lib/pool.sh` — append-only. `git diff` must be purely
      additive (0 deletions in the existing body).
- ❌ Don't call `pool_reap_stale` WITHOUT capturing — it writes the raw integer count to ITS
      stdout; if you don't capture, the integer leaks to the user alongside the message.
      ALWAYS `count="$(pool_reap_stale)"`.
- ❌ Don't re-implement the reap loop — DELEGATE to `pool_reap_stale` (M5.T3.S1). It owns lane
      enumeration, the tri-state staleness verdict, and the full teardown. Re-implementing
      duplicates a verified function and risks divergence.
- ❌ Don't write a bare `(( count == 0 ))` statement — it returns rc 1 when count==0 → FATAL
      under `set -e`. Keep it inside `if (( count == 0 )); then …` (errexit-exempt).
- ❌ Don't special-case the singular "lane" — the item contract is literally "lane(s)"; the
      `(s)` convention handles N=1 and N>0. No `if (( count == 1 ))` branch.
- ❌ Don't add a `local x="$(…)"` (SC2155) — declare `local count` first, then assign.
- ❌ Don't add a confirmation prompt (`read -p`) — `pool_admin_reap` is a library function
      (no stdin interaction). Any prompt is the DISPATCHER's job (M7.T5.S1). PRD §2.12 lists
      `reap` with no `[--yes]` flag → no confirmation is the current spec.
- ❌ Don't call `pool_die` or return non-zero in the body — reaping 0 lanes is NOT an error.
      (The precondition helpers may `pool_die` on genuine misconfiguration — that is correct.)
- ❌ Don't print anything but the one report line to stdout — `_pool_log` (file+stderr) must
      not leak; the raw integer must be captured; stdout stays one clean capturable line.
- ❌ Don't modify `.gitignore`, `PRD.md`, `tasks.json`, `prd_snapshot.md`, `bin/`, or `test/` —
      those are owned by other tasks / the orchestrator / humans.

---

## Confidence Score: 9/10

**Why high**: This is a 0.5-point THIN WRAPPER over a single LANDED, validated,
contract-documented function (`pool_reap_stale`, which returns 0 always + echoes one
integer). The entire implementation is ~8 lines (init → capture → if/else printf →
return 0). The ONE non-trivial decision (capture the count to prevent integer leak) is
explicitly pinned (design-decisions D3/D7) with a copy-pasteable code block. The message
strings are verbatim from the item contract. The append site is confirmed (after the
LANDED `pool_admin_status`, EOF @3681). The bash gotchas (`(( ))` inside `if`, SC2155,
capture safety) are all documented with the exact safe form.

**Why not 10**: A thin wrapper is low-risk, but the residual 1/10 is for (a) the
integration test's reliance on `pool_release_lane`'s close being fast + rc 0 on a missing
daemon (research-asserted, host-verified in M5.T2.S1, but environment-dependent) —
mitigated by Part A's override-based unit tests which are fully deterministic and need no
close subprocess at all; and (b) the parallel-execution context: `pool_admin_status`
LANDED first, so the append site is stable, but the orchestrator's sequencing of the M7
subtasks could theoretically affect the exact EOF line number (the PRP's Task 0 verifies
the live EOF before appending).
