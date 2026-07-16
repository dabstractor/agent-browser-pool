# PRP — P3.M2.T1.S1: Generalize `spawn_sim_owner` to optional comm name (2nd positional, default `pi`)

**Work item:** P3.M2.T1.S1 (1 point) — parent P3.M2.T1 (Multi-harness owner-simulation test coverage), milestone P3.M2 (Test coverage), PRD §2.18 (Testing & validation), §2.4 (owner resolution), §2.1.
**Type:** Test-framework internal generalization. **No user/config/API surface change.**
**Phase constraint:** This is a PLANNING-phase deliverable. Per AGENTS.md §1, validation here is
**static only** (`bash -n`, `shellcheck`). **Do NOT run the test suite** (it boots real Chrome).
The functional proof that non-pi owners work is deferred to P3.M2.T1.S2's new selftest.

---

## Goal

**Feature Goal:** Make `spawn_sim_owner` able to simulate a lane owner whose `/proc/<pid>/comm` is
**any** recognized (or unrecognized) harness name, not just `"pi"`, while leaving every existing
caller byte-for-byte unchanged (comm defaults to `"pi"`).

**Deliverable:** A backward-compatible signature change to `spawn_sim_owner` in `test/validate.sh`:
```bash
spawn_sim_owner [SECONDS] [COMM]   # COMM default "pi"; echoes the PID of a LIVE
                                   # process whose /proc/comm == COMM
```
plus a 15-char `TASK_COMM_LEN` guard and a refreshed function header comment.

**Success Definition:**
1. `spawn_sim_owner` (no args) still yields a PID with `/proc/<pid>/comm == "pi"` (every existing
   caller — validate.sh:197, release_reaper.sh:157+238, concurrency.sh:233+383, transparency.sh:162
   and 433/439/478/483 — is untouched and stays green).
2. `spawn_sim_owner 600 claude` yields a PID with `/proc/<pid>/comm == "claude"` (provable later by
   P3.M2.T1.S2; structurally guaranteed by the kernel's ELF-basename rule).
3. `bash -n test/validate.sh` → rc 0; `shellcheck -S warning -s bash test/validate.sh` → rc 0; the
   spawn_sim_owner region introduces **zero new** shellcheck findings.
4. The `mktemp -d -t abpool-pi.XXXXXX` **directory prefix is unchanged** (the trap's
   `rm -rf -- /tmp/abpool-pi.*` glob backstop stays valid for any comm name).

---

## Why

- P3 (Decision O9) generalizes owner resolution from a hardcoded `"pi"` requirement to a
  **recognized-harness set** (default `pi,claude,codex,agy,antigravity`; PRD §2.11, §2.4 step 1).
- The test suite simulates a live lane owner by copying `/usr/bin/sleep` to a temp ELF whose
  **filename** becomes the process's `/proc/comm` (kernel sets comm to the executed ELF's basename).
  That ELF was **hardcoded** to be named `pi`, so the suite could only ever exercise the `pi` path.
- P3.M2.T1.S2 must prove non-pi harnesses (e.g. `claude`) resolve and non-harness comms (e.g.
  `xterm`) are rejected. It cannot do that until `spawn_sim_owner` can produce a non-`pi` comm.
  **This item is S2's sole prerequisite.**

---

## What

### User-visible behavior
None — `spawn_sim_owner` is a test-internal helper, never shipped, never called by the pool binary.

### Technical change (mechanical, confined to ONE function)
`test/validate.sh` — `spawn_sim_owner()`:
- Add 2nd positional `COMM` (default `"pi"`): `local dur="${1:-600}" comm_name="${2:-pi}" …`
- Add a 15-char truncation guard (warn + truncate) so the settle-loop comparison always targets what
  the kernel reports.
- `bin="$bin_dir/pi"` → `bin="$bin_dir/$comm_name"` (the **bin/ELF filename** changes; the
  **mktemp dir prefix** `abpool-pi.XXXXXX` is deliberately left as-is).
- `[[ "$comm" == "pi" ]]` → `[[ "$comm" == "$comm_name" ]]` (settle loop).
- Refresh the header comment to describe `[COMM]`, the kernel-truncation guard, and drop the now-
  stale "requires 'pi'" wording (post P3.M1.T1.S2, `pool_owner_alive` takes an expected-comm arg).

