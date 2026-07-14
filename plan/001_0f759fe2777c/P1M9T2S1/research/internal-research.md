# Research: Concurrency Test Scavenging (PRD §2.18 — N parallel agents → distinct lanes)

> Purpose: extract EVERY fact relevant to writing the CONCURRENCY test for
> `agent-browser-pool` (PRD §2.18: "N parallel agents (distinct owner PIDs) must
> each get a distinct lane; assert no two share a lane and all release cleanly with
> no leftover dirs/processes"). All facts are host-verified or cited to a primary
> source (the landed `lib/pool.sh`, the landed `test/validate.sh`, the PRD, and the
> completed PRPs). **This is research only — no files were modified.**
>
> Source files read in full:
> - `plan/001_0f759fe2777c/architecture/key_findings.md`
> - `plan/001_0f759fe2777c/architecture/external_deps.md`
> - `plan/001_0f759fe2777c/architecture/system_context.md`
> - `plan/001_0f759fe2777c/prd_snapshot.md`
> - `plan/001_0f759fe2777c/P1M5T1S1/PRP.md` (flock critical section)
> - `plan/001_0f759fe2777c/P1M5T2S1/PRP.md` (release/teardown)
> - `plan/001_0f759fe2777c/P1M4T2S2/PRP.md` (Chrome launch + CDP wait)
> - `plan/001_0f759fe2777c/P1M4T1S1/PRP.md` (master copy + reflink)
> - `plan/001_0f759fe2777c/P1M9T1S1/research/test-framework-facts.md` + `external-research.md`
> - `lib/pool.sh` (the LANDED implementation — primary source of truth)
> - `test/validate.sh` (the LANDED framework — primary source of truth)

---

## Summary

The concurrency guarantee rests on a **short flock** (`pool_acquire_locked`,
`lib/pool.sh:~2033`) that **serializes only the lane-number scan+claim**; each
serialized claimer runs `pool_find_free_lane` → writes a **provisional lease**
(`port:0, chrome_pid:0, connected:false`) → releases the lock. The full **boot**
(copy → port → launch Chrome → wait CDP → connect daemon) then runs **outside**
the lock (`pool_boot_lane`, `lib/pool.sh:~2192`), so N agents boot N Chromes
**in parallel** but each holds a **distinct lane number**. Release is **idempotent
+ non-fatal** (`pool_release_lane` always returns 0; `lib/pool.sh:~2439`), and the
test framework's 5 assertion helpers + `spawn_sim_owner` are already landed in
`test/validate.sh`. The two sharp edges for the concurrency test: (1) the
owner-PID override sets the lease **identity** but does NOT fake the
**kernel-visible process** — the test must spawn N **real** `comm=="pi"` processes;
(2) `pool_find_free_port` runs **outside** the flock, so port allocation has a
narrow TOCTOU window (mitigated by writing the port to the lease **before** launch).

---

## §1. The Concurrency Contract — flock serializes lane assignment; boots are concurrent

### 1.1 The flock idiom + the short-critical-section invariant

**`pool_acquire_locked()`** (`lib/pool.sh:~2033`) is the PUBLIC entry point. Its
entire body is the canonical flock idiom:

```bash
pool_acquire_locked() {
    pool_state_init                              # ensure lock file + lanes dir exist
    (
        flock 9
        _pool_acquire_critical_section           # scan + reap + reuse + choose + claim
    ) 9>"$POOL_LOCK_FILE"
}
```
— `lib/pool.sh:~2046-2055`. The lock **auto-releases on subshell exit** (the kernel
closes fd 9), including on `pool_die`/SIGKILL — NO trap is needed.
[Source: `lib/pool.sh:~2033-2055`; `key_findings.md` FINDING 2; PRP `P1M5T1S1/PRP.md` §1.2]

**FINDING 2 (key_findings.md) — verbatim:**
> "claim under flock, boot Chrome AFTER releasing — no launch/copy/wait inside the lock"

This is THE design principle. The flock is held ONLY for: scan lanes (`pool_lanes_list`),
reap stale (`_pool_release_lane_internals`), reuse-orphan (`_pool_adopt_lane`), choose-N
(`pool_find_free_lane`), claim (`pool_lease_write` provisional). **NO** `setsid`, `cp -a`,
or CDP wait inside the lock.

### 1.2 The critical-section body — lane assignment is serialized + deterministic

**`_pool_acquire_critical_section()`** (`lib/pool.sh:~1966`) runs inside the flock
subshell (functions are inherited by `( … )` subshells). Its lane-assignment logic:

1. **Guard**: `[[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1`
   (passthrough owner must not claim) — `lib/pool.sh:~1978`.
2. **REAP-STALE + REUSE-ORPHAN** (interleaved per lane in ascending order):
   `for n in $(pool_lanes_list); do if pool_lane_is_stale "$n"; then …; fi; done`
   — `lib/pool.sh:~1983-2003`. Stale + responsive Chrome → adopt; stale + dead →
   `_pool_release_lane_internals`.
3. **CHOOSE-N**: `N="$(pool_find_free_lane)"` — `lib/pool.sh:~2007`.
4. **CLAIM**: `pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" … 0 0 "false"`
   — writes a **provisional lease** (`port:0, chrome_pid:0, chrome_pgid:0, connected:false`).
   — `lib/pool.sh:~2012-2015`.
5. `printf '%s\n' "$N"; return 0` — `lib/pool.sh:~2018`.

**`pool_find_free_lane()`** (`lib/pool.sh:~1130`) — the lane-number allocator:
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
— `lib/pool.sh:~1147-1155`. **ALWAYS echoes a value + returns 0** (no exhaustion
state). A lane is "free" iff BOTH the ephemeral dir is absent AND the lease file is
absent. The `[[ -f ]]` (not `pool_lease_exists`) treats a **present-but-corrupt**
lease as **occupied** → prevents collision. Because this runs **inside the flock**,
two concurrent acquires are **serialized**: the first picks lane 1 (writes
`lanes/1.json`), the second sees lane 1 occupied → picks lane 2. **N concurrent
acquires → N distinct lane numbers, guaranteed.**
[Source: `lib/pool.sh:~1130-1156`; PRP `P1M3T2S2/PRP.md`; PRP `P1M5T1S1/PRP.md` success criteria "Two distinct simulated owners … acquire two distinct lanes (1 and 2)"]

### 1.3 The boot happens AFTER lock release — concurrent boots

**`pool_boot_lane(LANE)`** (`lib/pool.sh:~2192`) is called by the wrapper AFTER
`pool_acquire_locked` returns a provisional lane. It does NO locking. Its sequence
(§2 below) runs **concurrently** across N agents — each agent has already claimed
its distinct lane under the flock, so the boots don't contend on lane numbers.
[Source: `lib/pool.sh:~2192-2250`; PRD §2.4 step 3e-3j; `key_findings.md` FINDING 2]

**ANSWER to Key Question A: YES.** The acquire critical section (under flock)
GUARANTEES N concurrent acquires get N distinct lane numbers. `flock` serializes the
scan+claim; `pool_find_free_lane` picks the lowest free N (dir absent AND lease
absent); the provisional lease is written atomically (`_pool_atomic_write` = tmp+mv
on same FS). Boot (`pool_boot_lane`) happens AFTER lock release → boots are
concurrent but lane assignment is serialized.
[Source: `lib/pool.sh:~1966-2055`, `~1130-1156`; `key_findings.md` FINDING 2, FINDING 7; PRD §2.4 step 3a-3d, §2.19]

---

## §2. The Boot Sequence + Timing (per lane, OUTSIDE the flock)

### 2.1 `pool_boot_lane(LANE)` — the full post-lock boot (`lib/pool.sh:~2192-2250`)

| Step | Call | Purpose | Fatal? |
|------|------|---------|--------|
| a. COPY | `pool_copy_master "$ephemeral_dir"` | reflink CoW copy of master → ephemeral dir; rm Singleton* locks | **pool_die** (non-btrfs / slow-copy-fail) |
| b. PORT | `port="$(pool_find_free_port)"` → `pool_lease_update "$lane" port "$port"` | lowest free TCP port; **write to lease BEFORE launch** (anti-collision) | rc 1 → cleanup + return 1 |
| c+d. LAUNCH+WAIT | `_pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"` | `pool_chrome_launch` + early-write chrome_ids + `pool_wait_cdp`, **retry once** | rc 1 (2× timeout) → cleanup + return 1 |
| e. CONNECT | `pool_daemon_connect "abpool-$lane" "$port"` | bind daemon session to Chrome | rc 1 → cleanup (kills LIVE chrome) + return 1 |
| f. UPDATE LEASE | `pool_lease_update "$lane" connected true` + `last_seen_at` | finalize | — |
— `lib/pool.sh:~2208-2248`. Every recoverable failure → `_pool_release_lane_internals "$lane"` + return 1.

### 2.2 `pool_copy_master(target_dir)` — the reflink copy (`lib/pool.sh:~1253`)

```bash
cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null
# on failure (non-btrfs): rm -rf partial; if POOL_ALLOW_SLOW_COPY==1: cp -a; else pool_die
rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie" "$target_dir/SingletonSocket"
```
— Instant on btrfs (~17 ms host-verified). **Loud refusal** on non-btrfs unless
`POOL_ALLOW_SLOW_COPY=1`. The master is **read-only** (never launched/mutated/deleted).
[Source: `lib/pool.sh:~1253-1312`; PRP `P1M4T1S1/PRP.md`; PRD §2.7, §2.19; `external_deps.md` §3; `system_context.md` §8]

### 2.3 `pool_find_free_port()` — lowest free TCP port (`lib/pool.sh:~1380`)

Range: `[POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE)` = **[53420, 54420)**
(defaults, `lib/pool.sh:~159-160`). A port is "free" when ALL of:
1. NOT claimed by any live lease's `.port` (provisional `port:0` does NOT count —
   `[[ "$p" -gt 0 ]]` filter, `lib/pool.sh:~1407-1410`);
