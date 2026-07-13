# PRP — P1.M6.T1.S1: `pool_dispatch_classify()` — parse first token → classify DRIVING vs META/passthrough

---

## Goal

**Feature Goal**: Implement **`pool_dispatch_classify()`** — the **PRD §2.4 step 0
dispatcher**: a pure library function that walks the original command-line args (`$@`),
skips leading flags to find the first non-flag token (the command), and **echoes exactly
one token on stdout — `'meta'` or `'driving'`** — telling the wrapper whether to exec the
real binary unchanged (META/passthrough) or route to the agent's locked lane (DRIVING).
It is the **very first** step of the request lifecycle, called BEFORE owner resolution.

This is a **pure addition**: ONE new public function appended to `lib/pool.sh` under a
NEW banner `# Wrapper shim — command dispatch (P1.M6.T1.S1)` at EOF (directly after
`pool_wait_for_lane`, the M5.T4.S1 deliverable, ~line 2971). **NO edits to any existing
function, NO new env vars/globals, NO new files, NO state, NO external commands.** It
reads ONLY `"$@"` and writes ONLY one stdout token.

The function implements the item CONTRACT verbatim (research §1 reconciles the
command taxonomy from the real `agent-browser --help`; research §2 the algorithm +
the `--help`-short-circuit / `session-list`-lookahead / default-driving decisions;
research §3 the bash `set -e` correctness):

**a.** Walk `$@` left→right, skipping leading flags to find the first non-flag token:
      `--help`/`-h`/`--version` → short-circuit `'meta'`; `--session <X>` → consume flag
      + value (`shift 2`); `--session=<X>`/`--json`/any `--flag`/any `-shortflag` → skip
      (`shift 1`); first non-flag → the COMMAND (`break`).
**b.** `'session'` + immediate-next-token `'list'` → `'meta'` (two-word META command);
      command ∈ `{skills, dashboard, plugin, mcp}` → `'meta'`.
**c.** DRIVING set (`open/click/type/.../connect/close/session/back/forward/reload/get/
      is/find` + `dblclick` etc. — full list `external_deps.md` §1.1) → `'driving'`.
**d.** Unrecognized command (and no-command / only-flags) → `'driving'` (let the real
      binary handle the error).
**e.** Echo `'meta'` or `'driving'`; **return 0 ALWAYS** (no failure mode).

> **Key implementation insight (research §2.2):** because steps (c) and (d) BOTH return
> `'driving'`, the DRIVING set is NEVER enumerated in code — a token is either in the
> META set (`'meta'`) or everything else (`'driving'`). This is functionally identical to
> enumerating DRIVING + defaulting, and stays correct as `agent-browser` adds new driving
> commands (`mouse`, `react`, …). The full DRIVING list is kept as a COMMENT only.

**Deliverable**: `pool_dispatch_classify()` appended to `lib/pool.sh` under a NEW
`# Wrapper shim — command dispatch (P1.M6.T1.S1)` banner at EOF (after `pool_wait_for_lane`
@2909, ~line 2971). Single public function, no private helper (the scan is short).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh` (NO `pool_config_init`, NO
  `pool_owner_resolve` needed — pure function), the following all hold:
  - `pool_dispatch_classify --help` / `-h` / `--version` → stdout `'meta'`, rc 0.
  - `pool_dispatch_classify skills` / `skills get core` / `dashboard` / `dashboard start`
    / `plugin` / `plugin add x` / `mcp` / `session list` → stdout `'meta'`, rc 0.
  - `pool_dispatch_classify open https://x` / `click sel` / `get url` / `find role x click`
    / `--json get url` / `--session foo open bar` / `--session=foo open` / `connect 9222`
    / `close --all` / `session` / `session foo` / `dblclick sel` / `install` → stdout
    `'driving'`, rc 0.
  - `pool_dispatch_classify` (no args) / `--json` (alone) / `--session` (no value) →
    stdout `'driving'`, rc 0 (default-to-driving, contract step d).
  - **Every** call returns rc 0; stdout is EXACTLY one token (`meta`/`driving`) — nothing
    else. A `set -u` shell does not abort (`${2:-}` guards the lookahead).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero
  warnings — host-verified ShellCheck 0.11.0); all prior deliverables (M1–M5.T4.S1)
  unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its single
consumer (per the item CONTRACT §4 + PRD §2.4 step 0) is:

- **M6.T3.S1 wrapper lifecycle** — the wrapper calls `pool_dispatch_classify "$@"` as the
  VERY FIRST thing. Pseudocode (M6's concern; this task ships the classifier only):
  ```bash
  case "$(pool_dispatch_classify "$@")" in
      meta)    exec "$AGENT_BROWSER_REAL" "$@" ;;          # passthrough unchanged
      driving) <resolve owner → find/acquire lane → ensure connected → exec with forced session> ;;
  esac
  ```
  Because it is step 0, it runs BEFORE `pool_owner_resolve` — hence the function takes
  **NO precondition** and reads **NO globals**.

**Use Case**: An AI agent (a `pi` child process) invokes `agent-browser <args>` hundreds
of times per task via stateless bash calls. The wrapper must decide, for each invocation,
whether the args even need a browser lane. `agent-browser skills get core` (reading a doc)
and `agent-browser --version` must NOT spin up Chrome; `agent-browser open <url>` must.
This function makes that binary decision in O(n) over the arg list with zero side effects.

**Pain Points Addressed**:
- **Needless lane acquisition for non-driving commands.** Without classification, every
  `skills get core` or `--help` would acquire a lane (launch Chrome) just to print text.
  The META path bypasses all pool logic (PRD §2.4 step 0 META branch).
- **Transparent absorption of the upstream skill.** Agents follow `skills get core` to the
  letter and invoke `--session <X>`, `connect <x>`, `close --all`, etc. The classifier
  must route the COMMAND correctly regardless of those leading flags (PRD §2.15
  transparency checklist).

## Why

- **This IS PRD §2.4 step 0 (dispatch).** The two-way split (DRIVING → lane logic;
  META/passthrough → exec real binary unchanged) is implemented exactly. The META set and
  DRIVING set come from the item CONTRACT, cross-checked against `external_deps.md` §1.1–1.2
  (verified from `agent-browser --help`).
- **It is the lifecycle's gate.** Every other step (owner resolution §2.4 step 1, lease
  lookup step 2, acquire step 3, ensure step 4, exec step 5) is SKIPPED for META commands.
  Getting the classification right is what makes the pool *transparent* (PRD §2.15).
