# PRP — P2.M1.T1.S2: Remove POOL_DISABLE passthrough + change no-pi-ancestor from passthrough to fail-fast in pool_wrapper_main

**Project**: agent-browser-pool (bash)
**Work item**: P2.M1.T1.S2
**Dependency**: Consumes the output of P2.M1.T1.S1 (which removed `POOL_DISABLE` from
`pool_config_init`). S2 removes the **consumer** (the passthrough branch + its stale comments).
S1 and S2 touch disjoint regions of `lib/pool.sh` (config_init ~96-210 vs wrapper ~3577+), so the
edits compose regardless of apply order; only line *numbers* shift (S1 deletes 3 lines above the
wrapper). Every edit below is specified by **exact text**, so it is robust to that shift.
**Full research notes**: `plan/002_97982899bef6/P2M1T1S2/research/notes.md`

---

## Goal

**Feature Goal**: Remove the obsolete `POOL_DISABLE==1 → passthrough` branch (step b) from
`pool_wrapper_main`, and change the no-pi-ancestor branch (step d) from silent `exec` passthrough
to an actionable `pool_die` fail-fast. Align all of `pool_wrapper_main`'s header comments
(CONSUMES list, config-freezes note, exit-count/passthrough GOTCHAs) so they no longer mention
`POOL_DISABLE` or the deleted/disabled steps.

**Deliverable**: A modified `lib/pool.sh` in which:
1. `pool_wrapper_main` has **no** `POOL_DISABLE` reference anywhere in its header or body.
2. A driving command issued with **no pi ancestor** produces `pool_die` (exit 1) with a two-part
   actionable message, instead of silently `exec`'ing the real binary.
3. The only remaining `POOL_DISABLE` reference in `lib/pool.sh` is the `pool_admin_help` printf
   at ~line 4606 — owned by P2.M1.T3.S1 (NOT this item).
4. `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` both remain clean.

**Success Definition**:
- `shellcheck -s bash lib/pool.sh` exits 0 with zero output (unchanged from the clean baseline).
- `bash -n lib/pool.sh` exits 0.
- `grep -n 'POOL_DISABLE' lib/pool.sh` shows exactly ONE hit (the `pool_admin_help` line ~4606),
  and **zero** hits anywhere in the `pool_wrapper_main` region (lines ~3570-3745).
- `grep -n 'safety valve' lib/pool.sh` returns nothing.
- An isolated, `timeout`-bounded micro-check (sources the lib, forces no-owner via the test-hook
  `AGENT_BROWSER_POOL_OWNER_PID=0`, calls `pool_wrapper_main open https://example.com`) exits **1**
  and prints BOTH sentences of the fail-fast message — and crucially **never boots Chrome**.
- A second micro-check with `AGENT_BROWSER_POOL_DISABLE=1` exported STILL fails fast (exit 1),
  proving the old safety valve is truly gone (no passthrough).
- Meta commands (`skills`, `--version`) at step c still pass through unchanged — step c is untouched.

---

## Why

- **Business value**: PRD §4 decision O5 (No PATH shadowing / pivot) removes the cutover danger
  and the `AGENT_BROWSER_POOL_DISABLE` safety valve. In the new explicit-invocation model
  (`agent-browser-pool <verb>`) the real `agent-browser` is never intercepted, so "disable
  pooling" is meaningless — there is nothing to bypass. The `POOL_DISABLE==1 → exec` branch
  (step b) is therefore dead and misleading. PRD §2.4 step 1 mandates the no-pi-ancestor change:
  *"No pi ancestor → DRIVING fails fast ('requires a pi ancestor; for raw browser use call
  `agent-browser` directly')"*. The old silent passthrough (step d) is the behavior being removed.
- **Scope cohesion**: S1 removed the **source** knob (config_init no longer sets `POOL_DISABLE`).
  This item removes the **consumer**. Splitting source/consumer makes each edit surgical and
  independently verifiable, and matches the dependency graph (S1 → S2 → S3 preflight → M2 entry).
