# Design Decisions — `pool_admin_release()` (P1.M7.T3.S1)

Synthesis of codebase-facts (§1–§10) into the concrete decisions the PRP pins.
This is the authoritative pre-implementation spec.

## D1 — LIB-ONLY, append-only, under its own banner

- `pool_admin_release()` is **APPENDED** to `lib/pool.sh` AFTER the LANDED
  `pool_admin_reap` (current EOF `lib/pool.sh:3762`), under a NEW banner identical
  in shape to the reap banner:
  ```
  # ============================================================================
  # Admin CLI — release (P1.M7.T3.S1)
  # ============================================================================
  ```
- Consumed later by the dispatcher `bin/agent-browser-pool` (M7.T5.S1):
  `case "$cmd" in release) pool_admin_release "$@" ;;`. That binary does NOT exist
  and is OUT OF SCOPE.
- Greenfield confirmed: `grep -n 'pool_admin_release' lib/pool.sh` → no matches.
- No existing function modified; no new files; no new env-vars/globals.

## D2 — Argument: ONE optional positional `target="${1:-}"`

Unlike the no-arg status/reap siblings, release takes a target. The dispatcher
passes the user's argument (or none):
- `agent-browser-pool release` → `pool_admin_release` (or `pool_admin_release ""`) → `target=""`.
- `agent-browser-pool release 5` → `pool_admin_release "5"` → `target="5"`.
- `agent-browser-pool release all` → `pool_admin_release "all"` → `target="all"`.

`local target="${1:-}"` captures it (inline `local` is SC2155-safe because it is
NOT a `$(…)` capture — it is a parameter expansion with a default). Both
"missing arg" and "empty-string arg" collapse to `target=""` → the usage branch.

## D3 — Classify target: `all` → numeric → else (usage)

```bash
if [[ "$target" == "all" ]]; then
    # (a) iterate all lanes
elif [[ "$target" =~ ^[0-9]+$ ]]; then
    # (b)/(d) numeric — probe existence, then release OR not-found
else
    # (c) empty OR invalid → usage
fi
```

- `== "all"` is exact (case-sensitive). `release ALL` → invalid → usage (acceptable;
  matches the literal contract token 'all').
- `^[0-9]+$` accepts only non-negative integers. `"-5"`, `"1.5"`, `"0x10"`, `"abc"`,
  `""` all fall to `else` → usage. (Lane numbers are canonical non-negative ints;
  there is no lane -5.) Leading-zero `"05"` passes the regex; `pool_lease_exists "05"`
  checks `$POOL_LANES_DIR/05.json` (which won't exist for canonical lanes) → the
  not-found message echoes "Lane 05 has no active lease." Acceptable edge case.

## D4 — (a) `all`: snapshot lanes, release each, count-based summary

Mirrors `pool_admin_status`'s snapshot-first pattern (status facts §4a /
`lib/pool.sh:3624`) for an ACCURATE count + a clean empty-pool check:

```bash
mapfile -t lanes < <(pool_lanes_list)
if (( ${#lanes[@]} == 0 )); then
    printf 'No active lanes to release.\n'
    return 0
fi
for lane in "${lanes[@]}"; do
    pool_release_lane "$lane"   # rc 0 always → bare call is set -e-safe
done
printf 'Released %d lane(s).\n' "${#lanes[@]}"
return 0
```

- **NO `pool_lease_exists` probe per lane in `all`** (unlike the numeric branch):
  `pool_lanes_list` yields ONLY lanes with a lease; every iterated lane is real.
  `pool_release_lane` is rc-0-always → the loop cannot abort. Snapshotting first
  means `${#lanes[@]}` is the count at snapshot time (a concurrent reap may race a
  lane away, but pool_release_lane no-ops cleanly on it; the summary count reflects
  what was present — acceptable + the documented contract is just "Print summary").
- **Messages (PINNED):** `"Released %d lane(s).\n"` for N>0 (literal `lane(s)` per
  the reap convention — no singular special-case); `"No active lanes to release.\n"`
  for the empty pool (parallels status's `"No active lanes."` + reap's `"No stale
  lanes found."`).
- `(( ${#lanes[@]} == 0 ))` is INSIDE `if` → errexit-exempt (the `(( ))`-returns-1
  gotcha does not apply in a condition).

## D5 — (b) numeric: probe `pool_lease_exists` BEFORE `pool_release_lane` (THE key decision)

This is the single non-trivial correctness constraint (facts §1). `pool_release_lane`
is idempotent + rc-0-always + **silently no-ops on a missing lease**. So you CANNOT
tell "released N" from "N had no lease" by calling pool_release_lane and reading its
rc (always 0). The contract's two distinct numeric branches require a SEPARATE
existence probe:

```bash
if pool_lease_exists "$target"; then
    pool_release_lane "$target"          # the real teardown
    printf 'Released lane %s.\n' "$target"
    return 0
else
    printf 'Lane %s has no active lease.\n' "$target"   # contract step (d)
    return 1
fi
```

- **`if pool_lease_exists …; then` is MANDATORY under set -e** (facts §2): a bare
  call with rc 1 (no lease) ABORTS. The `if` makes rc 1 fall into `else` cleanly.
