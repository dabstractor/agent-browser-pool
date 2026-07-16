# PRP — P3.M2.T1.S2: `selftest_owner_resolves_non_pi_harness` (positive `claude` + negative `xterm`)

**Work item:** P3.M2.T1.S2 (2 points) — parent P3.M2.T1 (Multi-harness owner-simulation test coverage),
milestone P3.M2 (Test coverage). PRD §2.18 (Testing & validation), §2.4 (owner resolution step 1),
§2.13 (identity rules).
**Type:** Test-only — one new auto-discovered selftest function in `test/validate.sh`. **No
user/config/API surface change. No docs.**
**Phase constraint:** This is a PLANNING-phase deliverable. Per AGENTS.md §1, validation here is
**static only** (`bash -n`, `shellcheck`). **Do NOT run the test suite** (it may spawn processes).
The implementing agent runs the suite isolated + bounded per AGENTS.md §2.

---

## Goal

**Feature Goal:** Prove, via the framework's auto-discovered selftest runner, that non-`pi` harness
owner resolution actually works end-to-end:
- **POSITIVE** — a recognized non-`pi` harness (`claude`) is **resolved** by `pool_owner_resolve`
  (which records the **actual** `/proc` comm, not a hardcoded `"pi"`), is marked resolved
  (`POOL_OWNER_PID != 0`), and is **accepted** by `pool_owner_alive` (comm + starttime both match).
- **NEGATIVE** — a non-harness comm (`xterm`) is **rejected** by `pool_owner_alive` (a lease
  expecting `comm=claude` must not adopt an `xterm` process — identity isolation, PRD §2.13).

**Deliverable:** A new function `selftest_owner_resolves_non_pi_harness()` appended in
`test/validate.sh` immediately after `selftest_sim_owner_is_alive_pi` (currently the `}` at line
329). It is auto-discovered by `_run_selftest_suite` (no registration). It consumes the generalized
`spawn_sim_owner [SECONDS] [COMM]` from P3.M2.T1.S1, `pool_owner_resolve` TEST MODE (actual-comm)
from P3.M1.T1.S2, and the comm-generic `pool_owner_alive` from P3.M1.T1.S2.

**Success Definition:**
1. `selftest_owner_resolves_non_pi_harness` exists in `test/validate.sh`, is picked up by
   `compgen -A function | grep '^selftest_'` (the runner), and contains a positive `claude` case +
   a negative `xterm` case.
2. It spawns+reaps its OWN sim owners (`spawn_sim_owner 600 claude` / `600 xterm`) and **never**
   overwrites the shared `ABPOOL_CUR_OWNER` set by `setup()` (which `selftest_sim_owner_is_alive_pi`
   and `teardown` rely on).
3. Every code path reaps its spawned owners (`kill "$pid" … || true; wait "$pid" … || true`) —
   guaranteed by **"capture → reap → assert"** ordering (asserts run AFTER the reap).
4. The existing `selftest_sim_owner_is_alive_pi` stays GREEN and byte-for-byte UNTOUCHED (it proves
   `pi ∈ default set` still works; the new selftest proves the generalization).
5. `bash -n test/validate.sh` → rc 0; `shellcheck -S warning -s bash test/validate.sh` → rc 0; the
   new function introduces **zero new** shellcheck findings (the 5 pre-existing info findings stay
   intact, only their line numbers shift).

---

## Why

- P3 (Decision O9) generalized owner resolution from a hardcoded `"pi"` requirement to a
  **recognized-harness set** (PRD §2.11 default `pi,claude,codex,agy,antigravity`) and made the
  recorded comm the **actual matched comm** (PRD §2.4 step 1, §2.8). P3.M1.T1.S2 landed the
  generalized `pool_owner_resolve` (TEST MODE records real `/proc/comm`) + comm-generic
  `pool_owner_alive`; P3.M2.T1.S1 landed the generalized `spawn_sim_owner [COMM]`.
