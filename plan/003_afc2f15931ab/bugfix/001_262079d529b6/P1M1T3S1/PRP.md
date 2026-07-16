# PRP — P1.M1.T3.S1: Add BUG-1 identity gate to `pool_ensure_connected` reconnect branch + fix broken existing test

> **Bugfix context**: This subtask fixes the **reconnect-branch half** of **Issue #3 (Minor)** from
> the QA report (`plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md` and
> `architecture/recon_issue3_ensure_connected.md`). `pool_ensure_connected` (lib/pool.sh:2508-2625)
> runs on **every driving call** (the hot path). Its reconnect branch answers a successful
> `curl /json/version` by calling `pool_daemon_connect` **without verifying the answerer is this
> lane's Chrome** — so a *foreign* Chrome that grabbed our port (narrow race: daemon restart + our
> Chrome dead + foreign Chrome binds the port) gets silently re-bound, a "1 agent = 1 browser"
> isolation break. The acquire path was already hardened against exactly this (`pool_cdp_is_ours` /
> BUG-1 in `_pool_launch_and_verify`); this subtask closes the gap on the per-call reconnect path.
>
> **SCOPE BOUNDARY (CRITICAL):** This subtask (S1) touches **ONLY**:
> (1) the jq extraction at lib/pool.sh:2532 (add `.chrome_pid` as a 5th field),
> (2) the reconnect branch at lib/pool.sh:2561-2572 (add a `pool_cdp_is_ours` identity gate), and
> (3) the inline comment above it (lib/pool.sh:2559-2560).
> Plus tests: fix `selftest_ensure_connected_rebinds_when_disconnected` (test/validate.sh:560-588) and
> ADD `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect` (after test/validate.sh:615).
>
> **OUT OF SCOPE (S2 owns these):** the relaunch-branch `pool_wait_cdp "$port"` 1-arg→3-arg fix
> (lib/pool.sh:2597), and the `pool_wait_cdp` / `pool_cdp_is_ours` docstring updates. S1 MUST NOT
> touch the relaunch branch or those docstrings.
>
> **LINE-NUMBER NOTE (verified against CURRENT tree, post-P1.M1.T1.S1):** P1.M1.T1.S1 (reaper,
> COMPLETE) inserted ~8 lines at lib/pool.sh:~2889 — that is **below** `pool_ensure_connected`
> (2508-2625), so our edit-site line numbers were NOT shifted. P1.M1.T2.S1 (doctor/ss, in PARALLEL)
> edits `pool_admin_doctor` (~4258+) and adds a test after test/validate.sh:~882 — also **below** our
> code (2508) and our test region (560-620). So neither parallel subtask shifts S1's line numbers.
> Edit sites are located by **content grep** in Task 0; exact current line numbers are quoted below.

---

## Goal

**Feature Goal**: Add the BUG-1 identity gate (`pool_cdp_is_ours`) to `pool_ensure_connected`'s
**reconnect branch** so that, when `curl /json/version` succeeds on the lane's port, the daemon is
re-bound **only after verifying the answerer is this lane's Chrome** (via the lease's `chrome_pid` +
`ephemeral_dir`). A mismatch (foreign Chrome answering our port) must **fall through to the relaunch
branch** instead of silently re-binding — closing the "1 agent = 1 browser" isolation gap on the
per-call hot path. The gate must be **backward-compatible**: when the lease has no valid `chrome_pid`
(old/provisional lanes, `chrome_pid=0`), skip the gate and preserve the legacy
connect-to-whatever-answers behavior so stale lanes are not broken. The function's return contract
(0=connected, 1=not) is **unchanged**; the only behavioral change is: foreign Chrome on reconnect →
relaunch instead of silent rebind. Also fix the one existing test that this change breaks, and add a
focused regression test that proves the gate blocks the foreign-Chrome rebind.

**Deliverable**:
1. **lib/pool.sh:2524-2538** — jq extraction comment + mapfile + assignments: add `.chrome_pid` as a
   5th field and coalesce null/non-numeric to `0`. (5 small edits in one contiguous block.)
2. **lib/pool.sh:2559-2572** — reconnect branch: insert the `pool_cdp_is_ours` identity gate between
   the successful `curl` and `pool_daemon_connect`, restructuring the single `if pool_daemon_connect`
   into a 3-way `if foreign … elif pool_daemon_connect … else …`. Update the inline comment above the
   branch to document the gate.
3. **test/validate.sh:560-588** — fix `selftest_ensure_connected_rebinds_when_disconnected`: add a
   `pool_cdp_is_ours() { return 0; }` stub to the body heredoc so the new gate passes and the
   reconnect branch fires as the test intends. Lease write and assertions UNCHANGED.
4. **test/validate.sh (after :615)** — ADD `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect`:
   a hermetic, timeout-bounded subshell that stubs `curl→0` (foreign Chrome answers) +
   `pool_cdp_is_ours→1` (NOT ours) and asserts `pool_daemon_connect` is NOT called and the function
   falls through to relaunch.
5. **No other files.** No docstring changes here (S2 owns `pool_wait_cdp`/`pool_cdp_is_ours`
   docstrings). No relaunch-branch change (S2 owns it). No consumer changes (the return contract is
   unchanged).

**Success Definition**:
- `grep -n '.session, .port, .ephemeral_dir, .connected, .chrome_pid' lib/pool.sh` matches the updated
  jq extraction at ~line 2532.
