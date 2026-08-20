---
name: "P4.M2.T1.S3 — Parallel caller-mode owners → distinct lanes; owner death → lane reaped"
---

## Goal

**Feature Goal**: Add two selftests to `test/validate.sh` proving PRD §2.12 / O10's caller-scoped semantics end-to-end through the real acquire/liveness/reap machinery: (a) two distinct simulated owners acquire **distinct lanes**, each lease recording its own `owner.pid`; (b) when an owner dies, its lane goes stale and is fully reaped (lease + ephemeral dir) by the next acquire/reap path.

**Deliverable**: Two auto-discovered selftest functions in `test/validate.sh`:
- `selftest_caller_mode_parallel_owners_distinct_lanes`
- `selftest_caller_mode_lane_reaped_after_owner_death`

Chrome-free, zero daemon spawns beyond `spawn_sim_owner` sleeps, all timeout-bounded and reaped.

**Success Definition**: `timeout 120 bash test/validate.sh` (isolated sandbox only) reports both new selftests PASS; all pre-existing selftests green and unmodified; `bash -n` + `shellcheck -s bash` add zero warnings; zero orphaned processes/temp dirs after the run.

## User Persona

**Target User**: Maintainer/agent validating the orchestrator use case of PRD §2.12 (`ABPOOL_OWNER=caller` parallel scrapers).
**Use Case**: Regression gate for lane auto-assignment and teardown-on-owner-exit.
**Pain Points Addressed**: Parallel caller-mode subprocesses clobbering one lane; leaked lanes/ephemeral dirs after a subprocess exits.

## Why

- PRD §2.12: each caller-mode subprocess must resolve to its own lane automatically and have it reaped on exit by the lazy reaper (§2.10) — "correct teardown semantics for free".
- PRD §2.19 sanctions simulating parallel owners "via the owner-override hooks or real subprocesses"; the hooks exercise the same downstream acquire/liveness/reap code as caller mode.
- Locks in P4.M1.T3.S1 (caller-mode resolve) + the existing reap machinery; foundation for P4.M2.T2 concurrency E2E.

## What

Two selftests, both following the established child-`body.sh` + per-body isolated state-root pattern (see `selftest_doctor_dependencies` / `selftest_cdp_is_ours_uses_socket_owner`, test/validate.sh ~:1121–1230):

