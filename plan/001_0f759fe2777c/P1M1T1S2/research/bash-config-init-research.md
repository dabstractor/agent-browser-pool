# Research: Bash config/init in a sourced strict-mode library (`set -euo pipefail`)

> Scope: resolving env vars into **global `readonly`** variables from inside a function of a **sourced** bash library running under `set -euo pipefail`. Target runtime is **bash 5.x on GNU coreutils** (Linux). All code below is written for that target.

---

## Summary

Use `declare -gr` (global + readonly) from inside the init function — `declare -r` without `-g` silently creates a *local*, the #1 sourced-lib bug. Guard re-init with an `_…_INITIALIZED` flag because **readonly variables cannot be `unset`** and re-assigning them is a fatal error under `set -e`. Resolve `$HOME` with plain `realpath` (it exists), but use **`realpath -m`** for any not-yet-created state dir — `-m` (`--canonicalize-missing`) is the documented option that canonicalizes with *no* existing components and exits 0. Validate numbers with `[[ =~ ^[0-9]+$ ]]` inside an `if` (conditions are immune to `errexit`), and read every env var through `${VAR:-}` so `set -u` never aborts. `typeset` and `declare` are **identical in bash**.

---

## Findings

### 1. `declare -g` vs `declare -gr` (global + readonly) inside a sourced function

**Core rule:** `declare` (and `local`/`typeset`) inside a function creates a **function-local** variable unless you pass `-g`. So to write a *global* from within the init function you must use `-g`.

```bash
_abp_init_config() {
    local raw="${ABP_HOME:-$HOME}"

    # WRONG (no -g): creates a function-local, NOT a global; the caller never sees it.
    declare -r ABP_HOME_RESOLVED="$raw"

    # WRONG (no -g, plus local): same problem, worse — it's gone when the function returns.
    # CORRECT: global + readonly
    declare -gr ABP_HOME_RESOLVED="$raw"
}
```

| Form | Scope | Mutable | Notes |
|------|-------|---------|-------|
| `declare VAR=…` (in function) | local | yes | caller cannot see it |
| `declare -g VAR=…` | global | yes | sets a true global |
| `declare -r VAR=…` (in function) | **local** readonly | no | classic bug — global is never set |
| `declare -gr VAR=…` | global readonly | no | what you want for config |

**Interaction with `set -u`:** the act of `declare`-ing (even to empty) makes the name *set*, so later `${ABP_HOME_RESOLVED}` won't trigger `unbound variable`. Always initialize from the env with `${VAR:-…}` so an unset source var never aborts.

