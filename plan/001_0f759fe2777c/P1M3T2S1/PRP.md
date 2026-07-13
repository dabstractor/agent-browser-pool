# PRP — P1.M3.T2.S1: Enumerate lanes + `find_my_lease(owner)`

---

## Goal

**Feature Goal**: Implement the **lease query layer** of `lib/pool.sh` — the first
functions that *iterate across lanes* and *correlate a lease's stored owner with the live
owner globals*. This is PRD §2.4 step 2 ("Find MY lease: scan `lanes/*.json` for
`owner.pid==pid && comm=="pi" && starttime match`") made executable, plus the lane
enumerator and the diagnostic variant. It sits directly above the lease I/O layer (S1
write/update + S2 read/field/exists — **both already landed** in `lib/pool.sh`) and the
owner-identity predicate (`pool_owner_alive`, M2.T2.S1 — landed). It is the wrapper's
"do I already own a lane?" oracle: a `0 + echo N` answer means *reuse lane N*; a `1` answer
means *go acquire* (PRD §2.4 step 3).

Three functions, appended at EOF of `lib/pool.sh`:

1. **`pool_lanes_list()`** — enumerate every numeric lane stem from
   `$POOL_LANES_DIR/*.json`, echo each N on its own line (numerically sorted ascending),
   return 0 always (an empty pool is a valid state). Defensive: filters out non-files
   (no-match glob literal, subdirs) and non-numeric stems via `^[0-9]+$`.

2. **`pool_lease_find_mine()`** — iterate all lanes; for each, read `owner.pid` via
   `pool_lease_field`; if `owner.pid == POOL_OWNER_PID` **and** `pool_owner_alive(pid,
   starttime, comm)` returns 0 → echo that lane N and return 0. If no valid match → return 1.
   Cheap-equality-first ordering (pid string-equality before the 3× `/proc` liveness read).
   Non-fatal (never `pool_die`); corrupt lanes are skipped, not fatal.

3. **`pool_lease_find_mine_any()`** — like `find_mine` but returns the lane as soon as
   `owner.pid == POOL_OWNER_PID` **regardless of liveness** (no `pool_owner_alive` call).
   Diagnostic: surfaces a *stale* lease that nonetheless names this PID (for the reaper /
   doctor / `release` self-cleanup paths).

**Deliverable**:
1. Three functions appended to `lib/pool.sh` under a new
   `# Lease management — query operations (P1.M3.T2.S1)` banner, placed directly after
   `pool_lease_exists()` (the current EOF, line 931). Order: `pool_lanes_list` first (the
   other two call it) → `pool_lease_find_mine` → `pool_lease_find_mine_any`.
2. No new globals, no new env vars, no new files, no new external dependencies. Pure
   additions. Composes the already-landed layers: `pool_lease_field` (S2), `pool_owner_alive`
   (M2.T2.S1); reads `POOL_OWNER_PID` + `POOL_LANES_DIR` (frozen by `pool_config_init` /
   `pool_owner_resolve`).
3. Every branch is **host-verified** (2026-07-12) via a prototype appended to the real
   `lib/pool.sh` — see `research/lanes-list-and-find-mine.md`. All 7 scenarios passed.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
  pool_owner_resolve` (with `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME` set to a live
  self-PID + its real starttime), seeding lane 7 as mine + lanes 5/9 as others, then
  `n="$(pool_lease_find_mine)"` (guarded) ⟹ `n==7`.
- `pool_lanes_list` on an empty/missing dir ⟹ no output, return 0; on lanes
  `{2,3,7,100}.json` + a `foo.json` junk file + a `sub.json/` dir ⟹ echoes `2 3 7 100` (one
  per line, sorted), return 0.
- A **stale** lane (pid matches, starttime mismatches) ⟹ `find_mine` returns 1, silent;
  `find_mine_any` returns 0 and echoes that lane.
- A **corrupt** lane (`printf 'NOT JSON{'`) is skipped (not fatal); a valid mine among other
  lanes is still found.
- `POOL_OWNER_PID` unset/empty ⟹ both find functions return 1 immediately (no scan).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1, M2.\*, M3.T1.S1, M3.T1.S2) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls these directly.
Consumers are later subtasks inside `lib/pool.sh` and the two wrappers:

- **P1.M6.T3.S1** (wrapper lifecycle step 2) — the **primary** consumer: after
  `pool_owner_resolve`, calls `pool_lease_find_mine`; on rc 0 reuses lane N (step 4), on
  rc 1 proceeds to ACQUIRE (step 3). PRD §2.4 step 2. **This is the single hot-path call.**
- **P1.M5.T1.S3** (`ensure_connected`) — on every invocation, confirm the lane's owner is
  still alive before reuse; `find_mine` is the reuse gate.
- **P1.M5.T3.S1** (`reap_stale`) — uses `pool_lanes_list` to enumerate; uses
  `find_mine_any`-style "lease names a PID" correlation for the self-reap / diagnostic path.
- **P1.M7.T4.S1** (`doctor`) — `pool_lanes_list` to enumerate all lanes for reconciliation
  vs live Chromes vs dirs; `find_mine_any` to surface "you own a stale lane".
- **P1.M7.T1.S1** (admin `status`) — `pool_lanes_list` to iterate the table rows.
- **P1.M5.T4.S1** (pool exhaustion force-reap) — enumerate to find the oldest dead-owner lane.

**Use Case**: On *every* `agent-browser` invocation the wrapper resolves the owner then
asks "do I already hold a valid lane?" — `pool_lease_find_mine` answers that in one call.
`pool_lanes_list` is the shared enumerator behind every scan (reap, status, doctor, force-reap).
`find_mine_any` answers "is there a lane that CLAIMS to be mine even though it's stale?" —
the diagnostic for leaks and crash recovery.

**Pain Points Addressed**:
- **No cheap reuse gate ⟹ every call re-acquires (a 5–10 s Chrome boot).** `find_mine` makes
  lane reuse O(lanes) string compares + at most one liveness check, so a returning agent
  reuses its browser instantly (PRD §2.4 step 2 ⟹ step 4).
- **PID recycling ⟹ lane theft.** Checking *only* `owner.pid == POOL_OWNER_PID` would bind a
  recycled PID to a dead owner's lane. `find_mine` delegates the identity check to
  `pool_owner_alive(pid, starttime, comm)` — the (pid, comm, starttime) triple defeats
  recycling (PRD §2.8, §2.14).
- **A corrupt/mid-deletion lease must not abort the hot path.** `pool_lease_field` returns 1
  on corrupt; `find_mine`/`find_mine_any` `|| continue` past it, so one bad lane never breaks
  the wrapper (PRD §2.14 defensive recovery).
- **"I own a stale lane" must be diagnosable separately from "I own a valid lane."** The
  reaper/doctor need to surface leases whose owner.pid names this PID but whose owner is
  dead — that is `find_mine_any`; `find_mine` deliberately excludes them.

## Why

- **This is the reuse decision, on the hottest path in the system.** Every `agent-browser`
  call runs the wrapper (M6), which runs owner-resolve then `find_mine`. A correct, cheap,
  non-fatal `find_mine` is the difference between instant reuse and a redundant 5–10 s
  Chrome boot per call. PRD §2.4 step 2.
- **It composes the (already-landed) I/O + identity layers — it adds no new mechanism, only
  correlation.** `pool_lease_field` (S2) reads the nested owner fields; `pool_owner_alive`
  (M2.T2.S1) checks liveness+identity; `pool_lanes_list` enumerates. This task is the thin
  orchestrator that wires "for each lane, compare pid, then verify alive" — exactly the
  PRD §2.4 step 2 algorithm.
- **Return-1 (not `pool_die`) is the whole point.** Like the S2 read layer, "no lease" /
  "no match" is a *normal, branchable* result — the wrapper's signal to acquire. A fatal
  `find_mine` would crash every first-ever invocation (empty pool). This mirrors
  `_pool_json_valid`, `pool_owner_alive`, and the S2 readers: non-fatal by design.
- **`find_mine_any` separates "valid mine" from "claiming mine."** Without it, the reaper
  and doctor would have to re-implement the pid-equality scan. Centralizing it here gives
  them one consistent helper and documents the §2.10/§2.14 diagnostic intent.

## What

User-visible behavior: none directly (internal library queries). Observable contract:

| Function | Args | Returns / side effects | Failure mode |
|---|---|---|---|
| `pool_lanes_list` | (none) | Echo each numeric lane N (one per line, `sort -n`), return 0. | Empty/missing dir or all-non-numeric ⟹ no output, return 0 (never fails). |
| `pool_lease_find_mine` | (none; reads `POOL_OWNER_PID`) | On the (≤1) lane whose `owner.pid==POOL_OWNER_PID` AND `pool_owner_alive` ⟹ 0: echo N, return 0. | `POOL_OWNER_PID` non-numeric/empty ⟹ return 1. No pid match ⟹ return 1. pid match but stale ⟹ return 1. Corrupt lane ⟹ skipped. Never fatal. |
| `pool_lease_find_mine_any` | (none; reads `POOL_OWNER_PID`) | On the first lane whose `owner.pid==POOL_OWNER_PID`: echo N, return 0 (regardless of liveness). | `POOL_OWNER_PID` non-numeric/empty ⟹ return 1. No pid match ⟹ return 1. Corrupt lane ⟹ skipped. Never fatal. |

**Semantics notes**:
- **"One owner holds ≤1 lane" (PRD §2.8)** is an invariant the acquire flow (M5) enforces.
  `find_mine`/`find_mine_any` therefore return the *first* pid-matching lane; in correct
  operation that is the *only* one. Scanning past a pid-match-but-stale lane (rather than
  returning immediately) is deliberate robustness against an invariant violation and costs
  nothing.
- **Cheap-equality-first**: `find_mine` does the `owner.pid == POOL_OWNER_PID` string
  compare *before* `pool_owner_alive` (3× `/proc` reads). Most lanes are not mine; this
  avoids the reads for them. The CONTRACT explicitly specifies this ordering ("owner.pid ==
  POOL_OWNER_PID AND pool_owner_alive(...)").
- **Corrupt/mid-deletion lanes are skipped** via `pool_lease_field … || continue`
  (`pool_lease_field` returns 1 on missing/corrupt — S2 contract). One bad lane never aborts
  the scan. This is essential because `find_mine` runs on the hot wrapper path under
  `set -euo pipefail`.
- **`POOL_OWNER_PID == "0"` (passthrough)**: the `^[0-9]+$` guard passes `0`; the loop then
  finds no real pid == 0 ⟹ return 1 (correct — passthrough mode has no lane). An
  unset/empty/non-numeric global is rejected by the guard ⟹ return 1 without scanning.

### Success Criteria

- [ ] All three functions defined in `lib/pool.sh` under a
      `# Lease management — query operations (P1.M3.T2.S1)` banner, directly after
      `pool_lease_exists()` (line ~931). Callable after `source lib/pool.sh`.
- [ ] `pool_lanes_list` on an empty/missing `POOL_LANES_DIR` ⟹ no output, return 0.
- [ ] `pool_lanes_list` with `{2,3,7,100}.json` + `foo.json` + a `sub.json/` dir ⟹ echoes
      `2`, `3`, `7`, `100` (one per line, numerically sorted), return 0.
- [ ] `pool_lease_find_mine` with lane 7 mine (live self) + lanes 5/9 others ⟹ echoes `7`,
      return 0.
- [ ] `pool_lease_find_mine` with no pid match ⟹ return 1, silent.
- [ ] `pool_lease_find_mine` with a stale lane (pid match, starttime mismatch) ⟹ return 1,
      silent; **same setup** `pool_lease_find_mine_any` ⟹ echoes that lane, return 0.
- [ ] `pool_lease_find_mine` with a corrupt lane (`printf 'NOT JSON{'`) among others ⟹ the
      corrupt lane is skipped and a valid mine is still found (return 0 + echo N).
- [ ] `POOL_OWNER_PID` unset/empty ⟹ both find functions return 1 immediately (no scan, no
      output).
- [ ] All three functions are **non-fatal**: none ever calls `pool_die`; a corrupt lease or
      no-match returns 1 (the caller's shell survives — critical because `find_mine` runs on
      the hot wrapper path).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.T1.S1, M3.T1.S2) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified behavior of the
