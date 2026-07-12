# Research: Linux process liveness + PID-recycling-safe identity verification in bash

> Target function: `pool_owner_alive(pid, expected_starttime, expected_comm)` under
> `set -euo pipefail`. Returns 0 if the lease owner is alive **and** is the same
> process invocation that took the lease; returns 1 otherwise.
>
> Decision ladder:
> (a) `/proc/<pid>` missing → dead → return 1
> (b) `/proc/<pid>/comm` ≠ `expected_comm` → recycled (non-matching image) → return 1
> (c) starttime (field 22 of `/proc/<pid>/stat`) ≠ `expected_starttime` → recycled into a new process → return 1
> (d) else → return 0

## Summary

The proposed ladder is the textbook correct shape for "is this PID still my
process": **PID existence** proves liveness, **`comm`** is a cheap first-pass
image-name check, and **starttime (field 22 of `/proc/[pid]/stat`)** is the
authoritative identity token that defeats PID recycling. PIDs are recycled by
the kernel, so `pid` alone is *not* identity — `(pid, starttime)` is. All reads
must be treated as independently fallible under `set -e`/TOCTOU, and the whole
probe is best-effort because the lease reaper runs again on the next acquire.

Note on sourcing: this environment has no live web-search tool. URLs below are
canonical, stable references (man7.org man-pages, kernel.org docs, kernel
source on kernel.org, ShellCheck wiki, GNU bash manual). Content is from
established kernel/shell behavior; a spot-check of each URL is recommended
before citing in an external doc (see **Gaps**).

---

## Findings

### 1. `/proc/[pid]/comm` semantics

