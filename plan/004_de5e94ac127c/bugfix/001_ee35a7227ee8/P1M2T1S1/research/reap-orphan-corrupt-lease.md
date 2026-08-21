# Research: pool_reap_orphan_dirs corrupt-lease reclaim (P1.M2.T1.S1 / BUG-003)

Date: 2026-08-20 (changeset 001_ee35a7227ee8)
Host-verified by direct read of lib/pool.sh (5146 LOC current), test/bootrace.sh,
README.md, fix_design.md §4, system_context.md §7.

---

## 1. CURRENT LINE NUMBERS (shifted from the item contract's baseline)

The item says pool_reap_orphan_dirs = 3131-3202. The file has grown (harnesses feature +
landed M1 fixes); CURRENT locations (verified this session):

| Function | Item contract says | Current (2026-08-20) |
|---|---|---|
| `_pool_json_valid` | (302-345 was _pool_atomic_write) | **394** |
| `pool_lease_exists` | 968-983 | **1005-1019** |
| `pool_find_free_lane` | 1126-1135 | **1163-1171** (body 1163-1171; comment "WHY [[ -f ]] NOT pool_lease_exists" at ~1145) |
| `pool_lane_is_stale` | 1189-1225 | **1226+** |
| `pool_reap_stale` | 3040-3094 | **3297** |
| `pool_reap_orphan_dirs` | 3131-3202 | **3388-3433** (orphan branch `if ! pool_lease_exists "$base"` at **3404**; prefix-guarded rm at **3425-3428**) |
| `pool_admin_status` corrupt row | 4147-4153 | ~**4403** (`printf -- "$fmt" "$lane" "?" ... "STALE"`) |
| `pool_admin_release` numeric branch | 4394-4420 | ~**4550+** (P1.M2.T1.S2's scope) |

ALWAYS match by TEXT, never by line number.

---

## 2. THE EXACT EDIT SITE (verbatim from lib/pool.sh:3404-3431)

```bash
        # (c) Leased dir → belongs to a live lane, NOT an orphan → skip.
        #     pool_lease_exists rc 1 (no lease) inside `if !` (errexit-exempt).
        if ! pool_lease_exists "$base"; then
            dir="$POOL_EPHEMERAL_ROOT/$base"
            # (d) Orphan. Kill any Chrome still pointed at it ... [anchored pgrep/pkill block]
            local pat="user-data-dir=$dir( |\$)"
            if pgrep -f -- "$pat" >/dev/null 2>&1; then
                pkill    -f -- "$pat" 2>/dev/null || true
                sleep 0.2                        # let renderer/GPU/utility children exit
                pkill    -9 -f -- "$pat" 2>/dev/null || true
            fi
            # Prefix-guarded rm (mirror _pool_release_lane_internals). `|| true` (TOCTOU-safe).
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            _pool_log "pool_reap(orphan): removed orphan dir $dir (no lease)"
            orphans=$((orphans + 1))
        fi
```

The new corrupt-lease removal goes AFTER the `_pool_log "pool_reap(orphan): removed orphan dir..."`
line and BEFORE `orphans=$((orphans + 1))` (or after it — either is fine; keep the
orphan-count semantics: the count counts DIRS removed, unchanged; the lease removal is a
rider, logged separately, NOT counted in the dir count. `pool_admin_reap` reports
`Removed %d orphan dir(s).` from this count — the lease removal must NOT inflate it).

---

## 3. THE FIX (fix_design.md §4 seam 1, verbatim shape)

```bash
            # BUG-003: also remove a present-but-INVALID lease file. Reaching this branch
            # with the file present means it is corrupt (pool_lease_exists rc 1 = missing
            # OR corrupt; the dir is already gone) — definitionally unowned and
            # unreclaimable by ANY other verb (pool_lane_is_stale rc 2 skips it,
            # pool_find_free_lane's [[ -f ]] deliberately treats it as occupied for
            # collision safety, release N refuses) → reap is the designated reclaimer.
            # Both [[ ]] and the `! pool_lease_exists` sit in the `if` condition
            # (errexit-exempt; rc 1 is the "corrupt" signal, not an error).
            if [[ -f "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base"; then
                rm -f -- "$POOL_LANES_DIR/$base.json"
                _pool_log "pool_reap(orphan): removed corrupt lease $POOL_LANES_DIR/$base.json (BUG-003)"
            fi
```

Safety analysis:
- `$base` is validated `^[0-9]+$` at the top of the loop (line ~3403) → no path
  traversal / injection. `rm -f --` + the literal `$POOL_LANES_DIR/$base.json` path
  (same shape `_pool_release_lane_internals` uses for its lease rm).
- We are already inside the orphan branch (pool_lease_exists rc 1 established), so the
  second `pool_lease_exists "$base"` call re-probes only to distinguish "missing" (skip
  rm) from "present-but-corrupt" (rm). The `[[ -f ]]` short-circuits the common
  missing-file case → zero extra forks for the normal orphan.
- **Deliberately NOT touched** (system_context.md §7):
  - `pool_lane_is_stale` rc 2 skip (corrupt → skip) — collision safety.
  - `pool_find_free_lane`'s `[[ -f ... ]]` (comment at ~1140-1145: corrupt lease =
    occupied) — collision safety. After OUR rm, the file is gone so find_free_lane sees
    the lane free — that's the POINT.
  - `_pool_atomic_write`'s no-fsync (deliberate, documented at ~340-365; fix_design §4:
    NO code change; the reclaim paths make any corrupt lease clearable).
- `orphans` count UNCHANGED (counts dirs only) — `pool_admin_reap`'s user-facing
  `Removed %d orphan dir(s).` message stays honest.

