# PRP — P1.M3.T1.S1: Set `connected=false` in `pool_wrapper_main` close path before exec

> ## ⚠️ CURRENT STATE — READ THIS FIRST (observed at research time, 2026-07-14 20:40)
>
> While this PRP was being researched, `lib/pool.sh` was modified by a concurrent
> implementer (mtime 20:40:12). On inspection, **the production change for S1 is ALREADY
> PRESENT** and matches this spec nearly verbatim:
> - **`_pool_clean_args_is_close()`** predicate — defined at `lib/pool.sh:3792` (flag-scan
>   `case` identical to this PRP's Task 1; final `[[ "$cmd" == close ]]`).
> - **The close→`connected=false` wiring** — present in `pool_wrapper_main` at
>   `lib/pool.sh:3652-3666`, INCLUDING the recommended **subshell defense**
>   `( pool_lease_update "$N" connected false ) 2>/dev/null || _pool_log …` (the literal
>   `|| true` from the item description was correctly NOT used — see Gotchas).
> - **Expanded step-k comments** (3670-3673) — present.
> - `bash -n lib/pool.sh` + `shellcheck -S warning lib/pool.sh` on the current file: **clean**.
>
> **The TEST, however, is NOT present** — `grep -rn '_pool_clean_args_is_close|close_marks_lease'
> test/` returns nothing.
>
> **THEREFORE:** Tasks 1-3 below are framed as **VERIFY-OR-IMPLEMENT** — the implementer MUST
> first check the current state and NOT blindly re-add code that already exists (which would
> duplicate / contradict it). **Task 4 (the test) is the primary remaining deliverable.** The
> full design spec is retained below as the authoritative target for verification and as a
> restore-path if a future revert removes the production code.

---

> **Bugfix context**: This subtask implements **Issue 3** (close→next-driving command may skip a
> needed daemon rebind) from
> `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` §"ISSUE 3" (Fix
> Approach #1: mark the lease `connected=false` on close so the next call's
> `pool_ensure_connected` rebinds). It is the FIRST of three subtasks under **P1.M3.T1**:
> **S1** (THIS) writes `connected=false` on close **+ its test**; **S2** (next) makes
> `pool_ensure_connected` READ that flag; **S3** adds the end-to-end close→rebind test. S1
> touches ONLY the close path of `pool_wrapper_main` (+ one predicate) and adds a Chrome-free
> test. It does NOT touch `pool_ensure_connected` (S2), boot/port code (P1.M2), or config (P1.M1).

---

## Goal

**Feature Goal**: When the wrapper executes an agent's `close` command, mark the lane's lease
`connected=false` BEFORE the terminal `exec`, so the agent's *next* driving command forces
`pool_ensure_connected` (S2) to re-bind the daemon to the still-running Chrome instead of
trusting the lingering `session list` entry. Today (pre-fix) the close path runs `close` like
any driving command and `exec`s — nothing records that the daemon binding was detached, so the
lease's `connected` stays `true`; `pool_daemon_connected` then returns 0 (lingering session +
alive Chrome) and the next call's `pool_ensure_connected` early-exits, skipping the reconnect
(Issue 3 / PRD §2.15 transparency risk). S1 closes the WRITE half of that gap **and gates it
with a Chrome-free regression test**.

**Deliverable** (edits to `lib/pool.sh` + a test addition):
1. **`_pool_clean_args_is_close ARGS...`** predicate (returns 0 iff the first non-flag token is
   the command `close`); the twin of the existing `_pool_clean_args_is_bare_connect`. **[ALREADY
   PRESENT at lib/pool.sh:3792 — VERIFY, do not duplicate-add.]**
2. A ~10-line block in `pool_wrapper_main` (between the `POOL_CLOSE_ALL_SEEN` log and step k)
   that, when `_pool_clean_args_is_close` is true, runs `pool_lease_update "$N" connected false`
   defensively in a subshell BEFORE `exec`. **[ALREADY PRESENT at lib/pool.sh:3652-3666 —
   VERIFY, do not duplicate-add.]**
3. Updated step-k comments documenting the new behavior + WHY. **[ALREADY PRESENT at 3670-3673 —
   VERIFY.]**
4. **A Chrome-free test** (predicate unit test + an isolated integration test via function
   overrides + no-op `exec` in a subshell) asserting the lease is `connected=false` after a
> close invocation. **[NOT YET PRESENT — this is the primary remaining work.]**

**Success Definition**:
- The production change (1-3) is present in `lib/pool.sh`, matches the spec below, and passes
  `bash -n` + `shellcheck -S warning` clean. (Verify; implement only if absent/reverted.)