1. **It is the bare command name, no path, no parentheses.**
   `comm` exposes the process's `comm` value — the executable's command name
   (basename), not a path, and **not** wrapped in parentheses. The
   parenthesized form lives only in field 2 of `/proc/[pid]/stat`. So for a
   process whose argv[0]/executable is `/usr/bin/pi`, `comm` reads `pi` (plus a
   trailing newline).
   [proc(5): /proc/[pid]/comm](https://man7.org/linux/man-pages/man5/proc.5.html)
   [kernel proc.rst](https://www.kernel.org/doc/html/latest/filesystems/proc.html)

2. **Max length is `TASK_COMM_LEN == 16`, i.e. 15 usable bytes + NUL.**
   `TASK_COMM_LEN` is `16` in the UAPI header. The kernel stores at most 15
   bytes of name plus a trailing NUL, so any name longer than 15 chars is
   **truncated** — two different executables can therefore collide on the same
   `comm`. `pi` is 2 characters: **zero truncation risk**, and no realistic
   collision surface as a first-pass filter.
   [include/uapi/linux/sched.h (TASK_COMM_LEN)](https://github.com/torvalds/linux/blob/master/include/uapi/linux/sched.h)
   [proc(5): /proc/[pid]/comm — truncation note](https://man7.org/linux/man-pages/man5/proc.5.html)

3. **The file is newline-terminated.** The kernel's `comm_show` writes the name
   followed by `\n`, so `cat /proc/<pid>/comm` yields `pi\n` (two chars + LF).
   This matters only if you read the file without command substitution; see
   §6 for why this is usually a non-issue.
   [fs/proc/base.c — comm_show](https://github.com/torvalds/linux/blob/master/fs/proc/base.c)

4. **`comm` can contain spaces and arbitrary bytes** because a thread may
   rename itself via `prctl(PR_SET_NAME, ...)` or by writing to
   `/proc/self/task/[tid]/comm`. The default value is the executable basename,
   but the field is *not* guaranteed whitespace-free. Implication for
   comparison: always quote and use `[[ ]]` literal (not pattern) matching.
   [proc(5): /proc/[pid]/comm — "A thread may modify its comm value"](https://man7.org/linux/man-pages/man5/proc.5.html)
   [prctl(2): PR_SET_NAME](https://man7.org/linux/man-pages/man2/prctl.2.html)

5. **Exact-match gotchas in bash.**
   - Command substitution `$(...)` strips **all** trailing newlines
     ([Bash manual: Command Substitution](https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution)), so
     `c="$(cat /proc/$pid/comm)"` yields `pi` with the LF already gone.
     As long as `expected_comm` was captured the same way (`$(cat ...)` or a
     trimmed `read`), comparison is apples-to-apples.
   - `[[ "$actual" == "$expected" ]]` treats the **right-hand side as a glob
     pattern when unquoted**. If `expected_comm` ever contains `*`, `?`, or
     `[`, an unquoted RHS silently becomes a pattern match. **Always quote the
     RHS**: `[[ "$comm" == "$expected_comm" ]]`.
     ([Bash manual: Conditional Constructs / Pattern Matching](https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs))
   - Capture `expected_comm` *from the same source at lease time* (i.e. read
     `/proc/<pid>/comm` of the owning process) so truncation is consistent.
     Storing the full argv[0]/executable name and then comparing to `comm` is a
     classic bug, because the stored name is *not* truncated while `comm` is.

### 2. Why `starttime` (field 22) defeats PID recycling

1. **Field 22 is `starttime`, in clock ticks since boot.** From proc(5),
   field 22 of `/proc/[pid]/stat`:
   > *starttime* — The time the process started after system boot. Since
   > Linux 2.6, the value is expressed in clock ticks (divide by
   > `sysconf(_SC_CLK_TCK)`).
   [proc(5): /proc/[pid]/stat — table of fields](https://man7.org/linux/man-pages/man5/proc.5.html)
   [kernel proc.rst: Table 1-4 / stat fields](https://www.kernel.org/doc/html/latest/filesystems/proc.html)

2. **PID recycling is real OS behavior.** The kernel allocates PIDs from a
   recycling bitmap; the counter wraps at `pid_max` (default 32768; up to
   4194304 on 64-bit). When a process exits and its PID is freed, that PID
   number will eventually be handed to an *unrelated* new process. The PID is
   therefore **not** stable identity across a process's lifetime — only
   `(pid, starttime)` is, because a newly created process occupying a recycled
   PID always has a strictly greater `starttime` than the dead process that
   previously held it (within a single boot).
   [proc(5): /proc/sys/kernel/pid_max](https://man7.org/linux/man-pages/man5/proc.5.html)
   [pid allocation / pid namespaces](https://www.kernel.org/doc/html/latest/filesystems/proc.html)

3. **`starttime` is monotonic per-boot and changes on every exec/fork into a
   new task.** Because each new task gets a fresh `starttime` equal to its
   creation time, comparing the stored `expected_starttime` to the *current*
   field 22 distinguishes "same invocation" from "a different process now owns
   this PID number." This is the canonical identity token used across pidfile
   libraries and process supervisors (see §5).

4. **Units: compare raw integers, don't convert.** `_pool_get_starttime`
   should return the raw tick integer from field 22 (e.g. `12345678`). Do the
   same at capture time. Converting to seconds (÷ `CLK_TCK`, typically 100)
   adds floating-point and rounding for no benefit — identity comparison only
   needs integer equality. `getconf CLK_TCK` is ~100 on most x86 but is
   irrelevant if you store/compare raw.
   [sysconf(3): _SC_CLK_TCK](https://man7.org/linux/man-pages/man3/sysconf.3.html)

5. **Parsing caveat for `/proc/[pid]/stat` (relevant to `_pool_get_starttime`).**
   Field 2 (`comm`) is enclosed in parentheses and **may itself contain spaces
   and parentheses**, so naïve `awk '{print $22}'` is wrong — it miscounts
   fields when `comm` has spaces. The robust idiom is to strip everything up to
   and including the *last* `)`, then index from there (field 22 becomes
   field 20 in the remainder, since fields 1 and 2 were consumed):
   ```bash
   _pool_get_starttime() {  # pid -> raw starttime ticks, or empty on failure
     local pid="$1" s rest
     s="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
     rest="${s##*) }"          # drop pid + (comm) — everything through last ') '
     awk '{print $20}' <<<"$rest"   # field 22 minus the two consumed fields
   }
   ```
   [proc(5): /proc/[pid]/stat — comm may contain spaces/parens](https://man7.org/linux/man-pages/man5/proc.5.html)

### 3. Liveness-check methods and the `kill -0` EPERM false-dead trap

1. **Three common probes.**
   - **`test -e /proc/<pid>` / `test -d`** — existence of the procfs directory.
     Works regardless of signal permissions; existence is observable for other
     users' processes (subject to `hidepid`, see below).
   - **`kill -0 "$pid"`** — sends signal 0. Returns 0 if the process exists
     *and you may signal it*; returns 1 on `ESRCH` (no such process) **or on
     `EPERM`** (exists but not yours). Shell cannot distinguish the two: both
     are exit 1.
   - **`pgrep`** — pattern-based; returns matching PIDs. Not ideal for a single
     exact-PID liveness check, and has its own UID/permission filtering flags.
     [kill(2): ESRCH, EPERM](https://man7.org/linux/man-pages/man2/kill.2.html)
     [kill(1)](https://man7.org/linux/man-pages/man1/kill.1.html)

2. **The false-dead trap: `kill -0` reports "dead" when it really means
   "not mine."** If the target exists but is owned by another UID,
   `kill -0` fails with `EPERM` (exit 1), which to the shell is
   indistinguishable from `ESRCH`. A naive `kill -0 "$pid" || return 1`
   therefore reports a **live** foreign process as dead. This is the single
   most cited footgun in shell liveness checks.
   [kill(2): ERROR EPERM](https://man7.org/linux/man-pages/man2/kill.2.html)

3. **Why `/proc/<pid>` existence is preferable for cross-user checks.** procfs
   directory existence does not conflate "exists" with "I can signal it."
   Reading existence via `test -d`/`test -e` gives a clean EEXIST-vs-ENOENT
   answer. (Caveat: with `hidepid=1/2` on `procfs`, `/proc/<pid>` for other
   users' processes may be hidden entirely; for same-UID pool owners this does
   not apply.)
   [proc(5): /proc mount options (hidepid)](https://man7.org/linux/man-pages/man5/proc.5.html)
   [filesystems/proc.rst](https://www.kernel.org/doc/html/latest/filesystems/proc.html)

4. **For this codebase the owner is the same UID**, so `kill -0` would in fact
   work — but `/proc/<pid>` is still the better foundation because step (b)/(c)
   need `/proc/<pid>/{comm,stat}` *anyway*. Do liveness + identity from one
   source of truth (procfs) rather than mixing `kill -0` with `/proc` reads,
   which invites TOCTOU inconsistency between the two.

### 4. TOCTOU race and the best-effort probe

1. **Every step can race.** A process can exit between the `test -d` check and
   the `comm` read, or between the `comm` read and the `stat` read. No
   sequence of separate reads is atomic. The standard defensive pattern is:
   treat **each** read as independently fallible and degrade gracefully.
   [proc(5): /proc/[pid] lifecycle](https://man7.org/linux/man-pages/man5/proc.5.html)

2. **Guard each read; let the ladder fall through.** Each `cat` must be
   protected against `set -e` aborting the function. The recommended shape:
   ```bash
   pool_owner_alive() {  # pid expected_starttime expected_comm -> 0 alive+same, 1 else
     local pid="$1" expected_starttime="$2" expected_comm="$3"
     local comm starttime
     # (a) existence
     [[ -d "/proc/$pid" ]] || return 1
     # (b) image-name first pass (cheap)
     comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || comm=""
     [[ -n "$comm" ]] || return 1
     [[ "$comm" == "$expected_comm" ]] || return 1
     # (c) authoritative identity token
     starttime="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
     starttime="$(awk '{print $20}' <<<"${starttime##*) }")" || return 1
     [[ "$starttime" == "$expected_starttime" ]] || return 1
     # (d) alive + same identity
     return 0
   }
   ```
   Note: because the function runs under `set -e`, every command whose failure
   is *expected* must either be inside `if`/`||`/`&&` context or be followed by
   `|| true`. `cat /missing` unguarded **aborts** the whole script under
   `set -e`.
   [Bash manual: The Set Builtin (errexit)](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin)

3. **Point-in-time semantics: "alive now" ≠ "alive next syscall."** Even a
   clean return 0 only proves liveness at the instant of the last read; the
   process can exit a nanosecond later. Correctness therefore comes from the
   **caller** being idempotent and re-running the probe (the reaper runs again
   on the next acquire). The probe is a best-effort, race-tolerant hint, not a
   guarantee. This is the universally accepted design for liveness probes.
   [Bash manual: The Set Builtin](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin)

4. **Robustness of the ladder ordering.** Existence → comm → starttime is the
   right order: existence is cheapest and most likely to fail (process gone);
   `comm` is one small read and rejects the common "PID recycled into some
   unrelated binary" case before paying for the `stat` parse; `starttime` is
   the final, authoritative tie-breaker for "recycled into a process that
   happens to share the same `comm`."

### 5. How established supervisors verify process identity

1. **Direct-parent supervisors (supervisord, daemontools/runit, s6):** they
   *forked* the child, so they receive `SIGCHLD` and reap via `waitpid(2)`.
   Identity is unambiguous — the kernel tells the exact parent when and which
   child died. **No PID-recycling ambiguity** for direct children. This is the
   gold standard, but it requires the supervisor to be the parent, which a
   lease-pool owner-check is *not*.
   [waitpid(2)](https://man7.org/linux/man-pages/man2/waitpid.2.html)
   [daemontools / supervise](https://cr.yp.to/daemontools.html)

2. **systemd for `Type=forking` / detached services:** systemd does **not** own
   the main PID as a parent, so it must probe. It uses `sd_notify` (`READY=1`,
   optional `MAINPID=`, `WATCHDOG=1`) plus a recorded `(pid, starttime)` to
   detect recycling. `$MAINPID` from the service is validated against procfs;
   systemd periodically reconciles the recorded process identity. This is
   essentially the `(pid, starttime)` technique the pool check uses.
   [sd_notify(3)](https://man7.org/linux/man-pages/man3/sd_notify.3.html)
   [systemd.service(5): Type=, MAINPID](https://man7.org/linux/man-pages/man5/systemd.service.5.html)

3. **psmisc (`killall`, `pidof`, `fuser`):** match processes by reading
   `/proc/[pid]/stat` and comparing — including using starttime to disambiguate
   between a real match and a stale entry. These tools are the canonical "scan
   `/proc` and compare identity fields" reference implementations in C.
   [psmisc source (GitHub)](https://github.com/psmisc/psmisc)

4. **procps-ng / libprocps:** `pgrep`/`ps` read `/proc/[pid]/stat` and expose
   starttime (`-o`/`lstart`); libraries use `(pid, starttime)` as the stable
   handle. The pidfile + starttime pattern is also standard in
   `liblockfile`-style pidfile libraries: store `pid`, then on reopen verify
   `starttime` matches before trusting the pid.
   [procps-ng](https://gitlab.com/procps-ng/procps)

5. **Takeaway.** The `(pid, comm, starttime)` triple is exactly the
   industry-standard identity check for "a PID I do not parent but must
   verify." The pool's design mirrors systemd/psmisc rather than
   supervisord/daemontools, which is correct given the lease owner is not a
   child of the pool.

### 6. bash strict-mode gotchas (directly relevant under `set -euo pipefail`)

1. **SC2155 — declare and assign separately.** `local x="$(cmd)"` masks the
   exit status of `cmd` because `local` is itself a builtin whose own status
   (0) replaces `$?`. Under `set -e` this *hides* failures rather than
   triggering them, so you get silent wrong behavior instead of a controlled
   `return`. Fix:
   ```bash
   local comm                          # declare first
   comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || comm=""
   ```
   [ShellCheck SC2155](https://www.shellcheck.net/wiki/SC2155)

2. **`cat /missing` aborts under `set -e`.** Any unguarded read of a path that
   may not exist (a process can die mid-function) will terminate the script.
   Guard with redirection + `|| true` or wrap in `if`:
   ```bash
   comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || comm=""
   ```
   [Bash manual: The Set Builtin (errexit)](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin)

3. **`[[ -e ... ]]` as a bare statement triggers `set -e` on failure.** A
   freestanding `[[ -e /proc/$pid ]]` that evaluates false is a non-zero
   command status and aborts. Always use it in a control-flow context
   (`if [[ ... ]]; then`, `[[ ... ]] && ...`, `[[ ... ]] || return 1`).
   [Bash manual: Conditional Constructs](https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs)

4. **`$(...)` strips trailing newlines** (see §1.3). This is *helpful* here:
   `/proc/<pid>/comm`'s trailing `\n` vanishes in `c="$(cat ...)"`, so the
   stored and read values both lack it and compare cleanly. If you instead
   read with the `read` builtin, use `IFS= read -r` to avoid backslash
   mangling and IFS trimming.
   [Bash manual: Command Substitution](https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution)

5. **`set -u` (nounset) requires initialization.** `expected_starttime`/`expected_comm`
   must be passed or defaulted; referencing an unset positional aborts.
   Always quote positionals (`"$1"`) and guard arity if callers are untrusted.
   [Bash manual: The Set Builtin (nounset)](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin)

6. **`pipefail` + pipelines.** If you write `cat ... | awk ...` under
   `pipefail`, a failed `cat` (process died) makes the pipeline fail. Prefer
   `<<<` here-strings (`awk '{print $20}' <<<"$rest"`) to avoid a subshell +
   pipe, and capture the result with `|| ` fallback.
   [Bash manual: Pipelines (pipefail)](https://www.gnu.org/software/bash/manual/bash.html#Pipelines)

7. **Always quote variables** (`"$pid"`, `"$comm"`, `"$expected_starttime"`).
   `comm` may contain spaces (§1.4); an unquoted expansion word-splits and
   globs, corrupting the `[[ ]]` comparison.
   [Bash manual: Shell Expansions / Word Splitting](https://www.gnu.org/software/bash/manual/bash.html#Word-Splitting)

---

## Reference implementations in the wild

- **psmisc** (C, `/proc/[pid]/stat` scanning with identity comparison) —
  `killall`/`pidof`/`fuser`. The canonical "scan `/proc`, match by stat
  fields" reference.
  https://github.com/psmisc/psmisc
- **procps-ng** (C, libprocps) — `ps`/`pgrep` read `starttime` from
  `/proc/[pid]/stat`; `ps -o lstart/etimes` expose it.
  https://gitlab.com/procps-ng/procps
- **systemd** (C) — `sd_notify` + recorded `(pid, starttime)` for
  `Type=forking`/`notify` services; PID recycling detection in
  `src/core/service.c` / unit main-PID tracking.
  https://github.com/systemd/systemd
- **procfs parsing idiom (documentation)** — kernel `filesystems/proc.rst`
  documents the stat fields and the "comm may contain spaces/parens" caveat
  that drives the `${s##*) }` strip used above.
  https://www.kernel.org/doc/html/latest/filesystems/proc.html
- **pidfile + starttime pattern** — common in init/pidfile libraries
  (e.g., `liblockfile`, OpenRC `start-stop-daemon`, Debian
  `startpar`): write `pid` to a pidfile, then on reopen verify `starttime`
  before trusting the PID. (No single canonical repo; cited for pattern
  provenance.)

---

## Sources

- Kept:
  - proc(5) — `/proc/[pid]/comm`, `/proc/[pid]/stat`, `pid_max`, `hidepid`
    (https://man7.org/linux/man-pages/man5/proc.5.html) — primary definition of
    every field and behavior this function depends on.
  - kernel proc.rst (https://www.kernel.org/doc/html/latest/filesystems/proc.html)
    — authoritative kernel-side stat-field table and parsing caveats.
  - kernel UAPI `sched.h` `TASK_COMM_LEN=16`
    (https://github.com/torvalds/linux/blob/master/include/uapi/linux/sched.h)
    — source of the 15-usable-char limit.
  - kernel `fs/proc/base.c` `comm_show`
    (https://github.com/torvalds/linux/blob/master/fs/proc/base.c) — source of
    the trailing newline.
  - kill(2) (https://man7.org/linux/man-pages/man2/kill.2.html) — ESRCH vs
    EPERM, the `kill -0` false-dead trap.
  - ShellCheck SC2155 (https://www.shellcheck.net/wiki/SC2155) — declare-before-assign.
  - GNU Bash Manual — The Set Builtin, Command Substitution, Conditional
    Constructs, Pipelines, Word Splitting
    (https://www.gnu.org/software/bash/manual/bash.html).
- Dropped:
  - Generic "how to check if a process is running" blog posts — SEO-heavy,
    frequently repeat the `kill -0` footgun without the EPERM caveat; superseded
    by kill(2) and proc(5).
  - Stack Overflow answers conflating `kill -0` with `/proc` existence without
    the permission distinction — inaccurate for cross-UID cases.

---

## Gaps

- **No live web fetch this run.** This environment exposes only file I/O tools
  (no `web_search`/HTTP). All content above is from established kernel/shell
  behavior; URLs are canonical and stable, but the exact heading anchors
  (e.g. the URL-encoded `#/proc/[pid]/comm` fragment) were not verified live.
  Suggested next step: open each URL once and confirm the cited section text;
  proc(5) and proc.rst are the two highest-value to spot-check.
- **`comm` with embedded newline/special bytes** (settable via `prctl`) is a
  theoretical edge case for exact string comparison; not a practical concern
  for a fixed-name pool owner like `pi`, but worth a one-line note in the
  function's doc comment.
- **`_pool_get_starttime` helper** is referenced but assumed to exist; if it
  does not yet use the `${s##*) }` strip-before-`awk` idiom (§2.5), it is
  likely field-count-buggy for any `comm` containing spaces. Recommend
  auditing that helper in the same change.
- **Cross-UID/hidepid scenarios** are documented for completeness; they do not
  apply to same-UID pool owners but should be a code comment so future
  multi-user deployments don't switch to `kill -0` and reintroduce the
  false-dead trap.

---

## Acceptance report

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Produced the requested research brief on Linux process liveness + PID-recycling-safe identity verification covering all 6 specified questions with citations, written to the exact authoritative output path. No scope widening: output is a research/plan artifact only; no source/runtime code was modified."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/97917b74/plan/001_0f759fe2777c/P1M2T2S1/research/liveness-and-pid-recycling.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "write research brief to authoritative output path",
      "result": "passed",
      "summary": "Created the markdown research brief at the runtime-authoritative path; file contains summary, 6 numbered findings sections, reference implementations, sources, gaps, and this acceptance report."
    }
  ],
  "validationOutput": [
    "Research file written to /home/dustin/projects/agent-browser-pool/.pi-subagents/artifacts/outputs/97917b74/plan/001_0f759fe2777c/P1M2T2S1/research/liveness-and-pid-recycling.md",
    "Covers all 6 required questions: comm semantics; starttime field 22 / PID recycling; liveness methods incl. kill -0 EPERM false-dead; TOCTOU best-effort; supervisor approaches (systemd/supervisord/daemontools/psmisc); bash strict-mode gotchas (SC2155, set -e, $() newline stripping, RHS pattern matching, pipefail).",
    "Reference implementations section included with psmisc/procps/systemd/kernel-doc links.",
    "Authoritative URLs included: man7 proc.5/kill.2/prctl.2/sd_notify.3/systemd.service.5, kernel.org proc.rst, torvalds/linux sched.h + fs/proc/base.c, shellcheck SC2155, GNU bash manual."
  ],
  "residualRisks": [
    "No live web verification performed (no web_search/HTTP tool in this environment). All content is from established, stable kernel/bash behavior; canonical URLs provided but heading anchors not spot-checked live.",
    "Exact URL section anchors (e.g. encoded #/proc/[pid]/comm fragments) should be verified once before external citation."
  ],
  "noStagedFiles": true,
  "diffSummary": "Single new file: research brief (.md) at the runtime-authoritative output path. No repository source/runtime/test files touched; no git add performed.",
  "reviewFindings": [
    "no blockers — note for parent: the referenced _pool_get_starttime helper should be audited to confirm it uses the strip-before-awk idiom (field 22 = field 20 after removing pid+(comm)), otherwise it miscounts when comm contains spaces."
  ],
  "manualNotes": "This is a research/planning artifact (criterion-1 = 'implement the requested change without widening scope' interpreted as: deliver exactly the requested research brief, no code edits). The 'tests-added/commands-run' fields are adapted since this is a documentation/research task, not a code-change task. If the parent expects code changes (not a brief), this task scope should be clarified."
}
```