### Success Criteria
- [ ] New signature `spawn_sim_owner [SECONDS] [COMM]` with `COMM` default `"pi"`.
- [ ] 15-char guard: `comm_name` longer than 15 chars is warned (stderr) and truncated to 15.
- [ ] `bin` path uses `$comm_name`; `mktemp -d -t abpool-pi.XXXXXX` **prefix unchanged**.
- [ ] Settle loop compares against `$comm_name`.
- [ ] All 6 (technically 10 incl. transparency 433/439/478/483) existing callers untouched.
- [ ] `bash -n test/validate.sh` rc 0; `shellcheck -S warning -s bash test/validate.sh` rc 0.

---

## All Needed Context

### Context Completeness Check
_Pass: an agent who has never seen this repo gets the exact file, the exact function, the exact
old text, the exact new text, the one critical do-not-touch line, the honest static-check gates,
and the scope boundaries. Nothing else is required._

### Documentation & References
```yaml
- file: test/validate.sh
  why: CONTAINS the target function spawn_sim_owner (def at ~line 119; header comment ~103-117).
  pattern: copy /usr/bin/sleep to a temp ELF named like the desired comm; kernel sets /proc/comm to the ELF basename.
  critical: the cleanup trap's glob backstop `rm -rf -- /tmp/abpool-pi.*` REQUIRES the mktemp dir prefix stay "abpool-pi". ONLY the bin filename generalizes to $comm_name.

- file: plan/003_afc2f15931ab/architecture/test_code_map.md
  why: §1 + §5a are the authoritative spec for this exact change (signature, the 3 edit points, the mktemp-prefix gotcha, the 15-char note). Read §1, §3 (callers), §5a before editing.
  critical: §5a gives the target function body almost verbatim — use it as the reference shape.

- url: https://man7.org/linux/man-pages/man5/proc_pid_comm.5.html
  why: authoritative source for "comm silently truncated to TASK_COMM_LEN=16 (incl NUL) → 15 usable chars".
  critical: justifies the 15-char guard; a long ELF name keeps its filename but /proc/comm reports only 15 chars.

- file: lib/pool.sh (function pool_owner_alive)
  why: the downstream consumer whose liveness check the simulated owner must satisfy. After P3.M1.T1.S2 it takes `[EXPECTED_COMM]`. Refer to it BY NAME in the refreshed header comment (not a line number — they drift).
  critical: do NOT edit lib/pool.sh in this item (M1 scope, already Complete).

- file: AGENTS.md
  why: §1 forbids running the suite / booting Chrome during planning; §3 mandates reaping spawned procs.
  critical: validation is STATIC ONLY here (bash -n + shellcheck). No `bash test/*.sh`.
```

### Current codebase tree (relevant slice)
```
test/
├── validate.sh        # THE FRAMEWORK: assertions + spawn_sim_owner (TARGET) + setup/teardown + runner + selftest_*
├── release_reaper.sh  # sources validate.sh; calls spawn_sim_owner (2 sites) — UNCHANGED
├── concurrency.sh     # sources validate.sh; calls spawn_sim_owner (2 sites) — UNCHANGED
└── transparency.sh    # sources validate.sh; calls spawn_sim_owner (6 sites) — UNCHANGED
lib/pool.sh            # pool_owner_alive (downstream consumer, EXPECTED_COMM arg) — NOT TOUCHED here
```

### Desired codebase tree (delta)
```
test/validate.sh       # MODIFIED: spawn_sim_owner signature + guard + header comment (ONE function)
(no new files; no deletions)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL: the cleanup trap (_abpool_global_cleanup) has a glob backstop:
#     rm -rf -- /tmp/abpool-pi.* 2>/dev/null || true
# It is AUTHORITATIVE for leaked sim-owner bin dirs, because ABPOOL_SIM_BINS+=("$bin_dir")
# runs INSIDE the $(...) subshell (spawn_sim_owner is consumed via `pid="$(spawn_sim_owner)"`)
# and is therefore LOST in the parent. => mktemp -d -t abpool-pi.XXXXXX MUST keep the
# "abpool-pi" dir-name prefix. Generalize ONLY the bin filename to $comm_name.

# CRITICAL: kernel truncates /proc/<pid>/comm to 15 chars (TASK_COMM_LEN=16 incl NUL).
# A bin ELF named "antigravity-very-long-name" (24 chars) keeps its filename, but the kernel
# reports comm="antigravity-ve" (15). Without truncating comm_name too, the settle loop's
#   [[ "$comm" == "$comm_name" ]]   NEVER matches -> falls through with an un-settled pid.
# Defaults (pi/claude/codex/agy/antigravity) are all <=15 -> guard is a no-op for them.

# shellcheck baseline honesty: `shellcheck -s bash test/validate.sh` is rc 1 with 5 PRE-EXISTING
# info-level findings (lines 29 SC1091; 578/608/638/670 SC2016) — all intentional, OUT OF SCOPE.
# Use `shellcheck -S warning -s bash test/validate.sh` (rc 0) as the gate, OR assert the finding
# count stays at 5 and none land in the edited region. Do NOT "fix" the 5 info findings here.

# set -e is active (validate.sh shebang). All new commands must be rc-safe: the guard's printf is
# always rc 0; the assignment comm_name="${...:0:15}" is rc 0; (( ${#comm_name} > 15 )) inside `if`
# is errexit-exempt. No bare kill/pgrep added -> no new abort surface.
```

---

## Implementation Blueprint

### Exact replacement (single contiguous block)

**Locate** the block from the header-comment signature line through the function's closing brace
(currently `test/validate.sh` ~lines 103–141). **Replace it wholesale** with:

```bash
# =============================================================================
# spawn_sim_owner [SECONDS] [COMM] — echo the PID of a LIVE process whose
# /proc/comm == COMM (COMM default "pi").
#
# COMM (2nd positional, default "pi") is the desired /proc/<pid>/comm. The kernel sets comm
# to the BASENAME of the executed ELF (proc(5)), NOT argv[0] — so copying /usr/bin/sleep to a
# temp file NAMED "$COMM" and exec'ing it yields comm=="$COMM" (HOST-VERIFIED 2026-07-13 for
# COMM="pi"). `exec -a "$COMM" sleep` does NOT work (argv[0] only). P3.M2.T1.S1 generalized
# this from a hardcoded "pi" so P3.M2.T1.S2 can simulate non-pi harnesses (claude/codex/agy/…)
# for multi-harness owner-resolution tests; existing callers pass no COMM → default "pi".
# KERNEL TRUNCATION (proc_pid_comm(5)): comm is silently truncated to 15 chars (TASK_COMM_LEN=16
# incl NUL). A long COMM keeps its ELF filename but the kernel reports the truncated comm → the
# settle-loop below would never match; we truncate COMM up front. (All defaults ≤15 → no-op.)
#
# WHY THIS EXISTS (the pivotal gotcha): pool_owner_alive (lib/pool.sh) reads the REAL
# /proc/<pid>/comm and (after P3.M1.T1.S2) compares it to the EXPECTED_COMM it is passed. The
# env override (AGENT_BROWSER_POOL_OWNER_PID) sets the lease's owner IDENTITY; it does NOT fake
# the kernel-visible process. So for a lease to be "mine"/"live", its owner PID must point at a
# real running process whose comm matches the recorded harness.
#
# Tracks the pid (ABPOOL_CUR_OWNER, set by setup) + its temp bin dir (trap removes it).
# SETTLES on a poll loop: after fork the child briefly shows the PARENT's comm until execve
# completes — reading comm/starttime in that window returns the wrong value (cost a verification
# run: it returned "bash"). The poll guarantees a ready-to-use pid.
# Host tooling verified: /usr/bin/sleep present.
# =============================================================================
spawn_sim_owner() {
    local dur="${1:-600}" comm_name="${2:-pi}" bin_dir bin pid comm tries
    # Kernel truncates /proc/<pid>/comm to 15 chars (TASK_COMM_LEN=16 incl NUL; proc_pid_comm(5)).
    # A longer harness name keeps its ELF filename but the kernel SILENTLY truncates comm → the
    # settle-loop comparison below would never match. Truncate comm_name so it targets exactly what
    # the kernel reports. (Defaults pi/claude/codex/agy/antigravity are all ≤15 → guard is a no-op.)
    if (( ${#comm_name} > 15 )); then
        printf 'spawn_sim_owner: comm name truncated to 15 chars (TASK_COMM_LEN): %s -> %s\n' \
            "$comm_name" "${comm_name:0:15}" >&2
        comm_name="${comm_name:0:15}"
    fi
    # KEEP the "abpool-pi" dir PREFIX: the cleanup trap's glob backstop `rm -rf -- /tmp/abpool-pi.*`
    # must reap this dir for ANY comm (ABPOOL_SIM_BINS+= is lost across the $(...) subshell). Only
    # the BIN filename generalizes to $comm_name; the dir name stays abpool-pi.XXXXXX.
    bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"
    bin="$bin_dir/$comm_name"
    cp -- /usr/bin/sleep "$bin"
    chmod +x -- "$bin"
    # Detach the child's fds (</dev/null >/dev/null 2>&1) so it does NOT inherit the
    # command-substitution pipe. spawn_sim_owner is consumed via `pid="$(spawn_sim_owner)"`
    # (setup + test bodies); without this the child is killed on subshell exit (or holds the
    # pipe → the caller blocks): the returned pid is dead → _pool_get_starttime fails → setup()
    # aborts under set -e. HOST-VERIFIED: redirected → pid ALIVE, comm==COMM, starttime OK.
    "$bin" "$dur" </dev/null >/dev/null 2>&1 &
    pid="$!"
    # Settle: poll until execve completes and comm flips to "$comm_name" (fork→exec race window).
    tries=0
    while (( tries++ < 50 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [[ "$comm" == "$comm_name" ]] && break
        sleep 0.02
    done
    ABPOOL_SIM_BINS+=("$bin_dir")
    printf '%s\n' "$pid"
}
```

### Implementation Tasks (ordered)

```yaml
Task 1: EDIT test/validate.sh — replace the spawn_sim_owner block (header comment + function body)
  - LOCATE: the contiguous block beginning at the header-comment line
            "# spawn_sim_owner [SECONDS] — echo the PID ..." and ending at the function's closing
            brace "}" (the line after `printf '%s\n' "$pid"`), currently ~lines 103–141.
  - REPLACE: with the EXACT block in "Exact replacement" above.
  - PRESERVE byte-for-byte: the 3 unchanged internal lines (cp, chmod, the fd-detach comment block,
            the launch line, pid=$!, the tries/while/sleep structure, ABPOOL_SIM_BINS+=, printf).
  - DO NOT TOUCH: the mktemp dir prefix "abpool-pi.XXXXXX" (ONLY the bin filename generalizes).
  - DO NOT TOUCH: any caller (validate.sh:197; release_reaper.sh:157,238; concurrency.sh:233,383;
            transparency.sh:162,433,439,478,483). They are all zero-comm-arg → default "pi".
  - DO NOT TOUCH: lib/pool.sh, the 5 pre-existing shellcheck info findings, transparency.sh:528
            (that's P3.M2.T1.S3 / P3.M1.T1.S3 scope).

Task 2: STATIC VALIDATE (no suite run — AGENTS.md §1)
  - RUN: bash -n test/validate.sh                # expect rc 0
  - RUN: shellcheck -S warning -s bash test/validate.sh   # expect rc 0 (warnings/errors clean)
  - RUN: shellcheck -s bash test/validate.sh 2>&1 | grep -E '^In test/validate.sh' | wc -l
          # expect 5 (the pre-existing info findings); confirm NONE in the edited region.
  - RUN: grep -rn 'spawn_sim_owner' test/*.sh | grep -E '\(spawn_sim_owner' \
          # sanity: confirm no caller was accidentally changed (all still zero-arg).

Task 3: (OPTIONAL, isolated micro-check ONLY if desired — last resort, never required)
  - If you must empirically confirm comm flips: a timeout-bounded, HOME/temps-isolated snippet that
    sources validate.sh, calls `pid="$(spawn_sim_owner 3 claude)"`, reads `/proc/$pid/comm`, asserts
    "claude", then kills+waits $pid and removes its temp bin dir. Wrap in `timeout 10` and a trap.
    Prefer NOT to run it — the static + kernel-basename reasoning is authoritative.
```

### Implementation Patterns & Key Details
```bash
# The guard — rc-safe under set -e (arithmetic in `if` is errexit-exempt; printf/assign are rc 0):
if (( ${#comm_name} > 15 )); then
    printf 'spawn_sim_owner: comm name truncated to 15 chars (TASK_COMM_LEN): %s -> %s\n' \
        "$comm_name" "${comm_name:0:15}" >&2
    comm_name="${comm_name:0:15}"
fi

# The generalize-but-keep-prefix pattern (the whole change in two lines):
bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"   # dir PREFIX unchanged (trap glob backstop)
bin="$bin_dir/$comm_name"                     # bin FILENAME generalized
```

### Integration Points
```yaml
DOWNSTREAM CONSUMER: P3.M2.T1.S2 (new selftest_owner_resolves_non_pi_harness)
  - will call: spawn_sim_owner 600 claude   (positive: recognized non-pi harness)
  - will call: spawn_sim_owner 600 xterm    (negative: unrecognized comm)
  - this item MUST land before S2; S2 depends on the new [COMM] positional existing.

NO config / NO routes / NO migrations / NO user docs (test-internal helper only).
```

---

## Validation Loop

### Level 1: Syntax & Style (run after the edit; STATIC ONLY — AGENTS.md §1)
```bash
bash -n test/validate.sh                                   # rc 0
shellcheck -S warning -s bash test/validate.sh             # rc 0
# Full picture (5 pre-existing info findings are expected & out of scope):
shellcheck -s bash test/validate.sh 2>&1 | grep -E '^In test/validate.sh'
#   expect exactly: lines 29, 578, 608, 638, 670 (SC1091 / SC2016, all info) — NONE in 103–141.
```
Expected: rc 0 for `bash -n` and for `shellcheck -S warning`. If a NEW finding appears in the
edited region, fix it before proceeding. Do NOT "fix" the 5 pre-existing info findings.

### Level 2: Unit / component
None at this subtask — the new comm path is exercised by P3.M2.T1.S2's selftest. The default-"pi"
path is already covered by every existing caller once the suite runs (not run here).

### Level 3: Integration
**DO NOT RUN THE SUITE.** `test/*.sh` boot a real windowed Chrome (PRD §2.18); AGENTS.md §1 forbids
that in planning. Integration proof of non-pi owners is P3.M2.T1.S2's job.

### Level 4: Reaping discipline (process hygiene — AGENTS.md §3)
This subtask adds no live execution. If you ran the OPTIONAL Task 3 micro-check, before ending:
```bash
pgrep -af 'abpool-pi|/usr/bin/sleep' || true     # expect empty
ls -d /tmp/abpool-pi.* 2>/dev/null || true       # expect empty
```
Kill+wait any PID you spawned; remove any `/tmp/abpool-pi.*` dir you created.

---

## Final Validation Checklist

### Technical Validation
- [ ] `bash -n test/validate.sh` → rc 0.
- [ ] `shellcheck -S warning -s bash test/validate.sh` → rc 0.
- [ ] No NEW shellcheck finding in the edited region (pre-existing 5 info findings untouched).

### Feature Validation
- [ ] New signature `spawn_sim_owner [SECONDS] [COMM]`, `COMM` default `"pi"`.
- [ ] 15-char guard present: warns + truncates when `${#comm_name} > 15`.
- [ ] `bin="$bin_dir/$comm_name"`; `mktemp -d -t abpool-pi.XXXXXX` **prefix unchanged**.
- [ ] Settle loop compares `[[ "$comm" == "$comm_name" ]]`.
- [ ] grep confirms zero callers changed (all still zero-arg → default "pi" → backward compatible).
- [ ] Header comment describes `[COMM]` + the truncation guard and no longer says "requires 'pi'".

### Scope Discipline
- [ ] Only `test/validate.sh` touched; only the spawn_sim_owner block edited.
- [ ] `lib/pool.sh`, `release_reaper.sh`, `concurrency.sh`, `transparency.sh` NOT modified.
- [ ] No test suite executed; no Chrome booted; no orphan processes/temp dirs left.

---

## Anti-Patterns to Avoid
- ❌ Don't substitute `$comm_name` into the `mktemp -t abpool-pi.XXXXXX` template — the trap's
  `/tmp/abpool-pi.*` glob backstop would stop reaping non-pi owner dirs → temp-dir leak (AGENTS.md §3).
- ❌ Don't skip the 15-char guard — a long harness name would make the settle loop never match and
  silently return an un-settled pid → flaky `pool_owner_alive` downstream.
- ❌ Don't run the suite "to be sure" (AGENTS.md §1 — planning phase; the suite boots real Chrome).
- ❌ Don't "fix" the 5 pre-existing `info`-level shellcheck findings — they are intentional and out
  of scope; chasing a bare `shellcheck … rc 0` there would expand scope and risk regressions.
- ❌ Don't reference `pool_owner_alive` by line number in the header comment (line numbers drift) —
  reference it by name.
- ❌ Don't add `local x="$(…)"` combined-declaration patterns (SC2155) — the existing style declares
  all locals in one bare `local` line; follow it.

---

## Confidence Score
**9/10.** The change is mechanical, confined to one function, fully specified with exact old→new
text, and validated by static checks that are verified runnable in this tree. The −1 is residual
empirical risk that `comm=="$comm_name"` settles correctly for a *non-pi* name — but the kernel's
ELF-basename rule is host-verified for `pi` and is name-agnostic, and P3.M2.T1.S2's selftest will
prove it empirically under the isolated single-setup runner. No part of this subtask requires live
execution, so the planning-phase constraint introduces no risk to correctness.
