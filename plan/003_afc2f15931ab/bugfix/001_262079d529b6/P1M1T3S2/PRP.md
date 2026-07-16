# PRP — P1.M1.T3.S2: Enable identity args in relaunch branch `pool_wait_cdp` + update `pool_wait_cdp`/`pool_cdp_is_ours` docstrings

> **Bugfix context**: This subtask closes the **relaunch-branch half** of **Issue #3 (Minor)**
> from the QA report (`plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md` and
> `architecture/recon_issue3_ensure_connected.md`). `pool_ensure_connected` (lib/pool.sh)
> runs on **every driving call** (the hot path). Its relaunch branch calls
> `pool_wait_cdp "$port"` with a **single argument**, so `check_identity=0` inside
> `pool_wait_cdp` — the BUG-1 identity check is **disabled**. A foreign Chrome that grabbed
> the port after our relaunched Chrome died on EADDRINUSE would be treated as a successful
> boot, a "1 agent = 1 browser" isolation break. The acquire path was already hardened
> against exactly this (`_pool_launch_and_verify` passes 3 args); this subtask makes the
> relaunch branch match it. It also updates two docstrings whose claim about "the
> ensure_connected relaunch path" becomes FALSE after this fix.
>
> **SCOPE BOUNDARY (CRITICAL):** This subtask (S2) touches **ONLY**:
> (1) the relaunch-branch `pool_wait_cdp` call — change its arity 1→3 (lib/pool.sh:~2618),
> (2) the `pool_wait_cdp` docstring (lib/pool.sh:1666-1669 — remove the now-false claim), and
> (3) the `pool_cdp_is_ours` docstring (lib/pool.sh:1613-1615 — same).
> Plus ONE test: ADD `selftest_ensure_connected_relaunch_passes_identity_args` to test/validate.sh.
>
> **OUT OF SCOPE (S1 owns these — already applied):** the jq extraction (`.chrome_pid` 5th
> field), the reconnect-branch identity gate, and S1's tests. S2 MUST NOT touch the reconnect
> branch, the jq extraction, the `local` decl, or S1's tests. S2 does NOT touch the
> `pool_wait_cdp`/`pool_cdp_is_ours` FUNCTION BODIES — only their DOCSTRINGS.
>
> **LINE-NUMBER NOTE (verified against CURRENT tree, S1 APPLIED):** S1 (reconnect) was being
> implemented IN PARALLEL and is **already applied** to the working tree (lib/pool.sh is now
> 4588 LOC; was 4577 pre-S1). S1's reconnect-branch restructure shifted the relaunch
> `pool_wait_cdp` call DOWN ~21 lines: it is now at **lib/pool.sh:2618** (was 2597 pre-S1).
> The two docstrings are at stable line numbers (no sibling subtask touches them:
> pool_cdp_is_ours docstring line 1615; pool_wait_cdp docstring lines 1668-1669). **Locate
> all edit sites by CONTENT grep in Task 0** — exact current line numbers are quoted below
> for orientation only and may drift if the tree changes further.

---

## Goal

**Feature Goal**: Enable the BUG-1 identity check inside `pool_wait_cdp` for the
`pool_ensure_connected` **relaunch branch** by passing all 3 args
(`$port`, `$ephemeral_dir`, `${POOL_CHROME_PID:-}`), mirroring the hardened acquire path
(`_pool_launch_and_verify`). After the relaunched Chrome's CDP probe succeeds,
`pool_cdp_is_ours` verifies the answerer is THIS lane's fresh Chrome
(DevToolsActivePort line1==port AND /proc/$POOL_CHROME_PID exists). A foreign Chrome on the
port (our relaunched Chrome died on EADDRINUSE) → keep polling → timeout → kill our pgroup →
`connected:false` (we do NOT bind to the foreign Chrome). The function's return contract
(0=connected, 1=not) is **unchanged**; the only behavioral change is: foreign Chrome on
relaunch → no silent bind. Also update the two docstrings that currently make a now-false
claim about the relaunch path, and add a focused regression test proving the arity change.

**Deliverable**:
1. **lib/pool.sh (relaunch branch, ~line 2618)** — change the arity of ONE line:
   `if ! pool_wait_cdp "$port"; then` → `if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then`.
2. **lib/pool.sh:1668-1669 (pool_wait_cdp docstring)** — remove the now-false "the
   ensure_connected relaunch path, which already knows its Chrome is bound" claim; state the
   relaunch path now passes identity args.
3. **lib/pool.sh:1615 (pool_cdp_is_ours docstring)** — remove the same claim; state the
   relaunch path was hardened in the Issue #3 fix.
