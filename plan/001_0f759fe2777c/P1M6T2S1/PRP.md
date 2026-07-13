# PRP — P1.M6.T2.S1: `pool_strip_session_args()` + `pool_force_session()` — strip inherited `--session`, force `AGENT_BROWSER_SESSION=abpool-<N>`

---

## Goal

**Feature Goal**: Implement the **PRD §2.4 step-5 session-neutralization pair** that guarantees an
agent cannot bypass its locked lane by passing the upstream-skill-taught `--session <X>` flag or an
inherited `AGENT_BROWSER_SESSION=<X>` env var. Specifically, append **TWO PURE/SIDE-EFFECT library
functions** to `lib/pool.sh`:

- **`pool_strip_session_args(args...)`** — a PURE argv transform that removes EVERY `--session <X>`
  (space form: flag + value) and `--session=<X>` (equals form: single token) from the args, preserving
  all other tokens (other `--flags`, positionals, args with spaces/newlines) in original order. Writes
  the cleaned argv to a NEW global array **`POOL_CLEAN_ARGS`** (`declare -ga`). Returns **0 ALWAYS**
  (no failure mode — removing a token that isn't there is a valid no-op).
- **`pool_force_session(lane)`** — a SIDE-EFFECT function that exports
  `AGENT_BROWSER_SESSION=abpool-<lane>` so the env var is inherited by the `exec`'d real binary in a
  later step. Validates `lane` is a non-negative integer; returns **0** on success, **1** (non-fatal,
  never `pool_die`) on a bad lane WITHOUT exporting (do-no-harm).

This is a **pure addition**: ONE new banner `# Wrapper shim — session override (P1.M6.T2.S1)`
appended at EOF of `lib/pool.sh` (currently line 3086, directly after `pool_dispatch_classify` — and
after M6.T1.S2's normalizers if that parallel sibling lands first). **NO edits to any existing
function.** `pool_strip_session_args` reads ONLY `"$@"` and writes ONLY the `POOL_CLEAN_ARGS`
output global (no `_pool_log`, no files, no external commands, no env vars consumed).
`pool_force_session` reads only `$1` and mutates only the `AGENT_BROWSER_SESSION` env var.

> **WHY BOTH functions are required (the load-bearing correctness fact)** — host-verified on
> agent-browser 0.28.0 (research `codebase-internal.md` §1): the `--session <name>` FLAG takes
> PRECEDENCE over the `AGENT_BROWSER_SESSION` env var. Concretely,
> `AGENT_BROWSER_SESSION=env-x agent-browser --session flag-x session` → prints `flag-x` (flag wins).
> Therefore: stripping the flag alone is NOT enough (an inherited env var would win once the flag is
> gone); forcing the env alone is NOT enough (a `--session` flag would override it). The contract
> (PRD §2.4 step 5; external_deps §1.3) requires BOTH — strip the flag AND force the env — so the
> env var becomes the SOLE session source, pinned to `abpool-<N>`.

**Deliverable**: Two public functions (`pool_strip_session_args`, `pool_force_session`) + one
output global (`POOL_CLEAN_ARGS`), appended to `lib/pool.sh` under a NEW
`# Wrapper shim — session override (P1.M6.T2.S1)` banner at EOF. Pure append; no existing function
touched.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh` (NO `pool_config_init` needed — `pool_strip_session_args`
  reads only `"$@"`; `pool_force_session` reads only `$1`), every row below holds (stdout is EMPTY;
  `POOL_CLEAN_ARGS` shown joined with `|` for readability; rc as noted):

  | input args (`"$@"`) | `POOL_CLEAN_ARGS` (joined) | rc | rule |
  |---|---|---|---|
  | `--session foo bar` | `bar` | 0 | space form: drop flag + value |
  | `--session=foo bar` | `bar` | 0 | equals form: drop single token |
  | `bar --session foo baz` | `bar\|baz` | 0 | mid-list, both dropped |
  | `--json --session foo open https://x` | `--json\|open\|https://x` | 0 | preserve other flags |
  | `open https://x` | `open\|https://x` | 0 | no --session → unchanged |
  | `--session` (trailing, no value) | *(empty)* | 0 | drop just the flag; no crash |
  | *(no args)* | *(empty)* | 0 | empty in → empty out |
  | `type '#q' 'two words'` | `type\|#q\|two words` | 0 | **spaces preserved** |
  | `--session foo --session=bar baz` | `baz` | 0 | both forms in one argv |
  | `--session foo --session bar baz` | `baz` | 0 | two space-form occurrences |
  | `--session-name myapp open x` | `--session-name\|myapp\|open\|x` | 0 | `--session-name` is NOT stripped (different feature) |

  `pool_force_session` behavior (stdout EMPTY):

  | call | `AGENT_BROWSER_SESSION` after | rc | rule |
  |---|---|---|---|
  | `pool_force_session 7` | `abpool-7` | 0 | export + persist in calling shell |
  | `pool_force_session 1` | `abpool-1` | 0 | lowest lane |
  | `pool_force_session 42` | `abpool-42` | 0 | multi-digit lane |
  | `pool_force_session foo` | *(unchanged)* | 1 | non-numeric → return 1, no export |
  | `pool_force_session ""` | *(unchanged)* | 1 | empty → return 1, no export |
  | `pool_force_session -1` | *(unchanged)* | 1 | negative → return 1 (regex `^[0-9]+$` rejects) |
  | `pool_force_session` (no arg) | *(unchanged)* | 1 | `${1:-}` empty → return 1 |
  | *(prior `AGENT_BROWSER_SESSION=old`)* `pool_force_session 3` | `abpool-3` | 0 | OVERWRITES inherited value |

- **Env propagation** (the contract): after `pool_force_session 7`, both `$AGENT_BROWSER_SESSION` in
  the calling shell AND a child `bash -c 'echo "$AGENT_BROWSER_SESSION"'` print `abpool-7` (the
  export persists in the calling shell and is inherited by a later `exec`). Host-verified
  (`bash-external.md` §4).
- **End-to-end guarantee** (the PRD §2.4 step-5 contract, demonstrable without the full lifecycle):
  `pool_strip_session_args --session evil open https://x; pool_force_session 4; \
   bash -c 'echo "${AGENT_BROWSER_SESSION}"; echo "[${1}]"' bash "${POOL_CLEAN_ARGS[@]}"`
  → prints `abpool-4` then `[open]` then `[https://x]` (flag stripped; env forced; no `evil` leak).
- `pool_strip_session_args` returns 0 ALWAYS and writes NOTHING to stdout (the ONLY output channel
  is the `POOL_CLEAN_ARGS` global). `pool_force_session` writes NOTHING to stdout.
- A `set -u` shell does not abort (`local lane="${1:-}"` for force; `local -a orig=("$@")` + `out=()`
  pre-declared for strip; index arithmetic uses the assignment form `i=$((i+1))`).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero warnings —
  host-verified ShellCheck 0.11.0); all prior deliverables (M1–M6.T1.S1, and M6.T1.S2 if landed)
  unchanged and callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its sole consumers (per the
item CONTRACT §4 "Consumed by lifecycle exec step (M6.T3.S1)" + PRD §2.4 step 5) are:

- **M6.T3.S1 wrapper lifecycle** — after classifying `'driving'`, acquiring lane N, normalizing
  close/connect (M6.T1.S2), and ensuring connected (M5.T1.S3), the wrapper strips the agent's
  `--session`, forces the lane env, then execs the real binary. Pseudocode (M6's concern; this task
  ships the strip + force pair only):
  ```bash
  case "$(pool_dispatch_classify "$@")" in
      meta)    exec "$POOL_REAL_BIN" "$@" ;;                       # passthrough UNCHANGED (no strip/force)
      driving) # resolve owner → find/acquire lane N (M5); pool_ensure_connected (M5.T1.S3)
               pool_normalize_close  "$@"                          # M6.T1.S2
               pool_normalize_connect "${POOL_NORM_ARGS[@]}"       # M6.T1.S2
               pool_strip_session_args "${POOL_NORM_ARGS[@]}"      # THIS TASK → POOL_CLEAN_ARGS
               if ! pool_force_session "$N"; then                  # THIS TASK → exports AGENT_BROWSER_SESSION
                   _pool_log "pool_force_session: bad lane '$N'"; exit 1
               fi
               exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"       # env forced; argv --session-free
               ;;
  esac
  ```
- **Unit tests (M9)** — `pool_strip_session_args` is pure (reads only `"$@"`, writes only the
  `POOL_CLEAN_ARGS` global) → needs ZERO fixtures (no state dir, no owner process, no Chrome) —
  directly testable after a bare `source lib/pool.sh`. `pool_force_session` needs only an env-var
  read-back + `unset AGENT_BROWSER_SESSION` between cases.

**Use Case**: An AI agent (a `pi` child) invokes `agent-browser` hundreds of times per task via
stateless bash calls, following `skills get core` to the letter. The skill teaches
`agent-browser --session <name> <cmd>`; a parent shell might export `AGENT_BROWSER_SESSION`. Without
neutralization, either would route the agent to a session of ITS choosing — bypassing the pool's lane
assignment, colliding with other agents, or pointing at a non-pooled Chrome. This pair makes those
skill-taught invocations land safely on the agent's own lane — the agent has "no idea" it is pooled
(PRD §2.15 "no idea" contract: "`agent-browser --session <x> …` (as the skill teaches) → forced to
my lane").

**Pain Points Addressed**:
- **`--session <X>` bypasses the lane.** The agent's flag would override the pool's lane binding
  (flag wins over env — verified). Stripping the flag removes the agent's escape hatch.
- **Inherited `AGENT_BROWSER_SESSION=<X>` bypasses the lane.** Once the flag is stripped, a leftover
  env var would still win. Forcing `abpool-<N>` overwrites whatever was inherited, pinning the lane.

## Why

- **This IS PRD §2.4 step 5 + §2.15 transparency.** §2.4 step 5: "EXEC real binary with
  `AGENT_BROWSER_SESSION=abpool-<N>` forced + original args. Strip any inherited `--session` /
  `AGENT_BROWSER_SESSION` so the agent can't bypass its lane." §2.4 "Transparent absorption":
  "`agent-browser --session <X> …` → override to `abpool-<N>`." §2.15: "`agent-browser --session <x>
  …` (as the skill teaches) → forced to my lane."
- **It is the identity-pinning safety boundary of the pool.** Every other lane's Chrome/daemon is
  isolated FROM this agent BECAUSE the agent cannot name a different session. Getting it wrong = an
  agent can collide with peers or escape to a non-pooled browser. (PRD §2.17 coexistence: the pool
  coexists with non-pool sessions AND other pool agents — but ONLY if agents can't override their lane.)
- **It is deliberately minimal.** `pool_strip_session_args` is a pure transform (return 0 always);
  `pool_force_session` is one validated `export`. Both are trivially unit-testable with zero fixtures.
- **It composes cleanly with the sibling tasks.** It does NOT classify (M6.T1.S1, landed), does NOT
  normalize close/connect (M6.T1.S2, parallel), does NOT wire the lifecycle (M6.T3.S1). It runs
  AFTER normalize in the pipeline (consumes `${POOL_NORM_ARGS[@]}` as input) and BEFORE exec.

## What

User-visible behavior: none directly (internal functions). Observable contract — given
`source lib/pool.sh`, each function's effect:

### `pool_strip_session_args "$@"`

- Snapshots `"$@"` into `local -a orig=("$@")`.
- Walks `orig` with an index `i`. For each token:
  - `--session` (space form): advance `i` by 2 (drop flag + value) IF a next token exists, else by 1
    (drop just the trailing flag).
  - `--session=*` (equals form): advance `i` by 1 (drop the single combined token).
  - anything else: append to `out` and advance `i` by 1.
- Writes `declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )` (REPLACES the array each call; no stale
  elements). Returns **0 ALWAYS**. stdout: **EMPTY**.
- Preserves ALL other tokens verbatim, including `--session-name <name>` (a DIFFERENT feature —
  cookie/localStorage persistence, NOT a lane-escape hatch; research `bash-external.md` §6), other
  `--flags`, short `-flags`, positionals, and tokens with embedded spaces/newlines.

### `pool_force_session "$1"`

- `local lane="${1:-}"` (set -u safe).
- `[[ "$lane" =~ ^[0-9]+$ ]] || return 1` — non-numeric / empty / negative lane → return 1 WITHOUT
  exporting (do-no-harm; leaves any prior `AGENT_BROWSER_SESSION` untouched).
- `export AGENT_BROWSER_SESSION="abpool-$lane"` — persists in the CALLING shell (functions do not
  create subshells) and is inherited by a later `exec`. Returns **0**. stdout: **EMPTY**.

**Hard invariants** (both functions, every input):
- **`pool_strip_session_args` returns 0 ALWAYS; stdout EMPTY.** The ONLY output channel is the
  `POOL_CLEAN_ARGS` global array. (argv may contain spaces/newlines → stdout is unsafe; this is the
  established codebase idiom from M6.T1.S2's `POOL_NORM_ARGS`.) The caller reads
  `"${POOL_CLEAN_ARGS[@]}"`.
- **`pool_force_session` returns 0 on success, 1 on a bad lane (non-fatal, never `pool_die`).** The
  caller MUST guard under set -e: `if pool_force_session "$N"; then …`. This mirrors the non-fatal
  rc-0/rc-1 family (`pool_daemon_connect` @1630, `pool_daemon_connected` @1680, `pool_wait_for_lane`).
- **OUTPUT = `POOL_CLEAN_ARGS` (global array, `declare -ga`)** — always fully reassigned each call
  (no stale elements). Distinct name from M6.T1.S2's `POOL_NORM_ARGS` so the pipeline stages don't
  alias (research `design-decisions.md` D2).
- **NO precondition for `pool_strip_session_args`.** Callable BEFORE `pool_config_init` (reads NO
  `POOL_*` config globals — only `"$@"`). This mirrors `pool_dispatch_classify` and makes it unit-
  testable with zero fixtures. `pool_force_session` likewise reads no config (only `$1`); it does not
  need init.
- **`(( ))` safety:** the only `(( ))` uses are `while (( i < ${#orig[@]} ))` (loop CONDITION —
  errexit-exempt) and `if (( i+1 < ${#orig[@]} ))` (if-CONDITION — exempt). Index increment uses the
  ASSIGNMENT form `i=$((i+1))` / `i=$((i+2))` (always rc 0). NO bare `(( i++ ))` (returns rc 1 when
  i==0 → ABORT under set -e; the trap documented at lib/pool.sh:360-365).
- **Both forms of `--session` stripped** (space `--session <X>` and equals `--session=<X>`); multiple
  occurrences all stripped; trailing `--session` with no value handled (drop just the flag).
- **`--session-name` is NOT touched** (different feature; research `bash-external.md` §6).

### Success Criteria

- [ ] `pool_strip_session_args` + `pool_force_session` defined (PUBLIC, no `_` prefix) under a NEW
      `# Wrapper shim — session override (P1.M6.T2.S1)` banner at EOF. Callable after a bare
      `source lib/pool.sh` (NO init needed for strip; force reads only `$1`).
- [ ] `--session foo bar` → `POOL_CLEAN_ARGS=(bar)`, rc 0, stdout empty.
- [ ] `--session=foo bar` → `POOL_CLEAN_ARGS=(bar)`, rc 0.
- [ ] `bar --session foo baz` → `POOL_CLEAN_ARGS=(bar baz)`, rc 0.
- [ ] `--json --session foo open https://x` → `POOL_CLEAN_ARGS=(--json open https://x)`, rc 0.
- [ ] `open https://x` (no --session) → `POOL_CLEAN_ARGS=(open https://x)`, rc 0 (no-op).
- [ ] trailing `--session` (no value) → `--session` dropped, NO crash, rc 0.
- [ ] no args → `POOL_CLEAN_ARGS=()` (empty), rc 0.
- [ ] **spaces preserved**: `type '#q' 'two words'` → 3rd element is the single string `two words`.
- [ ] `--session foo --session=bar baz` and `--session foo --session bar baz` → `POOL_CLEAN_ARGS=(baz)`, rc 0.
- [ ] `--session-name myapp open x` → `POOL_CLEAN_ARGS=(--session-name myapp open x)` (--session-name KEPT).
- [ ] `pool_force_session 7` → `AGENT_BROWSER_SESSION=abpool-7`, rc 0; export persists in calling shell
      AND is inherited by a child `bash -c`.
- [ ] `pool_force_session foo` / `""` / `-1` / no-arg → return 1, `AGENT_BROWSER_SESSION` UNCHANGED.
- [ ] prior `AGENT_BROWSER_SESSION=old`; `pool_force_session 3` → `abpool-3` (OVERWRITES).
- [ ] `pool_strip_session_args` return 0 ALWAYS; stdout EMPTY; reads no config globals / writes no
      files / no external cmds; `set -u`-safe.
- [ ] End-to-end (no full lifecycle): strip `--session evil` + force lane 4 → child sees
      `AGENT_BROWSER_SESSION=abpool-4` and args `open https://x` (no `evil`).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file);
      all prior deliverables (M1–M6.T1.S1, and M6.T1.S2 if landed) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **precedence fact** (research `codebase-internal.md`
§1 — `--session` flag WINS over `AGENT_BROWSER_SESSION` env, host-verified → BOTH strip+force are
required); the **two-function decomposition** (`design-decisions.md` D1); the **global-array output
decision** (D2 — `POOL_CLEAN_ARGS` distinct from `POOL_NORM_ARGS`, serialization-free); the
**return-convention split** (D3 strip returns 0 always; D5 force returns 0/1); the **strip-forms
decision** (D4 — space + equals + trailing + multiple); the **env-export mechanics** (D5 + bash-external
§4 — `export` persists in the calling shell, inherited by exec); the **`--session-name` exclusion**
(D6 — different feature); the **scan idiom to mirror** (codebase-internal §3 — the classify/M6.T1.S2
case-arms); the **`(( ))` trap** (codebase-internal §4 — `i=$((i+1))`, conditions exempt); the **full
verbatim-ready implementation** (Implementation Tasks Task 1); and a copy-pasteable, host-verified
validation script (Level 2).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 5 (the final exec: AGENT_BROWSER_SESSION=abpool-<N> forced + original args; strip
        inherited --session / AGENT_BROWSER_SESSION). §2.4 "Transparent absorption" bullet
        ("--session <X> … → override to abpool-<N>"). §2.15 transparency checklist
        ("--session <x> … (as the skill teaches) → forced to my lane"). §2.17 coexistence (agents
        can't override their lane).
  pattern: §2.4 step 5's two clauses (strip + force) ARE this task's two functions.
  gotcha: §2.4 step 5 lists BOTH the flag AND the env var as things to neutralize → both required.

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M6T2S1/research/codebase-internal.md
  why: §1 the HOST-VERIFIED precedence fact (--session flag WINS over env → both strip+force required;
        the load-bearing correctness fact). §2 the lifecycle position + sibling boundaries (M6.T1.S2
        emits POOL_NORM_ARGS → THIS task consumes it → emits POOL_CLEAN_ARGS → M6.T3.S1 execs). §3 the
        classify/M6.T1.S2 scan idiom to mirror (case-arms for --session). §4 the (( ))/set-e trap.
        §5 the host-verified strip matrix (11 cases incl. trailing --session, spaces, both forms,
        empty array = 0 elements). §6 env-export propagation (export persists + inherited by exec).
        §7 the return-convention census (strip = return 0 always; force = 0/1 non-fatal). §9 GOTCHA summary.
  pattern: §3's index-based rebuild-drop loop IS the strip implementation; §6's export line IS the force.
  gotcha: §1 — flag wins over env; §5 — trailing --session handled by the i+1<${#orig[@]} guard.
- file: plan/001_0f759fe2777c/P1M6T2S1/research/bash-external.md
  why: §1 declare -ga global-array return (argv-safe; empty array = 0 elements, no spurious NUL).
        §2 the (( )) trap (i=$((i+1)); conditions exempt). §3 the index rebuild-drop loop. §4 env
        export from a function (persists in calling shell; inherited by exec; export VAR=val clean).
        §5 WHY strip is needed given the force (flag precedence). §6 --session-name is a DIFFERENT
        feature (NOT stripped).
  pattern: §3 Snippet is the strip; §4 Snippet is the force.
  gotcha: §6 — do NOT strip --session-name / AGENT_BROWSER_SESSION_NAME.
- file: plan/001_0f759fe2777c/P1M6T2S1/research/design-decisions.md
  why: D1 (two functions not one) D2 (POOL_CLEAN_ARGS global, distinct from POOL_NORM_ARGS) D3 (strip
        returns 0 always) D4 (strip space+equals+trailing+multiple) D5 (force validates lane, 0/1,
        export) D6 (do NOT strip --session-name) D7 (placement + naming) D8 (sibling boundaries) +
        the composition sketch for M6.T3.S1. This is the design spine.
  pattern: D8's composition sketch IS the lifecycle integration contract.

# Architecture
- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §1.3 the Session/Connection special-handling table rows ARE this task's contract:
        "agent-browser --session <X> <cmd> → Override --session to abpool-<N>. Strip the agent's
        --session flag." and "AGENT_BROWSER_SESSION=<X> agent-browser <cmd> → Override env to abpool-<N>."
  pattern: §1.3 table rows = the two functions' behavior.
  gotcha: §1.3 — both the flag AND the env var must be overridden (two table rows → two functions).

# The LANDED sibling whose scan this task MIRRORS (treated as CONTRACT)
- file: plan/001_0f759fe2777c/P1M6T1S1/PRP.md   # pool_dispatch_classify (M6.T1.S1 — LANDED @3030-3086)
  why: the IMMEDIATE predecessor. Its `while (( $# > 0 )); do case ... --session) shift 2 || shift ;;
        --session=*) shift ;; --*) shift ;; -*) shift ;; *) cmd="$1" ...` scan is the EXACT idiom this
        task reuses (as an index-based loop that DROPS --session instead of skipping it). Its GOTCHA
        notes (return 0 always; no precondition; the (( i++ )) trap; scope boundary) are inherited.
  pattern: the flag-scan case-arms + the "return 0 always, stdout discipline, NO precondition" contract.
  gotcha: its scope note "Does NOT strip --session / force AGENT_BROWSER_SESSION (M6.T2.S1)" — THAT is
        this task. Mirror its scan; DROP --session (do not skip-and-keep as M6.T1.S2 does).

# The PARALLEL sibling whose OUTPUT global this task's INPUT comes from (treated as CONTRACT)
- file: plan/001_0f759fe2777c/P1M6T1S2/PRP.md   # pool_normalize_close/connect (M6.T1.S2 — parallel)
  why: establishes the POOL_NORM_ARGS global-array output idiom this task FOLLOWS (with a distinct
        name POOL_CLEAN_ARGS). Its design-decisions D1 (global array not stdout — argv can contain
        spaces) + D7 (return 0 always, pure) are inherited verbatim. M6.T3.S1 passes
        ${POOL_NORM_ARGS[@]} as THIS task's input args.
  pattern: the declare -ga NAME=( "${out[@]}" ) output idiom + the index-based scan loop.
  gotcha: M6.T1.S2 KEEPS --session (only skips its value during its scan); THIS task DROPS --session.
        Different actions, same scan idiom. Decoupled: pool_strip_session_args reads "$@", not
        POOL_NORM_ARGS directly (M6.T3.S1 wires the handoff).

# The LANDED functions whose CONVENTIONS this task follows
- file: lib/pool.sh   # pool_dispatch_classify @3030-3086 (the scan to mirror + the EOF append point)
  why: the append goes directly AFTER this function's closing brace (currently line 3086). Its
        `while (( $# > 0 ))` + case-arms ARE the idiom to mirror as an index loop.
- file: lib/pool.sh   # pool_daemon_connect @1605-1646 + pool_daemon_connected @1660-1720 (the rc 0/1
        non-fatal family + the --session "$session" invocation pattern)
  why: the `[[ -n "$X" ]] || return 1` defensive-validation idiom + the non-fatal rc-0/rc-1 contract
        IS what pool_force_session follows (validate lane → return 1 on bad; export → return 0). Also
        shows the codebase's own `--session "$session"` usage (lines 1645, 1703) — the very flag the
        pool relies on internally and that this task strips from the AGENT's argv.
- file: lib/pool.sh   # pool_chrome_launch @1471-1568 (declare -g return idiom for scalars)
  why: lines 1514 (`POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID`) IS the codebase's return-via-global
        idiom; this task extends it to `declare -ga` (array) for POOL_CLEAN_ARGS.
- file: lib/pool.sh   # lines 1-19 (header + strict mode), 360-366 (the (( )) trap doc)
  why: line 18 `set -euo pipefail` is INHERITED. Lines 360-365 document in-place the bare-`(( ))`
        -returns-rc1-when-result-0 trap — the exact reason this task uses `i=$((i+1))` and NEVER
        `(( i++ ))`.
```

### Current Codebase tree

After **M1–M6.T1.S1** have landed, `lib/pool.sh` (3086 lines) ends with `pool_dispatch_classify`
(@2977 banner; function body @3030; closing brace = EOF @3086). The parallel **M6.T1.S2** appends its
`pool_normalize_close`/`connect` under a `# Wrapper shim — arg normalization (P1.M6.T1.S2)` banner
AFTER `pool_dispatch_classify`; this task appends under its OWN banner after whatever is last:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6.T3.S2 populates)
├── lib/
│   └── pool.sh                           # ends (after M6.T1.S1) with pool_dispatch_classify at EOF.
│                                         #   Banner order at EOF (after M6.T1.S1 + parallel M6.T1.S2):
│                                         #   # Wrapper shim — command dispatch (P1.M6.T1.S1)   @2973
│                                         #   pool_dispatch_classify                            @3030
│                                         #   # Wrapper shim — arg normalization (P1.M6.T1.S2)  ← M6.T1.S2 (parallel)
│                                         #   pool_normalize_close / pool_normalize_connect
│                                         #   # Wrapper shim — session override (P1.M6.T2.S1)   ← THIS TASK (append here)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M6T1S2/PRP.md
    └── P1M6T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-internal,bash-external,design-decisions}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a NEW banner section at EOF:
                  #   # Wrapper shim — session override (P1.M6.T2.S1)   ← NEW banner
                  #   pool_strip_session_args:
                  #       - walk $@ (index loop, mirror classify scan); DROP every --session <X>
                  #         (space form: flag+value) and --session=<X> (equals form: 1 token);
                  #         KEEP all other tokens (incl --session-name) verbatim, order preserved
                  #       - POOL_CLEAN_ARGS = cleaned argv (declare -ga); return 0 ALWAYS; stdout EMPTY
                  #   pool_force_session LANE:
                  #       - validate LANE =~ ^[0-9]+$ else return 1 (non-fatal, no export)
                  #       - export AGENT_BROWSER_SESSION=abpool-<LANE>; return 0
                  #   (OUTPUT-ONLY global: POOL_CLEAN_ARGS [declare -ga array])
                  #   (SIDE EFFECT: AGENT_BROWSER_SESSION env var [exported by pool_force_session])
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**PRD §2.4 step-5 session neutralizers** — the pure argv strip + the env force — the wrapper
(M6.T3.S1) calls (after classify, after normalize, after acquire/ensure_connected) to guarantee an
agent's `--session` flag or inherited `AGENT_BROWSER_SESSION` cannot bypass its lane.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (--session FLAG WINS over AGENT_BROWSER_SESSION env — research codebase-internal §1,
#   HOST-VERIFIED): agent-browser resolves --session <name> as "Isolated session (or AGENT_BROWSER_SESSION
#   env)" — the env is the FALLBACK. Live: AGENT_BROWSER_SESSION=e agent-browser --session f session → "f".
#   ⇒ Stripping the flag alone is NOT enough (inherited env would win); forcing the env alone is NOT
#   enough (a flag would override it). BOTH are required (the contract). This is the load-bearing fact.

# CRITICAL (OUTPUT = GLOBAL ARRAY POOL_CLEAN_ARGS, not stdout — research design-decisions D2): argv can
#   contain spaces/newlines (URLs, type payloads). stdout is UNSAFE for an array. The codebase's
#   return-via-declare-g convention (POOL_CHROME_PID @1514) extends to `declare -ga POOL_CLEAN_ARGS=( … )`.
#   The cleaned argv is read by the caller as "${POOL_CLEAN_ARGS[@]}". stdout stays EMPTY.

# CRITICAL (export persists in the calling shell — research bash-external §4): a function call (no
#   $(...) / no pipe) runs in the CALLING shell, so `export AGENT_BROWSER_SESSION=abpool-$lane` inside
#   pool_force_session PERSISTS after the function returns and is INHERITED by a later exec. Host-verified.

# CRITICAL (the (( i++ )) trap — lib/pool.sh:360-365): a BARE `(( i++ ))` returns rc 1 when i was 0
#   → ABORTS under set -e. Use the ASSIGNMENT form `i=$((i+1))` (always rc 0). The ONLY (( )) uses here
#   are `while (( i < ${#orig[@]} ))` (loop COND — exempt) and `if (( i+1 < ${#orig[@]} ))` (if COND —
#   exempt). Prior art: pool_dispatch_classify `while (( $# > 0 ))` @3035.

# CRITICAL (pool_strip_session_args returns 0 ALWAYS — research design-decisions D3): NO failure mode.
#   Every input yields a valid POOL_CLEAN_ARGS. Do NOT add a non-zero return path. Mirrors classify +
#   M6.T1.S2's "return 0 ALWAYS."

# CRITICAL (pool_force_session returns 0/1 NON-FATAL — research design-decisions D5): validate lane
#   (^[0-9]+$); return 1 on a bad lane WITHOUT exporting (do-no-harm); NEVER pool_die. The caller MUST
#   guard: `if pool_force_session "$N"; then …`. Mirrors pool_daemon_connect @1630 / pool_daemon_connected @1680.

# CRITICAL (stdout EMPTY for BOTH): the ONLY output channel for strip is the POOL_CLEAN_ARGS global;
#   force has NO output (only the env side effect). NEVER printf/echo to stdout.

# GOTCHA (--session-name is NOT stripped — research bash-external §6): --session-name <name> (+
#   AGENT_BROWSER_SESSION_NAME) is a DIFFERENT feature (cookie/localStorage persistence), NOT a
#   lane-escape hatch. Stripping it would silently disable a legitimate agent capability. Strip ONLY
#   --session / --session=<X>.

# GOTCHA (trailing --session with no value): e.g. `agent-browser open x --session`. The index guard
#   `if (( i+1 < ${#orig[@]} ))` drops just the flag without reading past the array end. Host-verified
#   (codebase-internal §5): no crash, rc 0.

# GOTCHA (multiple --session): `--session a --session b cmd` → the loop drops EVERY --session (and each
#   space-form's value) → POOL_CLEAN_ARGS=(cmd). Correct — ZERO --session flags in the exec'd argv.

# GOTCHA (POOL_CLEAN_ARGS fully reassigned each call): `declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )`
#   REPLACES the array (no stale elements from a prior call). Safe to call repeatedly / in sequence.
#   Empty out → POOL_CLEAN_ARGS=() (${#} == 0, NO spurious element — host-verified).

# GOTCHA (set -u + empty array): `local -a orig=("$@")` and `local -a out=()` are pre-declared →
#   "${orig[@]}" / "${out[@]}" on an empty array are set -u-safe in bash 5.x. "${POOL_CLEAN_ARGS[@]}"
#   is also safe (declare -ga makes it exist).

# GOTCHA (DISTINCT global name POOL_CLEAN_ARGS ≠ M6.T1.S2's POOL_NORM_ARGS): the pipeline is
#   POOL_NORM_ARGS → strip → POOL_CLEAN_ARGS → exec. Distinct names prevent aliasing + make each stage
#   unit-testable. pool_strip_session_args reads "$@" (M6.T3.S1 passes ${POOL_NORM_ARGS[@]}); it does
#   NOT reference POOL_NORM_ARGS directly → decoupled from the parallel sibling.

# GOTCHA (placement + naming): APPEND at EOF (after pool_dispatch_classify @3086, and after M6.T1.S2's
#   normalizers if landed) under a NEW "# Wrapper shim — session override (P1.M6.T2.S1)" banner. Public
#   names pool_strip_session_args / pool_force_session (no `_` prefix; pool_* family). NO new env vars
#   CONSUMED (strip reads only "$@"; force reads only $1); POOL_CLEAN_ARGS is OUTPUT-only;
#   AGENT_BROWSER_SESSION is EXPORTED (side effect). NO edits to any existing function.

# GOTCHA (shellcheck — keep it clean): the file is 100% clean today (SC2034 disables only @124/@1569).
#   This task adds ZERO net warnings. Avoid SC2155 (the array literal `declare -ga X=( "${out[@]}" )`
#   has NO command substitution → clean; `export VAR="literal$1"` has no cmd-sub → clean). Avoid SC2086
#   (quote "$1", "${orig[@]}", "${out[@]}"). Avoid SC2178/SC2128 (always expand arrays as "${arr[@]}").
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change**, **no new env vars consumed**, and **no lease/data
model**. It introduces:

- `POOL_CLEAN_ARGS` — global **array** (`declare -ga`); the cleaned argv (every `--session` removed).
  Always fully reassigned by `pool_strip_session_args`. Read by the caller as `"${POOL_CLEAN_ARGS[@]}"`.
- `AGENT_BROWSER_SESSION` — an **environment variable** (exported by `pool_force_session`); set to
  `abpool-<lane>`. Exported into the calling shell's env so a later `exec` inherits it.

External commands: **NONE.** Both functions use only bash builtins (`local`, `while`, `case`, `if`,
`[[ ]]`, `(( ))`, `$(( ))`, `export`, `declare -g`/`-ga`, `return`). No `jq`, no `grep`, no subshells,
no `_pool_log`. This makes `pool_strip_session_args` pure, O(n), and safe to call before/after any
init; `pool_force_session` a single validated export.

**Naming**: `pool_strip_session_args` / `pool_force_session` (public, no `_` prefix; `pool_*` family).
No private helper needed (the strip is a short index loop; the force is one line).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_dispatch_classify'
  - EXPECT: reported as a function. (pool_dispatch_classify = M6.T1.S1 LANDED @3030; this task
        appends AFTER it, and AFTER M6.T1.S2's normalizers if that parallel sibling has landed.)
  - RUN (confirm this task is greenfield):
        grep -nE 'pool_strip_session_args|pool_force_session|POOL_CLEAN_ARGS|session override' \
            lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield.
  - RUN (locate the append point = current EOF + confirm the scan to mirror):
        grep -nE '^pool_dispatch_classify\(\)' lib/pool.sh    # M6.T1.S1 deliverable (@3030)
        grep -nE 'Wrapper shim' lib/pool.sh                    # banner sections at EOF
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh     # closing brace = EOF (~3086 or later)
        sed -n '3035,3055p' lib/pool.sh                        # the exact scan case-arms to MIRROR
        sed -n '19p' lib/pool.sh                               # expect: set -euo pipefail
  - EXPECT: pool_dispatch_classify defined (@3030); its `while (( $# > 0 ))` + case-arms (--session)
        shift 2 || shift ;; --session=*) shift ;; --*) shift ;; -*) shift ;; *) cmd="$1" ...) ARE
        the idiom to mirror as an index loop that DROPS --session. Line 18 = set -euo pipefail.
        EOF ~3086 (or later if M6.T1.S2 landed first — append after whatever is last).
  - RUN (confirm the precedence fact this task depends on — HOST-VERIFIED):
        AGENT_BROWSER_SESSION=env-x agent-browser --session flag-x session 2>&1 | head -1
  - EXPECT: "flag-x" (the FLAG wins over the env var → both strip + force are required).
  - RUN (confirm --session-name is a SEPARATE flag — do NOT strip it):
        agent-browser --help 2>&1 | grep -iE '\-\-session-name|\-\-session '
  - EXPECT: two distinct options (--session <name> and --session-name <name>).
  - RUN (sanity tools): command -v bash >/dev/null && command -v shellcheck >/dev/null && echo "OK tools"
  - EXPECT: OK tools (bash 5.x + ShellCheck 0.11.0).
  - RUN: bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh && echo "OK clean baseline"
  - EXPECT: OK clean baseline (zero warnings — the bar this task must NOT lower).

