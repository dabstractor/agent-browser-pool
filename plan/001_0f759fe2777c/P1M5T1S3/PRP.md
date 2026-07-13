# PRP — P1.M5.T1.S3: `pool_ensure_connected` — reconnect logic for subsequent calls

---

## Goal

**Feature Goal**: Implement **`pool_ensure_connected(lane)`** — the **ENSURE-CONNECTED**
step of the agent-browser-pool request lifecycle (PRD §2.4 step 4). It is the function the
wrapper runs on **every subsequent DRIVING call** after the first cold boot, to make sure a
lane that *was* drivable a moment ago *still is*. It is the literal realization of the item
CONTRACT steps a–d + PRD §2.4 step 4 + §2.14 (failure modes & recovery, esp. the "Chrome
crash mid-task → relaunch on same dir+port, reconnect, keep lease" row).

The function implements the CONTRACT verbatim:
**a.** read the lease → `session`, `port`, `chrome_pid`, `ephemeral_dir`;
**b.** if `pool_daemon_connected(session, port)` (the SIDE-EFFECT-FREE, stray-free `get
cdp-url` REPLACEMENT) → touch `last_seen_at`, return 0;
**c.** else (not connected) decide **reconnect vs relaunch** by whether the pooled Chrome is
still alive:
&nbsp;&nbsp;&nbsp;&nbsp;• Chrome **alive** (`curl /json/version` answers — see §"Known
Gotchas" for why NOT `kill -0`) → `pool_daemon_connect(session, port)` (re-bind the daemon);
return 0/1;
&nbsp;&nbsp;&nbsp;&nbsp;• Chrome **dead** → **relaunch** Chrome on the SAME dir+port
(`rm -f Singleton*` + `pool_chrome_launch` + early-write chrome-ids + `pool_wait_cdp` +
`pool_daemon_connect`), update lease `chrome_pid`/`chrome_pgid`, return 0/1;
**d.** touch the lease `last_seen_at` (observability) on every path.

**Deliverable**: One PUBLIC function `pool_ensure_connected(LANE)`, appended to `lib/pool.sh`
under a new banner **after `pool_boot_lane`** (the P1.M5.T1.S2 deliverable, current EOF
@2238). **Pure addition: no edits to any existing function, no new env-vars, no new files,
no private helpers** (the body is short + linear — the relaunch sub-flow is inlined). Reads
the lease (via `pool_lease_read`/`pool_lease_field`), the `POOL_EPHEMERAL_ROOT` /
`POOL_LANES_DIR` globals, and the `POOL_CHROME_PID`/`POOL_CHROME_PGID` globals set by
`pool_chrome_launch`.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, given a
  **fully-booted** lane 1 (written by `pool_boot_lane`: `port>0, chrome_pid>0,
  chrome_pgid>0, connected:true`), calling `pool_ensure_connected 1` returns **0**, the lease
  `last_seen_at` is updated to now, and the Chrome pgroup + daemon binding are unchanged.
- **Reconnect path**: after killing only the **daemon binding** (e.g. via `agent-browser
  --session abpool-1 close`) while the **Chrome stays alive** (CDP still answers), calling
  `pool_ensure_connected 1` returns **0**, `connected` is `true`, `last_seen_at` is now, the
  **same Chrome pid** survives (no new Chrome spawned), and `abpool-1` is re-bound to the
  daemon.
- **Relaunch path**: after killing the **Chrome pgroup** (`kill -9 -- -<pgid>`) so CDP no
  longer answers, calling `pool_ensure_connected 1` returns **0**, a **NEW Chrome** is
  running on the **same port + same ephemeral dir**, the lease `chrome_pid`/`chrome_pgid`
  are updated to the new Chrome, `connected` is `true`, `last_seen_at` is now, and `abpool-1`
  is bound to the new Chrome. (Open tabs lost; profile kept — PRD §2.14.)
- **Failure — relaunch CDP timeout**: with the selected port occupied so the relaunched
  Chrome's debug port can't bind, `pool_ensure_connected 1` returns **1**, `connected` is
  `false`, the relaunched Chrome pgroup is killed (by `pool_wait_cdp`), and the lane is NOT
  dropped (the lease file still exists — the wrapper/reaper owns teardown).
- **Failure — unbooted lane (port:0)**: `pool_ensure_connected 1` on a provisional lane
  (port:0, not yet booted) returns **1** early (defensive — S2's job, not ours).
- **Lease missing/corrupt**: `pool_ensure_connected 99` (no `lanes/99.json`) returns **1**
  (non-fatal; never `pool_die`).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M5.T1.S2) unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its sole consumer is the
**wrapper request lifecycle** (PRD §2.4 step 4):

- **M6.T3.S1** (wrapper lifecycle step 4) — the IMMEDIATE driver. After the wrapper resolves
  its owner + finds/acquires a lane (steps 1–3), it calls `pool_ensure_connected "$N"` BEFORE
  exec'ing the real binary. This runs on **every DRIVING invocation** (open/click/type/…), so
  it is the **HOT PATH** — the common case (lane already connected) must be fast (~1 curl +
  ~1 jq + 2 atomic lease touches).
- It runs on BOTH (a) reused previously-booted lanes (the steady state — every call after the
  first cold boot) AND (b) S1 reuse-orphan **adopted** lanes (which the wrapper routes to
  ensure_connected instead of pool_boot_lane, per S2's caller contract).

**Use Case**: A pi agent makes its 2nd, 3rd, … `agent-browser open …` call in a task. The
wrapper finds its lease (lane N), then calls `pool_ensure_connected "$N"`. In the common
case the lane is still connected → ~instant, exec proceeds. If the daemon died (Chrome
still alive) → reconnect (~ms). If Chrome crashed mid-task → relaunch on the same dir+port
(~5 s, once), keeping the authenticated profile (PRD §2.14). The agent never sees this — it
just gets a working browser.

**Pain Points Addressed**:
- **The daemon can die between calls** (idle timeout, crash). Without ensure_connected the
  next drive would fail opaquely. ensure_connected re-binds transparently.
- **Chrome can crash mid-task** (OOM, segfault, user kill). The pool must recover WITHOUT
  losing the authenticated profile or the lease — relaunch on the same dir+port (PRD §2.14).
- **The literal PRD §2.4 step 4 `get cdp-url || connect` is BROKEN** on agent-browser 0.28.0
  (P1.M4.T3.S1 research §2: `get cdp-url` always rc 0 + auto-launches STRAY Chromes on a
  dead-chrome session). ensure_connected uses the SIDE-EFFECT-FREE `pool_daemon_connected`
  + `curl /json/version` instead — never a stray.

## Why

- **This IS PRD §2.4 step 4 (ENSURE CONNECTED).** Without it, the 2nd+ call of a task has no
  guarantee the lane is still drivable — the daemon may have exited (idle timeout) or Chrome
  may have crashed. ensure_connected is the transparent self-heal.
- **PRD §2.14 "Chrome crash mid-task" recovery is owned here.** "relaunch on same dir+port,
  reconnect, keep lease (open tabs lost; profile kept)" is literally the relaunch branch of
  this function.
- **The `get cdp-url` auto-launch trap is defeated here.** P1.M4.T3.S1 research §2 proved
  the literal `get cdp-url` probe is catastrophic (always rc 0 + leaks strays). This
  function is the FIRST consumer of the corrective `pool_daemon_connected` primitive, and it
  establishes the safe `pool_daemon_connected || <reconnect/relaunch>` orchestration the
  whole pool will follow.
- **The hot path must stay cheap.** The connected-check is two side-effect-free probes
  (`session list` jq + `curl`); the touch is two atomic lease updates. No Chrome work on the
  happy path.

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| booted lane 1, Chrome alive, daemon bound | `pool_ensure_connected 1` | **rc 0**; `last_seen_at`=now; Chrome + daemon unchanged; no new Chrome |
| daemon binding lost (close), Chrome STILL ALIVE (CDP answers) | `pool_ensure_connected 1` | **rc 0**; `connected:true`; SAME chrome_pid (no relaunch); `abpool-1` re-bound; `last_seen_at`=now |
| Chrome CRASHED (CDP dead), dir+port reusable | `pool_ensure_connected 1` | **rc 0**; NEW chrome on SAME port + SAME dir; lease chrome_pid/pgid updated; `connected:true`; `last_seen_at`=now |
| relaunched Chrome can't bind debug port (port occupied) → CDP timeout | `pool_ensure_connected 1` | **rc 1**; relaunched Chrome killed (by wait_cdp); `connected:false`; lease NOT deleted |
| Chrome relaunched + CDP ready, but `pool_daemon_connect` rc 1 | `pool_ensure_connected 1` | **rc 1**; live Chrome left running (no leak-kill by ensure_connected); `connected:false` |
| `pool_chrome_launch` instant-exits (broken binary) on relaunch | `pool_ensure_connected 1` | **pool_die propagates** (fatal — genuine misconfiguration) |
| provisional lane (port:0, not booted) | `pool_ensure_connected 1` | **rc 1** early (defensive — S2's job) |
| lease missing/corrupt (no lanes/99.json) | `pool_ensure_connected 99` | **rc 1** (non-fatal; never pool_die) |

**Hard invariants** (every row):
- **`pool_ensure_connected` NEVER drops the lane.** On any failure it returns 1 and leaves
  the lease + (possibly-dead) Chrome as-is. Dropping the lane (`_pool_release_lane_internals`)
  is the wrapper's (M6) / reaper's (M5.T3) concern, NOT this function's. (Contract: "Returns
  0 if lane is connected …, 1 on failure.")
- **`get cdp-url` is FORBIDDEN.** The connected check is `pool_daemon_connected(session,
  port)` (SIDE-EFFECT-FREE; P1.M4.T3.S1 research §2). The Chrome-aliveness sub-check is
  `curl -sf /json/version` (NOT `kill -0` — see §"Known Gotchas").
- **`pool_chrome_launch` pool_die is FATAL and propagates** (instant-exit = genuine Chrome
  misconfiguration). It is NOT caught/retried. The contract's "Return 0/1" covers the
  CDP-timeout + connect-fail paths, NOT instant-exit.
- **The relaunch is a SINGLE attempt.** On `pool_wait_cdp` timeout (rc 1, Chrome pgroup
  already killed by wait_cdp), ensure_connected returns 1. No retry (the literal contract;
  the wrapper can re-invoke).
- **chrome_pid/chrome_pgid are written to the lease IMMEDIATELY after relaunch-launch**
  (before `pool_wait_cdp`) — reaper-safe (S2 §2 leak-prevention, ported here).
- **The relaunch happens on the SAME ephemeral_dir + SAME port** (read from the lease), with
  the stale `Singleton{Lock,Cookie,Socket}` removed first (matches `pool_copy_master` /
  PRD §2.7; eliminates the PID-recycle false-alive edge case).
- **`last_seen_at` is touched on EVERY path** (success + failure) — it is an observability
  heartbeat (PRD §2.4 step 4 "touch lease mtime"), NOT a staleness gate (the reaper uses
  owner-liveness, `pool_lane_is_stale`, not `last_seen_at`).
- **`connected` is set `true` on success, `false` on the relaunch/connect FAILURE paths**
  (truthful — the Chrome is dead/broken). On the already-connected happy path `connected` is
  already `true` (no write needed — only `last_seen_at` is touched).
- **Every `local` capture is split** (`local X; X="$(…)"` — BashFAQ 105 / SC2155) and every
  non-fatal rc-1 helper (`pool_lease_read`, `pool_daemon_connected`, `pool_daemon_connect`,
  `pool_wait_cdp`) is guarded with `if …; then …; else …; fi`.

### Success Criteria

- [ ] `pool_ensure_connected` defined in `lib/pool.sh` under a
      `# Acquire — ensure connected (P1.M5.T1.S3)` banner, appended after `pool_boot_lane`.
      Callable after `source lib/pool.sh` + `pool_config_init`.
- [ ] Happy path: booted lane → rc 0; `last_seen_at` updated; Chrome + daemon unchanged.
- [ ] Reconnect path: daemon binding killed, Chrome alive → rc 0; SAME chrome_pid;
      `connected:true`; `abpool-1` re-bound.
- [ ] Relaunch path: Chrome killed → rc 0; NEW chrome on SAME port + dir; lease
      chrome_pid/pgid updated; `connected:true`.
- [ ] Relaunch CDP-timeout failure → rc 1; relaunched Chrome killed; `connected:false`;
      lease NOT deleted.
- [ ] Provisional/unbooted lane (port:0) → rc 1 early.
- [ ] Missing/corrupt lease → rc 1 (non-fatal).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1–M5.T1.S2) unchanged and callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **composed-function contract
table** (research §1 — exact rc conventions for all LANDED helpers, quoted from the
`lib/pool.sh` source); the **THE liveness-check decision** (research §2 — why `curl
/json/version` not `kill -0`: ESRCH/EPERM conflation + PID-recycling + CDP-readiness; with
kill(2) + Puppeteer/Playwright/chrome-remote-interface + CDP-spec URLs); the **Singleton
cleanup before relaunch** (research §3 — why `rm -f Singleton*` matches pool_copy_master and
defeats the PID-recycle false-alive); the **`get cdp-url` AUTO-LAUNCH trap** (P1.M4.T3.S1
research §2 — why `pool_daemon_connected` is the only safe probe); the **early chrome-id
write** (research §5 — reaper-safe, ported from S2); the **full decision-flow pseudocode**
(research §4); the **`set -e` + `local var=$(...)` masking gotcha**; the **S2 caller
contract** (the booted-lane input state); the **PRD §2.8 lease schema**; and copy-pasteable,
host-verified validation commands (a real-Chrome happy path, a daemon-close reconnect test,
a Chrome-kill relaunch test, and an occupied-port CDP-timeout test).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 4 (ENSURE CONNECTED: "agent-browser --session abpool-<N> get cdp-url
        >/dev/null 2>&1 || connect <port>"; touch lease mtime) — NOTE: the literal get cdp-url
        is BROKEN on 0.28.0 (see P1.M4.T3.S1); this function uses pool_daemon_connected.
        §2.14 (failure modes & recovery — the "Chrome crash mid-task → relaunch on same
        dir+port, reconnect, keep lease (open tabs lost; profile kept)" row IS the relaunch
        branch). §2.8 (lease schema — the fields read/written).
  pattern: step 4 IS pool_ensure_connected; §2.14 "Chrome crash mid-task" IS the relaunch.
  gotcha: §2.4 step 4's literal get cdp-url AUTO-LAUNCHES strays (always rc 0) — use
        pool_daemon_connected (the side-effect-free REPLACEMENT). And the literal "kill -0
        $chrome_pid" in the item CONTRACT is a trap — use curl /json/version (research §2).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 3 (no bare ~ — POOL_EPHEMERAL_ROOT is absolute via pool_config_init; the
        relaunch --user-data-dir MUST be absolute); FINDING 6 (setsid → pgid==pid; the
        relaunch Chrome's pgroup teardown if wait_cdp times out); FINDING 7 (atomic lease
        write: tmp in SAME dir + mv — pool_lease_update does this internally).
  pattern: FINDING 6 ⇒ the relaunched chrome pgroup is correctly signalled by pool_wait_cdp.

- file: plan/001_0f759fe2777c/P1M4T3S1/research/daemon-connect-teardown-host-verified.md
  why: §2 (THE get cdp-url AUTO-LAUNCH TRAP — why pool_daemon_connected exists with the
        session+port signature); §6 (the side-effect-free connected probe design:
        session-list jq + curl /json/version); §1 (pool_daemon_connect is idempotent/
        re-bindable — safe to call speculatively in the reconnect path); §4 (curl /json/version
        is the side-effect-free CHROME probe). HOST-VERIFIED on agent-browser 0.28.0.
  pattern: §6 IS the connected check; §1 IS the reconnect; §4 IS the liveness sub-check.

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M5T1S3/research/ensure-connected-reconnect-relaunch.md
  why: §0 (the S2 booted-lane INPUT state this task ensures); §1 (the composed-function rc
        TABLE, quoted from lib/pool.sh source); §2 (THE liveness decision — curl not kill -0,
        with kill(2)/Puppeteer/Playwright/CDP-spec URLs); §3 (Singleton cleanup before
        relaunch); §4 (the full decision-flow pseudocode); §5 (early chrome-id write); §6
        (set -e gotchas + naming/placement/scope); §7 (why inline single relaunch, not
        S2's _pool_launch_and_verify); §8 (decisions summary).
  pattern: §4 IS the implementation spine; §1 IS the contract table.
  gotcha: §2 (curl not kill -0) + §3 (Singleton cleanup) + §5 (early chrome-id write) are
        the three highest-impact gotchas.

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M4T3S1/PRP.md   # pool_daemon_connect + pool_daemon_connected (M4.T3.S1 — LANDED @1631/~1700)
  why: the two PRIMITIVES this task orchestrates. pool_daemon_connected(session, port): rc 0
        connected / 1 not; SIDE-EFFECT-FREE; NEVER launches (the get cdp-url REPLACEMENT).
        pool_daemon_connect(session, port): subprocess rc 0 bound / 1 dead; NON-FATAL;
        idempotent/re-bindable (re-running connect on an already-bound session + same-live-port
        returns rc 0 — safe in the reconnect path).
- file: plan/001_0f759fe2777c/P1M4T2S2/PRP.md   # pool_chrome_launch + pool_wait_cdp (M4.T2.S2 — LANDED @1471/1570)
  why: the relaunch primitives. pool_chrome_launch(port, udd, lane): sets globals
        POOL_CHROME_PID=$! / POOL_CHROME_PGID via declare -g; returns 0 or pool_die's on
        INSTANT exit (fatal). pool_wait_cdp(port): curls /json/version up to 60×0.5s; rc 0
        ready; rc 1 timeout AND KILLS the chrome pgroup BEFORE returning 1. NON-FATAL.
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_read + pool_lease_field (M3.T1.S2 — LANDED)
  why: read the lease → session/port/chrome_pid/ephemeral_dir. pool_lease_read echoes JSON /
        rc 0 (rc 1 missing/corrupt); pool_lease_field echoes a (dotted) field value / rc 0
        (rc 1 missing/corrupt). BOTH non-fatal — caller MUST guard under set -e.
- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md   # pool_lease_update (M3.T1.S1 — LANDED @763)
  why: touch last_seen_at + set connected/chrome_pid/chrome_pgid. pool_lease_update(lane,
        field, value): sets ONE top-level field; value spliced as raw JSON (--argjson) →
        numbers / true / false / "quoted-str". pool_die's on missing/corrupt lease or
        non-JSON value. `connected` MUST be literal `true`/`false`.
- file: plan/001_0f759fe2777c/P1M4T1S1/PRP.md   # pool_copy_master (M4.T1.S1 — LANDED @1253)
  why: the Singleton-cleanup PATTERN to mirror in the relaunch: `rm -f "$dir/SingletonLock"
        "$dir/SingletonCookie" "$dir/SingletonSocket"`. (Do NOT re-copy on relaunch — the
        profile is KEPT per PRD §2.14; only the 3 singleton artifacts are removed.)

# External authoritative docs (for the WHY; behavior is HOST-VERIFIED in research §1/§2/§3)
- url: https://man7.org/linux/man-pages/man2/kill.2.html
  why: kill(2) signal-0 semantics — ESRCH (no such process) vs EPERM (exists, no permission).
        The shell's `kill -0` returns exit-code 1 for BOTH (indistinguishable) → a live
        foreign Chrome looks dead. THIS is why ensure_connected uses curl, not kill -0.
  section: DESCRIPTION + ERRORS (ESRCH / EPERM).
- url: https://chromedevtools.github.io/devtools-protocol/
  why: /json/version is the standard CDP discovery/health endpoint; a 200 response includes
        webSocketDebuggerUrl, proving the ENTIRE CDP stack is up. This is the idiomatic,
        side-effect-free "Chrome alive + ready" check used by the whole codebase.
  section: "HTTP Endpoints" (/json/version).
- url: https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/process_singleton/process_singleton_posix.cc
  why: SingletonLock is a symlink encoding <hostname>-<pid>; Chrome reads it + kill(pid,0) on
        launch; if the pid is DEAD it auto-recovers (unlink + re-take). BUT PID-recycling can
        make a dead Chrome's pid look alive → the relaunch EXITS without binding (the
        single-instance guard). Removing Singleton* before relaunch is the deterministic fix.
```

### Current Codebase tree

After **M1–M5.T1.S2** have landed, `lib/pool.sh` (2238 lines) ends with `pool_boot_lane`
as the final function (@2185):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T1.S2) with pool_boot_lane at EOF.
│                                         #   Banner order at EOF:
│                                         #   ... pool_chrome_launch + pool_wait_cdp (M4.T2.S2)
│                                         #   # Lane lifecycle — daemon connect, verify & teardown (M4.T3.S1)
│                                         #   pool_daemon_connect / pool_daemon_connected / pool_chrome_kill
│                                         #   # Acquire — flock critical section (M5.T1.S1)
│                                         #   _pool_release_lane_internals / _pool_adopt_lane
│                                         #   / _pool_acquire_critical_section / pool_acquire_locked
│                                         #   # Acquire — post-lock boot (M5.T1.S2)
│                                         #   _pool_boot_write_chrome_ids / _pool_launch_and_verify / pool_boot_lane  ← current EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T1S2/PRP.md
    └── P1M5T1S3/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/ensure-connected-reconnect-relaunch.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND ONE function under a new banner AFTER pool_boot_lane (EOF):
                  #   # Acquire — ensure connected (P1.M5.T1.S3)
                  #   pool_ensure_connected(lane):   # PUBLIC — the CONTRACT name
                  #       read lease → session, port, ephemeral_dir (+ chrome_pid)
                  #         lease missing/corrupt OR port<=0 → return 1
                  #       (b) pool_daemon_connected(session, port):
                  #              rc 0 → touch last_seen_at → return 0
                  #       (c) curl /json/version on port (Chrome alive?):
                  #            ALIVE → pool_daemon_connect(session,port):
                  #                       rc 0 → connected=true + last_seen_at → return 0
                  #                       rc 1 → last_seen_at → return 1
                  #            DEAD  → rm -f Singleton* in ephemeral_dir
                  #                     pool_chrome_launch(port, ephemeral_dir, lane)  [fatal pool_die ok]
                  #                     pool_lease_update chrome_pid/pgid (early write)
                  #                     pool_wait_cdp(port): rc 1 → connected=false + last_seen_at → return 1
                  #                     pool_daemon_connect(session,port): rc 1 → connected=false + last_seen_at → return 1
                  #                     connected=true + last_seen_at → return 0
                  #   (NO changes to any existing function — esp. NOT pool_daemon_connected /
                  #    pool_daemon_connect / pool_chrome_launch / pool_wait_cdp / pool_lease_update)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **ensure-connected** step (PRD §2.4 step 4) — the per-invocation self-heal that verifies
a booted lane is still drivable, reconnecting the daemon or relaunching Chrome on the same
dir+port as needed. It reads `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`, and the
`POOL_CHROME_PID`/`POOL_CHROME_PGID` globals; it writes only the lease (via
`pool_lease_update`) and (on relaunch) launches a Chrome (via `pool_chrome_launch`) on the
existing ephemeral dir. It never drops the lane.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (THE LIVENESS-CHECK DECISION — research §2): the item CONTRACT literally says
#   "check if Chrome is still alive (kill -0 $chrome_pid)". DO NOT USE kill -0. Use:
#       curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1
#   kill -0 is a TRAP: (1) kill(2) signal-0 returns exit-code 1 for BOTH ESRCH (dead) AND
#   EPERM (alive but not yours) — indistinguishable in the shell; (2) it is vulnerable to PID
#   recycling (a dead Chrome's pid recycled into a live process → kill -0 says "alive"); (3) it
#   says NOTHING about CDP readiness (Chrome alive but wedged / still booting / port not bound).
#   curl returns 0 ONLY when Chrome's DevTools HTTP server is fully up (the response includes
#   webSocketDebuggerUrl). curl is the IDIOMATIC check the codebase uses EVERYWHERE
#   (pool_wait_cdp, pool_daemon_connected, pool_find_free_port) and the industry standard
#   (Puppeteer/Playwright/chrome-remote-interface). This is a deliberate deviation from the
#   literal contract in service of its INTENT ("is Chrome alive and drivable?"). HOST-VERIFIED.

# CRITICAL (get cdp-url is FORBIDDEN — P1.M4.T3.S1 research §2): the literal PRD §2.4 step 4
#   `get cdp-url` AUTO-LAUNCHES a STRAY Chrome on a dead-chrome session (always rc 0) — it can
#   NEVER report "not connected" AND it leaks strays. Use pool_daemon_connected(session, port)
#   (SIDE-EFFECT-FREE, the deliberate REPLACEMENT) as the connected check. NEVER raw get cdp-url.

# CRITICAL (pool_daemon_connected takes TWO args — session AND port): the LANDED signature is
#   pool_daemon_connected "$session" "$port" (NOT session-only as the literal contract step b
#   implies). The port was ADDED because the only stray-free chrome-liveness signal is curl on
#   the port. P1.M4.T3.S1 research §6.

# CRITICAL (pool_wait_cdp KILLS the chrome pgroup on timeout — research §1.4 / S2 §1.3): on rc 1
#   the relaunched Chrome is ALREADY DEAD (kill -- -"$POOL_CHROME_PGID"). So after a wait_cdp
#   rc 1 in the relaunch path, do NOT add a redundant kill — just set connected:false, touch
#   last_seen_at, return 1. The Chrome is gone.

# CRITICAL (pool_chrome_launch pool_die is FATAL, NOT retryable — research §1.3 / S2 §1.2):
#   pool_chrome_launch calls pool_die (exit 1) if Chrome dies before its pgroup can be read.
#   This propagates out of pool_ensure_connected (NOT catchable without a subshell, which would
#   lose the declare -g globals + leak the Chrome). Let it propagate — it is a genuine Chrome
#   misconfiguration (broken binary / bad flags). The contract's "Return 0/1" covers the
#   CDP-timeout + connect-fail paths, NOT instant-exit.

# CRITICAL (`local var=$(...)` masks errexit — research §6 / BashFAQ 105 / SC2155): `local X="$(…)"`
#   — local returns 0 always, so set -e does NOT fire on a failing $(…). EVERY capture MUST be split:
#       local json; json="$(pool_lease_read "$lane" 2>/dev/null)"
#       local now; now="$(_pool_now)"
#   Applies to pool_lease_read, pool_lease_field, _pool_now. (curl/pool_daemon_* are commands —
#   guard with `if …; then …`, not captures.)

# CRITICAL (non-fatal rc-1 helpers MUST be guarded under set -e): pool_lease_read,
#   pool_daemon_connected, pool_daemon_connect, pool_wait_cdp all return 1 on a RECOVERABLE
#   failure. A BARE call ABORTS the caller. Use `if …; then …; else …; return 1; fi`.

# CRITICAL (early chrome-id write — research §5, ported from S2 §2): on the relaunch path,
#   write chrome_pid/chrome_pgid to the lease IMMEDIATELY after pool_chrome_launch (BEFORE
#   pool_wait_cdp). Reason: (1) if wait_cdp times out (kills the pgroup), the lease then holds
#   the dead-but-correct pid (the reaper's _pool_release_lane_internals reads the lease +
#   idempotently kills); (2) if ensure_connected is SIGKILL'd mid-relaunch, the lazy reaper
#   reads the lease and tears the relaunch-Chrome down (impossible if chrome_pid were stale).
#   The globals are the NEW Chrome's identity (pool_chrome_launch overwrote them).

# CRITICAL (Singleton cleanup BEFORE relaunch — research §3): Chrome's SingletonLock is a
#   symlink encoding <hostname>-<pid>; on relaunch Chrome kill(pid,0)'s it and auto-recovers if
#   dead — BUT PID-recycling can make a dead Chrome's pid look alive → the relaunch EXITS without
#   binding (single-instance guard) → wait_cdp times out → spurious failure. FIX:
#       rm -f -- "$ephemeral_dir/SingletonLock" "$ephemeral_dir/SingletonCookie" "$ephemeral_dir/SingletonSocket"
#   BEFORE pool_chrome_launch — matches pool_copy_master (M4.T1.S1, line ~460) + Puppeteer/
#   Playwright/Selenium. Only the 3 singleton artifacts (SingletonSocket is AF_UNIX; rm -f OK);
#   do NOT rm the dir (the profile is KEPT per PRD §2.14). Safe: we reach here only AFTER curl
#   proved the Chrome is dead.

# GOTCHA (ensure_connected NEVER drops the lane): on failure, return 1 and leave the lease +
#   (possibly-dead) Chrome as-is. Do NOT call _pool_release_lane_internals here. Dropping is the
#   wrapper's (M6) / reaper's (M5.T3) job. (Contract: "Returns 0 …, 1 on failure.")

# GOTCHA (the relaunch is a SINGLE attempt): no retry. On pool_wait_cdp rc 1 → connected:false,
#   touch last_seen_at, return 1. The literal contract is "pool_chrome_launch. pool_wait_cdp.
#   pool_daemon_connect. Update lease. Return 0/1." — one pass. (PRD §2.14 "retry launch once" is
#   the COLD-BOOT policy in S2's _pool_launch_and_verify, not the relaunch policy here. The
#   wrapper can re-invoke ensure_connected if it wants another shot.)

# GOTCHA (pool_lease_update VALUE typing): value is spliced as raw JSON via --argjson. So
#   last_seen_at / chrome_pid / chrome_pgid are bare digits; connected MUST be the literal
#   string "true" or "false" (not "1"/"True"/"yes"). A non-JSON value → jq exit 2 → pool_die.

# GOTCHA (pool_lease_update is TOP-LEVEL ONLY + pool_die's on missing/corrupt lease): fine here —
#   the lease exists (S1+S2 wrote it). last_seen_at / connected / chrome_pid / chrome_pgid are
#   all TOP-LEVEL fields (PRD §2.8). A missing/corrupt lease → pool_die (exceptional; the lane is
#   already broken) — but we pre-guard with pool_lease_read (return 1) before any update.

# GOTCHA (POOL_CHROME_PID/PGID may be UNSET under set -u): before any relaunch, the globals may
#   be unset (or hold a STALE value from a prior launch). Reference them as ${POOL_CHROME_PID:-0}
#   / ${POOL_CHROME_PGID:-0} in the chrome-id write (default-expansion). After a successful
#   pool_chrome_launch they ARE set to the new Chrome's identity. pool_lease_update accepts 0.

# GOTCHA (ephemeral_dir for the relaunch — ABSOLUTE + reconstruct defensively): read it from the
#   lease (.ephemeral_dir); if missing/relative, RECONSTRUCT as "$POOL_EPHEMERAL_ROOT/$lane"
#   (matches _pool_release_lane_internals' defensive reconstruction). pool_chrome_launch requires
#   an ABSOLUTE --user-data-dir (PRD §2.2). $POOL_EPHEMERAL_ROOT is frozen absolute by pool_config_init.

# GOTCHA (session is "abpool-<LANE>" — reconstruct, do NOT trust a stale lease field if it's
#   empty): read .session from the lease; if missing, reconstruct as "abpool-$lane". The session
#   name is deterministic from the lane number.

# GOTCHA (connected field on the happy path): when pool_daemon_connected returns 0, connected is
#   ALREADY true (the lane was booted/adopted) — do NOT re-write it (only touch last_seen_at).
#   Only the reconnect/relaunch SUCCESS paths write connected:true; the FAILURE paths write
#   connected:false (truthful).

# GOTCHA (naming + placement): pool_ensure_connected (PUBLIC, CONTRACT name, no `_`). NO private
#   helpers (the body is short + linear). APPEND at EOF after pool_boot_lane. Do NOT touch any
#   existing function.

# GOTCHA (scope — ensure_connected ONLY): do NOT implement the wrapper (M6.T3.S1); do NOT drop/
#   release the lane (M5.T2.S1 / M5.T3); do NOT retry the relaunch; do NOT touch the owner sub-
#   object. This task ships pool_ensure_connected ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**.
It reads the lease schema (PRD §2.8, frozen by M3.T1.S1) and updates top-level fields via the
LANDED `pool_lease_update`. It READS the `POOL_CHROME_PID`/`POOL_CHROME_PGID` globals (set by
`pool_chrome_launch` during the relaunch) and writes them into the lease.

Global READ (frozen by `pool_config_init`; chrome globals set by `pool_chrome_launch`):

| global | source | example | role |
|---|---|---|---|
| `POOL_EPHEMERAL_ROOT` | pool_config_init | `/home/dustin/.agent-chrome-profiles/active` | relaunch `--user-data-dir` = `$ROOT/$LANE` (the dir is KEPT; only Singleton* removed) |
| `POOL_LANES_DIR` | pool_config_init | `…/agent-browser-pool/lanes` | lease `<N>.json` (read via pool_lease_read/field; updated via pool_lease_update) |
| `POOL_CHROME_PID` | pool_chrome_launch (relaunch) | `104816` | written to lease `.chrome_pid` (early write, before wait_cdp) |
| `POOL_CHROME_PGID` | pool_chrome_launch (relaunch) | `104816` | written to lease `.chrome_pgid` (early write, before wait_cdp) |

External commands (verified present this session): `curl` (the liveness probe + used by
pool_daemon_connected/pool_wait_cdp), `rm` (Singleton cleanup), `google-chrome-stable` +
`setsid` (via `pool_chrome_launch`), `agent-browser` (via `pool_daemon_connect`/`connected`),
`jq` (via `pool_lease_read`/`pool_lease_update`). All present on host.

**Naming** (CONTRACT-mandated + codebase convention): `pool_ensure_connected` (public,
CONTRACT name). **No private helpers** — the decision tree is short + linear; fragmenting it
into `_pool_*` helpers would hurt readability.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init \
                  pool_lease_read pool_lease_field pool_lease_update _pool_now \
                  pool_daemon_connect pool_daemon_connected \
                  pool_chrome_launch pool_wait_cdp'
  - EXPECT: all reported as functions (M1–M5.T1.S2 LANDED). If any MISSING → STOP.
  - RUN (verify the globals + host facts this task depends on):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_EPHEMERAL_ROOT" && -n "$POOL_LANES_DIR" ]] \
                   && echo "OK globals" || echo FAIL'
        command -v google-chrome-stable >/dev/null && echo "OK chrome" || echo FAIL
        command -v curl >/dev/null && echo "OK curl" || echo FAIL
        [[ -d "$HOME/.agent-chrome-profiles/master-profile" ]] && echo "OK master" || echo FAIL
        findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles" | grep -q btrfs && echo "OK btrfs" || echo FAIL
  - EXPECT: OK globals ; OK chrome ; OK curl ; OK master ; OK btrfs.
  - RUN (locate the append point — current EOF must be pool_boot_lane):
        grep -nE '^pool_boot_lane\(\)' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
  - EXPECT: pool_boot_lane defined (@2185); it is the last function. APPEND the new banner + the
        function AFTER its closing brace. Do NOT touch any existing function.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_ensure_connected() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_boot_lane's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block, then adapt commentary to codebase style):
        # =============================================================================
        # Acquire — ensure connected (P1.M5.T1.S3)
        # =============================================================================
        # PRD §2.4 step 4 (ENSURE CONNECTED) — the per-invocation self-heal. Given an
        # ALREADY-BOOTED lane (port>0, from pool_boot_lane / S2 or a reuse-orphan adoption / S1),
        # verify it is STILL drivable; if not, RECONNECT (re-bind the daemon) or RELAUNCH (restart
        # Chrome on the SAME dir+port, keeping the profile — PRD §2.14 "Chrome crash mid-task").
        # Consumed by the wrapper lifecycle step 4 (M6.T3.S1) on EVERY DRIVING call.
        #
        # Returns 0 if connected (was-already OR reconnected OR relaunched); 1 on failure. NEVER
        # drops the lane (that's the wrapper's / reaper's job). The literal PRD `get cdp-url` probe
        # is BROKEN on agent-browser 0.28.0 (auto-launches strays — P1.M4.T3.S1 research §2), so
        # the connected check is the SIDE-EFFECT-FREE pool_daemon_connected + curl /json/version.

        # pool_ensure_connected LANE
        #
        # LOGIC (CONTRACT a→d):
        #   a. Read the lease → session, port, ephemeral_dir (+ chrome_pid). Lease missing/corrupt
        #      OR port<=0 (provisional, not booted) → return 1 (defensive — S2's job).
        #   b. pool_daemon_connected "$session" "$port" (SIDE-EFFECT-FREE): rc 0 → touch last_seen_at
        #      → return 0.
        #   c. NOT connected. Chrome alive? curl /json/version on the port (NOT kill -0 — research §2):
        #      ALIVE → pool_daemon_connect (re-bind the daemon): rc 0 → connected:true + last_seen_at
        #      → return 0; rc 1 → last_seen_at → return 1.
        #      DEAD → RELAUNCH on same dir+port: rm -f Singleton* ; pool_chrome_launch (0 or fatal
        #      pool_die) ; early-write chrome_pid/pgid (reaper-safe) ; pool_wait_cdp (rc 1 → chrome
        #      already killed → connected:false + last_seen_at → return 1) ; pool_daemon_connect
        #      (rc 1 → connected:false + last_seen_at → return 1) ; connected:true + last_seen_at
        #      → return 0.
        #   d. last_seen_at is touched on EVERY path (the observability heartbeat).
        #
        # CALLER CONTRACT (the wrapper M6.T3.S1, under set — e):
        #     if ! pool_ensure_connected "$N"; then
        #         <lane unusable: retry acquire / M5.T4 exhaustion / surface error>
        #     fi
        #     exec ... AGENT_BROWSER_SESSION=abpool-<N> ...
        #
        # GOTCHA — get cdp-url is FORBIDDEN (P1.M4.T3.S1 §2): use pool_daemon_connected (2 args).
        # GOTCHA — the Chrome-aliveness sub-check is curl /json/version, NOT kill -0 (research §2).
        # GOTCHA — NEVER drops the lane: returns 1, leaves lease + chrome as-is. No _pool_release_*.
        # GOTCHA — pool_chrome_launch pool_die (instant-exit) is FATAL + propagates (research §1.3).
        # GOTCHA — pool_wait_cdp KILLS the pgroup on timeout: after rc 1 the relaunched chrome is dead.
        # GOTCHA — early chrome-id write BEFORE wait_cdp (reaper-safe — research §5).
        # GOTCHA — Singleton cleanup before relaunch (research §3 / pool_copy_master pattern).
        # GOTCHA — every `local` capture is split (BashFAQ 105); every rc-1 helper guarded.
        # Reads POOL_EPHEMERAL_ROOT (relaunch udd) + POOL_LANES_DIR (via helpers) + POOL_CHROME_PID/PGID
        # (set by pool_chrome_launch). No new globals exported.
        # PRECONDITION: pool_config_init + pool_state_init + a BOOTED lease for LANE (port>0).
        pool_ensure_connected() {
            local lane="${1:-}"
            local json session port ephemeral_dir now

            # Validate lane.
            [[ "$lane" =~ ^[0-9]+$ ]] \
                || { _pool_log "pool_ensure_connected: bad lane '$lane'"; return 1; }

            # --- a. Read the lease (ONE read, ONE jq fork — the pool_lane_is_stale "ONE fork" idiom). ---
            # Lease missing/corrupt → return 1 (non-fatal; never pool_die — runs on the hot path).
            # `if !` is errexit-exempt (a bare capture ABORTS on rc 1).
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                _pool_log "pool_ensure_connected: no/corrupt lease for lane $lane"
                return 1
            fi
            # Extract the 3 fields we need in ONE jq fork (comma → 3 lines; mapfile -t strips \n).
            # jq cannot fail here (valid JSON guaranteed by pool_lease_read's _pool_json_valid).
            local -a _f
            mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")
            session="${_f[0]:-}"
            port="${_f[1]:-}"
            ephemeral_dir="${_f[2]:-}"

            # A not-booted (provisional) lane has port:0 — ensure_connected is for BOOTED lanes.
            # Reconstruct session/ephemeral_dir defensively if the lease fields are empty.
            [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
                || { _pool_log "pool_ensure_connected: lane $lane not booted (port='$port')"; return 1; }
            [[ -n "$session" ]]      || session="abpool-$lane"
            [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"

            now="$(_pool_now)"

            # --- b. ALREADY connected? (SIDE-EFFECT-FREE — never launches; the get cdp-url REPLACEMENT). ---
            if pool_daemon_connected "$session" "$port"; then
                pool_lease_update "$lane" last_seen_at "$now"   # observability heartbeat
                return 0
            fi

            # --- c. NOT connected. Chrome alive? curl /json/version (NOT kill -0 — research §2). ---
            if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
                # Chrome ALIVE → the daemon just lost its binding. RECONNECT (cheap ~ms attach).
                if pool_daemon_connect "$session" "$port"; then
                    pool_lease_update "$lane" connected true
                    pool_lease_update "$lane" last_seen_at "$now"
                    _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
                    return 0
                fi
                _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
                pool_lease_update "$lane" last_seen_at "$now"
                return 1
            fi

            # --- c. Chrome DEAD → RELAUNCH on the SAME dir+port (PRD §2.14 "Chrome crash mid-task"). ---
            # Singleton cleanup BEFORE launch (research §3 / pool_copy_master pattern): defeats the
            # PID-recycle false-alive that would make Chrome exit without binding. Safe: curl just
            # proved the chrome is dead. SingletonSocket is AF_UNIX — rm -f handles all three.
            rm -f -- "$ephemeral_dir/SingletonLock" "$ephemeral_dir/SingletonCookie" "$ephemeral_dir/SingletonSocket" \
                2>/dev/null || true

            # Launch the NEW chrome on the same port + same dir. pool_chrome_launch sets globals
            # POOL_CHROME_PID/PGID (declare -g); returns 0 or pool_die's on INSTANT exit (FATAL —
            # propagates; genuine misconfiguration, NOT a recoverable mid-task crash).
            pool_chrome_launch "$port" "$ephemeral_dir" "$lane"

            # Early chrome-id write (BEFORE wait_cdp — reaper-safe, research §5): if wait_cdp times
            # out (kills the pgroup) or this process is SIGKILL'd mid-relaunch, the lease holds the
            # new (dead-or-live) chrome identity so _pool_release_lane_internals / the reaper act
            # correctly. ${:-0} is set -u safe (globals are set after a successful launch, but be
            # defensive). pool_lease_update splices the value as raw JSON (bare digits OK).
            pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}"
            pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"

            # Wait for the relaunched chrome's CDP. rc 1 = timeout AND the pgroup is ALREADY KILLED
            # (pool_wait_cdp does the kill before returning 1). Non-fatal: set connected:false +
            # touch last_seen_at, return 1. (The lane is NOT dropped — wrapper/reaper's job.)
            if ! pool_wait_cdp "$port"; then
                _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
                pool_lease_update "$lane" connected false
                pool_lease_update "$lane" last_seen_at "$now"
                return 1
            fi

            # CDP ready → re-bind the daemon. rc 1 = the (alive) chrome won't bind — set
            # connected:false, return 1. (We do NOT kill the live chrome here — ensure_connected
            # never drops the lane; the next ensure_connected / reaper handles it.)
            if ! pool_daemon_connect "$session" "$port"; then
                _pool_log "pool_ensure_connected: lane $lane relaunch connect FAILED (cdp up, connect rc 1)"
                pool_lease_update "$lane" connected false
                pool_lease_update "$lane" last_seen_at "$now"
                return 1
            fi

            # Relaunch succeeded: a fresh chrome on the same port + dir, profile kept (PRD §2.14).
            pool_lease_update "$lane" connected true
            pool_lease_update "$lane" last_seen_at "$now"
            _pool_log "pool_ensure_connected: lane $lane relaunched (new pid=${POOL_CHROME_PID:-0}, port=$port)"
            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155 + BashFAQ-105); the lease
        read uses ONE jq fork via mapfile (the pool_lane_is_stale idiom); non-fatal rc-1 helpers
        guarded with `if …; then …; else …; return 1; fi`; `_pool_log` one line per
        branch/decision; docstring with LOGIC + CALLER CONTRACT + GOTCHA sections (mirror
        pool_daemon_connected / pool_boot_lane).
  - NAMING: pool_ensure_connected (PUBLIC, CONTRACT name, no `_`). NO private helpers.
  - PLACEMENT: the function in the new "(P1.M5.T1.S3)" banner, after pool_boot_lane.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_ensure_connected' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: HAPPY PATH — booted lane, already connected → rc 0, last_seen_at touched ---
  - RUN (boot a real lane via pool_boot_lane first, then ensure; isolated state):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Provisional claim → full boot (S1+S2):
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  ls_before="$(pool_lease_field 1 last_seen_at)"
                  sleep 2   # so last_seen_at must change
                  if pool_ensure_connected 1; then echo "OK1-rc0"; else echo "FAIL1-rc"; fi
                  ls_after="$(pool_lease_field 1 last_seen_at)"
                  conn="$(pool_lease_field 1 connected)"
                  cpid="$(pool_lease_field 1 chrome_pid)"
                  [[ "$ls_after" -gt "$ls_before" ]] && echo "OK1-touched ($ls_before→$ls_after)" || echo "FAIL1-touched"
                  [[ "$conn" == "true" ]] && echo "OK1-connected" || echo "FAIL1-connected=$conn"
                  # Chrome count UNCHANGED (no relaunch on happy path):
                  "$POOL_REAL_BIN" --session abpool-1 --json session list 2>/dev/null \
                      | jq -e --arg s abpool-1 ".data.sessions | index(\$s)" >/dev/null && echo "OK1-session" || echo "FAIL1-session"
                  # CLEANUP:
                  pg="$(pool_lease_field 1 chrome_pgid)"; kill -9 -- -"$pg" 2>/dev/null || true
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK1-rc0 ; OK1-touched ; OK1-connected ; OK1-session.
  #
  # --- SCENARIO 2: RECONNECT PATH — daemon binding closed, Chrome STILL ALIVE → rc 0, SAME chrome ---
  - RUN (boot, then `agent-browser close` to drop the binding, then ensure):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  cpid_before="$(pool_lease_field 1 chrome_pid)"
                  port="$(pool_lease_field 1 port)"
                  # Drop ONLY the daemon binding (Chrome stays alive — CDP still answers):
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true
                  # Verify chrome STILL alive (CDP up) but binding may be gone:
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK2-chrome-alive" || echo "FAIL2-chrome-dead"
                  if pool_ensure_connected 1; then echo "OK2-rc0"; else echo "FAIL2-rc"; fi
                  cpid_after="$(pool_lease_field 1 chrome_pid)"
                  conn="$(pool_lease_field 1 connected)"
                  # SAME chrome pid (no relaunch):
                  [[ "$cpid_after" == "$cpid_before" ]] && echo "OK2-same-chrome ($cpid_before)" || echo "FAIL2-relaunched ($cpid_before→$cpid_after)"
                  [[ "$conn" == "true" ]] && echo "OK2-connected" || echo "FAIL2-connected=$conn"
                  "$POOL_REAL_BIN" --session abpool-1 --json session list 2>/dev/null \
                      | jq -e --arg s abpool-1 ".data.sessions | index(\$s)" >/dev/null && echo "OK2-rebound" || echo "FAIL2-rebound"
                  pg="$(pool_lease_field 1 chrome_pgid)"; kill -9 -- -"$pg" 2>/dev/null || true
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK2-chrome-alive ; OK2-rc0 ; OK2-same-chrome ; OK2-connected ; OK2-rebound.
  #
  # --- SCENARIO 3: RELAUNCH PATH — Chrome KILLED → rc 0, NEW chrome on SAME port+dir ---
  - RUN (boot, then kill the chrome pgroup, then ensure → relaunch):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  cpid_before="$(pool_lease_field 1 chrome_pid)"
                  port="$(pool_lease_field 1 port)"
                  edir="$(pool_lease_field 1 ephemeral_dir)"
                  # Kill the Chrome pgroup (simulate PRD §2.14 "Chrome crash mid-task"):
                  pg_before="$(pool_lease_field 1 chrome_pgid)"
                  kill -9 -- -"$pg_before" 2>/dev/null || true; sleep 1
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "FAIL3-chrome-still-alive" || echo "OK3-chrome-dead"
                  # Verify the ephemeral dir is KEPT (profile survives) — pick a sentinel file:
                  [[ -d "$edir" ]] && echo "OK3-dir-kept" || echo "FAIL3-dir-gone"
                  if pool_ensure_connected 1; then echo "OK3-rc0"; else echo "FAIL3-rc"; fi
                  cpid_after="$(pool_lease_field 1 chrome_pid)"
                  conn="$(pool_lease_field 1 connected)"
                  [[ "$cpid_after" =~ ^[0-9]+$ && "$cpid_after" -gt 0 && "$cpid_after" != "$cpid_before" ]] \
                      && echo "OK3-new-chrome ($cpid_before→$cpid_after)" || echo "FAIL3-chrome-ids ($cpid_before→$cpid_after)"
                  [[ "$conn" == "true" ]] && echo "OK3-connected" || echo "FAIL3-connected=$conn"
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK3-cdp-up" || echo "FAIL3-cdp-down"
                  "$POOL_REAL_BIN" --session abpool-1 --json session list 2>/dev/null \
                      | jq -e --arg s abpool-1 ".data.sessions | index(\$s)" >/dev/null && echo "OK3-rebound" || echo "FAIL3-rebound"
                  pg_after="$(pool_lease_field 1 chrome_pgid)"; kill -9 -- -"$pg_after" 2>/dev/null || true
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK3-chrome-dead ; OK3-dir-kept ; OK3-rc0 ; OK3-new-chrome ; OK3-connected ;
        #         OK3-cdp-up ; OK3-rebound.
  #
  # --- SCENARIO 4: RELAUNCH CDP-TIMEOUT FAILURE — port occupied → rc 1, connected:false, lane kept ---
  - RUN (boot, kill chrome, occupy the port so the relaunch can't bind, then ensure):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  port="$(pool_lease_field 1 port)"
                  pg="$(pool_lease_field 1 chrome_pgid)"
                  # Kill the lane chrome + occupy its port so the relaunch cannot bind /json/version:
                  kill -9 -- -"$pg" 2>/dev/null || true; sleep 1
                  python3 -m http.server "$port" --bind 127.0.0.1 >/tmp/s4-occ.log 2>&1 & OCC=$!
                  sleep 0.5
                  if pool_ensure_connected 1; then echo "FAIL4-should-be-rc1"; else echo "OK4-rc1"; fi
                  conn="$(pool_lease_field 1 connected)"
                  [[ "$conn" == "false" ]] && echo "OK4-connected-false" || echo "FAIL4-connected=$conn"
                  # Lane NOT dropped (lease file still exists):
                  test -e "$POOL_LANES_DIR/1.json" && echo "OK4-lane-kept" || echo "FAIL4-lane-dropped"
                  kill "$OCC" 2>/dev/null || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK4-rc1 ; OK4-connected-false ; OK4-lane-kept. (May take ~30s for wait_cdp timeout.)
  #
  # --- SCENARIO 5: NOT-BOOTED LANE (port:0) + MISSING LEASE → rc 1 (defensive) ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Provisional (port:0) lease:
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  if pool_ensure_connected 1; then echo "FAIL5-provisional-should-be-rc1"; else echo "OK5-provisional-rc1"; fi
                  # No lease at all:
                  if pool_ensure_connected 99; then echo "FAIL5-missing-should-be-rc1"; else echo "OK5-missing-rc1"; fi'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK5-provisional-rc1 ; OK5-missing-rc1.
```

### Implementation Patterns & Key Details

```bash
# The connected-check + liveness-decision spine (research §4):
#   pool_daemon_connected "$session" "$port"          # rc 0 → connected, touch, return 0
#     || curl /json/version                            # Chrome alive?
#         && pool_daemon_connect "$session" "$port"   #   YES → re-bind (reconnect)
#         || <RELAUNCH>                                #   NO  → rm Singleton*; launch; wait; connect

# The relaunch sub-flow (inlined — research §3/§5):
#   rm -f -- "$edir"/SingletonLock SingletonCookie SingletonSocket   # §3 (before launch)
#   pool_chrome_launch "$port" "$edir" "$lane"                        # sets globals; fatal pool_die ok
#   pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}"     # §5 early write (reaper-safe)
#   pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
#   pool_wait_cdp "$port"  || { connected=false; last_seen_at; return 1; }   # rc1 = chrome already killed
#   pool_daemon_connect "$session" "$port" || { connected=false; last_seen_at; return 1; }
#   pool_lease_update "$lane" connected true; pool_lease_update "$lane" last_seen_at "$now"; return 0
```

### Integration Points

```yaml
LEASE (no schema change — top-level field updates only, via pool_lease_update):
  - read:   session, port, ephemeral_dir (+ chrome_pid) from lanes/<N>.json (pool_lease_read + ONE jq)
  - update: last_seen_at (every path); connected (true on success / false on relaunch-connect fail);
            chrome_pid, chrome_pgid (relaunch path — early write before wait_cdp)

GLOBALS (no new exports — reads only):
  - POOL_EPHEMERAL_ROOT (relaunch --user-data-dir; frozen by pool_config_init)
  - POOL_LANES_DIR (via pool_lease_read/field/update)
  - POOL_CHROME_PID / POOL_CHROME_PGID (set by pool_chrome_launch during relaunch; read into the lease)

CONSUMERS (downstream — NOT this task's concern, documented for context):
  - M6.T3.S1 wrapper lifecycle step 4: `if ! pool_ensure_connected "$N"; then <error path>; fi`
    before exec'ing the real binary. The common case (connected) is ~1 jq + 1 curl + 2 atomic
    lease touches — fast on the hot path.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after the function is appended — fix before proceeding.
bash -n lib/pool.sh                              # syntax — MUST be clean (zero output)
shellcheck lib/pool.sh                           # whole file — zero warnings
shellcheck -s bash lib/pool.sh | grep -i 'pool_ensure_connected' || echo "OK no SC on new fn"
# Expected: zero errors/warnings. If any exist, READ the output and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

The project has no bats harness yet (M9.T1.S1). Validate via the **host-verified scenarios in
Task 2** (real Chrome + real agent-browser + isolated state dirs), which exercise every branch:

```bash
# Run each SCENARIO 1–5 from Task 2 in turn. Each is self-contained (mktemp state + EPHEM dirs,
# real master/chrome/agent-browser, cleanup at the end). EXPECT the documented OK* lines.

# Quick smoke (function callable, no-op on a missing lease):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
         if pool_ensure_connected 999; then echo "FAIL (should rc1)"; else echo "OK smoke (rc1 on missing lease)"; fi'
```

### Level 3: Integration Testing (System Validation)

```bash
# Full acquire → boot → ensure round-trip (simulates the wrapper lifecycle steps 3→4):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
AGENT_BROWSER_POOL_OWNER_PID=77777 AGENT_BROWSER_POOL_OWNER_STARTTIME=12345 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
          N="$(pool_acquire_locked)"                                   # step 3 (S1: claim)
          port="$(pool_lease_field "$N" port)"
          if [[ "$port" == "0" ]]; then pool_boot_lane "$N"; fi        # step 3e-3j (S2: boot)
          pool_ensure_connected "$N" && echo "OK3-integration rc0" || echo "FAIL3-integration"
          # drive it once:
          "$POOL_REAL_BIN" --session "abpool-$N" --json session list >/dev/null && echo "OK3-drivable" || echo "FAIL3"
          pg="$(pool_lease_field "$N" chrome_pgid)"; kill -9 -- -"$pg" 2>/dev/null || true
          "$POOL_REAL_BIN" --session "abpool-$N" close >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-integration rc0 ; OK3-drivable.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# PRD §2.14 round-trip: drive → crash Chrome → ensure recovers → drive again (SAME profile):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          # (1) drive: open a page that leaves a profile marker (a cookie / history entry)
          port="$(pool_lease_field 1 port)"; edir="$(pool_lease_field 1 ephemeral_dir)"
          "$POOL_REAL_BIN" --session abpool-1 open "https://example.com" >/dev/null 2>&1 || true
          sleep 1
          # (2) crash Chrome (PRD §2.14)
          pg="$(pool_lease_field 1 chrome_pgid)"; kill -9 -- -"$pg" 2>/dev/null || true; sleep 1
          # (3) ensure recovers (relaunch on same dir+port → profile kept)
          pool_ensure_connected 1 && echo "OK4-recovered" || echo "FAIL4-recover"
          # (4) the profile dir is the SAME (profile kept — open tabs lost, but profile state persists)
          cpid2="$(pool_lease_field 1 chrome_pid)"; [[ "$cpid2" -gt 0 ]] && echo "OK4-new-chrome" || echo "FAIL4"
          test -d "$edir" && echo "OK4-profile-kept" || echo "FAIL4-profile-gone"
          pg2="$(pool_lease_field 1 chrome_pgid)"; kill -9 -- -"$pg2" 2>/dev/null || true
          "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-recovered ; OK4-new-chrome ; OK4-profile-kept.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` zero warnings (whole file).
- [ ] Level 2: all 5 scenarios from Task 2 print their documented `OK*` lines.
- [ ] Level 3: the acquire→boot→ensure integration round-trip prints `OK3-integration rc0` + `OK3-drivable`.
- [ ] Level 4: the crash→recover round-trip prints `OK4-recovered` + `OK4-new-chrome` + `OK4-profile-kept`.

### Feature Validation

- [ ] Happy path: booted lane → rc 0; `last_seen_at` updated; Chrome + daemon unchanged (Scenario 1).
- [ ] Reconnect path: daemon binding closed, Chrome alive → rc 0; SAME chrome_pid; re-bound (Scenario 2).
- [ ] Relaunch path: Chrome killed → rc 0; NEW chrome on SAME port + dir; chrome_pid/pgid updated (Scenario 3).
- [ ] Relaunch CDP-timeout failure → rc 1; relaunched Chrome killed; `connected:false`; lane NOT dropped (Scenario 4).
- [ ] Provisional/unbooted lane (port:0) → rc 1 early; missing lease → rc 1 (Scenario 5).
- [ ] `get cdp-url` is NOT used anywhere (uses `pool_daemon_connected` + `curl /json/version`).
- [ ] `kill -0` is NOT used (liveness sub-check is `curl /json/version`).
- [ ] Singleton* removed before every relaunch.

### Code Quality Validation

- [ ] Follows existing codebase patterns (the pool_lane_is_stale "ONE jq fork" idiom for the lease
      read; pool_lease_update for all writes; `_pool_log` one line per decision; docstring with
      LOGIC + CALLER CONTRACT + GOTCHA sections).
- [ ] `pool_ensure_connected` appended under a new `(P1.M5.T1.S3)` banner after `pool_boot_lane`;
      NO edits to any existing function.
- [ ] Every `local` capture is split (`local X; X="$(…)"`); every non-fatal rc-1 helper guarded.
- [ ] Anti-patterns avoided (see below): no `kill -0`, no `get cdp-url`, no lane-drop, no retry,
      no `local x=$(...)` masking, no missing `--`/`${:-}` guards.

### Documentation & Deployment

- [ ] Code is self-documenting (the docstring's LOGIC block IS the spec; the GOTCHA block captures
      the three deviations from the literal contract: curl-not-kill-0, get-cdp-url-forbidden,
      Singleton-cleanup).
- [ ] `_pool_log` lines are informative (one per branch: already-connected / reconnected /
      reconnect-failed / relaunch-cdp-timeout / relaunch-connect-failed / relaunched).
- [ ] No new env vars (reads only the frozen POOL_* globals + the chrome-id globals).

---

## Anti-Patterns to Avoid

- ❌ Don't use `kill -0 $chrome_pid` for the Chrome-aliveness check — it's a trap (ESRCH/EPERM
  conflation + PID-recycling + no CDP-readiness signal). Use `curl -sf /json/version`.
- ❌ Don't use `get cdp-url` — it auto-launches stray Chromes and always returns rc 0. Use
  `pool_daemon_connected(session, port)` (side-effect-free).
- ❌ Don't drop/release the lane on failure — `pool_ensure_connected` returns 1 and leaves the
  lease + Chrome as-is. Dropping is the wrapper's / reaper's job.
- ❌ Don't retry the relaunch — the contract is a SINGLE relaunch. On `pool_wait_cdp` rc 1 →
  return 1 (the wrapper can re-invoke).
- ❌ Don't catch `pool_chrome_launch`'s `pool_die` in a subshell — you'd lose the `declare -g`
  globals and leak the Chrome. Let it propagate (instant-exit is a genuine misconfiguration).
- ❌ Don't write `local X="$(…)"` — `local` masks errexit. Split it: `local X; X="$(…)"`.
- ❌ Don't forget the `--` on negative-pgid kills (not used here directly, but the
  `kill -9 -- -"$pg"` in the test cleanup needs it) or the `${:-0}` on the chrome-id globals
  (set -u safety).
- ❌ Don't skip the Singleton cleanup before relaunch — the PID-recycle false-alive edge case
  would make Chrome silently exit without binding the port.
- ❌ Don't touch the `owner` sub-object or re-write `connected` on the already-connected happy
  path (it's already `true`; only touch `last_seen_at`).
- ❌ Don't create unnecessary private helpers — the decision tree is short + linear; one
  function reads cleaner than fragmented `_pool_*` pieces.
