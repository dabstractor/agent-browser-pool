# Test Code Map — Delta 003 (Multi-Harness Owner Resolution)

Static research only. No tests run, no Chrome booted (AGENTS.md §1). All line numbers exact
against the current tree.

---

## 1. `spawn_sim_owner` in `test/validate.sh` (lines 103–140)

### Signature
```bash
spawn_sim_owner [SECONDS]        # SECONDS default 600
# echoes the PID of a LIVE process whose /proc/comm == "pi"
```
**The comm name is HARDCODED to `"pi"` — there is NO comm-name argument.** The only parameter
is the sleep duration (`$1`, default `600`).

### How it simulates a `"pi"`-comm owner
1. `mktemp -d -t abpool-pi.XXXXXX` → temp bin dir (validate.sh:121).
2. `bin="$bin_dir/pi"` — executable literally named `pi` (validate.sh:122).
3. `cp /usr/bin/sleep "$bin"` (validate.sh:123).
4. `"$bin" "$dur" </dev/null >/dev/null 2>&1 &` execs it (validate.sh:130). Kernel sets
   `/proc/$pid/comm` to the **basename of the executed ELF** = `"pi"`.
5. Poll loop (validate.sh:134–137) waits for fork→execve race to settle.

### Reaping
Temp bin dir tracked in `ABPOOL_SIM_BINS+=`. NOTE: that `+=` runs inside `$(…)` subshells so it
is LOST in the parent; trap's per-element loop is a no-op for them, so trap has a **glob
backstop** `rm -rf -- /tmp/abpool-pi.*` (validate.sh:170–171). **Any generalized bin-naming
must keep the `mktemp -d -t abpool-pi.XXXXXX` PREFIX (dir name, not bin name) so the backstop
stays valid.**

---

## 2. `selftest_sim_owner_is_alive_pi` in `test/validate.sh` (lines 293–307)

```bash
selftest_sim_owner_is_alive_pi() {
    local pid comm
    pid="$AGENT_BROWSER_POOL_OWNER_PID"          # set by setup via spawn_sim_owner
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    assert_eq "pi" "$comm" "simulated owner /proc comm"
    pool_owner_alive "$pid" "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-0}" "pi" \
        || { _fail "pool_owner_alive rejected the simulated live owner"; return 1; }
}
```
- Does **NOT** call `spawn_sim_owner` itself — reads `AGENT_BROWSER_POOL_OWNER_PID` (setup populates it).
- Does **NOT** call `pool_owner_resolve`. Calls `pool_owner_alive` DIRECTLY with hardcoded `"pi"`.
- Runs under the **single-setup** selftest runner (`_run_selftest_suite`, validate.sh:693–724).

---

## 3. ALL references across `test/*.sh`

### `test/validate.sh`
| Lines | Reference |
|-------|-----------|
| 10 | header: `owner simulation: spawn_sim_owner (a REAL process whose /proc/comm=="pi")` |
| 103–140 | `spawn_sim_owner()` definition |
| 165–171 | cleanup trap: `rm -rf -- /tmp/abpool-pi.*` backstop |
| 181–200 | `setup()`: spawns ONE `"pi"`-comm owner (line 197), exports owner env |
| 293–307 | `selftest_sim_owner_is_alive_pi()` |
| 306 | direct `pool_owner_alive "$pid" … "pi"` call |
| 693–724 | `_run_selftest_suite()` single-setup runner |

### `test/release_reaper.sh`
| Lines | Reference |
|-------|-----------|
| 43–44 | sources validate.sh for `spawn_sim_owner` |
| 148–171 | `_test_spawn_owner()`: `pid="$(spawn_sim_owner)"` (157), `pool_owner_resolve` (170) |
| 220–221 | comment: zombie may still read comm="pi" → false-alive |
| 235–245 | test (b): spawns owner Y via `spawn_sim_owner` (238), `pool_owner_resolve` (245) |
| 330–366 | `_abpool_run_release_reaper_suite()`: single-setup runner |

### `test/concurrency.sh`
| Lines | Reference |
|-------|-----------|
| 7, 19–20 | sources validate.sh for `spawn_sim_owner` |
| 160, 174 | `_concurrency_run_one_lane()`: `pool_owner_resolve` (174) |
| 226–234 | test 1: spawns N `"pi"`-comm owners via `spawn_sim_owner` (233) |
| 380–397 | test 2: spawns N `"pi"`-comm owners (383), `pool_owner_resolve` (396) |

### `test/transparency.sh`
| Lines | Reference |
|-------|-----------|
| 38 | sources validate.sh for `spawn_sim_owner` |
| 117, 121 | `pool_owner_resolve` (121) |
| 137–140 | comment: zombie `/proc/PID` + comm may still read "pi" |
| 148–169 | `_transparency_spawn_owner()`: `spawn_sim_owner` (162), `pool_owner_resolve` (167) |
| **498–532** | **`test_driving_no_pi_ancestor_fails_fast()`: polls for the LITERAL `"pi ancestor"` in pool_die message (line 528). ⚠️ WILL BREAK when R3 changes the message text.** |
| 534–575 | `_abpool_run_transparency_suite()`: single-setup runner |

