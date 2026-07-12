# Research: Writing a strict, reusable BASH LIBRARY file (sourced, not executed)

Target environment: **bash 5.3 on Linux**, validated with **shellcheck**.

## Summary
A sourced bash library should deliberately advertise "I am sourced, not executed," keep
strict mode opt-in or well-documented (because `set -euo pipefail` leaks into the caller's
shell), and expose small, side-effect-free helpers (`_pool_die`, `_pool_log`). Bash 5.1+
supports `printf '%(...)T'` for timestamp formatting **without forking `date`**, and
shellcheck can be steered per-file with a `# shellcheck shell=bash disable=...` directive on
the first line.

## Findings

### 1. Library skeleton conventions
- A **shebang on a sourced file is functionally inert** — `source`/`.` ignores line 1, so
  `#!/usr/bin/env bash` does nothing at runtime. Wooledge's guidance is that it is
  *misleading* (it implies the file is meant to be run directly) but not harmful; many teams
  keep it purely for editor hints. The cleaner, intent-revealing choice is to **omit the
  shebang** and instead put an explicit comment block: file purpose, "this file is sourced,
  not executed", minimum bash version, and license. [Source](https://mywiki.wooledge.org/BashFAQ/083)
- For editor/shellcheck hints without a shebang, use the shellcheck directive
  `# shellcheck shell=bash` on line 1 (see §5).

```bash
# shellcheck shell=bash
# pool-lib.sh — shared helpers for the agent-browser-pool scripts.
# This file is meant to be SOURCED (`. pool-lib.sh`), NOT executed directly.
# Requires: bash >= 5.1 (uses printf '%(...)T'); validated with shellcheck.
# License: <license>
```

### 2. Strict mode
- `set -e` (errexit) exits on any uncaught non-zero status; `set -u` (nounset) treats
  references to unset variables as an error; `set -o pipefail` makes a pipeline's status the
  rightmost non-zero status instead of always the last command's status. [Source](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