- `_pool_clean_args_is_close close` returns 0; `_pool_clean_args_is_close --json close` returns
  0; `_pool_clean_args_is_close open`/`connect`/`` (empty) `` return 1.
- A lane with a `connected=true` lease that receives a `close` via `pool_wrapper_main` (with the
  Chrome/daemon-dependent steps overridden for the test) has its lease flipped to
  `"connected": false` (JSON boolean) on disk, with every other field preserved, and the wrapper
  still `exec`s the close (the override's no-op).
- A non-close command (`open`/`click`/`connect`) does NOT flip `connected`.
- A (very unlikely) corrupt/missing lease does NOT abort the close: the `pool_lease_update` runs
  in a subshell so a `pool_die` is contained, a warning is logged, and the close still `exec`s.
- The new test runs green via the framework with zero residual processes.

## User Persona

**Target User**: The agent (a `pi`-ancestor process) running `agent-browser close` to
disconnect its lane's daemon from Chrome (PRD §2.5: "close = disconnect-only; next call reuses
the same browser"). Internal-only change — no operator-visible surface.

**Use Case**: `agent-browser close` → daemon binding detached (session lingers, Chrome alive).
Next `agent-browser open <url>` MUST reuse the same browser and succeed — which requires the
pool to re-bind the daemon. S1 ensures the lease records the detach so S2's
`pool_ensure_connected` knows to rebind.

**Pain Points Addressed**: Without S1+S2, the command immediately following a `close` may see a
spurious failure (daemon not re-bound) — violating PRD §2.15's transparency contract. S1
provides the signal (lease `connected=false`) that S2 consumes to force the rebind.

## Why

- **Closes the WRITE half of Issue 3.** The root cause (key_findings §ISSUE 3) is that no code
  path flips `connected=false` after a close, so the lease lies ("connected" while the binding is
  detached). S1 makes the close path tell the truth. (Doing S1 first keeps each change small and
  independently testable.)
- **Aligns with PRD §2.4 step 4's design** ("reconnect if the daemon died"). After a
  disconnect-only close the binding IS effectively dead even though the probes can't see it; the
  `connected=false` flag is the durable record that survives across the two separate
  `agent-browser` invocations (close runs in one call; the next driving command in another).
- **Defensive + harmless even before S2.** Writing `connected=false` on close has NO effect on
  any current code path (nothing reads `.connected` to change behavior until S2 lands). Safe to
  land independently; the full fix activates once S2 lands.
- **A regression test is the durable guarantee.** The production change can be silently
  regressed by a future edit; the Chrome-free test (predicate unit + isolated integration) locks
  the `close → connected=false` contract in place.

## What

| Change | Where | Status | Behavior |
|---|---|---|---|
| `_pool_clean_args_is_close ARGS...` | `lib/pool.sh:3792` (below `_pool_clean_args_is_bare_connect`) | **PRESENT — verify** | Predicate: scan ARGS with the same flag-skip `case`; return 0 iff first non-flag token == `close`, else 1. Never `pool_die`/echo/write; reads only `$@`. |
| close→`connected=false` block | `lib/pool.sh:3652-3666` (in `pool_wrapper_main`, after `POOL_CLOSE_ALL_SEEN`, before step k) | **PRESENT — verify** | `if _pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"; then if ! ( pool_lease_update "$N" connected false ) 2>/dev/null; then _pool_log "…non-fatal…"; fi; fi` |
| step-k comments | `lib/pool.sh:3670-3673` | **PRESENT — verify** | Document the close→`connected=false` update + WHY. |
| **the TEST** | `test/validate.sh` (selftests) **or** new `test/close_rebind.sh` | **ABSENT — ADD (primary work)** | Predicate unit test + Chrome-free integration test asserting `connected=false` after close. |

### Success Criteria

- [ ] `_pool_clean_args_is_close` is defined directly below `_pool_clean_args_is_bare_connect`
  and matches the spec (Task 1); returns 0 for `close`/`--json close`/`close --json`; returns 1
  for `open`/`click`/`connect`/`connect 98765`/empty/flags-only.
- [ ] `pool_wrapper_main`, when `POOL_CLEAN_ARGS`'s command is `close`, calls
  `pool_lease_update "$N" connected false` (in a subshell) so `.connected` becomes the JSON
  boolean `false`, all other fields byte-identical, BEFORE `exec`.
- [ ] A non-close command does NOT alter `.connected`.
- [ ] The `pool_lease_update` call is wrapped so a `pool_die` is CONTAINED (subshell) and the
  close still `exec`s; a warning is logged via `_pool_log`.
- [ ] `close --all` (normalized to scoped `close` at step i) still triggers the flip.
- [ ] **The test exists and passes** (predicate unit + Chrome-free integration), zero residual
  processes.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean; full file sources
  under `set -euo pipefail`.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed?"** → Yes.
This PRP includes: the **current-state** finding (production code present, test absent); the
exact spec to verify against; the **`AGENT_BROWSER_REAL` vs `POOL_REAL_BIN`** test gotcha (the
#1 test-harness trap — see Gotchas); the host-verified round-trip and integration-test commands;
the `pool_lease_update` contract (and the **`pool_die` cannot be caught by `|| true`** gotcha);
the S2 consumer contract; and the parallel-item conflict check (none).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: §"ISSUE 3" — root cause + Fix Approach #1 (mark connected=false on close [S1]) / #2
        (ensure_connected reads it [S2]).
  pattern: Fix #1 = THIS task (write side); Fix #2 = S2 (read side).
  gotcha: the doc's "`|| true`" suggestion is INSUFFICIENT against pool_die — use a subshell.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S1/research/close-rebind-s1-findings.md
  why: THIS task's research: the step map, the pool_lease_update contract + pool_die-vs-||
        gotcha, the host-verified round-trip, the helper-predicate rationale, the Chrome-free
        test design (WITH the AGENT_BROWSER_REAL fix), the CURRENT-STATE finding (§7b — prod
        code present, test absent), and the scope guard.
  pattern: §1 (insertion point), §2 (subshell defense), §6 (test design), §7b (current state).
  gotcha: §6's AGENT_BROWSER_REAL note + §2's pool_die-can't-be-caught-by-|| are the two traps.

- file: .pi-subagents/artifacts/outputs/3a827294/plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/scout-boot-connect.md
  why: §"ISSUE 3" (3.1–3.6) deep static analysis: pool_daemon_connected's lingering-session
        docstring, pool_ensure_connected's early-exit, the close path in pool_wrapper_main,
        pool_normalize_close's behavior, and the grep proving NO code path set connected=false.
  pattern: 3.3 maps the close steps; 3.4 confirms normalize_close only strips --all.

- file: PRD.md (bugfix snapshot)
  why: §2.4 step 4 (ENSURE CONNECTED — "reconnect if daemon died"), §2.5 ("close =
        disconnect-only; next call reuses the same browser"), §2.15 (transparency — agent must
        never see failures), §2.8 (lease `connected` boolean field).

# The code under edit — READ the named functions in lib/pool.sh
- file: lib/pool.sh
  why: pool_wrapper_main (3565–~3691) is the edit/verify site; _pool_clean_args_is_bare_connect
        (~3710) is the predicate S1 mirrors (already mirrored at 3792); pool_lease_update (768)
        is the primitive; pool_normalize_close (3250) + pool_normalize_connect build
        POOL_NORM_ARGS; pool_strip_session_args builds POOL_CLEAN_ARGS (step j);
        pool_ensure_connected (2390) is the S2 consumer (do NOT edit); pool_config_init (~120)
        RE-RESOLVES POOL_REAL_BIN from AGENT_BROWSER_REAL (the test gotcha).
  pattern: copy _pool_clean_args_is_bare_connect's flag-scan `case`; change the command test to
        `close`; drop the "scan past command for a positional" tail.
  gotcha: POOL_CLEAN_ARGS already had --session stripped at step j (mirror the full case anyway,
        for parity/defense-in-depth). close != connect → step k's bare-connect short-circuit
        never fires for close.

- file: test/validate.sh
  why: the test FRAMEWORK (hand-rolled, no bats): setup() (temp state dir +
        AGENT_BROWSER_POOL_STATE), assert_eq / _fail, run_test NAME FN (body in a subshell),
        abpool_run_suite PREFIX, spawn_sim_owner, the EXIT/INT/TERM trap that reaps+removes
        everything. Sibling bugfix tasks (P1.M2.T1.S1/S2) added pure-function selftests HERE.
  pattern: add selftest__pool_clean_args_is_close + test_close_marks_lease_disconnected as new
        test_* / selftest_* functions (source validate.sh, OR a new test/close_rebind.sh).
  gotcha: pool_wrapper_main ends in exec → run it in a `( … )` subshell; overrides are inherited.

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (`set -e`) exemptions — the condition of `if`/`||`/`&&` is EXEMPT.
- url: https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution
  why: `( … )` is a SUBSHELL (a fork) — inherits all functions/vars; a `pool_die` (exit) inside
        kills only the subshell, not the parent. This is WHY the subshell contains pool_die.
- url: https://www.gnu.org/software/bash/manual/bash.html#Environment
  why: a VAR=VALUE PREFIX on a command (e.g. `AGENT_BROWSER_REAL=x pool_wrapper_main …`) is
        exported into that command's ENVIRONMENT — so pool_config_init (called inside) reads it.
        This is WHY the test sets AGENT_BROWSER_REAL as a prefix env on the subshell.
- url: https://github.com/koalaman/shellcheck/wiki/SC2155  # declare+assign separately
- url: https://github.com/koalaman/shellcheck/wiki/SC2086   # quote "${arr[@]}"

# Sibling/parallel contracts
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S3/PRP.md
  why: P1.M2.T1.S3 (parallel) is TEST-ONLY on test/concurrency.sh. Its PRP states P1.M3 is
        disjoint from the boot/re-pick path. NO conflict. (NOTE: a concurrent edit DID land the
        S1 production code in lib/pool.sh during research — see CURRENT STATE above. Confirm the
        current file state before acting.)
```

### Current Codebase tree

```bash
agent-browser-pool/
├── lib/pool.sh    # 4510+ LOC — S1 production code ALREADY PRESENT:
│                  #   pool_lease_update (768); pool_ensure_connected (2390) [S2 edits, NOT S1];
│                  #   pool_wrapper_main (3565) — close→connected=false block PRESENT (3652-3666);
│                  #   _pool_clean_args_is_close PRESENT (3792); _pool_clean_args_is_bare_connect (~3710)
├── test/
│   ├── validate.sh        # framework + selftests — ADD the S1 test here (or new test/close_rebind.sh)
│   ├── transparency.sh    # close --all scope tests (Chrome-dependent; S1's test is Chrome-FREE)
│   ├── concurrency.sh     # P1.M2.T1.S3 (parallel)
│   └── release_reaper.sh
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S1/{PRP.md, research/close-rebind-s1-findings.md}
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (#1 test trap — host-verified): pool_config_init RE-RESOLVES POOL_REAL_BIN from the
# AGENT_BROWSER_REAL ENV VAR on every call (incl. inside pool_wrapper_main step a). So an inline
# `POOL_REAL_BIN=$tmp/noop.sh` is OVERWRITTEN → the test silently runs the REAL agent-browser and
# TOUCHES THE OPERATOR'S DAEMON (AGENTS.md violation) + passes for the wrong reason. FIX: set
# AGENT_BROWSER_REAL (the env var) — as a PREFIX env on the subshell command, e.g.
#   ( AGENT_BROWSER_REAL="$tmp/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close )
# Verified: with AGENT_BROWSER_REAL set, the noop runs; without it, the real binary runs.

# CRITICAL (pool_die can't be caught by `|| true`): pool_lease_update pool_die()'s on a bad lane /
# missing/corrupt lease / non-JSON value — and pool_die does `exit 1` (kills the PROCESS), NOT
# `return 1`. `|| true` only catches a non-zero RETURN. So `( pool_lease_update … ) || _pool_log`
# in a SUBSHELL is required to contain it (the subshell dies, the parent's `||` swallows it).
# (The ALREADY-PRESENT code at 3664 uses exactly this subshell form — verify it stays that way.)

# CRITICAL (exec replaces the process): NOTHING runs after `exec "$POOL_REAL_BIN" …` (step k).
# The connected=false write MUST be before it. The test MUST run pool_wrapper_main in a `( … )`
# subshell so the test process survives the exec.

# CRITICAL (close != connect): the bare-connect short-circuit (step k) fires ONLY for a bare
# `connect`; for a `close` argv it returns 1. So the close block (before the bare-connect check)
# and the bare-connect short-circuit are mutually exclusive — order is safe.

# GOTCHA (POOL_CLEAN_ARGS already had --session stripped at step j): mirror the full flag-skip
# case (--session/--session=/--*/-*) anyway, for parity with the connect twin + defense-in-depth.

# GOTCHA (SC2155 / set -e): declare locals FIRST, assign AFTER; call the predicate as
# `if _pool_clean_args_is_close …; then …` (it legitimately returns 1 for non-close).

# GOTCHA (connected is a JSON BOOLEAN): `pool_lease_update "$N" connected false` splices `false`
# as raw JSON (--argjson) → the boolean false (NOT the string "false", NOT 0). Host-verified:
# after the call, `jq -r .connected` prints `false` and `jq '.connected|type'` prints `boolean`.

# GOTCHA (S2 owns the read side): do NOT edit pool_ensure_connected. The round-trip is already
# sound: ensure_connected step c sets connected=true on reconnect (~line 2430).
```

## Implementation Blueprint

### Data models and structure

No schema/globals/env changes. S1 adds ONE predicate + ONE ~10-line block (both already present)
and one test. The only on-disk effect is one lease field (`.connected`, boolean) flipped
`true→false` via `pool_lease_update` (atomic tmp+mv; siblings + `owner` preserved).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY THE CURRENT STATE FIRST (the production code is likely already present)
  - RUN: grep -nE '^_pool_clean_args_is_close\(\)|pool_lease_update "\$N" connected false' lib/pool.sh
  - EXPECT: a hit at ~3792 (predicate def) and ~3664 (the wiring). If BOTH present → the
        production change is LANDED; SKIP Tasks 1-3 (do NOT duplicate-add) and go to Task 4
        (the test, the primary remaining work). If ABSENT → implement per Tasks 1-3.
  - RUN (confirm soundness of whatever is present): bash -n lib/pool.sh && shellcheck -S warning lib/pool.sh
  - EXPECT: clean.
  - RUN (host re-confirm the round-trip against the live lib):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'set -euo pipefail; source lib/pool.sh;
            pool_config_init; pool_state_init;
            pool_lease_write 1 /x 53420 abpool-1 1 pi 100 /c 200 201 true;
            pool_lease_update 1 connected false;
            test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "false" && echo OK-roundtrip'
  - EXPECT: OK-roundtrip.

Task 1: VERIFY-OR-IMPLEMENT _pool_clean_args_is_close (target: directly below _pool_clean_args_is_bare_connect)
  - IF PRESENT (grep Task 0): diff it against the spec body below; it must match (flag-scan case
        identical to _pool_clean_args_is_bare_connect; final `[[ "$cmd" == close ]]`). If it
        matches → done. If it differs in a way that breaks the contract → align it to the spec.
  - IF ABSENT: append directly below _pool_clean_args_is_bare_connect's closing `}`.
  - TARGET BODY (verbatim — the authoritative spec):
        # _pool_clean_args_is_close ARGS...
        #
        # Predicate: is the cleaned argv a `close` command? Returns 0 iff the first NON-flag
        # token (skipping --session/--session=/--*/-*, mirroring pool_dispatch_classify) equals
        # `close`; returns 1 otherwise. Twin of _pool_clean_args_is_bare_connect.
        #
        # CONSUMER: pool_wrapper_main (Issue #3 / P1.M3.T1.S1). When the agent's command is
        # `close`, the wrapper marks the lease connected=false (so the NEXT call's
        # pool_ensure_connected, S2, rebinds the daemon instead of trusting the lingering
        # session-list entry). close detaches the binding but the session lingers in `session
        # list` + Chrome stays alive → pool_daemon_connected would otherwise return 0 and skip
        # the rebind (PRD §2.15 transparency risk).
        #
        # GOTCHA — POOL_CLEAN_ARGS has had --session stripped at step j (pool_strip_session_args);
        #   the full flag-skip case is kept for parity with the connect twin + defense-in-depth.
        # GOTCHA — return 0/1 ONLY (never pool_die/echo/write); reads only "$@".
        # GOTCHA — under set -e, call as `if _pool_clean_args_is_close …; then …`.
        _pool_clean_args_is_close() {
            local -a orig=("$@")
            local i=0 tok cmd=""
            while (( i < ${#orig[@]} )); do
                tok="${orig[i]}"
                case "$tok" in
                    --session)      i=$((i+2)) ;;
                    --session=*)    i=$((i+1)) ;;
                    --*)            i=$((i+1)) ;;
                    -*)             i=$((i+1)) ;;
                    *)              cmd="$tok"; break ;;
                esac
            done
            [[ "$cmd" == close ]]
        }

