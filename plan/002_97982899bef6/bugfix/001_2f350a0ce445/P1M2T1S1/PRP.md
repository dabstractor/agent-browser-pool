# PRP — P1.M2.T1.S1: Replace `test_passthrough_skills` and `test_version_passthrough` with fail-fast tests + update header

> **Bugfix context**: This subtask fixes the **test half of Issue 3** (Major) from the QA report
> (`plan/002_97982899bef6/bugfix/001_2f350a0ce445/TEST_RESULTS.md`). The code half — deleting
> the META-passthrough execution path — is done by the sibling subtasks **P1.M1.T1.S1**
> (deleted step-c from `pool_wrapper_main`; COMPLETE) and **P1.M1.T1.S2** (deletes the dead
> `pool_dispatch_classify` function; IN PARALLEL). After P1.M1.T1.S1, `agent-browser-pool
> skills get core` and `agent-browser-pool --version` (with no `pi` ancestor) hit step d
> (owner resolve → `POOL_OWNER_PID==0` → `pool_die` with the `'pi ancestor'` message) — they
> are DRIVING commands now, NOT meta passthrough.
>
> **The problem this PRP fixes**: `test/transparency.sh` STILL asserts the OLD (removed)
> META-passthrough behavior — `test_passthrough_skills` (line 236) and `test_version_passthrough`
> (line 270) both assert byte-equal output vs the real binary, and the header checklist
> (lines 8-12) + the inline comments (lines 229-234, 265-268) document the removed model.
> Because the tests still assert the old behavior, the suite PASSES despite the delta being
> unmet — the deviation is invisible to the runner/CI. This PRP replaces those two tests with
> fail-fast assertions matching the new contract, and syncs the header + inline comments.

---

## Goal

**Feature Goal**: Replace `test_passthrough_skills` and `test_version_passthrough` in
`test/transparency.sh` with fail-fast tests that assert the post-fix contract: `agent-browser-pool
skills get core` and `agent-browser-pool --version`, invoked with **no `pi` ancestor**, fail-fast
with the `pool_die` message containing `'pi ancestor'` (sub-second, no Chrome, no lane boot). Sync
the file header checklist (lines 8-12) and the two inline TEST header comments (lines 229-234,
265-268) to describe the new driving/fail-fast contract instead of the removed META-passthrough
model. The suite must then FAIL on the old (buggy) code and PASS on the fixed code — making the
delta visible to CI.

The fail-fast mechanism is **proven**: it is the exact pattern already used by
`test_driving_no_pi_ancestor_fails_fast` (test/transparency.sh:485-511, item i) — `setsid --fork`
(detach the child from the `pi`/bash chain) + `env -u` (strip owner overrides) + temp-file +
bounded poll for `'pi ancestor'`. This PRP factors that mechanism into a shared helper and
points the two new test bodies at it.

**Deliverable**:
1. `test/transparency.sh` — **rename** `test_passthrough_skills` → `test_skills_fail_fast_no_pi`
   and **replace its body** with the fail-fast pattern (delegating to a new shared helper).
   Update the inline TEST (a) header comment (lines 229-234).
2. `test/transparency.sh` — **rename** `test_version_passthrough` → `test_version_fail_fast_no_pi`
   and **replace its body** with the fail-fast pattern. Update the inline TEST (b2) header
   comment (lines 265-268).
3. `test/transparency.sh` — **add** a shared helper `_transparency_assert_driving_no_pi_fails_fast`
   (the factored fail-fast verifier) immediately before the TEST (a) banner.
4. `test/transparency.sh` — **update the header checklist** (lines 8-12): change lines (a) and
   (b2) from `→ passthrough (META → exec real binary; byte-equal)` to
   `→ FAIL-FAST (driving, no pi ancestor; §2.4 step 1)`. Line (b1) is UNCHANGED.
5. No code changes (the code fix is P1.M1.T1.S1/S2's scope). No doc changes (the skill docs are
   P1.M1.T1.S2's `SKILL.md` scope and P1.M3.T1.S1's `README.md` scope; this PRP touches ONLY
   `test/transparency.sh`).

**Success Definition**:
- `test_skills_fail_fast_no_pi` and `test_version_fail_fast_no_pi` are defined in
  `test/transparency.sh` and auto-discovered by the single-setup runner
  (`compgen -A function | grep '^test_'`).
- `test_passthrough_skills` and `test_version_passthrough` NO LONGER EXIST (renamed).
- The shared helper `_transparency_assert_driving_no_pi_fails_fast` is defined.
- `grep -nE 'passthrough|meta' test/transparency.sh` returns ZERO hits in live
  test/header content (the only acceptable hits would be inside a comment explicitly noting
  what was REMOVED — but this PRP's replacements do NOT add such comments, so the grep should
  be zero or near-zero; see Validation).
- `bash -n test/transparency.sh` clean; `shellcheck -s bash test/transparency.sh` 0 findings.
- DO NOT run the test suite against the shared sandbox (AGENTS.md §1) — validation is static
  (`bash -n` + `shellcheck` + `grep`) plus reasoning about the proven mechanism.

## User Persona

**Target User**: CI / the test runner, and future maintainers reading the transparency suite.
Today the suite passes on buggy code (the META-passthrough tests assert the old behavior the
code still implements when P1.M1.T1 is only partially done). After this PRP, the suite encodes
the NEW contract: `skills`/`--version` are driving commands that fail-fast without a `pi`
ancestor.

**Use Case**: A maintainer runs `bash test/transparency.sh`. If the META-passthrough code path
is present (buggy/old code), `test_skills_fail_fast_no_pi` and `test_version_fail_fast_no_pi`
FAIL (the commands pass through instead of fail-fasting). If the code path is removed (fixed
code, post-P1.M1.T1.S1), they PASS. The suite becomes a faithful gate on the delta.

**User Journey**: CI runs `bash test/transparency.sh` → `_abpool_run_transparency_suite` calls
`setup()` once → discovers `^test_` bodies → runs `test_skills_fail_fast_no_pi` (sets up real
env, does NOT spawn an owner, detaches `agent-browser-pool skills get core` via `setsid --fork`
+ `env -u`, polls for `'pi ancestor'` in the output) → asserts the fail-fast message → PASS (on
fixed code) or FAIL (on buggy code, where `skills` passes through and no `'pi ancestor'` message
appears within 10s).

**Pain Points Addressed**:
- **Invisible delta (Issue 3)**: the tests asserted the OLD behavior, so the suite passed
  despite the META-passthrough removal being unmet. This PRP makes the suite assert the NEW
  behavior, so the delta is visible to CI.
- **Stale docs in the test file**: the header checklist + inline comments described the removed
  "META → exec real binary" model, misleading maintainers. This PRP syncs them to the
  driving/fail-fast contract.
- **The `pool_dispatch_classify` comment at transparency.sh:266** (flagged by P1.M1.T1.S2 as
  "owned by P1.M2.T1.S1"): this PRP removes it (it lives inside `test_version_passthrough`'s
  header, which is replaced).

## Why

- **Issue 3 (Major)** from the QA report, test half. The code half is P1.M1.T1.S1/S2; this PRP
  is the test half. Both halves are required for the delta to be faithful (code removed AND
  tests assert the new behavior).
- **The fail-fast mechanism is proven, not novel.** `test_driving_no_pi_ancestor_fails_fast`
  (item i, already in the suite and working) uses the exact `setsid --fork` + `env -u` +
  temp-file-poll pattern. This PRP factors it into a shared helper and points two new bodies at
  it — zero new mechanism, just reuse. The researcher confirmed (via util-linux setsid(1) +
  setsid(2) semantics) that `--fork` is mandatory (bare `setsid` is flaky; `--wait` is FATAL —
  it keeps the chain intact).
- **Minimal blast radius.** The change is: 2 test bodies replaced, 1 helper added, 2 header
  lines + 2 inline comment blocks updated. No code, no other tests, no docs outside
  transparency.sh. The single-setup runner is untouched (the new `^test_` bodies are
  auto-discovered).