**Interaction with `set -e` (errexit):**
- Assigning to a variable that is **already readonly** is an error (`bash: ABP_X: readonly variable`) and is fatal under `set -e`. This is the heart of the idempotency problem (§4, §7).
- **`declare`/`local` mask the exit status of command substitution** ([BashFAQ: declare/local hide failure](http://mywiki.wooledge.org/BashFAQ) — *see "local var=$(cmd) swallows failures" discussion*). `declare -gr X="$(may_fail)"` returns 0 even if `may_fail` returns non-zero, so `set -e` will **not** fire. Mitigation: capture into a local first, validate/propagate, then declare readonly:

```bash
_abp_init_config() {
    local home
    home="$(_abp_resolve_home)" || return 1   # failure here IS caught by set -e
    declare -gr ABP_HOME_RESOLVED="$home"
}
```

Docs: [Bash Manual — Bash Builtins (`declare`)](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins), [The Set Builtin](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin).

---

### 2. Resolving `$HOME` to an absolute canonical path; `realpath` vs `realpath -m`

**Safest for `$HOME` (which is expected to exist):**

```bash
_abp_resolve_home() {
    local input="${HOME:-}" resolved
    [[ -n "$input" ]] || { printf 'error: $HOME is unset or empty\n' >&2; return 1; }
    # realpath: resolves symlinks + '.', '..' → canonical absolute path.
    # $HOME exists, so default mode is correct.
    if ! resolved="$(realpath -- "$input" 2>/dev/null)"; then
        printf 'error: could not resolve $HOME (%s)\n' "$input" >&2
        return 1
    fi
    printf '%s\n' "$resolved"
}
```

**`realpath` vs `realpath -m` (GNU coreutils) — the documented modes:**

| Mode | What must exist | Behavior on missing path | Exit status |
|------|-----------------|--------------------------|-------------|
| `realpath` (default) | **all but the last** component must exist | missing *intermediate* component → error; missing *leaf* under an existing parent → prints canonical path | **0** if canonicalizable (missing leaf OK on GNU), **non-zero** if a required (non-leaf) component is missing |
| `realpath -e` (`--canonicalize-existing`) | **all** components must exist | any missing component → error | non-zero if anything missing |
| `realpath -m` (`--canonicalize-missing`) | **nothing** must exist | never fails due to nonexistence | **0** (only fails on other errors, e.g. permission on an existing component) |
| `realpath -s` (`--strip`/`--no-symlinks`) | (orthogonal) | does **not** expand symlinks | as above |

**Does `realpath` return exit 0 on nonexistent paths?** Nuanced — and this is the trap:
- On **GNU coreutils**, the default mode requires only *all-but-the-last* component to exist, so a missing **leaf** whose parent exists (e.g. `realpath /tmp/notyet`) prints `/tmp/notyet` and exits 0, **but** a missing **intermediate** component (e.g. `realpath /no/such/dir`) exits **non-zero**.
- On **BSD/macOS** `realpath`, a missing path (even a leaf) generally fails.
- Therefore: **do not rely on the default for "may not exist yet."**

**Which is correct for not-yet-created default paths (state dir, cache dir)?**
→ **`realpath -m`** is the documented, correct choice — it canonicalizes with no existing components and exits 0:

```bash
# State dir may not exist yet → use -m (--canonicalize-missing)
_abp_resolve_or_create_dir() {
    local input="$1" resolved
    if ! resolved="$(realpath -m -- "$input" 2>/dev/null)"; then
        printf 'error: could not canonicalize path (%s)\n' "$input" >&2
        return 1
    fi
    printf '%s\n' "$resolved"
}
```

**Manual string ops** (`${HOME%/}`, parameter expansion) are *not* canonicalization: they cannot resolve symlinks or `..`, and they don't verify existence. Use them only for trivial trailing-slash cleanup, never as a `realpath` replacement.

**Pitfall:** `realpath` (GNU) is from coreutils. For portability to systems without GNU coreutils, prefer `readlink -f` (also "all but last must exist") or guard with a capability check. If you need **no symlink resolution** for `$HOME` (rare), use `realpath -s`.

Docs: [Coreutils Manual — `realpath` invocation](https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html) (`-m`/`--canonicalize-missing`, `-e`/`--canonicalize-existing`, `-s`/`--no-symlinks`).

---

### 3. Validating numeric env vars under strict mode

Recommended: `[[ =~ ^[0-9]+$ ]]` **inside an `if`** (conditions are exempt from `errexit`), then `die` on failure. Validate before binding the global.

```bash
_abp_die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

# require a non-negative integer; echo value on success, die on failure
_abp_require_uint() {
    local name="$1" val="${2:-}"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        _abp_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
    fi
    printf '%s\n' "$val"
}

# range-checked integer
_abp_require_port() {
    local name="$1" val="${2:-}" n
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        _abp_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
    fi
    n=$(( val ))          # safe: val is digits only
    if (( n < 1024 || n > 65535 )); then
        _abp_die "$name ($val) out of range [1024,65535]"
    fi
    printf '%s\n' "$n"
}
```

Usage in init:

```bash
_abp_init_config() {
    local port_base
    port_base="$(_abp_require_port ABP_PORT_BASE "${ABP_PORT_BASE:-30000}")"
    declare -gr ABP_PORT_BASE="$port_base"
}
```

**Strict-mode traps to avoid:**
- `${ABP_PORT_BASE:-30000}` — the `:-default` is mandatory under `set -u`; a bare `$ABP_PORT_BASE` aborts when unset.
- `(( expr ))` returns **non-zero when the result is 0**. Bare `(( n ))` where `n==0` exits under `set -e`. Always put arithmetic in an `if`, or append `|| true`. The `(( n < 1024 … ))` above is inside `if`, so it's safe.
- Regex `[[ =~ ]]`: in the `if` branch it won't trip `errexit`; the negated `[[ ! … =~ … ]]` likewise returns a clean 0/1. (Docs: [Bash Conditional Expressions](https://www.gnu.org/software/bash/manual/bash.html#Bash-Conditional-Expressions), [Conditional Constructs](https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs).)

---

### 4. Config-init conventions & idempotency (success → `return 0`; error → `die`)

**`return` vs `die`/`exit`:** A library is *sourced*, so `exit` kills the **whole** shell/program (including test runners sourcing it). Convention for a CLI-style config gate: `return 0` on success, and route all failures through a single `die` that `exit 1`s. This makes "bad config = hard stop" explicit, but note the test-time consequence (below).

**Idempotency is hard with readonly** because (a) you **cannot `unset` a readonly variable** (`unset ABP_X` errors `readonly variable`), and (b) re-assigning it is a fatal error under `set -e`. So "unset first, then re-declare" **does not work** for readonly. The correct idiom is a **guard flag**:

```bash
_abp_init_config() {
    # Idempotent guard: cheap, runs before any readonly declaration.
    if [[ "${_ABP_CONFIG_DONE:-0}" == "1" ]]; then
        return 0
    fi

    # --- resolve + validate (all return/die on error) ---
    local home port_base
    home="$(_abp_resolve_home)"              || return 1
    port_base="$(_abp_require_port ABP_PORT_BASE "${ABP_PORT_BASE:-30000}")"

    # --- freeze config as global readonly ---
    declare -gr ABP_HOME_RESOLVED="$home"
    declare -gr ABP_PORT_BASE="$port_base"
    declare -gr ABP_DEBUG="$([[ "${ABP_DEBUG:-}" == "1" ]] && echo 1 || echo 0)"

    # --- mark done (also readonly; subsequent calls short-circuit) ---
    declare -gr _ABP_CONFIG_DONE=1
    return 0
}
```

**Key facts about the guard:**
- `_ABP_CONFIG_DONE` is checked with `${…:-0}` so the *first* call (unset) sees `0` and proceeds; we never read it unguarded.
- Making `_ABP_CONFIG_DONE` readonly is fine — the `if` returns early on later calls, so it is never re-assigned.
- If you instead made config values mutable (not `-r`), you could re-run init freely — but then you lose the "config is frozen" guarantee. Readonly + guard is the recommended pair for a config gate.

**Test-time pitfall:** because `die` calls `exit 1`, a failing init inside a sourced test file exits the test runner. Mitigations: (a) ensure tests feed valid env so init always succeeds, (b) allow `die` to be overridden for tests, or (c) run init in a subshell `(_abp_init_config)` when you only want its return status.

---

### 5. Boolean / tri-state env vars (unset = default, `=1` = opt-in)

Use `[[ "${VAR:-}" == "1" ]]`. The `${VAR:-}` is **mandatory** under `set -u`.

```bash
# Tri-state: unset/empty/anything-but-"1" → off; exactly "1" → on
if [[ "${ABP_DEBUG:-}" == "1" ]]; then
    declare -gr ABP_DEBUG=1
else
    declare -gr ABP_DEBUG=0
fi

# One-liner (works because [[ ]] in this position is a normal command;
# the &&/|| chain return status is well-defined and set -e won't abort on the false branch here):
declare -gr ABP_DEBUG="$( [[ "${ABP_DEBUG:-}" == "1" ]] && echo 1 || echo 0 )"

# "Any non-empty value means on" variant:
if [[ -n "${ABP_VERBOSE:-}" ]]; then ABP_VERBOSE_FLAG=1; else ABP_VERBOSE_FLAG=0; fi
```

**Anti-patterns to avoid:**
- `[[ -n "$ABP_DEBUG" ]]` — aborts under `set -u` when unset (missing `:-`).
- `[ $ABP_DEBUG ]` — word-splits and errors when empty/unset. ([BashPitfalls](http://mywiki.wooledge.org/BashPitfalls))
- `[[ "$ABP_DEBUG" == "true" ]]` — couples you to a string format; `=1` is the conventional Unix opt-in.

---

### 6. `typeset -g` vs `declare -g` in bash — identical?

**Yes — identical in bash.** The Bash Manual documents `typeset` as a synonym for `declare`:

> `typeset` … See `declare`. The `typeset` keyword is provided for ksh compatibility and is exactly equivalent to `declare`.

So `typeset -g`, `typeset -gr`, `typeset -gA` behave exactly like `declare -g`, `declare -gr`, `declare -gA`.

```bash
typeset -gr ABP_PORT_BASE=30000   # identical to:
declare  -gr ABP_PORT_BASE=30000
```

**Recommendation:** use `declare` in bash-only code (idiomatic, unambiguous); reserve `typeset` only when you're deliberately targeting ksh portability. **Caveat:** they are *not* identical across shells — in **zsh**, `typeset` is the primary builtin and `declare` is the alias, and the scoping rules differ from bash. Don't assume equivalence outside bash.

Docs: [Bash Manual — Bash Builtins (`declare`/`typeset`)](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins).

---

### 7. Readonly + re-sourcing (tests, interactive re-source): avoid "readonly variable"

**The problem:** if the library is sourced multiple times (test harness re-sources, you `source lib.sh` twice in a shell, BATS re-loads), any code path that re-runs a `declare -gr X=…` errors:

```
bash: ABP_PORT_BASE: readonly variable
```

…which is fatal under `set -e`. Three robust patterns:

**(a) Guard the whole init path (recommended — same flag as §4):**
```bash
_abp_init_config() {
    [[ "${_ABP_CONFIG_DONE:-0}" == "1" ]] && return 0
    # … readonly declarations …
    declare -gr _ABP_CONFIG_DONE=1
}
```

**(b) Guard each module-level constant at source time** (when constants are declared outside a function):
```bash
[[ -v ABP_LIB_VERSION ]] || declare -gr ABP_LIB_VERSION="1.0.0"
# or guard the entire file:
if [[ -z "${_ABP_LIB_LOADED:-}" ]]; then
    declare -gr _ABP_LIB_LOADED=1
    # … top-level readonly constants …
fi
```
(`[[ -v NAME ]]` tests whether a name is set; requires bash ≥ 4.2. It works on readonly names — it just reports true.)

**(c) If re-configuration is required, don't use `readonly`.** Readonly is fundamentally a one-way latch within a single shell: **the only way to reset readonly globals is to start a new shell.** If a test needs fresh config between cases, run each case in a subshell/fresh `bash`, or keep config mutable (`declare -g`, not `-gr`).

**Pitfalls to flag:**
- `unset` cannot clear a readonly variable (`unset ABP_X` → `readonly variable`).
- There is no builtin predicate "is this var readonly?"; you can only inspect via `readonly -p`.
- Exporting readonly (`declare -grx`) makes the value leak to child processes but the child still can't modify the parent's copy — and `export` + `readonly` ordering edge cases exist; prefer `declare -gr` and `export` separately only if you need it inherited.
- Sourcing a file that re-declares an already-readonly name **exits under `set -e`**, so even a benign "include guard" must run *before* any `declare -gr`.

Docs: [Bash Manual — Bash Builtins (`readonly`, `declare`)](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins), [The Set Builtin](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin).

---

## Consolidated idiomatic skeleton

```bash
#!/usr/bin/env bash
# lib.sh — sourced library, strict mode, global readonly config
set -euo pipefail

_abp_die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

_abp_resolve_home() {
    local input="${HOME:-}" resolved
    [[ -n "$input" ]] || { printf 'error: $HOME is unset or empty\n' >&2; return 1; }
    resolved="$(realpath -- "$input" 2>/dev/null)" \
        || { printf 'error: cannot resolve $HOME (%s)\n' "$input" >&2; return 1; }
    printf '%s\n' "$resolved"
}

_abp_resolve_maybedir() {                 # for not-yet-created state dirs
    local input="$1" resolved
    resolved="$(realpath -m -- "$input" 2>/dev/null)" \
        || { printf 'error: cannot canonicalize (%s)\n' "$input" >&2; return 1; }
    printf '%s\n' "$resolved"
}

_abp_require_port() {
    local name="$1" val="${2:-}" n
    [[ "$val" =~ ^[0-9]+$ ]] || _abp_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
    n=$(( val ))
    (( n >= 1024 && n <= 65535 )) || _abp_die "$name ($val) out of range [1024,65535]"
    printf '%s\n' "$n"
}

_abp_init_config() {
    [[ "${_ABP_CONFIG_DONE:-0}" == "1" ]] && return 0     # idempotent guard (§4,§7)

    local home port_base debug
    home="$(_abp_resolve_home)" || return 1               # catch failure (§1)
    port_base="$(_abp_require_port ABP_PORT_BASE "${ABP_PORT_BASE:-30000}")"
    debug="$( [[ "${ABP_DEBUG:-}" == "1" ]] && echo 1 || echo 0 )"   # tri-state (§5)

    declare -gr ABP_HOME_RESOLVED="$home"                 # global + readonly (§1)
    declare -gr ABP_PORT_BASE="$port_base"
    declare -gr ABP_DEBUG="$debug"
    declare -gr ABP_STATE_DIR="$(_abp_resolve_maybedir "${ABP_STATE_DIR:-${ABP_HOME_RESOLVED}/.abp/state}")"

    declare -gr _ABP_CONFIG_DONE=1
    return 0
}

_abp_init_config   # run at source time; safe to re-source thanks to the guard
```

---

## Sources

**Kept:**
- [GNU Bash Manual — Bash Builtins (`declare`, `local`, `readonly`, `typeset`)](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins) — authoritative for `-g`/`-r` scoping, `typeset`≡`declare`, and readonly semantics.
- [GNU Bash Manual — The Set Builtin](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin) — `-e`/`-u`/`-o pipefail` behavior referenced throughout.
- [GNU Bash Manual — Conditional Constructs](https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs) — `[[ ]]`/`(( ))` are `errexit`-safe inside `if`.
- [GNU Bash Manual — Bash Conditional Expressions](https://www.gnu.org/software/bash/manual/bash.html#Bash-Conditional-Expressions) — `=~` and `-v` semantics.
- [GNU Coreutils Manual — `realpath` invocation](https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html) — `-m`/`-e`/`-s` mode definitions.
- [Greg's Wiki — BashFAQ](http://mywiki.wooledge.org/BashFAQ) — community-canon on `declare`/`local` masking substitution failure and strict-mode gotchas.
- [Greg's Wiki — BashPitfalls](http://mywiki.wooledge.org/BashPitfalls) — word-splitting/unquoted-expansion and arithmetic-vs-errexit traps.
- [Bash Hackers Wiki — `declare`](https://wiki.bash-hackers.net/commands/builtin/declare) — readable reference on attribute flags incl. `-g`/`-r`.

**Dropped:**
- Various Stack Overflow answers on `realpath` — superseded by the Coreutils manual (primary source).
- Blog posts on "bash strict mode" — opinion-heavy; superseded by the Bash Manual + Greg's Wiki.

---

## Gaps

- **No live verification this session** (no `web_search`/shell tool was available in this subagent environment). Code and semantics are from documented behavior of bash 5.x and GNU coreutils; citations point at stable GNU/Greg's-Wiki URLs. **Recommend the parent spot-check two items on the target platform:**
  1. The exact GNU `realpath` default (no flag) leaf behavior on the deployment OS — i.e. `realpath /tmp/notyet` exit code. The recommendation (`-m` for not-yet-existing dirs) is robust regardless of this nuance, but confirm if `$HOME` could ever be missing.
  2. **Anchor IDs** in the Bash Manual HTML (`#Bash-Builtins`, `#The-Set-Builtin`, `#Conditional-Constructs`, etc.) — these are stable but derived from section titles; verify they resolve on the bash version's manual build you link against.
- `[[ -v NAME ]]` requires bash ≥ 4.2; confirm the minimum bash version targeted (the skeleton avoids it in the hot path, using the `${…:-}` guard instead).
- BSD/macOS `realpath` differs from GNU; if non-Linux targets matter, add a capability check or fall back to `readlink -f`.
