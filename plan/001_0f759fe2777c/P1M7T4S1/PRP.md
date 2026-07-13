# PRP — P1.M7.T4.S1: `pool_admin_doctor()` — full system reconciliation + dependency check

---

## Goal

**Feature Goal**: Implement **`pool_admin_doctor()`** — the user-facing `doctor`
diagnostic for `agent-browser-pool doctor` (PRD §2.12 `reconcile leases vs live
Chromes vs dirs; report leaks` + §2.16 `verify all dependencies present at runtime`).
Takes **NO input**. Performs a full system scan in six phases — **(1) DEPS**:
`command -v` each required runtime dep (flock, setsid, pgrep, pkill, cp, curl, jq)
+ the Chrome binary (`$POOL_CHROME_BIN`, name-or-path) + the OPTIONAL `notify-send`;
**(2) REAL BIN**: `$POOL_REAL_BIN` exists + executable; **(3) FS**: btrfs at
`$POOL_EPHEMERAL_ROOT`; **(4) MASTER**: `$POOL_MASTER_DIR` exists + non-empty;
**(5) RECONCILE LANES**: per lease — ephemeral_dir present? chrome_pid alive?
port listening? (→ LEAK / LEAK / DISCONNECTED); **(6) RECONCILE DIRS**: per dir in
`active/` — has a lease? (→ ORPHAN DIR). Prints a **sectioned report to stdout**
(`[dependencies] [binary] [filesystem] [master] [lanes] [dirs] [summary]`) with
per-item OK/WARN/FAIL + a summary `OK=N  WARN=N  FAIL=N` and a verdict.
**Returns 0 if healthy (no FAIL), 1 if any FAIL.** WARNs never move the exit code.

