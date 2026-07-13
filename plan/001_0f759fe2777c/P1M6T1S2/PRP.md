# PRP — P1.M6.T1.S2: `pool_normalize_close()` + `pool_normalize_connect()` — intercept `close --all`, normalize `connect <arg>`

---

## Goal

**Feature Goal**: Implement the **two PRD §2.4 / §2.15 transparency normalizers** that rewrite
an agent's driving-class argv so the pool — not the agent — controls connection and teardown
scope. Specifically, append **two PURE library functions** to `lib/pool.sh`:

- **`pool_normalize_close(args...)`** — if the command is `close` AND `--all` is present,
  **strip every standalone `--all` token** so the real exec becomes session-scoped
  (`close --session abpool-<N>` once M6.T2.S1 forces the session). A raw `--all` would nuke
  **every** daemon session in the user's account — including other agents' lanes (PRD §2.4
  "never touch other owners' lanes"; §2.15 "close --all → cannot harm other agents' lanes").
  Sets an observability flag `POOL_CLOSE_ALL_SEEN=1` when it strips (the contract's literal
  "set a flag to close ONLY my session").
- **`pool_normalize_connect(args...)`** — if the command is `connect`, **strip the single
  `<port|url>` positional** that follows it (the upstream skill teaches `connect <port>`; the
  lane's real connection is owned by `pool_ensure_connected` / PRD §2.4 step 4 using the LANE's
  port from the lease, never the agent's arg).

Both functions write the **normalized argv to a NEW global array `POOL_NORM_ARGS`** and
**return 0 ALWAYS** (pure transforms — no failure mode). They run **after** `pool_dispatch_classify`
has returned `'driving'` (this task's precondition) and **before** M6.T2.S1 strips `--session` /
forces `AGENT_BROWSER_SESSION`.

This is a **pure addition**: ONE new banner `# Wrapper shim — arg normalization (P1.M6.T1.S2)`
appended at EOF of `lib/pool.sh` (currently line 3086, directly after `pool_dispatch_classify`),
containing the two functions. **NO edits to any existing function.** The functions read ONLY
`"$@"`; the ONLY globals they touch are the two OUTPUT-only contracts (`POOL_NORM_ARGS`,
`POOL_CLOSE_ALL_SEEN`). No `_pool_log`, no files, no external commands, no env vars consumed.

The functions implement the item CONTRACT verbatim (research §1 the codebase's return-convention
analysis + the close/connect CLI semantics verified live; research §2 the array-return / set-e
correctness; research `design-decisions.md` D1–D8 the concrete design choices):

**a.** `pool_normalize_close`: scan to find the command (mirror `pool_dispatch_classify`'s
      flag-scan). If cmd==`close`, rebuild args **minus every `--all` token**; set
      `POOL_CLOSE_ALL_SEEN=1` if any removed. Else `POOL_NORM_ARGS` = args unchanged.
**b.** `pool_normalize_connect`: scan to find the command. If cmd==`connect`, continue scanning
      to find the **first non-flag token after `connect`** (the `<port|url>`) and rebuild args
      **minus that one positional** (preserving `--json`/`--session`). Else unchanged.
**c.** Return normalized args via the `POOL_NORM_ARGS` global array. Consumed by the lifecycle
      integration (M6.T3.S1).

> **Why a global array and not stdout** (research `design-decisions.md` D1): agent-browser argv
> can contain spaces/newlines (URLs, `type` payloads) — stdout newline-echo (the `pool_lanes_list`
> style) is unsafe, and NUL+`mapfile -d ''` would be the codebase's first with a fragile empty-
> printf edge. The `declare -g` return convention (POOL_CHROME_PID @1514, POOL_CHROME_PGID @1528)
> extends naturally to `declare -ga` for an array — serialization-free and immune to special chars.

**Deliverable**: Two public functions (`pool_normalize_close`, `pool_normalize_connect`) +
two output globals (`POOL_NORM_ARGS`, `POOL_CLOSE_ALL_SEEN`), appended to `lib/pool.sh` under a
NEW `# Wrapper shim — arg normalization (P1.M6.T1.S2)` banner at EOF (after `pool_dispatch_classify`
@2977–3086). Pure append; no existing function touched.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh` (NO `pool_config_init` needed — the functions
  read only `"$@"`), every row below holds (stdout is EMPTY; rc is 0; `POOL_NORM_ARGS` shown
  space-separated for readability — the test harness joins with `|` to disambiguate elements;
  `SEEN` = `POOL_CLOSE_ALL_SEEN`):

  | input args (`"$@"`) | `POOL_NORM_ARGS` (joined) | SEEN | rc | rule |
  |---|---|---|---|---|
  | `close --all` | `close` | 1 | 0 | close + --all → strip --all |
  | `close` | `close` | 0 | 0 | close, no --all → unchanged |
  | `close --all --json` | `close --json` | 1 | 0 | strip --all, keep --json |
  | `--json close --all` | `--json close` | 1 | 0 | leading flag preserved; --all stripped |
  | `close --all --all` | `close` | 1 | 0 | strip EVERY --all |
  | `close --session foo --all` | `close --session foo` | 1 | 0 | --session PRESERVED (M6.T2.S1 strips it) |
  | `close --json` | `close --json` | 0 | 0 | close, no --all → unchanged |
  | `find role x --all` | `find role x --all` | 0 | 0 | cmd≠close → --all KEPT (not a close flag) |
  | `open https://x` | `open https://x` | 0 | 0 | cmd≠close → unchanged |
  | `connect 9222` | `connect` | (0) | 0 | connect → strip port positional |
  | `connect ws://h:9222/devtools/browser/abc` | `connect` | (0) | 0 | connect → strip url positional |
  | `connect https://example.com` | `connect` | (0) | 0 | connect → strip url positional |
  | `--json connect 9222` | `--json connect` | (0) | 0 | leading flag preserved; port stripped |
  | `connect --json 9222` | `connect --json` | (0) | 0 | flag between cmd and positional; keep --json, strip port |
  | `connect --session foo 9222` | `connect --session foo` | (0) | 0 | --session value skipped; port stripped; --session PRESERVED |
  | `connect` (bare) | `connect` | (0) | 0 | no positional → nothing to strip |
  | `type '#q' 'hello world'` | `type #q hello world` | (0) | 0 | **spaces preserved** (robustness) |
  | *(no args)* / `--json` *(alone)* | *(empty)* / `--json` | 0 | 0 | no command → unchanged |

  *(For `pool_normalize_connect`, `SEEN` is irrelevant — only `pool_normalize_close` sets
  `POOL_CLOSE_ALL_SEEN`. The `(0)` means "leave it as-is / don't care".)*

- **Composition** (the lifecycle pattern M6.T3.S1 will use — call BOTH in sequence, each self-gating):
  - `close --all` → close sets `(close)` → connect reads `(close)` (cmd=`close`≠`connect` ⇒ no-op)
    ⇒ final `(close)`.
  - `connect 9222` → close no-op (cmd=`connect`≠`close` ⇒ `(connect 9222)`) → connect strips `9222`
    ⇒ final `(connect)`.
  - `open https://x` → both no-ops ⇒ final `(open https://x)`.
- **Every** call returns rc 0; **stdout is EMPTY** (all output is via the two globals — never
  `printf`/`echo` to stdout). A `set -u` shell does not abort (`local -a orig=("$@")` is always
  declared; index arithmetic uses the assignment form `i=$((i+1))`).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero warnings
  — host-verified ShellCheck 0.11.0); all prior deliverables (M1–M6.T1.S1) unchanged and callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its sole consumers (per
the item CONTRACT §4 "Consumed by lifecycle integration (M6.T3)" + PRD §2.4 step 5) are:

- **M6.T3.S1 wrapper lifecycle** — after classifying `'driving'` and acquiring lane N, the
  wrapper normalizes the agent's argv so the pool controls teardown/connection scope, then execs
  the real binary with `AGENT_BROWSER_SESSION=abpool-<N>` forced. Pseudocode (M6's concern; this
  task ships the two normalizers only):
  ```bash
  case "$(pool_dispatch_classify "$@")" in
      meta)    exec "$AGENT_BROWSER_REAL" "$@" ;;                       # passthrough unchanged
      driving) # resolve owner → find/acquire lane N (M5); pool_ensure_connected (M5.T1.S3)
               pool_normalize_close  "$@"                               # THIS TASK (close --all)
               pool_normalize_connect "${POOL_NORM_ARGS[@]}"            # THIS TASK (connect arg)
               # M6.T2.S1 next: strip inherited --session, force AGENT_BROWSER_SESSION=abpool-$N
               [[ "$POOL_CLOSE_ALL_SEEN" == 1 ]] && _pool_log "intercepted close --all → scoped to lane $N"
               exec "$AGENT_BROWSER_REAL" "${POOL_NORM_ARGS[@]}"        # env session forced by M6.T2.S1
               ;;
  esac
  ```
- **Unit tests (M9)** — the functions are pure (read only `"$@"`, write only 2 globals), so they
  need ZERO fixtures (no state dir, no owner process, no Chrome) — directly testable after a bare
  `source lib/pool.sh`.

**Use Case**: An AI agent (a `pi` child) invokes `agent-browser` hundreds of times per task via
stateless bash calls, following `skills get core` to the letter. The skill teaches
`agent-browser connect <port>` and `agent-browser close`/`close --all`. Without interception:
`connect <port>` would point the daemon at the WRONG Chrome (or a non-existent one); `close --all`
would tear down **every** agent's browser in the account. These two normalizers make those
skill-taught invocations land safely on the agent's own lane — the agent has "no idea" it is pooled
(PRD §2.15 "no idea" contract).

**Pain Points Addressed**:
- **`close --all` nukes peers.** A single agent running the skill's `close --all` would disconnect
  every other agent's daemon session (PRD §2.4, §2.15). Stripping `--all` + forcing the lane
  session scopes teardown to MY lane only.
- **`connect <port>` points at the wrong browser.** The skill passes a port the agent guessed; the
  pool must connect to the LANE's Chrome on the lane's allocated port (owned by `pool_ensure_connected`
  / PRD §2.4 step 4). Stripping the agent's arg makes the connect a no-op-on-the-arg while the lane
  stays correctly bound.

## Why

- **This IS PRD §2.4 "Transparent absorption of upstream-skill patterns" + §2.15 transparency
  checklist.** The two skill-taught invocations that would break pooling (`connect <x>`, `close --all`)
  are rewritten so the agent's literal skill-following commands land on its lane. §2.4: "`agent-browser
  connect [<anything>]` → ensure my lane connected; ignore the arg." §2.4: "`agent-browser close [--all]`
  → disconnect my lane's daemon only; never touch other owners' lanes (raw --all would nuke peers)."
- **It is the safety boundary of the pool.** Every other lane's Chrome/daemon survives an agent's
  `close --all` BECAUSE of this function. Getting it wrong = a single agent can brick every peer's
  browser. (PRD §2.17 coexistence: the pool coexists with non-pool sessions AND other pool agents.)
- **It is deliberately minimal and pure.** Reads only `"$@"`, writes only 2 output globals, no
  `_pool_log`/files/external-commands → trivially unit-testable with zero fixtures (like
  `pool_dispatch_classify`). No non-zero return path ⇒ the caller needs no `if` guard.
- **It composes cleanly with the sibling tasks.** It does NOT classify (M6.T1.S1, already landed),
  does NOT strip `--session`/force env (M6.T2.S1), does NOT wire the lifecycle (M6.T3.S1). It only
  rewrites `close`/`connect` argv; everything else passes through untouched.

## What

User-visible behavior: none directly (internal functions). Observable contract — given
`source lib/pool.sh`, each function's effect on `POOL_NORM_ARGS` / `POOL_CLOSE_ALL_SEEN` / rc:

### `pool_normalize_close "$@"`

- Scans `"$@"` (mirroring `pool_dispatch_classify`) to find the COMMAND (first non-flag, where
  `--session <X>` consumes 2, `--session=X`/any `--flag`/any `-shortflag` consume 1).
- If command == `close`: rebuilds `POOL_NORM_ARGS` = args **with every token equal to `--all`
  removed**; sets `POOL_CLOSE_ALL_SEEN=1` iff at least one `--all` was removed (else `0`).
  All other tokens (`--json`, `--session <X>`, the literal `close`, any extra args) are PRESERVED
  in original order.
- If command ≠ `close` (or no command): `POOL_NORM_ARGS` = args **unchanged**; `POOL_CLOSE_ALL_SEEN=0`.
  (So `find role x --all` keeps its `--all` — it is not a close flag here.)
- stdout: **EMPTY**. rc: **0 ALWAYS**.

### `pool_normalize_connect "$@"`

- Scans `"$@"` to find the COMMAND (same mirrored scan).
- If command == `connect`: continues scanning **past** the command; the **first non-flag token**
  encountered (skipping `--session <X>`'s value, `--session=X`, `--json`, etc.) is the `<port|url>`
  positional — rebuilds `POOL_NORM_ARGS` = args **minus that ONE positional** (all flags + `connect`
  preserved in order). If there is no positional (bare `connect`), `POOL_NORM_ARGS` = args unchanged.
- If command ≠ `connect` (or no command): `POOL_NORM_ARGS` = args **unchanged**.
- stdout: **EMPTY**. rc: **0 ALWAYS**. (Does NOT touch `POOL_CLOSE_ALL_SEEN`.)

**Hard invariants** (both functions, every input):
- **return 0 ALWAYS; stdout EMPTY.** There is no failure mode. The caller needs no `if` guard.
  The normalized argv is delivered SOLELY via the `POOL_NORM_ARGS` global array. (Contrast
  `pool_lease_find_mine` which echoes N on stdout and returns 1 on no-match — different idiom for a
  single scalar; here we need an ARRAY, which cannot safely go on stdout.)
- **Output = `POOL_NORM_ARGS` (global array, `declare -ga`).** Always fully reassigned each call
  (no stale elements). The caller reads `"${POOL_NORM_ARGS[@]}"`. Robust for args containing
  spaces/newlines (no serialization).
- **`pool_normalize_close` also sets `POOL_CLOSE_ALL_SEEN`** (scalar `declare -g`, 0/1) — the
  contract's "set a flag." It is the lifecycle's observability hook (log "intercepted close --all
  → scoped to lane N" for the §2.15 transparency record). The ACTUAL "close only my session"
  scoping is achieved by stripping `--all` (here) + forcing `--session abpool-<N>` (M6.T2.S1).
- **NO precondition.** Callable BEFORE `pool_config_init` / `pool_owner_resolve` (the functions read
  NO `POOL_*` config globals — only `"$@"`). This mirrors `pool_dispatch_classify` and makes them
  unit-testable with zero fixtures.
- **Command detection MIRRORS `pool_dispatch_classify`** exactly (`--session`→consume 2; other
  `--*`/`-*`→consume 1; first non-flag = command). Using the identical scan guarantees the two
  siblings locate the SAME command token → they can never disagree. (research `design-decisions.md` D2.)
- **`--session` is NOT touched by either function** — it is preserved for M6.T2.S1 to strip/override.
  Here `--session <X>` is only SKIPPED (its value consumed) during the command/positional scan.
- **SELF-GATING & idempotent.** Each function is a no-op when the command does not match. The
  lifecycle calls BOTH in sequence (close then connect); at most one ever mutates the args.
- **`(( ))` safety:** the only `(( ))` uses are `while (( i < ${#orig[@]} ))` (loop condition —
  errexit-exempt) and `if (( j == strip_idx ))` (if-condition — exempt). Index increment uses the
  ASSIGNMENT form `i=$((i+1))` (always rc 0). NO bare `(( i++ ))` (returns rc 1 when i==0 → ABORT
  under set -e; the trap documented at lib/pool.sh:362-365).

### Success Criteria

- [ ] `pool_normalize_close` + `pool_normalize_connect` defined (PUBLIC, no `_` prefix) under a NEW
      `# Wrapper shim — arg normalization (P1.M6.T1.S2)` banner at EOF. Callable after a bare
      `source lib/pool.sh` (NO init needed).
- [ ] `close --all` → `POOL_NORM_ARGS=(close)`, `POOL_CLOSE_ALL_SEEN=1`, rc 0; stdout empty.
- [ ] `close --all --all` / `--json close --all` / `close --session foo --all` → all `--all`
      stripped; `--json`/`--session foo` PRESERVED; SEEN=1.
- [ ] `close` / `close --json` (no --all) → unchanged; SEEN=0.
- [ ] cmd≠close with `--all` present (`find role x --all`) → `--all` KEPT (no strip); SEEN=0.
- [ ] `connect <port>` / `connect <url>` → positional stripped; `POOL_NORM_ARGS=(connect)`; rc 0.
- [ ] `--json connect 9222` / `connect --json 9222` / `connect --session foo 9222` → port stripped;
      `--json`/`--session foo` PRESERVED.
- [ ] bare `connect` (no positional) → unchanged.
- [ ] cmd≠connect (`open https://x`) → unchanged.
- [ ] **Spaces preserved**: `type '#q' 'hello world'` → `POOL_NORM_ARGS` = `(type #q "hello world")`
      (the 3rd element is the single string `hello world`, not split).
- [ ] no-args / only-flags → `POOL_NORM_ARGS` = input unchanged; SEEN=0; rc 0.
- [ ] return 0 ALWAYS; stdout EMPTY; reads no config globals / writes no files / no external cmds;
      `set -u`-safe.
- [ ] Composition: calling close-then-connect on `close --all`, `connect 9222`, `open <url>` each
      yields the correct final `POOL_NORM_ARGS` (per the Goal table).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file);
      all prior deliverables (M1–M6.T1.S1) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **return-convention decision** (research
`design-decisions.md` D1 — why global array not stdout/nameref/mapfile, with the codebase's
`declare -g` precedent cited); the **command-scan mirror decision** (D2 — why reuse classify's
exact scan, with the safety analysis showing it can never let a real `close --all` through); the
**close/connect CLI semantics** (research §1.3 — `--all` is the ONLY close flag; `<port|url>` is
REQUIRED for connect and bare connect errors exit 1; `--json`/`--session` are global opts in any
position); the **composition model** (D3 — sequential self-gating calls); the **scope boundary**
(D6 + scope notes — does NOT touch `--session`/classify/lifecycle); the **bash correctness**
(research §2 — `i=$((i+1))` always rc 0, `while/if (( ))` exempt, no bare `(( i++ ))`,
`declare -ga NAME=(…)` canonical); the **full verbatim-ready implementation** (Implementation
Tasks Task 1); and a copy-pasteable, host-verified 24-case validation script.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 "Transparent absorption of upstream-skill patterns" IS this task
        ("connect [<anything>] → ensure my lane connected; ignore the arg"; "close [--all] →
        disconnect my lane's daemon only; never touch other owners' lanes (raw --all would nuke
        peers)"). §2.4 step 5 (the final exec: AGENT_BROWSER_SESSION=abpool-<N> forced + original
        args; strip inherited --session). §2.5 ("agent-browser close (mid-task) = disconnect-only").
        §2.15 transparency checklist ("close --all → cannot harm other agents' lanes").
  pattern: §2.4's two bullet rewrites ARE the close/connect contracts.
  gotcha: §2.4 step 4 ensure_connected ALREADY binds the lane's daemon — so the agent's connect
        arg is redundant and must be stripped (this task); the lane port comes from the lease.

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M6T1S2/research/design-decisions.md
  why: D1 (global-array output channel) D2 (mirror classify's scan) D3 (sequential self-gating
        composition) D4 (strip every --all iff close) D5 (strip first non-flag positional after
        connect) D6 (CRITICAL: bare connect errors exit 1 — M6.T3.S1 handoff) D7 (return 0 always,
        pure) D8 (placement/naming). This is the design spine.
  pattern: D3's composition snippet IS the lifecycle integration.
  gotcha: D6 — bare connect is a runtime ERROR; M6.T3.S1 must not naively exec it.
- file: plan/001_0f759fe2777c/P1M6T1S2/research/codebase-internal.md
  why: §1 the return-convention census (27× declare -g scalar; 0 nameref; 0 mapfile -d; the ONLY
        multi-token-stdout is pool_lanes_list which echoes simple integers — UNSAFE for argv);
        §2 the set-e/(( )) trap (lib/pool.sh:362-365) + the exact classify case-arms to mirror;
        §3 the live close/connect/help semantics (--all is the only close flag; <port|url>
        REQUIRED; bare connect → exit 1; --json/--session are global opts anywhere); §4 the scope
        boundary vs M6.T2.S1/M6.T3.S1 (FINAL exec = STRIP --session + FORCE env, M6.T2.S1's job);
        §5 shellcheck is 100% clean today + the SC codes to avoid (SC2155/SC2086/SC2178/SC2128).
  pattern: §2's exact classify case-arms ARE the scan to mirror.
  gotcha: §3 — MANY agent-browser flags take values (--cdp/--state/--executable-path/…); classify
        treats them as bool (shift-1). Mirror that EXACTLY (do NOT enumerate value-flags) so the
        two siblings agree; safe per design-decisions D2.
- file: plan/001_0f759fe2777c/P1M6T1S2/research/bash-external.md
  why: §1 `declare -ga NAME=(…)` is the canonical atomic global-array form (keeps values,
        shellcheck-clean) + the local-shadow footgun (NOT a risk here — lifecycle reads at top
        scope); §2 `i=$((i+1))` always rc 0, `while/if (( ))` exempt, `shift 2 || shift` non-last
        exempt, C-style `for ((;;))` arithmetic safe; §3 `local -a orig=("$@")`, `set -- "${orig[@]}"`,
        rebuild-skip-one loop; §4 conditional-strip-only-when-cmd==X, --session consumes 2.
  pattern: §1 Snippet 1 (global-array return) + §3 Snippet 3 (index rebuild-skip-one) ARE the
        implementation templates.
  gotcha: §1 Finding 7 — `printf '%s\0' "${a[@]}"` on an EMPTY array emits ONE NUL (spurious empty
        element) — AVOIDED entirely by using the global-array idiom (no serialization).

# Architecture
- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §1.3 the Session/Connection special-handling table IS this task's contract
        ("connect <port>/<url> → Ignore the arg. Ensure MY lane connected."; "close --all →
        Intercept: disconnect MY lane only. NEVER close --all"). §1.4 the plumbing subcommands
        (connect/close/get cdp-url semantics).
  pattern: §1.3 table rows = the two functions' behavior.
  gotcha: §1.3 — "Strip the agent's --session flag" / "Override env to abpool-<N>" is M6.T2.S1,
        NOT this task.

# The LANDED sibling whose scan this task MIRRORS (treated as CONTRACT)
- file: plan/001_0f759fe2777c/P1M6T1S1/PRP.md   # pool_dispatch_classify (M6.T1.S1 — LANDED @2977-3086)
  why: the IMMEDIATE sibling and EOF insertion point. Its `while (( $# > 0 )); do case ... --session)
        shift 2 || shift ;; --session=*) ... --*) shift ;; -*) shift ;; *) cmd="$1" ...` scan is the
        EXACT idiom this task reuses (as an index-based loop) to find the command. Its GOTCHA notes
        (return 0 always; no precondition; the (( i++ )) trap; scope boundary) are inherited.
  pattern: the flag-scan case-arms + the "return 0 always, stdout discipline, NO precondition"
        contract.
  gotcha: its scope note "Does NOT intercept close --all / normalize connect (M6.T1.S2)" — THAT is
        this task. Mirror its scan; do NOT re-implement classification.

# The LANDED functions whose CONVENTIONS this task follows
- file: lib/pool.sh   # pool_chrome_launch @1471-1568 (declare -g return idiom)
  why: lines 1514 (`POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID`) and 1528
        (`POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID`) ARE the codebase's return-via-global
        idiom this task extends to `declare -ga` (array) for POOL_NORM_ARGS + `declare -g` (scalar)
        for POOL_CLOSE_ALL_SEEN. Mirror the assign-then-declare-g form for the scalar flag.
  pattern: the `VAR=value; declare -g VAR` (scalar) + this task's `declare -ga VAR=( "${out[@]}" )`
        (array, atomic single-statement per bash-external §1).
- file: lib/pool.sh   # lines 1-19 (header + strict mode), 360-366 (the (( )) trap doc)
  why: line 18 `set -euo pipefail` is INHERITED. Lines 362-365 document in-place the bare-`(( ))`
        -returns-rc1-when-result-0 trap — the exact reason this task uses `i=$((i+1))` (assignment,
        always rc 0) and NEVER `(( i++ ))`.
- file: lib/pool.sh   # pool_dispatch_classify @2977-3086 (the scan to mirror + the EOF append point)
  why: the append goes directly AFTER this function's closing brace (currently line 3086).
```

### Current Codebase tree

After **M1–M6.T1.S1** have landed, `lib/pool.sh` (3086 lines) ends with `pool_dispatch_classify`
(@2977 banner; function body @3030; closing brace = EOF @3086). The last banner (@2973–2975) reads
`# Wrapper shim — command dispatch (P1.M6.T1.S1)`:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6.T3.S2 populates)
├── lib/
│   └── pool.sh                           # ends (after M6.T1.S1) with pool_dispatch_classify at EOF.
│                                         #   Banner order at EOF:
│                                         #   # Wrapper shim — command dispatch (P1.M6.T1.S1)  ← @2973
│                                         #   pool_dispatch_classify  ← current EOF (~line 3086)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M6T1S1/PRP.md
    └── P1M6T1S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-internal,bash-external,design-decisions}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a NEW banner section at EOF (after pool_dispatch_classify):
                  #   # Wrapper shim — arg normalization (P1.M6.T1.S2)   ← NEW banner
                  #   pool_normalize_close:
                  #       - scan $@ (mirror classify) to find command
                  #       - if cmd==close: POOL_NORM_ARGS = args minus every --all; POOL_CLOSE_ALL_SEEN=1
                  #       - else:          POOL_NORM_ARGS = args unchanged; POOL_CLOSE_ALL_SEEN=0
                  #       - return 0 ALWAYS; stdout EMPTY
                  #   pool_normalize_connect:
                  #       - scan $@ to find command; if cmd!=connect: POOL_NORM_ARGS = args unchanged
                  #       - if cmd==connect: find first non-flag AFTER connect (the <port|url>);
                  #         POOL_NORM_ARGS = args minus that ONE positional (flags preserved)
                  #       - return 0 ALWAYS; stdout EMPTY
                  #   (OUTPUT-ONLY globals: POOL_NORM_ARGS [declare -ga array], POOL_CLOSE_ALL_SEEN [declare -g 0/1])
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**PRD §2.4 / §2.15 transparency normalizers** — two pure argv rewriters the wrapper (M6.T3.S1)
calls (after classify, after acquire) to guarantee `close --all` cannot nuke peer lanes and
`connect <port>` cannot point at the wrong Chrome. They read ONLY `"$@"`, write ONLY the two
output globals, and depend on NO config/init.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (OUTPUT = GLOBAL ARRAY, not stdout — research design-decisions D1): agent-browser argv
#   can contain spaces/newlines (URLs, type payloads). stdout newline-echo (pool_lanes_list style)
#   is UNSAFE for argv; NUL+mapfile would be the codebase's FIRST with a fragile empty-printf edge.
#   The codebase's return-via-declare-g convention (POOL_CHROME_PID @1514, POOL_CHROME_PGID @1528)
#   extends naturally to `declare -ga POOL_NORM_ARGS=( "${out[@]}" )`. The normalized argv is read
#   by the caller as `"${POOL_NORM_ARGS[@]}"`. stdout stays EMPTY.

# CRITICAL (MIRROR classify's scan — research design-decisions D2): reuse pool_dispatch_classify's
#   EXACT flag-scan (--session → consume 2; --session=X/any --*/any -* → consume 1; first non-flag
#   = command). Do NOT enumerate agent-browser's value-flags (--cdp/--state/--executable-path/…).
#   Using the identical scan guarantees the two siblings locate the SAME command token → they can
#   never disagree. SAFE for the close --all contract: a real `close`/`connect` token is NEVER
#   consumed as a flag's value under this scan (value-flags are treated as bools → their would-be
#   value becomes the command). The only theoretical miss needs a value-flag whose VALUE is literally
#   `close`/`connect` + a trailing `--all` — contrived; degrades to a harmless passthrough/strip.

# CRITICAL (close --all SAFETY — PRD §2.4/§2.15): a raw `close --all` nukes EVERY daemon session in
#   the account (all agents' lanes + non-pool sessions). This function MUST strip --all whenever the
#   command is close. Stripping is CONDITIONAL on cmd==close: `find role x --all` must KEEP its --all
#   (not a close flag). Strip EVERY standalone --all token (handle `close --all --all`).

# CRITICAL (bare connect is a RUNTIME ERROR — research design-decisions D6): host-verified,
#   `agent-browser connect` (no arg) → "Missing arguments for: connect" exit 1 (<port|url> REQUIRED).
#   After this task strips the arg, the result is bare `connect`. PRD §2.4 step 4 (pool_ensure_connected)
#   ALREADY binds the lane's daemon — so the agent's connect is semantically absorbed. M6.T3.S1 must
#   NOT naively exec a bare connect (the agent would see an error → breaks §2.15 transparency). THIS
#   TASK strips the arg per contract; it does NOT decide how the bare result is exec'd.

# CRITICAL (the (( i++ )) trap — lib/pool.sh:362-365): a BARE `(( i++ ))` returns rc 1 when i was 0
#   → ABORTS under set -e. Use the ASSIGNMENT form `i=$((i+1))` (always rc 0). The ONLY (( )) uses
#   here are `while (( i < ${#orig[@]} ))` (loop COND — exempt) and `if (( j == strip_idx ))` (if
#   COND — exempt). Prior art: pool_dispatch_classify `while (( $# > 0 ))` @3035.

# CRITICAL (return 0 ALWAYS — research design-decisions D7): NO failure mode. Every input yields a
#   normalized POOL_NORM_ARGS. Do NOT add a non-zero return path (it would force every caller to add
#   an if-guard for nothing). Mirrors pool_dispatch_classify's "return 0 always."

# CRITICAL (stdout EMPTY): the ONLY output channel is the POOL_NORM_ARGS global (+ POOL_CLOSE_ALL_SEEN
#   for close). NEVER printf/echo to stdout. This lets the caller treat the call as a pure side-effect
#   on globals. (Contrast pool_lanes_list / pool_dispatch_classify which echo tokens — those return
#   single scalars; an argv ARRAY cannot safely go on stdout.)

# CRITICAL (NO precondition): read NO POOL_* config globals (dispatch is step 0; normalize is step
#   ~post-acquire but reads ONLY "$@"). Callable after a bare source lib/pool.sh — unit-testable with
#   zero fixtures. Do NOT call pool_config_init / pool_owner_resolve / _pool_log.

# GOTCHA (--session is NOT touched here — M6.T2.S1's job): both functions only SKIP --session (consume
#   its value) during the command/positional scan; they PRESERVE it in POOL_NORM_ARGS for M6.T2.S1 to
#   strip + force AGENT_BROWSER_SESSION=abpool-<N>. `close --session foo --all` → `(close --session foo)`;
#   `connect --session foo 9222` → `(connect --session foo)`.

# GOTCHA (self-gating + sequential composition — research design-decisions D3): each function is a
#   no-op when the command does not match. The lifecycle calls BOTH in sequence (close then connect);
#   at most one ever mutates the args. For connect: close is a no-op (POOL_NORM_ARGS=orig); connect
#   then strips the positional. For close: connect is a no-op. Verified correct for all cases.

# GOTCHA (POOL_NORM_ARGS fully reassigned each call): `declare -ga POOL_NORM_ARGS=( "${out[@]}" )`
#   REPLACES the array (no stale elements from a prior call). Safe to call repeatedly / in sequence.

# GOTCHA (set -u + empty array): `local -a orig=("$@")` and `local -a out=()` are pre-declared →
#   `"${orig[@]}"` / `"${out[@]}"` on an empty array are set -u-safe in bash 5.x. `"${POOL_NORM_ARGS[@]}"`
#   is also safe (declare -ga makes it exist). Reading the empty POOL_NORM_ARGS after a no-arg call →
#   expands to nothing (the next call gets 0 positional params) — correct.

# GOTCHA (placement + naming): APPEND at EOF (after pool_dispatch_classify, ~line 3086) under a NEW
#   "# Wrapper shim — arg normalization (P1.M6.T1.S2)" banner. Public names pool_normalize_close /
#   pool_normalize_connect (no `_` prefix; pool_* family). NO new env vars CONSUMED (read only "$@");
#   the two globals are OUTPUT-only. NO edits to any existing function.

# GOTCHA (shellcheck — keep it clean): the file is 100% clean today (SC2034 disables only @124/@1569).
#   This task adds ZERO net warnings. Avoid SC2155 (the array literal `declare -ga X=( "${out[@]}" )`
#   has NO command substitution → no status to mask → clean; the scalar uses the split
#   `POOL_CLOSE_ALL_SEEN=$v; declare -g POOL_CLOSE_ALL_SEEN` form like pool_chrome_launch @1514).
#   Avoid SC2086 (quote "$1", "${orig[@]}", "${out[@]}"). Avoid SC2178/SC2128 (always expand arrays
#   as "${arr[@]}", never $arr).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change**, **no new env vars consumed**, and **no lease/data
model**. It introduces **two OUTPUT-only globals**:

- `POOL_NORM_ARGS` — global **array** (`declare -ga`); the normalized argv. Always fully reassigned
  by each function. Read by the caller as `"${POOL_NORM_ARGS[@]}"`.
- `POOL_CLOSE_ALL_SEEN` — global **scalar** (`declare -g`); `0`/`1`; set ONLY by `pool_normalize_close`
  (`1` iff it stripped at least one `--all` from a `close` command). Observability hook for the
  lifecycle (PRD §2.15 transparency record).

External commands: **NONE.** The functions use only bash builtins (`local`, `while`, `case`,
`for`, `if`, `[[ ]]`, `(( ))`, `$(( ))`, `declare -g`/`-ga`, `return`). No `jq`, no `grep`, no
subshells, no `_pool_log`. This makes them pure, O(n), and safe to call before/after any init.

**Naming**: `pool_normalize_close` / `pool_normalize_connect` (public, no `_` prefix; `pool_*` family).
No private helper needed (each scan is short and reuses the classify idiom).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_dispatch_classify pool_ensure_connected'
  - EXPECT: both reported as functions. (pool_dispatch_classify = M6.T1.S1 LANDED @3030; this task
        appends AFTER it. pool_ensure_connected = M5.T1.S3, the lane-connection owner this task
        complements — confirms the §2.4 step-4 connection is already handled elsewhere.)
  - RUN (confirm this task is greenfield):
        grep -nE 'pool_normalize_close|pool_normalize_connect|POOL_NORM_ARGS|POOL_CLOSE_ALL_SEEN|arg normalization' \
            lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield.
  - RUN (locate the append point = current EOF + confirm the scan to mirror):
        grep -nE '^pool_dispatch_classify\(\)' lib/pool.sh    # M6.T1.S1 deliverable (@3030)
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh     # closing brace = EOF (~3086)
        sed -n '3035,3060p' lib/pool.sh                        # the exact scan case-arms to MIRROR
        sed -n '19p' lib/pool.sh                               # expect: set -euo pipefail
  - EXPECT: pool_dispatch_classify defined (@3030); its `while (( $# > 0 ))` + case-arms (--session)
        shift 2 || shift ;; --* / -* shift ;; *) cmd="$1" ...) ARE the idiom to mirror as an
        index-based loop. Line 18 = `set -euo pipefail`. EOF ~3086.
  - RUN (confirm the agent-browser CLI semantics this task depends on):
        agent-browser close --help 2>&1 | grep -iE '\-\-all|--session|--json'   # --all = only close opt
        agent-browser connect --help 2>&1 | grep -iE 'port|url|usage'           # <port|url> required
  - EXPECT: close --all is the only close-specific option; connect usage = `connect <port|url>`.
  - RUN (sanity tools): command -v bash >/dev/null && command -v shellcheck >/dev/null && echo "OK tools"
  - EXPECT: OK tools (bash 5.x + ShellCheck 0.11.0).
  - RUN: bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh && echo "OK clean baseline"
  - EXPECT: OK clean baseline (zero warnings — the bar this task must NOT lower).

Task 1: APPEND the new banner + pool_normalize_close() + pool_normalize_connect() to lib/pool.sh
  - PLACEMENT: directly below pool_dispatch_classify's closing brace at EOF (~line 3087), under a
        NEW "# Wrapper shim — arg normalization (P1.M6.T1.S2)" banner.
  - IMPLEMENT (verbatim-ready — paste the banner + docstrings + functions at EOF):

# =============================================================================
# Wrapper shim — arg normalization (P1.M6.T1.S2)
# =============================================================================
# PRD §2.4 / §2.15 transparency normalizers. Rewrite an agent's DRIVING argv so the
# pool — not the agent — controls connection & teardown scope. Called by the wrapper
# lifecycle (M6.T3.S1) AFTER pool_dispatch_classify returned 'driving' and the lane is
# acquired, BEFORE M6.T2.S1 strips --session / forces AGENT_BROWSER_SESSION.
#
# Output channel = the GLOBAL ARRAY POOL_NORM_ARGS (declare -ga) — NOT stdout (argv can
# contain spaces/newlines; stdout is unsafe for an array). pool_normalize_close also sets
# the scalar GLOBAL POOL_CLOSE_ALL_SEEN (0/1). Both functions return 0 ALWAYS; stdout EMPTY.
# They read ONLY "$@" (NO config globals) → callable after a bare `source lib/pool.sh`.

# pool_normalize_close [--] ARGS...
#
# If the command is 'close', strip EVERY standalone '--all' token (a raw --all would nuke
# ALL daemon sessions incl. other agents' lanes — PRD §2.4/§2.15). All other tokens
# (--json, --session <X>, the literal 'close', extra args) are PRESERVED in order. If the
# command is NOT 'close', POOL_NORM_ARGS = args UNCHANGED (--all is left alone: it may be a
# legitimate token for another command, e.g. `find role x --all`).
#
# Sets POOL_CLOSE_ALL_SEEN=1 iff at least one '--all' was stripped from a close command
# (else 0) — the contract's "set a flag to close ONLY my session"; the lifecycle's
# observability hook. The ACTUAL session-scoping is: strip --all (here) + force
# --session abpool-<N> (M6.T2.S1) → the real exec is `close --session abpool-<N>`.
#
# LOGIC:
#   a. Scan $@ (mirroring pool_dispatch_classify) to find the COMMAND (first non-flag):
#        --session <X>  → skip 2 (consume flag + value)
#        --session=<X>  → skip 1 (caught by --*)
#        <any --flag>   → skip 1 (caught by --*; treated as bool — MIRRORS classify)
#        <any -short>   → skip 1 (caught by -*)
#        <non-flag>     → the COMMAND; stop.
#   b. Rebuild from the ORIGINAL args: drop every token whose value is exactly '--all'
#      IFF the command == 'close'. Track seen_all.
#   c. POOL_NORM_ARGS = rebuilt array; POOL_CLOSE_ALL_SEEN = seen_all. Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_NORM_ARGS, NOT stdout. stdout stays EMPTY. The
#   caller reads "${POOL_NORM_ARGS[@]}". (argv may contain spaces → stdout is unsafe.)
# GOTCHA — return 0 ALWAYS; no failure mode ⇒ the caller needs NO if-guard.
# GOTCHA — --session is PRESERVED (only skipped during the scan). M6.T2.S1 strips it.
# GOTCHA — the index counter uses `i=$((i+1))` (assignment, always rc 0), NEVER `(( i++ ))`
#   (returns rc 1 when i==0 → ABORT under set -e; lib/pool.sh:362-365). The only (( )) are
#   `while (( i < ${#orig[@]} ))` (cond, exempt) — no if-cond needed here.
# GOTCHA — MIRRORS pool_dispatch_classify's scan exactly so the two siblings agree on the
#   command token (do NOT enumerate agent-browser value-flags). Safe for close --all.
# PRECONDITION: none. Reads only "$@".
pool_normalize_close() {
    local -a orig=("$@") out=()
    local cmd="" tok seen_all=0
    local i=0

    # --- a. Find the COMMAND (mirror pool_dispatch_classify's flag-scan), index-based. ---
    # `i=$((i+N))` is an ASSIGNMENT (always rc 0) — avoids the bare-(( i++ )) trap. The
    # `while (( ))` is a CONDITION (errexit-exempt). --session consumes its value (skip 2);
    # all other flags skip 1 (matches classify's "all --* ⇒ shift-1" shortcut).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;   # space form: flag + value
            --session=*)    i=$((i+1)) ;;   # equals form: value attached
            --*)            i=$((i+1)) ;;   # --json, --all, --cdp, … (MIRRORS classify: bool)
            -*)             i=$((i+1)) ;;   # -i -c -d -p …
            *)              cmd="$tok"; break ;;   # first non-flag = COMMAND
        esac
    done

    # --- b. Rebuild from ORIGINAL args; drop every '--all' IFF cmd==close. ---
    for tok in "${orig[@]}"; do
        if [[ "$cmd" == close && "$tok" == --all ]]; then
            seen_all=1
            continue
        fi
        out+=("$tok")
    done

    # --- c. Emit normalized argv + flag; return 0 ALWAYS. ---
    # declare -ga NAME=( … ) is the canonical atomic global-array+assign form (keeps values,
    # shellcheck-clean). The scalar flag uses the assign-then-declare-g idiom (pool_chrome_launch @1514).
    declare -ga POOL_NORM_ARGS=( "${out[@]}" )
    POOL_CLOSE_ALL_SEEN=$seen_all
    declare -g POOL_CLOSE_ALL_SEEN
    return 0
}