glob-no-match-then-`[[ -f ]]`-filter idiom and `sort -n` enumeration (research §1, all run on
this host 2026-07-12); the exact already-landed functions to compose (`pool_lease_field`'s
return-1-on-corrupt + nested-path contract, `pool_owner_alive`'s `(pid, starttime, comm)`
signature, `pool_owner_resolve`'s globals); the exact append point (after `pool_lease_exists`
at line ~931); the **caller-side `set -e` gotcha** (research §2 — a bare
`n="$(pool_lease_find_mine)"` aborts the wrapper; the correct idiom is `if n="$(…)"`); the
exact consumer contract (M6.T3 step 2 reuse-vs-acquire, M5.T3 reap, M7 status/doctor); and
copy-pasteable, host-verified validation commands for every behavior (all 7 scenarios
passed in a prototype run).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 2 (the EXACT algorithm: "scan lanes/*.json for owner.pid==pid &&
        comm=='pi' && starttime match; Found & valid → reuse lane N"; this task IS that step),
        §2.8 (lease schema + the "One owner holds ≤1 lane" invariant + starttime defeats PID
        recycling), §2.5 (release is owner-liveness-driven → find_mine must verify liveness,
        not just pid), §2.10 (lazy reaper on acquire → consumes the enumeration), §2.14
        (corrupt/stale leases are expected + recovered, not fatal → skip, don't die), §2.2
        (no bare ~ — POOL_LANES_DIR is already absolute), §2.18 (test-hook overrides for the
        owner globals — how tests simulate distinct agents without real pi ancestors).
  pattern: §2.4 step 2 is the literal pseudocode for pool_lease_find_mine.
  gotcha: §2.8's starttime is the anti-recycling key → find_mine MUST delegate to
        pool_owner_alive (not just pid equality), else a recycled PID steals a lane.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 1 (starttime parsing → _pool_get_starttime, the value compared by
        pool_owner_alive), FINDING 8 (test-hook overrides AGENT_BROWSER_POOL_OWNER_PID/
        _STARTTIME — how the test harness simulates owners), and the "Function Naming
        Convention" (pool_lease_* = lease read/write/query; pool_lanes_list belongs to the
        broader lane family since it enumerates NUMBERS not lease records).
  pattern: naming table reserves pool_lease_* for this subdomain.
  gotcha: FINDING 8 hooks are test-only, narrowly scoped — never expose in user docs.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §6 (Lease JSON Schema v1 — byte-identical to PRD §2.8; owner is a NESTED object so
        owner.pid/owner.starttime/owner.comm need nested-path reads), §4 (jq at /usr/bin/jq;
        sort/findmnt/etc. are coreutils — all present), §5 (POOL_LANES_DIR derived =
        $POOL_STATE_DIR/lanes).
  pattern: §6 schema is the read contract this task queries.
  gotcha: none new.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout: lanes/<N>.json is what pool_lanes_list enumerates), §2
        (jq 1.8.2 confirmed; bash 5.x).
  pattern: §7 → enumeration target is $POOL_LANES_DIR/*.json.
  gotcha: the dir may be empty/missing on a first run — pool_lanes_list MUST treat that as
        "no lanes" (return 0, no output), NOT an error.

# This task's own research (host-verified prototype — all 7 scenarios passed)
- file: plan/001_0f759fe2777c/P1M3T2S1/research/lanes-list-and-find-mine.md
  why: the deep brief on (a) the glob-no-match + [[ -f ]] + numeric-filter + sort -n
        enumeration (§1), (b) the cheap-equality-first + pool_owner_alive delegation + the
        caller-side set -e idiom (§2), (c) find_mine_any's diagnostic role (§3), (d) naming/
        placement/scope (§4). Every code block's stated behavior was re-run on this host.
  pattern: §1 (pool_lanes_list body), §2 (find_mine body + the `if n="$(…)"` caller idiom),
        §3 (find_mine_any body).
  gotcha: §2 — a bare `n="$(pool_lease_find_mine)"` ABORTS the caller under set -e on the
        rc-1 path. Use `if n="$(pool_lease_find_mine)"; then …`.

# The layers THIS task composes (all LANDED in lib/pool.sh — treated as contract)
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_field / pool_lease_exists (S2)
  why: S2 defines pool_lease_field (injection-safe getpath read; returns 1 on missing/
        corrupt; missing FIELD → echoes "null" rc 0; supports NESTED owner.pid /
        owner.starttime / owner.comm) and pool_lease_exists (predicate). find_mine/
        find_mine_any call pool_lease_field per lane; the `|| continue` on its rc-1 is the
        corrupt-skip mechanism. S2's PRP §6 lists THIS task (P1.M3.T2.S1) as a consumer.
  pattern: S2's read-side convention — return 1 (never pool_die), `[[ ]] || return 1`,
        compose _pool_json_valid. THIS task follows the SAME convention (find_mine/
        find_mine_any return 1, never die).
  gotcha: pool_lease_field returns 1 on a corrupt/missing lease → MUST `|| continue` in the
        scan loop, else set -e aborts find_mine on the first bad lane.

- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md    # pool_lease_write (S1) — for test seeding
  why: S1 defines pool_lease_write (the full lease builder). The validation commands in THIS
        PRP seed lanes via pool_lease_write to construct realistic find_mine scenarios. Also
        defines the "Lease management" section banner this task appends under.
  pattern: pool_lease_write LANE EPHEM PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME
        OWNER_CWD CHROME_PID CHROME_PGID CONNECTED.
  gotcha: connected must be the literal true/false; owner_comm/owner_cwd are strings.

- file: plan/001_0f759fe2777c/P1M2T2.S1/PRP.md   # pool_owner_alive — the identity predicate
  why: pool_owner_alive(pid, expected_starttime, expected_comm="pi") returns 0 (alive + same
        process) / 1 (dead / recycled / comm or starttime mismatch). find_mine delegates the
        "is this a VALID mine" check to it. NEVER fatal — so `if pool_owner_alive …; then` is
        the correct (non-aborting) branch.
  pattern: `(pid, starttime, comm)` triple; cheapest-first decision ladder; return 1 not die.
  gotcha: pass the LEASE's stored starttime + comm (so the predicate compares them against
        the LIVE process) — that is what makes recycling detectable.

- file: plan/001_0f759fe2777c/P1M2T1S1/PRP.md    # pool_owner_resolve — sets the owner globals
  why: pool_owner_resolve populates POOL_OWNER_PID (== "0" ⟺ passthrough), POOL_OWNER_COMM,
        POOL_OWNER_STARTTIME, POOL_OWNER_CWD, and honors the AGENT_BROWSER_POOL_OWNER_PID /
        _STARTTIME test hooks. find_mine/find_mine_any read POOL_OWNER_PID.
  pattern: test hooks let validation simulate owners from distinct PIDs without real pi.
  gotcha: in passthrough (no pi ancestor) POOL_OWNER_PID == "0" → find_mine naturally returns
        1 (no real pid == 0 lease).

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md    # pool_config_init — freezes POOL_LANES_DIR
  why: pool_config_init freezes the ABSOLUTE POOL_LANES_DIR this task globs. PRECONDITION.
  pattern: POOL_LANES_DIR is $POOL_STATE_DIR/lanes, canonicalized, absolute.
  gotcha: do NOT re-resolve paths — trust the frozen POOL_LANES_DIR.

# External authoritative docs (for the HOW)
- url: https://www.gnu.org/software/bash/manual/bash.html#Pattern-Matching
  why: the `"$POOL_LANES_DIR"/*.json` glob and the no-match behavior (without nullglob the
        glob expands to its literal, which `[[ -f ]]` then rejects). This is the core
        enumeration mechanic.
  section: "Filename Expansion" + "Pattern Matching".
  critical: nullglob is NOT set in lib/pool.sh → a no-match glob stays literal; the `[[ -f ]]
        || continue` guard is MANDATORY (verified 2026-07-12).

- url: https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion
  why: `${f##*/}` (longest-prefix strip to the filename) and `${base%.json}` (shortest-
        suffix strip of the extension) — pure-bash stem extraction, no `basename` fork.
  section: "${parameter##word}", "${parameter%word}".

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (set -e) propagates into callers (the wrapper). Because find_mine/find_mine_any
        return 1 for the NORMAL "no match" case, a caller's bare `n="$(pool_lease_find_mine)"`
        ABORTS; the correct idiom is `if n="$(pool_lease_find_mine)"; then …`. (Host-verified:
        S2's research §2 documents the identical hazard for pool_lease_read.)
  section: `-e` (errexit).

- url: https://www.gnu.org/software/coreutils/manual/html_node/sort-invocation.html
  why: `sort -n` for deterministic ascending numeric lane order. GNU coreutils (guaranteed
        present; external_deps.md §4).
  section: "-n, --numeric-sort".

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local n; n="$(…)"` not `local n="$(…)"`. The find
        functions capture pool_lease_field into locals; follow the two-statement form so a
        command-substitution failure is observable (less critical here because of `|| continue`,
        but the pattern holds for the lane/file locals).
- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: quote expansions (`"$POOL_LANES_DIR"/*.json` keeps the glob but quotes the dir;
        `"$pid"`, `"$POOL_OWNER_PID"`, `"$n"` all quoted). The one INTENTIONAL unquoted
        expansion is `for n in $(pool_lanes_list)` — output is digits-only/newline-separated
        (research §1), so word-splitting is the desired behavior.
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.S1 (writers), M3.T1.S2 (readers)** have all
landed (verified: `grep` shows `pool_lease_write`/`_update`/`_read`/`_field`/`_exists` all
present, file is 931 lines):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty
├── lib/
│   └── pool.sh                           # 931 lines: set -euo pipefail + pool_die/_pool_log (S1)
│                                         #   + _pool_config_* + pool_config_init (S2)
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.S1/.S2)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)  ← line 931 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M3T1S2/PRP.md
    └── P1M3T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/lanes-list-and-find-mine.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND three query functions under a new banner after line 931:
                  #   # Lease management — query operations (P1.M3.T2.S1)
                  #   pool_lanes_list()          — enumerate numeric lane stems (sorted)
                  #   pool_lease_find_mine()     — first valid (pid+alive) lane owned by me
                  #   pool_lease_find_mine_any() — first lane claiming to be mine (any liveness)
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **lease query layer** — the cross-lane iterators and the owner-correlation queries. It
composes the S2 read helpers (`pool_lease_field`), the M2.T2.S1 identity predicate
(`pool_owner_alive`), and the M2.T1.S1 owner globals (`POOL_OWNER_PID`); it is consumed by
the wrapper lifecycle (M6.T3), the reap/ensure-connected orchestration (M5), and the admin
CLI (M7).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified): QUERY functions return 1, they do NOT pool_die. "No match" /
#   "no lease" is a NORMAL, branchable result — the wrapper's signal to ACQUIRE (PRD §2.4
#   step 3). Mirrors _pool_json_valid / pool_owner_alive / the S2 readers. NEVER call
#   pool_die in these three functions.

