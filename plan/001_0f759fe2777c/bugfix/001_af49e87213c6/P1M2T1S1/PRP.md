# PRP — P1.M2.T1.S1: Detect EADDRINUSE in pool_chrome_launch and return 1 instead of pool_die

> **Bugfix context**: This subtask fixes part of **Issue 2** from the validation report
> (`plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` §"ISSUE 2",
> and `architecture/scout-boot-connect.md` §2.5). It is a **behavior + test** fix
> (Mode A — the only doc update is the `pool_chrome_launch` docstring in `lib/pool.sh`).
> The repo is no longer greenfield; `lib/pool.sh` is 4429 LOC and fully implemented. This
> subtask is the FIRST of three under P1.M2.T1 (the port-race fix): S1 (this) makes
> `pool_chrome_launch` signal EADDRINUSE as a retryable return-1; **S2** adds the port
> re-pick retry in `_pool_launch_and_verify` + fixes the stale comment; **S3** updates the
> concurrency test. S1's contract is precisely scoped to `pool_chrome_launch` only — it
> does NOT touch the caller, the stale comment, or the concurrency test.

---

## Goal

**Feature Goal**: In `pool_chrome_launch` (`lib/pool.sh:1483-1545`), when Chrome exits
instantly (the `if [[ -z "$pgid" ]]` block at lines 1531-1538), **grep the Chrome log
for EADDRINUSE-like patterns BEFORE the existing `pool_die`**. If the grep matches,
return 1 (NON-FATAL, retryable) instead of `pool_die` (fatal). If the grep does NOT match,
keep the existing `pool_die` (genuine misconfiguration — broken binary, bad flags, corrupt
profile). This converts a port-collision instant-exit from a process-killing fatal abort
into a retryable signal that the caller (`_pool_launch_and_verify`, S2) can catch and
recover from by re-picking a different port.

This is the literal implementation of the Issue 2 "Suggested Fix" bullet: *"Have
`pool_chrome_launch` detect a bind failure from Chrome's log and signal
'retry-with-different-port' instead of `pool_die`."*

**Deliverable**:
1. `lib/pool.sh` — `pool_chrome_launch` instant-exit block (lines 1531-1538) edited to
   grep the Chrome log (`$POOL_STATE_DIR/chrome-<lane>.log`) for the EADDRINUSE pattern
   and `return 1` on a match (keeping `pool_die` for non-matches). One `if grep ...; then
   return 1; fi` block inserted before the existing `pool_die`.
2. `lib/pool.sh` — the `pool_chrome_launch` docstring (lines ~1455-1480) updated to
   document the new return-1-on-EADDRINUSE behavior, the grep pattern used, and the
   caller's set -e guard obligation. Three docstring lines change (the `# Returns` line,
   the `# CONSUMER:` contract line, and the "Highest-impact gotcha" GOTCHA block).
3. `test/validate.sh` — **add** a `selftest_chrome_launch_eaddrinuse` body that uses a
   fake-chrome mock (a bash script that writes an EADDRINUSE line to stderr then exits 1)
   to verify `pool_chrome_launch` returns 1 (not `pool_die`) on the EADDRINUSE path, plus
   a negative case proving a non-EADDRINUSE instant-exit still fails. Mock-based — no real
   Chrome (AGENTS.md §1).
