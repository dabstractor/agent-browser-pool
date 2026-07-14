# PRP — P1.M1.T1.S1: Update `_pool_config_bool` to accept truthy values + sync help/docs (Mode A)

> **Bugfix context**: This subtask fixes **Issue 1 + Issue 5** from the validation report
> (`plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md`).
> It is a **behavior + docs** fix (Mode A — docs ride with the work). The repo is no
> longer greenfield; `lib/pool.sh` is 4424 LOC and fully implemented.

---

## Goal

**Feature Goal**: Make `_pool_config_bool` honor the documented truthy set (`1`/`true`/`yes`/`on`, case-insensitive) instead of only the literal `"1"`, so the three boolean env vars (`AGENT_CHROME_HEADLESS`, `AGENT_BROWSER_POOL_DISABLE`, `AGENT_CHROME_ALLOW_SLOW_COPY`) behave as `README.md` and `pool_admin_help` already advertise. Sync the function docstring, `pool_admin_help`, and the README env-var table so code and docs agree.

**Deliverable**:
1. `lib/pool.sh` — `_pool_config_bool` (lines 82–84) rewritten to accept `1|true|yes|on` (case-insensitive) → `1`, everything else → `0`; its docstring (lines 79–81) updated.
2. `lib/pool.sh` — `pool_admin_help` env-var lines (4418–4420) updated to state `1/true/yes/on` for all three booleans.
3. `lib/pool.sh` — the `# 5. Booleans` comment in `pool_config_init` (line 171) updated to reflect the new truthy set.
4. `README.md` — env-var table rows (lines 218–220) updated to state `1/true/yes/on`.
5. `test/validate.sh` — new `selftest_config_bool_*` bodies added to the existing single-setup self-test, asserting the full truthy/falsy truth table (pure-function test, no Chrome).
6. The 5 consumer call-sites (`lib/pool.sh:242, 1295, 1515, 3491, 4222`) are **unchanged** — they already gate on `== "1"`, and the normalizer still emits `"1"` for ON, so they benefit automatically.

**Success Definition**:
- `_pool_config_bool true` → `1`; `_pool_config_bool TRUE` → `1`; `_pool_config_bool yes` → `1`; `_pool_config_bool ON` → `1`; `_pool_config_bool 1` → `1`.
- `_pool_config_bool 0` → `0`; `_pool_config_bool false` → `0`; `_pool_config_bool no` → `0`; `_pool_config_bool off` → `0`; `_pool_config_bool ""` → `0`; `_pool_config_bool random` → `0`.
- `bash -n lib/pool.sh` clean; `shellcheck -S warning lib/pool.sh` clean.
- `bash test/validate.sh` (the self-test suite) passes including the new config_bool bodies.
- `AGENT_BROWSER_POOL_DISABLE=true bash -c 'source lib/pool.sh; pool_config_init; echo "$POOL_DISABLE"'` prints `1` (the cutover safety valve now engages on the documented truthy form).
- `grep -n '1/true/yes' README.md lib/pool.sh` shows the synced wording in both files; no stale `if set` or `1`/`true`/`yes`-without-`on` wording remains in the three boolean rows.

## User Persona

**Target User**: Operators using `agent-browser-pool` during cutover (PRD §2.17) and on headless hosts (PRD §2.6/§2.18). Secondary: the implementing agent and downstream test subtasks.

**Use Case**: An operator mid-cutover sets `AGENT_BROWSER_POOL_DISABLE=true` to keep one session on the old workflow. Today that silently fails (pooling stays active). After this fix it works as documented.

**User Journey**: Operator reads `README.md` env-var table (or `agent-browser-pool help`) → sees `1/true/yes/on` accepted → sets the var to `true` → pooling disables / Chrome goes headless / slow-copy permitted, matching the documented contract.

**Pain Points Addressed**:
- **Cutover safety valve silent failure** (most severe — PRD §2.17: "This breaks running work"): `=true` now actually disables.
- **Headless hosts**: `AGENT_CHROME_HEADLESS=true` now launches `--headless=new`.
- **Non-btrfs escape hatch**: `AGENT_CHROME_ALLOW_SLOW_COPY=true` now permits the slow copy instead of `pool_die`-ing.
- **Docs/code contradiction** (Issue 5): help and README no longer promise a contract the code doesn't fulfill.

## Why

- **Issue 1 (Major)** + **Issue 5 (Minor docs)** from the validation report — same root cause, fixed together per `key_findings.md`.
- The fix is **1 function + 3 doc locations + 1 test** — minimal blast radius. The 5 consumer gates are already `== "1"`, so the normalizer change is backward-compatible (it still outputs `"1"` for ON; nothing that was ON before becomes OFF, and nothing that was OFF becomes ON except the newly-accepted truthy strings).
- PRD §2.17 makes the disable valve the **only** per-session opt-out during cutover; an operator "will reach for `true`" (key_findings.md). Honoring it is cutover-critical.
- Choosing Option (a) "accept truthy values" (over Option (b) "tighten docs to `1` only") because the disable valve is safety-critical and the documented `1`/`true`/`yes` form is what users naturally type.

