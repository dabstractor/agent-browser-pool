# Research — P1.M5.T1.S2: Post-lock boot (copy + port + launch + connect + update lease)

Date: 2026-07-13. Sources: `lib/pool.sh` (read in full, incl. the LANDED M4.T1.S1 /
M4.T2.S1 / M4.T2.S2 / M4.T3.S1 / M5.T1.S1 functions), `plan/…/P1M5T1S1/PRP.md` +
`research/acquire-flock-critical-section.md` (the S1 CONTRACT this task consumes),
`plan/…/P1M4T2S1|S2/PRP.md`, `PRD.md` §2.4/§2.6/§2.7/§2.8/§2.14. All composed-function
behavior below is quoted from the ACTUAL `lib/pool.sh` source (ground truth), not just the
PRPs.

Host facts VERIFIED this session: `~/.agent-chrome-profiles/master-profile` exists (4.8 GB),
FSTYPE of `~/.agent-chrome-profiles` == **btrfs** (reflink CoW works), `google-chrome-stable`
at `/usr/bin/google-chrome-stable`, `~/.local/bin/agent-browser` (symlink →
`…/agent-browser/bin/agent-browser-linux-x64`), `flock`/`curl`/`jq`/`setsid`/`ss` all present,
`agent-browser --json session list` responds OK.

---

## §0. What pool_boot_lane consumes (the S1 CONTRACT — already LANDED)

