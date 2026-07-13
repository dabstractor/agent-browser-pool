# PRP — P1.M4.T2.S1: `pool_find_free_port()` — lowest free TCP port in pool range

---

## Goal

**Feature Goal**: Implement the **port-selection primitive** for the agent-browser-pool — the
single function that finds the lowest free TCP port in `[BASE, BASE+RANGE)` for a freshly
claimed lane's Chrome to bind. It is the literal realization of PRD §2.4 step 3f ("PORT: lowest
free TCP port in [BASE, BASE+RANGE); probe via curl /json/version") and the item CONTRACT
(steps 3a–3c). It runs in the acquire **post-lock boot** (M5.T1.S2), **outside** the flock
critical section (key_findings FINDING 2), concurrently with other agents' boots. One function,
appended at EOF of `lib/pool.sh` under a new `# Lane lifecycle — port allocation` banner,
directly after `pool_copy_master` (the P1.M4.T1.S1 deliverable).

1. **`pool_find_free_port()`** — the literal realization of the item CONTRACT (steps 3a–3c):
   ```
   a. Build a set of ports claimed by existing leases: iterate lanes/*.json, extract .port.
   b. For port in BASE..BASE+RANGE-1:
        - Skip if claimed by any lease.          (provisional port=0 claims do NOT count)
        - Skip if port is listening: ss snapshot, grep ":$port ".   (trailing space = boundary)
        - Skip if curl /json/version responds.   (a live non-pool Chrome)
        - First port that passes all checks → echo it, return 0.
   c. If none free → return 1.                    (non-fatal; ~impossible with 1000 ports)
   ```

2. No new globals, no new env vars, no new files, no user docs ("DOCS: none — internal
   function"). Pure append of ONE function. Reads only `POOL_PORT_BASE`, `POOL_PORT_RANGE`
   (frozen by `pool_config_init`, M1.T1.S2) and `POOL_LANES_DIR` (via the LANDED readers
   `pool_lanes_list` + `pool_lease_field`). Writes nothing; never `pool_die`s.

**Deliverable**: One function (`pool_find_free_port`) appended to `lib/pool.sh` under a new
`# Lane lifecycle — port allocation (P1.M4.T2.S1)` banner, placed directly after
`pool_copy_master`'s closing brace (current EOF, line 1312 — `pool_copy_master() {` is verified
at line 1253, the P1.M4.T1.S1 deliverable now in the file). Pure addition: no edits to any
existing function, no new globals/env-vars/files. Every branch is **host-verified**
(2026-07-12) via a prototype of the exact function body sourced on top of the real library
under `set -euo pipefail` — see `research/find-free-port-host-verified.md` (all 6 scenarios
including the full claimed→ss→curl→free skip chain + exhaustion, `bash -n` + `shellcheck` —
ALL PASSED).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, with an
  empty lanes dir and nothing listening in range → `pool_find_free_port` echoes **53420** (the
  base, lowest free) and returns **0**.
- With a lease claiming port 53420 (and a provisional `port=0` lease that must be ignored) →
  echoes **53421**, returns **0**.
- With an OS listener (non-CDP) on 53421 → that port is skipped (the `ss` snapshot catches it);
  the function echoes the next free port, returns **0**.
- With a CDP-like responder (HTTP 200 on `/json/version`) on a pool port → that port is skipped
  (the `curl` check catches it); echoes the next free port, returns **0**.
- With every port in `[BASE, BASE+RANGE)` occupied (e.g. `RANGE=1` + the one port claimed) →
  echoes nothing, returns **1** (exhaustion — non-fatal).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M4.T1) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls this directly. Its sole
consumer is another function inside the post-lock boot:

- **P1.M5.T1.S2** (acquire **post-lock boot**) — the **primary** consumer. After the flock
  critical section writes the provisional claim (`port=0`) and releases the lock (key_findings
  FINDING 2), the post-lock boot does `copy → find_free_port → launch Chrome → connect →
  update lease`. `port="$(pool_find_free_port)"` is the **second** step of that boot, supplying
  the `--remote-debugging-port=<port>` the launch (M4.T2.S2) binds.

**Use Case**: Every `agent-browser` invocation that does NOT already hold a valid lease enters
the acquire flow: flock → reap-stale → choose-N → provisional claim (release flock) →
**post-lock boot**. This function is the "port" half of that boot. Without it the launch step
has no port number to bind and no way to avoid Brave's port 9222 (RESEARCH NOTE: 9222 is used
by Brave on this host — the pool deliberately uses 53420+ to avoid the collision).

**Pain Points Addressed**:
- **Chrome needs an explicit remote-debugging port.** Unlike stock `agent-browser` (which uses
  `--remote-debugging-port=0` = random port, system_context §"Note"), the pool must use a
  DETERMINISTIC, recorded port so the lease's `.port` field lets later invocations reconnect
  (PRD §2.4 step 4 "ENSURE CONNECTED" + §2.8 lease schema). This function is the single source
  of that port.
- **9222 is taken by Brave.** The RESEARCH NOTE + host check (`ss -tlnH | grep ':9222 '` →
  MATCH) confirm Brave owns 9222. Picking from a high range (53420+) and probing each candidate
  (ss + curl) guarantees the pool never collides with Brave or any other host Chrome.
- **One place that owns the three-way "free" test + the port=0 / ss-snapshot / TOCTOU
  footguns.** Centralizing selection means the only consumer (M5.T1.S2) gets a single
  best-effort port number and a clear rc contract.

## Why