# CRITICAL (host-verified): a CALLER under set -e that writes `n="$(pool_lease_find_mine)"`
#   ABORTS on the rc-1 path — the plain assignment's status == the command-substitution's
#   status (1), and errexit fires. The wrapper (M6.T3) runs under set -euo pipefail, so it
#   MUST use `if n="$(pool_lease_find_mine)"; then reuse; else acquire; fi`. Document this
#   for the M6.T3 consumer. (Identical hazard to S2's pool_lease_read — see S2 research §2.)

# CRITICAL (host-verified): nullglob is NOT set in lib/pool.sh. A no-match glob
#   `"$POOL_LANES_DIR"/*.json` expands to the LITERAL string "$dir/*.json". The
#   `[[ -f "$f" ]] || continue` guard is MANDATORY — it rejects the literal (and subdirs and
#   non-files). Without it, an empty pool would feed a garbage stem into the loop. Verified
#   2026-07-12: empty dir → 0 iterations, survives set -e.

# CRITICAL (corrupt-skip): pool_lease_field returns 1 on a missing/corrupt lease (S2
#   contract). In the scan loop you MUST `|| continue` (with 2>/dev/null to suppress jq's
#   TOCTOU stderr), else set -e aborts find_mine on the FIRST bad lane. One corrupt lane
#   must never break the hot wrapper path. Verified (scenario 6).

# CRITICAL (cheap-equality-first): do the `owner.pid == POOL_OWNER_PID` string compare BEFORE
#   calling pool_owner_alive. Most lanes are not mine; the compare is ~free while
#   pool_owner_alive does 3 /proc reads. The CONTRACT mandates this order. Only the (≤1,
#   by the §2.8 invariant) pid-matching lane reaches pool_owner_alive.

# CRITICAL (recycling defense): find_mine MUST call pool_owner_alive(pid, starttime, comm)
#   — NOT just pid equality. A recycled PID would otherwise bind to a dead owner's lane
#   (PRD §2.8, §2.14). Pass the LEASE's stored starttime + comm so the predicate compares
#   them against the LIVE process. (find_mine_any deliberately omits this — it is the
#   diagnostic that surfaces stale-but-mine leases.)

# CRITICAL (set -e + [[ ]]): a bare `[[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]]` that is FALSE
#   returns 1 and ABORTS under set -e. ALWAYS `[[ … ]] || return 1` (the `||` list is
#   errexit-exempt). Same for `[[ "$pid" == "$POOL_OWNER_PID" ]] || continue`.

# GOTCHA (for-loop word-splitting is INTENTIONAL): `for n in $(pool_lanes_list)` is
#   unquoted ON PURPOSE — the output is digits-only, one per line, so IFS word-splitting
#   yields exactly the lane numbers (no lane contains whitespace/glob chars). Do NOT quote
#   it (that would make it one big word). This is the standard bash idiom for newline-
#   separated numeric output.

# GOTCHA (sort -n over the pipe): `… | sort -n` runs the for-loop body in a subshell feeding
#   sort. The function's return status is sort's (always 0); the explicit `return 0`
#   documents intent and is pipefail-safe. Lane count is small (pool-bounded), so the fork
#   is negligible; the payoff is deterministic ascending order for every consumer.

# GOTCHA (one owner ≤1 lane): PRD §2.8 invariant (enforced at acquire, M5). find_mine/
#   find_mine_any return the FIRST pid-matching lane == the ONLY one in correct operation.
#   Scanning past a pid-match-but-stale lane (find_mine) rather than returning immediately
#   is deliberate robustness vs an invariant violation; it costs nothing.

# GOTCHA (POOL_OWNER_PID == "0"): passthrough mode. "0" passes the ^[0-9]+$ guard; the loop
#   then finds no real pid==0 lease → return 1 (correct). Unset/empty/non-numeric is rejected
#   by the guard → return 1 without scanning. Either way find_mine returns 1 in passthrough.

# GOTCHA (do NOT mkdir / do NOT mutate): these functions only READ. They never create dirs
#   (a missing POOL_LANES_DIR surfaces as an empty enumeration — return 0, no output, which
#   is correct), never write/delete leases (S1 owns write, M5.T2 owns teardown).

# GOTCHA (scope): this task is the QUERY layer ONLY. Do NOT: find_free_lane (M3.T2.S2),
#   is_lane_stale (M3.T2.S3), acquire/release/reap orchestration (M5.*), the wrapper wiring
#   (M6.T3.S1 consumes find_mine — do not build the wrapper here).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no new globals** and **no on-disk layout** (the layout is
`$POOL_LANES_DIR/<N>.json`, established by M1, written by S1, read by S2). It defines three
functions whose data contract is read-only over the PRD §2.8 lease object. The fields this
task reads (via `pool_lease_field`, which supports the nested `owner.*` paths):

| field path | JSON type | example | read by |
|---|---|---|---|
| `owner.pid` | number (nested) | `836725` | `find_mine`, `find_mine_any` (the equality gate) |
| `owner.comm` | string (nested) | `pi` | `find_mine` (passed to `pool_owner_alive`) |
| `owner.starttime` | number (nested) | `1234567890` | `find_mine` (passed to `pool_owner_alive` — anti-recycling) |