2. NOT shown listening by `ss -tlnH` (snapshot ONCE, `:$port ` trailing-space word
   boundary, `lib/pool.sh:~1414-1420`);
3. NOT answering `curl -sf --max-time 2 /json/version` (live non-pool Chrome,
   `lib/pool.sh:~1421-1424`).

**Runs OUTSIDE the flock** → TOCTOU tolerated (see §7 gotcha G). Returns 0 + echoes
port, or rc 1 (exhaustion, non-fatal).
[Source: `lib/pool.sh:~1380-1435`; PRP `P1M4T2S1/PRP.md`; `external_deps.md` §2.3]

### 2.4 `pool_chrome_launch(port, user_data_dir, lane)` — the setsid launch (`lib/pool.sh:~1471`)

```bash
flags=(
    --remote-debugging-port="$port"
    --user-data-dir="$user_data_dir"          # ABSOLUTE (PRD §2.2)
    --no-first-run --no-default-browser-check
    --disable-background-timer-throttling
    --disable-backgrounding-occluded-windows
    --disable-renderer-backgrounding
    --disable-features=CalculateNativeWinOcclusion
    --disable-back-forward-cache
)
[[ "$POOL_HEADLESS" == "1" ]] && flags+=(--headless=new)
setsid -- "$POOL_CHROME_BIN" "${flags[@]}" >"$POOL_STATE_DIR/chrome-$lane.log" 2>&1 &
POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID
pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
# … [[ -z "$pgid" ]] → pool_die (instant-exit guard)
POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID   # == POOL_CHROME_PID (setsid contract)
```
— `lib/pool.sh:~1518-1537`. `setsid` (NO `--fork`) → Chrome is its own session/group
leader → **`pgid == pid`** (host-verified). Exports `POOL_CHROME_PID` +
`POOL_CHROME_PGID` (the teardown handle). `pool_die` on bad args / instant Chrome
death / missing log dir.
[Source: `lib/pool.sh:~1471-1540`; PRP `P1M4T2S2/PRP.md`; `external_deps.md` §2.1; `key_findings.md` FINDING 6]

### 2.5 `pool_wait_cdp(port)` — CDP readiness wait (`lib/pool.sh:~1571`)

```bash
local -ri POOL_CDP_TRIES=60    # ×0.5s sleep = 30s budget
for (( i = 0; i < POOL_CDP_TRIES; i++ )); do
    if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
done
# timeout: kill -- -"$POOL_CHROME_PGID" (if numeric); return 1
```
— `lib/pool.sh:~1602-1614`. **Budget: 60 × 0.5s = 30s.** Host-observed CDP ready
~0.5s. `curl -sf` rc 7 (connection-refused, Chrome booting) → keep looping; rc 0
(HTTP 200) → ready. On timeout: kills the Chrome pgroup + returns 1 (NON-FATAL —
caller owns retry). The 15s figure in PRD §2.4 step 3h / §2.14 is a **stale
summary**; 30s is authoritative (CONTRACT 3b + `external_deps.md` §2.2).
[Source: `lib/pool.sh:~1571-1617`; PRP `P1M4T2S2/PRP.md` §7; `external_deps.md` §2.2]

### 2.6 `_pool_launch_and_verify` — retry-once (`lib/pool.sh:~2080`)

