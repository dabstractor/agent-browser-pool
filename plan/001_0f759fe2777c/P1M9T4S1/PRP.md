# PRP — P1.M9.T4.S1: Transparency checklist — verify the invisible pooling contract

> **Scope flag.** This is a **TEST-ONLY** PRP (PRD §2.18 / §2.15). Its sole output is a NEW
> file `test/transparency.sh` (+ this PRP). It adds **zero** source/lib/bin changes. It
> validates that an agent following the upstream `agent-browser` skill to the letter still
> lands on — and stays on — its locked ephemeral lane, and **cannot tell** pooling is happening.
>
> **Runs in parallel with P1.M9.T3.S1** (release/stale-reaper tests). Treat
> `test/release_reaper.sh` (P1.M9.T3.S1's output) as a **CONTRACT**: this PRP reuses its
> LANDED helpers + single-setup runner pattern, and does NOT duplicate its
> `test_close_is_disconnect_only` (single-owner, bare `close`). Item (g) here is a NEW,
> multi-owner `close --all` scope test (see §"item g is NOT a dup").

---

## Goal

**Feature Goal**: Prove, via automated tests, that `bin/agent-browser` (the transparent
wrapper, `pool_wrapper_main`) satisfies every clause of PRD §2.15 "the no-idea contract" —
an agent issuing the exact commands the upstream skill teaches (`skills get core`, `open`,
`connect <port>`, `--session <X>`, `close --all`, …) is silently routed to its own lane and
can neither detect nor escape the pool.

**Deliverable**: `test/transparency.sh` — a hand-rolled bash test file with **8 `test_*`
bodies** (one per checklist item a–h) + a **single-setup runner** `_abpool_run_transparency_suite`.
It SOURCES the landed framework `test/validate.sh` (P1.M9.T1.S1) for assertions + owner engine
+ hermetic `setup/teardown`, but BYPASSES `run_test`/`abpool_run_suite` (they call `setup()`
per-test → 3rd-call HANG in this sandbox — AGENTS.md §4). Run via `timeout 900 bash test/transparency.sh`.

**Success Definition**: the suite exits 0 with **all 8 transparency checks passing**, leaves
**zero** orphan Chrome/`sleep`/`pi`/`timeout` processes, and removes **all** its temp roots
(`pgrep -af 'user-data-dir='` empty; no `/tmp/abpool-test.*` or `abpool-test-eph.*` left). It
does NOT duplicate any assertion already in `test/release_reaper.sh`.

---

## User Persona

**Target User**: the agent-browser-pool maintainer / CI (the operator running validation).
**Use Case**: gate a release on "the pool is truly invisible." Run the suite; green = the
transparency contract holds; red = a specific clause regressed.
**User Journey**: `timeout 900 bash test/transparency.sh` → per-test `== test_<name>` / `PASS`
lines → `N passed, 0 failed`.
**Pain Points Addressed**: the §2.15 contract is currently UN-tested end-to-end; a regression
in dispatch/normalize/session-override would silently break transparency with no signal.

---

## Why

- PRD §2.15 is the product's central promise ("the no-idea contract") and the LAST untested
  milestone (P1.M9.T4 is the only `Researching` item left in M9). Without it, the MVP's claim
  of invisibility is unverified.
- These tests cover the `bin/agent-browser` wrapper's **classification + normalization +
  session-override** seams (lib/pool.sh:3030 `pool_dispatch_classify`, :3091
  `pool_normalize_close`, :3218 `pool_normalize_connect`, :3291 `pool_strip_session_args`,
  :3369 `pool_force_session`) — code paths the concurrency/release suites do NOT exercise
  (those drive the lib's acquire/boot/release directly, never through the wrapper's arg rewrite).
- Builds on P1.M9.T1.S1's framework (assertions, `spawn_sim_owner`, hermetic `setup`) and
  P1.M9.T3.S1's host-proven real-env helper (`_release_setup_real_env`), so it is cheap to
  write and high-signal.

---

## What

A single bash file `test/transparency.sh` that, when executed directly, runs **one** `setup()`
and 8 `test_*` bodies in the MAIN shell, each verifying one §2.15 clause:

| item | clause (PRD §2.15) | verification shape |
|------|--------------------|--------------------|
| (a) | `agent-browser skills get core` → passthrough (unaffected) | byte-equal stdout: `$WRAPPER skills get core` vs `$REAL_BIN skills get core` |
| (b) | `--help` / `--version` → passthrough | byte-equal stdout, both flags |
| (c) | `open <url>` zero-prep → my lane | backgrounded `open` (timeout-bounded); poll → lane acquired (status) |
| (d) | 2nd `open` same owner → SAME lane N | `pool_lease_find_mine` returns N both times (reuse, not re-acquire) |
| (e) | `connect <random>` → routed to my lane (arg ignored) | unit: `pool_normalize_connect` strips the arg; integ: my lane N unchanged |
| (f) | `--session <X> open <url>` → forced to `abpool-<N>` | lease `.session` == `abpool-<N>` and ≠ `<X>` |
| (g) | `close --all` → only MY lane's daemon closed; peers unaffected | unit: `--all` stripped (`POOL_CLOSE_ALL_SEEN==1`); integ: peer lane+Chrome survive |
| (h) | next agent (distinct PID) → different lane; no collision | two distinct owners → N≠M, both live |

### Success Criteria
- [ ] `timeout 900 bash test/transparency.sh` exits 0.
- [ ] All 8 `test_*` bodies PASS.
- [ ] `shellcheck -s bash test/transparency.sh` is clean; `bash -n` passes.
- [ ] Zero orphan processes / temp roots after the run.
- [ ] No assertion duplicated from `test/release_reaper.sh`.

---

## All Needed Context

### Context Completeness Check
A maintainer who has NEVER seen this repo can implement this from: the PRD §2.15/§2.4 clauses
(quoted below), the exact wrapper functions to exercise (file:line), the framework helpers to
reuse (file:line), the proven precedent file to mirror (`test/release_reaper.sh`), and the
two pivotal gotchas (open-may-hang → poll-then-kill; single-setup constraint). All provided.

### Documentation & References
```yaml
# --- PRD (READ-ONLY; the contract being verified) ---
- url: PRD.md#2.15
  why: "the 8 transparency clauses (the no-idea contract) — each maps 1:1 to a test_* body."
  critical: "close --all → 'cannot harm other agents' lanes' = the MULTI-owner scope test (item g)."
- url: PRD.md#2.4
  why: "the wrapper lifecycle (steps 0–5): dispatch → resolve → find/acquire → ensure → normalize → override → exec."
  critical: "META short-circuits at step 0 BEFORE owner resolution; session force is step 5 (after acquire)."

# --- the SUT: the wrapper functions each item exercises (lib/pool.sh) ---
- file: lib/pool.sh:3451  (pool_wrapper_main)
  why: "the lifecycle orchestrator. item (a/b) hit step c (meta passthrough); (c/d/f) hit e→f→h→i; (e/g) hit g→h→i; (h) hits e."
  pattern: "exec is TERMINAL (process replacement) — code AFTER `exec \"$POOL_REAL_BIN\"` is unreachable."
  gotcha: "the lane is acquired+booted+connected+lease-written BEFORE the exec ⇒ observable via status/lease even while a driving cmd runs."
- file: lib/pool.sh:3030  (pool_dispatch_classify)
  why: "META set = {--help|-h|--version (short-circuit FIRST), 'session list', skills|dashboard|plugin|mcp}. items (a),(b)."
  gotcha: "META returns 0 ALWAYS and reads NO globals → pure; meta short-circuits BEFORE owner resolve."
- file: lib/pool.sh:3091  (pool_normalize_close)   # item (g)
  why: "strips every --all from a close; sets POOL_CLOSE_ALL_SEEN=1. The --all that would nuke ALL daemon sessions is neutralized."
- file: lib/pool.sh:3218  (pool_normalize_connect) # item (e)
  why: "strips the FIRST non-flag positional after connect (the <port|url>). 'connect 12345' → bare 'connect'."
  gotcha: "bare connect is a RUNTIME ERROR in the real binary — verify ROUTING+STRIPPING, not the bare-connect rc."
- file: lib/pool.sh:3291  (pool_strip_session_args) # item (f)
  why: "removes every --session <X> / --session=<X>; writes POOL_CLEAN_ARGS."
- file: lib/pool.sh:3369  (pool_force_session)       # item (f)
  why: "export AGENT_BROWSER_SESSION=abpool-<N>. Combined with strip → env is the SOLE session source."
- file: bin/agent-browser  (the shim)
  why: "ABPOOL_WRAPPER = this file. It exec's into pool_wrapper_main; the real binary it exec's is \$POOL_REAL_BIN."

# --- the FRAMEWORK to SOURCE (P1.M9.T1.S1 output — the input contract) ---
- file: test/validate.sh
  why: "source for: _fail, assert_eq, assert_lane_exists/gone, assert_no_chrome, assert_no_dir, spawn_sim_owner, setup/teardown (hermetic mktemp + trap), the BASH_SOURCE gate."
  pattern: "symlink-safe bootstrap: VALIDATE_DIR=$(cd $(dirname $(readlink -f $BASH_SOURCE)) && pwd); source \$VALIDATE_DIR/validate.sh"
  gotcha: "setup() is process-spawning; calling it a 3rd time HANGS this sandbox (AGENTS.md §4) ⇒ use the SINGLE-SETUP runner, NOT run_test/abpool_run_suite."

# --- the PRECEDENT to MIRROR (P1.M9.T3.S1 output — copy these helpers verbatim, rename prefix) ---
- file: test/release_reaper.sh:67   (_release_setup_real_env)
  why: "the host-proven real-env fix: resolve REAL home via getent passwd; override AGENT_CHROME_MASTER (real master or minimal), AGENT_BROWSER_REAL (real binary), RELOCATE AGENT_CHROME_EPHEMERAL_ROOT to a btrfs temp dir (/tmp is tmpfs here → cp --reflink=always pool_die's); append to ABPOOL_SIM_BINS; re-run pool_config_init."
  pattern: "COPY this verbatim as _transparency_setup_real_env. It is the ONLY correct way to make the wrapper's exec(\$POOL_REAL_BIN) work under the temp HOME."
- file: test/release_reaper.sh:118  (_release_acquire_boot)
  why: "acquire+boot a lane for the CURRENT owner: pool_owner_resolve → pool_acquire_locked → (port==0) pool_boot_lane; echoes N."
- file: test/release_reaper.sh:154  (_test_spawn_owner)
  why: "spawn a FRESH live pi owner per body; export OWNER_PID/_STARTTIME; set ABPOOL_CUR_OWNER; pool_owner_resolve (refresh globals in THIS shell). Echoes pid."
  pattern: "per-body owners (NOT setup's shared one) — items (h) need 2; (g) needs a peer; bodies are order-independent."
- file: test/release_reaper.sh:140  (_release_kill_owner_and_reap_zombie)
  why: "kill+wait to REAP the zombie so /proc/<pid> clears (a zombie's comm may still read 'pi' → false-alive)."
- file: test/release_reaper.sh:376  (_abpool_run_release_reaper_suite)
  why: "the SINGLE-SETUP runner to mirror: ONE setup(); kill setup's unused owner; for fn in test_*: `if \"\$fn\"; then` in the MAIN shell (NO subshell); inter-body release all + kill owner; ONE teardown()."
  gotcha: "bodies run in the MAIN shell so a `return 1` from an assert is the fn's rc (FAIL→continue) AND the EXIT trap does NOT fire mid-suite (temp root survives all bodies)."

# --- the AGENTS.md rules (non-negotiable safety) ---
- file: AGENTS.md
  why: "§1 no Chrome/suite during planning (static only); §2 timeout every subprocess; §3 reap process GROUPS + wait zombies; §4 single-setup (≤1 process-spawning setup()); never kill -0 for liveness."
```

### Current Codebase tree (relevant subset)
```
bin/agent-browser          # the wrapper shim (ABPOOL_WRAPPER) → pool_wrapper_main
bin/agent-browser-pool     # admin CLI (release/reap/status) — used for inter-body cleanup
lib/pool.sh                # the SUT: dispatch/normalize/session + acquire/boot/release
test/validate.sh           # FRAMEWORK (P1.M9.T1.S1) — assertions + spawn_sim_owner + setup
test/concurrency.sh        # PRECEDENT: parallel-distinct-lanes + the 'open may hang' note
test/release_reaper.sh     # PRECEDENT (P1.M9.T3.S1): helpers + single-setup runner to MIRROR
test/transparency.sh       # ← NEW (this PRP)
```

### Desired file: `test/transparency.sh` — responsibility map
```
test/transparency.sh
 ├─ bootstrap: resolve repo dir (readlink -f), source ./validate.sh  (defines helpers + setup)
 ├─ _transparency_setup_real_env   # COPY of _release_setup_real_env (real master+binary+btrfs)
 ├─ _transparency_acquire_boot     # COPY of _release_acquire_boot
 ├─ _transparency_spawn_owner      # COPY of _test_spawn_owner  (rename to avoid clashes if sourced together)
 ├─ _transparency_kill_owner       # COPY of _release_kill_owner_and_reap_zombie
 ├─ _transparency_run_open_bg      # NEW: poll-then-kill driver for open (items c/d/f)
 ├─ test_passthrough_skills        # (a)
 ├─ test_passthrough_help_version  # (b)
 ├─ test_open_zero_prep_lands_lane # (c)
 ├─ test_second_open_reuses_lane   # (d)
 ├─ test_connect_random_ignored    # (e)
 ├─ test_session_override_forced   # (f)
 ├─ test_close_all_scoped_no_peer_harm  # (g)
 ├─ test_next_agent_distinct_lane  # (h)
 ├─ _abpool_run_transparency_suite # the SINGLE-SETUP runner (mirror _abpool_run_release_reaper_suite)
 └─ BASH_SOURCE==0 gate → run suite
```

### Known Gotchas of our codebase & Library Quirks
```bash
# 1. wrapper exec is TERMINAL. `bin/agent-browser open <url>` may NOT exit (the real agent-browser
#    can stay foregrounded). ⇒ NEVER `wait` a wrapper-driven open bare. Use poll-then-kill (§Impl).
# 2. setup() is process-spawning; the 3rd call HANGS this sandbox (AGENTS.md §4). ⇒ ONE setup() per
#    FILE (single-setup runner). NEVER use run_test/abpool_run_suite.
# 3. under temp HOME, POOL_REAL_BIN = $TEMP_HOME/.local/bin/agent-browser (NONEXISTENT) ⇒ every
#    exec fails. ⇒ MUST call _transparency_setup_real_env (override AGENT_BROWSER_REAL + btrfs root).
# 4. /tmp is tmpfs here ⇒ `cp --reflink=always` pool_die's ⇒ MUST relocate ephemeral root to btrfs.
# 5. a killed child is a ZOMBIE until waited ⇒ always kill+wait (a zombie's comm may read 'pi').
# 6. never kill -0 for liveness (ESRCH vs EPERM conflation); use pgrep / curl /json/version.
# 7. set -e: guard every rc-1 lib call (pool_acquire_locked, pool_lease_field, pool_lease_find_mine)
#    with `if ! …; then` or `|| `. `(( 0 ))` as a STATEMENT aborts; use it only in `if`/`while`.
# 8. bare `connect` (after arg strip) errors in the real binary — do NOT assert on its rc; assert
#    ROUTING (find_mine→N) + STRIPPING (unit-check POOL_NORM_ARGS).
# 9. Chrome is launched via setsid (own session) ⇒ killing the wrapper does NOT kill Chrome. Chrome
#    is the POOL's (reaped by `release all`); do NOT expect wrapper kill to clean Chrome.
```

---

## Implementation Blueprint

### Data models / structure
None new. This PRP reads the LANDED lease model via the lib: `pool_lease_field N port|session|owner.pid`,
`pool_lanes_list`, `pool_lease_find_mine`. No structs/types (bash).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE test/transparency.sh — bootstrap + copied helpers
  - IMPLEMENT: shebang `#!/usr/bin/env bash` + `set -euo pipefail`; header doc-comment block
    (PRD §2.15; the 'open may hang' gotcha; the SINGLE-SETUP constraint; sources validate.sh).
  - BOOTSTRAP (mirror test/concurrency.sh:24 + test/release_reaper.sh:49):
      TRANSPARENCY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
      # shellcheck source=./validate.sh
      source "$TRANSPARENCY_DIR/validate.sh"
  - COPY (verbatim, rename prefix _release→_transparency) from test/release_reaper.sh:
      _transparency_setup_real_env  (lines 67-110)   # real master+binary+btrfs ephemeral root
      _transparency_acquire_boot    (lines 118-131)  # pool_owner_resolve→acquire→boot; echo N
      _transparency_spawn_owner     (lines 154-172)  # fresh pi owner; export env; refresh globals
      _transparency_kill_owner      (lines 140-143)  # kill+wait (reap zombie)
  - FOLLOW pattern: test/release_reaper.sh (the LANDED, host-proven precedent).
  - NAMING: prefix EVERY local helper with `_transparency_` (avoid collision if a future
    aggregator sources multiple test files in one shell).
  - GOTCHA: do NOT call setup() here (the runner does, exactly once).

Task 2: IMPLEMENT _transparency_run_open_bg — the poll-then-kill open driver (items c/d/f)
  - WHY: a wrapper-driven `open` may not exit (§gotcha 1). The lane is acquired+booted+connected
    and the lease WRITTEN before the terminal exec ⇒ observable while open runs.
  - BODY (pseudo — make it real, guarded for set -e):
      _transparency_run_open_bg() {
          # $@ = wrapper args (e.g. "open about:blank" or "--session agent-x open about:blank")
          # Background the wrapper under a HARD timeout (AGENTS.md §2). >/dev/null 2>&1 (we assert
          # on the LANE, not open's output). $! = the `timeout` job (kills its child on expiry).
          timeout --signal=KILL 25 "$ABPOOL_WRAPPER" "$@" >/dev/null 2>&1 &
          TRANSPARENCY_BG_PID=$!
      }
      _transparency_wait_my_lane() {   # poll pool_lease_find_mine up to ~20s; echo N or rc 1
          local deadline lane
          deadline=$(( $(date +%s) + 20 ))
          lane=""
          while (( $(date +%s) < deadline )); do
              if lane="$(pool_lease_find_mine 2>/dev/null)" && [[ -n "$lane" ]]; then
                  printf '%s\n' "$lane"; return 0
              fi
              sleep 0.3
          done
          return 1
      }
      _transparency_reap_bg() {        # kill + wait the bg timeout job (Chrome survives; pool owns it)
          [[ -n "${TRANSPARENCY_BG_PID:-}" ]] || return 0
          kill "$TRANSPARENCY_BG_PID" 2>/dev/null || true
          wait "$TRANSPARENCY_BG_PID" 2>/dev/null || true
          TRANSPARENCY_BG_PID=""
      }
  - URL: use `about:blank` (local, no network, fastest nav, least flake).
  - GOTCHA: every poll/reap helper ends `|| true`; the bodies use explicit `|| return 1`.

Task 3: IMPLEMENT items (a) + (b) — META passthrough (NO Chrome, fast, deterministic)
  - test_passthrough_skills:  # (a) agent-browser skills get core → passthrough
      _transparency_setup_real_env || return 1
      _transparency_spawn_owner >/dev/null       # a pi ancestor IS present; meta ignores it
      local w r
      w="$(timeout 15 "$ABPOOL_WRAPPER" skills get core 2>/dev/null || true)"
      r="$(timeout 15 "$POOL_REAL_BIN"  skills get core 2>/dev/null || true)"
      assert_eq "$r" "$w" "skills get core: wrapper output == real binary output (passthrough)" || return 1
  - test_passthrough_help_version:  # (b) --help, --version → passthrough
      same shape, TWO sub-checks: `--help` and `--version` (loop or two assert_eq blocks).
  - WHY EQUALITY not CONTENT: agent-browser version output varies; the contract is the wrapper
    does NOT alter it. The wrapper's config/state init logs to a FILE (POOL_LOG_PATH), not stdout.
  - GOTCHA: meta short-circuits in pool_dispatch_classify (lib/pool.sh:3036) BEFORE owner resolve,
    so the pi ancestor env is irrelevant here — but set it anyway to prove meta wins regardless.

Task 4: IMPLEMENT items (c) + (d) + (f) — DRIVING lane assignment (poll-then-kill)
  - test_open_zero_prep_lands_lane:  # (c) open <url> zero-prep → my lane
      _transparency_setup_real_env || return 1
      _transparency_spawn_owner >/dev/null
      _transparency_run_open_bg open about:blank
      local N
      N="$(_transparency_wait_my_lane)" || { _transparency_reap_bg; _fail "no lane acquired for open"; return 1; }
      assert_lane_exists "$N" || { _transparency_reap_bg; return 1; }
      # the lane is LIVE (status shows it). Reap the bg open; release cleans Chrome.
      _transparency_reap_bg
  - test_second_open_reuses_lane:  # (d) 2nd open same owner → SAME N (reuse)
      _transparency_setup_real_env || return 1
      _transparency_spawn_owner >/dev/null
      _transparency_run_open_bg open about:blank
      local N1 N2
      N1="$(_transparency_wait_my_lane)" || { _transparency_reap_bg; _fail "1st open no lane"; return 1; }
      _transparency_reap_bg                       # let the 1st open finish/be-killed; Chrome stays
      _transparency_run_open_bg open about:blank
      N2="$(_transparency_wait_my_lane)" || { _transparency_reap_bg; _fail "2nd open no lane"; return 1; }
      _transparency_reap_bg
      assert_eq "$N1" "$N2" "2nd open reuses the SAME lane (find_mine, not re-acquire)" || return 1
  - test_session_override_forced:  # (f) --session <X> open → forced abpool-<N> (≠ X)
      _transparency_setup_real_env || return 1
      _transparency_spawn_owner >/dev/null
      local X="agent-evil-7777" N sess
      _transparency_run_open_bg --session "$X" open about:blank
      N="$(_transparency_wait_my_lane)" || { _transparency_reap_bg; _fail "no lane for --session open"; return 1; }
      _transparency_reap_bg
      sess="$(pool_lease_field "$N" session 2>/dev/null)" || sess=""
      assert_eq "abpool-$N" "$sess" "lane $N session forced to abpool-$N" || return 1
      [[ "$sess" != *"$X"* ]] || { _fail "agent's --session '$X' LEAKED into lease session '$sess'"; return 1; }
  - GOTCHA: pool_lease_field is rc 1 on missing/corrupt → guard `|| sess=""`. Chrome from a bg'd
    open survives wrapper kill (setsid) — the runner's inter-body `release all` reaps it.

Task 5: IMPLEMENT items (e) + (g) — DRIVING normalization
  - test_connect_random_ignored:  # (e) connect <random> → my lane, arg ignored
      # LAYER 1 (deterministic unit of the pure normalizer — no Chrome):
      pool_normalize_connect connect 98765 >/dev/null
      local found=0 t
      for t in "${POOL_NORM_ARGS[@]}"; do [[ "$t" == "98765" ]] && found=1; done
      [[ "$found" -eq 0 ]] || { _fail "connect arg 98765 NOT stripped from POOL_NORM_ARGS"; return 1; }
      # LAYER 2 (routing): with a live lane N, a wrapper `connect <random>` must NOT move us off N.
      _transparency_setup_real_env || return 1
      _transparency_spawn_owner >/dev/null
      local N before after
      before="$(_transparency_acquire_boot)" || return 1     # acquire+boot lane N (lib direct)
      timeout --signal=KILL 15 "$ABPOOL_WRAPPER" connect 98765 >/dev/null 2>&1 || true
      after="$(pool_lease_find_mine 2>/dev/null || true)"
      assert_eq "$before" "$after" "connect <random> kept us on lane $before (arg ignored)" || return 1
  - test_close_all_scoped_no_peer_harm:  # (g) close --all → MY daemon only; PEER unaffected
      # LAYER 1 (unit): --all is stripped + flagged.
      POOL_CLOSE_ALL_SEEN=0
      pool_normalize_close close --all >/dev/null
      assert_eq "1" "${POOL_CLOSE_ALL_SEEN:-0}" "close --all set POOL_CLOSE_ALL_SEEN=1" || return 1
      local t allgone=1
      for t in "${POOL_NORM_ARGS[@]}"; do [[ "$t" == "--all" ]] && allgone=0; done
      [[ "$allgone" -eq 1 ]] || { _fail "--all NOT stripped from close POOL_NORM_ARGS"; return 1; }
      # LAYER 2 (multi-owner scope): peer lane+Chrome survive MY close --all.
      _transparency_setup_real_env || return 1
      # owner A (me) + owner B (peer) — distinct PIDs/starttimes.
      local A B NA NB portB leaseB
      A="$(_transparency_spawn_owner)"; NA="$(_transparency_acquire_boot)" || return 1
      B="$(_transparency_spawn_owner)"; NB="$(_transparency_acquire_boot)" || return 1
      assert_lane_exists "$NA"; assert_lane_exists "$NB"
      portB="$(pool_lease_field "$NB" port 2>/dev/null)" || portB=""
      # switch back to owner A, run its close --all through the wrapper (scoped to abpool-NA).
      export AGENT_BROWSER_POOL_OWNER_PID="$A"
      export AGENT_BROWSER_POOL_OWNER_STARTTIME="$(_pool_get_starttime "$A")"
      pool_owner_resolve
      timeout --signal=KILL 15 "$ABPOOL_WRAPPER" close --all >/dev/null 2>&1 || true
      # PEER lane B MUST still be alive (Chrome responds; lease present).
      assert_lane_exists "$NB" || { _fail "peer lane $NB lease gone after my close --all"; return 1; }
      curl -sf "http://127.0.0.1:${portB}/json/version" >/dev/null 2>&1 \
          || { _fail "peer Chrome (port $portB) died after my close --all — --all was NOT scoped"; return 1; }
  - GOTCHA (e): bare connect errors in the real binary → ignore its rc (|| true); assert ROUTING.
  - GOTCHA (g): the wrapper exec's `"$POOL_REAL_BIN" --session abpool-NA close` (after strip+force)
    → only A's daemon. NB's daemon is a SEPARATE session ⇒ survives. This is the §2.15 "cannot harm
    peers" proof. NOT a dup of release_reaper's test_close_is_disconnect_only (single-owner, bare close).

Task 6: IMPLEMENT item (h) — next agent → next lane (sequential, 2 owners)
  - test_next_agent_distinct_lane:
      _transparency_setup_real_env || return 1
      local A B NA NB
      A="$(_transparency_spawn_owner)"; NA="$(_transparency_acquire_boot)" || return 1
      B="$(_transparency_spawn_owner)"; NB="$(_transparency_acquire_boot)" || return 1
      assert_lane_exists "$NA"; assert_lane_exists "$NB"
      [[ "$NA" != "$NB" ]] || { _fail "two distinct owners got the SAME lane $NA (collision!)"; return 1; }
      assert_eq "$A" "$(pool_lease_field "$NA" owner.pid 2>/dev/null)" "lane NA owned by A" || return 1
      assert_eq "$B" "$(pool_lease_field "$NB" owner.pid 2>/dev/null)" "lane NB owned by B" || return 1
  - NOTE: SEQUENTIAL (no parallel subshells) ⇒ no wait-hang risk. Distinct owners via distinct
    spawn_sim_owner PIDs+starttimes. Reuses the concurrency suite's LESSON, not its parallelism.

Task 7: IMPLEMENT _abpool_run_transparency_suite (MIRROR _abpool_run_release_reaper_suite)
  - ONE `setup` (the ONLY process-spawning setup call). Kill+reap setup's unused owner.
  - for fn in $(compgen -A function | grep '^test_' | sort): `if "$fn"; then` (MAIN shell, NO
    subshell). PASS/FAIL tally. Inter-body backstop: `"$ABPOOL_ADMIN" release all || true` +
    `_transparency_kill_owner "$ABPOOL_CUR_OWNER"`.
  - ONE `teardown`. Print `N passed, M failed`. Return 1 iff any failed.
  - BASH_SOURCE==0 gate at EOF: `if ! _abpool_run_transparency_suite; then exit 1; fi`.

Task 8: STATIC validation (PLANNING-safe; AGENTS.md §1 — no Chrome, no suite)
  - bash -n test/transparency.sh            # syntax (never blocks)
  - shellcheck -s bash test/transparency.sh # lint (never blocks)
  - Fix every shellcheck warning before the hermetic run.
```

### Implementation Patterns & Key Details
```bash
# (P1) META passthrough = BYTE-EQUAL stdout (NOT content — version output varies):
w_out="$(timeout 15 "$ABPOOL_WRAPPER"  <args> 2>/dev/null || true)"
r_out="$(timeout 15 "$POOL_REAL_BIN"   <args> 2>/dev/null || true)"
assert_eq "$r_out" "$w_out" "wrapper == real binary (passthrough)" || return 1

# (P2) poll-then-kill for a driving `open` (it may not exit):
_transparency_run_open_bg open about:blank          # bg under `timeout --signal=KILL 25`
N="$(_transparency_wait_my_lane)" || { _transparency_reap_bg; _fail ...; return 1; }
assert_lane_exists "$N"; _transparency_reap_bg       # Chrome survives (setsid); release all reaps it

# (P3) read lease fields the rc-1-safe way (pool_lease_field is rc 1 on missing/corrupt):
sess="$(pool_lease_field "$N" session 2>/dev/null)" || sess=""

# (P4) the single-setup runner body loop (MAIN shell, no subshell, no per-test setup):
for fn in $(compgen -A function | grep '^test_' | sort); do
    printf '== %s\n' "$fn"
    if "$fn"; then ABPOOL_PASS=$((ABPOOL_PASS+1)); printf '   PASS\n'
    else ABPOOL_FAIL=$((ABPOOL_FAIL+1)); ABPOOL_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
    "$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true       # inter-body backstop
    [[ -n "${ABPOOL_CUR_OWNER:-}" ]] && _transparency_kill_owner "$ABPOOL_CUR_OWNER"
    ABPOOL_CUR_OWNER=""
done

# (P5) EVERY body ends with its lanes released (the backstop does it) + owner killed — so the
# suite leaves ZERO orphan Chrome/sleep/pi. The EXIT trap (validate.sh) reaps the temp roots +
# the btrfs ephemeral dirs (appended to ABPOOL_SIM_BINS by _transparency_setup_real_env).
```

### Integration Points
```yaml
FILES_ADDED:
  - test/transparency.sh           # NEW (this PRP). Executable: chmod +x.
FILES_READ (not modified):
  - test/validate.sh               # sourced (framework)
  - test/release_reaper.sh         # pattern source (copy helpers, rename prefix)
  - lib/pool.sh                    # the SUT (pool_dispatch_classify / normalize_* / strip/force / acquire)
  - bin/agent-browser              # ABPOOL_WRAPPER (the wrapper under test)
  - bin/agent-browser-pool         # ABPOOL_ADMIN (release all for cleanup)
NO CHANGES TO: lib/, bin/, install.sh, PRD.md, .gitignore, any tasks.json.
```

---

## Validation Loop

### Level 1: Syntax & Style (PLANNING-safe — run after writing; never blocks)
```bash
bash   -n test/transparency.sh             # syntax check
shellcheck -s bash test/transparency.sh    # lint
# Expected: zero errors. Fix every SC* warning (esp. SC2155, SC2086, SC2310) before Level 2.
```

### Level 2: Hermetic suite run (VALIDATION — isolated temp tree + btrfs root + trap)
```bash
# The framework's setup() redirects HOME/state/ephemeral to a mktemp root; _transparency_setup_real_env
# relocates the ephemeral root to btrfs + points POOL_REAL_BIN at the real binary. Every subprocess is
# `timeout`-bounded (AGENTS.md §2); the EXIT trap reaps all temp roots (AGENTS.md §3).
timeout 900 bash test/transparency.sh
echo "exit=$?"
# Expected: exit 0, "8 passed, 0 failed".
```

### Level 3: No-leak audit (AGENTS.md §3 — MANDATORY after the run)
```bash
pgrep -af 'user-data-dir=' || echo "no pool Chrome (good)"     # zero pool Chrome
pgrep -af 'abpool' || echo "no abpool processes (good)"        # zero sleep/pi/timeout/agent-browser
ls -d /tmp/abpool-test.* "$HOME/abpool-test-eph."* 2>/dev/null || echo "no leftover temp roots (good)"
# Expected: every line prints the "(good)" fallback — ZERO orphans, ZERO leftover dirs.
```

### Level 4: No-duplication cross-check (g vs release_reaper)
```bash
# Confirm item (g) is genuinely NEW (multi-owner close --all scope) vs the PREVIOUS item's
# single-owner bare-close test:
grep -n 'test_close_is_disconnect_only' test/release_reaper.sh   # single-owner, bare close, close!=release
grep -n 'test_close_all_scoped_no_peer_harm' test/transparency.sh  # MULTI-owner, --all strip, peer survives
# Expected: two DISTINCT tests; (g) asserts a PEER lane survives (release_reaper's has no peer).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `bash -n test/transparency.sh` passes.
- [ ] `shellcheck -s bash test/transparency.sh` clean.
- [ ] `timeout 900 bash test/transparency.sh` exits 0; "8 passed, 0 failed".
- [ ] Level-3 audit: zero orphan Chrome/`sleep`/`pi`/`timeout`/`agent-browser`; zero leftover temp roots.

### Feature Validation (one PASS per §2.15 clause)
- [ ] (a) `skills get core` wrapper output == real binary output (passthrough).
- [ ] (b) `--help` and `--version` wrapper output == real binary output (passthrough).
- [ ] (c) zero-prep `open` lands a live lane (status shows it).
- [ ] (d) 2nd `open` reuses the SAME lane N (find_mine, not re-acquire).
- [ ] (e) `connect <random>` keeps the owner on lane N; arg stripped from POOL_NORM_ARGS.
- [ ] (f) `--session <X> open` forces lease.session == `abpool-<N>` and ≠ `<X>`.
- [ ] (g) `close --all` strips `--all` (`POOL_CLOSE_ALL_SEEN==1`) + a PEER lane+Chrome survive.
- [ ] (h) two distinct owners get two DISTINCT lanes (no collision).

### Code Quality Validation
- [ ] Mirrors `test/release_reaper.sh` structure/helpers (single-setup runner, copied real-env helper).
- [ ] Every local helper prefixed `_transparency_` (no cross-file name clashes).
- [ ] Every rc-1 lib call (`pool_acquire_locked`, `pool_lease_field`, `pool_lease_find_mine`) guarded.
- [ ] Every blocking subprocess `timeout`-bounded; every bg pid killed + `wait`-reaped.
- [ ] ONE `setup()` per file (single-setup runner); NO `run_test`/`abpool_run_suite` call.
- [ ] No assertion duplicated from `test/release_reaper.sh`.

### Documentation & Deployment
- [ ] Header doc-comment explains: §2.15 contract, the 'open may hang' gotcha, the single-setup
      constraint, and that it SOURCES validate.sh + MIRRORS release_reaper.sh.
- [ ] `chmod +x test/transparency.sh`.

---

## Anti-Patterns to Avoid
- ❌ Don't `wait` a wrapper-driven `open` bare (it may not exit → hang). Poll-then-kill.
- ❌ Don't call `setup()` (or `run_test`/`abpool_run_suite`) more than ONCE per file (3rd-call HANG).
- ❌ Don't run bodies in `( … )` subshells (the EXIT trap fires mid-suite → deletes the shared temp root).
- ❌ Don't assert on `skills`/`--help`/`--version` CONTENT (version-dependent); assert EQUALITY (passthrough).
- ❌ Don't assert on the bare-`connect` rc (it errors in the real binary); assert ROUTING + STRIPPING.
- ❌ Don't reuse `test_close_is_disconnect_only` — item (g) is a NEW multi-owner `--all` scope test.
- ❌ Don't skip `_transparency_setup_real_env` (temp HOME → POOL_REAL_BIN nonexistent → every exec fails).
- ❌ Don't leave a bg `open`/`timeout` un-reaped (AGENTS.md §3); kill+wait every bg pid.
- ❌ Don't use `kill -0` for liveness (ESRCH/EPERM conflation); use pgrep / `curl /json/version`.

---

## Confidence Score: 8/10
- The wrapper seams to test (dispatch/normalize/strip/force) are LANDED + pure + well-documented in
  lib/pool.sh; the framework + precedent helpers are LANDED + host-proven (copy, don't reinvent).
- Risk集中 in the poll-then-kill `open` driver (item c/d/f): whether `open` exits fast or hangs is
  version/host-dependent; the design is robust to BOTH (timeout + poll + kill), but a single live run
  at validation is needed to confirm timing (the 20s poll / 25s timeout bounds are generous headroom).
- The META equality + unit-layer (e1/g1) assertions are deterministic and carry most of the signal.
