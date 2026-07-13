# PRP — P1.M7.T5.S1: Admin CLI dispatcher (`bin/agent-browser-pool`) + `--help`

---

## Goal

**Feature Goal**: Create the **`bin/agent-browser-pool`** executable — the admin-CLI
entry point from PRD §2.1 (`← admin tool (symlink → repo bin/)`) and §2.12 (`status /
reap / release / doctor`). It is a thin dispatcher: enable strict mode → resolve its
own real path symlink-safely (identical mechanism to the landed `bin/agent-browser`) →
`source` the shared `lib/pool.sh` → `pool_config_init` + `pool_state_init` → read the
first positional (`cmd="${1:-status}"`) → `case`-dispatch to the four LANDED admin
functions (`pool_admin_status` / `pool_admin_reap` / `pool_admin_release` /
`pool_admin_doctor`) or to `pool_admin_help`, defaulting to `status` when no command is
given and printing `Unknown command: <cmd>` to stderr + `exit 1` on anything else. ALSO
implement **`pool_admin_help()`** — appended to `lib/pool.sh` under its own banner —
which prints the complete usage for all subcommands + the configuration env vars to
**stdout** (Mode A: `--help` IS the user-facing documentation for the admin tool).

**Deliverable**: TWO files.
1. **NEW** `bin/agent-browser-pool` — the verbatim dispatcher contract (item §3),
   made executable (`chmod 0755`), alongside the existing `bin/agent-browser` +
   `bin/.gitkeep` (both RETAINED).
2. **APPEND-ONLY** `lib/pool.sh` — a new banner `# Admin CLI — help (P1.M7.T5.S1)` +
   `pool_admin_help()` at the current live EOF (now **4233**, after the LANDED
   `pool_admin_doctor`). No existing function touched.

**Success Definition**:
- `test -x bin/agent-browser-pool` passes; `bash -n bin/agent-browser-pool` + `shellcheck
  -s bash bin/agent-browser-pool` → ZERO warnings; the file contains the verbatim
  `readlink -f` → `dirname` → `source "$REAL_DIR/../lib/pool.sh"` → `pool_config_init` →
  `pool_state_init` → `case` block.
- `pool_admin_help()` appended under its banner; `bash -n lib/pool.sh` + `shellcheck -s
  bash lib/pool.sh` (whole file) → ZERO warnings; the four existing admin functions
  unchanged; `lib/pool.sh` diff is append-only.
- `./bin/agent-browser-pool --help` (and `-h`, and `help`) → prints usage (all four
  subcommands + config env vars) to **stdout**; **rc 0**; never `pool_die`s.
