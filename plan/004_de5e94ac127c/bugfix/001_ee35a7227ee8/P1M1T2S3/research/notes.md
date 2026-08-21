# Research notes — P1.M1.T2.S3 (pool_ensure_connected race-free connect/relaunch)

Verified against HEAD (line numbers via grep, may drift):

- `pool_ensure_connected`: lib/pool.sh ~2744-2880. Steps: a) lease read (one jq fork,
  5 fields; `connected` defaults true; `chrome_pid` coalesced to 0; jq `null`
  coalescing), b) LOCK-FREE fast path `connected==true && pool_daemon_connected` →
  heartbeat + return 0, c) curl `/json/version` probe + `pool_cdp_is_ours` identity
  gate + `pool_daemon_connect` reconnect, e) relaunch: Singleton strip →
  `pool_chrome_launch` (sets POOL_CHROME_PID/PGID globals, `declare -g`, pool_die on
  instant exit) → EARLY chrome-id lease write (~2847-2849) → `pool_wait_cdp` (15s
  budget, 30×0.5s, KILLS pgroup on timeout) → `pool_daemon_connect` → finalize.
- `pool_wait_cdp` at lib/pool.sh:1813; `POOL_CDP_TRIES=30`. Identity check enabled
  only when dir+pid args supplied. `pool_cdp_is_ours` at 1733 (non-fatal).
  `pool_chrome_launch` at 1538. `pool_lease_update/read/field` at 813/873.
- T2.S2 upstream contract (read its PRP at ../P1M1T2S2/PRP.md): `pool_lane_boot_lock`
  helper near pool_state_init, fd-8 `( flock -w 20 8 && body ) 8>"$(...)"` idiom,
  timeout distinguishable from body failure (sentinel exit code), fd 9 forbidden
  (self-deadlock note at lib/pool.sh ~3250-3256). NOTE: not yet landed in lib/pool.sh
  at research time (grep found no `pool_lane_boot_lock`) — implement against the PRP
  contract.
- T2.S1 harness already ships R3: test/bootrace.sh `r3_bug002_race_e2e` (~261-306):
  FAKE_CHROME_DELAY=4, cmd A bg, cmd B at 0.8s; asserts B rc=0, exactly 1 count-file
  line, lease chrome_pid live + in launched pids, zero `release all` survivors, dir
  gone. Header marks it KNOWN-RED until T2.S2/S3 — this item flips the note only.
  `r3_control_delayed_boot_succeeds` is the harness green gate.
- POOL_CHROME_PID/PGID consumers: grep shows usage only inside launch/boot/ensure
  scopes (lib/pool.sh 1489-1648, 2462-2475) — no post-return consumption by
  bin/agent-browser-pool; lease is the authoritative outward channel (globals set
  inside a flock subshell are subshell-local anyway).
- fix_design.md §2b specifies exactly this fix (wrap from curl probe through relaunch
  success; re-read lease under lock; /proc/<pid> dead-pid gate, never kill -0; alive →
  bounded wait + rebind; flock -w ≥ 15s CDP + margin).
- system_context.md §6 covers the ensure_connected contract / wrapper pool_die
  propagation.