Task 2: VERIFY-OR-IMPLEMENT the close→connected=false block in pool_wrapper_main
  - IF PRESENT (grep Task 0): confirm it is between the POOL_CLOSE_ALL_SEEN if/fi and the step-k
        comment, uses the subshell form, and runs BEFORE exec. If so → done.
  - IF ABSENT: insert directly after the POOL_CLOSE_ALL_SEEN `if/fi` block and before the
        `# --- k. EXEC the real binary` comment header.
  - TARGET BLOCK (verbatim — the authoritative spec):
        # --- (close) mark the lease disconnected so the NEXT call rebinds (Issue #3) ----
        # close detaches the daemon↔Chrome binding, but the session LINGERS in `session list`
        # and Chrome stays alive → pool_daemon_connected would return 0 and the next
        # pool_ensure_connected would SKIP the rebind (PRD §2.15 transparency risk). Flipping
        # the lease connected=false here records the detach durably (across the two separate
        # agent-browser invocations) so S2's pool_ensure_connected takes the reconnect branch.
        # MUST run before exec (exec replaces the process — nothing runs after).
        if _pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"; then
            # Defensive SUBSHELL: pool_lease_update pool_die()'s on a corrupt/missing lease.
            # `|| true` does NOT catch pool_die (it `exit 1`s, not `return 1`) — a subshell
            # contains the exit so a (very unlikely — the lease was read at step h) corruption
            # cannot abort the close (PRD §2.15: close must always run). 2>/dev/null keeps the
            # agent's output clean; _pool_log records the rare miss.
            if ! ( pool_lease_update "$N" connected false ) 2>/dev/null; then
                _pool_log "pool_wrapper_main: close: could not mark lane $N connected=false (non-fatal; proceeding to exec)"
            fi
        fi

