# PRP — P1.M3.T1.S2: Lease read function + validation

---

## Goal

**Feature Goal**: Implement the **lease read layer** of `lib/pool.sh` — the three
functions that read and validate the per-lane lease file `$POOL_LANES_DIR/<N>.json`
written by the S1 writers (`pool_lease_write` / `pool_lease_update`). This is the *read*
half of the lease I/O layer. Together with S1, it is the on-disk state machine that every
acquire / release / heartbeat / reap / status decision reads.

1. **`pool_lease_read(lane)`** — read `$POOL_LANES_DIR/<lane>.json`. If the file does not
   exist, **return 1** (a lane with no lease is simply unleased — a *normal* state). If
   the file exists but is **invalid JSON**, log a warning via `_pool_log` and **return 1**
   (defensive coding against a crash-mid-write, rare under S1's atomic writes). On
   success, **echo the raw JSON** and return 0.

2. **`pool_lease_field(lane, field)`** — read one field via an **injection-safe** jq
   extraction that supports both top-level (`port`, `connected`, `last_seen_at`) and
   **nested** (`owner.pid`, `owner.starttime`) paths. Helper for quick access. Same
   return-1-on-missing/corrupt semantics as `pool_lease_read`.

3. **`pool_lease_exists(lane)`** — predicate: return **0** if the lease file exists AND
   is valid JSON, **1** otherwise. Pure predicate — never logs, never fatal.

These are the literal realization of the item's CONTRACT (LOGIC a–c) and the consumers
for every lease query (M3.T2), the reaper/orphan-reuse (M5.T3), and the admin CLI (M7).
`jq` is confirmed present at `/usr/bin/jq` (version 1.8.2); every jq / `set -e` behavior
in this PRP is **host-verified** (2026-07-12) — see
`research/lease-read-jq-and-semantics.md`.

**Deliverable**:
1. Three functions appended to `lib/pool.sh`, in the **"Lease management"** section (the
   same section S1 added for the writers; placed directly below `pool_lease_update` if S1
   has landed, else at EOF below the owner section). Order: `pool_lease_read` →
   `pool_lease_field` → `pool_lease_exists` (`field` and `exists` are independent of
   `read`; `read` is listed first because the CONTRACT lists it first).
2. No new globals, no new env vars, no new files, no new external dependencies. Pure
   additions to `lib/pool.sh`. All three functions are leaf-ish **readers** that compose
   the M1.T2.S1 primitives (`_pool_json_valid`, `_pool_log`) and read exactly one global
   (`POOL_LANES_DIR`, frozen by `pool_config_init`).
3. Each function follows the strict-mode-safe patterns verified on this host and passes
   `bash -n` + `shellcheck` clean.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`,
  writing a lease with `pool_lease_write` (S1) and calling `pool_lease_read <lane>` echoes
  back JSON that round-trips through `jq` with `.lane`/`.owner.pid`/`.connected` intact,
  and returns 0.
- `pool_lease_read <missing-lane>` returns 1 with no output; `pool_lease_read` on a file
  containing garbage returns 1 with no stdout AND writes one `pool_lease_read: corrupt
  lease …` line to the pool log.
- `pool_lease_field <lane> port` → echoes `53427`, return 0; `pool_lease_field <lane>
  owner.pid` → echoes the nested owner pid (injection-safe `getpath`), return 0;
  `pool_lease_field <lane> connected` on `connected:false` → echoes `false`, **return 0**
  (proves the no-`-e` choice); a missing field → echoes `null`, return 0.
- `pool_lease_exists <lane>` returns 0 for a valid lease, 1 for missing, 1 for corrupt, 1
  for a non-numeric lane (path-traversal safe).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources cleanly
  under `set -euo pipefail`; all prior deliverables (M1, M2.\*, M3.T1.S1) unchanged.

## User Persona

**Target User**: Internal only — no end user or operator ever calls these directly.
Consumers are later subtasks inside `lib/pool.sh` and the two wrappers:

- **P1.M3.T2.S1** (`find_my_lease`) — scans `lanes/*.json`, reads `owner.pid` +
  `owner.starttime` via `pool_lease_field` to match the current owner (PRD §2.4 step 2).
  **Needs nested-path support** — this is why `pool_lease_field` uses `getpath`+`split`
  and not a top-level-only `.[ $f ]`.
- **P1.M3.T2.S2** (`find_free_lane`) — `pool_lease_exists` returning 1 == "lane N is
  free"; picks the lowest N≥1.
- **P1.M3.T2.S3** (`is_lane_stale`) — reads `last_seen_at` / `chrome_pid` via
  `pool_lease_field` + owner via `pool_lease_read` for the lazy reaper (PRD §2.10).
- **P1.M5.T3.S1** (`reap_stale`) — `pool_lease_read` per lane to get the owner for
  liveness checks.
- **P1.M5.T3.S2** (`reuse_orphan`) — `pool_lease_field` for `owner.pid` / `chrome_pid` /
  `port` / `connected` / `ephemeral_dir` to adopt a responsive Chrome whose owner died.
- **P1.M7.T1.S1** (admin `status`) — `pool_lease_field` per lane for the table columns;
  `acquired_at` → `_pool_age_str`.
- **P1.M7.T4.S1** (`doctor`) — `pool_lease_exists` + `pool_lease_read` to reconcile leases
  vs live Chromes vs dirs.

**Use Case**: read the pool's per-lane runtime state (owner identity, ephemeral dir,
Chrome port/pid/pgid, connection flag, timestamps) from disk so concurrent processes
(other acquires, the lazy reaper, the admin `status`) can decide who owns what, which
lanes are free, and which are stale. The lease file is the shared state of the whole pool;
these three functions are its read-side API.

**Pain Points Addressed**:
- **A missing lease must not crash the caller.** A lane with no `.json` is simply
  unleased (CONTRACT). `pool_die`-ing on a missing file would abort every
  enumeration/reaper scan at the first free lane. Returning 1 makes "no lease" a
  first-class, handleable result.
- **A corrupt lease must not crash the caller EITHER.** A crash-mid-write (rare under S1
  atomic writes) could leave a half-written file. `_pool_json_valid` + `return 1` +
  (for `read`) a `_pool_log` warning lets the caller skip the bad lane and an operator
  diagnose it, instead of aborting the whole acquire.
- **Injection-safe field reads.** A naive `jq -r ".${field}"` splices the field name into
  the jq program — fragile/injectable. `getpath($f|split("."))` with `--arg` keeps the
  field name as data and supports nested paths in one shot.
- **Boolean fields must read correctly.** `jq -e` would exit 1 on `connected:false`,
  making a legitimately-connected=false lane look invalid. Plain `jq -r` (no `-e`)
  guarantees a present field always echoes + returns 0.

## Why

- **The lease file IS the pool's coordination state, and nearly every operation READS it
  before it writes.** find_my_lease reads to find an existing lane; find_free_lane reads
  to find a free one; reap reads to find stale owners; status reads to render the table.
  These three functions are the single, consistent read API for all of them — so every
  consumer handles missing/corrupt/valid uniformly instead of each re-implementing
  `jq` + error handling.
- **Return-1 (not pool_die) is the whole point.** The S1 writers `pool_die` because a
  failed write is an exceptional, fatal bug. The readers `return 1` because a missing or
  corrupt lease is a *normal* runtime state that the caller branches on ("no lease →
  acquire", "corrupt → skip + log"). This mirrors the existing read-side convention
  (`_pool_json_valid`: "NEVER fatal"; `pool_owner_alive`: "NEVER fatal"). The read layer
  joins that family.
- **Defensive coding against corruption, centralized.** The CONTRACT flags that leases
  *may* be corrupt (crash mid-write). Putting the `_pool_json_valid` guard + the
  `_pool_log` warning inside `pool_lease_read` means every consumer that reads the full
  lease gets the diagnostic for free, exactly once, in one place.
- **Separates "read the whole lease" from "read one field" from "does it exist".** Three
  single-purpose functions: `pool_lease_read` (full JSON, with diagnostics) for
  reap/status/doctor; `pool_lease_field` (one value, quick, silent) for find_my_lease/
  is_lane_stale/reuse_orphan; `pool_lease_exists` (boolean) for find_free_lane. Each
  consumer uses the cheapest one that fits.

## What

User-visible behavior: none directly (internal library readers). Observable contract:

| Function | Args | Returns / side effects | Failure mode |
|---|---|---|---|
| `pool_lease_read` | `$1=lane` | On valid lease: echo the raw file bytes, return 0. | Non-numeric `lane` → return 1. Missing file → return 1 (silent). Corrupt/invalid JSON → `_pool_log` warning + return 1 (silent stdout). |
| `pool_lease_field` | `$1=lane` `$2=field` | On valid lease + present field: echo the field's raw value, return 0. Missing field → echo `null`, return 0. | Non-numeric `lane`, empty `field`, missing file, or corrupt JSON → return 1 (silent). |
| `pool_lease_exists` | `$1=lane` | Valid lease present → return 0. | Non-numeric `lane`, missing file, or corrupt JSON → return 1 (silent, pure predicate). |

**`field` semantics** (`pool_lease_field`): a jq-style **dotted path**, e.g. `port`,
`connected`, `last_seen_at`, `owner.pid`, `owner.starttime`, `owner.comm`, `owner.cwd`,
`chrome_pid`, `chrome_pgid`, `acquired_at`, `session`, `ephemeral_dir`. The field name
enters jq as **data** (`--arg`), split on `.` into a path array, and is looked up with
`getpath` — injection-safe by construction (research §3b). A field that does not exist in
the object yields `null` (jq's standard output for a missing path, exit 0) — callers query
schema-defined fields (PRD §2.8), so this is harmless; it is documented behavior, not an
error. **`jq -r` is used WITHOUT `-e`** (research §3a): `-e`/`--exit-status` exits 1 on
`false` as well as `null`, which would corrupt reads of the boolean `connected` field.

**"valid" semantics** (`pool_lease_exists`, and the corrupt branch of `pool_lease_read`/
`pool_lease_field`): **syntactically valid JSON** (parseable by `jq empty`), composed via
the existing `_pool_json_valid` predicate. A full schema-completeness check (all 12 PRD
§2.8 fields with correct types) is **out of scope** — the literal CONTRACT is "exists and
is valid" = exists + parseable, and downstream consumers read specific fields defensively
(a missing field → `null` via `pool_lease_field`). This matches `_pool_json_valid`'s
documented "syntax, not schema" contract.

### Success Criteria

- [ ] All three functions defined in `lib/pool.sh`, callable after `source lib/pool.sh`
  (requires `pool_config_init` first, since they read `POOL_LANES_DIR`; tests also call
  `pool_state_init` to create the dir). Placed in the "Lease management" section,
  directly below `pool_lease_update` if S1 landed (else at EOF below the owner section).
- [ ] `pool_lease_read 7` on a lease written by S1 echoes JSON that round-trips through
  `jq -e '.lane==7 and .owner.pid==836725 and .connected==true'` → exit 0; the function
  returns 0.
- [ ] `pool_lease_read 99` (no such file) returns 1 with **no stdout**.
- [ ] `pool_lease_read 3` on a file containing `not json{` returns 1 with **no stdout**
  AND writes exactly one line matching `pool_lease_read: corrupt lease` to the pool log
  (`$POOL_LOG_PATH`).
- [ ] `pool_lease_field 7 port` → echoes `53427`, return 0.
- [ ] `pool_lease_field 7 owner.pid` → echoes `836725` (nested path), return 0.
- [ ] `pool_lease_field 7 owner.starttime` → echoes the starttime (nested path), return 0.
- [ ] `pool_lease_field 7 connected` on `connected:true` → echoes `true`, return 0; on
  `connected:false` → echoes `false`, **return 0** (proves the no-`-e` choice; a `-e`
  version would wrongly return 1).
- [ ] `pool_lease_field 7 nope.nada` (missing path) → echoes `null`, return 0.
- [ ] `pool_lease_field 99 port` (missing file), `pool_lease_field 3 port` (corrupt),
  `pool_lease_field "../etc" port` (path-traversal lane), `pool_lease_field 7 ""` (empty
  field) → all return 1, silent.
- [ ] `pool_lease_exists 7` (valid) → return 0; `pool_lease_exists 99` (missing) → 1;
  `pool_lease_exists 3` (corrupt) → 1; `pool_lease_exists abc` (non-numeric) → 1. Never
  logs, never writes.
- [ ] All three functions are **non-fatal**: none ever calls `pool_die`; a missing/corrupt
  lease returns 1 (the caller's shell survives — critical because they run inside
  enumeration/reaper loops).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; all prior deliverables
  (M1, M2.\*, M3.T1.S1) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified jq read facts
(missing file→exit 2; corrupt→exit 5; `-r .missing`→`null` exit 0; `-e` exits 1 on
`false` too; `getpath($f|split("."))` for injection-safe nested reads — all verified this
session and in `research/lease-read-jq-and-semantics.md` §3); the exact return-vs-die
contract and the **caller-side `set -e` gotcha** (§2 — a plain `out="$(pool_lease_read
99)"` aborts the caller; the correct idiom is `rc=0; out="$(...)" || rc=$?`); the exact
primitives to compose (`_pool_json_valid`, `_pool_log`, `pool_die`-NOT, `POOL_LANES_DIR`
— with their contracts); the exact placement (the "Lease management" section, below the
S1 writers); the exact downstream consumer contract (M3.T2 / M5.T3 / M7 — and WHY
`pool_lease_field` must support nested paths); and copy-pasteable, host-verified
validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.8 (the EXACT lease schema these functions read — version/lane/ephemeral_dir/port/
        session/owner{pid,comm,starttime,cwd}/chrome_pid/chrome_pgid/acquired_at/
        last_seen_at/connected; note the NESTED owner object → pool_lease_field must
        support owner.pid / owner.starttime), §2.4 (request lifecycle — step 2 find_my_lease
        + step 3a reap-stale, the two read-heavy call sites), §2.10 (lazy reaper reads
        leases on acquire), §2.12 (admin CLI status reads per-lane fields), §2.14 (failure
        modes — corrupt/stale leases are expected + recovered, not fatal), §2.2 (no bare ~
        — POOL_LANES_DIR is already absolute).
  pattern: §2.8 JSON is the object these functions parse.
  gotcha: §2.8's "connected" is a JSON BOOLEAN. Reading it with jq -e would exit 1 on
        false → use plain jq -r (research §3a).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 7 (Lease Atomic Write Pattern) is the ancestor of the S1 writers — the
        files this task READS are produced by that pattern (tmp + same-dir mv). Because
        the publish is atomic, a reader observes old-or-new, never torn — but a
        crash BEFORE the mv can leave a corrupt .json (rare; the CONTRACT's "defensive
        coding" target). The "Function Naming Convention" reserves pool_lease_* for this
        subdomain.
  pattern: FINDING 7 establishes that lease files are valid JSON objects on the happy
        path; corrupt ones are the exception this task defends against.
  gotcha: an atomic write that was interrupted before `mv` leaves the OLD target intact
        (good) OR no target (file absent → return 1, good). A partially-written .json
        with no .tmp rename is the only corrupt case → _pool_json_valid catches it.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §6 (Lease JSON Schema v1 — byte-identical to PRD §2.8), §4 (jq at /usr/bin/jq —
        "Read/write lease JSON files"), §5 (env-var → POOL_* table; POOL_LANES_DIR is
        derived = $POOL_STATE_DIR/lanes).
  pattern: §6 schema is the read contract; §4 confirms jq is the JSON tool.
  gotcha: none new beyond PRD §2.8.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout: lanes/<N>.json is where leases live), §2 (jq 1.8.2
        confirmed).
  pattern: §7 → lease path is $POOL_LANES_DIR/<N>.json.
  gotcha: the dir may not exist on a first run (pool_state_init, M1.T1.S3, creates it);
        a missing dir surfaces as `[[ -f file ]]` → false → return 1, which is CORRECT
        ("no lease"). Do NOT mkdir inside these functions.

# This task's own research (host-verified)
- file: plan/001_0f759fe2777c/P1M3T1S2/research/lease-read-jq-and-semantics.md
  why: the deep brief on (a) the return-1-vs-pool_die design + the caller-side set -e
        gotcha (§1–§2 — the defining facts), (b) every jq read behavior (§3: missing
        file/corrupt/null-output/-e-on-false/getpath+split, all host-verified), (c) the
        path-traversal lane-validation rationale (§4), (d) the primitives to compose (§5),
        (e) the downstream consumers and why nested paths are required (§6).
  pattern: §3b (the getpath+split read), §1 (the return-1 table), §2 (the caller idiom).
  gotcha: §2 (set -e aborts on `out="$(read ...)"` returning 1) and §3a (no jq -e) are
        the two non-obvious ones.

# The S1 write layer (parallel — treated as a CONTRACT: it WILL exist when this runs)
- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md
  why: S1 defines pool_lease_write / pool_lease_update and the "Lease management" section
        banner. THIS task appends its three readers INTO that section (below
        pool_lease_update). The schema S1 writes (PRD §2.8) is exactly the schema these
        readers parse — they are a matched pair. S1's research/lease-schema-and-consumers.md
        §4 lists THIS task (P1.M3.T1.S2) as a consumer of S1's output.
  pattern: S1's strict-mode idioms (`[[ ]] || …`, plain-assignment captures, compose
        M1 primitives, pool_die on the WRITE side) — THIS task reuses the first three and
        INVERTS the last (return 1, not pool_die, on the READ side).
  gotcha: S1's writers are fatal (pool_die); these readers are non-fatal (return 1). Do
        NOT mix the two conventions. A reader that pool_dies on a missing lease would
        abort every enumeration loop.

# Prior-subtask contracts (treated as already-implemented truth — M1 COMPLETE)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 created lib/pool.sh with set -euo pipefail (propagates to callers — the source
        of the §2 caller gotcha) + pool_die() + _pool_log(). THIS task uses _pool_log for
        the ONE corrupt-lease warning; it does NOT use pool_die.
  pattern: _pool_log is the canonical logger (ISO timestamp + message to pool.log + stderr).

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 delivers pool_config_init() + POOL_LANES_DIR (derived, canonicalized, absolute).
        All three new functions READ POOL_LANES_DIR → pool_config_init is a PRECONDITION.
  pattern: POOL_LANES_DIR is the directory under which <lane>.json lives.
  gotcha: do NOT re-resolve paths — trust the frozen POOL_LANES_DIR.

- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md
  why: T2.S1 delivers the primitives THIS task composes:
        - _pool_json_valid FILEPATH → jq empty predicate (0 valid / 1 not); "NEVER fatal",
          "syntax not schema" (accepts scalars/empty). [the "is valid" check in all three
          functions]
        - _pool_log MSG → one timestamped line. [the corrupt-lease warning in pool_lease_read]
  pattern: T2.S1's PRP literally scopes _pool_json_valid as "the stricter schema check is
        M3.T1.S2's job" — but the CONTRACT for THIS task is "exists and is valid" =
        syntactic. A full schema validator is NOT required by any current consumer; this
        task composes _pool_json_valid (syntax) and leaves field-level defensiveness to
        callers (a missing field → null via pool_lease_field).
  gotcha: _pool_json_valid returns 0 for an EMPTY file (jq empty on no-input exits 0).
        Acceptable: an empty lease is not a realistic atomic-write outcome, and consumers
        read fields defensively. Do NOT try to "fix" _pool_json_valid here.

- file: plan/001_0f759fe2777c/P1M2T2.S1/PRP.md   # pool_owner_alive — the read-side role model
  why: pool_owner_alive is the existing READ-side predicate in this codebase: "NEVER
        fatal — never calls pool_die, never writes, never logs (leaf predicate; callers
        log the decision)". The three functions in THIS task follow the SAME convention:
        return 0/1, never pool_die. pool_lease_exists is a direct sibling predicate.
  pattern: `[[ "$pid" =~ ^[0-9]+$ ]] || return 1` (input validation that returns, not
        dies) — THIS task reuses it for lane validation.

# External authoritative docs (for the HOW)
- url: https://jqlang.github.io/jq/manual/#invoking-jq
  why: -r/--raw-output (no quotes on strings), -e/--exit-status (exits 1 if last output is
        null OR false), --arg name value (binds a JSON STRING used as data, not code),
        getpath / path expressions.
  critical: -e exits 1 on `false` as well as `null` → NEVER use -e to read the boolean
        `connected` field (research §3a, host-verified). Use plain -r. --arg keeps the
        field name as DATA so getpath($f|split(".")) is injection-safe (research §3b).
  section: "Invoking jq" (-r, -e, --arg) and "Paths and path expressions" (getpath).

- url: https://jqlang.github.io/jq/manual/#path-expressions
  why: getpath(PATHARRAY) returns the value at a path given as an array of keys; a
        non-existent path returns null (not an error). `split(".")` turns "owner.pid" into
        ["owner","pid"]. Together: injection-safe nested read in one expression.
  critical: getpath on a missing path → null, exit 0 (host-verified). That is the documented
        "missing field → null" behavior of pool_lease_field.

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (set -e) — a plain assignment `out="$(cmd)"` whose command-substitution
        returns non-zero ABORTS the script. This is why read functions that return 1 must
        be called with `rc=0; out="$(...)" || rc=$?` or inside `if` (research §2).
  section: `-e` (errexit).

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"`. Less critical here than
        for S1 (these functions don't capture jq into a `local` on the happy path — they
        let cat/jq write straight to stdout), but the lane/file locals still follow it.
- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions (`"$POOL_LANES_DIR/$lane.json"`, `"$field"`, etc.).
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1** have landed and **M3.T1.S1 (S1 writers)** has
landed (parallel — treat as done; if it has NOT landed yet, this task appends at EOF and
S1 will land above it):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty
├── lib/
│   └── pool.sh                           # S1 header+set -euo pipefail+pool_die+_pool_log
│                                         # + S2 _pool_config_* + pool_config_init
│                                         # + S3 pool_state_init/pool_check_btrfs/pool_check_master
│                                         # + T2.S1 _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str
│                                         # + M2.T1.S1 _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve
│                                         # + M2.T1.S2 wrapper
│                                         # + M2.T2.S1 pool_owner_alive
│                                         # + M3.T1.S1 pool_lease_write/pool_lease_update  (S1 — parallel/landed)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M2T2.S1/PRP.md
    ├── P1M3T1S1/{PRP.md, research/…}     # the WRITE layer (parallel)
    └── P1M3T1S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/lease-read-jq-and-semantics.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND three reader functions to the "Lease management" section:
                  #          pool_lease_read(lane), pool_lease_field(lane, field),
                  #          pool_lease_exists(lane)
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
adds the **lease read layer** — the read-side API for `$POOL_LANES_DIR/<N>.json`. It
composes the M1.T2.S1 primitives (`_pool_json_valid`, `_pool_log`) and is consumed by the
lease-query layer (M3.T2), the reap/orchestration layer (M5), and the admin CLI (M7).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified): READ functions return 1, they do NOT pool_die.
#   A missing or corrupt lease is a NORMAL runtime state (CONTRACT: "a lane with no .json
#   file is simply unleased"; "Leases may be corrupt … defensive coding is needed").
#   The S1 writers pool_die (a failed write is a fatal bug); the readers return 1 (a
#   missing lease is a branchable result). pool_lease_exists is a pure predicate. This
#   mirrors _pool_json_valid ("NEVER fatal") and pool_owner_alive ("NEVER fatal"). NEVER
#   call pool_die in these three functions.

# CRITICAL (host-verified): a caller under set -e that writes `out="$(pool_lease_read 99)"`
#   ABORTS — the plain assignment's status == the command-substitution's status (1), and
#   errexit fires. The correct caller idiom is `rc=0; out="$(pool_lease_read 99)" || rc=$?`
#   or `if out="$(pool_lease_read 99)"; then …`. Document this for M3.T2/M5/M7 consumers;
#   it is the defining consequence of the return-1 design. (Verified: a prototype harness
#   died exactly this way on 2026-07-12.)

# CRITICAL (host-verified): NEVER use `jq -e` in pool_lease_field.
#   -e/--exit-status exits 1 when the last output value is null OR false. The lease schema
#   has a BOOLEAN `connected`. `jq -re .connected` on {"connected":false} → exit 1, no
#   output — indistinguishable from "missing/invalid". Use plain `jq -r`: a present field
#   ALWAYS echoes + returns 0, even when its value is false. (Verified.)

# CRITICAL (injection-safe + nested field read): use
#   `jq -r --arg f "$field" 'getpath($f|split("."))' "$file"`.
#   The field name enters jq as DATA (--arg = a JSON string), is split into a path array,
#   and is looked up with getpath — it NEVER becomes part of the jq program text. This
#   supports BOTH top-level (port, connected) AND nested (owner.pid, owner.starttime)
#   paths in one expression — which the consumers (find_my_lease reads owner.pid) require.
#   NEVER `jq -r ".${field}"` (splices the name into the program — fragile/injectable).
#   A missing path → getpath returns null, exit 0 (host-verified) → documented "missing
#   field → null" behavior.

# CRITICAL (host-verified): `jq -r '.missing'` on a valid object echoes the literal string
#   "null" with exit 0. So a missing field in pool_lease_field prints "null" and returns 0.
#   This is standard jq behavior, harmless (callers query schema-defined fields), and is
#   the faithful realization of the CONTRACT's "via jq -r .field". Do NOT add `// empty`
#   (it would also suppress a legitimate null-valued field; the schema has none, but keep
#   semantics faithful).

# CRITICAL (host-verified): jq exit codes on file/parse problems:
#   missing FILE → exit 2;  corrupt JSON → exit 5;  empty file → exit 0 (jq empty on
#   no-input). _pool_json_valid wraps `jq empty` (0 valid / 1 otherwise) and is NEVER
#   fatal — compose it; do not re-implement. Note empty-file→valid is acceptable here
#   (research §3c); do NOT try to "fix" _pool_json_valid.

# CRITICAL (path-traversal defense): validate `lane` against ^[0-9]+$ BEFORE building the
#   path. `$POOL_LANES_DIR/$lane.json` with lane="../../etc/passwd" would read outside the
#   lanes dir. On invalid lane → return 1 (read functions never die; a bogus lane simply
#   "has no lease"). `[[ "$lane" =~ ^[0-9]+$ ]] || return 1` is errexit-exempt.

# CRITICAL (SC2155 — declare and assign SEPARATELY): the `local` lane/file/field vars are
#   declared FIRST, then assigned. (These functions mostly let cat/jq write straight to
#   stdout, so there is no `local x="$(jq …)"` masking hazard on the happy path — but the
#   pattern still holds for the input captures.)

# CRITICAL (set -e + [[ ]]): a bare `[[ "$lane" =~ ^[0-9]+$ ]]` that is FALSE returns 1
#   and ABORTS under set -e. ALWAYS `[[ … ]] || return 1` (the `||` list is exempt).

# CRITICAL (set -e + jq/cat): a bare `jq …` or `cat …` that fails (corrupt file, TOCTOU
#   deletion) aborts under set -e. Guard with `|| return 1` (e.g. `cat "$file" || return 1`,
#   `jq … || return 1`). After _pool_json_valid passes, jq/cat normally succeed; the guard
#   handles the race.

# GOTCHA (only pool_lease_read logs): the CONTRACT names pool_lease_read to "log warning
#   and return 1" on corrupt JSON. pool_lease_exists is a pure predicate (no log — like
#   _pool_json_valid/pool_owner_alive). pool_lease_field is a "quick access" helper, silent
#   on missing/corrupt (callers wanting diagnostics use pool_lease_read). Do NOT log from
#   exists or field.

# GOTCHA (echo the RAW bytes): pool_lease_read uses `cat "$file"`, which reproduces the
#   file's exact bytes — including NO trailing newline (S1's _pool_atomic_write uses
#   printf '%s', and $() stripped jq's newline, so the file is newline-less). This is
#   faithful to "echo the raw JSON". Consumers pipe to jq (handles no-newline) or capture
#   via $() (strips trailing newline anyway). Do NOT re-add a newline.

# GOTCHA (do NOT mkdir): none of the three functions creates $POOL_LANES_DIR. A missing
#   dir surfaces as `[[ -f file ]]` → false → return 1, which is CORRECT ("no lease").
#   Callers run pool_state_init (M1.T1.S3) at startup; do not mask a misconfigured state
#   dir with a silent mkdir.

# GOTCHA (scope): this task is the READ layer ONLY. Do NOT: write/update a lease (S1);
#   delete/teardown a lease (M5.T2.S1); query lanes — enumerate / find_my_lease /
#   find_free_lane / is_lane_stale (M3.T2.*); acquire/release/reap orchestration (M5.*);
#   add a full schema-completeness validator (out of CONTRACT scope; consumers read fields
#   defensively).
```

## Implementation Blueprint

### Data models and structure

This subtask defines no new globals and no on-disk layout (the layout is
`$POOL_LANES_DIR/<N>.json`, already established by M1 and written by S1). It defines
THREE functions whose data contract is the PRD §2.8 lease object (read-only). The fields
the consumers read and that `pool_lease_field` must support (dotted path → jq getpath):

| field path | JSON type | example value | read by |
|---|---|---|---|
| `version` | number | `1` | (info) |
| `lane` | number | `7` | status table |
| `ephemeral_dir` | string | `/home/…/active/7` | reuse_orphan, release |
| `port` | number | `53427` | reuse_orphan, status |
| `session` | string | `abpool-7` | status |
| `owner.pid` | number (nested) | `836725` | find_my_lease, reap, reuse_orphan |
| `owner.comm` | string (nested) | `pi` | find_my_lease (identity) |
| `owner.starttime` | number (nested) | `1234567890` | find_my_lease (anti-recycle) |
| `owner.cwd` | string (nested) | `/home/…/x` | status |
| `chrome_pid` | number | `104816` | is_lane_stale, reuse_orphan, release |
| `chrome_pgid` | number | `104816` | release (kill -- -pgid) |
| `acquired_at` | number | `1720000000` | status → `_pool_age_str` |
| `last_seen_at` | number | `1720000123` | is_lane_stale |
| `connected` | boolean | `true`/`false` | reuse_orphan, status |

**Naming**: all three are `pool_lease_*` (lease subdomain; item-description-mandated exact
names). No `_` prefix — they are the lease-subdomain read entry points (mirrors
`pool_owner_resolve`, `pool_lease_write`). Internal-only in practice.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies (M1 primitives + globals) are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type _pool_json_valid _pool_log pool_die pool_config_init'
  - EXPECT: all four reported as functions. (_pool_json_valid/_pool_log are M1.T2.S1/S1;
        pool_config_init is M1.T1.S2. If any is MISSING, STOP — this subtask depends on
        M1; the orchestrator sequences it first.)
  - RUN (confirm POOL_LANES_DIR resolves after pool_config_init):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 echo "LANES=$POOL_LANES_DIR"; [[ "$POOL_LANES_DIR" == /* ]] && echo OK-abs'
  - EXPECT: an ABSOLUTE path (no '~') + OK-abs.
  - RUN (confirm jq present + the key read behaviors this task relies on):
        bash -c 'jq --version
                 f=$(mktemp); printf "{\"port\":53427,\"owner\":{\"pid\":100}}" > "$f"
                 echo "missing-file-exit:"; jq . /nope.json >/dev/null 2>&1; echo $?
                 echo "corrupt-exit:"; printf bad > "$f.x"; jq . "$f.x" >/dev/null 2>&1; echo $?
                 echo "missing-field:"; jq -r .missing "$f"; jq -r .missing "$f" >/dev/null; echo "rc=$?"
                 echo "getpath-nested:"; jq -r --arg f owner.pid "getpath(\$f|split(\".\"))" "$f"
                 echo "-e-on-false:"; printf "{\"c\":false}" > "$f2"; jq -re .c "$f2" >/dev/null 2>&1; echo "rc=$?"
                 rm -f "$f" "$f.x" "$f2"'
  - EXPECT: jq-1.8.2; missing-file-exit=2; corrupt-exit=5; missing-field prints "null" +
        rc=0; getpath-nested prints 100; -e-on-false rc=1 (the no--e rationale).
  - RUN (locate the append point):
        grep -nE '^pool_lease_(write|update|read|field|exists)\(\)' lib/pool.sh
        grep -nE 'Lease management' lib/pool.sh
        tail -5 lib/pool.sh
  - EXPECT: if S1 LANDED → pool_lease_write + pool_lease_update exist under a
        "# … Lease management …" banner → APPEND the three readers directly below
        pool_lease_update's closing brace (same section). If S1 has NOT landed → APPEND a
        new "Lease management — JSON read & validation (P1.M3.T1.S2)" banner + the three
        functions at EOF (S1 will land its writers above or merge; either way the section
        groups them). Do NOT touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_lease_read() to lib/pool.sh (first reader)
  - PLACEMENT: in the "Lease management" section, directly below pool_lease_update (if S1
        landed) or at the top of the new banner (if not). It is listed first because the
        CONTRACT lists it first; the other two do not depend on it.
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_read LANE
        #
        # Read $POOL_LANES_DIR/<LANE>.json and echo the RAW JSON on success (return 0).
        # If the file does not exist → return 1 (a lane with no lease is simply unleased —
        # a NORMAL state, NOT an error). If the file exists but is invalid JSON → log a
        # warning via _pool_log and return 1 (defensive coding against a crash-mid-write;
        # rare under S1's atomic writes). NEVER calls pool_die — read functions are
        # non-fatal (they run inside enumeration/reaper loops).
        #
        # CONSUMERS: M3.T2.S1 find_my_lease / M5.T3.S1 reap_stale / M5.T3.S2 reuse_orphan
        # (full-lease reads); M7.T1.S1 status / M7.T4.S1 doctor.
        #
        # GOTCHA — the file is newline-less (S1's _pool_atomic_write uses printf '%s');
        # `cat` reproduces the exact bytes. Consumers pipe to jq (handles no-newline) or
        # capture via $() (strips trailing newline). Do NOT re-add a newline.
        # GOTCHA — CALLERS under set -e must guard the call:
        #   `rc=0; out="$(pool_lease_read "$lane")" || rc=$?`  or  `if out="$(…)"; then`.
        #   A bare `out="$(pool_lease_read 99)"` ABORTS the caller when this returns 1.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR). The dir need not exist — a
        # missing dir surfaces as file-not-found → return 1 (correct: "no lease").
        pool_lease_read() {
            local lane="${1:-}"
            local file

            # Validate lane (path-traversal defense + catches caller bugs). Read functions
            # RETURN 1 on a bad lane (never pool_die) — a bogus lane simply "has no lease".
            # `[[ ]] || return 1` is errexit-exempt.
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1

            file="$POOL_LANES_DIR/$lane.json"

            # Missing file → normal "unleased" state → return 1 (silent).
            [[ -f "$file" ]] || return 1

            # Corrupt JSON → log ONE warning (CONTRACT) + return 1 (silent stdout).
            # _pool_json_valid is the M1.T2.S1 predicate (jq empty); never fatal.
            if ! _pool_json_valid "$file"; then
                _pool_log "pool_lease_read: corrupt lease (invalid JSON) for lane $lane: $file"
                return 1
            fi

            # Echo the raw bytes. `|| return 1` handles a TOCTOU deletion (rare). After the
            # validity check cat normally succeeds.
            cat "$file" || return 1
            return 0
        }
  - FOLLOW pattern: `local …` declared FIRST; `[[ ]] || return 1` (errexit-exempt);
        compose `_pool_json_valid` (the M1 syntax predicate) + `_pool_log` (the one
        warning); `cat … || return 1` (set -e safe). NO pool_die anywhere.
  - GOTCHA: only THIS function logs (on corrupt). Return 1 (not die) on every non-success.
  - NAMING: pool_lease_read (item-mandated; lease subdomain).
  - PLACEMENT: first function in the reader group.

Task 2: APPEND pool_lease_field() to lib/pool.sh (directly below pool_lease_read)
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_field LANE FIELD
        #
        # Read one field from $POOL_LANES_DIR/<LANE>.json and echo its raw value (return 0).
        # FIELD is a jq-style DOTTED PATH — top-level (port, connected, last_seen_at,
        # chrome_pid, …) OR nested (owner.pid, owner.starttime, owner.comm, owner.cwd).
        # "Helper for quick access" (CONTRACT). Silent on missing file / corrupt JSON /
        # invalid lane / empty field (return 1, no output). A field PATH that does not
        # exist in the object echoes `null` and returns 0 (standard jq getpath behavior).
        #
        # CONSUMERS: M3.T2.S1 find_my_lease (owner.pid, owner.starttime — NESTED);
        # M3.T2.S3 is_lane_stale (last_seen_at, chrome_pid); M5.T3.S2 reuse_orphan
        # (owner.pid, chrome_pid, port, connected, ephemeral_dir); M7.T1.S1 status
        # (lane, port, session, chrome_pid, acquired_at, connected).
        #
        # INJECTION SAFETY (research §3b): the filter is the fixed literal
        # `getpath($f|split("."))`; FIELD enters jq as DATA (--arg = a JSON string used as
        # a dict key), NEVER spliced into the program. Supports nested paths in one shot.
        # NEVER `jq -r ".${field}"`.
        # GOTCHA — NO `jq -e` (research §3a): -e exits 1 on `false` as well as `null`,
        # which would break reads of the boolean `connected`. Plain `jq -r` guarantees a
        # present field ALWAYS echoes + returns 0 (even when the value is false).
        # GOTCHA — missing field → echoes "null" (exit 0). Callers query schema-defined
        # fields (PRD §2.8), so this is harmless. It is the faithful "jq -r .field" behavior.
        # GOTCHA — silent on corrupt (no log); callers wanting diagnostics use
        # pool_lease_read (which logs). This keeps field a lean "quick access" helper.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR).
        pool_lease_field() {
            local lane="${1:-}"
            local field="${2:-}"
            local file

            # Validate lane (path-traversal defense) + field is non-empty.
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1
            [[ -n "$field" ]] || return 1

            file="$POOL_LANES_DIR/$lane.json"

            # Missing file → return 1 (silent). Corrupt JSON → return 1 (silent).
            [[ -f "$file" ]] || return 1
            _pool_json_valid "$file" || return 1

            # Injection-safe nested read. `|| return 1` handles a TOCTOU race (file deleted
            # or corrupted between the check and the read). After _pool_json_valid, jq
            # normally succeeds; a missing path yields null (exit 0).
            jq -r --arg f "$field" 'getpath($f|split("."))' "$file" || return 1
            return 0
        }
  - FOLLOW pattern: same strict-mode guards; `getpath($f|split("."))` via `--arg`
        (injection-safe, nested-capable); compose `_pool_json_valid` (syntax guard); plain
        `jq -r` (NO -e); `|| return 1` on jq.
  - GOTCHA: NO `jq -e`; field is a dotted path; missing field → "null"; silent on corrupt.
  - NAMING: pool_lease_field (item-mandated; lease subdomain).

Task 3: APPEND pool_lease_exists() to lib/pool.sh (directly below pool_lease_field)
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_exists LANE
        #
        # Predicate: does lane LANE have a VALID lease file? Return 0 if
        # $POOL_LANES_DIR/<LANE>.json exists AND is valid JSON (parseable by jq); return 1
        # otherwise (missing / corrupt / non-numeric lane). Pure predicate — NEVER logs,
        # NEVER writes, NEVER calls pool_die (mirrors _pool_json_valid and pool_owner_alive).
        #
        # "valid" = SYNTACTICALLY valid JSON (composed via _pool_json_valid). A full
        # schema-completeness check (all 12 PRD §2.8 fields + types) is OUT OF SCOPE — the
        # literal CONTRACT is "exists and is valid" = exists + parseable, and downstream
        # consumers read specific fields defensively (a missing field → null via
        # pool_lease_field).
        #
        # CONSUMERS: M3.T2.S2 find_free_lane (return 1 == "lane N is free"; lowest N≥1
        # with no lease); M3.T2.S1 find_my_lease (skip lanes with no lease); M7.T4.S1
        # doctor (reconcile leases vs live Chromes vs dirs).
        #
        # GOTCHA — non-numeric lane → return 1 (path-traversal safe; a bogus lane "has no
        # lease"). Read functions never die.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR).
        pool_lease_exists() {
            local lane="${1:-}"
            local file

            # Validate lane (path-traversal defense). Predicate → return 1 on bad lane.
            [[ "$lane" =~ ^[0-9]+$ ]] || return 1

            file="$POOL_LANES_DIR/$lane.json"

            # Exists + valid JSON → 0; else 1. Composes the M1.T2.S1 predicate (never fatal).
            [[ -f "$file" ]] || return 1
            _pool_json_valid "$file" || return 1
            return 0
        }
  - FOLLOW pattern: same lane guard; compose `_pool_json_valid` (the existing syntax
        predicate); pure 0/1 return; no log, no write, no pool_die.
  - GOTCHA: syntax-validity only (not schema). Predicate convention (no log).
  - NAMING: pool_lease_exists (item-mandated; lease subdomain).

Task 4: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (all three functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_lease_read pool_lease_field pool_lease_exists' >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (happy-path read: echoes valid JSON, return 0; S1 writer must be present):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/c" 104816 104816 true; \
                 rc=0; out="$(pool_lease_read 7)" || rc=$?; \
                 [[ $rc -eq 0 ]] && printf "%s" "$out" | jq -e ".lane==7 and .owner.pid==836725 and .connected==true" >/dev/null && echo OK'
        # EXPECT: OK. (If S1 writer is NOT yet landed, hand-craft the lease with the jq -n
        # build from research/lease-schema-and-consumers.md §1 instead of pool_lease_write.)
  - RUN (read missing → return 1, silent):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 rc=0; out="$(pool_lease_read 99 2>/dev/null)" || rc=$?; \
                 [[ $rc -eq 1 && -z "$out" ]] && echo OK'
        # EXPECT: OK.
  - RUN (read corrupt → return 1, silent stdout, ONE log line):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_LANES_DIR"; printf "not json{" > "$POOL_LANES_DIR/3.json"; \
                 rc=0; out="$(pool_lease_read 3 2>/dev/null)" || rc=$?; \
                 [[ $rc -eq 1 && -z "$out" ]] || echo FAIL; \
                 grep -q "pool_lease_read: corrupt lease" "$(_pool_log_path)" && echo OK'
        # EXPECT: OK. (corrupt→1, silent, log line present)
  - RUN (field top-level + nested + boolean):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/c" 104816 104816 true; \
                 v="$(pool_lease_field 7 port)";           [[ "$v" == 53427 ]] || echo FAIL-port; \
                 v="$(pool_lease_field 7 owner.pid)";      [[ "$v" == 836725 ]] || echo FAIL-ownerpid; \
                 v="$(pool_lease_field 7 owner.starttime)"; [[ "$v" == 1234567890 ]] || echo FAIL-st; \
                 v="$(pool_lease_field 7 connected)";      [[ "$v" == true ]] || echo FAIL-conn-true; \
                 echo OK'
        # EXPECT: OK.
  - RUN (field on connected:false MUST return 0 + echo false — the no-`-e` proof):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
                 rc=0; v="$(pool_lease_field 7 connected)" || rc=$?; \
                 [[ $rc -eq 0 && "$v" == false ]] && echo OK || echo FAIL'
        # EXPECT: OK. (A -e version would rc=1 here — this proves the choice.)
  - RUN (field missing path → "null", rc 0):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
                 rc=0; v="$(pool_lease_field 7 nope.nada)" || rc=$?; \
                 [[ $rc -eq 0 && "$v" == null ]] && echo OK || echo FAIL'
        # EXPECT: OK.
  - RUN (field error paths: missing file / corrupt / bad lane / empty field → rc 1 silent):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 mkdir -p "$POOL_LANES_DIR"; printf "bad" > "$POOL_LANES_DIR/3.json"; \
                 ok=1; \
                 rc=0; v="$(pool_lease_field 99 port 2>/dev/null)" || rc=$?; [[ $rc -eq 1 && -z "$v" ]] || ok=0; \
                 rc=0; v="$(pool_lease_field 3 port 2>/dev/null)" || rc=$?;  [[ $rc -eq 1 && -z "$v" ]] || ok=0; \
                 rc=0; v="$(pool_lease_field "../etc" port 2>/dev/null)" || rc=$?; [[ $rc -eq 1 ]] || ok=0; \
                 rc=0; v="$(pool_lease_field 7 "" 2>/dev/null)" || rc=$?;    [[ $rc -eq 1 ]] || ok=0; \
                 [[ $ok -eq 1 ]] && echo OK || echo FAIL'
        # EXPECT: OK.
  - RUN (exists: valid→0, missing→1, corrupt→1, bad-lane→1; never logs):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
                 mkdir -p "$POOL_LANES_DIR"; printf "bad" > "$POOL_LANES_DIR/3.json"; \
                 before="$(wc -l < "$(_pool_log_path)" 2>/dev/null || echo 0)"; \
                 ok=1; \
                 pool_lease_exists 7   && ok=1 || ok=0; \
                 pool_lease_exists 99  && ok=0 || true; \
                 pool_lease_exists 3   && ok=0 || true; \
                 pool_lease_exists abc && ok=0 || true; \
                 after="$(wc -l < "$(_pool_log_path)" 2>/dev/null || echo 0)"; \
                 [[ "$before" == "$after" ]] || ok=0; \
                 [[ $ok -eq 1 ]] && echo OK || echo FAIL'
        # EXPECT: OK. (exists 7→0; 99/3/abc→1; NO log lines added — pure predicate.)
  - RUN (regression: all prior functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists >/dev/null && echo OK'
        # EXPECT: OK.
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the three functions (paste into the "Lease management" section) ---------

pool_lease_read() {
    local lane="${1:-}"
    local file
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    file="$POOL_LANES_DIR/$lane.json"
    [[ -f "$file" ]] || return 1
    if ! _pool_json_valid "$file"; then
        _pool_log "pool_lease_read: corrupt lease (invalid JSON) for lane $lane: $file"
        return 1
    fi
    cat "$file" || return 1
    return 0
}

pool_lease_field() {
    local lane="${1:-}"
    local field="${2:-}"
    local file
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$field" ]] || return 1
    file="$POOL_LANES_DIR/$lane.json"
    [[ -f "$file" ]] || return 1
    _pool_json_valid "$file" || return 1
    # Injection-safe nested read. NO -e (would exit 1 on boolean false).
    jq -r --arg f "$field" 'getpath($f|split("."))' "$file" || return 1
    return 0
}

pool_lease_exists() {
    local lane="${1:-}"
    local file
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    file="$POOL_LANES_DIR/$lane.json"
    [[ -f "$file" ]] || return 1
    _pool_json_valid "$file" || return 1
    return 0
}

# --- Critical micro-rules baked into the above --------------------------------
#  * READ functions RETURN 1 (never pool_die). A missing/corrupt lease is a normal state,
#    not an error. Mirrors _pool_json_valid / pool_owner_alive. Only pool_lease_read LOGS
#    (one warning on corrupt — the CONTRACT); exists is a pure predicate; field is silent.
#  * lane is validated ^[0-9]+$ FIRST (path-traversal defense); invalid lane → return 1.
#  * `[[ ]] || return 1` (errexit-exempt) for every guard.
#  * compose _pool_json_valid (the M1 syntax predicate) for the "is valid" check — do not
#    re-implement jq empty. (syntax-only, not schema — acceptable per CONTRACT.)
#  * pool_lease_field uses `jq -r --arg f "$field" 'getpath($f|split("."))'`:
#      - injection-safe (field is DATA via --arg, never spliced into the program);
#      - supports NESTED paths (owner.pid, owner.starttime) the consumers need;
#      - NO `-e` (-e exits 1 on boolean false → breaks `connected`);
#      - missing field → echoes "null", exit 0 (standard jq; faithful to "jq -r .field").
#  * `cat … || return 1` / `jq … || return 1` guard TOCTOU races (set -e safe).
#  * pool_lease_read echoes RAW bytes via cat (file is newline-less per S1; do not re-add).
#  * no mkdir (a missing dir → file-not-found → return 1, which is correct).
#  * CALLERS under set -e MUST guard: `rc=0; out="$(pool_lease_read N)" || rc=$?` or
#    `if out="$(pool_lease_read N)"; then`. A bare `out="$(pool_lease_read 99)"` ABORTS.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — M1 COMPLETE):
  - _pool_json_valid(filepath) (M1.T2.S1): the syntax predicate. Called by ALL THREE
        functions (read's corrupt branch, field's guard, exists's predicate). Returns 0/1,
        never fatal.
  - _pool_log(msg...) (M1.T1.S1): the logger. Called ONCE by pool_lease_read on a corrupt
        lease (the CONTRACT's "log warning"). Writes one ISO-timestamped line to
        $POOL_LOG_PATH + stderr.
  - pool_config_init (M1.T1.S2): freezes POOL_LANES_DIR. PRECONDITION (callers run it).

PROVIDED (the consumers — later subtasks):
  - P1.M3.T2.S1 (find_my_lease): pool_lease_field lane owner.pid / owner.starttime per
        lane (NESTED paths). Skip lanes where pool_lease_exists returns 1.
  - P1.M3.T2.S2 (find_free_lane): pool_lease_exists lane → 1 means "free"; lowest N≥1.
  - P1.M3.T2.S3 (is_lane_stale): pool_lease_field lane last_seen_at / chrome_pid +
        pool_lease_read for owner liveness.
  - P1.M5.T3.S1 (reap_stale): pool_lease_read lane per lane for owner.
  - P1.M5.T3.S2 (reuse_orphan): pool_lease_field for owner.pid / chrome_pid / port /
        connected / ephemeral_dir.
  - P1.M7.T1.S1 (admin status): pool_lease_field per lane for the table; acquired_at →
        _pool_age_str.
  - P1.M7.T4.S1 (doctor): pool_lease_exists + pool_lease_read to reconcile.

CONFIG / DATABASE / ROUTES: none. No new env vars. No new globals (reads POOL_LANES_DIR,
        frozen by pool_config_init; reads $POOL_LOG_PATH via _pool_log). No dir I/O beyond
        reading the lease file (dirs are the caller's responsibility via pool_state_init).
        No user docs ("internal functions"; the schema is documented in PRD §2.8).
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

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds). Each block is self-contained (its own $tmp state dir, cleaned on EXIT). NOTE the
return-capture idiom `rc=0; out="$(...)" || rc=$?` — required because these functions
return 1 (a bare `out="$(pool_lease_read 99)"` would abort under set -e).

```bash
# 2a. All three functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_lease_read pool_lease_field pool_lease_exists' >/dev/null && echo OK
# Expected: OK.

# 2b. Happy-path read: echoes valid JSON, return 0.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/c" 104816 104816 true; \
         rc=0; out="$(pool_lease_read 7)" || rc=$?; \
         [[ $rc -eq 0 ]] && printf "%s" "$out" | jq -e ".lane==7 and .owner.pid==836725 and .connected==true" >/dev/null && echo OK'
# Expected: OK.

# 2c. read missing → return 1, silent.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         rc=0; out="$(pool_lease_read 99 2>/dev/null)" || rc=$?; \
         [[ $rc -eq 1 && -z "$out" ]] && echo OK'
# Expected: OK.

# 2d. read corrupt → return 1, silent stdout, ONE log line.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         mkdir -p "$POOL_LANES_DIR"; printf "not json{" > "$POOL_LANES_DIR/3.json"; \
         rc=0; out="$(pool_lease_read 3 2>/dev/null)" || rc=$?; \
         [[ $rc -eq 1 && -z "$out" ]] || echo FAIL; \
         grep -q "pool_lease_read: corrupt lease" "$(_pool_log_path)" && echo OK'
# Expected: OK.

# 2e. field top-level + nested + boolean true.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/c" 104816 104816 true; \
         [[ "$(pool_lease_field 7 port)" == 53427 ]] && \
         [[ "$(pool_lease_field 7 owner.pid)" == 836725 ]] && \
         [[ "$(pool_lease_field 7 owner.starttime)" == 1234567890 ]] && \
         [[ "$(pool_lease_field 7 connected)" == true ]] && echo OK'
# Expected: OK.

# 2f. field on connected:false → echoes false, rc 0 (the no-`-e` proof).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
         rc=0; v="$(pool_lease_field 7 connected)" || rc=$?; \
         [[ $rc -eq 0 && "$v" == false ]] && echo OK || echo FAIL'
# Expected: OK.

# 2g. field missing path → "null", rc 0.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
         rc=0; v="$(pool_lease_field 7 nope.nada)" || rc=$?; \
         [[ $rc -eq 0 && "$v" == null ]] && echo OK || echo FAIL'
# Expected: OK.

# 2h. field error paths → rc 1 silent (missing file / corrupt / bad lane / empty field).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         mkdir -p "$POOL_LANES_DIR"; printf "bad" > "$POOL_LANES_DIR/3.json"; \
         ok=1; \
         rc=0; v="$(pool_lease_field 99 port 2>/dev/null)" || rc=$?; [[ $rc -eq 1 && -z "$v" ]] || ok=0; \
         rc=0; v="$(pool_lease_field 3 port 2>/dev/null)" || rc=$?;  [[ $rc -eq 1 && -z "$v" ]] || ok=0; \
         rc=0; v="$(pool_lease_field "../etc" port 2>/dev/null)" || rc=$?; [[ $rc -eq 1 ]] || ok=0; \
         rc=0; v="$(pool_lease_field 7 "" 2>/dev/null)" || rc=$?;    [[ $rc -eq 1 ]] || ok=0; \
         [[ $ok -eq 1 ]] && echo OK || echo FAIL'
# Expected: OK.

# 2i. exists: valid→0, missing→1, corrupt→1, bad-lane→1; NEVER logs.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
         mkdir -p "$POOL_LANES_DIR"; printf "bad" > "$POOL_LANES_DIR/3.json"; \
         before="$(wc -l < "$(_pool_log_path)" 2>/dev/null || echo 0)"; \
         ok=1; \
         pool_lease_exists 7   || ok=0; \
         pool_lease_exists 99  && ok=0 || true; \
         pool_lease_exists 3   && ok=0 || true; \
         pool_lease_exists abc && ok=0 || true; \
         after="$(wc -l < "$(_pool_log_path)" 2>/dev/null || echo 0)"; \
         [[ "$before" == "$after" ]] || ok=0; \
         [[ $ok -eq 1 ]] && echo OK || echo FAIL'
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
              pool_lease_read pool_lease_field pool_lease_exists >/dev/null && echo OK'
# Expected: OK.

# 3b. Downstream-consumer simulation: the realistic find_my_lease shape — enumerate a few
#     lanes, read owner identity (nested) via pool_lease_field, find the one matching the
#     current owner. (Uses the M2 owner globals as the "current owner".)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
AGENT_BROWSER_POOL_OWNER_PID="836725" \
AGENT_BROWSER_POOL_OWNER_STARTTIME="1234567890" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve; \
         # seed three lanes, only lane 7 is mine
         pool_lease_write 5 "/x/5" 0 abpool-5 11111 pi 22222 "/c5" 0 0 false; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 "$POOL_OWNER_PID" pi "$POOL_OWNER_STARTTIME" "/c7" 104816 104816 true; \
         pool_lease_write 9 "/x/9" 0 abpool-9 99999 pi 88888 "/c9" 0 0 false; \
         found=""; \
         for n in 5 7 9; do \
           if pool_lease_exists "$n"; then \
             if [[ "$(pool_lease_field "$n" owner.pid)" == "$POOL_OWNER_PID" \
                && "$(pool_lease_field "$n" owner.starttime)" == "$POOL_OWNER_STARTTIME" ]]; then found="$n"; fi; \
           fi; \
         done; \
         [[ "$found" == 7 ]] && echo "OK found my lane=$found" || echo "FAIL found=$found"'
# Expected: OK found my lane=7. (Proves nested owner.pid + owner.starttime reads work end-to-end.)

# 3c. Round-trip with the S1 writers: write → update → read-back reflects the update.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 3 "/x/3" 0 abpool-3 1 pi 1 "/c" 0 0 false; \
         pool_lease_update 3 port 53420; \
         pool_lease_update 3 connected true; \
         pool_lease_update 3 last_seen_at 1720000999; \
         [[ "$(pool_lease_field 3 port)" == 53420 ]] && \
         [[ "$(pool_lease_field 3 connected)" == true ]] && \
         [[ "$(pool_lease_field 3 last_seen_at)" == 1720000999 ]] && \
         printf "%s" "$(pool_lease_read 3)" | jq -e ".owner.pid==1" >/dev/null && echo OK'
# Expected: OK. (read layer faithfully reflects what the S1 write/update layer produced.)

# 3d. No stray repo artifacts (these fns read only under $POOL_LANES_DIR/state; they write
#     nothing except the one _pool_log line on corrupt).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock)$' \
  || echo "repo clean of stray runtime artifacts"
# Expected: 'repo clean of stray runtime artifacts' (only lib/pool.sh modified).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Re-confirm the host jq facts the implementation depends on.
echo "jq: $(jq --version) at $(command -v jq)"
f=$(mktemp); printf '{"port":53427,"owner":{"pid":100},"connected":false}' > "$f"
echo "missing file exit : $(jq . /nope.json >/dev/null 2>&1; echo $?)  (want 2)"
printf 'bad' > "$f.x"; echo "corrupt exit      : $(jq . "$f.x" >/dev/null 2>&1; echo $?)  (want 5)"
echo "missing field null: $(jq -r .missing "$f")  (want null, rc 0)"
echo "getpath nested    : $(jq -r --arg f owner.pid 'getpath($f|split("."))' "$f")  (want 100)"
echo "-e on false rc    : $(jq -re .connected "$f" >/dev/null 2>&1; echo $?)  (want 1 — why we avoid -e)"
echo "plain -r false rc : $(jq -r .connected "$f" >/dev/null 2>&1; echo $?)  (want 0 — what we use)"
rm -f "$f" "$f.x"

# 4b. Non-fatal guarantee: none of the three functions ever calls pool_die. Prove it by
#     grepping the function bodies for pool_die (must be absent).
sed -n '/^pool_lease_read() {/,/^}/p;/^pool_lease_field() {/,/^}/p;/^pool_lease_exists() {/,/^}/p' lib/pool.sh \
  | grep -n 'pool_die' && echo "FAIL: pool_die present in a reader" || echo "OK no pool_die in readers"

# 4c. Injection-safety sweep: pool_lease_field must NOT interpolate $field into the jq
#     program text. Confirm it uses --arg + a fixed-literal filter.
sed -n '/^pool_lease_field() {/,/^}/p' lib/pool.sh \
  | grep -qE 'jq .*--arg f "\$field".*getpath\(\$f\|split\(""\."\)\)' \
  && echo "OK injection-safe getpath" || echo "FAIL: check pool_lease_field jq construction"

# 4d. No-`-e` sweep: pool_lease_field's jq must NOT pass -e/--exit-status.
sed -n '/^pool_lease_field() {/,/^}/p' lib/pool.sh | grep -qE 'jq -re|jq .* -e' \
  && echo "FAIL: pool_lease_field uses -e (breaks connected:false)" || echo "OK no -e in pool_lease_field"
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck lib/pool.sh` reports zero issues (whole file).
- [ ] All three functions callable after `source lib/pool.sh` (2a).
- [ ] Happy-path read echoes valid JSON + returns 0 (2b).
- [ ] read missing → return 1, silent (2c).
- [ ] read corrupt → return 1, silent stdout, ONE log line (2d).
- [ ] field top-level + nested (owner.pid/starttime) + boolean true (2e).
- [ ] field on `connected:false` → echoes `false`, return 0 — the no-`-e` proof (2f).
- [ ] field missing path → "null", return 0 (2g).
- [ ] field error paths → return 1 silent (2h).
- [ ] exists: valid→0 / missing→1 / corrupt→1 / bad-lane→1 / never logs (2i).
- [ ] Downstream simulation: find_my_lease finds the right lane via nested reads (3b).
- [ ] Round-trip with S1 write/update reflects updates on read-back (3c).
- [ ] No stray repo artifacts (3d).

### Feature Validation

- [ ] Reads match PRD §2.8 schema (version/lane/ephemeral_dir/port/session/
      owner{pid,comm,starttime,cwd}/chrome_pid/chrome_pgid/acquired_at/last_seen_at/
      connected) — verified by 2b + 2e + 3b.
- [ ] `pool_lease_field` supports BOTH top-level AND nested (owner.\*) paths (3b).
- [ ] `pool_lease_exists` = exists + syntactically valid JSON (composes _pool_json_valid).
- [ ] None of the three functions ever calls `pool_die` (4b) — non-fatal read layer.
- [ ] `pool_lease_field` is injection-safe (`--arg` + fixed-literal `getpath`; 4c) and
      never uses `jq -e` (4d).
- [ ] Integration points match the consumer contract (M3.T2.\*, M5.T3.\*, M7.\*) — 3b/3c.

### Code Quality Validation

- [ ] Follows existing `lib/pool.sh` read-side patterns (`return 1` not `pool_die`;
      `_pool_json_valid` / `_pool_log` composition; `[[ ]] || return 1`;
      `cat|jq … || return 1`; SC2155 two-statement locals).
- [ ] File placement: "Lease management" section, below the S1 writers (or at EOF).
- [ ] Anti-patterns avoided: no `pool_die`, no `jq -e`, no `jq ".${field}"` interpolation,
      no mkdir, no trailing-newline re-add, no logging from exists/field, no schema
      validator (out of CONTRACT scope).
- [ ] Dependencies properly composed (`_pool_json_valid`, `_pool_log`, `POOL_LANES_DIR`);
      no new globals/env vars/files/deps.

### Documentation & Deployment

- [ ] Each function has a doc comment explaining contract, return semantics, injection
      safety (field), the no-`-e` choice (field), the caller-side set -e idiom (read),
      consumers, and preconditions.
- [ ] No new user docs (internal functions; schema documented in PRD §2.8).
- [ ] No new env vars to document.

---

## Anti-Patterns to Avoid

- ❌ Don't `pool_die` on a missing/corrupt lease — **return 1** (it is a normal state; the
  caller branches on it). The S1 writers die; the readers must not.
- ❌ Don't leave a caller writing `out="$(pool_lease_read 99)"` ungoverned under `set -e` —
  it aborts the caller. Use `rc=0; out="$(…)" || rc=$?` or `if out="$(…)"; then`.
- ❌ Don't use `jq -e` in `pool_lease_field` — it exits 1 on the boolean `false`, breaking
  `connected` reads. Use plain `jq -r`.
- ❌ Don't build a jq filter by interpolating the field name (`jq -r ".${field}"`) — pass it
  as `--arg` data with the fixed-literal `getpath($f|split("."))`.
- ❌ Don't make `pool_lease_field` top-level-only — consumers (find_my_lease) need nested
  `owner.pid` / `owner.starttime`. `getpath`+`split` handles both.
- ❌ Don't log from `pool_lease_exists` (pure predicate) or `pool_lease_field` (quick
  helper). Only `pool_lease_read` logs (on corrupt — the CONTRACT).
- ❌ Don't re-implement JSON validation — compose `_pool_json_valid` (syntax predicate).
- ❌ Don't add a full schema-completeness validator — out of CONTRACT scope; consumers read
  fields defensively (missing → null).
- ❌ Don't mkdir inside these functions — a missing dir → file-not-found → return 1 (correct).
- ❌ Don't re-add a trailing newline to `pool_lease_read` output — `cat` echoes the raw
  (newline-less per S1) bytes; consumers handle it.
- ❌ Don't catch-all and `pool_die` — these are readers; failure is a `return 1`, not fatal.
