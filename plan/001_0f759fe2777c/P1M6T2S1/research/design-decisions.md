# Design decisions — P1.M6.T2.S1 (strip `--session` + force `AGENT_BROWSER_SESSION`)

Each decision is justified against the codebase conventions, the PRD contract, and the host-verified
bash semantics in `codebase-internal.md` + `bash-external.md`.

---

## D1 — Two separate functions (not one combined "prepare_exec(lane, args)")

**Decision**: ship `pool_strip_session_args(args...)` AND `pool_force_session(lane)` as two DISTINCT
public functions, not one combined `pool_prepare_exec(lane, args...)`.

**Why**:
- **Single Responsibility + testability.** The strip is a PURE argv transform (reads `"$@"`, writes
  the `POOL_CLEAN_ARGS` global array, return 0 always, no external commands). The force is a SIDE
  EFFECT (mutates the process env, return 0/1). Mixing a pure transform with a side effect in one
  function would make unit testing harder (the strip half would need env cleanup) and would violate
  the codebase pattern where pure argv transforms (classify, M6.T1.S2's normalizers) are isolated.
- **Composability with the lifecycle.** M6.T3.S1 wires the sequence
  `normalize_close → normalize_connect → strip_session → force_session → exec`. Keeping strip and
  force separate lets M6.T3.S1 interleave observability (`_pool_log "forced session abpool-$N"`)
  and makes each step independently replaceable/testable.
- **Mirrors the contract's own decomposition.** The item CONTRACT lists them as two functions (a.
  `pool_strip_session_args`; b. `pool_force_session`). The PRD §2.4 step 5 describes two distinct
  actions ("strip … AND force …"). One function per action is the faithful mapping.

**Rejected alternative**: a single `pool_prepare_exec`. Rejected for the SRP/testability reasons
above and because it would invent an interface not in the contract.

---

## D2 — Output the cleaned argv via a NEW global array `POOL_CLEAN_ARGS` (not stdout, not `POOL_NORM_ARGS`)

**Decision**: `pool_strip_session_args` writes the cleaned argv to `declare -ga POOL_CLEAN_ARGS`,
a NEW global distinct from M6.T1.S2's `POOL_NORM_ARGS`.

