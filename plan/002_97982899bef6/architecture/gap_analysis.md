# Gap Analysis — Detailed Code-Level Changes Required

## 1. lib/pool.sh Changes

### 1a. pool_config_init (lines 132-210)
**Change**: Remove `AGENT_BROWSER_POOL_DISABLE` / `POOL_DISABLE` initialization.

- **Line 109** (comment block): Remove the `AGENT_BROWSER_POOL_DISABLE` → `POOL_DISABLE` row.
- **Lines 183-184**: Remove:
  ```bash
  disable="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"
  ```
- **Line 186**: Remove:
  ```bash
  POOL_DISABLE="$disable"; declare -g POOL_DISABLE
  ```

### 1b. pool_wrapper_main (lines 3601-3740)
**Change 1**: Remove step b (POOL_DISABLE passthrough, lines 3611-3617):
```bash
# --- b. safety valve (PRD §2.17): POOL_DISABLE==1 → passthrough, no pooling ---
if [[ "${POOL_DISABLE:-0}" == "1" ]]; then
    _pool_log "pool_wrapper_main: POOL_DISABLE=1 → passthrough"
    exec "$POOL_REAL_BIN" "$@"
fi
```
Delete entirely.

**Change 2**: Step d (no-pi-ancestor, lines 3631-3635):
```bash
# CURRENT (passthrough):
pool_owner_resolve
if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
    _pool_log "pool_wrapper_main: no pi ancestor → passthrough (human terminal)"
    exec "$POOL_REAL_BIN" "$@"
fi
```
Change to:
```bash
# NEW (fail-fast):
pool_owner_resolve
if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
    pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
             "For raw browser use without pooling, call 'agent-browser' directly."
fi
```

**Change 3**: Add preflight check (new function `_pool_preflight_real_bin`,
called between config init and lane logic). Checks `$POOL_REAL_BIN` exists +
is executable. If not, `pool_die` with actionable message.

**Change 4**: Update all GOTCHA/consumer comments that reference POOL_DISABLE
(lines 3585, 3598, 3606).

### 1c. pool_admin_help (lines 4578-4613)
- **Line 4609**: Remove `AGENT_BROWSER_POOL_DISABLE` line.
- Update description to mention that `agent-browser-pool <verb>` also handles
  driving commands (open, click, screenshot, etc.).
- Add a driving commands section.

## 2. bin/agent-browser-pool Changes (25 lines)

**Current dispatch**:
```bash
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
```

**New dispatch**: Change `*)` branch from error to driving:
```bash
    *) pool_wrapper_main "$@" ;;
```

Everything else stays the same. Pool verbs are handled by the case arms;
everything else (driving commands + meta commands that slip through) goes to
`pool_wrapper_main`.

## 3. bin/agent-browser — DELETE

The old PATH-shadowing shim. In the new model, `~/.local/bin/agent-browser` is
the REAL Vercel CLI (unshadowed). This file is no longer needed.

## 4. install.sh — COMPLETE REWRITE

**Current** (221 lines): Cutover installer with PATH shadowing.
**New** (~50-70 lines): Three benign things:
1. `ln -sfnv "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"`
2. Pre-create state dir via `pool_state_init`
3. Run `doctor`

No cutover warning, no `~/scripts`, no PATH-ordering verification, no
confirmation gate, no `AGENT_BROWSER_POOL_DISABLE` references.

## 5. SKILL.md — COMPLETE REWRITE (~125 lines)

**Current**: Teaches `agent-browser` (PATH-shadowing). 
**New**: Teaches `agent-browser-pool <verb>` (explicit invocation).

Key changes:
- Frontmatter description → "Drive a browser through `agent-browser-pool`"
- All examples: `agent-browser open <url>` → `agent-browser-pool open <url>`
- Remove "transparent PATH-shadowing wrapper" language
- Add: "The command never names a lane" invariant
- Remove passthrough/DISABLE discussion
- No-pi-ancestor: "fails fast" not "passes through"

## 6. references/configuration.md — UPDATE (~170 lines)

- Remove `AGENT_BROWSER_POOL_DISABLE` row from env table
- Update `AGENT_CHROME_MASTER` default: `master-profile` → real Chrome dir
- Update dispatch table: remove DISABLE passthrough, update no-pi-ancestor to fail-fast
- Update troubleshooting matrix

## 7. Skill README.md — UPDATE (~50 lines)

- Remove "transparent wrapper" language
- Remove `AGENT_BROWSER_POOL_DISABLE` pitfall mention

## 8. test/validate.sh — UPDATE

- Line 26: `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` → remove or repurpose
- Line 314: `[[ -x "$ABPOOL_WRAPPER" ]]` check → update or remove
- Lines 346-357: `selftest_config_disable` → remove entirely (tests POOL_DISABLE)
- Any other selftest or assertion using `ABPOOL_WRAPPER`

