# PRP — P1.M6.T3.S1: `pool_wrapper_main()` — wire the complete request lifecycle (dispatch → resolve → find/acquire → boot → ensure → normalize → strip/force → exec)

---

## Goal

**Feature Goal**: Implement **`pool_wrapper_main()`** — the single orchestration entry point
that turns `bin/agent-browser` into a transparent browser pool. It is PRD §2.4 steps 0→5 in one
function: classify the command → resolve the owning `pi` process → find-or-acquire an ephemeral
lane → boot it (if provisional) → ensure it is connected → normalize the agent's argv (close
`--all` + connect positional) → strip the agent's `--session` + force `AGENT_BROWSER_SESSION` →
`exec` the real `agent-browser` against the agent's lane. Every driving invocation is routed to a
locked, booted, connected ephemeral lane; every non-driving / human-terminal invocation passes
through to the real binary **unchanged**. The function is **terminal by design** — all success
paths end in `exec` (process replacement, no return); all fatal paths end in `pool_die` (exit 1).

**Deliverable**: ONE new public function — **`pool_wrapper_main()`** — appended to `lib/pool.sh`
under a NEW `# Wrapper shim — complete lifecycle (P1.M6.T3.S1)` banner at EOF (currently line
3391, directly after `pool_force_session`). **NO edits to any existing function.** This task is
**lib-only**: `bin/agent-browser` is created by the sibling **P1.M6.T3.S2** (which `source`s
`lib/pool.sh` then calls `pool_wrapper_main "$@"`); this PRP's DOCS step is satisfied by the
`# ===` banner + contract comment block above the function (every other function in the file
follows that pattern — see scout-conventions §4).

**Success Definition** — after `set -euo pipefail; source lib/pool.sh`, `pool_wrapper_main` is
defined and routes every input class correctly. Verified WITHOUT launching Chrome (the rc-1/abort
paths are testable with test-hook env vars + `AGENT_BROWSER_POOL_DISABLE`), the driving happy-path
is verified by a `bash -n`/`shellcheck` clean function whose structure matches the CONTRACT steps
a→k:

| invocation (as `bin/agent-browser` would call it) | `pool_wrapper_main "$@"` outcome | how to verify (no Chrome needed) |
|---|---|---|
| `--help` / `-h` / `--version` / `skills get core` / `session list` | `exec "$POOL_REAL_BIN" "$@"` **unchanged** (classify → `meta`) | `AGENT_BROWSER_POOL_OWNER_PID=1` stub `$POOL_REAL_BIN` → captures original args verbatim |
| `AGENT_BROWSER_POOL_DISABLE=1 open https://x` | `exec "$POOL_REAL_BIN" "$@"` **unchanged** (safety valve) | unset owner pid; stub real bin → original args |
| `open https://x` with **no `pi` ancestor** (human terminal) | `exec "$POOL_REAL_BIN" "$@"` **unchanged** (step d passthrough) | unset `AGENT_BROWSER_POOL_OWNER_PID`; stub → original args |
| `--session evil open https://x` (driving, pooled owner) | `exec "$POOL_REAL_BIN" open https://x` with `AGENT_BROWSER_SESSION=abpool-<N>` | full lifecycle (needs Chrome — see Level 3) |

- **Terminal correctness**: NO code path through `pool_wrapper_main` returns normally on success
  — every success path ends in `exec "$POOL_REAL_BIN" …` (process replaced). Fatal paths use
  `pool_die` (exit 1). There is no `return` on the success path.
- **set -e safety**: EVERY helper that returns non-zero intentionally (`pool_lease_find_mine`,
  `pool_acquire_locked`, `pool_wait_for_lane`, `pool_lease_field`, `pool_boot_lane`,
  `pool_ensure_connected`, `pool_force_session`) is called in an errexit-exempt context
  (`if … then`, `|| pool_die`, `|| { … }`). NO bare call, NO `local N="$(…)"` (SC2155 / BashFAQ 105
  masking trap) — every lane capture is **split** (`local N; N="$(…)"` inside an `if`).
- **Lane flows via STDOUT, not globals**: `pool_lease_find_mine` / `pool_acquire_locked` /
  `pool_wait_for_lane` print the lane number `N` to stdout and set **NO global** (scout-lifecycle
  §1 — verified: `grep POOL_FOUND_LANE|POOL_ACQUIRED_LANE lib/pool.sh` → no matches). The wrapper
  captures it via `N="$(…)"`.
- **Boot-vs-adopt decision**: after `pool_acquire_locked` (or `pool_wait_for_lane`), read the
  lane's `port` via `pool_lease_field "$N" port`; if `"0"` / empty / `"null"` → the lease is
  **provisional** → call `pool_boot_lane "$N"`; else the lane is an **adopted orphan** (already
  booted, port>0) → **skip boot**, go straight to ensure-connected (scout-lifecycle §5, §7;
  `pool_boot_lane` CALLER CONTRACT).
- **Argv pipeline**: `$@` → `pool_normalize_close` → `POOL_NORM_ARGS` (array) →
  `pool_normalize_connect "${POOL_NORM_ARGS[@]}"` → `POOL_NORM_ARGS` (overwritten) →
  `pool_strip_session_args "${POOL_NORM_ARGS[@]}"` → `POOL_CLEAN_ARGS` (array) →
  `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"`. (scout-lifecycle "Global-array pipeline".)
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero warnings
  — same bar as the M6.T2.S1 baseline); all prior deliverables (M1–M6.T2.S1) unchanged + callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its sole consumer is the
**P1.M6.T3.S2** `bin/agent-browser` shim, which is:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.17; scout-conventions §9)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"
```

(T3.S2's verbatim contract — scout-conventions §9. `pool_wrapper_main "$@"` is the **last**
statement; the shim runs nothing after it. The lib's top-of-file `set -euo pipefail`
(@lib/pool.sh:18) propagates into the shim's shell by sourcing, so `pool_wrapper_main` runs under
strict mode.) **Unit tests (M9)** are the second consumer — they source `lib/pool.sh` and drive
`pool_wrapper_main` through the dispatch/passthrough branches with stubbed `$POOL_REAL_BIN` + the
test-hook env vars (`AGENT_BROWSER_POOL_OWNER_PID`, `AGENT_BROWSER_POOL_DISABLE`).

**Use Case**: An AI agent (a `pi` child) invokes `agent-browser` hundreds of times per task via
stateless bash calls, exactly as `skills get core` teaches. The FIRST driving call
(`agent-browser open <url>`) must transparently land on a fresh ephemeral lane (acquire → boot →
connect → exec). EVERY subsequent driving call by the SAME agent must reuse that SAME lane
(find-mine → ensure-connected → exec) — across many independent bash processes, with no flag/port
to remember. A human typing `agent-browser` in a terminal (no `pi` ancestor) must get the raw
upstream tool, untouched. A `skills get core` / `--help` / `session list` call must pass through
unchanged so the agent's skill-lookup and help still work. This function is the wire that makes
all of that hold (PRD §2.15 "no idea" contract).

**Pain Points Addressed**:
- **Stateless bash calls would otherwise each spawn a fresh browser.** The wrapper's find-mine
  step (PRD §2.4 step 2) recognizes the SAME owner across calls and reuses its lane → one browser
  per agent for the whole session.
- **Agents would collide without lane assignment.** The acquire step (step 3) hands each agent a
  distinct lane; the next agent gets the next free one (PRD §1.3 goal 3).
- **Agents would bypass their lane via `--session` / `AGENT_BROWSER_SESSION`.** The strip+force
  step (step 5) neutralizes both (delegated to M6.T2.S1's pair).
- **`close --all` would nuke peer agents' lanes.** The normalize step scopes it to the caller's
  own lane (delegated to M6.T1.S2).
- **A human in a terminal would get pooled by mistake.** The owner-resolve step (step 1) detects
  "no `pi` ancestor" and passes through unchanged.

## Why

- **This IS PRD §2.4 (the entire request lifecycle) + §2.15 (the transparency contract).** Every
  step in §2.4's numbered list (0 parse/dispatch → 1 resolve owner → 2 find my lease → 3 acquire
  → 4 ensure connected → 5 exec) is one block in `pool_wrapper_main`. §2.15's checklist
  (`--session <x> …` → forced to my lane; `close --all` → cannot harm peers; zero prep → my lane;
  same browser across calls) is the observable behavior this function produces.
- **It is the integration capstone of Milestone P1.M6.** M6.T1.S1 (classify) + M6.T1.S2
  (normalize close/connect) + M6.T2.S1 (strip/force session) are all argv transforms that
  `pool_wrapper_main` calls in order. M2 (owner resolve), M3 (lease find), M4 (copy/port/launch/
  connect), M5 (acquire/boot/ensure/release/reap/reuse/wait) are the lifecycle layers it
  orchestrates. Nothing else in M6 composes them — this task is the ONLY place the full pipeline
  is wired (scout-conventions §5: `grep pool_wrapper_main` → no existing references).
- **It is deliberately the FIRST `exec` in the library.** scout-conventions §5 verified: no
  `exec "$POOL_REAL_BIN"` exists anywhere in `lib/pool.sh` today (all current references are
  non-exec subprocess invocations in `pool_daemon_connect`/@1645, `pool_daemon_connected`/@1703,
  `pool_release_lane`/@2468). This task introduces the three passthrough `exec`s
  (POOL_DISABLE / meta / no-pi-ancestor) + the terminal driving `exec` — all process-replacing
  (external-bash §1: `exec` overwrites the image; PID stays; exported env inherited).
- **It must NOT duplicate sibling work.** It does NOT classify (M6.T1.S1 landed @3030), does NOT
  normalize (M6.T1.S2 landed @3139/@3210), does NOT strip/force session (M6.T2.S1 landed @3314/
  @3380), does NOT resolve/acquire/boot/ensure (M2/M3/M5 landed). It ONLY wires them in the PRD
  §2.4 order + adds the lane-capture + boot-vs-adopt + passthrough-exit glue.

## What

User-visible behavior: none directly (an internal function). The observable contract is the
**routing** `bin/agent-browser` (T3.S2) gains once it calls `pool_wrapper_main "$@"`. Given
`set -euo pipefail; source lib/pool.sh`, `pool_wrapper_main "$@"` behaves per the step list
(CONTRACT a→k, authoritative from `tasks.json` P1.M6.T3.S1 `context_scope`):

### `pool_wrapper_main "$@"` — the lifecycle

```
a. pool_config_init ; pool_state_init          # freeze POOL_* globals; rc 0 or pool_die
b. if POOL_DISABLE == "1"  → exec "$POOL_REAL_BIN" "$@"   # safety valve, UNCHANGED args
c. class="$(pool_dispatch_classify "$@")"      # rc 0 ALWAYS (no guard); prints meta|driving
   if class == "meta"     → exec "$POOL_REAL_BIN" "$@"   # passthrough UNCHANGED (skills/--help/...)
