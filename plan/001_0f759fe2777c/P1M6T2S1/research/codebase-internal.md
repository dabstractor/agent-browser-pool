# Codebase-internal research — P1.M6.T2.S1 (strip `--session` + force `AGENT_BROWSER_SESSION`)

Scope: the two wrapper-shim functions `pool_strip_session_args(args...)` and
`pool_force_session(lane)` appended to `lib/pool.sh`. Pure argv/env rewrite consumed by
the lifecycle exec step (M6.T3.S1). All findings are host-verified on this machine
(bash 5.2.21, ShellCheck 0.11.0, agent-browser 0.28.0).

---

## §1. The contract — PRD §2.4 step 5 + §2.15 + external_deps §1.3

PRD §2.4 step 5 (the wrapper's final EXEC step):

> EXEC real binary with `AGENT_BROWSER_SESSION=abpool-<N>` forced + original args.
> Strip any inherited `--session` / `AGENT_BROWSER_SESSION` so the agent can't bypass its lane.

PRD §2.4 "Transparent absorption" bullet:

> `agent-browser --session <X> …` → **override** to `abpool-<N>`.

external_deps.md §1.3 table (lines 48–49):

| Agent Invocation | Wrapper Behavior |
|---|---|
| `agent-browser --session <X> <cmd>` | **Override** `--session` to `abpool-<N>`. Strip the agent's `--session` flag. |
| `AGENT_BROWSER_SESSION=<X> agent-browser <cmd>` | **Override** env to `abpool-<N>`. |

So there are TWO agent escape hatches that must be neutralized:

1. The **`--session <X>` flag** (the upstream skill teaches `agent-browser --session <name> …`).
2. An **inherited `AGENT_BROWSER_SESSION=<X>` env var** (a parent shell could export it).

This task ships BOTH halves of the neutralization:

- `pool_strip_session_args(args...)` — removes `--session <X>` and `--session=<X>` from argv.
- `pool_force_session(lane)` — exports `AGENT_BROWSER_SESSION=abpool-<lane>`.

### HOST-VERIFIED precedence: the `--session` flag WINS over the env var

Decisive live test on this host (agent-browser 0.28.0):

```
$ AGENT_BROWSER_SESSION=env-test agent-browser session
env-test
$ agent-browser --session flag-test session
flag-test
$ AGENT_BROWSER_SESSION=env-test agent-browser --session flag-test session
flag-test        # <-- the FLAG wins over the env var
```

`--help` confirms the contract: "`--session <name>`  Isolated session (or AGENT_BROWSER_SESSION env)".
The env var is the FALLBACK when the flag is absent. Therefore:

- Stripping the flag alone is NOT enough (an inherited env var would still win once the flag is gone).
- Setting the env var alone is NOT enough (a `--session` flag would still override it).
- **BOTH are required** to force `abpool-<N>`. This is exactly the contract's "strip … AND force …".

This is the single most important correctness fact for this task.

---

## §2. Where this task sits in the lifecycle + sibling boundaries

PRD §2.4 lifecycle (relevant steps, for orientation):

```
0. dispatch_classify  → 'meta' (passthrough) | 'driving'      [M6.T1.S1, LANDED @3030]
1. owner_resolve                                                    [M2, LANDED]
2. find_my_lease                                                    [M3.T2.S1, LANDED]
3. acquire_locked (reap/orphan/choose/claim → boot)                [M5.T1, LANDED]
4. ensure_connected                                                 [M5.T1.S3, LANDED]
   ── after the above, for DRIVING invocations, the wrapper normalizes + execs: ──
   pool_normalize_close  "$@"                                       [M6.T1.S2, parallel sibling]
   pool_normalize_connect "${POOL_NORM_ARGS[@]}"                    [M6.T1.S2, parallel sibling]
   pool_strip_session_args "${POOL_NORM_ARGS[@]}"                   [THIS TASK — M6.T2.S1]
   pool_force_session "$N"                                          [THIS TASK — M6.T2.S1]
   exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"                    [M6.T3.S1 — NOT this task]
```

### Boundary vs M6.T1.S2 (the parallel sibling — `pool_normalize_close` / `pool_normalize_connect`)

M6.T1.S2 ships two argv rewriters whose OUTPUT channel is the global array **`POOL_NORM_ARGS`**
(`declare -ga`). They handle `close --all` (strip `--all`) and `connect <port>` (strip the
positional). They deliberately **do NOT touch `--session`** — their PRP's GOTCHA + scope notes say
"`--session` is PRESERVED for M6.T2.S1 to strip/override." The handoff is explicit:

> `--session` is NOT touched by either function — it is preserved for M6.T2.S1 to strip/override.
> Here `--session <X>` is only SKIPPED (its value consumed) during the command/positional scan.

So THIS task consumes `${POOL_NORM_ARGS[@]}` (the M6.T1.S2 output) as its INPUT, strips `--session`
from it, and emits a NEW global array **`POOL_CLEAN_ARGS`**. Different name ⇒ no aliasing; the
pipeline is `POOL_NORM_ARGS → (strip --session) → POOL_CLEAN_ARGS → exec`.

> NOTE: because M6.T1.S2 runs in parallel, its `POOL_NORM_ARGS` may or may not exist yet at the
> moment M6.T3.S1 wires the lifecycle. THIS task is self-contained: `pool_strip_session_args`
> reads its own `"$@"` (M6.T3.S1 will pass `${POOL_NORM_ARGS[@]}` once both siblings land). The
> function does NOT reference `POOL_NORM_ARGS` directly — it just takes args and emits
> `POOL_CLEAN_ARGS`. That decouples the two siblings cleanly.

### Boundary vs M6.T3.S1 (lifecycle exec — NOT this task)

This task ships the two transform functions only. It does NOT:
- decide WHEN to call them (M6.T3.S1 wires the sequence above);
- perform the `exec` (M6.T3.S1);
- touch META/passthrough invocations (those exec the real binary UNCHANGED — no strip, no force;
  PRD §2.4 step 0 "exec real binary unchanged"). The strip/force is ONLY for DRIVING invocations,
  but THAT decision is M6.T3.S1's (based on `pool_dispatch_classify`). The functions themselves are
  unconditional pure transforms.

---

## §3. The scan idiom to reuse (mirror `pool_dispatch_classify` / M6.T1.S2)

The codebase has a canonical flag-scan idiom, used identically by `pool_dispatch_classify`
(@3035, LANDED) and (per its PRP) by M6.T1.S2's two normalizers. THIS task uses the SAME scan to
locate `--session` tokens. The exact case-arms (from `pool_dispatch_classify` @3038–3053):

```bash
case "$tok" in
    --session)   shift 2 || shift ;;   # space form: flag + value (|| shift tolerates trailing)
    --session=*) shift ;;              # equals form: value attached
    --*)         shift ;;              # other long flag (--json, --headed, …)
    -*)          shift ;;              # short flags
    *)           cmd="$1"; break ;;    # first non-flag = command
esac
```

For `pool_strip_session_args` we want an **index-based** loop (not `shift`, because we rebuild the
cleaned array from the original) that DROPS `--session`/`--session=<X>` and KEEPS everything else.
Verified pattern (host-tested in §5):

```bash
local -a orig=("$@") out=()
local i=0 tok
while (( i < ${#orig[@]} )); do
    tok="${orig[i]}"
    case "$tok" in
        --session)
            # space form: drop flag + its value (if a next token exists)
            if (( i+1 < ${#orig[@]} )); then i=$((i+2)); else i=$((i+1)); fi ;;
        --session=*)
            i=$((i+1)) ;;                       # equals form: single token
        *)
            out+=("$tok"); i=$((i+1)) ;;        # KEEP everything else
    esac
done
declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )
```

This is the minimal, faithful extension of the codebase scan. NOTE a key difference from M6.T1.S2's
normalizers: they KEEP `--session` (only skip its value during the scan); THIS task DROPS it. Both
are correct for their respective contracts.

---

## §4. The `(( ))` / set -e trap (lib/pool.sh:360-365)

The codebase documents in-place the bare-`(( expr ))` trap:

> A bare `(( expr ))` as a STATEMENT returns exit status 1 when the result is 0 — FATAL under
> set -e. EVERY `(( ))` here is inside `if`/`elif`/`while` (exempt from errexit). The `$(( ))`
> EXPANSION form is always safe.

Concretely for this task:

- ✅ `while (( i < ${#orig[@]} ))` — loop CONDITION, errexit-exempt (prior art: classify @3035).
- ✅ `if (( i+1 < ${#orig[@]} ))` — if-CONDITION, errexit-exempt.
- ✅ `i=$((i+1))` / `i=$((i+2))` — ASSIGNMENT via `$(( ))` expansion, always rc 0.
- ❌ NEVER `(( i++ ))` — returns rc 1 when `i==0` → ABORT under set -e.

This is identical to the convention M6.T1.S2 follows.

---

## §5. Host-verified behavior matrix for the strip pattern

Ran the exact `pool_strip_session_args` body from §3 under `set -euo pipefail` (bash 5.2.21).
Output shown as `POOL_CLEAN_ARGS` joined with `|`:

| input args | POOL_CLEAN_ARGS | rule |
|---|---|---|
| `--session foo bar` | `bar` | space form: drop flag + value |
| `--session=foo bar` | `bar` | equals form: drop single token |
| `bar --session foo baz` | `bar\|baz` | mid-list, both dropped |
| `--json --session foo open https://x` | `--json\|open\|https://x` | preserve other flags |
| `open https://x` | `open\|https://x` | no --session → unchanged |
| `--session` (trailing, no value) | *(empty)* | drop just the flag; no rc-1 crash |
| *(no args)* | *(empty)* | empty in → empty out |
| `type '#q' 'two words'` | `type\|#q\|two words` | **spaces preserved** (the whole point of global-array return) |
| `--session foo --session=bar baz` | `baz` | both forms in one argv |
| `--session foo --session bar baz` | `baz` | two space-form occurrences |

**Empty-array edge case**: after a no-arg call, `declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )` yields
`${#POOL_CLEAN_ARGS[@]} == 0` — **NO spurious empty element**. (Verified: the count prints `0`.)
This contradicts the M6.T1.S2 research note about `printf '%s\0' "${a[@]}"` emitting a spurious NUL
on an empty array — but that note is about the STDOUT-serialization path, which THIS task does NOT
use. The global-array `declare -ga NAME=( "${out[@]}" )` form is clean for empty arrays (bash
expands `"${out[@]}"` to nothing when `out` is empty, so the assignment is `declare -ga NAME=()`).

---

## §6. Env-var export — host-verified propagation to `exec`

The contract: `pool_force_session(lane)` must export `AGENT_BROWSER_SESSION=abpool-<lane>` so the
env var is inherited by the `exec "$POOL_REAL_BIN" …` that M6.T3.S1 runs LATER in the same shell.

Host-verified behavior:

```bash
pool_force_session() { export AGENT_BROWSER_SESSION="abpool-$1"; }
pool_force_session 7
echo "$AGENT_BROWSER_SESSION"           # → abpool-7   (visible in calling shell)
bash -c 'echo "$AGENT_BROWSER_SESSION"' # → abpool-7   (inherited by child = exec'd binary)
```

Key facts:

1. **Functions do NOT create subshells.** A bare function call (no `$(...)`, no pipe) mutates the
   CALLING shell's environment. So `export VAR=val` inside `pool_force_session` persists in the
   wrapper's shell and is inherited by the subsequent `exec`. (Contrast: `VAR=val func` would scope
   the var to `func` only; `export` inside the function is the correct, persistent form.)
