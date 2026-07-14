# Bug Fix Requirements

## Overview

End-to-end validation of the `agent-browser-pool` implementation against the original
PRD, performed as **static analysis + isolated, timeout-bounded micro-checks** (per
AGENTS.md §1/§2 — no real Chrome, no daemon, no live test suite was launched against
the shared sandbox; only pure functions and lease I/O were exercised under a throwaway
temp `$HOME`).

**Overall assessment:** The implementation is exceptionally well-engineered and
thoroughly documented. The pure-function layer (command dispatch, arg normalization,
session stripping, lease JSON I/O, staleness detection, admin status/reap/release/
doctor) is correct and robust under `set -euo pipefail` — verified by 64 isolated
micro-assertions, all passing. However, several issues were found that affect
documented behavior, concurrency robustness, and the cutover safety valve.

**Method:** `bash -n` + `shellcheck -S warning` (clean) on all files; full read of
`lib/pool.sh` (4424 LOC), `bin/*`, `install.sh`, and all test files; isolated
micro-checks of `pool_dispatch_classify`, `pool_normalize_close/connect`,
`pool_strip_session_args`, `_pool_clean_args_is_bare_connect`, `pool_lease_*`,
`pool_find_free_lane`, `pool_lane_is_stale`, and the four `pool_admin_*` commands
against a temp state dir (no Chrome). Runtime-dependent paths (Chrome launch, daemon
connect/close, CDP probes) were analyzed by code reading and are flagged with their
confidence level.

---

## Critical Issues (Must Fix)

None rise to "prevents core functionality in the common case" — the happy path
(acquire → boot → drive → release) is sound. The issues below are Major (should fix).

---

## Major Issues (Should Fix)

### Issue 1: Boolean env vars only honor the literal `"1"` — contradicts README and the code's own `--help`
**Severity**: Major
**PRD Reference**: §2.11 (configuration env vars), §2.17 (safety valve
`AGENT_BROWSER_POOL_DISABLE`), §2.6 (`AGENT_CHROME_HEADLESS`), §2.7
(`AGENT_CHROME_ALLOW_SLOW_COPY`)
**Confidence**: High — verified by isolated micro-check (truth table below).

**Expected Behavior**: Setting a boolean env var to a truthy value such as `true` or
`yes` (as the README and `agent-browser-pool help` explicitly advertise) should enable
the feature.

**Actual Behavior**: `_pool_config_bool` (`lib/pool.sh:82-84`) treats ONLY the exact
string `"1"` as ON; every other value — including `true`, `yes`, `on`, `TRUE`, `Yes`,
and even `0`-vs-`true` distinctions — is silently normalized to OFF (`0`):

```bash
_pool_config_bool() {
    local val="${1:-}"
    if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
}
```

Verified truth table:
```
input=''    -> 0     input=1    -> 1     input=0    -> 0
input=true  -> 0     input=yes  -> 0     input=on   -> 0
input=TRUE  -> 0     input=Yes  -> 0
```

This is consumed by `pool_config_init` (`lib/pool.sh:172-174`) for all three boolean
globals (`POOL_HEADLESS`, `POOL_DISABLE`, `POOL_ALLOW_SLOW_COPY`), and each consumer
gate checks `== "1"` exclusively (`lib/pool.sh:1515`, `:242`, `:1295`, `:4222`,
`:3491`).

**The contradiction** (documentation promises a contract the code does not fulfill):
- `README.md:218` — `AGENT_CHROME_HEADLESS`: "set to `1`/`true`/`yes` to launch Chrome
  with `--headless=new`".
- `lib/pool.sh:4418` (`pool_admin_help`) — `AGENT_CHROME_HEADLESS`: "launch Chrome
  headless if set (1/true/yes)".
- `lib/pool.sh:4419-4420` (`pool_admin_help`) — `AGENT_CHROME_ALLOW_SLOW_COPY` and
  `AGENT_BROWSER_POOL_DISABLE`: "… if set" (implies any non-empty value works — false).

