# Design Decisions — `pool_admin_reap()` (P1.M7.T2.S1)

Synthesis of codebase-reap-facts into the concrete decisions the PRP pins. This
is a **0.5-point thin wrapper** — the bulk of the complexity (reap teardown,
tri-state staleness, idempotent release) lives in the LANDED `pool_reap_stale`
(M5.T3.S1). `pool_admin_reap` only: init → capture count → print message → return 0.

## D1 — LIB-ONLY, append-only, after the LANDED `pool_admin_status`

- `pool_admin_reap()` is **APPENDED** to `lib/pool.sh` after `pool_admin_status`
  (current EOF = `lib/pool.sh:3681`, verified LANDED this session), under a NEW
  parallel banner `# Admin CLI — reap (P1.M7.T2.S1)`.
- Each admin command owns its OWN banner (parallel-safe; matches the sibling's
  `# Admin CLI — status (P1.M7.T1.S1)`).
- Consumed later by the dispatcher `bin/agent-browser-pool` (M7.T5.S1):
  `case "$cmd" in reap) pool_admin_reap ;; …`). That binary does NOT exist yet
  and is OUT OF SCOPE.
- Greenfield confirmed (`grep pool_admin_reap` → none). No existing function
  modified; no new files; no new env-vars/globals.

## D2 — Precondition: `pool_config_init` + `pool_state_init` (mirrors the sibling)

Identical to `pool_admin_status` (`lib/pool.sh:3604-3606`) and
`pool_wrapper_main` step "a" (`lib/pool.sh:3455-3459`). Both are
rc-0-or-`pool_die` → NO guard. `pool_state_init`'s idempotent `mkdir -p`
guarantees `$POOL_LANES_DIR` exists, so a fresh pool's first `reap` just works.

Note: `pool_reap_stale`'s own docstring says `pool_state_init` is "NOT required"
(because `pool_lanes_list` handles a missing dir as a no-match glob → 0 iters).
But `pool_admin_reap` is a **user-facing command** (called directly by the
dispatcher) and MUST be self-contained — so it does the init itself, mirroring
the sibling. This is harmless (idempotent) and consistent.

## D3 — Capture pool_reap_stale's stdout (THE key correctness decision)

`pool_reap_stale` writes the raw integer count to ITS stdout. `pool_admin_reap`
MUST capture it:

```bash
count="$(pool_reap_stale)"
```

- **NO guard needed**: `pool_reap_stale` returns 0 ALWAYS (codebase-facts §1) →
  a bare capture is `set -e`-safe. This is the ONE place `pool_admin_reap` is
  SIMPLER than the sibling `pool_admin_status` (which must guard
  `pool_lease_read`/`pool_lane_is_stale`).
- If captured WITHOUT redirect, the raw integer would leak to the user
  alongside the message (codebase-facts §4). The capture is what prevents that.
- The capture's `$()` strips the trailing newline, so `count` is a bare integer
  token (`"0"`, `"1"`, `"3"`, …).

## D4 — Message format (PINNED — verbatim from the item contract)

```bash
if (( count == 0 )); then
    printf 'No stale lanes found.\n'
else
    printf 'Reaped %d stale lane(s).\n' "$count"
fi
```

- **N == 0** → `No stale lanes found.` (exact, from item contract step 3c).
- **N > 0** → `Reaped N stale lane(s).` (exact, from item contract step 3b).
- The literal string `lane(s)` handles both singular and plural (N=1 → "Reaped 1
  stale lane(s).", N=3 → "Reaped 3 stale lane(s)."). **Do NOT special-case** the
  singular — the contract's `(s)` convention is the spec.

## D5 — The `count == 0` comparison: `(( ))` inside `if` (errexit-exempt)

`(( count == 0 ))` as a **bare statement** returns rc 1 when the expression is
0 → FATAL under `set -e` (codebase-facts §5b). **Inside `if` it is exempt**:
`if (( count == 0 )); then …` is safe. (Equivalently, a string comparison
`[[ "$count" == "0" ]]` avoids arithmetic entirely — both are acceptable. The
`(( ))`-inside-`if` form is used here for readability + to match the
`count`-is-numeric intent.)

## D6 — Return 0 always (non-fatal, mirrors `pool_reap_stale` + sibling)

`pool_admin_reap` NEVER calls `pool_die` in its own body and NEVER returns
non-zero. A reap that reaps 0 lanes is NOT an error — it prints "No stale lanes
found." and returns 0. (The precondition helpers `pool_config_init`/
`pool_state_init` may `pool_die` on genuine misconfiguration — that is their
contract and is correct: a broken pool must fail loudly, not silently claim
"No stale lanes found.")

## D7 — stdout discipline (the report is the ONLY stdout)

`pool_admin_reap`'s stdout is **exactly one line**: the reap report (either
"Reaped N stale lane(s)." or "No stale lanes found."). `pool_reap_stale`'s raw
integer is CAPTURED (not passed through). `_pool_log` writes file+stderr (never
stdout); `pool_die` writes stderr+exit. So the report is cleanly capturable:
`out="$(pool_admin_reap)"` yields exactly the one message line.

## D8 — DOCS (Mode A): header doc-comment + suggested --help text

The item's "DOCS: [Mode A] --help output for 'reap' subcommand" is satisfied:
1. **In the function's header doc-comment**: document the reap command's
   behavior, input, output messages, and non-fatal contract.
2. **A suggested `--help` text block** (in the PRP) for the future dispatcher
   (M7.T5.S1) to reference/echo when wiring `agent-browser-pool reap --help`.

The actual `--help` PARSING + echo is M7.T5.S1's job (the dispatcher). This task
is lib-only.

## D9 — Validation strategy (no Chrome needed for the core logic)

Because `pool_admin_reap` is a thin wrapper, its validation has two tiers:

1. **Unit tests (override `pool_reap_stale`)** — isolate the MESSAGE logic from
   the reap teardown entirely. Override `pool_reap_stale` to echo a fixed count,
   then assert the exact message for N=0, N=1, N=5. Fully deterministic, no
   Chrome, no close subprocess, no FS state. This is the PRIMARY proof.
2. **Integration test (real synthetic stale lease)** — one end-to-end case: a
   synthetic stale lease (dead owner pid 99998) → `pool_admin_reap` captures the
   real count from the real `pool_reap_stale` → asserts "Reaped 1 stale
   lane(s)." Confirms the capture path works against the real function.
   (`pool_release_lane`'s close is fast + rc 0 on a missing daemon, codebase-facts
   §8, so no real Chrome is needed — the dead-owner-pid trick suffices.)

## Decisions summary table

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | lib-only, append after `pool_admin_status`, own banner | parallel-safe; matches sibling |
| D2 | precondition = `pool_config_init` + `pool_state_init` | self-contained; mirrors sibling |
| D3 | capture `count="$(pool_reap_stale)"`, NO guard | pool_reap_stale rc 0 always; prevents integer leak |
| D4 | messages: "Reaped N stale lane(s)." / "No stale lanes found." | verbatim item contract; literal `lane(s)` |
| D5 | `if (( count == 0 ))` inside `if` | errexit-exempt; `(( ))` bare statement is fatal |
| D6 | return 0 always, no `pool_die` in body | non-fatal; 0 reaped is not an error |
| D7 | stdout = exactly one report line | cleanly capturable; integer captured not leaked |
| D8 | DOCS via header doc-comment + suggested --help text | Mode A; --help wiring is M7.T5.S1 |
| D9 | unit (override) + integration (synthetic stale) tests | isolates message logic; confirms capture path |