Task 1: APPEND the new banner + pool_strip_session_args() + pool_force_session() to lib/pool.sh
  - PLACEMENT: directly below the LAST function at EOF (pool_dispatch_classify @3086, or M6.T1.S2's
        pool_normalize_connect if that parallel sibling has landed), under a NEW
        "# Wrapper shim — session override (P1.M6.T2.S1)" banner.
  - IMPLEMENT (verbatim-ready — paste the banner + docstrings + functions at EOF):

# =============================================================================
# Wrapper shim — session override (P1.M6.T2.S1)
# =============================================================================
# PRD §2.4 step 5 / §2.15 transparency. Neutralize an agent's attempt to bypass its
# lane via the upstream-skill-taught --session <X> flag or an inherited
# AGENT_BROWSER_SESSION=<X> env var. Called by the wrapper lifecycle (M6.T3.S1) AFTER
# pool_dispatch_classify returned 'driving', AFTER M6.T1.S2's close/connect normalize,
# and AFTER acquire + ensure_connected, but BEFORE the exec.
#
# HOST-VERIFIED precedence (agent-browser 0.28.0): the --session <name> FLAG WINS over
# the AGENT_BROWSER_SESSION env var (the env is the fallback when no flag is given).
# ⇒ NEITHER strip-alone NOR force-alone suffices. BOTH are required:
#     pool_strip_session_args  → remove every --session from the argv
#     pool_force_session       → export AGENT_BROWSER_SESSION=abpool-<lane>
#   so the env var is the SOLE session source, pinned to the agent's lane.

