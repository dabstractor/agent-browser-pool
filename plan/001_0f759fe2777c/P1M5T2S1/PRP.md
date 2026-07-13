# PRP — P1.M5.T2.S1: `pool_release_lane` — kill pgroup + disconnect daemon + rm dir + delete lease

---

## Goal

**Feature Goal**: Implement **`pool_release_lane(lane)`** — the PUBLIC teardown function that
fully releases one lane: **kill the Chrome process group, disconnect the daemon session,
remove the ephemeral dir, and delete the lease file**. This is PRD §2.5 "Release semantics"
made concrete — the "kill pgroup, `rm -rf` ephemeral dir, delete lease" teardown PLUS the
daemon-session disconnect (CONTRACT step 3d) that the LANDED internal kernel deliberately
omits. It is the single idempotent, non-fatal entry point every release path calls.

The function implements the item CONTRACT verbatim, in spirit:
**a.** read the lease for lane N; if no lease → already released → **return 0**;
**b.** extract `session` (the ONE field the kernel does not read);
**c+d.** **disconnect** the daemon (`$POOL_REAL_BIN --session "$session" close 2>/dev/null || true`)
— run BEFORE the kill (graceful detach while the Chrome may still be reachable; ordering is
immaterial — host-verified §3);
**e+f+g.** **delegate** to the LANDED `_pool_release_lane_internals "$lane"` which does the
KILL (`pool_chrome_kill` pgroup teardown) + RM DIR (prefix-guarded `rm -rf`) + DELETE LEASE
(`rm -f`); **return 0**.

**Deliverable**: One PUBLIC function `pool_release_lane(LANE)`, appended to `lib/pool.sh`
under a new banner **`# Release & teardown (P1.M5.T2.S1)`** directly AFTER `pool_ensure_connected`
(the current EOF, the M5.T1.S3 deliverable @ line 2288, closing brace @ line 2385). **Pure
addition: no edits to any existing function, no new private helpers, no new env-vars, no new
files, no flock.** It COMPOSES the LANDED `_pool_release_lane_internals` kernel (M5.T1.S1) +
reads the `session` field via `pool_lease_read` + one jq fork + calls the daemon `close`.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, given a
  **fully-booted** lane 1 (written by `pool_boot_lane`: real `port>0`, `chrome_pid>0`,
  `chrome_pgid>0`, `connected:true`, a live Chrome pgroup, a bound daemon `abpool-1`), calling
  `pool_release_lane 1` returns **0**, and afterwards: (a) the Chrome pgroup is **dead**
  (`curl /json/version` on the port fails; zero chrome procs for the pgroup), (b) the ephemeral
  dir `$POOL_EPHEMERAL_ROOT/1` is **gone**, (c) the lease file `$POOL_LANES_DIR/1.json` is
  **gone** (`pool_lease_exists 1` returns 1; `pool_find_free_lane` may return 1), (d) the daemon
  session `abpool-1` was **disconnected** (the `close` was invoked; rc 0).
- **Idempotent — no lease**: `pool_release_lane 99` (no `lanes/99.json`) returns **0** as a clean
  no-op (no Chrome/dir/lease touched).
- **Idempotent — double release**: release lane 1, then `pool_release_lane 1` again → both
  return **0**; the second is a clean no-op (lease already gone → step a returns 0).
- **Idempotent — partially-released lane**: kill lane 1's Chrome manually (leave the lease +
  dir), then `pool_release_lane 1` → returns **0**; the (already-dead) Chrome kill is a no-op;
  the dir + lease are removed. (`pool_chrome_kill` is idempotent via `|| true`.)
- **Provisional lease (port:0, chrome_pid:0, chrome_pgid:0)**: `pool_release_lane 1` on a
  provisional claim (never booted) → returns **0**; `pool_chrome_kill 0 0` is a safe no-op; the
  dir (if it exists) + lease are removed; the daemon `close` runs (rc 0, host-verified on a
  never-connected session).
- **Bad lane input**: `pool_release_lane "abc"` → returns **0** (validate, no-op);
  `pool_release_lane ""` → returns **0**.
- **Non-fatal always**: `pool_release_lane` NEVER calls `pool_die` and NEVER returns non-zero.
  Even a missing `POOL_REAL_BIN` or a transient `close`/kill/rm failure degrades to a graceful
  skip (every subprocess is `2>/dev/null || true`; the kernel is non-fatal).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M5.T1.S3) unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its consumers (per the
item CONTRACT §4, all OUTSIDE the flock — see Context §"Known Gotchas" + research §5):

- **M5.T3.S1 `pool_reap_stale`** — the lazy reaper (PRD §2.10). Scans every lane; for each
  stale one (`pool_lane_is_stale` rc 0) calls `pool_release_lane "$n"`. The reaper gets the
  FULL teardown incl. daemon disconnect (unlike acquire's in-lock REAP-STALE which uses the
  private kernel directly — see GOTCHA).
- **M7.T3.S1 `pool_admin_release`** — the `agent-browser-pool release [<N>|all]` CLI (PRD
  §2.12 / §2.5 "Explicit release" row). Calls `pool_release_lane "$N"` (or iterates all lanes).
- **M5.T4.S1 exhaustion force-reap** — PRD §2.9 / §2.5 "Pool-exhaustion" row: when the pool is
  full of dead-owner lanes and a new acquire blocks to timeout, force-release the oldest
  dead-owner lane (`pool_release_lane "$oldest"`), then proceed (and ALERT — a leak signal).
- **(NOT M5.T1.S1 acquire REAP-STALE)** — the LANDED acquire critical section calls the PRIVATE
  `_pool_release_lane_internals` directly (inside the short flock), NOT this public function
  (the `close` subprocess is forbidden under the short flock — PRD §2.19). This is the designed
  split; see "Why".

**Use Case**: A pi agent finishes a task and exits. Its owning process dies. The NEXT acquire
detects the dead owner (`pool_lane_is_stale`) and the reaper (`pool_reap_stale`) calls
`pool_release_lane "$N"` — the Chrome pgroup is killed, the daemon detached, the ephemeral dir
removed, the lease deleted, and lane N is free for the next agent. OR an admin runs
`agent-browser-pool release 3` to explicitly tear down a misbehaving lane. Either way the lane
is fully + idempotently reclaimed.

**Pain Points Addressed**:
- **Chrome renderers/GPU/utility children leak if you only kill the main pid.** `pool_chrome_kill`
  (via the kernel) SIGTERM→SIGKILLs the whole process group (`kill -- -<pgid>`) — no orphans.
- **The daemon holds a binding to a dead Chrome.** The public `close` step detaches it cleanly
  (graceful, host-verified rc 0). Without it the session lingers bound to a dead Chrome (harmless
  on re-acquire because `connect` re-binds, but the explicit disconnect is the contract + hygiene).
- **Partial releases must not crash the pool.** Every step is idempotent + non-fatal
  (`2>/dev/null || true`); a re-release or a kill of an already-dead Chrome is a clean no-op.
- **No double source of truth.** Delegating kill+rm+lease to the LANDED kernel (M5.T1.S1 contract)
  keeps the carefully prefix-guarded `rm -rf` logic in ONE place.

## Why

