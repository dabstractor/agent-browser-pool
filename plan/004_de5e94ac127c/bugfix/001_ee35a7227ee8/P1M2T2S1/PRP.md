# PRP — P1.M2.T2.S1: Doctor pre-creates the ephemeral root before the findmnt probe (BUG-004) + R7

---

## Goal

**Feature Goal**: Eliminate **BUG-004** — `pool_admin_doctor` false-FAILs its `[filesystem]`
check ("FAIL (unknown; not btrfs)" + doctor rc 1) on a fresh install simply because the
ephemeral root directory does not exist yet. `findmnt -nno FSTYPE -T <missing-path>` exits 1
with EMPTY output (host-verified), and doctor's `|| true` turns that into `fstype=""` → the
FAIL branch — even on a 100% btrfs host. The ephemeral root is legitimately absent on a fresh
install: `install.sh` pre-creates only the STATE dir (`pool_state_init`), and the ephemeral
root is first created by `pool_copy_master` at first acquire. Per **fix_design.md §3** (the
CHOSEN design: pre-create, not ancestor-probe), insert one `mkdir -p` line (non-fatal, the
`pool_copy_master` pattern) immediately before doctor's `fstype` capture so the probe is
exact on the first run AND self-heals for repeat runs. Ship with regression case **R7**
(TDD red→green) and a one-sentence Mode-A README note.

**Deliverable** (three artifacts, all small):
1. **`lib/pool.sh`** — inside `pool_admin_doctor`'s `[filesystem]` block, immediately before
   the `fstype` capture (currently **line 4971**; the block spans ~4963-4984): insert a
   BUG-004 comment + `mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true`. The
   OK/WARN/FAIL branches and their printf message formats stay **byte-identical** — only the
   empty-string *cause* disappears.
2. **`test/bootrace.sh`** — add case `r7_bug004_doctor_fresh_install` (after R6's closing
   `}`, before `_br_run_suite` ~line 575) **AND** register it in `_br_run_suite`'s HARDCODED
   case list (~577-580) after `r6_bug003_release_corrupt_lease`. Suite goes 8 → **9 cases**.
3. **`README.md`** — `### \`doctor\`` section (line **275**): ONE sentence — doctor creates
   the ephemeral root if absent (so the btrfs check is exact on fresh installs). Mode-A
   (rides with this subtask; P1.M3.T2.S1 does not redo it).

**Success Definition**:
- **R7 green** (after the fix): fresh temp tree + `AGENT_CHROME_EPHEMERAL_ROOT=$T/active-missing`
  (nonexistent) → `doctor`'s `[filesystem]` line is `OK (btrfs)` on this btrfs host, doctor
  rc reflects real findings only (0 in the otherwise-green harness env), and the dir now
  exists (documented side effect).
- **Negative controls still fire**: an existing genuinely non-btrfs path (tmpfs `/dev/shm/…`)
  → `WARN (tmpfs; slow-copy allowed)` under the suite's default `AGENT_CHROME_ALLOW_SLOW_COPY=1`,
  and `FAIL (tmpfs; not btrfs)` + doctor rc 1 with `AGENT_CHROME_ALLOW_SLOW_COPY=0`.
- `bash test/bootrace.sh` → **9 passed, 0 failed** (R1-R6 + control cases intact).
- `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` clean; `install.sh` **unchanged**;
  `pool_check_btrfs` stays removed; `pool_copy_master` untouched.

## User Persona

**Target User**: (a) The **operator installing the pool on a fresh machine** — `install.sh`
step 3 runs doctor as a subprocess and prints "doctor: found problems" on a perfectly healthy
btrfs host (the bug contradicts the install contract). (b) Any user running
`agent-browser-pool doctor` on a cloned-but-uninstalled tree. (c) Future maintainers — R7 pins
the semantics.

**Use Case**: `bash install.sh` on a fresh host → doctor must verify btrfs *correctly*; a bare
`agent-browser-pool doctor` before the first acquire must not report phantom problems.

**User Journey**: fresh clone → `install.sh` → symlink + state dir created → doctor runs →
`[filesystem] … OK (btrfs)`, `Healthy.`, rc 0 → first `agent-browser open …` creates the
ephemeral root at first acquire (and now doctor already created the parent anyway).

**Pain Points Addressed**: a false-FAIL on a healthy machine destroys doctor's signal (and
install's gate) exactly when it's most needed — on first contact with a new host.

## Why

- **Doctor is the install-time gate** (install.sh:103-111 runs it as a subprocess and treats
  rc≠0 as "found problems"). A false FAIL on every fresh btrfs install makes the gate useless
  and teaches operators to ignore it.
- **BUG-004 is the ONLY doctor probe conflating "absent" with "broken"** — deps use
  `command -v`, [binary]/[master] use `-d`/`-x`/`ls -A`; only [filesystem] probes a path
  that legitimately may not exist yet.
