# PRP — P1.M3.T2.S2: `pool_find_free_lane()` — lowest free lane number

---

## Goal

**Feature Goal**: Implement the **lane-allocation query** of `lib/pool.sh` — the single
function that, given the frozen pool globals, answers PRD §2.4 step 3c:
*"lowest N≥1 with no `active/<N>` dir and no `lanes/<N>.json` lease."* It is the
"CHOOSE N" primitive of the acquire critical section: a pure, read-only probe that walks
N=1,2,3,… (lanes are **unbounded — created on demand**, per the contract) and returns the
first N where **both** the ephemeral dir `$POOL_EPHEMERAL_ROOT/<N>` is absent **and** the
lease file `$POOL_LANES_DIR/<N>.json` is absent. One function, appended at EOF of
`lib/pool.sh`:

1. **`pool_find_free_lane()`** — loop N from 1 upward; on the first N where
   `[[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]` → echo N and
   `return 0`. **Always** echoes a value and returns 0 (lanes are unbounded; there is no
   "no free lane" failure state). Called **inside** the caller's `flock` critical section
   (M5.T1.S1 acquire step 3c) — the function itself does NO locking, NO mutation, NO I/O
   beyond two `stat`-class tests per probe.

**Deliverable**:
1. One function (`pool_find_free_lane`) appended to `lib/pool.sh` under a new
   `# Lease management — query operations (P1.M3.T2.S2)` banner, placed directly after the
   last existing function (currently `pool_lease_find_mine_any()`, line ~1042–1053 — S1
   landed; if not, after `pool_lease_exists()`, ~line 931). Pure addition: no new globals,
   no new env vars, no new files, no new external dependencies.
2. Reads only the two frozen globals `POOL_EPHEMERAL_ROOT` and `POOL_LANES_DIR` (frozen by
   `pool_config_init`, M1.T1.S2 — LANDED). Composes NOTHING below it (it does NOT call
   `pool_lease_exists`, `pool_lanes_list`, or any S1 function — verified independent; see
   research §3–§4). Consumed by the acquire flow (M5.T1.S1 step 3c).