## What

### Behavior change (single function)

`_pool_config_bool` currently:
```bash
local val="${1:-}"
if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
```
becomes a `case` over the lowercased input accepting `1|true|yes|on` → `1`, else `0`. See Implementation Tasks Task 1 for the exact code (verified shellcheck-clean on ShellCheck 0.11.0 and bash 5.3 against the full contract truth table).

### Docs changes (3 locations, all in lockstep)

- `lib/pool.sh` docstring (lines 79–81): state accepted values `1/true/yes/on` (case-insensitive).
- `lib/pool.sh` `pool_config_init` comment (line 171 `# 5. Booleans`): same.
- `lib/pool.sh` `pool_admin_help` (lines 4418–4420): all three rows say `(1/true/yes/on)`.
- `README.md` env table (lines 218–220): all three rows say `1/true/yes/on`.

### Success Criteria

- [ ] `_pool_config_bool` returns `1` for `1 true TRUE True yes YES Yes on ON On` (10 inputs).
- [ ] `_pool_config_bool` returns `0` for `0 false no off "" random` (6 inputs; contract lists these — `""` tested via no-arg call).
- [ ] The 5 consumer sites are **byte-unchanged** (verify with `git diff` — only lines 79–84, 171, 4418–4420 move).
- [ ] `shellcheck -S warning lib/pool.sh` clean; `bash -n lib/pool.sh` clean.
- [ ] `bash test/validate.sh` exits 0 with the new selftest bodies passing.
- [ ] README + help text both say `1/true/yes/on` for all three booleans; no `if set` remains for DISABLE/ALLOW_SLOW_COPY.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP pins exact line numbers, quotes the current code at every edit site, gives the verified replacement code, specifies the test framework's exact runner pattern (single-setup `selftest_*`), and lists the precise validation commands. The implementer needs no prior exposure to `lib/pool.sh` beyond reading the quoted snippets.

### Documentation & References

```yaml
# MUST READ — primary sources for the implementation idiom
- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: '${var,,} (to-lower, bash 4.0+) — the case-fold mechanism used instead of nocasematch.'
  critical: '${var,,} is pure parameter expansion (no subshell) → never trips SC2155. Host is bash 5.3 (verified). The repo already requires bash >= 4.2 (lib/pool.sh docstring), so 4.0+ is satisfied.'

- url: https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html
  why: 'case statement with | alternation (1|true|yes|on) — POSIX, no subshell, shellcheck-clean. Preferred over [[ =~ ]] whose quoting semantics shifted across bash versions.'
  critical: 'Use case, NOT [[ =~ ]]; case needs no regex quoting and is unambiguous to shellcheck.'

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: 'declare and assign separately. The new function captures into `local v` then reassigns `v="${v,,}"` in a SECOND statement — `local v="${1:-}"` is safe (param expansion, no $(...)), but keep the two-statement form for the case-fold.'

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: 'double-quote expansions. `case "$v" in` (quoted) — not `case $v in`.'

- url: https://mywiki.wooledge.org/BashFAQ/001
  why: 'printf over echo. The function already uses printf; keep `printf '"'"'%s\n'"'"'` for output.'

# Project-internal references (READ THESE — exact edit sites)
- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md
  why: Issue 1 (root cause + consumer table) and Issue 5 (help-text wording). Authoritative fix approach.
  pattern: 'Section "ISSUE 1" lists all 5 consumer lines (242, 1295, 1515, 3491, 4222) and the 3 doc contradictions; "ISSUE 5" lists the help-text lines.'
  gotcha: 'The fix RECOMMENDS Option (a) accept truthy — this PRP follows that. Do NOT pick Option (b) (tighten docs to "1" only).'

- file: lib/pool.sh
  why: THE file being edited. Read lines 75–105 (function + docstring), 165–185 (pool_config_init bool block), 4410–4425 (pool_admin_help).
  pattern: 'Existing style — docstring above each _pool_* function; printf for output; `local v="${1:-}"` for set -u safety; comments cite PRD sections.'
  gotcha: 'Do NOT touch the 5 consumer sites (242, 1293–1295, 1515, 3489–3492, 4222) — they gate on `== "1"` and stay correct. Do NOT touch line 1539 (log line) — it logs $POOL_HEADLESS, unaffected.'

- file: README.md
  why: 'Lines 205–235 — the env-var table. Row 218 (HEADLESS), 219 (ALLOW_SLOW_COPY), 220 (DISABLE) are the edit targets.'
  pattern: 'Markdown table row format: `| \`ENV_VAR\` | default | meaning |`. Keep the backticks around env-var names and values.'
  gotcha: 'Line 220 currently says "`1` = per-process passthrough" — broaden to "`1`/`true`/`yes`/`on` = per-process passthrough". Line 219 says "set to permit" with NO value list — add the value list. Line 218 already says "1/true/yes" — ADD "on".'

