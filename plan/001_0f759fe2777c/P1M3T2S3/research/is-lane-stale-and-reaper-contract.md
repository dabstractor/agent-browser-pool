# Research — P1.M3.T2.S3: `pool_lane_is_stale(lane)` — staleness detection for the reaper

Host-verified 2026-07-12 against the real `lib/pool.sh` (now 1109 lines: M1, M2.\*,
M3.T1.\*, M3.T2.S1, and M3.T2.S2 `pool_find_free_lane` @line 1101 all LANDED).

---

## §0 — The contract (verbatim from the work item)

```
pool_lane_is_stale(lane):
  a. Read lease for lane N. If no lease → return 2 (not stale; caller skips).
  b. Extract owner.pid, owner.comm, owner.starttime from lease.
  c. Call pool_owner_alive(pid, starttime, comm). If returns 1 → stale (return 0).
  d. If owner is alive → not stale (return 1).

OUTPUT: 0 = stale (reap), 1 = live, 2 = no lease.
INPUT:  lane N. Uses pool_lease_read and pool_owner_alive.
DOCS:   none — internal function.
```

---

## §1 — The tri-state return code: INVERTED from `pool_owner_alive` (the #1 gotcha)

`pool_owner_alive` returns **0 = alive**, **1 = dead/recycled**. `pool_lane_is_stale`
**INVERTS** this: it returns **0 = stale**, **1 = live**. The mapping is explicit in
the contract (c: pool_owner_alive→1 ⟹ is_stale→0; d: alive ⟹ is_stale→1).

Why the inversion? Because the natural reaper idiom is:

```bash
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then   # rc 0 (stale) == "true" → reap
        pool_release_lane "$n"
    fi
done
```

A shell command "succeeding" (rc 0) IS the "yes/true" answer to the predicate's question
("is this lane stale?"). So `if pool_lane_is_stale; then reap` reads like English and
matches shell convention. rc 1 (live) and rc 2 (no lease) are both "not stale" → the
`else` / fall-through skips them.

| situation                                  | pool_owner_alive | pool_lane_is_stale | caller action     |
|--------------------------------------------|------------------|--------------------|-------------------|
| live owner, comm+starttime match           | 0 (alive)        | **1 (live)**       | keep lane         |
| owner pid dead                             | 1 (dead)         | **0 (stale)**      | **reap**          |
| owner pid recycled into non-pi (comm≠pi)   | 1                | **0 (stale)**      | **reap**          |
| owner pid recycled into new pi (st mismatch)| 1               | **0 (stale)**      | **reap**          |
| no lease file (lane unleased)              | (not called)     | **2 (no lease)**   | skip              |
| corrupt lease file                         | (not called)     | **2 (skip)**       | skip (logged)     |

This tri-state is the **defining** fact of this function. Implementers MUST NOT return
0/1 only; the `2` ("no lease, skip") path is what keeps the reaper from pool_die-ing /
aborting when it scans a lane that was claimed-then-released or never existed.

---

## §2 — The caller-side `set -e` hazard (host-verified)

This function returns **non-zero for the common cases** (live = 1, no-lease = 2).
Under `set -euo pipefail` (propagated into every caller by `lib/pool.sh` line 14), a
**bare** `pool_lane_is_stale "$n"` whose rc is 1 or 2 **ABORTS the caller script**.

Host-verified (this session):

```bash
set -euo pipefail; source lib/pool.sh; ...
echo "before bare call"
pool_lane_is_stale 1      # lane is live → rc 1 → SCRIPT ABORTS HERE
echo "AFTER bare call"     # NEVER PRINTS
```

Result: only "before bare call" printed; the second echo never ran. **Confirmed.**

Therefore the caller MUST use one of these set -e-safe idioms (all host-verified):

```bash
# (A) the reaper's natural form — rc 0 (stale) → reap; rc 1/2 → skip (if is errexit-exempt)
if pool_lane_is_stale "$n"; then
    pool_release_lane "$n"
fi

# (B) capture all three codes explicitly (the `|| rc=$?` list is errexit-exempt)
pool_lane_is_stale "$n" && rc=0 || rc=$?
case "$rc" in 0) reap;; 1) keep;; 2) skip;; esac

# (C) inside a loop, branch on the captured code (the else branch captures rc)
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then echo "reap $n"; else rc=$?; echo "skip $n (rc=$rc)"; fi
done
```

This is the SAME hazard family as `pool_lease_read` / `pool_lease_find_mine`
(M3.T1.S2 / M3.T2.S1 PRPs document it). It must be in the PRP's gotchas + the function's
leading comment so the M5.T3.S1 (reap_stale) + M5.T1.S1 (acquire step 3a) implementers
do not write a bare call and watch the reaper abort on the first live lane.

**The host-verified proof of idiom (C):**
```
lane 1: not-stale (rc=1)        # live
lane 2: not-stale (rc=2)        # no lease
lane 3: not-stale (rc=2)        # no lease
loop completed OK               # no abort — proves the if/else guard is set -e safe
```

---