# pool_normalize_connect [--] ARGS...
#
# If the command is 'connect', strip the SINGLE <port|url> positional that follows it (the
# upstream skill teaches `connect <port>`; the lane's real connection is owned by
# pool_ensure_connected / PRD §2.4 step 4 using the LANE's port from the lease). Flags
# (--json, --session <X>) are PRESERVED. If the command is NOT 'connect', POOL_NORM_ARGS =
# args UNCHANGED.
#
# LOGIC:
#   a. Scan $@ (mirroring classify) to find the COMMAND.
#   b. If cmd != 'connect' → POOL_NORM_ARGS = args UNCHANGED; return 0.
#   c. If cmd == 'connect': CONTINUE scanning PAST the command; the FIRST non-flag token
#      (skipping --session's value, --session=X, --json, etc.) is the <port|url> positional.
#      Record its index. (Bare `connect` with no positional → nothing to strip.)
#   d. Rebuild POOL_NORM_ARGS = args MINUS that one positional (order + flags preserved).
#      Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — bare `connect` (no positional) is a RUNTIME ERROR in the real binary (exit 1,
#   "<port|url> required"). After this strip the result is bare `connect`. PRD §2.4 step 4
#   (pool_ensure_connected) ALREADY binds the lane's daemon — so M6.T3.S1 must NOT naively
#   exec a bare connect (the agent would see the error → breaks §2.15 transparency). This
#   task strips the arg per contract; how the bare result is exec'd is M6.T3.S1.
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_NORM_ARGS, NOT stdout. stdout stays EMPTY.
# GOTCHA — return 0 ALWAYS. Does NOT touch POOL_CLOSE_ALL_SEEN.
# GOTCHA — --session is PRESERVED (only its value is skipped during the positional scan).
# GOTCHA — strips only the FIRST non-flag positional after connect (agent-browser connect
#   takes exactly one <port|url>); extra stray positionals (malformed) are left for the
#   binary to error on.
# PRECONDITION: none. Reads only "$@".
pool_normalize_connect() {
    local -a orig=("$@") out=()
    local cmd="" tok
    local i=0 strip_idx=-1
    local j=0

    # --- a. Find the COMMAND (mirror classify), index-based. ---
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;
            -*)             i=$((i+1)) ;;
            *)              cmd="$tok"; i=$((i+1)); break ;;   # command found; advance PAST it
        esac
    done

    # --- b. Not connect → unchanged. ---
    if [[ "$cmd" != connect ]]; then
        declare -ga POOL_NORM_ARGS=( "${orig[@]}" )
        return 0
    fi

    # --- c. cmd==connect: find the FIRST non-flag positional AFTER the command (the <port|url>). ---
    # Continues the SAME scan from where phase (a) left off (i already points just past `connect`).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;   # skip flag + value
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;   # skip --json etc. (preserve them; not stripped)
            -*)             i=$((i+1)) ;;
            *)              strip_idx=$i; break ;;   # the <port|url> positional
        esac
    done

    # --- d. Rebuild MINUS strip_idx (or unchanged if no positional was found). ---
    # `if (( j == strip_idx ))` is an if-CONDITION (errexit-exempt). When strip_idx==-1 (no
    # positional) the test is never true → out == orig. `j=$((j+1))` is the safe counter form.
    for tok in "${orig[@]}"; do
        if (( j == strip_idx )); then
            j=$((j+1))
            continue
        fi
        out+=("$tok")
        j=$((j+1))
    done

    declare -ga POOL_NORM_ARGS=( "${out[@]}" )
    return 0
}

  - VERIFY (immediately after writing):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings
        grep -nE '^pool_normalize_(close|connect)\(\)' lib/pool.sh   # both defined exactly once
  - EXPECT: OK syntax; OK shellcheck (zero warnings — same as baseline); both defined once near EOF.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the index-based command scan that MIRRORS pool_dispatch_classify (the only (( )) is the
# while CONDITION, which is errexit-exempt; the counter uses the ASSIGNMENT form i=$((i+N)), always
# rc 0 — sidesteps the bare-(( i++ )) trap at lib/pool.sh:362-365):
local -a orig=("$@")      # snapshot $@ so we can both scan AND rebuild from the original
local i=0 tok cmd=""
while (( i < ${#orig[@]} )); do
    tok="${orig[i]}"
    case "$tok" in
        --session)   i=$((i+2)) ;;      # space form: flag consumes its value (MIRRORS classify)
        --session=*) i=$((i+1)) ;;      # equals form
        --*)         i=$((i+1)) ;;      # any other long flag (--json, --all, --cdp, …) — bool, MIRRORS classify
        -*)          i=$((i+1)) ;;      # short flags (-i -c -d -p …)
        *)           cmd="$tok"; break ;;   # first non-flag = COMMAND
    esac
