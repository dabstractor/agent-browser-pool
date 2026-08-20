# PRP — P4.M1.T2.S1: Add POOL_OWNER_MODE / POOL_LANE_PIN to pool_config_init

## Goal

**Feature Goal**: Parse and freeze two new user-set env vars — `ABPOOL_OWNER` (caller-scoped
ownership mode) and `ABPOOL_LANE` (explicit lane pin) — into new globals `POOL_OWNER_MODE` and
`POOL_LANE_PIN` inside `pool_config_init` (lib/pool.sh), with zero change to the default path
(both vars unset ⇒ behavior byte-identical to HEAD) and zero new shellcheck warnings.

**Deliverable**: A new numbered step (6b) in `pool_config_init` between the harnesses block
(step 6) and derived paths (step 7), setting two new `declare -g` globals; plus two new rows in
the env-var table comment (L112–L131 region).

**Success Definition**:
- `ABPOOL_OWNER` non-empty (ANY value, no truthy filtering) ⇒ `POOL_OWNER_MODE="caller"`;
  unset/empty ⇒ `POOL_OWNER_MODE="ancestor"`.
- `ABPOOL_LANE` unset/empty ⇒ `POOL_LANE_PIN=""`; set and matching `^[1-9][0-9]*$` ⇒
  `POOL_LANE_PIN="<digits>"`; set and malformed ⇒ `pool_die` with the raw value echoed,
  before any flock (config-init runs pre-flock on every invocation — PRD §2.20).
- Default path (neither var set): only two new empty/"ancestor" assignments; no control-flow
  change vs HEAD.
- `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` remain clean (zero new warnings;
  the in-file SC2034 disable at ~L131 already covers POOL_* globals — do not add new disables).

## Why

PRD §2.12 (caller-scoped lane selection, O10/O11) requires parallel browser-driving
subprocesses from one harness to each own a lane. This subtask is the config layer only:
later subtasks consume the globals — P4.M1.T3.S1 reads `POOL_OWNER_MODE` in
`pool_owner_resolve`; P4.M1.T4.S1/S2 read `POOL_LANE_PIN` in the acquire path. Tests land in
P4.M2.T1.S1. This subtask deliberately touches **no consumer** — it only sets globals.

## What

### Success Criteria

- [ ] New step "6b" (or equivalent numbering consistent with the 5b precedent) inserted after
      the `POOL_HARNESSES` assignment (~L213) and before step 7 (derived paths, ~L215).
- [ ] `POOL_OWNER_MODE ∈ {"caller","ancestor"}` and `POOL_LANE_PIN ∈ {"", "<digits>"}` set on
      every `pool_config_init` call (function is re-runnable — no init guard, per the header
      comment; both assignments must execute unconditionally).
- [ ] `ABPOOL_LANE` validated with `[[ =~ ^[1-9][0-9]*$ ]]`; failure ⇒
      `pool_die "agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw value>'"`
      (severity precedent: `_pool_config_require_uint` ~L74–75 and the port_range check ~L192).
- [ ] Later code reads the globals, NEVER `ABPOOL_OWNER`/`ABPOOL_LANE` again (freeze at init).
- [ ] Env-var table comment (L112–L131) gains both rows:
      `ABPOOL_OWNER  (unset = ancestor-mode)  POOL_OWNER_MODE  mode (any non-empty value → caller)`
      `ABPOOL_LANE   (unset = auto-assign)    POOL_LANE_PIN    positive-uint-or-empty (die on malformed)`
- [ ] No pre-existing `ABPOOL_OWNER`/`ABPOOL_LANE` references conflict (verified: zero exist in
      lib/ bin/ test/ today — `test/validate.sh`'s `ABPOOL_*` names are the test framework's own
      vars, unrelated; do not touch them).
- [ ] Static checks clean; no behavioral change with env vars unset.

## All Needed Context

### Documentation & References