- **Who it helps**: Agents get a clear, actionable error when they invoke a driving command
  outside a `pi` owner (instead of a confusing silent run that breaks lane isolation invariants);
  future maintainers get a wrapper with no dead `POOL_DISABLE` branch and accurate comments.

---

## What

**User-visible behavior**: A caller that issues a **driving** command (`open`, `click`, `type`,
`snapshot`, …) with no `pi` process in its ancestry now gets:

```
agent-browser-pool: driving commands require a pi ancestor (owning pi process). For raw browser use without pooling, call 'agent-browser' directly.
```
on stderr and a non-zero exit — instead of the real binary running silently. `AGENT_BROWSER_POOL_DISABLE`
is now a complete no-op (it was already inert after S1; step b is now physically gone).

**Unchanged (explicitly preserved)**:
- Step c (`pool_dispatch_classify` → meta → `exec` passthrough) is byte-for-byte unchanged. Meta
  commands (`skills get core`, `--version`, `session list`, bare flags) still pass through to the
  real binary — they need no lane (PRD §2.4 step 0; §2.15).
- Steps a, e→g, h, i, j, k (config/state, find-or-acquire, ensure-connected, normalize,
  session-force, exec) are unchanged.
- All other functions in `lib/pool.sh` (per the Function Reuse Map in gap_analysis) are unchanged.

### Success Criteria

- [ ] Step b block (the `# --- b. safety valve` comment + the `if [[ "${POOL_DISABLE:-0}" == "1" ]]`
      block + its trailing blank line) is deleted entirely.
- [ ] Step d body changed from `_pool_log ...; exec "$POOL_REAL_BIN" "$@"` to the 2-arg `pool_die`
      call specified below (verbatim message text).
- [ ] Step d header comment says `fail-fast` (not `passthrough`); its sub-comment no longer says
      "human in terminal".
- [ ] All 3 `POOL_DISABLE` references in the header comments (CONSUMES list, config-freezes note,
      the standalone `GOTCHA — POOL_DISABLE ...`) are gone.
- [ ] The two now-stale GOTCHAs ("four exits (b/c/d/k)" and "passthrough exec (b/c/d)") are
      corrected to reflect that only step c remains a passthrough exec.
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] The two isolated micro-checks (no-owner fail-fast; DISABLE-ignored) behave as specified.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the exact file, exact old/new text for every edit, the `pool_die` join
semantics, the deterministic owner-override mechanism for validation, the dispatch-classification
proof that `open` is driving, the test-impact map (expected failures owned by later subtasks), and
safe validation recipes are all specified below.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: lib/pool.sh
  why: The ONLY file modified. pool_wrapper_main header comments ~lines 3577-3597; body ~3598-3745.
       The exact target text for every edit is enumerated in "Implementation Tasks" below.
  pattern: >
    pool_wrapper_main is the driving-command router. Steps: a config+state init; b (DELETED here)
    was the POOL_DISABLE safety valve; c dispatch classify (meta→exec passthrough, UNCHANGED);
    d owner resolve (CHANGED here: no pi ancestor → pool_die); e→g find-or-acquire; h ensure
    connected; i normalize; j session force; k exec. All exits are terminal (exec or pool_die).
  gotcha: >
    pool_die (lib/pool.sh:30) does `printf '%s\n' "$*" >&2; exit 1`. "$*" joins ALL args with a
    space into ONE line. The required 2-arg call therefore prints a single stderr line (both
    sentences concatenated). Do NOT add an extra newline or change the arg split — it is verbatim
    from gap_analysis §1b / item LOGIC step (b).
  gotcha: >
    Line numbers below ~210 shift UP by 3 after S1 is applied (S1 deletes 3 lines in config_init).
    The edit tool matches oldText against the CURRENT file text, so text-based edits are robust.
    Do NOT anchor on line numbers — anchor on the exact text blocks given.