d. pool_owner_resolve                          # rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ no pi)
   if POOL_OWNER_PID == "0" → exec "$POOL_REAL_BIN" "$@" # human in terminal → UNCHANGED
e. if N="$(pool_lease_find_mine)"; then        # rc 0 found / 1 none (MUST guard); stdout = lane N
      : # reuse lane N → goto h (ensure connected)
   else
f.    if N="$(pool_acquire_locked)"; then      # rc 0/1 (MUST guard); stdout = provisional/adopted lane
      else
         if ! N="$(pool_wait_for_lane)"; then  # rc 0/1 (MUST guard); exhaustion
            pool_die "agent-browser-pool: no lane available after ${POOL_WAIT}s + force-reap"
         fi
      fi
g.    # boot-vs-adopt: read the lane's port (rc 0/1 — MUST guard)
      port="$(pool_lease_field "$N" port)" || port=""
      if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
         # provisional lease (port=0) → boot it (copy+port+launch+connect). rc 1 ⇒ dropped lane.
         pool_boot_lane "$N" || pool_die "agent-browser-pool: boot failed for lane $N"
      fi
      # else: adopted orphan (port>0, already booted) → SKIP boot
   fi
h. pool_ensure_connected "$N" || pool_die "agent-browser-pool: lane $N not connected; aborting"
                                               # rc 0/1 (MUST guard); reconnect/relaunch self-heal
i. pool_normalize_close  "$@"                  # rc 0 ALWAYS; sets POOL_NORM_ARGS + POOL_CLOSE_ALL_SEEN
   pool_normalize_connect "${POOL_NORM_ARGS[@]}" # rc 0 ALWAYS; overwrites POOL_NORM_ARGS
j. pool_strip_session_args "${POOL_NORM_ARGS[@]}" # rc 0 ALWAYS; sets POOL_CLEAN_ARGS
   pool_force_session "$N" || pool_die "agent-browser-pool: bad lane '$N' for session"
                                               # rc 0/1 (MUST guard); exports AGENT_BROWSER_SESSION=abpool-<N>
   [[ "${POOL_CLOSE_ALL_SEEN:-0}" == "1" ]] && \
      _pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"
k. exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"   # TERMINAL: process replaced; env inherited
```

**Hard invariants** (every input, every call):
- **TERMINAL on success.** All four `exec` sites (steps b, c, d, k) replace the process — code
  after any of them is unreachable. There is **no `return` on the success path**. Fatal paths use
  `pool_die` (→ `exit 1`, external-bash §8 — correct for a sourced lib: kills the sourcing
  `bin/agent-browser` process loudly).
- **`POOL_DISABLE` is checked AFTER `pool_config_init`** (CONTRACT step a then b). `pool_config_init`
  (@lib/pool.sh:173-176) freezes `POOL_DISABLE` from `AGENT_BROWSER_POOL_DISABLE` (bool "1" ⇒ on).
  So step b reads the FROZEN global, not the raw env var. (scout-conventions §6.)
- **Lane is STDOUT-only — capture with split `local N; N="$(…)"` inside an `if`.** Verified
  (scout-lifecycle §1): `pool_lease_find_mine` (@1003), `pool_acquire_locked` (@2043),
  `pool_wait_for_lane` (@2909) all `printf '%s\n' "$N"` and set NO global. NEVER `local N="$(…)"`
  (SC2155 — `local`'s own rc 0 masks the function's rc 1; BashFAQ 105). The `if N="$(…)"` form
  keeps rc 1 set -e-safe (the condition is just false).
- **Boot-vs-adopt is decided by `pool_lease_field "$N" port`.** A PROVISIONAL lease (from
  `pool_acquire_locked`'s choose-N path) has `port=0, chrome_pid=0, connected=false`
  (scout-lifecycle §5); an ADOPTED orphan (from the reuse-orphan path) has `port>0` already
  booted. The wrapper MUST boot the former and SKIP boot for the latter — `pool_boot_lane` on an
  already-booted lane would re-copy/re-launch (wasteful + racy). `pool_lease_field` (@876) is
  rc 0/1 non-fatal (returns 1 on missing/corrupt lease) → MUST guard with `|| port=""`.
  (scout-lifecycle §5/§7; `pool_boot_lane` CALLER CONTRACT @2228.)
- **`pool_boot_lane` rc 1 means the lane was DROPPED.** Its contract (@2185): on every recoverable
  failure it calls `_pool_release_lane_internals "$lane"` THEN `return 1`. So a rc-1 boot leaves NO
  lane to fall back on → the wrapper MUST `pool_die` (no silent retry that would re-enter acquire
  with the same exhausted state). (`pool_die` is the CONTRACT-consistent fatal exit.)
- **`pool_ensure_connected` rc 1 means the lane is unusable but NOT dropped.** Its contract
  (@2288): NEVER drops the lane (no `_pool_release_*`) — on failure returns 1 and leaves
  lease+chrome as-is (wrapper/reaper's job). The wrapper's `pool_die` surfaces the failure; the
  stale lane is reaped on the agent's NEXT acquire (M5.T3 reaper is lazy). Do NOT retry in-place.
- **Every passthrough `exec` passes the ORIGINAL `"$@"` unchanged.** Steps b/c/d use
  `exec "$POOL_REAL_BIN" "$@"` (NOT the normalized/cleaned arrays) — a meta command or a
  human-terminal call must see EXACTLY what the user typed (PRD §2.4 step 0 "exec real binary
  unchanged"; §2.15 "`skills get core` → passthrough (unaffected)"). ONLY step k (driving) uses the
  cleaned `"${POOL_CLEAN_ARGS[@]}"`.
- **`_pool_log` style**: prefix `pool_wrapper_main:` (mirrors `pool_owner_resolve`/@521,
  `pool_boot_lane`/@2236, `pool_ensure_connected`/@2295 — scout-conventions §7). Log on OUTCOMES /
  decisions (passthrough reason, lane acquired/booted/reused, close-`--all` interception), NOT a
  generic "entered" line (scout-conventions §7: happy-path logging minimal).

### Success Criteria

- [ ] `pool_wrapper_main()` defined (PUBLIC, no `_` prefix) under a NEW
      `# Wrapper shim — complete lifecycle (P1.M6.T3.S1)` banner appended at EOF (after
      `pool_force_session`, currently line 3391).
- [ ] Callable after `source lib/pool.sh`; `type pool_wrapper_main` reports a function.
- [ ] **Step a→b**: `pool_config_init; pool_state_init` run first; then if `POOL_DISABLE=="1"`
      → `exec "$POOL_REAL_BIN" "$@"` (original args). Verifiable: `AGENT_BROWSER_POOL_DISABLE=1`
      + stubbed `$POOL_REAL_BIN` → wrapper execs the stub with the ORIGINAL args verbatim.
- [ ] **Step c**: `class="$(pool_dispatch_classify "$@")"` (no guard); `class=="meta"` →
      `exec "$POOL_REAL_BIN" "$@"` (original args). Verifiable: `--help`/`skills get core`/
      `session list` → stub captures original args.
- [ ] **Step d**: `pool_owner_resolve`; `POOL_OWNER_PID=="0"` → `exec "$POOL_REAL_BIN" "$@"`
      (original args). Verifiable: unset `AGENT_BROWSER_POOL_OWNER_PID` (no pi ancestor in test
      shell) → stub captures original args (no pooling).
- [ ] **Step e**: `if N="$(pool_lease_find_mine)"; then` (split capture + `if` guard — rc 1 does
      NOT abort). Found → skip to step h (no acquire, no boot).
- [ ] **Step f**: not found → `if N="$(pool_acquire_locked)"; then` (split capture + guard); else
      `if ! N="$(pool_wait_for_lane)"; then pool_die …; fi` (split capture + guard; exhaustion →
      `pool_die`).
- [ ] **Step g**: after acquire/wait, read `port="$(pool_lease_field "$N" port)" || port=""`; if
      `port` ∈ {`"0"`, empty, `"null"`} → `pool_boot_lane "$N" || pool_die …`; else (adopted
      orphan, port>0) → SKIP boot.
- [ ] **Step h**: `pool_ensure_connected "$N" || pool_die …` (guard; rc 1 → fatal).
- [ ] **Step i**: `pool_normalize_close "$@"` then `pool_normalize_connect "${POOL_NORM_ARGS[@]}"`
      (both rc 0 ALWAYS — no guard).
- [ ] **Step j**: `pool_strip_session_args "${POOL_NORM_ARGS[@]}"` (rc 0 ALWAYS) then
      `pool_force_session "$N" || pool_die …` (guard; rc 1 → fatal — bad lane). If
      `POOL_CLOSE_ALL_SEEN=="1"` → `_pool_log` the interception.
