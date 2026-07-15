# PRP — P1.M3.T1.S3: End-to-end Chrome test for the close → rebind path (Issue #3)

> **Bugfix context**: This is the THIRD and final subtask under **P1.M3.T1** (Issue #3 —
> `close`→next-driving-command may skip a needed daemon rebind; PRD §2.4 step 4 / §2.5 /
> §2.15). **S1** (COMPLETE) writes `connected=false` on close in `pool_wrapper_main`;
> **S2** (CONTRACT — being implemented in parallel) makes `pool_ensure_connected` READ that
> flag and SKIP the lingering `pool_daemon_connected` early-exit so it re-binds. **S3 (THIS)**
> is the Chrome-dependent END-TO-END test proving the two halves compose with REAL Chrome +
> the real `agent-browser` daemon. **S3 is TEST-ONLY**: it adds ONE `test_*` function to
> `test/release_reaper.sh`. It does NOT touch `lib/pool.sh` (S1+S2), `test/validate.sh` (the
> framework + S1/S2 Chrome-free selftests), other test files, or any docs.

---

## Goal

**Feature Goal**: Add a Chrome-dependent integration test that verifies, end-to-end with
real headless Chrome + the real `agent-browser` daemon, that a `close` run **through the
wrapper** marks the lane's lease `connected=false` (S1), and the NEXT `pool_ensure_connected`
call RE-BINDS the daemon to the still-running Chrome (`connected` transitions `false→true`,
S2) — instead of trusting the lingering `pool_daemon_connected` probe and skipping the
rebind (the exact transparency gap Issue #3 describes).

**Deliverable**: ONE new function `test_close_then_rebind` in `test/release_reaper.sh`,
placed directly below `test_close_is_disconnect_only`, auto-discovered by the single-setup
runner `_abpool_run_release_reaper_suite` (it enumerates `test_*` via `compgen`). The test
boots a real lane N, runs `close` through `pool_wrapper_main` (firing S1), asserts
`connected=false`, calls `pool_ensure_connected` (firing S2), asserts `connected=true` +
that the daemon is genuinely bound, and leaves cleanup to the runner's inter-body backstop.

**Success Definition**:
- After a wrapper-driven `close`, the lease's `connected` field is the JSON boolean `false`
  (read via `pool_lease_field "$N" connected` → the string `"false"`) — proving S1's close
  block fired end-to-end through the real wrapper.
- After the subsequent `pool_ensure_connected "$N"`, the lease's `connected` is `true` AND
  `pool_ensure_connected` returns 0 — proving S2 skipped the lingering-probe early-exit and
  re-bound the daemon (the `false→true` transition is the ONLY signal that distinguishes
  "rebind ran" from "early-exit on a lingering probe").
- After the rebind, `pool_daemon_connected "abpool-$N" "$port"` returns 0 — the binding is
  genuinely live (session re-added to the daemon's list by `pool_daemon_connect` + Chrome
  still alive), NOT merely a lingering session-list entry.
- The test passes via `bash test/release_reaper.sh` in the isolated sandbox, with zero
  residual processes, and all pre-existing tests (a/b/c/d) still pass. `bash -n` +
  `shellcheck -S warning` clean on `test/release_reaper.sh`.

## User Persona

**Target User**: The `pi` agent that runs `agent-browser close` to detach its lane's daemon
from Chrome, then immediately runs its next driving command (`open`/`click`/…) which MUST
reuse the SAME browser and succeed (PRD §2.5 "close = disconnect-only; next call reuses the
same browser" / §2.15 "the agent cannot tell pooling is happening").

**Use Case**: `agent-browser close` (wrapper → S1 flips lease `connected=false`; real `close`
detaches the daemon; session lingers; Chrome alive) → `agent-browser open <url>` → wrapper
step h calls `pool_ensure_connected` → S2 reads `connected=false` → skips the stale
`pool_daemon_connected` early-exit → curl (Chrome alive) → `pool_daemon_connect` re-binds →
`connected=true` → exec `open` against a BOUND daemon → the open succeeds. S3 drives this
exact two-call sequence against real Chrome and asserts each transition.

**Pain Points Addressed**: Without S1+S2, the command immediately following a `close` may see
a spurious failure (daemon not re-bound) — violating PRD §2.15's "no idea" contract. S3 is
the durable regression guard: if a future edit reverts S1 or S2, this test FAILS (the
`connected` flag fails to transition `false→true`).

## Why

- **Closes the verification gap for Issue #3.** S1+S2 are the fix; S3 is the proof they
  compose under real Chrome. The architecture review (key_findings §ISSUE 3) flagged the
  close→rebind path as "confidence: medium — requires runtime verification"; S3 provides it.
- **The existing close test does NOT cover this.** `test_close_is_disconnect_only` (test d)
  invokes `close` DIRECTLY on `$POOL_REAL_BIN` (bypassing the wrapper), so S1's
  `connected=false` block NEVER fires; with `connected` still `true`, S2's gate lets the
  lingering `pool_daemon_connected` probe win and `pool_ensure_connected` EARLY-EXITS without
  re-binding. Test d passes both before AND after the fix — it never proves a rebind. S3
  closes that gap. (See research §1 for the full trace.)
- **Durable regression guard.** The `connected` `false→true` transition is a clean,
  machine-checkable signal: if S1 is reverted, `connected` never becomes `false`; if S2 is
  reverted, `pool_ensure_connected` early-exits and `connected` stays `false`. Either way the
  test FAILS loudly.
- **Test-only, zero production risk.** Adds one test function; no production code, framework,
  or doc change. Disjoint from all parallel items (P1.M2.T1.S3 → `concurrency.sh`; P1.M4 → docs).

## What

Add `test_close_then_rebind` to `test/release_reaper.sh`. It reuses the LANDED helpers
(`_release_setup_real_env`, `_test_spawn_owner`, `_release_acquire_boot`) and the LANDED
assertion primitives (`assert_eq`, `assert_lane_exists`, `_fail`, `pool_lease_field`,
`pool_daemon_connected`, `pool_ensure_connected`). The one design decision that distinguishes
it from test d: **it runs `close` THROUGH `pool_wrapper_main`** (in a subshell, because the
wrapper ends in `exec`) so S1's `connected=false` block fires end-to-end. Then it drives the
rebind by calling `pool_ensure_connected` directly (exactly what the wrapper's step h does on
the agent's next driving command) and asserts the `connected` `false→true` transition + a
genuine daemon binding.

| Step | Action | Asserts | PRD ref |
|---|---|---|---|
| 1 | `_test_spawn_owner` + `_release_acquire_boot` → lane N booted | `assert_lane_exists N`; port>0; **precondition `connected==true`** (boot step f, `lib/pool.sh:2335`) | §2.4 step 3 |
| 2 | `( pool_wrapper_main close )` (subshell — wrapper ends in exec) | — (S1 fires here) | §2.5 close |
| 3 | read `pool_lease_field "$N" connected` | **`== "false"`** (S1's wrapper block fired) | §2.4 step 4 |
| 4 | `pool_ensure_connected "$N"` | **rc 0** (S2 rebind succeeded) | §2.4 step 4 |
| 5 | read `pool_lease_field "$N" connected` | **`== "true"`** (S2's reconnect branch ran `pool_daemon_connect`) | §2.4 step 4 |
| 6 | `pool_daemon_connected "abpool-$N" "$port"` | **rc 0** (genuine binding, not lingering) | §2.15 |

### Success Criteria

- [ ] `test_close_then_rebind` is defined in `test/release_reaper.sh` below
      `test_close_is_disconnect_only`, named exactly `test_close_then_rebind` (auto-discovered
      by `_abpool_run_release_reaper_suite` — NO edit to the runner's `compgen` loop).
- [ ] It calls `_release_setup_real_env` first, then `_test_spawn_owner >/dev/null` (current
      shell, so owner env propagates to the `( pool_wrapper_main close )` subshell), then
      `_release_acquire_boot`.
- [ ] It asserts the precondition `connected==true` after boot (catches a broken boot).
- [ ] It runs `close` via `( pool_wrapper_main close ) >/dev/null 2>&1 || true` (subshell;
      wrapper ends in `exec`).
- [ ] It asserts `pool_lease_field "$N" connected == "false"` after close (S1 fired).
- [ ] It asserts `pool_ensure_connected "$N"` returns 0 (S2 rebind succeeded).
- [ ] It asserts `pool_lease_field "$N" connected == "true"` after the rebind (S2's reconnect
      branch ran — the discriminating `false→true` transition).
- [ ] It asserts `pool_daemon_connected` returns 0 after the rebind (genuine binding).
- [ ] `bash -n test/release_reaper.sh` clean; `shellcheck -S warning test/release_reaper.sh`
      clean; `bash test/release_reaper.sh` passes ALL tests (a/b/c/d + the new one) with zero
      residual processes.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed?"** → Yes.
This PRP includes: the **exact current state** of S1 (COMPLETE — wrapper close block +
predicate) and S2 (CONTRACT — the precise edits S2 makes to `pool_ensure_connected`, treated
as landed); the **full trace** of `pool_wrapper_main close` with a pre-booted lane (research
§2b); the **reason test d does not cover this** (it bypasses the wrapper → S1 never fires);
the **discriminating assertion** (the `connected` `false→true` transition is the ONLY signal
that proves a rebind ran vs an early-exit); the **single-setup runner auto-discovery**
(`compgen -A function | grep '^test_'` — there is NO literal test list to edit); the
**verbatim test body**; the safety mapping to AGENTS.md §1–§4; and the scope guard.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: §"ISSUE 3" — root cause (pool_daemon_connected's lingering-session false positive) +
        §"Testing Architecture Notes" (Chrome-requiring tests MUST follow AGENTS.md §1–§6;
        release_reaper.sh's _abpool_run_release_reaper_suite is the approved single-setup runner).
  pattern: the test goes in release_reaper.sh (Chrome-required); NOT validate.sh (Chrome-free).
  gotcha: test d invokes close on $POOL_REAL_BIN DIRECTLY → bypasses the wrapper → S1 never
        fires. S3 MUST run close THROUGH pool_wrapper_main.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S3/research/close-rebind-s3-findings.md
  why: THIS task's research: §1 (why test d does NOT cover the rebind), §2 (the full
        pool_wrapper_main close trace + the rebind flow + the discriminating connected
        false→true assertion), §3 (the single-setup runner + the helpers S3 reuses), §4 (AGENTS.md
        compliance), §5 (the bounded close invocation), §6 (naming+placement), §7 (scope/dependency).
  pattern: §2d (the assertion matrix), §3a (auto-discovery), §5 (option-1 subshell close).

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S2/PRP.md   # S2 — the READ-side CONTRACT
  why: S2 defines + LANDS the gate S3 exercises: pool_ensure_connected gains `connected` to its
        locals, adds `.connected` to the jq extraction (`connected="${_f[3]:-true}"`), and gates
        the early-exit `if [[ "$connected" == "true" ]] && pool_daemon_connected …; then`. S3's
        steps 4–5 VERIFY this gate works end-to-end. S2 also confirms BOTH success branches
        (reconnect ~2448, relaunch ~2499) ALREADY write connected=true — which is why S3's
        step-5 assert (connected==true after rebind) holds.
  pattern: S2's Chrome-free selftests (selftest_ensure_connected_rebinds_when_disconnected) prove
        the LOGIC in isolation; S3 proves it under REAL Chrome (the "requires runtime verification"
        the architecture review flagged).
  gotcha: if S2 is NOT yet landed, S3's step-5 assert FAILS (connected stays false) — that is
        CORRECT (S3 tests S2's behavior). The orchestrator sequences S1→S2→S3.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S1/PRP.md   # S1 — the WRITE-side CONTRACT
  why: S1 LANDED the close→connected=false block in pool_wrapper_main (lib/pool.sh:3656-3666) +
        _pool_clean_args_is_close (3792). S3's step-3 assert (connected==false after wrapper close)
        VERIFIES S1 fired end-to-end through the real wrapper.
  pattern: S1's own selftest (selftest_close_marks_lease_disconnected) runs
        `( AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json )` MOCKED (no Chrome);
        S3 runs the SAME wrapper invocation UN-MOCKED with real Chrome.

- file: PRD.md (bugfix snapshot)
  why: §2.4 step 4 (ENSURE CONNECTED — "reconnect if daemon died"), §2.5 ("close =
        disconnect-only; next call reuses the same browser"), §2.15 (transparency — agent must
        never see failures), §2.8 (lease `connected` boolean field).

# The code under test — READ these in lib/pool.sh
- file: lib/pool.sh
  why: pool_wrapper_main (3565) — the close path S3 drives (step e find_mine→reuse, step h
        ensure_connected early-exits on connected=true, the S1 close block 3656-3666 flips
        connected=false, step k exec's the real close); pool_ensure_connected (2390) — S2's gate
        (reads connected, skips early-exit when false → curl → pool_daemon_connect → connected=true);
        pool_daemon_connected (1727) — the lingering-session probe; pool_lease_field (881) — reads
        .connected as the bare string true/false; pool_boot_lane step f (2335) — sets connected=true
        on boot (S3's precondition); _pool_clean_args_is_close (3792) — S1's predicate.
  pattern: DO NOT edit ANY of these (S1+S2 own them). S3 only INVOKES pool_wrapper_main +
        pool_ensure_connected + pool_lease_field + pool_daemon_connected.
  gotcha: pool_wrapper_main ends in exec (step k) → run it in a `( … )` SUBSHELL so the test
        process survives. The subshell inherits the owner env + globals (set by _test_spawn_owner).

- file: test/release_reaper.sh
  why: THE file S3 edits. Helpers S3 reuses: _release_setup_real_env (60), _test_spawn_owner (153),
        _release_acquire_boot (109), _release_kill_owner_and_reap_zombie (133). The existing close
        test test_close_is_disconnect_only (~319) is the SIBLING to mirror (same scaffolding) — but
        note it invokes close on $POOL_REAL_BIN DIRECTLY (the gap S3 closes). The runner
        _abpool_run_release_reaper_suite (~395) auto-discovers test_* via compgen (§3a).
  pattern: copy test_close_is_disconnect_only's scaffolding (_release_setup_real_env ||
        return 1; _test_spawn_owner >/dev/null; N="$(_release_acquire_boot)"; port=...; guards);
        REPLACE the direct-close invocation with `( pool_wrapper_main close )` and ADD the
        connected-flag + rebind assertions.
  gotcha: _test_spawn_owner MUST run in the CURRENT shell (`>/dev/null`, NOT via `$(…)`) so the
        owner env + POOL_OWNER_* globals propagate to the `( pool_wrapper_main close )` subshell
        (pool_wrapper_main step d pool_owner_resolve reads AGENT_BROWSER_POOL_OWNER_PID; step e
        pool_lease_find_mine reads POOL_OWNER_PID). This matches how test d/c invoke it.

- file: test/validate.sh
  why: the test FRAMEWORK (sourced by release_reaper.sh). Assertion helpers: assert_eq EXP ACT
        [LABEL], assert_lane_exists N, assert_no_chrome [ROOT], _fail MSG. These are INHERITED —
        S3 uses them WITHOUT sourcing validate.sh directly (release_reaper.sh already does).
  pattern: every assert returns 0/1 (1 via _fail) → chain with `|| return 1` so a failed assert
        ends the body (rc 1 → the runner records FAIL → suite continues).
  gotcha: do NOT add S3 here — validate.sh selftests are Chrome-FREE (hermetic stubs); S3 needs
        REAL Chrome → it belongs in release_reaper.sh.

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution
  why: `( … )` is a SUBSHELL (a fork) — inherits all functions/vars/env; an `exec` inside replaces
        the SUBSHELL's process only, so the parent (test) shell survives. This is WHY
        `( pool_wrapper_main close )` works despite pool_wrapper_main's terminal `exec`.
  critical: do NOT run `pool_wrapper_main close` in the MAIN shell — the exec would REPLACE the
        test process (killing the suite). ALWAYS the subshell form `( … )`.
- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (`set -e`) exemptions — the condition of `if`/`||`/`&&` is EXEMPT. So
        `pool_ensure_connected "$N" || { _fail …; return 1; }` and
        `pool_daemon_connected … || { _fail …; return 1; }` are safe (a non-zero rc takes the
        `||` branch, it does NOT abort).
- url: https://github.com/koalaman/shellcheck/wiki/SC2155  # n/a — no `local x=$(…)` in this test
- url: https://github.com/koalaman/shellcheck/wiki/SC2086  # quote "$N", "$port", "$session"

# Sibling/parallel contracts (NO conflict)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2.T1.S3/PRP.md
  why: P1.M2.T1.S3 (parallel) is TEST-ONLY on test/concurrency.sh (port-collision recovery).
        Disjoint file from S3 (release_reaper.sh). NO conflict.
```

### Current Codebase tree

```bash
agent-browser-pool/
├── lib/pool.sh    # S1 COMPLETE: pool_wrapper_main close block (3656-3666) + _pool_clean_args_is_close (3792).
│                  # S2 CONTRACT (landing): pool_ensure_connected (2390) gains the connected gate.
│                  #   pool_boot_lane step f (2335) sets connected=true on boot (S3 precondition).
│                  #   pool_lease_field (881) reads .connected; pool_daemon_connected (1727) probes.
├── test/
│   ├── validate.sh         # framework + Chrome-free selftests (S1+S2 selftests live here). UNCHANGED by S3.
│   ├── release_reaper.sh   # ← S3 ADDS test_close_then_rebind HERE (Chrome-dependent; single-setup runner).
│   ├── transparency.sh     # unchanged
│   └── concurrency.sh      # P1.M2.T1.S3 (parallel) — unchanged
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S3/
    ├── PRP.md              # THIS FILE
    └── research/close-rebind-s3-findings.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── test/release_reaper.sh   # MODIFIED — +1 function (test_close_then_rebind) below test_close_is_disconnect_only.
                             # Auto-discovered by _abpool_run_release_reaper_suite (compgen). NO runner edit.
```

**File responsibility**: `test/release_reaper.sh::test_close_then_rebind` — the durable
end-to-end regression guard for Issue #3 (close→rebind). Proves S1 (wrapper marks
`connected=false`) + S2 (`pool_ensure_connected` re-binds, `connected` false→true) compose
under real Chrome.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the #1 design point): close MUST run THROUGH pool_wrapper_main (the wrapper),
#   NOT directly on $POOL_REAL_BIN. S1's connected=false block lives in pool_wrapper_main
#   (lib/pool.sh:3656-3666); the real $POOL_REAL_BIN close detaches the daemon but does NOT
#   touch the lease. Test d invokes $POOL_REAL_BIN directly (its gap); S3 invokes
#   pool_wrapper_main so S1 fires. VERIFIED by trace (research §1, §2b).

# CRITICAL (pool_wrapper_main ends in exec): running it in the MAIN shell would REPLACE the
#   test process (killing the suite). ALWAYS the subshell form: `( pool_wrapper_main close )`.
#   The exec replaces the SUBSHELL's process → real close runs → exits → parent shell continues.
#   `>/dev/null 2>&1 || true` keeps output clean + swallows close's rc (rc 0 on 0.28.0; future-
#   proof). This is the SAME pattern S1's selftest uses (selftest_close_marks_lease_disconnected).

# CRITICAL (owner env must reach the subshell): _test_spawn_owner MUST run in the CURRENT shell
#   (`_test_spawn_owner >/dev/null`, NOT `pid="$(…)"`). It exports AGENT_BROWSER_POOL_OWNER_PID +
#   refreshes POOL_OWNER_* globals in THIS shell; the `( pool_wrapper_main close )` subshell
#   inherits both → pool_wrapper_main step d (pool_owner_resolve) + step e (pool_lease_find_mine)
#   find lane N. (A `$()` here would lose the export → find_mine finds nothing → the wrapper
#   ACQUIRES a new lane instead of reusing N → S1 flips the WRONG lane → the test fails for the
#   wrong reason.) This matches how test d/c invoke _test_spawn_owner.

# CRITICAL (the discriminating assertion is connected false→true): pool_daemon_connected returns
#   0 BOTH when genuinely bound AND when lingering-after-close — it CANNOT distinguish them. The
#   ONLY clean signal that the rebind ran is the connected flag transitioning false→true: if S2
#   early-exited (fix absent), connected stays false; if S2 rebound, connected→true. Assert BOTH
#   the false (after close) and the true (after pool_ensure_connected). (research §2d)

# CRITICAL (S2 dependency): if S2 is NOT yet landed, pool_ensure_connected does NOT read
#   .connected → it calls pool_daemon_connected (lingering → 0) → early-exits → connected STAYS
#   false → S3's step-5 assert FAILS. That is CORRECT (S3 tests S2). Orchestrator orders S1→S2→S3.

# GOTCHA (pool_lease_field renders a JSON boolean as the bare string): `pool_lease_field "$N"
#   connected` prints `true` or `false` (jq -r on a JSON boolean). Compare with == "true" /
#   == "false" inside [[ ]] / assert_eq. NEVER numeric, NEVER quoted "false"-with-extra-quotes.

# GOTCHA (single-setup runner): setup() is called EXACTLY ONCE by _abpool_run_release_reaper_suite
#   (AGENTS.md §4 — the 3rd setup() hangs). Each body spawns its OWN owner via _test_spawn_owner
#   + boots its OWN lane via _release_acquire_boot. S3 does NOT call setup() itself. The runner's
#   inter-body backstop (release all + _release_kill_owner_and_reap_zombie) cleans up S3's lane +
#   owner — S3 needs NO explicit cleanup (but it must not spawn extra processes).

# GOTCHA (no literal test list): _abpool_run_release_reaper_suite discovers test_* via
#   `compgen -A function | grep '^test_' | sort`. Adding test_close_then_rebind is SUFFICIENT —
#   do NOT look for a list/array to edit.

# GOTCHA (release_reaper.sh sources validate.sh): the assertion helpers (assert_eq, assert_lane_exists,
#   _fail) + setup/teardown + lib/pool.sh are ALL inherited. Do NOT re-source anything.

# GOTCHA (AGENT_BROWSER_REAL must be the REAL binary): _release_setup_real_env sets it (+
#   AGENT_CHROME_MASTER + a btrfs AGENT_CHROME_EPHEMERAL_ROOT) + re-runs pool_config_init, so
#   POOL_REAL_BIN = real daemon. Without it, pool_daemon_connect / the wrapper's exec'd close /
#   pool_daemon_connected all fail. MUST be the FIRST call in the body (validate.sh's setup()
#   clobbered HOME → POOL_REAL_BIN resolves to a NONEXISTENT temp path otherwise).

# GOTCHA (Chrome is REAL here — AGENTS.md §1/§2/§3): _release_acquire_boot launches a real
#   headless Chrome; `( pool_wrapper_main close )` exec's the real close; pool_ensure_connected
#   does a real curl + pool_daemon_connect. The runner's backstop + teardown + EXIT trap reap the
#   Chrome pgroup + owner + temp roots. Do NOT add a per-test setup() or run the body in a `( … )`
#   subshell (the trap would fire mid-suite).
```

## Implementation Blueprint

### Data models and structure

No schema/globals/env/production changes. S3 adds ONE test function. The only data it
observes is the existing lease `.connected` boolean field (written by S1 on close, by the
reconnect branch of `pool_ensure_connected` on rebind). S3 reads it via `pool_lease_field`
— it never writes a lease itself.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY THE CURRENT STATE FIRST (S1 COMPLETE; S2 landing; locate the sibling test)
  - RUN: grep -nE '^test_close_is_disconnect_only\(\)|pool_lease_update "\$N" connected false|^_pool_clean_args_is_close\(\)' lib/pool.sh test/release_reaper.sh
  - EXPECT: test_close_is_disconnect_only in test/release_reaper.sh (~319); the S1 close block +
        predicate in lib/pool.sh (~3656 + ~3792). If the S1 block/predicate are ABSENT → STOP
        (S1 is a prerequisite — the orchestrator sequences it first).
  - RUN (confirm S2 has LANDED — the connected gate in pool_ensure_connected):
        grep -nE 'connected="\$\{_f\[3\]:-true\}"|if \[\[ "\$connected" == "true" \]\] && pool_daemon_connected' lib/pool.sh
  - EXPECT: TWO hits inside pool_ensure_connected (the capture + the gated early-exit). If ABSENT,
        S2 has NOT landed — S3 will FAIL its step-5 assert until S2 lands. Flag this to the
        orchestrator (do NOT implement S2 — it is a separate item); implement S3 anyway (it is the
        correct test; it goes green once S2 lands).
  - RUN (confirm the precondition — boot sets connected=true):
        grep -n 'pool_lease_update "$lane" connected true' lib/pool.sh | head -1   # ~2335 (pool_boot_lane step f)
  - EXPECT: a hit inside pool_boot_lane.
  - RUN: bash -n test/release_reaper.sh && shellcheck -S warning test/release_reaper.sh && echo OK
  - EXPECT: OK (clean before any S3 edit).

Task 1: ADD test_close_then_rebind to test/release_reaper.sh (the ONLY deliverable)
  - PLACEMENT: directly BELOW test_close_is_disconnect_only's closing `}` (logical grouping —
        both are close-semantics tests), ABOVE _abpool_run_release_reaper_suite. Auto-discovered
        by the runner's `compgen -A function | grep '^test_'` (NO runner edit).
  - BODY (verbatim — copy/paste; the comments cite the item's steps 1–6 + the PRD refs):
        # =============================================================================
        # TEST (e) — `close` (via the WRAPPER) marks the lease connected=false, and the NEXT
        # pool_ensure_connected RE-BINDS the daemon (connected false→true) instead of trusting the
        # lingering pool_daemon_connected probe (P1.M3.T1.S1+S2 / Issue #3 / PRD §2.4 step 4 /
        # §2.5 / §2.15).
        #
        # WHY THIS IS DISTINCT FROM test_close_is_disconnect_only (test d): test d invokes close
        # DIRECTLY on $POOL_REAL_BIN → BYPASSES pool_wrapper_main → S1's connected=false block
        # NEVER fires → connected stays true → S2's gate lets the lingering probe win →
        # pool_ensure_connected EARLY-EXITS without re-binding. test d passes before AND after the
        # fix; it never proves a rebind. THIS test runs close THROUGH pool_wrapper_main (so S1
        # fires end-to-end) and asserts the connected false→true transition (the ONLY signal that
        # distinguishes "rebind ran" from "early-exit on a lingering probe").
        # =============================================================================
        test_close_then_rebind() {
            _release_setup_real_env || return 1

            # (1) Spawn THIS body's owner (CURRENT shell — owner env + POOL_OWNER_* globals must
            #     propagate to the `( pool_wrapper_main close )` subshell), then acquire + boot
            #     lane N (one real headless Chrome).
            local N port session
            _test_spawn_owner >/dev/null
            N="$(_release_acquire_boot)" || return 1
            assert_lane_exists "$N" || return 1
            port="$(pool_lease_field "$N" port 2>/dev/null)" || port=""
            session="$(pool_lease_field "$N" session 2>/dev/null)" || session="abpool-$N"
            [[ "$port" =~ ^[0-9]+$ && "$port" != "0" ]] \
                || { _fail "lane $N not booted (port='$port')"; return 1; }
            # Precondition: a freshly-booted lane has connected=true (pool_boot_lane step f).
            assert_eq "true" "$(pool_lease_field "$N" connected)" \
                "precondition: booted lane $N connected=true" || return 1

            # (2) THE CONTRACT (S1): run `close` THROUGH the wrapper (pool_wrapper_main) so S1's
            #     close→connected=false block fires end-to-end. The wrapper ends in exec → run it
            #     in a SUBSHELL (exec replaces the subshell process; the real close detaches the
            #     daemon and exits; the parent shell continues). Bounded by exec's determinism
            #     (AGENTS.md §2; close is ms-fast). Owner env is inherited → find_mine reuses N.
            ( pool_wrapper_main close ) >/dev/null 2>&1 || true
            sleep 0.4   # let the daemon settle after the disconnect-only close (parity w/ test d)

            # (3) Assert S1 fired: the lease now has connected=false (the post-close signal S2 reads).
            assert_eq "false" "$(pool_lease_field "$N" connected)" \
                "S1: close (via wrapper) marked lane $N connected=false" || return 1

            # (4+5) THE CONTRACT (S2): pool_ensure_connected reads connected=false → SKIPS the
            #       lingering pool_daemon_connected early-exit → curl (Chrome still alive) →
            #       pool_daemon_connect RE-BINDS → connected=true → rc 0. (This is the self-heal
            #       the wrapper's step h runs on the agent's NEXT driving command.)
            pool_ensure_connected "$N" \
                || { _fail "S2: pool_ensure_connected failed to rebind lane $N after close"; return 1; }
            assert_eq "true" "$(pool_lease_field "$N" connected)" \
                "S2: pool_ensure_connected rebound lane $N (connected false→true)" || return 1

            # (6) Assert the daemon is GENUINELY bound (session in list + Chrome alive) — now
            #     because pool_daemon_connect re-attached, NOT because of a lingering entry. (The
            #     connected false→true transition above is the actual proof; this is the live-binding
            #     sanity check.)
            pool_daemon_connected "$session" "$port" \
                || { _fail "daemon not genuinely bound after rebind (pool_daemon_connected rc!=0)"; return 1; }

            # Cleanup is the runner's inter-body backstop (release all + kill owner); nothing extra.
        }
  - FOLLOW pattern: mirror test_close_is_disconnect_only's scaffolding (_release_setup_real_env ||
        return 1; _test_spawn_owner >/dev/null; N="$(_release_acquire_boot)"; the port guard).
  - GOTCHA: _test_spawn_owner is `>/dev/null` (CURRENT shell), NOT `pid="$(…)"` — see Known Gotchas.
  - GOTCHA: `( pool_wrapper_main close )` MUST be the subshell form (exec); `|| true` swallows rc.
  - GOTCHA: every assert is `|| return 1` so a failure ends the body (rc 1 → runner records FAIL).

Task 2: FINAL VERIFY (run before claiming done)
  - RUN: bash -n test/release_reaper.sh && shellcheck -S warning test/release_reaper.sh && echo OK-syntax
  - EXPECT: OK-syntax.
  - RUN (confirm the function is discovered by the runner):
        bash -c 'source test/validate.sh; source test/release_reaper.sh; compgen -A function | grep "^test_" | sort'
  - EXPECT: test_close_then_rebind appears in the sorted list (alongside test_explicit_release_tears_down_lane,
        test_stale_reaper_reaps_dead_owner_lane, test_reap_clears_crashed_owner_lane, test_close_is_disconnect_only).
        (NOTE: this `source` does NOT run the suite — release_reaper.sh's BASH_SOURCE gate runs the suite
        only when EXECUTED, not sourced.)
  - RUN (the full suite — REAL Chrome, isolated sandbox):
        bash test/release_reaper.sh
  - EXPECT: ALL tests PASS (a/b/c/d + e=test_close_then_rebind); "5 passed, 0 failed"; zero residual
        processes (`pgrep -af 'user-data-dir='` shows nothing under the test ephemeral root after teardown).
```

### Implementation Patterns & Key Details

```bash
# --- Pattern 1: close THROUGH the wrapper (the S1 trigger) --------------------------------
    ( pool_wrapper_main close ) >/dev/null 2>&1 || true
    # Subshell: exec replaces the subshell process (close runs + exits); parent survives.
    # Direct `$POOL_REAL_BIN --session abpool-N close` would BYPASS pool_wrapper_main → S1 never fires.

# --- Pattern 2: the discriminating assertion (connected false→true) ----------------------
    assert_eq "false" "$(pool_lease_field "$N" connected)" "S1: connected=false after close" || return 1
    pool_ensure_connected "$N" || { _fail "rebind failed"; return 1; }
    assert_eq "true"  "$(pool_lease_field "$N" connected)" "S2: connected=true after rebind" || return 1
    # If S2 early-exited (fix absent), connected stays false → the 2nd assert FAILS.

# --- Pattern 3: owner env in the current shell (so it reaches the subshell) ---------------
    _test_spawn_owner >/dev/null        # NOT: pid="$( _test_spawn_owner )"  (would lose the export)
    N="$(_release_acquire_boot)"        # this $() is fine — it only returns the lane number

# --- Critical micro-rules ----------------------------------------------------------------
#  * `pool_lease_field "$N" connected` → the bare string "true"/"false" (jq -r on a JSON boolean).
#  * `pool_daemon_connected SESSION PORT` → rc 0 (bound/lingering) / rc 1 (dead). SESSION="abpool-N".
#  * `pool_ensure_connected LANE` → rc 0 (connected, possibly after rebind/relaunch) / rc 1.
#  * The wrapper's step h runs pool_ensure_connected on the NEXT driving command; S3 calls it
#    DIRECTLY to isolate the rebind assertion (same function, same code path).
#  * pool_wrapper_main step e find_mine REUSES lane N (already booted+owned) — it does NOT re-acquire
#    or re-boot. (If it did, connected would be reset true by a fresh boot → S3 would pass vacuously.)
```

### Integration Points

```yaml
CONSUMED (S3 invokes; does NOT edit):
  - pool_wrapper_main "$@" (lib/pool.sh:3565): the wrapper. S3 calls `pool_wrapper_main close` in a
        subshell to fire S1's close block end-to-end + run the real close. Step e (find_mine) reuses
        lane N; step h (pool_ensure_connected) early-exits on connected=true; the S1 block (3656-3666)
        flips connected=false; step k exec's the real close.
  - pool_ensure_connected LANE (lib/pool.sh:2390): the self-heal. S3 calls it directly to drive the
        rebind (S2 reads connected=false → skips early-exit → curl → pool_daemon_connect → connected=true).
  - pool_lease_field LANE FIELD (lib/pool.sh:881): reads .connected (→ "true"/"false") + .port + .session.
  - pool_daemon_connected SESSION PORT (lib/pool.sh:1727): the lingering probe; S3 asserts rc 0 after
        the rebind (genuine binding).
  - _release_setup_real_env / _test_spawn_owner / _release_acquire_boot (test/release_reaper.sh): the
        real-Chrome harness helpers (LANDED). S3 reuses them verbatim.
  - assert_eq / assert_lane_exists / _fail (test/validate.sh): the assertion primitives (inherited).

PROVIDED (S3 does NOT implement): none — S3 is the FINAL subtask of P1.M3.T1.

CONFIG / DATABASE / ROUTES: none. No env vars/globals/schema/production change. One test function.
```

## Validation Loop

> **CRITICAL (AGENTS.md §1)**: Levels 1–2 are STATIC (no Chrome) — run them freely. Level 3
> launches REAL Chrome and MUST run in the isolated sandbox the test framework already provides
> (validate.sh's `setup()` redirects HOME/state/ephemeral to `mktemp -d`; `_release_setup_real_env`
> re-points master/ephemeral/binary to a btrfs temp dir). The single-setup runner reaps everything.

### Level 1: Syntax & Style (STATIC — no Chrome)

```bash
bash -n test/release_reaper.sh && echo OK-syntax
shellcheck -S warning test/release_reaper.sh && echo OK
# Expected: OK-syntax + OK (must be clean after adding the function).
```

### Level 2: Discovery & shape checks (STATIC — no Chrome)

```bash
# 2a. The new function is auto-discovered by the runner (NO edit to the compgen loop).
bash -c 'source test/validate.sh; source test/release_reaper.sh; \
         compgen -A function | grep "^test_" | sort' | grep -x test_close_then_rebind \
  && echo OK-discovered || echo FAIL-discovery
# Expected: OK-discovered. (Sourcing does NOT run the suite — the BASH_SOURCE gate.)

# 2b. The function calls the wrapper close in a SUBSHELL (not the main shell) — exec safety.
sed -n '/^test_close_then_rebind() {/,/^}/p' test/release_reaper.sh \
  | grep -qE '\( pool_wrapper_main close \)' && echo OK-subshell || echo FAIL-no-subshell
# Expected: OK-subshell.

# 2c. The function asserts connected false (after close) AND true (after rebind) — the
#     discriminating transition.
sed -n '/^test_close_then_rebind() {/,/^}/p' test/release_reaper.sh | grep -c 'assert_eq "false"\|assert_eq "true"'
# Expected: ≥2 (the false + the true connected asserts; the precondition true is a 3rd).
```

### Level 3: Integration Tests (REAL Chrome — isolated sandbox, single-setup runner)

```bash
# 3a. The full release_reaper suite (boots real headless Chrome; reaps via teardown+trap).
bash test/release_reaper.sh
# Expected: ALL tests PASS — test_explicit_release_tears_down_lane, test_stale_reaper_reaps_dead_owner_lane,
#           test_reap_clears_crashed_owner_lane, test_close_is_disconnect_only,
#           AND the new test_close_then_rebind. "5 passed, 0 failed".

# 3b. No residual pool-Chrome after the suite (AGENTS.md §3 — reap what you spawn).
pgrep -af 'user-data-dir=' | grep -v "$(getent passwd "$USER" | cut -d: -f6)/.config/google-chrome" || echo OK-no-residual-chrome
# Expected: OK-no-residual-chrome (only the operator's daily-driver Chrome, if any, under ~/.config/google-chrome;
#           ZERO pool-spawned Chrome under the test ephemeral root).

# 3c. No leaked temp roots under /tmp from this run.
ls -d /tmp/abpool-test.* /tmp/abpool-pi.* 2>/dev/null || echo OK-no-leaked-temps
# Expected: OK-no-leaked-temps (the EXIT trap removes them; _release_setup_real_env's btrfs eph root
#           is under ~/, removed via ABPOOL_SIM_BINS).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm ONLY test/release_reaper.sh changed (test-only; no production/framework/doc edit).
git status --porcelain --untracked-files=all
# Expected: only test/release_reaper.sh; no lib/pool.sh, no test/validate.sh, no PRD.md, no .json/.tmp.

# 4b. Confirm the function does NOT invoke close on $POOL_REAL_BIN directly (the test-d anti-pattern)
#     — it MUST go through pool_wrapper_main.
sed -n '/^test_close_then_rebind() {/,/^}/p' test/release_reaper.sh \
  | grep -qE '"\$POOL_REAL_BIN" .* close' && echo FAIL-direct-close || echo OK-via-wrapper
# Expected: OK-via-wrapper (no direct $POOL_REAL_BIN close in the new test).

# 4c. (Optional enrichment — if the implementer wants the strongest transparency assertion) verify
#     the agent's NEXT DRIVING COMMAND actually succeeds after the rebind, by running open through the
#     wrapper (step h pool_ensure_connected early-exits on connected=true → exec open → open drives the
#     re-bound daemon). Add AFTER step 6 if desired (not required by the item's steps 1–6):
#         ( pool_wrapper_main open about:blank ) >/dev/null 2>&1 || { _fail "post-close open failed (transparency)"; return 1; }
#     This directly tests PRD §2.15 ("the agent cannot tell pooling is happening"). It is OPTIONAL —
#     the connected false→true transition + pool_daemon_connected rc 0 already prove the rebind.
```

## Final Validation Checklist

### Technical Validation

- [ ] Task 0 current-state check done (S1 present; S2 located/landed; sibling test located; boot
      sets connected=true confirmed).
- [ ] `bash -n test/release_reaper.sh` clean; `shellcheck -S warning test/release_reaper.sh` zero warnings.
- [ ] `test_close_then_rebind` is auto-discovered by the runner (2a); close runs in a subshell (2b);
      both connected asserts present (2c).
- [ ] The full suite passes (3a): 5/5; zero residual Chrome (3b); no leaked temps (3c).
- [ ] Only `test/release_reaper.sh` changed (4a); close goes through the wrapper, not $POOL_REAL_BIN (4b).

### Feature Validation

- [ ] A wrapper-driven `close` marks the lease `connected=false` (step 3 assert) — S1 end-to-end.
- [ ] The subsequent `pool_ensure_connected` re-binds: `connected` transitions `false→true` (step 5
      assert) + rc 0 (step 4) — S2 end-to-end.
- [ ] After the rebind, `pool_daemon_connected` returns 0 (step 6) — genuine binding, not lingering.
- [ ] The test FAILS LOUDLY if S1 or S2 is reverted (the discriminating `false→true` transition breaks).
- [ ] PRD §2.4 step 4 / §2.5 / §2.15 (close→reuse-same-browser→no spurious failure) verified end-to-end.

### Code Quality / Documentation

- [ ] Mirrors `test_close_is_disconnect_only`'s scaffolding (helper order, guards, assert style).
- [ ] Comments document WHY this test is distinct from test d (bypasses-wrapper gap) + cite PRD refs.
- [ ] Reuses the LANDED helpers/primitives (no duplication; no new globals/env/dependencies).
- [ ] Test-only: no production code, framework, other-test, or doc change.

---

## Anti-Patterns to Avoid

- ❌ Don't invoke close on `$POOL_REAL_BIN` directly (the test-d anti-pattern) — S1's
  `connected=false` block is in `pool_wrapper_main`; a direct close BYPASSES it → the test
  passes vacuously (connected never becomes false, so S2's gate never gets exercised). ALWAYS
  `( pool_wrapper_main close )`.
- ❌ Don't run `pool_wrapper_main close` in the MAIN shell — it ends in `exec`, which would
  REPLACE the test process and kill the suite. ALWAYS the subshell `( … )` form.
- ❌ Don't run `_test_spawn_owner` via `pid="$(…)"` — the subshell loses the owner-env export,
  so the `( pool_wrapper_main close )` subshell's `pool_lease_find_mine` finds nothing → the
  wrapper ACQUIRES a new lane instead of reusing N → S1 flips the WRONG lane. Use
  `_test_spawn_owner >/dev/null` (current shell).
- ❌ Don't add a per-test `setup()` call or run the body in a `( … )` subshell — the
  single-setup runner calls `setup()` ONCE and runs bodies via `if "$fn"` in the MAIN shell
  (AGENTS.md §4 — the 3rd `setup()` hangs; a subshell body fires the EXIT trap mid-suite).
- ❌ Don't assert ONLY `pool_daemon_connected` rc 0 — it returns 0 BOTH bound AND
  lingering-after-close (cannot distinguish). The discriminating signal is the `connected`
  `false→true` transition; assert BOTH the `false` (after close) and the `true` (after rebind).
- ❌ Don't compare `connected` numerically or to quoted `"false"` — `pool_lease_field` prints
  the bare string `true`/`false`; use `assert_eq "false"` / `assert_eq "true"`.
- ❌ Don't edit `lib/pool.sh` (S1+S2 own it), `test/validate.sh` (the framework + Chrome-free
  selftests), other test files, `PRD.md`, `tasks.json`, or any docs — S3 is test-only on
  `test/release_reaper.sh`.
- ❌ Don't add the test to `test/validate.sh` — those selftests are Chrome-FREE (hermetic
  stubs); S3 needs REAL Chrome → it belongs in `test/release_reaper.sh`.
- ❌ Don't look for a "test list" to edit — `_abpool_run_release_reaper_suite` discovers
  `test_*` via `compgen`. Adding the function is sufficient.
- ❌ Don't blind-edit by the item's line numbers — locate `test_close_is_disconnect_only` with
  `grep -n 'test_close_is_disconnect_only' test/release_reaper.sh` and place the new function
  directly below it.