**Deliverable**: ONE new PUBLIC function `pool_admin_doctor()`, **APPENDED** to
`lib/pool.sh` at the **current live EOF** (after the LANDED `pool_admin_release`,
function `lib/pool.sh:3830`, EOF line 3916), introduced by a NEW section banner
`# Admin CLI — doctor (P1.M7.T4.S1)`. **Pure addition: no edits to any existing
function, no new private helpers, no new env-vars/globals, no new files.** It
COMPOSES five LANDED helpers — `pool_config_init` + `pool_state_init` (precondition,
M1.T1.S2/S3) + `pool_lanes_list` (M3.T2.S1) + `pool_lease_read` (M3.T1.S2) +
`pool_lease_exists` (M3.T2.S1) — and REPLICATES (does NOT call) the detection
logic of `pool_check_btrfs` (M4.T1.S1) + `pool_check_master` (M4.T1.S1) non-fatally,
plus `printf`/`mapfile`/`command -v`/`findmnt`/`curl`/`(( ))` (all already used
throughout the lib).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh` + exporting the `AGENT_*` env vars
  to a temp state dir + a real master dir + temp ephemeral root, then
  `pool_admin_doctor`:
  - **Healthy system** (all deps present, real bin executable, btrfs fs, master
    present+non-empty, no leases, no orphan dirs) → prints all six `[section]`
    headers + a `[summary]` line `OK=N  WARN=0  FAIL=0` + `Healthy.`; **rc 0**.
  - **Missing required dep** (e.g. shadow a dep) → that dep's line is `MISSING`,
    FAIL increments, `[summary] FAIL≥1` + `Problems found.`; **rc 1**.
  - **Non-btrfs fs, no slow-copy** → `[filesystem]` line is `FAIL`; rc 1.
  - **Non-btrfs fs, slow-copy allowed** (`AGENT_CHROME_ALLOW_SLOW_COPY=1`) →
    `[filesystem]` line is `WARN`; rc 0 (WARN only).
  - **Lease with dead chrome_pid** → `[lanes]` line `lane N WARN (LEAK(dead chrome)…)`;
    WARN increments; rc 0 (recoverable).
  - **Lease, port not listening** (curl overridden to fail) → `… DISCONNECTED …`;
    WARN increments; rc 0.
  - **Provisional lease** (port=0) → `lane N WARN (PROVISIONAL; incomplete acquire)`;
    the three per-lane checks are SKIPPED (no spurious LEAK/DISCONNECTED); rc 0.
  - **Orphan dir** (dir `3` with no `lanes/3.json`) → `[dirs]` line `… WARN (ORPHAN
    DIR: no lease)`; WARN increments; rc 0.
  - **notify-send absent** → `notify-send ... MISSING (optional)`; **NOT counted** as
    FAIL or WARN (it is optional); rc unaffected.
- **stdout discipline**: the entire report goes to STDOUT (capturable). `_pool_log`
  writes to log file + stderr (never stdout). doctor NEVER calls `pool_die` in its
  body (it reports, it does not die) — except the precondition helpers, which may
  `pool_die` on genuine misconfiguration (correct, matches siblings).
- **Return codes**: rc 0 if `fail == 0`; rc 1 if `fail > 0`. WARNs never affect rc.
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file,
  ZERO warnings — host-verified ShellCheck 0.11.0); all prior deliverables
  (M1–M7.T3.S1) unchanged and still callable; `lib/pool.sh`'s only diff is the
  appended banner + function.

## User Persona

**Target User**: Human admin (PRD §2.12 `doctor`; §1.5). The function is called
indirectly — the `bin/agent-browser-pool` dispatcher (M7.T5.S1) wires
`case "$cmd" in doctor) pool_admin_doctor ;;`. This task builds the LIBRARY
function only; the dispatcher binary is future work.

**Use Case**: The pool is misbehaving (lanes not acquired, Chromes leaking, copies
slow), OR the admin wants a pre-flight health check on a fresh host. The admin runs
`agent-browser-pool doctor` and reads a single sectioned report showing which
dependencies/binaries/fs/master are OK or broken, and which leases/dirs are
inconsistent — then runs `reap`/`release` to recover the WARNs, or fixes the
setup for the FAILs.

**User Journey**: `agent-browser-pool doctor` → reads `[summary] OK=9 WARN=2 FAIL=0`
+ `Healthy.` (rc 0, only recoverable cruft) → runs `agent-browser-pool reap` to
clear the stale leases → re-runs `doctor` → `OK=9 WARN=0 FAIL=0` / `Healthy.`.

**Pain Points Addressed**: Without `doctor`, diagnosing the pool requires manually
running `command -v`, `findmnt -T`, `ls $POOL_MASTER_DIR`, `cat lanes/*.json`,
`pgrep`, and `curl /json/version` — one at a time, with no severity triage. `doctor`
collapses this into ONE command with a FAIL/WARN split that tells the admin
"blocking setup problem" (FAIL) vs "recoverable cruft — run reap/release" (WARN).

## Why

- **This IS PRD §2.12's `doctor` command** (`reconcile leases vs live Chromes vs
  dirs; report leaks`) AND PRD §2.16's runtime dependency verification
  ("`agent-browser-pool doctor` should verify all of the above at runtime"). It is
  the ONLY command that crosses every subsystem (deps, fs, master, leases, dirs).
- **It is a READ-ONLY DIAGNOSTIC — it changes nothing.** Unlike `reap`/`release`
  (which tear lanes down), `doctor` only PROBES + REPORTS. The admin decides what
  to do from its output. (This is why it returns rc 1 on FAIL but takes no
  destructive action.)
- **Its single most important constraint is NON-FATAL probing.** `pool_die`
  (`lib/pool.sh:30`) is `exit 1` — a PROCESS exit, NOT catchable. The LANDED
  `pool_check_btrfs` (`lib/pool.sh:230`) and `pool_check_master` (`lib/pool.sh:266`)
  BOTH `pool_die` on the very failures `doctor` exists to DETECT + REPORT. If
  `doctor` called them, the first problem would abort the whole run BEFORE the
  summary printed. So `doctor` REPLICATES their detection logic NON-fatally (the
  same `findmnt -T` / `ls -A` primitives, but `if/else` instead of `pool_die`).
  This is the dominant correctness constraint (design-decisions D3).
- **Its severity model is a deliberate FAIL/WARN split.** Infrastructure problems
  (missing required dep, wrong fs, missing master) BLOCK correct pool operation →
  FAIL (exit 1). Lane/dir inconsistencies (leaks, orphans, disconnected) are
  EXACTLY what `reap`/`release` recover from → WARN (exit 0). Precedent: `brew
  doctor` (advisory vs hard error), `git fsck` (non-zero on error). So `doctor`
  becomes a triage tool, not a binary pass/fail (design-decisions D4).
- **It must NOT duplicate or conflict with sibling tasks.** M7.T1.S1 (`status`,
  LANDED), M7.T2.S1 (`reap`, LANDED), M7.T3.S1 (`release`, LANDED), M7.T5.S1 (the
  dispatcher + `--help` wiring, FUTURE) are all separate. This task owns ONLY
  `pool_admin_doctor()` in `lib/pool.sh`.

## What

User-visible behavior: **`agent-browser-pool doctor`** prints a sectioned
diagnostic report to stdout and exits 0 (healthy / only WARNs) or 1 (any FAIL).

### The contract (authoritative from item description + research)

**Input**: None (full system scan).

**Logic (item contract §3 a–g, verbatim):**
- a. **CHECK DEPENDENCIES**: for each required dep in {flock, setsid, pgrep, pkill,
  curl, jq, google-chrome-stable→`$POOL_CHROME_BIN`, cp} → `command -v` (or `-x` for
  a path); print OK/MISSING; MISSING = FAIL. Plus `notify-send` (OPTIONAL → MISSING
  is NOT a FAIL).
- b. **CHECK REAL BIN**: `$POOL_REAL_BIN` exists + executable → OK/MISSING; missing = FAIL.
- c. **CHECK FS**: btrfs at `$POOL_EPHEMERAL_ROOT` (via `findmnt -T`) → OK / FAIL
  (or WARN if non-btrfs AND `$POOL_ALLOW_SLOW_COPY==1`).
- d. **CHECK MASTER**: `$POOL_MASTER_DIR` exists + non-empty → OK / FAIL.
- e. **RECONCILE LANES**: for each lease — ephemeral_dir exists? (no → LEAK);
  chrome_pid alive? (no → LEAK); port listening? (no → DISCONNECTED). Each = WARN.
- f. **RECONCILE DIRS**: for each dir in `active/` — has a lease? (no → ORPHAN
  DIR). = WARN.
- g. **Print summary** with OK/WARN/FAIL counts. **Return non-zero if any FAIL.**

**Output**: diagnostic report to stdout. Exit 0 if healthy (no FAIL), 1 if any FAIL.

**DOCS**: [Mode A] the function's header doc-comment describes every check + the
output contract. A suggested `--help` line is provided for the dispatcher (M7.T5.S1)
to wire.

### Success Criteria

- [ ] `pool_admin_doctor()` appended to `lib/pool.sh` under banner
      `# Admin CLI — doctor (P1.M7.T4.S1)`; no other function touched.
- [ ] `bash -n lib/pool.sh` → exit 0; `shellcheck -s bash lib/pool.sh` → ZERO warnings.
- [ ] Prints all six section headers (`[dependencies] [binary] [filesystem] [master]
      [lanes] [dirs]`) + `[summary]` with `OK=N  WARN=N  FAIL=N` + a verdict line.
- [ ] Required dep present → `OK` + ok++; absent → `MISSING` + fail++.
- [ ] `notify-send` absent → `MISSING (optional)`, NOT counted toward FAIL or WARN.
- [ ] `$POOL_REAL_BIN` executable → OK; not → FAIL.
- [ ] btrfs → OK; non-btrfs + slow-copy → WARN; non-btrfs + no-slow-copy → FAIL.
- [ ] master present+non-empty → OK; else FAIL.
- [ ] Per lease: dir missing → LEAK (WARN); dead chrome_pid → LEAK (WARN); port not
      listening → DISCONNECTED (WARN). A booted lane with all three healthy → `OK`.
- [ ] Provisional lease (port=0) → ONE WARN `PROVISIONAL`; the three checks SKIPPED.
- [ ] Dir with no lease → ORPHAN DIR (WARN).
- [ ] rc 0 iff `fail == 0`; rc 1 iff `fail > 0`. WARN never affects rc.
- [ ] NEVER `pool_die` in the body (report, don't die). Precondition may `pool_die`.
- [ ] `lib/pool.sh` diff is append-only (banner + function); `bin/`, `.gitignore`,
      `PRD.md`, `tasks.json` untouched.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **verbatim six-phase
contract** (item description + research, re-stated with a copy-pasteable
implementation); the **single critical gotcha** — `pool_die` is `exit 1` (uncatchable),
so `doctor` CANNOT call `pool_check_btrfs`/`pool_check_master` and must replicate
their detection non-fatally (design-decisions D3); the **severity model** (FAIL =
blocking infra; WARN = recoverable lane/dir cruft — design-decisions D4); the
**notify-send-is-optional** asymmetry (D5); the **chrome-check-uses-`$POOL_CHROME_BIN`
not the literal "google-chrome-stable"** substitution (D6); the **provisional-lease
handling** (D9); the **`findmnt -T` MANDATORY** + **curl `--max-time 2`** +
**`/proc` liveness** primitives (facts §3/§9/§8); the **`set -e` guard enumeration**
(line 18, not the stale 23 cited by siblings — D16); the **dynamic append site**
(after the LANDED `pool_admin_release`, D1); host-verified tooling (bash 5.3,
ShellCheck 0.11); and copy-pasteable, **deterministic** validation (function-overrides
for `findmnt`/`curl` + synthetic leases + a fake master + a live/dead pid).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.12 (admin CLI: `doctor  # reconcile leases vs live Chromes vs dirs; report
        leaks`). §2.16 (Dependencies — the full dep list `doctor` must verify at
        runtime: flock/setsid/pgrep/pkill/curl/jq/notify-send[optional]/cp +
        google-chrome-stable; btrfs at the pool root). §2.14 (Failure modes — the
        LEAK/DISCONNECTED findings map to these: chrome crash, dead owner, missing
        master, non-btrfs).
  pattern: §2.12's `doctor` IS this command; §2.16 enumerates the deps to check.
  gotcha: §2.16 — notify-send is "optional"; its absence must NOT be a FAIL.

# This task's own research (the factual + external + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M7T4S1/research/codebase-doctor-facts.md
  why: §1 the globals doctor reads (POOL_REAL_BIN/EPHEMERAL_ROOT/MASTER_DIR/CHROME_BIN
        name-or-path/ALLOW_SLOW_COPY/LANES_DIR) + pool_state_init idempotency. §2
        pool_die = exit 1 (uncatchable) → doctor CANNOT call pool_check_btrfs/master.
        §3 the btrfs primitive (findmnt -T MANDATORY; empty = not-btrfs). §4 the master
        primitive (-d + ls -A). §5 the LANDED sibling SHAPE (status's mapfile/jq
        extraction idiom; reap's rc contract; CURRENT EOF = 3916 after release).
        §6 lease-read primitives (pool_lease_read rc 1 MUST guard; one-fork jq mapfile
        recommended). §7 lease schema + ephemeral_dir naming. §8 chrome liveness
        idiom ([[ -d /proc/$pid ]]). §9 port-listening idiom (curl -sf --max-time 2).
        §10 notify-send optional. §11 command -v idiom. §12 the set -e hazards.
        §13 the DYNAMIC append site. §14 sibling boundaries. §15 pool_lanes_list.
  pattern: §3/§4's primitives ARE the fs/master checks (replicated non-fatally); §5's
        status shape IS the reconcile-loop structure; §8/§9 ARE the per-lane checks.
  gotcha: §2 — pool_die aborts; §3 — findmnt needs -T; §6 — pool_lease_read rc 1 ABORTS
        bare under set -e (MUST `if !`).

- file: plan/001_0f759fe2777c/P1M7T4S1/research/external-doctor-patterns.md
  why: §1 command -v idiom (POSIX; prefer over `which` — SC2230) + name-or-path helper.
        §2 exit-code conventions (git fsck / brew doctor / npm doctor; validates the
        WARN=exit0/FAIL=exit1 split). §3 report formatting (sectioned + per-item +
        summary + verdict). §4 findmnt -T semantics. §5 /proc liveness + PID-recycling
        caveat + TASK_COMM_LEN=15 truncation. §6 curl -sf --max-time probe. §7 the
        set -e pitfalls (bare (( )) @0; command -v rc1; SC2155; nullglob).
  pattern: §1's command -v + §3's sectioned format + §6's curl ARE doctor's probes/format.
  gotcha: §5 — /proc/$pid proves "a process" not "Chrome" (recycling); accepted because
        the reconciliation is multi-faceted (dir+port catch true leaks). §7 — every
        probe MUST be guarded or doctor aborts before the summary.

- file: plan/001_0f759fe2777c/P1M7T4S1/research/design-decisions.md
  why: D1 (append at DYNAMIC EOF after release, own banner). D2 (no input). D3 (non-fatal
        — replicate, do NOT call pool_check_btrfs/master). D4 (severity model FAIL/WARN).
        D5 (notify-send optional). D6 (chrome → POOL_CHROME_BIN name-or-path). D7
        (command -v in a guard). D8 (reconcile loop mirrors status). D9 (per-lane checks
        + provisional-lease handling + PID-recycling caveat). D10 (orphan-dir detection).
        D11 (sectioned output format). D12 (return codes). D13 (never pool_die in body).
        D14 (Mode A docs + suggested --help). D15 (no collateral edits). D16 (set -e at
        line 18; guard enumeration).
  pattern: D3's replication + D4's severity + D9's provisional handling ARE the implementation.
  gotcha: D3 — calling pool_check_btrfs/master ABORTS on the first FAIL before the summary;
        D9 — a provisional lease (port=0) would spuriously triple-flag without the skip.

# The LANDED siblings (the shape to mirror — same lib-only, append-under-banner form)
- file: plan/001_0f759fe2777c/P1M7T1S1/PRP.md
  why: pool_admin_status() (LANDED @ lib/pool.sh:3594) — the `mapfile -t lanes < <(pool_lanes_list)`
        snapshot, the empty-pool `(( ${#lanes[@]} == 0 ))` inside `if`, the per-lane
        `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"` guard, and the ONE-fork
        `mapfile -t fields < <(jq -r '.a, .b, .c' <<<"$json")` extraction — ALL reused
        verbatim in doctor's reconcile loop.
  pattern: status's snapshot + per-lane read + one-fork jq extraction IS doctor's [lanes] loop.
  gotcha: status's doc-comment cites "lib/pool.sh:23" for set -e — that is STALE; the real
        line is 18 (verified). doctor's header cites line 18.
- file: plan/001_0f759fe2777c/P1M7T2S1/PRP.md
  why: pool_admin_reap() (LANDED @ lib/pool.sh:3730) — the no-arg + rc contract shape
        doctor mirrors (no input; locals up front; precondition; return). reap is rc-0-
        always; doctor is NOT (it returns rc 1 on FAIL) — the deliberate divergence.
- file: plan/001_0f759fe2777c/P1M7T3S1/PRP.md
  why: pool_admin_release() (LANDED @ lib/pool.sh:3830) — confirms the append site moved
        (release LANDED during this task's research; EOF is now 3916 = release's closing
        `}`). doctor appends AFTER release, at the dynamic live EOF.

# The helpers doctor composes (the real dependencies — all LANDED + contract-documented)
- file: lib/pool.sh
  why: line 18 (set -euo pipefail — the REAL strict-mode line; siblings' ":23" refs are
        stale). pool_config_init @126 (globals; POOL_CHROME_BIN name-or-path @152-174;
        POOL_ALLOW_SLOW_COPY @194). pool_state_init @202 (idempotent mkdir). pool_die
        @30 (exit 1 — why doctor cannot call pool_check_btrfs/master). pool_check_btrfs
        @230 (the findmnt -T primitive @234 to REPLICATE). pool_check_master @266 (the
        -d + ls -A primitive @267-269 to REPLICATE). pool_lease_read @823 (rc 1 MUST
        guard `if !`). pool_lease_exists @918 (rc 0/1 predicate; guard in `if !`).
        pool_lanes_list @967 (rc 0 always; numeric sorted). pool_owner_alive @616
        ([[ -d /proc/$pid ]] liveness @636). pool_daemon_connected @1689 (curl -sf
        /json/version @1711). pool_find_free_port @1376 (curl --max-time 2 @1407).
        pool_admin_status @3594 (the mapfile/jq idiom). pool_admin_release @3830 (current
        last function; EOF 3916 = append site). _pool_alert @2815 (command -v notify-send
        @2824 — the OPTIONAL precedent).
  pattern: status's [lanes] loop + pool_check_btrfs/master's primitives + pool_daemon_connected's
        curl + _pool_alert's command -v ARE doctor's building blocks.
  gotcha: pool_die is exit 1 (uncatchable) — replicate, don't call. pool_lease_read /
        pool_lease_exists rc 1 ABORTS bare under set -e — guard with `if !`. findmnt
        needs -T. A provisional lease (port=0) would spuriously triple-flag.
```

### Current Codebase tree

After **M1–M7.T3.S1** landed (status/reap/release all LANDED), `lib/pool.sh` is
**3916 lines**, ending at `pool_admin_release` (closing `}` @3916). `bin/agent-browser`
exists (M6.T3.S2). The admin CLI binary does NOT exist yet (M7.T5.S1). **THIS task
appends `pool_admin_doctor()` to `lib/pool.sh`:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   ├── .gitkeep                          # retained (admin CLI bin/agent-browser-pool is M7.T5.S1)
│   └── agent-browser                     # M6.T3.S2 (the wrapper shim) — UNCHANGED
├── lib/
│   └── pool.sh                           # EOF @3916 (pool_admin_release). THIS task APPENDS
│                                         #   the banner "# Admin CLI — doctor (P1.M7.T4.S1)"
│                                         #   + pool_admin_doctor() at the DYNAMIC live EOF.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M7T4S1/
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-doctor-facts,external-doctor-patterns,design-decisions}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                           # MODIFIED (append-only): +banner +pool_admin_doctor() at EOF
└── (no other files change)
```

**File responsibility**: `pool_admin_doctor()` is the **user-facing diagnostic**
backing `agent-browser-pool doctor`. It owns NO mutation — it probes six subsystems
(deps/bin/fs/master/lanes/dirs), classifies each finding FAIL (blocking) or WARN
(recoverable), prints a sectioned report, and returns rc 0/1. It is consumed by the
future dispatcher (M7.T5.S1: `case doctor) pool_admin_doctor ;;`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (pool_die is exit 1 — UNCATCHABLE — design-decisions D3): pool_check_btrfs
#   (lib/pool.sh:230) and pool_check_master (lib/pool.sh:266) BOTH pool_die on the
#   failures doctor must DETECT+REPORT. Calling them would abort doctor on the FIRST
#   problem before the summary prints. doctor REPLICATES their detection NON-fatally:
#     btrfs:  fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
#             [[ "$fstype" == "btrfs" ]]   # empty fstype = not-btrfs (missing root / findmnt fail)
#     master: [[ -d "$POOL_MASTER_DIR" ]] && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]
#   This is the ONE place doctor must NOT compose the landed helpers.

# CRITICAL (findmnt -T is MANDATORY — facts §3 / pool_check_btrfs @217-221): a bare
#   `findmnt -nno FSTYPE "$dir"` (NO -T) matches the positional arg against SOURCE
#   (a device), not the mount tree, and exits 1 on this host EVEN ON BTRFS. Always
#   `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"`. The `|| true` neutralizes a
#   missing-path exit-1 so set -e does not abort the capture.

# CRITICAL (pool_lease_read / pool_lease_exists rc 1 ABORTS under set -e — facts §6):
#   a BARE `json="$(pool_lease_read "$lane")"` whose rc is 1 (missing/corrupt) ABORTS.
#   ALWAYS `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …; continue; fi`.
#   Likewise `if ! pool_lease_exists "$base"; then …; fi` (rc 1 = no lease = orphan).

# CRITICAL (command -v rc 1 ABORTS under set -e — D7 / external §7): a BARE
#   `command -v "$dep"` for an ABSENT dep returns 1 → ABORTS. ALWAYS inside
#   `if command -v "$dep" >/dev/null 2>&1; then …; else …; fi` (rc 1 → else, exempt).

# CRITICAL (bare `(( expr ))` STATEMENT returns 1 when value is 0 — D16): FATAL under
#   set -e. Keep `(( ))` ONLY inside `if`/`elif`/`&&`/`||`. So
#   `if (( fail > 0 )); then return 1; …` (inside if — safe); a BARE `(( fail > 0 ))`
#   when fail==0 would ABORT. The `$(( ))` expansion form (`ok=$((ok+1))`) is ALWAYS safe.

# CRITICAL (SC2155 — never `local x="$(…)"`): declare ALL locals up front, then assign.
#   `local ok=0` (literal) is SC2155-safe; `local fstype` then `fstype="$(…)"` (split).
#   The house rule (pool_admin_status @lib/pool.sh:3607-3611).

# CRITICAL (curl returns non-zero on a closed port — D9 / pool_daemon_connected @1711):
#   `curl -sf --max-time 2 …/json/version` exits 7/22/28 on a dead port. ALWAYS inside
#   `if curl …; then …; else …; fi` (the DISCONNECTED branch). `--max-time 2` bounds a
#   hung port (matches pool_find_free_port @1407). The probe is SIDE-EFFECT-FREE.

# CRITICAL (provisional lease — D9): a lease with port==0 (and chrome_pid==0) is a
#   PROVISIONAL claim from pool_acquire_locked step 3d that did NOT complete boot. The
#   three per-lane checks would spuriously flag LEAK(dead-chrome)+DISCONNECTED(port=0).
#   So: if port is NOT a positive integer → emit ONE WARN "PROVISIONAL" and `continue`
#   (skip the three checks). A persistent provisional lease is itself a leak → WARN.

# GOTCHA (notify-send is OPTIONAL — D5 / PRD §2.16 / _pool_alert @2824): a MISSING
#   notify-send is printed "MISSING (optional)" and is NOT counted toward FAIL or WARN.
#   All OTHER deps are required → MISSING is FAIL.

# GOTCHA (chrome dep → POOL_CHROME_BIN, not the literal "google-chrome-stable" — D6):
#   POOL_CHROME_BIN is configurable ($AGENT_CHROME_BIN; default google-chrome-stable).
#   If it contains "/" → `[[ -f … && -x … ]]`; else `command -v`. Checking the literal
#   "google-chrome-stable" would FALSE-alarm on a chromium setup.

# GOTCHA (PID-recycling caveat — D9 / external §5): `[[ -d /proc/$chrome_pid ]]` proves
#   *a* process holds the PID, not that it is Chrome. Accepted: it matches the codebase
#   idiom (pool_owner_alive @636) + the contract; the reconciliation is multi-faceted
#   (a recycled PID still fails the port/dir checks). Chrome `comm` is truncated
#   (TASK_COMM_LEN=15 → "google-chrome-s") → a comm match is unreliable (false negatives).
#   The simple /proc check is the baseline; a stronger /proc/$pid/exe match is FUTURE work.

# GOTCHA (strict-mode line is 18, NOT 23 — facts §12): the LANDED admin comments cite
#   "lib/pool.sh:23"; that is STALE. `set -euo pipefail` is at line 18 (verified).
#   doctor's header cites line 18.

# GOTCHA (nullglob is NOT set — D10 / pool_lanes_list @970): a no-match glob
#   "$POOL_EPHEMERAL_ROOT/*/" expands to its LITERAL. Guard `[[ -d "$d" ]] || continue`.

