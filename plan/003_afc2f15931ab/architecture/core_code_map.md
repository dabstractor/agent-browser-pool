# Core Code Map — Delta 003 (Multi-Harness Owner Resolution)

Static research of `lib/pool.sh` (4406 lines) for the `pi`-only → recognized-harness-set
generalization. **No Chrome booted, no test suite run** (AGENTS.md §1). Verified with
`bash -n lib/pool.sh` (OK) and `shellcheck -s bash lib/pool.sh` (OK, rc 0).

The delta touches a single owner-resolution path + one config block + one user-facing
message. The liveness/identity layer (`pool_owner_alive`, `pool_lane_is_stale`) is already
**comm-generic** and needs only a doc/comment sweep — no logic change.

---

## 1. `pool_config_init` — config globals parsing (lib/pool.sh:130-206)

### Existing parse patterns
- **§4 Numerics (lines 161-169)** — the `:=` default + uint validation:
```bash
    port_base="$(_pool_config_require_uint AGENT_CHROME_PORT_BASE "${AGENT_CHROME_PORT_BASE:-53420}")"
    POOL_PORT_BASE="$port_base"; declare -g POOL_PORT_BASE
```
- **§3 CHROME_BIN string (lines 150-159)** — the plain-string `${VAR:-default}` pattern (this is the pattern a harness-set string follows):
```bash
    local chrome_in chrome_out
    chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
    POOL_CHROME_BIN="$chrome_out"; declare -g POOL_CHROME_BIN
```

### R1 insertion point + shape for `POOL_HARNESSES`
Add a block after the booleans (after line 176 `POOL_ALLOW_SLOW_COPY`), before the §6
derived-paths block (line 178). Frozen-global form (lowercased + de-duped lookup string):
```bash
    # 7. Agent-harness set (PRD §2.11 / Decision O9): comma-separated comm values the
    #    pool treats as valid lane owners. Default pi,claude,codex,agy,antigravity.
    #    Stored so the walk loop can glob-match: [[ ",$POOL_HARNESSES," == *",$comm,"* ]].
    #    Empty/unset → default (never empty).
    local harnesses_raw
    harnesses_raw="${AGENT_BROWSER_POOL_HARNESSES:-pi,claude,codex,agy,antigravity}"
    POOL_HARNESSES="$(printf '%s' "$harnesses_raw" | tr '[:upper:]' '[:lower:]' | tr -s ',' | sed 's/^,//; s/,$//')"
    [[ -n "$POOL_HARNESSES" ]] || POOL_HARNESSES="pi,claude,codex,agy,antigravity"
    declare -g POOL_HARNESSES
```
The header comment for `pool_config_init` lives ~lines 109-128 — R1 "Mode A docs" adds the
`AGENT_BROWSER_POOL_HARNESSES` line there.

---

## 2. `pool_owner_resolve` — full function (lib/pool.sh:486-583)

No args. Populates globals `POOL_OWNER_PID/COMM/STARTTIME/CWD`. Re-runnable (globals reset on entry).