- file: test/validate.sh
  why: 'The test framework. Add `selftest_config_bool_*` bodies following the existing `selftest_*` pattern (pure functions, no Chrome).'
  pattern: 'Bodies are plain functions calling `assert_eq EXPECTED ACTUAL LABEL`; the `_run_selftest_suite` (line 335) auto-discovers any `selftest_*` function via `compgen -A function | grep "^selftest_"`. Bodies run in the MAIN shell via `if "$fn"` (NOT a subshell) — a failed assert `return 1` → recorded FAIL → suite continues.'
  gotcha: 'Do NOT use `run_test`/`abpool_run_suite` for these — that path calls `setup()` per test (spawns a sim-owner process) and AGENTS.md §4 forbids >1 process-spawning setup() call in a shared sandbox. The `selftest_*` prefix is auto-picked by the SINGLE-SETUP `_run_selftest_suite` (one setup() for ALL selftest bodies). See validate.sh lines 320–360.'

- file: plan/001_0f759fe2777c/bugfix/001_af49e87213c6/P1M1T1S1/research/bool-normalization.md
  why: External research confirming the case+${,,} idiom is shellcheck-clean and set -euo safe. Includes the exact recommended function.
  section: 'Recommended implementation' (final code block).
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── README.md                     # lines 205-235: env-var table (3 rows to edit)
├── lib/
│   └── pool.sh                   # 4424 LOC — lines 79-84, 171, 4418-4420 to edit
├── test/
│   └── validate.sh               # 366 LOC — selftest_* pattern to extend
└── plan/001_0f759fe2777c/bugfix/001_af49e87213c6/
    ├── architecture/key_findings.md   # Issue 1 + Issue 5 root cause + fix approach
    └── P1M1T1S1/
        ├── PRP.md                # THIS FILE
        └── research/bool-normalization.md   # external research (case + ${,,} idiom)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 3 existing files:
#   lib/pool.sh       — _pool_config_bool body+docstring, pool_config_init comment, pool_admin_help rows
#   README.md         — 3 env-var table rows
#   test/validate.sh  — new selftest_config_bool_truthy + selftest_config_bool_falsy + selftest_config_bool_via_pool_config_init bodies
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: the 5 consumer sites gate on == "1" (NOT on the raw env string). This is WHY
# the fix is safe — the normalizer still outputs "1" for ON, so consumers are unaffected.
# DO NOT "modernize" the consumers to check true/yes/on directly; that would be scope creep
# and risk regressions. Lines: 242, 1295, 1515, 3491 (POOL_DISABLE), 4222.
# Verify they are untouched:  git diff lib/pool.sh should show ONLY the function + docstring + comment + help rows.

# GOTCHA: use ${var,,} (bash 4.0+ to-lower), NOT shopt -s nocasematch. nocasematch is
# session-GLOBAL and must be captured+restored (needs $(shopt -p) + eval — SC2155 territory
# and a leak-on-interruption risk). ${var,,} is pure parameter expansion, no subshell.
# Host bash is 5.3 (verified); repo already requires >= 4.2.

# GOTCHA: keep `local v="${1:-}"` for the FIRST assignment (set -u safety — $1 may be unset
# when called as `_pool_config_bool` with no arg). Then `v="${v,,}"` in a SEPARATE statement.
# Do NOT write `local v="${1:-,,}"` — that is not valid syntax. Do NOT write
# `local v; v="${1:-}"` then `local v="${v,,}"` — double `local` is a no-op but confusing.

# GOTCHA: the test framework's selftest runner is SINGLE-SETUP (validate.sh:335
# _run_selftest_suite calls setup() ONCE for all selftest_* bodies). setup() spawns a REAL
# sim-owner process; calling it >once in a shared sandbox HANGS on the 3rd call (AGENTS.md §4).
# So new test bodies MUST be named `selftest_*` (auto-discovered by the single-setup runner),
# NOT `test_*` (which abpool_run_suite would run with per-test setup). Bodies must be
# PURE-FUNCTION (no Chrome, no lease writes that persist — _run_selftest_suite sweeps the
# lanes dir between bodies but assume nothing).

