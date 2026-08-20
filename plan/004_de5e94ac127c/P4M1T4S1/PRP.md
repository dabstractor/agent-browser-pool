# PRP — P4.M1.T4.S1: Pin branch in `_pool_acquire_critical_section`

## Goal

**Feature Goal**: Add the `ABPOOL_LANE=<N>` pin branch (PRD §2.12 mode 2, O11, §2.15 last row) to `_pool_acquire_critical_section` in `lib/pool.sh`. When `POOL_LANE_PIN` is non-empty, the critical section deterministically acquires lane N (free → claim, stale → reap+claim, live-mine → idempotent reuse) and hard-errors on a live foreign lease or a live lease held by me on another lane. When `POOL_LANE_PIN` is empty, the existing auto path (reap-all/adopt/choose-N/claim) stays **byte-identical**.

**Deliverable**: A modified `_pool_acquire_critical_section` (plus its doc comment) in `lib/pool.sh`, producing a lane number on stdout that `pool_acquire_locked` (unchanged) passes through, consumed downstream by P4.M1.T4.S2 (wrapper) and tested by P4.M2.T1.S4.

**Success Definition**: `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` are clean; the unpinned code path is untouched byte-for-byte; the pinned path implements all 5 case branches below with the exact die strings recorded in the subtask output for the S3 documentation mirror.

## Why

Deterministic lane assignment ("scraper X always gets lane 3") for orchestrator-mode parallel scrapers, per PRD decision O11. A pin must never take over a live foreign lane (isolation guarantee, §2.14) and never silently fall back to auto-assignment.

## All Needed Context

### Context Completeness Check

Everything an implementer needs is in this PRP: exact function locations, rc conventions, the claim call to copy verbatim, the exact diagnostic strings, and the set -e / flock gotchas. No external libraries beyond the codebase itself.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: _pool_acquire_critical_section (L2203–L2248) is the edit target; pool_acquire_locked
        (L2280+, `flock 9` on $POOL_LOCK_FILE) runs it in a subshell
  pattern: existing claim call at L2240–L2244 is the EXACT call to reuse for pinned claims
  gotcha: pool_die inside the flock subshell is SAFE — exits subshell → kernel closes fd 9 →
          flock auto-released → exit 1 propagates (documented at L2259–L2260 region)

- file: lib/pool.sh
  why: pool_lane_is_stale (L1178–L1224) — tri-state rc: 0=stale, 1=live, 2=no-lease
  gotcha: a BARE call ABORTS under set -e on rc 1/2; capture with
          `pool_lane_is_stale "$N" && st_rc=0 || st_rc=$?` to read all three codes

- file: lib/pool.sh
  why: _pool_release_lane_internals (L2050–L2095) — idempotent non-fatal lane teardown
        (kills chrome pgroup, rm ephemeral dir + lease). Used verbatim for case (2).

- file: lib/pool.sh
  why: pool_lease_find_mine (L1088–L1108) — the template for the case-(5) scan loop:
        pool_lanes_list; pool_lease_field "$n" owner.pid (|| continue); cheap pid equality;
        then owner.starttime/owner.comm + pool_owner_alive

- file: lib/pool.sh
  why: _pool_adopt_lane / the reap loop L2213–L2233 — shows the one-jq-fork field-extraction
        idiom (mapfile -t over `jq -r '.owner.pid, .owner.comm, .owner.starttime'`)

- file: lib/pool.sh
  why: pool_config_init L224–L233 — POOL_LANE_PIN is already parsed/validated
        (uint-or-empty, malformed → die) and exported as a global by P4.M1.T2.S1.
        THIS TASK MUST NOT re-validate the format; it only checks non-emptiness.

- docfile: plan/004_de5e94ac127c/prd_snapshot.md
  why: §2.12 (pin semantics), §2.15 (fail-fast row), §2.14 (isolation), §2.20 (notes)
