# PRP — P1.M3.T2.S3: `pool_lane_is_stale(lane)` — staleness detection for the reaper

---

## Goal

**Feature Goal**: Implement the **per-lane staleness verdict** for the agent-browser-pool
reaper — the single function that answers *"is lane N's owner dead/recycled, so its
Chrome+dir+lease should be torn down?"* It is the literal realization of PRD §2.5
("Release is **owner-liveness-driven**, not TTL-driven") and §2.14's three failure modes
("owner pid dead → reap"; "comm != pi (recycled) → reap"; "starttime mismatch → reap"),
made into one composable predicate that the lazy reaper (§2.10) calls on every lane.
The function reads a lane's lease, extracts its `owner.{pid,comm,starttime}` triple, and
delegates the (pid, comm, starttime) identity check to `pool_owner_alive` (M2.T2.S1,
LANDED). One function, appended at EOF of `lib/pool.sh`.

1. **`pool_lane_is_stale(lane)`** — **tri-state** return (NOT a boolean — see §"What"):
   - **`0`** = lane is **stale** (owner dead/recycled/unverifiable → caller reaps).
   - **`1`** = lane is **live** (owner alive + identity matches → caller keeps it).
   - **`2`** = **no lease** (file missing OR corrupt → caller skips; nothing to reap).

   The function is the literal realization of the item's CONTRACT (LOGIC a→d):
   ```
   a. pool_lease_read "$lane".  If it returns 1 (missing OR corrupt) → return 2.
   b. Extract owner.pid, owner.starttime, owner.comm from the lease JSON.
   c. pool_owner_alive "$pid" "$starttime" "$comm".  If returns 1 → stale → return 0.
   d. If owner alive (returns 0) → not stale → return 1.
   ```

2. No new globals, no on-disk state, no env vars, no user docs ("DOCS: none — internal
   function"). Pure append of ONE function. Composes exactly two LANDED functions:
   `pool_lease_read` (M3.T1.S2) and `pool_owner_alive` (M2.T2.S1).

**Deliverable**: One function (`pool_lane_is_stale`) appended to `lib/pool.sh` under a new
`# Lease management — query operations (P1.M3.T2.S3)` banner, placed directly after
`pool_find_free_lane` (the current EOF, ~line 1108). Pure addition: no new globals, no new
env vars, no new files, no new external dependencies. Every branch is **host-verified**
(2026-07-12) via a prototype of the exact function body run against the real library under
`set -euo pipefail` — see `research/is-lane-stale-and-reaper-contract.md` (all 8 scenarios
+ the set -e hazard + the herestring form — ALL PASSED).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, with a
  lane leased to a LIVE self (`$$` + correct comm + correct starttime) →
  `pool_lane_is_stale "$lane"` returns **1** (live).
- A lane leased to a DEAD pid → returns **0** (stale).
- A lane leased to a live pid but WRONG starttime (recycle-into-new-pi) → **0** (stale).
- A lane leased to a live pid but WRONG comm (recycle-into-non-pi) → **0** (stale).
- A lane with NO lease file → returns **2** (no lease). A CORRUPT lease (`NOT JSON{`) →
  returns **2** (skip) AND the pool log gains one `pool_lease_read: corrupt lease` line
  (emitted by the composed `pool_lease_read`).
- A non-numeric lane (`../etc`) → returns **2** (path-traversal-safe, treated as no-lease).
- A valid-JSON lease with a MISSING `owner` object → returns **0** (stale — unverifiable
  owner is reaped, not trusted).
- `pool_lane_is_stale` NEVER calls `pool_die`, NEVER writes/deletes/kills (read-only
  verdict; the caller acts), and NEVER aborts under `set -euo pipefail`.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1, M2.\*, M3.T1.\*, M3.T2.S1, M3.T2.S2) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls this directly. Its
consumers are the reaper/orchestration subtasks inside `lib/pool.sh` and the wrappers:

- **P1.M5.T3.S1** (`reap_stale()`) — the **primary** consumer. The lazy reaper invoked on
  every acquire (PRD §2.10 "IQ3 = lazy, on acquire") scans every lane and calls
  `pool_lane_is_stale "$n"`; rc 0 (stale) → it tears the lane down (`kill -- -pgid`,
  `rm -rf` ephemeral dir, delete lease via `pool_release_lane` M5.T2.S1); rc 1/2 → skip.
- **P1.M5.T1.S1** (acquire, flock critical section step **3a REAP-STALE**) — calls
  `pool_lane_is_stale` (directly, or via `pool_reap_stale`) BEFORE `pool_find_free_lane`
  (step 3c) so freed lane numbers become reusable in the same critical section.
- **P1.M7.T4.S1** (`doctor`) — may use it to report stale lanes during reconciliation.

**Use Case**: On every `agent-browser` invocation that does NOT already hold a valid lane
(i.e. `pool_lease_find_mine` returned 1), the wrapper enters the acquire critical section
and the FIRST thing it does (PRD §2.4 step 3a) is reap stale lanes. This function is the
"stale?" oracle behind that step. Its verdict drives whether a lane's Chrome pgroup is
killed and its ephemeral dir deleted.

**Pain Points Addressed**:
- **Owner-liveness-driven release, not TTL.** PRD §2.5 mandates NO idle timer. Every
  release decision ultimately asks "is this owner dead/stale?" `pool_lane_is_stale` IS
  that question, lifted to the per-lane granularity the reaper iterates over. If it is
  wrong, either live owners get reaped (constant Chrome churn, redundant 4.8 GB copies) or
  dead owners leak their lanes forever (pool exhaustion, §2.9).
- **One place that turns the lease's owner triple into a verdict.** Without it, every
  consumer (reaper, acquire step 3a, doctor) would re-implement "read lease → extract
  owner → call pool_owner_alive → interpret rc". Centralizing it keeps the (pid, comm,
  starttime) anti-recycling logic in exactly two functions (`pool_owner_alive` checks a
  triple; `pool_lane_is_stale` reads the triple from a lease and delegates).
- **"No lease" must not crash the reaper scan.** A lane with no `.json` is simply
  unleased (NORMAL). The tri-state `2` makes that a first-class, handleable result so the
  reaper's `for n in $(pool_lanes_list)` loop never aborts at the first free lane.

## Why

- **It is the staleness spine of owner-liveness-driven release.** PRD §2.5 + §2.14 + §2.10
  make the reaper lazy and liveness-driven; this function is the liveness verdict the
  reaper iterates on. Correctness = no live owner is ever reaped (no churn) and no
  dead/recycled owner keeps a lane (no leak/theft). key_findings FINDING 1 + the M2.T2.S1
  research confirm the (pid, comm, starttime) triple is the correct, host-verified
  identity key.
- **It cleanly layers "read the lease's owner" on top of "is this owner alive".**
  `pool_owner_alive` (M2.T2.S1) checks an ARBITRARY triple against `/proc` now.
  `pool_lane_is_stale` reads the triple FROM A LANE LEASE and delegates. Splitting them
  keeps each function single-purpose and independently testable — and means the
  `/proc` parsing + anti-recycling logic lives in exactly one place
  (`_pool_get_starttime` + `pool_owner_alive`), never re-implemented here.
- **The tri-state (0/1/2) is the contract's whole point.** The reaper must distinguish
  "stale → reap" (0) from "live → keep" (1) from "no lease → skip" (2). A two-state
  boolean would either crash the scan on a free lane (if "no lease" were an error) or
  force the caller to re-implement the lease-existence check per call site. The `2` keeps
  the reaper loop a clean `if pool_lane_is_stale "$n"; then reap; fi`.