- **This IS PRD §2.5 "Release semantics".** Every release trigger (owner exit / explicit
  `release` / exhaustion force-reap) routes here for "kill pgroup, `rm -rf` ephemeral dir,
  delete lease" + the daemon disconnect.
- **The M5.T1.S1 contract MANDATES delegation.** The completed acquire PRP states verbatim:
  "M5.T2.S1's public `pool_release_lane()` will **compose** `_pool_release_lane_internals`
  rather than duplicate it." A standalone re-implementation would violate that contract and
  duplicate the kernel's prefix-guarded `rm -rf` + pgroup-kill logic. This PRP delegates.
- **The daemon `close` is the ONE step the kernel omits — by design.** `pool_chrome_kill`'s
  docstring (M4.T3.S1) explicitly defers it: "Daemon/session disconnect is … release's
  lease-delete (M5.T2.S1). Scope: kill the Chrome tree." The kernel is Chrome+dir+lease ONLY
  (it runs inside the short acquire flock where subprocesses are forbidden). The PUBLIC release
  runs OUTSIDE the flock and adds the `close`. This is the designed split.
- **Idempotency is non-negotiable.** The reaper iterates many possibly-dead lanes; the admin
  may re-release; exhaustion force-reaps under pressure. One already-dead lane must NEVER abort
  the pool under `set -euo pipefail`. Every step is `|| true`; a missing lease is a clean
  `return 0`.

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| booted lane 1 (live Chrome, bound daemon) | `pool_release_lane 1` | **rc 0**; Chrome pgroup DEAD; `$EPHEMERAL_ROOT/1` GONE; `$LANES_DIR/1.json` GONE; daemon `abpool-1` close invoked (rc 0) |
| no lease (lane 99) | `pool_release_lane 99` | **rc 0** (clean no-op; nothing touched) |
| double release (lease already gone) | `pool_release_lane 1` ×2 | **rc 0**, **rc 0** (2nd is a no-op) |
| Chrome already dead, lease+dir exist | `pool_release_lane 1` | **rc 0**; kill is a no-op; dir + lease removed; close invoked (rc 0 on dead-chrome session — host-verified) |
| provisional lease (port:0, chrome_pid:0) | `pool_release_lane 1` | **rc 0**; `pool_chrome_kill 0 0` no-op; dir + lease removed; close invoked (rc 0 on never-connected session — host-verified) |
| non-numeric lane | `pool_release_lane "abc"` | **rc 0** (validate, no-op) |
| empty lane | `pool_release_lane ""` | **rc 0** (validate, no-op) |
| `POOL_REAL_BIN` somehow unset | `pool_release_lane 1` | **rc 0** (close skipped gracefully; kernel still tears down Chrome+dir+lease) |

**Hard invariants** (every row):
- **`pool_release_lane` NEVER calls `pool_die` and NEVER returns non-zero.** It is NON-FATAL
  always (the kernel is non-fatal; `close` + every guard is `|| true`). It runs in reap loops /
  admin / exhaustion where one bad lane must never abort the pool.
- **DELEGATE — do NOT duplicate.** The kill (pool_chrome_kill pgroup teardown) + rm dir
  (prefix-guarded) + rm lease happen via `_pool_release_lane_internals "$lane"`. Do NOT
  re-implement them. (M5.T1.S1 contract.)
- **Read `session` BEFORE delegating.** The kernel DELETES the lease (its step 5); after
  delegation `pool_lease_read`/`pool_lease_field` would return "no lease". So extract `session`
  up front, run `close`, THEN delegate.
- **`close` runs BEFORE the kill** (graceful daemon detach while the Chrome may still be
  reachable). Ordering kill↔close is IMMATERIAL — host-verified rc 0 either way, `close` is
  disconnect-only (Chrome survives it), `close` launches NO strays (research §3). The CONTRACT's
  literal order (c. KILL → d. DISCONNECT) is swapped to (d → c); this is justified by DRY
  delegation (the kernel bundles kill+rm+rmlease) + graceful detach. **Document the swap; do not
  hide it.**
- **`close 2>/dev/null || true`** — `close` rc is ALWAYS 0 on agent-browser 0.28.0 (host-verified
  on fresh/live/dead/repeated sessions), but the guard is kept (future-proof + the idempotency
  mechanism + documents non-fatal intent).
- **NO flock.** Release is lane-local + idempotent; every kill/rm/close is `|| true`, so a
  concurrent acquire's in-lock reap of the SAME lane is a harmless idempotent no-op. Flocking is
  the CALLER's concern (the caller may take `pool_acquire_locked`'s flock if it wants exclusion —
  none of the real consumers do).
- **Defensive `session` reconstruct.** If `.session` is empty OR literal `"null"` (jq -r on a
  missing field), reconstruct as `"abpool-$lane"` (deterministic from the lane number; matches
  the S3 `pool_ensure_connected` convention). The session name is ALWAYS `abpool-<N>`.
- **Every `local` capture is split** (`local X; X="$(…)"` — BashFAQ 105 / SC2155) and the
  non-fatal rc-1 helper `pool_lease_read` is guarded with `if ! …; then return 0; fi`.

### Success Criteria

- [ ] `pool_release_lane` defined in `lib/pool.sh` under a `# Release & teardown (P1.M5.T2.S1)`
      banner, appended after `pool_ensure_connected`. Callable after `source lib/pool.sh` +
      `pool_config_init`.
