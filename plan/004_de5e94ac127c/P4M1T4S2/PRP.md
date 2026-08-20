# PRP — P4.M1.T4.S2: Wrapper integration: skip find-mine when pinned; NO exhaustion fallback

## Goal

**Feature Goal**: Wire lane pinning (`POOL_LANE_PIN`, set from `ABPOOL_LANE=<N>` by `pool_config_init`, P4.M1.T2.S1) into `pool_wrapper_main` in `lib/pool.sh`. When pinned: (a) SKIP `pool_lease_find_mine` (a different live lane would shadow the pin — S1's pin branch case 3 already handles live-mine reuse idempotently), and (b) NEVER fall back to `pool_wait_for_lane` on acquire failure — a live-foreign pin must die immediately ("never wait, never force", PRD §2.12/§2.15). When unpinned: behavior must be byte-identical to HEAD.

**Deliverable**: A modified `pool_wrapper_main` step e→g block (plus a small doc-comment addition) in `lib/pool.sh`. No change to `bin/agent-browser-pool` (27 lines — just sources lib and execs the wrapper).

**Success Definition**: `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` clean; diff shows only the pin branch + comments; end-to-end contract: `ABPOOL_LANE=N agent-browser-pool <driving…>` claims/adopts/reuses lane N or hard-errors; `ABPOOL_OWNER=caller ABPOOL_LANE=N` combines both modes with no special-casing.

## Why

Without this, the wrapper's existing step-e `pool_lease_find_mine` could return a different live lane and silently bypass the pin, and the existing `pool_wait_for_lane` fallback (block → force-reap) would violate the pin contract's "never wait, never force-reap" guarantee for a live-foreign lease (§2.12 mode 2, §2.15 last row). PRD references: §2.12, §2.13 note, §2.15, §2.20 (`ABPOOL_LANE` validation note).

## All Needed Context

### Context Completeness Check

The implementer needs the exact wrapper block, rc conventions, and the S1 contract — all below. No external research required.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: pool_wrapper_main — step e→g block (find-mine → acquire → wait-for-lane fallback →
        boot-vs-adopt). The comments "e→g. find-or-acquire my lane (steps 2→3)" and
        "Fallback to wait-for-lane on exhaustion" locate the edit precisely.
  pattern: lane flows via STDOUT capture `if N="$(pool_lease_find_mine)"` inside an if
        (errexit-exempt); NEVER `local N="$(…)"` (SC2155 — the wrapper comment block says so).
  gotcha: pool_lease_find_mine / pool_acquire_locked / pool_wait_for_lane are rc 0/1
        non-fatal; pool_die is terminal (exit 1).

- file: plan/004_de5e94ac127c/P4M1T4S1/PRP.md
  why: CONTRACT for the acquire-level pin branch (assumed implemented exactly as specified):
        when POOL_LANE_PIN non-empty, pool_acquire_locked returns lane N on stdout for
        free/stale/live-mine cases; on live-foreign (case 4) or my-other-live-lane (case 5)
        it dies INSIDE the flock subshell with the detailed diagnostic (lane N, live owner
        pid/comm) on stderr and non-zero exit.
  critical: the wrapper must NOT re-implement pin logic — it only (a) routes around
        find-mine and (b) replaces the wait-fallback with a pin-context die. The detailed
        diagnostic was already printed inside the critical section; the wrapper die only
        adds pin context and terminates.

- file: lib/pool.sh (pool_config_init, ~L224–L233)
  why: POOL_LANE_PIN is already parsed/validated (uint-or-empty; malformed → die) and is a
        global by the time pool_wrapper_main runs. Do NOT re-validate.

- file: lib/pool.sh (pool_owner_resolve, modified by P4.M1.T3.S1)
  why: caller mode (ABPOOL_OWNER=caller) sets the same POOL_OWNER_* globals — the wrapper
        pin branch must be mode-agnostic (no branching on POOL_OWNER_MODE).

- docfile: plan/004_de5e94ac127c/prd_snapshot.md
  why: §2.12 (pin: "skip pool_lease_find_mine / pool_find_free_lane"), §2.15 fail-fast row,
        §2.19 pin-conflict test note.
```

### Known Gotchas of our codebase

```bash
# CRITICAL — pinned acquire failure must NOT reach pool_wait_for_lane: today ANY
#   `pool_acquire_locked` rc≠0 (including the pin's live-foreign die) falls into the
#   wait/retry/force-reap block — which would loop or force-reap against the pin contract.
# CRITICAL — pool_die inside the S1 critical section already exited the flock subshell
#   before control returns here; the wrapper's `|| pool_die …` is the terminal surface.
# SC2155: keep the existing split-capture style (`N="$(…)"` inside `if`/after `local N`).
# Everything AFTER a successful acquire (boot-vs-adopt port check L3-branch,
#   pool_ensure_connected, close/connect normalization, session force, exec) stays
#   UNTOUCHED and mode-agnostic — a pinned provisional lease boots exactly like an auto one.
```

## Implementation Blueprint

### Implementation Tasks

```yaml
Task 1: MODIFY lib/pool.sh — pool_wrapper_main step e→g: pin-aware routing
  - FIND: the block starting with the comment `# --- e→g. find-or-acquire my lane (steps 2→3)`
  - REPLACE the routing so that:
      if [[ -n "${POOL_LANE_PIN:-}" ]]; then
          # Pinned (PRD §2.12): skip find-mine (case 3 of the acquire pin branch already
          # reuses a live-mine pin idempotently) and NEVER fall back to wait-for-lane —
          # a live-foreign pin must die fast ("never wait, never force", §2.15).
          N="$POOL_LANE_PIN"
          pool_acquire_locked >/dev/null || \
              pool_die "agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)"
      elif N="$(pool_lease_find_mine)"; then
          _pool_log "pool_wrapper_main: reusing lane $N"
      else
          … EXISTING auto path verbatim (acquire → wait_for_lane fallback → die) …
      fi
      (boot-vs-adopt block unchanged, outside the branch — reached by both paths)
  - GOTCHAS on the pinned capture:
      * pool_acquire_locked PRINTS lane N on success. Since N==POOL_LANE_PIN by
        construction, capturing via `pool_acquire_locked >/dev/null` is fine and avoids
        SC2155; alternatively `N="$(pool_acquire_locked)" || pool_die …` (assignment inside
        || is errexit-safe) — pick one and keep shellcheck clean.
      * The exact die string above is the contract; the detailed diagnostic (lane, live
        owner pid/comm) was already emitted by the S1 critical-section pool_die on stderr.
  - DO NOT touch: boot-vs-adopt (`port="$(pool_lease_field …)"`), pool_ensure_connected,
    normalization, session force, close-scoping, exec.

Task 2: UPDATE the pool_wrapper_main doc-comment block
  - ADD: a short "PIN MODE (PRD §2.12/§2.13, O11)" note — pinned calls skip find-mine,
    never use pool_wait_for_lane, hard-die on acquire failure; combined with
    ABPOOL_OWNER=caller with no special-casing. Cite §2.12/§2.13.
  - No other docs (user-facing pin docs are P4.M1.T4.S3).

Task 3: STATIC verification that default + unpinned paths are identical to HEAD
  - `git diff lib/pool.sh` must show ONLY: the pin routing change (wrapping the existing
    find-mine call in an elif / equivalent restructure that preserves its exact body) and
    doc-comment additions. If the restructure inlines the existing `if N="$(…)"` as an
    `elif`, the body lines must be byte-identical to the originals.
```

### Integration Points

```yaml
INPUTS: POOL_LANE_PIN (pool_config_init, T2.S1); POOL_OWNER_* (pool_owner_resolve, T3.S1);
        S1's _pool_acquire_critical_section pin branch (contract above).
OUTPUT: end-to-end pinned invocation. Tested at acquire level by P4.M2.T1.S4; optional E2E
        by P4.M2.T2.S2. Die string recorded for P4.M1.T4.S3 doc mirror.
UNTOUCHED: bin/agent-browser-pool; everything post-acquire in pool_wrapper_main.
```

## Validation Loop

### Level 1: Syntax & Lint (static only — AGENTS.md §1; NO Chrome, NO test suite)

```bash
bash -n lib/pool.sh                 # rc 0, no output
shellcheck -s bash lib/pool.sh      # no new findings
git diff lib/pool.sh                # only pin routing + comments; unpinned/auto paths byte-identical
```

### Level 2: Static logic checklist

- [ ] `POOL_LANE_PIN` non-empty ⇒ `pool_lease_find_mine` never called; `pool_wait_for_lane` never called.
- [ ] Pinned acquire failure ⇒ exactly one wrapper die with the contract string (the S1 stderr diagnostic already printed above it); exit 1.
- [ ] Pinned success ⇒ N==POOL_LANE_PIN flows into the UNCHANGED boot-vs-adopt block (port==0 → boot; live-mine reuse case 3 → lease port>0 or connected, handled by the same port read + ensure_connected).
- [ ] No `POOL_LANE_PIN` format validation added (done in config).
- [ ] No branching on POOL_OWNER_MODE — pin works identically in caller and ancestor modes.
- [ ] Unpinned path (no env vars) byte-identical to HEAD.

Runtime validation (pin matrix, E2E) is P4.M2's scope — do NOT run it here.

## Final Validation Checklist

- [ ] `bash -n` + `shellcheck` clean; diff minimal as specified.
- [ ] `ABPOOL_LANE=N agent-browser-pool <driving…>`: claims/adopts/reuses lane N or hard-errors (statically verified routing).
- [ ] `ABPOOL_OWNER=caller ABPOOL_LANE=N` combines modes with zero special-casing.
- [ ] Die string matches the contract verbatim; recorded in subtask output for S3.
- [ ] Doc-comment cites PRD §2.12/§2.13.
- [ ] No Chrome booted, no daemons, no orphans, no temp dirs left behind.

## Anti-Patterns to Avoid

- ❌ Don't let a pinned call reach `pool_wait_for_lane` (block/force-reap violates the pin contract).
- ❌ Don't call `pool_lease_find_mine` when pinned (a different live lane would shadow the pin).
- ❌ Don't re-implement pin conflict logic in the wrapper — S1 owns it; the wrapper only adds pin context on failure.
- ❌ Don't re-validate ABPOOL_LANE format.
- ❌ Don't touch boot/ensure_connected/normalization/exec or `bin/agent-browser-pool`.
- ❌ Don't use `local x="$(…)"` (SC2155) or bare rc-0/1 helper calls outside guards.