Task 3: VERIFY-OR-IMPLEMENT the step-k comment expansion (target: ~lib/pool.sh:3670-3673)
  - TARGET (a short note added to the step-k comment header):
        # The close path above already marked the lease connected=false BEFORE this terminal
        # exec, so the agent's NEXT driving command forces pool_ensure_connected to rebind the
        # daemon (close detaches the binding but the session lingers in `session list`; the
        # connected=false flag is what tells the next call a rebind is needed).

Task 4: ADD THE TEST (the PRIMARY remaining deliverable — currently ABSENT)
  - HOME: add to test/validate.sh's selftest section (co-located with P1.M2.T1.S1/S2 selftests),
        OR create test/close_rebind.sh that does `source "$ABPOOL_REPO/test/validate.sh"` then
        defines test_* functions and calls `abpool_run_suite test_`.
  - TEST BODIES (verbatim, Chrome-FREE; NOTE the AGENT_BROWSER_REAL prefix env — NOT POOL_REAL_BIN):
        # Unit: predicate truth table (pure function — no globals/Chrome/exec).
        selftest__pool_clean_args_is_close() {
            source "$ABPOOL_REPO/lib/pool.sh"
            _pool_clean_args_is_close close            || _fail "close should be detected"
            _pool_clean_args_is_close --json close     || _fail "--json close should be detected"
            _pool_clean_args_is_close close --json     || _fail "close --json should be detected"
            if _pool_clean_args_is_close open;         then _fail "open must NOT be detected"; fi
            if _pool_clean_args_is_close connect;      then _fail "connect must NOT be detected"; fi
            if _pool_clean_args_is_close connect 9;    then _fail "connect <port> must NOT be detected"; fi
            if _pool_clean_args_is_close;              then _fail "empty argv must NOT be detected"; fi
            if _pool_clean_args_is_close --json;       then _fail "flags-only must NOT be detected"; fi
        }
        # Integration: close flips connected true→false (Chrome-FREE via overrides + no-op exec).
        # KEY: AGENT_BROWSER_REAL (env) → pool_config_init → POOL_REAL_BIN=noop. POOL_REAL_BIN=
        # inline is OVERWRITTEN by config_init and would run the REAL agent-browser (AGENTS.md
        # violation). Verified host-side.
        test_close_marks_lease_disconnected() {
            setup                                   # temp state dir + AGENT_BROWSER_POOL_STATE
            pool_config_init; pool_state_init
            pool_lease_write 1 "$ABPOOL_TEST_ROOT/active/1" 53420 abpool-1 1 pi 100 "$ABPOOL_TEST_ROOT" 0 0 true
            assert_eq "true" "$(jq -r .connected "$POOL_LANES_DIR/1.json")" "precondition connected=true"
            # Override the Chrome/daemon-dependent steps so pool_wrapper_main reaches the close path.
            pool_ensure_connected() { return 0; }                       # step h: no daemon probe
            pool_lease_find_mine()   { printf '1\n'; return 0; }        # step e: hand back lane 1
            printf '#!/bin/sh\nexit 0\n' > "$ABPOOL_TEST_ROOT/noop.sh"; chmod +x "$ABPOOL_TEST_ROOT/noop.sh"
            # Subshell: exec replaces the SUBSHELL only; the parent asserts afterward.
            # AGENT_BROWSER_REAL (prefix env) is inherited by pool_config_init inside wrapper_main.
            ( AGENT_BROWSER_REAL="$ABPOOL_TEST_ROOT/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                  pool_wrapper_main close --json )
            assert_eq "false" "$(jq -r .connected "$POOL_LANES_DIR/1.json")" "connected after close"
            jq -e ".lane==1 and .port==53420 and .session==\"abpool-1\" and .owner.comm==\"pi\"" \
                "$POOL_LANES_DIR/1.json" >/dev/null || _fail "siblings not preserved"
        }
  - RUN: bash test/validate.sh   # (if added to selftests)  — or —  bash test/close_rebind.sh
  - EXPECT: green; zero residual processes (the no-op exec exits 0; setup's trap reaps temp).
  - NOTE: do NOT add a Chrome-dependent end-to-end close→rebind test here — that is S3
        (P1.M3.T1.S3). S1's test is the Chrome-free WRITE-side assertion only.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern 1: the predicate (verify-or-add below _pool_clean_args_is_bare_connect) -------
_pool_clean_args_is_close() {
    local -a orig=("$@")
    local i=0 tok cmd=""
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;
            -*)             i=$((i+1)) ;;
            *)              cmd="$tok"; break ;;
        esac
    done
    [[ "$cmd" == close ]]
}

