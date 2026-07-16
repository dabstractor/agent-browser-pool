# Bug Fix Requirements

## Overview

Creative end-to-end PRD validation of `agent-browser-pool` (`lib/pool.sh`,
`bin/agent-browser-pool`, `install.sh`, the skill, and the test suite). Testing
was performed primarily by static reading + safe, isolated, timeout-bounded
micro-checks (per `AGENTS.md` §1/§2: no real Chrome booted, no shared-sandbox
test runs during analysis). `bash -n` and `shellcheck -s bash -S warning` are
clean on all shell sources.

The implementation is unusually thorough and well-documented. The owner
resolution / starttime parsing (verified correct on this host: field-20-of-remainder
== field-22), the acquire flock/boot split, the atomic lease writes, the BUG-1
identity check on the *acquire* path, the arg-normalization pipeline, and the
exhaustion/alert flow all match the PRD. The standard validation suite
(`validate.sh`, `concurrency.sh`, `transparency.sh`, `release_reaper.sh`) is
broad and exercises the happy paths well.

However, three real defects were found that the existing tests do **not** cover.
The most serious is an isolation violation in the orphan-dir reaper that can
kill *other agents' live Chromes*. The other two are a doctor false-positive and
a defense-in-depth gap on the per-call reconnect path.

**Testing summary:**
- Static: `bash -n` (all sources), `shellcheck -S warning` (clean), full read of
  `lib/pool.sh` (4570 LOC), `bin/agent-browser-pool`, `install.sh`, skill +
  references, all four test files.
- Empirical (safe, timeout-bounded, isolated): verified `_pool_get_starttime`
  correctness; **reproduced** the `pgrep -f` over-match with controlled-argv
  fake-Chrome processes; confirmed substring blast-radius across prefix-numbered
  lanes.
- Areas with good coverage: owner identity/staleness, acquire mutual exclusion,
  release/reap lease-driven teardown, concurrency (distinct lanes), transparency
  (close/connect/--session scoping), atomic writes, btrfs/reflink guard.
- Areas needing attention: the orphan-dir sweep's process matching (Issue 1),
  doctor's optional-dep handling (Issue 2), and identity verification on the
  ensure-connected hot path (Issue 3).

---

## Critical Issues (Must Fix)

None. Core acquire/release/isolation functionality works; the most serious issue
below is recoverable and conditional, so it is classified Major rather than
Critical.

---

## Major Issues (Should Fix)

### Issue 1: `reap` orphan-dir sweep kills *other lanes'* live Chromes (unanchored `pgrep`/`pkill -f`)

**Severity**: Major
**PRD Reference**: §1.3 goal #2 ("1 agent = 1 browser. No two agents ever share a
Chrome"), §1.3 goal #3 ("Mutual exclusion + isolation … one agent cannot reach
another's lane through normal tool use"), §2.10 (reaper), §2.13 ("Isolation by
construction").
**Location**: `lib/pool.sh`, `pool_reap_orphan_dirs()` (the orphan-kill block,
~lines 2895-2899), reachable from `pool_admin_reap()` (line 3959) i.e. the
user-facing `agent-browser-pool reap` command.

**Expected Behavior**: When `reap` sweeps an orphan ephemeral dir (a
`active/<N>/` with no lease), it should kill **only** the orphan's own Chrome
(if any) and remove only that dir. It must never touch a *different* lane's
Chrome.

**Actual Behavior**: The Chrome kill uses an **unanchored** pattern match:

```bash
if pgrep -f -- "user-data-dir=$dir" >/dev/null 2>&1; then
    pkill  -f -- "user-data-dir=$dir" 2>/dev/null || true
    sleep 0.2
    pkill -9 -f -- "user-data-dir=$dir" 2>/dev/null || true
fi
```

where `dir="$POOL_EPHEMERAL_ROOT/$base"` (e.g.
`/home/dustin/.agent-chrome-profiles/active/3`). `pgrep`/`pkill -f` match the
pattern as a **substring** of the full `/proc/<pid>/cmdline`. Because lane
numbers are path components, the pattern for orphan lane **3**
(`user-data-dir=…/active/3`) is a substring of the cmdline for lane **30, 31, …,
39, 300, …** (`…/active/30`, etc.). So the `pkill` **kills every live lane whose
number starts with the orphan's number.**

