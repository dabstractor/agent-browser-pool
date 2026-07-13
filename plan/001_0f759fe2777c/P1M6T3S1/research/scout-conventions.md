# Code Context: pool_wrapper_main() (P1.M6.T3.S1) Conventions

Scout of `lib/pool.sh` (3391 lines) and `bin/` for the new `pool_wrapper_main()`
function and the (T3.S2) `bin/agent-browser` shim. All line numbers are 1-indexed
and verified against the current file.

## Files Retrieved

1. `lib/pool.sh` (lines 1-18) — shebang, shellcheck directive, banner-comment header, `set -euo pipefail`.
2. `lib/pool.sh` (lines 24-57) — `_pool_log_path`, `pool_die`, `_pool_log` definitions.
3. `lib/pool.sh` (lines 88-179) — config table + `pool_config_init` body (where `POOL_REAL_BIN` and `POOL_DISABLE` are frozen).
4. `lib/pool.sh` (lines 2043-2084) — `pool_acquire_locked` (flock wrapper).
5. `lib/pool.sh` (lines 2185-2240) — `pool_boot_lane` entry + outcome logging.
6. `lib/pool.sh` (lines 2288-2385) — `pool_ensure_connected` entry + outcome logging.
7. `lib/pool.sh` (lines 2909-2971) — `pool_wait_for_lane` entry + outcome logging.
8. `lib/pool.sh` (lines 2973-3391) — the entire M6.T1/T2 wrapper-shim section (`pool_dispatch_classify`, `pool_normalize_close/connect`, `pool_strip_session_args`, `pool_force_session`). **`pool_wrapper_main` is appended after `pool_force_session` (ends ~line 3390).**
9. `bin/` — contains ONLY `.gitkeep` (0 bytes). No `bin/agent-browser` yet.
10. `plan/001_0f759fe2777c/tasks.json` — T3.S1 / T3.S2 contract definitions (boundary).

---

## 1. `_pool_log()` — @39

**Signature:** `_pool_log MSG...` (variadic).

```bash
# lib/pool.sh:39-57
_pool_log() {
    local msg ts log_path log_dir
    msg="${*:-}"
    # -1 == current time; ISO-8601 with numeric timezone, e.g. 2026-07-12T18:49:04-0400.
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    log_path="$(_pool_log_path)"
    log_dir="${log_path%/*}"
    if [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null; then
        printf '%s %s\n' "$ts" "$msg" >>"$log_path" || printf '%s %s\n' "$ts" "$msg" >&2
    else
        printf '%s %s\n' "$ts" "$msg" >&2
    fi
}
```

- **How called:** Multi-arg — all args are joined into ONE line via `${*:-}` (the first
  positional joins with `$IFS`, which is space by default). Callers pass a SINGLE quoted
  string, or multiple args that get space-joined. Example of multi-arg join:
  ```bash
  # lib/pool.sh:521-523
  _pool_log "pool_owner_resolve: TEST MODE owner pid=$POOL_OWNER_PID" \
            "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"
  ```
  → writes one line: `<ts> pool_owner_resolve: TEST MODE owner pid=... comm=... starttime=...`.
- **Output dest:** BOTH the pool log file (default `$AGENT_BROWSER_POOL_STATE/pool.log`,
  overridable via `POOL_LOG_PATH`) AND stderr. Uses builtin `printf '%(...)T'` — **no `date`
  fork**. Writes `"${ts} ${msg}\n"` (timestamp + space + msg). If the file is unwritable,
  the line still goes to stderr.
- **Conventions for new code:** Log on meaningful state transitions/outcomes, NOT a generic
  "function entered" line. Prefix the message with the function name + colon. Keep happy-path
  logging minimal (see `pool_state_init` which logs nothing on success).

## 2. `pool_die()` — @30

**Signature:** `pool_die MSG...` (variadic). **Exit code: 1 (always).**

```bash
# lib/pool.sh:28-33
# pool_die MSG...
#   Print MSG to stderr and exit non-zero. The canonical error-exit helper.
pool_die() {
    printf '%s\n' "$*" >&2
    exit 1
}
```

- Prints `"$*"` (all args space-joined) to **stderr only** (no log file), then `exit 1`.
- Multi-arg usage example (line 257-262): `pool_die "pool_check_btrfs: ..." "..." "..."`.
- **No `_pool_log`** — error text is stderr-only. `pool_wrapper_main` should use `pool_die`
  for fatal conditions OR `exec` straight through (see passthrough below).