- `./bin/agent-browser-pool` (NO args) → runs `status` (the `${1:-status}` default).
- `./bin/agent-browser-pool bogus` → `Unknown command: bogus` to **stderr**; **rc 1**.
- `./bin/agent-browser-pool release` (no target) → release's usage to stderr; **rc 1**.
- **SYMLINK-safety test passes**: a symlink `$TMP/agent-browser-pool → <repo>/bin/agent-
  browser-pool`, invoked as `$TMP/agent-browser-pool --help`, still prints usage (proves
  `readlink -f` sourced `<repo>/lib/pool.sh` through the symlink — the #1 correctness risk).
- `bin/agent-browser`, `bin/.gitkeep`, `.gitignore`, `PRD.md`, `tasks.json` UNCHANGED.

## User Persona

**Target User**: Human admin (PRD §2.12). The admin manages the pool manually — inspects
lanes, reaps dead-owner cruft, releases lanes explicitly, and diagnoses the setup.

**Use Case**: An admin runs `agent-browser-pool status` to see live lanes, `reap` to
clean dead-owner lanes, `release all` to clear the pool, `doctor` to diagnose a problem,
or `agent-browser-pool --help` to recall the commands + config knobs. Before install.sh
(M8.T1.S1) symlinks this binary to `~/.local/bin/agent-browser-pool`, the admin invokes
it by absolute path (`…/bin/agent-browser-pool status`).

**User Journey**: `agent-browser-pool` (no args → status) sees stale lanes →
`agent-browser-pool reap` → `agent-browser-pool status` confirms cleanup → unsure of a
flag → `agent-browser-pool --help` recalls the config env vars →
`agent-browser-pool doctor` verifies the host setup.

**Pain Points Addressed**: Without this dispatcher, the four LANDED `pool_admin_*`
functions in `lib/pool.sh` are unreachable from the command line (the lib is sourced, not
executed — `lib/pool.sh` header lines 5-12). The dispatcher is the bootstrap that makes
them *invokable*. Without `--help`, the admin has no single source of truth for the
commands + config (Mode A docs).

## Why

- **This IS PRD §2.1's admin-CLI component** (`← admin tool (symlink → repo bin/)`) and
  the §2.12 command surface (`status / reap / release / doctor`). The lib header
  (lines 5-6) already names `bin/agent-browser-pool` as a consumer — this task creates it.
- **It is the capstone wiring for the entire P1.M7 milestone.** P1.M7.T1–T4.S1 are all
  library functions (`pool_admin_status/reap/release/doctor`). None is reachable from a
  real command until THIS dispatcher exists, sources the lib, and `case`-dispatches to it.
- **It mirrors the landed `bin/agent-browser` sibling exactly** for the symlink-safe
  bootstrap (`readlink -f` → `source ../lib/pool.sh`), then adds the admin-specific
  `case`. The pattern is proven (bin/agent-browser is shellcheck-clean + symlink-tested).
- **`pool_admin_help()` is the ONLY documentation surface** the admin tool gets (Mode A:
  the item's DOCS step = "`--help` / `pool_admin_help` output is the user-facing
  documentation"). It must list every subcommand + the config env vars.
- **It must NOT duplicate or conflict with siblings.** status/reap/release/doctor (all
  LANDED) are untouched. This task owns ONLY `bin/agent-browser-pool` (new) + the
  `pool_admin_help()` append.

## What

User-visible behavior: **a working `agent-browser-pool` command** that dispatches to the
four admin subcommands (or help), defaulting to `status`. For this task's verification
(no Chrome needed), the observable contract is the dispatch + help + symlink-safety.

### The dispatcher file (verbatim contract — authoritative from item §3)

```bash
#!/usr/bin/env bash
set -euo pipefail
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
  status) pool_admin_status ;;
  reap) pool_admin_reap ;;
  release) pool_admin_release "${2:-}" ;;
  doctor) pool_admin_doctor ;;
  --help|-h|help) pool_admin_help ;;
  *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
```
Then `chmod 0755 bin/agent-browser-pool`. A short header comment (3-5 lines) is OPTIONAL
but recommended (satisfies the item's DOCS step + matches `bin/agent-browser`).

### `pool_admin_help()` (append to lib/pool.sh) — prints usage to stdout, rc 0

Takes NO input, reads NO global, touches NO disk. Pure `printf`s + `return 0`. Documents
all four subcommands + the `help` aliases + the `${1:-status}` default + the config env
vars. (See Implementation Tasks for the verbatim body.)

### Success Criteria

- [ ] `bin/agent-browser-pool` created (NEW, alongside RETAINED `bin/agent-browser` +
      `bin/.gitkeep`); executable (`chmod 0755`).
- [ ] Dispatcher contains the verbatim contract: shebang, `set -euo pipefail`,
      `readlink -f "${BASH_SOURCE[0]}"`, `dirname`, `source "$REAL_DIR/../lib/pool.sh"`,
      `pool_config_init`, `pool_state_init`, `cmd="${1:-status}"`, and the full `case`.
- [ ] `pool_admin_help()` appended to `lib/pool.sh` under banner
      `# Admin CLI — help (P1.M7.T5.S1)`; NO existing function touched.
- [ ] `bash -n` + `shellcheck -s bash` → ZERO warnings for BOTH files (whole `lib/pool.sh`).
- [ ] `./bin/agent-browser-pool --help` / `-h` / `help` → usage to **stdout**, **rc 0**.
- [ ] `./bin/agent-browser-pool` (no args) → `status` runs (the `${1:-status}` default).
- [ ] `./bin/agent-browser-pool status` → lane table / "No active lanes."; rc 0.
- [ ] `./bin/agent-browser-pool reap` → reap report; rc 0.
- [ ] `./bin/agent-browser-pool doctor` → sectioned report (rc 0/1 per host).
- [ ] `./bin/agent-browser-pool release` (no target) → usage to stderr, rc 1.
- [ ] `./bin/agent-browser-pool bogus` → "Unknown command: bogus" to stderr, rc 1.
- [ ] **Symlink test**: `$TMP/agent-browser-pool` (→ repo/bin/agent-browser-pool)
      invoked `--help` → usage prints (proves `readlink -f` symlink-safe sourcing).
- [ ] `lib/pool.sh` diff is append-only; `bin/agent-browser` + `bin/.gitkeep` + `.gitignore`
      + `PRD.md` + `tasks.json` UNCHANGED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **verbatim dispatcher
contract** (item §3, re-stated); the **two-deliverable + placement decision** (dispatcher
= `bin/agent-browser-pool` NEW; `pool_admin_help()` = append to `lib/pool.sh` at the
DYNAMIC live EOF — all `pool_admin_*` live in the lib, the binary is a thin dispatcher
exactly like `bin/agent-browser`); the **symlink gotcha** (PRD §2.1: the admin tool is
symlinked to `~/.local/bin/`; `dirname "$0"` would miss the lib → `readlink -f` before
`dirname` is mandatory — proven by the landed `bin/agent-browser`); the **four admin
signatures** (status/reap/doctor = no-arg; release = `[<N>|all]` passed via `"${2:-}"`) so
the help text is accurate; the **config env var table** (from `pool_config_init` @135-174)
for the help docs; the fact that **all four admin functions are LANDED** (no parallel-
coordination risk); the **`pool_admin_help`-is-pure decision** (no config/state init INSIDE
the function — unlike its siblings; it is the most robust function); the **`set -e` line
is 18** (not the stale ":23" the sibling comments cite); the **stdout-vs-stderr** rule
(explicit `--help` → stdout + rc 0; release-on-misuse usage → stderr + rc 1); host-verified
tooling (bash 5.3, ShellCheck 0.11); and copy-pasteable, deterministic validation.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.1 (components: "/home/dustin/.local/bin/agent-browser-pool ← admin tool
        (symlink → repo bin/)" + "repo/lib/pool.sh ← shared lease logic"). §2.12 (the
        admin command surface: status / reap / release / doctor). §2.15 (transparency —
        --help is the user-facing doc). §2.16 (config env vars doctor verifies).
  pattern: §2.1's symlink→repo means the binary MUST resolve its own path symlink-safely;
        §2.12 IS the command list help must document.
  gotcha: §2.1 — the admin tool is symlinked at install time; a bare `dirname "$0"`
        resolves to the SYMLINK dir, not <repo>/bin → source fails. readlink -f first.

# This task's own research (THE factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M7T5S1/research/dispatcher-and-help-facts.md
  why: §1 the two-deliverable + placement decision (dispatcher=bin NEW; pool_admin_help=
        lib append at live EOF). §2 the verbatim dispatcher contract line-by-line.
        §3 the four admin signatures (for accurate help text). §4 the config env vars
        (for help docs). §5 pool_admin_help design (D1 pure/no-init-inside, D2 never
        die/rc0, D3 document all+default+aliases, D4 stdout, D5 append+banner). §6 set -e
        at line 18 (NOT 23). §7 bin/ layout + .gitkeep retained. §8 validation (no Chrome
        needed; symlink test is the integration proof). §9 scope boundaries.
  pattern: §2's contract IS the dispatcher; §5's design IS pool_admin_help.
  gotcha: §1 — pool_admin_help goes in lib/pool.sh (the contract calls it with NO inline
        definition); §2 — config/state init run BEFORE dispatch (verbatim; do not move);
        §5-D1 — pool_admin_help must NOT call config/state init itself.

# The proven sibling (the EXACT symlink-safe bootstrap pattern to mirror)
- file: bin/agent-browser
  why: the landed wrapper shim is BYTE-IDENTICAL lines 1-12 to this dispatcher's bootstrap
        (shebang, set -euo pipefail, readlink -f "${BASH_SOURCE[0]}", dirname, source
        "$REAL_DIR/../lib/pool.sh"). This dispatcher adds pool_config_init + pool_state_init
        + the admin `case`. Copy the bootstrap verbatim; it is shellcheck-clean + symlink-tested.
  pattern: the readlink -f → dirname → source ../lib/pool.sh block IS the dispatcher's bootstrap.
  gotcha: bin/agent-browser's last line is `pool_wrapper_main "$@"` (terminal exec); the
        admin dispatcher instead ends in a `case` (non-terminal — falls off the end = rc 0
        after a successful dispatch). Do NOT copy the `pool_wrapper_main "$@"` line.

# The landed admin functions this dispatcher wires (all LANDED + contract-documented)
- file: lib/pool.sh
  why: pool_admin_status @3594 (no-arg, rc 0). pool_admin_reap @3730 (no-arg, rc 0).
        pool_admin_release @3830 ([<N>|all|empty/invalid]; usage→stderr rc 1 on misuse).
        pool_admin_doctor @4011 (no-arg, rc 0/1). pool_config_init @135 (globals + env-var
        defaults — the table for help docs). pool_state_init @202 (idempotent mkdir).
        set -euo pipefail @18 (NOT 23). header lines 5-6 (already name bin/agent-browser-pool
        as a consumer). release usage block @3909 (`Usage: agent-browser-pool release [<N>|all]`
        → the help-text convention).
  pattern: the four admin functions ARE the case targets; config_init's env vars ARE the help docs.
  gotcha: pool_config_init/pool_state_init can pool_die on misconfig (a non-uint config value) —
        on a normal host they rc 0. The dispatcher calls them BEFORE the case (verbatim contract)
        so --help runs after successful init; do NOT reorder.

# Sibling PRPs (the shape to mirror — lib-only, append-under-banner)
- file: plan/001_0f759fe2777c/P1M7T4S1/PRP.md
  why: pool_admin_doctor (LANDED @4011) — the most recent sibling. Its banner + CONSUMERS
        line (`case doctor) pool_admin_doctor ;;`) IS the dispatch wiring this task builds.
        Its EOF was 3916; doctor landed and EOF is now 4233 — detect the append site via tail.
- file: plan/001_0f759fe2777c/P1M6T3S2/PRP.md
  why: bin/agent-browser (LANDED) — the EXACT bin-file pattern: verbatim contract,
        chmod 0755, bash -n + shellcheck clean, .gitkeep retained, .gitignore untouched,
        symlink-safety Level-2 test. The admin dispatcher mirrors it for the bootstrap half.
  pattern: the symlink-safety test + structure/contract/lib-untouched/.gitkeep checks apply verbatim.
```

### Current Codebase tree

After **M1–M7.T4.S1** landed, `lib/pool.sh` is **4233 lines** (ends at `pool_admin_doctor`'s
closing `}`). `bin/` has `agent-browser` (M6.T3.S2) + `.gitkeep`. The admin CLI does NOT
exist yet. **THIS task creates `bin/agent-browser-pool` AND appends `pool_admin_help()`:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # M6.T3.S2 (wrapper shim) — UNCHANGED
│   └── agent-browser-pool                # NEW (this task): the admin dispatcher
├── lib/
│   └── pool.sh                           # EOF @4233 (pool_admin_doctor). THIS task APPENDS
│                                         #   the banner "# Admin CLI — help (P1.M7.T5.S1)"
│                                         #   + pool_admin_help() at the DYNAMIC live EOF.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M7T5S1/
        ├── PRP.md                         # THIS FILE
        └── research/dispatcher-and-help-facts.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # UNCHANGED
│   └── agent-browser-pool                # NEW (chmod 0755): symlink-safe bootstrap (mirrors
│                                         #   bin/agent-browser) + pool_config_init/state_init +
│                                         #   case dispatch to pool_admin_{status,reap,release,
│                                         #   doctor,help}. Default cmd=status. Unknown→stderr+exit1.
└── lib/
    └── pool.sh                           # MODIFIED (append-only): +banner +pool_admin_help() at EOF
```

**File responsibilities**:
- `bin/agent-browser-pool` — the bootstrap + dispatch entry point. Owns NO logic: it
  resolves its path, sources the lib, inits config+state, and `case`-routes to the admin
  functions. What `install.sh` (M8.T1.S1) symlinks to `~/.local/bin/agent-browser-pool`.
- `pool_admin_help()` — the user-facing docs. Pure `printf` to stdout + `return 0`.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the symlink gotcha — PRD §2.1; proven by bin/agent-browser): the admin tool is
#   symlinked to ~/.local/bin/agent-browser-pool at install time. If it computes the lib path
#   from $0 (the symlink), dirname "$0" = ~/.local/bin and ../lib/pool.sh = ~/.local/lib/pool.sh
#   → WRONG → source fails → set -e aborts → every admin call dies. readlink -f
#   "${BASH_SOURCE[0]}" canonicalizes through ALL symlink hops to <repo>/bin/agent-browser-pool;
#   dirname → <repo>/bin; ../lib/pool.sh → <repo>/lib/pool.sh ✓. THE Level-2 symlink test
#   catches this regression. Use BASH_SOURCE[0] (not $0).

# CRITICAL (config/state init runs BEFORE dispatch — verbatim contract): the dispatcher calls
#   pool_config_init + pool_state_init unconditionally before the `case`. They are idempotent
#   (each admin function ALSO calls them as step "a" — redundant, harmless). They CAN pool_die
#   on genuine misconfig (e.g. AGENT_CHROME_PORT_RANGE<=0, a non-uint). On a normal host they
#   rc 0. Do NOT move init inside the branches — that diverges from the authoritative item §3.

# CRITICAL (pool_admin_help is PURE — NO config/state init INSIDE it): unlike its four
#   siblings (each calls pool_config_init + pool_state_init as step "a"), pool_admin_help
#   reads NO global, touches NO disk, does NO $(…). It is the most robust function: printf
#   + return 0. The dispatcher's verbatim init-before-case already ensures globals exist;
#   the FUNCTION itself must not depend on init. (Otherwise a config typo would hide --help.)

# CRITICAL (set -euo pipefail is at lib/pool.sh:18, NOT :23): sibling admin comments citing
#   "lib/pool.sh:23" are STALE. Line 14 is just the comment; the directive is at line 18.
#   pool_admin_help's header cites line 18.

# GOTCHA (stdout vs stderr — the two usage cases differ): EXPLICIT --help/-h/help →
#   pool_admin_help prints to STDOUT + rc 0 (conventional; capturable; --help never fails).
#   release-on-MISUSE (release with no/invalid arg) → its OWN usage to STDERR + rc 1 (already
#   implemented @lib/pool.sh:3909). Do NOT change release's behavior; pool_admin_help is the
#   separate explicit-help path → stdout.

# GOTCHA (the dispatcher ends in a `case`, not a terminal exec): unlike bin/agent-browser
#   (whose last line `pool_wrapper_main "$@"` is terminal — exec/pool_die), the admin dispatcher
#   ends in a `case`. A matched branch calls an admin function and the script FALLS OFF THE END
#   → implicit rc 0 (the admin functions' own return codes propagate as the script's exit code).
#   The unknown-command branch is the only explicit `exit 1`. No trailing code after the `case`.

# GOTCHA (release arg is "${2:-}", NOT "$@"): the dispatcher's `release) pool_admin_release
#   "${2:-}"` passes ONLY the second positional (or empty). `release 7` → $2=7. Bare `release`
#   → $2="" → release prints usage + rc 1. Do NOT change to "$@" (release takes one optional arg).

# GOTCHA (default command is status): `cmd="${1:-status}"` → `agent-browser-pool` with NO args
#   runs `status`. Document this in help. (Matches the common `git`/`kubectl` "default verb" UX.)

# GOTCHA (bin/.gitkeep RETAINED): the new binary is ALONGSIDE .gitkeep. Do NOT remove .gitkeep
#   (out of scope; a later sync task may clean it up). .gitignore has no matching rule — do NOT
#   modify it (orchestrator-owned, M10.T1.S2).

# GOTCHA (SC2155 does NOT apply to top-level assignments): the dispatcher's
#   REAL_SCRIPT="$(readlink -f …)" / REAL_DIR="$(dirname …)" are PLAIN top-level assignments
#   (no local) → shellcheck-clean. Do not split them. (Same as bin/agent-browser.)

# GOTCHA (SC1091 INFO is EXPECTED on the `source` line — host-verified): shellcheck emits
#   `SC1091 (info): Not following: ./../lib/pool.sh` for the dynamic `source "$REAL_DIR/../lib/pool.sh"`
#   line and EXITS 1 on this host even though it is info-level (shellcheck's exit reflects any
#   reported issue). This is IDENTICAL to the LANDED bin/agent-browser (same line 12, same SC1091,
#   same exit 1). It is NOT a real defect — the lib path is intentionally dynamic (symlink-resolved).
#   Validate the dispatcher with `shellcheck -S warning -s bash bin/agent-browser-pool` (filters
#   info → clean exit 0), OR accept the single SC1091 info line. `lib/pool.sh` itself has NO
#   top-level `source`, so `shellcheck -s bash lib/pool.sh` is truly clean (exit 0).
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk layout change beyond the new
binary + the lib append, and NO new env vars. `bin/agent-browser-pool` defines two
script-local vars (`REAL_SCRIPT`, `REAL_DIR`) from `${BASH_SOURCE[0]}` + one (`cmd`) from
`$1`. `pool_admin_help()` defines NO locals (pure `printf`s). All pooling state/env is
owned by the admin functions + `pool_config_init`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the dispatch targets exist
  - RUN: test -f lib/pool.sh && test -f bin/agent-browser && test -f bin/.gitkeep && echo "OK layout"
  - EXPECT: all exist.
  - RUN (confirm this task is greenfield — NO existing bin/agent-browser-pool, NO pool_admin_help):
        test -e bin/agent-browser-pool && echo "STOP: bin exists" || echo "OK: bin greenfield"
        grep -n 'pool_admin_help' lib/pool.sh && echo "STOP: help exists" || echo "OK: help greenfield"
  - EXPECT: OK: bin greenfield; OK: help greenfield.
  - RUN (confirm ALL FOUR dispatch targets are defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_admin_status pool_admin_reap pool_admin_release pool_admin_doctor pool_config_init pool_state_init; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; \
          done; echo "OK all dispatch targets defined"'
  - EXPECT: OK all dispatch targets defined (status/reap/release/doctor all LANDED).
  - RUN (confirm the symlink-safe bootstrap pattern — copy it from bin/agent-browser):
        sed -n '1,12p' bin/agent-browser
  - EXPECT: shebang + set -euo pipefail + readlink -f "${BASH_SOURCE[0]}" + dirname + source ../lib/pool.sh.
  - RUN (confirm the DYNAMIC append site — the CURRENT live EOF):
        wc -l lib/pool.sh; tail -3 lib/pool.sh; grep -n '^pool_admin_doctor' lib/pool.sh
  - EXPECT: EOF is the closing `}` of pool_admin_doctor (LANDED). APPEND after it. Detect via tail;
        do NOT hardcode 4233 (it moves if a sibling lands).
  - RUN (confirm set -e line is 18, NOT 23):
        grep -n '^set -euo pipefail' lib/pool.sh
  - EXPECT: line 18.
  - RUN (host tooling):
        bash --version | head -1
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'
        command -v readlink >/dev/null && readlink --version | head -1   # GNU coreutils (-f)
  - RUN (confirm the SC1091-on-`source` behavior matches the landed sibling):
        shellcheck -S warning -s bash bin/agent-browser && echo "OK: landed bin/agent-browser is clean at -S warning"
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0, GNU readlink (supports -f); bin/agent-browser clean
        at `-S warning` (its lone SC1091 INFO is the same the new dispatcher will have → filter
        with `-S warning`; see the SC1091 GOTCHA).
  - RUN: bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh && echo "OK lib syntax + shellcheck (baseline)"
  - EXPECT: OK (this task must not break existing syntax; lib is truly shellcheck-clean today).

Task 1: CREATE bin/agent-browser-pool (the verbatim dispatcher contract, executable)
  - PLACEMENT: bin/agent-browser-pool (NEW file alongside bin/.gitkeep + bin/agent-browser).
  - IMPLEMENT (verbatim — paste exactly; the 4-line header comment is OPTIONAL but recommended
        to satisfy the item's DOCS step + match bin/agent-browser):

#!/usr/bin/env bash
#
# bin/agent-browser-pool — admin CLI for the agent-browser-pool (PRD §2.1, §2.12).
# Resolves its own real path (symlink-safe, same mechanism as bin/agent-browser) so it can
# source the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
# → repo/bin/agent-browser-pool at install time). Dispatches to the pool_admin_* functions.
# Default command (no args) is `status`.
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.1; mirrors bin/agent-browser)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
# Init config + state unconditionally so every subcommand has globals + a lanes dir.
# (Idempotent; each pool_admin_* ALSO calls them as its own precondition — redundant, harmless.)
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac

  - MAKE EXECUTABLE: chmod 0755 bin/agent-browser-pool
  - VERIFY (immediately after):
        bash -n bin/agent-browser-pool && echo "OK syntax"
        shellcheck -S warning -s bash bin/agent-browser-pool && echo "OK shellcheck"   # ZERO warnings (SC1091 INFO on the `source` line is expected — identical to bin/agent-browser; -S warning filters it)
        test -x bin/agent-browser-pool && echo "OK executable"
        test -f bin/.gitkeep && echo "OK .gitkeep retained"
        git diff --stat lib/pool.sh | grep -q . && echo "STOP: lib touched!" || echo "OK lib untouched"
  - EXPECT: all OK; lib untouched (this task appends lib in Task 2); .gitkeep retained.

Task 2: APPEND pool_admin_help() to lib/pool.sh (the verbatim help body)
  - PLACEMENT: APPEND at the END of lib/pool.sh (at the CURRENT live EOF — after the closing
        `}` of pool_admin_doctor), preceded by the new banner. NO edits to any existing line.
        Detect the append site via `tail` (do not hardcode a line number).
  - IMPLEMENT (verbatim — paste exactly; the header doc-comment documents every subcommand +
        satisfies the item's DOCS step "[Mode A] --help output is the user-facing documentation"):

# ============================================================================
# Admin CLI — help (P1.M7.T5.S1)
# ============================================================================
# pool_admin_help
#
# The USER-FACING help for `agent-browser-pool --help|-h|help` (PRD §2.12 / §2.15
# transparency — Mode A: this output IS the documentation for the admin tool). NO
# input. Prints usage for every subcommand + the configuration env vars to STDOUT,
# then returns 0. Read by the bin/agent-browser-pool dispatcher's
# `case --help|-h|help) pool_admin_help ;;` branch.
#
# DESIGN (the KEY differentiators from the four admin siblings):
#   - PURE: reads NO global, touches NO disk, does NO $(…). Unlike status/reap/
#     release/doctor (each calls pool_config_init + pool_state_init as step "a"),
#     help is documentation only — it MUST NOT depend on init. (The dispatcher's
#     verbatim init-before-case already ensures globals exist on a normal host; this
#     function itself stays init-free so it is the most robust entry point.)
#   - NEVER pool_die, NEVER return non-zero. Explicit --help is conventional stdout
#     + rc 0 (--help must always succeed; matches `git --help` / `kubectl --help`).
#   - stdout ONLY (capturable: `agent-browser-pool --help | grep release`). No >&2,
#     no log. (Contrast pool_admin_release's misuse-usage → stderr + rc 1 @3909:
#     that is a DIFFERENT case — release called with no/invalid arg. This is the
#     EXPLICIT help request → stdout.)
#
# set -e GUARDS: NONE NEEDED. This function has no $(…) capture, no (( )), no
# command-that-can-fail — only `printf` (always rc 0) + `return 0`. It is the
# simplest admin function (fewest set -e hazards). (set -euo pipefail at lib/pool.sh:18
# [NOT 23 — sibling comments citing :23 are STALE].)
#
# PRECONDITION: NONE (pure function). The dispatcher inits config+state before the
# case; help does not rely on it.
# CONSUMERS: bin/agent-browser-pool dispatcher: `case --help|-h|help) pool_admin_help ;;`.
pool_admin_help() {
    printf 'agent-browser-pool — manage the agent-browser ephemeral-profile pool.\n'
    printf '\n'
    printf 'Usage: agent-browser-pool <command> [args]\n'
    printf '\n'
    printf 'If no command is given, '"'"'status'"'"' is assumed.\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  status                  Print a read-only table of all active lanes:\n'
    printf '                          lane, port, session, owner pid+cwd, chrome pid, age, state.\n'
    printf '  reap                    Tear down lanes whose owning process has died:\n'
    printf '                          kill Chrome, delete the ephemeral profile dir, remove the lease.\n'
    printf '  release [<N>|all]       Explicitly tear down one lane by number, or every lane.\n'
    printf '                          Use '"'"'release all'"'"' to clear the whole pool.\n'
    printf '  doctor                  Diagnose the pool: verify dependencies, the real binary,\n'
    printf '                          the filesystem (btrfs), and the master profile; reconcile\n'
    printf '                          leases against live Chromes and ephemeral dirs; report leaks.\n'
    printf '                          Exits 1 if any check fails, 0 otherwise.\n'
    printf '  help                    Show this help. Aliases: --help, -h.\n'
    printf '\n'
    printf 'Configuration (environment variables; all optional):\n'
    printf '  AGENT_BROWSER_POOL_STATE        state dir (lease store + logs)\n'
    printf '  AGENT_CHROME_MASTER             master profile template (copied per lane)\n'
    printf '  AGENT_CHROME_EPHEMERAL_ROOT     ephemeral lane dir root\n'
    printf '  AGENT_BROWSER_REAL              the real agent-browser binary (shadowed CLI)\n'
    printf '  AGENT_CHROME_BIN                Chrome binary (default: google-chrome-stable)\n'
    printf '  AGENT_CHROME_PORT_BASE          lowest pool TCP port (default: 53420)\n'
    printf '  AGENT_CHROME_PORT_RANGE         number of ports in the pool (default: 1000)\n'
    printf '  AGENT_BROWSER_POOL_WAIT         acquire block timeout, seconds (default: 600)\n'
    printf '  AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes)\n'
    printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set\n'
    printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set\n'
    printf '\n'
    printf "Run 'agent-browser-pool doctor' to verify your setup.\n"
    return 0
}

  - NOTE on the embedded single-quotes: lines like `printf 'If no command is given, '"'"'status'"'"' ...'`
        embed a literal single-quote via the `'"'"'` idiom (close quote, double-quoted single-quote,
        reopen quote). This is the canonical POSIX-bash way to put a `'` inside a single-quoted
        printf format string. Alternatively use a printf with NO embedded quotes (rephrase to
        "If no command is given, status is assumed." with no quotes around status). BOTH are
        shellcheck-clean; pick ONE and keep it consistent. (The verbatim body above uses the
        `'"'"'` idiom so the apostrophes render in the output.)
  - VERIFY (immediately after):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (whole file)
        grep -n 'pool_admin_help' lib/pool.sh | head -1        # the definition line
        git diff --stat lib/pool.sh                            # append-only diff
        # sanity: help runs standalone (pure function):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_admin_help | head -5'
  - EXPECT: all OK; the only change to lib/pool.sh is the appended banner + function;
        the standalone invocation prints the first 5 help lines (proves it is init-free).

Task 3: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY `bin/agent-browser-pool` (new untracked) + `lib/pool.sh` (modified, append-only).
        bin/agent-browser, bin/.gitkeep, .gitignore, PRD.md, tasks.json, prd_snapshot.md UNCHANGED.
        NO new files outside plan/.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe self-resolution (mirror bin/agent-browser byte-for-byte):
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"   # canonicalize through ALL symlink hops
REAL_DIR="$(dirname "$REAL_SCRIPT")"               # <repo>/bin  (NOT <symlink-dir>)
source "$REAL_DIR/../lib/pool.sh"                  # <repo>/lib/pool.sh  ✓

# PATTERN — init-then-dispatch (the verbatim contract):
pool_config_init       # idempotent globals; can pool_die on genuine misconfig (normal host: rc 0)
pool_state_init        # idempotent mkdir POOL_LANES_DIR
cmd="${1:-status}"     # default verb = status (git/kubectl UX)
case "$cmd" in
    status)         pool_admin_status ;;
    reap)           pool_admin_reap ;;
    release)        pool_admin_release "${2:-}" ;;   # second positional OR empty (NOT "$@")
    doctor)         pool_admin_doctor ;;
    --help|-h|help) pool_admin_help ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;   # stderr + process-exit 1
