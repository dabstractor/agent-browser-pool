# PRP — P1.M1.T1.S1: Anchor pgrep/pkill pattern in `pool_reap_orphan_dirs` + regression test for prefix collision

> **Bugfix context**: This subtask fixes **Issue 1 (Major — isolation violation)** from the
> QA report (`plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md` and
> `architecture/recon_issue1_reaper.md`). The orphan-dir reaper uses an **unanchored**
> `pgrep`/`pkill -f` substring match, so reaping orphan lane `3` also kills live lanes
> `30, 31, …, 39, 300, …` — every lane whose number *starts with* the orphan's.

---

## Goal

**Feature Goal**: Anchor the `pgrep`/`pkill -f` pattern in `pool_reap_orphan_dirs` to the lane-directory boundary so it matches **only** the exact orphan dir (followed by a space or end-of-line in `/proc/<pid>/cmdline`), eliminating the prefix-collision collateral kill of other lanes' live Chromes. Add a regression self-test that spawns two fake-Chrome processes on prefix-colliding lane numbers (3 and 30) and proves a reap of the orphan (lane 3) kills only lane 3.

**Deliverable**:
1. `lib/pool.sh` — the orphan-kill block in `pool_reap_orphan_dirs` (lines ~2898–2902) rewritten to use a single anchored `pat="user-data-dir=$dir( |$)"` variable, applied to all three `pgrep`/`pkill` calls.
2. `lib/pool.sh` — the inline comment above the block (~lines 2895–2897) updated to explain the anchoring (the old comment falsely claimed the full-path match already prevented cross-lane hits).
3. `test/validate.sh` — a new `selftest_reap_orphan_dirs_kills_only_target_lane` function, added alongside `selftest_reap_orphan_dirs_removes_and_skips` (line ~826). It is auto-picked-up by the single-setup `_run_selftest_suite` runner.
4. The function's **contract is unchanged**: echoes the orphan count to stdout, returns 0 always. Only the false-positive kills are eliminated.

**Success Definition**:
- `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean (matches the project gate).
- `grep -n 'user-data-dir=$dir' lib/pool.sh` returns **nothing** (the unanchored literal is gone); `grep -n 'pat="user-data-dir=$dir' lib/pool.sh` returns one match.
- `bash test/validate.sh` exits 0 with the new selftest passing.
- An isolated micro-check (the regression test itself, or a manual reproduction) confirms: with fake Chromes on lanes 3 and 30, reaping orphan lane 3 kills lane 3's process and **leaves lane 30's process alive**.
- Before the fix, the same scenario kills both (empirically reproduced during research — see `research/repro-anchored-pgrep.md`).

## User Persona

**Target User**: Operators running `agent-browser-pool reap` to clean up after a crashed agent. Secondary: every **active agent in the pool** — the fix protects their live browsers from collateral kills.

**Use Case**: An agent on lane 30 is mid-task. Another agent on lane 3 crashes, leaving an orphan dir. The operator runs `agent-browser-pool reap` to clean lane 3's orphan. Today that command **silently kills lane 30's Chrome** too (because `3` is a substring of `30` in the cmdline match). After this fix, only lane 3's orphan Chrome is killed; lane 30 is untouched.

**Pain Points Addressed**:
- **Isolation violation** (PRD §1.3 goals #2/#3, §2.13): an operator action that is supposed to be safe silently breaches lane isolation.
- **Lost work**: collateral-killed agents lose in-progress session state (forms, SPA navigation) per PRD §2.14, even though their Chrome auto-relaunches.
- **Silent/non-obvious**: no log line names the collateral victims — the operator has no idea other lanes were hit.
- **Test blind spot**: the existing `selftest_reap_orphan_dirs_removes_and_skips` only creates empty dirs, so the `pgrep`/`pkill` branch is dead code in the test and the bug is invisible.

## Why

- **Issue 1 (Major)** from the QA report. `pgrep`/`pkill -f` match the pattern as a **regex substring** of the full `/proc/<pid>/cmdline`. Lane numbers are path components, so the pattern for orphan lane `3` (`user-data-dir=…/active/3`) is a substring of lane `30` (`…/active/30`). Blast radius: orphan `1` + live `{10..19}` ⇒ up to 10 collateral kills; orphan `3` + live `{30..39}` ⇒ up to 10 kills. It triggers in a pool with as few as ~10–20 lanes — exactly the "unbounded, discoverable pool" (PRD §1.3.5).
- Only `pool_reap_orphan_dirs` is affected. The lease-driven `pool_reap_stale` path is safe (it kills by numeric `chrome_pgid` from the lease — no pattern matching).
- The fix is minimal (5 lines), backward-compatible (non-colliding lanes are unaffected — the anchored pattern still matches them), and closes a real isolation hole that the existing tests cannot detect.
- This subtask is **independent** (disjoint function from Issues 2 and 3 — see `architecture/system_context.md` "Issue Independence"). No data dependencies on sibling subtasks.

## What

### Behavior change (one block, ~5 lines)

The orphan-kill block currently:
```bash
if pgrep -f -- "user-data-dir=$dir" >/dev/null 2>&1; then
    pkill -f -- "user-data-dir=$dir" 2>/dev/null || true
    sleep 0.2
    pkill -9 -f -- "user-data-dir=$dir" 2>/dev/null || true