**Impact (most severe for the cutover safety valve):**
- `AGENT_BROWSER_POOL_DISABLE=true` (a natural choice that matches the documented
  `1`/`true`/`yes` form) does **NOT** disable pooling. PRD §2.17 states this valve is
  the **only** per-session opt-out during cutover and that an installed wrapper
  "silently intercepts" running agents' `agent-browser` calls — "This breaks running
  work." An operator who follows the documented truthy form during cutover believes
  they are bypassing the pool when they are not.
- `AGENT_CHROME_HEADLESS=true` on a headless/server host produces **windowed** Chrome
  (no `--headless=new`), which fails to display on a host with no compositor — exactly
  the unattended scenario PRD §2.18 says headless is for.
- `AGENT_CHROME_ALLOW_SLOW_COPY=true` on a non-btrfs host still **refuses** the copy
  (`pool_die`), defeating the documented escape hatch.

**Steps to Reproduce**:
```bash
source lib/pool.sh
# HEADLESS
AGENT_CHROME_HEADLESS=true bash -c 'source lib/pool.sh; pool_config_init; echo "POOL_HEADLESS=$POOL_HEADLESS"'
# -> POOL_HEADLESS=0   (expected 1 per README "1/true/yes")
# DISABLE
AGENT_BROWSER_POOL_DISABLE=true bash -c 'source lib/pool.sh; pool_config_init; echo "POOL_DISABLE=$POOL_DISABLE"'
# -> POOL_DISABLE=0    (pooling STILL ACTIVE — safety valve did not engage)
```

**Suggested Fix**: Either (a) make `_pool_config_bool` accept the common truthy set
(`1`, `true`, `yes`, `on`, case-insensitive) so the documented contract holds — this is
the safer choice given PRD §2.17's emphasis on the disable valve; or (b) correct
`README.md:218` and `lib/pool.sh:4418` to state that only the literal `1` is accepted
(and tighten the `pool_admin_help` "if set" wording for DISABLE/ALLOW_SLOW_COPY).
Option (a) is recommended because the disable valve is cutover-critical and users will
reach for `true`.

---

### Issue 2: Concurrent port allocation has an unmitigated race; the documented "retries on EADDRINUSE" mitigation is inaccurate
**Severity**: Major
**PRD Reference**: §1.3 Goal 3 (mutual exclusion — no two agents share a Chrome), §2.4
step 3f (port allocation), §2.18 (concurrency harness: "N parallel agents must each get
a distinct lane … all release cleanly"), §2.19 (keep the flock section short — boot
after lock release)
**Confidence**: High on the code path; the exact failure mode (instant-exit vs 30s
timeout) depends on Chrome's EADDRINUSE behavior, but **both** paths lead to a fatal
failure for the colliding agent (see analysis).

**Expected Behavior**: N agents acquiring lanes concurrently must each get a distinct,
usable port; if two momentarily race onto the same free port, the implementation
gracefully recovers (re-picks a different port) rather than crashing an agent.

**Actual Behavior**: `pool_find_free_port` (`lib/pool.sh:1383`) runs **outside** the
acquire flock (deliberately, per §2.19, so concurrent boots parallelize). Its only
anti-collision mechanism is "write the chosen port to the lease before launch"
(`pool_boot_lane` step b, `lib/pool.sh:2225`) so *later* `pool_find_free_port` callers
see it claimed. But there is a residual race window between a caller's
`pool_find_free_port` read and its lease write — **two concurrent acquires can both
select the same free port** before either has written it. The code acknowledges this:

> `lib/pool.sh:1377-1378` — "TOCTOU tolerated: runs OUTSIDE the flock … two acquires
> can both pick the same port — the launch (M4.T2.S2) is authoritative + retries on
> EADDRINUSE."

**The stated mitigation is inaccurate.** The "launch retries on EADDRINUSE" claim does
not hold up against the actual code:
1. `pool_chrome_launch` (`lib/pool.sh:1478`) does **not** retry on a bind failure. If
   Chrome exits immediately (which a port-in-use `--remote-debugging-port` can cause),
   the `pgid` capture is empty and the function does `pool_die` — a **FATAL** abort of
   the wrapper process (`lib/pool.sh:1530-1533`):
   ```bash
   if [[ -z "$pgid" ]]; then
       kill "$POOL_CHROME_PID" 2>/dev/null || true
       pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately; see log: $log_file"
   fi
   ```