- file: plan/002_97982899bef6/P2M1T1S1/PRP.md
  why: The CONTRACT for what S1 produces. S1 removes AGENT_BROWSER_POOL_DISABLE from pool_config_init
       (comment row, `local` token, assignment, global). After S1, POOL_DISABLE is unset, so the
       step-b `[[ "${POOL_DISABLE:-0}" == "1" ]]` is provably inert (always "0"). S2 then deletes
       that dead branch with confidence.
  critical: >
    S1 does NOT touch pool_wrapper_main. The step-b block's text is identical before/after S1.
    No merge conflict possible (disjoint regions).

- file: plan/002_97982899bef6/architecture/gap_analysis.md
  why: Authoritative change spec. §1b enumerates Change 1 (delete step b), Change 2 (step d →
       pool_die, exact message), Change 4 (update POOL_DISABLE comments). (Change 3 = preflight
       check is a SEPARATE later item, P2.M1.T2.S1 — DO NOT add it here.)
  section: "1b. pool_wrapper_main (lines 3601-3740)"

- prd: PRD.md §2.4 (Request lifecycle — "No pi ancestor → DRIVING fails fast"), §2.11 (Discovery &
       configuration — "AGENT_BROWSER_POOL_DISABLE … are gone"), §2.17 (Install — "Removed: the
       AGENT_BROWSER_POOL_DISABLE safety valve"), §2.13 (Safety & identity — isolation by owner
       triple), §4 decision O5.
  why: Mandates the fail-fast + the removal. §2.4 step 1 quote is the verbatim message source.

- file: plan/002_97982899bef6/P2M1T1S2/research/notes.md
  why: Full line-by-line table; pool_die join semantics; dispatch-classify proof that `open` is
       driving; pool_owner_resolve TEST MODE (`AGENT_BROWSER_POOL_OWNER_PID=0` → deterministic
       no-owner for the micro-check); test-impact map; out-of-scope owner table.
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh            # ~4613 lines, 61 functions, PURE lib (no top-level execution)
                       # pool_wrapper_main: header comments ~3577-3597, body ~3598-3745
bin/                   # entry points (NOT touched here — P2.M2.T1.S1 rewires the `*)` arm later)
test/                  # test harness (NOT touched here)
plan/002_97982899bef6/architecture/gap_analysis.md   # change spec (read-only)
plan/002_97982899bef6/P2M1T1S1/PRP.md                # S1 contract (read-only)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONLY lib/pool.sh is modified (edits within pool_wrapper_main header + body).
lib/pool.sh            # pool_wrapper_main: no POOL_DISABLE; no-pi-ancestor driving → pool_die.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (pool_die join semantics, lib/pool.sh:30):
#   pool_die() { printf '%s\n' "$*" >&2; exit 1; }
#   "$*" joins args with a SPACE into ONE line. The required 2-arg call prints a single line:
#     "agent-browser-pool: driving commands require a pi ancestor (owning pi process). For raw
#      browser use without pooling, call 'agent-browser' directly."
#   Use the bash line-continuation `\` to keep the two string literals on two source lines
#   (matches gap_analysis). Do NOT collapse into one literal, do NOT add `\n`.

# CRITICAL (line-number drift after S1): S1 deletes 3 lines in pool_config_init (above the
#   wrapper), so every wrapper line moves UP by 3 once S1 is applied. ALL edits below are given
#   as exact text blocks — match on TEXT, not line numbers. If you must cite a number, cite the
#   PRE-S1 number and note the +3 shift.

# CRITICAL (set -euo pipefail): callers run under `set -euo pipefail`, but lib/pool.sh itself
#   does not `set -e`. The edits are a deletion + a body swap; the new `pool_die` call is the
#   terminal exit (exit 1). The `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]` test stays errexit-safe
#   (it's a `[[ ]]` condition). No new rc-sensitive bare commands are introduced.

# CRITICAL (do NOT add the preflight check here): gap_analysis §1b "Change 3" (a new
#   _pool_preflight_real_bin function) is item P2.M1.T2.S1 — a SEPARATE later subtask. This item
#   is ONLY Change 1 (delete step b), Change 2 (step d → pool_die), Change 4 (comments). Adding
#   the preflight here would collide with P2.M1.T2.S1.

