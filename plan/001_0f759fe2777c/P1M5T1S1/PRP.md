# PRP — P1.M5.T1.S1: flock critical section — reap-stale + reuse-orphan + choose-N + provisional claim

---

## Goal

**Feature Goal**: Implement **`pool_acquire_locked()`** — the flock-guarded **acquire
critical section** for the agent-browser-pool: the single function that, while holding an
exclusive `flock` on `$POOL_LOCK_FILE`, performs PRD §2.4 step 3 in its entirety:
**REAP-STALE** (3a) → **REUSE-ORPHAN** (3b) → **CHOOSE-N** (3c) → **CLAIM** (3d), then
releases the lock. Chrome **launch/copy/connect** (step 3e–3j) is explicitly **OUT OF SCOPE**
(it is M5.T1.S2, the *post-lock* boot — key_findings FINDING 2: keep the flock section short
so concurrent acquires boot in parallel). This function is the literal realization of the
item CONTRACT (steps a–e) + PRD §2.4 step 3a–3d + §2.9 (return 1 ⇒ exhaustion) + §2.10 (lazy
reaper on acquire) + §2.19 (short flock; atomic lease writes).

To make `pool_acquire_locked()` **self-contained and one-pass implementable** despite its
hard dependency on P1.M5.T2.S1 (release) — which is only **Planned**, NOT landed — this task
ALSO defines the **private release kernel `_pool_release_lane_internals(LANE)`** ("kill pgroup
+ rm dir + delete lease", the "release internals" the item CONTRACT step 3a names) plus two
small private helpers (`_pool_acquire_critical_section`, `_pool_adopt_lane`). M5.T2.S1's public
`pool_release_lane()` will **compose** `_pool_release_lane_internals` rather than duplicate it
(documented as a contract below). This unblocks the circular acquire↔release dependency.

**Deliverable**: Four functions appended to `lib/pool.sh` under a new banner (after the
P1.M4.T3.S1 functions `pool_daemon_connect`/`pool_daemon_connected`/`pool_chrome_kill`, which
land at EOF from the parallel task). Pure addition: no edits to any existing function, no new
env-vars, no new files. The public entry point is `pool_acquire_locked()` (no args; reads the
`POOL_OWNER_*` globals set by `pool_owner_resolve`); the other three are private (`_`-prefixed)
internal helpers.

1. **`pool_acquire_locked()`** — acquire an exclusive `flock` on `$POOL_LOCK_FILE`, run the
   critical-section body, release on return. Echoes the claimed/adopted lane **N** on success
   (return 0); echoes nothing + return 1 when no free/reusable lane exists (triggers M5.T4
   exhaustion). CONTRACT-mandated flock pattern: `( flock 9; _pool_acquire_critical_section )
   9>"$POOL_LOCK_FILE"` (HOST-VERIFIED semantics — see research §1).
2. **`_pool_acquire_critical_section()`** — the body (runs inside the subshell holding fd 9):
   (a) REAP-STALE: for each lane where `pool_lane_is_stale` returns 0 (stale), check
   reuse-orphan; else `_pool_release_lane_internals`. (b) REUSE-ORPHAN: a stale lane whose
   Chrome is responsive (`pool_daemon_connected` == 0) → adopt (reassign owner to current,
   ensure connected, skip copy) → echo N + return 0. (c) CHOOSE-N: `pool_find_free_lane` → N.
   (d) CLAIM: `pool_lease_write` a provisional lease (`port=0`, `chrome_pid=0`,
   `chrome_pgid=0`, `connected=false`, `owner` = current). Echo N + return 0. Fall-through
   (no free lane) → return 1.
3. **`_pool_release_lane_internals(LANE)`** — the release kernel: read the lease →
   `pool_chrome_kill(chrome_pid, chrome_pgid)` → `rm -rf` the ephemeral dir (reconstructed as
   `$POOL_EPHEMERAL_ROOT/$LANE` AND guarded) → `rm` the lease file. **Idempotent + non-fatal**
   (return 0; every kill/rm `2>/dev/null || true`; a missing/corrupt lease is a clean no-op).
   This is what step 3a calls and what M5.T2.S1's public `pool_release_lane` composes.
4. **`_pool_adopt_lane(LANE)`** — the reuse-orphan adoption: a targeted jq mutation that
   rewrites the lease's `.owner` sub-object to the current `POOL_OWNER_*` triple + sets
   `.connected=true` + stamps `.last_seen_at`, published atomically via `_pool_atomic_write`.
   (`pool_lease_update` is top-level-only and cannot touch nested `owner.*` — research §4.)
   Then `pool_daemon_connect(session, port)` to ensure the daemon binding is current.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
  pool_owner_resolve`, calling `pool_acquire_locked` in an empty pool (no leases, no dirs)
  echoes a lane number (the lowest, `1`) + returns **0**, and writes a **provisional** lease
  `lanes/1.json` with `port:0, chrome_pid:0, chrome_pgid:0, connected:false` and
  `owner:{pid:POOL_OWNER_PID,…}`. No `pool_die`; the caller survives under `set -e`.
- Calling `pool_acquire_locked` a second time from a **distinct simulated owner** (different
  `AGENT_BROWSER_POOL_OWNER_PID`) while the first owner's lease is still LIVE returns the next
  lane (`2`) + a provisional `lanes/2.json` — i.e. two live owners get two distinct lanes
  (the mutual-exclusion core of the pool).
- Calling `pool_acquire_locked` when a lane has a **stale** lease (owner PID dead/recycled)
  AND no live Chrome on its port → the stale lane is **reaped** (Chrome killed via
  `pool_chrome_kill`, ephemeral dir removed, lease file deleted) and that lane number is
  **reused** for the new provisional claim.
- Calling `pool_acquire_locked` when a lane has a **stale** lease BUT a **responsive Chrome**
  (`pool_daemon_connected` == 0) → the lane is **adopted** (owner rewritten to current,
  `connected:true`, daemon re-bound) and returned WITHOUT writing a provisional lease / WITHOUT
  a copy. (reuse-orphan, PRD §2.4 step 3b / IQ4.)
- Calling `pool_acquire_locked` when **all** lanes are held by **live** owners → echoes
  nothing + returns **1** (exhaustion signal for M5.T4). No lease written.
- **Short critical section verified**: the flock is released BEFORE any Chrome launch (none
  happens inside this function — only signals, `rm`, jq, `mv`, and an optional attach). Two
  concurrent `pool_acquire_locked` calls serialize ONLY on the scan+claim, not on any boot.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M4.T3.S1) unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user or operator directly. Its sole
consumer is the **acquire orchestration** (PRD §2.4 step 3) that the wrapper shim (M6.T3.S1)
and the admin/exhaustion flows invoke:

- **M5.T1.S2** (acquire **post-lock boot**) — the IMMEDIATE consumer. Calls
  `pool_acquire_locked`; on rc 0 it reads the returned lane's lease: `port==0` (provisional)
  ⇒ run the boot (copy→port→launch→connect→update); `port>0 && connected` (adopted) ⇒ skip
  the boot, just `ensure_connected`. On rc 1 ⇒ defer to **M5.T4** exhaustion.
- **M5.T4** (pool exhaustion) — calls `pool_acquire_locked` inside its block-with-timeout
  loop; rc 1 each iteration ⇒ keep polling (re-running REAP-STALE each time via the same call).
- **M6.T3.S1** (wrapper lifecycle step 3) — the top-level driver: `find_my_lease` (step 2)
  misses ⇒ call `pool_acquire_locked`.

**Use Case**: Every `agent-browser` DRIVING invocation with no reusable lease enters acquire →
`pool_acquire_locked` claims/adopts a lane under the short lock → the boot/ensure happens
outside the lock → exec with `AGENT_BROWSER_SESSION=abpool-<N>`. This function is the
mutual-exclusion + reuse spine of that flow.

**Pain Points Addressed**:
- **Concurrent agents must get distinct lanes with no collision** — the flock serializes the
  scan+claim so two simultaneous acquires never pick the same lane number. FINDING 2: the lock
  is held ONLY for the fast scan+claim, never the ~10 s Chrome boot, so concurrency stays high.
- **Crashed agents leak Chrome+dir+lease** — REAP-STALE (step 3a) reclaims them lazily on the
  very next acquire (PRD §2.10, no background daemon). The release kernel centralizes the
  kill+rm+delete so acquire, release (M5.T2.S1), and reap (M5.T3.S1) share one correct path.
- **A responsive orphan Chrome should be reused, not killed+relaunched** — REUSE-ORPHAN
  (step 3b / IQ4) adopts a still-running Chrome whose owner died, skipping the expensive copy
  + launch. This is the single biggest latency win in the pool.
- **Exhaustion must be detectable, not an infinite hang** — rc 1 from `pool_acquire_locked`
  is the clean signal that drives M5.T4's block/force-reap/alert.

## Why

- **This IS PRD §2.4 step 3 (ACQUIRE).** Steps 3a (REAP-STALE), 3b (REUSE-ORPHAN), 3c
  (CHOOSE-N), 3d (CLAIM) are this function. Without it the pool can neither allocate lanes
  safely under concurrency nor reclaim stale ones nor reuse orphans.
- **The short-flock invariant (FINDING 2 / PRD §2.19) is enforced HERE.** Holding the lock
  only for scan+claim (and NOT the Chrome boot) is what lets N agents boot N lanes in parallel.
- **The release kernel unblocks the plan.** The item CONTRACT says release "must exist first",
  but M5.T2.S1 is only Planned. Defining `_pool_release_lane_internals` here means acquire is
  one-pass implementable AND M5.T2.S1 composes it (no duplication, one correct teardown path).
- **reuse-orphan is the IQ4 differentiator.** Detecting a responsive-but-orphaned Chrome and
  adopting it (instead of killing + relaunching) is the feature that keeps the pool fast under
  agent churn.

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| empty pool, owner resolved | `pool_acquire_locked` | **rc 0**, echoes `1`; `lanes/1.json` written provisional (`port:0,connected:false`) |
| 2nd live owner (distinct PID), lane 1 held live | `pool_acquire_locked` | **rc 0**, echoes `2`; `lanes/2.json` provisional |
| stale lease on lane 3, Chrome DEAD on its port | `pool_acquire_locked` | **rc 0**; lane 3 reaped (Chrome killed, `active/3` removed, `lanes/3.json` deleted); lowest free N claimed provisional |
| stale lease on lane 3, Chrome RESPONSIVE (`pool_daemon_connected`==0) | `pool_acquire_locked` | **rc 0**, echoes `3`; lane 3 ADOPTED (`owner`→current, `connected:true`, daemon re-bound); NO copy/launch; NO provisional claim of another lane |
| all lanes held by LIVE owners | `pool_acquire_locked` | **rc 1**, no output, no lease written (exhaustion → M5.T4) |
| `pool_owner_resolve` set POOL_OWNER_PID=0 (no pi ancestor / passthrough) | `pool_acquire_locked` | **rc 1** (defensive — a passthrough owner must not claim a lane; the wrapper gates passthrough BEFORE acquire in M6) |
| concurrent calls from 2 distinct owners | both `pool_acquire_locked` | serialized on flock; each gets a distinct lane N (mutual exclusion) |
| `_pool_release_lane_internals 3` on a live-orphan-free stale lane | helper | **rc 0**; Chrome pgroup killed (0 orphans), `active/3` rm'd, `lanes/3.json` deleted |
| `_pool_release_lane_internals 3` on an already-released lane (no lease) | helper | **rc 0** (idempotent no-op; `pool_lease_read` rc 1 ⇒ return 0) |
| `_pool_release_lane_internals 3` on a provisional lease (`chrome_pid:0`) | helper | **rc 0**; `pool_chrome_kill 0 0` is a safe no-op; dir + lease still removed |

**Hard invariants** (every row):
- **The flock is held ONLY for scan + reap + reuse + choose + claim.** No `setsid google-chrome`,
  no `cp -a`, no CDP wait inside the lock. (FINDING 2 / PRD §2.19.) Verified: the only
  subprocess that MAY run inside is `pool_daemon_connect` (an *attach* to a running Chrome, ~ms)
  in the rare adopt path; the common path has zero subprocess spawns.
- **The flock auto-releases on return** (including `pool_die`/`exit`/SIGKILL) — the
  `( flock 9; body ) 9>file` subshell binds the lock to fd 9, which the kernel closes on
  subshell exit. NO trap is needed for the lock. (research §1.2.)
- **`pool_acquire_locked` is NON-FATAL on the "no free lane" path** (rc 1, never `pool_die`) —
  that is the exhaustion signal. A `pool_die` (fatal) is reserved for genuine corruption
  (e.g. a lease write that fails atomically) and propagates through the subshell's exit.
- **`_pool_release_lane_internals` is NON-FATAL + idempotent** (rc 0 always): every kill/rm is
  `2>/dev/null || true`; a missing/corrupt lease is a clean no-op. It runs inside the reap loop
  over many lanes — one already-released lane must NEVER abort the pool under `set -e`.
- **Provisional claim fields are exactly `port:0, chrome_pid:0, chrome_pgid:0, connected:false`**
  (PRD §2.4 step 3d). The post-lock boot (M5.T1.S2) fills in the real values. `pool_lease_write`
  requires `connected` be the literal string `"false"`.
- **The owner written into the lease is the CURRENT claimer** (`POOL_OWNER_PID/COMM/STARTTIME/CWD`
  from `pool_owner_resolve`) — never a stale/previous owner.
- **Adoption rewrites the WHOLE `.owner` sub-object + `.connected:true` + `.last_seen_at`** via a
  targeted jq mutation (pool_lease_update cannot do nested `owner.*` — research §4). Atomic via
  `_pool_atomic_write`.
- **`rm -rf` is GUARDED**: `_pool_release_lane_internals` reconstructs the ephemeral dir as
  `$POOL_EPHEMERAL_ROOT/$lane` and ALSO guards it is non-empty + under `$POOL_EPHEMERAL_ROOT/`
  before any `rm -rf` (defense-in-depth against a corrupt/hostile lease path). NEVER `rm -rf` an
  arbitrary string read from a lease.

### Success Criteria

- [ ] `pool_acquire_locked`, `_pool_acquire_critical_section`, `_pool_release_lane_internals`,
      `_pool_adopt_lane` defined in `lib/pool.sh` under a
      `# Acquire — flock critical section (P1.M5.T1.S1)` banner, appended after the P1.M4.T3.S1
      functions (`pool_chrome_kill` et al.) at EOF. Callable after `source lib/pool.sh` +
      `pool_config_init`.
- [ ] Empty-pool acquire echoes `1` + rc 0 + writes provisional `lanes/1.json`
      (`port:0,chrome_pid:0,chrome_pgid:0,connected:false`, owner = current).
- [ ] Two distinct simulated owners (via `AGENT_BROWSER_POOL_OWNER_PID` test hook) acquire two
      distinct lanes (`1` and `2`) with no collision (mutual exclusion under flock).
- [ ] A stale lease with a DEAD Chrome is reaped (Chrome pgroup killed 0-orphans, ephemeral dir
      removed, lease deleted) and the freed lane number is reused for the provisional claim.
- [ ] A stale lease with a RESPONSIVE Chrome (`pool_daemon_connected` == 0) is ADOPTED: lease
      `.owner` rewritten to current, `.connected:true`, daemon re-bound; the lane is returned
      with NO copy/launch and NO second lane claimed.
- [ ] All-live-owners ⇒ rc 1, no output, no lease written.
- [ ] `_pool_release_lane_internals` is idempotent (re-call on a released lane ⇒ rc 0 no-op) and
      safe on a provisional lease (`chrome_pid:0`).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1–M4.T3.S1) unchanged and callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **cross-dependency resolution**
