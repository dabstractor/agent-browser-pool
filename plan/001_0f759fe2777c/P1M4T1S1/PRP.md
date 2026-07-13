# PRP — P1.M4.T1.S1: `pool_copy_master(target_dir)` — btrfs reflink copy + Singleton lock cleanup

---

## Goal

**Feature Goal**: Implement the **master-profile copy primitive** for the agent-browser-pool —
the single function that turns the read-only `master-profile` template into one ephemeral
`active/<N>` Chrome profile per acquire. It is the literal realization of PRD §2.7 ("Copy /
master hygiene") and §2.19's reflink-detection note: a near-instant CoW copy on btrfs via
`cp -a --reflink=always`, a **loud refusal** on a non-btrfs filesystem (a 4.8 GB real copy per
acquire is a footgun) unless `AGENT_CHROME_ALLOW_SLOW_COPY=1`, and the removal of the three
stale Chrome single-instance locks the template carries. One function, appended at EOF of
`lib/pool.sh`. It opens the "Lane lifecycle" group of M4.

1. **`pool_copy_master(target_dir)`** — the literal realization of the item's CONTRACT (steps
   a→e):
   ```
   a. cp -a --reflink=always "$POOL_MASTER_DIR" "$target_dir"     (instant CoW on btrfs)
   b. cp fails AND not btrfs AND POOL_ALLOW_SLOW_COPY != 1        → pool_die (loud refusal)
   c. cp fails AND POOL_ALLOW_SLOW_COPY == 1                      → retry with cp -a (slow real copy)
   d. after success: rm -f SingletonLock SingletonCookie SingletonSocket  (stale template locks)
   e. return 0 on success, pool_die on failure
   ```
   The contract's detection mechanism IS the `cp --reflink=always` failure (PRD §2.19):
   on btrfs it succeeds in ~17 ms; on non-btrfs (tmpfs/etc.) it fails rc 1. The function
   composes the LANDED `pool_check_master` (M1.T1.S3) as a pre-check so a missing/empty master
   dies with PRD §2.14's exact bootstrap command instead of a raw cp error.

2. No new globals, no new env vars, no new files, no user docs ("DOCS: none — internal
   function. The btrfs/reflink requirement is already in README.md"). Pure append of ONE
   function under a new `# Lane lifecycle` banner. Reads only `POOL_MASTER_DIR` and
   `POOL_ALLOW_SLOW_COPY` (both frozen by `pool_config_init`, M1.T1.S2).

**Deliverable**: One function (`pool_copy_master`) appended to `lib/pool.sh` under a new
`# Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)` banner, placed directly
after `pool_lane_is_stale`'s closing brace (current EOF, line 1197). Pure addition: no edits
to any existing function, no new globals/env-vars/files. Every branch is **host-verified**
(2026-07-12) via a prototype of the exact function body sourced on top of the real library
under `set -euo pipefail` — see `research/cp-reflink-gotchas-and-copy-master.md` (all 6
scenarios + `bash -n` + `shellcheck` — ALL PASSED).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init`, with a populated master on
  **btrfs** → `pool_copy_master "$target"` returns **0** in well under 1 s (instant CoW),
  `$target` is a **flat** copy of the master (contents directly under `$target`, NOT nested
  under `$POOL_MASTER_DIR`'s basename), and `$target` contains **none** of
  `SingletonLock`/`SingletonCookie`/`SingletonSocket`.
- With the target on **non-btrfs** (tmpfs) and `POOL_ALLOW_SLOW_COPY != 1` → `pool_copy_master`
  **pool_die**s with a message naming the detected FS, and leaves **no partial `$target`**
  behind (cleaned up).
- With the target on non-btrfs and `POOL_ALLOW_SLOW_COPY == 1` → falls back to `cp -a` (slow
  real copy), returns **0**, flat copy, Singleton* removed (no nesting).
- Missing/empty master → `pool_check_master` **pool_die**s with the exact
  `cp -a --reflink=always <profile> "$POOL_MASTER_DIR"` bootstrap command.
- Empty or non-absolute `target_dir` → `pool_die` (PRD §2.2: no bare `~` / relative paths to
  `cp`/`rm`; also guards the internal `rm -rf`).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M3) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls this directly. Its sole
consumer is another function inside `lib/pool.sh`:

- **P1.M5.T1.S2** (acquire **post-lock boot**) — the **primary** consumer. After the flock
  critical section releases the lane claim (key_findings FINDING 2: keep flock short), the
  post-lock boot does `copy → find_free_port → launch Chrome → connect → update lease`.
  `pool_copy_master "$POOL_EPHEMERAL_ROOT/$N"` is the **first** step of that boot — it
  materializes the ephemeral profile that Chrome's `--user-data-dir=<target>` then launches
  against. The ~instant reflink copy is cheap enough to live OUTSIDE the flock so concurrent
  acquires boot in parallel (PRD §2.19).

**Use Case**: Every `agent-browser` invocation that does NOT already hold a valid lane
(`pool_lease_find_mine` returned 1) enters the acquire flow: flock → reap-stale → choose-N →
provisional claim (release flock) → **post-lock boot**. This function is the "copy" half of
that boot. Without it there is no ephemeral profile; Chrome has nothing to launch.

**Pain Points Addressed**:
- **btrfs CoW is the whole economic premise of the pool.** PRD §1.2/§2.7: ephemeral profiles
  are cheap ONLY because `cp --reflink=always` shares blocks with the master (no 4.8 GB
  duplication per lane). If this function silently fell back to a real copy, a 10-lane pool
  would burn ~48 GB and multi-second acquires. The loud-refusal branch (b) is the safety
  interlock.
- **Stale template locks would break the launched Chrome.** The master was created by copying
  a once-launched Chrome profile, so it carries `SingletonLock`/`SingletonCookie`/
  `SingletonSocket`. If these survive into `active/<N>`, Chrome thinks another instance owns
  the dir → it refuses to start or attaches to a stale owner. Per-acquire removal (d) is
  mandatory (PRD §2.7).
- **One place that owns the copy + the three footguns.** The copy has four non-obvious cp
  gotchas (stderr flood on non-btrfs; empty partial dir left on failure; nesting hazard on
  retry; flat-vs-nested semantics — all host-verified, research §1). Centralizing them in one
  function means every consumer (only M5.T1.S2 today) gets them right.

## Why

- **It is the materialization step of the ephemeral-profile model.** PRD §1.2 ("The model:
  ephemeral profiles from a master copy") + §2.7 ("Copy / master hygiene") define the pool's
  core mechanic: a read-only master, copied per-lane via reflink, cleaned of stale locks, then
  launched. This function IS that mechanic. Everything else in M5 (launch, connect, lease)
  operates on the dir this function produces.
- **The loud refusal (b) is a deliberately painful interlock, not a limitation.** key_findings
  FINDING (the cp gotchas) + PRD §2.14 make a silent 4.8 GB real copy "the footgun": it would
  appear to work while destroying the pool's economics and starving the disk. Failing loudly
  unless the operator explicitly sets `AGENT_CHROME_ALLOW_SLOW_COPY=1` is the contract's
  explicit choice — and the `cp --reflink=always` failure is the authoritative, host-verified
  signal that triggers it.
- **It composes the LANDED primitives, it does not re-implement them.** `pool_check_master`
  (M1.T1.S3) already owns "is the master present + non-empty, else die with the bootstrap
  command". Reusing it keeps exactly one master-existence check in the codebase and gives the
  best error message. The btrfs detection itself is delegated to cp's exit code (per the
  contract), with a one-off `findmnt -T` only to *report* the FS in the die message.

## What

User-visible behavior: none directly (internal library primitive). Observable contract:

| `pool_copy_master "$target_dir"` | target FS | `POOL_ALLOW_SLOW_COPY` | Result |
|---|---|---|---|
| populated master, target absent | btrfs | any | **rc 0**, instant CoW copy (~ms), flat layout, Singleton* removed |
| populated master, target absent | btrfs | any | **rc 0** even if `--reflink` were to fail for a real reason AND slow-copy=1 → flat slow copy (defensive; on btrfs reflink does not fail) |
| populated master, target absent | non-btrfs (tmpfs…) | != 1 (unset/0/…) | **pool_die** — loud refusal naming the detected FS; **no partial target left** |
| populated master, target absent | non-btrfs | == 1 | **rc 0**, slow `cp -a` fallback, flat layout, Singleton* removed |
| master **missing or empty** | any | any | **pool_die** via `pool_check_master` with the exact `cp -a --reflink=always <profile> "$POOL_MASTER_DIR"` bootstrap command (PRD §2.14) |
| `target_dir` empty | — | — | **pool_die**: `empty target_dir` |
| `target_dir` non-absolute (`relative/1`) | — | — | **pool_die**: `target_dir must be absolute` (PRD §2.2 + guards the internal `rm -rf`) |

**Layout invariant (CRITICAL)**: a successful copy is ALWAYS **flat** — the master's contents
appear directly under `$target_dir` (e.g. `$target_dir/Preferences`, `$target_dir/Default/…`),
NEVER nested as `$target_dir/<master-basename>/…`. This is what Chrome's
`--user-data-dir=$target_dir` expects. The flat-vs-nested distinction is governed by whether
`$target_dir` exists at cp time (research §1.3/§1.4); the function guarantees absence before
every cp by `rm -rf`-ing any partial on the failure path and by `mkdir -p`-ing only the PARENT.

**Hard invariants** (every row):
- **Never silently produces a partial/nested/wrong target.** Every failure path either
  `pool_die`s (exiting the process) or cleans up before retrying.
- **Never floods stderr.** The reflink attempt runs with `2>/dev/null` (on non-btrfs cp emits
  one "Operation not supported" line PER FILE — thousands for a 4.8 GB master; research §1.1).
- **Never passes a bare `~` or relative path to `cp`/`rm`/`mkdir`** (PRD §2.2). `target_dir`
  is validated absolute; `POOL_MASTER_DIR` is already absolute (frozen by `pool_config_init`).
- **Reads only `POOL_MASTER_DIR` + `POOL_ALLOW_SLOW_COPY`** (frozen by `pool_config_init`).
  No new globals, no new env vars, no on-disk state beyond the target dir it creates.

### Success Criteria

- [ ] `pool_copy_master` defined in `lib/pool.sh` under a
      `# Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)` banner, directly after
      `pool_lane_is_stale`'s closing brace (current EOF, line 1197). Callable after
      `source lib/pool.sh` + `pool_config_init`.
- [ ] **btrfs happy path**: populated master → rc 0 in < 1 s; `$target` is a flat copy;
      `$target/SingletonLock`, `/SingletonCookie`, `/SingletonSocket` all absent (incl. when
      `SingletonSocket` is an AF_UNIX socket).
- [ ] **non-btrfs, no escape** (target on tmpfs, `POOL_ALLOW_SLOW_COPY != 1`) → `pool_die`
      naming the detected FS; **no partial `$target` left behind**.
- [ ] **non-btrfs, slow-copy escape** (`POOL_ALLOW_SLOW_COPY == 1`) → rc 0 via `cp -a`
      fallback; **flat** copy (no nesting); Singleton* removed.
- [ ] **missing/empty master** → `pool_die` via `pool_check_master` whose message contains the
      literal `cp -a --reflink=always` bootstrap command.
- [ ] **empty `target_dir`** → `pool_die: empty target_dir`.
- [ ] **non-absolute `target_dir`** → `pool_die: target_dir must be absolute: …`.
- [ ] Composes `pool_check_master` (LANDED) as the pre-check; composes `pool_die` for errors.
      Does NOT call `pool_check_btrfs` (the cp exit code is the detection; research §3.2).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.\*) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **four cp gotchas**