done

# PATTERN — return the normalized argv via a GLOBAL ARRAY (declare -ga, atomic single-statement):
declare -ga POOL_NORM_ARGS=( "${out[@]}" )   # REPLACES the array each call (no stale elements)

# PATTERN — return a scalar flag via the assign-then-declare-g idiom (pool_chrome_launch @1514):
POOL_CLOSE_ALL_SEEN=$seen_all
declare -g POOL_CLOSE_ALL_SEEN

# PATTERN — rebuild MINUS one index (connect's positional), order preserved (bash-external §3 Snippet 3):
local j=0
for tok in "${orig[@]}"; do
    if (( j == strip_idx )); then j=$((j+1)); continue; fi   # if-cond (( )) is exempt
    out+=("$tok"); j=$((j+1))
done

# GOTCHA — why GLOBAL ARRAY and not stdout: argv may contain spaces/newlines → stdout newline-echo
#   (pool_lanes_list style) is unsafe; NUL+mapfile would be the codebase's first with the empty-printf
#   edge. The declare -g convention extends to declare -ga — serialization-free. stdout stays EMPTY.
# GOTCHA — why MIRROR classify's scan (not a precise value-flag enumeration): normalize runs ONLY after
#   classify returned 'driving'; the identical scan guarantees they locate the SAME command → no
#   disagreement. Safe for close --all (a real close token is never a flag value under this scan).
# GOTCHA — why i=$((i+1)) and NOT (( i++ )): a bare (( i++ )) with i==0 returns rc 1 → ABORT under
#   set -e. The assignment form is always rc 0. The while/if (( )) CONDITIONS are errexit-exempt.
# GOTCHA — why strip EVERY --all for close: handles `close --all --all` defensively; --all is ONLY a
#   close flag so every occurrence when cmd==close is the close-all directive.
# GOTCHA — why strip only the FIRST positional for connect: agent-browser connect takes exactly one
#   <port|url>; extras are malformed and left for the binary to reject.
```

### Integration Points

```yaml
LIBRARY (lib/pool.sh):
  - append: "new banner '# Wrapper shim — arg normalization (P1.M6.T1.S2)' + pool_normalize_close +
            pool_normalize_connect at EOF (after pool_dispatch_classify, ~line 3087)"
  - pattern: "match the banner+docstring+function style of pool_dispatch_classify (@2977) +
             pool_chrome_launch (@1471, the declare -g return idiom)"

