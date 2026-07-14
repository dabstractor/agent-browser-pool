# Codebase facts — P1.M9.T3.S1 (Release + stale reaper + crash simulation tests)

Authoritative findings from reading `lib/pool.sh` (4302 lines, LANDED), `test/validate.sh`
(LANDED framework, 13585 bytes), the concurrency PRP (`plan/.../P1M9T2S1/PRP.md`, in-flight),
and the framework PRP (`plan/.../P1M9T1S1/PRP.md`). Every line number is current.

## §1. The SUT surface THIS test drives (exact lib functions + contracts)

| function | line | rc contract | what it does (the part this test exercises) |
|---|---|---|---|
| `pool_owner_resolve` | 478 | rc 0 always (TEST MODE) | reads `AGENT_BROWSER_POOL_OWNER_PID` + `_OWNER_STARTTIME` into `POOL_OWNER_*` globals (comm forced "pi"). |
| `pool_acquire_locked` | 2043 | echoes lane N + rc 0 ; rc 1 exhaustion | `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`. **rc 1 on exhaustion → GUARD.** |
| `_pool_acquire_critical_section` | 1966 | (private) | **REUSE-ORPHAN BEFORE REAP**: for each stale lane → if `port>0 && pool_daemon_connected` → `_pool_adopt_lane` (reuse, KEEPS port>0) else → `_pool_release_lane_internals` (reap). Then `pool_find_free_lane` + write PROVISIONAL lease (`port=0`). |
| `pool_boot_lane` | 2185 | rc 0 / rc 1 (recoverable, lane dropped) | copy→port→launch→wait_cdp→**pool_daemon_connect**→update lease `connected=true`. rc 1 cleans up via `_pool_release_lane_internals`. **GUARD.** |
| `pool_lease_field` | 876 | rc 0 echoes value / rc 1 missing | nested-path read (`owner.pid`, `port`, `chrome_pid`, `chrome_pgid`). **rc 1 → `|| true` inside `$(…)`.** |
| `pool_lanes_list` | 967 | rc 0 always; mapfile-safe | numeric lane numbers with a lease file. |
| `pool_lane_is_stale` | 1164 | tri-state 0=stale/1=live/2=no-lease | delegates to `pool_owner_alive` (INVERTED). **BARE call ABORTS under set -e on rc 1/2 → use in `if`.** |
| `pool_owner_alive` | 616 | 0=alive / 1=dead | reads REAL `/proc/$pid` (existence + `comm`=="pi" + starttime match). **The override does NOT fake the kernel process.** |
| `pool_release_lane` | 2438 | rc 0 ALWAYS (idempotent) | daemon `close` (via `POOL_REAL_BIN`) + `_pool_release_lane_internals`. |
| `_pool_release_lane_internals` | 1813 | rc 0 always | `pool_chrome_kill` + `rm -rf $POOL_EPHEMERAL_ROOT/$N` (reconstructed+prefix-guarded) + `rm -f $POOL_LANES_DIR/$N.json`. **The reap kernel.** |
| `pool_chrome_kill` | 1757 | rc 0 always | `kill -- -pgid` (SIGTERM) → sleep 0.5 → `kill -9 -- -pgid` → bare-pid fallback. Numeric guards skip `0`. Every kill `2>/dev/null \|\| true`. |
| `pool_reap_stale` | 2549 | rc 0 always; echoes reaped count | for each lane → if `pool_lane_is_stale` → `pool_release_lane` (full teardown). |
| `pool_ensure_connected` | 2288 | rc 0 connected / rc 1 not | (b) `pool_daemon_connected`? → heartbeat. (c) curl `/json/version` alive? → `pool_daemon_connect` (reconnect). (d) dead → relaunch same dir+port. **NEVER drops the lane.** |
| `pool_daemon_connected` | 1689 | 0=connected / 1=not | session known to daemon (`session list`) AND `curl -sf /json/version` on port. BOTH must pass. |
| `pool_lease_find_mine` | 1003 | echoes N + rc 0 / rc 1 none | the owner's existing LIVE lease (owner matches + alive). **The "next command reuses same lane" mechanism.** |
| `pool_admin_release` | 3830 | rc 0 released / rc 1 not-found/usage | `release N`/`release all`: probes `pool_lease_exists` → `pool_release_lane`. |
| `pool_admin_reap` | 3730 | rc 0 always | `reap`: `count="$(pool_reap_stale)"`; prints "Reaped N stale lane(s)."/"No stale lanes found." |