## §3 — Composition: WHY `pool_lease_read` + ONE jq fork, NOT `pool_lease_field` ×3

The contract literally says **"Uses pool_lease_read and pool_owner_alive."** It does
NOT name `pool_lease_field`. There are two faithful ways to "extract owner.{pid,comm,
starttime} from the lease":

| approach                                | disk reads | jq forks | faithful to contract? |
|-----------------------------------------|------------|----------|-----------------------|
| `pool_lease_read` once → jq ×3 lines    | 1          | 1        | ✅ YES (named fn)     |
| `pool_lease_field` ×3 (owner.pid/…)     | 3          | 3        | ⚠ uses a non-named fn |
| `pool_lease_read` once → 3 `jq -r`      | 1          | 3        | ✅ yes, more forks    |

We pick **`pool_lease_read` once → one `jq -r '.owner.pid, .owner.starttime, .owner.comm'`**
captured via `mapfile -t` (bash ≥4.0 builtin; the host runs bash 5.x). This is the
cheapest faithful form: **1 disk read, 1 jq fork**, and it uses the contract-named
function.

The exact host-verified extraction:
```bash
local -a _o
mapfile -t _o < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")
pid="${_o[0]:-}"; starttime="${_o[1]:-}"; comm="${_o[2]:-}"
```

- `jq -r '.owner.pid, .owner.starttime, .owner.comm'` produces **exactly 3 lines** for any
  valid JSON object (one per comma-separated expression), even when `.owner` is missing
  (each line is then the literal `null`). `pool_lease_read` has already guaranteed the
  JSON is valid (`_pool_json_valid` passed), so jq **cannot** fail here — no TOCTOU
  (jq reads the in-memory `$json` herestring, not the file).
- `mapfile -t` strips the trailing newlines → exactly 3 array elements. The `${_o[k]:-}`
  defaults defend a (theoretically impossible) short read.
- The herestring `<<<"$json"` is a bash redirect — **no `printf` fork** (cleaner than a
  pipeline). Host-verified equivalent to the `printf | jq` form.

---

## §4 — "No lease" (rc 2) covers BOTH missing AND corrupt (host-verified)

`pool_lease_read` returns **1** for **both** "file missing" AND "file exists but invalid
JSON" (it `_pool_log`s a single `corrupt lease` warning on the corrupt branch). The
contract's step (a) is "If no lease → return 2" and names `pool_lease_read` as the read
primitive. Therefore **both** return-1 outcomes map to **rc 2 (skip)**.

This is correct and safe:
- **Missing** = the lane is simply unleased → skip (the caller, e.g. reap_stale, has
  nothing to tear down). ✅
- **Corrupt** = a half-written lease (rare under S1's atomic `_pool_atomic_write`; only
  a crash *before* the `mv` could leave one). We **cannot** read its owner → we cannot
  know which chrome_pgid to kill. Reaping it blind (rc 0) would `rm -rf` an ephemeral
  dir whose Chrome we can't identify/stop. **Skipping (rc 2)** is the conservative
  choice — `doctor` (M7.T4.S1) does full reconciliation and handles corrupt leases
  explicitly. The `_pool_log` warning from `pool_lease_read` already flagged it.

Host-verified: a corrupt lane (`printf 'NOT JSON{' > lanes/6.json`) → `pool_lane_is_stale 6`
returns **2**, and the log contains `corrupt lease`. ✅

(The alternative — treating corrupt as stale/rc 0 — is rejected because reap without a
known pgid is unsafe. The contract's "If no lease → return 2" plus pool_lease_read's
unified rc-1 cleanly encode the safe behavior.)

---

## §5 — Missing/garbled owner FIELDS → stale (rc 0), NOT skip (host-verified)

A lease that is **valid JSON** but has a **missing/empty owner sub-object** (e.g.
`{"version":1,"lane":7,"port":0,"chrome_pid":0,"connected":false}` with NO `owner`)
is a degenerate but parseable lease. The contract's step (b) "extract owner fields" then
yields `null`/empty for pid/starttime/comm. Handing those to `pool_owner_alive`:

- `pid="null"` (or `""`) → `[[ "null" =~ ^[0-9]+$ ]]` is **false** → pool_owner_alive
  returns **1** (not verifiably alive) → `pool_lane_is_stale` returns **0 (stale)**.

This is the **safe** outcome: a lease whose owner cannot be verified is reaped on the
next acquire (idempotent reaper), rather than held forever (resource leak) or trusted
(lane theft). Host-verified: a hand-crafted no-owner lease → rc 0 (stale). ✅

No special-case branch is needed — `pool_owner_alive`'s own input validation
(non-numeric pid → return 1) handles it, exactly as M2.T2.S1's PRP predicted
("empty expected_starttime → safe-stale; the normal mismatch path handles it").

---

## §6 — Naming & placement

