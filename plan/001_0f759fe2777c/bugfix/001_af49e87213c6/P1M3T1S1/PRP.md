# PRP — P1.M3.T1.S1: Set `connected=false` in `pool_wrapper_main` close path before exec

> **Bugfix context**: This subtask implements **Issue 3** (close→next-driving command may skip
> a needed daemon rebind) from
> `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` §"ISSUE 3" (Fix
> Approach #1: *"After the wrapper intercepts/scopes a `close` … mark the lease
> `connected=false` so the next call's `pool_ensure_connected` takes the reconnect/relaunch
> branch and re-binds"*). It is the FIRST of three subtasks under **P1.M3.T1**:
> **S1** (THIS) writes `connected=false` on close; **S2** (P1.M3.T1.S2, next) makes
> `pool_ensure_connected` READ that flag and skip its early-exit; **S3** (P1.M3.T1.S3) adds the
> end-to-end close→rebind test. S1 touches ONLY the close path of `pool_wrapper_main` + adds
> ONE small predicate helper. It does NOT touch `pool_ensure_connected` (S2's job), any boot /
> port code (P1.M2's job), or any config code (P1.M1's job — already Complete).

---

## Goal

**Feature Goal**: When the wrapper executes an agent's `close` command, **mark the lane's lease
`connected=false` BEFORE the terminal `exec`**, so the agent's *next* driving command forces
`pool_ensure_connected` (S2) to re-bind the daemon to the still-running Chrome instead of
skipping the rebind. Today the close path runs `close` like any driving command and `exec`s —
nothing records that the daemon binding was just detached, so the lease's `connected` stays
`true`; `pool_daemon_connected` then returns 0 (lingering session + alive Chrome) and the next
call's `pool_ensure_connected` early-exits, skipping the reconnect (Issue 3 / PRD §2.15
transparency risk). S1 closes the WRITE half of that gap.

**Deliverable** (in-place edits to ONE file — `lib/pool.sh`; + ONE test addition):
1. **ADD** a small predicate helper **`_pool_clean_args_is_close ARGS...`** (returns 0 iff the
   first non-flag token is the command `close`; returns 1 otherwise). It is the twin of the
   existing `_pool_clean_args_is_bare_connect` (same flag-scan `case`), placed directly below it.
2. **ADD** a ~10-line block inside `pool_wrapper_main` — a new step between step j
   (`pool_force_session`) / the `POOL_CLOSE_ALL_SEEN` observability log and step k
   (`_pool_clean_args_is_bare_connect` short-circuit + `exec`). When
   `_pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"` is true, run
   `pool_lease_update "$N" connected false` (defensively, in a subshell — see Gotchas) so the
   lease reflects the detached binding. **MUST run before `exec`** (exec replaces the process;
   nothing runs after).
3. **UPDATE** the inline comments around step k to document the new `connected=false` update on
   close and WHY ("close detaches the daemon binding but the session lingers in `session list`;
   marking `connected=false` forces the next `pool_ensure_connected` to rebind").
4. **ADD** a Chrome-free test (predicate unit test + an isolated integration test via function
   overrides + no-op `exec` in a subshell) asserting the lease is `connected=false` after a
   close invocation.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh`, `_pool_clean_args_is_bare_connect` and
  `_pool_clean_args_is_close` both exist; `_pool_clean_args_is_close close` returns 0;
  `_pool_clean_args_is_close --json close` returns 0; `_pool_clean_args_is_close open` returns 1;
  `_pool_clean_args_is_close connect` returns 1; `_pool_clean_args_is_close` (empty) returns 1.
- A lane with a `connected=true` lease that receives a `close` via `pool_wrapper_main` (with the
  Chrome/daemon-dependent steps overridden for the test) has its lease flipped to
  `"connected": false` (JSON boolean) on disk, with every other field preserved, and the wrapper
  still `exec`s the close (the override's no-op).
- A `close --all` is normalized to a scoped `close` by step i (already), and S1's block still
  fires (command token is `close`) → `connected=false`. An `open` / `click` / `connect` command
  does NOT flip `connected` (predicate returns 1 → block skipped).
- A (very unlikely) corrupt/missing lease does NOT abort the close: the `pool_lease_update` runs
  in a subshell so a `pool_die` is contained, a warning is logged, and the close still `exec`s.
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean; the whole file still
  sources under `set -euo pipefail`; all prior behavior unchanged.

## User Persona

**Target User**: The agent (a `pi`-ancestor process) running `agent-browser close` to
disconnect its lane's daemon from Chrome (PRD §2.5: "close = disconnect-only; next call reuses
the same browser"). Internal-only change — no operator-visible surface.

**Use Case**: `agent-browser close` → daemon binding detached (session lingers in list, Chrome
stays alive). Next `agent-browser open <url>` MUST reuse the same browser and succeed — which
requires the pool to re-bind the daemon. S1 ensures the lease records the detach so S2's
`pool_ensure_connected` knows to rebind.

**Pain Points Addressed**: Without S1+S2, the command immediately following a `close` may see a
spurious failure (daemon not re-bound) — violating PRD §2.15's "the agent cannot tell pooling is
happening / must never see failures" transparency contract. S1 provides the signal (lease
`connected=false`) that S2 consumes to force the rebind.

## Why

- **Closes the WRITE half of Issue 3.** The root cause (key_findings §ISSUE 3) is that no code
  path flips `connected=false` after a close, so the lease lies ("connected" while the binding is
  detached). S1 makes the close path tell the truth. S2 then acts on it. (Doing S1 first keeps
  each change small, single-purpose, and independently testable.)
- **Aligns with PRD §2.4 step 4's design.** The PRD's ENSURE CONNECTED step is meant to
  "reconnect if the daemon died." After a disconnect-only close the binding IS effectively dead
  even though the probes can't see it; the `connected=false` flag is the durable record that
  survives across the two separate process invocations (close runs in one `agent-browser` call;
  the next driving command runs in another).
- **Defensive + harmless even before S2.** Writing `connected=false` on close has NO effect on
  any current code path (nothing reads `.connected` in a way that changes behavior until S2
  lands). So S1 is safe to land independently. Once S2 lands, the full fix activates.
- **Minimal, surgical, testable.** One predicate + one `if` block + comments. The predicate is a
  pure function (Chrome-free unit test); the wiring is verifiable with function overrides (no
  real Chrome/daemon needed — AGENTS.md-compliant).

## What

User-visible behavior: none directly (internal). Observable contract:

| Change | Where | Behavior |
|---|---|---|
| **NEW** `_pool_clean_args_is_close ARGS...` | `lib/pool.sh`, directly below `_pool_clean_args_is_bare_connect` (~line 3760) | Predicate: scan ARGS with the same flag-skip `case` as `_pool_clean_args_is_bare_connect`; return 0 iff the first non-flag token equals `close`, else return 1. Never `pool_die`, never echoes, reads only `$@`. |
| **MODIFY** `pool_wrapper_main` | new block between the `POOL_CLOSE_ALL_SEEN` log (~line 3650) and the step-k comment (~line 3652) | `if _pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"; then ( pool_lease_update "$N" connected false ) 2>/dev/null \|\| _pool_log "…non-fatal…"; fi` |
| **COMMENTS** step-k header | expand the step-k comment block | document the new close→`connected=false` update + WHY |

### Success Criteria

- [ ] `_pool_clean_args_is_close` defined directly below `_pool_clean_args_is_bare_connect`;
  returns 0 for `close`, `--json close`, `close --json`, `--session x close` (defense-in-depth);
  returns 1 for `open`, `click`, `connect`, `connect 98765`, empty argv, flags-only argv.
- [ ] `_pool_clean_args_is_close` NEVER calls `pool_die`, NEVER echoes, NEVER writes — it is a
  pure 0/1 predicate (mirrors `_pool_clean_args_is_bare_connect`'s contract).
- [ ] `pool_wrapper_main`, when `POOL_CLEAN_ARGS`'s command is `close`, calls
  `pool_lease_update "$N" connected false` so the on-disk lease's `.connected` becomes the JSON
  boolean `false`, with ALL other fields (version/lane/ephemeral_dir/port/session/owner/
  chrome_pid/chrome_pgid/acquired_at/last_seen_at) byte-identical.
- [ ] The `connected=false` write happens BEFORE `exec` (exec replaces the process) — verified
  by the test asserting the lease AFTER the (subshell) `pool_wrapper_main close` returns.
- [ ] A non-close command (`open`/`click`/`connect`) does NOT alter `.connected` (predicate
  returns 1 → block skipped).
- [ ] The `pool_lease_update` call is wrapped so a `pool_die` (corrupt/missing lease) is
  CONTAINED (subshell) and the close still `exec`s; a warning is logged via `_pool_log`.
  (Rationale: `|| true` alone does NOT catch `pool_die` — see Gotchas.)
- [ ] `close --all` (normalized to scoped `close` at step i) still triggers the
  `connected=false` write (command token is `close`).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean; full file sources
  under `set -euo pipefail`; `_pool_clean_args_is_bare_connect`, `pool_wrapper_main`, and every
  other function unchanged in behavior.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the exact step map of `pool_wrapper_main`
(lines a→k) with the precise insertion point (after the `POOL_CLOSE_ALL_SEEN` block, before the
step-k comment); the exact `pool_lease_update` contract (and the **`pool_die` cannot be caught
by `|| true`** gotcha → use a subshell); the host-verified round-trip (`pool_lease_write … true`
→ `pool_lease_update … connected false` → `.connected == false`); the sibling predicate
`_pool_clean_args_is_bare_connect` to mirror; the S2 consumer contract (what
`pool_ensure_connected` will do with the flag — NOT implemented here); the Chrome-FREE test
design (function overrides + no-op exec in a subshell); and the verbatim paste-ready code +
exact `oldText`/`newText` anchors.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: §"ISSUE 3" — root cause (pool_daemon_connected returns 0 after close → ensure_connected
        early-exits → rebind skipped), "The Close Path Does NOT Mark connected=false", and the
        Fix Approach (#1 = mark connected=false on close, #2 = ensure_connected reads it [S2]).
  pattern: Fix #1 is THIS task; Fix #2 is S2. S1 = write side only.
  gotcha: the doc's "`|| true`" suggestion is INSUFFICIENT against pool_die — see this PRP's
        Gotchas (use a subshell).

- file: .pi-subagents/artifacts/outputs/3a827294/plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/scout-boot-connect.md
  why: §"ISSUE 3" (3.1–3.6) is the deep static-analysis scout: confirms pool_daemon_connected's
        lingering-session docstring, pool_ensure_connected's early-exit line, the close path in
        pool_wrapper_main (3.3), pool_normalize_close's behavior (3.4), and that NO code path
        sets connected=false after close (3.5). §"Close→rebind flow (ISSUE 3)" diagrams it.
  pattern: 3.3 maps the close steps; 3.4 confirms normalize_close only strips --all.
  gotcha: 3.6 notes PRD §2.5 "next call reuses the same browser" is the contract being honored.

- file: PRD.md (bugfix snapshot) # plan/001_0f759fe2777c/bugfix/001_af49e87213c6/prd_snapshot.md
  why: §2.4 step 4 (ENSURE CONNECTED — "reconnect if daemon died"), §2.5 ("close =
        disconnect-only; next call reuses the same browser"), §2.15 (transparency — agent must
        never see failures), §2.8 (lease `connected` boolean field).
  pattern: §2.5 is the semantic S1 serves; §2.15 is the contract S1+S2 protect.
  gotcha: none new.

# THIS task's own research (host-verified)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S1/research/close-rebind-s1-findings.md
  why: the step map, the pool_lease_update contract + the pool_die-vs-||  gotcha, the host-
        verified round-trip, the helper-predicate rationale, the Chrome-free test design, the
        parallel-item conflict check (NONE), and the scope guard.
  pattern: §1 (insertion point), §2 (pool_lease_update + subshell defense), §4 (predicate),
        §6 (test design).
  gotcha: §2's "pool_die can't be caught by || true" is the #1 implementation trap.

# The code under edit — READ the named functions in lib/pool.sh
- file: lib/pool.sh
  why: pool_wrapper_main (3565–3691) is the edit site; _pool_clean_args_is_bare_connect
        (3710–3760) is the predicate to MIRROR for the new _pool_clean_args_is_close;
        pool_lease_update (768–806) is the primitive S1 calls; pool_normalize_close (3250) +
        pool_normalize_connect build POOL_NORM_ARGS; pool_strip_session_args builds
        POOL_CLEAN_ARGS (step j); pool_ensure_connected (2390) is the S2 consumer (do NOT edit).
  pattern: copy _pool_clean_args_is_bare_connect's flag-scan `case` verbatim, change the
        command test to `close` and drop the "scan past command for a positional" tail (close
        detection only needs the FIRST non-flag token == close).
  gotcha: POOL_CLEAN_ARGS already had --session stripped at step j, but mirror the full case
        anyway (defense-in-depth). close != connect, so step k's bare-connect short-circuit
        never fires for a close argv — order is safe.

- file: test/validate.sh
  why: the test FRAMEWORK (hand-rolled, no bats): setup() (temp state dir + AGENT_BROWSER_POOL_STATE),
        assert_eq / _fail, run_test NAME FN (body in a subshell), abpool_run_suite PREFIX,
        spawn_sim_owner, the EXIT/INT/TERM trap that reaps+removes everything. Sibling bugfix
        tasks (P1.M2.T1.S1/S2) added their pure-function selftests HERE.
  pattern: add `selftest__pool_clean_args_is_close` + a close→lease integration test as new
        test_* / selftest_* functions sourced via `source test/validate.sh` (or as a new
        test/close_rebind.sh that sources it). The integration test uses function overrides
        (pool_ensure_connected/pool_lease_find_mine) + a no-op POOL_REAL_BIN + a subshell —
        Chrome-free per AGENTS.md.
  gotcha: pool_wrapper_main ends in exec → MUST run it in a `( … )` subshell so the test
        survives; the overrides are inherited by the subshell (bash fork semantics).

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (`set -e`) exemptions — the condition of `if`/`||`/`&&` is EXEMPT, so
        `if _pool_clean_args_is_close …; then …` and `( pool_lease_update … ) || _pool_log …`
        are safe even when the predicate/lease-update return non-zero.
  section: `-e` (errexit).
- url: https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution
  why: `( … )` is a SUBSHELL (a fork of the current shell) — it inherits ALL functions and
        variables, and a `pool_die` (exit) inside it kills only the subshell, not the parent.
        This is WHY the subshell contains pool_die (the `|| true` defense made real).
  section: Command Substitution / Grouping (subshell).
- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: declare and assign SEPARATELY (`local x; x="$(…)"`) — the predicate + wrapper already
        obey this; keep the new code consistent.
- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote expansions (universal; pass "${POOL_CLEAN_ARGS[@]}" quoted).

# Sibling/parallel contracts (treated as truth)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S3/PRP.md
  why: P1.M2.T1.S3 (Implementing in parallel) is TEST-ONLY on test/concurrency.sh (removes the
        0.3s stagger). Its PRP explicitly states P1.M3 is disjoint from the boot/re-pick path.
        NO file overlap, NO conflict. Confirm before editing that concurrency.sh is the only
        file it touches.
  gotcha: none — S1 and S3 do not interact.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S2/PRP.md   # NEXT task (not yet written)
  why: S2 will make pool_ensure_connected READ .connected and skip its early-exit when false.
        S1 only WRITES connected=false; S1 must NOT edit pool_ensure_connected. The round-trip
        (close→false here, reconnect→true in S2's path) is already wired: pool_ensure_connected
        step c already calls `pool_lease_update "$lane" connected true` on a successful reconnect.
  gotcha: do NOT pre-implement S2's read — keep S1 strictly write-side.
```

### Current Codebase tree (the IMPLEMENTED repo — not greenfield)

```bash
agent-browser-pool/
├── PRD.md                                # READ-ONLY
├── README.md
├── install.sh
├── bin/{agent-browser, agent-browser-pool}
├── lib/
│   └── pool.sh                           # 4510 LOC — FULLY IMPLEMENTED
│                                         #   pool_lease_update (768)
│                                         #   pool_ensure_connected (2390)  ← S2 edits, NOT S1
│                                         #   pool_daemon_connected (1727)
│                                         #   pool_dispatch_classify (3139)
│                                         #   pool_normalize_close (3250)
│                                         #   pool_strip_session_args (3427)
│                                         #   pool_force_session (3493)
│                                         #   pool_wrapper_main (3565)       ← S1 edits (close path)
│                                         #   _pool_clean_args_is_bare_connect (3710) ← S1's mirror source
├── test/
│   ├── validate.sh                       # framework + selftests (S1 adds tests here)
│   ├── transparency.sh                   # close --all scope tests (Chrome-dependent; S1's test is Chrome-FREE + complementary)
│   ├── concurrency.sh                    # P1.M2.T1.S3 (parallel) edits this
│   └── release_reaper.sh
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/{key_findings,system_context,external_deps}.md
    ├── P1M3T1S1/                         # THIS subtask
    │   ├── PRP.md                         # THIS FILE
    │   └── research/close-rebind-s1-findings.md
    └── ...
```

### Desired Codebase tree with files to be added and responsibility

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — (1) ADD _pool_clean_args_is_close below _pool_clean_args_is_bare_connect;
                  #                     (2) ADD the close→connected=false block in pool_wrapper_main
                  #                         (between the POOL_CLOSE_ALL_SEEN log and step k);
                  #                     (3) EXPAND the step-k comment.
# + test addition (in test/validate.sh selftests, OR a new test/close_rebind.sh sourcing validate.sh)
```

**File responsibility**: `lib/pool.sh` is the single shared library. S1 adds the WRITE side of
the close→rebind fix (the predicate + the on-close lease flip) and leaves the READ side
(`pool_ensure_connected`) entirely to S2.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the #1 trap): `pool_lease_update "$N" connected false || true` does NOT defend
# against failure. pool_lease_update pool_die()'s on a bad lane / missing lease / corrupt lease /
# non-JSON value — and pool_die does `exit 1` (kills the PROCESS), NOT `return 1`. `|| true`
# only catches a non-zero RETURN. So a corrupt lease (very unlikely — it was read at step h)
# would ABORT the wrapper and the agent's close command, violating PRD §2.15 ("close must always
# run"). FIX: run it in a SUBSHELL so pool_die's exit kills only the subshell:
#       if ! ( pool_lease_update "$N" connected false ) 2>/dev/null; then
#           _pool_log "pool_wrapper_main: close: could not mark lane $N connected=false (non-fatal)"
#       fi
# The 2>/dev/null suppresses pool_die's stderr (keeps the agent's output clean); _pool_log records
# the rare event. The close then proceeds to exec. (research §2; host-verified semantics.)

# CRITICAL (insertion point): the new block MUST go AFTER POOL_CLEAN_ARGS is built (step j:
# pool_strip_session_args writes it) and BEFORE exec (step k: terminal). The precise spot is
# directly after the POOL_CLOSE_ALL_SEEN `if/fi` observability block (~line 3650) and before the
# `# --- k. EXEC the real binary` comment (~line 3652). POOL_CLEAN_ARGS is the cleaned argv
# (--session stripped, --all stripped for close). (research §1.)

# CRITICAL (exec replaces the process): NOTHING runs after `exec "$POOL_REAL_BIN" …` (step k,
# line 3691). The connected=false write MUST be before it. The test MUST run pool_wrapper_main in
# a `( … )` subshell so the test process survives the exec (the exec replaces the subshell only).

# CRITICAL (close != connect): the bare-connect short-circuit (step k, _pool_clean_args_is_bare_connect)
# fires ONLY for a bare `connect`. For a `close` argv it returns 1 → the short-circuit is skipped →
# the normal `exec` runs. So placing the close block BEFORE the bare-connect check is SAFE (mutually
# exclusive command shapes). Do not worry about ordering between them.

# GOTCHA (POOL_CLEAN_ARGS already had --session stripped): step j (pool_strip_session_args) removed
# every --session. So when _pool_clean_args_is_close scans POOL_CLEAN_ARGS, --session won't appear.
# STILL mirror the full flag-skip `case` (--session/--session=/--*/-*) for defense-in-depth (the
# predicate stays correct if ever called on raw argv, and matches its sibling exactly).

# GOTCHA (SC2155): declare locals FIRST, assign AFTER. The predicate uses `local -a orig=("$@")`
# (array init from $@ is safe — not a command substitution) + `local i=0 tok cmd=""` then assigns.
# Do NOT write `local x="$(…)"`.

# GOTCHA (set -e + predicate): `_pool_clean_args_is_close` returns 1 for non-close — a bare call
# would ABORT under set -e. ALWAYS use it as `if _pool_clean_args_is_close …; then …` (the `if`
# condition is errexit-exempt).

# GOTCHA (no logging on the happy path): pool_wrapper_main already logs at the operation level.
# Log ONLY the rare defensive-failure case (the subshell `||` branch), not the successful flip.
# (Matches the file's "log operations, not primitives" convention.)

# GOTCHA (S2 owns the read side): do NOT edit pool_ensure_connected. S1 writes connected=false;
# S2 makes ensure_connected read it. Pre-implementing S2 would conflict with S2's PRP and blur the
# change boundary. The round-trip is already sound: ensure_connected step c sets connected=true on
# reconnect (line ~2430) — so once S2 lands, close→false→reconnect→true cycles correctly.

# GOTCHA (connected is a JSON BOOLEAN): `pool_lease_update "$N" connected false` splices `false` as
# raw JSON (--argjson) → the boolean false, NOT the string "false" and NOT 0. Host-verified: after
# the call, `jq -r .connected` prints `false` and `jq '.connected|type'` prints `boolean`. Do not
# pass `"false"` (quoted) or 0/1 — those would store the wrong type.
```

## Implementation Blueprint

### Data models and structure

No schema/globals/env changes. S1 adds ONE predicate function and ONE ~10-line block. The
"data model" touched is a single lease field (`.connected`, boolean) flipped `true→false` via
the existing `pool_lease_update` primitive (atomic tmp+mv; preserves all siblings + the `owner`
sub-object). The lease path is `$POOL_LANES_DIR/$N.json` (frozen by `pool_config_init`, run at
step a of `pool_wrapper_main`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the edit site + the mirror source are as described (the file has evolved)
  - RUN: bash -c 'set -euo pipefail; source lib/pool.sh; type pool_wrapper_main
             _pool_clean_args_is_bare_connect pool_lease_update' >/dev/null && echo OK-fns
  - EXPECT: OK-fns. (All three present — the implemented repo.)
  - RUN (locate the insertion point — confirm POOL_CLOSE_ALL_SEEN block then step-k comment):
        grep -nE 'POOL_CLOSE_ALL_SEEN|--- k\. EXEC|_pool_clean_args_is_bare_connect\(\)|exec "\$POOL_REAL_BIN"' lib/pool.sh
  - EXPECT: a POOL_CLOSE_ALL_SEEN `if`/`fi` block, THEN a `# --- k. EXEC` comment, THEN (inside
        step k) the bare-connect check and `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"`. The
        new block goes BETWEEN the POOL_CLOSE_ALL_SEEN block and the `# --- k. EXEC` comment.
  - RUN (confirm the mirror predicate's flag-scan to copy):
        sed -n '/^_pool_clean_args_is_bare_connect() {/,/^    # --- a\./p' lib/pool.sh | head -30
  - EXPECT: the `case "$tok" in --session)… --session=*)… --*)… -*)… *)…` flag-scan.
  - RUN (host re-confirm the round-trip works against the live lib):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'set -euo pipefail; source lib/pool.sh;
            pool_config_init; pool_state_init;
            pool_lease_write 1 /x 53420 abpool-1 1 pi 100 /c 200 201 true;
            pool_lease_update 1 connected false;
            test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "false" && echo OK-roundtrip'
  - EXPECT: OK-roundtrip.
  - RUN: bash -n lib/pool.sh && echo OK-syntax
  - EXPECT: OK-syntax.

Task 1: ADD _pool_clean_args_is_close() directly below _pool_clean_args_is_bare_connect()
  - PLACEMENT: immediately after _pool_clean_args_is_bare_connect's closing `}` (~line 3760),
        before the `# Admin CLI — status` section banner.
  - IMPLEMENT (verbatim-ready — paste this function body):
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
        # LOGIC: walk $@; the first NON-flag token is the COMMAND. Return 0 iff it is `close`.
        # (Unlike _pool_clean_args_is_bare_connect we do NOT scan PAST the command — close
        # detection only cares about the command token itself; `close --all`/`close --json` are
        # still `close`. --all is already stripped by pool_normalize_close at step i anyway.)
        #
        # GOTCHA — POOL_CLEAN_ARGS has had --session stripped at step j (pool_strip_session_args),
        #   so --session won't appear here; the full flag-skip case is kept for defense-in-depth
        #   (correctness if ever called on raw argv) + exact parity with the connect sibling.
        # GOTCHA — return 0/1 ONLY (never pool_die, never echo, never write); reads only "$@".
        # GOTCHA — under set -e, call as `if _pool_clean_args_is_close …; then …` (the predicate
        #   legitimately returns 1 for non-close — a bare call would abort).
        # PRECONDITION: none.
        _pool_clean_args_is_close() {
            local -a orig=("$@")
            local i=0 tok cmd=""
            while (( i < ${#orig[@]} )); do
                tok="${orig[i]}"
                case "$tok" in
                    --session)      i=$((i+2)) ;;   # space form: flag + value (stripped by step j; kept for parity)
                    --session=*)    i=$((i+1)) ;;   # equals form (stripped by step j; kept for parity)
                    --*)            i=$((i+1)) ;;   # --json, --all, --cdp, …
                    -*)             i=$((i+1)) ;;   # -i -c -d -p …
                    *)              cmd="$tok"; break ;;   # first non-flag = COMMAND
                esac
            done
            [[ "$cmd" == close ]]
        }
  - FOLLOW pattern: _pool_clean_args_is_bare_connect's flag-scan `case` (verbatim case arms);
        `local -a orig=("$@")` (array-from-$@ is SC2155-safe); `local i=0 tok cmd=""` declared
        then used; `while (( ))` condition (errexit-exempt); final `[[ "$cmd" == close ]]`
        returns the predicate's exit status (a bare `[[ ]]` as the LAST statement is fine — its
        status is the function's status; it is NOT under a `set -e` abort because it's the final
        command... SEE GOTCHA below).
  - GOTCHA (final `[[ ]]` as function exit status): the last line `[[ "$cmd" == close ]]` makes
        the `[[ ]]` test's exit status the function's return. This is the SAME idiom used
        throughout the codebase for one-line predicates. It is safe: a `[[ ]]` whose result is
        the function's return does NOT trigger `set -e` (errexit does not apply to the LAST
        command of a function when its status is the function's returned status — it propagates
        to the caller, where the caller MUST use it in `if`/`||`). Callers do: `if
        _pool_clean_args_is_close …; then`.
        - ALTERNATIVE (equally valid, slightly more explicit): replace the last line with
          `if [[ "$cmd" == close ]]; then return 0; fi; return 1`. Either is acceptable; pick
          the one-liner for parity with the codebase's terse predicate style.
  - NAMING: _pool_clean_args_is_close (internal; twin of _pool_clean_args_is_bare_connect).
  - PLACEMENT: directly below _pool_clean_args_is_bare_connect's `}`.

Task 2: ADD the close→connected=false block in pool_wrapper_main (the core change)
  - PLACEMENT: in pool_wrapper_main, directly AFTER the POOL_CLOSE_ALL_SEEN `if/fi` block and
        BEFORE the `# --- k. EXEC the real binary` comment header.
  - EDIT (exact anchor — the oldText is the blank line + step-k comment header; newText inserts
        the new block between them):
        OLD TEXT (the boundary — keep the POOL_CLOSE_ALL_SEEN block, insert BEFORE the step-k comment):
            # Observability: log if we scoped a close --all (PRD §2.15: "close --all → cannot harm peers").
            if [[ "${POOL_CLOSE_ALL_SEEN:-0}" == "1" ]]; then
                _pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"
            fi

            # --- k. EXEC the real binary (step 5, terminal) -----------------------------
        NEW TEXT (new block inserted between the close-all log and step k):
            # Observability: log if we scoped a close --all (PRD §2.15: "close --all → cannot harm peers").
            if [[ "${POOL_CLOSE_ALL_SEEN:-0}" == "1" ]]; then
                _pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"
            fi

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

            # --- k. EXEC the real binary (step 5, terminal) -----------------------------
  - FOLLOW pattern: `if predicate; then …; fi` (errexit-exempt); `( cmd ) 2>/dev/null || …`
        subshell defense (contains pool_die); `_pool_log` only on the rare failure (no happy-path
        log spam — matches the file's operation-level logging convention).
  - GOTCHA: do NOT replace the `|| true` form from the item description literally — it does not
        defend against pool_die. Use the subshell form above (research §2).
  - GOTCHA: `_pool_clean_args_is_close` is defined in Task 1 (below this function in the file) —
        bash resolves functions dynamically at CALL time, so a function defined later in the file
        IS callable from an earlier function. No forward-reference problem.
  - NAMING/PLACEMENT: the block is unlabeled-internal (a comment banner marks it); it lives in
        pool_wrapper_main between step j's tail and step k.

Task 3: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh && echo OK                                    # syntax
  - RUN: shellcheck -S warning lib/pool.sh && echo OK                      # lint (zero warnings)
  - RUN (predicate defined + twin present):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type _pool_clean_args_is_close _pool_clean_args_is_bare_connect' >/dev/null && echo OK
  - RUN (predicate truth table):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_clean_args_is_close close              && echo "close=1"; \
                 _pool_clean_args_is_close --json close      && echo "jsonclose=1"; \
                 _pool_clean_args_is_close close --json      && echo "closejson=1"; \
                 if _pool_clean_args_is_close open;          then echo "open=FAIL";  else echo "open=0";  fi; \
                 if _pool_clean_args_is_close connect;       then echo "connect=FAIL";else echo "connect=0";fi; \
                 if _pool_clean_args_is_close connect 98765; then echo "connectpos=FAIL";else echo "connectpos=0";fi; \
                 if _pool_clean_args_is_close;               then echo "empty=FAIL"; else echo "empty=0"; fi; \
                 if _pool_clean_args_is_close --json;        then echo "flagsonly=FAIL";else echo "flagsonly=0";fi'
        # EXPECT: close=1, jsonclose=1, closejson=1, open=0, connect=0, connectpos=0, empty=0, flagsonly=0.
  - RUN (predicate is pure — never dies/echoes/writes):
        bash -c '
            body="$(sed -n "/^_pool_clean_args_is_close() {/,/^}/p" lib/pool.sh)"
            if grep -qE "pool_die|_pool_log|>>? *[\"/]|^[[:space:]]*echo " <<<"$body"; then
                echo "FAIL: body has side effects:"; echo "$body"; exit 1; fi
            echo OK-pure'
        # EXPECT: OK-pure.
  - RUN (INTEGRATION — close flips connected to false, Chrome-FREE via overrides):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 0 0 true; \
                 test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"; \
                 # --- override the Chrome/daemon-dependent steps so wrapper_main reaches the close path ---
                 pool_ensure_connected() { return 0; }        # step h: no daemon probe
                 pool_lease_find_mine()   { printf "1\n"; return 0; }   # step e: hand back lane 1
                 # --- run wrapper_main close in a SUBSHELL (exec replaces the subshell only) ---
                 ( POOL_REAL_BIN="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                       pool_wrapper_main close --json ); \
                 test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "false" && echo OK-close-flips'
        # EXPECT: OK-close-flips. (connected went true→false; all other fields preserved.)
  - RUN (INTEGRATION — non-close does NOT flip connected):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 0 0 true; \
                 pool_ensure_connected() { return 0; }
                 pool_lease_find_mine()   { printf "1\n"; return 0; }
                 ( POOL_REAL_BIN="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                       pool_wrapper_main open about:blank ); \
                 test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true" && echo OK-open-unchanged'
        # EXPECT: OK-open-unchanged. (open did not touch connected.)
  - RUN (INTEGRATION — siblings + owner preserved on the flip):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 2 "'"$tmp"'/active/2" 53421 abpool-2 55 pi 999 /home/x 7 8 true; \
                 pool_ensure_connected() { return 0; }
                 pool_lease_find_mine()   { printf "2\n"; return 0; }
                 ( POOL_REAL_BIN="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                       pool_wrapper_main close ); \
                 jq -e ".lane==2 and .port==53421 and .session==\"abpool-2\" and .owner.pid==55 and .owner.comm==\"pi\" and .owner.starttime==999 and .chrome_pid==7 and .chrome_pgid==8 and .connected==false" \
                     "$POOL_LANES_DIR/2.json" >/dev/null && echo OK-siblings-preserved'
        # EXPECT: OK-siblings-preserved.
  - RUN (defensive: corrupt lease does NOT abort the close):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '#!/bin/sh\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
        mkdir -p "$tmp/state/lanes"; printf 'NOT JSON' > "$tmp/state/lanes/1.json"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_ensure_connected() { return 0; }
                 pool_lease_find_mine()   { printf "1\n"; return 0; }
                 ( POOL_REAL_BIN="'"$tmp"'/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                       pool_wrapper_main close ) && echo OK-close-survives-corrupt-lease'
        # EXPECT: OK-close-survives-corrupt-lease. (The subshell contained pool_die; exec ran.)
  - RUN (regression: prior functions + the bare-connect path still work):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_wrapper_main _pool_clean_args_is_bare_connect _pool_clean_args_is_close \
                      pool_lease_update pool_ensure_connected pool_normalize_close >/dev/null && echo OK'
        # Also: the bare-connect short-circuit still fires for a bare connect (unchanged).
  - FIX every failure before proceeding.

Task 4: ADD the test (Chrome-free; mirrors how P1.M2.T1.S1/S2 added selftests to validate.sh)
  - OPTION A (preferred — co-located with sibling selftests): add to test/validate.sh a
        `selftest__pool_clean_args_is_close` (predicate unit test) + a
        `test_close_marks_lease_disconnected` (the Chrome-free integration test from Task 3's
        INTEGRATION block, wrapped to use setup()/assert_eq/_fail + the trap). Register them in
        the selftest/runner list the same way the existing selftests are.
  - OPTION B (if validate.sh's selftest list is awkward to extend): create
        test/close_rebind.sh that does `source "$ABPOOL_REPO/test/validate.sh"` then defines
        the two test_* functions and calls `abpool_run_suite test_` (the dual-mode source
        contract). Run: `bash test/close_rebind.sh`.
  - TEST BODIES (verbatim, Chrome-free):
        # Unit: predicate truth table.
        selftest__pool_clean_args_is_close() {
            source "$ABPOOL_REPO/lib/pool.sh"  # ensure loaded
            _pool_clean_args_is_close close            || _fail "close should be detected"
            _pool_clean_args_is_close --json close     || _fail "--json close should be detected"
            _pool_clean_args_is_close close --json     || _fail "close --json should be detected"
            if _pool_clean_args_is_close open;         then _fail "open must NOT be detected"; fi
            if _pool_clean_args_is_close connect;      then _fail "connect must NOT be detected"; fi
            if _pool_clean_args_is_close connect 9;    then _fail "connect <port> must NOT be detected"; fi
            if _pool_clean_args_is_close;              then _fail "empty argv must NOT be detected"; fi
            if _pool_clean_args_is_close --json;       then _fail "flags-only must NOT be detected"; fi
        }
        # Integration: close flips connected to false (Chrome-FREE via overrides + no-op exec).
        test_close_marks_lease_disconnected() {
            setup                                   # temp state dir + AGENT_BROWSER_POOL_STATE
            pool_config_init; pool_state_init
            pool_lease_write 1 "$ABPOOL_TEST_ROOT/active/1" 53420 abpool-1 1 pi 100 "$ABPOOL_TEST_ROOT" 0 0 true
            assert_eq "true" "$(jq -r .connected "$POOL_LANES_DIR/1.json")" "precondition connected=true"
            # Override the Chrome/daemon-dependent steps so pool_wrapper_main reaches the close path.
            pool_ensure_connected() { return 0; }
            pool_lease_find_mine()   { printf '1\n'; return 0; }
            printf '#!/bin/sh\nexit 0\n' > "$ABPOOL_TEST_ROOT/noop.sh"; chmod +x "$ABPOOL_TEST_ROOT/noop.sh"
            # Subshell: exec replaces the SUBSHELL only; the parent asserts afterward.
            ( POOL_REAL_BIN="$ABPOOL_TEST_ROOT/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
                  pool_wrapper_main close --json )
            assert_eq "false" "$(jq -r .connected "$POOL_LANES_DIR/1.json")" "connected after close"
            # Siblings preserved.
            jq -e ".lane==1 and .port==53420 and .session==\"abpool-1\" and .owner.comm==\"pi\"" \
                "$POOL_LANES_DIR/1.json" >/dev/null || _fail "siblings not preserved"
        }
  - RUN (execute the new tests):
        bash test/validate.sh   # (if OPTION A — runs selftests incl. the new one) — OR
        bash test/close_rebind.sh   # (if OPTION B)
  - EXPECT: all green, zero residual processes (the no-op exec exits 0; setup's trap reaps temp).
  - NOTE: do NOT add a Chrome-dependent end-to-end close→rebind test here — that is S3
        (P1.M3.T1.S3). S1's test is the Chrome-free WRITE-side assertion only.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern 1: the predicate (paste below _pool_clean_args_is_bare_connect) --------------
_pool_clean_args_is_close() {
    local -a orig=("$@")
    local i=0 tok cmd=""
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;   # parity with the connect twin (already stripped at step j)
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;   # --json/--all/--cdp/…
            -*)             i=$((i+1)) ;;   # -i/-c/…
            *)              cmd="$tok"; break ;;   # first non-flag = COMMAND
        esac
    done
    [[ "$cmd" == close ]]                    # function's exit status == this test's status
}

# --- Pattern 2: the wiring block (paste into pool_wrapper_main, before step k) ------------
    # ... (POOL_CLOSE_ALL_SEEN if/fi block already above) ...
    # --- (close) mark the lease disconnected so the NEXT call rebinds (Issue #3) ----
    if _pool_clean_args_is_close "${POOL_CLEAN_ARGS[@]}"; then
        # Subshell contains pool_die (|| true does NOT catch exit 1). close must always exec.
        if ! ( pool_lease_update "$N" connected false ) 2>/dev/null; then
            _pool_log "pool_wrapper_main: close: could not mark lane $N connected=false (non-fatal; proceeding to exec)"
        fi
    fi
    # --- k. EXEC the real binary (step 5, terminal) -----------------------------

# --- Critical micro-rules baked into the above --------------------------------
#  * `local -a orig=("$@")` is SC2155-safe (array init from $@, not a command sub).
#  * `while (( ))` is a CONDITION (errexit-exempt); `i=$((i+1))` is an assignment (always rc 0).
#  * the final `[[ "$cmd" == close ]]` IS the function's return status (terse-predicate idiom;
#    callers use `if _pool_clean_args_is_close …; then` so its 1-for-non-close is not a set -e abort).
#  * `( pool_lease_update … ) 2>/dev/null || _pool_log …` — the SUBSHELL is load-bearing: it
#    contains pool_die's `exit 1` so a corrupt lease cannot abort the close. `|| true` alone
#    would NOT work (pool_die exits, doesn't return).
#  * `${POOL_CLEAN_ARGS[@]}` is the cleaned argv (step j wrote it; --session/--all stripped) —
#    pass it QUOTED ("${...[@]}") to preserve token boundaries (SC2086).
#  * the block runs BEFORE `exec` (terminal) — verified by the test asserting the lease after.
#  * no happy-path logging (only the rare `|| _pool_log` miss) — operation-level logging convention.
#  * close != connect → step k's bare-connect short-circuit never fires for a close argv.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — the repo is FULLY IMPLEMENTED):
  - pool_lease_update(lane, field, value) (lib/pool.sh:768): the primitive S1 calls.
        Contract: validates lane+field; pool_die on missing/corrupt lease or non-JSON value;
        returns 0 on success; atomic tmp+mv re-publish (siblings + owner preserved). S1 calls it
        as `pool_lease_update "$N" connected false` (value `false` → JSON boolean; host-verified).
  - pool_wrapper_main (lib/pool.sh:3565): the edit site. Step j writes POOL_CLEAN_ARGS; step k is
        the terminal exec. S1 inserts between them.
  - _pool_clean_args_is_bare_connect (lib/pool.sh:3710): the predicate whose flag-scan S1 mirrors
        for the new _pool_clean_args_is_close. Not modified.
  - pool_normalize_close / pool_normalize_connect / pool_strip_session_args / pool_force_session:
        unchanged — they produce POOL_NORM_ARGS / POOL_CLEAN_ARGS that S1 reads.

PROVIDED (the consumer — a LATER subtask; S1 does NOT implement):
  - P1.M3.T1.S2 (pool_ensure_connected reads .connected): S2 adds `.connected` to the one-jq-fork
        field extraction in pool_ensure_connected (currently `.session, .port, .ephemeral_dir`
        only) and, when `.connected == false`, SKIPS the `pool_daemon_connected` early-exit so the
        reconnect/relaunch branch runs. The round-trip is already sound: pool_ensure_connected
        step c already calls `pool_lease_update "$lane" connected true` on a successful reconnect,
        so close→false (S1) → reconnect→true (S2) cycles correctly.
  - P1.M3.T1.S3 (end-to-end close→rebind test): a Chrome-dependent test that the FULL cycle
        works. S1's test is the Chrome-free WRITE-side assertion only; S3 adds the runtime gate.

CONFIG / DATABASE / ROUTES: none. No env vars, no globals, no schema change, no dir I/O beyond
        the existing lease file (via pool_lease_update). The only on-disk effect is one lease
        field flipped true→false on close.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && echo OK-syntax        # parse check — MUST be clean.
shellcheck -S warning lib/pool.sh && echo OK # zero warnings (whole file).
# Expected: OK-syntax + OK.
```

### Level 2: Unit Tests (predicate — pure, Chrome-free)

```bash
# 2a. Predicate truth table (the host-verified command from Task 3).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_clean_args_is_close close && echo close=1; \
         _pool_clean_args_is_close --json close && echo jsonclose=1; \
         _pool_clean_args_is_close close --json && echo closejson=1; \
         for c in open connect; do if _pool_clean_args_is_close $c; then echo "$c=FAIL"; else echo "$c=0"; fi; done; \
         if _pool_clean_args_is_close; then echo empty=FAIL; else echo empty=0; fi'
# Expected: close=1, jsonclose=1, closejson=1, open=0, connect=0, empty=0.

# 2b. Predicate is pure (no pool_die/_pool_log/echo/write).
bash -c '
  body="$(sed -n "/^_pool_clean_args_is_close() {/,/^}/p" lib/pool.sh)"
  grep -qE "pool_die|_pool_log|>>?|[[:space:]]echo " <<<"$body" && { echo FAIL; exit 1; } || echo OK-pure'
# Expected: OK-pure.
```

### Level 3: Integration Tests (Chrome-FREE via overrides + no-op exec)

```bash
# 3a. close flips connected true→false; siblings preserved. (Task 3 INTEGRATION block.)
# 3b. non-close (open) does NOT flip connected. (Task 3 INTEGRATION block.)
# 3c. corrupt lease does NOT abort the close (subshell defense). (Task 3 INTEGRATION block.)
# 3d. close --all (scoped) still flips connected. (Wrap 3a with argv `close --all`; normalize_close
#     strips --all at step i → command is `close` → predicate fires.)
# Expected: OK-close-flips, OK-open-unchanged, OK-siblings-preserved, OK-close-survives-corrupt-lease.
# (Each uses its own mktemp -d state dir, reaped by `trap ... EXIT`; zero Chrome/daemon/lingering procs.)

# 3e. Run the new test via the framework:
bash test/validate.sh        # OPTION A (selftests)
#   — or —
bash test/close_rebind.sh    # OPTION B
# Expected: all pass, no residual processes.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the round-trip types (boolean, not string/number) on the live lib.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'source lib/pool.sh; pool_config_init; pool_state_init;
    pool_lease_write 1 /x 53420 abpool-1 1 pi 100 /c 0 0 true;
    pool_lease_update 1 connected false;
    echo "connected=$(jq -r .connected "$POOL_LANES_DIR/1.json") type=$(jq -r ".connected|type" "$POOL_LANES_DIR/1.json")"'
# Expected: connected=false type=boolean.

# 4b. Confirm no stray runtime artifacts (only lib/pool.sh + the test file modified).
git status --porcelain --untracked-files=all
# Expected: lib/pool.sh (+ test file) only; no .json/.tmp/.log left in the repo tree.

# 4c. Confirm P1.M2.T1.S3 (parallel) did NOT touch pool_wrapper_main / the close path.
grep -nE 'pool_wrapper_main|connected ?false|_pool_clean_args_is_close' \
  plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S3/PRP.md | head
# Expected: no hits in pool_wrapper_main / connected-false / the new predicate (disjoint work).
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels pass.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` zero warnings.
- [ ] `_pool_clean_args_is_close` defined below its twin; predicate truth table correct (2a).
- [ ] Predicate is pure (no side effects) (2b).
- [ ] close flips `connected` true→false with siblings+owner preserved (3a/3c).
- [ ] non-close commands leave `connected` unchanged (3b).
- [ ] corrupt lease does not abort the close (subshell defense) (3c).
- [ ] The new test runs green via the framework (3e); zero residual processes.

### Feature Validation

- [ ] The close path marks the lease `connected=false` BEFORE exec (PRD §2.4 step 4 / §2.5 / §2.15).
- [ ] The flag is the JSON boolean `false` (4a), not a string/number.
- [ ] S2 (next task) will be able to read `.connected` and force a rebind; the round-trip is sound.
- [ ] All other pool_wrapper_main steps (a–k) behave exactly as before for non-close commands.

### Code Quality Validation

- [ ] Mirrors the existing `_pool_clean_args_is_bare_connect` predicate style exactly.
- [ ] Follows strict-mode idioms (`if predicate`, `local` first, `( … ) 2>/dev/null || _pool_log`,
      `${arr[@]}` quoted, `(( ))` only in conditions).
- [ ] No new globals/env/dependencies; the only on-disk effect is one lease field.
- [ ] Comments document the WHY (lingering session → rebind skipped → transparency risk).

### Documentation & Deployment

- [ ] Inline comments at the new block + expanded step-k header explain the close→connected=false
      behavior and rationale (item DOCS: Mode A).
- [ ] No user-facing doc change required (internal behavior; PRD §2.5/§2.15 already describe the
      intended close-then-reuse semantics). (README sync is P1.M4.T1.S1's separate scope.)

---

## Anti-Patterns to Avoid

- ❌ Don't use `pool_lease_update … || true` to "defend" — pool_die `exit 1`s, which `|| true`
  cannot catch. Use a **subshell** `( pool_lease_update … ) 2>/dev/null || _pool_log …`.
- ❌ Don't implement the READ side (pool_ensure_connected) — that's S2 (P1.M3.T1.S2).
- ❌ Don't add the Chrome end-to-end rebind test — that's S3 (P1.M3.T1.S3).
- ❌ Don't touch pool_normalize_close / pool_daemon_connected / pool_dispatch_classify.
- ❌ Don't pass `connected "false"` (quoted) or `0`/`1` — `pool_lease_update … connected false`
  splices `false` as raw JSON (--argjson) → the boolean. Quoting/0/1 would store the wrong type.
- ❌ Don't log on the happy path (only the rare defensive `|| _pool_log` miss) — operation-level
  logging convention.
- ❌ Don't place the block AFTER exec (nothing runs after exec) — it must be before, between the
  POOL_CLOSE_ALL_SEEN block and step k.
- ❌ Don't re-implement the flag-scan inline when `_pool_clean_args_is_close` mirrors the twin.
- ❌ Don't introduce a forward-reference worry — bash resolves functions at call time.