3. Every branch is **host-verified** (2026-07-12) via a prototype of the exact function body
   run under `set -euo pipefail` — see `research/find-free-lane.md` (all 4 scenarios passed).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init` with seeded state
  (lane 1 dir+lease; lane 2 dir-only orphan; lane 3 lease-only; lane 4 free), then
  `n="$(pool_find_free_lane)"` ⟹ `n==4`.
- On an empty pool (no dirs, no leases; or even when the roots don't exist yet) ⟹ echoes
  `1`, return 0.
- On a gap (lanes 1 & 3 occupied, lane 2 free) ⟹ echoes `2` (lowest free).
- A dir-only orphan lane (`active/2` exists, no lease) ⟹ that lane is **not** free
  (the dir blocks it); the probe continues to the next N.
- A lease-only lane (lease exists, dir absent) ⟹ that lane is **not** free (the file blocks
  it); this is the correct behavior for the in-flock "claimed, not yet copied" window.
- Non-numeric junk in the lanes dir (`foo.json`, a `sub.json/` subdir) does **not** affect
  the result — the probe is purely numeric (N=1,2,3,…), unlike `pool_lanes_list` which must
  filter junk.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1, M2.\*, M3.T1.\*, M3.T2.S1) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls this directly. The
single consumer is the acquire orchestration:

- **P1.M5.T1.S1** (acquire, flock critical section step 3c) — the **primary** and only
  caller. After `pool_reap_stale` (3a) + reuse-orphan (3b), it calls
  `N="$(pool_find_free_lane)"` to pick the lowest free lane, then `pool_lease_write` (3d) to
  provisionally claim it, **all inside `flock 9` on `$POOL_LOCK_FILE`**. PRD §2.4 step 3c.

**Use Case**: On every `agent-browser` invocation that does NOT already hold a valid lane
(i.e. `pool_lease_find_mine` returned 1), the wrapper enters the acquire critical section,
reaps stale lanes, then calls `pool_find_free_lane` to choose a fresh lane number. The
function is the "allocate the next lane" oracle.

**Pain Points Addressed**:
- **Two agents must never pick the same lane.** The dual check (dir **and** lease absent)
  plus the caller's `flock` guarantee uniqueness within the critical section. A dir-only
  orphan (crash between copy and claim) and a lease-only provisional claim (step 3d before
  3e) both correctly block their lane from reuse.
- **Lanes are unbounded → no fixed-size pool to manage.** The incrementing probe naturally
  grows the lane namespace on demand; no `MAX_LANES` constant, no resize logic.
- **The lock section must be short (key_findings FINDING 2).** Two `[[ -d ]]` / `[[ -f ]]`
  builtin tests per probe (no `jq` fork, no `ls` fork) keep choose-N sub-millisecond even
  for a pathological 1000-lane probe, so Chrome boots stay **outside** the lock.

## Why

- **This is the lane allocator, on the acquire hot path.** Every non-reuse `agent-browser`
  call (M6.T3 → M5.T1) runs it. Correctness = no two owners share a lane; speed = the global
  acquire lock is not held hostage to a slow scan. PRD §2.4 step 3c.
- **It is a leaf read-only query — it adds no new mechanism.** It reads two already-frozen
  absolute globals and does two `[[ ]]` existence tests. There is no JSON, no locking, no
  mutation. Its entire complexity is "increment N until both checks pass."
- **The dual dir+lease check is deliberate defense-in-depth.** Checking only the lease would
  miss an orphaned ephemeral dir (a Chrome still running after its lease was deleted, or a
  crash between `cp -a` and `pool_lease_write`). Checking only the dir would miss the
  provisional-claim window (lease written at step 3d, dir copied at step 3e — both inside the
  same flock, so a second serialized acquirer must skip lane N). The contract mandates BOTH.
- **`[[ -f ]]` over `pool_lease_exists` is a safety choice (research §3).** A corrupt lease
  file (`printf 'NOT JSON{'`, a crash-mid-write) makes `pool_lease_exists` return 1 (free),
  which would let find_free_lane reuse that lane number — a **collision** if a live Chrome
  still owns it (reap skipped it because it couldn't read `owner.pid`). `[[ -f ]]` treats a
  present-but-corrupt file as occupied, which is safe (just suboptimal — skips that N). It is
  also cheaper (no `jq` fork) inside the lock.

## What

User-visible behavior: none directly (internal library query). Observable contract:

| Function | Args | Returns / side effects | Failure mode |
|---|---|---|---|
| `pool_find_free_lane` | (none; reads `POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`) | Echo the lowest free lane N (digits, one line), `return 0`. | **Never fails.** Lanes are unbounded ⟹ there is always a free N (the live-agent count is finite). No non-zero return path is needed; exhaustion is M5.T4's external timeout concern. |

**Semantics notes**:
- **Always rc 0, always echoes.** Unlike `pool_lease_find_mine` (S1) which returns 1 on
  "no match" and so needs a caller `if`-guard under set -e, `pool_find_free_lane` always
  returns 0. A bare `N="$(pool_find_free_lane)"` is therefore **safe under set -e** (no
  `if` guard needed). This asymmetry is intentional and correct — the contracts differ.
- **Unbounded loop, no cap.** The contract is "lowest N≥1, increment." `reap_stale`
  (PRD §2.4 step 3a) runs BEFORE choose-N (3c), so after reaping the occupied count == live
  agent count (finite). The loop terminates at ≈ (live-agent-count + 1). Do NOT add a hard
  cap — it would silently change the contract (returning non-zero instead of finding the
  next N). Pool exhaustion (PRD §2.9) is M5.T4's responsibility (block-with-timeout +
  force-reap + alert), bounding the whole acquire externally.
- **Read-only / no mkdir.** The function never creates directories. If `POOL_EPHEMERAL_ROOT`
  doesn't exist yet, `[[ -d "$POOL_EPHEMERAL_ROOT/1" ]]` is simply false ⟹ N=1 is free
  (host-verified, scenario D). It never writes or deletes anything.
- **No locking inside.** The caller (M5.T1.S1) holds `flock` on `$POOL_LOCK_FILE` around
  the entire scan+reap+choose+claim sequence (key_findings FINDING 2). `pool_find_free_lane`
  is the "choose" step inside that lock; it must be fast (it is — two stat tests/probe).

### Success Criteria

- [ ] `pool_find_free_lane` defined in `lib/pool.sh` under a
      `# Lease management — query operations (P1.M3.T2.S2)` banner, directly after the last
      existing function (S1's `pool_lease_find_mine_any` at ~line 1042, or `pool_lease_exists`
      at ~line 931 if S1 hasn't landed). Callable after `source lib/pool.sh`.
- [ ] Empty pool (no dirs, no leases) ⟹ echoes `1`, return 0.
- [ ] Roots (`POOL_EPHEMERAL_ROOT`, `POOL_LANES_DIR`) don't exist yet ⟹ echoes `1`, return 0.
- [ ] Lane 1 occupied (dir+lease), lane 2 dir-only orphan, lane 3 lease-only, lane 4 free ⟹
      echoes `4`, return 0.
- [ ] Gap (lanes 1 & 3 occupied, lane 2 free) ⟹ echoes `2`, return 0 (lowest free).
- [ ] Dir-only orphan lane (`active/2` exists, no `2.json`) ⟹ lane 2 is **not** free
      (dir blocks it); probe continues.
- [ ] Lease-only lane (`3.json` exists, no `active/3`) ⟹ lane 3 is **not** free (file blocks it).
- [ ] Non-numeric junk (`foo.json`, a `sub.json/` subdir) in the lanes dir ⟹ does NOT affect
      the result (numeric probe ignores it).
- [ ] The function is **read-only**: never `mkdir`, never writes/deletes, never calls
      `pool_die`, never logs. It always returns 0 and echoes a value.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.T1.\*, M3.T2.S1) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified exact function