- **It is the addressing step of the ephemeral-profile model.** PRD §1.2/§2.4 define the pool's
  acquire flow; step 3f ("PORT: lowest free TCP port in [BASE, BASE+RANGE)") is THIS function.
  Everything downstream (launch M4.T2.S2, connect M4.T3.S1, the lease's `.port`) operates on
  the number this function echoes.
- **The three-stage probe (claimed → ss → curl) is the collision-avoidance contract.** RESEARCH
  NOTE + PRD §2.6/§2.11: the pool coexists with arbitrary host listeners (Brave on 9222,
  postgres, ssh, …). A port is "free" only if (a) no live lease claims it, (b) nothing is
  listening on it, AND (c) no CDP-capable Chrome answers on it. Each check catches what the
  others miss (a stale ss snapshot is closed by the live curl).
- **It composes the LANDED readers, it does not re-implement them.** `pool_lanes_list`
  (M3.T2.S1) + `pool_lease_field` (M3.T1.S2) already own "enumerate lanes" and "read one
  field". Reusing them (exactly `pool_lease_find_mine`'s pattern) keeps the enumeration logic
  in one place and inherits graceful corrupt-lease handling (`|| continue`).

## What

User-visible behavior: none directly (internal library primitive). Observable contract:

| state of `[BASE, BASE+RANGE)` | `pool_find_free_port` |
|---|---|
| empty lanes dir, nothing in range listening | **echo 53420**, **rc 0** (lowest free) |
| lease claims 53420 (+ a `port=0` provisional lease present) | **echo 53421**, **rc 0** (provisional ignored) |
| OS listener (non-CDP) on a low port in range | that port skipped; **echo next free**, **rc 0** |
| CDP responder (200 on `/json/version`) on a port in range | that port skipped; **echo next free**, **rc 0** |
| every port occupied | **no output**, **rc 1** (exhausted — non-fatal) |

**Hard invariants** (every row):
- **Always returns the LOWEST free port** (iterates `BASE..BASE+RANGE-1` ascending, returns on
  first pass). Never returns a port outside `[BASE, BASE+RANGE)`.
- **Never `pool_die`s.** Exhaustion is `return 1` (non-fatal query) — same family as
  `pool_lease_read` / `pool_lease_find_mine`. The caller (M5.T1.S2) handles exhaustion via the
  pool-exhaustion flow (M5.T4).
- **Never floods stderr.** `ss` and `curl` run with stderr suppressed (`2>/dev/null` / `2>&1`);
  a transient `ss` failure degrades to an empty snapshot (curl still guards).
- **Provisional leases (`port=0`) never reserve a port.** The claimed-set builder filters
  `port > 0` + numeric (PRD §2.4 step 3d writes `port=0` as the placeholder).
- **Reads only `POOL_PORT_BASE` + `POOL_PORT_RANGE`** (frozen by `pool_config_init`) and
  `POOL_LANES_DIR` (via helpers). No new globals/env-vars/files. Writes nothing.

### Success Criteria

- [ ] `pool_find_free_port` defined in `lib/pool.sh` under a
      `# Lane lifecycle — port allocation (P1.M4.T2.S1)` banner, directly after
      `pool_copy_master`'s closing brace (current EOF, line 1312). Callable after
      `source lib/pool.sh` + `pool_config_init`.
- [ ] **empty lanes, nothing listening** → echoes **53420**, rc 0.
- [ ] **lease claims 53420 + a `port=0` provisional lease** → echoes **53421**, rc 0 (provisional
      ignored; proves the `port > 0` filter).
- [ ] **OS listener (non-CDP) on a low port** → that port skipped (ss check); echoes next free,
      rc 0.
- [ ] **CDP responder (200 `/json/version`) on a port** → that port skipped (curl check);
      echoes next free, rc 0.
- [ ] **full skip chain** (lease 53420 → ss listener 53421 → curl responder 53422) → echoes
      **53423**, rc 0.
- [ ] **exhaustion** (RANGE=1 + the one port claimed) → no output, **rc 1** (non-fatal).
- [ ] Composes `pool_lanes_list` + `pool_lease_field` (LANDED); uses `local -A claimed` for
      O(1) fork-free membership; captures `ss -tlnH` ONCE (not per-port).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.\*, M4.T1.S1) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **`ss` regex word-boundary
gotcha** (`:$port ` trailing space — host-verified, IPv4/IPv6 safe — research §1); the
**"capture ss once" optimization** vs the contract's literal in-loop `ss` (research §2); the
**`local -A claimed` decision** (first assoc array in the codebase; why O(1) fork-free
matters for a 1000-iteration loop — research §3); the **`port=0` provisional-claim filter**
(mandatory — research §3 + PRD §2.4 step 3d); the **`curl --max-time 2` defensive timeout**
(connection-refused is instant; why it's added — research §4); the **TOCTOU / outside-flock
semantics** (best-effort selection; launch is authoritative — research §5); the
**exhaustion rc-1 + set -e caller hazard** (research §6); the exact placement (after
`pool_copy_master` @ EOF line 1312); and copy-pasteable, host-verified validation commands
for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3f (PORT: "lowest free TCP port in [BASE, BASE+RANGE); probe via curl
        /json/version" — THIS function), §2.4 step 3d (the provisional claim writes port=0 →
        must NOT reserve a port here), §2.6 (Chrome launch on --remote-debugging-port=<port>),
        §2.8 (the lease .port field this selection feeds), §2.11 (AGENT_CHROME_PORT_BASE=53420,
        AGENT_CHROME_PORT_RANGE=1000), §2.4 step 3h (curl /json/version is the CDP liveness
        probe, reused here).
  pattern: §2.4 step 3f is the literal selection rule; §2.4 step 3h is the probe.
  gotcha: step 3f shows `ss … | grep` INSIDE the loop; we capture ss ONCE and grep the snapshot
        per-port (research §2) — same regex, one netlink call.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §2.2 (CDP Readiness Check — `curl -sf "http://127.0.0.1:<port>/json/version"`), §2.3
        (Port Selection: BASE/RANGE + the 3-stage "lowest free port where: not lease-claimed,
        ss -tln shows no listener, curl /json/version gets no response"), §4 (ss at
        /usr/bin/ss — iproute2; curl at /usr/bin/curl — both verified present), §5
        (AGENT_CHROME_PORT_BASE / AGENT_CHROME_PORT_RANGE env vars), §6 (lease schema .port).
  pattern: §2.3 IS the three-stage test; §2.2 IS the curl probe.
  gotcha: §2.2's curl has no --max-time; we add `--max-time 2` defensively (research §4) —
        connection-refused is instant so it adds no latency for free ports.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (flock critical section must be SHORT → the post-lock boot, incl. THIS port
        selection, runs OUTSIDE the flock, concurrently across agents → selection is
        best-effort; TOCTOU tolerated because the launch in M4.T2.S2 is the authoritative
        bind).
  pattern: FINDING 2 → the function is non-locking + best-effort.
  gotcha: two concurrent acquires can both select the same port; the launch step handles
        EADDRINUSE (research §5).

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — POOL_LANES_DIR/lanes/<N>.json is what
        pool_lanes_list/pool_lease_field read), the "Note" that stock agent-browser uses
        --remote-debugging-port=0 (random) while the pool MUST use an explicit recorded port.
  pattern: the .port recorded in the lease comes from THIS function.
  gotcha: none beyond the above.

# This task's own research (host-verified prototype — all 6 scenarios PASSED)
- file: plan/001_0f759fe2777c/P1M4T2S1/research/find-free-port-host-verified.md
  why: the deep brief on (a) the ss regex word boundary (§1); (b) capture-ss-once (§2); (c)
        local -A claimed + the port=0 filter (§3); (d) the curl --max-time + ordering (§4);
        (e) TOCTOU/outside-flock (§5); (f) exhaustion rc-1 + set -e hazard (§6); (g)
        naming/banner/placement/scope (§7); (h) the full 6-scenario results table (§0); and
        the paste-ready host-verified function body (§8).
  pattern: §1 (ss regex), §2 (capture once), §3 (assoc array + filter), §8 (the body).
  gotcha: §3 (port=0 filter) and §6 (set -e caller hazard) are the two that WILL cause bugs
        if missed.