2. **`export VAR=val` (single statement)** is the canonical, ShellCheck-clean form. The split
   `VAR=val; export VAR` is equivalent but more verbose; the codebase uses both — e.g. the
   `declare -g` return idiom (pool_chrome_launch @1514) uses the split form for SCALARS that are
   read-back-by-name, but for a plain env export `export VAR=val` is preferred (SC2155 only bites
   when masking a command-substitution exit status; `export VAR="literal$var"` has no cmd-sub).
3. **Under `set -e`**: `export AGENT_BROWSER_SESSION="abpool-$1"` is always rc 0 (assignment +
   export). No guard needed. The only failure mode is a missing arg (`$1` empty under `set -u`),
   which is a precondition violation — validate `[[ "$1" =~ ^[0-9]+$ ]]` first and `return 1`
   (non-fatal; the caller M6.T3.S1 already has the lane number from the lease, so a bad lane is a
   genuine error worth surfacing — but we do NOT `pool_die`; return 1 and let the caller decide).

### Why NOT also `unset` a pre-existing `AGENT_BROWSER_SESSION` first

The contract says "Strip any inherited `--session` / `AGENT_BROWSER_SESSION`." For the env var,
"strip" + "force" collapses to a single `export AGENT_BROWSER_SESSION=abpool-<N>`: the assignment
OVERWRITES whatever was inherited. An `unset` immediately followed by an `export` would be a no-op
extra step (the export re-creates it). So `pool_force_session` = one `export` line. (If the lane
arg is invalid, we `return 1` WITHOUT exporting — leaving any prior env untouched, which is the
safest "do no harm" posture; M6.T3.S1 would then not exec.)

