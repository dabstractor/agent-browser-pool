# system_context.md — implementation map for delta 004_de5e94ac127c (caller-scoped owner + lane pin)

Static read-only analysis of `lib/pool.sh` @ 4695 lines + `bin/agent-browser-pool` @ 27 lines.
All line numbers verified against the working tree. PRD approx-cites validated where given.

## 0. TL;PR for downstream implementers (the three insertion points)

| Delta piece | Where it goes | Exact anchor |
|---|---|---|
| `ABPOOL_OWNER` / `ABPOOL_LANE` parse+validate | end of `pool_config_init` body, after step 6 (harnesses), before/with step 7 (derived paths) | `pool_config_init` L132–L223; harness block L203–L213; derived-paths block L215–L221 |
| caller-mode branch | `pool_owner_resolve`, AFTER the TEST MODE block's `fi` (L561) and BEFORE the `--- 2. REAL MODE` comment (L564) | blank lines L562–L563 |
| pinned-lane branch | `_pool_acquire_critical_section` (L2203–L2248) — insert before/around the CHOOSE-N step (L2234–L2236); skip `pool_lease_find_mine` at `pool_wrapper_main` L3651 |

Caller-mode identity must key on the WRAPPER's `$PPID` (parent of the bash process running
`bin/agent-browser-pool`), not `$$` — real mode today walks from `local pid="$$"` (L565).

## 1. Function inventory — lib/pool.sh (name + start line; all verified via `^[a-zA-Z_]*()` grep)

```
23 _pool_log_path          58 _pool_config_canon_path   343 _pool_atomic_write      506 _pool_owner_starttime
29 pool_die                69 _pool_config_require_uint 372 _pool_json_valid       516 pool_owner_resolve
38 _pool_log               82 _pool_config_bool         390 _pool_now              655 pool_owner_alive
132 pool_config_init       238 pool_state_init          407 _pool_age_str          721 pool_lease_write
266 pool_check_btrfs       302 pool_check_master        442 _pool_get_starttime    802 pool_lease_update
862 pool_lease_read        915 pool_lease_field         957 pool_lease_exists      1006 pool_lanes_list
1042 pool_lease_find_mine  1115 pool_find_free_lane     1178 pool_lane_is_stale     1267 pool_copy_master
1405 pool_find_free_port   1509 pool_chrome_launch      1643 _pool_socket_owner_pid 1704 pool_cdp_is_ours
1784 pool_wait_cdp         1868 pool_daemon_connect     1926 pool_daemon_connected 1994 pool_chrome_kill
2050 _pool_release_lane_internals  2129 _pool_adopt_lane  2203 _pool_acquire_critical_section  2280 pool_acquire_locked
2323 _pool_boot_write_chrome_ids   2368 _pool_launch_and_verify  2480 pool_boot_lane  2594 pool_ensure_connected
2779 pool_release_lane     2890 pool_reap_stale         2981 pool_reap_orphan_dirs 3076 _pool_alert
3170 pool_wait_for_lane    3285 pool_normalize_close    3358 pool_normalize_connect 3462 pool_strip_session_args
3528 pool_force_session    3553 _pool_preflight_real_bin 3627 pool_wrapper_main     3781 _pool_clean_args_is_bare_connect
3841 _pool_clean_args_is_close  3912 pool_admin_status  4048 pool_admin_reap       4162 pool_admin_release
4347 pool_admin_doctor     4648 pool_admin_help
```

Verified end-braces for the functions that matter here: `pool_config_init` L223;
`_pool_get_starttime` L504; `_pool_owner_starttime` L514; `pool_owner_resolve` L614;
`pool_owner_alive` L688; `pool_lease_write` L776; `pool_lease_find_mine` L1061;
`pool_lane_is_stale` L1211; `pool_chrome_kill` L2012; `_pool_release_lane_internals` L2095;
`_pool_adopt_lane` L2175; `_pool_acquire_critical_section` L2248; `pool_acquire_locked` L2292;
`pool_wrapper_main` L3757.

## 2. pool_config_init (L132–L223)

### 2.1 Header env-var table comment block (L112–L131, quoted in full)