4. No consumer-site changes: `_pool_launch_and_verify` (S2's scope) is NOT modified by S1.
   S1 establishes the return-1 contract; S2 wires the caller to catch it. S1's selftest
   calls `pool_chrome_launch` directly (bypassing the caller) to prove the contract.

**Success Definition**:
- After `source lib/pool.sh; pool_config_init`, calling `pool_chrome_launch` with a fake
  chrome binary that writes `Cannot start http server for devtools` to its log and exits 1
  returns **1** (not `pool_die`'s exit, not 0) — verified by the selftest.
- Calling `pool_chrome_launch` with a fake chrome that exits 1 with a NON-EADDRINUSE
  message still fails (non-zero) — the grep did NOT match, so `pool_die` fired (the
  genuine-misconfig path is preserved).
- The success path (pgid captured, Chrome alive) is UNCHANGED — `return 0` with
  `POOL_CHROME_PID`/`POOL_CHROME_PGID` set.
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean (project gate).
- `bash test/validate.sh` exits 0 with the new `selftest_chrome_launch_eaddrinuse` body
  passing alongside the existing selftest blocks.
- The stale "retries on EADDRINUSE" comments at lib/pool.sh:1335 and :1383 are UNTOUCHED
  (S2's scope — S1 does NOT fix the stale comment).

## User Persona

**Target User**: `pi` agents acquiring lanes concurrently. When two `pi` agents invoke
`agent-browser open <url>` within the same millisecond (before either's `pool_boot_lane`
writes its port to the lease — the TOCTOU window documented in scout-boot-connect §2.2),
both `pool_find_free_port` calls can return the same lowest free port. One Chrome fails
to bind. TODAY, that failure is a fatal `pool_die` (instant-exit path) or a ~60s
hang-then-fatal (CDP-timeout path) — crashing the colliding agent. After S1 (instant-exit
detection) + S2 (caller re-pick), the colliding agent recovers by re-picking a different
port and retrying.

**Use Case**: N `pi` agents concurrently acquire lanes (no stagger — real production load,
unlike the test's 0.3s stagger). Two race onto port 53420. Agent A's Chrome binds
successfully; Agent B's Chrome fails to bind. Agent B's `pool_chrome_launch` detects the
EADDRINUSE text in Chrome's log and returns 1; S2's `_pool_launch_and_verify` catches the
1, calls `pool_find_free_port` again (which now sees 53420 claimed by A's lease), gets
53421, and retries. Agent B succeeds on the second port. No agent crashes.

**User Journey** (post-S1+S2): `pi` agent B → `agent-browser open` → `pool_boot_lane` →
`pool_find_free_port` returns 53420 (raced with A) → `pool_chrome_launch 53420` → Chrome
exits instantly, log says `Cannot start http server for devtools` → **S1: return 1**
(was: `pool_die` → agent B's `agent-browser open` exits non-zero with a fatal error) →
S2: catch 1, `pool_find_free_port` → 53421 → `pool_chrome_launch 53421` → success →
`pool_wait_cdp` → `pool_daemon_connect` → lane provisioned → `exec` driving command.

**Pain Points Addressed**:
- **Fatal crash on a recoverable port collision** (Issue 2): a transient race that should
  be a silent retry becomes a process-killing `pool_die`. S1 makes the instant-exit variant
  retryable; S2 completes the recovery.
- **PRD §1.3 Goal 3 (mutual exclusion / no-collision) + §2.18 ("all release cleanly")**:
  under genuine concurrent load (no test stagger), a collision must not crash an agent.
- **The stale "retries on EADDRINUSE" comment** (lines 1335, 1383) promises a mitigation
  that does not exist in the code. S1 provides the detection half; S2 provides the retry
  half + fixes the comment. (S1 does NOT touch the comment — that's S2.)

## Why

- **Issue 2 (Major)** from the validation report. The fix is scoped to ONE function's
  instant-exit block + its docstring + one selftest. Minimal blast radius. The grep + the
  `return 1` are ~6 lines of logic; the docstring updates are 3 comment lines; the selftest
  is ~45 lines (mock-based, no Chrome).
- **Establishes the retryable contract S2 consumes.** S2 (`_pool_launch_and_verify` re-pick)
  is a SEPARATE subtask that runs after S1. S2's caller needs a signal "the launch failed
  due to a port collision, retry with a different port" — `return 1` is that signal. Without
  S1, `pool_chrome_launch` only emits `0` (success) or `pool_die` (fatal exit) — there is
  no retryable return code for S2 to catch. S1 creates the contract; S2 wires it.
- **The grep pattern is host-verified** (research §3): the item's specified pattern matches
  Chrome's actual `Cannot start http server for devtools` (`devtools_http_handler.cc`) and
  the `Address already in use` strerror variants, and does NOT over-match non-EADDRINUSE
  instant-exit causes (broken GPU, bad flags, missing binary, empty log — all verified
  NO-MATCH). The pattern is used AS SPECIFIED in the contract (do not "improve" it).
- **The mock test approach is host-verified** (research §4): a fake-chrome bash script that
  writes the EADDRINUSE line to stderr and exits 1 triggers the exact instant-exit block,
  the grep matches, and the function returns 1. Proven working this session.
- **CRITICAL NUANCE — documented in the docstring**: Chrome's COMMON EADDRINUSE behavior
  is to STAY UP without the DevTools port (not instant-exit) — caught by `pool_wait_cdp`'s
  30s timeout, recovered by S2's re-pick. S1's grep is the **defensive fast path** for the
  instant-exit variant (which DOES occur for some Chrome configs/versions, and is the path
  the item description explicitly scopes S1 to). S1 is correct and necessary even though
  it is not the sole EADDRINUSE recovery mechanism. See Known Gotchas + the docstring text.

## What

User-visible behavior: none directly (internal library function). A `pi` agent whose
Chrome fails to bind a port due to a collision will, after S1+S2, transparently retry on a
different port instead of crashing. Observable contract for `pool_chrome_launch`:

| Invocation context | Return | Side effects | Failure mode |
|---|---|---|---|
| Success (pgid captured, Chrome alive) | 0 | `POOL_CHROME_PID`/`POOL_CHROME_PGID` set; log line written | — |
| Instant-exit + log matches EADDRINUSE pattern (NEW) | 1 | bare PID killed; `_pool_log` warning written | NON-FATAL, retryable (caller re-picks port) |
| Instant-exit + log does NOT match (genuine misconfig) | (pool_die) | bare PID killed; `pool_die` to stderr + exit 1 | FATAL (broken binary / bad flags / corrupt profile) |
| Bad args / missing POOL_CHROME_BIN / missing log dir | (pool_die) | — | FATAL (unchanged) |

### The grep pattern (verbatim from the item contract — use AS SPECIFIED)

```bash
grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null
```

Host-verified truth table (research §3):

| Chrome stderr phrase | Matches? | Notes |
|---|---|---|
| `Cannot start http server for devtools.` | ✅ | PRIMARY — `devtools_http_handler.cc` `LOG(ERROR)`, always compiled in |
| `Address already in use` / `Bind failed: Address already in use` | ✅ | strerror variant (if `PLOG(ERROR)`) |
| `Couldn't bind to port` | ✅ | `couldn.t bind` — the `.` matches the apostrophe |
| `EADDRINUSE` (bare) | ✅ (dead) | never appears in real Chrome output (Chrome uses `ERR_ADDRESS_IN_USE`) — harmless |
| `Failed to bind to any port` | ❌ | NOT covered — acceptable (rare; the primary strings cover the common case) |
| Broken GPU / bad flags / missing binary / empty log | ❌ | correct — these stay fatal |

### Success Criteria

- [ ] `pool_chrome_launch` instant-exit block (lib/pool.sh:1531-1538) greps the log for
  the EADDRINUSE pattern BEFORE the existing `pool_die`; on a match, logs a warning via
  `_pool_log` and `return 1`; on no match, keeps the existing `pool_die`.
- [ ] The existing `kill "$POOL_CHROME_PID" 2>/dev/null || true` reap line is preserved
  (moved above the grep, or kept where it is — either is fine as long as the bare pid is
  reaped before EITHER exit path).
- [ ] The success path (pgid captured) is UNCHANGED — `POOL_CHROME_PGID` set, `_pool_log`
  line, `return 0`.
- [ ] `pool_chrome_launch` docstring updated: the `# Returns` line, the `# CONSUMER:`
  contract line, and the "Highest-impact gotcha" GOTCHA block all document the new
  return-1-on-EADDRINUSE behavior + the grep pattern + the caller's set -e guard obligation.
- [ ] The docstring documents the NUANCE: the COMMON EADDRINUSE case (Chrome stays up, no
  CDP) is caught by `pool_wait_cdp`'s 30s timeout and recovered by S2; S1's grep is the
  defensive fast path for the instant-exit variant.
- [ ] `test/validate.sh` has a new `selftest_chrome_launch_eaddrinuse` body that:
  (a) uses a fake-chrome mock writing `Cannot start http server for devtools` + exit 1;
  (b) asserts `pool_chrome_launch` returns 1 (not 0, not a harness-killing `pool_die`);
  (c) includes a negative case (non-EADDRINUSE instant-exit) proving the grep is selective.
- [ ] The selftest runs in a subshell (`bash -c '...' || rc=$?`) so a `pool_die` is caught
  as a non-zero rc without killing the harness; wrapped in `timeout 10` (AGENTS.md §2).
- [ ] The selftest uses an ISOLATED subdir of `$ABPOOL_TEST_ROOT` for its fake-chrome + log
  (does NOT pollute the shared `$POOL_STATE_DIR` from `setup()`).
- [ ] The stale "retries on EADDRINUSE" comments at lib/pool.sh:1335 and :1383 are UNTOUCHED
  (S2's scope).
- [ ] `_pool_launch_and_verify` (the caller) is UNTOUCHED (S2's scope).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean.
- [ ] `bash -n test/validate.sh` clean; `shellcheck -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 with the new selftest body passing.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP pins the exact current code at the edit
site (quoted verbatim from lib/pool.sh:1531-1538), gives the verified replacement, cites
the host-verified grep truth table, specifies the exact docstring lines to update, gives
the paste-ready selftest (mock approach verified working this session), and lists the
precise validation commands. The Chrome EADDRINUSE behavior nuance (instant-exit vs
CDP-timeout) is documented so the implementer understands WHY the grep is defensive and
not the sole recovery. No prior exposure to `lib/pool.sh` beyond the quoted snippet is
needed.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: ISSUE 2 — root cause (pool_chrome_launch pool_die on instant-exit, no EADDRINUSE
        detection), the exact suggested fix ("Have pool_chrome_launch detect a bind
        failure from Chrome's log and signal 'retry-with-different-port' instead of
        pool_die"), and the stale "retries on EADDRINUSE" comment at lines 1330/1377-1379.
  pattern: 'ISSUE 2 "Fix Approach" bullet 1 is the literal spec for this subtask.'
  gotcha: 'key_findings assigns the stale-comment fix to "Fix Approach" bullet 3 AND to
        S2 (per the task tree: "P1.M2.T1.S2: Add port re-pick retry in
        _pool_launch_and_verify + fix stale comment"). S1 does NOT touch the stale
        comment — that is S2''s scope. S1 touches ONLY pool_chrome_launch + its docstring.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/scout-boot-connect.md
  why: §2.5 confirms pool_chrome_launch calls pool_die on instant-exit (lines 1523-1534),
        §2.4 confirms _pool_launch_and_verify retries with the SAME port (no re-pick),
        §2.7 confirms the "retries on EADDRINUSE" comment is inaccurate. The call-chain
        diagram (§"Boot flow") shows where pool_chrome_launch sits in the boot path.
  pattern: '§2.5 quotes the exact instant-exit block (the edit site). §2.4 quotes
        _pool_launch_and_verify (the S2 caller — NOT modified by S1).'
  gotcha: 'scout-boot-connect §2.6 notes pool_wait_cdp kills the pgroup on its 30s timeout
        and returns 1 — that is the COMMON EADDRINUSE path (Chrome stays up). S1''s grep
        is for the INSTANT-EXIT variant (Chrome dies). Both paths need recovery; S1
        handles instant-exit, S2 handles the CDP-timeout path + the re-pick.'

- file: lib/pool.sh
  why: THE file being edited. Read lines 1440-1545 (the full pool_chrome_launch: docstring
        + validation + flag build + launch + the instant-exit block). Also read lines
        1325-1385 (the stale-comment site — DO NOT EDIT, but understand it for context).
  pattern: 'Existing style — docstring above the function with lettered GOTCHA blocks;
        `pgid="$(...)" || true` guarded capture; `if [[ -z "$pgid" ]]` branch; `kill
        2>/dev/null || true` reap; `pool_die` fatal. The grep goes INSIDE the `if [[ -z ]]`
        block, BEFORE the pool_die, as an `if grep ...; then return 1; fi`.'
  gotcha: 'The edit site is lib/pool.sh:1531-1538 (the `if [[ -z "$pgid" ]]` block). The
        existing `kill "$POOL_CHROME_PID" 2>/dev/null || true` at line 1536 MUST be
        preserved (it reaps the bare pid before EITHER exit path). The grep + return 1
        go AFTER the kill and BEFORE the pool_die. Do NOT touch the success path
        (lines 1539-1545: POOL_CHROME_PGID assignment + _pool_log + return 0).'

- file: test/validate.sh
  why: 'The pure-function test framework. ADD selftest_chrome_launch_eaddrinuse following
        the existing selftest_* pattern. The single-setup _run_selftest_suite (line 418)
        auto-discovers any selftest_* function via compgen. P1.M1.T1.S1 (config_bool) and
        P1.M1.T2.S1 (dispatch_classify) selftest blocks have LANDED (lines 324-416) —
        place the new body AFTER selftest_dispatch_classify_cases (ends ~416) and BEFORE
        _run_selftest_suite (418).'
  pattern: 'Bodies are plain functions calling assert_eq EXPECTED ACTUAL LABEL (line 58);
        bodies run in the MAIN shell via `if "$fn"` under _run_selftest_suite. Chain
        asserts with `|| return 1` (fail-fast). See selftest_config_bool_truthy (line 324)
        and selftest_dispatch_classify_cases (line 370).'
  gotcha: 'Do NOT use run_test/test_* prefix — that path calls setup() per test (spawns a
        sim-owner process) and AGENTS.md §4 forbids >1 process-spawning setup() call in a
        shared sandbox (the 3rd call hangs). The selftest_* prefix is auto-picked by the
        SINGLE-SETUP _run_selftest_suite. ALSO: pool_chrome_launch may pool_die (exit 1)
        on the negative case — the selftest body MUST run it in a SUBSHELL
        (`bash -c "..." || rc=$?`) so a pool_die is caught as a non-zero rc, not killing
        the harness. This is the ONE difference from the pure-function selftests: the
        function under test can exit the process.'

- file: PRD.md
  why: '§1.3 Goal 3 (mutual exclusion — no two agents share a Chrome), §2.4 step 3f (port
        allocation) + 3g (LAUNCH) + 3h (WAIT for CDP), §2.18 (concurrency harness: N
        parallel agents must each get a distinct lane, all release cleanly), §2.19 (keep
        the flock section short — boot after lock release, which is WHY port selection is
        outside the flock and thus racy).'
  pattern: '§2.4 step 3g is the LAUNCH step pool_chrome_launch implements. §2.19 explains
        why the race exists (flock kept short → port selection outside flock).'
  gotcha: 'PRD §2.4 step 3g does NOT mention EADDRINUSE recovery — the original design
        assumed the anti-collision pre-write (§2.4 step 3b) was sufficient. Issue 2
        corrects this: the pre-write has a TOCTOU window, and the launch must be resilient
        to a lost port race.'

# External authoritative docs (for the HOW — Chrome's EADDRINUSE behavior)
- url: https://chromium.googlesource.com/chromium/src/+/main/content/browser/devtools/devtools_http_handler.cc
  why: 'the source of the PRIMARY grep target: `LOG(ERROR) << "Cannot start http server
        for devtools."`. The DevToolsHttpHandler runs on its own thread; on bind failure
        it logs ERROR and the browser process continues (non-fatal).'
  critical: 'ON CHROME (research §1): EADDRINUSE does NOT cause instant-exit in the COMMON
        case — Chrome stays up without CDP, caught by pool_wait_cdp''s 30s timeout. S1''s
        grep is the DEFENSIVE fast path for the instant-exit variant (some configs/versions
        DO exit instantly, and the item description scopes S1 to the instant-exit block).
        The COMMON case is S2''s job (re-pick after CDP timeout). Document this nuance in
        the docstring so the implementer does not over-claim S1''s scope.'
  section: 'the `LOG(ERROR) << "Cannot start http server for devtools."` site.'

- url: https://chromium.googlesource.com/chromium/src/+/main/net/base/net_error_list.h
  why: 'defines `NET_ERROR(ADDRESS_IN_USE, -147)`. Confirms Chrome uses
        `ERR_ADDRESS_IN_USE` (the enum name), NOT the literal C errno macro `EADDRINUSE`.'
  critical: 'the item''s grep alternative `EADDRINUSE` is DEAD (never matches real Chrome
        output) — but HARMLESS (it simply never matches; the other alternatives do the
        work). Use the pattern AS SPECIFIED in the contract; do NOT remove the dead
        alternative (the contract is explicit, and deviating risks second-guessing the
        item author). Document the dead alternative in a code comment if you like.'
  section: 'NET_ERROR(ADDRESS_IN_USE, -147).'

- url: https://github.com/puppeteer/puppeteer/blob/main/src/node/BrowserRunner.ts
  why: 'Puppeteer polls the CDP endpoint (not the process exit code) because Chrome does
        NOT exit on DevTools bind failure. Confirms the non-fatal behavior.'
  critical: 'corroborates research §1 — the common EADDRINUSE case is a CDP timeout, not
        an instant exit.'
  section: 'the waitForEndpoint polling logic.'

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T2S1/PRP.md
  why: 'P1.M1.T2.S1 (Issue 4 — dispatch_classify) is the parallel sibling that LANDED its
        selftest_dispatch_classify_cases body in validate.sh (lines 370-416). THIS subtask
        ADDS selftest_chrome_launch_eaddrinuse. The two touch DISJOINT code
        (pool_chrome_launch vs pool_dispatch_classify) and DISJOINT test bodies
        (chrome_launch_eaddrinuse vs dispatch_classify_cases) → no merge conflict. Place
        the new body AFTER selftest_dispatch_classify_cases and BEFORE _run_selftest_suite.'
  pattern: 'P1.M1.T2.S1 established the selftest_* single-setup pattern + the
        assert_eq/||return 1 idiom for pure-function bodies. THIS subtask follows the SAME
        pattern but with ONE addition: the body runs pool_chrome_launch in a SUBSHELL
        (bash -c "..." || rc=$?) because the function under test may pool_die (exit 1).'
  gotcha: 'the subshell + || rc=$? is MANDATORY for this selftest (unlike the pure-function
        selftests) — a pool_die in the MAIN shell would kill the harness. See the reference
        impl in research/reference-impl.md §3.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T1S1/PRP.md
  why: 'P1.M1.T1.S1 (Issue 1/5 — boolean normalization) LANDED selftest_config_bool_* bodies
        (validate.sh:324-360) and the _pool_config_bool truthy fix. THIS subtask does NOT
        touch _pool_config_bool or the config_bool selftest. Disjoint code + disjoint
        test bodies. (Included for completeness — no direct dependency.)'
  pattern: 'the selftest_* idiom (assert_eq, ||return 1, single-setup).'
  gotcha: 'none direct — pool_chrome_launch does not read POOL_HEADLESS in a way this
        subtask changes (the --headless flag build is unchanged).'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S1/research/chrome-eaddrinuse-behavior.md
  why: 'the deep-research brief with all host-verified + Chromium-source facts: the
        critical finding that EADDRINUSE does NOT cause instant-exit in the common case
        (S1 is defensive); the grep truth table; the mock-test verification; the S1/S2/S3
        boundary; the strict-mode traps.'
  pattern: 'research §3 (grep truth table) + §4 (mock verification) + §6 (task boundary).'
  gotcha: 'research §1 is the KEY nuance — the implementer MUST understand that S1 is the
        defensive instant-exit path, not the sole EADDRINUSE recovery. The docstring must
        say so (otherwise a reader thinks S1 alone fixes the race).'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M2T1S1/research/reference-impl.md
  why: 'the paste-ready reference implementation of the edit + the docstring updates + the
        selftest body, with all strict-mode guards baked in and the subshell-isolation
        pattern for testing a pool_die-capable function.'
  pattern: '§1 (the edit), §2 (the docstring), §3 (the selftest).'
  gotcha: 'the selftest''s `bash -c "..." _ "$ABPOOL_REPO"` form passes $ABPOOL_REPO as $1
        inside the subshell so it can `source "$1/lib/pool.sh"`. $ABPOOL_REPO is set by
        validate.sh''s setup() (the repo root). Verified present.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                   # 4429 LOC — pool_chrome_launch at 1483-1545 (edit 1531-1538 + docstring 1455-1480)
│                                 #   stale comment at 1335 + 1383 (DO NOT EDIT — S2's scope)
│                                 #   _pool_launch_and_verify at 2117-2161 (DO NOT EDIT — S2's scope)
├── test/
│   └── validate.sh               # ~490 LOC — selftest_* pattern; ADD selftest_chrome_launch_eaddrinuse
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/{key_findings,system_context,external_deps,scout-boot-connect}.md
    ├── TEST_RESULTS.md
    ├── P1M1T1S1/PRP.md                # LANDED (config_bool)
    ├── P1M1T2S1/PRP.md                # LANDED (dispatch_classify) — parallel sibling
    └── P1M2T1S1/                      # THIS subtask
        ├── PRP.md                     # THIS FILE
        └── research/{chrome-eaddrinuse-behavior.md, reference-impl.md}
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh       — pool_chrome_launch instant-exit block (grep + return 1 before pool_die) + docstring (3 lines)
#   test/validate.sh  — ADD selftest_chrome_launch_eaddrinuse body (~45 lines, mock-based)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (Chrome EADDRINUSE behavior — research §1): Chrome does NOT instant-exit on
# EADDRINUSE in the COMMON case. The DevToolsHttpHandler (devtools_http_handler.cc) logs
# LOG(ERROR) "Cannot start http server for devtools." and the browser process CONTINUES.
# The CDP endpoint never answers → pool_wait_cdp's 30s timeout catches it → S2 re-picks.
# S1's grep (in the instant-exit block) is the DEFENSIVE fast path for the variant where
# Chrome DOES exit instantly (some configs/versions, or a combined error). S1 is CORRECT
# and NECESSARY (it converts a fatal pool_die into return 1 for that variant), but it is
# NOT the sole EADDRINUSE recovery. The docstring MUST say so. Do NOT over-claim S1's scope.
# Source: https://chromium.googlesource.com/chromium/src/+/main/content/browser/devtools/devtools_http_handler.cc

# CRITICAL (the grep alternative `EADDRINUSE` is DEAD): Chrome uses ERR_ADDRESS_IN_USE
# (the net::Error enum, net_error_list.h), NOT the literal C errno macro `EADDRINUSE`.
# The string `EADDRINUSE` never appears in Chrome's stderr. The item's grep pattern
# includes `EADDRINUSE` as an alternative — it is HARMLESS (never matches; the other
# alternatives do the work). Use the pattern AS SPECIFIED in the contract; do NOT remove
# the dead alternative (the contract is explicit). Optionally note it in a code comment.

# CRITICAL (set -e + grep): a bare `grep -qiE ... "$log_file"` that finds NO match returns
# rc 1 and ABORTS under set -e (propagated by the S1 header). ALWAYS wrap in `if grep ...;
# then ...; fi` (the if-condition is errexit-exempt) — the item's specified structure
# (`if grep -qiE ...; then return 1; fi`) is already correct. Do NOT use a bare `grep ||
# true` followed by `$?` — the `if` form is cleaner and matches the contract.

# CRITICAL (testing a pool_die-capable function): pool_chrome_launch calls pool_die (exit 1)
# on the non-EADDRINUSE instant-exit path. A selftest body that calls it in the MAIN shell
# would KILL THE HARNESS on the negative case. The selftest MUST run pool_chrome_launch in
# a SUBSHELL: `bash -c '...' || rc=$?` (or `( ... ) || rc=$?`). The `|| rc=$?` captures
# the exit (pool_die's exit 1 OR return 1 OR return 0) as a non-zero rc without killing
# the harness. This is the ONE difference from the pure-function selftests (config_bool,
# dispatch_classify) which never exit the process.

# CRITICAL (isolated state for the selftest): pool_chrome_launch writes its log to
# $POOL_STATE_DIR/chrome-<lane>.log. The selftest MUST override AGENT_BROWSER_POOL_STATE
# to an isolated subdir of $ABPOOL_TEST_ROOT (NOT the shared $POOL_STATE_DIR from setup())
# so the fake-chrome log does not pollute the shared state. Use
# AGENT_BROWSER_POOL_STATE="$ABPOOL_TEST_ROOT/eaddrinuse-selftest" + AGENT_CHROME_BIN=<fake>.

# GOTCHA (the kill reap line must be preserved): the existing
# `kill "$POOL_CHROME_PID" 2>/dev/null || true` at line 1536 reaps the bare pid before
# pool_die. The edit MUST keep this kill (it runs before BOTH the return-1 and the
# pool_die paths). Move it above the grep, or keep it where it is and add the grep+return
# after it — either is fine as long as the pid is reaped regardless of which exit path fires.

# GOTCHA (the log file exists before the grep): pool_chrome_launch opens the log redirect
# `>"$log_file" 2>&1 &` BEFORE the setsid fork (line 1519-1521). The mkdir -p at line 1505
# ensures the dir exists. So by the time the instant-exit block fires, $log_file EXISTS
# (possibly empty if Chrome died before writing, or containing Chrome's stderr). The grep
# handles both (empty log → no match → pool_die, which is correct for a Chrome that died
# without explanation). The `2>/dev/null` on grep suppresses "No such file" defensively.

# GOTCHA (the stale comment is S2's scope): lines 1335 and 1383 say "retries on EADDRINUSE"
# which is inaccurate. S1 does NOT fix these — S2 ("Add port re-pick retry in
# _pool_launch_and_verify + fix stale comment") does. S1 touches ONLY pool_chrome_launch
# (lines 1483-1545) + its docstring (1455-1480). Verify with `git diff` that lines 1335
# and 1383 are unchanged.

# GOTCHA (the caller is S2's scope): _pool_launch_and_verify (lines 2117-2161) currently
# calls `pool_chrome_launch "$port" ...` WITHOUT a set -e guard (it assumes 0-or-pool_die).
# After S1, pool_chrome_launch can return 1 — which under set -e would ABORT the caller
# (unguarded non-zero). S2 will add `if ! pool_chrome_launch ...; then re-pick; fi`. S1
# does NOT touch the caller. This means: between S1 and S2, a return-1 from
# pool_chrome_launch would abort _pool_launch_and_verify under set -e — but that is the
# SAME failure mode as the pre-S1 pool_die (the agent crashes), just via a different path.
# S1 alone does not break anything; S1+S2 together deliver the recovery. The task tree
# sequences S1 before S2; S2's PRP will reference S1's contract.

# GOTCHA (scope): this fix is the pool_chrome_launch instant-exit EADDRINUSE detection
# ONLY. Do NOT: add the port re-pick in _pool_launch_and_verify (S2); fix the stale comment
# (S2); update the concurrency test (S3); touch pool_wait_cdp; touch pool_find_free_port;
# touch the close-rebind path (P1.M3). One function, one block, plus its docstring and a test.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. The only "structure" is the `pool_chrome_launch`
return-code contract, which expands from `{0, pool_die}` to `{0, 1, pool_die}`:

| Return | Meaning | New? |
|---|---|---|
| 0 | Chrome launched, pgid captured, globals set | (unchanged) |
| 1 | Instant-exit + EADDRINUSE detected in log (retryable — caller re-picks port) | **NEW (S1)** |
| pool_die (exit 1) | Bad args / missing config / instant-exit WITHOUT EADDRINUSE (genuine misconfig) | (unchanged) |

The caller (`_pool_launch_and_verify`, S2's scope) gains the obligation to guard:
`if ! pool_chrome_launch "$port" ...; then <re-pick port>; fi` (S2 implements this).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current function and confirm the edit site
  - RUN: sed -n '1483,1545p' lib/pool.sh   # (or read lib/pool.sh offset 1483 limit 63)
  - EXPECT: the pool_chrome_launch function with:
      - docstring (~1455-1480): "# Returns 0 on success; pool_die on bad args / instant Chrome death..."
      - the launch + pgid capture (1519-1531)
      - the instant-exit block (1531-1538): "if [[ -z \"$pgid\" ]]; then kill ...; pool_die ...; fi"
      - the success path (1539-1545): POOL_CHROME_PGID assignment + _pool_log + return 0
  - RUN (confirm the stale comment is OUT OF SCOPE — do NOT edit):
        sed -n '1333,1336p;1381,1385p' lib/pool.sh
    - EXPECT: the two "retries on EADDRINUSE" comments. LEAVE THEM UNCHANGED (S2's scope).
  - RUN (empirical baseline — confirm the current pool_die behavior with a mock BEFORE fixing):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        fake="$tmp/fake"; printf '#!/usr/bin/env bash\necho "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2\nexit 1\n' > "$fake"; chmod +x "$fake"
        AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' \
          ; echo "exit=$?"
    - EXPECT (BEFORE fix): a pool_die message ("...exited immediately; see log...") + exit=1.
      (After fix: NO pool_die message, a _pool_log warning, + exit=1 via return 1. The
      distinction is the _pool_log warning line + the fact the harness subshell exit is 1
      from `return 1` not from `pool_die`'s exit — both are rc 1, but the warning proves
      the grep matched.)
  - NOTE: do NOT touch the success path, the stale comments (1335/1383), or
        _pool_launch_and_verify (2117-2161). The ONLY code change is inside the
        `if [[ -z "$pgid" ]]` block.

Task 1: EDIT lib/pool.sh — add the EADDRINUSE grep + return 1 in the instant-exit block (lines 1531-1538)
  - FIND (the exact current block — verify with the read in Task 0):
        if [[ -z "$pgid" ]]; then
            # Chrome died before we could read its pgroup. Best-effort reap of the bare pid,
            # then die with the log path (Chrome's stderr is in there).
            kill "$POOL_CHROME_PID" 2>/dev/null || true
            pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                     "see log: $log_file"
        fi
  - REPLACE WITH:
        if [[ -z "$pgid" ]]; then
            # Chrome died before we could read its pgroup. Best-effort reap of the bare pid
            # (runs before BOTH exit paths below).
            kill "$POOL_CHROME_PID" 2>/dev/null || true
            # EADDRINUSE detection (Issue 2): if Chrome's log shows a port-bind failure,
            # return 1 (NON-FATAL, retryable) so _pool_launch_and_verify (S2) can re-pick a
            # port. This handles the instant-exit-with-EADDRINUSE edge case. NOTE: the
            # COMMON EADDRINUSE case (Chrome stays up, no CDP → pool_wait_cdp 30s timeout)
            # is recovered by S2's port re-pick on the CDP-timeout path; THIS grep is the
            # defensive fast path for the instant-exit variant. The pattern matches Chrome's
            # "Cannot start http server for devtools" (devtools_http_handler.cc) + the
            # strerror "Address already in use" / "Bind failed" variants. (The `EADDRINUSE`
            # alternative is dead — Chrome uses ERR_ADDRESS_IN_USE — but harmless; kept per
            # the item contract.) `if grep` is errexit-exempt (rc 1 = no match = clean branch).
            if grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null; then
                _pool_log "pool_chrome_launch: Chrome exited immediately (port $port may be in use); see log: $log_file"
                return 1
            fi
            # Genuine misconfiguration (broken binary / bad flags / corrupt profile) — FATAL.
            pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                     "see log: $log_file"
        fi
  - WHY: a port-collision instant-exit is retryable (re-pick a different port); a
        genuine misconfig is fatal. The grep distinguishes them.
  - PRESERVE: the `kill "$POOL_CHROME_PID" 2>/dev/null || true` reap (moved above the grep);
        the existing `pool_die` (now the else/fallthrough path); the success path below.
  - GOTCHA: the `if grep ...; then return 1; fi` structure is errexit-safe (grep's rc-1 on
        no-match is the if-condition, not a bare statement). Do NOT use `grep || true` +
        `$?` — the `if` form matches the contract.
  - GOTCHA: `_pool_log` (not `pool_die`) on the EADDRINUSE path — it is a warning, not an
        error. `_pool_log` never fails the caller (falls back to stderr).
  - GOTCHA: `return 1` (not `exit 1`) — return from the FUNCTION so the caller can catch it
        (S2's `if ! pool_chrome_launch ...`). `exit 1` would be uncatchable.

Task 2: EDIT lib/pool.sh — update the pool_chrome_launch docstring (lines ~1455-1480)
  - FIND (the `# Returns` line ~1465):
        # Returns 0 on success; pool_die on bad args / instant Chrome death / missing log dir.
  - REPLACE WITH:
        # Returns 0 on success; 1 on instant Chrome death WITH an EADDRINUSE-like error in
        # the log (port collision — retryable, caller re-picks a port); pool_die on bad args
        # / instant Chrome death WITHOUT EADDRINUSE (genuine misconfiguration) / missing log dir.
  - FIND (the `# CONSUMER:` line ~1467-1469):
        # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → Chrome is launched + the two
        #   globals are set (pgid==pid); any failure exits the process via pool_die. The caller then
        #   calls pool_wait_cdp <port>, then reads POOL_CHROME_PID/POOL_CHROME_PGID into the lease.
  - REPLACE WITH:
        # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → Chrome launched + the two
        #   globals are set (pgid==pid); rc 1 → EADDRINUSE detected on instant-exit (retryable —
        #   caller re-picks a port via pool_find_free_port); pool_die → fatal (propagates). The
        #   caller MUST guard under set -e: `if ! pool_chrome_launch ...; then <re-pick port>; fi`.
        #   The caller then calls pool_wait_cdp <port>, then reads the globals into the lease.
  - FIND (the "Highest-impact gotcha" GOTCHA block ~1473-1477):
        # GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
        #   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
        #   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
        #   `[[ -z ]]` check → pool_die with the log path. Highest-impact gotcha in this task.
  - REPLACE WITH:
        # GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
        #   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
        #   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
        #   `[[ -z ]]` check. On instant death, grep the log for EADDRINUSE-like patterns
        #   (Issue 2): match → return 1 (retryable, caller re-picks port); no match → pool_die
        #   (genuine misconfiguration). NOTE: the COMMON EADDRINUSE case is Chrome STAYING UP
        #   without CDP → caught by pool_wait_cdp's 30s timeout → S2 re-picks; THIS grep is the
        #   defensive fast path for the instant-exit variant. Pattern:
        #   grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind'.
  - WHY: the docstring is now factually wrong after Task 1 (it claims "any failure exits
        via pool_die"); keep code+comments in lockstep. The caller obligation (set -e guard)
        is NEW and must be documented so S2's implementer knows the contract.
  - GOTCHA: do NOT edit the other GOTCHA blocks (setsid, log dir, POOL_CHROME_BIN, no-bare-~,
        naming) — only the "Highest-impact gotcha" block (the pgid/instant-exit one) changes.

Task 3: ADD test/validate.sh — selftest_chrome_launch_eaddrinuse body
  - ADD a new function named `selftest_chrome_launch_eaddrinuse` (the _run_selftest_suite at
        validate.sh:418 auto-discovers any `selftest_*` function — NO registration needed).
  - PLACE: AFTER `selftest_dispatch_classify_cases` (ends ~line 416) and BEFORE the
        `_run_selftest_suite` definition (line 418). (compgen discovery is order-independent;
        placement is for textual merge cleanliness with the landed P1.M1.T1.S1/P1.M1.T2.S1 blocks.)
  - FOLLOW pattern: selftest_config_bool_truthy (validate.sh:324) + selftest_dispatch_classify_cases
        (validate.sh:370) — plain function, assert_eq, `|| return 1` fail-fast, MAIN shell under
        single-setup. ONE ADDITION: run pool_chrome_launch in a SUBSHELL (`bash -c '...' || rc=$?`)
        because the function under test may pool_die (exit 1) on the negative case.
  - NAMING: selftest_chrome_launch_eaddrinuse.
  - REFERENCE IMPLEMENTATION (verified mock approach — research §4; the fake chrome writes
        the PRIMARY Chromium EADDRINUSE string + exits 1, triggering the instant-exit block):
      ----------------------------------------------------------------
      # --- pool_chrome_launch EADDRINUSE detection (P1.M2.T1.S1 / Issue 2) ---------
      # Mock-based test: a fake "chrome" binary writes an EADDRINUSE line to stderr then
      # exits 1 instantly. Verifies pool_chrome_launch detects the bind failure in the log
      # and returns 1 (retryable) instead of pool_die (fatal). No real Chrome (AGENTS.md §1).
      # Picked up by the single-setup _run_selftest_suite (same runner as the other selftest_*).
      #
      # NOTE: pool_chrome_launch may pool_die (exit 1) on the negative case. The body runs it
      # in a SUBSHELL (bash -c '...' || rc=$?) so a pool_die is caught as a non-zero rc, not
      # killing the harness. This is the ONE difference from the pure-function selftests.
      selftest_chrome_launch_eaddrinuse() {
          local fakechrome logdir log_file rc
          # Isolated subdir under the test root (do NOT pollute the shared $POOL_STATE_DIR).
          logdir="$ABPOOL_TEST_ROOT/eaddrinuse-selftest"
          mkdir -p -- "$logdir"
          fakechrome="$logdir/fake-chrome"
          # The fake chrome: write the primary Chromium EADDRINUSE string to stderr (captured
          # to the log by the setsid redirect), then exit 1 instantly (triggers empty-pgid).
          cat >"$fakechrome" <<'MOCK'
      #!/usr/bin/env bash
      echo "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2
      exit 1
      MOCK
          chmod +x -- "$fakechrome"

          # Point POOL_CHROME_BIN at the fake + POOL_STATE_DIR at the isolated logdir so the
          # chrome-<lane>.log lands where we can inspect it. Run pool_chrome_launch in a SUBSHELL
          # so a (buggy) pool_die is caught as a non-zero rc rather than killing the harness.
          log_file="$logdir/chrome-7.log"
          rc=0
          AGENT_CHROME_BIN="$fakechrome" \
          AGENT_BROWSER_POOL_STATE="$logdir" \
          timeout 10 bash -c '
              set -euo pipefail
              source "$1/lib/pool.sh"
              pool_config_init
              pool_chrome_launch 53420 /tmp/__abp_dummy_udd__ 7
          ' _ "$ABPOOL_REPO" || rc=$?

          # ASSERT: rc 1 (EADDRINUSE detected → return 1, NOT pool_die's exit 1 which would
          # also be rc 1; the distinguishing evidence is the log contained the EADDRINUSE text
          # the grep matched, AND no "exited immediately" pool_die message — but the cleanest
          # machine-checkable assertion is rc==1 + the log file exists + the grep matches it).
          assert_eq "1" "$rc" "pool_chrome_launch returns 1 on EADDRINUSE instant-exit (not 0)" || return 1
          [[ -f "$log_file" ]] || { _fail "chrome log not created at $log_file"; return 1; }
          grep -qiE 'cannot start http server|address already in use' "$log_file" \
              || { _fail "log missing EADDRINUSE text (grep pattern would not have matched)"; return 1; }

          # --- Negative case: a fake chrome that exits 1 WITHOUT EADDRINUSE → pool_die (rc!=0) ---
          # Proves the grep is selective: a non-EADDRINUSE instant-exit still fails (the grep
          # did NOT match → pool_die fired). We assert rc!=0 (failure) AND the log does NOT
          # match the EADDRINUSE pattern.
          local fakebad="$logdir/fake-bad-chrome"
          cat >"$fakebad" <<'MOCK'
      #!/usr/bin/env bash
      echo "ERROR:gpu_init.cc] GPU process isn't usable. Goodbye." >&2
      exit 1
      MOCK
          chmod +x -- "$fakebad"
          local log2="$logdir/chrome-8.log" rc2=0
          AGENT_CHROME_BIN="$fakebad" \
          AGENT_BROWSER_POOL_STATE="$logdir" \
          timeout 10 bash -c '
              set -euo pipefail
              source "$1/lib/pool.sh"
              pool_config_init
              pool_chrome_launch 53421 /tmp/__abp_dummy_udd2__ 8
          ' _ "$ABPOOL_REPO" || rc2=$?
          # Non-EADDRINUSE instant-exit → pool_die → rc!=0 (must NOT be rc 0).
          [[ "$rc2" -ne 0 ]] || { _fail "non-EADDRINUSE instant-exit returned 0 (should fail)"; return 1; }
          # And the log must NOT contain EADDRINUSE text (proving the grep correctly did NOT match).
          if [[ -f "$log2" ]] && grep -qiE 'cannot start http server|address already in use' "$log2"; then
              _fail "negative-case log unexpectedly matched EADDRINUSE"; return 1
          fi
      }
      ----------------------------------------------------------------
  - WHY a mock (not real Chrome): AGENTS.md §1 forbids launching real Chrome during
        research/testing against the shared sandbox. The fake-chrome approach triggers the
        EXACT code path (setsid + redirect + instant-exit + empty-pgid + grep) without a
        real Chrome. Verified working this session (research §4).
  - WHY a subshell: pool_chrome_launch calls pool_die (exit 1) on the negative case. A
        MAIN-shell call would kill the harness. `bash -c '...' || rc=$?` captures the exit.
  - WHY `timeout 10`: AGENTS.md §2 (hard timeout on every subprocess). The fake chrome
        exits instantly, so this never trips, but it satisfies the rule.
  - WHY `AGENT_BROWSER_POOL_STATE="$logdir"`: isolates the chrome log to the test subdir
        (does NOT pollute the shared $POOL_STATE_DIR from setup()). AGENT_CHROME_BIN points
        at the fake (pool_config_init canonicalizes an absolute path harmlessly).
  - GOTCHA: `assert_eq "1" "$rc"` — a pool_die would ALSO be rc 1. The DISTINGUISHING
        assertion is the log-grep (the EADDRINUSE text was in the log, so the grep matched,
        so the return-1 path fired, NOT pool_die). The negative case (log does NOT match)
        proves the grep is selective. Together they pin the behavior.
  - GOTCHA: do NOT spawn a real sim-owner or Chrome — this is a mock-based test. The single
        setup() provides $ABPOOL_TEST_ROOT + $ABPOOL_REPO; the body uses those + its own subdir.

Task 4: VERIFY — run the full validation gauntlet BEFORE claiming done
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -S warning lib/pool.sh
      bash -n test/validate.sh
      shellcheck -S warning test/validate.sh
      bash test/validate.sh                 # must exit 0, incl. the new selftest_chrome_launch_eaddrinuse
  - RUN (the S1 fix in isolation — the motivating behavior, mock-based):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        fake="$tmp/fake"; printf '#!/usr/bin/env bash\necho "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2\nexit 1\n' > "$fake"; chmod +x "$fake"
        AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' \
          ; echo "exit=$?"
        # EXPECT (AFTER fix): exit=1 (via return 1, NOT pool_die). And the pool log
        #       ($tmp/pool.log) contains the _pool_log warning "port 53420 may be in use".
        grep -q "port 53420 may be in use" "$tmp/pool.log" && echo "OK: warning logged (return-1 path fired)" \
          || echo "FAIL: no warning (pool_die path fired instead)"
        # EXPECT: OK: warning logged (return-1 path fired)
  - RUN (negative case — non-EADDRINUSE instant-exit still pool_die-s):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        fake="$tmp/fake"; printf '#!/usr/bin/env bash\necho "ERROR:gpu_init.cc] GPU process isn'"'"'t usable. Goodbye." >&2\nexit 1\n' > "$fake"; chmod +x "$fake"
        AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' \
          ; echo "exit=$?"
        # EXPECT: a pool_die message ("...exited immediately; see log...") + exit=1.
        #         (The grep did NOT match → pool_die fired. Genuine misconfig preserved.)
        grep -q "exited immediately" "$tmp/pool.log" 2>/dev/null || true   # pool_die goes to stderr, not pool.log
        # The pool_die message is on STDERR (captured by the outer bash -c). Confirm via:
        AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' 2>&1 \
          | grep -q "exited immediately" && echo "OK: pool_die fired for non-EADDRINUSE" || echo "FAIL"
        # EXPECT: OK: pool_die fired for non-EADDRINUSE
  - RUN (stale comment + caller UNCHANGED — git diff scope check):
        git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'retries on EADDRINUSE|_pool_launch_and_verify|authoritative bind' \
          && echo "FAIL: out-of-scope edit" || echo "scope OK (stale comment + caller unchanged)"
        # EXPECT: scope OK (stale comment + caller unchanged). The ONLY lib/pool.sh diff lines
        #       are: the grep+return-1 block, the kill-line reorder (if any), and the 3 docstring lines.
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern A — the edit (grep + return 1 before pool_die, inside the instant-exit block) ---
# BEFORE (lib/pool.sh:1531-1538):
#     if [[ -z "$pgid" ]]; then
#         kill "$POOL_CHROME_PID" 2>/dev/null || true
#         pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
#                  "see log: $log_file"
#     fi
# AFTER:
#     if [[ -z "$pgid" ]]; then
#         kill "$POOL_CHROME_PID" 2>/dev/null || true
#         if grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null; then
#             _pool_log "pool_chrome_launch: Chrome exited immediately (port $port may be in use); see log: $log_file"
#             return 1
#         fi
#         pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
#                  "see log: $log_file"
#     fi
# WHY: the grep distinguishes retryable (EADDRINUSE) from fatal (genuine misconfig).
# `if grep` is errexit-exempt (rc 1 no-match = clean branch, not a set -e abort).

# --- Pattern B — the grep pattern (verbatim from the item contract; do NOT alter) ---
grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null
# Host-verified truth table (research §3):
#   "Cannot start http server for devtools" → MATCH (primary, devtools_http_handler.cc)
#   "Address already in use" / "Bind failed: ..." → MATCH (strerror variant)
#   "Couldn't bind to port" → MATCH (couldn.t bind — . matches apostrophe)
#   broken GPU / bad flags / missing binary / empty log → NO MATCH (correct, stays fatal)
# The `EADDRINUSE` alternative is dead (Chrome uses ERR_ADDRESS_IN_USE) but harmless.

# --- Pattern C — testing a pool_die-capable function (subshell + || rc=$?) ---
# Unlike pure-function selftests (config_bool, dispatch_classify), pool_chrome_launch may
# pool_die (exit 1). The selftest MUST run it in a subshell so the harness survives:
rc=0
AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$logdir" \
timeout 10 bash -c '
    set -euo pipefail
    source "$1/lib/pool.sh"
    pool_config_init
    pool_chrome_launch 53420 /tmp/__abp_dummy_udd__ 7
' _ "$ABPOOL_REPO" || rc=$?
assert_eq "1" "$rc" "..." || return 1
# The `|| rc=$?` captures pool_die's exit 1 OR return 1 OR return 0 as a non-zero rc.

# --- Pattern D — the distinguishing assertion (return-1 vs pool_die both = rc 1) ---
# Both `return 1` and `pool_die` (exit 1) yield rc 1 from the subshell. The DISTINGUISHING
# evidence is the log: the EADDRINUSE text WAS in the log (so the grep matched → return-1
# path fired). Assert rc==1 AND the log file contains the EADDRINUSE text the grep matched:
assert_eq "1" "$rc" "returns 1" || return 1
grep -qiE 'cannot start http server|address already in use' "$log_file" \
    || { _fail "log missing EADDRINUSE text"; return 1; }
# The negative case (non-EADDRINUSE log → grep no-match → pool_die) proves selectivity.

# --- Critical micro-rules baked into the above ---------------------------------
#  * `if grep -qiE ...; then return 1; fi` — the if-condition is errexit-exempt; grep's
#    rc-1 (no match) is a clean branch, not a set -e abort.
#  * `kill "$POOL_CHROME_PID" 2>/dev/null || true` — preserved (reaps the bare pid before
#    EITHER exit path). Moved above the grep, or kept in place — either works.
#  * `_pool_log` (not pool_die) on the EADDRINUSE path — a warning, not an error.
#  * `return 1` (not `exit 1`) — return from the function so S2's caller can catch it.
#  * `2>/dev/null` on grep — suppresses "No such file" defensively (the log exists by
#    construction, but be robust).
#  * The success path (lines 1539-1545) is UNCHANGED — POOL_CHROME_PGID + _pool_log + return 0.
#  * The stale comments (1335, 1383) + _pool_launch_and_verify (2117-2161) are UNTOUCHED.
```

### Integration Points

```yaml
CODE (2 in-place edits, 1 addition — no new files):
  - lib/pool.sh:1531-1538   pool_chrome_launch instant-exit block: add grep + return 1 before pool_die
  - lib/pool.sh:~1465-1480  pool_chrome_launch docstring: 3 lines (Returns + CONSUMER + GOTCHA)
  - test/validate.sh:+1     1 new selftest_chrome_launch_eaddrinuse body (ADD, ~45 lines, mock-based)

CONSUMER (DO NOT TOUCH — S2's scope):
  - lib/pool.sh:2117-2161   _pool_launch_and_verify: currently calls pool_chrome_launch
                            UNGUARDED (assumes 0-or-pool_die). After S1, a return-1 would
                            abort it under set -e. S2 adds `if ! pool_chrome_launch ...; then
                            re-pick port; fi`. S1 does NOT touch this — S1 only establishes
                            the return-1 contract that S2 consumes.

OUT OF SCOPE (S2 / S3 — do NOT edit):
  - lib/pool.sh:1335        stale "retries on EADDRINUSE" comment (S2 fixes)
  - lib/pool.sh:1383        stale "retries on EADDRINUSE" GOTCHA (S2 fixes)
  - lib/pool.sh:2117-2161   _pool_launch_and_verify port re-pick (S2 adds)
  - test/concurrency.sh     collision-recovery test (S3 updates)

PARALLEL SUBTASK (P1.M1.T2.S1 — LANDED, disjoint, no conflict):
  - edits pool_dispatch_classify (lib/pool.sh:3091-3095) + docstring, adds
    selftest_dispatch_classify_cases (validate.sh:370-416). Disjoint code + disjoint test body.

CONFIG: none. No env vars. No defaults. No paths. (AGENT_CHROME_BIN / AGENT_BROWSER_POOL_STATE
        are existing config vars used only by the selftest to isolate the mock.)
ROUTES: none.
DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                 # parse check. MUST be clean (no output).
shellcheck -S warning lib/pool.sh   # MUST report zero issues (matches the project's gate).
bash -n test/validate.sh            # parse check the test file after adding the body.
shellcheck -S warning test/validate.sh   # MUST be clean.
# Expected: zero output from all four.
# NOTE: the project uses `shellcheck -S warning` (the project's gate; ShellCheck 0.11.0).
```

### Level 2: Unit Tests (Component Validation)

```bash
# 2a. The S1 fix in isolation (mock-based — the motivating behavior):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fake="$tmp/fake"
printf '#!/usr/bin/env bash\necho "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2\nexit 1\n' > "$fake"
chmod +x "$fake"
AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' \
  ; echo "exit=$?"
grep -q "port 53420 may be in use" "$tmp/pool.log" && echo "ISSUE 2 S1 OK (return-1 path fired)" \
  || echo "FAIL: no warning (pool_die fired instead)"
# Expected: exit=1 AND "ISSUE 2 S1 OK (return-1 path fired)".
#           (was BEFORE fix: a pool_die "exited immediately" message + no "port may be in use" warning.)

# 2b. The test framework self-test suite (now includes the new body):
bash test/validate.sh
# Expected: prints "== selftest_chrome_launch_eaddrinuse / PASS" and a final
#           "N passed, 0 failed" line; exits 0.

# 2c. Negative case — non-EADDRINUSE instant-exit still pool_die-s (genuine misconfig preserved):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fake="$tmp/fake"
printf '#!/usr/bin/env bash\necho "ERROR:gpu_init.cc] GPU process isn'"'"'t usable. Goodbye." >&2\nexit 1\n' > "$fake"
chmod +x "$fake"
AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 /tmp/__x__ 7' 2>&1 \
  | grep -q "exited immediately" && echo "NEGATIVE OK (pool_die fired for non-EADDRINUSE)" || echo "FAIL"
# Expected: NEGATIVE OK (pool_die fired for non-EADDRINUSE).

# 2d. Success-path regression — a fake chrome that STAYS UP (no instant exit) returns 0.
#     (Use a fake that sleeps; the pgid is captured → success path → return 0. Then kill it.)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fake="$tmp/fake"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$fake"   # stays up
chmod +x "$fake"
AGENT_CHROME_BIN="$fake" AGENT_BROWSER_POOL_STATE="$tmp" \
timeout 5 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_chrome_launch 53420 '"$tmp"'/udd 7; echo "rc=$?"; kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true' \
  ; echo "outer exit=$?"
# Expected: "rc=0" printed (success path: pgid captured, return 0) then the kill reaps the fake.
#           (The `timeout 5` bounds the subshell; the fake sleeps 30 but we kill it after the rc check.)
# NOTE: this confirms the success path is UNCHANGED by the edit.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Verify the edit scope — ONLY pool_chrome_launch changed (stale comment + caller untouched):
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'retries on EADDRINUSE|_pool_launch_and_verify|authoritative bind' \
  && echo "FAIL: out-of-scope edit" || echo "scope OK (stale comment + caller unchanged)"
# Expected: scope OK (stale comment + caller unchanged).

# 3b. Verify the full lib/pool.sh diff is minimal (only the grep block + 3 docstring lines):
git diff --stat -- lib/pool.sh
# Expected: 1 file changed, ~10-15 insertions, ~5 deletions (the grep+return block + the
#           kill-line reorder + the 3 docstring lines).
git diff -- lib/pool.sh
# Expected: ONLY these hunks:
#   - the instant-exit block: kill moved up (or kept) + the `if grep ...; then _pool_log; return 1; fi`
#     inserted before the pool_die.
#   - the docstring: the `# Returns` line, the `# CONSUMER:` block, the "Highest-impact gotcha" GOTCHA.

# 3c. Verify the test body was added (and named selftest_*):
grep -n 'selftest_chrome_launch_eaddrinuse' test/validate.sh
# Expected: the function definition line + (optionally) the PASS line from a validate.sh run.

# 3d. Full repo smoke (no real Chrome launched — mock-based sourcing + launch):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         type pool_chrome_launch >/dev/null && echo SOURCED_OK'
# Expected: SOURCED_OK.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the grep pattern's selectivity on THIS host (the core correctness claim).
#     Feed the pattern known EADDRINUSE phrases (MATCH) and known non-EADDRINUSE phrases (NO MATCH).
bash -c '
set -euo pipefail
pat="address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind"
check() { if grep -qiE "$pat" <<<"$1" 2>/dev/null; then echo "MATCH: $2"; else echo "NO MATCH: $2"; fi; }
check "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." "primary (devtools)"
check "Bind failed: Address already in use" "strerror variant"
check "Couldn'"'"'t bind to port" "couldnt bind"
check "ERROR:gpu_init.cc] GPU process isn'"'"'t usable. Goodbye." "broken GPU (must NOT match)"
check "Missing required flag: --user-data-dir" "bad flags (must NOT match)"
check "" "empty log (must NOT match)"
'
# Expected: MATCH for the first three; NO MATCH for the last three. This is WHY the grep
#           is selective: EADDRINUSE → return 1; genuine misconfig → pool_die.

# 4b. Confirm the mock triggers the EXACT instant-exit code path (empirical proof of the
#     fix's mechanism — no real Chrome, AGENTS.md-compliant):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fake="$tmp/fake"
printf '#!/usr/bin/env bash\necho "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2\nexit 1\n' > "$fake"
chmod +x "$fake"
# Simulate the pool_chrome_launch launch+capture+grep logic in isolation (mirrors the edit):
bash -c '
set -euo pipefail
log="'"$tmp"'/chrome.log"
setsid -- "'"$fake"'" >"$log" 2>&1 &
PID=$!
sleep 0.2
pgid="$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d " ")" || true
echo "pgid=[$pgid]"
if [[ -z "$pgid" ]]; then
    if grep -qiE "address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind" "$log" 2>/dev/null; then
        echo "DETECTED: EADDRINUSE → return 1 (retryable)"; exit 1
    else
        echo "NOT EADDRINUSE → pool_die (fatal)"; exit 2
    fi
fi'
echo "sim exit=$?"
# Expected: pgid=[] (empty, instant exit), "DETECTED: EADDRINUSE → return 1 (retryable)", sim exit=1.
#           This is the empirical proof the mock + grep + return-1 mechanism works end-to-end.

# 4c. Confirm the stale comment is UNCHANGED (S2's scope — S1 must not touch it):
git diff -- lib/pool.sh | grep -E '^[+-].*retries on EADDRINUSE' && echo "FAIL: stale comment edited" || echo "stale comment unchanged (S2 scope)"
# Expected: stale comment unchanged (S2 scope).

# (No real Chrome, no daemon, no concurrency validation applies to this mock-based fix.
#  S2 will add the caller re-pick; S3 will update the concurrency test. This subtask is
#  the pool_chrome_launch detection + its selftest ONLY.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck -S warning lib/pool.sh` clean (zero warnings).
- [ ] `bash -n test/validate.sh` clean.
- [ ] `shellcheck -S warning test/validate.sh` clean.
- [ ] Level 2 snippet 2a passes (EADDRINUSE mock → return 1, warning logged).
- [ ] Level 2 snippet 2b passes (`bash test/validate.sh` exits 0, new body PASS).
- [ ] Level 2 snippet 2c passes (non-EADDRINUSE mock → pool_die, genuine misconfig preserved).
- [ ] Level 2 snippet 2d passes (success path unchanged — return 0 with globals set).
- [ ] Level 4 snippet 4a passes (grep selectivity — 3 MATCH, 3 NO MATCH).
- [ ] Level 4 snippet 4b passes (mock triggers instant-exit + grep + return 1 end-to-end).

### Feature Validation

- [ ] `pool_chrome_launch` instant-exit block greps the log for the EADDRINUSE pattern
      (verbatim from the contract) BEFORE the existing `pool_die`.
- [ ] On an EADDRINUSE match: `_pool_log` warning + `return 1` (NOT `pool_die`).
- [ ] On no match: the existing `pool_die` fires (genuine misconfig preserved).
- [ ] The `kill "$POOL_CHROME_PID" 2>/dev/null || true` reap is preserved (before both paths).
- [ ] The success path (pgid captured) is UNCHANGED — `POOL_CHROME_PGID` set, `_pool_log`, `return 0`.
- [ ] The docstring `# Returns` line, `# CONSUMER:` block, and "Highest-impact gotcha" GOTCHA
      all document the new return-1-on-EADDRINUSE behavior + the grep pattern + the caller's
      set -e guard obligation + the COMMON-vs-instant-exit nuance.
- [ ] The selftest `selftest_chrome_launch_eaddrinuse` passes (positive: EADDRINUSE → rc 1 +
      log matches; negative: non-EADDRINUSE → rc!=0 + log does NOT match).
- [ ] The selftest runs `pool_chrome_launch` in a subshell (`bash -c '...' || rc=$?`) so a
      `pool_die` cannot kill the harness.
- [ ] The selftest uses an isolated subdir of `$ABPOOL_TEST_ROOT` (does NOT pollute shared state).

### Code Quality Validation

- [ ] The ONLY lib/pool.sh code change is the grep+return-1 block inside the `if [[ -z "$pgid" ]]`
      (the kill reap is preserved/reordered, the pool_die is preserved as the fallthrough).
- [ ] The docstring's 3 targeted lines updated; the other GOTCHA blocks (setsid, log dir,
      POOL_CHROME_BIN, no-bare-~, naming) UNCHANGED.
- [ ] Test body named `selftest_chrome_launch_eaddrinuse` (single-setup runner — NOT `test_*`).
- [ ] Test body mock-based (no real Chrome, no sim-owner — AGENTS.md §1 compliant).
- [ ] Test body wrapped in `timeout 10` (AGENTS.md §2).
- [ ] Test body chains `assert_eq ... || return 1` (fail-fast explicit).
- [ ] No scope creep into S2 (caller re-pick, stale comment) or S3 (concurrency test) or
      P1.M3 (close-rebind) or Issues 1/3/4/5.
- [ ] `if grep` (errexit-exempt) — no bare `grep` outside an `if`/`||`.

### Documentation & Deployment

- [ ] Docstring `# Returns` line matches the new behavior (rc 0 / rc 1 / pool_die).
- [ ] Docstring `# CONSUMER:` block documents the caller's set -e guard obligation.
- [ ] Docstring "Highest-impact gotcha" GOTCHA documents the grep pattern + the
      COMMON-vs-instant-exit nuance (so a reader understands S1 is the defensive path, not
      the sole EADDRINUSE recovery).
- [ ] No README change needed (the EADDRINUSE recovery is internal; the README's port-range
      docs are unaffected). The P1.M4.T1 docs-sweep task will catch any README discrepancy.
- [ ] No new env vars; no config changes; no path changes.

---

## Anti-Patterns to Avoid

- ❌ Don't touch the success path (lines 1539-1545: `POOL_CHROME_PGID` + `_pool_log` +
  `return 0`) — the edit is ONLY inside the `if [[ -z "$pgid" ]]` instant-exit block.
- ❌ Don't touch the stale "retries on EADDRINUSE" comments (lines 1335, 1383) — that's
  S2's scope. S1 touches ONLY `pool_chrome_launch` + its docstring.
- ❌ Don't touch `_pool_launch_and_verify` (lines 2117-2161) — that's S2's scope (the caller
  re-pick). S1 only establishes the return-1 contract.
- ❌ Don't alter the grep pattern from the contract — use it VERBATIM
  (`'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind'`).
  The `EADDRINUSE` alternative is dead (Chrome uses `ERR_ADDRESS_IN_USE`) but harmless; the
  contract is explicit. Do NOT "improve" it.
- ❌ Don't use a bare `grep -qiE ... "$log_file"` outside an `if`/`||` — grep returns 1 on
  no-match and `set -e` would abort. Use `if grep ...; then return 1; fi` (errexit-exempt).
- ❌ Don't use `exit 1` in the EADDRINUSE branch — use `return 1` so the caller (S2) can
  catch it. `exit 1` would be uncatchable (same as `pool_die`).
- ❌ Don't call `pool_die` on the EADDRINUSE path — it is retryable, not fatal. Use `_pool_log`
  (warning) + `return 1`.
- ❌ Don't remove the `kill "$POOL_CHROME_PID" 2>/dev/null || true` reap — it must run before
  BOTH exit paths (return-1 AND pool_die) to reap the bare pid.
- ❌ Don't name the test body `test_chrome_launch_*` — that prefix is run by `abpool_run_suite`
  with per-test `setup()` (spawns a process), which HANGS on the 3rd call in a shared sandbox
  (AGENTS.md §4). Use `selftest_chrome_launch_eaddrinuse` (single-setup runner).
- ❌ Don't call `pool_chrome_launch` in the MAIN shell of the selftest — it may `pool_die`
  (exit 1) on the negative case and kill the harness. Run it in a subshell
  (`bash -c '...' || rc=$?`).
- ❌ Don't spawn real Chrome in the selftest — use a fake-chrome bash script (AGENTS.md §1).
  The mock triggers the exact instant-exit + grep path without a real browser.
- ❌ Don't pollute the shared `$POOL_STATE_DIR` — the selftest overrides
  `AGENT_BROWSER_POOL_STATE` to an isolated subdir of `$ABPOOL_TEST_ROOT`.
- ❌ Don't fix S2/S3/P1.M3/Issues 1/3/4/5 in this subtask — stay in scope: the
  `pool_chrome_launch` instant-exit EADDRINUSE detection + its docstring + one selftest.
- ❌ Don't over-claim S1's scope in the docstring — document the nuance that the COMMON
  EADDRINUSE case (Chrome stays up) is caught by `pool_wait_cdp`'s 30s timeout and recovered
  by S2; S1's grep is the defensive fast path for the instant-exit variant. A reader who
  thinks S1 alone fixes the race will be confused when S2 lands.
- ❌ Don't blanket-disable shellcheck rules — the grep+return block introduces no warnings;
  fix the code, not the linter.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The edit is small and surgical (one `if grep ...; then return 1; fi` block inside an
  existing `if [[ -z "$pgid" ]]` branch) and the contract is unusually precise (the exact
  grep pattern is given verbatim; the exact edit site is pinned with quoted current code).
- The two subtle points were **verified on the host this session**: (1) the grep pattern's
  selectivity (3 EADDRINUSE phrases MATCH, 4 non-EADDRINUSE phrases NO-MATCH — confirmed in
  Validation 4a); (2) the mock-chrome approach triggers the exact instant-exit + grep +
  return-1 path end-to-end (confirmed in Validation 4b — `pgid=[]`, `DETECTED: EADDRINUSE
  → return 1`, exit 1).
- The `set -euo pipefail` interaction (`grep` rc-1 on no-match) is called out with the exact
  correct idiom (`if grep ...` is errexit-exempt) and a dedicated Level-2 test.
- The Chrome EADDRINUSE behavior nuance (instant-exit vs CDP-timeout) is researched from
  Chromium source and documented in the docstring + Known Gotchas so the implementer
  understands S1 is the defensive path, not the sole recovery — preventing an over-claim
  that would confuse S2's implementer.
- The test framework's one quirk for this subtask (pool_die-capable function must be tested
  in a subshell) is called out with the exact `bash -c '...' || rc=$?` pattern, and the
  distinguishing assertion (rc==1 AND log-matches, since return-1 and pool_die both yield
  rc 1) is specified.
- The -1 reflects that the selftest's distinguishing assertion relies on the log containing
  the EADDRINUSE text (which the fake chrome writes) — a subtle point a careless implementer
  might miss, leading to a test that passes for the wrong reason (rc 1 from pool_die instead
  of return 1). The reference impl's dual assertion (rc==1 + grep-matches-log) pins this.
