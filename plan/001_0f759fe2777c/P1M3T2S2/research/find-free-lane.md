# Research — P1.M3.T2.S2: `pool_find_free_lane()` (lowest free lane number)

Date: 2026-07-12
Status: **Host-verified** (prototype run on this machine, all 4 scenarios passed).

---

## 0. The contract (verbatim from the work item)

> PRD §2.4 step 3c: "lowest N≥1 with no active/<N> dir and no lanes/<N>.json lease".
> Lanes are unbounded — created on demand.
>
> INPUT: `POOL_EPHEMERAL_ROOT` and `POOL_LANES_DIR` globals.
> LOGIC: `pool_find_free_lane()`:
>   a. Start N=1, increment.
>   b. For each N: check if `$POOL_EPHEMERAL_ROOT/<N>` dir exists OR `$POOL_LANES_DIR/<N>.json` exists.
>   c. First N where neither exists → echo N and return 0.
>   d. This is called under flock so it's race-free within the critical section.
> OUTPUT: Echoes the lowest free lane number N. Consumed by acquire step 3c (M5.T1.S1).
> DOCS: none — internal function.

So the function is a **pure probe**: walk N=1,2,3,… and return the first N where BOTH the
ephemeral dir is absent AND the lease file is absent. No enumeration of existing lanes, no
locking (the caller holds flock), no mutation.

---

## 1. The algorithm — host-verified prototype (all 4 scenarios passed)

Exact body, run under `set -euo pipefail` against a temp tree on 2026-07-12:

```bash
pool_find_free_lane() {
    local n
    for (( n = 1; ; n++ )); do
        if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    done
}
```

Results (captured verbatim from the prototype run):

| Scenario | Seeded state | Expected | Got |
|---|---|---|---|
| A — contiguous occupied | lane1 dir+lease, lane2 dir-only, lane3 lease-only, lane4 free | `4` | `4` ✅ |
| B — empty pool | no dirs, no leases (roots exist, empty) | `1` | `1` ✅ |
| C — gap | lane1 dir, lane3 dir+lease, lane2 free | `2` | `2` ✅ |
| D — roots don't exist | `POOL_EPHEMERAL_ROOT` & `POOL_LANES_DIR` not created yet | `1` | `1` ✅ |

Scenario D is important: when `POOL_EPHEMERAL_ROOT` does not exist, `[[ -d "$POOL_EPHEMERAL_ROOT/1" ]]`
is simply false (a non-existent parent ⇒ the child path is not a dir), so N=1 is free.
`pool_find_free_lane` therefore works **before** the ephemeral root has ever been created.

---

## 2. Why `for (( n=1; ; n++ ))` and NOT a `seq`/`while`-with-cap — set -e safety

The lanes are **unbounded** (PRD §2.4: "created on demand"). There is no fixed `MAX_LANES`.
So the natural shape is an open-ended increment from 1.

* `for (( n=1; ; n++ ))` — the empty condition (middle of the three) is bash's canonical
  "loop forever" idiom. **The condition slot of a C-style for-loop is NOT a statement** —
  it is evaluated arithmetically and its truthiness gates the loop body, so `errexit` (set -e)
  never fires on it. Verified in the prototype: ran under `set -euo pipefail`, no abort.
  This is the cleanest match for "lowest N≥1, increment".

* A `while :; do (( n++ )); ...` would need `n=$((n+1))` (the `$(( ))` EXPANSION form is
  always set -e safe) because a bare `(( n++ ))` STATEMENT returns exit 1 when n was 0
  (pre-increment 0) and would abort under set -e on the first iteration (see `_pool_age_str`
  in lib/pool.sh, which documents this exact trap). The `for (( ))` form sidesteps it entirely.

* Why NOT a hard upper cap (e.g. `for ((n=1; n<=99999; n++))`): the literal contract is
  "lowest N≥1, increment" with no cap, and **reap-stale (PRD §2.4 step 3a) runs BEFORE
  choose-N (step 3c)** in the acquire critical section. After reaping, the count of
  occupied lanes == the count of LIVE agents, which is bounded by reality (you don't have
  a million concurrent pi agents). So the loop always terminates at ≈ (live-agent-count + 1).
  Pool **exhaustion** (PRD §2.9) is a separate concern owned by M5.T4 (block-with-timeout +
  force-reap + alert), and the whole acquire critical section is externally bounded by that
  timeout. A cap here would be redundant defensive code that silently changes the contract
  (returning non-zero on "too many lanes" instead of just finding the next N). **Keep it
  unbounded per the contract.**