- **Nothing currently proves the non-`pi` path empirically.** The only owner-aliveness selftest
  (`selftest_sim_owner_is_alive_pi`) exercises the `pi` comm exclusively. This item closes that
  gap: a positive case (`claude`) proves a recognized non-`pi` harness resolves + is accepted, and a
  negative case (`xterm`) proves a non-harness comm is rejected (the identity-isolation guarantee
  that prevents one owner's lease being adopted by an unrelated process).
- Scope is tight: ONE new selftest function. It does NOT touch `lib/pool.sh`, any caller, or any
  other test, and it adds no user-facing surface.

---

## What

### User-visible behavior
None — `selftest_*` functions are test-internal; never shipped, never called by the pool binary.
They run only when `test/validate.sh` is executed directly (the `BASH_SOURCE` gate, validate.sh:754).

### Technical change (one new function, confined to `test/validate.sh`)
Add `selftest_owner_resolves_non_pi_harness()` after `selftest_sim_owner_is_alive_pi`'s closing
brace (line 329). Structure per case:

**POSITIVE (`claude` resolves):** `pid="$(spawn_sim_owner 600 claude)"`;
`st="$(_pool_get_starttime "$pid")"`; drive resolve in TEST MODE via inline single-command env
assignment `AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$st" pool_owner_resolve`;
capture `resolve_comm="$POOL_OWNER_COMM"` and `resolve_pid="$POOL_OWNER_PID"`; capture
`alive_rc` from `pool_owner_alive "$pid" "$st" "$resolve_comm" || alive_rc=$?`; **reap**; then assert
`resolve_comm == "claude"`, `resolve_pid != "0"`, `alive_rc == 0`.

**NEGATIVE (`xterm` rejected):** `pid="$(spawn_sim_owner 600 xterm)"`; `st` as above;
`real_comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"`; `alive_rc=0;
pool_owner_alive "$pid" "$st" "claude" || alive_rc=$?`; **reap**; then assert `real_comm == "xterm"`
and `alive_rc != 0`.

### Success Criteria
- [ ] New function `selftest_owner_resolves_non_pi_harness()` present after `selftest_sim_owner_is_alive_pi`.
- [ ] Positive case asserts `POOL_OWNER_COMM == "claude"` (resolve records actual comm),
      `POOL_OWNER_PID != "0"` (resolved), `pool_owner_alive … "claude"` rc 0 (accepted).
- [ ] Negative case asserts real `/proc` comm `== "xterm"` and `pool_owner_alive … "claude"` rc ≠ 0
      (an xterm process is rejected as `claude`).
- [ ] Each spawned owner is reaped (`kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true`)
      BEFORE any assert on it ("capture → reap → assert").
- [ ] `ABPOOL_CUR_OWNER` is never assigned by this function (setup's shared pi owner untouched).
- [ ] `selftest_sim_owner_is_alive_pi` is NOT modified.
- [ ] `bash -n test/validate.sh` rc 0; `shellcheck -S warning -s bash test/validate.sh` rc 0.

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact file, the exact anchor, the verbatim
function to add, the load-bearing reaping + env-override gotchas (host-verified), the honest
static-check gates, and the scope boundaries. Nothing else is required._

### Documentation & References
```yaml
- file: test/validate.sh
  why: TARGET FILE. Contains spawn_sim_owner [SECONDS] [COMM] (128), _abpool_global_cleanup trap (171),
       setup() (204) which exports AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME + sets ABPOOL_CUR_OWNER,
       the template selftest_sim_owner_is_alive_pi (314–329), and _run_selftest_suite (728–757).
  pattern: selftest_* bodies are auto-discovered (compgen|grep '^selftest_'|sort), run via
           `if "$fn"` in the MAIN shell (no subshell ⇒ EXIT trap never fires mid-suite), share ONE
           setup() for the whole suite. Use assert_eq EXPECTED ACTUAL LABEL + _fail + `return 1`.
  critical: do NOT call setup() again, do NOT wrap the body in `( … )` (AGENTS.md §4), do NOT assign
            ABPOOL_CUR_OWNER. Insert AFTER the `}` at line 329, BEFORE selftest_admin_is_executable (331).

- file: lib/pool.sh
  why: pool_owner_resolve (499, TEST MODE ~524–556 reads REAL /proc/comm into POOL_OWNER_COMM),
       pool_owner_alive (638, 3-check ladder, comm-generic), _pool_get_starttime (425).
  critical: pool_owner_resolve is NEVER fatal (always return 0) and resets POOL_OWNER_* globals at
            the top of each call. pool_owner_alive returns 1 (never fatal) on comm/starttime mismatch.
            DO NOT edit lib/pool.sh (M1 scope, already Complete).

- file: plan/003_afc2f15931ab/P3M2T1S1/PRP.md
  why: the CONTRACT for the prerequisite. Confirms spawn_sim_owner [SECONDS] [COMM] (COMM default
       "pi"), the preserved mktemp "abpool-pi" prefix, and the 15-char guard. Treat as already landed.
  critical: S1 is the SOLE prerequisite; this item must not duplicate or revert its change.

- file: plan/003_afc2f15931ab/architecture/test_code_map.md
  why: §2 (template selftest), §4 (single-setup runner + reaping discipline), §5b (this selftest's spec).
  critical: line numbers in the map are PRE-S1 and have shifted — re-derive with grep before editing.

- file: test/release_reaper.sh
  why: _release_kill_owner_and_reap_zombie (141–144) is the codebase's sanctioned kill+wait reap idiom.
  pattern: `kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true`.
  critical: use the SAME idiom (see Known Gotchas — `wait` may return 127 for subshell-spawned pids;
            harmless because the kill terminates the process and the subreaper reaps the zombie).

- url: https://man7.org/linux/man-pages/man5/proc_pid_comm.5.html
  why: comm = basename of the executed ELF (why spawn_sim_owner's temp file NAME becomes the comm),
       truncated to 15 chars (TASK_COMM_LEN). claude (6) and xterm (5) are both well under 15.

- file: AGENTS.md
  why: §1 forbids running the suite / spawning processes during planning; §3 mandates reaping;
       §4 the single-setup + no-subshell + capture-before-assert disciplines.
  critical: validation is STATIC ONLY here. No `bash test/validate.sh`.
```

### Current codebase tree (relevant slice)
```
test/validate.sh        # FRAMEWORK: spawn_sim_owner [SECONDS] [COMM] (128), setup (204),
                       #   _abpool_global_cleanup trap (171), selftest_sim_owner_is_alive_pi (314),
                       #   _run_selftest_suite (728) — TARGET: add ONE selftest after line 329.
lib/pool.sh             # pool_owner_resolve (499) / pool_owner_alive (638) / _pool_get_starttime (425) — READ ONLY
test/release_reaper.sh  # _release_kill_owner_and_reap_zombie (141) — the reap idiom to mirror — READ ONLY
```

### Desired codebase tree (delta)
```
test/validate.sh       # MODIFIED: append selftest_owner_resolves_non_pi_harness() after line 329.
(no new files; no deletions; lib/pool.sh untouched.)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL — guaranteed reaping under set -e (AGENTS.md §3/§4): this selftest spawns its OWN owners
# and must reap them on EVERY path. Use "capture → reap → assert" ordering: collect all assertion
# values FIRST (starttime, resolve globals, alive-rc, real-comm), THEN kill+wait, THEN assert.
# Between spawn and reap every op is set -e-EXEMPT (assignments; non-fatal pool_owner_resolve;
# `pool_owner_alive … || alive_rc=$?`; `cat … || true`), so the reap path is always reached.

# CRITICAL — the kill+wait idiom and reparenting (host-verified): spawn_sim_owner is consumed via
#   pid="$(spawn_sim_owner …)"  (a command subshell), so its backgrounded child is reparented and
# the parent's `wait "$pid"` returns 127 ("not a child"). This is HARMLESS: `kill` terminates the
# process; the subreaper reaps the zombie; `|| true` masks the 127; and we never re-check a killed
# owner's liveness. Mirror _release_kill_owner_and_reap_zombie EXACTLY (the rest of the suite does).

# CRITICAL — do NOT clobber the shared owner: setup() sets ABPOOL_CUR_OWNER (the suite-wide pi owner
# killed by teardown/trap). Use LOCAL vars (pid/st/...) only. Never `ABPOOL_CUR_OWNER=…` here.

# CRITICAL — inline env override reverts (host-verified): `AGENT_BROWSER_POOL_OWNER_PID="$pid" …
# pool_owner_resolve` overrides the EXPORTED env for that ONE call and reverts after, so the later
# selftest_sim_owner_is_alive_pi still sees setup's pi owner. Do NOT `export` new values for these.

# CRITICAL — set -e + the reject case: a BARE `pool_owner_alive … "claude"` on the xterm process
# returns 1 and would ABORT the function. ALWAYS capture via `pool_owner_alive … || alive_rc=$?`
# (the `||` list is errexit-exempt) and assert on alive_rc afterward.

# shellcheck baseline (verified): plain `shellcheck -s bash test/validate.sh` is rc 1 with 5 PRE-
# EXISTING info findings (lines 29 SC1091; 599/629/659/691 SC2016) — all intentional, OUT OF SCOPE.
# Gate on `shellcheck -S warning` (rc 0) AND assert the info count stays 5 with NONE in the new
# function. Do NOT "fix" the 5 info findings here.

# `set -euo pipefail` is active (validate.sh shebang + pool.sh). Declare all locals in one bare
# `local` line then assign separately (avoids SC2155; matches the file's existing style).
```

---

## Implementation Blueprint

### Exact addition (one contiguous block)

Insert the following block into `test/validate.sh` **immediately after the closing `}` of
`selftest_sim_owner_is_alive_pi` (currently line 329) and before `selftest_admin_is_executable()`
(currently line 331)** — i.e. into the single blank line between them:

```bash