# GOTCHA (the precondition can pool_die — D13): pool_config_init / pool_state_init are
#   rc-0-or-pool_die. This is CORRECT — a misconfigured pool fails loudly. No guard
#   (matches status/reap/release). doctor's OWN body never calls pool_die.
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk change, NO new
env-vars/globals. It probes six subsystems, classifies findings into three integer
counters (`ok`/`warn`/`fail`), and prints a formatted report. The locals are: the
three counters; probe scratch (`fstype`, `dep`, `chrome_present`, `chrome_label`,
`dir_count`, `orphan_count`); the lanes snapshot array (`lanes`) + per-lane scratch
(`fields`, `lane`, `json`, `ephemeral_dir`, `chrome_pid`, `port`, `findings`); and
the dir-loop vars (`d`, `base`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the compose targets exist
  - RUN: test -f lib/pool.sh && echo "OK lib present"
  - EXPECT: present.
  - RUN (confirm greenfield — NO existing pool_admin_doctor):
        grep -n 'pool_admin_doctor' lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield (no matches — only comment references to "doctor M7.T4" elsewhere).
  - RUN (confirm the compose targets are defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_config_init pool_state_init pool_lanes_list pool_lease_read pool_lease_exists; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; \
          done; echo "OK all compose targets defined"'
  - EXPECT: OK all compose targets defined.
  - RUN (confirm the NON-fatal-replicate targets exist — doctor does NOT call them but
        replicates their logic; confirm they pool_die so the gotcha is real):
        sed -n '30,33p' lib/pool.sh                    # pool_die = exit 1
        sed -n '230,260p' lib/pool.sh | grep -n pool_die   # pool_check_btrfs dies
        sed -n '266,290p' lib/pool.sh | grep -n pool_die   # pool_check_master dies
  - EXPECT: pool_die is `printf … >&2; exit 1`; both check functions call pool_die on failure.
  - RUN (confirm the DYNAMIC append site — the CURRENT live EOF):
        wc -l lib/pool.sh; tail -3 lib/pool.sh; grep -n '^pool_admin_release' lib/pool.sh
  - EXPECT: EOF is the closing `}` of pool_admin_release (LANDED). APPEND after it.
        (Do NOT hardcode a line number — the EOF moves as siblings land. Detect via tail.)
  - RUN (confirm the LANDED sibling shape + the mapfile/jq idiom):
        sed -n '3594,3670p' lib/pool.sh    # pool_admin_status: locals, mapfile, one-fork jq
  - EXPECT: status's snapshot + per-lane guard + one-fork jq extraction (the reconcile pattern).
  - RUN (host tooling):
        bash --version | head -1
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'
        command -v findmnt curl jq >/dev/null && echo "OK probes present"
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0, findmnt/curl/jq present.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not break existing syntax).

Task 1: APPEND pool_admin_doctor() to lib/pool.sh (the verbatim contract)
  - PLACEMENT: APPEND at the END of lib/pool.sh (at the CURRENT live EOF — after the
        closing `}` of pool_admin_release), preceded by the new banner. NO edits to any
        existing line. Detect the append site via `tail` (do not hardcode a line number).
  - IMPLEMENT (verbatim — paste exactly; the header doc-comment satisfies the item's
        DOCS step by documenting every check + the output contract):

# ============================================================================
# Admin CLI — doctor (P1.M7.T4.S1)
# ============================================================================
# pool_admin_doctor
#
# PRD §2.12 `doctor` ("reconcile leases vs live Chromes vs dirs; report leaks") +
# §2.16 ("verify all dependencies present at runtime"). The USER-FACING diagnostic
# for `agent-browser-pool doctor`. NO input. READ-ONLY: probes six subsystems, prints
# a sectioned report, returns rc 0/1. Changes NOTHING on disk (unlike reap/release).
#
# LOGIC (CONTRACT a→g):
#   a. DEPS        — command -v each required dep {flock, setsid, pgrep, pkill, cp,
#                    curl, jq} + the Chrome binary ($POOL_CHROME_BIN, name-or-path) +
#                    the OPTIONAL notify-send. Required MISSING → FAIL; notify-send
#                    MISSING → "(optional)", NOT counted.
#   b. REAL BIN    — $POOL_REAL_BIN is a regular file + executable → OK / FAIL.
#   c. FS          — btrfs at $POOL_EPHEMERAL_ROOT (findmnt -T) → OK; non-btrfs +
#                    POOL_ALLOW_SLOW_COPY==1 → WARN; non-btrfs + no-slow-copy → FAIL.
#   d. MASTER      — $POOL_MASTER_DIR exists + non-empty (-d + ls -A) → OK / FAIL.
#   e. RECONCILE LANES — per lease (pool_lanes_list): ephemeral_dir missing → LEAK;
#                    dead chrome_pid → LEAK; port not listening (curl /json/version) →
#                    DISCONNECTED. Each = WARN. A provisional lease (port=0) → ONE WARN
#                    "PROVISIONAL" and the three checks are SKIPPED.
#   f. RECONCILE DIRS  — per numeric dir in $POOL_EPHEMERAL_ROOT: no matching lease →
#                    ORPHAN DIR = WARN.
#   g. SUMMARY     — print "OK=N  WARN=N  FAIL=N" + verdict; return 1 if fail>0 else 0.
#
# SEVERITY MODEL (FAIL = blocking infra; WARN = recoverable lane/dir cruft):
#   FAIL (exit 1): missing required dep; $POOL_REAL_BIN not executable; non-btrfs (no
#                  slow-copy); master missing/empty.
#   WARN (exit 0): non-btrfs + slow-copy; LEAK (no dir / dead chrome); DISCONNECTED;
#                  ORPHAN DIR; PROVISIONAL lease; corrupt/unreadable lease.
#   (not counted): notify-send MISSING (optional).
# Rationale: infra problems BLOCK correct pool operation → FAIL; lane/dir cruft is
#   EXACTLY what reap/release recover from → WARN. doctor = "FAIL = fix setup; WARN =
#   run reap/release." Precedent: brew doctor (advisory vs hard), git fsck (non-zero).
#
# OUTPUT (ALL to stdout — capturable):
#   [dependencies]
#     <dep>           OK | MISSING            (MISSING = FAIL, except notify-send)
#     chrome (<bin>)  OK | MISSING
#     notify-send     OK | MISSING (optional)
#   [binary]
#     <POOL_REAL_BIN> OK | MISSING (not executable)
#   [filesystem]
#     <EPHEMERAL_ROOT> OK (btrfs) | WARN (<fs>; slow-copy allowed) | FAIL (<fs>; not btrfs)
#   [master]
#     <MASTER_DIR>    OK | FAIL (missing or empty)
#   [lanes]
#     lane <N>   OK | WARN (LEAK(no dir); LEAK(dead chrome); DISCONNECTED) | WARN (PROVISIONAL)
#     (no active leases)   ← empty pool
#   [dirs]
#     <dir>      WARN (ORPHAN DIR: no lease)
#     (no ephemeral dirs) | (N dir(s), all leased)
#   [summary]
#     OK=N  WARN=N  FAIL=N
#     Healthy. | Problems found.
#
# CONTRACT:
#   - NON-FATAL probing (THE key constraint): pool_die (lib/pool.sh:30) is `exit 1`
#     (uncatchable). pool_check_btrfs (lib/pool.sh:230) + pool_check_master
#     (lib/pool.sh:266) BOTH pool_die on the failures doctor must DETECT+REPORT —
#     calling them would abort doctor on the FIRST problem before the summary prints.
#     So doctor REPLICATES their detection NON-fatally (findmnt -T / -d + ls -A) with
#     if/else instead of pool_die. This is the ONE place doctor does NOT compose the
#     landed helpers.
#   - READ-ONLY: doctor changes NOTHING. It is a diagnostic, not a recovery tool.
#     Recovery is reap/release (the admin decides from doctor's output).
#   - NEVER pool_die in the body (report, don't die). The ONLY pool_die-capable calls
#     are the precondition pool_config_init/pool_state_init (rc-0-or-pool_die on genuine
#     misconfiguration — correct; matches status/reap/release).
#   - RETURN CODES: rc 0 iff fail==0; rc 1 iff fail>0. WARN NEVER affects rc.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:18 [NOT 23 — sibling
# comments citing :23 are STALE]):
#   - command -v returns 1 on an ABSENT dep → a BARE call ABORTS. ALWAYS inside
#     `if command -v …; then …; else …; fi`.
#   - pool_lease_read returns rc 1 on missing/corrupt → a BARE capture ABORTS. ALWAYS
#     `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …; continue; fi`.
#   - pool_lease_exists returns rc 1 (no lease) → ALWAYS `if ! pool_lease_exists …; then`.
#   - findmnt / curl / ls exit non-zero (missing path / closed port / empty dir) →
#     `|| true` (findmnt, inside $()) or `if`/`if !` (curl, ls -A inside [[ ]]).
#   - `(( ))` ONLY inside `if`/`&&`/`||` (a BARE `(( ))` statement returns 1 when the
#     value is 0 → FATAL). `$(( ))` expansion (`ok=$((ok+1))`) is ALWAYS safe.
#   - never `local x="$(…)"` (SC2155); declare then assign. (`local ok=0` literal is safe.)
#   - nullglob NOT set → a no-match glob "$POOL_EPHEMERAL_ROOT/*/" is its literal →
#     `[[ -d "$d" ]] || continue`.
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case doctor) pool_admin_doctor ;;`.
pool_admin_doctor() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`). `ok/warn/fail` are
    # literal-initialized (safe); every `$(…)` capture is declared-then-assigned below.
    local ok=0 warn=0 fail=0
    local fstype dep chrome_present chrome_label dir_count orphan_count
    local -a lanes fields
    local lane json ephemeral_dir chrome_pid port findings
    local d base

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3616) + pool_admin_reap + pool_admin_release.
    pool_config_init
    pool_state_init

    # =========================================================================
    # [dependencies] — command -v each required dep + chrome (name-or-path) + notify-send
    # =========================================================================
    printf '[dependencies]\n'
    # Required PATH deps. `command -v` is POSIX-standard + the codebase idiom
    # (_pool_alert lib/pool.sh:2824); preferred over `which` (ShellCheck SC2230).
    # rc 1 (absent) MUST be inside `if` (a bare call ABORTS under set -e).
    for dep in flock setsid pgrep pkill cp curl jq; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf '  %-22s OK\n' "$dep"
            ok=$((ok+1))
        else
            printf '  %-22s MISSING\n' "$dep"
            fail=$((fail+1))
        fi
    done
    # Chrome — $POOL_CHROME_BIN (configurable via $AGENT_CHROME_BIN; default
    # google-chrome-stable). name-or-path branch (pool_config_init lib/pool.sh:152-174):
    # a path → -f + -x; a bare name → command -v. Checking the LITERAL "google-chrome-stable"
    # would FALSE-alarm on a chromium override.
    chrome_label="$POOL_CHROME_BIN"
    if [[ "$POOL_CHROME_BIN" == */* ]]; then
        if [[ -f "$POOL_CHROME_BIN" && -x "$POOL_CHROME_BIN" ]]; then
            chrome_present=1
        else
            chrome_present=0
        fi
    else
        if command -v "$POOL_CHROME_BIN" >/dev/null 2>&1; then
            chrome_present=1
        else
            chrome_present=0
        fi
    fi
    if (( chrome_present )); then
        printf '  %-22s OK\n' "chrome ($chrome_label)"
        ok=$((ok+1))
    else
        printf '  %-22s MISSING\n' "chrome ($chrome_label)"
        fail=$((fail+1))
    fi
    # notify-send — OPTIONAL (PRD §2.16; _pool_alert guards it lib/pool.sh:2824).
    # Absence is NOT a FAIL (and NOT a WARN) — it is genuinely fine to lack it.
    if command -v notify-send >/dev/null 2>&1; then
        printf '  %-22s OK\n' "notify-send"
        ok=$((ok+1))
    else
        printf '  %-22s MISSING (optional)\n' "notify-send"
    fi

    # =========================================================================
    # [binary] — $POOL_REAL_BIN exists + executable
    # =========================================================================
    printf '[binary]\n'
    if [[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]; then
        printf '  %-22s OK\n' "$POOL_REAL_BIN"
        ok=$((ok+1))
    else
        printf '  %-22s FAIL (missing or not executable)\n' "$POOL_REAL_BIN"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [filesystem] — btrfs at $POOL_EPHEMERAL_ROOT (REPLICATE pool_check_btrfs NON-fatally)
    # =========================================================================
    # pool_check_btrfs (lib/pool.sh:230) pool_die's on non-btrfs — doctor must NOT call
    # it (would abort before the summary). Replicate its findmnt -T primitive non-fatally.
    # `-T` is MANDATORY (pool_check_btrfs GOTCHA @217-221; a bare findmnt "$dir" matches
    # SOURCE not the mount tree and exits 1 even on btrfs). `|| true` neutralizes a
    # missing-path exit-1 → fstype becomes "" → "not btrfs".
    printf '[filesystem]\n'
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
    if [[ "$fstype" == "btrfs" ]]; then
        printf '  %-22s OK (btrfs)\n' "$POOL_EPHEMERAL_ROOT"
        ok=$((ok+1))
    elif [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
        # Non-btrfs but slow-copy allowed → degraded-but-functional (real 4.8 GB copy per
        # acquire) → WARN. (pool_check_btrfs allows this path too.)
        printf '  %-22s WARN (%s; slow-copy allowed)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"
        warn=$((warn+1))
    else
        printf '  %-22s FAIL (%s; not btrfs)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [master] — $POOL_MASTER_DIR exists + non-empty (REPLICATE pool_check_master NON-fatally)
    # =========================================================================
    # pool_check_master (lib/pool.sh:266) pool_die's on missing/empty — doctor must NOT
    # call it. Replicate its -d + ls -A primitive non-fatally (no stat/du of the 4.8 GB
    # master). `ls -A` inside `[[ -n "$(...)" ]]` is errexit-exempt; 2>/dev/null handles
    # a missing dir.
    printf '[master]\n'
    if [[ -d "$POOL_MASTER_DIR" ]] && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
        printf '  %-22s OK\n' "$POOL_MASTER_DIR"
        ok=$((ok+1))
    else
        printf '  %-22s FAIL (missing or empty)\n' "$POOL_MASTER_DIR"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [lanes] — reconcile each lease: dir present? chrome alive? port listening?
    # =========================================================================
    # Mirror pool_admin_status's snapshot (lib/pool.sh:3631) + per-lane read guard
    # (lib/pool.sh:3638) + ONE-fork jq extraction (lib/pool.sh:3650). pool_lanes_list
    # rc-0-always; process-sub exit not propagated → set -e safe; empty output → empty
    # array.
    printf '[lanes]\n'
    mapfile -t lanes < <(pool_lanes_list)
    if (( ${#lanes[@]} == 0 )); then
        # `(( ))` INSIDE `if` (bare @0 is FATAL under set -e).
        printf '  (no active leases)\n'
    else
        for lane in "${lanes[@]}"; do
            # pool_lease_read rc 1 (missing/corrupt) → MUST guard `if !` (bare ABORTS).
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                printf '  lane %-6s WARN (corrupt or unreadable lease)\n' "$lane"
                warn=$((warn+1))
                continue
            fi
            # ONE jq fork (mirror status): ephemeral_dir (str), chrome_pid (num), port (num).
            # `:-` defends a short read. jq -r echoes numbers as digit strings (fine for
            # /proc/$chrome_pid and the curl $port interpolation).
            mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")
            ephemeral_dir="${fields[0]:-}"
            chrome_pid="${fields[1]:-}"
            port="${fields[2]:-}"
            findings=""
            # Provisional lease (port not a positive integer) → incomplete acquire that was
            # NOT cleaned up. Skip the three checks (they'd spuriously triple-flag a
            # port=0/chrome=0 lease). A persistent provisional lease is itself a leak → WARN.
            # `[[ ]] && (( ))` in a `&&` list is errexit-exempt; `(( ))` only runs if the
            # regex matched (short-circuit) → safe.
            if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then
                # (1) dir present? `[[ ]] || findings+=` : test true → skip; false → append.
                [[ -d "$ephemeral_dir" ]] || findings+='LEAK(no dir); '
                # (2) chrome alive? codebase idiom [[ -d /proc/$pid ]] (pool_owner_alive
                # @636). A booted lane should have chrome_pid>0; 0/invalid → LEAK.
                if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
                    [[ -d "/proc/$chrome_pid" ]] || findings+='LEAK(dead chrome); '
                else
                    findings+='LEAK(invalid chrome_pid); '
                fi
                # (3) port listening? curl /json/version SIDE-EFFECT-FREE (pool_daemon_connected
                # @1711). --max-time 2 bounds a hung port (pool_find_free_port @1407). rc !=0
                # → DISCONNECTED.
                if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
                    :
                else
                    findings+='DISCONNECTED; '
                fi
                if [[ -z "$findings" ]]; then
                    printf '  lane %-6s OK\n' "$lane"
                    ok=$((ok+1))
                else
                    # Strip the trailing "; " (the `%` removes the shortest suffix match).
                    printf '  lane %-6s WARN (%s)\n' "$lane" "${findings%; }"
                    warn=$((warn+1))
                fi
            else
                printf '  lane %-6s WARN (PROVISIONAL; incomplete acquire)\n' "$lane"
                warn=$((warn+1))
            fi
        done
    fi

    # =========================================================================
    # [dirs] — orphan detection: per numeric dir in $POOL_EPHEMERAL_ROOT, no lease → ORPHAN
    # =========================================================================
    # nullglob NOT set → a no-match glob "$POOL_EPHEMERAL_ROOT/*/" is its literal → `[[ -d ]]
    # || continue` rejects it (+ files + subdirs). Numeric basename filter mirrors
    # pool_lanes_list's ^[0-9]+$ test. pool_lease_exists rc 1 (no lease) → MUST `if !`.
    printf '[dirs]\n'
    dir_count=0
    orphan_count=0
    if [[ -d "$POOL_EPHEMERAL_ROOT" ]]; then
        for d in "$POOL_EPHEMERAL_ROOT"/*/; do
            [[ -d "$d" ]] || continue
            base="${d%/}"           # strip trailing slash
            base="${base##*/}"      # basename
            [[ "$base" =~ ^[0-9]+$ ]] || continue
            dir_count=$((dir_count+1))
            if ! pool_lease_exists "$base"; then
                printf '  %-22s WARN (ORPHAN DIR: no lease)\n' "$d"
                orphan_count=$((orphan_count+1))
                warn=$((warn+1))
            fi
        done
    fi
    if (( dir_count == 0 )); then
        printf '  (no ephemeral dirs)\n'
    elif (( orphan_count == 0 )); then
        printf '  (%d dir(s), all leased)\n' "$dir_count"
    fi

    # =========================================================================
    # [summary] — counts + verdict + return code
    # =========================================================================
    printf '[summary]\n'
    printf '  OK=%d  WARN=%d  FAIL=%d\n' "$ok" "$warn" "$fail"
    # `(( ))` INSIDE `if` (bare @0 would be FATAL). WARN never affects rc.
    if (( fail > 0 )); then
        printf '  Problems found.\n'
        return 1
    fi
    printf '  Healthy.\n'
    return 0
}

  - VERIFY (immediately after):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (whole file)
        grep -n 'pool_admin_doctor' lib/pool.sh | head -1        # the definition line
        git diff --stat lib/pool.sh                              # append-only diff
  - EXPECT: all OK; the only change to lib/pool.sh is the appended banner + function.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY lib/pool.sh modified (append-only). bin/, .gitignore, PRD.md,
        tasks.json, prd_snapshot.md UNCHANGED. NO new files outside plan/.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the non-fatal fs/master replication (THE core gotcha — design-decisions D3):
