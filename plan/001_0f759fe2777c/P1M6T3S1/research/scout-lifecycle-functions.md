# Scout: Lifecycle Functions for `pool_wrapper_main()` (P1.M6.T3.S1)

Source: `/home/dustin/projects/agent-browser-pool/lib/pool.sh` (3389 lines).
`pool_wrapper_main()` does NOT exist yet — grep for `pool_wrapper_main` returns nothing. T3.S1 must create it and wire these functions together. POOL_REAL_BIN (real binary path) is the exec target, frozen by `pool_config_init` at line 147.

## ⚠️ CRITICAL CORRECTION to the task brief

The brief assumes several lane globals exist. **They do NOT.** Verified by grep:

| Brief-claimed global | Reality |
|---|---|
| `POOL_FOUND_LANE` (from `pool_lease_find_mine`) | **Does not exist.** Lane returned via **stdout** (`printf '%s\n' "$n"`). |
| `POOL_ACQUIRED_LANE` (from `pool_acquire_locked`) | **Does not exist.** Lane returned via **stdout** (flock subshell `printf '%s\n' "$N"`). |
| `POOL_ACQUIRED_LANE` (from `pool_wait_for_lane`) | **Does not exist.** Lane returned via **stdout** (`printf '%s\n' "$N"`). |

`grep -n 'POOL_FOUND_LANE\|POOL_ACQUIRED_LANE' lib/pool.sh` → **No matches.**

⇒ `pool_wrapper_main()` MUST capture the lane via **command substitution** (`N="$(pool_lease_find_mine)"`), NEVER by reading a global. Per the docstring GOTCHAs, the capture must be **split** (`local N; N="$(...)"`, NOT `local N="$(...)"`) so errexit is not masked (BashFAQ 105). Every one of these three functions returns 1 on "no lane" and is set -e-unsafe under a bare capture ⇒ ALL THREE require an `if` guard.

---

## Per-function integration contract

### 1. `pool_dispatch_classify` (line 3030–3074)

- **Signature:** `pool_dispatch_classify [--] ARGS...` — reads `$@`, no positional arg by name.
- **Return code:** **0 ALWAYS.** No failure mode ⇒ no `if` guard needed.
- **stdout:** EXACTLY one token: `meta` or `driving` (each via `printf 'meta\n'`/`printf 'driving\n'`). This is the SOLE output channel.
- **Globals read:** NONE (pure — callable BEFORE `pool_config_init`/`pool_owner_resolve`).
- **Globals set:** NONE.
- **Classification rules:** `--help`/`-h`/`--version` → meta; `session list` (two-word) → meta; cmd ∈ {skills,dashboard,plugin,mcp} → meta; everything else (DRIVING set + unrecognized) → driving; flags-only/empty → driving.
- **Caller pattern:** `class="$(pool_dispatch_classify "$@")"` (no guard needed). This is PRD §2.4 **step 0** — the VERY FIRST step, before owner resolution.

### 2. `pool_normalize_close` (line 3139–3176) + `pool_normalize_connect` (line 3210–3262)

Both read ONLY `$@` (no config globals) ⇒ callable after a bare `source lib/pool.sh`.

**`pool_normalize_close`:**
- **Signature:** `pool_normalize_close [--] ARGS...`
- **Return code:** **0 ALWAYS.** No failure mode ⇒ no `if` guard.
- **stdout:** EMPTY.
- **Globals set:**
  - `POOL_NORM_ARGS` — **global ARRAY**, set via `declare -ga POOL_NORM_ARGS=( "${out[@]}" )` at **line 3171**. The normalized argv (every `--all` stripped iff cmd==`close`; otherwise unchanged).
  - `POOL_CLOSE_ALL_SEEN` — **scalar**, assigned `POOL_CLOSE_ALL_SEEN=$seen_all` (line 3172) then `declare -g POOL_CLOSE_ALL_SEEN` (line 3173). Value: `1` iff ≥1 `--all` stripped from a `close` cmd, else `0`.
- **Effect:** strips every standalone `--all` from a `close` command (prevents nuking ALL daemon sessions); preserves all other tokens including `--session`.