```

### Known Gotchas of our codebase

```bash
# CRITICAL — set -e hazards (AGENTS.md §4):
#   pool_lane_is_stale returns rc 1 (live) / rc 2 (no lease) on non-stale paths —
#   a bare call aborts. Always capture: `pool_lane_is_stale "$N" && st_rc=0 || st_rc=$?`.
#   pool_lease_field returns 1 on missing/corrupt → `|| continue` in scan loops.
#   Do NOT use `local x="$(…)"` (SC2155) — split declaration and assignment.

# CRITICAL — flock subshell: pool_die is safe inside the critical section (exits the
#   subshell; fd 9 closes; flock auto-releases; rc 1 propagates to pool_acquire_locked's
#   caller). The (4)/(5) hard errors use pool_die (stderr + exit 1).

# A pin NEVER consults pool_find_free_lane — it has no bound and would pick a different N.
# A pin NEVER adopts a responsive orphan on lane N (deliberately unlike the auto path's
#   REUSE-ORPHAN): deterministic assignment prefers a clean lane. Stale ⇒ reap ⇒ fresh claim.

# Reuse (case 3) does NO lease rewrite — echo N and return 0 only.
# Boot is untouched: a pinned provisional lease (port=0, connected=false) boots exactly
#   like an auto one (post-lock S2 path reads port==0 → pool_boot_lane).
```

## Implementation Blueprint

### Implementation Tasks

```yaml
Task 1: MODIFY lib/pool.sh — _pool_acquire_critical_section: insert the pin branch
  - PLACEMENT: immediately AFTER the POOL_OWNER_PID==0 defensive guard (which stays
    first for both paths) and BEFORE the reap/adopt scan loop. Structure:

      if [[ -n "$POOL_LANE_PIN" ]]; then
          local N="$POOL_LANE_PIN" st_rc json o_pid o_comm o_start
          # Tri-state capture (set -e safe):
          pool_lane_is_stale "$N" && st_rc=0 || st_rc=$?

          # (1) rc 2 (no lease) AND no $POOL_EPHEMERAL_ROOT/$N dir  → FREE → CLAIM.
          # (2) rc 0 (STALE) → _pool_release_lane_internals "$N" (no adoption!) → CLAIM.
          # (3) rc 1 (LIVE) + lease owner is ME → printf '%s\n' "$N"; return 0  (NO rewrite).
          # (4) rc 1 (LIVE) + FOREIGN owner → pool_die (exact string below).
          #     Note rc 2 + dir $POOL_EPHEMERAL_ROOT/$N EXISTS but leaseless = orphaned dir:
          #     treat as stale-debris — _pool_release_lane_internals won't remove it (no
          #     lease); rm the dir the same guarded way internals does (prefix-guard under
          #     $POOL_EPHEMERAL_ROOT), then CLAIM. (Keeps the pin deterministic + clean.)
          # (5) BEFORE claiming in cases (1)/(2), scan for a LIVE lease owned by ME on a
          #     DIFFERENT lane (template: pool_lease_find_mine loop body L1088–L1108 +
          #     skip lane == "$N") → if found, pool_die (exact string below). This
          #     preserves the ≤1-lane-per-owner invariant (§2.8).

      For the CLAIM in cases (1)/(2), copy the EXISTING claim call byte-for-byte with
      N="$POOL_LANE_PIN":
          ephemeral_dir="$POOL_EPHEMERAL_ROOT/$N"
          pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" \
              "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" \
              "${POOL_OWNER_CWD:-}" 0 0 "false"
          _pool_log "pool_acquire(pin): provisional lane $N for owner pid=$POOL_OWNER_PID"
          printf '%s\n' "$N"
          return 0

      For owner identification in cases (3)/(4), extract the lease's owner triple ONCE
      with one jq fork on the in-memory JSON (pool_lease_read):
          mapfile -t _f < <(jq -r '.owner.pid, .owner.comm, .owner.starttime' <<<"$json")
      "Is ME" ⇔ o_pid == "$POOL_OWNER_PID" AND o_comm == "$POOL_OWNER_COMM" AND
      o_starttime == "${POOL_OWNER_STARTTIME:-0}".

  - ORDERING recommendation: do the case-(5) other-lane scan FIRST in the pin branch
    (before handling lane N), so the invariant error fires even when lane N is free.
  - DO NOT touch any other line of the function — the auto path (POOL_LANE_PIN empty)
    must remain byte-identical.