```
# Configuration reference (env var → POOL_* global):
#   ENV VAR                        DEFAULT                                         GLOBAL                CATEGORY
#   AGENT_BROWSER_POOL_STATE       $HOME/.local/state/agent-browser-pool           POOL_STATE_DIR        path (may not exist)
#   AGENT_CHROME_MASTER            ~/.agent-chrome-profiles/master-profile         POOL_MASTER_DIR       path (dedicated agent master; may not exist)
#   AGENT_CHROME_EPHEMERAL_ROOT    $HOME/.agent-chrome-profiles/active             POOL_EPHEMERAL_ROOT   path (may not exist)
#   AGENT_BROWSER_REAL             $HOME/.local/bin/agent-browser                  POOL_REAL_BIN         path (may not exist)
#   AGENT_CHROME_BIN               google-chrome-stable                            POOL_CHROME_BIN       name-or-path
#   AGENT_CHROME_PORT_BASE         53420                                           POOL_PORT_BASE        uint
#   AGENT_CHROME_PORT_RANGE        1000                                            POOL_PORT_RANGE       uint (>0)
#   AGENT_BROWSER_POOL_WAIT        600                                             POOL_WAIT             uint
#   AGENT_CHROME_HEADLESS          (unset = windowed)                              POOL_HEADLESS         bool (1=headless)
#   AGENT_CHROME_ALLOW_SLOW_COPY   (unset = refuse non-btrfs)                      POOL_ALLOW_SLOW_COPY  bool (1=allow real copy)
#   AGENT_CHROME_PROFILE           (unset = derive from Local State last_used)     POOL_PROFILE_DIR      profile-dir name (e.g. "Profile 8"/"Default")
#   AGENT_BROWSER_POOL_HARNESSES   pi,claude,codex,agy,antigravity                 POOL_HARNESSES        comma-set (lowercased; empty→default)
```

(Followed by "Derived (no env var)" POOL_HOME_DIR/POOL_LANES_DIR/POOL_LOCK_FILE note, the
boolean rule, the Errors list — `$HOME` unset, non-numeric numeric, `POOL_PORT_RANGE <= 0` —
and the "MUTABLE / RE-RUNNABLE, intentionally NO already-initialized guard" note.)

### 2.2 The AGENT_BROWSER_POOL_HARNESSES block (L203–L213, verbatim)

```bash
    # 6. Recognized harnesses (owner resolution, PRD §2.11 / Decision O9) — comma-separated
    #    comm values the pool treats as valid lane owners. Normalized to a clean lowercase
    #    comma list (never empty: an empty set would fail every driving command's ancestor
    #    check). Consumed as a lookup by pool_owner_resolve (M1.T1.S2):
    #      [[ ",$POOL_HARNESSES," == *",$comm,"* ]]   (comma-delimited wrap ⇒ exact-token match).
    local harnesses_raw harnesses
    harnesses_raw="${AGENT_BROWSER_POOL_HARNESSES:-pi,claude,codex,agy,antigravity}"
    harnesses="$(printf '%s' "$harnesses_raw" | tr '[:upper:]' '[:lower:]' | tr -s ',')"
    harnesses="${harnesses#,}"; harnesses="${harnesses%,}"
    [[ -n "$harnesses" ]] || harnesses="pi,claude,codex,agy,antigravity"
    POOL_HARNESSES="$harnesses"; declare -g POOL_HARNESSES
```

### 2.3 Representative env-parsing idiom (numerics, L186–L192)

```bash
    port_base="$(_pool_config_require_uint AGENT_CHROME_PORT_BASE "${AGENT_CHROME_PORT_BASE:-53420}")"
    port_range="$(_pool_config_require_uint AGENT_CHROME_PORT_RANGE "${AGENT_CHROME_PORT_RANGE:-1000}")"
    wait="$(_pool_config_require_uint AGENT_BROWSER_POOL_WAIT "${AGENT_BROWSER_POOL_WAIT:-600}")"
    (( port_range > 0 )) || pool_die "AGENT_CHROME_PORT_RANGE must be > 0 (got $port_range)"
```

