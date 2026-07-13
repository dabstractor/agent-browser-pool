# External/bash research — P1.M6.T2.S1

Host: bash 5.2.21, ShellCheck 0.11.0. All snippets run under `set -euo pipefail`.

## §1. Global-array return via `declare -ga` (the argv-safe output channel)

An argv array cannot go on stdout (tokens may contain spaces, newlines, or `|`). The codebase's
return-via-`declare -g` scalar idiom (pool_chrome_launch @1514 `POOL_CHROME_PID=$!; declare -g
POOL_CHROME_PID`) extends to arrays:

```bash
declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )
```

- `declare -ga NAME=( ... )` declares NAME as a GLOBAL array and assigns it atomically in one
  statement. The `-g` is REQUIRED inside a function (otherwise `declare -a` would create a LOCAL).
- When `out` is EMPTY, `"${out[@]}"` expands to nothing → the assignment becomes
  `declare -ga POOL_CLEAN_ARGS=()` → `${#POOL_CLEAN_ARGS[@]} == 0`. Host-verified: NO spurious
  empty element (unlike `printf '%s\0' "${a[@]}"` which emits one NUL for an empty array — but we
  do NOT use stdout serialization).
- ShellCheck-clean (SC2155 only flags `local x="$(cmd)"` masking cmd-sub status; an array literal
  with no cmd-sub is clean).
- The caller reads `"${POOL_CLEAN_ARGS[@]}"`.

References: BashFAQ 024 (variables set in a subshell don't propagate — which is WHY we use a global,
not `$(...)` capture); `help declare` (`-g` = global).

## §2. The `(( ))` trap under `set -e`

- A bare `(( expr ))` STATEMENT whose result is 0 returns exit status 1 → ABORT under `set -e`.
- `(( ))` inside `if`/`elif`/`while`/`until` CONDITIONS is errexit-exempt.
- The `$(( ))` arithmetic EXPANSION is always safe (it's a substitution, not a command).
- `i=$((i+1))` is an ASSIGNMENT using `$(( ))` — always rc 0. Use this, never `(( i++ ))`.

The codebase documents this in-place at lib/pool.sh:360-365 (the `_pool_age_str` GOTCHA).

## §3. Index-based rebuild-drop loop (strip while preserving order)

To drop specific tokens from a positional-args snapshot while keeping everything else in order:

```bash
local -a orig=("$@") out=()     # snapshot $@; pre-declare out (set -u safe on empty)
local i=0 tok
while (( i < ${#orig[@]} )); do
    tok="${orig[i]}"
    case "$tok" in
        --session)
            if (( i+1 < ${#orig[@]} )); then i=$((i+2)); else i=$((i+1)); fi ;;
        --session=*)
            i=$((i+1)) ;;
        *)
            out+=("$tok"); i=$((i+1)) ;;
    esac
done
declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )
```

- `local -a orig=("$@")` snapshots positional params so we can scan AND rebuild from the original.
- `out+=("$tok")` appends one element; quoting `"$tok"` preserves embedded spaces/newlines.
- The `if (( i+1 < ${#orig[@]} ))` guard makes `--session` at end-of-array safe (no read past end).
- Host-verified matrix in codebase-internal.md §5.

## §4. Env export from a function, inherited by a later `exec`

```bash
pool_force_session() {
    local lane="${1:-}"
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1     # non-fatal precondition check
    export AGENT_BROWSER_SESSION="abpool-$lane"
}
```

- A function call (no `$(...)`, no pipe) runs in the CALLING shell. `export VAR=val` inside it
  mutates the calling shell's env and PERSISTS after the function returns.
- The env is then inherited by any subsequent `exec "$binary"` in the same shell (exec replaces the
  process image but keeps the env unless explicitly cleared).
- Host-verified: after `pool_force_session 7`, both `$AGENT_BROWSER_SESSION` in the shell and
  `bash -c 'echo $AGENT_BROWSER_SESSION'` (child) print `abpool-7`.
- `export VAR="literal$var"` is ShellCheck-clean (no cmd-sub → no SC2155 status masking).
- Under `set -u`, `${1:-}` provides a safe default (empty) if called with no arg; the regex check
  then returns 1. Returning 1 (not `pool_die`) is the non-fatal family idiom
  (pool_daemon_connect @1630, pool_daemon_connected @1680).

References: BashFAQ 024; `help export`; POSIX execve (env inherited across exec unless reset).

## §5. Why strip `--session` at all (given we force the env)?

Host-verified precedence (agent-browser 0.28.0): the `--session <name>` FLAG takes precedence over
the `AGENT_BROWSER_SESSION` env var. Concretely:

```
$ AGENT_BROWSER_SESSION=env-x agent-browser --session flag-x session
flag-x      # flag wins
```

So if an agent passes `--session mysession`, merely forcing the env is insufficient — the agent's
flag would still route it to `mysession`, bypassing its lane. The contract (PRD §2.4 step 5,
external_deps §1.3) therefore requires BOTH: strip the flag (so the env is the sole source) AND
force the env (to `abpool-<N>`). This is the load-bearing correctness fact of the task.

## §6. What `--session-name` is (and why we do NOT strip it)

agent-browser has a SEPARATE flag `--session-name <name>` (and env `AGENT_BROWSER_SESSION_NAME`)
for auto-save/restore of cookies + localStorage — a DIFFERENT feature from `--session` (the daemon
session / Chrome binding). The pool only needs to control the DAEMON SESSION (`--session` /
`AGENT_BROWSER_SESSION`); `--session-name` is about persistent state and is NOT a lane-escape hatch.
Stripping it would silently disable a legitimate agent feature. So this task strips ONLY
`--session` / `--session=<X>` and leaves `--session-name` / `AGENT_BROWSER_SESSION_NAME` untouched.
(`--help` confirms the two are distinct options.)
