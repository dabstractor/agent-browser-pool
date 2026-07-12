# PRP — P1.M2.T1.S2: Robust starttime extraction from /proc/stat

---

## Goal

**Feature Goal**: Establish the **canonical, robust starttime extractor** for the
agent-browser-pool — the single source of truth that reads `/proc/<pid>/stat` and
extracts field 22 (`starttime`, clock ticks since boot) using a **parens-robust** method
immune to spaces in `comm`. This is the identity primitive that defeats PID recycling
(PRD §2.8: *"starttime defeats PID recycling into a new pi"*). Concretely: deliver
`_pool_get_starttime(pid)` and **consolidate** S1's already-landed `_pool_owner_starttime`
into a one-line delegating wrapper so the codebase holds exactly ONE starttime parser.

**Deliverable** (all in `lib/pool.sh`, inside the existing "Owner resolution" section):
1. **ADD** `_pool_get_starttime(pid)` — the canonical robust extractor: input-validated
   (`^[0-9]+$`), output-validated, parens-robust (`${stat_line##*)}` then `awk '{print $20}'`),
   never fatal. Returns 0 + echoes digits on success; returns 1 (no echo) for a
   missing/non-numeric PID or an unreadable/empty/garbled stat line.
2. **CONSOLIDATE** S1's `_pool_owner_starttime()` into a thin delegating wrapper
   (`_pool_get_starttime "$@"`) — preserving S1's exact I/O contract and all call sites
   inside `pool_owner_resolve` (which S1 already wired up). No duplication.