2. If Chrome instead stays up but fails to expose CDP on the colliding port,
   `pool_wait_cdp` times out (30s), kills the pgroup, and returns 1; `_pool_launch_and_verify`
   (`lib/pool.sh:2123`) then **retries with the SAME port** (`lib/pool.sh:2150` —
   `_pool_launch_and_verify "$port" …`, `$port` unchanged). The retry hits the same
   collision → second 30s timeout → `pool_boot_lane` calls `_pool_release_lane_internals`
   and returns 1 → `pool_wrapper_main` does `pool_die` (`lib/pool.sh:3515`).
3. At no point does the boot path **re-pick a different port** after a collision.

Either path ends in a fatal crash for one of the two concurrently-acquiring agents —
violating PRD §2.18's "all release cleanly" and §1.3's mutual-exclusion/no-collision
contract under genuine concurrent load.

**Evidence the race is known and only mitigated in the test, not the implementation:**
the concurrency test deliberately staggers launches to avoid it:
> `test/concurrency.sh:264` — `sleep 0.3   # narrow the pool-allocation TOCTOU (research G2)`
> `test/concurrency.sh:247` — "A ~0.3s stagger narrows the pool_find_free_port TOCTOU
> window (port is written to the lease BEFORE launch → later find_free_port calls see
> it claimed)."

So the implementation passes its own concurrency test **only because the test staggers
by 0.3s**; real concurrent agents (no stagger) can collide.