- **It is deliberately minimal and pure.** No globals, no state, no external commands, no
  precondition → trivially testable (no fixtures) and callable at step 0 before any
  initialization. The default-to-driving rule (contract step d) is the safe catch-all: an
  unknown command lets the real binary produce its own error message rather than the pool
  guessing wrong.

## What

User-visible behavior: none directly (internal function). Observable contract — given
`source lib/pool.sh`, the function's stdout + return code for representative inputs:

| invocation (after `pool_dispatch_classify`) | stdout | rc | rule |
|---|---|---|---|
| `--help` / `-h` / `--version` | `meta` | 0 | short-circuit (META) |
| `skills` / `skills get core` / `dashboard` / `dashboard start` / `plugin` / `plugin add x` / `mcp` | `meta` | 0 | META set |
| `session list` | `meta` | 0 | two-word META (session + next==list) |
| `open https://x` / `click sel` / `get url` / `find role x click` / `snapshot` / `eval js` | `driving` | 0 | DRIVING (default) |
| `--json get url` / `--session foo open bar` / `--session=foo open` | `driving` | 0 | flags skipped; command=driving |
| `connect 9222` / `close --all` | `driving` | 0 | DRIVING (special-handling is M6.T1.S2, not here) |
| `session` / `session foo` | `driving` | 0 | session ∈ DRIVING; next ≠ list |
| `dblclick sel` / `install` / `chat hi` | `driving` | 0 | unrecognized → default driving (step d) |
| *(no args)* / `--json` *(alone)* / `--session` *(no value)* | `driving` | 0 | no command found → default driving |

**Hard invariants** (every row):
- **return 0 ALWAYS.** There is no failure mode (every input yields `meta` or `driving`).
  This makes the caller's `class="$(pool_dispatch_classify "$@")"` safe under `set -e`
  with NO guard — unlike `pool_lease_find_mine` (returns 1 on no-match, REQUIRES an `if`).
- **stdout = EXACTLY one token** (`meta`/`driving`) via `printf 'meta\n'`/`printf 'driving\n'`.
  Nothing else writes stdout. The function reads NO `POOL_*` globals, writes NO files,
  calls NO external commands — pure arg parsing.
- **NO precondition.** Callable BEFORE `pool_config_init` / `pool_owner_resolve` (dispatch
  is PRD §2.4 STEP 0, before owner resolution step 1). This is a DESIGN REQUIREMENT, not a
  side-effect — and it makes the function unit-testable with zero fixtures.
- **`--help`/`-h`/`--version` short-circuit to `'meta'`.** They are listed in the contract
  both as "flags to skip" (a) and as META commands (b); the ONLY reconciliation satisfying
  both is: when encountered during the scan, return `'meta'` immediately. (research §2.3.)
- **`session list` → `'meta'`; bare `session` → `'driving'`.** The two-word META command
  needs a one-token lookahead (peek the token immediately after `session`); `session` is
  in the DRIVING set so `session <other>` defaults to `'driving'`. (research §2.5.)
- **default-to-driving, never enumerate DRIVING.** Because contract steps (c) and (d) both
  yield `'driving'`, the code detects META explicitly and defaults everything else. The
  full DRIVING list is a comment only. (research §2.2.)
- **shift-based scan, NO index counter.** Avoids the `(( i++ ))`-returns-0 → ABORT-under-
  `set -e` trap entirely. The only `(( ))` is `(( $# > 0 ))` in the `while` condition
  (errexit-exempt). (research §3.1.)
- **SCOPE — classify ONLY.** Does NOT intercept `close --all`, normalize `connect <arg>`
  (M6.T1.S2), strip `--session`, or force `AGENT_BROWSER_SESSION` (M6.T2.S1), nor wire the
  lifecycle (M6.T3.S1) or create the `bin/agent-browser` executable (M6.T3.S2). Here
  `--session <X>` is only SKIPPED to find the command; it is NOT removed or rewritten.

### Success Criteria

- [ ] `pool_dispatch_classify` defined (PUBLIC, no `_` prefix) under a NEW
      `# Wrapper shim — command dispatch (P1.M6.T1.S1)` banner at EOF. Callable after a
      bare `source lib/pool.sh` (NO init/resolve needed).
- [ ] `--help` / `-h` / `--version` → `meta` (short-circuit), rc 0.
- [ ] `skills` / `skills get core` / `dashboard` / `dashboard start` / `plugin` /
      `plugin add x` / `mcp` → `meta`, rc 0.
- [ ] `session list` → `meta` (two-word lookahead); `session` / `session foo` → `driving`.
- [ ] DRIVING commands (`open`/`click`/`get`/`find`/`connect`/`close`/…) → `driving`, rc 0.
- [ ] Leading flags skipped: `--json get url`, `--session foo open bar`, `--session=foo open`
      → command classified correctly (`driving` for these).