- **fix_design.md §3 chose the doctor-side pre-create over the install.sh-side fix**: it also
  fixes bare CLI doctor runs on cloned-but-uninstalled trees, makes repeat runs exact, and
  self-heals (the documented default `~/.agent-chrome-profiles/active` gets created).
  Creating a directory as an operator diagnostic is safe and user-visible.
- **PRD traceability**: this implements the changeset PRD's Minor Issue 2 (h3.3, BUG-004) and
  one line of h2.5's Recommendations ("Probe the nearest EXISTING ancestor … **or pre-create
  the ephemeral root**" — the pre-create alternative, chosen by fix_design §3).

## What

User-visible behavior after the fix:

| Scenario | Before (bug) | After |
|---|---|---|
| Fresh install, ephemeral root absent, host btrfs | `[filesystem]  <root> FAIL (unknown; not btrfs)`; doctor rc 1; install prints "found problems" | `[filesystem]  <root> OK (btrfs)`; rc reflects real findings; **root dir now exists** |
| Root absent + `findmnt` can't create it (perms/RO) | FAIL "(unknown; not btrfs)" | FAIL "(unknown; not btrfs)" — now a **true** failure (cannot create the documented dir) |
| Existing root on non-btrfs + slow-copy allowed | `WARN (<fs>; slow-copy allowed)` | unchanged |
| Existing root on non-btrfs + no slow-copy | `FAIL (<fs>; not btrfs)`, rc 1 | unchanged |
| Repeat doctor runs | same as first | exact (dir exists) |

Internal contract: `mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true` inserted
immediately before `fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"`.
No other line in `pool_admin_doctor` changes; no globals, no env vars, no new functions.

### Success Criteria

- [ ] The mkdir line + BUG-004 comment sit **immediately before** the `fstype` capture inside
  the `[filesystem]` block (re-locate by grep: `grep -n 'fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"' lib/pool.sh` — insert above it).
- [ ] The OK/WARN/FAIL printf branches and message formats are **byte-identical** to before.
- [ ] `mkdir` is **non-fatal** (`2>/dev/null || true`) — doctor NEVER aborts mid-report
  (contrast `pool_copy_master`'s `|| pool_die`, which is correct for *its* fatal context).
- [ ] `findmnt -T` retained verbatim (MANDATORY on this host — bare `findmnt "$dir"` exits 1
  even on btrfs).
- [ ] R7 exists in `test/bootrace.sh` AND is registered in `_br_run_suite`'s list (9 entries).
- [ ] R7's three variants assert: missing-root → `OK (btrfs)` + dir created + rc 0;
  tmpfs + slow-copy=1 → `WARN (tmpfs; slow-copy allowed)`; tmpfs + slow-copy=0 →
  `FAIL (tmpfs; not btrfs)` + rc≠0.
- [ ] R7 was observed RED before the lib/pool.sh fix (TDD) — variant 1 fails with the BUG-004
  symptom — and GREEN after.
- [ ] README `### \`doctor\`` gains exactly one sentence about the create-if-absent behavior.
- [ ] `install.sh`, `pool_copy_master`, the `[dirs]` section, and the `pool_check_btrfs`
  REMOVAL (lib/pool.sh:297) are all untouched.
- [ ] `bash -n` + `shellcheck` clean; `bash test/bootrace.sh` → 9 passed, 0 failed.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. Every fact below is host-verified as of this research
(post-BUG-003-S2 landing, `lib/pool.sh` = 5211 lines): the exact current anchors for the
insert (fstype capture at 4971, block 4963-4984) with grep re-location commands for drift;
the exact fix snippet from fix_design §3; the full R7 case body verbatim (env-prefix
overrides, `/dev/shm` tmpfs control, `AGENT_CHROME_ALLOW_SLOW_COPY=0` override, `_fail || rc_all=1`
style, unconditional cleanup); the hardcoded-list registration requirement (no compgen
discovery — an unregistered case is a vacuous green); the harness facts (BR_T on real btrfs
via `mktemp -d -p "$HOME"`, suite exports `AGENT_CHROME_ALLOW_SLOW_COPY=1`, doctor needs no
`_br_spawn_owner`); verified host FS map (HOME=btrfs, /dev/shm=tmpfs, /tmp=tmpfs); verified
findmnt-on-missing-path behavior (rc 1, empty); doctor's rc semantics (WARN never affects rc;
optional deps MISSING never increments fail); the exact README insertion point; and the
explicit do-not-touch list.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  why: §3 "BUG-004 — doctor probes an existing ancestor" is THE chosen design: contains the
        exact comment + mkdir line to insert, the rationale (pre-create chosen over
        ancestor-probe and over install.sh-side), "Keep findmnt -T", "Do NOT touch
        pool_check_btrfs", "install.sh needs NO change", the README Mode-A note, and the
        test contract R7 paraphrases. §7 gives changeset ordering (this task after M2.T1).
  pattern: §3's snippet is the literal insert.
  gotcha: §3's prose "probes an existing ancestor" describes the bug class; the CHOSEN
        mechanism is the pre-create mkdir in its code block — implement the code block.