## What

User-visible behavior: none directly (internal library predicate). Observable contract:

| `pool_lane_is_stale` args | Return | Reason |
|---|---|---|
| `lane` — lease present, owner alive + comm + starttime all match | **1** (live) | owner is the same process that took the lease (§2.14 all-clear) |
| `lane` — lease present, owner pid dead/missing | **0** (stale) | §2.14 "owner pid dead" |
| `lane` — lease present, owner comm != pi (recycled into non-pi) | **0** (stale) | §2.14 "comm != pi" |
| `lane` — lease present, owner starttime mismatch (recycled into new pi) | **0** (stale) | §2.14 "starttime mismatch" |
| `lane` — lease present but `owner` object missing/garbled | **0** (stale) | unverifiable owner → reaped, never trusted (safe) |
| `lane` — NO lease file (unleased) | **2** (no lease) | caller skips; nothing to reap |
| `lane` — lease file present but CORRUPT JSON | **2** (skip) | can't read owner safely; `_pool_log` warning emitted by pool_lease_read; doctor reconciles |
| non-numeric `lane` (`../etc`, `abc`) | **2** (skip) | path-traversal-safe; treated as "no lease" |

**Return-code convention — CRITICAL (inverted vs `pool_owner_alive`)**: `pool_owner_alive`
returns **0 = alive / 1 = dead**. `pool_lane_is_stale` **INVERTS** this: it returns **0 =
stale / 1 = live** (the mapping is explicit in the CONTRACT: c→ pool_owner_alive returns 1
⟹ is_stale returns 0; d→ alive ⟹ is_stale returns 1). The inversion makes the natural
reaper idiom `if pool_lane_is_stale "$n"; then reap; fi` read like English — rc 0 ("true")
IS the "yes, stale" answer. This is the single most important fact about this function.

**Hard invariants** (every cell above):
- NEVER calls `pool_die`; NEVER writes to disk; NEVER kills a process; NEVER deletes a file
  (read-only VERDICT — the caller acts on it). The ONLY possible side effect is one
  `_pool_log` line, emitted transitively by the composed `pool_lease_read` on a CORRUPT
  lease (it logs once; `pool_lane_is_stale` itself never logs — it runs in the reaper scan
  loop, where per-lane logging would flood the pool log; the CALLER logs the decision).
- NEVER aborts under `set -euo pipefail`: the `pool_lease_read` call is wrapped in
  `if ! json="$(…)"`; the jq extraction operates on the in-memory string (no file TOCTOU);
  `pool_owner_alive` is a leaf predicate that never aborts.

### Success Criteria

- [ ] `pool_lane_is_stale` defined in `lib/pool.sh` under a
      `# Lease management — query operations (P1.M3.T2.S3)` banner, directly after
      `pool_find_free_lane`'s closing brace (current EOF, ~line 1108). Callable after
      `source lib/pool.sh` (requires `pool_config_init` + `pool_state_init` for tests).
- [ ] Live owner (self `$$`, correct comm + starttime) → returns **1**.
- [ ] Dead owner pid → returns **0** (stale).
- [ ] Live pid + WRONG starttime (recycle-into-new-pi) → **0** (stale).
- [ ] Live pid + WRONG comm (recycle-into-non-pi) → **0** (stale).
- [ ] No lease file → returns **2**.
- [ ] Corrupt lease (`NOT JSON{`) → returns **2** AND the pool log gains one
      `pool_lease_read: corrupt lease` line (from the composed reader).
- [ ] Non-numeric lane (`../etc`) → returns **2** (path-traversal-safe).
- [ ] Valid-JSON lease with a MISSING `owner` object → returns **0** (stale; unverifiable
      owner is reaped, not trusted).
- [ ] Composes `pool_lease_read` (ONCE) + ONE `jq -r` extraction (via `mapfile`) +
      `pool_owner_alive` — does NOT call `pool_lease_field` (contract names only
      `pool_lease_read` + `pool_owner_alive`).
- [ ] NEVER calls `pool_die`, NEVER writes/kills/deletes, NEVER logs directly (the one
      possible log line comes from `pool_lease_read` on corrupt).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.T1.\*, M3.T2.S1, M3.T2.S2) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **tri-state return contract
and its inversion vs `pool_owner_alive`** (research §1 — the #1 gotcha); the **caller-side
`set -e` hazard** with the host-verified bare-call-aborts proof + the three safe idioms
(research §2); the **composition choice** (`pool_lease_read` once + one `jq -r` via
`mapfile`, NOT `pool_lease_field` ×3 — research §3) with the host-verified exact
extraction; the rationale for **missing+corrupt → rc 2** (research §4) and
**missing-owner-fields → rc 0** (research §5); the exact function body (host-verified, all
8 scenarios passed — research §8); the exact placement (after `pool_find_free_lane` at EOF,
~line 1108); the exact contracts of the two LANDED functions it composes; and
copy-pasteable, host-verified validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.5 (Release is owner-liveness-driven, NOT TTL — this verdict is the liveness
        oracle the reaper uses), §2.14 (the THREE failure modes this function encodes as
        the stale branch: pid dead / comm != pi / starttime mismatch), §2.4 step 3a
        (REAP-STALE runs first inside acquire's flock, BEFORE choose-N at 3c), §2.10
        (Reaper — "IQ3 = lazy, on acquire"), §2.8 (lease owner carries {pid, comm,
        starttime} — the triple this function reads + delegates), §2.2 (no bare ~ —
        POOL_LANES_DIR is already absolute).
  pattern: §2.14's table is the literal "when is a lane stale?" spec; §2.4 step 3a is the
        consumer call site.
  gotcha: §2.19's starttime formula is WRONG — irrelevant here (we delegate to
        _pool_get_starttime via pool_owner_alive); do NOT re-parse /proc in this function.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 1 (the (pid, starttime) anti-recycling key — defeats PID reuse; this
        function reads the key from the lease and pool_owner_alive checks it), FINDING 2
        (the flock critical section must be SHORT — reap_stale + is_lane_stale run INSIDE
        it, so this function must be cheap: 1 read + 1 jq + 1 pool_owner_alive per lane),
        the "Function Naming Convention" (pool_lane_* = lane lifecycle/query subdomain —
        this function is pool_lane_is_stale per the contract).
  pattern: the reap critical section calls is_lane_stale per lane; cheap = OK inside flock.
  gotcha: FINDING 2 — keep it lean; do NOT spawn 3 jq forks (use one jq + mapfile).

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout: lanes/<N>.json is the lease file this reads), §6
        (confirms owner.{pid,comm,starttime} are the identity triple).
  pattern: §7 → the read path is $POOL_LANES_DIR/<N>.json (via pool_lease_read).
  gotcha: the lanes dir MAY NOT EXIST on a first run → pool_lease_read returns 1 → rc 2.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §6 (lease schema v1 — owner is a NESTED object: owner.{pid,comm,starttime,cwd};
        this is WHY the jq extraction uses dotted paths .owner.pid etc.), §4 (jq at
        /usr/bin/jq — the extraction tool), §5 (POOL_LANES_DIR derived from POOL_STATE_DIR).
  pattern: §6 owner schema → the three fields this function extracts.
  gotcha: none new.