## §2. The lease JSON schema (fields this test reads — PRD §2.8)
Top-level: `lane`, `ephemeral_dir`, `port`, `session`, `chrome_pid`, `chrome_pgid`, `connected`,
`acquired_at`, `last_seen_at`; nested `owner.{pid,comm,starttime,cwd}`. A PROVISIONAL (claimed,
not booted) lease has `port=0, chrome_pid=0, chrome_pgid=0, connected=false`.

## §3. ★★★ THE PIVOTAL GAP — boot/release/close/reap ALL need a valid POOL_REAL_BIN ★★★
`pool_boot_lane` step e (lib/pool.sh:2257) calls `pool_daemon_connect`, which (lib/pool.sh:1648)
does `"$POOL_REAL_BIN" --session "$session" connect "$port"` and returns rc 1 if `POOL_REAL_BIN`
is empty OR the connect fails. **On rc 1, `pool_boot_lane` DROPS the lane + returns rc 1.**
`pool_config_init` (lib/pool.sh:142) resolves `POOL_REAL_BIN` from `AGENT_BROWSER_REAL` or
defaults to `$HOME/.local/bin/agent-browser`.

**The framework's `setup()` (test/validate.sh) overrides `HOME` to a temp dir but does NOT set
`AGENT_BROWSER_REAL`** → `POOL_REAL_BIN` = `$TEMP_HOME/.local/bin/agent-browser` (NONEXISTENT)
→ `pool_daemon_connect` rc 1 → `pool_boot_lane` rc 1 → **EVERY test that boots real Chrome FAILS.**

HOST-VERIFIED 2026-07-13: the REAL agent-browser exists at
`/home/dustin/.local/bin/agent-browser` → `/home/dustin/.local/lib/node_modules/agent-browser/bin/agent-browser-linux-x64`.