(stderr flood / empty-partial-dir / nesting-hazard / flat-copy semantics — all host-verified,
research §1); the **contract a→e → verified-implementation mapping** (research §7); the exact
**host-verified function body** (paste-ready); the **composition decision** (compose
`pool_check_master`, do NOT compose `pool_check_btrfs`, and WHY — research §3); the
**`findmnt -T` gotcha** reused for the die message (research §4); the **Singleton* file
types** (socket vs file, all removed by `rm -f` — research §5); the **set -e / subshell
hazard for testing `pool_die`** (research §2 — every die-expecting validation MUST wrap in a
subshell or it kills the test script); the exact placement (after `pool_lane_is_stale` at EOF,
line 1197); and copy-pasteable, host-verified validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.7 (Copy / master hygiene — the cp --reflink=always command, the loud-refusal rule,
        the three Singleton files to rm), §2.19 (Implementation notes — "Reflink detection:
        cp --reflink=always; on failure (non-btrfs) refuse unless AGENT_CHROME_ALLOW_SLOW_COPY=1
        (a 4.8 GB real copy per acquire is a footgun)"; also "Keep the flock critical section
        short" → this copy runs OUTSIDE the flock in M5.T1.S2; "No bare ~" → §2.2), §2.2 (every
        path absolute — target_dir validated absolute here), §2.14 (master missing → die with
        the exact cp bootstrap command — delivered by the composed pool_check_master), §1.2
        (the ephemeral-from-master model this function realizes), §2.3 (ephemeral dir =
        $POOL_EPHEMERAL_ROOT/<N> — the target layout), §2.8 (the lease that points at the dir
        this function creates, consumed by M5.T1.S2).
  pattern: §2.7 is the literal step list (a–e); §2.19 is the reflink-detection rationale.
  gotcha: §2.19's "reflink on failure refuse" is implemented as the cp-exit-code branch, NOT a
        pre-emptive pool_check_btrfs call (research §3.2).

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §3 (btrfs/CoW copy — the cp --reflink=always command at §3.1; the Singleton cleanup at
        §3.3), §4 (cp / rm / mkdir / findmnt are the verified-present coreutils+util-linux
        tools), §5 (POOL_MASTER_DIR / POOL_EPHEMERAL_ROOT / AGENT_CHROME_ALLOW_SLOW_COPY env
        vars), §6 (lease schema — ephemeral_dir field = the target this creates).
  pattern: §3.1 is the copy command; §3.3 is the rm -f line.
  gotcha: §3.2's btrfs-detection example OMITS the `-T` flag and is BROKEN on this host
        (exits 1 even on btrfs) — see research §4 and the LANDED pool_check_btrfs docstring.
        Do NOT copy §3.2 verbatim; the cp-exit-code approach here sidesteps it.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (keep the flock section short → the copy runs in post-lock boot M5.T1.S2,
        outside the flock; the ~instant reflink is fine there), FINDING 3 (no bare ~ →
        target_dir validated absolute; POOL_MASTER_DIR already absolute), the "Function Naming
        Convention" table (pool_lane_* = lane lifecycle incl. "copy" — but the CONTRACT
        overrides it to pool_copy_master; research §6).
  pattern: FINDING 3 → the absolute-path guard on target_dir.
  gotcha: the naming table is a RECOMMENDATION; the contract says pool_copy_master — honor the
        contract (research §6).

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — POOL_EPHEMERAL_ROOT/active/<N> is the target this creates;
        it is NOT created by pool_state_init, so this function mkdir -p's its parent).
  pattern: §7 → target_dir = $POOL_EPHEMERAL_ROOT/<N>.
  gotcha: POOL_EPHEMERAL_ROOT may not exist on a first run → mkdir -p the parent (research §7).

