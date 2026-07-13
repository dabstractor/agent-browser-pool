# Research — P1.M5.T1.S3: `pool_ensure_connected` (reconnect + relaunch logic)

Date: 2026-07-13. Sources: `lib/pool.sh` read in FULL (all LANDED M1–M5.T1.S2 functions,
verified present this session: `pool_daemon_connect` @1631, `pool_daemon_connected` @~1700,
`pool_chrome_launch` @1471, `pool_wait_cdp` @1570, `pool_lease_field` @~720,
`pool_lease_update` @763, `pool_lease_read` @~650, `_pool_now`, `_pool_release_lane_internals`
@1813); `P1M5T1S2/PRP.md` + `research/post-lock-boot.md` (S2 CONTRACT — the boot that
produces the lane this task ENSURES); `P1M5T1S1/PRP.md` (S1 — pool_acquire_locked);
`P1M4T3S1/research/daemon-connect-teardown-host-verified.md` (§2 the `get cdp-url`
AUTO-LAUNCH trap; §6 the side-effect-free `pool_daemon_connected` design); `PRD.md`
§2.4 step 4, §2.14, §2.8; the relaunch/Singleton + kill-0-vs-curl subagent research
(`.pi-subagents/artifacts/outputs/e958d9a8/research.md`).

Host facts VERIFIED this session: `pool.sh` == **2238 lines**; EOF function is
`pool_boot_lane` (S2 deliverable, LANDED). All composed deps `type`-check as functions.
`~/.agent-chrome-profiles/master-profile` (4.8 GB) present; FSTYPE of
`~/.agent-chrome-profiles` == **btrfs**; `google-chrome-stable` @ `/usr/bin/...`;
`~/.local/bin/agent-browser` present; `curl`/`jq`/`setsid`/`kill`/`flock` all present.

---

## §0. What `pool_ensure_connected` consumes (the S2 CONTRACT — already LANDED)

`pool_boot_lane(LANE)` (P1.M5.T1.S2, LANDED @2185) turns a PROVISIONAL lane into a
FULLY-provisioned one. Its SUCCESS state (the lane `pool_ensure_connected` takes as INPUT)
is, per the S2 PRP success definition + the `pool_boot_lane` source:

