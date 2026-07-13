# Research: Codebase facts for `pool_admin_release()` (P1.M7.T3.S1)

> Verified by direct reads of `lib/pool.sh` (3762 lines), `PRD.md`, and the sibling
> PRPs (P1.M7.T1.S1 status LANDED, P1.M7.T2.S1 reap LANDED in parallel). Line
> numbers are 1-indexed and reflect the LIVE file at research time.

## Summary
`pool_admin_release(target)` is a **lib-only, append-only** function to be
**APPENDED** to `lib/pool.sh` after the LANDED `pool_admin_reap` (current EOF
`lib/pool.sh:3762`). It backs PRD §2.12's `release [<N>|all]` admin command. It
COMPOSES three LANDED helpers — `pool_lanes_list`, `pool_lease_exists`,
`pool_release_lane` — plus the standard precondition (`pool_config_init` +
`pool_state_init`). The single non-obvious correctness constraint: **`pool_release_lane`
is idempotent + rc-0-always + silently no-ops on a missing lease**, so the contract's
"Lane N has no active lease." branch (step d) MUST be detected via a SEPARATE
`pool_lease_exists` check BEFORE delegating to `pool_release_lane` (else a missing
lane would wrongly print "Released lane N." instead of the not-found message).

## 1. `pool_release_lane LANE` (M5.T2.S1 — LANDED @ `lib/pool.sh:2438`)

The PUBLIC teardown function this task reuses. Contract (verified from its body
`lib/pool.sh:2438-2480` + its docstring):

- **rc 0 ALWAYS.** NON-FATAL: never `pool_die`, never non-zero. (Even a missing
  `POOL_REAL_BIN` degrades gracefully; every subprocess is `2>/dev/null || true`.)
- **Idempotent + self-validating:** (a) `[[ "$lane" =~ ^[0-9]+$ ]] || return 0`
  — a non-numeric lane returns 0 (path-traversal defense). (b) `if ! json="$(pool_lease_read
  "$lane" 2>/dev/null)"; then return 0; fi` — a MISSING or CORRUPT lease returns 0
  ("already released"). **⇒ `pool_release_lane 99` (no lease) returns 0 with NO
  signal that the lease was absent.** This is the crux: pool_release_lane CANNOT
  distinguish "I just released lane N" from "lane N had no lease" — BOTH are rc 0.
- Steps when a lease DOES exist: read `session` → daemon `close` (`$POOL_REAL_BIN
  --session "$session" close 2>/dev/null || true`) → delegate to
  `_pool_release_lane_internals "$lane"` (KILL pgroup + RM dir + RM lease, non-fatal).
- Its docstring's CALLER CONTRACT literally names this task:
  `for n in $(pool_lanes_list); do pool_lane_is_stale "$n" && pool_release_lane "$n"; done`
  OR explicit `pool_release_lane "$N"` (M7.T3 admin release).

**Why this matters for this task:** because pool_release_lane swallows the
"no lease" case as rc 0, `pool_admin_release(N)` MUST probe liveness with
`pool_lease_exists` first (see §2) to implement the contract's distinct
"Lane N has no active lease." branch. Calling pool_release_lane blind + reading its
rc is useless (always 0).

## 2. `pool_lease_exists LANE` (M3.T2.S1 — LANDED @ `lib/pool.sh:918`)

The predicate for "does lane N have a valid lease?" — exactly step (d)'s probe.

- **rc 0** = lease file exists AND is valid JSON (`_pool_json_valid`).
- **rc 1** = missing file OR corrupt JSON OR non-numeric lane (`[[ "$lane" =~ ^[0-9]+$ ]] || return 1`).
- Body (`lib/pool.sh:928-942`): `[[ -f "$file" ]] || return 1; _pool_json_valid "$file" || return 1; return 0`.
- **CALLERS-under-set-e MUST guard:** a BARE `pool_lease_exists "$lane"` whose rc
  is 1 (no lease) **ABORTS** the caller under `set -euo pipefail` (lib/pool.sh:23).
  Use `if pool_lease_exists "$lane"; then …; else …; fi` (rc 1 falls into else,
  errexit-exempt). This is the SAME tri-state-guard hazard as `pool_lane_is_stale`
  (status facts §5c) and `pool_lease_read` (rc 1). It is a BOOLEAN predicate
  (0/1 only, not tri-state), but the rc-1 guard requirement is identical.

