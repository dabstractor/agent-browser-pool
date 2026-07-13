# Research — `pool_find_free_port()` (P1.M4.T2.S1)

Host-verified brief for the **lowest-free-TCP-port** primitive. Every claim below was
executed on this host (2026-07-12) against the real `lib/pool.sh` (M1–M4.T1 landed).

---

## §0. Results table — prototype run against the real library

Prototype `pool_find_free_port` sourced on top of `lib/pool.sh` under `set -euo pipefail`,
`POOL_PORT_BASE=53420 POOL_PORT_RANGE=1000`, throwaway state/ephemeral dirs.

| # | Scenario | Fixtures | Expected | Got | Result |
|---|----------|----------|----------|-----|--------|
| 1 | empty lanes dir | none | 53420 (lowest, free) | 53420 | **PASS** |
| 2 | lease claims 53420 + provisional lease port=0 | lane1 port=53420; lane2 **port=0** | 53421 (provisional ignored) | 53421 | **PASS** |
| 3 | non-CDP OS listener on 53421 (python 404) | (lower ports free) | lowest free = 53420 | 53420 | PASS (lowest-first confirmed) |
| 3b | ss listener on 53421, **53420 NOT occupied** | listener 53421 | 53420 (still lowest free) | 53420 | PASS |
| 4 | CDP-like responder on 53422 (200 `{}`) | responder 53422 | lowest free = 53420 | 53420 | PASS |
| **5** | **full skip-chain**: lease→ss→curl→free | lease 53420 + listener 53421 + responder 53422 | **53423** | **53423** | **PASS** |
| 6 | range exhaustion (RANGE=1, claim the only port) | RANGE=1, lane1 port=53420 | **rc 1** (no echo) | rc 1 | **PASS** |

**Conclusion**: the three-stage skip (claimed → ss listener → curl CDP responder) + lowest-first
iteration + rc-1 exhaustion are all host-correct.

---

## §1. The `ss` regex `:$port ` — word boundary via trailing space (HOST-VERIFIED)

`ss -tlnH` lines look like `LISTEN 0 128 127.0.0.1:631 0.0.0.0:*` (local addr, space, peer addr).
The grep `:$port ` (colon, port digits, **trailing space**) anchors the port to the END of the
local-address field, so it cannot false-match a longer port or an IP octet.

```
$ ss -tlnH
LISTEN 0 128          0.0.0.0:22    0.0.0.0:*      # ssh
LISTEN 0 511        127.0.0.1:17318  0.0.0.0:*
LISTEN 0 4096         0.0.0.0:5432   0.0.0.0:*      # postgres
LISTEN 0 ...          [::]:9222      ...:*          # Brave (IPv6 form)

$ grep -q ':22 '  <<<"$L"  → MATCH   (port 22)
$ grep -q ':222 ' <<<"$L"  → no      (does NOT false-match :22)
$ grep -q ':9222 '<<<"$L"  → MATCH   (Brave, IPv6 — still has ':9222 ')
$ grep -q ':53420 '<<<"$L" → no      (free)
```

- **The trailing space is the disambiguator.** `:5342` would match `53420`'s line; `:5342 `
  (space) does not. The space is ALWAYS present (it separates local-addr from peer-addr).
- **IPv6-safe**: `[::]:9222` still contains the substring `:9222 ` → matches.
- Port is numeric (validated uint), so **no regex metacharacters** — plain `grep -q` (literal)
  is fine; no need for `grep -qE` or `grep -F -w`.
- This is the EXACT regex in the item contract (`ss -tlnH | grep -q ":$port "`).

---

## §2. Capture `ss` ONCE, grep the captured text per-port (not `ss` per-port)

The contract writes `ss -tlnH | grep -q ":$port "` *inside* the per-port loop. A literal
implementation would fork `ss` (a **netlink** syscall — slower than a grep fork) up to
RANGE=1000 times. We instead **capture `ss -tlnH` once** before the loop into `$listeners`
and `grep -q ":$port " <<<"$listeners"` per candidate.

- This mirrors `pool_lane_is_stale`'s explicit "ONE jq fork" principle (read the expensive
  resource once, reuse the in-memory snapshot).
- Same regex, same semantics — one netlink call instead of up to 1000. Grep forks only for
  candidates that pass the (instant, in-memory) claimed-set check, and only until the first
  free port (typically 1–4 greps in practice).
- The `ss` snapshot is deliberately a little stale (taken once); the per-port **curl** is the
  live check that closes the race window (§5).

`listeners="$(ss -tlnH 2>/dev/null || true)"` — `|| true` so a transient ss failure (missing
binary, permission) degrades gracefully to an empty snapshot (curl still guards).

