# Reference Implementation: pool_owner_resolve() (P1.M2.T1.S1)

Paste-ready, strict-mode-safe bash. All facts host-verified 2026-07-12.

## Globals produced (after `pool_owner_resolve` runs)

| Global | Type | Value when pi ancestor found | Value when NO pi ancestor (human) | Value in test mode |
|---|---|---|---|---|
| `POOL_OWNER_PID` | digits | the pi PID | `0` (passthrough signal) | the override PID |
| `POOL_OWNER_COMM` | string | `pi` | `""` (empty) | `pi` |
| `POOL_OWNER_STARTTIME` | digits | /proc field 22 (ticks) | `""` (empty) | override or extracted |
| `POOL_OWNER_CWD` | abs path or empty | readlink /proc/<pid>/cwd | `""` (empty) | readlink or empty |

Consumers: M3.T2 (lease queries — `find_my_lease` matches `owner.pid && comm=="pi" && starttime`),
M6.T3 (wrapper lifecycle — `POOL_OWNER_PID==0` → passthrough).

---

## Function: `_pool_owner_starttime PID` (minimal, S2 will harden)

```bash
# _pool_owner_starttime PID
#   Echo the process starttime (/proc/<pid>/stat field 22, clock ticks since boot)
#   for PID. Returns 0 + echoes digits on success; returns 1 (NOT fatal) if the
#   stat file is missing/unreadable. EXTRACTS ONLY — no liveness validation
#   (that's is_owner_alive in P1.M2.T2.S1).
#
#   ROBUSTNESS: field 2 (comm) is in parens and may contain spaces, so a naive
#   `awk '{print $22}'` is unsafe. We strip "pid (comm)" by removing everything up
#   to and including the LAST ')', making overall field 22 == field 20 of the
#   remainder. Verified on this host: both methods agree (8239564).
#   P1.M2.T1.S2 may replace this with a more robust variant; the contract is:
#   echo digits on success, return 1 on failure, never exit the process.
_pool_owner_starttime() {
    local pid="$1"
    local stat_line after start
    # `|| true` neutralizes a vanished/permission-denied /proc entry under set -e.
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
    [[ -n "$stat_line" ]] || return 1
    # Drop "pid (comm)" — everything up to and incl. the last ')'.
    after="${stat_line##*)}"
    start="$(awk '{print $20}' <<<"$after")"
    [[ -n "$start" ]] || return 1
    printf '%s\n' "$start"
}
```

---

## Function: `pool_owner_resolve` (the public entry point)