---

## §7. Return-convention census (consistency with the codebase)

- **`pool_strip_session_args`** → returns the cleaned argv via the global array **`POOL_CLEAN_ARGS`**
  (`declare -ga`). This is the SAME idiom M6.T1.S2 uses for `POOL_NORM_ARGS` — an argv ARRAY cannot
  safely go on stdout (spaces/newlines). **return 0 ALWAYS** (pure transform, no failure mode),
  mirroring `pool_dispatch_classify`'s "return 0 always" and M6.T1.S2's "return 0 ALWAYS."
- **`pool_force_session`** → returns 0 on success (env exported) or 1 on a bad lane arg
  (precondition violation; non-fatal, never `pool_die`). This matches the NON-FATAL rc-0/rc-1
  family (`pool_daemon_connect`, `pool_daemon_connected`, `pool_wait_for_lane`) where the caller
  owns the policy. A non-zero return is appropriate HERE (unlike the pure strip) because the env
  force has a real precondition (a valid lane number); returning 1 lets M6.T3.S1 decide not to exec
  rather than silently exporting a broken `abpool-`.

### Naming

- `pool_strip_session_args` — public, no `_` prefix, `pool_*` family. Mirrors M6.T1.S2's
  `pool_normalize_close` / `pool_normalize_connect` (action-verb prefix).