**Steps to Reproduce** (conceptual; requires real Chrome, so not run here per AGENTS.md):
Two `pi` agents invoke `agent-browser open <url>` within the same ~millisecond window
(before either's `pool_boot_lane` writes its port to the lease). Both `pool_find_free_port`
calls return the same lowest free port (e.g. 53420). Both launch Chrome on 53420. One
Chrome fails to bind → that agent's `agent-browser open` exits non-zero with a
`pool_die` (instant-exit) or a ~60s hang-then-fatal (two 30s CDP timeouts).

**Suggested Fix**: Make the boot path resilient to a lost port race, e.g.:
- On `_pool_launch_and_verify` failure where the cause is plausibly EADDRINUSE, **re-run
  `pool_find_free_port`** (excluding the current port) and retry launch with a *new*
  port before giving up; or
- Move the port selection (or at least the port→lease claim) **inside** the acquire
  flock so two concurrent acquires can never select the same port (the ~instant
  `flock`+scan is cheap; the expensive Chrome launch still happens post-lock); or
- Have `pool_chrome_launch` detect a bind failure from Chrome's log and signal
  "retry-with-different-port" instead of `pool_die`.
At minimum, correct the stale "retries on EADDRINUSE" comment so the gap is not hidden.

---

### Issue 3: `close` then next driving command may skip a needed daemon rebind (transparency risk)
**Severity**: Major (confidence: **medium — requires runtime verification** against real
`agent-browser` + Chrome; the code path is clear, but whether it manifests depends on
agent-browser's auto-rebind behavior, which I could not exercise without launching
Chrome per AGENTS.md)
**PRD Reference**: §2.4 step 4 (ENSURE CONNECTED — "reconnect if daemon died"), §2.5
("close = disconnect-only; next call reuses the same browser"), §2.15 (transparency —
"the agent cannot tell pooling is happening" / must never see failures)

**Expected Behavior**: After an agent runs `agent-browser close` (disconnect-only), its
very next driving command (`open`, `click`, …) reuses the same browser and **succeeds**
— the pool re-binds the daemon to the still-running Chrome if needed (PRD §2.4 step 4).

**Actual Behavior**: `pool_daemon_connected` (`lib/pool.sh:1696`) decides "connected"
using two read-only probes: (1) is the session in `--json session list`, and (2) does
the Chrome answer `curl /json/version`. Its own docstring admits:
> `lib/pool.sh:1726-1729` — "a session LINGERS in the list after a disconnect-only
> close, so 'in list' ≠ 'currently bound'. … the only imprecise case is right after a
> close (lingering session + still-alive chrome → returns 0). Per PRD §2.8 that is
> INTENDED ('next call reuses the same browser')."

After an agent's `close`, both probes still pass (session lingers; Chrome alive) →
`pool_daemon_connected` returns 0 → `pool_ensure_connected` (`lib/pool.sh:2306`)
**skips the `pool_daemon_connect` rebind** (the `if pool_daemon_connected …; then …
return 0` early-exit at `lib/pool.sh:2348-2351`). The wrapper then `exec`s the driving
command with `AGENT_BROWSER_SESSION=abpool-<N>` against a daemon whose binding was just
detached by `close`.

This **diverges from PRD §2.4 step 4's literal design** ("`get cdp-url` || `connect`
— reconnect if daemon died"): the implementation's probe cannot distinguish "bound"
from "lingering-after-close," so it may skip a reconnect that the PRD's design would
have performed. Whether the exec'd driving command then *works* depends entirely on
whether `agent-browser` auto-rebinds a closed session to a live Chrome on a driving
command — behavior I could not verify statically. If it does not auto-rebind, the
agent sees a spurious failure on the command immediately following a `close`,
violating PRD §2.15's "no idea" contract.

**Steps to Reproduce** (requires real Chrome — not run here):
1. Under a `pi` agent (or `AGENT_BROWSER_POOL_OWNER_PID` override + headless Chrome),
   run `agent-browser open about:blank` → lane N acquired/connected.
2. Run `agent-browser close` → daemon disconnects (session lingers; Chrome alive).
3. Immediately run `agent-browser open about:blank` again.
4. Observe: does step 3 succeed (reuses browser) or fail (daemon not re-bound)?
   - The wrapper's `pool_ensure_connected` will **not** call `pool_daemon_connect`
     between steps 2 and 3, because `pool_daemon_connected` returns 0 (lingering
     session + alive chrome).

**Suggested Fix**: Make `pool_ensure_connected` robust to the post-close case. Options:
- After the wrapper intercepts/scopes a `close` (it already strips `--all` and forces
  the session), mark the lease `connected=false` so the next call's
  `pool_ensure_connected` takes the reconnect/relaunch branch and re-binds; or
- Replace/augment `pool_daemon_connected`'s session-list probe with a probe that
  actually confirms the daemon *binding* is live (not merely that the session name is
  remembered) — e.g. a side-effect-free driving-equivalent check that fails after
  `close`; or
- Have `pool_ensure_connected` always (cheaply) re-`connect` when the last command was
  a `close` (track via lease `connected` flag, flipped to false by the close path).
Confirm against real `agent-browser` whether driving commands auto-rebind; if they do,
this is a non-issue and the docstring's "INTENDED" claim stands — but that should be
verified, not assumed.

---

## Minor Issues (Nice to Fix)

### Issue 4: Bare `agent-browser` (no command / only flags) boots a full Chrome for a no-op/help invocation
**Severity**: Minor
**PRD Reference**: §2.4 step 0 (dispatch), §2.15 (transparency / no surprises), §2.18
("the main interactive pi is long-lived → every test must release/reap")
**Confidence**: High — verified by isolated micro-check (`pool_dispatch_classify` with
no args returns `"driving"`).

**Expected Behavior**: A bare `agent-browser` invocation (no subcommand) — which
upstream treats as a help/usage request — should not silently acquire a lane and boot
Chrome.

**Actual Behavior**: `pool_dispatch_classify` (`lib/pool.sh:3085-3091`,
`:3104-3110`) returns `"driving"` when no non-flag command token is present (the
"everything else → driving" default, contract steps c & d). Consequently, for a `pi`
agent, `pool_wrapper_main` resolves the owner, runs `pool_lease_find_mine`/acquire,
**boots a full Chrome** (CoW copy + launch + CDP wait + daemon connect), then `exec`s
the real binary with no args — which typically just prints help and exits 0. The lane
then **persists** (owner still alive) until the `pi` process exits or an explicit
`release`/`reap`, wasting a Chrome process + ephemeral profile for a help request.

**Steps to Reproduce** (isolated, no Chrome needed for the classification):
```bash
source lib/pool.sh
pool_dispatch_classify        # no args -> prints "driving"  (would boot Chrome under a pi owner)
pool_dispatch_classify --json # only a flag -> prints "driving"
```

**Suggested Fix**: Treat an empty command (no non-flag token) as `meta`/passthrough in
`pool_dispatch_classify` (mirror the `--help` short-circuit), since a subcommand-less
invocation is not a driving action. This also helps the `--session foo`-with-no-command
edge case, which currently has the same effect.

---

### Issue 5: `pool_admin_help` describes `DISABLE` / `ALLOW_SLOW_COPY` as "if set" (misleading given Issue 1)
**Severity**: Minor (documentation)
**PRD Reference**: §2.11, §2.16 (doctor should verify deps at runtime; help is the
admin docs)
**Confidence**: High.

**Expected Behavior**: The admin `--help` accurately describes accepted values.

**Actual Behavior**: `lib/pool.sh:4419-4420`:
```
AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set
AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set
```
"If set" implies any non-empty value engages the feature. Given Issue 1, only the
literal `1` works; `=true`/`=yes` are silently ignored. (This is the same root cause
as Issue 1; listed separately because the fix to the help wording is independent and
trivial.)

**Suggested Fix**: Resolve together with Issue 1 — either accept truthy values, or
state "set to `1`" explicitly in the help text.

---

## Testing Summary

- **Total tests performed**: 64 isolated micro-assertions (all passing) across:
  - `pool_dispatch_classify`: 22 cases (META vs DRIVING, flag forms, `session list`,
    `--help`/`-h`/`--version`, no-args default).
  - Arg normalizers + session strip + bare-connect predicate: 23 cases (`close --all`
    scoping, `connect <port>` stripping, `--session`/`--session=` removal,
    `--session-name` preservation, bare-connect detection).
  - Lease I/O + lane enumeration + staleness: 19 cases (write/read/field/update,
    `find_free_lane` with leases + orphan dirs, `is_stale` for dead/mismatched/corrupt
    owners, atomic/JSON-validity helpers).
  - Admin commands (`status`/`reap`/`release`/`doctor`) on empty, provisional, stale,
    and corrupt-lease pools (incl. exit-code contract for `doctor` returning 1 on
    FAIL>0).
- **Static checks**: `bash -n` clean on all 8 files; `shellcheck -S warning` clean on
  `lib/pool.sh`.
- **Passing**: 64/64 micro-checks; all pure-function and lease-layer behavior matches
  the PRD/task contracts.
- **Failing**: 0 micro-checks fail; the issues above were found by code reading of the
  runtime-dependent paths (Chrome/daemon/CDP) that could not be exercised without
  launching a browser.
- **Areas with good coverage**: command dispatch & arg normalization; lease data model
  & atomic I/O; owner identity / PID-recycling defense (starttime + comm + /proc);
  staleness tri-state semantics; admin CLI (status/reap/release/doctor) including
  corrupt-lease and empty-pool edge cases; `set -euo pipefail` hazard handling
  (split-local captures, `if`-guarded rc-1 helpers, `(( ))`-in-condition discipline).
- **Areas needing more attention** (runtime-gated, could not be statically confirmed):
  - Concurrent acquire under genuine load (Issue 2) — the existing concurrency test
    staggers by 0.3s and thus does **not** exercise the port-collision race.
  - The `close` → next-command reuse path (Issue 3) — no test asserts that a driving
    command *succeeds* immediately after a `close`; the existing close test
    (`release_reaper.sh`'s `test_close_is_disconnect_only`) is single-owner and checks
    that the lane *survives* close, not that the subsequent command *drives*.
  - Chrome EADDRINUSE / instant-exit behavior feeding into `pool_chrome_launch`'s
    fatal `pool_die` (Issue 2).

**Sandbox-safety note**: No real Chrome, daemon, or the live test suite was launched
against the shared environment. All micro-checks ran under a throwaway `mktemp -d`
`$HOME` with `timeout` bounds and cleaned up afterward; `pgrep` confirmed no
pool-spawned processes were left running. (The `chrome_crashpad_handler` processes
observed during cleanup belong to the operator's own daily-driver Chrome under
`~/.config/google-chrome`, not to this work.)
