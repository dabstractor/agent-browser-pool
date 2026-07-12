# PRP — P1.M1.T1.S1: Directory structure + `lib/pool.sh` skeleton with strict bash

---

## Goal

**Feature Goal**: Establish the greenfield repository's directory skeleton (`bin/`, `lib/`, `test/`) and create `lib/pool.sh` — the shared bash library that both wrapper binaries will later `source`. The library contains only the file header, strict-mode settings, and the two foundational utility functions (`pool_die`, `_pool_log`). No pool logic is implemented yet.

**Deliverable**:
1. Three directories created: `bin/`, `lib/`, `test/` (matching PRD §3 repository layout).
2. `lib/pool.sh` containing, in order: file-level documentation comment block, strict-mode shebang+settings, `pool_die()` utility, `_pool_log()` utility.
3. The file is **sourceable with zero errors** under `set -euo pipefail` and passes `shellcheck` clean.
4. A deliberate, documented decision on whether `.gitignore` needs any new pattern (it does not for this subtask — rationale in Implementation Tasks Task 4).

**Success Definition**:
- `set -euo pipefail; source lib/pool.sh` exits 0 with no output.
- `shellcheck lib/pool.sh` reports no warnings/errors.
- `pool_die "test"` prints `test` to stderr and exits non-zero (verified in a subshell so the test harness survives).
- `_pool_log "hello"` appends one line of the form `<ISO-8601 timestamp> hello` to the configured pool log path.
- `bash -n lib/pool.sh` (syntax check) passes.
- Direct execution `./lib/pool.sh` either no-ops or prints a clear "this is a library, source it" message and exits 0 (does NOT crash from executing function bodies at parse/runtime).

## User Persona

