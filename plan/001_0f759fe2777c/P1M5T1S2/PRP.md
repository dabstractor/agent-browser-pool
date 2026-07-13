# PRP — P1.M5.T1.S2: Post-lock boot — copy + port + launch + connect + update lease

---

## Goal

**Feature Goal**: Implement **`pool_boot_lane(lane)`** — the **post-lock Chrome provisioning**
for a freshly-acquired lane in the agent-browser-pool: the single function that takes a
**provisionally-claimed** lane (port=0, from `pool_acquire_locked` / P1.M5.T1.S1) and turns it
into a **fully-provisioned** lane — Chrome running, daemon connected, lease complete. This is
the literal realization of **PRD §2.4 step 3e–3j** (the part that runs **OUTSIDE** the flock,
so concurrent acquires boot their Chromes in parallel — `key_findings` FINDING 2) + **§2.6**
(Chrome launch) + **§2.7** (copy / master hygiene) + **§2.14** (failure modes: CDP-timeout →
retry once → fail, drop lane).

The function implements the item CONTRACT steps a–g verbatim:
**a. COPY** (`pool_copy_master`) → **b. PORT** (`pool_find_free_port` + early lease port write
for anti-collision) → **c. LAUNCH** (`pool_chrome_launch`, sets `POOL_CHROME_PID`/`PGID`
globals) → **d. WAIT** (`pool_wait_cdp`, **retry launch once on timeout**, drop lane on second
failure) → **e. CONNECT** (`pool_daemon_connect`) → **f. UPDATE LEASE** (`connected:true` +
`last_seen_at`) → **g. return 0**. Every failure path cleans up the lane (kill Chrome +
rm dir + delete lease) and returns 1.

**Deliverable**: One PUBLIC function `pool_boot_lane(LANE)` plus up to two PRIVATE `_pool_*`
helpers, appended to `lib/pool.sh` under a new banner **after `pool_acquire_locked`** (the
P1.M5.T1.S1 deliverable, current EOF @2055). **Pure addition: no edits to any existing
function, no new env-vars, no new files.** Reads `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`,
`POOL_REAL_BIN`, and the `POOL_CHROME_PID`/`POOL_CHROME_PGID` globals set by
`pool_chrome_launch`.

1. **`pool_boot_lane(LANE)`** — the public entry point (the CONTRACT name). Performs steps
   a→b→c+d→e→f. On success: lane fully provisioned, return **0**. On ANY recoverable failure
   (port exhaustion / CDP double-timeout / daemon connect fail): clean up the lane via
   `_pool_release_lane_internals "$LANE"` and return **1**. (Fatal `pool_die`s from
   `pool_copy_master` / `pool_chrome_launch` propagate — those are genuine misconfigurations,
   not recoverable boot failures; the provisional lease they leave behind self-heals via the
   next acquire's REAP-STALE.)
2. **`_pool_launch_and_verify(PORT, EPHEMERAL_DIR, LANE)`** — *(private helper)* the
   launch + write-chrome-ids + CDP-wait + **retry-once** sub-flow. Calls `pool_chrome_launch`
   (0 or fatal pool_die on instant-exit), writes `chrome_pid`/`chrome_pgid` to the lease
   (robustness — see §"Known Gotchas"), calls `pool_wait_cdp`; on timeout (rc 1, Chrome pgroup
   already killed by `pool_wait_cdp`) retries the whole launch+write+wait **once**; returns
   **0** (CDP ready) or **1** (second timeout, Chrome already killed).
3. **`_pool_boot_write_chrome_ids(LANE)`** — *(optional tiny private helper)* writes the
   `POOL_CHROME_PID`/`POOL_CHROME_PGID` globals into the lease via two `pool_lease_update`
   calls. Exists only to DRY the write across the two launch attempts; may be inlined.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, given a
  **provisional** lease for lane 1 (written by `pool_acquire_locked`: `port:0, chrome_pid:0,
  connected:false`), calling `pool_boot_lane 1` returns **0** and the lease ends with
  `port` ∈ [53420, 54420), `chrome_pid` > 0, `chrome_pgid` > 0, `connected` == **true**,
  `last_seen_at` == now; a Chrome process group is alive on that port; `curl -sf
  http://127.0.0.1:<port>/json/version` answers; and `agent-browser --session abpool-1
  --json session list` includes `abpool-1`.
- **Failure → cleanup → return 1** is exercised for all three recoverable paths:
  - **port exhaustion** (`POOL_PORT_RANGE=1` + the one port pre-claimed): `pool_find_free_port`
    rc 1 → NO Chrome spawned → ephemeral dir removed → lease deleted → return 1.
  - **CDP double-timeout** (selected port occupied by a listener so Chrome's debug port can't
    bind): two `pool_wait_cdp` timeouts → **0 Chrome pgroups left** (killed by `pool_wait_cdp`
    + `_pool_release_lane_internals`) → dir + lease gone → return 1.
  - **daemon connect fail** (`AGENT_BROWSER_REAL=/nonexistent`): Chrome launched + CDP ready
    but `pool_daemon_connect` rc 1 → the **LIVE Chrome is killed** (proves the early
    chrome-id write — no leak) → dir + lease gone → return 1.
- **Chrome-identity-early-write** verified: after a successful launch but before step f, the
  lease already shows `chrome_pid` > 0 (reaper-safe if the boot is killed mid-way).
- **Parallelism preserved**: `pool_boot_lane` performs NO flocking and NO call into
  `pool_acquire_locked` — it is purely the post-lock body, so concurrent boots run in parallel
  (the FLOCK is owned by the caller / already released before this runs).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M5.T1.S1) unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its sole consumer is the
**acquire orchestration** (PRD §2.4 step 3e–3j) driven by the wrapper:

- **M6.T3.S1** (wrapper request lifecycle step 3) — the IMMEDIATE driver. After
  `pool_acquire_locked` returns lane N on rc 0, the wrapper reads the lease: `port==0`
  (provisional) ⇒ call **`pool_boot_lane "$N"`** (THIS function); `port>0 && connected`
  (adopted) ⇒ skip the boot, just `ensure_connected` (M5.T1.S3). On `pool_boot_lane` rc 1 ⇒
  retry acquire / defer to M5.T4 exhaustion.
