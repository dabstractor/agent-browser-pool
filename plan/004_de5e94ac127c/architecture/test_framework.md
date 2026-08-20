# Test Framework Map — plan/004 (caller-scoped lane mode + lane pinning)

Static research only. No Chrome, no suite runs, no binaries launched (AGENTS.md §1).
All line numbers exact against the current tree. Source files: `test/validate.sh` (1207 L),
`test/release_reaper.sh` (475 L), `test/concurrency.sh` (444 L), `test/transparency.sh` (603 L).

---

## 1. Topology — validate.sh is the FRAMEWORK; the others source it

```
test/validate.sh        FRAMEWORK: _fail + 5 asserts + spawn_sim_owner + setup/teardown
                        + run_test/abpool_run_suite (per-test) + _run_selftest_suite
                        (single-setup) + 28 selftest_* bodies
test/release_reaper.sh  sources validate.sh:48; OWN single-setup runner (:440); test_* (REAL Chrome)
test/concurrency.sh     sources validate.sh:27; uses abpool_run_suite test_ (:441) = PER-TEST
                        setup() — currently exactly 2 tests (at the hang threshold, §8 LM-1)
test/transparency.sh    sources validate.sh:48; OWN single-setup runner (:562); test_* (REAL Chrome)
```

Dual mode: executing a file runs its suite (`BASH_SOURCE[0] == "$0"` gate, validate.sh:1198);
sourcing it defines helpers only.

## 2. Selftest DISCOVERY (validate.sh)

Generic runner (validate.sh:264–283) — prefix-enumeration via compgen+grep, **no registration**:

```bash
# validate.sh:267 (abpool_run_suite loop)
for fn in $(compgen -A function | grep "^${prefix}" | sort); do
    run_test "$fn" "$fn"
done
```

The built-in selftests BYPASS it (per-test setup hazard, §8) for a single-setup runner
(validate.sh:1178–1207):

```bash
# validate.sh:1178–1196 (_run_selftest_suite)
_run_selftest_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call
    for fn in $(compgen -A function | grep '^selftest_' | sort); do
        printf '== %s\n' "$fn"
        if "$fn"; then
            ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else
            ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
        fi
        rm -f -- "${POOL_LANES_DIR:?}/"*.json 2>/dev/null || true   # :1192 inter-body lease sweep
    done
    teardown
```

**Failing test never aborts the suite**: the body runs as `if "$fn"` in the MAIN shell —
a failing assert's `return 1` is the function's rc → recorded FAIL → loop continues. No
subshell ⇒ the EXIT trap cannot fire mid-suite and delete the shared temp root. Bodies must
end every assert with explicit `|| return 1` (the `if` context disables set -e propagation).

## 3. setup()/teardown(): what spawns, and hermetic redirection

`setup()` (validate.sh:204–228) DOES spawn a process: ONE sim-owner (`spawn_sim_owner`,
line 218). It is called exactly ONCE per suite in validate.sh/_run_selftest_suite (:1181),
release_reaper.sh (:443), transparency.sh (:562). The GENERIC `run_test` (:246–263) calls
`setup` before EACH body — that path is the 3rd-call hang hazard and is only still used by
concurrency.sh (2 tests ⇒ 2 calls, at the edge; see plan/003/architecture/key_findings.md:50).

Hermetic redirection (validate.sh:206–213):

```bash
ABPOOL_TEST_ROOT="$(mktemp -d -t abpool-test.XXXXXX)"     # :206
ABPOOL_TEST_ROOTS+=("$ABPOOL_TEST_ROOT")                  # :207 track EVERY root for the trap
export HOME="$ABPOOL_TEST_ROOT/home";            mkdir -p -- "$HOME"        # :209
export AGENT_BROWSER_POOL_STATE="$ABPOOL_TEST_ROOT/state"                   # :210
export AGENT_CHROME_EPHEMERAL_ROOT="$ABPOOL_TEST_ROOT/active"              # :211
export AGENT_CHROME_MASTER="$ABPOOL_TEST_ROOT/master"; mkdir -p -- "$AGENT_CHROME_MASTER" # :212
export AGENT_CHROME_HEADLESS=1                                             # :213
```
then `pool_config_init` + `pool_state_init` (:215–216) re-resolve all `POOL_*` globals,
`pid="$(spawn_sim_owner)"` (:218) + `st="$(_pool_get_starttime "$pid")"` (:219), then
`export AGENT_BROWSER_POOL_OWNER_PID="$pid"` / `_STARTTIME="$st"` (:221–222).