# This task's own research (host-verified prototype — all 6 scenarios PASSED)
- file: plan/001_0f759fe2777c/P1M4T1S1/research/cp-reflink-gotchas-and-copy-master.md
  why: the deep brief on (a) the four cp gotchas — stderr flood / empty partial dir / nesting
        hazard / flat-vs-nested — all host-verified (§1); (b) the set -e + subshell hazard for
        TESTING pool_die — every die-expecting validation MUST wrap in ( … ) or it kills the
        test script (§2); (c) the composition decision — compose pool_check_master, do NOT
        compose pool_check_btrfs, and why (§3); (d) the findmnt -T gotcha reused for the die
        message (§4); (e) Singleton* file types incl. the AF_UNIX socket, all removed by rm -f
        (§5); (f) naming/banner/placement (§6); (g) the contract a→e → verified-implementation
        mapping + the four defensive additions beyond the literal contract (§7); (h) the full
        6-scenario results table (§0).
  pattern: §1 (the gotchas), §7 (the mapping), §2 (the test-subshell idiom).
  gotcha: §1.3 (nesting hazard on retry) and §1.1 (stderr flood) are the two non-obvious ones
        that WILL cause bugs if missed.

# The LANDED function this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md   # pool_check_master + pool_check_btrfs (M1.T1.S3 — LANDED)
  why: pool_check_master() is composed as the pre-check. CONTRACT: returns 0 if
        $POOL_MASTER_DIR exists (-d) AND is non-empty (ls -A); otherwise pool_die with the
        exact PRD §2.14 bootstrap command `cp -a --reflink=always <profile>
        "$POOL_MASTER_DIR"`. It is idempotent + cheap (no du/stat of 4.8 GB). This task's
        `pool_check_master` call relies on EXACTLY this — rc 0 → proceed to cp; pool_die →
        process exits with the bootstrap hint.
        pool_check_btrfs() is deliberately NOT composed (research §3.2) — but its docstring is
        the authoritative source for the `findmnt -nno FSTYPE -T` technique (the -T is
        MANDATORY) reused in this task's die message, and for the POOL_ALLOW_SLOW_COPY
        semantics ("exactly '1' → on").
  pattern: pre-check then act; the findmnt -T -nno FSTYPE form.
  gotcha: pool_check_btrfs checks POOL_EPHEMERAL_ROOT (the root) and pool_die's — calling it
        here would pre-empt the contract's cp-failure detection. Use a raw findmnt for the
        message only.

# The LANDED config + error helpers this task depends on
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md   # pool_die / _pool_log (M1.T1.S1 — LANDED @~40/@~24)
  why: pool_die(MSG…) prints MSG to stderr + exit 1 — every failure path here. _pool_log is
        NOT used (happy path silent; pool_die is the failure signal), matching pool_state_init.
  pattern: `pool_die "pool_copy_master: …"`.
  gotcha: pool_die does `exit 1` — in the CURRENT shell. Testing it requires a subshell (§2).

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init (M1.T1.S2 — LANDED @~95)
  why: freezes POOL_MASTER_DIR (absolute, via realpath -m) and POOL_ALLOW_SLOW_COPY
        (normalized from AGENT_CHROME_ALLOW_SLOW_COPY by _pool_config_bool: exactly "1" → "1",
        everything else → "0"). This task reads both; the `[[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]`
        branch relies on the bool normalization.
  pattern: globals are MUTABLE + re-runnable; no readonly.
  gotcha: POOL_ALLOW_SLOW_COPY is the GLOBAL (normalized), not the env var; the contract's
        "POOL_ALLOW_SLOW_COPY" name matches the global. AGENT_CHROME_ALLOW_SLOW_COPY is the env.

# The IMMEDIATE PREDECESSOR at EOF (placement reference)
- file: plan/001_0f759fe2777c/P1M3T2S3/PRP.md   # pool_lane_is_stale (M3.T2.S3 — LANDED @~1108)
  why: S3 LANDED `pool_lane_is_stale` is the LAST function in lib/pool.sh (file is now 1197
        lines). This task APPENDS the new banner + pool_copy_master directly after its closing
        brace. S3 also established the banner style + append-at-EOF placement this task mirrors
        for the new "Lane lifecycle" section.
  pattern: the banner style (`# ====…` + `# <group> — <subtask>` + `# ====…`).
  gotcha: do NOT touch pool_lane_is_stale or any M3 function — this task only APPENDS.

# External authoritative docs (for the HOW)
- url: https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
  why: cp --reflink=always semantics ("copy using copy-on-write reflinks; fail if the FS does
        not support them"); -a (archive: recursive + preserve); the source-into-existing-dir
        vs source-into-absent-dst layout difference that drives the flat-vs-nested invariant.
  critical: `--reflink=always` is the ONLY mode that FAILS on non-CoW FS. (`--reflink=auto`
        silently falls back to a real copy — a footgun; never use auto here.) On a non-CoW FS
        cp fails rc 1, one "Operation not supported" stderr line per file, AND creates the
        target dir first (host-verified — research §1.1/§1.2).
  section: "cp invocation" → --reflink, --archive.

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (set -e) — pool_die's `exit 1` in a function kills the whole script unless the
        call is in a pipeline/subshell. Validation commands for the die paths MUST wrap in
        `( … )` (research §2). The `if ! cp …` and `if ! cp -a …` guards are errexit-exempt.
  section: `-e` (errexit).

- url: https://man7.org/linux/man-pages/man1/findmnt.1.html
  why: the `-T/--target` flag (MANDATORY) finds the mount for a PATH; without -T the
        positional arg is matched against SOURCE (a device) and exits 1 even on btrfs on this
        host. `-n` (no header), `-o FSTYPE` (just the type). Reused for the die-message FS
        report.
  critical: always `findmnt -nno FSTYPE -T "$path"`; the bare form is broken (research §4).
  section: OPTIONS (-T, -n, -o).
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.\*, M3.T2.S1–S3** have landed, `lib/pool.sh`
is **1197 lines** with `pool_lane_is_stale` (M3.T2.S3) as the final function (verified:
`grep -nE '^pool_lane_is_stale\(\)' lib/pool.sh`):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # 1197 lines: set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)  ← @202/230/266
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.*)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)
│                                         #   + pool_lanes_list/pool_lease_find_mine/_any (M3.T2.S1)
│                                         #   + pool_find_free_lane (M3.T2.S2)
│                                         #   + pool_lane_is_stale (M3.T2.S3)  ← @~1108–1197 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M3T2S3/PRP.md
    └── P1M4T1S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/cp-reflink-gotchas-and-copy-master.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND one function under a new banner after the current EOF
                  #   (line 1197, after pool_lane_is_stale's closing brace):
                  #   # Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)
                  #   pool_copy_master(target_dir) — reflink CoW copy of the master into an
                  #       ephemeral dir + Singleton lock cleanup (loud-refuse on non-btrfs
                  #       unless POOL_ALLOW_SLOW_COPY=1).
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask opens
the **Lane lifecycle** group (M4) with the **master→ephemeral copy primitive** — the
materialization step of PRD §1.2/§2.7. It composes the LANDED `pool_check_master` (M1.T1.S3);
it is consumed by the acquire post-lock boot (M5.T1.S2).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (reflink stderr FLOODS on non-btrfs — one line per file): `cp -a --reflink=always`
#   on a non-CoW FS emits "cp: failed to clone '<f>': Operation not supported" for EVERY source
#   file and exits rc 1. A 4.8 GB Chrome master has THOUSANDS of files → thousands of stderr
#   lines per failed acquire. The reflink attempt MUST run with `2>/dev/null`. HOST-VERIFIED
#   (research §1.1). Do NOT let cp's stderr reach the user on the reflink attempt.

