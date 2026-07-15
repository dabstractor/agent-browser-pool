# Research — P1.M3.T1.S3: End-to-end Chrome test for the close → rebind path (Issue #3)

> Companion to `../PRP.md`. This is the THIRD and final subtask under P1.M3.T1
> (Issue #3 — close→next-driving-command may skip a needed daemon rebind). **S1**
> (COMPLETE — writes `connected=false` on close in `pool_wrapper_main`) + **S2**
> (CONTRACT — `pool_ensure_connected` reads `.connected` + gates the early-exit)
> are the fix; **S3** (THIS) is the Chrome-dependent END-TO-END test that proves the
> two halves compose: a real `close` (via the WRAPPER) flips `connected=false`, and
> the NEXT `pool_ensure_connected` RE-BINDS the daemon (`connected` false→true)
> instead of trusting the lingering `pool_daemon_connected` probe.
>
> Method: STATIC ANALYSIS ONLY (code reading + grep). No Chrome/daemon/test-suite was
> launched (AGENTS.md §1). All claims below are host-verified against the LANDED code.

---

## 1. WHY the existing `test_close_is_disconnect_only` (release_reaper.sh "test d") does NOT test the rebind

The existing close test (`test_close_is_disconnect_only`) is the sibling, but it does
NOT exercise the S1+S2 fix. Two reasons:

### 1a. It BYPASSES the wrapper → S1's `connected=false` block never fires

`test_close_is_disconnect_only` step (2) invokes close DIRECTLY on the real binary:

```bash
# test/release_reaper.sh:347 (test d)
"$POOL_REAL_BIN" --session "abpool-$N" close >/dev/null 2>&1 || true
```

`$POOL_REAL_BIN` is the REAL `agent-browser` daemon binary (NOT the wrapper
`bin/agent-browser`). S1's close→`connected=false` block lives in **`pool_wrapper_main`**
(`lib/pool.sh:3656-3666`) — the WRAPPER function. Invoking the real binary directly
NEVER enters `pool_wrapper_main`, so S1's block NEVER runs → the lease's `connected`
STAYS `true` after close.

### 1b. With `connected` still `true`, S2's gate lets the stale probe win → NO rebind

`test_close_is_disconnect_only` step (5) calls `pool_ensure_connected "$N"` and asserts
rc 0. But with the lease still `connected=true`:

- S2's gate: `if [[ "$connected" == "true" ]] && pool_daemon_connected …; then … return 0`
- `pool_daemon_connected` returns 0 (the post-close FALSE POSITIVE — the session LINGERS
  in `session list` after a disconnect-only close + Chrome is still alive, per its own
  docstring `lib/pool.sh:1726-1729`).
- → `pool_ensure_connected` EARLY-EXITS at `return 0`. It does **NOT** call
  `pool_daemon_connect`. **No rebind happens.**

So `test_close_is_disconnect_only` passes BOTH before AND after the fix — but it never
proves the daemon was re-bound. **That is exactly the gap S3 closes.**

> KEY DISTINGUISHER: S3 must (1) go THROUGH the wrapper for `close` (so S1 fires), and
> (2) assert the `connected` flag actually transitions `false→true` (the only signal that
> distinguishes "rebind ran" from "early-exit on a lingering probe").

---

## 2. The S3 test design: go THROUGH the wrapper, then assert the rebind

### 2a. Close via the WRAPPER (`pool_wrapper_main`) — the only way to fire S1 end-to-end

To exercise S1's `connected=false` block, `close` MUST run through `pool_wrapper_main`
(the wrapper logic a real agent invokes via `bin/agent-browser`). The test shell already
sources `lib/pool.sh` (via `validate.sh`), so `pool_wrapper_main` is directly available as
a function. Invoking it in a `( … )` SUBSHELL is safe: `pool_wrapper_main` ends in
`exec "$POOL_REAL_BIN" …` (step k, `lib/pool.sh:3686`), which replaces the SUBSHELL's
process; the real `close` runs and exits, and the parent shell continues. This is the SAME
pattern S1's own selftest uses (`test/validate.sh:selftest_close_marks_lease_disconnected`:
`( AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json )`) — the only difference
is S3 does NOT mock `pool_ensure_connected`/`pool_lease_find_mine` (it wants REAL Chrome).

### 2b. Full trace of `( pool_wrapper_main close )` with a pre-booted lane (host-verified against the LANDED code)

With a lane N already booted+owned (via `_release_acquire_boot`), invoking
`pool_wrapper_main close` executes (`lib/pool.sh:3565` onward):