fi
```
becomes:
```bash
local pat="user-data-dir=$dir( |$)"
if pgrep -f -- "$pat" >/dev/null 2>&1; then
    pkill    -f -- "$pat" 2>/dev/null || true
    sleep 0.2
    pkill    -9 -f -- "$pat" 2>/dev/null || true
fi
```
The `pat` is hoisted to a variable so the anchor `( |$)` is written once and applied identically to all three calls. Chrome's cmdline is `--user-data-dir=<dir>` followed by either a space (next flag) or end-of-line, so `( |$)` after the dir defeats the prefix collision.

### What does NOT change

- The function signature, the loop structure, the `pool_lease_exists "$base"` orphan check, the prefix-guarded `rm -rf`, the orphan count, the `return 0`.
- `pool_reap_stale` (the lease-driven path) — already safe, untouched.
- `pool_admin_reap` (the only caller) — untouched.
- Non-colliding lanes — the anchored pattern still matches them (a lane `7` reap still kills lane `7`'s Chrome; the `( |$)` is satisfied by the trailing space before `--remote-debugging-port`).

### Success Criteria

- [ ] The orphan-kill block uses a single `pat` variable with the `( |$)` anchor on all three calls.
- [ ] The inline comment explains the anchoring (no false "never hit a different lane" claim).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean.
- [ ] `bash test/validate.sh` exits 0; the new selftest passes.
- [ ] The new selftest spawns two fake-Chrome processes (lanes 3 and 30), makes lane 3 the orphan, calls `pool_reap_orphan_dirs`, asserts lane 3's process is dead AND lane 30's process is alive, and reaps lane 30's survivor before returning.
- [ ] No orphaned processes leak from the selftest (AGENTS.md §3).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP quotes the **exact verbatim current code** at the edit site (verified by direct read of `lib/pool.sh:2874–2912`), gives the exact replacement, and — critically — provides a **verified-working regression test design** including the non-obvious gotcha that `sleep 300 -- --user-data-dir=…` (the contract's suggested approach) does NOT work because `sleep` rejects the flag. The PRP's test reference implementation was empirically validated end-to-end during research (see Validation section of this PRP + `research/repro-anchored-pgrep.md`).

### Documentation & References

```yaml
# MUST READ — project-internal (primary)
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/recon_issue1_reaper.md
  why: 'Verbatim code of pool_reap_orphan_dirs (2874-2912), the orphan-kill block (2898-2902), the variable-construction chain (base/dir), pool_admin_reap (only caller), and the existing selftest_reap_orphan_dirs_removes_and_skips (which has the test gap). Authoritative fix surface.'
  pattern: 'Section 2 quotes the exact buggy block; Section 5 shows the existing test that misses it; Section 6 lists the 3 risks.'
  critical: 'The kill block (2898-2902) is UNREACHABLE by the existing test (it only creates empty dirs). The regression test MUST spawn fake-Chrome processes with controlled argv.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/system_context.md
  why: 'Section "Issue 1" confirms location + root cause + fix surface + injection-safety reasoning; "Cross-Cutting Concerns / Test Infrastructure" documents the single-setup runner constraint (AGENTS.md §4) and the process-reaping requirement.'
  section: 'Issue 1' + 'Test Infrastructure'.
  critical: 'New selftests must be `selftest_*` functions (auto-picked by _run_selftest_suite via compgen). NEVER call setup() per-test. Tests that spawn processes MUST reap them (kill + wait). Use `timeout` on any subprocess that could block.'

- file: lib/pool.sh
  why: THE file being edited. Read lines 2874-2912 (the whole function) before editing. The exact current text of the orphan-kill block + comment is quoted verbatim in Implementation Tasks Task 1.
  pattern: 'Existing style: (a)/(b)/(c) labeled comment blocks, prefix-guarded rm, `2>/dev/null || true` on best-effort kills, `printf "%s\n" $orphans` stdout contract.'
  gotcha: 'Line numbers shift as edits apply. The edit tool matches by EXACT TEXT, not line number. The oldText quoted in Task 1 is byte-accurate (verified by direct read).'

- file: test/validate.sh
  why: 'The test framework. Mirror `selftest_doctor_flags_disconnected_lease` (lines ~852-881) for the hermetic timeout-bounded subshell pattern. Follow `selftest_reap_orphan_dirs_removes_and_skips` (lines ~826-844) for pool_lease_write usage + assert style.'
  pattern: 'Hermetic subshell: write a body.sh to $ABPOOL_TEST_ROOT, source pool.sh inside it, redirect AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT to temp dirs, run under `timeout 15`, capture rc. Bodies run in the MAIN shell via `if "$fn"` under the single-setup _run_selftest_suite.'
  gotcha: 'Do NOT name the test `test_*` (that prefix is run by abpool_run_suite with per-test setup() — hangs the sandbox on the 3rd call, AGENTS.md §4). Use `selftest_*`. Do NOT spawn processes in the MAIN shell — use the hermetic-subshell pattern so a crash or leak cannot contaminate the suite.'

# External references — pgrep/pkill ERE anchoring (verified during research)
- url: https://man7.org/linux/man-pages/man1/pgrep.1.html
  why: 'pgrep -f matches the pattern against the full /proc/<pid>/cmdline (NUL→space). The pattern is an ERE (extended regex). Anchoring with ( |$) — a non-capturing alternation of literal-space or end-of-line — is standard ERE. Confirmed empirically (see research/repro-anchored-pgrep.md).'
  critical: 'The `.` in $dir is an ERE metachar matching any char, but it only matches itself (permissive, not unsafe — a path `…/active/3` will not falsely match `…/activeX3` because the `/` separators are literal). $dir is absolute; $base is validated ^[0-9]+$ upstream (line ~2890); injection-safe.'