```bash
# pool_owner_resolve — resolve the owning pi process and populate POOL_OWNER_* globals.
#
# Implements PRD §2.4 step 1 (resolve OWNER) and §1.1 (walk ppid to comm=='pi').
# Also implements the test-hook overrides of PRD §2.18 / key_findings FINDING 8.
#
# LOGIC:
#   1. TEST MODE: if AGENT_BROWSER_POOL_OWNER_PID is set (non-empty), use it directly.
#      Set POOL_OWNER_COMM='pi', POOL_OWNER_STARTTIME from _OWNER_STARTTIME (or extract
#      from /proc if the override PID is live and the starttime override is unset),
#      POOL_OWNER_CWD via readlink.
#   2. REAL MODE: walk ppid from $$ reading /proc/<pid>/comm; stop at first comm=='pi'.
#      On hit: set POOL_OWNER_PID/COMM/STARTTIME/CWD. Extract starttime via
#      _pool_owner_starttime. Extract cwd via readlink.
#   3. NO PI ANCESTOR (human in a terminal): set POOL_OWNER_PID=0, POOL_OWNER_COMM=''
#      (signals passthrough mode to the wrapper — M6.T3).
#
# Globals are MUTABLE (not readonly) so this is re-runnable (test harness calls it
# repeatedly with different overrides in one shell). No "already-resolved" guard.
#
# Never calls pool_die — owner resolution is NEVER fatal (passthrough is always valid).
# Logs the resolved identity via _pool_log for observability.
pool_owner_resolve() {
    # Reset globals to defaults every call (re-runnable contract).
    POOL_OWNER_PID="0"
    POOL_OWNER_COMM=""
    POOL_OWNER_STARTTIME=""
    POOL_OWNER_CWD=""
    declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD

    # --- 1. TEST MODE: env-var override -------------------------------------
    if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
        local ovr_pid="$AGENT_BROWSER_POOL_OWNER_PID"
        # Validate the override is a non-negative integer (regex in [[ ]] is errexit-safe).
        if [[ ! "$ovr_pid" =~ ^[0-9]+$ ]]; then
            _pool_log "pool_owner_resolve: invalid AGENT_BROWSER_POOL_OWNER_PID='$ovr_pid' (ignored)"
            return 0   # leave POOL_OWNER_PID=0 → passthrough; test misconfig is non-fatal
        fi
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM
        # starttime: prefer the override; else try to extract from /proc (test may point
        # at a live PID); else leave empty.
        if [[ -n "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-}" ]]; then
            POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME"; declare -g POOL_OWNER_STARTTIME
        else
            local st=""
            st="$(_pool_owner_starttime "$ovr_pid" 2>/dev/null)" || true
            if [[ -n "$st" ]]; then
                POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
            fi
        fi
        # cwd: readlink the override PID if live; else empty.
        local cwd=""
        cwd="$(readlink "/proc/$ovr_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: TEST MODE owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"
        return 0
    fi

    # --- 2. REAL MODE: walk ppid chain from $$ ------------------------------
    local pid="$$"
    local ppid="" comm="" line="" found_pid="" steps=0
    while (( steps++ < 128 )); do
        comm=""
        IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true
        if [[ "$comm" == "pi" ]]; then
            found_pid="$pid"
            break
        fi
        # ppid from /proc/<pid>/status (PPid: line) — robust vs comm-paren issue.
        ppid=""
        if [[ -r "/proc/$pid/status" ]]; then
            while IFS= read -r line; do
                if [[ "$line" == PPid:* ]]; then
                    ppid="${line#PPid:}"
                    ppid="${ppid//[[:space:]]/}"   # strip tab/space → pure digits
                    break
                fi
            done < "/proc/$pid/status"
        fi
        # Termination: blank/non-numeric ppid, init (1), kernel boundary (0), self-loop.
        if [[ ! "$ppid" =~ ^[0-9]+$ ]]; then break; fi
        if (( ppid == 1 ));  then break; fi
        if (( ppid == 0 ));  then break; fi
        if (( ppid == pid )); then break; fi
        pid="$ppid"
    done

    # --- 3. RESULT ----------------------------------------------------------
    if [[ -n "$found_pid" ]]; then
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM
        local st=""
        st="$(_pool_owner_starttime "$found_pid" 2>/dev/null)" || true
        if [[ -n "$st" ]]; then
            POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
        fi
        local cwd=""
        cwd="$(readlink "/proc/$found_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}" \
                  "cwd=${POOL_OWNER_CWD:-<unknown>}"
        return 0
    fi

    # No pi ancestor → human-in-terminal → passthrough (POOL_OWNER_PID stays 0).
    _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
    return 0
}
```

---

## Strict-mode notes baked in above

- Every `local x; x="$(...)"` is two-statement (SC2155-clean).
- Every `IFS= read ... < file` has `2>/dev/null || true` (vanished /proc entry is a
  clean branch, not a set -e abort).
- Every `(( ))` is inside `if` or `while` (bare `(( ))` returning 0 is fatal).
- The `[[ "$v" =~ ^[0-9]+$ ]]` regex tests are inside `if`/`!` (exempt from errexit).
- `declare -g POOL_OWNER_*` (single-statement form) sets globals unambiguously.
- `pool_owner_resolve` NEVER calls `pool_die` — resolution failure → passthrough (PID=0).
- Globals reset to defaults at function top so it is re-runnable (test harness).