- **Closes the P1.M1.T1.S2 cross-cutting residual.** P1.M1.T1.S2's PRP explicitly flagged
  transparency.sh:266's `pool_dispatch_classify` comment as "owned by P1.M2.T1.S1" and documented
  that the grep-zero goal is scoped to lib/pool.sh + test/validate.sh for S2. This PRP removes
  that residual by replacing the test that contains it.

## What

User-visible behavior: none (test file only). Observable contract for the transparency suite:

| Test (old) | Test (new) | Old assertion | New assertion |
|---|---|---|---|
| `test_passthrough_skills` | `test_skills_fail_fast_no_pi` | `agent-browser-pool skills get core` output byte-equals `$POOL_REAL_BIN skills get core` (META passthrough) | `agent-browser-pool skills get core` with NO pi ancestor fail-fasts with `'pi ancestor'` in stderr (driving) |
| `test_version_passthrough` | `test_version_fail_fast_no_pi` | `agent-browser-pool --version` output byte-equals `$POOL_REAL_BIN --version` (META passthrough) | `agent-browser-pool --version` with NO pi ancestor fail-fasts with `'pi ancestor'` in stderr (driving) |

The fail-fast assertion uses the proven pattern: `_transparency_setup_real_env` (so
`_pool_preflight_real_bin` passes BEFORE the owner-resolve die), NO `_transparency_spawn_owner`
(the test condition is "no pi ancestor"), `env -u AGENT_BROWSER_POOL_OWNER_PID -u
AGENT_BROWSER_POOL_OWNER_STARTTIME setsid --fork "$ABPOOL_ADMIN" <cmd> >"$tmp" 2>&1 &`, then
poll `$tmp` (bounded 10s) for the substring `'pi ancestor'`.

### Success Criteria

- [ ] `test_passthrough_skills` and `test_version_passthrough` NO LONGER EXIST in
  `test/transparency.sh` (renamed to `test_skills_fail_fast_no_pi` and
  `test_version_fail_fast_no_pi`).
- [ ] `test_skills_fail_fast_no_pi` and `test_version_fail_fast_no_pi` ARE DEFINED and named
  with the `^test_` prefix (auto-discovered by the single-setup runner).
- [ ] Both new bodies call `_transparency_setup_real_env` (so preflight passes) and do NOT call
  `_transparency_spawn_owner` (no pi ancestor is the condition under test).
- [ ] Both new bodies delegate to the shared helper `_transparency_assert_driving_no_pi_fails_fast`,
  which implements the `setsid --fork` + `env -u` + temp-file + bounded-poll-for-`'pi ancestor'`
  pattern (mirroring `test_driving_no_pi_ancestor_fails_fast`).
- [ ] The shared helper `_transparency_assert_driving_no_pi_fails_fast` is defined (with the
  `_transparency_*` internal-helper prefix, so it is NOT auto-discovered as a test).
- [ ] The header checklist lines (a) and (b2) (lines 8-12) say `→ FAIL-FAST (driving, no pi
  ancestor; §2.4 step 1)` (was `→ passthrough (META → exec real binary; byte-equal)`). Line (b1)
  is UNCHANGED.
- [ ] The inline TEST (a) header comment (lines 229-234) describes the new contract (skills is
  driving, fail-fasts without pi; same mechanism as item i).
- [ ] The inline TEST (b2) header comment (lines 265-268) describes the new contract for
  `--version` AND no longer references `pool_dispatch_classify` (the removed function).
- [ ] `bash -n test/transparency.sh` clean (zero output).
- [ ] `shellcheck -s bash test/transparency.sh` rc 0, 0 findings.
- [ ] `grep -nE 'passthrough|meta' test/transparency.sh` returns ZERO hits in the test bodies
  and header (acceptable residual hits would only be in unrelated comments describing the owner-
  passthrough concept OR a deliberate "this was removed" note — but this PRP's replacements add
  neither, so the grep should be zero).