This was **empirically reproduced** (safe, isolated, fake-Chrome processes with
controlled argv):

```
lane3 : … --user-data-dir=/tmp/abpool_bugtest/active/3 --remote-debugging-port=53423
lane30: … --user-data-dir=/tmp/abpool_bugtest/active/30 --remote-debugging-port=53453

pgrep -af -- 'user-data-dir=/tmp/abpool_bugtest/active/3'
  MATCH: <pid> … active/3 …      <- intended orphan kill
  MATCH: <pid> … active/30 …     <- COLLATERAL: a live, leased lane's Chrome
```

Blast radius (confirmed by substring test): orphan lane `1` + live lanes
`{10..19}` ⇒ up to **10** collateral Chrome kills; orphan lane `3` + live lanes
`{30..39}` ⇒ up to **10** kills; orphan lane `1` even hits lanes `100..199` if
they exist. It triggers in a pool with as few as ~10–20 lanes — exactly the
"unbounded, discoverable pool" (PRD §1.3.5) the tool is built for.

**Impact**: An operator running `agent-browser-pool reap` to clear one crashed
agent's orphan dir silently **kills other agents' mid-task browsers**. Their
leases survive and their ephemeral dirs are untouched, so `pool_ensure_connected`
*relaunches* their Chrome on the next call — but per PRD §2.14 "open tabs lost;
profile kept", those agents lose their in-progress session state (forms, unsaved
work, SPA navigation). This is a direct violation of the isolation guarantee and
is surprising/non-obvious (no log line names the collateral victims). The PRD's
stated invariant "one agent cannot reach another's lane through normal tool use"
is broken by an *operator* action that is supposed to be safe.

**Why the tests miss it**: `selftest_reap_orphan_dirs_removes_and_skips`
(`validate.sh`) only creates empty orphan *dirs* — it never spawns a Chrome
process whose cmdline contains `--user-data-dir=…`. So the `pgrep`/`pkill` branch
is never exercised, and the over-match is invisible. (The lease-driven
`pool_reap_stale` path is safe — it kills by numeric `chrome_pgid` from the
lease, no pattern matching. Only `pool_reap_orphan_dirs` is affected.)

**Steps to Reproduce** (operator-facing, on a pool where lanes 3 and 30 are both
live and lane 3's owner has crashed leaving an orphan dir but the lease was
already deleted):
1. Ensure lane 30 has a live, leased Chrome (an active agent).
2. Create the orphan condition for lane 3 (e.g. manually `rm` its lease while
   leaving its dir + a Chrome running, or simulate a crash between lease-delete
   and dir-remove).
3. Run `agent-browser-pool reap`.
4. Observe (`agent-browser-pool status` / `doctor`) that lane 30's Chrome is now
   dead (state flips to `disconnected`, then relaunches) even though lane 30's
   owner is alive and its lease was never stale.

**Suggested Fix**: Anchor the pattern to the lane-dir boundary. Chrome's cmdline
is `--user-data-dir=<dir>` followed by either a space (next flag) or end-of-line,
so an ERE alternation `( |$)` after the dir defeats the prefix collision while
keeping the same `pgrep`/`pkill` style. For example:

```bash
pat="user-data-dir=$dir( |\$)"
if pgrep -f -- "$pat" >/dev/null 2>&1; then
    pkill    -f -- "$pat" 2>/dev/null || true
    sleep 0.2
    pkill -9 -f -- "$pat" 2>/dev/null || true
fi
```

(Equivalently, match `--user-data-dir=$dir( |$)`. `$dir` is absolute and lane
numbers are validated `^[0-9]+$`, so the regex is injection-safe; the `.` in the
path is a regex metachar but matches itself.) **Add a regression test** that
spawns two fake-Chrome processes on prefix-colliding lane numbers (3 and 30) and
asserts a `reap`/`pool_reap_orphan_dirs` of the orphan kills only lane 3.

---

## Minor Issues (Nice to Fix)

### Issue 2: `doctor` hard-FAILs on a missing `ss`, but `ss` is optional (contradicts its own docstring)

**Severity**: Minor
**PRD Reference**: §2.12 (`doctor`), §2.16 (dependencies), §2.17 (install runs
`doctor`).
**Location**: `lib/pool.sh`, `pool_admin_doctor()` dependencies loop, ~line 4258.

