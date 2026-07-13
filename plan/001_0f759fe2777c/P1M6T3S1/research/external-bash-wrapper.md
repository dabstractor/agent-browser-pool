# Research: Bash best practices for a sourced-library `main` wrapper that ends in `exec`

> **Scope:** `pool_wrapper_main()` in `lib/pool.sh` (sourced by `bin/agent-browser`).
> It orchestrates config init → state init → dispatch → owner resolve → lease
> find/acquire → boot → ensure-connected → arg normalization → session strip/force →
> `exec "$POOL_REAL_BIN" "$@"`.
>
> **Method note:** `web_search` was not available in this toolset, so the findings
> below rest on (a) the canonical, stable reference URLs cited inline — the GNU Bash
> Reference Manual, Greg's Wiki (BashFAQ), POSIX, `man7.org` man pages, and the
> upstream project repos — and (b) the actual `lib/pool.sh` / `PRD.md` in this repo,
> which were read in full. The bash semantics here are well-established and the URLs
> are long-lived reference pages; see **Gaps** for what live verification could add.

---

## Summary

`exec program args` **replaces** the current shell process image (same PID, same open
file descriptors, same environment) and never returns on success; an `export`-ed
variable like `AGENT_BROWSER_SESSION` set before `exec` is therefore inherited by the
exec'd binary. In a **sourced** library, `return` returns to the caller while `exit`
terminates the whole process — for `pool_wrapper_main` the success path is terminal
(it ends in `exec`, so there is nothing to return to) and the error path uses
`pool_die`→`exit 1`, which is exactly right. The two highest-leverage hazards are:
**(1)** a shim that is itself a symlink must resolve itself with `readlink -f` /
`realpath` *before* computing the relative path to `lib/pool.sh` (a bare
`dirname "$0"` points at the symlink's directory, not the repo); and **(2)** under
`set -euo pipefail`, every function that *intentionally* returns non-zero (e.g.
`pool_lease_find_mine` → 1 on no-match) must be called in an errexit-exempt context
(`if …`, `&&`/`||` list) — a bare call or a plain `n="$(…)"` capture aborts the shell.

---

## Findings

### 1. Bash `exec` semantics — process replacement, no return, env inheritance

1. **`exec` replaces the process; it does not return.** The Bash manual states for
   `exec`: *"If command is specified, it replaces the shell. No new process is
   created."* The shell's process image is overwritten via `execve(2)`; the **PID
   stays the same**, and any code written *after* a successful `exec` is unreachable
   dead code. If the command cannot be executed and the `execfail` option is off
   (the default for non-interactive shells), the shell exits. — [Bash Reference
   Manual → Bourne Shell Builtins → `exec`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html);
   [`execve(2)` — Linux man page](https://man7.org/linux/man-pages/man2/execve.2.html)
2. **The exec'd program inherits the exported environment.** `execve(2)` is passed
   the caller's environment. A shell variable appears in that environment **only if
   it is exported** (set with `export`, or declared via `declare -x`, or given on the
   command line as `VAR=val cmd`). A plain `AGENT_BROWSER_SESSION=foo exec …` also
   adds it to the command's environment even without `export`, but the persistent
   form is `export`. — [`execve(2)` — environ argument](https://man7.org/linux/man-pages/man2/execve.2.html);
   [Bash Reference Manual → `export`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)
3. **Therefore `AGENT_BROWSER_SESSION` exported before `exec` IS seen by the real
   binary.** `pool_force_session()` already does
   `export AGENT_BROWSER_SESSION="abpool-$lane"` (read in full in `lib/pool.sh`). Because
   that runs in the *calling* shell (no subshell, no pipe) and `pool_wrapper_main` later
   does `exec "$POOL_REAL_BIN" "$@"`, the Rust `agent-browser` (which reads `std::env`)
   receives `AGENT_BROWSER_SESSION=abpool-<N>`. Confirmed-correct design. **Caveat to
   state in the PRP:** the variable must remain exported at the `exec` line; never
   `unset` it, and never run `exec` inside a `$(...)` or pipe (which would scope the
   export to a subshell that dies before the real binary starts).
4. **`exec` vs a plain invocation — why exec is the correct choice for a wrapper.**
   `"$POOL_REAL_BIN" "$@"` (no `exec`) runs the binary as a **child**, then control
   returns to the shell which then exits — leaving a transient parent shell, delaying
   signal delivery, and (under `set -e`) making the child's exit status subject to
   errexit bookkeeping. `exec` makes the real binary **become** the process: stdio,
   controlling terminal, signal disposition, and the final exit status all belong to
   the real tool with no shell in the way. This is precisely the property the
   rbenv/pyenv/rustup shims and every transparent PATH shadow rely on (see §5).
   — [`execve(2)`](https://man7.org/linux/man-pages/man2/execve.2.html)
5. **The `exec "$@"` / `"${array[@]}"` quoting rule applies.** Always quote the
   program path and pass `"$@"` (or the normalized array `"${POOL_NORM_ARGS[@]}"`)
   to preserve args containing spaces/globs. An unquoted `$@` or `$*` would re-split
   and re-glob — catastrophic for a transparent wrapper. `exec "$POOL_REAL_BIN"
   "$@"` is the correct form. — [Bash Reference Manual → Special Parameters (`@`)](https://www.gnu.org/software/bash/manual/html_node/Special-Parameters.html)

### 2. `return` vs `exit` in a sourced library — the right pattern for `pool_wrapper_main`

6. **`return` exits a function or a *sourced* script back to its caller; `exit`
   terminates the entire shell process.** The manual: `return` *"causes a function
   to stop executing and return the value specified by n to its caller … If return
   is used outside a function, but during execution of a script by the `.` (or
   `source`) command, it causes the shell to stop executing that script."* `exit`
   *"cause[s] the shell to exit."* Because `lib/pool.sh` is *sourced* (not executed),
   an `exit` inside any of its functions kills the **`bin/agent-browser` process**
   (the sourcing script) — which is the intended fatal-error behavior. A `return`
   from `pool_wrapper_main` would hand control back to `bin/agent-browser`'s
   remaining statements. — [Bash Reference Manual → `return`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html);
   [→ `exit`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)
7. **Best-practice pattern for a sourced-library main: the shim calls the function
   as its last statement, and the function is terminal.** Concretely, `bin/agent-browser`
   should be structured so that **nothing runs after** `pool_wrapper_main "$@"`:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   _abpool_self="${BASH_SOURCE[0]}"
   _abpool_real_self="$(readlink -f "$_abpool_self")"
   source "$(dirname "$_abpool_real_self")/../lib/pool.sh"
   pool_wrapper_main "$@"
   ```
   `pool_wrapper_main`'s exit paths are exhaustive and terminal: on the happy path it
   ends with `exec "$POOL_REAL_BIN" "$@"` (replaces the process — never returns); on
   any fatal error it calls `pool_die` → `exit 1` (terminates the process). There is
   **no `return` on the success path**, because there is no caller state to resume —
   the process has been replaced. If a non-fatal, non-terminal path were ever needed
   (e.g. a `--help` meta passthrough that wants to `exec` anyway), `exec` still
   handles it; `return` would be a bug because the shim has nothing to do next.
   — [Bash Reference Manual → `.` (source)](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)
8. **`pool_die` uses `exit 1` — correct for a sourced library.** `pool_die` (in
   `lib/pool.sh`) does `printf '%s\n' "$*" >&2; exit 1`. Since the lib is sourced,
   this `exit` aborts the `bin/agent-browser` invocation with a non-zero status —
   exactly the desired "fail this command loudly" semantics. Do **not** change it to
   `return`; a fatal config/acquire failure must fail the whole invocation, not hand
   a stale environment back to the shim. The library's existing `return`-based
   non-fatal helpers (`pool_lease_find_mine`, `pool_lane_is_stale`, …) are the
   complement: they `return` so their *caller* can branch, while only the true
   terminal `pool_die`/`exec`/`exit` paths end the process.
9. **`set -euo pipefail` is inherited by the sourced lib and is already at the top of
   `lib/pool.sh`.** When `bin/agent-browser` sources the lib, the lib's `set -euo
   pipefail` runs in the shim's own shell and governs `pool_wrapper_main`'s body.
   This is intentional and the whole library is written to that contract (see §4).

### 3. Resolving the shim's own path (to `source lib/pool.sh`) — symlink gotcha

10. **Use `BASH_SOURCE[0]`, not `$0`.** `${BASH_SOURCE[0]}` is the path of the file
    currently being read/sourced, regardless of how it was invoked; `$0` is the shell
    name and is unreliable for path resolution (it can be `bash`, an absolute path,
    or a symlink). For an *executed* script `BASH_SOURCE[0] == $0`, so it is the
    strictly-safer choice. — [Bash Reference Manual → `BASH_SOURCE`](https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html)
11. **THE symlink gotcha: resolve symlinks before taking `dirname`.** Per `PRD.md §2.1`,
    `~/scripts/agent-browser` is a **symlink → repo `bin/agent-browser`**, placed ahead
    of `~/.local/bin` on `PATH`. If the shim does `source "$(dirname "$0")/../lib/pool.sh"`:
    - `$0` = `~/scripts/agent-browser` (the **symlink**, not the target)
    - `dirname "$0"` = `~/scripts`
    - `../lib/pool.sh` = `~/lib/pool.sh` → **WRONG** (the lib lives at `<repo>/lib/pool.sh`).
    The fix is to canonicalize first: `real_self="$(readlink -f "${BASH_SOURCE[0]}")"`
    resolves **every** symlink hop to the real file `<repo>/bin/agent-browser`; then
    `dirname "$real_self"` = `<repo>/bin` and `../lib/pool.sh` = `<repo>/lib/pool.sh`. ✓
    — [`readlink(1)` — `-f` canonicalize](https://man7.org/linux/man-pages/man1/readlink.1.html);
    [Greg's Wiki BashFAQ 028 — "How do I determine the location of my script?"](https://mywiki.wooledge.org/BashFAQ/028)
12. **`readlink -f` vs `realpath` vs `realpath -m` — pick by existence requirement.**
    - `readlink -f` and `realpath` (GNU coreutils) both canonicalize and **require the
      final path to exist**; on this Linux host both are available. Either is correct
      for resolving the shim (the shim obviously exists — it is running).
    - `realpath -m` (`--canonicalize-missing`) does **not** require the path to exist.
      The codebase already uses `realpath -m` in `_pool_config_canon_path` /
      `pool_config_init` for *configuration defaults that may not exist yet* (state
      dir, ephemeral root, `POOL_REAL_BIN`). For the *shim self-resolution*, where the
      file definitely exists, plain `realpath`/`readlink -f` is fine and slightly
      stricter.
    — [GNU coreutils → `realpath` invocation](https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html);
    [→ `readlink` invocation](https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html)
13. **`POOL_REAL_BIN` (the *real* `agent-browser`) is already resolved by
    `pool_config_init`, not by the shim.** The task's Q3 conflates two distinct
    resolutions. The shim only needs to resolve **its own** location to find
    `lib/pool.sh`. The *real upstream binary* path is the config global
    `POOL_REAL_BIN`, set by `pool_config_init` from `AGENT_BROWSER_REAL` (default
    `$HOME/.local/bin/agent-browser`, canonicalized via `realpath -m`). So the
    `exec "$POOL_REAL_BIN" "$@"` line consumes an already-validated absolute path —
    the shim does **not** need to `readlink` it. Keep these two resolutions separate
    in the PRP. (One additional note: `realpath -m` does not verify the binary
    *exists*; a pre-`exec` `[[ -x "$POOL_REAL_BIN" ]]` guard with a clear `pool_die`
    is a reasonable belt-and-suspenders check, since a failed `exec` of a missing
    file under `set -e` exits with a less-actionable message.)

### 4. `set -euo pipefail` gotchas with intentionally non-zero functions

14. **`set -e` (errexit) aborts on the first non-zero simple command — *except* in
    exempt contexts.** A command's non-zero status is ignored when the command is:
    part of an `if`/`elif`/`while`/`until` condition, in a `&&`/`||` list (except the
    final command), inverted with `!`, or in a pipeline before the last command.
    This exception is the **mechanism** that lets you call a function that returns
    non-zero without aborting. — [Bash Reference Manual → The Set Builtin (`-e`)](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
15. **Bare call of `pool_lease_find_mine` (returns 1 on no-match) ABORTS under
    `set -e`.** A function invocation is a simple command; its non-zero exit status
    triggers errexit unless it sits in an exempt context. The library documents this
    exact hazard in the `pool_lease_find_mine` GOTCHA block. **The guard patterns:**
    ```bash
    # (a) if-guard — cleanest; rc 1 simply makes the condition false:
    if n="$(pool_lease_find_mine)"; then
        <reuse lane n>
    else
        <acquire>
    fi

    # (b) || fallback list — errexit-exempt:
    pool_lease_find_mine >/dev/null || { <acquire path>; }

    # (c) explicit rc capture:
    n=""; pool_lease_find_mine >/dev/null && n="$(pool_lease_find_mine)"
    ```
    — [Greg's Wiki BashFAQ 105 — "Why doesn't set -e do what I expected?"](https://mywiki.wooledge.org/BashFAQ/105)
16. **The `local x="$(…)"` (SC2155) trap MASKS errexit silently.** `local` is a
    builtin whose own exit status is always 0, so `local n="$(pool_lease_find_mine)"`
    does **not** abort even when the function returns 1 — but you silently lose the
    failure signal (and may proceed with `n=""` as if no error occurred). The correct
    form is to **split** declaration and assignment:
    ```bash
    local n
    n="$(pool_lease_find_mine)"   # plain assignment — status is the substitution's
    ```
    Note this split now makes errexit *fire* on the rc-1 path, so you must still wrap
    it in an `if`/`||` as in (15). Every capture in the library already follows this
    "declare first, assign in an exempt context" discipline. — [Greg's Wiki BashFAQ
    105](https://mywiki.wooledge.org/BashFAQ/105); [ShellCheck SC2155](https://www.shellcheck.net/wiki/SC2155)
17. **`(( expr ))` as a *statement* returns 1 when the value is 0 → aborts under
    `set -e`.** This bites counters: `(( n++ ))` returns 1 when `n` was 0. The library
    avoids it everywhere with the **assignment form** `n=$(( n + 1 ))` (always rc 0)
    and by only using `(( ))` inside conditions (`while (( … ))`, `if (( … ))`,
    `&&`/`||` lists), which are errexit-exempt. `pool_wrapper_main` must follow the
    same rule for any arithmetic it introduces. — [Bash Reference Manual → Arithmetic
    Evaluation / The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
18. **`set -u` (nounset): reference unset variables with `${var:-}` defaults.** The
    library uses `${VAR:-}` / `${VAR:-0}` everywhere for optional globals
    (`POOL_CHROME_PID`, `POOL_OWNER_STARTTIME`, …). `pool_wrapper_main` should do the
    same for any global it reads before its setter has run. — [Bash Reference Manual
    → The Set Builtin (`-u`)](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
19. **`set -o pipefail`: the pipeline's status is the rightmost non-zero component.**
    Combined with `set -e`, a failing command anywhere in a pipe (not just the last)
    aborts the shell. The library sidesteps this by either avoiding pipes for
    rc-sensitive work or guarding with `|| true` (e.g. `findmnt … || true`,
    `ss … || true`). For `pool_wrapper_main`'s `exec` line there is no pipe, so
    pipefail is not a concern there, but any diagnostic pipe inside the function
    should be guarded. — [Bash Reference Manual → Pipelines / The Set
    Builtin](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html)
20. **Functions that are *always-rc-0* need no guard** — and `pool_wrapper_main`'s
    building blocks are pre-classified this way in the library:
    - **Always rc 0 (bare call / plain capture is safe):** `pool_config_init`
      (rc 0 or `pool_die`), `pool_state_init` (rc 0 or `pool_die`), `pool_dispatch_classify`
      (always echoes + rc 0), `pool_normalize_close` / `pool_normalize_connect` /
      `pool_strip_session_args` (rc 0 always; output is the `POOL_*` global array, not
      stdout), `pool_force_session` is rc 0/1 so it *does* need guarding.
    - **rc 0/1 (MUST guard with `if`/`||`):** `pool_lease_find_mine`, `pool_acquire_locked`,
      `pool_wait_for_lane`, `pool_boot_lane`, `pool_ensure_connected`,
      `pool_force_session`.
    - **tri-state (rc 0/1/2; MUST guard with `if`):** `pool_lane_is_stale`.
    - **fatal (`pool_die`/`exit 1` or always 0):** `pool_copy_master`, `pool_chrome_launch`.
    This classification is the single most important thing to keep straight in the
    PRP; it is the entire reason the library's GOTCHA comments are so voluminous.
    — confirmed by reading `lib/pool.sh` in full.

### 5. Standard "dispatch wrapper" patterns (rbenv / pyenv / nvm / rustup)

21. **rbenv / pyenv: the "shim re-execs a dispatcher" pattern.** rbenv installs a
    generic shim for each command name into `~/.rbenv/shims/`. Each shim is identical
    and re-execs the dispatcher, passing its own basename as the program:
    ```bash
    #!/usr/bin/env bash
    set -e
    program="${0##*/}"            # e.g. 'ruby', 'gem'
    export RBENV_ROOT="/…/.rbenv"
    exec "/path/to/rbenv" exec "$program" "$@"
    ```
    `rbenv exec` resolves the selected version and then `exec`s the real binary.
    pyenv mirrors this (libexec-based; `pyenv exec <program> "$@"`). The unifying
    idea: a **PATH shadow** that does `exec dispatcher exec program args`. Note this
    is a **fork+exec hop** (shim → rbenv → real binary). — [rbenv (GitHub)](https://github.com/rbenv/rbenv);
    [pyenv (GitHub)](https://github.com/pyenv/pyenv)
22. **rustup: "proxy shims" that exec `rustup run`.** rustup places proxies
    (`rustc`, `cargo`, …) in `~/.cargo/bin/`. Each proxy detects the active toolchain
    and execs `rustup run <toolchain> <name> "$@"`, which resolves and execs the real
    tool. Same model as rbenv: thin shim → dispatcher → real binary, all via `exec`.
    — [rustup → Concepts → Proxies](https://rust-lang.github.io/rustup/concepts/proxies.html)
23. **nvm: the *sourced function* model (closest to this project).** Unlike
    rbenv/rustup, nvm is **sourced** (`\. ~/.nvm/nvm.sh`) and manipulates `PATH` /
    env in the current shell rather than installing per-command shims. `nvm use` sets
    `PATH` and exports vars; subsequent `node`/`npm` resolve via PATH. This is the
    *sourced-library* philosophy that `agent-browser-pool` adopts (`source lib/pool.sh`,
    work done in-process). — [nvm (GitHub)](https://github.com/nvm-sh/nvm)
24. **How `agent-browser-pool` relates to these (and where it is simpler).**
    `pool_wrapper_main` is **not** the rbenv/rustup "shim → dispatcher → real binary"
    three-hop model. It does the classification **inline in the sourced lib** and
    ends with a single `exec "$POOL_REAL_BIN" "$@"`. This is closer to nvm's
    "do the work in the current shell, then hand off" — but unlike nvm it *terminates*
    with a process-replacing `exec` (nvm usually just modifies env and returns). The
    takeaways to lift from the upstream shims:
    - **`set -e` at the top** of both shim and lib (matches rbenv/rustup; already done).
    - **The shim is a thin bootstrap** whose only job is: locate the lib (symlink-safe,
      §3), source it, call the main, and let main `exec`/`exit` (§2). Keep
      `bin/agent-browser` to ~5–8 lines.
    - **`exec` is the terminal hand-off** — no fork, env inherited (§1), exit status
      belongs to the real tool.
    - **Dispatch-then-exec-or-do-work**: classify first (here `pool_dispatch_classify`
      → `meta` = `exec` passthrough unchanged; `driving` = the full pool lifecycle),
      exactly mirroring how rbenv's shim classifies by `program="${0##*/}"` and how
      rustup proxies classify by their own name.
    — [rbenv](https://github.com/rbenv/rbenv); [pyenv](https://github.com/pyenv/pyenv);
    [rustup proxies](https://rust-lang.github.io/rustup/concepts/proxies.html);
    [nvm](https://github.com/nvm-sh/nvm)

---

## Recommended skeleton for `pool_wrapper_main` (synthesizing the above)

```bash
# pool_wrapper_main [--] ARGS...
#
# The wrapper lifecycle (PRD §2.4 steps 0→5). Called by bin/agent-browser as its
# FINAL statement (see §2: the shim must run nothing after this). Terminal by design:
#   - happy path  → exec "$POOL_REAL_BIN" "$@"   (process replaced; never returns)
#   - fatal path  → pool_die (exit 1)            (whole invocation fails loudly)
pool_wrapper_main() {
    local class N port

    # 0. Bypass / safety valve (PRD §2.17): passthrough, no pooling.
    if [[ "${POOL_DISABLE:-0}" == "1" ]]; then
        exec "$POOL_REAL_BIN" "$@"
    fi

    # config + state init (rc 0 or pool_die).
    pool_config_init
    pool_state_init

    # 0. dispatch: meta → exec passthrough unchanged.
    class="$(pool_dispatch_classify "$@")"   # always rc 0 → no guard needed
    if [[ "$class" == "meta" ]]; then
        exec "$POOL_REAL_BIN" "$@"
    fi

    # 1. owner resolution (never fatal; sets POOL_OWNER_*).
    pool_owner_resolve
    # No pi ancestor → passthrough (PRD §2.4 step 1).
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        exec "$POOL_REAL_BIN" "$@"
    fi

    # 2. find MY lease (rc 1 = none, MUST guard).
    if N="$(pool_lease_find_mine)"; then
        : # reuse lane N
    else
        # 3. acquire (rc 0/1 MUST guard) + exhaustion.
        if ! N="$(pool_acquire_locked)"; then
            if ! N="$(pool_wait_for_lane)"; then
                pool_die "agent-browser-pool: no lane available after ${POOL_WAIT}s + force-reap"
            fi
        fi
        # Is the acquired lane provisional (port 0) → boot it?
        port="$(pool_lease_field "$N" port)"
        if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
            pool_boot_lane "$N" || pool_die "agent-browser-pool: boot failed for lane $N"
        fi
    fi

    # 4. ensure connected (rc 0/1 MUST guard) — the per-call self-heal.
    if ! pool_ensure_connected "$N"; then
        pool_die "agent-browser-pool: lane $N not connected; aborting"
    fi

    # 5a. arg normalization: close --all strip, connect positional strip.
    pool_normalize_close "$@"
    pool_normalize_connect "${POOL_NORM_ARGS[@]}"

    # 5b. session override: strip --session flags, force env to abpool-<N>.
    pool_strip_session_args "${POOL_NORM_ARGS[@]}"
    pool_force_session "$N" || pool_die "agent-browser-pool: bad lane '$N' for session"

    # 5c. EXEC the real binary (process replacement; AGENT_BROWSER_SESSION inherited).
    exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"
}
```
> This skeleton is illustrative for the PRP (e.g. the exact acquire/boot/exhaustion
> sequence should match `pool_acquire_locked`'s documented CALLER CONTRACT and the
> `pool_boot_lane` / `pool_wait_for_lane` contracts already in `lib/pool.sh`). The
> *invariants* it demonstrates are the research deliverable: terminal `exec`, `pool_die`
> on fatal, `if`/`||` guards on every rc-0/1 and tri-state helper, and the
> `POOL_NORM_ARGS → strip → POOL_CLEAN_ARGS → exec` array pipeline.

---

## Sources

- **Kept:**
  - Bash Reference Manual (GNU) — `https://www.gnu.org/software/bash/manual/html_node/` — the authoritative spec for `exec`, `export`, `return`, `exit`, `set`, `BASH_SOURCE`, special params, pipelines. (Nodes: Bourne-Shell-Builtins, The-Set-Builtin, Bash-Variables, Special-Parameters, Pipelines.)
  - Greg's Wiki — BashFAQ 105 — `https://mywiki.wooledge.org/BashFAQ/105` — the canonical, community-trusted treatment of `set -e` gotchas (this is the single most-cited reference for §4).
  - Greg's Wiki — BashFAQ 028 — `https://mywiki.wooledge.org/BashFAQ/028` — finding a script's directory / resolving symlinks (the §3 symlink gotcha).
  - `execve(2)` — `https://man7.org/linux/man-pages/man2/execve.2.html` — process replacement + `environ` inheritance (§1).
  - `readlink(1)` / GNU coreutils `realpath` — `https://man7.org/linux/man-pages/man1/readlink.1.html`, `https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html` — symlink canonicalization (§3).
  - rbenv / pyenv / nvm / rustup — `https://github.com/rbenv/rbenv`, `https://github.com/pyenv/pyenv`, `https://github.com/nvm-sh/nvm`, `https://rust-lang.github.io/rustup/concepts/proxies.html` — dispatch-shim precedents (§5).
  - This repo's `lib/pool.sh`, `PRD.md`, `README.md` — read in full; they already encode every primitive and its rc contract (§20 skeleton, and confirming `pool_force_session` exports correctly).
- **Dropped:** none excluded for cause; live search results were unavailable, so no low-quality sources were filtered.

---

## Gaps

- **No live web search was performed** (`web_search` was not in the available
  toolset). The findings rest on stable, canonical reference pages and the repo's own
  code. A live pass would add: (a) confirmation that each cited manual-node URL
  resolves to the described section today, and (b) any *very* recent (2025–2026) bash
  changelog entries affecting `exec`/errexit behavior (none are expected — these
  semantics are stable across bash 4.x→5.x).
- **`local n="$(…)"` errexit-mask vs. plain-assignment abort under `set -e`** is a
  known gray area whose exact behavior can vary across bash point-releases; the
  *safe* guidance (always guard with `if`/`||`, always split declaration/assignment)
  is version-independent and is what the library already does, but the PRP should not
  *rely* on the precise abort-vs-mask of the unguarded forms. See BashFAQ 105.
- **Recommended next step:** a 10-second host verification of the two load-bearing
  claims: (1) `export X=1; exec env` shows `X=1` in the child's environment, and (2)
  `set -e; f(){ return 1; }; f; echo ok` prints nothing (aborts) while
  `if f; then echo yes; fi` prints nothing-but-doesn't-abort. These are trivial to
  confirm in the implementation subtask.
