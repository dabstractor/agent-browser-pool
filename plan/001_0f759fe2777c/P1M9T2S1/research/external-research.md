# Research: Bash patterns for a CONCURRENCY / mutual-exclusion test (parallel subshells → distinct lanes)

> Scope: patterns for the PRD §2.18 concurrency test — spawn N parallel subshells (simulating N agents), each `acquire`s a real headless-Chrome lane under a SHARED pool+lock, then assert distinct lane numbers / ports / Chrome PIDs and full cleanup.

## Summary
The canonical pattern is: the parent sets up **one** shared temp-state root and exports it; it spawns N `( export AGENT_BROWSER_POOL_OWNER_PID=…; … ) &` subshells, captures each PID via `$!`, then waits **per-PID** with a loop (`wait "$p" || fail=1`) — never bare `wait` (which masks child failures by returning 0). Each subshell writes its lane/port/chrome_pid to a **per-job temp file**; the parent reads them after `wait` and asserts distinctness with a `sort | uniq -d` (empty = all distinct) or associative-array dedup. Cleanup is asserted with **boolean `pgrep -f -- "user-data-dir=$ROOT" >/dev/null` inside an `if`** (never bare, never `pgrep -c`). The SUT's own correctness rests on **`flock`** auto-releasing on subshell/fd exit, which is what serializes the `acquire` and guarantees distinct lanes.

---

## Findings

### 1. Bash job control for parallel subshells (`&` / `$!` / `wait`)

