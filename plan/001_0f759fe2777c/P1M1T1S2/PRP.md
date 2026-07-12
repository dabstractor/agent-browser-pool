# PRP — P1.M1.T1.S2: Config/path resolution — all env vars to absolute paths

---

## Goal

**Feature Goal**: Implement `pool_config_init()` inside `lib/pool.sh` — the single function that, when called, resolves every `AGENT_BROWSER_*` / `AGENT_CHROME_*` environment-variable override into validated **absolute** `POOL_*` globals consumed by every later function (lease I/O, copy, launch, acquire, release, reap). This is the literal, physical enforcement of PRD §2.2's hard rule ("never pass `~` to a subprocess") and the configuration reference table from PRD §2.11 / architecture `external_deps.md` §5.

**Deliverable**:
1. A `pool_config_init()` function appended to `lib/pool.sh` (the file created by **P1.M1.T1.S1**, whose PRP is treated as a hard contract — see Context).
2. A small set of internal `_pool_config_*` helper functions (numeric validator, path canonicalizer) that `pool_config_init` composes.
3. The complete set of `POOL_*` global variables populated on call (exact list in "Data models and structure").
4. A documentation comment block inside `pool_config_init` listing every env var, its source name, its default, and its purpose — this block IS the project's configuration reference ([Mode A] per the subtask contract).

**Success Definition**:
- `set -euo pipefail; source lib/pool.sh; pool_config_init; echo "$POOL_STATE_DIR"` prints an absolute, canonical path (no `~`, no trailing slash), under every override + no-override combination.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean.
- Every `POOL_*` global is populated, absolute, and validated (numeric vars reject non-digits; booleans normalize to `0`/`1`).
- Calling `pool_config_init` twice in one shell is safe (idempotent) — see the explicit decision in "Implementation Patterns".
- `pool_config_init` exits the process via `pool_die` on a fatal misconfiguration (e.g. `$HOME` unset, non-numeric port), because there is no sane fallback. It does NOT exit on a merely-unset env override (those fall back to defaults).

## User Persona

**Target User**: Downstream implementers (every subtask M1.T1.S3 onward) and the runtime wrapper (`bin/agent-browser`, `bin/agent-browser-pool`) which call `pool_config_init` once near the top of dispatch, before any pool logic runs. Also: the operator/admin who reads the in-file comment block to learn which env vars the pool honors.

**Use Case**: At startup, the wrapper sources `lib/pool.sh` and calls `pool_config_init`. From that point on, every other function reads the frozen `POOL_*` globals (never the raw env vars) and can hand any path to Chrome / `rm` / `cp` / log files with zero risk of a literal `~` leaking through.

**Pain Points Addressed**: PRD §2.2 documents that tilde does NOT expand after `=` or inside quotes, and a literal `~` has previously created a junk dir named `~` on this host. Architecture `key_findings.md` FINDING 3 codifies the fix: resolve `$HOME` to absolute **once**, up front, and never emit a bare `~`. This subtask is where that fix physically lives.

## Why

- **Single chokepoint for the no-`~` rule.** Rather than scattering `realpath` calls across ~250 LOC of pool logic, every path is canonicalized here. Later subtasks simply trust `POOL_*` vars are absolute.
- **Configuration reference in one place.** PRD §2.11 spreads env vars across prose; `external_deps.md` §5 tabulates them; this subtask makes the *code* the source of truth via the [Mode A] comment block.
- **Foundation for M1.T1.S3.** The very next subtask (state-directory setup + btrfs detection) consumes `POOL_STATE_DIR`, `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`, and `POOL_LOCK_FILE` directly. M2 (owner resolution), M3 (leases), M4 (lanes), M5 (acquire/release/reap), M6/M7 (wrappers) all consume `POOL_REAL_BIN`, `POOL_CHROME_BIN`, `POOL_PORT_BASE`, `POOL_DISABLE`, etc. Getting the names, defaults, and resolution rules exactly right now prevents cascading renames later.
- **Validation gate.** A non-numeric `AGENT_CHROME_PORT_BASE=abc` would currently cause silent arithmetic failures deep in `find_free_port` (M4.T2.S1). Validating at init turns that into an immediate, clear error at startup.

## What

User-visible behavior: none directly (this is a library function). Observable contract:

### Success Criteria