Cleanup trap (validate.sh:171–193): `_abpool_global_cleanup` kills `ABPOOL_CUR_OWNER`,
`rm -rf` every `ABPOOL_TEST_ROOTS` element + every `ABPOOL_SIM_BINS` element, plus glob
backstops `rm -rf -- /tmp/abpool-test.*` and `rm -rf -- /tmp/abpool-pi.*`. Registered:
`trap _abpool_global_cleanup EXIT INT TERM` (validate.sh:193). `teardown()` (:230–241) is
the per-suite backstop: `"$ABPOOL_ADMIN" release all … || true` + kill `ABPOOL_CUR_OWNER`.

## 4. Assert helpers (exact signatures, validate.sh)

| Line | Signature | Meaning |
|---|---|---|
| 45 | `_fail MSG` | print `    FAIL: MSG` to stderr; `return 1`; never exits |
| 57 | `assert_eq EXPECTED ACTUAL [LABEL]` | string equality |
| 67 | `assert_lane_exists N` | lease file `$POOL_LANES_DIR/N.json` present |
| 74 | `assert_lane_gone N` | lease file AND `$POOL_EPHEMERAL_ROOT/N` absent |
| 83 | `assert_no_dir PATH` | path absent (file/dir/symlink) |
| 94 | `assert_no_chrome [ROOT]` | `pgrep -f -- "user-data-dir=$ROOT"` finds nothing (scoped; NEVER `kill -0`) |

There is no dedicated rc-assert — the idiom is a subshell + `|| rc=$?` + `assert_eq`
(§5). Lease field reads use the lib's `pool_lease_field LANE FIELD` guarded as
`x="$(pool_lease_field "$N" port 2>/dev/null)" || x=""` (rc 1 on missing/corrupt).

## 5. pool_die subshell rc-assert — canonical example (validate.sh:896–911)

```bash
selftest_preflight_accepts_bare_name_on_path() {
    ...
    rc=0
    ( PATH="$bin_dir:/usr/bin:/bin" AGENT_BROWSER_REAL=agent-browser bash -c '
          set -e; source "$1/lib/pool.sh"; pool_config_init; _pool_preflight_real_bin
      ' _ "$ABPOOL_REPO" ) || rc=$?
    assert_eq "0" "$rc" "preflight passes for a bare name on PATH" || return 1
    rc=0
    ( PATH="/usr/bin:/bin" AGENT_BROWSER_REAL=agent-browser-nope bash -c '
          set -e; source "$1/lib/pool.sh"; pool_config_init; _pool_preflight_real_bin
      ' _ "$ABPOOL_REPO" ) || rc=$?
    [[ "$rc" -ne 0 ]] || { _fail "preflight should fail for a missing bare name (rc=0)"; return 1; }
}
```
Also `selftest_chrome_launch_eaddrinuse` (:730): `timeout 10 bash -c '…' || rc=$?` then
`assert_eq "1" "$rc"`, plus `selftest_close_survives_corrupt_lease` (:528) where the
pool_die is contained by an inner `( … )` subshell inside a `timeout 15 bash` body.

## 6. spawn_sim_owner — DEFINED IN validate.sh, SHARED BY ALL SUITES

Location: **validate.sh:128–168** (the framework). release_reaper.sh / concurrency.sh /
transparency.sh get it by `source ./validate.sh` — it is NOT duplicated. (Per-suite
wrappers ARE local: `_test_spawn_owner` release_reaper.sh:155, `_transparency_spawn_owner`
transparency.sh:160 — copies of each other.)