- `grep -n 'pool_cdp_is_ours "\$port" "\$ephemeral_dir" "\$chrome_pid"' lib/pool.sh` matches the new
  gate inside the reconnect branch (the relaunch branch does NOT call pool_cdp_is_ours directly — that
  is S2's `pool_wait_cdp` change).
- With a lease carrying a valid `chrome_pid>0` and `curl→0` + `pool_cdp_is_ours→1` (foreign), the
  reconnect branch does **NOT** call `pool_daemon_connect` — it falls through to relaunch (asserted by
  the new regression test).
- With a lease carrying `chrome_pid=0` (provisional/stale) and `curl→0`, the gate is **skipped** and
  the legacy reconnect behavior is preserved (asserted by a hermetic micro-check in the Validation Loop).
- The previously-breaking test `selftest_ensure_connected_rebinds_when_disconnected` PASSES again
  (after adding the `pool_cdp_is_ours()→0` stub).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean (project gate).
- `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- `bash test/validate.sh` exits 0 with BOTH ensure_connected selftests PASS + the new regression test PASS.

## User Persona

**Target User**: Any AI agent driving a browser lane through `agent-browser-pool` (the per-call hot
path `pool_ensure_connected` runs on every driving command). Secondary: operators/maintainers auditing
the pool's isolation guarantees.

**Use Case**: The narrow-but-real isolation race (PRD Issue #3, step 5): (1) lane N booted, Chrome on
port P, lease `connected:true`; (2) the `agent-browser` daemon is restarted (reboot/crash/upgrade) and
no longer knows session `abpool-N`; (3) lane N's Chrome dies, freeing port P; (4) a **foreign** Chrome
binds port P; (5) the agent's next driving call → `pool_ensure_connected` → `curl /json/version`
succeeds (foreign Chrome answers) → **before this fix**: `pool_daemon_connect` re-binds our daemon to
the foreign Chrome → `exec agent-browser` drives the WRONG browser, silently. **After this fix**: the
identity gate sees `pool_cdp_is_ours` return 1 (foreign) → falls through to relaunch → a fresh,
verified-ours Chrome is launched → no isolation break.

**User Journey**: Agent calls any driving subcommand → `pool_ensure_connected $LANE` → (the existing
connected/early-exit + curl logic runs) → on a successful curl, the NEW gate checks identity → if ours
(or no valid pid), reconnect as before; if foreign, relaunch → the agent always drives THIS lane's own
Chrome.

**Pain Points Addressed**:
- **Silent isolation break** (the core complaint): a foreign Chrome answering our port could be
  silently driven. The gate makes it impossible — foreign → relaunch.
- **Defense-in-depth inconsistency**: the acquire path was hardened (BUG-1 / `pool_cdp_is_ours`) but
  the far-more-frequent per-call reconnect path was not. This subtask makes the hot path match the
  acquire path's identity discipline.

## Why

- **Issue #3 (Minor)** from the QA report. The trigger is a narrow conjunction (daemon restart + our
  Chrome dead + foreign Chrome on our exact port), so severity is Minor — but it is a real
  inconsistency with the acquire path and contradicts PRD §1.3 "1 agent = 1 browser" / §2.13
  "isolation by construction." Closing it is cheap (one jq field + one 3-way branch) and high-value
  (the hot path that runs on every driving call).
- **The fix is narrowly scoped and backward-compatible.** The guard `[[ "$chrome_pid" =~ ^[0-9]+$ &&
  "$chrome_pid" -gt 0 ]]` means: enforce identity ONLY when we have a valid pid; old/provisional lanes
  with `chrome_pid=0` preserve the legacy connect-to-whatever-answers behavior. `pool_lease_write`
  always writes `chrome_pid` (lib/pool.sh:38), so every booted lane has a real pid; only genuinely
  stale/pre-boot lanes have `0` — and for those, the legacy path is correct (there is no Chrome identity
  to verify yet).
- **The identity primitive already exists and is battle-tested.** `pool_cdp_is_ours` (lib/pool.sh:1629)
  is the exact function the acquire path uses via `pool_wait_cdp`. Reusing it (not inventing a new
  check) keeps the two binding paths consistent.
- **Closes a test blind spot.** The existing ensure_connected self-tests stub `curl`/`pool_daemon_connect`
  to fixed return codes; NONE simulate a foreign Chrome answering the lane's port, so the gap is never
  observed. This subtask adds exactly that regression test.
- **One existing test breaks by design** (`selftest_ensure_connected_rebinds_when_disconnected`) — it
  stubs `curl→0` (reconnect branch) with a dead `chrome_pid=200` and no `DevToolsActivePort` file, so
  the new gate correctly rejects it → the test must be updated (add a `pool_cdp_is_ours()→0` stub).
  This is expected and documented (recon_issue3 §5, system_context.md "Test impact").

## What

User-visible behavior: **none in the common case** (our Chrome alive, or no valid pid → legacy path).
The only observable change is in the narrow foreign-Chrome race: instead of silently re-binding the
daemon to the foreign Chrome and returning `connected:true`, the function now **relaunches** a fresh
Chrome on the same dir+port (the existing relaunch branch) — exactly as if our Chrome had died. The
function's return contract (0=connected, 1=not) is unchanged.

### Behavior change (reconnect branch)

The reconnect branch currently (lib/pool.sh:2561-2572):
```bash
if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
    # Chrome ALIVE → the daemon just lost its binding. RECONNECT (cheap ~ms attach).
    if pool_daemon_connect "$session" "$port"; then
        pool_lease_update "$lane" connected true
        pool_lease_update "$lane" last_seen_at "$now"
        _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
        return 0
    fi
    _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
    pool_lease_update "$lane" last_seen_at "$now"
    return 1
fi
```
becomes (see Implementation Tasks Task 2 for the exact replacement):
```bash
if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
    # Something answers on $port. BUG-1 identity gate (Issue #3): is it OUR Chrome?
    if [[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]] \
        && ! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"; then
        # NOT ours (foreign Chrome) → do NOT rebind. Fall through to relaunch below.
        _pool_log "pool_ensure_connected: lane $lane foreign Chrome on port $port → relaunch"
    elif pool_daemon_connect "$session" "$port"; then
        # Ours (or no valid pid → legacy) → RECONNECT (cheap ~ms attach).
        pool_lease_update "$lane" connected true
        pool_lease_update "$lane" last_seen_at "$now"
        _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
        return 0
    else
        _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi
fi
```

### Success Criteria

- [ ] The jq extraction at lib/pool.sh:2532 reads **5 fields** incl. `.chrome_pid`; a 5th assignment
      `chrome_pid="${_f[4]:-}"` + a coalesce `[[ "$chrome_pid" =~ ^[0-9]+$ ]] || chrome_pid=0` exist.
- [ ] The reconnect branch calls `pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"` gated by
      `chrome_pid>0`, BEFORE `pool_daemon_connect`; a mismatch falls through to relaunch (no rebind).
- [ ] When `chrome_pid=0`, the gate is SKIPPED (legacy reconnect preserved) — asserted by a micro-check.
- [ ] `selftest_ensure_connected_rebinds_when_disconnected` has a `pool_cdp_is_ours() { return 0; }`
      stub and PASSES (its `_connect_called==1` + `connected→true` assertions hold).
- [ ] `selftest_ensure_connected_skips_rebind_when_connected` is UNCHANGED and still PASSES.
- [ ] NEW `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect` exists and asserts the daemon
      is NOT bound to the foreign Chrome + the function falls through to relaunch.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean.
- [ ] `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 (all selftests PASS).
- [ ] The relaunch branch (lib/pool.sh:2574-2625) and the `pool_wait_cdp`/`pool_cdp_is_ours` docstrings
      are **byte-unchanged** (those are S2's scope).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?"** → Yes. This PRP pins the exact line numbers (verified against the current 4577-LOC
`lib/pool.sh` and 1006-LOC `test/validate.sh`), quotes the current code verbatim at every edit site,
gives the verified replacement code, explains WHY the existing test breaks (and the exact one-line
fix), specifies the regression test's stubs + assertions (including the non-obvious requirement to
stub `pool_chrome_launch` + `pool_wait_cdp` for hermeticity), reproduces the bug rationale, and lists
the exact validation commands. The implementer needs no prior exposure beyond the quoted snippets.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/recon_issue3_ensure_connected.md
  why: THE recon doc for this exact bug. Verbatim line numbers, the exact current reconnect-branch
        code, the exact jq extraction, pool_cdp_is_ours's signature/semantics, the data-flow diagram,
        and a "Start here" hit-list. Authoritative for the code state.
  pattern: '§1 (pool_ensure_connected), §2 (pool_cdp_is_ours), "Architecture / data flow" diagram,
            "Start here" (lists the 4 edit sites — note: this PRP does the jq + reconnect sites +
            the broken test; the relaunch site + docstrings are S2).'
  gotcha: '§5 marks selftest_ensure_connected_rebinds_when_disconnected as "WILL BREAK … MUST be
            updated: stub pool_cdp_is_ours()→0, or create a DevToolsActivePort file + use pid 1."
            This PRP uses Option A (the stub) — simpler and sufficient.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/system_context.md
  why: 'Confirms Issue 3's location, root cause, fix surface (reconnect: extract chrome_pid + gate on
        pool_cdp_is_ours; relaunch: 3-arg pool_wait_cdp), the CRITICAL test impact (rebind test
        breaks), and the test-infrastructure constraints (single-setup runner; AGENTS.md §3/§4).'
  pattern: '"Fix surface (reconnect)" is EXACTLY this PRP. "Fix surface (relaunch)" + "Docstring
            impact" are S2 — do NOT implement them here.'
  gotcha: 'system_context explicitly assigns the relaunch pool_wait_cdp change + both docstrings to a
            LATER subtask (S2). Stay in scope: reconnect branch + jq extraction + comment + the 2 tests.'

- file: lib/pool.sh
  why: 'THE file being edited. Read pool_ensure_connected (2508-2625), pool_cdp_is_ours (1614-1652),
        pool_wait_cdp (1687-1741 — for context only; S2 edits it), _pool_launch_and_verify (2282-2351
        — the hardened REFERENCE whose 3-arg pool_wait_cdp pattern S2 will mirror), and
        pool_lease_write (713 — to confirm chrome_pid is field 9 / JSON key "chrome_pid").'
  pattern: 'pool_cdp_is_ours (1629-1652) is the EXACT function to call — 3 args (PORT UDD PID),
            2-signal check (DevToolsActivePort line1==PORT AND /proc/PID exists), returns 0=ours /
            1=not-provably-ours (NON-FATAL). The reconnect gate mirrors how pool_wait_cdp calls it
            (lib/pool.sh:1720-1722): `if pool_cdp_is_ours "$port" "$user_data_dir" "$expected_pid";
            then return 0; fi`.'
  gotcha: 'pool_cdp_is_ours is NON-FATAL (returns 1, never pool_die) — so `! pool_cdp_is_ours …` is
            a clean branch under set -e (the ! makes it errexit-exempt). The guard
            `[[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]]` is REQUIRED: without it, a
            chrome_pid=0 lane (provisional/stale) would always fail the identity check and never
            reconnect. The guard preserves legacy behavior for pid-less lanes.'

- file: test/validate.sh
  why: 'The test framework. FIX selftest_ensure_connected_rebinds_when_disconnected (560-588 — add one
        stub line). ADD selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (after
        selftest_ensure_connected_skips_rebind_when_connected at :615, before the EADDRINUSE comment
        at :617). The single-setup _run_selftest_suite (test/validate.sh:~890) auto-discovers any
        selftest_* function via `compgen -A function | grep "^selftest_" | sort`.'
  pattern: 'selftest_ensure_connected_rebinds_when_disconnected (560-588) is the EXACT template for
        the new test: outdir under $ABPOOL_TEST_ROOT, body.sh heredoc (<<'"'"'EOF'"'"'), source the lib,
        pool_config_init + pool_state_init, write a lease via pool_lease_write, STUB the relevant
        functions, run pool_ensure_connected, assert via `test`, run body.sh via `timeout 15 bash
        "$script" "$ABPOOL_REPO" "$outdir"`, assert_eq "0" "$rc".'
  gotcha: 'Do NOT use run_test/abpool_run_suite for this — that path calls setup() per test (spawns a
            sim-owner process) and AGENTS.md §4 forbids >1 process-spawning setup() call in a shared
            sandbox (the 3rd call hangs). The selftest_* prefix is auto-picked by the SINGLE-SETUP
            _run_selftest_suite. ALSO: the body runs in a SUBSHELL (via `bash "$script"`) so all stubs
            are naturally scoped — they do NOT leak to the rest of the suite.'

- file: PRD.md
  why: '§1.3 goal #2 ("1 agent = 1 browser"), §2.4 step 4 (ENSURE CONNECTED), §2.13 ("isolation by
        construction"), §2.14 ("Chrome crash mid-task → relaunch"). The reconnect gate enforces
        §1.3/§2.13 on the hot path; the relaunch-on-mismatch behavior is exactly §2.14.'
  pattern: '§2.4 step 4 is the ENSURE CONNECTED contract (return 0=connected, 1=not) — UNCHANGED by
            this PRP; only the internal rebind-vs-relaunch decision changes for the foreign-Chrome case.'
  gotcha: 'PRD §2.14 already defines "Chrome crash mid-task → relaunch" — the foreign-Chrome case is
            morally identical (the lane's Chrome is not the answerer) and reuses the existing relaunch
            branch verbatim (no new teardown path).'

# External authoritative docs (minimal — this is a small structural fix reusing an existing primitive)
- url: https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html
  why: 'the `if A && ! B; then …; elif C; then …; else …; fi` form — how the 3-way reconnect branch is
        structured so (a) the identity-mismatch path falls through (no return → reaches relaunch), (b)
        the legacy/connect path returns 0, (c) the connect-failed path returns 1.'
  critical: 'the `! pool_cdp_is_ours …` is the right operand of `&&` in an `if` condition → errexit-
            exempt AND its non-zero (foreign) result makes the whole `&&` TRUE → the foreign branch
            fires. This is intentional and correct: foreign → log + fall through.'
  section: search for "if" and "Compound Commands" → "The if Command".

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: '"Declare and assign separately" — the existing code already does `local json session port …`
        then assigns via mapfile/`${_f[N]:-}`. The new chrome_pid assignment follows the SAME pattern
        (no `local x=$(…)` masking). SC2086 (quote expansions) does not apply (chrome_pid is used only
        in `[[ ]]` / arithmetic).'
  critical: 'add `chrome_pid` to the existing `local json session port ephemeral_dir connected now`
            declaration at lib/pool.sh:2509-2510 so it is set -u safe. (The PRP Task 1 includes this.)'

# Prior/parallel-subtask contracts (treated as already-implemented truth)
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T2S1/PRP.md
  why: 'P1.M1.T2.S1 (Issue 2 — doctor/ss) runs IN PARALLEL. It edits pool_admin_doctor (lib/pool.sh
        ~4258-4300 + docstring ~4145-4186) and adds selftest_doctor_ss_optional_when_missing
        (test/validate.sh after ~882). THIS subtask edits pool_ensure_connected (lib/pool.sh 2508-2625)
        + the ensure_connected tests (test/validate.sh 560-620). Disjoint functions + disjoint test
        regions → no merge conflict and no line-number shift (T2 edits are all BELOW our sites).'
  pattern: 'T2 also ADDS a selftest_* body to validate.sh (after selftest_doctor_flags_disconnected_lease
            at ~882). THIS subtask ADDS its body after selftest_ensure_connected_skips_rebind_when_connected
            (:615) — a DIFFERENT region (560-620 vs 852-990) → no textual merge conflict.'
  gotcha: 'Both subtasks APPEND selftest bodies. To stay merge-clean, place the new
            selftest_ensure_connected_rejects_foreign_chrome_on_reconnect IMMEDIATELY AFTER
            selftest_ensure_connected_skips_rebind_when_connected (test/validate.sh:615), before the
            `# --- pool_chrome_launch EADDRINUSE detection` comment at :617. Order does not affect
            discovery (_run_selftest_suite auto-sorts) — only textual merge cleanliness.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T1S1/PRP.md
  why: 'P1.M1.T1.S1 (Issue 1 — reaper anchoring) is COMPLETE. It edited pool_reap_orphan_dirs
        (lib/pool.sh ~2874-2902) + added selftest_reap_orphan_dirs_kills_only_target_lane
        (test/validate.sh ~852). Its ~8-line insertion at ~2889 is BELOW pool_ensure_connected (2508),
        so it did NOT shift our line numbers (verified: pool_ensure_connected is still at 2508).'
  pattern: 'confirms the single-setup selftest_* pattern + hermetic timeout-bounded subshell shape
            that THIS subtask's new regression test must follow.'
  gotcha: 'no interaction — disjoint functions, disjoint test regions.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md
  why: 'the QA report that identified Issue 3. Confirms the bug (reconnect branch rebinds without
        identity check), the location (lib/pool.sh:2561-2572 reconnect; 2597 relaunch — note S1 does
        ONLY the 2561-2572 site), the 5-step race, and the suggested fix (gate on pool_cdp_is_ours
        using the lease chrome_pid; guard so pid-less lanes keep legacy behavior).'
  pattern: 'TEST_RESULTS §"Minor Issues" Issue 3 — the "Suggested Fix" is EXACTLY this PRP (reconnect
            half). The "Add a test that stubs curl to succeed while the lease's DevToolsActivePort/
            chrome_pid disagree" is EXACTLY the new regression test.'
  gotcha: 'TEST_RESULTS also lists Issues 1 (reaper — done in T1) and 2 (doctor — T2). Stay in scope:
            Issue 3 RECONNECT branch only.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                   # 4577 LOC
