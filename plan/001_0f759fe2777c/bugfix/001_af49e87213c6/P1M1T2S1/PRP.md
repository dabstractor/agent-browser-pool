# PRP — P1.M1.T2.S1: Update `pool_dispatch_classify` to return `meta` for no command token

> **Bugfix context**: This subtask fixes **Issue 4** from the validation report
> (`plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md`,
> §"ISSUE 4"). It is a **behavior + test** fix (Mode A — no separate docs task; bare-command
> passthrough matches upstream and contradicts no README statement). The repo is no longer
> greenfield; `lib/pool.sh` is 4424 LOC and fully implemented. This subtask runs **in
> parallel** with P1.M1.T1.S1 (Issue 1/5 — boolean normalization); the two touch
> disjoint code (`pool_dispatch_classify` vs `_pool_config_bool`), so there is no conflict.

---

## Goal

**Feature Goal**: Make `pool_dispatch_classify` return `"meta"` (passthrough) instead of
`"driving"` (boot Chrome) when the agent's argv contains **no non-flag command token** —
i.e. bare `agent-browser`, `agent-browser --json`, `agent-browser --session foo` (no
subcommand), `agent-browser -i`, or any combination of flags with no command. This mirrors
the existing `--help`/`-h`/`--version` short-circuit and prevents a no-op/help invocation
from silently acquiring a lane and booting a full Chrome (CoW copy + launch + CDP wait +
daemon connect) that then persists until the `pi` process exits.

**Deliverable**:
1. `lib/pool.sh` — the empty-command branch of `pool_dispatch_classify` (the
   `if [[ -z "$cmd" ]]; then printf 'driving\n'; return 0; fi` block at lines ~3092–3095)
   changed to emit `"meta"`. One `printf` token change.
2. `lib/pool.sh` — the function's docstring (the `# e. No command found ...` comment at
   line ~3044, and the `# No command token found ... → default 'driving' (contract step d).`
   inline comment at line ~3091) updated to reflect `meta` (not `driving`).
3. `test/validate.sh` — **add** a pure-function `selftest_dispatch_classify_*` block
   asserting the full classification table (META cases, DRIVING cases, and the
   no-command/flags-only cases that this fix flips to `meta`). There is currently **no**
   pure dispatch unit test in validate.sh (the contract's "existing test that expects
   'driving' for no-args" is the *conceptual* expectation baked into the 22-case
   transparency suite; the pure-function assertion is net-new and belongs in validate.sh's
   selftest block per the architecture's test-scope table).
4. No consumer-site changes: `pool_wrapper_main` step c (`lib/pool.sh:3500`) already
   `exec`s passthrough when `class == "meta"` — it benefits automatically.

**Success Definition**:
- `source lib/pool.sh; pool_dispatch_classify` (no args) prints `meta` (was `driving`).
- `pool_dispatch_classify --json` prints `meta` (was `driving`).
- `pool_dispatch_classify --session foo` (flag + value, no command) prints `meta` (was `driving`).
- `pool_dispatch_classify --headed --json` (multiple flags) prints `meta` (was `driving`).
- `pool_dispatch_classify -i` (short flag only) prints `meta` (was `driving`).
- Regression preserved: `pool_dispatch_classify open` → `driving`;
  `pool_dispatch_classify session list` → `meta`; `pool_dispatch_classify skills` → `meta`;
  `pool_dispatch_classify --help` → `meta`; `pool_dispatch_classify unknowncmd` → `driving`
  (unrecognized commands still default to `driving` — let the real binary handle the error).
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean (project gate).
- `bash test/validate.sh` exits 0 with the new `selftest_dispatch_classify_*` bodies passing.
- The `transparency.sh` suite (which exercises the real wrapper for `skills`/`--help`/`--version`
  passthrough) is unaffected — those cases were already `meta` and stay `meta`.

## User Persona

**Target User**: `pi` agents (the long-lived interactive process) and operators. A `pi`
agent that shells out `agent-browser` with no subcommand (e.g. probing the CLI, or a
malformed wrapper call) currently triggers a full Chrome boot for a help printout.

**Use Case**: A `pi` agent runs `agent-browser --json` (intending to get JSON help/version
output) or bare `agent-browser`. Upstream agent-browser treats a subcommand-less invocation
as a help/usage request (prints help, exits 0). The pool should passthrough to the real
binary unchanged — NOT acquire a lane, boot Chrome, and leave a lingering ephemeral profile.

**User Journey**: `pi` → `agent-browser` (no args) → `pool_wrapper_main` step c sees
`class == "meta"` → `exec "$POOL_REAL_BIN"` (unchanged) → real binary prints help → exits 0.
No lane acquired, no Chrome booted, no ephemeral dir created, no lease written.

**Pain Points Addressed**:
- **Wasted Chrome + ephemeral profile for a no-op** (Issue 4): a help request no longer
  boots a 4.8 GB CoW copy + Chrome process that persists until `pi` exits.
- **PRD §2.18 leak risk**: "the main interactive pi is long-lived → every test must
  release/reap." A bare invocation that boots Chrome and never releases it (because the
  real binary exits 0 immediately but the lease persists) is exactly the kind of
  un-reaped lane the PRD warns against.
- **PRD §2.15 transparency / no surprises**: a help request behaving like a driving
  command (silently acquiring a lane) is a surprise; passthrough is the unsurprising behavior.

## Why

- **Issue 4 (Minor)** from the validation report. The fix is **1 printf token + 2 comment
  lines + 1 test block** — minimal blast radius. The empty-cmd branch is the ONLY change;
  the META classification (`session list`, `skills`/`dashboard`/`plugin`/`mcp`) and the
  `--help`/`-h`/`--version` short-circuit are untouched, and the DRIVING default
  (unrecognized commands → `driving`) is untouched.
- **Mirrors an existing, correct pattern.** The function ALREADY short-circuits
  `--help`/`-h`/`--version` to `meta` at the top of the case statement (lib/pool.sh:3057).
  A subcommand-less invocation is the same class of "not a driving action" — treating it
  as `meta` is consistent, not a new concept.
- **The consumer is already wired.** `pool_wrapper_main` step c (lib/pool.sh:3500–3502)
  does `if [[ "$class" == "meta" ]]; then exec "$POOL_REAL_BIN" "$@"; fi` — so flipping
  the empty-cmd branch to `meta` automatically routes bare invocations to passthrough.
  Zero consumer changes.
