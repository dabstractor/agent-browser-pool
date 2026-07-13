# Research: Lease schema + atomic write (`pool_lease_write` / `pool_lease_update`)

> Host-verified 2026-07-12. jq 1.8.2 at `/usr/bin/jq`. shellcheck 0.11.0 at `/usr/bin/shellcheck`.
> Source codebase: `lib/pool.sh` (649 lines as of P1.M2.T2.S1). Last function: `pool_owner_alive()` (line 616).

## 1. What already exists (consume, don't re-implement)

Prior subtasks delivered every primitive this task needs. Confirmed by reading `lib/pool.sh`:

| Primitive | Delivered by | Contract used here |
|---|---|---|
| `_pool_atomic_write FILEPATH CONTENT` | P1.M1.T2.S1 | Writes `"$FILEPATH".tmp` then `mv -f --` over `"$FILEPATH"` (same dir → same FS → atomic rename). `pool_die` on failure. `printf '%s'` preserves exact bytes. |
| `_pool_json_valid FILEPATH` | P1.M1.T2.S1 | `if jq empty ...; then return 0; fi; return 1`. Never fatal. |
| `_pool_now` | P1.M1.T2.S1 | `date '+%s'` → digits. |
| `pool_die MSG` | P1.M1.T1.S1 | `printf '%s\n' "$*" >&2; exit 1`. **FATAL — exits the whole process**, NOT catchable by `if`. |
| `pool_config_init` | P1.M1.T1.S2 | Sets `POOL_LANES_DIR` (absolute) — the dir lease files live in. |
| `pool_owner_resolve` | P1.M2.T1.S1 | Sets `POOL_OWNER_PID/COMM/STARTTIME/CWD`. The caller passes these as explicit args. |

**`POOL_LANES_DIR`** is the absolute lease directory. Lease file for lane N = `"$POOL_LANES_DIR/$N.json"` (external_deps §6, system_context §7, pool.sh line 109).

## 2. The lease schema (PRD §2.8 / external_deps §6) — VERIFIED field order & types

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

| field | JSON type | jq flag | source |
|---|---|---|---|
| `version` | number | `--argjson version 1` (hardcoded) | constant |
| `lane` | number | `--argjson lane "$lane"` | arg $1 |
| `ephemeral_dir` | string | `--arg` | arg $2 |
| `port` | number | `--argjson` | arg $3 |
| `session` | string | `--arg` | arg $4 |
| `owner.pid` | number | `--argjson` | arg $5 |
| `owner.comm` | string | `--arg` | arg $6 |
| `owner.starttime` | number | `--argjson` | arg $7 |
| `owner.cwd` | string | `--arg` | arg $8 |
| `chrome_pid` | number | `--argjson` | arg $9 |
| `chrome_pgid` | number | `--argjson` | arg ${10} |
| `acquired_at` | number | `--argjson acquired_at "$now"` | `_pool_now` (auto) |
| `last_seen_at` | number | `--argjson last_seen_at "$now"` | `_pool_now` (auto) |
| `connected` | boolean | `--argjson connected "$connected"` | arg ${11} (must be `true`\|`false`) |

## 3. Host-verified jq facts (the core of this subtask)

**FACT A — `jq -n` builds the exact nested object** (Test 1, this session). The full 14-field
construction produces byte-correct JSON with `owner` as a nested object, numbers as numbers,
booleans as booleans. exit 0.

**FACT B — dynamic-key update via `.[$field] = $value` works** (Test 2). For top-level fields:
```
jq --arg field "port"      --argjson value 53427  '.[$field] = $value' lease.json   # .port = 53427
jq --arg field "connected" --argjson value true   '.[$field] = $value' lease.json   # .connected = true
jq --arg field "chrome_pid" --argjson value 104816 '.[$field] = $value' lease.json  # .chrome_pid = 104816
```
Other fields are preserved (read-modify-write, not replace). Cited authorities:
- `https://jqlang.github.io/jq/manual/#invoking-jq` — `--arg` (→ string) vs `--argjson` (→ parsed JSON literal).
- `https://jqlang.github.io/jq/manual/#assignment` — `=` updates any path expression.
- `https://jqlang.github.io/jq/manual/#basic-filters` — `.[$var]` is a legal path expression.

**FACT C — `--argjson` FAILS (exit 2) on empty/non-JSON input** (Test 3):
```
jq -n --argjson x "" '{x:$x}'   → exit 2 "invalid JSON text passed to --argjson"
jq -n --argjson x "abc" '{x:$x}' → exit 2
jq -n --argjson connected "false" '{connected:$connected}' → exit 0  (boolean OK)
```
Consequence: under `set -e` (propagated by S1), a bad `--argjson` aborts the process with a
cryptic jq error. TWO defenses: (1) **validate numeric fields up front** with `[[ =~ ^[0-9]+$ ]]`
→ `pool_die` with a clear message; (2) guard the jq capture with `|| pool_die`.