# pool_strip_session_args [--] ARGS...
#
# Pure argv transform: remove EVERY '--session <X>' (space form: flag + value) and
# '--session=<X>' (equals form: single token) from ARGS, preserving all other tokens
# (other --flags, -shortflags, positionals, args with spaces/newlines) in original order.
# Writes the cleaned argv to the GLOBAL ARRAY POOL_CLEAN_ARGS (declare -ga). Returns 0
# ALWAYS (removing a token that isn't there is a valid no-op). stdout: EMPTY.
#
# LOGIC (CONTRACT a, research codebase-internal §3/§5):
#   - Snapshot $@ into local -a orig=("$@").
#   - Walk orig with an index i; rebuild into local -a out=():
#        --session      → if a next token exists: i+=2 (drop flag + value); else i+=1 (drop trailing flag)
#        --session=*    → i+=1 (drop the single equals-form token)
#        <anything else>→ out+=("$tok"); i+=1   (KEEP verbatim, incl. --session-name)
#   - POOL_CLEAN_ARGS = out. Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle (passes ${POOL_NORM_ARGS[@]} from M6.T1.S2 as
#   the args); unit tests (M9).
#
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_CLEAN_ARGS, NOT stdout. stdout stays EMPTY.
#   The caller reads "${POOL_CLEAN_ARGS[@]}". (argv may contain spaces → stdout is unsafe.)
# GOTCHA — return 0 ALWAYS; no failure mode ⇒ the caller needs NO if-guard.
# GOTCHA --session-name is NOT stripped (different feature: cookie/localStorage persistence;
#   research bash-external §6). Only --session / --session=<X> are removed.
# GOTCHA — multiple --session are ALL dropped; trailing --session (no value) is dropped
#   without reading past the array end (the i+1<${#orig[@]} guard).
# GOTCHA — the index counter uses `i=$((i+N))` (assignment, always rc 0), NEVER `(( i++ ))`
#   (returns rc 1 when i==0 → ABORT under set -e; lib/pool.sh:360-365). The only (( )) are
#   `while (( i < ${#orig[@]} ))` (cond, exempt) and `if (( i+1 < ${#orig[@]} ))` (cond, exempt).
# GOTCHA — MIRRORS pool_dispatch_classify's scan case-arms (--session / --session=*) so the
#   wrapper-shim siblings agree on what a --session token is.
# GOTCHA — POOL_CLEAN_ARGS is DISTINCT from M6.T1.S2's POOL_NORM_ARGS (pipeline:
#   POOL_NORM_ARGS → strip → POOL_CLEAN_ARGS → exec). This function reads only "$@" (it does
#   NOT reference POOL_NORM_ARGS) → decoupled from the parallel sibling.
# PRECONDITION: none. Reads only "$@".
pool_strip_session_args() {
    local -a orig=("$@") out=()
    local i=0 tok

    # Walk orig with an index; rebuild into out MINUS every --session token. `i=$((i+N))`
    # is an ASSIGNMENT (always rc 0) — avoids the bare-(( i++ )) trap (lib/pool.sh:360-365).
    # The `while (( ))` and `if (( ))` are CONDITIONS (errexit-exempt).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)
                # Space form: drop the flag AND its value (if a next token exists).
                # Trailing `--session` with no value → drop just the flag (i+=1).
                if (( i+1 < ${#orig[@]} )); then
                    i=$((i+2))
                else
                    i=$((i+1))
                fi
                ;;
            --session=*)
                # Equals form: single combined token (--session=X) → drop it.
                i=$((i+1))
                ;;
            *)
                # KEEP everything else verbatim (incl. --session-name, --json, positionals).
                out+=("$tok")
                i=$((i+1))
                ;;
        esac
    done

    # Emit the cleaned argv via the GLOBAL ARRAY (atomic single-statement; REPLACES each
    # call — no stale elements; empty out → POOL_CLEAN_ARGS=() with 0 elements).
    declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )
    return 0
}

