# P4.M2.T1.S3 research — parallel caller-mode owners → distinct lanes; owner death → lane reaped

## Verified code facts (lib/pool.sh, HEAD)

- `pool_owner_resolve` (~:536–660): TEST MODE (hook `AGENT_BROWSER_POOL_OWNER_PID` [+ `_OWNER_STARTTIME`]) is checked FIRST and outranks caller mode. Setting the hooks per-owner in a body.sh exercises the same downstream acquire/liveness/reap code as caller mode (item contract explicitly sanctions this).
- `pool_acquire_locked` (:2394+): calls `pool_state_init`, then `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`. Echoes lane N, rc 0; rc 1 on exhaustion. Claim writes a PROVISIONAL lease via `pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" pid comm starttime cwd 0 0 "false"` — NO Chrome, NO copy, NO ephemeral dir creation (boot is a separate post-lock step). Fully Chrome-free.
- `_pool_acquire_critical_section` (:2265): (a) REAP-STALE + REUSE-ORPHAN interleaved per lane via `pool_lane_is_stale` (tri-state: 0=stale, 1=live, 2=no-lease); (c) `pool_find_free_lane` = lowest N with no `active/<N>` dir AND no `lanes/<N>.json`; (d) claim.
- `pool_lane_is_stale N` (:1224): tri-state; must be guarded under set -e (`if pool_lane_is_stale "$n"; then ...; fi` — rc 1/2 abort otherwise).
- `pool_reap_stale` (:3021): explicit stale sweep.
- `pool_release_lane` (:2910): teardown (kills pgroup — chrome_pid 0 → no-op —, rm -rf ephemeral dir, deletes lease).
- `pool_lease_field N field` (:961) — read `owner.pid` from a lease.

## Verified framework facts (test/validate.sh, HEAD)

- Selftest discovery: `compgen -A function | grep '^selftest_' | sort` in `_run_selftest_suite` (:1252). ONE `setup()` call for the whole suite (single-setup runner). Bodies run in the MAIN shell via `if "$fn"`.
- Inter-body sweep (:1268): `rm -f -- "${POOL_LANES_DIR:?}/"*.json` clears leases between bodies — but does NOT clear ephemeral dirs under $POOL_LANES' sibling $AGENT_CHROME_EPHEMERAL_ROOT (the suite root). ⇒ Prefer per-body ISOLATED state roots under `$ABPOOL_TEST_ROOT/<name>/` via env overrides on the body.sh invocation (established pattern at :1086, :1121, :1160, :1230: `AGENT_BROWSER_POOL_STATE="$outdir/state" AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" bash "$script" ...`).
- `spawn_sim_owner [SECONDS] [COMM]` (:128): echoes pid of live fd-detached `sleep` copy named COMM; mktemp prefix `abpool-pi.XXXXXX` MUST stay (trap glob backstop). Settles comm via poll. Tracks bin dir in ABPOOL_SIM_BINS (lost across $(...) subshells → trap backstop).
- setup() (:204) exports `AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME` pointing at ITS sim "pi" owner. ABPOOL_CUR_OWNER holds that pid (LM-6: single slot).
- Assert helpers: `assert_eq :57`, `assert_lane_exists N :67` (lease file presence), `assert_lane_gone N :74` (no lease AND no ephemeral dir).
- Landmines (test_framework.md :315+): LM-4 — kill + `wait` before staleness asserts (zombie /proc lingers → false-alive). LM-6 — one own-owner at a time alongside the setup owner.

## Test design decisions

1. Run each test's pool operations in a child `body.sh` (sourced lib, own STATE/EPHEMERAL_ROOT under outdir) — avoids clobbering main-shell POOL_OWNER_* globals and suite lanes; no inter-body sweep dependency.
2. Spawn sim owners in the MAIN shell (spawn_sim_owner is a validate.sh fn, not visible to children); export hooks per owner into the body.sh invocation env.
3. After `pool_acquire_locked` returns N, body `mkdir -p "$POOL_EPHEMERAL_ROOT/$N"` to simulate the post-lock copy step so `assert_lane_gone` (lease AND dir) is meaningful on reap.
4. Ordering discipline: capture pid → kill → `wait` → staleness asserts (LM-4).
5. Cleanup: bodies + fn kill+wait every owner they spawned even on failure paths (`|| true` guarded kills, then unconditional wait where killed). Since owners are main-shell background children, `wait` works.