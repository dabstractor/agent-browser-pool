# PRP — P1.M2.T3.S1: Rewrite the AGENT_BROWSER_POOL_HARNESSES help lines + help-vs-code contract case R8 (BUG-005)

---

## Goal

**Feature Goal**: Eliminate **BUG-005** — the built-in `help` text for
`AGENT_BROWSER_POOL_HARNESSES` claims the variable APPENDS extra harness names to
`pi/claude/codex/agy`, but the code (`pool_config_init`) **REPLACES** the entire set
whenever the variable is set (empty/unset → default), and the actual default has **five**
members including `antigravity`. A user following the current help would silently
disable every default harness's driving commands. This is a **TEXT-ONLY fix**: the two
`printf` lines inside `pool_admin_help` are rewritten to state replace semantics and the
full 5-item default. `pool_config_init` is **NOT touched** (code already matches PRD §2.11,
README.md, and .agents/skills/agent-browser-pool/references/configuration.md).

**Deliverable** (two artifacts, both small):
1. **`lib/pool.sh`** — the two `printf` lines inside `pool_admin_help` for
   `AGENT_BROWSER_POOL_HARNESSES` (currently at lines ~5205-5206, up from 4879-4880 cited
   in the PRD — the file has drifted from sibling subtasks; LOCATE BY GREP, not by number):
   ```bash
   grep -n "AGENT_BROWSER_POOL_HARNESSES    extra" lib/pool.sh
   ```
   Replace the two lines:
   ```bash
   # OLD (wrong — replace semantics, and omits antigravity):
   printf '  AGENT_BROWSER_POOL_HARNESSES    extra recognized harness command names\n'
   printf '                                  (comma-separated; appended to pi/claude/codex/agy)\n'
   # NEW (correct — replace semantics, full 5-item default):
   printf '  AGENT_BROWSER_POOL_HARNESSES    recognized harness command names\n'
   printf '                                  (comma-separated; replaces the default pi,claude,codex,agy,antigravity; empty/unset -> default)\n'
   ```
   Keep the exact two-line layout and column alignment: the env-var column is
   `printf '  %-33s…'`-style fixed width — every other entry pads the var name to column 38
   (`  AGENT_BROWSER_POOL_STATE        state dir…`); continuation lines are indented with
   34 spaces so descriptions align (`printf '                                  …'`). Count the
   indentation spaces from a sibling continuation line (e.g. the ABPOOL_LANE block two
   lines up) and match it exactly.
   - `replaces` must appear (case-insensitive OK for the probe).
   - The default list cited must be exactly `pi,claude,codex,agy,antigravity`.
   - Do NOT introduce the word `appended`/`append` anywhere in the new lines.
   - The second line is long (~100 chars) — that is fine; sibling lines (e.g.
     `AGENT_CHROME_EPHEMERAL_ROOT`) already run long. Do NOT wrap to three lines (P1.M3.T2.S2's
     skill-doc sweep greps a two-line shape).
2. **`test/bootrace.sh`** — add case **R8** `r8_bug005_help_harnesses_contract` and register
   it in `_br_run_suite`'s HARDCODED case list (the `for fn in …` at ~line 578) after
   `r7_bug004_doctor_fresh_install` (R7 is being added in parallel by P1.M2.T2.S1 — its PRP
   adds `r7_bug004_doctor_fresh_install` after `r6_bug003_release_corrupt_lease`; if R7 has
   NOT landed yet, add R8 directly after `r6_bug003_release_corrupt_lease` — do NOT add R7
   yourself). Suite goes N → N+1 cases.

**Success Definition**:
- TDD red→green: before the edit, `r8_bug005_help_harnesses_contract` FAILS (help contains
  `appended`, lacks `antigravity`/`replaces`); after the edit it PASSES.
- `agent-browser-pool help` output for the variable contains `antigravity` and `replaces`,
  does NOT contain `appended`, and the default list it cites equals the ACTUAL default set
  (cross-checked by sourcing `lib/pool.sh` with the var unset).