---

## 3. Why `[[ -f "$LDIR/$n.json" ]]` and NOT `pool_lease_exists "$n"` — corrupt-file safety

Both could express "is lane N's lease present". The choice matters for a corrupt lease file
(`printf 'NOT JSON{' > lanes/5.json`, e.g. a crash mid-write — rare under S1's atomic writes,
but the contract must be defensive):

| Check | Corrupt lease file → | Risk |
|---|---|---|
| `[[ -f lanes/5.json ]]` | **occupied** (file present) | skips lane 5 (safe — never double-allocates) |
| `pool_lease_exists 5` | **free** (returns 1 on invalid JSON — S2 contract) | would pick lane 5, overwriting a corrupt file; **if a live Chrome still owns lane 5 (reap skipped it because it couldn't read owner.pid), this is a COLLISION** |

`[[ -f ]]` is also **cheaper** (no `jq` fork) and find_free_lane runs inside the flock
critical section on the acquire hot path (every non-reuse `agent-browser` call). And the
ephemeral-dir check (`[[ -d active/$n ]]`) independently catches the "live Chrome, dir
present" case regardless of lease state. **Use `[[ -f ]]`.** (The contract literally says
"$POOL_LANES_DIR/<N>.json exists" — a plain file-existence test — so `[[ -f ]]` is also the
faithful reading.)

Note: pool_lease_exists IS still listed in S2's PRP §"CONSUMERS" as a *future* consumer of
find_free_lane is NOT the case — find_free_lane does NOT call pool_lease_exists; the
relationship is reversed (both are leaf query helpers; they are siblings, not
parent/child). find_free_lane depends only on the frozen globals.

---

## 4. Relationship to the sibling S1 (pool_lanes_list / find_mine) — INDEPENDENT

S1 (P1.M3.T2.S1) landed three functions: `pool_lanes_list` (enumerate existing numeric lane
stems), `pool_lease_find_mine`, `pool_lease_find_mine_any`. Verified present in lib/pool.sh:
`pool_lanes_list` at line 967, `pool_lease_find_mine` at 1003, `pool_lease_find_mine_any`
at 1042. File is now 1053 lines.

`pool_find_free_lane` does **NOT** call any of S1's functions. The algorithms are different:
- `pool_lanes_list` ENUMERATES the lanes that exist (glob + sort -n).
- `pool_find_free_lane` PROBES N=1,2,3,… until it finds a free slot (no glob, no sort).

This is important for the parallel build: S2 has **zero dependency on S1's output**.
find_free_lane only reads the frozen globals `POOL_EPHEMERAL_ROOT` / `POOL_LANES_DIR`
(M1.T1.S2, LANDED). If S1 had not landed yet, S2 would still build and test correctly.

The two functions are complementary: in the acquire critical section the caller first runs
`pool_lease_find_mine` (do I already own a lane?) and, only on "no", runs `pool_find_free_lane`
(pick a new one). They never both pick the same lane for the same owner because find_mine
short-circuits first (PRD §2.4 step 2 → step 3).

---

## 5. "Called under flock" — caller's responsibility, NOT this function's

The contract note (3d) says find_free_lane "is called under flock so it's race-free within
the critical section." That means **the CALLER (M5.T1.S1 acquire step 3c) holds flock on
`$POOL_LOCK_FILE`** when it invokes `pool_find_free_lane`. find_free_lane itself does NO
flocking — it has no `flock` call, no lock file. This is consistent with FINDING 2 in
key_findings.md (flock section is short: scan + reap + choose-N + provisional-claim only;
Chrome launch is AFTER the lock releases). find_free_lane is the "choose-N" step.

Implication for the function: it MUST be fast (it holds the global acquire lock). The two
`[[ -d ]]` / `[[ -f ]]` builtin tests per probe are essentially free (stat syscalls, no
forks). Even probing N=1..1000 (a pathological 1000-agent pool) is sub-millisecond. Good.

---

## 6. Naming + placement

