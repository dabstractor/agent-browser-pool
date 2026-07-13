# Codebase research: lease schema, dependencies & downstream consumers

**Task:** P1.M3.T1.S1 — Lease schema + atomic write function
**Date:** 2026-07-12

Cross-references the PRD, the architecture docs, the already-landed `lib/pool.sh`,
and the sibling PRPs. Establishes the exact contract `pool_lease_write` /
`pool_lease_update` must satisfy, the primitives they compose, and the consumers
that will call them.

---

## 1. The lease schema (authoritative)

Three sources agree (PRD §2.8 = external_deps §6 = the schema this task writes):

```json
{
  "version": 1,
  "lane": 7,
  "ephemeral_dir": "/home/dustin/.agent-chrome-profiles/active/7",
  "port": 53427,
  "session": "abpool-7",
  "owner": { "pid": 836725, "comm": "pi", "starttime": 1234567890, "cwd": "/home/dustin/projects/x" },
  "chrome_pid": 104816,
  "chrome_pgid": 104816,
  "acquired_at": 1720000000,
  "last_seen_at": 1720000123,
  "connected": true
}
```

File location: **`$POOL_LANES_DIR/<N>.json`** (`POOL_LANES_DIR` frozen by
`pool_config_init`, P1.M1.T1.S2; the dir created by `pool_state_init`, P1.M1.T1.S3).

Field-by-field typing for the `jq -n` build:

| field | JSON type | jq flag | source / notes |
|---|---|---|---|
| `version` | number | `--argjson` | **constant `1`** (hardcoded in the build) |
| `lane` | number | `--argjson` | `$1` (validated `^[0-9]+$`) |
| `ephemeral_dir` | string | `--arg` | `$2` (absolute path — PRD §2.2, no `~`) |
| `port` | number | `--argjson` | `$3` (placeholder `0` during provisional claim) |
| `session` | string | `--arg` | `$4` (`abpool-<N>`) |
| `owner.pid` | number | `--argjson` | `$5` |
| `owner.comm` | string | `--arg` | `$6` (normally `pi`) |
| `owner.starttime` | number | `--argjson` | `$7` (from `_pool_get_starttime`) |
| `owner.cwd` | string | `--arg` | `$8` (absolute) |
| `chrome_pid` | number | `--argjson` | `$9` (placeholder `0` during provisional claim) |
| `chrome_pgid` | number | `--argjson` | `$10` (placeholder `0` during provisional claim) |
| `acquired_at` | number | `--argjson` | **auto** `$(_pool_now)` at write time |
| `last_seen_at` | number | `--argjson` | **auto** `$(_pool_now)` at write time (same value as acquired_at) |
| `connected` | boolean | `--argjson` | `$11` — validated to be literally `true` or `false` |

**Key design choice:** `acquired_at` and `last_seen_at` are NOT caller args — they
are auto-set to `$(_pool_now)` (captured ONCE, so both equal the same second). A fresh
lease therefore always has `acquired_at == last_seen_at`. (Heartbeat refresh of
`last_seen_at` alone is done later via `pool_lease_update lane last_seen_at <now>`.)

---

## 2. Primitives already in `lib/pool.sh` (M1 — COMPLETE) — compose, don't reinvent

| Primitive (P1.M1.T2.S1) | Contract | Use |
|---|---|---|
| `_pool_atomic_write FILEPATH CONTENT` | writes `FILEPATH.tmp` then `mv -f` over target; same-dir → atomic rename. `pool_die` on write/rename failure. `printf '%s'` preserves exact bytes (no added `\n`). | **publishes** the built/updated lease JSON |
| `_pool_json_valid FILEPATH` | predicate: `jq empty` → 0 valid / 1 malformed-missing. Syntax-only (accepts scalars/empty). Never fatal. | `pool_lease_update` pre-check for a clear "not valid JSON" message before the jq mutate |
| `_pool_now` | echoes Unix epoch digits, exit 0 | timestamps `acquired_at`/`last_seen_at` |
| `_pool_age_str TS` | echoes `Ns`/`Nm`/`Nh`/`Nd` | (consumed later by M7 status, not by this task) |

These are **leaf helpers** that take explicit args and read no globals. `pool_lease_*`
DOES read the `POOL_LANES_DIR` global (frozen by `pool_config_init`) — so `pool_config_init`
(+ `pool_state_init` to create the dir) is a **precondition** for both new functions.

**Supporting (S1):** `pool_die MSG...` (printf to stderr, exit 1) — the canonical
fatal-exit helper for write/build/mutate failures.

---

## 3. Owner globals this task will typically source from (M2.T1.S1 — LANDED)

`pool_owner_resolve()` (M2.T1.S1) populates, after a real `pi`-ancestor walk or a
test-hook override:

```
POOL_OWNER_PID        POOL_OWNER_COMM   POOL_OWNER_STARTTIME   POOL_OWNER_CWD
```