# GOTCHA: assert_eq runs in the MAIN shell in selftest (not a subshell). A failing assert
# returns 1 → the body's `return 1` propagates → recorded FAIL → suite continues. So a body
# can chain multiple assert_eq calls; the FIRST failure ends that body (later asserts in the
# same body won't run). That is the existing pattern (see selftest_assert_eq_passes).

# GOTCHA: README line 219 (ALLOW_SLOW_COPY) currently has NO value list ("set to permit a
# real (slow) 4.8 GB copy per acquire") — it must GAIN "1/true/yes/on". Line 220 (DISABLE)
# says "`1` = per-process passthrough" — broaden to "`1`/`true`/`yes`/`on`". Line 218
# (HEADLESS) already says "1/true/yes" — just ADD "/on".

# GOTCHA: pool_admin_help (lib/pool.sh:4418-4420) uses printf '  ENV_VAR<spaces>desc\n'.
# Preserve the column alignment (env var name left-padded to a consistent width). The three
# rows currently align at the description column; keep that alignment after editing the desc text.

# GOTCHA: the existing docstring (lines 79-81) says 'A var counts as ON only when its value
# is exactly "1"'. This is now FALSE — rewrite it. Also line 171 comment "# 5. Booleans —
# exactly "1" → on, anything else → off." is now FALSE — rewrite it.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. The only "structure" is the `_pool_config_bool` signature, which is unchanged: `_pool_config_bool VALUE` → prints `1` or `0`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — rewrite _pool_config_bool (lines 79-84)
  - REPLACE the current docstring + function (lines 79-84) with the verified version below.
  - KEEP the function NAME (_pool_config_bool) and its stdout contract (prints "1"/"0" + newline).
  - NAMING/PLACEMENT: unchanged — stays at lib/pool.sh:79-84 (internal helper, _ prefix).
  - REFERENCE IMPLEMENTATION (verified shellcheck-clean on ShellCheck 0.11.0 + bash 5.3;
    passes the full contract truth table — see Validation Level 2):
      ----------------------------------------------------------------
      # _pool_config_bool VALUE
      #   Normalize a tri-state env value to "1" (on) or "0" (off). ON when the value is
      #   one of 1 / true / yes / on (case-insensitive); every other value (including "0",
      #   "false", "no", "off", arbitrary strings, and unset) is OFF. Keeps boolean
      #   semantics predictable and matches the README + `agent-browser-pool help` contract.
      _pool_config_bool() {
          local v="${1:-}"
          v="${v,,}"                      # bash 4.0+ to-lower (no subshell, set -u safe)
          case "$v" in
              1|true|yes|on) printf '%s\n' 1 ;;
              *)             printf '%s\n' 0 ;;
          esac
      }
      ----------------------------------------------------------------
  - NOTE: the two-statement `local v=...; v="${v,,}"` form avoids SC2155 (the case-fold is
    parameter expansion, not command substitution, so SC2155 would not fire regardless —
    but the two-statement form matches the research recommendation and is unambiguous).
  - DO NOT trim whitespace. Env vars set via `export FOO=true` carry no whitespace; the
    existing function was strict (exact match) and the contract specifies exact values.
    Adding trim is scope creep and risks SC2295. Keep it strict.

Task 2: EDIT lib/pool.sh — update pool_config_init comment (line 171)
  - FIND: `    # 5. Booleans — exactly "1" → on, anything else → off.`
  - REPLACE WITH: `    # 5. Booleans — 1/true/yes/on (case-insensitive) → on, else off.`
  - WHY: the comment is now factually wrong after Task 1; keep code+comments in lockstep.

Task 3: EDIT lib/pool.sh — update pool_admin_help (lines 4418-4420)
  - FIND these three printf lines (preserve leading spaces + alignment):
        printf '  AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes)\n'
        printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set\n'
        printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set\n'
  - REPLACE WITH (add /on to all three; replace "if set" with explicit value list for the
    latter two so "if set" no longer implies any-non-empty-value-works):
        printf '  AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes/on)\n'
        printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)\n'
        printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set (1/true/yes/on)\n'
  - PRESERVE: the env-var-name column width (the names are left-aligned to a fixed width;
    the descriptions start at the same column). Do NOT change the names or the leading spaces.

Task 4: EDIT README.md — update env-var table (lines 218-220)
  - FIND (3 table rows):
        | `AGENT_CHROME_HEADLESS` | unset = **windowed** | set to `1`/`true`/`yes` to launch Chrome with `--headless=new` |
        | `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | set to permit a real (slow) 4.8 GB copy per acquire |
        | `AGENT_BROWSER_POOL_DISABLE` | unset = **pooling active** | `1` = per-process passthrough (safety valve — see below) |
  - REPLACE WITH:
        | `AGENT_CHROME_HEADLESS` | unset = **windowed** | set to `1`/`true`/`yes`/`on` to launch Chrome with `--headless=new` |
        | `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | set to `1`/`true`/`yes`/`on` to permit a real (slow) 4.8 GB copy per acquire |
        | `AGENT_BROWSER_POOL_DISABLE` | unset = **pooling active** | `1`/`true`/`yes`/`on` = per-process passthrough (safety valve — see below) |
  - PRESERVE: the rest of the table (rows 211-217, 221+). PRESERVE the markdown pipe alignment
    style of the surrounding rows (do not reformat the whole table).