- **M5.T1.S3** (`ensure_connected`) — on a Chrome mid-task crash (PRD §2.14 row "Chrome crash
  mid-task"), the relaunch-on-same-dir+port path may compose the launch+wait sub-flow
  (`_pool_launch_and_verify`) to bring the Chrome back without re-copying.

**Use Case**: Every `agent-browser` DRIVING invocation whose owner has no reusable lease
acquires a provisional lane under the short flock, then — OUTSIDE the lock — calls
`pool_boot_lane` to make it real (copy the master, grab a port, launch Chrome, wait for CDP,
bind the daemon, finalize the lease). This is the 5–10 s "cold start" that runs concurrently
across agents. After it, the wrapper execs the real binary with
`AGENT_BROWSER_SESSION=abpool-<N>`.

**Pain Points Addressed**:
- **Cold-start latency must not serialize across agents.** By running entirely outside the
  flock, N agents boot N lanes in parallel (FINDING 2). `pool_boot_lane` does NO locking.
- **A crashed/wedged Chrome must not leak or hang the agent.** The CDP-timeout path retries
  once then drops the lane cleanly (kill pgroup + rm dir + delete lease) and returns 1 so the
  wrapper can retry acquire (PRD §2.14).
- **A boot killed mid-way must not leak a Chrome.** Writing `chrome_pid`/`chrome_pgid` to the
  lease right after launch (not only at the end) lets the lazy reaper tear it down on the next
  acquire — see §"Known Gotchas".
- **Port collisions between concurrent boots must be minimized.** Writing `port` to the lease
  immediately after `pool_find_free_port` (step b) reserves it for the other concurrent
  boots' `pool_find_free_port` claimed-port scan.

## Why

- **This IS PRD §2.4 step 3e–3j (the post-lock boot).** Without it a provisional claim never
  becomes a drivable lane — there is no Chrome, no daemon binding, no usable session.
- **The short-flock invariant (FINDING 2) is completed here.** S1 held the lock ONLY for
  scan+claim; THIS function does all the slow work (5–10 s Chrome boot) OUTSIDE the lock, which
  is what makes N parallel boots possible.
- **PRD §2.14 failure handling is owned here.** "Chrome slow to boot → retry launch once;
  then fail, drop lane" is literally step d of this function. Every other recoverable failure
  (port exhaustion, connect fail) drops the lane cleanly so the wrapper can retry.
- **The early chrome-id write closes a real leak window.** Without it, a mid-boot death leaves
  an orphan Chrome the reaper cannot find (`chrome_pid:0`). This task makes the lease the
  source of truth for teardown as early as possible.

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| provisional lease on lane 1, master present, free port, Chrome healthy | `pool_boot_lane 1` | **rc 0**; lease: `port>0, chrome_pid>0, chrome_pgid>0, connected:true, last_seen_at=now`; Chrome pgroup alive; `abpool-1` bound to daemon |
| port range exhausted (`POOL_PORT_RANGE=1` + that port claimed) | `pool_boot_lane 1` | **rc 1**; no Chrome spawned; ephemeral dir removed; `lanes/1.json` deleted |
| Chrome's debug port can't bind (port occupied) → CDP never answers | `pool_boot_lane 1` | **rc 1**; Chrome launched twice, both timed out (killed by `pool_wait_cdp`); 0 pgroups left; dir + lease gone |
| Chrome healthy + CDP ready, but `pool_daemon_connect` rc 1 | `pool_boot_lane 1` | **rc 1**; the LIVE Chrome **killed** (no leak); dir + lease gone |
| `pool_copy_master` fails (non-btrfs, no slow-copy) | `pool_boot_lane 1` | **pool_die propagates** (fatal — misconfiguration); provisional lease left for reaper |
| `pool_chrome_launch` instant-exits (broken binary / bad flags) | `pool_boot_lane 1` | **pool_die propagates** (fatal — surfaces the chrome-`<N>.log` path); provisional lease left for reaper |
| two concurrent `pool_boot_lane` calls (distinct lanes) | both | run in parallel (no lock); each gets a distinct port (early port write prevents collision in the common case) |

**Hard invariants** (every row):
- **No flocking.** `pool_boot_lane` never opens `acquire.lock` and never calls
  `pool_acquire_locked`. The lock is the caller's concern (already released). This is the
  FINDING 2 completion.
- **Step b writes `port` to the lease BEFORE launch** (anti-collision — the contract mandates
  "Update lease port" at step b). `pool_lease_update "$LANE" port "$PORT"`.
- **`chrome_pid`/`chrome_pgid` are written to the lease right after EACH launch** (not only at
  step f). This is the leak-prevention refinement (research §2): the lazy reaper can tear down
  a Chrome whose boot died mid-way, and every failure-path cleanup via
  `_pool_release_lane_internals` reads the real pid and kills correctly.
- **The retry (step d) is the CDP-TIMEOUT case only.** `pool_wait_cdp` rc 1 (Chrome pgroup
  already killed by `pool_wait_cdp`) ⇒ retry `pool_chrome_launch` + re-write chrome-ids +
  `pool_wait_cdp` once more. Second rc 1 ⇒ cleanup + return 1. The instant-exit `pool_die`
  from `pool_chrome_launch` is FATAL and propagates (NOT retried — research §3).
- **Every recoverable failure cleans up via `_pool_release_lane_internals "$LANE"`** (the S1
  private kernel): kill Chrome (idempotent), guarded `rm -rf` the dir, delete the lease. No
  bespoke `kill`/`rm` in this function. Return 1 after cleanup.
- **`pool_die` (fatal) propagates** for `pool_copy_master` (non-btrfs) and
  `pool_chrome_launch` (instant-exit). These exit the process; the provisional lease they
  leave is self-healing (owner now dead → next acquire's REAP-STALE reaps it).
- **The final lease matches the contract's step-f state exactly**:
  `{port:<PORT>, chrome_pid:<PID>, chrome_pgid:<PGID>, connected:true, last_seen_at:<now>}`.
  (port written at b; chrome_pid/chrome_pgid written at c; connected/last_seen_at written at f.)
- **Every `local` capture is split** (`local X; X="$(…)"` — BashFAQ 105 / SC2155) and every
  non-fatal rc-1 helper (`pool_find_free_port`, `pool_wait_cdp`, `pool_daemon_connect`,
  `_pool_launch_and_verify`) is guarded with `if …; then …; else <cleanup>; return 1; fi`.

### Success Criteria

- [ ] `pool_boot_lane` (+ the private helpers) defined in `lib/pool.sh` under a
      `# Acquire — post-lock boot (P1.M5.T1.S2)` banner, appended after `pool_acquire_locked`.
      Callable after `source lib/pool.sh` + `pool_config_init`.
- [ ] Happy path: provisional lane 1 → rc 0; lease complete (`port>0, chrome_pid>0,
      connected:true, last_seen_at=now`); Chrome pgroup alive on the port; CDP answers;
      `abpool-1` in the daemon session list.
- [ ] Port-exhaustion path: rc 1; no Chrome; dir removed; lease deleted.
- [ ] CDP-double-timeout path: rc 1; 0 Chrome pgroups left; dir + lease gone.
- [ ] Daemon-connect-fail path: rc 1; the LIVE Chrome killed (no leak); dir + lease gone.
- [ ] Early chrome-id write verified (lease has `chrome_pid>0` before step f).
- [ ] No flocking / no call into `pool_acquire_locked` inside `pool_boot_lane`.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1–M5.T1.S1) unchanged and callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **composed-function contract
table** (research §1 — exact rc conventions for all 7 LANDED helpers `pool_boot_lane` calls,
quoted from the `lib/pool.sh` source); **THE central leak gotcha** (chrome identity lives in
`POOL_CHROME_PID/PGID` globals during boot, NOT the lease until step f — so a daemon-connect
failure would leak a live Chrome UNLESS chrome-ids are written to the lease right after launch;
research §2); the **`pool_wait_cdp`-kills-on-timeout** behavior (the retry just re-launches;
research §1.3/§3); the **instant-exit pool_die is FATAL, not retryable** (research §3); the
**port anti-collision write** (research §4); the **`set -e` + `local var=$(...)` masking**
gotcha (research §5); the **uniform-cleanup-via-`_pool_release_lane_internals`** design
(research §6 — no bespoke rm/kill); the **S1 caller contract** (provisional vs adopted lease
state — research §0); the **PRD §2.8 lease schema**; and copy-pasteable, host-verified
validation commands (incl. a real-Chrome happy path, an occupied-port CDP-timeout test, and a
`/nonexistent`-binary connect-fail test).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3e (COPY: cp -a --reflink=always; rm Singleton*), 3f (PORT: lowest free TCP
        port, probe via curl /json/version), 3g (LAUNCH: setsid google-chrome --remote-debugging-port
        --user-data-dir + anti-throttle flags; record chrome_pid+pgid), 3h (WAIT for CDP ≤30×0.5s),
        3i (CONNECT: agent-browser --session abpool-<N> connect <port>), 3j (Update lease
        {port,chrome_pid,pgid,connected:true}); §2.6 (Chrome launch flags verbatim); §2.7 (copy /
        master hygiene: reflink=always, rm Singleton{Lock,Cookie,Socket}, master read-only);
        §2.8 (lease schema — the 12 fields); §2.14 (Chrome slow to boot → retry launch once; then
        fail, drop lane).
  pattern: step 3e–3j IS pool_boot_lane; §2.14 "Chrome slow to boot" row IS the retry-once policy.
  gotcha: §2.4 step 3b "ensure connected" forbids the broken `get cdp-url` (auto-launches strays —
        see P1.M4.T3.S1 research §2). pool_boot_lane uses pool_daemon_connect (attach) for the
        CONNECT step — never `get cdp-url`.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (THE short-flock rule — claim under lock, the slow boot runs AFTER releasing so
        concurrent acquires boot in parallel → pool_boot_lane does NO flocking); FINDING 3 (no bare
        ~ → POOL_EPHEMERAL_ROOT is absolute via pool_config_init; user_data-dir MUST be absolute);
        FINDING 6 (setsid → pgid==pid; kill -- -<pgid> with the `--`); FINDING 7 (atomic lease
        write: tmp in SAME dir + mv — pool_lease_update does this internally).
  pattern: FINDING 2 ⇒ pool_boot_lane is lock-free; FINDING 6 ⇒ the chrome pgroup teardown.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — POOL_EPHEMERAL_ROOT=<…>/.agent-chrome-profiles/active,
        POOL_LANES_DIR=<…>/lanes, chrome-<N>.log under POOL_STATE_DIR); §2 (btrfs confirmed for the
        ephemeral root → pool_copy_master reflink succeeds; google-chrome-stable + agent-browser +
        flock/curl/jq/setsid/ss all present).

- file: plan/001_0f759fe2777c/P1M5T1S1/PRP.md   # THE CONTRACT this task consumes
  why: S1 defines pool_acquire_locked (returns the provisional lane N on rc 0) + the PRIVATE
        release kernel _pool_release_lane_internals(LANE) that THIS task's cleanup composes.
        The pool_acquire_locked docstring's CALLER CONTRACT (research §0/§5) is the exact
        provisional-vs-adopted branching: port==0 ⇒ pool_boot_lane; port>0&&connected ⇒ ensure.
        _pool_release_lane_internals (S1 @1813) reads chrome_pid/chrome_pgid from the lease,
        pool_chrome_kill's, guarded rm -rf's the dir, deletes the lease — rc 0 always.
  pattern: failure cleanup in pool_bootlane == `_pool_release_lane_internals "$LANE"` (ONE call).
  gotcha: _pool_release_lane_internals reads chrome_pid FROM THE LEASE → it can only kill the live
        Chrome on the daemon-connect-fail path IF chrome_id was written to the lease right after
        launch (research §2). That early write is MANDATORY in this PRP.