## 4. pool_lease_exists CONTRACT (lib/pool.sh:1005-1019)

```bash
pool_lease_exists() {
    local lane="${1:-}"
    local file
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    file="$POOL_LANES_DIR/$lane.json"
    [[ -f "$file" ]] || return 1
    _pool_json_valid "$file" || return 1
    return 0
}
```
rc 0 = file present AND valid JSON. rc 1 = missing OR corrupt (or bad lane). It NEVER
exits the process (predicate). Under set -e a bare call with rc 1 ABORTS — always inside
`if !` / `if ... &&`.

`_pool_json_valid` (394) = `jq empty` syntax predicate: `printf 'not json {{{'` → rc 1
(invalid). Verified idiom; the PRD h3.2 repro uses exactly this seed.

## 5. pool_find_free_lane CONTRACT (1163-1171) — for R5's "lane un-burned" assertion

```bash
pool_find_free_lane() {
    local n
    for (( n = 1; ; n++ )); do
        if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
            printf '%s\n' "$n"; return 0
        fi
    done
}
```
Pure FILE-PRESENCE check (no port parsing). So: seed lease FILES for lanes 1-6 (any
content — even `{"port":1}`; presence is all that matters), seed nothing else → after the
fix's reap removes lanes/7.json + active/7, `pool_find_free_lane` returns 7. Before the
fix (lease file remains), it returns 8. This is the sharpest possible assertion that the
lane number was un-burned.

## 6. THE `reap` VERB (pool_admin_reap, 4492+)

`agent-browser-pool reap` → pool_config_init + pool_state_init → captures
`stale_count="$(pool_reap_stale)"` → captures `orphan_count="$(pool_reap_orphan_dirs)"`
→ prints `Reaped N stale lane(s).` / `Removed N orphan dir(s).` / or
`No stale lanes or orphan dirs found.`; rc 0 ALWAYS. Our fix is INSIDE
pool_reap_orphan_dirs — no changes to pool_admin_reap needed. The R5 test drives
`"$ABPOOL_REPO/bin/agent-browser-pool" reap` under timeout 30 (mirror r2's style).

## 7. test/bootrace.sh HARNESS FACTS (507 lines, current)

- Invocation: `bash test/bootrace.sh`; exit 0 iff all cases pass. Runner
  `_br_run_suite` has a HARDCODED case list at ~line 469-471:
  `for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e r3_control_delayed_boot_succeeds
   r3_bug002_race_e2e r3_neg_dead_ids_release_still_kills r4_bug002_preport_race; do`
  → **adding R5 requires appending `r5_bug003_corrupt_lease_reclaimed` to this list**.
- ONE suite setup: `_bootrace_setup` (mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX;
  exports HOME/AGENT_BROWSER_POOL_STATE=$BR_T/state/AGENT_CHROME_EPHEMERAL_ROOT=$BR_T/
  active/AGENT_CHROME_MASTER/AGENT_CHROME_BIN=fake-chrome/AGENT_BROWSER_REAL=fake-ab/
  AGENT_CHROME_ALLOW_SLOW_COPY=1) + EXIT/INT/TERM trap `_bootrace_teardown` (kills
  owners +wait, pkill fake patterns, rm tree). AGENTS.md §4 single-setup honored.
- Header comment at lines 31-35 says "Consumers of this harness (add cases here, do not
  fork the file): ... P1.M2 (R5–R8 minor-bug cases)" — R5 belongs HERE.
- Case style (mirror r1): plain function, `_fail "R5: ..."` + `return 1`, self-cleanup
  at the end (`rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/7"`, `rm -f -- lanes/7.json`
  etc. with `|| true`) so later cases start clean.
- Subshell-source idiom for lib calls: `( trap - EXIT INT TERM; source
  "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && <fn> )` — the `trap -` disables the
  suite's EXIT trap inside the subshell (prevents a premature teardown rm), and the
  subshell isolates set -e.
- No real chrome needed for R5: the orphan-branch pgrep finds no fake-chrome processes
  (they only run when a case launches them) → pgrep rc 1 → no kill. Pure filesystem
  case, sub-second.
- AGENTS.md: wrap the `reap` invocation in `timeout 30` (house style; r2 uses timeout 60
  for boots — reap is fast, 30 is plenty).

## 8. README.md `reap` SECTION (line 236)

Current text (verified):
```
### `reap`

Tear down lanes whose owning harness process has died (kill the Chrome process group, delete the
ephemeral profile dir, remove the lease) **and** remove orphan ephemeral dirs (numeric
`active/<N>/` directories left by an interrupted boot or a crashed release that have no
lease and no live owner — killing any orphaned Chrome still pointed at them). Always exits 0.
```
Mode A addition (one sentence, rides with this subtask): after "...still pointed at them)"
add: "A corrupt/unparseable `lanes/<N>.json` left behind after its lane dir is gone is
also removed, freeing the lane number."

## 9. TASK BOUNDARY (S1 vs S2)

| Concern | S1 (THIS) | S2 (release-side seam) |
|---|---|---|
| pool_reap_orphan_dirs removes corrupt lease after dir gone | ✅ HERE | — |
| R5 bootrace case | ✅ HERE | — |
| README reap sentence | ✅ HERE (Mode A) | — |
| pool_admin_release numeric branch treats corrupt as releasable | — | ✅ P1.M2.T1.S2 |
| fsync in _pool_atomic_write | — NO CODE CHANGE (fix_design §4 decision; optionally a comment) | — |
| pool_lane_is_stale rc 2 / pool_find_free_lane [[ -f ]] | — UNTOUCHED (collision safety) | — |

S1 has NO code dependency on S2 (may land in parallel — item contract §2).