**Naming** (item-mandated, exact): `pool_lanes_list` (lane-family — enumerates NUMBERS, not
lease records, so it is `pool_lanes_*` not `pool_lease_*`, per key_findings naming table),
`pool_lease_find_mine`, `pool_lease_find_mine_any` (lease-query subdomain). No `_` prefix —
entry points (mirror `pool_owner_resolve`, `pool_lease_write`). Internal-only in practice.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_lease_field pool_owner_alive pool_owner_resolve pool_config_init'
  - EXPECT: all four reported as functions. (pool_lease_field is M3.T1.S2 LANDED;
        pool_owner_alive is M2.T2.S1; pool_owner_resolve is M2.T1.S1; pool_config_init is
        M1.T1.S2. If pool_lease_field is MISSING, STOP — this task depends on S2; the
        orchestrator sequences S2 first.)
  - RUN (confirm POOL_OWNER_PID + POOL_LANES_DIR resolve after init+resolve):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 AGENT_BROWSER_POOL_OWNER_PID="123" pool_owner_resolve; \
                 echo "PID=$POOL_OWNER_PID LANES=$POOL_LANES_DIR"; \
                 [[ "$POOL_LANES_DIR" == /* ]] && echo OK-abs'
  - EXPECT: PID=123, an ABSOLUTE LANES path, OK-abs.
  - RUN (confirm the glob/sort/word-split mechanics this task relies on):
        tmp=$(mktemp -d); printf '{"x":1}' > "$tmp/7.json"; printf '{"x":1}' > "$tmp/3.json"
        printf 'junk' > "$tmp/foo.json"; mkdir -p "$tmp/sub.json"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 mkdir -p "$POOL_LANES_DIR"; cp "'$tmp'"/7.json "'$tmp'"/3.json "$POOL_LANES_DIR"/; \
                 cp "'$tmp'"/foo.json "$POOL_LANES_DIR"/; mkdir -p "$POOL_LANES_DIR/sub.json"; \
                 for f in "$POOL_LANES_DIR"/*.json; do [[ -f "$f" ]] || continue; \
                   b="${f##*/}"; n="${b%.json}"; [[ "$n" =~ ^[0-9]+$ ]] || continue; \
                   printf "%s\n" "$n"; done | sort -n | tr "\n" " "; echo'
        rm -rf "$tmp"
  - EXPECT: "3 7 " (junk + subdir filtered, numeric-sorted). If this differs, re-read the
        research §1 gotchas before proceeding.
  - RUN (locate the append point — current EOF):
        grep -nE '^pool_lease_exists\(\)' lib/pool.sh; wc -l lib/pool.sh; tail -3 lib/pool.sh
  - EXPECT: pool_lease_exists near EOF (~line 918), file ~931 lines, last lines are the
        closing brace of pool_lease_exists. APPEND the new banner + three functions AFTER
        that brace. Do NOT touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_lanes_list() to lib/pool.sh (first; the other two call it)
  - PLACEMENT: after a new banner line, directly below pool_lease_exists()'s closing brace.
  - IMPLEMENT (verbatim-ready — paste this function body):
        # =============================================================================
        # Lease management — query operations (P1.M3.T2.S1)
        # =============================================================================
        # Cross-lane iteration + owner-correlation queries. Composes the S2 read helpers
        # (pool_lease_field), the M2.T2.S1 identity predicate (pool_owner_alive), and the
        # M2.T1.S1 owner globals (POOL_OWNER_PID). Consumed by the wrapper lifecycle step 2
        # (M6.T3.S1 reuse-vs-acquire), the reap/ensure-connected orchestration (M5), and the
        # admin CLI (M7 status/doctor). NON-FATAL by design: "no match"/"no lease" returns 1
        # (the wrapper's signal to acquire), mirroring _pool_json_valid / pool_owner_alive /
        # the S2 readers.

        # pool_lanes_list
        #
        # Enumerate every NUMERIC lane stem from $POOL_LANES_DIR/*.json, echo each N on its
        # own line, numerically sorted ascending (sort -n). Always returns 0 — an empty or
        # missing lanes dir is a VALID state (the wrapper's first-ever acquire; PRD §2.4
        # step 2 scans this), never an error.
        #
        # CONSUMERS: pool_lease_find_mine / pool_lease_find_mine_any (below); M5.T3 reap;
        # M7.T1 status; M7.T4 doctor; M5.T4 force-reap (find oldest dead-owner lane).
        #
        # GOTCHA — nullglob is NOT set: a no-match glob expands to the LITERAL
        # "$POOL_LANES_DIR/*.json". `[[ -f "$f" ]] || continue` rejects that literal (and
        # subdirs, and non-files). Host-verified 2026-07-12.
        # GOTCHA — numeric filter: a stray non-numeric *.json (e.g. an editor artifact) is
        # skipped by the ^[0-9]+$ test, matching the lane-validation contract used by every
        # lease function (S1/S2). Lane numbers are the only thing we ever echo.
        # GOTCHA — for n in $(pool_lanes_list): output is digits-only/newline-separated, so
        # the unquoted command substitution word-splits into exactly the lane numbers
        # (intentional; quoting would make it one word). Safe because no lane has whitespace.
        # GOTCHA — | sort -n runs the loop body in a subshell; the function's status is
        # sort's (always 0). The explicit `return 0` documents intent and is pipefail-safe.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR). The dir need not exist — a
        # missing dir surfaces as a no-match glob → 0 iterations → no output (correct).
        pool_lanes_list() {
            local f base n
            for f in "$POOL_LANES_DIR"/*.json; do
                [[ -f "$f" ]] || continue
                base="${f##*/}"
                n="${base%.json}"
                [[ "$n" =~ ^[0-9]+$ ]] || continue
                printf '%s\n' "$n"
            done | sort -n
            return 0
        }
  - FOLLOW pattern: pure-bash parameter expansion (`${f##*/}`, `${base%.json}` — no basename
        fork); `[[ ]] || continue` (errexit-exempt); `sort -n` for deterministic order;
        always return 0.
  - NAMING: pool_lanes_list (item-mandated; lane family — enumerates NUMBERS).
  - PLACEMENT: first function in the new "query operations" section.