- [ ] Unrecognized (`install`, `dblclick`, `chat`) → `driving` (default, step d).
- [ ] No-command / only-flags (no args; `--json` alone; `--session` no value) → `driving`.
- [ ] return 0 ALWAYS; stdout EXACTLY one token; reads no globals / writes no files / no
      external commands; `set -u`-safe (`${2:-}`).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole
      file); all prior deliverables (M1–M5.T4.S1) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **command taxonomy** (research §1 — the
verified META/DRIVING lists from `agent-browser --help`, the flag semantics `--session`
takes a value / `--json` boolean / `--version` works, the reconciliation of the item
contract's DRIVING list vs `external_deps.md` §1.1, and the known-limitation note on
`install/upgrade/doctor/profiles`); the **algorithm design** (research §2 — the
META-detection + default-driving insight, the `--help`-short-circuit reconciliation, the
`session-list` lookahead, the shift-based scan, the return-0-always + no-precondition
contract, the scope boundary vs M6.T1.S2/M6.T2.S1/M6.T3); the **bash correctness**
(research §3 — the `(( ))`-in-condition rule, the `shift 2 || shift` idiom, the
SC2155-irrelevance, the banner/placement convention); the **full verbatim-ready
implementation** (Implementation Tasks Task 1); and copy-pasteable, host-verified
validation commands covering 22 scenarios.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 0 ("Parse first non-flag token → dispatch: DRIVING → lane logic;
        META/passthrough → exec real binary unchanged") IS this function. §2.15 transparency
        checklist (the "no idea" contract: skills passthrough, --session/--connect routed,
        close --all harmless). §2.17 cutover (the wrapper shadows the real binary on PATH).
  pattern: §2.4 step 0's DRIVING/META split IS the classification; §2.15 enumerates the
        invocations that must stay transparent.
  gotcha: §2.4 step 0 lists `session list` as META but bare commands like `open` as DRIVING
        — the two-word `session list` needs a lookahead (research §2.5).

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M6T1S1/research/command-taxonomy.md
  why: §1 the verified META/DRIVING lists; §2 flag semantics (--session takes a value,
        --json boolean, --version confirmed, --help short-circuit rationale); §3 commands
        not in either list → default driving (+ the install/upgrade/doctor/profiles
        known-limitation note); §4 the 14-row edge-case decision table.
  pattern: §4 IS the test matrix.
  gotcha: §2 why --help/-h/--version must SHORT-CIRCUIT (not skip-then-nothing) — the only
        reading where `agent-browser --help` → meta.
- file: plan/001_0f759fe2777c/P1M6T1S1/research/dispatch-logic.md
  why: §2 the META-detection + default-driving insight (DRIVING never enumerated); §3 the
        --help short-circuit reconciliation; §4 the shift-based case-arms in evaluation
        order; §5 the classification block; §6 return-0-always + stdout discipline; §7 the
        NO-precondition requirement (step 0 before owner resolution); §8 the scope boundary.
  pattern: §4+§5 IS the implementation spine.
  gotcha: §7 NO precondition is a DESIGN REQUIREMENT (dispatch is step 0) — read NO globals.
- file: plan/001_0f759fe2777c/P1M6T1S1/research/bash-patterns.md
  why: §1 the (( ))-in-condition rule + why shift-based (no index) avoids the (( i++ )) trap;
        §2 shift 2 || shift; §3 SC2155 irrelevance (rc always 0); §4 case over elif; §5
        stdout discipline; §6 array-less design; §7 banner + placement + pool_dispatch_*
        naming.
  pattern: §1+§2 ARE the set -e safety checklist.
  gotcha: §1 a bare `(( i++ ))` when i==0 returns rc 1 and ABORTS under set -e — the reason
        we use shift, not an index.

# External authoritative docs (for the WHY; behavior host-verified in research)
- url: https://www.gnu.org/software/bash/manual/html_node/Compound-Commands.html
  why: "`(( expression ))` ... exit status is 0 if the expression evaluates to non-zero;
        otherwise 1." ⇒ a bare `(( i++ ))` with i==0, or `(( $# ))` as a STATEMENT when $#==0,
        returns 1 and ABORTS under set -e. In a `while`/`if` CONDITION it is exempt. ⇒ use
        `while (( $# > 0 ))` (condition) and shift-based iteration (no index counter).
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: the `-e` exemption list — the command in a `while`/`if`/`until` condition AND any
        command in a `||` list except the last are exempt. ⇒ `while (( $# > 0 ))` and
        `shift 2 || shift` both fall through cleanly on a non-zero rc.
  section: `-e` (the exemption list paragraph).
- url: https://www.shellcheck.net/wiki/SC2155
  why: "Declare and assign separately to avoid masking exit status." Relevant only when the
        RHS is a command whose rc matters; HERE the function returns 0 always so it is
        irrelevant — but `local tok cmd next` declared separately is still the clean form.

# Architecture
- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §1.1 the DRIVING command list (verified from agent-browser --help); §1.2 the META list;
        §1.3 the session/connect/close special-handling table (M6.T1.S2's job — this task only
        CLASSIFIES connect/close as 'driving').
  pattern: §1.1+§1.2 ARE the classification source (cross-checked vs the item contract).
  gotcha: §1.1 includes `dblclick` which the item-contract DRIVING list omits — harmless
        because default-driving covers it (research §1 reconciliation note).
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: line 215 "pool_dispatch_* ← wrapper command dispatch" (the naming family this function
        joins); lines 178-195 the single-shared-library architecture (bin/agent-browser
        sources lib/pool.sh via readlink-safe path).

# The LANDED functions whose CONVENTIONS this task follows (treated as CONTRACT)
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list (M3.T2.S1 — LANDED @967)
  why: the closest structural MODEL — a PUBLIC function that echoes exactly one kind of token
        (lane numbers) to stdout, returns 0 always, has rich docstring (CONSUMERS/GOTCHA/
        PRECONDITION), and documents the `for n in $(f)` unquoted-substitution contract. Mirror
        its docstring depth + stdout discipline.
  pattern: the docstring-with-LOGIC/CONSUMERS/GOTCHA/PRECONDITION sections; `printf '%s\n'`
        as the ONLY stdout write.
- file: lib/pool.sh   # lines 1-19 (header + strict mode), 352-385 (_pool_now/_pool_age_str)
  why: line 19 `set -euo pipefail` is INHERITED by this function. Lines 362-364 document the
        bare-`(( ))`-ABORTS-under-set-e GOTCHA in-place — the exact trap this task's
        shift-based design avoids. Lines 529 (`while (( steps++ < 128 ))`) + 547 (`if (( ppid
        == 1 ))`) are prior art for `(( ))` in a CONDITION (errexit-exempt).
```

### Current Codebase tree

After **M1–M5.T4.S1** have landed, `lib/pool.sh` (2971 lines) ends with `pool_wait_for_lane`
(@2909, closing brace = EOF ~line 2971). The last banner (@2777–2779) reads
`# Pool exhaustion (P1.M5.T4.S1)`:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6.T3.S2 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T4.S1) with pool_wait_for_lane at EOF.
│                                         #   Banner order at EOF:
│                                         #   # Release & teardown (P1.M5.T2.S1)
│                                         #   pool_release_lane
│                                         #   # Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)
│                                         #   pool_reap_stale
│                                         #   pool_reuse_orphan
│                                         #   # Pool exhaustion (P1.M5.T4.S1)
│                                         #   _pool_alert
│                                         #   pool_wait_for_lane  ← current EOF (~line 2971)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T4S1/PRP.md
    └── P1M6T1S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{command-taxonomy,dispatch-logic,bash-patterns}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a NEW banner section at EOF (after pool_wait_for_lane):
                  #   # Wrapper shim — command dispatch (P1.M6.T1.S1)   ← NEW banner
                  #   pool_dispatch_classify:
                  #       local tok cmd next; cmd=""
                  #       while (( $# > 0 )); do
                  #           tok="$1"
                  #           case "$tok" in
                  #               --help|-h|--version) printf 'meta\n'; return 0 ;;      # short-circuit META
                  #               --session)            shift 2 || shift ;;               # space form: consume flag + value
                  #               --*)                  shift ;;                          # --json, --session=X, --headed, …
                  #               -*)                   shift ;;                          # -i -c -d -p … (-h caught above)
                  #               *)                    cmd="$1"; next="${2:-}"; break ;; # first non-flag = command
                  #           esac
                  #       done
                  #       [[ -n "$cmd" ]] || { printf 'driving\n'; return 0; }            # no command → default driving
                  #       if [[ "$cmd" == session && "$next" == list ]]; then printf 'meta\n'; return 0; fi
                  #       case "$cmd" in skills|dashboard|plugin|mcp) printf 'meta\n'; return 0 ;; esac
                  #       printf 'driving\n'; return 0                                     # DRIVING + unrecognized → driving
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **PRD §2.4 step-0 dispatcher** — a pure classifier the wrapper (M6.T3.S1) calls first to
decide META-passthrough vs DRIVING-lane-routing. It reads ONLY `"$@"`, writes ONLY one
stdout token, and depends on NOTHING (no globals, no init, no resolve). It is the gate that
keeps `skills`/`--help`/`--version`/`dashboard`/`plugin`/`mcp`/`session list` from spinning
up Chrome.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (default-to-driving, never enumerate DRIVING — research §2.2): contract steps
#   (c) DRIVING and (d) unrecognized BOTH return 'driving'. So a token is EITHER in the
#   META set (→ 'meta') OR everything else (→ 'driving'). Do NOT enumerate the DRIVING set
#   in code — it is documentation-only. Detecting META + defaulting the rest is functionally
#   identical and stays correct as agent-browser adds driving commands (mouse, react, …).
#   The full DRIVING list (external_deps.md §1.1, incl. dblclick) goes in a COMMENT.

# CRITICAL (--help/-h/--version SHORT-CIRCUIT to meta — research §2.3): the contract lists
#   these BOTH as "flags to skip" (a) AND as META commands (b). The ONLY reconciliation is:
#   when the scan hits --help/-h/--version, `printf 'meta\n'; return 0` IMMEDIATELY. This is
#   the sole reading under which `agent-browser --help` → 'meta'. (Semantically correct too:
#   they are always help/version requests, so passthrough is safe + avoids a lane acquire.)

# CRITICAL (session list is TWO-WORD META — research §2.5): 'session list' → 'meta', but
#   bare 'session' → 'driving' (session ∈ DRIVING set). The lookahead peeks the token
#   IMMEDIATELY after the command: `next="${2:-}"` captured at the `*)` break. So:
#     cmd==session && next==list → meta ;  otherwise (incl. session w/o list) → driving.
#   Edge: `session --json list` (flag between) classifies 'driving' — harmless (wrapper
#   execs it; the binary lists sessions anyway). Documented, not worth special-casing.

# CRITICAL (NO index counter — the (( i++ )) trap — research §3.1, lib/pool.sh:362-364):
#   a BARE `(( i++ ))` returns the OLD value of i; if i was 0 the result is 0 → rc 1 →
#   ABORTS under set -e. Avoided ENTIRELY by shift-based iteration (no index). The ONLY
#   `(( ))` is `while (( $# > 0 ))` — a CONDITION (errexit-exempt); when $#==0 it returns
#   rc 1 and the while exits cleanly. Prior art: lib/pool.sh:529 `while (( steps++ < 128 ))`.

# CRITICAL (shift 2 || shift for --session — research §3.2): a bare `shift 2` with < 2
#   params returns rc 1 → ABORTS under set -e. The `||`-list (`shift 2 || shift`) is
#   errexit-exempt (GNU -e: "any command in a || list except the last"). Handles the
#   trailing `--session`-with-no-value case: shift 2 fails → shift consumes just --session.

# CRITICAL (return 0 ALWAYS — research §2.6): there is NO failure mode. Every input yields
#   'meta' or 'driving'. This makes the caller's `class="$(pool_dispatch_classify "$@")"`
#   set -e-safe with NO guard (contrast pool_lease_find_mine which returns 1 on no-match and
#   REQUIRES `if …; then`). Do NOT add a non-zero return path.

# CRITICAL (NO precondition — research §2.7): dispatch is PRD §2.4 STEP 0, BEFORE owner
#   resolution (step 1). So read NO POOL_* globals, call NO pool_config_init /
#   pool_owner_resolve, depend on NOTHING but "$@". This is also why it is trivially unit-
#   testable (no fixtures / state dir / owner process).

# GOTCHA (stdout discipline — research §2.6): the ONLY stdout writes are `printf 'meta\n'`
#   and `printf 'driving\n'`. No _pool_log (writes a file+stderr, never stdout — but unused
#   here), no subcommand echoes. `class=$(pool_dispatch_classify …)` captures EXACTLY one
#   token. Mirrors pool_lanes_list (echoes lane numbers only).

# GOTCHA (set -u safe): `"$1"` is always set inside the loop (guarded by `(( $# > 0 ))`);
#   the lookahead uses `${2:-}` (defaults empty if absent). Both are set -u-safe.

# GOTCHA (case ordering — research §2.4): specific arms MUST precede generic —
#   `--help|-h|--version` and `--session` BEFORE the catch-all `--*`; `-h` is in the first
#   arm so the generic `-*` never sees it. FIRST MATCH WINS.

# GOTCHA (known limitation — research §1.3): commands like install/upgrade/doctor/profiles/
#   chat/auth are NOT in the contract's META set → default 'driving' → wrapper acquires a
#   lane before running them. They still WORK (binary handles them; forced session is
#   harmless for non-browser ops), just wasteful. This is the contract's deliberate
#   default-to-driving tradeoff. Do NOT extend the META set here (out of scope).

# GOTCHA (naming + placement — research §3.7): pool_dispatch_classify (PUBLIC, no `_`
#   prefix; matches the pool_dispatch_* family named in key_findings.md:215). APPEND at EOF
#   (after pool_wait_for_lane, ~line 2971) under a NEW "# Wrapper shim — command dispatch
#   (P1.M6.T1.S1)" banner. Single function, no private helper. NO new env vars/globals/files.

# GOTCHA (scope — classify ONLY): do NOT intercept 'close --all' or normalize 'connect'
#   (M6.T1.S2), strip '--session' or force AGENT_BROWSER_SESSION (M6.T2.S1), wire the
#   lifecycle (M6.T3.S1), or create bin/agent-browser (M6.T3.S2). Here connect/close just
#   classify 'driving' and --session is only SKIPPED (not removed).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change**, **no new env vars / globals**, and
**no data model**. It is a pure function over the positional parameters (`$@`). It reads
NO `POOL_*` globals (deliberately — see the NO-precondition invariant).

External commands: **NONE.** The function uses only bash builtins (`local`, `while`,
`case`, `shift`, `printf`, `return`, `[[ ]]`, `(( ))`). No `jq`, no `grep`, no subshells.
This is what makes it O(n), side-effect-free, and safe to call at lifecycle step 0.

**Naming** (codebase convention + `key_findings.md:215`): `pool_dispatch_classify` (public,
no `_` prefix; matches the `pool_dispatch_*` family). No private helper needed.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_wait_for_lane'   # confirms M5.T4.S1 LANDED (this task appends AFTER it)
  - EXPECT: pool_wait_for_lane reported as a function. If MISSING → the dependency that
        defines the current EOF is absent; append after the LAST function instead (see below).
  - RUN (confirm this task is greenfield — name absent, no prior dispatch art):
        grep -nE 'pool_dispatch_classify|Wrapper shim' lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield.
  - RUN (locate the append point = current EOF):
        grep -nE '^pool_wait_for_lane\(\)' lib/pool.sh   # M5.T4.S1 deliverable
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        # ALSO confirm the strict-mode header (this function inherits set -euo pipefail):
        sed -n '19p' lib/pool.sh   # expect: set -euo pipefail
  - EXPECT: pool_wait_for_lane defined (@~2909); its closing `}` is EOF (~line 2971).
        APPEND the new banner + function AFTER that closing brace. Line 19 = `set -euo pipefail`.
  - RUN (sanity: the tools this task's validation uses):
        command -v bash >/dev/null && command -v shellcheck >/dev/null && echo "OK tools" || echo "shellcheck absent"
  - EXPECT: OK tools (host has bash 5.x + ShellCheck 0.11.0). shellcheck absent is non-fatal
        but the success criterion requires it — install if missing.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND the new banner + pool_dispatch_classify() to lib/pool.sh
  - PLACEMENT: directly below pool_wait_for_lane's closing brace at EOF (~line 2972), under a
        NEW "# Wrapper shim — command dispatch (P1.M6.T1.S1)" banner.
  - IMPLEMENT (verbatim-ready — paste the banner + docstring + function at EOF):

# =============================================================================
# Wrapper shim — command dispatch (P1.M6.T1.S1)
# =============================================================================
# PRD §2.4 step 0 dispatcher. Classify an agent-browser invocation as 'meta'
# (passthrough — exec the real binary unchanged) or 'driving' (route to the agent's
# locked lane). ECHOES 'meta' or 'driving' on stdout; returns 0 ALWAYS. Called by the
# wrapper lifecycle (M6.T3.S1) as the VERY FIRST step, BEFORE owner resolution.

# pool_dispatch_classify [--] ARGS...
#
# Walk $@ left→right, skipping leading flags to find the first non-flag token (the
# command), then classify. Pure: reads NO globals, writes NO files, calls NO external
# commands. stdout = EXACTLY one token ('meta'|'driving'). Returns 0 always.
#
# LOGIC (item contract steps a–e):
#   a. Flag scan (first non-flag token = command):
#        --help | -h | --version  → echo 'meta'; return 0   (short-circuit: always a
#                                   help/version request — PRD §2.4 / external_deps §1.2 META)
#        --session <X>            → shift 2 (space form: consume flag + value)
#        --session=<X>            → shift 1 (equals form: value attached; caught by --*)
#        --json | <any --flag>    → shift 1 (caught by --*)
#        <any -shortflag except -h> → shift 1 (caught by -*)
#        <non-flag>               → the COMMAND; break (peek next token for session-list)
#   b. META classification:
#        'session' + next=='list' → 'meta'   (two-word command; bare 'session' is DRIVING)
#        cmd ∈ {skills, dashboard, plugin, mcp} → 'meta'
#   c. EVERYTHING ELSE → 'driving'. Covers the DRIVING set
#      (open/click/dblclick/type/fill/press/keyboard/hover/focus/check/uncheck/select/drag/
#       upload/download/scroll/scrollintoview/wait/screenshot/pdf/snapshot/eval/connect/
#       close/session/back/forward/reload/get/is/find — external_deps.md §1.1) AND
#   d. unrecognized commands (contract step d: "default to 'driving' — let the real binary
#      handle the error"). Because (c) and (d) BOTH yield 'driving', the DRIVING set is NOT
#      enumerated in code — detecting META + defaulting the rest is identical and stays
#      correct as agent-browser adds driving commands (mouse, react, …).
#   e. No command found (only flags / empty $@) → 'driving' (default, step d).
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle step 0; unit tests (M9).
#
# GOTCHA — return 0 ALWAYS. No failure mode ⇒ the caller's
#   `class="$(pool_dispatch_classify "$@")"` is set -e-safe with NO guard (unlike
#   pool_lease_find_mine which returns 1 on no-match and REQUIRES an `if` guard).
# GOTCHA — NO precondition. Callable BEFORE pool_config_init / pool_owner_resolve (dispatch
#   is PRD §2.4 STEP 0, before owner resolution step 1). Reads NO POOL_* globals. This also
#   makes it unit-testable with zero fixtures.
# GOTCHA — the loop guard `while (( $# > 0 ))` is a CONDITION (errexit-exempt). A BARE
#   `(( expr ))` statement whose value is 0 returns rc 1 and ABORTS under set -e
#   (lib/pool.sh:362-364). Shift-based iteration (NO index counter) avoids the
#   `(( i++ ))`-returns-0 trap entirely.
# GOTCHA — `shift 2 || shift` for --session: the `||`-list is errexit-exempt; tolerates a
#   trailing `--session` with no value (shift 2 fails → shift consumes just --session).
# GOTCHA — 'session list' (two-word) is META; bare 'session' is DRIVING. The lookahead
#   peeks the token immediately after the command (`next="${2:-}"`). session ∈ DRIVING so
#   'session <other>' → 'driving' via the default.
# GOTCHA — SCOPE: CLASSIFIES ONLY. Does NOT intercept 'close --all' / normalize 'connect'
#   (M6.T1.S2), strip '--session' / force AGENT_BROWSER_SESSION (M6.T2.S1), or wire the
#   lifecycle (M6.T3.S1). Here connect & close simply classify 'driving'.
# PRECONDITION: none. The function is pure.
pool_dispatch_classify() {
    local tok cmd next
    cmd=""
    while (( $# > 0 )); do
        tok="$1"
        case "$tok" in
            --help|-h|--version)
                printf 'meta\n'
                return 0
                ;;
            --session)
                # Space form: consume the flag AND its value. `|| shift` tolerates a
                # trailing --session with no value (shift 2 fails → shift 1). The `||`
                # list is errexit-exempt.
                shift 2 || shift
                ;;
            --*)
                # Any other long flag: --json, --session=X (equals form), --headed, …
                shift
                ;;
            -*)
                # Any short flag except -h (caught above): -i, -c, -d, -p, -v, -q, …
                shift
                ;;
            *)
                # First non-flag token = the command. Peek the next token (for the
                # 'session list' two-word META command) and stop scanning.
                cmd="$1"
                next="${2:-}"
                break
                ;;
        esac
    done

    # No command token found (only flags / empty $@) → default 'driving' (contract step d).
    if [[ -z "$cmd" ]]; then
        printf 'driving\n'
        return 0
    fi

    # META classification. (The DRIVING set + unrecognized commands all fall through to
    # the default 'driving' below — contract steps c & d.)
    if [[ "$cmd" == session && "$next" == list ]]; then
        printf 'meta\n'
        return 0
    fi
    case "$cmd" in
        skills|dashboard|plugin|mcp)
            printf 'meta\n'
            return 0
            ;;
    esac

    # Everything else → 'driving' (DRIVING set + unrecognized; contract c & d).
    printf 'driving\n'
    return 0
}

  - VERIFY (immediately after writing):
        bash -n lib/pool.sh && echo "OK syntax"
        grep -nE '^pool_dispatch_classify\(\)' lib/pool.sh   # confirm defined once
  - EXPECT: OK syntax; exactly one definition (near the new EOF).
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the shift-based flag scan (NO index counter; the only (( )) is the while
# condition, which is errexit-exempt). This is the canonical "find first non-flag token"
# idiom that sidesteps the (( i++ )) trap:
pool_dispatch_classify() {
    local tok cmd next
    cmd=""
    while (( $# > 0 )); do          # CONDITION — rc 1 when $#==0 exits the loop cleanly
        tok="$1"
        case "$tok" in
            --help|-h|--version) printf 'meta\n'; return 0 ;;   # short-circuit META
            --session)            shift 2 || shift ;;            # space form: flag + value
            --*)                  shift ;;                       # --json, --session=X, --headed…
            -*)                   shift ;;                       # -i -c -d -p … (-h caught above)
            *)                    cmd="$1"; next="${2:-}"; break ;; # first non-flag = command
        esac
    done
    # … META detection + default driving (see Task 1) …
}

