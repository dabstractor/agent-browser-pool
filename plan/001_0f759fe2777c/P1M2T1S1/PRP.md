# PRP — P1.M2.T1.S1: ppid walk to comm==pi + test hook overrides

---

## Goal

**Feature Goal**: Implement the **owner-resolution layer** of `lib/pool.sh` — the
function `pool_owner_resolve()` that determines WHICH `pi` process owns the current
tool-call shell, by walking the `ppid` chain from `$$` up to the first process whose
`/proc/<pid>/comm` equals `pi`, and populating four `POOL_OWNER_*` globals that every
downstream lease query and the wrapper lifecycle consume. This is the literal
implementation of PRD §1.1 ("walking ppid to comm==pi yields a stable, unique-per-agent
PID") and PRD §2.4 step 1 ("Resolve OWNER: walk ppid to first comm==\"pi\"; record
{pid, comm, starttime}. No pi ancestor → passthrough").

The function also implements the **test-hook overrides** of PRD §2.18 /
key_findings.md FINDING 8 (`AGENT_BROWSER_POOL_OWNER_PID` +
`AGENT_BROWSER_POOL_OWNER_STARTTIME`) so the test harness (P1.M9.T1.S1) can simulate
distinct agents from distinct subshell PIDs without real `pi` ancestor processes — a
hard requirement because "a harness run from a plain interactive shell has no pi
ancestor → the wrapper enters passthrough and can't be exercised" (PRD §2.18).

**Deliverable**:
1. Two functions appended to `lib/pool.sh`, directly below the last function delivered
   by P1.M1.T2.S1 (the I/O primitive layer — `_pool_atomic_write`, `_pool_json_valid`,
   `_pool_now`, `_pool_age_str`), treated as a hard contract (see Integration Points):
   - `_pool_owner_starttime(pid)` — INTERNAL helper that extracts `/proc/<pid>/stat`
     field 22 (starttime, clock ticks since boot) using the parens-robust method.
   - `pool_owner_resolve()` — PUBLIC entry point that walks the ppid chain (or honors
     the test-hook override) and populates the `POOL_OWNER_*` globals.
2. Four new globals set by `pool_owner_resolve`: `POOL_OWNER_PID`, `POOL_OWNER_COMM`,
   `POOL_OWNER_STARTTIME`, `POOL_OWNER_CWD`. They are MUTABLE (not readonly) so the
   function is re-runnable (test harness calls it repeatedly with different overrides
   in one shell — same pattern as `pool_config_init`).
3. No new external dependencies (`cat`, `awk`, `readlink`, `read` — all verified
   present). No new files. No user-facing docs (test hooks are code-comment-only per
   the item description).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve`:
  - When run UNDER `pi` (the normal agent runtime): `POOL_OWNER_PID` is a non-zero
    digit string matching the actual `pi` ancestor PID; `POOL_OWNER_COMM=="pi"`;
    `POOL_OWNER_STARTTIME` is a digit string (the `/proc/<pid>/stat` field-22 value);
    `POOL_OWNER_CWD` is the absolute path from `readlink /proc/<pid>/cwd` (or empty
    if unreadable).
  - When run with `AGENT_BROWSER_POOL_OWNER_PID=<pid>` set: `POOL_OWNER_PID==<pid>`,
    `POOL_OWNER_COMM=="pi"`, `POOL_OWNER_STARTTIME` from `_OWNER_STARTTIME` override
    (or extracted from `/proc/<pid>` if the override is unset and the PID is live).
  - When run from a plain interactive shell with NO `pi` ancestor and NO override:
    `POOL_OWNER_PID=="0"` (the passthrough signal), `POOL_OWNER_COMM==""`.
- `pool_owner_resolve` NEVER calls `pool_die` and NEVER exits non-zero — owner
  resolution is never fatal (passthrough is always a valid outcome).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file still
  sources cleanly under `set -euo pipefail`.
- No regressions in S1 (`pool_die`, `_pool_log`), S2 (`pool_config_init` + `POOL_*`),
  S3 (`pool_state_init`, `pool_check_btrfs`, `pool_check_master`), or T2.S1
  (`_pool_atomic_write`, `_pool_json_valid`, `_pool_now`, `_pool_age_str`).

## User Persona

**Target User**: The downstream consumers are all internal to `lib/pool.sh` and the two
wrappers — no end-user or operator ever calls `pool_owner_resolve` directly:

- **P1.M3.T2.S1** (`find_my_lease`) — scans `lanes/*.json` for a lease whose
  `owner.pid == $POOL_OWNER_PID && owner.comm == "pi" && owner.starttime ==
  $POOL_OWNER_STARTTIME`. The (pid, starttime) pair is the anti-PID-recycling key
  (key_findings FINDING 1; see starttime semantics in Known Gotchas).
- **P1.M6.T3.S1** (wrapper lifecycle) — if `POOL_OWNER_PID == 0` (no pi ancestor /
  human in terminal), the wrapper enters **passthrough mode** (exec the real binary
  unchanged, no lane magic). Otherwise it proceeds to find/acquire a lane.
- **P1.M9.T1.S1** (test harness) — sets `AGENT_BROWSER_POOL_OWNER_PID=<distinct pid>`
  per simulated "agent" to drive the concurrency harness (N parallel agents must each
  get a distinct lane) WITHOUT real `pi` processes (PRD §2.18).

**Use Case**: Every single `agent-browser` invocation begins with
`pool_owner_resolve` (PRD §2.4 step 1). It is the FIRST lane-relevant operation —
before any lease scan, before any flock. It answers "who am I acting on behalf of?"

**Pain Points Addressed**:
- The pool's central correctness property is **per-agent lane affinity**: each `pi`
  process owns exactly one lane for the duration of its session, and subagents (separate
  `pi` processes) get separate lanes (PRD §1.1). `pool_owner_resolve` is what makes
  that possible — it distinguishes "which agent is this" without any agent-side
  cooperation (the agent just runs `agent-browser ...` and the wrapper figures out
  the owner from the process tree).
- Without the test-hook override, the test harness would need to run under real `pi`
  subagents — slow, brittle, and impossible to parallelize deterministically. The
  override (PRD §2.18) makes N-agent simulation a matter of setting N distinct env
  vars.

## Why

- **It is the identity primitive underpinning the entire lease model.** Leases
  (PRD §2.8) carry `owner: {pid, comm, starttime}`. `find_my_lease` (M3.T2.S1) and
  `is_lane_stale` (M3.T2.S3) both compare against the resolved owner. If owner
  resolution is wrong (e.g. matches the wrong `pi`, or misses a `pi` ancestor),
  agents will collide on lanes or steal each other's lanes. key_findings.md FINDING 8
  and system_context.md §2 both verified the ppid-walk works on this host.
- **The test harness cannot function without the override hooks.** PRD §2.18 is
  explicit: "a harness run from a plain interactive shell has no pi ancestor → the
  wrapper enters passthrough and can't be exercised." The `AGENT_BROWSER_POOL_OWNER_PID`
  override is the ONLY way to test lane acquisition/reaping logic from a test runner
  that is not itself a `pi` subagent. Implementing the hooks here (rather than later)
  unblocks M9.T1.S1 (test framework) and M9.T2.S1 (concurrency tests).
- **It cleanly separates "resolve owner" from "check owner liveness."** This task
  RESOLVES and STORES the owner identity (incl. starttime). The LIVENESS check
  (`is_owner_alive(pid, starttime)` — does the PID still exist AND still have the same
  starttime, i.e. was it recycled?) is P1.M2.T2.S1. Splitting them keeps each function
  single-purpose and testable.
- **`POOL_OWNER_PID == 0` is the passthrough contract.** The wrapper (M6.T3) and the
  admin CLI (M7) both need a single, unambiguous signal for "no pi ancestor, do
  nothing pool-related." `0` is that signal (a real PID is always ≥ 1). Documenting
  it here, at the source, prevents every consumer from reinventing the check.

## What

User-visible behavior: none directly (internal library function + an env-var test
hook that is code-comment-only). Observable contract:

| `pool_owner_resolve` invocation context | `POOL_OWNER_PID` | `POOL_OWNER_COMM` | `POOL_OWNER_STARTTIME` | `POOL_OWNER_CWD` | return |
|---|---|---|---|---|---|
| `AGENT_BROWSER_POOL_OWNER_PID=<pid>` set, `_OWNER_STARTTIME=<st>` set | `<pid>` | `pi` | `<st>` | readlink `/proc/<pid>/cwd` (or empty) | 0 |
| `AGENT_BROWSER_POOL_OWNER_PID=<pid>` set, `_OWNER_STARTTIME` unset, `<pid>` live | `<pid>` | `pi` | extracted field-22 (or empty) | readlink (or empty) | 0 |
| `AGENT_BROWSER_POOL_OWNER_PID=<pid>` set, `<pid>` not live, no starttime | `<pid>` | `pi` | `""` | `""` | 0 |
| `AGENT_BROWSER_POOL_OWNER_PID` set but NOT numeric | `0` (ignored, log warning) | `""` | `""` | `""` | 0 |
| no override, run UNDER `pi` | the pi ancestor PID | `pi` | extracted field-22 | readlink (or empty) | 0 |
| no override, NO pi ancestor (human in terminal) | `0` (passthrough) | `""` | `""` | `""` | 0 |

| `_pool_owner_starttime` args | Returns / echoes | Failure mode |
|---|---|---|
| `$1=pid` (live process) | 0; echoes digit string (field 22) | — |
| `$1=pid` (dead/missing/unreadable /proc) | 1; echoes nothing | NEVER exits the process; NEVER calls `pool_die` |

### Success Criteria

- [ ] `pool_owner_resolve` and `_pool_owner_starttime` are defined in `lib/pool.sh`
  and callable after `source lib/pool.sh` (no `pool_config_init` required to call
  them — they read no `POOL_*` path globals — but tests/callers will have run
  `pool_config_init` first for realism).
- [ ] When sourced and run under `pi` (the normal agent runtime), `pool_owner_resolve`
  sets `POOL_OWNER_PID` to the actual `pi` ancestor's PID (verified by comparing to an
  independent `ppid` walk), `POOL_OWNER_COMM=="pi"`, `POOL_OWNER_STARTTIME` matching
  `cut -d' ' -f22 /proc/<that pid>/stat`, and `POOL_OWNER_CWD` matching
  `readlink /proc/<that pid>/cwd` (or empty if unreadable).
- [ ] When `AGENT_BROWSER_POOL_OWNER_PID=<pid>` is set, `pool_owner_resolve` uses it
  directly (NO ppid walk), sets `POOL_OWNER_PID=<pid>`, `POOL_OWNER_COMM="pi"`, and
  `POOL_OWNER_STARTTIME` from `AGENT_BROWSER_POOL_OWNER_STARTTIME` if set (else
  extracted from `/proc/<pid>` if live, else empty).
- [ ] When run from a plain shell with NO `pi` ancestor and NO override,
  `POOL_OWNER_PID=="0"` and `POOL_OWNER_COMM==""` (passthrough signal).
- [ ] `pool_owner_resolve` NEVER calls `pool_die` and ALWAYS returns 0 — even on
  invalid override values, missing /proc entries, or readlink failures. Invalid
  overrides are logged via `_pool_log` and ignored (POOL_OWNER_PID stays 0).
- [ ] `pool_owner_resolve` is RE-RUNNABLE: calling it twice in the same shell with
  different overrides produces the second call's globals (globals are reset to defaults
  at the top of every call — same re-runnable contract as `pool_config_init`).
- [ ] `_pool_owner_starttime` echoes a `^[0-9]+$` string for a live PID and returns 0;
  returns 1 (echoes nothing) for a dead/missing PID; NEVER calls `pool_die` and NEVER
  exits the process.
- [ ] `_pool_owner_starttime` uses the PARENS-ROBUST extraction (strip everything up to
  and including the last `)`, then field 20 of the remainder = field 22 overall) — NOT
  a naive `awk '{print $22}'` which breaks when `comm` contains spaces. Verified on
  this host: both methods agree for `comm=='pi'` (no spaces), but only the robust
  method is correct in general.
- [ ] The ppid walk terminates cleanly on ALL of: reaching `comm=='pi'` (success),
  `ppid==1` (init), `ppid==0` (kernel boundary), `ppid==pid` (self-loop guard), a
  step cap (128, pathological-chain guard), and a missing/unreadable `/proc/<pid>`
  entry. It NEVER infinite-loops.
- [ ] `POOL_OWNER_CWD` is an ABSOLUTE path (from `readlink`, which resolves the
  symlink to an absolute target) or empty — never a relative path, never `~`.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources
  cleanly under `set -euo pipefail`; all prior deliverables (S1, S2, S3, T2.S1) still
  work.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the exact host-verified
`/proc` field layout (comm bare in `/proc/<pid>/comm`; `PPid:` line in
`/proc/<pid>/status`; field-22 starttime in `/proc/<pid>/stat` with the parens-robust
extraction verified to yield `8239564` on this host); the exact ppid-walk algorithm
with all five termination conditions; the exact test-hook override semantics from
PRD §2.18 / FINDING 8; the exact `set -euo pipefail` traps (SC2155 two-statement
locals, `(( ))` inside `if`, `read < /missing` guarded with `|| true`); the exact
downstream consumer contract (M3.T2 lease queries, M6.T3 wrapper passthrough, M9.T1
test harness); the exact boundary against the sibling task P1.M2.T1.S2 (robust
starttime extraction); and copy-pasteable validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §1.1 (pi ancestor walk — "walking ppid to comm==pi yields a stable,
        unique-per-agent PID"), §2.4 step 1 (resolve OWNER — the exact lifecycle
        step this implements), §2.18 (test-hook overrides — AGENT_BROWSER_POOL_OWNER_PID
        + _OWNER_STARTTIME, "implement as narrowly-scoped test hooks"), §2.19
        (Implementation notes: "/proc/<pid>/stat parsing: comm is field 2 but wrapped
        in parens and may contain spaces... Read starttime from the right (field 22
        from the start → index NF-19)" — NOTE the NF-19 formula is WRONG per
        key_findings FINDING 1; use the parens-strip method instead).
  pattern: §2.4 step 1 is the literal algorithm. §2.18 is the literal test-hook spec.
  gotcha: §2.19's `NF-19` formula is empirically WRONG on this host (NF=52, NF-19=33,
        not field 22). key_findings FINDING 1 + system_context §6.1 both correct it:
        strip-to-last-paren then field 20 of remainder. USE THE PARENS METHOD.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §2 (env verification — "pi ancestor PID walk works ✅ CONFIRMED: ppid walk from
        $$ → bash → pi (1409826) → timeout → zsh → ..."), §6 ("/proc Parsing — CRITICAL
        FINDING": starttime is field 22; the NF-19 approach is WRONG; the correct
        robust method is `sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'`;
        comm via /proc/<pid>/comm strips parens; ppid is field 4 or via status PPid: line).
  pattern: §6.1 Method 2 (sed 's/.*)//' | awk '{print $20}') is the direct ancestor of
        _pool_owner_starttime.
  gotcha: §6.1 notes "The comm field for pi is just 'pi' (no spaces), so Method 1
        [cut -f22] also works, but Method 2 is defensive." USE METHOD 2 (defensive).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 1 (starttime parsing — the NF-19 bug + the correct parens-strip method,
        verified on this host: field 22 = 8239564-class values), FINDING 8 (Test Hook
        Overrides — the exact env-var names + semantics this task implements), the
        "Function Naming Convention" (`pool_owner_*` for owner resolution).
  pattern: FINDING 8's pseudo-code (check override first; else walk ppid) is the
        literal algorithm for pool_owner_resolve.
  gotcha: FINDING 8 says these are "test-only hooks — narrowly-scoped, not exposed in
        user-facing docs." Document them in CODE COMMENTS only.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §2/§3 confirm `cat`, `awk`, `readlink` are present on this host (the only
        external commands _pool_owner_starttime and pool_owner_resolve invoke).
  pattern: no new deps introduced.
  gotcha: none.

# External authoritative docs (for the HOW)
- url: https://man7.org/linux/man-pages/man5/proc.5.html
  why: authoritative definition of /proc/[pid]/{comm,status,stat,cwd}. comm = field 2
        of stat wrapped in parens, ALSO available bare at /proc/[pid]/comm (trailing
        newline). status has a `PPid:\t<N>` line. stat field 22 = starttime in clock
        ticks since boot. cwd is a symlink to the process's working directory.
  critical: ON THIS HOST (verified 2026-07-12): /proc/self/comm = bare name + newline
        (no parens); /proc/self/status PPid line = `PPid:\t<N>`; /proc/self/stat field
        22 = 8239564 (agrees between cut -f22 and the parens-strip method);
        getconf CLK_TCK = 100. starttime changes when a PID is recycled (the anti-
        recycling key — M2.T2.S1 consumes this; THIS task only extracts+stores it).
  section: "/proc/[pid]/stat" (field table), "/proc/[pid]/comm", "/proc/[pid]/status",
        "/proc/[pid]/cwd".

- url: https://www.kernel.org/doc/html/latest/filesystems/proc.html
  why: the kernel's own rendered proc.rst — the canonical field table for
        /proc/[pid]/stat (confirms comm-in-parens + the field numbering).
  critical: same as proc(5) — comm may contain spaces, so naive whitespace splitting
        of stat is unsafe; use the parens-strip method.
  section: "Process-specific subdirectories" → /proc/[pid]/stat table.

- url: https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
  why: `declare -g VAR="value"` (bash ≥ 4.2) — the unambiguous way to set a GLOBAL
        from inside a function. Plain `VAR="value"` only sets global if no same-named
        `local` is in dynamic scope. The existing pool_config_init uses the weaker
        "both" pattern (`VAR="x"; declare -g VAR`) — for NEW globals, prefer the
        single-statement `declare -g VAR="value"`.
  critical: POOL_OWNER_* globals must be MUTABLE (not readonly) so pool_owner_resolve
        is RE-RUNNABLE (test harness). Do NOT use `readonly`.
  section: the `declare` builtin entry.

- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: authoritative on `set -e` (the condition of `if`/`while`/`&&`/`||` and the
        inside of `[[ ]]` / `(( ))` in those conditions are EXEMPT from errexit) and
        `set -u` (use `${VAR:-}` for possibly-unset vars).
  critical: `IFS= read ... < /proc/X/comm` whose redirection FAILS (vanished /proc
        entry) returns non-zero and ABORTS under set -e — guard with `2>/dev/null
        || true`. A bare `(( expr ))` statement returning 0 is FATAL — always
        `if (( ))` or `while (( ))`. A standalone failing `[[ =~ ]]` aborts — use
        inside `if`/`!`.
  section: errexit (`-e`) and nounset (`-u`).

- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: `${VAR:-}` (set -u safe default for possibly-unset env vars), `${line##*)}` /
        `${line#PPid:}` (prefix-strip for the parens-robust stat parse and the status
        PPid parse), `${ppid//[[:space:]]/}` (strip whitespace from the PPid value).
  critical: `${VAR:-}` covers BOTH unset AND empty (use `:-`, not `-`, for the
        non-empty test). `${line##*\)}` is the GREEDY form (longest prefix) — required
        to reach the LAST `)` even if comm itself contains `)`.
  section: `${parameter:-word}`, `${parameter##word}`, `${parameter/pattern/string}`.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` so cmd's exit status
        is not masked (matters for `cat /proc/...`, `readlink`, `_pool_owner_starttime`).
  critical: every `local` capture in pool_owner_resolve must be two-statement form.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions. Universal.

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 created lib/pool.sh with `set -euo pipefail` (propagates to callers),
        `pool_die()` (printf '%s\n' "$*" >&2; exit 1), `_pool_log()` (ISO-8601 timestamp
        + msg to log + stderr), `_pool_log_path()`. THIS subtask APPENDS to that file.
        Call `_pool_log` for observability (one line per resolve). Do NOT call
        `pool_die` from pool_owner_resolve (resolution is never fatal).
  pattern: S1's `_pool_log "msg"` is the logger; S1's `pool_die` is the exit-1 helper.
  gotcha: S1 propagates `set -euo pipefail` into the caller. EVERY command whose
        non-zero exit is a SIGNAL not a failure (`read < /missing`, `readlink` on a
        dead pid, `(( ))`, `[[ =~ ]]`) MUST be wrapped in `if`/`||`.

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 delivers `pool_config_init()` + the `POOL_*` path/config globals
        (POOL_STATE_DIR, POOL_LANES_DIR, etc.). pool_owner_resolve does NOT require
        pool_config_init to have run (it reads no POOL_* path globals), but tests and
        the wrappers will have called pool_config_init first. _pool_log (used by
        pool_owner_resolve) reads POOL_LOG_PATH / AGENT_BROWSER_POOL_STATE — so logging
        works whether or not pool_config_init ran (S1's _pool_log_path has its own
        defaults).
  pattern: S2's `declare -g POOL_*` mutable-global re-runnable pattern is the model
        for POOL_OWNER_*.
  gotcha: none direct — pool_owner_resolve is independent of the path globals.

- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md
  why: T2.S1 (IN PARALLEL / just-landed) delivers `_pool_atomic_write`,
        `_pool_json_valid`, `_pool_now`, `_pool_age_str`. THIS subtask appends BELOW
        those four. They are NOT called by pool_owner_resolve (owner resolution does
        no lease I/O), but they are part of the file the implementer must append to.
  pattern: append at EOF, below the T2.S1 functions.
  gotcha: the implementer must locate the END of the current lib/pool.sh (after S1,
        S2, S3, and T2.S1's four helpers) and append there. Do NOT assume a specific
        function is last — `tail -1 lib/pool.sh` to confirm, or grep for the last
        `^[a-z_].*\(\)$` line.

- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md
  why: S3 delivers `pool_state_init`, `pool_check_btrfs`, `pool_check_master`. Not
        called by pool_owner_resolve. Append below them if they have landed.
  pattern: append at EOF regardless of S3's status.
  gotcha: none.

- file: plan/001_0f759fe2777c/P1M2T1S1/research/proc-parsing-and-ppid-walk.md
  why: the host-verified /proc facts (field layout, comm/status/stat formats, the
        parens-strip method verified to yield 8239564, the strict-mode traps table),
        the task-boundary analysis (S1 vs S2), and the test-hook spec from FINDING 8.
  pattern: the strict-mode traps table + the test-hook decision logic.
  gotcha: the NF-19 formula in PRD §2.19 is WRONG; use the parens-strip method.

- file: plan/001_0f759fe2777c/P1M2T1S1/research/reference-impl.md
  why: the paste-ready reference implementation of _pool_owner_starttime and
        pool_owner_resolve, with all strict-mode guards baked in. This is the direct
        ancestor of the Implementation Patterns section below.
  pattern: the two function bodies + the "Strict-mode notes" bullets.
  gotcha: the reference uses `cat /proc/$pid/stat` (not `$(<...)`) for maximum
        portability and because `local x; x="$(cat ...)"` is the SC2155-safe form;
        either works, be consistent.
```

### Current Codebase tree

After **S1, S2, S3, and T2.S1** are implemented, the repo looks like:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/                                  # S1 — empty (.gitkeep)
├── lib/
│   └── pool.sh                           # S1 header+set -euo pipefail+pool_die+_pool_log
│                                         # + S2 _pool_config_* helpers + pool_config_init
│                                         # + S3 pool_state_init/pool_check_btrfs/pool_check_master
│                                         # + T2.S1 _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str
├── test/                                 # S1 — empty (.gitkeep)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md
    ├── prd_index.txt
    ├── tasks.json
    ├── P1M1T1S1/{PRP.md, research/bash-library-research.md}
    ├── P1M1T1S2/{PRP.md, research/bash-config-init-research.md}
    ├── P1M1T1S3/{PRP.md, research/btrfs-findmnt-host-facts.md}
    ├── P1M1T2S1/{PRP.md, research/{atomic-write-jq-date-semantics.md, helper-function-reference-impl.md}}
    └── P1M2T1S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{proc-parsing-and-ppid-walk.md, reference-impl.md}
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh   # MODIFIED — append _pool_owner_starttime, pool_owner_resolve
└── (nothing else changes this subtask)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
adds the **owner-resolution layer** between the I/O primitives (T2.S1) and the lease
layer (M3). It appends, in order, at EOF (below T2.S1's four helpers):

1. `_pool_owner_starttime(pid)` — INTERNAL: extract `/proc/<pid>/stat` field 22
   (parens-robust). Echoes digits + return 0 on success; return 1 (no echo) on
   missing/unreadable. Never fatal.
2. `pool_owner_resolve()` — PUBLIC: honor the test-hook override OR walk ppid from `$$`
   to `comm=='pi'`; populate `POOL_OWNER_PID/COMM/STARTTIME/CWD`. Never fatal.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (PRD §2.19 is WRONG; key_findings FINDING 1 + system_context §6.1 correct it):
# /proc/<pid>/stat field 2 (comm) is wrapped in parens and MAY contain spaces, shifting
# every subsequent field. The PRD's "NF-19" formula assumes a fixed field count (41) but
# the real count on this host is 52, so NF-19 = field 33, NOT field 22 (starttime).
# VERIFIED THIS SESSION: cut -d' ' -f22 /proc/self/stat = 8239564 AND
# sed 's/.*)//' /proc/self/stat | awk '{print $20}' = 8239564 (they AGREE for comm='pi'
# with no spaces). The parens-strip method is robust for ANY comm; use it.
# After stripping "pid (comm)" (everything up to & incl. the LAST ')'), overall field 22
# == field 20 of the remainder (offset −2).

# CRITICAL (set -e + read < /missing): a bare `IFS= read -r comm < "/proc/$pid/comm"`
# whose REDIRECTION fails (process vanished between the `-d /proc/$pid` check and the
# read, or EACCES) returns non-zero and ABORTS under set -e (propagated by S1). ALWAYS
# guard: `IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true`. The `2>/dev/null`
# suppresses the shell's "No such file" message; `|| true` neutralizes the exit status.
# comm stays "" on failure — check with `[[ -n "$comm" ]]`.

# CRITICAL (set -e + (( ))): a bare `(( expr ))` as a STATEMENT returns exit status 1
# when the result is 0 (or any false-y value). Under set -e this is FATAL. ALWAYS put
# `(( ))` inside `if (( ))`, `while (( ))`, or guard with `|| true`. The `$(( expr ))`
# EXPANSION form is always safe. So `if (( ppid == 1 )); then break; fi` is correct;
# `(( ppid == 1 )) && break` is ALSO correct (the `&&` list is exempt for all but the
# last command).

# CRITICAL (set -e + [[ =~ ]]): a standalone `[[ "$v" =~ ^[0-9]+$ ]]` that fails to
# match returns 1 and ABORTS under set -e. ALWAYS use it inside `if [[ ]]` / `[[ ]] ||`
# / `! [[ ]]` (all exempt). So `if [[ ! "$pid" =~ ^[0-9]+$ ]]; then ...; fi` is correct.

# CRITICAL (SC2155): `local x="$(cmd)"` masks cmd's exit status (and under set -e hides
# failures). ALWAYS: `local x; x="$(cmd)"` — two statements. This matters for
# `cat /proc/$pid/stat`, `readlink /proc/$pid/cwd`, and the `_pool_owner_starttime`
# subshell capture inside pool_owner_resolve.

# CRITICAL (declare -g vs readonly): POOL_OWNER_* globals must be MUTABLE so
# pool_owner_resolve is RE-RUNNABLE (test harness calls it repeatedly with different
# overrides in one shell — same contract as pool_config_init). Do NOT use `readonly`.
# Use `declare -g POOL_OWNER_PID="$pid"` (single-statement, unambiguously global).

# GOTCHA (readlink /proc/<pid>/cwd can fail): returns EACCES (different uid / Yama
# ptrace_scope) or ENOENT (process died / cwd unlinked). Guard:
# `cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || true`; treat empty as "unknown"
# (POOL_OWNER_CWD=""). CWD is observability-only; an empty value is never fatal.

# GOTCHA (comm trailing newline): /proc/<pid>/comm has a trailing newline. Using
# `IFS= read -r comm < file` consumes the newline (comm has no trailing \n). Using
# `comm="$(<file)"` strips ALL trailing newlines. Either is fine; be consistent. The
# reference impl uses `IFS= read -r`.

# GOTCHA (PPid: line format): /proc/<pid>/status line is `PPid:\t<N>` (tab-separated).
# `${line#PPid:}` leaves `\t<N>`; `${ppid//[[:space:]]/}` strips the tab → pure digits.
# Do NOT assume a single space; use the whitespace-strip.

# GOTCHA (re-runnable globals): pool_owner_resolve must RESET POOL_OWNER_* to defaults
# at the TOP of every call (POOL_OWNER_PID="0", COMM/STARTTIME/CWD=""), then populate.
# Without the reset, a second call that finds no pi ancestor would leave stale globals
# from the first call. Mirror pool_config_init's unconditional re-resolve.

# GOTCHA (test-hook override is NON-FATAL on bad input): if AGENT_BROWSER_POOL_OWNER_PID
# is set but not numeric, do NOT pool_die — log a warning via _pool_log and leave
# POOL_OWNER_PID=0 (passthrough). A misconfigured test should not crash the wrapper.

# GOTCHA (no _pool_log spam): pool_owner_resolve runs on EVERY agent-browser invocation
# (PRD §2.4 step 1). Log EXACTLY ONE line per call (the resolved identity or the
        # passthrough reason). Do not log inside the ppid-walk loop.

# GOTCHA (scope): this task RESOLVES+STORES the owner identity ONLY. Do NOT: implement
# is_owner_alive (that's P1.M2.T2.S1 — liveness + starttime-recycling check); scan
# leases (M3.T2); acquire a lane (M5.T1); enter passthrough/exec (M6.T3). This subtask
# is the resolver + the test hooks, nothing else.
```

## Implementation Blueprint

### Data models and structure

This subtask defines no JSON, no on-disk schema. It defines four MUTABLE bash globals
(the `POOL_OWNER_*` contract) and two functions:

| Symbol | Kind | Visibility | Set by | Consumed by |
|---|---|---|---|---|
| `POOL_OWNER_PID` | global (digits, `0` = passthrough) | public (no `_` prefix) | `pool_owner_resolve` | M3.T2.S1 find_my_lease, M6.T3 wrapper |
| `POOL_OWNER_COMM` | global (string, `pi` or `""`) | public | `pool_owner_resolve` | M3.T2.S1 find_my_lease |
| `POOL_OWNER_STARTTIME` | global (digits or `""`) | public | `pool_owner_resolve` | M3.T2.S1 find_my_lease, M2.T2.S1 is_owner_alive |
| `POOL_OWNER_CWD` | global (abs path or `""`) | public | `pool_owner_resolve` | observability (M7 status) |
| `_pool_owner_starttime` | function (echoes digits / returns 0\|1) | internal (`_pool_` prefix) | (defined here) | pool_owner_resolve; M2.T2.S1 may harden |
| `pool_owner_resolve` | function (returns 0 always) | public (`pool_` prefix) | (defined here) | bin/agent-browser (M6.T3), bin/agent-browser-pool (M7), tests (M9) |

**Naming**: matches key_findings.md "Function Naming Convention" — `pool_owner_*` =
owner resolution (public entry), `_pool_*` = internal helper.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the prior PRPs and confirm the file is ready to append at EOF
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_die _pool_log pool_config_init _pool_atomic_write _pool_now'
  - EXPECT: all five reported as functions. (pool_state_init/pool_check_btrfs/
        pool_check_master may or may not be present — S3 may be parallel; T2.S1's four
        helpers SHOULD be present. APPEND below whichever landed last.)
  - RUN (find the append point):
        grep -nE '^[a-z_][a-z_0-9]*\(\)' lib/pool.sh | tail -5
  - EXPECT: the last function definition line. Append BELOW that function's closing `}`.
  - NOTE: the file ALREADY contains S1 (set -euo pipefail, pool_die, _pool_log,
        _pool_log_path), S2 (_pool_config_* + pool_config_init), POSSIBLY S3
        (pool_state_init/pool_check_btrfs/pool_check_master), and T2.S1
        (_pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str). APPEND at EOF.
        Do NOT duplicate anything.

Task 1: APPEND _pool_owner_starttime() to lib/pool.sh (at EOF)
  - IMPLEMENT: parens-robust extraction of /proc/<pid>/stat field 22 (starttime).
  - BEHAVIOR (verbatim-ready):
        _pool_owner_starttime() {
            # Echo the process starttime (/proc/<pid>/stat field 22, clock ticks since
            # boot) for PID. Returns 0 + echoes digits on success; returns 1 (NOT fatal,
            # no echo) if the stat file is missing/unreadable. EXTRACTS ONLY — no
            # liveness validation (that's is_owner_alive in P1.M2.T2.S1).
            #
            # ROBUSTNESS: field 2 (comm) is wrapped in parens and MAY contain spaces,
            # which shifts every later field. The PRD §2.19 "NF-19" formula is WRONG on
            # this host (NF=52 → NF-19=field 33, not 22). We strip "pid (comm)" by
            # removing everything up to and including the LAST ')' (greedy), making
            # overall field 22 == field 20 of the remainder (offset −2). Verified
            # 2026-07-12: both methods agree (8239564) for comm='pi'.
            # P1.M2.T1.S2 may harden this further; the CONTRACT is: echo digits on
            # success, return 1 on failure, never exit the process.
            local pid="$1"
            local stat_line after start
            # `|| true` neutralizes a vanished/permission-denied /proc entry under set -e.
            stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
            [[ -n "$stat_line" ]] || return 1
            # Drop "pid (comm)" — greedy longest-prefix up to the LAST ')'.
            after="${stat_line##*)}"
            start="$(awk '{print $20}' <<<"$after")"
            [[ -n "$start" ]] || return 1
            printf '%s\n' "$start"
        }
  - FOLLOW pattern: `local x; x="$(...)"` two-statement (SC2155); `[[ -n ]] || return 1`
        for the missing-file guard (regex/[[ ]] inside `||` is errexit-exempt).
  - GOTCHA: NEVER use a naive `awk '{print $22}'` — breaks when comm has spaces. Use the
        parens-strip. Verified.
  - GOTCHA: NEVER `pool_die` from this helper — it is a 0/1 extractor; callers handle
        the empty/1 case gracefully.
  - NAMING: _pool_owner_starttime (internal).
  - PLACEMENT: at EOF (below T2.S1's four helpers, or below S3's pool_check_master if
        S3 landed after T2.S1 — either way, EOF).

Task 2: APPEND pool_owner_resolve() to lib/pool.sh (below _pool_owner_starttime)
  - IMPLEMENT: honor test-hook override OR walk ppid from $$ to comm=='pi'; populate
        POOL_OWNER_* globals. NEVER fatal.
  - BEHAVIOR (verbatim-ready):
        pool_owner_resolve() {
            # Resolve the owning pi process and populate POOL_OWNER_* globals.
            # Implements PRD §2.4 step 1 (resolve OWNER), §1.1 (walk ppid to comm=='pi'),
            # and the test-hook overrides of PRD §2.18 / key_findings FINDING 8.
            #
            # LOGIC:
            #   1. TEST MODE: if AGENT_BROWSER_POOL_OWNER_PID is set+non-empty+numeric,
            #      use it directly (NO ppid walk). Set COMM='pi'; STARTTIME from
            #      _OWNER_STARTTIME override (else extract from /proc if live); CWD via
            #      readlink. Bad/non-numeric override → log warning, leave PID=0.
            #   2. REAL MODE: walk ppid from $$ reading /proc/<pid>/comm; stop at first
            #      comm=='pi'. On hit: set PID/COMM/STARTTIME/CWD.
            #   3. NO PI ANCESTOR (human in terminal): POOL_OWNER_PID stays 0, COMM=''
            #      (passthrough signal to M6.T3 wrapper).
            #
            # NEVER calls pool_die — owner resolution is NEVER fatal. Always returns 0.
            # Globals are MUTABLE so this is RE-RUNNABLE (test harness). One _pool_log
            # line per call (observability) — never log inside the walk loop.

            # Reset globals to defaults every call (re-runnable contract).
            POOL_OWNER_PID="0"
            POOL_OWNER_COMM=""
            POOL_OWNER_STARTTIME=""
            POOL_OWNER_CWD=""
            declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD

            # --- 1. TEST MODE: env-var override ---------------------------------
            if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
                local ovr_pid="$AGENT_BROWSER_POOL_OWNER_PID"
                # Non-numeric override → log + ignore (passthrough). Non-fatal.
                if [[ ! "$ovr_pid" =~ ^[0-9]+$ ]]; then
                    _pool_log "pool_owner_resolve: invalid AGENT_BROWSER_POOL_OWNER_PID='$ovr_pid' (ignored)"
                    return 0
                fi
                POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
                POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM
                # starttime: prefer the override; else extract from /proc (test may
                # point at a live PID); else leave empty.
                if [[ -n "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-}" ]]; then
                    POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME"
                    declare -g POOL_OWNER_STARTTIME
                else
                    local st=""
                    st="$(_pool_owner_starttime "$ovr_pid" 2>/dev/null)" || true
                    if [[ -n "$st" ]]; then
                        POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
                    fi
                fi
                # cwd: readlink the override PID if live; else empty.
                local cwd=""
                cwd="$(readlink "/proc/$ovr_pid/cwd" 2>/dev/null)" || true
                if [[ -n "$cwd" ]]; then
                    POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
                fi
                _pool_log "pool_owner_resolve: TEST MODE owner pid=$POOL_OWNER_PID" \
                          "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"
                return 0
            fi

            # --- 2. REAL MODE: walk ppid chain from $$ --------------------------
            local pid="$$"
            local ppid="" comm="" line="" found_pid="" steps=0
            # Hard cap (128) guards against pathological chains; normal chains are < 10.
            while (( steps++ < 128 )); do
                comm=""
                # `2>/dev/null || true`: vanished /proc entry is a clean branch, not a
                # set -e abort. comm stays "" on failure.
                IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true
                if [[ "$comm" == "pi" ]]; then
                    found_pid="$pid"
                    break
                fi
                # ppid from /proc/<pid>/status (PPid: line) — robust vs comm-paren issue.
                ppid=""
                if [[ -r "/proc/$pid/status" ]]; then
                    while IFS= read -r line; do
                        if [[ "$line" == PPid:* ]]; then
                            ppid="${line#PPid:}"
                            ppid="${ppid//[[:space:]]/}"   # strip tab/space → pure digits
                            break
                        fi
                    done < "/proc/$pid/status"
                fi
                # Termination: blank/non-numeric ppid, init (1), kernel boundary (0),
                # self-loop (ppid==pid). All inside if/(( )) — errexit-exempt.
                if [[ ! "$ppid" =~ ^[0-9]+$ ]]; then break; fi
                if (( ppid == 1 ));  then break; fi
                if (( ppid == 0 ));  then break; fi
                if (( ppid == pid )); then break; fi
                pid="$ppid"
            done

            # --- 3. RESULT ------------------------------------------------------
            if [[ -n "$found_pid" ]]; then
                POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
                POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM
                local st=""
                st="$(_pool_owner_starttime "$found_pid" 2>/dev/null)" || true
                if [[ -n "$st" ]]; then
                    POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
                fi
                local cwd=""
                cwd="$(readlink "/proc/$found_pid/cwd" 2>/dev/null)" || true
                if [[ -n "$cwd" ]]; then
                    POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
                fi
                _pool_log "pool_owner_resolve: owner pid=$POOL_OWNER_PID" \
                          "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}" \
                          "cwd=${POOL_OWNER_CWD:-<unknown>}"
                return 0
            fi

            # No pi ancestor → human-in-terminal → passthrough (POOL_OWNER_PID stays 0).
            _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
            return 0
        }
  - FOLLOW pattern: globals reset at top (re-runnable); `local x; x="$(...)"` two-statement;
        every `IFS= read ... < file` guarded with `2>/dev/null || true`; every `(( ))`
        inside `if`; every `[[ =~ ]]` inside `if`/`!`; `declare -g VAR="value"` (mutable);
        exactly ONE _pool_log line per call.
  - GOTCHA: NEVER pool_die. A bad override, a vanished /proc, a readlink failure — all
        are non-fatal. Log and continue (or passthrough).
  - GOTCHA: the `${AGENT_BROWSER_POOL_OWNER_PID:-}` form (with `:-`) covers BOTH unset
        AND empty — required under set -u. Do NOT use `${VAR-}` (only covers unset).
  - GOTCHA: the PPid: line is tab-separated (`PPid:\t<N>`); `${line#PPid:}` leaves the
        tab+digits; `${ppid//[[:space:]]/}` strips the tab. Do NOT assume a single space.
  - NAMING: pool_owner_resolve (public entry point).
  - PLACEMENT: directly below _pool_owner_starttime (last function in the file).

Task 3: VERIFY (do this BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                  # syntax
  - RUN: shellcheck lib/pool.sh                               # zero warnings (whole file)
  - RUN (both functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type _pool_owner_starttime pool_owner_resolve'
        # EXPECT: both reported as functions.
  - RUN (_pool_owner_starttime echoes digits for $$):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 out="$(_pool_owner_starttime "$$")"; [[ "$out" =~ ^[0-9]+$ ]] && echo "OK st=$out"'
        # EXPECT: OK st=<digits> (the field-22 value for the current shell).
  - RUN (_pool_owner_starttime agrees with cut -f22 for $$):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 a="$(_pool_owner_starttime "$$")"; b="$(cut -d" " -f22 /proc/$$/stat)"; \
                 [[ "$a" == "$b" ]] && echo "OK agree=$a" || echo "FAIL a=$a b=$b"'
        # EXPECT: OK agree=<digits> (the parens method matches the naive method for
        #       comm='bash' which has no spaces — sanity check).
  - RUN (_pool_owner_starttime returns 1 for a dead/missing PID, no echo, no abort):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_owner_starttime 999999999; then echo "FAIL: should be dead"; \
                 else echo "OK: dead pid → return 1"; fi'
        # EXPECT: OK: dead pid → return 1 (and NO output from the function itself).
  - RUN (REAL MODE under pi: pool_owner_resolve finds the pi ancestor):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 [[ "$POOL_OWNER_COMM" == "pi" ]] && echo "OK comm=pi pid=$POOL_OWNER_PID"'
        # EXPECT: OK comm=pi pid=<the actual pi ancestor PID>.
        # NOTE: this test only works when run UNDER pi (the agent runtime). If run from
        #       a plain interactive shell with no pi ancestor, POOL_OWNER_PID will be 0
        #       (passthrough) — that is the CORRECT behavior for a human-in-terminal.
  - RUN (REAL MODE: POOL_OWNER_STARTTIME matches the independently-extracted value):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 if [[ "$POOL_OWNER_PID" != "0" ]]; then \
                     indep="$(cut -d" " -f22 /proc/$POOL_OWNER_PID/stat)"; \
                     [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] \
                       && echo "OK st match=$POOL_OWNER_STARTTIME" \
                       || echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; \
                 else echo "SKIP (no pi ancestor in this shell)"; fi'
        # EXPECT (under pi): OK st match=<digits>.
        # EXPECT (plain shell): SKIP (no pi ancestor in this shell).
  - RUN (REAL MODE: POOL_OWNER_CWD matches readlink):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 if [[ "$POOL_OWNER_PID" != "0" ]]; then \
                     indep="$(readlink /proc/$POOL_OWNER_PID/cwd)"; \
                     [[ "$POOL_OWNER_CWD" == "$indep" ]] \
                       && echo "OK cwd match=$POOL_OWNER_CWD" \
                       || echo "FAIL resolved=$POOL_OWNER_CWD indep=$indep"; \
                 else echo "SKIP (no pi ancestor)"; fi'
        # EXPECT (under pi): OK cwd match=<abs path>.
  - RUN (REAL MODE: no pi ancestor → POOL_OWNER_PID=0, COMM=""):
        # Simulate "no pi ancestor" by running in a shell whose ppid chain has no pi.
        # A fresh `bash -c` from THIS agent shell WILL have a pi ancestor, so to truly
        # test the no-ancestor path, run from a context without pi (e.g. a login shell).
        # PRAGMATIC: env AGENT_BROWSER_POOL_OWNER_PID= forces the override path; to test
        # the genuine no-ancestor path, the operator runs from a terminal. Document this.
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 echo "pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM"'
        # EXPECT (under pi): pid=<pi pid> comm=pi.
        # EXPECT (plain shell): pid=0 comm=.
  - RUN (TEST MODE: AGENT_BROWSER_POOL_OWNER_PID override):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="12345" pool_owner_resolve; \
                 [[ "$POOL_OWNER_PID" == "12345" && "$POOL_OWNER_COMM" == "pi" ]] \
                   && echo "OK override pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM"'
        # EXPECT: OK override pid=12345 comm=pi. (12345 is likely dead → STARTTIME/CWD
        #       will be empty, which is correct.)
  - RUN (TEST MODE: AGENT_BROWSER_POOL_OWNER_PID + _OWNER_STARTTIME both set):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="12345" \
                 AGENT_BROWSER_POOL_OWNER_STARTTIME="99999" pool_owner_resolve; \
                 [[ "$POOL_OWNER_PID" == "12345" && "$POOL_OWNER_STARTTIME" == "99999" ]] \
                   && echo "OK override+st pid=$POOL_OWNER_PID st=$POOL_OWNER_STARTTIME"'
        # EXPECT: OK override+st pid=12345 st=99999.
  - RUN (TEST MODE: TEST MODE extracts starttime from a LIVE override PID):
        # Use $$ itself as the "override" PID — it's live, so starttime should populate.
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="$$" pool_owner_resolve; \
                 indep="$(cut -d" " -f22 /proc/$$/stat)"; \
                 [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] \
                   && echo "OK live-override st=$POOL_OWNER_STARTTIME" \
                   || echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"'
        # EXPECT: OK live-override st=<digits>.
  - RUN (TEST MODE: non-numeric override → ignored, PID=0, warning logged, non-fatal):
        tmp_state="$(mktemp -d)"; trap 'rm -rf "$tmp_state"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp_state" \
        AGENT_BROWSER_POOL_OWNER_PID="not-a-number" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
                 [[ "$POOL_OWNER_PID" == "0" ]] && echo "OK ignored"'
        grep -q "invalid AGENT_BROWSER_POOL_OWNER_PID" "$tmp_state/pool.log" && echo "OK logged"
        # EXPECT: OK ignored AND OK logged.
  - RUN (TEST MODE: empty override string → treated as unset → real mode):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="" pool_owner_resolve; \
                 echo "pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM"'
        # EXPECT (under pi): pid=<pi pid> comm=pi (empty override → real walk).
        # EXPECT (plain shell): pid=0 comm=.
  - RUN (RE-RUNNABLE: second call with different override wins):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="111" pool_owner_resolve; \
                 first="$POOL_OWNER_PID"; \
                 AGENT_BROWSER_POOL_OWNER_PID="222" pool_owner_resolve; \
                 [[ "$POOL_OWNER_PID" == "222" ]] \
                   && echo "OK re-runnable first=$first second=$POOL_OWNER_PID"'
        # EXPECT: OK re-runnable first=111 second=222.
  - RUN (Regression: S1 + S2 + S3 + T2.S1 still work after append):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_log pre; pool_config_init; pool_state_init; \
                 _pool_atomic_write "$POOL_LANES_DIR/7.json" "{\"lane\":7}"; \
                 _pool_json_valid "$POOL_LANES_DIR/7.json" && echo lease-valid; \
                 pool_check_btrfs >/dev/null; pool_check_master 2>/dev/null || true; \
                 pool_owner_resolve; echo "owner=$POOL_OWNER_PID/$POOL_OWNER_COMM"'
        test -s "$tmp/state/pool.log" && echo OK
        # EXPECT: lease-valid, owner=<pi pid>/pi (under pi) or owner=0/ (plain shell), OK.
        # NOTE: pool_check_master will pool_die if the master doesn't exist — that's
        #       expected in a tmpdir test; the `2>/dev/null || true` neutralizes it for
        #       this regression smoke (we're only checking the OTHER functions survive).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the two functions, verbatim-ready (append at EOF) -----------------

_pool_owner_starttime() {
    # Echo the process starttime (/proc/<pid>/stat field 22, clock ticks since boot)
    # for PID. Returns 0 + echoes digits on success; returns 1 (NOT fatal, no echo)
    # if the stat file is missing/unreadable. EXTRACTS ONLY — no liveness validation
    # (that's is_owner_alive in P1.M2.T2.S1).
    #
    # ROBUSTNESS: field 2 (comm) is wrapped in parens and MAY contain spaces, which
    # shifts every later field. The PRD §2.19 "NF-19" formula is WRONG on this host
    # (NF=52 → NF-19=field 33, not 22). We strip "pid (comm)" by removing everything
    # up to and including the LAST ')' (greedy), making overall field 22 == field 20
    # of the remainder (offset −2). Verified 2026-07-12: both methods agree (8239564)
    # for comm='pi'. P1.M2.T1.S2 may harden this; CONTRACT: echo digits / return 0,
    # or return 1 (no echo), never exit the process.
    local pid="$1"
    local stat_line after start
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
    [[ -n "$stat_line" ]] || return 1
    after="${stat_line##*)}"                 # greedy: drop through LAST ')'
    start="$(awk '{print $20}' <<<"$after")" # field 22 overall == field 20 of remainder
    [[ -n "$start" ]] || return 1
    printf '%s\n' "$start"
}

pool_owner_resolve() {
    # Resolve the owning pi process and populate POOL_OWNER_* globals.
    # Implements PRD §2.4 step 1 (resolve OWNER), §1.1 (walk ppid to comm=='pi'),
    # and the test-hook overrides of PRD §2.18 / key_findings FINDING 8.
    #
    # LOGIC: (1) TEST MODE if AGENT_BROWSER_POOL_OWNER_PID set+numeric → use directly;
    # (2) REAL MODE walk ppid from $$ to comm=='pi'; (3) no pi ancestor → PID=0
    # (passthrough). NEVER fatal. Globals MUTABLE → re-runnable. One _pool_log/call.

    # Reset globals to defaults every call (re-runnable contract).
    POOL_OWNER_PID="0"; POOL_OWNER_COMM=""; POOL_OWNER_STARTTIME=""; POOL_OWNER_CWD=""
    declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD

    # --- 1. TEST MODE: env-var override -------------------------------------
    if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
        local ovr_pid="$AGENT_BROWSER_POOL_OWNER_PID"
        if [[ ! "$ovr_pid" =~ ^[0-9]+$ ]]; then
            _pool_log "pool_owner_resolve: invalid AGENT_BROWSER_POOL_OWNER_PID='$ovr_pid' (ignored)"
            return 0
        fi
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM
        if [[ -n "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-}" ]]; then
            POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME"; declare -g POOL_OWNER_STARTTIME
        else
            local st=""
            st="$(_pool_owner_starttime "$ovr_pid" 2>/dev/null)" || true
            if [[ -n "$st" ]]; then
                POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
            fi
        fi
        local cwd=""
        cwd="$(readlink "/proc/$ovr_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: TEST MODE owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"
        return 0
    fi

    # --- 2. REAL MODE: walk ppid chain from $$ ------------------------------
    local pid="$$"
    local ppid="" comm="" line="" found_pid="" steps=0
    while (( steps++ < 128 )); do
        comm=""
        IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true
        if [[ "$comm" == "pi" ]]; then
            found_pid="$pid"
            break
        fi
        ppid=""
        if [[ -r "/proc/$pid/status" ]]; then
            while IFS= read -r line; do
                if [[ "$line" == PPid:* ]]; then
                    ppid="${line#PPid:}"
                    ppid="${ppid//[[:space:]]/}"
                    break
                fi
            done < "/proc/$pid/status"
        fi
        if [[ ! "$ppid" =~ ^[0-9]+$ ]]; then break; fi
        if (( ppid == 1 ));  then break; fi
        if (( ppid == 0 ));  then break; fi
        if (( ppid == pid )); then break; fi
        pid="$ppid"
    done

    # --- 3. RESULT ----------------------------------------------------------
    if [[ -n "$found_pid" ]]; then
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM
        local st=""
        st="$(_pool_owner_starttime "$found_pid" 2>/dev/null)" || true
        if [[ -n "$st" ]]; then
            POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
        fi
        local cwd=""
        cwd="$(readlink "/proc/$found_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}" \
                  "cwd=${POOL_OWNER_CWD:-<unknown>}"
        return 0
    fi

    _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
    return 0
}

# --- Critical micro-rules baked into the above ---------------------------------
#  * Globals reset to defaults at the TOP of pool_owner_resolve (re-runnable).
#  * `declare -g POOL_OWNER_*` (mutable, NOT readonly) — test harness re-resolves.
#  * Every `local x; x="$(...)"` two-statement (SC2155).
#  * Every `IFS= read ... < /proc/...` has `2>/dev/null || true` (vanished entry is a
#    clean branch, NOT a set -e abort).
#  * Every `(( ))` inside `if`/`while` (bare `(( ))` returning 0 is fatal under set -e).
#  * Every `[[ =~ ]]` inside `if`/`!` (standalone failing match aborts under set -e).
#  * `${VAR:-}` (with colon-dash) covers unset AND empty (set -u safe).
#  * `${stat_line##*)}` GREEDY strip reaches the LAST ')' even if comm contains ')'.
#  * `${ppid//[[:space:]]/}` strips the TAB from `PPid:\t<N>` → pure digits.
#  * pool_owner_resolve NEVER calls pool_die — resolution is never fatal (passthrough
#    is always valid). Invalid override → log + ignore (PID stays 0).
#  * Exactly ONE _pool_log line per call (never inside the walk loop — it runs on every
#    agent-browser invocation).
#  * _pool_owner_starttime uses the parens-robust extraction (PRD §2.19 NF-19 is WRONG;
#    key_findings FINDING 1 + system_context §6.1 correct it).
```

### Integration Points

```yaml
PRIOR (S1 + S2 + S3 + T2.S1) — consumed, not modified:
  - pool_die()           : S1's exit-1 helper. NOT called by pool_owner_resolve or
                           _pool_owner_starttime (resolution is never fatal).
  - _pool_log()          : S1's logger. Called EXACTLY ONCE per pool_owner_resolve call
                           (the resolved identity or the passthrough reason). _pool_owner_starttime
                           does NOT log (it is a leaf extractor).
  - pool_config_init()   : S2's config resolver. NOT required by pool_owner_resolve
                           (it reads no POOL_* path globals). But _pool_log reads
                           POOL_LOG_PATH / AGENT_BROWSER_POOL_STATE — S1's _pool_log_path
                           has defaults, so logging works either way.
  - _pool_atomic_write / _pool_json_valid / _pool_now / _pool_age_str (T2.S1):
                           NOT called by the owner resolver (no lease I/O here). They
                           are just the functions this subtask appends below.

LATER — provided (the lease layer, wrapper, admin CLI, and tests):
  - P1.M2.T1.S2 (robust starttime extraction): MAY harden _pool_owner_starttime with a
        more robust parser (e.g. handling a comm that contains ')' — extremely rare). The
        CONTRACT this task establishes: echo digits / return 0, or return 1 (no echo),
        never exit the process. If S2 replaces the body, it MUST preserve this contract.
        Coordinate: S2 appends below pool_owner_resolve (EOF); if S2 redefines
        _pool_owner_starttime, the later definition wins on re-source. Preferred: S2
        adds a SEPARATE hardened function and leaves this one as the fallback.
  - P1.M2.T2.S1 (is_owner_alive(pid, starttime)): CONSUMES POOL_OWNER_PID and
        POOL_OWNER_STARTTIME (set by this task). Checks: is the PID still alive? Does its
        current starttime still match the stored value (i.e. not recycled)? This task
        only RESOLVES+STORES; the liveness check is M2.T2.S1.
  - P1.M3.T2.S1 (find_my_lease): scans lanes/*.json for owner.pid==$POOL_OWNER_PID &&
        owner.comm=="pi" && owner.starttime==$POOL_OWNER_STARTTIME. The (pid, starttime)
        pair is the anti-PID-recycling key — if a PID was recycled, starttime differs
        and the lease is treated as stale (reaped).
  - P1.M6.T3.S1 (wrapper lifecycle): if POOL_OWNER_PID==0 → passthrough (exec real binary
        unchanged, no lane magic). Otherwise → find/acquire a lane.
  - P1.M7.T1.S1 (admin status): displays POOL_OWNER_CWD in the lane table (observability).
  - P1.M9.T1.S1 (test harness): sets AGENT_BROWSER_POOL_OWNER_PID=<distinct pid> per
        simulated agent to drive the concurrency harness WITHOUT real pi processes.
        Also sets AGENT_BROWSER_POOL_OWNER_STARTTIME to simulate distinct identities.

CONFIG / DATABASE / ROUTES: none. No new env vars beyond the two test hooks (which are
PRD-mandated, §2.18). No new readonly globals. No dir creation. No lease I/O. The two
test-hook env vars are:
  - AGENT_BROWSER_POOL_OWNER_PID        (test-only; PRD §2.18; code-comment-documented)
  - AGENT_BROWSER_POOL_OWNER_STARTTIME  (test-only; PRD §2.18; code-comment-documented)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the two functions — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. S1+S2+S3+T2.S1).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds). NOTE: tests marked "(under pi)" only pass when the test runner is itself a child
of a `pi` process (the normal agent runtime). Tests marked "(plain shell)" exercise the
passthrough path.

```bash
# 2a. Both functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type _pool_owner_starttime pool_owner_resolve' >/dev/null && echo OK
# Expected: OK.

# 2b. _pool_owner_starttime echoes digits for $$ (the current shell).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         out="$(_pool_owner_starttime "$$")"; [[ "$out" =~ ^[0-9]+$ ]] && echo "OK st=$out"'
# Expected: OK st=<digits>.

# 2c. _pool_owner_starttime AGREES with the naive cut -f22 (sanity: comm='bash' has no spaces).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         a="$(_pool_owner_starttime "$$")"; b="$(cut -d" " -f22 /proc/$$/stat)"; \
         [[ "$a" == "$b" ]] && echo "OK agree=$a" || { echo "FAIL a=$a b=$b"; exit 1; }'
# Expected: OK agree=<digits>.

# 2d. _pool_owner_starttime returns 1 (no echo, no abort) for a dead/missing PID.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_owner_starttime 999999999; then echo "FAIL: should be dead"; \
         else echo "OK: dead pid → return 1"; fi'
# Expected: OK: dead pid → return 1.

# 2e. TEST MODE: AGENT_BROWSER_POOL_OWNER_PID override (dead PID → starttime/cwd empty).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="12345" pool_owner_resolve; \
         [[ "$POOL_OWNER_PID" == "12345" && "$POOL_OWNER_COMM" == "pi" ]] \
           && echo "OK override pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM"'
# Expected: OK override pid=12345 comm=pi.

# 2f. TEST MODE: both override env vars set.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="12345" \
         AGENT_BROWSER_POOL_OWNER_STARTTIME="99999" pool_owner_resolve; \
         [[ "$POOL_OWNER_PID" == "12345" && "$POOL_OWNER_STARTTIME" == "99999" ]] \
           && echo "OK override+st pid=$POOL_OWNER_PID st=$POOL_OWNER_STARTTIME"'
# Expected: OK override+st pid=12345 st=99999.

# 2g. TEST MODE: live override PID ($$) → starttime extracted from /proc.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="$$" pool_owner_resolve; \
         indep="$(cut -d" " -f22 /proc/$$/stat)"; \
         [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] \
           && echo "OK live-override st=$POOL_OWNER_STARTTIME" \
           || { echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; exit 1; }'
# Expected: OK live-override st=<digits>.

# 2h. TEST MODE: non-numeric override → ignored (PID=0), warning logged, non-fatal.
tmp_state="$(mktemp -d)"; trap 'rm -rf "$tmp_state"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp_state" \
AGENT_BROWSER_POOL_OWNER_PID="not-a-number" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
         [[ "$POOL_OWNER_PID" == "0" ]] && echo "OK ignored"' \
  && grep -q "invalid AGENT_BROWSER_POOL_OWNER_PID" "$tmp_state/pool.log" && echo "OK logged"
# Expected: OK ignored AND OK logged.

# 2i. TEST MODE: empty override string → treated as unset → real mode.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="" pool_owner_resolve; \
         echo "pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM"'
# Expected (under pi): pid=<pi pid> comm=pi.
# Expected (plain shell): pid=0 comm=.

# 2j. RE-RUNNABLE: second call with a different override wins (globals reset at top).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="111" pool_owner_resolve; first="$POOL_OWNER_PID"; \
         AGENT_BROWSER_POOL_OWNER_PID="222" pool_owner_resolve; \
         [[ "$POOL_OWNER_PID" == "222" ]] \
           && echo "OK re-runnable first=$first second=$POOL_OWNER_PID"'
# Expected: OK re-runnable first=111 second=222.

# 2k. REAL MODE (under pi): finds the pi ancestor, STARTTIME matches independent extraction.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
         if [[ "$POOL_OWNER_PID" != "0" ]]; then \
           indep="$(cut -d" " -f22 /proc/$POOL_OWNER_PID/stat)"; \
           [[ "$POOL_OWNER_COMM" == "pi" && "$POOL_OWNER_STARTTIME" == "$indep" ]] \
             && echo "OK real pid=$POOL_OWNER_PID st=$POOL_OWNER_STARTTIME" \
             || { echo "FAIL"; exit 1; }; \
         else echo "SKIP (no pi ancestor — run under pi to exercise real mode)"; fi'
# Expected (under pi): OK real pid=<pi pid> st=<digits>.
# Expected (plain shell): SKIP (...).

# 2l. REAL MODE (under pi): CWD matches readlink.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
         if [[ "$POOL_OWNER_PID" != "0" ]]; then \
           indep="$(readlink /proc/$POOL_OWNER_PID/cwd)"; \
           [[ "$POOL_OWNER_CWD" == "$indep" ]] \
             && echo "OK cwd=$POOL_OWNER_CWD" || { echo "FAIL"; exit 1; }; \
         else echo "SKIP (no pi ancestor)"; fi'
# Expected (under pi): OK cwd=<abs path>.

# 2m. REAL MODE (plain shell, no pi ancestor): passthrough — PID=0, COMM="".
#     To truly test this, run from a login shell with no pi ancestor. Under the agent
#     runtime this branch is NOT reachable (there IS a pi ancestor). The TEST MODE
#     override path (2e–2j) is how the test harness simulates distinct agents; the
#     genuine no-ancestor passthrough is exercised by an operator in a terminal.
#     Document this in code comments; do NOT force the test.

# 2n. Regression: S1 + S2 + S3 + T2.S1 still work after the append.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_log pre; pool_config_init; pool_state_init; \
         _pool_atomic_write "$POOL_LANES_DIR/7.json" "{\"lane\":7}"; \
         _pool_json_valid "$POOL_LANES_DIR/7.json" && echo lease-valid; \
         echo "now=$(_pool_now) age=$(_pool_age_str "$(date +%s)")"; \
         pool_owner_resolve; echo "owner=$POOL_OWNER_PID/$POOL_OWNER_COMM"'
test -s "$tmp/state/pool.log" && grep -q pre "$tmp/state/pool.log" && echo OK
# Expected: lease-valid, now=<digits>, age=0s, owner=<pi pid>/pi (or 0/), OK.

# Expected: ALL of 2a–2n pass (with 2k/2l/2n-owner under pi; SKIP under plain shell).
# Debug root cause on any failure (most likely a missing `|| true` on a `read < /proc`,
# a bare `(( ))` outside `if`, a `local x="$(...)"` SC2155, or a `${VAR-}` instead of
# `${VAR:-}`).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. The full file sources cleanly and all prior + new functions are present.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
              _pool_owner_starttime pool_owner_resolve' >/dev/null && echo OK
# Expected: OK (all nine+ are functions; pool_check_btrfs/pool_check_master too if S3 landed).

# 3b. Downstream-consumer smoke test: simulate M3.T2.S1's lease match against the
#     resolved owner identity.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
         echo "M3.T2.S1 would scan lanes for: pid=$POOL_OWNER_PID" \
              "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"; \
         echo "M6.T3 passthrough? $([[ "$POOL_OWNER_PID" == "0" ]] && echo YES || echo NO)"'
# Expected (under pi): "M3.T2.S1 would scan lanes for: pid=<pi pid> comm=pi starttime=<digits>"
#                       "M6.T3 passthrough? NO"
# Expected (plain shell): "... pid=0 comm= starttime=" / "M6.T3 passthrough? YES"

# 3c. Concurrency-simulation smoke test: N "agents" via the override each get a distinct
#     POOL_OWNER_PID (this is exactly what M9.T2.S1's concurrency harness will do).
for i in 1 2 3 4 5; do
  AGENT_BROWSER_POOL_OWNER_PID="$((1000+i))" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
           echo "agent lane-candidate: pid=$POOL_OWNER_PID"' &
done; wait
# Expected: five lines, each "agent lane-candidate: pid=100X" for X in 1..5 — distinct
#           identities, no collision (the override gives each its own PID).

# 3d. No stray repo artifacts from testing (owner resolution reads /proc, writes only
#     to the log via _pool_log — which goes to $POOL_STATE_DIR, a tmpdir in tests).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json|tmp)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts'.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the /proc/<pid>/stat field layout on THIS host (the core correctness claim).
echo "fields in /proc/self/stat: $(wc -w < /proc/self/stat)"
echo "field 22 (starttime, naive cut): $(cut -d' ' -f22 /proc/self/stat)"
echo "field 22 (parens-strip+awk): $(sed 's/.*)//' /proc/self/stat | awk '{print $20}')"
echo "CLK_TCK: $(getconf CLK_TCK)"
# Expected: fields=52; the two starttime extractions AGREE; CLK_TCK=100. This is WHY
#           _pool_owner_starttime uses the parens-strip (robust for any comm) and why the
#           PRD §2.19 NF-19 formula (which assumes NF=41) is wrong on this host.

# 4b. Confirm the ppid-walk actually climbs to a pi ancestor when run under pi.
#     (This is the empirical proof of PRD §1.1 / system_context §2.)
pid=$$
while [[ "$pid" != "1" && -n "$pid" ]]; do
  comm=$(cat /proc/$pid/comm 2>/dev/null)
  echo "pid=$pid comm='$comm'"
  [[ "$comm" == "pi" ]] && { echo "→ pi ancestor found at $pid"; break; }
  pid=$(awk '/^PPid:/ {print $2}' /proc/$pid/status 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] || break
done
# Expected (under pi): the chain climbs bash → pi → ...; "→ pi ancestor found at <pid>".
# Expected (plain shell): the chain climbs to systemd/1 with NO pi; no "found" line.

# 4c. Confirm POOL_OWNER_STARTTIME is a stable identity (does NOT change while the pi
#     process is alive — it only changes on PID recycling). Run resolve twice, 1s apart,
#     and assert the starttime is identical.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; s1="$POOL_OWNER_STARTTIME"; \
         sleep 1; pool_owner_resolve; s2="$POOL_OWNER_STARTTIME"; \
         if [[ -n "$s1" && "$s1" == "$s2" ]]; then echo "OK stable starttime=$s1"; \
         elif [[ -z "$s1" ]]; then echo "SKIP (no pi ancestor / empty starttime)"; \
         else echo "FAIL: starttime changed s1=$s1 s2=$s2"; exit 1; fi'
# Expected (under pi): OK stable starttime=<digits> (proves the value is a usable identity
#           key for M2.T2.S1 is_owner_alive and M3.T2.S1 find_my_lease).

# 4d. Confirm the test-hook override gives a DETERMINISTIC identity (the whole point of
#     PRD §2.18 — the test harness needs reproducible "agent" identities).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         for pid in 1001 1002 1003; do \
           AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$((pid*10))" \
           pool_owner_resolve; \
           echo "override pid=$POOL_OWNER_PID st=$POOL_OWNER_STARTTIME comm=$POOL_OWNER_COMM"; \
           [[ "$POOL_OWNER_PID" == "$pid" && "$POOL_OWNER_STARTTIME" == "$((pid*10))" ]] \
             || { echo "FAIL: non-deterministic"; exit 1; }; \
         done; echo OK'
# Expected: three lines with pid=1001/1002/1003, st=10010/10020/10030, comm=pi; then OK.
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors) — whole file incl. S1 + S2 + S3 + T2.S1.
- [ ] Level 2 snippets 2a–2n all pass (2k/2l under pi; SKIP is acceptable under plain shell).
- [ ] Level 3 snippets 3a–3d all pass.
- [ ] Level 4 snippets 4a–4d confirm the host facts that justify the design (stat field
      layout; ppid-walk climbs to pi; starttime is stable; override is deterministic).

### Feature Validation

- [ ] `_pool_owner_starttime()` and `pool_owner_resolve()` defined and callable after
      `source lib/pool.sh`.
- [ ] `_pool_owner_starttime` echoes a `^[0-9]+$` string for a live PID (return 0);
      returns 1 (no echo) for a dead/missing PID; NEVER calls `pool_die`; NEVER exits
      the process.
- [ ] `_pool_owner_starttime` uses the PARENS-ROBUST extraction (strip to last `)`,
      then field 20 of remainder = field 22 overall) — NOT naive `awk '{print $22}'`.
- [ ] `pool_owner_resolve` under `pi`: sets `POOL_OWNER_PID` to the actual pi ancestor,
      `POOL_OWNER_COMM="pi"`, `POOL_OWNER_STARTTIME` matching `cut -f22`, `POOL_OWNER_CWD`
      matching `readlink` (or empty if unreadable).
- [ ] `pool_owner_resolve` with `AGENT_BROWSER_POOL_OWNER_PID=<pid>` set: uses it
      directly (NO ppid walk), sets PID/COMM/STARTTIME (from override or /proc)/CWD.
- [ ] `pool_owner_resolve` from a plain shell with NO pi ancestor and NO override:
      `POOL_OWNER_PID="0"`, `POOL_OWNER_COMM=""` (passthrough).
- [ ] `pool_owner_resolve` with a non-numeric override: logs a warning, leaves
      `POOL_OWNER_PID="0"`, returns 0 (NEVER fatal).
- [ ] `pool_owner_resolve` NEVER calls `pool_die` and ALWAYS returns 0.
- [ ] `pool_owner_resolve` is RE-RUNNABLE (globals reset at top; second call wins).
- [ ] Exactly ONE `_pool_log` line per `pool_owner_resolve` call (never inside the walk loop).

### Code Quality Validation

- [ ] APPENDED to S1+S2(+S3)+T2.S1's `lib/pool.sh` — all prior functions intact and unmodified.
- [ ] Every `local` capture is two-statement (SC2155 clean): `local x; x="$(...)"`.
- [ ] Every `IFS= read ... < /proc/...` is guarded with `2>/dev/null || true`.
- [ ] Every `(( ))` is inside `if`/`while` (set -e safe).
- [ ] Every `[[ =~ ]]` is inside `if`/`!`/`||` (set -e safe).
- [ ] `${VAR:-}` (colon-dash) used for possibly-unset env vars (set -u safe).
- [ ] `POOL_OWNER_*` globals set via `declare -g` (mutable, NOT readonly) — re-runnable.
- [ ] Globals reset to defaults at the TOP of `pool_owner_resolve` (re-runnable contract).
- [ ] All expansions double-quoted (SC2086 clean).
- [ ] No top-level executable code added beyond function definitions (sourcing stays
      side-effect-free apart from S1's existing `set -euo pipefail`).
- [ ] Naming matches the project convention: `pool_owner_resolve` (public), `_pool_owner_starttime`
      (internal, leading underscore).

### Documentation & Deployment

- [ ] `_pool_owner_starttime` has a leading comment explaining: the parens-robust method,
      WHY the PRD §2.19 NF-19 formula is wrong (key_findings FINDING 1), the contract
      (echo digits / return 0, or return 1 / never fatal), and the handoff to P1.M2.T1.S2.
- [ ] `pool_owner_resolve` has a leading comment explaining: the 3-step logic (test mode /
      real mode / passthrough), the PRD sections it implements (§1.1, §2.4 step 1, §2.18),
      the never-fatal contract, the re-runnable contract, and the one-log-line-per-call rule.
- [ ] The two test-hook env vars (`AGENT_BROWSER_POOL_OWNER_PID`,
      `AGENT_BROWSER_POOL_OWNER_STARTTIME`) are documented in `pool_owner_resolve`'s
      comment as TEST-ONLY (PRD §2.18 / key_findings FINDING 8) — NOT in user-facing docs.
- [ ] No source/PRD/tasks.json/.gitignore files modified.

---

## Anti-Patterns to Avoid

- ❌ Don't use the PRD §2.19 `NF-19` formula for starttime — it's WRONG on this host (NF=52,
  NF-19=field 33, not 22). Use the parens-strip method (`${line##*)}` then field 20 of the
  remainder). key_findings FINDING 1 + system_context §6.1 both verified this.
- ❌ Don't use a naive `awk '{print $22}'` on `/proc/<pid>/stat` — breaks when `comm`
  contains spaces (field 2 is parenthesized). Use the parens-strip.
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155; masks exit
  status under `set -e`). Critical for `cat /proc/...`, `readlink`, `_pool_owner_starttime`.
- ❌ Don't leave a bare `IFS= read ... < /proc/$pid/comm` unguarded — a vanished /proc entry
  makes the redirection fail and `set -e` aborts the caller. Always `2>/dev/null || true`.
- ❌ Don't write a bare `(( expr ))` as a statement — it returns 1 when the result is 0,
  FATAL under `set -e`. Always `if (( ))` / `while (( ))` / `(( )) || ...`.
- ❌ Don't write a standalone `[[ "$v" =~ ^[0-9]+$ ]]` — a failed match returns 1 and aborts
  under `set -e`. Use inside `if`/`!`/`||`.
- ❌ Don't use `${VAR-}` (single dash) for the override check — it only covers *unset*, not
  *empty*. Use `${VAR:-}` (colon-dash) so an empty string is treated as unset.
- ❌ Don't use `readonly` for `POOL_OWNER_*` — they must be MUTABLE so `pool_owner_resolve`
  is re-runnable (test harness calls it repeatedly with different overrides).
- ❌ Don't forget to RESET `POOL_OWNER_*` to defaults at the top of `pool_owner_resolve` —
  without it, a second call that finds no pi ancestor would leave stale globals.
- ❌ Don't call `pool_die` from `pool_owner_resolve` or `_pool_owner_starttime` — owner
  resolution is NEVER fatal (passthrough is always valid). A bad override, a missing
  /proc, a readlink failure → log and continue (or passthrough).
- ❌ Don't log inside the ppid-walk `while` loop — `pool_owner_resolve` runs on EVERY
  `agent-browser` invocation; logging per-step would flood the log. Log EXACTLY ONCE per
  call (the resolved identity or the passthrough reason).
- ❌ Don't implement `is_owner_alive` here — that's P1.M2.T2.S1 (liveness + starttime-
  recycling check). This task only RESOLVES+STORES the identity.
- ❌ Don't scan leases, acquire a lane, or enter passthrough/exec here — those are M3.T2 /
  M5.T1 / M6.T3. This subtask is the resolver + test hooks ONLY.
- ❌ Don't assume the ppid walk always finds a `pi` ancestor — a human running
  `agent-browser` directly in a terminal has NO pi ancestor; that's the `POOL_OWNER_PID=0`
  passthrough case. Test it via the "plain shell" path or the TEST MODE override.
- ❌ Don't assume `PPid:` is space-separated — it's TAB-separated (`PPid:\t<N>`). Use
  `${ppid//[[:space:]]/}` to strip the tab, not `${ppid# }`.
- ❌ Don't recreate S1/S2/S3/T2.S1's deliverables — APPEND only, at EOF.
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any source
  file other than appending to `lib/pool.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The two functions' contracts are unusually precise (explicit I/O table for all four
  resolution contexts; explicit 0/1 extractor contract; explicit never-fatal +
  always-returns-0 + re-runnable + one-log-line rules).
- The two subtle traps were **verified on the host this session**: (1) the PRD §2.19
  `NF-19` starttime formula is WRONG (NF=52 on this host → NF-19=field 33), and the
  parens-strip method (`sed 's/.*)//' | awk '{print $20}'`) yields the correct field 22
  (verified: both = 8239564 for `comm='bash'`) — confirmed in Validation 4a; (2) the ppid
  walk genuinely climbs `bash → pi → timeout → ...` on this host (confirmed in Validation
  4b), proving PRD §1.1's central claim.
- The `set -euo pipefail` interactions (`read < /missing`, bare `(( ))`, standalone
  `[[ =~ ]]`, SC2155) — the four classic bash-strict-mode footguns — are each called out
  with the exact correct idiom (`2>/dev/null || true`; `if (( ))`; inside `if`/`||`;
  two-statement local) and a dedicated Level-2 test.
- The TEST MODE override path is fully specified (PRD §2.18 / FINDING 8) with explicit
  handling of: both-vars-set, only-PID-set-with-live-PID, only-PID-set-with-dead-PID,
  non-numeric-PID (ignored+logged), and empty-string (treated as unset).
- The -1 reflects that the genuine "no pi ancestor → passthrough" branch (2m) is NOT
  reachable when the test runner is itself under `pi` (the normal agent runtime) — it can
  only be exercised by an operator in a terminal or by a dedicated login-shell test. The
  TEST MODE override path (2e–2j) covers the harness's needs, but the raw passthrough
  branch relies on manual/operator validation. The Level-4 4b snippet documents exactly
  how to observe it.
