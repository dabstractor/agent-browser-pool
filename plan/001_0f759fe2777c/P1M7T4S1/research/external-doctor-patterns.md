# Research: "doctor"/"diagnose"/"health-check" CLI subcommand patterns

Scope: actionable patterns to inform a `agent-browser-pool doctor` Bash subcommand.
Conventions are confirmed/affirmed where noted; otherwise cited to primary docs.

## Summary
A `doctor` command is a self-contained diagnostic that (1) checks runtime
dependencies with the POSIX `command -v` idiom (plus `-x` for absolute paths),
(2) probes filesystem/process/port facts with the correct tool flags, (3) prints
a sectioned OK/WARN/FAIL report, and (4) exits 0 only when no FAIL is present.
The single most important discipline is guarding every probe against
`set -euo pipefail` so a missing optional dep or a dead PID never aborts the whole
run — every check must tolerate non-zero via `if`/`||`/`|| true`.

---

## Findings

### 1. `command -v` idiom for PATH dependency checks in Bash

1. **Canonical POSIX form.** `command -v NAME >/dev/null 2>&1` is the standard,
   portable way to test whether a command is resolvable on `PATH`. The POSIX
   `command` utility's `-v` flag "writes a string to standard output that
   indicates the pathname or command that will be invoked by the shell" and
   returns non-zero if the name cannot be found.
   [POSIX `command`](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html)