# GOTCHA — why `shift 2 || shift` and NOT `shift 2` alone: under set -e a bare `shift 2`
# with < 2 remaining params returns rc 1 and ABORTS. The `||` makes it exempt.
# GOTCHA — why NO `(( i++ ))`: a bare `(( i++ ))` when i==0 returns rc 1 (OLD value) and
# ABORTS under set -e. The shift-based loop has no index, so the trap cannot occur.
# GOTCHA — why default-driving (no DRIVING enumeration): contract steps c & d both return
# 'driving', so enumerating the DRIVING set would be dead code. Detect META, default rest.
```

### Integration Points

```yaml
LIBRARY (lib/pool.sh):
  - append: "new banner '# Wrapper shim — command dispatch (P1.M6.T1.S1)' + pool_dispatch_classify at EOF"
  - pattern: "match the banner+docstring+function style of pool_lanes_list (@967) / pool_wait_for_lane (@2909)"

CONSUMERS (NOT built by this task — referenced for interface stability):
  - M6.T3.S1 wrapper lifecycle step 0:
        case "$(pool_dispatch_classify "$@")" in
            meta)    exec "$AGENT_BROWSER_REAL" "$@" ;;          # passthrough unchanged
            driving) <resolve → find/acquire lane → ensure → exec with forced session> ;;
        esac
  - Because pool_dispatch_classify returns 0 ALWAYS, the `case "$(…)"` capture is set -e-safe
    with NO `if` guard (unlike pool_lease_find_mine consumers).