Task 5: ADD test/validate.sh — selftest bodies for _pool_config_bool
  - ADD three new functions named `selftest_config_bool_*` (the _run_selftest_suite at
    validate.sh:335 auto-discovers any `selftest_*` function — NO registration needed).
  - PLACE: after the existing `selftest_wrapper_and_admin_are_executable` function (ends
    around line 318) and BEFORE the `# --- source-vs-execute gate` comment block (line 358).
  - FOLLOW pattern: selftest_assert_eq_passes (validate.sh:264) — plain function, calls
    assert_eq EXPECTED ACTUAL LABEL. Runs in MAIN shell (not subshell) under the single-setup runner.
  - NAMING: selftest_config_bool_truthy, selftest_config_bool_falsy, selftest_config_bool_via_pool_config_init.
  - REFERENCE IMPLEMENTATION:
      ----------------------------------------------------------------
      # _pool_config_bool: truthy inputs (1/true/yes/on, case-insensitive) → "1".
      selftest_config_bool_truthy() {
          local v r
          for v in 1 true TRUE True yes YES Yes on ON On; do
              r="$(_pool_config_bool "$v")"
              assert_eq "1" "$r" "truthy [$v] -> 1" || return 1
          done
      }

      # _pool_config_bool: falsy inputs (0/false/no/off/empty/random) → "0".
      selftest_config_bool_falsy() {
          local v r
          for v in 0 false no off random; do
              r="$(_pool_config_bool "$v")"
              assert_eq "0" "$r" "falsy [$v] -> 0" || return 1
          done
          # empty/unset (no arg) — the set -u-safe ${1:-} path
          r="$(_pool_config_bool "")"
          assert_eq "0" "$r" "falsy [empty] -> 0" || return 1
          r="$(_pool_config_bool)"
          assert_eq "0" "$r" "falsy [no-arg] -> 0" || return 1
      }

      # End-to-end: AGENT_BROWSER_POOL_DISABLE=true flows through pool_config_init to POOL_DISABLE=1.
      # This is the cutover safety-valve contract (PRD §2.17) that motivated the fix.
      selftest_config_bool_via_pool_config_init() {
          local d
          d="$(AGENT_BROWSER_POOL_DISABLE=true bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
          assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=true -> POOL_DISABLE=1" || return 1
          d="$(AGENT_BROWSER_POOL_DISABLE=yes bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
          assert_eq "1" "$d" "AGENT_BROWSER_POOL_DISABLE=yes -> POOL_DISABLE=1" || return 1
          d="$(AGENT_BROWSER_POOL_DISABLE=0 bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_DISABLE"' _ "$ABPOOL_REPO")"
          assert_eq "0" "$d" "AGENT_BROWSER_POOL_DISABLE=0 -> POOL_DISABLE=0" || return 1
      }
      ----------------------------------------------------------------
  - WHY a subshell for the third body: pool_config_init mutates POOL_* globals; running it
    in `$(...)` isolates the mutation so it does not clobber the selftest suite's own
    POOL_* state (set by the single setup() call). The `source "$1/lib/pool.sh"` form
    re-sources cleanly in the child. ABPOOL_REPO is set at validate.sh:26 (module-level).
  - GOTCHA: the `|| return 1` after each assert_eq is REQUIRED — in the MAIN-shell selftest
    runner, without it a failed assert's `return 1` would end the body anyway, BUT the for-loop
    would otherwise continue to the next iteration after a failed assert in some bash versions
    when not explicitly chained. The `|| return 1` makes "fail fast" explicit and matches the
    assert_eq idiom. (assert_eq returns 1 on mismatch → `|| return 1` propagates → body ends.)
  - GOTCHA: do NOT spawn Chrome or a sim-owner in these bodies — they are pure-function tests.
    The single setup() call by _run_selftest_suite already provides a temp HOME + state dir,
    but these bodies do not USE setup's state (they call _pool_config_bool directly / spawn
    an isolated bash -c). That is fine and matches selftest_assert_eq_passes (which also
    ignores setup's state).

Task 6: VERIFY — run the full validation gauntlet BEFORE claiming done
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -S warning lib/pool.sh
      bash test/validate.sh                 # must exit 0
      grep -n 'if set' lib/pool.sh          # the 3 boolean rows should NO LONGER contain bare "if set"
      grep -n '1/true/yes' README.md lib/pool.sh   # should show synced wording in both
  - RUN (the contract truth table, one-liner — re-verify the function in isolation):
      bash -c 'set -euo pipefail; source lib/pool.sh; for t in 1 true TRUE True yes YES Yes on ON On; do [ "$(_pool_config_bool "$t")" = 1 ] || { echo "FAIL $t"; exit 1; }; done; for f in 0 false no off "" random; do [ "$(_pool_config_bool "$f")" = 0 ] || { echo "FAIL $f"; exit 1; }; done; echo OK'
      # Expected: OK
  - RUN (the safety-valve end-to-end — the motivating bug):
      AGENT_BROWSER_POOL_DISABLE=true bash -c 'source lib/pool.sh; pool_config_init; echo "POOL_DISABLE=$POOL_DISABLE"'
      # Expected: POOL_DISABLE=1   (was 0 before the fix)
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — the boolean normalizer (case over lowercased input; no subshell, no nocasematch):
_pool_config_bool() {
    local v="${1:-}"          # set -u safe: ${1:-} handles unset/no-arg
    v="${v,,}"                # bash 4.0+ to-lower — pure parameter expansion
    case "$v" in              # case (POSIX) over [[ =~ ]] (bash-only, quoting traps)
        1|true|yes|on) printf '%s\n' 1 ;;
        *)             printf '%s\n' 0 ;;
    esac
}
# WHY case+${,,} over shopt -s nocasematch: nocasematch is session-global, must be
# captured/restored via $(shopt -p)+eval (SC2155 + leak-on-interruption risk). ${var,,}
# is local to the variable, no global state.