**FIX (mandatory):** the test's setup helper MUST `export AGENT_BROWSER_REAL` to the real binary
(resolved via `getent passwd` for the REAL home, since `setup()` clobbered HOME) + re-run
`pool_config_init`. This is EXACTLY analogous to the concurrency PRP's `_concurrency_setup_master`
overriding `AGENT_CHROME_MASTER` to the real master — EXCEPT the concurrency PRP does NOT set
`AGENT_BROWSER_REAL` (a latent gap there; THIS PRP sets BOTH `AGENT_CHROME_MASTER` AND
`AGENT_BROWSER_REAL`). The real master is READ-ONLY (PRD §2.7) → safe to share; reflink copies
are CoW. Chrome still runs under the TEMP ephemeral root (setup's override) → hermetic.

## §4. Contract resolutions (the item description is a high-level sketch; the CODE is authority)

### (b) stale reaper — "X != Y → X dead" is imprecise; the REAL mechanism + the reuse-orphan trap
- `pool_owner_alive` reads the REAL `/proc/$pid`. Merely using a different override PID (Y) for M
  does NOT make X dead — X must be GENUINELY dead. **So: KILL owner X** (then `wait "$X"` to REAP
  the zombie so `/proc/$X` vanishes — a zombie's `comm`/`starttime` may still read "pi" → false-alive).
- **THE REUSE-ORPHAN TRAP (§1 `_pool_acquire_critical_section`):** during M's acquire, if N is stale
  BUT N's Chrome is still RESPONSIVE (`pool_daemon_connected` rc 0), M will **ADOPT** N (reuse),
  NOT reap it. Adopted → `port>0` (N's port KEPT). Reaped → fresh provisional → `port=0`.
- **TO FORCE THE REAP PATH:** after killing X, ALSO kill N's Chrome pgroup (`kill -9 -- -pgid`) so
  `curl /json/version` fails → `pool_daemon_connected` rc 1 → not adoptable → REAP runs.
- **THE CLEAN REAP-vs-REUSE SIGNAL:** after M's acquire, `M.port == 0` ⟺ M is a fresh reap+claim
  (NOT a reuse). `M.port > 0` ⟺ M reused (adopted) N. So assert `M.port == 0` to PROVE reap.
- NOTE: after reaping N, `pool_find_free_lane` may return N's OWN number (lowest free) → M can == N.
  So do NOT assert `M != N`. Assert instead: `M.port==0` (reap, not reuse) + `M.owner.pid==Y` +
  N's ephemeral dir gone (`assert_no_dir $POOL_EPHEMERAL_ROOT/$N`) + N's Chrome dead.

### (c) crash simulation — "kill Chrome then reap" is INCONSISTENT with PRD §2.14
PRD §2.14: **Chrome crash mid-task (owner ALIVE) → relaunch+reconnect, KEEP lease (NOT reap).**
`pool_reap_stale` only reaps DEAD-OWNER lanes (`pool_lane_is_stale`→`pool_owner_alive`). Killing
Chrome alone (owner alive) → lane NOT stale → `reap` does NOTHING → "assert dir deleted, lease
gone" would FAIL. **RESOLUTION (the only PRD-consistent reading):** the simulated crash is the
**OWNER** (agent pi) crashing. Kill owner X (Chrome still alive = the orphan a real crash leaves).
Then `agent-browser-pool reap` detects X dead → `pool_release_lane` → **kills the orphan Chrome
pgroup + rm dir + drop lease**. Assert `assert_lane_gone N` + `assert_no_chrome` (proves the reaper
killed the still-alive orphan Chrome — the strong cleanup-on-crash claim). The RESEARCH NOTE's
"simulate crash by changing the owner PID override so the existing lease's owner appears dead" =
kill the override-set owner X (its PID points at the real sim-owner process; killing it makes the
lease's recorded owner dead).

### (d) close != release — disconnect-only; Chrome/dir/lease survive; next cmd reuses the lane
- `close` = daemon disconnect. The wrapper does `exec "$POOL_REAL_BIN" --session abpool-N close`
  (terminal exec). For a non-driving command we invoke the SAME command DIRECTLY (avoids the exec).
  rc is 0 on agent-browser 0.28.0 (always). close detaches the daemon session; leaves Chrome + dir +
  lease ALIVE (PRD §2.5). The lib does NOT touch the lease on close (`connected` stays `true`).
- Assert post-close: lease present (`assert_lane_exists N`), dir exists (`[[ -d ]]`), Chrome alive
  (`curl /json/version` on N's port). Then "next command reuses same lane":
  `pool_lease_find_mine` returns N (owner X still live → its existing lease) — assert `== N`. AND
  `pool_ensure_connected N` reconnects the daemon to the SAME Chrome (curl alive → reconnect) —
  assert rc 0.

## §5. set -e hazards the test bodies MUST respect (all proven in lib/pool.sh)
- `pool_acquire_locked` rc 1 (exhaustion), `pool_boot_lane` rc 1 (dropped), `pool_lease_field` rc 1
  (missing), `pool_lease_find_mine` rc 1 (none), `pool_ensure_connected` rc 1 (not connected) ALL
  ABORT a bare call under set -e (the body runs in `( set -e; "$fn" )`). GUARD each:
  `if ! N="$(pool_acquire_locked)"; then …`, `pool_boot_lane "$N" || { _fail …; return 1; }`,
  `cpid="$(pool_lease_field … 2>/dev/null)" || cpid=""`, `if ! reuse="$(pool_lease_find_mine 2>/dev/null)"`.
- `pool_lanes_list` + `pool_release_lane` + `pool_chrome_kill` are rc 0 ALWAYS → safe bare.
- `(( ))` only inside `if`/`while`/`for` (the condition is errexit-exempt). Counters via `$(( ))`.
- `local x="$(…)"` masks errexit (SC2155) → split: `local x; x="$(…)"`.
- `kill`/`curl`/`pgrep`/`pkill` returning non-zero ABORTS bare → `2>/dev/null || true` or in `if`.
- `kill -0` is a TRAP (ESRCH vs EPERM) → use `curl /json/version` or `pgrep` for liveness.

## §6. Zombie-reaping gotcha (owner-death simulation)
After `kill "$owner_x"`, the sim-owner (a `sleep` binary named `pi`, child of the test shell)
becomes a **ZOMBIE** until its parent reaps it. A zombie's `/proc/$pid` STILL EXISTS and its
`comm`/`starttime` may still read "pi"/match → `pool_owner_alive` returns 0 (ALIVE) → the lane is
NOT stale → reap/acquire won't touch it → **test fails / passes vacuously**. **FIX:**
`kill "$owner_x" 2>/dev/null || true; wait "$owner_x" 2>/dev/null || true` — `wait` reaps the zombie
so `/proc/$owner_x` vanishes → `pool_owner_alive` returns 1 (dead). (The sim-owner IS a direct child
of the shell that ran `setup()`/`spawn_sim_owner`, so `wait` works.)

## §7. Framework-baseline RISK (observed) → RESOLVED by the single-setup runner
Empirically `bash test/validate.sh` (the LANDED framework self-test, Chrome-free) was observed to
hang on the 3rd `setup()` call in THIS sandbox (timed out at 45–60s after 2 selftests passed).
Root cause not isolated (candidate: an EXIT-trap / subshell + accumulation interaction in `setup()`'s
`pid="$(spawn_sim_owner)"; st="$(_pool_get_starttime "$pid")"` captures, OR an environment artifact).
This is a **P1.M9.T1.S1 framework concern**.

**RESOLUTION (the PRP enforces):** `test/release_reaper.sh` calls `setup()` **EXACTLY ONCE**
(`_abpool_run_release_reaper_suite`) and does NOT use the framework's `run_test`/`abpool_run_suite`
(which call `setup()` per test → would hit the 3rd-call hang). Bodies run via `if "$fn"; then` in the
MAIN shell (no subshell → the EXIT trap never fires mid-suite → the temp root survives all four
bodies). Each body spawns its OWN owner via `_test_spawn_owner` (tests c/b kill theirs, so they
cannot share setup's single owner). **HARD DIRECTIVE: no agent may ever run a 3rd `setup()` in this
sandbox.** Task 0 verifies the framework by SOURCING it + confirming `setup()` works ONCE — it does
NOT run `bash test/validate.sh` (whose self-test makes 7 `setup()` calls and hangs).

## §8. Hermetic isolation (unchanged from the framework + concurrency PRP)
`setup()` overrides `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`,
`AGENT_CHROME_MASTER` to a `mktemp` temp root + `AGENT_CHROME_HEADLESS=1`. This test's helper ADDS
`AGENT_BROWSER_REAL` (real binary) + overrides `AGENT_CHROME_MASTER` (real master). Chrome runs
under the TEMP ephemeral root (hermetic); the real master is READ-ONLY (never mutated); the real
agent-browser daemon operates on the temp-scoped sessions. The operator's real pool state + daily
Chrome are untouched. `teardown` runs `"$ABPOOL_ADMIN" release all` as a SUBPROCESS (pool_die-safe)
+ kills `ABPOOL_CUR_OWNER`.