# CRITICAL (reflink failure leaves an EMPTY PARTIAL target dir): before failing on the first
#   content file, `cp` CREATES the target directory (empty, total 0). HOST-VERIFIED (research
#   §1.2). A phantom dir would (a) confuse the caller's `[[ -d ]]` free-lane probe and (b)
#   trigger the nesting hazard (next). MUST `rm -rf -- "$target_dir"` on reflink failure.

# CRITICAL (NESTING HAZARD on retry): `cp -a src dst` when dst EXISTS as a dir copies src
#   INTO dst → `dst/<basename src>/…` (WRONG). When dst is ABSENT, dst becomes a flat copy of
#   src → `dst/<src contents>` (CORRECT). HOST-VERIFIED (research §1.3/§1.4). Because the
#   failed reflink leaves dst existing (above), a naive slow-retry `cp -a src dst` would NEST
#   the profile under `active/1/master-profile/`. The `rm -rf` before the retry is MANDATORY.

# CRITICAL (the FLAT layout is the success invariant): a correct copy has the master's
#   contents DIRECTLY under $target_dir ($target/Preferences, $target/Default/…), NEVER
#   $target/<master-basename>/. Chrome's --user-data-dir=$target expects exactly this.
#   Guaranteed by: mkdir -p the PARENT only (never the target), and rm -rf the target before
#   any retry. HOST-VERIFIED (scenario A + C both flat).

# CRITICAL (SingletonSocket is an AF_UNIX socket, not a regular file): Chrome's SingletonSocket
#   is a unix domain socket (ls shows srwxr-xr-x). `rm -f` removes a socket just like a file —
#   do NOT special-case it. All three (SingletonLock/Cookie/Socket) removed with ONE rm -f.
#   HOST-VERIFIED (research §5). `-f` is correct: some may be absent in a clean master.

# CRITICAL (testing pool_die REQUIRES a subshell): pool_die does `exit 1` in the CURRENT shell.
#   A validation script that calls `pool_copy_master <non-btrfs-target>` directly is KILLED at
#   the pool_die before it can print anything. Every die-expecting validation MUST wrap the
#   call in `( … )` and capture `$?`. HOST-VERIFIED (research §2 — my first harness died at
#   scenario B). Happy-path (rc 0) validations do NOT need the subshell.

# CRITICAL (compose pool_check_master, NOT pool_check_btrfs): the contract's btrfs detection
#   IS the `cp --reflink=always` exit code (steps a-c). Calling pool_check_btrfs would
#   PRE-EMPT that (it pool_die's on non-btrfs before cp runs) and checks POOL_EPHEMERAL_ROOT
#   not the target. pool_check_btrfs is the acquire-INIT gate (M5.T1.S1), not this function's.
#   A raw `findmnt -nno FSTYPE -T "$parent"` is used ONLY to report the FS in the die message.
#   HOST-VERIFIED (research §3).

# CRITICAL (findmnt -T is MANDATORY): `findmnt -nno FSTYPE "$dir"` (NO -T) matches the
#   positional arg against SOURCE (a device) and exits 1 ON THIS HOST EVEN ON BTRFS.
#   external_deps.md §3.2's example omits -T and is BROKEN. Always use -T. HOST-VERIFIED
#   (research §4 + LANDED pool_check_btrfs docstring).

# CRITICAL (set -e + the cp guards): the reflink attempt and the slow retry are each wrapped
#   in `if ! cp …; then …; fi` — errexit-EXEMPT (a bare `cp` that fails would ABORT). The
#   mkdir and the post-copy rm -f use `|| pool_die` so a real FS error is a clean fatal, not a
#   set -e abort. `rm -rf -- "$target_dir"` on the failure path is intentionally NOT guarded
#   by `|| true` — if it fails we WANT to die (something is very wrong). [Note: under set -e,
#   `rm -rf` failing would abort; that is acceptable/desired here.]

# GOTCHA (naming): pool_copy_master — the CONTRACT body literally says "Implement
#   `pool_copy_master(target_dir)`". key_findings' naming table SUGGESTS pool_lane_* for
#   "copy"; the contract OVERRIDES it. The consumer (M5.T1.S2) references pool_copy_master.
#   Do NOT rename to pool_lane_copy.

# GOTCHA (placement): APPEND at EOF (after pool_lane_is_stale @1197). Do NOT touch any
#   existing function (pool_check_master, pool_check_btrfs, pool_state_init, etc.). This task
#   only CONSUMES pool_check_master + pool_die.

# GOTCHA (scope): this task is the COPY primitive only. Do NOT: launch Chrome (M4.T2.S2);
#   find a free port (M4.T2.S1); connect the daemon (M4.T3); acquire/release/reap (M5);
#   the flock critical section (M5.T1.S1); or update the lease's ephemeral_dir (M5.T1.S2 —
#   the caller writes $target into the lease AFTER this returns 0).

# GOTCHA (POOL_EPHEMERAL_ROOT may not exist yet): pool_state_init creates lanes/ + the lock,
#   NOT the ephemeral root. On a first run $POOL_EPHEMERAL_ROOT is absent, so cp would fail
#   ("No such file or directory"). `mkdir -p -- "$(dirname "$target_dir")"` makes the function
#   self-sufficient on first run (mirrors pool_state_init's "just works" creation).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no new globals**, **no new env vars**, and **no on-disk layout** beyond
the target dir it creates (the layout `$POOL_EPHEMERAL_ROOT/<N>/` is defined by PRD §2.3; the
target is supplied by the caller M5.T1.S2). It defines ONE function whose data contract is
read-only over `POOL_MASTER_DIR`/`POOL_ALLOW_SLOW_COPY` (frozen by `pool_config_init`) and
write-only over the caller-supplied `target_dir`. It touches no lease JSON.

| composed fn | source | contract relied upon | role here |
|---|---|---|---|
| `pool_check_master` | M1.T1.S3 (LANDED @266) | rc 0 if `$POOL_MASTER_DIR` exists + non-empty; else `pool_die` with the exact `cp -a --reflink=always <profile> "$POOL_MASTER_DIR"` bootstrap command | pre-check: best-effort error before cp |
| `pool_die(MSG…)` | M1.T1.S1 (LANDED @~40) | prints MSG to stderr + `exit 1` | every failure path |

Globals read (both frozen absolute/normalized by `pool_config_init`, M1.T1.S2):

| global | source env var | example | role |
|---|---|---|---|
| `POOL_MASTER_DIR` | `AGENT_CHROME_MASTER` (default `$HOME/.agent-chrome-profiles/master-profile`) | `/home/dustin/.agent-chrome-profiles/master-profile` | cp SOURCE (absolute via realpath -m) |
| `POOL_ALLOW_SLOW_COPY` | `AGENT_CHROME_ALLOW_SLOW_COPY` (default unset → `0`) | `0` or `1` | the slow-copy escape hatch (exactly `"1"` → on) |