- file: PRD.md   # changeset PRD (read-only)
  why: h3.3 = Minor Issue 2 / BUG-004 verbatim (symptom, repro, install.sh interaction);
        h2.5 Recommendations bullet 4 offers ancestor-probe OR pre-create (fix_design picked
        pre-create); h2.3 is the minor-issues context.
  pattern: h3.3's "Steps to Reproduce" is R7's positive case almost verbatim.
  gotcha: PRD line cites are stale (doctor moved; file grew to 5211 lines) — re-locate by grep.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M2T2S1/research/bug004-doctor-fs-probe.md
  why: THIS task's research note — all host-verified facts: live repro of the bug, exact
        anchors + grep re-location, the pool_copy_master pattern (1330-1337) and why doctor's
        variant is non-fatal, the do-not-touch list (pool_check_btrfs REMOVED @297, install.sh,
        pool_copy_master, [dirs] guard analysis), doctor rc semantics (optional deps never
        increment fail), the bootrace harness contract (BR_T on btrfs, exported env incl.
        ALLOW_SLOW_COPY=1, hardcoded case list @577-580, R5/R6 case style, no owner needed),
        host FS map (btrfs/tmpfs), grep assertion style (`grep -qF -- "$root OK (btrfs)"`),
        README insertion point.
  pattern: §6-§7 are the R7 construction manual.
  gotcha: none — everything re-verifiable by the commands it contains.

- file: lib/pool.sh   # the code under change
  section: pool_admin_doctor() @4856; [filesystem] block @4963-4984 (fstype capture @4971);
        pool_copy_master mkdir-parent @1330-1337 (pattern); pool_check_btrfs REMOVAL note @297;
        [dirs] [[ -d ]] guard ~5085-5090; [summary]/rc ~5108-5120.
  why: exact insertion context; the three printf formats to keep byte-identical.
  gotcha: line numbers drift (S2 landed R6 + release branch since the item was written) —
        ALWAYS re-locate via the greps in the research note §2.

- file: test/bootrace.sh
  section: header/harness 1-120 (_bootrace_setup env exports, _fail, timeout contract);
        R5 @467-509 and R6 @511-573 (case-style templates); _br_run_suite @575-590
        (HARDCODED case list — registration mandatory).
  why: R7's home; the case-list registration gotcha (no auto-discovery).
  gotcha: suite-wide `AGENT_CHROME_ALLOW_SLOW_COPY=1` — R7's FAIL variant MUST override to 0
        per-command; case list currently has 8 entries (r1,r2,r3-control,r3,r3-neg,r4,r5,r6).

- file: README.md
  section: '### `doctor`' @275.
  why: the Mode-A one-sentence note lands here (end of the first paragraph, before
        "Sections, in order:").
  gotcha: P1.M2.T1.S2 edits '### release' (~249-265) — disjoint; do not touch it.

- file: install.sh   # READ ONLY — needs NO change
  section: step 2 pool_state_init @~98; step 3 doctor subprocess @~103-111.
  why: proves the doctor-side fix also heals install.sh's step-3 gate; explicitly out of scope.

# External authoritative docs (background; the fix needs no new externals)
- url: https://man7.org/linux/man-pages/man8/findmnt.8.html
  why: `-T, --target` resolves the mount for a PATH (creates nothing); on a missing path it
        exits 1 with empty output — the exact behavior behind BUG-004 (verified on host).
  section: OPTIONS (-T/--target).
- url: https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html
  why: `mkdir -p` creates parents, is idempotent, and succeeds silently if the dir exists —
        why the single line is safe on every repeat run.
  section: mkdir invocation (-p).
- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: the insert introduces no captures, but R7's `out="$(…)" || rc=$?` follows the
        declare-then-assign rule used throughout the harness.