**Why**:
- **stdout is unsafe for argv** (M6.T1.S2 research D1, carried here): tokens may contain spaces /
  newlines; newline- or NUL-serialization has edge cases. The global-array idiom is serialization-
  free and ShellCheck-clean. This is now the ESTABLISHED codebase pattern (M6.T1.S2's `POOL_NORM_ARGS`
  sets the precedent; this task's `POOL_CLEAN_ARGS` follows it).
- **Distinct name (`POOL_CLEAN_ARGS` ≠ `POOL_NORM_ARGS`) avoids aliasing.** The pipeline is
  `POOL_NORM_ARGS → (strip --session) → POOL_CLEAN_ARGS → exec`. If both stages wrote the SAME
  global, a reader couldn't tell which stage produced the current value, and calling strip twice
  would be a confusing no-op-vs-mutation. Distinct names make the data flow explicit and let each
  stage be unit-tested in isolation.
- **Self-contained input.** `pool_strip_session_args` reads its own `"$@"` — it does NOT reference
  `POOL_NORM_ARGS` directly. This DECOUPLES this task from the parallel M6.T1.S2 sibling: M6.T3.S1
  will pass `${POOL_NORM_ARGS[@]}` as the args once both siblings land, but the function itself just
  takes args and strips `--session`. (Equivalent to how `pool_normalize_connect` takes `"$@"` and
  M6.T3.S1 passes `${POOL_NORM_ARGS[@]}` from the close stage.)

---

## D3 — `pool_strip_session_args` returns 0 ALWAYS (pure transform, no failure mode)

**Decision**: `pool_strip_session_args` has NO non-zero return path. Every input (including empty,
or args with no `--session`) yields a valid `POOL_CLEAN_ARGS`.

**Why**:
- **Mirrors the established pure-transform contract.** `pool_dispatch_classify` (return 0 always,
  @3083) and M6.T1.S2's `pool_normalize_close`/`connect` (return 0 ALWAYS) set the pattern: argv
  transforms that merely REMOVE tokens have no possible failure. There is nothing to "fail" —
  removing `--session` from an argv that has none is a valid no-op.
- **Caller convenience.** A guaranteed rc 0 means M6.T3.S1 needs no `if pool_strip_session_args …`
  guard (unlike `pool_lease_find_mine` / `pool_force_session` which DO return non-zero and require a
  guard). Keeps the lifecycle sequence flat.

**Contrast with `pool_force_session` (D5)**: the force DOES have a precondition (valid lane number)
and returns 1 on violation. Different idiom for a different kind of operation (pure transform vs
preconditioned side effect).

---

## D4 — Strip BOTH `--session <X>` (space form, 2 tokens) AND `--session=<X>` (equals form, 1 token)

**Decision**: the scan recognizes both forms. Space form drops the flag AND its following value (if
present); equals form drops the single combined token.

**Why**:
- **agent-browser accepts both forms** (`--help`: "`--session <name>`"; the equals form
  `--session=name` is standard getopt-long and agent-browser's commander.js parser accepts it —
  verified live: `agent-browser --session=foo session` prints `foo`). An agent could use either.
- **Trailing `--session` with no value** (e.g. malformed `agent-browser open x --session`): the index
  guard `if (( i+1 < ${#orig[@]} ))` drops just the flag without reading past the array end. (A naive
  `shift 2` at end-of-args would either crash or consume a phantom; the index form is uniform and
  safe.) Verified in codebase-internal §5.
- **Multiple occurrences** (`--session a --session b cmd`): the loop drops EVERY `--session` token
  (and each space-form's value). Correct — we want ZERO `--session` flags in the exec'd argv.

---

## D5 — `pool_force_session` validates the lane and returns 1 (non-fatal) on a bad lane; uses `export`

**Decision**:
```bash
pool_force_session() {
    local lane="${1:-}"
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    export AGENT_BROWSER_SESSION="abpool-$lane"
}
```

**Why**:
- **`export` persists in the calling shell** (functions don't create subshells) and is inherited by
  the later `exec`. Host-verified (codebase-internal §6). A single `export VAR=val` line is the
  canonical, ShellCheck-clean form (no cmd-sub → no SC2155).
- **Validate lane** (`^[0-9]+$`): a non-numeric/empty lane would export a broken
  `AGENT_BROWSER_SESSION=abpool-` (or `abpool-foo`) that the daemon would treat as a NEW session,
  silently breaking lane binding. Validating prevents that. `return 1` (NOT `pool_die`) follows the
  non-fatal rc-0/rc-1 family (pool_daemon_connect, pool_daemon_connected): the caller (M6.T3.S1)
  owns the policy — on rc 1 it should NOT exec (do no harm; surface the error).
- **Do-no-harm on failure**: on rc 1, we return WITHOUT exporting, leaving any prior
  `AGENT_BROWSER_SESSION` untouched. This is the safest posture (no half-mutation).
- **Why NOT `unset` then `export`**: the contract says "strip … AGENT_BROWSER_SESSION." For the env
  var, strip+force collapses to one `export` (the assignment OVERWRITES the inherited value). An
  `unset`+`export` would be a redundant no-op. One `export` line is minimal and correct.

---

## D6 — Do NOT strip `--session-name` / `AGENT_BROWSER_SESSION_NAME`

**Decision**: only `--session` / `--session=<X>` are stripped; only `AGENT_BROWSER_SESSION` is
forced. `--session-name` and `AGENT_BROWSER_SESSION_NAME` are left UNTOUCHED.

**Why**:
- **`--session-name` is a DIFFERENT feature** (bash-external §6): auto-save/restore of cookies +
  localStorage persistence. It is NOT a lane-escape hatch (it doesn't control the daemon session /
  Chrome binding). Stripping it would silently disable a legitimate agent capability.
- **Scope discipline.** The contract (item CONTRACT + external_deps §1.3) names ONLY `--session` /
  `AGENT_BROWSER_SESSION`. Expanding scope to `--session-name` would be an undocumented behavior
  change and could break agents that rely on state persistence.

---

## D7 — Placement: append at EOF under a NEW `# Wrapper shim — session override (P1.M6.T2.S1)` banner

**Decision**: append the two functions under a new banner at EOF of `lib/pool.sh`, after whatever
is currently last (M6.T1.S1's `pool_dispatch_classify` @3030–3086, and — if it lands first —
M6.T1.S2's normalizers).

**Why**:
- **Pure append, no existing function touched** — matches the M6.T1.S1 / M6.T1.S2 pattern (each
  wrapper-shim subtask adds its own banner section at EOF).
- **Banner makes it self-locating** (`grep -n 'Wrapper shim' lib/pool.sh` shows each subtask's
  section). Avoids any collision with the parallel M6.T1.S2 append: whichever lands second simply
  appends after the other's closing brace. The functions are independent (no shared helpers), so
  order does not matter.
- **Naming**: `pool_strip_session_args` / `pool_force_session` (public, no `_`, `pool_*` family).
  Global: `POOL_CLEAN_ARGS` (array, OUTPUT-only).

---

## D8 — Boundary vs siblings (what this task does NOT do)

- Does NOT classify (M6.T1.S1) — the functions are unconditional transforms; M6.T3.S1 decides
  whether to call them (DRIVING only; META/passthrough execs unchanged per PRD §2.4 step 0).
- Does NOT normalize close/connect (M6.T1.S2) — this task runs AFTER normalize in the pipeline and
  consumes `${POOL_NORM_ARGS[@]}` (passed by M6.T3.S1) as its input args.
- Does NOT wire the lifecycle or `exec` (M6.T3.S1) — ships the two functions only.
- Does NOT touch `--session-name` (D6).
- Does NOT decide how a bare/stripped argv is exec'd (e.g. the M6.T1.S2 note that bare `connect`
  errors exit 1 — that's M6.T3.S1's concern). This task just strips `--session`.

---

## Composition sketch (for M6.T3.S1 — NOT built here)

```bash
# M6.T3.S1 lifecycle (DRIVING path), after acquire + ensure_connected:
pool_normalize_close  "$@"                          # M6.T1.S2 → POOL_NORM_ARGS (+ POOL_CLOSE_ALL_SEEN)
pool_normalize_connect "${POOL_NORM_ARGS[@]}"       # M6.T1.S2 → POOL_NORM_ARGS
pool_strip_session_args "${POOL_NORM_ARGS[@]}"      # THIS TASK → POOL_CLEAN_ARGS (no --session)
if ! pool_force_session "$N"; then                  # THIS TASK → exports AGENT_BROWSER_SESSION=abpool-$N
    _pool_log "pool_force_session: bad lane '$N'; aborting exec"; exit 1
fi
[[ "$POOL_CLOSE_ALL_SEEN" == 1 ]] && _pool_log "intercepted close --all → scoped to lane $N"
exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"       # env session forced; argv cleaned
```

The `exec` inherits `AGENT_BROWSER_SESSION=abpool-$N` (exported by `pool_force_session`) and receives
the `--session`-free argv. Because the flag is stripped, the env var is the SOLE session source → the
agent cannot bypass its lane. (Precedence verified: flag wins over env, so BOTH strip+force are
required — codebase-internal §1.)