4. **test/validate.sh (after S1's test at :628)** — ADD
   `selftest_ensure_connected_relaunch_passes_identity_args`: a hermetic, timeout-bounded
   subshell that stubs `pool_chrome_launch` (sets `POOL_CHROME_PID` via `declare -g`) +
   stubs `pool_wait_cdp` as an arg RECORDER, and asserts the relaunch branch passes 3 args
   ($2=ephemeral_dir, $3=POOL_CHROME_PID).
5. **No other files.** No reconnect-branch change (S1 owns it, applied). No jq extraction
   change (S1 owns it, applied). No function-body change to pool_wait_cdp/pool_cdp_is_ours
   (only their docstrings). No consumer change (the return contract is unchanged).

**Success Definition**:
- `grep -n 'if ! pool_wait_cdp "\$port" "\$ephemeral_dir" "\${POOL_CHROME_PID:-}"; then' lib/pool.sh`
  matches the relaunch branch (and there is NO remaining 1-arg `pool_wait_cdp "$port"` call
  inside `pool_ensure_connected`).
- `grep -n 'ensure_connected relaunch path, which already knows its Chrome is bound' lib/pool.sh`
  returns NOTHING (the pool_wait_cdp docstring claim is gone).
- `grep -n 'back-compat for standalone tests / the ensure_connected relaunch path' lib/pool.sh`
  returns NOTHING (the pool_cdp_is_ours docstring claim is gone).
- `selftest_ensure_connected_relaunch_passes_identity_args` exists and PASSES (asserts
  pool_wait_cdp received 3 args incl. the lane's ephemeral_dir and the POOL_CHROME_PID set
  by pool_chrome_launch).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean (project gate).
- `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- `bash test/validate.sh` exits 0 (all selftests PASS, incl. S1's tests + S2's new test).

## User Persona

**Target User**: Any AI agent driving a browser lane through `agent-browser-pool` (the
per-call hot path `pool_ensure_connected` runs on every driving command after a Chrome crash
mid-task → relaunch). Secondary: operators/maintainers auditing the pool's isolation
guarantees and reading the docstrings.

**Use Case**: The narrow-but-real isolation race (PRD Issue #3, relaunch variant): (1) lane
N's Chrome dies mid-task; (2) `pool_ensure_connected` reaches the relaunch branch and
launches a fresh Chrome on the same port+dir via `pool_chrome_launch`; (3) the fresh Chrome
**dies on EADDRINUSE** (e.g. a transient bind collision) before writing
`DevToolsActivePort`; (4) a **foreign** Chrome binds that port; (5) **before this fix**:
`pool_wait_cdp "$port"` (1 arg → identity OFF) sees curl succeed (foreign Chrome answers) →
returns 0 → `pool_daemon_connect` binds our daemon to the foreign Chrome → `exec agent-browser`
drives the WRONG browser, silently. **After this fix**: the 3-arg call enables
`check_identity=1` → `pool_cdp_is_ours` sees the DevToolsActivePort mismatch (foreign dir has
no such file / wrong port) → keeps polling → times out → kills our (dead) pgroup → returns 1
→ `connected:false` → no isolation break.

**User Journey**: Agent's driving call → `pool_ensure_connected $LANE` → (Chrome dead) →
relaunch branch → `pool_chrome_launch` (sets POOL_CHROME_PID) → NEW 3-arg
`pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"` → identity verified →
`pool_daemon_connect` → `connected:true`. On a foreign-Chrome collision, the same call times
out and returns 1 (no bind).

**Pain Points Addressed**:
- **Silent isolation break on relaunch**: a foreign Chrome answering our port after a
  failed relaunch could be silently driven. The 3-arg call makes it impossible.
- **Defense-in-depth inconsistency**: the acquire path was hardened (BUG-1 / 3-arg
  `pool_wait_cdp`) but the relaunch path was not. This subtask makes the relaunch path match.
- **Stale docstrings**: two docstrings claim the relaunch path uses legacy probe-only
  behavior "which already knows its Chrome is bound" — after S1+S2 this is FALSE. Updated to
  avoid misleading future maintainers.

## Why

- **Issue #3 (Minor)** from the QA report — the relaunch-branch half. The trigger is a
  narrow conjunction (Chrome dies mid-task + fresh relaunch dies on EADDRINUSE + foreign
  Chrome grabs the port), so severity is Minor — but it is a real inconsistency with the
  acquire path and contradicts PRD §1.3 "1 agent = 1 browser" / §2.13 "isolation by
  construction." Closing it is a **one-line arity change** reusing an existing primitive.
- **The fix is trivially scoped and safe.** `$ephemeral_dir` is already extracted at the top
  of the function (jq `_f[2]`); `${POOL_CHROME_PID:-}` is set by `pool_chrome_launch` which
  runs a few lines above the `pool_wait_cdp` call. `${:-}` keeps it `set -u` safe. This is
  EXACTLY the pattern `_pool_launch_and_verify` already uses at lib/pool.sh:2302/2321.
- **The identity primitive is already correct and tested.** `pool_wait_cdp`'s
  `check_identity` logic + `pool_cdp_is_ours` are unchanged — S2 merely routes the relaunch
  branch INTO the existing identity-enabled code path instead of the legacy probe-only one.
  No new logic; no new failure modes.
- **The docstrings are a [Mode A] doc fix that rides with the code.** Both currently claim
  the relaunch path uses legacy probe-only behavior. After S1 (reconnect) + S2 (relaunch),
  no in-tree caller omits the identity args, so the legacy path is "standalone tests only."
  Leaving the stale claim would mislead future maintainers into thinking the relaunch path
  is intentionally un-hardened.
- **Closes a test blind spot.** S1's `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect`
  stubs `pool_wait_cdp` entirely (`return 1`) and proves the foreign-Chrome fall-through —
  but it does NOT verify the relaunch branch passes identity ARGS. S2 adds exactly that
  recorder-based test.

## What

User-visible behavior: **none in the common case** (our relaunched Chrome binds the port
correctly → identity passes → connect succeeds → identical to before). The only observable
change is in the narrow foreign-Chrome-after-relaunch race: instead of binding the daemon to
the foreign Chrome and returning `connected:true`, `pool_wait_cdp` times out (30s), kills our
pgroup, and returns 1 → `connected:false` (correct). The function's return contract
(0=connected, 1=not) is unchanged.

### Behavior change (relaunch branch)

The relaunch branch currently (lib/pool.sh:~2618):
```bash
    if ! pool_wait_cdp "$port"; then
        _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi
```
becomes:
```bash
    if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then
        _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi
```

### Success Criteria

- [ ] The relaunch branch's `pool_wait_cdp` call passes 3 args (`$port`, `$ephemeral_dir`,
      `${POOL_CHROME_PID:-}`); no 1-arg `pool_wait_cdp "$port"` call remains in
      `pool_ensure_connected`.
- [ ] The `pool_wait_cdp` docstring no longer claims "the ensure_connected relaunch path
      … already knows its Chrome is bound"; it states the relaunch path now passes identity args.
- [ ] The `pool_cdp_is_ours` docstring no longer lists "the ensure_connected relaunch path"
      as a legacy-behavior consumer; it states the relaunch path was hardened in the Issue #3 fix.
- [ ] NEW `selftest_ensure_connected_relaunch_passes_identity_args` exists and asserts
      pool_wait_cdp received 3 args ($2=ephemeral_dir, $3=POOL_CHROME_PID set by
      pool_chrome_launch) AND the relaunch succeeded (`ec==0`).
- [ ] S1's tests (`selftest_ensure_connected_rebinds_when_disconnected`,
      `selftest_ensure_connected_skips_rebind_when_connected`,
      `selftest_ensure_connected_rejects_foreign_chrome_on_reconnect`) still PASS — S2 does
      NOT touch the reconnect branch or S1's tests.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean.