# CRITICAL (step c meta-passthrough must stay): pool_dispatch_classify + the meta→exec branch
#   (step c) are UNCHANGED. Meta commands (skills/--version/session list) legitimately need no
#   lane. Deleting step b and re-routing step d does NOT affect step c.

# CRITICAL (transient EXPECTED test failure — do NOT chase it): after S1+S2,
#   test/validate.sh's selftest_config_disable (lines ~346-357, asserts POOL_DISABLE=1) WILL FAIL.
#   It is owned by P2.M5.T1.S1 and is EXPECTED to be removed there. The S2 validation gates
#   below intentionally AVOID running validate.sh. (transparency.sh has NO no-pi-ancestor test —
#   confirmed by grep — so the fail-fast change breaks zero transparency assertions.)

# CRITICAL (do not boot Chrome / do not run the suite against the shared sandbox during this
#   lib edit — AGENTS.md §1): validate with `bash -n`, `shellcheck`, and the isolated
#   timeout-bounded micro-checks only. The micro-check dies at step d (pool_die) BEFORE any lane
#   lookup / port probe / Chrome launch.

# SAFE TO SOURCE: lib/pool.sh has NO top-level executable code. `source lib/pool.sh` only defines
#   functions. The fail-fast micro-check force-sets AGENT_BROWSER_POOL_OWNER_PID=0 (pool_owner_resolve
#   TEST MODE) so it never walks the real ppid chain and never depends on whether the test shell
#   is itself under a `pi` process.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This is a control-flow + comment edit in one bash function. The "model"
is `pool_wrapper_main`'s exit taxonomy: after this change the terminal exits are `exec` (step c
meta passthrough; step k driving) and `pool_die` (step d no-pi-ancestor; plus the pre-existing
e/h/j error branches). No lease/session/JSON shape changes.

### Implementation Tasks (ordered by dependencies)

> All edits are in `lib/pool.sh`, inside `pool_wrapper_main`'s header-comment block (~3577-3597)
> and body (~3598-3631). They are mutually disjoint, so they MAY be applied in a SINGLE `edit`
> call with multiple `edits[]` entries (the tool matches each `oldText` against the original
> file independently). Order in the array does not matter. Each `oldText` is unique.

```yaml
Task 1: EDIT lib/pool.sh — delete the standalone POOL_DISABLE GOTCHA (header comment)
  - oldText (2 lines, delete both):
      # GOTCHA — POOL_DISABLE is read AFTER pool_config_init (which freezes it @176). Step b reads
      #   the FROZEN global, not the raw env var.
      # GOTCHA — pool_boot_lane rc 1 ⇒ lane DROPPED ⇒ pool_die (no in-place retry; re-entering
    - newText:
      # GOTCHA — pool_boot_lane rc 1 ⇒ lane DROPPED ⇒ pool_die (no in-place retry; re-entering
  - WHY: the leading line of the NEXT gotcha is included only to make oldText unique + remove the
    right number of lines cleanly; it is preserved verbatim in newText.
  - BUCKET: required (item step d — "comments referencing POOL_DISABLE").

Task 2: EDIT lib/pool.sh — remove POOL_DISABLE from the CONSUMES list (header comment)
  - oldText:
      # CONSUMES: POOL_DISABLE, POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS,
    - newText:
      # CONSUMES: POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS,
  - BUCKET: required (item step d).

Task 3: EDIT lib/pool.sh — remove POOL_DISABLE from the step-a "config freezes" comment
  - oldText:
      # config freezes POOL_DISABLE, POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.
    - newText:
      # config freezes POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.
  - BUCKET: required (item step d). (After S1, config_init no longer freezes POOL_DISABLE.)

Task 4: EDIT lib/pool.sh — DELETE the entire step-b block (safety valve) + its trailing blank line
  - oldText (the block PLUS the blank line after it, ending right before the step-c comment):
        # --- b. safety valve (PRD §2.17): POOL_DISABLE==1 → passthrough, no pooling ---
        # Read the FROZEN global (config_init just set it). ORIGINAL "$@" unchanged.
        if [[ "${POOL_DISABLE:-0}" == "1" ]]; then
            _pool_log "pool_wrapper_main: POOL_DISABLE=1 → passthrough"
            exec "$POOL_REAL_BIN" "$@"
        fi

    - newText:   (empty string — remove all of the above)
  - VERIFY after: the step-a block (`pool_config_init` / `pool_state_init`) is now immediately
    followed by a single blank line and then the `# --- c. dispatch` comment.
  - BUCKET: required (item step a — "DELETE step b entirely").
  - NOTE: do NOT renumber steps c/d/…/k to fill the "b" gap — the GOTCHA comments elsewhere
    reference "step c", "step h", "step k" by their current letters and would all need updating;
    leaving a missing step b is far less risky and is faithful to the contract (which refers to
    steps by their CURRENT letters). Step letters are the implementation's own subdivision, not
    the PRD §2.4 lifecycle numbers.