# This task's own research (host-verified prototype — all 8 scenarios PASSED)
- file: plan/001_0f759fe2777c/P1M3T2S3/research/is-lane-stale-and-reaper-contract.md
  why: the deep brief on (a) the tri-state contract + the inversion vs pool_owner_alive
        (§1), (b) the caller-side set -e hazard + the 3 safe idioms, host-verified (§2),
        (c) WHY pool_lease_read + one jq+mapfile, not pool_lease_field×3 (§3), (d) WHY
        missing+corrupt → rc 2 (§4), (e) WHY missing-owner-fields → rc 0 via
        pool_owner_alive's own validation (§5), (f) naming/placement (§6), (g) the
        non-fatal/read-only predicate convention (§7), (h) the full host-verified results
        table (§8), (i) the caller contract for reap_stale + acquire step 3a (§9).
  pattern: §1 (the return table), §3 (the exact extraction), §9 (the reaper caller idiom).
  gotcha: §2 (bare call aborts under set -e) and §1 (the inversion) are the two non-obvious
        ones that WILL cause bugs if missed.

# The TWO LANDED functions this task composes (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_read (M3.T1.S2 — LANDED)
  why: pool_lease_read(lane) is the contract-named reader. CONTRACT: echoes raw JSON +
        return 0 on a valid lease; return 1 (NEVER fatal, silent stdout) for MISSING file
        OR CORRUPT JSON (it _pool_logs ONE "corrupt lease" warning on the corrupt branch).
        This task's `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 2; fi`
        relies on EXACTLY this contract — rc 1 (both missing+corrupt) → rc 2 (skip). The
        JSON it echoes is guaranteed valid (_pool_json_valid passed), so the downstream jq
        extraction cannot fail on a parse error.
  pattern: the `if ! json="$(pool_lease_read …)"; then …; fi` guard (the set -e-safe read).
  gotcha: pool_lease_read returns 1 for BOTH missing AND corrupt — both map to rc 2 here
        (research §4). Do NOT try to distinguish them inside this function.

- file: plan/001_0f759fe2777c/P1M2T2S1/PRP.md    # pool_owner_alive (M2.T2.S1 — LANDED)
  why: pool_owner_alive(pid, starttime, comm) is the contract-named identity predicate.
        CONTRACT: return 0 if alive+same-process; return 1 (NEVER fatal) for dead pid /
        comm mismatch / starttime mismatch / non-numeric pid. THIS task INVERTS its rc
        (alive→0 becomes live→1; dead→1 becomes stale→0). Its input validation
        (non-numeric pid → return 1) is what makes a missing/garbled owner field resolve
        to stale (rc 0) with NO special-case branch (research §5). Its default
        expected_comm='pi' is NOT used here — we always pass the lease's stored comm.
  pattern: `if pool_owner_alive "$pid" "$starttime" "$comm"; then return 1; fi; return 0`.
  gotcha: the rc inversion (research §1) — easy to get backwards; the table in §1 is the
        authoritative mapping.

# The sibling query layer (LANDED — for cohesion/placement, NOT a dependency)
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list / find_mine (S1)
  why: S1 landed pool_lanes_list (the reaper's `for n in $(pool_lanes_list)` iterator),
        pool_lease_find_mine/_any. is_lane_stale is CALLED INSIDE that loop by reap_stale
        (M5.T3.S1). Read this PRP only to match the section-banner style and confirm the
        per-lane scan shape; is_lane_stale does NOT call any S1 function itself.
  pattern: S1 appends under a "# Lease management — query operations (P1.M3.T2.S1)" banner;
        THIS task uses the analogous "(P1.M3.T2.S3)" banner directly after S2's functions.
  gotcha: do NOT enumerate lanes inside is_lane_stale — it takes ONE lane arg; enumeration
        is the caller's job (pool_lanes_list).

- file: plan/001_0f759fe2777c/P1M3T2S2/PRP.md   # pool_find_free_lane (S2 — LANDED @1101)
  why: S2 (parallel, now LANDED at line 1101) is the IMMEDIATE PREDECESSOR at EOF. This
        task appends directly after pool_find_free_lane's closing brace. S2 established
        the "(P1.M3.T2.S2)" banner pattern this task mirrors for "(P1.M3.T2.S3)".
  pattern: the banner style + append-after-last-function placement.
  gotcha: S2's find_free_lane runs at acquire step 3c, AFTER reap_stale (3a, which calls
        THIS function) — so reaping stale lanes frees numbers for find_free_lane. Do NOT
        call find_free_lane here.

# External authoritative docs (for the HOW)
- url: https://jqlang.github.io/jq/manual/
  why: comma-separated expressions (`.owner.pid, .owner.starttime, .owner.comm` — emits
        one value per line, exactly 3 lines for any object; a missing path emits `null`);
        `-r` raw output (no quotes). This is the ONE-fork extraction (research §3).
  critical: comma in jq emits each expression on its own line → `mapfile -t` captures
        exactly 3 elements. A missing `.owner` → three `null` lines → pool_owner_alive
        rejects "null" as non-numeric → stale (rc 0). Host-verified.
  section: "Comma is another operator" + "Invoking jq" (-r).

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (set -e) — a bare `pool_lane_is_stale "$n"` whose rc is 1 or 2 ABORTS the
        caller (host-verified, research §2). The condition of `if`/`&&`/`||` is EXEMPT, so
        `if pool_lane_is_stale "$n"; then` and the `if ! json="$(pool_lease_read …)"; then`
        guard are safe. Document the caller hazard (M5.T3.S1 / M5.T1.S1 must use the
        if-guard, not a bare call).
  section: `-e` (errexit).