Pattern: `local` two-statement capture (never `local x="$(…)"`), validate, then
`GLOBAL="$val"; declare -g GLOBAL`. Path values go through `_pool_config_canon_path` (L58);
booleans through `_pool_config_bool` (L82); ints through `_pool_config_require_uint` (L69).
Strings stored as-is (POOL_PROFILE_DIR, L196–L201) are the closest precedent for a raw env
value like `ABPOOL_OWNER`.

### 2.4 pool_die — definition, signature, call-site precedent for malformed env

- Defined IN lib/pool.sh itself at **L29–L32** (not sourced elsewhere): sourced into the
  process by `bin/agent-browser-pool` L12 (`source "$REAL_DIR/../lib/pool.sh"`).
- Signature: `pool_die MSG...` → `printf '%s\n' "$*" >&2; exit 1`.
- Malformed-env → pool_die precedents (what `ABPOOL_LANE=abc` should mirror):
  - `_pool_config_require_uint` L74–L75: `pool_die "$name must be a non-negative integer, got: '${val:-<unset>}'"`
  - L192: `(( port_range > 0 )) || pool_die "AGENT_CHROME_PORT_RANGE must be > 0 (got $port_range)"`
  - L137: `pool_die "pool_config_init: \$HOME is unset or empty"` (also L138, L165, L182–L184)
  - Note the OPPOSITE precedent too: `pool_owner_resolve` L539–L541 treats a malformed
    `AGENT_BROWSER_POOL_OWNER_PID` as a logged warning + ignore (`_pool_log … (ignored)`),
    NOT pool_die. The 004 delta PRD (test R1) wants malformed `ABPOOL_LANE` → `pool_die`, so
    it follows the config-init precedent, not the resolve one.

## 3. pool_owner_resolve (L516–L614)

Signature: `pool_owner_resolve` (no args). Returns rc 0 ALWAYS, never fatal. Doc comment
L516–L534. **Globals reset every call at L533–L534 (re-runnable contract):**

```bash
    POOL_OWNER_PID="0"; POOL_OWNER_COMM=""; POOL_OWNER_STARTTIME=""; POOL_OWNER_CWD=""
    declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD
```

Exact global spellings (only these four exist): `POOL_OWNER_PID`, `POOL_OWNER_COMM`,
`POOL_OWNER_STARTTIME`, `POOL_OWNER_CWD`.

### 3.1 TEST MODE block (L536–L561, quoted; insertion point for caller mode is AFTER L561)

```bash
    # --- 1. TEST MODE: env-var override -------------------------------------
    if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
        local ovr_pid="$AGENT_BROWSER_POOL_OWNER_PID"
        if [[ ! "$ovr_pid" =~ ^[0-9]+$ ]]; then
            _pool_log "pool_owner_resolve: invalid AGENT_BROWSER_POOL_OWNER_PID='$ovr_pid' (ignored)"
            return 0
        fi
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="$(cat /proc/"$ovr_pid"/comm 2>/dev/null || printf 'pi')"; declare -g POOL_OWNER_COMM
```

Continuation (L546–L561): if `AGENT_BROWSER_POOL_OWNER_STARTTIME` is set it WINS (precedence:
explicit env override > live read); else `_pool_owner_starttime "$ovr_pid"` live read; then
`readlink "/proc/$ovr_pid/cwd"` for CWD; `_pool_log "pool_owner_resolve: TEST MODE owner …"`;
`return 0` at L560; block `fi` at **L561**.

Note the TEST MODE `return 0` on malformed PID (L539–L541) silently leaves the reset
defaults (PID=0 → wrapper fail-fast fires downstream).

### 3.2 REAL MODE ppid walk (L563–L590) and the RESULT block (L592–L614)

- L565 `local pid="$$"` — starts from the wrapper process itself, NOT $PPID.
- L566 locals: `ppid comm line found_pid found_comm steps`.
- Loop L567 `while (( steps++ < 128 )); do`:
  - L569–L570: `IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true` then the
    set-membership test `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]` → found; break.
  - L576–L584: PPid extraction from `/proc/$pid/status` (line-by-line `PPid:` prefix match,
    strip whitespace).
  - L585–L588 break guards: non-numeric ppid, `ppid == 1`, `ppid == 0`, `ppid == pid` (self).
- RESULT L592–L610: on found → set all four POOL_OWNER_* globals, `_pool_owner_starttime`
  live read, `readlink /proc/$found_pid/cwd`, `_pool_log`, `return 0`.