Task 5: EDIT lib/pool.sh — change step d (header comment + sub-comment + body) to fail-fast
  - oldText (one contiguous block):
        # --- d. owner resolution (step 1): no pi ancestor → passthrough --------------
        # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ human in terminal).
        pool_owner_resolve
        if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
            _pool_log "pool_wrapper_main: no pi ancestor → passthrough (human terminal)"
            exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — raw upstream tool for humans
        fi
    - newText:
        # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
        # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no pi ancestor).
        pool_owner_resolve
        if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
            pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
                     "For raw browser use without pooling, call 'agent-browser' directly."
        fi
  - BUCKET: required (item steps b + c).
  - GOTCHA: the `\` line-continuation + 8-space indent on the second string literal must be
    preserved (matches the project's existing multi-line call style; keeps shellcheck happy).

Task 6 (consequential hygiene, SAME function): EDIT the now-stale exit-count GOTCHA
  - oldText:
      # GOTCHA — TERMINAL: all four exits are exec (b/c/d/k) or pool_die. NO return on success.
    - newText:
      # GOTCHA — TERMINAL: exits are exec (c/k) or pool_die (d + error branches). NO return on success.
  - WHY (not optional in practice): step b is deleted and step d is no longer an exec, so "four
    exits (b/c/d/k)" is now factually wrong. Leaving it misleads the next maintainer. This comment
    lives in pool_wrapper_main's own header (which S2 owns), so correcting it is in-scope hygiene.
  - BUCKET: consequential comment fix (directly caused by Tasks 4+5).

Task 7 (consequential hygiene, SAME function): EDIT the now-stale passthrough-exec GOTCHA
  - oldText:
      # GOTCHA — passthrough exec (b/c/d) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:
    - newText:
      # GOTCHA — passthrough exec (c) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:
  - WHY: only step c remains a passthrough exec (b deleted; d is now pool_die). "b/c/d" is stale.
  - BUCKET: consequential comment fix (directly caused by Tasks 4+5).

Task 8: VERIFY — static gates (no execution of browsers/daemons)
  - RUN: bash -n lib/pool.sh                       # exit 0
  - RUN: shellcheck -s bash lib/pool.sh            # exit 0, zero output
  - RUN: the isolated micro-checks in "Validation Loop → Level 2".
```

### Implementation Patterns & Key Details