### (a) TEST MODE block (lib/pool.sh:507-533) — env override
```bash
    if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
        ...
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM          # <<< HARDCODED "pi" (line 514)
        ...
        return 0
    fi
```
**R2 note:** delta_prd §R2 says keep `"pi"` as the test-mode default (in the default set,
preserves existing owner-simulation tests) — UNLESS R3's non-pi selftest needs a
`AGENT_BROWSER_POOL_OWNER_COMM` hook. Coordinate with R4: the new selftest's positive case
needs `pool_owner_resolve` TEST MODE to record the actual comm. **Decision: read the real
`/proc/$ovr_pid/comm` in TEST MODE (so it records the sim owner's actual comm), OR honor a
narrow `AGENT_BROWSER_POOL_OWNER_COMM` override. Prefer reading `/proc/$ovr_pid/comm` since
the sim owner's comm is genuinely set by the kernel.**

### (b) REAL MODE ppid-walk loop (lib/pool.sh:535-557) — THE key change site
```bash
    local pid="$$"
    local ppid="" comm="" line="" found_pid="" steps=0
    while (( steps++ < 128 )); do
        comm=""
        IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true
        if [[ "$comm" == "pi" ]]; then          # <<< HARDCODED CHECK (line 540) → set membership
            found_pid="$pid"
            break
        fi
        ...ppid walk...
    done
```
**R2 concrete change:** add `found_comm=""` to the line 536 declaration; replace line 540:
```bash
        if [[ ",$POOL_HARNESSES," == *",$comm,"* ]]; then
            found_pid="$pid"; found_comm="$comm"
            break
        fi
```

### (c) RESULT block (lib/pool.sh:559-579)
```bash
    if [[ -n "$found_pid" ]]; then
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM    # <<< HARDCODED "pi" (line 564) → use $found_comm
        ...
        return 0
    fi
```
**R2 change:** line 564 `POOL_OWNER_COMM="pi"` → `POOL_OWNER_COMM="$found_comm"`.

### (d) No-ancestor / fail path (lib/pool.sh:581-582) — UNCHANGED
```bash
    _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
    return 0
```
Fail condition is `POOL_OWNER_PID == "0"` (consumed by `pool_wrapper_main`). **Not modified** —
only the `_pool_log` text rephrases (R2 Mode A: "no pi ancestor" → "no recognized-harness ancestor").
Header comment lines 487-498 also rephrase.

---

## 3. `pool_wrapper_main` — fail-fast message (lib/pool.sh:3413-3416)
```bash
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
                 "For raw browser use without pooling, call 'agent-browser' directly."
    fi
```
- **Condition (line 3414):** UNCHANGED (R3 says no condition change).
- **`pool_die` text (line 3415):** → `"agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)."`
- **Second line (3416):** kept verbatim.

`pool_die` (lib/pool.sh:29) writes to pool log + stderr and `exit 1`s.

---

## 4. `pool_owner_alive` & `pool_lane_is_stale` — ALREADY comm-generic (doc-only)

### `pool_owner_alive` (lib/pool.sh:624-687)
```bash
    local expected_comm="${3:-pi}"        # <<< DEFAULT "pi" (line 627) — harmless: pi is in the default set
    ...
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
    [[ "$comm" == "$expected_comm" ]] || return 1      # GENERIC (line 662)
```
Always called with the lease's stored comm. The `${3:-pi}` fallback only hit if a caller
omits the 3rd arg — no current caller does. **No logic change.**

### `pool_lane_is_stale` (lib/pool.sh:1147-1234)
```bash
    mapfile -t _owner < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")
    ...
    if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then   # passes STORED comm + ${:-pi} fallback (line 1176)
        return 1     # live
    fi
    return 0          # stale
```
**No logic change.** Comment header rephrases (doc only).

---

## 5. ALL other places hardcoding "pi" in owner/harness context

### A. Code (logic-relevant) — 2 sites need code change; rest stay
| Line | Verbatim | Disposition |
|------|----------|-------------|
| **514** | `POOL_OWNER_COMM="pi"` (TEST MODE) | **See R2/R4 decision** — record actual comm |
| **540** | `if [[ "$comm" == "pi" ]]; then` (walk loop) | **CHANGE** (R2: set membership) |
| **564** | `POOL_OWNER_COMM="pi"` (RESULT) | **CHANGE** (R2: → `$found_comm`) |
| 627 | `local expected_comm="${3:-pi}"` | Keep (generic fallback) |
| 1176 | `pool_owner_alive "$pid" "$starttime" "${comm:-pi}"` | Keep (passes stored comm) |
| 581 | `_pool_log "... no pi ancestor ..."` | R2 Mode A: rephrase text |
| 3415 | `pool_die "...require a pi ancestor..."` | **CHANGE** (R3: message text) |

### B. Comment/doc rephrases (R5 Mode A — no behavior change)
Lines: 399-400, 406, 450, 487-488, 496-498, 598, 607, 608, 618 (KEEP — accurate), 991-992,
1098, 2097, 3353, 3411-3412, 3646.

### C. Owner-comm WRITE sites (auto-correct after R2 — no code change)
- **lib/pool.sh:2133** (`_pool_acquire_critical_section`): writes `$POOL_OWNER_COMM` into lease.
- **lib/pool.sh:2044** (`_pool_adopt_lane`): `--arg comm "$POOL_OWNER_COMM"` in jq mutation.
→ Once R2 records the actual matched comm, these automatically write the right `.owner.comm`.

---

## 6. Architecture — how the pieces connect
```
pool_wrapper_main (3398)
  ├─ pool_config_init (130)         ── freezes POOL_* globals incl. NEW POOL_HARNESSES
  ├─ pool_owner_resolve (486)       ── walks ppid → first comm ∈ POOL_HARNESSES
  │      [CHANGE: line 540 set-membership, line 564 record actual comm]
  ├─ if POOL_OWNER_PID=="0" → pool_die fail-fast (3414-3416)   [CHANGE: msg text only]
  ├─ pool_lease_find_mine (1011)    ── reuses my live lane generically
  └─ pool_acquire_locked → _pool_acquire_critical_section (2020)
            └─ pool_lane_is_stale (1147) → pool_owner_alive [no change]
            └─ pool_lease_write (690)   writes "$POOL_OWNER_COMM"        [auto-correct]
            └─ _pool_adopt_lane (2020)  writes "$POOL_OWNER_COMM"        [auto-correct]
```

**Identity model (unchanged):** the triple `(pid, comm, starttime)` (PRD §2.8/§2.13). Only the
**set of acceptable comm values** widens, and the **recorded** comm becomes the actual match.

---

## 7. Static-check evidence (research-only)
```
$ bash -n lib/pool.sh            → OK (rc 0)
$ shellcheck -s bash lib/pool.sh → OK (rc 0)
```
No processes spawned; no browsers booted.
