# Design Decisions — `pool_admin_status()` (P1.M7.T1.S1)

Synthesis of codebase-facts + external-formatting research into the concrete
decisions the PRP pins. This is the authoritative pre-implementation spec for
the three open design choices (format string, STATE precedence, field extraction).

## D1 — This is a LIB-ONLY, append-only task

- `pool_admin_status()` is **APPENDED** to `lib/pool.sh` after `pool_wrapper_main`
  (the current EOF, `lib/pool.sh:3541`), under a NEW banner:
  ```
  # =============================================================================
  # Admin CLI — status (P1.M7.T1.S1)
  # =============================================================================
  ```
- It is consumed later by the **dispatcher** `bin/agent-browser-pool`
  (P1.M7.T5.S1, `case "$cmd" in status) pool_admin_status ;; …`). That binary
  does NOT exist yet and is OUT OF SCOPE for this task.
- Greenfield confirmed: `grep -n 'pool_admin' lib/pool.sh` → no matches.
- No existing function is modified; no new files; no new env-vars/globals.

## D2 — Precondition: `pool_config_init` + `pool_state_init` at the top

Mirrors `pool_wrapper_main` step "a" (`lib/pool.sh:3455-3459`). Both are
rc-0-or-`pool_die` → NO guard needed under `set -e`. `pool_state_init` is what
guarantees `$POOL_LANES_DIR` exists (idempotent `mkdir -p`), so a fresh pool's
first `status` just works.

## D3 — Field extraction: ONE `pool_lease_read` + ONE `jq` fork per lane (mapfile)

Follows the `pool_lane_is_stale` pattern (`lib/pool.sh:1175-1178`: read once,
`mapfile -t < <(jq -r '.a, .b, .c' <<<"$json")`). Cheaper than 7×
`pool_lease_field` (7 jq forks/lane). Capture is guarded:

```bash
if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
    # missing OR corrupt (TOCTOU between lanes_list and now): degraded row, continue
    <print a row with "?" fields + state STALE>; continue
fi
mapfile -t fields < <(jq -r '.port, .session, .owner.pid, .owner.cwd, .chrome_pid, .acquired_at, .connected' <<<"$json")
```

The `2>/dev/null` mirrors `pool_lane_is_stale`'s own capture (`lib/pool.sh:1170`);
the corrupt-lease WARNING is still logged by `pool_lease_read` (to file+stderr,
not stdout), so diagnostics are preserved while stdout stays clean.

## D4 — Column format string (PINNED)

`printf` fixed-width spaces (NOT tabs; NOT `column`). Widths chosen so both the
HEADER label AND typical data fit without overflow; the two variable-width
columns use `%-N.Ns` precision to TRUNCATE (research §2: bare `%-Ns` does NOT
truncate → would shove the next column).

| column      | width | align | truncate | why |
|-------------|-------|-------|----------|-----|
| LANE        | 4     | right | —        | ≤4 digits (range 1000) |
| PORT        | 6     | right | —        | 5-digit ports (53420+) |
| SESSION     | 16    | left  | yes .16  | `abpool-N` fits; long UUIDs truncated |
| OWNER_PID   | 10    | right | —        | "OWNER_PID" label=9; pids ≤7 digits |
| OWNER_CWD   | 24    | left  | yes .24  | long absolute paths truncated |
| CHROME_PID  | 10    | right | —        | "CHROME_PID" label=10 (exact fit) |
| AGE         | 5     | right | —        | "Nd"/"Nh"/"Nm" ≤3 chars |
| STATE       | 12    | left  | —        | "disconnected"=12 (exact fit) |

**Format string (shared by header + every row):**
```bash
local fmt='%4s %6s %-16.16s %10s %-24.24s %9s %5s %-12s\n'
```
Wait — CHROME_PID label is 10; recompute: `%10s` for both OWNER_PID and CHROME_PID.
(Both labels ≤10, both data ≤7 digits → 10 is safe + aligned.)

**Final (corrected) format string:**
```bash
local fmt='%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n'
```
Header args: `LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`.
Total content width: 4+6+16+10+24+10+5+12 = 87 + 7 separators = 94 cols (fits 100-col).

## D5 — STATE precedence (PINNED): STALE > disconnected > live

`pool_lane_is_stale` is TRI-STATE (`lib/pool.sh:1118-1126`): rc **0=STALE**,
rc **1=LIVE**, rc **2=NO-LEASE**. Precedence by admin-actionability:

1. rc 0 → **`STALE`** (owner dead → lane is a leak → admin reaps; highest priority)
2. else rc 1 (live) OR rc 2 (unreadable/TOCTOU): neither is stale → state then
   depends on daemon connectivity from the lease:
   - `connected == "false"` → **`disconnected`** (Chrome daemon not connected)
   - else → **`live`**

This collapses rc-1 and rc-2 into the same connected-based branch (robust to the
TOCTOU case where `pool_lease_read` succeeded for the row but `pool_lane_is_stale`
then reads rc 2). It satisfies the item contract verbatim — 'live' if rc 1,
'STALE' if rc 0, 'disconnected' if connected false — with a defensible precedence.

```bash
if pool_lane_is_stale "$lane"; then
    state="STALE"          # rc 0 — owner dead/recycled
else
    # rc 1 (live) OR rc 2 (unreadable/TOCTOU): not stale → decide by connectivity
    if [[ "$connected" == "false" ]]; then
        state="disconnected"
    else
        state="live"
    fi
fi
```
(The `if pool_lane_is_stale …; then … else … fi` guard is MANDATORY — a bare
call with rc 1/2 ABORTS under `set -e`; see codebase-facts §5c.)

## D6 — AGE computation

`age="$(_pool_age_str "$acquired_at")"` — `_pool_age_str` is rc 0 ALWAYS
(`lib/pool.sh:369`, clamps negative→"0s"). BUT guard `acquired_at` is numeric
first: a missing field → `jq` echoes `null` → `$(( now - null ))` is an
arithmetic error under `set -e`. Schema guarantees `acquired_at` is a number
(`pool_lease_write` `--argjson`), so this is purely defensive:

```bash
if [[ "$acquired_at" =~ ^[0-9]+$ ]]; then
    age="$(_pool_age_str "$acquired_at")"
else
    age="?"
fi
```

## D7 — Empty pool

```bash
mapfile -t lanes < <(pool_lanes_list)
if (( ${#lanes[@]} == 0 )); then
    printf 'No active lanes.\n'
    return 0
fi
```
`(( ${#lanes[@]} == 0 ))` is inside `if` → errexit-exempt (the `(( ))`-returns-1
gotcha does not apply inside a condition).

## D8 — STDOUT discipline

The table (or "No active lanes.") is the function's ONLY stdout. All diagnostics
flow through `_pool_log` (file+stderr) / `pool_die` (stderr). This makes
`agent-browser-pool status` safely pipeable (e.g. `status | grep STALE`).

## D9 — DOCS step (column documentation lives in THIS function's header)

The item's "DOCS: --help should describe output columns" is satisfied here by a
thorough header doc-comment enumerating every column + the STATE values. The
actual `--help` subcommand wiring is M7.T5.S1 (the dispatcher), which will
reference/echo this documentation. This task does NOT build `--help`.