## 3. `pool_lanes_list` (M3.T2.S1 — LANDED @ `lib/pool.sh:967`)

For the `'all'` iteration. Contract (verified from body `lib/pool.sh:967-983`):

- Echoes every NUMERIC lane stem from `$POOL_LANES_DIR/*.json`, each on its own line,
  numerically sorted (`| sort -n`). Non-numeric stems skipped (`^[0-9]+$` guard).
- **rc 0 ALWAYS.** An empty / missing lanes dir is a VALID state → 0 output → the
  `for n in $(…)` loop body runs 0 times (correct, never an error).
- `for n in $(pool_lanes_list)` is SAFE unquoted: output is digits-only /
  newline-separated → word-splits into exactly the lane numbers (intentional;
  no lane has whitespace). (Mirrors the reap loop + `pool_lease_find_mine`.)
- **Every lane yielded HAS a lease** (it comes from `*.json` + the numeric filter) —
  so iterating `pool_lanes_list` and `pool_release_lane`-ing each releases real lanes.

## 4. The LANDED admin siblings (the shape to mirror — BOTH now in the file)

### 4a. `pool_admin_status` (M7.T1.S1 — LANDED @ `lib/pool.sh:3594`)
Read-only lane table. Structure to reuse (verified `lib/pool.sh:3594-3685`):
- **Precondition** (`lib/pool.sh:3604-3606`): `pool_config_init` + `pool_state_init`
  (both rc-0-or-pool_die → NO guard). `pool_state_init`'s idempotent `mkdir -p`
  guarantees `$POOL_LANES_DIR` exists.
- **Locals up front** (`lib/pool.sh:3595-3602`): `local -a lanes fields; local …`
  — SC2155 house rule (never `local x="$(…)"`).
- **Snapshot lanes into an array** (`lib/pool.sh:3624`):
  `mapfile -t lanes < <(pool_lanes_list)` — process-substitution exit status is NOT
  propagated → set -e safe; empty output → empty array. (The clean empty-pool check.)
- **Empty check** (`lib/pool.sh:3629`): `if (( ${#lanes[@]} == 0 )); then printf
  'No active lanes.\n'; return 0; fi` — `(( ))` INSIDE `if` is errexit-exempt.
- **Per-lane lease read guarded** (`lib/pool.sh:3654`): `if ! json="$(pool_lease_read
  "$lane" 2>/dev/null)"; then …; continue; fi` (rc 1 non-fatal).
- `return 0` at the end.

### 4b. `pool_admin_reap` (M7.T2.S1 — LANDED in parallel @ `lib/pool.sh:3730-3762`)
The CLOSEST analog (same kind: a user-facing admin command that delegates to one
LANDED helper + prints a report). Structure (verified `lib/pool.sh:3730-3762`):
- Same precondition (`pool_config_init` + `pool_state_init`).
- `local count` up front.
- `count="$(pool_reap_stale)"` — bare capture, NO `if !` guard, because
  pool_reap_stale is rc-0-always.
- `if (( count == 0 )); then printf 'No stale lanes found.\n'; else printf 'Reaped
  %d stale lane(s).\n' "$count"; fi`.
- `return 0` — NON-FATAL always.
- **Banner** (`lib/pool.sh:3689-3691`):
  ```
  # ============================================================================
  # Admin CLI — reap (P1.M7.T2.S1)
  # ============================================================================
  ```
  (three lines: 76 `=` , title line, 76 `=`.) THIS task's banner is the SAME shape
  with `release (P1.M7.T3.S1)`.

**The structural difference release has that reap/status do NOT:** release takes an
**argument** (the target). status/reap take none. So release must CLASSIFY the
argument (all / numeric / else) and has a genuine "not found" branch (a specific
lane that has no lease). This is why release's return-code semantics differ (see
design-decisions D6): the two no-arg siblings are rc-0-always; release returns
non-zero for usage-error and targeted-not-found (Unix convention).

## 5. Precondition + globals (frozen by pool_config_init)

