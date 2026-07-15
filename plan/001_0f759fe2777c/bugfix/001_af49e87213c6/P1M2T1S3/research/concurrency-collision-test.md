# Research: concurrency test collision-recovery exercise (P1.M2.T1.S3)

Date: 2026-07-14
Bugfix context: Issue 2 (concurrent port-allocation race). S3 is the THIRD of three
subtasks under P1.M2.T1. S1 (preceding, landed) makes `pool_chrome_launch` return 1 on an
EADDRINUSE instant-exit. S2 (preceding, "Implementing" in parallel) adds the port re-pick
retry in `_pool_launch_and_verify` + the `pool_boot_lane` lease-port re-read + the stale-
comment fix + two selftests. **S3 (THIS) is a TEST-ONLY change to `test/concurrency.sh`**:
remove the artificial 0.3s launch stagger so concurrent boots can collide, exercising S1+S2's
recovery under genuine concurrent load. No production code is touched.

---

## 1. THE CURRENT `test/concurrency.sh` (the file S3 edits)

Structure (all read this session; `wc -l` ≈ 414 lines):

| Element | Location | Role |
|---|---|---|
| `_concurrency_setup_master` | L31-148 | Override 3 host resources setup() doesn't provide (real master, btrfs ephemeral root, real agent-browser bin). Re-runs pool_config_init. Pre-emptively reaps stale btrfs roots. |
| `_concurrency_run_one_lane OWNER_PID OWNER_ST RESULT_FILE` | L150-193 | The per-agent body (runs in a `( … ) &` subshell): pool_owner_resolve → pool_acquire_locked (guarded) → pool_boot_lane (guarded) → write lane N to RESULT_FILE. Exits 1 on acquire/boot failure (writes 'FAIL'). |
| `_assert_all_distinct_and_nonzero VALUES…` | L195-215 | Associative-array dedup: every value non-empty, != "0"/"null", and unique. Used for owner.pid / port / chrome_pid distinctness. |
| **`test_n_agents_get_n_distinct_lanes`** | **L217-351** | **THE test S3 edits.** N=3. Spawns N distinct sim owners, launches N parallel acquire+boot subshells, asserts N distinct lanes/ports/chrome_pids, asserts clean release (no lanes, lanes gone, no Chrome). |
| `test_n_provisional_lanes_are_distinct` | L353-414 | A Chrome-free sanity test (provisional lanes, no boot). S3 does NOT edit it. |
| runner | bottom | `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then abpool_run_suite test_; fi` |

### The stagger (the S3 edit site) — `test_n_agents_get_n_distinct_lanes`, step (4)

Current text (L244-265), quoted verbatim for the PRP's `edit` oldText:

```
    # (4) Launch N parallel acquire+boot subshells. Each subshell OVERRIDES the owner env
    #     for ITSELF ONLY (subshell-scoped export → parent + siblings unaffected). They
    #     SHARE the temp pool state + lock file (inherited) → contend for the SAME flock.
    #     A ~0.3s stagger narrows the pool_find_free_port TOCTOU window (port is written to
    #     the lease BEFORE launch → later find_free_port calls see it claimed).
    for (( i = 0; i < N; i++ )); do
        (
            ...subshell-scoped export + _concurrency_run_one_lane...
        ) &
        bg_pids+=("$!")
        sleep 0.3   # narrow the port-allocation TOCTOU (research G2)
    done
```

**The two edit sites (and ONLY these two):**
- L247-248: the block comment explaining the stagger's rationale.
- L264: the `sleep 0.3   # narrow the port-allocation TOCTOU (research G2)` line.