# pool_force_session LANE
#
# Export AGENT_BROWSER_SESSION=abpool-<LANE> into the CALLING shell's environment so the
# later `exec "$POOL_REAL_BIN" …` (M6.T3.S1) inherits it. Because pool_strip_session_args
# removed any --session flag, this env var is the SOLE session source → the agent cannot
# bypass its lane. Validates LANE is a non-negative integer; returns 1 (non-fatal, no
# export) on a bad lane. stdout: EMPTY.
#
# LOGIC (CONTRACT b, research bash-external §4):
#   - lane="${1:-}"  (set -u safe)
#   - [[ "$lane" =~ ^[0-9]+$ ]] || return 1   (non-numeric/empty/negative → do-no-harm)
#   - export AGENT_BROWSER_SESSION="abpool-$lane"   (persists in calling shell; inherited by exec)
#   - return 0
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — `export` inside a function (no $(...) / no pipe) runs in the CALLING shell →
#   the env var PERSISTS after the function returns AND is inherited by a later exec.
#   Host-verified (bash-external §4).
# GOTCHA — NON-FATAL rc 0/1 (never pool_die): mirrors pool_daemon_connect @1630 /
#   pool_daemon_connected @1680. The caller MUST guard: `if pool_force_session "$N"; then …`.
# GOTCHA — on rc 1 we return WITHOUT exporting (do-no-harm: any prior AGENT_BROWSER_SESSION
#   is left untouched).
# GOTCHA — a SUCCESSFUL export OVERWRITES any inherited AGENT_BROWSER_SESSION (that is the
#   point — "strip inherited AGENT_BROWSER_SESSION" collapses to one overwrite export).
# GOTCHA — does NOT touch AGENT_BROWSER_SESSION_NAME (different feature; bash-external §6).
# PRECONDITION: none (reads only $1; no config/init needed).
pool_force_session() {
    local lane="${1:-}"

    # Validate lane: non-negative integer. `[[ ]] || return 1` is errexit-exempt.
    # Bad lane (empty/non-numeric/negative) → return 1 WITHOUT exporting (do-no-harm).
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    # Force the lane session. export VAR=val is ShellCheck-clean (no cmd-sub → no SC2155).
    # Persists in the calling shell; inherited by the later exec.
    export AGENT_BROWSER_SESSION="abpool-$lane"
    return 0
}

  - VERIFY (immediately after writing):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings
        grep -nE '^pool_strip_session_args\(\)|^pool_force_session\(\)' lib/pool.sh   # both defined once
  - EXPECT: OK syntax; OK shellcheck (zero warnings — same as baseline); both defined once near EOF.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the index-based strip loop that MIRRORS pool_dispatch_classify's scan but DROPS --session