Task 2: UPDATE the function's doc-comment block to document the pin branch: the 5 cases,
  the no-adoption/no-find-free-lane rule, and that pool_die is safe inside the subshell.
  Cite PRD §2.12 (O11) / §2.15.

Task 3: RECORD the exact die strings in the subtask output (for the P4.M1.T4.S3 doc
  mirror). REQUIRED strings (implement verbatim):
  - Case (4): pool_die "pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane"
  - Case (5): pool_die "owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE"
```

### Integration Points

```yaml
INPUTS:
  - POOL_LANE_PIN: global set by pool_config_init (P4.M1.T2.S1); "" = auto path; format
    already validated pre-flock (do NOT re-validate).
  - POOL_OWNER_PID / _COMM / _STARTTIME / _CWD: set by pool_owner_resolve; the pin branch
    is mode-agnostic (works in caller mode AND ancestor mode).
OUTPUT:
  - pool_acquire_locked unchanged: single-line lane number + rc 0 on success; on (4)/(5)
    the subshell exits non-zero with the stderr diagnostic (flock auto-released).
  - Consumed by P4.M1.T4.S2 (wrapper: skip find-mine when pinned; no exhaustion fallback)
    and P4.M2.T1.S4 (pin matrix selftest).
DOCS: configuration.md pin subsection + troubleshooting rows live in P4.M1.T4.S3 —
  only the exact strings need to be recorded in this subtask's output.
```

## Validation Loop

### Level 1: Syntax & Lint (static only — AGENTS.md rules)

```bash
bash -n lib/pool.sh                 # Expected: no output, rc 0
shellcheck -s bash lib/pool.sh      # Expected: no new findings (baseline-clean)
git diff lib/pool.sh                # Eyeball: the auto path is byte-identical
```

Verify the auto path is untouched: the diff must show ONLY (a) the new `if [[ -n "$POOL_LANE_PIN" ]]` block, (b) doc-comment additions. Any hunk touching the reap loop / `pool_find_free_lane` / existing claim call is a bug.

### Level 2: Static logic self-review checklist

- [ ] Pin branch sits after the PID!=0 guard, before the reap scan loop; auto path reaches the scan loop with zero changed lines.
- [ ] All `pool_lane_is_stale` / `pool_lease_field` / `pool_lease_read` calls are set -e-guarded (`if`/`&& rc=… || rc=$?` / `|| continue`).
- [ ] No `pool_find_free_lane` and no `_pool_adopt_lane` call inside the pin branch.
- [ ] Case (2) calls `_pool_release_lane_internals "$N"` then claims (fresh lease, port=0).
- [ ] Case (3) echoes N and returns 0 with no lease write.
- [ ] No new process spawning (no Chrome, no daemons) inside the lock beyond what internals already does.

Runtime behavior (real flock/Chrome) is validated later in P4.M2.T1.S4 / P4.M2.T3 — do NOT run the test suite or boot Chrome in this subtask (AGENTS.md §1).

## Final Validation Checklist

- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean.
- [ ] Unpinned path byte-identical (verified via diff review).
- [ ] All 5 pin cases implemented: free→claim, stale→reap+claim (no adopt), live-mine→echo+rc0, live-foreign→die, my-other-live-lane→die.
- [ ] Exact die strings emitted verbatim and recorded in the subtask output for S3.
- [ ] Doc-comment updated with PRD §2.12/O11 citations.
- [ ] No orphaned processes, temp dirs, or Chrome launches left by this subtask.

## Anti-Patterns to Avoid

- ❌ Don't re-validate `POOL_LANE_PIN`'s format (done pre-flock in P4.M1.T2.S1).
- ❌ Don't adopt a responsive orphan on the pinned lane — stale always reaps+claims fresh.
- ❌ Don't fall back to `pool_find_free_lane` on any pin conflict — hard error only.
- ❌ Don't rewrite the lease in case (3) (idempotent reuse).
- ❌ Don't use bare `pool_lane_is_stale`/`pool_lease_field` calls (set -e abort on rc≠0).
- ❌ Don't touch the auto path or any other function.