- **Backward-compatible with the DRIVING default.** Unrecognized COMMANDS (e.g.
  `agent-browser mouse`, `agent-browser react`) still return `driving` (the
  "everything else → driving" fallthrough at lib/pool.sh:3108). Only the NO-COMMAND case
  changes. This preserves the contract step d ("default to driving — let the real binary
  handle the error") for actual commands while fixing the no-command case.
- **Foundation for the cutover (PRD §2.17).** During cutover, operators and `pi` agents
  probe the CLI frequently; each probe should not boot Chrome.

## What

User-visible behavior: a bare `agent-browser` (or flags-only invocation) now passes
through to the real binary unchanged (prints help, exits 0) instead of booting Chrome.
Observable contract:

### Behavior change (single branch)

`pool_dispatch_classify` currently (lib/pool.sh:3091–3095):
```bash
    # No command token found (only flags / empty $@) → default 'driving' (contract step d).
    if [[ -z "$cmd" ]]; then
        printf 'driving\n'
        return 0
    fi
```
becomes:
```bash
    # No command token found (only flags / empty $@) → 'meta' (passthrough). A
    # subcommand-less invocation is a help/usage request (upstream prints help + exits 0),
    # not a driving action — mirrors the --help/-h/--version short-circuit above (Issue 4).
    if [[ -z "$cmd" ]]; then
        printf 'meta\n'
        return 0
    fi
```

### Success Criteria

- [ ] `pool_dispatch_classify` (no args) prints `meta` and returns 0.
- [ ] `pool_dispatch_classify --json` prints `meta` and returns 0.
- [ ] `pool_dispatch_classify --session foo` (space form, value present, no command) prints `meta` and returns 0.
- [ ] `pool_dispatch_classify --session=foo` (equals form, no command) prints `meta` and returns 0.
- [ ] `pool_dispatch_classify --headed --json` (multiple flags) prints `meta` and returns 0.
- [ ] `pool_dispatch_classify -i` (short flag only) prints `meta` and returns 0.
- [ ] `pool_dispatch_classify ""` (a single empty-string arg) prints `meta` and returns 0. (An empty-string token is not a flag and not a real command — it falls through the loop with `cmd` still empty, same as no-args. Verified empirically: currently returns `driving`, will return `meta`.)
- [ ] **Regression — META preserved:** `--help` → `meta`; `-h` → `meta`; `--version` → `meta`; `session list` → `meta`; `skills` → `meta`; `dashboard` → `meta`; `plugin` → `meta`; `mcp` → `meta`.
- [ ] **Regression — DRIVING preserved:** `open` → `driving`; `click` → `driving`; `connect 53420` → `driving`; `close` → `driving`; `session` (bare, not `session list`) → `driving`; `unknowncmd` → `driving` (unrecognized commands still default to driving per contract step d).
- [ ] `pool_dispatch_classify --session foo open` (flag + value + command) → `driving` (the command `open` is found; flags before it are skipped). Regression.
- [ ] The function still returns 0 ALWAYS (no failure mode; the caller's `class="$(pool_dispatch_classify "$@")"` stays set -e-safe with no guard).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean.
- [ ] `bash test/validate.sh` exits 0 with the new `selftest_dispatch_classify_*` bodies PASS.
- [ ] The docstring `# e.` line and the inline comment above the `if [[ -z "$cmd" ]]` block both say `meta` (not `driving`).
- [ ] No consumer-site changes (`pool_wrapper_main` step c unchanged — verify with `git diff`).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP pins the exact line numbers, quotes the
current code at the single edit site, gives the verified replacement, specifies the test
framework's exact runner pattern (single-setup `selftest_*`, auto-discovered via `compgen`),
quotes `assert_eq`'s signature, and lists the precise validation commands (all verified
executable on this host this session). The implementer needs no prior exposure to
`lib/pool.sh` beyond reading the quoted snippet.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: ISSUE 4 — root cause (empty-cmd branch returns 'driving'), the exact suggested fix
        (change to 'meta', mirror the --help short-circuit), and the note that the existing
        test expecting 'driving' for no-args must be updated.
  pattern: 'ISSUE 4 "Fix Approach" gives the exact 3-line replacement (printf driving → meta).'
  gotcha: 'key_findings says "the existing test in validate.sh ... expects driving for
        no-args — update it." Empirically (verified this session): validate.sh has NO pure
        pool_dispatch_classify unit test today; the "22 dispatch cases" live conceptually in
        the transparency.sh suite (which exercises the real wrapper + Chrome). So this PRP
        ADDS a pure selftest_dispatch_classify_* block to validate.sh (the correct home for
        pure-function tests per the architecture test-scope table) rather than editing a
        non-existent assertion.'

- file: lib/pool.sh
  why: THE file being edited. Read lines 2998–3112 (the full pool_dispatch_classify:
        docstring + the flag-scan loop + the empty-cmd branch + the META case + the
        driving default) and lines 3496–3503 (pool_wrapper_main step c, the meta passthrough).
  pattern: 'Existing style — docstring above the function with lettered steps a–e; printf
        for output; `local tok cmd next` for set -u safety; the `--help|-h|--version`
        short-circuit at the TOP of the case (lib/pool.sh:3056–3059) is the pattern to mirror.'
  gotcha: 'The empty-cmd branch is at lib/pool.sh:3091–3095 (the `if [[ -z "$cmd" ]]` AFTER
        the while loop). Do NOT touch the META case (lib/pool.sh:3098–3107: session list +
        skills/dashboard/plugin/mcp) or the driving default (lib/pool.sh:3108–3110). Do NOT
        touch the --help/-h/--version short-circuit (lib/pool.sh:3056–3059) — it already
        returns meta and is the model for this fix. Do NOT touch pool_wrapper_main step c
        (lib/pool.sh:3500–3502) — it already execs passthrough on meta.'

- file: test/validate.sh
  why: 'The pure-function test framework. ADD selftest_dispatch_classify_* bodies following
        the existing selftest_* pattern (pure functions, no Chrome). The single-setup
        _run_selftest_suite (validate.sh:335) auto-discovers any selftest_* function via
        `compgen -A function | grep "^selftest_" | sort`.'
  pattern: 'Bodies are plain functions calling `assert_eq EXPECTED ACTUAL LABEL`; bodies run
        in the MAIN shell via `if "$fn"` (NOT a subshell) — a failed assert returns 1 →
        recorded FAIL → suite continues. See selftest_assert_eq_passes (validate.sh:264) and
        the P1.M1.T1.S1 selftest_config_bool_* block (validate.sh:325+, landing in parallel).'
  gotcha: 'Do NOT use `run_test`/`abpool_run_suite` for these — that path calls setup()
        per test (spawns a sim-owner process) and AGENTS.md §4 forbids >1 process-spawning
        setup() call in a shared sandbox (the 3rd call hangs). The selftest_* prefix is
        auto-picked by the SINGLE-SETUP _run_selftest_suite (one setup() for ALL selftest
        bodies). See validate.sh lines 320–360. ALSO: pool_dispatch_classify is a PURE
        function (reads NO globals, writes NO files) — so the selftest bodies do NOT need
        setup() state at all (they call pool_dispatch_classify directly); they just inherit
        the single setup() the runner already pays for.'