- [ ] No code files modified (lib/pool.sh, bin/* are P1.M1.T1's scope — already done/in-progress).
- [ ] No doc files modified (SKILL.md is P1.M1.T1.S2; README.md is P1.M3.T1.S1).
- [ ] DO NOT run the test suite against the shared sandbox (AGENTS.md §1).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP quotes the EXACT current text of every edit site
(header lines 8-12, the TEST (a) header + body lines 229-243, the TEST (b2) header + body lines
264-277 — all verified by direct read of test/transparency.sh on 2026-07-15), gives byte-accurate
replacement text for each, specifies the exact placement of the new helper, and provides the
paste-ready helper + test bodies. The fail-fast mechanism is proven (the reference test item i
is quoted and its correctness is researcher-confirmed via util-linux setsid(1)/setsid(2)
semantics). The implementer needs no prior exposure beyond reading the quoted snippets.

### Documentation & References

```yaml
# MUST READ — project-internal (primary; this is test-mechanic surgery)
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_test_framework.md
  why: THE framework reference. Documents the single-setup runner
        (_abpool_run_transparency_suite, lines 533-573) with ONE setup() call; bodies run via
        `if "$fn"; then` in the MAIN shell (NOT subshell); discovery via
        `compgen -A function | grep '^test_'`. Documents _transparency_setup_real_env (lines
        51-110), _transparency_spawn_owner (lines 152-170), and the reference fail-fast test
        test_driving_no_pi_ancestor_fails_fast (lines ~480-510). Documents validate.sh::setup()
        EXPORTS AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME (why env -u is needed).
  pattern: the reference fail-fast pattern (item i) is the EXACT mechanism to replicate.
  gotcha: the single-setup constraint — the new ^test_ bodies are auto-discovered, NO new
        setup() call. The _transparency_* helper prefix means it is NOT discovered as a test.

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_meta_refs.md
  why: THE reference map for the META-passthrough model. §4 lists the EXACT transparency.sh
        hits: test_passthrough_skills (lines 236-243), test_version_passthrough (lines 270-277),
        header lines 8-12, inline comments 229-234 + 265-268. §0 disambiguates the two
        "passthrough" concepts — ONLY concept #1 (META dispatch) is in scope; concept #2
        (owner-passthrough = POOL_OWNER_PID==0) is UNRELATED and appears in the fail-fast
        MESSAGE ('pi ancestor') which the new tests ASSERT ON (correctly retained).
  pattern: §4's transparency.sh bullet list is the exact hit list to scrub.
  gotcha: the 'passthrough' word in the fail-fast MESSAGE ('no pi ancestor (passthrough mode)'
        at lib/pool.sh:581) is concept #2 (owner-passthrough) and is CORRECT — the new tests
        assert on 'pi ancestor' (a substring of the message), not on 'passthrough'. Do NOT try
        to remove 'passthrough' from the message.

- file: test/transparency.sh
  why: THE file being edited. Exact text of every edit site is quoted in Implementation Tasks
        (verified by direct read 2026-07-15). The reference fail-fast test is at lines 485-511
        (test_driving_no_pi_ancestor_fails_fast) — read it to confirm the mechanism.
  pattern: existing test-body style — `_transparency_setup_real_env || return 1` first line;
        `local` declarations; `assert_eq`/`_fail`/`[[ ==*substr* ]]` assertions; `|| return 1`
        fail-fast. Header comments use `# TEST (x) — ...` banners.
  gotcha: line numbers are STABLE across P1.M1.T1.S1/S2 (neither touches transparency.sh —
        confirmed: S2's PRP explicitly says transparency.sh is owned by P1.M2.T1.S1). The edit
        tool matches by EXACT TEXT anyway, so even a drift is harmless.

- file: test/validate.sh
  why: the BASE framework transparency.sh sources. _fail (line 45), assert_eq (line 57),
        setup() (lines 196-223, the process-spawning step that EXPORTS the owner env vars),
        spawn_sim_owner, the EXIT trap, _run_selftest_suite. Read to confirm _fail/assert_eq
        signatures + the owner-env export that motivates `env -u`.
  pattern: _fail MSG → printf '    FAIL: %s\n' "$*" >&2; return 1. assert_eq EXPECTED ACTUAL
        [LABEL] → [[ == ]] || { _fail; return 1; }.
  gotcha: the new tests do NOT use assert_eq (they use `[[ ==*"pi ancestor"* ]]` + _fail,
        matching the reference item i). assert_eq is for byte-equality; the fail-fast assertion
        is a substring match on a message that includes a path.

- file: lib/pool.sh
  why: confirms the fail-fast message the tests assert on. Step d (owner resolve) at
        lib/pool.sh:3411-3417 (post-S1): pool_die "agent-browser-pool: driving commands
        require a pi ancestor (owning pi process). For raw browser use without pooling, call
        'agent-browser' directly." → stderr contains 'pi ancestor'. This fires BEFORE any
        Chrome/lane work (steps e-k), so the fail-fast is sub-second.
  pattern: step d is the assertion target. The message is stable (P1.M1.T1.S1 only deleted
        step c, not step d).
  gotcha: the line number 3411 is post-S1 (S1 shifted pool_wrapper_main). The edit tool matches
        text, so this is informational only — the TEST asserts on the MESSAGE substring
        'pi ancestor', not on a line number.

- file: bin/agent-browser-pool
  why: confirms `skills` and `--version` are NOT pool verbs (no case arm) → fall to `*)` →
        pool_wrapper_main → step d. So they DO reach the fail-fast (not intercepted as pool
        verbs like --help). This is WHY the new tests work: skills/--version flow through the
        driving path.
  pattern: the case dispatcher (lines 30-37) is the single classifier post-fix.
  gotcha: do NOT touch bin/agent-browser-pool — read-only.

# External authoritative docs (for the HOW — the fail-fast mechanism)
- url: https://man7.org/linux/man-pages/man1/setsid.1.html
  why: util-linux setsid. "-f, --fork — Always fork". Confirms --fork is mandatory (the forking
        parent exits → child reparented to init → ppid chain broken → no pi ancestor found).
  critical: bare `setsid` (no --fork) only forks CONDITIONALLY (when the caller is already a
        session leader) → flaky. `--wait` is FATAL (keeps setsid as the parent → chain intact
        → no fail-fast → test passes for the WRONG reason). The reference pattern uses
        `setsid --fork` (no --wait) + temp-file-poll. Use the pattern AS-IS.
  section: OPTIONS (-f, --fork; -w, --wait).

- url: https://man7.org/linux/man-pages/man2/setsid.2.html
  why: setsid(2) returns EPERM if the caller is a process-group leader — the root cause of bare
        setsid's conditional fork (and thus its flakiness). Confirms WHY --fork is required.
  section: ERRORS (EPERM).

- url: https://man7.org/linux/man-pages/man1/env.1.html
  why: coreutils env. "-u, --unset=NAME — Remove variable from the environment." Confirms env -u
        strips the owner overrides so pool_owner_resolve TEST MODE cannot short-circuit.
  section: OPTIONS (-u, --unset).

- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: set -e exemptions — the `if`/`while` conditions, the `&&`/`||` list (except the final
        command), are EXEMPT from errexit. Confirms every non-zero-returning command in the
        fail-fast pattern is guarded.
  critical: `wait "$bg" 2>/dev/null || true` (wait returns the waited pid's status); `cat "$tmp"
        2>/dev/null || true` (cat rc 1 on missing); `[[ ==*"pi ancestor"* ]] && break` (the [[ ]]
        is part of a && list, not the final command) — all errexit-exempt.
  section: errexit (-e).

- url: https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html
  why: `wait` — reaps the setsid zombie (AGENTS.md §3). The detached child is NOT this shell's
        child (reparented to init) → this shell cannot/need-not wait it.
  section: wait.

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M1T1S2/PRP.md
  why: P1.M1.T1.S2 (delete pool_dispatch_classify) runs IN PARALLEL. It edits lib/pool.sh
        (3012-3128 delete + 7 comment rewording) + test/validate.sh (delete selftest) + SKILL.md.
        It does NOT touch test/transparency.sh — its PRP explicitly says "test/transparency.sh —
        owned by P1.M2.T1.S1" and flags the line-266 pool_dispatch_classify comment inside
        test_version_passthrough as THIS subtask's scope.
  pattern: S2 established the principle "replace META-passthrough assertions with the new
        contract" — THIS subtask does the transparency.sh half (S2 did the validate.sh half +
        the SKILL.md half).
  gotcha: S2 may have landed BEFORE or AFTER this PRP. Either way, transparency.sh is untouched
        by S2, so this PRP's edit sites are stable. The line-266 pool_dispatch_classify comment
        (inside test_version_passthrough's header) is removed by THIS PRP's EDIT SITE 3
        (replacing the whole test_version_passthrough header+body).

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M1T1S1/PRP.md
  why: P1.M1.T1.S1 (delete step-c) is COMPLETE. It deleted the step-c META block from
        pool_wrapper_main, dropping `class` from the locals. After S1, `skills`/`--version`
        reach step d (owner resolve) and fail-fast without a pi ancestor. THIS subtask's tests
        ASSERT that behavior — so they PASS on post-S1 code and FAIL on pre-S1 code (the desired
        CI gate).
  pattern: S1's step-c deletion is the CODE fix; this PRP is the TEST fix that makes it visible.
  gotcha: if S1 were reverted, these new tests would FAIL (skills/--version would pass through,
        no 'pi ancestor' message). That is the CORRECT behavior — the suite should fail on
        buggy code.

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M2T1S1/research/fail-fast-test-pattern.md
  why: the deep-research brief with all host-verified + framework-researched facts: the proven
        reference pattern (item i), why each element (setsid --fork, env -u, temp-file-poll,
        wait) is mandatory, the exact fail-fast message, the DRY helper factoring, the AGENTS.md
        compliance analysis, and the strict-mode safety audit of every command.
  pattern: research §1 (the reference pattern) + §6 (the DRY helper).
  gotcha: research §2.1's `--wait is FATAL` finding is critical — NEVER add --wait to the
        setsid call (it would make the test pass for the wrong reason).

- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M2T1S1/research/reference-impl.md
  why: the byte-accurate edit sites — the EXACT current text of every oldText block (header
        lines 8-12, TEST (a) 229-243, TEST (b2) 264-277) and the exact replacement newText, plus
        the helper definition. The direct ancestor of the Implementation Tasks section.
  pattern: the 4 edit sites (header, TEST (a), TEST (b2), helper-add).
  gotcha: match the oldText BYTE-FOR-BYTE (including the `# =============...` banners and blank
        lines). If a match fails, re-read the region — the text is stable but byte-accuracy is
        required.
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                 # 4523 LOC — pool_wrapper_main step d (fail-fast) at 3411-3417 (post-S1). NOT EDITED by this PRP.
├── bin/agent-browser-pool      # the case dispatcher. NOT EDITED (read-only; skills/--version fall to *)).
├── test/
│   └── transparency.sh         # ~569 LOC — THE file. EDIT: header (8-12), TEST(a) (229-243), TEST(b2) (264-277), ADD helper.
│                               #   reference fail-fast test (item i) at 485-511 — the mechanism to replicate.
│   └── validate.sh             # NOT EDITED by this PRP (P1.M1.T1.S2's scope).
└── plan/002_97982899bef6/bugfix/001_2f350a0ce445/
    ├── architecture/{research_test_framework,research_meta_refs,...}.md
    ├── P1M1T1S1/PRP.md              # COMPLETE (step-c deleted)
    ├── P1M1T1S2/PRP.md              # IN PARALLEL (delete pool_dispatch_classify + validate.sh selftest + SKILL.md)
    └── P1M2T1S1/                    # THIS subtask
        ├── PRP.md                   # THIS FILE
        └── research/{fail-fast-test-pattern.md, reference-impl.md}
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 1 existing file:
#   test/transparency.sh  — rename 2 tests + replace their bodies + add 1 helper + update header (2 lines) + update 2 inline comment blocks
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (setsid --fork is mandatory; --wait is FATAL): the fail-fast mechanism requires
# `setsid --fork` (util-linux: always fork → child reparented to init → ppid chain broken →
# no pi ancestor found). Bare `setsid` only forks CONDITIONALLY (caller is a session leader)
# → FLAKY. `setsid --fork --wait` keeps setsid as the parent → chain INTACT → pool_owner_resolve
# FINDS pi → NO fail-fast → test passes for the WRONG reason. Use `setsid --fork` (no --wait).
# The reference test_driving_no_pi_ancestor_fails_fast (item i) uses exactly this. Researcher-confirmed.

# CRITICAL (env -u is mandatory): validate.sh::setup() EXPORTS AGENT_BROWSER_POOL_OWNER_PID and
# _OWNER_STARTTIME every call (the sim-owner). Test bodies inherit them. If a leftover owner
# env rode into the detached child, pool_owner_resolve TEST MODE would use it directly (skip
# the ppid walk) → the tool believes it HAS an owner → NO fail-fast → wrong result. `env -u
# AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME` strips both. (Stripping
# _OWNER_STARTTIME is belt-and-suspenders; _OWNER_PID is the actual TEST-MODE trigger.)

# CRITICAL (temp-file + bounded poll, NOT $()): `setsid --fork` exits IMMEDIATELY after
# forking. The detached child is orphaned to init. So `out="$( setsid --fork cmd 2>&1 )"` is
# RACY (the $() subshell's direct child was setsid, already exited; if a regression makes the
# command hang, $() blocks FOREVER → wedges the sandbox). The redirect `>"$tmp" 2>&1` is
# inherited across fork+exec+orphaning, so the file accumulates the child's stderr. Then the
# bounded poll (10s ceiling, 0.2s sleep) reads it. The fail-fast is sub-second (step d, before
# any Chrome), so the loop exits on iteration 1 almost always. NEVER replace this with $() or
# timeout+setsid (research §2.3).

# CRITICAL (wait reaps the setsid zombie): after backgrounding `env ... setsid --fork ... &`,
# do `wait "$bg" 2>/dev/null || true`. setsid exits immediately → becomes a zombie until its
# parent waits. Unreaped, /proc/$bg lingers → a later liveness probe could false-positive;
# unreaped children accumulate and wedge the sandbox (AGENTS.md §3). The detached CHILD is NOT
# this shell's child (reparented to init) → this shell cannot/need-not wait it (init reaps it
# when it self-exits via pool_die).

# CRITICAL (the new tests do NOT call _transparency_spawn_owner): the test condition is "NO pi
# ancestor". _transparency_spawn_owner spawns a live pi owner + EXPORTS the owner env (which
# env -u then strips — but spawning it would be pointless and could leave a stray process).
# The reference item i test ALSO does not spawn an owner. Match it exactly.

# CRITICAL (the new tests DO call _transparency_setup_real_env): _pool_preflight_real_bin
# (step a, BEFORE step d) checks POOL_REAL_BIN exists+exec and pool_die's if not. validate.sh's
# setup() clobbers HOME → empty master / nonexistent POOL_REAL_BIN → pool_die before reaching
# step d → the test would see a DIFFERENT error (not 'pi ancestor'). So the new tests MUST call
# _transparency_setup_real_env to point AGENT_BROWSER_REAL at the real binary. The reference
# item i test does exactly this.

# GOTCHA (line numbers are STABLE): P1.M1.T1.S1 edited lib/pool.sh (pool_wrapper_main, ~3411+).
# P1.M1.T1.S2 edits lib/pool.sh + test/validate.sh + SKILL.md. NEITHER touches test/transparency.sh.
# THEREFORE the transparency.sh line numbers (header 8-12, TEST(a) 229-243, TEST(b2) 264-277,
# reference item i 485-511) are STABLE. The edit tool matches by text anyway.

# GOTCHA (the 'passthrough' in the fail-fast MESSAGE is UNRELATED): the pool_die message at
# lib/pool.sh:3415 is "driving commands require a pi ancestor ...". The 'no pi ancestor
# (passthrough mode)' log line at lib/pool.sh:581 is concept #2 (owner-passthrough). The new
# tests assert on 'pi ancestor' (a substring of BOTH the message and the log line). Do NOT try
# to remove 'passthrough' from the code — it is correct (concept #2). The grep-zero goal is for
# the TEST FILE's live content (test bodies + header), not the code.

# GOTCHA (test naming): the item contract names the tests test_skills_fail_fast_no_pi and
# test_version_fail_fast_no_pi — use THOSE names verbatim (not the researcher's suggested
# test_*_no_pi_ancestor_fails_fast, which is longer; the contract is explicit). The ^test_
# prefix is what the runner discovers.

# GOTCHA (helper naming): the shared helper is _transparency_assert_driving_no_pi_fails_fast
        # (leading _ = internal helper, matching the repo's _transparency_* convention). It is
        # NOT auto-discovered as a test (the runner greps ^test_, not ^_transparency_).

# GOTCHA (scope): this PRP touches ONLY test/transparency.sh. Do NOT: edit lib/pool.sh (P1.M1.T1's
        # scope), edit test/validate.sh (P1.M1.T1.S2), edit SKILL.md (P1.M1.T1.S2), edit README.md
        # (P1.M3.T1.S1), edit bin/agent-browser-pool (read-only), or refactor the reference item i
        # test (it works; leave it — minimize blast radius).

# GOTCHA (AGENTS.md §1): validation is STATIC ONLY. Do NOT run bash test/transparency.sh (it
        # would launch real Chrome for the other test bodies). bash -n + shellcheck + grep are
        # the only validation commands. The fail-fast behavior is verified by the PROVEN MECHANISM
        # (identical to item i, already in the suite and working) — not by running the new tests.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models, no schemas. This is test-body replacement + helper extraction +
comment sync. The only "structure" is the test-function naming contract:

| Old name | New name | Prefix |
|---|---|---|
| `test_passthrough_skills` | `test_skills_fail_fast_no_pi` | `^test_` (auto-discovered) |
| `test_version_passthrough` | `test_version_fail_fast_no_pi` | `^test_` (auto-discovered) |
| (new) | `_transparency_assert_driving_no_pi_fails_fast` | `_transparency_*` (internal helper, NOT discovered) |

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current file and confirm the edit sites + the reference mechanism
  - RUN: sed -n '8,12p;229,243p;264,277p;485,511p' test/transparency.sh
    # (or read test/transparency.sh offset 1 limit 20; offset 225 limit 60; offset 469 limit 50)
  - EXPECT:
      - header lines 8-12: the checklist with (a)/(b1)/(b2) passthrough/FAIL-FAST lines
      - TEST (a) header + test_passthrough_skills body (229-243)
      - TEST (b2) header + test_version_passthrough body (264-277)
      - the reference test_driving_no_pi_ancestor_fails_fast (485-511) — the mechanism to replicate
  - RUN (confirm the fail-fast message the tests will assert on):
        grep -n 'require a pi ancestor' lib/pool.sh
    - EXPECT: one hit at ~line 3415 (post-S1) — "agent-browser-pool: driving commands require
        a pi ancestor (owning pi process). For raw browser use without pooling, call
        'agent-browser' directly." Contains the substring 'pi ancestor'.
  - RUN (confirm skills/--version are NOT pool verbs → reach step d):
        grep -n 'skills\|--version' bin/agent-browser-pool
    - EXPECT: ZERO hits (they fall to the `*)` arm → pool_wrapper_main → step d).
  - NOTE: do NOT touch the reference item i test (485-511) — it works; leave it. Do NOT touch
        any other test body, the runner, or the helpers (except adding the new one).

Task 1: EDIT test/transparency.sh — update the header checklist (lines 8-12)
  - FIND (the exact current 3 lines — verify with the read in Task 0):
        #   (a)  agent-browser-pool skills get core → passthrough (META → exec real binary; byte-equal)
        #   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
        #   (b2) agent-browser-pool --version       → passthrough (META → exec real binary; byte-equal)
  - REPLACE WITH:
        #   (a)  agent-browser-pool skills get core → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
        #   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
        #   (b2) agent-browser-pool --version       → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
  - WHY: lines (a) and (b2) described the removed META-passthrough model; post-P1.M1.T1.S1
        they are driving commands that fail-fast without a pi ancestor. Line (b1) is UNCHANGED
        (--help is still a pool verb). The text matches the item contract verbatim.
  - GOTCHA: only lines (a) and (b2) change. Do NOT touch (b1), (c)-(i), or any other header line.

Task 2: EDIT test/transparency.sh — ADD the shared fail-fast helper (before the TEST (a) banner)
  - PLACE: immediately BEFORE the `# TEST (a) — ...` banner line (currently line 229). The line
        above (228) is the `# ===...` separator closing the previous section. Insert the helper
        between line 228's banner and the new TEST (a) header (added in Task 3). Concretely:
        the helper goes where the OLD `# TEST (a) — ...passthrough...` header was — Task 3
        replaces that header, and the helper is added as a new block ABOVE the replacement
        header. (Implementation: do Task 3's edit to include the helper at the top of the
        replacement, OR add the helper as a separate edit whose oldText is the `# ===...` banner
        + the old `# TEST (a)` line and whose newText is the banner + helper + new `# TEST (a)`
        line. The latter is cleaner — see Task 3.)
  - ADD this helper definition:
        # _transparency_assert_driving_no_pi_fails_fast CMD... — shared verifier: assert that a driving
        # command (CMD...) with NO pi ancestor fail-fasts with the 'pi ancestor' pool_die message.
        # Mirrors the proven mechanism of test_driving_no_pi_ancestor_fails_fast (item i):
        #   - `setsid --fork` ALWAYS forks → the detached child is reparented to the subreaper/init,
        #     so its ppid chain no longer contains `pi` (bare `setsid` only forks conditionally → flaky;
        #     `--wait` is FATAL — it keeps setsid as the parent → chain intact → no fail-fast).
        #   - `env -u` strips AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME so pool_owner_resolve's TEST MODE
        #     cannot short-circuit (validate.sh::setup exports them; without -u the child would inherit
        #     a fake owner → no fail-fast).
        #   - redirect to a TEMP FILE (setsid --fork exits immediately after forking → `$()` capture is
        #     racy + could wedge on a regression) + bounded poll (10s ceiling; pool_die is sub-second).
        # pool_die fires at pool_wrapper_main step d, BEFORE any Chrome/lane work → no orphan
        # (the detached child self-exits; setsid pid reaped by `wait`). AGENTS.md §1-§3 compliant.
        _transparency_assert_driving_no_pi_fails_fast() {
            local tmp bg deadline msg
            tmp="$(mktemp)"
            env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
                setsid --fork "$ABPOOL_ADMIN" "$@" >"$tmp" 2>&1 &
            bg=$!
            wait "$bg" 2>/dev/null || true              # reap the setsid zombie (AGENTS.md §3); setsid exits immediately after forking
            # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
            deadline=$(( $(date +%s) + 10 ))
            msg=""
            while (( $(date +%s) < deadline )); do
                msg="$(cat "$tmp" 2>/dev/null || true)"
                [[ "$msg" == *"pi ancestor"* ]] && break
                sleep 0.2
            done
            rm -f -- "$tmp"
            [[ "$msg" == *"pi ancestor"* ]] \
                || { _fail "no-pi '$*' did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
        }
  - WHY a helper: the two new tests share the EXACT mechanism (only the argv differs). Factoring
        avoids 3x duplication (the helper, test a, test b2) and matches the DRY principle. The
        reference item i test CAN be left as-is (it works; don't touch it) — or OPTIONALLY
        refactored to use the helper, but that is OUT OF SCOPE (minimize blast radius).
  - GOTCHA: the helper is `_transparency_*` (internal) → NOT auto-discovered as a test. Correct.
  - GOTCHA: include a trailing blank line after the helper's closing `}` so it is separated
        from the following TEST (a) banner by one blank line (matches the prevailing style).

Task 3: EDIT test/transparency.sh — replace the TEST (a) header + test_passthrough_skills body (lines 229-243)
  - FIND (the exact current block — the `# TEST (a)` banner through the function's closing `}`):
        # TEST (a) — `agent-browser-pool skills get core` → passthrough (META, byte-equal to real binary).
        # PRD §2.15: meta commands are unaffected. `skills` has no case arm in bin/agent-browser-pool →
        # the driving-command dispatcher → the pool's meta classifier
        # classifies cmd=`skills` as meta → exec
        # `$POOL_REAL_BIN skills get core`. META short-circuits BEFORE owner resolve — but set a pi
        # ancestor anyway to prove meta wins regardless. Assert EQUALITY (not content — output varies).
        # =============================================================================
        test_passthrough_skills() {
            _transparency_setup_real_env || return 1
            _transparency_spawn_owner >/dev/null       # a pi ancestor IS present; meta ignores it
            local w r
            w="$(timeout 15 "$ABPOOL_ADMIN" skills get core 2>/dev/null || true)"
            r="$(timeout 15 "$POOL_REAL_BIN"  skills get core 2>/dev/null || true)"
            assert_eq "$r" "$w" "skills get core: pool output == real binary output (meta passthrough)" || return 1
        }
  - REPLACE WITH (the helper from Task 2 + the new header + the new body — combine into ONE edit
        so the helper lands directly above the new TEST (a) banner):
        # _transparency_assert_driving_no_pi_fails_fast CMD... — shared verifier: assert that a driving
        # command (CMD...) with NO pi ancestor fail-fasts with the 'pi ancestor' pool_die message.
        # Mirrors the proven mechanism of test_driving_no_pi_ancestor_fails_fast (item i):
        #   - `setsid --fork` ALWAYS forks → the detached child is reparented to the subreaper/init,
        #     so its ppid chain no longer contains `pi` (bare `setsid` only forks conditionally → flaky;
        #     `--wait` is FATAL — it keeps setsid as the parent → chain intact → no fail-fast).
        #   - `env -u` strips AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME so pool_owner_resolve's TEST MODE
        #     cannot short-circuit (validate.sh::setup exports them; without -u the child would inherit
        #     a fake owner → no fail-fast).
        #   - redirect to a TEMP FILE (setsid --fork exits immediately after forking → `$()` capture is
        #     racy + could wedge on a regression) + bounded poll (10s ceiling; pool_die is sub-second).
        # pool_die fires at pool_wrapper_main step d, BEFORE any Chrome/lane work → no orphan
        # (the detached child self-exits; setsid pid reaped by `wait`). AGENTS.md §1-§3 compliant.
        _transparency_assert_driving_no_pi_fails_fast() {
            local tmp bg deadline msg
            tmp="$(mktemp)"
            env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
                setsid --fork "$ABPOOL_ADMIN" "$@" >"$tmp" 2>&1 &
            bg=$!
            wait "$bg" 2>/dev/null || true              # reap the setsid zombie (AGENTS.md §3); setsid exits immediately after forking
            # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
            deadline=$(( $(date +%s) + 10 ))
            msg=""
            while (( $(date +%s) < deadline )); do
                msg="$(cat "$tmp" 2>/dev/null || true)"
                [[ "$msg" == *"pi ancestor"* ]] && break
                sleep 0.2
            done
            rm -f -- "$tmp"
            [[ "$msg" == *"pi ancestor"* ]] \
                || { _fail "no-pi '$*' did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
        }

        # TEST (a) — `agent-browser-pool skills get core` with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
        # Post P1.M1.T1.S1 (step-c META passthrough deleted), `skills` is a DRIVING command: it has no
        # case arm in bin/agent-browser-pool → falls to pool_wrapper_main → step d (owner resolve) →
        # POOL_OWNER_PID==0 (no pi ancestor) → pool_die 'driving commands require a pi ancestor …'.
        # Same fail-fast mechanism as test_driving_no_pi_ancestor_fails_fast (item i): detach via
        # `setsid --fork` (reparent the child away from the pi/bash chain) + `env -u` (strip owner
        # overrides) + capture to a temp file + poll for 'pi ancestor'. pool_die fires at step d,
        # BEFORE any Chrome/lane work → sub-second, no orphan. (A pi ancestor is deliberately NOT
        # spawned — that is the condition under test.)
        # =============================================================================
        test_skills_fail_fast_no_pi() {
            _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
            _transparency_assert_driving_no_pi_fails_fast skills get core || return 1
        }
  - WHY combined into one edit: the helper is logically grouped with its first caller, and a
        single edit avoids any ambiguity about where the helper goes. The replacement preserves
        the prevailing style (helper block, blank line, `# TEST (a)` banner, body).
  - GOTCHA: the oldText MUST match byte-for-byte (including the multi-line `# classifies
        cmd=...` wrap and the trailing blank line after `}`). Re-read lines 229-244 to confirm.
  - GOTCHA: the function is RENAMED test_passthrough_skills → test_skills_fail_fast_no_pi
        (per the item contract).

Task 4: EDIT test/transparency.sh — replace the TEST (b2) header + test_version_passthrough body (lines 264-277)
  - FIND (the exact current block — the `# TEST (b2)` banner through the function's closing `}`):
        # TEST (b2) — `agent-browser-pool --version` → passthrough (META, byte-equal to real binary).
        # `--version` has NO case arm in bin/agent-browser-pool → falls to the driving-command dispatcher →
        # pool_dispatch_classify classifies `--version` as meta → exec `$POOL_REAL_BIN --version`.
        # So the byte-equal assertion STILL HOLDS (identical to the old model, just via $ABPOOL_ADMIN).
        # =============================================================================
        test_version_passthrough() {
            _transparency_setup_real_env || return 1
            _transparency_spawn_owner >/dev/null
            local w r
            w="$(timeout 15 "$ABPOOL_ADMIN"  --version 2>/dev/null || true)"
            r="$(timeout 15 "$POOL_REAL_BIN" --version 2>/dev/null || true)"
            assert_eq "$r" "$w" "--version: pool output == real binary output (meta passthrough)" || return 1
        }
  - REPLACE WITH:
        # TEST (b2) — `agent-browser-pool --version` with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
        # Post P1.M1.T1.S1 (step-c META passthrough deleted), `--version` is a DRIVING command: it has
        # no case arm in bin/agent-browser-pool → falls to pool_wrapper_main → step d (owner resolve) →
        # POOL_OWNER_PID==0 (no pi ancestor) → pool_die 'driving commands require a pi ancestor …'.
        # Same fail-fast mechanism as test_driving_no_pi_ancestor_fails_fast (item i). pool_die fires
        # at step d, BEFORE any Chrome/lane work → sub-second, no orphan.
        # =============================================================================
        test_version_fail_fast_no_pi() {
            _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
            _transparency_assert_driving_no_pi_fails_fast --version || return 1
        }
  - WHY: same as Task 3 but for --version. The new header no longer references
        pool_dispatch_classify (the removed function — P1.M1.T1.S2 deletes it from lib/pool.sh;
        this PRP removes the reference from transparency.sh:266, closing the cross-cutting
        residual S2's PRP flagged). Renamed per item contract: test_version_passthrough →
        test_version_fail_fast_no_pi.
  - GOTCHA: the oldText MUST match byte-for-byte. Note the `# pool_dispatch_classify classifies
        ...` line (old line 266) is INSIDE this block — replacing the whole block removes it.

Task 5: VERIFY — static validation only (AGENTS.md §1: no Chrome, no test suite run)
  - RUN (in order):
      bash -n test/transparency.sh
      shellcheck -s bash test/transparency.sh
      grep -nE 'passthrough|meta' test/transparency.sh
      grep -n 'pool_dispatch_classify' test/transparency.sh
      grep -n 'test_passthrough_skills\|test_version_passthrough' test/transparency.sh
      grep -n 'test_skills_fail_fast_no_pi\|test_version_fail_fast_no_pi\|_transparency_assert_driving_no_pi_fails_fast' test/transparency.sh
  - EXPECTED:
      bash -n                          → no output (clean)
      shellcheck -s bash               → rc 0, 0 findings
      grep passthrough|meta            → ZERO hits (or only in unrelated owner-passthrough comments
                                         if any leaked into transparency.sh — but the item contract
                                         says zero; verify none are in test bodies/header)
      grep pool_dispatch_classify      → ZERO hits (the line-266 residual is removed by Task 4)
      grep old test names              → ZERO hits (both renamed)
      grep new test names + helper     → 3 hits (the 2 new tests + the helper definition)
  - RUN (regression — the OTHER test bodies + the runner are intact):
      grep -n 'test_help_shows_pool_help\|test_open_zero_prep_lands_lane\|test_driving_no_pi_ancestor_fails_fast\|_abpool_run_transparency_suite' test/transparency.sh
      # EXPECT: all 4 present (the reference item i test is UNCHANGED — do NOT refactor it; the
      #         runner is UNCHANGED).
  - RUN (confirm the fail-fast message the tests assert on still exists in the code):
      grep -n 'require a pi ancestor' lib/pool.sh
      # EXPECT: one hit (the step-d pool_die message, post-S1).
  - FIX any failure before claiming done.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern A — the fail-fast verifier (shared helper, proven mechanism) ---------
_transparency_assert_driving_no_pi_fails_fast() {
    local tmp bg deadline msg
    tmp="$(mktemp)"
    env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        setsid --fork "$ABPOOL_ADMIN" "$@" >"$tmp" 2>&1 &
    bg=$!
    wait "$bg" 2>/dev/null || true
    deadline=$(( $(date +%s) + 10 ))
    msg=""
    while (( $(date +%s) < deadline )); do
        msg="$(cat "$tmp" 2>/dev/null || true)"
        [[ "$msg" == *"pi ancestor"* ]] && break
        sleep 0.2
    done
    rm -f -- "$tmp"
    [[ "$msg" == *"pi ancestor"* ]] \
        || { _fail "no-pi '$*' did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
}
# This is the EXACT mechanism of test_driving_no_pi_ancestor_fails_fast (item i), factored.
# `setsid --fork` (not bare, not --wait) + `env -u` (strip overrides) + temp-file + bounded poll.

# --- Pattern B — a test body delegates to the helper (3 lines) -------------------
test_skills_fail_fast_no_pi() {
    _transparency_setup_real_env || return 1
    _transparency_assert_driving_no_pi_fails_fast skills get core || return 1
}
# The body: (1) set up real env (preflight passes), (2) do NOT spawn owner, (3) assert.
# The `|| return 1` propagates the helper's failure (the runner records FAIL, suite continues).

# --- Pattern C — the assertion is a SUBSTRING match, not byte-equality -----------
# OLD tests: assert_eq "$r" "$w" (byte-equal pool output vs real binary output).
# NEW tests: [[ "$msg" == *"pi ancestor"* ]] (substring of the pool_die message).
# WHY: the fail-fast message includes a path/styling that varies; the contract is "contains
# 'pi ancestor'", not "byte-equal". Matches the reference item i test.

# --- Critical micro-rules baked into the helper ---------------------------------
#  * `setsid --fork` (no --wait) — ALWAYS fork → child reparented to init → chain broken.
#    bare setsid is flaky (conditional fork); --wait is FATAL (chain intact → no fail-fast).
#  * `env -u VAR -u VAR2` — strips owner overrides so TEST MODE cannot short-circuit.
#  * `>"$tmp" 2>&1 &` then `wait "$bg" 2>/dev/null || true` — temp file survives orphaning;
#    wait reaps the setsid zombie (AGENTS.md §3).
#  * `while (( $(date +%s) < deadline ))` — the (( )) is the while CONDITION (errexit-exempt).
#  * `[[ "$msg" == *"pi ancestor"* ]] && break` — the [[ ]] is part of a && list (exempt).
#  * `cat "$tmp" 2>/dev/null || true` — cat rc 1 on missing file → msg="" (no abort).
#  * `rm -f -- "$tmp"` — `-f` → rc 0 even if missing (safe bare).
#  * final `[[ ... ]] || { _fail; return 1; }` — failing [[ ]] is exempt; block ends in
#    return 1 → recorded FAIL, suite continues.
```

### Integration Points

```yaml
CODE (in-place edits in 1 file, no new files):
  - test/transparency.sh:8-12      header checklist (lines a + b2: passthrough → FAIL-FAST)
  - test/transparency.sh:229-243   TEST (a) header + test_passthrough_skills → helper + TEST (a) + test_skills_fail_fast_no_pi
  - test/transparency.sh:264-277   TEST (b2) header + test_version_passthrough → TEST (b2) + test_version_fail_fast_no_pi

DO NOT TOUCH:
  - lib/pool.sh                    P1.M1.T1.S1 (step-c, COMPLETE) + P1.M1.T1.S2 (pool_dispatch_classify, parallel)
  - test/validate.sh               P1.M1.T1.S2 (selftest_dispatch_classify deletion)
  - .agents/skills/.../SKILL.md    P1.M1.T1.S2 (the skill doc)
  - .agents/skills/.../references/configuration.md   P1.M1.T1.S1 (already "pool verbs vs driving")
  - README.md                      P1.M3.T1.S1 (Mode B cross-cutting docs)
  - bin/agent-browser-pool         read-only; already the sole classifier
  - test/transparency.sh:485-511   the reference item i test (test_driving_no_pi_ancestor_fails_fast) — LEAVE IT (works; minimize blast radius)
  - test/transparency.sh runner (_abpool_run_transparency_suite) — UNCHANGED (auto-discovers ^test_)

CONFIG: none (no env vars change).
ROUTES: none.
DATABASE: none.
```

## Validation Loop

> **AGENTS.md §1/§2 compliance**: ALL validation here is STATIC. `bash -n` + `shellcheck` +
> `grep` only. Do NOT run `bash test/transparency.sh` (it would launch real Chrome for the
> other test bodies). The fail-fast behavior is verified by the PROVEN MECHANISM (identical to
> the reference item i test, already in the suite and working) — not by running the new tests.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n test/transparency.sh                 # parse check. MUST be clean (no output).
shellcheck -s bash test/transparency.sh      # MUST rc 0, 0 findings.
# Expected: bash -n silent; shellcheck rc 0.
# The pre-edit baseline is already clean (verified). The edits only REPLACE test bodies + ADD a
# helper + UPDATE comments — they CANNOT introduce a shellcheck warning if the helper mirrors
# the proven reference. If shellcheck fires, compare the helper byte-for-byte with the reference
# item i test (test_driving_no_pi_ancestor_fails_fast) — the only difference should be the argv.
```

### Level 2: Unit Tests (Component Validation)

```bash
# There is NO new unit test framework invocation. Validation is by STATIC GREP:

# 2a. The old tests are GONE (renamed):
grep -n 'test_passthrough_skills\|test_version_passthrough' test/transparency.sh
# Expected: ZERO output.

# 2b. The new tests + helper ARE DEFINED:
grep -n 'test_skills_fail_fast_no_pi\|test_version_fail_fast_no_pi\|_transparency_assert_driving_no_pi_fails_fast' test/transparency.sh
# Expected: 3 hits — the 2 new test definitions + the helper definition.

# 2c. The new tests are auto-discoverable by the runner (^test_ prefix):
bash -c 'set -euo pipefail; source test/validate.sh; source test/transparency.sh; compgen -A function | grep "^test_" | grep -E "skills_fail_fast_no_pi|version_fail_fast_no_pi"'
# Expected: 2 hits (test_skills_fail_fast_no_pi + test_version_fail_fast_no_pi).
# NOTE: this only SOURCES (defines functions) — it does NOT run setup() or any body. Safe.
# (Do NOT call _abpool_run_transparency_suite — it spawns Chrome — AGENTS.md.)

# 2d. The helper is NOT discovered as a test (_transparency_* prefix):
bash -c 'set -euo pipefail; source test/validate.sh; source test/transparency.sh; compgen -A function | grep "^test_" | grep "_transparency_assert_driving"'
# Expected: ZERO output (the helper has the _transparency_ prefix, not ^test_).

# 2e. The header checklist lines (a) and (b2) say FAIL-FAST:
sed -n '8,12p' test/transparency.sh | grep -E 'FAIL-FAST'
# Expected: 2 hits (lines a + b2).
sed -n '8,12p' test/transparency.sh | grep -E 'passthrough.*META.*byte-equal'
# Expected: ZERO hits (the old wording is gone from lines a + b2).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. transparency.sh still parses + sources cleanly (the edits didn't orphan anything):
bash -c 'set -euo pipefail; source test/validate.sh; source test/transparency.sh; type _abpool_run_transparency_suite _transparency_setup_real_env _transparency_spawn_owner _transparency_assert_driving_no_pi_fails_fast test_skills_fail_fast_no_pi test_version_fail_fast_no_pi test_driving_no_pi_ancestor_fails_fast'
# Expected: all 7 reported as functions. (Confirms the helper + 2 new tests + the unchanged
#           reference item i test + the runner/helpers are all intact.)
# NOTE: this only SOURCES — it does NOT run setup() or any body. Safe.

# 3b. The pool_dispatch_classify residual at transparency.sh:266 is REMOVED:
grep -n 'pool_dispatch_classify' test/transparency.sh
# Expected: ZERO output. (The line-266 reference lived inside test_version_passthrough's header,
#           which Task 4 replaced. This closes the cross-cutting residual P1.M1.T1.S2 flagged.)

# 3c. No 'passthrough'/'meta' live references remain in test bodies or the header:
grep -nE 'passthrough|meta' test/transparency.sh
# Expected: ZERO hits (or only in the unchanged reference item i test's comment if it mentions
#           "meta" — but it doesn't; it says "driving command". Verify zero.)
# If a hit appears, it's in a comment that should be reworded; investigate and fix.

# 3d. The fail-fast message the tests assert on still exists in the code (regression guard):
grep -n 'require a pi ancestor' lib/pool.sh
# Expected: one hit (the step-d pool_die message). The new tests assert on its 'pi ancestor'
#           substring.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the fail-fast mechanism is BYTE-IDENTICAL to the proven reference (item i),
#     modulo the argv. Diff the helper against test_driving_no_pi_ancestor_fails_fast's body:
sed -n '485,511p' test/transparency.sh | grep -E 'setsid --fork|env -u|pi ancestor|deadline|wait .bg.'
# Expected: hits for each — the SAME primitives. The helper uses the identical mechanism.
# (This is the empirical proof the new tests will work: they share the proven pattern.)

# 4b. Confirm skills/--version reach step d (not intercepted as pool verbs):
grep -nE 'skills|--version' bin/agent-browser-pool
# Expected: ZERO hits (they fall to the `*)` arm → pool_wrapper_main → step d → fail-fast).
# Contrast: `--help` IS a pool verb (grep --help bin/agent-browser-pool → hit).

# 4c. Confirm the suite would FAIL on buggy (pre-P1.M1.T1.S1) code:
#     On pre-S1 code, skills/--version would pass through (step c exec's the real binary) →
#     the detached child prints the real binary's output (NOT 'pi ancestor') → the poll times
#     out at 10s → _fail "did NOT fail fast" → test FAILS. This is the CORRECT CI gate behavior.
#     (We do NOT run this — it's reasoning about the mechanism, validated by 4a.)

# 4d. AGENTS.md compliance check — no processes spawned by validation:
pgrep -af 'setsid|agent-browser-pool|chrome' | grep -v pgrep || echo "no stray processes"
# Expected: "no stray processes" (all validation was static sourcing + grep).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n test/transparency.sh` clean (zero output).
- [ ] `shellcheck -s bash test/transparency.sh` rc 0, 0 findings.
- [ ] Level 2 snippet 2a: old test names → zero hits.
- [ ] Level 2 snippet 2b: new test names + helper → 3 hits.
- [ ] Level 2 snippet 2c: new tests auto-discoverable (`compgen | grep ^test_`).
- [ ] Level 2 snippet 2d: helper NOT discovered as a test (`_transparency_*` prefix).
- [ ] Level 2 snippet 2e: header lines (a)+(b2) say FAIL-FAST; old passthrough wording gone.

### Feature Validation

- [ ] `test_passthrough_skills` and `test_version_passthrough` NO LONGER EXIST (renamed).
- [ ] `test_skills_fail_fast_no_pi` and `test_version_fail_fast_no_pi` ARE DEFINED (`^test_`).
- [ ] Both new bodies call `_transparency_setup_real_env` and do NOT call `_transparency_spawn_owner`.
- [ ] Both new bodies delegate to `_transparency_assert_driving_no_pi_fails_fast`.
- [ ] The helper `_transparency_assert_driving_no_pi_fails_fast` is defined (uses `setsid --fork`
      + `env -u` + temp-file + bounded-poll-for-`'pi ancestor'`, mirroring item i).
- [ ] Header lines (a) and (b2) say `→ FAIL-FAST (driving, no pi ancestor; §2.4 step 1)`.
- [ ] Inline TEST (a) and TEST (b2) header comments describe the new driving/fail-fast contract.
- [ ] The `pool_dispatch_classify` reference at the old line 266 is REMOVED (inside the replaced block).

### Code Quality Validation

- [ ] The ONLY file modified is `test/transparency.sh` (no code/doc/bin files touched).
- [ ] The helper mirrors the proven reference item i test byte-for-byte (modulo the argv).
- [ ] Every `(( ))` is inside `while` (errexit-exempt); every `[[ ]] && break` is a && list (exempt).
- [ ] `wait "$bg" 2>/dev/null || true` reaps the setsid zombie (AGENTS.md §3).
- [ ] The reference item i test (`test_driving_no_pi_ancestor_fails_fast`) is UNCHANGED.
- [ ] The runner (`_abpool_run_transparency_suite`) is UNCHANGED.
- [ ] No scope creep into lib/pool.sh (P1.M1.T1), test/validate.sh (P1.M1.T1.S2), SKILL.md
      (P1.M1.T1.S2), README.md (P1.M3.T1.S1), or bin/agent-browser-pool (read-only).

### Documentation & Deployment

- [ ] The transparency.sh header checklist is the test documentation; lines (a)+(b2) updated inline.
- [ ] The inline TEST (a) and TEST (b2) header comments document the new contract (skills/--version
      are driving; fail-fast without pi; same mechanism as item i).
- [ ] No user-facing/config/API surface change (test files are internal). DOCS clause: none.
- [ ] No README change (Mode B — P1.M3.T1.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't touch ANY file other than `test/transparency.sh` — lib/pool.sh (P1.M1.T1.S1/S2),
  test/validate.sh (P1.M1.T1.S2), SKILL.md (P1.M1.T1.S2), README.md (P1.M3.T1.S1),
  bin/agent-browser-pool (read-only) are all out of scope.
- ❌ Don't use bare `setsid` (flaky — conditional fork) or `setsid --wait` (FATAL — keeps the
  chain intact → no fail-fast → test passes for the wrong reason). Use `setsid --fork` (no --wait).
- ❌ Don't drop `env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME` —
  validate.sh::setup() EXPORTS them; without `-u` the child inherits a fake owner → TEST MODE
  short-circuits → no fail-fast → wrong result.
- ❌ Don't use `$(...)` to capture the detached child's output — `setsid --fork` exits immediately,
  orphaning the child to init; `$()` is racy and could wedge the sandbox on a regression. Use the
  temp-file + bounded-poll pattern (research §2.3).
- ❌ Don't forget `wait "$bg" 2>/dev/null || true` — the setsid process becomes a zombie; unreaped,
  it lingers and can cause false-positive liveness probes (AGENTS.md §3).
- ❌ Don't call `_transparency_spawn_owner` in the new tests — the test condition is "NO pi ancestor".
  Spawning an owner would defeat the purpose (and the `env -u` would strip it anyway). The
  reference item i test ALSO does not spawn an owner.
- ❌ Don't SKIP `_transparency_setup_real_env` — without it, `_pool_preflight_real_bin` (step a,
  BEFORE step d) pool_die's on the missing real binary → the test sees the WRONG error (not
  'pi ancestor'). The reference item i test calls it for exactly this reason.
- ❌ Don't rename the tests to anything other than `test_skills_fail_fast_no_pi` and
  `test_version_fail_fast_no_pi` — the item contract is explicit on the names.
- ❌ Don't refactor the reference item i test (`test_driving_no_pi_ancestor_fails_fast`) to use
  the helper — it works; leave it. Minimize blast radius. (OPTIONAL cleanup, but NOT required
  and NOT recommended for this subtask.)
- ❌ Don't run `bash test/transparency.sh` or `_abpool_run_transparency_suite` — it launches real
  Chrome for the other bodies (AGENTS.md §1). Validation is `bash -n` + `shellcheck` + `grep`.
- ❌ Don't try to remove the word "passthrough" from lib/pool.sh — the 'no pi ancestor (passthrough
  mode)' log line (lib/pool.sh:581) is concept #2 (owner-passthrough), UNRELATED to META dispatch,
  and CORRECT. The new tests assert on 'pi ancestor' (a substring of the message), not on
  'passthrough'. The grep-zero goal is for the TEST FILE's live content only.
- ❌ Don't change the assertion style — the OLD tests used `assert_eq` (byte-equality); the NEW
  tests use `[[ ==*"pi ancestor"* ]]` + `_fail` (substring match on the fail-fast message),
  matching the reference item i test. The fail-fast message includes a path/styling that varies;
  the contract is "contains 'pi ancestor'", not byte-equal.
- ❌ Don't match edit oldText by line number — transparency.sh lines are stable across S1/S2, but
  the edit tool matches text. Match byte-for-byte; re-read on mismatch.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The change is small and surgical (2 test bodies replaced, 1 helper added, 2 header lines + 2
  inline comment blocks updated) and the contract is unusually precise (exact test names, exact
  header wording, exact mechanism).
- The fail-fast mechanism is **proven, not novel** — it is the exact pattern of
  `test_driving_no_pi_ancestor_fails_fast` (item i, already in the suite and working). The
  researcher confirmed via util-linux setsid(1)/setsid(2) semantics that `--fork` is mandatory
  (bare setsid flaky; `--wait` fatal) and via coreutils env(1) that `-u` strips the overrides.
- Every edit site is quoted **byte-for-byte** (verified by direct read of test/transparency.sh
  on 2026-07-15) — header lines 8-12, TEST (a) 229-243, TEST (b2) 264-277.
- The `set -euo pipefail` interactions (`(( ))` in while, `[[ ]] && break`, `wait || true`,
  `cat || true`) are each called out with the exact correct idiom and audited in the research.
- The -1 reflects residual risk in Task 3's combined edit (helper + header + body in one oldText
  block) — if the implementer retypes the oldText from memory instead of reading the current
  file, a whitespace mismatch could fail the edit. The mitigation (read test/transparency.sh
  229-243, copy verbatim) is documented. Level 2 snippet 2a/2b catch any miss immediately.
- AGENTS.md compliance is airtight: validation is static (`bash -n` + `shellcheck` + `grep`),
  no Chrome is launched, the detached child self-exits via `pool_die` (no orphan), the setsid
  zombie is reaped by `wait`, and the new `^test_` bodies are auto-discovered by the single-setup
  runner (no new `setup()` call — AGENTS.md §4).