---

## §3. The claimed-port set — `local -A claimed` (first assoc array in the codebase)

Lane count is tiny (≈ concurrent agents), but membership must be **O(1) and fork-free** inside
the loop (up to 1000 iterations in the degenerate full-range case). A bash **associative
array** is the idiomatic "set":

```bash
local -A claimed=()
for n in $(pool_lanes_list); do
    p="$(pool_lease_field "$n" port 2>/dev/null)" || continue
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && claimed["$p"]=1
done
# …loop…
[[ -z "${claimed[$port]:-}" ]] || continue     # fork-free membership test
```

- **`local -A` works** at runtime on this host (verified). The shebang is
  `#!/usr/bin/env bash`; the library already requires bash 4.2+ (`mapfile`, `declare -g`),
  and associative arrays are bash 4+ → safe.
- **shellcheck-clean** for the assoc-array usage (the whole `lib/pool.sh` currently passes
  `shellcheck` clean; the prototype passed too — the lone SC2034 in a stripped test was an
  artifact of an unused loop var, not the assoc array).
- **`-gt 0` filter is MANDATORY (GOTCHA):** provisional claims write `port=0` (PRD §2.4 step
  3d; lease-schema research: "placeholder `0` during provisional claim"). `pool_lease_field`
  echoes `0` for those → must NOT enter the claimed set (0 is the "not yet assigned" sentinel
  and is never in [BASE, BASE+RANGE) anyway). Also filters `null` (missing field) and any
  non-numeric garbage via the `=~ ^[0-9]+$` test.
- **Composes the LANDED readers**, does not re-implement: `pool_lanes_list` (M3.T2.S1) +
  `pool_lease_field` (M3.T1.S2) — exactly `pool_lease_find_mine`'s enumeration pattern.
  Corrupt/missing leases return 1 from `pool_lease_field` → `|| continue` keeps the scan alive.

---

## §4. The `curl` double-check — `curl -sf --max-time 2 http://127.0.0.1:$port/json/version`

Order per contract: claimed → **ss listener** → **curl CDP responder**.

- For a port with **no `ss` listener**, `curl` to it gets **connection-refused (rc 7) instantly**
  (HOST-VERIFIED: `curl -sf --max-time 1 http://127.0.0.1:59999/json/version` → rc 7, instant).
  So in the common case the curl adds **zero latency** for genuinely free ports.
- `--max-time 2` is a **defensive** addition (the contract shows bare `curl -sf`). It bounds
  the worst case where a port is filtered (firewall DROP, not REJECT) — a hung SYN could
  otherwise stall the loop for the kernel's TCP timeout (~minutes). Connection-refused never
  hits the timeout. This does NOT change the contract's semantics.
- `-f` (fail on HTTP ≥400) means a non-CDP listener that returns 404 → curl exits 22 → NOT
  "responds" → the **ss check already skipped it** (a 404 responder IS listening → ss caught
  it first). The curl only runs for ports ss reports free, so its job is the narrow "CDP
  endpoint that appeared after the ss snapshot / ss somehow missed" case → it's the live race
  guard. Verified: a python 200-`{}` responder on a pool port → curl exits 0 → port skipped
  (scenario 5).
- `/json/version` is the **canonical Chrome DevTools Protocol** liveness endpoint (PRD §2.4
  step 3h + §2.6; external_deps §2.2). Reusing it here keeps the probe identical to the
  launch-readiness wait (M4.T2.S2) and the connect step (M4.T3.S1).

---

## §5. TOCTOU + "outside the flock" (FINDING 2) — best-effort is the contract

key_findings FINDING 2: the flock critical section is kept SHORT — the **provisional claim**
(`port=0`) is written under flock (M5.T1.S1), then the lock is RELEASED and the **post-lock
boot** (copy → **find_free_port** → launch → connect → update lease) runs concurrently across
agents (M5.T1.S2).

Consequences for THIS function:
- It runs **OUTSIDE the flock**. Two concurrent acquires can race: both read the leases, both
  see port 53420 free, both return 53420. **This is tolerated** — the **launch** (M4.T2.S2,
  `--remote-debugging-port=<port>`) is the authoritative bind; if it hits `EADDRINUSE` the
  caller (M5.T1.S2) retries with a new port. The contract says "First port that passes all
  checks → echo it, return 0" — i.e. **best-effort selection**, not a reservation.
- The per-port `curl` is the in-loop live check that narrows (but cannot eliminate) the race
  against the stale `ss` snapshot.