```bash
spawn_sim_owner [SECONDS=600] [COMM=pi]     # echoes the PID of a LIVE process whose /proc/comm == COMM
```
Mechanics (:141–166): truncate COMM to 15 chars (TASK_COMM_LEN); `bin_dir="$(mktemp -d -t
abpool-pi.XXXXXX)"` (**dir prefix must stay `abpool-pi.`** — trap glob backstop depends on
it); `cp /usr/bin/sleep "$bin_dir/$COMM"`; run it `</dev/null >/dev/null 2>&1 &` (fd
detach is mandatory — consumed via `$(…)`); settle-loop polls `/proc/$pid/comm` up to 50×
`sleep 0.02` (fork→exec race); echo pid. `ABPOOL_SIM_BINS+=` is lost across the `$()`
subshell → only the trap's `rm -rf -- /tmp/abpool-pi.*` backstop reaps the bin dir.

**No numeric cap on simultaneous sim owners exists.** Discipline instead: default 600 s
lifetime; every body spawns its OWN owner(s) and kills+waits them (`_release_kill_owner_and_reap_zombie`,
release_reaper.sh:141–144: `kill "$pid" || true; wait "$pid" || true` — the `wait` reaps the
zombie so `/proc/<pid>` truly vanishes and `pool_owner_alive` cannot false-alive); single
`ABPOOL_CUR_OWNER` slot (last `_test_spawn_owner` wins; the runner's inter-body backstop
kills only that one — see release_reaper.sh:457).

**Owner-env hooks**: `AGENT_BROWSER_POOL_OWNER_PID` + `AGENT_BROWSER_POOL_OWNER_STARTTIME`
(set identity only; they do NOT fake the kernel process — hence a real sleep-named-"pi"
process). Harness set (O9): `AGENT_BROWSER_POOL_HARNESSES` (lib/pool.sh:209, default
`pi,claude,codex,agy,antigravity`) → `POOL_HARNESSES`.

## 7. COMPLETE selftest inventory (validate.sh)

| Line | Function | Purpose |
|---|---|---|
| 284 | selftest_assert_eq_passes | equality helper sanity |
| 289 | selftest_assert_eq_fails_correctly | mismatch → rc 1 without killing harness (nested subshell, inverted) |
| 297 | selftest_assert_no_dir_absent | assert_no_dir on absent path |
| 301 | selftest_empty_pool_lane_is_gone | fresh pool ⇒ no leases/dirs |
| 306 | selftest_lane_exists_after_write | lease-file presence assert ⭐ lease claims |
| 314 | selftest_sim_owner_is_alive_pi | setup's owner: /proc/comm==pi + `pool_owner_alive` accepts ⭐ owner hooks |
| 351 | selftest_owner_resolves_non_pi_harness | pos 'claude' resolves+alive / neg 'xterm' rejected ⭐⭐ owner resolve + O9 harness set; spawns+reaps own owners, inline `VAR=val pool_owner_resolve` override |
| 392 | selftest_admin_is_executable | bin/agent-browser-pool is `-x` |
| 405 | selftest_config_bool_truthy | `_pool_config_bool` truthy table ⭐ config parsing (pool_config_init helper) |
| 414 | selftest_config_bool_falsy | falsy table incl empty/no-arg |
| 433 | selftest_clean_args_is_close_cases | close-predicate truth table |
| 463 | selftest_close_marks_lease_disconnected | close flips connected true→false via pool_wrapper_main (mocked subshell) ⭐ lease writes |
| 499 | selftest_open_does_not_flip_connected | non-close leaves connected |
| 528 | selftest_close_survives_corrupt_lease | corrupt lease → pool_die contained by subshell ⭐ pool_die rc-assert |
| 560 | selftest_ensure_connected_rebinds_when_disconnected | connected=false forces rebind |
| 594 | selftest_ensure_connected_skips_rebind_when_connected | connected=true early-exits |
| 628 | selftest_ensure_connected_rejects_foreign_chrome_on_reconnect | identity gate, no rebind to foreign Chrome |
| 671 | selftest_ensure_connected_relaunch_passes_identity_args | relaunch passes 3 args to pool_wait_cdp |
| 730 | selftest_chrome_launch_eaddrinuse | EADDRINUSE detect → rc 1 not pool_die; negative case asserts pool_die rc ⭐ |
| 804 | selftest_launch_and_verify_repick_on_launch_fail | port re-pick path a |
| 838 | selftest_launch_and_verify_repick_on_cdp_timeout | port re-pick path b |
| 871 | selftest_real_bin_name_or_path | POOL_REAL_BIN bare-name/path/default resolution ⭐⭐ pool_config_init; **default-path assert**: `HOME="$tmp_home" bash -c '…pool_config_init; printf "%s\n" "$POOL_REAL_BIN"'` ⇒ `$tmp_home/.local/bin/agent-browser` with NO AGENT_BROWSER_REAL set |
| 896 | selftest_preflight_accepts_bare_name_on_path | preflight PATH-name pass / pool_die fail ⭐ subshell rc-assert |
| 919 | selftest_reap_orphan_dirs_removes_and_skips | orphan dir reap + skip leased + idempotent ⭐ lease claims |
| 947 | selftest_reap_orphan_dirs_kills_only_target_lane | kills only orphan lane (prefix collision); spawns 2 fake chromes, setsid, `kill -9 -- -pgid` ⭐ process discipline |
| 1025 | selftest_doctor_flags_disconnected_lease | doctor WARN on connected:false |
| 1057 | selftest_doctor_ss_optional_when_missing | missing `ss` is optional |
| 1106 | selftest_cdp_is_ours_uses_socket_owner | socket-owner identity (6 cases) |

