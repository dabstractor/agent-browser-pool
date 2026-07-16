# Code Context — Test Framework (`test/*.sh`)

> Scouting of the agent-browser-pool bash test harness. Static analysis only; nothing
> executed. Covers `test/transparency.sh`, `test/validate.sh`, `test/concurrency.sh`,
> the test-invocation mechanism, and the dispatch/normalizer seams under test.

## Files Retrieved
1. `test/transparency.sh` (lines 1-560, whole file) — transparency checklist (PRD §2.15); 10 `test_*` bodies + the single-setup runner + real-env/spawn-owner helpers.
2. `test/validate.sh` (lines 1-776, whole file) — the BASE framework sourced by the other three; assertions, `spawn_sim_owner`, hermetic setup/teardown, EXIT trap, `run_test`/`abpool_run_suite`, all `selftest_*`, `_run_selftest_suite`.
3. `test/concurrency.sh` (lines 1-448, whole file) — N-distinct-lanes concurrency test; header + runner. **0 matches for `meta`/`passthrough`** (grepped — confirmed absent).
4. `test/release_reaper.sh` (lines 420-498) — `_abpool_run_release_reaper_suite` (the single-setup mirror pattern transparency.sh copies).
5. `bin/agent-browser-pool` (lines 1-36, whole file) — the SOLE entry point tests invoke as `$ABPOOL_ADMIN`; the `case` dispatch (`--help|-h|help` → `pool_admin_help`; everything else → `pool_wrapper_main`).
6. `lib/pool.sh` — symbol locations confirmed via grep (see "Key symbols in lib/pool.sh" below).

## Test invocation — there is NO `test/run.sh` and NO `Makefile`
- `find . -maxdepth 2 -iname makefile` → **no results**. No `GNUmakefile` either.
- Every test file is **self-running** via a `BASH_SOURCE` gate at its bottom. Invoke directly:
  ```bash
  bash test/validate.sh        # runs _run_selftest_suite (selftest_*)
  bash test/transparency.sh    # runs _abpool_run_transparency_suite (test_*)
  bash test/release_reaper.sh  # runs _abpool_run_release_reaper_suite (test_*)
  bash test/concurrency.sh     # runs abpool_run_suite test_  (test_*)
  ```
- Gate pattern (identical in all four):
  ```bash
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
      if ! <runner>; then exit 1; fi
  fi
  ```
- Each file `source`s `validate.sh` first (symlink-safe bootstrap): `validate.sh` → `lib/pool.sh`. Sourcing only *defines* helpers (dual mode); the gate controls execution.

## Architecture — the framework layering
```
lib/pool.sh            ← all SUT primitives (config/state/lease/owner/dispatch/boot)
   ▲
   │ source
bin/agent-browser-pool ← SOLE entry point ($ABPOOL_ADMIN); case dispatch: pool verbs vs driving
   ▲
   │ tests invoke $ABPOOL_ADMIN by ABSOLUTE PATH (no PATH shadowing)
test/validate.sh       ← BASE framework: assertions, spawn_sim_owner, setup/teardown,
   │                     EXIT trap (_abpool_global_cleanup), run_test/abpool_run_suite,
   │                     selftest_* + _run_selftest_suite  (BASH_SOURCE self-run)
   ▲
   │ source
   ├── test/transparency.sh   (test_*  + _abpool_run_transparency_suite  — single-setup)
   ├── test/release_reaper.sh (test_*  + _abpool_run_release_reaper_suite — single-setup)
   └── test/concurrency.sh    (test_*  + abpool_run_suite test_           — PER-TEST setup!)
```
`ABPOOL_ADMIN` is resolved in validate.sh: `ABPOOL_ADMIN="$ABPOOL_REPO/bin/agent-browser-pool"` (validate.sh:29). `ABPOOL_WRAPPER` no longer exists (renamed to `ABPOOL_ADMIN` — P2.M5.T1.S1).

## Key Code

### transparency.sh — all 10 `test_*` functions (PRD §2.15 clauses)
Discovered via `compgen -A function | grep '^test_' | sort` in `_abpool_run_transparency_suite`. One body per clause (a–i):
1. `test_passthrough_skills` (a) — `skills get core` → META passthrough, byte-equal to `$POOL_REAL_BIN`. **Uses `assert_eq "$r" "$w"` on real-binary output.**
2. `test_help_shows_pool_help` (b1) — `--help` → POOL help (contains `"agent-browser-pool"`).
3. `test_version_passthrough` (b2) — `--version` → META passthrough, byte-equal. **Uses `assert_eq "$r" "$w"`.**
4. `test_open_zero_prep_lands_lane` (c) — bg `open about:blank`, poll `_transparency_wait_my_lane`, assert lane exists.
5. `test_second_open_reuses_lane` (d) — 2 opens same owner → `N1 == N2` (find_mine reuse).
6. `test_connect_random_ignored` (e) — LAYER1 normalizer unit (`connect 98765` stripped from `POOL_NORM_ARGS`); LAYER2 routing (`find_mine == N`).
7. `test_session_override_forced` (f) — `--session <X> open` → lease `.session == "abpool-$N"`, `≠ <X>`.
8. `test_close_all_scoped_no_peer_harm` (g) — multi-owner; LAYER1 normalizer (`--all` stripped, `POOL_CLOSE_ALL_SEEN=1`); LAYER2 peer lane+Chrome survive.
9. `test_next_agent_distinct_lane` (h) — two distinct owners → `NA != NB`, each owned by its pid.
10. `test_driving_no_pi_ancestor_fails_fast` (i) — `setsid --fork` detached `open` → pool_die, stderr contains `"pi ancestor"`.