**Target User**: The implementing agent (this PRP's consumer) and, downstream, every later subtask that builds on `lib/pool.sh` (P1.M1.T1.S2 path config, P1.M1.T2.S1 atomic-write helpers, all of M2–M5 lease logic, M6/M7 wrappers).

**Use Case**: Later subtasks `source lib/pool.sh` to get `pool_die` and `_pool_log` "for free" before implementing their own functions. This subtask establishes the conventions every later file will copy.

**Pain Points Addressed**: No shared utilities exist yet → every later subtask would re-implement error/log handling inconsistently. Locking the skeleton + header style now prevents convention drift across ~250 LOC of bash the PRD forecasts.

## Why

- **First subtask in the entire project** (dependencies: `[]`). Everything else builds on this file's header, strict-mode posture, and utility function signatures.
- Establishes the **single coding convention** for the repo: shebang form, strict mode, error handling (`pool_die`), and logging (`_pool_log`). Per PRD §2.19 ("No bare `~` anywhere") and §2.2, absolute-path resolution and strict error handling are non-negotiable from line 1.
- PRD §3 mandates exactly three dirs + `lib/pool.sh` as the shared core ("shared: owner resolve / acquire / release / reap / copy / launch"). This subtask creates the vessel; later subtasks fill it.

## What

User-visible behavior at this stage is minimal (this is infrastructure), but the file must satisfy a concrete contract:

### Success Criteria

- [ ] Directories `bin/`, `lib/`, `test/` exist (empty `bin/` and `test/` are fine; their files come in M6/M7 and M9).
- [ ] `lib/pool.sh` begins with `#!/usr/bin/env bash` immediately followed by `set -euo pipefail` (exact form mandated by the subtask contract; do NOT use the "omit shebang because it's sourced" advice — the contract overrides it).
- [ ] A file-level comment block documents: (a) the file's purpose, (b) that it is the shared library sourced by **both** `bin/agent-browser` and `bin/agent-browser-pool`, (c) minimum bash version (≥ 4.2 for `printf '%(...)T'`; host is 5.3), (d) that it must be sourced not executed, (e) the strict-mode posture.
- [ ] `pool_die()` defined: writes its arguments to stderr, then exits non-zero. Idiom: `printf '%s\n' "$*" >&2; exit 1`.
- [ ] `_pool_log()` defined: emits one line `"<ISO-8601-ts> <message>"` to the pool log path, using the bash builtin `printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1` (no `date` subprocess). Leading-underscore name marks it internal.
- [ ] No pool logic (no owner resolution, no acquire/release, no Chrome launch, no flock, no JSON). Just skeleton + the two utilities.
- [ ] `shellcheck lib/pool.sh` → clean. `bash -n lib/pool.sh` → clean.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP includes: the exact directory list (PRD §3), the exact function contracts, the exact validation commands (verified on-host), the exact bash version, the logging-path resolution rule, and a concrete reference implementation. The repo is greenfield so there is no existing convention to reverse-engineer — this subtask *creates* the convention.

### Documentation & References

```yaml
# MUST READ — primary sources for the implementation idioms
- url: https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
  why: printf builtin — the '%(fmt)T' time-format specifier and the '-1' == current-time argument.
  critical: 'printf -v ts "%(%Y-%m-%dT%H:%M:%S%z)T" -1' is the no-fork timestamp; confirmed working on host bash 5.3.
  section: search page for '%(fmt)T' / "the corresponding argument is an epoch time"

- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: authoritative semantics of 'set -e', 'set -u', 'set -o pipefail'.
  critical: pipefail makes a pipeline's exit status the rightmost non-zero (otherwise 'false | true' silently succeeds).

- url: https://github.com/koalaman/shellcheck/wiki/Directive
  why: how to annotate a bash file for shellcheck ('# shellcheck shell=bash' and disable= list).
  critical: directive MUST be the first line OR placed before shebang is acceptable ONLY if shebang absent. With a shebang, shellcheck auto-detects bash — directive optional but harmless.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: 'declare and assign separately' — local x; x="$(cmd)" so the command's exit status is not masked.
  critical: in _pool_log, capture the timestamp into a local in TWO statements, not 'local ts="$(printf ...)"'.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote variable expansions everywhere. Universal rule for this file.

# Project-internal references (READ THESE)
- file: PRD.md
  why: §3 Repository layout (exact dirs to create) and §2.2 (no bare '~' rule — informs path handling).
  pattern: 'bin/, lib/, test/' three dirs; lib/pool.sh is 'shared: owner resolve / acquire / release / reap / copy / launch'.
  gotcha: §2.2 — tilde does not expand after '=' or inside quotes; resolve $HOME to absolute for EVERY path. _pool_log's default log path must therefore use a $HOME-resolved absolute default, NOT '~/'.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §1 confirms repo is GREENFIELD (no bin/lib/test exist). §7 names the runtime state dir '~/.local/state/agent-browser-pool/' and the log file layout (alerts.log, chrome-<N>.log) — this tells us where _pool_log should write by default.
  pattern: State dir '$AGENT_BROWSER_POOL_STATE' (default ~/.local/state/agent-browser-pool); pool-level log is alerts.log there.
  gotcha: State dir does NOT exist yet at implementation time — _pool_log must mkdir -p its parent or fall back to stderr if the dir is absent, so that merely sourcing the lib never fails.

- file: .gitignore
  why: Already covers '*.log' (line 1) and '.state/' (line 5). Determines whether Task 4 needs any change.
  pattern: '*.log' catches any in-repo log file; '.state/' is for a different local-dev artifact.
  gotcha: The pool's REAL runtime logs live OUTSIDE the repo (~/.local/state/agent-browser-pool/*.log) and are never version-controlled regardless. See Task 4 — no .gitignore change needed for this subtask.

- file: README.md
  why: §"How it works" confirms lib/pool.sh is sourced by the wrapper; confirms 'No fork, no Rust, no daemon' (~250 LOC bash).
  pattern: Thin bash-only library; this subtask sets the tone.
```

### Current Codebase tree

Verified via `ls -la` on the repo root (2026-07-12):

```bash
agent-browser-pool/
├── .git/
├── .gitignore          # *.log, .state/, .env*, .DS_Store, dist/, build/, node_modules/, venv/, __pycache__/
├── PRD.md              # READ-ONLY
├── README.md           # overview (pre-existing)
└── plan/
    └── 001_0f759fe2777c/
        ├── architecture/system_context.md   # greenfield confirmation + env verification
        ├── prd_snapshot.md
        ├── prd_index.txt
        ├── tasks.json
        └── P1M1T1S1/                         # THIS subtask's plan dir
            └── research/bash-library-research.md   # external-research brief (see below)
# NOTE: NO bin/, lib/, test/, or install.sh exist yet. All must be created.
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── bin/                         # NEW — empty dir; wrapper shims land here in M6/M7 (placeholder .gitkeep optional)
├── lib/                         # NEW
│   └── pool.sh                  # NEW — shared library: header + strict mode + pool_die + _pool_log (THIS SUBTASK)
├── test/                        # NEW — empty dir; validate.sh lands here in M9 (placeholder .gitkeep optional)
└── ... (unchanged: PRD.md, README.md, .gitignore, plan/)
```

**File responsibilities**:
- `lib/pool.sh` — the **single shared bash library**. Sourced (never executed directly) by `bin/agent-browser` (M6) and `bin/agent-browser-pool` (M7). Holds repo-wide utilities and (in later subtasks) all pool logic. This subtask delivers ONLY: header comment block, strict-mode settings, `pool_die()`, `_pool_log()`.
- `bin/`, `test/` — empty placeholders so the layout matches PRD §3 from day one. (Git does not track empty dirs; add `.gitkeep` to each so they survive commits — see Task 1.)

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: strict-mode leak. 'set -euo pipefail' inside a SOURCED file
# propagates into the caller's shell. This is INTENTIONAL here — the PRD wants
# the whole project to run strict — but it means every caller inherits -e/-u/-o pipefail.
# Consequence for THIS file: use ${var:-} for ANY optional parameter so -u never fires
# on an unset-but-meaningful input. Example inside _pool_log: read the message as "${1:-}".

# CRITICAL: shebang on a sourced file is functionally inert ('source' ignores line 1).
# Keep '#!/usr/bin/env bash' anyway — the subtask CONTRACT mandates it, and it gives
# editor/shellcheck hints + lets the file be linted/executed standalone for testing.

# GOTCHA: printf '%(...)T' requires bash >= 4.2. Host is 5.3 (verified: outputs e.g.
# '2026-07-12T18:49:04-0400'). Do NOT shell out to 'date' on every log line — the
# builtin is fork-free and the PRD values low overhead (Chrome launch is the hot path).

# GOTCHA (PRD §2.2): NEVER put a bare '~' in any path handed to a subprocess or used
# in a redirection. Resolve $HOME to absolute. So _pool_log's default path is
# "${HOME}/.local/state/agent-browser-pool/pool.log" — NOT "~/.local/...".

# GOTCHA: the runtime state dir (~/.local/state/agent-browser-pool/) does NOT exist yet
# (confirmed). _pool_log MUST NOT fail when sourced just because the dir is missing.
# Either mkdir -p on first call, or degrade gracefully to stderr-only. Prefer mkdir -p
# guarded by '2>/dev/null || true' so a read-only HOME still lets sourcing succeed.

# GOTCHA: local x="$(cmd)" masks the command's exit status (shellcheck SC2155). In
# strict mode this can hide failures. Always: local x; x="$(cmd)".

# GOTCHA: do NOT put executable pool logic at the top level of lib/pool.sh. Any bare
# statement runs at source time. Only function DEFINITIONS and 'set'/'shopt' may run
# when sourced. (A top-level 'pool_die' call would crash every caller at source time.)
```

## Implementation Blueprint

### Data models and structure

Not applicable — this subtask defines no data models (no JSON schemas, no leases). The only "structure" is the two function signatures:

```bash
# Exit the program with a stderr message. Always exits non-zero.
# Args: $@ — the message (joined with spaces, like echo).
# Returns: never (exits 1).
pool_die() { ... }

# Append one timestamped line to the pool log. Internal helper (leading _).
# Args: $@ — the message.
# Env:  POOL_LOG_PATH overrides the destination file (default: resolved $HOME-based absolute path).
# Returns: 0 on success; calls pool_die if the log cannot be written AND stderr is unavailable.
_pool_log() { ... }
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE directories bin/ lib/ test/
  - RUN: mkdir -p bin lib test   (from repo root)
  - ADD: bin/.gitkeep and test/.gitkeep (empty files) so git tracks the otherwise-empty dirs.
        lib/ does NOT need .gitkeep because lib/pool.sh (Task 2) is committed in this same subtask.
  - VERIFY: PRD §3 layout — exactly these three dirs.
  - WHY .gitkeep: git ignores empty directories; the PRD layout must be visible in the first commit.

Task 2: CREATE lib/pool.sh  (the entire deliverable body)
  - STRUCTURE (top to bottom, exact order):
      1. '#!/usr/bin/env bash'
      2. File-level comment block (see Task 2a for required contents).
      3. 'set -euo pipefail'
      4. (Optional) '# shellcheck shell=bash' directive — harmless, aids linting.
      5. Pool-log path resolution (a readonly-resolved absolute default; honor POOL_LOG_PATH override).
      6. 'pool_die()' function definition.
      7. '_pool_log()' function definition.
      8. NO other code. No top-level executable statements beyond 'set'.
  - NAMING: pool_die (public, no underscore — callers use it freely); _pool_log (internal, underscore prefix).
  - PLACEMENT: repo-root-relative lib/pool.sh.
  - FOLLOW pattern: the exact idioms in Task 2b below.

  Task 2a: FILE-LEVEL COMMENT BLOCK must state:
      - One-line purpose ("Shared library for the agent-browser-pool wrapper and admin CLI.").
      - "Sourced by bin/agent-browser (wrapper shim) and bin/agent-browser-pool (admin CLI)."
      - "This file is SOURCED, not executed directly."
      - "Requires bash >= 4.2 (uses printf '%(...)T'); developed/tested on bash 5.x."
      - "Strict mode: set -euo pipefail is enabled at source time and propagates to callers."
      - Brief TODO marker: "Pool logic (owner resolve / acquire / release / reap / copy / launch) is added by later subtasks."

  Task 2b: REFERENCE IMPLEMENTATION (adapt verbatim, then verify):
      ----------------------------------------------------------------
      #!/usr/bin/env bash
      # shellcheck shell=bash
      #
      # lib/pool.sh — shared library for the agent-browser-pool project.
      #
      # Sourced by:
      #   - bin/agent-browser       (the transparent PATH-shadowing wrapper shim)
      #   - bin/agent-browser-pool  (the admin CLI: status / reap / release / doctor)
      #
      # This file is meant to be SOURCED (`. lib/pool.sh` or `source lib/pool.sh`),
      # NOT executed directly. It defines foundational utilities only.
      #
      # Requires: bash >= 4.2 (uses the printf '%(fmt)T' builtin). Hosts run bash 5.x.
      # Strict mode: `set -euo pipefail` below propagates into every caller's shell by design.
      #
      # TODO(later subtasks): owner resolution, acquire/release, reap, copy, Chrome launch.
      #                       This file currently provides ONLY the skeleton + die/log utilities.
      set -euo pipefail

      # Resolve the pool log path to an ABSOLUTE form (PRD §2.2: never use bare ~).
      # Callers/tests may override with POOL_LOG_PATH; otherwise default under the
      # runtime state dir (~/.local/state/agent-browser-pool/). Per PRD §2.11 the
      # state dir is $AGENT_BROWSER_POOL_STATE.
      _pool_log_path() {
          printf '%s\n' "${POOL_LOG_PATH:-${AGENT_BROWSER_POOL_STATE:-${HOME}/.local/state/agent-browser-pool}/pool.log}"
      }

      # pool_die MSG...
      #   Print MSG to stderr and exit non-zero. The canonical error-exit helper.
      pool_die() {
          printf '%s\n' "$*" >&2
          exit 1
      }

      # _pool_log MSG...
      #   Append one "<ISO-8601 timestamp> MSG" line to the pool log (and to stderr).
      #   Uses the builtin printf '%(...)T' (no `date` fork). Creates the log dir
      #   if missing; if the log cannot be written, the line still goes to stderr.
      _pool_log() {
          local msg ts log_path log_dir
          msg="${*:-}"
          # -1 == current time; ISO-8601 with numeric timezone, e.g. 2026-07-12T18:49:04-0400.
          printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
          log_path="$(_pool_log_path)"
          log_dir="${log_path%/*}"
          if [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null; then
              printf '%s %s\n' "$ts" "$msg" >>"$log_path" || printf '%s %s\n' "$ts" "$msg" >&2
          else
              printf '%s %s\n' "$ts" "$msg" >&2
          fi
      }
      ----------------------------------------------------------------
  - NOTE on the helper split: _pool_log_path() is a tiny internal resolver so the
        path-override logic is testable in isolation and stays DRY for later subtasks
        that will reuse it. It is fine to inline it if you prefer fewer functions —
        but keeping it separate matches the "small side-effect-free helpers" research
        recommendation and helps Task 5 testing.
  - DO NOT add: flock wrappers, JSON helpers, owner resolution, Chrome launch,
        anything from later subtasks. Skeleton only.

Task 3: VERIFY sourceability + syntax + shellcheck (do this BEFORE claiming done)
  - RUN: bash -n lib/pool.sh                      # syntax check, no execution
  - RUN: shellcheck lib/pool.sh                   # must be clean
  - RUN: bash -c 'set -euo pipefail; source lib/pool.sh; echo OK'   # expect: OK
  - RUN (subshell, must not kill the harness):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_die boom' ; echo "exit=$?"
        # expect: 'boom' on stderr, 'exit=1' on stdout.
  - RUN (log write):
        tmp=$(mktemp -d)
        POOL_LOG_PATH="$tmp/p.log" bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log hello'
        cat "$tmp/p.log"   # expect one line: '<ISO8601> hello'
        rm -rf "$tmp"
  - FIX any failure before proceeding. All four must pass.

Task 4: DECIDE on .gitignore (no change expected)
  - INSPECT .gitignore: it already has '*.log' and '.state/'.
  - REASON: this subtask introduces NO in-repo log files (the pool's runtime logs live
        outside the repo at ~/.local/state/agent-browser-pool/). The new dirs bin/lib/test/
        hold tracked source, not ignore-able artifacts. Therefore NO .gitignore edit is needed.
  - ACTION: make no change. If, and only if, you discover a stray artifact during Task 3
        (e.g. a *.log written into the repo by accident during testing), add it explicitly —
        but the design prevents that (POOL_LOG_PATH defaults outside the repo).
  - DO NOT add 'plan/', 'PRD.md', or task files to .gitignore (those are orchestrator-owned).
```

### Implementation Patterns & Key Details

```bash
# Pattern A — strict-mode header (MANDATED by contract; do not deviate):
#!/usr/bin/env bash
set -euo pipefail
#   -e         errexit:   abort on uncaught non-zero status
#   -u         nounset:   error on unset variable references (use ${var:-} for optionals)
#   -o pipefail:          pipeline status = rightmost non-zero (catches `false | true`)

# Pattern B — safe error exit (printf over echo; %s\n avoids echo's -n/-e traps):
pool_die() {
    printf '%s\n' "$*" >&2
    exit 1
}
# Usage guard idiom (set -e safe): command -v jq >/dev/null || pool_die "jq is required"

# Pattern C — fork-free ISO-8601 timestamp (bash >= 4.2 builtin; verified on host 5.3):
local ts
printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1     # -1 == current time
# Result example: 2026-07-12T18:49:04-0400

# Pattern D — SC2155-safe local capture (declare, THEN assign):
local log_path
log_path="$(_pool_log_path)"     # NOT:  local log_path="$(_pool_log_path)"   # masks exit status
```

### Integration Points

```yaml
# This subtask has NO runtime integration points — it only creates a sourceable library
# and empty dirs. But it PRE-ESTABLISHES the integration contract every later subtask uses:

LATER-SUBTASK CONTRACT (do not implement now, just honor the names):
  - pool_die and _pool_log MUST keep these exact names so M2–M7 can call them.
  - _pool_log MUST honor POOL_LOG_PATH (tests in M9 override it to a temp file).
  - The lib MUST remain sourceable with zero side effects beyond 'set -euo pipefail'
    and function definitions — M6/M7 will 'source' it at the top of their dispatchers.

CONFIG (established here, consumed later — no file change needed this subtask):
  - env: AGENT_BROWSER_POOL_STATE  (PRD §2.11; default ~/.local/state/agent-browser-pool)
  - env: POOL_LOG_PATH             (test/override hook for _pool_log destination)
  - Both resolved to ABSOLUTE paths at use time (PRD §2.2). Defaults use ${HOME}, never ~.

ROUTES: none (no dispatchers yet — M6/M7 create bin/*).
DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after creating lib/pool.sh — fix before proceeding to Level 2.
bash -n lib/pool.sh                # parse check, no execution. MUST be clean.
shellcheck lib/pool.sh             # MUST report zero issues.
# (No shfmt on this host — formatting is hand-enforced; match the reference block exactly.)
# Expected: zero output / zero errors from both commands.
```

### Level 2: Unit Tests (Component Validation)

There is no test framework yet (bats is not installed; M9.T1.S1 builds the harness). For THIS subtask, validate the two functions with inline shell one-liners (these double as the future regression seed):

```bash
# 2a. Sourceability under strict mode (the core deliverable contract):
bash -c 'set -euo pipefail; source lib/pool.sh; echo OK'
# Expected stdout: OK ; exit 0.

# 2b. pool_die writes to stderr and exits non-zero (subshell isolates the harness):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_die boom' ; echo "exit=$?"
# Expected stderr: boom ; Expected stdout: exit=1 .

# 2c. _pool_log writes exactly one ISO-8601 line to the configured log:
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
POOL_LOG_PATH="$tmp/p.log" bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log hello'
test -s "$tmp/p.log" && echo "log written" || echo "FAIL: no log"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} hello$' "$tmp/p.log" \
  && echo "format OK" || echo "FAIL: bad format"
cat "$tmp/p.log"
# Expected: 'log written', 'format OK', and one line like '2026-07-12T18:49:04-0400 hello'.

# 2d. _pool_log does NOT crash when the state dir does not exist (sourcing must stay safe):
tmp="$(mktemp -d)"; rm -rf "$tmp"; POOL_LOG_PATH="$tmp/nested/missing.log" \
  bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log createdir' ; echo "exit=$?"
rm -rf "$tmp"
# Expected: 'createdir' on stderr (graceful degrade) and exit=0 — sourcing/first-call never fails.

# Expected: all four snippets pass. If any fails, debug root cause (likely SC2155 or a bare ~).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Verify the full repo layout now matches PRD §3:
ls -d bin lib test lib/pool.sh
# Expected: all four paths listed.

# 3b. Verify git will track the new empty dirs (bin/ and test/ have .gitkeep):
git status --porcelain
# Expected: untracked lib/pool.sh, bin/.gitkeep, test/.gitkeep (and nothing unexpected).

# 3c. Verify .gitignore is unchanged and still correct (Task 4 decision):
git diff -- .gitignore
# Expected: empty (no change) — this subtask adds no new ignore-worthy artifact.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the bash builtin timestamp path works on THIS host (research dependency):
printf '%(%Y-%m-%dT%H:%M:%S%z)T\n' -1
# Expected: a line like '2026-07-12T18:49:04-0400'. If this fails, the host bash is < 4.2
#           (architecture doc confirms 5.3, so it will pass).

# 4b. Confirm no stray runtime artifacts were created inside the repo by testing:
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json)$' || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts'.

# (No performance, security-scan, or browser-launch validation applies to this skeleton subtask.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors).
- [ ] Level 2 snippet 2a passes (sourceable under strict mode → prints `OK`).
- [ ] Level 2 snippet 2b passes (`pool_die` → stderr message + exit 1).
- [ ] Level 2 snippet 2c passes (`_pool_log` → one correctly-formatted ISO-8601 line).
- [ ] Level 2 snippet 2d passes (no crash when log dir absent — graceful degrade).

### Feature Validation

- [ ] Directories `bin/`, `lib/`, `test/` exist.
- [ ] `lib/pool.sh` begins with `#!/usr/bin/env bash` then `set -euo pipefail`.
- [ ] File-level comment block documents: purpose, both sourcing binaries, "sourced not executed", min bash version, strict-mode posture.
- [ ] `pool_die()` and `_pool_log()` defined with the exact names and contracts above.
- [ ] NO pool logic present (no owner/acquire/release/reap/copy/launch/flock/JSON).
- [ ] `.gitignore` reviewed; no change made (or a justified change if a stray artifact appeared).

### Code Quality Validation

- [ ] All variable expansions double-quoted (SC2086 clean).
- [ ] All `local` declarations separate from assignments (SC2155 clean).
- [ ] No bare `~` in any path (PRD §2.2); defaults use `${HOME}`.
- [ ] No top-level executable statements beyond `set -euo pipefail` and function definitions.
- [ ] Names match contract: `pool_die` (public), `_pool_log` (internal underscore prefix).

### Documentation & Deployment

- [ ] File header is self-documenting (a reader knows what the file is, who sources it, bash version, strict mode).
- [ ] No new env vars introduced beyond the two pre-specified (`AGENT_BROWSER_POOL_STATE` consumed as default; `POOL_LOG_PATH` as override) — both already in the PRD/intent.
- [ ] `bin/.gitkeep` and `test/.gitkeep` present so the layout commits cleanly.

---

## Anti-Patterns to Avoid

- ❌ Don't omit the `#!/usr/bin/env bash` shebang "because it's only sourced" — the subtask CONTRACT mandates it (it also aids shellcheck/editor hints).
- ❌ Don't use `echo` for `pool_die` — use `printf '%s\n' "$*" >&2` (echo's `-n`/`-e` handling is non-portable).
- ❌ Don't shell out to `date` for the timestamp — use the builtin `printf '%(...)T' -1` (fork-free).
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155 / exit-status masking under `set -e`).
- ❌ Don't use a bare `~` anywhere — resolve `${HOME}` to absolute (PRD §2.2; tilde won't expand in redirections/assignments).
- ❌ Don't let `_pool_log` fail (and thus abort the caller under `set -e`) when the state dir doesn't exist yet — mkdir -p with a stderr fallback.
- ❌ Don't implement any actual pool logic in this subtask — skeleton + two utilities only. Every later subtask (M1.T1.S2 onward) adds the rest.
- ❌ Don't add `plan/`, `PRD.md`, or task files to `.gitignore` — those are orchestrator-owned and must remain visible.
- ❌ Don't blanket-disable shellcheck rules (SC2086, SC2155) to make warnings disappear — fix the code.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: greenfield (nothing to break), small surface area (one file + three dirs), exact reference implementation provided, all validation commands verified executable on the host (`bash -n`, `shellcheck`, `printf '%(...)T'`), and the only contract subtlety (strict-mode leak + SC2155 + no-bare-`~`) is explicitly called out with copy-pasteable correct code. The -1 reflects that the implementer could still fumble the `_pool_log` graceful-degrade path (snippet 2d) if they skip reading the gotchas — the Level 2 tests will catch it immediately.