- url: https://man7.org/linux/man-pages/man2/setsid.2.html  (and kill(2))
  why: 'setsid puts the child in a new session/process-group so pgid == pid, enabling `kill -- -$pgid` teardown. The regression test uses setsid + `kill -9 -- -$pgid` for clean process-group reaping (AGENTS.md §3 canonical pattern).'
  critical: 'setsid (without -f) forks; $! captures the child PID == the new pgid. setsid -f (fork-and-exit) returns immediately and complicates PID capture — do NOT use -f in the test; use plain `setsid script ... & pgid=$!`.'

- docfile: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T1S1/research/repro-anchored-pgrep.md
  why: 'The empirical reproduction log proving (a) the bug, (b) the fix, (c) the correct fake-Chrome test harness design (bash loop, NOT sleep — sleep rejects --user-data-dir). This is the evidence base for the PRP confidence score and the test reference implementation.'
  section: 'Verified results' — shows unanchored=2 matches, anchored=1 match, pkill -9 -f anchored kills lane3 only, lane30 spared.
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh            # 4569 LOC — pool_reap_orphan_dirs at 2874-2912 (edit block at ~2895-2902)
├── test/
│   └── validate.sh        # ~928 LOC — selftest_reap_orphan_dirs_removes_and_skips at ~826;
│                          #            selftest_doctor_flags_disconnected_lease at ~852 (pattern to mirror)
└── plan/003_afc2f15931ab/bugfix/001_262079d529b6/
    ├── architecture/
    │   ├── recon_issue1_reaper.md     # verbatim code + fix surface + test gap
    │   └── system_context.md          # issue independence + test-infra constraints
    └── P1M1T1S1/
        ├── PRP.md                     # THIS FILE
        └── research/repro-anchored-pgrep.md   # empirical reproduction (this PRP's evidence base)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new source files. Edits are IN-PLACE in 2 existing files:
#   lib/pool.sh        — pool_reap_orphan_dirs orphan-kill block (anchor the pattern) + comment update
#   test/validate.sh   — add selftest_reap_orphan_dirs_kills_only_target_lane (new function, ~45 lines)
# (research/repro-anchored-pgrep.md is a research note under the plan dir, NOT a source file.)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (TEST HARNESS — the contract's example is WRONG): `sleep 300 -- --user-data-dir=...`
# does NOT work. `sleep` treats `--user-data-dir=...` as an unrecognized OPTION and exits
# immediately ("sleep: unrecognized option '--user-data-dir=...'"). So the fake-Chrome process
# dies before the test can assert anything, and /proc/<pid>/cmdline never holds the argv alive.
# VERIFIED during research. The fake-Chrome MUST be a bash loop script (e.g. `while :; do
# read -r -t 86400 _ || sleep 86400; done`) that accepts arbitrary argv and blocks forever.
# See the Task 3 reference implementation (fakechrome.sh) — copy it verbatim.

# CRITICAL (PID CAPTURE in the test): use `setsid script args & pgid=$!` — plain `setsid`
# (NO `-f`). `setsid -f` forks the child into a new session and the parent `setsid` exits
# immediately, so `$!` captures the transient `setsid` launcher PID, NOT the long-lived
# child. Plain `setsid ... &` puts the calling shell's backgrounded `setsid` (which becomes
# the session leader, pgid == that PID) in `$!`. VERIFIED: `/proc/$pgid/cmdline` then shows
# `bash .../fakechrome.sh --user-data-dir=.../active/3 ...`.

# GOTCHA (liveness check — AGENTS.md §3 "kill -0 is a trap"): do NOT use `kill -0 $pid` to
# test if the fake-Chrome is dead — it conflates ESRCH (dead) with EPERM (foreign-alive).
# Use `/proc/<pid>` existence: `[[ -d /proc/$pgid ]]` → alive; absent → dead/reaped. This is
# what the Task 3 assertions use.

# GOTCHA (pgrep -f includes the PARENT test shell): if the test body runs `pgrep -f` in the
# SAME shell whose argv contains the pattern string, the parent matches itself (contamination).
# This is why Task 3 runs the fake-Chrome spawn + reap + assertions INSIDE the hermetic
# body.sh subshell (mirroring selftest_doctor_flags_disconnected_lease), and asserts on
# /proc/<pgid> existence rather than re-running pgrep from the parent. VERIFIED: the hermetic
# subshell approach gives clean, uncontaminated results.

# GOTCHA (the `.` in $dir): $dir is an absolute path like /home/dustin/.agent-chrome-profiles/active/3.
# The `.` is an ERE metachar (matches any char). It is PERMISSIVE, not unsafe: the `/`
# separators in the path are literal ERE chars, and a real cmdline will not contain a path
# that differs only by a `.`-vs-other-char in a position that would cause a false lane match.
# Do NOT attempt to regex-escape $dir (e.g. sed 's/\./\\./g') — it adds complexity for zero
# safety gain and risks breaking the `( |$)` anchor. The recon doc (section 5 risk #2)
# confirms: "permissive but not unsafe in practice."