`pool_acquire_locked()` (P1.M5.T1.S1, LANDED @2043) returns a **provisionally-claimed** lane
on rc 0. The caller (the wrapper lifecycle M6.T3.S1, and THIS function's eventual caller)
distinguishes provisional-vs-adopted by reading the lease (S1 research §5 / the
`pool_acquire_locked` docstring):

| S1 outcome | lease state | caller action |
|---|---|---|
| provisional CLAIM (§2.4 step 3d) | `port:0, chrome_pid:0, chrome_pgid:0, connected:false` | **THIS task (S2): copy→port→launch→connect→update lease** |
| reuse-orphan ADOPT (§2.4 step 3b) | `port>0, chrome_pid>0, connected:true` | S3: skip boot; just `ensure_connected` |
| no free lane | (no lease) | M5.T4 exhaustion |

**So `pool_boot_lane(LANE)` is invoked ONLY for a PROVISIONAL lease** (port:0). It must turn
that provisional lease into a fully-provisioned lane: Chrome running + daemon connected +
lease complete. Return 0 on success, 1 on failure (lane cleaned up). The lane number N is the
sole argument. (This task implements `pool_boot_lane`; the provisional-vs-adopted BRANCHING
that decides whether to call it is the wrapper's job — M6.T3.S1. This task is the boot body.)

> NOTE on the parallel-execution context: S1 was "Implementing" when this research ran and is
> now LANDED (verified: `_pool_release_lane_internals` @1813, `_pool_adopt_lane` @1892,
> `_pool_acquire_critical_section` @1966, `pool_acquire_locked` @2043 all present). So this
> task can rely on S1's outputs as a hard contract — including the **private release kernel
> `_pool_release_lane_internals(LANE)`** (see §6).

---

## §1. The composed-function contract table (rc conventions + signatures — HOST-VERIFIED)

`pool_boot_lane` composes SEVEN already-landed primitives. Their exact rc conventions (read
from `lib/pool.sh` source) are:

| function (LANDED @line) | args | returns | fatal? | pool_boot_lane role |
|---|---|---|---|---|
| `pool_copy_master` @1253 | `target_dir` (ABS) | **0** ok | **pool_die** on non-btrfs/no-slow-copy/bad args | step a. COPY (reflink CoW) |
| `pool_find_free_port` @1376 | (none) | **0** echoes port / **1** range exhausted | NON-fatal | step b. PORT |
| `pool_chrome_launch` @1471 | `port` `user_data_dir` `lane` | **0** | **pool_die** on bad args / **instant exit** / missing log dir; sets globals `POOL_CHROME_PID`/`POOL_CHROME_PGID` via `declare -g` | step c. LAUNCH |
| `pool_wait_cdp` @1570 | `port` | **0** CDP ready / **1** timeout (**and KILLS the chrome pgroup on timeout**) | NON-fatal | step d. WAIT |
| `pool_daemon_connect` @1631 | `session` `port` | subprocess rc (**0** bound / **1** dead port) | NON-fatal | step e. CONNECT |
| `pool_lease_update` @763 | `lane` `field` `value` | 0 | **pool_die** on missing/corrupt lease or non-JSON value; **TOP-LEVEL field only** | steps b + c + f. UPDATE LEASE |
| `_pool_release_lane_internals` @1813 (S1) | `lane` | **always 0** (idempotent, non-fatal) | NON-fatal | ALL failure-path cleanup |

Plus `pool_chrome_kill` @1757 (called indirectly via `_pool_release_lane_internals`):
idempotent, handles 0/0, rc 0 always.

**Key rc-convention facts (each HOST-VERIFIED by reading the source):**

1. **`pool_find_free_port` rc 1 = NON-FATAL exhaustion.** "return 1 if the whole range is
   occupied … recoverable; caller → M5.T4 exhaustion flow." A bare `PORT="$(pool_find_free_port)"`
   ABORTS under `set -e` on rc 1 → MUST guard: `if PORT="$(pool_find_free_port)"; then …`.
2. **`pool_chrome_launch` pool_die's on INSTANT exit** (Chrome died before its pgroup could be
   read): `pool_die "pool_chrome_launch: Chrome (pid $PID) exited immediately; see log: $log_file"`.
   This calls `exit 1` (pool_die @30) → exits the WHOLE process. It is NOT catchable in a normal
   function call (no subshell). It is FATAL — the contract's "retry once" does NOT cover this
   case (see §3). On SUCCESS it sets the globals `POOL_CHROME_PID=$!` and
   `POOL_CHROME_PGID="$(ps -o pgid= -p $! …)"` via `declare -g` (lines 1514/1528).
3. **`pool_wait_cdp` KILLS the chrome pgroup on timeout THEN returns 1.** Source (lines
   1584–1588): on timeout, `if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then kill --
   -"$POOL_CHROME_PGID" …; fi; return 1`. **So when wait_cdp returns 1, the Chrome is ALREADY
   DEAD** (pgroup signalled). The retry just re-launches (overwrites the globals). This is the
   single most important behavioral fact for the retry flow.
4. **`pool_daemon_connect` rc 1 = NON-FATAL** (dead port / unreachable). "Prints '✗ All CDP
   discovery methods failed … Connection refused' and exits 1. It does NOT launch anything."
   Guard: `if pool_daemon_connect …; then …`.
5. **`pool_lease_update` is TOP-LEVEL FIELD ONLY + pool_die's on a missing/corrupt lease.**
   Value is spliced as raw JSON via `--argjson v "$value"` → numbers, `true`/`false`,
   `'"str"'`. So `connected` MUST be the literal string `true` (not `1`/`True`). The lease
   MUST already exist (it does — provisional from S1). Each call = one read-modify-write
   (tmp+mv atomic); calling it N times for N fields is N atomic publishes (benign intermediate
   states — the lane is mid-boot and owned by us).
6. **`_pool_release_lane_internals(LANE)` reads `chrome_pid`/`chrome_pgid` from the LEASE**
   (lines 1813–1828: `mapfile -t _f < <(jq -r '.chrome_pid, .chrome_pgid, .ephemeral_dir' …)`),
   then `pool_chrome_kill` (idempotent) + guarded `rm -rf "$POOL_EPHEMERAL_ROOT/$lane"` +
   `rm -f "$POOL_LANES_DIR/$lane.json"`. Returns 0 always. **This means cleanup correctness
   depends on the lease holding the chrome identity — see §2.**

---

## §2. THE central gotcha: chrome identity lives in GLOBALS, not the lease, during the boot

`pool_chrome_launch` sets `POOL_CHROME_PID` / `POOL_CHROME_PGID` as **global variables**
(`declare -g`). The contract (step f) writes them to the **lease** only at the very END.
**This creates a chrome-LEAK hazard on every mid-boot failure path:**

| failure point | chrome state | lease `chrome_pid` at that moment | if cleanup reads the lease… |
|---|---|---|---|
| step b (port exhaustion) | none launched | 0 (provisional) | ✓ no-op kill — correct |
| step d (wait_cdp timeout) | **already killed** by wait_cdp (§1.3) | 0 (not written yet) | ⚠ kill 0 = no-op — OK only because chrome is ALREADY dead |
| step e (daemon_connect fail) | **ALIVE** (CDP answered!) | 0 (not written yet) | ✗ **LEAKS** — `pool_chrome_kill 0 0` is a no-op, the live Chrome is never killed |

**Resolution (this PRP mandates): write `chrome_pid` + `chrome_pgid` to the lease
IMMEDIATELY after EACH successful launch (right after step c), not only at step f.** This is a
deliberate, justified refinement of the contract's step ordering. It delivers THREE wins:

1. **Correct cleanup on EVERY failure path.** After the early write, `_pool_release_lane_internals
   "$lane"` reads the real `chrome_pid` and kills the (live or already-dead) Chrome correctly.
   The step-e daemon_connect-fail LEAK is eliminated.
2. **Reaper robustness.** If `pool_boot_lane` is killed (SIGKILL / segfault / OOM-kill) after
   launch but before step f, the lazy reaper (PRD §2.10, M5.T3.S1) reads the lease, finds the
   real `chrome_pid`, and tears down the Chrome. WITHOUT the early write the chrome_pid would
   be 0 → the reaper cannot kill it → **a permanent Chrome leak** until manual cleanup.
3. **Uniform cleanup = DRY.** A single `_pool_release_lane_internals "$lane"` call serves all
   failure paths; no bespoke "kill via globals" cleanup is needed.

**The lease's FINAL state is unchanged** — at step f the lease still ends with
`{port, chrome_pid, chrome_pgid, connected:true, last_seen_at}` all correct, exactly as the
contract specifies. The early write only changes WHEN `chrome_pid`/`chrome_pgid` first appear
(after launch vs. at the end), not the final value. port is likewise written early (step b) —
already mandated by the contract for the anti-collision reason in §4.

**Retry interaction (verified correct):** on the wait_cdp-timeout retry, `pool_chrome_launch`
is called a SECOND time, overwriting the globals, and the early write overwrites
`chrome_pid`/`chrome_pgid` in the lease with the 2nd Chrome's identity. So after a failed retry,
`_pool_release_lane_internals` reads the 2nd Chrome's pid (already killed by the 2nd wait_cdp
per §1.3) — correct. No stale 1st-chrome pid lingers in the lease past the retry's write.