# This task's own research (the composed-contract table + the leak gotcha + test recipes)
- file: plan/001_0f759fe2777c/P1M5T1S2/research/post-lock-boot.md
  why: THE evidence base. §0 (S1 caller contract — provisional vs adopted); §1 (the
        composed-function rc-convention TABLE, quoted from lib/pool.sh source); §2 (THE central
        gotcha — chrome identity in GLOBALS not lease during boot → the early-write mandate); §3
        (retry = CDP-timeout only; instant-exit pool_die is fatal); §4 (port anti-collision write);
        §5 (set -e + local var=$(...) masking); §6 (uniform cleanup via _pool_release_lane_internals);
        §7 (how to test each path on THIS host — no mocking needed); §8 (decisions summary).
  pattern: §1 is the contract table; §2 is the leak-prevention design; §7 is the test matrix.
  gotcha: §2 (early chrome-id write) + §1.3 (wait_cdp kills on timeout) + §3 (instant-exit is
        fatal) are the three highest-impact gotchas.

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M4T1S1/PRP.md   # pool_copy_master (M4.T1.S1 — LANDED @1253)
  why: step a. COPY. pool_copy_master "$POOL_EPHEMERAL_ROOT/$LANE": reflink CoW + rm Singleton*.
        Returns 0; pool_die's (fatal) on non-btrfs/no-slow-copy/bad-args. target_dir MUST be absolute.
        Idempotent parent mkdir. The 4.8 GB master exists on this host (verified).