# selftest_owner_resolves_non_pi_harness — POSITIVE: a recognized non-pi harness ('claude')
# resolves via pool_owner_resolve's TEST MODE (which records the ACTUAL /proc comm, not a hardcoded
# "pi"), is marked resolved (POOL_OWNER_PID!=0), AND pool_owner_alive accepts it; NEGATIVE: a
# non-harness comm ('xterm') is REJECTED by pool_owner_alive (a lease expecting comm 'claude' must
# not adopt an xterm process — identity isolation, PRD §2.13). Exercises the generalized
# spawn_sim_owner [COMM] (P3.M2.T1.S1) + pool_owner_resolve's actual-comm TEST MODE (P3.M1.T1.S2).
#
# Runs under the single-setup runner (_run_selftest_suite): NO setup() re-call; the body runs via
# `if "$fn"` in the MAIN shell (no subshell ⇒ the EXIT trap never fires mid-suite). It spawns+reaps
# its OWN sim owners and MUST NOT overwrite the shared ABPOOL_CUR_OWNER (setup's pi owner, kept
# alive for the whole suite incl. selftest_sim_owner_is_alive_pi).
#
# REAPING (AGENTS.md §3/§4 — GUARANTEED): "capture → reap → assert" ordering. Every spawned owner
# is kill+wait'd BEFORE any assert on it, so an assert failure (return 1 under set -e) can never
# leak a process. Between spawn and reap every op is set -e-exempt (assignments; non-fatal
# pool_owner_resolve; `pool_owner_alive … || alive_rc=$?`; `cat … || true`) ⇒ the reap always runs.
# The kill+wait idiom mirrors _release_kill_owner_and_reap_zombie (release_reaper.sh): the spawned
# child is reparented out of the $(spawn_sim_owner) subshell so `wait` may return 127 — harmless
# (the kill terminates it; the subreaper reaps the zombie; we never re-check a dead owner). Temp
# bin dirs (/tmp/abpool-pi.*) are reaped by the EXIT trap's comm-agnostic glob backstop.
selftest_owner_resolves_non_pi_harness() {
    local pid st resolve_comm resolve_pid real_comm alive_rc

    # --- POSITIVE: recognized non-pi harness 'claude' resolves (PRD §2.4 step 1) ---
    pid="$(spawn_sim_owner 600 claude)"
    st="$(_pool_get_starttime "$pid")"
    # Drive resolve in TEST MODE for THIS pid only. The inline single-command env assignment
    # (VAR=val func) overrides the exported AGENT_BROWSER_POOL_OWNER_* (which setup set to its pi
    # owner) for THIS call and REVERTS after (host-verified) ⇒ no leakage into the later
    # selftest_sim_owner_is_alive_pi. pool_owner_resolve reads the REAL /proc/comm here.
    AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$st" pool_owner_resolve
    resolve_comm="$POOL_OWNER_COMM"      # the ACTUAL recorded comm ("claude")
    resolve_pid="$POOL_OWNER_PID"        # non-zero ⟹ resolved, not failed
    # pool_owner_alive must ACCEPT the claude process (comm + starttime both match). Capture rc
    # via `|| alive_rc=$?` (errexit-exempt) so a reject never aborts this body.
    alive_rc=0
    pool_owner_alive "$pid" "$st" "$resolve_comm" || alive_rc=$?
    # REAP before asserting (guaranteed cleanup regardless of the asserts below).
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # Asserts (deferred until after the reap):
    assert_eq "claude" "$resolve_comm" "resolve recorded actual comm (claude)" || return 1
    [[ "$resolve_pid" != "0" ]] || { _fail "resolve set POOL_OWNER_PID=0 (did not resolve)"; return 1; }
    [[ "$alive_rc" -eq 0 ]] || { _fail "pool_owner_alive rejected the live claude owner (rc=$alive_rc)"; return 1; }

    # --- NEGATIVE: non-harness comm 'xterm' is rejected (identity isolation, PRD §2.13) ---
    pid="$(spawn_sim_owner 600 xterm)"
    st="$(_pool_get_starttime "$pid")"
    real_comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    # pool_owner_alive with EXPECTED_COMM="claude" MUST reject an xterm process (decision-ladder
    # step b: /proc/<pid>/comm != expected). Capture rc via `|| alive_rc=$?`.
    alive_rc=0
    pool_owner_alive "$pid" "$st" "claude" || alive_rc=$?
    # REAP before asserting.
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # Asserts:
    assert_eq "xterm" "$real_comm" "simulated owner /proc comm (negative case)" || return 1
    [[ "$alive_rc" -ne 0 ]] || { _fail "pool_owner_alive ACCEPTED an xterm process as 'claude' (identity leak)"; return 1; }
}
```

### Implementation Tasks (ordered)

```yaml
Task 1: LOCATE the insertion anchor (re-derive line numbers — S1 shifted them)
  - RUN: grep -nE '^(selftest_sim_owner_is_alive_pi|selftest_admin_is_executable)\(\)' test/validate.sh
  - CONFIRM: selftest_sim_owner_is_alive_pi's body ends with the line `}` (the one after the
            `pool_owner_alive "$pid" … "pi" \  || { _fail …; return 1; }` block), followed by a
            blank line and `selftest_admin_is_executable() {`.