2. **Prefer `command -v` over `which`.** `which` is **not** specified by POSIX
   (it's an external binary, behavior varies across distros, and it writes to
   stdout). ShellCheck flags it: **SC2230** "which is non-standard. Use builtin
   `command -v` instead."
   [ShellCheck SC2230](https://www.shellcheck.net/wiki/SC2230)
3. **Always quote the argument.** An unquoted variable triggers **SC2086**
   ("Double quote to prevent globbing and word splitting").
   [ShellCheck SC2086](https://www.shellcheck.net/wiki/SC2086)
4. **Recommended helper for "bare NAME OR absolute PATH".** A dependency value
   may be a resolvable name (`pgrep`) or an absolute path (`/usr/bin/google-chrome-stable`).
   Combine both:
   ```bash
   # Returns 0 if present+executable, 1 otherwise. Safe under set -e (always in a guard).
   _dep_ok() {  # $1 = name or absolute path
     local v=$1
     if [[ $v == /* ]]; then [[ -x $v ]]; else command -v "$v" >/dev/null 2>&1; fi
   }
   ```
   `command -v` already returns a resolved path to stdout, so redirecting to
   `/dev/null` avoids leaking it into the report. For the absolute branch,
   `test -x` (POSIX `test`) is the right check — it confirms both existence and
   executable bit.
   [POSIX `test`](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html)

### 2. Exit-code conventions for "doctor"/"health"/"fsck" commands

5. **Universal convention: exit 0 = healthy, non-zero = problems found.** This
   is the contract callers (`&&`, CI, cron wrappers) rely on.
6. **`git fsck`** "exits with a non-zero status if errors were found" — the
   archetypal precedent for a verify-and-exit command.
   [git-fsck(1)](https://git-scm.com/docs/git-fsck)
7. **`brew doctor`** "checks your system for potential problems" and returns a
   non-zero exit status when it detects issues, making it scriptable in CI.
   [Homebrew Manpage](https://docs.brew.sh/Manpage)
8. **`npm doctor`** runs a battery of environment checks (registry ping,
   permissions, git) and surfaces failures; npm commands broadly follow the
   "non-zero on failure" exit-code convention.
   [npm doctor](https://docs.npmjs.com/cli/v10/commands/npm-doctor)
9. **`flutter doctor`** prints a ✓/✗ status grid per check and is the clearest
   precedent for a *sectioned, per-item* doctor report.
   [Flutter doctor](https://docs.flutter.dev/get-started/install)
10. **Project convention is SOUND and well-precedented.** Separating **WARN**
    (exit 0, recoverable: stale lease, orphan dir, disconnected port, missing
    *optional* `notify-send`) from **FAIL** (non-zero, blocking: missing required
    dep, wrong filesystem, missing master) matches how `brew doctor` (advisory
    warnings vs hard errors) and CI tooling (warnings don't fail the build)
    behave. The verdict rule **"FAIL drives exit code; WARN never does"** is the
    correct, conventional design. Recommendation: **exit 1 if `FAIL_N -gt 0`,
    else exit 0.** Keep a single, documented exit code (1) rather than bitmask
    codes unless callers need severity differentiation.

### 3. Report formatting for a doctor command

11. **Sectioned output with category headers.** Bracketed headers group related
    checks and aid grep/awk. Recommended sections for this tool:
    `[dependencies]`, `[binary]`, `[filesystem]`, `[master]`, `[lanes]`,
    `[dirs]`, `[summary]`. This mirrors `brew doctor`'s per-category output and
    `flutter doctor`'s grouped check lines.
12. **Per-item status line.** Print `name`, a dotted leader for alignment, then a
    status token. Avoid external formatting libs — `printf` suffices:
    ```bash
    # $1=name $2=state (OK/MISSING/WARN/FAIL)  $3=optional detail
    _emit() {
      local name=$1 state=$2 detail=${3:-}
      printf '%-26s %s%s\n' "$name" "$state" "${detail:+  $detail}"
    }
    ```
    A `-26s` left-justified field with the status right after gives a clean
    column without pulling in `column`/`tput`.
13. **Final SUMMARY line with counts + one-line verdict.** Make the summary line
    itself machine-parseable and put the human verdict on the next line:
    ```text
    [summary] OK=6 WARN=2 FAIL=1
    Problems found. (1 blocking failure)
    ```
    Single-line `OK=N WARN=N FAIL=N` is trivially `grep`/`cut`-able by CI.

### 4. `findmnt -T` (target) flag

14. **`findmnt -nno FSTYPE -T PATH` is the correct invocation.** Breakdown:
    - `-n` / `--noheadings` — suppress the header row.
    - `-o FSTYPE` / `--output FSTYPE` — print only the filesystem type
      (e.g. `btrfs`).
    - `-T PATH` / `--target PATH` — "**If path is not a mountpoint device or
      file**, findmnt checks the parent directories … then displays filesystem
      that contains the path." This resolves the *containing* mount for any path.
    [findmnt(8)](https://man7.org/linux/man-pages/man8/findmnt.8.html)
15. **Why a bare `findmnt PATH` is WRONG.** Without `-T`, findmnt treats the
    positional argument as a match against **SOURCE** (device name) or an exact
    **mountpoint**. For a path that lives *inside* a mount tree (not the exact
    mountpoint root), a bare lookup returns nothing or matches the wrong entry.
    `-T` is what makes "what filesystem is this directory on?" work.
    [findmnt(8)](https://man7.org/linux/man-pages/man8/findmnt.8.html)
16. **Concrete check (must be guarded under `set -e`):**
    ```bash
    local fs
    fs=$(findmnt -nno FSTYPE -T "$EPH_ROOT" 2>/dev/null || echo "")
    [[ $fs == btrfs ]]   # FAIL if not btrfs
    ```

### 5. Process liveness via `/proc` in Bash

17. **`[[ -d /proc/$pid ]]` is a cheap liveness test** but has a known
    limitation: it only proves *some* process holds that PID, not that it's *the
    process you started*. PIDs are recycled, so a dead Chrome PID can later be
    reused by an unrelated program, producing a false "alive".
    [proc(5)](https://man7.org/linux/man-pages/man5/proc.5.html)
18. **`/proc/$pid/comm` is a stronger identity check.** It holds the executable's
    base name as set by the kernel. But note the truncation: Linux stores `comm`
    in a `TASK_COMM_LEN`-sized buffer of **16 bytes (15 chars + NUL)**, so long
    names are cut. For Chrome launched as `google-chrome-stable`, `comm` becomes
    **`google-chrome-s`** (15 chars). Match against the truncated form, or check
    `/proc/$pid/exe` (symlink to the real binary) for a precise match:
    ```bash
    # Strong identity: resolved binary path
    [[ -L /proc/$pid/exe && "$(readlink /proc/$pid/exe)" == *chrome* ]]
    ```
    [proc(5) — /proc/[pid]/comm](https://man7.org/linux/man-pages/man5/proc.5.html)
19. **Stale-lease reconciliation (LEAK / ORPHAN DIR / DISCONNECTED).** Use the
    `/proc` liveness check as the tie-breaker between three sources:
    | Condition | Lease JSON | /proc alive | Ephemeral dir |
    |---|---|---|---|
    | LEAK (stale lease) | yes | NO | (any) |
    | ORPHAN DIR | no | (any) | yes (exists) |
    | DISCONNECTED | yes | YES | port closed / no dir |
    All three are **WARNs** (recoverable), per the convention in §2.

### 6. Port-listening probe via curl

20. **`curl -sf --max-time 2 http://127.0.0.1:$port/json/version >/dev/null 2>&1`**
    is a side-effect-free HTTP liveness probe. The DevTools `/json/version`
    endpoint answers on a running Chrome without altering session/lease state.
    Flag meanings:
    - `-s` / `--silent` — no progress meter, no error noise.
    - `-f` / `--fail` — **fail fast on HTTP errors** (4xx/5xx → exit **22**),
      and suppress the error body. Returns 0 only on 2xx.
    - `--max-time` — **overall** operation timeout (DNS+connect+transfer);
      `2` bounds a hung/unresponsive port. (Contrast `--connect-timeout`, which
      only bounds the TCP connect phase.)
    [curl(1)](https://curl.se/docs/manpage.html)
21. **Guard it.** A non-listening port makes `curl` exit 7/22/28 — fatal under
    `set -e` if bare. Always wrap: `if curl -sf --max-time 2 …; then …; fi`.

### 7. Common pitfalls under `set -euo pipefail`

22. **(a) Bare `(( expr ))` returns exit 1 when the result is 0.** Arithmetic
    compound commands take their exit status from the *expression value*: a
    result of `0` → exit `1`, which is fatal under `set -e`. Fix: keep it in a
    condition (`if (( n )); then`), or use value form (`x=$(( n + 1 ))`), or
    append `|| true`. Incrementing a counter with `(( ++n ))` when `n` is already
    non-zero is safe, but `(( n - n ))` or `(( found == 0 ))` will abort.
    [BashFAQ/105 — Why set -e is dangerous](https://mywiki.wooledge.org/BashFAQ/105)
23. **(b) `command -v` returning 1 aborts under `set -e`.** A missing dependency
    makes `command -v "$dep"` exit non-zero; if called bare, errexit kills the
    script. The whole point of `doctor` is to *report* a missing dep, not crash.
    Always invoke it in `if command -v …; then` or `_dep_ok … || …`.
    [BashGuide — Practices](https://mywiki.wooledge.org/BashGuide/Practices)
24. **(c) `findmnt`/`curl`/`ls`/`cat`/`grep` exiting non-zero.** Every external
    probe that may legitimately fail (no match, connection refused, file gone)
    must be neutralized: `findmnt … || echo ""`, `if ! curl …; then …; fi`,
    `grep … || true`, or `[[ -f $f ]] || continue`. Under `set -o pipefail`, a
    non-zero anywhere in a pipeline propagates, so prefer capturing into a var
    with a trailing `|| echo ""` rather than naked pipes.
    [BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)
25. **(d) SC2155 — `local x="$(cmd)"` masks errexit.** The `local` builtin
    **always returns 0**, so `local x="$(failing_cmd)"` swallows the failure even
    under `set -e`. Declare then assign:
    ```bash
    local fs          # declare first
    fs=$(findmnt -nno FSTYPE -T "$EPH_ROOT" 2>/dev/null || echo "")
    ```
    [ShellCheck SC2155](https://www.shellcheck.net/wiki/SC2155)
26. **(e) `nullglob` unset → literal glob on no match.** By default, a glob with
    zero matches expands to its literal text (e.g. `leases/*.json` when empty →
    the string `leases/*.json`). Iterating then "processes" a nonexistent file.
    Guard with existence checks:
    ```bash
    shopt -s nullglob   # OR explicit per-iteration guard:
    for f in "$MASTER"/*; do [[ -f $f ]] || continue; …; done
    ```
    [Greg's Wiki — nullglob](https://mywiki.wooledge.org/glob#nullglob)
27. **Bonus: `pipefail` + `findmnt`/`grep`.** With `set -o pipefail` active,
    `fs=$(findmnt … | awk '{print $1}')` fails if `findmnt` fails. Prefer a
    single command + `$()` without pipes, or append `|| true` to the pipeline.

---

## Sources

- **Kept:**
  - POSIX `command` (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html) — authority for `command -v`.
  - POSIX `test` (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html) — authority for `-x`.
  - ShellCheck SC2230 (https://www.shellcheck.net/wiki/SC2230) — `which` → `command -v`.
  - ShellCheck SC2086 (https://www.shellcheck.net/wiki/SC2086) — quote variables.
  - ShellCheck SC2155 (https://www.shellcheck.net/wiki/SC2155) — `local` masks errexit.
  - git-fsck(1) (https://git-scm.com/docs/git-fsck) — non-zero on error precedent.
  - Homebrew Manpage (https://docs.brew.sh/Manpage) — `brew doctor` precedent.
  - npm doctor (https://docs.npmjs.com/cli/v10/commands/npm-doctor) — env-check precedent.
  - Flutter doctor (https://docs.flutter.dev/get-started/install) — sectioned status grid.
  - findmnt(8) (https://man7.org/linux/man-pages/man8/findmnt.8.html) — `-T/--target` semantics.
  - proc(5) (https://man7.org/linux/man-pages/man5/proc.5.html) — `/proc/[pid]`, `comm`, `TASK_COMM_LEN`.
  - curl(1) (https://curl.se/docs/manpage.html) — `-s`/`-f`/`--max-time`.
  - BashFAQ/105 (https://mywiki.wooledge.org/BashFAQ/105) — `set -e` hazards.
  - Greg's Wiki glob (https://mywiki.wooledge.org/glob#nullglob) — `nullglob` behavior.
- **Dropped:** generic blog posts on "bash doctor script", "how to check if command exists" — SEO-heavy, redundant with POSIX/ShellCheck primaries.

## Gaps

- **Exact exit code of `npm doctor`** is not crisply documented in the npm docs;
  the convention (non-zero on problem) is inferred from npm-wide behavior. Verify
  against the installed version if a caller depends on it.
- **Chrome DevTools `/json/version` schema stability** across Chrome versions:
  cited as the liveness endpoint, but field shape can vary; only the HTTP 200
  response is relied upon here, which is robust.
- **`brew doctor` per-check exit semantics** (individual check vs aggregate) —
  the aggregate "non-zero if problems" is well established; per-check granularity
  is out of scope for this tool.

## Suggested next steps for the PRP

- Encode the `_dep_ok` helper (§1, finding 4) and the `_emit` formatter (§3,
  finding 12) as the two core primitives the spec builds on.
- Make the spec's exit-code rule a one-liner: `(( FAIL_N ))` inside the exit
  decision, **not** bare — i.e. `if (( FAIL_N > 0 )); then exit 1; else exit 0; fi`.
- Require every probe function to end with `|| echo ""` / `if !` guarding so the
  whole `doctor` run never aborts before printing its summary (the single most
  common bug in hand-written Bash diagnostics).
