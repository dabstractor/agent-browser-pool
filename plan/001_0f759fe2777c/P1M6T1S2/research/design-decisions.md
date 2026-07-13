# Design Decisions — P1.M6.T1.S2 (close --all interception + connect arg normalization)

Synthesizes `codebase-internal.md` + `bash-external.md` into the concrete choices the PRP
codifies. Read alongside those two reports.

## D1. Output channel — GLOBAL ARRAY `POOL_NORM_ARGS` (+ scalar `POOL_CLOSE_ALL_SEEN`)

**Decision:** both functions write the normalized argv to a NEW global array
`POOL_NORM_ARGS` (set via `declare -ga POOL_NORM_ARGS=( "${out[@]}" )`, the canonical
single-statement form). `pool_normalize_close` additionally sets a scalar global
`POOL_CLOSE_ALL_SEEN` (0/1) — the contract's literal "set a flag."

**Rejected alternatives:**
- *stdout echo (newline-separated, like pool_lanes_list)* — UNSAFE: agent-browser argv can
  contain spaces/newlines (URLs, `type` payloads). `$( )` capture also loses trailing
  newlines. pool_lanes_list only ever echoes simple integer tokens.
- *stdout NUL-separated + `mapfile -d '' -t`* — robust but would be the codebase's FIRST
  `mapfile -d ''` (0 today), has the empty-`printf`-emits-one-NUL edge (must guard), and
  crosses a process-substitution boundary (failure inside `<(...)` is invisible).
- *nameref (`local -n`)* — cleanest in the abstract, but 0 precedent in this codebase and
  risks SC2178/disable churn; the scalar-global return convention is already established.

**Rationale:** the codebase returns multi-values via `declare -g` globals (POOL_CHROME_PID @1514,
POOL_CHROME_PGID @1528, ~27 `declare -g` total; 0 nameref, 0 `mapfile -d`). Extending that to
`declare -ga` for an ARRAY is the minimal, consistent, serialization-free choice. The only
footgun (caller `local`-shadowing a `-g` global → silent empty) is NOT a risk here because the
sole consumer (M6.T3.S1 lifecycle) reads `POOL_NORM_ARGS` at the top-level wrapper scope, not
inside a function that locals it. (bash-external §1a Finding 3.)

## D2. Command detection — MIRROR `pool_dispatch_classify`'s scan EXACTLY

**Decision:** reuse classify's proven flag-scan idiom (shift/i+= semantics):
`--session` → consume 2 (`shift 2 || shift` / `i=$((i+2))`); `--session=*` and any other
`--*` and any `-*` → consume 1; first non-flag token = COMMAND.

**Why mirror (not a more precise value-flag enumeration):** normalize runs ONLY after classify
returned `'driving'`. Using the IDENTICAL scan guarantees normalize locates the SAME command
token classify did → they can never disagree about what the command is. The scout flagged that
many agent-browser flags take values (--cdp, --state, --executable-path, …) which classify's
"all `--*` ⇒ shift-1" shortcut mis-handles; BUT for the close/connect SAFETY contract this is
harmless: under the mirrored scan a real `close`/`connect` token is NEVER consumed as a flag's
value (value-flags are treated as bools → their would-be value becomes the next token, i.e. the
command). Concretely `agent-browser --cdp close --all` → scan shifts `--cdp`, finds `close` ⇒
strips `--all` ⇒ SAFE (no peer nuke). The only theoretical miss needs a value-flag whose VALUE
is literally `close`/`connect` AND a trailing `--all` — contrived beyond any skill-taught usage,
and even then degrades to a harmless passthrough/strip. Documented as an accepted, safe
limitation. (codebase-internal §3.)

## D3. Two self-gating functions; compose via SEQUENTIAL calls

**Decision:** `pool_normalize_close` and `pool_normalize_connect` are each SELF-GATING:
each scans to find the command; if it is NOT `close` (resp. `connect`), `POOL_NORM_ARGS` is
set to the args UNCHANGED (no-op). Because an invocation has exactly ONE command, at most one
of them ever mutates the args. The lifecycle composes them by calling both in order:

