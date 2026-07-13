# Research: Codebase facts for `pool_admin_reap()` (P1.M7.T2.S1)

> Verified by direct reads of `lib/pool.sh` (3681 lines), `PRD.md`, and the
> landed sibling `pool_admin_status` (`lib/pool.sh:3594`). Line numbers are
> 1-indexed. `set -euo pipefail` is active at `lib/pool.sh:23`.

## Summary

`pool_admin_reap()` is a **thin, user-facing wrapper** APPENDED to `lib/pool.sh`
after the landed `pool_admin_status` (current EOF = `lib/pool.sh:3681`). It takes
**no input**, calls the LANDED `pool_reap_stale` (M5.T3.S1, `lib/pool.sh:2549`),
**captures the reaped count from pool_reap_stale's stdout**, and prints a
human-friendly report: `"Reaped N stale lane(s)."` (N>0) or `"No stale lanes
found."` (N==0). It returns 0 always. The dispatcher `bin/agent-browser-pool`
(M7.T5.S1, `case reap) pool_admin_reap ;;`) is a **separate task**.

## 1. The function being wrapped — `pool_reap_stale` (the ONE dependency)

**Location**: `lib/pool.sh:2549`. Implemented by P1.M5.T3.S1. Verified LANDED.

**Exact contract** (read from its own docstring + body, `lib/pool.sh:2485-2602`):
- **INPUT**: none.
- **LOGIC**: iterates `for n in $(pool_lanes_list)`; for each lane where
  `pool_lane_is_stale "$n"` returns rc 0 (stale owner), calls
  `pool_release_lane "$n" >/dev/null` (full teardown) and increments a counter.
- **STDOUT**: writes **EXACTLY ONE line** — `printf '%s\n' "$reaped"` (the integer
  count). This is the **only** stdout write. All per-lane diagnostics go to the
  log FILE via `_pool_log` (never stdout).
- **RETURN**: `return 0` **ALWAYS** — "NON-FATAL always — never pool_die, never
  non-zero" (`lib/pool.sh:2583-2601`). Empty pool → echoes `0` + rc 0.

**CRITICAL implication for the capture**: because `pool_reap_stale` returns 0
ALWAYS, a bare capture `count="$(pool_reap_stale)"` is **SAFE under `set -e`** —
**NO `if` guard is required**. This is the KEY simplification vs the sibling
`pool_admin_status`, which must guard `pool_lease_read`/`pool_lane_is_stale`
(both can return non-zero). The only non-zero risk in `pool_admin_reap` is the
precondition (`pool_config_init`/`pool_state_init`, which `pool_die` on genuine
misconfiguration — that is their contract and is desirable).

## 2. The sibling that LANDED — `pool_admin_status` (the pattern model)

**Location**: `lib/pool.sh:3594` (closing `}` @ `lib/pool.sh:3681`). Implemented
by P1.M5.T3.S1's parallel sibling P1.M7.T1.S1. **Verified LANDED this session.**

`pool_admin_reap` mirrors `pool_admin_status`'s shape exactly:
- **Precondition** (`lib/pool.sh:3604-3606`): `pool_config_init` then
  `pool_state_init` (both rc-0-or-`pool_die` → no guard). `pool_state_init`'s
  idempotent `mkdir -p $POOL_LANES_DIR` guarantees the dir exists.
- **Locals declared up front** (`lib/pool.sh:3595-3599`): `local -a …; local …`
  — SC2155 (never `local x="$(…)"`).
- **Return 0** at the end (`lib/pool.sh:3680`).
- **Banner**: its OWN `# Admin CLI — status (P1.M7.T1.S1)` banner at
  `lib/pool.sh:3544-3546` (triple `# ===` brackets). `pool_admin_reap` gets a
  parallel banner `# Admin CLI — reap (P1.M7.T2.S1)`.

## 3. Append site + banner convention

- **Current EOF**: `lib/pool.sh:3681` (closing `}` of `pool_admin_status`). This
  task APPENDS after it.
- **Greenfield confirmed**: `grep -n 'pool_admin_reap' lib/pool.sh` → no matches.
- **Banner convention** (triple `# ===…===`, 76 `=`): identical to the sibling's
  `# Admin CLI — status (P1.M7.T1.S1)` banner. Each admin command gets its OWN
  banner (parallel-safe: each task appends a self-contained banner+function).
- **Banner for THIS task**:
  ```
  # ============================================================================
  # Admin CLI — reap (P1.M7.T2.S1)
  # ============================================================================
  ```