**Name: `pool_lane_is_stale`** — the contract body literally says
*"Implement `pool_lane_is_stale(lane)`"*. The work-item *title* shortens it to
`is_lane_stale`, but the CONTRACT (the authoritative spec) uses `pool_lane_is_stale`.
Honor the contract verbatim. key_findings' "Function Naming Convention" reserves
`pool_lane_*` for the lane-lifecycle/query subdomain — this function (a per-lane
staleness verdict) fits that bucket precisely. The M5.T3.S1 (reap_stale) and
M5.T1.S1 (acquire step 3a) consumers reference this exact name.

**Placement**: append at EOF (line 1109, directly after `pool_find_free_lane`'s closing
brace at ~1108), under a new banner:
```
# =============================================================================
# Lease management — query operations (P1.M3.T2.S3)
# =============================================================================
```
This mirrors the banner style of S1 (`(P1.M3.T2.S1)`) and S2 (`(P1.M3.T2.S2)`). Pure
append; no existing function is touched.

---

## §7 — Non-fatal / read-only (the predicate contract)

`pool_lane_is_stale` follows the **read-side predicate convention** established by
`_pool_json_valid`, `pool_owner_alive`, `pool_lease_read`, `pool_lease_field`,
`pool_lease_exists`, `pool_lease_find_mine` (all M2.T2.S1 / M3.T1.S2 / M3.T2.S1):
- **NEVER** calls `pool_die`. (A stale/missing lane is a normal scan result, not a bug.)
- **NEVER** writes to disk, kills a process, or deletes a file. (Read-only verdict; the
  CALLER — reap_stale / release — does the teardown based on the verdict.)
- The ONLY possible side effect is **one `_pool_log` line** — and only transitively,
  via `pool_lease_read` on a corrupt lease (§4). is_lane_stale itself does not log
  (it runs in the reaper scan loop; per-lane logging would flood the pool log). The
  caller logs the DECISION ("reaping lane N: owner pid dead").

---

## §8 — Host-verified prototype results (this session, real `lib/pool.sh`)

Prototype of the exact function body (the verbatim-ready form in the PRP) run against
the real library + real `pool_lease_write` to seed leases:

| lane | setup                                  | expected rc | got | result |
|------|----------------------------------------|-------------|-----|--------|
| 1    | live owner = `$$` (self), correct comm+st | 1 (live) | 1   | ✅ OK  |
| 2    | dead owner pid (999999999)             | 0 (stale)   | 0   | ✅ OK  |
| 3    | live pid, WRONG starttime (recycled)   | 0 (stale)   | 0   | ✅ OK  |
| 4    | live pid, WRONG comm (recycled non-pi) | 0 (stale)   | 0   | ✅ OK  |
| 5    | no lease file                          | 2 (no lease)| 2   | ✅ OK  |
| 6    | corrupt lease (`NOT JSON{`)            | 2 (skip)    | 2   | ✅ OK  (+1 log line) |
| 7    | valid JSON, NO owner object            | 0 (stale)   | 0   | ✅ OK  |
| "../etc" | non-numeric lane (path-traversal)  | 2 (skip)    | 2   | ✅ OK  |

**ALL PASS.** The exact body in the PRP's Implementation Blueprint is the one tested.

Plus the §2 set -e hazard test (bare call aborts; if/else guard survives) and the §3
herestring-vs-printf equivalence — all host-verified.

---

## §9 — Caller contract (for M5.T3.S1 reap_stale + M5.T1.S1 acquire step 3a)

The reaper scan is the canonical consumer:
```bash
pool_reap_stale() {
    local n rc
    for n in $(pool_lanes_list); do
        # if-guard: rc 0 (stale) → reap; rc 1 (live) / rc 2 (no lease) → skip.
        # the `if` makes this set -e SAFE (a bare call would abort on rc 1/2 — §2).
        if pool_lane_is_stale "$n"; then
            _pool_log "reap_stale: reaping stale lane $n"
            pool_release_lane "$n"   # M5.T2.S1: kill pgroup + rm dir + delete lease
        fi
    done
}
```
And the acquire critical-section step 3a (M5.T1.S1) reuses the same `if pool_lane_is_stale`
form inside its `flock` (it reaps stale lanes before `pool_find_free_lane` at step 3c —
note reap_stale MUST run before find_free_lane so the freed lane numbers are reusable).

Boundary: `pool_lane_is_stale` is the **verdict** only. The **teardown** (kill pgroup,
`rm -rf` ephemeral dir, delete lease) is `pool_release_lane` (M5.T2.S1) — out of scope
for this task. This task answers "stale?"; it does not act on the answer.

---

## §10 — Scope guard (do NOT build these here)

- NO teardown: kill / `rm -rf` / lease delete → `pool_release_lane` (M5.T2.S1).
- NO full-reaper loop / orphan-reuse / exhaustion → M5.T3.\*, M5.T4.\*.
- NO acquire flock / choose-N → M5.T1.S1 (this function is CALLED BY step 3a, not the reverse).
- NO owner resolution (the lease already stores owner.{pid,comm,starttime}).
- NO schema-completeness validator (a lease with a missing owner → stale via §5, not an error).
- NO new globals / env vars / files / external deps. Pure append of one function.