- [ ] `pool_config_init()` is defined in `lib/pool.sh` and callable after sourcing.
- [ ] After `pool_config_init`, ALL of these globals exist and are non-empty (unless the contract marks them as legitimately empty/unset):
  - `POOL_HOME_DIR` — absolute canonical `$HOME` (via `realpath`).
  - `POOL_STATE_DIR` — absolute (may not exist on disk yet; `realpath -m`).
  - `POOL_MASTER_DIR` — absolute.
  - `POOL_EPHEMERAL_ROOT` — absolute.
  - `POOL_REAL_BIN` — absolute.
  - `POOL_CHROME_BIN` — the Chrome binary name/path (default `google-chrome-stable`; NOT canonicalized if it's a bare name found on PATH — see gotcha).
  - `POOL_PORT_BASE` — digits only, validated.
  - `POOL_PORT_RANGE` — digits only, validated, `> 0`.
  - `POOL_WAIT` — digits only, validated.
  - `POOL_HEADLESS` — normalized to `0` or `1` (from `AGENT_CHROME_HEADLESS`).
  - `POOL_DISABLE` — normalized to `0` or `1` (from `AGENT_BROWSER_POOL_DISABLE`).
  - `POOL_ALLOW_SLOW_COPY` — normalized to `0` or `1` (from `AGENT_CHROME_ALLOW_SLOW_COPY`).
  - `POOL_LANES_DIR` — `$POOL_STATE_DIR/lanes`, absolute.
  - `POOL_LOCK_FILE` — `$POOL_STATE_DIR/acquire.lock`, absolute.
- [ ] No `POOL_*` value contains a literal `~` character (verified by a Level-2 grep test).
- [ ] `pool_config_init` exits non-zero via `pool_die` when: `$HOME` is unset/empty, `$HOME` cannot be resolved, or any numeric env var is non-numeric or `PORT_RANGE` ≤ 0.
- [ ] `pool_config_init` is **idempotent**: calling it twice in the same shell with the same env produces the same globals and does not error (see the explicit readonly-vs-mutable decision below).
- [ ] `pool_config_init` is **re-runnable with different env**: tests (M9) source the lib once, then call `pool_config_init` repeatedly with different overrides per case — this MUST work (drives the mutable-globals + guard decision).
- [ ] A comment block documents every env var, its source name, default, and purpose (the configuration reference).
- [ ] `shellcheck lib/pool.sh` clean; `bash -n lib/pool.sh` clean; the whole file still sources cleanly under `set -euo pipefail`.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP includes: the exact input→output env-var mapping table (from the subtask contract + PRD §2.11 + `external_deps.md` §5, cross-checked and reconciled below), the exact resolution strategy per variable category (path-exists / path-may-not-exist / numeric / boolean), the exact bash idioms verified on the host (realpath `-m` exit codes, `declare -g` under strict mode, idempotency pattern), the exact downstream consumer contract, and copy-pasteable validation commands. The only external dependency is the prior PRP (P1.M1.T1.S1), whose output contract is quoted verbatim in "Integration Points".

### Documentation & References

```yaml
# MUST READ — primary sources of truth for WHAT to resolve and the no-~ rule
- file: PRD.md
  why: §2.2 (hard rule: never pass ~ to a subprocess) and §2.11 (discovery & configuration — every env var + default).
  pattern: §2.11 lists exactly: AGENT_CHROME_MASTER, AGENT_CHROME_EPHEMERAL_ROOT, AGENT_BROWSER_POOL_STATE, AGENT_BROWSER_REAL, AGENT_CHROME_BIN, AGENT_CHROME_PORT_BASE=53420, AGENT_CHROME_PORT_RANGE=1000, AGENT_BROWSER_POOL_WAIT=600, AGENT_CHROME_HEADLESS (unset=windowed), AGENT_CHROME_ALLOW_SLOW_COPY (unset=refuse), AGENT_BROWSER_POOL_DISABLE=1 (passthrough).
  gotcha: §2.2 — tilde does NOT expand after `=` or inside quotes; resolve $HOME to absolute for EVERY path. NEVER bare ~.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §5 is the canonical configuration-variable table (env name | default | purpose) — use it to cross-check the env→POOL_* mapping.
  pattern: §5 table is the single reconciled source for defaults (e.g. AGENT_BROWSER_REAL default = /home/dustin/.local/bin/agent-browser).
  gotcha: §5 includes two TEST-ONLY hooks (AGENT_BROWSER_POOL_OWNER_PID, AGENT_BROWSER_POOL_OWNER_STARTTIME) — these are NOT resolved by THIS subtask (they belong to M2 owner resolution). Do NOT add them to pool_config_init.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 3 is the literal code pattern this subtask implements (HOME_DIR="$(realpath "$HOME")" + the ${VAR:-$HOME_DIR/...} default-expansion chain).
  pattern: FINDING 3 gives the exact 5-line resolution idiom for HOME_DIR/STATE_DIR/MASTER_DIR/EPHEMERAL_ROOT/REAL_BIN.
  gotcha: FINDING 3 uses plain `realpath` — but that FAILS on not-yet-existing intermediate dirs (verified on host: `realpath /nonexistent/deep/path` exits 1). Use `realpath -m` for paths that may not exist yet (state dir, ephemeral root, master, lanes, lock). See Known Gotchas.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 confirms the state dir does NOT exist yet at impl time (so resolution must not require it) and lists the exact runtime layout (acquire.lock, lanes/, chrome-<N>.log, alerts.log).
  pattern: POOL_LOCK_FILE = $POOL_STATE_DIR/acquire.lock ; POOL_LANES_DIR = $POOL_STATE_DIR/lanes.
  gotcha: §8 confirms active/ exists but master-profile is 4.8GB — do NOT stat/validate these at config time (that's M1.T1.S3 / M4.T1.S1); just canonicalize the path strings.

# External authoritative docs (for the HOW)
- url: https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html
  why: defines `-m`/`--canonicalize-missing` (exit 0 even when nothing exists) vs default (fails on missing intermediate components) vs `-e` (everything must exist).
  critical: ON THIS HOST (verified): `realpath /nonexistent/deep/path` → exit 1; `realpath -m /nonexistent/deep/path` → exit 0. Therefore default-pool paths (state/ephemeral/master) MUST use `realpath -m`. `$HOME` (always exists) may use plain `realpath`.
  section: "4.2 realpath invocation" — the `-m` / `--canonicalize-missing` bullet.

- url: https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins
  why: `declare -g` (global from inside a function) and `-r` (readonly) semantics. Confirms `typeset`≡`declare` in bash.
  critical: `declare -r X=...` INSIDE a function makes X LOCAL (not global) — the classic sourced-lib bug. Use `declare -g` for globals. See "Implementation Patterns" for the readonly-vs-mutable decision.
  section: search page for `declare` then `-g` / "global".

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: authoritative on `set -u` (nounset — must use `${VAR:-}`) and `set -e` (errexit — `[[ =~ ]]` inside `if` is exempt; bare `(( ))` returning 0 is fatal).
  critical: read EVERY env var through `${VAR:-}` so an unset override never aborts init.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` so the command's exit status is not masked.
  critical: when capturing `realpath` output, do `local resolved; resolved="$(realpath -m -- "$in")"` in TWO statements, NOT `local resolved="$(realpath -m -- "$in")"`.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions. Universal rule for this file.

- file: plan/001_0f759fe2777c/P1M1T1S2/research/bash-config-init-research.md
  why: the deep-research brief on sourced-lib config init — idempotency guard pattern, realpath -m vs realpath, numeric validation, boolean tri-state normalization, readonly re-source pitfalls.
  pattern: the "Consolidated idiomatic skeleton" at the end of that file is the direct ancestor of the reference implementation in this PRP (adapt the var names to POOL_* and the defaults to PRD §2.11).
  gotcha: the brief recommends `declare -gr` (readonly) + guard. THIS PRP intentionally uses MUTABLE `declare -g` + guard instead — rationale in "Implementation Patterns" (tests must re-init with different env in one shell).

# Prior-subtask contract (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 creates lib/pool.sh with: `#!/usr/bin/env bash` + `set -euo pipefail` (propagates to callers) + `pool_die()` (printf '%s\n' "$*" >&2; exit 1) + `_pool_log()` + `_pool_log_path()`. THIS subtask APPENDS to that file; it must NOT recreate the header, strict-mode line, or the two utilities.
  pattern: S1's `pool_die` is the canonical exit-1 helper — call it on fatal config errors. S1's file ends after `_pool_log`; append `pool_config_init` and its `_pool_config_*` helpers BELOW `_pool_log`.
  gotcha: S1 propagates `set -euo pipefail` into the caller. Every env read in pool_config_init MUST use `${VAR:-}` or the caller (and any test) aborts on an unset var. S1's `_pool_log_path` already honors `AGENT_BROWSER_POOL_STATE` and `POOL_LOG_PATH` — do NOT duplicate that logic; pool_config_init sets POOL_STATE_DIR which `_pool_log_path` will pick up on its NEXT call (see Integration Points note).
```

### Current Codebase tree

After **P1.M1.T1.S1** is implemented (treated as done), the repo looks like:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md              # READ-ONLY
├── README.md
├── bin/                # S1 — empty (.gitkeep)
├── lib/
│   └── pool.sh         # S1 — header + set -euo pipefail + pool_die + _pool_log + _pool_log_path
├── test/               # S1 — empty (.gitkeep)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md
    ├── prd_index.txt
    ├── tasks.json
    ├── P1M1T1S1/PRP.md
    └── P1M1T1S2/                        # THIS subtask
        ├── PRP.md                        # THIS FILE
        └── research/bash-config-init-research.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh   # MODIFIED — append pool_config_init() + _pool_config_* helpers + config-ref comment block
└── (nothing else changes this subtask)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the **configuration layer** between the utilities (S1) and the pool logic (later subtasks). Concretely it appends, in order:
1. `_pool_config_canon_path()` — internal: canonicalize a path to absolute via `realpath -m` (never fails on missing components).
2. `_pool_config_require_uint()` — internal: validate a value is digits-only; `pool_die` otherwise.
3. `_pool_config_bool()` — internal: normalize a tri-state env to `0`/`1`.
4. `pool_config_init()` — the public entry point: resolves all env overrides → `POOL_*` globals, with the configuration-reference comment block as its leading doc.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (PRD §2.2, FINDING 3): NEVER put a bare '~' in any POOL_* value. Tilde does
# NOT expand after '=' or inside quotes; a literal '~' has created a junk dir named '~'
# on this host before. Resolve every default via "$POOL_HOME_DIR/..." (an already-absolute
# base), then canonicalize with realpath -m.

# CRITICAL (verified on host THIS session): `realpath` (no flag) EXITS 1 when an
# INTERMEDIATE path component is missing:
#   $ realpath /nonexistent/deep/path   → exit 1   (would abort under set -e!)
#   $ realpath -m /nonexistent/deep/path → exit 0, prints /nonexistent/deep/path
# The pool's default STATE_DIR, EPHEMERAL_ROOT, MASTER_DIR, LANES_DIR, LOCK_FILE do NOT
# exist at first run. Therefore ALL path resolution in pool_config_init MUST use
# `realpath -m` (--canonicalize-missing). Using bare `realpath` is a latent set -e crash.
# `$HOME` itself always exists, so plain `realpath "$HOME"` is also safe there, but using
# `realpath -m` uniformly is simpler and equally correct.

# CRITICAL (shellcheck SC2155): `local x="$(cmd)"` masks cmd's exit status. Under set -e
# this hides failures. ALWAYS: local x; x="$(cmd)" — two statements.

# CRITICAL (set -u): S1's lib propagates `set -u` into the caller. Reading an unset env
# var like `$AGENT_CHROME_PORT_BASE` aborts. EVERY env read MUST be `${AGENT_CHROME_PORT_BASE:-}`
# (with the default inside the `:-`).

# CRITICAL (set -e + arithmetic): `(( n ))` returns non-zero when the result is 0, which
# is FATAL under set -e. Put all `(( ))` inside an `if`/`&&`/`||`, e.g.:
#   (( POOL_PORT_RANGE > 0 )) || pool_die "PORT_RANGE must be > 0"
# Never write a bare `(( ... ))` as a statement.

# GOTCHA (declare -g vs declare -gr): making POOL_* readonly breaks the test harness.
# M9 tests source lib/pool.sh ONCE, then call pool_config_init repeatedly with different
# env overrides per test case to exercise different configs in one shell. Readonly globals
# cannot be reassigned (error under set -e) and cannot be unset. THEREFORE: use MUTABLE
# `declare -g` (NOT -gr) and make pool_config_init RE-RUNNABLE. See "Implementation Patterns"
# for the full decision.

# GOTCHA (POOL_CHROME_BIN is special): the default is the bare NAME `google-chrome-stable`
# (resolved via PATH at Chrome-launch time, not here). Do NOT realpath a bare name — it
# would either fail or produce a wrong path. Only canonicalize POOL_CHROME_BIN if it
# contains a '/' (i.e. the operator gave an explicit path). A bare name is stored as-is.
# (findmnt/which resolution belongs to M4.T2.S2 Chrome launch, NOT here.)

# GOTCHA (the test hooks are NOT here): AGENT_BROWSER_POOL_OWNER_PID and
# AGENT_BROWSER_POOL_OWNER_STARTTIME (external_deps.md §5) are test-only owner-resolution
# hooks consumed by M2.T1.S1. They are deliberately NOT resolved into POOL_* globals here.
# Adding them would couple config to owner resolution and break M2's encapsulation.

# GOTCHA (realpath of $HOME when $HOME is a symlink): `realpath "$HOME"` follows symlinks
# to the canonical target. On this host $HOME=/home/dustin is already canonical, but if an
# operator symlinks $HOME, the canonicalized POOL_HOME_DIR may differ from the literal $HOME.
# That is the DESIRED behavior (PRD §2.2 wants the real on-disk path).

# GOTCHA (idempotency): pool_config_init may be called more than once (wrapper calls it;
# a sourced test then calls it again with overrides). It must NOT error on the 2nd call.
# Do NOT use a "return early if already initialized" flag that skips re-resolution — that
# would prevent tests from re-configuring. Instead, resolve unconditionally each call
# (mutating the existing globals). See Implementation Patterns.
```

## Implementation Blueprint

### Data models and structure

This subtask defines no JSON/ORM models. The "data model" is the set of `POOL_*` global variables — the env→global mapping table that IS the contract. Reconciled from the subtask description, PRD §2.11, and `external_deps.md` §5:

| Global (output) | Env source (input) | Default | Category | Notes |
|---|---|---|---|---|
| `POOL_HOME_DIR` | `$HOME` | (required) | path-exists | `realpath "$HOME"`; fatal if unset/empty/unresolvable. |
| `POOL_STATE_DIR` | `$AGENT_BROWSER_POOL_STATE` | `$POOL_HOME_DIR/.local/state/agent-browser-pool` | path-may-not-exist | `realpath -m`. May not exist yet (M1.T1.S3 creates it). |
| `POOL_MASTER_DIR` | `$AGENT_CHROME_MASTER` | `$POOL_HOME_DIR/.agent-chrome-profiles/master-profile` | path-may-not-exist | `realpath -m`. 4.8GB; do not stat. |
| `POOL_EPHEMERAL_ROOT` | `$AGENT_CHROME_EPHEMERAL_ROOT` | `$POOL_HOME_DIR/.agent-chrome-profiles/active` | path-may-not-exist | `realpath -m`. |
| `POOL_REAL_BIN` | `$AGENT_BROWSER_REAL` | `$POOL_HOME_DIR/.local/bin/agent-browser` | path-may-not-exist | `realpath -m`. (Default path exists on this host but tests may point elsewhere.) |
| `POOL_CHROME_BIN` | `$AGENT_CHROME_BIN` | `google-chrome-stable` | name-or-path | If value contains `/`, `realpath -m` it; else store as-is (bare name, resolved via PATH at launch). |
| `POOL_PORT_BASE` | `$AGENT_CHROME_PORT_BASE` | `53420` | uint | digits-only validated; fatal if non-numeric. |
| `POOL_PORT_RANGE` | `$AGENT_CHROME_PORT_RANGE` | `1000` | uint>0 | digits-only validated AND `> 0`; fatal otherwise. |
| `POOL_WAIT` | `$AGENT_BROWSER_POOL_WAIT` | `600` | uint | digits-only validated; fatal if non-numeric. |
| `POOL_HEADLESS` | `$AGENT_CHROME_HEADLESS` | unset → `0` | bool | `0` unless env `== 1`. |
| `POOL_DISABLE` | `$AGENT_BROWSER_POOL_DISABLE` | unset → `0` | bool | `0` unless env `== 1`. |
| `POOL_ALLOW_SLOW_COPY` | `$AGENT_CHROME_ALLOW_SLOW_COPY` | unset → `0` | bool | `0` unless env `== 1`. |
| `POOL_LANES_DIR` | (derived) | `$POOL_STATE_DIR/lanes` | path-may-not-exist | `realpath -m`. Derived AFTER `POOL_STATE_DIR` is set. |
| `POOL_LOCK_FILE` | (derived) | `$POOL_STATE_DIR/acquire.lock` | path-may-not-exist | `realpath -m`. Derived AFTER `POOL_STATE_DIR` is set. |

**Naming**: all globals prefixed `POOL_` (matches `key_findings.md` function-naming convention `pool_config_*`). Internal helpers prefixed `_pool_config_`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the prior PRP and confirm S1's lib/pool.sh exists and is sourceable
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; type pool_die _pool_log' 
  - EXPECT: prints that pool_die and _pool_log are functions (S1 done).
  - IF S1 not yet landed: STOP. This subtask depends on S1's file existing. Re-read
        plan/001_0f759fe2777c/P1M1T1S1/PRP.md and treat its deliverable as the starting point.
  - NOTE: the file ALREADY contains '#!/usr/bin/env bash', 'set -euo pipefail', pool_die,
        _pool_log_path, _pool_log. Do NOT duplicate any of these — APPEND only.

Task 1: APPEND internal helper _pool_config_canon_path to lib/pool.sh
  - IMPLEMENT: `_pool_config_canon_path <input>` → prints canonical absolute path via `realpath -m`.
  - BEHAVIOR: 
        local in="$1" out
        [[ -n "$in" ]] || pool_die "_pool_config_canon_path: empty input"
        out="$(realpath -m -- "$in")" || pool_die "cannot canonicalize path: $in"
        printf '%s\n' "$out"
  - FOLLOW pattern: S1's `pool_die` for errors. Two-statement local capture (SC2155).
  - GOTCHA: MUST use `realpath -m` (not bare `realpath`) — see Known Gotchas.
  - NAMING: leading underscore = internal helper.
  - PLACEMENT: directly BELOW _pool_log (S1's last function).

Task 2: APPEND internal helper _pool_config_require_uint to lib/pool.sh
  - IMPLEMENT: `_pool_config_require_uint <name> <value>` → validates digits-only, prints value, else pool_die.
  - BEHAVIOR:
        local name="$1" val="${2:-}"
        if [[ ! "$val" =~ ^[0-9]+$ ]]; then
            pool_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
        fi
        printf '%s\n' "$val"
  - FOLLOW pattern: regex inside `if` is set -e safe (Conditional Constructs, bash manual).
  - NAMING: _pool_config_require_uint.
  - PLACEMENT: directly below Task 1's helper.

Task 3: APPEND internal helper _pool_config_bool to lib/pool.sh
  - IMPLEMENT: `_pool_config_bool <value>` → prints "1" if value == "1", else "0".
  - BEHAVIOR:
        local val="${1:-}"
        if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
  - RATIONALE: PRD §2.11 treats these as tri-state (unset = default/off, =1 = on). Any
        other value (e.g. "true", "yes") is treated as OFF to keep semantics strict and
        predictable. Document this in the comment block.
  - NAMING: _pool_config_bool.
  - PLACEMENT: directly below Task 2's helper.

Task 4: APPEND the public pool_config_init function WITH its configuration-reference comment block
  - STRUCTURE (top to bottom inside pool_config_init):
      1. Leading comment block [Mode A] — the configuration reference. MUST list every
         env var below with: source name | default | purpose. (See Task 4a for exact text.)
      2. Resolve POOL_HOME_DIR FIRST (everything else depends on it). Fatal if $HOME bad.
      3. Resolve the path globals (STATE_DIR, MASTER_DIR, EPHEMERAL_ROOT, REAL_BIN) using
         ${ENV:-$POOL_HOME_DIR/...} then _pool_config_canon_path.
      4. Resolve POOL_CHROME_BIN with the name-or-path rule (Task 4b).
      5. Validate + assign the numeric globals via _pool_config_require_uint, then enforce
         POOL_PORT_RANGE > 0 with an explicit (( ))||pool_die guard.
      6. Normalize the boolean globals via _pool_config_bool.
      7. Derive POOL_LANES_DIR and POOL_LOCK_FILE from the now-final POOL_STATE_DIR.
      8. `return 0` at the end.
  - DECISION (mutable, not readonly): use plain `declare -g POOL_X=...` (or, because we are
        at function scope and want TRUE globals, assign directly: `POOL_X="$val"` — since
        pool_config_init is called at top level, a bare `POOL_X="$val"` assigns a global;
        no `declare -g` needed and no readonly footgun). Pick ONE style and be consistent.
        Rationale: tests re-init in one shell (see Known Gotchas).
  - NO idempotency short-circuit: pool_config_init MUST re-resolve every call so tests can
        change env and re-call. (Idempotency here = "safe to re-call", NOT "skips work".)
  - NAMING: pool_config_init (public, no underscore — called by wrappers and tests).
  - PLACEMENT: directly below Task 3's helper (last function in the file).

  Task 4a: CONFIGURATION-REFERENCE COMMENT BLOCK (paste, adapt wording, keep the table).
      Place as the leading comment of pool_config_init. This IS the project config reference.
      ----------------------------------------------------------------
      # pool_config_init — resolve every configuration override to validated absolute globals.
      #
      # Enforces PRD §2.2 (never pass ~ to a subprocess) by canonicalizing every path via
      # `realpath -m` against an already-absolute $POOL_HOME_DIR. Called once near the top
      # of bin/agent-browser and bin/agent-browser-pool (and re-callable for tests).
      #
      # Configuration reference (env var → POOL_* global):
      #   ENV VAR                        DEFAULT                                         GLOBAL                CATEGORY
      #   AGENT_BROWSER_POOL_STATE       $HOME/.local/state/agent-browser-pool           POOL_STATE_DIR        path (may not exist)
      #   AGENT_CHROME_MASTER            $HOME/.agent-chrome-profiles/master-profile     POOL_MASTER_DIR       path (may not exist)
      #   AGENT_CHROME_EPHEMERAL_ROOT    $HOME/.agent-chrome-profiles/active             POOL_EPHEMERAL_ROOT   path (may not exist)
      #   AGENT_BROWSER_REAL             $HOME/.local/bin/agent-browser                  POOL_REAL_BIN         path (may not exist)
      #   AGENT_CHROME_BIN               google-chrome-stable                            POOL_CHROME_BIN       name-or-path
      #   AGENT_CHROME_PORT_BASE         53420                                           POOL_PORT_BASE        uint
      #   AGENT_CHROME_PORT_RANGE        1000                                            POOL_PORT_RANGE       uint (>0)
      #   AGENT_BROWSER_POOL_WAIT        600                                             POOL_WAIT             uint
      #   AGENT_CHROME_HEADLESS          (unset = windowed)                              POOL_HEADLESS         bool (1=headless)
      #   AGENT_BROWSER_POOL_DISABLE     (unset = pooling active)                        POOL_DISABLE          bool (1=passthrough)
      #   AGENT_CHROME_ALLOW_SLOW_COPY   (unset = refuse non-btrfs)                      POOL_ALLOW_SLOW_COPY  bool (1=allow real copy)
      #
      # Derived (no env var):
      #   POOL_HOME_DIR    = realpath($HOME)                       (fatal if unset/unresolvable)
      #   POOL_LANES_DIR   = $POOL_STATE_DIR/lanes
      #   POOL_LOCK_FILE   = $POOL_STATE_DIR/acquire.lock
      #
      # Boolean rule: a var counts as ON only when its value is exactly "1". Any other value
      # (including "true", "yes", "0") is OFF. This keeps semantics strict and predictable.
      #
      # Errors (any of these → pool_die, exit 1):
      #   - $HOME unset/empty or unresolvable
      #   - a numeric var is non-numeric
      #   - POOL_PORT_RANGE <= 0
      ----------------------------------------------------------------

  Task 4b: POOL_CHROME_BIN name-or-path rule.
      ----------------------------------------------------------------
      # Default is the bare name "google-chrome-stable" (found via PATH at launch time).
      # If the operator sets AGENT_CHROME_BIN to something containing '/', treat it as an
      # explicit path and canonicalize it; otherwise store the bare name unchanged.
      local chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
      if [[ "$chrome_in" == */* ]]; then
          POOL_CHROME_BIN="$(_pool_config_canon_path "$chrome_in")"
      else
          POOL_CHROME_BIN="$chrome_in"
      fi
      ----------------------------------------------------------------

Task 5: VERIFY (do this BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                  # syntax
  - RUN: shellcheck lib/pool.sh                               # zero warnings
  - RUN (source + init, no overrides):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 echo "STATE=$POOL_STATE_DIR"; echo "HOME=$POOL_HOME_DIR"; \
                 echo "PORT=$POOL_PORT_BASE/$POOL_PORT_RANGE"; echo "WAIT=$POOL_WAIT"; \
                 echo "HEADLESS=$POOL_HEADLESS DISABLE=$POOL_DISABLE SLOW=$POOL_ALLOW_SLOW_COPY"; \
                 echo "LANES=$POOL_LANES_DIR LOCK=$POOL_LOCK_FILE"; \
                 echo "REAL=$POOL_REAL_BIN CHROME=$POOL_CHROME_BIN MASTER=$POOL_MASTER_DIR EPH=$POOL_EPHEMERAL_ROOT"'
        # EXPECT: every line prints an absolute path (no '~'); numerics are digits; bools are 0/1.
  - RUN (no bare ~ anywhere): 
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 for v in POOL_HOME_DIR POOL_STATE_DIR POOL_MASTER_DIR POOL_EPHEMERAL_ROOT \
                           POOL_REAL_BIN POOL_LANES_DIR POOL_LOCK_FILE; do \
                     echo "${!v}"; done' | grep -n '~' && echo "FAIL: bare ~ present" || echo "OK: no bare ~"
        # EXPECT: "OK: no bare ~".
  - RUN (override honored):
        AGENT_BROWSER_POOL_STATE=/tmp/pooltest-state \
        AGENT_CHROME_PORT_BASE=60000 AGENT_CHROME_PORT_RANGE=50 \
        AGENT_CHROME_HEADLESS=1 AGENT_BROWSER_POOL_DISABLE=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 test "$POOL_STATE_DIR" = "/tmp/pooltest-state"; \
                 test "$POOL_PORT_BASE" = "60000"; test "$POOL_PORT_RANGE" = "50"; \
                 test "$POOL_HEADLESS" = "1"; test "$POOL_DISABLE" = "1"; \
                 test "$POOL_LANES_DIR" = "/tmp/pooltest-state/lanes"; \
                 test "$POOL_LOCK_FILE" = "/tmp/pooltest-state/acquire.lock"; \
                 echo OK'
        # EXPECT: OK. NOTE: realpath -m canonicalizes /tmp/pooltest-state (no .. or symlinks) to itself.
  - RUN (fatal on bad numeric):
        AGENT_CHROME_PORT_BASE=notanumber bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
        # EXPECT: a pool_die message on stderr ("...must be a non-negative integer...") and exit=1.
  - RUN (fatal on PORT_RANGE <= 0):
        AGENT_CHROME_PORT_RANGE=0 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
        # EXPECT: pool_die message + exit=1.
  - RUN (fatal on empty HOME):
        HOME= bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
        # EXPECT: pool_die message + exit=1.
  - RUN (idempotent / re-runnable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_CHROME_PORT_BASE=53420 pool_config_init; a=$POOL_PORT_BASE; \
                 AGENT_CHROME_PORT_BASE=60000 pool_config_init; b=$POOL_PORT_BASE; \
                 test "$a" = 53420; test "$b" = 60000; echo "re-init OK"'
        # EXPECT: "re-init OK". (Note: the env-var prefix on the function call sets it for that call only.)
  - RUN (S1 utilities still work after append):
        tmp="$(mktemp -d)"; POOL_LOG_PATH="$tmp/p.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log stillworks; pool_config_init; _pool_log inited'
        cat "$tmp/p.log"; rm -rf "$tmp"
        # EXPECT: two log lines (proves appending pool_config_init didn't break _pool_log / pool_die).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- DECISION: mutable globals (NOT readonly), re-runnable init -----------------
# The research brief (research/bash-config-init-research.md §4,§7) recommends
# `declare -gr` + an "already-initialized" early-return guard. We DEVIATE here, on purpose:
#
#   1. M9 tests source lib/pool.sh ONCE and call pool_config_init repeatedly with
#      different env (to exercise headless/disabled/slow-copy/ports) in ONE shell.
#   2. Readonly globals cannot be reassigned (error) and cannot be unset, so a
#      second pool_config_init with a different POOL_PORT_BASE would crash under set -e.
#   3. A "skip if initialized" guard would prevent tests from re-configuring at all.
#
# Therefore: assign POOL_* as PLAIN GLOBALS (no -g needed when called at top level; if
# you want to be defensive against being called from inside another function, use
# `declare -g POOL_X=...` which forces global scope). Re-resolution on every call is
# cheap (a handful of realpath -m subprocesses) and is the correctness property we want.

# --- Pattern: resolve $HOME first, everything else references it ----------------
pool_config_init() {
    # 1. HOME (must exist; plain realpath is fine, -m also works)
    local home_raw="${HOME:-}"
    [[ -n "$home_raw" ]] || pool_die "pool_config_init: \$HOME is unset or empty"
    local home_resolved
    home_resolved="$(realpath -- "$home_raw")" || pool_die "pool_config_init: cannot resolve \$HOME ($home_raw)"
    POOL_HOME_DIR="$home_resolved"

    # 2. path globals (defaults anchored on the now-absolute POOL_HOME_DIR)
    POOL_STATE_DIR="$(_pool_config_canon_path \
        "${AGENT_BROWSER_POOL_STATE:-$POOL_HOME_DIR/.local/state/agent-browser-pool}")"
    POOL_MASTER_DIR="$(_pool_config_canon_path \
        "${AGENT_CHROME_MASTER:-$POOL_HOME_DIR/.agent-chrome-profiles/master-profile}")"
    POOL_EPHEMERAL_ROOT="$(_pool_config_canon_path \
        "${AGENT_CHROME_EPHEMERAL_ROOT:-$POOL_HOME_DIR/.agent-chrome-profiles/active}")"
    POOL_REAL_BIN="$(_pool_config_canon_path \
        "${AGENT_BROWSER_REAL:-$POOL_HOME_DIR/.local/bin/agent-browser}")"

    # 3. CHROME_BIN name-or-path (Task 4b)
    local chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
    if [[ "$chrome_in" == */* ]]; then
        POOL_CHROME_BIN="$(_pool_config_canon_path "$chrome_in")"
    else
        POOL_CHROME_BIN="$chrome_in"
    fi

    # 4. numerics — validate, THEN enforce PORT_RANGE > 0
    POOL_PORT_BASE="$(_pool_config_require_uint AGENT_CHROME_PORT_BASE "${AGENT_CHROME_PORT_BASE:-53420}")"
    POOL_PORT_RANGE="$(_pool_config_require_uint AGENT_CHROME_PORT_RANGE "${AGENT_CHROME_PORT_RANGE:-1000}")"
    POOL_WAIT="$(_pool_config_require_uint AGENT_BROWSER_POOL_WAIT "${AGENT_BROWSER_POOL_WAIT:-600}")"
    (( POOL_PORT_RANGE > 0 )) || pool_die "AGENT_CHROME_PORT_RANGE must be > 0 (got $POOL_PORT_RANGE)"

    # 5. booleans — exactly "1" → on, anything else → off
    POOL_HEADLESS="$(_pool_config_bool "${AGENT_CHROME_HEADLESS:-}")"
    POOL_DISABLE="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"
    POOL_ALLOW_SLOW_COPY="$(_pool_config_bool "${AGENT_CHROME_ALLOW_SLOW_COPY:-}")"

    # 6. derived paths (after POOL_STATE_DIR is final)
    POOL_LANES_DIR="$(_pool_config_canon_path "$POOL_STATE_DIR/lanes")"
    POOL_LOCK_FILE="$(_pool_config_canon_path "$POOL_STATE_DIR/acquire.lock")"

    return 0
}

# --- Pattern: the three internal helpers (verbatim-ready) ----------------------
_pool_config_canon_path() {
    local in="$1" out
    [[ -n "$in" ]] || pool_die "_pool_config_canon_path: empty input"
    out="$(realpath -m -- "$in")" || pool_die "_pool_config_canon_path: cannot canonicalize: $in"
    printf '%s\n' "$out"
}

_pool_config_require_uint() {
    local name="$1" val="${2:-}"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        pool_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
    fi
    printf '%s\n' "$val"
}

_pool_config_bool() {
    local val="${1:-}"
    if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
}

# --- Critical micro-rules baked into the above ---------------------------------
#  * Every env read uses ${ENV:-default}  → safe under set -u (S1 propagated -u).
#  * `local x; x="$(...)"` two-statement form → SC2155-clean, exit status not masked.
#  * `realpath -m` (never bare `realpath`) → safe on not-yet-existing dirs → no set -e crash.
#  * Regex `[[ ! =~ ]]` and `(( ))` are inside if/|| → safe under set -e.
#  * `[[ "$chrome_in" == */* ]]` → pattern match needs NO quotes around */* inside [[ ]]`.
```

### Integration Points

```yaml
PRIOR (S1) — consumed, not modified:
  - pool_die()      : called on every fatal config error (unset HOME, bad numeric, etc.).
  - _pool_log()     : S1's logger. NOT called by pool_config_init (config runs before any
                      logging is useful; errors go via pool_die to stderr). But S1's
                      _pool_log_path() reads $AGENT_BROWSER_POOL_STATE / $POOL_LOG_PATH at
                      CALL time, so once pool_config_init has set the env (it reads env, it
                      does not set AGENT_BROWSER_POOL_STATE), _pool_log_path keeps working
                      exactly as S1 designed. DO NOT couple _pool_log_path to POOL_STATE_DIR
                      (that would change S1's contract).

LATER — provided (these subtasks read the POOL_* globals this subtask freezes):
  - P1.M1.T1.S3 (state dir setup + btrfs): consumes POOL_STATE_DIR, POOL_LANES_DIR,
        POOL_LOCK_FILE, POOL_EPHEMERAL_ROOT, POOL_ALLOW_SLOW_COPY. It will mkdir -p
        POOL_STATE_DIR/POOL_LANES_DIR and run findmnt on POOL_EPHEMERAL_ROOT.
  - P1.M2.* (owner resolution): consumes POOL_DISABLE (early passthrough check) — and
        NOTHING else from config (the owner-PID test hooks are env-only, not POOL_*).
  - P1.M3.* (leases): reads/writes $POOL_LANES_DIR/<N>.json.
  - P1.M4.* (lanes): consumes POOL_MASTER_DIR, POOL_EPHEMERAL_ROOT, POOL_CHROME_BIN,
        POOL_PORT_BASE, POOL_PORT_RANGE, POOL_HEADLESS, POOL_ALLOW_SLOW_COPY.
  - P1.M5.T1.S1 (acquire): uses POOL_LOCK_FILE for the flock critical section; POOL_WAIT
        for the exhaustion timeout.
  - P1.M6.T3.* / P1.M7.T5.* (wrappers): call pool_config_init at the very top of dispatch,
        immediately after sourcing lib/pool.sh, before any command classification.
  - P1.M9.T1.S1 (test harness): sources lib/pool.sh and calls pool_config_init with
        per-test overrides (POOL_PORT_BASE, POOL_STATE_DIR pointed at a tmpdir, etc.).

CONFIG:
  - no config/settings.py equivalent; the comment block in pool_config_init IS the reference.
  - no new env vars invented. Every input env var is listed in PRD §2.11 / external_deps §5.

ROUTES / DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending pool_config_init — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean.
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. S1's part).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression seeds):

```bash
# 2a. Source + init with defaults → all globals populated, absolute, no '~'.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         for v in POOL_HOME_DIR POOL_STATE_DIR POOL_MASTER_DIR POOL_EPHEMERAL_ROOT \
                  POOL_REAL_BIN POOL_LANES_DIR POOL_LOCK_FILE; do \
             test -n "${!v}" || { echo "FAIL: $v empty"; exit 1; }; \
             case "${!v}" in ~*) echo "FAIL: $v starts with ~ (${!v})"; exit 1;; esac; \
         done; \
         [[ "$POOL_PORT_BASE" =~ ^[0-9]+$ ]] && [[ "$POOL_PORT_RANGE" =~ ^[0-9]+$ ]] && \
         [[ "$POOL_WAIT" =~ ^[0-9]+$ ]] && \
         [[ "$POOL_HEADLESS" =~ ^[01]$ ]] && [[ "$POOL_DISABLE" =~ ^[01]$ ]] && \
         [[ "$POOL_ALLOW_SLOW_COPY" =~ ^[01]$ ]] && echo OK'
# Expected: OK.

# 2b. Overrides honored + derived paths correct.
AGENT_BROWSER_POOL_STATE=/tmp/abp-test \
AGENT_CHROME_PORT_BASE=60000 AGENT_CHROME_PORT_RANGE=50 AGENT_BROWSER_POOL_WAIT=30 \
AGENT_CHROME_HEADLESS=1 AGENT_BROWSER_POOL_DISABLE=1 AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         test "$POOL_STATE_DIR"   = /tmp/abp-test; \
         test "$POOL_LANES_DIR"   = /tmp/abp-test/lanes; \
         test "$POOL_LOCK_FILE"   = /tmp/abp-test/acquire.lock; \
         test "$POOL_PORT_BASE"   = 60000; \
         test "$POOL_PORT_RANGE"  = 50; \
         test "$POOL_WAIT"        = 30; \
         test "$POOL_HEADLESS"    = 1; \
         test "$POOL_DISABLE"     = 1; \
         test "$POOL_ALLOW_SLOW_COPY" = 1; \
         echo OK'
# Expected: OK.

# 2c. CHROME_BIN name vs path.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; test "$POOL_CHROME_BIN" = google-chrome-stable; echo OK-name'
AGENT_CHROME_BIN=/usr/bin/google-chrome-stable \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; test "$POOL_CHROME_BIN" = /usr/bin/google-chrome-stable; echo OK-path'
# Expected: OK-name AND OK-path.

# 2d. Fatal on bad numeric (subshell isolates the harness).
AGENT_CHROME_PORT_BASE=abc bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
# Expected: a pool_die stderr line mentioning "must be a non-negative integer" and exit=1.

# 2e. Fatal on PORT_RANGE <= 0.
AGENT_CHROME_PORT_RANGE=0 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
# Expected: pool_die message + exit=1.

# 2f. Fatal on empty HOME.
HOME= bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init' ; echo "exit=$?"
# Expected: pool_die message + exit=1.

# 2g. Idempotent / re-runnable with different env in one shell (the test-harness use case).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_CHROME_PORT_BASE=53420 pool_config_init; test "$POOL_PORT_BASE" = 53420; \
         AGENT_CHROME_PORT_BASE=60000 pool_config_init; test "$POOL_PORT_BASE" = 60000; \
         AGENT_BROWSER_POOL_STATE=/tmp/x pool_config_init; test "$POOL_STATE_DIR" = /tmp/x; \
         echo OK'
# Expected: OK. (This is WHY globals are mutable, not readonly.)

# 2h. S1 utilities still functional after the append (regression).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
POOL_LOG_PATH="$tmp/p.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log pre; pool_config_init; _pool_log post; \
         ( pool_die should-Exit-1 ) 2>/dev/null; true'
test -s "$tmp/p.log" && grep -q pre "$tmp/p.log" && grep -q post "$tmp/p.log" && echo OK
# Expected: OK (two log lines; pool_die still exits non-zero inside the subshell).

# Expected: ALL of 2a–2h pass. Debug root cause on any failure (likely a bare `realpath`
# instead of `realpath -m`, a missing `${VAR:-}`, or a SC2155 local-capture).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. The full file still sources cleanly and S1's deliverables are intact.
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_die _pool_log pool_config_init'
# Expected: all three reported as functions.

# 3b. Downstream-consumer smoke test: simulate what P1.M1.T1.S3 will do.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         mkdir -p "$POOL_LANES_DIR"; \
         ( flock 9; echo locked ) 9>"$POOL_LOCK_FILE"; \
         echo "lanes=$POOL_LANES_DIR"; test -d "$POOL_LANES_DIR"; echo OK'
# Expected: prints the lanes dir, "locked", and OK — proves POOL_LANES_DIR and POOL_LOCK_FILE
#           are usable exactly as the next subtask will use them.

# 3c. No stray repo artifacts from testing (config must not create runtime dirs).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts'.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the realpath -m vs realpath distinction on THIS host (the core correctness claim).
realpath /nonexistent/deep/path   ; echo "realpath exit=$?"     # expect exit=1
realpath -m /nonexistent/deep/path; echo "realpath -m exit=$?"  # expect exit=0
# Expected: confirms why pool_config_init MUST use -m for may-not-exist paths.

# 4b. Confirm every POOL_* path is genuinely absolute (starts with '/') — catches a
#     accidental bare-~ or relative default slipping through.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         for v in POOL_HOME_DIR POOL_STATE_DIR POOL_MASTER_DIR POOL_EPHEMERAL_ROOT \
                   POOL_REAL_BIN POOL_LANES_DIR POOL_LOCK_FILE; do \
             case "${!v}" in /*) ;; *) echo "FAIL: $v not absolute: ${!v}"; exit 1;; esac; \
         done; echo all-absolute'
# Expected: all-absolute.

# 4c. Symlinked-$HOME robustness (informational; skip if you can't safely symlink).
#     If $HOME were a symlink, realpath "$HOME" follows it to the canonical target — which
#     is the PRD §2.2 intent. No action required beyond confirming 4b passes on the real host.
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors) — whole file including S1's part.
- [ ] Level 2 snippets 2a–2h all pass.
- [ ] Level 3 snippets 3a–3c all pass.
- [ ] Level 4 snippet 4a confirms `realpath -m` exit 0 on missing paths (justifies the design).

### Feature Validation

- [ ] `pool_config_init()` defined and callable after `source lib/pool.sh`.
- [ ] All 14 `POOL_*` globals from the mapping table are populated after `pool_config_init`.
- [ ] No `POOL_*` path value contains a literal `~` (Level 2 / 4b).
- [ ] All `POOL_*` paths are absolute (start with `/`), except `POOL_CHROME_BIN` which may be a bare name when no `/` is in the override.
- [ ] `pool_config_init` calls `pool_die` (exit 1) on: unset/empty/unresolvable `$HOME`, non-numeric `PORT_BASE`/`PORT_RANGE`/`WAIT`, `PORT_RANGE <= 0`.
- [ ] `pool_config_init` is re-runnable: a second call with different env updates the globals (no error) — Level 2 snippet 2g.
- [ ] All three internal helpers (`_pool_config_canon_path`, `_pool_config_require_uint`, `_pool_config_bool`) are defined and used by `pool_config_init`.
- [ ] The [Mode A] configuration-reference comment block is present and lists every env var, its default, and its purpose.

### Code Quality Validation

- [ ] APPENDED to S1's `lib/pool.sh` — header, `set -euo pipefail`, `pool_die`, `_pool_log`, `_pool_log_path` left intact and unmodified.
- [ ] Every env read uses `${VAR:-default}` (set -u safe).
- [ ] Every `realpath` is `realpath -m` (set -e safe on not-yet-existing dirs), except the `$HOME` resolution where plain `realpath` is also acceptable.
- [ ] Every `local` capture is two-statement (SC2155 clean): `local x; x="$(...)"`.
- [ ] All expansions double-quoted (SC2086 clean).
- [ ] No `declare -gr` / `readonly` used on `POOL_*` (mutable by design, per the documented decision).
- [ ] No top-level executable code added beyond function definitions (sourcing stays side-effect-free apart from S1's existing `set -euo pipefail`).
- [ ] Naming matches the project convention: `pool_config_init` (public), `_pool_config_*` (internal).

### Documentation & Deployment

- [ ] The in-function comment block is the configuration reference (an operator can read it to learn every env var the pool honors, its default, and its effect).
- [ ] No new env vars invented; no env vars from PRD §2.11 / external_deps §5 omitted (the test-only owner hooks are intentionally excluded with a documented reason).
- [ ] No source/PRD/tasks.json/.gitignore files modified.

---

## Anti-Patterns to Avoid

- ❌ Don't use bare `realpath` on default paths that may not exist yet (state/ephemeral/master/lanes/lock) — it exits 1 on missing intermediate components and crashes under `set -e`. Use `realpath -m`. (Verified on host.)
- ❌ Don't use `declare -gr` / `readonly` on `POOL_*` — the test harness re-inits with different env in one shell; readonly makes the 2nd call fatal.
- ❌ Don't add an "already-initialized" early-return guard that skips re-resolution — same reason: tests need to re-configure.
- ❌ Don't read any env var without `${VAR:-...}` — S1 propagated `set -u`, so `$AGENT_CHROME_PORT_BASE` aborts when unset.
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155; masks exit status under `set -e`).
- ❌ Don't canonicalize `POOL_CHROME_BIN` when it's a bare name (no `/`) — `realpath google-chrome-stable` fails or misresolves. Store bare names as-is.
- ❌ Don't resolve `AGENT_BROWSER_POOL_OWNER_PID` / `AGENT_BROWSER_POOL_OWNER_STARTTIME` into `POOL_*` globals — those are M2 owner-resolution test hooks, not config.
- ❌ Don't recreate S1's header, strict-mode line, `pool_die`, `_pool_log`, or `_pool_log_path` — APPEND only.
- ❌ Don't put a bare `(( ... ))` as a statement (returns non-zero when result is 0 → fatal under `set -e`). Always `(( ... )) || pool_die ...` or inside `if`.
- ❌ Don't treat boolean env vars as "any non-empty = on" — the PRD's tri-state is "`=1` = on, unset = off"; stick to exactly-`1` for predictability (documented in the comment block).
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any source file other than appending to `lib/pool.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The contract is unusually precise (an explicit env→global mapping table with categories).
- The one subtle correctness trap — `realpath` vs `realpath -m` on not-yet-existing dirs — was **verified on the host this session** (`realpath /nonexistent/deep/path` → exit 1; `realpath -m ...` → exit 0) and is called out in three places (Known Gotchas, Task 1, Validation 4a).
- The one design tension — readonly vs mutable globals — is resolved with a documented, test-driven decision (mutable + re-runnable), and the idempotency/re-runnability test (2g) directly proves it.
- S1's prior contract is quoted and treated as immutable, so the implementer knows exactly what exists before they start.
- All validation commands are copy-pasteable and verified to be available on the host (`bash -n`, `shellcheck 0.11.0`, `realpath` from coreutils).

The -1 is for the residual risk that the implementer, despite the three callouts, reaches for `declare -gr` because "config should be immutable" sounds reasonable — Level 2 snippet 2g will catch that immediately (it fails on readonly), which is exactly why that test exists.
