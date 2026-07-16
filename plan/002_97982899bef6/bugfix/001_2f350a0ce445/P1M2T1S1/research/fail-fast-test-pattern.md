# Research: fail-fast test pattern + test framework facts (P1.M2.T1.S1)

Date: 2026-07-15 (bugfix 001_2f350a0ce445 — restore lane isolation)
Host-verified + framework-researched facts for replacing the META-passthrough
transparency tests with fail-fast tests.

---

## 1. THE PROVEN REFERENCE PATTERN — test_driving_no_pi_ancestor_fails_fast

`test/transparency.sh:485-511` (`test_driving_no_pi_ancestor_fails_fast`) is the
EXACT mechanism to replicate for `skills get core` and `--version`. Verified by
direct read of the file (lines 469-511) this session.

### The pattern (verbatim mechanism, adapted only for the argv)
```bash
test_driving_no_pi_ancestor_fails_fast() {
    _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
    # Deliberately NO _transparency_spawn_owner — this body has NO pi ancestor.
    local tmp bg deadline msg
    tmp="$(mktemp)"
    env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        setsid --fork "$ABPOOL_ADMIN" open about:blank >"$tmp" 2>&1 &
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
        || { _fail "driving cmd with no pi ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
}
```

---

## 2. WHY each element of the pattern is MANDATORY (host-verified + researched)

### 2.1 `setsid --fork` (NOT bare `setsid`, NOT `setsid --wait`)
- **`--fork` is mandatory** (util-linux setsid: "-f, --fork — Always fork"). The forking
  parent EXITS immediately after forking → the detached child is **reparented to the
  subreaper / init (pid 1)** → its ppid chain no longer contains `pi` →
  `pool_owner_resolve` REAL MODE walks `child → 1`, finds no `pi` → `POOL_OWNER_PID=0` →
  step d `pool_die`. **Deterministic.**
- **Bare `setsid`** (no `--fork`) forks ONLY when the caller is already a session leader
  (`getsid(0)==getpid()`; setsid(2) would EPERM otherwise). When the caller is NOT a
  leader, NO fork → `setsid` exec's the tool IN PLACE → the tool's parent is still the
  test shell → ppid chain still contains `pi` → NO fail-fast → **flaky**. (This is the
  exact flakiness the reference comment documents.)
- **`--wait` is FATAL** (researcher finding): `setsid --fork --wait` keeps `setsid`
  alive as the child's parent for the child's whole lifetime → the child's ppid chain is
  `child → setsid → <shell> → … → pi` → `pool_owner_resolve` FINDS `pi` → NO fail-fast
  → the test passes for the WRONG reason. NEVER add `--wait`.
- Source: https://man7.org/linux/man-pages/man1/setsid.1.html ; https://man7.org/linux/man-pages/man2/setsid.2.html

### 2.2 `env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME`
- `validate.sh::setup()` EXPORTS both vars (the sim-owner) every call. Test bodies
  inherit them. If a leftover `AGENT_BROWSER_POOL_OWNER_PID` rode into the detached
  child, `pool_owner_resolve` TEST MODE would use it directly (skip the ppid walk) →
  the tool believes it HAS an owner → NO fail-fast → wrong result.
- `env -u NAME` (coreutils env: "-u, --unset=NAME — Remove variable from the environment")
  strips the var from the child's env. With `_OWNER_PID` unset, TEST MODE is skipped →
  REAL MODE runs → ppid walk (broken by setsid --fork) → no owner → `pool_die`.
- Stripping `_OWNER_STARTTIME` is belt-and-suspenders (with `_PID` unset, REAL MODE
  runs and starttime is irrelevant), kept for symmetry.
- Source: https://man7.org/linux/man-pages/man1/env.1.html