```bash
# The step-d region AFTER Task 5 should read EXACTLY:
#
#     # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
#     # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no pi ancestor).
#     pool_owner_resolve
#     if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
#         pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
#                  "For raw browser use without pooling, call 'agent-browser' directly."
#     fi
#
# The header-comment CONSUMES / config-freezes lines AFTER Tasks 2+3 must NOT contain the token
# "POOL_DISABLE" anywhere in the pool_wrapper_main region.
#
# The region BETWEEN step a and step c AFTER Task 4 must be exactly one blank line (the step-b
# block AND its trailing blank are removed; step a's own trailing blank remains).

# DO NOT:
#   - touch step c (pool_dispatch_classify + meta→exec) — it stays byte-identical.
#   - add a _pool_preflight_real_bin call or function — that is P2.M1.T2.S1.
#   - renumber the step letters (c→b, d→c, …) — see Task 4 NOTE.
#   - touch pool_admin_help's `printf '  AGENT_BROWSER_POOL_DISABLE ...'` (~line 4606) — P2.M1.T3.S1.
#   - run test/validate.sh or test/transparency.sh during this item (validate.sh has an EXPECTED
#     failure owned by P2.M5.T1.S1; transparency.sh boots real Chrome).
#   - boot Chrome or run the suite against the shared $HOME (AGENTS.md §1).
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no new env vars, no routes.
  - The ONLY integration surface is pool_wrapper_main's behavior contract:
      * driving command + no pi ancestor → exit 1 + actionable message (was: silent exec).
      * POOL_DISABLE → complete no-op (was: short-circuit passthrough at step b).
  - Downstream consumers that will reflect this LATER (NOT here):
      * bin/agent-browser-pool `*)` arm → pool_wrapper_main "$@"   (P2.M2.T1.S1)
      * test/transparency.sh invocations                              (P2.M5.T2.S1)
      * pool_admin_help text / configuration.md / SKILL.md / README.md (P2.M1.T3 / P2.M4 / P2.M6)
```

---

## Validation Loop

> Per AGENTS.md §1/§2: every command below is STATIC (`bash -n`, `shellcheck`) or an isolated,
> `timeout`-bounded micro-check that sources a pure library and dies at step d (pool_die) BEFORE
> any lane/port/Chrome work. No real Chrome, no daemons, no full test suite, no shared-$HOME writes.

### Level 1: Syntax & Style (run after the edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# Syntax — must exit 0
bash -n lib/pool.sh

# Lint — must exit 0 with ZERO output (matches the pre-change clean baseline)
shellcheck -s bash lib/pool.sh

# Expected: both exit 0; shellcheck prints nothing. If shellcheck flags the multi-line pool_die,
# check that the `\` line-continuation is present and the second line is indented (Task 5 newText).
```

### Level 2: Component Validation (isolated, timeout-bounded micro-checks)

```bash
cd /home/dustin/projects/agent-browser-pool

# --- (i) no-pi-ancestor DRIVING command → fail-fast (NOT passthrough, NOT Chrome boot) ---------
# AGENT_BROWSER_POOL_OWNER_PID=0 → pool_owner_resolve TEST MODE → POOL_OWNER_PID=0 deterministically
# (works even if this shell is under a real `pi`). Dies at step d before any lane lookup/Chrome.
# Note: single quotes are literal inside double quotes, so the grep -F pattern needs no escaping.
timeout 10 bash -c '
  export HOME="$(mktemp -d)"          # redirect state dir away from the operator's real $HOME
  export AGENT_BROWSER_POOL_OWNER_PID=0   # simulate "no pi ancestor"
  source "$1/lib/pool.sh"
  pool_wrapper_main open https://example.com
' _ "$(pwd)" >/dev/null 2>/tmp/s2_ff.txt
echo "exit=$?"                       # Expected: exit=1
if grep -Fq "driving commands require a pi ancestor (owning pi process)." /tmp/s2_ff.txt \
   && grep -Fq "For raw browser use without pooling, call 'agent-browser' directly." /tmp/s2_ff.txt; then
  echo "OK: fail-fast message present (both sentences)"
else
  echo "FAIL: message missing/incomplete — see /tmp/s2_ff.txt"
fi

# --- (ii) AGENT_BROWSER_POOL_DISABLE=1 is now IGNORED (old safety valve is gone) ---------------
# Same no-owner override; the DISABLE env var must NOT cause a passthrough. Still exit=1.
timeout 10 env AGENT_BROWSER_POOL_DISABLE=1 bash -c '
  export HOME="$(mktemp -d)"
  export AGENT_BROWSER_POOL_OWNER_PID=0
  source "$1/lib/pool.sh"
  pool_wrapper_main open https://example.com