### The assertions S3 KEEPS UNCHANGED (they already verify recovery worked)
- (5) `wait "$pid" || fail=1` per-PID join → "one or more parallel acquire+boot subshells failed" on any non-zero exit. **This is where a broken S2 recovery surfaces**: a colliding lane whose re-pick fails → `_concurrency_run_one_lane` exits 1 → `fail=1` → test FAILS.
- (7) `assert_eq "$N" "${#held_lanes[@]}"` — exactly N lanes held (no lane dropped).
- (8) `_assert_all_distinct_and_nonzero "${held_ports[@]}"` — all ports distinct + >0 (no two lanes share a port; a failed re-pick leaves port collisions or port=0).
- (8) `_assert_all_distinct_and_nonzero "${held_cpids[@]}"` — distinct Chrome PIDs.
- (9) cleanup: release all → 0 lanes remain → each lane gone → `assert_no_chrome` (scoped pgrep, no false-positive on the operator's daily Chrome).

So **S3's success criteria (a) all succeed, (b) distinct ports, (c) clean release are ALREADY
asserted.** S3 only removes the thing that PREVENTED collisions from ever happening.

---

## 2. THE S2 CONTRACT S3 CONSUMES (assume S2 lands exactly as its PRP specifies)

S3 is a pure consumer of S2's output (no production-code edits). The relevant S2 behavior:

`_pool_launch_and_verify PORT DIR LANE` (post-S2):
- Attempt 1 + Attempt 2 on the SAME port, each `pool_chrome_launch` now **guarded**
  (`if pool_chrome_launch …; then` — rc 1 = EADDRINUSE from S1 = fall-through, NOT a set-e abort).
- If both same-port attempts fail (launch rc 1 OR both CDP timeouts) → **port re-pick**
  (ONE retry, no loop): `pool_find_free_port` → `pool_lease_update "$lane" port "$new_port"`
  → `pool_chrome_launch "$new_port"` → `_pool_boot_write_chrome_ids` → `pool_wait_cdp "$new_port"`
  → return 0 on success, 1 on exhaustion/retry-failure.

`pool_boot_lane` (post-S2): after `_pool_launch_and_verify` returns 0, **re-reads the lease
port** (`pool_lease_field "$lane" port`) so the daemon connect (step e) uses the REAL bound
port, not the stale local `$port`. **This re-read is the reason S3's test can pass**: without
it, a re-picked port would be silently discarded and every colliding lane would drop.

**What this means for the test**: when two lanes race onto the same port, the loser's boot path
now (a) detects the EADDRINUSE (S1) or CDP failure, (b) re-picks a different port (S2), (c)
updates the lease (S2), (d) pool_boot_lane re-reads the lease and connects the daemon to the
new port (S2). The lane succeeds on a DIFFERENT port → `_assert_all_distinct_and_nonzero` on
held_ports passes. Pre-S2, the loser would `pool_die` (instant-exit) or hang ~60s then drop →
the test would FAIL. So removing the stagger makes the test a **meaningful gate for S1+S2**:
it FAILS if the recovery is broken (or absent) and a collision occurs.

---

## 3. COLLISION DYNAMICS + FLAKINESS ANALYSIS (the core design decision)

### Why the 0.3s stagger existed
Per `key_findings.md` Issue 2 + the comment at L247: `pool_find_free_port` runs OUTSIDE the
acquire flock (deliberately, PRD §2.19 — concurrent boots parallelize). Its anti-collision
mechanism is "write the chosen port to the lease BEFORE launch" (pool_boot_lane step b). But
there's a TOCTOU window between `pool_find_free_port` (read) and the lease write — two
concurrent acquires can both pick the same port. The 0.3s stagger serialized the boots enough
that lane N's lease write completed before lane N+1's `pool_find_free_port` ran → no collision.

### What removing the stagger does
With no stagger, all N subshells fork in a tight loop. `pool_acquire_locked` is serialized by
the flock (lanes claimed one at a time), but `pool_boot_lane` (find_free_port + lease write +
Chrome launch) runs in PARALLEL post-flock. The critical window is [lane N find_free_port] →
[lane N lease write] (a few jq ops, ~5-20ms host-dependent). Lane N+1's find_free_port can
land in this window → both pick the same lowest free port → **collision**. Without the stagger,
collisions become PROBABLE (not guaranteed — it's a race), exercising S1+S2's recovery.

### The 3-way collision risk (the flakiness concern)
With N=3 and no stagger, all 3 lanes can enter the initial collision window simultaneously:
all 3 pick port P0. Then the two losers re-pick. The re-pick path ALSO has a TOCTOU window
(`pool_find_free_port` → `pool_lease_update`, adjacent but not atomic). If both losers call
`pool_find_free_port` before either writes its new port → both pick P1 → one binds P1, the
other's re-pick launch fails (EADDRINUSE again) → that lane has EXHAUSTED its one re-pick →
returns 1 → lane dropped → **test FAILS despite correct S1+S2 code**.

This is the residual flakiness. It is RARE (requires a tight 3-way + 2-way re-pick
interleaving) but non-zero. The item explicitly anticipates it:
> "If the stagger cannot be fully removed (e.g., the test becomes flaky due to other timing
> issues), reduce it to a smaller value (e.g., 0.05s) that still allows collision but is less
> artificial."

### Design decision: REMOVE is primary; a MINIMAL stagger is the documented fallback
- **REMOVE the stagger entirely** (delete the `sleep 0.3` line). This is the cleanest way to
  "exercise collision recovery" — it removes the artificial AVOIDANCE. It is host-independent
  (always allows collisions, unlike a fixed small delay whose effect depends on host speed).
  With N=3 the 3-way flake risk is low; the test is a regression gate run repeatedly, so a
  rare false-fail surfaces as intermittent CI noise, not a blocker.
- **FALLBACK (only if remove proves persistently flaky on a host)**: re-introduce a MINIMAL
  stagger. CAUTION: the boot-path window is ~5-20ms, so a "small" value like 0.05s (50ms) is
  likely TOO LARGE — it would let lane N's lease write complete before lane N+1's find_free_port
  → NO collision → the test stops exercising recovery (back to the pre-S3 state). A genuinely
  collision-permitting fallback must be SMALL (e.g. `sleep 0.005`–`sleep 0.01`, i.e. 5-10ms) —
  smaller than the boot window so collisions still occur, but with enough separation to reduce
  the 3-way pile-up. This is inherently host-dependent and fragile; prefer REMOVAL. Fractional
  sleep is supported here (validate.sh:138 already uses `sleep 0.02`; GNU coreutils).

### Why NOT add a "collision occurred" assertion
S1 logs `_pool_log "pool_chrome_launch: Chrome exited immediately (port $port may be in use)"`
and S2 logs `_pool_log "_pool_launch_and_verify: re-picked port $new_port for lane $lane (was
$port)"` to the pool log (`_pool_log_path()`). One COULD grep the log to assert a re-pick
happened. **Do NOT**: a race is probabilistic — on a given run NO collision may occur (the
window was missed), and a "collision MUST happen" assertion would make the test flaky in the
opposite direction (false-fail when no collision occurred). The item's success criteria are
explicitly (a) all succeed, (b) distinct ports, (c) clean release — NOT "a collision happened."
The test EXERCISES the recovery path (by allowing collisions) and VERIFIES the OUTCOME; it
does not need to PROVE a collision occurred. This is the correct design for a probabilistic
regression gate.

---

## 4. AGENTS.md COMPLIANCE (this is a REAL-CHROME integration test)

S3's change (remove a `sleep` + edit a comment) does NOT alter the test's process model — it
keeps the existing, already-compliant structure. But the PRP must re-state the requirements
because the implementer WILL run this test (real Chrome) during validation:

- **§1 isolated sandbox**: the test ALREADY hermetic-isolates via validate.sh `setup()` (mktemp
  HOME/state/ephemeral/master) + `_concurrency_setup_master` (relocates the ephemeral root to
  btrfs under the real $HOME, reuses/creates a real master, resolves the real agent-browser
  bin). The implementer must run it under the same isolation (do NOT run against the operator's
  live HOME/Chrome). S3's edit doesn't touch any of this.
- **§2 hard timeout on every subprocess**: the test has NO top-level `timeout` wrapper. The
  implementer MUST run it bounded: `timeout 300 bash test/concurrency.sh` (each pool_wait_cdp
  is internally 30s; N=3 parallel boots + cleanup fits comfortably under 300s). During
  RESEARCH/planning (this PRP creation), NO real Chrome was launched — only static reads.
- **§3 reap what you spawn**: the test ALREADY reaps — the body kills the N-1 extra sim owners
  (step 10), `release all` kills the Chrome pgroups, `_concurrency_setup_master` reaps the
  btrfs root (step 9b + pre-emptive), teardown runs `release all` + the EXIT trap removes all
  temp roots + sim-owner bin dirs. S3's edit (removing a sleep) does NOT add any process.
- **§4 single-setup + accumulation**: `abpool_run_suite` calls `run_test` per `test_*` fn, and
  `run_test` calls `setup()` (which spawns ONE sim owner via `spawn_sim_owner`). concurrency.sh
  has 2 `test_*` fns → 2 `setup()` calls. AGENTS.md §4 warns setup "is known to hang on the
  3rd call in a shared sandbox." **2 calls is under the threshold, AND the test runs in an
  ISOLATED sandbox (§1) where the hang does not occur.** S3 does NOT change the runner or the
  number of tests → the per-test-setup count is unchanged. Do NOT refactor the runner (out of
  scope; the item calls the existing structure the contract). If a hang IS observed, follow
  §4's single-setup guidance as a SEPARATE concern — not in S3's scope.
- **§4 EXIT-trap-in-subshell hazard**: `run_test` runs the body in `( set -e; "$fn" )` (a
  subshell). The framework's EXIT trap (main shell) removes `ABPOOL_TEST_ROOTS`. The body's
  subshell does NOT fire the EXIT trap mid-suite (the trap is inherited but the subshell EXIT
  is the `( … )` close, not the script EXIT). The concurrency body reaps its OWN btrfs root
  explicitly (step 9b) precisely BECAUSE the framework trap can't see subshell-created state.
  S3's edit doesn't touch this. Removing the sleep does NOT move any state across the boundary.
- **§4 kill -0 / liveness**: `assert_no_chrome` uses a scoped `pgrep` (not kill -0). Unchanged.
- **§5 read-only files**: S3 edits ONLY `test/concurrency.sh`. Not PRD/tasks/prd_snapshot/gitignore.

**Net**: S3 is a 2-line-ish edit (remove sleep + rewrite comment). The hard part is the
VALIDATION (running a real-Chrome test safely), which the PRP's Validation Loop governs.

---

## 5. SCOPE BOUNDARIES (what S3 does NOT touch)

| Concern | S1 | S2 | S3 (THIS) |
|---|---|---|---|
| pool_chrome_launch EADDRINUSE detect | ✅ | — | — |
| _pool_launch_and_verify re-pick + pool_boot_lane re-read | — | ✅ | — |
| stale-comment fix in lib/pool.sh | — | ✅ | — |
| validate.sh selftests for the re-pick | — | ✅ | — |
| **test/concurrency.sh stagger removal + comment** | — | — | **✅** |

S3 does NOT touch:
- Any production code (`lib/pool.sh`, `bin/*`). S3 is test-only.
- `test/validate.sh`, `test/release_reaper.sh`, `test/transparency.sh`.
  - **NOTE `test/transparency.sh:195` has its own `sleep 0.3`** — it is a POLLING-LOOP sleep
    (`while …; pool_lease_find_mine …; sleep 0.3; done`), NOT a launch stagger. It has NOTHING
    to do with the port-collision TOCTOU. **DO NOT touch it** (different purpose, different
    file, out of scope). The same applies to the `sleep 0.4`/`sleep 0.5` in release_reaper.sh
    (process-death/reap settling) — all unrelated.
- The concurrency test's assertions (steps 5-10), the runner, `_concurrency_setup_master`,
  `_concurrency_run_one_lane`, `_assert_all_distinct_and_nonzero`, or the provisional-lane test.
- N (keep N=3).

---

## 6. SOURCES

- `test/concurrency.sh` (full read this session — structure, the stagger at L247-248+L264, the
  assertions at steps 5-10, the cleanup at steps 9-10).
- `plan/…/architecture/key_findings.md` ISSUE 2 (root cause: find_free_port TOCTOU outside the
  flock; the 0.3s stagger is a TEST mitigation, not a code fix; Fix Approach #4 = "Update the
  concurrency test to exercise collision recovery (reduce/remove stagger).") + Testing
  Architecture Notes (Chrome-requiring tests follow AGENTS.md §1-§6; concurrency.sh = single-
  setup with 0.3s stagger).
- `plan/…/P1M2T1S2/PRP.md` (S2 contract: _pool_launch_and_verify re-pick, pool_boot_lane
  lease-port re-read, the stale-comment fix) + `P1M2T1S2/research/launch-and-verify-repick.md`.
- `plan/…/P1M2T1S1/PRP.md` (S1 contract: pool_chrome_launch return-1-on-EADDRINUSE).
- `test/validate.sh` (run_test/abpool_run_suite single-setup-ish runner; setup spawns one sim
  owner per test; assert_no_chrome uses scoped pgrep; fractional `sleep 0.02` already in use).
- `lib/pool.sh:39` `_pool_log` (writes to `_pool_log_path()`; S1/S2 log re-pick/EADDRINUSE here
  — usable for debugging but NOT for a required assertion, §3).
- AGENTS.md §1-§6 (isolated sandbox, hard timeouts, reap, single-setup, kill -0 trap, scope).