`pool_lease_write` does **not** read these directly — it takes explicit args (the item
description specifies the owner fields as INPUT, and explicit args are more
testable/reusable). But the realistic call site is:

```bash
pool_owner_resolve                      # sets POOL_OWNER_*
pool_lease_write "$lane" "$eph" "$port" "abpool-$lane" \
    "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "$POOL_OWNER_STARTTIME" "$POOL_OWNER_CWD" \
    0 0 false                           # provisional: chrome_pid/chrome_pgid=0, connected=false
```

**Parallel item note:** P1.M2.T2.S1 (`pool_owner_alive`) is being implemented in
parallel and appends `pool_owner_alive()` below `pool_owner_resolve()`. This task
appends a NEW "Lease management" section after the owner section (at EOF). There is no
functional coupling (lease I/O does not call the liveness predicate); only file
placement ordering matters — append at EOF, do not touch any owner function.

---

## 4. Downstream consumers (the contract this task must serve)

| Consumer (task) | Calls | Why |
|---|---|---|
| **P1.M5.T1.S1** acquire — flock critical section | `pool_lease_write` with **provisional** values: `port=0 chrome_pid=0 chrome_pgid=0 connected=false` | claims the lane under flock; the claim record must exist so concurrent acquires see it as taken (key_findings FINDING 2). Then the lock is RELEASED before Chrome boots. |
| **P1.M5.T1.S2** post-lock boot | `pool_lease_update lane port <P>`; `… lane chrome_pid <PID>`; `… lane chrome_pgid <PGID>`; `… lane connected true` | fills in the real port/pid/pgid/connected after Chrome is up & connected (M1.T1.S1 §2 = key_findings FINDING 2). |
| **P1.M5.T1.S3** ensure_connected | `pool_lease_update lane last_seen_at <now>` | heartbeat on every invocation (PRD §2.4 step 4). |
| **P1.M5.T2.S1** release | deletes `$POOL_LANES_DIR/<N>.json` (not via these fns; teardown removes the file) | release is delete, not a write. (This task does NOT implement delete.) |
| **P1.M3.T1.S2** lease read + validation | reads `$POOL_LANES_DIR/<N>.json` (separate task) | reads what this task wrote; the schema written here must match the schema validated there. |
| **P1.M3.T2.\*** lease queries | read-only over the leases this task writes | enumerate / find_my_lease / find_free_lane / is_lane_stale. |
| **P1.M7.T1.S1** admin `status` | reads `acquired_at` → `_pool_age_str` | renders the age column. |

**Implication for `pool_lease_update`'s field set:** the only fields ever updated in
place are **top-level**: `port`, `chrome_pid`, `chrome_pgid`, `connected`,
`last_seen_at`. The `owner.*` sub-object is written once at acquire and never
mutated. Therefore `pool_lease_update(lane, field, value)` handles **top-level fields
only** (dotted/`owner.*` updates are out of scope and unnecessary). The field-name
regex `^[a-zA-Z_][a-zA-Z0-9_]*$` matches every updatable field.

---

## 5. Placement & dependencies in `lib/pool.sh`

- **Append at EOF** (below the owner-resolution section: `pool_owner_resolve` and, if
  landed, the parallel `pool_owner_alive`). Add a section banner:
  `# Lease management — JSON write & atomic update (P1.M3.T1.S1)`.
- **No edits** to any existing function (S1/S2/S3/T2.S1/M2.T1.\*/M2.T2.S1).
- **Hard dependencies (all COMPLETE / parallel):**
  - `_pool_atomic_write`, `_pool_json_valid`, `_pool_now`, `pool_die` (M1 — done).
  - `POOL_LANES_DIR` global (frozen by `pool_config_init` — M1.T1.S2, done).
- **No new globals, no new env vars, no new files, no new external deps.** Pure
  additions: two functions + one section banner. `jq` already verified present.

---

## 6. Function naming (key_findings "Function Naming Convention")

- `pool_lease_*` ← lease read/write/query subdomain. These two functions are
  `pool_lease_write` and `pool_lease_update` (the item description mandates these
  exact names). They carry no `_` prefix — they are the lease-subdomain entry points
  (mirrors `pool_owner_resolve`, also unprefixed). Internal-only in PRACTICE (never
  called by an operator), but part of the library's public-ish lease API.

---

## 7. Scope guard (do NOT do in this task)

- ❌ lease READ (`pool_lease_read` + schema validation) → **P1.M3.T1.S2**.
- ❌ lease QUERIES (enumerate / find_my_lease / find_free_lane / is_lane_stale) → **P1.M3.T2.\***.
- ❌ lease DELETE / teardown → **P1.M5.T2.S1** (release).
- ❌ acquire / provisional-claim orchestration / flock → **P1.M5.T1.S1**.
- ❌ reading `owner.*` from globals inside `pool_lease_write` (take explicit args).
- ❌ re-implementing tmp+mv (compose `_pool_atomic_write`).
- ❌ range-validating `port` (that's `find_free_port`, M4.T2.S1) — store what's given.