* **Name**: `pool_find_free_lane` — item-mandated (the work item literally says
  "Implement `pool_find_free_lane()`"). NOTE the naming-table tension: key_findings.md's
  convention table lists `pool_lane_*` for lane LIFECYCLE (copy/launch/connect/teardown) and
  S1 introduced `pool_lanes_list` (plural) for enumeration. `pool_find_free_lane` is a
  lane QUERY, so it does not cleanly fit either bucket — but the work item is authoritative,
  and the consumer (M5.T1.S1) will reference this exact name. **Use `pool_find_free_lane`.**
  Do NOT "helpfully" rename to `pool_lanes_find_free` / `pool_lane_find_free` — that would
  break the contract with the acquire consumer.

* **Placement**: append at EOF of lib/pool.sh, under a new banner
  `# Lease management — query operations (P1.M3.T2.S2)` (or simply "lane allocation"),
  directly after the last existing function. As of this research, the last function is
  `pool_lease_find_mine_any()` (S1) ending at line 1053. If S1 had NOT landed, the last
  function would be `pool_lease_exists()` (M3.T1.S2) at ~line 931 — either is a valid append
  point; find_free_lane is append-only and composes nothing below it.

* **Preconditions**: `pool_config_init` must have run (it freezes the ABSOLUTE
  `POOL_EPHEMERAL_ROOT` and `POOL_LANES_DIR`). `pool_state_init` is NOT strictly required
  (scenario D proves the function works with missing dirs), but in practice the caller
  (acquire) has already run it. The function is read-only: it never `mkdir`s, never writes,
  never deletes.

---

## 7. Edge cases / contract guarantees to encode as validation

1. Empty pool (no lanes, no dirs) → echo `1`, rc 0. (scenario B)
2. Roots don't exist yet → echo `1`, rc 0. (scenario D — a fresh checkout's first acquire)
3. Lane 1 occupied (dir OR lease) → echo `2`. (scenario A)
4. Gap (1 & 3 occupied, 2 free) → echo `2` (the incrementing probe finds the lowest gap).
   (scenario C)
5. Dir-only orphan (active/2 exists, no lease) → lane 2 is NOT free (dir blocks it). This
   is correct: an orphaned ephemeral dir must not be silently reused (its Chrome may still
   be running — the dir check defends against reuse-orphan's race window).
6. Lease-only (lease exists, dir gone) → lane N is NOT free. This is the normal "lease
   claimed, dir not yet copied" window inside the flock (step 3d claim → 3e copy). Another
   concurrent acquirer under the SAME flock (serialized) must skip this N. Correct.
7. Non-numeric junk in the lanes dir (e.g. `foo.json`, a `sub.json/` subdir) does NOT
   affect find_free_lane at all — it probes N=1,2,3,… by NUMBER and ignores everything else.
   (Unlike `pool_lanes_list`, which must filter junk; find_free_lane is immune.)
8. The function ALWAYS echoes a value and returns 0 (given the unbounded loop + live-agent
   bound). It never returns 1 in normal operation. (No error path is needed — there is no
   "no free lane" state, because N can grow without limit.)

Point 8 is worth stressing: **there is no failure return code to design for.** The contract
is unconditionally "echo N, return 0". M5.T4 (exhaustion) handles "too many lanes" externally
via a timeout around the whole acquire; it does NOT rely on find_free_lane returning non-zero.

---

## 8. Caller contract (for the M5.T1.S1 acquire consumer — documented, not built here)

```bash
# Inside the flock critical section (PRD §2.4 step 3c):
(
  flock 9
  pool_reap_stale          # 3a — remove dead-owner lanes FIRST
  # 3b reuse-orphan handled elsewhere
  N="$(pool_find_free_lane)"   # 3c — lowest free lane; always echoes, always rc 0
  pool_lease_write "$N" "$POOL_EPHEMERAL_ROOT/$N" 0 "abpool-$N" \
      "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "$POOL_OWNER_STARTTIME" \
      "$POOL_OWNER_CWD" 0 0 false    # 3d — provisional claim
) 9>"$POOL_LOCK_FILE"
```

Note for the consumer: `pool_find_free_lane` always returns 0, so a bare `N="$(…)"` is
safe under set -e (unlike `pool_lease_find_mine`, which returns 1 and needs an `if` guard).
This asymmetry is fine — they have different contracts.