- url: https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins
  why: `mapfile -t ARRAY` reads stdin lines into ARRAY (strips trailing newlines). bash
        ≥4.0; the host runs bash 5.x. The `-t` is mandatory (else each element keeps its
        newline and the pid comparison would be "836725\n" != "836725").
  section: mapfile / readarray.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local json` FIRST, then `json="$(…)"` so the
        capture's exit status is preserved and the `if ! json="$(…)"` guard works. (The
        function declares all locals first, then assigns; SC2155-clean.)
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.\*, M3.T2.S1** have landed AND **M3.T2.S2
(`pool_find_free_lane`)** has landed at line 1101 (verified: the file is now **1109 lines**;
`grep` shows `pool_find_free_lane` @1101; S1's `pool_lease_find_mine` @1003,
`pool_lease_find_mine_any` @1042):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty
├── lib/
│   └── pool.sh                           # 1109 lines: set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.S1/.S2)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)  ← @823–966
│                                         #   + pool_lanes_list/pool_lease_find_mine/pool_lease_find_mine_any (M3.T2.S1)  ← @967–1053
│                                         #   + pool_find_free_lane (M3.T2.S2)  ← @1101–1108 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M3T2S2/PRP.md
    └── P1M3T2S3/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/is-lane-stale-and-reaper-contract.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND one verdict function under a new banner after the
                  #   current EOF (line ~1108, after S2's pool_find_free_lane):
                  #   # Lease management — query operations (P1.M3.T2.S3)
                  #   pool_lane_is_stale(lane)  — tri-state staleness verdict (0 stale / 1 live / 2 no lease)
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **per-lane staleness verdict** — the reaper's "stale?" oracle. It composes the LANDED
`pool_lease_read` (M3.T1.S2) and `pool_owner_alive` (M2.T2.S1); it is consumed by the lazy
reaper (M5.T3.S1) and the acquire flock step 3a (M5.T1.S1).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the return-code INVERSION): pool_owner_alive returns 0=alive/1=dead.
#   pool_lane_is_stale INVERTS this: 0=STALE (reap), 1=LIVE, 2=NO-LEASE. The mapping is:
#     pool_owner_alive -> 1 (dead)   ==> is_stale -> 0 (stale)
#     pool_owner_alive -> 0 (alive)  ==> is_stale -> 1 (live)
#   Easy to write backwards. The rc-0-is-stale convention is deliberate: it makes the
#   reaper idiom `if pool_lane_is_stale "$n"; then reap; fi` read naturally (rc 0 = true).
#   See research §1. HOST-VERIFIED.

# CRITICAL (caller-side set -e hazard): a BARE `pool_lane_is_stale "$n"` whose rc is 1 or 2
#   ABORTS the caller script (set -e is propagated by lib/pool.sh line 14). HOST-VERIFIED:
#   a bare call on a live lane killed the prototype harness mid-script. Callers MUST use
#   `if pool_lane_is_stale "$n"; then reap; fi` (rc 1/2 fall through to the implicit else)
#   or `pool_lane_is_stale "$n" && rc=0 || rc=$?` to capture all three codes. This is the
#   SAME hazard family as pool_lease_read/pool_lease_find_mine. Document it for M5.T3.S1 /
#   M5.T1.S1. See research §2.

# CRITICAL (compose ONLY pool_lease_read + pool_owner_alive): the CONTRACT literally names
#   these two. Do NOT use pool_lease_field (would be 3 extra disk reads + 3 jq forks, and a
#   non-contract function). Read the lease ONCE via pool_lease_read, then extract the three
#   owner fields with ONE `jq -r '.owner.pid, .owner.starttime, .owner.comm'` captured via
#   `mapfile -t` (1 disk read + 1 jq fork total). See research §3. HOST-VERIFIED.

# CRITICAL (missing AND corrupt both → rc 2): pool_lease_read returns 1 for BOTH a missing
#   file AND a corrupt file (it logs one "corrupt lease" warning on the corrupt branch).
#   The CONTRACT's "If no lease → return 2" maps BOTH to rc 2 (skip). Rationale: a corrupt
#   lease can't tell us the owner/chrome_pgid, so reaping it blind is unsafe — skip and let
#   doctor (M7.T4) reconcile. See research §4. HOST-VERIFIED.

# CRITICAL (missing/garbled owner FIELDS → stale, rc 0): a lease that is valid JSON but has
#   NO owner object (or owner.pid is null) yields pid="null" → pool_owner_alive's own
#   `[[ "$pid" =~ ^[0-9]+$ ]]` rejects it → returns 1 → is_stale returns 0 (stale). This is
#   SAFE (an unverifiable owner is reaped, never trusted) and needs NO special-case branch.
#   See research §5. HOST-VERIFIED.

# CRITICAL (mapfile -t is mandatory): the `-t` strips the trailing newline from each line.
#   Without it, pid would be "836725\n" and `[[ ... =~ ^[0-9]+$ ]]` / the starttime
#   comparison would fail. Always `mapfile -t`. HOST-VERIFIED (the whole prototype uses -t).

# CRITICAL (jq operates on the in-memory string, not the file): `jq -r '...' <<<"$json"`
#   feeds the captured JSON to jq via a herestring — there is NO file read here, so NO
#   TOCTOU and jq CANNOT fail on a parse error (pool_lease_read already guaranteed valid
#   JSON via _pool_json_valid). Do NOT add a `|| return` on the jq/mapfile line for a parse
#   failure — it is unreachable; but it IS fine to leave the array-index `:-` defaults.

# CRITICAL (NEVER pool_die / NEVER write / NEVER kill / NEVER log directly): this is a
#   read-only VERDICT. The caller (reap_stale / release) does the teardown. The ONLY
#   possible log line comes transitively from pool_lease_read on a corrupt lease. is_lane_stale
#   itself must not _pool_log (it runs in the reaper scan loop; per-lane logging floods).

# CRITICAL (set -e + the read guard): wrap the read in `if ! json="$(pool_lease_read "$lane"
#   2>/dev/null)"; then return 2; fi` — the `if !` is errexit-exempt (a bare
#   `json="$(pool_lease_read 99)"` would ABORT on rc 1). The `2>/dev/null` suppresses the
#   corrupt-parse stderr from jq inside pool_lease_read (the warning is logged via _pool_log,
#   not stderr, so diagnostics are preserved).

# GOTCHA (placement): APPEND at EOF (after pool_find_free_lane @1108). Do NOT touch any
#   existing function (pool_lease_read, pool_owner_alive, _pool_get_starttime, etc.). This
#   task only CONSUMES them.

# GOTCHA (naming): pool_lane_is_stale — the CONTRACT body literally says "Implement
#   `pool_lane_is_stale(lane)`" (the work-item TITLE shortens it to is_lane_stale, but the
#   contract body is authoritative). key_findings' naming table puts pool_lane_* in the lane
#   lifecycle/query subdomain. The M5.T3.S1 + M5.T1.S1 consumers reference this exact name.

# GOTCHA (scope): this task is the VERDICT only. Do NOT: enumerate lanes (pool_lanes_list,
#   M3.T2.S1); tear down a lane — kill pgroup / rm dir / delete lease (pool_release_lane,
#   M5.T2.S1); the full reap loop (M5.T3.S1); orphan reuse (M5.T3.S2); exhaustion handling
#   (M5.T4); acquire flock / choose-N (M5.T1.S1 — this function is CALLED BY step 3a); owner
#   resolution (the lease already stores owner.*); re-parse /proc (delegate to pool_owner_alive).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no new globals**, **no new env vars**, and **no on-disk layout**
(the layout is `$POOL_LANES_DIR/<N>.json`, established by M1, written by M3.T1.S1, read by
M3.T1.S2). It defines ONE function whose data contract is read-only over one lease file,
composing two LANDED functions. It touches no on-disk state.

| composed fn | source | contract relied upon | role here |
|---|---|---|---|
| `pool_lease_read(lane)` | M3.T1.S2 (LANDED @823) | echoes raw JSON + rc 0 on valid; rc 1 (silent stdout) on missing OR corrupt (logs 1 line on corrupt) | step (a)/(b): read the lease |
| `pool_owner_alive(pid, starttime, comm)` | M2.T2.S1 (LANDED @587) | rc 0 if alive+same; rc 1 (never fatal) if dead/comm-mismatch/st-mismatch/non-numeric-pid | step (c)/(d): the identity verdict (its rc is INVERTED) |

The three owner fields extracted (PRD §2.8 nested `owner` object):

| field path | JSON type | example | role |
|---|---|---|---|
| `owner.pid` | number | `836725` | pool_owner_alive arg 1 (liveness: /proc existence) |
| `owner.starttime` | number | `9276557` | pool_owner_alive arg 2 (identity: anti-recycle) |
| `owner.comm` | string | `pi` | pool_owner_alive arg 3 (identity: image name) |

