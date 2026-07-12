# PRP — P1.M2.T2.S1: `is_owner_alive(pid, starttime)` — liveness + identity verification

---

## Goal

**Feature Goal**: Implement the **owner liveness + identity-verification predicate**
for the agent-browser-pool — the single function that answers *"is this lease's owner
still alive AND still the SAME process that took the lease?"* PID recycling is a real
OS threat (a crashed `pi`'s PID is eventually handed to an unrelated process), so `pid`
alone is NOT identity. The function defeats recycling by checking three independent
facts in order: (a) the PID exists in `/proc`, (b) its `comm` matches the expected name,
(c) its `starttime` (`/proc/<pid>/stat` field 22, unique per process invocation) matches
the stored value. This is PRD §2.5 (release is *owner-liveness-driven*) and §2.14
(failure modes: "PID recycled into non-pi → comm != pi"; "PID recycled into new pi →
starttime mismatch") made executable. It is the load-bearing predicate behind every
reap/stale decision in the pool.

**Deliverable** (all in `lib/pool.sh`, ONE function appended directly below the existing
`pool_owner_resolve()`, the last function in the file):

1. **ADD** `pool_owner_alive(pid, expected_starttime, expected_comm)` — internal
   predicate. Returns **0** if the owner is alive and identity matches; returns **1**
   (NEVER fatal, never calls `pool_die`) if the PID is missing/dead, the `comm` does not
   match, or the `starttime` does not match. `expected_comm` defaults to `'pi'` when the
   3rd argument is omitted.

   The function is the literal realization of the item's CONTRACT (logic a→b→c→d):
   ```
   a. If /proc/<pid> doesn't exist   → dead               → return 1
   b. /proc/<pid>/comm != expected   → recycled into non-pi → return 1
   c. starttime != expected_starttime → recycled into new pi → return 1
   d. all checks pass                → alive + same process → return 0
   ```

2. No new globals, no on-disk state, no env vars, no user docs ("DOCS: none — internal
   function"). The ONLY thing read is `/proc` (kernel-provided, ephemeral).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh`:
  - `pool_owner_alive "$$" "$(_pool_get_starttime "$$")" "$(cat /proc/$$/comm)"` returns
    **0** (live self, correct comm + starttime).
  - `pool_owner_alive "$$" "1" "$(cat /proc/$$/comm)"` returns **1** (live self, WRONG
    starttime → recycle-into-new-process simulation).
  - `pool_owner_alive "$$" "$(_pool_get_starttime "$$")" "pi"` returns **1** when
    `/proc/$$/comm` is not `pi` (e.g. `bash`) → recycle-into-non-pi simulation.
  - `pool_owner_alive 999999999 "<st>" "pi"` returns **1** (dead PID → `/proc` missing).
  - `pool_owner_alive "abc" "<st>" "pi"` and `pool_owner_alive "" "<st>" "pi"` return
    **1** (input validation — non-numeric/empty pid).
  - `pool_owner_alive "$$" "<st>"` (2-arg form) defaults `expected_comm` to `'pi'`: on a
    `bash` process it returns **1** (default `pi` ≠ `bash`).
- Under the `pi` agent runtime: `pool_owner_resolve` finds the real pi ancestor, and
  `pool_owner_alive "$POOL_OWNER_PID" "$POOL_OWNER_STARTTIME"` (2-arg form, default
  comm `pi`) returns **0** (the realistic happy path).
- `pool_owner_alive` NEVER calls `pool_die`, NEVER writes, NEVER logs (leaf predicate —
  callers log/act), and NEVER aborts under `set -euo pipefail`.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (S1–T2.S1, M2.T1.S1, M2.T1.S2's `_pool_get_starttime`) unchanged.

## User Persona

**Target User**: Internal only — no end user or operator ever calls `pool_owner_alive`.
Its consumers are all later subtasks inside `lib/pool.sh` / the two wrappers:

- **P1.M3.T2.S3** (`is_lane_stale(lane)`) — scans a lane lease's `owner.{pid,comm,starttime}`
  and calls `pool_owner_alive` to decide whether the lane is stale (reaper-able). PRD §2.5
  ("Release is owner-liveness-driven"), §2.9 ("Owning pi exits ... detected by next
  acquire's REAP-STALE").
- **P1.M5.T3.S1** (`reap_stale()`) — the lazy reaper invoked on every acquire; uses
  `pool_owner_alive` to find dead/stale owners and tear down their lanes (kill pgroup,
  rm ephemeral dir, delete lease). PRD §2.10 (Reaper — "IQ3 = lazy, on acquire").
- **P1.M5.T1.S3** (`ensure_connected`) — on every invocation, confirm the lane's owner is
  still alive before reusing it; a stale owner triggers release+re-acquire instead of
  silently stealing a recycled PID's lane. PRD §2.4 step 4 (ENSURE CONNECTED).
- **P1.M5.T3.S2** (`reuse_orphan`) — adopts a *responsive* Chrome whose owner is dead;
  `pool_owner_alive` is the "owner is dead" oracle that distinguishes adoptable orphans
  from live-but-merely-disconnected lanes.

**Use Case**: The single question "is lease owner X still the process that took the
lease?" is asked (transitively) on EVERY `agent-browser` invocation (via
ensure_connected at §2.4 step 4) and on every acquire (via reap_stale). It is the core
correctness gate that prevents lane theft by a recycled PID.

**Pain Points Addressed**:
- **PID recycling → lane theft.** Without identity verification, after a `pi` crash its
  PID could be reused by an unrelated process (or another `pi`), and the stale lease
  would silently bind that new process to the dead owner's lane — corrupting browser
  state, leaking tabs, or handing one agent's profile to another. The `(pid, comm,
  starttime)` triple is the industry-standard fix (systemd, psmisc, procps-ng all use it
  — see research note §5). `pool_owner_alive` is where that triple is checked.
- **`kill -0` false-dead trap.** A naive `kill -0 $pid` returns 1 on `EPERM` (process
  exists but owned by another uid) — indistinguishable from `ESRCH` (truly dead). The
  `/proc/<pid>`-existence check used here never conflates the two (research note §3).
  Documented here so future maintainers don't "optimize" toward `kill -0`.

## Why

- **It is the correctness spine of owner-liveness-driven release.** PRD §2.5 makes
  release *owner-liveness-driven, not TTL-driven* — there is no idle timer. Every release
  decision (REAP-STALE on acquire, pool-exhaustion force-reap, explicit `release`)
  ultimately asks "is this owner dead/stale?" `pool_owner_alive` IS that question. If it
  is wrong, either (a) live owners get reaped (constant churn, redundant Chrome copies)
  or (b) dead/recycled owners keep their lanes (resource leak, eventual exhaustion, or
  lane theft). key_findings FINDING 1 + system_context §6 + the research note all
  confirm the `(pid, starttime)` approach is correct and host-verified.
- **It cleanly separates "is the owner alive+same?" from "resolve/store the owner".**
  `pool_owner_resolve` (M2.T1.S1) RESOLVES and STORES the current shell's owner into
  `POOL_OWNER_*`. `pool_owner_alive` checks an ARBITRARY stored (pid, starttime, comm)
  triple against what `/proc` says NOW. Splitting them keeps each function
  single-purpose and independently testable — and `pool_owner_alive` is reusable for
  any owner PID in any lease, not just the current shell's.
- **It makes the three failure modes in PRD §2.14 executable and distinguishable.** §2.14
  enumerates "agent pi crash/kill → owner pid dead", "PID recycled into non-pi → comm
  != pi", "PID recycled into new pi → starttime mismatch". This function implements all
  three as early-return branches, so callers (reaper) get a single boolean ("stale") and
  don't need to re-implement the `/proc` dance per call site.

## What

User-visible behavior: none directly (internal library predicate). Observable contract:

| `pool_owner_alive` args | Return | Reason |
|---|---|---|
| `pid expected_starttime [expected_comm]` — live PID, comm matches, starttime matches | **0** | alive + same process (PRD §2.14 all-clear) |
| pid missing / `/proc/<pid>` absent (dead/crashed owner) | **1** | dead (§2.14 "owner pid dead") |
| live PID but `comm` ≠ `expected_comm` | **1** | recycled into non-pi (§2.14 "comm != pi") |
| live PID, comm matches, but `starttime` ≠ `expected_starttime` | **1** | recycled into a new pi (§2.14 "starttime mismatch") |
| non-numeric / empty pid (input validation) | **1** | not a verifiable PID |
| `expected_starttime` empty/non-numeric, live PID | **1** | can't verify identity → safe-stale (live process always has a non-empty starttime → mismatch) |
| 2-arg form (omit `expected_comm`) | as above | `expected_comm` defaults to `'pi'` |

**Hard invariants** (every cell above):
- NEVER calls `pool_die`; NEVER writes to disk; NEVER logs (leaf predicate — callers
  log the decision); NEVER exits non-zero except via its own `return 1`.
- NEVER aborts under `set -euo pipefail`: every `/proc` read is TOCTOU-guarded
  (`2>/dev/null` + `|| return 1`); every `[[ ]]` is in a control-flow context.

### Success Criteria

- [ ] `pool_owner_alive` is defined in `lib/pool.sh`, callable after `source lib/pool.sh`
  (needs no `pool_config_init` — it reads no `POOL_*` globals), appended directly below
  `pool_owner_resolve()`.
- [ ] Returns **0** for a live PID whose `comm` and `starttime` both match the expected
  values (verified for `$$` and for the real pi ancestor under `pi`).
- [ ] Returns **1** for each of: dead/missing PID; live PID with wrong `comm`; live PID
  with wrong `starttime`; non-numeric/empty pid; empty `expected_starttime` against a
  live process.
- [ ] The 2-arg form defaults `expected_comm` to `'pi'` (verified: 2-arg call on a `bash`
  process returns 1; 3-arg call with `bash` returns 0).
- [ ] The check order is **existence → comm → starttime** (existence is cheapest/most-
  likely-to-fail; `comm` rejects the common recycle-into-unrelated-binary case before
  paying for the `stat` parse; `starttime` is the authoritative tie-breaker). See
  research note §4.4.
- [ ] Uses `_pool_get_starttime "$pid"` (provided by P1.M2.T1.S2) for the starttime read
  — does NOT re-parse `/proc/<pid>/stat` itself (one parser, the canonical one).
- [ ] `comm` is read via `$(cat "/proc/$pid/comm" 2>/dev/null)` — command substitution
  strips the trailing newline, so comparison against `expected_comm` is apples-to-apples
  (no manual strip). The RHS of the `[[ == ]]` comparison is QUOTED (prevents glob
  matching if `expected_comm` ever contained `*`/`?`/`[`).
- [ ] NEVER calls `pool_die`, NEVER writes, NEVER logs, NEVER aborts under strict mode.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; all prior deliverables
  unchanged; `_pool_get_starttime`/`_pool_owner_starttime`/`pool_owner_resolve`
  (T1.S1 + T1.S2) untouched.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified `/proc`
facts (comm is the bare name + trailing newline, stripped by `$(...)`; `comm` truncated
to 15 chars — zero risk for `'pi'`; `starttime` is field 22, unique per invocation,
read via the already-landed `_pool_get_starttime`; `/proc/<pid>` is a directory for live
PIDs; dead PID → ENOENT — ALL verified this session); the paste-ready function body with
every `set -euo pipefail` guard baked in; the host-verified validation commands for
every branch (live-self, recycle-newproc, comm-mismatch, dead-pid, non-numeric,
empty-starttime, default-comm proof, real-pi integration); the exact dependency contract
on the parallel T1.S2 (`_pool_get_starttime` exists and echoes digits/0 or 1/no-echo);
the exact placement (append below `pool_owner_resolve`, do NOT touch T1.S1/T1.S2
functions); and the authoritative external references (proc(5), kill(2) for the
`kill -0` EPERM trap, SC2155, bash manual).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.5 (Release is owner-liveness-driven, NOT TTL — this predicate is the
        liveness oracle), §2.8 (lease owner carries {pid, comm, starttime}; "starttime
        defeats PID recycling into a new pi"), §2.14 (the THREE failure modes this
        function encodes as branches: pid dead / comm != pi / starttime mismatch),
        §2.4 step 4 (ENSURE CONNECTED consumes liveness on every invocation),
        §2.10 (Reaper — lazy, on acquire — consumes liveness to find stale lanes).
  pattern: §2.14's table is the literal a/b/c/d decision ladder.
  gotcha: §2.19's "NF-19" starttime formula is WRONG — irrelevant here because we
        call _pool_get_starttime (T1.S2 owns the correct parser); do NOT re-parse.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §6 ("/proc Parsing — CRITICAL FINDING"): starttime = field 22; §6.2 comm is
        available BARE at /proc/<pid>/comm (no parens); confirms the data sources this
        predicate reads. §2 confirms the pi-ancestor PID walk works on this host.
  pattern: §6.2's bare-comm read is what this function uses for the comm check.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 1 (starttime parsing — why the (pid,starttime) pair defeats recycling),
        the "Function Naming Convention" (pool_owner_* = owner resolution subdomain;
        this function is pool_owner_alive per the item description's CONTRACT).
  pattern: the (pid, starttime) anti-recycling key is the whole reason this function
        exists.

- file: plan/001_0f759fe2777c/P1M2T1S1/PRP.md   # T1.S1 — landed (CONTRACT)
  why: T1.S1 LANDED pool_owner_resolve() + _pool_owner_starttime() in lib/pool.sh.
        pool_owner_alive is APPENDED directly below pool_owner_resolve. T1.S1 also
        established the set -euo pipefail traps (SC2155, cat /missing aborts,
        [[ =~ ]] inside if) that this function must obey.
  pattern: T1.S1's _pool_owner_starttime (the parens-robust extractor) is the
        historical ancestor of the parser pool_owner_alive now consumes via
        _pool_get_starttime.

- file: plan/001_0f759fe2777c/P1M2T1S2/PRP.md   # T1.S2 — parallel, treated as LANDED (CONTRACT)
  why: T1.S2 ADDS _pool_get_starttime(pid) — the canonical robust starttime extractor
        that THIS function calls in step (c). T1.S2's _pool_get_starttime CONTRACT:
        echoes a digits-only string + returns 0 on success; returns 1 (no echo, never
        fatal) for a missing/non-numeric PID or an unreadable/garbled stat line.
        pool_owner_alive's `actual_starttime="$(_pool_get_starttime "$pid"
        2>/dev/null)" || return 1` relies on EXACTLY this contract. T1.S2 also reduces
        _pool_owner_starttime to a delegating wrapper — do NOT touch either function.
  pattern: T1.S2 Task 1's paste-ready _pool_get_starttime body is the thing this PRP
        calls; treat it as already-present and correct.
  gotcha: this subtask DEPENDS ON T1.S2 (tasks.json lists P1.M2.T1.S2 as a dependency).
        If _pool_get_starttime is NOT yet present when implementation starts, STOP — the
        orchestrator sequences T1.S2 first. Task 0 below verifies it.

- file: plan/001_0f759fe2777c/P1M2T2S1/research/liveness-and-pid-recycling.md
  why: THIS task's own research — the comm semantics (§1: bare name, 15-char truncation
        no risk for 'pi', trailing newline stripped by $(...)), why starttime defeats
        recycling (§2), the kill -0 EPERM false-dead trap + why /proc existence is
        preferable (§3), the TOCTOU best-effort pattern (§4), how systemd/psmisc/procps
        do identity checks (§5), and the bash strict-mode traps (§6).
  pattern: §4.2 is the reference ladder (existence → comm → starttime) and the exact
        guard shape used below.

# External authoritative docs (for the HOW + the WHY)
- url: https://man7.org/linux/man-pages/man5/proc.5.html
  why: authoritative definition of /proc/[pid]/comm ("The command name ... will be
        truncated to TASK_COMM_LEN (16) characters"), /proc/[pid]/stat field 22
        (starttime), and pid recycling (pid_max). Confirms the data sources this
        predicate reads.
  critical: ON THIS HOST (verified 2026-07-12): /proc/self/comm = bare name + '\n'
        (od -c confirmed the trailing newline); 'pi' is 2 chars (zero truncation risk);
        /proc/self is a directory (-d and -e both true); dead PID 999999999 →
        "No such file or directory"; stat field 22 = ~8.33M ticks; 52 total fields.
  section: "/proc/[pid]/comm", "/proc/[pid]/stat" (field table, field 22).

- url: https://man7.org/linux/man-pages/man2/kill.2.html
  why: the `kill -0` EPERM-vs-ESRCH trap — kill(2) returns EPERM (process exists but
        not yours) OR ESRCH (no such process); the shell cannot distinguish (both exit
        1). This is WHY the predicate uses /proc existence instead of kill -0.
  critical: a future "optimization" to `kill -0 "$pid"` would report LIVE foreign
        processes as dead → false reaps. /proc existence never conflates the two.
  section: "ERRORS" (ESRCH, EPERM).

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` so cmd's exit status is
        not masked. The function declares `local comm actual_starttime` at the top, then
        assigns separately, so `comm="$(cat ...)" || return 1` correctly reflects cat's
        status.
  critical: do NOT write `local comm="$(cat ...)"` (masks failure under set -e).

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit exemptions — the condition of `if`/`&&`/`||` and the inside of `[[ ]]`
        in those conditions are EXEMPT from set -e. So `[[ -d /proc/$pid ]] || return 1`
        and `[[ "$comm" == "$expected_comm" ]] || return 1` are safe (the `||` list is
        exempt for all but the last command).
  section: errexit (`-e`).

- url: https://www.gnu.org/software/bash/manual/bash.html#Command-Substitution
  why: "$(...)` strips ALL trailing newlines — so `$(cat /proc/$pid/comm)` yields the
        bare name ('pi', no '\n') without any manual strip. This is why the comm
        comparison is apples-to-apples with expected_comm.
  section: Command Substitution.

- url: https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs
  why: in `[[ string1 == string2 ]]`, the RIGHT-HAND string2 is treated as a GLOB
        PATTERN when UNQUOTED. If expected_comm ever contained `*`/`?`/`[`, an unquoted
        RHS would silently pattern-match. ALWAYS quote: `[[ "$comm" == "$expected_comm" ]]`.
  section: Conditional Constructs (Pattern Matching).
```

### Current Codebase tree

After **S1, S2, S3, T2.S1, M2.T1.S1, and M2.T1.S2** have landed, the repo looks like:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # S1 — empty
├── lib/
│   └── pool.sh                           # S1 header+set -euo pipefail+pool_die+_pool_log
│                                         # + S2 _pool_config_* + pool_config_init
│                                         # + S3 pool_state_init/pool_check_btrfs/pool_check_master
│                                         # + T2.S1 _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str
│                                         # + M2.T1.S1 _pool_owner_starttime + pool_owner_resolve  (LANDED)
│                                         # + M2.T1.S2 _pool_get_starttime + wrapper conversion      (parallel→laned)
├── test/.gitkeep                         # empty
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1/.../PRP.md
    ├── P1M1T1S2/.../PRP.md
    ├── P1M1T1S3/.../PRP.md
    ├── P1M1T2S1/.../PRP.md
    ├── P1M2T1S1/.../PRP.md
    ├── P1M2T1S2/.../PRP.md
    └── P1M2T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/liveness-and-pid-recycling.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND pool_owner_alive() directly below pool_owner_resolve()
                  #   (a new "Owner liveness" section banner; NO changes to any other function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
appends ONE predicate — the owner liveness + identity check — closing out the Owner
resolution & identity layer (M2). It consumes the canonical extractor
`_pool_get_starttime` (T1.S2) and is consumed by the lease-staleness/reaper layer (M3/M5).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (hard dependency on T1.S2): this function CALLS _pool_get_starttime "$pid"
# in step (c). That function is delivered by P1.M2.T1.S2 (parallel). Its CONTRACT:
# echoes digits + return 0 on success; return 1 (no echo, never fatal) for a
# missing/non-numeric PID or a garbled stat line. This predicate treats extraction
# failure (process died mid-read, or garbled stat) as "not verifiably alive" → return 1.
# Do NOT re-implement stat parsing here — call _pool_get_starttime. One parser, the
# canonical one. If _pool_get_starttime is absent at implementation time, STOP (Task 0
# verifies it; the orchestrator sequences T1.S2 before T2.S1).

# CRITICAL (kill -0 is a TRAP — do NOT use it): `kill -0 "$pid"` returns 1 BOTH for
# ESRCH (truly dead) AND EPERM (alive but owned by another uid) — the shell cannot
# distinguish. A live foreign process would be reported DEAD. The /proc/<pid> existence
# check (`[[ -d /proc/$pid ]]`) never conflates the two. Stick with /proc. The pool
# owner is the same uid anyway, but /proc is correct in general AND is needed for the
# comm/stat reads regardless (single source of truth — no kill -0 + /proc mixing).
# (research note §3.)

# CRITICAL (comm is truncated to 15 chars — TASK_COMM_LEN=16): /proc/<pid>/comm is at
# most 15 usable chars + NUL. 'pi' is 2 chars → ZERO truncation/collision risk. The
# 15-char limit only matters for long executable names; document it but do NOT pad/trim
# expected_comm. (research note §1.2.)

# CRITICAL ($(cat ...) strips the trailing newline): /proc/<pid>/comm has a trailing
# '\n' (od -c verified). `comm="$(cat /proc/$pid/comm)"` strips ALL trailing newlines,
# so `comm` is the bare name ('pi') with no '\n'. Therefore comparison against
# expected_comm needs NO manual strip — as long as expected_comm was captured the same
# way (it is: pool_owner_resolve reads /proc/<pid>/comm the same way, and the lease
# stores owner.comm="pi" literally). DO NOT add a manual `${comm%$'\n'}` — it's already
# gone. (research note §1.3, §6.4.)

# CRITICAL (quote the RHS of [[ == ]]): `[[ "$comm" == $expected_comm ]]` (UNquoted RHS)
# treats expected_comm as a GLOB PATTERN — if it ever contained *, ?, or [, it would
# pattern-match instead of compare literally. ALWAYS quote: [[ "$comm" == "$expected_comm" ]].
# expected_comm is normally the literal 'pi', but quoting is the safe universal rule.

# CRITICAL (set -e + cat /missing): `comm="$(cat /proc/$pid/comm")"` whose cat FAILS
# (process vanished between the -d check and the read — TOCTOU, or EACCES) returns
# non-zero. Because comm is a PLAIN variable (not a `local x=$(...)` — see SC2155), the
# assignment's exit status == cat's status, so `|| return 1` fires correctly. The
# 2>/dev/null suppresses the shell's "No such file" message. ALWAYS:
# `comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1`.

# CRITICAL (SC2155 — declare and assign SEPARATELY): `local x="$(cmd)"` masks cmd's
# exit status (and under set -e hides failures). This function declares
# `local pid expected_starttime expected_comm comm actual_starttime` FIRST, then assigns
# each separately. The captures (`comm="$(cat ...)"`, `actual_starttime="$(... )"`)
# are PLAIN assignments (not `local x=$(...)`), so their exit status is preserved and
# `|| return 1` works. NEVER write `local comm="$(cat ...)"`.

# CRITICAL (set -e + [[ ]]): a bare `[[ -d /proc/$pid ]]` that is false returns 1 and
# ABORTS under set -e. ALWAYS use `[[ ... ]] || return 1` (the `||` list is errexit-
# exempt) or `if [[ ... ]]`. Same for `[[ =~ ]]` and `[[ == ]]`.

# CRITICAL (set -u — default the positionals): callers may invoke the 2-arg form
# (expected_comm omitted). Use `local expected_comm="${3:-pi}"` so an unset $3 does not
# abort under set -u. Use `${1:-}` / `${2:-}` for pid/expected_starttime and validate.

# GOTCHA (TOCTOU is acceptable — best-effort predicate): a process can die between the
# -d check and the comm read, or between the comm read and the starttime read. Each
# read is independently guarded (|| return 1), so a mid-function death yields return 1
# (stale), which is SAFE (the reaper tears it down; the caller re-runs on the next
# acquire). Even a clean return 0 only proves liveness at the instant of the last read
# — the caller must be idempotent. This is the universally accepted liveness-probe
# design. (research note §4.)

# GOTCHA (placement — do NOT touch T1.S1/T1.S2): APPEND pool_owner_alive directly below
# pool_owner_resolve() (the last function in the file after T1.S1+T1.S2 land). Do NOT
# modify _pool_get_starttime, _pool_owner_starttime, or pool_owner_resolve. T1.S2 owns
# the starttime parser; this task only consumes it. Editing those functions is out of
# scope and risks a conflict with the parallel T1.S2 change.

# GOTCHA (ordering — existence → comm → starttime): this order is deliberate. Existence
# is cheapest and the most common failure (process gone). comm is one tiny read and
# rejects the common "PID recycled into an unrelated binary" case BEFORE paying for the
# stat parse. starttime is the authoritative tie-breaker for the rare "recycled into a
# process that happens to share comm" case. Do NOT reorder. (research note §4.4.)

# GOTCHA (empty expected_starttime → safe-stale): if a lease's owner.starttime is empty
# (owner resolution couldn't extract it — a degenerate lease) and the process is live,
# actual_starttime (digits) != "" → mismatch → return 1 (stale). This is the SAFE
# choice: when identity can't be verified, reap and re-acquire rather than risk lane
# theft. No special-case branch is needed — the normal mismatch path handles it.

# GOTCHA (no logging): this is a LEAF predicate. It must NOT call _pool_log (it runs on
# every invocation via ensure_connected — logging would flood the pool log). Callers
# (is_lane_stale, reaper) log the DECISION ("reaping lane N: owner pid dead"). Keep
# this function silent.

# GOTCHA (scope): this task is the liveness+identity PREDICATE ONLY. Do NOT: scan leases
# (M3.T2); reap/teardown a lane (M5.T2/M5.T3); adopt an orphan (M5.T3.S2); implement
# ensure_connected (M5.T1.S3); read/write lease JSON (M3.T1). This is one pure boolean.
```

## Implementation Blueprint

### Data models and structure

No JSON, no on-disk schema, no globals, no env vars. This subtask defines ONE function
in the existing "Owner resolution" / new "Owner liveness" section of `lib/pool.sh`:

| Symbol | Kind | Visibility | Change | Consumed by |
|---|---|---|---|---|
| `pool_owner_alive` | function (returns 0\|1, echoes nothing) | internal (owner subdomain; `pool_owner_*` per naming convention) | **NEW** | is_lane_stale (M3.T2.S3), reap_stale (M5.T3.S1), ensure_connected (M5.T1.S3), reuse_orphan (M5.T3.S2) |

**Naming**: the item description's CONTRACT literally specifies
`pool_owner_alive(pid, starttime, comm)`. key_findings' "Function Naming Convention"
reserves `pool_owner_*` for the owner-resolution/identity subdomain. This predicate
belongs to that subdomain (it answers "is THIS owner alive/same?"). It carries no `_`
prefix, matching the sibling `pool_owner_resolve` (also internal-to-the-pool but the
owner-subdomain entry point). The function echoes NOTHING (return-code-only predicate) —
unlike `_pool_get_starttime` which echoes digits.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependency (_pool_get_starttime from T1.S2) is present and the file is ready
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type _pool_get_starttime pool_owner_resolve pool_owner_alive' 2>&1
  - EXPECT: _pool_get_starttime and pool_owner_resolve reported as functions.
        pool_owner_alive reported as NOT FOUND (this task creates it). If
        _pool_get_starttime is MISSING, STOP — this subtask depends on P1.M2.T1.S2
        (tasks.json dependency); the orchestrator sequences it first. Do NOT
        re-implement starttime parsing here.
  - RUN (confirm _pool_get_starttime works — sanity check the contract):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 s="$(_pool_get_starttime "$$")"; [[ "$s" =~ ^[0-9]+$ ]] && echo "OK dep st=$s"'
  - EXPECT: OK dep st=<digits>. (If this fails, T1.S2 is not landed — stop.)
  - RUN (locate the append point — pool_owner_resolve must be the last function):
        grep -nE '^[a-z_][a-z_0-9]*\(\)' lib/pool.sh | tail -3
  - EXPECT: pool_owner_resolve is the LAST function listed. Append directly below its
        closing `}`.
  - RUN (file is otherwise clean):
        bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_owner_alive(pid, expected_starttime, expected_comm) to lib/pool.sh
  - PLACEMENT: directly below pool_owner_resolve()'s closing `}` (the current EOF after
        T1.S1+T1.S2). Add a section banner comment:
        # =============================================================================
        # Owner liveness & identity verification (P1.M2.T2.S1)
        # =============================================================================
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_owner_alive PID EXPECTED_STARTTIME [EXPECTED_COMM]
        #
        # Predicate: is the lease owner PID still alive AND still the SAME process that
        # took the lease? Returns 0 (alive + identity matches) or 1 (dead / recycled /
        # unverifiable). NEVER fatal — never calls pool_die, never writes, never logs
        # (leaf predicate; callers log the decision).
        #
        # WHY THREE CHECKS (PRD §2.5 owner-liveness-driven release, §2.14 failure modes,
        # key_findings FINDING 1, research note §2/§4):
        #   PID recycling is real: after a pi crash, the kernel hands that PID number to
        #   an UNRELATED process. pid alone is NOT identity. The (pid, comm, starttime)
        #   triple IS — starttime (field 22 of /proc/<pid>/stat, clock ticks since boot)
        #   is unique per process invocation and strictly increases for a recycled PID.
        #   This triple is the industry-standard identity check (systemd, psmisc,
        #   procps-ng; research note §5).
        #
        # DECISION LADDER (order matters — cheapest/most-likely-fail first; research §4.4):
        #   a. /proc/<pid> missing                → dead              → return 1
        #   b. /proc/<pid>/comm != EXPECTED_COMM  → recycled (non-pi) → return 1
        #   c. starttime != EXPECTED_STARTTIME    → recycled (new pi) → return 1
        #   d. all pass                           → alive + same      → return 0
        #
        # GOTCHA — kill -0 is a TRAP (research note §3, kill(2)): `kill -0 $pid` returns
        # 1 for BOTH ESRCH (dead) and EPERM (alive but not yours) — the shell cannot
        # tell them apart, so a live foreign process looks dead. We use /proc/<pid>
        # existence, which never conflates them. /proc is also needed for comm/stat, so
        # one source of truth.
        #
        # GOTCHA — comm truncation (research note §1.2): /proc/<pid>/comm is at most 15
        # chars (TASK_COMM_LEN=16). 'pi' is 2 chars → zero risk. Do not pad/trim.
        #
        # GOTCHA — TOCTOU (research note §4): a process can die between checks. Each
        # /proc read is independently guarded (|| return 1), so a mid-function death
        # yields return 1 (stale) — SAFE. The caller must be idempotent (reaper re-runs
        # on next acquire). Even return 0 only proves liveness at that instant.
        pool_owner_alive() {
            local pid="${1:-}"
            local expected_starttime="${2:-}"
            local expected_comm="${3:-pi}"
            local comm actual_starttime

            # Input validation: pid must be a non-negative integer. A non-numeric/empty
            # pid is not a verifiable owner → return 1. `[[ =~ ]] || return 1` is safe
            # under set -e (the `||` list is errexit-exempt).
            [[ "$pid" =~ ^[0-9]+$ ]] || return 1

            # (a) Liveness: /proc/<pid> must exist (it is a directory for live PIDs;
            # verified -d/-e both true on host). A dead process has no /proc entry.
            [[ -d "/proc/$pid" ]] || return 1

            # (b) Image-name first pass: read /proc/<pid>/comm. `$(cat ...)` strips the
            # trailing newline (bash Command Substitution), so comm is the bare name
            # with no '\n' — no manual strip needed. If the read fails (process died
            # mid-function → TOCTOU, or EACCES), treat as dead. PLAIN assignment (not
            # `local x=$(...)`) so cat's exit status is preserved → `|| return 1` works.
            # Quote the RHS of [[ == ]] so a glob-y expected_comm can't pattern-match.
            comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
            [[ "$comm" == "$expected_comm" ]] || return 1

            # (c) Authoritative identity token: starttime via the canonical extractor
            # _pool_get_starttime (P1.M2.T1.S2). It echoes digits/return 0 on success,
            # return 1 (no echo, never fatal) on failure (process died, garbled stat).
            # Extraction failure → not verifiably alive → return 1.
            actual_starttime="$(_pool_get_starttime "$pid" 2>/dev/null)" || return 1
            [[ "$actual_starttime" == "$expected_starttime" ]] || return 1

            # (d) Alive and the same process invocation that took the lease.
            return 0
        }
  - FOLLOW pattern: `local pid="${1:-}"` (set -u safe for omitted args); `local` declared
        FIRST, assignments AFTER (SC2155 — so `|| return 1` on captures reflects the
        command's real status); every `[[ ]]` in a `|| return 1` / control-flow context
        (errexit-exempt); every `/proc` read guarded with `2>/dev/null`; RHS of `[[ == ]]`
        QUOTED; NEVER pool_die, NEVER write, NEVER log.
  - GOTCHA: use `_pool_get_starttime "$pid"` — do NOT re-implement stat parsing.
  - GOTCHA: the function echoes NOTHING (return-code-only). Callers branch on `$?`.
  - NAMING: pool_owner_alive (item-description-mandated; owner subdomain).
  - PLACEMENT: directly below pool_owner_resolve().

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_owner_alive' >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (happy path: live self, correct comm+starttime → 0):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; st="$(_pool_get_starttime "$me")"; comm="$(cat /proc/$me/comm)"; \
                 if pool_owner_alive "$me" "$st" "$comm"; then echo "OK live-self -> 0"; \
                 else echo "FAIL live-self"; exit 1; fi'
        # EXPECT: OK live-self -> 0. ($$ comm is 'bash' under bash -c; we pass it explicitly.)
  - RUN (recycle-into-new-process: WRONG starttime → 1):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; comm="$(cat /proc/$me/comm)"; \
                 if pool_owner_alive "$me" "1" "$comm"; then echo "FAIL"; \
                 else echo "OK recycle-newproc -> 1"; fi'
        # EXPECT: OK recycle-newproc -> 1.
  - RUN (recycle-into-non-pi: WRONG comm → 1):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; st="$(_pool_get_starttime "$me")"; \
                 if pool_owner_alive "$me" "$st" "pi"; then echo "FAIL"; \
                 else echo "OK comm-mismatch -> 1"; fi'
        # EXPECT: OK comm-mismatch -> 1. ($$ comm is 'bash', not 'pi'.)
  - RUN (dead PID → 1):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if pool_owner_alive 999999999 "1" "pi"; then echo "FAIL"; \
                 else echo "OK dead -> 1"; fi'
        # EXPECT: OK dead -> 1 (and NO output from the function itself).
  - RUN (input validation: non-numeric + empty pid → 1, never fatal):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 pool_owner_alive "abc" "1" "pi"; a=$?; \
                 pool_owner_alive "" "1" "pi"; b=$?; \
                 if (( a == 1 && b == 1 )); then echo "OK input-validation"; \
                 else echo "FAIL a=$a b=$b"; exit 1; fi'
        # EXPECT: OK input-validation. (( )) inside if is errexit-exempt.
  - RUN (empty expected_starttime, live process → 1 — safe-stale):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; comm="$(cat /proc/$me/comm)"; \
                 if pool_owner_alive "$me" "" "$comm"; then echo "FAIL"; \
                 else echo "OK empty-st -> 1"; fi'
        # EXPECT: OK empty-st -> 1. (Live process has non-empty starttime → mismatch.)
  - RUN (DEFAULT comm='pi' — self-contained proof, no pi process needed):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; st="$(_pool_get_starttime "$me")"; \
                 if pool_owner_alive "$me" "$st"; then echo "FAIL (default should mismatch bash)"; \
                 else echo "OK default=pi mismatches bash -> 1"; fi; \
                 if pool_owner_alive "$me" "$st" "bash"; then echo "OK explicit bash -> 0"; \
                 else echo "FAIL explicit"; exit 1; fi'
        # EXPECT: OK default=pi mismatches bash -> 1  AND  OK explicit bash -> 0.
        #       (Proves the 2-arg form defaults expected_comm to 'pi'.)
  - RUN (INTEGRATION under pi: real pi ancestor, 2-arg default-comm → 0):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 if [[ "$POOL_OWNER_PID" != "0" ]]; then \
                   if pool_owner_alive "$POOL_OWNER_PID" "$POOL_OWNER_STARTTIME"; then \
                     echo "OK real-pi default-comm -> 0 (pid=$POOL_OWNER_PID)"; \
                   else echo "FAIL real-pi"; exit 1; fi; \
                   if pool_owner_alive "$POOL_OWNER_PID" "1"; then echo "FAIL"; \
                   else echo "OK real-pi wrong-st -> 1"; fi; \
                 else echo "SKIP (no pi ancestor — run under pi)"; fi'
        # EXPECT (under pi): OK real-pi default-comm -> 0 ... OK real-pi wrong-st -> 1.
        # EXPECT (plain shell): SKIP.
  - RUN (TOCTOU — child killed before probe → 1):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 sleep 100 & c=$!; st="$(_pool_get_starttime "$c")"; \
                 kill -9 "$c" 2>/dev/null || true; sleep 0.2; \
                 if pool_owner_alive "$c" "$st" "sleep"; then echo "FAIL"; \
                 else echo "OK dead-child-toctou -> 1"; fi'
        # EXPECT: OK dead-child-toctou -> 1.
  - RUN (NEVER writes/logs/dies — leaf predicate):
        # The function body must contain NO pool_die, NO _pool_log, NO write/printf to
        # files, NO mv/rm. Assert it.
        bash -c '
            body="$(sed -n "/^pool_owner_alive() {/,/^}/p" lib/pool.sh)"
            if grep -qE "pool_die|_pool_log|>>? *[\"/]|\brm |mv -f" <<<"$body"; then
                echo "FAIL: body has side effects:"; echo "$body"; exit 1; fi
            grep -q "_pool_get_starttime \"\$pid\"" <<<"$body" && echo "OK pure-predicate-uses-extractor" \
                || { echo "FAIL: missing _pool_get_starttime call"; exit 1; }
        '
        # EXPECT: OK pure-predicate-uses-extractor.
  - RUN (regression: all prior functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime _pool_owner_starttime pool_owner_resolve \
                      pool_owner_alive >/dev/null && echo OK'
        # EXPECT: OK (all functions, including the new pool_owner_alive, callable).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the predicate (paste below pool_owner_resolve, after a section banner) --

pool_owner_alive() {
    # [full comment block from Task 1 — documents the ladder, kill-0 trap, truncation,
    #  TOCTOU, and why the (pid,comm,starttime) triple defeats recycling]
    local pid="${1:-}"
    local expected_starttime="${2:-}"
    local expected_comm="${3:-pi}"
    local comm actual_starttime

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1          # input validation (errexit-exempt)
    [[ -d "/proc/$pid" ]] || return 1             # (a) liveness
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1   # (b) comm read (TOCTOU-guarded)
    [[ "$comm" == "$expected_comm" ]] || return 1             # (b) comm match (RHS quoted)
    actual_starttime="$(_pool_get_starttime "$pid" 2>/dev/null)" || return 1  # (c) identity
    [[ "$actual_starttime" == "$expected_starttime" ]] || return 1            # (c) starttime match
    return 0                                      # (d) alive + same process
}

# --- Critical micro-rules baked into the above --------------------------------
#  * `local pid="${1:-}"` etc. — set -u safe for omitted args (2-arg form omits comm).
#  * `local` declared FIRST (separate statement), assignments AFTER — SC2155. This is
#    what makes `comm="$(cat ...)" || return 1` correctly reflect cat's exit status: a
#    PLAIN assignment's status == the command-substitution's status (unlike
#    `local x="$(cmd)"` which masks it). NEVER write `local comm="$(cat ...)"`.
#  * `[[ -d /proc/$pid ]]` — a procfs entry is a DIRECTORY for live PIDs (host-verified).
#    Do NOT use `kill -0` (EPERM/ESRCH ambiguity → false-dead trap; research note §3).
#  * `$(cat /proc/$pid/comm)` strips the trailing newline automatically — comm is the
#    bare name. No manual `${comm%$'\n'}`. Quote expected_comm: `[[ "$comm" ==
#    "$expected_comm" ]]` (unquoted RHS is a glob pattern).
#  * `_pool_get_starttime "$pid"` — the canonical extractor (T1.S2). Do NOT re-parse
#    /proc/<pid>/stat. One parser.
#  * Every `[[ ]]` is in `... || return 1` (errexit-exempt via the `||` list) — a bare
#    false `[[ ]]` would ABORT under set -e.
#  * NEVER pool_die / NEVER _pool_log / NEVER write — this is a leaf return-code-only
#    predicate. Callers log the decision and act.
#  * NEVER echo — callers branch on `$?` (`if pool_owner_alive ...; then ...`).
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth):
  - _pool_get_starttime(pid) (P1.M2.T1.S2): the canonical starttime extractor. Called in
        step (c). Contract: echoes digits/return 0 on success; return 1 (no echo, never
        fatal) for missing/non-numeric pid or garbled stat. THIS TASK HARD-DEPENDS ON IT
        (tasks.json dependency: P1.M2.T1.S2). If absent → stop (orchestrator sequences it).
  - _pool_owner_starttime / pool_owner_resolve (P1.M2.T1.S1, possibly wrapped by T1.S2):
        NOT called by pool_owner_alive (it takes explicit args, not the globals). But the
        realistic integration test reads POOL_OWNER_PID/STARTTIME (set by pool_owner_resolve)
        to exercise the default-comm path against the real pi ancestor.
  - pool_die / _pool_log (S1): NOT called (leaf predicate).

PROVIDED (the consumers — later subtasks):
  - P1.M3.T2.S3 (is_lane_stale(lane)): reads a lease's owner.{pid,comm,starttime} and
        calls `if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then alive; else
        stale; fi`. The boolean this function returns IS the stale/alive verdict.
  - P1.M5.T3.S1 (reap_stale): on every acquire, scans lanes; for each, calls
        pool_owner_alive to find dead/recycled owners and tears them down (kill pgroup,
        rm ephemeral dir, delete lease). PRD §2.10 (lazy reaper).
  - P1.M5.T1.S3 (ensure_connected): PRD §2.4 step 4 — on every invocation, confirm the
        lane owner is still alive before reuse; stale → release+re-acquire (never steal a
        recycled PID's lane).
  - P1.M5.T3.S2 (reuse_orphan): adopts a responsive Chrome whose owner is dead;
        pool_owner_alive is the "owner dead" oracle.

CONFIG / DATABASE / ROUTES: none. No new env vars, no globals, no dir I/O, no lease I/O.
The only thing read is /proc (kernel-provided, ephemeral). No user docs ("internal
function"). The function is appended as a pure in-memory predicate.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending pool_owner_alive — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. all prior subtasks).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds). NOTE: the "under pi" tests pass when the runner is a child of a `pi` process
(the normal agent runtime); under a plain interactive shell they print SKIP — correct.

```bash
# 2a. Function defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_owner_alive' >/dev/null && echo OK
# Expected: OK.

# 2b. Happy path: live self, correct comm+starttime → 0.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; st="$(_pool_get_starttime "$me")"; comm="$(cat /proc/$me/comm)"; \
         if pool_owner_alive "$me" "$st" "$comm"; then echo "OK live-self -> 0"; else echo FAIL; exit 1; fi'
# Expected: OK live-self -> 0.

# 2c. Recycle-into-new-process: WRONG starttime → 1.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; comm="$(cat /proc/$me/comm)"; \
         if pool_owner_alive "$me" "1" "$comm"; then echo FAIL; else echo "OK recycle-newproc -> 1"; fi'
# Expected: OK recycle-newproc -> 1.

# 2d. Recycle-into-non-pi: WRONG comm → 1.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; st="$(_pool_get_starttime "$me")"; \
         if pool_owner_alive "$me" "$st" "pi"; then echo FAIL; else echo "OK comm-mismatch -> 1"; fi'
# Expected: OK comm-mismatch -> 1. ($$ comm is 'bash'.)

# 2e. Dead PID → 1, no echo, no abort.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if pool_owner_alive 999999999 "1" "pi"; then echo FAIL; else echo "OK dead -> 1"; fi'
# Expected: OK dead -> 1.

# 2f. Input validation: non-numeric + empty pid → 1, never fatal.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         pool_owner_alive "abc" "1" "pi"; a=$?; pool_owner_alive "" "1" "pi"; b=$?; \
         if (( a == 1 && b == 1 )); then echo "OK input-validation"; else echo "FAIL a=$a b=$b"; exit 1; fi'
# Expected: OK input-validation.

# 2g. Empty expected_starttime, live process → 1 (safe-stale).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; comm="$(cat /proc/$me/comm)"; \
         if pool_owner_alive "$me" "" "$comm"; then echo FAIL; else echo "OK empty-st -> 1"; fi'
# Expected: OK empty-st -> 1.

# 2h. DEFAULT comm='pi' (2-arg form) — self-contained proof.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; st="$(_pool_get_starttime "$me")"; \
         if pool_owner_alive "$me" "$st"; then echo "FAIL (default should mismatch bash)"; \
         else echo "OK default=pi mismatches bash -> 1"; fi; \
         if pool_owner_alive "$me" "$st" "bash"; then echo "OK explicit bash -> 0"; else echo FAIL; exit 1; fi'
# Expected: OK default=pi mismatches bash -> 1  AND  OK explicit bash -> 0.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Full file sources; all prior + new functions present + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
              _pool_get_starttime _pool_owner_starttime pool_owner_resolve \
              pool_owner_alive >/dev/null && echo OK'
# Expected: OK.

# 3b. INTEGRATION under pi: real pi ancestor from pool_owner_resolve, default-comm → 0.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
         if [[ "$POOL_OWNER_PID" != "0" ]]; then \
           if pool_owner_alive "$POOL_OWNER_PID" "$POOL_OWNER_STARTTIME"; then \
             echo "OK real-pi -> 0 (pid=$POOL_OWNER_PID st=$POOL_OWNER_STARTTIME)"; \
           else echo FAIL; exit 1; fi; \
           if pool_owner_alive "$POOL_OWNER_PID" "1"; then echo FAIL; \
           else echo "OK real-pi wrong-st -> 1"; fi; \
         else echo "SKIP (no pi ancestor — run under pi)"; fi'
# Expected (under pi): OK real-pi -> 0 ... OK real-pi wrong-st -> 1. (plain shell): SKIP.

# 3c. TOCTOU: child killed before probe → 1 (each read independently guarded).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         sleep 100 & c=$!; st="$(_pool_get_starttime "$c")"; \
         kill -9 "$c" 2>/dev/null || true; sleep 0.2; \
         if pool_owner_alive "$c" "$st" "sleep"; then echo FAIL; else echo "OK toctou-dead-child -> 1"; fi'
# Expected: OK toctou-dead-child -> 1.

# 3d. Downstream-consumer simulation: how is_lane_stale/reaper will USE the predicate.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         me=$$; st="$(_pool_get_starttime "$me")"; comm="$(cat /proc/$me/comm)"; \
         # simulate a lease owner record, then ask: is this owner still alive+same?
         owner_pid="$me"; owner_starttime="$st"; owner_comm="$comm"; \
         if pool_owner_alive "$owner_pid" "$owner_starttime" "$owner_comm"; then \
           echo "lane is LIVE (reuse)"; else echo "lane is STALE (reap)"; fi'
# Expected: lane is LIVE (reuse).

# 3e. No stray repo artifacts (the predicate reads /proc only; writes nothing).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json|tmp)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts' (only lib/pool.sh modified).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Re-confirm the host /proc facts the predicate depends on.
echo "self comm: $(cat /proc/self/comm) (len=$(cat /proc/self/comm | tr -d '\n' | wc -c))"
echo "self comm has trailing newline:"; od -c /proc/self/comm | tail -1
echo "self field22: $(cut -d' ' -f22 /proc/self/stat)"
echo "self is dir: $(test -d /proc/self && echo yes || echo no)"
echo "dead pid: $(ls -ld /proc/999999999 2>&1)"
# Expected: self comm = a 2-3 char name; od -c shows trailing '\n'; field22 = digits;
#       self is dir: yes; dead pid: "No such file or directory".

# 4b. Prove comm truncation does NOT affect 'pi' (defensive — research note §1.2).
# 'pi' is 2 chars << 15-char TASK_COMM_LEN limit. Confirm the real pi process reads back 'pi'.
pi_pid="$(pgrep -x pi | head -1 || true)"
if [[ -n "$pi_pid" ]]; then
  echo "pi pid=$pi_pid comm='$(cat /proc/$pi_pid/comm)' (len=$(cat /proc/$pi_pid/comm | tr -d '\n' | wc -c))"
else echo "no pi process on host (skip)"; fi
# Expected: pi pid=<digits> comm='pi' (len=2). Confirms no truncation/collision for the
#       pool's expected_comm='pi'.

# 4c. Prove the (pid, starttime) pair is STABLE for a live process (only recycling
#     changes it) — the property pool_owner_alive relies on.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         s1="$(_pool_get_starttime "$$")"; sleep 1; s2="$(_pool_get_starttime "$$")"; \
         [[ "$s1" == "$s2" ]] && echo "OK stable=$s1" || echo "FAIL $s1 vs $s2"'
# Expected: OK stable=<digits>. (A live process's starttime never changes; a recycled PID
#       would have a different one → pool_owner_alive correctly returns 1.)

# 4d. Prove the predicate is the SAME shape the industry uses — verify _pool_get_starttime
#     agrees with the kernel-doc parens-strip method (research note §2.5).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         a="$(_pool_get_starttime "$$")"; r="$(sed "s/.*)//" /proc/$$/stat | awk "{print \$20}")"; \
         [[ "$a" == "$r" ]] && echo "OK parser-agrees=$a" || echo "FAIL a=$a r=$r"'
# Expected: OK parser-agrees=<digits>.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n lib/pool.sh` clean (no syntax errors).
- [ ] `shellcheck lib/pool.sh` clean (whole file, zero warnings).
- [ ] File sources cleanly under `set -euo pipefail`.

### Feature Validation

- [ ] `pool_owner_alive` returns **0** for live PID + matching comm + matching starttime
      (2b, 2h-explicit, 3b under pi).
- [ ] Returns **1** for each failure mode: dead PID (2e), wrong comm (2d), wrong
      starttime (2c), non-numeric/empty pid (2f), empty expected_starttime (2g).
- [ ] 2-arg form defaults `expected_comm` to `'pi'` (2h: default mismatches `bash`;
      explicit `bash` matches).
- [ ] Check order is existence → comm → starttime (Task 1 body).
- [ ] Uses `_pool_get_starttime "$pid"` (does NOT re-parse stat) — verified by the
      pure-predicate grep in Task 2.
- [ ] NEVER calls `pool_die` / `_pool_log` / writes — verified by the side-effect grep.
- [ ] TOCTOU-safe: dead-child probe returns 1 (3c).

### Code Quality Validation

- [ ] Follows existing `pool_owner_*` naming convention (item-description-mandated name).
- [ ] Appended directly below `pool_owner_resolve()` (the file's last function); no other
      function modified (`git diff lib/pool.sh` shows ONLY the append).
- [ ] `local` declared separately from assignment (SC2155); every `[[ ]]` in a
      control-flow context; every `/proc` read TOCTOU-guarded; RHS of `[[ == ]]` quoted.
- [ ] Anti-patterns avoided (see below): no `kill -0`, no `local x=$(...)`, no re-parsing
      stat, no logging, no manual comm-newline strip.

### Documentation & Deployment

- [ ] No new env vars / globals / user docs (internal function per item spec).
- [ ] Function doc-comment documents the ladder, the `kill -0` trap, comm truncation, and
      TOCTOU (so future maintainers don't reintroduce the footguns).

---

## Anti-Patterns to Avoid

- ❌ **Don't use `kill -0 "$pid"`** for liveness — EPERM (alive, not yours) is
  indistinguishable from ESRCH (dead) at the shell level → false-dead on foreign
  processes. Use `/proc/<pid>` existence. (research note §3.)
- ❌ **Don't re-parse `/proc/<pid>/stat`** for starttime — call `_pool_get_starttime`
  (one canonical parser; T1.S2 owns it). Re-parsing risks the NF-19 bug and duplication.
- ❌ **Don't write `local x="$(cmd)"`** — it masks the command's exit status (SC2155) so
  `|| return 1` can't catch a failed `cat`/`_pool_get_starttime`. Declare `local` first,
  assign separately.
- ❌ **Don't leave a bare `[[ ]]`/`[[ =~ ]]`** as a statement — a false result aborts
  under `set -e`. Always `[[ ... ]] || return 1` or `if [[ ... ]]`.
- ❌ **Don't forget to quote the RHS** of `[[ "$comm" == "$expected_comm" ]]` — an
  unquoted RHS is a glob pattern.
- ❌ **Don't manually strip a trailing newline** from `comm` — `$(cat ...)` already strips
  all trailing newlines. Redundant code risks divergence.
- ❌ **Don't reorder the checks** — existence (cheapest, most-likely-fail) → comm (cheap
  image-name rejection) → starttime (authoritative tie-breaker). See research note §4.4.
- ❌ **Don't call `pool_die` or `_pool_log`** — this is a leaf predicate that runs on every
  invocation (via ensure_connected). Logging would flood; dying would crash the wrapper.
  Callers log the decision.
- ❌ **Don't touch `_pool_get_starttime` / `_pool_owner_starttime` / `pool_owner_resolve`**
  — T1.S1/T1.S2 own them. This task only APPENDS `pool_owner_alive`.
- ❌ **Don't hardcode `'pi'` as a magic literal in the comparison** without the `${3:-pi}`
  default — callers must be able to pass a different comm (tests do, future lanes might).
  The default belongs ONLY in the parameter expansion, not inline.
```