3. A definitive code comment on `_pool_get_starttime` explaining **why the PRD §2.19
   `NF-19` formula is wrong** (NF=52 on this host → NF-19 = field 33 = vsize, not
   starttime) and documenting the correct method (item requirement #5).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh`: `_pool_get_starttime "$$"` echoes a
  digit string that **exactly equals** `cut -d' ' -f22 /proc/$$/stat` (same process →
  exact match), and returns 0.
- `_pool_get_starttime <dead-pid>` returns 1, echoes nothing, and does NOT abort under
  `set -euo pipefail`.
- `_pool_get_starttime ""` / `_pool_get_starttime "abc"` return 1 (input validation),
  echo nothing, never fatal.
- `_pool_owner_starttime "$$"` returns the SAME value as `_pool_get_starttime "$$"`
  (delegation preserves behavior), and `pool_owner_resolve` continues to populate
  `POOL_OWNER_STARTTIME` correctly (S1 regression intact).
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources cleanly
  under `set -euo pipefail`; all prior deliverables (S1, S2, S3, T2.S1, M2.T1.S1)
  unchanged in behavior.
- Exactly ONE starttime parser exists in the file (no duplicated logic).

## User Persona

**Target User**: Internal only — no end user or operator ever calls `_pool_get_starttime`
directly. Its consumers are:

- **`pool_owner_resolve()`** (S1, already landed) — calls `_pool_owner_starttime` (which
  now delegates here) to record `POOL_OWNER_STARTTIME` when resolving the owning `pi`
  process (PRD §2.4 step 1, §2.8).
- **`is_owner_alive(pid, starttime)`** (P1.M2.T2.S1, planned) — calls `_pool_get_starttime`
  DIRECTLY to read a lease owner PID's *current* starttime and compare it to the stored
  value; a mismatch means the PID was recycled into a different process (PRD §2.8,
  §2.19, key_findings FINDING 1). This is why the canonical name is `_pool_get_starttime`
  (general-purpose, any PID) rather than `_owner_starttime` (scoped to owner resolution).
- **`find_my_lease` / `is_lane_stale`** (P1.M3.T2) — consume the resolved+stored
  starttime via the lease JSON; the (pid, starttime) pair is the anti-recycling key.

**Use Case**: Every lease-affinity and staleness decision in the pool ultimately depends
on a correct starttime read. This function is the ONE place that read happens.

**Pain Points Addressed**:
- A naive `awk '{print $22}'` breaks when `comm` contains spaces (field 2 is
  parenthesized), shifting every later field. The parens-robust method fixes this for
  ANY comm.
- The PRD §2.19 `NF-19` formula is empirically WRONG on this host (yields field 33 =
  vsize, not starttime). This function documents and uses the correct method, eliminating
  a latent correctness bug that would have made `is_owner_alive` mis-detect recycling.

## Why

- **Correctness of the anti-PID-recycling key.** PID recycling is the central threat the
  starttime field exists to defeat (PRD §2.8, §2.19). If starttime extraction is wrong
  (e.g. returns vsize), `is_owner_alive` would either always-match (recycled PID
  accepted → lane theft) or never-match (live owner treated as stale → constant reaping).
  Getting this ONE function right is a load-bearing correctness requirement for M2.T2.S1
  and M3.T2.
- **Eliminate parser duplication.** S1 shipped `_pool_owner_starttime` as a self-contained
  fallback (it could not assume S2 would land first under parallel execution). S2 owns the
  canonical function. Without consolidation we'd have two parsers; with it, one. The
  parallel-context rule ("do NOT duplicate") and S1's own Integration-Points note
  ("P1.M2.T1.S2 may harden _pool_owner_starttime... MUST preserve this contract") both
  point to delegation as the correct, contract-preserving consolidation.
- **Make the extractor GENERAL.** `_pool_owner_starttime` was named/scoped to owner
  resolution. `is_owner_alive` needs to read the starttime of an ARBITRARY lease-owner PID
  (not just the current shell's owner). The canonical `_pool_get_starttime` serves both,
  and its input/output validation makes it safe to call on any PID-shaped input.

## What

User-visible behavior: none directly (internal library function + a comment). Observable
contract:

| `_pool_get_starttime` args | Echoes | Return | Fatal? |
|---|---|---|---|
| `<live-pid>` (numeric) | digits (field 22) | 0 | never |
| `<dead-pid>` (numeric, /proc missing) | nothing | 1 | never |
| non-numeric / empty (`""`, `"abc"`) | nothing | 1 (input validation) | never |
| numeric PID but stat line garbled / no field 20 | nothing | 1 (output validation) | never |

| `_pool_owner_starttime` (after consolidation) | Behavior |
|---|---|
| any args | delegates exactly: `_pool_get_starttime "$@"`. Identical I/O to S1's original (echo digits/0, or 1/no-echo, never fatal). `pool_owner_resolve`'s call sites unchanged. |

### Success Criteria

- [ ] `_pool_get_starttime` is defined in `lib/pool.sh` and callable after `source lib/pool.sh`.
- [ ] `_pool_get_starttime "$$"` echoes a `^[0-9]+$` string that **exactly equals**
  `cut -d' ' -f22 /proc/$$/stat` (both read the SAME `$$` process), return 0.
- [ ] `_pool_get_starttime <dead-pid>` (e.g. `999999999`) returns 1, echoes nothing, does
  NOT abort under `set -euo pipefail`.
- [ ] `_pool_get_starttime ""` and `_pool_get_starttime "abc"` return 1 (input validation),
  echo nothing, never fatal.
- [ ] `_pool_get_starttime` uses the PARENS-ROBUST extraction (`${stat_line##*)}` greedy
  strip then `awk '{print $20}'`), NOT a naive `awk '{print $22}'` and NOT the PRD §2.19
  `NF-19` formula.
- [ ] `_pool_get_starttime` carries a leading comment explaining WHY NF-19 is wrong
  (NF=52 here → field 33 = vsize) and documenting the correct method (item req. #5).
- [ ] `_pool_owner_starttime` is reduced to a one-line delegating wrapper
  (`_pool_get_starttime "$@"`); its I/O contract is unchanged.
- [ ] `pool_owner_resolve` (S1) STILL populates `POOL_OWNER_STARTTIME` correctly after the
  consolidation (delegation regression: `_pool_owner_starttime "$$"` ==
  `_pool_get_starttime "$$"`).
- [ ] Exactly ONE starttime parser body exists (the `_pool_get_starttime` body); the
  `_pool_owner_starttime` body contains no parsing logic, only the delegation call.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources
  cleanly under `set -euo pipefail`.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified `/proc/stat`
field layout (52 fields; field 22 = starttime; the three correct methods agree at ~8283368;
NF-19 = 4096 = field 33 vsize = WRONG; CLK_TCK = 100); the exact field-offset arithmetic
(overall 22 == field 20 of the post-`)` remainder, because stripping `pid (comm)` removes
exactly 2 fields); the exact S1/S2 consolidation strategy (delegation, not duplication) with
the rationale; the paste-ready `_pool_get_starttime` body with all `set -euo pipefail`
guards baked in; the exact `edit`-ready oldText/newText for converting `_pool_owner_starttime`
to a wrapper; the S1 regression contract to preserve; the ±1-tick red-herring warning (test
with `$$`, not `/proc/self`); and copy-pasteable validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.8 (lease model — "starttime ... defeats PID recycling into a new pi"; the
        owner.starttime field this extractor feeds), §2.19 (Implementation notes — the
        WRONG NF-19 formula this task corrects: "Read starttime from the right (field 22
        from the start → index NF-19)"). §2.4 step 1 (resolve OWNER records starttime).
  pattern: §2.8 owner object carries starttime; §2.19 documents the (buggy) parsing
        gotcha this task fixes.
  gotcha: §2.19's "NF-19" is empirically WRONG on this host (NF=52 → field 33, not 22).
        key_findings FINDING 1 + system_context §6.1 + this task's own verification all
        correct it: strip-to-last-paren then field 20 of remainder. USE THE PARENS METHOD.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §6 ("/proc Parsing — CRITICAL FINDING"): starttime is field 22; the NF-19 approach
        is WRONG; the correct robust method is `sed 's/.*)//' /proc/<pid>/stat | awk
        '{print $20}'` (removes everything up to last ')', then field 20 = 22-2).
        Recommends Method 2 (parens-aware) "for maximum robustness."
  pattern: §6.1 Method 2 is the direct ancestor of _pool_get_starttime's parse.
  gotcha: §6.1 notes "The comm field for pi is just 'pi' (no spaces), so Method 1
        [cut -f22] also works, but Method 2 is defensive." USE METHOD 2 (defensive).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 1 (starttime parsing — the NF-19 bug + the correct parens-strip method,
        verified on this host), the "Function Naming Convention" (`_pool_*` = internal
        helper; the canonical `_pool_get_starttime` matches this convention and the
        item description's mandated name).
  pattern: FINDING 1's `sed 's/.*)//' | awk '{print $20}'` is the reference command.
  gotcha: the naive `awk '{print $22}'` is unsafe when comm has spaces; the NF-19
        formula assumes a fixed NF=41 that does not hold (real NF=52).

- file: plan/001_0f759fe2777c/P1M2T1S1/PRP.md   # S1 — the prior task (CONTRACT)
  why: S1 ALREADY LANDED `_pool_owner_starttime(pid)` and `pool_owner_resolve()` in
        lib/pool.sh. S1's _pool_owner_starttime has the exact contract this task must
        PRESERVE via delegation: echo digits/return 0, or return 1/no-echo, never fatal,
        parens-robust. S1's Integration Points note explicitly anticipates S2: "P1.M2.T1.S2
        (robust starttime extraction): MAY harden _pool_owner_starttime... If S2 replaces
        the body, it MUST preserve this contract." pool_owner_resolve calls
        _pool_owner_starttime at TWO sites (TEST MODE override block + REAL MODE result
        block) — delegation leaves both untouched.
  pattern: S1's _pool_owner_starttime body is the parsing logic to extract into
        _pool_get_starttime (with added input/output validation); the wrapper keeps S1's
        name + contract.
  gotcha: do NOT touch pool_owner_resolve's body (zero changes there). Only _pool_owner_starttime
        becomes a one-line wrapper. This is the no-duplication consolidation.

- file: plan/001_0f759fe2777c/P1M2T1S1/research/proc-parsing-and-ppid-walk.md
  why: S1's research §1.4 (host-verified starttime values, the parens-strip method),
        §2 (the set -euo pipefail traps table), §5 (the S1/S2 task boundary + the note
        that "S2 replaces/augments that extractor with a more robust version").
  pattern: the strict-mode traps (SC2155 two-statement locals; `cat ... 2>/dev/null || true`;
        `[[ =~ ]]` inside `if`).
  gotcha: none beyond the NF-19 correction.

- file: plan/001_0f759fe2777c/P1M2T1S2/research/starttime-extraction-and-consolidation.md
  why: THIS task's own research — the host-verified field facts (§1), the field-offset
        arithmetic (§2), the consolidation decision + rationale (§3), the ±1-tick test
        red herring (§4), the strict-mode traps (§5).
  pattern: §3 mandates delegation (option a) over editing pool_owner_resolve (option b).

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 (scaffolding) created lib/pool.sh with `set -euo pipefail` (line 1, propagates
        to callers), `pool_die()`, `_pool_log()`. _pool_get_starttime does NOT call
        pool_die (it is a 0/1 extractor) and does NOT log (leaf function).
  gotcha: S1's set -e means every failing command that is a SIGNAL not a failure
        (`cat /missing`, standalone `[[ =~ ]]`) MUST be guarded (`|| true` or inside `if`).

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 (config) delivered pool_config_init + POOL_* globals. _pool_get_starttime reads
        NO POOL_* globals (pure /proc function), so it needs no config — but callers run
        pool_config_init first for realism.

- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md
  why: S3 (state) delivered pool_state_init/pool_check_btrfs/pool_check_master. Not called
        here. Regression-checked at the end.

- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md
  why: T2.S1 delivered _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str. Not
        called here. Regression-checked at the end.

# External authoritative docs (for the HOW)
- url: https://man7.org/linux/man-pages/man5/proc.5.html
  why: authoritative /proc/[pid]/stat field table — field 2 (comm) is parenthesized and
        may contain spaces; field 22 (starttime) is "The time the process started after
        system boot ... in clock ticks."
  critical: ON THIS HOST (verified 2026-07-12): /proc/self/stat has 52 fields; field 22
        = starttime (~8283368 ticks); getconf CLK_TCK = 100. comm-in-parens shifts later
        fields if it contains spaces — hence the parens-strip.
  section: "/proc/[pid]/stat" (field table, entries 1..52).

- url: https://www.kernel.org/doc/html/latest/filesystems/proc.html
  why: the kernel's own proc.rst — canonical field table (confirms comm-in-parens + the
        field numbering and that starttime is field 22).
  section: "Process-specific subdirectories" → /proc/[pid]/stat table.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` so cmd's exit status is
        not masked (matters for `cat /proc/$pid/stat`).
  critical: every `local` capture must be two-statement form.

- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: `${1:-}` (set -u safe default for the positional arg), `${stat_line##*)}` (GREEDY
        longest-prefix strip up to & incl. the LAST `)`).
  critical: `${var##pattern}` is the GREEDY form (required to reach the LAST `)` even if
        comm itself contains `)` — extremely rare but the greedy form is correct).
        `${var#pattern}` (single #) is NON-greedy and would stop at the FIRST ')'.

- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: `set -e` exemptions — the condition of `if`/`&&`/`||` and the inside of `[[ ]]`
        in those conditions are EXEMPT from errexit. A standalone failing `[[ =~ ]]`
        aborts; inside `if [[ ! ... ]]` it is safe.
  section: errexit (`-e`).
```

### Current Codebase tree

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep
├── lib/
│   └── pool.sh                           # S1 header + set -euo pipefail + pool_die + _pool_log
│                                         #   + S2 _pool_config_* + pool_config_init
│                                         #   + S3 pool_state_init/pool_check_btrfs/pool_check_master
│                                         #   + T2.S1 _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str
│                                         #   + M2.T1.S1 _pool_owner_starttime + pool_owner_resolve  ← LANDED
├── test/.gitkeep
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1/{PRP.md, research/bash-library-research.md}
    ├── P1M1T1S2/{PRP.md, research/bash-config-init-research.md}
    ├── P1M1T1S3/{PRP.md, research/btrfs-findmnt-host-facts.md}
    ├── P1M1T2S1/{PRP.md, research/{atomic-write-jq-date-semantics.md, helper-function-reference-impl.md}}
    ├── P1M2T1S1/{PRP.md, research/{proc-parsing-and-ppid-walk.md, reference-impl.md}}
    └── P1M2T1S2/                          # THIS subtask
        ├── PRP.md                          # THIS FILE
        └── research/starttime-extraction-and-consolidation.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — in the "Owner resolution" section:
                  #   * INSERT _pool_get_starttime(pid) (canonical robust extractor)
                  #   * REPLACE _pool_owner_starttime body → one-line delegating wrapper
                  #   (pool_owner_resolve unchanged)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
makes `_pool_get_starttime` the canonical starttime parser and routes S1's
`_pool_owner_starttime` through it. Net effect: one parser, two entry names (the general
`_pool_get_starttime` for `is_owner_alive`/future code; the `_owner`-scoped alias S1
already wired into `pool_owner_resolve`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (PRD §2.19 is WRONG; key_findings FINDING 1 + system_context §6.1 correct it):
# /proc/<pid>/stat field 2 (comm) is wrapped in parens and MAY contain spaces, shifting
# every subsequent field. The PRD's "NF-19" formula assumes a fixed field count (41) but
# the real count on this host is 52, so NF-19 = field 33 (= vsize ≈ 4096), NOT field 22
# (starttime ≈ 8.28M ticks). VERIFIED THIS SESSION: NF-19 yields 4096 (WRONG) while
# cut -f22, awk $22, and the parens-strip method all yield ~8283368 (CORRECT). Use the
# parens-strip: `${stat_line##*)}` (greedy, to the LAST ')') then `awk '{print $20}'`.
# After stripping "pid (comm)" (fields 1+2), overall field 22 == field 20 of the
# remainder (offset −2).

# CRITICAL (the ±1-tick red herring): each separate shell command reading /proc/self/stat
# reads a DIFFERENT process (the command's own PID). Two such processes spawned microseconds
# apart can have starttimes differing by 1 tick (10 ms at CLK_TCK=100). This is NOT a
# parsing bug. When ASSERTING equality in tests, compare against the SAME process: use
# `_pool_get_starttime "$$"` vs `cut -d' ' -f22 /proc/$$/stat` within ONE shell — $$ is
# stable, so they match EXACTLY. Do NOT compare two independent /proc/self reads.

# CRITICAL (set -e + cat /missing): `stat_line="$(cat "/proc/$pid/stat")"` whose cat FAILS
# (vanished /proc entry, EACCES) returns non-zero and ABORTS under set -e (propagated by
# S1). ALWAYS: `stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true`. The
# 2>/dev/null suppresses the shell's "No such file" message; `|| true` neutralizes the
# exit status. stat_line stays "" on failure → the `[[ -z ]]` guard returns 1.

# CRITICAL (set -e + standalone [[ =~ ]]): a bare `[[ "$v" =~ ^[0-9]+$ ]]` that fails to
# match returns 1 and ABORTS under set -e. ALWAYS use it inside `if [[ ! ... ]]; then
# return 1; fi` (the condition of `if` is errexit-exempt).

# CRITICAL (SC2155): `local x="$(cmd)"` masks cmd's exit status (and under set -e hides
# failures). ALWAYS: `local x; x="$(cmd)"` — two statements. This matters for the
# `cat /proc/$pid/stat` and `awk '{print $20}'` captures.

# GOTCHA (${1:-} under set -u): the function's first arg may be unset (called with no
# args). Use `local pid="${1:-}"` then validate with `[[ "$pid" =~ ^[0-9]+$ ]]`, NOT bare
# `$1` (which aborts under set -u when no arg is passed).

# GOTCHA (##*  ) is GREEDY by design): `${stat_line##*)}` removes the LONGEST prefix
# ending in ')' — required to reach the LAST ')' even if comm itself contains ')'. Do NOT
# use the single-# form `${stat_line#*)}` (non-greedy, stops at first ')').

# GOTCHA (delegation must PRESERVE S1's contract): _pool_owner_starttime (after conversion
# to a wrapper) must STILL: echo digits/return 0 on success, return 1 (no echo) on failure,
# NEVER call pool_die, NEVER exit the process. Since it delegates to _pool_get_starttime
# (which has the same contract), this holds automatically. pool_owner_resolve's call sites
# (`st="$(_pool_owner_starttime ...)" || true; [[ -n "$st" ]]`) are unchanged.

# GOTCHA (do NOT duplicate the parser): the file must end with exactly ONE starttime
# parsing body (in _pool_get_starttime). _pool_owner_starttime's body must be ONLY the
# delegation call — no `cat`, no `awk`, no `${...##*)}`. Two parsers = a maintenance
# hazard and violates the parallel-task no-duplication rule.

# GOTCHA (do NOT touch pool_owner_resolve): the consolidation changes ONLY
# _pool_owner_starttime's body. pool_owner_resolve keeps calling _pool_owner_starttime at
# its two existing sites (TEST MODE + REAL MODE). Editing pool_owner_resolve is out of
# scope and unnecessary (delegation makes the change transparent to it).

# GOTCHA (scope): this task is the starttime EXTRACTOR + consolidation ONLY. Do NOT:
# implement is_owner_alive (that's P1.M2.T2.S1 — liveness + starttime-recycling check);
# change POOL_OWNER_* population logic (that's pool_owner_resolve, unchanged); scan
# leases / acquire lanes / enter passthrough (M3/M5/M6).
```

## Implementation Blueprint

### Data models and structure

No JSON, no on-disk schema, no new globals. This subtask defines/changes two FUNCTIONS
in the existing "Owner resolution" section of `lib/pool.sh`:

| Symbol | Kind | Visibility | Change | Consumed by |
|---|---|---|---|---|
| `_pool_get_starttime` | function (echoes digits / returns 0\|1) | internal (`_pool_`) | **NEW** (canonical) | pool_owner_resolve (via wrapper), is_owner_alive (M2.T2.S1, direct), future code |
| `_pool_owner_starttime` | function (echoes digits / returns 0\|1) | internal (`_pool_`) | **CHANGED** → 1-line wrapper | pool_owner_resolve (S1, unchanged call sites) |

**Naming**: matches key_findings.md "Function Naming Convention" — `_pool_*` = internal
helper. `_pool_get_starttime` is the general-purpose canonical name (the item description
mandates it; `is_owner_alive` needs a PID-agnostic extractor, not an owner-scoped one).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ and confirm the starting state
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type _pool_owner_starttime pool_owner_resolve _pool_get_starttime' 2>&1
  - EXPECT: _pool_owner_starttime and pool_owner_resolve reported as functions.
        _pool_get_starttime reported as NOT FOUND (this task creates it). If
        _pool_get_starttime ALREADY exists (another agent landed it), STOP and reconcile
        — do not define it twice.
  - RUN (locate S1's _pool_owner_starttime for the edit):
        grep -n '_pool_owner_starttime()' lib/pool.sh
  - EXPECT: exactly ONE definition line (S1's). Note its line number.
  - RUN (confirm the file is otherwise clean):
        bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: INSERT _pool_get_starttime(pid) — the canonical robust extractor
  - PLACEMENT: inside the "Owner resolution" section, DIRECTLY ABOVE the existing
        `_pool_owner_starttime()` definition (so the canonical helper precedes its
        wrapper; logical grouping). Update the section banner comment to credit both
        M2.T1.S1 and M2.T1.S2.
  - IMPLEMENT (verbatim-ready — paste this function body):
        _pool_get_starttime() {
            # _pool_get_starttime PID
            #
            # THE CANONICAL starttime extractor for the pool. Echo the process starttime
            # (/proc/<pid>/stat field 22, clock ticks since boot; CLK_TCK=100 on this
            # host) for PID. Returns 0 + echoes a digits-only string on success; returns
            # 1 (NOT fatal, echoes nothing) if PID is empty/non-numeric, or
            # /proc/<pid>/stat is absent/unreadable, or the parsed value is not an integer.
            #
            # CONSUMERS:
            #   - pool_owner_resolve()  → records POOL_OWNER_STARTTIME (PRD §2.4 step 1, §2.8),
            #     via the _pool_owner_starttime() wrapper below.
            #   - is_owner_alive() (P1.M2.T2.S1) → reads a lease owner's CURRENT starttime
            #     and compares to the stored value; a mismatch means the PID was recycled
            #     (PRD §2.8, §2.19). The (pid, starttime) pair is the anti-recycling key.
            #
            # WHY THE PRD §2.19 "NF-19" FORMULA IS WRONG (key_findings FINDING 1,
            # system_context §6.1, host-verified 2026-07-12):
            #   /proc/<pid>/stat field 2 is comm, wrapped in parens:  "<pid> (<comm>) <state> ..."
            #   comm MAY contain spaces (e.g. "(Chrome Helper)"), shifting every later field,
            #   so a naive left-to-right `awk '{print $22}'` is unsafe in general. The PRD
            #   tried to read "from the right": field 22 from the start == index NF-19. That
            #   formula assumes a FIXED total field count of 41. On this host the real count
            #   is 52, so NF-19 == field 33 — which is vsize (≈ 4096), NOT starttime. The
            #   total count is NOT fixed across kernel versions / process states, so any
            #   NF-based offset is inherently fragile. Verified: `awk '{print $(NF-19)}'
            #   /proc/self/stat` = 4096 (WRONG) vs the correct field-22 starttime ≈ 8283368.
            #
            # THE CORRECT ROBUST METHOD:
            #   Strip "pid (comm)" by deleting everything up to AND INCLUDING the LAST ')'
            #   (greedy), collapsing any spaces inside comm. That removes exactly fields 1
            #   (pid) + 2 (comm), so overall field N == field (N-2) of the remainder.
            #   starttime (field 22) therefore falls at field 20 of the remainder (22-2=20).
            #   Pure bash (preferred — no extra fork; we already hold the line in a var):
            #       after="${stat_line##*)}"        # GREEDY longest prefix up to last ')'
            #       start="$(awk '{print $20}' <<<"$after")"
            #   Shell-pipeline equivalent (what the PRD/arch docs cite — IDENTICAL result):
            #       sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'
            #   Verified agreement (comm='pi'/'bash'/'cat'/'head', no spaces): all three
            #   methods yield the same starttime.
            local pid="${1:-}"
            local stat_line after start
            # Input validation: a non-numeric / empty PID is a clean "no value" (return 1),
            # never fatal. `[[ =~ ]]` inside `if` is errexit-exempt.
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                return 1
            fi
            # `cat ... 2>/dev/null || true`: a vanished / permission-denied /proc entry is a
            # clean "process dead" signal (return 1), NOT a set -e abort. SC2155: two-stmt.
            stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
            if [[ -z "$stat_line" ]]; then
                return 1
            fi
            # Drop "pid (comm)" — GREEDY strip to & incl. the LAST ')'.
            after="${stat_line##*)}"
            start="$(awk '{print $20}' <<<"$after")"   # field 22 overall == field 20 here
            # Output validation: guard a truncated/garbled stat line. Return 1 (no echo),
            # never fatal.
            if [[ ! "$start" =~ ^[0-9]+$ ]]; then
                return 1
            fi
            printf '%s\n' "$start"
        }
  - FOLLOW pattern: `local pid="${1:-}"` (set -u safe for a possibly-missing arg);
        `local x; x="$(...)"` two-statement (SC2155); every `[[ =~ ]]` inside `if`;
        `cat ... 2>/dev/null || true` for the /proc read; NEVER pool_die.
  - GOTCHA: use `${stat_line##*)}` (DOUBLE #, greedy) NOT `${stat_line#*)}` (single #,
        non-greedy — stops at the first ')' and is WRONG if comm contains ')').
  - NAMING: _pool_get_starttime (internal, canonical — the item-mandated name).
  - PLACEMENT: directly above the existing _pool_owner_starttime() definition.

Task 2: CONVERT _pool_owner_starttime into a one-line delegating wrapper (NO duplication)
  - WHY: S1 already landed _pool_owner_starttime (a full parser). pool_owner_resolve calls
        it at two sites. Rather than maintain TWO parsers, reduce S1's function to a thin
        wrapper that delegates to the canonical _pool_get_starttime. The I/O contract
        (echo digits/0, or 1/no-echo, never fatal) is preserved EXACTLY.
  - METHOD: use the edit tool to REPLACE S1's entire _pool_owner_starttime body with the
        delegation. The exact oldText is S1's current body (grep -n to locate it). The
        newText is:
        _pool_owner_starttime() {
            # Thin delegating wrapper preserved for S1's pool_owner_resolve() call sites.
            # The canonical parser is _pool_get_starttime() above (P1.M2.T1.S2); keeping
            # this alias means there is exactly ONE starttime parser in the codebase while
            # pool_owner_resolve's existing `_pool_owner_starttime "$ovr_pid"` calls stay
            # unchanged. I/O contract unchanged: echo digits/return 0, or return 1
            # (no echo), never fatal.
            _pool_get_starttime "$@"
        }
  - FOLLOW pattern: keep S1's function NAME and signature; replace only the BODY.
  - GOTCHA: do NOT delete the comment block above _pool_owner_starttime's def line unless
        it is the S1 internal body comment (the section banner "Owner resolution" stays).
        Keep the function name line `_pool_owner_starttime() {` and its closing `}`.
  - GOTCHA: do NOT touch pool_owner_resolve() at all (zero changes). Its two call sites
        (`st="$(_pool_owner_starttime "$ovr_pid" 2>/dev/null)" || true` in TEST MODE and
        `st="$(_pool_owner_starttime "$found_pid" 2>/dev/null)" || true` in REAL MODE)
        keep working transparently.
  - NAMING: _pool_owner_starttime (S1's name, now an alias).
  - PLACEMENT: immediately after _pool_get_starttime (where S1's version already sits).

Task 3: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (both functions defined; wrapper delegates):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type _pool_get_starttime _pool_owner_starttime' >/dev/null && echo OK
        # EXPECT: OK (both functions exist).
  - RUN (canonical: echoes digits for $$; EXACT agreement with cut -f22, same process):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 a="$(_pool_get_starttime "$$")"; b="$(cut -d" " -f22 /proc/$$/stat)"; \
                 [[ "$a" == "$b" && "$a" =~ ^[0-9]+$ ]] && echo "OK canon=$a" \
                   || { echo "FAIL a=$a b=$b"; exit 1; }'
        # EXPECT: OK canon=<digits>. ($$ is stable within the one shell → exact match.
        #       Do NOT compare two independent /proc/self reads — see the red-herring note.)
  - RUN (wrapper delegates: _pool_owner_starttime == _pool_get_starttime for the same PID):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 w="$(_pool_owner_starttime "$$")"; c="$(_pool_get_starttime "$$")"; \
                 [[ "$w" == "$c" ]] && echo "OK wrapper-delegates=$w" \
                   || { echo "FAIL wrapper=$w canon=$c"; exit 1; }'
        # EXPECT: OK wrapper-delegates=<digits>. (Proves S1's call sites now route through
        #       the canonical parser; the wrapper adds no divergence.)
  - RUN (dead PID → return 1, no echo, no abort under set -e):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_get_starttime 999999999; then echo "FAIL: dead pid returned 0"; \
                 else echo "OK: dead pid → return 1"; fi'
        # EXPECT: OK: dead pid → return 1 (and NO output from the function itself).
  - RUN (dead PID via the wrapper too — S1 contract preserved):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_owner_starttime 999999999; then echo "FAIL"; \
                 else echo "OK: wrapper dead pid → return 1"; fi'
        # EXPECT: OK: wrapper dead pid → return 1.
  - RUN (input validation: empty + non-numeric → return 1, no echo, never fatal):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_get_starttime "" ; e=$?; \
                 _pool_get_starttime "abc"; n=$?; \
                 if (( e == 1 && n == 1 )); then echo "OK input-validation"; \
                 else echo "FAIL e=$e n=$n"; exit 1; fi'
        # EXPECT: OK input-validation. (Bare (( )) would be fatal if result 0 — here it is
        #       inside `if`, so errexit-exempt.)
  - RUN (parens-robust MATH proof on a CRAFTED multi-space comm — proves field 22 == field 20
        of the post-paren remainder even when comm has spaces; this is the core robustness
        claim that a real pi/bash comm can't exercise because their comm has no spaces):
        bash -c '
            line="4242 (Chrome Helper Renderer) S 1 1 1 0 -1 4194304 5 0 0 0 0 0 0 0 20 0 1 0 7777777 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
            # field 22 overall should be 7777777 (placed there by construction)
            pure="$({ read -r _; after="${line##*)}"; printf "%s\n" "$after"; } <<<"$line" | awk "{print \$20}")"
            sed="$(sed "s/.*)//" <<<"$line" | awk "{print \$20}")"
            naive="$(awk "{print \$22}" <<<"$line")"
            echo "pure-bash=$pure sed=$sed naive=$naive (expect pure=sed=7777777; naive MISMATCHES due to 2 extra comm words)"
            [[ "$pure" == "7777777" && "$sed" == "7777777" ]] && echo "OK robust-method-correct" || { echo FAIL; exit 1; }
        '
        # EXPECT: pure-bash=7777777 sed=7777777 naive=<something else, off by the comm spaces>,
        #       then OK robust-method-correct. This PROVES the parens-strip yields field 22
        #       while the naive method does not, validating the whole design.
  - RUN (S1 regression: pool_owner_resolve STILL populates POOL_OWNER_STARTTIME via the
        wrapper, and it matches an independent extraction — proves consolidation didn't
        break owner resolution):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
                 if [[ "$POOL_OWNER_PID" != "0" ]]; then \
                     indep="$(cut -d" " -f22 /proc/$POOL_OWNER_PID/stat)"; \
                     [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] \
                       && echo "OK s1-regression st=$POOL_OWNER_STARTTIME" \
                       || { echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; exit 1; }; \
                 else echo "SKIP (no pi ancestor — run under pi to exercise real mode)"; fi'
        # EXPECT (under pi): OK s1-regression st=<digits>.
        # EXPECT (plain shell): SKIP. (Under pi the ppid walk finds the pi ancestor; under a
        #       plain interactive shell there is no pi ancestor → passthrough, PID=0.)
  - RUN (S1 TEST-MODE regression: override still drives starttime through the wrapper):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 AGENT_BROWSER_POOL_OWNER_PID="$$" pool_owner_resolve; \
                 indep="$(cut -d" " -f22 /proc/$$/stat)"; \
                 [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] \
                   && echo "OK test-mode-via-wrapper=$POOL_OWNER_STARTTIME" \
                   || { echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; exit 1; }'
        # EXPECT: OK test-mode-via-wrapper=<digits>. ($$ is live → the wrapper extracts its
        #       real starttime. Proves pool_owner_resolve's TEST MODE path still works post-
        #       consolidation.)
  - RUN (exactly ONE parser body — grep for duplicated parsing primitives):
        # The canonical body has the parsing; the wrapper must NOT. Assert the wrapper body
        # is just the delegation call.
        bash -c '
            body="$(sed -n "/^_pool_owner_starttime() {/,/^}/p" lib/pool.sh)"
            if grep -qE "cat |awk|\$\{.*##\*\)" <<<"$body"; then
                echo "FAIL: wrapper still contains parsing logic:"; echo "$body"; exit 1
            fi
            grep -q "_pool_get_starttime \"\$@\"" <<<"$body" && echo "OK wrapper-is-pure-delegation" \
                || { echo "FAIL: wrapper missing delegation call"; exit 1; }
        '
        # EXPECT: OK wrapper-is-pure-delegation. (Guards against leaving two parsers.)
  - RUN (full-file regression: all prior functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime _pool_owner_starttime pool_owner_resolve \
                      >/dev/null && echo OK'
        # EXPECT: OK (all functions, including the two new/changed ones, callable).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the canonical extractor (paste into the Owner-resolution section,
#     directly ABOVE _pool_owner_starttime) ------------------------------------

_pool_get_starttime() {
    # [full comment block from Task 1 — documents NF-19 bug + correct method]
    local pid="${1:-}"
    local stat_line after start
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
    if [[ -z "$stat_line" ]]; then
        return 1
    fi
    after="${stat_line##*)}"
    start="$(awk '{print $20}' <<<"$after")"
    if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$start"
}

# --- Pattern: S1's function becomes a one-line delegating wrapper ------------
# (replace S1's FULL body with this; keep the function name + the section banner)

_pool_owner_starttime() {
    # Thin delegating wrapper preserved for S1's pool_owner_resolve() call sites.
    # The canonical parser is _pool_get_starttime() above (P1.M2.T1.S2); keeping this
    # alias means there is exactly ONE starttime parser in the codebase while
    # pool_owner_resolve's existing `_pool_owner_starttime "$pid"` calls stay unchanged.
    # I/O contract unchanged: echo digits/return 0, or return 1 (no echo), never fatal.
    _pool_get_starttime "$@"
}

# --- Critical micro-rules baked into the above --------------------------------
#  * `local pid="${1:-}"` — set -u safe for a called-with-no-args function.
#  * `local x; x="$(...)"` two-statement everywhere (SC2155; masks exit status under
#    set -e otherwise). Critical for `cat /proc/$pid/stat` and `awk '{print $20}'`.
#  * `cat "/proc/$pid/stat" 2>/dev/null || true` — vanished/EACCES /proc is a clean
#    "process dead" return-1, NOT a set -e abort.
#  * Every `[[ =~ ]]` is inside `if [[ ! ... ]]; then return 1; fi` — a standalone
#    failing match would abort under set -e.
#  * `${stat_line##*)}` is GREEDY (double #) — reaches the LAST ')' even if comm itself
#    contains ')'. NEVER the single-# non-greedy form.
#  * `awk '{print $20}'` of the post-paren remainder == overall field 22 (offset −2),
#    because stripping "pid (comm)" removes exactly 2 fields. Host-verified.
#  * NEVER pool_die / never exit — 0/1 extractor only. Callers treat 1/empty as
#    "process dead / identity unknown".
#  * The wrapper body contains NO parsing primitives (no cat/awk/${...##*)}) — only the
#    delegation call. One parser, two entry names.
```

### Integration Points

```yaml
PRIOR (S1 + S2 + S3 + T2.S1 + M2.T1.S1) — consumed, not modified except _pool_owner_starttime:
  - pool_die() / _pool_log() (S1): NOT called by _pool_get_starttime (a 0/1 leaf extractor;
        never fatal, never logs).
  - pool_config_init() + POOL_* (S2 config): NOT read by _pool_get_starttime (pure /proc).
  - _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (T2.S1): not called here.
  - _pool_owner_starttime (M2.T1.S1): CHANGED → one-line delegating wrapper. Contract
        preserved. pool_owner_resolve (M2.T1.S1) UNCHANGED — keeps calling
        _pool_owner_starttime at its two existing sites (TEST MODE + REAL MODE).

LATER — provided (the consumers):
  - P1.M2.T2.S1 (is_owner_alive(pid, starttime)): calls _pool_get_starttime DIRECTLY on a
        lease's owner.pid to read its current starttime; compares to the stored
        owner.starttime. Equal (and pid alive) → owner is the SAME process; differ → the
        PID was recycled → lease is stale (reap). PRD §2.8 ("starttime defeats PID
        recycling into a new pi"), §2.19. This task gives that check its extractor.
  - P1.M3.T2.S1 (find_my_lease) / P1.M3.T2.S3 (is_lane_stale): compare lease
        owner.starttime (stored by pool_owner_resolve via this extractor) to the resolved
        POOL_OWNER_STARTTIME. The (pid, starttime) pair is the anti-collision +
        anti-staleness key.
  - P1.M6.T3 (wrapper lifecycle): consumes POOL_OWNER_PID/STARTTIME (set by
        pool_owner_resolve, which now routes through _pool_get_starttime via the wrapper).
  - P1.M9.T1.S1 (test harness): the AGENT_BROWSER_POOL_OWNER_STARTTIME override feeds
        pool_owner_resolve's TEST MODE; the wrapper/extractor handle the live-PID case.

CONFIG / DATABASE / ROUTES: none. No new env vars, no new globals, no dir I/O, no lease
I/O. The only on-disk thing read is /proc/<pid>/stat (ephemeral, kernel-provided).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After the insert + wrapper conversion — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. all prior subtasks).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds). NOTE: the "under pi" tests only pass when the runner is itself a child of a `pi`
process (the normal agent runtime); under a plain interactive shell they print SKIP
(no pi ancestor) — that is correct, not a failure.

```bash
# 2a. Both functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type _pool_get_starttime _pool_owner_starttime' >/dev/null && echo OK
# Expected: OK.

# 2b. Canonical: echoes digits for $$ and EXACTLY equals cut -f22 (same process).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         a="$(_pool_get_starttime "$$")"; b="$(cut -d" " -f22 /proc/$$/stat)"; \
         [[ "$a" == "$b" && "$a" =~ ^[0-9]+$ ]] && echo "OK canon=$a" || { echo "FAIL a=$a b=$b"; exit 1; }'
# Expected: OK canon=<digits>.

# 2c. Canonical AGREES with the sed|awk reference command (the item's stated robust method).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         a="$(_pool_get_starttime "$$")"; r="$(sed "s/.*)//" /proc/$$/stat | awk "{print \$20}")"; \
         [[ "$a" == "$r" ]] && echo "OK matches-sed-method=$a" || { echo "FAIL a=$a r=$r"; exit 1; }'
# Expected: OK matches-sed-method=<digits>. (Both read $$ → exact agreement.)

# 2d. Dead PID → return 1, no echo, no abort under set -e.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_get_starttime 999999999; then echo "FAIL"; else echo "OK dead→1"; fi'
# Expected: OK dead→1 (and NO output from the function itself).

# 2e. Input validation: empty + non-numeric → return 1, never fatal.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_get_starttime ""; e=$?; _pool_get_starttime "abc"; n=$?; \
         if (( e == 1 && n == 1 )); then echo "OK input-validation"; else echo "FAIL e=$e n=$n"; exit 1; fi'
# Expected: OK input-validation.

# 2f. Output validation: a garbled stat line (simulated by pointing at a non-stat path that
#     exists but has no ')' ) → return 1. (Direct unit test of the output guard is hard
#     without a /proc hook; the dead-PID + input tests cover the guard paths. The
#     crafted-comm proof in 3c exercises the parse math instead.)
bash -c 'set -euo pipefail; source lib/pool.sh; \
         out="$(_pool_get_starttime 1 2>/dev/null)"; \
         [[ -z "$out" || "$out" =~ ^[0-9]+$ ]] && echo "OK pid1-ok-or-guarded" || { echo FAIL; exit 1; }'
# Expected: OK pid1-ok-or-guarded. (PID 1 is init, almost always live → echoes digits.
#       If somehow unreadable, returns 1 with no echo — both are correct.)

# 2g. Wrapper delegates: _pool_owner_starttime == _pool_get_starttime for the same PID.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         w="$(_pool_owner_starttime "$$")"; c="$(_pool_get_starttime "$$")"; \
         [[ "$w" == "$c" ]] && echo "OK wrapper=$w" || { echo "FAIL wrapper=$w canon=$c"; exit 1; }'
# Expected: OK wrapper=<digits>.

# 2h. S1 regression (under pi): pool_owner_resolve populates POOL_OWNER_STARTTIME correctly
#     via the wrapper, matching an independent extraction.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_owner_resolve; \
         if [[ "$POOL_OWNER_PID" != "0" ]]; then \
           indep="$(cut -d" " -f22 /proc/$POOL_OWNER_PID/stat)"; \
           [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] && echo "OK s1-regression=$POOL_OWNER_STARTTIME" \
             || { echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; exit 1; }; \
         else echo "SKIP (no pi ancestor)"; fi'
# Expected (under pi): OK s1-regression=<digits>. (plain shell): SKIP.

# 2i. S1 TEST-MODE regression: override routes through the wrapper.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         AGENT_BROWSER_POOL_OWNER_PID="$$" pool_owner_resolve; \
         indep="$(cut -d" " -f22 /proc/$$/stat)"; \
         [[ "$POOL_OWNER_STARTTIME" == "$indep" ]] && echo "OK test-mode=$POOL_OWNER_STARTTIME" \
           || { echo "FAIL resolved=$POOL_OWNER_STARTTIME indep=$indep"; exit 1; }'
# Expected: OK test-mode=<digits>.

# 2j. Exactly ONE parser: the wrapper body must contain no parsing primitives.
bash -c '
    body="$(sed -n "/^_pool_owner_starttime() {/,/^}/p" lib/pool.sh)"
    if grep -qE "cat |awk|##\*\)" <<<"$body"; then echo "FAIL dup parser"; echo "$body"; exit 1; fi
    grep -q "_pool_get_starttime \"\$@\"" <<<"$body" && echo "OK pure-delegation" || { echo FAIL; exit 1; }
'
# Expected: OK pure-delegation.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Full file sources; all prior + new/changed functions present.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
              _pool_get_starttime _pool_owner_starttime pool_owner_resolve >/dev/null && echo OK'
# Expected: OK.

# 3b. Downstream-consumer simulation: how M2.T2.S1 is_owner_alive will use the extractor
#     (read a PID's current starttime; compare to a stored value).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         now="$(_pool_get_starttime "$$")"; \
         sleep 0.2; again="$(_pool_get_starttime "$$")"; \
         if [[ "$now" == "$again" ]]; then echo "OK identity-stable ($now) — is_owner_alive would MATCH"; \
         else echo "FAIL: starttime changed for the same live pid ($now vs $again)"; exit 1; fi'
# Expected: OK identity-stable (<digits>) — proves the value is a usable anti-recycling key
#       (a live process's starttime never changes; only recycling changes it).

# 3c. PARENS-ROBUST MATH PROOF on a CRAFTED multi-space comm (validates the core claim a
#     real pi/bash comm cannot exercise, since their comm has no spaces). Construct a stat
#     line whose field-22 is 7777777 and whose comm has 2 extra words.
bash -c '
    line="4242 (Chrome Helper Renderer) S 1 1 1 0 -1 4194304 5 0 0 0 0 0 0 0 20 0 1 0 7777777 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
    after="${line##*)}"
    pure="$(awk "{print \$20}" <<<"$after")"
    sedv="$(sed "s/.*)//" <<<"$line" | awk "{print \$20}")"
    naive="$(awk "{print \$22}" <<<"$line")"
    echo "pure=$pure sed=$sed naive=$naive"
    [[ "$pure" == "7777777" && "$sedv" == "7777777" ]] && echo "OK robust-field22" || { echo "FAIL"; exit 1; }
'
# Expected: pure=7777777 sed=7777777 naive=<wrong value, shifted by the 2 comm words>, then
#       OK robust-field22. PROVES the parens-strip yields field 22 and the naive method
#       does not — the entire justification for the robust method.

# 3d. No stray repo artifacts (the extractor reads /proc only; writes nothing but may log
#     via pool_owner_resolve if that's exercised — to a tmpdir in tests).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json|tmp)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts' (or only expected test-tmpdir logs).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Re-confirm the host /proc/stat field layout (the core correctness claim) — matches
#     this task's research §1.
echo "fields: $(wc -w < /proc/self/stat)"
echo "field22 (cut): $(cut -d' ' -f22 /proc/self/stat)"
echo "field22 (sed|awk): $(sed 's/.*)//' /proc/self/stat | awk '{print $20}')"
echo "NF-19 (WRONG): $(awk '{print $(NF-19)}' /proc/self/stat)"
echo "CLK_TCK: $(getconf CLK_TCK)"
# Expected: fields=52; the two correct extractions agree (~8.28M); NF-19 = 4096 (WRONG);
#       CLK_TCK=100.

# 4b. Confirm a live process's starttime is STABLE across reads (only recycling changes it) —
#     the property is_owner_alive relies on.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         s1="$(_pool_get_starttime "$$")"; sleep 1; s2="$(_pool_get_starttime "$$")"; \
         [[ "$s1" == "$s2" ]] && echo "OK stable=$s1" || echo "FAIL $s1 vs $s2"'
# Expected: OK stable=<digits>.

# 4c. Confirm the canonical extractor and the item's literal sed command are interchangeable
#     (documenting the equivalence for future maintainers).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         for pid in $$ $PPID 1; do \
           a="$(_pool_get_starttime "$pid")"; \
           b="$(sed "s/.*)//" /proc/$pid/stat 2>/dev/null | awk "{print \$20}")"; \
           [[ -z "$a" && -z "$b" || "$a" == "$b" ]] \
             && echo "pid=$pid eq=$a" || { echo "FAIL pid=$pid a=$a b=$b"; exit 1; }; \
         done; echo OK'
# Expected: pid=$$ eq=<digits>, pid=$PPID eq=<digits>, pid=1 eq=<digits>, then OK. (For each
#       live pid, _pool_get_starttime and the sed reference command agree exactly.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors) — whole file incl. all prior subtasks.
- [ ] Level 2 snippets 2a–2j all pass (2h under pi; SKIP is acceptable under plain shell).
- [ ] Level 3 snippets 3a–3d all pass (3c is the decisive robustness proof).
- [ ] Level 4 snippets 4a–4c confirm the host facts that justify the design.

### Feature Validation

- [ ] `_pool_get_starttime()` defined and callable after `source lib/pool.sh`.
- [ ] `_pool_get_starttime "$$"` echoes `^[0-9]+$` and EXACTLY equals `cut -d' ' -f22 /proc/$$/stat`.
- [ ] `_pool_get_starttime "$$"` EXACTLY equals `sed 's/.*)//' /proc/$$/stat | awk '{print $20}'`
      (the item's stated robust method).
- [ ] `_pool_get_starttime <dead-pid>` returns 1, echoes nothing, never aborts under set -e.
- [ ] `_pool_get_starttime ""` and `_pool_get_starttime "abc"` return 1 (input validation), never fatal.
- [ ] `_pool_get_starttime` uses the PARENS-ROBUST extraction (`${stat_line##*)}` greedy +
      `awk '{print $20}'`), NOT naive `awk '{print $22}'` and NOT the NF-19 formula.
- [ ] `_pool_get_starttime` has a leading comment explaining WHY NF-19 is wrong (NF=52 →
      field 33 = vsize) and documenting the correct method (item req. #5).
- [ ] `_pool_owner_starttime` is a one-line delegating wrapper (`_pool_get_starttime "$@"`);
      its body contains NO parsing primitives; its I/O contract is unchanged from S1.
- [ ] `pool_owner_resolve` (S1) UNCHANGED in behavior — `POOL_OWNER_STARTTIME` still populates
      correctly (regression 2h/2i).
- [ ] Exactly ONE starttime parser body exists in the file (regression 2j).

### Code Quality Validation

- [ ] Only `lib/pool.sh` modified; the change is confined to the "Owner resolution" section.
- [ ] `_pool_get_starttime` INSERTED directly above `_pool_owner_starttime` (logical grouping).
- [ ] `_pool_owner_starttime` BODY replaced with the delegation (name + signature preserved).
- [ ] `pool_owner_resolve` NOT modified (zero changes — delegation is transparent to it).
- [ ] Every `local` capture is two-statement (SC2155 clean): `local x; x="$(...)"`.
- [ ] The /proc read is `cat ... 2>/dev/null || true` (vanished entry → clean return 1, no abort).
- [ ] Every `[[ =~ ]]` is inside `if [[ ! ... ]]; then return 1; fi` (set -e safe).
- [ ] `${stat_line##*)}` is the GREEDY (double-#) form.
- [ ] `local pid="${1:-}"` (set -u safe for a called-with-no-args function).
- [ ] All expansions double-quoted (SC2086 clean).
- [ ] No top-level executable code added beyond the function definition + the wrapper change
      (sourcing stays side-effect-free apart from S1's existing `set -euo pipefail`).
- [ ] Naming matches the project convention: `_pool_get_starttime` (internal, canonical) and
      `_pool_owner_starttime` (internal, S1 alias/wrapper).

### Documentation & Deployment

- [ ] `_pool_get_starttime` has a leading comment covering: it is THE canonical extractor;
      its consumers (pool_owner_resolve via wrapper, is_owner_alive directly); WHY the PRD
      §2.19 NF-19 formula is wrong (NF=52 → field 33 = vsize, not starttime); the correct
      parens-robust method + the sed-pipeline equivalent; the field-offset arithmetic
      (22−2=20); the never-fatal 0/1 contract.
- [ ] `_pool_owner_starttime` (wrapper) has a brief comment noting it delegates to
      `_pool_get_starttime` and why the alias exists (S1's call sites + single-parser rule).
- [ ] No source/PRD/tasks.json/prd_snapshot.md/.gitignore files modified.

---

## Anti-Patterns to Avoid

- ❌ Don't use the PRD §2.19 `NF-19` formula — it's WRONG on this host (NF=52 → NF-19 =
  field 33 = vsize ≈ 4096, not starttime ≈ 8.28M). Verified this session. Use the
  parens-strip (`${stat_line##*)}` then `awk '{print $20}'`). key_findings FINDING 1 +
  system_context §6.1 confirm it.
- ❌ Don't use a naive `awk '{print $22}'` — breaks when `comm` contains spaces (field 2 is
  parenthesized). The crafted-comm proof (Validation 3c) demonstrates the failure.
- ❌ Don't leave TWO starttime parsers in the file. S1's `_pool_owner_starttime` MUST become
  a one-line delegating wrapper — one parser, two entry names. Duplication is a maintenance
  hazard and violates the parallel-task no-duplication rule.
- ❌ Don't modify `pool_owner_resolve` to call `_pool_get_starttime` directly — that's a
  larger blast radius for no benefit; the wrapper makes the consolidation transparent to
  S1's two call sites. Leave `pool_owner_resolve` byte-for-byte unchanged.
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155; masks exit
  status under `set -e`). Critical for `cat /proc/$pid/stat` and `awk '{print $20}'`.
- ❌ Don't leave `cat "/proc/$pid/stat"` unguarded — a vanished/EACCES entry makes cat fail
  and `set -e` aborts. Always `2>/dev/null || true`.
- ❌ Don't write a standalone `[[ "$v" =~ ^[0-9]+$ ]]` — a failed match returns 1 and aborts
  under `set -e`. Always inside `if [[ ! ... ]]; then return 1; fi`.
- ❌ Don't use `${stat_line#*)}` (single `#`, non-greedy) — it stops at the FIRST `)`, which
  is wrong if `comm` itself contains `)`. Use the double-`#` greedy `${stat_line##*)}`.
- ❌ Don't read `$1` bare — under `set -u` a no-args call aborts. Use `local pid="${1:-}"`.
- ❌ Don't call `pool_die` or `exit` from `_pool_get_starttime` — it is a 0/1 leaf extractor;
  callers treat 1/empty as "process dead / identity unknown".
- ❌ Don't compare two independent `/proc/self/stat` reads and expect exact equality — they
  are different PIDs whose starttimes can differ by 1 tick (10 ms). Compare against the SAME
  process via `$$` within one shell.
- ❌ Don't implement `is_owner_alive` here — that's P1.M2.T2.S1 (liveness + starttime-
  recycling check). This task is the EXTRACTOR + the wrapper consolidation only.
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any file other
  than `lib/pool.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The extractor contract is unusually precise (explicit I/O table; explicit 0/1,
  never-fatal rule; exact agreement assertions against `cut -f22` and the sed reference
  command for the SAME `$$` process).
- The two correctness-critical facts were **verified on the host this session**: (1) the
  PRD §2.19 `NF-19` formula is WRONG (NF=52 → NF-19 = field 33 = vsize ≈ 4096), and the
  parens-strip method (`${stat_line##*)}` then `awk '{print $20}'`, equivalently
  `sed 's/.*)//' | awk '{print $20}'`) yields the correct field 22 (~8283368); (2) a live
  process's starttime is stable across reads (only recycling changes it) — the property
  `is_owner_alive` depends on. The crafted-comm proof (Validation 3c) demonstrates the
  robustness claim directly.
- The S1/S2 consolidation via delegation is the principled no-duplication resolution: it
  preserves S1's exact I/O contract and leaves `pool_owner_resolve` byte-for-byte
  unchanged (so S1's regressions hold automatically), while giving the codebase one
  canonical parser. The pure-delegation guard (Validation 2j) mechanically prevents
  leaving two parsers.
- The `set -euo pipefail` traps (SC2155 two-statement locals; `cat /missing || true`;
  `[[ =~ ]]` inside `if`; `${1:-}` under set -u) are each called out with the exact idiom
  and a dedicated Level-2 test.
- The -1 reflects that the S1-regression "under pi" test (2h) and the genuine real-mode
  path rely on the runner being a child of `pi` (the normal agent runtime); under a plain
  interactive shell it prints SKIP. The TEST-MODE override path (2i) and the direct
  `$$`-based tests (2b/2c/2g) cover the extractor fully regardless of runtime context.