' _ "$(pwd)" >/dev/null 2>/tmp/s2_nodisable.txt
echo "exit=$?"                         # Expected: exit=1 (NOT the real binary running)
if grep -Fq "driving commands require a pi ancestor" /tmp/s2_nodisable.txt; then
  echo "OK: DISABLE ignored — still fail-fast"
else
  echo "FAIL: DISABLE still short-circuits (step b not fully removed?)"
fi

# --- (iii) META command still passes through (step c unchanged) --------------------------------
# `--version` is META → step c exec's the REAL binary (NOT pool_die). This proves step c is intact.
# (Only assert the BEHAVIOR TYPE: it must NOT print the no-pi-ancestor message.)
timeout 10 bash -c '
  export HOME="$(mktemp -d)"
  export AGENT_BROWSER_POOL_OWNER_PID=0
  source "$1/lib/pool.sh"
  pool_wrapper_main --version
' _ "$(pwd)" >/tmp/s2_meta.txt 2>&1
if grep -Fq "driving commands require a pi ancestor" /tmp/s2_meta.txt; then
  echo "FAIL: meta command (--version) wrongly hit the no-pi-ancestor branch (step c broken?)"
else
  echo "OK: --version did not hit the fail-fast (meta passthrough intact)"
fi

# Cleanup (defensive): the mktemp -d dirs die with their bash -c shell; remove any stray tmp files.
rm -f /tmp/s2_ff.txt /tmp/s2_nodisable.txt /tmp/s2_meta.txt
```

Expected for all three: (i) exit=1 + both sentences; (ii) exit=1 + sentence; (iii) no fail-fast
sentence (meta passed through). If (i)/(ii) hang past ~1s, ABORT — that would mean execution
reached lane/Chrome logic (step g+), i.e. the override or the step-d change is wrong. Do not wait
for the `timeout 10`.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Confirm POOL_DISABLE is gone from pool_wrapper_main but REMAINS in pool_admin_help (later owner).
grep -n 'POOL_DISABLE' lib/pool.sh
# Expected: exactly ONE hit, in pool_admin_help (~line 4606, PRE-S1 numbering). ZERO hits in the
# pool_wrapper_main region (~3570-3745). If you see any hit at the old wrapper lines, an edit was
# missed.

# Confirm the safety-valve block + the old no-pi-ancestor passthrough log line are gone.
grep -n 'safety valve\|POOL_DISABLE=1 → passthrough\|no pi ancestor → passthrough (human terminal)' lib/pool.sh
# Expected: NO output (rc 1). Any hit ⇒ step b or the step-d body edit is incomplete.

# Confirm the new fail-fast message is present exactly once.
grep -n "driving commands require a pi ancestor (owning pi process)" lib/pool.sh
# Expected: exactly ONE hit (the pool_die first argument).

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command.
# (validate.sh selftest_config_disable is EXPECTED to fail post-S1+S2 and is fixed in P2.M5.T1.S1.)
```

### Level 4: Creative & Domain-Specific Validation

N/A — this item has no user-facing surface beyond the stderr message, no network, no DB, no
performance dimension. Levels 1-3 are complete and sufficient. The fail-fast message wording is
the only "creative" output and is pinned verbatim by PRD §2.4 step 1 / gap_analysis §1b.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] Level 2 micro-check (i): exit=1 and BOTH fail-fast sentences present on stderr.
- [ ] Level 2 micro-check (ii): with `AGENT_BROWSER_POOL_DISABLE=1`, still exit=1 (safety valve gone).
- [ ] Level 2 micro-check (iii): `--version` (meta) does NOT hit the fail-fast (step c intact).
- [ ] `grep -n POOL_DISABLE lib/pool.sh` shows exactly ONE hit (pool_admin_help ~4606) and ZERO in
      the pool_wrapper_main region.