│                                 # pool_ensure_connected at 2508-2625
│                                 #   jq extraction at 2532 (ADD .chrome_pid as 5th field)
│                                 #   field decls at 2509-2510 (ADD chrome_pid to local decl)
│                                 #   reconnect branch at 2559-2572 (ADD identity gate + comment)
│                                 #   relaunch branch at 2574-2625 (S2's scope — DO NOT TOUCH)
│                                 # pool_cdp_is_ours at 1614-1652 (the primitive to call — READ ONLY)
│                                 # pool_wait_cdp at 1687-1741 (S2 edits — DO NOT TOUCH)
│                                 # _pool_launch_and_verify at 2282-2351 (the hardened REFERENCE)
│                                 # pool_lease_write at 713 (confirms chrome_pid = field 9 / JSON key)
├── test/
│   └── validate.sh               # 1006 LOC
│                                 # selftest_ensure_connected_rebinds_when_disconnected at 560-588 (FIX)
│                                 # selftest_ensure_connected_skips_rebind_when_connected at 593-615 (UNTOUCHED)
│                                 # ADD selftest_ensure_connected_rejects_foreign_chrome_on_reconnect after 615
│                                 # _run_selftest_suite at ~890 (auto-discovers selftest_*)
│                                 # assert_eq at 57
└── plan/003_afc2f15931ab/bugfix/001_262079d529b6/
    ├── architecture/recon_issue3_ensure_connected.md   # THE recon doc (exact code + line numbers)
    ├── architecture/system_context.md                   # host env + test isolation + scope split (S1 vs S2)
    ├── TEST_RESULTS.md                                 # QA report (Issue 3 confirmed)
    ├── P1M1T1S1/PRP.md                                 # COMPLETE parallel subtask (Issue 1 — disjoint)
    ├── P1M1T2S1/PRP.md                                 # IN-PARALLEL subtask (Issue 2 — disjoint)
    └── P1M1T3S1/                                       # THIS subtask
        ├── PRP.md                                      # THIS FILE
        └── research/notes.md                           # verified line numbers + test-design rationale
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh       — jq extraction (+1 field +1 coalesce +1 local decl) + reconnect branch
#                       (restructure single-if into 3-way if/elif/else + identity gate) + comment (~+8 lines)
#   test/validate.sh  — FIX selftest_ensure_connected_rebinds_when_disconnected (+1 stub line in body heredoc)
#                     — ADD selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (~35-line body)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the gate's backward-compat guard): the guard
#   `[[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]]`
# is MANDATORY. Without it, a provisional/stale lane with chrome_pid=0 would ALWAYS fail
# pool_cdp_is_ours (expected_pid must be numeric AND /proc/0 doesn't exist → return 1) and NEVER
# reconnect — breaking legacy/stale lanes. The guard means: only enforce identity when we HAVE a
# valid pid; otherwise preserve the old connect-to-whatever-answers behavior. pool_lease_write always
# writes chrome_pid (lib/pool.sh:38), so every booted lane has a real pid; only genuinely
# pre-boot/stale lanes have 0.