(release kernel defined here because M5.T2.S1 is not landed — research §0); the **flock +
`set -euo pipefail` semantics** (HOST-VERIFIED: blocking `flock 9` returns 0; lock auto-released
on subshell exit incl. SIGKILL; parent functions ARE inherited by subshells; **the
`local var=$(...)` errexit-masking gotcha** — research §1); the **short-critical-section
budget** (kill/rm-reflink/jq/mv/attach = fast; Chrome launch = forbidden inside — research §2);
the **exact composed-function contracts** (pool_lane_is_stale TRI-STATE 0/1/2; pool_lease_write
11-arg order + `connected` must be literal "true"/"false"; pool_lease_update is TOP-LEVEL only
⇒ adoption needs a jq mutation; pool_chrome_kill idempotent + handles 0/0; pool_daemon_connect/
connected from P1.M4.T3.S1 — research §3); the **lease schema** (PRD §2.8); the **rm-rf safety
guard** (reconstruct + prefix-guard); the **output contract** (echo N + rc 0 / rc 1; lease state
tells the caller provisional-vs-adopted); and copy-pasteable, host-verified validation commands
including a real concurrency test.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3a (REAP-STALE: kill pgroup, rm dir, delete lease), 3b (REUSE-ORPHAN: adopt a
        responsive Chrome with a dead owner — reassign owner, ensure connected, skip the copy),
        3c (CHOOSE-N: lowest N≥1 with no dir AND no lease), 3d (CLAIM: write lanes/<N>.json with
        port=0, chrome_pid=0, session=abpool-<N>); §2.8 (lease schema); §2.9 (exhaustion — the
        rc-1 path feeds M5.T4); §2.10 (reaper is LAZY, on acquire — step 3a IS the reaper);
        §2.19 (keep the flock section SHORT: claim under lock, boot AFTER; atomic lease writes
        via tmp+mv).
  pattern: step 3a-d IS pool_acquire_locked; §2.9 rc-1 IS the exhaustion signal.
  gotcha: §2.4 step 3b "ensure connected" must NOT use the broken `get cdp-url` (see P1.M4.T3.S1
        research §2 — it auto-launches strays). Use pool_daemon_connected (read-only) for the
        responsiveness check + pool_daemon_connect (attach) for the re-bind.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (THE short-flock rule — claim under lock, launch Chrome AFTER releasing so
        concurrent acquires boot in parallel; the EXACT pattern `( flock 9; ... ) 9>"$LOCK_FILE"`);
        FINDING 6 (setsid → pgid==pid; `kill -- -<pgid>` with the `--`; teardown — used by
        pool_chrome_kill which _pool_release_lane_internals composes); FINDING 3 (no bare ~ —
        POOL_EPHEMERAL_ROOT/POOL_LANES_DIR/POOL_LOCK_FILE are already absolute via pool_config_init);
        FINDING 7 (atomic lease write: tmp in SAME dir + mv — _pool_atomic_write does this).
  pattern: FINDING 2 IS the flock idiom (verbatim); FINDING 7 IS the publish mechanism.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — POOL_LOCK_FILE=acquire.lock, POOL_LANES_DIR=lanes/, chrome-<N>.log);
        §2 (flock confirmed present at /usr/bin/flock; btrfs confirmed for the ephemeral root →
        rm -rf of a reflink dir is fast).

- file: plan/001_0f759fe2777c/P1M4T3S1/PRP.md   # PARALLEL CONTRACT — the connect/verify/kill primitives
  why: THIS task's pool_acquire_locked + _pool_release_lane_internals + _pool_adopt_lane COMPOSE
        the three functions P1.M4.T3.S1 appends at EOF: pool_daemon_connect (attach, rc 0 live /
        1 dead), pool_daemon_connected (SIDE-EFFECT-FREE "is this lane drivable?" — rc 0 iff
        session known AND chrome alive; NEVER launches; the RESPONSIVENESS probe for reuse-orphan),
        pool_chrome_kill (idempotent whole-tree teardown, rc 0 always, handles 0/0). The §2
        "get cdp-url AUTO-LAUNCH TRAP" in that PRP's research is WHY reuse-orphan MUST use
        pool_daemon_connected (not get cdp-url).
  pattern: reuse-orphan responsiveness == `pool_daemon_connected "$session" "$port"`; re-bind ==
        `pool_daemon_connect "$session" "$port"`; reap teardown == `pool_chrome_kill "$cpid" "$cpgid"`.
  gotcha: treat P1.M4.T3.S1 as a CONTRACT — it WILL be at EOF when this task runs. Append AFTER
        pool_chrome_kill. If those three functions are MISSING, STOP (this task depends on them).

# This task's own research (HOST-VERIFIED flock semantics + composed-contract table)
- file: plan/001_0f759fe2777c/P1M5T1S1/research/acquire-flock-critical-section.md
  why: THE evidence base. §0 (the cross-dependency resolution — release kernel defined here);
        §1 (flock + set -e semantics: blocking flock 9 returns 0; auto-release on subshell exit
        incl. SIGKILL; parent functions inherited by subshells; THE `local var=$(...)` MASKING
        GOTCHA — every capture must be split); §2 (short-section budget — what's safe inside the
        lock); §3 (composed-function contract TABLE — the exact rc conventions + signatures);
        §4 (the reuse-orphan owner-reassignment — why pool_lease_update can't + the jq-mutation
        design); §5 (output contract); §6 (rm -rf safety guard + idempotency).
  pattern: §1 is the flock idiom; §3 is the contract table; §4 is the adoption jq.
  gotcha: §1.5 (local var=$(...)) + §6 (rm -rf guard) are the two highest-impact gotchas.

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init (M1.T1.S2 — LANDED @126)
  why: freezes POOL_LOCK_FILE, POOL_LANES_DIR, POOL_EPHEMERAL_ROOT (all ABSOLUTE) — read by this task.
        CONTRACT: MUTABLE declare -g globals, re-runnable.
- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md   # pool_state_init (M1.T1.S3 — LANDED)
  why: creates POOL_LANES_DIR + touches POOL_LOCK_FILE (idempotent). pool_acquire_locked calls it
        before opening fd 9 so the redirect `9>"$POOL_LOCK_FILE"` cannot fail on a missing parent.
- file: plan/001_0f759fe2777c/P1M2T1.S1/PRP.md + P1M2T2S1  # pool_owner_resolve / pool_owner_alive (M2 — LANDED)
  why: pool_owner_resolve sets POOL_OWNER_PID/COMM/STARTTIME/CWD (the claimer's identity written
        into every lease + the test-hook AGENT_BROWSER_POOL_OWNER_PID override for the concurrency
        test). pool_lane_is_stale composes pool_owner_alive internally — this task does not call it.
- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md   # pool_lease_write / pool_lease_update / _pool_atomic_write (M3.T1.S1 — LANDED)
  why: pool_lease_write (the provisional CLAIM) takes 11 args; `connected` MUST be literal
        "true"/"false". pool_lease_update is TOP-LEVEL FIELD ONLY (CANNOT update nested owner.*)
        — that is why _pool_adopt_lane uses a direct jq mutation + _pool_atomic_write instead.
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_read / pool_lease_field (M3.T1.S2 — LANDED)
  why: _pool_release_lane_internals reads chrome_pid/chrome_pgid/ephemeral_dir/port/session via
        pool_lease_read + ONE jq (the pool_lane_is_stale "ONE jq fork" pattern). Both return 1 on
        missing/corrupt — caller MUST guard under set -e.
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list / pool_lease_find_mine (M3.T2.S1 — LANDED)
  why: pool_lanes_list enumerates lane numbers (sorted -n, always rc 0) — the reap loop iterator.
- file: plan/001_0f759fe2777c/P1M3T2S2/PRP.md   # pool_find_free_lane (M3.T2.S2 — LANDED)
  why: CHOOSE-N. Always echoes N + returns 0 → a bare `N="$(pool_find_free_lane)"` is set -e SAFE.
        Checks BOTH no-dir AND no-lease (catches the provisional-claim window inside the same flock).
- file: plan/001_0f759fe2777c/P1M3T2S3/PRP.md   # pool_lane_is_stale (M3.T2.S3 — LANDED)
  why: TRI-STATE verdict (0=stale / 1=live / 2=no-lease). The reap loop MUST handle all three.
        CRITICAL: rc is INVERTED vs pool_owner_alive — rc 0 means "yes stale" (caller reaps).

# External authoritative docs (for the WHY; flock/bash behavior is HOST-VERIFIED in research §1)
- url: https://man7.org/linux/man-pages/man1/flock.1.html
  why: the `( flock 9; … ) 9>file` idiom is the man-page-recommended shell form; blocking `flock 9`
        returns 0 on acquire; EXIT STATUS 0/1/2.
  section: SYNOPSIS (third form) + DESCRIPTION + EXIT STATUS.
- url: https://man7.org/linux/man-pages/man2/flock.2.html
  why: flock(2) locks bind to the OPEN FILE DESCRIPTION → auto-released when the last fd closes
        (subshell exit / SIGKILL). Why the subshell idiom needs NO trap.
  section: DESCRIPTION + NOTES (open file description binding).
- url: https://www.gnu.org/software/bash/manual/bash.html#Command-Execution-Environment
  why: `( ... )` is a subshell = a FORK → inherits functions, variables, shell options (-e/-u/
        pipefail). Confirms _pool_acquire_critical_section is callable inside the flock subshell.
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: THE `set -e` surprises reference. `local var=$(...)` masks errexit (local returns 0) →
        EVERY capture in this task must be split into `local x; x=$(...)`.