| field | value after a successful S2 boot |
|---|---|
| `port` | > 0, in [53420, 54420) |
| `session` | `"abpool-<N>"` |
| `chrome_pid` | > 0 (the live Chrome leader pid) |
| `chrome_pgid` | > 0 (== chrome_pid; setsid contract) |
| `ephemeral_dir` | ABSOLUTE, `"$POOL_EPHEMERAL_ROOT/$N"` |
| `connected` | `true` (JSON boolean) |
| `last_seen_at` | epoch seconds (the boot's `_pool_now`) |
| `owner` | the claimer (set by S1's provisional claim; unchanged by S2) |

**So `pool_ensure_connected(LANE)` is invoked on an ALREADY-BOOTED lane** (port>0,
chrome_pid>0, connected:true) on a SUBSEQUENT `agent-browser` DRIVING call (PRD §2.4 step 4).
Its job: verify the lane is STILL drivable; if not, RECONNECT (re-bind the daemon) or
RELAUNCH (restart Chrome on the same dir+port), keeping the lease. Per PRD §2.14 row
"Chrome crash mid-task": "relaunch on same dir+port, reconnect, keep lease (open tabs lost;
profile kept)."

> The S2 PRP's `pool_boot_lane` CALLER CONTRACT explicitly says the wrapper (M6.T3.S1)
> branches on the lease state: `port==0` (provisional) ⇒ `pool_boot_lane`; `port>0 &&
> connected` (adopted OR previously-booted) ⇒ **`ensure_connected` (THIS task)**. So this
> function runs on BOTH (a) reused previously-booted lanes (the steady state — every
> subsequent call after the first cold boot) AND (b) S1 reuse-orphan adopted lanes.

---

## §1. The composed-function contract table (rc conventions + signatures — HOST-VERIFIED)

`pool_ensure_connected` composes FIVE already-landed primitives + two helpers. Exact rc
conventions (read from `lib/pool.sh` source):

| function (LANDED @line) | args | returns | fatal? | ensure_connected role |
|---|---|---|---|---|
| `pool_daemon_connected` @~1700 | `session` `port` | **0** connected / **1** not | NON-fatal, SIDE-EFFECT-FREE | step b. "is the lane drivable right now?" |
| `pool_daemon_connect` @1631 | `session` `port` | subprocess rc (**0** bound / **1** dead) | NON-fatal | reconnect path: re-bind the daemon |
| `pool_chrome_launch` @1471 | `port` `user_data_dir` `lane` | **0** | **pool_die** on bad args / instant exit; sets `POOL_CHROME_PID`/`POOL_CHROME_PGID` via `declare -g` | relaunch path: restart Chrome |
| `pool_wait_cdp` @1570 | `port` | **0** ready / **1** timeout (**KILLS the chrome pgroup on timeout**) | NON-fatal | relaunch path: wait for CDP |
| `pool_lease_field` @~720 | `lane` `field` | echoes value, **0**; **1** on missing/corrupt | NON-fatal | read lease → session/port/ephemeral_dir |
| `pool_lease_update` @763 | `lane` `field` `value` | 0 | **pool_die** on missing/corrupt lease or non-JSON value; **TOP-LEVEL field only** | touch last_seen_at, set connected/chrome_pid/pgid |
| `pool_lease_read` @~650 | `lane` | echoes JSON, **0**; **1** missing/corrupt | NON-fatal | (alt) read the whole lease in one jq fork |
| `_pool_now` @~580 | (none) | echoes epoch seconds, **0** | NON-fatal | last_seen_at timestamp |

**Key rc-convention facts (each HOST-VERIFIED by reading the source):**

1. **`pool_daemon_connected` is SIDE-EFFECT-FREE + takes TWO args (`session` `port`).**
   It is the read-only, stray-free "is this lane drivable?" predicate (P1.M4.T3.S1
   research §6). It NEVER launches a Chrome (the `get cdp-url` AUTO-LAUNCH trap, §2 of
   that research, is the reason this function EXISTS with this signature). It returns 0 iff
   BOTH (1) the session is known to the daemon AND (2) `curl -sf /json/version` on the port
   answers HTTP 200. **This is the `get cdp-url` REPLACEMENT** — the literal PRD §2.4 step 4
   `get cdp-url` is BROKEN on agent-browser 0.28.0 (always rc 0 + auto-launches strays).
2. **`pool_daemon_connect` rc 1 = NON-FATAL** (dead port / unreachable / "Connection
   refused"). Idempotent + re-bindable (re-running connect on an already-bound session +
   same-live-port returns rc 0). Safe to call speculatively in the reconnect path.
3. **`pool_chrome_launch` pool_die's on INSTANT exit** (Chrome died before its pgroup could
   be read) → `exit 1` (FATAL, NOT catchable in a normal function call). On SUCCESS it sets
   the globals `POOL_CHROME_PID=$!` and `POOL_CHROME_PGID`. **For the relaunch path, this
   FATAL pool_die propagates** — it is a genuine Chrome misconfiguration (broken binary /
   bad flags), not a recoverable mid-task crash. The contract's "Return 0/1" does NOT cover
   this case (same as S2 §3).
4. **`pool_wait_cdp` KILLS the chrome pgroup on timeout THEN returns 1.** Source: on
   timeout, `if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then kill -- -"$POOL_CHROME_PGID"
   …; fi; return 1`. **So when wait_cdp returns 1, the relaunched Chrome is ALREADY DEAD.**
   ensure_connected just returns 1 (it does NOT retry — the contract is a single relaunch).
5. **`pool_lease_update` is TOP-LEVEL FIELD ONLY + pool_die's on missing/corrupt lease.**
   Value spliced as raw JSON via `--argjson` → `last_seen_at`/`chrome_pid`/`chrome_pgid` are
   bare digits; `connected` MUST be the literal `true`/`false`. The lease MUST already exist
   (it does — S1 claimed it, S2 booted it). Each call = one atomic read-modify-write.