- [ ] **Step k**: `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (TERMINAL; original `--session`
      stripped; `AGENT_BROWSER_SESSION=abpool-<N>` exported + inherited).
- [ ] **NO `return` on any success path** — all four exits are `exec` (process replacement) or
      `pool_die` (exit 1). The function is terminal.
- [ ] **set -e safety**: no bare call of any rc-0/1 helper; no `local N="$(…)"`. Every lane
      capture is `local N; … if N="$(…)"`.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file);
      all prior deliverables (M1–M6.T2.S1) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **authoritative step list** (CONTRACT a→k,
verbatim from `tasks.json` `context_scope`); the **lane-via-stdout fact** (scout-lifecycle §1 —
verified `grep` for `POOL_FOUND_LANE`/`POOL_ACQUIRED_LANE` → no matches; capture must be split
`local N; N="$(…)"` inside `if`); the **boot-vs-adopt decision tree** (scout-lifecycle §5/§7 +
`pool_boot_lane` CALLER CONTRACT @2228 — read `port` via `pool_lease_field`; boot iff
port∈{0,empty,null}); the **rc taxonomy** (scout-lifecycle table — which helpers are rc-0-always
[no guard] vs rc-0/1 [MUST guard] vs `pool_die`-fatal [propagates]); the **terminal-exec / no-return
contract** (external-bash §1/§2 — `exec` replaces the process; `pool_die`'s `exit 1` is correct
for a sourced lib; no `return` on success); the **passthrough-original-args invariant** (steps b/c/d
use `"$@"` UNCHANGED; only step k uses `"${POOL_CLEAN_ARGS[@]}"`); the **argv-array pipeline**
(`POOL_NORM_ARGS` → strip → `POOL_CLEAN_ARGS`); the **symlink-safe sourcing** note for T3.S2
(external-bash §3 — NOT this task, but the function's sole caller); the **`_pool_log` style**
(`pool_wrapper_main:` prefix, log outcomes not entry); and a copy-pasteable, host-verified
validation script (Level 2) that exercises the passthrough branches with a stubbed `$POOL_REAL_BIN`
+ the test-hook env vars (no Chrome needed).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 (the ENTIRE request lifecycle — steps 0→5 ARE this function's body). §2.4 "Transparent
        absorption" bullets (connect arg ignored; --session override; close --all scoped). §2.15
        transparency checklist (the "no idea" contract — every row is an observable this function
        produces). §2.17 coexistence (the wrapper vs the real binary; symlink on PATH).
  pattern: §2.4's numbered steps 0-5 map 1:1 to CONTRACT steps a-k. The "exec real binary unchanged"
        / "exec real binary with AGENT_BROWSER_SESSION=abpool-<N> forced" clauses ARE the four exec
        sites.
  gotcha: §2.4 step 0 says META "→ exec real binary unchanged" — that means ORIGINAL "$@", NOT
        normalized. Only the driving path (step 5) uses the cleaned argv.

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M6T3S1/research/scout-lifecycle-functions.md
  why: §1 the per-function integration contract (signature / rc / stdout / globals set) for ALL NINE
        helpers pool_wrapper_main calls. §1 ⚠️ CRITICAL CORRECTION: lane is STDOUT-only (NOT a
        global) — pool_lease_find_mine / pool_acquire_locked / pool_wait_for_lane print N, set NO
        global; capture MUST be split local N; N="$(…)" inside if. The "Architecture" pipeline
        diagram (STEP 0→5) IS the function skeleton. The rc-taxonomy table IS the guard map.
  pattern: the STEP 0→5 pseudocode block IS the implementation (adapt to CONTRACT a→k ordering).
  gotcha: §1 — local N="$(…)" (SC2155) masks errexit; bare N="$(…)" aborts under set -e on rc 1;
        ONLY `if N="$(…)"` is correct.
- file: plan/001_0f759fe2777c/P1M6T3S1/research/scout-conventions.md
  why: §1 _pool_log signature (variadic, space-joined, file+stderr). §2 pool_die (exit 1, stderr
        only). §3 header/strict-mode (set -euo pipefail @line 18). §4 banner format (# + 77 '=').
        §5 NO existing exec / NO existing main — pool_wrapper_main is the FIRST exec in the lib.
        §6 POOL_REAL_BIN (@147, frozen by config_init) + POOL_DISABLE (@176). §7 log style
        (funcname: prefix, outcomes not entry). §8 bin/ is .gitkeep-only (T3.S2 creates the shim).
        §9 the T3.S1 vs T3.S2 boundary (this task is LIB-ONLY) + the verbatim T3.S2 shim contract.
  pattern: §4 banner + §7 log style + §9 "pool_wrapper_main is appended after pool_force_session".
  gotcha: §5 — there is NO prior exec to copy; the four exec sites are NEW. §9 — do NOT create
        bin/agent-browser in this task (T3.S2).
- file: plan/001_0f759fe2777c/P1M6T3S1/research/external-bash-wrapper.md
  why: §1 exec semantics (process replaced, PID stays, exported env inherited by the exec'd binary —
        confirms AGENT_BROWSER_SESSION set by pool_force_session IS seen by $POOL_REAL_BIN). §2
        return-vs-exit in a SOURCED lib (pool_die's exit 1 kills the sourcing bin/agent-browser —
        correct; NO return on the success path because there's no caller state to resume). §3
        symlink-safe self-resolution for the T3.S2 SHIM (NOT this task — but the function's sole
        consumer; keep the resolutions separate: the shim resolves ITS OWN path to find lib/pool.sh;
        pool_config_init resolves POOL_REAL_BIN). §4 the set -e gotcha family (if-guard / ||-list
        are errexit-exempt; local x="$(…)" masks; (( i++ )) returns 1 when 0). §5 the rbenv/pyenv/
        rustup/nvm dispatch-shim precedents (classify → exec-passthrough-OR-do-work). §"Recommended
        skeleton" a near-complete pool_wrapper_main to adapt.
  pattern: §4's guard patterns (if N="$(…)"; … || pool_die) ARE the wrapper's error handling.
        §"Recommended skeleton" is the starting point (reconcile its ordering with CONTRACT a→k).
  gotcha: §1 caveat — never run exec inside $(…) or a pipe (the export would die in a subshell
        before the real binary starts). §4 — (( )) only in conditions; counters use i=$((i+1)).

# Architecture
- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §1.3 the Session/Connection special-handling table rows ARE the step-i/j contract:
        "agent-browser --session <X> <cmd> → Override --session to abpool-<N>. Strip the agent's
        --session flag." / "agent-browser connect [<x>] → ensure my lane connected; ignore the arg."
        / "agent-browser close [--all] → disconnect my lane's daemon only." This function delegates
        those to M6.T1.S2 + M6.T2.S1 but OWNS the ordering (normalize → strip → force → exec).
  pattern: §1.3 table rows = the step-i/j delegation.
  gotcha: §1.3 — the connect positional is stripped by M6.T1.S2 (leaving bare `connect`); the
        wrapper does NOT exec a bare `connect` — pool_ensure_connected already bound the daemon.

# The LANDED siblings whose outputs this task CONSUMES (treated as CONTRACT)
- file: plan/001_0f759fe2777c/P1M6T1S1/PRP.md   # pool_dispatch_classify (M6.T1.S1 — LANDED @3030)
  why: step c. Its contract: rc 0 ALWAYS; prints EXACTLY one token `meta` or `driving` to stdout;
        reads ONLY $@ (no config globals — callable BEFORE pool_config_init, though CONTRACT orders
        config first). Classification: --help/-h/--version → meta; `session list` (two-word) → meta;
        cmd ∈ {skills,dashboard,plugin,mcp} → meta; everything else → driving.
  pattern: `class="$(pool_dispatch_classify "$@")"` (no guard); `[[ "$class" == "meta" ]] && exec …`.
  gotcha: classify is PURE — but CONTRACT step a (config_init) runs first anyway (POOL_DISABLE needs it).
- file: plan/001_0f759fe2777c/P1M6T1S2/PRP.md   # pool_normalize_close/connect (M6.T1.S2 — LANDED @3139/@3210)
  why: step i. Their contract: BOTH rc 0 ALWAYS; stdout EMPTY; BOTH write the global ARRAY
        `POOL_NORM_ARGS` (the second OVERWRITES the first's output); `pool_normalize_close` ALSO
        sets scalar `POOL_CLOSE_ALL_SEEN` (1 iff ≥1 `--all` stripped from a `close` cmd).
        pool_normalize_close strips standalone `--all` from `close` (prevents nuking peers);
        pool_normalize_connect strips the SINGLE positional after `connect` (real connect owned by
        pool_ensure_connected). The wrapper MUST chain them: normalize_close "$@" → read
        ${POOL_NORM_ARGS[@]} into normalize_connect → read ${POOL_NORM_ARGS[@]} into strip.
  pattern: `pool_normalize_close "$@"; pool_normalize_connect "${POOL_NORM_ARGS[@]}"`.
  gotcha: after connect-normalize a bare `connect` may result — do NOT exec it (pool_ensure_connected
        bound the daemon in step h). POOL_CLOSE_ALL_SEEN gates the interception log line.
- file: plan/001_0f759fe2777c/P1M6T2S1/PRP.md   # pool_strip_session_args + pool_force_session (M6.T2.S1 — LANDED @3314/@3380)
  why: step j. Their contract: pool_strip_session_args rc 0 ALWAYS; sets global ARRAY POOL_CLEAN_ARGS
        (every --session removed); pool_force_session rc 0/1 non-fatal; exports
        AGENT_BROWSER_SESSION=abpool-<lane>. The wrapper chains: strip "${POOL_NORM_ARGS[@]}" → read
        ${POOL_CLEAN_ARGS[@]} into the exec; force "$N" (guard rc 1 → pool_die).
  pattern: `pool_strip_session_args "${POOL_NORM_ARGS[@]}"; pool_force_session "$N" || pool_die …`.
  gotcha: strip reads $@ (the wrapper PASSES ${POOL_NORM_ARGS[@]} as its $@); force's export persists
        in the calling shell + is inherited by the step-k exec (external-bash §1).

# The LANDED lifecycle layers this task ORCHESTRATES (treated as CONTRACT)
- file: lib/pool.sh   # pool_config_init @126 + pool_state_init @202 (step a)
  why: config freezes POOL_DISABLE (@176), POOL_REAL_BIN (@147), POOL_WAIT (@170), POOL_LANES_DIR,
        POOL_LOCK_FILE. state_init idempotently mkdirs lanes/ + touches acquire.lock. Both rc 0 or
        pool_die. pool_acquire_locked (@2043) calls pool_state_init itself, but CONTRACT orders BOTH
        at step a (so POOL_DISABLE is frozen before step b's check).
- file: lib/pool.sh   # pool_owner_resolve @478 (step d)
  why: rc 0 ALWAYS (never fatal); sets POOL_OWNER_PID (==0 ⇒ no pi ancestor ⇒ passthrough),
        POOL_OWNER_COMM, POOL_OWNER_STARTTIME. Reads test-hook env AGENT_BROWSER_POOL_OWNER_PID.
- file: lib/pool.sh   # pool_lease_find_mine @1003 (step e)
  why: rc 0 found / 1 none (non-fatal); prints lane N to stdout on match, EMPTY on no-match; sets NO
        global. Reads POOL_OWNER_PID (must be numeric, else return 1). PRECONDITION: config_init +
        owner_resolve. MUST guard: `if N="$(pool_lease_find_mine)"; then`.
- file: lib/pool.sh   # pool_acquire_locked @2043 (step f)
  why: rc 0 success (provisional-claim OR orphan-adopt) / 1 (exhaustion / passthrough owner);
        prints lane N to stdout; sets NO global. PRECONDITION: config_init + owner_resolve. The
        returned lane is PROVISIONAL (port=0) unless it was an adopted orphan (port>0). MUST guard.
- file: lib/pool.sh   # pool_wait_for_lane @2909 (step f fallback)
  why: rc 0 (acquired during poll OR after force-reap) / 1 (exhaustion); prints lane N to stdout;
        sets NO global. Reads POOL_WAIT (config global). PRECONDITION: same as acquire_locked. MUST
        guard. On rc 1 (true exhaustion) the wrapper pool_die's.
- file: lib/pool.sh   # pool_lease_field @876 (step g)
  why: rc 0/1 non-fatal predicate; reads ONE field from lane N's lease via jq; returns 1 on
        missing/corrupt/non-numeric lane. Used to read `port` for the boot-vs-adopt decision. MUST
        guard: `port="$(pool_lease_field "$N" port)" || port=""`.
- file: lib/pool.sh   # pool_boot_lane @2185 (step g) + CALLER CONTRACT @2228
  why: arg = LANE; rc 0 (provisioned) / 1 (recoverable: port-exhausted / CDP-timeout / connect-fail
        → drops the lane via _pool_release_lane_internals THEN return 1) / pool_die (fatal:
        copy_master non-btrfs, chrome instant-exit). PRECONDITION: config_init + state_init + a
        PROVISIONAL lease (port=0). On rc 1 the lane is GONE → wrapper pool_die's (no retry).
- file: lib/pool.sh   # pool_ensure_connected @2288 (step h)
  why: arg = LANE; rc 0 (was-already/reconnected/relaunched) / 1 (failure — NEVER drops the lane) /
        pool_die (chrome instant-exit on relaunch). PRECONDITION: a BOOTED lease (port>0). The
        per-invocation self-heal (PRD §2.4 step 4). MUST guard: `|| pool_die`.
- file: lib/pool.sh   # pool_die @30 + _pool_log @39 (error/log helpers)
  why: pool_die → printf stderr + exit 1 (correct for sourced lib). _pool_log → variadic,
        space-joined, file + stderr, `funcname:` prefix convention.
```