# CRITICAL (why the gate must be in the RECONNECT branch, not the relaunch branch): the reconnect
# branch is the one that calls pool_daemon_connect on an EXISTING (curl-proven) answerer — the
# foreign-Chrome risk. The relaunch branch launches a FRESH Chrome and then pool_daemon_connect's it;
# its identity risk is the pool_wait_cdp 1-arg call (S2's scope). S1 does NOT touch the relaunch branch.

# CRITICAL (the existing test WILL BREAK — by design): selftest_ensure_connected_rebinds_when_disconnected
# (test/validate.sh:560-588) stubs curl()→0 (reconnect branch) with chrome_pid=200 (dead) and NO
# DevToolsActivePort file. After the fix, the gate fires (200>0) → pool_cdp_is_ours checks /proc/200
# (dead) + missing DevToolsActivePort → returns 1 → foreign → fall through to relaunch →
# pool_chrome_launch would launch REAL Chrome (AGENTS.md §1 violation!) AND _connect_called stays 0
# → the test's `test "$_connect_called" = "1"` assertion FAILS. FIX: add `pool_cdp_is_ours() { return 0; }`
# to the body heredoc → gate passes → reconnect fires as the test intends. (Option B — create a
# DevToolsActivePort file + use pid 1 — also works but Option A is simpler. This PRP uses Option A.)

# CRITICAL (the regression test MUST stub pool_chrome_launch + pool_wait_cdp for hermeticity): the
# naive assertion "pool_daemon_connect NOT called" is INSUFFICIENT — if the gate fails and we fall
# through to relaunch, the relaunch ALSO calls pool_daemon_connect (after a successful pool_wait_cdp),
# so _connect_called would be 1 regardless. To make the assertion load-bearing AND hermetic (no real
# Chrome), the regression test body MUST:
#   (1) stub pool_chrome_launch() → no-op (prevent REAL Chrome — AGENTS.md §1; also record
#       _relaunch_called=1 to PROVE fall-through), AND
#   (2) stub pool_wait_cdp() → 1 (simulate relaunch "CDP timeout" → pool_ensure_connected returns 1
#       BEFORE the relaunch's pool_daemon_connect fires), AND
#   (3) assert _connect_called==0 (the foreign-Chrome rebind did NOT happen) + _relaunch_called==1
#       (fell through to relaunch) + rc!=0.
# Without (1) the test boots real Chrome (sandbox wedge risk). Without (2) the relaunch's
# pool_daemon_connect fires and _connect_called==1 even with the fix → the test cannot distinguish
# fixed vs buggy. See Task 4.

# GOTCHA (set -e + the bare pool_chrome_launch call): the relaunch branch calls
# `pool_chrome_launch "$port" "$ephemeral_dir" "$lane"` BARE (not under `if`). Under set -e, a stub
# that returns non-zero would ABORT the body. So the regression test's pool_chrome_launch stub MUST
# `return 0` (no-op). (pool_wait_cdp is under `if !` so its stub can return 1 safely.)

# GOTCHA (set -e + pool_ensure_connected returning 1): in the regression test, pool_ensure_connected
# returns 1 (relaunch CDP timeout). Under set -e, a bare `pool_ensure_connected 1` returning 1 aborts
# the body. Capture with `ec=0; pool_ensure_connected 1 || ec=$?` (the `|| ec=$?` is errexit-exempt),
# then assert `test "$ec" != "0"`. This mirrors how the existing tests tolerate non-zero returns.

# GOTCHA (pool_cdp_is_ours is NON-FATAL): it returns 1 (not pool_die) when it cannot prove identity.
# So `! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"` is a clean branch under set -e (the
# `!` + being an `if` operand make it errexit-exempt). Do NOT wrap it in a `|| true` — the `!` already
# neutralizes set -e.

# GOTCHA (scope): this fix is ISSUE 3 RECONNECT BRANCH ONLY. Do NOT touch: the relaunch branch
# (lib/pool.sh:2574-2625), pool_wait_cdp (1687-1741), pool_cdp_is_ours (1614-1652), or any docstring.
# Those are S2. Do NOT fix Issue 1 (done) or Issue 2 (T2). One jq field + one 3-way branch + one
# comment + one test fix + one new test.

# GOTCHA (chrome_pid coalesce must handle jq's `null`): jq -r renders an ABSENT .chrome_pid as the
# bare word `null` (NOT empty). The coalesce `[[ "$chrome_pid" =~ ^[0-9]+$ ]] || chrome_pid=0` handles
# both empty and `null` (neither matches ^[0-9]+$ → falls to 0). This mirrors the existing `connected`
# coalesce pattern at lib/pool.sh:2538.

# GOTCHA (placement of the new regression test): place it IMMEDIATELY AFTER
# selftest_ensure_connected_skips_rebind_when_connected (test/validate.sh:615), BEFORE the
# `# --- pool_chrome_launch EADDRINUSE detection` comment at :617. This groups the 3 ensure_connected
# tests together and avoids merge conflicts with the parallel P1.M1.T2.S1 PRP (which adds a body near
# ~882). _run_selftest_suite auto-discovers via compgen, so order does not affect discovery.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. The only "structure" change is reading one more field
(`chrome_pid`) from the existing lease JSON (the key already exists — written by `pool_lease_write` at
lib/pool.sh:38/46) and using it in the reconnect branch's decision. `chrome_pid` is already part of the
lease schema; this PRP merely *reads* it on the hot path.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current function and confirm edit sites BEFORE touching anything
  - RUN (locate by CONTENT — line numbers are stable post-T1/T2 but verify):
        grep -n "Extract the 4 fields we need" lib/pool.sh          # → 2524 (the jq comment)
        grep -n ".session, .port, .ephemeral_dir, .connected'" lib/pool.sh  # → 2532 (the mapfile)
        grep -n '# --- c. NOT connected. Chrome alive?' lib/pool.sh # → 2560 (reconnect comment)
        grep -n 'if curl -sf "http://127.0.0.1:$port/json/version"' lib/pool.sh  # → 2561 (reconnect if)
  - READ lib/pool.sh:2508-2575 to confirm the current text matches the quotes in this PRP.
  - READ lib/pool.sh:1614-1652 (pool_cdp_is_ours) to confirm its 3-arg signature + NON-FATAL return.
  - CONFIRM chrome_pid is JSON key "chrome_pid": grep -n 'chrome_pid:' lib/pool.sh (→ pool_lease_write
        at :46; jq extraction must read .chrome_pid).
  - EXPECT: the jq extraction reads 4 fields; the reconnect branch is a single `if curl; then if
        pool_daemon_connect; then …; fi … fi` with NO identity check.