# Pattern B — consumer sites stay == "1" (UNCHANGED — do not touch):
#   lib/pool.sh:242    if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then ...
#   lib/pool.sh:1295   if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then ...
#   lib/pool.sh:1515   [[ "$POOL_HEADLESS" == "1" ]] && flags+=(--headless=new)
#   lib/pool.sh:3491   if [[ "${POOL_DISABLE:-0}" == "1" ]]; then ...
#   lib/pool.sh:4222   elif [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then ...
# These are correct BECAUSE the normalizer emits "1" for ON. No change needed.

# Pattern C — test body under the single-setup selftest runner (MAIN shell, fail-fast):
selftest_config_bool_truthy() {
    local v r
    for v in 1 true TRUE True yes YES Yes on ON On; do
        r="$(_pool_config_bool "$v")"
        assert_eq "1" "$r" "truthy [$v] -> 1" || return 1
    done
}
# The || return 1 makes fail-fast explicit; the selftest_* prefix auto-registers with
# _run_selftest_suite (validate.sh:335). Do NOT use test_* prefix (per-test setup hangs).
```

### Integration Points

```yaml
CODE (3 in-place edits, 1 addition — no new files):
  - lib/pool.sh:79-84      _pool_config_bool body + docstring (REWRITE)
  - lib/pool.sh:171        pool_config_init "# 5. Booleans" comment (REWRITE)
  - lib/pool.sh:4418-4420  pool_admin_help 3 env-var rows (REWRITE descriptions)
  - README.md:218-220      env-var table 3 rows (REWRITE meaning column)
  - test/validate.sh:+3    3 new selftest_config_bool_* bodies (ADD, ~30 lines)

CONFIG (unchanged env vars — only their ACCEPTED VALUES broaden):
  - AGENT_CHROME_HEADLESS        now accepts 1/true/yes/on (was: only 1)
  - AGENT_BROWSER_POOL_DISABLE   now accepts 1/true/yes/on (was: only 1)  ← cutover safety valve
  - AGENT_CHROME_ALLOW_SLOW_COPY now accepts 1/true/yes/on (was: only 1)
  - No new env vars. No default changes. No path changes.

CONSUMERS (DO NOT TOUCH — verified unchanged):
  - lib/pool.sh:242, 1295, 1515, 3491, 4222  (all gate on == "1", stay correct)

ROUTES: none.
DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                 # parse check. MUST be clean (no output).
shellcheck -S warning lib/pool.sh   # MUST report zero issues (matches the project's existing gate).
bash -n test/validate.sh            # parse check the test file after adding bodies.
shellcheck -S warning test/validate.sh   # MUST be clean.
# Expected: zero output from all four.
# NOTE: the project uses `shellcheck -S warning` (the validation report confirmed this is the
#       project's gate). Do not use a stricter -S info/style threshold — the existing codebase
#       was validated at -S warning and may have style-level annotations by design.
```

### Level 2: Unit Tests (Component Validation)

```bash
# 2a. The full contract truth table (run the function in isolation against ALL spec inputs):
bash -c 'set -euo pipefail; source lib/pool.sh; \
  for t in 1 true TRUE True yes YES Yes on ON On; do \
    [ "$(_pool_config_bool "$t")" = 1 ] || { echo "FAIL truthy [$t]"; exit 1; }; \
  done; \
  for f in 0 false no off "" random; do \
    [ "$(_pool_config_bool "$f")" = 0 ] || { echo "FAIL falsy [$f]"; exit 1; }; \
  done; \
  echo "TRUTH TABLE OK"'
