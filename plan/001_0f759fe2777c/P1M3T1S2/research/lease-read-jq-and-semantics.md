# Research: lease read functions — jq read semantics + return-vs-die contract

**Date:** 2026-07-12 (host-verified) · **Host:** jq 1.8.2 at `/usr/bin/jq`, bash 5.x
**Task:** P1.M3.T1.S2 — Lease read function + validation
**Method:** live verification on the target host of every behavioral claim below.

Combines (a) the jq manual / man-page facts with (b) **live host verification** of the
exact read paths this task must implement. Every code block's stated exit code / output
was re-run on this host on 2026-07-12.

---

## 1. THE central design fact: READ functions return 1, they do NOT `pool_die`

The S1 writers (`pool_lease_write` / `pool_lease_update`) `pool_die` on failure because a
writer is *expected to succeed* and a failed write is an exceptional, fatal condition.

The S2 READ functions are the **opposite**: a missing or corrupt lease is a **NORMAL,
expected runtime state**, not an error. The item CONTRACT is explicit:

> Lease files are optional — a lane with no .json file is simply unleased. Leases may be
> corrupt if a crash happened mid-write (rare with atomic writes, but defensive coding
> is needed).
> a. `pool_lease_read(lane)` … If file doesn't exist, return 1. If invalid JSON, log
>    warning and return 1.
> c. `pool_lease_exists(lane)` — Return 0 if lease file exists and is valid, 1 otherwise.

So **all three functions `return 1` (never `pool_die`) when the lease is absent/corrupt.**
This mirrors the existing read-side convention in `lib/pool.sh`:
`_pool_json_valid` (returns 0/1, "NEVER fatal") and `pool_owner_alive` (returns 0/1,
"NEVER fatal — never calls pool_die"). The read layer joins that family.

| Function | Missing file | Corrupt JSON | Valid JSON | Happy value |
|---|---|---|---|---|
| `pool_lease_read` | return 1 (silent) | return 1 (**+ `_pool_log` warning**) | echo raw JSON, return 0 | the file bytes |
| `pool_lease_field` | return 1 (silent) | return 1 (silent) | echo field value, return 0 | the field's raw value |
| `pool_lease_exists` | return 1 (silent) | return 1 (silent) | return 0 | (no echo — pure predicate) |

**Only `pool_lease_read` logs** (the CONTRACT names it: "log warning and return 1").
`pool_lease_exists` is a pure predicate (no log — like `_pool_json_valid`/`pool_owner_alive`).
`pool_lease_field` is a thin "quick access" helper; it is silent on missing/corrupt
(callers wanting diagnostics use `pool_lease_read`).

---

## 2. CRITICAL caller-side gotcha: `set -e` aborts on a non-zero return

`lib/pool.sh` opens with `set -euo pipefail` (P1.M1.T1.S1) which propagates into every
caller. Because the read functions **return 1** for the normal "no lease" case, a caller
that writes:

```bash
out="$(pool_lease_read 99)"; rc=$?     # ← ABORTS the caller under set -e before rc=$?
```

will have its shell **aborted** by errexit the moment `pool_lease_read 99` returns 1,
because a plain assignment's exit status == the command-substitution's status, and
errexit fires on non-zero. (`rc=$?` never runs.) **Host-verified** — a prototype test
harness died here exactly this way on 2026-07-12.

The correct caller idioms (document this for the M3.T2 / M5 / M7 consumers):

```bash
# (a) capture rc without aborting:
rc=0; out="$(pool_lease_read "$lane" 2>/dev/null)" || rc=$?

# (b) branch on it:
if out="$(pool_lease_read "$lane")"; then
    # lease exists & valid — use $out
else
    # no lease / corrupt — acquire instead
fi

# (c) predicate directly in a condition (errexit-exempt):
if pool_lease_exists "$lane"; then ...; fi
```