Task 1: EDIT lib/pool.sh — read chrome_pid from the lease (jq 5th field) + local decl + coalesce
  - EDIT 1a — the `local` declaration (lib/pool.sh:2509-2510). FIND:
        local lane="${1:-}"
        local json session port ephemeral_dir connected now
    REPLACE WITH:
        local lane="${1:-}"
        local json session port ephemeral_dir connected chrome_pid now
    (Add chrome_pid to the second local line — set -u safe; SC2155-clean.)
  - EDIT 1b — the jq comment (lib/pool.sh:2524). FIND:
        # Extract the 4 fields we need in ONE jq fork (comma → N lines; mapfile -t strips \n):
    REPLACE WITH:
        # Extract the 5 fields we need in ONE jq fork (comma → N lines; mapfile -t strips \n):
  - EDIT 1c — the jq mapfile + assignments (lib/pool.sh:2532-2538). FIND (the exact current block):
        mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")
        session="${_f[0]:-}"
        port="${_f[1]:-}"
        ephemeral_dir="${_f[2]:-}"
        connected="${_f[3]:-true}"
        [[ "$connected" == "true" || "$connected" == "false" ]] || connected=true
    REPLACE WITH:
        mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected, .chrome_pid' <<<"$json")
        session="${_f[0]:-}"
        port="${_f[1]:-}"
        ephemeral_dir="${_f[2]:-}"
        connected="${_f[3]:-true}"
        chrome_pid="${_f[4]:-}"
        [[ "$connected" == "true" || "$connected" == "false" ]] || connected=true
        # Issue #3 (S1): coalesce chrome_pid to 0 for the reconnect-branch identity gate. jq -r renders
        # an absent .chrome_pid as the bare word `null` (NOT empty) — neither `null` nor empty matches
        # ^[0-9]+$, so both fall to 0. The gate (step c) only fires for chrome_pid>0, so a 0 (provisional
        # / stale / pre-boot lane) preserves the legacy connect-to-whatever-answers behavior.
        [[ "$chrome_pid" =~ ^[0-9]+$ ]] || chrome_pid=0
  - WHY: the reconnect-branch identity gate needs this lane's chrome_pid (the BUG-1 expected pid).
        pool_lease_write always writes it (field 9 / JSON key chrome_pid), so every booted lane has a
        real pid. Reading it in the same ONE jq fork preserves the "ONE fork" idiom (pool_lane_is_stale).
  - GOTCHA: the coalesce MUST handle jq's `null` (absent field). The `connected` coalesce above it is
        the model. Do NOT use `chrome_pid="${_f[4]:-0}"` alone — that leaves the literal `null` string
        in place for a pid-less lease, which would then FAIL the gate's `=~ ^[0-9]+$` and (because the
        gate guards on it) be handled correctly anyway — but coalescing explicitly to 0 is clearer and
        matches the connected pattern.

Task 2: EDIT lib/pool.sh — add the identity gate to the reconnect branch (+ update comment)
  - LOCATE by content: grep -n '# --- c. NOT connected. Chrome alive?' lib/pool.sh  (→ 2560)
  - FIND (the exact current reconnect block, lib/pool.sh:2559-2572 — comment + curl + 2 branches):
        # --- c. NOT connected. Chrome alive? curl /json/version (NOT kill -0 — research §2). ---
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            # Chrome ALIVE → the daemon just lost its binding. RECONNECT (cheap ~ms attach).
            if pool_daemon_connect "$session" "$port"; then
                pool_lease_update "$lane" connected true
                pool_lease_update "$lane" last_seen_at "$now"
                _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
                return 0
            fi
            _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
            pool_lease_update "$lane" last_seen_at "$now"
            return 1
        fi
    REPLACE WITH:
        # --- c. NOT connected. Chrome alive? curl /json/version (NOT kill -0 — research §2). ---
        # BUG-1 identity hardening (Issue #3, S1): a successful curl only proves SOMETHING answers on
        # $port — not that it is THIS lane's Chrome. Before rebinding the daemon, verify identity via
        # pool_cdp_is_ours (DevToolsActivePort line1==$port AND our chrome_pid still alive). A foreign
        # Chrome on our port (narrow race: daemon restart + our Chrome dead + foreign Chrome grabbed
        # the port) must NOT be rebound — fall through to the relaunch branch below instead. The guard
        # `chrome_pid -gt 0` enforces identity ONLY for lanes with a valid pid; old/provisional lanes
        # (chrome_pid=0) preserve the legacy connect-to-whatever-answers behavior (no silent break of
        # stale lanes). pool_cdp_is_ours is NON-FATAL (returns 1, never pool_die) → `! pool_cdp_is_ours`
        # is a clean set -e branch. Mirrors the acquire path's pool_wait_cdp identity check (BUG-1).
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            # Something answers on $port. Is it OUR Chrome? (Only check when we have a valid pid.)
            if [[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]] \
                && ! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"; then
                # NOT ours (foreign Chrome) → do NOT rebind. Fall through to the relaunch branch below.
                _pool_log "pool_ensure_connected: lane $lane foreign Chrome on port $port → relaunch"
            elif pool_daemon_connect "$session" "$port"; then
                # Ours (or no valid pid → legacy) → the daemon just lost its binding. RECONNECT.
                pool_lease_update "$lane" connected true
                pool_lease_update "$lane" last_seen_at "$now"
                _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
                return 0
            else
                _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
                pool_lease_update "$lane" last_seen_at "$now"
                return 1
            fi
        fi
  - WHY: the 3-way if/elif/else encodes the three outcomes of a successful curl:
        (1) foreign Chrome (chrome_pid>0 AND pool_cdp_is_ours≠0) → log + FALL THROUGH (no return →
            reaches the relaunch branch) — THE FIX;
        (2) ours OR legacy (chrome_pid=0) AND pool_daemon_connect succeeds → reconnect, return 0;
        (3) connect fails → log + return 1.
        The `elif` (not a nested `if`) is what makes outcome (1) fall through cleanly: when the
        foreign branch is taken, none of the `elif`/`else` run, and control proceeds past the closing
        `fi` to the relaunch branch.
  - GOTCHA: `! pool_cdp_is_ours …` is the right operand of `&&` inside an `if` condition → both
        errexit-exempt AND its non-zero (foreign) result makes the `&&` TRUE → the foreign branch
        fires. This is intentional. Do NOT add `|| true`.
  - GOTCHA: do NOT add a `return` in the foreign branch — it MUST fall through to relaunch. A `return`
        there would drop the lane (no Chrome), which is wrong; relaunch gives it a fresh Chrome.
  - GOTCHA: keep the existing log strings byte-identical (the reconnect/connect-failed messages) so
        log-grep tests/observability are unaffected. Only the foreign-branch log is new.

Task 3: FIX test/validate.sh — selftest_ensure_connected_rebinds_when_disconnected (add 1 stub)
  - LOCATE: grep -n 'selftest_ensure_connected_rebinds_when_disconnected' test/validate.sh  (→ 560)
  - FIND (the body heredoc stubs, test/validate.sh:575-578 — the comment-free pool_daemon_connected
        line at :575 is UNIQUE in the file; the skips_rebind variant at :608 carries a trailing comment):
        pool_daemon_connected() { return 0; }
        curl()                  { return 0; }
        _connect_called=0
        pool_daemon_connect()   { _connect_called=1; return 0; }
    REPLACE WITH:
        pool_daemon_connected() { return 0; }
        curl()                  { return 0; }
        pool_cdp_is_ours()      { return 0; }   # ours → identity gate (Issue #3) passes → reconnect fires
        _connect_called=0
        pool_daemon_connect()   { _connect_called=1; return 0; }
  - WHY: after Task 1+2, the reconnect branch gates on pool_cdp_is_ours (chrome_pid=200>0). Without
        this stub, pool_cdp_is_ours checks /proc/200 (dead) + the missing DevToolsActivePort → returns 1
        → foreign → fall through to relaunch → pool_chrome_launch launches REAL Chrome (AGENTS.md §1
        violation) AND _connect_called stays 0 → the test FAILS. The stub makes the gate pass ("ours")
        → reconnect fires → _connect_called=1, connected→true → the test's assertions hold exactly as
        before. (Option A from the item spec; Option B — DevToolsActivePort file + pid 1 — also works
        but is more setup for no extra coverage.)
  - GOTCHA: the lease write at test/validate.sh:571 (`pool_lease_write 1 … 200 201 false`) is
        UNCHANGED — chrome_pid=200 is a valid positive int; the stub overrides the actual /proc check.
  - GOTCHA: the stub is scoped to the body.sh subshell (run via `timeout 15 bash "$script"`) → it does
        NOT leak to other selftests.