# Expected: TRUTH TABLE OK

# 2b. The test framework self-test suite (now includes the 3 new config_bool bodies):
bash test/validate.sh
# Expected: prints "== selftest_config_bool_truthy / PASS", "== selftest_config_bool_falsy / PASS",
#           "== selftest_config_bool_via_pool_config_init / PASS", and a final
#           "N passed, 0 failed" line; exits 0.
# If ANY selftest fails, the suite exits non-zero — debug root cause, do not proceed.

# 2c. End-to-end through pool_config_init (the actual consumer path) for all three vars:
AGENT_CHROME_HEADLESS=true      bash -c 'source lib/pool.sh; pool_config_init; echo "HEADLESS=$POOL_HEADLESS"'     # expect HEADLESS=1
AGENT_BROWSER_POOL_DISABLE=true bash -c 'source lib/pool.sh; pool_config_init; echo "DISABLE=$POOL_DISABLE"'        # expect DISABLE=1
AGENT_CHROME_ALLOW_SLOW_COPY=yes bash -c 'source lib/pool.sh; pool_config_init; echo "SLOW=$POOL_ALLOW_SLOW_COPY"'  # expect SLOW=1
AGENT_CHROME_HEADLESS=0         bash -c 'source lib/pool.sh; pool_config_init; echo "HEADLESS=$POOL_HEADLESS"'      # expect HEADLESS=0
# Expected: the four lines above show 1, 1, 1, 0 respectively.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Verify the 5 consumer sites are BYTE-UNCHANGED (the fix must not touch them):
git diff -- lib/pool.sh | grep -E '^[+-].*== "1"|^[+-].*POOL_(HEADLESS|DISABLE|ALLOW_SLOW_COPY)' \
  || echo "consumers unchanged"
# Expected: "consumers unchanged" (the only diff lines are the function body, docstring,
#           the line-171 comment, and the 3 help rows). If you see a consumer-site diff,
#           STOP — you over-edited; revert that hunk.

# 3b. Verify docs/code are in lockstep (no stale wording remains):
grep -n 'if set' lib/pool.sh
# Expected: the 3 boolean help rows (4418-4420) NO LONGER contain a bare "if set" without a
#           value list. (Other "if set" occurrences elsewhere in the file, if any, are unrelated
#           — inspect them but they are out of scope.)
grep -nE '1/true/yes(/on)?' README.md lib/pool.sh
# Expected: matches in README.md (3 rows) and lib/pool.sh (docstring + comment + 3 help rows).

# 3c. Verify the admin help text renders correctly:
bash -c 'source lib/pool.sh; pool_admin_help' | grep -E 'HEADLESS|ALLOW_SLOW_COPY|POOL_DISABLE'
# Expected: 3 lines, each ending with "(1/true/yes/on)" and column-aligned.

# 3d. Full repo smoke (no Chrome launched — pure sourcing + help):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_admin_help >/dev/null; echo SOURCED_OK'
# Expected: SOURCED_OK
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The cutover safety-valve scenario (the MOST SEVERE impact from key_findings.md):
#     Simulate an operator mid-cutover setting =true to bypass the pool.
AGENT_BROWSER_POOL_DISABLE=true bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  if [[ "$POOL_DISABLE" == "1" ]]; then
    echo "SAFETY VALVE ENGAGED (correct — operator bypass works)"
  else
    echo "SAFETY VALVE FAILED (pooling still active — BUG NOT FIXED)"; exit 1
  fi
'
# Expected: SAFETY VALVE ENGAGED (correct — operator bypass works)

# 4b. Whitespace/robustness spot-check (env vars should NOT carry whitespace, but confirm
#     the function does not crash on odd input — it should return 0, not error):
for odd in " true" "true " "TRUE\n" "yes;rm -rf /"; do
  r="$(bash -c 'set -euo pipefail; source lib/pool.sh; printf "%s" "$(_pool_config_bool "$1")"' _ "$odd")"
  echo "[$odd] -> [$r]"
done
# Expected: each odd value -> [0] (none match 1|true|yes|on exactly after to-lower, because
#           they carry whitespace/payload). No crash, no command injection (case is safe).
#           This confirms the function is strict (no trim) and injection-safe.