This is the **defining consequence** of the return-1-vs-pool_die choice and must be
called out in every consumer-facing note. (Contrast: the S1 writers `pool_die` and so
never need this guard — they exit the process, they don't return.)

---

## 3. jq read behaviors — host-verified (jq 1.8.2)

| Operation | Exit | Output | Note |
|---|---|---|---|
| `jq . /nonexistent.json` | **2** | (stderr: "No such file") | missing FILE |
| `jq . <corrupt>` | **5** | (stderr: parse error) | malformed JSON |
| `jq . <empty-file>` | **0** | (nothing) | empty file parses as "no input" → NOT caught by `_pool_json_valid` |
| `jq -r '.port' lease` | 0 | `53427` | existing top-level field |
| `jq -r '.missing' lease` | **0** | **`null`** (literal string) | MISSING field prints "null", exit 0 — GOTCHA |
| `jq -re '.missing' lease` | **1** | (nothing) | `-e` → exit 1 on null |
| `jq -re '.connected' lease`(=false) | **1** | (nothing) | **`-e` ALSO exits 1 on `false` — DANGER** |
| `jq -re '.connected' lease`(=true) | 0 | `true` | `-e` exits 0 on true/value |

### 3a. NEVER use `jq -e` in `pool_lease_field`

`-e` / `--exit-status` makes jq exit 1 when the last output value is `null` **or `false`**
(jq manual: <https://jqlang.github.io/jq/manual/#invoking-jq>). The lease schema has a
**boolean** `connected` field. `pool_lease_field 7 connected` on a lease with
`"connected": false` would exit 1 and print nothing — looking exactly like "field
missing" / "lease invalid". **Host-verified:** `jq -re '.connected'` on `{"connected":false}`
→ exit 1. Therefore `pool_lease_field` uses plain `jq -r` (no `-e`): a present field
ALWAYS echoes its value and returns 0, even when the value is the boolean `false`.

### 3b. Injection-safe field read that supports NESTED paths (owner.pid)

The CONTRACT says "Read a specific field via `jq -r .field`". A literal
`jq -r ".${field}"` would **splice** `$field` into the jq PROGRAM text — injectable and
fragile (S1's research §2 establishes this for the update side). The injection-safe
realization, which ALSO handles the nested `owner.pid` / `owner.starttime` paths the
downstream consumers (find_my_lease, reap, reuse_orphan) need, is:

```bash
jq -r --arg f "$field" 'getpath($f|split("."))' "$file"
```

**Host-verified (2026-07-12):**

```bash
$ printf '{"port":53427,"owner":{"pid":100,"comm":"pi"}}' > /tmp/l.json
$ jq -r --arg f 'owner.pid'       'getpath($f|split("."))' /tmp/l.json   # → 100, exit 0
$ jq -r --arg f 'port'            'getpath($f|split("."))' /tmp/l.json   # → 53427, exit 0 (top-level via split)
$ jq -r --arg f 'owner.starttime' 'getpath($f|split("."))' /tmp/l.json   # → null, exit 0 (missing nested)
$ jq -r --arg f 'nope.nada'       'getpath($f|split("."))' /tmp/l.json   # → null, exit 0 (missing path)
```

**Why injection-safe:** the filter handed to jq is the fixed literal
`getpath($f|split("."))`. The field name enters jq as **data** via `--arg f` (a JSON
string), is split into a path array, and is used as a dict key — it never becomes part of
the program text. `getpath([])` on a path that doesn't exist returns `null` (not an
error) → safe for arbitrary field names. This mirrors S1's `--arg f … '.[$f] = $v'`
update pattern (research `jq-lease-build-and-update.md` §2) but extends it to dotted
paths via `split(".")`.

A **missing field prints `null`** (literal) with exit 0 (§3 table). Callers query
schema-defined fields, so this is harmless and standard jq behavior; document it.
(`jq -r '.a // empty'` would suppress null, but then a legitimate null-valued field also
vanishes — the lease schema has no null fields, but keeping `jq -r .field` semantics
faithful is simpler and matches the CONTRACT wording.)

### 3c. Empty file is "valid JSON" to `_pool_json_valid` — acceptable

`_pool_json_valid` (M1.T2.S1) runs `jq empty`, which exits **0** on an empty file (no
input → no error). So an empty lease file passes the syntax check. This is the same
"syntax, not schema" limitation already documented on `_pool_json_valid` ("accepts
scalars/empty; the stricter schema check is M3.T1.S2's job"). For THIS task it is
acceptable: an empty file is not a realistic outcome of an atomic write (S1's
`pool_lease_write` always writes a full object), and downstream consumers
(find_my_lease) read specific fields defensively via `pool_lease_field`, where a missing
field yields `null`. A full **schema-completeness** validator (all 12 fields, correct
types) is out of scope for the literal CONTRACT ("exists and is valid" = exists +
parseable); consumers own field-level defensiveness. (Noted in the PRP gotchas.)

---

## 4. Path-traversal defense: validate `lane` is `^[0-9]+$`

`$POOL_LANES_DIR/$lane.json` interpolates `lane` into a path. A caller-supplied
`lane="../../etc/passwd"` would resolve to a path **outside** `$POOL_LANES_DIR` → an
arbitrary-file read. All three functions therefore validate `lane` against `^[0-9]+$`
before constructing the path. On an invalid lane:

- `pool_lease_exists` → return 1 (predicate: "doesn't exist"; never fatal).
- `pool_lease_read` / `pool_lease_field` → return 1 (read functions never `pool_die`).

`[[ "$lane" =~ ^[0-9]+$ ]] || return 1` is errexit-exempt (the `||` list). This matches
the lane validation in S1's writers — but the writers `pool_die` (a bogus write is a
bug), whereas the readers `return 1` (a read that finds nothing is graceful). The
asymmetry is intentional and documented in §1.

---

## 5. Composing the existing primitives (no reinvention)

| Primitive (M1.T2.S1, COMPLETE) | Contract | Used here for |
|---|---|---|
| `_pool_json_valid FILEPATH` | predicate: `jq empty` → 0 valid / 1 malformed-missing. **Never fatal.** | the "is valid" check in all three functions (pool_lease_read corrupt branch, pool_lease_field guard, pool_lease_exists predicate) |
| `_pool_log MSG...` | one ISO-timestamped line to the pool log + stderr | the ONE warning `pool_lease_read` emits on a corrupt lease |
| `POOL_LANES_DIR` (frozen by `pool_config_init`) | absolute path to the lanes dir | constructing `$POOL_LANES_DIR/<lane>.json` |

Do NOT re-implement JSON validation (compose `_pool_json_valid`). Do NOT add a new log
helper (compose `_pool_log`). `jq` is the only external read tool (verified §3).

---

## 6. Downstream consumers (the contract this task must serve)

| Consumer (task) | Calls | Why it needs the read layer |
|---|---|---|
| **P1.M3.T2.S1** find_my_lease(owner) | `pool_lease_field lane owner.pid` / `… owner.starttime` (nested) | match owner identity across lanes (PRD §2.4 step 2). **Needs nested-path support** → §3b. |
| **P1.M3.T2.S2** find_free_lane | `pool_lease_exists lane` | "lowest N≥1 with no lease" — `exists` returning 1 == free |
| **P1.M3.T2.S3** is_lane_stale | `pool_lease_field lane last_seen_at` / `chrome_pid` + `pool_lease_read` for owner | staleness detection for the lazy reaper (PRD §2.10) |
| **P1.M5.T3.S1** reap_stale | `pool_lease_read lane` (owner) per lane | scan all lanes, release stale ones |
| **P1.M5.T3.S2** reuse_orphan | `pool_lease_field lane owner.pid` / `chrome_pid` / `port` / `connected` / `ephemeral_dir` | adopt a responsive Chrome whose owner died |
| **P1.M7.T1.S1** admin `status` | `pool_lease_field lane lane/port/session/chrome_pid/acquired_at/connected` | render the lane table (age via `_pool_age_str` on `acquired_at`) |
| **P1.M7.T4.S1** doctor | `pool_lease_exists` + `pool_lease_read` | reconcile leases vs live Chromes vs dirs |

**Implication:** `pool_lease_field` MUST support nested paths (`owner.pid`,
`owner.starttime`) — §3b. A top-level-only helper would force every consumer to hand-roll
`jq` over `pool_lease_read` output, defeating the "quick access" purpose.

---

## 7. Placement, naming, scope

- **Append at EOF** of `lib/pool.sh`, in the SAME "Lease management" section banner S1
  added (or directly below the S1 writers if S1 landed first). The two halves (write in
  S1, read in S2) live together under one banner.
- **No edits** to any existing function (S1/S2/S3/T2.S1/M2.*/S1-writers).
- **Naming:** `pool_lease_read`, `pool_lease_field`, `pool_lease_exists` —
  `pool_lease_*` subdomain, no `_` prefix (entry points, mirroring `pool_owner_resolve`,
  `pool_lease_write`). Item-mandated exact names.
- **No new globals, no new env vars, no new files, no new external deps.** Pure
  additions: three functions (+S2's note under the existing banner). Composes
  `_pool_json_valid` / `_pool_log` and reads `POOL_LANES_DIR`.
- **Preconditions:** `pool_config_init` (freezes `POOL_LANES_DIR`) must have run. The
  functions do NOT `mkdir` (a missing dir surfaces as `[[ -f file ]]` → false → return 1,
  which is correct — "no lease").

### Scope guard (do NOT do in this task)
- ❌ lease WRITE / UPDATE (S1 — `pool_lease_write` / `pool_lease_update`).
- ❌ lease DELETE / teardown (M5.T2.S1 release).
- ❌ lease QUERIES: enumerate / find_my_lease / find_free_lane / is_lane_stale (M3.T2.*).
- ❌ a full schema-completeness validator (all 12 fields + types). The literal CONTRACT is
  "exists and is valid" = syntactically parseable; field-level defensiveness is the
  consumer's job. (May be added later if a consumer needs it; not required by any
  current consumer.)
- ❌ acquire / release / reap / flock orchestration (M5.*).