Task 2: EDIT test/validate.sh — insert the block from "Exact addition" between that `}` and the
        blank line / selftest_admin_is_executable.
  - PRESERVE: the existing selftest_sim_owner_is_alive_pi body byte-for-byte (it stays GREEN).
  - DO NOT TOUCH: lib/pool.sh, any other selftest, the runner, setup/teardown, the trap, any caller
            in release_reaper.sh / concurrency.sh / transparency.sh. (transparency.sh:528 message
            text is P3.M2.T1.S3's scope, not here.)
  - DO NOT call setup(), do NOT wrap the body in `( … )`, do NOT assign ABPOOL_CUR_OWNER.

Task 3: STATIC VALIDATE (no suite run — AGENTS.md §1)
  - RUN: bash -n test/validate.sh                                    # expect rc 0
  - RUN: shellcheck -S warning -s bash test/validate.sh              # expect rc 0
  - RUN: shellcheck -s bash test/validate.sh 2>&1 | grep -E '^In test/validate.sh line'
          # expect exactly 5 lines (the pre-existing info findings: SC1091 @29, SC2016 @4 others).
          # CONFIRM none of the 5 fall inside the newly inserted function's line range.
  - RUN: compgen -A function | grep '^selftest_owner_resolves_non_pi_harness$'
          # (in a `bash -c 'source …'` form if you like) — sanity that it is discoverable. OPTIONAL.
```

### Implementation Patterns & Key Details
```bash
# (1) The guaranteed-reap shape (per phase): spawn → capture → reap → assert.
pid="$(spawn_sim_owner 600 claude)"
st="$(_pool_get_starttime "$pid")"
AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$st" pool_owner_resolve
resolve_comm="$POOL_OWNER_COMM"; resolve_pid="$POOL_OWNER_PID"
alive_rc=0
pool_owner_alive "$pid" "$st" "$resolve_comm" || alive_rc=$?   # `||` ⇒ errexit-exempt capture
kill "$pid" 2>/dev/null || true                                 # ← REAP (always reached)
wait "$pid" 2>/dev/null || true
assert_eq "claude" "$resolve_comm" "…" || return 1              # asserts LAST ⇒ never skip a reap

# (2) The reject-capture idiom (negative case) — bare pool_owner_alive returning 1 must NOT abort:
alive_rc=0
pool_owner_alive "$pid" "$st" "claude" || alive_rc=$?           # xterm != claude ⇒ rc 1 captured

# (3) Inline env override scopes the TEST-MODE pid to the single resolve call (reverts after):
AGENT_BROWSER_POOL_OWNER_PID="$pid" AGENT_BROWSER_POOL_OWNER_STARTTIME="$st" pool_owner_resolve
```

### Integration Points
```yaml
AUTO-DISCOVERY: none required — _run_selftest_suite enumerates selftest_* via compgen+sort.
DOWNSTREAM: nothing consumes this selftest; it is a terminal verification node for P3.M2.T1.
NO config / NO routes / NO migrations / NO user docs (test-internal).
NO conflict with the parallel P3.M2.T1.S1 (it lands spawn_sim_owner [COMM], which this CONSUMES).
```

---

## Validation Loop

### Level 1: Syntax & Style (run after the edit; STATIC ONLY — AGENTS.md §1)
```bash
bash -n test/validate.sh                                   # rc 0
shellcheck -S warning -s bash test/validate.sh             # rc 0
# Full picture (5 pre-existing info findings are expected & out of scope). After inserting ~45
# lines near line 330, the SC2016 findings (previously at 599/629/659/691) shift up by ~45:
shellcheck -s bash test/validate.sh 2>&1 | grep -E '^In test/validate.sh line'
#   expect exactly 5 lines; confirm NONE fall inside the new function's line range.
```
Expected: rc 0 for `bash -n` and `shellcheck -S warning`. If a NEW finding lands in the new
function, fix it before proceeding. Do NOT "fix" the 5 pre-existing info findings.

### Level 2: Unit / component
Covered by this very selftest once the suite runs (functional proof is the selftest's PASS under
the isolated runner). Not run during planning.

### Level 3: Integration
**DO NOT RUN THE SUITE HERE (AGENTS.md §1 — planning phase).** The implementing agent runs it
isolated + bounded per §2, e.g. (illustrative; the implementer owns the exact invocation):
```bash
timeout 120 env -i HOME="$(mktemp -d)" PATH="/usr/bin:/bin" bash test/validate.sh
```
Expected (when the implementer runs it): the new selftest PASSES (positive + negative), and
`selftest_sim_owner_is_alive_pi` still PASSES (untouched). The whole selftest_* run stays
Chrome-free for these two bodies (they use only lib primitives + simulated owners).

### Level 4: Reaping discipline (process hygiene — AGENTS.md §3)
Before ending any turn that executed a live run, confirm no orphans:
```bash
pgrep -af 'abpool-pi|/usr/bin/sleep' || true     # expect empty
ls -d /tmp/abpool-pi.* 2>/dev/null || true       # expect empty (trap glob backstop reaped them)
```
Kill+wait any PID you spawned; the `/tmp/abpool-pi.*` temp bin dirs are reaped by the trap's
comm-agnostic `rm -rf -- /tmp/abpool-pi.*` backstop (the prefix was deliberately preserved in S1).

---

## Final Validation Checklist

### Technical Validation
- [ ] `bash -n test/validate.sh` → rc 0.
- [ ] `shellcheck -S warning -s bash test/validate.sh` → rc 0.
- [ ] No NEW shellcheck finding in the new function (pre-existing 5 info findings untouched; only
      their line numbers shift up).

### Feature Validation
- [ ] Positive case: `resolve_comm == "claude"`, `resolve_pid != "0"`, `pool_owner_alive … "claude"` rc 0.
- [ ] Negative case: `real_comm == "xterm"`, `pool_owner_alive … "claude"` rc ≠ 0.
- [ ] "capture → reap → assert" ordering in BOTH cases (asserts after the kill+wait).
- [ ] `ABPOOL_CUR_OWNER` never assigned by this function; `setup()` never re-called; no `( … )` body.

### Scope Discipline
- [ ] Only `test/validate.sh` touched; only the one new function added (after line 329).
- [ ] `selftest_sim_owner_is_alive_pi` byte-for-byte unchanged (stays GREEN).
- [ ] `lib/pool.sh`, `release_reaper.sh`, `concurrency.sh`, `transparency.sh` NOT modified.
- [ ] No test suite executed during planning; no Chrome booted; no orphan processes/temp dirs left.

---

## Anti-Patterns to Avoid
- ❌ Don't assert BEFORE reaping — a failing assert (`return 1` under set -e) would skip the kill and
  leak the simulated owner (AGENTS.md §3). Always capture → reap → assert.
- ❌ Don't call `pool_owner_alive … "claude"` on the xterm process as a BARE command — its non-zero
  return aborts under set -e. Capture via `|| alive_rc=$?`.
- ❌ Don't `export AGENT_BROWSER_POOL_OWNER_PID=…` or assign `ABPOOL_CUR_OWNER=…` — the inline
  single-command form reverts (host-verified) and clobbering the shared owner breaks the suite's
  other selftests + teardown.
- ❌ Don't wrap the body in a `( … )` subshell — the EXIT trap fires on subshell exit and would kill
  `ABPOOL_CUR_OWNER` (setup's pi owner) mid-suite (AGENTS.md §4).
- ❌ Don't call `setup()` (single-setup discipline; per-test setup is the known hang, AGENTS.md §4).
- ❌ Don't invent a new reap mechanism — mirror `_release_kill_owner_and_reap_zombie` exactly so this
  body matches the rest of the suite.
- ❌ Don't "fix" the 5 pre-existing `info`-level shellcheck findings — intentional, out of scope.
- ❌ Don't run the suite during planning (AGENTS.md §1).

---

## Confidence Score
**9/10.** The change is one new selftest function, fully specified verbatim with its exact anchor
and validated by static checks verified runnable in this tree. The three load-bearing subtleties —
(1) `set -e` not aborting between spawn and reap, (2) the inline env override reverting, (3) the
`kill||true; wait||true` idiom being safe despite `wait`'s 127 on reparented children — are all
host-verified in the research notes and consistent with existing suite code. The −1 is residual
empirical risk that the positive `claude`/negative `xterm` asserts behave exactly as the
decision-ladder predicts when the implementer runs the suite isolated; that run is the final proof
and is explicitly the implementer's job per AGENTS.md §1/§2.