| Step | Code (lib/pool.sh) | Behavior with a pre-booted lane N |
|---|---|---|
| a | `pool_config_init` + `pool_state_init` (3584) | re-resolves globals from env (fine — `AGENT_BROWSER_REAL`→`POOL_REAL_BIN`, temp roots) |
| b | `POOL_DISABLE` check (3589) | not disabled → continue |
| c | `pool_dispatch_classify close` (3597) | `close` is a DRIVING command → "driving" → continue |
| d | `pool_owner_resolve` (3606) | reads `AGENT_BROWSER_POOL_OWNER_PID` (our sim owner) → `POOL_OWNER_PID` = owner |
| e | `pool_lease_find_mine` (3618) | finds lane N (our owner, alive) → REUSE (skip acquire+boot) |
| h | `pool_ensure_connected "$N"` (3640) | `connected=true` (boot set it @2335) → S2 gate `[[ true ]] &&` → `pool_daemon_connected` rc 0 (bound) → EARLY-EXIT. `connected` stays `true`. (No rebind here — correct, the lane IS connected.) |
| i | `pool_normalize_close "$@"` (3650) | writes `POOL_NORM_ARGS` |
| j | `pool_strip_session_args` + `pool_force_session "$N"` (3655) | writes `POOL_CLEAN_ARGS`; exports `AGENT_BROWSER_SESSION=abpool-N` |
| **close block (S1)** | `_pool_clean_args_is_close …` → `( pool_lease_update "$N" connected false )` (3656-3666) | **predicate TRUE** → lease `connected` flipped to JSON `false` ✅ |
| k | `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (3686) | process replaced → real `close` detaches daemon session abpool-N → exits |

**After `( pool_wrapper_main close )` returns, the lease for N has `connected=false`.**
This is the S1 assertion.

### 2c. The NEXT `pool_ensure_connected "$N"` RE-BINDS (the S2 assertion)

Calling `pool_ensure_connected "$N"` directly (the self-heal the wrapper's step h runs
on the agent's NEXT driving command):

1. step a: read lease → `connected=false` (S1 wrote it).
2. S2 gate: `if [[ "$connected" == "true" ]] && pool_daemon_connected …` → `[[ false ]]`
   → short-circuits → **SKIP the early-exit** (the lingering probe is NOT consulted).
3. step c: `curl -sf http://127.0.0.1:$port/json/version` → rc 0 (Chrome STILL ALIVE —
   close is disconnect-only) → RECONNECT branch.
4. `pool_daemon_connect "$session" "$port"` → re-binds the daemon to the still-running
   Chrome → rc 0.
5. `pool_lease_update "$lane" connected true` (`lib/pool.sh:2448`) → `connected` flipped
   back to `true` ✅; `return 0`.

**After `pool_ensure_connected "$N"`, the lease has `connected=true` AND the daemon is
genuinely bound.** This is the S2 assertion.

### 2d. The discriminating assertion: the `connected` false→true transition

The `connected` flag transition is the ONE clean signal that distinguishes "rebind ran"
from "early-exit on a lingering probe":

| Scenario | After wrapper-close | After `pool_ensure_connected` |
|---|---|---|
| **FIX BROKEN** (no S2 gate) | `connected=false` (S1 fired) | S1 not read → `pool_daemon_connected` rc 0 (lingering) → EARLY-EXIT → `connected` STAYS `false`; rc 0 |
| **FIX WORKING** (S1+S2) | `connected=false` (S1 fired) | gate skips early-exit → curl → connect → `connected=true`; rc 0 |

→ Asserting `connected == false` after close AND `connected == true` after
`pool_ensure_connected` is the proof. If the fix is absent/broken, the second assert
FAILS (`connected` stays `false`). Host-verified logic flow.

### 2e. "Genuinely bound" vs "lingering": `pool_daemon_connected` rc 0 after the rebind

After the rebind, `pool_daemon_connected "$session" "$port"` returns 0 because the daemon
IS bound (session re-added to the list by `pool_daemon_connect` + Chrome alive). Before
the rebind (right after close) it ALSO returns 0 — but for the WRONG reason (lingering
session-list entry). The `connected` flag is what disambiguates the two. The test asserts
`pool_daemon_connected` rc 0 AFTER the rebind as a "the binding is live" sanity check; the
`connected false→true` transition is the actual proof the rebind ran.

---

## 3. The single-setup runner + auto-discovery (release_reaper.sh)

### 3a. `_abpool_run_release_reaper_suite` auto-discovers `test_*` functions