- [ ] `grep -n 'safety valve' lib/pool.sh` returns nothing.

### Feature Validation

- [ ] Step b block (comment + `if POOL_DISABLE==1` + body + trailing blank) deleted entirely (Task 4).
- [ ] Step d body is the 2-arg `pool_die` call with the verbatim message (Task 5).
- [ ] Step d header comment says `fail-fast`; sub-comment no longer says "human in terminal".
- [ ] All 3 header POOL_DISABLE references removed (Tasks 1, 2, 3).
- [ ] The two stale GOTCHAs corrected: "four exits (b/c/d/k)"→"exits (c/k)"; "(b/c/d)"→"(c)" (Tasks 6, 7).
- [ ] Step c (dispatch classify + meta→exec) is byte-for-byte unchanged.
- [ ] No `_pool_preflight_real_bin` added (that is P2.M1.T2.S1).

### Code Quality Validation

- [ ] Only `lib/pool.sh` modified; no other file touched.
- [ ] The region between step a and step c is exactly one blank line.
- [ ] No step-letter renumbering (c/d/…/k keep their current letters).
- [ ] pool_admin_help (~4606), validate.sh, install.sh, configuration.md, SKILL.md, README.md all
      untouched (owned by P2.M1.T3.S1 / P2.M5.T1.S1 / P2.M3.T1.S1 / P2.M4 / P2.M6).

### Documentation & Deployment

- [ ] [Mode A] Header comments reflect the no-POOL_DISABLE + fail-fast reality (Tasks 1-3, 6-7).
- [ ] No external doc files change in THIS item (configuration.md is P2.M4.T2.S1; SKILL/README are
      P2.M4.T1.S1 / P2.M6.T1.S1).

---

## Anti-Patterns to Avoid

- ❌ Don't add `_pool_preflight_real_bin` or any real-binary existence check — that's P2.M1.T2.S1.
- ❌ Don't touch step c / `pool_dispatch_classify` / the meta→exec passthrough — meta commands still
  pass through (PRD §2.4 step 0, §2.15).
- ❌ Don't renumber the step letters to "fill" the deleted step b — it cascades into many stale
  references ("step h", "step k") and adds risk for no benefit.
- ❌ Don't touch `pool_admin_help`'s `AGENT_BROWSER_POOL_DISABLE` printf (~4606) — P2.M1.T3.S1.
- ❌ Don't run `test/validate.sh` to "verify" — `selftest_config_disable` is EXPECTED to fail
  post-S1+S2 (owned by P2.M5.T1.S1). Use the Level 2 micro-checks instead.
- ❌ Don't run `test/transparency.sh` or `install.sh`, and don't boot Chrome / touch the shared
  `$HOME` (AGENTS.md §1).
- ❌ Don't change the `pool_die` message wording or collapse its two string literals into one — it is
  pinned verbatim by PRD §2.4 step 1 / gap_analysis §1b; `"$*"` join already yields one stderr line.
- ❌ Don't leave the stale "four exits (b/c/d/k)" / "passthrough exec (b/c/d)" GOTCHAs — they become
  factually wrong after Tasks 4+5; fix them (Tasks 6+7) as part of leaving the header correct.
- ❌ Don't anchor edits on line numbers — S1 shifts the wrapper up by 3. Match on the exact text blocks.

---

## Confidence Score

**9/10** — one-pass success likelihood. The change is surgical (7 disjoint text edits in one
function), every `oldText`/`newText` is given verbatim, the `pool_die` join semantics are
documented, the deterministic owner-override makes the fail-fast micro-check environment-independent
and Chrome-free, the dispatch classification of `open` as driving is proven, and the test-impact +
out-of-scope boundaries are explicit (only validate.sh:selftest_config_disable is an expected
post-change failure, owned by P2.M5.T1.S1). The single residual risk is an implementer who skips the
two consequential comment fixes (Tasks 6+7) as "out of scope" — this PRP marks them explicitly as
in-scope hygiene caused by the change, so the result is not left with stale step-b/d references.