body (prototype run under `set -euo pipefail`, all 4 scenarios passed — research §1); the
reasoning for `for (( n=1; ; n++ ))` over a capped/`while` form including the set -e `(( ))`
trap (research §2); the `[[ -f ]]` vs `pool_lease_exists` corrupt-file safety decision
(research §3); the proof of independence from S1 (research §4 — no call to any S1 function);
the "caller holds the flock" boundary (research §5); the item-mandated exact name
(`pool_find_free_lane`, research §6); and copy-pasteable, host-verified validation commands
for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3c (the EXACT contract: "CHOOSE N: lowest N≥1 with no active/<N> dir and
        no lanes/<N>.json lease" — this task IS that step), §2.4 step 3a/3d (reap-stale runs
        BEFORE choose-N; provisional claim 3d runs INSIDE the same flock → lease-only window
        must block), §2.3 (ephemeral dir location: lanes live in active/<N>/, numbered from
        1, created on acquire → the dir half of the check), §2.9 (pool exhaustion is a
        SEPARATE concern handled by M5.T4 block-with-timeout — do NOT add a cap here),
        §2.2 (no bare ~ — POOL_EPHEMERAL_ROOT/POOL_LANES_DIR are already absolute).
  pattern: §2.4 step 3c is the literal pseudocode for pool_find_free_lane.
  gotcha: the check is "no dir AND no lease" (BOTH must be absent), not "no dir OR no lease";
        a dir-only orphan or a lease-only provisional claim each block their lane.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (flock critical section must be SHORT: scan + reap + choose-N + provisional-
        claim only; Chrome launch AFTER the lock releases → find_free_lane must be fast and is
        the "choose-N" step), FINDING 3 (no bare ~ — the globals are absolute by S2 of M1),
        and the "Function Naming Convention" table (pool_* = public entry points; note this
        task uses the item-mandated pool_find_free_lane, a lane QUERY — see research §6).
  pattern: the "RIGHT" flock example shows find_free_lane's caller shape.
  gotcha: FINDING 2 — do NOT do Chrome launch / connect inside the lock; find_free_lane is
        pure-probe so it does none of that, but the function's speed is what makes the
        short-section rule viable.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout: lanes/<N>.json is the lease file; acquire.lock is the flock
        target held by the CALLER, not this function), §8 (ephemeral layout: active/<N>/ CoW
        copy dirs created on acquire, deleted on release → the dir half of the check).
  pattern: §7 + §8 → the two probe paths are $POOL_EPHEMERAL_ROOT/<N> and $POOL_LANES_DIR/<N>.json.
  gotcha: the ephemeral root (active/) and lanes dir MAY NOT EXIST on a first run → the probe
        must treat a missing parent as "child path absent" (host-verified, scenario D).

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §4 ([[ -d ]] / [[ -f ]] are bash builtins — zero forks, ideal for the lock section),
        §5 (POOL_EPHEMERAL_ROOT derived from AGENT_CHROME_EPHEMERAL_ROOT; POOL_LANES_DIR derived
        from POOL_STATE_DIR/lanes — both frozen by pool_config_init), §6 (lease schema, not
        directly needed but confirms the .json extension and lane-numeric naming).
  pattern: §4 → no external tool is needed; pure bash builtins.
  gotcha: none new.

# This task's own research (host-verified prototype — all 4 scenarios passed)
- file: plan/001_0f759fe2777c/P1M3T2S2/research/find-free-lane.md
  why: the deep brief on (a) the exact host-verified function body + the 4-scenario results
        (§1), (b) why for ((n=1;;n++)) and NOT a capped/while form + the set -e (( )) trap
        (§2), (c) why [[ -f ]] over pool_lease_exists — corrupt-file collision safety (§3),
        (d) proof of independence from S1 — composes nothing below it (§4), (e) the caller-
        holds-flock boundary (§5), (f) naming/placement (§6), (g) edge cases (§7), (h) the
        caller contract for M5.T1.S1 (§8).
  pattern: §1 (the function body), §8 (the caller idiom — bare N="$(…)" is set -e safe).
  gotcha: §3 — pool_lease_exists returns 1 (free) on a CORRUPT lease, which would collide;
        [[ -f ]] is safe. §2 — a bare (( n++ )) STATEMENT returns 1 when n was 0 and aborts
        under set -e; the for (( )) condition slot is exempt — use the for-form.

# The globals THIS task reads (LANDED in lib/pool.sh — treated as contract)
- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init — freezes the two globals
  why: pool_config_init freezes the ABSOLUTE POOL_EPHEMERAL_ROOT and POOL_LANES_DIR this task
        probes. PRECONDITION. Both are realpath -m canonicalized (may not exist yet → probe
        treats missing parent as absent).
  pattern: POOL_EPHEMERAL_ROOT = $POOL_HOME_DIR/.agent-chrome-profiles/active (canonical);
        POOL_LANES_DIR = $POOL_STATE_DIR/lanes (canonical).
  gotcha: do NOT re-resolve paths — trust the frozen globals; they are already absolute.

# The sibling query layer (LANDED — for cohesion/context, NOT a dependency)
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list / find_mine (S1)
  why: S1 landed pool_lanes_list (enumerate existing lane STEMS) + pool_lease_find_mine/
        _any (owner correlation). pool_find_free_lane is INDEPENDENT — it does NOT call any of
        them (different algorithm: numeric probe vs glob+sort enumeration). They are
        complementary: the caller runs find_mine first (reuse?), and only on "no" runs
        find_free_lane (pick new). Read this PRP only to match the section-banner style and
        the append placement.
  pattern: S1 appends under a "# Lease management — query operations (P1.M3.T2.S1)" banner;
        THIS task uses the analogous "(P1.M3.T2.S2)" banner directly after S1's functions.
  gotcha: do NOT route the lease check through pool_lease_exists (S1/M3.T1.S2) — see research
        §3; use [[ -f ]].

# External authoritative docs (for the HOW)
- url: https://www.gnu.org/software/bash/manual/bash.html#Looping-Constructs
  why: the C-style `for (( expr1 ; expr2 ; expr3 ))` form. An EMPTY middle condition (expr2)
        is the canonical "loop forever" — expr2 is evaluated arithmetically for truthiness, so
        errexit (set -e) never fires on it (the condition slot is not a statement).
  section: "for (( expr1 ; expr2 ; expr3 )) ; do … ; done".

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (set -e). A bare `(( n++ ))` STATEMENT returns exit status 1 when the result is
        0 (i.e. n was 0 pre-increment) and ABORTS under set -e (see _pool_age_str in
        lib/pool.sh for the same trap). The for (( )) form sidesteps this entirely; a
        hypothetical while-loop would need n=$((n+1)) (the $(( )) EXPANSION is always safe).
  section: `-e` (errexit).