# (the only (( )) are the while/if CONDITIONS, which are errexit-exempt; the counter uses the
# ASSIGNMENT form i=$((i+N)), always rc 0 — sidesteps the bare-(( i++ )) trap at lib/pool.sh:360-365):
local -a orig=("$@") out=()      # snapshot $@ so we can scan AND rebuild; pre-declare out (set -u safe)
local i=0 tok
while (( i < ${#orig[@]} )); do
    tok="${orig[i]}"
    case "$tok" in
        --session)                      # space form: flag + value
            if (( i+1 < ${#orig[@]} )); then i=$((i+2)); else i=$((i+1)); fi ;;
        --session=*)                    # equals form: single combined token
            i=$((i+1)) ;;
        *)                              # KEEP everything else (incl. --session-name)
            out+=("$tok"); i=$((i+1)) ;;
    esac
done

# PATTERN — return the cleaned argv via a GLOBAL ARRAY (declare -ga, atomic single-statement):
declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )   # REPLACES the array each call (no stale elements)

# PATTERN — force the lane session via a validated export (pool_daemon_connect @1630 idiom):
local lane="${1:-}"
[[ "$lane" =~ ^[0-9]+$ ]] || return 1          # non-fatal precondition check (errexit-exempt)
export AGENT_BROWSER_SESSION="abpool-$lane"    # persists in calling shell; inherited by exec
return 0

# GOTCHA — WHY BOTH strip + force (flag precedence): host-verified, --session <name> WINS over
#   AGENT_BROWSER_SESSION. Stripping the flag makes the env the sole source; forcing the env pins
#   it to abpool-<N>. Neither alone suffices.
# GOTCHA — WHY i=$((i+1)) and NOT (( i++ )): a bare (( i++ )) with i==0 returns rc 1 → ABORT under
#   set -e. The assignment form is always rc 0. The while/if (( )) CONDITIONS are errexit-exempt.
# GOTCHA — WHY NOT strip --session-name: it is a DIFFERENT feature (cookie/localStorage persistence),
#   not a lane-escape hatch. Stripping it would silently disable a legitimate agent capability.
# GOTCHA — WHY return 0 always for strip: removing a token has no failure mode (no-op if absent).
#   WHY return 0/1 for force: a bad lane is a real precondition violation; return 1 so the caller
#   can decline to exec (do-no-harm).
```

### Integration Points

```yaml
LIBRARY (lib/pool.sh):
  - append: "new banner '# Wrapper shim — session override (P1.M6.T2.S1)' + pool_strip_session_args +
            pool_force_session at EOF (after pool_dispatch_classify @3086, and after M6.T1.S2's
            normalizers if landed)"
  - pattern: "match the banner+docstring+function style of pool_dispatch_classify (@2977) +
             pool_daemon_connect (@1605, the rc 0/1 non-fatal family + the --session invocation)"

OUTPUT CONTRACTS (new globals/side effects — OUTPUT-only; never read by these functions):
  - POOL_CLEAN_ARGS:        "declare -ga array — the --session-free argv. Caller reads \"${POOL_CLEAN_ARGS[@]}\"."
  - AGENT_BROWSER_SESSION:  "env var EXPORTED by pool_force_session (= abpool-<lane>). Inherited by the exec."

CONSUMERS (NOT built by this task — referenced for interface stability):
  - M6.T3.S1 wrapper lifecycle (the composition pattern — normalize → strip → force → exec):
        pool_normalize_close  "$@"                          # M6.T1.S2 → POOL_NORM_ARGS (+ POOL_CLOSE_ALL_SEEN)
        pool_normalize_connect "${POOL_NORM_ARGS[@]}"       # M6.T1.S2 → POOL_NORM_ARGS
        pool_strip_session_args "${POOL_NORM_ARGS[@]}"      # THIS TASK → POOL_CLEAN_ARGS
        if ! pool_force_session "$N"; then                  # THIS TASK → exports AGENT_BROWSER_SESSION
            _pool_log "pool_force_session: bad lane '$N'; aborting exec"; exit 1
        fi
        [[ "$POOL_CLOSE_ALL_SEEN" == 1 ]] && _pool_log "intercepted close --all → scoped to lane $N"
        exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"       # env forced; argv --session-free

NO CHANGES TO:
  - any existing function (M1–M6.T1.S1, M6.T1.S2) — pure append.
  - any env var / config global consumed — strip reads only "$@"; force reads only $1.
  - bin/ (still .gitkeep) — the executable is M6.T3.S2.
  - test/ (still .gitkeep) — the bats harness is M9.T1.S1.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the functions — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings

grep -nE '^pool_strip_session_args\(\)|^pool_force_session\(\)' lib/pool.sh   # both defined exactly once
# Expected: both OK; both defined once near EOF. (Baseline was 100% clean; this task must not lower it.)
#   Common fixes: SC2155 (none expected — array literal + export have no cmd-sub), SC2086 (quote
#   "$1"/"${orig[@]}"), SC2178 (expand arrays as "${arr[@]}").
```

### Level 2: Unit Tests (Component Validation)

The bats harness lands in M9.T1.S1. For THIS task, validate via a direct bash script asserting
`POOL_CLEAN_ARGS` (joined) + `AGENT_BROWSER_SESSION` + rc (the functions are pure/side-effect —
zero fixtures needed):

```bash
# Save as /tmp/test_session_override.sh and run: bash /tmp/test_session_override.sh
set -euo pipefail
source lib/pool.sh
pass=0; fail=0

# join POOL_CLEAN_ARGS with '|' for comparison (empty array → "").
clean_join() { local IFS='|'; printf '%s' "${POOL_CLEAN_ARGS[*]}"; }

# CRITICAL — call pool_strip_session_args DIRECTLY (NOT inside "$( ... )"). A command-substitution
# subshell would lose the POOL_CLEAN_ARGS global (BashFAQ/024). The function writes NOTHING to stdout
# (verified in Level 3), so a direct call is both correct and sufficient. rc==0 is enforced by set -e.

# assert_strip EXPECTED_JOINED  ARGS...  — run pool_strip_session_args directly; check POOL_CLEAN_ARGS + rc.
assert_strip() {
    local exp_join="$1"; shift
    local joined
    pool_strip_session_args "$@"                       # DIRECT call → sets POOL_CLEAN_ARGS in THIS shell
    joined="$(clean_join)"                             # clean_join subshell inherits the global (copy)
    if [[ "$joined" == "$exp_join" ]]; then pass=$((pass+1));
    else fail=$((fail+1)); printf 'FAIL strip: args=[%s] want(j=%s) got(j=%s)\n' "$*" "$exp_join" "$joined" >&2; fi
}

# assert_force EXPECTED_ENV  LANE  — run pool_force_session directly; check AGENT_BROWSER_SESSION + rc.
assert_force_ok() {
    local exp_env="$1" lane="$2"
    pool_force_session "$lane"                         # DIRECT call → exports in THIS shell
    if [[ "${AGENT_BROWSER_SESSION:-}" == "$exp_env" ]]; then pass=$((pass+1));
    else fail=$((fail+1)); printf 'FAIL force-ok: lane=%s want(env=%s) got(env=%s)\n' \
        "$lane" "$exp_env" "${AGENT_BROWSER_SESSION:-}" >&2; fi
}
assert_force_bad() {  # LANE — expect rc 1, NO export, env UNCHANGED
    local lane="$1" before="${AGENT_BROWSER_SESSION:-UNSET}"
    if pool_force_session "$lane" 2>/dev/null; then
        fail=$((fail+1)); printf 'FAIL force-bad: lane=%s expected rc 1, got rc 0\n' "$lane" >&2
    else
        if [[ "${AGENT_BROWSER_SESSION:-UNSET}" == "$before" ]]; then pass=$((pass+1));
        else fail=$((fail+1)); printf 'FAIL force-bad: lane=%s env mutated (%s → %s)\n' \
            "$lane" "$before" "${AGENT_BROWSER_SESSION:-UNSET}" >&2; fi
    fi
}

# --- pool_strip_session_args ---
assert_strip 'bar'                       --session foo bar                 # space form
assert_strip 'bar'                       --session=foo bar                 # equals form
assert_strip 'bar|baz'                   bar --session foo baz             # mid-list
assert_strip '--json|open|https://x'     --json --session foo open https://x  # preserve flags
assert_strip 'open|https://x'            open https://x                    # no --session → unchanged
assert_strip ''                          --session                         # trailing, no value
assert_strip ''                                                           # no args
assert_strip 'baz'                       --session foo --session=bar baz   # both forms
assert_strip 'baz'                       --session foo --session bar baz   # two space-form
assert_strip '--session-name|myapp|open|x' --session-name myapp open x     # --session-name KEPT

# spaces preserved (robustness): the 3rd element is the single string 'two words'
assert_strip "type|#q|two words"         type '#q' 'two words'

# --- pool_force_session (unset env between each block) ---
unset AGENT_BROWSER_SESSION || true
assert_force_ok 'abpool-7'   7
assert_force_ok 'abpool-1'   1
assert_force_ok 'abpool-42'  42

# bad lanes → rc 1, no export, env UNCHANGED
export AGENT_BROWSER_SESSION=prior-val
assert_force_bad foo
assert_force_bad ''
assert_force_bad -1
unset AGENT_BROWSER_SESSION || true
assert_force_bad ''            # no-arg (unset env; ${1:-} empty → rc 1, env stays unset)

# prior inherited value is OVERWRITTEN on success
export AGENT_BROWSER_SESSION=old-inherited
assert_force_ok 'abpool-3' 3   # overwrites old-inherited → abpool-3

# --- ENV PROPAGATION to a child (the exec inheritance contract) ---
unset AGENT_BROWSER_SESSION || true
pool_force_session 5
child_env="$(bash -c 'printf "%s" "${AGENT_BROWSER_SESSION:-UNSET}"')"
if [[ "$child_env" == "abpool-5" ]]; then pass=$((pass+1));
else fail=$((fail+1)); printf 'FAIL propagation: child saw %s, want abpool-5\n' "$child_env" >&2; fi

# --- END-TO-END (strip + force, no full lifecycle) ---
unset AGENT_BROWSER_SESSION || true
pool_strip_session_args --session evil open https://x
pool_force_session 4
# Simulate the exec'd binary's view: env + cleaned argv.
e2e="$(bash -c 'printf "%s|${POOL_CLEAN_ARGS[*]}" "${AGENT_BROWSER_SESSION:-UNSET}"' 2>/dev/null || \
       bash -c 'printf "%s|%s" "$AGENT_BROWSER_SESSION" "$*" ' bash "${POOL_CLEAN_ARGS[@]}")"
# (The child can't see the parent's POOL_CLEAN_ARGS global — pass it as args instead:)
e2e="$(bash -c 'printf "%s|%s" "$AGENT_BROWSER_SESSION" "$*" ' bash "${POOL_CLEAN_ARGS[@]}")"
if [[ "$e2e" == "abpool-4|open https://x" ]]; then pass=$((pass+1));
else fail=$((fail+1)); printf 'FAIL e2e: got %s, want abpool-4|open https://x\n' "$e2e" >&2; fi

# --- report ---
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
# Expected: pass=20 fail=0 (10 strip + 3 force-ok + 4 force-bad + 1 propagation + 1 overwrite-in-ok
#           + 1 e2e; the overwrite case counts in assert_force_ok). If ANY fail, debug root cause.
# (stdout-emptiness is verified separately in Level 3.)
```

### Level 3: Integration Testing (System Validation)

```bash
# Confirm NO regression — all prior deliverables still load + are callable (incl. the new ones):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
         type pool_dispatch_classify pool_strip_session_args pool_force_session \
               pool_acquire_locked pool_ensure_connected' && echo "OK all callable"
# Expected: all reported as functions (incl. the two new ones; and pool_normalize_close/connect if
#           M6.T1.S2 has landed).

# Confirm pool_strip_session_args needs NONE of the init (pure — callable on a bare source):
bash -c 'set -euo pipefail; source lib/pool.sh; \
         pool_strip_session_args --session foo open https://x; \
         printf "args=[%s]\n" "${POOL_CLEAN_ARGS[*]}"'
# Expected: args=[open https://x] (NO pool_config_init called).

# Confirm pool_force_session works on a bare source + exports:
bash -c 'set -euo pipefail; source lib/pool.sh; pool_force_session 9; \
         printf "env=%s\n" "$AGENT_BROWSER_SESSION"'
# Expected: env=abpool-9.

# Confirm stdout is EMPTY for BOTH (all output is via the global / env) — captures must be empty:
out="$(set -euo pipefail; source lib/pool.sh; pool_strip_session_args --session foo bar)"
[[ -z "$out" ]] && echo "OK strip stdout-empty" || echo "FAIL: strip wrote to stdout"
out="$(set -euo pipefail; source lib/pool.sh; pool_force_session 2)"
[[ -z "$out" ]] && echo "OK force stdout-empty" || echo "FAIL: force wrote to stdout"
# Expected: both OK.

# (The wrapper bin/agent-browser integration is M6.T3.S1/S2 — NOT validated here.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# SAFETY smoke — the core PRD §2.15 guarantee: an agent's --session CANNOT bypass its lane.
# After strip + force, the exec'd binary's view must have NO agent-chosen session and the lane env:
set -euo pipefail; source lib/pool.sh
unset AGENT_BROWSER_SESSION || true
# Simulate the skill-taught escape attempt: agent-browser --session mysession open https://example.com
pool_strip_session_args --session mysession open https://example.com
pool_force_session 6
# POOL_CLEAN_ARGS must contain NO --session and NO 'mysession':
case "${POOL_CLEAN_ARGS[*]}" in
    *--session*|*mysession*) echo "FAIL: agent session leaked into argv" ;;
    *) echo "OK: argv clean = [${POOL_CLEAN_ARGS[*]}]" ;;