# GOTCHA (shellcheck on the pat assignment): `pat="user-data-dir=$dir( |$)"` — the `$)` looks
# like it could confuse the parser, but inside double quotes `$dir` expands and `\$` (escaped
# in the assignment) is the literal `$` of the ERE end-of-line. VERIFIED shellcheck-clean on
# ShellCheck (project gate is -S warning). Write it EXACTLY as: `pat="user-data-dir=$dir( |\$)"`.
# (The `\$` inside double quotes yields a literal `$` in the string → the ERE `$` metachar.)

# GOTCHA (set -e in pool_reap_orphan_dirs): the function runs under `set -euo pipefail`
# (inherited from the lib header). `pgrep` returns rc 1 on no-match — but it's inside an
# `if` (errexit-exempt), so no abort. `pkill ... || true` is explicitly guarded. The `sleep
# 0.2` is a sub-second bash builtin (cannot hang). The anchored-pattern change preserves
# ALL of these guards verbatim — do not remove any `|| true` or the `if pgrep ...; then` wrap.

# GOTCHA (process reaping in the test — AGENTS.md §3): the surviving fake-Chrome (lane 30)
# MUST be reaped before the selftest returns. Use `kill -9 -- -$pgid30 2>/dev/null || true`
# (kill the process GROUP, not just the PID — the `--` is required because the arg starts
# with `-`). Then the hermetic subshell exits and its EXIT trap removes the temp tree. If
# you leak the process, subsequent selftests / the suite teardown may wedge.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models, no schemas. `pool_reap_orphan_dirs` reads `$POOL_EPHEMERAL_ROOT` and `pool_lease_exists`; its contract (echo orphan count to stdout, rc 0 always) is unchanged.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — anchor the orphan-kill pattern (pool_reap_orphan_dirs, ~lines 2895-2902)
  - FIND this EXACT block (match by text, not line number; verified verbatim by direct read):
      ----------------------------------------------------------------
            # (d) Orphan. Kill any Chrome still pointed at it (owner is gone). Scope by the
            #     FULL ABSOLUTE --user-data-dir path so a different lane's Chrome is never hit.
            #     pgrep rc 1 (no match) → `if` falls through (no kill). pkill best-effort.
            if pgrep -f -- "user-data-dir=$dir" >/dev/null 2>&1; then
                pkill -f -- "user-data-dir=$dir" 2>/dev/null || true
                sleep 0.2                        # let renderer/GPU/utility children exit
                pkill -9 -f -- "user-data-dir=$dir" 2>/dev/null || true
            fi
      ----------------------------------------------------------------
  - REPLACE WITH (introduce a `pat` local; anchor with `( |$)`; rewrite the comment to
    explain WHY the anchor is required — the old comment's "never hit a different lane"
    claim was the false premise that hid this bug):
      ----------------------------------------------------------------
            # (d) Orphan. Kill any Chrome still pointed at it (owner is gone). The pattern is
            #     ANCHORED to the lane-dir boundary with `( |$)` so a prefix-colliding lane
            #     (e.g. lane 30 when reaping lane 3) is never hit — pgrep/pkill -f match as a
            #     regex SUBSTRING of /proc/<pid>/cmdline, so an UNanchored `user-data-dir=$dir`
            #     would also match `$dir` followed by more digits (lane 3's pattern is a
            #     substring of lane 30/31/.../300/...). Chrome's cmdline has the dir followed
            #     by a space (next --flag) or EOL, so `( |$)` is exact. `$dir` is absolute;
            #     `$base` is validated ^[0-9]+$ upstream → injection-safe. `.` in the path is
            #     a regex metachar but matches itself (permissive, not unsafe).
            #     pgrep rc 1 (no match) → `if` falls through (no kill). pkill best-effort.
            local pat="user-data-dir=$dir( |\$)"
            if pgrep -f -- "$pat" >/dev/null 2>&1; then
                pkill    -f -- "$pat" 2>/dev/null || true
                sleep 0.2                        # let renderer/GPU/utility children exit
                pkill    -9 -f -- "$pat" 2>/dev/null || true
            fi
      ----------------------------------------------------------------
  - WHY a `local pat` (not three inline anchored literals): (1) the anchor is written once,
    so the three calls cannot drift apart; (2) shellcheck-clean; (3) the comment documents
    the single source of truth. The `local` is safe inside the function (already has
    `local d base dir` at the top — bash allows additional `local` declarations mid-body).
  - PRESERVE: the `if pgrep ... ; then` wrap (errexit-exempt for rc 1), both `|| true`
    guards on pkill, the `sleep 0.2`, the inline `# let renderer/GPU...` comment, and the
    surrounding prefix-guarded rm block (do NOT touch lines after the `fi`).
  - VERIFY after edit:
      grep -n 'user-data-dir="$dir"' lib/pool.sh      # → nothing (old unanchored literal gone)
      grep -n 'pat="user-data-dir="$dir"' lib/pool.sh # → one match (the new local)

Task 2: VERIFY the lib edit (static — AGENTS.md §1/§2: no Chrome, no suite yet)
  - RUN:
      bash -n lib/pool.sh
      shellcheck -s bash -S warning lib/pool.sh
  - EXPECTED: both clean (zero output; shellcheck exit 0). The current baseline is clean
    (verified); this edit only adds a `local` + rewrites a pattern + comment, so it cannot
    introduce a warning. If shellcheck fires, you changed code beyond the quoted block —
    revert and redo.