NO CHANGES TO:
  - any existing function (M1–M5.T4.S1) — pure append.
  - any env var / global — reads none.
  - bin/ (still .gitkeep) — the executable is M6.T3.S2.
  - test/ (still .gitkeep) — the bats harness is M9.T1.S1.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the function — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings
# Expected: both OK. If shellcheck warns on the new function, READ it and fix (common:
#   none expected — `(( $# > 0 ))`, `shift 2 || shift`, `case` globs, `${2:-}` are all clean).
```

### Level 2: Unit Tests (Component Validation)

The bats harness lands in M9.T1.S1. For THIS task, validate via a direct bash script that
asserts stdout + rc for every scenario (the function is pure — no fixtures needed):

```bash
# Save as /tmp/test_dispatch.sh and run: bash /tmp/test_dispatch.sh
set -euo pipefail
source lib/pool.sh
pass=0; fail=0
# assert_meta ARGS...   — expect stdout 'meta', rc 0
# assert_driving ARGS... — expect stdout 'driving', rc 0
assert_meta() {
    local out rc
    out="$(pool_dispatch_classify "$@")"; rc=$?
    if [[ "$out" == meta && "$rc" -eq 0 ]]; then pass=$((pass+1));
    else fail=$((fail+1)); printf 'FAIL meta: args=[%s] got=[%s] rc=%s\n' "$*" "$out" "$rc" >&2; fi
}
assert_driving() {
    local out rc
    out="$(pool_dispatch_classify "$@")"; rc=$?
    if [[ "$out" == driving && "$rc" -eq 0 ]]; then pass=$((pass+1));
    else fail=$((fail+1)); printf 'FAIL driving: args=[%s] got=[%s] rc=%s\n' "$*" "$out" "$rc" >&2; fi
}
# --- META cases ---
assert_meta --help
assert_meta -h
assert_meta --version
assert_meta skills
assert_meta skills get core
assert_meta dashboard
assert_meta dashboard start
assert_meta plugin
assert_meta plugin add some-ref
assert_meta mcp
assert_meta session list
# --- DRIVING cases (enumerated + default) ---
assert_driving open https://example.com
assert_driving click '#btn'
assert_driving type '#q' 'hello'
assert_driving snapshot
assert_driving eval '1+1'
assert_driving get url
assert_driving find role button Click me
assert_driving connect 9222
assert_driving close --all
assert_driving session                 # bare session → driving
assert_driving session foo             # session <non-list> → driving
assert_driving dblclick '#x'           # not in contract DRIVING list → default driving
assert_driving install                 # unrecognized → default driving
assert_driving chat 'hi'               # unrecognized → default driving
# --- flag-skipping ---
assert_driving --json get url
assert_driving --json --session foo open https://x
assert_driving --session foo open https://x
assert_driving --session=foo open https://x
assert_meta --json --help              # --json skipped, then --help → meta
assert_meta --session foo --help       # --session consumes foo, then --help → meta
# --- no-command / edge cases (default driving) ---
assert_driving                         # no args at all
assert_driving --json                  # only a flag
assert_driving --session               # --session with no value
# --- report ---
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
# Expected: pass=34 fail=0 (34 cases). If ANY fail, debug root cause and fix the function.
```

### Level 3: Integration Testing (System Validation)

```bash
# Confirm NO regression in the library — all prior deliverables still load + are callable:
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
         type pool_acquire_locked pool_wait_for_lane pool_release_lane pool_reap_stale \
               pool_lanes_list pool_dispatch_classify' && echo "OK all callable"