- file: PRD.md
  why: '§2.4 (request lifecycle step 0 — dispatch), §2.15 (transparency / no surprises),
        §2.18 (pi is long-lived → every test must release/reap). The bug is a §2.15/§2.18
        violation: a no-op invocation booting Chrome and leaving a lingering lane.'
  pattern: '§2.4 step 0 is the dispatch contract; the META set (passthrough) vs DRIVING set
        (route to lane) is the classification this function performs.'
  gotcha: 'PRD §2.4 does NOT enumerate "no command" as a case — the original implementer
        defaulted it to driving. Issue 4 corrects this to meta (passthrough), which is the
        behavior upstream agent-browser exhibits (no args → help → exit 0).'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/external_deps.md
  why: '§1.1 (DRIVING command set) and §1.2 (META/passthrough command set). The fix moves
        the no-command case from the implicit-DRIVING bucket to the META bucket.'
  pattern: '§1.2 lists --help/-h/--version and skills/dashboard/plugin/mcp and session list
        as META. A subcommand-less invocation joins this set (it is a help request).'
  gotcha: '§1.1 DRIVING set is NOT enumerated in pool_dispatch_classify code (the function
        detects META + defaults the rest to driving, per the docstring contract steps c&d).
        This fix does NOT change that — unrecognized COMMANDS still default to driving.
        Only the NO-COMMAND case (empty cmd after the flag scan) changes.'

# External authoritative docs (for the HOW — minimal; this is a 1-token change)
- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: 'the `if [[ -z "$cmd" ]]` test (empty-string check). Unchanged by this fix — only
        the printf argument inside the branch changes.'
  critical: 'no new bash feature is introduced; the fix is a literal string substitution
        inside an existing branch.'

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: 'double-quote expansions. The existing `printf '"'"'driving\n'"'"'` has no expansions
        (a literal string); the replacement `printf '"'"'meta\n'"'"'` is equally clean.
        Universal rule, unchanged.'
  critical: 'no shellcheck concern is introduced or removed by this 1-token change.'

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T1S1/PRP.md
  why: 'P1.M1.T1.S1 (Issue 1/5 — boolean normalization) runs IN PARALLEL. It edits
        _pool_config_bool (lib/pool.sh:79–84), pool_config_init comment (line 171),
        pool_admin_help (lines 4418–4420), README env table (lines 218–220), and ADDS
        selftest_config_bool_* bodies to validate.sh (lines ~325+). THIS subtask edits
        pool_dispatch_classify (lib/pool.sh:3091–3095) + its docstring and ADDS
        selftest_dispatch_classify_* bodies to validate.sh. The two touch DISJOINT code
        (dispatch vs config_bool) and DISJOINT test bodies (dispatch_* vs config_bool_*)
        → no merge conflict.'
  pattern: 'P1.M1.T1.S1 established the selftest_* single-setup pattern + the
        selftest_config_bool_truthy/falsy/via_pool_config_init bodies. THIS subtask follows
        the SAME pattern (selftest_* prefix, assert_eq, MAIN-shell, pure-function).'
  gotcha: 'Both subtasks APPEND selftest bodies to validate.sh. To avoid a textual merge
        conflict, place the new selftest_dispatch_classify_* block IMMEDIATELY AFTER the
        selftest_config_bool_* block (which P1.M1.T1.S1 adds around line 325–360) and
        BEFORE the `# --- source-vs-execute gate` / `_run_selftest_suite` definition. If
        P1.M1.T1.S1 has NOT landed yet, place the dispatch block after the last existing
        selftest_* function (selftest_wrapper_and_admin_are_executable, validate.sh:311)
        and before the _run_selftest_suite definition. Either way: after all selftest_*
        bodies, before _run_selftest_suite. The _run_selftest_suite auto-discovers ALL
        selftest_* functions via compgen, so order does not affect discovery — only textual
        merge cleanliness.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/TEST_RESULTS.md
  why: 'the validation report that identified Issue 4. Confirms the bug was found by an
        isolated micro-check (`pool_dispatch_classify` with no args returns "driving") and
        that the fix is a pure-function change (no Chrome needed to validate).'
  pattern: 'TEST_RESULTS §"Minor Issues" Issue 4 — the Steps to Reproduce (source lib/pool.sh;
        pool_dispatch_classify / pool_dispatch_classify --json) are the exact assertions the
        new selftest encodes.'
  gotcha: 'TEST_RESULTS also lists Issues 1/2/3/5 — those are OUT OF SCOPE for this subtask
        (P1.M1.T1.S1 does 1/5; P1.M2 does 2; P1.M3 does 3). Stay in scope: Issue 4 only.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                   # 4424 LOC — pool_dispatch_classify at 3046-3112 (edit 3091-3095 + docstring 3044)
│                                 #   pool_wrapper_main step c at 3496-3503 (CONSUMER — do NOT edit)
├── test/
│   └── validate.sh               # 366 LOC — selftest_* pattern; ADD selftest_dispatch_classify_* block
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/key_findings.md   # ISSUE 4 root cause + fix approach
    ├── TEST_RESULTS.md                # the validation report (Issue 4 confirmed)
    ├── P1M1T1S1/PRP.md                # parallel subtask (Issue 1/5 — disjoint code)
    └── P1M1T2S1/                      # THIS subtask
        └── PRP.md                     # THIS FILE
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh       — pool_dispatch_classify empty-cmd branch (printf driving → meta) + docstring step e + inline comment
#   test/validate.sh  — ADD selftest_dispatch_classify_cases body (pure-function, ~25 lines)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: the empty-cmd branch is the ONLY code change. It is at lib/pool.sh:3091–3095
# (the `if [[ -z "$cmd" ]]; then printf 'driving\n'; return 0; fi` AFTER the while loop).
# Do NOT touch:
#   - the --help|-h|--version short-circuit (lib/pool.sh:3056–3059) — already meta, the model.
#   - the META case (lib/pool.sh:3098–3107: session list + skills/dashboard/plugin/mcp).
#   - the driving default fallthrough (lib/pool.sh:3108–3110) — unrecognized COMMANDS stay driving.
#   - pool_wrapper_main step c (lib/pool.sh:3500–3502) — already execs passthrough on meta.
# Verify with git diff: the ONLY lib/pool.sh change is the printf token + 2 comment lines.