```

### Current Codebase tree (relevant slice; repo root = agent-browser-pool/)

```bash
├── install.sh                      # UNCHANGED (doctor subprocess at ~103-111)
├── lib/
│   └── pool.sh                     # 5211 lines
│       ├── 297   pool_check_btrfs REMOVAL note (leave as-is)
│       ├── 1330-1337 pool_copy_master mkdir-parent (pattern; do not touch)
│       ├── 4856  pool_admin_doctor()
│       ├── 4963-4984 [filesystem] block   ← THE FIX (fstype capture @4971)
│       └── ~5108-5120 [summary] + rc
├── test/
│   ├── bootrace.sh                 # R1-R6 landed; _br_run_suite @575 (8 cases) ← ADD R7
│   ├── concurrency.sh, release_reaper.sh, transparency.sh, validate.sh  # untouched
└── README.md                       # '### `doctor`' @275 ← one sentence
```

### Desired Codebase tree with files to be added/changed

```bash
├── lib/pool.sh        # MODIFIED: +4 lines in pool_admin_doctor's [filesystem] block
│                       #   (BUG-004 comment + `mkdir -p … || true` before the fstype capture)
├── test/bootrace.sh   # MODIFIED: + ~55 lines (r7 case after R6, before _br_run_suite)
│                       #   + 1 list entry (9 cases)
└── README.md          # MODIFIED: +1 sentence in '### `doctor`'
# NOTHING else changes (install.sh, pool_copy_master, other tests, bin/, docs/ untouched).
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (line drift): the item text cites doctor @4643-4661 — STALE. After P1.M2.T1.S2
# landed (R6 + release corrupt-branch @4682-4715), the [filesystem] fstype capture is at
# lib/pool.sh:4971 (verified). Re-locate, never trust numbers:
#   grep -n 'fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"' lib/pool.sh

# CRITICAL (non-fatal mkdir): use `mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true`
# — NOT pool_copy_master's `|| pool_die`. doctor must NEVER abort mid-report (that's why
# it replicates checks instead of calling the die-ing helpers). If mkdir truly fails, the
# path stays missing → fstype "" → FAIL — now a TRUE finding.

# CRITICAL (findmnt -T is MANDATORY): a bare `findmnt -nno FSTYPE "$dir"` (no -T) matches
# SOURCE not the mount tree and exits 1 EVEN ON BTRFS on this host (external_deps.md §3.2
# omits -T and is broken). Keep `-T` verbatim in the capture you do NOT modify.

# CRITICAL (R7 registration): _br_run_suite iterates a HARDCODED list (test/bootrace.sh:577-580).
# There is NO compgen discovery — a defined-but-unlisted case NEVER RUNS (vacuous green).
# Register r7_bug004_doctor_fresh_install after r6_bug003_release_corrupt_lease → 9 entries.

# CRITICAL (suite exports AGENT_CHROME_ALLOW_SLOW_COPY=1): R7's FAIL variant needs the
# per-command override `AGENT_CHROME_ALLOW_SLOW_COPY=0` (a prefix assignment overrides the
# exported value for that one subprocess; _pool_config_bool: exactly "1" = on). Without it,
# a tmpfs path yields WARN, not FAIL — the negative control would silently weaken.

# GOTCHA (no _br_spawn_owner needed): doctor never consults owner identity; config+state
# init happen inside doctor. R7 must NOT spawn an owner process (keep it cheap + zero-orphan).

# GOTCHA (BR_T is on real btrfs): _bootrace_setup uses `mktemp -d -p "$HOME"` — that is WHY
# R7's missing-root variant probes btrfs. Do not relocate the temp tree.

# GOTCHA (non-btrfs control = /dev/shm): verified tmpfs on this host (/tmp is also tmpfs;
# either works — /dev/shm avoids colliding with anything). The case MUST rm it in cleanup.

# GOTCHA (set -e discipline in the case): R6 style — locals up front; `out="$(env… timeout 30
# "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?` (plain assignment after a
# separate `local` = SC2155-safe, rc preserved); `(( ))` only inside `if`; assertions via
# `_fail "R7: …" || rc_all=1`; snapshot BEFORE cleanup; cleanup unconditional `|| true`;
# end `return "$rc_all"`.

# GOTCHA (grep assertions): use `grep -qF -- "$root OK (btrfs)" <<<"$out"` — fixed-string,
# anchored to the unique temp path (which is >22 chars, so the %-22s padding never truncates
# it out of the line). Do NOT regex (temp paths contain '.' and '/').

# GOTCHA (message formats are FROZEN): OK/WARN/FAIL printf lines stay byte-identical. R7
# greps depend on them: "OK (btrfs)", "WARN (tmpfs; slow-copy allowed)", "FAIL (tmpfs; not btrfs)".

# GOTCHA (do-not-touch): pool_check_btrfs is REMOVED (@297) — leave removed, do not
# "restore"; pool_copy_master (BUG-001/002 territory) is read-only reference; install.sh
# explicitly needs NO change; the [dirs] section's `[[ -d ]]` guard already handles an
# empty created root ("(no ephemeral dirs)") — no output change there.