- L612–L613 no-owner path (verbatim):

```bash
    _pool_log "pool_owner_resolve: no recognized-harness ancestor (passthrough mode)"
    return 0
```

**Yes: no owner ⇒ POOL_OWNER_PID stays "0"** (from the L533 reset). Wrapper gates on that.

### 3.3 starttime helpers

- `_pool_get_starttime` (L442–L504) — THE canonical parser. Validates PID numeric (rc 1 if
  not), `cat /proc/<pid>/stat` (rc 1 if unreadable), then:

```bash
    after="${stat_line##*)}"                    # GREEDY strip to & incl. the LAST ')'
    start="$(awk '{print $20}' <<<"$after")"    # field 22 overall == field 20 here
```

  (comm may contain spaces → never use `awk '{print $22}'`; PRD §2.19 "NF-19" is wrong per
  the L470–L476 comment). Echoes digits rc 0; rc 1 on anything else; never fatal.
- `_pool_owner_starttime` (L506–L514) — 1-line delegating wrapper: `_pool_get_starttime "$@"`.

### 3.4 pool_owner_alive (L655–L688)

Signature `pool_owner_alive PID EXPECTED_STARTTIME [EXPECTED_COMM="pi"]`. Decision ladder:
(a) `[[ -d "/proc/$pid" ]]` (NOT `kill -0` — L641–L645 comment: kill -0 conflates ESRCH and
EPERM); (b) comm equality (`[[ "$comm" == "$expected_comm" ]]`); (c) starttime equality via
`_pool_get_starttime`; (d) `return 0`. rc 1 = dead/recycled/unverifiable. Never fatal.

## 4. bin/agent-browser-pool (27 lines, quoted in full)

```bash
#!/usr/bin/env bash
#
# bin/agent-browser-pool — SOLE entry point for the agent-browser-pool: pool verbs + driving
# router (PRD §2.1, §2.4, §2.12). Resolves its own real path (symlink-safe) so it can source
# the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
# → repo/bin/agent-browser-pool at install time). Pool verbs (status|reap|release|doctor|help)
# dispatch to pool_admin_*; every other token is a DRIVING command routed to pool_wrapper_main,
# which acquires/reuses the caller's lane and execs the real agent-browser (§2.4 steps 1-5).
# Default command (no args) is `status`.
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.1; mirrors bin/agent-browser)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
# Init config + state unconditionally so every subcommand has globals + a lanes dir.
# (Idempotent; each pool_admin_* ALSO calls them as its own precondition — redundant, harmless.)
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) pool_wrapper_main "$@" ;;
esac
```

## 5. pool_wrapper_main (L3627–L3757) — driving-path call chain

Sequence (step letters per in-code comments):
- **a** L3634–L3638: `pool_config_init` (L3637) + `pool_state_init` (L3638) +
  `_pool_preflight_real_bin` (L3640… actual call L3640; fn def L3553).
- **d** owner resolve + fail-fast (L3642–L3646, verbatim):

```bash
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
                 "For raw browser use without pooling, call 'agent-browser' directly."
    fi
```

  (die message strings live at L3644–L3645; the `fi` at L3646.) NOTE for delta: with
  `ABPOOL_OWNER=caller` this gate must still fire only when the CALLER itself died/unresolved.
- **e→g** find-or-acquire (L3651–L3676):

```bash
    if N="$(pool_lease_find_mine)"; then              # L3651 — reuse live lane
        _pool_log "pool_wrapper_main: reusing lane $N"
    else
        if ! N="$(pool_acquire_locked)"; then         # L3656 — flock'd acquire
            if ! N="$(pool_wait_for_lane)"; then      # L3657 — poll + force-reap
                pool_die "agent-browser-pool: no lane available after ${POOL_WAIT:-600}s + force-reap"  # L3659
            fi
        fi
```

  then L3665–L3674 boot-vs-adopt: `port="$(pool_lease_field "$N" port)"` (L3669); port
  0/empty/null → `pool_boot_lane "$N" || pool_die "…boot failed for lane $N"` (L3671); else
  adopted (skip boot). **Pinned-lane delta: skip the `pool_lease_find_mine` call at L3651**
  (or make it honor the pin).
