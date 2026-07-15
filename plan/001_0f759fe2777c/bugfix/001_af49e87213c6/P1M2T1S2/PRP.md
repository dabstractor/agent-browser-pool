# PRP — P1.M2.T1.S2: Add port re-pick retry in _pool_launch_and_verify + fix stale comment

> **Bugfix context**: This subtask fixes the SECOND half of **Issue 2** (concurrent
> port-allocation race) from
> `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` §"ISSUE 2"
> (Fix Approach #2 + #3). It is a **behavior + test** fix (Mode A — the only doc updates
> are inline comments in `lib/pool.sh`). The repo is no longer greenfield; `lib/pool.sh` is
> ~4431 LOC and fully implemented. This is the SECOND of three subtasks under P1.M2.T1:
> **S1** (preceding, "Implementing") made `pool_chrome_launch` return 1 on an EADDRINUSE
> instant-exit (instead of `pool_die`); **S2** (THIS) wires the caller `_pool_launch_and_verify`
> to catch that return-1 + the existing CDP-timeout path, **re-pick a different port**, and
> retry once; **S3** (later) updates the concurrency test. S2's contract is scoped to
> `_pool_launch_and_verify` + a REQUIRED `pool_boot_lane` integration fix + the stale
> comment + two selftests. It does NOT touch `pool_chrome_launch` (S1) or `test/concurrency.sh` (S3).

---

## Goal

**Feature Goal**: Make the Chrome boot path **resilient to a lost port race** (Issue 2).
When `_pool_launch_and_verify` fails to get CDP on the chosen port — either because
`pool_chrome_launch` returned 1 (EADDRINUSE, detected by S1) OR because both same-port
CDP-timeout retries failed — it must **re-pick a different port via `pool_find_free_port`**,
update the lease, and retry launch+wait ONCE on the new port. Limit to ONE re-pick (no loop).
This converts a fatal lane-drop (and a ~60s hang-then-crash for the colliding agent) into a
transparent recovery, satisfying PRD §1.3 Goal 3 (no two agents share a Chrome) and §2.18
("all release cleanly") under genuine concurrent load (no test stagger).