esac
# Env must be the lane, NOT mysession:
[[ "$AGENT_BROWSER_SESSION" == "abpool-6" ]] && echo "OK: env pinned to lane 6" || echo "FAIL: env=$AGENT_BROWSER_SESSION"

# Inherited env var is OVERWRITTEN (the env-strip half of the contract):
export AGENT_BROWSER_SESSION=i-inherited-this
pool_force_session 2
[[ "$AGENT_BROWSER_SESSION" == "abpool-2" ]] && echo "OK: inherited env overwritten" || echo "FAIL"

# --session-name is PRESERVED (do NOT over-strip — different feature):
pool_strip_session_args --session-name myapp --session lane-evil open https://x
clean_join() { local IFS='|'; printf '%s' "${POOL_CLEAN_ARGS[*]}"; }
[[ "$(clean_join)" == "--session-name|myapp|open|https://x" ]] && echo "OK --session-name preserved, --session stripped" || echo "FAIL: $(clean_join)"

# Spaces/newlines robustness — the WHOLE point of the global-array output channel:
pool_strip_session_args --session foo type '#q' 'two words'
[[ "$(clean_join)" == "type|#q|two words" ]] && echo "OK spaces preserved" || echo "FAIL"
# Expected: all OK. (If spaces were split, the global-array channel would be wrong.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 passed: `bash -n lib/pool.sh` clean + `shellcheck -s bash lib/pool.sh` zero warnings.
- [ ] Level 2 passed: the strip/force script reports `fail=0` (≈20 cases).
- [ ] Level 3 passed: all prior functions still callable; both new functions work on a bare
      `source lib/pool.sh` (no init); stdout is EMPTY for both.
