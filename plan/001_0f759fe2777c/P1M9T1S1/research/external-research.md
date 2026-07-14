# Research: Hand-rolled `bash` test-framework patterns for `test/validate.sh`

Scope: a single self-contained `bash` script that sources `lib/pool.sh` and tests
`bin/agent-browser`, `bin/agent-browser-pool`. It is **not** bats/shunit2. It defines
assertion helpers (`assert_eq`, `assert_lane_exists`, `assert_lane_gone`,
`assert_no_chrome`, `assert_no_dir`), a `setup`/`teardown` pair, and a
`run_test(name, fn)` runner that counts pass/fail and exits non-zero on any failure,
all under `set -euo pipefail`.

Every snippet below mirrors conventions already proven in `lib/pool.sh`:
`set -euo pipefail`; `local x; x="$(cmd)"` two-statement captures (SC2155-safe);
`[[ … =~ … ]] || return 1` / `|| pool_die`; `(( expr ))` only inside `if`; every
`kill`/`grep`/`pgrep`/`curl` guarded by `|| true` or an `if`.

> **Tooling caveat (read this):** This sandbox exposes no web tooling, so the URLs
> below were not live-fetched. They are canonical, version-stable primary links
> (man-pages project on `man7.org`, `kernel.org` documentation, the `torvalds/linux`
> tree, the ShellCheck wiki, the Wooledge "Greg's Wiki", and the GNU bash manual).
> `lib/pool.sh` was read directly and its already-host-verified findings are cited as
> ground truth. See **Gaps**.

---

## Summary

1. The robust pattern is: **source `lib/pool.sh` once at load; run each test body in a
   subshell whose exit code is captured by an `if`, so a test failure is non-fatal to
   the harness**; gate the suite behind `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`.