This is the literal implementation of Issue 2 Fix Approach #2: *"In `_pool_launch_and_verify`,
after any launch failure, call `pool_find_free_port` (which will exclude the current port
since it's in the lease) and retry with the new port. Limit to one port re-pick."*

**Deliverable** (all in-place edits to `lib/pool.sh` + `test/validate.sh`):
1. `lib/pool.sh` `_pool_launch_and_verify` (lines ~2128-2207) — **guard both `pool_chrome_launch`
   calls** with `if …; then` (catch S1's return-1 instead of aborting under `set -e`) and
   **add the port re-pick block** at the end (reached by fall-through from the three trigger
   points: attempt-1 launch rc 1, attempt-2 launch rc 1, both same-port CDP timeouts). ONE
   re-pick, no loop. Update the function's docstring.
2. `lib/pool.sh` `pool_boot_lane` (lines ~2208-2310) — **REQUIRED integration fix**: after
   `_pool_launch_and_verify` returns 0, re-read the (possibly re-picked) port from the lease
   so the daemon connect (step e) + provisioned log (step f) use the REAL bound port, not the
   stale local `$port`. (Without this, a successful re-pick is silently discarded — the daemon
   connects to the old port and the lane is dropped.)
3. `lib/pool.sh` — **fix the stale "retries on EADDRINUSE" comments** at the
   `pool_find_free_port` section banner (~line 1330) and the GOTCHA (~lines 1377-1379) to
   accurately name `_pool_launch_and_verify`'s re-pick as the real mitigation.
4. `test/validate.sh` — **add two `selftest_*` bodies** (path-a: launch-fail re-pick;
   path-b: CDP-timeout re-pick) that mock `pool_chrome_launch`/`pool_wait_cdp`/`pool_find_free_port`
   in a `bash -c` subshell (scoped — no leakage to other selftests; no real Chrome) and assert
   `_pool_launch_and_verify` returns 0 + the lease holds the new port.

**Success Definition**:
- After `source lib/pool.sh; pool_config_init`, with mocked `pool_chrome_launch` returning 1 on
  port 53420 and 0 on 53421, `_pool_launch_and_verify 53420 <dir> 7` returns **0** and the lane-7
  lease's `port` field == **53421** (verified by the selftest).
- With `pool_chrome_launch` always returning 0 but `pool_wait_cdp` returning 1 on 53430 and 0 on
  53431, `_pool_launch_and_verify 53430 <dir> 8` returns **0** and the lease `port` == **53431**
  (both same-port CDP timeouts trigger the re-pick).
- If `pool_find_free_port` returns 1 (exhausted) OR the re-pick launch/wait fails,
  `_pool_launch_and_verify` returns **1** (caller drops the lane) — verified by the negative cases.
- The unguarded `pool_chrome_launch` calls are GONE (both wrapped in `if …; then`); a post-S1
  return-1 no longer aborts under `set -euo pipefail`.
- `pool_boot_lane` re-reads the lease port after a successful `_pool_launch_and_verify`, so a
  re-picked port flows through to `pool_daemon_connect` (the stale-local-port bug is fixed).
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean (project gate).
- `bash test/validate.sh` exits 0 with the two new selftests passing alongside the existing blocks.
- `pool_chrome_launch` (S1's scope) is UNCHANGED by S2; `test/concurrency.sh` (S3's scope) UNCHANGED.

## User Persona

**Target User**: `pi` agents acquiring lanes concurrently. Two `pi` agents that invoke
`agent-browser open <url>` within the same millisecond (before either's `pool_boot_lane` writes
its port to the lease — the TOCTOU window) can both `pool_find_free_port` the same lowest free
port. TODAY (pre-S1+S2), the colliding agent's Chrome either instant-exit-`pool_die`s (fatal) or
hangs ~60s (two 30s CDP timeouts on the same colliding port) then `pool_die`s. After S1+S2, the
colliding agent detects the bind failure, re-picks a different port, and succeeds — transparently.

**Use Case**: N `pi` agents concurrently acquire lanes (no stagger — real production load, unlike
the test's 0.3s stagger). Two race onto port 53420. Agent A binds 53420; Agent B's launch fails
(EADDRINUSE → S1 returns 1, or CDP never answers → `pool_wait_cdp` rc 1). S2 catches the failure,
`pool_find_free_port` now sees 53420 claimed by A's lease → returns 53421, S2 updates B's lease to
53421, relaunches, and B succeeds on 53421. No agent crashes.

**User Journey** (post-S1+S2): `pi` agent B → `agent-browser open` → `pool_boot_lane` →
`pool_find_free_port`=53420 (raced with A) → lease port=53420 → `_pool_launch_and_verify 53420` →
launch rc 1 (S1: EADDRINUSE) OR wait_cdp rc 1 (×2) → **S2: `pool_find_free_port`=53421 → lease
port=53421 → launch 53421 → wait_cdp 53421 rc 0 → return 0** → `pool_boot_lane` re-reads
port=53421 → `pool_daemon_connect abpool-7 53421` → lane provisioned → `exec` driving command.

**Pain Points Addressed**:
- **Fatal crash / 60s hang on a recoverable port collision** (Issue 2): a transient race that
  should be a silent retry becomes a process-killing failure. S2 completes the recovery S1 began.
- **PRD §1.3 Goal 3 (mutual exclusion / no-collision) + §2.18 ("all release cleanly")**: under
  genuine concurrent load (no test stagger), a collision must not crash an agent.
- **The stale "retries on EADDRINUSE" comment** promises a mitigation that, before S1+S2, did not
  exist. S2 makes the mitigation real AND fixes the comment to name the actual mechanism.

## Why

- **Issue 2 (Major)** from the validation report. S2 is the recovery half: S1 produces the
  retryable signal (return 1); S2 consumes it (re-pick + retry). Without S2, S1's return-1 would
  ABORT the caller under `set -e` (the calls are currently unguarded) — S1 alone is inert/broken
  until S2 wires the caller.
- **The re-pick is bounded and cheap**: ONE retry on a different port (no loop). `pool_find_free_port`
  already excludes ports claimed by leases (incl. our current port, written by `pool_boot_lane`
  step b), so the new port is guaranteed different from the colliding one. The expensive Chrome
  launch still happens post-flock (PRD §2.19) — S2 adds at most one extra launch per colliding
  agent, only on the failure path.
- **The `pool_boot_lane` integration fix is REQUIRED, not optional**: the item's OUTPUT contract
  is "the lease's port field is updated to the new port." That output is only meaningful if the
  caller reads it. `pool_boot_lane` step e (`pool_daemon_connect "abpool-$lane" "$port"`) uses the
  STALE local `$port`; without the re-read, a successful re-pick is silently discarded (daemon
  connects to the old port → lane dropped). The 4-line re-read is the minimal change that makes
  S2's deliverable actually function end-to-end. S1 does NOT touch `pool_boot_lane` → no conflict.
- **The control flow is host-verified** (research §6): a mock-based scratch test of the exact
  designed `_pool_launch_and_verify` passed all four scenarios (path-a re-pick, path-b re-pick,
  exhaustion→1, re-pick-failure→1) against real lease files. The fall-through structure (nested
  `if pool_chrome_launch; then … fi` → shared re-pick block) is proven correct.

## What

User-visible behavior: a `pi` agent whose Chrome loses a port race will, after S1+S2, transparently
retry on a different port instead of crashing/hanging. Observable contract for
`_pool_launch_and_verify`:

| Trigger | Behavior | Return | Lease port |
|---|---|---|---|
| Attempt-1 launch rc 0 + wait_cdp rc 0 | success | 0 | unchanged (orig) |
| Attempt-1 launch rc 0, wait rc 1 → attempt-2 launch rc 0 + wait rc 0 | success | 0 | unchanged (orig) |
| Attempt-1 launch rc 1 (EADDRINUSE, S1) | re-pick → launch+wait on new port | 0 (success) or 1 (retry fail) | updated to new (if re-pick ran) |
| Attempt-2 launch rc 1 (EADDRINUSE, S1) | re-pick → launch+wait on new port | 0 or 1 | updated to new |
| Both same-port CDP timeouts (path b) | re-pick → launch+wait on new port | 0 or 1 | updated to new |
| `pool_find_free_port` rc 1 (exhausted) on re-pick | give up | 1 | unchanged |
| Re-pick launch rc 1 OR wait rc 1 | give up | 1 | updated to new (lease updated before the failed retry) |

`pool_boot_lane`: after `_pool_launch_and_verify` rc 0, the local `$port` is re-read from the
lease (so step e `pool_daemon_connect` + step f log use the real bound port).

### Success Criteria

- [ ] `_pool_launch_and_verify` wraps BOTH `pool_chrome_launch` calls in `if pool_chrome_launch …; then`
  (a return-1 falls through to the re-pick; it does NOT abort under `set -e`).
- [ ] `_pool_launch_and_verify` adds a port re-pick block (AFTER the same-port retry logic) that:
  calls `pool_find_free_port` (guarded `if ! new_port="$(…)"`); on rc 0 updates the lease via
  `pool_lease_update "$lane" port "$new_port"`; relaunches `pool_chrome_launch "$new_port" …` +
  `_pool_boot_write_chrome_ids "$lane"` + `pool_wait_cdp "$new_port"`; returns 0 on success, 1 on
  `pool_find_free_port` exhaustion OR retry failure.
- [ ] Exactly ONE re-pick (no loop) — the re-pick block is reached at most once per call.
- [ ] `pool_boot_lane` re-reads the port from the lease (`pool_lease_field "$lane" port`) after
  `_pool_launch_and_verify` returns 0, guarded so a failed re-read keeps the original `$port`.
- [ ] The stale comments at the `pool_find_free_port` section banner (~1330) and GOTCHA (~1377-1379)
  no longer say "retries on EADDRINUSE"; they name `_pool_launch_and_verify`'s re-pick as the mitigation.
- [ ] `_pool_launch_and_verify` docstring documents the re-pick (the two trigger paths, the ONE-re-pick
  limit, the lease-port update, the S1 return-1 contract).
- [ ] `validate.sh` has two new selftest bodies (path-a + path-b) that mock the three functions in a
  `bash -c` subshell and assert rc 0 + lease port == new port.
- [ ] `pool_chrome_launch` (S1's scope) is UNCHANGED by S2; `test/concurrency.sh` (S3's scope) UNCHANGED.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean.
- [ ] `bash -n test/validate.sh` clean; `shellcheck -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 with the two new selftests passing.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP quotes the EXACT current `_pool_launch_and_verify` body
(verbatim, line-cited), gives the verified replacement with the fall-through control flow
(host-proven across 4 scenarios), quotes the exact `pool_boot_lane` step-c+d→e region + the 4-line
re-read fix, quotes the exact stale-comment text + the replacement wording, specifies the exact
selftest design (subshell-scoped mocks mirroring S1's landed `selftest_chrome_launch_eaddrinuse`),
cites the S1 contract (return-1-on-EADDRINUSE), and lists the precise validation commands (all
mock-based, no real Chrome). No prior exposure to `lib/pool.sh` beyond the quoted snippets is needed.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: ISSUE 2 — root cause (pool_find_free_port TOCTOU outside the flock; the stale "retries on
        EADDRINUSE" comment at lines 1330/1377-1379 is inaccurate), the exact Fix Approach #2
        ("In _pool_launch_and_verify, after any launch failure, call pool_find_free_port … retry
        with the new port. Limit to one port re-pick.") + #3 ("Fix the stale comment").
  pattern: 'Fix Approach #2 is the literal spec for _pool_launch_and_verify; #3 is the stale-comment fix.'
  gotcha: 'key_findings Fix Approach #1 (pool_chrome_launch EADDRINUSE grep) is S1 (preceding);
        #2+#3 are S2 (THIS); #4 (concurrency test) is S3. S2 does NOT touch pool_chrome_launch.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S1/PRP.md   # S1 — the CONTRACT
  why: S1 (preceding, "Implementing") makes pool_chrome_launch return 1 on an EADDRINUSE
        instant-exit (grep the log; return 1; keep pool_die for non-EADDRINUSE). S1's return
        contract: rc 0 → launched+globals set; rc 1 → EADDRINUSE (retryable); pool_die → fatal.
        S1 touches ONLY pool_chrome_launch + its docstring + selftest_chrome_launch_eaddrinuse —
        DISJOINT from S2's edits (no merge conflict). The CURRENT _pool_launch_and_verify calls
        pool_chrome_launch UNGUARDED (written for the pre-S1 {0,pool_die} contract) → S2 MUST
        wrap both calls in `if …; then` or a post-S1 return-1 aborts under set -e.
  pattern: 'S1 establishes the return-1 contract S2 consumes; S2 wires the caller to catch it.'
  gotcha: 'S2 depends on S1 for the REAL end-to-end path-(a) recovery (EADDRINUSE → return 1).
        S2''s SELFTESTS mock pool_chrome_launch to return 1 directly, so they pass S1-independently
        (they validate S2''s control flow, not S1''s grep). The task tree sequences S1 before S2.'

- file: lib/pool.sh
  why: THE file being edited. Read lines 1320-1482 (pool_find_free_port + the stale comments at
        ~1328-1331 + ~1377-1379), 1483-1642 (pool_chrome_launch + pool_wait_cdp — NOT edited by
        S2, but understand the contracts), 2098-2310 (_pool_boot_write_chrome_ids +
        _pool_launch_and_verify + pool_boot_lane — the edit sites), 768-922 (pool_lease_update +
        pool_lease_field — used by the re-pick + the pool_boot_lane re-read).
  pattern: 'Existing style — docstring with lettered GOTCHA blocks above each fn; `local x; x="$(…)"`
        two-statement captures; `if ! cmd; then … fi` for rc-1 helpers; `pool_lease_update LANE FIELD
        VALUE` splices VALUE as raw JSON via --argjson (a bare number is valid).'
  gotcha: 'The edit sites are _pool_launch_and_verify (2128-2207), pool_boot_lane step c+d→e
        (~2270-2290), and the two stale comments (~1330 + ~1377-1379). Do NOT touch pool_chrome_launch
        (S1), pool_wait_cdp, pool_find_free_port body, or pool_ensure_connected.'

- file: test/validate.sh
  why: 'The test framework. ADD two selftest_* bodies. _run_selftest_suite (line ~474) auto-discovers
        any selftest_* function via compgen — NO registration. Bodies run in the MAIN shell (single
        setup — AGENTS.md §4: ≤1 process-spawning setup()). CRITICAL: a mock function defined in the
        main shell would SHADOW the lib function for ALL subsequent selftests → the test MUST run
        _pool_launch_and_verify in a `bash -c "…"` SUBSHELL (scoped mocks), mirroring S1''s landed
        selftest_chrome_launch_eaddrinuse (`bash -c "…" _ "$ABPOOL_REPO" || rc=$?`). $ABPOOL_REPO,
        $ABPOOL_TEST_ROOT, assert_eq, _fail, setup (provides POOL_LANES_DIR + a sim owner) are all
        available to selftest bodies. Inter-body backstop `rm -f lanes/*.json` cleans up.'
  pattern: 'selftest_config_bool_truthy (line ~324) + selftest_dispatch_classify_cases (~370) +
        selftest_chrome_launch_eaddrinuse (~392, S1) — plain fn, assert_eq, `|| return 1` fail-fast,
        MAIN shell. The subshell pattern (bash -c "…" _ "$ABPOOL_REPO" || rc=$?) is from S1''s body.'
  gotcha: 'PLACE the two new bodies AFTER selftest_chrome_launch_eaddrinuse (S1) and BEFORE the
        `# --- source-vs-execute gate` / _run_selftest_suite block. The subshell MUST inherit
        AGENT_BROWSER_POOL_STATE (exported by setup) so its pool_config_init resolves the SAME
        POOL_LANES_DIR as the main shell (the subshell''s pool_lease_update writes to the file the
        main shell then reads for the assertion).'

- file: PRD.md
  why: '§1.3 Goal 3 (mutual exclusion — no two agents share a Chrome), §2.4 step 3f (port allocation)
        + 3g (LAUNCH) + 3h (WAIT for CDP), §2.14 ("Chrome slow to boot → retry launch once; then fail,
        drop lane" — S2 extends this to re-pick-then-retry), §2.18 (concurrency: N agents distinct
        lanes, all release cleanly), §2.19 (keep the flock section short — boot after lock release,
        which is WHY port selection is outside the flock and thus racy).'
  pattern: '§2.4 step 3f-3h is the boot sub-flow _pool_launch_and_verify implements. §2.14 is the
        retry-once policy S2 generalizes (re-pick a port, then retry once).'
  gotcha: 'PRD §2.4 does NOT mention EADDRINUSE recovery — the original design assumed the
        anti-collision pre-write (step 3b) was sufficient. Issue 2 corrects this: the pre-write has a
        TOCTOU window, and the launch must be resilient to a lost port race.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S2/research/launch-and-verify-repick.md
  why: 'THIS task''s own research — the host-verified control-flow proof (§6, 4 scenarios), the
        fall-through map (§3), the pool_boot_lane integration fix rationale (§4), the exact stale-comment
        text (§5), the test mock design (§7), the strict-mode traps (§8), the S1/S2/S3 boundary (§9).'
  pattern: '§3 (the designed _pool_launch_and_verify) + §4 (the pool_boot_lane re-read) + §7 (the
        two selftests) are the direct ancestors of the Implementation Tasks.'

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T1S1/PRP.md
  why: 'P1.M1.T1.S1 (Issue 1/5 — boolean normalization) LANDED. Disjoint from S2 (S2 touches no
        config/bool code). (Included for completeness — no direct dependency.)'
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T2S1/PRP.md
  why: 'P1.M1.T2.S1 (Issue 4 — dispatch_classify) LANDED. Disjoint from S2. (No direct dependency.)'

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: 'set -e exemptions — the condition of `if`/`&&`/`||` is exempt from errexit. `if pool_chrome_launch …;
        then … fi` makes a return-1 a clean false-condition (fall-through), NOT an abort. `if ! cmd; then`
        is the idiom for "cmd failed, handle it."'
  critical: 'The CURRENT unguarded `pool_chrome_launch "$port" …` (a bare statement) ABORTS under
        set -e on a post-S1 return-1. Wrapping in `if …; then` is the fix. Never leave an rc-1-capable
        helper as a bare statement under set -e.'
  section: errexit (`-e`).
- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: '"declare and assign separately" — `local x; x="$(cmd)"` so cmd''s exit status is not masked.'
  critical: 'every `local` capture (new_port, reread_port) must be two-statement.'
- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: '${1:-}` (set -u safe for the positional args).'
  section: `${parameter:-word}`.
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh   # ~4431 LOC
│       # EDIT SITES (S2):
│       #   _pool_launch_and_verify  (2128-2207) — guard launches + add re-pick block + docstring
│       #   pool_boot_lane           (2208-2310) — re-read lease port after launch_and_verify rc 0
│       #   stale comments           (~1328-1331 section banner + ~1377-1379 GOTCHA) — fix wording
│       # NOT EDITED by S2 (for reference):
│       #   pool_chrome_launch (1483-1581)        — S1's scope (return-1-on-EADDRINUSE)
│       #   pool_wait_cdp (1582-1642)             — unchanged
│       #   pool_find_free_port (1388-1482)       — unchanged (body); only its docstring comments fixed
│       #   pool_lease_update (768-827)            — used by the re-pick (real, unchanged)
│       #   pool_lease_field (881-922)             — used by pool_boot_lane re-read (real, unchanged)
├── test/
│   └── validate.sh   # ADD two selftest_* bodies (after selftest_chrome_launch_eaddrinuse, before _run_selftest_suite)
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/{key_findings,system_context,external_deps}.md
    ├── P1M1T1S1/PRP.md, P1M1T2S1/PRP.md   # LANDED (disjoint)
    ├── P1M2T1S1/{PRP.md, research/{chrome-eaddrinuse-behavior.md, reference-impl.md}}   # S1 (preceding)
    └── P1M2T1S2/                          # THIS subtask
        ├── PRP.md                          # THIS FILE
        └── research/launch-and-verify-repick.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits IN-PLACE in 2 existing files:
#   lib/pool.sh       — _pool_launch_and_verify (guard+re-pick+docstring), pool_boot_lane (re-read), 2 stale comments
#   test/validate.sh  — ADD 2 selftest_* bodies (~50 lines each, mock-based, subshell-scoped)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the unguarded-call hazard — the core bug S2 fixes): _pool_launch_and_verify currently
# calls `pool_chrome_launch "$port" "$ephemeral_dir" "$lane"` as a BARE statement (lines ~2140, ~2153).
# Pre-S1 that was "safe" (pool_chrome_launch returned 0 or pool_die'd — never a plain rc 1). Post-S1,
# pool_chrome_launch can return 1 (EADDRINUSE) → the bare statement ABORTS _pool_launch_and_verify
# under set -e (lib/pool.sh line 1). S2 MUST wrap BOTH calls in `if pool_chrome_launch …; then … fi`
# (rc 1 = false condition = fall-through to the re-pick; errexit-exempt).

# CRITICAL (the pool_boot_lane stale-port bug — REQUIRED integration fix): pool_boot_lane step e calls
# `pool_daemon_connect "abpool-$lane" "$port"` with the LOCAL $port. After a re-pick, the Chrome is on
# $new_port (lease updated), but $port is still the OLD value → daemon connects to the wrong port →
# rc 1 → lane DROPPED despite a successful re-pick. S2 MUST re-read the port from the lease
# (`pool_lease_field "$lane" port`) after _pool_launch_and_verify returns 0, BEFORE step e. Guarded
# (`|| true` + `[[ =~ && -gt ]] &&`) so a failed re-read keeps the original $port.

# CRITICAL (ONE re-pick, no loop): the re-pick block runs AT MOST ONCE per _pool_launch_and_verify
# call. Do NOT wrap it in a while/for loop. The fall-through structure (nested if → shared re-pick
# block at the end) guarantees this: each trigger point falls through to the re-pick exactly once,
# and the re-pick itself returns (0 or 1) without re-entering the same-port logic.

# CRITICAL (mock leakage in selftests): _run_selftest_suite runs selftest_* bodies in the MAIN shell.
# A mock function (pool_chrome_launch/wait_cdp/find_free_port) defined in the main shell SHADOWS the
# lib function for ALL subsequent selftests → pollution. The test MUST run _pool_launch_and_verify in
# a `bash -c '…'` SUBSHELL that sources lib/pool.sh fresh + defines the mocks there (scoped). Mirror
# S1's selftest_chrome_launch_eaddrinuse (`bash -c '…' _ "$ABPOOL_REPO" || rc=$?`).

# GOTCHA (pool_lease_update splices VALUE as raw JSON): `pool_lease_update "$lane" port "$new_port"`
# where $new_port is a bare number (e.g. 53421) → jq --argjson splices it as a JSON number. Correct.
# (A non-numeric/empty value → jq exit 2 → pool_die. $new_port comes from pool_find_free_port which
# echoes a validated port, so it is always digits.) Trust the lease exists (pool_boot_lane step b
# wrote it) — pool_lease_update pool_die-s on a missing lease, matching the existing step-b pattern.

# GOTCHA (pool_find_free_port excludes lease-claimed ports): the re-pick's pool_find_free_port reads
# the leases (step a) and sees our CURRENT $port claimed (written by pool_boot_lane step b) → it
# returns a DIFFERENT port. This is the anti-collision property the re-pick relies on. Do NOT pass
# the old port to pool_find_free_port (it takes no args; it discovers the exclusion from the lease).

# GOTCHA (pool_wait_cdp kills the pgroup on timeout): after a rc-1 pool_wait_cdp, the Chrome pgroup
# is ALREADY killed. Do NOT add a redundant kill in the re-pick path. The re-pick's launch starts a
# fresh Chrome. (Existing behavior — preserved.)

# GOTCHA (the log-preserve Issue #6 block stays inside attempt 1's then-block): the existing
# `mv chrome-$lane.log → chrome-$lane.attempt1.log` before attempt 2 is PRESERVED unchanged. For
# path (a) (attempt-1 launch rc 1), attempt 1's then-block is SKIPPED, so no .attempt1.log is created
# — the re-pick launch truncates chrome-$lane.log (losing attempt-1's EADDRINUSE stderr), BUT S1's
# _pool_log warning ("port $port may be in use") records the collision. Acceptable; the item does not
# ask for log preservation in the re-pick. Do NOT expand scope by adding it.

# GOTCHA (set -e + command substitution): `new_port="$(pool_find_free_port)"` rc 1 aborts. Use
# `if ! new_port="$(pool_find_free_port)"; then return 1; fi`. Same for the pool_boot_lane re-read:
# `reread_port="$(pool_lease_field "$lane" port 2>/dev/null)" || true`.

# GOTCHA (SC2155): `local new_port` then `new_port="$(…)"` (two-statement). Same for reread_port.

# GOTCHA (scope): S2 is the re-pick + the pool_boot_lane re-read + the stale comment + the selftests.
# Do NOT: touch pool_chrome_launch (S1); touch pool_wait_cdp / pool_find_free_port body; update
# test/concurrency.sh (S3); touch the close-rebind path (P1.M3); loop the re-pick.
```

## Implementation Blueprint

### Data models and structure

No data-model change. The lease JSON's `port` field (PRD §2.8) is the existing top-level
number; S2 merely UPDATES it on a re-pick (via the existing `pool_lease_update`). The only
"structure" is the `_pool_launch_and_verify` return/behavior contract, which expands:

| Trigger | Return | Lease port | New? |
|---|---|---|---|
| Success on the original port (attempt 1 or 2) | 0 | unchanged | (unchanged) |
| Re-pick succeeds (launch rc 1 OR both CDP timeouts → new port → launch+wait rc 0) | 0 | → new_port | **NEW (S2)** |
| `pool_find_free_port` exhausted on re-pick | 1 | unchanged | **NEW (S2)** |
| Re-pick launch rc 1 OR wait rc 1 | 1 | → new_port (updated before the failed retry) | **NEW (S2)** |

`pool_boot_lane` gains: after `_pool_launch_and_verify` rc 0, re-read the lease port (so step e/f
use the real bound port). This is a 4-line addition, confined to the success path.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current state and confirm the edit sites
  - RUN: sed -n '2128,2207p' lib/pool.sh   # (or read lib/pool.sh offset 2128 limit 80)
  - EXPECT: the _pool_launch_and_verify body quoted in §"Current _pool_launch_and_verify" below —
        two UNGUARDED `pool_chrome_launch "$port" …` calls (the bug), the Issue-#6 log-preserve
        block, the `return 1` at the end.
  - RUN: sed -n '2260,2295p' lib/pool.sh   # pool_boot_lane step c+d → e
  - EXPECT: `if ! _pool_launch_and_verify "$port" …; then …; fi` then `# --- e. CONNECT ---` then
        `if ! pool_daemon_connect "abpool-$lane" "$port"; then` — the stale-local-$port site.
  - RUN: sed -n '1326,1332p;1375,1380p' lib/pool.sh   # the two stale comments
  - EXPECT: the "retries on EADDRINUSE" text (quoted verbatim in Task 3).
  - RUN (confirm S1's pool_chrome_launch state — S2 does NOT edit it, but must know the contract):
        sed -n '1528,1545p' lib/pool.sh
  - EXPECT: EITHER the OLD instant-exit block (pool_die, no grep — S1 not yet landed) OR S1's
        new block (grep + return 1 before pool_die). EITHER WAY, S2's edit is the SAME: wrap the
        CALLS in `if …; then`. (S2 is S1-independent at the call site.) If S1 has NOT landed,
        note it: the real end-to-end path-(a) recovery requires S1; the selftests mock it.
  - NOTE: do NOT touch pool_chrome_launch, pool_wait_cdp, pool_find_free_port body, or
        test/concurrency.sh.

Task 1: EDIT lib/pool.sh — rewrite _pool_launch_and_verify (guard launches + add re-pick block)
  - FIND (the EXACT current body, lib/pool.sh:2128-2207 — verify with Task 0):
        _pool_launch_and_verify() {
            local port="${1:-}"
            local ephemeral_dir="${2:-}"
            local lane="${3:-}"

            # Validate args (defensive; the caller already validated, but be safe).
            [[ "$port" =~ ^[0-9]+$ ]] || return 1
            [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || return 1
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1

            # --- Attempt 1 ---
            pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # 0 or fatal pool_die
            _pool_boot_write_chrome_ids "$lane"                    # globals → lease (§2)
            if pool_wait_cdp "$port"; then
                return 0
            fi
            # pool_wait_cdp rc 1 ⇒ Chrome pgroup ALREADY KILLED (research §1.3).

            # --- Attempt 2 (retry once — PRD §2.14) ---
            # PRESERVE attempt 1's diagnostic log (Issue #6): pool_chrome_launch opens
            # $POOL_STATE_DIR/chrome-<lane>.log with `>` (truncate). On retry that would DESTROY
            # the first Chrome's stderr — exactly the output most useful for diagnosing why the
            # first boot failed. Rename attempt-1's log aside first so the second launch's truncate
            # only clears the (now-empty) live log, and the first attempt's output survives for
            # post-mortem. Best-effort (`|| true`): a missing/empty attempt-1 log is not fatal.
            if [[ -f "$POOL_STATE_DIR/chrome-$lane.log" ]]; then
                mv -f -- "$POOL_STATE_DIR/chrome-$lane.log" \
                        "$POOL_STATE_DIR/chrome-$lane.attempt1.log" 2>/dev/null || true
                _pool_log "_pool_launch_and_verify: preserved attempt-1 log: $POOL_STATE_DIR/chrome-$lane.attempt1.log"
            fi
            pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # relaunch (overwrites globals)
            _pool_boot_write_chrome_ids "$lane"                    # 2nd chrome-ids → lease
            if pool_wait_cdp "$port"; then
                return 0
            fi
            # Second timeout ⇒ Chrome already killed. Caller cleans up the lane.
            return 1
        }
  - REPLACE WITH (host-verified control flow — research §3/§6):
        _pool_launch_and_verify() {
            local port="${1:-}"
            local ephemeral_dir="${2:-}"
            local lane="${3:-}"
            local new_port

            # Validate args (defensive; the caller already validated, but be safe).
            [[ "$port" =~ ^[0-9]+$ ]] || return 1
            [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || return 1
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1

            # --- Attempt 1 (same port) ---
            # Guard pool_chrome_launch (Issue 2 / S1): rc 1 = EADDRINUSE detected on instant-exit
            # (retryable) → fall through to the port re-pick below. rc 0 → write chrome-ids + wait
            # for CDP. (A pool_die from pool_chrome_launch — genuine misconfig — still propagates.)
            if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then
                _pool_boot_write_chrome_ids "$lane"                    # globals → lease (§2)
                if pool_wait_cdp "$port"; then
                    return 0
                fi
                # pool_wait_cdp rc 1 ⇒ Chrome pgroup ALREADY KILLED (research §1.3). Retry once on
                # the SAME port (PRD §2.14) before re-picking a different port.
                # PRESERVE attempt 1's diagnostic log (Issue #6): pool_chrome_launch opens
                # $POOL_STATE_DIR/chrome-<lane>.log with `>` (truncate). On retry that would DESTROY
                # the first Chrome's stderr — exactly the output most useful for diagnosing why the
                # first boot failed. Rename attempt-1's log aside first so the second launch's
                # truncate only clears the (now-empty) live log, and the first attempt's output
                # survives for post-mortem. Best-effort (`|| true`): a missing/empty log is not fatal.
                if [[ -f "$POOL_STATE_DIR/chrome-$lane.log" ]]; then
                    mv -f -- "$POOL_STATE_DIR/chrome-$lane.log" \
                            "$POOL_STATE_DIR/chrome-$lane.attempt1.log" 2>/dev/null || true
                    _pool_log "_pool_launch_and_verify: preserved attempt-1 log: $POOL_STATE_DIR/chrome-$lane.attempt1.log"
                fi
                # --- Attempt 2 (same-port retry — PRD §2.14) ---
                if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then
                    _pool_boot_write_chrome_ids "$lane"                # 2nd chrome-ids → lease
                    if pool_wait_cdp "$port"; then
                        return 0
                    fi
                fi
            fi

            # --- Port re-pick (ONE retry with a DIFFERENT port; Issue 2 / S2) ---
            # Reached when (a) pool_chrome_launch returned 1 (EADDRINUSE — S1) on attempt 1 or 2, OR
            # (b) both same-port CDP-timeout attempts failed. pool_find_free_port excludes ports
            # already claimed by leases (incl. our current $port, written by pool_boot_lane step b),
            # so the new port is guaranteed different from the colliding one. ONE re-pick only —
            # do NOT loop. On exhaustion or retry failure, return 1 (caller drops the lane).
            if ! new_port="$(pool_find_free_port)"; then
                _pool_log "_pool_launch_and_verify: no free port to re-pick for lane $lane; giving up"
                return 1
            fi
            # Update the lease so pool_boot_lane's daemon connect (step e) uses the real bound port,
            # and so a concurrent pool_find_free_port sees this port claimed too.
            pool_lease_update "$lane" port "$new_port"
            _pool_log "_pool_launch_and_verify: re-picked port $new_port for lane $lane (was $port)"
            # Retry launch + wait on the new port. pool_chrome_launch rc 1 here = EADDRINUSE again
            # → do NOT loop (one re-pick only) → return 1.
            if ! pool_chrome_launch "$new_port" "$ephemeral_dir" "$lane"; then
                return 1
            fi
            _pool_boot_write_chrome_ids "$lane"
            if pool_wait_cdp "$new_port"; then
                return 0
            fi
            return 1
        }
  - WHY: the unguarded calls abort on S1's return-1; the same-port retry can't escape a collision;
        the re-pick is the recovery. The fall-through structure reaches the re-pick from all three
        trigger points exactly once (host-verified, research §6).
  - PRESERVE: the arg validation; the Issue-#6 log-preserve block (now inside attempt 1's then-block);
        the `_pool_boot_write_chrome_ids` calls; the `pool_wait_cdp` calls; the `return 0`/`return 1`
        semantics. The ONLY structural change is wrapping the launches in `if …; then` + appending
        the re-pick block.
  - GOTCHA: `local new_port` (new) declared at the top with the other locals (two-statement SC2155-safe).
  - GOTCHA: `if ! new_port="$(pool_find_free_port)"; then return 1; fi` — the `if !` makes rc 1 a
        clean branch (NOT a set -e abort). Same for `if ! pool_chrome_launch "$new_port" …; then return 1; fi`.

Task 2: EDIT lib/pool.sh — update the _pool_launch_and_verify DOCSTRING (the comment block above it)
  - FIND (the current docstring, ~lines 2100-2122):
        # _pool_launch_and_verify PORT EPHEMERAL_DIR LANE
        #
        # The launch + CDP-wait + RETRY-ONCE sub-flow. Returns 0 if Chrome's CDP endpoint answers;
        # returns 1 if it times out TWICE (the Chrome pgroup is already killed by pool_wait_cdp on
        # each timeout — research §1.3). PRD §2.14 "Chrome slow to boot → retry launch once; then
        # fail, drop lane". Composed by pool_boot_lane (step c+d) and (by contract) M5.T1.S3
        # ensure_connected for a mid-task-crash relaunch on the same dir+port (profile kept).
        #
        # LOGIC:
        #   1. pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   (sets globals; pool_die on
        #      instant-exit is FATAL — propagates, NOT retried; research §3).
        #   2. _pool_boot_write_chrome_ids "$lane"   (write globals → lease; robustness §2).
        #   3. pool_wait_cdp "$port": rc 0 → return 0.
        #   4. rc 1 (Chrome pgroup already killed) → RETRY: pool_chrome_launch + write_chrome_ids
        #      + pool_wait_cdp. rc 0 → return 0; rc 1 → return 1 (Chrome already killed).
        #
        # GOTCHA — the retry overwrites POOL_CHROME_PID/PGID (and the lease chrome-ids) with the
        #   2nd Chrome's identity, so a subsequent cleanup reads the correct (already-dead) pid.
        # GOTCHA — pool_wait_cdp ALREADY kills the pgroup on timeout; do NOT add a redundant kill.
        # GOTCHA — instant-exit pool_die (pool_chrome_launch) propagates (fatal) — not catchable
        #   without losing the declare -g globals in a subshell (research §3).
        # NON-FATAL on the CDP-timeout path (return 1). No new globals exported.
        # PRECONDITION: pool_config_init + pool_state_init.
  - REPLACE WITH:
        # _pool_launch_and_verify PORT EPHEMERAL_DIR LANE
        #
        # The launch + CDP-wait + RETRY-ONCE sub-flow with PORT RE-PICK (Issue 2 / S2). Returns 0
        # if Chrome's CDP endpoint answers — possibly after re-picking a DIFFERENT port on a launch
        # or CDP failure; returns 1 if all retries (2 same-port + 1 re-picked-port) are exhausted.
        # PRD §2.14 "Chrome slow to boot → retry launch once; then fail, drop lane", generalized by
        # Issue 2 to re-pick a port then retry once. Composed by pool_boot_lane (step c+d); pool_boot_lane
        # re-reads the lease port after a successful call so a re-picked port flows to the daemon connect.
        #
        # LOGIC:
        #   1. Attempt 1 (same port): `if pool_chrome_launch "$port" …; then` — rc 1 (EADDRINUSE,
        #      detected by S1) → fall through to the re-pick (step 5). rc 0 → write_chrome_ids +
        #      pool_wait_cdp "$port": rc 0 → return 0; rc 1 (Chrome pgroup already killed) → attempt 2.
        #   2. Attempt 2 (same-port retry — PRD §2.14): `if pool_chrome_launch "$port" …; then` —
        #      rc 1 → fall through to the re-pick. rc 0 → write_chrome_ids + pool_wait_cdp "$port":
        #      rc 0 → return 0; rc 1 → fall through to the re-pick (both same-port attempts failed).
        #   3. (Re-pick trigger paths: attempt-1 launch rc 1, attempt-2 launch rc 1, OR both CDP
        #      timeouts — all fall through to step 5.)
        #   4. (The Issue-#6 log-preserve: attempt-1's chrome-<lane>.log is renamed to .attempt1.log
        #      before attempt 2's launch truncates it — only when attempt 1 ran.)
        #   5. PORT RE-PICK (ONE retry, no loop — Issue 2 / S2): `if ! new_port="$(pool_find_free_port)"`;
        #      rc 1 (exhausted) → return 1. Else pool_lease_update "$lane" port "$new_port"; then
        #      `if ! pool_chrome_launch "$new_port" …; then return 1; fi`; write_chrome_ids;
        #      pool_wait_cdp "$new_port": rc 0 → return 0; rc 1 → return 1.
        #
        # GOTCHA — pool_chrome_launch rc 1 (EADDRINUSE — S1) is NON-FATAL and triggers the re-pick;
        #   only pool_die (genuine misconfig: broken binary / bad flags / non-EADDRINUSE instant-exit)
        #   propagates as fatal. Both launch calls are guarded with `if …; then` so a return-1 does
        #   NOT abort under set -e (it falls through to the re-pick).
        # GOTCHA — the re-pick updates the LEASE port (pool_lease_update). pool_boot_lane MUST re-read
        #   it (pool_lease_field) after this returns 0, or the daemon connect uses the stale $port.
        # GOTCHA — ONE re-pick only (no loop): the re-pick block is reached at most once per call.
        # GOTCHA — the retry/re-pick overwrites POOL_CHROME_PID/PGID (and the lease chrome-ids) with
        #   the latest Chrome's identity, so a subsequent cleanup reads the correct pid.
        # GOTCHA — pool_wait_cdp ALREADY kills the pgroup on timeout; do NOT add a redundant kill.
        # NON-FATAL on the failure paths (return 1). No new globals exported (new_port is local).
        # PRECONDITION: pool_config_init + pool_state_init + a PROVISIONAL lease for LANE (port>0,
        #   written by pool_boot_lane step b — pool_find_free_port + pool_lease_update rely on it).
  - WHY: the old docstring is now factually wrong (it says "instant-exit pool_die is FATAL — NOT
        retried" and "returns 1 if it times out TWICE" with no re-pick). Keep code+comments in lockstep.

Task 3: EDIT lib/pool.sh — fix the two stale "retries on EADDRINUSE" comments
  - FIND (section banner, ~lines 1330-1331 — verify with Task 0):
        # FINDING 2 — concurrent boots; selection is BEST-EFFORT: the launch in M4.T2.S2 is the
        # authoritative bind and retries on EADDRINUSE).
  - REPLACE WITH:
        # FINDING 2 — concurrent boots; selection is BEST-EFFORT: the launch is the authoritative
        # bind; on a launch/CDP failure, _pool_launch_and_verify re-picks a different port via
        # pool_find_free_port and retries once (Issue 2 / S1+S2)).
  - FIND (GOTCHA, ~lines 1377-1379):
        # GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can both
        #   pick the same port — the launch (M4.T2.S2) is authoritative + retries on EADDRINUSE.
        #   (research §5).
  - REPLACE WITH:
        # GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can both
        #   pick the same port — the launch is authoritative; on a launch/CDP failure,
        #   _pool_launch_and_verify re-picks a different port via pool_find_free_port and retries
        #   once (Issue 2 / S1+S2). (research §5).
  - WHY: the old wording is inaccurate (it implied pool_chrome_launch itself retries; it does NOT —
        _pool_launch_and_verify does the re-pick, and only after S1+S2). After S1+S2 the mitigation
        IS real; the comment now names the actual mechanism precisely (per the item's exact wording).
  - GOTCHA: these are COMMENT-ONLY edits — do NOT touch the pool_find_free_port BODY (step a/b/c logic).

Task 4: EDIT lib/pool.sh — pool_boot_lane re-read the lease port after _pool_launch_and_verify rc 0
  - FIND (the step c+d → e region, ~lines 2270-2285 — verify with Task 0):
        # --- c+d. LAUNCH + WAIT (retry once on CDP timeout) (PRD §2.4 step 3g/3h / §2.14). ---
        #     _pool_launch_and_verify returns 0 (CDP ready) or 1 (timed out twice; Chrome killed).
        #     On failure, clean up + return 1.
        if ! _pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"; then
            _pool_log "pool_boot_lane: CDP not ready after retry for lane $lane port $port; dropping lane"
            _pool_release_lane_internals "$lane"
            return 1
        fi

        # --- e. CONNECT: bind the daemon session to the Chrome (PRD §2.4 step 3i). ---
  - REPLACE WITH (insert the re-read between the fi and the step-e comment):
        # --- c+d. LAUNCH + WAIT (retry once on CDP timeout) (PRD §2.4 step 3g/3h / §2.14). ---
        #     _pool_launch_and_verify returns 0 (CDP ready — possibly after a port re-pick — Issue 2/S2)
        #     or 1 (all retries exhausted; Chrome killed). On failure, clean up + return 1.
        if ! _pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"; then
            _pool_log "pool_boot_lane: CDP not ready after retry for lane $lane port $port; dropping lane"
            _pool_release_lane_internals "$lane"
            return 1
        fi
        # _pool_launch_and_verify may have re-picked a different port on a launch/CDP failure (Issue 2 / S2)
        # and updated the lease; re-read the authoritative port so the daemon connect (step e) + the
        # provisioned log (step f) use the REAL bound port, not the stale local $port. Guarded: a
        # failed re-read (truly exceptional — corrupt lease mid-boot) keeps the original $port.
        local reread_port
        reread_port="$(pool_lease_field "$lane" port 2>/dev/null)" || true
        if [[ "$reread_port" =~ ^[0-9]+$ && "$reread_port" -gt 0 ]]; then
            port="$reread_port"
        fi

        # --- e. CONNECT: bind the daemon session to the Chrome (PRD §2.4 step 3i). ---
  - WHY: without this, a successful re-pick is silently discarded (pool_daemon_connect uses the stale
        $port → connection refused → lane dropped). The lease is the authoritative port source after
        a re-pick (the item's OUTPUT contract).
  - PRESERVE: the failure path (the `if ! _pool_launch_and_verify …; then … return 1; fi`), step e
        onward, and the rest of pool_boot_lane. The ONLY addition is the 6-line re-read block.
  - GOTCHA: `local reread_port` mid-function is valid bash (function-scoped); two-statement
        (`local reread_port; reread_port="$(…)"`) is SC2155-safe. The `|| true` neutralizes a rc-1
        pool_lease_field (missing/corrupt lease → exceptional); the `[[ =~ && -gt ]] && port=` is
        inside `if` (errexit-exempt) and only overwrites $port with a VALID port.

Task 5: ADD test/validate.sh — two selftest bodies (path-a + path-b)
  - ADD two functions: `selftest_launch_and_verify_repick_on_launch_fail` (path a) and
        `selftest_launch_and_verify_repick_on_cdp_timeout` (path b). _run_selftest_suite (line ~474)
        auto-discovers them — NO registration.
  - PLACE: AFTER `selftest_chrome_launch_eaddrinuse` (S1, ends ~line 470) and BEFORE the
        `# --- source-vs-execute gate` comment / `_run_selftest_suite` definition.
  - FOLLOW pattern: selftest_chrome_launch_eaddrinuse (S1) — `bash -c '…' _ "$ABPOOL_REPO" || rc=$?`
        subshell (scoped mocks, no leakage). The body (main shell) writes a provisional lease
        (real pool_lease_write), runs the subshell, then asserts rc + lease port (real pool_lease_field).
  - REFERENCE IMPLEMENTATION (path a — host-verified mock approach, research §6/§7):
      ----------------------------------------------------------------
      # --- _pool_launch_and_verify port re-pick on launch failure (P1.M2.T1.S2 / Issue 2, path a) ---
      # Mock-based test: pool_chrome_launch returns 1 (EADDRINUSE — S1) on the original port and
      # 0 on the re-picked port; pool_wait_cdp returns 0 on the new port. Verifies _pool_launch_and_verify
      # catches the rc-1, re-picks a different port via pool_find_free_port, updates the lease, retries,
      # and returns 0 with the lease holding the NEW port. No real Chrome (AGENTS.md §1).
      # Runs in a bash -c SUBSHELL so the mock functions (which shadow the lib fns) are scoped — they
      # do NOT leak into the main shell and pollute the other selftests (single-setup runner, AGENTS.md §4).
      selftest_launch_and_verify_repick_on_launch_fail() {
          local dir lane orig new rc lease_port
          dir="$ABPOOL_TEST_ROOT/ephemeral-rp1"; mkdir -p -- "$dir"
          lane=7; orig=53420; new=53421
          # Provisional lease for lane 7 with port=orig (simulates pool_boot_lane step b).
          pool_lease_write "$lane" "$dir" "$orig" "abpool-$lane" \
              12345 "pi" 99999 "$ABPOOL_TEST_ROOT" 0 0 false
          # Run _pool_launch_and_verify in a subshell with mocked launch/wait/find_free_port.
          rc=0
          timeout 15 bash -c '
              set -euo pipefail
              repo="$1"; orig="$2"; new="$3"; dir="$4"; lane="$5"
              source "$repo/lib/pool.sh"
              pool_config_init
              # --- mocks (port-conditional; scoped to this subshell) ---
              pool_chrome_launch() {
                  if [[ "$1" == "$orig" ]]; then return 1; fi   # EADDRINUSE on the original port
                  POOL_CHROME_PID=99999; declare -g POOL_CHROME_PID
                  POOL_CHROME_PGID=99999; declare -g POOL_CHROME_PGID
                  return 0
              }
              pool_wait_cdp() { [[ "$1" != "$orig" ]]; }        # orig times out; new is ready
              pool_find_free_port() { printf "%s\n" "$new"; }   # the re-pick port
              _pool_launch_and_verify "$orig" "$dir" "$lane"
          ' _ "$ABPOOL_REPO" "$orig" "$new" "$dir" "$lane" || rc=$?
          assert_eq "0" "$rc" "path-a: _pool_launch_and_verify returns 0 after launch-fail re-pick" || return 1
          lease_port="$(pool_lease_field "$lane" port)"
          assert_eq "$new" "$lease_port" "path-a: lease port updated to the re-picked port" || return 1
      }

      # --- _pool_launch_and_verify port re-pick on CDP timeout (P1.M2.T1.S2 / Issue 2, path b) ---
      # Mock-based test: pool_chrome_launch succeeds (rc 0) on BOTH attempts for the original port,
      # but pool_wait_cdp times out (rc 1) on both; on the re-picked port, both succeed. Verifies the
      # "both same-port CDP-timeout attempts failed" trigger path reaches the re-pick. No real Chrome.
      selftest_launch_and_verify_repick_on_cdp_timeout() {
          local dir lane orig new rc lease_port
          dir="$ABPOOL_TEST_ROOT/ephemeral-rp2"; mkdir -p -- "$dir"
          lane=8; orig=53430; new=53431
          pool_lease_write "$lane" "$dir" "$orig" "abpool-$lane" \
              12345 "pi" 99999 "$ABPOOL_TEST_ROOT" 0 0 false
          rc=0
          timeout 15 bash -c '
              set -euo pipefail
              repo="$1"; orig="$2"; new="$3"; dir="$4"; lane="$5"
              source "$repo/lib/pool.sh"
              pool_config_init
              # --- mocks ---
              pool_chrome_launch() {   # always succeeds (sets globals)
                  POOL_CHROME_PID=88888; declare -g POOL_CHROME_PID
                  POOL_CHROME_PGID=88888; declare -g POOL_CHROME_PGID
                  return 0
              }
              pool_wait_cdp() { [[ "$1" != "$orig" ]]; }        # orig times out (both attempts); new ready
              pool_find_free_port() { printf "%s\n" "$new"; }
              _pool_launch_and_verify "$orig" "$dir" "$lane"
          ' _ "$ABPOOL_REPO" "$orig" "$new" "$dir" "$lane" || rc=$?
          assert_eq "0" "$rc" "path-b: _pool_launch_and_verify returns 0 after CDP-timeout re-pick" || return 1
          lease_port="$(pool_lease_field "$lane" port)"
          assert_eq "$new" "$lease_port" "path-b: lease port updated to the re-picked port" || return 1
      }
      ----------------------------------------------------------------
  - WHY a subshell: the single-setup _run_selftest_suite runs bodies in the MAIN shell; a mock fn
        defined there would shadow the lib fn for ALL subsequent selftests. The subshell scopes the
        mocks. (Mirrors S1's selftest_chrome_launch_eaddrinuse.)
  - WHY mock pool_find_free_port (not just launch/wait_cdp): determinism — no ss/curl host-port
        dependency. The item lists launch+wait_cdp as the Chrome-interacting mocks; pool_find_free_port
        is mocked for determinism (its exclusion property is tested elsewhere). $new is a fixed port.
  - WHY the mock pool_chrome_launch sets POOL_CHROME_PID/PGID via declare -g: the real
        _pool_boot_write_chrome_ids reads ${POOL_CHROME_PID:-0}/${POOL_CHROME_PGID:-0} and writes them
        to the lease via pool_lease_update. Without the globals, the lease would get chrome_pid=0
        (cosmetic for this test, but faithful to keep).
  - GOTCHA: the subshell inherits AGENT_BROWSER_POOL_STATE (exported by setup) → its pool_config_init
        resolves the SAME POOL_LANES_DIR as the main shell → the subshell's pool_lease_update writes to
        the file the main shell's pool_lease_field then reads. Verify: the lane is written by the main
        shell's pool_lease_write (using setup's POOL_LANES_DIR); the subshell reads/updates the same file.
  - GOTCHA: $dir must be ABSOLUTE (ABPOOL_TEST_ROOT is from mktemp → absolute) — _pool_launch_and_verify
        validates `[[ "$ephemeral_dir" == /* ]]`.
  - GOTCHA: the inter-body backstop `rm -f lanes/*.json` (in _run_selftest_suite) cleans up the leases
        these bodies write — no pollution.

Task 6: VERIFY — run the full gauntlet BEFORE claiming done
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -S warning lib/pool.sh
      bash -n test/validate.sh
      shellcheck -S warning test/validate.sh
      bash test/validate.sh                 # must exit 0, incl. the two new selftests
  - RUN (the S2 control flow in isolation — mock-based, mirrors the selftests but standalone):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/state/lanes" "$tmp/active/7"
        timeout 15 bash -c '
            set -euo pipefail
            source "'"$PWD"'/lib/pool.sh"
            export AGENT_BROWSER_POOL_STATE="'"$tmp"'/state"
            pool_config_init; pool_state_init
            pool_lease_write 7 "'"$tmp"'/active/7" 53420 abpool-7 12345 pi 99999 "'"$tmp"'" 0 0 false
            pool_chrome_launch() { if [[ "$1" == 53420 ]]; then return 1; fi; POOL_CHROME_PID=99999; declare -g POOL_CHROME_PID; POOL_CHROME_PGID=99999; declare -g POOL_CHROME_PGID; return 0; }
            pool_wait_cdp() { [[ "$1" != 53420 ]]; }
            pool_find_free_port() { printf "53421\n"; }
            _pool_launch_and_verify 53420 "'"$tmp"'/active/7" 7
            echo "rc=$?  lease_port=$(pool_lease_field 7 port)"
        '
        # EXPECT: rc=0  lease_port=53421
  - RUN (scope check — S2 touched ONLY _pool_launch_and_verify, pool_boot_lane, the 2 stale comments,
        and the docstring; pool_chrome_launch + test/concurrency.sh UNCHANGED):
        git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'pool_chrome_launch\(\)|grep -qiE|cannot start http server' \
          && echo "FAIL: out-of-scope edit to pool_chrome_launch (S1's scope)" || echo "scope OK (pool_chrome_launch untouched by S2)"
        git diff --name-only | grep -q '^test/concurrency.sh$' \
          && echo "FAIL: concurrency.sh touched (S3's scope)" || echo "scope OK (concurrency.sh untouched)"
        # EXPECT: scope OK (both). The ONLY lib/pool.sh diff lines are: the _pool_launch_and_verify
        #       rewrite, its docstring, the pool_boot_lane re-read block, and the 2 stale-comment fixes.
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the fall-through control flow (host-verified, research §6) -----------------
# The re-pick is reached from 3 trigger points via nested `if pool_chrome_launch; then … fi`:
# a return-1 makes the `if` condition FALSE → the `then` block is skipped → execution falls
# through to the shared re-pick block at the end. Each trigger reaches it exactly once; the
# re-pick returns (0 or 1) without re-entering the same-port logic → ONE re-pick, no loop.

#   if pool_chrome_launch "$port" …; then        # attempt 1 (rc 1 → fall through)
#       _pool_boot_write_chrome_ids "$lane"
#       if pool_wait_cdp "$port"; then return 0; fi
#       <Issue-#6 log-preserve>
#       if pool_chrome_launch "$port" …; then    # attempt 2 (rc 1 → fall through)
#           _pool_boot_write_chrome_ids "$lane"
#           if pool_wait_cdp "$port"; then return 0; fi
#       fi
#   fi
#   # RE-PICK (reached from: att1 launch rc1, att2 launch rc1, or both CDP timeouts):
#   if ! new_port="$(pool_find_free_port)"; then return 1; fi
#   pool_lease_update "$lane" port "$new_port"
#   if ! pool_chrome_launch "$new_port" …; then return 1; fi
#   _pool_boot_write_chrome_ids "$lane"
#   if pool_wait_cdp "$new_port"; then return 0; fi
#   return 1

# --- Pattern: the pool_boot_lane re-read (REQUIRED integration fix) --------------------
#   if ! _pool_launch_and_verify "$port" …; then <cleanup>; return 1; fi
#   local reread_port
#   reread_port="$(pool_lease_field "$lane" port 2>/dev/null)" || true
#   if [[ "$reread_port" =~ ^[0-9]+$ && "$reread_port" -gt 0 ]]; then port="$reread_port"; fi
#   # --- e. CONNECT ---  if ! pool_daemon_connect "abpool-$lane" "$port"; then …

# --- Critical micro-rules ---------------------------------------------------------------
#  * Both pool_chrome_launch calls wrapped in `if …; then` (rc 1 = false condition = fall-through;
#    errexit-exempt). NEVER a bare `pool_chrome_launch …` under set -e (post-S1 it can return 1).
#  * `if ! new_port="$(pool_find_free_port)"` and `if ! pool_chrome_launch "$new_port" …` — the
#    `if !` makes rc 1 a clean branch (NOT a set -e abort).
#  * `local new_port` / `local reread_port` two-statement (SC2155).
#  * pool_lease_update "$lane" port "$new_port" — $new_port is a bare number → valid JSON via --argjson.
#  * pool_wait_cdp kills the pgroup on timeout — no redundant kill in the re-pick.
#  * ONE re-pick, no loop (the fall-through structure guarantees it).
#  * The subshell-scoped mocks in the selftests do NOT leak (bash -c sources lib/pool.sh fresh).
```

### Integration Points

```yaml
PRIOR (S1) — consumed, NOT modified by S2:
  - pool_chrome_launch (S1's scope): S2 ASSUMES its post-S1 contract (rc 0 / rc 1-EADDRINUSE /
        pool_die). S2 wraps the CALLS; it does NOT edit pool_chrome_launch. If S1 has not landed,
        only the path-(b) re-pick (CDP timeout) is functional end-to-end; path-(a) requires S1.
        S2's selftests mock pool_chrome_launch to return 1 directly → they pass S1-independently.
  - pool_wait_cdp (unchanged): rc 0 (CDP ready) / rc 1 (timeout, pgroup already killed).
  - pool_find_free_port (unchanged body): echoes the lowest free port excluding lease-claimed ports
        (incl. our current $port). rc 1 on exhaustion.
  - pool_lease_update / pool_lease_field (unchanged): used by the re-pick (update) + pool_boot_lane
        (re-read). VALUE spliced as raw JSON.

S2 EDITS:
  - _pool_launch_and_verify: guard + re-pick + docstring.
  - pool_boot_lane: 6-line re-read block after _pool_launch_and_verify rc 0.
  - 2 stale comments (pool_find_free_port section banner + GOTCHA): wording fix (comment-only).

LATER — provided:
  - P1.M2.T1.S3 (concurrency test): will exercise collision recovery end-to-end through
        pool_boot_lane (now correct because S2 re-reads the port). S2's pool_boot_lane fix is a
        PREREQUISITE for S3's test to pass (otherwise the daemon connect uses the stale port).
  - P1.M3 (close-rebind): disjoint (close path / connected flag). No interaction with S2.

CONFIG / DATABASE / ROUTES: none. No new env vars, no new globals (new_port/reread_port are local),
no dir I/O beyond the existing lease update. The only on-disk effect is the lease `port` field
being updated on a re-pick (the item's OUTPUT contract).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck -S warning lib/pool.sh  # MUST report zero issues (whole file). NOTE: project gate is -S warning.
bash -n test/validate.sh
shellcheck -S warning test/validate.sh
# Expected: zero output from all four.
```

### Level 2: Unit Tests (Component Validation — the two new selftests)

```bash
# Run the full selftest suite (single-setup). The two new bodies are auto-discovered.
bash test/validate.sh
# Expected: exits 0; the summary includes the two new selftests as PASS (alongside the existing
#           selftest_* blocks incl. S1's selftest_chrome_launch_eaddrinuse).

# Isolated run of just the two new bodies (if you want to see them in isolation — optional):
bash -c '
  source lib/pool.sh  # not needed; validate.sh sources it. This is illustrative.
'
# Pragmatic: the suite is the gate. If a selftest fails, _run_selftest_suite prints FAIL + the name.
```

### Level 3: Integration Testing (the control flow, mock-based, standalone)

```bash
# 3a. Path (a): launch rc 1 on orig (EADDRINUSE) → re-pick → success. Assert rc 0 + lease port.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/lanes" "$tmp/active/7"
timeout 15 bash -c '
    set -euo pipefail
    source "'"$PWD"'/lib/pool.sh"
    export AGENT_BROWSER_POOL_STATE="'"$tmp"'/state"
    pool_config_init; pool_state_init
    pool_lease_write 7 "'"$tmp"'/active/7" 53420 abpool-7 12345 pi 99999 "'"$tmp"'" 0 0 false
    pool_chrome_launch() { if [[ "$1" == 53420 ]]; then return 1; fi; POOL_CHROME_PID=99999; declare -g POOL_CHROME_PID; POOL_CHROME_PGID=99999; declare -g POOL_CHROME_PGID; return 0; }
    pool_wait_cdp() { [[ "$1" != 53420 ]]; }
    pool_find_free_port() { printf "53421\n"; }
    _pool_launch_and_verify 53420 "'"$tmp"'/active/7" 7
    echo "rc=$?  lease_port=$(pool_lease_field 7 port)"
'
# Expected: rc=0  lease_port=53421

# 3b. Path (b): launch rc 0, wait_cdp rc 1 twice → re-pick → success. Assert rc 0 + lease port.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/lanes" "$tmp/active/8"
timeout 15 bash -c '
    set -euo pipefail
    source "'"$PWD"'/lib/pool.sh"
    export AGENT_BROWSER_POOL_STATE="'"$tmp"'/state"
    pool_config_init; pool_state_init
    pool_lease_write 8 "'"$tmp"'/active/8" 53430 abpool-8 12345 pi 99999 "'"$tmp"'" 0 0 false
    pool_chrome_launch() { POOL_CHROME_PID=88888; declare -g POOL_CHROME_PID; POOL_CHROME_PGID=88888; declare -g POOL_CHROME_PGID; return 0; }
    pool_wait_cdp() { [[ "$1" != 53430 ]]; }
    pool_find_free_port() { printf "53431\n"; }
    _pool_launch_and_verify 53430 "'"$tmp"'/active/8" 8
    echo "rc=$?  lease_port=$(pool_lease_field 8 port)"
'
# Expected: rc=0  lease_port=53431

# 3c. Negative: pool_find_free_port exhausted → rc 1.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/lanes" "$tmp/active/7"
timeout 15 bash -c '
    set -euo pipefail
    source "'"$PWD"'/lib/pool.sh"
    export AGENT_BROWSER_POOL_STATE="'"$tmp"'/state"
    pool_config_init; pool_state_init
    pool_lease_write 7 "'"$tmp"'/active/7" 53420 abpool-7 12345 pi 99999 "'"$tmp"'" 0 0 false
    pool_chrome_launch() { return 1; }
    pool_wait_cdp() { return 1; }
    pool_find_free_port() { return 1; }
    _pool_launch_and_verify 53420 "'"$tmp"'/active/7" 7
    echo "rc=$? (expect 1)"
' ; echo "outer-exit=$?"
# Expected: rc=1 (expect 1) + outer-exit=0 (the function returned 1, caught by the || in the harness)

# 3d. Negative: re-pick launch also fails → rc 1 (lease updated before the failed retry).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/lanes" "$tmp/active/8"
timeout 15 bash -c '
    set -euo pipefail
    source "'"$PWD"'/lib/pool.sh"
    export AGENT_BROWSER_POOL_STATE="'"$tmp"'/state"
    pool_config_init; pool_state_init
    pool_lease_write 8 "'"$tmp"'/active/8" 53430 abpool-8 12345 pi 99999 "'"$tmp"'" 0 0 false
    pool_chrome_launch() { return 1; }
    pool_wait_cdp() { return 1; }
    pool_find_free_port() { printf "53431\n"; }
    _pool_launch_and_verify 53430 "'"$tmp"'/active/8" 8
    echo "rc=$? (expect 1)  lease_port=$(pool_lease_field 8 port) (expect 53431)"
' ; echo "outer-exit=$?"
# Expected: rc=1 (expect 1)  lease_port=53431 (expect 53431) + outer-exit=0
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the unguarded-call hazard is GONE: both pool_chrome_launch calls in _pool_launch_and_verify
#     are now inside `if …; then` (a return-1 no longer aborts under set -e).
grep -n 'pool_chrome_launch ' lib/pool.sh | grep -E '_pool_launch_and_verify|^\s*pool_chrome_launch' >/dev/null
# Better: confirm the function body has NO bare `pool_chrome_launch "$` statement (all are `if pool_chrome_launch`).
sed -n '/^_pool_launch_and_verify()/,/^}/p' lib/pool.sh | grep -nE '^\s*pool_chrome_launch ' \
  && echo "FAIL: a bare (unguarded) pool_chrome_launch statement remains" \
  || echo "OK: all pool_chrome_launch calls are guarded (inside if)"
# Expected: OK: all pool_chrome_launch calls are guarded (inside if)

# 4b. Confirm the re-pick block exists and is singular (ONE pool_find_free_port call in the fn).
count=$(sed -n '/^_pool_launch_and_verify()/,/^}/p' lib/pool.sh | grep -c 'pool_find_free_port')
echo "pool_find_free_port calls in _pool_launch_and_verify: $count (expect 1)"
# Expected: 1 (the re-pick; no loop)

# 4c. Confirm pool_boot_lane re-reads the port (the integration fix landed).
sed -n '/^pool_boot_lane()/,/^}/p' lib/pool.sh | grep -q 'pool_lease_field "$lane" port' \
  && echo "OK: pool_boot_lane re-reads the lease port" || echo "FAIL: re-read missing"
# Expected: OK: pool_boot_lane re-reads the lease port

# 4d. Confirm the stale comments are fixed (no "retries on EADDRINUSE" remains in pool_find_free_port's area).
sed -n '1320,1485p' lib/pool.sh | grep -q 'retries on EADDRINUSE' \
  && echo "FAIL: stale 'retries on EADDRINUSE' comment still present" \
  || echo "OK: stale comment fixed"
sed -n '1320,1485p' lib/pool.sh | grep -q '_pool_launch_and_verify re-picks a different port' \
  && echo "OK: comment now names the re-pick mechanism" || echo "FAIL: new wording missing"
# Expected: OK: stale comment fixed + OK: comment now names the re-pick mechanism

# 4e. Scope check (S2 did not touch pool_chrome_launch or test/concurrency.sh).
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'pool_chrome_launch\(\)|grep -qiE|cannot start http server' \
  && echo "FAIL: out-of-scope edit to pool_chrome_launch (S1)" || echo "scope OK: pool_chrome_launch untouched"
git diff --name-only | grep -q '^test/concurrency.sh$' \
  && echo "FAIL: concurrency.sh touched (S3)" || echo "scope OK: concurrency.sh untouched"
# Expected: scope OK (both)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck -S warning lib/pool.sh` passes (zero warnings) — whole file.
- [ ] `bash -n test/validate.sh` passes; `shellcheck -S warning test/validate.sh` passes.
- [ ] `bash test/validate.sh` exits 0 (the two new selftests PASS alongside the existing blocks).
- [ ] Level 3 snippets 3a–3d pass (path-a, path-b, exhaustion→1, re-pick-fail→1).
- [ ] Level 4 snippets 4a–4e confirm the structural guarantees (guarded calls, ONE re-pick, re-read,
      stale-comment fixed, scope clean).

### Feature Validation

- [ ] `_pool_launch_and_verify` wraps BOTH `pool_chrome_launch` calls in `if …; then` (4a).
- [ ] `_pool_launch_and_verify` adds the re-pick block: `pool_find_free_port` (guarded) →
      `pool_lease_update "$lane" port "$new_port"` → `pool_chrome_launch "$new_port"` (guarded) →
      `_pool_boot_write_chrome_ids` → `pool_wait_cdp "$new_port"`; return 0 on success, 1 on failure.
- [ ] Exactly ONE `pool_find_free_port` call in `_pool_launch_and_verify` (4b — no loop).
- [ ] `pool_boot_lane` re-reads the lease port after `_pool_launch_and_verify` rc 0 (4c).
- [ ] The two stale comments no longer say "retries on EADDRINUSE"; they name the re-pick (4d).
- [ ] `_pool_launch_and_verify` docstring documents the re-pick (trigger paths, ONE-re-pick, lease update, S1 contract).
- [ ] `pool_chrome_launch` (S1) UNCHANGED by S2; `test/concurrency.sh` (S3) UNCHANGED (4e).

### Code Quality Validation

- [ ] Only `lib/pool.sh` + `test/validate.sh` modified.
- [ ] The `_pool_launch_and_verify` change preserves: arg validation, the Issue-#6 log-preserve block,
      `_pool_boot_write_chrome_ids` calls, `pool_wait_cdp` calls, the `return 0`/`return 1` semantics.
- [ ] The `pool_boot_lane` change is confined to the success path (6-line re-read block); the failure
      path + step e onward are structurally preserved.
- [ ] Every `local` capture is two-statement (SC2155): `local new_port` / `local reread_port`.
- [ ] Every rc-1-capable helper is guarded (`if …; then` / `if ! …; then` / `|| true`) — no bare
      `pool_chrome_launch` / `pool_find_free_port` / `pool_lease_field` statements under set -e.
- [ ] The stale-comment edits are COMMENT-ONLY (the `pool_find_free_port` body is untouched).
- [ ] The selftests run `_pool_launch_and_verify` in a `bash -c` subshell (scoped mocks — no leakage).
- [ ] No source/PRD/tasks.json/prd_snapshot.md/.gitignore files modified.

### Documentation & Deployment

- [ ] `_pool_launch_and_verify` docstring updated (Task 2).
- [ ] The two stale comments fixed (Task 3).
- [ ] The `pool_boot_lane` re-read block has a comment explaining WHY (the re-pick updates the lease;
      the caller must re-read or the daemon connects to the stale port).
- [ ] No new env vars / globals / files.

---

## Anti-Patterns to Avoid

- ❌ Don't leave `pool_chrome_launch` as a BARE statement under set -e — post-S1 it can return 1
  (EADDRINUSE) and ABORT `_pool_launch_and_verify`. Wrap in `if …; then` (rc 1 = fall-through to the
  re-pick). This is the core fix.
- ❌ Don't LOOP the re-pick — "Limit to ONE port re-pick." The fall-through structure reaches the
  re-pick exactly once; do NOT wrap it in `while`/`for`.
- ❌ Don't forget the `pool_boot_lane` re-read — without it, a successful re-pick is silently
  discarded (daemon connect uses the stale `$port` → lane dropped). The lease-port update is only
  meaningful if the caller reads it. This is REQUIRED, not optional.
- ❌ Don't define mock functions in the validate.sh MAIN shell — `_run_selftest_suite` runs bodies
  in the main shell (single setup); a mock would SHADOW the lib fn for all subsequent selftests.
  Run `_pool_launch_and_verify` in a `bash -c` subshell (scoped mocks), mirroring S1's selftest.
- ❌ Don't touch `pool_chrome_launch` (S1's scope), `pool_wait_cdp`, `pool_find_free_port` body, or
  `test/concurrency.sh` (S3's scope). S2's edits are `_pool_launch_and_verify`, `pool_boot_lane`'s
  re-read, the 2 stale comments, and the 2 selftests — nothing else.
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155). For `new_port` and
  `reread_port`.
- ❌ Don't leave `new_port="$(pool_find_free_port)"` unguarded — rc 1 (exhaustion) aborts under set -e.
  Use `if ! new_port="$(pool_find_free_port)"; then return 1; fi`.
- ❌ Don't add a redundant `kill` after `pool_wait_cdp` rc 1 — `pool_wait_cdp` ALREADY kills the pgroup
  on timeout (existing behavior; preserved).
- ❌ Don't pass the old port to `pool_find_free_port` (it takes no args; it discovers the exclusion
  from the lease). Don't "help" it by excluding the port manually.
- ❌ Don't expand scope by adding log-preservation to the re-pick — the item specifies the re-pick
  steps (find_free_port → update lease → launch → write_ids → wait_cdp) with NO log preservation.
  The Issue-#6 log-preserve block stays where it is (inside attempt 1's then-block).
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any file other than
  `lib/pool.sh` + `test/validate.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The control flow was **host-verified this session** (research §6): a mock-based scratch test of the
  exact designed `_pool_launch_and_verify` passed all four scenarios (path-a re-pick → rc 0 + lease
  updated; path-b re-pick → rc 0 + lease updated; exhaustion → rc 1; re-pick-fail → rc 1 + lease
  updated). The fall-through structure (nested `if pool_chrome_launch; then … fi` → shared re-pick
  block) is proven to reach the re-pick from all three trigger points exactly once.
- The `pool_boot_lane` integration fix is a **necessary, minimal** consequence (the re-pick updates
  the lease port; the caller must re-read it or the daemon connects to the stale port). It is 6 lines,
  confined to the success path, guarded for set -e. S1 does NOT touch pool_boot_lane → no conflict.
- The two selftests are **mock-based and S1-independent** (the mock returns 1 directly; they validate
  S2's control flow, not S1's grep). They mirror S1's landed `selftest_chrome_launch_eaddrinuse`
  subshell pattern (scoped mocks, no leakage, no real Chrome — AGENTS.md §1).
- The stale-comment fix is comment-only (verbatim oldText/newText quoted in Task 3).
- The `set -euo pipefail` traps (unguarded rc-1 helper aborts; SC2155; `if !`/`|| true` guards) are
  each called out with the exact idiom and a dedicated Level-4 check (4a).
- The -1 reflects that the **real end-to-end path-(a) recovery additionally requires S1's
  `pool_chrome_launch` edit to have landed** (S1 is the immediately-preceding subtask, "Implementing").
  S2's selftests mock the return-1, so they pass regardless; but the live EADDRINUSE→re-pick path
  needs S1's grep. The task tree sequences S1 before S2, so by implementation time S1 should be landed.
  The PRP explicitly notes this dependency so the implementer verifies S1's state (Task 0).