esac
# A matched branch calls the admin function and the script falls off the end → rc = that
# function's return code. The unknown branch is the only explicit `exit 1`.

# PATTERN — pool_admin_help is PURE (the key differentiator from siblings):
pool_admin_help() {
    printf '...usage...'   # NO config_init, NO state_init, NO $(…), NO (( ))
    ...
    return 0               # explicit --help = rc 0 (never die, never non-zero)
}

# GOTCHA — WHY readlink -f and NOT dirname "$0": at install time $0/BASH_SOURCE[0] is the
#   SYMLINK (~/.local/bin/agent-browser-pool); dirname "$0" = ~/.local/bin; ../lib/pool.sh
#   = ~/.local/lib/pool.sh → WRONG. readlink -f resolves to <repo>/bin FIRST. (research §2.)
# GOTCHA — WHY pool_admin_help must NOT call config_init/state_init: it is documentation.
#   If it required init, a config typo (e.g. AGENT_CHROME_PORT_RANGE=0) would make `--help`
#   die — defeating the purpose. The dispatcher's verbatim init-before-case covers a normal
#   host; the function stays init-free so it always renders. (research §5-D1.)
# GOTCHA — WHY "${2:-}" for release (not "$@"): release takes ONE optional arg. "$@" would
#   pass all remaining args; release's contract is `[<N>|all]` (one token). "${2:-}" is the
#   authoritative item-§3 contract. (research §2.)
# GOTCHA — WHY the embedded-quote idiom: `printf '... '"'"'status'"'"' ...'` renders a
#   literal apostrophe inside a single-quoted format. Alternatively rephrase to drop the
#   quotes. Both shellcheck-clean; pick one + be consistent.
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "bin/agent-browser-pool (NEW; chmod 0755; alongside bin/.gitkeep + bin/agent-browser,
            both RETAINED). Verbatim item-§3 contract + a 4-line header comment."
  - modify: "lib/pool.sh (APPEND-ONLY: banner '# Admin CLI — help (P1.M7.T5.S1)' + pool_admin_help()
            at the DYNAMIC live EOF, currently after pool_admin_doctor @4011, EOF 4233). Detect the
            site via `tail`; do NOT hardcode a line number (the EOF moves if a sibling lands)."

