# PRP — P1.M2.T1.S1: `pool_reap_orphan_dirs` also removes a present-but-invalid `lanes/N.json` in the orphan branch

> **Bugfix context**: This subtask implements **seam 1 of the BUG-003 fix** (Minor, PRD h2.3/h3.2)
> per `architecture/fix_design.md` §4. BUG-003: a corrupt lease file is uncleanable by any pool
> verb — `pool_lane_is_stale` returns rc 2 (skip) for corrupt leases so `pool_reap_stale` never
> touches them; `pool_reap_orphan_dirs` removes an orphan DIR but leaves `lanes/N.json` in place;
> `release N` refuses (P1.M2.T1.S2's seam). Net: the lane number is permanently burned
> (`pool_find_free_lane`'s `[[ -f ]]` treats it as occupied — deliberately, for collision safety)
> and `status` shows a permanent `? ? … STALE` row. This subtask makes **`reap`** the designated
> reclaimer: when the orphan branch has already removed the dir, a present-but-corrupt lease file
> is removed too. Runs **in parallel** with P1.M1.T3.S1 (the major-fix verification gate —
> verification-only, touches no source/test files, no conflict) and **without code dependency**
> on P1.M2.T1.S2 (the release-side seam; item contract §2: "no code dependencies on other
> subtasks").

---

## Goal

**Feature Goal**: In `pool_reap_orphan_dirs` (`lib/pool.sh`, currently at lines 3388-3433 — the
item contract's 3131-3202 baseline has shifted; match by text), the orphan branch (the
`if ! pool_lease_exists "$base"; then` block) currently: kills any orphan Chrome pointed at the
dir (anchored pgrep/pkill), prefix-guarded `rm -rf` of the dir, logs, increments the orphan
count — but **never touches `$POOL_LANES_DIR/$base.json`**. Add, immediately after the
prefix-guarded `rm -rf` of the dir (and its `_pool_log` line), a guarded removal of a
**present-but-invalid** lease file: if the lease file exists AND `pool_lease_exists` fails
(reaching the orphan branch with the file present means it is corrupt — `pool_lease_exists` rc 1
= missing OR corrupt), `rm -f -- "$POOL_LANES_DIR/$base.json"` with a
`_pool_log "pool_reap(orphan): removed corrupt lease ..."` line and a BUG-003 comment. This
frees the lane number (post-reap, `pool_find_free_lane`'s `[[ -f ]]` sees no file → the lane is
reclaimable) and eliminates the permanent `? STALE` status row.

This is the literal implementation of fix_design.md §4 seam 1 and the PRD h2.5 recommendation:
*"reap_orphan_dirs also removes an unparseable lanes/N.json after its dir is gone"*.

**Deliverable**:
1. `lib/pool.sh` — one guarded block added inside `pool_reap_orphan_dirs`'s orphan branch
   (after the dir rm, before/after `orphans=$((orphans + 1))` — keep the count semantics: the
   count counts DIRS; the lease removal is a rider, logged separately, NOT counted).
2. `test/bootrace.sh` — **add** the `r5_bug003_corrupt_lease_reclaimed` case (TDD: write it
   FIRST, watch it fail on current code, then fix lib/pool.sh and watch it pass) + append the
   case name to `_br_run_suite`'s hardcoded list (~line 469-471). Mirrors the PRD h3.2 repro:
   seed `printf 'not json {{{' > $STATE/lanes/7.json` + orphan dir 7 with a marker file → run
   `reap` → assert BOTH the dir and the lease are gone, `pool_find_free_lane` can return 7
   (with lanes 1-6 lease-files present), and `status` shows no row for lane 7.
3. `README.md` — Mode A: one sentence in the `### reap` section (~line 236): corrupt/unparseable
   lease files are also cleared once their lane dir is gone. Rides WITH this subtask.
4. NOTHING else changes. `pool_lane_is_stale` rc 2, `pool_find_free_lane`'s `[[ -f ]]`, and
   `_pool_atomic_write`'s no-fsync stay UNTOUCHED (deliberate collision safety + documented
   fsync decision — fix_design §4).

**Success Definition**:
- With `HOME`/state/ephemeral redirected to a temp tree, seeding a corrupt
  `$STATE/lanes/7.json` + an orphan dir `$EPHEMERAL/7` (with a marker file) and running
  `agent-browser-pool reap`: BOTH `$EPHEMERAL/7` and `$STATE/lanes/7.json` are gone after
  (before the fix, the lease file REMAINED — that is BUG-003), the report still says
  `Removed 1 orphan dir(s).` (the count is not inflated), `pool_find_free_lane` (with lanes
  1-6 lease-files present) returns 7, and `agent-browser-pool status` shows no row for lane 7.
- A NORMAL orphan (dir present, NO lease file at all) still reaps identically — the new block's
  `[[ -f ]]` short-circuits (no rm, no extra fork beyond the file test).
- A LIVE lane (dir + VALID lease) is still skipped by the orphan branch (the
  `if ! pool_lease_exists` gate is unchanged and fires FIRST — a valid lease → rc 0 → not an
  orphan → the new block is never reached).
- `bash -n` + `shellcheck -s bash -S warning` clean on `lib/pool.sh` and `test/bootrace.sh`.
- `timeout 300 bash test/bootrace.sh` exits 0 with ALL cases passing (the 6 existing + the new
  R5). R5 fails on pre-fix code (lease file survives reap) and passes post-fix.
- The other four repo suites (validate/release_reaper/transparency/concurrency) unaffected
  (this change only ADDS a removal inside a branch they don't exercise with corrupt leases;
  P1.M3.T1.S1's final gate re-runs them).

## User Persona

**Target User**: Operators running `agent-browser-pool reap` / `status` after a crash or power
loss, and the lazy reaper path (`pool_wait_for_lane` force-reap on exhaustion). Secondary: any
agent whose acquire keeps skipping a burned lane number.

**Use Case**: A power loss (explicitly in scope — PRD Goal 4 covers crash/power-loss) truncates
a lease write's target... actually, `_pool_atomic_write`'s atomic rename prevents TORN files —
power loss leaves the OLD lease intact plus an orphan `.tmp`. But OTHER causes (disk-full
ENOSPC mid-write of the .tmp, a killed process between the printf and the mv in a FUTURE
regression, external sabotage, an operator's stray editor) can still leave a zero-length or
partial `lanes/N.json`. Today that state is permanent: `status` shows `7  ? ? … STALE` forever,
`reap` removes the dir but not the lease, `release 7` refuses, and every acquire skips lane 7.
After this fix: one `reap` (which the exhaustion path already runs) fully clears the lane.

**User Journey**: Operator sees a permanent `? STALE` row → runs `agent-browser-pool reap` →
report `Removed 1 orphan dir(s).` (unchanged wording) → the row disappears, the lane number is
reclaimable, the next acquire can use it.

**Pain Points Addressed**:
- **Lane number permanently burned** (PRD h3.2): with a 10-lane default pool, one corrupt lease
  permanently reduces capacity by 10%.
- **No verb can clean it**: the PRD h2.3 title says it all — "can never be cleaned by any pool
  verb". `reap` becomes the designated reclaimer (PRD h2.5's exact recommendation).
- **PRD §2.10 contract**: "stale/corrupt state is reclaimable by the lazy reaper / `reap`" —
  the current code violates this for the corrupt-lease case.

## Why

- **fix_design.md §4 seam 1 is the designed fix** — this PRP implements it verbatim. The design
  deliberately chose TWO surgical seams (reap: dir-gone + corrupt lease; release:
  corrupt-lease-with-dir-present) rather than weakening the collision-safety guards
  (`pool_lane_is_stale` rc 2 and `pool_find_free_lane`'s `[[ -f ]]` treat corrupt as
  "occupied/unknown" to NEVER hand a possibly-in-use lane to two owners — system_context §7.
  Those stay untouched).
- **Safety of the seam**: dir gone + corrupt lease is *definitionally unowned* — no lease data
  is trustworthy (that's what corrupt means), the dir (the only other evidence of the lane) is
  already removed, so no live owner/chrome can be orphaned by removing the file. Contrast S2's
  seam (release with the dir possibly PRESENT), which needs the extra cmdline sweep.
- **Zero impact on the happy path**: the new block only runs INSIDE the orphan branch (lease
  missing-or-corrupt) AND only when the file is present (the `[[ -f ]]` short-circuit) — i.e.
  exactly the corrupt-lease-with-orphan-dir state. Normal orphans (no file) cost one `[[ -f ]]`
  test. Live lanes never reach it.
- **TDD-first**: R5 in test/bootrace.sh encodes the PRD h3.2 repro; written first, it fails on
  current code (red), then the 8-line fix turns it green — the minimal possible blast radius
  with a deterministic proof.
- **Mode A docs**: the one-sentence README addition rides with the code (no separate docs task;
  P1.M3.T2.S1 does the changeset-level sweep later).

## What

User-visible behavior: `agent-browser-pool reap` now also removes a corrupt/unparseable
`lanes/<N>.json` once its lane dir is gone (and `status` stops showing that `? STALE` row after
the reap). The report wording and counts are unchanged (the orphan count still counts DIRS).

Observable contract:

| State before `reap` | Dir after | Lease after | Orphan count | Notes |
|---|---|---|---|---|
| orphan dir 7, NO lease file | gone | (absent) | 1 | unchanged behavior |
| orphan dir 7, CORRUPT lease 7.json | gone | **gone (NEW)** | 1 | BUG-003 fixed; `_pool_log` records the lease removal |
| live dir + VALID lease | untouched | untouched | 0 | orphan branch never fires |
| corrupt lease 7.json, NO dir 7 | — | **remains** | 0 | no orphan branch → S2's `release 7` seam handles this shape |

### Success Criteria

- [ ] `pool_reap_orphan_dirs`'s orphan branch removes `$POOL_LANES_DIR/$base.json` when it is
      present-but-invalid, with the `_pool_log "pool_reap(orphan): removed corrupt lease
      $POOL_LANES_DIR/$base.json"` line and a BUG-003-referencing comment.
- [ ] The removal is guarded exactly as fix_design §4 specifies: `if [[ -f
      "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base"; then rm -f -- ...; fi`
      — every rc-1 call inside the `if` condition (errexit-exempt under `set -e`).
- [ ] The `orphans` count semantics are UNCHANGED (counts dirs only; the lease removal is not
      counted) — `pool_admin_reap`'s `Removed %d orphan dir(s).` message stays honest.
- [ ] `pool_lane_is_stale` (rc 2 skip), `pool_find_free_lane` (`[[ -f ]]` deliberate), and
      `_pool_atomic_write` (no fsync, deliberate) are UNTOUCHED (verify via git diff).
- [ ] `pool_admin_reap`, `pool_reap_stale`, `pool_admin_release` are UNTOUCHED (S2 owns the
      release seam).
- [ ] `test/bootrace.sh` gains `r5_bug003_corrupt_lease_reclaimed` AND it is appended to
      `_br_run_suite`'s hardcoded case list; the case mirrors the PRD h3.2 repro (corrupt
      7.json + orphan dir 7 + marker), runs `reap` under `timeout 30`, asserts dir+lease gone,
      `pool_find_free_lane` returns 7 (lanes 1-6 seeded with lease FILES), `status` shows no
      row for lane 7, and self-cleans.
- [ ] README `### reap` section gains the one-sentence Mode A note.
- [ ] `bash -n` + `shellcheck -s bash -S warning` clean on both edited files.
- [ ] `timeout 300 bash test/bootrace.sh` → rc 0, all cases pass (R5 red pre-fix, green post-fix).

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP quotes the exact current orphan-branch code (verified by
direct read at the CURRENT line numbers — the item contract's baseline numbers have shifted),
gives the verbatim fix block from fix_design §4 with its safety analysis, specifies the exact
R5 test (mirroring existing bootrace case style, with the subshell-source idiom and self-cleanup
pattern quoted from r1/r2), pins the README sentence, and lists the exact validation commands.
No prior exposure beyond the quoted snippets is needed.

### Documentation & References

```yaml
# MUST READ — project-internal (primary)
- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  section: §4 (BUG-003 — corrupt leases become reclaimable, keep safety)
  why: THE design. Seam 1 (this subtask) is quoted verbatim: "after the prefix-guarded rm -rf
        of the dir, ALSO remove a present-but-invalid lease file: if [[ -f .../$base.json ]]
        && ! pool_lease_exists "$base"; then rm -f -- ...; _pool_log ...; fi — frees the lane
        number. (Dir gone + corrupt lease = definitionally unowned; safe.)" Also §4's fsync
        decision (NO code change to _pool_atomic_write — atomic-rename already prevents TORN
        files; the reclaim paths make any corrupt lease clearable) and §4's Test contract.
  critical: seam 2 (pool_admin_release) is P1.M2.T1.S2's scope — do NOT implement it here.
        pool_lane_is_stale rc=2 and pool_find_free_lane's [[ -f ]] "stay UNTOUCHED (deliberate
        collision safety)".

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  section: §7 (BUG-003 — CONFIRMED)
  why: the precise mechanism of the bug: pool_lane_is_stale (rc 2 = missing OR corrupt → skip
        forever), pool_reap_orphan_dirs (orphan branch fires on pool_lease_exists rc 1; removes
        the DIR but never lanes/N.json), pool_lease_exists ([[ -f ]] + _pool_json_valid →
        corrupt = rc 1), pool_find_free_lane ([[ -f ]] DELIBERATE — "Do not change this"),
        pool_admin_status corrupt row (permanent ? ? … STALE), _pool_atomic_write no-fsync
        (deliberate + documented).
  critical: "pool_find_free_lane (1126-1135) uses [[ -f ... ]] DELIBERATELY (comment: corrupt
        lease = occupied, collision safety). Do not change this — make the corrupt state
        reclaimable instead." THIS subtask is the "instead".

- file: lib/pool.sh
  why: THE file. pool_reap_orphan_dirs is at CURRENT lines 3388-3433 (the item's 3131-3202
        baseline shifted — the file is now 5146 LOC). The orphan branch `if ! pool_lease_exists
        "$base"` is at ~3404; the prefix-guarded rm at ~3425-3428; the _pool_log at ~3429;
        `orphans=$((orphans + 1))` at ~3430. pool_lease_exists at 1005-1019. pool_find_free_lane
        at 1163-1171 (pure [[ ! -d && ! -f ]] presence check — key for R5's assertion).
  pattern: house style — `if ! pool_lease_exists "$base"` already demonstrates the rc-1-in-if
        idiom; the prefix-guarded rm demonstrates the rm-guard idiom; `_pool_log "pool_reap
        (orphan): ..."` demonstrates the log-tag style. Match all three in the new block.
  gotcha: match by TEXT (line numbers in the item contract and this PRP are point-in-time).
        The full current orphan-branch text is quoted in Implementation Tasks.

- file: test/bootrace.sh
  why: the regression suite this subtask extends (its own header, lines 31-35: "Consumers of
        this harness (add cases here, do not fork the file): ... P1.M2 (R5–R8 minor-bug
        cases)" — R5 belongs HERE). Single-setup runner _br_run_suite has a HARDCODED case
        list at ~469-471 (must append r5_bug003_corrupt_lease_reclaimed). Sandbox: _bootrace_
        setup (mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX; exports HOME,
        AGENT_BROWSER_POOL_STATE=$BR_T/state, AGENT_CHROME_EPHEMERAL_ROOT=$BR_T/active,
        AGENT_CHROME_MASTER, fake-chrome/fake-agent-browser bins, ALLOW_SLOW_COPY=1) + EXIT
        trap _bootrace_teardown.
  pattern: case style = mirror r1 (plain function, _fail "R5: ..." + return 1, self-cleanup
        `rm -rf ... || true` at the end) and r2 (drives "$ABPOOL_REPO/bin/agent-browser-pool"
        under `timeout`; subshell-source idiom `( trap - EXIT INT TERM; source "$ABPOOL_REPO/
        lib/pool.sh" && pool_config_init && <fn> )` for direct lib calls — the `trap -`
        disables the suite's EXIT trap inside the subshell).
  gotcha: R5 needs NO fake-chrome launch and NO owner spawn — the orphan branch's pgrep finds
        no matching processes (rc 1 → skip kill) — pure filesystem case, sub-second. Wrap the
        `reap` invocation in `timeout 30` anyway (house style, AGENTS.md §2).

- file: README.md
  why: the Mode A doc target. `### reap` section at ~line 236 (verified: the paragraph ends
        "...killing any orphaned Chrome still pointed at them). Always exits 0.").
  pattern: prose style — one sentence appended to the existing orphan-dirs sentence group.
  gotcha: ONE sentence only. The changeset-level README reconciliation is P1.M3.T2.S1's task.

- docfile: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  section: §4 (R1–R9 matrix) + §5 (safety checklist)
  why: the canonical description of R5's slot in the matrix and the suite-safety rules
        (single setup, timeouts, zero orphans) the new case must honor.

# Prior/subtask contracts
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T3S1/PRP.md
  why: the PARALLEL item (major-fix verification gate). It is verification-only (zero source/
        test edits) — no conflict with this subtask. Its gate counts bootrace cases AT RUN TIME
        ("re-grep the case list, do not hardcode") — adding R5 changes the count from 6 to 7;
        the gate PRP anticipates that. Its gate_results.md documents the pre-R5 baseline.
  pattern: the gate invokes `timeout 300 bash test/bootrace.sh` and expects rc 0 with
        "N passed, 0 failed" — R5 must keep that true (it will: R5 passes post-fix).
  gotcha: if the gate has ALREADY run and recorded 6 cases, that record is simply the
        pre-minor-fix baseline; P1.M3.T1.S1 re-runs everything after this lands.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M2T1S1/research/reap-orphan-corrupt-lease.md
  why: the research note for THIS subtask: current-vs-baseline line-number table, the exact
        verbatim edit site, the fix block with safety analysis, pool_lease_exists /
        pool_find_free_lane contracts, bootrace harness facts, the README text, and the S1/S2
        boundary table.
  pattern: §3 (the fix block) is the direct ancestor of Implementation Tasks Task 2.

# External authoritative docs (minimal — this is repo-internal bash surgery)
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: set -e exemptions — the condition of `if` is errexit-exempt, so `pool_lease_exists`
        rc 1 (the corrupt signal) inside `if ! ...` and the combined `[[ ]] && ! ...`
        condition are safe branches, not aborts.
  critical: a BARE `pool_lease_exists "$base"` (rc 1) outside an if/|| ABORTS under set -e
        (propagated by lib/pool.sh's header). The new block's guard is entirely inside the
        `if` condition — the exact idiom the orphan branch already uses one line above.
- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions — `rm -f -- "$POOL_LANES_DIR/$base.json"` (the item's
        guard idiom). Universal.
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh            # 5146 LOC. pool_reap_orphan_dirs 3388-3433 (EDIT: orphan branch ~3404-3431)
│                          #   pool_lease_exists 1005-1019, pool_find_free_lane 1163-1171 (UNTOUCHED)
│                          #   pool_lane_is_stale 1226+ (UNTOUCHED), _pool_atomic_write ~330-385 (UNTOUCHED)
├── bin/
│   └── agent-browser-pool # the admin CLI (reap verb → pool_admin_reap → pool_reap_orphan_dirs). UNTOUCHED.
├── test/
│   ├── bootrace.sh        # 507 LOC. EDIT: add r5_bug003_corrupt_lease_reclaimed + case-list entry (~469)
│   ├── validate.sh / release_reaper.sh / transparency.sh / concurrency.sh   # UNTOUCHED
├── README.md              # EDIT: one sentence in `### reap` (~line 236)
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/{fix_design,system_context,test_framework}.md
    ├── P1M1T3S1/PRP.md         # PARALLEL (verification gate — no file conflicts)
    └── P1M2T1S1/               # THIS subtask
        ├── PRP.md              # THIS FILE
        └── research/reap-orphan-corrupt-lease.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 3 existing files:
#   lib/pool.sh       — pool_reap_orphan_dirs orphan branch: +1 guarded corrupt-lease removal block (~10 lines incl. comment)
#   test/bootrace.sh  — +1 case r5_bug003_corrupt_lease_reclaimed (~40 lines) + 1 name in _br_run_suite's list
#   README.md         — +1 sentence in `### reap`
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (line numbers shifted): the item contract's line numbers (3131-3202, 968-983,
# 1126-1135, 1189-1225) are the architecture-doc baseline; lib/pool.sh is NOW 5146 LOC
# (harnesses feature + landed M1 fixes). CURRENT: pool_reap_orphan_dirs 3388-3433,
# pool_lease_exists 1005-1019, pool_find_free_lane 1163-1171, pool_lane_is_stale 1226+.
# ALWAYS match by TEXT — the exact current orphan-branch text is quoted in Task 2.

# CRITICAL (set -e + pool_lease_exists): pool_lease_exists is a PREDICATE — rc 1 means
# "missing or corrupt" (a signal, NOT an error). A bare call with rc 1 ABORTS under set -e.
# Every call must sit inside an `if` condition / `||` list (errexit-exempt). The new block's
# guard `if [[ -f ... ]] && ! pool_lease_exists "$base"; then` is entirely condition-context
# — the same idiom the orphan branch's own `if ! pool_lease_exists "$base"` uses.

# CRITICAL (do NOT weaken the collision-safety guards): pool_lane_is_stale's rc 2 (corrupt →
# skip) and pool_find_free_lane's [[ -f ... ]] (corrupt lease = occupied) are DELIBERATE —
# they prevent handing a possibly-in-use lane to two owners. system_context §7: "Do not
# change this — make the corrupt state reclaimable instead." This subtask removes the FILE
# (so the guards then see a clean free lane); it must NOT touch the guards themselves.

# CRITICAL (the orphan count counts DIRS): orphans=$((orphans + 1)) counts removed DIRS;
# pool_admin_reap prints "Removed %d orphan dir(s)." from it. The corrupt-lease removal is a
# RIDER — log it via _pool_log but do NOT increment the count (the user-facing message stays
# honest; the PRD h3.2 repro expects "Removed 1 orphan dir(s)." with BOTH artifacts gone).

# GOTCHA (why the second pool_lease_exists call is needed): the orphan branch was entered
# because pool_lease_exists returned rc 1 (missing OR corrupt). The `[[ -f ]]` +
# re-pool_lease_exists distinguishes the two: file absent (the common orphan — normal crash
# debris) → skip the rm (nothing to remove; the [[ -f ]] short-circuits, zero extra forks);
# file present + still rc 1 → corrupt → rm. Without the distinction you'd rm a nonexistent
# path (harmless with -f, but the _pool_log would LIE about removing a corrupt lease that
# wasn't there).

# GOTCHA (rm safety): $base is validated ^[0-9]+$ at the top of the loop (path-traversal
# defense, same as pool_lease_exists's own guard) → "$POOL_LANES_DIR/$base.json" is a literal,
# injection-safe path. Use `rm -f --` (the -- guards leading-dash; -f makes missing-file a
# no-op). Same shape _pool_release_lane_internals uses for its lease rm.

# GOTCHA (fsync decision — NO code change): _pool_atomic_write's no-fsync is deliberate and
# documented (atomic same-FS rename prevents TORN files; power-loss leaves OLD-intact + an
# orphan .tmp). fix_design §4 explicitly decides: NO fsync code change; the reclaim paths
# (this seam + S2's) make any corrupt lease clearable regardless of cause. Do NOT add fsync,
# do NOT add a .tmp sweep here (fix_design mentions it as a possible doctor/orphan-dir
# extension — out of scope for this subtask).

# GOTCHA (bootrace runner has a HARDCODED case list): _br_run_suite's `for fn in ...` list
# (~line 469-471) does NOT auto-discover cases (unlike validate.sh's compgen). Adding the
# r5_ function WITHOUT appending its name to the list = the case silently never runs (a
# vacuous green). ALWAYS do BOTH. (The M1.T3.S1 gate greps the case list at run time —
# expect its count to grow by 1.)

# GOTCHA (bootrace self-cleanup): every case cleans up its own artifacts at the end
# (`rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/7" ... || true` etc.) so later cases start
# clean — mirror r1/r2. R5's seeds (lanes/1-6 placeholder files, lanes/7.json, active/7)
# must all be removed even on the failure paths that return early... note: an early
# `return 1` SKIPS the trailing cleanup — acceptable per house style (r1/r2 do the same;
# the suite's _bootrace_teardown + later cases' reap tolerate leftovers), but keep the
# happy-path cleanup so R5 does not pollute the cases that follow it in the list.

# GOTCHA (AGENTS.md): the R5 run must be hermetic (bootrace's setup already redirects
# HOME/state/ephemeral under $BR_T) and `timeout`-wrapped. NO real chrome is launched by
# R5 (the orphan branch's pgrep matches nothing → no kill). Never run against the
# operator's real ~/.local/state/agent-browser-pool/ or ~/.agent-chrome-profiles/.

# GOTCHA (scope): THIS subtask = seam 1 (reap) + R5 + README sentence. Do NOT implement
# seam 2 (pool_admin_release corrupt-lease handling — P1.M2.T1.S2), do NOT touch
# pool_admin_reap / pool_reap_stale / pool_lane_is_stale / pool_find_free_lane /
# _pool_atomic_write / pool_admin_status. Verify with git diff.
```

## Implementation Blueprint

### Data models and structure

No data models change. The lease JSON schema is untouched. The only "structure" is the
return/count contract of `pool_reap_orphan_dirs`:

| Aspect | Before | After |
|---|---|---|
| stdout | one integer = removed DIR count | UNCHANGED |
| rc | 0 always | UNCHANGED |
| side effects | kill orphan chrome (anchored), rm -rf dir (prefix-guarded), `_pool_log` per orphan | + rm -f a present-but-corrupt `lanes/N.json` + one extra `_pool_log` per corrupt lease found |

### Implementation Tasks (ordered by dependencies — TDD: test first)

```yaml
Task 1: READ the current code and confirm the edit site + contracts
  - RUN: sed -n '3388,3435p' lib/pool.sh    # pool_reap_orphan_dirs (current lines)
  - EXPECT: the (a) no-root guard, (b) the glob loop + base validation, (c) the
        `if ! pool_lease_exists "$base"` orphan branch with the anchored pgrep/pkill block,
        the prefix-guarded `rm -rf -- "$dir"`, `_pool_log "pool_reap(orphan): removed orphan
        dir $dir (no lease)"`, and `orphans=$((orphans + 1))`.
  - RUN: sed -n '1005,1019p' lib/pool.sh    # pool_lease_exists ([[ -f ]] + _pool_json_valid)
  - RUN: sed -n '1163,1171p' lib/pool.sh    # pool_find_free_lane (pure [[ ! -d && ! -f ]])
  - RUN: sed -n '469,472p' test/bootrace.sh # _br_run_suite's hardcoded case list
  - RUN: sed -n '210,245p' test/bootrace.sh # r1/r2 case style to mirror
  - NOTE: if the line numbers drifted (they will over time), locate by grepping unique
        text: `grep -n 'removed orphan dir' lib/pool.sh`, `grep -n 'r4_bug002_preport_race'
        test/bootrace.sh`.

Task 2: ADD test/bootrace.sh case r5_bug003_corrupt_lease_reclaimed (TDD — write it FIRST)
  - PLACE: after the r4_bug002_preport_race function's closing `}` and BEFORE the
        `_br_run_suite` definition. Follow the r1/r2 style exactly.
  - ADD this case (byte-ready; mirrors the PRD h3.2 repro + the fix_design §4 test contract):
      ----------------------------------------------------------------
      # R5 — BUG-003: reap must ALSO remove a present-but-invalid lanes/N.json once its
      # orphan dir is gone. Before the fix, `reap` removed the dir but left the corrupt
      # lease → pool_find_free_lane's [[ -f ]] treated lane 7 as occupied forever (deliberate
      # collision safety — the FILE must be removed, not the guard weakened) and status
      # showed a permanent '? ? … STALE' row. PRD h2.3/h3.2 repro + fix_design §4 test
      # contract. No chrome launch: the orphan branch's pgrep matches nothing (rc 1 → no kill).
      r5_bug003_corrupt_lease_reclaimed() {
          # Seed: lanes 1-6 occupied (file presence is ALL pool_find_free_lane checks),
          # lane 7 = the BUG-003 state (corrupt lease + orphan dir with a marker file).
          local n out lease7
          mkdir -p -- "$AGENT_BROWSER_POOL_STATE/lanes" "$AGENT_CHROME_EPHEMERAL_ROOT/7"
          for n in 1 2 3 4 5 6; do
              printf '{"port":%d}' "$((53400 + n))" >"$AGENT_BROWSER_POOL_STATE/lanes/$n.json"
          done
          printf 'not json {{{' >"$AGENT_BROWSER_POOL_STATE/lanes/7.json"
          printf 'orphan-marker\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/7/Preferences"
          # Run reap through the real admin CLI (house style: timeout; rc 0 always).
          out=""
          out="$(timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" reap 2>/dev/null || true)"
          # 1) BOTH artifacts gone: the dir AND the corrupt lease.
          if [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/7" ]]; then
              _fail "R5: orphan dir 7 still present after reap"; return 1
          fi
          lease7="$AGENT_BROWSER_POOL_STATE/lanes/7.json"
          if [[ -e "$lease7" ]]; then
              _fail "R5: corrupt lease 7.json still present after reap (BUG-003 reproduced)"; return 1
          fi
          # 2) Lane number un-burned: with 1-6 occupied, find_free_lane must return 7.
          n="$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && \
                  pool_config_init && pool_find_free_lane ) 2>/dev/null || true )"
          if [[ "$n" != "7" ]]; then
              _fail "R5: pool_find_free_lane returned '${n:-<empty>}' (expected 7 — lane still burned)"; return 1
          fi
          # 3) status no longer shows a row for lane 7.
          if timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" status 2>/dev/null | grep -qE '^ *7 '; then
              _fail "R5: status still shows a row for lane 7"; return 1
          fi
          # Self-cleanup (lanes 1-6 seeds; 7 is already gone on the happy path).
          rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/"[1-6].json 2>/dev/null || true
          rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/7" 2>/dev/null || true
      }
      ----------------------------------------------------------------
  - ALSO append the case to _br_run_suite's hardcoded list:
        FIND:  for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e \
                        r3_control_delayed_boot_succeeds r3_bug002_race_e2e \
                        r3_neg_dead_ids_release_still_kills r4_bug002_preport_race; do
        REPLACE WITH (append r5, keep the wrapping):
               for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e \
                        r3_control_delayed_boot_succeeds r3_bug002_race_e2e \
                        r3_neg_dead_ids_release_still_kills r4_bug002_preport_race \
                        r5_bug003_corrupt_lease_reclaimed; do
  - GOTCHA (both edits are mandatory): the function alone is never run — the list is
        hardcoded (no compgen discovery in bootrace). A missing list entry = vacuous green.
  - GOTCHA (status row regex): pool_admin_status prints a formatted row whose FIRST field
        is the lane number (the corrupt row: `printf -- "$fmt" "$lane" "?" "?" ...`). The
        grep pattern `'^ *7 '` matches a row starting with (optionally padded) "7 ". If the
        fmt has no leading spaces, `^7 ` still matches via ` *`. Verified against the
        corrupt-row printf at ~line 4403.
  - GOTCHA (find_free_lane in a subshell): the subshell-source idiom `( trap - EXIT INT
        TERM; source ... && pool_config_init && pool_find_free_lane )` — the `trap -`
        prevents the suite's EXIT trap from firing inside the subshell (it would rm the
        whole sandbox mid-suite). `|| true` on the capture keeps set -e safe; the [[ != ]]
        assertion catches an empty/failed output.
  - GOTCHA (TDD checkpoint): run `timeout 300 bash test/bootrace.sh` NOW — R5 must FAIL
        ("corrupt lease 7.json still present after reap (BUG-003 reproduced)") while the
        6 existing cases still pass. That red run is the proof the test detects the bug.
        (Per AGENTS.md it is safe: bootrace is hermetic + single-setup + timeout-wrapped.)

Task 3: EDIT lib/pool.sh — add the corrupt-lease removal to pool_reap_orphan_dirs' orphan branch
  - FIND (the exact current tail of the orphan branch — verify with the Task 1 read):
            # Prefix-guarded rm (mirror _pool_release_lane_internals). `|| true` (TOCTOU-safe).
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            _pool_log "pool_reap(orphan): removed orphan dir $dir (no lease)"
            orphans=$((orphans + 1))
  - REPLACE WITH (insert the new block between the _pool_log and the counter):
            # Prefix-guarded rm (mirror _pool_release_lane_internals). `|| true` (TOCTOU-safe).
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            _pool_log "pool_reap(orphan): removed orphan dir $dir (no lease)"
            # BUG-003 (fix_design §4 seam 1): ALSO remove a present-but-INVALID lease file.
            # Reaching this branch with the file present means it is corrupt (pool_lease_exists
            # rc 1 = missing OR corrupt; the dir is now gone) — definitionally unowned AND
            # unreclaimable by any other verb (pool_lane_is_stale rc 2 skips it; release
            # refuses; pool_find_free_lane's [[ -f ]] DELIBERATELY treats it as occupied for
            # collision safety) → reap is the designated reclaimer. Removing the FILE (not
            # weakening the guards) frees the lane number. The [[ -f ]] short-circuits the
            # common missing-file orphan (zero extra forks); the second pool_lease_exists call
            # re-probes only to confirm corrupt-vs-missing. Both sit in the `if` condition
            # (errexit-exempt — rc 1 is a signal, not an error). $base is ^[0-9]+$-validated
            # upstream → injection-safe. NOT counted in $orphans (dirs only — the admin report
            # "Removed N orphan dir(s)." stays honest).
            if [[ -f "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base"; then
                rm -f -- "$POOL_LANES_DIR/$base.json"
                _pool_log "pool_reap(orphan): removed corrupt lease $POOL_LANES_DIR/$base.json (BUG-003)"
            fi
            orphans=$((orphans + 1))
  - WHY: fix_design §4 seam 1, verbatim shape. Dir gone + corrupt lease = definitionally
        unowned → safe to free the lane number.
  - PRESERVE: everything else in the function — the (a) no-root guard, the glob loop + base
        validation, the (c) `if ! pool_lease_exists "$base"` gate, the anchored pgrep/pkill
        block, the prefix-guarded dir rm, the `_pool_log` orphan-dir line, the (e) count
        echo + rc-0-always.
  - GOTCHA: do NOT touch pool_lane_is_stale / pool_find_free_lane / _pool_atomic_write /
        pool_admin_reap / pool_reap_stale / pool_admin_release / pool_admin_status.

Task 4: EDIT README.md — the one-sentence Mode A note in `### reap`
  - FIND (the paragraph in the `### reap` section, ~line 236):
        Tear down lanes whose owning harness process has died (kill the Chrome process group, delete the
        ephemeral profile dir, remove the lease) **and** remove orphan ephemeral dirs (numeric
        `active/<N>/` directories left by an interrupted boot or a crashed release that have no
        lease and no live owner — killing any orphaned Chrome still pointed at them). Always exits 0.
  - REPLACE WITH (append one sentence before "Always exits 0."):
        Tear down lanes whose owning harness process has died (kill the Chrome process group, delete the
        ephemeral profile dir, remove the lease) **and** remove orphan ephemeral dirs (numeric
        `active/<N>/` directories left by an interrupted boot or a crashed release that have no
        lease and no live owner — killing any orphaned Chrome still pointed at them). A
        corrupt/unparseable `lanes/<N>.json` left behind after its lane dir is gone is also
        removed, freeing the lane number. Always exits 0.
  - GOTCHA: ONE sentence. The broader changeset README reconciliation is P1.M3.T2.S1.

Task 5: VERIFY — the full gate (hermetic; bootrace is safe per AGENTS.md via its own sandbox)
  - RUN (in order):
      bash -n lib/pool.sh
      bash -n test/bootrace.sh
      shellcheck -s bash -S warning lib/pool.sh
      shellcheck -s bash -S warning test/bootrace.sh
      timeout 300 bash test/bootrace.sh
  - EXPECTED:
      bash -n (both)        → clean (no output)
      shellcheck (both)     → rc 0, zero findings at -S warning
      bootrace              → rc 0, "7 passed, 0 failed" (6 prior cases + R5 now GREEN;
                              R5 was RED at the Task-2 checkpoint before the Task-3 fix)
  - RUN (the BUG-003 repro from the PRD, verbatim, isolated — proves the end-to-end fix):
        T="$(mktemp -d)"
        mkdir -p "$T/state/lanes" "$T/active/7"
        printf 'not json {{{' >"$T/state/lanes/7.json"
        printf 'x' >"$T/active/7/Preferences"
        HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" \
        AGENT_CHROME_EPHEMERAL_ROOT="$T/active" AGENT_CHROME_MASTER="$T/master" \
        AGENT_CHROME_ALLOW_SLOW_COPY=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_reap_orphan_dirs >/dev/null; \
                 [[ ! -e "$T/active/7" ]] || { echo "FAIL dir"; exit 1; }; \
                 [[ ! -e "$T/state/lanes/7.json" ]] || { echo "FAIL lease"; exit 1; }; \
                 echo "BUG-003 FIXED"' T="$T"
        rm -rf -- "$T"
      # Expected: BUG-003 FIXED   (before the fix: "FAIL lease").
  - RUN (negative regression — a NORMAL orphan with no lease file still reaps, count intact):
        T="$(mktemp -d)"; mkdir -p "$T/state/lanes" "$T/active/3"; printf 'x' >"$T/active/3/m"
        HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
        AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 c="$(pool_reap_orphan_dirs)"; [[ "$c" == "1" ]] || { echo "FAIL count=$c"; exit 1; }; \
                 [[ ! -e "$T/active/3" && ! -e "$T/state/lanes/3.json" ]] || { echo "FAIL artifacts"; exit 1; }; \
                 echo "NORMAL ORPHAN OK"' T="$T"
        rm -rf -- "$T"
      # Expected: NORMAL ORPHAN OK  (count 1, dir gone, no lease was ever there).
  - RUN (scope check — only the 3 intended files changed):
        git status --porcelain
        git diff --stat
      # Expected: lib/pool.sh, test/bootrace.sh, README.md ONLY. In particular
      #   pool_lane_is_stale / pool_find_free_lane / _pool_atomic_write / pool_admin_release
      #   bodies untouched: git diff lib/pool.sh | grep -E '^[-+]' | grep -vE '^[-+]{3}' \
      #   should show ONLY the new block's lines inside pool_reap_orphan_dirs.
  - FIX any failure before claiming done.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern A — the fix block (fix_design §4 seam 1, house-style guards) --------
# Inside pool_reap_orphan_dirs' orphan branch, after the dir rm + its _pool_log:
if [[ -f "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base"; then
    rm -f -- "$POOL_LANES_DIR/$base.json"
    _pool_log "pool_reap(orphan): removed corrupt lease $POOL_LANES_DIR/$base.json (BUG-003)"
fi
# * the whole guard is ONE if-condition → every rc-1 (corrupt/missing) is an errexit-exempt
#   branch, never an abort (same idiom as the branch's own `if ! pool_lease_exists` gate).
# * `[[ -f ]]` short-circuits the common missing-file orphan → no rm, no extra probe fork.
# * `rm -f --` on a ^[0-9]+$-validated basename → injection-safe; -f tolerates a TOCTOU
#   disappearance between the probe and the rm (idempotent, no error).
# * NOT counted in $orphans — the count is DIRS; the admin report stays honest.

# --- Pattern B — the R5 subshell-source idiom (bootrace house style, from r1) -----
n="$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && \
        pool_config_init && pool_find_free_lane ) 2>/dev/null || true )"
# `trap -` disables the suite's EXIT trap inside the subshell (it would rm the sandbox
# mid-suite); the outer `|| true` keeps set -e safe; the assertion on "$n" catches failure.

# --- Pattern C — bootrace case skeleton (mirror r1/r2) ----------------------------
r5_bug003_corrupt_lease_reclaimed() {
    # seed → run the verb under timeout → _fail+return 1 per assertion → self-cleanup
    out="$(timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" reap 2>/dev/null || true)"
    ...
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/"[1-6].json 2>/dev/null || true
}
# + MANDATORY: append the case name to _br_run_suite's hardcoded `for fn in ...` list
#   (bootrace does NOT compgen-discover — a missing entry is a vacuous green).

# --- Critical micro-rules ---------------------------------------------------------
#  * pool_lease_exists is a predicate (rc 1 = signal) — NEVER call it bare under set -e.
#  * $base is ^[0-9]+$-validated before use (both the existing loop and the new rm rely on it).
#  * `rm -rf --` keeps its existing prefix-guard for the DIR; the LEASE rm needs no
#    prefix-guard (it is a single literal .json path, not a glob).
#  * _pool_log never fails its caller (stderr fallback) — safe on the reap path.
#  * orphans count semantics UNCHANGED (dirs only).
```

### Integration Points

```yaml
CODE (in-place edits in 3 files, no new files):
  - lib/pool.sh  : pool_reap_orphan_dirs orphan branch — insert the corrupt-lease block
                   between the orphan-dir _pool_log and orphans=$((orphans + 1)).
  - test/bootrace.sh : + r5_bug003_corrupt_lease_reclaimed function (after r4's `}`,
                   before _br_run_suite) + the name appended to the hardcoded case list.
  - README.md    : + 1 sentence in `### reap` (Mode A — rides with this subtask).

CONSUMERS (auto-benefiting, NO changes needed):
  - pool_admin_reap (reap verb) → calls pool_reap_orphan_dirs; its "Removed N orphan
    dir(s)." message is unchanged (count = dirs); the corrupt-lease removal happens inside.
  - pool_wait_for_lane's force-reap path (exhaustion) → same function.
  - pool_admin_status → after a reap clears the corrupt lease, the '? STALE' row disappears
    (no file → no row).
  - pool_find_free_lane → after the file is gone, the lane number is free again.

DO NOT TOUCH:
  - pool_lane_is_stale (rc 2 skip)            deliberate collision safety
  - pool_find_free_lane ([[ -f ]])            deliberate collision safety
  - _pool_atomic_write (no fsync)             deliberate + documented (fix_design §4 decision)
  - pool_admin_release numeric branch         P1.M2.T1.S2 (seam 2)
  - pool_admin_reap / pool_reap_stale         correct as-is; the fix is inside the helper
  - pool_admin_status                         auto-benefits; no edit
  - the 4 other repo suites                   P1.M3.T1.S1's gate re-runs them

CONFIG / DATABASE / ROUTES: none. No env vars, no globals, no new deps.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh
bash -n test/bootrace.sh
shellcheck -s bash -S warning lib/pool.sh
shellcheck -s bash -S warning test/bootrace.sh
# Expected: bash -n silent on both; shellcheck rc 0, zero findings on both (the pre-edit
#           baseline is clean — the new code uses only already-clean idioms).
```

### Level 2: Unit Tests (Component Validation)

```bash
# 2a. The new block in isolation (the BUG-003 state, direct helper call):
T="$(mktemp -d)"
mkdir -p "$T/state/lanes" "$T/active/7"
printf 'not json {{{' >"$T/state/lanes/7.json"; printf 'x' >"$T/active/7/m"
HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_reap_orphan_dirs >/dev/null; \
         [[ ! -e "$T/active/7" && ! -e "$T/state/lanes/7.json" ]] && echo "OK both gone"' T="$T"
rm -rf -- "$T"
# Expected: OK both gone   (pre-fix: the lease survives → no output + rc 1).

# 2b. Valid lease + dir = NOT an orphan (the guard gate must still protect live lanes):
T="$(mktemp -d)"
mkdir -p "$T/state/lanes" "$T/active/2"
printf '{"lane":2,"port":53402}' >"$T/state/lanes/2.json"
HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         c="$(pool_reap_orphan_dirs)"; [[ "$c" == "0" ]] && \
         [[ -d "$T/active/2" && -f "$T/state/lanes/2.json" ]] && echo "OK live lane untouched"' T="$T"
rm -rf -- "$T"
# Expected: OK live lane untouched  (pool_lease_exists rc 0 → not an orphan → nothing removed).

# 2c. Normal orphan (no lease file) — count semantics intact (no false corrupt-lease log):
T="$(mktemp -d)"; mkdir -p "$T/state/lanes" "$T/active/3"; printf 'x' >"$T/active/3/m"
HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         c="$(pool_reap_orphan_dirs)"; [[ "$c" == "1" && ! -e "$T/active/3" ]] && echo "OK count=1"' T="$T"
rm -rf -- "$T"
# Expected: OK count=1.

# 2d. The bootrace suite (all cases incl. the new R5):
timeout 300 bash test/bootrace.sh
# Expected: rc 0, "7 passed, 0 failed" (TDD: R5 was RED before the lib/pool.sh edit).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. The PRD h3.2 repro END-TO-END through the admin CLI (status → reap → status → acquire):
T="$(mktemp -d)"
mkdir -p "$T/state/lanes" "$T/active/7" "$T/master/Default"
printf 'x' >"$T/master/Default/Preferences"
printf 'not json {{{' >"$T/state/lanes/7.json"; printf 'x' >"$T/active/7/Preferences"
run() { HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" \
        AGENT_CHROME_EPHEMERAL_ROOT="$T/active" AGENT_CHROME_MASTER="$T/master" \
        AGENT_CHROME_ALLOW_SLOW_COPY=1 timeout 30 "$PWD/bin/agent-browser-pool" "$@"; }
run status | grep -qE '^ *7 ' && echo "pre-reap: row visible (expected)"
run reap                      # → "Removed 1 orphan dir(s)." (wording unchanged)
run status | grep -qE '^ *7 ' && echo "FAIL: row still visible" || echo "post-reap: row gone (FIXED)"
[[ ! -e "$T/state/lanes/7.json" ]] && echo "lease gone (FIXED)"
rm -rf -- "$T"
# Expected: "pre-reap: row visible", "Removed 1 orphan dir(s).",
#           "post-reap: row gone (FIXED)", "lease gone (FIXED)".

# 3b. Lane un-burned — find_free_lane returns 7 once 1-6 are file-occupied (R5's assertion):
#    (covered inside R5; this is the standalone equivalent)
T="$(mktemp -d)"; mkdir -p "$T/state/lanes"
for n in 1 2 3 4 5 6; do printf '{"port":%d}' "$((53400+n))" >"$T/state/lanes/$n.json"; done
HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         [[ "$(pool_find_free_lane)" == "7" ]] && echo "OK lane 7 reclaimable"' T="$T"
rm -rf -- "$T"
# Expected: OK lane 7 reclaimable.

# 3c. Scope check — only the intended files/functions changed:
git status --porcelain
git diff lib/pool.sh | grep -E '^[-+]' | grep -vE '^[-+]{3}'
# Expected: changed files = lib/pool.sh, test/bootrace.sh, README.md ONLY; the pool.sh diff
#           shows ONLY the inserted block inside pool_reap_orphan_dirs (no deletions except
#           none; pure insertion).

# 3d. The other suites are unaffected but spot-check the pure-function one:
timeout 600 bash test/validate.sh
# Expected: rc 0, prior green count (the fix adds behavior only inside a corrupt-lease
#           branch no existing case seeds). (P1.M3.T1.S1 re-runs all four.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the corrupt-detection primitive used by the guard (the jq-empty predicate):
T="$(mktemp -d)"; printf 'not json {{{' >"$T/7.json"
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_json_valid "$1/7.json"; then echo "UNEXPECTED valid"; exit 1; else echo "OK corrupt detected"; fi' _ "$T"
rm -rf -- "$T"
# Expected: OK corrupt detected   (this is WHY pool_lease_exists returns rc 1 for the seed).

# 4b. Confirm the _pool_log line lands in the pool log (observability of the new path):
T="$(mktemp -d)"; mkdir -p "$T/state/lanes" "$T/active/7"
printf 'not json {{{' >"$T/state/lanes/7.json"; printf 'x' >"$T/active/7/m"
HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_reap_orphan_dirs >/dev/null; \
         grep -q "removed corrupt lease" "$T/state/pool.log" && echo "OK logged"' T="$T"
rm -rf -- "$T"
# Expected: OK logged.

# 4c. AGENTS.md leak sweep after running the suites:
pgrep -af 'fake-chrome|fake-cdp|abpool-bootrace|fake-agent-browser' | grep -v pgrep \
  || echo "no stray test processes"
ls -d "$HOME"/abpool-bootrace.* /tmp/abpool-bootrace.* /tmp/fake-cdp.* 2>/dev/null \
  || echo "no leftover test roots"
# Expected: both "no stray..." messages (bootrace's trap + per-case cleanup hold).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` clean on `lib/pool.sh` + `test/bootrace.sh`.
- [ ] `shellcheck -s bash -S warning` zero findings on both.
- [ ] Level 2: 2a (both artifacts gone), 2b (live lane untouched), 2c (count=1, normal orphan), 2d (bootrace 7/7 green).
- [ ] Level 3: 3a (the full PRD repro through the CLI), 3b (lane 7 reclaimable), 3c (scope diff), 3d (validate.sh still green).
- [ ] Level 4: 4a (corrupt predicate), 4b (log line), 4c (zero leaks).

### Feature Validation

- [ ] `reap` removes a corrupt `lanes/N.json` once its dir is gone; `_pool_log` records it.
- [ ] The orphan count still counts DIRS only; the `Removed N orphan dir(s).` wording unchanged.
- [ ] Normal orphans (no lease file) unaffected (`[[ -f ]]` short-circuit).
- [ ] Live lanes (valid lease) unaffected (the orphan-branch gate fires first).
- [ ] `r5_bug003_corrupt_lease_reclaimed` added AND registered in `_br_run_suite`'s list.
- [ ] README `### reap` has the one-sentence Mode A note.

### Code Quality Validation

- [ ] Only 3 files changed (lib/pool.sh, test/bootrace.sh, README.md).
- [ ] `pool_lane_is_stale`, `pool_find_free_lane`, `_pool_atomic_write`, `pool_admin_release`,
      `pool_admin_reap`, `pool_reap_stale`, `pool_admin_status` bodies untouched.
- [ ] Every rc-1 call inside an `if` condition (errexit-exempt); `rm -f --` quoted + guarded.
- [ ] Case style mirrors r1/r2 (subshell-source idiom, `_fail`+return, self-cleanup, timeout).
- [ ] Comments reference BUG-003 / fix_design §4 (traceability, house style).

### Documentation & Deployment

- [ ] README sentence is accurate and minimal; no new env vars; no config changes.
- [ ] fsync decision NOT re-litigated in code (fix_design §4: no code change) — a comment
      reference is acceptable but no behavioral edit.

---

## Anti-Patterns to Avoid

- ❌ Don't weaken the collision-safety guards — `pool_lane_is_stale`'s rc-2 skip and
  `pool_find_free_lane`'s `[[ -f ]]` are DELIBERATE (corrupt = "unknown → treat as
  occupied" so a possibly-in-use lane is never handed to two owners). Remove the FILE in
  the reap path; never touch the guards (system_context §7: "Do not change this").
- ❌ Don't increment `$orphans` for the lease removal — the count is DIRS;
  `pool_admin_reap`'s user-facing message would lie.
- ❌ Don't call `pool_lease_exists` bare (outside `if`/`||`) — rc 1 aborts under set -e.
- ❌ Don't remove the `[[ -f ]]` half of the guard — without it you'd rm a nonexistent path
  (harmless) but the `_pool_log` would claim a corrupt-lease removal that didn't happen.
- ❌ Don't add fsync to `_pool_atomic_write` — the fix_design §4 decision is NO code change
  (atomic rename already prevents torn files; the reclaim seams handle any corrupt cause).
- ❌ Don't implement seam 2 (`pool_admin_release` corrupt-lease handling) — that's
  P1.M2.T1.S2. Similarly don't add the `lanes/*.tmp` sweep (a possible doctor extension,
  out of scope).
- ❌ Don't forget the `_br_run_suite` case-list append — bootrace does NOT auto-discover;
  a function without a list entry is a vacuous green.
- ❌ Don't spawn fake-chrome or an owner in R5 — the orphan branch's pgrep matching nothing
  is the point (no kill path); keep the case a sub-second filesystem test.
- ❌ Don't run anything against the operator's real state dirs — bootrace's setup already
  redirects; the standalone snippets above redirect explicitly. Wrap CLI runs in `timeout`.
- ❌ Don't skip the TDD checkpoint — R5 must be observed RED on pre-fix code before the
  lib/pool.sh edit (that red run is the proof the test detects BUG-003).
- ❌ Don't reformat the surrounding function or "improve" the anchored pgrep/pkill block —
  pure insertion between the `_pool_log` line and the counter.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The fix block is quoted VERBATIM from fix_design.md §4 (the designed seam), is 3 lines of
  logic + guards already proven one line above in the same function, and its safety argument
  (dir gone + corrupt lease = definitionally unowned) is airtight.
- Every edit site was verified by direct read at the CURRENT line numbers this session (the
  item contract's baseline had drifted — the PRP carries both, with a match-by-text rule).
- The R5 test mirrors two existing, passing bootrace cases (r1's assertion style; r2's
  CLI-under-timeout + subshell-source idiom) and encodes the PRD h3.2 repro verbatim; the
  TDD red→green checkpoint is built into the task order.
- The hazards are all catalogued with their house-style answers: rc-1 predicates in if-conditions,
  the hardcoded runner list, count semantics, self-cleanup, timeout-wrapping, and the
  do-not-touch list (collision-safety guards, fsync, S2's seam).
- The -1 reflects residual risk in the `status` row-grep assertion (`'^ *7 '`) — the exact
  output format of `pool_admin_status` is fmt-driven and was verified only by reading the
  corrupt-row printf (~line 4403), not by running it pre-fix; if the padding differs, the
  implementer adjusts the regex per the quoted printf (a one-character fix, caught by the
  Task-2 red run immediately).