# pool_check_btrfs / pool_check_master pool_die (exit 1, uncatchable) on the failures
# doctor must DETECT. Replicate their primitives with if/else:
fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"  # -T MANDATORY
if [[ "$fstype" == "btrfs" ]]; then …OK…;
elif [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then …WARN…;        # degraded-but-functional
else …FAIL…; fi
# master:
if [[ -d "$POOL_MASTER_DIR" ]] && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then …OK…;
else …FAIL…; fi

# PATTERN — the dep check (command -v, ALWAYS inside `if` — design-decisions D7):
for dep in flock setsid pgrep pkill cp curl jq; do
    if command -v "$dep" >/dev/null 2>&1; then printf OK; else printf MISSING; fi
done
# chrome name-or-path (D6): [[ "$POOL_CHROME_BIN" == */* ]] → -f+-x ; else command -v.

# PATTERN — the reconcile loop (mirrors pool_admin_status — design-decisions D8):
mapfile -t lanes < <(pool_lanes_list)          # rc 0 always
if (( ${#lanes[@]} == 0 )); then printf '(no active leases)\n'; else
  for lane in "${lanes[@]}"; do
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …WARN corrupt…; continue; fi
    mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")
    ephemeral_dir="${fields[0]:-}"; chrome_pid="${fields[1]:-}"; port="${fields[2]:-}"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then   # booted lane → 3 checks
      [[ -d "$ephemeral_dir" ]] || findings+='LEAK(no dir); '
      …chrome /port checks…
    else                                                    # provisional → 1 WARN, skip checks
      printf 'PROVISIONAL; incomplete acquire'
    fi
  done
fi

# PATTERN — the per-lane findings accumulator (one line per lane, all problems listed):
findings=""
[[ -d "$ephemeral_dir" ]] || findings+='LEAK(no dir); '
if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
    [[ -d "/proc/$chrome_pid" ]] || findings+='LEAK(dead chrome); '
else
    findings+='LEAK(invalid chrome_pid); '
fi
if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then :; \
else findings+='DISCONNECTED; '; fi
if [[ -z "$findings" ]]; then printf 'OK'; else printf 'WARN (%s)' "${findings%; }"; fi
# `[[ ]] || findings+=` : test true → skip; false → append (the compound always returns 0).
# `${findings%; }` strips the trailing "; ".

# GOTCHA — WHY provisional-lease handling is mandatory (D9): a lease with port=0 has
#   chrome_pid=0 too (acquire step 3d). Without the skip, doctor would print
#   "LEAK(dead chrome); DISCONNECTED" for EVERY provisional lease — spurious noise.
#   The `if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 ))` gate emits ONE "PROVISIONAL"
#   WARN and `continue`s past the three checks.

# GOTCHA — WHY WARN ≠ rc 1 (the severity model — D4): lane/dir cruft is recoverable via
#   reap/release; only BLOCKING infra problems (deps/bin/fs/master) exit non-zero. This
#   makes doctor a triage tool, not a binary pass/fail. rc = (fail > 0 ? 1 : 0).

# GOTCHA — WHY the `[[ ]] || findings+=` form is set -e-safe: `cmd1 || cmd2` runs cmd2
#   only if cmd1 fails (rc!=0). `[[ ]]` is a condition (always safe); `findings+=` is an
#   assignment (returns 0). So the compound always returns 0 → never aborts.

# GOTCHA — WHY not call pool_lane_is_stale for the dead-chrome check: pool_lane_is_stale
#   checks the OWNER's liveness (the `pi` process), not Chrome's. doctor reconciles the
#   CHROME (chrome_pid) directly via /proc, per the contract ("Is chrome_pid alive?").
```

### Integration Points

```yaml
FILESYSTEM:
  - modify: "lib/pool.sh (APPEND-ONLY: banner + pool_admin_doctor() at the DYNAMIC live EOF,
            currently after pool_admin_release @3830, EOF 3916). Detect the site via `tail`;
            do NOT hardcode a line number (the EOF moves as siblings land)."

LIBRARY (lib/pool.sh):
  - composes: "pool_config_init + pool_state_init (precondition); pool_lanes_list (lane
              enumerate); pool_lease_read (per-lane JSON, guard `if !`); pool_lease_exists
              (orphan probe, guard `if !`). All LANDED + contract-documented."
  - replicates (NON-fatally — does NOT call): "pool_check_btrfs's findmnt -T primitive;
              pool_check_master's -d + ls -A primitive. (They pool_die; doctor reports.)"
  - probes (external, all guarded): "command -v (deps); findmnt -T (fs); curl -sf
              --max-time 2 /json/version (port); [[ -d /proc/$pid ]] (chrome liveness);
              ls -A (master non-empty)."

GITIGNORE:
  - no change: ".gitignore is orchestrator-owned (M10.T1.S2); no rule matches the diff."

CONSUMERS (the dispatcher, FUTURE — NOT this task):
  - M7.T5.S1 bin/agent-browser-pool: "case \"\$cmd\" in doctor) pool_admin_doctor ;;". This
            task does NOT create the binary. It only provides the function the binary will
            call by name."

SUGGESTED --help TEXT (for M7.T5.S1 to reference — NOT wired by this task):
  - "  doctor                 diagnose the pool: deps, fs, master, reconcile leases/Chromes/dirs"
  - The dispatcher (M7.T5.S1) will echo this under the global `agent-browser-pool --help`
            usage block. This task documents the doctor command's behavior in the function's
            header doc-comment (Mode A) so the dispatcher author has the source of truth.

NO CHANGES TO:
  - any existing lib/pool.sh function (append-only), bin/ (M6.T3.S2 owns agent-browser;
    M7.T5.S1 owns agent-browser-pool), .gitignore, PRD.md / tasks.json / prd_snapshot.md
    (read-only), test/ (M9.T1.S1 owns the harness).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the function — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (WHOLE file)
grep -n 'pool_admin_doctor' lib/pool.sh | head -1        # the definition exists
git diff --stat lib/pool.sh                              # append-only (no -/= churn in middle)
# Expected: all OK. The diff should be purely additive (~150 + lines, 0 deletions).
#   shellcheck zero warnings: watch SC2155 (declare-then-assign; literal `local ok=0` is fine),
#   SC2086 (quote "$dep"/"$lane"/"$ephemeral_dir"/"$chrome_pid"/"$port"/"$base"/"$d" in printf
#   + interpolations), SC2059 (NOT triggered — every printf uses a literal format string, no $fmt
#   var). The `if command -v …` + `if ! json="$(pool_lease_read …)"` + `if ! pool_lease_exists …`
#   guards + `(( ))` inside if + `|| true` on findmnt + `[[ ]] || findings+=` are all clean.
```

### Level 2: Unit + Integration Tests (DETERMINISTIC — no real Chrome/master needed)

`pool_admin_doctor` is fully verifiable WITHOUT a real Chrome / a real master /
real btrfs by: (a) a temp state dir + a fake master + a temp ephemeral root;
(b) **function-overriding `findmnt` and `curl`** (bash resolves a same-named
function before the external binary → deterministic fs/port results); (c) synthetic
lease JSON in the temp lanes dir (exercises the REAL `pool_lanes_list` /
`pool_lease_read` / `pool_lease_exists`); (d) a live pid (`1`) vs a dead pid
(`9999999`) for the chrome-liveness branch.

```bash
# Save as /tmp/test_doctor.sh and run: bash /tmp/test_doctor.sh
# Run from the REPO ROOT.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/lib/pool.sh" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1" >&2; }

# --- fresh isolated state + fake master + temp ephemeral root ---
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"
mkdir -p "$STATE/lanes"
export AGENT_CHROME_MASTER="$STATE/master"
mkdir -p "$AGENT_CHROME_MASTER"; touch "$AGENT_CHROME_MASTER/Default"   # non-empty master
export AGENT_CHROME_EPHEMERAL_ROOT="$STATE/active"; mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT"
export AGENT_BROWSER_REAL="/bin/true"          # a real executable file → bin OK
export POOL_LOG_PATH=/dev/null                  # keep stderr clean
# (findmnt + curl are overridden PER-TEST below via function definitions.)

source ./lib/pool.sh
# pool_config_init freezes globals from the env vars above. doctor calls it itself; we
# rely on that (it re-resolves). Confirm the compose targets are the REAL functions:
type pool_lanes_list pool_lease_read pool_lease_exists >/dev/null && echo "OK real data layer"

# NOTE on the rc-capture idiom: `rc=0; out="$(pool_admin_doctor)" || rc=$?`. The
# `|| rc=$?` makes the capture errexit-EXEMPT — WITHOUT it, `out="$(…)"; rc=$?`
# would ABORT under `set -e` whenever doctor correctly returns 1 (Part B/C/D/G2),
# before `rc=$?` runs. This split idiom (BashFAQ 105) is used for every capture.

# ============================================================================
# PART A — HEALTHY SYSTEM (all OK, empty pool) → rc 0, "Healthy."
# ============================================================================
findmnt() { printf 'btrfs\n'; }    # btrfs
curl()     { return 0; }           # (unused — no lanes)
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 0 ]] && ok "A-healthy: rc 0" || bad "A-healthy: rc=$rc"
grep -q '\[dependencies\]' <<<"$out" && ok "A: [dependencies] header" || bad "A: no deps header"
grep -q '\[binary\]'        <<<"$out" && ok "A: [binary] header"        || bad "A: no binary header"
grep -q '\[filesystem\]'    <<<"$out" && ok "A: [filesystem] header"    || bad "A: no fs header"
grep -q '\[master\]'        <<<"$out" && ok "A: [master] header"        || bad "A: no master header"
grep -q '\[lanes\]'         <<<"$out" && ok "A: [lanes] header"         || bad "A: no lanes header"
grep -q '\[dirs\]'          <<<"$out" && ok "A: [dirs] header"          || bad "A: no dirs header"
grep -q '\[summary\]'       <<<"$out" && ok "A: [summary] header"       || bad "A: no summary header"
grep -Eq 'FAIL=0'           <<<"$out" && ok "A: FAIL=0"                 || bad "A: FAIL!=0 [$out]"
grep -q 'Healthy\.'         <<<"$out" && ok "A: verdict Healthy."       || bad "A: no Healthy."
grep -q '(no active leases)'<<<"$out" && ok "A: empty pool message"     || bad "A: no empty msg"
grep -q '(no ephemeral dirs)' <<<"$out" && ok "A: no dirs message"      || bad "A: no dirs msg"