OUTPUT CONTRACTS (new globals — OUTPUT-only; never read by these functions):
  - POOL_NORM_ARGS:   "declare -ga array — the normalized argv. Caller reads \"${POOL_NORM_ARGS[@]}\"."
  - POOL_CLOSE_ALL_SEEN: "declare -g scalar 0/1 — set by pool_normalize_close (1 iff it stripped --all
                         from a close). Observability hook for the lifecycle."

CONSUMERS (NOT built by this task — referenced for interface stability):
  - M6.T3.S1 wrapper lifecycle (the composition pattern — call BOTH in sequence, each self-gating):
        pool_normalize_close  "$@"                          # sets POOL_NORM_ARGS (+ POOL_CLOSE_ALL_SEEN)
        pool_normalize_connect "${POOL_NORM_ARGS[@]}"       # re-sets POOL_NORM_ARGS (reads prev)
        [[ "$POOL_CLOSE_ALL_SEEN" == 1 ]] && _pool_log "intercepted close --all → scoped to lane $N"
        # M6.T2.S1 then strips --session from POOL_NORM_ARGS + forces AGENT_BROWSER_SESSION=abpool-$N
        exec "$AGENT_BROWSER_REAL" "${POOL_NORM_ARGS[@]}"   # (env session forced by M6.T2.S1)
  - CRITICAL HANDOFF to M6.T3.S1: bare `connect` (the post-strip result) is a RUNTIME ERROR (exit 1).
    pool_ensure_connected (PRD §2.4 step 4) ALREADY binds the lane's daemon, so M6.T3.S1 must NOT
    naively exec a bare connect (breaks §2.15 transparency). Likely: skip the exec for connect, or
    tolerate its exit 1. THIS TASK strips the arg per contract; the exec policy is M6.T3.S1.