# The LANDED functions this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list (M3.T2.S1 — LANDED @967)
  why: enumerates every numeric lane stem from $POOL_LANES_DIR/*.json, echoes each N sorted -n,
        ALWAYS returns 0 (empty/missing lanes dir is valid → no output). This task's claimed-set
        builder loops `for n in $(pool_lanes_list)`. CONTRACT: digits-only, newline-separated,
        so the unquoted $(…) word-splits into exactly the lane numbers (safe — no whitespace).
  pattern: the for-loop enumeration idiom (same as pool_lease_find_mine).
  gotcha: a missing lanes dir → no-match glob → 0 iterations → empty claimed set (correct).

- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_field (M3.T1.S2 — LANDED @876)
  why: reads one jq-style dotted field and echoes its raw value. For `port` (a top-level NUMBER,
        written via --argjson in pool_lease_write): echoes the decimal string ("53427" / "0" /
        "null"); returns 1 on missing/corrupt/non-numeric-lane (silent). This task calls
        `pool_lease_field "$n" port`. CONTRACT: a present numeric field echoes + returns 0; a
        missing field echoes "null" + returns 0; missing/corrupt FILE returns 1 (no output).
        Hence the `[[ =~ ^[0-9]+$ && -gt 0 ]]` filter (research §3).
  pattern: `p="$(pool_lease_field "$n" port 2>/dev/null)" || continue`.
  gotcha: provisional leases have port=0 → echoes "0" → filtered out (do NOT claim). Missing
        field → "null" → filtered out. Corrupt → rc 1 → || continue.

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init (M1.T1.S2 — LANDED @126)
  why: freezes POOL_PORT_BASE + POOL_PORT_RANGE as validated unsigned ints
        (_pool_config_require_uint; RANGE>0 enforced). This task reads both; the `for (( port =
        POOL_PORT_BASE; port < POOL_PORT_BASE + POOL_PORT_RANGE; … ))` loop relies on them being
        clean decimals (no octal-leading-zero hazard — uint-validated).
  pattern: globals are MUTABLE + re-runnable; no readonly.
  gotcha: POOL_PORT_BASE/POOL_PORT_RANGE are the GLOBALS (validated), not the env vars
        AGENT_CHROME_PORT_BASE/AGENT_CHROME_PORT_RANGE.

# The LANDED error/log helpers this task's CALLERS depend on (this task does NOT call pool_die)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md   # pool_die / _pool_log (M1.T1.S1 — LANDED)
  why: NOT used here. This function is NON-FATAL (rc 1 on exhaustion, never pool_die). pool_die
        is documented only to contrast: exhaustion is a recoverable query result, NOT a fatal.
  gotcha: do NOT add a pool_die on exhaustion — the contract says return 1 (research §6).

# The IMMEDIATE PREDECESSOR at EOF (placement reference)
- file: plan/001_0f759fe2777c/P1M4T1S1/PRP.md   # pool_copy_master (M4.T1.S1 — LANDED @1253)
  why: pool_copy_master is the LAST function in lib/pool.sh (file is now 1312 lines; verified
        `pool_copy_master() {` @ line 1253). This task APPENDS the new banner +
        pool_find_free_port directly after its closing brace. (Implemented in parallel per the
        plan; treated as a CONTRACT that is already present.)
  pattern: the banner style (`# ====…` + `# <group> — <subtask>` + `# ====…`); append-at-EOF.
  gotcha: do NOT touch pool_copy_master or any prior function — this task only APPENDS.

# The DIRECT ANALOG (the lane-number version of this function — pattern reference)
- file: plan/001_0f759fe2777c/P1M3T2S2/PRP.md   # pool_find_free_lane (M3.T2.S2 — LANDED @1101)
  why: the sibling "lowest free N" probe. SAME shape: a pure read-only query that echoes the
        lowest free index and returns 0 (no failure state there because lanes are unbounded).
        THIS function is the PORT analogue — bounded range, hence an exhaustion rc-1 path the
        lane version lacks. Read it for the echo-and-return-0 idiom + the docstring/banner
        style.
  pattern: `printf '%s\n' "$x"; return 0` + the non-fatal-query docstring conventions.
  gotcha: pool_find_free_lane ALWAYS returns 0 (lanes unbounded); pool_find_free_port can
        return 1 (range bounded) — the caller MUST guard (research §6).

# External authoritative docs (for the HOW)
- url: https://man7.org/linux/man-pages/man8/ss.8.html
  why: ss -tlnH output format (LISTEN state, TCP, no header, one-line-per-socket). The local
        address is `<addr>:<port>` (or `[<ipv6>]:<port>`), followed by a space and the peer
        address — which is why the `:$port ` trailing-space anchor is the correct word boundary.
  critical: capture ONCE per call (netlink), not per-port (research §2).
  section: OPTIONS (-t, -l, -n, -H); OUTPUT.

- url: https://curl.se/docs/manpage.html
  why: -s (silent), -f (fail silently on HTTP ≥400 → non-zero exit), --max-time (overall
        timeout). Connection-refused is exit 7 + instant (no timeout hit); a 200 response is
        exit 0 → "port taken by a CDP Chrome". The launch-readiness wait (M4.T2.S2) uses the
        same endpoint.
  critical: -f makes a 404 responder exit non-zero ("not a CDP endpoint"), but such a responder
        is ALREADY caught by the ss check first (it IS listening). The curl only runs for ports
        ss reports free → its job is the live race guard (research §4/§5).
  section: -s, -f, --max-time.
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.\*, M3.T2.S1–S3, M4.T1.S1** have landed,
`lib/pool.sh` is **1312 lines** with `pool_copy_master` (M4.T1.S1) as the final function
(verified: `grep -nE '^pool_copy_master\(\)' lib/pool.sh` → 1253):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # 1312 lines: set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)  ← POOL_PORT_BASE/RANGE frozen @~166
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.*)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)  ← pool_lease_field @876
│                                         #   + pool_lanes_list/pool_lease_find_mine/_any (M3.T2.S1)  ← pool_lanes_list @967
│                                         #   + pool_find_free_lane (M3.T2.S2)  ← @1101 (the DIRECT ANALOG)
│                                         #   + pool_lane_is_stale (M3.T2.S3)
│                                         #   + pool_copy_master (M4.T1.S1)  ← @1253–1312 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M4T1S1/PRP.md
    └── P1M4T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/find-free-port-host-verified.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND one function under a new banner after the current EOF
                  #   (line 1312, after pool_copy_master's closing brace):
                  #   # Lane lifecycle — port allocation (P1.M4.T2.S1)
                  #   pool_find_free_port() — lowest free TCP port in [BASE, BASE+RANGE):
                  #       skip lease-claimed, skip OS-listening (ss), skip CDP-responding
                  #       (curl /json/version); echo first free, return 0; rc 1 on exhaustion.
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**port-selection primitive** — the addressing step of PRD §2.4 step 3f. It composes the LANDED
`pool_lanes_list` + `pool_lease_field`; it is consumed by the acquire post-lock boot
(M5.T1.S2), outside the flock.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (provisional leases carry port=0): PRD §2.4 step 3d writes the claim with port=0
#   (lease-schema research: "placeholder 0 during provisional claim"). pool_lease_field echoes
#   "0" for those. The claimed-set builder MUST filter `port > 0` (and numeric), else a
#   provisional claim would (harmlessly) record 0 — but more importantly a stale/real lease's
#   real port must be honored. HOST-VERIFIED (research §3, scenario 2).

# CRITICAL (the ss regex NEEDS the trailing space): `:$port ` (colon, digits, SPACE). The space
#   is the local-addr/peer-addr separator in `ss -tlnH` output → the word boundary. Without it
#   `:5342` would match the `:53420` line. IPv6-safe: `[::]:9222` still contains `:9222 `.
#   HOST-VERIFIED (research §1). Plain `grep -q` (literal) is correct — port is numeric, no
#   metacharacters.

# CRITICAL (capture ss ONCE, not per-port): the contract shows `ss … | grep` inside the loop.
#   ss is a NETLINK syscall (slower than a grep fork); running it up to RANGE=1000 times is
#   wasteful. Capture `ss -tlnH` once into $listeners and `grep -q ":$port " <<<"$listeners"`
#   per candidate. Mirrors pool_lane_is_stale's "ONE jq fork" principle. HOST-VERIFIED (§2).
#   `|| true` on the capture so a transient ss failure → empty snapshot (curl still guards).

# CRITICAL (curl --max-time 2 is defensive, not in the bare contract): connection-refused (rc 7)
#   is INSTANT (HOST-VERIFIED), so --max-time adds ZERO latency for free ports. It only bounds a
#   pathological DROP-style filtered port (which would otherwise stall for the kernel TCP
#   timeout). Does NOT change the contract's semantics. (research §4)

# CRITICAL (NEVER pool_die on exhaustion): the contract step 3c says "return 1". Exhaustion is
#   a recoverable query result (the caller M5.T1.S2 → M5.T4 block-with-timeout handles it), NOT
#   a fatal. Same non-fatal family as pool_lease_read / pool_lease_find_mine. (research §6)

# CRITICAL (CALLERS under set -e MUST guard): a BARE `port="$(pool_find_free_port)"` whose rc
#   is 1 (exhausted) ABORTs the caller (the $(…) returns 1 → errexit fires). The caller MUST
#   use `if port="$(pool_find_free_port)"; then …; else <exhaustion path>; fi`. Same hazard
#   family as pool_lease_read / pool_lease_find_mine / pool_lane_is_stale. (research §6)

# CRITICAL (this is the FIRST `local -A` in the codebase): an associative array is the idiomatic
#   O(1) fork-free "set" for the claimed-port membership test inside a ≤1000-iteration loop.
#   bash 4+ (already required by mapfile/declare -g). shellcheck-clean. Document it in the
#   docstring so the next reader isn't surprised. (research §3)

# GOTCHA (naming): pool_find_free_port — the CONTRACT body literally says "Implement
#   `pool_find_free_port()`". Consistent with the lane analog pool_find_free_lane (M3.T2.S2).
#   The item title abbreviates it find_free_port(); the contract + consumer (M5.T1.S2) use the
#   pool_ prefix. Do NOT rename.

# GOTCHA (placement): APPEND at EOF (after pool_copy_master @1312). Do NOT touch any existing
#   function. This task only CONSUMES pool_lanes_list + pool_lease_field (both read-only).

# GOTCHA (scope): this task is the port-SELECTION primitive only. Do NOT: launch Chrome
#   (M4.T2.S2); wait for CDP readiness (M4.T2.S2 — that's the post-launch /json/version loop,
#   up to 30×0.5s); connect the daemon (M4.T3); acquire/release/reap (M5); the flock critical
#   section (M5.T1.S1); or update the lease's .port (M5.T1.S2 — the caller writes $port into
#   the lease AFTER this returns 0).

# GOTCHA (TOCTOU is tolerated): this runs OUTSIDE the flock (key_findings FINDING 2). Two
#   concurrent acquires can both select the same port. The launch (M4.T2.S2) is the
#   authoritative bind; EADDRINUSE there is retried by M5.T1.S2. The per-port curl narrows (but
#   cannot eliminate) the race against the once-captured ss snapshot. (research §5)
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no new globals**, **no new env vars**, and **no on-disk layout**. It
defines ONE function whose data contract is read-only over `POOL_PORT_BASE`/`POOL_PORT_RANGE`
(frozen by `pool_config_init`) and the lease JSON files (read via `pool_lanes_list` +
`pool_lease_field`). It echoes one integer to stdout (the free port) on success or nothing on
exhaustion. It writes nothing and never `pool_die`s.

| composed fn | source | contract relied upon | role here |
|---|---|---|---|
| `pool_lanes_list` | M3.T2.S1 (LANDED @967) | echoes each numeric lane N sorted -n; ALWAYS rc 0 (empty/missing dir = valid) | enumerate lanes for the claimed-set build |
| `pool_lease_field` | M3.T1.S2 (LANDED @876) | echoes the raw value of a jq dotted field; rc 1 on missing/corrupt file; a missing field echoes "null" + rc 0 | read each lease's `.port` |

Globals read (both frozen as validated unsigned ints by `pool_config_init`, M1.T1.S2):

| global | source env var | example | role |
|---|---|---|---|
| `POOL_PORT_BASE` | `AGENT_CHROME_PORT_BASE` (default `53420`) | `53420` | inclusive loop start |
| `POOL_PORT_RANGE` | `AGENT_CHROME_PORT_RANGE` (default `1000`) | `1000` | loop width; range is `[BASE, BASE+RANGE)` (exclusive end) |

External commands (both verified present, external_deps §4): `ss` (`/usr/bin/ss`, iproute2 —
`ss -tlnH`), `curl` (`/usr/bin/curl` — `curl -sf --max-time 2 http://127.0.0.1:<port>/json/version`).
`grep` is a built-in/utility used against a captured string (`grep -q ":$port "`).

**Naming** (CONTRACT-mandated, exact): `pool_find_free_port`. Consistent with the lane analog
`pool_find_free_lane` (M3.T2.S2). No `_` prefix — it is a public entry point (mirrors
`pool_find_free_lane`). Internal-only in practice (sole consumer M5.T1.S2).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init pool_lanes_list pool_lease_field pool_find_free_lane pool_copy_master'
  - EXPECT: all six reported as functions. (pool_config_init is M1.T1.S2 LANDED @126; pool_state_init
        is M1.T1.S3 LANDED @202; pool_lanes_list is M3.T2.S1 LANDED @967; pool_lease_field is M3.T1.S2
        LANDED @876; pool_find_free_lane is M3.T2.S2 LANDED @1101 — the DIRECT ANALOG; pool_copy_master
        is M4.T1.S1 LANDED @1253 — confirms the append point.) If pool_lanes_list or pool_lease_field
        is MISSING, STOP — this task hard-depends on both.
  - RUN (sanity-check the composed contract + the two globals):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 pool_config_init; \
                 [[ "${POOL_PORT_BASE}" =~ ^[0-9]+$ ]] && echo "OK POOL_PORT_BASE=$POOL_PORT_BASE" || echo "FAIL"; \
                 [[ "${POOL_PORT_RANGE}" =~ ^[0-9]+$ && POOL_PORT_RANGE -gt 0 ]] && echo "OK POOL_PORT_RANGE=$POOL_PORT_RANGE" || echo "FAIL"; \
                 [[ "${POOL_LANES_DIR}" == /* ]] && echo "OK POOL_LANES_DIR absolute" || echo "FAIL"'
        # EXPECT: OK POOL_PORT_BASE=53420 ; OK POOL_PORT_RANGE=1000 ; OK POOL_LANES_DIR absolute.
  - RUN (verify the external commands this task shells out to):
        command -v ss >/dev/null && echo "OK ss present" || echo "FAIL"
        command -v curl >/dev/null && echo "OK curl present" || echo "FAIL"
        ss -tlnH >/dev/null 2>&1 && echo "OK ss runnable" || echo "FAIL"
        # EXPECT: all OK.
  - RUN (locate the append point — current EOF):
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^pool_copy_master\(\)' lib/pool.sh
  - EXPECT: the last function is pool_copy_master (closing brace at ~line 1312). APPEND the new
        banner + function AFTER that brace. Do NOT touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_find_free_port() to lib/pool.sh (the only function)
  - PLACEMENT: after a new banner, directly below pool_copy_master()'s closing brace (current
        EOF, line 1312).
  - IMPLEMENT (verbatim-ready — paste this block):
        # =============================================================================
        # Lane lifecycle — port allocation (P1.M4.T2.S1)
        # =============================================================================
        # Select the lowest free TCP port in [POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE)
        # for a freshly-claimed lane's Chrome to bind. Implements PRD §2.4 step 3f ("PORT: lowest
        # free TCP port in [BASE, BASE+RANGE); probe via curl /json/version") + §2.3 (the
        # 3-stage free test). Consumed by the acquire POST-LOCK boot (M5.T1.S2: copy → port →
        # launch → connect → update lease), OUTSIDE the flock critical section (key_findings
        # FINDING 2 — concurrent boots; selection is BEST-EFFORT: the launch in M4.T2.S2 is the
        # authoritative bind and retries on EADDRINUSE).

        # pool_find_free_port
        #
        # Echo the lowest free TCP port in [POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE) and
        # return 0; return 1 if the whole range is occupied (exhaustion — non-fatal, ~impossible
        # with the default 1000-port range). A port is "free" when ALL of:
        #   1. NOT claimed by any live lease's .port      (provisional port=0 claims do NOT count)
        #   2. NOT shown listening by `ss -tlnH`          (any OS listener)
        #   3. NOT answering curl /json/version           (a live non-pool Chrome on that port)
        #
        # LOGIC (CONTRACT 3a→3c):
        #   a. Build a claimed-port set from lanes/*.json (compose pool_lanes_list +
        #      pool_lease_field); skip port<=0 / non-numeric (PRD §2.4 step 3d provisional = 0).
        #   b. Capture `ss -tlnH` ONCE (netlink is more expensive than a grep fork; mirrors
        #      pool_lane_is_stale's "ONE jq fork" principle). Loop BASE..BASE+RANGE-1:
        #        - skip if claimed (O(1) assoc-array lookup)
        #        - skip if `:$port ` (trailing space = word boundary) appears in the snapshot
        #        - skip if curl /json/version responds (live CDP endpoint)
        #        - first pass → echo + return 0.
        #   c. none free → return 1 (NOT pool_die — recoverable; caller → M5.T4 exhaustion flow).
        #
        # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → stdout is the port to bind;
        #   rc 1 → range exhausted, caller must handle (block/force-reap/alert). Caller MUST guard
        #   under set -e: `if port="$(pool_find_free_port)"; then …`.
        #
        # GOTCHA — provisional leases carry port=0 (PRD §2.4 step 3d): the claimed-set builder
        #   filters `[[ =~ ^[0-9]+$ && -gt 0 ]]`, so a mid-acquire lane does NOT reserve a port.
        #   HOST-VERIFIED (research §3, scenario 2).
        # GOTCHA — the ss regex NEEDS the trailing space (`:$port `): it is the local-addr /
        #   peer-addr separator → the word boundary. Without it `:5342` would match `:53420`.
        #   IPv6-safe ([::]:9222 still has ':9222 '). Plain grep -q (literal) — port is numeric.
        #   HOST-VERIFIED (research §1).
        # GOTCHA — capture ss ONCE, not per-port: the contract writes the ss|grep inside the loop;
        #   ss is a netlink call (slower than grep). We snapshot once and grep the captured text.
        #   `|| true` degrades a transient ss failure to an empty snapshot (curl still guards).
        #   HOST-VERIFIED (research §2).
        # GOTCHA — curl --max-time 2 is DEFENSIVE: connection-refused (rc 7) is INSTANT, so this
        #   adds zero latency for free ports; it only bounds a pathological DROP-style filtered
        #   port. -f makes a 404 responder non-zero, but such a responder is ALREADY caught by the
        #   ss check (it IS listening) — curl only runs for ss-free ports → it's the live race
        #   guard. HOST-VERIFIED (research §4).
        # GOTCHA — NEVER pool_die on exhaustion: rc 1 (non-fatal query), same family as
        #   pool_lease_read / pool_lease_find_mine. Caller MUST guard under set -e. (research §6).
        # GOTCHA — this is the FIRST `local -A` (associative array) in the codebase: the idiomatic
        #   O(1) fork-free "set" for the claimed-port membership test inside a ≤1000-iteration
        #   loop. bash 4+ (already required by mapfile/declare -g). (research §3).
        # GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can both
        #   pick the same port — the launch (M4.T2.S2) is authoritative + retries on EADDRINUSE.
        #   (research §5).
        # Reads ONLY POOL_PORT_BASE + POOL_PORT_RANGE (frozen by pool_config_init) + the lease
        # JSON (via pool_lanes_list/pool_lease_field). Writes nothing. No new globals/env-vars.
        # PRECONDITION: pool_config_init (for POOL_PORT_BASE/RANGE + POOL_LANES_DIR via helpers).
        pool_find_free_port() {
            local port p n listeners
            local -A claimed=()

            # (a) Build the claimed-port set. Compose the LANDED readers (pool_lanes_list +
            #     pool_lease_field) — same enumeration pattern as pool_lease_find_mine. Skip
            #     port<=0 / non-numeric: a PROVISIONAL claim writes port=0 (PRD §2.4 step 3d)
            #     and must NOT reserve a port. `|| continue` keeps a corrupt/missing lease from
            #     aborting the scan (pool_lease_field returns 1, silent). assoc-array assignment
            #     is errexit-safe.
            for n in $(pool_lanes_list); do
                p="$(pool_lease_field "$n" port 2>/dev/null)" || continue
                [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && claimed["$p"]=1
            done

            # Snapshot the listening sockets ONCE (not per-port). `|| true` so a transient ss
            # failure (missing binary / permission) degrades to an empty snapshot — the per-port
            # curl below is the live check that still guards.
            listeners="$(ss -tlnH 2>/dev/null || true)"

            # (b) Lowest free port in [BASE, BASE+RANGE). POOL_PORT_BASE/RANGE are validated
            #     uints (pool_config_init) → safe in (( )). Each skip is errexit-exempt
            #     (`[[ ]] || continue`, `grep … && continue`, `if curl …; then continue; fi`).
            for (( port = POOL_PORT_BASE; port < POOL_PORT_BASE + POOL_PORT_RANGE; port++ )); do
                # 1. claimed by a live lease? (O(1) assoc lookup; ${:-} is safe for unset keys)
                [[ -z "${claimed[$port]:-}" ]] || continue
                # 2. OS listener? (`:$port ` trailing space = word boundary; literal grep)
                grep -q ":$port " <<<"$listeners" && continue
                # 3. live CDP endpoint? (a non-pool Chrome answering /json/version). -f fails on
                #    HTTP>=400; --max-time bounds a DROP-style filter (connection-refused is
                #    instant). 2>&1 + >/dev/null = fully silent.
                if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
                    continue
                fi
                printf '%s\n' "$port"
                return 0
            done

            # (c) Exhausted — rc 1, NOT pool_die. Caller handles via M5.T4 (block/force-reap/alert).
            return 1
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155); `local -A claimed=()`
        (first assoc array — documented); `[[ ]] || continue` / `grep … && continue` /
        `if …; then continue; fi` (all errexit-exempt loop controls); `$(pool_lanes_list)`
        unquoted (digits-only/newline-separated → safe word-split, same as pool_lease_find_mine);
        `2>/dev/null`/`2>&1` on ss+curl (never flood stderr); the composed pool_lanes_list +
        pool_lease_field.
  - NAMING: pool_find_free_port (CONTRACT-mandated; do NOT rename).
  - PLACEMENT: the only function in the new "(P1.M4.T2.S1)" banner.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_find_free_port' >/dev/null && echo OK
        # EXPECT: OK.
  # NOTE: pool_find_free_port returns 1 on EXHAUSTION (never pool_die), so it never exits the
  # process — subshells are only needed where you want to assert the rc-1 path explicitly.
  #
  # --- shared throwaway state dir + listeners -----------------------------------------
  - RUN (build fixtures: claim 53420 via a lease; stand up a non-CDP listener on 53421 and a
        CDP-like responder on 53422):
        STATE="$(mktemp -d)"; EPH="$(mktemp -d)"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1000 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                  pool_lease_write 1 "$EPH/1" 53420 abpool-1 $$ pi 1234567890 /tmp 0 0 false; \
                  pool_lease_write 2 "$EPH/2" 0 abpool-2 $$ pi 1234567890 /tmp 0 0 false' \
            # lane2 is provisional (port=0) → must be IGNORED
        # non-CDP OS listener on 53421 (python 404)
        python3 - <<'PY' &
        import http.server,socketserver
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self): self.send_response(404); self.end_headers()
            def log_message(self,*a): pass
        socketserver.TCPServer(("127.0.0.1",53421),H).serve_forever()
        PY
        L1=$!
        # CDP-like responder on 53422 (200 {})
        python3 - <<'PY' &
        import http.server,socketserver
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                b=b'{}'; self.send_response(200); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b)
            def log_message(self,*a): pass
        socketserver.TCPServer(("127.0.0.1",53422),H).serve_forever()
        PY
        L2=$!
        sleep 1.0
        # eyeball the fixtures
        ss -tlnH 2>/dev/null | grep -cE ':53421 '   # EXPECT: 1
        curl -sf --max-time 2 http://127.0.0.1:53422/json/version >/dev/null 2>&1 && echo "53422 responds" || echo "53422 no"
  - RUN (SCENARIO 1 — empty lanes, nothing in range listening → 53420):
        STATE2="$(mktemp -d)"; EPH2="$(mktemp -d)"
        AGENT_BROWSER_POOL_STATE="$STATE2" AGENT_CHROME_EPHEMERAL_ROOT="$EPH2" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1000 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 p="$(pool_find_free_port)"; echo "got=$p"; [[ "$p" == 53420 ]] && echo OK1 || echo FAIL1'
        rm -rf "$STATE2" "$EPH2"
        # EXPECT: got=53420 ; OK1.   (53420 must be free on a quiet host; if a stray listener
        #   is there, the function correctly skips to the next free port — adjust the assertion
        #   to "p is in [53420,54420) and not claimed/not listening".)
  - RUN (SCENARIO 2 — lease claims 53420 + provisional port=0 → 53421; provisional ignored):
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1000 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 p="$(pool_find_free_port)"; echo "got=$p"; [[ "$p" == 53421 ]] && echo OK2 || echo FAIL2'
        # EXPECT: got=53421 ; OK2.   (lane1 claims 53420; lane2 port=0 ignored; 53421 has a
        #   non-CDP listener → skipped; 53422 has the CDP responder → skipped; → 53423.)
        #   NOTE: with BOTH listeners up this is really the full skip-chain → expect 53423 (see
        #   SCENARIO 5). Run SCENARIO 2 BEFORE standing up the listeners for the isolated check,
        #   OR assert 53423 with listeners up (SCENARIO 5).
  - RUN (SCENARIO 3 — non-CDP OS listener is skipped by ss):  (covered by the skip-chain below)
  - RUN (SCENARIO 4 — CDP responder is skipped by curl):      (covered by the skip-chain below)
  - RUN (SCENARIO 5 — full skip chain: lease53420 → ss53421 → curl53422 → FREE 53423):
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1000 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 p="$(pool_find_free_port)"; echo "got=$p"; [[ "$p" == 53423 ]] && echo OK5 || echo FAIL5'
        # EXPECT: got=53423 ; OK5.   (proves claimed→ss→curl→free in one shot.)
  - RUN (SCENARIO 6 — exhaustion: RANGE=1 + claim the only port → rc 1, no output):
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
        AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 pool_lease_update 1 port 53420; \
                 if p="$(pool_find_free_port)"; then echo "FAIL6 got=$p"; else echo "OK6 rc=1 exhausted"; fi'
        # EXPECT: OK6 rc=1 exhausted.   (proves the rc-1 non-fatal path + the caller guard idiom.)
  - RUN (SCENARIO 7 — caller set -e hazard: a BARE capture of the exhausted rc aborts; the
        `if` guard does not):
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
        AGENT_CHROME_PORT_RANGE=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 p="$(pool_find_free_port)"; echo "UNREACHED bare-capture rc=$?"' \
            >/tmp/s7.out 2>&1; rc=$?
        echo "bare-capture exit=$rc"; cat /tmp/s7.out
        # EXPECT: exit != 0 (the bare $(…) returned 1 → errexit fired before "UNREACHED").
        #   This is WHY callers MUST use `if p="$(pool_find_free_port)"; then …`.
  - RUN (composes the right helpers — body contains pool_lanes_list + pool_lease_field + ss +
        curl + the assoc array; does NOT call pool_die; does NOT call pool_find_free_lane):
        body="$(sed -n "/^pool_find_free_port() {/,/^}/p" lib/pool.sh)"
        grep -q "pool_lanes_list"   <<<"$body" && echo "OK composes pool_lanes_list"  || echo "FAIL"
        grep -q "pool_lease_field"  <<<"$body" && echo "OK composes pool_lease_field" || echo "FAIL"
        grep -q "local -A claimed"  <<<"$body" && echo "OK assoc-array claimed set"   || echo "FAIL"
        grep -q 'grep -q ":\$port " <<<"\$listeners"' <<<"$body" && echo "OK ss-snapshot grep" || echo "FAIL"
        grep -q "/json/version"     <<<"$body" && echo "OK curl /json/version"       || echo "FAIL"
        grep -q -- "--max-time 2"   <<<"$body" && echo "OK curl timeout"             || echo "FAIL"
        grep -q "return 1"          <<<"$body" && echo "OK exhaustion rc 1"          || echo "FAIL"
        grep -q "pool_die"          <<<"$body" && echo "FAIL calls pool_die"         || echo "OK no pool_die"
        grep -q "pool_find_free_lane" <<<"$body" && echo "FAIL calls pool_find_free_lane" || echo "OK no lane-fn reuse"
        # EXPECT: all OK / no-FAIL lines.
  - RUN (regression: all prior + new function still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      pool_check_btrfs pool_check_master \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any \
                      pool_find_free_lane pool_lane_is_stale pool_copy_master \
                      pool_find_free_port >/dev/null && echo OK'
        # EXPECT: OK (all functions, including the new pool_find_free_port, callable).
  - RUN (cleanup test artifacts):
        kill "$L1" "$L2" 2>/dev/null || true; wait "$L1" "$L2" 2>/dev/null || true
        rm -rf "$STATE" "$EPH" /tmp/s7.out
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the one function (paste under the new banner after pool_copy_master) ---------

pool_find_free_port() {
    local port p n listeners
    local -A claimed=()

    # (a) claimed-port set from live leases (skip port=0 provisional + non-numeric).
    for n in $(pool_lanes_list); do
        p="$(pool_lease_field "$n" port 2>/dev/null)" || continue
        [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && claimed["$p"]=1
    done

    # ss snapshot ONCE (netlink is more expensive than grep; mirrors pool_lane_is_stale's
    # "ONE jq fork" principle). `|| true` → empty snapshot on transient failure (curl still guards).
    listeners="$(ss -tlnH 2>/dev/null || true)"

    # (b) lowest free port in [BASE, BASE+RANGE): claimed → ss → curl, first pass wins.
    for (( port = POOL_PORT_BASE; port < POOL_PORT_BASE + POOL_PORT_RANGE; port++ )); do
        [[ -z "${claimed[$port]:-}" ]] || continue            # lease-claimed (O(1))
        grep -q ":$port " <<<"$listeners" && continue         # OS listener (word boundary)
        if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            continue                                           # live CDP endpoint (non-pool Chrome)
        fi
        printf '%s\n' "$port"
        return 0
    done

    return 1   # (c) exhausted — non-fatal; caller → M5.T4
}

# --- Critical micro-rules baked into the above --------------------------------
#  * PROVISIONAL port=0 never reserves a port: PRD §2.4 step 3d; the `-gt 0` + numeric filter.
#    HOST-VERIFIED.
#  * `:$port ` NEEDS the trailing space: the ss local/peer-addr separator = word boundary.
#    IPv6-safe. HOST-VERIFIED.
#  * Capture ss ONCE: netlink call (slower than grep); grep the snapshot per-port. HOST-VERIFIED.
#  * curl --max-time 2: connection-refused is INSTANT → zero latency for free ports; only bounds
#    a DROP-style filter. -f → 404 non-zero, but a 404 responder is already ss-caught (listening).
#    HOST-VERIFIED.
#  * NEVER pool_die: exhaustion = rc 1 (non-fatal query). Caller MUST guard under set -e:
#    `if port="$(pool_find_free_port)"; then …; else <M5.T4>; fi`. Same hazard as pool_lease_read.
#  * `local -A claimed` is the codebase's FIRST assoc array: O(1) fork-free membership in a
#    ≤1000-iteration loop. bash 4+ (already required). shellcheck-clean.
#  * Reads only POOL_PORT_BASE/POOL_PORT_RANGE + the lease JSON (via helpers). No writes, no new
#    state. TOCTOU tolerated (runs outside the flock; launch in M4.T2.S2 is authoritative).
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_lanes_list() (M3.T2.S1 @967): echoes each numeric lane N sorted -n; ALWAYS rc 0
        (empty/missing lanes dir → no output). THIS task loops `for n in $(pool_lanes_list)`.
  - pool_lease_field() (M3.T1.S2 @876): echoes the raw value of a jq dotted field; rc 1 on
        missing/corrupt FILE (silent); a missing FIELD echoes "null" + rc 0. THIS task calls
        `pool_lease_field "$n" port`. For a numeric .port it echoes the decimal string; for a
        provisional lease it echoes "0"; the filter `=~ ^[0-9]+$ && -gt 0` admits only real ports.
  - pool_config_init() (M1.T1.S2 @126): freezes POOL_PORT_BASE + POOL_PORT_RANGE as validated
        unsigned ints (RANGE>0 enforced). THIS task reads both; the (( )) loop relies on clean
        decimals (no octal hazard).

CALLER (future — M5.T1.S2 acquire post-lock boot, NOT built here):
  - After the flock critical section writes the provisional claim (port=0) and releases the lock
    (key_findings FINDING 2: keep flock short), M5.T1.S2 runs:
        pool_copy_master "$POOL_EPHEMERAL_ROOT/$N"   # M4.T1.S1
        port="$(pool_find_free_port)"                 # THIS task  ← M5.T1.S2 GUARDS with `if`
        # launch Chrome on $port (M4.T2.S2: --remote-debugging-port=$port + CDP readiness wait)
        # connect daemon (M4.T3.S1)
        pool_lease_update "$N" port "$port"           # M3.T1.S1 (records the chosen port)
    On exhaustion (rc 1), M5.T1.S2 falls through to the pool-exhaustion flow (M5.T4:
    block-with-timeout + force-reap + alert).

ENV VARS (all already wired by pool_config_init; NONE new in this task):
  - AGENT_CHROME_PORT_BASE    → POOL_PORT_BASE    (53420; inclusive loop start)
  - AGENT_CHROME_PORT_RANGE   → POOL_PORT_RANGE   (1000; range = [BASE, BASE+RANGE), exclusive end)

NO DATABASE / NO ROUTES / NO CONFIG-FILE CHANGES. This is a pure library append.
```

## Validation Loop

> This is a bash library. There is no test harness yet (bats arrives in M9.T1.S1), so each
> level uses inline scenario scripts against the real `lib/pool.sh`. `pool_find_free_port`
> returns 1 on exhaustion (never `pool_die`), so — UNLIKE the die-expecting validations in
> sibling PRPs — it does NOT need a `( … )` subshell to survive; use `if p="$(…)"` to assert
> the rc-1 path.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the function — fix before proceeding.
bash -n lib/pool.sh                  # parse check — MUST be clean
shellcheck lib/pool.sh               # lint the WHOLE file — zero warnings

# Expected: both clean. If shellcheck flags the new function, READ the wiki (SC2155 = declare
# local separately from assignment; SC2086 = quote vars) and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

```bash
# Throwaway state + fixtures. (python3 stands up reliable listeners; `nc` is unreliable here.)
STATE="$(mktemp -d)"; EPH="$(mktemp -d)"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
AGENT_CHROME_PORT_BASE=53420 AGENT_CHROME_PORT_RANGE=1000 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
           pool_lease_write 1 "$EPH/1" 53420 abpool-1 $$ pi 1234567890 /tmp 0 0 false
           pool_lease_write 2 "$EPH/2" 0 abpool-2 $$ pi 1234567890 /tmp 0 0 false'   # lane2 provisional

# non-CDP listener on 53421 + CDP responder on 53422
python3 - <<'PY' & import http.server,socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
socketserver.TCPServer(("127.0.0.1",53421),H).serve_forever()
PY
python3 - <<'PY' & import http.server,socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b=b'{}'; self.send_response(200); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
socketserver.TCPServer(("127.0.0.1",53422),H).serve_forever()
PY
sleep 1.0

# (A) empty lanes (separate clean state) → 53420
STATE2="$(mktemp -d)"; EPH2="$(mktemp -d)"
AGENT_BROWSER_POOL_STATE="$STATE2" AGENT_CHROME_EPHEMERAL_ROOT="$EPH2" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
           p="$(pool_find_free_port)"; echo "A got=$p"; [[ "$p" == 53420 ]] && echo "A OK" || echo "A (adjust if host listener present)"'

# (B+5) full skip chain: lease53420 + ss53421 + curl53422 → 53423 (provisional port=0 ignored)
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           p="$(pool_find_free_port)"; echo "B got=$p"; [[ "$p" == 53423 ]] && echo "B OK" || echo "B FAIL"'

# (6) exhaustion: RANGE=1 + claim the only port → rc 1
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" AGENT_CHROME_PORT_RANGE=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_lease_update 1 port 53420
           if p="$(pool_find_free_port)"; then echo "6 FAIL got=$p"; else echo "6 OK rc=1"; fi'

kill %1 %2 2>/dev/null; wait 2>/dev/null; rm -rf "$STATE" "$EPH" "$STATE2" "$EPH2"
# Expected: A OK (or adjusted note); B OK (53423); 6 OK rc=1. See Task 2 for the full assertion set.
```

### Level 3: Integration Testing (Real lease fixtures + host listeners)

```bash
# Confirm the host facts the function relies on (regression against env change):
command -v ss && command -v curl                                  # both present
ss -tlnH | grep -q ':9222 ' && echo "9222 (Brave) listening — pool correctly avoids it" || echo "9222 free"
ss -tlnH >/dev/null 2>&1 && echo "ss -tlnH runnable" || echo "ss FAILED"

# End-to-end with the production port range (no fixtures beyond a clean state):
STATE="$(mktemp -d)"; EPH="$(mktemp -d)"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
           p="$(pool_find_free_port)"; echo "free port = $p"
           [[ "$p" -ge 53420 && "$p" -lt 54420 ]] && echo "in range OK" || echo "OUT OF RANGE FAIL"'
rm -rf "$STATE" "$EPH"
# Expected: free port = 53420 (on a quiet host); in range OK. If 53420 is occupied by a stray
# process, the function correctly returns the next free port in [53420,54420).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Concurrency / TOCTOU sanity (two simultaneous selectors on a clean state — they MAY agree,
# and that is ACCEPTABLE per FINDING 2; the launch in M4.T2.S2 is authoritative):
STATE="$(mktemp -d)"; EPH="$(mktemp -d)"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPH" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
           pool_find_free_port & pool_find_free_port & wait' | sort -n | uniq -c
rm -rf "$STATE" "$EPH"
# Expected: 1 or 2 distinct ports (both may pick 53420 — best-effort, non-locking; correct).

# Regression: the whole file still lints clean after the append.
shellcheck lib/pool.sh && echo "whole-file shellcheck OK"
bash -n lib/pool.sh && echo "whole-file bash -n OK"
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (Level 1).
- [ ] `shellcheck lib/pool.sh` clean — whole file (Level 1).
- [ ] All Level 2 scenarios pass: empty→53420; full skip-chain (lease+ss+curl)→53423 with
      provisional port=0 ignored; exhaustion (RANGE=1)→rc 1.
- [ ] Level 3 host facts: `ss` + `curl` present and runnable; 9222 (Brave) correctly avoided by
      the 53420+ range.
- [ ] Level 4: whole-file `shellcheck` + `bash -n` clean after the append.

### Feature Validation

- [ ] All success criteria from "What" section met.
- [ ] Lowest-free-port invariant: iterates BASE..BASE+RANGE-1 ascending, returns on first pass.
- [ ] Provisional `port=0` leases do NOT reserve a port (the `-gt 0` filter — scenario B).
- [ ] ss listener skipped (`:$port ` word boundary — scenario B/5).
- [ ] CDP responder skipped (`curl /json/version` — scenario B/5).
- [ ] Exhaustion is **rc 1** (NOT pool_die); caller `if`-guard idiom demonstrated (scenario 6/7).
- [ ] Composes `pool_lanes_list` + `pool_lease_field`; does NOT call `pool_die` /
      `pool_find_free_lane` / `pool_check_btrfs`.

### Code Quality Validation

- [ ] Follows existing codebase patterns: `local`-first (SC2155), errexit-exempt loop controls
      (`[[ ]] || continue`, `grep … && continue`, `if curl …; then continue; fi`), `2>/dev/null`/
      `2>&1` on ss+curl, `$(pool_lanes_list)` unquoted enumeration (same as pool_lease_find_mine).
- [ ] Banner style matches the M3/M4.T1 sections; placed at EOF after `pool_copy_master`.
- [ ] `local -A claimed` (first assoc array) is documented in the docstring with rationale.
- [ ] No new globals / env vars / files / on-disk layout; reads only the two port globals + leases.

### Documentation & Deployment

- [ ] No new user docs required ("DOCS: none — internal function"). The function is
      self-documenting via its docstring header.
- [ ] No new env vars; no README changes; no .gitignore changes.

---

## Anti-Patterns to Avoid

- ❌ Don't run `ss` per-port inside the loop — capture the `ss -tlnH` snapshot ONCE and grep the
  captured text per-port (netlink is more expensive than a grep fork; mirrors
  pool_lane_is_stale's "ONE jq fork" principle).
- ❌ Don't drop the `:$port ` **trailing space** — it is the word boundary; without it `:5342`
  would false-match the `:53420` line.
- ❌ Don't add provisional `port=0` leases to the claimed set — filter `-gt 0` + numeric (PRD
  §2.4 step 3d).
- ❌ Don't `pool_die` on exhaustion — return 1 (non-fatal; caller handles via M5.T4). Same
  non-fatal family as `pool_lease_read` / `pool_lease_find_mine`.
- ❌ Don't call the function with a bare `port="$(pool_find_free_port)"` under `set -e` without an
  `if` guard — the rc-1 exhaustion path ABORTs the caller.
- ❌ Don't omit `--max-time` on the curl — connection-refused is instant, but a DROP-style
  filtered port could otherwise stall the loop for the kernel TCP timeout.
- ❌ Don't re-implement lane enumeration or field reads — compose `pool_lanes_list` +
  `pool_lease_field` (exactly `pool_lease_find_mine`'s pattern).
- ❌ Don't launch Chrome, wait for CDP readiness, connect the daemon, take/release the flock, or
  update the lease here — those are M4.T2.S2 / M4.T3 / M5.T1.S1 / M5.T1.S2 (out of scope).
- ❌ Don't rename `pool_find_free_port` — the contract + consumer (M5.T1.S2) use exactly that
  name (consistent with the `pool_find_free_lane` analog).