`pool_chrome_launch` → `_pool_boot_write_chrome_ids` (early-write `chrome_pid`/
`chrome_pgid` to lease — LEAK-PREVENTION) → `pool_wait_cdp`. On rc 1 (Chrome pgroup
already killed): retry once (PRD §2.14 "retry launch once; then fail, drop lane").
Second timeout → return 1.
[Source: `lib/pool.sh:~2080-2120`; PRP `P1M5T1S2/PRP.md`]

**Approximate boot timing per lane:** copy ~17 ms (reflink) + port probe ~ms +
Chrome launch+CDP ~0.5-2s + daemon connect ~ms ≈ **1-3s per lane**. N concurrent
boots ≈ **1-3s wall** (parallel), NOT N×.

---

## §3. The Release / Cleanup Contract

### 3.1 `pool_release_lane(LANE)` — PUBLIC, idempotent, non-fatal (`lib/pool.sh:~2439`)

```bash
pool_release_lane() {
    local lane="${1:-}" json session
    [[ "$lane" =~ ^[0-9]+$ ]] || return 0                          # (a) validate
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi   # (b) idempotent no-op
    session="$(jq -r '.session' <<<"$json")"
    [[ -n "$session" && "$session" != "null" ]] || session="abpool-$lane"
    if [[ -n "${POOL_REAL_BIN:-}" ]]; then
        "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true      # (c) disconnect daemon
    fi
    _pool_release_lane_internals "$lane"                            # (d) KILL + RM DIR + RM LEASE
    _pool_log "pool_release: released lane $lane …"; return 0
}
```
— `lib/pool.sh:~2440-2486`. **Always returns 0. NEVER `pool_die`. NEVER non-zero.**
Idempotent: missing lease → return 0 (no-op); double-release → rc 0, rc 0;
provisional lease (`chrome_pid:0`) → `pool_chrome_kill 0 0` is a safe no-op;
Chrome already dead → kill no-op, dir+lease still removed. `close` rc is ALWAYS 0
on agent-browser 0.28.0 (host-verified; disconnect-only — Chrome survives it; the
session LINGERS harmlessly).
[Source: `lib/pool.sh:~2439-2487`; PRP `P1M5T2S1/PRP.md`; PRD §2.5; `external_deps.md` §1.3]

### 3.2 `_pool_release_lane_internals(LANE)` — the KERNEL (`lib/pool.sh:~1813`)

The release kernel, shared by acquire's in-lock REAP-STALE, the public
`pool_release_lane`, and the reaper:

1. `pool_lease_read "$lane"` → rc 1 (missing/corrupt) → return 0.
2. ONE jq fork: extract `.chrome_pid, .chrome_pgid, .ephemeral_dir`.
3. `pool_chrome_kill "$chrome_pid" "$chrome_pgid"` — **SIGTERM pgroup → sleep 0.5 →
   SIGKILL pgroup → bare-pid fallback**; every kill `2>/dev/null || true`; numeric
   guards skip 0/0 (provisional). `lib/pool.sh:~1745-1762`.
4. `rm -rf -- "$POOL_EPHEMERAL_ROOT/$lane"` — **RECONSTRUCTED** from lane number
   (NOT trusted from lease) + **prefix-guarded** (`== "$POOL_EPHEMERAL_ROOT"/*`).
   `lib/pool.sh:~1844-1854`.
5. `rm -f -- "$POOL_LANES_DIR/$lane.json"` — delete lease. `lib/pool.sh:~1860`.
return 0 always.
[Source: `lib/pool.sh:~1813-1866`; PRP `P1M5T1S1/PRP.md`; `key_findings.md` FINDING 6]

### 3.3 `pool_admin_release` — the `release all` CLI path (`lib/pool.sh:~3854`)

`bin/agent-browser-pool release all` → `pool_admin_release all` → snapshots
`pool_lanes_list` → calls `pool_release_lane "$lane"` EACH (rc 0 always) → prints
`"Released N lane(s)."`. This is what the test framework's `teardown()` invokes as a
subprocess (`"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true`).
[Source: `lib/pool.sh:~3854-3925`; PRP `P1M7T3S1/PRP.md`; PRD §2.12]

**ANSWER to Key Question C:** release does: (1) daemon `close` (disconnect-only),
(2) `pool_chrome_kill` (SIGTERM→SIGKILL the whole pgroup + bare-pid fallback), (3)
`rm -rf` the reconstructed prefix-guarded ephemeral dir, (4) `rm -f` the lease file.
**It IS idempotent — rc 0 always, never `pool_die`.**
[Source: `lib/pool.sh:~2439-2487`, `~1813-1866`]

---

## §4. The EXACT Cleanup Assertions (PRD §2.18)

PRD §2.18 (verbatim from `prd_snapshot.md` §2.18):
> "The main interactive `pi` is long-lived, so a lease it takes persists until
> explicit release — every test must call `agent-browser-pool release`/`reap` and
> assert the ephemeral dir + Chrome process group are gone."

The test framework's 5 assertion helpers (LANDED in `test/validate.sh`) realize
this contract:

| Helper | Signature | Asserts | Source |
|--------|-----------|---------|--------|
| `assert_eq` | `EXPECTED ACTUAL [LABEL]` | string equality | `test/validate.sh:~73` |
| `assert_lane_exists` | `N` | `$POOL_LANES_DIR/$N.json` is present (file) | `test/validate.sh:~84` |
| `assert_lane_gone` | `N` | **NO** lease file AND **NO** ephemeral dir for N | `test/validate.sh:~93` |
| `assert_no_dir` | `PATH` | PATH does not exist (file/dir/symlink) | `test/validate.sh:~103` |
| `assert_no_chrome` | `[ROOT]` | **NO** Chrome process matching `pgrep -f -- "user-data-dir=$ROOT"` (default `$POOL_EPHEMERAL_ROOT`) | `test/validate.sh:~111` |

**What EXACTLY must be gone after a concurrency test's release-all:**
1. **No lease files**: `assert_lane_gone N` for each lane N → no
   `$POOL_LANES_DIR/$N.json`. (Equivalently: `pool_lanes_list` enumerates nothing.)
2. **No ephemeral dirs**: `assert_lane_gone N` → no `$POOL_EPHEMERAL_ROOT/$N`. (Or
   `assert_no_dir "$POOL_EPHEMERAL_ROOT/$N"`.)
3. **No Chrome processes scoped to the ephemeral root**: `assert_no_chrome`
   (no `ROOT` arg → uses `$POOL_EPHEMERAL_ROOT`) → `pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"`
   returns nothing. This is **scoped** — it does NOT false-positive the operator's
   daily-driver Chrome (whose `--user-data-dir` is `~/.config/google-chrome`).
4. **No lingering lease**: covered by (1).