# GOTCHA (parallel sibling): P1.M2.T1.S2 (BUG-003 release + R6 + README '### release')
# LANDED — do not conflict; your README edit is '### doctor' only, your lib edit is the
# doctor [filesystem] block only, your test edit is after R6 only.
```

## Implementation Blueprint

### Data models and structure

None — this is a surgical 1-line behavioral fix + test + doc. No globals, no env vars, no
functions added or removed, no schema. (Listed for template completeness: N/A.)

### Implementation Tasks (TDD: red → green → docs)

```yaml
Task 0: CONFIRM the starting state (5 commands, all read-only)
  - RUN: grep -n 'fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"' lib/pool.sh
  - EXPECT: exactly ONE hit (today: 4971) — the insertion point. Note the line.
  - RUN: grep -c 'r6_bug003_release_corrupt_lease' test/bootrace.sh
  - EXPECT: ≥2 (definition + registration) — proves the sibling landed; your R7 appends AFTER it.
  - RUN: grep -n 'pool_check_btrfs has been REMOVED' lib/pool.sh
  - EXPECT: a hit (~297) — the removal note exists; leave it alone.
  - RUN: bash -n lib/pool.sh && bash -n test/bootrace.sh && echo OK
  - RUN: grep -n '### `doctor`' README.md   # EXPECT: 275 (or wherever — your note goes there)

Task 1: RED — add R7 to test/bootrace.sh BEFORE touching lib/pool.sh
  - PLACEMENT: the case function goes after R6's closing `}` and before `_br_run_suite`
        (~line 575). ALSO append `r7_bug004_doctor_fresh_install` to the for-list in
        _br_run_suite (the continuation line after `r6_bug003_release_corrupt_lease`; the
        list then has 9 entries). MISSING REGISTRATION = the case never runs (vacuous green).
  - IMPLEMENT (verbatim-ready — mirrors R6's style; locals up front; snapshot before cleanup;
        cleanup unconditional; no _br_spawn_owner — doctor ignores owner identity):
        # R7 — BUG-004 (fix_design §3): doctor must not false-FAIL [filesystem] when the
        # ephemeral root does not exist yet (fresh install: install.sh pre-creates only the
        # STATE dir; the root is first created by pool_copy_master at first acquire).
        # findmnt -T on a MISSING path exits 1 EMPTY → fstype "" → false "not btrfs".
        # Fix under test: doctor mkdir -p's the root before probing (pre-create, non-fatal).
        # Three variants:
        #   (1) MISSING root on the harness's btrfs tree → 'OK (btrfs)' + dir created + rc 0
        #       (every other doctor check is green in the harness env, so rc reflects ONLY
        #       real findings);
        #   (2) existing tmpfs (non-btrfs) root + suite-default ALLOW_SLOW_COPY=1 → WARN
        #       (proves the WARN branch still fires);
        #   (3) same root + ALLOW_SLOW_COPY=0 → FAIL + rc≠0 (proves a GENUINE non-btrfs
        #       finding still fails — the false-FAIL is gone, the true one stays).
        r7_bug004_doctor_fresh_install() {
            local rc out root_missing root_tmpfs rc_all
            root_missing="$BR_T/active-missing"
            root_tmpfs="$(mktemp -d -p /dev/shm -t abpool-r7-nonbtrfs.XXXXXX)"
            rc_all=0

            # --- variant 1: MISSING root → OK (btrfs) + dir created + rc 0 ---
            # Prefix assignment overrides the suite-exported AGENT_CHROME_EPHEMERAL_ROOT for
            # this ONE subprocess (plain assignment after `local` = SC2155-safe).
            rc=0
            out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_missing" \
                   timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
            if (( rc != 0 )); then
                _fail "R7: doctor rc=$rc with missing ephemeral root (BUG-004 reproduced)" || rc_all=1
            fi
            if ! grep -qF -- "$root_missing OK (btrfs)" <<<"$out"; then
                _fail "R7: [filesystem] expected 'OK (btrfs)' for missing root: $root_missing" || rc_all=1
            fi
            if [[ ! -d "$root_missing" ]]; then
                _fail "R7: doctor did not create the missing ephemeral root" || rc_all=1
            fi

            # --- variant 2: existing NON-btrfs (tmpfs) + ALLOW_SLOW_COPY=1 → WARN ---
            rc=0
            out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_tmpfs" \
                   timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
            if ! grep -qF -- "$root_tmpfs WARN (tmpfs; slow-copy allowed)" <<<"$out"; then
                _fail "R7: expected 'WARN (tmpfs; slow-copy allowed)' for $root_tmpfs" || rc_all=1
            fi

            # --- variant 3: same root + ALLOW_SLOW_COPY=0 → FAIL + rc 1 ---
            rc=0
            out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_tmpfs" AGENT_CHROME_ALLOW_SLOW_COPY=0 \
                   timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
            if (( rc == 0 )); then
                _fail "R7: doctor rc=0 on genuine non-btrfs without slow-copy (expected 1)" || rc_all=1
            fi
            if ! grep -qF -- "$root_tmpfs FAIL (tmpfs; not btrfs)" <<<"$out"; then
                _fail "R7: expected 'FAIL (tmpfs; not btrfs)' for $root_tmpfs" || rc_all=1
            fi

            # --- cleanup (unconditional; AGENTS.md §3) ---
            rm -rf -- "$root_missing" "$root_tmpfs" 2>/dev/null || true
            return "$rc_all"
        }
  - VERIFY (RED — against the UNFIXED lib/pool.sh, expect exactly the BUG-004 symptom):
        bash test/bootrace.sh 2>&1 | sed -n '/== r7_bug004/,/FAIL/p'
    - EXPECT: R7 FAILs: "doctor rc=1 with missing ephemeral root (BUG-004 reproduced)" and/or
        "expected 'OK (btrfs)'…". Variants 2-3 already pass (WARN/FAIL branches are correct
        today). The suite summary shows 8 passed, 1 failed — ONLY R7 failing is a correct RED.
    - NOTE: if R7 fails differently (e.g. fixtures), fix the CASE before proceeding — do not
        weaken assertions to force a shape.

