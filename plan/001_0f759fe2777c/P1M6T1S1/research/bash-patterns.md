# Research §3 — bash correctness patterns for the dispatch scan

The dispatch function runs under `set -euo pipefail` (inherited from the lib header,
line 19). Every construct below is chosen to be errexit-safe. Each rule cites the GNU
manual or a prior-art line in `lib/pool.sh`.

---

## 1. NEVER a bare `(( expr ))` statement — always a CONDITION

GNU Bash (Compound Commands): *"`(( expression ))` … The exit status is 0 if the
expression evaluates to non-zero; otherwise the exit status is 1."* Under `set -e` a
bare `(( ))` that evaluates to 0 **ABORTS the script**.

This is already documented in `lib/pool.sh` lines 362–364 (the `_pool_age_str` GOTCHA):
> "a bare `(( expr ))` as a STATEMENT returns exit status 1 when the result is 0 — FATAL
> under set -e. EVERY `(( ))` here is inside `if`/`elif` (exempt from errexit)."

**Application here:** the loop guard is `while (( $# ))`.
- `$# > 0` → expression non-zero → rc 0 → loop body runs.
- `$# == 0` → expression 0 → rc 1 → `while` exits. Because it is the `while` CONDITION
  (not a statement), it is **exempt** from `set -e`. SAFE. (Prior art: `lib/pool.sh:529`
  `while (( steps++ < 128 ))`; `lib/pool.sh:547` `if (( ppid == 1 ))`.)

**The index-loop trap we AVOID:** an index counter `i` would need `(( i++ ))` to advance.
`(( i++ ))` returns the OLD value of `i`; if `i` started at 0 the result is 0 → rc 1 →
ABORT. There is no safe "post-increment in a statement" form under `set -e` except
`i=$(( i + 1 ))` (an assignment, always rc 0). We dodge the whole problem by using a
**shift-based loop with no index** (see `dispatch-logic.md` §4).

Refs:
- https://www.gnu.org/software/bash/manual/html_node/Compound-Commands.html (Arithmetic
  Expansion / `(( ))` rc semantics)
- https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html (`-e` exemption
  list: the command following `while`/`if`/`until` is exempt)

---

## 2. `shift` rc, and why `shift 2 || shift` is safe

`shift N` returns 0 if there are ≥ N positional params left, else 1. Under `set -e` a
bare `shift 2` with < 2 params ABORTS. The idiom `shift 2 || shift` is an `||`-list:
- if `shift 2` succeeds (≥2 params) → rc 0, `|| shift` skipped.
- if `shift 2` fails (<2 params) → rc 1, `|| shift` runs (consumes the 1 remaining).
The `||`-list is **exempt** from `set -e` (the GNU `-e` exemption: "any command in a `||`
list except the last"). The trailing `shift` either succeeds (rc 0) or, if `$#==0`, the
loop guard already prevented entry. SAFE.

(Used for the `--session` space-form arm: consume flag + value, but tolerate a trailing
`--session` with no value.)

---

## 3. `local` masks return codes — but we don't care here (rc is always 0)

SC2155 ("Declare and assign separately to avoid masking exit status") matters when the
RHS is a command whose rc you need (e.g. `local N="$(pool_acquire_locked)"` masks the
rc-1 exhaustion path — see the M5.T4.S1 PRP). **Here it is irrelevant**: the only
"command" results are `printf`/`return`, and the function returns 0 unconditionally. So
`local cmd next tok` declared once, assigned separately, is clean and SC-clean. No
`local X=$(failing-cmd)` pattern exists in this function.

Ref: https://www.shellcheck.net/wiki/SC2155

---

## 4. `case` is the right tool (not a chain of `[[ ]]` / `elif`)

`case "$tok" in …` with glob patterns (`--*`, `-*`, `--help|-h|--version`) is:
- O(n) single-pass, first-match-wins — exactly the "find first non-flag" semantics.
- errexit-safe: a `case` does not run external commands; `[[ ]]`-free.
- ShellCheck-clean (no SC2053 etc. when patterns are literal globs).

The ordering puts specific flags (`--help|-h|--version`, `--session`) BEFORE the generic
`--*`/`-*` catch-alls so they win. See `dispatch-logic.md` §4.

---

## 5. `printf '%s\n'` is the only stdout write (stdout discipline)

Every classification outcome is a single `printf 'meta\n'` / `printf 'driving\n'`
followed by `return 0`. No `_pool_log` (writes a file + stderr, never stdout — but we
don't even need it). No subcommand dispatch. So `class="$(pool_dispatch_classify "$@")"`
captures EXACTLY one token. This matches the stdout contract of `pool_lanes_list`
(echoes lane numbers only) and `pool_find_free_port` (echoes the port only).

---

## 6. Array-less design (no `local -a`)

The function never materializes `$@` into an array. It consumes positional params
in-place via `shift`. This avoids:
- `local -a args=("$@")` + index iteration (brings back the `(( i++ ))` trap).
- `set -u` hazards with `${args[i]}` on out-of-range (bash arrays don't error but the
  `(( ))` index math does).

`"$1"` and `${2:-}` under `set -u`: `"$1"` is always set inside the loop (guarded by
`(( $# ))`); `${2:-}` defaults empty if absent. Both are `set -u`-safe.

---

## 7. Banner + placement (matches codebase convention)

Append at EOF under a new banner. Current EOF (after M5.T4.S1 landed):
```
…
# Pool exhaustion (P1.M5.T4.S1)   ← banner @2777-2779
_pool_alert                         ← @2815
pool_wait_for_lane                  ← @2909  (closing brace = EOF, ~line 2971)
```
New banner (APPEND, after pool_wait_for_lane's closing brace):
```
# =============================================================================
# Wrapper shim — command dispatch (P1.M6.T1.S1)
# =============================================================================
# pool_dispatch_classify
```
Naming: `pool_dispatch_classify` (PUBLIC, no `_` prefix) — matches the
`pool_dispatch_*` family named in `architecture/key_findings.md` line 215
("pool_dispatch_*  ← wrapper command dispatch"). Single function, no private helper
needed (the scan is short enough to inline).
