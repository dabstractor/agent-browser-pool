# PRP — P1.M7.T3.S1: `pool_admin_release(target)` — `release [<N>|all]` explicit lane teardown

---

## Goal

**Feature Goal**: Implement **`pool_admin_release(target)`** — the user-facing
release wrapper for the `agent-browser-pool release [<N>|all]` admin command
(PRD §2.12 / §2.5 "Explicit release"). It takes **ONE optional argument**
(`all`, a lane number `N`, or nothing/invalid), **classifies** it, and:
**(a)** `all` → iterate every lane from `pool_lanes_list` and `pool_release_lane`
each, then print a count summary; **(b)** a number `N` whose lease **exists**
(`pool_lease_exists`) → `pool_release_lane N` + print `Released lane N.`;
**(c)** empty/invalid → print usage to stderr; **(d)** a number `N` with **no
lease** → print `Lane N has no active lease.`. It reuses the LANDED
`pool_release_lane` (M5.T2.S1, `lib/pool.sh:2438`). The `status` command
(M7.T1.S1, LANDED), the `reap` command (M7.T2.S1, LANDED in parallel), the
`doctor` command (M7.T4), and the `bin/agent-browser-pool` **dispatcher** (M7.T5.S1)
are all SEPARATE tasks.

**Deliverable**: ONE new PUBLIC function `pool_admin_release()`, **APPENDED** to
`lib/pool.sh` directly after the LANDED `pool_admin_reap` (current EOF
`lib/pool.sh:3762`), introduced by a NEW section banner
`# Admin CLI — release (P1.M7.T3.S1)`. **Pure addition: no edits to any existing
function, no new private helpers, no new env-vars/globals, no new files.** It
COMPOSES four LANDED helpers — `pool_config_init` + `pool_state_init`
(precondition, M1.T1.S2/S3) + `pool_lanes_list` (M3.T2.S1) + `pool_lease_exists`
(M3.T2.S1) + `pool_release_lane` (M5.T2.S1) — plus `printf`/`mapfile`/`(( ))`
(already used throughout the lib).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`:
  - **(a) `release all`, N>0 lanes** → each lane's lease/dir/Chrome torn down (via
    `pool_release_lane`); prints EXACTLY `Released N lane(s).` (N = lane count); rc 0.
  - **(a) `release all`, empty pool** → prints EXACTLY `No active lanes to release.`; rc 0.
  - **(b) `release N`, lease exists** → lane N torn down; prints EXACTLY
    `Released lane N.`; rc 0.
  - **(c) `release` / `release foo`** → prints the usage block to **stderr**; stdout
    EMPTY; rc 1.
  - **(d) `release 99`, no lease** → prints EXACTLY `Lane 99 has no active lease.`;
    rc 1; nothing torn down.
- **stdout discipline**: stdout is PURELY the one result line (capturable:
  `out="$(pool_admin_release "$arg")"` yields exactly the message). Usage goes to
  stderr (stdout stays empty on the usage path). `_pool_log` writes to the log file +
  stderr (never stdout).
- **Return codes**: rc 0 for successful releases (all cases + numeric-found); rc 1
  for usage-error (c) and targeted-not-found (d). **NEVER `pool_die`** in the body.
  (The precondition helpers may `pool_die` on genuine misconfiguration — correct.)
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file,
  ZERO warnings — host-verified ShellCheck 0.11.0); all prior deliverables
  (M1–M7.T2.S1) unchanged and still callable; `lib/pool.sh`'s only diff is the
  appended banner + function.

> **⚠ PARALLEL-EXECUTION STATUS NOTE (read before implementing).** All line numbers
> and the "greenfield" framing below were verified at the **start** of this research
> session (file was 3762 lines; `pool_admin_release` absent; append site = after the
> LANDED `pool_admin_reap` @3730–3762). **During this session a parallel implementer
> landed `pool_admin_release()` at `lib/pool.sh:3830–3908` (file now 3908 lines).**
> That landed implementation matches this PRP's spec near-verbatim (same classify spine
> `all`→numeric→else, same `pool_lease_exists`-before-`pool_release_lane` probe, same
> messages, same rc 0/1 contract, same usage-to-stderr). **Therefore:**
> - **If implementing:** run Task 0 first. If `pool_admin_release` **already exists**
>   AND matches this spec → **verify it in place** (do NOT append a duplicate). If it
>   is **absent** → append it after the LAST admin function (verify the **live** EOF;
>   the 3762 number is research-time only and WILL have drifted).
> - The PRP remains the **authoritative spec** either way — it is what the function
>   must satisfy. The validation tests (Level 2 Parts A/B/C) verify the spec
>   regardless of which agent wrote the code.

## User Persona

**Target User**: Human admin (PRD §2.5 "Explicit release" row; §1.5). The function is
called indirectly — the `bin/agent-browser-pool` dispatcher (M7.T5.S1) wires
`case "$cmd" in release) pool_admin_release "$@" ;;`. This task builds the LIBRARY
function only; the dispatcher binary is future work.

**Use Case**: A lane is misbehaving, or an admin wants to reclaim a specific lane
(purposefully, regardless of owner liveness), or wipe the whole pool at end of day.
The admin runs `agent-browser-pool release 3` (tear down lane 3 — even if its owner
is alive; explicit teardown) or `agent-browser-pool release all` (reclaim every
lane). `pool_admin_release` classifies the argument, probes existence (for a number),
delegates the teardown to `pool_release_lane`, and prints a one-line confirmation.

**User Journey**: `agent-browser-pool release 3` → reads `Released lane 3.` → (to
confirm the pool is now clean) runs `agent-browser-pool status` (M7.T1.S1). For
`release all`, reads `Released N lane(s).` then `status` → `No active lanes.`

**Pain Points Addressed**: Without `release`, the only way to tear down a lane is to
wait for its owner to die (lazy reap on next acquire) or run `reap` (which is
**stale-only** — it SKIPS live-owner lanes). `release` gives the admin EXPLICIT,
on-demand teardown of a named lane (live OR stale) or the whole pool — no editing of
`lanes/*.json`, no manual `kill`/`rm`.

## Why

- **This IS PRD §2.12's `release` command** (`release [<N>|all]  # explicit teardown`)
  and PRD §2.5's "Explicit `agent-browser-pool release [<N>|all]`" release trigger —
  one of the three release triggers (owner exit / **explicit release** / exhaustion
  force-reap). It is the PRIMARY documented admin consumer of `pool_release_lane`.
- **It is a THIN CLASSIFIER + DELEGATOR — it does not duplicate teardown.** ALL the
  teardown logic (daemon close + Chrome pgroup kill + rm dir + delete lease) lives in
  the LANDED, validated, idempotent, rc-0-always `pool_release_lane` (M5.T2.S1).
  `pool_admin_release` only: init → classify the argument → (for a number) probe
  existence → delegate → print the right message. Re-implementing teardown would
  duplicate a carefully-verified function + risk divergence. (DRY.)
- **Its single non-trivial decision is the existence probe.** `pool_release_lane` is
  idempotent + rc-0-always + **silently no-ops on a missing lease** — it CANNOT signal
  "lane N had no lease" (both "released" and "no lease" are rc 0). So the contract's
  two distinct numeric branches (`Released lane N.` vs `Lane N has no active lease.`)
  REQUIRE a SEPARATE `pool_lease_exists` probe BEFORE delegating. This is the dominant
  correctness constraint (design-decisions D5).
- **It is DISTINCT from reap.** `reap` (M7.T2.S1) is STALE-ONLY (it skips live-owner
  lanes via `pool_reap_stale`). `release` is EXPLICIT (the admin named the lane(s) —
  live OR stale, it is torn down). Routing release through `pool_reap_stale` would
  WRONGLY skip live-owner lanes. (design-decisions D10.)
- **It must NOT duplicate or conflict with sibling tasks.** M7.T1.S1 (`status`,
  LANDED), M7.T2.S1 (`reap`, LANDED in parallel), M7.T4.S1 (`doctor`), M7.T5.S1 (the
  dispatcher + `--help` wiring) are all separate. This task owns ONLY
  `pool_admin_release()` in `lib/pool.sh`.

## What

User-visible behavior: **`agent-browser-pool release [<N>|all]`** tears down the named
lane(s) (explicit teardown — live OR stale) and prints a one-line confirmation, OR
prints usage (empty/invalid) / a not-found message (a number with no lease).

### The contract (authoritative from item description + research)

**Input**: ONE optional argument `target` (the string `all`, a lane number `N`, or
empty/invalid).

**Logic (item contract, verbatim):**
- a. If `target == 'all'`: snapshot `pool_lanes_list`; if empty → `No active lanes to
  release.`; else `pool_release_lane` each, then `Released N lane(s).` (N = count). rc 0.
- b. If `target` is a number AND `pool_lease_exists target`: `pool_release_lane target`;
  `Released lane N.`. rc 0.
- c. If `target` is empty OR invalid (not `all`, not `^[0-9]+$`): print usage to
  stderr. rc 1.
- d. If `target` is a number AND NOT `pool_lease_exists target`:
  `Lane N has no active lease.`. rc 1.

**Precondition**: `pool_config_init` + `pool_state_init` (mirrors `pool_admin_status`
`lib/pool.sh:3604-3606` + `pool_admin_reap` `lib/pool.sh:3738-3742`).

### Success Criteria

- [ ] `pool_admin_release()` appended to `lib/pool.sh` under banner
      `# Admin CLI — release (P1.M7.T3.S1)`; no other function touched.
- [ ] `bash -n lib/pool.sh` → exit 0; `shellcheck -s bash lib/pool.sh` → ZERO warnings.
- [ ] `release all` (N>0) → `Released N lane(s).\n` (N = lane count), rc 0, lanes torn down.
- [ ] `release all` (empty) → `No active lanes to release.\n`, rc 0.
- [ ] `release N` (exists) → `Released lane N.\n`, rc 0, lane N torn down.
- [ ] `release` / `release foo` → usage to stderr, stdout EMPTY, rc 1.
- [ ] `release 99` (no lease) → `Lane 99 has no active lease.\n`, rc 1, nothing torn down.
- [ ] stdout is PURELY the one result line (capturable); usage goes to stderr.
- [ ] Returns 0 on success, 1 on usage/not-found; never `pool_die` in its own body.
- [ ] `lib/pool.sh` diff is append-only (banner + function); `bin/`, `.gitignore`,
      `PRD.md`, `tasks.json` untouched.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **verbatim function
contract** (item description + research, re-stated with copy-pasteable code); the
**single critical gotcha** — `pool_release_lane` is idempotent + rc-0-always +
silently no-ops on a missing lease, so the numeric branch MUST probe
`pool_lease_exists` BEFORE delegating (design-decisions D5); the **classification
order** (`all` → numeric → else, design-decisions D3); the **return-code rationale**
(why release returns rc 1 for usage/not-found, diverging from the reap sibling's
rc-0-always — design-decisions D6); the **pinned message strings** (verbatim from the
item contract); the **`(( ))`-inside-`if`** + **rc-1-helper-must-guard** + **SC2155**
safety rules; the **append site** (after the LANDED `pool_admin_reap`, EOF @3762);
the **banner convention**; host-verified tooling (bash 5.3, ShellCheck 0.11); and
copy-pasteable, **no-Chrome** validation (unit tests that override
`pool_release_lane` + synthetic-lease integration cases).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.12 (admin CLI: `release [<N>|all]  # explicit teardown`). §2.5 (Release
        semantics — the "Explicit `agent-browser-pool release [<N>|all]`" trigger row;
        same teardown as owner-exit: kill pgroup + rm dir + delete lease + daemon close).
        §1.5 (user story: the admin operates the pool).
  pattern: §2.12's `release` IS this command; §2.5's "Explicit release" row names it.
  gotcha: §2.5 — release is EXPLICIT (admin-named, live-or-stale). It is NOT reap
        (§2.10 reap is STALE-ONLY). Do NOT route release through pool_reap_stale.

# This task's own research (the factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M7T3S1/research/codebase-release-facts.md
  why: §1 pool_release_lane's EXACT contract (rc 0 ALWAYS; idempotent; SILENTLY no-ops
        on a missing lease → the not-found branch CANNOT be detected from pool_release_lane's
        rc — REQUIRES a separate pool_lease_exists probe). §2 pool_lease_exists (rc 0/1
        BOOLEAN predicate; rc 1 MUST be guarded under set -e). §3 pool_lanes_list (rc 0
        always; digits sorted; empty = 0 output → safe `for n in $(…)»). §4 the LANDED
        siblings pool_admin_status + pool_admin_reap (the shape to mirror: precondition +
        locals-up-front + the snapshot/mapfile idiom + return 0). §5 the precondition. §6
        the set -e / SC2155 / (( )) gotchas. §7 stdout discipline. §8 the DOCS/--help
        boundary (Mode A). §9 the parallel-execution append site (after pool_admin_reap).
        §10 the sibling boundaries.
  pattern: §1's idempotency + §2's probe ARE the numeric branch; §4's shape IS the structure.
  gotcha: §1 — pool_release_lane swallows "no lease" as rc 0; §2 — pool_lease_exists rc 1
        ABORTS under set -e if called bare (MUST use `if pool_lease_exists …; then`).

- file: plan/001_0f759fe2777c/P1M7T3S1/research/design-decisions.md
  why: D1 (lib-only, append after pool_admin_reap, own banner). D2 (ONE optional positional
        target="${1:-}"). D3 (classify all → numeric → else). D4 (all: snapshot mapfile +
        count summary; literal lane(s)). D5 (numeric: probe pool_lease_exists BEFORE
        pool_release_lane — THE key decision). D6 (return codes: rc 0 success / rc 1 usage+
        not-found; WHY it diverges from reap's rc-0-always). D7 (stdout=result, stderr=usage).
        D8 (usage block to stderr). D9 (DOCS via header + suggested --help). D10 (release is
        EXPLICIT, NOT reap — do not route through pool_reap_stale). D11 (no flock, no prompt).
  pattern: D3's classify + D4's all-branch + D5's numeric-branch ARE the implementation.
  gotcha: D5 — calling pool_release_lane WITHOUT the probe prints "Released lane N." even
        when the lane was absent (WRONG — must be "Lane N has no active lease."). D6 — bare
        `(( ))` returns 1 @0 (fatal); keep inside `if`.

# The LANDED siblings (the shape to mirror — same lib-only, append-under-banner form)
- file: plan/001_0f759fe2777c/P1M7T2S1/PRP.md
  why: pool_admin_reap() (LANDED @ lib/pool.sh:3730) is the CLOSEST analog — also a
        lib-only admin command, also precondition, also locals-up-front, also delegates to
        ONE LANDED helper + prints a report. Its header doc-comment style + house rules ARE
        the pattern. This task APPENDS directly after it (it is the current EOF @3762).
  pattern: "append to lib/pool.sh under banner X; compose landed helpers; print one report
        line; locals up front; SC2155; (( )) inside if" is the exact shape.
  gotcha: reap is rc-0-always (it cannot fail — pool_reap_stale is rc 0 always). release is
        NOT: it returns rc 1 for usage/not-found (a structural difference — release takes an
        argument and can hit "not found"). See design-decisions D6.
- file: plan/001_0f759fe2777c/P1M7T1S1/PRP.md
  why: pool_admin_status() (LANDED @ lib/pool.sh:3594) — the `mapfile -t lanes < <(pool_lanes_list)`
        snapshot idiom + the empty-pool `(( ${#lanes[@]} == 0 ))` check ARE reused verbatim
        in this task's `all` branch.
  pattern: status's snapshot-first + empty-check is the `all` branch's structure.

# The function being delegated to (the REAL teardown dependency)
- file: plan/001_0f759fe2777c/P1M5T2S1/PRP.md
  why: pool_release_lane(LANE) (LANDED @ lib/pool.sh:2438) is what pool_admin_release CALLS.
        Its contract (rc 0 ALWAYS; idempotent; missing lease → return 0 SILENTLY; self-validates
        the lane) is the foundation. Its own docstring names M7.T3's release command as a
        consumer (`pool_release_lane "$N"` (or iterate all)).
  pattern: the CALLER CONTRACT `pool_release_lane "$N"` is EXACTLY what the numeric branch
        implements; the `for n in $(pool_lanes_list); do … pool_release_lane "$n"; done` is
        EXACTLY what the `all` branch implements.
  gotcha: pool_release_lane returns 0 on a missing lease with NO signal → the numeric branch
        MUST probe pool_lease_exists FIRST (else "Released lane N." prints for an absent lane).

# The existence-probe predicate (the not-found detection)
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md
  why: pool_lease_exists(LANE) (LANDED @ lib/pool.sh:918) — rc 0 = valid lease exists; rc 1 =
        missing/corrupt/non-numeric. This is EXACTLY step (d)'s "Lane N has no active lease"
        probe. rc 1 MUST be guarded (`if pool_lease_exists …; then … else …; fi`).

# The library this function is appended to (read header + EOF to confirm append site)
- file: lib/pool.sh
  why: line 23 (set -euo pipefail — every gotcha is live). pool_release_lane @2438 (rc 0
        always; missing lease → return 0 @2448-2449). pool_lease_exists @918 (rc 0/1; the
        predicate). pool_lanes_list @967 (rc 0 always; digits sorted). pool_admin_status @3594
        (mapfile snapshot @3624; empty check @3629). pool_admin_reap @3730 (closest analog;
        banner @3689-3691). EOF @3762 (closing } of pool_admin_reap) — the append site.
  pattern: pool_admin_reap's body (@3730-3762) is the closest structure to reuse (precondition
        → logic → return), plus status's mapfile idiom for the `all` branch.
  gotcha: pool_lease_exists rc 1 → MUST be inside `if` (bare call ABORTS under set -e).
        pool_release_lane rc 0 always → bare call is safe (no guard).
```

### Current Codebase tree

After **M1–M7.T2.S1** landed (status LANDED, reap LANDED in parallel), `lib/pool.sh`
(3762 lines) ends at `pool_admin_reap` (closing `}` @3762). `bin/agent-browser`
exists (M6.T3.S2). The admin CLI binary does NOT exist yet (M7.T5.S1). **THIS task
appends `pool_admin_release()` to `lib/pool.sh`:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   ├── .gitkeep                          # retained (admin CLI bin/agent-browser-pool is M7.T5.S1)
│   └── agent-browser                     # M6.T3.S2 (the wrapper shim) — UNCHANGED
├── lib/
│   └── pool.sh                           # EOF @3762 (pool_admin_reap). THIS task APPENDS
│                                         #   the banner "# Admin CLI — release (P1.M7.T3.S1)"
│                                         #   + pool_admin_release() after line 3762.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M7T3S1/
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-release-facts,design-decisions}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                           # MODIFIED (append-only): +banner +pool_admin_release() at EOF
└── (no other files change)
```

**File responsibility**: `pool_admin_release(target)` is the **user-facing release
command** backing `agent-browser-pool release [<N>|all]`. It owns NO teardown logic —
it classifies the argument, probes existence (for a number), delegates entirely to
`pool_release_lane`, and prints the right confirmation. It is consumed by the future
dispatcher (M7.T5.S1: `case release) pool_admin_release "$@" ;;`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the existence probe — design-decisions D5): pool_release_lane is idempotent +
#   rc-0-always + SILENTLY no-ops on a missing lease (lib/pool.sh:2448-2449: `if ! json=…;
#   then return 0; fi`). So `pool_release_lane 99` (no lease) returns 0 with NO signal that
#   the lease was absent. The contract's two distinct numeric branches REQUIRE a SEPARATE
#   pool_lease_exists probe BEFORE delegating:
#       if pool_lease_exists "$target"; then pool_release_lane "$target"; printf 'Released lane %s.\n' …
#       else printf 'Lane %s has no active lease.\n' …; fi
#   WITHOUT the probe, `release 99` (absent) would wrongly print "Released lane 99."

# CRITICAL (pool_lease_exists rc 1 ABORTS under set -e — design-decisions D5 / facts §2):
#   a BARE `pool_lease_exists "$lane"` whose rc is 1 (no lease) ABORTS the caller. ALWAYS
#   use `if pool_lease_exists "$lane"; then …; else …; fi` (rc 1 falls into else, errexit-
#   exempt). This is the SAME hazard as pool_lane_is_stale / pool_lease_read.

# CRITICAL (pool_release_lane rc 0 always → NO guard needed — facts §1): once the existence
#   probe passes, `pool_release_lane "$target"` is a BARE call (safe under set — e). Do NOT
#   wrap it in `if !`. (Contrast pool_lease_exists which MUST be guarded.)

# CRITICAL (SC2155 — never `local x="$(…)"`): declare ALL locals up front, then assign. For
#   `target` use `local target="${1:-}"` — this is a parameter expansion (NOT a `$(…)` capture),
#   so inline `local target=…` is SC2155-safe. For any `$(…)` capture, declare then assign.
#   The house rule (pool_admin_status @lib/pool.sh:3595-3602, pool_admin_reap @3736).

# CRITICAL (`(( ))` as a STATEMENT returns 1 when result is 0 — design-decisions D6):
#   FATAL under set -e. Keep arithmetic INSIDE `if`. So `if (( ${#lanes[@]} == 0 )); then …`
#   (inside if — safe); a BARE `(( ${#lanes[@]} == 0 ))` when empty would ABORT.

# GOTCHA (release is EXPLICIT, NOT reap — design-decisions D10): release calls
#   pool_release_lane DIRECTLY (admin-named lane — live OR stale, torn down). Do NOT route
#   through pool_reap_stale (that is STALE-ONLY — it SKIPS live-owner lanes). `release 5`
#   must tear down lane 5 even if its owner is alive. In the `all` branch, iterate
#   pool_lanes_list (EVERY lane with a lease) and pool_release_lane each — do NOT filter
#   to stale lanes.

# GOTCHA (return codes DIFFER from the reap sibling — design-decisions D6): release returns
#   rc 1 for usage-error (c) and targeted-not-found (d). This is CORRECT (Unix convention) and
#   diverges from reap's rc-0-always ONLY because release takes an argument + can hit "not found".
#   Do NOT force rc-0-always here. Successful releases (all cases + numeric-found) → rc 0.

# GOTCHA (stdout = result, stderr = usage — design-decisions D7): the result messages
#   ("Released lane N." / "Released N lane(s)." / "No active lanes to release." /
#   "Lane N has no active lease.") go to STDOUT (capturable). The usage block (the misuse
#   path) goes to STDERR (stdout stays empty on usage). `_pool_log`/`pool_die` never touch stdout.

# GOTCHA (precondition can pool_die): pool_config_init / pool_state_init are rc-0-or-pool_die.
#   This is CORRECT — a misconfigured pool fails loudly, not silently. No guard (matches the
#   siblings).

# GOTCHA (literal `lane(s)` — design-decisions D4): the `all` summary string is literally
#   "Released N lane(s)." — the `(s)` convention handles both N=1 and N>0 (same as reap). Do
#   NOT special-case the singular. printf 'Released %d lane(s).\n' "$count".

# GOTCHA (the delegate logs internally): pool_release_lane calls `_pool_log` for its per-lane
#   teardown (file+stderr). So pool_admin_release does NOT need its own `_pool_log` — the
#   stdout summary is the user-facing output (matches status/reap, which do NOT call _pool_log).
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk change, NO new env-vars/globals.
It classifies one argument, probes one predicate, delegates one teardown, and prints a
formatted message. The locals are the scalar `target`, the array `lanes` (for `all`),
and the loop var `lane`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the compose targets exist
  - RUN: test -f lib/pool.sh && echo "OK lib present"
  - EXPECT: present.
  - RUN (check whether pool_admin_release already exists — parallel landing possible;
        see the PARALLEL-EXECUTION STATUS NOTE at the top of this PRP):
        grep -n '^pool_admin_release()' lib/pool.sh && echo "EXISTS — verify against spec (do NOT duplicate)" || echo "ABSENT — append after the last admin fn"
  - EXPECT: one of the two. If ABSENT → proceed to Task 1 (append). If EXISTS →
        read its body; confirm it matches this PRP's spec (classify spine, the
        pool_lease_exists probe, pinned messages, rc 0/1, usage→stderr). If it matches,
        the implementation IS this task's deliverable — proceed to Task 2 (scope check)
        + the validation tests (Level 2) to confirm. If it DIVERGES materially, reconcile
        to this spec (this PRP is the contract).
  - RUN (confirm the compose targets are defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_release_lane pool_lease_exists pool_lanes_list pool_config_init pool_state_init; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; \
          done; echo "OK all compose targets defined"'
  - EXPECT: OK all compose targets defined.
  - RUN (confirm pool_release_lane's idempotency contract — rc 0 on a missing lease):
        grep -n 'then return 0' lib/pool.sh | grep -i release | head -3
        sed -n '2485,2495p' lib/pool.sh
  - EXPECT: pool_release_lane's `if ! json="$(pool_lease_read …)"; then return 0; fi` (the
        idempotent no-op on a missing lease — WHY the pool_lease_exists probe is required).
  - RUN (confirm pool_lease_exists's rc-0/1 contract):
        sed -n '928,945p' lib/pool.sh
  - EXPECT: `[[ "$lane" =~ ^[0-9]+$ ]] || return 1` … `[[ -f "$file" ]] || return 1` …
        `_pool_json_valid "$file" || return 1` … `return 0` (rc 1 on missing/corrupt/non-numeric).
  - RUN (confirm the LANDED sibling pool_admin_reap + its append site):
        grep -n '^pool_admin_reap()' lib/pool.sh; wc -l lib/pool.sh; tail -3 lib/pool.sh
  - EXPECT: pool_admin_reap defined @3730; EOF @3762 = its closing `}`. APPEND after it.
  - RUN (host tooling):
        bash --version | head -1
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not break existing syntax).

Task 1: APPEND pool_admin_release() to lib/pool.sh (the verbatim contract)
  - PLACEMENT: APPEND at end of lib/pool.sh (after the closing `}` of pool_admin_reap),
        preceded by the new banner. NO edits to any existing line.
  - IMPLEMENT (verbatim — paste exactly; the header doc-comment satisfies the item's
        DOCS step by documenting the release command's behavior + output messages):

# ============================================================================
# Admin CLI — release (P1.M7.T3.S1)
# ============================================================================
# pool_admin_release [TARGET]
#
# PRD §2.12 `release [<N>|all]` / §2.5 "Explicit release" — the USER-FACING
# release command. Takes ONE optional argument TARGET (the string "all", a lane
# number N, or empty/invalid), CLASSIFIES it, and explicitly tears down the named
# lane(s) by delegating to the LANDED pool_release_lane (M5.T2.S1 — kill pgroup +
# disconnect daemon + rm dir + delete lease; rc 0 ALWAYS; idempotent). Prints a
# one-line confirmation. Distinct from `reap` (M7.T2.S1): reap is STALE-ONLY
# (pool_reap_stale skips live-owner lanes); release is EXPLICIT (admin-named lane
# is torn down live OR stale).
#
# LOGIC (CONTRACT 3a→3d):
#   a. TARGET == "all"  → snapshot pool_lanes_list; if empty → "No active lanes to
#      release."; else pool_release_lane EACH, then "Released N lane(s)." (N = count).
#      rc 0.
#   b. TARGET is a number AND pool_lease_exists → pool_release_lane TARGET;
#      "Released lane N.". rc 0.
#   c. TARGET is empty OR invalid (not "all", not ^[0-9]+$) → print USAGE to STDERR.
#      rc 1.
#   d. TARGET is a number AND NOT pool_lease_exists → "Lane N has no active lease."
#      rc 1. (Nothing torn down.)
#
# OUTPUT (stdout = the result line; stderr = usage only):
#   release all (N>0)  → stdout: "Released N lane(s)."
#   release all (N==0) → stdout: "No active lanes to release."
#   release N (exists) → stdout: "Released lane N."
#   release N (absent) → stdout: "Lane N has no active lease."
#   release / release foo → stderr: usage block; stdout EMPTY.
#
# The literal "lane(s)" handles both singular and plural (do not special-case N=1).
#
# CONTRACT:
#   - DELEGATE: ALL teardown logic lives in pool_release_lane. This function does NOT
#     re-implement any of it. It classifies + probes existence + delegates + reports.
#   - PROBE BEFORE DELEGATING (the key decision): pool_release_lane is idempotent +
#     rc-0-always + SILENTLY no-ops on a missing lease (lib/pool.sh:2448-2449). So it
#     CANNOT distinguish "I just released lane N" from "lane N had no lease" (BOTH rc 0).
#     The numeric branch MUST probe pool_lease_exists FIRST to pick the right message
#     ("Released lane N." vs "Lane N has no active lease."). In the `all` branch no
#     per-lane probe is needed: pool_lanes_list yields ONLY lanes with a lease.
#   - EXPLICIT, NOT reap: release calls pool_release_lane DIRECTLY (admin-named lane —
#     live OR stale). Do NOT route through pool_reap_stale (stale-only; skips live lanes).
#   - RETURN CODES: rc 0 for successful releases (all cases + numeric-found); rc 1 for
#     usage-error (c) + targeted-not-found (d). This DELIBERATELY diverges from the reap
#     sibling's rc-0-always: release takes an ARGUMENT and can hit "not found", which is a
#     genuine error (Unix convention). NEVER pool_die in the body.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_lease_exists returns rc 1 on missing/corrupt/non-numeric → a BARE call
#     ABORTS under set -e. ALWAYS `if pool_lease_exists "$lane"; then …; else …; fi`
#     (rc 1 falls into else, errexit-exempt). This is the SAME hazard as pool_lane_is_stale.
#   - pool_release_lane returns rc 0 ALWAYS → a BARE call (after the probe passes) is
#     set -e-safe. NO `if !` guard.
#   - pool_lanes_list returns rc 0 ALWAYS → the `mapfile -t lanes < <(pool_lanes_list)`
#     snapshot + any iteration is safe.
#   - never `local x="$(…)"` (SC2155); declare then assign. (`local target="${1:-}"` is a
#     parameter expansion, NOT a `$(…)` capture → SC2155-safe inline.)
#   - `(( ${#lanes[@]} == 0 ))` MUST be inside `if` (a bare `(( ))` statement returns 1
#     when the value is 0 → FATAL under set -e).
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case release) pool_admin_release "$@" ;;`.
pool_admin_release() {
    # Declare ALL locals up front (SC2155). `target` is a parameter expansion (NOT a
    # `$(…)` capture), so inline `local target="${1:-}"` is SC2155-safe. `lanes` is the
    # snapshot array for the `all` branch; `lane` is the loop var.
    local target="${1:-}"
    local -a lanes
    local lane

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3604-3606) + pool_admin_reap
    # (lib/pool.sh:3738-3742) + pool_wrapper_main step "a". pool_state_init's
    # idempotent mkdir -p guarantees POOL_LANES_DIR exists (so a fresh pool's first
    # release — `release all` on an empty pool — works cleanly).
    pool_config_init
    pool_state_init

    # --- classify TARGET: "all" → numeric → else(usage) -------------------------
    if [[ "$target" == "all" ]]; then
        # --- (a) release ALL lanes: snapshot first for an accurate count + clean ---
        # --- empty-pool check (mirrors pool_admin_status @lib/pool.sh:3624/3629). -
        # Process-substitution exit status is NOT propagated → set -e safe. mapfile of
        # empty output → empty array. pool_lanes_list yields ONLY lanes with a lease
        # (numeric *.json stems), so every iterated lane is real.
        mapfile -t lanes < <(pool_lanes_list)
        # `(( ))` inside `if` is errexit-exempt (bare `(( ))` @0 is FATAL under set -e).
        if (( ${#lanes[@]} == 0 )); then
            printf 'No active lanes to release.\n'
            return 0
        fi
        # Release each lane. pool_release_lane is rc 0 ALWAYS (idempotent; non-fatal) →
        # the bare call is set -e-safe. NO per-lane pool_lease_exists probe: pool_lanes_list
        # already guaranteed each lane has a lease. (Contrast the numeric branch, which
        # MUST probe.) A concurrent reap may race a lane away between snapshot + release —
        # pool_release_lane no-ops cleanly on the now-absent lease (rc 0); the summary count
        # reflects the snapshot (acceptable; contract says only "Print summary".)
        for lane in "${lanes[@]}"; do
            pool_release_lane "$lane"
        done
        # Literal "lane(s)" handles N=1 and N>0 (no singular special-case — same as reap).
        printf 'Released %d lane(s).\n' "${#lanes[@]}"
        return 0

    elif [[ "$target" =~ ^[0-9]+$ ]]; then
        # --- (b)/(d) numeric: PROBE existence BEFORE delegating (the key guard) ---
        # pool_lease_exists is rc 0 (valid lease) / rc 1 (missing/corrupt/non-numeric).
        # A BARE call with rc 1 ABORTS under set -e → the `if` is MANDATORY (rc 1 falls
        # into else, errexit-exempt). This probe is REQUIRED because pool_release_lane is
        # rc-0-always + silently no-ops on a missing lease — it CANNOT tell us the lane
        # was absent. The probe picks the right message.
        if pool_lease_exists "$target"; then
            # (b) lease EXISTS → delegate the real teardown. pool_release_lane is rc 0
            # ALWAYS → bare call, NO `if !` guard. It reads the lease, disconnects the
            # daemon, kills the Chrome pgroup, rm -rf the dir, deletes the lease.
            pool_release_lane "$target"
            # %s echoes the target token verbatim ("Released lane 7.").
            printf 'Released lane %s.\n' "$target"
            return 0
        else
            # (d) lease ABSENT → nothing to release. NOT an idempotent success (the admin
            # named a SPECIFIC lane that isn't there) → rc 1 (Unix convention). Nothing is
            # torn down (pool_release_lane was NOT called).
            printf 'Lane %s has no active lease.\n' "$target"
            return 1
        fi

    else
        # --- (c) empty OR invalid (not "all", not ^[0-9]+$) → usage to STDERR ------
        # Usage goes to stderr (the misuse path; conventional). stdout stays EMPTY so a
        # `out="$(pool_admin_release foo)"` captures nothing. rc 1 (usage error). The
        # full --help is the dispatcher's job (M7.T5.S1); this is the function-level
        # fallback the item contract requires ("print usage").
        printf 'Usage: agent-browser-pool release [<N>|all]\n' >&2
        printf '\n' >&2
        printf 'Release (tear down) one lane or all lanes.\n' >&2
        printf '  release N    Release lane N (explicit teardown).\n' >&2
        printf '  release all  Release all active lanes.\n' >&2
        return 1
    fi
}

  - VERIFY (immediately after):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (whole file)
        grep -n 'pool_admin_release' lib/pool.sh | head -1       # the definition line
        git diff --stat lib/pool.sh                              # append-only diff
  - EXPECT: all OK; the only change to lib/pool.sh is the appended banner + function.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY lib/pool.sh modified (append-only). bin/, .gitignore, PRD.md,
        tasks.json, prd_snapshot.md UNCHANGED. NO new files outside plan/.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the classify spine (the whole function is a 3-way if/elif/else):
pool_admin_release() {
    local target="${1:-}"
    local -a lanes
    local lane
    pool_config_init
    pool_state_init
    if [[ "$target" == "all" ]]; then
        mapfile -t lanes < <(pool_lanes_list)             # snapshot (rc 0 always)
        if (( ${#lanes[@]} == 0 )); then                   # inside if → errexit-exempt
            printf 'No active lanes to release.\n'; return 0
        fi
        for lane in "${lanes[@]}"; do pool_release_lane "$lane"; done   # rc 0 always → bare
        printf 'Released %d lane(s).\n' "${#lanes[@]}"; return 0
    elif [[ "$target" =~ ^[0-9]+$ ]]; then
        if pool_lease_exists "$target"; then              # rc 1 MUST be guarded → inside if
            pool_release_lane "$target"                    # rc 0 always → bare (NO guard)
            printf 'Released lane %s.\n' "$target"; return 0
        else
            printf 'Lane %s has no active lease.\n' "$target"; return 1
        fi
    else
        printf 'Usage: agent-browser-pool release [<N>|all]\n' >&2   # usage → stderr
        printf '\n' >&2
        printf 'Release (tear down) one lane or all lanes.\n' >&2
        printf '  release N    Release lane N (explicit teardown).\n' >&2
        printf '  release all  Release all active lanes.\n' >&2
        return 1
    fi
}

# PATTERN — probe BEFORE delegate (the numeric branch's core):
if pool_lease_exists "$target"; then
    pool_release_lane "$target"        # rc 0 always → bare call, NO guard
    printf 'Released lane %s.\n' "$target"
else
    printf 'Lane %s has no active lease.\n' "$target"
fi
#   pool_lease_exists is a BOOLEAN predicate (rc 0/1). rc 1 MUST be inside `if` (a bare
#   call ABORTS under set -e). pool_release_lane is rc 0 always → the bare post-probe call
#   is safe. The probe is REQUIRED: pool_release_lane swallows "no lease" as rc 0.

# GOTCHA — WHY probe existence and not just call pool_release_lane + read its rc:
#   pool_release_lane returns 0 on a missing lease with NO signal (lib/pool.sh:2448-2449).
#   So `pool_release_lane 99 && echo released` would print "released" for an absent lane —
#   WRONG. The contract demands "Lane N has no active lease." for the absent case. The
#   pool_lease_exists probe is the ONLY way to distinguish the two numeric outcomes.

# GOTCHA — WHY the `all` branch does NOT probe per lane:
#   pool_lanes_list yields ONLY lanes with a lease (numeric *.json stems). Every iterated
#   lane is real. pool_release_lane is rc-0-always + idempotent, so the loop cannot abort
#   and re-releasing a raced-away lane is a clean no-op. The summary count is the snapshot
#   size (accurate at snapshot time).

# GOTCHA — WHY return rc 1 for usage/not-found (diverging from reap's rc-0-always):
#   release takes an ARGUMENT and can hit "not found" — a structural capability the no-arg
#   reap/status siblings lack. A usage error (`release` / `release foo`) and a targeted
#   miss (`release 99` absent) are genuine errors (Unix convention → non-zero). Successful
#   releases (all cases + numeric-found) → rc 0. This is the deliberate, documented divergence.

# GOTCHA — WHY no confirmation prompt before the destructive release:
#   pool_release_lane is DESTRUCTIVE (kills Chromes, rm dirs). But pool_admin_release is a
#   LIBRARY function (no stdin interaction). Any confirmation prompt is the DISPATCHER's
#   job (M7.T5.S1, which may add `read -p` before calling pool_admin_release). (PRD §2.12
#   lists `release` with no `[--yes]` flag → no confirmation is the current spec.)
```

### Integration Points

```yaml
FILESYSTEM:
  - modify: "lib/pool.sh (APPEND-ONLY: banner + pool_admin_release() after line 3762)"

LIBRARY (lib/pool.sh):
  - composes: "pool_config_init + pool_state_init (precondition); pool_lanes_list (all
              snapshot); pool_lease_exists (numeric existence probe); pool_release_lane
              (the teardown). All LANDED + contract-documented."

GITIGNORE:
  - no change: ".gitignore is orchestrator-owned (M10.T1.S2); no rule matches the diff."

CONSUMERS (the dispatcher, FUTURE — NOT this task):
  - M7.T5.S1 bin/agent-browser-pool: "case \"\$cmd\" in release) pool_admin_release \"\$@\" ;;".
            This task does NOT create the binary. It only provides the function the binary
            will call by name."

SUGGESTED --help TEXT (for M7.T5.S1 to reference — NOT wired by this task):
  - "  release [<N>|all]      explicitly tear down one lane or all lanes"
  - The dispatcher (M7.T5.S1) will echo this under the global `agent-browser-pool --help`
            usage block. This task documents the release command's behavior in the function's
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
grep -n 'pool_admin_release' lib/pool.sh | head -1       # the definition exists
git diff --stat lib/pool.sh                              # append-only (no -/= churn in middle)
# Expected: all OK. The diff should be purely additive (~115 + lines, 0 deletions).
#   shellcheck zero warnings: watch SC2155 (declare-then-assign; `local target="${1:-}"`
#   is fine — parameter expansion, NOT $(…)), SC2086 (quote "$target" / "$lane" in printf),
#   SC2190 (mapfile lanes OK). The `if pool_lease_exists …; then` guard + `(( ${#lanes[@]} == 0 ))`
#   inside if + `>&2` on usage printf are all clean.
```

### Level 2: Unit Tests (Component Validation — NO Chrome needed)

`pool_admin_release` is a classify+probe+delegate wrapper. Its message + return-code
logic is fully verifiable WITHOUT Chrome / a master profile / a real teardown by
**overriding `pool_release_lane`** (and `pool_lanes_list` / `pool_lease_exists` where
needed) to isolate the classify/report logic. PLUS integration cases with synthetic
leases (no real Chrome — pool_release_lane's close is fast + rc 0 on a missing daemon).

```bash
# Save as /tmp/test_release.sh and run: bash /tmp/test_release.sh
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
# PART A — UNIT TESTS: override pool_release_lane to a stub, isolating pool_admin_release's
# CLASSIFY + REPORT logic from the teardown entirely. Fully deterministic, no Chrome.
# ============================================================================

# ---- Case A1: empty arg → usage to stderr, stdout EMPTY, rc 1 ----------------
pool_release_lane() { echo "STUB-RELEASE-SHOULD-NOT-RUN"; }   # must NOT run
out="$(pool_admin_release "" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 1 ]] && ok "A1-empty: rc 1" || bad "A1-empty: rc=$rc"
[[ -z "$out" ]] && ok "A1-empty: stdout empty (usage → stderr)" || bad "A1-empty: stdout=[$out]"
# verify usage went to stderr:
err="$(pool_admin_release "" 2>&1 >/dev/null)"
grep -q 'Usage: agent-browser-pool release' <<<"$err" && ok "A1-empty: usage on stderr" \
    || bad "A1-empty: no usage on stderr [$err]"

# ---- Case A2: invalid arg ("foo") → usage to stderr, rc 1 --------------------
out="$(pool_admin_release "foo" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 1 ]] && ok "A2-foo: rc 1" || bad "A2-foo: rc=$rc"
[[ -z "$out" ]] && ok "A2-foo: stdout empty" || bad "A2-foo: stdout=[$out]"

# ---- Case A3: missing arg (no arg at all) → usage, rc 1 ----------------------
out="$(pool_admin_release 2>/dev/null)"; rc=$?
[[ "$rc" -eq 1 ]] && ok "A3-missing: rc 1" || bad "A3-missing: rc=$rc"
[[ -z "$out" ]] && ok "A3-missing: stdout empty" || bad "A3-missing: stdout=[$out]"

# ---- Case A4: numeric + lease EXISTS → "Released lane N." + rc 0 -------------
# Override pool_lease_exists to say "yes", and pool_release_lane to a stub.
pool_lease_exists() { return 0; }
released=""; pool_release_lane() { released="$1"; }   # record what was delegated
out="$(pool_admin_release "7")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "A4-num-exists: rc 0" || bad "A4-num-exists: rc=$rc"
[[ "$out" == "Released lane 7." ]] && ok "A4-num-exists: exact message" \
    || bad "A4-num-exists: got [$out]"
[[ "$released" == "7" ]] && ok "A4-num-exists: delegated pool_release_lane 7" \
    || bad "A4-num-exists: delegated [$released]"

# ---- Case A5: numeric + lease ABSENT → "Lane N has no active lease." + rc 1 --
pool_lease_exists() { return 1; }   # no lease
called=0; pool_release_lane() { called=1; }   # must NOT run
out="$(pool_admin_release "99")"; rc=$?
[[ "$rc" -eq 1 ]] && ok "A5-num-absent: rc 1" || bad "A5-num-absent: rc=$rc"
[[ "$out" == "Lane 99 has no active lease." ]] && ok "A5-num-absent: exact message" \
    || bad "A5-num-absent: got [$out]"
[[ "$called" -eq 0 ]] && ok "A5-num-absent: pool_release_lane NOT called (nothing torn down)" \
    || bad "A5-num-absent: pool_release_lane was called!"

# ---- Case A6: numeric edge — "05" passes regex; existence decides ------------
pool_lease_exists() { return 1; }   # no lease for "05"
out="$(pool_admin_release "05")"; rc=$?
[[ "$out" == "Lane 05 has no active lease." ]] && ok "A6-leadingzero: echoes target verbatim" \
    || bad "A6-leadingzero: got [$out]"

# ---- Case A7: negative / float / hex → invalid → usage ----------------------
for badarg in "-5" "1.5" "0x10"; do
    out="$(pool_admin_release "$badarg" 2>/dev/null)"; rc=$?
    [[ "$rc" -eq 1 ]] && ok "A7-$badarg: rc 1 (invalid)" || bad "A7-$badarg: rc=$rc"
    [[ -z "$out" ]] && ok "A7-$badarg: stdout empty" || bad "A7-$badarg: stdout=[$out]"
done

# ============================================================================
# PART B — `all` BRANCH UNIT TESTS: override pool_lanes_list + pool_release_lane.
# ============================================================================

# ---- Case B1: `all` empty pool → "No active lanes to release." + rc 0 --------
pool_lanes_list() { :; }   # echo nothing (empty pool)
ran=0; pool_release_lane() { ran=1; }
out="$(pool_admin_release "all")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "B1-all-empty: rc 0" || bad "B1-all-empty: rc=$rc"
[[ "$out" == "No active lanes to release." ]] && ok "B1-all-empty: exact message" \
    || bad "B1-all-empty: got [$out]"
[[ "$ran" -eq 0 ]] && ok "B1-all-empty: pool_release_lane NOT called" \
    || bad "B1-all-empty: pool_release_lane called on empty pool"

# ---- Case B2: `all` N>0 → "Released N lane(s)." + rc 0; each lane delegated --
pool_lanes_list() { printf '%s\n' 1 2 5; }   # 3 lanes
delegated=""
pool_release_lane() { delegated="$delegated $1"; }
out="$(pool_admin_release "all")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "B2-all-three: rc 0" || bad "B2-all-three: rc=$rc"
[[ "$out" == "Released 3 lane(s)." ]] && ok "B2-all-three: count message (literal lane(s))" \
    || bad "B2-all-three: got [$out]"
[[ "$delegated" == " 1 2 5" ]] && ok "B2-all-three: delegated lanes 1,2,5" \
    || bad "B2-all-three: delegated [$delegated]"

# ---- Case B3: `all` single lane (N=1) → "Released 1 lane(s)." (literal lane(s)) --
pool_lanes_list() { printf '%s\n' 3; }
pool_release_lane() { :; }
out="$(pool_admin_release "all")"; rc=$?
[[ "$out" == "Released 1 lane(s)." ]] && ok "B3-all-one: singular still says lane(s)" \
    || bad "B3-all-one: got [$out]"

# ---- Case B4: stdout is PURELY the one result line (capturable) --------------
pool_lanes_list() { printf '%s\n' 1 2; }
pool_release_lane() { :; }
out="$(pool_admin_release "all")"
[[ "$(grep -c . <<<"$out")" -eq 1 ]] && ok "B4-discipline: one line (no leak)" \
    || bad "B4-discipline: multiline [$out]"

# ============================================================================
# PART C — INTEGRATION: the REAL pool_lease_exists / pool_lanes_list / pool_release_lane
# against synthetic leases. NO real Chrome needed (pool_release_lane's close is fast +
# rc 0 on a missing daemon; kill/rm of nonexistent pid/dir are || true).
# ============================================================================
unset -f pool_release_lane pool_lease_exists pool_lanes_list   # restore REAL functions

# C-pre: empty pool → release all → "No active lanes to release."
out="$(pool_admin_release "all")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "C-all-empty: rc 0" || bad "C-all-empty: rc=$rc"
[[ "$out" == "No active lanes to release." ]] && ok "C-all-empty: message" \
    || bad "C-all-empty: got [$out]"

# C-num-absent: release 4 (no lease) → "Lane 4 has no active lease." rc 1; nothing created.
out="$(pool_admin_release "4")"; rc=$?
[[ "$rc" -eq 1 ]] && ok "C-num-absent: rc 1" || bad "C-num-absent: rc=$rc"
[[ "$out" == "Lane 4 has no active lease." ]] && ok "C-num-absent: message" \
    || bad "C-num-absent: got [$out]"

# C-num-exists: write a synthetic lease for lane 2 → release 2 → "Released lane 2." rc 0; lease gone.
NOW="$(date +%s)"
jq -n --argjson lane 2 --argjson port 53422 --arg session "abpool-2" \
      --argjson owner_pid 99998 --arg owner_cwd "$STATE" --argjson chrome_pid 9999999 \
      --argjson acquired_at "$NOW" --argjson connected true \
      '{version:1, lane:$lane, ephemeral_dir:"", port:$port, session:$session,
        owner:{pid:$owner_pid, comm:"pi", starttime:1111, cwd:$owner_cwd},
        chrome_pid:$chrome_pid, chrome_pgid:$chrome_pid,
        acquired_at:$acquired_at, last_seen_at:$acquired_at, connected:$connected}' \
      > "$STATE/lanes/2.json"
out="$(pool_admin_release "2")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "C-num-exists: rc 0" || bad "C-num-exists: rc=$rc"
[[ "$out" == "Released lane 2." ]] && ok "C-num-exists: message" \
    || bad "C-num-exists: got [$out]"
[[ ! -f "$STATE/lanes/2.json" ]] && ok "C-num-exists: lease deleted" \
    || bad "C-num-exists: lease still present"

# C-all-exists: write two synthetic leases → release all → "Released 2 lane(s." rc 0; both gone.
NOW="$(date +%s)"
for ln in 1 3; do
  jq -n --argjson lane "$ln" --argjson port "5342$ln" --arg session "abpool-$ln" \
        --argjson owner_pid 99997 --arg owner_cwd "$STATE" --argjson chrome_pid 9999998 \
        --argjson acquired_at "$NOW" --argjson connected true \
        '{version:1, lane:$lane, ephemeral_dir:"", port:$port, session:$session,
          owner:{pid:$owner_pid, comm:"pi", starttime:1111, cwd:$owner_cwd},
          chrome_pid:$chrome_pid, chrome_pgid:$chrome_pid,
          acquired_at:$acquired_at, last_seen_at:$acquired_at, connected:$connected}' \
        > "$STATE/lanes/$ln.json"
done
out="$(pool_admin_release "all")"; rc=$?
[[ "$rc" -eq 0 ]] && ok "C-all-exists: rc 0" || bad "C-all-exists: rc=$rc"
[[ "$out" == "Released 2 lane(s)." ]] && ok "C-all-exists: count message" \
    || bad "C-all-exists: got [$out]"
[[ ! -f "$STATE/lanes/1.json" && ! -f "$STATE/lanes/3.json" ]] && ok "C-all-exists: both leases gone" \
    || bad "C-all-exists: a lease survives"

# C-idempotent: re-release all on now-empty pool → "No active lanes to release."
out="$(pool_admin_release "all")"
[[ "$out" == "No active lanes to release." ]] && ok "C-idempotent: re-release all → empty" \
    || bad "C-idempotent: got [$out]"

rm -rf "$STATE"
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≥30, fail=0. (Part A isolates the classify/report logic via stubs — fully
#   deterministic. Part B isolates the `all` branch via pool_lanes_list/pool_release_lane
#   stubs. Part C exercises the REAL functions against synthetic leases — no real Chrome:
#   the dead-owner-pid trick + pool_release_lane's close=rc0-fast on a missing daemon.)
```

### Level 3: Integration Testing (System Validation)

The full end-to-end (a real pooled Chrome lane exists and `release N` tears it down) needs
a real Chrome + master profile + a `pi` ancestor — the domain of the M9 harness. **For this
task, Level 2's Part C tests ARE the integration proof** (they exercise the real
`pool_lease_exists` / `pool_lanes_list` / `pool_release_lane` against synthetic leases). A
smoke once the dispatcher (M7.T5.S1) lands + a real lane is acquired:

```bash
# PREREQ: a lane acquired via the wrapper (run inside pi). Then, from a human terminal:
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool}" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_release "1"'
# Expected: "Released lane 1." (the lane torn down: Chrome killed, dir+lease gone). Verify
# with `pool_admin_status` → lane 1 absent. Re-run release 1 → "Lane 1 has no active lease." (rc 1).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Capturability (PRD §2.12 admin ergonomics): the result is exactly one capturable line.
out="$(bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_release all')"
echo "captured: [$out]"   # exactly "No active lanes to release." or "Released N lane(s)."

# Usage isolation: usage goes to stderr (stdout empty) — scripts capturing stdout get nothing.
out="$(bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_release foo' 2>/dev/null)"
[[ -z "$out" ]] && echo "OK usage stdout empty" || echo "FAIL stdout=[$out]"

# Exit-code ergonomics: a script can branch on the result.
bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_release 99' \
    && echo "OK released" || echo "OK rc-nonzero (nothing to release / bad arg)"   # the latter for lane 99

# Pipeability: release all | grep Released works (stdout is one clean line).
bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_release all' \
    | grep -E '^(Released|No active)' || true
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` zero
      warnings (whole file) + `git diff --stat lib/pool.sh` is append-only (0 deletions).
- [ ] Level 2 passes (pass≥30, fail=0): Part A (override pool_release_lane/pool_lease_exists →
      exact messages + rcs for empty/foo/missing/num-exists/num-absent/leading-zero/invalid),
      Part B (override pool_lanes_list → all-empty/all-three/all-one/discipline),
      Part C (real functions vs synthetic leases: all-empty, num-absent, num-exists+lease-gone,
      all-exists+both-gone, idempotent re-release).

### Feature Validation

- [ ] `pool_admin_release()` appended under banner `# Admin CLI — release (P1.M7.T3.S1)`.
- [ ] `release all` (N>0) → exactly `Released N lane(s).\n` (rc 0; lanes torn down).
- [ ] `release all` (empty) → exactly `No active lanes to release.\n` (rc 0).
- [ ] `release N` (exists) → exactly `Released lane N.\n` (rc 0; lane N torn down).
- [ ] `release` / `release foo` → usage to stderr, stdout EMPTY, rc 1.
- [ ] `release N` (absent) → exactly `Lane N has no active lease.\n` (rc 1; nothing torn down).
- [ ] stdout is purely the one result line (capturable); usage goes to stderr.
- [ ] Returns 0 on success, 1 on usage/not-found; never calls `pool_die` in its own body.

### Code Quality Validation

- [ ] Follows house style: `set -euo pipefail`-safe (pool_lease_exists rc 1 guarded inside
      `if`; pool_release_lane rc 0 always → bare call; pool_lanes_list rc 0 always → safe
      snapshot/iteration), SC2155 (locals up front; `local target="${1:-}"` is a parameter
      expansion → safe inline), `(( ))` only inside `if`, banner convention, doc-comment header.
- [ ] Composes ONLY landed helpers (no new system interaction, no flock, no Chrome, no
      re-implementation of teardown).
- [ ] Anti-patterns avoided: no bare `pool_lease_exists` call (fatal rc 1); no blind
      `pool_release_lane` without the existence probe (would print "Released lane N." for an
      absent lane); no bare `(( ))` statement (fatal @0); no routing through pool_reap_stale
      (stale-only); no `pool_die` in the body; no edits to existing functions; no confirmation
      prompt (that is the dispatcher's job).
- [ ] The header doc-comment documents the output messages + return-code contract + the
      pool_lease_exists-probe rationale (item DOCS).

### Documentation & Deployment

- [ ] The function is self-documenting via its header doc-comment (messages + contract + gotchas).
- [ ] No new env-vars; no `.gitignore` change; no new files; the dispatcher + `--help` wiring
      is M7.T5.S1.
- [ ] The suggested `--help` text ("release [<N>|all]  explicitly tear down one lane or all
      lanes") is provided in Integration Points for M7.T5.S1 to reference.

---

## Anti-Patterns to Avoid

- ❌ Don't build `bin/agent-browser-pool` or wire `--help` — that is M7.T5.S1. This task is
      **lib-only**: append `pool_admin_release()` to `lib/pool.sh`. Nothing else.
- ❌ Don't edit any existing function in `lib/pool.sh` — append-only. `git diff` must be purely
      additive (0 deletions in the existing body).
- ❌ Don't call `pool_release_lane` WITHOUT the `pool_lease_exists` probe in the numeric branch.
      pool_release_lane is idempotent + rc-0-always + **silently no-ops on a missing lease** —
      without the probe, `release 99` (absent) would print "Released lane 99." (WRONG; must be
      "Lane 99 has no active lease."). ALWAYS probe first: `if pool_lease_exists "$target";
      then pool_release_lane …; else …; fi`.
- ❌ Don't call `pool_lease_exists` as a BARE statement — it returns rc 1 on no-lease, which
      ABORTS under `set -e`. ALWAYS guard it inside `if pool_lease_exists …; then …; else …; fi`.
- ❌ Don't wrap the post-probe `pool_release_lane` in `if !` — it returns rc 0 ALWAYS, so a bare
      call is set -e-safe. The guard is only needed for `pool_lease_exists`.
- ❌ Don't route `release` through `pool_reap_stale` — that is STALE-ONLY (it SKIPS live-owner
      lanes). `release` is EXPLICIT: the admin named the lane(s), torn down live OR stale.
      Call `pool_release_lane` directly.
- ❌ Don't force rc-0-always (the reap sibling's pattern) — release returns rc 1 for usage-error
      and targeted-not-found. That is the deliberate, documented divergence (release takes an
      argument and can hit "not found"). Successful releases → rc 0.
- ❌ Don't write a bare `(( ${#lanes[@]} == 0 ))` statement — it returns rc 1 when empty → FATAL
      under `set -e`. Keep it inside `if (( … )); then …` (errexit-exempt).
- ❌ Don't special-case the singular "lane" — the contract is literally "lane(s)"; the `(s)`
      convention handles N=1 and N>0 (same as reap). No `if (( count == 1 ))` branch.
- ❌ Don't add a `local x="$(…)"` (SC2155) — declare locals first, then assign. (`local
      target="${1:-}"` is a parameter expansion, NOT a `$(…)` capture → SC2155-safe inline.)
- ❌ Don't add a confirmation prompt (`read -p`) — `pool_admin_release` is a library function
      (no stdin interaction). Any prompt is the DISPATCHER's job (M7.T5.S1). PRD §2.12 lists
      `release` with no `[--yes]` flag → no confirmation is the current spec.
- ❌ Don't call `pool_die` in the body — usage/not-found are reported + return-coded, not fatal.
      (The precondition helpers may `pool_die` on genuine misconfiguration — that is correct.)
- ❌ Don't print anything but the one result line to stdout — usage goes to stderr; `_pool_log`
      (file+stderr) must not leak; stdout stays one clean capturable line (or empty on usage).
- ❌ Don't modify `.gitignore`, `PRD.md`, `tasks.json`, `prd_snapshot.md`, `bin/`, or `test/` —
      those are owned by other tasks / the orchestrator / humans.

---

## Confidence Score: 9/10

**Why high**: This is a thin CLASSIFY + PROBE + DELEGATE wrapper over LANDED, validated,
contract-documented functions. The entire implementation is ~35 lines (init → 3-way classify
→ `all` mapfile-loop / numeric probe-or-delegate / usage-to-stderr → return). The ONE
non-trivial decision (probe `pool_lease_exists` before `pool_release_lane` in the numeric
branch, because pool_release_lane swallows "no lease" as rc 0) is explicitly pinned
(design-decisions D5) with a copy-pasteable code block + the anti-pattern call-out. The
message strings are verbatim from the item contract. The return-code rationale (rc 1 for
usage/not-found, diverging from reap's rc-0-always) is justified structurally (release takes
an argument + can hit "not found") and documented (D6). The append site is confirmed (after
the LANDED `pool_admin_reap`, EOF @3762). The bash gotchas (`(( ))` inside `if`, the rc-1
guard on `pool_lease_exists`, SC2155, the bare-call safety of rc-0-always helpers) are all
documented with the exact safe form. Validation is no-Chrome (Part A/B override stubs are
fully deterministic; Part C uses synthetic leases + pool_release_lane's fast/rc-0 close on a
missing daemon).

**Why not 10**: The residual 1/10 is for (a) the parallel-execution context: `pool_admin_reap`
is LANDED at EOF @3762 now, but the orchestrator's sequencing could shift the exact EOF line
— mitigated by Task 0 verifying the live EOF before appending; (b) the integration test's
reliance on `pool_release_lane`'s close being fast + rc 0 on a missing daemon
(research-asserted, host-verified in M5.T2.S1, but environment-dependent) — mitigated by
Part A/B's override-based unit tests which are fully deterministic and need no close
subprocess at all; and (c) the return-code decision (rc 1 for usage/not-found) is a judgment
call that diverges from the reap sibling — but it is the Unix-conventional + structurally-
justified choice, documented thoroughly so the implementing agent follows it rather than
copying reap's rc-0-always.
