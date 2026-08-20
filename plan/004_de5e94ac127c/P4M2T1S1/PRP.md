---
name: "P4.M2.T1.S1 — Config selftests: default-path identity + ABPOOL_OWNER any-value + ABPOOL_LANE validation"
---

## Goal

**Feature Goal**: Add selftest coverage in `test/validate.sh` proving the config contract frozen in P4.M1.T2.S1 (`POOL_OWNER_MODE` / `POOL_LANE_PIN` in `pool_config_init`): default path is identity-unchanged, `ABPOOL_OWNER` is any-value (raw-string), `ABPOOL_LANE` is strictly validated (malformed ⇒ die; valid uint ⇒ pin).

**Deliverable**: One new auto-discovered selftest function `selftest_config_owner_mode_and_lane_pin` in `test/validate.sh` (pure logic — subshell `bash -c` invocations of `pool_config_init`, zero processes spawned, zero leases written, no Chrome).

**Success Definition**: `timeout 120 bash test/validate.sh` (isolated sandbox only) reports the new selftest PASS and every pre-existing selftest stays green/untouched. `bash -n` + `shellcheck` clean.

## User Persona

**Target User**: Maintainer/agent validating the pool's config contract.
**Use Case**: Regression gate after any change to `pool_config_init` step 6b.
**Pain Points Addressed**: Silent drift of default-path behavior; accidental truthiness filtering of `ABPOOL_OWNER`; silent fallback on malformed `ABPOOL_LANE`.

## Why

- PRD §2.11/§2.12: default behavior must be **byte-identical** with no env vars; `ABPOOL_OWNER` any value = caller mode; `ABPOOL_LANE` must hard-error on malformed values with no silent fallback (§2.20).
- P4.M2.T1.S2–S4 build on this frozen contract; these selftests lock it before the process-spawning tests land.

## What