- Provisional leases (`port=0`) in the claimed set do NOT reserve a port (§3), which is
  correct: a lane that has claimed a *lane number* but not yet bound a port should not block
  port selection.

---

## §6. Exhaustion → return 1 (NOT pool_die) + the set -e caller hazard

Contract step 3c: "If none free → return 1 (should be extremely rare with 1000 ports)." So
`pool_find_free_port` is **non-fatal** — it returns 1 on exhaustion, it does NOT `pool_die`.
This places it in the same family as `pool_lease_read` / `pool_lease_find_mine` (M3): a query
that signals "no result" via rc 1.

**GOTCHA (caller under `set -e`):** a BARE `port="$(pool_find_free_port)"` whose rc is 1
(exhausted) **ABORTs the caller** (the `$(…)` returns 1 → errexit fires). The caller
(M5.T1.S2) MUST guard:
```bash
if port="$(pool_find_free_port)"; then
    # launch on $port …
else
    # exhaustion path (M5.T4 block-with-timeout + force-reap + alert)
fi
```
This is the SAME hazard family documented in `pool_lease_read` (S2) and
`pool_lease_find_mine`/`pool_lane_is_stale` (S3) — the PRP must state it explicitly.

---

## §7. Naming, placement, banner, scope

- **Name: `pool_find_free_port`** — contract-mandated ("Implement `pool_find_free_port()`").
  Consistent with the lane analog `pool_find_free_lane` (M3.T2.S2). The item title abbreviates
  it `find_free_port()`; the contract body + consumer (M5.T1.S2) use the `pool_` prefix.
  Do NOT rename.
- **Placement: APPEND after `pool_copy_master`** (the P1.M4.T1.S1 deliverable — current EOF,
  line 1312; verified `pool_copy_master() {` @ line 1253). Do NOT touch any existing function.
- **Banner:** a new
  `# Lane lifecycle — port allocation (P1.M4.T2.S1)` banner, same style as the M3/M4.T1
  banners (`# ====…` + `# <group> — <subtask>` + `# ====…`).
- **Scope:** the port-SELECTION primitive ONLY. Do NOT: launch Chrome (M4.T2.S2); wait for CDP
  readiness (M4.T2.S2); connect the daemon (M4.T3); the flock/claim (M5.T1.S1); or the
  post-lock-boot orchestration (M5.T1.S2). This function is a pure read-only query that echoes
  one number.
- **No new globals / env vars / files.** Reads `POOL_PORT_BASE`, `POOL_PORT_RANGE` (frozen by
  `pool_config_init`, M1.T1.S2) and `POOL_LANES_DIR` (via `pool_lanes_list` / `pool_lease_field`).
  Writes nothing.

---

## §8. The host-verified function body (paste-ready)

```bash
pool_find_free_port() {
    local port p n listeners
    local -A claimed=()

    # (a) Build the set of ports already claimed by live leases. Compose the LANDED
    #     readers (pool_lanes_list M3.T2.S1 + pool_lease_field M3.T1.S2) — same enumeration
    #     pattern as pool_lease_find_mine. Skip port<=0 / non-numeric: a PROVISIONAL claim
    #     writes port=0 (PRD §2.4 step 3d) and must NOT reserve a port.
    for n in $(pool_lanes_list); do
        p="$(pool_lease_field "$n" port 2>/dev/null)" || continue
        [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && claimed["$p"]=1
    done

    # Snapshot the listening sockets ONCE (netlink is more expensive than a grep fork;
    # mirrors pool_lane_is_stale's "ONE jq fork" principle). The per-port curl (below) is the
    # live check that closes the race against this snapshot. `|| true` degrades gracefully.
    listeners="$(ss -tlnH 2>/dev/null || true)"

    # (b) Lowest free port in [BASE, BASE+RANGE): skip claimed, skip OS-listening, skip any
    #     port answering the CDP liveness probe (a non-pool Chrome). First that passes → echo.
    for (( port = POOL_PORT_BASE; port < POOL_PORT_BASE + POOL_PORT_RANGE; port++ )); do
        [[ -z "${claimed[$port]:-}" ]] || continue              # lease-claimed
        grep -q ":$port " <<<"$listeners" && continue           # OS listener (word boundary)
        if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            continue                                             # live CDP endpoint (non-pool Chrome)
        fi
        printf '%s\n' "$port"
        return 0
    done

    # (c) Exhausted — extremely rare with 1000 ports. Non-fatal: rc 1 (caller handles).
    return 1
}
```

All six prototype scenarios (§0) + `bash -n` + `shellcheck` (assoc-array form) PASS against
this body on this host.