### Current Codebase tree

After **M1–M6.T2.S1** have landed, `lib/pool.sh` (3391 lines) ends with `pool_force_session`
(@3380; closing brace = EOF @3391). The **M6.T3.S1** deliverable appends `pool_wrapper_main` under
its OWN banner after `pool_force_session`. `bin/` is still `.gitkeep`-only (T3.S2 populates it):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6.T3.S2 creates bin/agent-browser)
├── lib/
│   └── pool.sh                           # ends (after M6.T2.S1) with pool_force_session at EOF @3391.
│                                         #   Banner order at EOF (after M6.T1.S1 + M6.T1.S2 + M6.T2.S1):
│                                         #   # Wrapper shim — command dispatch (P1.M6.T1.S1)    @2973
│                                         #   pool_dispatch_classify                             @3030
│                                         #   # Wrapper shim — arg normalization (P1.M6.T1.S2)   @3088
│                                         #   pool_normalize_close / pool_normalize_connect      @3139/@3210
│                                         #   # Wrapper shim — session override (P1.M6.T2.S1)    @3263
│                                         #   pool_strip_session_args / pool_force_session       @3314/@3380
│                                         #   # Wrapper shim — complete lifecycle (P1.M6.T3.S1)   ← THIS TASK (append here)
│                                         #   pool_wrapper_main
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M6T2S1/PRP.md
    └── P1M6T3S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{scout-lifecycle-functions,scout-conventions,external-bash-wrapper}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a NEW banner section at EOF:
                  #   # Wrapper shim — complete lifecycle (P1.M6.T3.S1)   ← NEW banner
                  #   pool_wrapper_main [--] ARGS...:
                  #     a. pool_config_init + pool_state_init (rc 0 | pool_die)
                  #     b. POOL_DISABLE==1  → exec "$POOL_REAL_BIN" "$@"          (passthrough, UNCHANGED)
                  #     c. classify=="meta" → exec "$POOL_REAL_BIN" "$@"          (passthrough, UNCHANGED)
                  #     d. POOL_OWNER_PID==0 → exec "$POOL_REAL_BIN" "$@"         (human terminal, UNCHANGED)
                  #     e. if N="$(pool_lease_find_mine)"  → reuse (goto h)
                  #     f. else N="$(pool_acquire_locked)" || N="$(pool_wait_for_lane)" || pool_die
                  #     g.      port="$(pool_lease_field "$N" port)" || port=""
                  #            [[ port in {0,"",null} ]] && pool_boot_lane "$N" || pool_die   (provisional→boot)
                  #     h. pool_ensure_connected "$N" || pool_die
                  #     i. pool_normalize_close "$@" ; pool_normalize_connect "${POOL_NORM_ARGS[@]}"
                  #     j. pool_strip_session_args "${POOL_NORM_ARGS[@]}" ; pool_force_session "$N" || pool_die
                  #     k. exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"          (TERMINAL; env inherited)
                  #   (CONSUMES globals: POOL_DISABLE, POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT,
                  #    POOL_NORM_ARGS, POOL_CLOSE_ALL_SEEN, POOL_CLEAN_ARGS — all set by others)
                  #   (EXPORTS: AGENT_BROWSER_SESSION=abpool-<N> via pool_force_session)
                  #   (NO changes to any existing function; NO bin/agent-browser — that is T3.S2)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**PRD §2.4 orchestration entry point** — the wire that turns `bin/agent-browser` (T3.S2) into a
transparent browser pool. It composes every prior M6 argv transform (classify / normalize /
strip+force) with the M2/M3/M5 lifecycle layers (resolve / find / acquire / boot / ensure),
terminating in the library's FIRST `exec "$POOL_REAL_BIN"`.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (lane is STDOUT-only — scout-lifecycle §1, HOST-VERIFIED): pool_lease_find_mine,
#   pool_acquire_locked, pool_wait_for_lane all `printf '%s\n' "$N"` and set NO global
#   (`grep POOL_FOUND_LANE|POOL_ACQUIRED_LANE lib/pool.sh` → no matches). The wrapper MUST capture
#   via `local N; … if N="$(…)"`. NEVER `local N="$(…)"` (SC2155: `local`'s rc 0 masks the
#   function's rc 1 → you proceed with N="" as if no error; BashFAQ 105). The `if N="$(…)"` form
#   keeps rc 1 set -e-safe (the condition is just false, no abort).

# CRITICAL (boot-vs-adopt via pool_lease_field port — scout-lifecycle §5/§7): pool_acquire_locked
#   returns a PROVISIONAL lease (port=0, chrome_pid=0, connected=false) on the choose-N path, OR
#   an ADOPTED orphan (port>0, already booted) on the reuse-orphan path. The wrapper reads
#   `port="$(pool_lease_field "$N" port)" || port=""` and boots ONLY when port ∈ {"0","",null}.
#   Booting an already-booted adopted lane would re-copy/re-launch (wasteful + racy). pool_lease_field
#   is rc 0/1 (returns 1 on missing/corrupt) → MUST guard with `|| port=""`.

# CRITICAL (pool_boot_lane rc 1 ⇒ lane DROPPED — scout-lifecycle §7): on every recoverable failure
#   pool_boot_lane calls _pool_release_lane_internals THEN return 1. So rc 1 leaves NO lane. The
#   wrapper MUST `pool_die` (no in-place retry — re-entering acquire with the same exhausted state
#   would loop). Do NOT swallow rc 1.

# CRITICAL (pool_ensure_connected rc 1 ⇒ lane NOT dropped — scout-lifecycle §8): it NEVER calls
#   _pool_release_*; rc 1 leaves lease+chrome as-is (reaper's job on next acquire). The wrapper's
#   `|| pool_die` surfaces the failure; do NOT retry in-place (would hit the same dead Chrome).

# CRITICAL (TERMINAL — no return on success — external-bash §1/§2): all four exits are `exec`
#   (process replacement; PID stays; exported env inherited) or `pool_die` (exit 1). There is NO
#   `return` on the success path — bin/agent-browser runs nothing after pool_wrapper_main, so there
#   is no caller state to resume. A `return` would be a bug (the shim would fall off the end → exit 0
#   → the agent's command silently does nothing). exec IS the hand-off.