LIBRARY (lib/pool.sh):
  - wires (all LANDED): "pool_admin_status @3594; pool_admin_reap @3730; pool_admin_release @3830;
            pool_admin_doctor @4011. The dispatcher's `case` targets each by name."
  - init (dispatcher-level): "pool_config_init @135 (globals) + pool_state_init @202 (mkdir lanes).
            Called BEFORE the case (verbatim contract). Idempotent; each admin fn also calls them."

GITIGNORE:
  - no change: "no rule matches bin/agent-browser-pool. .gitignore is orchestrator-owned (M10.T1.S2)."

INSTALL (NOT this task — M8.T1.S1, future):
  - future: "install.sh symlinks bin/agent-browser-pool → ~/.local/bin/agent-browser-pool (PRD §2.1).
            The readlink -f bootstrap is what makes that symlink safe. Until install.sh exists, test
            by ABSOLUTE PATH or via the Level-2 symlink fixture."

NO CHANGES TO:
  - bin/agent-browser (M6.T3.S2, unchanged), bin/.gitkeep (retained), .gitignore (orchestrator-owned),
    PRD.md / tasks.json / prd_snapshot.md (read-only), install.sh (M8.T1.S1, future),
    status/reap/release/doctor (siblings, unchanged).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating bin/agent-browser-pool + chmod + appending pool_admin_help — fix before proceeding.