# (No Chrome, no daemon, no concurrency validation applies to this pure-function + docs fix.
#  Issues 2/3/4 are OUT OF SCOPE — they are separate subtasks P1.M2 / P1.M3 / P1.M1.T2.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck -S warning lib/pool.sh` clean (zero warnings).
- [ ] `bash -n test/validate.sh` clean.
- [ ] `shellcheck -S warning test/validate.sh` clean.
- [ ] Level 2 snippet 2a passes (full truth table — 10 truthy + 6 falsy).
- [ ] Level 2 snippet 2b passes (`bash test/validate.sh` exits 0, 3 new bodies PASS).
- [ ] Level 2 snippet 2c passes (end-to-end through pool_config_init: 1/1/1/0).

### Feature Validation

- [ ] `_pool_config_bool` returns `1` for `1 true TRUE True yes YES Yes on ON On`.
- [ ] `_pool_config_bool` returns `0` for `0 false no off "" random`.
- [ ] The 5 consumer sites are unchanged (Level 3 snippet 3a → "consumers unchanged").
- [ ] `pool_admin_help` shows `(1/true/yes/on)` for all three boolean rows.
- [ ] README env table shows `1/true/yes/on` for all three boolean rows.
- [ ] Cutover safety valve: `AGENT_BROWSER_POOL_DISABLE=true` → `POOL_DISABLE=1` (Level 4 snippet 4a).
- [ ] Docstring (lib/pool.sh:79-81) and comment (lib/pool.sh:171) updated to match.

### Code Quality Validation

- [ ] Uses `case` + `${var,,}` (not `nocasematch`, not `[[ =~ ]]`).
- [ ] `local v="${1:-}"` then `v="${v,,}"` (two statements; set -u safe).
- [ ] `case "$v"` quoted (SC2086 clean).
- [ ] `printf '%s\n'` for output (not `echo`).
- [ ] Test bodies named `selftest_*` (single-setup runner — NOT `test_*`).
- [ ] Test bodies pure-function (no Chrome, no sim-owner, no persistent lease writes).
- [ ] No scope creep into Issues 2/3/4 (port race, close-rebind, empty-cmd dispatch).

### Documentation & Deployment

- [ ] README, pool_admin_help, docstring, and line-171 comment all agree on `1/true/yes/on`.
- [ ] No new env vars; no default changes; no path changes.
- [ ] Column alignment in `pool_admin_help` and README table preserved.
- [ ] Mode A satisfied: docs rode with the code in this same subtask (no separate docs task).

---

## Anti-Patterns to Avoid

- ❌ Don't touch the 5 consumer sites (`== "1"`) — they stay correct; "modernizing" them is scope creep and risks regressions.
- ❌ Don't use `shopt -s nocasematch` — it's session-global, needs capture/restore via `eval`, and leaks state on interruption. Use `${var,,}`.
- ❌ Don't use `[[ =~ ]]` with a regex — quoting semantics shifted across bash versions and it's needlessly bash-only. Use `case`.
- ❌ Don't trim whitespace — the contract specifies exact values; the existing function was strict; trim adds SC2295 risk for no real benefit on env vars.
- ❌ Don't name the test bodies `test_*` — that prefix is run by `abpool_run_suite` with per-test `setup()` (spawns a process), which HANGS on the 3rd call in a shared sandbox (AGENTS.md §4). Use `selftest_*` (single-setup runner).
- ❌ Don't spawn Chrome or a sim-owner in the config_bool test bodies — they're pure-function tests; the single setup() is already paid for by `_run_selftest_suite`.
- ❌ Don't fix Issues 2/3/4 in this subtask — they have their own subtasks (P1.M2, P1.M3, P1.M1.T2). Stay in scope.
- ❌ Don't change env-var defaults, names, or add new env vars — only the accepted VALUE SET broadens.
- ❌ Don't reformat the README table or the `pool_admin_help` block beyond the 3 targeted rows.
- ❌ Don't blanket-disable shellcheck rules — the function is clean as written; fix the code, not the linter.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: tiny, well-bounded surface (1 function body + 5 doc/comment lines + 1 table + 3 test bodies). The replacement code is **already verified** shellcheck-clean (ShellCheck 0.11.0) and passes the full contract truth table (10 truthy + 6 falsy inputs) on bash 5.3. The consumer sites are confirmed `== "1"` (so the normalizer change is backward-compatible by construction). The test framework's `selftest_*` single-setup pattern is documented exactly, with a copy-pasteable reference implementation that reuses the existing `assert_eq` helper. The -1 reflects residual risk in the third test body (`selftest_config_bool_via_pool_config_init`) — the `bash -c 'source ...; pool_config_init'` subshell pattern re-sources the lib cleanly in principle, but if the implementer fat-fingers the `$ABPOOL_REPO` path argument the body will fail with a source error; Level 2 snippet 2b catches it immediately.