- **h** L3682: `pool_ensure_connected "$N" || pool_die "…lane $N not connected; aborting"`.
- **i/j** arg normalization L3688–L3699; close→`connected=false` L3713–L3721.
- **k** bare-connect short-circuit L3739–L3755; terminal `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` at **L3756**.

Exact call chain acquire: `pool_wrapper_main` (L3627) → `pool_acquire_locked` (L2280, called
L3656) → `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` (L2288–L2291) →
`_pool_acquire_critical_section` (L2203). **The flock: `flock 9` at L2289; fd-9 redirect on
`$POOL_LOCK_FILE` at L2291; lock path = `$POOL_STATE_DIR/acquire.lock`** (derived at
L215–L220 of pool_config_init; `pool_state_init` L238 pre-touches it). Lock is exclusive,
blocking, held ONLY for scan+reap+reuse+choose+claim.

## 6. _pool_acquire_critical_section (L2203–L2248)

Signature: `_pool_acquire_critical_section` (no args; runs INSIDE the flock subshell,
inherits globals). Echoes lane N + rc 0; rc 1 on exhaustion/passthrough.

Current flow step-by-step:
1. **L2205** `local n port session N ephemeral_dir`.
2. **L2211** passthrough guard:
   `[[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1`
   (defense-in-depth; wrapper already gated).
3. **(a/b) L2213–L2233** interleaved REAP-STALE + REUSE-ORPHAN per lane, ascending
   (`for n in $(pool_lanes_list)`; lanes_list = L1006–L1014, glob+sort -n):
   - `if pool_lane_is_stale "$n"; then` (L2216) — TRI-STATE: only rc 0 (stale) enters.
   - `port="$(pool_lease_field "$n" port …)"`, `session=…` (L2218–L2219).
   - if port>0 AND `pool_daemon_connected "$session" "$port"` (L2220–L2221) →
     `if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi` (L2223–L2226) —
     **adoption reassigns owner to CURRENT POOL_OWNER_*; rc 1 (Chrome died mid-adopt) falls
     through to reap**.
   - else `_pool_release_lane_internals "$n"` (L2229–L2230).
4. **(c) CHOOSE-N L2234**: `N="$(pool_find_free_lane)"` (def L1115; always echoes + rc 0;
   first N≥1 with NO `$POOL_EPHEMERAL_ROOT/$n` dir AND NO `$POOL_LANES_DIR/$n.json` file —
   uses `[[ -f ]]`, not pool_lease_exists, so a corrupt lease still blocks reuse).
5. **(d) CLAIM L2240–L2244** (verbatim — the provisional port=0 claim):

```bash
    ephemeral_dir="$POOL_EPHEMERAL_ROOT/$N"
    pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" \
        "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" "${POOL_OWNER_CWD:-}" \
        0 0 "false"
```

6. **L2246–L2247**: `_pool_log "pool_acquire(claim): provisional lane $N …"`; `printf '%s\n'
   "$N"`; `return 0` L2247; close brace **L2248**.

**Pinned-lane branch goes here** — e.g. before the reap loop (validate/adopt lane N) or
replacing step (c); must still run under the flock and handle: free lane → claim at N;
stale lane at N → adopt/reap-then-claim; LIVE FOREIGN lease at N → hard error (pool_die is
safe inside: it exits the subshell → flock auto-released → propagates; per L2259–L2260
comment). The caller-mode/pin distinction provisional-vs-adopted happens in the wrapper at
L3665–L3674 via the lease `port` field.

### 6.1 pool_lane_is_stale (L1178–L1211) — tri-state rc contract

- rc **0** = STALE (owner dead/recycled/unverifiable) → caller reaps.
- rc **1** = LIVE (owner alive, same (pid,comm,starttime)).
- rc **2** = NO LEASE (missing/corrupt lease, or non-numeric lane arg).
Flow: read lease via `pool_lease_read` (L1191–L1193); ONE jq fork
`mapfile -t _owner < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")`
(L1200–L1203); `if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then return 1; fi;
return 0` (L1207–L1210).

### 6.2 _pool_release_lane_internals (L2050–L2095)