- file: plan/001_0f759fe2777c/P1M4T2S1/PRP.md   # pool_find_free_port (M4.T2.S1 — LANDED @1376)
  why: step b. PORT. rc 0 echoes the lowest free port; rc 1 = range exhausted (NON-FATAL). Builds a
        claimed-port set from lanes/*.json .port (skips port<=0 → provisional port=0 does NOT
        reserve). GUARD under set -e: `if PORT="$(pool_find_free_port)"; then …`.
- file: plan/001_0f759fe2777c/P1M4T2S2/PRP.md   # pool_chrome_launch + pool_wait_cdp (M4.T2.S2 — LANDED @1471/@1570)
  why: steps c + d. pool_chrome_launch(PORT, UDD, LANE): setsid + anti-throttle flags; sets globals
        POOL_CHROME_PID=$! / POOL_CHROME_PGID via declare -g; returns 0 or pool_die's on INSTANT
        exit (fatal). pool_wait_cdp(PORT): curls /json/version up to 60×0.5s; rc 0 ready; rc 1
        timeout AND KILLS the chrome pgroup (read POOL_CHROME_PGID) BEFORE returning 1. NON-FATAL.
- file: plan/001_0f759fe2777c/P1M4T3S1/PRP.md   # pool_daemon_connect (M4.T3.S1 — LANDED @1631)
  why: step e. CONNECT. "$POOL_REAL_BIN" --session abpool-<N> connect <port>; returns subprocess rc
        (0 bound / 1 dead). NON-FATAL. Idempotent/re-bindable. NEVER use `get cdp-url` (auto-launch
        trap — research §2 of that PRP).
- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md   # pool_lease_update (M3.T1.S1 — LANDED @763)
  why: steps b/c/f. pool_lease_update(LANE, FIELD, VALUE): sets ONE top-level field; VALUE spliced
        as raw JSON (--argjson) → numbers / true / false / "quoted-str". pool_die's on missing/corrupt
        lease (none here — provisional from S1) or non-JSON value. `connected` MUST be literal `true`.

# External authoritative docs (for the WHY; bash behavior is HOST-VERIFIED in research §5)
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: THE `set -e` surprises reference. `local var=$(...)` masks errexit (local returns 0) →
        EVERY capture in pool_boot_lane must be split: `local X; X="$(...)"`.
- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: ${POOL_CHROME_PID:-} / ${POOL_CHROME_PGID:-} default-expansion guards (a bare reference
        under set -u ABORTS if the global is unset — e.g. before any launch).
```

### Current Codebase tree

After **M1–M5.T1.S1** have landed, `lib/pool.sh` (2055 lines) ends with
`pool_acquire_locked` as the final function (@2043):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T1.S1) with pool_acquire_locked at EOF.
│                                         #   Banner order at EOF:
│                                         #   ... pool_wait_cdp (M4.T2.S2)
│                                         #   # Lane lifecycle — daemon connect, verify & teardown (M4.T3.S1)
│                                         #   pool_daemon_connect / pool_daemon_connected / pool_chrome_kill
│                                         #   # Acquire — flock critical section (M5.T1.S1)
│                                         #   _pool_release_lane_internals / _pool_adopt_lane
│                                         #   / _pool_acquire_critical_section / pool_acquire_locked  ← current EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T1S1/PRP.md
    └── P1M5T1S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/post-lock-boot.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND under a new banner AFTER pool_acquire_locked (EOF):
                  #   # Acquire — post-lock boot (P1.M5.T1.S2)
                  #   _pool_boot_write_chrome_ids(lane):   # (optional) DRY the chrome-id write
                  #       pool_lease_update lane chrome_pid $POOL_CHROME_PID
                  #       pool_lease_update lane chrome_pgid $POOL_CHROME_PGID
                  #   _pool_launch_and_verify(port, ephemeral_dir, lane):   # launch + wait + retry-once
                  #       pool_chrome_launch (0 or fatal pool_die on instant-exit)
                  #       _pool_boot_write_chrome_ids lane          # write globals → lease (robustness)
                  #       pool_wait_cdp: rc 0 → return 0
                  #       rc 1 (chrome pgroup already killed) → RETRY: pool_chrome_launch + write + wait
                  #       rc 0 → return 0 ; rc 1 → return 1 (chrome already killed)
                  #   pool_boot_lane(lane):   # PUBLIC — the CONTRACT name
                  #       a. pool_copy_master "$POOL_EPHEMERAL_ROOT/$lane"            (fatal pool_die ok)
                  #       b. PORT=pool_find_free_port (rc 1 → _pool_release_lane_internals; return 1)
                  #          pool_lease_update lane port "$PORT"                       (anti-collision)
                  #       c+d. _pool_launch_and_verify "$PORT" "$eph" "$lane"          (rc 1 → cleanup; return 1)
                  #       e. pool_daemon_connect "abpool-$lane" "$PORT" (rc 1 → cleanup; return 1)
                  #       f. pool_lease_update lane connected true ; pool_lease_update lane last_seen_at "$now"
                  #       return 0
                  #   (NO changes to any existing function — esp. NOT pool_chrome_launch / pool_wait_cdp /
                  #    pool_daemon_connect / pool_lease_update / _pool_release_lane_internals)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**post-lock boot** — the copy→port→launch→wait→connect→update-lease pipeline (PRD §2.4 step
3e–3j) that turns a provisional claim into a fully-provisioned lane. It reads
`POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`, `POOL_REAL_BIN`, and the `POOL_CHROME_PID/PGID`
globals; it writes only the lease (via `pool_lease_update`) and (on failure) tears the lane
down via `_pool_release_lane_internals`. It is lock-free (FINDING 2).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (THE LEAK GOTCHA — research §2): chrome identity lives in GLOBALS during the boot.
#   pool_chrome_launch sets POOL_CHROME_PID/POOL_CHROME_PGID via declare —g (NOT the lease). The
#   contract's step f writes them to the lease at the END. BUT on the daemon-connect-fail path
#   (step e) the Chrome is ALIVE (CDP answered) and the lease still has chrome_pid:0 → if cleanup
#   read the lease it would call pool_chrome_kill 0 0 (no-op) → the live Chrome LEAKS. MANDATE:
#   write chrome_pid/chrome_pgid to the lease IMMEDIATELY after EACH launch (step c, and again on
#   the retry). Then _pool_release_lane_internals reads the real pid and kills correctly on EVERY
#   failure path. BONUS: if the boot process is killed mid-way, the lazy reaper can tear the
#   Chrome down (it reads the lease). HOST-VERIFIED (research §2).

# CRITICAL (pool_wait_cdp KILLS the chrome pgroup on timeout — research §1.3): on rc 1 the Chrome
#   is ALREADY DEAD (kill -- -"$POOL_CHROME_PGID"). So the retry just re-launches (overwrites the
#   globals + the lease chrome-ids). The final cleanup finds an already-dead Chrome (no-op kill).
#   Do NOT add a redundant kill after a wait_cdp rc 1 before the retry.

# CRITICAL (instant-exit pool_die is FATAL, NOT retryable — research §3): pool_chrome_launch calls
#   pool_die (exit 1) if Chrome dies before its pgroup can be read. The contract's "retry once"
#   applies ONLY to the CDP-TIMEOUT case (pool_wait_cdp rc 1). Do NOT try to catch the pool_die in
#   a subshell — you'd lose the declare -g globals and leak the Chrome. Let it propagate.

# CRITICAL (`local var=$(...)` masks errexit — research §5 / BashFAQ 105 / SC2155): `local X="$(…)"`
#   — local returns 0 always, so set -e does NOT fire on a failing $(…). EVERY capture MUST be split:
#       local PORT; PORT="$(pool_find_free_port)"     # ← errexit now propagates
#       local now; now="$(_pool_now)"
#   Applies to pool_find_free_port, _pool_now, and any pool_lease_field read.

# CRITICAL (non-fatal rc-1 helpers MUST be guarded under set -e): pool_find_free_port,
#   pool_wait_cdp, pool_daemon_connect, _pool_launch_and_verify all return 1 on a RECOVERABLE
#   failure. A BARE call ABORTS the caller. Use `if …; then …; else <cleanup>; return 1; fi`.
#   (_pool_release_lane_internals always returns 0 → no guard needed.)

# CRITICAL (step b writes port to the lease BEFORE launch — research §4 anti-collision):
#   pool_find_free_port builds a claimed-port set from lanes/*.json .port. Two concurrent boots
#   (outside the flock) could both pick the same port UNLESS each writes its port back to the lease
#   promptly. The contract MANDATES "Update lease port" at step b. pool_lease_update "$LANE" port "$PORT".

# GOTCHA (pool_lease_update VALUE typing): value is spliced as raw JSON via --argjson. So port /
#   chrome_pid / chrome_pgid / last_seen_at are passed as bare digits (e.g. "53427"), and connected
#   MUST be the literal string "true" (not "1" / "True" / "yes"). A non-JSON value → jq exit 2 → pool_die.

# GOTCHA (pool_lease_update is TOP-LEVEL ONLY + pool_die's on missing/corrupt lease): fine here —
#   the provisional lease exists (written by pool_acquire_locked). chrome_pid/chrome_pgid/port/
#   connected/last_seen_at are all TOP-LEVEL fields (PRD §2.8) → pool_lease_update works for each.

# GOTCHA (POOL_CHROME_PID/PGID may be UNSET under set -u): before any launch, or in a standalone
#   test, the globals may be unset. Reference them as ${POOL_CHROME_PID:-} / ${POOL_CHROME_PGID:-}
#   (default expansion) — a bare $POOL_CHROME_PID ABORTS under set -u if unset. (They ARE set after a
#   successful pool_chrome_launch, but be defensive in the chrome-id writer.)

# GOTCHA (cleanup delegates 100% to _pool_release_lane_internals — research §6): pool_boot_lane
#   writes NO kill / NO rm itself. Every failure path is `_pool_release_lane_internals "$LANE"`
#   (reads chrome_id from the lease — correct because of the early write; guarded rm -rf; deletes
#   the lease; rc 0 always). Do NOT re-implement the rm-rf guard.

# GOTCHA (the ephemeral dir path is $POOL_EPHEMERAL_ROOT/$LANE — ABSOLUTE): passed to BOTH
#   pool_copy_master (step a) and pool_chrome_launch --user-data-dir (step c). Both require ABSOLUTE
#   (PRD §2.2 / FINDING 3). $POOL_EPHEMERAL_ROOT is frozen absolute by pool_config_init.

# GOTCHA (session is "abpool-<LANE>"): the provisional lease from S1 already carries session
#   "abpool-$N". pool_daemon_connect "abpool-$LANE" "$PORT" reconstructs it (do NOT read it from the
#   lease — reconstruct from the lane number, matching the contract).

# GOTCHA (naming + placement): pool_boot_lane (PUBLIC, CONTRACT name, no `_`) + _pool_launch_and_verify
#   + _pool_boot_write_chrome_ids (PRIVATE `_pool_*`). APPEND at EOF after pool_acquire_locked. Do NOT
#   touch any existing function.

# GOTCHA (scope — the post-lock boot ONLY): do NOT implement ensure_connected (M5.T1.S3), the
#   exhaustion wait-loop (M5.T4), release (M5.T2.S1), reap/reuse (M5.T3.*), or the wrapper (M6). This
#   task ships pool_boot_lane + its private launch/wait helpers ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**.
It reads the lease schema (PRD §2.8, frozen by M3.T1.S1) and updates top-level fields via the
LANDED `pool_lease_update`. It READS the `POOL_CHROME_PID`/`POOL_CHROME_PGID` globals (set by
`pool_chrome_launch`) and writes them into the lease.

Global READ (frozen by `pool_config_init`; chrome globals set by `pool_chrome_launch`):

| global | source | example | role |
|---|---|---|---|
| `POOL_EPHEMERAL_ROOT` | pool_config_init | `/home/dustin/.agent-chrome-profiles/active` | ephemeral dir `$ROOT/$LANE` — copy target + Chrome `--user-data-dir` |
| `POOL_LANES_DIR` | pool_config_init | `…/agent-browser-pool/lanes` | lease `<N>.json` (read/updated/deleted via helpers) |
| `POOL_REAL_BIN` | pool_config_init | `…/bin/agent-browser-linux-x64` | the CONNECT subprocess (`--session abpool-N connect PORT`) |
| `POOL_CHROME_PID` | pool_chrome_launch | `104816` | written to lease `.chrome_pid` (early, after launch) |
| `POOL_CHROME_PGID` | pool_chrome_launch | `104816` | written to lease `.chrome_pgid` (early, after launch) |

External commands (verified present this session): `cp` (via `pool_copy_master`),
`google-chrome-stable` + `setsid` (via `pool_chrome_launch`), `curl` (via `pool_wait_cdp`),
`agent-browser` (via `pool_daemon_connect`), `jq` (via `pool_lease_update`). All present on host.

**Naming** (CONTRACT-mandated + codebase convention): `pool_boot_lane` (public, CONTRACT name) +
`_pool_launch_and_verify` + `_pool_boot_write_chrome_ids` (private `_pool_*` helpers).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init \
                  pool_copy_master pool_find_free_port pool_chrome_launch pool_wait_cdp \
                  pool_daemon_connect pool_lease_update _pool_release_lane_internals \
                  pool_acquire_locked _pool_now'
  - EXPECT: all reported as functions (M1–M5.T1.S1 LANDED). If any MISSING → STOP.
  - RUN (verify the globals + host facts this task depends on):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_EPHEMERAL_ROOT" && -n "$POOL_LANES_DIR" && -n "$POOL_REAL_BIN" ]] \
                   && echo "OK globals" || echo FAIL'
        command -v google-chrome-stable >/dev/null && echo "OK chrome" || echo FAIL
        [[ -d "$HOME/.agent-chrome-profiles/master-profile" ]] && echo "OK master" || echo FAIL
        findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles" | grep -q btrfs && echo "OK btrfs" || echo FAIL
  - EXPECT: OK globals ; OK chrome ; OK master ; OK btrfs.
  - RUN (locate the append point — current EOF must be pool_acquire_locked):
        grep -nE '^pool_acquire_locked\(\)' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
  - EXPECT: pool_acquire_locked defined; it is the last function. APPEND the new banner + the
        functions AFTER its closing brace. Do NOT touch any existing function.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND _pool_boot_write_chrome_ids() + _pool_launch_and_verify() + pool_boot_lane() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_acquire_locked's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block, then adapt commentary to codebase style):
        # =============================================================================
        # Acquire — post-lock boot (P1.M5.T1.S2)
        # =============================================================================
        # Turn a PROVISIONALLY-claimed lane (port=0, from pool_acquire_locked / M5.T1.S1) into a
        # FULLY-provisioned lane: copy master → pick port → launch Chrome → wait CDP → bind daemon →
        # finalize lease. PRD §2.4 step 3e–3j, run OUTSIDE the flock (key_findings FINDING 2: concurrent
        # boots). PRD §2.14 failure handling: CDP-timeout → retry launch once → drop lane. Every
        # recoverable failure cleans up via _pool_release_lane_internals (M5.T1.S1) and returns 1.
        # Consumed by the wrapper lifecycle (M6.T3.S1) after pool_acquire_locked returns a provisional lane.

        # _pool_boot_write_chrome_ids LANE
        #
        # Write the POOL_CHROME_PID / POOL_CHROME_PGID globals (set by pool_chrome_launch) into the lease
        # for LANE as top-level chrome_pid / chrome_pgid. Called right after EACH launch (incl. the retry)
        # — NOT only at step f. This is the LEAK-PREVENTION refinement (research §2):
        #   (1) _pool_release_lane_internals reads chrome_id FROM THE LEASE → with this early write it
        #       correctly kills the LIVE Chrome on the daemon-connect-fail path (step e). Without it,
        #       cleanup would read chrome_pid:0 → pool_chrome_kill 0 0 (no-op) → LEAK.
        #   (2) if pool_boot_lane is killed mid-way, the lazy reaper (M5.T3) reads the lease and tears
        #       the Chrome down — impossible if chrome_id is still 0.
        # Uses pool_lease_update (top-level field; value = raw JSON number via --argjson). The lease
        # exists (provisional from S1); a missing/corrupt lease would pool_die (exceptional).
        # GOTCHA — reference the globals with ${…:-} (set -u safe before any launch).
        # Reads POOL_CHROME_PID/PGID + POOL_LANES_DIR. PRECONDITION: pool_chrome_launch just succeeded.
        _pool_boot_write_chrome_ids() {
            local lane="${1:-}"
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1
            pool_lease_update "$lane" chrome_pid "${POOL_CHROME_PID:-0}"
            pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
        }

        # _pool_launch_and_verify PORT EPHEMERAL_DIR LANE
        #
        # The launch + CDP-wait + RETRY-ONCE sub-flow. Returns 0 if Chrome's CDP endpoint answers;
        # returns 1 if it times out TWICE (the Chrome pgroup is already killed by pool_wait_cdp on each
        # timeout — research §1.3). PRD §2.14 "Chrome slow to boot → retry launch once; then fail".
        #
        # LOGIC:
        #   1. pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   (sets globals; pool_die on
        #      instant-exit is FATAL — propagates, NOT retried; research §3).
        #   2. _pool_boot_write_chrome_ids "$lane"   (write globals → lease; robustness §2).
        #   3. pool_wait_cdp "$port": rc 0 → return 0.
        #   4. rc 1 (Chrome pgroup already killed) → RETRY: pool_chrome_launch + write_chrome_ids +
        #      pool_wait_cdp. rc 0 → return 0; rc 1 → return 1 (Chrome already killed).
        #
        # GOTCHA — the retry overwrites POOL_CHROME_PID/PGID (and the lease chrome-ids) with the 2nd
        #   Chrome's identity, so a subsequent cleanup reads the correct (2nd, already-dead) pid.
        # GOTCHA — pool_wait_cdp ALREADY kills the pgroup on timeout; do NOT add a redundant kill here.
        # GOTCHA — instant-exit pool_die (pool_chrome_launch) propagates (fatal) — not catchable without
        #   losing the declare -g globals in a subshell (research §3).
        # NON-FATAL on the CDP-timeout path (return 1). Reads POOL_EPHEMERAL_ROOT implicitly (via
        # pool_chrome_launch's user_data_dir). PRECONDITION: pool_config_init + pool_state_init.
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
            pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # relaunch (overwrites globals)
            _pool_boot_write_chrome_ids "$lane"                    # 2nd chrome-ids → lease
            if pool_wait_cdp "$port"; then
                return 0
            fi
            # Second timeout ⇒ Chrome already killed. Caller cleans up the lane.
            return 1
        }

        # pool_boot_lane LANE
        #
        # PUBLIC ENTRY POINT (the CONTRACT name). Provision a lane: COPY master → PORT → LAUNCH+WAIT
        # (retry once) → CONNECT → finalize LEASE. PRD §2.4 step 3e–3j, OUTSIDE the flock (FINDING 2 —
        # concurrent boots; this function does NO locking). Input: a PROVISIONAL lease for LANE (port=0,
        # from pool_acquire_locked). Output: lane fully provisioned (return 0) OR cleaned up (return 1).
        #
        # Recoverable failures (→ _pool_release_lane_internals + return 1):
        #   - step b: pool_find_free_port rc 1 (port range exhausted) — no Chrome yet.
        #   - step d: _pool_launch_and_verify rc 1 (CDP timed out twice) — Chrome already killed.
        #   - step e: pool_daemon_connect rc 1 (daemon bind failed) — LIVE Chrome killed via cleanup
        #     (chrome_id is in the lease from step c's early write → no leak).
        # Fatal failures (pool_die propagates — genuine misconfiguration; provisional lease self-heals
        # via the next acquire's REAP-STALE):
        #   - step a: pool_copy_master non-btrfs / slow-copy-fail.
        #   - step c: pool_chrome_launch instant-exit (broken binary / bad flags).
        #
        # CALLER CONTRACT (the wrapper M6.T3.S1, under set -e):
        #     local N
        #     if N="$(pool_acquire_locked)"; then
        #         local port
        #         port="$(pool_lease_field "$N" port)"
        #         if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        #             pool_boot_lane "$N" || <retry acquire / M5.T4 exhaustion>
        #         else
        #             <M5.T1.S3 adopted: ensure_connected only; skip the boot>
        #         fi
        #     else
        #         <M5.T4 exhaustion>
        #     fi
        #
        # GOTCHA — the chrome-id early write (step c, inside _pool_launch_and_verify) is what makes the
        #   step-e cleanup able to kill the LIVE Chrome. Never reorder it to step f (research §2).
        # GOTCHA — step b writes port to the lease BEFORE launch (anti-collision — research §4).
        # GOTCHA — `local PORT; PORT="$(pool_find_free_port)"` MUST be split (BashFAQ 105 / SC2155).
        # GOTCHA — every recoverable failure → `_pool_release_lane_internals "$LANE"` then return 1.
        #   Do NOT write your own kill/rm here.
        # Reads POOL_EPHEMERAL_ROOT, POOL_LANES_DIR (via helpers), POOL_REAL_BIN (via pool_daemon_connect),
        # POOL_CHROME_PID/PGID (via _pool_boot_write_chrome_ids). No new globals exported.
        # PRECONDITION: pool_config_init + pool_state_init + a PROVISIONAL lease for LANE (from S1).
        pool_boot_lane() {
            local lane="${1:-}"
            local ephemeral_dir port now

            # Validate lane.
            [[ "$lane" =~ ^[0-9]+$ ]] \
                || pool_die "pool_boot_lane: lane must be a non-negative integer, got: '$lane'"

            ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"

            # --- a. COPY: reflink CoW copy of the master → ephemeral dir (PRD §2.4 step 3e / §2.7). ---
            #     pool_die's (fatal) on non-btrfs/no-slow-copy — propagates (genuine misconfiguration).
            pool_copy_master "$ephemeral_dir"

            # --- b. PORT: lowest free TCP port (PRD §2.4 step 3f). ---
            #     rc 1 = range exhausted (NON-FATAL). Split the capture (BashFAQ 105). On failure,
            #     clean up (the dir was just copied) + return 1.
            if ! port="$(pool_find_free_port)"; then
                _pool_log "pool_boot_lane: port range exhausted for lane $lane; dropping lane"
                _pool_release_lane_internals "$lane"
                return 1
            fi
            # Anti-collision: write port to the lease BEFORE launch so concurrent pool_find_free_port
            # calls see it claimed (research §4). pool_lease_update splices the value as raw JSON.
            pool_lease_update "$lane" port "$port"

            # --- c+d. LAUNCH + WAIT (retry once on CDP timeout) (PRD §2.4 step 3g/3h / §2.14). ---
            #     _pool_launch_and_verify returns 0 (CDP ready) or 1 (timed out twice; Chrome killed).
            #     On failure, clean up + return 1.
            if ! _pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"; then
                _pool_log "pool_boot_lane: CDP not ready after retry for lane $lane port $port; dropping lane"
                _pool_release_lane_internals "$lane"
                return 1
            fi

            # --- e. CONNECT: bind the daemon session to the Chrome (PRD §2.4 step 3i). ---
            #     rc 1 = NON-FATAL (dead/unreachable). The Chrome is ALIVE here (CDP just answered) —
            #     _pool_release_lane_internals kills it correctly (chrome_id is in the lease from step c).
            if ! pool_daemon_connect "abpool-$lane" "$port"; then
                _pool_log "pool_boot_lane: daemon connect failed for lane $lane port $port; dropping lane"
                _pool_release_lane_internals "$lane"
                return 1
            fi

            # --- f. UPDATE LEASE: connected=true + last_seen_at=now (PRD §2.4 step 3j). ---
            #     port + chrome_pid + chrome_pgid are already set (steps b + c). `connected` MUST be
            #     the literal "true" (pool_lease_update splices via --argjson). last_seen_at = epoch s.
            now="$(_pool_now)"
            pool_lease_update "$lane" connected true
            pool_lease_update "$lane" last_seen_at "$now"

            _pool_log "pool_boot_lane: lane $lane provisioned (port=$port pid=${POOL_CHROME_PID:-0})"
            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155 + BashFAQ-105); non-fatal
        rc-1 helpers guarded with `if ! …; then <cleanup>; return 1; fi`; cleanup delegated to
        `_pool_release_lane_internals`; `_pool_log` one line per action/boot phase; docstrings
        with LOGIC + CONSUMER + GOTCHA sections (mirror pool_wait_cdp / pool_chrome_launch).
  - NAMING: pool_boot_lane (PUBLIC, CONTRACT) + _pool_launch_and_verify + _pool_boot_write_chrome_ids
        (PRIVATE `_pool_*`).
  - PLACEMENT: the functions in the new "(P1.M5.T1.S2)" banner, after pool_acquire_locked.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_boot_lane _pool_launch_and_verify _pool_boot_write_chrome_ids' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: HAPPY PATH — provisional lane → fully provisioned (rc 0) ---
  - RUN (isolated state + ephemeral dirs; real master/chrome/agent-browser):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Plant a PROVISIONAL lease for lane 1 (as pool_acquire_locked would):
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" \
                      99999 pi 1111 "/tmp" 0 0 "false"
                  if pool_boot_lane 1; then echo "OK1-rc0"; else echo "FAIL1-rc"; fi
                  # Assertions on the final lease:
                  port="$(pool_lease_field 1 port)"; cpid="$(pool_lease_field 1 chrome_pid)"
                  cpgid="$(pool_lease_field 1 chrome_pgid)"; conn="$(pool_lease_field 1 connected)"
                  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 53420 ]] && echo "OK1-port=$port" || echo "FAIL1-port=$port"
                  [[ "$cpid" =~ ^[0-9]+$ && "$cpid" -gt 0 ]] && echo "OK1-chrome_pid=$cpid" || echo "FAIL1-chrome_pid"
                  [[ "$cpgid" =~ ^[0-9]+$ && "$cpgid" -gt 0 ]] && echo "OK1-chrome_pgid=$cpgid" || echo "FAIL1-chrome_pgid"
                  [[ "$conn" == "true" ]] && echo "OK1-connected=true" || echo "FAIL1-connected=$conn"
                  # Chrome pgroup alive + CDP answers + daemon knows the session:
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK1-cdp" || echo "FAIL1-cdp"
                  "$POOL_REAL_BIN" --session abpool-1 --json session list 2>/dev/null \
                      | jq -e --arg s abpool-1 ".data.sessions | index(\$s)" >/dev/null && echo "OK1-session" || echo "FAIL1-session"
                  # CLEANUP the chrome we just booted:
                  g="$cpgid"; kill -9 -- -"$g" 2>/dev/null || true
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK1-rc0 ; OK1-port=… ; OK1-chrome_pid=… ; OK1-chrome_pgid=… ; OK1-connected=true ;
        #         OK1-cdp ; OK1-session.
  #
  # --- SCENARIO 2: PORT EXHAUSTION — pool_find_free_port rc 1 → cleanup + return 1, no Chrome ---
  - RUN (RANGE=1 + pre-claim that one port in another lease):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes"
        # Pre-claim the ONLY port (53420) in a lane-2 lease (so pool_find_free_port's claimed-set excludes it):
        jq -n --argjson lane 2 --arg ed "$EPHEM/2" --argjson port 53420 --arg session "abpool-2" \
              --argjson pid 22222 --arg comm pi --argjson st 222 --arg cwd "" --argjson cpid 0 \
              --argjson cpgid 0 --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:false}' > "$STATE/lanes/2.json"
        before="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1 AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  if pool_boot_lane 1; then echo "FAIL2-should-be-rc1"; else echo "OK2-rc1"; fi
                  test -e "$POOL_EPHEMERAL_ROOT/1" && echo "FAIL2-dir" || echo "OK2-dir-gone"
                  test -e "$POOL_LANES_DIR/1.json" && echo "FAIL2-lease" || echo "OK2-lease-gone"'
        after="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK2-no-chrome-spawned" || echo "FAIL2-chrome-spawned"
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK2-rc1 ; OK2-dir-gone ; OK2-lease-gone ; OK2-no-chrome-spawned.
  #
  # --- SCENARIO 3: CDP DOUBLE-TIMEOUT — port occupied so Chrome's debug port can't bind → retry → drop ---
  - RUN (occupy the selected port with a listener before pool_boot_lane launches):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        # Occupy port 53420 so Chrome's --remote-debugging-port=53420 can't bind → /json/version never answers:
        python3 -m http.server 53420 --bind 127.0.0.1 >/tmp/s3-occ.log 2>&1 & OCC=$!
        sleep 0.5
        before="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1 AGENT_CHROME_HEADLESS=1 \
        timeout 120 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Pre-claim nothing (so pool_find_free_port picks 53420 — which is occupied by the http.server).
                  # NOTE: pool_find_free_port's curl probe may reject 53420 (it answers, but not /json/version).
                  # If so, set RANGE=2 and occupy BOTH 53420 and 53421 to force the collision path. Simpler:
                  # launch Chrome directly on the occupied port via the helper to exercise the retry path:
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_copy_master "$POOL_EPHEMERAL_ROOT/1"
                  if _pool_launch_and_verify 53420 "$POOL_EPHEMERAL_ROOT/1" 1; then
                      echo "FAIL3-should-timeout"; g="${POOL_CHROME_PGID:-}"; [[ -n "$g" ]] && kill -9 -- -"$g" 2>/dev/null || true
                  else echo "OK3-launch-verify-rc1"; fi
                  # And the full pool_boot_lane path (pool_find_free_port may skip 53420 due to the http.server;
                  # force a port it WILL pick by also occupying the next ones, OR just assert _pool_launch_and_verify):
                  true'
        after="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK3-no-chrome-leak" || echo "FAIL3-chrome-leak"
        kill "$OCC" 2>/dev/null || true; pkill -9 -f 'remote-debugging-port=53420' 2>/dev/null || true
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK3-launch-verify-rc1 ; OK3-no-chrome-leak.
        #   (Chrome launched twice, both CDP-waits timed out, pool_wait_cdp killed both pgroups → 0 left.)
        #   NOTE: this exercises _pool_launch_and_verify directly (the retry+timeout kernel). The full
        #   pool_boot_lane path is harder to force into the timeout branch deterministically (pool_find_free_port's
        #   curl probe may reject an occupied port before launch); _pool_launch_and_verify IS the retry logic.
  #
  # --- SCENARIO 4: DAEMON CONNECT FAIL — Chrome alive + CDP ready, connect rc 1 → LIVE Chrome killed (no leak) ---
  - RUN (AGENT_BROWSER_REAL=/nonexistent → pool_daemon_connect rc 1):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_REAL=/nonexistent/binary AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  before="$(pgrep -c -f "remote-debugging-port" 2>/dev/null || echo 0)"
                  if pool_boot_lane 1; then echo "FAIL4-should-be-rc1"; else echo "OK4-rc1"; fi
                  after="$(pgrep -c -f "remote-debugging-port" 2>/dev/null || echo 0)"
                  echo "chrome-before=$before chrome-after=$after"
                  [[ "$after" -le "$before" ]] && echo "OK4-live-chrome-killed-no-leak" || echo "FAIL4-leak"
                  test -e "$POOL_EPHEMERAL_ROOT/1" && echo "FAIL4-dir" || echo "OK4-dir-gone"
                  test -e "$POOL_LANES_DIR/1.json" && echo "FAIL4-lease" || echo "OK4-lease-gone"'
        pkill -9 -f 'remote-debugging-port' 2>/dev/null || true; rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK4-rc1 ; chrome-after <= chrome-before ; OK4-live-chrome-killed-no-leak ;
        #         OK4-dir-gone ; OK4-lease-gone.
        #   (Chrome booted + CDP answered, but pool_daemon_connect rc 1 → cleanup killed the LIVE Chrome
        #    via the lease chrome_id — the early write from step c. This is the §2 leak-prevention proof.)
  #
  # --- SCENARIO 5: EARLY CHROME-ID WRITE (robustness) — chrome_id in lease BEFORE step f ---
  - RUN (monkeypatch: after a successful launch, snapshot the lease mid-boot):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_copy_master "$POOL_EPHEMERAL_ROOT/1"
                  port="$(pool_find_free_port)"; pool_lease_update 1 port "$port"
                  pool_chrome_launch "$port" "$POOL_EPHEMERAL_ROOT/1" 1
                  _pool_boot_write_chrome_ids 1
                  # BEFORE connect/finalize, the lease MUST already carry the chrome identity:
                  cpid="$(pool_lease_field 1 chrome_pid)"; conn="$(pool_lease_field 1 connected)"
                  [[ "$cpid" =~ ^[0-9]+$ && "$cpid" -gt 0 ]] && echo "OK5-early-chrome_pid=$cpid" || echo "FAIL5-chrome_pid=$cpid"
                  [[ "$conn" == "false" ]] && echo "OK5-connected-still-false" || echo "FAIL5-connected=$conn"
                  g="${POOL_CHROME_PGID:-}"; [[ -n "$g" ]] && kill -9 -- -"$g" 2>/dev/null || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK5-early-chrome_pid=… ; OK5-connected-still-false.
        #   (After launch + _pool_boot_write_chrome_ids, chrome_pid>0 but connected is still false —
        #    proving the chrome identity lands in the lease at step c, before step f. Reaper-safe.)
  #
  # --- PRIOR-DELIVERABLES regression (must still all be callable) ---
  - RUN:
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 type pool_config_init pool_state_init pool_die _pool_log _pool_now \
                      pool_copy_master pool_find_free_port pool_chrome_launch pool_wait_cdp \
                      pool_daemon_connect pool_daemon_connected pool_chrome_kill \
                      pool_lease_write pool_lease_read pool_lease_field pool_lease_update \
                      _pool_release_lane_internals pool_acquire_locked \
                      pool_boot_lane _pool_launch_and_verify _pool_boot_write_chrome_ids' >/dev/null && echo OK-regression
  - EXPECT: OK-regression (all prior functions + pool_boot_lane + helpers present).
```

### Implementation Patterns & Key Details

```bash
# PATTERN: the recoverable-failure cleanup (research §6). ONE call; no bespoke kill/rm.
#   Works for ALL recoverable paths BECAUSE the early chrome-id write (below) keeps the lease honest.
if ! <non-fatal rc-1 helper>; then
    _pool_log "pool_boot_lane: <reason> for lane $lane; dropping lane"
    _pool_release_lane_internals "$lane"   # kill Chrome (idempotent) + guarded rm dir + delete lease
    return 1
fi

# PATTERN: the LEAK-PREVENTION early chrome-id write (research §2 — the central gotcha).
#   Called right after EACH pool_chrome_launch (incl. the retry). pool_lease_update splices raw JSON.
_pool_boot_write_chrome_ids() {
    local lane="$1"
    pool_lease_update "$lane" chrome_pid "${POOL_CHROME_PID:-0}"
    pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
}

# PATTERN: the launch + CDP-wait + retry-once sub-flow (PRD §2.14).
#   pool_wait_cdp ALREADY kills the pgroup on timeout → no redundant kill; the retry overwrites globals.
_pool_launch_and_verify() {
    local port="$1" ephemeral_dir="$2" lane="$3"
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # 0 or fatal pool_die (instant-exit)
    _pool_boot_write_chrome_ids "$lane"
    pool_wait_cdp "$port" && return 0                      # rc 0 ready
    # rc 1: Chrome pgroup already killed. RETRY ONCE:
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"
    _pool_boot_write_chrome_ids "$lane"
    pool_wait_cdp "$port" && return 0
    return 1                                                # 2nd timeout; Chrome already killed
}

# PATTERN: split every `local` capture (BashFAQ 105 / SC2155). errexit propagates only on the 2nd line.
local port; port="$(pool_find_free_port)"     # rc 1 (exhaustion) now triggers set -e → guard with `if !`
local now;  now="$(_pool_now)"

# PATTERN: pool_lease_update VALUE typing (raw JSON via --argjson inside pool_lease_update).
pool_lease_update "$lane" port         "$port"        # bare number  → 53427
pool_lease_update "$lane" chrome_pid   "${POOL_CHROME_PID:-0}"
pool_lease_update "$lane" chrome_pgid  "${POOL_CHROME_PGID:-0}"
pool_lease_update "$lane" connected    true           # LITERAL "true" (JSON boolean) — NOT 1 / True
pool_lease_update "$lane" last_seen_at "$now"         # bare epoch seconds
```

### Integration Points

```yaml
GLOBALS (read-only):
  - POOL_EPHEMERAL_ROOT: "$HOME/.agent-chrome-profiles/active (copy target + Chrome --user-data-dir = $ROOT/$LANE)."
  - POOL_LANES_DIR:      "$POOL_STATE_DIR/lanes (lease <N>.json — updated via pool_lease_update; deleted on failure)."
  - POOL_REAL_BIN:       "the agent-browser binary (CONNECT subprocess = $BIN --session abpool-<N> connect <port>)."
  - POOL_CHROME_PID/PGID: "set by pool_chrome_launch; read by _pool_boot_write_chrome_ids → written to the lease."

COMPOSED (LANDED — treated as CONTRACT):
  - pool_copy_master:          "step a. reflink CoW copy; pool_die (fatal) on non-btrfs."
  - pool_find_free_port:       "step b. rc 0 echoes port / rc 1 exhausted (non-fatal)."
  - pool_chrome_launch:        "step c. sets globals POOL_CHROME_PID/PGID; pool_die (fatal) on instant-exit."
  - pool_wait_cdp:             "step d. rc 0 ready / rc 1 timeout (KILLS pgroup first). non-fatal."
  - pool_daemon_connect:       "step e. rc 0 bound / rc 1 dead. non-fatal."
  - pool_lease_update:         "steps b/c/f. one top-level field; value = raw JSON; pool_die on missing lease."
  - _pool_release_lane_internals: "ALL recoverable-failure cleanup (reads chrome_id from lease; rc 0 always)."

DOWNSTREAM CONSUMERS (NOT this task's work — documented as contract):
  - M6.T3.S1: "wrapper lifecycle step 3 — after pool_acquire_locked returns provisional lane N
               (port==0), call pool_boot_lane N; on rc 1 retry acquire / M5.T4; on rc 0 exec with
               AGENT_BROWSER_SESSION=abpool-<N>."
  - M5.T1.S3: "ensure_connected — on a Chrome mid-task crash (PRD §2.14), may compose
               _pool_launch_and_verify to relaunch on the same dir+port (profile kept)."
  - M5.T2.S1: "public pool_release_lane composes _pool_release_lane_internals (not this task)."

NO NEW:
  - files: "none (pure append to lib/pool.sh)."
  - env vars: "none."
  - globals: "none exported (reads POOL_* + the chrome globals set by pool_chrome_launch)."
  - leases/migrations: "none (reads/writes the existing PRD §2.8 schema via pool_lease_update)."
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the functions — fix before proceeding.
bash -n lib/pool.sh                       # syntax — MUST be clean
shellcheck lib/pool.sh                    # zero warnings (whole file, incl. the new functions)

# Expected: Zero errors. Watch for SC2155 (declare+assign — split `local x; x=$(…)`) on every
# command-substitution capture (the BashFAQ-105 errexit-masking rule) and SC2084/${var:-} on the
# POOL_CHROME_PID/PGID globals (they may be unset under set -u before any launch). Read any output
# and fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# No bats harness yet (M9.T1.S1). Validate via the SCENARIO blocks in Task 2 — each is a self-contained
# bash -c against an ISOLATED AGENT_BROWSER_POOL_STATE (mktemp -d) + AGENT_CHROME_EPHEMERAL_ROOT, with a
# REAL master/chrome/agent-browser (no mocking needed — verified feasible on this host, research §7).
# The headline scenarios:
#   SCENARIO 1 (happy path, real Chrome) ; SCENARIO 2 (port exhaustion, no Chrome) ;
#   SCENARIO 3 (_pool_launch_and_verify CDP double-timeout, occupied port) ;
#   SCENARIO 4 (daemon connect fail, LIVE Chrome killed — leak proof) ;
#   SCENARIO 5 (early chrome-id write — robustness).
# Re-run any scenario in isolation. Expected: every "OK*" line prints; no "FAIL*" line prints.
# IMPORTANT: every scenario cleans up its Chrome (kill -9 -- -<pgid>; agent-browser close) + rm's the
# temp state/ephemeral dirs so the real pool + real master are never touched.
```

### Level 3: Integration Testing (System Validation)

```bash
# SCENARIO 1 (happy path) + SCENARIO 4 (connect-fail cleanup) ARE the integration tests — they
# exercise the LANDED copy/port/launch/wait/connect/update primitives + the S1 release kernel
# (_pool_release_lane_internals) against a REAL Chrome + REAL daemon. Re-run end-to-end.

# End-to-end with the REAL acquire→boot flow (compose S1 + S2 — the contract the wrapper M6 will use):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
AGENT_BROWSER_POOL_OWNER_PID="$$" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
          local N; N="$(pool_acquire_locked)" || { echo FAIL-acquire; exit 1; }
          echo "acquired provisional lane N=$N"
          pool_boot_lane "$N" && echo "OK-e2e-booted" || echo "FAIL-e2e-boot"
          port="$(pool_lease_field "$N" port)"; conn="$(pool_lease_field "$N" connected)"
          curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK-e2e-cdp" || echo "FAIL-e2e-cdp"
          [[ "$conn" == "true" ]] && echo "OK-e2e-connected" || echo "FAIL-e2e-connected"
          # cleanup:
          cpgid="$(pool_lease_field "$N" chrome_pgid)"; kill -9 -- -"$cpgid" 2>/dev/null || true
          "$POOL_REAL_BIN" --session "abpool-$N" close >/dev/null 2>&1 || true
          rm -f "$POOL_LANES_DIR/$N.json"'
rm -rf "$STATE" "$EPHEM"
# Expected: acquired provisional lane N=1 ; OK-e2e-booted ; OK-e2e-cdp ; OK-e2e-connected.

# Daemon/CLI sanity (the shared daemon is healthy; abpool-* sessions don't disturb others):
~/.local/bin/agent-browser --json session list >/dev/null 2>&1 && echo "OK daemon responds" || echo FAIL
# Expected: OK daemon responds.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# THE critical domain-specific assertions for this task:
#
#  (1) PARALLELISM — pool_boot_lane does NO flocking and NO call into pool_acquire_locked. Prove it:
        grep -nE 'flock|pool_acquire_locked' lib/pool.sh | grep -vE '^[0-9]+:.*M5\.T1\.S1|critical section|pool_acquire_locked\(\)|^.*#'
        # Inspect the new (P1.M5.T1.S2) banner lines: there must be NO `flock` and NO call to
        # pool_acquire_locked inside pool_boot_lane / _pool_launch_and_verify / _pool_boot_write_chrome_ids.
        # Expected: zero matches in the new functions.
#
#  (2) NO `get cdp-url` (the auto-launch trap — P1.M4.T3.S1 research §2): the CONNECT step uses
#      pool_daemon_connect only.
        awk '/# Acquire — post-lock boot \(P1.M5.T1.S2\)/,/^$/' lib/pool.sh | grep -nE 'get[[:space:]]+cdp-url' \
            && echo "FAIL-forbidden-get-cdp-url" || echo "OK-no-get-cdp-url"
        # Expected: OK-no-get-cdp-url.
#
#  (3) LEAK PREVENTION — the early chrome-id write is present after EACH launch in _pool_launch_and_verify.
        # Confirm _pool_boot_write_chrome_ids is called twice in _pool_launch_and_verify (attempt 1 + retry).
        count=$(awk '/_pool_launch_and_verify\(\)/,/^}/' lib/pool.sh | grep -c '_pool_boot_write_chrome_ids')
        [[ "$count" -eq 2 ]] && echo "OK-early-write-x2 ($count)" || echo "FAIL-early-write-count=$count"
        # Expected: OK-early-write-x2 (2).  (This is what makes the step-e cleanup kill the LIVE Chrome.)
#
#  (4) REUSE-ORPHAN NOT DISTURBED — pool_boot_lane is ONLY for provisional (port==0) lanes. It must not
#      be invoked for adopted lanes (port>0); that branching is the wrapper's (M6.T3.S1). Confirm the
#      docstring documents the caller contract (port==0 ⇒ boot). (Read-only check.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean.
- [ ] `shellcheck lib/pool.sh` clean (whole file).
- [ ] All Task 2 scenarios pass (happy path, port exhaustion, CDP double-timeout, connect-fail,
      early chrome-id write).
- [ ] Level 4: no flocking / no `pool_acquire_locked` call in the new functions; no
      `get cdp-url`; early chrome-id write present twice in `_pool_launch_and_verify`.
- [ ] Prior-deliverables regression (Task 2 final RUN) reports OK-regression.

### Feature Validation

- [ ] Happy path: provisional lane → rc 0; lease complete (`port>0, chrome_pid>0, chrome_pgid>0,
      connected:true, last_seen_at=now`); Chrome pgroup alive; CDP answers; `abpool-N` bound.
- [ ] Port exhaustion ⇒ rc 1; no Chrome; dir removed; lease deleted.
- [ ] CDP double-timeout ⇒ rc 1; 0 Chrome pgroups left; dir + lease gone.
- [ ] Daemon-connect fail ⇒ rc 1; the LIVE Chrome killed (no leak); dir + lease gone.
- [ ] Early chrome-id write verified (lease has `chrome_pid>0` before step f; `connected` still false).
- [ ] End-to-end (S1 acquire → S2 boot) works with a real Chrome.
- [ ] No existing function modified (esp. pool_chrome_launch / pool_wait_cdp / pool_daemon_connect /
      pool_lease_update / _pool_release_lane_internals / pool_acquire_locked).

### Code Quality Validation

- [ ] Follows existing patterns (non-fatal rc-returning; `local` first then assign; non-fatal helpers
      guarded with `if !`; cleanup delegated to `_pool_release_lane_internals`; `_pool_log` per phase;
      docstrings with LOGIC + CONSUMER + GOTCHA sections).
- [ ] File placement matches the desired tree (appended after pool_acquire_locked under the new banner).
- [ ] Anti-patterns avoided (no flocking; no `get cdp-url`; no `local x=$(...)`; no bespoke rm/kill in
      the failure paths; no chrome-id write deferred to step f only; no redundant kill after wait_cdp rc 1;
      no attempt to catch the instant-exit pool_die in a subshell).
- [ ] Only POOL_* + chrome globals read; no new globals/env-vars/files.

### Documentation & Deployment

- [ ] Each function has a docstring with LOGIC + CONSUMER + GOTCHA sections (mirrors pool_wait_cdp /
      pool_chrome_launch / pool_acquire_locked).
- [ ] The early-chrome-id-write refinement (vs. the literal contract step-f ordering) is documented in
      the `_pool_boot_write_chrome_ids` + `_pool_launch_and_verify` docstrings (WHY: leak prevention +
      reaper robustness + uniform cleanup).
- [ ] The caller contract (provisional `port==0` ⇒ `pool_boot_lane`; adopted ⇒ skip) is documented in
      the `pool_boot_lane` docstring.
- [ ] `_pool_log` lines are concise (one per boot phase / failure).

---

## Anti-Patterns to Avoid

- ❌ Don't defer the chrome-id write to step f only — a daemon-connect failure (step e) would then
      leave a LIVE Chrome the cleanup cannot kill (it reads `chrome_pid:0` from the lease) → LEAK.
      Write `chrome_pid`/`chrome_pgid` to the lease right after EACH launch (research §2).
- ❌ Don't add a redundant `kill` after a `pool_wait_cdp` rc 1 — `pool_wait_cdp` ALREADY kills the
      chrome pgroup on timeout (research §1.3). The retry just re-launches.
- ❌ Don't try to catch `pool_chrome_launch`'s instant-exit `pool_die` in a subshell — you'd lose the
      `declare -g` globals and leak the Chrome. Let it propagate (it's fatal by design; research §3).
- ❌ Don't flock / don't call `pool_acquire_locked` inside `pool_boot_lane` — the boot runs OUTSIDE the
      lock so concurrent boots parallelize (FINDING 2). The lock is the caller's concern.
- ❌ Don't use `get cdp-url` for the CONNECT step — it auto-launches strays (P1.M4.T3.S1 research §2).
      Use `pool_daemon_connect`.
- ❌ Don't write `local x="$(…)"` — `local` masks errexit (BashFAQ 105). Split into `local x; x="$(…)"`.
- ❌ Don't write your own `kill`/`rm -rf` in the failure paths — delegate to
      `_pool_release_lane_internals "$LANE"` (it has the rm-rf prefix-guard + idempotent kill).
- ❌ Don't pass `1`/`True`/`yes` as the `connected` value to `pool_lease_update` — it splices via
      `--argjson`; use the literal `true` (JSON boolean).
- ❌ Don't reference `$POOL_CHROME_PID`/`$POOL_CHROME_PGID` without `${…:-}` — they may be unset under
      `set -u` before any launch (standalone test).
- ❌ Don't skip writing `port` to the lease at step b — it's the anti-collision mechanism for concurrent
      `pool_find_free_port` calls (research §4).
- ❌ Don't touch any existing function (esp. pool_chrome_launch / pool_wait_cdp / pool_daemon_connect /
      pool_lease_update / _pool_release_lane_internals / pool_acquire_locked).
- ❌ Don't implement ensure_connected (M5.T1.S3), the exhaustion loop (M5.T4), release (M5.T2.S1),
      reap/reuse (M5.T3.*), or the wrapper (M6). This task ships `pool_boot_lane` + its private
      launch/wait helpers ONLY.

---

## Confidence Score

**9/10** for one-pass implementation success.

**Why 9**: every composed function's rc convention is quoted from the ACTUAL `lib/pool.sh` source
(research §1 table: `pool_copy_master` pool_die's on non-btrfs; `pool_find_free_port` rc 1 non-fatal
exhaustion; `pool_chrome_launch` sets globals + pool_die's on instant-exit; `pool_wait_cdp` rc 1 AND
kills the pgroup; `pool_daemon_connect` rc 0/1 non-fatal; `pool_lease_update` top-level + raw-JSON value
+ pool_die on missing lease; `_pool_release_lane_internals` reads chrome_id from the lease + rc 0
always). THE central leak gotcha (chrome identity in globals vs lease during boot → the early-write
mandate) is spelled out with the exact failure table (research §2) and a dedicated leak-proof test
(Scenario 4: `AGENT_BROWSER_REAL=/nonexistent` → LIVE Chrome killed, no leak). The retry flow is
correct precisely because `pool_wait_cdp`'s kills-on-timeout behavior is documented (research §1.3) —
the retry needs no redundant kill. The instant-exit-is-fatal decision is justified (can't catch
pool_die without losing the `declare -g` globals; research §3). The cleanup-via-
`_pool_release_lane_internals` is uniformly correct BECAUSE of the early write (research §6 table:
all three failure paths clean). Host facts (master 4.8 GB on btrfs, chrome, agent-browser, daemon)
are VERIFIED this session, and every test scenario is feasible on this host with NO mocking (research
§7). The end-to-end S1-acquire→S2-boot integration test is included.

**Why not 10**: (1) Scenario 3 (CDP double-timeout) exercises `_pool_launch_and_verify` directly
rather than the full `pool_boot_lane` path — `pool_find_free_port`'s curl probe may reject an
occupied port before launch reaches `_pool_launch_and_verify`, making the full-path timeout hard to
force deterministically; the retry kernel itself is tested, but the `pool_boot_lane`→helper
delegation for that branch is validated by code inspection (Level 4) + the helper test. (2) The
happy-path Chrome boot is real (~5–10 s, windowed headless on this btrfs host) — reliable but
inherently timing-sensitive; a flaky first boot is caught by the retry, and a flaky second boot
correctly drops the lane (rc 1), which is the designed behavior. (3) `_pool_boot_write_chrome_ids`
passes `${POOL_CHROME_PID:-0}` as the value — if `pool_chrome_launch` ever failed to set the global
on a partial-success edge (not observed in the M4.T2.S2 source), the lease would store `chrome_pid:0`
and the step-e cleanup would revert to the leak; this is guarded by `pool_chrome_launch`'s own
pool_die-on-empty-pgid (it never returns 0 without both globals set), so it cannot occur in practice.