**Imitate for new caller-scoped/pinning tests** (⭐⭐ first): `selftest_owner_resolves_non_pi_harness`
(own-owner spawn/reap + env override + capture-then-reap-then-assert),
`selftest_real_bin_name_or_path` (config-default assertions, temp-HOME subshells),
`selftest_preflight_accepts_bare_name_on_path` (rc-assert subshells),
`selftest_close_marks_lease_disconnected` (mocked body.sh in `timeout 15 bash` subshell),
`selftest_reap_orphan_dirs_kills_only_target_lane` (two controlled fake children + pgroup
kill/reap). Real acquire/lease-claim patterns live in release_reaper.sh
`_release_acquire_boot` (:119) and concurrency.sh `_concurrency_run_one_lane` (:167).

## 8. release_reaper.sh — the APPROVED single-setup runner (:440–467)

```bash
_abpool_run_release_reaper_suite() {
    local fn
    ABPOOL_PASS=0; ABPOOL_FAIL=0; ABPOOL_FAILED=()
    setup                                  # ★ the ONE AND ONLY setup() call   (:443)
    _release_kill_owner_and_reap_zombie "$AGENT_BROWSER_POOL_OWNER_PID"        # (:446 kill unused setup owner)
    ABPOOL_CUR_OWNER=""
    for fn in $(compgen -A function | grep '^test_' | sort); do                # (:448)
        printf '== %s\n' "$fn"
        if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
        else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
        "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true                    # (:456 inter-body backstop)
        [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _release_kill_owner_and_reap_zombie "$ABPOOL_CUR_OWNER"
        ABPOOL_CUR_OWNER=""
    done
    teardown                                                                   # (:460)
```

`_test_spawn_owner` (release_reaper.sh:155–173) — per-body owner, NOT shared:
`pid="$(spawn_sim_owner)"` → `st="$(_pool_get_starttime "$pid")"` →
`ABPOOL_CUR_OWNER="$pid"` → `export AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME` →
`pool_owner_resolve` (refresh globals in THIS shell — required when the lane is later
acquired via `N="$(…)"` subshell) → echo pid. Also `_release_setup_real_env` (:68): re-points
AGENT_CHROME_MASTER at the REAL read-only master + AGENT_BROWSER_REAL at the REAL
`~/.local/bin/agent-browser` (resolved via `getent passwd`, HOME is already clobbered) +
relocates the ephemeral root to a btrfs temp dir (tracked in `ABPOOL_SIM_BINS` for the trap).
Tests: `test_explicit_release_tears_down_lane` :177, `test_stale_reaper_reaps_dead_owner_lane`
:203 (two-owner X/Y flow), `test_reap_clears_crashed_owner_lane` :288,
`test_close_is_disconnect_only` :320, `test_close_then_rebind` :373.