### Summary
- `spawn_sim_owner` call sites: validate.sh:197, release_reaper.sh:157 + :238,
  concurrency.sh:233 + :383, transparency.sh:162. **All 6 callers take ZERO comm arg.**

---

## 4. Test framework structure

### File topology
```
test/validate.sh        — the FRAMEWORK: assertions + spawn_sim_owner + setup/teardown + runner + selftest_*
test/release_reaper.sh  — SOURCES validate.sh; own single-setup runner; test_* (real Chrome)
test/concurrency.sh     — SOURCES validate.sh; uses abpool_run_suite test_  (real Chrome)
test/transparency.sh    — SOURCES validate.sh; own single-setup runner; test_* (real Chrome)
```

### How `setup()` is called — SINGLE-SETUP (HARD constraint)
`setup()` (validate.sh:175–200) **spawns a real process**. AGENTS.md §4: a process-spawning
`setup()` called per-test HANGS this sandbox on the 3rd call. Therefore **no suite uses the
per-test runner** for selftests:
- `validate.sh` selftest → `_run_selftest_suite()` (693–724): ONE `setup()`, then each
  `selftest_*` runs via `if "$fn"; then …` in the MAIN shell (NO subshell ⇒ EXIT trap never
  fires mid-suite). ONE `teardown()`. Inter-body backstop: `rm -f "${POOL_LANES_DIR:?}/"*.json`.

### How selftests are discovered (validate.sh)
```bash
setup                                  # ★ the ONE AND ONLY setup() call
for fn in $(compgen -A function | grep '^selftest_' | sort); do
    if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); ...
    else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ...
    rm -f -- "${POOL_LANES_DIR:?}/"*.json 2>/dev/null || true
done
teardown
```
A new `selftest_*` is auto-discovered by `compgen | grep` — **no registration needed**.

### Reaping discipline
- `setup()` exports `ABPOOL_CUR_OWNER` (validate.sh:199).
- EXIT/INT/TERM trap (validate.sh:154–172): kills `ABPOOL_CUR_OWNER`, globs `ABPOOL_SIM_BINS`,
  globs `ABPOOL_TEST_ROOTS`, plus backstops `rm -rf -- /tmp/abpool-test.*` and `rm -rf -- /tmp/abpool-pi.*`.
- release_reaper.sh adds `_release_kill_owner_and_reap_zombie` (130–144): `kill` then `wait`
  (reaps zombie so `/proc/PID` vanishes — critical so `pool_owner_alive` does not false-alive).

---

## 5. MINIMAL change to generalize `spawn_sim_owner` + new selftest (R4)

### 5a. Generalize `spawn_sim_owner` (comm arg as SECOND positional, default `pi`)
Keeps `$1` = duration (all 6 existing callers unchanged). Make comm the 2nd positional:
```bash
spawn_sim_owner() {
    local dur="${1:-600}" comm_name="${2:-pi}" bin_dir bin pid comm tries
    bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"      # KEEP prefix (trap backstop)
    bin="$bin_dir/$comm_name"
    cp -- /usr/bin/sleep "$bin"
    chmod +x -- "$bin"
    "$bin" "$dur" </dev/null >/dev/null 2>&1 &
    pid="$!"
    tries=0
    while (( tries++ < 50 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [[ "$comm" == "$comm_name" ]] && break
        sleep 0.02
    done
    ABPOOL_SIM_BINS+=("$bin_dir")
    printf '%s\n' "$pid"
}
```
**Backward-compatible:** all 6 callers unchanged (`$2` defaults `"pi"`). **Keep `mktemp -d -t
abpool-pi.XXXXXX` prefix** so the trap's `/tmp/abpool-pi.*` glob backstop stays valid. 15-char
`TASK_COMM_LEN`: default set `pi,claude,codex,agy,antigravity` all ≤15 — fine.

### 5b. New `selftest_owner_resolves_non_pi_harness` (auto-discovered)
Runs in single-setup runner. Spawns/reaps its OWN non-pi owner. Positive case proves a non-pi
harness resolves + `pool_owner_alive` accepts it; negative case proves a non-harness comm is
rejected. **Depends on R2 making TEST MODE record the actual comm** (pool.sh:514).

---

## 6. ⚠️ Residual risk: transparency.sh:528

`test_driving_no_pi_ancestor_fails_fast()` (transparency.sh:498–532) polls for the literal
substring `"pi ancestor"` in the pool_die message (line 528). **R3 changes the message wording**
(→ "supported agent harness"). This test WILL BREAK if R3 lands without updating it. This is
OUTSIDE the R4 test-file scope but in the blast radius — **must be updated as part of R3/R5**
(match the new message text: `"supported agent harness"`).