---

## §2. THE liveness-check decision: `curl /json/version`, NOT `kill -0`

The item CONTRACT step c literally says: "check if Chrome is still alive
(`kill -0 $chrome_pid`)". **This literal `kill -0` is a TRAP and must NOT be used.** The
PRP specifies `curl -sf http://127.0.0.1:$port/json/version` instead. Justification
(subagent research e958d9a8 + the codebase's OWN established pattern):

1. **`kill -0` conflates ESRCH (dead) with EPERM (alive but not yours).** `kill(2)`: signal
   0 returns ESRCH if no such process, EPERM if the process exists but you lack permission.
   The shell's `kill -0` returns exit code 1 for **both** — indistinguishable. A live Chrome
   owned by another user (or a permission edge case) would look "dead." The pool's OWN
   `pool_owner_alive()` docstring (M2.T2.S1) documents this exact trap and uses `/proc/<pid>`
   existence instead. [kill(2) man page — man7.org/linux/man-pages/man2/kill.2.html]
2. **`kill -0` is vulnerable to PID recycling.** After Chrome dies, the kernel may assign
   its PID to an unrelated process. `kill -0 $old_chrome_pid` then returns 0 ("alive") even
   though Chrome is dead. `kill -0` has NO identity check (no starttime). The whole pool
   exists to avoid exactly this class of stale-identity bug (PRD §2.8, §2.14).
3. **`kill -0` says NOTHING about CDP readiness.** A Chrome process can be ALIVE (pid
   exists) but wedged/hung, or still mid-boot (DevTools HTTP server not yet listening), or
   the `--remote-debugging-port` not bound. `kill -0` returns 0 in ALL those cases, but the
   daemon connect would fail. `curl /json/version` returns 0 ONLY when Chrome's DevTools HTTP
   server is fully initialized and accepting connections (the response includes
   `webSocketDebuggerUrl`, proving the entire CDP stack is up). [Chrome DevTools Protocol —
   HTTP endpoints: chromedevtools.github.io/devtools-protocol]
4. **The ENTIRE industry polls the HTTP CDP endpoint, not the PID.** Puppeteer's `launch()`
   resolves only when it can read from the HTTP endpoint; Playwright polls the CDP endpoint;
   chrome-remote-interface fetches `/json/version` as its connection bootstrap. NONE checks
   process liveness. [github.com/puppeteer/puppeteer ProductLauncher.ts;
   github.com/microsoft/playwright chromium.ts; github.com/cyrus-and/chrome-remote-interface]
5. **The codebase ALREADY uses `curl /json/version` as THE Chrome-liveness check
   EVERYWHERE.** `pool_wait_cdp` (60×0.5s), `pool_daemon_connected` (step 2), and
   `pool_find_free_port` (the live-CDP-endpoint guard) ALL use it. Using `kill -0` here
   would be a lone, inconsistent, fragile outlier.

**CONCLUSION:** the reconnect-vs-relaunch decision (is the pooled Chrome alive?) uses
`curl -sf http://127.0.0.1:$port/json/version`. curl rc 0 → Chrome alive → RECONNECT
(daemon re-bind only). curl non-zero → Chrome dead/wedged → RELAUNCH. The `chrome_pid` read
from the lease (per contract step a) is kept for the lease state but is NOT the liveness
gate. **This is a deliberate, well-reasoned deviation from the literal `kill -0`**, in
service of the contract's INTENT ("is Chrome still alive and drivable?") — the literal
`kill -0` would be both incorrect (ESRCH/EPERM/PID-recycle) and inconsistent with the
codebase.

> NOTE: `pool_daemon_connected(session, port)` ALSO does a curl internally (its step 2). So
> in the not-connected branch we curl the port a SECOND time to distinguish reconnect-vs-
> relaunch. Both curls are instant on refusal (curl rc 7) — negligible overhead on the hot
> path. Keeping `pool_daemon_connected` as a single black-box predicate + one direct curl
> for the sub-decision is cleaner than inlining/duplicating its two checks.

---

## §3. Chrome relaunch on the SAME dir+port: clean the Singleton* locks first

The relaunch path (step c, Chrome dead) calls `pool_chrome_launch "$port" "$ephemeral_dir"
"$lane"` on the EXISTING ephemeral dir (no re-copy — the profile is KEPT per PRD §2.14).
The dir carries Chrome's stale single-instance locks from the crashed Chrome. Subagent
research (e958d9a8 §1, citing Chromium `process_singleton_posix.cc`):

- Chrome's `SingletonLock` is a symlink encoding `<hostname>-<pid>`. On launch, Chrome reads
  it, calls `kill(pid, 0)`: if the pid is DEAD (ESRCH), Chrome **auto-recovers** (unlinks +
  re-takes the lock). So in the COMMON case, relaunch without cleanup works.
- **BUT** there are edge cases: (a) PID recycling — if the dead Chrome's pid was recycled
  into a LIVE process, Chrome's `kill(pid, 0)` returns 0 → Chrome thinks the old instance is
  still running → **the new instance EXITS without binding the port** (the single-instance
  guard). (b) Stale `SingletonSocket`. (c) Hostname mismatch. Any of these would silently
  make `pool_wait_cdp` time out → ensure_connected returns 1 → the agent gets a dead lane.

**RESOLUTION (this PRP mandates): `rm -f SingletonLock SingletonCookie SingletonSocket` in
the ephemeral dir BEFORE `pool_chrome_launch`, matching `pool_copy_master` (PRD §2.7) and
the industry-standard Puppeteer/Playwright/Selenium pattern.** This is cheap, deterministic,
and eliminates the rare PID-recycling false-alive case. It is the SAME `rm -f` line
`pool_copy_master` uses (line ~460), so it is idiomatic. The three files are the COMPLETE
set of singleton artifacts (SingletonSocket is an AF_UNIX socket — `rm -f` handles it).

**Why `rm -f` is SAFE at this point:** we only reach the relaunch path AFTER curl confirmed
the pooled Chrome is DEAD/not-responding. The dead Chrome can no longer hold the lock. `rm
-f` is idempotent (tolerates absent files). There is no risk of removing a LIVE Chrome's
lock (we just proved it's dead). Do NOT `rm` the whole dir (the profile is KEPT — only the
three singleton artifacts go).

---

## §4. The reconnect-vs-relaunch decision flow (the function's spine)

```
pool_ensure_connected(LANE):
  validate LANE
  read lease → session, port, ephemeral_dir            # pool_lease_read + ONE jq (the "ONE fork" idiom)
    lease missing/corrupt      → return 1              # can't ensure a lane with no lease
    port invalid (<=0/"null")  → return 1              # lane not booted (provisional) — S2's job, not ours

  # (b) ALREADY connected? (SIDE-EFFECT-FREE — never launches)
  if pool_daemon_connected "$session" "$port"; then
      pool_lease_update "$lane" last_seen_at "$now"    # touch (PRD §2.4 step 4 observability)
      return 0
  fi

  # (c) NOT connected. Chrome alive? (curl — NOT kill -0, see §2)
  if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
      # Chrome ALIVE → daemon just lost its binding. RECONNECT (cheap ~ms attach).
      if pool_daemon_connect "$session" "$port"; then
          pool_lease_update "$lane" connected true
          pool_lease_update "$lane" last_seen_at "$now"
          return 0
      fi
      pool_lease_update "$lane" last_seen_at "$now"    # attempt counts as activity
      return 1
  fi

  # (c) Chrome DEAD → RELAUNCH on same dir+port (PRD §2.14 "Chrome crash mid-task")
  ephemeral_dir = <lease .ephemeral_dir if ABSOLUTE else reconstruct $POOL_EPHEMERAL_ROOT/$lane>
  rm -f "$ephemeral_dir"/SingletonLock SingletonCookie SingletonSocket   # §3 — before launch
  pool_chrome_launch "$port" "$ephemeral_dir" "$lane"   # 0 or FATAL pool_die (instant exit)
  # early chrome-id write (reaper-safe — see §5; the globals are now the NEW Chrome's)
  pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}"
  pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
  if ! pool_wait_cdp "$port"; then
      # CDP timeout — relaunched Chrome pgroup ALREADY KILLED by wait_cdp. Lane is broken.
      pool_lease_update "$lane" connected false         # truthful: chrome is dead
      pool_lease_update "$lane" last_seen_at "$now"
      return 1
  fi
  if ! pool_daemon_connect "$session" "$port"; then
      # Chrome is ALIVE (CDP up) but daemon won't bind. The live Chrome now has no daemon
      # binding. We do NOT kill it (pool_wait_cdp didn't; ensure_connected doesn't drop the
      # lane). Leave it for the next ensure_connected / the reaper. Return 1.
      pool_lease_update "$lane" connected false
      pool_lease_update "$lane" last_seen_at "$now"
      return 1
  fi
  pool_lease_update "$lane" connected true
  pool_lease_update "$lane" last_seen_at "$now"
  return 0
```

**Three terminal outcomes:** 0 = connected (was-already OR reconnected OR relaunched); 1 =
could not connect (reconnect failed OR relaunch failed). **ensure_connected NEVER drops the
lane** (no `_pool_release_lane_internals`) — that is the wrapper's / reaper's concern. The
contract: "Returns 0 if lane is connected (possibly after reconnect/relaunch), 1 on failure."

---

## §5. The early chrome-id write (reaper safety, ported from S2 §2)

The relaunch path writes `chrome_pid`/`chrome_pgid` to the lease **IMMEDIATELY after
`pool_chrome_launch`** (before `pool_wait_cdp`), not only at the end. This is the S2 leak-
prevention refinement, ported to the relaunch:

- If `pool_wait_cdp` times out, it KILLS the relaunched pgroup. The lease then holds the
  dead chrome_pid — which is CORRECT (the reaper's `_pool_release_lane_internals` reads the
  lease and kills it idempotently; a no-op since it's dead). WITHOUT the early write the
  lease would hold the OLD (pre-relaunch) chrome_pid, possibly also dead — still harmless,
  but the early write keeps the lease truthful at all times.
- If the ensure_connected process is KILLED (SIGKILL/OOM) after launch but before the final
  update, the lazy reaper (M5.T3) reads the lease, finds the NEW chrome_pid, and tears the
  relaunch-Chrome down. WITHOUT the early write the reaper would find a stale/old pid.

The globals `POOL_CHROME_PID`/`POOL_CHROME_PGID` are set by `pool_chrome_launch` via
`declare -g`. Reference them as `${POOL_CHROME_PID:-0}` / `${POOL_CHROME_PGID:-0}` (set -u
safe; default to 0 if somehow unset — `pool_lease_update` accepts 0 as a raw-JSON number).

---

## §6. set -e gotchas, naming, placement, scope

- **`local var=$(...)` masks errexit (BashFAQ 105 / SC2155).** EVERY capture MUST be split:
  `local json; json="$(pool_lease_read "$lane" 2>/dev/null)"`. Applies to pool_lease_read,
  pool_lease_field, _pool_now, and the curl check (curl is a command, not a capture — guard
  with `if`).
- **Non-fatal rc-1 helpers MUST be guarded under set -e.** `pool_daemon_connected`,
  `pool_daemon_connect`, `pool_wait_cdp` all return 1 on a RECOVERABLE failure. A BARE call
  ABORTS the caller. Use `if …; then …; else …; return 1; fi`.
- **`pool_lease_update` pool_die's on missing/corrupt lease.** The lease EXISTS (S1+S2
  wrote it); a missing/corrupt lease here is exceptional → pool_die propagates (acceptable;
  the wrapper gates on rc, and the lane is already in a broken state). We do NOT pre-check
  with `_pool_json_valid` (the early `pool_lease_read` already validated + returned 1).
- **`pool_chrome_launch` pool_die is FATAL.** On instant Chrome exit it calls `pool_die`
  (exit 1). This propagates out of ensure_connected (NOT catchable without a subshell, which
  would lose the `declare -g` globals). It is a genuine misconfiguration — let it propagate.
  The contract's "Return 0/1" covers the CDP-timeout + connect-fail paths, NOT instant-exit.
- **Naming:** `pool_ensure_connected` (PUBLIC, the CONTRACT name — no `_`). NO private
  helpers needed (the body is short + linear); the relaunch sub-flow is inlined (5 lines).
  Do NOT create `_pool_*` helpers that fragment the single decision tree.
- **Placement:** APPEND at EOF of `lib/pool.sh` (currently 2238 lines, ends with
  `pool_boot_lane`), under a new banner `# Acquire — ensure connected (P1.M5.T1.S3)`. Pure
  addition — NO edits to any existing function.
- **Scope — ensure_connected ONLY.** Do NOT: implement the wrapper lifecycle (M6.T3.S1);
  drop/release the lane (that's pool_release_lane M5.T2.S1 / the reaper M5.T3); retry the
  relaunch more than once (the contract is a SINGLE relaunch; PRD §2.14 "retry launch once"
  is the COLD-BOOT policy in S2's `_pool_launch_and_verify`, not the relaunch policy here —
  though see §7 for the optional composition note); or touch the `owner` sub-object.

---

## §7. Optional: compose S2's `_pool_launch_and_verify` for the relaunch?

S2 defined a PRIVATE `_pool_launch_and_verify(port, ephemeral_dir, lane)` that does
launch + early-write-chrome-ids + wait_cdp + **retry launch once** on timeout. The relaunch
path in ensure_connected is structurally similar (launch + wait). Two options:

- **(A) Inline single relaunch (this PRP's DEFAULT — matches the literal contract).** The
  contract step c is "pool_chrome_launch. pool_wait_cdp. pool_daemon_connect." — a single
  linear attempt. Simple, no cross-task private-function dependency. On wait_cdp timeout →
  return 1 (no retry). This is the literal contract.
- **(B) Compose `_pool_launch_and_verify` (OPTIONAL — adds retry-once).** Would give
  PRD §2.14 "retry launch once" parity with the cold boot. BUT: (1) it is a PRIVATE function
  from a sibling task (fragile coupling); (2) it would deviate from the literal single-
  relaunch contract; (3) `_pool_launch_and_verify` writes chrome-ids itself (no double-write
  concern — it calls `_pool_boot_write_chrome_ids`).

**Decision: (A) inline single relaunch.** The contract is explicit and the relaunch is an
already-warm path (the dir exists, the profile is populated, Chrome boots faster than a cold
start). A single attempt + return 1 on failure is sufficient; the wrapper (M6) can retry by
re-invoking, or the next call re-runs ensure_connected. Option (B) is noted for the
implementer but NOT the default.

---

## §8. Decisions summary

| decision | choice | rationale |
|---|---|---|
| liveness check | `curl /json/version` (NOT `kill -0`) | §2 — kill -0 is a trap (ESRCH/EPERM/PID-recycle); curl is idiomatic + tests CDP readiness; industry standard |
| relaunch singleton cleanup | `rm -f Singleton{Lock,Cookie,Socket}` before launch | §3 — eliminates PID-recycle false-alive; matches pool_copy_master; industry standard |
| relaunch retry | single attempt (no retry) | §7 — literal contract; warm path; caller can re-invoke |
| chrome-id early write | YES (before wait_cdp) | §5 — reaper-safe; lease-truthful; ported from S2 §2 |
| lane drop on failure | NO (return 1 only) | contract — dropping is the wrapper's/reaper's job |
| `get cdp-url` | FORBIDDEN (use pool_daemon_connected) | P1.M4.T3.S1 §2 — auto-launches strays, always rc 0 |
| naming/placement | `pool_ensure_connected`, APPEND after pool_boot_lane | §6 — public CONTRACT name; pure addition |