**`pool_normalize_connect`:**
- **Signature:** `pool_normalize_connect [--] ARGS...`
- **Return code:** **0 ALWAYS.** No failure mode ⇒ no `if` guard.
- **stdout:** EMPTY.
- **Globals set:** `POOL_NORM_ARGS` only — **global ARRAY** via `declare -ga` at **line 3230** (non-connect, unchanged) and **line 3259** (connect, positional stripped).
- **Effect:** if cmd==`connect`, strips the SINGLE `<port|url>` positional after the command (real connection owned by `pool_ensure_connected`). Does NOT touch `POOL_CLOSE_ALL_SEEN`. Note GOTCHA: after strip a bare `connect` results — M6.T3.S1 must NOT naively exec it (would error); pool_ensure_connected already binds the lane.
- **Both functions OVERWRITE `POOL_NORM_ARGS` each call** (atomic `declare -ga …=( ... )` REPLACES — no stale elements; empty ⇒ `POOL_NORM_ARGS=()` with 0 elements).

### 3. `pool_owner_resolve` (line 478–597)

- **Signature:** `pool_owner_resolve` (no args). Reads env test-hooks `AGENT_BROWSER_POOL_OWNER_PID` / `AGENT_BROWSER_POOL_OWNER_STARTTIME`.
- **Return code:** **0 ALWAYS.** NEVER fatal (never `pool_die`). Re-runnable (globals reset to defaults every call).
- **stdout:** EMPTY (logs via `_pool_log`, not stdout).
- **Globals set** — all reset at top (lines 495–496: `POOL_OWNER_PID="0"; POOL_OWNER_COMM=""; POOL_OWNER_STARTTIME=""; POOL_OWNER_CWD=""; declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD`), then populated:
  - `POOL_OWNER_PID` (scalar, `declare -g` lines 496/505/555) — the owner pi PID.
  - `POOL_OWNER_COMM` (scalar, `declare -g` lines 496/507/556) — `"pi"` if found.
  - `POOL_OWNER_STARTTIME` (scalar, `declare -g` lines 496/...) — owner starttime, may stay `""` if unreadable.
  - `POOL_OWNER_CWD` (scalar, `declare -g` line 496) — owner cwd, may stay `""`.
- **When `POOL_OWNER_PID=="0"`:** **passthrough mode** — no `pi` ancestor found in the ppid walk (steps 2→3 fall through to the "no pi ancestor" log). Also the explicit reset default. ⚠️ **`_pool_acquire_critical_section` (line 1971) and adopt (line 2706) REFUSE to claim/adopt a lane when `POOL_OWNER_PID=="0"`** (return 1) — a passthrough owner must not claim. ⇒ `pool_wrapper_main()` MUST gate the passthrough owner BEFORE acquire and (per PRD §2.4 step 1) likely exec the real binary unchanged.
- **Globals read:** NONE (reads env + /proc only).

### 4. `pool_lease_find_mine` (line 1003–1021)

- **Signature:** `pool_lease_find_mine` (no args).
- **Return code:** **0 on found (mine + live owner), 1 on not found / no resolved owner.** Non-fatal (never `pool_die`).
- **stdout:** **the lane N** via `printf '%s\n' "$n"` on match (line 1017); EMPTY on no match.
- **Globals set:** **NONE.** (NOT `POOL_FOUND_LANE` — does not exist.) Lane is stdout-only.
- **Globals read:** `POOL_OWNER_PID` (must be numeric; else `return 1` immediately). Requires `pool_config_init` + `pool_owner_resolve`.
- **Caller pattern (under set -e — MUST guard):**
  ```sh
  local N
  if N="$(pool_lease_find_mine)"; then
      <reuse existing live lane N; go to ensure_connected step>
  else
      <no existing lane → acquire a new one>
  fi
  ```
  Bare capture `N="$(pool_lease_find_mine)"` would ABORT under set -e on the rc-1 no-match path.

### 5. `pool_acquire_locked` (line 2043–2051) [+ `_pool_acquire_critical_section` line 1966–2030]