Task 4: ADD test/validate.sh — selftest_ensure_connected_rejects_foreign_chrome_on_reconnect
  - ADD a new function named `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect` (the
        _run_selftest_suite at test/validate.sh:~890 auto-discovers any selftest_* function — NO
        registration needed).
  - PLACE: IMMEDIATELY AFTER selftest_ensure_connected_skips_rebind_when_connected (test/validate.sh:615),
        BEFORE the `# --- pool_chrome_launch EADDRINUSE detection` comment at :617. Groups the 3
        ensure_connected tests; avoids merge conflict with P1.M1.T2.S1 (which adds a body near ~882).
  - FOLLOW pattern: selftest_ensure_connected_rebinds_when_disconnected (test/validate.sh:560-588) —
        the EXACT template: outdir under $ABPOOL_TEST_ROOT, body.sh heredoc (<<'EOF'), source the lib,
        pool_config_init + pool_state_init, write a lease via pool_lease_write, STUB the relevant
        functions, run pool_ensure_connected, assert via `test`, run body.sh via `timeout 15 bash
        "$script" "$ABPOOL_REPO" "$outdir"`, assert_eq "0" "$rc".
  - REFERENCE IMPLEMENTATION (the stubs are the load-bearing part — see "Known Gotchas" for WHY
        pool_chrome_launch + pool_wait_cdp MUST be stubbed for hermeticity + a load-bearing assertion):
      ----------------------------------------------------------------
      # --- pool_ensure_connected rejects a foreign Chrome on reconnect (Issue #3 / S1) ---
      # Regression for the BUG-1 identity gap on the reconnect branch. Models the PRD Issue #3
      # 5-step race: lane was connected (connected=true), daemon restarted (pool_daemon_connected→1
      # → step b falls through), a foreign Chrome answers our port (curl→0), and it is NOT ours
      # (pool_cdp_is_ours→1). THE INVARIANT: pool_daemon_connect must NOT be called (the daemon must
      # not be bound to the foreign Chrome) AND the function must fall through to relaunch.
      # Hermetic (NO real Chrome): pool_chrome_launch is stubbed to a no-op (also records
      # _relaunch_called to PROVE fall-through); pool_wait_cdp is stubbed→1 so the relaunch returns 1
      # BEFORE its own pool_daemon_connect (otherwise _connect_called would be 1 regardless and the
      # assertion could not distinguish fixed vs buggy).
      selftest_ensure_connected_rejects_foreign_chrome_on_reconnect() {
          local outdir script rc out
          outdir="$ABPOOL_TEST_ROOT/ensure-foreign"
          mkdir -p -- "$outdir"
          script="$outdir/body.sh"
          cat >"$script" <<'EOF'
      set -euo pipefail
      source "$1/lib/pool.sh"
      pool_config_init
      pool_state_init
      # Lease: connected=true (was connected before the daemon restart), valid chrome_pid (1 = init,
      # alive at /proc/1) so the identity gate's `chrome_pid -gt 0` predicate is TRUE and the gate FIRES.
      #   args: LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME CWD CHROME_PID CHROME_PGID CONNECTED
      pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 1000 "$2" 1 1 true
      # Stubs modeling the foreign-chrome-on-reconnect race (PRD Issue #3 step 5):
      pool_daemon_connected() { return 1; }   # daemon restarted → does NOT know our session (step b falls through)
      curl()                  { return 0; }   # SOMETHING answers on our port (a foreign Chrome)
      pool_cdp_is_ours()      { return 1; }   # ... and it is NOT ours (foreign) → gate must NOT rebind
      pool_chrome_launch()    { _relaunch_called=1; return 0; }   # no-op: prevent REAL Chrome (AGENTS.md §1)
      pool_wait_cdp()         { return 1; }   # relaunch "CDP timeout" → return 1 BEFORE its pool_daemon_connect
      _connect_called=0
      _relaunch_called=0
      pool_daemon_connect()   { _connect_called=1; return 0; }
      ec=0
      pool_ensure_connected 1 || ec=$?   # capture rc (returns 1 — relaunch CDP "timeout"); `|| ec=$?` is errexit-exempt
      test "$_connect_called"  = "0"   # THE INVARIANT: daemon NOT bound to the foreign Chrome on reconnect
      test "$_relaunch_called" = "1"   # fell through to relaunch (not silently rebound)
      test "$ec"               != "0"  # pool_ensure_connected returned non-zero (relaunch CDP timeout)
      EOF
          rc=0
          out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
          assert_eq "0" "$rc" "ensure_connected rejects foreign Chrome on reconnect (no rebind, falls through) (out: $out)" || return 1
      }
      ----------------------------------------------------------------
  - WHY pool_daemon_connected()→1 (not omitted): the lease has connected=true, so step b is
        `[[ true ]] && pool_daemon_connected`. For step b to fall through (so we REACH the reconnect
        branch), pool_daemon_connected MUST return non-zero. This faithfully models the PRD "daemon
        restarted → doesn't know session" scenario AND makes both the connected flag and the stub
        meaningful (no dead-code stub).
  - WHY pool_chrome_launch stub (return 0, records _relaunch_called): (a) prevent REAL Chrome
        (AGENTS.md §1 — the relaunch branch calls it bare); (b) _relaunch_called==1 PROVES the gate
        fell through to relaunch (pool_chrome_launch is ONLY called in the relaunch branch). Returning 0
        is REQUIRED — the bare call under set -e would abort the body if it returned non-zero.
  - WHY pool_wait_cdp stub (return 1): without it, the relaunch's `if ! pool_wait_cdp "$port"` would
        call the REAL pool_wait_cdp (curl stubbed→0, single-arg → check_identity=0 → returns 0), then
        the relaunch's pool_daemon_connect fires → _connect_called=1 → the test could NOT distinguish
        fixed (gate blocked reconnect) from buggy (no gate, reconnect bound foreign). Stubbing
        pool_wait_cdp→1 makes the relaunch take its CDP-timeout path (return 1, no connect) so
        _connect_called reflects ONLY the reconnect branch. (pool_wait_cdp is under `if !` so a
        returning-1 stub is set -e safe.)
  - WHY chrome_pid=1 (init) in the lease: it is a valid positive int (gate's `>0` is TRUE → gate
        fires) AND /proc/1 exists on Linux — so even if the pool_cdp_is_ours stub were removed, the
        pid-liveness signal would pass (only the DevToolsActivePort signal would fail). Using a live pid
        makes the test robust to the stub being (accidentally) removed. (The foreign verdict is still
        driven by the pool_cdp_is_ours()→1 stub, which short-circuits both signals.)
  - GOTCHA: the `|| return 1` after assert_eq makes fail-fast explicit. The heredoc uses `<<'EOF'`
        (quoted) so $1/$2/$(…) are NOT expanded by the outer shell — they expand when body.sh runs
        (matches the existing ensure_connected tests).
  - GOTCHA: do NOT spawn Chrome or a sim-owner — this is a pure-function + hermetic-subshell test. The
        body runs in its own `bash "$script"` subshell with its own scoped stubs. No processes to reap.

Task 5: VERIFY (the Validation Loop below) — run BEFORE claiming done.
  - Run Level 1 (syntax/lint) + Level 2 (micro-checks + full suite) + Level 3 (diff scope) in order.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — reading chrome_pid in the ONE jq fork (5 fields, comma → 5 lines; mapfile -t strips \n):
#     mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected, .chrome_pid' <<<"$json")
#     ...
#     chrome_pid="${_f[4]:-}"
#     [[ "$chrome_pid" =~ ^[0-9]+$ ]] || chrome_pid=0   # coalesce null/empty/non-numeric → 0
# WHY: preserves the "ONE jq fork" idiom (pool_lane_is_stale). The coalesce handles jq's `null`.