```

### Current Codebase tree

After **M1–M4.T2.S2** have landed AND **M4.T3.S1** (`pool_daemon_connect` + `pool_daemon_connected`
+ `pool_chrome_kill`, the PARALLEL contract) has landed at EOF, `lib/pool.sh` ends with
`pool_chrome_kill` as the final function (~line 1700):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M4.T3.S1) with pool_chrome_kill at EOF.
│                                         #   Banner order at EOF:
│                                         #   ... pool_chrome_launch + pool_wait_cdp (M4.T2.S2)
│                                         #   # Lane lifecycle — daemon connect, verify & teardown (M4.T3.S1)
│                                         #   pool_daemon_connect / pool_daemon_connected / pool_chrome_kill  ← current EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M4T3S1/PRP.md
    └── P1M5T1S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/acquire-flock-critical-section.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND four functions under a new banner AFTER pool_chrome_kill (EOF):
                  #   # Acquire — flock critical section (P1.M5.T1.S1)
                  #   _pool_release_lane_internals(lane):
                  #       read lease → pool_chrome_kill(cpid,cpgid)
                  #       → rm -rf $POOL_EPHEMERAL_ROOT/$lane (guarded) → rm lease file.
                  #       Idempotent + non-fatal (rc 0). The release kernel (M5.T2.S1 composes it).
                  #   _pool_adopt_lane(lane):   # reuse-orphan adoption
                  #       jq mutate .owner={current} | .connected=true | .last_seen_at=now
                  #       → _pool_atomic_write → pool_daemon_connect(session,port) (re-bind).
                  #   _pool_acquire_critical_section():   # the flock body (function; inherits globals)
                  #       REAP-STALE: for n in pool_lanes_list; pool_lane_is_stale==0 (stale)
                  #         → if pool_daemon_connected(session,port)==0: _pool_adopt_lane(n); echo n; return 0
                  #           else _pool_release_lane_internals(n)
                  #       CHOOSE-N: N=pool_find_free_lane
                  #       CLAIM: pool_lease_write(N, ephemeral_dir, 0, abpool-N, owner..., 0, 0, "false")
                  #       echo N; return 0   |   fall-through → return 1 (exhaustion)
                  #   pool_acquire_locked():   # PUBLIC — the flock wrapper
                  #       pool_state_init   # ensure lock file + lanes dir exist
                  #       ( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"
                  #   (NO changes to any existing function — esp. NOT pool_chrome_kill / pool_wait_cdp)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**acquire critical section** — the flock-guarded scan/reap/reuse/choose/claim that is PRD §2.4
step 3a–3d — plus the private release kernel + adoption helper that future tasks (M5.T2.S1,
M5.T3.S1/S2) compose. It reads `POOL_LOCK_FILE`, `POOL_LANES_DIR`, `POOL_EPHEMERAL_ROOT`, and
the `POOL_OWNER_*` identity globals; it writes only lease files + (on reap) removes ephemeral
dirs + kills Chrome pgroups (via the already-landed primitives).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (THE `local var=$(...)` ERREXIT-MASKING GOTCHA — research §1.5 / BashFAQ 105):
#   `local x="$(...)"` — `local` is a command that ALWAYS returns 0, so `set -e` does NOT fire
#   even if the command-substitution exits non-zero. EVERY capture in this task MUST be split:
#       local x; x="$(...)"     # ← errexit now propagates
#   Applies to: the CALLER's `local N; N="$(pool_acquire_locked)"` AND every internal
#   `port="$(pool_lease_field ...)"`, `json="$(pool_lease_read ...)"`, etc. HOST-VERIFIED.

# CRITICAL (flock is held ONLY for scan+reap+reuse+choose+claim — FINDING 2 / PRD §2.19):
#   NO `setsid google-chrome`, NO `cp -a`, NO CDP wait inside the lock — those are S2 (post-lock
#   boot). Inside the lock only: kill (signals, µs), rm -rf reflink (metadata, ms), jq+mv (µs-ms),
#   pool_find_free_lane (numeric, µs), and the RARE pool_daemon_connect ATTACH (~ms, adopt path
#   only). A Chrome launch (~10 s) inside the lock would SERIALIZE all concurrent acquires.

# CRITICAL (the lock auto-releases on subshell exit incl. SIGKILL — research §1.2):
#   `( flock 9; body ) 9>file` binds the lock to fd 9; the kernel closes fds on process death →
#   lock freed. NO trap is needed for the lock. A `pool_die` (exit 1) inside the body exits the
#   subshell → lock released → status 1 propagates to the caller under set -e.

# CRITICAL (pool_lane_is_stale is TRI-STATE + INVERTED — research §3):
#   0 = STALE (reap it)   1 = LIVE (keep)   2 = NO LEASE (skip).
#   The reap loop MUST capture all three: `if pool_lane_is_stale "$n"; then <stale logic>; fi`
#   handles rc 0 (stale); rc 1/2 fall through. A BARE `pool_lane_is_stale "$n"` ABORTS the caller
#   under set -e when rc is 1 or 2. (rc 0 is "true" in shell convention = "yes, stale".)

# CRITICAL (pool_lease_update CANNOT update nested owner.* — research §4 / M3.T1.S1 docstring):
#   "FIELD is TOP-LEVEL only; dotted owner.* updates are NOT supported (owner is written once at
#   acquire, never mutated)." So reuse-orphan adoption (_pool_adopt_lane) uses a DIRECT jq mutation
#   of .owner + .connected + .last_seen_at + _pool_atomic_write — NOT pool_lease_update.

# CRITICAL (rm -rf SAFETY GUARD — research §6):
#   _pool_release_lane_internals does `rm -rf` on the ephemeral dir. The path is RECONSTRUCTED as
#   "$POOL_EPHEMERAL_ROOT/$lane" (NOT trusted from the lease) AND guarded `[[ -n && == "$POOL_EPHEMERAL_ROOT"/* ]]`
#   before any rm. NEVER `rm -rf` an arbitrary string read from a lease (corrupt/hostile path).

# GOTCHA (parent functions ARE inherited by `( ... )` subshells — research §1.3):
#   `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` works — the body function +
#   all globals (POOL_OWNER_*, POOL_LANES_DIR, …) are available inside the subshell. Variables/
#   return/exit changes do NOT propagate back; stdout + exit code DO.

# GOTCHA (`return` is fine inside the body FUNCTION — research §1.4):
#   `_pool_acquire_critical_section` (a function) may `return 0`/`return 1`; that becomes the
#   subshell's exit status (it is the last command). Do NOT use bare `return` directly in the
#   `( )` body (only inside a function) — that is an error.

# GOTCHA (provisional claim fields are EXACTLY 0/0/0/false — PRD §2.4 step 3d):
#   pool_lease_write(N, "$ephemeral_dir", 0, "abpool-N", "$POOL_OWNER_PID", "$POOL_OWNER_COMM",
#       "$POOL_OWNER_STARTTIME", "$POOL_OWNER_CWD", 0, 0, "false"). `connected` MUST be the literal
#   string "false" (pool_lease_write validates ∈ {"true","false"}). port/chrome_pid/chrome_pgid are
#   --argjson NUMBERs (0 is valid).

# GOTCHA (POOL_OWNER_PID==0 ⇒ no claim — defensive):
#   pool_owner_resolve sets POOL_OWNER_PID="0" in passthrough mode (no pi ancestor). A lane claimed
#   by owner pid 0 would be reaped by every other acquirer (pool_owner_alive(0,…) ⇒ rc 1 ⇒ stale).
#   pool_acquire_locked MUST refuse to claim when POOL_OWNER_PID is 0/unset (return 1) — the
#   wrapper gates passthrough BEFORE acquire in M6, but this is defense-in-depth.

# GOTCHA (the ephemeral_dir in the provisional lease — use $POOL_EPHEMERAL_ROOT/$N):
#   The lease field `ephemeral_dir` MUST be the ABSOLUTE path "$POOL_EPHEMERAL_ROOT/$N" so the
#   post-lock boot (S2) knows where to cp the master + launch Chrome. NEVER a relative path / bare ~.

# GOTCHA (reuse-orphan must use pool_daemon_connected, NOT get cdp-url — P1.M4.T3.S1 research §2):
#   `get cdp-url` AUTO-LAUNCHES a stray Chrome on a dead-chrome session (always rc 0). The
#   responsiveness probe for reuse-orphan is pool_daemon_connected(session, port) (read-only,
#   never launches). The re-bind is pool_daemon_connect(session, port) (attach). See P1.M4.T3.S1.

# GOTCHA (all release operations idempotent + non-fatal — _pool_release_lane_internals rc 0 always):
#   runs inside the reap loop over many lanes. every kill/rm is `2>/dev/null || true`. A
#   missing/corrupt lease (pool_lease_read rc 1) ⇒ return 0 (nothing to release). pool_chrome_kill
#   already self-guards (handles 0/0). One already-released lane must NEVER abort the pool.

# GOTCHA (naming): pool_acquire_locked (PUBLIC, no `_`) + _pool_acquire_critical_section +
#   _pool_release_lane_internals + _pool_adopt_lane (PRIVATE, `_`-prefixed). The item CONTRACT
#   names pool_acquire_locked exactly; the private helpers follow the codebase `_pool_*` convention.

# GOTCHA (placement): APPEND at EOF (after pool_chrome_kill, the M4.T3.S1 deliverable). Do NOT
#   touch any existing function.

# GOTCHA (scope): the flock critical section ONLY. Do NOT: launch/copy/connect Chrome (S2);
#   implement the full exhaustion wait-loop (M5.T4 — this function only RETURNS 1 to signal it);
#   implement the public pool_release_lane (M5.T2.S1 — composes _pool_release_lane_internals);
#   implement standalone pool_reap_stale / pool_reuse_orphan (M5.T3.1/S2 — they share the kernel);
#   or intercept the wrapper (M6).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars**. It reads the lease
schema (PRD §2.8, frozen by M3.T1.S1) and writes provisional + adopted leases via the LANDED
`pool_lease_write` / `_pool_atomic_write`. It exports **NO new globals** (reads
`POOL_LOCK_FILE`, `POOL_LANES_DIR`, `POOL_EPHEMERAL_ROOT`, `POOL_OWNER_PID/COMM/STARTTIME/CWD`).

Global READ (frozen by pool_config_init / pool_owner_resolve):

| global | source | example | role |
|---|---|---|---|
| `POOL_LOCK_FILE` | pool_config_init | `/home/dustin/.local/state/agent-browser-pool/acquire.lock` | the flock target (`9>"$POOL_LOCK_FILE"`) |
| `POOL_LANES_DIR` | pool_config_init | `…/agent-browser-pool/lanes` | leases `<N>.json` (read/iterated/deleted) |
| `POOL_EPHEMERAL_ROOT` | pool_config_init | `/home/dustin/.agent-chrome-profiles/active` | ephemeral dirs `<N>/` (rm'd on reap; written into the lease) |
| `POOL_OWNER_PID/COMM/STARTTIME/CWD` | pool_owner_resolve | `1234`/`pi`/`8283368`/`/home/…` | the claimer's identity → provisional/adopted lease `owner` |

External commands (verified present): `flock` (`/usr/bin/flock`, util-linux — `flock 9`), `jq`
(lease read/mutate), `rm` (reap), `kill` (via pool_chrome_kill). `curl`/`agent-browser` are
used INDIRECTLY via pool_daemon_connected/pool_daemon_connect (M4.T3.S1).

**Naming** (CONTRACT-mandated + codebase convention): `pool_acquire_locked` (public,
CONTRACT name) + `_pool_acquire_critical_section` + `_pool_release_lane_internals` +
`_pool_adopt_lane` (private `_pool_*` helpers).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init pool_owner_resolve \
                  pool_lanes_list pool_lane_is_stale pool_find_free_lane \
                  pool_lease_write pool_lease_read pool_lease_field pool_lease_update \
                  _pool_atomic_write'
  - EXPECT: all reported as functions (M1–M3 LANDED). If any MISSING → STOP.
  - RUN (verify the P1.M4.T3.S1 PARALLEL contract is present — this task COMPOSES these):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_chrome_kill pool_daemon_connect pool_daemon_connected'
  - EXPECT: all three reported as functions. If MISSING → the parallel M4.T3.S1 has not landed
        yet; STOP and consult the orchestrator (this task depends on those three).
  - RUN (verify the flock binary + globals):
        command -v flock >/dev/null && echo "OK flock" || echo FAIL
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_LOCK_FILE" && -n "$POOL_LANES_DIR" && -n "$POOL_EPHEMERAL_ROOT" ]] \
                   && echo "OK globals" || echo FAIL'
        command -v jq >/dev/null && echo "OK jq" || echo FAIL
  - EXPECT: OK flock ; OK globals ; OK jq.
  - RUN (locate the append point — current EOF must be pool_chrome_kill):
        grep -nE '^pool_chrome_kill\(\)' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
  - EXPECT: pool_chrome_kill defined; it is the last function. APPEND the new banner + four
        functions AFTER its closing brace. Do NOT touch any existing function.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND _pool_release_lane_internals() + _pool_adopt_lane() + _pool_acquire_critical_section() + pool_acquire_locked() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_chrome_kill's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block):
        # =============================================================================
        # Acquire — flock critical section (P1.M5.T1.S1)
        # =============================================================================
        # The flock-guarded acquire critical section: REAP-STALE + REUSE-ORPHAN + CHOOSE-N +
        # CLAIM (PRD §2.4 step 3a–3d). Implements key_findings FINDING 2 (claim under the SHORT
        # flock, boot Chrome AFTER releasing — no launch/copy/wait inside the lock) + §2.9
        # (rc 1 ⇒ exhaustion → M5.T4) + §2.10 (lazy reaper on acquire) + §2.19 (atomic lease
        # writes). Consumed by the acquire post-lock boot (M5.T1.S2) and the exhaustion loop
        # (M5.T4). The private release kernel (_pool_release_lane_internals) is ALSO composed by
        # M5.T2.S1's public pool_release_lane and M5.T3.S1's reap (shared teardown path).

        # _pool_release_lane_internals LANE
        #
        # The release KERNEL: tear down one lane's Chrome + ephemeral dir + lease. Idempotent +
        # NON-FATAL (return 0 always; every kill/rm `2>/dev/null || true`; a missing/corrupt lease
        # is a clean no-op). Called by _pool_acquire_critical_section's REAP-STALE step (3a) for
        # each non-adoptable stale lane, AND (by contract) by M5.T2.S1 pool_release_lane +
        # M5.T3.S1 reap_stale.
        #
        # LOGIC:
        #   1. pool_lease_read "$lane" → JSON (rc 1 = missing/corrupt → return 0, nothing to release).
        #   2. ONE jq fork: extract .chrome_pid, .chrome_pgid, .port, .session, .ephemeral_dir.
        #   3. pool_chrome_kill "$chrome_pid" "$chrome_pgid"  (idempotent; handles 0/0 provisional).
        #   4. rm -rf the ephemeral dir — RECONSTRUCTED as "$POOL_EPHEMERAL_ROOT/$lane" AND guarded
        #      ([[ -n && == "$POOL_EPHEMERAL_ROOT"/* ]]) before any rm (NEVER rm an arbitrary lease path).
        #   5. rm -f "$POOL_LANES_DIR/$lane.json"  (the lease file).
        #   return 0.
        #
        # GOTCHA — idempotent + non-fatal: runs in the reap loop over many lanes; one already-dead
        #   lane must NEVER abort the pool under set -e. pool_lease_read rc 1 ⇒ return 0.
        # GOTCHA — rm -rf SAFETY: reconstruct the dir from the lane number + POOL_EPHEMERAL_ROOT
        #   (don't trust the lease's ephemeral_dir field) AND prefix-guard. research §6.
        # GOTCHA — pool_chrome_kill already self-guards 0/0 (provisional lease) + every kill || true.
        # Reads POOL_EPHEMERAL_ROOT + POOL_LANES_DIR (frozen). Writes: signals + rm + lease delete.
        # PRECONDITION: pool_config_init.
        _pool_release_lane_internals() {
            local lane="${1:-}"
            local json chrome_pid chrome_pgid ephemeral_dir
            local -a _f

            # Validate lane (path-traversal defense; a bogus lane "has nothing to release").
            [[ "$lane" =~ ^[0-9]+$ ]] || return 0

            # (1) Read the lease. rc 1 (missing OR corrupt) → nothing to release → return 0.
            #     `if !` is errexit-exempt (a bare capture would ABORT under set -e on rc 1).
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                return 0
            fi

            # (2) ONE jq fork: extract the fields _pool_acquire needs. Comma → 3 lines; mapfile -t
            #     strips trailing newlines. jq cannot fail here (valid JSON guaranteed by
            #     pool_lease_read's _pool_json_valid pre-check); the herestring is in-memory.
            mapfile -t _f < <(jq -r '.chrome_pid, .chrome_pgid, .ephemeral_dir' <<<"$json")
            chrome_pid="${_f[0]:-}"
            chrome_pgid="${_f[1]:-}"
            ephemeral_dir="${_f[2]:-}"

            # (3) Kill the Chrome process group (idempotent; handles 0/0 provisional lease).
            pool_chrome_kill "$chrome_pid" "$chrome_pgid"

            # (4) rm -rf the ephemeral dir — RECONSTRUCT from lane + POOL_EPHEMERAL_ROOT (do NOT
            #     trust the lease's ephemeral_dir), AND prefix-guard. Defense-in-depth: even a
            #     corrupt/hostile lease cannot make us rm an arbitrary path. `|| true` for safety.
            local dir="$POOL_EPHEMERAL_ROOT/$lane"
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            # (Defense-in-depth: if the lease's ephemeral_dir DIFFERS from the reconstructed path
            #  and is a distinct valid sub-tree under POOL_EPHEMERAL_ROOT, remove it too — covers a
            #  historical layout change. Same guard.)
            if [[ -n "$ephemeral_dir" && "$ephemeral_dir" == "$POOL_EPHEMERAL_ROOT"/* \
                  && "$ephemeral_dir" != "$POOL_EPHEMERAL_ROOT/" && "$ephemeral_dir" != "$dir" ]]; then
                rm -rf -- "$ephemeral_dir" 2>/dev/null || true
            fi

            # (5) Delete the lease file. `|| true` (already-deleted / TOCTOU).
            rm -f -- "$POOL_LANES_DIR/$lane.json" 2>/dev/null || true

            _pool_log "pool_acquire(reap): released stale lane $lane (chrome_pid=${chrome_pid:-0})"
            return 0
        }

        # _pool_adopt_lane LANE
        #
        # REUSE-ORPHAN adoption (PRD §2.4 step 3b / IQ4): reassign a responsive-but-orphaned lane's
        # owner to the CURRENT claimer, mark connected, and re-bind the daemon. Called by
        # _pool_acquire_critical_section when a STALE lane has a RESPONSIVE Chrome
        # (pool_daemon_connected == 0). Skips the copy/launch (the Chrome is already running).
        #
        # LOGIC:
        #   1. pool_lease_read "$lane" → JSON (rc 1 ⇒ return 1, can't adopt a missing lease).
        #   2. Extract .port + .session (for the daemon re-bind).
        #   3. jq mutate: .owner = {pid,comm,starttime,cwd from POOL_OWNER_*} | .connected = true
        #      | .last_seen_at = $(_pool_now). Inject-safe (--arg/--argjson DATA, fixed filter).
        #   4. _pool_atomic_write the mutated JSON back to the lease file (tmp+mv, same FS).
        #   5. pool_daemon_connect "$session" "$port" — re-bind the daemon to the (still-running)
        #      Chrome. rc 0 ⇒ return 0 (adopted). rc 1 ⇒ the Chrome died between the responsiveness
        #      probe and now → return 1 (caller will REAP it instead).
        #
        # WHY A DIRECT jq MUTATION (not pool_lease_update): pool_lease_update is TOP-LEVEL FIELD ONLY
        #   and CANNOT touch the nested .owner sub-object (M3.T1.S1 docstring: "owner is written
        #   once at acquire, never mutated"). Adoption is the ONE deliberate owner mutation. The jq
        #   `.owner = {…} | .connected = true | .last_seen_at = $now` filter is inject-safe (all
        #   values are --arg/--argjson DATA, never spliced into the program). research §4.
        #
        # GOTCHA — the responsiveness probe (pool_daemon_connected) runs in the CALLER BEFORE this;
        #   this function only does the REASSIGN + RE-BIND. A race where the Chrome dies between the
        #   probe and pool_daemon_connect is handled by connect returning rc 1 ⇒ caller reaps.
        # GOTCHA — `connected` MUST be a JSON boolean (true), not the number 1. pool_daemon_connect
        #   is an ATTACH (~ms) — safe inside the lock (research §2); it is NOT a Chrome launch.
        # GOTCHA — owner reassignment writes the CURRENT POOL_OWNER_* identity (the adopter), so the
        #   lane is now "mine" and survives pool_lane_is_stale for the adopter.
        # NON-FATAL (return 0 adopted / 1 Chrome-died-mid-adopt). Reads POOL_OWNER_* + POOL_LANES_DIR.
        # PRECONDITION: pool_config_init + pool_owner_resolve.
        _pool_adopt_lane() {
            local lane="${1:-}"
            local json port session now adopted

            [[ "$lane" =~ ^[0-9]+$ ]] || return 1
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                return 1   # can't adopt a missing/corrupt lease
            fi

            # Extract port + session for the re-bind. PLAIN assignment (not local x=$(…)) so jq's
            # exit status is preserved — but jq cannot fail on valid JSON; guard anyway.
            port="$(jq -r '.port' <<<"$json")"
            session="$(jq -r '.session' <<<"$json")"

            # Validate the owner identity globals are present (defensive; pool_owner_resolve sets them).
            [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1

            # Mutate: rewrite .owner to the CURRENT claimer, set connected=true, stamp last_seen_at.
            # All values enter jq as DATA (--arg/--argjson) → inject-safe. starttime/cwd via --arg
            # (strings) OR --argjson (numbers) — starttime is digits → --argjson; cwd/comm → --arg.
            now="$(_pool_now)"
            if ! updated_lease="$(jq \
                    --argjson now "$now" \
                    --argjson pid "$POOL_OWNER_PID" \
                    --arg comm "$POOL_OWNER_COMM" \
                    --argjson starttime "${POOL_OWNER_STARTTIME:-0}" \
                    --arg cwd "${POOL_OWNER_CWD:-}" \
                    '.owner = {pid:$pid, comm:$comm, starttime:$starttime, cwd:$cwd}
                     | .connected = true
                     | .last_seen_at = $now' \
                    <<<"$json" 2>/dev/null)"; then
                return 1   # jq build failure — caller reaps
            fi

            # Atomic publish (tmp+mv same dir = same FS). _pool_atomic_write pool_die's on a real
            # FS failure (exceptional); that exits the subshell → flock released → propagates.
            _pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$updated_lease"

            # Re-bind the daemon to the (still-running) Chrome. An ATTACH — safe inside the lock.
            # rc 1 ⇒ Chrome died between the probe and now ⇒ tell the caller to reap (return 1).
            if ! pool_daemon_connect "$session" "$port"; then
                return 1
            fi

            _pool_log "pool_acquire(adopt): reused orphan lane $lane (port=$port, owner pid=$POOL_OWNER_PID)"
            return 0
        }

        # _pool_acquire_critical_section
        #
        # THE FLOCK BODY — runs inside `( flock 9; <this> ) 9>"$POOL_LOCK_FILE"`. A FUNCTION (so it
        # can `return` and inherit all globals). Performs PRD §2.4 step 3a–3d:
        #   a. REAP-STALE + REUSE-ORPHAN (interleaved per lane): for each lane, pool_lane_is_stale
        #      rc 0 (stale) → if pool_daemon_connected(session,port)==0 (responsive Chrome) → ADOPT
        #      (_pool_adopt_lane; echo N; return 0); else REAP (_pool_release_lane_internals).
        #      rc 1 (live) / rc 2 (no lease) → skip.
        #   c. CHOOSE-N: pool_find_free_lane → N (always echoes + rc 0; set -e safe).
        #   d. CLAIM: pool_lease_write(N, ephemeral_dir, 0, abpool-N, owner..., 0, 0, "false").
        #   echo N; return 0.  Fall-through (POOL_OWNER_PID==0 OR no free lane) → return 1.
        #
        # OUTPUT: echoes the claimed/adopted lane N on success (return 0); echoes nothing on
        # exhaustion (return 1). The CALLER distinguishes provisional (port:0/connected:false → S2
        # boots) vs adopted (port>0/connected:true → S3 ensures) by reading the lease. research §5.
        #
        # GOTCHA — TRI-STATE pool_lane_is_stale: `if pool_lane_is_stale "$n"; then …; fi` runs the
        #   body on rc 0 (stale) only; rc 1 (live) / rc 2 (no-lease) fall through. A BARE call
        #   ABORTS under set -e on rc 1/2.
        # GOTCHA — reuse-orphan uses pool_daemon_connected (read-only, NEVER launches — P1.M4.T3.S1
        #   research §2 forbids get cdp-url). Only port>0 lanes can be orphans (provisional port=0
        #   has no Chrome yet → always reaped, never adopted).
        # GOTCHA — POOL_OWNER_PID==0 ⇒ return 1 (a passthrough owner must not claim; defense-in-depth).
        # GOTCHA — _pool_adopt_lane return 1 (Chrome died mid-adopt) ⇒ fall through to REAP that lane.
        # Reads POOL_OWNER_*, POOL_EPHEMERAL_ROOT, POOL_LANES_DIR. Non-fatal on exhaustion (rc 1).
        # PRECONDITION: pool_config_init + pool_owner_resolve (+ pool_state_init by the wrapper).
        _pool_acquire_critical_section() {
            local n port session N ephemeral_dir

            # Defensive: a passthrough owner (no pi ancestor → POOL_OWNER_PID==0) must NOT claim a
            # lane (it would be immediately stale to everyone). The wrapper gates passthrough BEFORE
            # acquire in M6; this is defense-in-depth. `[[ ]] || return 1` is errexit-exempt.
            [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1

            # (a/b) REAP-STALE + REUSE-ORPHAN, interleaved per lane in ascending order.
            for n in $(pool_lanes_list); do
                # TRI-STATE capture: pool_lane_is_stale 0=stale / 1=live / 2=no-lease.
                # `if …; then` runs the body on rc 0 (stale) only; rc 1/2 fall through (skip).
                if pool_lane_is_stale "$n"; then
                    # Stale. Is it an ORPHAN (responsive Chrome)? Only lanes with a real port can be.
                    port="$(pool_lease_field "$n" port 2>/dev/null)" || port=""
                    session="$(pool_lease_field "$n" session 2>/dev/null)" || session=""
                    if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
                       && pool_daemon_connected "$session" "$port"; then
                        # REUSE-ORPHAN: adopt. If adoption succeeds → we're DONE (return this lane).
                        # If adoption fails (Chrome died mid-adopt) → fall through to reap it.
                        if _pool_adopt_lane "$n"; then
                            printf '%s\n' "$n"
                            return 0
                        fi
                    fi
                    # REAP-STALE: not adoptable (or adoption failed) → release the lane's resources.
                    _pool_release_lane_internals "$n"
                fi
            done

            # (c) CHOOSE-N: lowest free lane. Always echoes + rc 0 → bare capture is set -e safe.
            N="$(pool_find_free_lane)"

            # (d) CLAIM: write the PROVISIONAL lease (port=0, chrome_pid=0, chrome_pgid=0,
            #     connected=false, owner=current). pool_lease_write validates connected ∈
            #     {"true","false"} + builds via jq + publishes atomically. A build/FS failure
            #     pool_die's → exits the subshell → flock released → propagates (exceptional).
            ephemeral_dir="$POOL_EPHEMERAL_ROOT/$N"
            pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" \
                "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" "${POOL_OWNER_CWD:-}" \
                0 0 "false"

            _pool_log "pool_acquire(claim): provisional lane $N for owner pid=$POOL_OWNER_PID"
            printf '%s\n' "$N"
            return 0
        }

        # pool_acquire_locked
        #
        # PUBLIC ENTRY POINT — acquire a lane under an exclusive flock on $POOL_LOCK_FILE. Runs
        # _pool_acquire_critical_section inside the canonical `( flock 9; body ) 9>file` subshell
        # (key_findings FINDING 2; flock(1) man-page-recommended shell form). The lock is held ONLY
        # for scan+reap+reuse+choose+claim (NO Chrome launch/copy/wait — those are S2, post-lock).
        #
        # Echoes the claimed/adopted lane N + return 0 on success; echoes nothing + return 1 on
        # exhaustion (all lanes live / passthrough owner) → M5.T4. The lock auto-releases on return
        # (incl. pool_die/SIGKILL — the kernel closes fd 9 on subshell exit; research §1.2).
        #
        # CALLER CONTRACT (under set -e — split the capture per BashFAQ 105):
        #     local N
        #     if N="$(pool_acquire_locked)"; then
        #         port="$(pool_lease_field "$N" port)"
        #         if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
        #             <S2 post-lock boot: copy→port→launch→connect→update lease>
        #         else
        #             <S3 adopted: ensure_connected only; skip the boot>
        #         fi
        #     else
        #         <M5.T4 exhaustion: block-with-timeout / force-reap / alert>
        #     fi
        #
        # GOTCHA — `local N; N="$(pool_acquire_locked)"` MUST be split: `local N=$(…)` masks errexit
        #   (local returns 0). research §1.5 / BashFAQ 105.
        # GOTCHA — pool_state_init is called first so `9>"$POOL_LOCK_FILE"` cannot fail on a missing
        #   parent dir (idempotent; pool_die only on a real FS error).
        # Reads POOL_LOCK_FILE (+ everything _pool_acquire_critical_section reads). No new globals.
        # PRECONDITION: pool_config_init + pool_owner_resolve (+ pool_state_init, called here).
        pool_acquire_locked() {
            # Ensure the lock file + lanes dir exist (idempotent) so the fd-9 redirect opens cleanly.
            pool_state_init

            # The canonical flock idiom. fd 9 is opened on POOL_LOCK_FILE; `flock 9` (blocking,
            # returns 0) acquires the exclusive lock; the body function runs (inherited — it's a
            # subshell fork); the subshell's exit status == the function's return code; stdout (echo
            # N) propagates to the caller's $(…). The lock is released when the subshell exits.
            (
                flock 9
                _pool_acquire_critical_section
            ) 9>"$POOL_LOCK_FILE"
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155 + the BashFAQ-105 errexit
        rule); TRI-STATE pool_lane_is_stale via `if …; then`; arg validation via `[[ ]] || return`;
        every kill/rm `2>/dev/null || true` in the release kernel; `_pool_log` one line per action;
        `9>"$POOL_LOCK_FILE"` fd-9 flock idiom.
  - NAMING: pool_acquire_locked (PUBLIC, CONTRACT) + _pool_acquire_critical_section +
        _pool_release_lane_internals + _pool_adopt_lane (PRIVATE `_pool_*`).
  - PLACEMENT: the four functions in the new "(P1.M5.T1.S1)" banner, after pool_chrome_kill.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_acquire_locked _pool_acquire_critical_section \
                      _pool_release_lane_internals _pool_adopt_lane' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: empty-pool acquire → provisional claim on lane 1 ---
  - RUN (fresh isolated state dir; TEST-MODE owner via the test hook — owner identity is $$):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        MYST="$(sed 's/.*)//' /proc/$$/stat | awk '{print $20}')"   # real starttime of this shell
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_POOL_OWNER_PID="$$" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MYST" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
                  local N; N="$(pool_acquire_locked)" || { echo FAIL1; exit 1; }
                  echo "acquired N=$N"
                  test -f "$POOL_LANES_DIR/$N.json" && echo "OK1-lease-exists" || echo FAIL1-lease
                  jq -e ".lane==$N and .port==0 and .chrome_pid==0 and .chrome_pgid==0 and .connected==false" \
                     "$POOL_LANES_DIR/$N.json" >/dev/null && echo "OK1-provisional" || echo FAIL1-fields'
        # NOTE: the empty pool means owner identity is not exercised (no leases to reap). $$ is
        # non-zero + numeric so it passes the defensive gate; its real starttime is captured above.
        # EXPECT: acquired N=1 ; OK1-lease-exists ; OK1-provisional.
  #
  # --- SCENARIO 2: MUTUAL EXCLUSION — a LIVE owner's lane is respected; a distinct owner gets the next lane ---
  # NOTE on testability (CRITICAL): pool_owner_resolve in TEST MODE HARDCODES POOL_OWNER_COMM="pi", so a
  # lease written by pool_acquire_locked carries owner.comm="pi" — but the test process's REAL comm is
  # NOT "pi", so to ANOTHER acquirer that lane reads as STALE (comm mismatch in pool_owner_alive) and
  # would be REAPED. To make a lane appear genuinely LIVE to a second acquirer, we PLANT its lease
  # with a REAL live process's pid + REAL comm + REAL starttime (so pool_lane_is_stale →
  # pool_owner_alive ⇒ alive ⇒ skipped by REAP-STALE). This is the faithful mutual-exclusion test.
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes" "$EPHEM/1"
        # A REAL live "owner A" (background sleep — stays alive for the test):
        sleep 600 & OWNA=$!
        ST_A="$(sed 's/.*)//' /proc/$OWNA/stat | awk '{print $20}')"
        COMM_A="$(cat /proc/$OWNA/comm)"        # "sleep"
        # Plant a LIVE lease for lane 1 owned by the real live OWNA (comm matches /proc/$OWNA/comm):
        jq -n --argjson lane 1 --arg ed "$EPHEM/1" --argjson port 0 --arg session "abpool-1" \
              --argjson pid "$OWNA" --arg comm "$COMM_A" --argjson st "$ST_A" --arg cwd "" \
              --argjson cpid 0 --argjson cpgid 0 --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:false}' > "$STATE/lanes/1.json"
        # A SECOND live owner B acquires (another real live process, via the test hook):
        sleep 600 & OWNB=$!
        ST_B="$(sed 's/.*)//' /proc/$OWNB/stat | awk '{print $20}')"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_POOL_OWNER_PID="$OWNB" AGENT_BROWSER_POOL_OWNER_STARTTIME="$ST_B" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
                  local N; N="$(pool_acquire_locked)"; echo "ownerB acquired N=$N"
                  [[ "$N" == "2" ]] && echo "OK2-got-distinct-lane-2" || echo "FAIL2-wrong-lane-N=$N"
                  jq -e ".owner.pid==$OWNA" "$POOL_LANES_DIR/1.json" >/dev/null \
                     && echo "OK2-lane1-untouched-still-live-owner" || echo "FAIL2-lane1-tampered"'
        kill "$OWNA" "$OWNB" 2>/dev/null || true
        # EXPECT: ownerB acquired N=2 ; OK2-got-distinct-lane-2 ; OK2-lane1-untouched-still-live-owner.
        #   (lane 1 is LIVE → skipped by REAP-STALE; lane 2 is the lowest free → claimed. Mutual exclusion.)
  #
  # --- SCENARIO 3: REAP-STALE — a stale lease (owner dead) with NO live Chrome is reaped + reused ---
  - RUN (plant a stale lease for lane 1 — owner PID that does not exist → stale; no Chrome on its port):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes" "$EPHEM/1"
        jq -n --argjson lane 1 --arg ed "$EPHEM/1" --argjson port 0 --arg session "abpool-1" \
              --argjson pid 999999 --arg comm "pi" --argjson st 999 --arg cwd "" \
              --argjson cpid 0 --argjson cpgid 0 --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:false}' > "$STATE/lanes/1.json"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_POOL_OWNER_PID="20001" AGENT_BROWSER_POOL_OWNER_STARTTIME="333" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
                  local N; N="$(pool_acquire_locked)"; echo "reaped+claimed N=$N"
                  test -d "$EPHEM/1" && echo "FAIL3-dir-still-there" || echo "OK3-ephemeral-removed"
                  test -f "$POOL_LANES_DIR/1.json" && jq -e ".owner.pid==20001" "$POOL_LANES_DIR/1.json" >/dev/null \
                     && echo "OK3-lane1-reclaimed-by-new-owner" || echo "FAIL3"'
        # EXPECT: reaped+claimed N=1 ; OK3-ephemeral-removed ; OK3-lane1-reclaimed-by-new-owner.
        #   (pid 999999 does not exist → pool_lane_is_stale rc 0 → reaped → lane 1 reused.)
  #
  # --- SCENARIO 4: REUSE-ORPHAN — a stale lease WITH a responsive Chrome is ADOPTED (no copy/launch) ---
  #   Requires a LIVE headless Chrome on a free port + a lease whose owner is dead but port points
  #   at that Chrome. pool_daemon_connected must return 0 (session known + chrome alive).
  - RUN (launch a real headless Chrome, plant a stale lease pointing at it, then acquire):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes" "$EPHEM/3"
        PORT=55601; UDD="$EPHEM/3"
        setsid google-chrome-stable --remote-debugging-port="$PORT" --user-data-dir="$UDD" \
          --no-first-run --no-default-browser-check --headless=new >/tmp/s4-chrome.log 2>&1 &
        CP=$!; for i in $(seq 1 20); do curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break; sleep 0.5; done
        # Pre-bind the daemon session so pool_daemon_connected's session-list check passes:
        "$HOME/.local/bin/agent-browser" --session "abpool-3" connect "$PORT" >/dev/null 2>&1 || true
        # Plant a STALE lease (owner pid 888888 does not exist) but with a LIVE Chrome on $PORT:
        jq -n --argjson lane 3 --arg ed "$UDD" --argjson port "$PORT" --arg session "abpool-3" \
              --argjson pid 888888 --arg comm "pi" --argjson st 888 --arg cwd "" \
              --argjson cpid "$CP" --argjson cpgid "$CP" --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:true}' > "$STATE/lanes/3.json"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_POOL_OWNER_PID="30001" AGENT_BROWSER_POOL_OWNER_STARTTIME="444" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
                  local N; N="$(pool_acquire_locked)"; echo "adopt N=$N"
                  [[ "$N" == "3" ]] && echo "OK4-reused-lane-3" || echo "FAIL4-wrong-lane"
                  jq -e ".owner.pid==30001 and .connected==true and .port==$PORT" "$POOL_LANES_DIR/3.json" >/dev/null \
                     && echo "OK4-adopted-owner+connected" || echo "FAIL4-adopt-fields"'
        # cleanup the chrome:
        g="$(ps -o pgid= -p "$CP" 2>/dev/null|tr -d ' ')"; kill -9 -- -"$g" 2>/dev/null; \
          "$HOME/.local/bin/agent-browser" --session abpool-3 close >/dev/null 2>&1 || true
        # EXPECT: adopt N=3 ; OK4-reused-lane-3 ; OK4-adopted-owner+connected.
        #   (stale owner 888888 BUT responsive Chrome → ADOPTED, not reaped; no new lane claimed.)
  #
  # --- SCENARIO 5: EXHAUSTION — all lanes held by LIVE owners → rc 1, no output, no new lease ---
  - RUN (plant a lane 1 lease whose owner IS the current simulated owner → LIVE; no free lane below it):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes"
        # Lane 1 owned by pid 50001 — make the acquirer BE pid 50001 so it is LIVE (or use a real
        # live PID). Simpler: claim lane 1 first (scenario 1), then acquire again as the SAME owner
        # and assert find_my_lease would catch it — but for THIS function, acquire again as a
        # DIFFERENT owner with lane 1 LIVE and lane 1's dir present → it must pick lane 2, NOT rc 1.
        # For a TRUE rc-1 test: make lane 1 owned by a LIVE pid AND no higher free lane reachable
        # is impossible (lanes are unbounded). So rc 1 is ONLY reachable via POOL_OWNER_PID==0:
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_BROWSER_POOL_OWNER_PID="0" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
                  if N="$(pool_acquire_locked)"; then echo "FAIL5-should-be-rc1 N=$N"; else echo "OK5-rc1-passthrough"; fi
                  ls "$POOL_LANES_DIR" 2>/dev/null | wc -l | xargs -I{} echo "leases-after: {}"'
        # EXPECT: OK5-rc1-passthrough ; leases-after: 0.  (POOL_OWNER_PID==0 ⇒ defensive rc 1.)
  #
  # --- SCENARIO 6: _pool_release_lane_internals idempotency + provisional-lease safety ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes" "$EPHEM/7"
        jq -n --argjson lane 7 --arg ed "$EPHEM/7" --argjson port 0 --arg session "abpool-7" \
              --argjson pid 777 --arg comm "pi" --argjson st 7 --arg cwd "" \
              --argjson cpid 0 --argjson cpgid 0 --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:false}' > "$STATE/lanes/7.json"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  _pool_release_lane_internals 7; echo "release rc=$?"
                  test -e "$EPHEM/7" && echo "FAIL6-dir" || echo "OK6-dir-gone"
                  test -e "$POOL_LANES_DIR/7.json" && echo "FAIL6-lease" || echo "OK6-lease-gone"
                  _pool_release_lane_internals 7; echo "re-release rc=$?"   # idempotent
                  _pool_release_lane_internals 999; echo "no-lease rc=$?"'  # missing lease
        # EXPECT: release rc=0 ; OK6-dir-gone ; OK6-lease-gone ; re-release rc=0 ; no-lease rc=0.
  #
  # --- CLEANUP test state dirs ---
  - RUN: rm -rf "$STATE" "$EPHEM" 2>/dev/null; for c in $(pgrep -f "remote-debugging-port=55601" 2>/dev/null); do g="$(ps -o pgid= -p "$c"|tr -d ' ')"; kill -9 -- -"$g" 2>/dev/null; done; echo cleaned
  #
  # --- PRIOR-DELIVERABLES regression (must still all be callable) ---
  - RUN:
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 type pool_config_init pool_state_init pool_die _pool_log pool_owner_resolve \
                      pool_owner_alive pool_lease_write pool_lease_read pool_lease_field pool_lease_update \
                      pool_lanes_list pool_lease_find_mine pool_find_free_lane pool_lane_is_stale \
                      pool_copy_master pool_find_free_port pool_chrome_launch pool_wait_cdp \
                      pool_daemon_connect pool_daemon_connected pool_chrome_kill \
                      pool_acquire_locked' >/dev/null && echo OK-regression
  - EXPECT: OK-regression (all prior functions + pool_acquire_locked present).
```

### Implementation Patterns & Key Details

```bash
# PATTERN: the flock-guarded critical section (FINDING 2; flock(1) man-page form).
#   pool_state_init ensures the lock file + lanes dir exist (idempotent) so `9>file` opens cleanly.
#   Plain blocking `flock 9` returns 0; the body function is INHERITED by the subshell fork;
#   its `return` becomes the subshell exit status; its stdout (echo N) propagates. The lock
#   auto-releases on subshell exit (kernel closes fd 9). NO trap needed.
pool_acquire_locked() {
    pool_state_init
    (
        flock 9
        _pool_acquire_critical_section
    ) 9>"$POOL_LOCK_FILE"
}

# PATTERN: TRI-STATE pool_lane_is_stale (0=stale/1=live/2=no-lease). `if …; then` runs the body
#   on rc 0 (stale) ONLY; rc 1/2 fall through. NEVER a bare call (aborts under set -e on rc 1/2).
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then
        …reap-or-adopt…
    fi
done

# PATTERN: the release kernel (idempotent + non-fatal). Every kill/rm `2>/dev/null || true`;
#   missing/corrupt lease ⇒ return 0. rm -rf is RECONSTRUCTED + prefix-guarded (NEVER trust a
#   lease path). Composes pool_chrome_kill (already self-guards 0/0 + every kill || true).
_pool_release_lane_internals() {
    local lane="$1" json
    local -a _f
    [[ "$lane" =~ ^[0-9]+$ ]] || return 0
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi
    mapfile -t _f < <(jq -r '.chrome_pid, .chrome_pgid, .ephemeral_dir' <<<"$json")
    pool_chrome_kill "${_f[0]:-}" "${_f[1]:-}"
    local dir="$POOL_EPHEMERAL_ROOT/$lane"
    if [[ "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
        rm -rf -- "$dir" 2>/dev/null || true
    fi
    rm -f -- "$POOL_LANES_DIR/$lane.json" 2>/dev/null || true
    return 0
}

# PATTERN: reuse-orphan adoption — DIRECT jq nested mutation (pool_lease_update is top-level only).
#   `.owner = {…} | .connected = true | .last_seen_at = $now` via --arg/--argjson (inject-safe) +
#   _pool_atomic_write. Then pool_daemon_connect (ATTACH, safe inside the lock) to re-bind.
updated_lease="$(jq --argjson pid "$POOL_OWNER_PID" --arg comm "$POOL_OWNER_COMM" \
    --argjson starttime "${POOL_OWNER_STARTTIME:-0}" --arg cwd "${POOL_OWNER_CWD:-}" \
    --argjson now "$(_pool_now)" \
    '.owner={pid:$pid,comm:$comm,starttime:$starttime,cwd:$cwd}|.connected=true|.last_seen_at=$now' \
    <<<"$json")"
_pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$updated_lease"
pool_daemon_connect "$session" "$port"   # rc 0 adopted / rc 1 chrome-died-mid-adopt

# PATTERN: provisional CLAIM via pool_lease_write (11 args; connected MUST be literal "false").
pool_lease_write "$N" "$POOL_EPHEMERAL_ROOT/$N" 0 "abpool-$N" \
    "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" "${POOL_OWNER_CWD:-}" \
    0 0 "false"
```

### Integration Points

```yaml
GLOBALS (read-only):
  - POOL_LOCK_FILE:    "$POOL_STATE_DIR/acquire.lock (the flock target — 9> redirect)."
  - POOL_LANES_DIR:    "$POOL_STATE_DIR/lanes (leases <N>.json — iterate/read/delete/write)."
  - POOL_EPHEMERAL_ROOT: "$HOME/.agent-chrome-profiles/active (ephemeral dirs <N>/ — rm on reap; path in lease)."
  - POOL_OWNER_PID/COMM/STARTTIME/CWD: "from pool_owner_resolve — the claimer's identity → lease owner."

COMPOSED (LANDED — treated as CONTRACT):
  - pool_state_init:          "ensures POOL_LANES_DIR + POOL_LOCK_FILE exist (called at entry)."
  - pool_lanes_list:          "reap-loop iterator (always rc 0; sorted lane numbers)."
  - pool_lane_is_stale:       "TRI-STATE 0=stale/1=live/2=no-lease — the reap decision."
  - pool_find_free_lane:      "CHOOSE-N (always rc 0 + echoes N)."
  - pool_lease_write:         "provisional CLAIM (11 args; connected literal 'false')."
  - pool_lease_read/field:    "read lease fields for reap/adopt."
  - _pool_atomic_write:       "atomic publish for the adoption mutation (tmp+mv same dir)."
  # From P1.M4.T3.S1 (PARALLEL — WILL be at EOF when this runs):
  - pool_chrome_kill:         "idempotent Chrome pgroup teardown (rc 0 always; handles 0/0)."
  - pool_daemon_connected:    "SIDE-EFFECT-FREE responsiveness probe (rc 0 ⇒ adoptable)."
  - pool_daemon_connect:      "ATTACH re-bind (rc 0 adopted / rc 1 chrome-died)."

DOWNSTREAM CONSUMERS (NOT this task's work — documented as contract):
  - M5.T1.S2: "acquire post-lock boot — calls pool_acquire_locked; on rc 0 reads the lease:
               port==0 ⇒ boot (copy→port→launch→connect→update); port>0&&connected ⇒ ensure only."
  - M5.T4:    "exhaustion loop — pool_acquire_locked rc 1 ⇒ block-with-timeout / force-reap / alert."
  - M5.T2.S1: "public pool_release_lane COMPOSES _pool_release_lane_internals (no duplication)."
  - M5.T3.S1: "standalone pool_reap_stale shares _pool_release_lane_internals."
  - M5.T3.S2: "standalone pool_reuse_orphan may compose _pool_adopt_lane (or its logic)."
  - M6.T3.S1: "wrapper lifecycle step 3 driver — find_my_lease misses ⇒ pool_acquire_locked."

NO NEW:
  - files: "none (pure append to lib/pool.sh)."
  - env vars: "none."
  - globals: "none exported (reads POOL_* only)."
  - leases/migrations: "none (reads/writes the existing PRD §2.8 schema)."
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the four functions — fix before proceeding.
bash -n lib/pool.sh                       # syntax — MUST be clean
shellcheck lib/pool.sh                    # zero warnings (whole file, incl. the new functions)

# Expected: Zero errors. Watch for SC2155 (declare+assign — split `local x; x=$(…)`) on every
# command-substitution capture (the BashFAQ-105 errexit-masking rule) and SC2086 on the kill/rm
# args (they ARE quoted). Read any output and fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# No bats harness yet (M9.T1.S1). Validate via the SCENARIO blocks in Task 2 above — each is a
# self-contained bash -c against an isolated state dir (and a REAL Chrome for scenario 4).
# Re-run any scenario in isolation. The headline scenarios:
#   SCENARIO 1 (empty-pool provisional claim) ; SCENARIO 2 (mutual exclusion) ;
#   SCENARIO 3 (reap-stale reuse) ; SCENARIO 4 (reuse-orphan adopt, REAL Chrome) ;
#   SCENARIO 5 (exhaustion rc 1) ; SCENARIO 6 (_pool_release_lane_internals idempotency).
# Expected: every "OK*" line prints; no "FAIL*" line prints.
```

### Level 3: Integration Testing (System Validation)

```bash
# SCENARIO 2 (mutual exclusion) + SCENARIO 4 (reuse-orphan against a REAL Chrome + REAL daemon)
# ARE the integration tests — they exercise the flock serialization, the LANDED lease/owner
# primitives, AND the P1.M4.T3.S1 daemon primitives together. Re-run end-to-end.

# Daemon/CLI sanity (the shared daemon is healthy; abpool-* sessions don't disturb others):
agent-browser --json session list >/dev/null 2>&1 && echo "OK daemon responds" || echo FAIL
# Expected: OK daemon responds.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# THE critical domain-specific assertions for this task:
#  (1) SHORT CRITICAL SECTION — prove no Chrome launch happens inside the flock. Easiest proof:
#      scenario 1 (provisional claim) runs with ZERO google-chrome processes started by the call
#      (the provisional lease has chrome_pid:0). Verify:
        before="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        # …run SCENARIO 1…
        after="$(pgrep -c -f 'remote-debugging-port' 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK-short-section (no launch inside lock)" || echo "FAIL-launched"
#      Expected: OK-short-section (N==N).  (Only scenario 4 deliberately launches a Chrome to be
#      adopted — and that Chrome is launched by the TEST HARNESS, not by pool_acquire_locked.)
#
#  (2) REUSE-ORPHAN never uses get cdp-url (the auto-launch trap — P1.M4.T3.S1 research §2):
#      grep the new functions for "get cdp-url" — MUST be absent. pool_daemon_connected is the probe.
        grep -nE 'get[[:space:]]+cdp-url' lib/pool.sh && echo "FAIL-forbidden-get-cdp-url" || echo "OK-no-get-cdp-url"
#      Expected: OK-no-get-cdp-url.
#
#  (3) rm -rf GUARD — prove a corrupt/hostile lease ephemeral_dir cannot cause an arbitrary rm.
#      Plant a lease with ephemeral_dir="/etc" (hostile) and call _pool_release_lane_internals;
#      it must reconstruct "$POOL_EPHEMERAL_ROOT/$lane" and IGNORE the /etc field (prefix-guard
#      rejects "/etc" since it's not under POOL_EPHEMERAL_ROOT). /etc is untouched.
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"; mkdir -p "$STATE/lanes"
        jq -n --argjson lane 1 --arg ed "/etc" --argjson port 0 --arg session "abpool-1" \
              --argjson pid 9 --arg comm pi --argjson st 9 --arg cwd "" --argjson cpid 0 \
              --argjson cpgid 0 --argjson now "$(date +%s)" \
              '{version:1,lane:$lane,ephemeral_dir:$ed,port:$port,session:$session,
                owner:{pid:$pid,comm:$comm,starttime:$st,cwd:$cwd},chrome_pid:$cpid,chrome_pgid:$cpgid,
                acquired_at:$now,last_seen_at:$now,connected:false}' > "$STATE/lanes/1.json"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  _pool_release_lane_internals 1; echo "rc=$?"
                  test -d /etc && echo "OK-etc-untouched" || echo "FAIL-etc-gone"'
        rm -rf "$STATE"; rmdir "$EPHEM" 2>/dev/null
#      Expected: rc=0 ; OK-etc-untouched.  (The guard rejected /etc; only $EPHEM/1 would be rm'd.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean.
- [ ] `shellcheck lib/pool.sh` clean (whole file).
- [ ] All Task 2 scenarios pass (empty-pool claim, mutual exclusion, reap-stale, reuse-orphan
      adopt, exhaustion rc 1, release-kernel idempotency).
- [ ] Level 4: short-section (no launch inside lock) ; no `get cdp-url` ; rm -rf guard holds.
- [ ] Prior-deliverables regression (Task 2 final RUN) reports OK-regression.

### Feature Validation

- [ ] Empty-pool acquire echoes `1` + rc 0 + provisional `lanes/1.json` (port:0/connected:false).
- [ ] Two distinct owners get lanes `1` + `2` (mutual exclusion under flock).
- [ ] Stale lease + dead Chrome ⇒ reaped + lane number reused for the provisional claim.
- [ ] Stale lease + responsive Chrome ⇒ ADOPTED (owner rewritten, connected:true, no copy/launch).
- [ ] All-live / passthrough owner ⇒ rc 1, no lease written.
- [ ] `_pool_release_lane_internals` idempotent + safe on provisional leases (chrome_pid:0).
- [ ] No existing function modified (esp. pool_chrome_kill / pool_wait_cdp / pool_lease_write).

### Code Quality Validation

- [ ] Follows existing patterns (non-fatal rc-returning; `local` first then assign; TRI-STATE
      pool_lane_is_stale via `if`; `2>/dev/null || true` on every kill/rm; flock fd-9 idiom).
- [ ] File placement matches the desired tree (appended after pool_chrome_kill under the new banner).
- [ ] Anti-patterns avoided (no Chrome launch inside the lock; no `get cdp-url`; no bare
      pool_lane_is_stale call; no `local x=$(...)`; no `rm -rf` of an unguarded lease path; no
      pool_die on the exhaustion path; no nested-field use of pool_lease_update).
- [ ] Only POOL_* globals read; no new globals/env-vars/files.

### Documentation & Deployment

- [ ] Each function has a docstring with LOGIC + CONSUMER + GOTCHA sections (mirrors pool_wait_cdp).
- [ ] The cross-dependency resolution (release kernel defined here; M5.T2.S1 composes it) is
      documented in the banner + the _pool_release_lane_internals docstring.
- [ ] The caller contract (split `local N; N=$(…)`; provisional-vs-adopted lease-state branching)
      is documented in the pool_acquire_locked docstring.
- [ ] _pool_log lines are concise (one per reap/adopt/claim action).

---

## Anti-Patterns to Avoid

- ❌ Don't launch/copy/wait for Chrome INSIDE the flock — that serializes concurrent acquires (FINDING 2).
      Chrome launch is S2 (post-lock). The only subprocess inside is pool_daemon_connect (attach) in the rare adopt path.
- ❌ Don't use `get cdp-url` for the reuse-orphan responsiveness probe — it auto-launches strays
      (P1.M4.T3.S1 research §2). Use pool_daemon_connected (read-only).
- ❌ Don't call `pool_lane_is_stale` bare — rc 1/2 ABORT under set -e. Use `if …; then` (rc 0 = stale).
- ❌ Don't write `local x="$(…)"` — `local` masks errexit (BashFAQ 105). Split into `local x; x="$(…)"`.
- ❌ Don't `rm -rf` a path read directly from a lease — reconstruct `$POOL_EPHEMERAL_ROOT/$lane` + prefix-guard.
- ❌ Don't use `pool_lease_update` for the adoption — it's top-level-only; use a direct jq `.owner={…}` mutation + _pool_atomic_write.
- ❌ Don't `pool_die` on the exhaustion path — return 1 (the M5.T4 signal). Reserve pool_die for genuine corruption (a lease-write FS failure).
- ❌ Don't rename `pool_acquire_locked` — the item CONTRACT names it exactly.
- ❌ Don't touch any existing function (esp. pool_chrome_kill / pool_wait_cdp / pool_lease_write / pool_lane_is_stale).
- ❌ Don't implement the post-lock boot (S2), the exhaustion wait-loop (M5.T4), the public release
      (M5.T2.S1), or the standalone reap/reuse (M5.T3.*) — they are separate items. This task ships
      pool_acquire_locked + the shared release kernel + adoption helper ONLY.
- ❌ Don't add a `trap` to release the flock — the `( … ) 9>file` subshell auto-releases on exit (research §1.2).

---

## Confidence Score

**9/10** for one-pass implementation success.

**Why 9**: the flock + `set -euo pipefail` semantics are **HOST-VERIFIED** (research §1: blocking
`flock 9` returns 0; lock auto-releases on subshell exit incl. SIGKILL; parent functions inherited
by subshells; the `local var=$(...)` masking gotcha). Every composed function's rc convention is
quoted from the LANDED docstrings (research §3 table: pool_lane_is_stale TRI-STATE 0/1/2;
pool_find_free_lane always rc 0; pool_lease_write 11-arg order + `connected` literal; pool_lease_update
top-level-only ⇒ adoption needs a jq mutation; pool_chrome_kill idempotent + handles 0/0;
pool_daemon_connected/connect from the parallel P1.M4.T3.S1 contract). The cross-dependency
(M5.T2.S1 not landed) is **resolved explicitly** by defining the release kernel here (research §0),
with a clear contract that M5.T2.S1 composes it. The rm-rf safety guard, the short-section budget,
and the provisional-vs-adopted output contract are all spelled out with copy-pasteable validation
(including a REAL-Chrome reuse-orphan test and an `/etc`-untouched guard test).

**Why not 10**: (1) reuse-orphan adoption relies on `pool_daemon_connected` returning 0 for an
orphan's session — verified for the present/absent cases in P1.M4.T3.S1 but the orphan scenario
(dead owner, live Chrome, lingering session binding) depends on the daemon's exact session-list +
close semantics after the owner died, which the M4.T3.S1 research verified for related but not
identical cases; scenario 4 in validation exercises it against a real Chrome. (2) The `POOL_OWNER_PID==0 ⇒ rc 1`
defensive gate means a TRUE all-live-owners rc-1 cannot be unit-tested without unbounded lanes (the
real exhaustion rc-1 path is exercised via M5.T4's timeout wrapper, not this function alone) —
scenario 5 tests the passthrough gate instead. (3) `_pool_adopt_lane` writes `POOL_OWNER_STARTTIME`
via `--argjson` with a `${…:-0}` default; if pool_owner_resolve left it empty in an edge case, the
lease would store starttime:0 (harmless — the lane is "mine" by pid+comm, and the next stale-check
would catch a mismatch); the default is documented.
