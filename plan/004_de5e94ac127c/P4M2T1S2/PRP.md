---
name: "P4.M2.T1.S2 — Caller-mode resolve selftest (in-process, $PPID)"
---

## Goal

**Feature Goal**: Add a selftest to `test/validate.sh` proving `pool_owner_resolve`'s caller-mode branch (P4.M1.T3.S1, PRD §2.12 mode 1 / O10): with `ABPOOL_OWNER` set and both TEST-MODE hook vars unset, the owner resolves to the calling process's parent `$PPID` with correct comm/starttime/cwd, PID != 0 (fail-fast bypass), and the TEST MODE hook **outranks** caller mode.

**Deliverable**: One new auto-discovered selftest function `selftest_owner_resolves_caller_mode` in `test/validate.sh` (pure logic — a short-lived `bash` child script, zero Chrome, zero leases, zero spawned daemons).

**Success Definition**: `timeout 120 bash test/validate.sh` (isolated sandbox only) reports the new selftest PASS; every pre-existing selftest stays green and unmodified; `bash -n` + `shellcheck -s bash` clean.

## User Persona

**Target User**: Maintainer/agent validating caller-scoped ownership (PRD §2.12).
**Use Case**: Regression gate after any change to `pool_owner_resolve` or `pool_config_init` step 6b.
**Pain Points Addressed**: Silent breakage of caller-mode identity (wrong PID source, missing starttime, or the hook accidentally leaking into caller mode).

## Why

- PRD §2.12: `ABPOOL_OWNER=caller` re-keys ownership on the calling process with no ppid walk and **no harness fail-fast**; the recognized-harness gate (§2.4 step 1) must not fire (POOL_OWNER_PID != 0).
- PRD §2.19 hooks (`AGENT_BROWSER_POOL_OWNER_PID`) must keep outranking caller mode — TEST MODE is the suite's simulation backbone and must never be shadowed.
- Unblocks P4.M2.T1.S3 (parallel caller-mode owners → distinct lanes), which needs resolve proven correct first.

## What