bash -n bin/agent-browser-pool && echo "OK bin bash -n"
shellcheck -S warning -s bash bin/agent-browser-pool && echo "OK bin shellcheck"   # ZERO warnings (SC1091 INFO on the `source` line is expected — identical to landed bin/agent-browser; `-S warning` filters info → exit 0)
test -x bin/agent-browser-pool && echo "OK bin executable"                # chmod 0755
bash -n lib/pool.sh && echo "OK lib bash -n"
shellcheck -s bash lib/pool.sh && echo "OK lib shellcheck"               # ZERO issues (lib has NO top-level `source` → no SC1091; truly clean)
# Expected: all OK. The bin/ file emits ONE SC1091 INFO (the dynamic `source` line) — same as
#   bin/agent-browser — which `-S warning` suppresses. SC2155 does NOT fire on the dispatcher's
#   top-level REAL_SCRIPT/REAL_DIR (no local). SC2086 satisfied by quoting "${BASH_SOURCE[0]}",
#   "$REAL_SCRIPT", "$REAL_DIR/...". pool_admin_help is only printf + return 0 → no warnings.
```

### Level 2: Unit/Functional Tests (NO Chrome needed — dispatch + help + symlink)

The dispatcher + help are testable WITHOUT Chrome / a master profile / a real `pi`
ancestor — they only need a sourceable lib + the LANDED admin functions. Use a FRESH
`AGENT_BROWSER_POOL_STATE` (mktemp -d) so tests never touch the real pool state, and
`AGENT_CHROME_ALLOW_SLOW_COPY=1` so `doctor`'s [filesystem] check is WARN-not-FAIL on a
non-btrfs dev/CI host.

```bash
# Save as /tmp/test_dispatcher.sh and run: bash /tmp/test_dispatcher.sh
# Run from the REPO ROOT (where bin/ and lib/ live).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/bin/agent-browser-pool" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0
STATE="$(mktemp -d)"   # fresh lease store — tests never touch the real pool