**Naming** (CONTRACT-mandated, exact): `pool_lane_is_stale`. NOTE the work-item title
shortens it to `is_lane_stale`, but the CONTRACT body says *"Implement
`pool_lane_is_stale(lane)`"* — honor the contract verbatim. key_findings' naming table puts
`pool_lane_*` in the lane-lifecycle/query subdomain (this is a per-lane query). The M5.T3.S1
+ M5.T1.S1 consumers reference this exact name. No `_` prefix — it is a public entry point
(mirrors `pool_lanes_list`, `pool_lease_find_mine`, `pool_find_free_lane`). Internal-only in
practice.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_lease_read pool_owner_alive pool_lease_write pool_find_free_lane'
  - EXPECT: all four reported as functions. (pool_lease_read is M3.T1.S2 LANDED @823;
        pool_owner_alive is M2.T2.S1 LANDED @587; pool_lease_write is M3.T1.S1, used only
        to seed validation scenarios; pool_find_free_lane is S2 LANDED @1101 — confirms the
        append point.) If pool_lease_read OR pool_owner_alive is MISSING, STOP — this task
        hard-depends on both.
  - RUN (sanity-check the two composed contracts against the live library):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 me=$$; st="$(_pool_get_starttime "$me")"; comm="$(cat /proc/$me/comm)"; \
                 pool_owner_alive "$me" "$st" "$comm" && echo "OK alive->0"; \
                 pool_owner_alive 999999999 "1" "pi" && echo "BUG dead->0" || echo "OK dead->1"'
        # EXPECT: OK alive->0  AND  OK dead->1  (confirms pool_owner_alive's rc convention
        # — which this task INVERTS).
  - RUN (locate the append point — current EOF):
        tail -6 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^pool_find_free_lane\(\)' lib/pool.sh
  - EXPECT: the last function is pool_find_free_lane (~line 1101; file ~1109 lines).
        APPEND the new banner + function AFTER its closing brace. Do NOT touch any existing
        function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_lane_is_stale() to lib/pool.sh (the only function)
  - PLACEMENT: after a new banner line, directly below pool_find_free_lane()'s closing brace
        (current EOF, ~line 1108).
  - IMPLEMENT (verbatim-ready — paste this function body):
        # =============================================================================
        # Lease management — query operations (P1.M3.T2.S3)
        # =============================================================================
        # Per-lane staleness verdict for the lazy reaper. Implements PRD §2.5 (release is
        # owner-liveness-driven) + §2.14 (the three stale failure modes: pid dead / comm!=pi
        # / starttime mismatch) + §2.10 (reaper is lazy, on acquire). Reads a lane's lease,
        # extracts its owner.{pid,starttime,comm} triple, and delegates the identity check to
        # pool_owner_alive (M2.T2.S1). Consumed by the reaper (M5.T3.S1) and the acquire flock
        # step 3a REAP-STALE (M5.T1.S1) — it runs BEFORE pool_find_free_lane (step 3c) so freed
        # lane numbers are reusable in the same critical section.

        # pool_lane_is_stale LANE
        #
        # TRI-STATE verdict (NOT a boolean):
        #   0 = STALE     — owner dead/recycled/unverifiable → caller reaps the lane.
        #   1 = LIVE      — owner alive + identity matches → caller keeps the lane.
        #   2 = NO LEASE  — lease file missing OR corrupt → caller skips (nothing to reap).
        #
        # The rc convention is INVERTED vs pool_owner_alive (which returns 0=alive / 1=dead):
        #   pool_owner_alive -> 1 (dead)  ==>  pool_lane_is_stale -> 0 (stale)
        #   pool_owner_alive -> 0 (alive) ==>  pool_lane_is_stale -> 1 (live)
        # The inversion is deliberate: it makes the reaper idiom
        #   `if pool_lane_is_stale "$n"; then pool_release_lane "$n"; fi`
        # read naturally — rc 0 ("true") IS the "yes, stale" answer (shell convention).
        #
        # LOGIC (CONTRACT a→d):
        #   a. pool_lease_read "$lane". rc 1 (missing OR corrupt) → return 2 (skip).
        #   b. Extract owner.{pid,starttime,comm} from the in-memory JSON (ONE jq fork).
        #   c. pool_owner_alive "$pid" "$starttime" "$comm". rc 1 → return 0 (stale).
        #   d. rc 0 (alive) → return 1 (live).
        #
        # CONSUMERS: M5.T3.S1 reap_stale (the lazy reaper, per-lane in the scan loop);
        #   M5.T1.S1 acquire flock step 3a (reap-stale before choose-N).
        #
        # GOTCHA — CALLERS under set -e MUST guard: a BARE `pool_lane_is_stale "$n"` whose rc
        #   is 1 (live) or 2 (no lease) ABORTS the caller. Use `if pool_lane_is_stale "$n";
        #   then reap; fi` (rc 1/2 fall through) or `pool_lane_is_stale "$n" && rc=0 || rc=$?`
        #   to capture all three codes. Same hazard family as pool_lease_read/find_mine.
        # GOTCHA — compose ONLY pool_lease_read + pool_owner_alive (CONTRACT-named). Do NOT use
        #   pool_lease_field (3 extra reads + forks). Read ONCE, extract with ONE jq via mapfile.
        # GOTCHA — missing AND corrupt both → rc 2: pool_lease_read returns 1 for both; a corrupt
        #   lease can't identify the owner/chrome_pgid to kill safely, so skip (doctor M7.T4
        #   reconciles). pool_lease_read logs the ONE "corrupt lease" warning on the corrupt path.
        # GOTCHA — missing/garbled owner FIELDS → stale (rc 0): a valid-JSON lease with no owner
        #   object yields pid="null" → pool_owner_alive's own `[[ =~ ^[0-9]+$ ]]` rejects it →
        #   returns 1 → is_stale returns 0. SAFE (unverifiable → reaped, never trusted); needs
        #   NO special-case branch.
        # GOTCHA — mapfile -t is mandatory: strips trailing newlines so pid compares cleanly.
        # GOTCHA — jq reads the in-memory herestring (not the file): no TOCTOU, and jq cannot
        #   fail on parse (pool_lease_read already guaranteed valid JSON via _pool_json_valid).
        # NEVER calls pool_die / NEVER writes / NEVER kills / NEVER logs directly (read-only
        #   VERDICT; the caller acts). The only possible log line comes from pool_lease_read.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR, via pool_lease_read).
        pool_lane_is_stale() {
            local lane="${1:-}"
            local json pid starttime comm
            local -a _owner

            # (a) Read the lease. Validate lane (path-traversal defense; a non-numeric lane
            # simply "has no lease" → rc 2). `if !` is errexit-exempt — a bare capture would
            # ABORT under set -e when pool_lease_read returns 1 (missing OR corrupt). The
            # 2>/dev/null suppresses jq's corrupt-parse stderr (the warning is logged, not on
            # stderr, so diagnostics are preserved).
            [[ "$lane" =~ ^[0-9]+$ ]] || return 2
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                return 2
            fi

            # (b) Extract owner.{pid,starttime,comm} from the in-memory JSON in ONE jq fork.
            # Comma emits exactly 3 lines (one per expression; a missing .owner → three
            # "null" lines). mapfile -t strips trailing newlines → 3 clean elements. The
            # `:-` defaults defend an (impossible) short read. jq cannot fail here (valid JSON
            # guaranteed; herestring is in-memory — no file TOCTOU).
            mapfile -t _owner < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")
            pid="${_owner[0]:-}"
            starttime="${_owner[1]:-}"
            comm="${_owner[2]:-}"

            # (c)/(d) Delegate identity+liveness to pool_owner_alive and INVERT its rc.
            # pool_owner_alive: 0=alive → return 1 (live);  1=dead/recycled/non-numeric-pid
            # → return 0 (stale). The `if` is errexit-exempt (pool_owner_alive returns 1 on
            # the stale path — a bare call would abort; the if keeps it safe).
            if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then
                return 1     # live — owner is the same process that took the lease
            fi
            return 0          # stale — owner dead/recycled/unverifiable → caller reaps
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155); `[[ =~ ]] || return 2`
        (errexit-exempt + path-traversal-safe lane guard); `if ! json="$(pool_lease_read …)"`
        (the set -e-safe read guard); `mapfile -t` + herestring jq (one fork, clean capture);
        `if pool_owner_alive …; then return 1; fi; return 0` (the inverted delegation).
  - NAMING: pool_lane_is_stale (CONTRACT-mandated; do NOT rename).
  - PLACEMENT: the only function in the new "(P1.M3.T2.S3)" section.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_lane_is_stale' >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (LIVE owner = self, correct comm+starttime → rc 1):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 me=$$; st="$(_pool_get_starttime "$$")"; comm="$(cat /proc/$$/comm)"; \
                 pool_lease_write 1 "$TMP/a/1" 53421 abpool-1 "$me" "$comm" "$st" "$PWD" 100 100 true; \
                 if pool_lane_is_stale 1; then echo "FAIL rc=0(stale)"; else rc=$?; [[ "$rc" == 1 ]] && echo "OK live rc=$rc" || echo "FAIL rc=$rc"; fi'
        # EXPECT: OK live rc=1.
  - RUN (DEAD owner pid → rc 0 stale):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 2 "$TMP/a/2" 53422 abpool-2 999999999 pi 1234567 "$PWD" 200 200 true; \
                 if pool_lane_is_stale 2; then echo "OK stale rc=0"; else echo "FAIL rc=$?"; fi'
        # EXPECT: OK stale rc=0.
  - RUN (recycle-into-new-pi: live pid + WRONG starttime → rc 0 stale):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 me=$$; st="$(_pool_get_starttime "$$")"; \
                 pool_lease_write 3 "$TMP/a/3" 53423 abpool-3 "$me" pi 1 "$PWD" 300 300 true; \
                 if pool_lane_is_stale 3; then echo "OK stale(rc0) wrong-starttime"; else echo "FAIL rc=$?"; fi'
        # EXPECT: OK stale(rc0) wrong-starttime.
  - RUN (recycle-into-non-pi: live pid + WRONG comm → rc 0 stale):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 me=$$; st="$(_pool_get_starttime "$$")"; \
                 pool_lease_write 4 "$TMP/a/4" 53424 abpool-4 "$me" zzz "$st" "$PWD" 400 400 true; \
                 if pool_lane_is_stale 4; then echo "OK stale(rc0) wrong-comm"; else echo "FAIL rc=$?"; fi'
        # EXPECT: OK stale(rc0) wrong-comm.
  - RUN (NO lease file → rc 2):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 if pool_lane_is_stale 9; then echo "FAIL rc=0"; else rc=$?; [[ "$rc" == 2 ]] && echo "OK no-lease rc=$rc" || echo "FAIL rc=$rc"; fi'
        # EXPECT: OK no-lease rc=2.
  - RUN (CORRUPT lease → rc 2 + ONE log line):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 printf "NOT JSON{" > "$POOL_LANES_DIR/6.json"; \
                 if pool_lane_is_stale 6; then echo "FAIL rc=0"; else rc=$?; [[ "$rc" == 2 ]] && echo "OK corrupt rc=$rc" || echo "FAIL rc=$rc"; fi; \
                 grep -q "corrupt lease" "$(_pool_log_path)" && echo "OK corrupt logged" || echo "FAIL not logged"'
        # EXPECT: OK corrupt rc=2  AND  OK corrupt logged.
  - RUN (NON-NUMERIC lane (path-traversal) → rc 2):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 if pool_lane_is_stale "../etc"; then echo "FAIL rc=0"; else rc=$?; [[ "$rc" == 2 ]] && echo "OK bad-lane rc=$rc" || echo "FAIL rc=$rc"; fi'
        # EXPECT: OK bad-lane rc=2.
  - RUN (valid JSON but MISSING owner object → rc 0 stale):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 printf "{\"version\":1,\"lane\":7,\"port\":0,\"chrome_pid\":0,\"connected\":false}" > "$POOL_LANES_DIR/7.json"; \
                 if pool_lane_is_stale 7; then echo "OK missing-owner rc=0 (stale)"; else echo "FAIL rc=$?"; fi'
        # EXPECT: OK missing-owner rc=0 (stale).
  - RUN (CALLER set -e hazard — the if-guard is safe, a bare call is NOT):
        export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 me=$$; st="$(_pool_get_starttime "$$")"; comm="$(cat /proc/$$/comm)"; \
                 pool_lease_write 1 "$TMP/a/1" 53421 abpool-1 "$me" "$comm" "$st" "$PWD" 100 100 true; \
                 # the reaper idiom must NOT abort on rc 1 (live) or rc 2 (no lease):
                 for n in 1 2 3; do \
                     if pool_lane_is_stale "$n"; then echo "lane $n: STALE->reap"; \
                     else rc=$?; echo "lane $n: skip (rc=$rc)"; fi; \
                 done; echo "loop completed OK"'
        # EXPECT: lane 1: skip (rc=1) ; lane 2: skip (rc=2) ; lane 3: skip (rc=2) ; loop completed OK.
        #   (Proves the if-guard survives all three return codes under set -e.)
  - RUN (NEVER writes/kills/dies/log-directly — read-only verdict):
        bash -c '
            body="$(sed -n "/^pool_lane_is_stale() {/,/^}/p" lib/pool.sh)"
            # forbidden side effects (the ONLY allowed external is pool_lease_read + jq + pool_owner_alive)
            if grep -qE "pool_die|kill |\brm |>>? *[\"/]|\bmkdir " <<<"$body"; then
                echo "FAIL: body has forbidden side effects:"; echo "$body"; exit 1; fi
            grep -q "pool_lease_read"            <<<"$body" && echo "OK composes pool_lease_read"  || echo "FAIL: missing pool_lease_read"
            grep -q "pool_owner_alive"           <<<"$body" && echo "OK composes pool_owner_alive" || echo "FAIL: missing pool_owner_alive"
            grep -qE "return 0|return 1|return 2" <<<"$body" >/dev/null && echo "OK tri-state returns" || echo "FAIL: not tri-state"
        '
        # EXPECT: OK composes pool_lease_read ; OK composes pool_owner_alive ; OK tri-state returns ;
        #   (no FAIL on side effects). NOTE: is_lane_stale itself has no _pool_log call —
        #   the only possible log is transitively from pool_lease_read on a corrupt lease.
  - RUN (regression: all prior + new function still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any \
                      pool_find_free_lane pool_lane_is_stale >/dev/null && echo OK'
        # EXPECT: OK (all functions, including the new pool_lane_is_stale, callable).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the one function (paste under the new banner after pool_find_free_lane) ---

pool_lane_is_stale() {
    local lane="${1:-}"
    local json pid starttime comm
    local -a _owner

    [[ "$lane" =~ ^[0-9]+$ ]] || return 2                     # path-traversal-safe lane guard
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then  # (a) read; missing OR corrupt -> rc 2
        return 2
    fi

    # (b) extract owner triple in ONE jq fork (comma = 3 lines; mapfile -t strips newlines)
    mapfile -t _owner < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")
    pid="${_owner[0]:-}"
    starttime="${_owner[1]:-}"
    comm="${_owner[2]:-}"

    # (c)/(d) delegate to pool_owner_alive and INVERT: alive(0)->live(1); dead(1)->stale(0)
    if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then
        return 1     # live
    fi
    return 0          # stale (reap)
}

# --- Critical micro-rules baked into the above --------------------------------
#  * TRI-STATE return: 0=stale(reap), 1=live, 2=no-lease(skip). The 0=stale convention is
#    INVERTED from pool_owner_alive (0=alive) so `if pool_lane_is_stale "$n"; then reap; fi`
#    reads naturally. Easy to write backwards — the table in research §1 is authoritative.
#  * `if ! json="$(pool_lease_read …)"` — the set -e-safe read guard. pool_lease_read returns
#    1 for BOTH missing AND corrupt; both → rc 2 here. A bare capture would ABORT on rc 1.
#  * ONE jq fork via `mapfile -t < <(jq -r '.owner.pid, .owner.starttime, .owner.comm')` —
#    comma emits 3 lines, mapfile -t captures them clean. Do NOT use pool_lease_field×3
#    (CONTRACT names only pool_lease_read + pool_owner_alive; this is also cheaper: 1 read +
#    1 jq vs 3 reads + 3 jq, which matters inside the reaper's flock section — FINDING 2).
#  * `${comm:-pi}` — defensive default if owner.comm is empty/null. pool_owner_alive's own
#    `[[ "$pid" =~ ^[0-9]+$ ]]` rejects a null/empty pid → rc 1 → stale (rc 0). So a lease
#    with a missing owner object resolves to STALE with no special-case branch.
#  * NEVER pool_die / NEVER write / NEVER kill / NEVER log directly (read-only VERDICT). The
#    caller (reap_stale/release) acts. The only possible log line is transitively from
#    pool_lease_read on a corrupt lease.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_lease_read(lane) (M3.T1.S2 @823): the contract-named reader. Echoes raw JSON + rc 0
        on valid; rc 1 (silent stdout, logs 1 line on corrupt) on missing/corrupt. THIS task's
        `if ! json="$(pool_lease_read …)"; then return 2; fi` relies on EXACTLY this. The JSON
        it returns is guaranteed valid → the downstream jq cannot fail on a parse error.
  - pool_owner_alive(pid, starttime, comm) (M2.T2.S1 @587): the contract-named identity
        predicate. rc 0 if alive+same; rc 1 (never fatal) if dead/comm-mismatch/st-mismatch/
        non-numeric-pid. THIS task INVERTS its rc. Its input validation makes missing owner
        fields resolve to stale (rc 0) with no special case.
  - pool_lease_write (M3.T1.S1): NOT called by this function — used only by the validation
        scenarios to seed leases.

CALLER (future — M5.T3.S1 reap_stale + M5.T1.S1 acquire step 3a, NOT built here):
  - reap_stale iterates `for n in $(pool_lanes_list)` and calls `if pool_lane_is_stale "$n";
        then pool_release_lane "$n"; fi`. The if-guard is MANDATORY (a bare call aborts under
        set -e on rc 1/2 — research §2). reap_stale runs INSIDE the acquire flock and BEFORE
        pool_find_free_lane (step 3a before 3c) so freed lane numbers are reusable.
  - acquire step 3a may call pool_lane_is_stale directly (or via reap_stale) inside flock.

NO INTEGRATION WITH S1/S2: pool_lane_is_stale does NOT call pool_lanes_list /
  pool_lease_find_mine / pool_find_free_lane. It takes ONE lane arg; lane enumeration is the
  caller's job. It is a sibling under the "query operations" umbrella (verdict per lane).

CONFIG / DATABASE / ROUTES: none. No new env vars, no globals, no dir I/O, no lease writes.
The only thing read is one lease file (via pool_lease_read) + /proc (via pool_owner_alive).
No user docs ("internal function"). Pure in-memory verdict appended to the library.
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
# (These are the exact host-verified commands from Task 2 — run them all.)

# LIVE (self owner) → rc 1
export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         me=$$; st="$(_pool_get_starttime "$$")"; comm="$(cat /proc/$$/comm)"; \
         pool_lease_write 1 "$TMP/a/1" 53421 abpool-1 "$me" "$comm" "$st" "$PWD" 100 100 true; \
         if pool_lane_is_stale 1; then echo "FAIL rc=0"; else rc=$?; [[ "$rc" == 1 ]] && echo "OK live rc=$rc" || echo "FAIL rc=$rc"; fi'
# Expected: OK live rc=1.

# DEAD / WRONG-STARTTIME / WRONG-COMM → rc 0 (stale) ; NO-LEASE → rc 2 ; CORRUPT → rc 2 (+log)
# NON-NUMERIC lane → rc 2 ; MISSING-OWNER → rc 0 ; caller set -e if-guard → loop completed OK
# (see Task 2 VERIFY block for the exact commands — all are host-verified to print OK.)

# Expected: every probe prints OK. If FAIL, debug root cause and fix before proceeding.
```

### Level 3: Integration Testing (System Validation)

```bash
# Reaper-scan simulation: reap_stale (M5.T3.S1) is OUT OF SCOPE, but we CAN prove the
# is_lane_stale → (caller reaps via pool_release_lane handoff) loop works under the natural
# reaper idiom, and that a re-run after reaping reports the lane as no-lease (rc 2).

export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         me=$$; st="$(_pool_get_starttime "$$")"; comm="$(cat /proc/$$/comm)"; \
         # lane 1: live (me); lane 2: stale (dead owner); lane 3: no lease
         pool_lease_write 1 "$TMP/a/1" 53421 abpool-1 "$me" "$comm" "$st" "$PWD" 100 100 true; \
         pool_lease_write 2 "$TMP/a/2" 53422 abpool-2 999999999 pi 1 "$PWD" 200 200 true; \
         # simulate the reaper scan: reap rc-0 lanes only (delete the lease as release would)
         reaped=""; for n in $(pool_lanes_list); do \
             if pool_lane_is_stale "$n"; then reaped="$reaped $n"; rm -f "$POOL_LANES_DIR/$n.json"; fi; \
         done; \
         echo "reaped lanes:$reaped"; \
         # after reaping, the stale lane must now report no-lease (rc 2); the live one still rc 1
         if pool_lane_is_stale 1; then echo "FAIL 1 stale"; else echo "lane 1 kept (rc=$?)"; fi; \
         if pool_lane_is_stale 2; then echo "FAIL 2 stale"; else echo "lane 2 now no-lease (rc=$?)"; fi'
# Expected: reaped lanes: 2 ; lane 1 kept (rc=1) ; lane 2 now no-lease (rc=2).
#   (Proves the verdict drives a correct reap in the natural caller idiom, and is idempotent
#    on re-scan — the reaped lane is gone, so the next scan skips it.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Re-entrant / stateless reasoning check: the function is a pure read-only verdict (no side
# effects), so calling it twice on the same lane yields the same rc. This is what makes the
# reaper safe to re-run on every acquire (idempotent).

export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         me=$$; st="$(_pool_get_starttime "$$")"; comm="$(cat /proc/$$/comm)"; \
         pool_lease_write 1 "$TMP/a/1" 53421 abpool-1 "$me" "$comm" "$st" "$PWD" 100 100 true; \
         # capture rc via the safe idiom (bare call would abort on rc 1)
         pool_lane_is_stale 1 && a=0 || a=$?; \
         pool_lane_is_stale 1 && b=0 || b=$?; \
         [[ "$a" == "$b" ]] && echo "OK idempotent (a=b=$a)" || echo "FAIL a=$a b=$b"'
# Expected: OK idempotent (a=b=1) — proves the function is a pure verdict with no side
# effects, so the caller's flock + re-scan is safe and repeatable.

# Anti-recycling confidence check: confirm the (pid, starttime) triple really distinguishes
# a recycled PID from the original (the whole reason this verdict delegates to pool_owner_alive).
export TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AGENT_BROWSER_POOL_STATE="$TMP/state" AGENT_BROWSER_POOL_LOG_PATH="$TMP/pool.log" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         # launch a child, record its starttime, lease a lane to it, then kill+wait the child
         sleep 100 & c=$!; cst="$(_pool_get_starttime "$c")"; \
         pool_lease_write 5 "$TMP/a/5" 53425 abpool-5 "$c" sleep "$cst" "$PWD" 500 500 true; \
         kill -9 "$c" 2>/dev/null || true; wait "$c" 2>/dev/null || true; \
         # the lane must now be STALE (rc 0) — the owner pid is dead
         if pool_lane_is_stale 5; then echo "OK dead-child lane stale (rc=0)"; else echo "FAIL rc=$?"; fi'
# Expected: OK dead-child lane stale (rc=0) — the verdict correctly detects a dead owner.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully
- [ ] `bash -n lib/pool.sh` clean
- [ ] `shellcheck lib/pool.sh` clean (whole file, zero warnings)
- [ ] No prior function altered (diff is append-only under the new banner)

### Feature Validation

- [ ] All success criteria from "What" section met
- [ ] Live owner (self, correct comm+starttime) → rc **1**
- [ ] Dead owner pid → rc **0** (stale)
- [ ] Live pid + wrong starttime (recycle-into-new-pi) → rc **0** (stale)
- [ ] Live pid + wrong comm (recycle-into-non-pi) → rc **0** (stale)
- [ ] No lease file → rc **2**; corrupt lease → rc **2** + one `corrupt lease` log line
- [ ] Non-numeric lane (`../etc`) → rc **2** (path-traversal-safe)
- [ ] Valid JSON but missing `owner` object → rc **0** (stale; unverifiable → reaped)
- [ ] Caller set -e hazard confirmed: the `if pool_lane_is_stale …; then reap; fi` idiom
      survives rc 1/2 (loop completed OK); a bare call would abort (documented)
- [ ] Tri-state return is exactly {0=stale, 1=live, 2=no-lease} (inverted vs pool_owner_alive)

### Code Quality Validation

- [ ] Follows existing codebase patterns and naming conventions (CONTRACT-mandated
      `pool_lane_is_stale`; banner style matches S1/S2's "query operations" sections)
- [ ] File placement matches the desired codebase tree (append at EOF under new banner)
- [ ] Anti-patterns avoided (check against Anti-Patterns section)
- [ ] Composes ONLY `pool_lease_read` + `pool_owner_alive` (no `pool_lease_field`, no
      re-parsing of /proc, no `pool_lanes_list`)
- [ ] No new globals, no new env vars, no new external dependencies

### Documentation & Deployment

- [ ] The function's leading comment block documents: the tri-state contract + the inversion
      vs pool_owner_alive, the caller set -e hazard + the safe idiom, the composition choice
      (read once + one jq), missing/corrupt → rc 2 rationale, missing-owner → rc 0 rationale,
      the mapfile -t requirement, and the read-only/no-pool_die/no-direct-log guarantee
- [ ] No user-facing docs needed (internal function; CONTRACT §5: "DOCS: none")
- [ ] No environment variables added

---

## Anti-Patterns to Avoid

- ❌ Don't INVERT the rc backwards — `pool_owner_alive` returns 0=alive/1=dead; `pool_lane_is_stale`
  returns **0=stale/1=live**. The mapping: alive→0 becomes live→**1**; dead→1 becomes stale→**0**.
  Getting this backwards makes the reaper reap LIVE lanes and keep STALE ones (catastrophic).
  The table in research §1 is authoritative.
- ❌ Don't call `pool_lane_is_stale` as a BARE command under set -e — rc 1 (live) or 2 (no lease)
  ABORTS the caller. Always `if pool_lane_is_stale "$n"; then reap; fi` or capture with
  `… && rc=0 || rc=$?`. (Same hazard as pool_lease_read/find_mine.)
- ❌ Don't use `pool_lease_field` ×3 to read the owner triple — the CONTRACT names only
  `pool_lease_read` + `pool_owner_alive`, and field×3 is 3 disk reads + 3 jq forks (slow inside
  the reaper's flock). Read ONCE via `pool_lease_read`, extract with ONE `jq -r '.owner.pid,
  .owner.starttime, .owner.comm'` + `mapfile -t`.
- ❌ Don't re-parse `/proc/<pid>/stat` or re-implement the identity check — delegate to
  `pool_owner_alive` (it already composes `_pool_get_starttime`, the one canonical parser).
- ❌ Don't distinguish "missing" from "corrupt" inside this function — `pool_lease_read` returns 1
  for both, and BOTH map to rc 2 (skip). A corrupt lease can't identify the owner/pgid to kill
  safely; doctor (M7.T4) reconciles. Don't add a second read path.
- ❌ Don't `pool_die` on a missing/corrupt lease or a missing owner — those are NORMAL scan
  results (rc 2 / rc 0 respectively). This function is a read-only VERDICT; it never exits the
  process.
- ❌ Don't `kill` / `rm` / delete the lease / `mkdir` inside this function — teardown is
  `pool_release_lane` (M5.T2.S1), called by the CALLER on rc 0. is_lane_stale only ANSWERS.
- ❌ Don't `_pool_log` directly from this function — it runs in the reaper scan loop; per-lane
  logging floods the pool log. The caller logs the DECISION; the only log line is transitively
  from `pool_lease_read` on a corrupt lease.
- ❌ Don't forget `mapfile -t` (the `-t`) — without it each element keeps its trailing newline
  and the pid/starttime comparisons silently fail.
- ❌ Don't rename `pool_lane_is_stale` to `is_lane_stale` / `pool_lanes_is_stale` / etc. — the
  CONTRACT body mandates `pool_lane_is_stale`; the M5.T3.S1 + M5.T1.S1 consumers reference it.
- ❌ Don't enumerate lanes inside this function — it takes ONE lane arg; `pool_lanes_list`
  iteration is the caller's job.
- ❌ Don't skip validation because "it should work" — every scenario in Task 2 is host-verified
  to print OK; run them all (especially the rc-inversion ones and the caller set -e hazard).

---

**Confidence Score: 9/10** for one-pass implementation success. The function is a single,
host-verified ~14-line verdict composing two LANDED functions (contracts pinned), with an
exact prototype that passed all 8 scenarios + the set -e hazard + the herestring form. The
one residual risk is the **rc inversion** (0=stale is counter-intuitive vs pool_owner_alive's
0=alive) — which is why the PRP foregrounds it in the Goal, the What table, the gotchas, the
comment block, and the anti-patterns, and why the Task 2 validation explicitly asserts each
rc. A careful implementer who runs the Task 2 probes cannot ship it backwards (the probes
fail loudly if the rc is inverted).