Task 3: ADD test/validate.sh — selftest_reap_orphan_dirs_kills_only_target_lane
  - PLACE: immediately AFTER `selftest_reap_orphan_dirs_removes_and_skips` (which ends
    around line 844, just before the `# --- doctor [lanes] flags...` comment at ~851).
  - NAMING: `selftest_reap_orphan_dirs_kills_only_target_lane` (the `selftest_` prefix is
    auto-discovered by `_run_selftest_suite` via `compgen -A function | grep '^selftest_'`).
  - FOLLOW pattern: `selftest_doctor_flags_disconnected_lease` (validate.sh ~852-881) —
    hermetic timeout-bounded bash subshell (write body.sh, source pool.sh, redirect state
    + ephemeral root to temp, `timeout 15`, capture rc, assert_eq).
  - REFERENCE IMPLEMENTATION (validated end-to-end during research — copy the fakechrome.sh
    design verbatim; do NOT substitute `sleep`):
      ----------------------------------------------------------------
      # Regression for Issue #1 (unanchored pgrep/pkill -f prefix collision). Spawns TWO
      # fake-Chrome processes with controlled argv on prefix-colliding lane numbers (3 and 30),
      # makes lane 3 the orphan (no lease) and lane 30 leased, calls pool_reap_orphan_dirs,
      # and asserts lane 3's process is DEAD while lane 30's process is ALIVE. Runs in a
      # hermetic timeout-bounded subshell (mirror selftest_doctor_flags_disconnected_lease)
      # so spawned processes + temp tree cannot contaminate the suite. Reaps the survivor.
      selftest_reap_orphan_dirs_kills_only_target_lane() {
          local outdir script rc out
          outdir="$ABPOOL_TEST_ROOT/reap-prefix"
          mkdir -p -- "$outdir/active/3" "$outdir/active/30"
          script="$outdir/body.sh"
          # fakechrome.sh: a process that (a) accepts arbitrary chrome-like argv, (b) blocks
          # forever (until killed), (c) holds a CLEAN /proc/<pid>/cmdline. NB: `sleep` CANNOT
          # be used here — it rejects `--user-data-dir=...` as an unknown option and exits.
          cat >"$outdir/fakechrome.sh" <<'FAKE'
      #!/usr/bin/env bash
      # Hold the caller-supplied argv (incl. --user-data-dir=<dir>) alive until killed.
      while :; do read -r -t 86400 _ || sleep 86400; done
      FAKE
          chmod +x -- "$outdir/fakechrome.sh"
          cat >"$script" <<'EOF'
      set -uo pipefail    # NO set -e: pgrep/pkill return 1 legitimately; we assert via rc.
      source "$1/lib/pool.sh"
      pool_config_init
      pool_state_init

      EPH="$2/active"
      # Spawn TWO fake chromes in their own process groups (setsid; pgid == $!). Plain
      # setsid (NOT -f) so $! is the long-lived session leader, not a transient launcher.
      setsid "$2/fakechrome.sh" "--user-data-dir=$EPH/3"  "--remote-debugging-port=53423" >/dev/null 2>&1 &
      pgid3=$!
      setsid "$2/fakechrome.sh" "--user-data-dir=$EPH/30" "--remote-debugging-port=53453" >/dev/null 2>&1 &
      pgid30=$!
      sleep 0.5   # let both enter their read loop (cmdline visible in /proc)

      # Lane 30 is LEASED (a live lane) → must be SKIPPED by the orphan sweep.
      #   args: LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME CWD CHROME_PID CHROME_PGID CONNECTED
      pool_lease_write 30 "$EPH/30" 53453 abpool-30 1 pi 1000 /x "$pgid30" "$pgid30" true
      # Lane 3 is an ORPHAN (no lease) with a live fake-Chrome → must be KILLED.

      # Sanity: both fake chromes are alive before the reap.
      [[ -d /proc/$pgid3 ]]  || { echo "PRE: lane3 proc $pgid3 not alive"; exit 1; }
      [[ -d /proc/$pgid30 ]] || { echo "PRE: lane30 proc $pgid30 not alive"; exit 1; }

      orphans="$(pool_reap_orphan_dirs)"
      [[ "$orphans" == "1" ]] || { echo "expected 1 orphan reaped, got [$orphans]"; exit 1; }

      sleep 0.4   # let the pkill -9 propagate
      # THE core assertion: lane 3 DEAD, lane 30 ALIVE (no collateral kill).
      if [[ -d /proc/$pgid3 ]];  then echo "FAIL: lane3 (orphan) still alive"; rc=1; else rc=0; fi
      if [[ -d /proc/$pgid30 ]]; then
          : # good — spared
      else
          echo "FAIL: lane30 (leased) was collateral-killed by the prefix collision"; rc=1
      fi

      # Reap the survivor (AGENTS.md §3 — never leak processes). Kill the process GROUP.
      kill -9 -- "-$pgid30" 2>/dev/null || true
      wait "$pgid30" 2>/dev/null || true
      wait "$pgid3"  2>/dev/null || true
      exit "${rc:-0}"
      EOF
          rc=0
          out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" \
                timeout 15 bash "$script" "$ABPOOL_REPO" "$outdir" 2>&1)" || rc=$?
          # Defensive: even on failure, sweep any leaked fakechrome under this outdir.
          pkill -9 -f -- "$outdir/fakechrome.sh" 2>/dev/null || true
          assert_eq "0" "$rc" "reap kills only the orphan lane (no prefix-collision collateral) (out: $out)" || return 1
      }
      ----------------------------------------------------------------
  - GOTCHA (set -e inside body.sh): the body uses `set -uo pipefail` NOT `set -euo pipefail`.
    REASON: `pgrep`/`pkill` return rc 1 on no-match and `[[ -d /proc/$pid ]]` in an `if` is
    fine, but the function `pool_reap_orphan_dirs` internally uses `pgrep ... >/dev/null`
    inside an `if` (errexit-exempt) — that's safe under set -e too. The real reason to drop
    `-e` is the final `exit "${rc:-0}"` pattern: we want to run the cleanup `kill`/`wait`
    unconditionally and THEN exit with our chosen rc, which set -e would short-circuit on
    any intermediate non-zero. Mirrors how selftest_doctor_flags_disconnected_lease tolerates
    doctor's rc 1 with `|| true`. (If you prefer set -e, wrap each kill/wait in `|| true` and
    compute rc explicitly — the reference impl above uses the simpler no-set-e form.)
  - GOTCHA (the defensive pkill in the outer function): `pkill -9 -f -- "$outdir/fakechrome.sh"`
    runs in the MAIN shell after the subshell returns, catching any fakechrome that escaped
    the body's cleanup (e.g. if the body hit the timeout). The `outdir` path is unique per
    test run (under $ABPOOL_TEST_ROOT) so this never matches an unrelated process.
  - GOTCHA (inter-body backstop): _run_selftest_suite (validate.sh ~911) does `rm -f --
    "${POOL_LANES_DIR:?}/"*.json` between bodies but does NOT remove ephemeral dirs. Our
    body writes the lane-30 lease inside the HERMETIC SUBSHELL's redirected state dir
    ($outdir/state), NOT the suite's $POOL_LANES_DIR — so it cannot pollute sibling selftests.
    The $outdir tree itself is under $ABPOOL_TEST_ROOT, removed by the suite's EXIT trap.