**FACT D — the `connected` boolean trap.** `--argjson connected "1"` yields the NUMBER `1`, not
boolean `true` → schema violation. The caller MUST pass the JSON literal `true` or `false`.
Validate: `[[ "$connected" == "true" || "$connected" == "false" ]] || pool_die`.

**FACT E — `owner.starttime` can be EMPTY.** `pool_owner_resolve` (M2.T1.S1) leaves
`POOL_OWNER_STARTTIME` empty when `/proc/<pid>/stat` could not be parsed. A lease with an empty
starttime breaks the anti-recycling contract (M2.T2.S1). So `pool_lease_write` MUST reject an
empty/non-numeric starttime via the numeric validation (`pool_die`). This is a real bug-catcher.

## 4. The `pool_die` fatal-error model (CRITICAL — easy to get wrong)

`pool_die` does `exit 1` — it terminates the **whole shell process**, it does NOT merely
return non-zero from the function. Therefore:

```bash
# BROKEN: pool_die exits before `if` can evaluate the failure branch
if pool_lease_update 99 port 1; then echo ok; else echo "caught"; fi   # process already exited

# CORRECT understanding: these functions are FATAL on precondition violation. Callers
# (M5 acquire/release) operate in a context where the preconditions HOLD (lane claimed,
# lease exists, owner alive). pool_die firing = a real unrecoverable bug.
```
VERIFIED (NEG 1/2/3 this session): every `pool_die` path exits with code 1 and a clear stderr
message. So `pool_lease_write`/`pool_lease_update` are NOT catchable predicates — they are
"do-or-die" primitives. Document this loudly in the PRP.

## 5. Concurrency / flock: pool_lease_update does NOT need flock (ownership invariant)

`pool_lease_update` is a read-modify-write (TOCTOU-prone by itself). It is called during
**post-lock boot** (M5.T1.S2), AFTER the flock critical section released the lock. It is safe
WITHOUT flock because of the **ownership invariant**:

- The lane already has a provisional lease owned by THIS process (pid+starttime).
- The reaper (M5.T3) only reaps STALE lanes (dead owner) — this owner is alive → not reaped.
- `reuse_orphan` (M5.T3.S2) only adopts lanes with a DEAD owner — not adopted.
- `find_free_lane` (M3.T2.S2) only picks lanes with no/stale lease — this lane is claimed → skipped.
- Release (M5.T2) is only invoked by the owner itself.

→ No other process mutates a live-owner lane's lease. So a single un-locked read-modify-write is
safe. The tmp+mv (`_pool_atomic_write`) still guarantees no torn READS for concurrent readers
(status, reaper scan). Document: pool_lease_update takes NO flock; correctness rests on the
ownership invariant, not on locking.

(Caveat to document: `.[$field] = $value` only updates TOP-LEVEL fields. owner.* is nested and is
set once at acquire by pool_lease_write and never updated — so no nested update is needed. If a
nested update is ever needed later, a separate helper with `.owner.starttime = $v` is required.)

## 6. Reference implementation — VERIFIED end-to-end this session

A full prototype of both functions was run against the real `lib/pool.sh` (`_pool_atomic_write`,
`_pool_json_valid`, `pool_config_init`, `pool_state_init`) in a temp `AGENT_BROWSER_POOL_STATE`:

1. Provisional claim `pool_lease_write 7 .../7 0 abpool-7 836725 pi 1234567890 /home/dustin/projects/x 0 0 false`
   → wrote `7.json` with `port:0, chrome_pid:0, chrome_pgid:0, connected:false`, both timestamps = now.
2. Post-lock updates: `pool_lease_update 7 port 53427` / `chrome_pid 104816` / `chrome_pgid 104816` / `connected true`
   → final lease has all four updated, owner block + acquired_at UNCHANGED (read-modify-write preserves).
3. Schema check `jq -e 'type=="object" and .version==1 and .lane==7 and (.port|type)=="number" ...'` → PASS.
4. No orphan `.tmp` after writes.
5. Negative paths: bad connected → pool_die exit 1; empty starttime → pool_die exit 1; jq failure → caught by `|| pool_die`.

This is the exact shape the PRP's Implementation Patterns section specifies. The implementer can
paste it nearly verbatim.

## 7. Naming & placement

- Naming convention (key_findings "Function Naming"): `pool_lease_*` = public lease read/write/query
  functions (called by M5 acquire/release, M7 admin, tests). These are the FIRST `pool_lease_*`
  functions in the codebase.
- Placement: append at EOF (after `pool_owner_alive`, line 616), under a new section header comment:
  `# === Lease Management (P1.M3.T1) ===`.