```bash
pool_normalize_close  "$@"                          # sets POOL_NORM_ARGS  (close handled)
pool_normalize_connect "${POOL_NORM_ARGS[@]}"       # re-sets POOL_NORM_ARGS (connect handled)
exec "$REAL" ... "${POOL_NORM_ARGS[@]}"             # (M6.T3.S1 wires the real exec + session)
```

For a `connect 9222` call: close is a no-op (cmd≠close ⇒ POOL_NORM_ARGS=orig); connect then
strips `9222`. For `close --all`: close strips `--all`; connect is a no-op (cmd still `close`).
For `open <url>`: both no-ops. All cases correct. (bash-external §1c Finding 9.)

## D4. close — strip EVERY standalone `--all` iff command==close

If cmd==`close`, rebuild `POOL_NORM_ARGS` = args minus every token whose value is exactly
`--all` (handles `close --all --all`); set `POOL_CLOSE_ALL_SEEN=1` if any was removed (else 0).
If cmd≠`close`, args unchanged (so `find role x --all` keeps its `--all` — it is NOT a close
flag here). `--json`/`--session`/etc. are PRESERVED (M6.T2.S1 strips --session later). The
ACTUAL "close only my session" scoping is achieved by stripping `--all` (here) + forcing
`--session abpool-<N>` (M6.T2.S1); `POOL_CLOSE_ALL_SEEN` is the observability hook for PRD §2.15.

## D5. connect — strip the FIRST non-flag positional AFTER `connect`

If cmd==`connect`, continue scanning past the command; the FIRST non-flag token (the
`<port|url>`) is the one positional to drop (skip flags incl. `--session`'s value). PRESERVE
`--json` and `--session <X>` (M6.T2.S1's job). Bare `connect` (no positional) ⇒ nothing to
strip ⇒ unchanged. (external_deps §1.3.)

## D6. CRITICAL integration risk — bare `connect` is a runtime ERROR (exit 1)

Host-verified: `agent-browser connect` (no arg) → "Missing arguments for: connect …" exit 1
(connect --help shows `<port|url>` REQUIRED). After D5 strips the arg, the result is bare
`connect`. PRD §2.4 step 4 (ensure_connected) ALREADY binds the lane's daemon to the lane's
Chrome, so the agent's `connect <port>` is semantically absorbed. **M6.T3.S1 must NOT naively
exec a bare connect** (the agent would see an error → breaks the §2.15 transparency contract).
Likely lifecycle behavior: for `connect`, ensure_connected (step 4) is the real work; the final
exec is either skipped, or run with failure tolerated. **This task strips the arg per the item
contract; it does NOT decide how the bare result is exec'd** (that is M6.T3.S1). Flagged
prominently in the PRP as a handoff.

## D7. Return 0 ALWAYS; pure (no _pool_log, no files, no external cmds)

Both functions return 0 unconditionally (pure argv transform; no failure mode) — mirrors
`pool_dispatch_classify`. The ONLY writes are the two globals. No `_pool_log` (keeps them
trivially unit-testable with zero fixtures, like classify). set-e safety per bash-external §2:
`while (( ))` / `if (( ))` conditions are exempt; `i=$((i+1))` assignment is always rc 0; no
bare `(( i++ ))`; `shift 2 || shift` non-last-member exempt.

## D8. Placement & naming

Append a NEW banner `# Wrapper shim — arg normalization (P1.M6.T1.S2)` at EOF of lib/pool.sh
(after `pool_dispatch_classify`, currently line 3086). Public names `pool_normalize_close` /
`pool_normalize_connect` (no `_` prefix) join the `pool_*` family. NO new env vars consumed
(functions read only `"$@"`); the two globals are OUTPUT-only contracts. Pure append — no edits
to any existing function.