- `pool_force_session` — public, no `_` prefix. "force" matches the contract's verb ("force
  `AGENT_BROWSER_SESSION=abpool-<N>`") and the PRD's "forced" (§2.4 step 5).
- Globals: `POOL_CLEAN_ARGS` (array, OUTPUT-only — never read by these functions). Distinct from
  M6.T1.S2's `POOL_NORM_ARGS` so the pipeline stages don't alias.

---

## §8. Placement + shellcheck baseline

- **Append point**: EOF of `lib/pool.sh`, currently line 3086 (closing brace of
  `pool_dispatch_classify`). M6.T1.S2 (parallel) appends `pool_normalize_close`/`connect` AFTER
  that. To avoid a placement collision with the parallel sibling, THIS task appends under its OWN
  NEW banner `# Wrapper shim — session override (P1.M6.T2.S1)`. Since both are pure appends at EOF
  and the orchestrator runs them in sequence (not literally simultaneously editing the same bytes),
  the second-to-land simply appends after whatever is currently last. The banner makes each
  task's contribution self-locating (`grep -n 'Wrapper shim' lib/pool.sh`).
- **shellcheck baseline**: the file is 100% clean today (`shellcheck -s bash lib/pool.sh` → zero
  warnings; SC2034 disables only @124/@1569). This task must add ZERO net warnings. Avoid SC2155
  (no cmd-sub masking — `export VAR="literal$1"` is clean; the array literal
  `declare -ga X=( "${out[@]}" )` has no cmd-sub). Avoid SC2086 (quote `"$1"`, `"${orig[@]}"`,
  `"${out[@]}"`). Avoid SC2178/SC2128 (always `"${arr[@]}"`, never `$arr`).

---

## §9. GOTCHA summary (carried into the PRP)

- **CRITICAL — `--session` flag WINS over env** (host-verified §1). Both strip AND force are
  required. Neither alone suffices.
- **CRITICAL — OUTPUT is the GLOBAL ARRAY `POOL_CLEAN_ARGS`**, not stdout (argv may contain
  spaces/newlines). stdout stays EMPTY.
- **CRITICAL — `export` inside the function persists in the calling shell** (no subshell) and is
  inherited by the later `exec`. `export VAR=val` is the single canonical line.
- **CRITICAL — the `(( i++ ))` trap** (lib/pool.sh:360-365): use `i=$((i+1))` (assignment, rc 0);
  only `while (( ))` / `if (( ))` CONDITIONS are used (errexit-exempt).
- **GOTCHA — `--session` with NO trailing value** (`... --session`): drop just the flag, do not
  read past the end of the array. The `if (( i+1 < ${#orig[@]} ))` guard handles it (no crash,
  unlike a naive `shift 2` at end-of-args — though `shift 2 || shift` would also work, the index
  form is uniform with the rebuild loop).
- **GOTCHA — empty-array `declare -ga` is clean** (§5): no spurious element. Safe to call with no
  args.
- **GOTCHA — `pool_force_session` validates lane** (`^[0-9]+$`): returns 1 (non-fatal) on a bad
  lane WITHOUT exporting (do-no-harm). The caller (M6.T3.S1) owns the policy.
- **GOTCHA — boundary**: does NOT classify (M6.T1.S1), normalize close/connect (M6.T1.S2), wire the
  lifecycle (M6.T3.S1), or `exec` (M6.T3.S1). Pure transforms + one env export.
- **GOTCHA — passthrough is NOT this task's concern**: META invocations exec the real binary
  UNCHANGED (no strip/force) per PRD §2.4 step 0. But that decision is M6.T3.S1's (based on
  `pool_dispatch_classify`). These functions are unconditional; M6.T3.S1 simply does not call them
  on the META path.