A single selftest asserting, in subshells (so the harness's own `POOL_*` globals are untouched):

1. **Default path identity**: with both `ABPOOL_OWNER` and `ABPOOL_LANE` unset ⇒ `POOL_OWNER_MODE == "ancestor"` AND `POOL_LANE_PIN == ""`.
2. **Any-value**: `ABPOOL_OWNER=caller` ⇒ `"caller"`; `ABPOOL_OWNER=1` ⇒ `"caller"` (raw-string check, no truthy filtering — NOT `_pool_config_bool`).
3. **ABPOOL_LANE matrix**:
   - Malformed `0`, `-1`, `abc`, `2.5` ⇒ subshell exits non-zero with `ABPOOL_LANE must be a positive integer` on stderr (assert rc + grep stderr).
   - Explicitly-empty `ABPOOL_LANE=""` ⇒ NO die; `POOL_LANE_PIN == ""` (the implemented contract treats empty as unset-equivalent).
   - Valid `ABPOOL_LANE=3` ⇒ `POOL_LANE_PIN == "3"`.

### Success Criteria
- [ ] New selftest passes; no other selftest modified or failing.
- [ ] No new processes, leases, or temp dirs beyond the existing single-setup framework.

## All Needed Context

### Context Completeness Check
The implementing agent needs: the exact step-6b source of `pool_config_init`, the selftest discovery mechanism, the two canonical idioms (config-in-subshell, die-assert), and the blessed invocation. All are below.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: pool_config_init step 6b (~lines 218–233) — the contract under test
  pattern: |
    if [[ -n "${ABPOOL_OWNER:-}" ]]; then owner_mode="caller"; else owner_mode="ancestor"; fi
    lane_pin="${ABPOOL_LANE:-}"
    if [[ -n "$lane_pin" ]] && [[ ! "$lane_pin" =~ ^[1-9][0-9]*$ ]]; then
        pool_die "agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '$lane_pin'"
    fi
    POOL_OWNER_MODE="$owner_mode"; declare -g POOL_OWNER_MODE
    POOL_LANE_PIN="$lane_pin"; declare -g POOL_LANE_PIN
  gotcha: raw-string check, NOT _pool_config_bool — "0"/"false" still mean caller mode. pool_config_init is re-runnable.

- file: test/validate.sh
  why: selftest framework
  pattern: |
    - discovery: `compgen -A function | grep '^selftest_' | sort` in _run_selftest_suite (~:1170) — NO registration; define the fn anywhere above it.
    - bodies run in the MAIN shell via `if "$fn"` — every assert must end `|| return 1`.
    - helpers: `assert_eq <want> <got> <label>` (:57), `_fail <msg>` (:45).
    - setup() (:204–223): single-setup runner; already redirects HOME/AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT/AGENT_CHROME_MASTER into one mktemp root and calls pool_config_init — do NOT call setup() again.
    - canonical config-subshell: selftest_real_bin_name_or_path (:871) — `VAR=… bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s\n" "$POOL_X"' _ "$ABPOOL_REPO"`.
    - canonical die-assert: selftest_preflight_accepts_bare_name_on_path (:896–911) — `rc=0; ( …set -e… ) || rc=$?` + assert_eq/rc checks.
  gotcha: AGENTS.md §4 — never convert back to per-test setup; never run bodies in `( )` subshells at the top level (EXIT-trap hazard). The small `bash -c` child invocations ARE the approved config-test idiom.

- file: plan/004_de5e94ac127c/P4M2T1S1/research/notes.md
  why: full research notes incl. verified line numbers and gotchas
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh            # pool_config_init (owner_mode/lane_pin at ~:218-233)
test/validate.sh       # selftest framework + all selftest_* functions
```

### Desired Codebase tree

```bash
test/validate.sh       # + selftest_config_owner_mode_and_lane_pin (one function, ~60-90 lines,
                       #   placed after selftest_preflight_accepts_bare_name_on_path ~:911)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: always explicitly control BOTH env vars per case — `env -u ABPOOL_OWNER -u ABPOOL_LANE`
# or unset them inside the bash -c — a later harness shell may export ABPOOL_*.
# CRITICAL: `pool_die` exits the SUBSHELL (bash -c child), never the harness — that's why the
# config tests must run pool_config_init inside `bash -c`, not inline in the selftest body.
# GOTCHA: explicitly-empty ABPOOL_LANE="" does NOT die ([[ -n "" ]] is false) — assert
# POOL_LANE_PIN == "" for that case; do NOT expect a die.
# GOTCHA: capture stderr separately: `2>"$err_file"` on the bash -c, then grep -q 'ABPOOL_LANE' --
# using $HOME-relative temp; mktemp file must be registered in ABPOOL_TEST_ROOTS or rm'd in a
# trap-free `rm -f` at fn end (prefer reusing $HOME from setup() so NO new mktemp is needed —
# but an err-file via mktemp is fine if rm'd unconditionally before every return; simplest: use
# "$(mktemp)" and rm -f it first thing after each subshell capture, or write to "$HOME/err.$$").
# shellcheck: validate.sh is bash — check with `shellcheck -s bash test/validate.sh`.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD selftest_config_owner_mode_and_lane_pin to test/validate.sh
  - PLACEMENT: directly after selftest_preflight_accepts_bare_name_on_path (~:911), before the
    next selftest block; keep the `# --- title ----` comment style used by neighboring blocks.
  - STRUCTURE (single function; subshell `bash -c` per case, following :871 idiom):
    1. helper-in-fn (local closures are fine as plain command repeats): define
       `_cfg()`-style inline invocation is NOT required — just repeat the bash -c snippet:
         mode="$(env -u ABPOOL_OWNER -u ABPOOL_LANE bash -c '
             source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_OWNER_MODE"' _ "$ABPOOL_REPO")"
       (capture POOL_LANE_PIN the same way; reuse setup()'s redirected $HOME — no new mktemp roots).
    2. (a) DEFAULT: assert_eq "ancestor" "$mode" "default owner mode is ancestor" || return 1
            assert_eq "" "$pin" "default lane pin is empty" || return 1
    3. (b) ANY-VALUE: for ABPOOL_OWNER in caller 1: assert_eq "caller" — two explicit
            invocations (not a loop) mirror the precedent style; assert the raw-string contract.
    4. (c) MALFORMED: for each of 0 -1 abc 2.5:
            rc=0; ABPOOL_LANE="$v" bash -c '…set -e…; pool_config_init' 2>"$err" || rc=$?
            [[ $rc -ne 0 ]] || { _fail "…"; return 1; }
            grep -q 'ABPOOL_LANE' "$err" || { _fail "die message mentions ABPOOL_LANE"; return 1; }
            Also assert the exact phrase 'positive integer' for at least one value.
       EMPTY: ABPOOL_LANE="" ⇒ rc 0 and pin "" (explicit assertion, documents intended semantics).
       VALID: ABPOOL_LANE=3 ⇒ pin "3" (and mode unaffected: "ancestor" when OWNER unset).
  - NAMING: exactly selftest_config_owner_mode_and_lane_pin (auto-discovered by the ^selftest_ grep).
  - CONSTRAINTS: zero spawned daemons/Chrome; no lease writes; no calls to setup/teardown.

Task 2: STATIC VALIDATION (immediate)
  - bash -n test/validate.sh
  - shellcheck -s bash test/validate.sh   # zero NEW warnings vs baseline

Task 3: RUN the suite (isolated sandbox ONLY — AGENTS.md §1/§2)
  - timeout 120 bash test/validate.sh
  - Verify: new selftest PASS, pre-existing count unchanged, 0 failed.
  - After run: pgrep -af 'chrome|sleep|abpool' — zero orphans from this work.
```

### Implementation Patterns & Key Details

```bash
# Canonical per-case snippet (capture a frozen global):
mode="$(env -u ABPOOL_OWNER -u ABPOOL_LANE bash -c '
    source "$1/lib/pool.sh"; pool_config_init; printf "%s" "$POOL_OWNER_MODE"
' _ "$ABPOOL_REPO")"
assert_eq "ancestor" "$mode" "default: POOL_OWNER_MODE=ancestor" || return 1

# Canonical die-assert (from :896–911):
err="$HOME/cfgtest-err.$$"; rc=0
ABPOOL_LANE=abc bash -c 'set -e; source "$1/lib/pool.sh"; pool_config_init' \
    _ "$ABPOOL_REPO" 2>"$err" || rc=$?
rm -f -- "$err"
[[ "$rc" -ne 0 ]] || { _fail "ABPOOL_LANE=abc should die"; return 1; }
# (grep the err file BEFORE rm — order: grep, then rm, then assert)
```

### Integration Points

```yaml
NONE: no changes to lib/pool.sh, bin/*, or docs. This item adds tests only.
Pre-existing contract: P4.M1.T2.S1 (config freeze), P4.M1.T3.S1 (POOL_OWNER_MODE consumer),
P4.M1.T4.S1/S2 (POOL_LANE_PIN consumers) — read-only dependencies.
Parallel item P4.M1.T4.S3 (docs) touches only .md files — no conflict.
```

## Validation Loop

### Level 1: Syntax & Style
```bash
bash -n test/validate.sh
shellcheck -s bash test/validate.sh   # no new issues introduced
```

### Level 2: Unit / suite (isolated sandbox ONLY — never the shared env)
```bash
timeout 120 bash test/validate.sh
# Expected: "<N+1> passed, 0 failed" (N = previous pass count), new selftest listed PASS.
```

### Level 3: Post-run hygiene (AGENTS.md §3 checklist)
```bash
pgrep -af 'chrome|agent-browser|abpool|sleep' || echo "clean"   # expect only unrelated procs
ls /tmp/abpool-test* 2>/dev/null   # framework's EXIT trap should have cleaned; if stale roots
                                   # exist from BEFORE this change, do not delete others' dirs
```

## Final Validation Checklist

- [ ] `bash -n` + `shellcheck -s bash test/validate.sh` clean (no new warnings)
- [ ] `timeout 120 bash test/validate.sh` green in isolated sandbox; all pre-existing selftests untouched
- [ ] Default-path identity asserted (ancestor + empty pin)
- [ ] Any-value caller mode asserted (caller, 1 — and 0/false if desired)
- [ ] Malformed matrix (0 -1 abc 2.5): rc≠0 + stderr contains ABPOOL_LANE (and 'positive integer')
- [ ] Empty ABPOOL_LANE ⇒ no die, pin "" ; valid ABPOOL_LANE=3 ⇒ pin "3"
- [ ] Zero spawned processes / leases / leftover temp files; no edits outside test/validate.sh

## Anti-Patterns to Avoid

- ❌ Calling `pool_config_init` inline in the selftest body — a malformed-value die would kill the whole suite; ALWAYS via `bash -c` subshell.
- ❌ Relying on the caller's ambient `ABPOOL_*` — always `env -u` / explicit assignment per case.
- ❌ Adding per-test setup/teardown or restoring a per-test runner (AGENTS.md §4 hard rule).
- ❌ Expecting empty ABPOOL_LANE to die (it doesn't — empty == unset-equivalent).
- ❌ Editing lib/pool.sh, docs, or any selftest other than the new one.
- ❌ Running validate.sh against the operator's real HOME (isolated sandbox only; setup() already redirects, but the invocation itself must be timeout-bounded).