**Expected Behavior**: `doctor` should FAIL only on *blocking* infrastructure
problems. Per its own SEVERITY MODEL docstring, `ss` is **not** blocking: `ss`
(`ss -tlnH`) is used only by `pool_find_free_port`, and its absence "degrades
SILENTLY to a curl-only probe (the `|| true` empty-snapshot path); **no FAIL, no
WARN** → name it so the operator can see the degradation" (docstring lines
~4181-4183).

**Actual Behavior**: The code places `ss` in the **same FAIL loop** as the
genuinely-required deps:

```bash
for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
    if command -v "$dep" >/dev/null 2>&1; then … ok …
    else printf '… MISSING'; fail=$((fail+1))     # <-- hard FAIL
    fi
done
```

So on a host without `ss` (e.g. a minimal container without `iproute2`),
`doctor` prints `ss MISSING`, increments `fail`, and **returns exit 1**
("Problems found."). Since `install.sh` runs `doctor` as its final step, the
install falsely reports "doctor found problems" even though the pool would
operate correctly (port allocation falls back to the `curl`-only probe). This
directly contradicts the function's documented severity model and the inline
comment three lines above the loop.

(`findmnt` *is* genuinely required — `pool_check_btrfs` treats a missing/empty
fstype as non-btrfs and `pool_die`s — so it correctly belongs in the FAIL set.
Only `ss` is over-counted.)

**Steps to Reproduce**: On a host lacking `ss` (e.g. `PATH=/usr/bin:/bin` with
no iproute2, or a stripped image), run `agent-browser-pool doctor`. Output ends
with `FAIL=1` / `Problems found.` and exit code 1, despite the pool being
functional.

**Suggested Fix**: Remove `ss` from the required-deps FAIL loop and report it
separately (like `notify-send`) — e.g. `printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' ss` with no `fail++`. (Optionally also split
out `findmnt` documentation, but keep `findmnt` as a real FAIL.) Keep the `[summary]`
exit code driven only by truly-blocking failures, matching the docstring.

---

### Issue 3: `pool_ensure_connected` reconnect/relaunch paths do not perform the BUG-1 identity check

**Severity**: Minor
**PRD Reference**: §1.3 goal #2 ("1 agent = 1 browser"), §2.4 step 4 (ENSURE
CONNECTED), §2.14 ("Chrome crash mid-task → relaunch"), §2.13 ("Isolation by
construction"). Also the codebase's own `pool_cdp_is_ours` rationale (the
"BUG-1" collision fix).
**Location**: `lib/pool.sh`, `pool_ensure_connected()` — both the **reconnect**
branch (~step c, `curl … && pool_daemon_connect`) and the **relaunch** branch's
`pool_wait_cdp "$port"` call (no identity args).

**Expected Behavior**: Whenever the pool binds the daemon to a Chrome answering
on a lane's port, it should verify the answerer is *this lane's* Chrome — exactly
the protection `pool_cdp_is_ours` / `pool_wait_cdp "$port" "$udd" "$pid"`
provides on the **acquire/boot** path (`_pool_launch_and_verify`). That check was
added specifically because a foreign lane's Chrome can answer `/json/version` on
a port our (EADDRINUSE-killed) Chrome failed to bind.

**Actual Behavior**: `pool_ensure_connected` runs on **every** driving call (the
hot path) but its two binding paths skip the identity check:

- **Reconnect branch**: `if curl -sf …/json/version; then pool_daemon_connect
  "$session" "$port"; fi` — if *anything* answers CDP on `$port`, the daemon is
  rebound to it, with no check that the answerer is this lane's Chrome.
- **Relaunch branch**: `pool_wait_cdp "$port"` is called with a **single**
  argument, so `check_identity=0` inside `pool_wait_cdp` (the identity args are
  omitted) — a foreign Chrome on the port after our relaunch Chrome dies on
  EADDRINUSE would be treated as a successful boot.

**Reachable (narrow) silent-wrong-browser race**:
1. Lane N is booted (Chrome on port P, lease `connected:true`).
2. The `agent-browser` **daemon is restarted** (machine reboot, daemon crash, or
   `agent-browser` upgrade) → it no longer knows session `abpool-N`.