# CRITICAL (passthrough exec passes ORIGINAL "$@" — PRD §2.4 step 0): steps b/c/d use
#   `exec "$POOL_REAL_BIN" "$@"` — a meta command / human-terminal call must see EXACTLY what the
#   user typed (PRD §2.15: "`skills get core` → passthrough (unaffected)"). ONLY step k (driving)
#   uses the cleaned `"${POOL_CLEAN_ARGS[@]}"`. Mixing these up (e.g. exec'ing cleaned args for a
#   meta command) would break skills/help.

# CRITICAL (POOL_DISABLE checked AFTER config_init — CONTRACT a then b; scout-conventions §6):
#   pool_config_init (@173-176) freezes POOL_DISABLE from AGENT_BROWSER_POOL_DISABLE. Step b reads
#   the FROZEN global `[[ "$POOL_DISABLE" == "1" ]]`, NOT the raw env var. (config_init also freezes
#   POOL_REAL_BIN — needed by every exec site.)

# CRITICAL (the (( )) trap — lib/pool.sh:360-365): a BARE `(( i++ ))` returns rc 1 when i==0 →
#   ABORTS under set -e. pool_wrapper_main introduces NO arithmetic counters (the lane comes from
#   stdout, not a loop), so this is mainly a "don't add any" note. If any (( )) is needed, use it
#   ONLY in a condition (while/if — exempt) and the assignment form i=$((i+1)).

# GOTCHA (pool_dispatch_classify is PURE but CONTRACT orders config first): classify (@3030) reads
#   NO config globals (callable before config_init). BUT CONTRACT step a (config_init) runs before
#   step c (classify) because step b (POOL_DISABLE) needs config. Don't "optimize" by moving
#   classify before config — it breaks the POOL_DISABLE check ordering.

# GOTCHA (the connect-normalize leaves bare `connect` — scout-conventions §9 / M6.T1.S2): after
#   pool_normalize_connect strips the positional, a bare `connect` may remain in POOL_NORM_ARGS.
#   The wrapper does NOT special-case it — pool_ensure_connected (step h) already bound the daemon,
#   so exec'ing `agent-browser --session abpool-<N> connect` against a connected lane is a no-op
#   connect (harmless). Do NOT add a "skip exec for bare connect" branch.

# GOTCHA (close --all interception log — M6.T1.S2 POOL_CLOSE_ALL_SEEN): pool_normalize_close sets
#   POOL_CLOSE_ALL_SEEN=1 iff it stripped ≥1 `--all` from a `close` cmd. The wrapper logs the
#   interception (`_pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"`) for
#   observability (PRD §2.15: "`close --all` → cannot harm other agents' lanes"). The close itself
#   is exec'd normally (scoped to the lane via the forced session).

# GOTCHA (split capture even for pool_lease_field — it is rc 0/1): `port="$(pool_lease_field "$N"
#   port)"` would ABORT under set -e if the lease is missing/corrupt (rc 1). Guard with
#   `|| port=""` (||-list is errexit-exempt). Then test `[[ "$port" == "0" || -z "$port" || "$port"
#   == "null" ]]` → boot.

# GOTCHA (pool_force_session rc 1 ⇒ bad lane ⇒ pool_die): force (@3380) returns 1 iff lane is
#   empty/non-numeric. By step j the lane $N came from a successful acquire (numeric), so rc 1 is
#   unreachable in practice — but guard anyway (`|| pool_die`) for defense + set -e safety.

# GOTCHA (set -u + globals): read POOL_OWNER_PID / POOL_DISABLE / POOL_CLOSE_ALL_SEEN with
#   `${VAR:-}` defaults where they might be unset BEFORE their setter runs. After step a
#   (config_init) POOL_DISABLE is set; after step d (owner_resolve) POOL_OWNER_PID is set;
#   POOL_CLOSE_ALL_SEEN is set by step i. So by the time each is READ it is set — but use
#   `${POOL_OWNER_PID:-0}` / `${POOL_CLOSE_ALL_SEEN:-0}` defensively (matches the codebase idiom).

# GOTCHA (placement + naming): APPEND at EOF (after pool_force_session @3391) under a NEW
#   "# Wrapper shim — complete lifecycle (P1.M6.T3.S1)" banner. Public name pool_wrapper_main
#   (no `_` prefix; pool_* family). This task is LIB-ONLY — do NOT create bin/agent-browser (T3.S2).
#   NO edits to any existing function.

# GOTCHA (shellcheck — keep it clean): the file is 100% clean today. This task adds ZERO net
#   warnings. Avoid SC2155 (declare lane captures separately: `local N` then `N="$(…)"` in an if —
#   NEVER `local N="$(…)"`). Avoid SC2086 (quote "$N", "$@", "${POOL_NORM_ARGS[@]}",
#   "${POOL_CLEAN_ARGS[@]}", "$POOL_REAL_BIN"). Avoid SC2181 (use `if …; then` not `$?` checks).
#   The `class="$(pool_dispatch_classify "$@")"` capture is a plain assignment (no `local` on the
#   same line) → SC2155-clean IF `class` is declared separately; declare `local class N port` at top.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new data model**. It introduces ONE
function and CONSUMES (does not define) these globals — all set by other functions:

- `POOL_DISABLE` (scalar, set by `pool_config_init` @176) — read at step b.
- `POOL_REAL_BIN` (scalar path, set by `pool_config_init` @147) — the exec target (steps b/c/d/k).
- `POOL_OWNER_PID` (scalar, set by `pool_owner_resolve` @478) — read at step d (`==0` ⇒ passthrough).
- `POOL_WAIT` (scalar seconds, set by `pool_config_init` @170) — read (indirectly) by
  `pool_wait_for_lane`; referenced in the exhaustion `pool_die` message.
- `POOL_NORM_ARGS` (array, set by `pool_normalize_close` @3171 + overwritten by
  `pool_normalize_connect` @3230/@3259) — the normalized argv; step i output, step j input.
- `POOL_CLOSE_ALL_SEEN` (scalar, set by `pool_normalize_close` @3173) — read at step j (log gate).
- `POOL_CLEAN_ARGS` (array, set by `pool_strip_session_args` @3349) — the `--session`-free argv;
  step j output, step k input (the exec argv).