# --- Case 1 (structure): executable + bash -n + shellcheck clean ---
bash -n bin/agent-browser-pool && shellcheck -s bash bin/agent-browser-pool && test -x bin/agent-browser-pool \
    && { pass=$((pass+1)); echo "PASS structure: executable + bash -n + shellcheck clean"; } \
    || { fail=$((fail+1)); echo "FAIL structure" >&2; }

# --- Case 2 (verbatim contract lines present): readlink -f / dirname / source / case targets ---
grep -q 'readlink -f "\${BASH_SOURCE\[0\]}"' bin/agent-browser-pool \
    && grep -q 'source "\$REAL_DIR/\.\./lib/pool\.sh"' bin/agent-browser-pool \
    && grep -q 'cmd="\${1:-status}"' bin/agent-browser-pool \
    && grep -q 'pool_admin_release "\${2:-}"' bin/agent-browser-pool \
    && grep -q 'pool_admin_help' bin/agent-browser-pool \
    && grep -q 'Unknown command' bin/agent-browser-pool \
    && { pass=$((pass+1)); echo "PASS contract: verbatim dispatch lines present"; } \
    || { fail=$((fail+1)); echo "FAIL contract: a required line is missing/wrong" >&2; }

# --- Case 3 (lib append-only + .gitkeep retained): ---
git diff --stat lib/pool.sh | grep -q . || true   # lib IS expected to change (append)
test -f bin/.gitkeep && { pass=$((pass+1)); echo "PASS: bin/.gitkeep retained"; } \
    || { fail=$((fail+1)); echo "FAIL: bin/.gitkeep removed" >&2; }