# CRITICAL (empirically verified this session): the no-command cases that currently return
# 'driving' (and must become 'meta') are ALL caught by the `if [[ -z "$cmd" ]]` branch:
#   no args, --json, --session foo (no cmd), --session=foo (no cmd), --headed --json,
#   -i (short flag), and a single "" (empty-string) arg. Confirmed by running each through
#   pool_dispatch_classify. The fix flips ALL of them in one stroke (they all leave cmd="").

# GOTCHA (the "" empty-string-arg case): `pool_dispatch_classify ""` — a single empty-string
# argument. The empty string is not a flag (does not match --* or -*), so it hits the `*)`
# branch and sets `cmd=""` (empty), then breaks. So `cmd` is empty → the `if [[ -z "$cmd" ]]`
# branch fires. Currently returns 'driving'; after the fix returns 'meta'. This is correct:
# an empty-string token is not a real command. (Verified empirically.)

# GOTCHA (set -e + the function contract): pool_dispatch_classify returns 0 ALWAYS. The
# caller `class="$(pool_dispatch_classify "$@")"` (lib/pool.sh:3499) has NO `if` guard and
# relies on rc 0. The fix preserves this — `printf 'meta\n'; return 0` is rc 0. Do NOT add
# any path that returns non-zero.

# GOTCHA (the test framework's selftest runner is SINGLE-SETUP): validate.sh:335
# _run_selftest_suite calls setup() ONCE for all selftest_* bodies. setup() spawns a REAL
# sim-owner process; calling it >once in a shared sandbox HANGS on the 3rd call (AGENTS.md §4).
# So the new test body MUST be named `selftest_*` (auto-discovered by the single-setup runner),
# NOT `test_*` (which abpool_run_suite would run with per-test setup). The body must be
# PURE-FUNCTION (no Chrome). pool_dispatch_classify is pure (reads no globals, writes no
# files), so the body just calls it directly — it does NOT use setup()'s state, but it
# inherits the single setup() the runner already pays for (harmless).

# GOTCHA (assert_eq in MAIN shell): assert_eq runs in the MAIN shell in selftest (not a
# subshell). A failing assert returns 1 → the body's `return 1` propagates → recorded FAIL →
# suite continues. So a body can chain multiple assert_eq calls; the FIRST failure ends that
# body (later asserts in the same body won't run). Chain with `|| return 1` to make fail-fast
# explicit (matches the P1.M1.T1.S1 selftest_config_bool_* idiom).

# GOTCHA (parallel-merge cleanliness): P1.M1.T1.S1 (in parallel) ADDS selftest_config_bool_*
# bodies to validate.sh around line 325–360. THIS subtask ADDS selftest_dispatch_classify_*
# bodies. Place the dispatch block AFTER the config_bool block (if landed) or after
# selftest_wrapper_and_admin_are_executable (line 311) if not — either way, before
# _run_selftest_suite (line 335). The compgen-based discovery is order-independent, so
# placement only affects textual merge cleanliness, not behavior.

# GOTCHA (scope): this fix is ISSUE 4 ONLY. Do NOT fix Issue 1/5 (boolean — P1.M1.T1.S1),
# Issue 2 (port race — P1.M2), or Issue 3 (close-rebind — P1.M3). Do NOT change the DRIVING
# default for unrecognized commands. Do NOT add new META commands. Do NOT touch the
# --session stripping (M6.T2.S1) or the close --all interception (M6.T1.S2). One branch, one
# token, plus its comments and a test.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. The only "structure" is the `pool_dispatch_classify`
signature, which is unchanged: `pool_dispatch_classify [--] ARGS...` → echoes exactly one
token (`meta`|`driving`), returns 0 always.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current function and confirm the edit site
  - RUN: sed -n '3046,3112p' lib/pool.sh   # (or read lib/pool.sh offset 3046 limit 67)
  - EXPECT: the pool_dispatch_classify function with:
      - docstring step e (~line 3044): "# e. No command found (only flags / empty $@) → 'driving' (default, step d)."
      - the while-loop flag scan (3051–3089)
      - the empty-cmd branch (~3091–3095): "if [[ -z \"$cmd\" ]]; then printf 'driving\\n'; return 0; fi"
      - the META case (~3098–3107) and the driving default (~3108–3110)
  - RUN (empirical baseline — confirm the bug BEFORE fixing):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 echo "no-args=[$(pool_dispatch_classify)]"; \
                 echo "--json=[$(pool_dispatch_classify --json)]"; \
                 echo "open=[$(pool_dispatch_classify open)]"'
    - EXPECT (BEFORE fix): no-args=[driving], --json=[driving], open=[driving].
      (After fix: no-args=[meta], --json=[meta], open=[driving].)
  - NOTE: do NOT touch the --help/-h/--version short-circuit, the META case, or the driving
        default. The ONLY code change is the printf token in the empty-cmd branch.

Task 1: EDIT lib/pool.sh — change the empty-cmd branch from 'driving' to 'meta' (lines ~3091–3095)
  - FIND (the exact current block — verify with the read in Task 0):
        # No command token found (only flags / empty $@) → default 'driving' (contract step d).
        if [[ -z "$cmd" ]]; then
            printf 'driving\n'
            return 0
        fi
  - REPLACE WITH:
        # No command token found (only flags / empty $@) → 'meta' (passthrough). A
        # subcommand-less invocation is a help/usage request (upstream prints help + exits 0),
        # not a driving action — mirrors the --help/-h/--version short-circuit above (Issue 4).
        if [[ -z "$cmd" ]]; then
            printf 'meta\n'
            return 0
        fi
  - WHY: a no-command invocation is not a driving action; passthrough is the correct
        behavior (upstream agent-browser with no args prints help and exits 0). This mirrors
        the --help short-circuit at the top of the case (lib/pool.sh:3056–3059).
  - PRESERVE: the `if [[ -z "$cmd" ]]` test, the `return 0`, and the rc-0-always contract.
  - GOTCHA: only the printf argument changes ('driving' → 'meta'). The `\n` is preserved
        (the caller does `class="$(...)"` which strips the trailing newline via command
        substitution, so 'meta\n' → class=="meta"). Do NOT remove the `\n`.