- **Signature:** `pool_acquire_locked` (no args). Public entry point.
- **Return code:** **0 on success (lane claimed or orphan adopted), 1 on exhaustion / passthrough owner.** The rc comes from the `( flock 9; body ) 9>"$POOL_LOCK_FILE"` subshell exit status.
- **stdout:** **the lane N** via `printf '%s\n' "$N"` (line 2048 inside `_pool_acquire_critical_section`, echoed by the subshell → caller's `$(...)`). EMPTY on failure.
- **Globals set:** **NONE.** (NOT `POOL_ACQUIRED_LANE` — does not exist.) Lane is stdout-only. The docstring (lines ~2020) states verbatim "No new globals."
- **Globals read:** `POOL_LOCK_FILE` (+ everything the critical section reads). The critical section (line 1971) gates `POOL_OWNER_PID` (numeric AND != "0" else `return 1`). **PRECONDITION: `pool_config_init` + `pool_owner_resolve`** (+ `pool_state_init`, called inside).
- **What it returns:** a **PROVISIONAL** lease — port=0, chrome_pid=0, connected=false (line 2018 `pool_lease_write ... 0 ... 0 0 "false"`), OR an adopted orphan (port>0 already booted). ⇒ caller MUST check the returned lane's port to decide boot (S2) vs adopted (skip boot).
- **Caller pattern (under set -e — split capture + MUST guard):**
  ```sh
  local N port
  if N="$(pool_acquire_locked)"; then
      port="$(pool_lease_field "$N" port)"
      if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
          pool_boot_lane "$N" || <retry acquire / exhaustion>
      else
          <adopted: port>0 → ensure_connected only; skip boot>
      fi
  else
      <exhaustion: pool_wait_for_lane or M5.T4 path>
  fi
  ```

### 6. `pool_wait_for_lane` (line 2909–3029)

- **Signature:** `pool_wait_for_lane` (no args). Reads `POOL_WAIT` (timeout seconds global from config).
- **Return code:** **0 on success (lane acquired during poll or after force-reap), 1 on exhaustion (timeout + no stale lane / lost race).**
- **stdout:** **the lane N** via `printf '%s\n' "$N"` (lines 2933 & 2967); EMPTY on final exhaustion (so `N="$(pool_wait_for_lane)"` yields `""`).
- **Globals set:** **NONE.** (NOT `POOL_ACQUIRED_LANE` — does not exist.) Lane is stdout-only.
- **Globals read:** `POOL_WAIT` (loop timeout), plus everything `pool_acquire_locked`/`pool_reap_stale`/`pool_release_lane` read. **PRECONDITION:** same as `pool_acquire_locked`.
- **Logic:** (a) poll loop reaping + retrying acquire until `POOL_WAIT`s; (b) find OLDEST stale lane; (c) force-reap it (`pool_release_lane`) + alert + one final acquire; (d) all-live-owners or lost race → alert + `return 1`.
- **Caller pattern (under set -e — split capture + MUST guard):**
  ```sh
  local N
  if N="$(pool_wait_for_lane)"; then
      <boot-or-adopt N per its port, same as acquire_locked>
  else
      <truly exhausted — surface error to the agent>
  fi
  ```

### 7. `pool_boot_lane` (line 2185–2241)

- **Signature:** `pool_boot_lane LANE` — single positional arg, the lane number.
- **Args:** `LANE` — must match `^[0-9]+$`; else `pool_die` (FATAL).
- **Return code:**
  - **0** on success (lane fully provisioned).
  - **1 (NON-FATAL)** on recoverable failures (port range exhausted @step b; CDP timed out twice @step d; daemon connect failed @step e). On every recoverable failure it calls `_pool_release_lane_internals "$lane"` (drops the lane cleanly) THEN `return 1`.
  - **pool_die (FATAL, propagates)** on genuine misconfiguration: step a `pool_copy_master` non-btrfs/slow-copy-fail; step c `pool_chrome_launch` instant-exit (broken binary).
- **stdout:** EMPTY (logs only).
- **Globals set:** **NONE** exported. (It updates the LANE'S LEASE FILE via `pool_lease_update` — port, chrome_pid, chrome_pgid, connected, last_seen_at — not shell globals.)
- **Globals read:** `POOL_EPHEMERAL_ROOT` (ephemeral dir), `POOL_LANES_DIR` (via helpers), `POOL_REAL_BIN` (via `pool_daemon_connect`), and `POOL_CHROME_PID`/`POOL_CHROME_PGID` (set by `pool_chrome_launch`, read via `_pool_boot_write_chrome_ids`). **PRECONDITION: `pool_config_init` + `pool_state_init` + a PROVISIONAL lease for LANE (port=0, from `pool_acquire_locked`).**
- **Pipeline:** copy master → find free port → launch+wait (retry once) → daemon connect → finalize lease (connected=true). Transforms a provisional lane into a booted lane.

### 8. `pool_ensure_connected` (line 2288–2382)

- **Signature:** `pool_ensure_connected LANE` — single positional arg.
- **Args:** `LANE` — must match `^[0-9]+$`; else logs + `return 1` (non-fatal).
- **Return code:**
  - **0** if connected (already-was / reconnected / relaunched).
  - **1 (NON-FATAL)** on any failure (no/corrupt lease; lane not booted port≤0; reconnect fail; relaunch CDP timeout; relaunch connect fail).
  - **pool_die (FATAL, propagates)** only from `pool_chrome_launch` instant-exit on the relaunch path.
- **stdout:** EMPTY (logs only).
- **Globals set:** **NONE** exported. (Touches the LANE'S LEASE FILE: `last_seen_at` on EVERY path; `connected true/false` on reconnect/relaunch.)
- **Globals read:** `POOL_EPHEMERAL_ROOT` (relaunch udd), `POOL_LANES_DIR` (via helpers), `POOL_CHROME_PID`/`POOL_CHROME_PGID` (set by `pool_chrome_launch`). **PRECONDITION: `pool_config_init` + `pool_state_init` + a BOOTED lease for LANE (port>0).**
- **Key contract:** NEVER drops the lane (no `_pool_release_*`); on failure returns 1 and leaves lease+chrome as-is (wrapper/reaper's job). Forbids `get cdp-url` (auto-launches strays); uses `pool_daemon_connected` + `curl /json/version`.
- **Caller pattern (under set — MUST guard):**
  ```sh
  if ! pool_ensure_connected "$N"; then
      <lane unusable: retry acquire / exhaustion / surface error>
  fi
  ```

### 9. `pool_strip_session_args` (line 3314–3352) + `pool_force_session` (line 3378–3389)

**`pool_strip_session_args`:**
- **Signature:** `pool_strip_session_args [--] ARGS...`
- **Return code:** **0 ALWAYS.** No failure mode ⇒ no `if` guard.
- **stdout:** EMPTY.
- **Globals set:** `POOL_CLEAN_ARGS` — **global ARRAY** via `declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )` at **line 3349**. The argv with every `--session <X>` (space form) and `--session=<X>` (equals form) removed; all else preserved in order. REPLACES each call (empty ⇒ 0 elements).
- **Globals read:** NONE (reads only `$@`). Decoupled from `POOL_NORM_ARGS` — caller passes `${POOL_NORM_ARGS[@]}` as the args.

**`pool_force_session`:**
- **Signature:** `pool_force_session LANE` — single positional arg.
- **Return code:** **0/1 NON-FATAL** (NEVER `pool_die`). `1` (no export) iff LANE is empty/non-numeric/negative (`[[ "$lane" =~ ^[0-9]+$ ]] || return 1`); `0` on successful export.
- **stdout:** EMPTY.
- **Globals/ENV set:** `export AGENT_BROWSER_SESSION="abpool-$lane"` into the **calling shell's environment** (persists after return; inherited by the later `exec`). **This is the ONLY env-var side effect.** Does NOT touch `AGENT_BROWSER_SESSION_NAME`.
- **Globals read:** NONE (reads only `$1`).
- **Caller pattern (MUST guard on the rc-1 path):**
  ```sh
  if pool_force_session "$N"; then
      <ok: env pinned; proceed to exec>
  else
      <bad lane — handle>
  fi
  ```

---

## Architecture: how the pieces connect (the `pool_wrapper_main()` pipeline)

The lifecycle is PRD §2.4 steps 0→5, and the pipeline order is FIXED by the docstrings. The argv array flows through THREE distinct global arrays (`POOL_NORM_ARGS` → strip → `POOL_CLEAN_ARGS`), and the lane flows via STDOUT (never a global):

```
STEP 0  class="$(pool_dispatch_classify "$@")"          # ALWAYS rc 0; stdout meta|driving
        [[ "$class" == meta ]] && { exec real bin unchanged; }   # passthrough

STEP 1  pool_owner_resolve                                # ALWAYS rc 0; sets POOL_OWNER_*
        [[ "$POOL_OWNER_PID" == "0" ]] && { exec real bin unchanged; }  # passthrough owner

STEP 2  pool_config_init (if not already)                 # freezes POOL_REAL_BIN, POOL_WAIT, ...

        # --- argv normalization (writes POOL_NORM_ARGS + POOL_CLOSE_ALL_SEEN) ---
        pool_normalize_close  "$@"                        # ALWAYS rc 0
        pool_normalize_connect "${POOL_NORM_ARGS[@]}"     # ALWAYS rc 0 (chained: reads NORM, writes NORM)

        # --- lane acquisition (lane N via STDOUT, capture split + guarded) ---
        local N
        if N="$(pool_lease_find_mine)"; then              # rc 0 found / 1 not; stdout lane
            <reuse existing live lane>
        else
            if N="$(pool_acquire_locked)"; then           # rc 0 / 1; stdout provisional lane
                port="$(pool_lease_field "$N" port)"
                if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
                    pool_boot_lane "$N" || <retry/exhaustion>     # rc 0/1 non-fatal | pool_die fatal
                else
                    <adopted orphan: port>0, skip boot>
                fi
            else
                if N="$(pool_wait_for_lane)"; then        # rc 0 / 1; stdout lane
                    <boot-or-adopt N per its port>
                else
                    <truly exhausted — surface error>
                fi
            fi
        fi

STEP 4  if ! pool_ensure_connected "$N"; then             # rc 0/1 non-fatal | pool_die fatal
            <lane unusable>
        fi

STEP 5  # --- session override (writes POOL_CLEAN_ARGS; exports AGENT_BROWSER_SESSION) ---
        pool_strip_session_args "${POOL_NORM_ARGS[@]}"    # ALWAYS rc 0; sets POOL_CLEAN_ARGS
        pool_force_session "$N" || <handle>               # rc 0/1 non-fatal; exports env
        exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"     # env AGENT_BROWSER_SESSION inherited
```

### Global-array pipeline (the argv contract)
- `POOL_NORM_ARGS` (array, `declare -ga`): set by `pool_normalize_close` (3171) AND overwritten by `pool_normalize_connect` (3230/3259). Close also sets the scalar `POOL_CLOSE_ALL_SEEN` (3173).
- `POOL_CLEAN_ARGS` (array, `declare -ga`): set by `pool_strip_session_args` (3349) from `${POOL_NORM_ARGS[@]}`. This is the FINAL argv for `exec`.

### Return-code taxonomy (for wrapper error handling)
| rc pattern | functions | wrapper action |
|---|---|---|
| **0 always** (no guard needed) | `pool_dispatch_classify`, `pool_normalize_close`, `pool_normalize_connect`, `pool_strip_session_args` | none |
| **0/1 non-fatal** (MUST `if`-guard; set -e unsafe under bare capture) | `pool_lease_find_mine`, `pool_acquire_locked`, `pool_wait_for_lane`, `pool_ensure_connected`, `pool_force_session` | guard; rc 1 = retry/exhaustion/handle |
| **pool_die FATAL** (propagates — terminates) | inside `pool_boot_lane` (copy_master, chrome_launch instant-exit), inside `pool_ensure_connected` (chrome_launch instant-exit) | NOT catchable without losing `declare -g` globals in a subshell |

### Config/init precondition chain
- `pool_dispatch_classify`: NONE (pure — call FIRST).
- `pool_normalize_close`/`pool_normalize_connect`/`pool_strip_session_args`/`pool_force_session`: NONE (read only `$@`).
- `pool_owner_resolve`: NONE (reads env + /proc).
- `pool_lease_find_mine`/`pool_acquire_locked`/`pool_wait_for_lane`: need `pool_config_init` + `pool_owner_resolve`.
- `pool_boot_lane`: needs `pool_config_init` + `pool_state_init` + a PROVISIONAL lease.
- `pool_ensure_connected`: needs `pool_config_init` + `pool_state_init` + a BOOTED lease (port>0).

## Start here
Open **`lib/pool.sh:3030`** (`pool_dispatch_classify`) — it is step 0 and its docstring block (lines 2991–3029) is the most complete written spec of the dispatch contract. Then read the `pool_boot_lane` CALLER CONTRACT block at **lines 2228–2245** — it gives the exact boot-vs-adopt decision tree the wrapper must implement.

## Open questions / risks for the implementer
1. **Confirm `pool_config_init` invocation point.** `pool_dispatch_classify` and the normalize/strip/force shims need NO init; but `pool_lease_find_mine` onward do. The wrapper must call `pool_config_init` between step 1 (owner_resolve) and step 2 (find_mine) — verify exactly where the existing code expects it.
2. **`POOL_WAIT` source.** `pool_wait_for_lane` reads `POOL_WAIT` (a config global) — confirm it is frozen by `pool_config_init` before `pool_wait_for_lane` can run, and what the default is when unset.
3. **The bare-`connect` GOTCHA** (pool_normalize_connect docstring): after stripping the positional, the result is bare `connect`. The wrapper must rely on `pool_ensure_connected` (which binds the daemon) and NOT exec a bare connect — verify the exact exec decision for a connect command.
4. **Passthrough-owner exec.** When `POOL_OWNER_PID=="0"`, acquire/adopt refuse — confirm the wrapper execs `$POOL_REAL_BIN` unchanged (with the ORIGINAL `$@`, not normalized) for a passthrough driving call.
5. **`local N=$(...)` masking trap** — every lane capture MUST be split (`local N; N="$(...)"`). Easy to get wrong; the docstrings flag it at BashFAQ 105.