- [ ] `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 (all selftests PASS).
- [ ] The reconnect branch (S1's 3-way if/elif/else), the jq extraction (5 fields), and the
      `pool_wait_cdp`/`pool_cdp_is_ours` FUNCTION BODIES are **byte-unchanged** (S1 owns the
      first two; S2 only edits the two DOCSTRINGS, not the bodies).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?"** → Yes. This PRP pins the edit sites by content grep (robust to line drift),
quotes the current code/docstrings verbatim at every site, gives the exact one-line replacement
for the code and the exact old→new text for both docstrings, explains WHY each change is correct
(which vars are in scope, how the identity guard works, why `${:-}` is needed for set -u), and
specifies the regression test's stubs + assertions (including the non-obvious requirement that
the `pool_chrome_launch` stub must use `declare -g` so POOL_CHROME_PID is visible to pool_wait_cdp).
The implementer needs no prior exposure beyond the quoted snippets.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/recon_issue3_ensure_connected.md
  why: THE recon doc for this exact bug. Verbatim line numbers, the exact current relaunch-branch
        code, pool_wait_cdp's check_identity guard logic, the data-flow diagram, and a "Start here"
        hit-list. §3 (pool_wait_cdp) documents the arity-driven check_identity logic S2 relies on.
  pattern: '§1 pool_ensure_connected RELAUNCH branch, §3 pool_wait_cdp check_identity, §4
            _pool_launch_and_verify (the 3-arg REFERENCE), "Architecture / data flow" diagram.'
  gotcha: 'the recon quotes the relaunch pool_wait_cdp call at line 2597 (pre-S1). After S1 was
            applied, it shifted to ~2618. LOCATE BY CONTENT GREP (Task 0), not by line number.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/system_context.md
  why: 'Confirms Issue 3 root cause + fix surface. "Fix surface (relaunch): change
        pool_wait_cdp "$port" → pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}""
        is EXACTLY this PRP. "Docstring impact" lists pool_wait_cdp (lib/pool.sh:1689 — now
        1668-1669 after S1) + pool_cdp_is_ours (lib/pool.sh:1622 — now 1615) — EXACTLY S2.'
  pattern: '"Fix surface (relaunch)" + "Docstring impact" = this PRP. "Fix surface (reconnect)" is
            S1 (already applied).'
  gotcha: 'system_context line numbers predate S1; the docstring claims are still at the same
            RELATIVE positions but shifted slightly. Locate by content grep.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T3S1/PRP.md
  why: 'S1 (the DEPENDENCY — reconnect branch + jq extraction + tests) is the contract S2 builds
        on. S1 already applied its reconnect identity gate, the 5-field jq extraction, the chrome_pid
        coalesce, and 3 tests. S2 MUST coexist with all of that. S1 OUT-OF-SCOPE explicitly defers
        the relaunch pool_wait_cdp arity change + both docstrings to S2.'
  pattern: 'S1 Task 1 (jq 5-field extraction + local decl + coalesce) is applied → $ephemeral_dir
            is in scope for S2. S1 Task 2 (reconnect 3-way gate) is applied → control can now reach
            the relaunch branch via the foreign-Chrome fall-through as well as via a dead Chrome.
            S2 works regardless of HOW the relaunch branch is reached (it just launched a fresh
            Chrome and verifies it).'
  gotcha: 'S1 added selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (test/validate.sh:628)
            which stubs pool_wait_cdp()→1. S2 ADDS a NEW test after it (do NOT modify S1 test). The two
            tests are complementary: S1 proves fall-through; S2 proves the arity change.'

- file: lib/pool.sh
  why: 'THE file being edited (3 sites: relaunch call + 2 docstrings). Read pool_ensure_connected
        (2508-2630), pool_wait_cdp (1697-1741 — docstring 1660-1695 + body, S2 edits ONLY the
        docstring), pool_cdp_is_ours (1629-1652 — docstring 1601-1628, S2 edits ONLY the docstring),
        and _pool_launch_and_verify (2282-2351 — the hardened 3-arg REFERENCE S2 mirrors).'
  pattern: 'the 3-arg form `pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"` appears
            verbatim at lib/pool.sh:2302 and 2321 (acquire path) — S2 copies it exactly.'
  gotcha: 'pool_wait_cdp's check_identity guard (lib/pool.sh:1707-1712) requires user_data_dir to be
            an ABSOLUTE path AND expected_pid to match ^[0-9]+$. $ephemeral_dir (from lease) is always
            absolute (reconstructed at lib/pool.sh:2543 if empty); POOL_CHROME_PID (from
            pool_chrome_launch) is always numeric. So identity WILL be enabled. If POOL_CHROME_PID
            were ever empty (defensive), the guard rejects it → identity disabled → legacy behavior
            (a safe no-op regression, not a crash).'

- file: test/validate.sh
  why: 'The test framework. ADD selftest_ensure_connected_relaunch_passes_identity_args AFTER S1 test
        selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (:628-664), BEFORE the
        `# --- pool_chrome_launch EADDRINUSE detection` comment. The single-setup _run_selftest_suite
        auto-discovers any selftest_* function via `compgen -A function | grep "^selftest_" | sort`.'
  pattern: 'S1 selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (:628) is the EXACT
        template: outdir under $ABPOOL_TEST_ROOT, body.sh heredoc (<<'"'"'EOF'"'"'), source the lib,
        pool_config_init + pool_state_init, write a lease via pool_lease_write, STUB relevant functions,
        run pool_ensure_connected, assert via `test`, run body.sh via `timeout 15 bash "$script"
        "$ABPOOL_REPO" "$outdir"`, assert_eq "0" "$rc".'
  gotcha: 'Do NOT use run_test/abpool_run_suite (spawns a sim-owner per test → AGENTS.md §4 hang risk).
            The selftest_* prefix is auto-picked by the SINGLE-SETUP runner. The body runs in its own
            `bash "$script"` subshell → stubs are naturally scoped (do NOT leak).'

- file: PRD.md
  why: '§1.3 goal #2 ("1 agent = 1 browser"), §2.4 step 4 (ENSURE CONNECTED), §2.13 ("isolation by
        construction"), §2.14 ("Chrome crash mid-task → relaunch"). The 3-arg relaunch call enforces
        §1.3/§2.13 on the hot path; the relaunch itself is §2.14.'
  pattern: '§2.4 step 4 return contract (0=connected, 1=not) is UNCHANGED by this PRP.'