Signature `_pool_release_lane_internals LANE`. Idempotent + NON-FATAL (rc 0 always).
Flow: non-numeric lane → rc 0; `pool_lease_read` rc 1 → rc 0 (nothing to release); one jq
fork for `.chrome_pid, .chrome_pgid, .ephemeral_dir`; `pool_chrome_kill "$chrome_pid"
"$chrome_pgid"`; `rm -rf` the ephemeral dir RECONSTRUCTED as `$POOL_EPHEMERAL_ROOT/$lane`
(never trusts the lease string) with prefix guard `[[ "$dir" == "$POOL_EPHEMERAL_ROOT"/* ]]`;
`rm -f "$POOL_LANES_DIR/$lane.json"`; `_pool_log "pool_acquire(reap): released stale lane …"`.
(The public `pool_release_lane` L2779 and admin release L4162 compose it with daemon close.)

### 6.3 _pool_adopt_lane (L2129–L2175)

Signature `_pool_adopt_lane LANE`. rc 0 adopted / rc 1 Chrome-died-mid-adopt (caller reaps).
Re-reads lease; extracts `.port`/`.session`; validates `POOL_OWNER_PID`; jq-mutates:

```bash
    if ! updated_lease="$(jq \
            --argjson now "$now" \
            --argjson pid "$POOL_OWNER_PID" \
            --arg comm "$POOL_OWNER_COMM" \
            --argjson starttime "${POOL_OWNER_STARTTIME:-0}" \
            --arg cwd "${POOL_OWNER_CWD:-}" \
            '.owner = {pid:$pid, comm:$comm, starttime:$starttime, cwd:$cwd}
             | .connected = true
             | .last_seen_at = $now' …
```

then `_pool_atomic_write` publish (L2165) and `pool_daemon_connect "$session" "$port"`
re-bind (L2169–L2171; rc 1 ⇒ return 1). NOTE: adoption is the ONE deliberate `.owner`
mutation (pool_lease_update is top-level-field only) — a pinned-lane adoption path can reuse
this function unchanged.

### 6.4 Lease JSON — full schema, jq usage, atomic write

- File: `$POOL_LANES_DIR/<N>.json`. Built by `pool_lease_write` (L721–L776) with `jq -n`,
  every value as `--arg`/`--argjson` DATA (injection-safe). **ALL keys (PRD §2.8):**
  `version`(1, num) · `lane`(num) · `ephemeral_dir`(string) · `port`(num) · `session`(string)
  · `owner` = `{pid, comm, starttime, cwd}` (owner.comm/owner.cwd strings; owner.pid /
  owner.starttime numbers) · `chrome_pid`(num) · `chrome_pgid`(num) · `acquired_at`(epoch
  num) · `last_seen_at`(epoch num) · `connected`(JSON boolean, validated true|false at
  L737–L739). No harness/owner-mode field exists today.
- **Atomic write** = `_pool_atomic_write` (L343–L361): `tmp="${filepath}.tmp"`;
  `printf '%s' "$content" >"$tmp"` (exact bytes, no newline);
  `mv -f -- "$tmp" "$filepath" || pool_die …` — tmp in same dir ⇒ same FS ⇒ atomic rename.
- Reads: `pool_lease_read` (L862, logs+rc1 on corrupt), `pool_lease_field` (L915,
  injection-safe nested `jq -r --arg f 'getpath($f|split("."))'`, missing field → `"null"`),
  `pool_lease_exists` (L957).

## 7. Reaper + liveness (names + lines)

- `pool_owner_alive` L655–L688 — see §3.4; uses `/proc/<pid>` existence (never `kill -0`).
- Lazy reaping on acquire: (1) the per-lane stale scan INSIDE the flock —
  `_pool_acquire_critical_section` L2213–L2233 (calls `pool_lane_is_stale` →
  `_pool_release_lane_internals`); (2) exhaustion path — `pool_wait_for_lane` (L3170–L3284)
  calls lock-free `pool_reap_stale >/dev/null` (L3180) each 2s poll, then retries
  `pool_acquire_locked` (L3183); on timeout force-reaps the oldest dead-owner lane.