```yaml
- url: (PRD, in-repo) PRD.md §2.11 / §2.12 / §2.20
  why: defines ABPOOL_OWNER=caller (any value), ABPOOL_LANE=<N> (positive integer, hard-error
       on malformed, validate before the flock section), and the byte-identical-default rule.
  critical: "any non-empty value" for ABPOOL_OWNER — do NOT run it through _pool_config_bool
       (bool would treat "0"/"false" as OFF, violating the spec).

- file: lib/pool.sh
  why: the single file to modify.
  pattern: step 6 (harnesses, ~L194–213) is the insertion neighbor; POOL_PROFILE_DIR raw-string
       capture (step 5b, ~L196–201 pre-sweep) is the idiom for ABPOOL_OWNER (plain
       `local x="${VAR:-}"` — no bool parsing); `POOL_HARNESSES="$harnesses"; declare -g POOL_HARNESSES`
       (~L213) is the exact declare -g pattern to copy for both new globals.
  gotcha: keep `declare -g` AFTER assignment exactly like every existing global; pool_die is
       `printf '%s\n' "$*" >&2; exit 1` (L29–32).

- file: plan/004_de5e94ac127c/P4M1T1S1/PRP.md
  why: the immediately-preceding sibling (citation renumber sweep) is landing concurrently and
       renumbers §-citations in lib/pool.sh (§2.16→§2.17 etc.). Line numbers above may shift by
       zero lines (the sweep is 1:1 token substitution, `wc -l` unchanged), but if you cite PRD
       sections in your comments, cite the NEW numbering (§2.11/§2.12/§2.20 per current PRD.md).
  gotcha: do NOT re-do or revert any citation changes; build on the swept file as you find it.

- file: test/validate.sh (L25–38)
  why: shows the framework's own ABPOOL_* test vars — names collide only superficially.
  pattern: unit selftests live in validate.sh; your behavioral tests are P4.M2.T1.S1's job,
       NOT this subtask. Do not add tests here.
```

### Current Codebase tree (relevant slice)

```bash
lib/pool.sh            # pool_config_init L132–L223: env table comment L112–131, pool_die L29–32,
                       # _pool_config_require_uint ~L68–77, step 6 harnesses ~L194–213, step 7 derived paths ~L215+
test/validate.sh       # test framework (untouched by this subtask)
bin/agent-browser-pool # entry point (untouched)
```

### Desired Codebase tree

```bash
lib/pool.sh            # MODIFIED ONLY: new step 6b + two comment-table rows
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: ABPOOL_OWNER must NOT use _pool_config_bool — PRD says ANY non-empty value means
#           caller mode. `ABPOOL_OWNER=false` is CALLER mode. Use the raw-string precedent:
#   if [[ -n "${ABPOOL_OWNER:-}" ]]; then mode="caller"; else mode="ancestor"; fi
# CRITICAL: ABPOOL_LANE follows the STRICT die precedent (require_uint), deliberately unlike the
#           TEST-MODE hook's malformed-PID warn+ignore (~L539–541) — PRD R2 mandates hard error.
# GOTCHA: the regex must be ^[1-9][0-9]*$ (no leading zero, no zero, no sign, no whitespace).
# GOTCHA: config-init runs on EVERY invocation BEFORE any flock ⇒ the die fires regardless of
#           verb (status/reap/release too) — that is intended and satisfies PRD §2.20.
# GOTCHA: pool_config_init is RE-RUNNABLE (no init guard, per header comment ~L120–124): the new
#           step must unconditionally overwrite both globals each call.
# GOTCHA: shellcheck must stay clean; both new globals are covered by the existing
#           `# shellcheck disable=SC2034` at ~L131 — verify, don't duplicate it.
# GOTCHA: local var masking (SC2155): declare locals separately from their assignments.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lib/pool.sh — env-var table comment (L112–L131)
  - ADD two rows mirroring existing column alignment exactly:
      ABPOOL_OWNER  (unset = ancestor ownership)  POOL_OWNER_MODE  mode ("caller" if non-empty)
      ABPOOL_LANE   (unset = auto-assign lane)   POOL_LANE_PIN    uint-or-empty (malformed → die)
  - PLACE: beside the AGENT_BROWSER_POOL_HARNESSES row (last of the env table, before the
    "# Derived (no env var):" block).
  - OPTIONALLY extend the "Errors" list in the same comment block with the ABPOOL_LANE case.

Task 2: MODIFY lib/pool.sh — new step in pool_config_init
  - INSERT after the POOL_HARNESSES assignment (~L213), before "# 7. Derived paths":
    # 6b. Caller-scoped owner mode + lane pin (PRD §2.11/§2.12, O10/O11) ...
    local owner_mode lane_pin
    if [[ -n "${ABPOOL_OWNER:-}" ]]; then owner_mode="caller"; else owner_mode="ancestor"; fi
    lane_pin="${ABPOOL_LANE:-}"
    if [[ -n "$lane_pin" ]] && [[ ! "$lane_pin" =~ ^[1-9][0-9]*$ ]]; then
        pool_die "agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '$lane_pin'"
    fi
    POOL_OWNER_MODE="$owner_mode"; declare -g POOL_OWNER_MODE
    POOL_LANE_PIN="$lane_pin"; declare -g POOL_LANE_PIN
  - FOLLOW pattern: step 5b (raw env capture) + step 6 (declare -g style + explanatory comment
    naming consumers: pool_owner_resolve reads POOL_OWNER_MODE; acquire path reads POOL_LANE_PIN).
  - NAMING: exactly POOL_OWNER_MODE / POOL_LANE_PIN (frozen contract names — downstream
    subtasks P4.M1.T3.S1, P4.M1.T4.S1/S2 and tests P4.M2.T1.S1 reference them verbatim).
  - PRESERVE: everything else byte-identical; do not renumber later steps' comments unless
    inserting "6b" style (keep "7." as-is).