- [ ] Happy path: booted lane → rc 0; Chrome dead; dir gone; lease gone; daemon close invoked.
- [ ] Idempotent no-lease: lane 99 → rc 0 (no-op).
- [ ] Idempotent double-release: rc 0, rc 0.
- [ ] Partial release (Chrome already dead): rc 0; dir + lease removed.
- [ ] Provisional lease (port:0, chrome_pid:0): rc 0; no-op kill; dir + lease removed.
- [ ] Bad/empty lane input → rc 0 (validate, no-op).
- [ ] Non-fatal always: never `pool_die`, never non-zero.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1–M5.T1.S3) unchanged and callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **delegate-design contract**
(research §1 — the M5.T1.S1 PRP's verbatim "compose, don't duplicate" mandate); the **kernel
body** this task delegates TO (research §2 — exact steps + the fact it does NOT read `session`
nor call `close`); the **HOST-VERIFIED `close` semantics** (research §3 — rc always 0,
disconnect-only, no strays, session lingers); the **composition order decision** (research §4
— why `close` before delegation + why the CONTRACT's c↔d swap is immaterial); the **flock
verdict** (research §5 — no flock, lane-local + idempotent); the **lease schema + session
read** (research §6); the **bash set -e gotchas** (research §7); the **full verbatim-ready
implementation** (Implementation Tasks Task 1); and copy-pasteable, host-verified validation
commands (a real-Chrome happy path, a no-lease idempotency test, a double-release test, a
partial-release test, a provisional-lease test, and a re-acquire-freed-lane integration test).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.5 (Release semantics — the "kill pgroup, rm -rf ephemeral dir, delete lease" teardown
        + the explicit-release row; "`agent-browser close` (mid-task) = disconnect-only"). §2.8
        (lease schema — `session` is a top-level field, value `abpool-<N>`). §2.4 step 3d
        (`session=abpool-<N>` set at CLAIM). §2.19 (flock = SHORT, ACQUIRE-ONLY — release runs
        outside it). §2.6 (setsid → pgid==pid → `kill -- -<pgid>` tears down the whole tree).
        §2.10 (lazy reaper — release is called on acquire + on-demand reap). §2.9 (exhaustion
        force-reap).
  pattern: §2.5's teardown IS pool_release_lane; §2.8's session IS the close arg.
  gotcha: §2.5's table does NOT list the daemon close (PRD lists "kill+rm+rmlease" only) — the
        CONTRACT step 3d ADDS the close (the kernel omits it; this public function adds it).

- file: plan/001_0f759fe2777c/P1M5T1S1/PRP.md   # the COMPLETED acquire PRP — the delegate CONTRACT
  why: states verbatim: "M5.T2.S1's public pool_release_lane() will COMPOSE
        _pool_release_lane_internals rather than duplicate it (documented as a contract below).
        This unblocks the circular acquire↔release dependency." + the Integration Points:
        "M5.T2.S1: public pool_release_lane COMPOSES _pool_release_lane_internals (no duplication)."
  pattern: DELEGATE — this task's whole shape follows from that one mandate.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (short flock — claim under flock, launch/teardown AFTER; ⇒ release's close
        subprocess runs OUTSIDE the flock). FINDING 6 (setsid → pgid==pid; `kill -- -<pgid>`
        signals the whole process group). FINDING 7 (atomic lease write: tmp in SAME dir + mv).

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M5T2S1/research/release-lane-delegate-design.md
  why: §1 (the delegate CONTRACT quotes); §2 (the kernel body this task delegates to — esp. that
        it does NOT read `session` nor call `close`); §3 (HOST-VERIFIED `close` semantics — rc
        always 0, disconnect-only, no strays, session lingers); §4 (the composition-order
        decision — close-before-delegate, why the c↔d swap is immaterial); §5 (no flock); §6
        (session read + defensive reconstruct); §7 (set -e gotchas); §9 (decisions table).
  pattern: §4 IS the implementation spine; §2 IS the kernel contract.
  gotcha: §3 (close rc always 0 / disconnect-only / no strays) + §2 (kernel omits session+close)
        are the two highest-impact facts.

# HOST-VERIFIED external evidence (the daemon primitives + close semantics)
- file: plan/001_0f759fe2777c/P1M4T3S1/research/daemon-connect-teardown-host-verified.md
  why: §3 (session list is READ-ONLY; a session LINGERS after `close` — harmless); §5
        (process-group teardown via `kill -- -<pgid>` — every kill needs `2>/dev/null || true`
        because kill on an already-dead target returns rc 1 / ESRCH and ABORTS under set -e); §1
        (connect is idempotent/re-bindable — ⇒ a lingering session is harmless on re-acquire).
  pattern: §5 IS the idempotency mechanism (`|| true`, not a kill -0 pre-check).

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M5T1S1/PRP.md   # _pool_release_lane_internals (M5.T1.S1 — LANDED @1813)
  why: the KERNEL this task delegates to. Body: read lease (rc1⇒return0) → ONE jq fork
        (.chrome_pid,.chrome_pgid,.ephemeral_dir — NOTE: NOT .session) → pool_chrome_kill →
        prefix-guarded rm -rf $POOL_EPHEMERAL_ROOT/$lane (+ defense-in-depth 2nd block) → rm -f
        $POOL_LANES_DIR/$lane.json → return 0 ALWAYS (non-fatal). It does NOT call the daemon close.
- file: plan/001_0f759fe2777c/P1M4T3S1/PRP.md   # pool_chrome_kill (M4.T3.S1 — LANDED @1757)
  why: the kill primitive the kernel composes. pool_chrome_kill(chrome_pid, chrome_pgid):
        SIGTERM pgroup → sleep 0.5 → SIGKILL pgroup → bare-pid fallback; numeric guards skip
        0/0 (provisional); every kill `2>/dev/null || true`; returns 0 ALWAYS. Chrome-teardown
        ONLY (its docstring: do NOT call close here).
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_read (M3.T1.S2 — LANDED @823)
  why: read the lease → json. pool_lease_read(lane): echoes raw JSON / rc 0; rc 1 missing/corrupt
        (NON-FATAL). The caller MUST guard under set -e: `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi`.
- file: plan/001_0f759fe2777c/P1M5T1S3/PRP.md   # pool_ensure_connected (M5.T1.S3 — LANDED @2288, CURRENT EOF)
  why: (1) it is the CURRENT EOF — this task APPENDS after it. (2) its defensive `session`
        reconstruct convention: `[[ -n "$session" ]] || session="abpool-$lane"` (mirror this).

# External authoritative docs (for the WHY; behavior is HOST-VERIFIED in research §3)
- url: https://man7.org/linux/man-pages/man2/kill.2.html
  why: kill(2) on an already-dead target returns ESRCH (rc 1 in the shell) → under set -e a bare
        `kill` ABORTS the caller. This is why pool_chrome_kill (via the kernel) uses
        `2>/dev/null || true` on EVERY signal — and why this task's `close` uses the same guard.
  section: ERRORS (ESRCH).
- url: https://agent-browser.dev   # the wrapped CLI's docs (close = "Close the browser instance for the current session"; aliases quit/exit)
  why: documents `agent-browser --session <name> close`. NOTE: on 0.28.0 the BEHAVIOR is
        disconnect-only (Chrome survives close) despite the "Close the browser" wording —
        host-verified in research §3. The pool relies on pool_chrome_kill (the pgroup kill) to
        actually terminate Chrome, NOT on close.
```

### Current Codebase tree

After **M1–M5.T1.S3** have landed, `lib/pool.sh` (2385 lines) ends with `pool_ensure_connected`
as the final function (@2288, closing brace @2385):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T1.S3) with pool_ensure_connected at EOF.
│                                         #   Banner order at EOF:
│                                         #   ... pool_chrome_launch + pool_wait_cdp (M4.T2.S2)
│                                         #   # Lane lifecycle — daemon connect, verify & teardown (M4.T3.S1)
│                                         #   pool_daemon_connect / pool_daemon_connected / pool_chrome_kill
│                                         #   # Acquire — flock critical section (M5.T1.S1)
│                                         #   _pool_release_lane_internals / _pool_adopt_lane
│                                         #   / _pool_acquire_critical_section / pool_acquire_locked
│                                         #   # Acquire — post-lock boot (M5.T1.S2)
│                                         #   _pool_boot_write_chrome_ids / _pool_launch_and_verify / pool_boot_lane
│                                         #   # Acquire — ensure connected (M5.T1.S3)
│                                         #   pool_ensure_connected  ← current EOF (closing brace @2385)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T1S3/PRP.md
    └── P1M5T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/release-lane-delegate-design.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND ONE function under a new banner AFTER pool_ensure_connected (EOF):
                  #   # Release & teardown (P1.M5.T2.S1)
                  #   pool_release_lane(lane):   # PUBLIC — the CONTRACT name
                  #       a. validate lane (^[0-9]+$) else return 0
                  #       b. pool_lease_read "$lane" → json; rc 1 (missing/corrupt) → return 0 (idempotent)
                  #          session = jq -r '.session' (defensive reconstruct → "abpool-$lane")
                  #       c. DISCONNECT daemon: $POOL_REAL_BIN --session "$session" close 2>/dev/null || true
                  #         (graceful detach; runs BEFORE the kill — order immaterial, host-verified)
                  #       d. _pool_release_lane_internals "$lane"   ← KILL pgroup + RM DIR + RM LEASE (DRY)
                  #       e. _pool_log …; return 0
                  #   (NO changes to any existing function — esp. NOT _pool_release_lane_internals /
                  #    pool_chrome_kill / pool_lease_read / pool_ensure_connected)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**public release** entry point (PRD §2.5) — the idempotent, non-fatal teardown that kills the
Chrome pgroup, disconnects the daemon, removes the ephemeral dir, and deletes the lease. It
COMPOSES the LANDED `_pool_release_lane_internals` kernel (kill+rm+rmlease) + adds the ONE
daemon-`close` step the kernel omits. It reads `POOL_REAL_BIN` (for the close subprocess) +
`POOL_LANES_DIR` (via the kernel + pool_lease_read). It writes nothing new (the kernel does the
rm; close is a daemon side-effect).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (DELEGATE — do NOT duplicate the kernel — research §1 / M5.T1.S1 contract): the
#   completed acquire PRP states verbatim: "M5.T2.S1's public pool_release_lane() will COMPOSE
#   _pool_release_lane_internals rather than duplicate it." The kernel already does the
#   pgroup-kill (pool_chrome_kill) + the prefix-guarded rm -rf + the rm -f lease — all idempotent +
#   non-fatal. Re-implementing them would (a) violate the M5.T1.S1 contract, (b) duplicate the
#   carefully safety-guarded rm logic, (c) risk divergence. CALL _pool_release_lane_internals "$lane".

# CRITICAL (the kernel does NOT read `session` NOR call `close` — research §2): the LANDED kernel
#   extracts ONLY .chrome_pid, .chrome_pgid, .ephemeral_dir (its jq fork). It has NO daemon close.
#   The public function MUST read .session ITSELF (before delegating — the kernel deletes the lease)
#   and invoke the close. This is the ONE step the public layer adds (pool_chrome_kill's docstring
#   defers it: "Daemon/session disconnect is … release's lease-delete (M5.T2.S1)").

# CRITICAL (read `session` BEFORE delegating — research §2/§6): the kernel's step 5 is
#   `rm -f $POOL_LANES_DIR/$lane.json`. After delegation the lease is GONE, so pool_lease_read /
#   pool_lease_field would return "no lease". Extract session up front, run close, THEN delegate.

# CRITICAL (`close` runs BEFORE the kill — research §3/§4, HOST-VERIFIED): the CONTRACT literal
#   order is c.KILL → d.DISCONNECT. This PRP swaps to d → c (close → delegate[kill+rm+rmlease]).
#   WHY: (1) graceful daemon detach while the Chrome may still be reachable (cleaner); (2) the
#   session read happens up front and close naturally follows it; (3) the kernel BUNDLES
#   kill+rm+rmlease as one delegated unit, so close-after-delegate would mean closing a session
#   bound to an already-dead Chrome (works but less clean). THE SWAP IS IMMATERIAL: `close` is
#   disconnect-only (Chrome survives it — host-verified EXP2), `close` rc is ALWAYS 0 (host-verified
#   on fresh/live/dead/repeated sessions), and `close` launches NO strays (host-verified: chrome proc
#   count unchanged 2→2). DOCUMENT the swap in the function docstring; do not hide it.

# CRITICAL (close rc is ALWAYS 0 on agent-browser 0.28.0 — research §3, HOST-VERIFIED): but KEEP
#   `2>/dev/null || true`. It is (1) future-proof (a future version could change the rc), (2) the
#   idempotency mechanism (a 2nd release re-closes harmlessly), (3) documents the non-fatal intent.
#   close is DISCONNECT-ONLY — it does NOT kill the Chrome (EXP2: chrome still alive after close);
#   the pool relies on pool_chrome_kill (the pgroup kill) to terminate Chrome. close does NOT launch
#   strays (unlike `get cdp-url` — M4.T3.S1 research §2). The session LINGERS in `session list`
#   after close (harmless — re-acquire re-binds via idempotent connect, M4.T3.S1 §1).

# CRITICAL (NO flock — research §5): pool_release_lane does NOT acquire the lock. Rationale:
#   release is lane-local + idempotent (kill a specific pid, rm a specific dir, rm a specific lease);
#   every kill/rm/close is `2>/dev/null || true`, so a concurrent acquire's in-lock reap of the SAME
#   lane is a harmless idempotent no-op. Flocking is the CALLER's concern (the reaper/admin/exhaustion
#   may take pool_acquire_locked's flock if they want exclusion — none do). The kernel itself is
#   flock-agnostic (called both inside + outside the acquire lock).

# CRITICAL (NON-FATAL always — never pool_die, never non-zero — research §7/§8): pool_release_lane
#   runs in reap loops / admin / exhaustion where one bad lane must never abort the pool under
#   `set -euo pipefail` (lib/pool.sh line 17). The kernel returns 0 always; close is `|| true`; a
#   missing lease → return 0; a bad lane → return 0. Do NOT add any path that could return non-zero
#   or call pool_die.

# CRITICAL (`local var=$(...)` masks errexit — research §7 / BashFAQ 105 / SC2155): `local X="$(…)"`
#   — local returns 0 always, so set -e does NOT fire on a failing $(…). EVERY capture MUST be split:
#       local json session
#       json="$(pool_lease_read "$lane" 2>/dev/null)"
#   Applies to pool_lease_read + the jq capture.

# CRITICAL (pool_lease_read returns 1 on missing/corrupt — NON-FATAL — research §7): a BARE call
#   ABORTS under set -e. Guard with the idempotent-return pattern (mirror the kernel exactly):
#       if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi
#   (the `if !` is errexit-exempt; `return 0` = idempotent no-op — "already released").

# CRITICAL (POOL_REAL_BIN under set -u — research §7): `"$POOL_REAL_BIN"` with the global UNSET is an
#   unbound-variable error BEFORE the command runs (not catchable by the command's `|| true`). It IS
#   set by pool_config_init (precondition), but release is non-fatal — guard with default-expansion:
#       if [[ -n "${POOL_REAL_BIN:-}" ]]; then "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true; fi
#   (If unset, skip close gracefully — the kernel still tears down Chrome+dir+lease.)

# GOTCHA (defensive `session` reconstruct — research §6): jq -r on a MISSING field outputs the
#   literal string "null". So guard BOTH empty AND "null", reconstruct as "abpool-$lane":
#       [[ -n "$session" && "$session" != "null" ]] || session="abpool-$lane"
#   The session name is deterministic from the lane number (PRD §2.4 step 3d). Matches the S3
#   pool_ensure_connected convention.

# GOTCHA (the kernel RE-READS the lease internally): do NOT worry that your up-front read + the
#   kernel's read "double-read" — lease reads are ONE tiny file + ONE jq fork, cheap, and release is
#   NOT the hot path (it runs on owner exit / explicit release / reap, not every invocation). The
#   kernel is self-contained by design (M5.T1.S1); do not "optimize" by inlining the kill/rm.

# GOTCHA (naming + placement — research §8): pool_release_lane (PUBLIC, CONTRACT name, NO `_`
#   prefix). Pairs with the private _pool_release_lane_internals kernel. NO new private helpers
#   (the body is ~10 lines; fragmenting it would hurt readability). APPEND at EOF after
#   pool_ensure_connected. Do NOT touch any existing function.

# GOTCHA (scope — release ONLY): do NOT implement reap_stale (M5.T3), admin release (M7.T3),
# exhaustion force-reap (M5.T4), or the wrapper (M6). Do NOT add a flock. Do NOT touch the kernel.
# Do NOT add new env vars / globals. This task ships pool_release_lane ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**.
It reads the lease schema (PRD §2.8, frozen by M3.T1.S1) — specifically the top-level `session`
field — and delegates all destructive work (kill + rm dir + rm lease) to the LANDED kernel.

Global READ (frozen by `pool_config_init`):

| global | source | example | role |
|---|---|---|---|
| `POOL_REAL_BIN` | pool_config_init (env `AGENT_BROWSER_REAL`) | `/home/dustin/.local/bin/agent-browser` | the daemon `close` subprocess (`"$POOL_REAL_BIN" --session "$session" close`) |
| `POOL_LANES_DIR` | pool_config_init | `…/agent-browser-pool/lanes` | lease `<N>.json` (read via pool_lease_read; deleted by the kernel) |
| `POOL_EPHEMERAL_ROOT` | pool_config_init | `…/active` | the kernel reconstructs `$ROOT/$lane` for the rm (NOT read directly here) |

External commands (verified present this session + host-verified for `close`): `agent-browser`
(`$POOL_REAL_BIN` — the `close` subcommand, rc always 0 on 0.28.0), `jq` (the `.session`
extract), `rm`/`kill` (inside the kernel). All present on host.

**Naming** (CONTRACT-mandated + codebase convention): `pool_release_lane` (public, CONTRACT
name, no `_`). **No private helpers** — the body is ~10 lines + linear; delegating to the kernel
keeps it short. Fragmenting into `_pool_*` helpers would hurt readability.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init \
                  pool_lease_read _pool_release_lane_internals _pool_log'
  - EXPECT: all reported as functions (M1–M5.T1.S1 LANDED). If _pool_release_lane_internals is
        MISSING → STOP (the delegate target does not exist). If pool_release_lane (no `_`)
        ALREADY EXISTS → STOP (someone implemented it already; reconcile).
  - RUN (verify the globals + host facts this task depends on):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_REAL_BIN" && -n "$POOL_LANES_DIR" ]] && echo "OK globals" || echo FAIL'
        command -v agent-browser >/dev/null && echo "OK agent-browser" || echo FAIL
        command -v jq >/dev/null && echo "OK jq" || echo FAIL
        [[ -x "$HOME/.local/bin/agent-browser" ]] && echo "OK real-bin" || echo FAIL
  - EXPECT: OK globals ; OK agent-browser ; OK jq ; OK real-bin.
  - RUN (locate the append point — current EOF must be pool_ensure_connected):
        grep -nE '^pool_ensure_connected\(\)' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        # ALSO confirm the public name does NOT yet exist:
        grep -nE '^pool_release_lane\(\)' lib/pool.sh && echo "STOP: already exists" || echo "OK: absent"
  - EXPECT: pool_ensure_connected defined (@2288); it is the last function (closing brace @2385).
        APPEND the new banner + the function AFTER its closing brace. pool_release_lane ABSENT.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_release_lane() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_ensure_connected's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block, then adapt commentary to codebase style):
        # =============================================================================
        # Release & teardown (P1.M5.T2.S1)
        # =============================================================================
        # PRD §2.5 "Release semantics" — the PUBLIC, idempotent, non-fatal teardown that fully
        # releases one lane: disconnect the daemon session, kill the Chrome process group, remove
        # the ephemeral dir, delete the lease. Consumed by the reaper (M5.T3 reap_stale), the admin
        # CLI (M7.T3 release [<N>|all]), and exhaustion force-reap (M5.T4). NOT used by acquire's
        # in-lock REAP-STALE (that calls the private kernel directly — the close subprocess is
        # forbidden under the short acquire flock, PRD §2.19).
        #
        # DESIGN — DELEGATE (M5.T1.S1 contract): the completed acquire PRP states verbatim:
        #   "M5.T2.S1's public pool_release_lane() will COMPOSE _pool_release_lane_internals
        #    rather than duplicate it." So the KILL (pool_chrome_kill pgroup teardown) + RM DIR
        #   (prefix-guarded rm -rf) + RM LEASE (rm -f) all happen via _pool_release_lane_internals.
        #   The ONE step this public layer adds — that the kernel deliberately omits (per
        #   pool_chrome_kill's docstring: "Daemon/session disconnect is … release's lease-delete
        #   (M5.T2.S1)") — is the daemon `close`.
        #
        # LOGIC (CONTRACT 3a→3g; the c↔d order is swapped — see GOTCHA — immaterial, host-verified):
        #   a. validate lane (^[0-9]+$) else return 0 (path-traversal defense).
        #   b. pool_lease_read "$lane" → json. rc 1 (missing/corrupt) ⇒ already released ⇒ return 0
        #      (idempotent). Extract session (the ONE field the kernel does not read). Defensive
        #      reconstruct → "abpool-$lane" if empty/null.
        #   c. DISCONNECT daemon: $POOL_REAL_BIN --session "$session" close 2>/dev/null || true.
        #      Run BEFORE the kill (graceful detach while the Chrome may still be reachable).
        #   d. _pool_release_lane_internals "$lane" → KILL pgroup + RM DIR + RM LEASE (the kernel,
        #      non-fatal, idempotent). It re-reads the lease + does all destructive work.
        #   e. _pool_log … ; return 0.
        #
        # CALLER CONTRACT (the reaper M5.T3 / admin M7.T3 / exhaustion M5.T4, under set — e):
        #     for n in $(pool_lanes_list); do
        #         if pool_lane_is_stale "$n"; then pool_release_lane "$n"; fi   # rc 0 always
        #     done
        #   OR explicit: pool_release_lane "$N". No flock needed (lane-local + idempotent).
        #
        # GOTCHA — DELEGATE: do NOT re-implement kill/rm/lease (the kernel does it; duplicating
        #   violates the M5.T1.S1 contract + the prefix-guarded rm logic). Read session, close, delegate.
        # GOTCHA — read session BEFORE delegating: the kernel DELETES the lease; after delegation
        #   pool_lease_read returns "no lease". So extract session up front.
        # GOTCHA — close BEFORE kill (d→c swap vs the literal CONTRACT): graceful detach + the kernel
        #   bundles kill+rm+rmlease. IMMATERIAL — close is disconnect-only (Chrome survives it),
        #   rc always 0, no strays (research §3, HOST-VERIFIED on agent-browser 0.28.0).
        # GOTCHA — close 2>/dev/null || true: rc is ALWAYS 0 on 0.28.0, but the guard is future-proof +
        #   the idempotency mechanism + non-fatal intent. close does NOT kill Chrome (pool_chrome_kill
        #   does); the session LINGERS after close (harmless; re-acquire re-binds via connect).
        # GOTCHA — NON-FATAL always: never pool_die, never non-zero. Missing lease ⇒ return 0;
        #   bad lane ⇒ return 0; POOL_REAL_BIN unset ⇒ skip close (kernel still tears down).
        # GOTCHA — NO flock: release is lane-local + idempotent. Flocking is the caller's concern.
        # GOTCHA — every `local` capture is split (BashFAQ 105); pool_lease_read guarded (rc 1 non-fatal).
        # Reads POOL_REAL_BIN (close subprocess) + POOL_LANES_DIR (via helpers). No new globals exported.
        # PRECONDITION: pool_config_init (+ pool_state_init by the caller).
        pool_release_lane() {
            local lane="${1:-}"
            local json session

            # (a) Validate lane (path-traversal defense; a bogus lane "has nothing to release").
            #     `[[ ]] || return 0` is errexit-exempt. Matches the kernel.
            [[ "$lane" =~ ^[0-9]+$ ]] || return 0

            # (b) Read the lease. rc 1 (missing OR corrupt) ⇒ already released ⇒ return 0 (idempotent).
            #     `if !` is errexit-exempt (a bare capture would ABORT under set -e on rc 1).
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                return 0
            fi

            # Extract `session` — the ONE field the kernel does NOT read (needed for the daemon close).
            # jq cannot fail here (valid JSON guaranteed by pool_lease_read's _pool_json_valid). The
            # assignment is split (local declared above) — no SC2155 / errexit masking. jq -r on a
            # missing field outputs the literal "null" → guard both empty AND "null", reconstruct.
            session="$(jq -r '.session' <<<"$json")"
            [[ -n "$session" && "$session" != "null" ]] || session="abpool-$lane"

            # (c) DISCONNECT the daemon session — graceful detach while the Chrome may still be
            #     reachable (close is DISCONNECT-ONLY: it does NOT kill the Chrome — host-verified,
            #     research §3). rc is ALWAYS 0 on agent-browser 0.28.0 (fresh/live/dead/repeated);
            #     `2>/dev/null || true` is future-proof + the idempotency mechanism. The session
            #     LINGERS in the daemon's session list after close (M4.T3.S1 research §3) — harmless:
            #     a re-acquired lane (same N → same abpool-N) re-binds via pool_daemon_connect
            #     (idempotent, M4.T3.S1 research §1). Guard POOL_REAL_BIN (set -u safety; release is
            #     non-fatal — if unset, skip close, the kernel still tears down Chrome+dir+lease).
            if [[ -n "${POOL_REAL_BIN:-}" ]]; then
                "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true
            fi

            # (d) Delegate the Chrome teardown + dir removal + lease deletion to the shared kernel
            #     (M5.T1.S1 contract: COMPOSE, do NOT duplicate). The kernel re-reads the lease,
            #     calls pool_chrome_kill (pgroup SIGTERM→SIGKILL + bare-pid fallback; idempotent),
            #     rm -rf the reconstructed prefix-guarded $POOL_EPHEMERAL_ROOT/$lane, and rm -f the
            #     lease. It returns 0 ALWAYS (non-fatal). So pool_release_lane inherits rc 0.
            _pool_release_lane_internals "$lane"

            _pool_log "pool_release: released lane $lane (daemon session '$session' disconnected, chrome killed, dir+lease removed)"
            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155 + BashFAQ-105); the lease
        read uses ONE jq fork for the single field (the _pool_adopt_lane / S3 idiom); the
        non-fatal rc-1 helper guarded with `if ! …; then return 0; fi`; `_pool_log` one summary
        line; docstring with LOGIC + CALLER CONTRACT + GOTCHA sections (mirror the kernel +
        pool_chrome_kill + pool_ensure_connected).
  - NAMING: pool_release_lane (PUBLIC, CONTRACT name, no `_`). NO private helpers.
  - PLACEMENT: the function in the new "(P1.M5.T2.S1)" banner, after pool_ensure_connected.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN: shellcheck -s bash lib/pool.sh | grep -i 'pool_release_lane' || echo "OK no SC on new fn"
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_release_lane' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: HAPPY PATH — booted lane → rc 0; chrome dead; dir gone; lease gone; close invoked ---
  - RUN (boot a real lane via pool_boot_lane first, then release; isolated state):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Provisional claim → full boot (M5.T1.S1 + M5.T1.S2):
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  port="$(pool_lease_field 1 port)"
                  cpid="$(pool_lease_field 1 chrome_pid)"
                  edir="$(pool_lease_field 1 ephemeral_dir)"
                  # PRE: chrome alive, dir exists, lease exists, session bound:
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK1-pre-chrome-alive" || echo "FAIL1-pre-chrome-dead"
                  test -d "$edir" && echo "OK1-pre-dir" || echo "FAIL1-pre-dir"
                  pool_lease_exists 1 && echo "OK1-pre-lease" || echo "FAIL1-pre-lease"
                  # RELEASE:
                  if pool_release_lane 1; then echo "OK1-rc0"; else echo "FAIL1-rc"; fi
                  # POST: chrome DEAD, dir GONE, lease GONE:
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && echo "FAIL1-chrome-alive" || echo "OK1-chrome-dead"
                  test -d "$edir" && echo "FAIL1-dir" || echo "OK1-dir-gone"
                  pool_lease_exists 1 && echo "FAIL1-lease" || echo "OK1-lease-gone"
                  # no leftover chrome procs for the old pid:
                  ps -p "$cpid" >/dev/null 2>&1 && echo "FAIL1-pid-alive" || echo "OK1-pid-gone"
                  # CLEANUP (defensive — should already be clean):
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK1-pre-chrome-alive ; OK1-pre-dir ; OK1-pre-lease ; OK1-rc0 ;
        #         OK1-chrome-dead ; OK1-dir-gone ; OK1-lease-gone ; OK1-pid-gone.
  #
  # --- SCENARIO 2: IDEMPOTENT — no lease → rc 0 (no-op) ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  if pool_release_lane 99; then echo "OK2-no-lease-rc0"; else echo "FAIL2-no-lease-rc"; fi
                  pool_lease_exists 99 && echo "FAIL2-lease-created" || echo "OK2-no-lease"'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK2-no-lease-rc0 ; OK2-no-lease.
  #
  # --- SCENARIO 3: IDEMPOTENT — double release → rc 0, rc 0 ---
  - RUN (boot, release, release again):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  pool_release_lane 1 && echo "OK3-first-rc0" || echo "FAIL3-first"
                  # Second release — lease already gone → no-op → rc 0:
                  if pool_release_lane 1; then echo "OK3-second-rc0"; else echo "FAIL3-second-rc"; fi
                  pool_lease_exists 1 && echo "FAIL3-lease" || echo "OK3-lease-gone"
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK3-first-rc0 ; OK3-second-rc0 ; OK3-lease-gone.
  #
  # --- SCENARIO 4: PARTIAL RELEASE — Chrome already dead (kill manually), lease+dir remain ---
  - RUN (boot, kill the chrome pgroup manually leaving lease+dir, then release):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  pg="$(pool_lease_field 1 chrome_pgid)"
                  edir="$(pool_lease_field 1 ephemeral_dir)"
                  # Kill the chrome pgroup MANUALLY (simulate PRD §2.14 crash); leave lease + dir:
                  kill -9 -- -"$pg" 2>/dev/null || true; sleep 1
                  test -d "$edir" && echo "OK4-pre-dir" || echo "FAIL4-pre-dir"
                  pool_lease_exists 1 && echo "OK4-pre-lease" || echo "FAIL4-pre-lease"
                  # RELEASE on the partially-released lane (must be idempotent + non-fatal):
                  if pool_release_lane 1; then echo "OK4-rc0"; else echo "FAIL4-rc"; fi
                  test -d "$edir" && echo "FAIL4-dir" || echo "OK4-dir-gone"
                  pool_lease_exists 1 && echo "FAIL4-lease" || echo "OK4-lease-gone"
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK4-pre-dir ; OK4-pre-lease ; OK4-rc0 ; OK4-dir-gone ; OK4-lease-gone.
  #
  # --- SCENARIO 5: PROVISIONAL LEASE (port:0, chrome_pid:0, chrome_pgid:0) → rc 0; no-op kill ---
  - RUN (write a provisional claim, never boot, then release):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Provisional claim (port 0, chrome_pid 0, chrome_pgid 0, connected false):
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
                  pool_lease_exists 1 && echo "OK5-pre-lease" || echo "FAIL5-pre-lease"
                  if pool_release_lane 1; then echo "OK5-rc0"; else echo "FAIL5-rc"; fi
                  pool_lease_exists 1 && echo "FAIL5-lease" || echo "OK5-lease-gone"
                  "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK5-pre-lease ; OK5-rc0 ; OK5-lease-gone.
  #
  # --- SCENARIO 6: BAD / EMPTY lane input → rc 0 (validate, no-op) ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  if pool_release_lane "abc"; then echo "OK6-bad-rc0"; else echo "FAIL6-bad-rc"; fi
                  if pool_release_lane ""; then echo "OK6-empty-rc0"; else echo "FAIL6-empty-rc"; fi
                  if pool_release_lane; then echo "OK6-missing-rc0"; else echo "FAIL6-missing-rc"; fi'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK6-bad-rc0 ; OK6-empty-rc0 ; OK6-missing-rc0.
```

### Implementation Patterns & Key Details

```bash
# The release spine (research §4 — the composition decision):
#   pool_release_lane LANE:
#     validate lane  || return 0
#     read lease     || return 0          # idempotent: missing/corrupt ⇒ already released
#     session = .session (reconstruct → abpool-$LANE if empty/null)
#     $POOL_REAL_BIN --session "$session" close 2>/dev/null || true      # ONE added step (graceful detach)
#     _pool_release_lane_internals "$LANE"                               # KILL + RM DIR + RM LEASE (DRY)
#     _pool_log …; return 0

# The daemon-close guard (set -u safety + non-fatal):
#   if [[ -n "${POOL_REAL_BIN:-}" ]]; then
#       "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true
#   fi
#   # POOL_REAL_BIN is set by pool_config_init (precondition), but release must NEVER fail — if
#   # somehow unset, skip close; the kernel still tears down Chrome+dir+lease.

# The session-extract idiom (split local — no SC2155; guard jq's literal "null"):
#   local json session
#   json="$(pool_lease_read "$lane" 2>/dev/null)"     # inside `if !` — errexit-exempt
#   session="$(jq -r '.session' <<<"$json")"          # jq cannot fail on valid JSON
#   [[ -n "$session" && "$session" != "null" ]] || session="abpool-$lane"
```

### Integration Points

```yaml
LEASE (no schema change — read-only via pool_lease_read; deleted by the kernel):
  - read: session from lanes/<N>.json (pool_lease_read + ONE jq fork for .session)
  - delete: by _pool_release_lane_internals (rm -f $POOL_LANES_DIR/$lane.json)

DAEMON (side-effect — the close):
  - $POOL_REAL_BIN --session <abpool-N> close   (rc 0; disconnect-only; session lingers — harmless)

GLOBALS (no new exports — reads only):
  - POOL_REAL_BIN (the close subprocess; frozen by pool_config_init)
  - POOL_LANES_DIR (via pool_lease_read + the kernel)
  - POOL_EPHEMERAL_ROOT (read ONLY by the kernel for the rm-reconstruct)

CONSUMERS (downstream — NOT this task's concern, documented for context):
  - M5.T3.S1 reap_stale: `for n in $(pool_lanes_list); do pool_lane_is_stale "$n" && pool_release_lane "$n"; done`
  - M7.T3.S1 admin release: `pool_release_lane "$N"` (or iterate all for `release all`)
  - M5.T4.S1 exhaustion force-reap: force `pool_release_lane "$oldest_dead_owner_lane"`, then proceed + ALERT
  - (NOT M5.T1.S1 acquire REAP-STALE — uses the private kernel directly inside the flock.)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after the function is appended — fix before proceeding.
bash -n lib/pool.sh                              # syntax — MUST be clean (zero output)
shellcheck lib/pool.sh                           # whole file — zero warnings
shellcheck -s bash lib/pool.sh | grep -i 'pool_release_lane' || echo "OK no SC on new fn"
# Expected: zero errors/warnings. If any exist, READ the output and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

The project has no bats harness yet (M9.T1.S1). Validate via the **host-verified scenarios in
Task 2** (real Chrome + real agent-browser + isolated state dirs), which exercise every branch:

```bash
# Run each SCENARIO 1–6 from Task 2 in turn. Each is self-contained (mktemp state + EPHEM dirs,
# real master/chrome/agent-browser, cleanup at the end). EXPECT the documented OK* lines.

# Quick smoke (function callable, no-op on a missing lease):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
         if pool_release_lane 999; then echo "OK smoke (rc0 on missing lease)"; else echo "FAIL"; fi'
```

### Level 3: Integration Testing (System Validation)

```bash
# Full acquire → boot → release → re-acquire round-trip (proves release frees the lane for reuse):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
AGENT_BROWSER_POOL_OWNER_PID=77777 AGENT_BROWSER_POOL_OWNER_STARTTIME=12345 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
          N1="$(pool_acquire_locked)"                          # acquire (claims lane 1)
          port="$(pool_lease_field "$N1" port)"
          [[ "$port" == "0" ]] && pool_boot_lane "$N1"          # boot
          # RELEASE lane 1 explicitly (the function under test):
          pool_release_lane "$N1" && echo "OK3-released" || echo "FAIL3-release"
          pool_lease_exists "$N1" && echo "FAIL3-lease" || echo "OK3-lease-gone"
          # RE-ACQUIRE — must get the SAME lane number back (it was freed):
          N2="$(pool_acquire_locked)"
          [[ "$N2" == "$N1" ]] && echo "OK3-reused-lane-$N2" || echo "OK3-got-lane-$N2 (distinct ok if >1 free)"
          port2="$(pool_lease_field "$N2" port)"
          [[ "$port2" == "0" ]] && pool_boot_lane "$N2"
          # CLEANUP:
          pg="$(pool_lease_field "$N2" chrome_pgid)"; kill -9 -- -"$pg" 2>/dev/null || true
          "$POOL_REAL_BIN" --session "abpool-$N2" close >/dev/null 2>&1 || true
          pool_release_lane "$N2" >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-released ; OK3-lease-gone ; OK3-reused-lane-1 (or OK3-got-lane-N).

# Reaper-style loop validation (release is safe to call in a loop over many lanes):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          # Boot 2 lanes, then reap-style release ALL lanes:
          for n in 1 2; do
              pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99999 pi 1111 "/tmp" 0 0 "false"
              pool_boot_lane "$n"
          done
          for n in $(pool_lanes_list); do pool_release_lane "$n"; done   # rc 0 each; no abort
          for n in 1 2; do pool_lease_exists "$n" && echo "FAIL lane $n" || echo "OK reaped lane $n"; done
          # re-reap (all already gone) — must still rc 0 each, no abort:
          for n in $(pool_lanes_list); do pool_release_lane "$n"; done
          echo "OK3-reaper-loop"'
rm -rf "$STATE" "$EPHEM"
# Expected: OK reaped lane 1 ; OK reaped lane 2 ; OK3-reaper-loop.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Verify the daemon close actually fires + is non-fatal on a dead-chrome session (research §3):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          pg="$(pool_lease_field 1 chrome_pgid)"
          # Kill chrome first (so close runs on a dead-chrome session — the hardest case):
          kill -9 -- -"$pg" 2>/dev/null || true; sleep 1
          # release must still rc 0 (close on dead-chrome session is rc 0, host-verified):
          pool_release_lane 1 && echo "OK4-close-on-dead-rc0" || echo "FAIL4"
          # Verify close did NOT launch a stray chrome (unlike get cdp-url):
          pgrep -fc "chrome.*remote-debugging.*abpool" >/dev/null 2>&1 && echo "FAIL4-stray" || echo "OK4-no-stray"
          "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-close-on-dead-rc0 ; OK4-no-stray.

# Idempotency stress — release the same lane 5×; every call rc 0; no stray chrome; no abort:
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99999 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          for i in 1 2 3 4 5; do pool_release_lane 1 && echo "OK4-iter-$i-rc0" || echo "FAIL4-iter-$i"; done
          pool_lease_exists 1 && echo "FAIL4-lease" || echo "OK4-lease-gone"
          "$POOL_REAL_BIN" --session abpool-1 close >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-iter-1-rc0 … OK4-iter-5-rc0 ; OK4-lease-gone.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` zero warnings (whole file).
- [ ] Level 2: all 6 scenarios from Task 2 print their documented `OK*` lines.
- [ ] Level 3: the acquire→boot→release→re-acquire round-trip prints `OK3-released` + `OK3-lease-gone`
      + a reused/distinct lane; the reaper-loop test prints `OK3-reaper-loop`.
- [ ] Level 4: close-on-dead-chrome prints `OK4-close-on-dead-rc0` + `OK4-no-stray`; the 5×
      idempotency stress prints all 5 `OK4-iter-*-rc0` + `OK4-lease-gone`.

### Feature Validation

- [ ] Happy path: booted lane → rc 0; Chrome dead; dir gone; lease gone; close invoked (Scenario 1).
- [ ] Idempotent no-lease: lane 99 → rc 0 (no-op) (Scenario 2).
- [ ] Idempotent double-release: rc 0, rc 0 (Scenario 3).
- [ ] Partial release (Chrome already dead): rc 0; dir + lease removed (Scenario 4).
- [ ] Provisional lease (port:0, chrome_pid:0): rc 0; no-op kill; dir + lease removed (Scenario 5).
- [ ] Bad/empty/missing lane input → rc 0 (validate, no-op) (Scenario 6).
- [ ] DELEGATES to `_pool_release_lane_internals` (does NOT duplicate kill/rm/lease logic).
- [ ] Reads `session` BEFORE delegating (the kernel deletes the lease).
- [ ] Runs `close` BEFORE the kill (graceful detach); the swap vs the literal CONTRACT order is
      documented in the docstring + justified (immaterial, host-verified).
- [ ] Non-fatal always: never `pool_die`, never non-zero.
- [ ] NO flock (lane-local + idempotent).

### Code Quality Validation

- [ ] Follows existing codebase patterns (the _pool_adopt_lane / S3 single-field jq idiom; the
      kernel's `if ! pool_lease_read …; then return 0; fi` idempotent-return idiom; `_pool_log`
      one summary line; docstring with LOGIC + CALLER CONTRACT + GOTCHA sections).
- [ ] `pool_release_lane` appended under a new `(P1.M5.T2.S1)` banner after `pool_ensure_connected`;
      NO edits to any existing function.
- [ ] Every `local` capture is split (`local X; X="$(…)"`); the non-fatal rc-1 helper guarded.
- [ ] Anti-patterns avoided (see below): no kernel duplication, no flock, no pool_die, no
      `local x=$(...)` masking, no unguarded `pool_lease_read`, no missing `${:-}` on POOL_REAL_BIN.

### Documentation & Deployment

- [ ] Code is self-documenting (the docstring's LOGIC block IS the spec; the GOTCHA block captures
      the delegate mandate, the c↔d swap, the close semantics, the no-flock decision).
- [ ] `_pool_log` summary line is informative (lane + session + teardown confirmation).
- [ ] No new env vars (reads only the frozen POOL_REAL_BIN + POOL_LANES_DIR).

---

## Anti-Patterns to Avoid

- ❌ Don't DUPLICATE the kill/rm/lease logic — the M5.T1.S1 contract MANDATES delegation to
  `_pool_release_lane_internals`. Re-implementing violates the contract + duplicates the
  prefix-guarded `rm -rf` safety logic.
- ❌ Don't read `session` AFTER delegating — the kernel DELETES the lease; read it up front.
- ❌ Don't call `pool_die` or return non-zero — `pool_release_lane` is NON-FATAL always (it runs in
  reap loops / admin / exhaustion under `set -euo pipefail`; one bad lane must never abort the pool).
- ❌ Don't add a flock — release is lane-local + idempotent. Flocking is the caller's concern (and
  none of the real consumers take it).
- ❌ Don't run `close` and expect it to kill the Chrome — `close` is DISCONNECT-ONLY (the Chrome
  survives it, host-verified). The pool relies on `pool_chrome_kill` (via the kernel) to terminate
  Chrome. Don't drop the kill.
- ❌ Don't drop the `2>/dev/null || true` on `close` — even though rc is always 0 on 0.28.0, the guard
  is the idempotency mechanism + future-proof + documents non-fatal intent.
- ❌ Don't use `get cdp-url` anywhere — it auto-launches strays (M4.T3.S1 research §2). The release
  uses `close` (no launch) + `pool_chrome_kill` (direct pgroup signal). No cdp probing needed here.
- ❌ Don't write `local X="$(…)"` — `local` masks errexit (BashFAQ 105 / SC2155). Split it.
- ❌ Don't call `pool_lease_read` bare — it returns 1 (non-fatal) on missing/corrupt and ABORTS under
  set -e. Guard with `if ! …; then return 0; fi`.
- ❌ Don't reference `"$POOL_REAL_BIN"` without `${POOL_REAL_BIN:-}` — under set -u an unset global is
  an unbound-variable error before the command runs (not catchable by `|| true`). Guard it.
- ❌ Don't create private helpers or new files — the body is ~10 lines; one function reads cleaner.
  Append to `lib/pool.sh` under the banner; nothing else.