**Side effect**: `pool_force_session` (@3380) EXPORTS `AGENT_BROWSER_SESSION=abpool-<N>` into the
calling shell; that export is inherited by the step-k `exec` (external-bash §1 — `execve(2)` passes
the caller's exported env). This is the SOLE env-var side effect.

**Naming**: `pool_wrapper_main` (public, no `_` prefix; `pool_*` family). No private helper needed
(the function is a linear pipeline of existing helpers).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + locate the append point + confirm the integration contract
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_dispatch_classify pool_normalize_close pool_normalize_connect \
                  pool_strip_session_args pool_force_session pool_owner_resolve \
                  pool_lease_find_mine pool_acquire_locked pool_wait_for_lane \
                  pool_lease_field pool_boot_lane pool_ensure_connected \
                  pool_config_init pool_state_init pool_die _pool_log'
  - EXPECT: all reported as functions (M1–M6.T2.S1 all landed).
  - RUN (confirm this task is greenfield):
        grep -nE 'pool_wrapper_main|complete lifecycle' lib/pool.sh && echo "STOP: already exists" \
            || echo "OK: greenfield"
  - EXPECT: OK: greenfield.
  - RUN (confirm lane is STDOUT-only — NO POOL_FOUND_LANE / POOL_ACQUIRED_LANE globals):
        grep -nE 'POOL_FOUND_LANE|POOL_ACQUIRED_LANE' lib/pool.sh && echo "STOP: globals exist?!" \
            || echo "OK: lane is stdout-only (capture via \$(...))"
  - EXPECT: OK: lane is stdout-only.
  - RUN (locate the append point + confirm the last function):
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh          # EOF ~3391 (pool_force_session)
        grep -nE '^pool_force_session\(\)' lib/pool.sh              # @3380 — append AFTER its closing brace
        grep -nE 'Wrapper shim' lib/pool.sh | tail -3               # banner order at EOF
        sed -n '18p' lib/pool.sh                                    # expect: set -euo pipefail
  - EXPECT: pool_force_session defined @3380; EOF ~3391; line 18 = set -euo pipefail. Append after EOF.
  - RUN (confirm pool_lease_field is rc 0/1 + reads `port'):
        sed -n '876,910p' lib/pool.sh                               # the predicate; `[[ -f "$file" ]] || return 1`
  - EXPECT: pool_lease_field returns 1 on missing/corrupt → MUST guard `|| port=""`.
  - RUN (confirm pool_acquire_locked / pool_boot_lane CALLER CONTRACT — boot-vs-adopt):
        sed -n '2043,2056p' lib/pool.sh                             # acquire_locked (stdout N, no global)
        sed -n '2185,2245p' lib/pool.sh                             # boot_lane + its CALLER CONTRACT
  - EXPECT: acquire prints N (no global); boot_lane docs say provisional lease has port=0.
  - RUN (sanity tools): command -v bash >/dev/null && command -v shellcheck >/dev/null && echo "OK tools"
  - RUN: bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh && echo "OK clean baseline"
  - EXPECT: OK tools (bash 5.x + ShellCheck 0.11.0); OK clean baseline (zero warnings — the bar to NOT lower).

Task 1: APPEND the new banner + pool_wrapper_main() to lib/pool.sh
  - PLACEMENT: directly below pool_force_session's closing brace (EOF ~3391), under a NEW
        "# Wrapper shim — complete lifecycle (P1.M6.T3.S1)" banner.
  - IMPLEMENT (verbatim-ready — paste the banner + docstrings + function at EOF):

# =============================================================================
# Wrapper shim — complete lifecycle (P1.M6.T3.S1)
# =============================================================================
# PRD §2.4 steps 0→5 — the orchestration entry point. Called by bin/agent-browser
# (M6.T3.S2) as its FINAL statement (`pool_wrapper_main "$@"`; the shim runs nothing
# after it). TERMINAL by design: every success path ends in `exec "$POOL_REAL_BIN" …`
# (process replacement — never returns); every fatal path ends in `pool_die` (exit 1).
# There is NO `return` on the success path — there is no caller state to resume.
#
# This is the ONLY place the full pipeline is wired. It COMPOSES (does not re-implement):
#   - M6.T1.S1 pool_dispatch_classify   (step c: meta vs driving)
#   - M6.T1.S2 pool_normalize_close/connect (step i: scope close --all, strip connect positional)
#   - M6.T2.S1 pool_strip_session_args / pool_force_session (step j: neutralize --session + env)
#   - M2    pool_owner_resolve          (step d: find the owning pi; ==0 ⇒ human terminal)
#   - M3    pool_lease_find_mine        (step e: reuse my live lane)
#   - M5    pool_acquire_locked / pool_wait_for_lane (step f: get a lane)
#           pool_boot_lane              (step g: boot a provisional lane)
#           pool_ensure_connected       (step h: per-call self-heal)
#
# THE LANE FLOWS VIA STDOUT, NOT A GLOBAL. pool_lease_find_mine / pool_acquire_locked /
# pool_wait_for_lane all `printf '%s\n' "$N"` and set NO global (verified: no
# POOL_FOUND_LANE / POOL_ACQUIRED_LANE in this file). The wrapper captures N via
# `local N; … if N="$(…)"` — NEVER `local N="$(…)"` (SC2155 masks errexit; BashFAQ 105).
#
# BOOT-VS-ADOPT: pool_acquire_locked returns a PROVISIONAL lease (port=0) on the
# choose-N path, OR an ADOPTED orphan (port>0, already booted) on the reuse-orphan path.
# The wrapper reads `port="$(pool_lease_field "$N" port)" || port=""` and boots ONLY when
# port ∈ {"0","",null}. Booting an adopted lane would re-copy/re-launch (wasteful + racy).
#
# RC TAXONOMY (which helpers need an `if`/`||` guard under set -e):
#   rc 0 ALWAYS (no guard):  pool_dispatch_classify, pool_normalize_close/connect,
#                            pool_strip_session_args, pool_config_init, pool_state_init,
#                            pool_owner_resolve (config/state/owner pool_die on FATAL misconfig)
#   rc 0/1 NON-FATAL (guard): pool_lease_find_mine, pool_acquire_locked, pool_wait_for_lane,
#                            pool_lease_field, pool_force_session
#   rc 0/1, rc 1 ⇒ lane GONE: pool_boot_lane      (rc 1 ⇒ _pool_release_lane_internals already ran)
#   rc 0/1, rc 1 ⇒ lane KEPT: pool_ensure_connected (NEVER drops the lane; reaper's job later)
#   pool_die FATAL (propagates): inside pool_boot_lane / pool_ensure_connected (chrome instant-exit)
#
# GOTCHA — TERMINAL: all four exits are exec (b/c/d/k) or pool_die. NO return on success.
# GOTCHA — passthrough exec (b/c/d) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:
#   "exec real binary unchanged"; §2.15: "skills get core → passthrough (unaffected)"). ONLY
#   step k (driving) uses the cleaned "${POOL_CLEAN_ARGS[@]}".
# GOTCHA — POOL_DISABLE is read AFTER pool_config_init (which freezes it @176). Step b reads
#   the FROZEN global, not the raw env var.
# GOTCHA — pool_boot_lane rc 1 ⇒ lane DROPPED ⇒ pool_die (no in-place retry; re-entering
#   acquire with the same exhausted state would loop).
# GOTCHA — pool_ensure_connected rc 1 ⇒ lane NOT dropped ⇒ pool_die (surface the failure;
#   reaper cleans up on the agent's NEXT acquire). Do NOT retry in-place.
# GOTCHA — the connect-normalize may leave a bare `connect` in POOL_NORM_ARGS; do NOT
#   special-case it — pool_ensure_connected (step h) already bound the daemon, so exec'ing
#   `agent-browser --session abpool-<N> connect` is a harmless no-op connect.
# GOTCHA — close --all interception: pool_normalize_close sets POOL_CLOSE_ALL_SEEN=1 iff it
#   stripped ≥1 --all from a close cmd. Log it for observability (PRD §2.15).
# PRECONDITION: none (pool_config_init + pool_state_init are step a — the first thing run).
# CONSUMES: POOL_DISABLE, POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS,
#   POOL_CLOSE_ALL_SEEN, POOL_CLEAN_ARGS (all set by the helpers above).
# EXPORTS (via pool_force_session): AGENT_BROWSER_SESSION=abpool-<N> (inherited by the step-k exec).
pool_wrapper_main() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"` — declare then assign).
    local class N port

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # config freezes POOL_DISABLE, POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.
    # state idempotently mkdirs lanes/ + touches acquire.lock.
    pool_config_init
    pool_state_init

    # --- b. safety valve (PRD §2.17): POOL_DISABLE==1 → passthrough, no pooling ---
    # Read the FROZEN global (config_init just set it). ORIGINAL "$@" unchanged.
    if [[ "${POOL_DISABLE:-0}" == "1" ]]; then
        _pool_log "pool_wrapper_main: POOL_DISABLE=1 → passthrough"
        exec "$POOL_REAL_BIN" "$@"
    fi

    # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
    # pool_dispatch_classify is rc 0 ALWAYS (no guard); prints exactly one token meta|driving.
    # Plain assignment (class declared above) → SC2155-clean + errexit-safe (classify never fails).
    class="$(pool_dispatch_classify "$@")"
    if [[ "$class" == "meta" ]]; then
        _pool_log "pool_wrapper_main: meta command → passthrough"
        exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — skills/--help/session list/etc.
    fi

    # --- d. owner resolution (step 1): no pi ancestor → passthrough --------------
    # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ human in terminal).
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        _pool_log "pool_wrapper_main: no pi ancestor → passthrough (human terminal)"
        exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — raw upstream tool for humans
    fi

    # --- e→g. find-or-acquire my lane (steps 2→3) --------------------------------
    # Lane is STDOUT-only. Split capture (`local N` above; `N="$(…)"` here) inside an `if` keeps
    # rc 1 set -e-safe (the condition is just false). NEVER `local N="$(…)"` (SC2155 masks rc 1).
    if N="$(pool_lease_find_mine)"; then
        # Found my LIVE lane → reuse it (skip acquire + boot). Go to step h (ensure connected).
        _pool_log "pool_wrapper_main: reusing lane $N"
    else
        # Not found → acquire (step 3). Fallback to wait-for-lane on exhaustion.
        if ! N="$(pool_acquire_locked)"; then
            if ! N="$(pool_wait_for_lane)"; then
                # True exhaustion: timeout + force-reap yielded nothing. Surface to the agent.
                pool_die "agent-browser-pool: no lane available after ${POOL_WAIT:-600}s + force-reap"
            fi
        fi

        # --- g. boot-vs-adopt ------------------------------------------------
        # pool_lease_field is rc 0/1 (returns 1 on missing/corrupt) → guard with `|| port=""`
        # (||-list is errexit-exempt). A PROVISIONAL lease has port=0; an ADOPTED orphan has port>0.
        port="$(pool_lease_field "$N" port)" || port=""
        if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
            # Provisional → boot it (copy+port+launch+connect). rc 1 ⇒ lane was DROPPED → pool_die
            # (no in-place retry; re-entering acquire with the same exhausted state would loop).
            _pool_log "pool_wrapper_main: booting provisional lane $N"
            pool_boot_lane "$N" || pool_die "agent-browser-pool: boot failed for lane $N"
        else
            # Adopted orphan (port>0, already booted) → SKIP boot (would re-copy/re-launch).
            _pool_log "pool_wrapper_main: adopted orphan lane $N (port=$port) → skip boot"
        fi
    fi

    # --- h. ensure connected (step 4): per-call self-heal -----------------------
    # rc 1 ⇒ lane unusable but NOT dropped (reaper's job on next acquire). pool_die surfaces it.
    # Do NOT retry in-place (would hit the same dead Chrome).
    pool_ensure_connected "$N" || pool_die "agent-browser-pool: lane $N not connected; aborting"

    # --- i. arg normalization (step 5, first half) ------------------------------
    # Both rc 0 ALWAYS (no guard). pool_normalize_close writes POOL_NORM_ARGS + POOL_CLOSE_ALL_SEEN;
    # pool_normalize_connect OVERWRITES POOL_NORM_ARGS (chained: read ${POOL_NORM_ARGS[@]} → write it).
    pool_normalize_close "$@"
    pool_normalize_connect "${POOL_NORM_ARGS[@]}"

    # --- j. session override (step 5, second half) ------------------------------
    # pool_strip_session_args is rc 0 ALWAYS; writes POOL_CLEAN_ARGS (every --session removed).
    # pool_force_session is rc 0/1; exports AGENT_BROWSER_SESSION=abpool-<N> (persists; inherited by exec).
    pool_strip_session_args "${POOL_NORM_ARGS[@]}"
    pool_force_session "$N" || pool_die "agent-browser-pool: bad lane '$N' for session force"

    # Observability: log if we scoped a close --all (PRD §2.15: "close --all → cannot harm peers").
    if [[ "${POOL_CLOSE_ALL_SEEN:-0}" == "1" ]]; then
        _pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"
    fi

    # --- k. EXEC the real binary (step 5, terminal) -----------------------------
    # Process replacement (PID stays; exported AGENT_BROWSER_SESSION inherited). UNREACHABLE code
    # after this line. The agent's command now runs against its locked, booted, connected lane.
    exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"
}

  - VERIFY (immediately after writing):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings
        grep -nE '^pool_wrapper_main\(\)' lib/pool.sh            # defined exactly once, near EOF
  - EXPECT: OK syntax; OK shellcheck (zero warnings — same as baseline); defined once near EOF.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — split lane capture inside an if (lane is STDOUT-only; rc 1 must NOT abort):
local N                          # declare FIRST (SC2155: never `local N="$(…)"`)
if N="$(pool_lease_find_mine)"; then    # rc 1 ⇒ condition false, NO abort (BashFAQ 105)
    <reuse lane N>