# ============================================================================
# PART B — FS FAIL (non-btrfs, no slow-copy) → rc 1; + slow-copy → WARN, rc 0
# ============================================================================
unset AGENT_CHROME_ALLOW_SLOW_COPY
findmnt() { printf 'ext4\n'; }; curl() { return 0; }
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 1 ]] && ok "B-ext4-noslow: rc 1" || bad "B-ext4-noslow: rc=$rc"
grep -q 'FAIL (ext4; not btrfs)' <<<"$out" && ok "B-ext4-noslow: fs FAIL line" || bad "B: no fs FAIL"
grep -q 'Problems found\.' <<<"$out" && ok "B-ext4-noslow: verdict" || bad "B: no verdict"
# now allow slow-copy → WARN, rc 0 (still has no other FAIL)
export AGENT_CHROME_ALLOW_SLOW_COPY=1
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 0 ]] && ok "B-ext4-slow: rc 0 (WARN only)" || bad "B-ext4-slow: rc=$rc"
grep -q 'WARN (ext4; slow-copy allowed)' <<<"$out" && ok "B-ext4-slow: fs WARN line" || bad "B: no fs WARN"
unset AGENT_CHROME_ALLOW_SLOW_COPY

# ============================================================================
# PART C — MASTER FAIL (empty master) → rc 1
# ============================================================================
findmnt() { printf 'btrfs\n'; }; curl() { return 0; }
rm -f "$AGENT_CHROME_MASTER/Default"; rmdir "$AGENT_CHROME_MASTER"   # remove master
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 1 ]] && ok "C-master-missing: rc 1" || bad "C: rc=$rc"
grep -q 'FAIL (missing or empty)' <<<"$out" && ok "C: master FAIL line" || bad "C: no master FAIL"
# restore master for subsequent parts
mkdir -p "$AGENT_CHROME_MASTER"; touch "$AGENT_CHROME_MASTER/Default"