**Naming** (CONTRACT-mandated, exact): `pool_copy_master`. NOTE `key_findings.md`'s naming
*recommendation* puts "copy" under `pool_lane_*`; the CONTRACT body + the consumer (M5.T1.S2)
say `pool_copy_master` — honor the contract verbatim (same principle as S3's
`pool_lane_is_stale` vs title `is_lane_stale`). No `_` prefix — it is a public entry point
(mirrors `pool_state_init`, `pool_check_master`). Internal-only in practice.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_die pool_check_master pool_config_init pool_lane_is_stale'
  - EXPECT: all four reported as functions. (pool_die is M1.T1.S1 LANDED @~40; pool_check_master
        is M1.T1.S3 LANDED @266; pool_config_init is M1.T1.S2 LANDED @~95; pool_lane_is_stale
        is M3.T2.S3 LANDED — confirms the append point.) If pool_check_master is MISSING, STOP
        — this task hard-depends on it.
  - RUN (sanity-check the composed contract + the two globals):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_CHROME_MASTER="$HOME/.abp_master_probe" AGENT_CHROME_ALLOW_SLOW_COPY= pool_config_init; \
                 ( pool_check_master ) 2>&1 | grep -q "cp -a --reflink=always" && echo "OK pool_check_master die has bootstrap cmd" || echo "FAIL"; \
                 [[ "${POOL_ALLOW_SLOW_COPY:-x}" == "0" ]] && echo "OK POOL_ALLOW_SLOW_COPY normalized to 0" || echo "FAIL"; \
                 [[ "${POOL_MASTER_DIR}" == /* ]] && echo "OK POOL_MASTER_DIR absolute" || echo "FAIL"; \
                 rm -rf "$HOME/.abp_master_probe"'
        # EXPECT: OK pool_check_master die has bootstrap cmd ; OK POOL_ALLOW_SLOW_COPY=0 ; OK absolute.
  - RUN (locate the append point — current EOF):
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^pool_lane_is_stale\(\)' lib/pool.sh
  - EXPECT: the last function is pool_lane_is_stale (closing brace at ~line 1197). APPEND the
        new banner + function AFTER that brace. Do NOT touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_copy_master() to lib/pool.sh (the only function)
  - PLACEMENT: after a new banner, directly below pool_lane_is_stale()'s closing brace
        (current EOF, line 1197).
  - IMPLEMENT (verbatim-ready — paste this block):
        # =============================================================================
        # Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)
        # =============================================================================
        # Materialize one ephemeral Chrome profile from the read-only master template.
        # Implements PRD §2.7 (Copy / master hygiene) + §2.19 (reflink detection: cp
        # --reflink=always; on failure refuse unless AGENT_CHROME_ALLOW_SLOW_COPY=1) and
        # removes the three stale Chrome single-instance locks the template carries. Consumed
        # by the acquire POST-LOCK boot (M5.T1.S2: copy → port → launch → connect → update
        # lease), OUTSIDE the flock critical section (key_findings FINDING 2 — the ~instant
        # reflink copy is cheap enough to run concurrently with other acquires' boots).

        # pool_copy_master TARGET_DIR
        #
        # Copy $POOL_MASTER_DIR (the master template) into TARGET_DIR (an ephemeral lane,
        # normally $POOL_EPHEMERAL_ROOT/<N>) as a flat profile, then remove the stale
        # Singleton* locks. Returns 0 on success; pool_die on any failure.
        #
        # LOGIC (CONTRACT a→e):
        #   a. cp -a --reflink=always "$POOL_MASTER_DIR" "$TARGET_DIR"  (instant CoW on btrfs).
        #   b. cp fails (non-btrfs / unsupported) AND POOL_ALLOW_SLOW_COPY != 1 → pool_die.
        #   c. cp fails AND POOL_ALLOW_SLOW_COPY == 1 → retry with cp -a (slow real copy).
        #   d. after success: rm -f SingletonLock SingletonCookie SingletonSocket.
        #   e. return 0 / pool_die on failure.
        #
        # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → TARGET_DIR is a flat,
        #   lock-cleaned, ready-to-launch profile; any failure exits the process via pool_die.
        #
        # GOTCHA — reflink stderr FLOODS on non-btrfs: cp emits one "Operation not supported"
        #   line PER source file (thousands for a 4.8 GB master) and exits rc 1. The reflink
        #   attempt runs with 2>/dev/null. HOST-VERIFIED (research §1.1).
        # GOTCHA — reflink failure leaves an EMPTY PARTIAL TARGET_DIR: cp creates TARGET_DIR
        #   (empty) before failing. We `rm -rf -- "$target_dir"` on the failure path so the
        #   caller's `[[ -d ]]` free-lane probe is not fooled and the slow retry does not nest.
        #   HOST-VERIFIED (research §1.2).
        # GOTCHA — NESTING HAZARD: `cp -a src dst` when dst EXISTS copies src INTO dst
        #   (dst/<basename src>/…); when dst is ABSENT, dst becomes a flat copy of src. Because
        #   the failed reflink leaves dst existing, the `rm -rf` before the slow retry is
        #   MANDATORY to keep the copy FLAT. HOST-VERIFIED (research §1.3/§1.4).
        # GOTCHA — SingletonSocket is an AF_UNIX socket: rm -f removes it like a file; no
        #   special-case. `-f` tolerates a clean master where some are absent. (research §5).
        # GOTCHA — compose pool_check_master, NOT pool_check_btrfs: the cp exit code IS the
        #   btrfs detection (contract steps a-c). pool_check_btrfs would pre-empt it and checks
        #   POOL_EPHEMERAL_ROOT not the target; it is the acquire-INIT gate (M5.T1.S1). A raw
        #   findmnt -T is used ONLY to report the FS in the die message. (research §3).
        # GOTCHA — findmnt -T is MANDATORY: a bare `findmnt -nno FSTYPE "$dir"` (no -T) exits 1
        #   ON THIS HOST EVEN ON BTRFS. external_deps.md §3.2 omits -T and is BROKEN. (§4).
        # GOTCHA — POOL_EPHEMERAL_ROOT may not exist on a first run (pool_state_init does NOT
        #   create it); mkdir -p the PARENT of TARGET_DIR so cp can create the target. NEVER
        #   mkdir the target itself (that would flip cp into nesting mode).
        # GOTCHA — TARGET_DIR validated absolute (PRD §2.2: no bare ~ / relative paths to cp or
        #   rm) and non-empty (also guards the internal rm -rf).
        # Reads ONLY POOL_MASTER_DIR + POOL_ALLOW_SLOW_COPY (frozen by pool_config_init).
        # No new globals/env-vars/files.
        # PRECONDITION: pool_config_init (for POOL_MASTER_DIR + POOL_ALLOW_SLOW_COPY).
        pool_copy_master() {
            local target_dir="${1:-}"
            local parent fstype

            # Validate target_dir: non-empty + ABSOLUTE (PRD §2.2; also guards the rm -rf).
            # `[[ ]] || pool_die` is errexit-exempt.
            [[ -n "$target_dir" ]] \
                || pool_die "pool_copy_master: empty target_dir"
            [[ "$target_dir" == /* ]] \
                || pool_die "pool_copy_master: target_dir must be absolute: $target_dir"

            # Pre-check the master (PRD §2.14: die with the exact bootstrap cp command if
            # missing/empty). pool_check_master is M1.T1.S3 (LANDED @266): rc 0 or pool_die.
            pool_check_master

            # Ensure the PARENT of target_dir exists (cp needs it; the ephemeral root may not
            # exist on a first run). mkdir -p is idempotent. Do NOT mkdir the target itself
            # (cp creates it; mkdir-ing it would trigger the nesting hazard). `|| pool_die` so a
            # real FS error is a clean fatal (not a set -e abort).
            parent="$(dirname -- "$target_dir")"
            mkdir -p -- "$parent" \
                || pool_die "pool_copy_master: cannot create parent dir: $parent"

            # (a) reflink CoW copy — instant on btrfs. 2>/dev/null suppresses the per-file
            # "Operation not supported" flood on non-btrfs (research §1.1). `if !` is
            # errexit-exempt — a bare cp that fails would ABORT under set -e.
            if ! cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null; then
                # reflink failed (non-btrfs / unsupported). cp left an empty PARTIAL target_dir
                # (research §1.2). rm it so the retry does not NEST (research §1.3). PLAIN rm
                # under `if !`: if rm itself fails we fall through to die below (acceptable —
                # something is deeply wrong with the FS).
                rm -rf -- "$target_dir" 2>/dev/null || true

                # (c) slow-copy escape hatch (POOL_ALLOW_SLOW_COPY normalized to "1"/"0" by
                # pool_config_init's _pool_config_bool — exactly "1" → on).
                if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
                    if ! cp -a -- "$POOL_MASTER_DIR" "$target_dir"; then
                        pool_die "pool_copy_master: slow copy (cp -a) also failed:" \
                                 "$POOL_MASTER_DIR -> $target_dir"
                    fi
                else
                    # (b) not btrfs + no escape → die loudly. Report the detected FS for clarity
                    # (findmnt -T MANDATORY; || true neutralizes a missing-path exit 1).
                    fstype="$(findmnt -nno FSTYPE -T "$parent" 2>/dev/null || true)"
                    pool_die "pool_copy_master: cp --reflink=always failed" \
                             "(target FS '${fstype:-<unknown>}' is not btrfs / reflink unsupported)." \
                             "A real 4.8 GB copy per acquire would be catastrophic." \
                             "Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point" \
                             "AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount (the path may not exist)."
                fi
            fi

            # (d) remove stale Chrome single-instance locks from the template (would confuse a
            # launched Chrome). SingletonSocket may be an AF_UNIX socket — rm -f handles all
            # three. -f tolerates a clean master where some are absent. `|| pool_die` for safety.
            rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie" "$target_dir/SingletonSocket" \
                || pool_die "pool_copy_master: cannot remove Singleton locks in: $target_dir"

            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155); `[[ ]] || pool_die`
        (errexit-exempt input guards); `if ! cp …; then …; fi` (errexit-exempt cp guards);
        `--` before every path arg to cp/rm/mkdir (defensive, matches pool_state_init); the
        composed `pool_check_master` + `pool_die`.
  - NAMING: pool_copy_master (CONTRACT-mandated; do NOT rename).
  - PLACEMENT: the only function in the new "(P1.M4.T1.S1)" banner.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_copy_master' >/dev/null && echo OK
        # EXPECT: OK.
  # NOTE: the die-expecting scenarios (B, E, empty, relative) MUST run inside a SUBSHELL —
  # pool_die does `exit 1` in the current shell and would kill the whole command line.
  #
  # --- shared test master (on btrfs $HOME) with content + the 3 Singleton* files ---------
  - RUN (build the master ONCE; SingletonSocket as an AF_UNIX socket):
        M="$HOME/.abp_m4_master"; rm -rf "$M" "$HOME/.abp_m4_root" /tmp/abp_m4_root
        mkdir -p "$M/Default"; echo prefs > "$M/Preferences"; echo cookies > "$M/Default/Cookies"
        : > "$M/SingletonLock"; : > "$M/SingletonCookie"
        python3 -c "import socket,os;socket.socket(socket.AF_UNIX).bind(os.environ['M']+'/SingletonSocket')" \
            2>/dev/null || : > "$M/SingletonSocket"
        ls -la "$M"   # eyeball: Preferences, Default/, SingletonLock, SingletonCookie, SingletonSocket(srwx)
  - RUN (SCENARIO A — btrfs happy path → rc 0, instant, flat, Singleton* gone):
        T="$HOME/.abp_m4_root/active/1"
        AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="$HOME/.abp_m4_root/active" \
        AGENT_CHROME_ALLOW_SLOW_COPY= \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init;
                 t0=$(date +%s.%N); pool_copy_master "'"$T"'"; rc=$?; t1=$(date +%s.%N);
                 echo "rc=$rc elapsed=$(awk "BEGIN{print $t1-$t0}")s";
                 [[ "$rc" == 0 ]] && echo OK-happy-rc0 || echo FAIL'
        # Then verify layout + Singleton removal:
        find "$T" -maxdepth 2 | sort
        ( ls "$T/SingletonLock" "$T/SingletonCookie" "$T/SingletonSocket" 2>/dev/null \
            && echo "FAIL Singleton present" ) || echo "OK Singleton* removed"
        # EXPECT: rc=0 elapsed=<well under 1s>; OK-happy-rc0; flat tree (Preferences, Default/Cookies
        #         directly under $T, NO $T/.abp_m4_master/); OK Singleton* removed.
  - RUN (SCENARIO B — non-btrfs (tmpfs) target, slow-copy OFF → pool_die, no partial):
        T="/tmp/abp_m4_root/active/1"
        ( AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/abp_m4_root/active" \
          AGENT_CHROME_ALLOW_SLOW_COPY= \
          bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "'"$T"'"; echo UNREACHED' \
        ) >/tmp/B.out 2>/tmp/B.err; rc=$?
        echo "exit=$rc"; cat /tmp/B.err
        ( ls "$T" 2>/dev/null && echo "FAIL partial left" ) || echo "OK no partial"
        # EXPECT: exit=1; die msg names the FS (tmpfs); OK no partial.
  - RUN (SCENARIO C — non-btrfs target, slow-copy ON → cp -a fallback, flat, Singleton* gone):
        T="/tmp/abp_m4_root/active/2"
        AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/abp_m4_root/active" \
        AGENT_CHROME_ALLOW_SLOW_COPY=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "'"$T"'"; echo "rc=$?"'
        find "$T" -maxdepth 2 | sort
        ( ls "$T/SingletonLock" "$T/SingletonCookie" "$T/SingletonSocket" 2>/dev/null \
            && echo "FAIL Singleton present" ) || echo "OK Singleton* removed"
        # EXPECT: rc=0; FLAT tree (Preferences + Default/Cookies directly under $T, NO nested
        #         .abp_m4_master/ — proves the rm-rf-before-retry killed the nesting hazard);
        #         OK Singleton* removed.
  - RUN (SCENARIO E — missing master → pool_check_master die with bootstrap cp cmd):
        ( AGENT_CHROME_MASTER="$HOME/.abp_m4_master_NOPE" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/abp_m4_root/active" \
          bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "/tmp/abp_m4_root/active/9"; echo UNREACHED' \
        ) >/tmp/E.out 2>/tmp/E.err; rc=$?
        echo "exit=$rc"; cat /tmp/E.err
        grep -q 'cp -a --reflink=always' /tmp/E.err && echo "OK bootstrap cmd in msg" || echo "FAIL"
        # EXPECT: exit=1; die msg from pool_check_master containing the literal
        #         `cp -a --reflink=always` bootstrap command; OK bootstrap cmd in msg.
  - RUN (empty target_dir → pool_die):
        ( AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/x" \
          bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master ""' \
        ) 2>&1 | grep -q "empty target_dir" && echo OK || echo FAIL
        # EXPECT: OK.
  - RUN (non-absolute target_dir → pool_die):
        ( AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/x" \
          bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "relative/1"' \
        ) 2>&1 | grep -q "must be absolute" && echo OK || echo FAIL
        # EXPECT: OK.
  - RUN (NESTING anti-regression — assert a successful copy is FLAT, not nested):
        T="$HOME/.abp_m4_root/active/3"
        AGENT_CHROME_MASTER="$HOME/.abp_m4_master" AGENT_CHROME_EPHEMERAL_ROOT="$HOME/.abp_m4_root/active" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "'"$T"'"'
        ( [[ -f "$T/Preferences" ]] && echo "OK flat (Preferences at root)" ) || echo "FAIL not flat"
        ( [[ -d "$T/.abp_m4_master" ]] && echo "FAIL nested (.abp_m4_master/ exists)" ) || echo "OK not nested"
        # EXPECT: OK flat (Preferences at root) ; OK not nested.
  - RUN (composes the right helpers — body contains pool_check_master + cp --reflink + the
        3 Singleton names; does NOT call pool_check_btrfs):
        body="$(sed -n "/^pool_copy_master() {/,/^}/p" lib/pool.sh)"
        grep -q "pool_check_master"            <<<"$body" && echo "OK composes pool_check_master" || echo "FAIL"
        grep -q -- "--reflink=always"          <<<"$body" && echo "OK reflink attempt"           || echo "FAIL"
        grep -q "rm -rf -- \"\$target_dir\""   <<<"$body" && echo "OK partial-cleanup"           || echo "FAIL"
        grep -q "SingletonLock"                <<<"$body" && echo "OK SingletonLock"             || echo "FAIL"
        grep -q "SingletonSocket"              <<<"$body" && echo "OK SingletonSocket"           || echo "FAIL"
        grep -q "pool_check_btrfs"             <<<"$body" && echo "FAIL calls pool_check_btrfs"  || echo "OK no pool_check_btrfs"
        # EXPECT: OK composes pool_check_master ; OK reflink attempt ; OK partial-cleanup ;
        #   OK SingletonLock ; OK SingletonSocket ; OK no pool_check_btrfs.
  - RUN (regression: all prior + new function still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      pool_check_btrfs pool_check_master \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any \
                      pool_find_free_lane pool_lane_is_stale pool_copy_master >/dev/null && echo OK'
        # EXPECT: OK (all functions, including the new pool_copy_master, callable).
  - RUN (cleanup test artifacts):
        rm -rf "$HOME/.abp_m4_master" "$HOME/.abp_m4_root" /tmp/abp_m4_root /tmp/B.out /tmp/B.err /tmp/E.out /tmp/E.err
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the one function (paste under the new banner after pool_lane_is_stale) -------

pool_copy_master() {
    local target_dir="${1:-}"
    local parent fstype

    [[ -n "$target_dir" ]] || pool_die "pool_copy_master: empty target_dir"
    [[ "$target_dir" == /* ]] || pool_die "pool_copy_master: target_dir must be absolute: $target_dir"

    pool_check_master                                    # LANDED pre-check (bootstrap-cmd error)

    parent="$(dirname -- "$target_dir")"
    mkdir -p -- "$parent" || pool_die "pool_copy_master: cannot create parent dir: $parent"

    if ! cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null; then
        rm -rf -- "$target_dir" 2>/dev/null || true      # kill empty partial (also kills nesting)
        if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
            if ! cp -a -- "$POOL_MASTER_DIR" "$target_dir"; then
                pool_die "pool_copy_master: slow copy (cp -a) also failed: $POOL_MASTER_DIR -> $target_dir"
            fi
        else
            fstype="$(findmnt -nno FSTYPE -T "$parent" 2>/dev/null || true)"
            pool_die "pool_copy_master: cp --reflink=always failed (target FS '${fstype:-<unknown>}' is not btrfs / reflink unsupported). A real 4.8 GB copy per acquire would be catastrophic. Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount (the path may not exist)."
        fi
    fi

    rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie" "$target_dir/SingletonSocket" \
        || pool_die "pool_copy_master: cannot remove Singleton locks in: $target_dir"
    return 0
}

# --- Critical micro-rules baked into the above --------------------------------
#  * REFLINK stderr is suppressed (2>/dev/null): on non-btrfs cp floods one "Operation not
#    supported" per file (thousands for a 4.8 GB master). HOST-VERIFIED.
#  * `rm -rf -- "$target_dir"` on failure is MANDATORY: (1) cp leaves an empty partial target;
#    (2) without it the slow retry `cp -a src dst` would NEST src under the existing dst.
#    HOST-VERIFIED.
#  * FLAT copy invariant: mkdir the PARENT only (never the target); rm the target before retry.
#    `cp -a src dst` (dst absent) → dst becomes a flat copy of src. HOST-VERIFIED.
#  * Compose pool_check_master (yes) NOT pool_check_btrfs (no): the cp exit code IS the btrfs
#    detection; pool_check_btrfs would pre-empt it. A raw `findmnt -T` reports the FS only.
#  * findmnt -T is MANDATORY (the bare form exits 1 even on btrfs on this host).
#  * `--` before every cp/rm/mkdir path arg (defensive; matches pool_state_init).
#  * `if ! cp …; then …; fi` guards make cp failures errexit-safe (a bare failing cp ABORTs).
#  * SingletonSocket may be an AF_UNIX socket — `rm -f` handles it; no special-case.
#  * Reads only POOL_MASTER_DIR + POOL_ALLOW_SLOW_COPY (frozen by pool_config_init). No new state.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_check_master() (M1.T1.S3 @266): rc 0 if $POOL_MASTER_DIR exists + non-empty; else
        pool_die with the exact PRD §2.14 `cp -a --reflink=always <profile> "$POOL_MASTER_DIR"`
        bootstrap command. THIS task calls it as the pre-check; its pool_die is the missing-
        master path. Idempotent + cheap.
  - pool_die(MSG…) (M1.T1.S1 @~40): prints MSG to stderr + exit 1. EVERY failure path here.
  - pool_config_init (M1.T1.S2 @~95): freezes POOL_MASTER_DIR (absolute) + POOL_ALLOW_SLOW_COPY
        (normalized: exactly "1" → "1", else "0"). THIS task reads both; the slow-copy branch
        relies on the bool normalization.

CALLER (future — M5.T1.S2 acquire post-lock boot, NOT built here):
  - After the flock critical section releases the provisional claim (key_findings FINDING 2:
    keep flock short), M5.T1.S2 runs: pool_copy_master "$POOL_EPHEMERAL_ROOT/$N" →
    find_free_port (M4.T2.S1) → launch Chrome (M4.T2.S2) → connect (M4.T3.S1) →
    pool_lease_update lane ephemeral_dir/port/chrome_pid/connected (M3.T1.S1). Because
    pool_copy_master mkdir's the parent and cleans partials, the caller need only ensure
    pool_config_init has run. pool_check_btrfs (the root-level gate) is expected to have been
    called by the acquire INIT path (M5.T1.S1), not here.

ENV VARS (all already wired by pool_config_init; NONE new in this task):
  - AGENT_CHROME_MASTER           → POOL_MASTER_DIR       (cp source; absolute)
  - AGENT_CHROME_ALLOW_SLOW_COPY  → POOL_ALLOW_SLOW_COPY  (the escape hatch; "1" → on)

NO DATABASE / NO ROUTES / NO CONFIG-FILE CHANGES. This is a pure library append.
```

## Validation Loop

> This is a bash library. There is no test harness yet (bats arrives in M9.T1.S1), so each
> level uses inline scenario scripts against the real `lib/pool.sh`. Every scenario that
> EXPECTS a `pool_die` MUST run inside a `( … )` subshell — pool_die's `exit 1` otherwise
> kills the whole command line (research §2).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the function — fix before proceeding.
bash -n lib/pool.sh                  # parse check — MUST be clean
shellcheck lib/pool.sh               # lint the WHOLE file — zero warnings

# Expected: both clean. If shellcheck flags the new function, READ the wiki (SC2155 = declare
# local separately from assignment; SC2086 = quote vars) and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

```bash
# Build a throwaway master on btrfs ($HOME) with content + the 3 Singleton* files.
M="$HOME/.abp_m4_master"; rm -rf "$M" "$HOME/.abp_m4_root" /tmp/abp_m4_root
mkdir -p "$M/Default"; echo prefs > "$M/Preferences"; echo cookies > "$M/Default/Cookies"
: > "$M/SingletonLock"; : > "$M/SingletonCookie"
python3 -c "import socket,os;socket.socket(socket.AF_UNIX).bind(os.environ['M']+'/SingletonSocket')" 2>/dev/null || : > "$M/SingletonSocket"

# (A) btrfs happy path → rc 0, <1s, flat, Singleton* gone
AGENT_CHROME_MASTER="$M" AGENT_CHROME_EPHEMERAL_ROOT="$HOME/.abp_m4_root/active" AGENT_CHROME_ALLOW_SLOW_COPY= \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "'"$HOME/.abp_m4_root/active/1"'" && echo "rc=0 OK"'
find "$HOME/.abp_m4_root/active/1" -maxdepth 2 | sort   # flat: Preferences, Default/Cookies

# (B) non-btrfs + slow-copy OFF → pool_die (SUBSHELL!)
( AGENT_CHROME_MASTER="$M" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/abp_m4_root/active" AGENT_CHROME_ALLOW_SLOW_COPY= \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "/tmp/abp_m4_root/active/1"' ) 2>&1 | grep -q "not btrfs" && echo "die OK"

# (C) non-btrfs + slow-copy ON → cp -a fallback, FLAT, Singleton* gone
AGENT_CHROME_MASTER="$M" AGENT_CHROME_EPHEMERAL_ROOT="/tmp/abp_m4_root/active" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_copy_master "/tmp/abp_m4_root/active/2" && echo "rc=0 OK"'
find "/tmp/abp_m4_root/active/2" -maxdepth 2 | sort    # FLAT (no nested .abp_m4_master/)

# Expected: each echoes OK / shows a flat tree. See Task 2 for the full assertion set.
```

### Level 3: Integration Testing (Real btrfs Master)

```bash
# If a REAL Chrome master exists at $AGENT_CHROME_MASTER (the production 4.8 GB profile),
# validate end-to-end against it (instant reflink is the whole point). Otherwise use the
# throwaway master from Level 2.
TARGET="$HOME/.agent-chrome-profiles/active/_m4_probe"
( set -euo pipefail; source lib/pool.sh; pool_config_init; \
  t0=$(date +%s.%N); pool_copy_master "$TARGET"; t1=$(date +%s.%N); \
  echo "copy elapsed: $(awk "BEGIN{print $t1-$t0}")s"; \
  [[ -f "$TARGET/Preferences" ]] && echo "flat OK"; \
  ls "$TARGET"/Singleton* 2>/dev/null && echo "Singleton FAIL" || echo "Singleton cleaned OK" )
rm -rf "$TARGET"   # clean up the probe (never leave a stray lane dir)
# Expected: copy elapsed well under 1s on btrfs (instant CoW); flat OK; Singleton cleaned OK.
# On the real host /home is btrfs — if elapsed is multi-second, reflink is NOT happening
# (investigate findmnt -T / the POOL_EPHEMERAL_ROOT mount).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the host filesystem facts the function relies on (regression against env change):
findmnt -nno FSTYPE -T "$HOME"            # EXPECT: btrfs   (reflink works here)
findmnt -nno FSTYPE -T /tmp               # EXPECT: tmpfs   (reflink fails here — the refusal path)
findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || echo "ephemeral root not yet created (OK)"

# Negative test on tmpfs is the canonical "loud refusal" proof (see Level 2 scenario B).
# Performance: a real-master copy MUST be ~ms (CoW), NOT seconds — see Level 3.
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (Level 1).
- [ ] `shellcheck lib/pool.sh` clean — whole file (Level 1).
- [ ] All Level 2 scenarios pass: btrfs happy (rc 0, flat, Singleton* gone); tmpfs+no-escape
      (pool_die, no partial); tmpfs+escape (cp -a fallback, flat, Singleton* gone); missing
      master (pool_die w/ bootstrap cmd); empty + non-absolute target_dir (pool_die).
- [ ] Level 3 real-btrfs-master copy is ~ms (instant CoW), flat, Singleton* removed.
- [ ] Level 4 host facts: `$HOME`=btrfs, `/tmp`=tmpfs.

### Feature Validation

- [ ] All success criteria from "What" section met.
- [ ] NESTING anti-regression: `$target/Preferences` exists AND `$target/<master-basename>/`
      does NOT (Task 2 nesting assertion).
- [ ] Reflink stderr never reaches the user on the failure path (2>/dev/null).
- [ ] A failed reflink leaves NO partial `$target` (rm -rf cleanup).
- [ ] SingletonSocket (AF_UNIX socket) is removed, not just the two regular files.
- [ ] Missing master → `pool_check_master` die message contains the literal
      `cp -a --reflink=always` bootstrap command.

### Code Quality Validation

- [ ] Follows existing codebase patterns: `local`-first (SC2155), `--` before path args,
      `if ! cmd; then` errexit guards, `pool_die`-tagged messages, `[[ ]] || pool_die` guards.
- [ ] Banner style matches the M3 sections; placed at EOF after `pool_lane_is_stale`.
- [ ] Composes `pool_check_master` (LANDED) — does not re-implement master-existence checks.
- [ ] Does NOT compose `pool_check_btrfs` (cp exit code is the detection).
- [ ] No new globals / env vars / files / on-disk layout beyond the caller-supplied target.

### Documentation & Deployment

- [ ] No new user docs required ("DOCS: none — internal function"; btrfs/reflink already in
      README.md). The function is self-documenting via its docstring header.
- [ ] No new env vars; no README changes; no .gitignore changes.

---

## Anti-Patterns to Avoid

- ❌ Don't run the reflink attempt WITHOUT `2>/dev/null` — on non-btrfs it floods thousands of
  per-file "Operation not supported" lines.
- ❌ Don't skip the `rm -rf -- "$target_dir"` on the failure path — the empty partial it leaves
  would (a) fool the caller's free-lane `[[ -d ]]` probe and (b) make the slow retry NEST.
- ❌ Don't `mkdir` the target itself (only the parent) — pre-creating the target flips
  `cp -a src dst` into nesting mode.
- ❌ Don't compose `pool_check_btrfs` — it pre-empts the contract's cp-exit-code detection and
  checks the wrong path (the root, not the target).
- ❌ Don't use `cp --reflink=auto` (silently falls back to a real 4.8 GB copy — the footgun);
  the contract mandates `--reflink=always`.
- ❌ Don't use a bare `findmnt -nno FSTYPE "$dir"` (no `-T`) — it exits 1 even on btrfs on this
  host. Always `-T`.
- ❌ Don't test a `pool_die` path without a `( … )` subshell — `exit 1` kills the test script.
- ❌ Don't ignore a failing `cp` under `set -e` without an `if !`/`||` guard (it ABORTs the
  caller).
- ❌ Don't rename `pool_copy_master` to `pool_lane_copy` — the contract + consumer say
  `pool_copy_master`.