## 3. Lines 1-20 — strict mode & header

```bash
# lib/pool.sh:1-18
#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/pool.sh — shared library for the agent-browser-pool project.
#
# Sourced by:
#   - bin/agent-browser       (the transparent PATH-shadowing wrapper shim)
#   - bin/agent-browser-pool  (the admin CLI: status / reap / release / doctor)
#
# This file is meant to be SOURCED (`. lib/pool.sh` or `source lib/pool.sh`),
# NOT executed directly. It defines foundational utilities only.
#
# Requires: bash >= 4.2 (uses the printf '%(fmt)T' builtin). Hosts run bash 5.x.
# Strict mode: `set -euo pipefail` below propagates into every caller's shell by design.
#
# TODO(later subtasks): owner resolution, acquire/release, reap, copy, Chrome launch.
#                       This file currently provides ONLY the skeleton + die/log utilities.
set -euo pipefail
```

- **Strict mode:** `set -euo pipefail` at **line 18**. This propagates into every caller's
  shell (bin/agent-browser, bin/agent-browser-pool) because the file is sourced.
- **Shebang:** `#!/usr/bin/env bash` (line 1) + `# shellcheck shell=bash` (line 2).
- **Header style:** `# ` comment lines, an em-dash title `lib/pool.sh — shared library ...`,
  a "Sourced by:" list, a "Requires:" note, and the strict-mode note. Top-of-file comment
  block; the header is NOT wrapped in `=====` separators (only section headers within the body are).

## 4. Banner / section-header formatting

Section headers within the body use **`# ` followed by a run of `=`** to a total line width
of **79 characters** (`# ` + 77 `=`). They wrap a single title line:

```bash
# lib/pool.sh:3263-3267  (verbatim, M6.T2.S1 section header)
# =============================================================================
# Wrapper shim — session override (P1.M6.T2.S1)
# =============================================================================
# PRD §2.4 step 5 / §2.15 transparency. Neutralize an agent's attempt to bypass its
```

Other examples (all identical width): lines 388-390, 577-579, 933-935, 1055-1057, 1418-1420,
1592-1594, 2057-2059, 2240-2242, 2973-2975, 3088-3090. The pattern is:
```
# =============================================================================
# <Title> — <Milestone.Task.Subtask>
# =============================================================================
# <optional prose explanation paragraph(s)>
```
The new `pool_wrapper_main` should open with a `# ===` banner reading
`# Wrapper shim — complete lifecycle (P1.M6.T3.S1)` followed by a prose explanation block,
then the contract comment, then the function definition. (Every other function in the file
follows this: banner → prose → `# GOTCHA — ...` notes → `# PRECONDITION:` → `funcname() {`.)

**Minor separators** (sub-section grouping) are NOT used between sibling functions; each
function gets its own full `===` banner. So `pool_wrapper_main` gets its own banner after
`pool_force_session`.

## 5. `exec` / `main` / main-guard — search results