Task 4: VERIFY — full validation gauntlet (static + the self-test suite)
  - RUN (in order):
      bash -n lib/pool.sh
      bash -n test/validate.sh
      shellcheck -s bash -S warning lib/pool.sh
      shellcheck -s bash -S warning test/validate.sh
      bash test/validate.sh
  - EXPECTED:
      bash -n (both)         → no output (clean)
      shellcheck (both)      → no output, exit 0 (project gate is -S warning)
      bash test/validate.sh  → exits 0; prints "== selftest_reap_orphan_dirs_kills_only_target_lane"
                               then "   PASS"; final "N passed, 0 failed"
  - IF the new selftest FAILS: read the `out:` captured in the assert message. Most likely
    causes: (a) fakechrome died at spawn (did you use the bash-loop fakechrome, NOT sleep?);
    (b) pgid capture wrong (did you use `setsid ... &` NOT `setsid -f ... &`?); (c) lane 30
    lease not written / written to the wrong state dir (must be the hermetic $outdir/state,
    via the env redirects). Fix the TEST, not the lib — the lib fix is proven by research.
```

### Implementation Patterns & Key Details

```bash
# Pattern A — the anchored ERE (the fix). `\$` inside double quotes → literal `$` → ERE end-of-line.
#   pat="user-data-dir=$dir( |\$)"
#   pgrep -f -- "$pat"   # ERE substring match on /proc/<pid>/cmdline, anchored to dir boundary
# VERIFIED: for lanes 3 + 30, unanchored matches BOTH pids; anchored matches ONLY lane 3's pid.

# Pattern B — hermetic subshell test (mirror selftest_doctor_flags_disconnected_lease):
#   - write body.sh to $ABPOOL_TEST_ROOT/<name>/
#   - source pool.sh INSIDE body.sh; redirect AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT
#   - `timeout 15 bash body.sh "$ABPOOL_REPO" "$outdir"`; capture `out` + rc via `|| rc=$?`
#   - assert_eq "0" "$rc" "label (out: $out)"
# The subshell isolates: spawned processes, temp leases, env stubs. The suite's MAIN shell
# stays clean.

# Pattern C — fake-Chrome process for pgrep/pkill tests (USE THIS, not sleep):
#   cat >fakechrome.sh <<'EOF'
#   #!/usr/bin/env bash
#   while :; do read -r -t 86400 _ || sleep 86400; done
#   EOF
# `sleep 300 -- --user-data-dir=...` FAILS (sleep rejects the flag). The bash loop holds the
# argv in /proc/<pid>/cmdline and blocks ~forever. `setsid script args &; pgid=$!` (plain
# setsid, NOT -f) captures the session-leader PID. Liveness via `[[ -d /proc/$pgid ]]`
# (never kill -0 — AGENTS.md §3). Teardown: `kill -9 -- -$pgid` (process GROUP, the `--`
# is required because the arg starts with `-`).

# Pattern D — leave no orphan (AGENTS.md §3): the body reaps the survivor (kill -9 -- -$pgid30)
# before exiting; the outer function adds a defensive `pkill -9 -f -- "$outdir/fakechrome.sh"`
# in case the body timed out. `wait` each spawned pgid so /proc truly clears (zombie hygiene).
```

### Integration Points

```yaml
CODE (in-place edits in 2 files, no new source files):
  - lib/pool.sh ~2895-2902    pool_reap_orphan_dirs orphan-kill block (REWRITE: add `local pat`, anchor, comment)
  - test/validate.sh ~845     new selftest_reap_orphan_dirs_kills_only_target_lane (ADD, ~55 lines)