- [ ] Level 4 passed: agent `--session` cannot leak into argv; inherited env overwritten;
      `--session-name` preserved; spaces preserved.

### Feature Validation

- [ ] All success-criteria rows in the "What"/Goal tables met (strip space/equals/trailing/multiple,
      force ok/bad, overwrite, propagation).
- [ ] `--session <X>` (space) and `--session=<X>` (equals) BOTH stripped; value consumed for space form.
- [ ] `--session-name <X>` PRESERVED (not stripped).
- [ ] multiple `--session` all stripped; trailing `--session` (no value) stripped without crash.
- [ ] `pool_force_session <N>` → `AGENT_BROWSER_SESSION=abpool-<N>` (rc 0; exported; inherited by exec).
- [ ] `pool_force_session <bad>` → rc 1, env UNCHANGED (do-no-harm).
- [ ] End-to-end: strip `--session evil` + force lane 4 → child sees `abpool-4` + `open https://x`.
- [ ] `pool_strip_session_args` return 0 ALWAYS; stdout EMPTY; reads no config globals / writes no
      files / no external cmds; `set -u`-safe.

### Code Quality Validation

- [ ] Follows existing codebase patterns (banner + docstring + function style of
      `pool_dispatch_classify`; rc 0/1 non-fatal family of `pool_daemon_connect`; return-via-`declare -g`
      of `pool_chrome_launch` extended to `declare -ga` for `POOL_CLEAN_ARGS`).