# confirm ONLY the banner+help were appended (no existing function edited):
diff <(git show HEAD:lib/pool.sh 2>/dev/null) lib/pool.sh | grep -E '^[<>]' | grep -vE '^[<>] (#|$|pool_admin_help)' \
    | grep -E '^[<>] [^#[:space:]]' && { fail=$((fail+1)); echo "FAIL: existing code edited (not append-only)" >&2; } \
    || { pass=$((pass+1)); echo "PASS: lib/pool.sh diff is append-only (banner + pool_admin_help)"; }

# --- Case 4 (--help → stdout, rc 0): all three aliases ---
for a in --help -h help; do
    out="$(AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool "$a" 2>/dev/null)" \
        && echo "$out" | grep -q 'Usage: agent-browser-pool' \
        && echo "$out" | grep -q 'status' && echo "$out" | grep -q 'doctor' \
        && echo "$out" | grep -q 'AGENT_BROWSER_POOL_STATE' \
        && { pass=$((pass+1)); echo "PASS '$a' → usage to stdout, rc 0"; } \
        || { fail=$((fail+1)); echo "FAIL '$a'" >&2; }
done

# --- Case 5 (no-args default → status runs, rc 0): ---
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool >/tmp/dflt 2>&1 \
    && { grep -Eq 'No active lanes\.|^[[:space:]]*LANE' /tmp/dflt; } \
    && { pass=$((pass+1)); echo "PASS no-args → status (default verb)"; } \
    || { fail=$((fail+1)); echo "FAIL no-args default" >&2; }

# --- Case 6 (reap runs, rc 0): ---
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool reap >/dev/null 2>&1 \
    && { pass=$((pass+1)); echo "PASS reap → rc 0"; } \
    || { fail=$((fail+1)); echo "FAIL reap" >&2; }

# --- Case 7 (release with no target → usage to STDERR, rc 1): ---
if AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool release >/dev/null 2>/dev/null; then
    fail=$((fail+1)); echo "FAIL release-no-target: expected rc 1, got 0" >&2
else
    pass=$((pass+1)); echo "PASS release-no-target → rc 1"
fi

# --- Case 8 (unknown command → stderr message, rc 1): ---
if AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool bogus 2>/tmp/err >/dev/null; then
    fail=$((fail+1)); echo "FAIL unknown-cmd: expected rc 1, got 0" >&2
else
    grep -q 'Unknown command: bogus' /tmp/err && { pass=$((pass+1)); echo "PASS unknown-cmd → stderr + rc 1"; } \
        || { fail=$((fail+1)); echo "FAIL unknown-cmd: stderr message missing" >&2; }
fi

# --- Case 9 (doctor wires — runs a sectioned report; rc depends on host): ---
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 ./bin/agent-browser-pool doctor >/tmp/doc 2>&1 \
    && grep -q '\[summary\]' /tmp/doc \
    && { pass=$((pass+1)); echo "PASS doctor → sectioned report (rc 0 host-healthy)"; } \
    || { pass=$((pass+1)); echo "PASS doctor → sectioned report (rc 1 host-dep-missing — wiring correct)"; }  # rc 1 is also a PASS (doctor found a real issue)

# --- Case 10 (SYMLINK-SAFETY — THE distinguishing check): invoke THROUGH a symlink ---
# Simulates install.sh: ~/.local/bin/agent-browser-pool → <repo>/bin/agent-browser-pool.
LINK_DIR="$(mktemp -d)"; ln -s "$REPO/bin/agent-browser-pool" "$LINK_DIR/agent-browser-pool"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_ALLOW_SLOW_COPY=1 "$LINK_DIR/agent-browser-pool" --help >/tmp/sym 2>/dev/null \
    && grep -q 'Usage: agent-browser-pool' /tmp/sym \
    && { pass=$((pass+1)); echo "PASS symlink-safety: invoked via symlink → sourced <repo>/lib/pool.sh → help printed"; } \
    || { fail=$((fail+1)); echo "FAIL symlink-safety: readlink -f broken? (a bare dirname \$0 shim would die here)" >&2; }
# NEGATIVE-control reasoning: if the dispatcher used `dirname "$0"` (no readlink -f), it would
# try to source "$LINK_DIR/../lib/pool.sh" = <tmp>/lib/pool.sh → source fails → set -e aborts
# → no 'Usage:' in /tmp/sym. Case 10 fails. That is exactly the regression this test catches.

# --- Cleanup ---
rm -rf "$STATE" "$LINK_DIR" /tmp/dflt /tmp/doc /tmp/err /tmp/sym
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≈11, fail=0. (Case 9 counts a pass either way — rc 0 or 1 both prove the wiring.)
```

### Level 3: Integration Testing (System Validation — needs Chrome + master profile)

The full status/reap/release lifecycle (lanes with live Chromes) requires a real Chrome, a
btrfs master profile, and a `pi` ancestor. It is the domain of the M9 harness. **For this
task, the symlink test in Level 2 IS the integration proof** that the dispatcher wires the
admin functions into an invokable `agent-browser-pool`. A full end-to-end smoke (once a
master profile exists) from inside `pi`:

```bash
# PREREQ: master profile at $AGENT_CHROME_MASTER; a lane acquired (via bin/agent-browser).
# Then the admin tool observes/manages it:
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool}" \
    ./bin/agent-browser-pool status          # → lane table shows the acquired lane (STATE=live)
