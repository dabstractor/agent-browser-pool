# Research: lanes enumeration + find_my_lease(owner)

**Date:** 2026-07-12 (host-verified) · **Host:** bash 5.x, jq 1.8.2 at `/usr/bin/jq`
**Task:** P1.M3.T2.S1 — Enumerate lanes + `find_my_lease(owner)`
**Method:** live prototype appended to the REAL `lib/pool.sh`, exercising every branch.

This task builds the **lease query layer** that sits directly above the lease I/O layer
(S1 write/update + S2 read/field/exists, both LANDED in `lib/pool.sh`). It introduces the
first functions that *iterate across lanes* and *correlate a lease's owner with the live
owner globals*. Every behavioral claim below was verified on this host on 2026-07-12.

---

## 0. Dependency state — what is ALREADY in `lib/pool.sh` (host-verified)

`grep -nE '^pool_lease_(write|update|read|field|exists)\(\)' lib/pool.sh` returns:

```
682:pool_lease_write()        # S1 — full lease builder + atomic publish
763:pool_lease_update()       # S1 — top-level field mutate + atomic re-publish
823:pool_lease_read()         # S2 — echo raw JSON / rc 0; missing→rc1 silent; corrupt→rc1 + 1 log line
876:pool_lease_field()        # S2 — injection-safe getpath read (top-level + nested); missing field→echo "null" rc0
918:pool_lease_exists()       # S2 — predicate: exists + valid JSON → rc0; else rc1 (never logs)
```

So **S1 AND S2 are both landed**. This task composes them. `pool_owner_alive(pid, starttime,
expected_comm="pi")` (M2.T2.S1, line 616) is also present — returns 0 (alive + same
process) / 1 (dead / recycled / unverifiable), NEVER fatal.

Owner globals populated by `pool_owner_resolve()` (M2.T1.S1): `POOL_OWNER_PID`,
`POOL_OWNER_COMM`, `POOL_OWNER_STARTTIME`, `POOL_OWNER_CWD`. In TEST mode
(`AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`) the globals are set directly; otherwise the
ppid walk finds the real pi ancestor. `POOL_OWNER_PID == "0"` ⟺ no pi ancestor (passthrough).

---

## 1. `pool_lanes_list()` — enumerate numeric lane stems from `$POOL_LANES_DIR/*.json`