### 2.3 TEMP FILE + BOUNDED POLL (NOT `$(...)`, NOT `timeout`+`setsid`)
- `setsid --fork` exits IMMEDIATELY after forking. The detached child is orphaned to
  init. So:
  - `out="$( setsid --fork cmd 2>&1 )"` is RACY: the command-substitution's direct child
    was `setsid` (already exited); the actual producer is the orphaned grandchild. If a
    regression makes the command NOT fail-fast (it hangs on Chrome boot), `$()` blocks
    FOREVER → wedges the sandbox (AGENTS.md's cardinal sin). No built-in timeout on `$()`.
  - `timeout 10 setsid --fork cmd` (no --wait): `timeout` observes its child (`setsid`)
    has exited → returns BEFORE the orphaned grandchild writes anything → empty/partial
    capture.
- **The redirect `>"$tmp" 2>&1` is inherited across fork+exec+orphaning**, so the file
  accumulates the child's stderr even after `setsid` exits. Then the bounded poll reads
  it. This is the ONLY shape that satisfies all three constraints: (a) break the chain via
  parent exit, (b) capture output, (c) bound the wait.
- The fail-fast fires at step d, BEFORE any Chrome/lane work → sub-second (≈50-250ms).
  The poll loop exits on iteration 1 almost always. The 10s budget is a CEILING that is
  almost never hit (defensive against a regression that hangs).
- Source: https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html

### 2.4 `wait "$bg" 2>/dev/null || true`
- `bg=$!` is the `env`→`setsid` process pid (the shell's direct child). `setsid --fork`
  exits immediately → that process becomes a ZOMBIE until its parent `wait`s it.
- Unreaped, the zombie keeps `/proc/$bg` alive → a later liveness probe could
  false-positive; unreaped children accumulate and wedge the sandbox (AGENTS.md §3).
- `wait "$bg"` reaps the setsid zombie so `/proc/$bg` truly clears.
- `2>/dev/null || true` is defensive: `wait` returns the waited pid's status (may be
  non-zero); the `|| true` neutralizes it so `set -e` does not abort.
- The DETACHED CHILD (the tool) is NOT this shell's child (reparented to init) → this
  shell CANNOT `wait` it → and does not need to: its new parent (the subreaper) reaps it
  when it self-exits via `pool_die`.
- Source: https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html

---

## 3. THE FAIL-FAST MESSAGE (exact assertion target)

Verified by direct read of `lib/pool.sh:3411-3417` (post-S1; step c deleted, step d is
the owner-resolve fail-fast):

```bash
    # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
                 "For raw browser use without pooling, call 'agent-browser' directly."
    fi
```

`pool_die` does `printf '%s\n' "$*" >&2; exit 1` (multi-arg joined by IFS=space). So the
stderr line contains the substring **`pi ancestor`**. The assertion
`[[ "$msg" == *"pi ancestor"* ]]` matches it.

This fires at step d, BEFORE any Chrome/lane work (steps e→k). So `skills get core` and
`--version` BOTH reach step d (they fall through `bin/agent-browser-pool`'s `*)` arm →
`pool_wrapper_main` → step a config/preflight → step d owner-resolve → `pool_die`).
Sub-second, no Chrome, no lane, no hang, no orphan.

---

## 4. TEST FRAMEWORK FACTS (transparency.sh, confirmed)

- **Single-setup runner**: `_abpool_run_transparency_suite` (test/transparency.sh:533-573)
  calls `setup()` EXACTLY ONCE, then runs bodies via `if "$fn"; then` in the MAIN shell
  (NOT a subshell — no mid-suite EXIT trap). Bodies are discovered by
  `compgen -A function | grep '^test_' | sort` (line 540). So any `^test_` function is
  auto-registered — NO explicit registration list.
- **`_transparency_setup_real_env`** (test/transparency.sh:68-110) sets
  `AGENT_BROWSER_REAL` (real agent-browser binary), `AGENT_CHROME_MASTER` (real
  read-only master), `AGENT_CHROME_EPHEMERAL_ROOT` (btrfs temp), then `pool_config_init;
  pool_state_init`. REQUIRED because `validate.sh::setup()` clobbers HOME → empty master
  / nonexistent POOL_REAL_BIN → pool_die before reaching step d. The new fail-fast tests
  MUST call it (so `_pool_preflight_real_bin` passes BEFORE the owner-resolve die).
- **`_transparency_spawn_owner`** (test/transparency.sh:160-171) spawns a live `pi`-comm
  owner + EXPORTS `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`. The new fail-fast tests
  MUST NOT call it (they need NO pi ancestor — that's the whole point).
- **`_fail MSG`** (validate.sh:45-48): `printf '    FAIL: %s\n' "$*" >&2; return 1`.
  Non-fatal to the harness (the body's `return 1` ends only that body).
- **`assert_eq EXPECTED ACTUAL [LABEL]`** (validate.sh:57-61): `[[ == ]] || { _fail; return 1; }`.
  (The OLD tests used this for byte-equality; the NEW tests use `[[ == *"pi ancestor"* ]]`
  directly + `_fail` on mismatch — matching the reference `test_driving_no_pi_ancestor_fails_fast`.)

---

## 5. LINE-NUMBER STABILITY (transparency.sh is immune to S1/S2)

- P1.M1.T1.S1 (delete step-c) edited `lib/pool.sh` `pool_wrapper_main` (~line 3411+).
- P1.M1.T1.S2 (delete `pool_dispatch_classify`) edits `lib/pool.sh` (~3012-3128) +
  `test/validate.sh` + `SKILL.md`. It does NOT touch `test/transparency.sh`
  (confirmed: the S2 PRP explicitly says transparency.sh is owned by P1.M2.T1.S1).
- THEREFORE: the transparency.sh line numbers in the item description
  (header 8-12, TEST(a) header 229-234, test_passthrough_skills 236-243, TEST(b2) header
  265-268, test_version_passthrough 270-277) are STABLE across S1 and S2. Verified by
  direct read this session: those lines are exactly as the item describes.
- The edit tool matches by EXACT TEXT, so even if lines drift, the quoted oldText blocks
  are byte-accurate. Match by text, never by line number.

---

## 6. THE DRY HELPER FACTORING (recommended structure)

The reference `test_driving_no_pi_ancestor_fails_fast` (item i, for `open about:blank`)
and the two NEW tests (items a/b2, for `skills get core` and `--version`) share the EXACT
same mechanism — only the argv differs. Factor the shared logic into a helper to avoid
3x duplication:

```bash
# _transparency_assert_driving_no_pi_fails_fast CMD...  — shared verifier. Return 1 on failure.
# (Mirrors test_driving_no_pi_ancestor_fails_fast verbatim; CMD... is the driving argv.)
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
```

Then each test body is 3 lines:
```bash
test_skills_fail_fast_no_pi() {
    _transparency_setup_real_env || return 1
    _transparency_assert_driving_no_pi_fails_fast skills get core || return 1
}
test_version_fail_fast_no_pi() {
    _transparency_setup_real_env || return 1
    _transparency_assert_driving_no_pi_fails_fast --version || return 1
}
```

**Decision**: The item contract names the tests `test_skills_fail_fast_no_pi` and
`test_version_fail_fast_no_pi` — use THOSE names verbatim. The helper is named
`_transparency_assert_driving_no_pi_fails_fast` (leading `_` = internal helper, matching
the repo's `_transparency_*` convention). The reference `test_driving_no_pi_ancestor_fails_fast`
(item i) can OPTIONALLY be refactored to use the helper too (DRY cleanup), but that is
OUT OF SCOPE unless the implementer wants to — the item only asks to replace tests (a) and (b2).
Leave item (i) as-is to minimize blast radius (it works; don't touch it).

---

## 7. AGENTS.md COMPLIANCE for this subtask

- **NO real Chrome booted**: the fail-fast fires at step d, BEFORE any Chrome/lane work.
  `skills get core` and `--version` never reach the boot path. The test asserts the
  FAIL-FAST, not a real launch.
- **Isolated**: uses `_transparency_setup_real_env` (real master is READ-ONLY; reflink
  CoW is safe; the btrfs eph root is test-specific + EXIT-trap-reaped). The detached
  child self-exits via `pool_die` → no orphan.
- **Hard timeout**: the 10s poll budget bounds the wait (AGENTS.md §2). The `setsid --fork`
  child is orphaned to init, which reaps it. `wait "$bg"` reaps the setsid zombie.
- **Reap what you spawn**: setsid pid reaped by `wait "$bg"`; detached child reaped by
  its new parent (subreaper/init); temp file removed by `rm -f -- "$tmp"`. Zero orphans.
- **Single setup**: the new tests are `^test_` bodies, picked up by the single-setup
  runner. NO new `setup()` call. (AGENTS.md §4 — the 3rd per-test setup() hangs.)
- **DO NOT run the suite**: validation is `bash -n` + `shellcheck` + `grep` ONLY
  (AGENTS.md §1). The fail-fast behavior is verified by the proven mechanism (identical
  to `test_driving_no_pi_ancestor_fails_fast`, which is already in the suite and works).

---

## 8. SOURCES

- util-linux setsid(1): https://man7.org/linux/man-pages/man1/setsid.1.html (`-f, --fork`)
- setsid(2): https://man7.org/linux/man-pages/man2/setsid.2.html (EPERM for pgroup leader)
- coreutils env(1): https://man7.org/linux/man-pages/man1/env.1.html (`-u, --unset`)
- Bash The Set Builtin (`-e` exemptions): https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- Bash Job-Control Builtins (`wait`): https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html
- Bash Command Substitution: https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html
- Project: `plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_test_framework.md`
- Project: `plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_meta_refs.md`
- Project: `test/transparency.sh:68-110` (_transparency_setup_real_env), `:160-171` (_transparency_spawn_owner), `:469-511` (the reference fail-fast test), `:533-573` (single-setup runner)
- Project: `test/validate.sh:45-61` (_fail, assert_eq)
- Project: `lib/pool.sh:3411-3417` (step d fail-fast message, post-S1)
- Project: `bin/agent-browser-pool:30-37` (the case dispatcher — skills/--version fall to `*)`)