Task 2: EDIT lib/pool.sh — update the docstring step e (line ~3044)
  - FIND: "#   e. No command found (only flags / empty $@) → 'driving' (default, step d)."
  - REPLACE WITH: "#   e. No command found (only flags / empty $@) → 'meta' (passthrough — a help/usage request, like --help; Issue 4)."
  - WHY: the docstring is now factually wrong after Task 1; keep code+comments in lockstep.
  - GOTCHA: the docstring's contract steps a–d are UNCHANGED. Only step e changes. Do NOT
        edit steps a (flag scan), b (META classification), c (everything else → driving), or
        d (unrecognized → driving). Step c and d STILL yield 'driving' for actual commands —
        only the no-command case (step e) changes.

Task 3: ADD test/validate.sh — selftest_dispatch_classify_cases body
  - ADD a new function named `selftest_dispatch_classify_cases` (the _run_selftest_suite at
        validate.sh:335 auto-discovers any `selftest_*` function — NO registration needed).
  - PLACE: AFTER the last selftest_* body and BEFORE the `_run_selftest_suite` definition
        (validate.sh:335). If P1.M1.T1.S1's selftest_config_bool_* block has landed (~line
        325–360), place this block immediately AFTER it; otherwise place it after
        selftest_wrapper_and_admin_are_executable (validate.sh:311). Either way: before
        _run_selftest_suite. (compgen discovery is order-independent; placement is for
        textual merge cleanliness with the parallel P1.M1.T1.S1 PRP.)
  - FOLLOW pattern: selftest_assert_eq_passes (validate.sh:264) + the P1.M1.T1.S1
        selftest_config_bool_truthy idiom — plain function, calls assert_eq EXPECTED ACTUAL
        LABEL, chains with `|| return 1`. Runs in MAIN shell (not subshell) under the
        single-setup runner. Pure-function (no Chrome, no sim-owner, no lease writes).
  - NAMING: selftest_dispatch_classify_cases.
  - REFERENCE IMPLEMENTATION (verified: pool_dispatch_classify is pure, reads no globals,
        so the body needs no setup state — it just calls the function directly):
      ----------------------------------------------------------------
      # pool_dispatch_classify: full classification table (Issue 4 — no-command → meta).
      # Pure-function: pool_dispatch_classify reads NO globals, writes NO files. No Chrome.
      # Picked up by the single-setup _run_selftest_suite (same runner as the other selftest_*).
      selftest_dispatch_classify_cases() {
          local r
          # --- META: help/version short-circuit (unchanged, regression guard) ---
          for a in "--help" "-h" "--version"; do
              r="$(pool_dispatch_classify "$a")"
              assert_eq "meta" "$r" "meta [$a] -> meta" || return 1
          done
          # --- META: two-word + single-word META commands (unchanged, regression guard) ---
          r="$(pool_dispatch_classify session list)"; assert_eq "meta" "$r" "session list -> meta" || return 1
          for a in skills dashboard plugin mcp; do
              r="$(pool_dispatch_classify "$a")"; assert_eq "meta" "$r" "meta [$a] -> meta" || return 1
          done
          # --- META (Issue 4 fix): no command token / flags-only / empty $@ ---
          r="$(pool_dispatch_classify)";                   assert_eq "meta" "$r" "no-args -> meta" || return 1
          r="$(pool_dispatch_classify --json)";            assert_eq "meta" "$r" "--json (no cmd) -> meta" || return 1
          r="$(pool_dispatch_classify --session foo)";     assert_eq "meta" "$r" "--session foo (no cmd) -> meta" || return 1
          r="$(pool_dispatch_classify --session=foo)";     assert_eq "meta" "$r" "--session=foo (no cmd) -> meta" || return 1
          r="$(pool_dispatch_classify --headed --json)";   assert_eq "meta" "$r" "--headed --json (no cmd) -> meta" || return 1
          r="$(pool_dispatch_classify -i)";                assert_eq "meta" "$r" "-i (no cmd) -> meta" || return 1
          r="$(pool_dispatch_classify "")";                assert_eq "meta" "$r" "empty-string arg -> meta" || return 1
          # --- DRIVING: actual commands (unchanged, regression guard) ---
          for a in open click connect close session back get find; do
              r="$(pool_dispatch_classify "$a")"; assert_eq "driving" "$r" "driving [$a] -> driving" || return 1
          done
          # --- DRIVING: unrecognized command defaults to driving (contract step d, unchanged) ---
          r="$(pool_dispatch_classify unknowncmd)"; assert_eq "driving" "$r" "unknowncmd -> driving (default)" || return 1
          # --- DRIVING: flags before a command are skipped, command is found ---
          r="$(pool_dispatch_classify --session foo open)"; assert_eq "driving" "$r" "--session foo open -> driving" || return 1
          r="$(pool_dispatch_classify --json click)";       assert_eq "driving" "$r" "--json click -> driving" || return 1
      }
      ----------------------------------------------------------------
  - WHY so many cases: this is the FIRST pure dispatch unit test (the "22 dispatch cases"
        the contract mentions live in the Chrome-exercising transparency.sh suite, not as
        pure assertions). Encoding the full table here makes the Issue 4 fix + the existing
        META/DRIVING contract a fast, Chrome-free regression gate.
  - GOTCHA: the `|| return 1` after each assert_eq makes fail-fast explicit (a failed assert
        returns 1 → the body ends → recorded FAIL → suite continues). This matches the
        P1.M1.T1.S1 selftest_config_bool_truthy idiom.
  - GOTCHA: do NOT spawn Chrome or a sim-owner — this is a pure-function test. The single
        setup() call by _run_selftest_suite provides a temp HOME + state dir, but this body
        does not USE setup's state (it calls pool_dispatch_classify directly). That is fine
        and matches selftest_assert_eq_passes (which also ignores setup's state).
  - GOTCHA: pool_dispatch_classify is pure and reads NO globals, so it does NOT need
        pool_config_init to have run. But the single setup() (validate.sh:184) DOES call
        pool_config_init (via the sourced lib + the setup flow), so POOL_* globals exist —
        harmless. The body works regardless.

Task 4: VERIFY — run the full validation gauntlet BEFORE claiming done
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -S warning lib/pool.sh
      bash -n test/validate.sh
      shellcheck -S warning test/validate.sh
      bash test/validate.sh                 # must exit 0, incl. the new selftest_dispatch_classify_cases
  - RUN (the Issue 4 fix in isolation — the motivating bug, one-liner):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 [ "$(pool_dispatch_classify)" = "meta" ] || { echo "FAIL no-args"; exit 1; }; \
                 [ "$(pool_dispatch_classify --json)" = "meta" ] || { echo "FAIL --json"; exit 1; }; \
                 [ "$(pool_dispatch_classify --session foo)" = "meta" ] || { echo "FAIL --session foo"; exit 1; }; \
                 echo OK'
        # Expected: OK   (was: each printed 'driving' → would have failed before the fix)
  - RUN (regression — DRIVING/META preserved):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 [ "$(pool_dispatch_classify open)" = "driving" ] || { echo "FAIL open"; exit 1; }; \
                 [ "$(pool_dispatch_classify --help)" = "meta" ] || { echo "FAIL --help"; exit 1; }; \
                 [ "$(pool_dispatch_classify session list)" = "meta" ] || { echo "FAIL session list"; exit 1; }; \
                 [ "$(pool_dispatch_classify skills)" = "meta" ] || { echo "FAIL skills"; exit 1; }; \
                 [ "$(pool_dispatch_classify unknowncmd)" = "driving" ] || { echo "FAIL unknowncmd"; exit 1; }; \
                 echo OK'
        # Expected: OK
  - RUN (consumer unchanged — git diff shows ONLY the printf token + 2 comments + the test block):
        git diff -- lib/pool.sh | grep -E '^[+-]' | grep -vE '^[+-]{3}|^[-+]#|printf .(driving|meta).\\n' \
          | grep -E 'pool_dispatch_classify|pool_wrapper_main|== "meta"|class=' \
          && echo "FAIL: unexpected consumer change" || echo "consumers unchanged"
        # Expected: "consumers unchanged" (the ONLY lib/pool.sh diff lines are the printf
        #           token swap, the 2 comment lines, and the docstring step-e line).
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — the single code change (one printf token, inside an existing branch):
# BEFORE (lib/pool.sh:3091-3095):
#     # No command token found (only flags / empty $@) → default 'driving' (contract step d).
#     if [[ -z "$cmd" ]]; then
#         printf 'driving\n'
#         return 0
#     fi
# AFTER:
#     # No command token found (only flags / empty $@) → 'meta' (passthrough). A
#     # subcommand-less invocation is a help/usage request (upstream prints help + exits 0),
#     # not a driving action — mirrors the --help/-h/--version short-circuit above (Issue 4).
#     if [[ -z "$cmd" ]]; then
#         printf 'meta\n'
#         return 0
#     fi
# WHY this is safe: the consumer (pool_wrapper_main step c, lib/pool.sh:3500) already does
# `if [[ "$class" == "meta" ]]; then exec "$POOL_REAL_BIN" "$@"; fi` — so 'meta' routes to
# passthrough automatically. No consumer change.

# Pattern B — the model this mirrors (the --help short-circuit, lib/pool.sh:3056-3059):
#         --help|-h|--version)
#             printf 'meta\n'
#             return 0
#             ;;
# A subcommand-less invocation is the same class of "not a driving action" as --help.

# Pattern C — test body under the single-setup selftest runner (MAIN shell, fail-fast):
selftest_dispatch_classify_cases() {
    local r
    r="$(pool_dispatch_classify)"; assert_eq "meta" "$r" "no-args -> meta" || return 1
    r="$(pool_dispatch_classify --json)"; assert_eq "meta" "$r" "--json -> meta" || return 1
    r="$(pool_dispatch_classify open)"; assert_eq "driving" "$r" "open -> driving" || return 1
    # ... (full table in Task 3)
}
# The || return 1 makes fail-fast explicit; the selftest_* prefix auto-registers with
# _run_selftest_suite (validate.sh:335). Do NOT use test_* prefix (per-test setup hangs).

# Pattern D — rc-0-always preserved: pool_dispatch_classify returns 0 in ALL branches.
# The caller `class="$(pool_dispatch_classify "$@")"` (lib/pool.sh:3499) has NO `if` guard.
# The fix preserves `printf 'meta\n'; return 0` → rc 0. Do NOT add any non-zero path.
```

### Integration Points

```yaml
CODE (2 in-place edits, 1 addition — no new files):
  - lib/pool.sh:3091-3095   pool_dispatch_classify empty-cmd branch: printf 'driving' → 'meta' + comment
  - lib/pool.sh:~3044       pool_dispatch_classify docstring step e: 'driving' → 'meta' (lockstep)
  - test/validate.sh:+1     1 new selftest_dispatch_classify_cases body (ADD, ~30 lines)

CONSUMER (DO NOT TOUCH — already correct):
  - lib/pool.sh:3499-3502   pool_wrapper_main step c: `if [[ "$class" == "meta" ]]; then exec "$POOL_REAL_BIN" "$@"; fi`
                            Already execs passthrough on meta → benefits automatically from the fix.

PARALLEL SUBTASK (P1.M1.T1.S1 — disjoint, no conflict):
  - edits _pool_config_bool (lib/pool.sh:79-84), pool_config_init comment (171),
    pool_admin_help (4418-4420), README (218-220), adds selftest_config_bool_* (validate.sh ~325+).
  - THIS subtask edits pool_dispatch_classify (3091-3095) + docstring (3044), adds
    selftest_dispatch_classify_* (validate.sh). Disjoint code + disjoint test bodies.

CONFIG: none. No env vars. No defaults. No paths.
ROUTES: none.
DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                 # parse check. MUST be clean (no output).
shellcheck -S warning lib/pool.sh   # MUST report zero issues (matches the project's existing gate).
bash -n test/validate.sh            # parse check the test file after adding the body.
shellcheck -S warning test/validate.sh   # MUST be clean.
# Expected: zero output from all four.
# NOTE: the project uses `shellcheck -S warning` (the validation report confirmed this is the
#       project's gate; ShellCheck 0.11.0 verified on host). Do not use a stricter -S info/style
#       threshold — the existing codebase was validated at -S warning and may have style-level
#       annotations by design.
```

### Level 2: Unit Tests (Component Validation)

```bash
# 2a. The Issue 4 fix in isolation (the motivating bug — one-liner):
bash -c 'set -euo pipefail; source lib/pool.sh; \
  [ "$(pool_dispatch_classify)" = "meta" ]               || { echo "FAIL no-args"; exit 1; }; \
  [ "$(pool_dispatch_classify --json)" = "meta" ]        || { echo "FAIL --json"; exit 1; }; \
  [ "$(pool_dispatch_classify --session foo)" = "meta" ] || { echo "FAIL --session foo"; exit 1; }; \
  [ "$(pool_dispatch_classify --session=foo)" = "meta" ] || { echo "FAIL --session=foo"; exit 1; }; \
  [ "$(pool_dispatch_classify --headed --json)" = "meta" ] || { echo "FAIL --headed --json"; exit 1; }; \
  [ "$(pool_dispatch_classify -i)" = "meta" ]            || { echo "FAIL -i"; exit 1; }; \
  [ "$(pool_dispatch_classify "")" = "meta" ]            || { echo "FAIL empty-string"; exit 1; }; \
  echo "ISSUE 4 FIX OK"'
# Expected: ISSUE 4 FIX OK   (each was 'driving' before the fix)

# 2b. The test framework self-test suite (now includes the new dispatch body):
bash test/validate.sh
# Expected: prints "== selftest_dispatch_classify_cases / PASS" and a final
#           "N passed, 0 failed" line; exits 0.
# If ANY selftest fails, the suite exits non-zero — debug root cause, do not proceed.

# 2c. Regression — META preserved (help/version/session-list/skills-family):
bash -c 'set -euo pipefail; source lib/pool.sh; \
  [ "$(pool_dispatch_classify --help)" = "meta" ]    || { echo "FAIL --help"; exit 1; }; \
  [ "$(pool_dispatch_classify -h)" = "meta" ]        || { echo "FAIL -h"; exit 1; }; \
  [ "$(pool_dispatch_classify --version)" = "meta" ] || { echo "FAIL --version"; exit 1; }; \
  [ "$(pool_dispatch_classify session list)" = "meta" ] || { echo "FAIL session list"; exit 1; }; \
  for a in skills dashboard plugin mcp; do \
    [ "$(pool_dispatch_classify "$a")" = "meta" ] || { echo "FAIL $a"; exit 1; }; \
  done; \
  echo "META REGRESSION OK"'
# Expected: META REGRESSION OK

# 2d. Regression — DRIVING preserved (real commands + unrecognized default + flags-before-cmd):
bash -c 'set -euo pipefail; source lib/pool.sh; \
  for a in open click connect close session back get find; do \
    [ "$(pool_dispatch_classify "$a")" = "driving" ] || { echo "FAIL $a"; exit 1; }; \
  done; \
  [ "$(pool_dispatch_classify unknowncmd)" = "driving" ] || { echo "FAIL unknowncmd"; exit 1; }; \
  [ "$(pool_dispatch_classify --session foo open)" = "driving" ] || { echo "FAIL --session foo open"; exit 1; }; \
  [ "$(pool_dispatch_classify --json click)" = "driving" ] || { echo "FAIL --json click"; exit 1; }; \
  echo "DRIVING REGRESSION OK"'
# Expected: DRIVING REGRESSION OK
# NOTE: 'session' (bare, NOT 'session list') → 'driving' (bare session is a DRIVING command
#       per the docstring: "two-word command; bare 'session' is DRIVING").
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Verify the consumer (pool_wrapper_main step c) is BYTE-UNCHANGED:
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'pool_wrapper_main|class=|== "meta"|exec "\$POOL_REAL_BIN"'
# Expected: NO output (the consumer is untouched). If you see a consumer-site diff, STOP —
#           you over-edited; revert that hunk. The ONLY lib/pool.sh diff lines should be:
#           the printf token swap, the inline comment, and the docstring step-e line.

# 3b. Verify the full lib/pool.sh diff is minimal (only the 3 targeted lines move):
git diff --stat -- lib/pool.sh
# Expected: 1 file changed, ~3-5 insertions, ~3-5 deletions (the printf token + 2 comments).
git diff -- lib/pool.sh
# Expected: ONLY these hunks:
#   - the docstring "# e. ..." line (driving → meta)
#   - the inline comment "# No command token found ..." (driving → meta, expanded wording)
#   - the printf 'driving\n' → printf 'meta\n' line

# 3c. Verify the test body was added (and named selftest_*):
grep -n 'selftest_dispatch_classify_cases' test/validate.sh
# Expected: the function definition line + (optionally) the PASS line from a validate.sh run.

# 3d. Full repo smoke (no Chrome launched — pure sourcing + classify):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         pool_dispatch_classify >/dev/null; pool_dispatch_classify open >/dev/null; echo SOURCED_OK'
# Expected: SOURCED_OK
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The motivating scenario (Issue 4 from TEST_RESULTS.md): a bare invocation should NOT
#     boot Chrome. Since pool_dispatch_classify is pure, we verify the CLASSIFICATION (the
#     gate that decides boot-vs-passthrough). Under a real pi owner, class==meta → step c
#     execs passthrough → no lane acquired, no Chrome booted.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         class="$(pool_dispatch_classify)"; \
         if [[ "$class" == "meta" ]]; then \
           echo "bare invocation → meta (passthrough) — no Chrome boot (CORRECT)"; \
         else \
           echo "bare invocation → $class (would boot Chrome — BUG NOT FIXED)"; exit 1; \
         fi'
# Expected: bare invocation → meta (passthrough) — no Chrome boot (CORRECT)

# 4b. The flags-only scenario (--json — a common probe):
bash -c 'set -euo pipefail; source lib/pool.sh; \
         class="$(pool_dispatch_classify --json)"; \
         [[ "$class" == "meta" ]] && echo "--json → meta (passthrough — CORRECT)" || { echo "FAIL"; exit 1; }'
# Expected: --json → meta (passthrough — CORRECT)

# 4c. The --session-foo-no-command edge case (mentioned in key_findings Issue 4):
bash -c 'set -euo pipefail; source lib/pool.sh; \
         class="$(pool_dispatch_classify --session foo)"; \
         [[ "$class" == "meta" ]] && echo "--session foo (no cmd) → meta (CORRECT)" || { echo "FAIL"; exit 1; }'
# Expected: --session foo (no cmd) → meta (CORRECT)

# 4d. Confirm the upstream behavior the fix mirrors (informational — no Chrome launched):
#     agent-browser with no args prints help and exits 0. (Do NOT actually run it if it might
#     hang — but `agent-browser --help` is a safe, fast, read-only probe. Wrap in timeout.)
timeout 10 "$POOL_REAL_BIN" --help >/dev/null 2>&1 && echo "upstream --help exits 0 (passthrough is correct)" \
  || echo "upstream --help probe skipped (real bin unavailable — fine; the fix is logic-correct regardless)"
# Expected: "upstream --help exits 0 ..." (or the skipped message if $POOL_REAL_BIN isn't set
#           in this shell — the fix's correctness does not depend on this probe).

# (No Chrome, no daemon, no concurrency validation applies to this pure-function fix.
#  Issues 1/2/3/5 are OUT OF SCOPE — they are separate subtasks P1.M1.T1.S1 / P1.M2 / P1.M3.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck -S warning lib/pool.sh` clean (zero warnings).
- [ ] `bash -n test/validate.sh` clean.
- [ ] `shellcheck -S warning test/validate.sh` clean.
- [ ] Level 2 snippet 2a passes (all 7 no-command cases → meta).
- [ ] Level 2 snippet 2b passes (`bash test/validate.sh` exits 0, new body PASS).
- [ ] Level 2 snippet 2c passes (META regression — help/version/session-list/skills-family).
- [ ] Level 2 snippet 2d passes (DRIVING regression — real commands + unrecognized default).

### Feature Validation

- [ ] `pool_dispatch_classify` (no args) → `meta`.
- [ ] `pool_dispatch_classify --json` → `meta`.
- [ ] `pool_dispatch_classify --session foo` (no cmd) → `meta`.
- [ ] `pool_dispatch_classify --session=foo` (no cmd) → `meta`.
- [ ] `pool_dispatch_classify --headed --json` (no cmd) → `meta`.
- [ ] `pool_dispatch_classify -i` (no cmd) → `meta`.
- [ ] `pool_dispatch_classify ""` (empty-string arg) → `meta`.
- [ ] Regression: `--help`/`-h`/`--version` → `meta` (unchanged).
- [ ] Regression: `session list` + `skills`/`dashboard`/`plugin`/`mcp` → `meta` (unchanged).
- [ ] Regression: `open`/`click`/`connect`/`close`/`session`(bare)/`unknowncmd` → `driving` (unchanged).
- [ ] Regression: `--session foo open` / `--json click` → `driving` (flags skipped, command found).
- [ ] `pool_dispatch_classify` returns 0 ALWAYS (no failure mode introduced).
- [ ] The consumer `pool_wrapper_main` step c is unchanged (Level 3 snippet 3a).

### Code Quality Validation

- [ ] The ONLY lib/pool.sh code change is the `printf 'driving\n'` → `printf 'meta\n'` token.
- [ ] Docstring step e and the inline comment updated to say `meta` (lockstep with code).
- [ ] Test body named `selftest_dispatch_classify_cases` (single-setup runner — NOT `test_*`).
- [ ] Test body pure-function (no Chrome, no sim-owner, no persistent lease writes).
- [ ] Test body chains `assert_eq ... || return 1` (fail-fast explicit).
- [ ] No scope creep into Issues 1/2/3/5 (boolean, port race, close-rebind, help wording).
- [ ] No new META commands added; no DRIVING default changed for unrecognized commands.

### Documentation & Deployment

- [ ] Docstring step e matches the new behavior (`meta`, not `driving`).
- [ ] Inline comment above the `if [[ -z "$cmd" ]]` block explains the Issue 4 rationale.
- [ ] No README change needed (bare-command passthrough matches upstream; the README META list
      is not contradicted — a subcommand-less invocation is a help request, consistent with the
      documented `--help`/`--version` passthrough). The Mode B final task (P1.M4.T1) will sweep
      README 'How it works' if a discrepancy is found.
- [ ] No new env vars; no config changes; no path changes.

---

## Anti-Patterns to Avoid

- ❌ Don't touch the `--help`/`-h`/`--version` short-circuit, the META case (`session list` /
  `skills`/`dashboard`/`plugin`/`mcp`), or the driving default fallthrough — they are correct
  and unchanged. The ONLY code change is the empty-cmd branch's printf token.