2. `/proc/<pid>/comm` is set by the kernel to the **basename of the executed ELF
   (the `filename` arg to `execve(2))`, NOT `argv[0]`** — so `cp /bin/sleep /tmp/pi;
   /tmp/pi &` gives `comm == pi`, while `exec -a pi /bin/sleep` does not.
3. `starttime` is **field 22** of `/proc/<pid>/stat` (clock ticks since boot); it is
   stable per invocation and defeats PID recycling. Parse it by stripping everything
   up to and including the **last `)`** then taking field 20. The "NF-19" formula in
   PRD §2.19 is **wrong** (verified on-host in `lib/pool.sh`: it yields `vsize`/a
   signal field, not `starttime`); the correct from-the-right offset is **NF-30**.
4. Under `set -e`, the harness survives only because (a) test bodies run in subshells
   behind `if`, (b) every command that may legitimately return non-zero is wrapped in
   `if`/`|| true`, and (c) `(( … ))`, `local x=$(…)` (SC2155), and bare
   `grep`/`pgrep`/`curl` are never used as freestanding statements.
5. Hermetic isolation = `mktemp -d` for `HOME`/state/ephemeral root + a
   `trap cleanup EXIT INT TERM`, plus per-test `setup`/`teardown`.
6. Scope Chrome detection to the pool with `pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"`
   (the flag `lib/pool.sh`'s `pool_chrome_launch` writes), guarded by `if`/`|| true`.

---

## §1. Hand-rolled `run_test name fn`, setup/teardown, and the source-vs-execute gate

### 1.1 The source-vs-execute idiom

`${BASH_SOURCE[0]}` is the path the file was *sourced/executed from*; `$0` is the name
of the *current top-level script*. They are equal only when the file is run directly
([Bash manual — Bash Variables, `BASH_SOURCE`][bashvars]). This lets `validate.sh`
be sourced (to reuse `assert_*` ad hoc) **or** run as a suite:

```bash
# Run the suite only when executed, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

This is the idiomatic test/self-test gate recommended across Greg's Wiki
([BashFAQ][gregfaq]) and enforced by ShellCheck in many projects. `bin/agent-browser`
and `bin/agent-browser-pool` already use `${BASH_SOURCE[0]}` for the symlink-safe
`readlink -f` bootstrap, so the harness matches the repo.

### 1.2 The runner: setup/teardown + subshell isolation + counters

The crucial design rule: **a test failure must increment the fail counter, never kill
the harness.** The clean way under `set -euo pipefail` is to run the body in a
subshell whose exit status is the condition of an `if` — commands used as `if`
conditions are **exempt from `errexit`** ([BashFAQ/105][greg105]). `setup`/`teardown`
run in the parent so the temp root they create is visible to teardown.

```bash
set -euo pipefail   # NB: sourcing lib/pool.sh already activates this (pool.sh line 17)

PASS=0; FAIL=0
declare -a FAILED_TESTS=()

TEST_ROOT=""      # set by setup(); removed by teardown()

setup() {
    TEST_ROOT="$(mktemp -d -t abpool-validate.XXXXXX)"   # hermetic root
    export HOME="$TEST_ROOT/home"; mkdir -p "$HOME"      # never touch real ~/
    export AGENT_BROWSER_POOL_STATE="$TEST_ROOT/state"
    export AGENT_CHROME_EPHEMERAL_ROOT="$TEST_ROOT/active"
    export AGENT_CHROME_MASTER="$TEST_ROOT/master"; mkdir -p "$AGENT_CHROME_MASTER"
    export AGENT_BROWSER_POOL_DISABLE=1                  # tests assert lib fns, not the wrapper
    pool_config_init    # MUTABLE globals → re-runnable per test (pool.sh contract)
    pool_state_init     # idempotent mkdir/touch
}

teardown() {
    [[ -n "${TEST_ROOT:-}" ]] && rm -rf -- "$TEST_ROOT" 2>/dev/null || true
}

# run_test NAME FN
#   Runs setup in the parent, the body in a SUBSHELL (set -e ON so the first failing
#   assert ends the test), then teardown in the parent. The body's non-zero exit is
#   captured by `|| rc=$?` → errexit-safe → the harness never aborts on a test fail.
run_test() {
    local name="$1" fn="$2" rc=0
    printf '%s\n' "== $name"
    setup
    ( set -e; "$fn" ) || rc=$?
    teardown
    if (( rc == 0 )); then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name")
    fi
}
```

Notes that match `lib/pool.sh`'s discipline:

- `( set -e; "$fn" ) || rc=$?` — the `||` list makes the subshell's non-zero exit a
  controlled branch, so the harness survives. This is the *exact* mechanism the
  library relies on for `if pool_lane_is_stale …; then …` (rc 1/2 must not abort).
- `PASS=$((PASS+1))` uses the **`$(( ))` expansion form**, which is always errexit-safe.
  Never `(( PASS++ ))` as a statement — when `PASS==0` it returns 1 and aborts (see §4).
- `(( rc == 0 ))` is inside an `if`, so its "false→returns 1" case is exempt.
- A test body that calls a library function returning non-zero on the "happy" path
  (e.g. `pool_lease_read 99`, `pool_lease_find_mine`, `pool_lane_is_stale`) **must
  guard it** exactly as `lib/pool.sh` documents: `if …; then` or `… || true`. This is
  the same caller contract the wrapper/reaper obey.

### 1.3 Auto-discovery + non-zero exit on any failure

```bash
main() {
    local fn
    for fn in $(compgen -A function test_); do   # functions named test_*
        run_test "$fn" "$fn"
    done
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf 'FAILED: %s\n' "${FAILED_TESTS[*]}" >&2
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

`(( FAIL > 0 ))` is the `if` condition (exempt); `exit 1` satisfies "non-zero on any
failure". `compgen -A function test_` enumerates only `test_*` functions (names have
no spaces → safe to word-split).

### 1.4 Real-world hand-rolled harnesses (cited for structure)

- **git's `t/test-lib.sh`** — the canonical hand-rolled shell harness. It defines
  `test_expect_success`, a `trap … EXIT` trash-directory cleanup, and strict-mode
  handling around each test snippet. [git/test-lib.sh][gittestlib]
- **sharness** — a dependency-free shell test framework *extracted from git's
  test-lib*, used by cgit/git-notes/etc. Demonstrates `test_expect_success NAME
  "snippet"` + `test_done` counting + `trash directory` isolation. [sharness][sharness]
- **bats** (for contrast only — out of scope here) runs each test in a **separate
  process**, which is the maximal-isolation version of the subshell trick above.

The subshell-per-test + `if`-capture + counter pattern in §1.2 is the distilled
essence shared by all three.

---

## §2. The "copy a binary to `/tmp/pi` so `/proc/<pid>/comm == pi`" trick

### 2.1 What the kernel actually sets `comm` to

`/proc/<pid>/comm` is the process's `task->comm`. Its **initial value is the basename
of the executed program** — the `filename` argument to `execve(2)` after the kernel's
internal (shebang) resolution — **not** `argv[0]`. A process may later overwrite it via
`prctl(PR_SET_NAME)`. Per [proc(5)][proc5] (`/proc/[pid]/comm`):

> "This file … is the same as the value … in field (2) of `/proc/[pid]/stat` … A
> thread can change this value … via `prctl(2)` `PR_SET_NAME` …"

and [prctl(2)][prctl2] (`PR_SET_NAME`):

> "sets the name of the calling thread … The name can be up to 16 bytes long,
> including the terminating null byte."  (`TASK_COMM_LEN`, see below)

The kernel assignment lives in `fs/exec.c` (`begin_new_exec()` /
`setup_new_exec()`), which calls `set_task_comm(current, kbasename(bprm->filename), …)`
— i.e. the basename of the **executable path**, never `argv[0]`. `argv[0]` is stored
separately and surfaced only in `/proc/[pid]/cmdline`.

### 2.2 The two test fixtures — only the copy works

```bash
# ✅ WORKS: the executed ELF's basename IS "pi".
cp /bin/sleep /tmp/pi
/tmp/pi 600 &            # execve("/tmp/pi", ["/tmp/pi","600"], envp)
PID=$!
read -r comm < "/proc/$PID/comm"
[[ "$comm" == "pi" ]]    # TRUE — comm = kbasename("/tmp/pi") = "pi"

# ❌ DOES NOT WORK: bash `exec -a NAME CMD` only rewrites argv[0].
exec -a pi /bin/sleep 600 &   # execve("/bin/sleep", ["pi","600"], envp)
#   /proc/$!/comm stays "sleep" (basename of the real binary "/bin/sleep").
#   Only /proc/$!/cmdline[0] becomes "pi".
```

This is confirmed by the [bash manual (`exec -a`)][bashbuiltins]: "If `-a` is supplied,
the shell passes `name` as the zeroth argument to the executed command" — i.e. `name`
becomes `argv[0]` only; the binary path passed to `execve(2)` is still `/bin/sleep`.

This matters for `lib/pool.sh`'s owner resolver (`pool_owner_resolve`), which walks the
`ppid` chain reading `/proc/<pid>/comm` and comparing to the literal `"pi"`
(`AGENT_BROWSER_POOL_OWNER_PID` test-hook aside). To simulate a live `pi` owner with a
*real* process (not the env-var hook), you **must** copy a real binary to a file named
`pi` and exec it. `setsid`-launched Chrome in `pool_chrome_launch` follows the same
principle: `comm` derives from `$POOL_CHROME_BIN`'s basename.

### 2.3 `TASK_COMM_LEN` — "pi" is safe

`comm` is truncated to **15 bytes + NUL = 16 bytes** (`TASK_COMM_LEN`) in
[`include/uapi/linux/sched.h`][schedh]. [proc(5)][proc5] documents the 15-char limit on
`/proc/[pid]/comm`. `"pi"` is 2 bytes — zero truncation risk. (Long owner names like a
hypothetical `"agent-browser-daemon"` would be clipped to `"agent-browser-d"` — another
reason the pool keys on the fixed `"pi"` string.)

```bash
# Fixture helper: a throwaway "pi" process that lives N seconds.
spawn_fake_pi() {            # echo $! of a process whose /proc/$!/comm == "pi"
    local secs="${1:-600}"
    local bin
    bin="$(mktemp -d -t fakesh.XXXXXX)/pi"
    cp /bin/sleep "$bin"
    "$bin" "$secs" &           # basename("pi") → comm=="pi"
    echo "$!"
}
```

---

## §3. `starttime` extraction (field 22) — defeating PID recycling

### 3.1 The field, and why it defeats recycling

`/proc/<pid>/stat` field **22 (1-indexed) is `starttime`** — clock ticks since boot
(`sysconf(_SC_CLK_TCK)`, 100 on this host). [proc(5)][proc5] (`/proc/[pid]/stat`,
field list):

> "(22) starttime  %lu  The time the process started after system boot. … Since
> Linux 2.6, the value is expressed in clock ticks (divide by
> `sysconf(_SC_CLK_TCK)`)."

`starttime` is **monotonic per process invocation**: stable for the process's whole
life, and (because it strictly increases with boot time) **different** if a freed PID
is handed to a new process. The `(pid, comm, starttime)` triple is the identity key
`lib/pool.sh` uses in `pool_owner_alive` / `pool_lane_is_stale` (the anti-recycling
guard mandated by PRD §2.8/§2.19). This is also how systemd, psmisc, and procps-ng
disambiguate recycled PIDs.

### 3.2 The parenthesized-comm parsing gotcha (and why NF-19 is wrong)

Field 2 is `comm` wrapped in parentheses and **may contain spaces and parentheses**
(e.g. `"(Chrome Helper)"`), which shifts every later field for a naïve left-to-right
split. [proc(5)][proc5] therefore says to parse by locating the **last `)`** and
counting from there.

The robust method (this is `lib/pool.sh`'s `_pool_get_starttime`, host-verified
2026-07-12):

```bash
# Strip "pid (comm)" by deleting up to AND INCLUDING the LAST ')' (greedy),
# collapsing any spaces inside comm. Remaining tokens are fields 3..52.
# starttime (field 22 overall) == field 20 of the remainder (22 - 2 = 20).
_pool_get_starttime() {
    local pid="${1:-}" stat_line after start
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
    [[ -n "$stat_line" ]] || return 1
    after="${stat_line##*)}"                       # GREEDY longest prefix ending ')'
    start="$(awk '{print $20}' <<<"$after")"       # field 22 == remainder field 20
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$start"
}
```

Equivalent pipeline form: `sed 's/.*)//' /proc/$pid/stat | awk '{print $20}'`.

**Correcting the "NF-19" formula (PRD §2.19 / your brief §3):** reading field 22
"from the right" as `$(NF-19)` is **wrong**. `/proc/[pid]/stat` has **52** fields, so
field 22 is at `NF-30` from the right (`52 - 22 = 30`), not `NF-19`. The `NF-19`
formula assumes a fixed count of **41** fields (an old/incomplete count); `lib/pool.sh`
host-verified that `awk '{print $(NF-19)}' /proc/self/stat` yields a **non-starttime**
value (`4096` — a signal-mask/vsize field, field 33), **not** the correct starttime.
Prefer the greedy-`)`-strip → field-20 method, which is immune to the total-field-count
problem entirely. (When you *do* read from the right, use `$(NF-30)`.)

### 3.3 Comparison idiom for the harness

```bash
# Identity check: is the live PID still the SAME invocation recorded in the lease?
assert_same_starttime() {  # PID EXPECTED_STARTTIME
    local pid="$1" expected="$2" actual
    actual="$(_pool_get_starttime "$pid")" || { _fail "no stat for $pid"; return 1; }
    [[ "$actual" == "$expected" ]] \
        || { _fail "starttime mismatch (recycled? expected $expected got $actual)"; return 1; }
}
```

(Mirrors `pool_owner_alive`'s decision ladder: `/proc` exists → `comm == "pi"` →
`starttime` equals the stored value.)

---

## §4. `set -euo pipefail` hazards inside a test harness

`set -e` ("errexit") is famously not a safety net — see Greg's Wiki
[BashFAQ/105 — "Why doesn't set -e (or set -o errexit) do what I expected?"][greg105].
The harness keeps running only because every "may legitimately fail" command is
shielded. The four traps below all bite `lib/pool.sh` too (and it documents each).

### 4.1 `local x="$(failing_cmd)"` — SC2155 masks the failure (does *not* abort)

⚠️ **Correction to the brief:** `local x="$(failing_cmd)"` does **not** abort under
`set -e`. That is *the bug*. The `local` builtin always returns 0, so the command
substitution's non-zero status is **silently swallowed** — a real failure looks like
success. [ShellCheck SC2155][sc2155]:

> "Declare and assign separately to avoid masking return values."

The fix is the two-statement form `lib/pool.sh` uses everywhere (`pool_lease_write`,
`pool_chrome_launch`, `_pool_get_starttime`, …):

```bash
# ❌ masks failure: local returns 0 even when failing_cmd returns 1.
local json="$(jq -n …)"            # a jq build error is invisible

# ✅ split: jq's status reaches the `|| pool_die`.
local json
json="$(jq -n …)" || pool_die "jq build failed"
```

### 4.2 Bare `(( expr ))` that evaluates to 0 → returns 1 → aborts

`(( … ))` returns the **C truth value** of the expression: non-zero result → exit 0;
**zero result → exit 1**. As a freestanding statement under `set -e`, `(( 0 ))` kills
the shell. Classics that bite: `(( i++ ))` starting at 0; `(( diff < 0 ))` when `diff`
is 0; a "found" flag. Fix — put it in `if`, append `|| true`, or use the `$(( ))`
**expansion** form (always safe). `lib/pool.sh`'s `_pool_age_str` documents this
verbatim. ([BashFAQ/105][greg105]; ShellCheck notes `(( ))` exit semantics.)

```bash
# ❌ aborts when FAIL == 0.
(( FAIL )); …
(( PASS++ ))         # post-increment returns OLD value → 0 when PASS was 0 → abort

# ✅ expansion (always safe) / guarded.
PASS=$((PASS+1))
if (( FAIL > 0 )); then exit 1; fi
```

### 4.3 `grep`/`pgrep`/`curl`/`kill` returning non-zero (no match / ESRCH)

`grep` returns 1 on no match, `pgrep` returns 1 when nothing matches, `curl -sf`
returns non-zero on connection-refused/HTTP≥400, and `kill` returns 1 on `ESRCH`
(already dead) **or** `EPERM` (alive but not yours — `kill -0` is a *trap*: it cannot
distinguish dead from foreign-alive, [kill(2)][kill2]). Under `set -e` any of these as
a bare statement aborts. Wrap in `if`, append `|| true`, or capture into a var with a
fallback. `lib/pool.sh`'s `pool_chrome_kill` makes *every* kill `2>/dev/null || true`
— that **is** its idempotency mechanism (no `kill -0` precheck).

```bash
# ❌ aborts on "no chrome".
pgrep -f "user-data-dir=$ROOT"            # rc 1 when none → errexit fires
grep -q ":$port " <<<"$listeners"          # rc 1 when not listening → errexit fires
kill -- -"$pgid"                           # rc 1 if already dead → errexit fires

# ✅ guard it.
if pgrep -f -- "user-data-dir=$ROOT" >/dev/null 2>&1; then fail "chrome leaked"; fi
grep -q ":$port " <<<"$listeners" && continue
kill -- -"$pgid" 2>/dev/null || true
```

### 4.4 Keeping assertions non-fatal to the harness

Three layers, all used by `lib/pool.sh` and by the §1.2 runner:

1. **Subshell isolation** — the test body runs in `( … )` behind an `if`/`||`, so its
   non-zero exit (assert fail *or* a `set -e` abort) is the test's failure code, not
   the harness's. ([BashFAQ/105][greg105]: commands in `if` conditions are errexit-exempt.)
2. **Guarded commands** — anything that may legitimately fail is in `if`/`||`/`|| true`.
   Use ShellCheck's [SC2181][sc2181] advice ("check exit code directly with `if cmd;`,
   not indirectly via `$?`") to avoid the `cmd; rc=$?; if [ $rc -eq 0 ]` anti-pattern.
3. **Assertions return non-zero, never `exit`** — an assert calls `_fail` then
   `return 1`; the `set -e` inside the body subshell converts that into the test's
   terminating failure (caught at layer 1). Asserts never touch the counters directly.

```bash
_fail() { printf '    FAIL: %s\n' "$*" >&2; return 1; }   # never exits the process

assert_eq() {  # EXPECTED ACTUAL [LABEL]
    local expected="$1" actual="$2" label="${3:-}"
    [[ "$expected" == "$actual" ]] \
        || { _fail "assert_eq${label:+ ($label)}: expected '$expected' got '$actual'"; return 1; }
}
# Called as a bare statement inside the body subshell → its `return 1` ends the test.
```

---

## §5. Hermetic isolation: `mktemp -d`, `trap`, overriding `HOME`/XDG

The pool resolves all paths against `$HOME` (`pool_config_init` →
`POOL_HOME_DIR = realpath($HOME)`), so the single most important isolation is
**pointing `HOME` at a temp dir**. `mktemp -d` ([mktemp(1)][mktemp1]) gives a private
root; a `trap` ([Bash manual — Bourne Shell Builtins, `trap`][bashbuiltins]) guarantees
cleanup on any exit.

```bash
GLOBAL_TMP=""

cleanup() {
    [[ -n "${GLOBAL_TMP:-}" && -d "${GLOBAL_TMP:-}" ]] \
        && rm -rf -- "$GLOBAL_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

setup() {
    GLOBAL_TMP="$(mktemp -d -t abpool-validate.XXXXXX)"   # private, unique, 0700
    TEST_ROOT="$GLOBAL_TMP"
    export HOME="$TEST_ROOT/home";     mkdir -p "$HOME"     # pool anchors everything on HOME
    export XDG_CACHE_HOME="$TEST_ROOT/cache"
    export XDG_CONFIG_HOME="$TEST_ROOT/config"
    export XDG_DATA_HOME="$TEST_ROOT/share"
    export AGENT_BROWSER_POOL_STATE="$TEST_ROOT/state"
    export AGENT_CHROME_EPHEMERAL_ROOT="$TEST_ROOT/active"
    export AGENT_CHROME_MASTER="$TEST_ROOT/master"; mkdir -p "$AGENT_CHROME_MASTER"
    pool_config_init        # re-resolves all POOL_* against the temp HOME
    pool_state_init
}
```

Notes:

- `mktemp -d -t abpool-validate.XXXXXX` honours `$TMPDIR` and is race-free
  ([mktemp(1)][mktemp1]). The `XXXXXX` template is mandatory on GNU mktemp.
- `trap cleanup EXIT INT TERM` (the EXIT arm runs on normal exit; INT/TERM on
  signals). Because `set -e` can abort mid-test, the EXIT trap is the backstop;
  per-test `teardown` is the primary cleaner.
- Overriding `HOME`/`XDG_*` keeps the harness from ever touching the operator's real
  `~/.local`, `~/.config`, etc. — the same discipline git's test-lib uses with its
  `TRASH_DIRECTORY` ([git/test-lib.sh][gittestlib]) and that sharness enforces
  ([sharness][sharness]).
- `POOL_LOG_PATH` may also be overridden to a temp file to keep assertions
  side-effect-free w.r.t. the real pool log.

---

## §6. Detecting "no Chrome processes" — scoped to the pool's `--user-data-dir`

The pool launches each lane's Chrome with a **distinct, predictable** flag
(`pool_chrome_launch`: `--user-data-dir="$user_data_dir"` where
`user_data_dir == "$POOL_EPHEMERAL_ROOT/$lane"`). So `pgrep -f` against that
substring ([pgrep(1)][pgrep1], `-f` matches the **full command line**) scopes detection
to the pool **without** false-positiving on the user's daily-driver Chrome (whose
`--user-data-dir` is `~/.config/google-chrome` / `Default`, a different string).

```bash
# assert_no_chrome [ROOT] — no pooled Chrome bound under ROOT (or the pool root).
assert_no_chrome() {
    local root="${1:-$POOL_EPHEMERAL_ROOT}"
    # pgrep is the `if` CONDITION → errexit-exempt (rc 1 on "no match" does NOT abort).
    if pgrep -f -- "user-data-dir=$root" >/dev/null 2>&1; then
        _fail "chrome still running under --user-data-dir=$root"
        return 1
    fi
    printf '    ok: no chrome under %s\n' "$root"
}
```

Gotchas:

- **`pgrep -f` is a regex, not a fixed string** ([pgrep(1)][pgrep1]); if
  `$POOL_EPHEMERAL_ROOT` contains regex metacharacters (`.` etc.), escape them or use a
  more specific anchor. The leading `--` separates options from the pattern (a path can
  start with `-`).
- **A single Chrome instance is many processes** (browser + renderers + GPU + utility);
  each spawned child typically carries `--user-data-dir=` too, so `pgrep -f … | wc -l`
  is *not* a clean instance count. For "is there *any* pool chrome?" use the boolean
  form above (`pgrep … >/dev/null`); only count if you understand the tree.
- **`pgrep` returns 1 when nothing matches** → under `set -e` a bare `pgrep` aborts.
  Always put it in `if`/`|| true` (§4.3). For a numeric count: `n=$(pgrep -fc … 2>/dev/null || printf 0)`.
- **`pkill` is the symmetric teardown** for a leak discovered in a test — but the pool's
  own `pool_chrome_kill` (SIGTERM→grace→SIGKILL the process group via `kill -- -<pgid>`)
  is the authoritative path; tests should prefer `pool_release_lane`/`pool_chrome_kill`.
- **`kill -0` is a trap** for liveness ([kill(2)][kill2]): it returns 1 for *both*
  `ESRCH` (dead) and `EPERM` (alive but not yours). `lib/pool.sh` deliberately uses
  `/proc/<pid>` existence + `comm` + `starttime` (§3) instead. Use `pgrep`/`/proc`, not
  `kill -0`, for assertions.

---

## Sources

Kept (primary / canonical, version-stable):

- **proc(5)** — `/proc/[pid]/comm`, `/proc/[pid]/stat` field list (field 22 = starttime),
  comm parsing note (locate last `)`), `TASK_COMM_LEN`/15-char limit.
  https://man7.org/linux/man-pages/man5/proc.5.html
- **prctl(2)** — `PR_SET_NAME` semantics + the 16-byte `TASK_COMM_LEN` limit on `comm`.
  https://man7.org/linux/man-pages/man2/prctl.2.html
- **kill(2)** — why `kill -0` conflates `ESRCH` and `EPERM` (the liveness trap).
  https://man7.org/linux/man-pages/man2/kill.2.html
- **pgrep(1)** — `-f` matches the full command line; exit status 1 on no match; regex.
  https://man7.org/linux/man-pages/man1/pgrep.1.html
- **mktemp(1)** — `mktemp -d` for private race-free temp dirs; `XXXXXX` template.
  https://man7.org/linux/man-pages/man1/mktemp.1.html
- **flock(1)** — the `( flock 9; … ) 9>"$file"` shell idiom (relevant to pool acquire;
  shows the subshell-isolation pattern the harness reuses for tests).
  https://man7.org/linux/man-pages/man1/flock.1.html
- **Kernel `include/uapi/linux/sched.h`** — `#define TASK_COMM_LEN 16` (15 chars + NUL).
  https://github.com/torvalds/linux/blob/master/include/uapi/linux/sched.h
- **Kernel proc.rst** — kernel-side `/proc` documentation (comm, stat).
  https://www.kernel.org/doc/html/latest/filesystems/proc.html
- **ShellCheck SC2155** — declare/assign separately to avoid masking return values.
  https://www.shellcheck.net/wiki/SC2155
- **ShellCheck SC2181** — check exit code directly with `if cmd;`, not via `$?`.
  https://www.shellcheck.net/wiki/SC2181
- **Greg's Wiki — BashFAQ/105** — "set -e is not a panacea"; `if` conditions are errexit-exempt.
  https://mywiki.wooledge.org/BashFAQ/105
- **Greg's Wiki — BashFAQ** (index) — general idioms incl. source-vs-execute / `${BASH_SOURCE}`.
  https://mywiki.wooledge.org/BashFAQ
- **GNU Bash manual — Bash Variables** — `${BASH_SOURCE[0]}` vs `$0`.
  https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
- **GNU Bash manual — Bourne Shell Builtins** — `exec -a NAME` (argv[0] only) and `trap`.
  https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- **git `t/test-lib.sh`** — canonical hand-rolled shell harness (test_expect_success,
  EXIT trap, trash-directory isolation).
  https://github.com/git/git/blob/master/t/test-lib.sh
- **sharness** — dependency-free shell test framework extracted from git's test-lib.
  https://github.com/chriscool/sharness
- **`lib/pool.sh`** (this repo) — ground truth: `set -euo pipefail`; two-statement
  captures; `_pool_get_starttime` (greedy `)`-strip → field 20); the host-verified note
  that PRD §2.19 `NF-19` is wrong (yields `vsize`/signal field, not starttime);
  `pool_chrome_launch`'s `--user-data-dir=` flag; `pool_chrome_kill`'s `|| true`
  idempotency; tri-state `pool_lane_is_stale` caller contract.

Dropped (would-be secondary/commentary, not primary, and not live-fetched):

- Various "set -e considered harmful" blog posts — superseded by the primary
  BashFAQ/105 + ShellCheck citations above.
- bats/shunit2 docs — explicitly out of scope (the harness is hand-rolled, not a framework).

---

## Gaps

- **URLs were not live-fetched.** This sandbox has no web/HTTP tool. All links are
  canonical primary sources whose paths have been stable for years; the
  `lib/pool.sh`-derived claims (`NF-19` wrong, `comm`=basename, `--user-data-dir`
  flag, `|| true` idempotency) are backed by the repo's own host-verified docstrings.
  If the parent can run a `web_search`-capable agent, a quick re-fetch of `proc(5)`,
  `prctl(2)`, SC2155, and BashFAQ/105 would close the last verification gap.
- **Exact kernel line for `set_task_comm(current, kbasename(bprm->filename), …)`** is in
  `fs/exec.c` (`begin_new_exec`), which moves across versions; I cited the stable
  *documentation* (`proc.rst`, `prctl(2)`) and the `sched.h` constant instead of a
  line-anchored source URL.
- **`/proc/[pid]/stat` total field count = 52** is current per `proc(5)`; the `NF-30`
  correction assumes that count. The greedy-`)`-strip → field-20 method does not depend
  on the count and is the recommended path.
- **Chrome child-process `--user-data-dir` propagation** (does every renderer/GPU child
  carry the flag on this Chrome build?) was not verified; the boolean "any pool chrome"
  assertion is robust regardless, but a per-instance *count* via `pgrep` would need that
  confirmation.

---

## Appendix — minimal working `test/validate.sh` skeleton (all six sections composed)

```bash
#!/usr/bin/env bash
# test/validate.sh — hand-rolled, dependency-free harness for lib/pool.sh + the bins.
# Usage: bash test/validate.sh          # runs all test_* functions
#        source test/validate.sh        # reuse assert_* / run_test ad hoc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pool.sh
source "$SCRIPT_DIR/../lib/pool.sh"     # also activates set -euo pipefail (pool.sh L17)

PASS=0; FAIL=0
declare -a FAILED_TESTS=()
GLOBAL_TMP=""

# --- cleanup -----------------------------------------------------------------
cleanup() { [[ -n "${GLOBAL_TMP:-}" && -d "${GLOBAL_TMP:-}" ]] && rm -rf -- "$GLOBAL_TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- assert helpers (record failure via _fail, NEVER exit the process) -------
_fail() { printf '    FAIL: %s\n' "$*" >&2; return 1; }

assert_eq() {  # EXPECTED ACTUAL [LABEL]
    local expected="$1" actual="$2" label="${3:-}"
    [[ "$expected" == "$actual" ]] \
        || { _fail "assert_eq${label:+ ($label)}: expected '$expected' got '$actual'"; return 1; }
}
assert_lane_exists() {  # N
    pool_lease_exists "$1" || { _fail "lane $1 should have a valid lease"; return 1; }
}
assert_lane_gone() {  # N
    [[ ! -f "$POOL_LANES_DIR/$1.json" ]] || { _fail "lane $1 lease still present"; return 1; }
    [[ ! -d "$POOL_EPHEMERAL_ROOT/$1"  ]] || { _fail "lane $1 dir still present";   return 1; }
}
assert_no_chrome() {  # [ROOT]
    local root="${1:-$POOL_EPHEMERAL_ROOT}"
    if pgrep -f -- "user-data-dir=$root" >/dev/null 2>&1; then
        _fail "chrome still running under --user-data-dir=$root"; return 1
    fi
}
assert_no_dir() {  # PATH
    [[ ! -e "$1" ]] || { _fail "path still exists: $1"; return 1; }
}

# --- setup/teardown (hermetic; HOME-anchored) --------------------------------
setup() {
    GLOBAL_TMP="$(mktemp -d -t abpool-validate.XXXXXX)"
    export HOME="$GLOBAL_TMP/home";            mkdir -p "$HOME"
    export XDG_CACHE_HOME="$GLOBAL_TMP/cache"
    export XDG_CONFIG_HOME="$GLOBAL_TMP/config"
    export XDG_DATA_HOME="$GLOBAL_TMP/share"
    export AGENT_BROWSER_POOL_STATE="$GLOBAL_TMP/state"
    export AGENT_CHROME_EPHEMERAL_ROOT="$GLOBAL_TMP/active"
    export AGENT_CHROME_MASTER="$GLOBAL_TMP/master"; mkdir -p "$AGENT_CHROME_MASTER"
    export AGENT_BROWSER_POOL_DISABLE=1
    pool_config_init; pool_state_init
}
teardown() { [[ -n "${GLOBAL_TMP:-}" ]] && rm -rf -- "$GLOBAL_TMP" 2>/dev/null || true; }

# --- runner (subshell isolation → test failure is non-fatal) ------------------
run_test() {
    local name="$1" fn="$2" rc=0
    printf '%s\n' "== $name"
    setup
    ( set -e; "$fn" ) || rc=$?     # body non-zero = test fail, captured, harness survives
    teardown
    if (( rc == 0 )); then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); fi
}

main() {
    local fn
    for fn in $(compgen -A function test_); do run_test "$fn" "$fn"; done
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then printf 'FAILED: %s\n' "${FAILED_TESTS[*]}" >&2; exit 1; fi
}

# --- example test -------------------------------------------------------------
test_free_lane_is_one() {
    local n
    n="$(pool_find_free_lane)"          # always echoes + rc 0 → bare capture is set -e safe
    assert_eq "1" "$n" "first free lane"
}
test_missing_lane_has_no_lease() {
    if pool_lease_read 99; then         # rc 1 expected → guard it (§4.3 caller contract)
        _fail "pool_lease_read 99 should report no lease"; return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```