```bash
# test/release_reaper.sh:401 (the runner)
for fn in $(compgen -A function | grep '^test_' | sort); do
    printf '== %s\n' "$fn"
    if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
    else          ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2
    fi
    # Inter-body backstop: release any leftover lanes + kill this body's owner.
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _release_kill_owner_and_reap_zombie "$ABPOOL_CUR_OWNER"
    ABPOOL_CUR_OWNER=""
done
```

→ **Adding a new `test_*` function to `release_reaper.sh` is SUFFICIENT** — it is auto-
discovered. There is NO literal "test list" to edit (the item's "add to the test list" ==
"add a `test_*` function"; `compgen` enumerates them). Each body runs via `if "$fn"`
in the MAIN shell (NOT a subshell — so the EXIT trap does NOT fire mid-suite, preserving
the temp root across bodies; a failing assert's `return 1` is the function's rc → FAIL →
suite continues). `setup()` is called EXACTLY ONCE (AGENTS.md §4 — the 3rd `setup()` hangs).

### 3b. The helpers S3 reuses (all LANDED in release_reaper.sh)

- `_release_setup_real_env` (line 60): points `AGENT_BROWSER_REAL`→real daemon binary,
  `AGENT_CHROME_MASTER`→real read-only master, `AGENT_CHROME_EPHEMERAL_ROOT`→btrfs temp
  dir; re-runs `pool_config_init`/`pool_state_init`. **MUST be the first call in the body**
  (validate.sh's `setup()` clobbered `HOME` → `POOL_REAL_BIN` resolves to a NONEXISTENT
  temp path without this). Sets `POOL_REAL_BIN` to the REAL binary (so the wrapper's exec
  runs the real `close`, and `pool_daemon_connect`/`pool_daemon_connected` work).
- `_test_spawn_owner` (line 153): spawns a FRESH live "pi"-comm owner for THIS body, sets
  `ABPOOL_CUR_OWNER`, exports `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`, refreshes the
  `POOL_OWNER_*` globals in the current shell. **MUST run in the CURRENT shell** (NOT via
  `$(…)`) so the owner env + globals propagate to `( pool_wrapper_main close )`.
- `_release_acquire_boot` (line 109): `pool_owner_resolve` → `pool_acquire_locked` →
  `pool_boot_lane`. Boots ONE real headless Chrome. Echoes the lane N; rc 1 on failure.
  After it returns, lane N has `connected=true` (boot step f, `lib/pool.sh:2335`).
- `_release_kill_owner_and_reap_zombie` (line 133): kill + `wait` (reap zombie). Used by
  the runner's backstop; S3's owner is cleaned up by the runner's inter-body backstop.

### 3c. Assertion helpers (LANDED in validate.sh, sourced by release_reaper.sh)