else
    if ! N="$(pool_acquire_locked)"; then
        if ! N="$(pool_wait_for_lane)"; then pool_die "...exhausted..."; fi
    fi
    <boot-or-adopt N>
fi

# PATTERN — boot-vs-adopt via pool_lease_field port (rc 0/1 → guard with ||):
port="$(pool_lease_field "$N" port)" || port=""    # ||-list is errexit-exempt; rc 1 ⇒ port=""
if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
    pool_boot_lane "$N" || pool_die "boot failed for lane $N"   # rc 1 ⇒ lane DROPPED
fi

# PATTERN — the argv-array pipeline (each helper REPLACES the global it writes):
pool_normalize_close "$@"                         # → POOL_NORM_ARGS (+ POOL_CLOSE_ALL_SEEN)
pool_normalize_connect "${POOL_NORM_ARGS[@]}"     # → POOL_NORM_ARGS (overwritten)
pool_strip_session_args "${POOL_NORM_ARGS[@]}"    # → POOL_CLEAN_ARGS
pool_force_session "$N" || pool_die "..."         # → exports AGENT_BROWSER_SESSION=abpool-<N>
exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"     # TERMINAL; env inherited

# PATTERN — passthrough exec (ORIGINAL "$@" UNCHANGED; only driving uses CLEAN args):
if [[ "${POOL_DISABLE:-0}" == "1" ]];      then exec "$POOL_REAL_BIN" "$@"; fi   # step b
if [[ "$class" == "meta" ]];               then exec "$POOL_REAL_BIN" "$@"; fi   # step c
if [[ "${POOL_OWNER_PID:-0}" == "0" ]];    then exec "$POOL_REAL_BIN" "$@"; fi   # step d
exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"                                    # step k (driving ONLY)

# GOTCHA — WHY split `local N; N="$(…)"` and NOT `local N="$(…)"`: `local` is a builtin whose
#   own rc is always 0, so `local N="$(pool_lease_find_mine)"` does NOT abort on rc 1 — but you
#   silently proceed with N="" as if no error. The split form lets errexit fire (inside the `if`).
# GOTCHA — WHY `|| pool_die` for boot/ensure (not `|| return`): a sourced lib's `return` hands
#   control back to bin/agent-browser (which has nothing to do → exit 0 → the agent's command
#   silently does nothing). pool_die's exit 1 fails the whole invocation loudly. There is no
#   "soft failure" path — the wrapper is terminal.
# GOTCHA — WHY boot-vs-adopt matters: pool_acquire_locked may return an ADOPTED orphan (port>0,
#   already booted — the reuse-orphan path, PRD §2.4 step 3b "REUSE-ORPHAN"). Booting it again
#   would cp -a the master + launch a second Chrome on the same dir (race + waste). Read port first.
# GOTCHA — WHY pool_ensure_connected is called even on reuse: the lane was live when find_mine
#   matched, but the daemon may have died between then and now (PRD §2.4 step 4 "reconnect if daemon
#   died"). ensure_connected is the per-call self-heal — call it on EVERY driving path (reuse + boot
#   + adopt).
```

### Integration Points

```yaml
LIBRARY (lib/pool.sh):
  - append: "new banner '# Wrapper shim — complete lifecycle (P1.M6.T3.S1)' + pool_wrapper_main at
            EOF (after pool_force_session @3391)"
  - pattern: "match the banner+docstring+function style of pool_dispatch_classify (@2973 banner) +
             pool_force_session (@3263 banner). The docstring MUST list the step pipeline (a→k),
             the rc taxonomy, and the GOTCHA notes (terminal; passthrough-original-args;
             lane-via-stdout; boot-vs-adopt)."

CONSUMED GLOBALS (set by OTHERS — pool_wrapper_main only READS them):
  - POOL_DISABLE:        "scalar (config_init @176). Step b: ==\"1\" ⇒ passthrough exec."
  - POOL_REAL_BIN:       "scalar path (config_init @147). The exec target (steps b/c/d/k)."
  - POOL_OWNER_PID:      "scalar (owner_resolve @478). Step d: ==\"0\" ⇒ human terminal ⇒ passthrough."
  - POOL_WAIT:           "scalar seconds (config_init @170). Used in the exhaustion pool_die message."
  - POOL_NORM_ARGS:      "array (normalize_close @3171 + normalize_connect @3230/@3259). Step i output."
  - POOL_CLOSE_ALL_SEEN: "scalar (normalize_close @3173). Step j: ==\"1\" ⇒ log interception."
  - POOL_CLEAN_ARGS:     "array (strip_session_args @3349). Step j output; step k exec argv."

EXPORTED ENV (via pool_force_session @3380 — inherited by the step-k exec):
  - AGENT_BROWSER_SESSION: "= abpool-<N>. The SOLE env side effect. forces the agent onto its lane."

CONSUMERS (NOT built by this task — referenced for interface stability):
  - M6.T3.S2 bin/agent-browser: "source \"$REAL_DIR/../lib/pool.sh\"; pool_wrapper_main \"$@\" (the
            LAST statement; shim runs nothing after it). T3.S2 creates the executable + chmod +x;
            this task is LIB-ONLY."

NO CHANGES TO:
  - any existing function (M1–M6.T2.S1) — pure append.
  - bin/ (still .gitkeep) — the executable is M6.T3.S2.
  - test/ (still .gitkeep) — the bats harness is M9.T1.S1.
  - any on-disk layout / data model / lease schema.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the function — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # whole file, ZERO warnings

grep -nE '^pool_wrapper_main\(\)' lib/pool.sh            # defined exactly once, near EOF
# Expected: both OK; defined once near EOF. (Baseline was 100% clean; this task must not lower it.)
#   Common fixes: SC2155 (declare locals up front; never `local N="$(…)"`), SC2086 (quote "$N",
#   "$POOL_REAL_BIN", "${POOL_NORM_ARGS[@]}", "${POOL_CLEAN_ARGS[@]}"), SC2181 (use `if` not `$?`).
```

### Level 2: Unit Tests (Component Validation)

The bats harness lands in M9.T1.S1. For THIS task, validate via a direct bash script that stubs
`$POOL_REAL_BIN` and exercises the three passthrough branches + the driving-arg-pipeline (no Chrome
needed — the rc-1/abort paths use test-hook env vars). The driving happy-path (acquire→boot→ensure)
needs a real Chrome + master profile and is deferred to Level 3 / M9:

```bash
# Save as /tmp/test_wrapper_main.sh and run: bash /tmp/test_wrapper_main.sh
# Strategy: stub $POOL_REAL_BIN via AGENT_BROWSER_REAL so the wrapper's exec captures args to a file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"   # run from repo root (adjust if saved elsewhere)
source lib/pool.sh
pass=0; fail=0
check() { # NAME EXPECTED_FILE ACTUAL
    if diff -q "$2" "$3" >/dev/null 2>&1; then pass=$((pass+1)); printf 'PASS %s\n' "$1";
    else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$(cat "$2")" "$(cat "$3")" >&2; fi
}

# --- stub the real binary: a script that writes its argv (+ env) to $CAPTURE_FILE ---
STUB="$(mktemp -d)/agent-browser-stub"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
# Print argv (NUL-delimited for safety) + the forced session env, then exit 0.
printf 'ARGS:\n'; for a in "$@"; do printf '  [%s]\n' "$a"; done
printf 'ENV: AGENT_BROWSER_SESSION=%s\n' "${AGENT_BROWSER_SESSION:-<unset>}"
EOF
chmod +x "$STUB"
CAP="$(mktemp)"

# --- Case 1: POOL_DISABLE=1 → passthrough ORIGINAL args (no strip/force) ---
# Use a non-meta driving command so we PROVE the disable short-circuits BEFORE classify/lifecycle.
# (The owner is a real pi in the test shell only if run under pi; force passthrough via DISABLE.)
: >"$CAP"
AGENT_BROWSER_POOL_DISABLE=1 AGENT_BROWSER_REAL="$STUB" AGENT_BROWSER_POOL_STATE="$(mktemp -d)" \
    bash -c 'set -euo pipefail; source lib/pool.sh; POOL_LOG_PATH="/dev/null" \
        pool_wrapper_main --session evil open https://x' >"$CAP" 2>/dev/null
grep -q -- '--session' "$CAP" && grep -q 'evil' "$CAP" && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL POOL_DISABLE: expected ORIGINAL args incl --session evil" >&2; }
# Env must be UNSET (no force ran): grep for <unset> OR no AGENT_BROWSER_SESSION=abpool line.
grep -qE 'AGENT_BROWSER_SESSION=(<unset>|evil)' "$CAP" && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL POOL_DISABLE: env should NOT be abpool-<N>" >&2; }

# --- Case 2: meta command (--help) → passthrough ORIGINAL args (no strip/force) ---
# No pi ancestor in the test shell → owner_resolve would ALSO passthrough; but classify runs FIRST
# (step c before step d), so --help must passthrough via the META branch. Verify args unchanged.
: >"$CAP"
AGENT_BROWSER_REAL="$STUB" AGENT_BROWSER_POOL_STATE="$(mktemp -d)" \
    bash -c 'set -euo pipefail; source lib/pool.sh; POOL_LOG_PATH="/dev/null" \
        pool_wrapper_main --help --session ignored' >"$CAP" 2>/dev/null
grep -q -- '--help' "$CAP" && grep -q -- '--session' "$CAP" && grep -q 'ignored' "$CAP" \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL meta --help: expected ORIGINAL args incl --session ignored" >&2; }

# --- Case 3: skills get core → meta → passthrough ---
: >"$CAP"
AGENT_BROWSER_REAL="$STUB" AGENT_BROWSER_POOL_STATE="$(mktemp -d)" \
    bash -c 'set -euo pipefail; source lib/pool.sh; POOL_LOG_PATH="/dev/null" \
        pool_wrapper_main skills get core' >"$CAP" 2>/dev/null
grep -q 'skills' "$CAP" && grep -q 'core' "$CAP" && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL meta skills: expected 'skills' 'get' 'core' passthrough" >&2; }