# External authoritative docs (minimal — one-line arity change reusing an existing primitive)
- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: '"Declare and assign separately." The code change does NOT introduce any `local x=$(…)`; it
        only adds two args to an existing call. The docstring edits are comment-only. SC-clean.'
  critical: 'no new shellcheck considerations. The 3-arg form already exists at lib/pool.sh:2302/2321
            and passes shellcheck -S warning.'

- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameters.html
  why: '`${POOL_CHROME_PID:-}` (the :- default-empty expansion) keeps the call set -u safe when
        POOL_CHROME_PID is unset — identical to the acquire-path usage. No further reading needed.'
  section: 'search for "${parameter:-word}" — the "use default value" expansion.'

# Prior/parallel-subtask contracts (treated as already-implemented truth)
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T3S1/PRP.md
  why: 'see above (DEPENDENCY). S1 is applied. S2 builds on its reconnect gate + jq extraction.'
  gotcha: 'S1 explicitly reserved the relaunch arity change + both docstrings for S2. Do not
            re-implement S1; do not touch S1 tests.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                     # 4588 LOC (post-S1; was 4577)
│                                   # pool_ensure_connected at 2508-2630
│                                   #   jq extraction 5 fields (.chrome_pid added by S1) at ~2532  [S1 — DO NOT TOUCH]
│                                   #   reconnect branch 3-way identity gate at ~2569-2590         [S1 — DO NOT TOUCH]
│                                   #   RELAUNCH branch at ~2591-2630
│                                   #     pool_chrome_launch at ~2584 (sets POOL_CHROME_PID)
│                                   #     pool_wait_cdp "$port" 1-arg call at ~2618  ← S2 CODE EDIT
│                                   # pool_cdp_is_ours at 1629-1652 (body) + docstring 1601-1628
│                                   #   docstring line 1615 ← S2 DOCSTRING EDIT
│                                   # pool_wait_cdp at 1697-1741 (body) + docstring 1660-1695
│                                   #   docstring lines 1668-1669 ← S2 DOCSTRING EDIT
│                                   # _pool_launch_and_verify at 2282-2351 (3-arg REFERENCE at 2302/2321)
├── test/
│   └── validate.sh                 # ~1000+ LOC (post-S1)
│                                   # selftest_ensure_connected_rebinds_when_disconnected at 560  [S1 fixed — DO NOT TOUCH]
│                                   # selftest_ensure_connected_skips_rebind_when_connected at 594 [DO NOT TOUCH]
│                                   # selftest_ensure_connected_rejects_foreign_chrome_on_reconnect at 628 [S1 — DO NOT TOUCH]
│                                   # ADD selftest_ensure_connected_relaunch_passes_identity_args AFTER S1 test (~664)
│                                   # _run_selftest_suite at ~890 (auto-discovers selftest_*)
│                                   # assert_eq at 57
└── plan/003_afc2f15931ab/bugfix/001_262079d529b6/
    ├── architecture/recon_issue3_ensure_connected.md   # THE recon doc (exact code + line numbers)
    ├── architecture/system_context.md                   # scope split (S1 reconnect vs S2 relaunch)
    ├── TEST_RESULTS.md                                 # QA report (Issue 3 confirmed)
    ├── P1M1T3S1/PRP.md                                 # S1 (DEPENDENCY — applied)
    └── P1M1T3S2/
        ├── PRP.md                                      # THIS FILE
        └── research/notes.md                           # verified line numbers + test-design rationale
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh       — relaunch-branch pool_wait_cdp arity 1→3 (1 line) + 2 docstring edits (~3 comment lines each)
#   test/validate.sh  — ADD selftest_ensure_connected_relaunch_passes_identity_args (~30-line function)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (locate edit sites by CONTENT GREP, not line number): the relaunch pool_wait_cdp call
# SHIFTED ~21 lines when S1 (reconnect restructure) was applied (2597 → 2618). The two docstrings
# are at stable lines (no sibling touches them) but ALWAYS verify with grep before editing. The
# UNIQUE content anchors are:
#   CODE:   'if ! pool_wait_cdp "$port"; then'   (only ONE such line in pool_ensure_connected)
#   DOC1:   'the ensure_connected relaunch path, which already knows its Chrome is bound).'
#   DOC2:   '(back-compat for standalone tests / the ensure_connected relaunch path).'

# CRITICAL (the fix is arity-ONLY — do NOT change anything else on that line or in the branch):
#   FROM:  if ! pool_wait_cdp "$port"; then
#   TO:    if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then
# The log string, the connected:false update, and the return 1 are UNCHANGED. ${:-} is REQUIRED
# for set -u safety (identical to the acquire-path usage at lib/pool.sh:2302/2321).

# CRITICAL (POOL_CHROME_PID is a GLOBAL set by pool_chrome_launch, NOT the lease chrome_pid):
# the relaunch branch's pool_wait_cdp 3rd arg is "${POOL_CHROME_PID:-}" — the GLOBAL just set by
# pool_chrome_launch a few lines above (the FRESHLY relaunched Chrome's pid). It is NOT the lease's
# chrome_pid field (that one is for the RECONNECT branch's gate, owned by S1). This mirrors
# _pool_launch_and_verify exactly. pool_chrome_launch sets it via `declare -g`.

# CRITICAL (identity WILL be enabled after the fix — that is the point): pool_wait_cdp's
# check_identity guard (lib/pool.sh:1707-1712) enables identity when user_data_dir is a non-empty
# ABSOLUTE path AND expected_pid matches ^[0-9]+$. $ephemeral_dir is always absolute (lease value,
# reconstructed at lib/pool.sh:2543 if empty); POOL_CHROME_PID is always numeric post-launch. So
# check_identity becomes 1 → pool_cdp_is_ours runs after curl succeeds. This is the BUG-1 hardening.

# GOTCHA (defensive empty POOL_CHROME_PID): if pool_chrome_launch somehow did NOT set
# POOL_CHROME_PID (should never happen — it always sets it or pool_die's), the :-  gives empty →
# the ^[0-9]+$ guard rejects it → check_identity stays 0 → legacy probe-only behavior. So a
# missing pid is a SAFE no-op (no crash, no silent break), not a failure. This is documented in
# pool_wait_cdp's NON-FATAL contract.