### (a) selftest_caller_mode_parallel_owners_distinct_lanes
1. `pidA="$(spawn_sim_owner 600 pi)"`; `stA="$(_pool_get_starttime "$pidA")"`.
2. Body 1 (child `bash`, env `AGENT_BROWSER_POOL_STATE="$outdir/state" AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" AGENT_BROWSER_POOL_OWNER_PID="$pidA" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stA"`): `source lib/pool.sh; pool_config_init; pool_owner_resolve; N_A="$(pool_acquire_locked)"`; print `N_A`; `mkdir -p "$POOL_EPHEMERAL_ROOT/$N_A"` (simulates the post-lock copy so lane presence is observable); print `owner.pid` via `pool_lease_field "$N_A" owner.pid`... **note**: `owner` is a nested object — read it with `jq -r '.owner.pid'` on `"$POOL_LANES_DIR/$N_A.json"` (verify pool_lease_field's nesting support; jq directly on the lease file is the safe path).
3. `pidB="$(spawn_sim_owner 600 claude)"` (vary comm); `stB` likewise.
4. Body 2: same as body 1 but hooks → pidB/stB and a separate `outdir2/state`+`outdir2/active`; prints `N_B` + its `owner.pid`.
5. Main-shell asserts (each `|| return 1`):
   - `N_A` and `N_B` numeric, ≥ 1 (`[[ "$n" =~ ^[1-9][0-9]*$ ]]`)
   - `N_A != N_B` ("two caller-mode owners get distinct lanes")
   - `assert_lane_exists "$N_A"` and `assert_lane_exists "$N_B"` — **CAUTION**: these check the MAIN shell's `$POOL_LANES_DIR` (suite root), but the bodies wrote leases under their own `$outdir/state/lanes`. Assert against the per-body paths instead: `[[ -f "$outdir/state/lanes/$N_A.json" ]]` etc., or export the body's STATE env in an `( … )` subshell before calling assert_lane_exists. Prefer the explicit `-f`/dir checks — simplest and honest.
   - lease A's `owner.pid == pidA`, lease B's `owner.pid == pidB` (jq per above).
6. Kill+`wait` BOTH owners (LM-4), `|| true`-guarded kills; remove both per-body state trees (or leave under `$ABPOOL_TEST_ROOT` — suite-managed).

### (b) selftest_caller_mode_lane_reaped_after_owner_death
1. `pidA="$(spawn_sim_owner 600 pi)"`; `stA`; body 1 (isolated roots) → hooks A → `pool_owner_resolve` → `N="$(pool_acquire_locked)"`; `mkdir -p "$POOL_EPHEMERAL_ROOT/$N"`; print N. Assert lease file + ephemeral dir exist for N (path checks under outdir).
2. In the MAIN shell: `kill "$pidA" 2>/dev/null || true; wait "$pidA" 2>/dev/null || true` — **MANDATORY order: kill → wait → then assert staleness** (LM-4: an unreaped zombie's /proc lingers → false-alive).
3. Body 2 (same isolated roots as body 1!): `source lib; pool_config_init; if pool_lane_is_stale "$N"; then echo STALE; else echo LIVE; fi` → main asserts output == STALE.
4. Continue body 2 (or body 3): spawn owner B in main shell (`pidB="$(spawn_sim_owner 600 claude)"`), run `pool_reap_stale` (or `pool_acquire_locked` with hooks → B, which runs REAP-STALE internally at step 3a). If using acquire-as-B: assert the returned lane's `owner.pid == pidB` and that NO lease anywhere under the state dir has `owner.pid == pidA` (jq sweep). If using `pool_reap_stale` first: assert lease file gone + ephemeral dir gone (`[[ ! -f ... ]] && [[ ! -e .../active/$N ]]` — equivalent to assert_lane_gone but against the body's roots), then acquire as B and assert a valid new lane.
5. Kill+`wait` owner B.

### Success Criteria
- [ ] Both selftests PASS; no other selftest modified or failing.
- [ ] Distinct-lane assertion (N_A != N_B) and per-lane owner.pid identity both hold.
- [ ] Staleness detected after kill+wait; lane fully reaped (lease AND ephemeral dir gone); re-acquire by B succeeds with owner.pid == pidB.
- [ ] Zero orphans: every spawn_sim_owner pid is killed and `wait`ed on every path (pass AND fail).

## All Needed Context

### Context Completeness Check

The implementing agent needs: how pool_acquire_locked claims without Chrome, the tri-state pool_lane_is_stale contract, the hook-based owner simulation, the single-setup selftest framework idioms, the kill→wait ordering landmine, and the per-body isolated state-root pattern. All verified against HEAD and documented below.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: code under test
  pattern: |
    pool_acquire_locked (:2394+): pool_state_init; ( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE".
      Echoes lane N rc 0. CHROME-FREE: claim writes a provisional lease (pool_lease_write ... 0 0 "false"),
      no copy, no ephemeral dir creation.
    _pool_acquire_critical_section (:2265): (a) REAP-STALE+REUSE-ORPHAN per lane via pool_lane_is_stale;
      (c) pool_find_free_lane = lowest N with NO active/<N> dir AND NO lanes/<N>.json; (d) claim.
      ⇒ two sequential acquires with DIFFERENT live owners get DIFFERENT lanes (lane A is leased+dir'd when B acquires).
    pool_lane_is_stale N (:1224): TRI-STATE rc 0=stale / 1=live / 2=no-lease. GOTCHA: under set -e a bare
      call with rc 1/2 ABORTS — guard: `if pool_lane_is_stale "$n"; then ...; fi`.
    pool_reap_stale (:3021): explicit stale sweep (kills chrome pgroup — chrome_pid 0 → no-op —, rm -rf dir, drops lease).
    pool_owner_resolve TEST MODE (~:537-561): AGENT_BROWSER_POOL_OWNER_PID [+ _STARTTIME] wins over everything;
      records ACTUAL /proc comm. This is the sanctioned simulation hook (PRD §2.19).
    _pool_get_starttime PID: canonical starttime extractor.
  gotcha: owner is a NESTED json object — read with jq -r '.owner.pid' on lanes/<N>.json, or verify
    pool_lease_field handles nesting before using it.

- file: test/validate.sh
  why: selftest framework
  pattern: |
    Discovery: compgen -A function | grep '^selftest_' | sort inside _run_selftest_suite (:1252).
      ONE setup() for the whole suite; bodies run in the MAIN shell via `if "$fn"`; every assert ends || return 1.
    spawn_sim_owner [SECONDS=600] [COMM=pi] (:128): echoes pid of live fd-detached sleep-copy whose
      /proc/comm == COMM. mktemp -t abpool-pi.XXXXXX prefix MUST STAY (cleanup trap globs /tmp/abpool-pi.*).
    Per-body isolated-roots idiom (:1086/:1121/:1160/:1230):
      outdir="$ABPOOL_TEST_ROOT/<name>"; script="$outdir/body.sh"; cat >"$script" <<'EOF' ... EOF
      out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" \
            timeout 15 bash "$script" "$ABPOOL_REPO" ... 2>&1)" || rc=$?
    helpers: assert_eq :57 (main-shell only); assert_lane_exists N :67 (lease file in MAIN $POOL_LANES_DIR);
      assert_lane_gone N :74 (lease AND ephemeral dir in main roots) — for body-local roots use explicit -f/-e checks.
    Inter-body sweep (:1268) rm -f "$POOL_LANES_DIR"/*.json — main-shell lanes only; per-body roots are NOT swept,
      so each body must clean up its own leases/dirs (or they live harmlessly under $ABPOOL_TEST_ROOT until the trap).
  gotcha: setup() exports AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME for the suite's sim pi owner. Body scripts
    MUST override BOTH hook vars (PID and STARTTIME) in their invocation env — a stale _STARTTIME with a new
    _PID yields identity mismatch → spurious staleness. Also ABPOOL_CUR_OWNER (LM-6 single slot) tracks only
    setup's owner — your test-spawned owners are YOUR responsibility to kill+wait.

- file: plan/004_de5e94ac127c/P4M2T1S2/PRP.md
  why: PARALLEL item adding selftest_owner_resolves_caller_mode to the same file — assume it exists;
    place the new functions AFTER it (alphabetical sort order will interleave discovery anyway —
    placement is cosmetic; keep them adjacent, after the P4.M2.T1.S1/S2 additions).
  gotcha: do NOT duplicate its resolve-level assertions; this item tests the ACQUIRE/REAP layer.

- file: plan/004_de5e94ac127c/architecture/test_framework.md
  why: landmines LM-4 (kill→wait before staleness asserts; zombie /proc false-alive) and
    LM-6 (ABPOOL_CUR_OWNER single-slot discipline); blessed invocation + static checks.

- file: plan/004_de5e94ac127c/architecture/synthesis.md
  why: §3 test-plan grounding for R5 (this coverage item); confirms hook-based simulation is sanctioned.
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh            # pool_acquire_locked :2394, _pool_acquire_critical_section :2265,
                       # pool_lane_is_stale :1224 (tri-state), pool_reap_stale :3021, TEST MODE :537
test/validate.sh       # selftest framework; spawn_sim_owner :128; setup :204; _run_selftest_suite :1252
```

### Desired Codebase tree

```bash
test/validate.sh       # + selftest_caller_mode_parallel_owners_distinct_lanes (~110-150 lines)
                       # + selftest_caller_mode_lane_reaped_after_owner_death   (~110-150 lines)
                       # each writes body.sh files under $ABPOOL_TEST_ROOT/<name>/ at runtime
```

### Known Gotchas of our Codebase & Library Quirks

```bash
# CRITICAL (LM-4): kill "$pid" then WAIT "$pid" BEFORE any staleness assert — an unreaped zombie's
#   /proc/<pid> persists and pool_lane_is_stale reads the owner as ALIVE (false pass/fail).
# CRITICAL: hooks must be overridden as a PAIR (OWNER_PID + OWNER_STARTTIME) — a mismatched pair
#   fails identity and the lane looks stale immediately.
# CRITICAL: pool_lane_is_stale is TRI-STATE (0 stale / 1 live / 2 no-lease); under set -e guard with
#   `if pool_lane_is_stale "$n"; then ...; fi` inside body scripts.
# GOTCHA: pool_acquire_locked echoes N on stdout — capture with `N="$(pool_acquire_locked)"` and
#   split `local N; N="$(...)"` (SC2155) in the MAIN shell; inside body.sh plain N=$(...) with set -e is fine
#   (rc 1 on exhaustion would exit the body — acceptable: the test expects success).
# GOTCHA: acquire does NOT create active/<N> — body must mkdir it to make "reap removes dir" observable
#   and to make the second owner's find-free-lane skip N.
# GOTCHA: spawn_sim_owner lives in validate.sh only — spawn owners in the MAIN shell, pass pids/starttimes
#   into body.sh via env/argv.
# GOTCHA: kill+wait owners on EVERY exit path (trap or explicit `|| true` kills + unconditional wait of
#   killed pids) — leave zero orphans (AGENTS.md §3).
# GOTCHA: never touch the operator's real state — bodies get AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT
#   under $ABPOOL_TEST_ROOT (already hermetic via setup(), plus per-body subdirs).
# shellcheck: bash; new code adds zero warnings.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD selftest_caller_mode_parallel_owners_distinct_lanes to test/validate.sh
  - PLACEMENT: after selftest_owner_resolves_caller_mode (P4.M2.T1.S2's fn; fall back to after the
    P4.M2.T1.S1 config selftest if S2 hasn't landed). Keep the `# name — description` comment style.
  - STRUCTURE: comment block (why/hooks/Chrome-free note) then:
    locals: outdir1 outdir2 script1 script2 pidA stA pidB stB rc out1 out2 N_A N_B
    pidA="$(spawn_sim_owner 600 pi)";    stA="$(_pool_get_starttime "$pidA" 2>/dev/null || true)"
    pidB="$(spawn_sim_owner 600 claude)"; stB="$(...)"
    NOTE: spawn BOTH up front is fine (both alive, distinct pids — LM-6 only constrains ABPOOL_CUR_OWNER
    bookkeeping, not coexisting owners; you never touch that slot).
    Write body.sh ONCE (parameterless; reads its identity from the hook env the runner sets):
      set -euo pipefail; source "$1/lib/pool.sh"; pool_config_init; pool_owner_resolve
      N="$(pool_acquire_locked)"; [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "BADN:$N"; exit 1; }
      mkdir -p -- "$POOL_EPHEMERAL_ROOT/$N"
      opid="$(jq -r '.owner.pid' "$POOL_LANES_DIR/$N.json")"
      echo "N|$N"; echo "OWNERPID|$opid"
    Runner: rc=0; out1="$(AGENT_BROWSER_POOL_STATE="$outdir1/state" AGENT_CHROME_EPHEMERAL_ROOT="$outdir1/active" \
      AGENT_BROWSER_POOL_OWNER_PID="$pidA" AGENT_BROWSER_POOL_OWNER_STARTTIME="$stA" \
      timeout 15 bash "$script1" "$ABPOOL_REPO" 2>&1)" || rc=$?   — then same for body 2 with pidB/stB.
    IMPORTANT: pool_state_init inside the body creates "$outdir/state/lanes" — mkdir -p "$outdir1/state"
    not needed. Use timeout 15 (bounded per AGENTS.md §2).
    Asserts (|| return 1 after each): rc==0 for both; parse N| and OWNERPID| lines; N_A != N_B;
    N_A/N_B numeric ≥1; OWNERPID lines == pidA/pidB; lease files exist at
    "$outdir1/state/lanes/$N_A.json" and "$outdir2/state/lanes/$N_B.json".
  - CLEANUP (unconditional, before every return): kill pidA pidB (|| true) then wait both (|| true).

Task 2: ADD selftest_caller_mode_lane_reaped_after_owner_death to test/validate.sh
  - PLACEMENT: directly after Task 1's fn.
  - STRUCTURE:
    outdir/script; pidA="$(spawn_sim_owner 600 pi)"; stA=...
    Body 1 (hooks → A, roots → outdir): source lib; config_init; resolve;
      N="$(pool_acquire_locked)"; mkdir -p "$POOL_EPHEMERAL_ROOT/$N"; echo "N|$N".
    Main asserts: rc 0; N numeric; lease file + ephemeral dir "$outdir/active/$N" exist.
    DEATH: kill "$pidA" 2>/dev/null || true; wait "$pidA" 2>/dev/null || true   # LM-4 order!
    Body 2 (hooks → A, SAME roots): source lib; config_init; pool_state_init;
      if pool_lane_is_stale "$N"; then echo STALE; else echo LIVE; fi
    Main asserts output contains STALE.
    pidB="$(spawn_sim_owner 600 claude)"; stB=...
    Body 3 (hooks → B, SAME roots): source lib; config_init; resolve;
      if pool_lane_is_stale "$N"; then pool_reap_stale; echo REAPED; fi
      N2="$(pool_acquire_locked)"; mkdir -p "$POOL_EPHEMERAL_ROOT/$N2"
      echo "N2|$N2"; echo "OWNERPID|$(jq -r '.owner.pid' "$POOL_LANES_DIR/$N2.json")"
      ALSO after reap, echo "OLDGONE|$([[ ! -f $POOL_LANES_DIR/$N.json ]] && [[ ! -e $POOL_EPHEMERAL_ROOT/$N ]] && echo yes || echo no)"
    Main asserts: rc 0; OLDGONE|yes (lane A's lease AND dir gone after reap); N2 numeric;
    OWNERPID == pidB; (N2 may equal N — fine; it is now B's lane.)
    ALTERNATIVE (equally valid): skip explicit pool_reap_stale and let body 3's pool_acquire_locked run
    REAP-STALE internally (step 3a), then assert no lease under "$outdir/state/lanes" has
    owner.pid == pidA (jq sweep) — pick ONE and keep the assertion explicit.
  - CLEANUP: kill+wait pidA (already dead+waited — skip or || true) and pidB.

Task 3: STATIC VALIDATION
  - bash -n test/validate.sh
  - shellcheck -s bash test/validate.sh   (zero NEW warnings)

Task 4: LIVE VALIDATION (isolated sandbox ONLY — AGENTS.md §1/§2)
  - timeout 120 bash test/validate.sh → both new selftests PASS + all pre-existing green
  - pgrep -af 'abpool|sleep' → nothing new left behind
```

### Implementation Patterns & Key Details

```bash
# Body invocation pattern (the load-bearing idiom — per-body isolated roots + hook pair + timeout):
out1="$(AGENT_BROWSER_POOL_STATE="$outdir1/state" \
        AGENT_CHROME_EPHEMERAL_ROOT="$outdir1/active" \
        AGENT_BROWSER_POOL_OWNER_PID="$pidA" \
        AGENT_BROWSER_POOL_OWNER_STARTTIME="$stA" \
        timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?
# Parse: N_A="$(sed -n 's/^N|//p' <<<"$out1")"; opid="$(sed -n 's/^OWNERPID|//p' <<<"$out1")"

# Kill→wait discipline (LM-4) — verbatim before ANY staleness assertion:
kill "$pidA" 2>/dev/null || true
wait "$pidA" 2>/dev/null || true

# Tri-state guard inside bodies (set -e safe):
if pool_lane_is_stale "$N"; then pool_reap_stale; fi
```

### Integration Points

```yaml
NONE:
  - No lib/pool.sh changes (tests existing P4.M1 code).
  - No docs (item contract: DOCS none).
  - No new env vars; no real Chrome; no real state-dir writes (all under $ABPOOL_TEST_ROOT).
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n test/validate.sh
shellcheck -s bash test/validate.sh
# Expected: zero errors, zero NEW warnings.
```

### Level 2: Suite (isolated sandbox only — never the operator's live HOME/state)

```bash
timeout 120 bash test/validate.sh
# Expected: selftest_caller_mode_parallel_owners_distinct_lanes PASS,
#           selftest_caller_mode_lane_reaped_after_owner_death PASS, all others PASS.
```

### Level 3: Leak audit

```bash
pgrep -af 'abpool|agent-browser|sleep' || true
ls /tmp/abpool-* 2>/dev/null || true   # sim-owner bin dirs removed by the suite trap
# Expected: nothing spawned by these selftests remains.
```

### Level 4: Creative / domain-specific
N/A (Chrome-free logic tests).

## Final Validation Checklist

- [ ] `bash -n` clean; `shellcheck -s bash` adds zero warnings
- [ ] `timeout 120 bash test/validate.sh` green in the isolated sandbox (both new + all old selftests)
- [ ] Distinct lanes: N_A != N_B, both numeric ≥ 1, lease owner.pid == pidA / pidB respectively
- [ ] Reap: after kill+wait, pool_lane_is_stale N == STALE; reap removes lease AND ephemeral dir; owner B re-acquires successfully with owner.pid == pidB
- [ ] Every spawned owner killed AND waited on every exit path; zero orphans; no other selftest touched
- [ ] Functions named exactly `selftest_caller_mode_parallel_owners_distinct_lanes` and `selftest_caller_mode_lane_reaped_after_owner_death`

## Anti-Patterns to Avoid

- ❌ Don't assert staleness before `wait`ing the killed owner (zombie /proc → false-alive, LM-4)
- ❌ Don't override only `AGENT_BROWSER_POOL_OWNER_PID` — always the (PID, STARTTIME) pair
- ❌ Don't call `pool_lane_is_stale` bare under set -e (tri-state rc 1/2 aborts the body)
- ❌ Don't assert against the main-shell `$POOL_LANES_DIR` for body-local leases — use the body's own outdir paths
- ❌ Don't re-call setup() or spawn per-test setup owners (AGENTS.md §4 single-setup discipline)
- ❌ Don't run validate.sh against the operator's live state dirs — isolated sandbox only
- ❌ Don't boot real Chrome — pool_acquire_locked is claim-only; the mkdir simulates the copy step