# --- Case 4: no pi ancestor (human terminal) → passthrough ORIGINAL args ---
# Force classify to see a DRIVING command (open) but owner_resolve to find NO pi (PID unset → 0).
: >"$CAP"
AGENT_BROWSER_REAL="$STUB" AGENT_BROWSER_POOL_STATE="$(mktemp -d)" \
    bash -c 'set -euo pipefail; unset AGENT_BROWSER_POOL_OWNER_PID; source lib/pool.sh; \
        POOL_LOG_PATH="/dev/null" pool_wrapper_main --session evil open https://x' >"$CAP" 2>/dev/null
grep -q -- '--session' "$CAP" && grep -q 'evil' "$CAP" && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL no-pi-ancestor: expected ORIGINAL args (human passthrough)" >&2; }

# --- Case 5 (structural): the function is terminal — no `return` on the success path ---
if ! grep -nE '^\s*return\s*[0-9]*\s*$' lib/pool.sh | awk -F: '$1 > 3391' | grep .; then
    pass=$((pass+1));   # no bare `return` in the appended function (exec/pool_die are the only exits)
else
    fail=$((fail+1)); echo "FAIL terminal: found a `return` in pool_wrapper_main (should be exec/pool_die only)" >&2
fi

# --- Case 6 (structural): every rc-0/1 helper is guarded (no bare call) ---
# Confirm no `local N="$(pool_lease_find_mine|pool_acquire_locked|pool_wait_for_lane)"` (SC2155).
if grep -nE 'local [A-Za-z]+="\$\(' lib/pool.sh | awk -F: '$1 > 3391' | \
     grep -E 'lease_find_mine|acquire_locked|wait_for_lane'; then
    fail=$((fail+1)); echo "FAIL SC2155: found local X=\"\$(lane-fn)\" — split the capture" >&2
else
    pass=$((pass+1))
fi

echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: all PASS, fail=0. (Cases 1-4 exercise the three passthrough branches + skills meta;
#   Case 5-6 are structural invariants. The driving happy-path is Level 3 / M9.)
```

### Level 3: Integration Testing (System Validation — needs Chrome + master profile)

The driving happy-path (acquire → boot → ensure → exec) requires a real Chrome, a master profile,
and btrfs at the ephemeral root. It is the domain of the M9 test harness. For a SMOKE test once a
master profile exists:

```bash
# PREREQ: master profile at $AGENT_CHROME_MASTER; btrfs at ephemeral root (or POOL_ALLOW_SLOW_COPY=1);
#         a REAL pi ancestor (run inside pi) OR AGENT_BROWSER_POOL_OWNER_PID=<a live pi pid>.
# This runs the FULL lifecycle end-to-end. Skip if no Chrome/master — it is M9's job to automate.

# Set the real bin to the ACTUAL upstream agent-browser (so exec runs the real tool):
#   (default; just don't override AGENT_BROWSER_REAL)
# Run a driving command under a simulated pi owner:
AGENT_BROWSER_POOL_OWNER_PID="$PPID" \
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool-smoke}" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_wrapper_main --session evil open https://example.com'
# Expected: a Chrome launches in an ephemeral lane; the page opens; AGENT_BROWSER_SESSION=abpool-<N>
#   is forced (check `agent-browser-pool status` shows lane N owned by $PPID with connected=true).

# Verify reuse (second call by the SAME owner reuses lane N):
AGENT_BROWSER_POOL_OWNER_PID="$PPID" \
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool-smoke}" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_wrapper_main snapshot'
# Expected: NO new Chrome; the SAME lane N is reused (find_mine matched); snapshot returns.

# Transparency: --session evil must NOT bypass the lane (forced to abpool-<N>):
AGENT_BROWSER_POOL_OWNER_PID="$PPID" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_wrapper_main --session evil session' 2>&1 \
    | grep -q 'abpool-' && echo "OK: forced to abpool-<N>" || echo "FAIL: --session leaked"

# Cleanup: release the lane (M5.T2 / M7.T3 release command):
#   agent-browser-pool release all   (or kill the owner pi → next acquire reaps it)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Transparency checklist (PRD §2.15) — spot-checks (full automation is M9.T4.S1):
#   [ ] `agent-browser skills get core` → passthrough (Case 3 above).
#   [ ] `agent-browser --session <x> open <url>` → forced to abpool-<N> (Level 3 transparency check).
#   [ ] `agent-browser close --all` → scoped to my lane (POOL_CLOSE_ALL_SEEN logged; no peer harm).
#   [ ] next agent → next free lane (run two simulated owners → distinct lanes).

# Concurrency (M9.T2.S1 automates): launch N simulated pi owners in parallel → N distinct lanes.
#   for i in 1 2 3; do ( AGENT_BROWSER_POOL_OWNER_PID=$BASHPID bash -c '... pool_wrapper_main open ...' ) & done; wait
#   Expected: 3 distinct lanes, no collision.
```

## Final Validation Checklist

### Technical Validation

- [ ] All applicable validation levels completed (Level 1 + Level 2 mandatory; Level 3 needs Chrome).
- [ ] `bash -n lib/pool.sh` clean (no syntax errors).
- [ ] `shellcheck -s bash lib/pool.sh` zero warnings (whole file — same as M6.T2.S1 baseline).
- [ ] `pool_wrapper_main` defined exactly once, near EOF (after `pool_force_session`).

### Feature Validation

- [ ] **Step a**: `pool_config_init; pool_state_init` run first (rc 0 or pool_die).
- [ ] **Step b**: `POOL_DISABLE=="1"` → `exec "$POOL_REAL_BIN" "$@"` (ORIGINAL args; no strip/force).
- [ ] **Step c**: `class=="meta"` → `exec "$POOL_REAL_BIN" "$@"` (ORIGINAL args; --help/skills/session list).
- [ ] **Step d**: `POOL_OWNER_PID=="0"` → `exec "$POOL_REAL_BIN" "$@"` (ORIGINAL args; human terminal).
- [ ] **Step e**: `if N="$(pool_lease_find_mine)"` (split capture + if-guard; rc 1 does NOT abort).
- [ ] **Step f**: `if ! N="$(pool_acquire_locked)"` → `if ! N="$(pool_wait_for_lane)"` → `pool_die`.
- [ ] **Step g**: `port="$(pool_lease_field "$N" port)" || port=""`; boot iff port∈{0,"",null}; skip boot otherwise.
- [ ] **Step h**: `pool_ensure_connected "$N" || pool_die`.
- [ ] **Step i**: `pool_normalize_close "$@"; pool_normalize_connect "${POOL_NORM_ARGS[@]}"`.
- [ ] **Step j**: `pool_strip_session_args "${POOL_NORM_ARGS[@]}"; pool_force_session "$N" || pool_die`.
- [ ] **Step k**: `exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"` (TERMINAL; env AGENT_BROWSER_SESSION inherited).
- [ ] **Terminal**: NO `return` on any success path (all exits are `exec` or `pool_die`).
- [ ] **set -e safety**: every rc-0/1 helper guarded; no `local N="$(…)"`.
- [ ] All success-criteria rows from the "What" section met (Level 2 Cases 1-6 PASS).

### Code Quality Validation

- [ ] Follows existing codebase patterns (banner format, `funcname:` log prefix, GOTCHA notes).
- [ ] File placement matches the desired codebase tree (append at EOF under new banner).
- [ ] Anti-patterns avoided (no `local N="$(…)"`; no bare rc-0/1 call; no `return` on success; no
      special-casing of bare `connect`; passthrough exec passes ORIGINAL `$@`).
- [ ] Consumes only the documented globals; exports only `AGENT_BROWSER_SESSION` (via force).
- [ ] NO changes to any existing function (pure append); NO bin/agent-browser (T3.S2).

### Documentation & Deployment

- [ ] The `# ===` banner + contract comment block above `pool_wrapper_main` documents the dispatch
      flow + transparency contract (satisfies the CONTRACT §5 DOCS step [Mode A] — lib-only).
- [ ] Logs are informative but not verbose (passthrough reason; lane reuse/boot/adopt; close-`--all`).
- [ ] No new env vars CONSUMED (reads only globals set by helpers + the test-hook owner vars).

---

## Anti-Patterns to Avoid

- ❌ Don't `local N="$(pool_lease_find_mine)"` — SC2155 masks rc 1; use split `local N; … if N="$(…)"`.
- ❌ Don't call rc-0/1 helpers bare under set -e — guard with `if`/`||` (BashFAQ 105).
- ❌ Don't `return` on a success path — the function is terminal (exec/pool_die only).
- ❌ Don't pass `"${POOL_CLEAN_ARGS[@]}"` to a passthrough exec (steps b/c/d) — passthrough uses the
  ORIGINAL `"$@"` (PRD §2.4 step 0 "unchanged"; §2.15 "skills get core → passthrough (unaffected)").
- ❌ Don't boot an adopted orphan (port>0) — read `port` first; boot only provisional lanes (port=0).
- ❌ Don't retry pool_boot_lane / pool_ensure_connected in-place on rc 1 — pool_die (boot rc 1 ⇒ lane
  gone; ensure rc 1 ⇒ same dead Chrome).
- ❌ Don't special-case a bare `connect` left by normalize — pool_ensure_connected already bound the
  daemon; exec'ing `--session abpool-<N> connect` is a harmless no-op.
- ❌ Don't create bin/agent-browser in this task — that is P1.M6.T3.S2 (this task is LIB-ONLY).
- ❌ Don't add arithmetic counters with bare `(( i++ ))` — returns rc 1 when 0 (use conditions or
  `i=$((i+1))`). pool_wrapper_main needs NO counters (lane is stdout-only).
- ❌ Don't read POOL_DISABLE / POOL_OWNER_PID / POOL_CLOSE_ALL_SEEN without `${VAR:-}` defaults — set -u
  safety (matches the codebase idiom; each is set before it's read, but be defensive).