1. **Backgrounding a subshell:** `( … ) &` runs a compound command in a child process in the background; `$!` immediately after expands to the PID of the last backgrounded job. [Bash Manual — Job Control Basics](https://www.gnu.org/software/bash/manual/html_node/Job-Control-Basics.html)
2. **`wait` semantics (verbatim from the manual):** for `wait [id …]`, "Wait until the child process specified by each process ID pid or job specification jobspec exits and **return the exit status of the last command waited for.** If the job terminates abnormally, the return status is greater than 127. If id specifies a non-existent process or job, the return status is **127**." Critically: "**If neither jobspec nor pid is supplied, the wait builtin waits for all currently active child processes, and the return status is zero.**" [Bash Manual — Bourne Shell Builtins, index `wait`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-wait)
3. **Consequence:** bare `wait` (no args) **always returns 0**, so it **cannot** detect a failing subshell. To detect failures you MUST wait per-PID: `wait "$pid" || fail=1`. `wait -n` (Bash 4.3+) waits for the *next* child to exit; `wait -p var` (Bash 5.1+) records which PID exited — neither needed here. [Bash Manual — Bourne Shell Builtins](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-wait)

### 2. Per-subshell distinct env vars

4. **Temporary single-command assignment:** `VAR=val command args` sets `VAR` in the environment of *only* `command`. [Bash Manual — Environment](https://www.gnu.org/software/bash/manual/html_node/Environment.html)
5. **Subshell-scoped export:** `( export VAR=val; … ) &` exports `VAR` for only that subshell and its children. Because the environment is copied at `fork`, **parent and sibling subshells are unaffected**. A subshell that does `export AGENT_BROWSER_POOL_OWNER_PID=…` therefore gives N parallel jobs N distinct owner PIDs with zero cross-talk. [Bash Manual — Environment](https://www.gnu.org/software/bash/manual/html_node/Environment.html)
6. **`$$` vs `$BASHPID` gotcha:** `$$` always expands to the **parent** shell's PID even inside a subshell; `$BASHPID` expands to the **actual** current (sub)shell PID. For a genuinely distinct owner PID per subshell use `$BASHPID`. [Bash Manual — Bash Variables, index `BASHPID`](https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASHPID)

### 3. Collecting distinct results from parallel jobs (tmp-file-per-job)

7. **Recommended pattern:** each job writes its result (lane / port / chrome_pid) to a file **named by job index**; the parent reads them **after `wait`**. This is lock-free, race-free (each job writes a different path), and trivially parses. A shared append under `flock` is *overkill* here.
8. **Read with `mapfile`, never `arr=($(…))`** (word-splitting + glob-expansion). [Wooledge BashFAQ/005 — reading line-by-line](https://mywiki.wooledge.org/BashFAQ/005); [Wooledge BashFAQ/050 — command in a variable](https://mywiki.wooledge.org/BashFAQ/050)

### 4. `set -e` interaction with `wait`

9. **Bare `wait || true` loses every child's exit code** (returns 0 regardless) — useless for asserting all-subshells-succeeded.
10. **Per-PID loop preserves codes:** `for p in "${pids[@]}"; do wait "$p" || fail=1; done`.
11. **errexit exemptions:** "The shell does not exit if the command that fails is … part of the test following the `if` or `elif` reserved words, part of any command executed in a `&&` or `||` list except the command following the final `&&` or `||`, … or if the command's return value is being inverted with `!`." So `wait "$p" || fail=1` and `if wait "$p"; then …` are exempt and do NOT abort the script. [Bash Manual — The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html); [Wooledge BashFAQ/105 — "Why doesn't set -e do what I expect?"](https://mywiki.wooledge.org/BashFAQ/105)

### 5. `flock` for mutual exclusion (the SUT's lane-serialization mechanism)

12. **Canonical idiom:** `( flock 9; critical_section ) 9>lockfile` — open the lockfile on fd 9, take an exclusive (`-x`, default) advisory lock, run the critical section, and the lock auto-releases when fd 9 closes (i.e., when the subshell exits). [linux.die.net — flock(1)](https://linux.die.net/man/1/flock)
13. **Auto-release on SIGKILL:** locks are tied to the open file description; when the holding process is killed (even SIGKILL) the kernel closes its fds, releasing the lock. This is exactly why the SUT can safely use flock to guarantee distinct lane allocation even if an agent is killed mid-acquire. [linux.die.net — flock(1)](https://linux.die.net/man/1/flock)

### 6. Verifying distinctness

14. **`sort | uniq -d` idiom:** `printf '%s\n' "${vals[@]}" | sort | uniq -d` prints any duplicates; **empty output = all values distinct**.
15. **Associative-array dedup** (no external process): `declare -A seen; for v in "${vals[@]}"; do [[ -n "${seen[$v]:-}" ]] && dup=1; seen[$v]=1; done`.
16. **Zero/empty guard:** combine the duplicate check with an explicit non-empty/non-zero check so a failed `acquire` (returning `0` or `""`) can't masquerade as a valid distinct lane.

### 7. Asserting process cleanup (scoped `pgrep`)

17. **Match the full command line:** `pgrep -f -- "user-data-dir=$ROOT"` matches against the *entire* command line, so it catches Chrome processes scoped to this test's ephemeral root. Returns **0 if a match exists, 1 if none**. [man7.org — pgrep(1)](https://man7.org/linux/man-pages/man1/pgrep.1.html)
18. **`pgrep` rc 1 aborts under `set -e`** → must always be used in an `if` condition (e.g. `if pgrep … >/dev/null; then … FAIL …`), never as a bare statement.
19. **Use boolean `pgrep … >/dev/null`, never `pgrep -c`:** one Chrome launches many processes (parent, renderer, GPU, utility); a count-based assertion is fragile. A boolean "any match?" check is what "no Chrome left" actually means. [man7.org — pgrep(1)](https://man7.org/linux/man-pages/man1/pgrep.1.html)

### 8. Timing / readiness + robust `wait`

20. **`wait` blocks until all waited jobs finish — no explicit `sleep` is needed for join.** (`sleep`-based readiness is an anti-pattern.) [Wooledge — ProcessManagement](https://mywiki.wooledge.org/ProcessManagement)
21. **Hard wall-clock cap per job with `timeout`:** `timeout SECS bash -c '…'` kills the wrapped command if it hangs (e.g. Chrome never becomes ready); `timeout` exits **124** on kill. [man7.org — timeout(1)](https://man7.org/linux/man-pages/man1/timeout.1.html)
22. **Orphan-Chrome risk:** if a job is killed mid-boot, Chrome children may linger. The SUT's reaper cleans these lazily; the **test must still explicitly `release all` (and/or reap) in a cleanup trap** so no Chrome escapes the assertion.

### 9. Hermetic isolation for parallel tests

23. **Shared state root + distinct owner PID is the core invariant:** the parent sets up **ONE** `AGENT_BROWSER_POOL_STATE` / `AGENT_CHROME_EPHEMERAL_ROOT` / `AGENT_CHROME_MASTER` / `HOME` and exports it; every subshell **inherits the same** state (so they contend for the SAME pool and the SAME lock file under that state dir) and adds its **own** `AGENT_BROWSER_POOL_OWNER_PID`. The shared lock file is what serializes `acquire` → distinct lanes. [Bash Manual — Environment](https://www.gnu.org/software/bash/manual/html_node/Environment.html)

### 10. Common pitfalls (with mitigations)

24. **`mapfile -t arr < <(cmd)`** for newline-delimited output — **not** `arr=($(cmd))` (splits on IFS + expands globs). [Wooledge BashFAQ/005](https://mywiki.wooledge.org/BashFAQ/005)
25. **`(( ))` arithmetic under `set -e`:** bare `(( 0 ))` has value 0 → exit status 1 → **aborts the script**. Use `if (( expr )); then …` (exempt) or `(( expr )) || true`. [Wooledge BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)
26. **`local x="$(cmd)"` masks failure (ShellCheck SC2155):** declare first, assign separately → `local x; x="$(cmd)"`. [ShellCheck SC2155](https://www.shellcheck.net/wiki/SC2155)
27. **Leaked background jobs on failure:** register a `trap` that `kill`s all tracked PIDs (and releases/cleans up) so a failing assertion can't strand Chrome processes.
28. **`set -u` with possibly-empty arrays:** `${arr[@]}` can error on an empty array in older bash; use `${arr[@]:-}` (or `${arr[@]+…}`) defensively. [Wooledge BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)
29. **`wait` on an already-reaped job returns 127** (same as "unknown pid") — don't interpret 127 as a fresh failure; capture exit codes in the per-PID loop on the first wait.

---

## Concrete recommended patterns

### (1) Parallel spawn-and-wait — `( export VAR; … ) &` + per-PID `wait`

```bash
#!/usr/bin/env bash
set -euo pipefail

N=4
tmp_root="$(mktemp -d)"
mkdir -p "$tmp_root/results"
trap 'rm -rf "$tmp_root"' EXIT

# ONE shared state root -> all subshells contend for the SAME pool + SAME lock file
export AGENT_BROWSER_POOL_STATE="$tmp_root/state"
export AGENT_CHROME_EPHEMERAL_ROOT="$tmp_root/ephemeral"
export AGENT_CHROME_MASTER="$tmp_root/chrome"   # use the real var name the SUT expects
export HOME="$tmp_root/home"
mkdir -p "$AGENT_BROWSER_POOL_STATE" "$AGENT_CHROME_EPHEMERAL_ROOT" "$HOME"

declare -a pids=()
for i in $(seq 1 "$N"); do
  (
    # $BASHPID (NOT $$) -> genuinely distinct PID per subshell
    export AGENT_BROWSER_POOL_OWNER_PID="$BASHPID"
    export JOB_INDEX="$i"
    export JOB_RESULT_FILE="$tmp_root/results/job_$i"

    # ... acquire a lane (boots real headless Chrome), record result, release ...
    # (see snippets (2) and (6) for the body)
  ) &
  pids+=("$!")                       # capture THIS subshell's PID
done

# join: wait PER-PID so child failures are NOT masked (bare `wait` always -> 0)
fail=0
for p in "${pids[@]}"; do
  if ! wait "$p"; then               # errexit-exempt inside `if`
    echo "FAIL: subshell pid=$p exited $?" >&2
    fail=1
  fi
done
if (( fail )); then exit 1; fi        # if-guards the arithmetic under set -e
```

> Why not bare `wait`: the manual states no-arg `wait` "return[s] … zero" — a crashing subshell would pass silently. The per-PID loop is mandatory for a correctness assertion.

### (2) Collect results via tmp-file-per-job (written by each subshell, read by parent after `wait`)

```bash
# ---- inside each subshell ----
# acquire yields lane, port, chrome_pid (adapt to your SUT's real API):
read -r lane port chrome_pid < <(acquire)   # or however the SUT reports them
printf '%s\n%s\n%s\n' "$lane" "$port" "$chrome_pid" > "$JOB_RESULT_FILE"
release "$lane"

# ---- in the parent, AFTER `wait` ----
declare -a lanes=() ports=() chrome_pids=()
for i in $(seq 1 "$N"); do
  f="$tmp_root/results/job_$i"
  [[ -s "$f" ]] || { echo "FAIL: job $i produced no result" >&2; fail=1; continue; }
  mapfile -t r < "$f"                       # NOT r=($(<"$f"))
  lanes+=("${r[0]}"); ports+=("${r[1]}"); chrome_pids+=("${r[2]}")
done
if (( fail )); then exit 1; fi
```

### (3) Distinctness assert — `uniq -d` (empty = distinct) + zero/empty guard

```bash
all_distinct_and_nonzero() {           # returns 0 iff all args distinct, non-empty, non-"0"
  local v
  local -A seen=()
  for v in "$@"; do
    [[ -n "$v" && "$v" != 0 ]] || return 1
    [[ -z "${seen[$v]:-}" ]] || return 1
    seen["$v"]=1
  done
  return 0
}

if ! all_distinct_and_nonzero "${lanes[@]}";       then echo "FAIL lanes"        >&2; exit 1; fi
if ! all_distinct_and_nonzero "${ports[@]}";        then echo "FAIL ports"        >&2; exit 1; fi
if ! all_distinct_and_nonzero "${chrome_pids[@]}";  then echo "FAIL chrome_pids"  >&2; exit 1; fi

# one-liner alternative (both must be empty):
bad=$(printf '%s\n' "${lanes[@]}" | grep -Exe '0' -e '' || true)   # zero or empty -> BAD
dups=$(printf '%s\n' "${lanes[@]}" | sort | uniq -d)              # any duplicate -> BAD
[[ -z "$bad" && -z "$dups" ]] || { echo "FAIL: bad/empty/dup lanes: [$bad][$dups]" >&2; exit 1; }
```

> `grep … || true` is required: grep's "no match" rc=1 (the *good* case) would abort under `set -e`.

### (4) Cleanup assert — scoped `pgrep` (boolean, inside `if`)

```bash
assert_no_chrome_under_root() {
  local root="$1"
  if pgrep -f -- "user-data-dir=$root" >/dev/null; then    # rc0 = match(BAD), rc1 = none(GOOD)
    echo "FAIL: Chrome still running under $root" >&2
    pgrep -af -- "user-data-dir=$root" >&2                  # -a shows the full cmd for debugging
    return 1
  fi
  return 0
}
assert_no_chrome_under_root "$tmp_root" || exit 1
```

> Never `pgrep -c` (one Chrome = many processes; count is the wrong predicate). Never bare `pgrep` under `set -e` (rc 1 aborts the "all clean" case).

### (5) Hermetic shared-state pattern (one root, N owner PIDs)

```bash
tmp_root="$(mktemp -d)"; trap 'rm -rf "$tmp_root"' EXIT
# ---- shared by ALL N subshells (so they contend for the SAME pool/lock) ----
export AGENT_BROWSER_POOL_STATE="$tmp_root/state"
export AGENT_CHROME_EPHEMERAL_ROOT="$tmp_root/ephemeral"
export AGENT_CHROME_MASTER="$tmp_root/chrome"
export HOME="$tmp_root/home"
mkdir -p "$AGENT_BROWSER_POOL_STATE" "$AGENT_CHROME_EPHEMERAL_ROOT" "$HOME"

for i in $(seq 1 "$N"); do
  (
    export AGENT_BROWSER_POOL_OWNER_PID="$BASHPID"   # ONLY this subshell; siblings unaffected
    # acquire contends for "$AGENT_BROWSER_POOL_STATE"/lock -> serialized -> distinct lane
    :
  ) &
  pids+=("$!")
done
```

### (6) Timeout-wrapping pattern (hard per-job cap; release-all in cleanup)

```bash
# per-job body wrapped in `timeout` so a hung Chrome boot can't hang the test.
# Pass everything needed via INHERITED env (no parent-shell interpolation inside '' )
for i in $(seq 1 "$N"); do
  (
    export JOB_INDEX="$i"
    export JOB_RESULT_FILE="$tmp_root/results/job_$i"
    if timeout 120 bash -c '
          export AGENT_BROWSER_POOL_OWNER_PID="$BASHPID"
          source ./agent-browser-pool.sh || exit 1
          read -r lane port chrome_pid < <(acquire) || exit 1
          printf "%s\n%s\n%s\n" "$lane" "$port" "$chrome_pid" > "$JOB_RESULT_FILE"
          release "$lane"
        '; then
      :                       # job ok
    else
      rc=$?                   # 124 == timeout killed it
      echo "job $JOB_INDEX failed rc=$rc" >&2
      exit "$rc"
    fi
  ) &
  pids+=("$!")
done

# fail-safe cleanup: kill tracked PIDs + release all if the parent assertion path fails
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp_root"
}
trap cleanup EXIT
```

### (7) Pitfalls → mitigations (quick reference)

| # | Pitfall | Mitigation |
|---|---------|-----------|
| a | `arr=($(cmd))` word-splits + globs | `mapfile -t arr < <(cmd)` ([BashFAQ/005](https://mywiki.wooledge.org/BashFAQ/005)) |
| b | bare `(( 0 ))` aborts under `set -e` | `if (( expr )); then` or `(( expr )) || true` ([BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105)) |
| c | `local x="$(cmd)"` masks exit status (SC2155) | `local x; x="$(cmd)"` ([SC2155](https://www.shellcheck.net/wiki/SC2155)) |
| d | failing test strands background Chrome | `trap` that `kill`s tracked PIDs + `release all` |
| e | `set -u` + empty array | `${arr[@]:-}` / `${arr[@]+…}` |
| f | `wait` on already-reaped pid → 127 | capture codes in the per-PID loop on first wait; don't treat 127 as fresh failure |
| g | `$$` is parent PID in a subshell | use `$BASHPID` for distinct per-subshell PID |
| h | bare `wait` always returns 0 | per-PID `wait "$p" || fail=1` loop |

---

## Sources

**Kept (authoritative):**
- GNU Bash Manual — Job Control Basics — https://www.gnu.org/software/bash/manual/html_node/Job-Control-Basics.html (`&`, `$!`, jobs)
- GNU Bash Manual — Bourne Shell Builtins (`wait`) — https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-wait (exact `wait` semantics incl. no-arg → 0, per-pid → status, 127 on unknown)
- GNU Bash Manual — Environment — https://www.gnu.org/software/bash/manual/html_node/Environment.html (export + subshell inheritance)
- GNU Bash Manual — Bash Variables (`BASHPID`) — https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASHPID
- GNU Bash Manual — The Set Builtin — https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html (`set -e` exemptions: if/elif, &&/||, pipelines, `!`)
- Wooledge BashFAQ/105 — Why doesn't `set -e` do what I expect? — https://mywiki.wooledge.org/BashFAQ/105
- Wooledge BashFAQ/005 — reading data line-by-line — https://mywiki.wooledge.org/BashFAQ/005 (`mapfile`, avoid `$(…)`)
- Wooledge BashFAQ/050 — putting a command in a variable — https://mywiki.wooledge.org/BashFAQ/050 (word-splitting)
- Wooledge — ProcessManagement — https://mywiki.wooledge.org/ProcessManagement (don't `sleep`-poll for readiness)
- linux.die.net — flock(1) — https://linux.die.net/man/1/flock (canonical `( flock 9; … ) 9>lockfile`; auto-release on fd close)
- man7.org — pgrep(1) — https://man7.org/linux/man-pages/man1/pgrep.1.html (`-f` full match; rc 1 on no-match; `-c` caveat)
- man7.org — timeout(1) — https://man7.org/linux/man-pages/man1/timeout.1.html (exit 124 on kill)
- ShellCheck — SC2155 — https://www.shellcheck.net/wiki/SC2155

**Dropped:** none excluded — all task-referenced sources retained.

## Gaps

- **No live web fetch was performed.** This brief was compiled from authoritative knowledge of the cited canonical references (GNU Bash manual, man7.org / linux.die.net man pages, wooledge.org wikis, ShellCheck). The URLs are the stable, canonical versions and are consistent with the task's own references; recommend a quick spot-check that each URL resolves before pasting into the test's header comment block.
- **SUT-specific API shapes are illustrative** (`acquire` / `release` argument and return conventions, exact env-var names beyond `AGENT_BROWSER_POOL_OWNER_PID`, and the precise lock-file path under `AGENT_BROWSER_POOL_STATE`). These must be reconciled against the real `agent-browser-pool` source when writing the test — the bash *patterns* here are generic and correct regardless.
- **Exit-code 124 vs 137 vs 143 nuance** under `timeout`/signals is summarised; if the test asserts *specific* killed-job codes, verify against the actual `timeout`/`kill` behaviour on the target OS.

## Supervisor coordination
None needed — self-contained research deliverable. Returned normally (no blocking decision required).

---

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Research-only deliverable produced at the authoritative output path with the requested structure: 10 numbered findings + 7 concrete bash code patterns + pitfalls table, all with inline canonical citations. No project source/test files were modified; scope held to research."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Deliverable is a single self-contained markdown brief at the exact runtime output path; findings cite stable URLs (GNU Bash manual, man7.org, linux.die.net, wooledge.org, ShellCheck) suitable for independent review."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/1c804ff7/plan/001_0f759fe2777c/P1M9T2S1/research/external-research.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "(research task — no shell commands executed; artifact written via write tool)",
      "result": "passed",
      "summary": "Research brief written to authoritative output path; no project files touched."
    }
  ],
  "validationOutput": [
    "Deliverable covers all 10 requested research angles and all 7 requested concrete patterns (spawn/wait, tmp-file collection, distinctness assert, pgrep cleanup, hermetic state, timeout wrap, pitfalls).",
    "Corrected a typo in code snippet (1) (AGROME_CHROME_MASTER -> AGENT_CHROME_MASTER) so all patterns are copy-pasteable.",
    "No live web fetch performed (no web tool available); URLs are canonical/stable and consistent with task references; flagged in Gaps for spot-check.",
    "No project source or test files modified — research only."
  ],
  "residualRisks": [
    "Brief compiled from authoritative knowledge, not live page fetches; reviewer should spot-check URL resolution.",
    "SUT-specific API/env-var/lock-path details (acquire/release signatures) are illustrative and must be reconciled with the real agent-browser-pool source when implementing the test."
  ],
  "noStagedFiles": true,
  "diffSummary": "Created one new file: the research brief at .pi-subagents/artifacts/outputs/1c804ff7/plan/001_0f759fe2777c/P1M9T2S1/research/external-research.md. No other files changed.",
  "reviewFindings": [
    "no blockers (research artifact only; no code/test changes to review)"
  ],
  "manualNotes": "The brief's key actionable takeaways for the implementer: (1) use per-PID `wait \"$p\" || fail=1` — never bare `wait` (returns 0); (2) one shared STATE/EPHEMERAL_ROOT/MASTER/HOME + per-subshell `$BASHPID` owner PID; (3) tmp-file-per-job for results, read with `mapfile` after wait; (4) boolean `pgrep -f … >/dev/null` inside `if` for cleanup, never bare/`-c`; (5) `timeout 120 bash -c '…'` (exit 124) with a release-all cleanup trap. SUT API shapes are placeholders to reconcile with real source."
}
```
