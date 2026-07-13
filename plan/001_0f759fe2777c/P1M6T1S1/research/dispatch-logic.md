# Research §2 — dispatch algorithm design & contract reconciliation

The implementation spine for `pool_dispatch_classify`. Every design choice is tied to a
line in the item CONTRACT or to a bash-correctness rule (see `bash-patterns.md`).

---

## 1. The CONTRACT, restated (item description steps 2–5)

```
INPUT:  original command-line args ($@)
LOGIC:  pool_dispatch_classify(args)
  a. Skip leading flags (--help, -h, --version, --json, --session <X>).
     Find the first non-flag token = the command.
  b. META (return 'meta'):    skills, dashboard, plugin, mcp, session list, --help, -h, --version
  c. DRIVING (return 'driving'): open, click, …, connect, close, session, …, get, is, find
  d. Unrecognized → 'driving' (let the real binary handle the error)
  e. Echo 'meta' or 'driving'
OUTPUT: echoes 'meta' or 'driving' (consumed by the lifecycle integration M6.T3)
```

---

## 2. KEY INSIGHT — only META needs explicit detection

Steps (c) and (d) BOTH return 'driving'. Therefore a token is EITHER:
- in the META set → 'meta', OR
- anything else → 'driving'.

**The DRIVING set never needs to be enumerated in code.** Enumerating it would be pure
documentation (membership → driving; absence → driving; identical result). The robust
choice is: detect META explicitly, default everything else to 'driving'. This means
future agent-browser driving commands (`mouse`, `react`, a new one) auto-classify
correctly without a library edit. The full DRIVING list is kept as a COMMENT only
(citing the contract + external_deps §1.1) for the reader.

---

## 3. Reconciling (a) "skip --help/-h/--version" vs (b) "they are META"

These are reconciled by **short-circuit**: when the left→right scan encounters
`--help`, `-h`, or `--version`, return 'meta' immediately. Rationale + correctness in
`command-taxonomy.md` §2. This is the only reading under which `agent-browser --help`
yields 'meta'.

---

## 4. The scan — shift-based, NO index counter (avoids the `(( i++ ))` trap)

Use `while (( $# )); do tok="$1"; case "$tok" in …; esac; done` operating on the
FUNCTION's own positional params (`$@`), mutating them with `shift`. This is preferred
over an index `i` because:
- An index loop needs `(( i++ ))` / `(( i += 2 ))`. A bare `(( i++ ))` when the result
  is 0 returns rc 1 and **ABORTS under `set -e`** (see `bash-patterns.md` §1). Avoiding
  the index avoids the trap entirely.
- `shift` is a builtin that returns 0 when it succeeds (the common path); the only rc-1
  case (`shift` with nothing to shift) is shielded by `|| shift` / the `(( $# ))` guard.

### The case arms (in evaluation order — FIRST MATCH WINS)
```
case "$tok" in
    --help|-h|--version)  printf 'meta\n'; return 0 ;;      # short-circuit (§3)
    --session)            shift 2 || shift ;;               # space form: consume flag + VALUE
    --*)                  shift ;;                          # --json, --session=X, --headed, … (1 token)
    -*)                   shift ;;                          # -i -c -d -p -v -q … (1 token; -h handled above)
    *)                    cmd="$1"; next="${2:-}"; break ;; # FIRST non-flag = command; peek next
esac
```

**Ordering rationale:**
- `--help|-h|--version` FIRST — must short-circuit before the generic flag arms.
- `--session` before `--*` — the space form needs `shift 2`; the equals form
  (`--session=X`) falls through to `--*` and shifts 1 (value already attached). Correct.
- `-*` AFTER `-h` — `-h` is caught by the first arm; other short flags shift 1.
- `*)` LAST — the first non-flag token is the command; `break` out, keeping `$1`=cmd and
  `$2`=next for the `session list` lookahead.

**`shift 2 || shift`:** if `--session` is the LAST token (no value), `shift 2` returns
rc 1 (nothing to shift twice); the `|| shift` consumes just `--session`. The `||` makes
the compound errexit-exempt. After that the loop sees `$# == 0`, exits, and `cmd=""` →
'driving' (default).

---

## 5. Classification after the scan

```
# No command found (only flags / empty args) → default driving (contract step d).
[[ -n "$cmd" ]] || { printf 'driving\n'; return 0; }

# Two-word META command: 'session list' (contract step b).
if [[ "$cmd" == session && "$next" == list ]]; then
    printf 'meta\n'; return 0
fi

# Single-word META commands (contract step b).
case "$cmd" in
    skills|dashboard|plugin|mcp) printf 'meta\n'; return 0 ;;
esac

# Everything else → driving (DRIVING set + unrecognized; contract steps c & d).
printf 'driving\n'; return 0
```

**`session list` lookahead** uses `next="${2:-}"` captured at the `*)` arm (the token
immediately after the command). This covers the standard `agent-browser session list`
invocation. `session --json list` (flag between) is NOT expected (agents invoke the
two-word form adjacently) and would classify as 'driving' — harmless (wrapper execs
`session --json list` which lists sessions anyway). Documented edge case.

---

## 6. Return code & stdout discipline

- **return 0 ALWAYS.** There is no failure mode (every input yields 'meta' or
  'driving'). This makes the caller's `class="$(pool_dispatch_classify "$@")"` safe
  under `set -e` with NO guard needed — rc is always 0. (Contrast `pool_lease_find_mine`
  which returns 1 on no-match and REQUIRES an `if` guard.)
- **stdout = EXACTLY one token** ('meta' or 'driving'), via `printf '%s\n'`. Nothing
  else writes stdout (no `_pool_log`, no subcommand echoes). The function reads NO
  globals, writes NO files, calls NO external commands — pure arg parsing.

---

## 7. NO precondition — callable BEFORE pool_config_init / pool_owner_resolve

This is a DESIGN REQUIREMENT, not a side-effect. PRD §2.4 runs dispatch as **step 0**
(BEFORE owner resolution step 1). So the wrapper calls `pool_dispatch_classify "$@"`
FIRST to decide meta-vs-driving, and only if 'driving' does it proceed to owner
resolution + lane acquisition. Therefore:
- Read NO `POOL_*` globals.
- Call NO `pool_config_init` / `pool_owner_resolve`.
- Depend on NOTHING but `"$@"`.

This also makes the function trivially unit-testable (no fixtures, no state dir, no
owner process) — just `source lib/pool.sh; pool_dispatch_classify …`.

---

## 8. Scope boundary — what this task does NOT do

To respect sibling tasks (all "Planned"):
- **NOT** `close --all` interception / `connect` arg normalization → **M6.T1.S2**.
  Here `close` and `connect` simply classify as 'driving'.
- **NOT** `--session` stripping / `AGENT_BROWSER_SESSION=abpool-<N>` forcing → **M6.T2.S1**.
  Here `--session <X>` is only SKIPPED to find the command; it is NOT removed or rewritten.
- **NOT** the lifecycle wiring (resolve → find/acquire → ensure → exec) → **M6.T3.S1**.
- **NOT** the `bin/agent-browser` executable itself → **M6.T3.S2**.

This task ships ONE function (`pool_dispatch_classify`) that echoes 'meta' or 'driving'.