- `pool_reap_stale` L2890–L2980 — scans all lanes, releases stale ones via
  `pool_release_lane`, echoes the count, rc 0 always. `pool_reap_orphan_dirs` L2981 (dirs
  without leases). Admin entry: `pool_admin_reap` L4048.
- `pool_chrome_kill` L1994–L2012 — escalation:
  `kill -- -"$chrome_pgid"` (SIGTERM pgroup) → `sleep 0.5` → `kill -9 -- -"$chrome_pgid"`
  (L2002–L2005); fallback bare-pid TERM+KILL (L2008–L2011). Every kill `2>/dev/null || true`;
  0/0 provisional values self-guard to no-op. Chrome is launched under `setsid` so
  `pgid == pid` (see `pool_chrome_launch` L1509).

## 8. ABPOOL_OWNER / ABPOOL_LANE — NO pre-existing handling (confirmed)

`grep -rn 'ABPOOL_OWNER\|ABPOOL_LANE'` over the whole repo: matches ONLY in
`plan/004_de5e94ac127c/prd_snapshot.md` + `plan/004_de5e94ac127c/delta_prd.md` (the PRD docs
themselves). Zero matches in `lib/`, `bin/`, `test/`, `README*`, `install.sh`. (test/*.sh
`ABPOOL_*` hits are unrelated framework vars: `ABPOOL_ADMIN`, `ABPOOL_TEST_ROOT(S)`,
`ABPOOL_CUR_OWNER`, `ABPOOL_SIM_BINS`, `ABPOOL_PASS/FAIL`.) The two new env names are free.

## 9. Static checks + totals

- `bash -n lib/pool.sh` → **PASS** (exit 0).
- `shellcheck -s bash lib/pool.sh` → **PASS, exit 0, ZERO warnings** (file is
  lint-clean; in-file `shellcheck disable=SC2034` at L131 covers the POOL_* globals
  contract — a new `POOL_OWNER_MODE`/`POOL_LANE_PIN` global will need the same treatment
  or it will trip SC2034).
- `wc -l`: lib/pool.sh = **4695**; bin/agent-browser-pool = **27**.
- Bash version guards: NONE enforced at runtime. Header comment L12: "Requires: bash >= 4.2
  (uses the printf '%(fmt)T' builtin). Hosts run bash 5.x." Bashisms relied on:
  `${v,,}` (L84), `mapfile -t` (L1200, L2074), `declare -g` (throughout config init),
  `printf -v ts '%(...)T'` (L47), `for (( n=1; ; n++ ))` (L1117). `set -euo pipefail` at L18.

## 10. PRD-vs-reality line-cite check (delta PRD approximates → verified current)

| PRD cite | Reality | Verdict |
|---|---|---|
| pool_config_init ~L130–230 | L132–L223 | close; use L132–L223 |
| harness parse ~L204–213 | L203–L213 | match |
| pool_owner_resolve ~L516–618 | L516–L614 | start exact; END is L614 (not 618) |
| critical section ~L2203 | L2203–L2248 | start exact |
| wrapper fail-fast ~L3642 | call L3642, `if` L3643, die L3644–3645 | match (call site) |
| find_mine ~L3651 | call site L3651; def L1042–L1061 | match |

Additional discrepancy warnings for implementers:
- PRD says caller-mode keys on "the wrapper's $PPID". Reality: `pool_owner_resolve` runs in
  the wrapper bash process, so `$PPID` there IS the calling process — correct as stated, but
  note `$$`/`$PPID` are the SHELL's, not the eventual exec'd child's. Capture
  starttime/cwd/comm of `$PPID` BEFORE any exec (delta PRD R3 already says this).
- TEST MODE hook (`AGENT_BROWSER_POOL_OWNER_PID`) takes PRECEDENCE over everything today
  (L537). Decide and pin where `ABPOOL_OWNER=caller` ranks vs that hook (recommended:
  after TEST MODE, before REAL MODE — exactly the mandated insertion point).
- `pool_lease_write` validates `connected` but performs NO lane-range/N-validation beyond
  digits; a pinned-lane branch should validate `ABPOOL_LANE` is a positive integer at
  config-init time (precedent: `_pool_config_require_uint` + the `> 0` check pattern, L69/L192).
- `pool_find_free_lane` has no bound; a pinned claim at fixed N must NOT route through it.