# ============================================================================
# PART D — REAL BIN FAIL (POOL_REAL_BIN not executable) → rc 1
# ============================================================================
export AGENT_BROWSER_REAL="$STATE/not-a-binary"; touch "$AGENT_BROWSER_REAL"   # exists, not -x
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 1 ]] && ok "D-bin-noexec: rc 1" || bad "D: rc=$rc"
grep -q 'FAIL (missing or not executable)' <<<"$out" && ok "D: bin FAIL line" || bad "D: no bin FAIL"
export AGENT_BROWSER_REAL="/bin/true"   # restore

# ============================================================================
# PART E — RECONCILE LANES: live lane OK; dead-chrome LEAK; DISCONNECTED; PROVISIONAL
# Uses the REAL pool_lanes_list / pool_lease_read / pool_lease_exists against synthetic leases.
# ============================================================================
findmnt() { printf 'btrfs\n'; }
mklease() { # $1=lane $2=ephemeral_dir $3=chrome_pid $4=port
  jq -n --argjson lane "$1" --arg ed "$2" --argjson cpid "$3" --argjson port "$4" \
    '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:("abpool-"+($lane|tostring)),
      owner:{pid:1,comm:"pi",starttime:1111,cwd:"/x"},chrome_pid:$cpid,chrome_pgid:$cpid,
      acquired_at:1,last_seen_at:1,connected:true}' > "$STATE/lanes/$1.json"
}