## 4. The stdout-discipline GOTCHA (the single highest-impact fact)

`pool_reap_stale` writes the raw integer count to ITS stdout. If `pool_admin_reap`
calls `pool_reap_stale` **without capturing**, the raw integer leaks to the user:

```
2                                      ← pool_reap_stale's stdout (LEAKED)
Reaped 2 stale lane(s).                ← pool_admin_reap's message
```

**FIX**: `pool_admin_reap` MUST capture: `count="$(pool_reap_stale)"`. Then
`pool_admin_reap`'s OWN stdout is **only** the human message (one line). This
makes the user-facing report clean and matches the item's OUTPUT contract
("User-facing reap report to stdout").

## 5. `set -e` / SC2155 / arithmetic gotchas (all live — `set -euo pipefail` @23)

- **(a) SC2155**: never `local x="$(…)"`. Declare locals FIRST, assign AFTER.
  This is `pool_admin_status`'s house rule (`lib/pool.sh:3595-3599`).
- **(b) `(( ))` as a STATEMENT** returns rc 1 when the expression is 0 → FATAL
  under `set -e`. Keep arithmetic inside `if`/`elif`, OR use the `$(( ))`
  EXPANSION form (always safe). For the `count==0` comparison, use
  `if (( count == 0 )); then …` (inside `if` → errexit-exempt) OR the string
  comparison `[[ "$count" == "0" ]]` (no arithmetic at all — simplest, safest).
- **(c) Capture guard**: `pool_reap_stale` returns 0 ALWAYS (§1) → a bare
  `count="$(pool_reap_stale)"` is SAFE — **no guard**. (Contrast the sibling,
  which guards `pool_lease_read`/`pool_lane_is_stale`.) This is the ONE place
  `pool_admin_reap` is SIMPLER than `pool_admin_status`.

## 6. `pool_config_init` / `pool_state_init` precondition (mirrors the sibling)

- `pool_config_init` (`lib/pool.sh:~115`): freezes globals (`POOL_LANES_DIR`,
  `POOL_REAL_BIN`, etc.). Can `pool_die` on genuine misconfiguration (unset
  `$HOME`, bad port range, etc.) — that is correct, desired behavior (a
  misconfigured pool must fail loudly, not silently print "No stale lanes
  found.").
- `pool_state_init` (`lib/pool.sh:~198`): idempotent `mkdir -p $POOL_LANES_DIR`
  + touch the lock file. Can `pool_die` on a real FS failure.
- Both are rc-0-or-`pool_die` → **no `if` guard** needed (matches the sibling
  `pool_admin_status` and `pool_wrapper_main` step "a").

## 7. DOCS / `--help` boundary (Mode A)

The item's "DOCS: [Mode A] --help output for 'reap' subcommand" is satisfied at
the **lib level** by a thorough header doc-comment documenting the reap command's
behavior + output. The actual `--help` subcommand WIRING (parsing `--help`,
echoing the usage text) is **M7.T5.S1** (the dispatcher binary). This task
provides the documented function the dispatcher will call by name, plus a
suggested `--help` text block (see PRP) that the future dispatcher may reference.

## 8. `pool_release_lane` close behavior (test-feasibility for the N>0 case)

`pool_release_lane` (`lib/pool.sh:2438`) runs
`"$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true`. Per the
M5.T2.S1 research: "rc is ALWAYS 0 on agent-browser 0.28.0 (fresh/live/dead/
repeated)". So `close` is **fast and non-fatal even on a missing daemon**. This
means the N>0 integration test CAN use a **synthetic stale lease** (dead owner
pid, nonexistent chrome_pid, nonexistent ephemeral_dir) — `pool_release_lane`
will: read lease → run close (fast, rc 0) → kill nonexistent pid (`|| true`) →
rm nonexistent dir (`|| true`) → rm the lease file. All non-fatal. No real Chrome
needed. (This is how the N>0 case is tested without booting Chrome.)

## 9. Boundary vs siblings (do NOT duplicate)

- **M5.T3.S1** owns `pool_reap_stale` — DO NOT re-implement the reap loop. CALL it.
- **M7.T1.S1** (LANDED) owns `pool_admin_status` — DO NOT modify it.
- **M7.T3.S1** owns `release` (`pool_admin_release`, Planned) — separate.
- **M7.T4.S1** owns `doctor` (Planned) — separate.
- **M7.T5.S1** owns the dispatcher `bin/agent-browser-pool` + `--help` wiring —
  separate. This task is **lib-only**.