---

## §3. "Retry launch once" applies to the CDP-TIMEOUT case, NOT the instant-exit case

The contract research note + PRD §2.14 ("Chrome slow to boot | /json/version timeout | retry
launch once; then fail, drop lane") tie the retry specifically to the **`/json/version`
timeout** — i.e. `pool_wait_cdp` rc 1. The instant-exit case is handled by `pool_chrome_launch`
itself via `pool_die` (§1.2), which is FATAL and propagates (it surfaces Chrome's stderr log
path — a genuine misconfiguration / broken-binary signal that should NOT be silently retried).

**Why the boot cannot catch the instant-exit pool_die:** pool_die calls `exit 1` (line 32). To
catch it without process death you'd run `pool_chrome_launch` in a subshell — but then the
`declare -g POOL_CHROME_PID/PGID` writes happen INSIDE the subshell and do NOT propagate out
(subshell variable scope). So the boot would launch a Chrome, lose its pid, and be unable to
ever kill it — strictly worse than letting the pool_die propagate. **Decision: let
`pool_chrome_launch`'s pool_die propagate.** It is exceptional (rare), it prints the log path,
and the provisional lease left behind (port possibly set, chrome_pid 0) is self-healing: the
owner process is now dead → the next acquire's REAP-STALE (S1 step 3a) reaps it.

So the retry flow is EXACTLY: `pool_chrome_launch` (0 or pool_die) → write chrome-ids to lease
→ `pool_wait_cdp` (0 or 1-with-chrome-killed) → on 1, repeat once → on second 1, cleanup +
return 1.

---

## §4. Step b: write port to the lease IMMEDIATELY (anti-collision)

`pool_find_free_port` (M4.T2.S1) builds a claimed-port set by scanning `lanes/*.json` for
`.port` (skipping port≤0 / non-numeric, so provisional port=0 claims do NOT reserve a port).
Two concurrent acquires run their boots OUTSIDE the flock (FINDING 2), so both call
`pool_find_free_port` nearly simultaneously. **If a boot does not write its chosen port back
to the lease before the other boot's `pool_find_free_port` runs, both can pick the SAME port.**

The contract explicitly says step b: "PORT=$(pool_find_free_port). **Update lease port.**" —
this update IS the anti-collision mechanism. Write `port` to the lease right after selecting
it (before launch), shrinking the TOCTOU window to a few µs. TOCTOU is still tolerated
(OUTSIDE the flock; `pool_chrome_launch` is the authoritative bind), but the early write makes
the common case collision-free. (This is why step b is split from step f rather than batching
all five fields at the end.)

---

## §5. `set -euo pipefail` + the `local var=$(...)` errexit-masking gotcha (BashFAQ 105)

`lib/pool.sh` line 17: `set -euo pipefail`. EVERY command-substitution capture in
`pool_boot_lane` MUST be split into two statements, because `local x="$(…)"` masks errexit
(`local` is a command that always returns 0, so a failing `$(…)` does NOT trigger `set -e`):

```bash
local PORT              # declare FIRST
PORT="$(pool_find_free_port)"    # assign SECOND — now errexit propagates on rc 1
```

This applies to: `PORT="$(pool_find_free_port)"`, `now="$(_pool_now)"`, and any
`pool_lease_field` reads. (SC2155 in shellcheck flags this; the codebase convention is
two-statement form throughout — see `pool_chrome_launch` @1520 `pgid="$(…)" || true`.)

The NON-FATAL rc-1 helpers (`pool_find_free_port`, `pool_wait_cdp`, `pool_daemon_connect`)
must be guarded with `if …; then …; else <cleanup>; return 1; fi` — a bare call ABORTS the
caller under `set -e` on rc 1. `_pool_release_lane_internals` always returns 0, so it needs no
guard.

---

## §6. Cleanup = `_pool_release_lane_internals "$lane"` for EVERY failure path

The S1 private kernel (LANDED @1813) does exactly what the contract's failure clauses require
("delete lease, rm dir" / "kill Chrome, delete lease, rm dir"):

- reads `.chrome_pid .chrome_pgid .ephemeral_dir` from the lease (ONE jq fork);
- `pool_chrome_kill "$cpid" "$cpgid"` (idempotent — handles 0/0, already-dead, live);
- guarded `rm -rf "$POOL_EPHEMERAL_ROOT/$lane"` (prefix-guard — NEVER trusts a lease path);
- `rm -f "$POOL_LANES_DIR/$lane.json"` (the lease file);
- returns 0 always (idempotent, non-fatal).

Thanks to §2's early chrome-id write, this single call correctly handles ALL failure points:

| failure point | chrome state | `_pool_release_lane_internals` does | result |
|---|---|---|---|
| step b (port exhaustion) | none | `pool_chrome_kill 0 0` (no-op) + rm copied dir + delete lease | ✓ clean |
| step d (wait_cdp 2nd timeout) | already killed by wait_cdp | kill already-dead (no-op via `\|\| true`) + rm dir + delete lease | ✓ clean |
| step e (daemon_connect fail) | ALIVE | kill the live Chrome (chrome_id in lease from §2) + rm dir + delete lease | ✓ clean, NO LEAK |

The ONLY failure paths that do NOT reach `_pool_release_lane_internals` are the FATAL
`pool_die`s (`pool_copy_master` non-btrfs; `pool_chrome_launch` instant-exit) — those `exit 1`
the whole process and leave a provisional lease that the reaper self-heals on the next acquire.

**`pool_boot_lane` therefore never writes its own `rm -rf` / `kill`** — it delegates 100% of
teardown to `_pool_release_lane_internals`. No duplication, no rm-rf guard to re-implement.

---

## §7. How to test each path (HOST-VERIFIED feasible — no mocking needed)

| scenario | setup | assertion |
|---|---|---|
| **happy path** | real master (4.8 GB btrfs), real chrome, real agent-browser; call `pool_boot_lane 1` on a fresh provisional lease | rc 0; lease has `port>0, chrome_pid>0, connected==true`; `curl /json/version` answers; `agent-browser --session abpool-1 --json session list` includes abpool-1; 1 chrome pgroup alive |
| **port exhaustion** | `AGENT_CHROME_PORT_RANGE=1` + pre-claim that one port in another lease → `pool_find_free_port` rc 1 | rc 1; NO chrome process spawned; ephemeral dir removed; lease file deleted |
| **wait_cdp double-fail** | occupy the selected port with a listener (`python3 -m http.server` / `nc -l`) so Chrome's debug port can't bind → `/json/version` never answers → `pool_wait_cdp` times out twice | rc 1; 0 chrome pgroups left (killed by wait_cdp + cleanup); dir + lease gone |
| **daemon_connect fail** | `AGENT_BROWSER_REAL=/nonexistent/binary` → `pool_daemon_connect` rc 1 (Chrome launched + CDP ready, but connect subprocess fails) | rc 1; the LIVE chrome is KILLED (no leak — proves §2's early write); dir + lease gone |
| **robustness (early chrome_id write)** | after a successful launch but BEFORE step f, inspect the lease | `chrome_pid>0, chrome_pgid>0` already present (reaper-safe) |

**Cleanup of test Chromes:** each scenario ends with `pgid=$(ps -o pgid= -p <pid>|tr -d ' ')`;
`kill -9 -- -"$pgid"`; `agent-browser --session abpool-N close`. Run in an ISOLATED
`AGENT_BROWSER_POOL_STATE` (mktemp -d) + `AGENT_CHROME_EPHEMERAL_ROOT` (mktemp -d) so the real
pool state is never touched.

---

## §8. Decisions summary (what the PRP encodes)

1. **`pool_boot_lane(LANE)`** — one PUBLIC function (the CONTRACT name), append after
   `pool_acquire_locked` (current EOF @2055). Plus up to two PRIVATE `_pool_*` helpers
   (`_pool_launch_and_verify` for the launch+cdp+retry sub-flow; optionally
   `_pool_boot_write_chrome_ids` to DRY the chrome-id write across the retry). Pure append; no
   existing function touched.
2. **Write chrome_pid/chrome_pgid to the lease right after EACH launch** (§2) — robustness +
   uniform cleanup. Documented as a justified refinement of the contract's step-f ordering.
3. **Retry = the wait_cdp-timeout case only** (§3); instant-exit pool_die propagates (fatal).
4. **Step b writes port early** (§4 anti-collision); step f writes `connected:true` +
   `last_seen_at` (port + chrome_ids already set). Final lease state == contract.
5. **ALL failure cleanup = `_pool_release_lane_internals "$lane"`** (§6) — no bespoke rm/kill.
6. **Every `local` capture split** (§5); every non-fatal rc-1 helper guarded with `if`.
7. **NO new env vars, NO new files, NO new globals exported** (reads `POOL_EPHEMERAL_ROOT`,
   `POOL_LANES_DIR`, `POOL_REAL_BIN`, and the `POOL_CHROME_PID/PGID` globals set by
   `pool_chrome_launch`).