# Expected: all reported as functions (incl. the new pool_dispatch_classify).

# Confirm pool_dispatch_classify needs NONE of the init (pure — callable on a bare source):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_dispatch_classify open http://x'   # → driving
bash -c 'set -euo pipefail; source lib/pool.sh; pool_dispatch_classify --help'          # → meta
# Expected: 'driving' then 'meta' on stdout, both rc 0 — with NO pool_config_init called.

# (The wrapper bin/agent-browser integration is M6.T3.S1/S2 — NOT validated here.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Pipe-aware check: stdout is EXACTLY one token (no trailing/leaking output). The line
# count must be 1 and the token must be exactly 'meta' or 'driving':
out="$(set -euo pipefail; source lib/pool.sh; pool_dispatch_classify skills get core)"
[[ "$(printf '%s' "$out" | wc -l)" -eq 1 && "$out" == meta ]] && echo "OK stdout-discipline" || echo "FAIL"

# Unknown-flag robustness: a flag the wrapper has never seen must be skipped (→ command
# classified), NOT treated as the command:
out="$(set -euo pipefail; source lib/pool.sh; pool_dispatch_classify --some-new-flag open http://x)"
[[ "$out" == driving ]] && echo "OK unknown-long-flag-skipped" || echo "FAIL: $out"