Task 2: GREEN — the fix in lib/pool.sh
  - LOCATE: grep -n 'fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"' lib/pool.sh
  - EDIT: immediately BEFORE that capture line (and after `printf '[filesystem]\n'`), insert:
        # BUG-004 (fix_design §3): the ephemeral root may not exist yet on a fresh install
        # (install.sh pre-creates only the state dir; the root is first created by
        # pool_copy_master at first acquire). findmnt -T on a MISSING path exits 1 EMPTY →
        # fstype "" → false "not btrfs". Mirror pool_copy_master: ensure the dir, then probe
        # it — the probe is exact on the FIRST run and repeat runs, and the diagnostic
        # self-heals (creating the documented root is a safe, user-visible side effect).
        # NON-fatal (`|| true`): doctor never aborts mid-report; a genuine mkdir failure
        # (perms/RO-FS) leaves the path absent → fstype "" → a TRUE failure below.
        mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true
  - PRESERVE: the fstype capture line, the OK/WARN/FAIL branches, all printf formats —
        byte-identical. ONLY the inserted comment + mkdir are new.
  - VERIFY:
        bash -n lib/pool.sh && shellcheck -s bash lib/pool.sh && echo CLEAN
        bash test/bootrace.sh 2>&1 | tail -2
    - EXPECT: CLEAN; "9 passed, 0 failed".

Task 3: DOCS — one Mode-A sentence in README.md
  - LOCATE: '### `doctor`' (line ~275). Insert at the END of the first paragraph (after
        "…they do **not** affect the exit code." and before "Sections, in order:") one sentence:
        If the ephemeral root directory does not exist yet, `doctor` creates it — so the
        btrfs check is exact on fresh installs (the root is otherwise first created at your
        first `open`/`connect`).
  - VERIFY: the section still renders as one intro paragraph + the "Sections, in order:" code
        block; ONLY '### `doctor`' changed (git diff README.md).

Task 4: FINAL GATE (all must pass)
  - bash -n lib/pool.sh; shellcheck -s bash lib/pool.sh       # clean
  - bash test/bootrace.sh                                       # 9 passed, 0 failed
  - git diff --stat                                             # exactly 3 files touched
  - Zero-orphan sweep: pgrep -af 'fake-cdp\.|user-data-dir=.*bootrace|abpool-r7' (expect none)