## 9. concurrency.sh — REAL Chrome, two tests, PER-TEST runner

- `_concurrency_setup_master` (:77): real/btrfs/minimal master strategy + real
  `AGENT_BROWSER_REAL` + ephemeral root on btrfs (`mktemp -d -p … ephemeral.XXXXXX`,
  pre-emptively reaps stale roots); re-runs `pool_config_init`/`pool_state_init`.
- `test_n_agents_get_n_distinct_lanes` (:217–334): N=3 owners (setup's + 2 spawned); N
  parallel `( … ) &` subshells each with **subshell-scoped**
  `export AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME` (SC2030-silenced by design) running
  `_concurrency_run_one_lane`; join via per-PID `wait "$pid" || fail=1` (never bare `wait`);
  asserts N lanes, distinct owner.pid/port/chrome_pid (`_assert_all_distinct_and_nonzero`
  :200); cleanup `release all` + `assert_lane_gone` ×N + `assert_no_chrome` + explicit
  `rm -rf "$_concurrency_btrfs_root"` (subshell state loss ⇒ trap can't see it) + kill the
  N−1 extra owners.
- `test_n_provisional_lanes_are_distinct` (:368): Chrome-free N=4 provisional-acquire twin.
- Runner (:441): `if ! abpool_run_suite test_; then exit 1; fi` — the FRAMEWORK per-test
  runner ⇒ setup() runs once PER test_ ⇒ **exactly 2 calls today**.
- **Where a caller-mode two-child variant slots in**: a new function after
  `test_n_provisional_lanes_are_distinct` (ends :438, before the gate at :440–444). ⚠️ But a
  THIRD `test_` function makes abpool_run_suite call setup() a 3rd time ⇒ documented HANG.
  Options: (a) put a Chrome-free caller-mode test in validate.sh as `selftest_*`
  (auto-discovered by `_run_selftest_suite`, single setup — the plan/003-endorsed route,
  key_findings.md:51); (b) add it to concurrency.sh ONLY by converting that file to a
  release_reaper-style single-setup runner first; or (c) merge it into an existing body.
- Runtime markers: prior live runs measured the real-Chrome test at ~4.2 s (plan/001
  bugfix/001_af49e87213c6/P1M2T1S3/issue_feedback.md); PRP time budgets: 240 s
  concurrency, 300 s release_reaper, 180 s transparency, 120 s validate.

## 10. BLESSED INVOCATION (prior sessions; ALWAYS isolated sandbox + `timeout`)

```
timeout 900 bash test/<file>.sh                                   # generic (plan/001/P1M10T1S1/research/readme-facts.md:226)
timeout 120 bash test/validate.sh; echo rc=$?                      # expect rc 0 (plan/002/P2M5T1S1/PRP.md:543)
AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh; echo rc=$?   # (plan/002/P2M5T2S1/PRP.md:727)
AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh; echo rc=$?    # (plan/002/P2M5T3S1/PRP.md:558)
AGENT_CHROME_HEADLESS=1 timeout 300 bash test/release_reaper.sh; echo rc=$? # (plan/002/P2M5T3S1/PRP.md:559)
timeout 600 bash test/validate.sh                                 # (plan/003 bugfix P1M1T3S2/PRP.md:658)
```
The suites self-hermeticize (§3) but still boot REAL Chrome / use the REAL master +
agent-browser binary (§8) ⇒ run only in a container/bwrap/isolated temp tree, never the
shared sandbox. Output goes to stdout/stderr (harness prints `== name`, `PASS/FAIL`,
`N passed, M failed`); no tee/output-file convention exists in the PRPs.

plan/003 notes on selftest discipline: `plan/003_afc2f15931ab/architecture/test_code_map.md`
§4 (single-setup hard constraint, discovery snippet, reaping discipline; §5 = the approved
minimal-change recipe for a new selftest; §6's warning about transparency.sh's "pi ancestor"
literal is STALE — the current test greps `"supported agent harness"` (transparency.sh:534–537)).
`plan/003_afc2f15931ab/architecture/key_findings.md`:50–51 — concurrency.sh's 2-call per-test
runner is pre-existing; new selftests go in validate.sh's single-setup runner.

## 11. Static checks (run this session)

| File | `bash -n` | `shellcheck -s bash` |
|---|---|---|
| test/transparency.sh | OK | clean except SC1091 info (source not followed) |
| test/concurrency.sh | OK | clean except SC1091 info |
| test/release_reaper.sh | OK | clean except SC1091 info |
| test/validate.sh | OK | SC1091 info ×1 + SC2016 info ×4 (intentional single-quoted `bash -c` bodies) — zero warnings/errors |

## 12. Adding a NEW selftest to validate.sh — the recipe

1. Name it `selftest_*` — auto-discovered by `_run_selftest_suite`'s
   `compgen -A function | grep '^selftest_' | sort` (validate.sh:1182). **No registration.**
2. Place it above `_run_selftest_suite` (anywhere before :1178; convention: grouped with
   related tests, e.g. O9-style owner tests near :351).
3. It runs in the MAIN shell, ONE shared setup: use `$ABPOOL_TEST_ROOT` for scratch dirs,
   `$POOL_*` globals from setup; do NOT call setup()/teardown(); do NOT overwrite
   `ABPOOL_CUR_OWNER` (setup's pi owner must survive for selftest_sim_owner_is_alive_pi).
4. Spawn your own sim owners (`spawn_sim_owner [dur] [comm]`) and REAP before asserting:
   `kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true` — copy
   selftest_owner_resolves_non_pi_harness's capture→reap→assert ordering so an assert
   failure can never leak a process.
5. End every assert with `|| return 1` (the `if "$fn"` context is errexit-exempt).
6. Mock-based bodies: write `body.sh` under `$ABPOOL_TEST_ROOT`, run via
   `timeout 15 bash "$script" "$ABPOOL_REPO" … 2>&1) || rc=$?` + `assert_eq 0 $rc` — mocks
   stay scoped to the subshell (no leak into the shared suite).

## 13. Landmines

- **LM-1 (the headline):** `abpool_run_suite`/`run_test` call `setup()` PER test;
  the 3rd process-spawning setup() HANGS in the shared sandbox. concurrency.sh currently
  has exactly 2 `test_` bodies — a 3rd would hang it. Chrome-free new tests go in
  validate.sh as `selftest_*`; real-Chrome additions need a single-setup runner.
- **LM-2:** NEVER run bodies in `( … )` subshells inside a single-setup suite — the EXIT
  trap is inherited and would `rm -rf` the shared temp root mid-suite (use `if "$fn"`).
- **LM-3:** `ABPOOL_SIM_BINS+=` and any `+=` inside `$(…)` are lost in the parent — rely on
  the `/tmp/abpool-pi.*` and `/tmp/abpool-test.*` glob backstops; keep mktemp prefixes.
- **LM-4:** a killed child is a zombie until `wait`ed; `/proc/<pid>` lingers → false-alive.
  Always kill+wait owners. Never use `kill -0` for liveness (ESRCH vs EPERM conflation).
- **LM-5:** `pool_lease_field` / `pool_lanes_list` / `pool_owner_alive` return rc 1
  legitimately — always guard (`|| x=""`, `if`, `|| rc=$?`) or bare calls abort under set -e.
- **LM-6:** single-slot `ABPOOL_CUR_OWNER`: spawning a 2nd owner without killing the 1st
  orphans the 1st until its 600 s expiry.
- **LM-7:** comm is kernel-truncated to 15 chars; new harness names must be ≤15 or
  spawn_sim_owner silently truncates.
- **LM-8:** release_reaper/concurrency re-point env at the REAL master + agent-browser
  binary — hermetic only for POOL state, not for those host resources; don't "simplify"
  that away.