out="$(set -euo pipefail; source lib/pool.sh; pool_dispatch_classify -z open http://x)"
[[ "$out" == driving ]] && echo "OK unknown-short-flag-skipped" || echo "FAIL: $out"
# Expected: all OK. (Unknown flags fall to the --* / -* arms and are shifted; open is the command.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 passed: `bash -n lib/pool.sh` clean + `shellcheck -s bash lib/pool.sh` zero warnings.
- [ ] Level 2 passed: the 34-case dispatch script reports `pass=34 fail=0`.
- [ ] Level 3 passed: all prior functions still callable; `pool_dispatch_classify` works on a
      bare `source lib/pool.sh` (no init).
- [ ] Level 4 passed: stdout-discipline (exactly one token) + unknown-flag-skipping verified.

### Feature Validation

- [ ] All success-criteria rows in the "What" table met (META, DRIVING, default, edges).
- [ ] `--help`/`-h`/`--version` short-circuit to `meta`.
- [ ] `session list` → `meta`; `session` / `session foo` → `driving`.
- [ ] `--session <X>` and `--session=<X>` both skipped (space form via shift 2; equals form via --*).
- [ ] Unrecognized + no-command → `driving` (default).
- [ ] return 0 ALWAYS; reads no globals / writes no files / no external commands.