### transparency.sh helpers
- **`_transparency_setup_real_env`** (lines 51-110) — points `AGENT_CHROME_MASTER` (real read-only master), `AGENT_BROWSER_REAL` (real `$real_home/.local/bin/agent-browser`), and `AGENT_CHROME_EPHEMERAL_ROOT` (btrfs temp dir) at REAL host resources, because validate.sh's `setup()` clobbers `HOME` → empty temp master / nonexistent `POOL_REAL_BIN` → `pool_die`. Ends with `pool_config_init; pool_state_init` to re-resolve globals. **Copied verbatim** from release_reaper's `_release_setup_real_env`.
- **`_transparency_spawn_owner`** (lines 152-170) — spawns a fresh live "pi"-comm owner per body; sets `ABPOOL_CUR_OWNER`, exports `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`, then calls `pool_owner_resolve` to refresh globals in the main shell (required because `$()` subshell exports don't propagate).
- **`_transparency_acquire_boot`** (lines 118-131) — `pool_owner_resolve` → `pool_acquire_locked` → boot if port==0; echoes lane N.
- **`_transparency_kill_owner`** (lines 138-143) — `kill` + `wait` (reap zombie so `/proc` clears).
- `_transparency_run_open_bg` / `_transparency_wait_my_lane` / `_transparency_reap_bg` / `_transparency_reap_all_sim_owners` — the poll-then-kill open driver (driving `open` may not exit → background under `timeout --signal=KILL 25`, poll `pool_lease_find_mine` up to 20s, then reap).

### transparency.sh — `_abpool_run_transparency_suite` (single-setup runner, lines 533-573)
```bash
_abpool_run_transparency_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call
    _transparency_kill_owner "$AGENT_BROWSER_POOL_OWNER_PID"   # setup's owner unused; kill now
    ABPOOL_CUR_OWNER=""
    for fn in $(compgen -A function | grep '^test_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then                      # MAIN shell, not subshell (no mid-suite EXIT trap)
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        _transparency_reap_bg
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _transparency_kill_owner "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
        _transparency_reap_all_sim_owners
    done
    teardown
    _transparency_reap_all_sim_owners       # final backstop
    printf '\n%d passed, %d failed\n' "$ABPOOL_PASS" "$ABPOOL_FAIL"
    if (( ABPOOL_FAIL > 0 )); then printf 'FAILED: %s\n' "${ABPOOL_FAILED[*]}" >&2; return 1; fi
    return 0
}
```
**Bypasses `run_test`/`abpool_run_suite`** (which call `setup()` per-test → the 3rd call HANGS the sandbox, AGENTS.md §4). Bodies run via `if "$fn"` in the **main shell** (a `return 1` = function rc = FAIL, suite continues; no subshell ⇒ the EXIT trap does not fire mid-suite ⇒ temp root survives).

### validate.sh — `_run_selftest_suite` (lines 748-773)
Identical single-setup pattern but enumerates `^selftest_` and sweeps `"$POOL_LANES_DIR"/*.json` between bodies (pure-logic selftests leave stray lease files). Also bypasses `abpool_run_suite`.

### validate.sh — selftest registration (NO explicit registry)
Selftests are registered **by naming convention + runtime discovery** — there is no registration array/call. `_run_selftest_suite` does:
```bash
for fn in $(compgen -A function | grep '^selftest_' | sort); do ... done
```
So adding `selftest_foo() { ... }` ANYWHERE in validate.sh auto-registers it. `test_*`/`test_`-prefixed funcs in the other files are discovered the same way (`compgen -A function | grep '^test_'`).

### validate.sh — `selftest_dispatch_classify_cases` (lines 345-388)
Exercises `pool_dispatch_classify` directly (pure function, reads NO globals, writes NO files). Full table:
- **META** short-circuit: `--help`/`-h`/`--version` → `meta`; `session list`, `skills`, `dashboard`, `plugin`, `mcp` → `meta`.
- **META (Issue 4)**: no-args / `--json` / `--session foo` / `--session=foo` / `--headed --json` / `-i` / empty-string → `meta`.
- **DRIVING**: `open click connect close session back get find` → `driving`; `unknowncmd` → `driving` (default); `--session foo open` / `--json click` → `driving`.

### validate.sh — the EXIT trap (`_abpool_global_cleanup`, lines 154-186)
```bash
trap _abpool_global_cleanup EXIT INT TERM
```
Kills `ABPOOL_CUR_OWNER`; `rm -rf` every dir in `ABPOOL_SIM_BINS[]`; `rm -rf` every root in `ABPOOL_TEST_ROOTS[]`; backstop globs `/tmp/abpool-test.*` and `/tmp/abpool-pi.*`. Every line ends `|| true` (never aborts the exit path). **Inherited by subshells** → the reason bodies run in the main shell (AGENTS.md §4 trap hazard).

### validate.sh — `setup()` (lines 196-223, process-spawning)
`mktemp -d -t abpool-test.XXXXXX` → overrides `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_CHROME_MASTER` (EMPTY temp), `AGENT_CHROME_HEADLESS=1`; `pool_config_init; pool_state_init`; then `spawn_sim_owner` (the spawning step). **This is the accumulation hazard**: called per-test by `run_test`/`abpool_run_suite`; 3rd call HANGS. All single-setup runners call it exactly ONCE.

### concurrency.sh — header + `meta`/`passthrough`
- Header (lines 1-28): N-parallel-agents mutual-exclusion test; drives the lib's acquire+boot DIRECTLY (not the entry point) because `pool_wrapper_main` `exec`s into the real agent-browser (may not exit → `wait` hang).
- `grep -nE 'meta|passthrough' test/concurrency.sh` → **NO MATCHES.** concurrency.sh has no meta/passthrough concepts (it does not exercise dispatch classification).
- Runner: `abpool_run_suite test_` (line 441) — uses the **per-test setup runner** (the DANGEROUS one). Only 2 `test_*` bodies (`test_n_agents_get_n_distinct_lanes`, `test_n_provisional_lanes_are_distinct`) ⇒ 2 setup() calls ⇒ under the 3rd-call-hang threshold, but it is the ONE file that does NOT use a single-setup runner.

### Key symbols in `lib/pool.sh` (locations, for cross-reference)
- `_pool_config_bool` — lib/pool.sh:82
- `_pool_get_starttime` — lib/pool.sh:412
- `pool_owner_resolve` — lib/pool.sh:486
- `pool_lease_find_mine` — lib/pool.sh:1011
- `pool_dispatch_classify` — lib/pool.sh:3070  (returns `meta` | `driving`)
- `pool_normalize_close` — lib/pool.sh:3181
- `pool_normalize_connect` — lib/pool.sh:3254
- `pool_wrapper_main` — lib/pool.sh:3516  (the driving dispatcher; terminal `exec "$POOL_REAL_BIN"…`)
- `_pool_clean_args_is_close` — lib/pool.sh:3739

### bin/agent-browser-pool dispatch (lines 25-36)
```bash
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) pool_wrapper_main "$@" ;;
esac
```
`--help`/`-h`/`help` is a POOL VERB caught here (→ `pool_admin_help`), BEFORE `pool_wrapper_main`/`pool_dispatch_classify`. `--version`, `skills`, etc. fall through to `pool_wrapper_main` → `pool_dispatch_classify` → `meta` → `exec "$POOL_REAL_BIN"`. This is WHY `test_help_shows_pool_help` asserts `agent-browser-pool` substring (pool help) while `test_passthrough_skills`/`test_version_passthrough` assert byte-equality vs `$POOL_REAL_BIN`.

## Start Here
Open **`test/validate.sh`** first — it is the base framework every other test file sources, and defines the EXIT trap, `setup()` (the accumulation hazard), `run_test`/`abpool_run_suite` (per-test runners), the single-setup `_run_selftest_suite`, and the `selftest_dispatch_classify_cases` table. Then `test/transparency.sh` for the 10 `test_*` bodies + `_abpool_run_transparency_suite`, and `bin/agent-browser-pool` for the dispatch case that `--help` vs passthrough turns on.

## Notes / open questions
- The 4 test files cannot be aggregated into one shell yet (each has a runner that calls `setup()`; combining would exceed the single-setup constraint). Each runs standalone via its BASH_SOURCE gate.
- `concurrency.sh` is the only suite still on the per-test `abpool_run_suite` runner (2 tests only). If a 3rd `test_*` is ever added there, it would hit the 3rd-setup()-hang.
- "META → exec real binary" model: `pool_dispatch_classify` returns `meta`; `pool_wrapper_main` then execs `$POOL_REAL_BIN` with the meta args. The transparency tests' "passthrough = byte-equal to `$POOL_REAL_BIN`" asserts depend on this.