# Pattern B — the 3-way reconnect branch (the load-bearing restructure):
#     if curl -sf …/json/version >/dev/null 2>&1; then
#         if [[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]] \
#             && ! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"; then
#             _pool_log "... foreign Chrome on port $port → relaunch"   # FALL THROUGH (no return)
#         elif pool_daemon_connect "$session" "$port"; then
#             ...; return 0                                            # ours/legacy → reconnect
#         else
#             ...; return 1                                            # connect failed
#         fi
#     fi
# WHY the `elif` (not a nested `if`): when the foreign branch is taken, the elif/else do NOT run, so
# control falls past the `fi` to the relaunch branch. A nested `if`+`else` would also work but the
# flat if/elif/else matches the item spec exactly and reads as "one decision with 3 outcomes."

# Pattern C — pool_cdp_is_ours reuse (the BUG-1 primitive, lib/pool.sh:1629):
#     pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"   # 0=ours, 1=not-provably-ours (NON-FATAL)
# WHY: the EXACT function pool_wait_cdp calls on the acquire path (lib/pool.sh:1720). Reusing it (not a
# new check) keeps the two binding paths consistent. It is NON-FATAL (returns 1, never pool_die) so
# `! pool_cdp_is_ours …` is a clean set -e branch.

# Pattern D — the regression test's stub set (the non-obvious requirement):
#     pool_daemon_connected() { return 1; }   # daemon restarted (step b falls through)
#     curl()                  { return 0; }   # foreign Chrome answers
#     pool_cdp_is_ours()      { return 1; }   # NOT ours
#     pool_chrome_launch()    { _relaunch_called=1; return 0; }   # no-op (no real Chrome) + prove fall-through
#     pool_wait_cdp()         { return 1; }   # relaunch CDP "timeout" (return 1 BEFORE relaunch's connect)
#     pool_daemon_connect()   { _connect_called=1; return 0; }
# WHY pool_chrome_launch + pool_wait_cdp are stubbed: hermeticity (no real Chrome) + a load-bearing
# _connect_called==0 assertion (see "Known Gotchas"). Without BOTH, the test either wedges the sandbox
# (real Chrome) or cannot distinguish fixed vs buggy (relaunch's connect fires).
```

### Integration Points

```yaml
CODE (in-place edits in lib/pool.sh — no new files):
  - lib/pool.sh:2509-2510   `local` declaration: add chrome_pid (set -u safe)
  - lib/pool.sh:2524        jq comment: "4 fields" → "5 fields"
  - lib/pool.sh:2532-2538   jq mapfile: add '.chrome_pid'; + chrome_pid assignment + coalesce
  - lib/pool.sh:2559-2572   reconnect branch: comment block (+~8 lines) + 3-way if/elif/else gate

TEST (in-place edits + 1 addition in test/validate.sh):
  - test/validate.sh:575-578 FIX selftest_ensure_connected_rebinds_when_disconnected (+1 stub line)
  - test/validate.sh:+~35   ADD selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (after :615)

CONSUMER (DO NOT TOUCH — the return contract is unchanged):
  - pool_wrapper_main / every driving command calls pool_ensure_connected and acts on rc 0/1.
    Behavior is unchanged for rc; only the internal rebind-vs-relaunch decision changes for the
    foreign-Chrome case (which previously could not happen — there was no gate).

OUT OF SCOPE (S2 owns — DO NOT TOUCH in this PRP):
  - lib/pool.sh:2597        relaunch branch `if ! pool_wait_cdp "$port"` → 3-arg (S2)
  - lib/pool.sh:1687-1696   pool_wait_cdp docstring (S2)
  - lib/pool.sh:1614-1628   pool_cdp_is_ours docstring (S2)

PARALLEL SUBTASK (P1.M1.T2.S1 — disjoint, no conflict):
  - edits pool_admin_doctor (lib/pool.sh ~4258-4300 + docstring ~4145-4186) + adds
    selftest_doctor_ss_optional_when_missing (test/validate.sh after ~882).
  - THIS subtask edits pool_ensure_connected (lib/pool.sh 2508-2625) + ensure_connected tests
    (test/validate.sh 560-620). Disjoint functions + disjoint test regions → no merge conflict.
  - T2's edits are all BELOW pool_ensure_connected AND below our test region → no line-number shift.

CONFIG: none. ROUTES: none. DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                      # parse check. MUST be clean (no output).
shellcheck -s bash -S warning lib/pool.sh   # MUST report zero issues (project gate; ShellCheck 0.11.0).
bash -n test/validate.sh                 # parse check the test file after the fix + the new body.
shellcheck -s bash -S warning test/validate.sh   # MUST be clean.
# Expected: zero output from all four.
# NOTE: the project gate is `shellcheck -s bash -S warning` (confirmed in system_context.md +
#       TEST_RESULTS.md). Do NOT use a stricter -S info/style threshold — the existing codebase was
#       validated at -S warning and may have style-level annotations by design.
```

### Level 2: Unit / Component Tests (hermetic micro-checks + the suite)

```bash
# 2a. The identity gate in isolation — foreign Chrome on reconnect → NO rebind (THE FIX):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  pool_lease_write 1 "$1/active/1" 53420 abpool-1 1 pi 1000 "$1" 1 1 true
  pool_daemon_connected() { return 1; }   # daemon restarted
  curl()                  { return 0; }   # foreign Chrome answers
  pool_cdp_is_ours()      { return 1; }   # NOT ours
  pool_chrome_launch()    { _relaunch=1; return 0; }
  pool_wait_cdp()         { return 1; }
  _connect=0; _relaunch=0
  pool_daemon_connect()   { _connect=1; return 0; }
  ec=0; pool_ensure_connected 1 || ec=$?
  test "$_connect"   = "0" && echo "OK: foreign chrome NOT rebound"   || { echo "FAIL: rebound to foreign"; exit 1; }
  test "$_relaunch"  = "1" && echo "OK: fell through to relaunch"     || { echo "FAIL: did not fall through"; exit 1; }
  test "$ec"         != "0" && echo "OK: returned non-zero"           || { echo "FAIL: returned 0"; exit 1; }
' _ "$tmp"
# Expected: "OK: foreign chrome NOT rebound" + "OK: fell through to relaunch" + "OK: returned non-zero".
#           (BEFORE the fix: the reconnect branch calls pool_daemon_connect directly → _connect=1 → FAIL.)

# 2b. Backward-compat — chrome_pid=0 (provisional/stale lane) preserves legacy reconnect (NO gate):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  # chrome_pid=0 → the gate is SKIPPED. Even though pool_cdp_is_ours would say "not ours", legacy
  # reconnect must fire (connect to whatever answers). Use a lease with chrome_pid 0.
  pool_lease_write 1 "$1/active/1" 53420 abpool-1 1 pi 1000 "$1" 0 0 true
  pool_daemon_connected() { return 1; }
  curl()                  { return 0; }
  pool_cdp_is_ours()      { return 1; }   # "not ours" — but gate is SKIPPED for pid 0
  _connect=0
  pool_daemon_connect()   { _connect=1; return 0; }
  pool_ensure_connected 1 || true
  test "$_connect" = "1" && echo "OK: chrome_pid=0 → legacy reconnect (gate skipped)" || { echo "FAIL: gate fired on pid 0"; exit 1; }
' _ "$tmp"
# Expected: "OK: chrome_pid=0 → legacy reconnect (gate skipped)".
#           (Proves stale/provisional lanes with pid 0 are NOT broken by the gate.)

# 2c. The full self-test suite (now includes the fixed rebind test + the new regression test):
bash test/validate.sh
# Expected: prints "== selftest_ensure_connected_rebinds_when_disconnected / PASS",
#           "== selftest_ensure_connected_skips_rebind_when_connected / PASS", and
#           "== selftest_ensure_connected_rejects_foreign_chrome_on_reconnect / PASS",
#           and a final "N passed, 0 failed" line; exits 0.
# If ANY selftest fails, the suite exits non-zero — debug root cause, do not proceed.