- [ ] File placement: appended at EOF under the new banner; no existing function touched.
- [ ] Anti-patterns avoided: no bare `(( i++ ))` (uses `i=$((i+1))`), no stdout output, no non-zero
      return path for strip, no `pool_die` for force, no global config reads, no `--session-name`
      stripping, no classification (M6.T1.S1), no close/connect normalize (M6.T1.S2), no lifecycle
      wiring/exec (M6.T3.S1).
- [ ] Naming matches the `pool_*` family; `POOL_CLEAN_ARGS` is OUTPUT-only; `AGENT_BROWSER_SESSION`
      is EXPORTED (documented side effect).

### Documentation & Deployment

- [ ] Docstrings document LOGIC, CONSUMERS, GOTCHAs, PRECONDITION (= none) for BOTH functions.
- [ ] No new env vars CONSUMED documented (strip reads only "$@"; force reads only $1).
- [ ] Scope boundary vs M6.T1.S1 (classify) / M6.T1.S2 (normalize) / M6.T3.S1 (lifecycle/exec) noted.
- [ ] The load-bearing precedence fact (`--session` flag wins over env → both strip+force required)
      documented in the banner + both docstrings.

---

## Anti-Patterns to Avoid

- ❌ Don't ship ONLY strip or ONLY force — the `--session` FLAG WINS over `AGENT_BROWSER_SESSION`
  (host-verified). Both are required to pin the lane. Strip removes the flag's override; force sets
  the env (the sole source once the flag is gone).
- ❌ Don't echo the cleaned argv on stdout — argv can contain spaces/newlines (unsafe); use the
  `POOL_CLEAN_ARGS` global array. stdout stays EMPTY.
- ❌ Don't use a bare `(( i++ ))` — returns rc 1 when i==0 → ABORTS under `set -e`. Use the assignment
  form `i=$((i+1))` (always rc 0). The only `(( ))` are `while (( ))` / `if (( ))` CONDITIONS (exempt).
- ❌ Don't strip `--session-name` / `AGENT_BROWSER_SESSION_NAME` — that is a DIFFERENT feature
  (cookie/localStorage persistence), not a lane-escape hatch. Stripping it silently disables a
  legitimate agent capability. Strip ONLY `--session` / `--session=<X>`.
- ❌ Don't forget the trailing `--session` (no value) case — a naive `i=$((i+2))` at end-of-array would
  read past the end. Use the `if (( i+1 < ${#orig[@]} ))` guard.
- ❌ Don't `pool_die` in `pool_force_session` on a bad lane — return 1 (non-fatal) so the caller
  (M6.T3.S1) can decide not to exec (do-no-harm). And on rc 1, do NOT export (leave env untouched).
- ❌ Don't add a non-zero return path to `pool_strip_session_args` — it returns 0 ALWAYS (no failure
  mode; removing an absent token is a valid no-op). A non-zero path would force every caller to add
  an `if` guard for nothing.
- ❌ Don't read any `POOL_*` config global or call `pool_config_init`/`pool_owner_resolve`/`_pool_log` —
  `pool_strip_session_args` reads ONLY `"$@"`; `pool_force_session` reads only `$1`. Both are callable
  after a bare source (unit-testable with zero fixtures).
- ❌ Don't reference `POOL_NORM_ARGS` (M6.T1.S2's global) inside `pool_strip_session_args` — read
  `"$@"` and let M6.T3.S1 pass `${POOL_NORM_ARGS[@]}` as the args. This decouples this task from the
  parallel sibling. Use the DISTINCT output name `POOL_CLEAN_ARGS`.
- ❌ Don't classify (M6.T1.S1), normalize close/connect (M6.T1.S2), wire the lifecycle, or `exec`
  (M6.T3.S1). This task strips `--session` + forces `AGENT_BROWSER_SESSION` ONLY.
- ❌ Don't skip validation because "it should work" — run the Level 2 matrix; the space-vs-equals
  strip, the trailing `--session`, the `--session-name` preservation, the bad-lane rc 1, and the
  env-propagation-to-child checks are all easy to get wrong.