# E1: fully-healthy lane (dir exists, chrome=1 alive, port alive) → "lane 1 OK"
mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT/1"
mklease 1 "$AGENT_CHROME_EPHEMERAL_ROOT/1" 1 53421
curl() { return 0; }   # port alive
rc=0; out="$(pool_admin_doctor)" || rc=$?
grep -Eq 'lane 1 +OK' <<<"$out" && ok "E1-live: lane 1 OK" || bad "E1-live: [$out]"

# E2: dead chrome (9999999) → "LEAK(dead chrome)"; dir+port OK
mklease 2 "$AGENT_CHROME_EPHEMERAL_ROOT/2" 9999999 53422; mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT/2"
out="$(pool_admin_doctor)"
grep -Eq 'lane 2 +WARN \(LEAK\(dead chrome\)\)' <<<"$out" && ok "E2-deadchrome: LEAK" || bad "E2: [$out]"

# E3: port dead → "DISCONNECTED" (dir + chrome=1 alive)
mklease 3 "$AGENT_CHROME_EPHEMERAL_ROOT/3" 1 53423; mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT/3"
curl() { return 7; }
out="$(pool_admin_doctor)"
grep -Eq 'lane 3 +WARN \(DISCONNECTED\)' <<<"$out" && ok "E3-disconnected: DISCONNECTED" || bad "E3: [$out]"
curl() { return 0; }

# E4: dir missing → "LEAK(no dir)" (chrome=1 alive, port alive)
mklease 4 "$AGENT_CHROME_EPHEMERAL_ROOT/4-MISSING" 1 53424   # dir 4 does NOT exist
out="$(pool_admin_doctor)"
grep -Eq 'lane 4 +WARN \(LEAK\(no dir\)\)' <<<"$out" && ok "E4-nodir: LEAK(no dir)" || bad "E4: [$out]"

# E5: provisional lease (port=0) → ONE "PROVISIONAL" WARN; NO spurious LEAK/DISCONNECTED
mklease 5 "$AGENT_CHROME_EPHEMERAL_ROOT/5" 0 0
out="$(pool_admin_doctor)"
grep -Eq 'lane 5 +WARN \(PROVISIONAL' <<<"$out" && ok "E5-provisional: PROVISIONAL" || bad "E5: [$out]"
# verify the three checks did NOT also fire for lane 5:
! grep -Eq 'lane 5 .*LEAK|lane 5 .*DISCONNECTED' <<<"$out" \
    && ok "E5-provisional: no spurious LEAK/DISCONNECTED" || bad "E5: spurious findings [$out]"

# E6: multi-finding lane (dir missing + dead chrome + port dead) → all listed on ONE line
mklease 6 "$AGENT_CHROME_EPHEMERAL_ROOT/6-MISSING" 9999998 53426
curl() { return 7; }
out="$(pool_admin_doctor)"
grep -Eq 'lane 6 +WARN \(LEAK\(no dir\); LEAK\(dead chrome\); DISCONNECTED\)' <<<"$out" \
    && ok "E6-multifind: all 3 listed" || bad "E6: [$out]"
curl() { return 0; }

