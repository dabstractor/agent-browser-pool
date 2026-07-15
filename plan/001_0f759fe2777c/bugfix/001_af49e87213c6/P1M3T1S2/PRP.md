# PRP — P1.M3.T1.S2: Check `connected` flag in `pool_ensure_connected` to skip early-exit after close

> **Bugfix context**: This is the **READ half** of **Issue #3** (close→next driving command may
> skip a needed daemon rebind — PRD §2.4 step 4 / §2.5 / §2.15 transparency risk) from
> `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` §"ISSUE 3" (Fix
> Approach #2: `pool_ensure_connected` reads the lease `connected` flag). It is the SECOND of three
> subtasks under **P1.M3.T1**: **S1** (COMPLETE — writes `connected=false` on close) produces the
> signal; **S2** (THIS) makes `pool_ensure_connected` CONSUME it; **S3** adds the end-to-end
> Chrome close→rebind test. S2 edits ONLY `pool_ensure_connected` (4 surgical lines + docstring)
> and adds Chrome-free tests. It does NOT touch the close path (S1), the relaunch/curl branches,
> boot/port code (P1.M2), or config (P1.M1).

---

## Goal

**Feature Goal**: Make `pool_ensure_connected` (the per-invocation self-heal, `lib/pool.sh:2390`)
read the lease's `connected` field and, when it is `false`, **skip the `pool_daemon_connected`
early-exit** so the function falls through to the curl→`pool_daemon_connect` rebind. Today
(pre-fix), `pool_ensure_connected` ignores `connected` and trusts `pool_daemon_connected`, which
returns 0 after a `close` (lingering session-list entry + still-alive Chrome = a false positive) →
the wrapper `exec`s the agent's next driving command against an UN-bound daemon → possible
spurious failure (PRD §2.15). After S1 marks the lease `connected=false` on close, S2 here makes
the NEXT call's `pool_ensure_connected` re-bind the daemon instead of trusting the stale probe.

**Deliverable** (edits to `lib/pool.sh` + test additions to `test/validate.sh`):
1. **`pool_ensure_connected`**: (a) add `connected` to its locals; (b) extend the single jq
   extraction (`.session, .port, .ephemeral_dir` → `…, .connected`) and capture it with a
   `:-true` default; (c) gate the early-exit with `[[ "$connected" == "true" ]] &&` so a
   `false` value short-circuits past `pool_daemon_connected`. **Both** the curl-reconnect branch
   (`:2463`) and the relaunch branch (`:2497`) ALREADY set `connected=true` on success, so the
   flag flips back automatically — S2 adds NO new write.
2. **Docstring** (Mode A, the LOGIC comment block at `:2358-2372`): document the new
   `connected`-flag gate in steps a + b.
3. **Two Chrome-free tests** in `test/validate.sh` (mirroring S1's `selftest_*` hermetic pattern):
   (A) `connected=false` → `pool_ensure_connected` skips the early-exit, calls the (stubbed)
   `pool_daemon_connect` rebind, and flips `connected` back to `true`; (B) `connected=true` → the
   early-exit fires and `pool_daemon_connect` is NOT called (happy-path unchanged).

**Success Definition**:
- A lease with `connected=false` (as S1 writes after a close) causes `pool_ensure_connected` to
  NOT take the `pool_daemon_connected` early-exit (even when that probe would return 0), to call
  `pool_daemon_connect`, and — on success — to leave the lease `connected=true`.
- A lease with `connected=true` behaves EXACTLY as before: the `pool_daemon_connected` early-exit
  fires and `pool_daemon_connect` is NOT called.
- A lease lacking the `connected` field (backward compat) is treated as `true` (old behavior).
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean; the new selftests pass;
  all prior deliverables (incl. S1's close→`connected=false` + its tests) unchanged.

## User Persona

**Target User**: The agent (a `pi`-ancestor process) whose `agent-browser close` (S1) detached its
lane's daemon from Chrome, and whose NEXT driving command (`open`/`click`/…) must reuse the SAME
browser and succeed (PRD §2.5: "close = disconnect-only; next call reuses the same browser"). Internal
change — no operator-visible surface.

**Use Case**: `agent-browser close` (daemon detaches; session lingers; Chrome alive; S1 flips lease
`connected=false`) → `agent-browser open <url>` → wrapper step h calls `pool_ensure_connected` → S2
reads `connected=false` → skips the stale `pool_daemon_connected` probe → curl (Chrome alive) →
`pool_daemon_connect` re-binds → `connected=true` → `exec` against a BOUND daemon → the open
succeeds. Without S2, the open may see a spurious failure on the command immediately after a close.

**Pain Points Addressed**: The post-close false-positive in `pool_daemon_connected` (it cannot
distinguish "bound" from "lingering-after-close") made the implementation diverge from PRD §2.4
step 4's literal "reconnect if the daemon died" design. S1 (signal) + S2 (consume) close that gap
without weakening the cheap, side-effect-free happy-path probe.

## Why

- **Closes the READ half of Issue #3.** S1 durably records the detach (`connected=false`); S2 makes
  that record OBSERVABLE to the self-heal. Together they restore PRD §2.4 step 4's "reconnect"
  behavior for the post-close case while leaving every other path untouched.
- **Minimal, surgical, low-risk.** S2 changes a READ + one `if` condition — no new write, no new
  process, no new global. The reconnect/relaunch branches already exist and already write
  `connected=true`, so flipping the flag back is free.
- **Preserves the happy path.** `connected=true` (the normal case) still short-circuits via the
  cheap `pool_daemon_connected` probe — no extra curl/connect on the hot path. Only the post-close
  case (where the probe is known to lie) pays the rebind.
- **Backward-compatible.** A `:-true` default means any lease predating S1 (or lacking the field)
  behaves exactly as before — S2 never newly skips a probe.
- **Testable without Chrome.** The fix's code path (read `connected` → branch) is exercised by
  stubbing `pool_daemon_connected` + `curl` + `pool_daemon_connect` in a hermetic subshell (the S1
  test convention) — no real Chrome/daemon, per AGENTS.md.

## What

User-visible behavior: none directly (internal library self-heal). Observable contract change is
narrow and inside `pool_ensure_connected` only:

| Lease `connected` | Before S2 (early-exit) | After S2 |
|---|---|---|
| `true` (normal booted lane) | `pool_daemon_connected` probe → rc 0 → early-exit (return 0) | **unchanged** — `[[ true ]] && probe` → same early-exit |
| `false` (post-close, S1) | `pool_daemon_connected` probe → rc 0 (false positive) → early-exit → `exec` un-bound | `[[ false ]]` short-circuits → SKIP probe → curl (alive) → `pool_daemon_connect` rebind → `connected=true` → return 0 |
| field absent (old lease) | probe → rc 0 → early-exit | **unchanged** — `:-true` → `[[ true ]]` → probe |
| `false` + Chrome dead (rare) | (unchanged relaunch) | `[[ false ]]` → skip probe → curl (dead) → relaunch → `connected=true` |

**Exact edits** (host-verified exact text — see research `ensure-connected-connected-flag.md` §2):

| # | File:line | Current | Target |
|---|---|---|---|
| 1 | `lib/pool.sh` locals (~2399) | `    local json session port ephemeral_dir now` | `    local json session port ephemeral_dir connected now` |
| 2 | `lib/pool.sh` jq (~2408) | `    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")` | `    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")` |
| 3 | `lib/pool.sh` capture (~2411, after `ephemeral_dir="${_f[2]:-}"`) | — | add `    connected="${_f[3]:-true}"   # Issue #3: S1 flips this false on close; default true (old leases)` |
| 4 | `lib/pool.sh` early-exit (~2423) | `    if pool_daemon_connected "$session" "$port"; then` | `    if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then` |

Plus **Mode A docstring** edits to the LOGIC block (`:2358-2372`): step a adds `connected` to the
read-field list; step b describes the new gate ("only trust the `pool_daemon_connected` probe when
the lease says `connected==true`; after a close S1 flipped it `false`, so skip the probe and fall
through to the curl reconnect — the lingering session-list entry is a false positive").

### Success Criteria

- [ ] `pool_ensure_connected` reads `.connected` in the SAME single jq fork (no second read).
- [ ] `connected="${_f[3]:-true}"` — defaults to `true` when the field is absent (backward compat).
- [ ] Early-exit is gated: `if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then`.
- [ ] With `connected=false`: the function does NOT return from the early-exit (even if
      `pool_daemon_connected` would return 0); it reaches `pool_daemon_connect` and, on success,
      leaves the lease `connected=true`.
- [ ] With `connected=true`: the early-exit fires (old behavior); `pool_daemon_connect` is NOT called.
- [ ] **Test A** (`connected=false` → rebind) passes; **Test B** (`connected=true` → no rebind) passes.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean; the file sources under
      `set -euo pipefail`; all prior deliverables (incl. S1) unchanged and their tests still pass.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed?"** → Yes. This
PRP includes: the **exact current-state** finding (S1 COMPLETE — production code + tests present;
the function is at `lib/pool.sh:2390`, not the item's `:2306`); the **host-verified exact text** of
every edit target (4 lines + docstring); the proof that **both success branches already write
`connected=true`** (so S2 adds no write); the `jq -r` boolean→string semantics (`false` → the
string `false`); the errexit-exempt `[[ ]] && …` idiom; the **test mock technique** (shadow `curl`
with a function so the reconnect branch — not relaunch — fires in a Chrome-free test); the S1 test
pattern to mirror (heredoc body script + `timeout 15` + `assert_eq rc`); and the scope guard.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: §"ISSUE 3" — root cause (pool_daemon_connected's lingering-session false positive) + Fix
        Approach #1 (mark connected=false on close [S1]) and #2 (ensure_connected reads it [S2]).
  pattern: Fix #2 = THIS task; Fix #1 = S1 (COMPLETE).
  gotcha: the fix is READ/branch only — the existing reconnect/relaunch writes already flip connected back.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S2/research/ensure-connected-connected-flag.md
  why: THIS task's research: the exact current code of pool_ensure_connected (§1), the 4-edit map
        with host-verified exact text (§2), the [[ ]] && gate semantics (§3), the test design with
        the curl-stub trick + two tests (§4), the full round-trip (§5), gotchas (§6), scope (§7).
  pattern: §2 (the edit table), §4 (the test bodies).
  gotcha: §6 — jq -r .connected → string "false"; curl() stub shadows the binary; _connect_called
        must live in the same shell as the assertion; default :-true for backward compat.

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S1/PRP.md   # S1 — the WRITE-side CONTRACT
  why: S1 defines + LANDS the signal this task consumes: `_pool_clean_args_is_close` + the
        close→`pool_lease_update "$N" connected false` block in pool_wrapper_main, AND its tests.
        S1's PRP states (Integration Points): "P1.M3.T1.S2: pool_ensure_connected READS .connected,
        skips the early-exit when false. Round-trip already sound: ensure_connected step c sets
        connected=true on reconnect (~2463)." THIS is that task.
  pattern: S1 writes the JSON boolean false via pool_lease_update (value spliced raw via --argjson).
  gotcha: confirm S1's production code is STILL present before finishing (grep Task 0) — do not edit it.

- file: PRD.md (bugfix snapshot)
  why: §2.4 step 4 (ENSURE CONNECTED — "reconnect if the daemon died"), §2.5 ("close =
        disconnect-only; next call reuses the same browser"), §2.15 (transparency — agent must
        never see failures), §2.8 (lease `connected` boolean field).

# The code under edit — READ the named function + its helpers in lib/pool.sh
- file: lib/pool.sh
  why: pool_ensure_connected (2390) is the ONLY edit site; pool_lease_read (828) + the jq/mapfile
        idiom (2408) feed it; pool_daemon_connected (1727) is the gated probe; pool_daemon_connect
        (1669) is the rebind; pool_lease_update (768) writes connected=true on the success branches.
        pool_wrapper_main (3565) step h is the CALLER of ensure_connected (do NOT edit it — S1's
        close→connected=false block at 3658-3666 is the input).
  pattern: extend the existing `mapfile -t _f < <(jq -r '…')` ONE-fork idiom (pool_lane_is_stale /
        ensure_connected both use it); add the field to the comma list + a `:-default` capture.
  gotcha: do NOT add a second pool_lease_read/jq fork — the single-read-single-fork pattern is the
        codebase convention. Edit #4's `[[ ]] && probe` is errexit-exempt (left operand of && in an
        if-condition) — do NOT add `|| true`.

- file: test/validate.sh
  why: the test FRAMEWORK + the S1 selftests to MIRROR. Helpers: setup()/teardown() (temp state +
        AGENT_BROWSER_POOL_STATE/EPHEMERAL_ROOT/MASTER), _fail MSG, assert_eq EXP ACT [LABEL],
        run_test NAME FN (body in a subshell), abpool_run_suite PREFIX, ABPOOL_REPO/ABPOOL_TEST_ROOT.
        The S1 selftests (selftest_close_marks_lease_disconnected @437, selftest_open_does_not_flip_connected
        @473) define the hermetic body-script pattern: write body.sh via heredoc, run under
        `AGENT_BROWSER_POOL_STATE=… AGENT_BROWSER_REAL=… timeout 15 bash "$script" "$ABPOOL_REPO" …`,
        assert_eq "0" "$rc" "<msg>". selftest_* are picked up by the single-setup _run_selftest_suite.
  pattern: copy selftest_close_marks_lease_disconnected's scaffolding (outdir/noop/script/rc/out);
        replace the body with the S2 stub-based assertion (S2's body is SIMPLER — no pool_wrapper_main,
        no AGENT_BROWSER_REAL needed, but keep the pattern for consistency).
  gotcha: stub `curl`, `pool_daemon_connected`, `pool_daemon_connect` INSIDE the body script (same
        shell as pool_ensure_connected) so the call-recorder var persists. `_connect_called` must be
        set in the SAME shell that asserts — call pool_ensure_connected directly, NOT in a `( … )`.

# External authoritative docs
- url: https://jqlang.github.io/jq/manual/#invoking-jq
  why: `jq -r '.a, .b, .c'` emits one value per line (comma = sequence); `mapfile -t arr < <(…)`
        captures them; `jq -r .connected` renders a JSON boolean `false` as the bare string `false`.
  critical: compare `connected` to the STRINGS "true"/"false" (`[[ "$connected" == "true" ]]`), never
        numerically; a `false` field is NOT `"false"` (no quotes) and NOT `0`.
- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (`set -e`) — the condition of `if` and the operands of `&&`/`||` are EXEMPT. So
        `if [[ "$connected" == "true" ]] && pool_daemon_connected …; then` is safe even when both
        operands can legitimately be false/non-zero (they just make the `if` false).
- url: https://www.gnu.org/software/bash/manual/bash.html#Shell-Functions
  why: a shell FUNCTION named `curl` shadows the external binary for command lookup in that shell
        (functions are checked before PATH). This is WHY the test's `curl() { return 0; }` stub makes
        `pool_ensure_connected`'s `curl -sf …` return 0 without a real Chrome. Valid only in the
        hermetic test subshell.
- url: https://github.com/koalaman/shellcheck/wiki/SC2155   # declare+assign separately (n/a — no new local capture here)
- url: https://github.com/koalaman/shellcheck/wiki/SC2086   # quote "$connected", "$session", "$port"
```

### Current Codebase tree

```bash
agent-browser-pool/
├── lib/pool.sh    # 4577 LOC. S1 COMPLETE:
│                  #   pool_lease_update (768); pool_lease_read (828);
│                  #   pool_daemon_connect (1669); pool_daemon_connected (1727);
│                  #   pool_ensure_connected (2390) ← S2 EDITS HERE (locals/jq/capture/early-exit + docstring);
│                  #     its reconnect branch (2463) + relaunch branch (2497) ALREADY write connected=true;
│                  #   pool_wrapper_main (3565) — close→connected=false block PRESENT (3658-3666) [S1];
│                  #   _pool_clean_args_is_close PRESENT (3792) [S1].
├── test/
│   ├── validate.sh        # framework + selftests. S1 selftests PRESENT (437-531). ADD S2 selftests here.
│   ├── transparency.sh / concurrency.sh / release_reaper.sh   # unchanged
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M3T1S2/
    ├── PRP.md             # THIS FILE
    └── research/ensure-connected-connected-flag.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/pool.sh   # MODIFIED — pool_ensure_connected: +1 local, +1 jq field, +1 capture line,
│                  #                       gated early-exit, docstring. (NO other function touched.)
└── test/validate.sh  # MODIFIED — +2 selftest_* functions (connected=false→rebind; connected=true→skip)
```

**File responsibility**: `lib/pool.sh` — `pool_ensure_connected` becomes Issue-#3-aware (consumes
S1's `connected=false` signal). `test/validate.sh` — the two Chrome-free selftests lock the contract
in both directions.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified): jq -r .connected on a JSON boolean false → the STRING "false".
#   Compare with == "true" / == "false" (string compare inside [[ ]]). NEVER numeric.
#   Verified: jq -r .connected on {"connected":false} prints `false` (bare word, no quotes, not 0).

# CRITICAL (errexit-safe gate): `if [[ "$connected" == "true" ]] && pool_daemon_connected …; then`
#   The [[ ]] is the LEFT operand of && inside an if-CONDITION → errexit-exempt. A false [[ ]] does
#   NOT abort (it short-circuits &&, making the if false → fall through). This is the EXISTING idiom
#   (the codebase already uses `if [[ … ]] && helper …; then` throughout). Do NOT add `|| true`.

# CRITICAL (both success branches ALREADY write connected=true): the curl-reconnect branch (2463)
#   and the relaunch branch (2497) both call `pool_lease_update "$lane" connected true` on success.
#   So once S2 makes connected=false skip the early-exit, the flag flips back to true for free.
#   DO NOT add a new write of connected=true — it would be redundant.

# CRITICAL (backward-compat default): `connected="${_f[3]:-true}"`. A lease predating S1 (or any
#   lease lacking the field) → behave as the OLD code (always probe). Defaulting to true is the SAFE
#   choice (never newly skip a probe due to a missing field). PRD §2.8 + pool_lease_write always
#   include connected, but the default is defensive.

# CRITICAL (single read / single jq fork): pool_ensure_connected reads the lease ONCE via
#   pool_lease_read and extracts all fields in ONE jq fork (the "ONE fork" idiom shared with
#   pool_lane_is_stale). EXTEND the comma list (.session, .port, .ephemeral_dir, .connected) — do NOT
#   add a second pool_lease_read or a second jq fork.

# CRITICAL (test: curl() stub shadows the binary): defining `curl() { return 0; }` in the hermetic
#   test body makes `pool_ensure_connected`'s `curl -sf …` return 0 WITHOUT a real Chrome → the
#   RECONNECT branch fires (not relaunch). This is the ONLY Chrome-free way to exercise the exact
#   code path the fix activates. Functions beat PATH executables for command lookup. Valid ONLY in
#   the test subshell — do NOT define curl() in lib/pool.sh.

# GOTCHA (test: _connect_called must persist): pool_ensure_connected and the stubbed
#   pool_daemon_connect run in the SAME shell (the body script) — call pool_ensure_connected DIRECTLY,
#   not in a `( … )`, so the call-recorder var set inside the stub is visible to the assertion.

# GOTCHA (do NOT touch): the relaunch path, the curl branch's body, pool_daemon_connected,
#   pool_daemon_connect, pool_wrapper_main, the close path (S1), boot/port code (P1.M2), config (P1.M1).
#   S2 edits ONLY: the locals line, the extraction+capture, the early-exit condition, and the docstring.

# GOTCHA (no real Chrome / no daemon — AGENTS.md §1): the test stubs curl + pool_daemon_connected +
#   pool_daemon_connect. pool_chrome_launch / pool_wait_cdp are NEVER reached (curl stub → reconnect
#   branch, never relaunch).

# GOTCHA (line numbers shifted): the item cites pool_ensure_connected at 2306; it is now at 2390
#   (file grew to 4577 LOC). Locate with `grep -n 'pool_ensure_connected()' lib/pool.sh` — do NOT
#   blind-edit by the item's line numbers.
```

## Implementation Blueprint

### Data models and structure

No schema/globals/env changes. No new globals exported. The only data the change touches is the
existing lease `.connected` boolean field (already in PRD §2.8, already written by S1 on close and
by pool_boot_lane/pool_ensure_connected on connect). S2 reads it into a new `local connected`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY THE CURRENT STATE FIRST (S1 must be COMPLETE; locate the exact edit lines)
  - RUN: grep -nE 'pool_ensure_connected\(\)|_pool_clean_args_is_close\(\)|pool_lease_update "\$N" connected false' lib/pool.sh
  - EXPECT: pool_ensure_connected def at ~2390; _pool_clean_args_is_close at ~3792; the close block
        at ~3664. If S1's block/predicate are ABSENT → STOP (S1 is a prerequisite; the orchestrator
        sequences it first — this task assumes S1 landed).
  - RUN (confirm the exact edit targets — host-read these, but re-confirm in case of concurrent edits):
        sed -n '/^pool_ensure_connected() {/,/^    # --- c\. NOT connected/p' lib/pool.sh
  - EXPECT: the locals line `local json session port ephemeral_dir now`, the mapfile jq, the three
        captures, the port/session/ephemeral_dir guards, `now=`, the `# --- b. ALREADY connected`
        comment, and `if pool_daemon_connected "$session" "$port"; then`.
  - RUN (confirm both success branches already write connected=true):
        grep -n 'pool_lease_update "$lane" connected true' lib/pool.sh
  - EXPECT: TWO hits (the reconnect branch ~2463 + the relaunch branch ~2497). If either is missing,
        the round-trip breaks — STOP and surface it (do NOT add a redundant write blindly; investigate).
  - RUN: bash -n lib/pool.sh && shellcheck -S warning lib/pool.sh && echo OK
  - EXPECT: OK (clean before any S2 edit).

Task 1: EDIT pool_ensure_connected — locals + jq extraction + capture (Edits 1/2/3)
  - OLD (exact, host-read at ~2399 + ~2406-2411):
        local json session port ephemeral_dir now
        ...
        # Extract the 3 fields we need in ONE jq fork (comma → 3 lines; mapfile -t strips \n).
        # jq cannot fail here (valid JSON guaranteed by pool_lease_read's _pool_json_valid).
        mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")
        session="${_f[0]:-}"
        port="${_f[1]:-}"
        ephemeral_dir="${_f[2]:-}"
  - NEW:
        local json session port ephemeral_dir connected now
        ...
        # Extract the 4 fields we need in ONE jq fork (comma → N lines; mapfile -t strips \n):
        # session, port, ephemeral_dir, connected. `connected` is the Issue-#3 signal — S1's close
        # path flips it false, so a post-close call must NOT trust the lingering pool_daemon_connected
        # probe (step b). Default true for backward compat with leases predating S1 (or lacking the
        # field) — preserves the old always-probe behavior. jq cannot fail here (valid JSON guaranteed
        # by pool_lease_read's _pool_json_valid).
        mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")
        session="${_f[0]:-}"
        port="${_f[1]:-}"
        ephemeral_dir="${_f[2]:-}"
        connected="${_f[3]:-true}"
  - FOLLOW pattern: extend the existing ONE-fork comma list (do NOT add a second jq); keep the
        `:-default` capture idiom used for session/port/ephemeral_dir.
  - GOTCHA: `:-true` (string), not `:-1`; jq -r renders the boolean as the bare word true/false.

Task 2: EDIT pool_ensure_connected — the early-exit gate (Edit 4)
  - OLD (exact, host-read at ~2421-2424):
        # --- b. ALREADY connected? (SIDE-EFFECT-FREE — never launches; the get cdp-url REPLACEMENT). ---
        if pool_daemon_connected "$session" "$port"; then
            pool_lease_update "$lane" last_seen_at "$now"   # observability heartbeat
            return 0
        fi
  - NEW:
        # --- b. ALREADY connected? (SIDE-EFFECT-FREE — never launches; the get cdp-url REPLACEMENT). ---
        # Issue #3 (S2): only trust the lingering-session probe if the lease says connected==true.
        # After a close, S1 flips connected=false; the session LINGERS in `session list` + Chrome
        # stays alive, so pool_daemon_connected would return 0 (false positive) and we'd skip the
        # rebind the next driving command needs. When connected==false, short-circuit past this
        # early-exit and fall through to the curl reconnect (step c) → pool_daemon_connect rebinds.
        # `[[ ]] && probe` is errexit-exempt (left operand of && in an if-condition).
        if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then
            pool_lease_update "$lane" last_seen_at "$now"   # observability heartbeat
            return 0
        fi
  - FOLLOW pattern: `if [[ … ]] && helper …; then` (the codebase's existing conditional-and idiom).
  - GOTCHA: do NOT add `|| true`; do NOT move/rewrite the early-exit body (the last_seen_at touch +
        return 0 stay). Only the `if` condition gains the `[[ "$connected" == "true" ]] && ` prefix.

Task 3: EDIT the docstring (Mode A — the LOGIC comment block ~2358-2372)
  - In step a, add `connected` to the read-field list:
        OLD: #   a. Read the lease → session, port, ephemeral_dir (+ chrome_pid). Lease missing/corrupt
             #      OR port<=0 (provisional, not booted) → return 1 (defensive — S2's job).
        NEW: #   a. Read the lease → session, port, ephemeral_dir, connected (+ chrome_pid). Lease
             #      missing/corrupt OR port<=0 (provisional, not booted) → return 1 (defensive).
  - In step b, document the new gate:
        OLD: #   b. pool_daemon_connected "$session" "$port" (SIDE-EFFECT-FREE): rc 0 → touch last_seen_at
             #      → return 0.
        NEW: #   b. ONLY if the lease connected==true: pool_daemon_connected "$session" "$port"
             #      (SIDE-EFFECT-FREE) → rc 0 → touch last_seen_at → return 0. If connected==false
             #      (S1 flipped it after a close), SKIP this early-exit and fall through to (c): the
             #      lingering session-list entry is a false positive, so rebind via curl+connect.
  - FOLLOW pattern: keep the LOGIC block's terse a→d step style.

Task 4: VERIFY the production edits (run BEFORE writing the tests)
  - RUN: bash -n lib/pool.sh && shellcheck -S warning lib/pool.sh && echo OK
  - EXPECT: OK.
  - RUN (the fix in isolation — connected=false forces the rebind; Chrome-free via stubs):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 200 201 false; \
                 pool_daemon_connected() { return 0; };          # the post-close FALSE POSITIVE \
                 curl() { return 0; };                            # chrome "alive" → reconnect branch \
                 _c=0; pool_daemon_connect() { _c=1; return 0; }; \
                 pool_ensure_connected 1; \
                 [[ "$_c" == "1" ]] && test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true" && echo OK-rebind'
        # EXPECT: OK-rebind (probe skipped → connect called → connected flipped to true).
  - RUN (the happy path UNCHANGED — connected=true → early-exit, no rebind):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 200 201 true; \
                 pool_daemon_connected() { return 0; }; \
                 curl() { return 0; }; \
                 _c=0; pool_daemon_connect() { _c=1; return 0; }; \
                 pool_ensure_connected 1; \
                 [[ "$_c" == "0" ]] && echo OK-no-rebind'
        # EXPECT: OK-no-rebind (early-exit fired; connect NOT called).
  - RUN (backward compat — a lease LACKING connected behaves as true → early-exit):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_LANES_DIR"; \
                 jq -n "{version:1,lane:1,ephemeral_dir:\"'"$tmp"'/a\",port:53420,session:\"abpool-1\",owner:{pid:1,comm:\"pi\",starttime:1,cwd:\"/c\"},chrome_pid:1,chrome_pgid:1,acquired_at:1,last_seen_at:1}" > "$POOL_LANES_DIR/1.json"; \
                 pool_daemon_connected() { return 0; }; curl() { return 0; }; \
                 _c=0; pool_daemon_connect() { _c=1; return 0; }; \
                 pool_ensure_connected 1; \
                 [[ "$_c" == "0" ]] && echo OK-default-true'
        # EXPECT: OK-default-true (no connected field → :-true → early-exit).

Task 5: ADD the two Chrome-free selftests to test/validate.sh
  - PLACEMENT: co-located with the S1 selftests (directly below
        selftest_close_survives_corrupt_lease, ~line 531), inside the selftest_* block picked up by
        _run_selftest_suite. Mirror selftest_close_marks_lease_disconnected's scaffolding exactly.
  - BODIES (verbatim — note the curl() stub + the direct pool_ensure_connected call + the SAME-shell
        call recorder):
        # --- pool_ensure_connected rebinds when connected=false (P1.M3.T1.S2 / Issue #3 READ side) ---
        # The FIX: connected=false (S1 wrote it on close) must make pool_ensure_connected SKIP the
        # pool_daemon_connected early-exit (even though that probe returns 0 — the post-close false
        # positive) and instead call pool_daemon_connect to rebind, flipping connected back to true.
        # Chrome-FREE: stub pool_daemon_connected (→0), curl (→0, so the reconnect branch — not
        # relaunch — fires), pool_daemon_connect (records + →0). Hermetic, timeout-bounded subshell.
        selftest_ensure_connected_rebinds_when_disconnected() {
            local outdir script rc out
            outdir="$ABPOOL_TEST_ROOT/ensure-rebind"
            mkdir -p -- "$outdir"
            script="$outdir/body.sh"
            cat >"$script" <<'EOF'
set -euo pipefail
source "$1/lib/pool.sh"
pool_config_init
pool_state_init
# Lease with connected=false (exactly as S1's close path writes it) + a valid port.
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 false
# Stubs. pool_daemon_connected returns 0 = the post-close FALSE POSITIVE (lingering session +
# alive chrome). curl returns 0 = chrome "alive" → the RECONNECT branch (not relaunch). The
# connect stub records that it was called (the rebind we want to FORCE) + returns 0.
pool_daemon_connected() { return 0; }
curl()                  { return 0; }
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
# The fix: connected=false MUST skip the early-exit → reach pool_daemon_connect + flip connected.
pool_ensure_connected 1
test "$_connect_called" = "1"                                  # rebind CALLED (no early-exit)
test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"   # flipped back to true
EOF
            rc=0
            out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                  timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
            assert_eq "0" "$rc" "connected=false → ensure_connected rebinds (connect called, connected→true) (out: $out)" || return 1
        }

        # --- pool_ensure_connected early-exits (no rebind) when connected=true (happy path) ---
        # Companion: a normal booted lease (connected=true) MUST still take the pool_daemon_connected
        # early-exit and NOT call pool_daemon_connect — i.e. S2 changes nothing for the happy path.
        selftest_ensure_connected_skips_rebind_when_connected() {
            local outdir script rc out
            outdir="$ABPOOL_TEST_ROOT/ensure-noop"
            mkdir -p -- "$outdir"
            script="$outdir/body.sh"
            cat >"$script" <<'EOF'
set -euo pipefail
source "$1/lib/pool.sh"
pool_config_init
pool_state_init
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 true
pool_daemon_connected() { return 0; }   # connected + probe rc 0 → early-exit
curl()                  { return 0; }
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
pool_ensure_connected 1
test "$_connect_called" = "0"   # NOT called — early-exit fired (old behavior preserved)
EOF
            rc=0
            out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                  timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
            assert_eq "0" "$rc" "connected=true → ensure_connected early-exits, no rebind (out: $out)" || return 1
        }
  - RUN: bash test/validate.sh
  - EXPECT: the suite reports the two new selftests PASS (plus all prior selftests, incl. S1's,
        still PASS). Zero residual processes (no Chrome/daemon spawned — all stubbed).

Task 6: FINAL VERIFY (run before claiming done)
  - RUN: bash -n lib/pool.sh && shellcheck -S warning lib/pool.sh && echo OK-syntax
  - RUN: bash test/validate.sh && echo OK-tests
  - RUN (regression — S1's close→connected=false still works; its selftests still pass):
        grep -nE 'pool_lease_update "\$N" connected false' lib/pool.sh   # S1 block still present
  - EXPECT: OK-syntax; OK-tests; the S1 block still present.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern 1: extend the ONE-fork jq extraction (no second read) -------------------------
    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")
    session="${_f[0]:-}"
    port="${_f[1]:-}"
    ephemeral_dir="${_f[2]:-}"
    connected="${_f[3]:-true}"   # Issue #3 signal; :-true = backward compat with old leases

# --- Pattern 2: the gated early-exit (errexit-exempt [[ ]] && probe) ----------------------
    if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then
        pool_lease_update "$lane" last_seen_at "$now"
        return 0
    fi
    # (falls through to the EXISTING curl reconnect → pool_daemon_connect → connected=true)

# --- Pattern 3: the Chrome-free test (mirror S1's selftest_close_marks_lease_disconnected) -
#   stub curl + pool_daemon_connected + pool_daemon_connect in the body script; call
#   pool_ensure_connected DIRECTLY (not in a subshell) so the call-recorder var persists.

# --- Critical micro-rules ----------------------------------------------------------------
#  * jq -r .connected on a JSON boolean false → the STRING "false"; compare with == "true".
#  * `[[ "$connected" == "true" ]] && probe` — the [[ ]] is the left operand of && in an
#    if-condition → errexit-exempt; do NOT add `|| true`.
#  * both success branches (reconnect ~2463, relaunch ~2497) ALREADY write connected=true —
#    S2 adds NO new write.
#  * default `:-true` preserves the old always-probe behavior for leases lacking the field.
#  * single pool_lease_read + single jq fork — extend the comma list, do not fork again.
#  * the test's curl()/pool_daemon_connected()/pool_daemon_connect() stubs shadow the real
#    functions/binary ONLY in the hermetic body subshell; valid because functions beat PATH.
```

### Integration Points

```yaml
CONSUMED (already implemented — S2 reads them; do NOT edit):
  - pool_lease_read(lane) (lib/pool.sh:828): returns the lease JSON on stdout (rc 0) / rc 1 on
        missing/corrupt. pool_ensure_connected ALREADY calls it (step a) — S2 just consumes one
        more field from its output.
  - pool_lease_update(lane, field, value) (lib/pool.sh:768): atomic lease patch. The reconnect
        branch (2463) + relaunch branch (2497) ALREADY call `pool_lease_update "$lane" connected true`
        on success — S2 relies on these (no new call).
  - pool_daemon_connected(session, port) (1727) + pool_daemon_connect(session, port) (1669):
        the probe + the rebind — UNCHANGED. S2 only changes WHEN the probe is consulted.
  - S1's close→connected=false block (pool_wrapper_main 3658-3666): the PRODUCER of the signal
        S2 consumes. (COMPLETE — verify it stays present; do not edit.)

PROVIDED (later subtasks; S2 does NOT implement):
  - P1.M3.T1.S3: the Chrome-dependent end-to-end close→rebind test (real agent-browser + Chrome).
        S2's tests are the Chrome-free READ-side assertions only.

CONFIG / DATABASE / ROUTES: none. No env vars/globals/schema change. S2 reads one existing lease
        field into a local; the on-disk effect (connected true↔false) is owned by S1 (close) and the
        existing connect/relaunch branches.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n lib/pool.sh && echo OK-syntax
shellcheck -S warning lib/pool.sh && echo OK
# Expected: OK-syntax + OK (must be clean after the 4 edits + docstring).
```

### Level 2: Unit / Behavior Checks (Chrome-FREE, host-verified forms)

```bash
# 2a. connected=false → rebind (THE FIX). probe stubbed to 0 (false positive); curl stubbed to 0
#     (reconnect branch); connect stub records + returns 0. Assert: connect CALLED + connected→true.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 200 201 false; \
         pool_daemon_connected() { return 0; }; curl() { return 0; }; \
         _c=0; pool_daemon_connect() { _c=1; return 0; }; \
         pool_ensure_connected 1; \
         [[ "$_c" == "1" ]] && test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true" && echo OK-rebind'
# Expected: OK-rebind.

# 2b. connected=true → early-exit, NO rebind (happy path UNCHANGED).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 1 "'"$tmp"'/active/1" 53420 abpool-1 1 pi 100 "'"$tmp"'" 200 201 true; \
         pool_daemon_connected() { return 0; }; curl() { return 0; }; \
         _c=0; pool_daemon_connect() { _c=1; return 0; }; \
         pool_ensure_connected 1; [[ "$_c" == "0" ]] && echo OK-no-rebind'
# Expected: OK-no-rebind.

# 2c. backward compat — a lease LACKING connected → :-true → early-exit (old behavior).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         mkdir -p "$POOL_LANES_DIR"; \
         jq -n "{version:1,lane:1,ephemeral_dir:\"'"$tmp"'/a\",port:53420,session:\"abpool-1\",owner:{pid:1,comm:\"pi\",starttime:1,cwd:\"/c\"},chrome_pid:1,chrome_pgid:1,acquired_at:1,last_seen_at:1}" > "$POOL_LANES_DIR/1.json"; \
         pool_daemon_connected() { return 0; }; curl() { return 0; }; \
         _c=0; pool_daemon_connect() { _c=1; return 0; }; \
         pool_ensure_connected 1; [[ "$_c" == "0" ]] && echo OK-default-true'
# Expected: OK-default-true.
```

### Level 3: Integration Tests (the framework + regression)

```bash
# 3a. Run the new selftests via the framework (they are picked up by _run_selftest_suite).
bash test/validate.sh
# Expected: ALL selftests PASS — incl. the two new ones (ensure_connected_rebinds_when_disconnected,
#           ensure_connected_skips_rebind_when_connected) AND S1's four (clean_args_is_close_cases,
#           close_marks_lease_disconnected, open_does_not_flip_connected, close_survives_corrupt_lease)
#           AND P1.M2's chrome_launch_eaddrinuse. Zero residual processes.

# 3b. Regression: S1's close→connected=false block is STILL present (S2 did not touch it).
grep -nE '_pool_clean_args_is_close\(\)|pool_lease_update "\$N" connected false' lib/pool.sh
# Expected: both hits (~3792, ~3664) still present.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the EXACT edit landed (the jq has 4 fields; the early-exit is gated).
sed -n '/^pool_ensure_connected() {/,/^    # --- c\. NOT connected/p' lib/pool.sh \
  | grep -qE "jq -r '\.session, \.port, \.ephemeral_dir, \.connected'" \
  && echo "OK jq-4-fields" || echo "FAIL jq"
sed -n '/^pool_ensure_connected() {/,/^    # --- c\. NOT connected/p' lib/pool.sh \
  | grep -qE 'if \[\[ "\$connected" == "true" \]\] && pool_daemon_connected' \
  && echo "OK gated-early-exit" || echo "FAIL gate"

# 4b. Confirm NO second pool_lease_read / NO redundant connected=true write was added inside
#     pool_ensure_connected (the single-read-single-fork idiom + the existing writes suffice).
sed -n '/^pool_ensure_connected() {/,/^}/p' lib/pool.sh | grep -c 'pool_lease_read'   # want 1
sed -n '/^pool_ensure_connected() {/,/^}/p' lib/pool.sh | grep -c 'mapfile'           # want 1

# 4c. No stray runtime artifacts (only lib/pool.sh + test/validate.sh touched).
git status --porcelain --untracked-files=all
# Expected: only lib/pool.sh + test/validate.sh; no .json/.tmp/.log left in the repo tree.
```

## Final Validation Checklist

### Technical Validation

- [ ] Task 0 current-state check done (S1 present; exact edit lines located; both connected=true
      writes confirmed at ~2463 + ~2497).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` zero warnings.
- [ ] Edit 1 (locals +connected), Edit 2 (jq +.connected), Edit 3 (capture `:-true`), Edit 4
      (`[[ "$connected" == "true" ]] &&` gate) all landed (4a).
- [ ] connected=false → rebind (2a); connected=true → no rebind (2b); missing field → default true (2c).
- [ ] No second pool_lease_read / no redundant connected=true write added inside the function (4b).
- [ ] The two new selftests pass via the framework (3a); zero residual processes.

### Feature Validation

- [ ] `pool_ensure_connected` reads `.connected` and skips the `pool_daemon_connected` early-exit
      when it is `false` (PRD §2.4 step 4 / §2.5 / §2.15) — Issue #3 READ side closed.
- [ ] The reconnect (curl-alive) path re-binds via `pool_daemon_connect` and flips `connected=true`
      (existing writes, unchanged).
- [ ] Happy path (`connected=true`) is byte-for-byte unchanged in behavior (2b).
- [ ] S1's close→`connected=false` block is intact (3b); S1's selftests still pass.

### Code Quality / Documentation

- [ ] Reuses the existing single-read/single-fork jq idiom; `[[ ]] && probe` errexit-exempt idiom.
- [ ] No new globals/env/dependencies; one local added; no new on-disk writes.
- [ ] Docstring (Mode A) documents the connected-flag gate (steps a + b).
- [ ] No user-facing doc change required (internal; PRD §2.4/§2.5/§2.15 describe the semantics).

---

## Anti-Patterns to Avoid

- ❌ Don't add a SECOND `pool_lease_read` or a second `jq` fork — extend the existing comma list.
- ❌ Don't add a redundant `pool_lease_update "$lane" connected true` — the reconnect (2463) and
  relaunch (2497) branches ALREADY do it.
- ❌ Don't drop the `:-true` default — old/field-absent leases must behave as before.
- ❌ Don't compare `connected` numerically or to `"false"`-with-quotes — `jq -r` yields the bare
  word `false`; use `[[ "$connected" == "true" ]]`.
- ❌ Don't add `|| true` to the `[[ ]] && probe` gate — it's errexit-exempt as an if-condition.
- ❌ Don't touch the close path (S1), the relaunch/curl branches, `pool_daemon_connected`/
  `pool_daemon_connect`, boot/port code (P1.M2), or config (P1.M1).
- ❌ Don't define `curl()` in `lib/pool.sh` — the stub belongs ONLY in the hermetic test subshell.
- ❌ Don't run the test body's `pool_ensure_connected` in a `( … )` — the `_connect_called` recorder
  must persist to the assertion (same shell).
- ❌ Don't add the Chrome end-to-end close→rebind test — that's S3 (P1.M3.T1.S3).
- ❌ Don't blind-edit by the item's line numbers (2306/2323/2339) — the file is now 4577 LOC;
  locate with `grep -n 'pool_ensure_connected()'`.