`pool_config_init` (@126) freezes `POOL_LANES_DIR`, `POOL_REAL_BIN`, etc.
`pool_state_init` (@202) does the idempotent `mkdir -p $POOL_LANES_DIR`. Both are
rc-0-or-`pool_die` (a misconfigured pool fails loudly — correct; NO guard). This
task reads `$POOL_LANES_DIR` (via `pool_lanes_list` / `pool_lease_exists`) — no new
globals exported.

## 6. `set -e` / SC2155 / `(( ))` gotchas (all LIVE — `set -euo pipefail` @ lib/pool.sh:23)

- **(a) SC2155:** never `local x="$(…)"`; declare then assign. Applies to `target`
  (use `local target="${1:-}"` — this is NOT a `$(…)` capture, so `local target=…`
  inline is fine; but ALL `$(…)` captures must be split). This task does NO `$(…)`
  capture in the simplest design (it iterates + probes), so SC2155 risk is minimal.
- **(b) `(( ))` as a STATEMENT returns 1 when the result is 0 → FATAL under set -e.**
  Keep ALL arithmetic INSIDE `if`/`elif`. `if (( count == 0 ))` is safe; a bare
  `(( count == 0 ))` when count==0 would ABORT. (Alternatively `[[ … ]]` strings.)
- **(c) rc-1 helpers MUST be guarded:** `pool_lease_exists` (rc 1 = no lease) and
  `pool_lease_read` (rc 1 = missing/corrupt) ABORT under set -e if called bare.
  Use `if pool_lease_exists "$lane"; then …; else …; fi`. (This task guards
  pool_lease_exists exactly this way.)
- **(d) rc-0-always helpers need NO guard:** `pool_lanes_list` (rc 0 always) and
  `pool_release_lane` (rc 0 always) can be called bare / captured bare under set -e.

## 7. STDOUT discipline

`_pool_log` (@39) → file + **stderr** (NEVER stdout); `pool_die` (@30) → stderr + exit.
So `pool_admin_release`'s stdout is PURELY the user-facing release message(s) —
capturable + pipeable. Usage (the misuse path) goes to **stderr** by convention.

## 8. DOCS / --help boundary (Mode A)

This task = `pool_admin_release()` ONLY (append to lib). It MUST NOT create
`bin/agent-browser-pool` (M7.T5.S1: `case "$cmd" in release) pool_admin_release "$arg" ;;`).
The item's "DOCS: [Mode A] --help output for 'release' subcommand" is satisfied by a
thorough header doc-comment (the command's behavior + the output messages) + a
suggested `--help` one-liner the dispatcher author references. Like the reap/status
PRPs, this task documents + provides suggested text; it does NOT wire `--help`.

## 9. Parallel-execution context (P1.M7.T2.S1 reap lands first)

`pool_admin_reap` is LANDED in the file (@3730-3762, current EOF=3762). The
orchestrator sequences research → implement; reap's research finished first
(plan_status: reap "Ready"/being-implemented, release "Researching"). So when
release's implementation begins, **pool_admin_reap is at EOF** and release APPENDS
after it. Task 0 of this PRP verifies the live EOF before appending (the line number
will be ≥3762; may shift if other tasks land — append after the LAST `}` of
`pool_admin_reap`). No write conflict: append-only, serial.

## 10. Sibling boundaries (do NOT collide)

- **M7.T1.S1 status** (LANDED) — separate command. Do not touch.
- **M7.T2.S1 reap** (LANDED) — separate command. This task appends AFTER it.
- **M7.T4.S1 doctor** (future) — separate command. Do not preempt.
- **M7.T5.S1 dispatcher** (future) — owns `bin/agent-browser-pool` + `--help` wiring
  + the `case "$cmd" in release) …` dispatch. This task provides the FUNCTION the
  dispatcher calls by name.
- **M5.T2.S1 pool_release_lane** (LANDED) — the delegate. Do NOT modify it.
- **M5.T3.S1 pool_reap_stale** — DIFFERENT operation (stale-only sweep). release is
  EXPLICIT (admin-named lane(s), live-or-stale); reap is IMPLICIT (stale-only). Do
  NOT route release through pool_reap_stale.