**ANSWER to Key Question D:** the cleanup contract is: no `lanes/<N>.json`, no
`active/<N>/` ephemeral dirs, no Chrome processes scoped to the ephemeral root via
`pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"`. The `assert_no_chrome` helper
does the scoped Chrome check; `assert_lane_gone N` does lease+dir; `pool_release_lane`
(idempotent rc 0) is the release mechanism.
[Source: `test/validate.sh:~73-119`; `test-framework-facts.md` §1.3, §3.5; PRD §2.18]

**NOTE on `assert_no_chrome` for concurrency:** a single Chrome instance is MANY
processes (renderer/GPU/utility). Use the BOOLEAN form (`pgrep … >/dev/null` as an
`if` condition), NOT `pgrep -c` for a count. `pgrep` returns rc 1 on no-match → it
MUST be the `if` condition (errexit-exempt), never a bare statement.
[Source: `test-framework-facts.md` §3.5; `external-research.md` §6]

---

## §5. Real-Chrome Requirements (master + headless)

### 5.1 Real Chrome is REQUIRED (PRD §2.18)

PRD §2.18 (verbatim):
> "Smoke tests launch a real, windowed Chrome — on Hyprland that pops a visible
> window. For unattended harness runs set `AGENT_CHROME_HEADLESS=1` (plumbing tests
> only; headless trips some anti-bot walls, so it's not valid for trusted-profile
> wall-passing validation)."

**For the concurrency test (a plumbing test), `AGENT_CHROME_HEADLESS=1` is REQUIRED.**
The test framework's `setup()` already exports it: `export AGENT_CHROME_HEADLESS=1`
(`test/validate.sh:~166`). `pool_config_init` normalizes this to `POOL_HEADLESS="1"`
→ `pool_chrome_launch` adds `--headless=new`.
[Source: PRD §2.18; `test/validate.sh:~166`; `lib/pool.sh:~155-157`, `~1530`]

### 5.2 The master profile must EXIST + be on btrfs

- **Location**: `$AGENT_CHROME_MASTER` (default `$HOME/.agent-chrome-profiles/master-profile`).
  PRD §2.11, §O4; `external_deps.md` §5; `system_context.md` §8.
- **Size**: 4.8 GB (verified). `system_context.md` §8; PRD §1.1.
- **Must exist + be non-empty** or `pool_check_master` `pool_die`s with the exact
  `cp -a --reflink=always <profile> "$POOL_MASTER_DIR"` bootstrap command (PRD §2.14).
  `lib/pool.sh:pool_check_master` (M1.T1.S3).
- **btrfs required** at the ephemeral root (or `AGENT_CHROME_ALLOW_SLOW_COPY=1`):
  `pool_copy_master` does `cp -a --reflink=always` which FAILS loudly on non-btrfs.
  `lib/pool.sh:~1289-1312`; PRD §2.7, §2.19.

### 5.3 ⚠️ CRITICAL GAP for the concurrency test — the framework's default master is EMPTY