# --- Pattern 2: the wiring block (verify-or-add in pool_wrapper_main, before step k) --------
    if _pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"; then
        if ! ( pool_lease_update "$N" connected false ) 2>/dev/null; then
            _pool_log "pool_wrapper_main: close: could not mark lane $N connected=false (non-fatal; proceeding to exec)"
        fi
    fi

# --- Pattern 3: the test's no-op exec (AGENT_BROWSER_REAL, NOT POOL_REAL_BIN) --------------
    ( AGENT_BROWSER_REAL="$ABPOOL_TEST_ROOT/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json )

# --- Critical micro-rules ----------------------------------------------------------------
#  * AGENT_BROWSER_REAL (env) → config_init → POOL_REAL_BIN. Inline POOL_REAL_BIN= is overwritten.
#  * `( pool_lease_update … ) 2>/dev/null || _pool_log` — subshell contains pool_die's exit 1.
#  * `( AGENT_BROWSER_REAL=… pool_wrapper_main … )` — subshell survives the exec; prefix env
#    is inherited by config_init inside wrapper_main.
#  * final `[[ "$cmd" == close ]]` is the function's return status (terse-predicate idiom).
#  * close != connect → step k's bare-connect short-circuit never fires for a close argv.
#  * the block runs BEFORE exec; the test asserts the lease AFTER the (subshell) wrapper returns.
```

### Integration Points

```yaml
CONSUMED (already implemented — S1 composes them):
  - pool_lease_update(lane, field, value) (lib/pool.sh:768): pool_die on missing/corrupt lease
        or non-JSON value; returns 0 on success; atomic re-publish. S1 calls it as
        `pool_lease_update "$N" connected false` (value `false` → JSON boolean; host-verified).
  - pool_wrapper_main (3565): edit/verify site. Step j writes POOL_CLEAN_ARGS; step k = exec.
  - _pool_clean_args_is_bare_connect (~3710): the predicate S1 mirrors.
  - pool_normalize_close/connect, pool_strip_session_args, pool_force_session: unchanged.

PROVIDED (later subtasks; S1 does NOT implement):
  - P1.M3.T1.S2: pool_ensure_connected READS .connected, skips the early-exit when false.
        Round-trip already sound: ensure_connected step c sets connected=true on reconnect (~2430).
  - P1.M3.T1.S3: Chrome-dependent end-to-end close→rebind test.

CONFIG / DATABASE / ROUTES: none. No env vars/globals/schema change. One lease field flipped.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n lib/pool.sh && echo OK-syntax
shellcheck -S warning lib/pool.sh && echo OK
# Expected: OK-syntax + OK (must be clean whether the prod code was just added or already present).
```

### Level 2: Unit Tests (predicate — pure, Chrome-free)

```bash
# 2a. Predicate truth table (host-verified form).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_clean_args_is_close close && echo close=1; \
         _pool_clean_args_is_close --json close && echo jsonclose=1; \
         _pool_clean_args_is_close close --json && echo closejson=1; \
         for c in open connect; do if _pool_clean_args_is_close $c; then echo "$c=FAIL"; else echo "$c=0"; fi; done; \
         if _pool_clean_args_is_close; then echo empty=FAIL; else echo empty=0; fi'
# Expected: close=1, jsonclose=1, closejson=1, open=0, connect=0, empty=0.

# 2b. Predicate is pure.
bash -c '
  body="$(sed -n "/^_pool_clean_args_is_close() {/,/^}/p" lib/pool.sh)"
  grep -qE "pool_die|_pool_log|>>?|[[:space:]]echo " <<<"$body" && { echo FAIL; exit 1; } || echo OK-pure'
# Expected: OK-pure.
```

### Level 3: Integration Tests (Chrome-FREE via overrides + no-op exec; AGENT_BROWSER_REAL)

```bash
# 3a. close flips connected true→false; siblings preserved. (NOTE: AGENT_BROWSER_REAL prefix env.)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 0 0 true; \
         test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"; \
         pool_ensure_connected() { return 0; }
         pool_lease_find_mine()   { printf "1\n"; return 0; }
         ( AGENT_BROWSER_REAL="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json ); \
         test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "false" && echo OK-close-flips'
# Expected: OK-close-flips.

# 3b. non-close (open) does NOT flip connected.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 0 0 true; \
         pool_ensure_connected() { return 0; }
         pool_lease_find_mine()   { printf "1\n"; return 0; }
         ( AGENT_BROWSER_REAL="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main open about:blank ); \
         test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true" && echo OK-open-unchanged'
# Expected: OK-open-unchanged.

# 3c. corrupt lease does NOT abort the close (subshell defense).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
mkdir -p "$tmp/state/lanes"; printf 'NOT JSON' > "$tmp/state/lanes/1.json"
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_ensure_connected() { return 0; }
         pool_lease_find_mine()   { printf "1\n"; return 0; }
         ( AGENT_BROWSER_REAL="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close ) \
             && echo OK-close-survives-corrupt-lease'
# Expected: OK-close-survives-corrupt-lease.

# 3d. Run the new test via the framework.
bash test/validate.sh        # (if added to selftests)   — or —   bash test/close_rebind.sh
# Expected: all pass, no residual processes.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Round-trip types (boolean) on the live lib.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'source lib/pool.sh; pool_config_init; pool_state_init;
    pool_lease_write 1 /x 53420 abpool-1 1 pi 100 /c 0 0 true;
    pool_lease_update 1 connected false;
    echo "connected=$(jq -r .connected "$POOL_LANES_DIR/1.json") type=$(jq -r ".connected|type" "$POOL_LANES_DIR/1.json")"'
# Expected: connected=false type=boolean.

# 4b. Confirm no stray runtime artifacts (only lib/pool.sh + the test file touched).
git status --porcelain --untracked-files=all
# Expected: lib/pool.sh (+ test file) only; no .json/.tmp/.log left in the repo tree.

# 4c. Sanity: AGENT_BROWSER_REAL (not POOL_REAL_BIN) is what makes the no-op run. Confirm the
#     test does NOT invoke the real agent-browser (AGENTS.md):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\necho NOOP-RAN\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
    pool_lease_write 1 "'"$tmp"'/a" 53420 abpool-1 1 pi 100 "'"$tmp"'" 0 0 true;
    pool_ensure_connected(){ return 0;}; pool_lease_find_mine(){ printf "1\n"; return 0;};
    out="$( AGENT_BROWSER_REAL="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 pool_wrapper_main close --json )";
    [[ "$out" == *"NOOP-RAN"* ]] && echo OK-noop-ran || echo "FAIL: real binary ran: $out"'
# Expected: OK-noop-ran.
```

## Final Validation Checklist

### Technical Validation

- [ ] Task 0 current-state check done (production code confirmed present OR implemented per spec).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` zero warnings.
- [ ] Predicate truth table correct (2a); predicate is pure (2b).
- [ ] close flips `connected` true→false with siblings+owner preserved (3a); types are boolean (4a).
- [ ] non-close leaves `connected` unchanged (3b); corrupt lease does not abort close (3c).
- [ ] **The new test runs green via the framework (3d); zero residual processes.**
- [ ] The test uses AGENT_BROWSER_REAL (not POOL_REAL_BIN) — does NOT invoke the real binary (4c).

### Feature Validation

- [ ] The close path marks the lease `connected=false` BEFORE exec (PRD §2.4 step 4 / §2.5 / §2.15).
- [ ] S2 will be able to read `.connected` and force a rebind; round-trip is sound.
- [ ] All other pool_wrapper_main steps (a–k) behave as before for non-close commands.

### Code Quality / Documentation

- [ ] Mirrors `_pool_clean_args_is_bare_connect` style; strict-mode idioms followed.
- [ ] No new globals/env/dependencies; one lease field is the only on-disk effect.
- [ ] Comments document the WHY (lingering session → rebind skipped → transparency risk).
- [ ] No user-facing doc change required (internal; PRD §2.5/§2.15 describe the semantics).

---

## Anti-Patterns to Avoid

- ❌ Don't blindly re-add the predicate/wiring — VERIFY the current state first (it's likely
  already present); duplicate-add creates a conflict.
- ❌ Don't set `POOL_REAL_BIN=…` inline in the test — `pool_config_init` overwrites it from
  `AGENT_BROWSER_REAL`, so the REAL agent-browser would run (AGENTS.md violation). Use
  **`AGENT_BROWSER_REAL`** (prefix env on the subshell).
- ❌ Don't use `pool_lease_update … || true` to defend — pool_die `exit 1`s; use a **subshell**
  `( pool_lease_update … ) 2>/dev/null || _pool_log …`.
- ❌ Don't implement the READ side (pool_ensure_connected) — that's S2.
- ❌ Don't add the Chrome end-to-end rebind test — that's S3.
- ❌ Don't pass `connected "false"` (quoted) or `0`/`1` — `connected false` splices the boolean.
- ❌ Don't place the block AFTER exec; don't log on the happy path; don't reimplement the
  flag-scan inline when `_pool_clean_args_is_close` mirrors the twin.