# GOTCHA (the test's pool_chrome_launch stub MUST use declare -g): the relaunch branch reads
# ${POOL_CHROME_PID:-} as a GLOBAL. If the stub sets it with `local` or `POOL_CHROME_PID=4242`
# WITHOUT declare -g, it would be FUNCTION-LOCAL and invisible to pool_wait_cdp's recorder (the
# 3rd arg would be empty → the arity assertion _wcdp_arg3==4242 would FAIL). Use:
#   pool_chrome_launch() { declare -g POOL_CHROME_PID=4242; declare -g POOL_CHROME_PGID=4242; return 0; }
# This mirrors the REAL pool_chrome_launch (which uses declare -g per lib/pool.sh docstring).

# GOTCHA (the test's pool_chrome_launch stub MUST return 0): it is called BARE in the relaunch
# branch (`pool_chrome_launch "$port" "$ephemeral_dir" "$lane"` — not under `if`). Under set -e,
# a stub returning non-zero would ABORT the body before reaching pool_wait_cdp. (pool_wait_cdp and
# pool_daemon_connect are called under `if !` so their stubs may return non-zero safely, but S2's
# test returns 0 from both so the relaunch SUCCEEDS and we can assert ec==0.)

# GOTCHA (the test reaches the relaunch branch via curl→1, NOT via the S1 foreign-Chrome fall-
# through): the cleanest way to exercise the relaunch branch in isolation is to stub curl to FAIL
# (Chrome dead) → skip the reconnect branch entirely → relaunch. This keeps the test focused on the
# arity change and independent of S1's reconnect logic. (S1's own test already covers the
# fall-through-to-relaunch path; S2 does not duplicate it.)

# GOTCHA (set -e + pool_ensure_connected returning 0): in S2's test the relaunch SUCCEEDS
# (pool_wait_cdp→0, pool_daemon_connect→0) so pool_ensure_connected returns 0. Capture with
# `ec=0; pool_ensure_connected 1 || ec=$?` anyway (defensive; mirrors the existing test idiom) and
# assert ec==0. The `|| ec=$?` is errexit-exempt and harmless when rc is 0.