- `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh test/bootrace.sh` clean (no NEW
  findings vs HEAD).
- `bash test/bootrace.sh` → all cases pass, 0 failed, zero orphan processes.

## Why

- The built-in `help` is the first place users look; it currently instructs them to
  misconfigure the pool in a way that breaks every default harness's ancestor check
  (`pool_owner_resolve` walks ppid and matches `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]`
  — with `AGENT_BROWSER_POOL_HARNESSES=myagent`, `pi` is no longer recognized).
- PRD §2.11 defines the variable as THE recognized set; code matches; help does not.
  README.md:320 and .agents/skills/agent-browser-pool/references/configuration.md:28 already
  document replace semantics correctly — only the help is wrong.
- Downstream: **P1.M3.T2.S2** (skill-doc consistency sweep) will verify docs against this
  NEW help text — getting the exact wording landed here unblocks it.

## What

User-visible behavior: `agent-browser-pool help` now truthfully documents
`AGENT_BROWSER_POOL_HARNESSES` — comma-separated recognized harness command names that
REPLACE the default `pi,claude,codex,agy,antigravity` (empty/unset → default). No code
behavior changes at all.

### Success Criteria

- [ ] Help two-line entry states replace semantics + 5-item default; alignment matches siblings.
- [ ] R8 contract probe in test/bootrace.sh, registered in the runner list; red before, green after.
- [ ] `pool_config_init`, README.md, configuration.md UNCHANGED by this subtask.

## All Needed Context

### Context Completeness Check

If someone knew nothing about this codebase: they get the exact wrong lines, the exact
replacement text, the grep to locate them despite line drift, the alignment rule, the R8
test recipe (below, near-copy-paste), and the runner registration step. No further
codebase knowledge required.

### Documentation & References

```yaml
- file: lib/pool.sh (pool_config_init, "step 6. Recognized harnesses", ~lines 207-217)
  why: GROUND TRUTH for semantics — do not modify
  pattern: harnesses_raw="${AGENT_BROWSER_POOL_HARNESSES:-pi,claude,codex,agy,antigravity}";
           lowercased, tr -s ','; strip lead/trail commas; [[ -n ]] || default → REPLACE, empty→default
  gotcha: exact default string 'pi,claude,codex,agy,antigravity' — the help text must cite it verbatim

- file: lib/pool.sh (pool_admin_help, Configuration block, currently ~5190-5212)
  why: the two printf lines to rewrite; also the column-alignment reference
  pattern: env-var names padded to start descriptions at a fixed column; continuation
           printf lines are 34-space indented
  gotcha: line numbers in the PRD (4879-4880) are STALE — sibling subtasks have shifted
          the file; locate via grep -n "AGENT_BROWSER_POOL_HARNESSES    extra" lib/pool.sh

- file: README.md:320 and .agents/skills/agent-browser-pool/references/configuration.md:28
  why: already-correct replace-semantics documentation — the wording north star; DO NOT EDIT

- file: test/bootrace.sh
  why: harness for R8 — single-setup runner, hermetic sandbox, timeout-wrapped calls
  pattern: copy r6/r5 case shape: local vars, _fail "... R8: ..." guards, timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" ..., || rc=$?, cleanup with || true
  gotcha: bodies run in the MAIN shell (no ( … ) subshells — EXIT-trap hazard, AGENTS.md §4);
          register the new fn in _br_run_suite's hardcoded for-list or it never runs

- docfile: architecture/fix_design.md §5 and architecture/system_context.md §9
  why: changeset design context for the BUG-005 fix
```

### Current Codebase tree (relevant excerpt)

```bash
lib/pool.sh              # pool_config_init (~207-217, ground truth), pool_admin_help (~5190-5212, TARGET)
test/bootrace.sh         # 9-case (post-R7) single-setup suite; add r8_… here
README.md                # :320 already correct — no change
.agents/skills/agent-browser-pool/references/configuration.md  # :28 already correct — no change
```

