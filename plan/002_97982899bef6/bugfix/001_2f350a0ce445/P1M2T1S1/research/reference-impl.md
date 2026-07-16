# Reference Implementation: byte-accurate edit sites (P1.M2.T1.S1)

All text below is the EXACT current content of `test/transparency.sh` (verified by direct
read on 2026-07-15). Match these verbatim in the edit tool's oldText.

---

## EDIT SITE 1 — Header checklist (lines 8-12)

### Current (oldText)
```
#   (a)  agent-browser-pool skills get core → passthrough (META → exec real binary; byte-equal)
#   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
#   (b2) agent-browser-pool --version       → passthrough (META → exec real binary; byte-equal)
```

### Replacement (newText)
```
#   (a)  agent-browser-pool skills get core → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
#   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
#   (b2) agent-browser-pool --version       → FAIL-FAST (driving, no pi ancestor; §2.4 step 1)
```

WHY: lines (a) and (b2) described the removed META-passthrough model ("byte-equal"). Post-fix
(P1.M1.T1.S1 deleted step c), `skills` and `--version` are DRIVING commands that fail-fast
without a pi ancestor. Line (b1) is UNCHANGED (`--help` is still a pool verb). The text matches
the item contract verbatim (sub-letters c).

---

## EDIT SITE 2 — TEST (a) header + test_passthrough_skills body (lines 229-243)

### Current (oldText) — the full block from the `# TEST (a)` banner through the function's closing `}`
```
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
```
NOTE: the block STARTS at line 229 (`# TEST (a) — ...`) and ENDS at line 243 (the closing `}`).
Line 228 above it is the `# ===...` banner (KEEP it — it's the section separator). Line 244
below is blank (KEEP).

### Replacement (newText)
```
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
```
WHY: the new header documents the post-fix contract (skills is driving, fails-fast without
pi). The body delegates to the shared helper (EDIT SITE 4). The function is renamed per the
item contract: `test_passthrough_skills` → `test_skills_fail_fast_no_pi`.

---

## EDIT SITE 3 — TEST (b2) header + test_version_passthrough body (lines 264-277)

### Current (oldText) — the full block from the `# TEST (b2)` banner through the function's closing `}`
```
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
```
NOTE: the block STARTS at line 264 (`# TEST (b2) — ...`) and ENDS at line 277 (the closing `}`).
Line 263 above is the `# ===...` banner closing test_help_shows_pool_help's section (KEEP).
Line 278 below is blank (KEEP). The `pool_dispatch_classify` reference on line 266 of the old
text is the one P1.M1.T1.S2's PRP flagged as "owned by P1.M2.T1.S1" — THIS edit removes it.

### Replacement (newText)
```
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
```
WHY: same as EDIT SITE 2 but for `--version`. Renamed per item contract:
`test_version_passthrough` → `test_version_fail_fast_no_pi`.

---

## EDIT SITE 4 — ADD the shared fail-fast helper

PLACE: immediately BEFORE the TEST (a) banner (i.e. after the `# ===...` separator at line 228
and before the new `# TEST (a)` header). This groups the helper with its first caller. The
single-setup runner discovers `^test_` bodies via compgen — the helper's `_transparency_*`
prefix means it is NOT discovered as a test (correct; it's a library function).

### newText (the helper definition, to be inserted)
```
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

```
NOTE: include the trailing blank line so the helper is separated from the following
`# TEST (a)` banner by exactly one blank line (matches the prevailing style).

---

## STRICT-MODE SAFETY (every command in the helper audited)

| Command | Non-zero risk | Guard | Why safe |
|---|---|---|---|
| `tmp="$(mktemp)"` | rc 1 only on FS failure | unguarded (mirrors reference) | acceptable; reference does the same |
| `env ... setsid --fork ... &` | n/a (backgrounded) | `&` | bg job status never triggers errexit |
| `wait "$bg"` | returns waited pid's status (may be ≠0) | `2>/dev/null \|\| true` | `\|\| true` is errexit-exempt list tail |
| `cat "$tmp"` (early/empty) | rc 1 if missing/unreadable | inside `$( ... \|\| true)` | `\|\| true` → msg="" |
| `[[ "$msg" == *"pi ancestor"* ]] && break` | `[[ ]]` returns 1 when not-yet-found | part of `&&` list (not the final cmd) | exempt per errexit rules |
| `while (( $(date +%s) < deadline ))` | `(( 0 ))` returns rc 1 | it's the `while` condition | exempt |
| `$(date +%s)` | always rc 0 | — | safe |
| `rm -f -- "$tmp"` | none (`-f` ⇒ rc 0) | — | safe bare |
| final `[[ ... ]] \|\| { _fail; return 1; }` | `_fail` returns 1 | inside `\|\|` RHS ending in `return 1` | failing `[[ ]]` is exempt; block ends in return 1 → FAIL, suite continues |

Sources: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html (errexit exemptions)