- **NO actual `exec` command exists anywhere in `lib/pool.sh`.** All matches are in COMMENTS:
  lines 1452, 1462, 1738, 1673, 2275, 2977, 3112, 3199, 3200, 3270, 3311, 3356, 3364, 3370, 3388.
  The most relevant forward-reference (in `pool_force_session`'s comment):
  ```bash
  # lib/pool.sh:3356  (comment)
  # later `exec "$POOL_REAL_BIN" …` (M6.T3.S1) inherits it.
  ```
- **NO `main` function and NO main-guard pattern exists.** Confirmed: zero matches for
  `main()`, `BASH_SOURCE`-guard, `${0##*/}`, `main "$@"`. The file is sourced-only by design
  (header lines 9-10). **`pool_wrapper_main()` is brand-new** — there is no existing entry
  point to mimic except the contract in tasks.json (see §9).
- `grep -rn 'pool_wrapper_main' lib/ bin/` → **NO references anywhere.** It is introduced by this task.

> Implication: T3.S1 adds `pool_wrapper_main()` as the FIRST `exec`-containing function. The
> execs are the three passthrough/terminal points (POOL_DISABLE, meta, no-pi-ancestor) and the
> final driving exec — see the contract in §9. Because `set -e` is active, every command
> substitution of a returning-1 helper MUST be guarded (`if N="$(pool_lease_find_mine)"`, etc.).

## 6. `POOL_REAL_BIN` references

- **Set at line 147** in `pool_config_init`, from env `AGENT_BROWSER_REAL` (default
  `$HOME/.local/bin/agent-browser`), canonicalized via `_pool_config_canon_path`:
  ```bash
  # lib/pool.sh:141-147
  real_bin="$(_pool_config_canon_path \
      "${AGENT_BROWSER_REAL:-$POOL_HOME_DIR/.local/bin/agent-browser}")"
  ...
  POOL_REAL_BIN="$real_bin"; declare -g POOL_REAL_BIN
  ```
  Listed in the config table at line 98: `AGENT_BROWSER_REAL ... POOL_REAL_BIN path (may not exist)`.
- **Used to invoke the real binary** (the only existing `$POOL_REAL_BIN ...` invocations):
  - `pool_daemon_connect` @1645: `"$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1 || return 1`
  - `pool_daemon_connected` @1703: `"$POOL_REAL_BIN" --session "$session" --json session list 2>/dev/null ...`
  - `pool_release_lane` @2468: `"$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true`
- **NO existing `exec "$POOL_REAL_BIN"` passthrough** — those subprocess invocations are all
  non-exec foreground/background calls. **`pool_wrapper_main` is the FIRST place `exec` is
  used.** The expected terminal execs (from the contract):
  - `exec "$POOL_REAL_BIN" "$@"` (POOL_DISABLE==1 passthrough, and meta-classified, and
    no-pi-ancestor human-terminal cases)
  - `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (final driving exec, after normalize +
    strip + force session).
  - `pool_force_session` (line 3366/3388) exports `AGENT_BROWSER_SESSION=abpool-<lane>` into
    the calling shell precisely so the `exec` inherits it.
- `POOL_DISABLE` (the passthrough flag) is set @176 from `AGENT_BROWSER_POOL_DISABLE`; bool
  "1" ⇒ passthrough. Config table @104: `AGENT_BROWSER_POOL_DISABLE ... POOL_DISABLE bool (1=passthrough)`.

## 7. Lifecycle-function entry logging style

**All four log with a `<funcname>: <description>` prefix, on OUTCOMES, not a generic "entered" line.**

- **`pool_acquire_locked()` @2043-2084** — NO entry log. It is the flock wrapper
  (`pool_state_init` then `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`).
  The critical section logs under `pool_acquire(reap|adopt|claim):` prefixes (lines 1856, 1936, 2008).
- **`pool_boot_lane()` @2185** — logs on outcomes only:
  - @2236 success: `_pool_log "pool_boot_lane: lane $lane provisioned (port=$port pid=${POOL_CHROME_PID:-0})"`
  - @2203/2215/2224 failures: `pool_boot_lane: port range exhausted ... / CDP not ready ... / daemon connect failed ...`
- **`pool_ensure_connected()` @2288** — logs on outcomes:
  - @2295 bad lane: `_pool_log "pool_ensure_connected: bad lane '$lane'"`
  - @2301/2314/2332/2335/2364/2374/2383 — no-lease, reconnect-ok/failed, relaunch-timeout/failed/ok.
- **`pool_wait_for_lane()` @2909** — NO entry log. Logs only @2957 force-reap and @2969
  exhaustion: `_pool_log "pool_wait: force-reaped stale lane ..."` /
  `_pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"`.
  (Note the prefix is `pool_wait:`, slightly shorter than the function name.)

**Style for `pool_wrapper_main`:** follow the same `<funcname>: <desc>` convention. A single
entry log line naming the classification + owner resolution is consistent with `pool_owner_resolve`
(which logs exactly one line per call, @521/567/573). Recommended prefix: `pool_wrapper_main:`.

## 8. `bin/` directory contents

```
$ ls -la bin/
-rw-r--r-- 1 dustin dustin 0 Jul 12 18:53 .gitkeep
```

- **`bin/` contains ONLY `.gitkeep` (0 bytes).** No `bin/agent-browser`, no `bin/agent-browser-pool`.
- **`bin/agent-browser` is NOT created in T3.S1.** Per the tasks.json contracts (§9):
  - **T3.S1** (this task, status "Researching") implements ONLY `pool_wrapper_main()` in
    `lib/pool.sh`. Output: "The wrapper fully routes the agent's command to its ephemeral
    lane. No return (exec replaces the process)."
  - **T3.S2** (status "Planned", **depends on T3.S1**) creates `bin/agent-browser`.

## 9. P1.M6.T3.S2 PRP — does NOT exist; boundary from tasks.json

- **`plan/001_0f759fe2777c/P1M6T3S2/` does NOT exist** (confirmed: `ls` → "No such file or
  directory"). Only `P1M6T3S1/` exists. So there is no T3.S2 PRP doc to read; the boundary is
  defined in `plan/001_0f759fe2777c/tasks.json`.

**T3.S1 contract (verbatim from tasks.json `context_scope`):**
```
3. LOGIC: Implement `pool_wrapper_main()`:
   a. Call pool_config_init + pool_state_init.
   b. If POOL_DISABLE==1 → exec $POOL_REAL_BIN "$@" (passthrough, no pooling).
   c. Classify: if pool_dispatch_classify returns 'meta' → exec $POOL_REAL_BIN "$@" unchanged.
   d. Resolve owner: pool_owner_resolve. If POOL_OWNER_PID==0 (no pi ancestor) → exec real
      binary unchanged (human in terminal).
   e. Find my lease: pool_lease_find_mine. If found → go to step h.
   f. Not found → acquire: pool_acquire_locked. If no free lane → pool_wait_for_lane.
   g. Post-lock boot: pool_boot_lane(lane).
   h. Ensure connected: pool_ensure_connected(lane).
   i. Normalize args: pool_normalize_close/connect.
   j. Strip session args + force session: pool_strip_session_args, pool_force_session.
   k. EXEC: exec $POOL_REAL_BIN <normalized args>. The agent's command runs against its lane.
4. OUTPUT: The wrapper fully routes the agent's command to its ephemeral lane. No return
   (exec replaces the process).
5. DOCS: [Mode A] Add a header comment in bin/agent-browser documenting the dispatch flow...
```

> Note: T3.S1's DOCS step says "header comment in bin/agent-browser," but that file is created
> in T3.S2. Since T3.S1 is lib-only, the doc header lives as the `# ===` banner + contract
> comment above `pool_wrapper_main()` in lib/pool.sh (matching every other function's pattern).

**T3.S2 contract (verbatim):** Creates `bin/agent-browser`:
```bash
#!/usr/bin/env bash
set -euo pipefail
# Resolve real script dir (handles symlinks)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"
```
(chmod +x). T3.S2 depends on T3.S1 — it cannot exist until `pool_wrapper_main()` exists.

## 10. P1.M6.T3.S1 PRP dir contents

```
$ ls -la plan/001_0f759fe2777c/P1M6T3S1/
drwxr-xr-x ... research/    (empty — this scout output is the first artifact)
```

- **`P1M6T3S1/` contains ONLY an empty `research/` subdirectory.** No PRP file, no prior
  research, no implementation. (The task is still in status "Researching".) This scout report
  is the first artifact placed in it.

---

## Key Code (the exact pieces pool_wrapper_main must compose)

All of these already exist and are called by `pool_wrapper_main` in order:

| Step | Call | File:line | Returns | Notes |
|------|------|-----------|---------|-------|
| a | `pool_config_init` | 126 | 0 / pool_die | freezes POOL_DISABLE, POOL_REAL_BIN, etc. |
| a | `pool_state_init` | 202 | 0 / pool_die | idempotent mkdir |
| b | `[[ "$POOL_DISABLE" == "1" ]]` | — | bool | → `exec "$POOL_REAL_BIN" "$@"` |
| c | `pool_dispatch_classify "$@"` | 3030 | 0 always; echoes `meta`/`driving` | no guard needed |
| d | `pool_owner_resolve` | 478 | 0 always | sets POOL_OWNER_PID; `==0` ⇒ human ⇒ exec passthrough |
| e | `pool_lease_find_mine` | 1003 | 0/1; echoes lane N | **MUST guard**: `if N="$(...)"` (rc 1 aborts under set -e) |
| f | `pool_acquire_locked` | 2043 | echoes N / nonzero | **MUST guard**; fallback `pool_wait_for_lane` |
| f | `pool_wait_for_lane` | 2909 | echoes N / pool_die @2969 | pool_die on exhaustion |
| g | `pool_boot_lane "$N"` | 2185 | 0/1 | rc 1 ⇒ lane dropped; needs handling |
| h | `pool_ensure_connected "$N"` | 2288 | 0/1 | rc 1 ⇒ reconnect/relaunch failed |
| i | `pool_normalize_close "$@"` then `pool_normalize_connect` | 3139 / 3210 | 0 always | sets global `POOL_NORM_ARGS[]` |
| j | `pool_strip_session_args "${POOL_NORM_ARGS[@]}"` | 3314 | 0 always | sets global `POOL_CLEAN_ARGS[]` |
| j | `pool_force_session "$N"` | 3380 | 0/1 | exports `AGENT_BROWSER_SESSION=abpool-<N>` |
| k | `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` | — | (never returns) | the ONLY exec in the lib |

**Critical set -e gotchas (from comments at lines 362-365, 995-997):**
- `pool_lease_find_mine` returns 1 on no-match → a bare `N="$(pool_lease_find_mine)"` ABORTS.
  Use `if N="$(pool_lease_find_mine)"; then ...`.
- `pool_acquire_locked` returns nonzero when no lane → guard with `if N="$(pool_acquire_locked)"; then ...`.
- `pool_dispatch_classify` / `pool_normalize_*` / `pool_strip_session_args` return 0 ALWAYS → no guard needed.
- `pool_force_session` returns 1 on bad lane → guard or rely on already-validated `$N`.
- Index counters must use `i=$((i+1))`, never bare `(( i++ ))` (returns rc 1 when 0).

## Architecture

`lib/pool.sh` is a **sourced library** (header lines 9-10). `bin/agent-browser` (T3.S2) and
`bin/agent-browser-pool` (M7) are thin shims that `source "$REAL_DIR/../lib/pool.sh"` and call
into it. `pool_wrapper_main()` is the orchestration entry point that T3.S2's shim invokes with
`pool_wrapper_main "$@"`. It composes the M6.T1 (dispatch + normalize) and M6.T2 (strip/force
session) argv transforms with the M2 (owner resolve), M3 (lease find), M5 (acquire/boot/
ensure) lifecycle layers, terminating in a single `exec "$POOL_REAL_BIN"` that replaces the
process (so there is no return). The three early `exec` passthroughs (POOL_DISABLE, meta,
no-pi-ancestor) make the wrapper fully transparent for non-driving / human-terminal invocations.

## Start Here

**Open `lib/pool.sh` at line 3380** (`pool_force_session`, the last function). `pool_wrapper_main`
is appended immediately after it (file currently ends at line 3391). Read the contract in
`tasks.json` node `P1.M6.T3.S1` (quoted in §9 above) — it is the authoritative step list (a–k).
Then model the banner/comment style on the M6.T2.S1 header at lines 3263-3271 and the
`pool_owner_resolve` entry-log style at lines 478/567-573.

## Open Questions / Risks

- **No prior `exec` precedent in the lib** to copy. The three passthrough execs + the final
  driving exec are the FIRST execs. Validate the exact quoting: `exec "$POOL_REAL_BIN" "$@"`
  (passthrough) vs `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (driving). Confirm
  `POOL_CLEAN_ARGS` is populated by chaining `pool_normalize_close` → `pool_normalize_connect`
  → `pool_strip_session_args` (each REPLACES the global it writes).
- **Order of normalize calls:** `pool_normalize_close` and `pool_normalize_connect` both write
  `POOL_NORM_ARGS` (the second reads `$@` per its contract, NOT the first's output). The
  wrapper must thread the array correctly — verify whether to call them sequentially on
  `${POOL_NORM_ARGS[@]}` or whether each independently takes original `$@`. (Their comments
  say "Reads only `$@`", decoupled — but the pipeline `POOL_NORM_ARGS → strip → POOL_CLEAN_ARGS`
  at line 3356 implies strip consumes POOL_NORM_ARGS. Confirm at implementation time.)
- **Failure handling for `pool_boot_lane`/`pool_ensure_connected` rc 1** is not spelled out in
  the contract steps g/h beyond "call them." Decide: pool_die vs retry vs fall back to a raw
  passthrough exec. The contract's OUTPUT says only the happy path.