Task 2: APPEND pool_lease_find_mine() to lib/pool.sh (directly below pool_lanes_list)
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_find_mine
        #
        # Find MY valid lease: scan every lane; on the first lane whose owner.pid ==
        # POOL_OWNER_PID AND pool_owner_alive(pid, starttime, comm) → echo that lane N and
        # return 0. If no valid match → return 1. Implements PRD §2.4 step 2 ("Find MY
        # lease: owner.pid==pid && comm=='pi' && starttime match").
        #
        # CONSUMERS: M6.T3.S1 wrapper lifecycle step 2 (rc 0 → reuse lane N; rc 1 → acquire);
        # M5.T1.S3 ensure_connected (reuse gate).
        #
        # ORDERING (CONTRACT): owner.pid == POOL_OWNER_PID (cheap string equality) BEFORE
        # pool_owner_alive (3× /proc reads). Most lanes are not mine; only the (≤1, by the
        # §2.8 invariant) pid-matching lane reaches the liveness check.
        # GOTCHA — corrupt/mid-deletion leases are SKIPPED, not fatal: pool_lease_field
        # returns 1 on missing/corrupt (S2 contract); `|| continue` keeps the scan alive
        # under set -e (one bad lane must never break the hot wrapper path).
        # GOTCHA — pool_owner_alive is passed the LEASE's stored starttime + comm so it can
        # compare them against the LIVE process → defeats PID recycling (PRD §2.8/§2.14).
        # GOTCHA — POOL_OWNER_PID == "0" (passthrough) passes the guard; the loop finds no
        # real pid==0 lease → return 1 (correct). Unset/empty/non-numeric → return 1 fast.
        # GOTCHA — CALLERS under set -e MUST guard: `if n="$(pool_lease_find_mine)"; then …`.
        #   A bare `n="$(pool_lease_find_mine)"` ABORTS on the rc-1 path (same hazard as
        #   pool_lease_read — S2 research §2).
        # PRECONDITION: pool_config_init + pool_owner_resolve (for POOL_OWNER_PID).
        pool_lease_find_mine() {
            local n pid st comm
            # No resolved owner → no lease. `[[ ]] || return 1` is errexit-exempt.
            [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
            for n in $(pool_lanes_list); do
                pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
                # Cheap equality first; skip non-mine lanes without touching /proc.
                [[ "$pid" == "$POOL_OWNER_PID" ]] || continue
                st="$(pool_lease_field "$n" owner.starttime 2>/dev/null)" || continue
                comm="$(pool_lease_field "$n" owner.comm 2>/dev/null)" || continue
                # Live + same process invocation? (pool_owner_alive returns 1 on dead/
                # recycled — the `if` is simply false → keep scanning.) One owner ≤1 lane
                # (§2.8) ⟹ the scan falls through to return 1 if this one is stale.
                if pool_owner_alive "$pid" "$st" "$comm"; then
                    printf '%s\n' "$n"
                    return 0
                fi
            done
            return 1
        }
  - FOLLOW pattern: guard-first; `for n in $(pool_lanes_list)` (intentional word-split);
        `pool_lease_field … 2>/dev/null || continue` (corrupt-skip + TOCTOU-stderr-suppress);
        cheap-equality-first; `if pool_owner_alive …; then echo+return 0; fi`; `return 1`.
  - GOTCHA: never pool_die; never mutate; the `if pool_owner_alive` must NOT be a bare call
        (it returns 1, which under set -e outside an `if`/`||` would abort).
  - NAMING: pool_lease_find_mine (item-mandated; lease-query subdomain).

Task 3: APPEND pool_lease_find_mine_any() to lib/pool.sh (directly below pool_lease_find_mine)
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_find_mine_any
        #
        # Diagnostic variant of find_mine: return the first lane whose owner.pid ==
        # POOL_OWNER_PID REGARDLESS of liveness (no pool_owner_alive call). Surfaces a STALE
        # lease that nonetheless names this PID — for the reaper (M5.T3), doctor (M7.T4),
        # and explicit release (M7.T3) self-cleanup paths. Echo the lane N and return 0 on
        # the first pid-match; return 1 if no lane names this PID.
        #
        # CONSUMERS: M5.T3 reap (self-reap / diagnostic), M7.T4 doctor (reconcile), M7.T3
        # release [<N>|all] (find my lanes to tear down).
        #
        # DIFFERENCE from find_mine: no pool_owner_alive → returns a lane even when the owner
        # is dead/recycled. find_mine = "valid mine"; find_mine_any = "claiming to be mine".
        # GOTCHA — first-match semantics (return immediately). §2.8 invariant ⟹ ≤1 such
        # lane, so first-match == only-match in correct operation.
        # GOTCHA — corrupt lanes skipped via `|| continue` (same as find_mine).
        # GOTCHA — CALLERS under set -e MUST guard: `if n="$(pool_lease_find_mine_any)"; then`.
        # PRECONDITION: pool_config_init + pool_owner_resolve (for POOL_OWNER_PID).
        pool_lease_find_mine_any() {
            local n pid
            [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
            for n in $(pool_lanes_list); do
                pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
                if [[ "$pid" == "$POOL_OWNER_PID" ]]; then
                    printf '%s\n' "$n"
                    return 0
                fi
            done
            return 1
        }
  - FOLLOW pattern: same guard + scan; pid-equality in an `if` (so a non-match does not
        abort under set -e); echo + return 0 on first match; return 1 otherwise.
  - GOTCHA: deliberately NO pool_owner_alive call (that is the point — stale-but-mine).
  - NAMING: pool_lease_find_mine_any (item-mandated; lease-query subdomain).

Task 4: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (all three functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any' >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (pool_lanes_list empty/missing dir → no output, rc 0):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 out="$(pool_lanes_list)"; rc=$?; [[ $rc -eq 0 && -z "$out" ]] && echo OK || echo FAIL'
        # EXPECT: OK.
  - RUN (pool_lanes_list mixed → numeric-sorted, junk+subdir filtered):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/7.json"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/3.json"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/100.json"; \
                 printf "{\"x\":1}" > "$POOL_LANES_DIR/2.json"; \
                 printf junk > "$POOL_LANES_DIR/foo.json"; mkdir -p "$POOL_LANES_DIR/sub.json"; \
                 out="$(pool_lanes_list | tr "\n" " ")"; \
                 [[ "$out" == "2 3 7 100 " ]] && echo "OK [$out]" || echo "FAIL [$out]"'
        # EXPECT: OK [2 3 7 100 ].
  - RUN (find_mine HAPPY: lane 7 mine & alive; 5/9 others → echo 7, rc 0):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
                 AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" \
                 pool_owner_resolve; \
                 pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" "$MEST" "/c7" 104816 104816 true; \
                 pool_lease_write 9 "/x/9" 0 abpool-9 99999 pi 88888 "/c9" 0 0 false; \
                 rc=0; n="$(pool_lease_find_mine)" || rc=$?; \
                 [[ $rc -eq 0 && "$n" == 7 ]] && echo "OK n=$n" || echo "FAIL rc=$rc n=$n"'
        # EXPECT: OK n=7.
  - RUN (find_mine NO MATCH → rc 1, silent):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 AGENT_BROWSER_POOL_OWNER_PID="1234567" AGENT_BROWSER_POOL_OWNER_STARTTIME="111" pool_owner_resolve; \
                 pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
                 rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; \
                 [[ $rc -eq 1 && -z "$n" ]] && echo OK || echo "FAIL rc=$rc n=$n"'
        # EXPECT: OK.
  - RUN (STALE: pid matches, starttime mismatch → find_mine rc 1; find_mine_any rc 0 echo lane):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 ME=$$; MECOMM=$(cat /proc/$$/comm); \
                 AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="999" pool_owner_resolve; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" 12345 "/c7" 104816 104816 true; \
                 rc=0; o1="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; echo "find_mine rc=$rc out=[$o1]"; \
                 [[ $rc -eq 1 && -z "$o1" ]] || echo FAIL-mine; \
                 rc=0; o2="$(pool_lease_find_mine_any)" || rc=$?; echo "find_mine_any rc=$rc out=[$o2]"; \
                 [[ $rc -eq 0 && "$o2" == 7 ]] && echo OK || echo FAIL-any'
        # EXPECT: find_mine rc=1 out=[]; find_mine_any rc=0 out=[7]; OK.
  - RUN (corrupt lane SKIPPED; valid mine still found):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
                 AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" pool_owner_resolve; \
                 printf "NOT JSON{" > "$POOL_LANES_DIR/3.json"; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" "$MEST" "/c7" 104816 104816 true; \
                 rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; \
                 [[ $rc -eq 0 && "$n" == 7 ]] && echo "OK n=$n (corrupt lane 3 skipped)" || echo "FAIL rc=$rc n=$n"'
        # EXPECT: OK n=7 (corrupt lane 3 skipped).
  - RUN (POOL_OWNER_PID unset → rc 1 fast, no scan):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 unset AGENT_BROWSER_POOL_OWNER_PID; POOL_OWNER_PID="" declare -g POOL_OWNER_PID; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 11111 pi 22222 "/c7" 104816 104816 true; \
                 rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; \
                 [[ $rc -eq 1 && -z "$n" ]] && echo OK || echo FAIL'
        # EXPECT: OK.
  - RUN (regression: all prior + new functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any >/dev/null && echo OK'
        # EXPECT: OK.
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the three functions (paste under the new banner after pool_lease_exists) ---

pool_lanes_list() {
    local f base n
    for f in "$POOL_LANES_DIR"/*.json; do
        [[ -f "$f" ]] || continue          # no-match literal / subdirs / non-files
        base="${f##*/}"
        n="${base%.json}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue # numeric-only
        printf '%s\n' "$n"
    done | sort -n
    return 0
}

pool_lease_find_mine() {
    local n pid st comm
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
    for n in $(pool_lanes_list); do
        pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
        [[ "$pid" == "$POOL_OWNER_PID" ]] || continue          # cheap equality FIRST
        st="$(pool_lease_field "$n" owner.starttime 2>/dev/null)" || continue
        comm="$(pool_lease_field "$n" owner.comm 2>/dev/null)" || continue
        if pool_owner_alive "$pid" "$st" "$comm"; then          # live + same process?
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 1
}

pool_lease_find_mine_any() {
    local n pid
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
    for n in $(pool_lanes_list); do
        pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
        if [[ "$pid" == "$POOL_OWNER_PID" ]]; then             # ANY liveness
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 1
}

# --- Critical micro-rules baked into the above --------------------------------
#  * QUERY functions RETURN 1 (never pool_die). "No match"/"no lease" is the wrapper's
#    signal to ACQUIRE. Mirrors _pool_json_valid / pool_owner_alive / the S2 readers.
#  * pool_lanes_list ALWAYS returns 0 (empty pool is valid); the others return 1 on no-match.
#  * nullglob is NOT set → `[[ -f "$f" ]] || continue` is MANDATORY (no-match glob is literal).
#  * `pool_lease_field … 2>/dev/null || continue` skips corrupt/mid-deletion lanes (S2 returns 1)
#    and suppresses jq's TOCTOU stderr — one bad lane must never break the hot path.
#  * cheap-equality-first: pid string-compare BEFORE pool_owner_alive (3× /proc reads).
#  * pool_owner_alive is in an `if` (it returns 1 for stale — must not be a bare call under
#    set -e). Passed the LEASE's starttime+comm → recycling-detectable.
#  * `for n in $(pool_lanes_list)` is INTENTIONALLY unquoted (digits-only/newline-separated).
#  * CALLERS under set -e MUST guard: `if n="$(pool_lease_find_mine)"; then …`.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_lease_field(lane, field) (M3.T1.S2): injection-safe nested read. Returns the value
        + rc 0; returns 1 (silent) on missing file / corrupt JSON / bad lane / empty field.
        find_mine/find_mine_any call it for owner.pid / owner.starttime / owner.comm.
        The `|| continue` on its rc-1 is the corrupt-skip mechanism.
  - pool_owner_alive(pid, starttime, expected_comm="pi") (M2.T2.S1): identity predicate.
        Returns 0 (alive + same process) / 1 (dead / recycled / comm|starttime mismatch).
        NEVER fatal → `if pool_owner_alive …; then` is the correct non-aborting branch.
        find_mine delegates the "VALID mine" check to it.
  - pool_owner_resolve (M2.T1.S1): sets POOL_OWNER_PID (=="0" ⟺ passthrough) +
        POOL_OWNER_STARTTIME/COMM/CWD; honors AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME hooks.
  - pool_config_init (M1.T1.S2): freezes the ABSOLUTE POOL_LANES_DIR. PRECONDITION.

PROVIDED (the consumers — later subtasks):
  - P1.M6.T3.S1 (wrapper lifecycle step 2): `if n="$(pool_lease_find_mine)"; then reuse;
        else acquire; fi`. THE primary hot-path consumer.
  - P1.M5.T1.S3 (ensure_connected): reuse gate via find_mine.
  - P1.M5.T3.S1 (reap_stale): pool_lanes_list to enumerate; find_mine_any for self-reap.
  - P1.M5.T4.S1 (force-reap): pool_lanes_list to find oldest dead-owner lane.
  - P1.M7.T1.S1 (admin status): pool_lanes_list to iterate table rows.
  - P1.M7.T4.S1 (doctor): pool_lanes_list + find_mine_any to reconcile.

CONFIG / DATABASE / ROUTES: none. No new env vars. No new globals (reads POOL_OWNER_PID +
        POOL_LANES_DIR, both frozen by pool_config_init/pool_owner_resolve). No dir I/O
        beyond reading leases via pool_lease_field (dirs are the caller's responsibility via
        pool_state_init). No user docs ("internal functions"; the algorithm is PRD §2.4
        step 2; the schema is PRD §2.8).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the three functions — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. all prior subtasks).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression seeds).
Each block is self-contained (its own $tmp state dir, cleaned on EXIT). NOTE the return-
capture idiom `rc=0; n="$(...)" || rc=$?` — required because find_mine/find_mine_any return 1
(a bare `n="$(pool_lease_find_mine)"` would abort under set -e on the rc-1 path).

```bash
# 2a. All three functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any' >/dev/null && echo OK
# Expected: OK.

# 2b. pool_lanes_list empty/missing dir → no output, rc 0.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         out="$(pool_lanes_list)"; rc=$?; [[ $rc -eq 0 && -z "$out" ]] && echo OK || echo FAIL'
# Expected: OK.

# 2c. pool_lanes_list mixed → "2 3 7 100" (junk + subdir filtered, numeric-sorted).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         printf "{\"x\":1}">"$POOL_LANES_DIR/7.json"; printf "{\"x\":1}">"$POOL_LANES_DIR/3.json"; \
         printf "{\"x\":1}">"$POOL_LANES_DIR/100.json"; printf "{\"x\":1}">"$POOL_LANES_DIR/2.json"; \
         printf junk>"$POOL_LANES_DIR/foo.json"; mkdir -p "$POOL_LANES_DIR/sub.json"; \
         out="$(pool_lanes_list | tr "\n" " ")"; [[ "$out" == "2 3 7 100 " ]] && echo "OK [$out]" || echo "FAIL [$out]"'
# Expected: OK [2 3 7 100 ].

# 2d. find_mine HAPPY: lane 7 mine & alive; 5/9 others → echo 7, rc 0.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
         AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" pool_owner_resolve; \
         pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" "$MEST" "/c7" 104816 104816 true; \
         pool_lease_write 9 "/x/9" 0 abpool-9 99999 pi 88888 "/c9" 0 0 false; \
         rc=0; n="$(pool_lease_find_mine)" || rc=$?; [[ $rc -eq 0 && "$n" == 7 ]] && echo "OK n=$n" || echo "FAIL rc=$rc n=$n"'
# Expected: OK n=7.

# 2e. find_mine NO MATCH → rc 1, silent.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         AGENT_BROWSER_POOL_OWNER_PID="1234567" AGENT_BROWSER_POOL_OWNER_STARTTIME="111" pool_owner_resolve; \
         pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
         rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; [[ $rc -eq 1 && -z "$n" ]] && echo OK || echo "FAIL rc=$rc n=$n"'
# Expected: OK.

# 2f. STALE: pid matches, starttime mismatch → find_mine rc1 silent; find_mine_any rc0 echo lane.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         ME=$$; MECOMM=$(cat /proc/$$/comm); \
         AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="999" pool_owner_resolve; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" 12345 "/c7" 104816 104816 true; \
         rc=0; o1="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; echo "find_mine rc=$rc out=[$o1]"; \
         [[ $rc -eq 1 && -z "$o1" ]] || echo FAIL-mine; \
         rc=0; o2="$(pool_lease_find_mine_any)" || rc=$?; echo "find_mine_any rc=$rc out=[$o2]"; \
         [[ $rc -eq 0 && "$o2" == 7 ]] && echo OK || echo FAIL-any'
# Expected: find_mine rc=1 out=[]; find_mine_any rc=0 out=[7]; OK.

# 2g. corrupt lane SKIPPED; valid mine still found.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
         AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" pool_owner_resolve; \
         printf "NOT JSON{">"$POOL_LANES_DIR/3.json"; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" "$MEST" "/c7" 104816 104816 true; \
         rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; \
         [[ $rc -eq 0 && "$n" == 7 ]] && echo "OK n=$n (corrupt 3 skipped)" || echo "FAIL rc=$rc n=$n"'
# Expected: OK n=7 (corrupt 3 skipped).

# 2h. POOL_OWNER_PID unset → rc 1 fast (no scan).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         declare -g POOL_OWNER_PID=""; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 11111 pi 22222 "/c7" 104816 104816 true; \
         rc=0; n="$(pool_lease_find_mine 2>/dev/null)" || rc=$?; [[ $rc -eq 1 && -z "$n" ]] && echo OK || echo FAIL'
# Expected: OK.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Full file sources; all prior + new functions present + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
              _pool_get_starttime pool_owner_resolve pool_owner_alive \
              pool_lease_write pool_lease_update \
              pool_lease_read pool_lease_field pool_lease_exists \
              pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any >/dev/null && echo OK'
# Expected: OK.

# 3b. Downstream-consumer simulation: the realistic wrapper step-2 shape — resolve owner,
#     seed several lanes, find_mine returns MY valid lane (the reuse decision).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         ME=$$; MEST=$(_pool_get_starttime "$$"); MECOMM=$(cat /proc/$$/comm); \
         AGENT_BROWSER_POOL_OWNER_PID="$ME" AGENT_BROWSER_POOL_OWNER_STARTTIME="$MEST" pool_owner_resolve; \
         pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 "$ME" "$MECOMM" "$MEST" "/c7" 104816 104816 true; \
         pool_lease_write 9 "/x/9" 0 abpool-9 99999 pi 88888 "/c9" 0 0 false; \
         # The wrapper idiom: guard the rc-1 path.
         if n="$(pool_lease_find_mine)"; then echo "REUSE lane $n (expected 7)"; \
         else echo "ACQUIRE new lane"; fi'
# Expected: REUSE lane 7 (expected 7).

# 3c. Enumerate + read end-to-end (the admin status / reap shape): pool_lanes_list drives a
#     per-lane loop that reads owner identity via pool_lease_field.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 2 "/x/2" 0 abpool-2 11111 pi 22222 "/c2" 0 0 false; \
         pool_lease_write 5 "/x/5" 0 abpool-5 33333 pi 44444 "/c5" 0 0 false; \
         rows=""; for n in $(pool_lanes_list); do \
           pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue; \
           rows="$rows lane$n:pid=$pid"; done; \
         echo "$rows"; [[ "$rows" == " lane2:pid=11111 lane5:pid=33333" ]] && echo OK || echo FAIL'
# Expected: " lane2:pid=11111 lane5:pid=33333" + OK.

# 3d. No stray repo artifacts (these fns read only; they write nothing).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock)$' \
  || echo "repo clean of stray runtime artifacts"
# Expected: 'repo clean of stray runtime artifacts' (only lib/pool.sh modified).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Re-confirm the host mechanics the implementation depends on (glob no-match, sort -n,
#     word-splitting of digits-only output).
tmp=$(mktemp -d); printf '{"x":1}'>"$tmp/7.json"; printf junk>""$tmp/foo.json"
bash -c 'set -euo pipefail; n=0; for f in "'"$tmp"'"/[0-9]*.json; do [[ -f "$f" ]] || continue; n=$((n+1)); done; echo "no-match-survives-set-e n=$n"'
echo "sort -n of 2 10 3 7: $(printf '%s\n' 2 10 3 7 | sort -n | tr "\n" " ")"
rm -rf "$tmp"
# Expected: no-match-survives-set-e n=1 ; sort -n of 2 10 3 7: 2 3 7 10

# 4b. Non-fatal guarantee: none of the three functions ever calls pool_die. Prove it by
#     grepping the function bodies for pool_die (must be absent).
awk '/^pool_lanes_list\(\) {/,/^}/{print} /^pool_lease_find_mine\(\) {/,/^}/{print} /^pool_lease_find_mine_any\(\) {/,/^}/{print}' lib/pool.sh \
  | grep -n 'pool_die' && echo "FAIL: pool_die present in a query fn" || echo "OK no pool_die in query fns"
# Expected: OK no pool_die in query fns.

# 4c. Cheap-equality-first sweep: find_mine must do the pid equality BEFORE pool_owner_alive.
sed -n '/^pool_lease_find_mine() {/,/^}/p' lib/pool.sh \
  | grep -nE '\[\[ "\$pid" == "\$POOL_OWNER_PID" \]\] \|\| continue' >/dev/null \
  && echo "OK pid-equality-before-alive" || echo "FAIL: check find_mine ordering"
# Expected: OK pid-equality-before-alive.

# 4d. Corrupt-skip sweep: find_mine/find_mine_any must `|| continue` on pool_lease_field.
for fn in pool_lease_find_mine pool_lease_find_mine_any; do
  sed -n "/^$fn() {/,/^}/p" lib/pool.sh | grep -qE 'pool_lease_field .*2>/dev/null\) \|\| continue' \
    && echo "OK $fn skips corrupt" || echo "FAIL: $fn missing corrupt-skip"
done
# Expected: OK pool_lease_find_mine skips corrupt ; OK pool_lease_find_mine_any skips corrupt.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck lib/pool.sh` reports zero issues (whole file).
- [ ] All three functions callable after `source lib/pool.sh` (2a).
- [ ] `pool_lanes_list` empty/missing dir → no output, rc 0 (2b).
- [ ] `pool_lanes_list` mixed → numeric-sorted, junk+subdir filtered (2c).
- [ ] `pool_lease_find_mine` happy: mine+alive → echo N, rc 0 (2d).
- [ ] `pool_lease_find_mine` no-match → rc 1, silent (2e).
- [ ] STALE: find_mine rc 1 silent, find_mine_any rc 0 + echo lane (2f).
- [ ] corrupt lane skipped; valid mine still found (2g).
- [ ] POOL_OWNER_PID unset → rc 1 fast (2h).
- [ ] Downstream wrapper step-2 simulation reuses the right lane (3b).
- [ ] Enumerate + per-lane read end-to-end (3c).
- [ ] No stray repo artifacts (3d).

### Feature Validation

- [ ] `pool_lease_find_mine` realizes PRD §2.4 step 2 (pid == owner AND comm=="pi" AND
      starttime match), delegating the identity check to `pool_owner_alive` (recycling-safe).
- [ ] Cheap-equality-first ordering (pid compare before the 3× `/proc` liveness read) (4c).
- [ ] `pool_lanes_list` enumerates `$POOL_LANES_DIR/*.json` numerically, defensively filtered.
- [ ] `pool_lease_find_mine_any` returns a lane CLAIMING to be mine regardless of liveness
      (the diagnostic, distinct from find_mine's "valid mine").
- [ ] Corrupt/mid-deletion leases are skipped (`|| continue`), never fatal (4d).
- [ ] None of the three functions ever calls `pool_die` (4b) — non-fatal query layer.
- [ ] Integration points match the consumer contract (M6.T3 step 2, M5.T3 reap,
      M7 status/doctor) — 3b/3c.

### Code Quality Validation

- [ ] Follows existing `lib/pool.sh` read/query-side patterns (`return 1` not `pool_die`;
      `[[ ]] || return 1` / `|| continue`; compose `pool_lease_field` + `pool_owner_alive`;
      SC2155 two-statement locals; `2>/dev/null` on the field reads).
- [ ] File placement: new "query operations" banner after `pool_lease_exists()` (EOF).
- [ ] Anti-patterns avoided: no `pool_die`; no bare `pool_owner_alive` call (always in `if`);
      no quoting of `$(pool_lanes_list)` in `for` (intentional word-split); no mkdir/mutate;
      no `jq -e`/`-re` (find_mine uses pool_lease_field, not raw jq); no schema validator.
- [ ] Dependencies properly composed (`pool_lease_field`, `pool_owner_alive`,
      `POOL_OWNER_PID`, `POOL_LANES_DIR`); no new globals/env vars/files/deps.

### Documentation & Deployment

- [ ] Each function has a doc comment explaining contract, return semantics, the
      cheap-equality-first ordering (find_mine), the corrupt-skip mechanism, the
      caller-side `set -e` idiom, consumers, and preconditions.
- [ ] No new user docs (internal functions; algorithm is PRD §2.4 step 2; schema is PRD §2.8).
- [ ] No new env vars to document.

---

## Anti-Patterns to Avoid

- ❌ Don't `pool_die` on no-match / corrupt / missing — **return 1** (it is a normal state;
  the wrapper branches on it to acquire). Mirrors `_pool_json_valid` / `pool_owner_alive` /
  the S2 readers.
- ❌ Don't leave a caller writing `n="$(pool_lease_find_mine)"` ungoverned under `set -e` —
  it aborts the wrapper on the rc-1 path. Use `if n="$(…)"; then reuse; else acquire; fi`.
- ❌ Don't skip the `[[ -f "$f" ]] || continue` guard in `pool_lanes_list` — nullglob is NOT
  set, so a no-match glob is a literal string that must be filtered (or an empty pool feeds a
  garbage stem). Verified.
- ❌ Don't omit `|| continue` on `pool_lease_field` in the scan loop — a corrupt/mid-deletion
  lease returns 1 and would abort `find_mine` under `set -e` on the hot path.
- ❌ Don't call `pool_owner_alive` on every lane (do the cheap `pid == POOL_OWNER_PID` string
  compare FIRST). Most lanes are not mine; the CONTRACT mandates this ordering.
- ❌ Don't make `pool_owner_alive` a bare call in `find_mine` — it returns 1 for stale, which
  under `set -e` (outside `if`/`||`) would abort. Always `if pool_owner_alive …; then`.
- ❌ Don't reduce `find_mine` to pid-only equality (that would bind a recycled PID to a dead
  owner's lane — PRD §2.8/§2.14). The `pool_owner_alive(pid, starttime, comm)` delegation is
  the recycling defense.
- ❌ Don't have `find_mine_any` call `pool_owner_alive` — its whole purpose is to return a
  lane CLAIMING to be mine regardless of liveness (the stale-but-mine diagnostic).
- ❌ Don't quote `$(pool_lanes_list)` in the `for` loop — the output is digits-only/newline-
  separated; word-splitting is the desired behavior (quoting would make it one word).
- ❌ Don't `mkdir` or mutate state from these functions — they are READ/QUERY only. A missing
  `POOL_LANES_DIR` surfaces as an empty enumeration (return 0, no output), which is correct.
- ❌ Don't catch-all and `pool_die` — these are queries; failure is a `return 1`, not fatal.