DO NOT TOUCH:
  - lib/pool.sh pool_reap_stale        (lease-driven path — already safe; kills by chrome_pgid)
  - lib/pool.sh pool_admin_reap        (the only caller — contract unchanged)
  - lib/pool.sh pool_chrome_kill       (canonical pgroup teardown — pre-existing, separate concern)
  - test/validate.sh selftest_reap_orphan_dirs_removes_and_skips  (keep; complementary coverage)
  - README.md                          (§reap description still accurate post-fix — Mode A doc-only here)

CONFIG: none.
ROUTES: none.
DATABASE: none.
```

## Validation Loop

> **AGENTS.md §1/§2 compliance**: Levels 1–3 are STATIC (`bash -n`, `shellcheck`, `grep`) +
> the self-test suite (which spawns only fake `sleep`-loop processes under `timeout`, never
> real Chrome). No real Chrome, no daemon, no operator-state-dir access. Level 4 is the
> empirical reproduction (optional, isolated, timeout-bounded).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                          # parse check. MUST be clean.
bash -n test/validate.sh                     # parse check the test file after adding the body.
shellcheck -s bash -S warning lib/pool.sh    # project gate. MUST exit 0.
shellcheck -s bash -S warning test/validate.sh
# Expected: zero output from all four; shellcheck exit 0.
# The lib baseline is already clean (verified); the edit only adds a `local` + rewrites a
# pattern + comment, so it cannot introduce a warning. If shellcheck fires, you changed code
# beyond the quoted block — revert and redo.
```

### Level 2: Unit Tests (the new selftest)

