# PRP — P1.M1.T1.S3: State directory setup + btrfs detection

---

## Goal

**Feature Goal**: Implement the **precheck layer** of `lib/pool.sh` — three functions
that run at the start of every acquire to (a) bring the pool's on-disk state dir into
existence, (b) verify the ephemeral root is on btrfs (refusing an accidental 4.8 GB real
copy), and (c) verify the master template exists and is populated (printing the exact
`cp` command if not). These are the literal, physical enforcement of PRD §2.7 (copy /
master hygiene + "fail loudly on non-btrfs unless `AGENT_CHROME_ALLOW_SLOW_COPY=1`") and
PRD §2.14 ("master-profile missing → fail with the exact `cp` command"; "FS not btrfs →
refuse unless `AGENT_CHROME_ALLOW_SLOW_COPY=1`").

**Deliverable**:
1. Three functions appended to `lib/pool.sh`, in this order, directly below
   `pool_config_init()` (the function delivered by **P1.M1.T1.S2**, treated as a hard
   contract — see Integration Points):
   - `pool_state_init()` — idempotently `mkdir -p $POOL_LANES_DIR` and `touch
     $POOL_LOCK_FILE`.
   - `pool_check_btrfs()` — `findmnt -T` the ephemeral root; die unless btrfs or
     `POOL_ALLOW_SLOW_COPY=1`; echo the detected FSTYPE for callers/tests.
   - `pool_check_master()` — verify `$POOL_MASTER_DIR` exists and is non-empty; die with
     the exact `cp` command otherwise.
2. No new globals, no new env vars, no new files. Pure additions to `lib/pool.sh`.
3. Each function follows the strict-mode-safe patterns verified on this host (see Known
   Gotchas — the `external_deps.md §3.2` findmnt example is **broken** and is NOT to be
   copied).

**Success Definition**:
- `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init` creates
  `$POOL_LANES_DIR` (and parents) and `$POOL_LOCK_FILE` as an empty file, and a second
  call in the same shell is a no-op (no error).
- `pool_check_btrfs` on the default ephemeral root (btrfs, verified) returns 0 and prints
  `btrfs`; with `POOL_EPHEMERAL_ROOT` pointed at a non-btrfs mount it dies with a clear
  message *unless* `POOL_ALLOW_SLOW_COPY=1`, in which case it returns 0 and prints the
  real FSTYPE.
- `pool_check_master` returns 0 when the 4.8 GB master exists and is non-empty; dies with
  an actionable `cp` command (mentioning the literal `$POOL_MASTER_DIR` path) when it is
  missing or empty.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file still sources
  cleanly under `set -euo pipefail`.
- No regressions in S1 (`pool_die`, `_pool_log`) or S2 (`pool_config_init` and the
  `POOL_*` globals).

## User Persona

**Target User**: The downstream acquire flow (P1.M5.T1) and every code path that needs
the pool's runtime state dir to exist or needs to guarantee CoW will work. Also: the
operator who gets a clear, copy-pasteable error message when their environment isn't set
up for the pool.

**Use Case**: At the top of `pool_acquire_*` (M5.T1.S1), immediately after
`pool_config_init`, the flow calls `pool_state_init` then `pool_check_btrfs` then
`pool_check_master`. If any precheck fails, the operator sees a one-line actionable
error and the acquire aborts before any expensive or destructive work (no 4.8 GB real
copy, no half-created lane).

**Pain Points Addressed**:
- State dir doesn't exist yet (system_context §7) → `pool_state_init` creates it
  idempotently so the very first acquire on a fresh install just works.
- PRD §2.7: a non-btrfs FS would silently trigger a 4.8 GB real copy per acquire →
  `pool_check_btrfs` refuses loudly (the `AGENT_CHROME_ALLOW_SLOW_COPY=1` escape hatch
  is honored for slow-CI/non-btrfs hosts).
- PRD §2.14: a missing master currently has no friendly recovery → `pool_check_master`
  prints the exact `cp` command to bootstrap it.

## Why

- **Failure fast, fail loud.** These three functions are the cheapest possible checks
  that run before the expensive parts (flock, CoW copy, Chrome boot). Catching a
  non-btrfs FS or a missing master here saves a 4.8 GB copy, a Chrome launch, and a
  confusing downstream error.
- **The state dir is created lazily, not by install.** system_context §7 confirms the
  state dir does not exist at install time; install.sh (M8.T1.S1) *may* pre-create it,
  but the wrapper must not *assume* it did. `pool_state_init` makes "first acquire on a
  fresh checkout" work without a special install step.
- **Foundation for M3/M4/M5.** Lease I/O (M3.T1) writes to `$POOL_LANES_DIR`; the CoW
  copy (M4.T1.S1) targets `$POOL_EPHEMERAL_ROOT` and reads `$POOL_MASTER_DIR`; the flock
  critical section (M5.T1.S1) locks `$POOL_LOCK_FILE`. All of those assume the prechecks
  have passed.
- **Corrects a latent bug in the architecture doc.** `external_deps.md §3.2` shows a
  `findmnt` invocation **without** `-T` that exits 1 on this host even on btrfs (verified
  — see Known Gotchas). Codifying the correct `findmnt -T` form here prevents that bug
  from being copy-pasted into the implementation.

## What

User-visible behavior: none directly (library functions). Observable contract:

### Success Criteria

- [ ] `pool_state_init()` is defined in `lib/pool.sh`, callable after `source lib/pool.sh`
  (and after `pool_config_init`).
- [ ] After `pool_state_init`: `$POOL_LANES_DIR` exists as a directory (created with
  parents) and `$POOL_LOCK_FILE` exists as a regular file (empty is fine).
- [ ] `pool_state_init` is idempotent: a second call in the same shell is a no-op (exit 0,
  no error, no side-effect beyond touching the lock's mtime).
- [ ] `pool_state_init` calls `pool_die` (exit 1) with a clear message if `mkdir -p` or
  `touch` fails for a real filesystem reason (permission denied, read-only FS, etc.).
- [ ] `pool_check_btrfs()` is defined and callable.
- [ ] `pool_check_btrfs`, on the default btrfs ephemeral root, returns 0 and prints
  exactly `btrfs` to stdout.
- [ ] `pool_check_btrfs`, on a non-btrfs ephemeral root with `POOL_ALLOW_SLOW_COPY=0`,
  calls `pool_die` with a message naming the path, the detected FSTYPE, and the
  `AGENT_CHROME_ALLOW_SLOW_COPY=1` escape hatch.
- [ ] `pool_check_btrfs`, on a non-btrfs ephemeral root with `POOL_ALLOW_SLOW_COPY=1`,
  returns 0 and prints the detected FSTYPE (whatever it is — e.g. `ext4`, `xfs`).
- [ ] `pool_check_btrfs`, on a *nonexistent* ephemeral root (findmnt exits 1, empty
  FSTYPE), is treated as "not btrfs" and follows the same die/escape-hatch rule as a real
  non-btrfs FS (with a message that also mentions the path may not exist).
- [ ] `pool_check_btrfs` uses `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"` (the `-T` /
  `--target` flag is **mandatory** — see Known Gotchas).
- [ ] `pool_check_master()` is defined and callable.
- [ ] `pool_check_master`, when `$POOL_MASTER_DIR` exists and is non-empty, returns 0.
- [ ] `pool_check_master`, when `$POOL_MASTER_DIR` is missing OR empty, calls `pool_die`
  with a message that includes the literal path AND the exact `cp -a --reflink=always
  <src> "$POOL_MASTER_DIR"` command the operator should run.
- [ ] `pool_check_master` does NOT stat the size of the master (4.8 GB stat is slow); it
  tests existence (`-d`) and non-emptiness only.
- [ ] None of the three functions define or modify any `POOL_*` global (they are pure
  consumers of the globals frozen by S2's `pool_config_init`).
- [ ] None of the three functions call `_pool_log` on success (prechecks must be silent on
  the happy path to avoid polluting every acquire); they DO use `pool_die` on fatal errors.
- [ ] `shellcheck lib/pool.sh` clean; `bash -n lib/pool.sh` clean; the whole file sources
  cleanly under `set -euo pipefail`; S1 and S2 deliverables still work.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the exact host-verified
`findmnt` semantics (the `-T` flag is mandatory; the architecture doc's example is
broken), the exact idempotent `mkdir -p` + `touch` pattern, the exact non-empty-dir test,
the exact `cp` command for the master error message (derived from PRD §2.7 + §2.14), the
exact strict-mode-safe capture patterns (`|| true` to neutralize findmnt's exit 1 under
`set -e`), the exact downstream consumer contract (M5.T1 acquire flow), and
copy-pasteable validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.7 (copy/master hygiene + the btrfs-fail-loudly rule + the SingletonLock cleanup
        that happens AFTER copy — note this subtask is the PRECHECK, not the copy itself),
        §2.14 (failure-modes table: "master-profile missing → fail with exact cp command";
        "FS not btrfs → refuse unless AGENT_CHROME_ALLOW_SLOW_COPY=1"), §2.11
        (AGENT_CHROME_ALLOW_SLOW_COPY semantics: unset = refuse).
  pattern: §2.7 line 182 gives the cp form `cp -a --reflink=always <master> <active/N>`.
  gotcha: §2.7 is about the COPY step (M4.T1.S1). Do NOT implement the copy or the
        SingletonLock rm here — only the precheck that runs BEFORE it.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §3.1–§3.3 (copy command, btrfs detection, SingletonLock cleanup) and §5 (config
        vars table — confirms AGENT_CHROME_ALLOW_SLOW_COPY default = unset = refuse).
  pattern: §3.2 shows the INTENDED findmnt logic.
  gotcha: ⚠️ §3.2's findmnt invocation is MISSING the -T/--target flag and is BROKEN on
        this host (verified: exits 1 on existing btrfs dirs). DO NOT copy it verbatim.
        Use `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"` instead. See Known Gotchas.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (state dir layout — acquire.lock, lanes/, chrome-N.log, alerts.log; DOES NOT
        EXIST yet), §8 (ephemeral layout — master-profile = 4.8 GB, active/ exists & empty).
  pattern: §7 → POOL_LANES_DIR = $POOL_STATE_DIR/lanes; POOL_LOCK_FILE = $POOL_STATE_DIR/acquire.lock.
  gotcha: §7 says "Must be created on first run or by install.sh" — pool_state_init is
        the "first run" creation path. Do not assume install.sh ran.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: confirms the host facts these functions depend on (btrfs at the profile root,
        master = 4.8 GB, cp --reflink works). FINDING 3 (no bare ~) is already enforced
        by S2; this subtask inherits absolute POOL_* paths and does no path resolution
        of its own.
  pattern: function-naming convention — pool_* public, _pool_* internal. These three are
        all public (called by the acquire flow), so pool_state_init / pool_check_btrfs /
        pool_check_master (no leading underscore).

# External authoritative docs (for the HOW — findmnt -T)
- url: https://man7.org/linux/man-pages/man8/findmnt.8.html
  why: defines `--target`/`-T` ("display all filesystems containing the specified file or
        directory") vs the default behavior (positional arg matches SOURCE, not the mount
        tree). This is the single most important external fact for this subtask.
  critical: ON THIS HOST (verified 2026-07-12): `findmnt -nno FSTYPE
        "$HOME/.agent-chrome-profiles/active"` (NO -T) → exit 1, empty output; the SAME
        call WITH `-T` → exit 0, prints `btrfs`. The architecture doc's §3.2 example
        omits `-T` and would make pool_check_btrfs ALWAYS die. ALWAYS use `-T`.
  section: the `--target` / `-T` entry and the "Target column" definition.

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: `set -e` (errexit) — `findmnt` legitimately exits 1 when the FS isn't btrfs or the
        path is missing; a bare `fstype="$(findmnt ...)"` would abort under `set -e`.
  critical: neutralize with `|| true`: `fstype="$(findmnt ... 2>/dev/null || true)"`. Then
        test `fstype` with `[[ ]]` (which is exempt from errexit).

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` (two statements) so the
        command's exit status is not masked.
  critical: every `local` capture in these functions must be two-statement form.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions. Universal.

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 created lib/pool.sh with `#!/usr/bin/env bash`, `set -euo pipefail` (propagates
        to callers), `pool_die()` (printf '%s\n' "$*" >&2; exit 1), `_pool_log()`, and
        `_pool_log_path()`. THIS subtask APPENDS to that file; it must NOT recreate any of
        those. Call `pool_die` on fatal errors. Do NOT call `_pool_log` on success.
  pattern: S1's `pool_die` is the canonical exit-1 helper — use it for every fatal
        precheck failure. S1's file ENDS after `_pool_log`; S2 then appended
        `pool_config_init`; THIS subtask appends BELOW `pool_config_init`.
  gotcha: S1 propagates `set -euo pipefail` into the caller. Every subprocess capture
        that can legitimately fail (findmnt) MUST be neutralized with `|| true`.

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 delivers `pool_config_init()` which freezes the POOL_* globals this subtask
        consumes. THIS subtask assumes pool_config_init has ALREADY been called before any
        of its three functions (the acquire flow calls config_init first).
  pattern: the relevant globals (all GUARANTEED absolute, validated, non-empty after
        pool_config_init): POOL_STATE_DIR, POOL_LANES_DIR (= $POOL_STATE_DIR/lanes),
        POOL_LOCK_FILE (= $POOL_STATE_DIR/acquire.lock), POOL_EPHEMERAL_ROOT,
        POOL_MASTER_DIR, POOL_ALLOW_SLOW_COPY (normalized to "0" or "1").
  gotcha: POOL_ALLOW_SLOW_COPY is already normalized to "0"/"1" by S2's _pool_config_bool
        — test it with `[[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]`, NOT against the raw env var
        AGENT_CHROME_ALLOW_SLOW_COPY (which may be unset, "true", etc.). Reading the raw
        env var here would bypass S2's normalization and risk a set -u abort.

- file: plan/001_0f759fe2777c/P1M1T1S3/research/btrfs-findmnt-host-facts.md
  why: the deep-research brief with all host-verified findmnt/mkdir/touch facts and the
        exact strict-mode-safe capture patterns. The "Consolidated patterns" below are
        adapted from it.
  pattern: Fact 1 (findmnt -T mandatory), Fact 2 (findmnt -T exits 1 on missing),
        Fact 3 (findmnt -T walks up to the mount), Fact 4 (mkdir -p + touch idempotent),
        Fact 5 (master = 4.8 GB plain dir; test -d + non-empty only, no size stat).
```

### Current Codebase tree

After **P1.M1.T1.S1** and **P1.M1.T1.S2** are implemented (treated as done), the repo
looks like:

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
├── test/                                 # S1 — empty (.gitkeep)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md
    ├── prd_index.txt
    ├── tasks.json
    ├── P1M1T1S1/PRP.md
    ├── P1M1T1S2/{PRP.md, research/bash-config-init-research.md}
    └── P1M1T1S3/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/btrfs-findmnt-host-facts.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh   # MODIFIED — append pool_state_init, pool_check_btrfs, pool_check_master
└── (nothing else changes this subtask)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
adds the **precheck layer** between configuration (S2) and pool logic (M2–M5). It
appends, in order, directly below `pool_config_init`:

1. `pool_state_init()` — bring the on-disk state dir into existence (idempotent).
2. `pool_check_btrfs()` — refuse non-btrfs unless the escape hatch is set.
3. `pool_check_master()` — refuse a missing/empty master with an actionable `cp` command.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified, 2026-07-12): findmnt REQUIRES the -T/--target flag to detect
# the filesystem of a DIRECTORY PATH. The architecture doc external_deps.md §3.2 shows:
#     FSTYPE=$(findmnt -nno FSTYPE "$EPHEMERAL_ROOT" ...)   # ← NO -T
# That invocation exits 1 and prints NOTHING on this host even when the dir is on btrfs,
# because without -T the positional arg is matched against SOURCE (a device), not the
# mount tree. Verified:
#     findmnt -nno FSTYPE "$HOME/.agent-chrome-profiles/active"      → exit 1, empty
#     findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles/active"   → exit 0, "btrfs"
# ALWAYS use:  findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"

# CRITICAL (host-verified): findmnt -T EXITS 1 on a NONEXISTENT target path. It does NOT
# walk up to the nearest existing ancestor. So if an operator points
# AGENT_CHROME_EPHEMERAL_ROOT at a not-yet-created dir, pool_check_btrfs sees an empty
# FSTYPE. Treat empty FSTYPE as "not btrfs" and follow the die/escape-hatch rule. The
# error message should mention BOTH possibilities (non-btrfs OR missing) so the operator
# knows what to check. (The default active/ DOES exist on this host per system_context §8.)

# CRITICAL (set -e + findmnt): findmnt legitimately returns non-zero (not-btrfs / missing
# path). A bare `fstype="$(findmnt ...)"` ABORTS under set -e (which S1 propagates).
# Neutralize: `fstype="$(findmnt -nno FSTYPE -T "$path" 2>/dev/null || true)"`. The
# `|| true` makes the command-substitution always succeed; fstype becomes "" on failure,
# which the subsequent [[ ]] test handles.

# CRITICAL (SC2155): `local x="$(cmd)"` masks cmd's exit status (and under set -e hides
# failures). ALWAYS: `local x; x="$(cmd)"` — two statements. This matters for the findmnt
# and the ls -A captures below.

# CRITICAL (set -u): S1 propagates set -u. DO NOT read raw env vars (e.g.
# $AGENT_CHROME_ALLOW_SLOW_COPY) in these functions — S2 already normalized that into
# POOL_ALLOW_SLOW_COPY ("0"/"1"). Reading the raw env risks a set -u abort when it's
# unset, AND bypasses S2's normalization. Test POOL_ALLOW_SLOW_COPY with
# [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]].

# GOTCHA (idempotency of mkdir -p / touch): both are idempotent by design. pool_state_init
# needs NO "if not exists" guard. Calling it on every acquire is cheap and correct.
# Verified on host: mkdir -p twice on the same path = no error; touch twice = no error.

# GOTCHA (non-empty dir test under set -e): `ls -A "$dir"` returns non-zero (and prints
# nothing) on an EMPTY dir. Capturing it in `[[ -n "$(ls -A "$dir" 2>/dev/null)" ]]` is
# safe (command substitution + [[ ]] are exempt from errexit). Do NOT use `ls` (which
# includes . and ..) or `[ "$(ls -A)" ]` (the test-builtin form is fine too, but [[ ]] is
# preferred for consistency with the rest of the file). Redirect ls's stderr to avoid
# "No such file or directory" noise when the dir itself is missing (we test -d first
# anyway, but the redirection is belt-and-suspenders).

# GOTCHA (do NOT stat the master size): the master is 4.8 GB. A `du -s` or `stat`
# traversal is slow and unnecessary. Test existence (-d) and non-emptiness (ls -A) only.
# "Non-empty" is sufficient to catch a stray `mkdir` that created the dir without copying
# a profile into it.

# GOTCHA (scope): these are PRECHECKS. Do NOT perform the CoW copy, do NOT rm the
# SingletonLock files, do NOT acquire flock, do NOT read/write leases, do NOT launch
# Chrome. Those belong to M4.T1.S1 (copy), M5.T1.S1 (flock), M4.T2.S2 (launch). This
# subtask only ensures the preconditions for those steps hold.

# GOTCHA (logging): do NOT call _pool_log on the success path. Prechecks run on EVERY
# acquire; logging "btrfs OK" / "master OK" every time would flood the log. Use pool_die
# (stderr + exit 1) for fatal failures. Alert-level logging for exhaustion is M5.T4.S1.

# GOTCHA (no new globals): these three functions are pure CONSUMERS of the POOL_* globals
# set by pool_config_init. They must not `declare -g`, `readonly`, or assign to any POOL_*
# name. (Consistent with S2's decision that all globals live in pool_config_init.)
```

## Implementation Blueprint

### Data models and structure

This subtask defines no data models, no JSON, no globals. It adds three pure side-effect
/ validation functions. Their I/O contract:

| Function | Reads (globals, from S2) | Writes / Side effects | Returns |
|---|---|---|---|
| `pool_state_init` | `POOL_LANES_DIR`, `POOL_LOCK_FILE` | creates `$POOL_LANES_DIR` (mkdir -p, with parents), creates/refreshes `$POOL_LOCK_FILE` (touch) | 0 on success; `pool_die` (exit 1) on real FS error |
| `pool_check_btrfs` | `POOL_EPHEMERAL_ROOT`, `POOL_ALLOW_SLOW_COPY` | none (read-only check) | 0 + echoes FSTYPE when btrfs OR slow-copy allowed; `pool_die` otherwise |
| `pool_check_master` | `POOL_MASTER_DIR` | none (read-only check) | 0 when dir exists & non-empty; `pool_die` (with cp command) otherwise |

**Naming**: all three are public (no leading underscore) — they are called by the acquire
flow and by tests. Matches the `pool_*` convention from `key_findings.md`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the prior PRPs and confirm the file is ready to append
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_die _pool_log pool_config_init'
  - EXPECT: all three reported as functions. (If pool_config_init is MISSING, S2 has not
        landed yet — STOP. This subtask depends on S2's globals. Re-read
        plan/001_0f759fe2777c/P1M1T1S2/PRP.md and treat its deliverable as the starting
        point. Do NOT recreate pool_config_init or the _pool_config_* helpers.)
  - RUN: bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
             echo "LANES=$POOL_LANES_DIR LOCK=$POOL_LOCK_FILE EPH=$POOL_EPHEMERAL_ROOT \
             MASTER=$POOL_MASTER_DIR SLOW=$POOL_ALLOW_SLOW_COPY"'
  - EXPECT: every value is an absolute path (no '~'); POOL_ALLOW_SLOW_COPY is 0 or 1.
  - NOTE: the file ALREADY contains the S1 header, set -euo pipefail, pool_die, _pool_log,
        _pool_log_path, AND S2's _pool_config_* helpers + pool_config_init. APPEND below
        pool_config_init. Do NOT duplicate anything.

Task 1: APPEND pool_state_init() to lib/pool.sh (below pool_config_init)
  - IMPLEMENT: idempotently create the lanes dir and the lock file.
  - BEHAVIOR:
        pool_state_init() {
            # Creates the on-disk pool state dir if missing (PRD §2.11, system_context §7).
            # Idempotent: safe to call on every acquire. Reads POOL_LANES_DIR and
            # POOL_LOCK_FILE (frozen by pool_config_init). Does NOT log on success.
            mkdir -p -- "$POOL_LANES_DIR" \
                || pool_die "pool_state_init: cannot create lanes dir: $POOL_LANES_DIR"
            touch -- "$POOL_LOCK_FILE" \
                || pool_die "pool_state_init: cannot create lock file: $POOL_LOCK_FILE"
            return 0
        }
  - FOLLOW pattern: S1's pool_die for errors. Two-statement where capturing (none needed
        here — mkdir/touch are direct).
  - GOTCHA: `mkdir -p -- ...` and `touch -- ...` — the `--` protects against paths
        starting with '-' (defensive; POOL_* paths are absolute, but `--` is free and
        shellcheck-clean).
  - GOTCHA: the `|| pool_die` form is safe under set -e (the || branch runs on failure,
        pool_die exits). Do NOT write `mkdir -p ... ; pool_die` (that always dies).
  - NAMING: pool_state_init (public).
  - PLACEMENT: directly BELOW pool_config_init (S2's last function).

Task 2: APPEND pool_check_btrfs() to lib/pool.sh (below pool_state_init)
  - IMPLEMENT: detect FSTYPE at POOL_EPHEMERAL_ROOT; die unless btrfs or slow-copy allowed.
  - BEHAVIOR:
        pool_check_btrfs() {
            # Refuses a non-btrfs ephemeral root unless POOL_ALLOW_SLOW_COPY=1 (PRD §2.7,
            # §2.14). Echoes the detected FSTYPE on success (for callers/tests). Uses
            # `findmnt -T` — the -T/--target flag is MANDATORY (a bare findmnt <dir>
            # matches SOURCE, not the mount tree, and exits 1 on this host even on btrfs).
            local fstype
            # `|| true` neutralizes findmnt's legit non-zero exit (missing path / not
            # found) so set -e (propagated by S1) does not abort. fstype becomes "" then.
            fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"

            if [[ "$fstype" == "btrfs" ]]; then
                printf '%s\n' "$fstype"
                return 0
            fi

            # Not btrfs (incl. empty — path missing or findmnt failed).
            if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
                printf '%s\n' "${fstype:-unknown}"
                return 0
            fi

            pool_die "pool_check_btrfs: $POOL_EPHEMERAL_ROOT is not on btrfs" \
                     "(detected: '${fstype:-<empty/missing>}')." \
                     "A real copy of the 4.8 GB master per acquire would be catastrophic." \
                     "Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point" \
                     "AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount."
        }
  - FOLLOW pattern: two-statement local capture (SC2155); `[[ ]]` exempt from errexit;
        `|| true` on the findmnt capture.
  - GOTCHA: read POOL_ALLOW_SLOW_COPY (S2-normalized to "0"/"1"), NOT the raw env var.
  - GOTCHA: the `${fstype:-<empty/missing>}` and `${fstype:-unknown}` forms document the
        empty case in the output without tripping set -u.
  - NAMING: pool_check_btrfs (public).
  - PLACEMENT: directly below pool_state_init.

Task 3: APPEND pool_check_master() to lib/pool.sh (below pool_check_btrfs)
  - IMPLEMENT: verify POOL_MASTER_DIR exists and is non-empty; die with cp command otherwise.
  - BEHAVIOR:
        pool_check_master() {
            # Verifies the master template exists and is populated (PRD §2.7: the master
            # is read-only; §2.14: missing master → fail with the exact cp command).
            # Tests existence (-d) and non-emptiness only — do NOT stat the 4.8 GB size.
            if [[ -d "$POOL_MASTER_DIR" ]] \
               && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
                return 0
            fi

            pool_die "pool_check_master: master template missing or empty:" \
                     "$POOL_MASTER_DIR" \
                     "Create it ONCE by copying a configured Chrome profile, e.g.:" \
                     "  cp -a --reflink=always <your-chrome-profile> \"$POOL_MASTER_DIR\"" \
                     "(see PRD §1.2 — the master is created once, never launched/mutated.)"
        }
  - FOLLOW pattern: `[[ -d ... ]] && [[ -n "$(...)" ]]` — both [[ ]] exempt from errexit;
        the ls capture is in a command substitution (also exempt). Redirect ls stderr to
        silence "No such file or directory" when the dir is missing (we already tested -d
        first, but belt-and-suspenders).
  - GOTCHA: `ls -A` (NOT `ls`) — -A omits `.` and `..` so an "empty" dir really tests empty.
  - GOTCHA: the cp command in the error MUST print the literal $POOL_MASTER_DIR (already
        resolved absolute by S2) so the operator can copy-paste-run. The `<your-chrome-
        profile>` placeholder is intentional — the pool doesn't know the operator's source
        profile; PRD §1.2 says "you create once".
  - GOTCHA: do NOT stat/du the master (4.8 GB, slow). -d + non-empty is the right check.
  - NAMING: pool_check_master (public).
  - PLACEMENT: directly below pool_check_btrfs (last function in the file).

Task 4: VERIFY (do this BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                  # syntax
  - RUN: shellcheck lib/pool.sh                               # zero warnings (whole file)
  - RUN (all three functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 type pool_state_init pool_check_btrfs pool_check_master'
        # EXPECT: all three reported as functions.
  - RUN (pool_state_init creates dir + lock, idempotent):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 pool_state_init; \
                 test -d "$POOL_LANES_DIR" && test -f "$POOL_LOCK_FILE"; \
                 pool_state_init; \
                 echo OK'
        # EXPECT: OK. (Second call is a no-op.)
  - RUN (pool_check_btrfs on default btrfs root → prints btrfs, exit 0):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 out="$(pool_check_btrfs)"; test "$out" = "btrfs"; echo OK'
        # EXPECT: OK. (Host's default active/ is on btrfs.)
  - RUN (pool_check_btrfs on non-btrfs, slow-copy OFF → dies):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_CHROME_EPHEMERAL_ROOT="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_btrfs' \
        ; echo "exit=$?"
        # EXPECT: a pool_die message mentioning not-btrfs + the escape hatch, and exit=1.
        # NOTE: /tmp is typically a tmpfs or ext4 on this host — non-btrfs. If /tmp
        # happens to be btrfs on your test host, point AGENT_CHROME_EPHEMERAL_ROOT at a
        # known non-btrfs mount instead (e.g. /dev/shm if present, or mktemp under /var).
  - RUN (pool_check_btrfs on non-btrfs, slow-copy ON → returns 0, prints FSTYPE):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_CHROME_EPHEMERAL_ROOT="$tmp" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 out="$(pool_check_btrfs)"; test "$out" = "$(pool_check_btrfs)"; \
                 echo "slow-copy OK, fstype=$out"'
        # EXPECT: "slow-copy OK, fstype=<whatever /tmp is>". (Non-empty, exit 0.)
  - RUN (pool_check_btrfs on NONEXISTENT path, slow-copy OFF → dies):
        AGENT_CHROME_EPHEMERAL_ROOT="/tmp/__abp_definitely_missing__$RANDOM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_btrfs' \
        ; echo "exit=$?"
        # EXPECT: pool_die message (mentions empty/missing) + exit=1.
  - RUN (pool_check_master on real master → exit 0):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master; echo OK'
        # EXPECT: OK. (Host has the 4.8 GB master at the default path.)
  - RUN (pool_check_master on missing dir → dies with cp command):
        AGENT_CHROME_MASTER="/tmp/__abp_missing_master__$RANDOM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master' \
        ; echo "exit=$?"
        # EXPECT: pool_die message containing "cp -a --reflink=always" + the literal path, exit=1.
  - RUN (pool_check_master on EMPTY existing dir → dies with cp command):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_CHROME_MASTER="$tmp" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master' \
        ; echo "exit=$?"
        # EXPECT: pool_die message + exit=1 (empty dir fails the non-empty test).
  - RUN (S1 + S2 still work after append — regression):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        POOL_LOG_PATH="$tmp/p.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log pre; pool_config_init; \
                 _pool_log post; pool_state_init; pool_check_btrfs >/dev/null; \
                 pool_check_master'
        test -s "$tmp/p.log" && grep -q pre "$tmp/p.log" && grep -q post "$tmp/p.log" && echo OK
        # EXPECT: OK (two log lines; S1's _pool_log and S2's pool_config_init unbroken).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the three functions, verbatim-ready (append below pool_config_init) -----

pool_state_init() {
    # Creates the on-disk pool state dir if missing (PRD §2.11, system_context §7: the
    # state dir does NOT exist until first run / install). Idempotent: safe to call on
    # every acquire. Reads POOL_LANES_DIR and POOL_LOCK_FILE (frozen by pool_config_init).
    # Silent on success (no _pool_log — prechecks must not flood the log).
    mkdir -p -- "$POOL_LANES_DIR" \
        || pool_die "pool_state_init: cannot create lanes dir: $POOL_LANES_DIR"
    touch -- "$POOL_LOCK_FILE" \
        || pool_die "pool_state_init: cannot create lock file: $POOL_LOCK_FILE"
    return 0
}

pool_check_btrfs() {
    # Refuses a non-btrfs ephemeral root unless POOL_ALLOW_SLOW_COPY=1 (PRD §2.7, §2.14).
    # Echoes the detected FSTYPE on success (handy for callers + tests). Uses `findmnt -T`;
    # the -T/--target flag is MANDATORY — a bare `findmnt <dir>` matches SOURCE (a device),
    # not the mount tree, and exits 1 on this host EVEN ON BTRFS. (external_deps.md §3.2's
    # example omits -T and is broken — do not copy it.)
    local fstype
    # `|| true` neutralizes findmnt's legit non-zero exit (missing path / not found) so
    # set -e (propagated by S1) does not abort. fstype becomes "" in that case.
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"

    if [[ "$fstype" == "btrfs" ]]; then
        printf '%s\n' "$fstype"
        return 0
    fi

    # Not btrfs — including the empty case (path missing or findmnt failed).
    if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
        printf '%s\n' "${fstype:-unknown}"
        return 0
    fi

    pool_die "pool_check_btrfs: $POOL_EPHEMERAL_ROOT is not on btrfs" \
             "(detected: '${fstype:-<empty/missing>}')." \
             "A real copy of the 4.8 GB master per acquire would be catastrophic." \
             "Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point" \
             "AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount."
}

pool_check_master() {
    # Verifies the master template exists and is populated (PRD §2.7: master is read-only,
    # never launched/mutated; §2.14: missing master → fail with the exact cp command).
    # Tests existence (-d) and non-emptiness only — do NOT stat the 4.8 GB size (slow).
    if [[ -d "$POOL_MASTER_DIR" ]] \
       && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
        return 0
    fi

    pool_die "pool_check_master: master template missing or empty:" \
             "$POOL_MASTER_DIR" \
             "Create it ONCE by copying a configured Chrome profile, e.g.:" \
             "  cp -a --reflink=always <your-chrome-profile> \"$POOL_MASTER_DIR\"" \
             "(see PRD §1.2 — the master is created once, never launched/mutated.)"
}

# --- Critical micro-rules baked into the above ---------------------------------
#  * No env var is read directly — only POOL_* globals (frozen + normalized by S2). This
#    keeps set -u happy (raw env may be unset) and respects S2's normalization.
#  * `findmnt ... || true` — findmnt's non-zero exit is a normal "not btrfs/missing"
#    signal, not an error; the `|| true` prevents set -e from aborting the capture.
#  * `local x; x="$(...)"` two-statement form → SC2155-clean, exit status not masked.
#  * `mkdir -p --` / `touch --` / `ls -A ... 2>/dev/null` — the `--` and stderr redirect
#    are defensive (paths are absolute, but `--`/redirect are free and shellcheck-clean).
#  * `[[ ]]` tests are exempt from errexit; the `&&` chain in pool_check_master is safe.
#  * `pool_die` (S1) is the only failure path — it prints to stderr and exits 1.
#  * No _pool_log on success — prechecks are silent on the happy path.
```

### Integration Points

```yaml
PRIOR (S1 + S2) — consumed, not modified:
  - pool_die()           : S1's exit-1 helper. Called on every fatal precheck failure.
  - _pool_log()          : S1's logger. NOT called by these functions on success
                           (prechecks must be silent). Would be appropriate to log ONLY
                           if a future subtask adds alert-level precheck failures.
  - pool_config_init()   : S2's config resolver. MUST be called BEFORE any of these three
                           functions (they read POOL_* globals it freezes). The acquire
                           flow (M5.T1) calls pool_config_init first, then these.
  - POOL_* globals       : POOL_LANES_DIR, POOL_LOCK_FILE (pool_state_init);
                           POOL_EPHEMERAL_ROOT, POOL_ALLOW_SLOW_COPY (pool_check_btrfs);
                           POOL_MASTER_DIR (pool_check_master). All guaranteed absolute,
                           validated, non-empty (paths) / "0"|"1" (bool) by S2.

LATER — provided (the acquire flow and beyond):
  - P1.M5.T1.S1 (acquire critical section): calls pool_state_init, pool_check_btrfs,
        pool_check_master at the very top of acquire (before flock). The flock critical
        section then uses POOL_LOCK_FILE (now guaranteed to exist). Lease I/O uses
        POOL_LANES_DIR (now guaranteed to exist).
  - P1.M3.T1.* (lease I/O): writes $POOL_LANES_DIR/<N>.json — relies on pool_state_init
        having created POOL_LANES_DIR.
  - P1.M4.T1.S1 (btrfs CoW copy): performs `cp -a --reflink=always "$POOL_MASTER_DIR"
        "$POOL_EPHEMERAL_ROOT/<N>"` then `rm -f .../Singleton{Lock,Cookie,Socket}`.
        Relies on pool_check_btrfs (reflink will work) and pool_check_master (source
        exists & is populated) having passed.
  - P1.M8.T1.S1 (install.sh): MAY pre-create the state dir; pool_state_init makes the
        wrapper robust even if install didn't run. install.sh may also reference
        pool_check_master's error message when guiding the operator to bootstrap the
        master.
  - P1.M9.* (tests): will call pool_state_init with AGENT_BROWSER_POOL_STATE pointed at
        a tmpdir; will exercise pool_check_btrfs with a non-btrfs tmpdir + the escape
        hatch; will exercise pool_check_master with a missing/empty dir.

CONFIG / DATABASE / ROUTES: none. No new env vars (all consumed from S2). No new globals.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the three functions — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. S1+S2).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds):

```bash
# 2a. All three functions defined + callable after config_init.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         type pool_state_init pool_check_btrfs pool_check_master' >/dev/null && echo OK
# Expected: OK.

# 2b. pool_state_init creates lanes dir + lock file, idempotent.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         test -d "$POOL_LANES_DIR" && test -f "$POOL_LOCK_FILE"; \
         pool_state_init; echo OK'
# Expected: OK (second call no-ops).

# 2c. pool_state_init dies on a real FS error (point LANES_DIR at an unwritable path
#     by making the parent a file — mkdir -p will fail).
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/notallowed" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init' \
  ; echo "exit=$?"
# Expected: a pool_die message ("cannot create lanes dir...") and exit=1.
# ($tmp is a FILE, so mkdir -p $tmp/notallowed/lanes fails.)

# 2d. pool_check_btrfs on default btrfs root → prints "btrfs", exit 0.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         out="$(pool_check_btrfs)"; test "$out" = "btrfs"; echo OK'
# Expected: OK. (Host default active/ is btrfs.)

# 2e. pool_check_btrfs on non-btrfs, slow-copy OFF → dies.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_CHROME_EPHEMERAL_ROOT="$tmp" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_btrfs' \
  ; echo "exit=$?"
# Expected: pool_die message (mentions not-btrfs + escape hatch) + exit=1.
# (If /tmp is btrfs on your host, swap $tmp for a known non-btrfs path, e.g. /dev/shm.)

# 2f. pool_check_btrfs on non-btrfs, slow-copy ON → exit 0, prints FSTYPE.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_CHROME_EPHEMERAL_ROOT="$tmp" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         out="$(pool_check_btrfs)"; test -n "$out"; echo "OK fstype=$out"'
# Expected: "OK fstype=<non-empty>".

# 2g. pool_check_btrfs on NONEXISTENT path, slow-copy OFF → dies.
AGENT_CHROME_EPHEMERAL_ROOT="/tmp/__abp_missing__$RANDOM" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_btrfs' \
  ; echo "exit=$?"
# Expected: pool_die message (mentions empty/missing) + exit=1.

# 2h. pool_check_master on real 4.8 GB master → exit 0.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master; echo OK'
# Expected: OK.

# 2i. pool_check_master on MISSING dir → dies with cp command.
AGENT_CHROME_MASTER="/tmp/__abp_missing_master__$RANDOM" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master' \
  ; echo "exit=$?"
# Expected: pool_die message containing "cp -a --reflink=always" + the literal master
# path; exit=1.

# 2j. pool_check_master on EMPTY existing dir → dies (non-empty test catches it).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_CHROME_MASTER="$tmp" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_check_master' \
  ; echo "exit=$?"
# Expected: pool_die message + exit=1.

# 2k. Regression: S1 (_pool_log, pool_die) and S2 (pool_config_init + POOL_* globals)
#     still work after the append.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
POOL_LOG_PATH="$tmp/p.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; _pool_log pre; pool_config_init; \
         _pool_log post; pool_state_init; pool_check_btrfs >/dev/null; pool_check_master'
test -s "$tmp/p.log" && grep -q pre "$tmp/p.log" && grep -q post "$tmp/p.log" && echo OK
# Expected: OK.

# Expected: ALL of 2a–2k pass. Debug root cause on any failure (most likely a missing
# `-T` on findmnt, a missing `|| true` on the findmnt capture under set -e, reading the
# raw env var instead of POOL_ALLOW_SLOW_COPY, or a SC2155 local-capture).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. The full file sources cleanly and S1+S2+S3 are all present.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init pool_check_btrfs pool_check_master' \
  >/dev/null && echo OK
# Expected: OK (all six are functions).

# 3b. Downstream-consumer smoke test: simulate the acquire-flow call order.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; \
         pool_config_init; pool_state_init; pool_check_btrfs >/dev/null; pool_check_master; \
         ( flock 9; echo locked ) 9>"$POOL_LOCK_FILE"; \
         echo "lanes=$POOL_LANES_DIR"; test -d "$POOL_LANES_DIR"; echo OK'
# Expected: prints the lanes dir, "locked", and OK — proves the three prechecks set up
#           POOL_LANES_DIR and POOL_LOCK_FILE exactly as M5.T1.S1's flock section needs.

# 3c. No stray repo artifacts from testing (these functions must not create runtime dirs
#     under the repo; all state goes under $POOL_STATE_DIR = a tmpdir in tests).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts'.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the findmnt -T vs no-T distinction on THIS host (the core correctness claim).
findmnt -nno FSTYPE "$HOME/.agent-chrome-profiles/active" 2>/dev/null; echo "no-T exit=$?"
findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles/active" 2>/dev/null; echo "-T exit=$?"
# Expected: no-T exit=1 (empty output); -T exit=0 (prints btrfs). This is WHY pool_check_btrfs
#           MUST use -T and must NOT copy external_deps.md §3.2 verbatim.

# 4b. Confirm findmnt -T exits 1 on a nonexistent path (drives the empty-FSTYPE handling).
findmnt -nno FSTYPE -T "/tmp/__abp_no_such_path__$RANDOM" 2>/dev/null; echo "exit=$?"
# Expected: exit=1, empty output. (pool_check_btrfs treats this as "not btrfs".)

# 4c. Confirm the default ephemeral root reports btrfs (proves 2d is meaningful).
test "$(findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles/active")" = "btrfs" && echo "default is btrfs"
# Expected: "default is btrfs".

# 4d. Confirm the master is non-empty (proves 2h is meaningful).
test -n "$(ls -A "$HOME/.agent-chrome-profiles/master-profile")" && echo "master non-empty"
# Expected: "master non-empty".
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors) — whole file incl. S1 + S2.
- [ ] Level 2 snippets 2a–2k all pass.
- [ ] Level 3 snippets 3a–3c all pass.
- [ ] Level 4 snippets 4a–4d confirm the host facts that justify the design (findmnt -T
      mandatory; findmnt -T exits 1 on missing; default root is btrfs; master non-empty).

### Feature Validation

- [ ] `pool_state_init()`, `pool_check_btrfs()`, `pool_check_master()` defined and callable
      after `source lib/pool.sh` (and `pool_config_init`).
- [ ] `pool_state_init` creates `$POOL_LANES_DIR` + `$POOL_LOCK_FILE`, is idempotent, and
      dies via `pool_die` on a real FS error.
- [ ] `pool_check_btrfs` returns 0 + prints `btrfs` on the default root; dies on
      non-btrfs unless `POOL_ALLOW_SLOW_COPY=1`; uses `findmnt -T` (never bare findmnt).
- [ ] `pool_check_btrfs` treats an empty/missing FSTYPE (nonexistent path) as "not btrfs".
- [ ] `pool_check_master` returns 0 when the master exists & is non-empty; dies with the
      exact `cp -a --reflink=always ... "$POOL_MASTER_DIR"` command otherwise (covering
      both missing AND empty dir).
- [ ] None of the three functions read raw env vars (only S2-normalized `POOL_*` globals).
- [ ] None of the three functions call `_pool_log` on success; all use `pool_die` on fatal
      errors.

### Code Quality Validation

- [ ] APPENDED to S1+S2's `lib/pool.sh` — header, `set -euo pipefail`, `pool_die`,
      `_pool_log`, `_pool_log_path`, `_pool_config_*`, `pool_config_init` all intact.
- [ ] Every `local` capture is two-statement (SC2155 clean).
- [ ] The findmnt capture uses `|| true` to neutralize its legit non-zero exit under
      `set -e`.
- [ ] All expansions double-quoted (SC2086 clean); `--` used on mkdir/touch.
- [ ] No new globals, no `declare -g`, no `readonly`.
- [ ] No top-level executable code added beyond function definitions (sourcing stays
      side-effect-free apart from S1's existing `set -euo pipefail`).
- [ ] Naming matches the project convention: `pool_*` (public, no underscore).
- [ ] No source/PRD/tasks.json/.gitignore files modified.

### Documentation & Deployment

- [ ] Each function has a leading comment explaining its purpose, the PRD sections it
      enforces, and the key gotcha (findmnt -T for pool_check_btrfs; no-size-stat for
      pool_check_master).
- [ ] The findmnt `-T` requirement is called out in code (so a future reader doesn't
      "simplify" it away and reintroduce the §3.2 bug).
- [ ] The master error message is actionable (literal path + copy-paste cp command).

---

## Anti-Patterns to Avoid

- ❌ Don't use `findmnt` WITHOUT `-T`/`--target`. Without `-T` the positional arg matches
  SOURCE (a device), not the mount tree, and exits 1 on this host EVEN ON BTRFS. The
  `external_deps.md §3.2` example omits `-T` and is broken — do not copy it. (Verified.)
- ❌ Don't write `fstype="$(findmnt ...)"` without `|| true`. findmnt legitimately exits 1
  (non-btrfs / missing path) and `set -e` (propagated by S1) would abort the function
  before the `[[ ]]` test runs. Always `fstype="$(findmnt ... 2>/dev/null || true)"`.
- ❌ Don't read `AGENT_CHROME_ALLOW_SLOW_COPY` directly — S2 already normalized it into
  `POOL_ALLOW_SLOW_COPY` ("0"/"1"). Reading the raw var risks a `set -u` abort (when
  unset) and bypasses S2's normalization. Test `[[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]`.
- ❌ Don't `stat`/`du` the master to validate it (4.8 GB, slow). Test `-d` + non-empty
  (`ls -A`) only.
- ❌ Don't use `ls` (instead of `ls -A`) for the non-empty test — plain `ls` on an empty
  dir still succeeds; `ls -A` is what makes an empty dir produce empty output. And wrap
  the capture so an empty dir's non-zero `ls` exit doesn't trip `set -e`.
- ❌ Don't call `_pool_log` on the success path — prechecks run every acquire; logging
  them floods the log. Use `pool_die` for failures only.
- ❌ Don't create the ephemeral root, the master dir, or perform the CoW copy here — those
  are operator (system_context §8) / install.sh (M8) / M4.T1.S1 responsibilities. This
  subtask is the PRECHECK that runs before all of them.
- ❌ Don't acquire flock, read/write leases, reap stale lanes, or launch Chrome here —
  those are M3/M5/M4. These three functions are pure setup + validation.
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155; masks exit
  status under `set -e`).
- ❌ Don't recreate S1's or S2's deliverables — APPEND only, below `pool_config_init`.
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any source
  file other than appending to `lib/pool.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The three functions are small and their contracts are unusually precise (explicit
  I/O table, explicit host-verified findmnt semantics, explicit error-message wording).
- The single most dangerous trap — `findmnt` without `-T` silently exits 1 on btrfs —
  was **verified on the host this session** (Fact 1 in the research brief; Validation
  4a) and is called out in five places (Known Gotchas, Task 2, Implementation Patterns,
  the in-function comment, Anti-Patterns). The architecture doc's §3.2 example that
  embeds this bug is explicitly flagged as broken so the implementer does not copy it.
- The second trap — `findmnt`'s non-zero exit aborting under `set -e` — is handled by the
  documented `|| true` idiom, with the rationale (set -e propagated by S1) stated.
- The scope boundary (these are PRECHECKS, not the copy/launch/lease logic) is stated
  repeatedly to prevent the implementer from over-building into M4/M5 territory.
- The one residual uncertainty (minor): on a test host where `/tmp` is itself btrfs, the
  "non-btrfs" negative tests (2e, 2f, 2g) need a different non-btrfs path — the PRP
  flags this explicitly with a fallback (`/dev/shm` or `/var`). On the actual target host
  `/tmp` is not btrfs (the default profile root is on a separate btrfs mount), so the
  tests pass as written.