### CONTRACT
> a. `pool_lanes_list()` — List all N from $POOL_LANES_DIR/*.json. Echo each N on a separate line.

### Host-verified implementation

```bash
pool_lanes_list() {
    local f base n
    for f in "$POOL_LANES_DIR"/*.json; do
        [[ -f "$f" ]] || continue        # no-match literal + subdirs + non-files
        base="${f##*/}"                  # strip directory prefix
        n="${base%.json}"                # strip .json suffix → the stem
        [[ "$n" =~ ^[0-9]+$ ]] || continue   # numeric-only (defensive; skip stray *.json)
        printf '%s\n' "$n"
    done | sort -n
    return 0
}
```

### Verified behaviors
| Case | Output | rc | Notes |
|---|---|---|---|
| empty dir / dir missing | (none) | 0 | no-match glob stays literal `*.json`; `[[ -f ]]` filters it → 0 iterations |
| lanes 2,3,7,100 + `foo.json` + `sub.json/` dir | `2\n3\n7\n100` | 0 | junk stem + subdir both filtered by the numeric/`-f` tests; `sort -n` ⟹ 2 3 7 100 |

### Why each micro-decision
- **`[[ -f "$f" ]] || continue`**: with `nullglob` NOT set, a no-match glob expands to the
  LITERAL string `$POOL_LANES_DIR/*.json`. `-f` is false for that literal (and for
  directories, and for a `sub.json/` dir) ⟹ it is skipped. Without this guard, `base%.json`
  on the literal would yield `*` and the numeric test would reject it anyway — but `-f` is
  the cleaner primary gate and also rejects a stray directory named `7.json` (defensive).
  **Verified:** survives `set -euo pipefail` on a no-match glob (2026-07-12).
- **`${f##*/}` then `${base%.json}`**: pure-bash parameter expansion, no `basename` fork.
  `${f##*/}` = longest-prefix strip to last `/` (the filename); `${base%.json}` =
  shortest-suffix strip of `.json`. Yields the bare lane number.
- **`[[ "$n" =~ ^[0-9]+$ ]] || continue`**: defensive numeric filter. The contract says
  "*.json", but a stray non-numeric `.json` (e.g. an editor's `7.json.swp`? no — that lacks
  .json; but `acquire.lock.json`? no — it's `acquire.lock`). In practice only `<N>.json`
  files exist; the filter is cheap insurance so a malformed file never reaches the consumer.
  It also enforces the same lane-validation contract used by every other lease function
  (S1/S2 validate `^[0-9]+$`).
- **`| sort -n`**: deterministic ascending numeric order. find_mine/find_mine_any do not
  *need* order (the "one owner ≤1 lane" invariant ⟹ at most one match), but a deterministic,
  numerically-sorted enumeration is the sensible contract for ALL consumers (status table,
  doctor, find_free_lane lowest-N). `sort` is GNU coreutils (guaranteed present). Lane count
  is small (bounded by pool size), so the fork is negligible.
- **always `return 0`**: enumeration never fails — an empty pool is a valid, normal state
  (the wrapper's first-ever acquire). The function's exit status is `sort`'s (always 0); the
  explicit `return 0` documents intent and is robust under `pipefail`.

### `for n in $(pool_lanes_list)` word-splitting — SAFE here
The output is digits-only, one per line. Word-splitting on IFS (default includes newline)
yields exactly the lane numbers; no lane number contains whitespace/glob chars ⟹ unquoted
command substitution in a `for` loop is intentional and safe. (This is the standard bash
idiom for newline-separated numeric output; quoting would make it a single word.)

---

## 2. `pool_lease_find_mine()` — the wrapper's "do I already own a lane?" query

### CONTRACT
> b. `pool_lease_find_mine()` — Iterate all lanes. For each, read owner.pid, owner.comm,
> owner.starttime. If owner.pid == POOL_OWNER_PID AND pool_owner_alive(pid, starttime, comm)
> returns 0 → this is my valid lease. Echo the lane N and return 0. If no match → return 1.

### Host-verified implementation

```bash
pool_lease_find_mine() {
    local n pid st comm
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1   # no resolved owner → no lease
    for n in $(pool_lanes_list); do
        pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
        [[ "$pid" == "$POOL_OWNER_PID" ]] || continue         # cheap equality first
        st="$(pool_lease_field "$n" owner.starttime 2>/dev/null)" || continue
        comm="$(pool_lease_field "$n" owner.comm 2>/dev/null)" || continue
        if pool_owner_alive "$pid" "$st" "$comm"; then         # live + same process?
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 1
}
```

### Verified scenarios (all passed 2026-07-12)
| # | Setup | `find_mine` | Want |
|---|---|---|---|
| 3 | lanes 5,7,9; lane 7 owner == live self (pid+starttime+comm match) | rc 0, echo `7` | rc0 `7` ✓ |
| 4 | lanes all owned by OTHER pids | rc 1, silent | rc1 ✓ |
| 5 | lane 7 owner.pid == self but starttime MISMATCH (recycled/stale) | rc 1, silent | rc1 ✓ |
| 6 | lane 3 is CORRUPT (`printf 'NOT JSON{'`), lane 7 valid+mine | rc 0, echo `7` | corrupt skipped, mine found ✓ |
| 7 | `POOL_OWNER_PID` = real pi (this agent) but no lane matches | rc 1 | rc1 ✓ |

### Why each micro-decision
- **`[[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1` (guard first)**: if owner resolution
  has not run, or returned `0`/empty (passthrough — no pi ancestor), there is by definition
  no "my" lease. Guard early ⟹ no pointless scan. Also rejects a garbage/unset global
  defensively. (Note: `0` IS numeric ⟹ passes the regex; the loop then naturally finds no
  pid==0 lease ⟹ return 1. Correct either way; the guard also covers the unset/empty case.)
- **`pool_lease_field … || continue`**: a corrupt or mid-deletion lease (S2 returns rc 1) is
  SKIPPED, not fatal. This is critical — find_mine runs inside the hot wrapper path and must
  not abort on one bad lane. `2>/dev/null` suppresses jq's stderr on the (already-guarded)
  TOCTOU race. **Verified (scenario 6).**
- **cheap-equality-first ordering** (`pid ==` BEFORE `pool_owner_alive`): the CONTRACT
  explicitly says "owner.pid == POOL_OWNER_PID AND pool_owner_alive(…)". The vast majority of
  lanes are NOT mine; the string equality is ~free while `pool_owner_alive` does 3 `/proc`
  reads. Short-circuiting on pid avoids those reads for non-mine lanes. `pool_owner_alive`
  is only reached for the (≤1, by the §2.8 invariant) pid-matching lane.
- **`pool_owner_alive "$pid" "$st" "$comm"`**: signature is `(pid, expected_starttime,
  expected_comm="pi")` (M2.T2.S1, verified line 616). We pass the lease's stored
  starttime + comm so the predicate can compare them against the LIVE process's
  starttime/comm ⟹ defeats PID recycling. `comm` comes from the lease (`owner.comm`, always
  "pi" in production); passing it explicitly (rather than relying on the "pi" default) keeps
  the call self-documenting and faithful to the CONTRACT's `pool_owner_alive(pid, starttime,
  comm)`.
- **`if pool_owner_alive …; then echo+return 0; fi`**: `pool_owner_alive` returns 1 for
  dead/recycled ⟹ the `if` is simply false ⟹ keep scanning. Because the §2.8 invariant
  guarantees ≤1 pid match, the scan will fall through to `return 1` — but `continue`-style
  scanning (rather than `return 1` on the first pid-match-but-not-alive) is robust against an
  invariant violation (two lanes claiming the same pid) and costs nothing.
- **`return 1` at the end**: no valid mine found. NON-FATAL (never `pool_die`) — find_mine
  is a query whose "no" answer (rc 1) is the wrapper's signal to ACQUIRE (PRD §2.4 step 3).
  Mirrors the S2 read-layer convention (`return 1`, never die).

### The caller-side `set -e` idiom (carry-forward from S2's research §2)
Because `pool_lease_find_mine` returns 1 for the NORMAL "no lease" case, a caller under
`set -e` MUST guard:
```bash
if n="$(pool_lease_find_mine)"; then   # reuse lane $n
else                                    # acquire a new lane
fi
```
A bare `n="$(pool_lease_find_mine)"` ABORTS the caller on the rc-1 path (the wrapper, M6,
runs under `set -euo pipefail` propagated by lib/pool.sh). This is the defining consequence
of the return-1 design and must be documented for the M6.T3 consumer.

---

## 3. `pool_lease_find_mine_any()` — diagnostic "any lane claiming to be mine"

### CONTRACT
> c. `pool_lease_find_mine_any()` — Like find_mine but returns even if the owner check fails
>    (for diagnosing stale leases owned by this PID).

### Host-verified implementation

```bash
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
```

### Verified scenario (passed 2026-07-12)
- **Scenario 5**: lane 7 owner.pid == self, starttime MISMATCH (stale). `find_mine` → rc 1
  (not a *valid* lease); `find_mine_any` → rc 0, echo `7` (a lease CLAIMING to be mine,
  useful for the reaper/doctor to diagnose "you own a stale lane"). ✓

### Why it exists / who consumes it
- It does NOT call `pool_owner_alive` — only the pid equality. So it returns a lane even when
  the owner is dead/recycled (the "stale lease owned by this PID" diagnostic).
- This is the building block for the **reaper's self-reap path** and `doctor` reconciliation:
  "find any lane whose lease names me, regardless of liveness". PRD §2.10 (lazy reaper) and
  §2.14 (failure modes) both need to surface stale-but-mine leases. (find_mine itself is
  consumed by the wrapper lifecycle step 2, M6.T3.S1; find_mine_any by the diagnostic/admin
  path, M7.T4 doctor and potentially M5 reap.)
- First-match semantics (return immediately on the first pid-match). The §2.8 invariant
  guarantees ≤1 such lane, so first-match == only-match in correct operation. If a violation
  exists, returning the first is still a safe, deterministic choice.

---

## 4. Naming, placement, scope

- **Naming** (item-mandated, exact): `pool_lanes_list`, `pool_lease_find_mine`,
  `pool_lease_find_mine_any`. `pool_lanes_list` breaks the strict `pool_lease_*` subdomain
  (it enumerates lane NUMBERS, not lease records) — it lives in the broader lane/query
  family alongside the future `pool_lane_*` lifecycle functions (key_findings naming table).
  The two `find_mine*` functions are `pool_lease_*` (lease queries).
- **Placement**: append at EOF of `lib/pool.sh`, in the "Lease management" section (S1/S2
  added it; the readers are the last functions at line ~960). A short banner comment groups
  them as the "Lease query operations (P1.M3.T2.S1)" sub-section. Order: `pool_lanes_list`
  first (the other two call it), then `pool_lease_find_mine`, then `pool_lease_find_mine_any`.
- **No edits** to any existing function. **No new globals, env vars, files, or external
  deps.** Composes: `pool_lanes_list`, `pool_lease_field` (S2), `pool_owner_alive` (M2.T2.S1),
  and reads `POOL_OWNER_PID` + `POOL_LANES_DIR` (frozen by `pool_config_init`).
- **Preconditions**: `pool_config_init` (freezes `POOL_LANES_DIR`) + `pool_owner_resolve`
  (sets `POOL_OWNER_PID`) must have run. Callers (the wrapper) run both at startup.

### Scope guard (do NOT do in this task)
- ❌ `find_free_lane()` (lowest free N) — that is P1.M3.T2.S2 (uses `pool_lease_exists`).
- ❌ `is_lane_stale(lane)` — that is P1.M3.T2.S3 (uses `pool_owner_alive` + last_seen_at).
- ❌ acquire / release / reap / flock orchestration (M5.*).
- ❌ the wrapper lifecycle wiring (M6.T3.S1 consumes find_mine; do not build the wrapper here).
- ❌ deleting / mutating leases (S1 owns write; M5.T2 owns teardown).