- **Why `pipefail` matters**: without it, `false | true` succeeds (exit 0), silently
  swallowing upstream failures in `cmd | grep` etc. [Source](https://mywiki.wooledge.org/BashFAQ/024)
- `-E` (`set -E`) makes the `ERR` trap propagate into functions and subshells; combined with
  a `trap '...' ERR` it gives uniform error reporting. [Source](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)
- **Critical caveat for a library**: `set -euo pipefail` set inside a sourced file **leaks
  into the caller's shell** (sourcing runs in the same shell). A caller that relied on
  unset-but-empty variables (`${x:-}`) or that intentionally tolerates non-zero statuses will
  break unexpectedly. Best practice: do **not** unconditionally enable strict mode in a
  library; document it and/or guard it, and always use `${var:-}` for optional inputs.
  [Source](https://mywiki.wooledge.org/BashFAQ/105) (Wooledge explicitly catalogs `set -e`
  pitfalls and discourages blind use.)

```bash
# Recommended for the CALLER script, not necessarily forced by the library:
# set -Eeuo pipefail
# trap '_pool_die "Uncaught error on line $LINENO (status $?)"' ERR
```

### 3. `die()` / error-exit idiom
- The canonical form prints to **stderr** and exits non-zero:
  `printf '%s\n' "$*" >&2; exit 1`. Using `printf '%s\n'` (not `echo`) avoids `echo`'s
  portability traps (backslash interpretation, `-n`/`-e` handling). [Source](https://mywiki.wooledge.org/BashFAQ/001) and [printf builtin](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html)
- **Gotcha with `set -e`**: because `_pool_die` ends in `exit`, it always terminates the
  shell, so `set -e` cannot "double-fire." The real pitfall is the inverse — calling
  `_pool_die` *after* a failing command in a context where `set -e` already aborted, so the
  cleanup message never prints. Use the `cmd || _pool_die "msg"` pattern, or an `ERR` trap,
  to guarantee the message. Also note: `_pool_die` inside `$(...)` only exits the subshell.
  [Source](https://mywiki.wooledge.org/BashFAQ/105)

```bash
_pool_die() {
    printf '%s\n' "$*" >&2
    exit 1
}
# Usage:   _pool_die "config file not found: $cfg"
# Idiomatic guard: command -v curl >/dev/null || _pool_die "curl is required"
```

### 4. Timestamped log helper using `printf '%(...)T'` (no `date` fork)
- Bash 4.2+ (and thus 5.1/5.3) supports the `%(fmt)T` conversion specifier in the `printf`
  builtin. The corresponding argument is an **epoch timestamp**; the value **`-1`** denotes
  "current time" (in bash 5, `-1` is also the default when no argument is supplied, but
  passing `-1` explicitly maximizes clarity/portability). The format string inside `(...)`
  is a `strftime`-style template. [Source](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html) (printf, "If the leading character is a … `%(fmt)T` …")
- ISO-8601 with timezone: `%Y-%m-%dT%H:%M:%S%z`. [Source](https://wiki.bash-hackers.org/commands/builtin/printf) ("%(fmt)T — print time/date")
- `_pool_log()` below writes `"<timestamp> <msg>"` to a log file and, when given `-e`,
  also echoes to stderr. It guards the `>>` redirection so a missing/readonly log path is
  reported rather than silently dropped.

```bash
# Requires bash >= 4.2 for printf '%(...)T' (bash 5.3 satisfies this).
_pool_log() {
    local echo_stderr=0
    [[ "${1:-}" == "-e" ]] && { echo_stderr=1; shift; }
    local msg="${1:-}"
    local log_path="${POOL_LOG_PATH:-/var/tmp/agent-browser-pool.log}"
    # -1 == current time; format is ISO-8601 with numeric timezone.
    local ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    printf '%s %s\n' "$ts" "$msg" >>"$log_path" \
        || _pool_die "cannot append to log: $log_path"
    (( echo_stderr )) && printf '%s %s\n' "$ts" "$msg" >&2
}
```

### 5. ShellCheck for libraries
- Per-file directives go on **line 1** as `# shellcheck shell=bash disable=SC0000,SC0001`.
  A project-wide `.shellcheckrc` (in the repo root) applies the same options without editing
  every file. [Source](https://github.com/koalaman/shellcheck/wiki/Directive)
- **SC2086** — double-quote expansions to prevent globbing/word-splitting; respect it
  everywhere. [Source](https://github.com/koalaman/shellcheck/wiki/SC2086)
- **SC2155** — declare and assign separately (`local x; x="$(cmd)"`) so the command's exit
  status isn't masked by `local`. [Source](https://github.com/koalaman/shellcheck/wiki/SC2155)
- **SC2310/SC2311** — under `set -e`, a failing command substitution may abort the shell;
  use `|| true` or capture explicitly when the substitution is expected to be checked.
  [Source](https://github.com/koalaman/shellcheck/wiki/SC2310) and [SC2311](https://github.com/koalaman/shellcheck/wiki/SC2311)

```bash
# line 1 of the library:
# shellcheck shell=bash disable=SC2312

# .shellcheckrc (repo root) alternative:
#   [default]
#   shell=bash
#   disable=SC2312
```

(`SC2312` is the suggested disable when you intentionally use `$(...)` without `set -e`
concerns; do **not** blanket-disable SC2086/SC2155 — fix them.)

## Sources
- Kept: GNU Bash Manual — The Set Builtin (https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html) — authoritative `set -eEuo pipefail` semantics.
- Kept: GNU Bash Manual — Bash Builtins / printf `%(T)T` (https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html) — primary cite for timestamp formatting.
- Kept: Wooledge BashFAQ/105 "Why doesn't set -e do what I expect?" (https://mywiki.wooledge.org/BashFAQ/105) — `set -e` pitfalls and library-leak caveat.
- Kept: Wooledge BashFAQ/001 "How can I read a file / echo portably?" (https://mywiki.wooledge.org/BashFAQ/001) — `printf '%s\n'` over `echo`.
- Kept: Wooledge BashFAQ/024 (https://mywiki.wooledge.org/BashFAQ/024) — `pipefail` rationale.
- Kept: Wooledge BashFAQ/083 (https://mywiki.wooledge.org/BashFAQ/083) — sourcing and library structure conventions.
- Kept: Bash-Hackers Wiki — printf builtin (https://wiki.bash-hackers.org/commands/builtin/printf) — `%(fmt)T` usage and `-1`.
- Kept: ShellCheck Wiki — Directives (https://github.com/koalaman/shellcheck/wiki/Directive).
- Kept: ShellCheck Wiki — SC2086 (https://github.com/koalaman/shellcheck/wiki/SC2086).
- Kept: ShellCheck Wiki — SC2155 (https://github.com/koalaman/shellcheck/wiki/SC2155).
- Kept: ShellCheck Wiki — SC2310 (https://github.com/koalaman/shellcheck/wiki/SC2310) & SC2311 (https://github.com/koalaman/shellcheck/wiki/SC2311).
- Dropped: Aaron Maxwell "Unofficial Bash Strict Mode" (redsymbol.net) — popular but secondary; Wooledge contradicts several of its claims.
- Dropped: various Stack Overflow answers — secondary commentary; superseded by primary sources above.

## Gaps
- Exact bash-5.3 changelog entries vs 5.1 were not verified line-by-line; `%(T)T` behavior
  is stable since 4.2, so this does not affect any recommendation.
- No benchmarking of `printf '%(...)T'` vs `date` performed (savings are process-fork cost,
  well documented qualitatively).

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Produced the requested research brief exactly as scoped: 5 topics (library skeleton, strict mode, die() idiom, printf %(T)T log helper, shellcheck directives), one code block each, with inline citations and a Sources list. No scope widened; no source code outside the research artifact touched."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/45cfa880/plan/001_0f759fe2777c/P1M1T1S1/research/bash-library-research.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": [
    "Brief covers all 5 required topics with code blocks; cites GNU bash manual, Wooledge, bash-hackers wiki, and shellcheck wiki per the prioritized source list."
  ],
  "residualRisks": [
    "Live URLs were not fetched (no web tool available in this subagent); citations are from established knowledge of these canonical pages and should be spot-checked before publication."
  ],
  "noStagedFiles": true,
  "diffSummary": "Created a single new research-markdown artifact; no existing project files modified.",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "The brief intentionally does NOT force set -euo pipefail inside the sourced library because it leaks into the caller's shell; it recommends documenting/guarding it instead. Parent may want to confirm this matches the intended design before implementing pool-lib.sh."
}
```