```

### Integration Points

```yaml
CONSUMERS (later subtasks — do NOT implement here):
  - P4.M1.T3.S1: pool_owner_resolve branches on POOL_OWNER_MODE == "caller"
  - P4.M1.T4.S1/S2: acquire path uses non-empty POOL_LANE_PIN to pin lane N
DOCS:
  - User-facing env-table rows ride in P4.M1.T2.S2 (same work batch). This subtask updates the
    IN-CODE comment table only. Do not edit README.md / SKILL.md / references/.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n lib/pool.sh                      # expect: no output, rc 0
shellcheck -s bash lib/pool.sh           # expect: zero findings (verify none NEW vs HEAD)
```

### Level 2: Behavioral micro-checks (isolated, no browsers, timeout-bounded)

Per AGENTS.md: static-only is preferred; these are pure-shell checks with no Chrome, no daemon,
no flock — wrap in `timeout` anyway. Source lib/pool.sh in a subshell with redirected state:

```bash
timeout 20 bash -c '
  set -euo pipefail; source lib/pool.sh
  pool_config_init
  [[ "$POOL_OWNER_MODE" == "ancestor" && -z "$POOL_LANE_PIN" ]]   # default path
  ABPOOL_OWNER= pool_config_init; [[ "$POOL_OWNER_MODE" == "ancestor" ]]
  ABPOOL_OWNER=x pool_config_init; [[ "$POOL_OWNER_MODE" == "caller" ]]
  ABPOOL_OWNER=false pool_config_init; [[ "$POOL_OWNER_MODE" == "caller" ]]  # any value!
  ABPOOL_LANE=3 pool_config_init; [[ "$POOL_LANE_PIN" == "3" ]]
  ABPOOL_LANE=03 pool_config_init 2>/dev/null && exit 9            # must die
  ABPOOL_LANE=abc pool_config_init 2>/dev/null && exit 9           # must die
  ABPOOL_LANE=0 pool_config_init 2>/dev/null && exit 9             # must die
  ABPOOL_LANE=-2 pool_config_init 2>/dev/null && exit 9            # must die
  echo ALL-OK'
```

Also verify the die message includes the raw value (run `ABPOOL_LANE=abc bash -c 'source lib/pool.sh; pool_config_init'` and inspect stderr). Note: these inline checks must override state paths to a `mktemp -d` tree (export HOME and AGENT_BROWSER_POOL_STATE) so the operator's real state is never touched.

### Level 3–4: NOT IN SCOPE
No browser, no daemon, no flock, no test-suite runs for this subtask (tests are P4.M2.T1.S1).
Final check: `git diff lib/pool.sh` shows only the comment rows + the new step 6b block.

## Final Validation Checklist

- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero NEW findings.
- [ ] Default path byte-identical behavior (globals: `POOL_OWNER_MODE=ancestor`, `POOL_LANE_PIN=""`).
- [ ] `ABPOOL_OWNER` any-non-empty → caller (incl. "false", "0"); empty/unset → ancestor.
- [ ] `ABPOOL_LANE` validates strictly; malformed → pool_die with raw value, pre-flock, any verb.
- [ ] Both globals re-set on every (re-runnable) call; declare -g pattern matches POOL_HARNESSES.
- [ ] Env table comment updated; no user-facing docs touched (deferred to P4.M1.T2.S2).
- [ ] No conflicts with the concurrent P4.M1.T1.S1 citation sweep (new comments cite NEW numbering).
- [ ] Zero orphan processes / temp dirs left (all checks were static or timeout-bounded subshells).

## Anti-Patterns to Avoid

- ❌ Do NOT use `_pool_config_bool` for ABPOOL_OWNER (any non-empty value = caller).
- ❌ Do NOT warn-and-ignore malformed ABPOOL_LANE (that's the TEST-MODE hook's policy, not this one).
- ❌ Do NOT read ABPOOL_OWNER/ABPOOL_LANE anywhere outside this step (freeze into globals).
- ❌ Do NOT implement consumer logic (owner resolve / pin acquire) — those are T3/T4.
- ❌ Do NOT add tests to validate.sh — P4.M2.T1.S1 owns them.
- ❌ Do NOT launch Chrome, daemons, or the real test suite during this subtask.

**Confidence Score: 9/10** — single-file, fully-specified insertion with exact idioms and
line anchors; the only residual risk is line drift from the concurrent citation sweep (zero
net lines, mitigated by anchoring on content not line numbers).