3. Lane N's Chrome also dies (freeing port P).
4. A **foreign** Chrome binds port P (e.g. a manually-launched
   `--remote-debugging-port=P`, or another tool).
5. The agent's next driving call → `pool_ensure_connected`:
   - step b: `pool_daemon_connected(abpool-N, P)` ⇒ session **not** known
     (restarted daemon) ⇒ returns 1 ⇒ early-exit skipped.
   - step c: `curl /json/version` on P ⇒ the **foreign** Chrome answers ⇒
     **reconnect** ⇒ `pool_daemon_connect` binds our daemon to the foreign
     Chrome ⇒ `connected:true`, return 0.
   - `exec agent-browser …` ⇒ the agent now **drives the foreign Chrome** with no
     error — a silent isolation break.

**Why it's Minor**: The trigger requires (a) a daemon restart, (b) our Chrome
dead, and (c) a *foreign* Chrome on our exact port — a narrow conjunction. In
the common case (our Chrome alive, or the port simply free) the path is correct.
But it is a real **inconsistency**: the acquire path was hardened against exactly
this (BUG-1 / `pool_cdp_is_ours`), while the per-call hot path that runs far more
often was not. Given the PRD's emphasis on "1 agent = 1 browser" and "isolation
by construction," the gap is worth closing.

**Why the tests miss it**: The `ensure_connected` self-tests stub
`pool_daemon_connected`/`curl`/`pool_daemon_connect` to fixed return codes; none
simulate a *foreign* Chrome answering on the lane's port, so the identity gap is
never observed.

**Suggested Fix**: On both binding paths, after a successful `curl`/CDP probe,
call `pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"` (reading
`chrome_pid` from the lease) and treat a mismatch as "not ours" (proceed to a
real relaunch / port re-pick rather than binding to the foreign Chrome). For the
relaunch branch, pass the identity args to `pool_wait_cdp`
(`pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"`), mirroring
`_pool_launch_and_verify`. Add a test that stubs `curl` to succeed while the
lease's `DevToolsActivePort`/`chrome_pid` disagree, and asserts the daemon is
**not** bound to the foreign answerer.

---

## Testing Summary

- **Total tests performed**: ~30 distinct checks across static analysis,
  doc-vs-code reconciliation, dispatcher tracing, and isolated empirical
  micro-checks. (The project's own 4-file suite — `validate.sh`,
  `concurrency.sh`, `transparency.sh`, `release_reaper.sh` — was read in full to
  assess coverage; it was *not* executed against the shared sandbox per
  `AGENTS.md` §1.)
- **Passing**: owner identity + starttime parsing (verified correct), acquire
  flock/boot split, atomic lease writes, mutual exclusion / distinct-lane
  allocation, `--session`/`connect`/`close --all` arg scoping, btrfs/reflink
  guard, exhaustion block+force-reap+alert, release/reap lease-driven teardown,
  `bash -n` + `shellcheck -S warning` clean.
- **Failing / defective**: 3 (1 Major, 2 Minor) — see above.
- **Areas with good coverage**: identity/staleness, concurrency, transparency
  normalization, atomic writes, the acquire-path BUG-1 identity check.
- **Areas needing more attention**: orphan-dir process matching (Issue 1 — no
  test spawns a `--user-data-dir=` Chrome), optional-dep severity in `doctor`
  (Issue 2 — no test runs `doctor` on an `ss`-less environment), and
  identity verification on the ensure-connected hot path (Issue 3 — self-tests
  stub the primitives rather than simulating a foreign answerer).

**Notes on scope / non-issues confirmed during testing**:
- `_pool_get_starttime`'s "field-20-of-remainder" parsing is **correct** on this
  host (verified: equals naïve field-22 for no-space `comm`); the PRD §2.19
  "NF-19" note was rightly flagged as wrong by the implementer.
- `agent-browser-pool --version` (and other meta tokens) being *driving*
  (fail-fast without a recognized-harness ancestor, and routing through a lane
  with one) is **intentional and explicitly tested**
  (`test_version_fail_fast_no_pi`, `test_skills_fail_fast_no_pi`) per PRD §2.4
  step 0 — not a defect.
- `release`/`release all` being able to tear down other agents' lanes is
  accepted by the PRD (§2.12 / §2.13: operator-only by convention) — not a defect.