One selftest asserting, via a child `bash` body script (so the harness's own `POOL_OWNER_*` globals are untouched):

1. **Caller-mode identity**: in a child with `ABPOOL_OWNER=caller`, both hook vars unset →
   - `POOL_OWNER_PID` == the child's own `$PPID` (captured first thing in the child)
   - `POOL_OWNER_PID` != 0 (fail-fast bypass proven)
   - `POOL_OWNER_COMM` == contents of `/proc/$PPID/comm`
   - `POOL_OWNER_STARTTIME` non-empty AND == `_pool_get_starttime "$PPID"` (called in the same child)
   - `POOL_OWNER_CWD` == `readlink /proc/$PPID/cwd`
2. **Hook precedence (TEST MODE wins)**: in a child with `ABPOOL_OWNER=caller` AND `AGENT_BROWSER_POOL_OWNER_PID=<a live pid>` set → `POOL_OWNER_PID` == the hook pid (NOT `$PPID`).

### Success Criteria
- [ ] New selftest passes; no other selftest modified or failing.
- [ ] No new processes, leases, or temp dirs beyond the existing single-setup framework (one synchronous foreground `bash` child, naturally reaped).

## All Needed Context

### Context Completeness Check

The implementing agent needs: the caller-mode branch source, the resolution order (TEST MODE first), the selftest framework idioms (child body.sh + `|| rc=$?`), and the blessed validation commands. All below.

### Documentation & References

```yaml
- file: lib/pool.sh
  why: pool_owner_resolve (~:536–660) — the code under test
  pattern: |
    Resolution order (verified):
    1. TEST MODE: [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]] and numeric → use hook pid, return 0. CHECKED FIRST ⇒ outranks caller mode.
    2. CALLER MODE: [[ "$POOL_OWNER_MODE" == "caller" ]] (frozen by pool_config_init step 6b
       ~:225-233 from any non-empty ABPOOL_OWNER):
         - guard: PPID==1 or /proc/$PPID missing → pool_die
         - POOL_OWNER_PID="$PPID"; POOL_OWNER_COMM=$(cat /proc/$PPID/comm)
         - POOL_OWNER_STARTTIME=$(_pool_owner_starttime $PPID); POOL_OWNER_CWD=$(readlink ...)
       NOTE: the implemented contract keys on $PPID (the parent), NOT $$ — PRD §2.12's "$$"
       wording is superseded by the merged code. Follow the code.
    3. REAL MODE ppid walk (untested here).
  gotcha: Globals are RESET to defaults at the top of every resolve call — calling resolve in
    the shared main shell would clobber the harness's POOL_OWNER_* state ⇒ run it in a child.

- file: lib/pool.sh
  why: _pool_get_starttime PID (~:462) — canonical starttime extractor; echoes digits, rc 1 on
    unreadable /proc. Use it inside the child to compute the EXPECTED starttime.

- file: test/validate.sh
  why: selftest framework
  pattern: |
    - discovery: compgen -A function | grep '^selftest_' | sort in _run_selftest_suite (~:1170)
      — NO registration; just define the fn above it.
    - bodies run in the MAIN shell via `if "$fn"`; every assert ends `|| return 1`.
    - helpers: assert_eq <want> <got> <label> (:57); _fail <msg> (:45).
    - setup() (:204-223): single-setup runner; EXPORTS AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME
      for its sim pi owner ⇒ the caller-mode child MUST unset BOTH hook vars.
    - canonical child-body idiom: selftest_cdp_is_ours_uses_socket_owner (~:1182-1190):
      outdir="$ABPOOL_TEST_ROOT/<name>"; mkdir -p; cat >"$outdir/body.sh" <<'EOF' ... EOF
      rc=0; bash "$script" _ "$ABPOOL_REPO" "$outdir" >"$outdir/out" 2>&1 || rc=$?
      then assert rc==0 and grep/parse "$outdir/out".
    - inline env-override precedent: selftest_owner_resolves_non_pi_harness (:351).
  gotcha: the child's $PPID is the (live) selftest main shell — a valid live parent, so the
    caller-mode pool_die guard never fires. Capture $PPID FIRST in the child and reuse it for
    all /proc reads (the parent cannot die mid-child; the suite is synchronous).

- file: plan/004_de5e94ac127c/P4M2T1S1/PRP.md
  why: PARALLEL item adding selftest_config_owner_mode_and_lane_pin to the same file — assume
    it exists; place this fn AFTER it (or after selftest_preflight_accepts_bare_name_on_path
    ~:911 if S1 hasn't landed). Do NOT duplicate its config assertions.
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh            # pool_owner_resolve (TEST MODE :557+, CALLER MODE :592-617), _pool_get_starttime :462
test/validate.sh       # selftest framework; assert_eq :57; _fail :45; setup :204; body.sh idiom :1182
```

### Desired Codebase tree

```bash
test/validate.sh       # + selftest_owner_resolves_caller_mode (one function, ~80-110 lines,
                       #   + its child body.sh written under $ABPOOL_TEST_ROOT at runtime)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: caller mode must be tested with BOTH hook vars UNSET — setup() exports them for the
#   suite, and the TEST MODE branch (checked first) would silently win. Use `env -u ... bash`
#   or unset inside the child: unset AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME.
# CRITICAL: POOL_OWNER_MODE is frozen by pool_config_init — the child must set ABPOOL_OWNER when
#   running pool_config_init (env must be present at config time, not just at resolve time).
# GOTCHA: pool_config_init + pool_owner_resolve in the child also need the hook vars unset AT
#   RESOLVE TIME only for case 1; for case 2 (precedence) SET AGENT_BROWSER_POOL_OWNER_PID to a
#   live pid — the main-shell $$ works (pass it in as argv[2] to body.sh; it stays alive for the
#   synchronous child's lifetime).
# GOTCHA: /proc/<pid>/comm has a trailing newline when read with cat; `$(cat ...)` strips it —
#   compare directly, no extra trimming. comm may be truncated to 15 chars (proc(5)) — harmless
#   here (comparing like-for-like).
# GOTCHA: readlink /proc/$PPID/cwd may be empty/unreadable (permissions) — compare against the
#   SAME command's output in the child, not an absolute path; if BOTH empty that's a pass. Use
#   [[ "$got" == "$want" ]] only when want is non-empty; else assert non-empty only if want is.
#   Simplest robust form: compute want & got in the same child, print both, assert_eq in the fn.
# GOTCHA: never call resolve directly in the main shell — it resets/clobbers POOL_OWNER_* globals.
# shellcheck: validate.sh is bash — check with `shellcheck -s bash test/validate.sh`.

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD selftest_owner_resolves_caller_mode to test/validate.sh
  - PLACEMENT: after the P4.M2.T1.S1 config selftest (selftest_config_owner_mode_and_lane_pin)
    if present, else after selftest_preflight_accepts_bare_name_on_path (~:911). Keep the
    `# selftest_... — description` comment style of neighboring blocks.
  - STRUCTURE:
    1. local outdir script rc out want_ppid want_st want_comm want_cwd
       outdir="$ABPOOL_TEST_ROOT/caller-resolve"; mkdir -p -- "$outdir"
       script="$outdir/body.sh"
    2. cat >"$script" <<'EOF' — body (set -euo pipefail; source "$1/lib/pool.sh"):
       CASE 1 (identity):
         unset AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME
         ABPOOL_OWNER=caller pool_config_init        # env present AT CONFIG time
         ppid="$PPID"                                # capture FIRST
         want_comm="$(cat /proc/$ppid/comm 2>/dev/null || true)"
         want_st="$(_pool_get_starttime "$ppid" 2>/dev/null || true)"
         want_cwd="$(readlink /proc/$ppid/cwd 2>/dev/null || true)"
         pool_owner_resolve                          # rc 0 always
         printf '%s\n' "PPID|$ppid" "PID|$POOL_OWNER_PID" "COMM|$POOL_OWNER_COMM" \
                       "ST|$POOL_OWNER_STARTTIME" "CWD|$POOL_OWNER_CWD"
         [[ "$POOL_OWNER_PID" == "$ppid" && "$POOL_OWNER_PID" != "0" ]] || exit 1
         [[ -n "$POOL_OWNER_STARTTIME" ]] || exit 1
       CASE 2 (precedence, second run of body.sh or second script arg):
         ABPOOL_OWNER=caller AGENT_BROWSER_POOL_OWNER_PID="$3" pool_config_init
         AGENT_BROWSER_POOL_OWNER_PID="$3" pool_owner_resolve   # hook read at resolve time
         printf 'HOOKPID|%s\n' "$POOL_OWNER_PID"
         [[ "$POOL_OWNER_PID" == "$3" ]] || exit 1
       (Implement as ONE body.sh taking a mode arg: bash "$script" _ "$ABPOOL_REPO" "$MODE" "$hookpid";
        MODE=identity runs case 1, MODE=precedence runs case 2. Cleaner than two scripts.)
    3. Runner in the selftest fn (main shell):
       rc=0; bash "$script" _ "$ABPOOL_REPO" identity "$$" >"$outdir/out" 2>&1 || rc=$?
       assert_eq "0" "$rc" "caller-mode resolve body exit" || return 1
       rc=0; bash "$script" _ "$ABPOOL_REPO" precedence "$$" >"$outdir/out2" 2>&1 || rc=$?
       assert_eq "0" "$rc" "precedence body exit" || return 1
    4. Parse "$outdir/out" (cut -d'|' -f2 lines) and assert in the MAIN shell with assert_eq:
       - PID == PPID line value          label "caller-mode owner is the child's \$PPID"
       - PID != 0                        (redundant with body exit but keep an explicit assert)
       - COMM == want_comm (body prints it; compare like-for-like from out)
       - ST == want_st AND non-empty     label "starttime matches _pool_get_starttime"
       - CWD: compare got==want (both may be empty → pass on equality)
       - out2: HOOKPID value == "$$" passed in  label "TEST MODE hook outranks caller mode"
       Every assert ends `|| return 1`.
  - SAFETY: synchronous foreground bash children (reaped by || rc=$?); no daemons, no
    leases, no signals; nothing to trap. Cleanup of $outdir is the suite's job (ABPOOL_TEST_ROOT).
  - NAMING: selftest_owner_resolves_caller_mode (exact — discovery is by prefix).

Task 2: STATIC VALIDATION (no live run against the shared sandbox)
  - bash -n test/validate.sh
  - shellcheck -s bash test/validate.sh   (new fn must add zero warnings)

Task 3: LIVE VALIDATION (isolated sandbox ONLY — AGENTS.md §1/§2)
  - timeout 120 bash test/validate.sh   → new selftest PASS + all pre-existing selftests green
  - Confirm zero orphaned processes afterwards (pgrep -af 'sleep|abpool' should show nothing new).
```

### Implementation Patterns & Key Details

```bash
# The single most important ordering fact (verified in pool_owner_resolve):
#   TEST MODE (hook) is checked BEFORE the caller-mode branch. Case 2 asserts the hook wins
#   even when POOL_OWNER_MODE == "caller" — this protects the whole suite's simulation model.
#
# Body-script pattern (follows selftest_cdp_is_ours_uses_socket_owner :1182):
#   cat >"$script" <<'EOF'
#   set -euo pipefail
#   source "$1/lib/pool.sh"
#   case "$3" in
#     identity)   ... resolve + print pipe-delimited KV lines ... ;;
#     precedence) ... hook set + resolve + print HOOKPID ... ;;
#   esac
#   EOF
#   rc=0; bash "$script" _ "$ABPOOL_REPO" identity "$$" >out 2>&1 || rc=$?
# Parse with: awk -F'|' '/^PID|/{...}' or one grep per key — keep it simple and readable.
```

### Integration Points

```yaml
NONE:
  - No lib/pool.sh changes (this item tests existing code from P4.M1.T3.S1).
  - No docs (per item contract).
  - No new env vars, no leases, no state-dir writes.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n test/validate.sh
shellcheck -s bash test/validate.sh
# Expected: zero errors / zero NEW warnings.
```

### Level 2: Component (selftest suite — isolated sandbox only)

```bash
timeout 120 bash test/validate.sh
# Expected: selftest_owner_resolves_caller_mode PASS; all pre-existing selftests PASS.
# Run ONLY in an isolated sandbox (mktemp HOME/state redirect already done by setup());
# never against the operator's live ~/.local/state/agent-browser-pool (AGENTS.md §1).
```

### Level 3: Leak audit

```bash
pgrep -af 'abpool|agent-browser|sleep' || true
# Expected: nothing spawned by this selftest remains (it spawns only synchronous bash children).
```

### Level 4: Creative / domain-specific

N/A (pure-logic selftest; no Chrome, no MCP, no endpoints).

## Final Validation Checklist

- [ ] `bash -n test/validate.sh` clean; `shellcheck -s bash test/validate.sh` adds zero warnings
- [ ] `timeout 120 bash test/validate.sh` green in the isolated sandbox (new + all old selftests)
- [ ] Identity assertions: PID == child $PPID; PID != 0; COMM == /proc/$PPID/comm; STARTTIME non-empty == `_pool_get_starttime $PPID`; CWD matches readlink (or both empty)
- [ ] Precedence assertion: hook set + ABPOOL_OWNER=caller ⇒ resolve returns hook pid
- [ ] No other selftest modified; no processes/leases/temp roots leaked
- [ ] Function named exactly `selftest_owner_resolves_caller_mode` (auto-discovered)

## Anti-Patterns to Avoid

- ❌ Don't call `pool_owner_resolve` in the main shell — it clobbers the harness's `POOL_OWNER_*` globals
- ❌ Don't test caller mode without unsetting BOTH hook vars — TEST MODE will silently win and the test proves nothing
- ❌ Don't re-call setup() or convert to per-test setup (AGENTS.md §4)
- ❌ Don't run validate.sh against the operator's real state dirs — isolated sandbox only
- ❌ Don't assert against `$$` semantics — the implemented caller mode keys on `$PPID`