# clean lanes for the dirs test
rm -f "$STATE"/lanes/*.json

# ============================================================================
# PART F — RECONCILE DIRS: orphan dir (no lease) → ORPHAN DIR; leased dir → no WARN
# ============================================================================
findmnt() { printf 'btrfs\n'; }; curl() { return 0; }
# dir 7 with NO lease → orphan; dir 8 WITH a lease → not orphan
mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT/7" "$AGENT_CHROME_EPHEMERAL_ROOT/8"
mklease 8 "$AGENT_CHROME_EPHEMERAL_ROOT/8" 1 53428
out="$(pool_admin_doctor)"
grep -Eq 'WARN \(ORPHAN DIR: no lease\)' <<<"$out" && ok "F-orphan: ORPHAN DIR" || bad "F: [$out]"
# verify dir 8 is NOT flagged (it has a lease):
! grep -Eq 'active/8.*ORPHAN' <<<"$out" && ok "F-leased: dir 8 not orphan" || bad "F: dir 8 flagged [$out]"

# ============================================================================
# PART G — exit-code invariant: WARN-only → rc 0; any FAIL → rc 1
# ============================================================================
# G1: WARN-only (orphan dir, no other FAIL) → rc 0
findmnt() { printf 'btrfs\n'; }; curl() { return 0; }
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 0 ]] && ok "G1-warn-only: rc 0" || bad "G1: rc=$rc (WARN must not fail)"
# G2: add a FAIL (break master) → rc 1 even though WARNs exist
rmdir "$AGENT_CHROME_MASTER" 2>/dev/null || true; rm -f "$AGENT_CHROME_MASTER/Default" 2>/dev/null || true
rc=0; out="$(pool_admin_doctor)" || rc=$?
[[ "$rc" -eq 1 ]] && ok "G2-with-fail: rc 1 (FAIL dominates WARN)" || bad "G2: rc=$rc"

rm -rf "$STATE"
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≥45, fail=0. (Part A = structure + healthy. B = fs FAIL/WARN. C = master FAIL.
#   D = bin FAIL. E = the 6 reconcile cases (live/dead-chrome/disconnected/no-dir/provisional/
#   multi-find). F = orphan vs leased dir. G = the rc invariant.)
```

### Level 3: Integration Testing (System Validation — real host, optional)

The end-to-end against the REAL host filesystem (no overrides) is informational —
it confirms doctor runs against the real environment and produces a coherent report.
Most assertions are host-dependent (deps present, btrfs present, master may/ may not
exist), so Level 3 is a SMOKE test, not a strict gate (Level 2 is the gate).

```bash
# Run the REAL doctor against the real host (no findmnt/curl overrides). Expect it to
# complete without aborting (the non-fatal-probing contract) and emit all headers + a summary.
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"; mkdir -p "$STATE/lanes"
export AGENT_CHROME_MASTER="$STATE/master"; mkdir -p "$AGENT_CHROME_MASTER"; touch "$STATE/master/Default"
export AGENT_CHROME_EPHEMERAL_ROOT="$STATE/active"; mkdir -p "$AGENT_CHROME_EPHEMERAL_ROOT"
export AGENT_BROWSER_REAL="$(command -v agent-browser || echo /bin/true)"
set -euo pipefail; source ./lib/pool.sh
rc=0; out="$(pool_admin_doctor)" || rc=$?
echo "$out"
# Structural assertions (host-agnostic):
grep -q '\[dependencies\]' <<<"$out"
grep -q '\[summary\]'     <<<"$out"
grep -Eq 'OK=[0-9]+  WARN=[0-9]+  FAIL=[0-9]+' <<<"$out"
[[ "$rc" -eq 0 || "$rc" -eq 1 ]]   # never any other rc; never aborts mid-report
echo "OK smoke (rc=$rc)"
rm -rf "$STATE"
# Expected: completes; all headers present; a parseable summary; rc 0 or 1 (never a crash).
#   On a healthy host with btrfs + all deps + the temp master: OK=N WARN=0 FAIL=0, rc 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm doctor's report is GREP-able + the summary is machine-parseable (CI-friendly,
# per external-doctor-patterns §3).
set -euo pipefail; source ./lib/pool.sh
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"; mkdir -p "$STATE/lanes"
export AGENT_CHROME_MASTER="$STATE/master"; mkdir -p "$STATE/master"; touch "$STATE/master/Default"
export AGENT_CHROME_EPHEMERAL_ROOT="$STATE/active"; mkdir -p "$STATE/active"
export AGENT_BROWSER_REAL=/bin/true
findmnt() { printf 'btrfs\n'; }; curl() { return 0; }
out="$(pool_admin_doctor)"
# the summary line is the ONLY line matching OK=N WARN=N FAIL=N — parse with awk/grep:
line="$(grep -E '^  OK=[0-9]+  WARN=[0-9]+  FAIL=[0-9]+$' <<<"$out")"
f="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^FAIL=/) {sub("FAIL=","",$i); print $i}}' <<<"$line")"
[[ "$f" == "0" ]] && echo "OK parseable summary (FAIL=$f, rc 0 expected)" || echo "OK parseable (FAIL=$f, rc 1 expected)"
# verify every FAIL line names its section (no naked FAIL):
grep -c 'FAIL' <<<"$out"   # informational
rm -rf "$STATE"
# Expected: the summary is a single parseable line; FAIL lines carry context (deps/bin/fs/master).
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully (Level 2 is the strict gate).
- [ ] `bash -n lib/pool.sh` → exit 0.
- [ ] `shellcheck -s bash lib/pool.sh` → ZERO warnings (whole file).
- [ ] `lib/pool.sh` diff is append-only (banner + `pool_admin_doctor()`); 0 deletions.

### Feature Validation

- [ ] All success criteria from "What" section met.
- [ ] Prints all six section headers + `[summary]` with `OK=N WARN=N FAIL=N` + verdict.
- [ ] Healthy system → `Healthy.` + rc 0; any FAIL → `Problems found.` + rc 1.
- [ ] Dep check: required present → OK; absent → MISSING (FAIL); notify-send absent →
      `MISSING (optional)` (NOT counted).
- [ ] Chrome check uses `$POOL_CHROME_BIN` (name-or-path), not the literal name.
- [ ] FS: btrfs → OK; non-btrfs+slow-copy → WARN; non-btrfs+no-slow-copy → FAIL.
- [ ] Master: present+non-empty → OK; else FAIL.
- [ ] Reconcile: live lane → OK; dead chrome → LEAK; port dead → DISCONNECTED; no dir
      → LEAK(no dir); provisional (port=0) → ONE PROVISIONAL WARN (checks skipped).
- [ ] Orphan dir (no lease) → ORPHAN DIR WARN; leased dir → not flagged.
- [ ] WARN-only → rc 0; any FAIL → rc 1.
- [ ] NEVER `pool_die` in the body; precondition may.

### Code Quality Validation

- [ ] Follows the LANDED admin-function shape (locals up front, SC2155, precondition,
      banner, Mode A header, self-contained, called by name from the dispatcher).
- [ ] File placement matches the desired codebase tree (append-only to lib/pool.sh).
- [ ] Anti-patterns avoided (see below).
- [ ] Composes the LANDED helpers; REPLICATES (does not call) pool_check_btrfs/master.
- [ ] No new globals/env-vars/files.

### Documentation & Deployment

- [ ] Function header doc-comment documents every check + the output contract (Mode A).
- [ ] Suggested `--help` line provided for the dispatcher (M7.T5.S1) to wire.
- [ ] No new environment variables (doctor reads only existing `POOL_*` globals).

---

## Anti-Patterns to Avoid

- ❌ **Don't call `pool_check_btrfs` / `pool_check_master`.** They `pool_die` (exit 1,
  uncatchable) on the very failures doctor must REPORT. Replicate their `findmnt -T` /
  `-d + ls -A` primitives NON-fatally with `if/else`. (design-decisions D3 — THE gotcha.)
- ❌ **Don't call `command -v` / `pool_lease_read` / `pool_lease_exists` / `curl` bare.**
  Each returns non-zero on a legitimate "not found" → ABORTS under `set -e`. Always inside
  `if`/`if !` (or `|| true` for findmnt).
- ❌ **Don't use a bare `(( expr ))` statement.** It returns 1 when the value is 0 →
  FATAL. Keep `(( ))` inside `if`/`&&`/`||`; use `$(( ))` for arithmetic.
- ❌ **Don't `local x="$(…)"` (SC2155).** Declare then assign (literal `local ok=0` is fine).
- ❌ **Don't check the literal "google-chrome-stable".** Check `$POOL_CHROME_BIN`
  (name-or-path) — a chromium override would FALSE-alarm otherwise. (D6.)
- ❌ **Don't flag a provisional lease (port=0) with the three checks.** It would spuriously
  triple-flag LEAK+DISCONNECTED. Emit ONE "PROVISIONAL" WARN and `continue`. (D9.)
- ❌ **Don't make WARNs affect the exit code.** Only FAIL (blocking infra) exits non-zero;
  lane/dir cruft is recoverable via reap/release. (D4.)
- ❌ **Don't count a missing notify-send as a FAIL.** It is OPTIONAL (PRD §2.16). (D5.)
- ❌ **Don't forget `findmnt -T`.** A bare `findmnt "$dir"` matches SOURCE not the mount
  tree and exits 1 even on btrfs. (facts §3.)
- ❌ **Don't `pool_die` in the body.** doctor REPORTS; it does not die. (D13.)
- ❌ **Don't hardcode the append line number.** Detect the live EOF via `tail` (release
  landed mid-research; the EOF moves). (D1.)