```

### Implementation Patterns & Key Details

```bash
# --- The fix in context (pool_admin_doctor [filesystem] block; after the edit) ---------
    printf '[filesystem]\n'
    # BUG-004 (fix_design §3): … (comment as specced in Task 2) …
    mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
    if [[ "$fstype" == "btrfs" ]]; then
        printf '  %-22s OK (btrfs)\n' "$POOL_EPHEMERAL_ROOT"          # UNCHANGED
        ok=$((ok+1))
    elif [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
        printf '  %-22s WARN (%s; slow-copy allowed)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"  # UNCHANGED
        warn=$((warn+1))
    else
        printf '  %-22s FAIL (%s; not btrfs)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"          # UNCHANGED
        fail=$((fail+1))
    fi

# --- Why non-fatal here (vs pool_copy_master @1336's `|| pool_die`) -------------------
#   pool_copy_master is acquire-critical: a missing parent MUST abort the acquire loudly.
#   doctor is a diagnostic: it must complete ALL sections and summarize; aborting mid-report
#   destroys its purpose. Hence `2>/dev/null || true` — and a real mkdir failure degrades to
#   the FAIL branch, which is the honest verdict ("cannot create the documented dir").

# --- R7 micro-rules (mirrors the harness's R5/R6 conventions) --------------------------
#   * per-command env override via prefix assignment (AGENT_CHROME_EPHEMERAL_ROOT=x …)
#     beats the suite's exports for exactly one subprocess — no export/unexport dance.
#   * `out="$(… 2>&1)" || rc=$?` — assignment AFTER separate `local out` (SC2155-safe);
#     the rc of the doctor subprocess is preserved in $?.
#   * grep -qF (fixed-string) anchored to the full unique temp root; never regex on paths.
#   * `(( rc != 0 ))` / `(( rc == 0 ))` only inside `if` (bare (( )) at 0 is FATAL).
#   * cleanup unconditional `|| true`; snapshot assertions BEFORE cleanup (already done —
#     rc/out captured before rm).
#   * register in _br_run_suite's hardcoded list or the case never runs.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth):
  - pool_config_init / POOL_EPHEMERAL_ROOT / POOL_ALLOW_SLOW_COPY: read by the inserted line
        exactly as the surrounding probe already does (no new globals).
  - bootrace harness (_bootrace_setup env + _fail + _br_run_suite + timeout contract):
        R7 plugs in; NO changes to setup/teardown/fixtures (doctor needs neither fake chrome
        nor fake agent-browser process activity — only their executables' existence, which
        the fixtures already provide).
  - P1.M2.T1.S2 (BUG-003 seam 2, LANDED): disjoint (release branch + R6 + README '### release').
        Your R7 appends after R6; suite count after your task = 9.

PROVIDED (downstream consumers of this fix):
  - install.sh step 3 (NO code change): its doctor subprocess now exits 0 on fresh btrfs
        installs → "doctor: found problems" stops firing on healthy machines.
  - P1.M3.T1.S1 / P1.M3.T2.S1 (final gate + README sync): R7 is part of the 9-case suite they
        run; the Mode-A doctor note rides HERE so the README sync reconciles rather than rewrites.
  - P1.M2.T3/T4 (BUG-005 help, BUG-006 validate.sh): independent; do not touch their targets
        (pool_admin_help, plan/004_de5e94ac127c/validate.sh).

CONFIG / DATABASE / ROUTES: none. No env vars, no state files, no schema. Side effect
(documented in README): doctor creates $POOL_EPHEMERAL_ROOT if absent.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh && echo SYNTAX-OK
shellcheck -s bash lib/pool.sh && shellcheck -s bash test/bootrace.sh && echo LINT-OK
# Expected: SYNTAX-OK, LINT-OK (zero warnings — the file is lint-clean at HEAD; the insert
# adds only a comment + a guarded mkdir; R7 follows the harness's established idioms).
```

### Level 2: The R7 case (component validation)

```bash
bash test/bootrace.sh 2>&1 | sed -n '/== r7_bug004_doctor_fresh_install/,+3p'
# Expected:
#   == r7_bug004_doctor_fresh_install
#      PASS
bash test/bootrace.sh 2>&1 | tail -1
# Expected: "9 passed, 0 failed"
```

### Level 3: End-to-end (the bug's own repro, now green)

```bash
# 3a. The PRD h3.3 repro — fresh tree, missing root, btrfs host:
T="$(mktemp -d -p "$HOME" -t abpool-bug004.XXXXXX)"; mkdir -p "$T/state" "$T/h"
HOME="$T/h" AGENT_BROWSER_POOL_STATE="$T/state" \
AGENT_CHROME_EPHEMERAL_ROOT="$T/active-missing" \
timeout 30 bash bin/agent-browser-pool doctor >"$T/out" 2>&1; rc=$?
sed -n '/\[filesystem\]/,+2p' "$T/out"
test -d "$T/active-missing" && echo "root created"
# Expected: the [filesystem] line shows "$T/active-missing OK (btrfs)"; "root created".
#       (rc may be nonzero ONLY for unrelated real findings in a bare tree — in this
#        minimal repro [master] may FAIL because no master exists; that is a TRUE finding.
#        The assertion that matters: [filesystem] is OK (btrfs).)

# 3b. Negative control still fails (a true non-btrfs path):
N="$(mktemp -d -p /dev/shm -t abpool-neg.XXXXXX)"
HOME="$T/h" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$N" \
AGENT_CHROME_ALLOW_SLOW_COPY=0 timeout 30 bash bin/agent-browser-pool doctor 2>&1 \
  | grep -F "FAIL (tmpfs; not btrfs)" && echo NEGATIVE-CONTROL-OK
rm -rf -- "$T" "$N"
# Expected: the FAIL (tmpfs; not btrfs) line + NEGATIVE-CONTROL-OK.

# 3c. install.sh path heals (NO change to install.sh):
#   (logic check only — a full install.sh run mutates ~/.local/bin; do NOT run it here.
#    install.sh:103-111 runs the same `bin/agent-browser-pool doctor` subprocess fixed in 3a.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Repeat-run exactness (the self-heal property): run doctor TWICE on a missing root —
#     the second run must also be OK (dir already exists; mkdir -p idempotent).
T="$(mktemp -d -p "$HOME" -t abpool-r7b.XXXXXX)"; mkdir -p "$T/state" "$T/h"
for i in 1 2; do
  HOME="$T/h" AGENT_BROWSER_POOL_STATE="$T/state" \
  AGENT_CHROME_EPHEMERAL_ROOT="$T/active-missing" \
  timeout 30 bash bin/agent-browser-pool doctor 2>&1 | grep -cF "OK (btrfs)"
done
rm -rf -- "$T"
# Expected: 1 then 1 (both runs OK).

# 4b. [dirs] output unchanged for an empty created root (regression guard):
T="$(mktemp -d -p "$HOME" -t abpool-r7c.XXXXXX)"; mkdir -p "$T/state" "$T/h"
HOME="$T/h" AGENT_BROWSER_POOL_STATE="$T/state" \
AGENT_CHROME_EPHEMERAL_ROOT="$T/active-empty" \
timeout 30 bash bin/agent-browser-pool doctor 2>&1 | sed -n '/\[dirs\]/,+1p'
rm -rf -- "$T"
# Expected: "[dirs]" then "  (no ephemeral dirs)" — identical to the absent-root output.

# 4c. Zero-orphan sweep (AGENTS.md checklist):
pgrep -af 'fake-cdp\.|user-data-dir=.*bootrace|abpool-r7|abpool-bug004|abpool-neg' || echo ZERO-ORPHANS
# Expected: ZERO-ORPHANS.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `bash -n` + `shellcheck` clean on lib/pool.sh AND test/bootrace.sh.
- [ ] Level 2: `bash test/bootrace.sh` → **9 passed, 0 failed** (R1-R6 + control intact).
- [ ] Level 3: PRD h3.3 repro green (`OK (btrfs)` on missing root; root created);
      negative control still `FAIL (tmpfs; not btrfs)`.
- [ ] Level 4: repeat-run exactness (4a), `[dirs]` unchanged (4b), zero orphans (4c).
- [ ] TDD discipline: R7 observed RED pre-fix (variant 1 = the BUG-004 symptom), GREEN post-fix.

### Feature Validation

- [ ] mkdir inserted immediately before the fstype capture, with the BUG-004 comment.
- [ ] OK/WARN/FAIL branches + printf formats byte-identical (git diff shows insert-only).
- [ ] install.sh, pool_copy_master, pool_check_btrfs-removal, [dirs] logic all untouched.
- [ ] `git diff --stat` shows exactly: lib/pool.sh, test/bootrace.sh, README.md.

### Code Quality Validation

- [ ] mkdir non-fatal (`2>/dev/null || true`) — doctor can never abort mid-report.
- [ ] `findmnt -T` retained; no bare findmnt introduced.
- [ ] R7 registered in the hardcoded case list (not just defined); follows R5/R6 style
      (locals up front, `|| rc=$?`, `_fail || rc_all=1`, unconditional cleanup, `return "$rc_all"`).
- [ ] R7 overrides `AGENT_CHROME_ALLOW_SLOW_COPY=0` for the FAIL variant (suite default is 1).
- [ ] Anti-patterns below avoided.

### Documentation & Deployment

- [ ] README `### \`doctor\``: exactly one sentence noting doctor creates the ephemeral root
      if absent (Mode-A; rides with this subtask).
- [ ] No env vars / config / docs beyond that sentence.

---

## Anti-Patterns to Avoid

- ❌ **Don't add `|| pool_die` to the mkdir** — that's pool_copy_master's acquire-critical
  idiom; doctor must complete all sections. Non-fatal + fall-through to FAIL is the design.
- ❌ **Don't alter the OK/WARN/FAIL printf formats** — R7 and downstream tooling grep them;
  the fix changes only WHY fstype is non-empty, not how results print.
- ❌ **Don't drop `-T` from findmnt** (or "simplify" the probe) — bare findmnt breaks on this
  host even on btrfs; also don't swap findmnt for `stat -f` (behavior verified only for findmnt).
- ❌ **Don't restore/recreate `pool_check_btrfs`** — it was deliberately REMOVED (dead code);
  doctor replicates the primitive by design.
- ❌ **Don't edit install.sh** — fix_design §3 explicitly chose the doctor-side minimal path;
  install heals transitively.
- ❌ **Don't define R7 without registering it** in `_br_run_suite`'s hardcoded list — an
  unlisted case silently never runs (vacuous green, the classic trap this harness documents).
- ❌ **Don't let R7 depend on the suite's exported `AGENT_CHROME_ALLOW_SLOW_COPY=1`** for the
  FAIL variant — override to `0` per-command or the negative control silently weakens to WARN.
- ❌ **Don't spawn an owner/fake-chrome in R7** — doctor ignores owner identity; keep the case
  cheap and orphan-free.
- ❌ **Don't trust the line numbers in the item text** — the file has drifted (5211 lines,
  capture at 4971); re-locate with the grep in Task 0/2.
- ❌ **Don't skip the RED step** — writing R7 after the fix makes it unfalsifiable theater;
  observe it fail with the BUG-004 symptom first.