## 9. test/transparency.sh — MAJOR UPDATE (502 lines)

- All `$ABPOOL_WRAPPER` invocations → `$ABPOOL_ADMIN` (bin/agent-browser-pool)
- Item (a) `skills get core`: still passthrough via pool_dispatch_classify (meta → exec real binary). Invocation changes to `$ABPOOL_ADMIN skills get core`.
- Item (b) `--help`/`--version`: `--help` is now a pool verb (caught by dispatch → pool_admin_help). `--version` goes to pool_wrapper_main → meta → passthrough. Need to update test expectations.
- No-pi-ancestor behavior: was passthrough, now fail-fast. Any test asserting passthrough for no-pi-ancestor must change to assert pool_die.
- Item (c)-(h): invocation changes from `$ABPOOL_WRAPPER` to `$ABPOOL_ADMIN`.

## 10. test/concurrency.sh — COMMENT UPDATES

- Comment at line 12: "the wrapper (bin/agent-browser → pool_wrapper_main)" → update
- No functional changes needed (calls lib functions directly).

## 11. test/release_reaper.sh — COMMENT UPDATES

- Comments referencing "wrapper" → update
- No functional changes needed (already uses `agent-browser-pool release/reap`).

## 12. README.md — COMPLETE REWRITE

- Remove all PATH-shadowing language
- Change command examples to `agent-browser-pool <verb>`
- Update installation instructions (no `~/scripts`, no cutover)
- Remove `AGENT_BROWSER_POOL_DISABLE` references
- Update source profile default (real Chrome dir)
- Update failure modes / troubleshooting

## Dependency Graph

```
P2.M1.T1.S1 (remove POOL_DISABLE from config)
    ↓
P2.M1.T1.S2 (update pool_wrapper_main: remove DISABLE passthrough + no-pi-ancestor fail-fast)
    ↓
P2.M1.T1.S3 (add preflight check)
    ↓
P2.M2.T1.S1 (update bin/agent-browser-pool dispatch)  ←─ depends on M1 (pool_wrapper_main ready)
    ↓
P2.M2.T2.S1 (remove bin/agent-browser)                ←─ depends on M2.T1 (new entry point works)
    ↓
P2.M3.T1.S1 (rewrite install.sh)                      ←─ depends on M2 (no bin/agent-browser)
    ↓                                           ╲
P2.M4 (skill docs)  ←─ depends on M2                ╲
P2.M5 (test files)  ←─ depends on M1 + M2            ╲
                                                       ↓
P2.M6.T1.S1 (README rewrite)  ←─ depends on ALL
```

## Function Reuse Map (What Does NOT Change)

These functions in `lib/pool.sh` are UNCHANGED by this pivot:
- `_pool_log_path`, `pool_die`, `_pool_log` (utilities)
- `_pool_config_canon_path`, `_pool_config_require_uint`, `_pool_config_bool` (config helpers)
- `pool_state_init` (state dir setup)
- `pool_check_btrfs`, `pool_check_master` (prechecks)
- `_pool_atomic_write`, `_pool_json_valid`, `_pool_now`, `_pool_age_str` (helpers)
- `_pool_get_starttime`, `_pool_owner_starttime`, `pool_owner_resolve`, `pool_owner_alive` (owner identity)
- `pool_lease_write`, `pool_lease_update`, `pool_lease_read`, `pool_lease_field`, `pool_lease_exists` (lease I/O)
- `pool_lanes_list`, `pool_lease_find_mine`, `pool_lease_find_mine_any` (lease queries)
- `pool_find_free_lane`, `pool_lane_is_stale` (lane management)
- `pool_copy_master` (CoW copy)
- `pool_find_free_port`, `pool_chrome_launch`, `pool_wait_cdp` (Chrome boot)
- `pool_daemon_connect`, `pool_daemon_connected`, `pool_chrome_kill` (daemon/kill)
- `_pool_release_lane_internals`, `_pool_adopt_lane` (release/adopt)
- `_pool_acquire_critical_section`, `pool_acquire_locked` (acquire)
- `_pool_boot_write_chrome_ids`, `_pool_launch_and_verify`, `pool_boot_lane` (boot)
- `pool_ensure_connected` (self-heal)
- `pool_release_lane`, `pool_reap_stale`, `pool_reuse_orphan` (release/reap)
- `_pool_alert`, `pool_wait_for_lane` (exhaustion)
- `pool_dispatch_classify` (meta/driving classification — KEPT for meta passthrough)
- `pool_normalize_close`, `pool_normalize_connect` (arg normalization)
- `pool_strip_session_args`, `pool_force_session` (session override)
- `_pool_clean_args_is_bare_connect`, `_pool_clean_args_is_close` (arg predicates)
- `pool_admin_status`, `pool_admin_reap`, `pool_admin_release`, `pool_admin_doctor` (admin commands)
