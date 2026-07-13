# Research: Bash patterns for `pool_wait_for_lane()` under `set -euo pipefail`

> Audience: implementer of `pool_wait_for_lane()` in `lib/pool.sh` (a library that is
> **sourced** into arbitrary caller shells with strict mode propagated by design).
> Scope: external best practices. No project files were modified — this is a note.

## Summary / TL;DR

For a polling-with-timeout loop, **do not use `$SECONDS`** (its special behavior is
silently lost if a caller has `unset SECONDS`, which is a real risk for a *sourced*
library). For elapsed-time **arithmetic**, prefer the codebase's named epoch primitive
`_pool_now` (= `date '+%s'`) for DRY/consistency with `acquired_at`; the forkless builtin
`printf '%(%s)T' -1` is a valid fork-free alternative and is the house style for *display*
timestamps (used by `_pool_log` / `_pool_alert`). Pair the timer with a **pre-test /
check-before-body loop** so `POOL_WAIT=0` falls straight through to the force-reap
fallback, guard every best-effort side effect (`notify-send`, log-append) with
`... 2>/dev/null || true`, capture return codes with a **split-local**
`local v; v="$(...)"` (SC2155), and never leave a bare `(( ))` / `[[ ]]` whose falsity
would trip `errexit`.

| Concern | Recommendation | Avoid |
|---|---|---|
| Elapsed/deadline timing | `_pool_now` (epoch; matches `acquired_at`) for arithmetic; `printf '%(...)T' -1` for display | `$SECONDS` (unset-fragile) |
| Sleep | `sleep 2` (returns 0; clear) | bare `read -t 2` (consumes stdin, returns non-zero on timeout → `errexit`) |
| `POOL_WAIT=0` | check-before-body (loop body never runs) | do/until (sleeps once first) |
| `notify-send` | `command -v notify-send >/dev/null 2>&1 && notify-send … 2>/dev/null \|\| true` | unguarded call (exits non-zero w/o display) |
| Log append | `printf '%s %s\n' "$ts" "$msg" >>"$file" \|\| true` (mirrors `_pool_log`) | unguarded redirect under `set -e` |
| `(( ))` truth test | `while (( … )); do`, `if (( … )); then`, `(( … )) \|\| x` | bare `(( x ))` when `x==0` → `errexit` exit |
| rc capture from a fn | `if out=$(fn); then …; else rc=$?; fi` + split-local | `local out=$(fn)` (masks fn's rc) |

---

## 1. Polling loop with timeout — `$SECONDS` (a) vs `date +%s`/`_pool_now` (b) vs `printf %()T` (c)

- **(a) `$SECONDS` works functionally even when the function spawns `( flock … )`
  subshells.** `$SECONDS` is measured in the *main shell*; functions run in the main shell.
  `start=$SECONDS` and `(( SECONDS - start < POOL_WAIT ))` all read the main shell's clock.
  Spawning a subshell does **not** reset/freeze/corrupt the parent's `$SECONDS`; each
  reference recomputes elapsed (it does not update "only on assignment"). The GNU bash
  manual: *"Subshells do not propagate the value of SECONDS to the parent shell."* —
  exactly what keeps the parent's delta safe.
  - Source: GNU Bash Manual → *Bash Variables* (`SECONDS`):
    https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html

- **THE GOTCHA that disqualifies `$SECONDS` for a *sourced* library:**
  > *"If SECONDS is unset, it loses its special properties, even if it is subsequently
  > reset."* — GNU Bash Manual, *Bash Variables*.

  Because `lib/pool.sh` is `source`d into an **arbitrary caller shell**, the caller may
  have `unset SECONDS`, `declare`-d it plain, or `export`-ed it — at which point `$SECONDS`
  silently expands to empty/garbage and the loop logic breaks with no error. The same
  caveat applies to `RANDOM`, `LINENO`, and `EPOCHREALTIME` (so `EPOCHREALTIME` is **not**
  a safe substitute either).

- **(b) `date +%s` / `_pool_now` works**, no special-variable semantics, but **forks** a
  process per read (negligible at a 2 s cadence). It is the codebase's named epoch
  primitive AND the clock `acquired_at` uses → elapsed-time and lease-time are on the same
  clock. **Preferred for elapsed arithmetic (DRY/consistency).**

- **(c) `printf '%(%s)T' -1`** is forkless, builtin, and the house style for *display*
  timestamps (`_pool_log` uses `printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1`). Valid for
  elapsed arithmetic too, but introducing a parallel epoch source when `_pool_now` exists
  is less DRY. **Preferred for display timestamps (in `_pool_alert`).**

```bash
# Arithmetic (elapsed/deadline) — use the named primitive
start="$(_pool_now)"
now="$(_pool_now)"
(( now - start >= POOL_WAIT )) && break

# Display timestamp — forkless builtin (house style)
printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
```

- Sources: GNU Bash Manual → *Bash Builtins* (`printf` `%(...)T`, `-1`=now):
  https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html ;
  *Bash Variables* (`SECONDS` unset caveat):
  https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html ;
  wooledge BashFAQ 105: https://mywiki.wooledge.org/BashFAQ/105

## 2. `sleep` interruptibility — `sleep 2` vs `read -t 2`

- `sleep` is an **external** utility that returns **0** on normal completion; under `set -e`
  a succeeding `sleep` does nothing bad. Interrupted only by a signal (default disposition
  applies). Sources: POSIX `sleep`
  https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sleep.html ; coreutils
  https://www.gnu.org/software/coreutils/manual/html_node/sleep-invocation.html
- `read -r -t 2 _` is a **builtin** (no fork), **but**: (a) **reads from inherited stdin**
  — stealing the caller's input; (b) **returns non-zero on timeout** → a *bare statement*
  trips `errexit`; (c) **cannot be redirected from `/dev/null`** for sleeping (hits EOF,
  returns immediately). **Recommendation: use `sleep 2`** for clarity and safety.

## 3. `POOL_WAIT=0` / small budget — check-before-body (pre-test)

In `pool_config_init`, `POOL_WAIT` is validated **digits-only** (no `> 0` enforcement —
only `PORT_RANGE` gets that), so **`POOL_WAIT=0` is a real, reachable value**
(`AGENT_BROWSER_POOL_WAIT=0`). The loop **must** fall straight through to force-reap
without a spurious first `sleep 2`.

```bash
start="$(_pool_now)"
while true; do
    now="$(_pool_now)"
    (( now - start >= POOL_WAIT )) && break   # CHECK FIRST (errexit-exempt in &&)
    pool_reap_stale >/dev/null
    if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
    sleep 2
done
# → force-reap (POOL_WAIT=0 never entered the body)
```

- Source (loop exit status): GNU Bash Manual → *Looping Constructs* — *"The exit status of
  the while command is the exit status of the last command executed in list-2, or zero if
  no commands were executed."*:
  https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html

## 4. `notify-send` — best-effort, never fatal under `set -e`

`notify-send` (libnotify) **exits non-zero when it cannot reach a notification daemon /
D-Bus session** (no `DISPLAY`/`WAYLAND_DISPLAY`, or `DBUS_SESSION_BUS_ADDRESS` unset).
Under `set -e` an unguarded call would abort the library. Guard it so a missing binary
**and** a non-graphical session are both non-fatal. `command -v … >/dev/null 2>&1` is
exempt from errexit (part of a &&/|| list).

```bash
if command -v notify-send >/dev/null 2>&1; then
    notify-send "$summary" "$body" >/dev/null 2>&1 || true
fi
```

- Sources: GNU Bash Manual → *The Set Builtin* (`-e`):
  https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html ;
  `notify-send(1)` https://manpages.debian.org/stable/libnotify-bin/notify-send.1.en.html

## 5. Atomic log append — timestamped line to `alerts.log`

The `>>` redirection opens the file with **`O_APPEND`**; on a local FS the kernel
atomically seeks to EOF and writes, so **concurrent small appends (each < `PIPE_BUF`,
typically 4096 bytes) do not interleave**. A single short timestamped line is well under
that bound, so a plain `>>` is atomic in practice.

```bash
printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true
printf '%s %s: %s\n' "$ts" "$summary" "$body" >>"$POOL_STATE_DIR/alerts.log" 2>/dev/null || true
```

- Sources: POSIX `write()` (`O_APPEND`/no intervening modification):
  https://pubs.opengroup.org/onlinepubs/9699919799/functions/write.html ;
  POSIX `<limits.h>` (`PIPE_BUF` ≥ 512, typically 4096):
  https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/limits.h.html

## 6. `set -e` + loop / `(( ))` return codes

1. **Loop exit status** = exit status of the last command in the body (or 0 if the body
   never ran). A loop whose last command is `sleep` returns **0**. After a `break`, the
   propagated status is that of `break` (**0**) — so a failing command just before `break`
   is **masked** unless `errexit` already aborted. → Use an **explicit `rc` variable** /
   `return` rather than relying on the loop tail.
2. **`(( expr ))` returns 0 when the expression is non-zero, and 1 when it is 0 (or on
   error).** A **bare** `(( x ))` with `x==0` returns 1 and, as a top-level command,
   **trips `errexit`** — the classic counter bug (`x=0; (( x++ ))` evaluates the *old* 0).
3. **Safe (errexit-exempt) contexts:** the `while`/`until` condition, the `if` condition,
   the non-final command of a `&&`/`||` list, anything inverted by `!`. So
   `(( x )) && break`, `(( x )) || true`, `if (( x )); then`, `while (( x )); do` are all
   safe; a bare `(( x ))` is **not**. (`[[ ]]` is *also* a command — a false bare
   `[[ … ]]` trips `errexit` too; same cure.)

- Sources: *The Set Builtin* (`-e` exceptions, "part of any command executed in a && or ||
  list except the command following the final && or ||"):
  https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html ;
  *Compound Commands* (`(( ))` arithmetic return value):
  https://www.gnu.org/software/bash/manual/html_node/Compound-Commands.html

## 7. Capturing a function's rc under `set -e` — SC2155 / BashFAQ 105

- **SC2155** — *"Declare and assign separately to avoid masking return values."*
  `local out="$(fn)"` reports `local`'s exit status (**always 0**), so a failure inside the
  command substitution is **silently swallowed** and `set -e` does **not** abort. Split it.
- `if out=$(fn); then …; else rc=$?; fi` works **only** when `out=$(fn)` is a plain
  assignment. **Never** write `if local out=$(fn)` — `local` masks the status and the `if`
  is always true.

```bash
# GOOD — split-local (SC2155-clean); if-capture branches on fn's real rc
local N
if N="$(pool_acquire_locked)"; then
    printf '%s\n' "$N"; return 0
fi
# BAD — local masks the rc; set -e cannot see the failure
local N="$(pool_acquire_locked)"
```

- Sources: ShellCheck SC2155 https://www.shellcheck.net/wiki/SC2155 ;
  wooledge BashFAQ 105 https://mywiki.wooledge.org/BashFAQ/105

## Note on URL verification

The URLs above are canonical, stable references (GNU bash manual HTML nodes, wooledge
BashFAQ, ShellCheck wiki, POSIX). They were recalled from established knowledge; a quick
click-check before merge is good practice (especially the `$SECONDS` "loses special
properties if unset" sentence and the `-e` exception wording).