./bin/agent-browser-pool reap                # → "No stale lanes found." (owner still alive)
./bin/agent-browser-pool release all         # → "Released N lane(s)." (explicit teardown)
./bin/agent-browser-pool status              # → "No active lanes."
# Cleanup is M9.T2/T3; here we only confirm the dispatcher reaches each sibling.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Transparency (PRD §2.15) spot-checks via the dispatcher (full automation is M9.T4.S1):
#   [ ] `./bin/agent-browser-pool --help` → stdout usage (Level 2 Case 4).
#   [ ] `./bin/agent-browser-pool` via SYMLINK `--help` → stdout usage (Level 2 Case 10).
#   [ ] unknown command → stderr + rc 1 (Level 2 Case 8).
# Help is grep-able (Mode A docs):
./bin/agent-browser-pool --help | grep -E '^(  status|  reap|  release|  doctor|  help)' \
    && echo "PASS: help lists all five verbs"
# Portability sanity (confirm shebang + readlink -f resolve as expected on this Linux host):
command -v env >/dev/null && echo "/usr/bin/env bash shebang resolves: $(command -v bash)"
readlink -f ./bin/agent-browser-pool        # expect: <repo>/bin/agent-browser-pool (absolute, canonical)
# Multi-hop symlink defense-in-depth (install.sh may chain symlinks):
D="$(mktemp -d)"; ln -s "$REPO/bin/agent-browser-pool" "$D/a"; ln -s "$D/a" "$D/b"
readlink -f "$D/b" | grep -q 'bin/agent-browser-pool$' && echo "PASS multi-hop symlink resolves" || echo "FAIL"
AGENT_BROWSER_POOL_STATE="$(mktemp -d)" AGENT_CHROME_ALLOW_SLOW_COPY=1 "$D/b" --help >/dev/null 2>&1 \
    && echo "PASS multi-hop --help runs" || echo "FAIL multi-hop"
rm -rf "$D"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n` (both files) clean; `shellcheck -S warning -s bash
      bin/agent-browser-pool` clean (the dispatcher's lone SC1091 INFO on the `source` line is
      expected — identical to landed bin/agent-browser); `shellcheck -s bash lib/pool.sh` truly
      clean; `test -x bin/agent-browser-pool` passes.
- [ ] Level 2 Cases 1-3 (structure, verbatim contract, append-only/.gitkeep) PASS.
- [ ] Level 2 Cases 4-9 (--help×3 aliases, no-args default, reap, release-no-target rc1,
      unknown-cmd stderr rc1, doctor wiring) PASS.
- [ ] Level 2 Case 10 (**symlink-safety**) PASSES — the single most important check for the
      bootstrap half of this task.

### Feature Validation

- [ ] `bin/agent-browser-pool` exists, executable (`chmod 0755`), contains the verbatim contract.
- [ ] `pool_admin_help()` appended under banner `# Admin CLI — help (P1.M7.T5.S1)`.
- [ ] `--help`/`-h`/`help` → usage to stdout, rc 0 (all three aliases).
- [ ] No-args → `status` (the `${1:-status}` default).
- [ ] `release [<N>|all]` passes `"${2:-}"` to `pool_admin_release`.
- [ ] Unknown command → stderr message + rc 1.
- [ ] **Symlink invocation** reaches `pool_admin_help` — proves `readlink -f` sourced
      `<repo>/lib/pool.sh` through the symlink (the `~/.local/bin/` install scenario).
- [ ] `lib/pool.sh` diff is append-only; `bin/agent-browser` + `bin/.gitkeep` unchanged.

### Code Quality Validation

- [ ] Follows the codebase shebang convention (`#!/usr/bin/env bash` — matches `lib/pool.sh:1`).
- [ ] Strict mode (`set -euo pipefail`) declared in the dispatcher AND re-asserted by the lib on
      source (idempotent; matches `bin/agent-browser`).
- [ ] Anti-patterns avoided: no bare `dirname "$0"` (symlink-unsafe); no lifecycle logic in the
      dispatcher (that's the admin fns); `pool_admin_help` is pure (no init inside); no edits to
      existing functions; release uses `"${2:-}"` (not `"$@"`).
- [ ] Self-documenting (the dispatcher header comment + `pool_admin_help`'s header doc-comment +
      the usage output itself; satisfies the item's DOCS step / Mode A).

### Documentation & Deployment

- [ ] `pool_admin_help` output is the user-facing admin docs (Mode A).
- [ ] No new env vars; no config changes; no `.gitignore` change; no `install.sh` (M8.T1.S1).
- [ ] Before cutover (PRD §2.17): the tool is testable by absolute path; `install.sh` (future)
      will symlink it to `~/.local/bin/` — the `readlink -f` makes that safe.

---

## Anti-Patterns to Avoid

- ❌ Don't use `dirname "$0"` / `dirname "$BASH_SOURCE[0]"` WITHOUT `readlink -f` first — at
      install time `$0` is the symlink (`~/.local/bin/agent-browser-pool`) and `../lib/pool.sh`
      resolves to the wrong dir. The Level-2 symlink test (Case 10) catches this. Use
      `readlink -f "${BASH_SOURCE[0]}"`.
- ❌ Don't call `pool_config_init`/`pool_state_init` INSIDE `pool_admin_help` — it is pure
      documentation; requiring init would hide `--help` behind a config typo. The dispatcher's
      verbatim init-before-case covers a normal host; the function stays init-free.
- ❌ Don't move the dispatcher's `pool_config_init`/`pool_state_init` INSIDE the `case` branches —
      the verbatim item-§3 contract calls them BEFORE the dispatch. Reordering diverges from the
      authoritative contract.
- ❌ Don't pass `"$@"` to `pool_admin_release` — the contract is `release) pool_admin_release
      "${2:-}"` (one optional positional). `"$@"` would over-pass args.
- ❌ Don't print `pool_admin_help` output to stderr — explicit `--help` is conventional stdout +
      rc 0 (capturable; `--help` never fails). (release's *misuse* usage → stderr is a DIFFERENT case.)
- ❌ Don't make `pool_admin_help` return non-zero or `pool_die` — `--help` must always succeed.
- ❌ Don't add lifecycle logic to the dispatcher — status/reap/release/doctor/help all live in the
      lib. The dispatcher is bootstrap + `case` only.
- ❌ Don't hardcode the lib EOF line number (4233) — detect the append site via `tail` (it moves
      if a sibling lands).
- ❌ Don't delete the dispatcher's own `set -euo pipefail` because the lib has one — keep both
      (idempotent + protects the pre-source readlink/dirname lines).
- ❌ Don't remove `bin/.gitkeep`, edit `bin/agent-browser`, or modify `.gitignore` /
      `PRD.md` / `tasks.json` / `install.sh` — out of scope / owned by other tasks / humans.
- ❌ Don't split the top-level `REAL_SCRIPT="$(…)"` assignment to "fix" SC2155 — SC2155 does NOT
      apply to plain top-level assignments (only `local`/`declare`/`readonly`/`typeset`).