The test framework's `setup()` points `AGENT_CHROME_MASTER` at a **temp dir**
(`$ABPOOL_TEST_ROOT/master`, `mkdir -p`'d but EMPTY — `test/validate.sh:~164`).
`test-framework-facts.md` §1.7 confirms: **"No master profile under the real root
(`~/.agent-chrome-profiles/master-profile` absent on this checkout)"**. The M9.T1.S1
self-test is **Chrome-free by design** (exercises the framework, not the pool
lifecycle).

**For the concurrency test (M9.T2.S1), the test body MUST:**
1. Override `AGENT_CHROME_MASTER` to point at a **real, non-empty master profile**
   (e.g. copy the real `~/.agent-chrome-profiles/master-profile`, or build a minimal
   one: `mkdir -p "$M/Default"; echo prefs > "$M/Preferences"`).
2. Ensure `AGENT_CHROME_EPHEMERAL_ROOT` is on **btrfs** (the default `$HOME`-anchored
   `~/.agent-chrome-profiles/active` IS on btrfs — `system_context.md` §8 verified
   `/dev/nvme1n1p2[/@home] btrfs`), OR set `AGENT_CHROME_ALLOW_SLOW_COPY=1` if using
   a tmpfs `mktemp` root (but a 4.8 GB real copy per lane × N would be catastrophically
   slow — use btrfs).
3. The simplest hermetic approach: set `AGENT_CHROME_EPHEMERAL_ROOT` to a btrfs
   subdir under `$HOME` (e.g. `$HOME/.abpool-concurrency-test/active`) and
   `AGENT_CHROME_MASTER` to the real master (or a btrfs copy of it). This keeps the
   test off the operator's real `active/` while staying on btrfs.

**ANSWER to Key Question E:** YES, real headless Chrome is required
(`AGENT_CHROME_HEADLESS=1`). The master must exist (4.8 GB at
`$AGENT_CHROME_MASTER`). The framework's default temp master is EMPTY → the
concurrency test must supply a real master + a btrfs ephemeral root.
[Source: PRD §2.18, §2.11, §2.7, §2.14; `test/validate.sh:~164`; `test-framework-facts.md` §1.7; `system_context.md` §8]

---

## §6. The Test Framework Helper API (verbatim, from LANDED `test/validate.sh`)

The framework is LANDED and dual-mode (source vs execute via the `BASH_SOURCE` gate).
The concurrency test will `source test/validate.sh` and define `test_*` functions,
then call `abpool_run_suite test_`.

### 6.1 Constants + globals (module-level)

```bash
ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"      # the wrapper shim (absolute)
ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"   # the admin CLI (absolute)
ABPOOL_PASS=0; ABPOOL_FAIL=0; declare -a ABPOOL_FAILED=()
ABPOOL_TMP_ROOT=""           # suite temp root (trap removes it)
ABPOOL_TEST_ROOT=""          # per-test temp root (set by setup)
ABPOOL_CUR_OWNER=""          # the simulated owner PID for the CURRENT test
declare -a ABPOOL_SIM_BINS=() # temp dirs holding "pi" binaries
```
— `test/validate.sh:~43-54`.

### 6.2 The 5 assertion helpers + `_fail` + `spawn_sim_owner` (verbatim signatures)

```bash
_fail MSG                                                    # record failure + return 1; NEVER exits
assert_eq EXPECTED ACTUAL [LABEL]                            # string equality
assert_lane_exists N                                         # $POOL_LANES_DIR/N.json present
assert_lane_gone N                                           # NO lease file AND NO ephemeral dir for N
assert_no_dir PATH                                           # PATH does not exist
assert_no_chrome [ROOT]                                      # no Chrome under --user-data-dir=$ROOT (default $POOL_EPHEMERAL_ROOT)
spawn_sim_owner [SECONDS]                                    # echo PID of a LIVE process whose /proc/comm=="pi"
```
— `test/validate.sh:~66-148`. Full bodies in §4 above + `test-framework-facts.md` §3/§4.

**`spawn_sim_owner` is THE engine for owner simulation.** It copies `/usr/bin/sleep`
to a temp file named `pi`, execs it (`"$bin" "$dur" &`), and **settles** (polls
`/proc/$pid/comm` until it reads `pi` — the fork→execve race window otherwise returns
the parent's comm "bash"). Returns the PID. **The concurrency test MUST call this N
times to get N distinct live `pi` owners.**
[Source: `test/validate.sh:~119-148`; `test-framework-facts.md` §2]

### 6.3 `setup()` / `teardown()` (hermetic isolation)

```bash
setup() {
    # mktemp -d temp root; export HOME, AGENT_BROWSER_POOL_STATE,
    #   AGENT_CHROME_EPHEMERAL_ROOT, AGENT_CHROME_MASTER (all under temp root);
    #   export AGENT_CHROME_HEADLESS=1; pool_config_init; pool_state_init;
    #   spawn ONE sim owner; export AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME.
}
teardown() {
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true   # SUBPROCESS (pool_die-safe)
    kill "$ABPOOL_CUR_OWNER" 2>/dev/null || true
}
```
— `test/validate.sh:~156-186`. **`setup` spawns exactly ONE sim owner per test.** For
the concurrency test, the test BODY must spawn the OTHER N-1 owners (each with its own
`AGENT_BROWSER_POOL_OWNER_PID` exported into the respective agent's subprocess env).
[Source: `test/validate.sh:~156-186`; `test-framework-facts.md` §1.4-§1.6]

### 6.4 `run_test NAME FN` + `abpool_run_suite [PREFIX]`

```bash
run_test() {
    setup
    ( set -e; "$fn" ) || rc=$?    # body in SUBSHELL → failure is non-fatal to harness
    teardown
    if (( rc == 0 )); then ABPOOL_PASS=$((ABPOOL_PASS+1)); else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$name"); fi
}
abpool_run_suite() {
    local prefix="${1:-test_}" fn
    for fn in $(compgen -A function | grep "^${prefix}" | sort); do run_test "$fn" "$fn"; done
    # prints summary; returns 1 iff any failed
}
```
— `test/validate.sh:~193-220`. The concurrency test defines e.g. `test_concurrent_distinct_lanes`
and the suite runner picks it up. **All counters use `$(( ))` expansion (always
errexit-safe); `(( ))` only inside `if`.**
[Source: `test/validate.sh:~193-220`; `test-framework-facts.md` §3.1, §3.2]

### 6.5 The source-vs-execute gate

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! abpool_run_suite selftest_; then exit 1; fi
fi
```
— `test/validate.sh:~283-287`. When SOURCED (the concurrency test's mode), the
self-test does NOT run; the caller defines `test_*` and calls `abpool_run_suite test_`.

---

## §7. Gotchas for Concurrent Boots

### G1. The owner-PID override does NOT fake the kernel-visible process (THE pivotal constraint)

`AGENT_BROWSER_POOL_OWNER_PID` sets the lease's owner **identity** (pid + comm="pi"
+ starttime). But `pool_owner_alive` (`lib/pool.sh:~616`) reads the **REAL**
`/proc/<pid>/comm` and requires it to be literally `"pi"`. So for a lease to be
"mine" (reuse) or "live" (not stale), the PID must point at a **real running process
with `comm=="pi"`**. The env override does NOT fake this.
**⇒ The concurrency test MUST spawn N real `pi`-comm processes** (via
`spawn_sim_owner`, which copies `/usr/bin/sleep` to a file named `pi`). Each agent's
subprocess gets a DISTINCT `AGENT_BROWSER_POOL_OWNER_PID` = its sim owner's PID.
[Source: `test-framework-facts.md` §1.2, §2; `lib/pool.sh:~478-510` (pool_owner_resolve), `~616-660` (pool_owner_alive)]

### G2. `pool_find_free_port` runs OUTSIDE the flock — narrow TOCTOU on ports

`pool_find_free_port` (`lib/pool.sh:~1380`) runs in `pool_boot_lane` (post-lock). Its
docstring (verbatim, `lib/pool.sh:~1388`):
> "GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can
> both pick the same port — the launch (M4.T2.S2) is authoritative + retries on
> EADDRINUSE."

**Mitigation in the design:** `pool_boot_lane` writes the port to the lease
**BEFORE** launch (`pool_lease_update "$lane" port "$port"`, `lib/pool.sh:~2220`,
commented "Anti-collision: write port to the lease BEFORE launch"). So once lane A
writes port X, lane B's `pool_find_free_port` claimed-set sees X → skips it. The
TOCTOU window is only between two concurrent `pool_find_free_port` calls where
neither has written yet.

**⚠️ CAVEAT for the test:** the docstring says "the launch retries on EADDRINUSE,"
but `pool_chrome_launch` actually `pool_die`s on instant Chrome exit (it does NOT
retry on EADDRINUSE — `_pool_launch_and_verify` retries only on CDP-timeout, not on
bind failure). So a true port collision would be FATAL (pool_die → the agent
subshell exits non-zero). For the concurrency test with small N (3-5) and slightly
staggered launches, the write-before-launch almost always wins. **If the test sees
spurious pool_die on Chrome instant-exit, suspect a port collision** — mitigate by
staggering agent launches by ~0.2-0.5s, or by accepting that N must be small enough
that the window doesn't bite.
[Source: `lib/pool.sh:~1380-1435`, `~2220`, `~1525-1537`; PRP `P1M4T2.S1/PRP.md`; PRP `P1M4T2S2/PRP.md` §5]

**ANSWER to Key Question G:** `pool_find_free_port` runs AFTER the flock (in
`pool_boot_lane`). N concurrent boots CAN race for the same port in a narrow TOCTOU
window. The mitigation is writing the port to the lease BEFORE launch (so
subsequent `find_free_port` calls see it claimed). The race is real but narrow;
stagger launches if it bites.

### G3. Concurrent reflink copies of the same master are SAFE

`cp -a --reflink=always` is a **read-only** operation on the source (CoW shares
blocks until write; the master is never mutated). N simultaneous reflink copies of
the same master are safe — btrfs refcounts the shared blocks. PRD §2.7: "master-profile
is read-only as far as the wrapper is concerned: never launched, never mutated,
never deleted." No lock is needed around the copy.
**ANSWER to Key Question F:** YES, N simultaneous reflink copies of the same master
work safely — btrfs CoW; the master is read-only.
[Source: PRD §2.7; `external_deps.md` §3; `system_context.md` §8; PRP `P1M4T1S1/PRP.md`]

### G4. The `local var=$(...)` errexit-masking gotcha (SC2155)

`local x="$(failing_cmd)"` does NOT abort under `set -e` — `local` always returns 0,
so the failure is silently swallowed. **EVERY capture in the test must be split:**
`local x; x="$(...)"`. This applies to capturing lane numbers, ports, PIDs from
`pool_lease_field`, `pool_acquire_locked`, etc. The framework's helpers already
follow this; the test body must too.
[Source: `test-framework-facts.md` §3.3, §4.1; `external-research.md` §4.1; `lib/pool.sh` throughout]

### G5. `pool_lane_is_stale` / `pool_lease_exists` / `pool_lease_read` / `pool_lease_find_mine` / `pool_find_free_port` return non-zero on the "happy" path — GUARD them

Under `set -e`, a BARE call that returns rc 1 ABORTS the caller. These all return
rc 1 on a legitimate "not found / not stale / exhausted" condition:
- `pool_lease_read N` → rc 1 on missing/corrupt
- `pool_lease_exists N` → rc 1 on missing/corrupt/non-numeric
- `pool_lane_is_stale N` → TRI-STATE (0=stale / 1=live / 2=no-lease) — a bare call
  aborts on rc 1 or 2
- `pool_lease_find_mine` → rc 1 if no valid lease
- `pool_find_free_port` → rc 1 on exhaustion

**Always guard:** `if …; then …; fi` or `… || true` or `if ! x="$(…)"`. The
framework's `assert_lane_exists` deliberately uses `[[ -f ]]` (not `pool_lease_exists`)
to avoid this. For the concurrency test's "read each lane's owner.pid/port/chrome_pid"
assertion, use `pool_lease_field N field` guarded, or read the JSON directly with `jq`.
[Source: `test-framework-facts.md` §1.3, §3.3; `lib/pool.sh` docstrings for each function]

### G6. `kill -0` is a TRAP for liveness — use `/proc` or `pgrep`

`kill -0 $pid` returns rc 1 for BOTH `ESRCH` (dead) AND `EPERM` (alive but not
yours) — the shell cannot tell them apart. **Never use `kill -0` for assertions.**
Use `pgrep -f` (the `assert_no_chrome` approach) or `/proc/<pid>` existence.
[Source: `test-framework-facts.md` §3.3; `external-research.md` §4.3, §6; `lib/pool.sh:~640`]

### G7. The fork→execve race window in `spawn_sim_owner`

After `"$bin" "$dur" &`, the child exists (fork) but has NOT yet called
`execve("…/pi")` — for a few hundred µs it shows the PARENT's comm ("bash"). Reading
`/proc/$pid/comm` or `starttime` in that window returns the WRONG value. `spawn_sim_owner`
**settles** (polls until comm=="pi"). **The concurrency test must NOT read the sim
owner's starttime before `spawn_sim_owner` returns** — it already settles internally.
[Source: `test-framework-facts.md` §2 (GOTCHA); `test/validate.sh:~137-145`]

### G8. One owner ≤ one lane (PRD §2.8 invariant)

PRD §2.8: "One owner holds ≤1 lane (enforced at acquire step 2)." `pool_lease_find_mine`
(`lib/pool.sh:~1003`) scans for an existing valid lease for the current owner BEFORE
acquire. So if the same `AGENT_BROWSER_POOL_OWNER_PID` is used for two "agents," the
second will REUSE the first's lane (not get a new one). **⇒ Each of the N concurrent
agents MUST have a DISTINCT `AGENT_BROWSER_POOL_OWNER_PID`** (N distinct `spawn_sim_owner`
calls). This is the core of the concurrency test.
[Source: PRD §2.8; `lib/pool.sh:~1003-1035`; `test-framework-facts.md` §1.2]

### G9. Release as a SUBPROCESS (pool_die safety)

`pool_die` does `exit 1` in the CURRENT shell. If the test body calls the admin tool
inline and it hits a config error, the harness shell dies. **Always invoke teardown
release as a subprocess:** `"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true`. The
framework's `teardown()` already does this.
[Source: `test-framework-facts.md` §1.5; `test/validate.sh:~183-186`]

### G10. The "distinct lanes" assertion — what to extract from each lease

For each lane N held by a concurrent agent, read `$POOL_LANES_DIR/$N.json` and
extract (PRD §2.8 schema, `external_deps.md` §6):
- `owner.pid` — **all N must be DISTINCT** (the N sim owner PIDs).
- `port` — **all N must be DISTINCT** AND `> 0` (booted, not provisional).
- `chrome_pid` — **all N must be DISTINCT** AND `> 0` (real Chrome per lane).
- `chrome_pgid` — should equal `chrome_pid` (setsid contract).
- `session` — should be `abpool-$N` (distinct per lane).
- `connected` — should be `true` (boot completed).

**ANSWER to Key Question H:** read each `lanes/<N>.json`; assert `owner.pid` all
distinct, `port` all distinct and >0, `chrome_pid` all distinct and non-zero.
[Source: PRD §2.8; `external_deps.md` §6; `lib/pool.sh:pool_lease_write` schema]

---

## §8. Key Question Answers (consolidated)

| Q | Answer | Primary source |
|---|--------|----------------|
| A | **YES.** flock serializes scan+claim; `pool_find_free_lane` picks lowest free N (dir absent AND lease absent); provisional lease written atomically; boot AFTER lock release → concurrent boots, serialized lane assignment. | `lib/pool.sh:~1966-2055`, `~1130-1156`; FINDING 2; PRD §2.4 3a-3d |
| B | copy master (reflink ~17ms) → `pool_find_free_port` (write to lease before launch) → `pool_chrome_launch` (setsid, flags, `pgid==pid`) → `pool_wait_cdp` (**60×0.5s = 30s** budget, ~0.5s observed) → `pool_daemon_connect` → update lease. Retry once on CDP timeout. ~1-3s/lane. | `lib/pool.sh:~2192-2250`, `~1471-1540`, `~1571-1617`; PRP `P1M4T2S2` |
| C | `close` daemon (disconnect-only) → `pool_chrome_kill` (SIGTERM→SIGKILL pgroup + bare-pid) → `rm -rf` reconstructed prefix-guarded dir → `rm -f` lease. **Idempotent, rc 0 always, never pool_die.** | `lib/pool.sh:~2439-2487`, `~1813-1866` |
| D | No `lanes/<N>.json`, no `active/<N>/` dirs, no Chrome procs scoped via `pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"`. Helpers: `assert_lane_gone N`, `assert_no_chrome`. | `test/validate.sh:~93-119`; PRD §2.18 |
| E | **YES, real headless Chrome** (`AGENT_CHROME_HEADLESS=1`, required for unattended). Master must exist (4.8GB at `$AGENT_CHROME_MASTER`). Framework's default temp master is EMPTY → test must supply real master + btrfs ephemeral root. | PRD §2.18, §2.11, §2.7; `test-framework-facts.md` §1.7 |
| F | **YES, safe.** btrfs reflink is read-only on source; N simultaneous copies share blocks via CoW; master never mutated. No lock needed. | PRD §2.7; `external_deps.md` §3 |
| G | `pool_find_free_port` runs OUTSIDE flock → narrow TOCTOU. Mitigated by writing port to lease BEFORE launch. Race is real but narrow; stagger launches if it bites. **CAVEAT:** pool_chrome_launch pool_die's on EADDRINUSE (no retry) — a true collision is fatal. | `lib/pool.sh:~1380-1435`, `~2220` |
| H | Read each `lanes/<N>.json`: `owner.pid` distinct, `port` distinct & >0, `chrome_pid` distinct & >0, `chrome_pgid`==`chrome_pid`, `session`==`abpool-N`, `connected`==true. | PRD §2.8; `external_deps.md` §6 |

---

## §9. Recommended Concurrency Test Skeleton (for the implementer — NOT prescriptive)

```bash
# source test/validate.sh  (gets helpers + runner + setup/teardown)

test_concurrent_distinct_lanes() {
    local N=3 i pids=() lane_pids=() lane_ports=() lane_cpids=()
    local results_dir="$ABPOOL_TEST_ROOT/results"; mkdir -p -- "$results_dir"

    # 1. Supply a REAL master + btrfs ephemeral root (override setup's empty temp master).
    #    (Either copy the real master, or build a minimal one — see §5.3.)
    #    Re-run pool_config_init so POOL_MASTER_DIR / POOL_EPHEMERAL_ROOT reflect the override.

    # 2. Spawn N DISTINCT live "pi" owners (setup already spawned 1; spawn N-1 more).
    for (( i = 1; i < N; i++ )); do
        local pid; pid="$(spawn_sim_owner)"
        pids+=("$pid")
    done
    pids+=("$AGENT_BROWSER_POOL_OWNER_PID")   # the one setup spawned

    # 3. Launch N wrapper invocations IN PARALLEL, each with a DISTINCT OWNER_PID.
    #    (Stagger by ~0.3s to avoid the port TOCTOU — §7 G2.)
    for (( i = 0; i < N; i++ )); do
        (
            AGENT_BROWSER_POOL_OWNER_PID="${pids[$i]}" \
            AGENT_BROWSER_POOL_OWNER_STARTTIME="$(_pool_get_starttime "${pids[$i]}")" \
            AGENT_BROWSER_POOL_STATE="$AGENT_BROWSER_POOL_STATE" \
            AGENT_CHROME_EPHEMERAL_ROOT="$AGENT_CHROME_EPHEMERAL_ROOT" \
            AGENT_CHROME_MASTER="$AGENT_CHROME_MASTER" \
            AGENT_CHROME_HEADLESS=1 \
            "$ABPOOL_WRAPPER" open "about:blank" >/dev/null 2>&1
        ) &
        sleep 0.3
    done
    wait

    # 4. Assert N DISTINCT lanes with distinct owner.pid / port / chrome_pid.
    local lanes; lanes="$(pool_lanes_list)"
    local -a lane_nums=($lanes)
    assert_eq "$N" "${#lane_nums[@]}" "lane count == N"
    # … collect owner.pid / port / chrome_pid per lane, assert all distinct & >0 …

    # 5. CLEANUP ASSERTIONS (PRD §2.18): release all + assert gone.
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    for lane in "${lane_nums[@]}"; do assert_lane_gone "$lane"; done
    assert_no_chrome   # no Chrome under the ephemeral root
}
```

---

## Gaps

- **The exact `bin/agent-browser` wrapper dispatch** (M6.T3.S1) was NOT read in this
  pass — the concurrency test invokes `"$ABPOOL_WRAPPER" open <url>` which routes
  through the wrapper's lifecycle (owner resolve → find_my_lease → acquire_locked →
  boot_lane → exec real binary). If the wrapper has not landed or has a different
  dispatch contract, the test may need to call `pool_acquire_locked` + `pool_boot_lane`
  directly instead. **Suggested next step:** read `bin/agent-browser` (or its PRP
  `P1M6T3S1/PRP.md`) to confirm the wrapper's exact entry contract for a DRIVING
  command like `open`.
- **The real master profile availability** on this checkout is unconfirmed
  (`test-framework-facts.md` §1.7 says it's absent under the real root). The
  concurrency test needs a real master — either the operator's 4.8 GB master exists
  at `$HOME/.agent-chrome-profiles/master-profile`, or the test builds a minimal one.
  A minimal master (`mkdir Default; echo prefs > Preferences`) is enough for a
  headless boot-to-CDP test but won't carry the "trusted identity" the PRD cares
  about (irrelevant for a plumbing concurrency test).
- **Whether `bin/agent-browser` and `bin/agent-browser-pool` are wired/symlinked**
  was not verified (the `bin/` dir may still be `.gitkeep`-only per M6/M7 status).
  The framework constants `ABPOOL_WRAPPER` / `ABPOOL_ADMIN` point at
  `$ABPOOL_REPO/bin/*` — confirm those files exist before the test runs.

## Sources

Kept (primary — the landed code + the PRD + completed PRPs):
- `lib/pool.sh` — the LANDED implementation. Primary source of truth for every
  function contract + line number. (`pool_acquire_locked` ~2033;
  `_pool_acquire_critical_section` ~1966; `pool_find_free_lane` ~1130;
  `pool_boot_lane` ~2192; `pool_chrome_launch` ~1471; `pool_wait_cdp` ~1571;
  `pool_find_free_port` ~1380; `pool_release_lane` ~2439;
  `_pool_release_lane_internals` ~1813; `pool_admin_release` ~3854;
  `pool_owner_resolve` ~478; `pool_owner_alive` ~616; `pool_lanes_list` ~967.)
- `test/validate.sh` — the LANDED test framework (5 assertion helpers +
  `spawn_sim_owner` + `setup`/`teardown` + `run_test` + `abpool_run_suite`).
- `plan/001_0f759fe2777c/prd_snapshot.md` — §2.4 (lifecycle), §2.5 (release),
  §2.6 (Chrome launch), §2.7 (copy/master), §2.8 (lease schema), §2.10 (reaper),
  §2.14 (failure modes), §2.18 (testing — THE contract), §2.19 (gotchas).
- `plan/001_0f759fe2777c/architecture/key_findings.md` — FINDING 2 (short flock),
  FINDING 6 (setsid/pgid), FINDING 7 (atomic lease write), FINDING 8 (test hooks).
- `plan/001_0f759fe2777c/architecture/external_deps.md` — §2.1 (launch cmd),
  §2.2 (CDP readiness loop), §2.3 (port selection), §3 (btrfs/reflink), §5 (env vars),
  §6 (lease schema).
- `plan/001_0f759fe2777c/architecture/system_context.md` — §7 (state dir layout),
  §8 (ephemeral layout, master=4.8GB, btrfs verified).
- `plan/001_0f759fe2777c/P1M5T1S1/PRP.md` — flock critical section (the acquire contract).
- `plan/001_0f759fe2777c/P1M5T2S1/PRP.md` — release/teardown (the release contract).
- `plan/001_0f759fe2777c/P1M4T2S2/PRP.md` — Chrome launch + CDP wait (the boot timing).
- `plan/001_0f759fe2777c/P1M4T1S1/PRP.md` — master copy + reflink (concurrent-copy safety).
- `plan/001_0f759fe2777c/P1M9T1S1/research/test-framework-facts.md` — THE framework
  facts (§1 codebase facts, §2 the fake-pi trick, §3 external synthesis, §4 design).
- `plan/001_0f759fe2777c/P1M9T1S1/research/external-research.md` — the raw framework
  research (set -e hazards, hermetic isolation, pgrep scoping).

Dropped: none (every source read was primary and relevant).

## Supervisor coordination

No coordination needed. This is a research-only task; no files were modified, no
decisions required, no blocking ambiguities. Returning the completed brief.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Research-only task: read all 11 specified source files (key_findings.md, external_deps.md, system_context.md, prd_snapshot.md, P1M5T1S1/PRP.md, P1M5T2S1/PRP.md, P1M4T2S2/PRP.md, P1M4T1S1/PRP.md, P1M9T1S1/research/test-framework-facts.md + external-research.md) PLUS the LANDED lib/pool.sh and test/validate.sh (primary sources of truth). Extracted every fact relevant to the PRD §2.18 concurrency test: the flock contract, boot sequence + timing, release/cleanup contract, exact cleanup assertions, real-Chrome requirements, framework helper API, and 10 concurrency gotchas. Did NOT modify any source file; did NOT widen scope to implement the test. Scope was exactly 'research notes scavenging'."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Every fact is cited to a primary source with a file path + approximate line number (e.g. 'lib/pool.sh:~2033' for pool_acquire_locked, 'test/validate.sh:~93' for assert_lane_gone, 'PRD §2.18' for the cleanup contract, 'key_findings.md FINDING 2' for the short-flock invariant). An independent reviewer can open lib/pool.sh at the cited lines and verify each contract. The 8 key questions (A-H) are answered in a consolidated table (§8) with primary-source citations."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": [
    "Read lib/pool.sh at offsets 1, 120, 470, 600, 960, 1080, 1320, 1520, 1760, 1960, 2160, 2440, 3810 — confirmed function locations: pool_config_init ~126, pool_owner_resolve ~478, pool_owner_alive ~616, pool_lanes_list ~967, pool_find_free_lane ~1130, pool_find_free_port ~1380, pool_chrome_launch ~1471, pool_wait_cdp ~1571 (POOL_CDP_TRIES=60), _pool_release_lane_internals ~1813, _pool_acquire_critical_section ~1966, pool_acquire_locked ~2033, pool_boot_lane ~2192, pool_release_lane ~2439, pool_admin_release ~3854.",
    "Read test/validate.sh in full — confirmed 5 assertion helpers (assert_eq, assert_lane_exists, assert_lane_gone, assert_no_dir, assert_no_chrome), spawn_sim_owner (with settle poll), setup/teardown (hermetic, HEADLESS=1, ONE sim owner per test), run_test (subshell isolation), abpool_run_suite, source-vs-execute gate.",
    "Confirmed test-framework-facts.md §1.7 gap: framework's default temp master is EMPTY → concurrency test must supply a real master + btrfs ephemeral root."
  ],
  "residualRisks": [
    "bin/agent-browser wrapper dispatch (M6.T3.S1) was NOT read — if the wrapper is not landed or has a different entry contract, the concurrency test may need to call pool_acquire_locked + pool_boot_lane directly instead of '$ABPOOL_WRAPPER open <url>'. Suggested next step: read bin/agent-browser or P1M6T3S1/PRP.md.",
    "Real master profile availability on this checkout unconfirmed (test-framework-facts.md §1.7 says absent under real root). Test needs a real master (4.8GB or minimal).",
    "bin/agent-browser and bin/agent-browser-pool file existence not verified (bin/ may still be .gitkeep-only per M6/M7 status). Framework constants ABPOOL_WRAPPER/ABPOOL_ADMIN point at $ABPOOL_REPO/bin/*.",
    "pool_find_free_port TOCTOU (§7 G2): the docstring claims 'launch retries on EADDRINUSE' but pool_chrome_launch pool_die's on instant exit (no EADDRINUSE retry). A true port collision in a concurrency test would be FATAL. Mitigation: stagger launches by ~0.3s, keep N small (3-5)."
  ],
  "noStagedFiles": true,
  "diffSummary": "No source files modified. One NEW file written: the research brief at the authoritative output path (.pi-subagents/artifacts/outputs/2a67d230/plan/001_0f759fe2777c/P1M9T2S1/research/internal-research.md). The brief is research-only — 9 sections covering the concurrency contract, boot sequence + timing, release/cleanup contract, exact cleanup assertions, real-Chrome requirements, framework helper API (verbatim signatures), 10 concurrency gotchas, a consolidated key-question answer table, a recommended test skeleton, gaps, and sources.",
  "reviewFindings": [
    "no blockers — research-only task; output path matches the authoritative runtime override; all facts cited to primary sources with line numbers"
  ],
  "manualNotes": "The brief is structured for direct use by the concurrency-test implementer: §1 (why N agents get N distinct lanes), §2 (boot sequence + 30s CDP budget), §3 (release is idempotent rc 0), §4 (the 5 cleanup helpers + what must be gone), §5 (real Chrome + the EMPTY-master gap the test must fill), §6 (verbatim framework API), §7 (10 gotchas — especially G1 the fake-pi requirement, G2 the port TOCTOU, G8 the one-owner-one-lane invariant), §8 (consolidated answers to all 8 key questions A-H), §9 (a non-prescriptive test skeleton). The two highest-impact findings for the implementer: (1) the framework's setup() spawns only ONE sim owner — the concurrency test must spawn N distinct ones; (2) the framework's default temp master is EMPTY + tmpfs — the concurrency test must point AGENT_CHROME_MASTER at a real master and AGENT_CHROME_EPHEMERAL_ROOT at btrfs (or the reflink copy pool_die's)."
}
```