# GOTCHA (scope): this fix is ISSUE 3 RELAUNCH BRANCH + 2 DOCSTRINGS + 1 TEST ONLY. Do NOT touch:
# the reconnect branch (S1, applied), the jq extraction (S1, applied), the pool_wait_cdp BODY
# (only its docstring), the pool_cdp_is_ours BODY (only its docstring), or S1's tests. Do NOT fix
# Issue 1 (done) or Issue 2 (done). One arity change + two docstring edits + one test.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. `POOL_CHROME_PID` is an existing global (set by
`pool_chrome_launch`); `$ephemeral_dir` is an existing local (extracted by S1's jq at the top
of the function). S2 only passes them as args to `pool_wait_cdp`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current function and CONFIRM edit sites BEFORE touching anything
  - RUN (locate by CONTENT — robust to S1's line shift):
        grep -n 'if ! pool_wait_cdp "\$port"; then' lib/pool.sh
        # → expect ONE match inside pool_ensure_connected (~line 2618 post-S1)
        grep -n 'ensure_connected relaunch path, which already knows its Chrome is bound' lib/pool.sh
        # → expect ONE match in pool_wait_cdp docstring (~line 1669)
        grep -n 'back-compat for standalone tests / the ensure_connected relaunch path' lib/pool.sh
        # → expect ONE match in pool_cdp_is_ours docstring (~line 1615)
        grep -n 'pool_wait_cdp "\$port" "\$ephemeral_dir" "\${POOL_CHROME_PID:-}"' lib/pool.sh
        # → expect TWO matches in _pool_launch_and_verify (acquire path, 2302/2321) — the REFERENCE form
  - READ lib/pool.sh around the relaunch branch (sed -n '2591,2625p' or equivalent) to confirm the
        exact current text of the `if ! pool_wait_cdp "$port"; then` block matches Task 1's FIND.
  - READ lib/pool.sh:1660-1675 (pool_wait_cdp docstring IDENTITY VERIFICATION block) to confirm the
        exact text of the claim to edit (Task 2's FIND).
  - READ lib/pool.sh:1601-1628 (pool_cdp_is_ours docstring CONSUMER block) to confirm the exact text
        of the claim to edit (Task 3's FIND).
  - READ lib/pool.sh:1700-1741 (pool_wait_cdp body, check_identity + probe loop) to confirm identity
        is enabled when 3 well-formed args are passed — i.e. the arity change has the intended effect.
  - CONFIRM: there is exactly ONE 1-arg `pool_wait_cdp "$port"` call in pool_ensure_connected and
        TWO 3-arg `pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"` calls in
        _pool_launch_and_verify (the form S2 copies).

Task 1: EDIT lib/pool.sh — relaunch-branch pool_wait_cdp arity 1→3 (THE CODE FIX)
  - LOCATE by content: grep -n 'if ! pool_wait_cdp "\$port"; then' lib/pool.sh  (→ ~2618)
  - FIND (the exact current line — it is the ONLY 1-arg pool_wait_cdp call in pool_ensure_connected):
        if ! pool_wait_cdp "$port"; then
    REPLACE WITH:
        if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then
  - WHY: enabling the 3 args turns on pool_wait_cdp's check_identity guard (user_data_dir absolute
        AND expected_pid numeric → check_identity=1) → after the relaunched Chrome's curl succeeds,
        pool_cdp_is_ours verifies the answerer is THIS lane's fresh Chrome. A foreign Chrome on the
        port (our relaunched Chrome died on EADDRINUSE) → DevToolsActivePort mismatch → keep polling
        → timeout → kill our pgroup → return 1 → connected:false. Mirrors _pool_launch_and_verify
        (lib/pool.sh:2302/2321). ${:-} keeps it set -u safe (identical to acquire path).
  - GOTCHA: change ONLY the argument list of this ONE line. Do NOT touch the log string, the
        connected:false update, the return 1, the surrounding comment, or any other line. Do NOT
        touch the reconnect branch (S1 owns it).
  - GOTCHA: after this edit, `grep -n 'if ! pool_wait_cdp "\$port"; then' lib/pool.sh` should return
        NOTHING (no 1-arg call left in pool_ensure_connected).

Task 2: EDIT lib/pool.sh — pool_wait_cdp docstring (remove the now-false relaunch-path claim)
  - LOCATE by content: grep -n 'ensure_connected relaunch path, which already knows its Chrome is bound' lib/pool.sh
        (→ ~1669, inside pool_wait_cdp's IDENTITY VERIFICATION docstring block)
  - FIND (the exact current two comment lines, lib/pool.sh:1668-1669):
        # args are OMITTED, the legacy probe-only behavior is preserved (standalone tests + the
        # ensure_connected relaunch path, which already knows its Chrome is bound).
    REPLACE WITH:
        # args are OMITTED, the legacy probe-only behavior is preserved ONLY for standalone tests
        # (the ensure_connected relaunch path now also passes identity args — Issue #3 fix — so all
        # pool_wait_cdp call sites enforce identity when a pid is available).
  - WHY: after S1 (reconnect gate) + S2 (relaunch 3-arg), NO in-tree pool_wait_cdp call omits the
        identity args. The old claim ("the relaunch path already knows its Chrome is bound") is now
        FALSE and would mislead maintainers. The new text states the relaunch path was hardened and
        legacy behavior is standalone-tests-only.
  - GOTCHA: this is a DOCSTRING (comment) edit — do NOT touch the pool_wait_cdp FUNCTION BODY. The
        check_identity logic (lib/pool.sh:1707-1731) is UNCHANGED. Only the prose describing WHEN it
        fires is updated.

Task 3: EDIT lib/pool.sh — pool_cdp_is_ours docstring (remove the same claim)
  - LOCATE by content: grep -n 'back-compat for standalone tests / the ensure_connected relaunch path' lib/pool.sh
        (→ ~1615, inside pool_cdp_is_ours's CONSUMER docstring block)
  - FIND (the exact current three comment lines, lib/pool.sh:1613-1615):
        #   Called ONLY when an identity check is requested (USER_DATA_DIR + EXPECTED_PID both
        #   supplied and non-empty); otherwise pool_wait_cdp keeps the legacy probe-only behavior
        #   (back-compat for standalone tests / the ensure_connected relaunch path).
    REPLACE WITH:
        #   Called ONLY when an identity check is requested (USER_DATA_DIR + EXPECTED_PID both
        #   supplied and non-empty); otherwise pool_wait_cdp keeps the legacy probe-only behavior
        #   (back-compat for standalone tests — the ensure_connected relaunch path was hardened in
        #   the Issue #3 fix and now passes identity args).
  - WHY: the 3rd line listed "the ensure_connected relaunch path" as a consumer of the legacy
        (no-identity) behavior. After S2 that is FALSE. The new text states the relaunch path was
        hardened, leaving standalone tests as the ONLY legacy consumer.
  - GOTCHA: comment-only edit — do NOT touch the pool_cdp_is_ours FUNCTION BODY (lib/pool.sh:1629-1652).

Task 4: ADD test/validate.sh — selftest_ensure_connected_relaunch_passes_identity_args
  - ADD a new function named `selftest_ensure_connected_relaunch_passes_identity_args` (the
        _run_selftest_suite auto-discovers any selftest_* function — NO registration needed).
  - PLACE: IMMEDIATELY AFTER S1's selftest_ensure_connected_rejects_foreign_chrome_on_reconnect
        (test/validate.sh:628-664), BEFORE the `# --- pool_chrome_launch EADDRINUSE detection`
        comment. This groups the 4 ensure_connected tests together and avoids merge conflicts.
  - FOLLOW pattern: selftest_ensure_connected_rejects_foreign_chrome_on_reconnect (test/validate.sh:628)
        — the EXACT template (outdir, quoted heredoc, source lib, config/state init, lease write,
        stubs, run pool_ensure_connected, assert, timeout 15 bash "$script", assert_eq "0" "$rc").
  - REFERENCE IMPLEMENTATION (the pool_chrome_launch stub's `declare -g` + the pool_wait_cdp recorder
        are the load-bearing parts — see "Known Gotchas" for WHY):
      ----------------------------------------------------------------
      # --- pool_ensure_connected relaunch passes identity args to pool_wait_cdp (Issue #3 / S2) ---
      # Regression for the relaunch-branch arity fix. Models Chrome DEAD (curl fails → skip reconnect
      # → RELAUNCH branch), then asserts pool_wait_cdp receives 3 args ($2=ephemeral_dir,
      # $3=POOL_CHROME_PID). Hermetic (NO real Chrome): pool_chrome_launch is stubbed to set the
      # globals via declare -g (mirrors real) + return 0; pool_wait_cdp is stubbed as an arg RECORDER
      # (records argc/$2/$3, returns 0 so the relaunch succeeds). This proves the arity change — the
      # load-bearing invariant — without exercising pool_cdp_is_ours's /proc + DevToolsActivePort
      # signals (those are covered by the existing pool_wait_cdp identity selftests).
      selftest_ensure_connected_relaunch_passes_identity_args() {
          local outdir script rc out
          outdir="$ABPOOL_TEST_ROOT/ensure-relaunch-identity"
          mkdir -p -- "$outdir"
          script="$outdir/body.sh"
          cat >"$script" <<'EOF'
      set -euo pipefail
      source "$1/lib/pool.sh"
      pool_config_init
      pool_state_init
      # Lease: connected=false, port 53420, ephemeral_dir $2/active/1. Model Chrome DEAD so the
      # reconnect branch is skipped and the RELAUNCH branch fires (curl→1).
      #   args: LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME CWD CHROME_PID CHROME_PGID CONNECTED
      pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 1000 "$2" 200 201 false
      # Stubs:
      curl()                { return 1; }   # Chrome DEAD → skip reconnect → RELAUNCH branch
      pool_daemon_connect() { return 0; }   # relaunch rebind succeeds → connected=true, return 0
      # pool_chrome_launch: set the globals via declare -g (mirrors real pool_chrome_launch) + return 0.
      # MUST return 0 (bare call under set -e); MUST declare -g so POOL_CHROME_PID is visible to
      # pool_wait_cdp's recorder. No REAL Chrome (AGENTS.md §1).
      pool_chrome_launch()  { declare -g POOL_CHROME_PID=4242; declare -g POOL_CHROME_PGID=4242; return 0; }
      # pool_wait_cdp RECORDER: capture argc + $2/$3, return 0 so the relaunch succeeds (connect fires).
      _wcdp_argc=0; _wcdp_arg2=""; _wcdp_arg3=""
      pool_wait_cdp()       { _wcdp_argc=$#; _wcdp_arg2="${2:-}"; _wcdp_arg3="${3:-}"; return 0; }
      ec=0
      pool_ensure_connected 1 || ec=$?   # capture rc (relaunch succeeds → 0); `|| ec=$?` is errexit-exempt
      # THE INVARIANT (Issue #3 / S2): relaunch passes 3 args to pool_wait_cdp — the ephemeral_dir
      # ($2) and POOL_CHROME_PID ($3) → identity check ENABLED (BUG-1 hardening).
      test "$_wcdp_argc" = "3"
      test "$_wcdp_arg2" = "$2/active/1"   # ephemeral_dir from the lease
      test "$_wcdp_arg3" = "4242"          # POOL_CHROME_PID set by pool_chrome_launch
      test "$ec"        = "0"              # relaunch succeeded (connected=true)
      EOF
          rc=0
          out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
          assert_eq "0" "$rc" "ensure_connected relaunch passes identity args to pool_wait_cdp (3 args) (out: $out)" || return 1
      }
      ----------------------------------------------------------------
  - WHY pool_chrome_launch uses declare -g (return 0): see Known Gotchas. The globals MUST be visible
        to pool_wait_cdp (which reads ${POOL_CHROME_PID:-} as the 3rd arg); return 0 because the call
        is BARE under set -e.
  - WHY pool_wait_cdp returns 0 (recorder): so the relaunch's `if ! pool_wait_cdp …` is satisfied →
        pool_daemon_connect fires → connected=true → pool_ensure_connected returns 0 → assert ec==0.
        This proves the arity change end-to-end (the relaunch path with identity args reaches a
        successful connect). pool_wait_cdp is under `if !` so any return is set -e safe.
  - WHY curl→1 (not omitted): the cleanest way to reach the relaunch branch in isolation is to model
        Chrome DEAD. This keeps the test focused on the arity change and independent of S1's reconnect
        logic (S1's own test covers the foreign-Chrome fall-through-to-relaunch path).
  - WHY the lease has connected=false: step b is `[[ "$connected" == "true" ]] && pool_daemon_connected`
        — with connected=false it short-circuits (skipped), so control reaches step c (curl→1 → relaunch).
        (A connected=true + pool_daemon_connected→1 stub would also work; connected=false is simpler.)
  - GOTCHA: the heredoc uses `<<'EOF'` (quoted) so $1/$2/$(…) are NOT expanded by the outer shell —
        they expand when body.sh runs (matches S1's test exactly). The `|| return 1` after assert_eq
        makes fail-fast explicit.
  - GOTCHA: do NOT spawn Chrome or a sim-owner — pure-function + hermetic-subshell test. The body
        runs in its own `bash "$script"` subshell with scoped stubs. No processes to reap.

Task 5: VERIFY (the Validation Loop below) — run BEFORE claiming done.
  - Run Level 1 (syntax/lint) + Level 2 (grep invariants + full suite) + Level 3 (diff scope) in order.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — the 3-arg pool_wait_cdp form (copied verbatim from _pool_launch_and_verify):
#     if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then
#         … connected:false, return 1 …
#     fi
# WHY: identical to lib/pool.sh:2302/2321. ${:-} is set -u safe; $ephemeral_dir is the lease value
# (absolute); POOL_CHROME_PID is the global just set by pool_chrome_launch.

# Pattern B — the test's pool_chrome_launch stub (declare -g + return 0):
#     pool_chrome_launch()  { declare -g POOL_CHROME_PID=4242; declare -g POOL_CHROME_PGID=4242; return 0; }
# WHY: pool_wait_cdp's 3rd arg reads ${POOL_CHROME_PID:-} as a GLOBAL. declare -g makes the stub-set
# value visible across functions in the body.sh subshell. return 0 because the real call is BARE
# (set -e would abort on non-zero).

# Pattern C — the test's pool_wait_cdp recorder:
#     pool_wait_cdp() { _wcdp_argc=$#; _wcdp_arg2="${2:-}"; _wcdp_arg3="${3:-}"; return 0; }
# WHY: $# proves arity 3; ${2}/${3} prove the lane's ephemeral_dir + POOL_CHROME_PID were passed. The
# recorder is under `if !` so returning 0 is set -e safe and makes the relaunch SUCCEED (so ec==0 is
# assertable). This is the minimal, hermetic proof of the arity change.
```

### Integration Points

```yaml
CODE (lib/pool.sh):
  - edit: "relaunch-branch pool_wait_cdp call arity 1→3 (Task 1)"
  - site: "inside pool_ensure_connected, the `if ! pool_wait_cdp \"$port\"; then` line (locate by grep)"
  - effect: "enables check_identity=1 inside pool_wait_cdp → pool_cdp_is_ours runs after curl succeeds"

DOCS (lib/pool.sh — inline docstrings, Mode A):
  - edit: "pool_wait_cdp docstring IDENTITY VERIFICATION block (Task 2)"
  - edit: "pool_cdp_is_ours docstring CONSUMER block (Task 3)"
  - effect: "remove the now-false 'ensure_connected relaunch path … already knows its Chrome is bound' claim"

TESTS (test/validate.sh):
  - add: "selftest_ensure_connected_relaunch_passes_identity_args (Task 4) — auto-discovered by _run_selftest_suite"

NO other integration points: the return contract is unchanged; no consumer changes; no config; no
migrations; no README/skill changes (those are P1.M1.T4.S1's scope).
```

## Validation Loop

> **AGENTS.md §1/§2**: every command below is wrapped in `timeout`. All static checks are
> non-blocking. The full suite (`bash test/validate.sh`) runs ONLY in the test framework's
> isolated temp-tree sandbox (it redirects HOME/state/ephemeral roots under `$ABPOOL_TEST_ROOT`);
> never against the operator's live environment.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after each file edit — fix before proceeding. Wrap in timeout (AGENTS.md §2).
timeout 30 bash -n lib/pool.sh            && echo "pool.sh syntax OK"
timeout 30 bash -n test/validate.sh       && echo "validate.sh syntax OK"
timeout 60 shellcheck -s bash -S warning lib/pool.sh
timeout 60 shellcheck -s bash -S warning test/validate.sh
# Expected: zero shellcheck warnings. If warnings exist, READ output and fix before proceeding.
```

### Level 2: Grep Invariants + Unit Selftests (Component Validation)

```bash
# (a) The arity change took effect — the relaunch call now passes 3 args:
timeout 10 bash -c 'grep -nq '\''if ! pool_wait_cdp "\$port" "\$ephemeral_dir" "\${POOL_CHROME_PID:-}"; then'\'' lib/pool.sh' \
  && echo "relaunch 3-arg call PRESENT" || echo "MISSING 3-arg call"

# (b) No 1-arg pool_wait_cdp call remains in pool_ensure_connected:
timeout 10 bash -c '! grep -nq '\''if ! pool_wait_cdp "\$port"; then'\'' lib/pool.sh' \
  && echo "no 1-arg call remains" || echo "STALE 1-arg call present"

# (c) Both docstring claims are gone:
timeout 10 bash -c '! grep -nq "ensure_connected relaunch path, which already knows its Chrome is bound" lib/pool.sh' \
  && echo "pool_wait_cdp claim GONE" || echo "STALE pool_wait_cdp claim"
timeout 10 bash -c '! grep -nq "back-compat for standalone tests / the ensure_connected relaunch path" lib/pool.sh' \
  && echo "pool_cdp_is_ours claim GONE" || echo "STALE pool_cdp_is_ours claim"

# (d) The new test function exists and is discoverable:
timeout 10 bash -c 'grep -nq "selftest_ensure_connected_relaunch_passes_identity_args" test/validate.sh' \
  && echo "new test PRESENT" || echo "MISSING new test"

# (e) Run the FULL selftest suite (isolated temp-tree runner — _run_selftest_suite calls setup() ONCE).
#    Must exit 0. The new test + S1's 3 tests + all others must PASS.
timeout 600 bash test/validate.sh
# Expected: exit 0, all selftests PASS (incl. selftest_ensure_connected_relaunch_passes_identity_args
# and the S1 ensure_connected tests). If failing, read the failing test's stderr (the assert_eq message
# includes the body.sh stdout) and debug root cause.
```

### Level 3: Diff Scope (System Validation — confirms S2 did NOT over-reach)

```bash
# Confirm S2 touched ONLY: (1) the relaunch pool_wait_cdp line, (2) pool_wait_cdp docstring,
# (3) pool_cdp_is_ours docstring, (4) the new test function. The reconnect branch, the jq extraction,
# the pool_wait_cdp/pool_cdp_is_ours BODIES, and S1's tests must be byte-unchanged.
timeout 20 git -C "$PWD" --no-pager diff -- lib/pool.sh test/validate.sh
# Expected: a SMALL diff. Inspect manually:
#   lib/pool.sh  — exactly 1 changed code line (arity) + ~6 changed comment lines (2 docstrings).
#   test/validate.sh — exactly 1 added function (selftest_ensure_connected_relaunch_passes_identity_args).
# If the diff shows changes to the reconnect branch, the jq mapfile/local decl, the pool_wait_cdp BODY,
# the pool_cdp_is_ours BODY, or S1's tests → STOP and revert those (out of scope).

# Optional: targeted confirm that the function bodies are untouched:
timeout 20 git -C "$PWD" --no-pager diff -- lib/pool.sh | grep -E '^[+-]' | grep -vE '^[+-]\s*#' | grep -vE '^\+\+\+|^---'
# Expected: exactly ONE non-comment changed line (the arity change). Any other non-comment change is a scope violation.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (No browser/daemon/integration testing — AGENTS.md §1: do NOT boot real Chrome during research/
#  validation against the shared sandbox. The selftest suite in Level 2 is the hermetic, isolated
#  validation. The identity behavior of pool_wait_cdp/pool_cdp_is_ours is already covered by the
#  existing selftest_launch_and_verify_* tests + pool_wait_cdp's own probe-loop logic; S2's new
#  test proves the relaunch branch ROUTES into that tested code path with the right args.)
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `timeout 30 bash -n lib/pool.sh` exits 0; `timeout 60 shellcheck -s bash -S warning lib/pool.sh` clean.
- [ ] `timeout 30 bash -n test/validate.sh` exits 0; `timeout 60 shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] `timeout 600 bash test/validate.sh` exits 0 (all selftests PASS, incl. S2's new test + S1's 3 tests).

### Feature Validation

- [ ] The relaunch-branch `pool_wait_cdp` call passes 3 args (Level 2 grep (a) + (b)).
- [ ] Both docstring claims removed/revised (Level 2 grep (c)).
- [ ] NEW `selftest_ensure_connected_relaunch_passes_identity_args` exists, is discovered, and PASSES
      (Level 2 grep (d) + suite (e)).
- [ ] The relaunch recorder test asserts `_wcdp_argc==3`, `_wcdp_arg2==<ephemeral_dir>`,
      `_wcdp_arg3==<POOL_CHROME_PID>`, `ec==0`.
- [ ] S1's 3 ensure_connected tests still PASS (S2 did not touch the reconnect branch or S1's tests).
- [ ] The function's return contract (0=connected, 1=not) is unchanged (diff scope, Level 3).

### Code Quality Validation

- [ ] Follows existing codebase patterns (the 3-arg form is copied verbatim from `_pool_launch_and_verify`).
- [ ] File placement matches (docstring edits in-place; test added in the ensure_connected test group).
- [ ] Anti-patterns avoided (no `local x=$(…)`; no bare pool_chrome_launch in the test returning non-zero;
      no set -e hazard on the arity change).
- [ ] Scope respected (reconnect branch, jq extraction, function bodies, S1 tests — all untouched).

### Documentation & Deployment

- [ ] The two docstrings are accurate post-fix (no stale "relaunch path already knows" claim).
- [ ] The new test is self-documenting (header comment explains the invariant + why stubs are load-bearing).
- [ ] No new environment variables or config.

---

## Anti-Patterns to Avoid

- ❌ Don't change anything beyond the 3 args on the relaunch line (no log string, no return logic, no comment).
- ❌ Don't touch the reconnect branch, the jq extraction, the `local` decl, or S1's tests (S1 owns them).
- ❌ Don't edit the `pool_wait_cdp` / `pool_cdp_is_ours` FUNCTION BODIES — only their DOCSTRINGS.
- ❌ Don't stub `pool_chrome_launch` without `declare -g` in the test (POOL_CHROME_PID would be invisible).
- ❌ Don't let the `pool_chrome_launch` test stub return non-zero (bare call under set -e → body aborts).
- ❌ Don't boot real Chrome or run the suite against the shared sandbox (AGENTS.md §1) — use the isolated
  selftest runner only.
- ❌ Don't locate edits by fixed line number — use content grep (S1 shifted line numbers ~21).