- ❌ Don't change the DRIVING default for unrecognized commands — `agent-browser mouse` must
  still return `driving` (contract step d: "default to driving — let the real binary handle
  the error"). Only the NO-COMMAND case changes.
- ❌ Don't touch `pool_wrapper_main` step c (the consumer) — it already `exec`s passthrough on
  `meta`; it benefits automatically. Editing it is scope creep and risks regressions.
- ❌ Don't add a non-zero return path to `pool_dispatch_classify` — it returns 0 ALWAYS; the
  caller's unguarded `class="$(pool_dispatch_classify "$@")"` relies on rc 0.
- ❌ Don't remove the `\n` from `printf 'meta\n'` — the caller strips it via command
  substitution, but the `printf` contract (echo exactly one token + newline) is preserved.
- ❌ Don't name the test body `test_dispatch_classify_*` — that prefix is run by
  `abpool_run_suite` with per-test `setup()` (spawns a process), which HANGS on the 3rd call
  in a shared sandbox (AGENTS.md §4). Use `selftest_dispatch_classify_*` (single-setup runner).
- ❌ Don't spawn Chrome or a sim-owner in the dispatch test body — it's a pure-function test;
  `pool_dispatch_classify` reads no globals and writes no files. The single setup() is already
  paid for by `_run_selftest_suite`; the body ignores its state.
- ❌ Don't fix Issues 1/2/3/5 in this subtask — they have their own subtasks
  (P1.M1.T1.S1 for 1/5, P1.M2 for 2, P1.M3 for 3). Stay in scope: Issue 4 only.
- ❌ Don't reformat the `pool_dispatch_classify` function or its docstring beyond the targeted
  step-e line and the inline comment.
- ❌ Don't blanket-disable shellcheck rules — the 1-token change introduces no warnings; fix
  the code, not the linter.
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, `TEST_RESULTS.md`,
  or any file other than `lib/pool.sh` and `test/validate.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The fix is a **single printf token** (`'driving\n'` → `'meta\n'`) inside an existing
  branch, plus 2 comment lines and a pure-function test body. Tiny, well-bounded surface.
- The behavior was **verified empirically this session**: all 7 no-command cases (no-args,
  `--json`, `--session foo`, `--session=foo`, `--headed --json`, `-i`, `""`) currently return
  `driving` and all are caught by the single `if [[ -z "$cmd" ]]` branch — so one token flips
  all of them. The META and DRIVING regression cases were also verified empirically.
- The consumer (`pool_wrapper_main` step c) is **already wired** for `meta` → passthrough, so
  no consumer change is needed (confirmed by reading lib/pool.sh:3500–3502).
- The test framework's `selftest_*` single-setup pattern is documented exactly (quoted from
  validate.sh:335) with a copy-pasteable reference implementation reusing the existing
  `assert_eq` helper — and the parallel P1.M1.T1.S1 PRP's `selftest_config_bool_*` bodies are
  already landing in validate.sh, proving the pattern works in this exact file.
- The -1 reflects residual merge-collision risk with the parallel P1.M1.T1.S1 PRP (both
  append selftest bodies to validate.sh). The placement guidance (after the config_bool
  block if landed, else after selftest_wrapper_and_admin_are_executable; before
  _run_selftest_suite) minimizes this, and compgen-based discovery is order-independent — but
  if both land simultaneously a textual conflict in validate.sh is possible. Level 3 snippet
  3c and the `bash test/validate.sh` gate (2b) catch any breakage immediately.
