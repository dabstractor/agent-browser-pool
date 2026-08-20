# Research notes — P4.M2.T2.S1 (concurrency.sh single-setup conversion)

Verified against HEAD by direct file reads:

## Key facts
- test/concurrency.sh is 444 lines, sources test/validate.sh, has exactly 2 `test_` bodies
  (`test_n_agents_get_n_distinct_lanes` :217, `test_n_provisional_lanes_are_distinct`
  :368), and the execute-gate at :438–444 calls `abpool_run_suite test_`.
- validate.sh `run_test` (:239–258) calls `setup()` per body and runs the body in
  `( set -e; "$fn" )` subshell. `abpool_run_suite` (:262–273) loops run_test.
- Reference pattern: `_abpool_run_release_reaper_suite` test/release_reaper.sh:440–467,
  with `_release_kill_owner_and_reap_zombie` at :135–147 and `_test_spawn_owner` :155–173.
- ABPOOL_ADMIN set by validate.sh:26.

## Concurrency-specific deltas vs release_reaper (the interesting part)
1. release_reaper kills setup's sim-owner right after its single setup() because its
   bodies each spawn their own owner. concurrency's bodies USE setup's owner as owner #0
   (`AGENT_BROWSER_POOL_OWNER_PID`), so the new runner must KEEP it alive; teardown kills it.
2. Bodies spawn N-1 extra `spawn_sim_owner` owners and kill them bare (`kill || true`, no
   wait) — previously safe because bodies ran in subshells (children reparented). With
   main-shell bodies they are the main shell's children → kills need `wait` (LM-4 zombies).
3. release_reaper uses single-slot ABPOOL_CUR_OWNER; concurrency needs an array
   (ABPOOL_CUR_OWNERS) because bodies spawn multiple owners.
4. Bodies' internal `( … ) &` parallel-acquire worker subshells are the concurrency seam
   and must be kept.

## Landmine sources
- plan/004_de5e94ac127c/architecture/test_framework.md §13 (LM-1..LM-8), esp. LM-1 (:307),
  LM-2, LM-4 (:310 area).
- plan/004_de5e94ac127c/architecture/synthesis.md §3 concurrency bullet (:126).
- AGENTS.md §1–§4, §6 (isolated sandbox, timeouts, reaping, single-setup discipline).

Blessed invocation: `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh`
(isolated sandbox only; real Chrome boots).