```bash
# The self-test suite runs ALL selftest_* functions under the single-setup runner.
bash test/validate.sh
# Expected: exits 0. Includes the line:
#   == selftest_reap_orphan_dirs_kills_only_target_lane
#      PASS
# and a final "N passed, 0 failed" line.
#
# If the new selftest FAILS, the assert message includes `(out: ...)` — read it. The body.sh
# stderr/stdout is captured there. Common failure modes + fixes are in Task 4's note.
# Do NOT "fix" a failing selftest by weakening the assertion — if lane 30 dies, the LIB fix
# is wrong (re-read Task 1's exact pat= assignment; the most common mistake is forgetting the
# `\$` escape, yielding a literal `$dir(` + broken ERE).
```

### Level 3: Integration / Static Contract Checks

```bash
# 3a. The unanchored literal is GONE; the anchored `pat` is present:
grep -n 'pgrep -f -- "user-data-dir="$dir"' lib/pool.sh     # Expected: NO output
grep -n 'pkill.*-f -- "user-data-dir="$dir"' lib/pool.sh    # Expected: NO output
grep -n 'local pat="user-data-dir="$dir( |\$)"' lib/pool.sh # Expected: ONE match

# 3b. The function contract is unchanged (still echoes count, returns 0):
sed -n '/^pool_reap_orphan_dirs()/,/^[^ ]/p' lib/pool.sh | grep -E 'printf .%s.\\n. .\$orphans|return 0'
# Expected: two lines (the printf + the return 0).

# 3c. The new selftest is auto-discovered (no registration needed):
grep -n 'selftest_reap_orphan_dirs_kills_only_target_lane' test/validate.sh
# Expected: TWO matches (the function def + its invocation is implicit via compgen; the grep
#           shows the def line and the assert label line).

# 3d. No processes leak after running the suite:
pgrep -af 'fakechrome.sh' || echo "no fakechrome procs (good)"
# Expected: "no fakechrome procs (good)".
```

### Level 4: Empirical Reproduction (optional, isolated, timeout-bounded)

```bash
# This is the research reproduction script — it PROVES the bug + the fix in <2s with fake
# processes, no real Chrome. Safe to run; it reaps everything. (Already run during research;
# included here so the implementer can re-confirm if the selftest's PASS feels suspicious.)
timeout 20 bash <<'REPRO'
set -uo pipefail
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
EPH="$ROOT/active"; mkdir -p "$EPH/3" "$EPH/30"
cat >"$ROOT/fakechrome.sh" <<'EOF'
#!/usr/bin/env bash
while :; do read -r -t 86400 _ || sleep 86400; done
EOF
chmod +x "$ROOT/fakechrome.sh"
setsid "$ROOT/fakechrome.sh" "--user-data-dir=$EPH/3"  "--remote-debugging-port=53423" >/dev/null 2>&1 &
pgid3=$!
setsid "$ROOT/fakechrome.sh" "--user-data-dir=$EPH/30" "--remote-debugging-port=53453" >/dev/null 2>&1 &
pgid30=$!
sleep 0.5
PAT3="user-data-dir=$EPH/3"
PAT3A="user-data-dir=$EPH/3( |\$)"
echo "unanchored matches: $(pgrep -f -- "$PAT3" 2>/dev/null | wc -l) (bug: expect 2)"
echo "anchored matches:   $(pgrep -f -- "$PAT3A" 2>/dev/null | wc -l) (fix: expect 1)"
pkill -9 -f -- "$PAT3A" 2>/dev/null || true
sleep 0.3
echo "lane3 alive? $([[ -d /proc/$pgid3 ]] && echo YES-BAD || echo NO-GOOD-KILLED)"
echo "lane30 alive? $([[ -d /proc/$pgid30 ]] && echo YES-GOOD-SPARED || echo NO-BAD-KILLED)"
kill -9 -- -$pgid30 2>/dev/null || true
wait "$pgid3" 2>/dev/null || true; wait "$pgid30" 2>/dev/null || true
REPRO
# Expected:
#   unanchored matches: 2 (bug: expect 2)
#   anchored matches:   1 (fix: expect 1)
#   lane3 alive? NO-GOOD-KILLED
#   lane30 alive? YES-GOOD-SPARED
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean; `bash -n test/validate.sh` clean.
- [ ] `shellcheck -s bash -S warning lib/pool.sh` exit 0; same for `test/validate.sh`.
- [ ] Level 3 snippet 3a: unanchored literals gone, anchored `pat` present (one match).
- [ ] Level 3 snippet 3b: function contract unchanged (printf count + return 0).
- [ ] `bash test/validate.sh` exits 0; new selftest prints PASS.
- [ ] Level 3 snippet 3d: no `fakechrome.sh` processes leak.

### Feature Validation

- [ ] Orphan-kill block uses `local pat="user-data-dir=$dir( |\$)"` on all three calls.
- [ ] Inline comment explains the anchoring + the prefix-collision rationale (no false "never hit" claim).
- [ ] New selftest spawns two fake chromes (lanes 3 + 30), reaps the orphan (3), asserts 3-dead + 30-alive.
- [ ] New selftest reaps the survivor + waits both pgids before returning (AGENTS.md §3).
- [ ] `pool_reap_stale` (lease path) untouched; `pool_admin_reap` (caller) untouched.

### Code Quality Validation

- [ ] Edit-tool oldText matched byte-for-byte (no approximations).
- [ ] No code beyond the quoted lib block + the new selftest was touched.
- [ ] shellcheck baseline preserved (was clean, still clean).
- [ ] Selftest uses the hermetic-subshell pattern (mirror `selftest_doctor_flags_disconnected_lease`).
- [ ] Selftest uses the bash-loop `fakechrome.sh` (NOT `sleep` — sleep rejects `--user-data-dir`).
- [ ] Selftest uses plain `setsid ... &; pgid=$!` (NOT `setsid -f`) for correct PID capture.
- [ ] Liveness via `/proc/<pgid>` existence (NOT `kill -0` — AGENTS.md §3 trap).
- [ ] No scope creep into Issue 2 (doctor) or Issue 3 (ensure_connected) — disjoint functions.

### Documentation & Deployment

- [ ] Inline comment updated (Mode A) — no separate docs subtask.
- [ ] No README change needed (§reap description "killing any orphaned Chrome still pointed at them" remains accurate post-fix).
- [ ] No new env vars; no config changes; no path changes.
- [ ] Research note saved at `plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T1S1/research/repro-anchored-pgrep.md`.

---

## Anti-Patterns to Avoid

- ❌ Don't use `sleep 300 -- --user-data-dir=...` for the fake Chrome — `sleep` rejects the flag and exits immediately, leaving nothing for `pgrep` to match. Use the bash-loop `fakechrome.sh`. (Verified during research.)
- ❌ Don't use `setsid -f` in the test — `-f` forks-and-exits, so `$!` captures the transient launcher, not the long-lived child. Use plain `setsid ... &`.
- ❌ Don't use `kill -0 $pid` for liveness — it conflates dead (ESRCH) with foreign-alive (EPERM). Use `/proc/<pid>` existence. (AGENTS.md §3.)
- ❌ Don't run `pgrep -f` for the pattern in the SAME shell whose argv contains the pattern string — the parent matches itself (contamination). Do liveness + assertions on `/proc/<pgid>` inside the hermetic subshell.
- ❌ Don't regex-escape the `.` in `$dir` — it's permissive, not unsafe, and escaping risks breaking the `( |$)` anchor. (Recon §5 risk #2.)
- ❌ Don't write the anchor inline three times — hoist to `local pat` so the calls cannot drift.
- ❌ Don't drop `set -e`-safety: keep the `if pgrep ... ; then` wrap and both `|| true` guards on `pkill` exactly as-is.
- ❌ Don't touch `pool_reap_stale`, `pool_admin_reap`, `pool_chrome_kill`, or the existing `selftest_reap_orphan_dirs_removes_and_skips`.
- ❌ Don't run real Chrome or the operator's real state/ephemeral dirs (AGENTS.md §1/§2). The selftest uses only fake `sleep`-loop processes under `timeout` in a redirected temp tree.
- ❌ Don't fix Issue 2 (doctor) or Issue 3 (ensure_connected) here — they have their own subtasks and touch disjoint functions.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: the lib fix is 5 lines with an exact verbatim oldText and a verified shellcheck-clean replacement. The regression test's non-obvious failure modes (sleep rejects the flag; setsid -f captures the wrong PID; parent-shell pgrep contamination; kill -0 trap) are all pre-solved in the reference implementation, which was **empirically validated end-to-end** during research (unanchored=2 matches → anchored=1 match → pkill kills lane 3 only, lane 30 spared). The -1 reflects residual risk in the test's timing (`sleep 0.5` for the fake chromes to enter their read loop; `sleep 0.4` for pkill propagation) — on a heavily loaded host these could need bumping, and the `timeout 15` wrapper plus the defensive outer `pkill` guarantee no leak even if timing slips. The lib edit itself is near-zero-risk (pattern tightening only; non-colliding lanes unaffected by construction).