- **`pool_release_lane "$target"` is called bare** (NO guard): rc 0 always (facts §1).
- **Messages (PINNED, verbatim from the contract):** `"Released lane %s.\n"` (step
  b) and `"Lane %s has no active lease.\n"` (step d). `%s` echoes the target token
  verbatim (so `release 7` → "Released lane 7." / "Lane 7 has no active lease.").

## D6 — Return codes: rc 0 for success; rc 1 for usage-error + targeted-not-found

**This DELIBERATELY diverges from the reap sibling's "rc 0 always"** — and the
reasoning is structural, not arbitrary:

- The no-arg siblings (status, reap) **cannot fail**: status is read-only; reap
  delegates to pool_reap_stale (rc 0 always). "Reaping 0 lanes" / "empty pool" are
  VALID states, not errors → rc 0 is correct for them.
- release, given a **SPECIFIC lane**, CAN hit "not found" (the named lane has no
  lease). That is a genuine, targeted miss — semantically different from "Released
  lane N." (the contract prints a DIFFERENT message for it). It is NOT a vacuous
  success like "empty pool."
- Unix CLI convention: a usage error (`release` / `release foo`) and a named-target
  miss (`release 99` where 99 is absent) return **non-zero** so scripts can detect
  them (`agent-browser-pool release 5 || handle`).

| case | condition | message (stdout) | rc |
|------|-----------|------------------|----|
| (a) all, N>0 | lanes present | `Released N lane(s).` | **0** |
| (a) all, N==0 | empty pool | `No active lanes to release.` | **0** |
| (b) numeric, exists | lease present | `Released lane N.` | **0** |
| (c) empty/invalid | not all, not numeric | *(usage → stderr)* | **1** |
| (d) numeric, no lease | lease absent | `Lane N has no active lease.` | **1** |

- `all` on an empty pool is rc 0 (the vacuous-success case, like `rm -f` on a missing
  file): the admin released everything (there was nothing).
- The numeric not-found is rc 1 (the targeted-miss case, like `git checkout
  nonexistent`): the admin named a specific lane that isn't there.
- **NEVER `pool_die`:** release prints messages + returns a code. (A misconfigured
  pool still dies loudly via the precondition helpers `pool_config_init`/
  `pool_state_init` — that is correct and inherited from the siblings.)

## D7 — STDOUT/STDERR discipline

- **stdout = the result message** (capturable, pipeable): `Released lane N.`,
  `Released N lane(s).`, `No active lanes to release.`, `Lane N has no active lease.`.
  All are single-line (`printf '…\n'`).
- **stderr = usage** (the misuse path; conventional for a usage error). stdout stays
  empty on a usage error. (The dispatcher may choose to echo `--help` to stdout
  instead — that is M7.T5.S1's call, not this function's.)
- `_pool_log` / `pool_die` never touch stdout (facts §7). `pool_release_lane` logs
  its per-lane teardown via `_pool_log` internally (file+stderr) — so the per-lane
  detail is preserved WITHOUT polluting this function's stdout summary.

## D8 — Usage message (step c, to stderr)

A compact 4-line block (the dispatcher owns the full `--help`; this is the
function-level fallback for the empty/invalid case):

```bash
printf 'Usage: agent-browser-pool release [<N>|all]\n' >&2
printf '\n' >&2
printf 'Release (tear down) one lane or all lanes.\n' >&2
printf '  release N    Release lane N (explicit teardown).\n' >&2
printf '  release all  Release all active lanes.\n' >&2
return 1
```

## D9 — DOCS (Mode A): header doc-comment + suggested `--help` one-liner

- The function's header doc-comment documents: the command's behavior (all/numeric/
  usage branches), the pinned output messages, the return-code contract, the
  pool_release_lane idempotency gotcha (why the pool_lease_exists probe is needed),
  and the set -e guards. This satisfies the item's DOCS step.
- Suggested `--help` one-liner for M7.T5.S1 to reference (NOT wired by this task):
  `release [<N>|all]   explicitly tear down one lane or all lanes`

## D10 — Delegation boundary: release is EXPLICIT, NOT reap

- release calls `pool_release_lane` DIRECTLY (the admin named the lane(s) — live OR
  stale, it is torn down). It does **NOT** route through `pool_reap_stale` (that is
  STALE-ONLY — it skips live lanes). `release 5` must tear down lane 5 even if its
  owner is alive (explicit teardown); reap would SKIP it. Keep the two paths distinct.
- In the `all` branch, release iterates `pool_lanes_list` (EVERY lane with a lease,
  regardless of liveness) and `pool_release_lane`-s each. It does NOT filter to
  stale lanes (contrast pool_reap_stale's `pool_lane_is_stale` gate).

## D11 — No flock, no confirmation prompt

- **No flock:** release is lane-local + idempotent (pool_release_lane is rc-0-always
  + `|| true` on every subprocess). A concurrent acquire's in-lock reap of the SAME
  lane is a harmless idempotent no-op. (Same verdict as pool_release_lane's own PRP.)
- **No confirmation prompt:** pool_admin_release is a LIBRARY function (no stdin
  interaction). Any `read -p` confirmation is the DISPATCHER's job (M7.T5.S1). PRD
  §2.12 lists `release` with no `[--yes]` flag → no confirmation is the current spec.
  (Like the reap PRP's stance.)