- `assert_eq EXPECTED ACTUAL [LABEL]` — string equality; `_fail`+`return 1` on mismatch.
- `assert_lane_exists N` — `$POOL_LANES_DIR/N.json` present.
- `assert_no_chrome [ROOT]` — `pgrep -f -- "user-data-dir=$ROOT"` (scoped; never false-
  positives on the operator's daily-driver Chrome).
- `_fail MSG` — print FAIL line + `return 1`.
- `pool_lease_field LANE FIELD` (lib primitive) — reads a lease field via
  `jq -r --arg f "$field" 'getpath($f|split("."))'`; `connected` → reads `.connected`;
  renders a JSON boolean as the bare string `true`/`false`. **Use this for the
  `connected` assertions** (`assert_eq "false" "$(pool_lease_field "$N" connected)"`).

---

## 4. Safety / AGENTS.md compliance (this is a REAL-Chrome test)

| AGENTS.md rule | How S3 satisfies it |
|---|---|
| §1 isolated sandbox | `setup()` (ONE call) redirects `HOME`/state/ephemeral to `mktemp -d`; `_release_setup_real_env` re-points master+ephemeral+binary to a btrfs temp dir under the real home (the master is read-only/CoW-safe). |
| §1 NO real Chrome during research | This PRP is research-only (static analysis). The IMPLEMENTER runs the test in the isolated sandbox per §1. |
| §2 hard timeout on every subprocess | `_release_acquire_boot` (boot) is internally bounded (CDP wait, Chrome launch). The `( pool_wrapper_main close )` invocation terminates via `exec` (close is ms-fast). `pool_ensure_connected`'s curl is bounded by Chrome's fast response. **Wrap the wrapper-close + the post-close `pool_ensure_connected` defensively** (see §5). |
| §3 reap what you spawn | The runner's inter-body backstop (`release all` + `_release_kill_owner_and_reap_zombie`) + `teardown()` + the EXIT trap (`_abpool_global_cleanup`) reap Chrome pgroups + owner + temp roots. S3 does NOT spawn extra processes beyond `_release_acquire_boot` + the exec'd `close` (which exits immediately). |
| §4 single-setup runner | `_abpool_run_release_reaper_suite` calls `setup()` EXACTLY ONCE. S3 is ONE body among the `test_*` set. |
| §4 EXIT-trap-in-subshell hazard | bodies run via `if "$fn"` in the MAIN shell (NOT `( … )`) → the trap never fires mid-suite. |
| §4 `kill -0` is a trap | S3 uses `pool_daemon_connected` (curl + session-list) + `assert_no_chrome` (pgrep), NEVER `kill -0`. |

---

## 5. The `( pool_wrapper_main close )` invocation — bounded + safe

`pool_wrapper_main` is a FUNCTION (not a standalone binary), so `timeout` cannot wrap it
directly. Three safe options (any one is acceptable):

1. **Subshell (RECOMMENDED, matches S1's selftest pattern):** `( pool_wrapper_main close ) >/dev/null 2>&1 || true`.
   `pool_wrapper_main` ends in `exec "$POOL_REAL_BIN" …` → the subshell process is REPLACED
   by the real `close` → `close` runs (ms) → exits → subshell done. `|| true` guards any
   non-zero rc (close is rc 0 on agent-browser 0.28.0, but the guard is future-proof).
2. Background + bounded wait: `pool_wrapper_main close & wpid=$!; sleep 0.5; kill …` — heavier,
   not needed (close is fast).
3. A `timeout`-wrapped `bash -c 'source lib/pool.sh; pool_wrapper_main close'` — requires
   re-sourcing + re-resolving env; heavier than option 1.

**Use option 1.** The `exec` makes it terminate deterministically; the only "slow" step
before exec is `pool_ensure_connected`'s curl (bounded by Chrome's ms response). Add a
one-line comment citing AGENTS.md §2.

---

## 6. Naming + placement

- **Name:** `test_close_then_rebind` (the item's primary suggested name; describes the full
  flow). Alternate `test_close_marks_connected_false` is also acceptable, but
  `test_close_then_rebind` captures BOTH the S1 flip AND the S2 rebind.
- **Placement:** a new `test_*` function in `test/release_reaper.sh`, placed directly BELOW
  `test_close_is_disconnect_only` (logical grouping — both are close-semantics tests).
  Auto-discovered by `_abpool_run_release_reaper_suite` (§3a). NO edit to the runner needed.
- **What NOT to touch:** `lib/pool.sh` (S1+S2 own it), `test/validate.sh` (the framework +
  the S1/S2 Chrome-free selftests), other test files, `PRD.md`, `tasks.json`.

---

## 7. Scope guard + dependency on S1+S2

- **DEPENDENCY:** S3 assumes S1 (COMPLETE — `pool_wrapper_main` close block @3656-3666 +
  `_pool_clean_args_is_close` @3792) AND S2 (CONTRACT — `pool_ensure_connected` reads
  `.connected` + the `[[ "$connected" == "true" ]] &&` gate) are LANDED. If S2 is NOT yet
  landed, S3's `connected` stays `false` after `pool_ensure_connected` → the test FAILS
  (correctly — it is testing S2's behavior). The orchestrator sequences S1→S2→S3.
- **S3 is TEST-ONLY:** it adds ONE `test_*` function to `test/release_reaper.sh`. It does
  NOT modify any production code, the framework, other tests, or docs.
- **No conflict with parallel items:** P1.M2.T1.S3 (concurrency.sh) and P1.M4 (docs) are
  disjoint files. S3 touches only `test/release_reaper.sh`.

---

## 8. Open question resolved: does `agent-browser` auto-rebind a closed session on a driving command?

The architecture note (key_findings §ISSUE 3) flagged this as needing runtime verification
("confidence: medium"). S3 RESOLVES it: even if agent-browser DID auto-rebind, the
`connected=false` (S1) + rebind (S2) is HARMLESS (a redundant rebind). If it did NOT
auto-rebind, S1+S2 are REQUIRED (the wrapper's step h `pool_ensure_connected` re-binds
before the exec'd driving command). S3 proves the rebind happens at the POOL layer
(`pool_ensure_connected`), independent of agent-browser's auto-rebind behavior. **No
further research needed** — the test is self-contained.