### Code Quality Validation

- [ ] Follows existing codebase patterns (banner + docstring + function style of
      `pool_lanes_list` / `pool_wait_for_lane`).
- [ ] File placement: appended at EOF under the new banner; no existing function touched.
- [ ] Anti-patterns avoided: no `(( i++ ))` index, no bare `shift 2`, no DRIVING enumeration,
      no non-zero return path, no global reads.
- [ ] Naming matches the `pool_dispatch_*` family (`key_findings.md:215`).

### Documentation & Deployment

- [ ] Docstring documents LOGIC (a–e), CONSUMERS, GOTCHAs, PRECONDITION (= none).
- [ ] No new env vars to document (the function reads none).
- [ ] Scope boundary vs M6.T1.S2 / M6.T2.S1 / M6.T3 clearly noted (classify only).

---

## Anti-Patterns to Avoid

- ❌ Don't enumerate the DRIVING set in code — steps (c) and (d) both return 'driving', so it
  is dead code. Detect META, default the rest. (Keep the list as a comment only.)
- ❌ Don't use an index counter (`(( i++ ))`) — a bare `(( i++ ))` with i==0 returns rc 1 and
  ABORTS under `set -e`. Use shift-based iteration.
- ❌ Don't write a bare `shift 2` — use `shift 2 || shift` (errexit-exempt; tolerates a
  trailing `--session` with no value).
- ❌ Don't add a non-zero return path — the function returns 0 ALWAYS (no failure mode); a
  non-zero path would force every caller to add an `if` guard for no reason.
- ❌ Don't read any `POOL_*` global or call `pool_config_init`/`pool_owner_resolve` — dispatch
  is PRD §2.4 STEP 0, before owner resolution; the function must be pure.
- ❌ Don't intercept `close --all`, normalize `connect`, strip `--session`, or force
  `AGENT_BROWSER_SESSION` here — those are M6.T1.S2 / M6.T2.S1. This task CLASSIFIES ONLY.
- ❌ Don't skip validation because "it should work" — run the 34-case script; the `session`
  vs `session list` distinction and the `--session=X` equals form are easy to get wrong.