# 2d. Regression — the happy path (connected=true + daemon knows session) early-exits UNCHANGED:
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  pool_lease_write 1 "$1/active/1" 53420 abpool-1 1 pi 1000 "$1" 1 1 true
  pool_daemon_connected() { return 0; }   # daemon KNOWS session → early-exit
  curl()                  { return 0; }
  pool_cdp_is_ours()      { return 1; }   # would be "foreign" — but early-exit means curl/gate never run
  _connect=0
  pool_daemon_connect()   { _connect=1; return 0; }
  pool_ensure_connected 1
  test "$_connect" = "0" && echo "OK: happy path early-exits (curl/gate not reached)" || { echo "FAIL"; exit 1; }
' _ "$tmp"
# Expected: "OK: happy path early-exits (curl/gate not reached)".
#           (Confirms the gate does not perturb the connected early-exit.)
```

### Level 3: Integration / Scope Verification

```bash
# 3a. Verify the diff is minimal + scoped to pool_ensure_connected (NOT the relaunch branch / docstrings):
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -vE '^[+-]{3}'
# Expected: ONLY hunks within pool_ensure_connected: the local decl (~2509), the jq comment/mapfile
#           (~2524-2538), and the reconnect comment/branch (~2559-2572). NO hunks in the relaunch
#           branch (~2574-2625), pool_wait_cdp (1687), pool_cdp_is_ours (1614), or any docstring.

# 3b. Verify the relaunch branch's pool_wait_cdp is STILL single-arg (S2's job — must be UNCHANGED):
grep -n 'pool_wait_cdp "\$port"' lib/pool.sh
# Expected: a line `if ! pool_wait_cdp "$port"; then` in the relaunch branch (~2597) — still 1 arg.
#           (S2 will change it to 3 args; S1 must NOT.)

# 3c. Verify the test diff is scoped (fix 1 body, add 1 body):
git diff -- test/validate.sh | grep -E '^[+-]' | grep -vE '^[+-]{3}'
# Expected: +1 stub line in selftest_ensure_connected_rebinds_when_disconnected + the new
#           selftest_ensure_connected_rejects_foreign_chrome_on_reconnect body (~35 lines).
#           NO changes to selftest_ensure_connected_skips_rebind_when_connected or any other test.

# 3d. Verify the jq extraction now reads 5 fields incl. chrome_pid:
grep -n ".session, .port, .ephemeral_dir, .connected, .chrome_pid'" lib/pool.sh
# Expected: one match at ~line 2532.

# 3e. Verify the gate exists in the reconnect branch:
grep -n 'pool_cdp_is_ours "\$port" "\$ephemeral_dir" "\$chrome_pid"' lib/pool.sh
# Expected: one match inside pool_ensure_connected's reconnect branch (S2 will add another inside
#           pool_wait_cdp's caller later — but for S1 there must be exactly ONE, in ensure_connected).

# 3f. Full repo smoke (no Chrome launched — pure sourcing + a stubbed ensure_connected):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; echo SOURCED_OK'
# Expected: SOURCED_OK
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The motivating scenario (Issue #3 from TEST_RESULTS.md): a foreign Chrome answering our port on
#     reconnect must NOT be rebound. Simulate via the stub set (hermetic — no real Chrome). Assert the
#     daemon is NOT bound (pool_daemon_connect NOT called) and the function relaunches.
#     (This is Level 2a restated as the "motivating scenario" check — same expected output.)

# 4b. Confirm the backward-compat guard is correct: a lane with a VALID pid whose Chrome IS ours
#     reconnects normally (the gate passes, no spurious relaunch):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  pool_lease_write 1 "$1/active/1" 53420 abpool-1 1 pi 1000 "$1" 1 1 true
  pool_daemon_connected() { return 1; }
  curl()                  { return 0; }
  pool_cdp_is_ours()      { return 0; }   # OURS → gate passes → reconnect (NOT relaunch)
  _connect=0
  pool_daemon_connect()   { _connect=1; return 0; }
  pool_ensure_connected 1
  test "$_connect" = "1" && echo "OK: ours → reconnect (gate passed)" || { echo "FAIL: did not reconnect"; exit 1; }
' _ "$tmp"
# Expected: "OK: ours → reconnect (gate passed)".
#           (Confirms the gate does not cause spurious relaunches for a genuine same-Chrome reconnect.)

# 4c. Confirm the previously-breaking test is fixed (it now stubs pool_cdp_is_ours→0):
grep -A1 'selftest_ensure_connected_rebinds_when_disconnected' test/validate.sh | head -1
grep -n 'pool_cdp_is_ours()      { return 0; }   # ours → identity gate' test/validate.sh
# Expected: the new stub line exists in the rebind test body.

# NOTE (AGENTS.md): all Level 2/4 checks are hermetic — they source lib/pool.sh and call
# pool_ensure_connected with STUBS (no real Chrome, no daemon, no network). They run in a subshell
# with an isolated temp tree under $(mktemp -d) and trap-cleanup. They never touch the operator's real
# state. No processes are spawned (pool_chrome_launch is stubbed). Zero orphans.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n lib/pool.sh` clean; `bash -n test/validate.sh` clean.
- [ ] `shellcheck -s bash -S warning lib/pool.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 (all selftests PASS, incl. the fixed rebind test + the new regression test).

### Feature Validation

- [ ] jq extraction reads 5 fields incl. `.chrome_pid` (Level 3d).
- [ ] Reconnect branch gates on `pool_cdp_is_ours` for `chrome_pid>0` (Level 3e).
- [ ] Foreign Chrome on reconnect → NO rebind + fall through to relaunch (Level 2a / 4a).
- [ ] `chrome_pid=0` lane → legacy reconnect preserved, gate skipped (Level 2b).
- [ ] Happy path early-exit UNCHANGED (Level 2d).
- [ ] Genuine same-Chrome reconnect → reconnect (gate passes, no spurious relaunch) (Level 4b).
- [ ] Previously-breaking rebind test is fixed (Level 4c) and PASSES.

### Scope Validation (CRITICAL — S1 must not bleed into S2)

- [ ] The relaunch branch (`pool_wait_cdp "$port"`) is byte-UNCHANGED — still 1 arg (Level 3b).
- [ ] `pool_wait_cdp` (1687) and `pool_cdp_is_ours` (1614) docstrings are byte-UNCHANGED (S2's scope).
- [ ] `git diff -- lib/pool.sh` touches ONLY pool_ensure_connected (Level 3a).
- [ ] `git diff -- test/validate.sh` fixes ONLY the rebind test + adds ONLY the new regression test (Level 3c).

### Code Quality Validation

- [ ] Follows existing patterns (pool_cdp_is_ours reuse, ONE jq fork, hermetic selftest shape).
- [ ] File placement matches (reconnect gate in pool_ensure_connected; new test grouped with ensure_connected tests).
- [ ] Anti-patterns avoided (no real Chrome in tests; no dead-code stubs; no `return` in the foreign fall-through branch).
- [ ] The backward-compat guard (`chrome_pid>0`) is present (no breakage of stale/provisional lanes).

### Documentation

- [ ] Inline comment above the reconnect branch documents the identity gate + the backward-compat guard (Mode A).
- [ ] No docstring changes here (S2 owns pool_wait_cdp/pool_cdp_is_ours docstrings) — verified by Level 3a.

---

## Anti-Patterns to Avoid

- ❌ Don't touch the relaunch branch or the pool_wait_cdp/pool_cdp_is_ours docstrings — those are S2.
- ❌ Don't omit the `chrome_pid>0` guard — without it, stale/provisional lanes (pid 0) always fail the gate and never reconnect.
- ❌ Don't add a `return` in the foreign fall-through branch — it MUST fall through to relaunch (a `return` would drop the lane with no Chrome).
- ❌ Don't write the regression test without stubbing `pool_chrome_launch` + `pool_wait_cdp` — real Chrome wedges the sandbox (AGENTS.md §1) and an unstubbed relaunch connect makes `_connect_called` unable to distinguish fixed vs buggy.
- ❌ Don't use `chrome_pid="${_f[4]:-0}"` alone (leaves jq's `null` literal) — use the explicit `[[ =~ ^[0-9]+$ ]] || chrome_pid=0` coalesce.
- ❌ Don't run the test suite or boot real Chrome during research/planning (AGENTS.md §1) — static checks + hermetic micro-checks only.
- ❌ Don't catch all exceptions / don't add `|| true` around `! pool_cdp_is_ours` — the `!` + `if` operand already neutralize set -e.