### Desired Codebase tree with files to be added

```bash
# NO new files. Two modified files only:
lib/pool.sh        # 2 printf lines rewritten inside pool_admin_help
test/bootrace.sh   # + r8_bug005_help_harnesses_contract + runner registration
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: lib/pool.sh runs under `set -euo pipefail`. pool_admin_help body is printf-only
#   (always rc 0) + `return 0` — keep it that way; no command substitution, no [[ ]] bare.
# CRITICAL: never `local x="$(…)"` (SC2155) in the new test case — declare then assign
#   (copy r6's style: `local rc=0 help=…` literals only; captures via `help="$(…)"` after declare).
# CRITICAL: run bodies in the MAIN shell (`if r8_…; then`) — never in ( … ) subshells
#   (AGENTS.md EXIT-trap-in-subshell hazard deletes shared state mid-suite).
# CRITICAL: R8 spawns NO processes except the bounded `timeout 30 agent-browser-pool help`
#   call — keep it that way (help is printf-only; nothing to reap beyond the timeout).
# GOTCHA: subshell probe sourcing lib/pool.sh needs env redirects (HOME/state/ephemeral)
#   inherited from the suite sandbox so pool_config_init doesn't touch operator state —
#   the case already runs inside _bootrace_setup's redirected env; just `env -u AGENT_BROWSER_POOL_HARNESSES`.
# GOTCHA: `source lib/pool.sh` in a subshell must NOT execute a verb — pool.sh only defines
#   functions at source time (verified: bottom dispatch is under `abpool_main "$@"`-style
#   guard / invoked only by bin/agent-browser-pool). Source, call pool_config_init, echo.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: WRITE R8 FIRST (TDD red)
  - FILE: test/bootrace.sh — add r8_bug005_help_harnesses_contract after the last r-case's
    closing brace (post-R7: after r7_…; if R7 absent, after r6_bug003_release_corrupt_lease),
    before _br_run_suite. Register in _br_run_suite's for-list.
  - CASE RECIPE (adapt names/idioms to the file's existing style):
    r8_bug005_help_harnesses_contract() {
        local rc=0 help= actual=""
        # (a) help text contract — bounded, hermetic (help only printfs; needs no fixtures
        #     beyond the suite env, but redirect via the pool binary anyway)
        help="$(timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" help 2>/dev/null || true)"
        grep -qi 'antigravity' <<<"$help" || { _fail "R8: help omits antigravity" || rc=1; }
        grep -qi 'replaces'    <<<"$help" || { _fail "R8: help lacks 'replaces'" || rc=1; }
        grep -qi 'appended'    <<<"$help" && { _fail "R8: help still says 'appended'" || rc=1; }
        # (b) help-vs-code: default list cited in help == actual default (PRD h3.4 steps 1-3)
        actual="$(cd "$ABPOOL_REPO" && env -u AGENT_BROWSER_POOL_HARNESSES bash -c \
            'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
        [[ "$actual" == "pi,claude,codex,agy,antigravity" ]] \
            || { _fail "R8: actual default is [$actual]" || rc=1; }
        grep -qi 'pi,claude,codex,agy,antigravity' <<<"$help" \
            || { _fail "R8: help default list != actual default ($actual)" || rc=1; }
        # (c) replace-semantics behavior check (mirrors PRD repro step 2-3):
        local withovr=""
        withovr="$(cd "$ABPOOL_REPO" && AGENT_BROWSER_POOL_HARNESSES=myagent bash -c \
            'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
        [[ "$withovr" == "myagent" ]] \
            || { _fail "R8: override produced [$withovr], expected myagent (replace)" || rc=1; }
        return "$rc"
    }
    # GOTCHA: `grep -qi … && { _fail … }` — under set -e a failed grep in a && chain is fine,
    # but a bare failing grep statement ABORTS: keep every grep in || / && compound context
    # exactly as written. If shellcheck flags the `&& {` negative form, use
    #   if grep -qi appended <<<"$help"; then _fail "…" || rc=1; fi   (preferred — clearest).
  - RUNNER: append r8_bug005_help_harnesses_contract to the for-list in _br_run_suite.
  - VERIFY RED: bash test/bootrace.sh → only r8 FAILS ('help omits antigravity', 'lacks replaces',
    'still says appended'); all other cases pass.

Task 2: FIX THE HELP LINES (green)
  - FILE: lib/pool.sh, pool_admin_help. Locate:
      grep -n "AGENT_BROWSER_POOL_HARNESSES    extra" lib/pool.sh
  - REPLACE the two printf lines with (adjust continuation indent to match siblings exactly):
      printf '  AGENT_BROWSER_POOL_HARNESSES    recognized harness command names\n'
      printf '                                  (comma-separated; replaces the default pi,claude,codex,agy,antigravity; empty/unset -> default)\n'
  - DO NOT touch pool_config_init, README.md, configuration.md, or any other help line.
  - P1.M3.T2.S2 greps this text — the substring 'replaces the default pi,claude,codex,agy,antigravity'
    must survive verbatim into the landed line.

Task 3: VALIDATE
  - bash -n lib/pool.sh; shellcheck -s bash lib/pool.sh; shellcheck -s bash test/bootrace.sh
    (no NEW findings vs HEAD)
  - bash test/bootrace.sh → all cases PASS (r8 green), 0 failed
  - pgrep -af 'sleep|fake|agent-browser|chrome' → no orphans from your run
```

### Integration Points

```yaml
CODE: none — no logic changes anywhere.
DOWNSTREAM: P1.M3.T2.S2 verifies skill docs against the new help wording
  ('replaces the default pi,claude,codex,agy,antigravity').
DOCS: none — README.md:320 and references/configuration.md:28 already correct; the help IS
  the user-facing doc being fixed (Mode A by construction).
```

## Validation Loop

### Level 1: Syntax & Style
```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh
shellcheck -s bash lib/pool.sh
shellcheck -s bash test/bootrace.sh
# Expected: clean / no NEW findings vs HEAD
```

### Level 2: TDD contract case
```bash
bash test/bootrace.sh
# RED before Task 2 (only r8 fails), GREEN after: 'N passed, 0 failed'
```

### Level 3: Direct manual cross-check (hermetic, bounded)
```bash
timeout 30 bash bin/agent-browser-pool help | grep -A1 AGENT_BROWSER_POOL_HARNESSES
# Expect the new two lines; NOT 'appended'
T=$(mktemp -d); HOME="$T" bash -c 'source lib/pool.sh; pool_config_init; echo "$POOL_HARNESSES"'
# Expect: pi,claude,codex,agy,antigravity
rm -rf -- "$T"
```

## Final Validation Checklist
- [ ] Help lines state replace semantics + full 5-item default, alignment intact
- [ ] r8 registered in _br_run_suite; suite fully green; zero orphans (`pgrep -af` sweep)
- [ ] pool_config_init / README.md / configuration.md untouched (`git diff --stat` = 2 files)
- [ ] bash -n + shellcheck clean (no new findings)

## Anti-Patterns to Avoid
- ❌ Do NOT "fix" pool_config_init to match the old (wrong) help — code is the ground truth.
- ❌ Do NOT wrap the help entry to 3 lines or reflow the whole Configuration block.
- ❌ Do NOT run the real test suite against operator state — only the hermetic bootrace harness.
- ❌ Do NOT add R7 (parallel sibling owns it); only insert R8 adjacent to wherever the last r-case sits.

**Confidence Score: 9/10** — text-only fix, exact replacement text given, drift-proof locating via grep, near-copy-paste test recipe; residual risk is only line drift from the parallel R7 work, handled by grep-based location.