NO CHANGES TO:
  - any existing function (M1–M6.T1.S1) — pure append.
  - any env var / config global consumed — reads none (only "$@").
  - POOL_CLOSE_ALL_SEEN is also written only by pool_normalize_close; pool_normalize_connect leaves it.
  - bin/ (still .gitkeep) — the executable is M6.T3.S2.
  - test/ (still .gitkeep) — the bats harness is M9.T1.S1.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the functions — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings
# Expected: both OK (shellcheck baseline was 100% clean; this task must not lower it). Common
#   fixes if a warning appears: SC2155 (none expected — array literal has no cmd-sub; scalar uses
#   the split form), SC2086 (quote "$1"/"${orig[@]}"), SC2178 (expand arrays as "${arr[@]}").
```

### Level 2: Unit Tests (Component Validation)

The bats harness lands in M9.T1.S1. For THIS task, validate via a direct bash script asserting
`POOL_NORM_ARGS` (joined) + `POOL_CLOSE_ALL_SEEN` (the functions are pure — no fixtures needed):

```bash
# Save as /tmp/test_normalize.sh and run: bash /tmp/test_normalize.sh
set -euo pipefail
source lib/pool.sh
pass=0; fail=0

# join POOL_NORM_ARGS with '|' for comparison (empty array → "").
norm_join() { local IFS='|'; printf '%s' "${POOL_NORM_ARGS[*]}"; }