- url: https://www.gnu.org/software/bash/manual/bash.html#Conditional-Constructs
  why: the `[[ ! -d … && ! -f … ]]` compound test. `[[ ]]` is errexit-exempt (a false result
        doesn't abort), and `&&` / `!` inside `[[ ]]` are logical (not command-list) operators,
        so the whole "both absent" predicate is one safe test.
  section: "[[ … ]]".

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local n` on its own line (the for-loop declares n
        but never captures a command-substitution into a local, so this is minor; still follow
        the two-statement form for any local capture).
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.S1/S2, M3.T2.S1** have all landed
(verified: the file is now **1053 lines**; `grep` shows `pool_lanes_list` @967,
`pool_lease_find_mine` @1003, `pool_lease_find_mine_any` @1042 — S1 LANDED):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty
├── lib/
│   └── pool.sh                           # 1053 lines: set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.S1/.S2)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)  ← line 918–966
│                                         #   + pool_lanes_list/pool_lease_find_mine/pool_lease_find_mine_any (M3.T2.S1)  ← lines 967–1053 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M3T2S1/PRP.md
    └── P1M3T2S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/find-free-lane.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND one query function under a new banner after the current
                  #   EOF (line ~1053, after S1's pool_lease_find_mine_any):
                  #   # Lease management — query operations (P1.M3.T2.S2)
                  #   pool_find_free_lane()  — lowest free lane N≥1 (no dir AND no lease)
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **lane-allocation query** — the lowest-free-lane probe. It reads only the two frozen
`pool_config_init` globals; it is consumed by the acquire flow's flock critical section
(M5.T1.S1 step 3c).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified): the check is "no dir AND no lease" — BOTH must be absent for a
#   lane to be free. A dir-only orphan (active/2 exists, no lease — a crash between cp and
#   pool_lease_write, or a Chrome still running after lease deletion) BLOCKS lane 2. A
#   lease-only lane (3.json exists, no active/3 — the in-flock "claimed, not yet copied"
#   window of step 3d→3e) BLOCKS lane 3. This dual defense is the whole point of the contract.

# CRITICAL (corrupt-file safety): use [[ -f "$POOL_LANES_DIR/$n.json" ]], NOT
#   pool_lease_exists "$n". pool_lease_exists returns 1 (free) on a CORRUPT lease file (S2
#   contract: jq-empty parse fails → rc 1), which would let find_free_lane reuse that lane
#   number — a COLLISION if a live Chrome still owns it (reap skipped it because it couldn't
#   read owner.pid). [[ -f ]] treats a present-but-corrupt file as occupied (safe; just
#   suboptimal — skips that N). It is also cheaper (no jq fork) inside the lock.

# CRITICAL (set -e + (( ))): a bare `(( n++ ))` STATEMENT returns exit 1 when n was 0
#   (pre-increment result is 0) and ABORTS under set -e. Use the C-style for-loop
#   `for (( n = 1; ; n++ ))` — its condition slot is evaluated arithmetically for truthiness
#   and is NOT a statement, so errexit never fires on it. (Same trap as _pool_age_str's
#   `(( ))` blocks, which all live inside if/elif.) Do NOT rewrite this as a while-loop with
#   a bare `(( n++ ))`.

# CRITICAL (no cap): lanes are UNBOUNDED (PRD §2.4: created on demand). The contract is
#   "lowest N≥1, increment" with NO upper bound. reap_stale (step 3a) runs BEFORE choose-N
#   (3c), so after reaping the occupied count == live-agent count (finite) → the loop always
#   terminates at ≈ (live-agent-count + 1). Do NOT add a hard cap — it would silently change
#   the contract. Pool EXHAUSTION (PRD §2.9) is M5.T4's job (block-with-timeout + force-reap
#   + alert around the whole acquire), not find_free_lane's.

# CRITICAL (always rc 0): unlike pool_lease_find_mine (S1) which returns 1 on "no match",
#   pool_find_free_lane ALWAYS echoes a value and returns 0 (there is no "no free lane"
#   failure state). Therefore a bare `N="$(pool_find_free_lane)"` is set -e SAFE (no `if`
#   guard needed). This asymmetry vs find_mine is intentional and correct.

# CRITICAL (no locking inside): the CALLER (M5.T1.S1) holds flock on $POOL_LOCK_FILE around
#   scan+reap+choose+claim (key_findings FINDING 2). find_free_lane is the "choose" step
#   INSIDE that lock. It does NO flocking of its own and must be fast (it is — two stat
#   tests/probe, zero forks).

# GOTCHA (missing parents are fine): if POOL_EPHEMERAL_ROOT or POOL_LANES_DIR does not exist
#   yet (fresh checkout's first acquire, before pool_state_init created the lanes dir), then
#   [[ -d "$POOL_EPHEMERAL_ROOT/1" ]] is simply false → N=1 is free. Host-verified (scenario
#   D). The function is read-only: it never mkdirs to "fix" a missing parent.

# GOTCHA (junk immunity): unlike pool_lanes_list (S1), which globs $POOL_LANES_DIR/*.json and
#   must filter non-numeric stems / subdirs, pool_find_free_lane PROBES N=1,2,3,… by number.
#   A stray foo.json or a sub.json/ subdir is never tested and cannot affect the result.
#   This is a structural advantage of the numeric-probe algorithm.

# GOTCHA (no new globals / no new env / no new deps): pure addition. Reads only
#   POOL_EPHEMERAL_ROOT + POOL_LANES_DIR (frozen by pool_config_init). Composes nothing.

# GOTCHA (scope): this task is the FREE-LANE query ONLY. Do NOT: pool_lanes_list /
#   find_mine (M3.T2.S1, LANDED), is_lane_stale (M3.T2.S3), acquire/release/reap
#   orchestration (M5.*), the flock itself or the wrapper wiring (M6.*).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no new globals**, **no new env vars**, and **no on-disk layout**
(the layout is `$POOL_EPHEMERAL_ROOT/<N>/` for ephemeral dirs and `$POOL_LANES_DIR/<N>.json`
for leases — both established by M1, written by M3.T1.S1, read by M3.T1.S2). It defines one
function whose data contract is read-only over those two path families. It touches no JSON
and reads no lease fields.

| input | source | example | role |
|---|---|---|---|
| `POOL_EPHEMERAL_ROOT` | `pool_config_init` (M1.T1.S2) | `/home/dustin/.agent-chrome-profiles/active` | parent of the `active/<N>/` ephemeral dirs |
| `POOL_LANES_DIR` | `pool_config_init` (M1.T1.S2) | `/home/dustin/.local/state/agent-browser-pool/lanes` | parent of the `lanes/<N>.json` lease files |

**Naming** (item-mandated, exact): `pool_find_free_lane`. NOTE the naming-table tension
(key_findings lists `pool_lane_*` for lane lifecycle and S1 introduced `pool_lanes_list`
plural for enumeration); this function is a lane QUERY and the work item's contract
literally says "Implement `pool_find_free_lane()`" — honor it verbatim. The acquire consumer
(M5.T1.S1) references this exact name. Do NOT rename to `pool_lanes_find_free` /
`pool_lane_find_free`. No `_` prefix — it is a public entry point (mirror `pool_lanes_list`,
`pool_lease_find_mine`). Internal-only in practice.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init pool_lease_write'
  - EXPECT: all three reported as functions. (pool_config_init is M1.T1.S2 LANDED — it
        freezes POOL_EPHEMERAL_ROOT + POOL_LANES_DIR; pool_state_init is M1.T1.S3; 
        pool_lease_write is M3.T1.S1, used only to seed validation scenarios.) If
        pool_config_init is MISSING, STOP — this task depends on it.
  - RUN (confirm the two globals resolve to ABSOLUTE paths after init):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 echo "EROOT=$POOL_EPHEMERAL_ROOT"; echo "LDIR=$POOL_LANES_DIR"; \
                 [[ "$POOL_EPHEMERAL_ROOT" == /* ]] && [[ "$POOL_LANES_DIR" == /* ]] && echo OK-abs'
  - EXPECT: both paths absolute, OK-abs.
  - RUN (confirm the probe mechanics + set -e safety on a temp tree — the EXACT algorithm):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        EROOT="$tmp/active"; LDIR="$tmp/lanes"; mkdir -p "$EROOT" "$LDIR"
        mkdir -p "$EROOT/1" "$EROOT/2"; printf '{"x":1}' > "$LDIR/1.json"; printf '{"x":1}' > "$LDIR/3.json"
        POOL_EPHEMERAL_ROOT="$EROOT" POOL_LANES_DIR="$LDIR" \
        bash -c 'set -euo pipefail
                 pool_find_free_lane() {
                     local n
                     for (( n = 1; ; n++ )); do
                         if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
                             printf "%s\n" "$n"; return 0
                         fi
                     done
                 }
                 n="$(pool_find_free_lane)"; [[ "$n" == 4 ]] && echo "OK n=$n" || echo "FAIL n=$n"'
        # EXPECT: OK n=4 (lane1 dir+lease, lane2 dir-only, lane3 lease-only, lane4 free).
        # If this differs, re-read research §1–§2 before proceeding.
  - RUN (locate the append point — current EOF):
        tail -5 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^pool_(lease_find_mine_any|lease_exists|lanes_list)\(\)' lib/pool.sh
  - EXPECT: the last function is pool_lease_find_mine_any (S1, ~line 1042) OR pool_lease_exists
        (M3.T1.S2, ~line 918) if S1 hasn't landed. File ~1053 lines (S1 landed) or ~931 (not).
        APPEND the new banner + function AFTER the last function's closing brace. Do NOT touch
        any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_find_free_lane() to lib/pool.sh (the only function)
  - PLACEMENT: after a new banner line, directly below the last existing function's closing
        brace (S1's pool_lease_find_mine_any, or pool_lease_exists if S1 not landed).
  - IMPLEMENT (verbatim-ready — paste this function body):
        # =============================================================================
        # Lease management — query operations (P1.M3.T2.S2)
        # =============================================================================
        # Lane allocation: the lowest-free-lane probe. Implements PRD §2.4 step 3c
        # ("CHOOSE N: lowest N≥1 with no active/<N> dir and no lanes/<N>.json lease").
        # A pure, read-only numeric probe; composes NOTHING below it (it does not call
        # pool_lease_exists, pool_lanes_list, or any M3.T2.S1 function). Reads only the two
        # frozen pool_config_init globals. Consumed by the acquire flock critical section
        # (M5.T1.S1 step 3c).

        # pool_find_free_lane
        #
        # Walk N = 1, 2, 3, … (lanes are UNBOUNDED — created on demand, PRD §2.4). Echo the
        # first N where BOTH the ephemeral dir is absent AND the lease file is absent, and
        # return 0. ALWAYS echoes a value and returns 0 — there is no "no free lane" failure
        # state (the live-agent count is finite, so the probe terminates at ≈ live-count+1;
        # reap_stale at step 3a has already removed dead-owner lanes before this runs at 3c).
        #
        # CONSUMER: M5.T1.S1 acquire step 3c, INSIDE the caller's flock on $POOL_LOCK_FILE.
        #   Because this function always returns 0, a bare `N="$(pool_find_free_lane)"` is
        #   set -e SAFE (no `if` guard needed) — unlike pool_lease_find_mine (returns 1).
        #
        # WHY TWO CHECKS (dir AND lease — research §0/§7): checking only the lease would miss
        # an orphaned ephemeral dir (a Chrome still running after its lease was deleted, or a
        # crash between `cp -a` and pool_lease_write). Checking only the dir would miss the
        # provisional-claim window (lease written at step 3d, dir copied at 3e — both inside
        # the same flock, so a second serialized acquirer must skip lane N). BOTH must be
        # absent for a lane to be free.
        # WHY [[ -f ]] NOT pool_lease_exists (research §3): pool_lease_exists returns 1 (free)
        # on a CORRUPT lease (jq-empty parse fails), which would let us reuse a lane whose
        # Chrome may still be live (reap skipped it — couldn't read owner.pid) → COLLISION.
        # [[ -f ]] treats a present-but-corrupt file as occupied (safe; just skips that N).
        # It is also cheaper (no jq fork) inside the lock.
        # GOTCHA — for (( n=1; ; n++ )): the empty middle condition is the canonical
        # "loop forever"; its condition slot is NOT a statement, so errexit never fires on it.
        # (A bare `(( n++ ))` STATEMENT would return 1 when n was 0 and ABORT under set -e —
        # same trap as _pool_age_str's (( )) blocks; the for-form sidesteps it.)
        # GOTCHA — no hard cap: do NOT add `n <= MAX`. The contract is "lowest N≥1, increment"
        # with no bound. Pool EXHAUSTION (PRD §2.9) is M5.T4's concern (external timeout around
        # the whole acquire), not this function's.
        # GOTCHA — missing parents are fine: if POOL_EPHEMERAL_ROOT/POOL_LANES_DIR don't exist
        # yet, [[ -d "$POOL_EPHEMERAL_ROOT/1" ]] is simply false → N=1 is free. Read-only:
        # never mkdirs.
        # GOTCHA — junk immunity: a stray foo.json / sub.json/ subdir is never tested (the
        # probe is purely numeric N=1,2,3,…), unlike pool_lanes_list which globs and filters.
        # PRECONDITION: pool_config_init (for the ABSOLUTE POOL_EPHEMERAL_ROOT + POOL_LANES_DIR).
        pool_find_free_lane() {
            local n
            for (( n = 1; ; n++ )); do
                if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
                    printf '%s\n' "$n"
                    return 0
                fi
            done
        }
  - FOLLOW pattern: `for (( ))` open-ended increment (set -e safe); `[[ ! -d … && ! -f … ]]`
        compound builtin test (errexit-exempt, zero forks); `printf '%s\n'` (not echo, for
        portability/digits-only output); `return 0` (explicit, documents "always succeeds").
  - NAMING: pool_find_free_lane (item-mandated; do NOT rename).
  - PLACEMENT: the only function in the new "(P1.M3.T2.S2)" section.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_find_free_lane' >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (HAPPY — lane1 dir+lease, lane2 dir-only orphan, lane3 lease-only, lane4 free → 4):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_EPHEMERAL_ROOT/1" "$POOL_EPHEMERAL_ROOT/2"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/1.json"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/3.json"; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 4 ]] && echo "OK n=$n" || echo "FAIL n=$n"'
        # EXPECT: OK n=4.
  - RUN (EMPTY POOL — no dirs, no leases → 1):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 1 ]] && echo "OK n=$n" || echo "FAIL n=$n"'
        # EXPECT: OK n=1.
  - RUN (MISSING ROOTS — ephemeral root & lanes dir not created → 1; read-only, no mkdir):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 # NOTE: pool_state_init NOT called → lanes dir does not exist; ephemeral root
                 # default also does not exist. Function must still return 1 without mkdir-ing.
                 before_eph="$(ls -A "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"; \
                 before_lan="$(ls -A "$POOL_LANES_DIR" 2>/dev/null || true)"; \
                 n="$(pool_find_free_lane)"; \
                 after_eph="$(ls -A "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"; \
                 after_lan="$(ls -A "$POOL_LANES_DIR" 2>/dev/null || true)"; \
                 if [[ "$n" == 1 && "$before_eph" == "$after_eph" && "$before_lan" == "$after_lan" ]]; then \
                     echo "OK n=$n (read-only: created nothing)"; \
                 else echo "FAIL n=$n (ephemeral before=[$before_eph] after=[$after_eph]; lanes before=[$before_lan] after=[$after_lan])"; fi'
        # EXPECT: OK n=1 (read-only: created nothing).
  - RUN (GAP — lanes 1 & 3 occupied, lane 2 free → 2; lowest free):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_EPHEMERAL_ROOT/1" "$POOL_EPHEMERAL_ROOT/3"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/3.json"; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 2 ]] && echo "OK n=$n (lowest gap)" || echo "FAIL n=$n"'
        # EXPECT: OK n=2 (lowest gap).
  - RUN (DIR-ONLY ORPHAN blocks lane — active/2 exists, no lease → not free):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_EPHEMERAL_ROOT/2"; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 1 ]] && echo "OK n=$n (lane 1 free; orphaned dir at 2 does not lower it)" || echo "FAIL n=$n"'
        # EXPECT: OK n=1 (lane 1 free; the orphan dir at 2 is irrelevant for N=1).
  - RUN (CORRUPT LEASE treated as occupied — [[ -f ]] not pool_lease_exists):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 printf "NOT JSON{" > "$POOL_LANES_DIR/1.json"; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 2 ]] && echo "OK n=$n (corrupt 1.json blocks lane 1)" || echo "FAIL n=$n"'
        # EXPECT: OK n=2 (the corrupt file's PRESENCE blocks lane 1 — collision-safe).
  - RUN (JUNK IMMUNITY — foo.json + sub.json/ dir do not affect the numeric probe):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 printf junk > "$POOL_LANES_DIR/foo.json"; mkdir -p "$POOL_LANES_DIR/sub.json"; \
                 n="$(pool_find_free_lane)"; \
                 [[ "$n" == 1 ]] && echo "OK n=$n (junk ignored)" || echo "FAIL n=$n"'
        # EXPECT: OK n=1 (junk ignored — probe is numeric).
  - RUN (set -e SAFE bare capture — pool_find_free_lane always rc 0, no if-guard needed):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 # A bare capture under set -e must NOT abort (unlike pool_lease_find_mine).
                 n="$(pool_find_free_lane)"; echo "captured bare under set -e: n=$n"'
        # EXPECT: captured bare under set -e: n=1  (no abort — proves always-rc-0 contract).
  - RUN (regression: all prior + new function still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any \
                      pool_find_free_lane >/dev/null && echo OK'
        # EXPECT: OK.
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the one function (paste under the new banner after the last function) ---

pool_find_free_lane() {
    local n
    for (( n = 1; ; n++ )); do
        if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    done
}

# --- Critical micro-rules baked into the above --------------------------------
#  * The check is "no dir AND no lease" — BOTH absent ⟹ free. A dir-only orphan or a
#    lease-only provisional claim each block their lane (defense-in-depth vs collision).
#  * [[ -f ]] (NOT pool_lease_exists): a corrupt lease file's PRESENCE blocks the lane
#    (collision-safe); pool_lease_exists would call it free and risk a collision.
#  * for (( n=1; ; n++ )) is the "loop forever" idiom; its condition slot is not a
#    statement ⟹ set -e safe. Do NOT use a while-loop with a bare (( n++ )) (aborts when
#    n was 0). No hard cap (contract is unbounded; exhaustion is M5.T4's external timeout).
#  * ALWAYS rc 0 + echoes N. A bare `N="$(pool_find_free_lane)"` is set -e safe (no `if`
#    guard), unlike pool_lease_find_mine which returns 1 and needs `if n="$(…)"`.
#  * Read-only: never mkdir, never write/delete, never pool_die, never logs. Missing parents
#    ⟹ child path is absent ⟹ N probes upward correctly (verified scenario D).
#  * Zero forks: [[ -d ]] / [[ -f ]] are bash builtins (ideal inside the caller's flock).
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_config_init (M1.T1.S2): freezes the ABSOLUTE POOL_EPHEMERAL_ROOT and POOL_LANES_DIR
        this task probes. PRECONDITION. Both canonicalized via realpath -m (may not exist yet).
  - (pool_state_init (M1.T1.S3) creates the lanes dir, but is NOT required by this function —
        a missing dir is handled as "all lanes free". In practice the acquire caller has run
        it.)

CALLER (future — M5.T1.S1 acquire step 3c, NOT built here):
  - The acquire flow holds flock on $POOL_LOCK_FILE around: reap_stale (3a) → reuse-orphan
        (3b) → `N="$(pool_find_free_lane)"` (3c) → pool_lease_write provisional claim (3d) →
        release flock → copy/port/launch/connect outside the lock (3e–3j). key_findings
        FINDING 2 mandates the lock section be SHORT (choose-N is the fast step inside it).

NO INTEGRATION WITH S1: pool_find_free_lane does NOT call pool_lanes_list /
  pool_lease_find_mine / pool_lease_find_mine_any (different algorithm: numeric probe vs
  glob+sort enumeration). They are complementary siblings under the same "query operations"
  umbrella. Verified independent (research §4) — S2 builds and tests correctly even if S1
  had not landed.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the function — fix before proceeding
bash -n lib/pool.sh                       # bash syntax check — MUST be clean
shellcheck lib/pool.sh                    # whole-file lint — zero warnings

# Project-wide (the whole library must stay clean)
shellcheck lib/pool.sh && echo "shellcheck clean"
bash -n lib/pool.sh && echo "bash -n clean"

# Expected: Zero errors. If errors exist, READ output and fix before proceeding.
# NOTE: this is a bash library (no ruff/mypy — those are the Python template defaults;
#       the bash equivalents are `bash -n` + shellcheck).
```

### Level 2: Unit Tests (Component Validation)

```bash
# There is no bats harness yet (M9.T1.S1). Validate via inline one-shot bash probes that
# source the real lib/pool.sh against a temp POOL_STATE dir. Each scenario below MUST print OK.

# HAPPY: lane1 dir+lease, lane2 dir-only orphan, lane3 lease-only, lane4 free → 4
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         mkdir -p "$POOL_EPHEMERAL_ROOT/1" "$POOL_EPHEMERAL_ROOT/2"; \
         printf "{\"x\":1}" > "$POOL_LANES_DIR/1.json"; \
         printf "{\"x\":1}" > "$POOL_LANES_DIR/3.json"; \
         n="$(pool_find_free_lane)"; [[ "$n" == 4 ]] && echo "OK n=$n" || echo "FAIL n=$n"'

# EMPTY POOL → 1 ;  MISSING ROOTS → 1 (read-only) ;  GAP → 2 ;  CORRUPT LEASE → 2 ;  JUNK → 1
# (see Task 2 VERIFY block for the exact commands — all are host-verified to print OK.)

# Expected: every probe prints OK. If FAIL, debug root cause and fix before proceeding.
```

### Level 3: Integration Testing (System Validation)

```bash
# End-to-end acquire-critical-section simulation: reap is OUT OF SCOPE (M5.T3), but we CAN
# prove the find_free_lane → pool_lease_write (claim) handoff works under the caller's flock
# pattern (key_findings FINDING 2 "RIGHT" shape), and that a SECOND serialized acquirer
# inside the SAME flock skips the now-claimed lane.

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
         AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" pool_owner_resolve; \
         # Simulate the flock critical section (no real flock in this test — single shell):
         N1="$(pool_find_free_lane)"; \
         pool_lease_write "$N1" "$POOL_EPHEMERAL_ROOT/$N1" 0 "abpool-$N1" \
             "$ME" "$MECOMM" "$MEST" "/c" 0 0 false; \
         mkdir -p "$POOL_EPHEMERAL_ROOT/$N1"; \
         # A second acquirer (serialized) must now skip lane N1 (lease+dir present):
         N2="$(pool_find_free_lane)"; \
         echo "first claim N1=$N1, second acquirer N2=$N2"; \
         [[ "$N1" == 1 && "$N2" == 2 ]] && echo "OK handoff" || echo "FAIL handoff"'
# Expected: first claim N1=1, second acquirer N2=2 ; OK handoff (the claimed lane is skipped).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Race-free-by-construction reasoning check (no real concurrency here — the CONTRACT is that
# the CALLER holds flock; this just confirms the function is stateless/re-entrant so it is
# safe to call repeatedly inside one flock section):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         a="$(pool_find_free_lane)"; b="$(pool_find_free_lane)"; c="$(pool_find_free_lane)"; \
         [[ "$a" == "$b" && "$b" == "$c" ]] && echo "OK idempotent/re-entrant (a=b=c=$a)" || echo "FAIL"'
# Expected: OK idempotent/re-entrant (a=b=c=1) — proves the function is a pure probe with no
# side effects, so the caller's flock is the ONLY thing preventing a race. This matches the
# contract note "called under flock so it's race-free within the critical section".
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully
- [ ] `bash -n lib/pool.sh` clean
- [ ] `shellcheck lib/pool.sh` clean (whole file, zero warnings)
- [ ] No prior function altered (diff is append-only under the new banner)

### Feature Validation

- [ ] All success criteria from "What" section met
- [ ] HAPPY scenario (lane1 dir+lease, lane2 dir-only, lane3 lease-only, lane4 free) ⟹ `4`
- [ ] Empty pool ⟹ `1`; missing roots ⟹ `1` (read-only, created nothing)
- [ ] Gap (1 & 3 occupied) ⟹ `2` (lowest free)
- [ ] Corrupt lease (`NOT JSON{`) ⟹ that lane is occupied (`[[ -f ]]` collision-safety)
- [ ] Dir-only orphan / lease-only provisional-claim each block their lane
- [ ] Junk (`foo.json`, `sub.json/`) does not affect the numeric probe
- [ ] Bare `N="$(pool_find_free_lane)"` is set -e safe (always rc 0 — no `if` guard needed)
- [ ] Integration handoff (find_free_lane → pool_lease_write → second acquirer skips) works

### Code Quality Validation

- [ ] Follows existing codebase patterns and naming conventions (item-mandated
      `pool_find_free_lane`; banner style matches S1's "query operations" section)
- [ ] File placement matches the desired codebase tree (append at EOF under new banner)
- [ ] Anti-patterns avoided (check against Anti-Patterns section)
- [ ] No new globals, no new env vars, no new external dependencies
- [ ] Composes nothing below it (independent of S1; pure probe of frozen globals)

### Documentation & Deployment

- [ ] The function's leading comment block documents: the contract (PRD §2.4 step 3c), the
      "both absent" rule, the `[[ -f ]]` vs `pool_lease_exists` choice, the `for (( ))` set -e
      safety, the no-cap rationale, the read-only/no-mkdir guarantee, and the caller-holds-flock
      boundary
- [ ] No user-facing docs needed (internal function; CONTRACT §5: "DOCS: none")
- [ ] No environment variables added

---

## Anti-Patterns to Avoid

- ❌ Don't use `pool_lease_exists "$n"` for the lease check — it returns 1 (free) on a CORRUPT
  lease, risking a collision. Use `[[ -f "$POOL_LANES_DIR/$n.json" ]]` (presence blocks).
- ❌ Don't check only the dir OR only the lease — the contract is "no dir AND no lease". Both
  a dir-only orphan and a lease-only provisional claim must block their lane.
- ❌ Don't add a hard upper cap (`n <= MAX`) — lanes are unbounded; exhaustion is M5.T4's
  external-timeout concern. A cap silently changes the contract.
- ❌ Don't use a `while`-loop with a bare `(( n++ ))` — it returns 1 when n was 0 and aborts
  under set -e. Use the C-style `for (( n = 1; ; n++ ))` (its condition slot is not a statement).
- ❌ Don't add flock/locking inside the function — the CALLER (M5.T1.S1) holds the lock; the
  function is the fast "choose-N" step inside it.
- ❌ Don't `mkdir` or mutate anything — read-only probe. A missing parent is "child absent."
- ❌ Don't route through `pool_lanes_list` (S1) — different algorithm (numeric probe vs
  glob+sort enumeration); find_free_lane is independent and must not depend on S1 landing.
- ❌ Don't `pool_die` or log — the function always succeeds (rc 0); there is no failure path.
- ❌ Don't rename `pool_find_free_lane` to "fit" the `pool_lane_*` / `pool_lanes_*` buckets —
  the work item's contract mandates this exact name and the acquire consumer references it.
- ❌ Don't skip validation because "it should work" — every scenario in Task 2 is host-verified
  to print OK; run them all.

---

**Confidence Score: 9/10** for one-pass implementation success. The function is a single,
host-verified 6-line pure-probe with no dependencies beyond two frozen globals, an exact
prototype that passed all 4 scenarios, and a complete validation suite. The one residual
uncertainty is purely organizational (whether S1's functions precede this one at EOF — handled
by instructing append-after-last-function, robust either way).