# CRITICAL — call the functions DIRECTLY (NOT inside "$( ... )"). A command-substitution subshell
# would lose the POOL_NORM_ARGS global (BashFAQ/024 — variables set in a subshell don't propagate
# to the parent). The functions write NOTHING to stdout (verified separately in Level 3/4), so a
# direct call is both correct and sufficient. rc==0 is enforced by `set -e`: a buggy non-zero
# return aborts the whole script = loud failure (the function returns 0 ALWAYS by contract).

# assert_close EXPECTED_JOINED EXPECTED_SEEN  ARGS...  — run pool_normalize_close directly; check globals.
assert_close() {
    local exp_join="$1" exp_seen="$2"; shift 2
    local joined
    pool_normalize_close "$@"                       # DIRECT call → sets POOL_NORM_ARGS in THIS shell
    joined="$(norm_join)"                           # norm_join subshell inherits the global (copy)
    if [[ "$joined" == "$exp_join" && "$POOL_CLOSE_ALL_SEEN" == "$exp_seen" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf 'FAIL close: args=[%s] want(j=%s s=%s) got(j=%s s=%s)\n' \
            "$*" "$exp_join" "$exp_seen" "$joined" "$POOL_CLOSE_ALL_SEEN" >&2
    fi
}

# assert_connect EXPECTED_JOINED  ARGS...  — run pool_normalize_connect directly; check POOL_NORM_ARGS.
assert_connect() {
    local exp_join="$1"; shift
    local joined
    pool_normalize_connect "$@"                     # DIRECT call → sets POOL_NORM_ARGS in THIS shell
    joined="$(norm_join)"
    if [[ "$joined" == "$exp_join" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        printf 'FAIL connect: args=[%s] want(j=%s) got(j=%s)\n' "$*" "$exp_join" "$joined" >&2
    fi
}

# --- pool_normalize_close ---
assert_close 'close'              1  close --all                 # strip --all
assert_close 'close'              0  close                        # no --all
assert_close 'close|--json'       1  close --all --json           # strip --all, keep --json
assert_close '--json|close'       1  --json close --all           # leading flag; strip --all
assert_close 'close'              1  close --all --all            # strip EVERY --all
assert_close 'close|--session|foo' 1  close --session foo --all   # --session PRESERVED
assert_close 'close|--json'       0  close --json                 # close, no --all
assert_close 'find|role|x|--all'  0  find role x --all            # cmd≠close → --all KEPT
assert_close 'open|https://x'     0  open https://x              # cmd≠close → unchanged
assert_close ''                   0                               # no args
assert_close '--json'             0  --json                       # only a flag

# --- pool_normalize_connect ---
assert_connect 'connect'                 connect 9222                                      # strip port
assert_connect 'connect'                 connect ws://localhost:9222/devtools/browser/abc   # strip ws url
assert_connect 'connect'                 connect https://example.com                       # strip http url
assert_connect '--json|connect'          --json connect 9222                               # leading flag; strip port
assert_connect 'connect|--json'          connect --json 9222                               # flag between; keep --json
assert_connect 'connect|--session|foo'   connect --session foo 9222                        # --session PRESERVED
assert_connect 'connect'                 connect                                           # bare → nothing to strip
assert_connect 'open|https://x'          open https://x                                   # cmd≠connect → unchanged
assert_connect ''                                                                         # no args
# spaces preserved (robustness): the 3rd element is the single string 'hello world'
assert_connect "type|#q|hello world"     type '#q' 'hello world'

# --- COMPOSITION (the M6.T3.S1 pattern: close THEN connect) ---
comp() {  # comp EXPECTED_JOINED  ARGS...
    local exp_join="$1"; shift
    local joined
    pool_normalize_close  "$@"                       # sets POOL_NORM_ARGS (+ POOL_CLOSE_ALL_SEEN)
    pool_normalize_connect "${POOL_NORM_ARGS[@]}"    # reads prev POOL_NORM_ARGS; re-sets it
    joined="$(norm_join)"
    if [[ "$joined" == "$exp_join" ]]; then pass=$((pass+1));
    else fail=$((fail+1)); printf 'FAIL comp: args=[%s] want(j=%s) got(j=%s)\n' "$*" "$exp_join" "$joined" >&2; fi
}
comp 'close'             close --all          # close strips --all; connect no-op (cmd=close)
comp 'connect'           connect 9222         # close no-op (cmd=connect); connect strips 9222
comp 'open|https://x'    open https://x       # both no-ops

# --- report ---
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
# Expected: pass=25 fail=0 (11 close + 10 connect + 3 composition + 1 stdout-empty). The
#   verbatim implementation above was host-verified to pass all 25 (bash 5.3, shellcheck 0.11.0).
#   If ANY fail, debug root cause (the implementation, NOT the expectations — they are correct).
# (stdout-emptiness is verified separately in Level 3, since the direct call here doesn't capture stdout.)
```

### Level 3: Integration Testing (System Validation)

```bash
# Confirm NO regression — all prior deliverables still load + are callable (incl. the new ones):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
         type pool_dispatch_classify pool_normalize_close pool_normalize_connect \
               pool_acquire_locked pool_ensure_connected' && echo "OK all callable"
# Expected: all reported as functions (incl. the two new normalizers).

# Confirm the new functions need NONE of the init (pure — callable on a bare source):
bash -c 'set -euo pipefail; source lib/pool.sh; \
         pool_normalize_close close --all; printf "args=[%s] seen=%s\n" "${POOL_NORM_ARGS[*]}" "$POOL_CLOSE_ALL_SEEN"'
# Expected: args=[close] seen=1 (NO pool_config_init called).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         pool_normalize_connect connect 9222; printf "args=[%s]\n" "${POOL_NORM_ARGS[*]}"'
# Expected: args=[connect] (NO pool_config_init called).

# Confirm stdout is EMPTY (all output is via globals) — the capture must be the empty string:
out="$(set -euo pipefail; source lib/pool.sh; pool_normalize_close close --all)"
[[ -z "$out" ]] && echo "OK close stdout-empty" || echo "FAIL: close wrote to stdout"
out="$(set -euo pipefail; source lib/pool.sh; pool_normalize_connect connect 9222)"
[[ -z "$out" ]] && echo "OK connect stdout-empty" || echo "FAIL: connect wrote to stdout"
# Expected: both OK.

# (The wrapper bin/agent-browser integration is M6.T3.S1/S2 — NOT validated here.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# SAFETY smoke — the core PRD §2.15 guarantee: close --all MUST be defanged to session scope.
# After normalize, POOL_NORM_ARGS must NOT contain --all when cmd==close (so the real exec, once
# M6.T2.S1 forces --session abpool-<N>, cannot nuke peers):
set -euo pipefail; source lib/pool.sh
pool_normalize_close close --all --json --all
# POOL_NORM_ARGS must be exactly (close --json) — zero --all tokens:
[[ "$(norm_join)" == "close|--json" && "$POOL_CLOSE_ALL_SEEN" == 1 ]] && echo "OK close --all defanged" || echo "FAIL"
# (define norm_join as in Level 2 if running standalone)

# Non-close --all must be PRESERVED (do not over-strip):
pool_normalize_close find role button --all
[[ "$(norm_join)" == "find|role|button|--all" ]] && echo "OK non-close --all preserved" || echo "FAIL"

# Connect arg fully stripped regardless of port/url shape:
for arg in 9222 ws://h:9222/x https://x.example/cdp wss://svc.example/cdp?token=abc ; do
    pool_normalize_connect connect "$arg"
    [[ "$(norm_join)" == "connect" ]] || { echo "FAIL connect strip: $arg -> $(norm_join)"; }
done
echo "OK connect arg stripped for all shapes"

# Spaces/newlines robustness — the WHOLE point of the global-array output channel:
pool_normalize_close type '#q' 'two words'
[[ "$(norm_join)" == "type|#q|two words" ]] && echo "OK spaces preserved" || echo "FAIL"
# Expected: all OK. (If spaces were split, the global-array channel would be wrong.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 passed: `bash -n lib/pool.sh` clean + `shellcheck -s bash lib/pool.sh` zero warnings.
- [ ] Level 2 passed: the close/connect/composition script reports `fail=0`.
- [ ] Level 3 passed: all prior functions still callable; both normalizers work on a bare
      `source lib/pool.sh` (no init); stdout is EMPTY.
- [ ] Level 4 passed: close --all defanged (zero --all tokens) + non-close --all preserved +
      connect arg stripped for all shapes + spaces preserved.

### Feature Validation

- [ ] All success-criteria rows in the "What"/Goal tables met (close strip, connect strip, default,
      edges, composition).
- [ ] `close --all` → `POOL_NORM_ARGS` has NO `--all`; `POOL_CLOSE_ALL_SEEN=1`.
- [ ] cmd≠close with `--all` → `--all` KEPT.
- [ ] `connect <port|url>` → positional stripped; `--json`/`--session` PRESERVED.
- [ ] bare `connect` / cmd≠connect → unchanged.
- [ ] return 0 ALWAYS; stdout EMPTY; reads no config globals / writes no files / no external cmds.
- [ ] Composition (close-then-connect) correct for close / connect / other commands.

### Code Quality Validation

- [ ] Follows existing codebase patterns (banner + docstring + function style of
      `pool_dispatch_classify`; return-via-`declare -g` of `pool_chrome_launch` extended to `declare -ga`).
- [ ] File placement: appended at EOF under the new banner; no existing function touched.
- [ ] Anti-patterns avoided: no bare `(( i++ ))` (uses `i=$((i+1))`), no stdout output, no non-zero
      return path, no global config reads, no `--session` stripping (M6.T2.S1), no classification
      (M6.T1.S1), no lifecycle wiring (M6.T3.S1).
- [ ] Naming matches the `pool_*` family; output globals are OUTPUT-only contracts.

### Documentation & Deployment

- [ ] Docstrings document LOGIC (a–c/d), CONSUMERS, GOTCHAs, PRECONDITION (= none) for BOTH functions.
- [ ] No new env vars CONSUMED documented (functions read only "$@").
- [ ] Scope boundary vs M6.T1.S1 (classify) / M6.T2.S1 (session) / M6.T3.S1 (lifecycle) clearly noted.
- [ ] CRITICAL handoff to M6.T3.S1 documented (bare connect errors exit 1 → do not naively exec).

---

## Anti-Patterns to Avoid

- ❌ Don't echo the normalized argv on stdout — argv can contain spaces/newlines (unsafe); use the
  `POOL_NORM_ARGS` global array. stdout stays EMPTY. (`pool_lanes_list` only echoes simple integers.)
- ❌ Don't use a bare `(( i++ ))` — returns rc 1 when i==0 → ABORTS under `set -e`. Use the assignment
  form `i=$((i+1))` (always rc 0). The only `(( ))` are `while (( ))` / `if (( ))` CONDITIONS (exempt).
- ❌ Don't strip `--all` unconditionally — only when the command is `close`. `find role x --all` must
  KEEP its `--all`. (Verify command == close first.)
- ❌ Don't strip more than the FIRST non-flag positional for `connect` — agent-browser connect takes
  exactly one `<port|url>`. Preserve `--json`/`--session`.
- ❌ Don't touch `--session` — that's M6.T2.S1. Here it is only SKIPPED (value consumed) during the
  scan; it is PRESERVED in `POOL_NORM_ARGS`.
- ❌ Don't add a non-zero return path — both functions return 0 ALWAYS (no failure mode); a non-zero
  path would force every caller to add an `if` guard for nothing.
- ❌ Don't read any `POOL_*` config global or call `pool_config_init`/`pool_owner_resolve`/`_pool_log` —
  the functions read ONLY `"$@"` (callable after a bare source; unit-testable with zero fixtures).
- ❌ Don't enumerate agent-browser's value-flags (--cdp/--state/…) in the scan — MIRROR
  `pool_dispatch_classify`'s exact scan (`--session`→2, other `--*`→1) so the two siblings agree.
  (Safe for close --all; see design-decisions D2.)
- ❌ Don't classify (M6.T1.S1), wire the lifecycle (M6.T3.S1), create bin/agent-browser (M6.T3.S2),
  or decide how a bare connect is exec'd (M6.T3.S1 handoff). This task NORMALIZES close/connect ONLY.
- ❌ Don't skip validation because "it should work" — run the Level 2 matrix; the close-vs-non-close
  `--all` distinction, the connect positional-vs-flag distinction, and the space-preservation check
  are easy to get wrong.
