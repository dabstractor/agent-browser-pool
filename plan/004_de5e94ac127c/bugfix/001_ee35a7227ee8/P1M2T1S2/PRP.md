# PRP — P1.M2.T1.S2: pool_admin_release numeric branch: treat a present-but-corrupt lease as releasable

> **Bugfix context**: This subtask implements **BUG-003 seam 2** (PRD h2.3/h3.2, ID
> BUG-003) from the merged bugfix PRD — the authoritative design is
> `plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md` **§4**
> (seam 2) + `system_context.md` §7. It is a **behavior + test + one-doc-line** fix
> (Mode A). The sibling subtask **P1.M2.T1.S1** (reap-side seam 1) is "Implementing" —
> treat its PRP as a contract; its lib/test/README deltas are **verified already landed
> in the working tree** (see §S1 contract below). S1 and S2 are MUTUALLY INDEPENDENT
> (fix_design §7) and touch DISJOINT code: S1 = `pool_reap_orphan_dirs`; S2 =
> `pool_admin_release` numeric branch. After S1+S2, corrupt state is reclaimable by BOTH
> verbs — the consistent story the item contract requires.

---

## Goal

**Feature Goal**: Make `agent-browser-pool release N` clear a **present-but-corrupt**
lease (`lanes/N.json` exists but fails `pool_lease_exists`' JSON-validity check) instead
of refusing with `Lane N has no active lease.` rc 1. Today that refusal — combined with
`pool_lane_is_stale`'s rc-2 skip, `pool_reap_orphan_dirs`' dir-only removal (pre-S1), and
`pool_find_free_lane`'s deliberate `[[ -f ]]` collision-safety check — means a corrupt
lease is uncleanable except by manual `rm`: `status` shows a permanent `? ? … STALE` row
and lane N is **permanently burned** (skipped by every future acquire). This is reachable
without sabotage: `_pool_atomic_write` deliberately does no fsync, so power loss (PRD
Goal 4) can leave a zero-length/partial lease. PRD h2.3/h3.2 and §2.10 expect
stale/corrupt state to be reclaimable.

Because the lease is corrupt, its `chrome_pid`/`chrome_pgid`/`ephemeral_dir` fields are
**untrustworthy by definition** — and `_pool_release_lane_internals` (the shared release
kernel) early-returns 0 on an unreadable lease, so it **cannot** be reused for this case.
The release verb therefore needs its own inline corrupt-teardown: an anchored
cmdline-sweep kill (the established house idiom), prefix-guarded dir removal, lease-file
removal, log + success message, rc 0.

This is the literal implementation of fix_design §4 seam 2: *"probe `[[ -f
"$POOL_LANES_DIR/$target.json" ]]` in addition to `pool_lease_exists`. If the file exists
but is INVALID → treat as releasable: run the teardown directly (rm lease with the same
prefix/numeric guards … + kill any `user-data-dir=$POOL_EPHEMERAL_ROOT/$target` cmdline
match — cannot trust lease ids) and report `Released lane N (corrupt lease).` rc 0."*

**Deliverable** (all in-place edits):
1. `lib/pool.sh` — `pool_admin_release` (NOW lines **4606-4709**; numeric branch
   **4655-4682**): in the numeric branch, BEFORE the existing `pool_lease_exists` check,
   probe `[[ -f "$POOL_LANES_DIR/$target.json" ]]`; if present-but-corrupt, run the
   inline corrupt-teardown (sweep-kill → prefix-guarded rm -rf → rm lease → log →
   `Released lane %s (corrupt lease cleared).` → rc 0). The existing clean-lease (b) and
   no-lease (d) branches stay **byte-identical in behavior**. Update the function's
   docstring block for the new branch.
2. `test/bootrace.sh` — ADD `r6_bug003_release_corrupt_lease` (after R5's closing `}`,
   before `_br_run_suite`) + **register it in `_br_run_suite`'s HARDCODED case list**
   (lines ~512-515 — there is NO compgen discovery; a missing entry = vacuous green).
   R6 covers both shapes: corrupt lease + dir present (with a LIVE process carrying the
   lane's `user-data-dir` marker in its cmdline → asserts the sweep actually killed) and
   corrupt lease + dir absent. Suite goes from **7 passed** → **8 passed, 0 failed**.
3. `README.md` — `### release [<N>|all]` (~line 249-265): one sentence — `release N`
   also clears a corrupt/unparseable lease (killing any Chrome still on the lane dir) —
   plus the example output line `Released lane 7 (corrupt lease cleared).` (Mode A; rides
   WITH this subtask, mirroring how S1's README sentence rode with S1).

**Success Definition**:
- Corrupt `7.json` + live marker process on the lane dir + `active/7/` present →
  `release 7` → **rc 0**, lease file gone, dir gone, **zero processes** matching the
  anchored `user-data-dir=…/7( |$)` pattern (the sweep verifiably killed).
- Corrupt `7.json` with NO dir → `release 7` → **rc 0**, lease gone (this shape is the
  one S1's reap can never reach — reap iterates `$POOL_EPHEMERAL_ROOT/*/`).
- Clean lease → existing behavior unchanged: `pool_release_lane` delegate + `Released lane N.` rc 0.
- No lease file at all → existing behavior unchanged: `Lane N has no active lease.` rc 1.
- `pool_find_free_lane` returns 7 after the teardown (lane number un-burned).
- `bash -n` + `shellcheck -S warning` clean on both files; `bash test/bootrace.sh`
  exits 0 with **8 passed, 0 failed**.

## User Persona

**Target User**: The pool operator (a developer running `agent-browser-pool` on their own
machine) whose pool state was corrupted — most plausibly by power loss/crash mid-lease-write
(no fsync by design), or a truncated file. They see a permanent `? ? … STALE` row for lane
N in `status`, `reap` doesn't clear it (rc-2 skip / dir-less), and `release N` tells them
`Lane N has no active lease.` while the lane number stays burned forever. Their only
recourse today is knowing to `rm ~/.local/state/agent-browser-pool/lanes/N.json` by hand.

**Use Case**: `agent-browser-pool status` shows `7 ? ? … STALE` after a crash. The operator
runs `agent-browser-pool release 7`. With S2: any Chrome still pointed at `active/7` is
swept (lease ids can't be trusted), the dir and the corrupt lease file are removed, the
operator sees `Released lane 7 (corrupt lease cleared).` and lane 7 becomes acquirable
again. With S1+S2 together the story is consistent: corrupt state is reclaimable by BOTH
`reap` (when the orphan dir exists) and `release N` (always).

**User Journey**: status shows the burned lane → `release N` → sweep-kill (if any stray
Chrome on the dir) → dir removed → corrupt lease file removed → success message, rc 0 →
next `status` shows no row → next acquire may hand out lane N again.

**Pain Points Addressed**:
- A lane number permanently burned by an uncleanable corrupt lease (BUG-003, PRD h2.3/h3.2).
- `status` permanently showing a `? ? … STALE` row for a lane nothing can reclaim.
- A possible LIVE Chrome stranded on the lane dir (crash between launch and lease
  finalization) that id-based release can never find — the sweep closes this leak.

## Why

- **BUG-003 (Minor, ID BUG-003)**. PRD h2.3/h3.2 + the Recommendations line: *"Make
  `reap`/`release` able to clear corrupt leases."* S1 covers the reap side; S2 is the
  release side — without S2, the corrupt-lease-without-dir shape remains uncleanable
  (reap only iterates existing dirs), and the two verbs tell inconsistent stories.
- **`release N` is the natural operator verb for "clear this specific lane"** — it takes
  the lane number as an argument, so the operator can name the burned lane directly.
  The current rc-1 refusal is the exact dead end the PRD documents in its repro.
- **The teardown must be inline, not delegated**: `_pool_release_lane_internals` step (1)
  (NOW ~2138-2141) is `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi`
  — rc 1 = missing OR corrupt → clean no-op. It can never tear down a corrupt lease, and
  its id-based `pool_chrome_kill` path can't run at all without parseable ids. The item
  contract and fix_design §4 both mandate the inline approach with the cmdline sweep.
- **Safety is preserved, not weakened**: `pool_lane_is_stale` rc-2 skip and
  `pool_find_free_lane`'s `[[ -f ]]` collision-safety check stay UNTOUCHED (deliberate;
  S1's PRP + system_context §7 both forbid weakening them). The reclaim is by EXPLICIT
  operator action (`release N`), which is the safe place for it.
- **The kill idiom and guards are established, host-verified house patterns** — copy them
  verbatim from `_pool_release_lane_internals` §3b/step-4 and `pool_reap_orphan_dirs`;
  the R6 live-marker technique was verified on this host this session (see Known Gotchas).

## What

Observable contract for `pool_admin_release` numeric branch (target is already
`^[0-9]+$`-validated by the elif classification — path-traversal defense; keep relying on it):

| State of `lanes/N.json` (+ dir / chrome) | Behavior | stdout | rc |
|---|---|---|---|
| Valid lease (JSON parses) | existing (b): `pool_release_lane "$N"` delegate | `Released lane N.` | 0 |
| **Present but CORRUPT** (file exists, `pool_lease_exists` rc 1) — **NEW** | inline teardown: anchored sweep-kill → prefix-guarded `rm -rf $EPH/N` → `rm -f lanes/N.json` → `_pool_log` | `Released lane N (corrupt lease cleared).` | 0 |
| Absent | existing (d): nothing torn down | `Lane N has no active lease.` | 1 |

The `all` branch, `usage` branch, and both existing numeric sub-branches are
**byte-identical in behavior**. (`release all` still no-ops on corrupt leases —
documented residual, out of scope; see Known Gotchas.)

### Success Criteria

- [ ] Numeric branch probes `[[ -f "$POOL_LANES_DIR/$target.json" ]]` BEFORE the
  `pool_lease_exists` check; present-but-corrupt takes the new teardown path.
- [ ] Teardown order: (a) anchored `user-data-dir=$dir( |$)` pgrep→pkill→`sleep 0.2`→`pkill -9`
  sweep (pgrep rc 1 guarded by `if`); (b) prefix-guarded `rm -rf -- "$POOL_EPHEMERAL_ROOT/$target"`
  (same 3-condition guard as `_pool_release_lane_internals` step 4); (c) `rm -f --
  "$POOL_LANES_DIR/$target.json"`; (d) `_pool_log` (tagged `pool_admin_release(corrupt):`,
  mentions BUG-003) + `printf 'Released lane %s (corrupt lease cleared).\n' "$target"` + `return 0`.
- [ ] $target reaches NO path without the `^[0-9]+$` elif classification (validated first).
- [ ] Clean-lease and no-lease branches byte-identical in behavior (only the new branch
  is inserted; existing lines untouched).
- [ ] `r6_bug003_release_corrupt_lease` in test/bootrace.sh, REGISTERED in `_br_run_suite`'s
  hardcoded list; asserts: variant-1 (corrupt + dir + LIVE marker process) rc 0 + lease
  gone + dir gone + **zero survivors** matching the anchored pattern; variant-2 (corrupt,
  no dir) rc 0 + lease gone; self-cleans; snapshot-before-cleanup discipline.
- [ ] README `### release` documents the corrupt-lease behavior + example line.
- [ ] `bash -n` + `shellcheck -S warning` clean on lib/pool.sh and test/bootrace.sh;
  `bash test/bootrace.sh` → **8 passed, 0 failed**.
- [ ] S1's landed code (`pool_reap_orphan_dirs` seam, R5, README reap sentence) UNTOUCHED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. The PRP quotes the exact current numeric branch
(verbatim, line-cited), gives the paste-ready replacement with the corrupt-teardown
inlined (idioms copied verbatim from their house sources, each cited), specifies the R6
case in full paste-ready form — including the non-obvious **live-marker technique**
(`exec -a`, host-verified, because the fake-chrome fixture's final `exec python3` drops
the `user-data-dir` marker from cmdline and would make the kill assertion vacuous) — the
exact `_br_run_suite` registration site, the exact README sentence + example placement,
the S1 landed-state contract, and the validation commands.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  why: §4 = the AUTHORITATIVE design for BUG-003 (both seams; S2 = seam 2, quoted in the
        Goal). §5 = the fsync decision (NO code change — reclaim paths instead; S1 already
        recorded it). §7 = ordering: P1.M2.T1.S1/S2 mutually independent.
  pattern: seam 2's exact probe + teardown + message wording.
  gotcha: "implementers MUST not trust stale line numbers blindly" — fix_design cites
        HEAD-at-breakdown numbers; the file is NOW 5146 LOC and pool_admin_release is at
        4606-4709 (numeric branch 4655-4682). The PRP's line numbers are re-verified.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: §7 = BUG-003 confirmation with every code location + the mandate that
        pool_lane_is_stale rc-2 and pool_find_free_lane [[ -f ]] stay UNTOUCHED
        ("Do not change this — make the corrupt state reclaimable instead"). §11 = house
        style (set -e guards, never kill -0, never bare pgrep/pkill/rm, SC2155, timeout).
  pattern: §11 is the checklist the new code must satisfy.
  gotcha: "pool_die (exit 1) is NOT catchable with || true — wrap in a subshell to
        contain" — relevant if a test ever triggers one (R6 does not).

- file: lib/pool.sh
  why: THE file being edited (NOW 5146 LOC). Read: pool_admin_release 4606-4709 (docstring
        ~4606-4644 + body; numeric branch 4655-4682), _pool_release_lane_internals
        2121-2181 (step (1) early-return ~2138-2141 — WHY the kernel can't be reused; §3b
        sweep ~2153-2163 — the kill idiom; step-4 guards ~2166-2173 — the rm idiom),
        pool_reap_orphan_dirs 3388-3436 (S1's landed seam + the same sweep), pool_lease_exists
        1005-1019, pool_lanes_list ~976-988, pool_chrome_kill 2065-2085.
  pattern: house kill/rm idioms, docstring-with-GOTCHAs style, `if pool_lease_exists` probe.
  gotcha: line drift vs fix_design (4394-4420 → now 4655-4682). Re-locate with
        `grep -nE '^pool_admin_release\(\)' lib/pool.sh` before editing.

- file: test/bootrace.sh
  why: ADD r6 after R5 (line ~508, R5's closing `}`) and BEFORE `_br_run_suite` (510).
        CRITICAL: register in the HARDCODED case list (512-515) — bootrace has NO compgen
        discovery; a missing entry = the case never runs = vacuous green. R5 (473-508) is
        the seeding style to mirror; r3_neg (349-400) is the snapshot→cleanup→assert
        discipline; header (1-176) documents fixtures (_br_spawn_owner, fake chrome/ab).
  pattern: plain fn + named `_fail "R6: ..."` + `|| rc_all=1` accumulation + self-cleanup.
  gotcha: the fake chrome fixture ends with `exec python3 -m http.server` — exec REPLACES
        cmdline, dropping `user-data-dir=`. For R6's kill assertion use the exec -a marker
        technique (Known Gotchas) instead of booting the fixture.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M2T1S1/PRP.md   # S1 — the CONTRACT
  why: S1 (parallel, "Implementing") = seam 1. VERIFIED LANDED in-tree: the BUG-003 block
        in pool_reap_orphan_dirs, R5 + its case-list entry, the README reap sentence. S2
        must NOT duplicate or conflict: S1 touched pool_reap_orphan_dirs + R5 + README
        '### reap'; S2 touches pool_admin_release + R6 + README '### release'. Disjoint.
  pattern: S1's boundary table — "corrupt lease 7.json, NO dir 7 → reap leaves it →
        S2's `release 7` seam handles this shape." R6 variant-2 tests exactly this shape.
  gotcha: S1's R5 asserted reap-side behavior; do NOT re-test reap in R6 (release only).

- file: README.md
  why: '### release [<N>|all]' (~249-265): intro sentence at 249-250, example output block
        ~252-263 incl. `Lane 99 has no active lease.      # exit code 1`. Extend the intro
        with the corrupt-lease sentence + add the new example line (Mode A).
  pattern: S1's reap sentence (236-237) is the exact precedent for one-sentence Mode-A doc.
  gotcha: keep the `# exit code 1` comment on the Lane-99 example — that path is unchanged.

# External authoritative docs
- url: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
  why: 'exec -a NAME — "the shell passes NAME as the zeroth argument to the executed
        command." R6''s marker technique relies on it: argv[0] carries the
        user-data-dir=... string, sleep never re-execs, so /proc/<pid>/cmdline keeps the
        marker for the anchored pgrep -f match. HOST-VERIFIED this session (visible →
        TERM-killed → zero survivors → no prefix-collision with lane 70).'
  critical: 'do NOT use the fake-chrome fixture for the kill assertion — its final
        `exec python3` replaces cmdline and drops the marker (vacuous pass).'
  section: 'exec [-cl] [-a name] [command [arguments]]'.

- url: https://www.kernel.org/doc/html/latest/filesystems/proc.html
  why: /proc/<pid>/cmdline is NUL-separated argv including argv[0]; pgrep -f matches a
        regex SUBSTRING of it. Grounds the anchored `user-data-dir=$dir( |$)` pattern
        (space-or-EOL after the dir → prefix-colliding lanes never match).
  section: 'Process-specific subdirectories' → cmdline table.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: 'declare and assign separately — `local pat; pat="user-data-dir=$dir( |\\$)"` is a
        PARAMETER EXPANSION assignment (SC2155-safe inline, established house style at §3b
        + reap loop); `local x="$(…)"` is NOT. No $(…) captures are added by this fix.'
  section: the SC2155 rule.

- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: set -e exemptions — the condition of `if`/`&&`/`||` lists is exempt; `pgrep -f`
        rc 1 (no match) inside `if` is a clean branch; `a && b` with failing `a` does not
        abort. All new guards rely on this.
  section: errexit (-e).
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                    # 5146 LOC
│       # pool_admin_release        4606-4709  ← S2 EDIT (numeric branch 4655-4682 + docstring)
│       # _pool_release_lane_internals 2121-2181 (READ ONLY — early-return + idiom source)
│       # pool_reap_orphan_dirs     3388-3436 (S1 LANDED — DO NOT TOUCH; idiom source)
│       # pool_lease_exists         1005-1019, pool_lanes_list ~976-988, pool_chrome_kill 2065-2085
│       # pool_lane_is_stale rc-2 + pool_find_free_lane [[ -f ]] — UNTOUCHED (deliberate)
├── test/
│   └── bootrace.sh                # 550 lines; R5 at 473-508; _br_run_suite list 512-515
│                                  # ← S2 ADDS r6 (after R5, before _br_run_suite) + list entry
├── README.md                      # '### release [<N>|all]' ~249-265 ← S2 extends (Mode A)
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/{fix_design,system_context,test_framework}.md   # fix_design §4 = THE design
    ├── P1M2T1S1/{PRP.md, research/reap-orphan-corrupt-lease.md}     # S1 (LANDED; contract)
    └── P1M2T1S2/                  # THIS subtask
        ├── PRP.md                  # THIS FILE
        └── research/release-corrupt-lease.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits IN-PLACE in 3 existing files:
#   lib/pool.sh       — pool_admin_release numeric branch: corrupt-teardown branch + docstring note
#   test/bootrace.sh  — r6_bug003_release_corrupt_lease case + _br_run_suite list entry (7→8 cases)
#   README.md         — one sentence + one example line in '### release'
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (why the teardown must be INLINE): _pool_release_lane_internals step (1)
# (~2138-2141) is `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi` —
# pool_lease_read rc 1 = missing OR corrupt → clean no-op return. The shared kernel can
# NEVER tear down a corrupt lease, and its id-based pool_chrome_kill path is unreachable
# without parseable ids. Do NOT try to "fix" the kernel (it is the reap/acquire hot path,
# deliberately non-fatal); add the release-side branch per the item contract.

# CRITICAL (R6 kill-assertion technique — NOT the fake-chrome fixture): the fake chrome
# fixture ends with `exec python3 -m http.server` — exec REPLACES /proc/<pid>/cmdline, so
# after boot the process NO LONGER contains `user-data-dir=` and the anchored pgrep cannot
# match it. Asserting "no survivors" against the exec'd fixture would pass VACUOUSLY
# (marker gone regardless of the sweep). Instead spawn a live marker process:
#     bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$EPH/7 lane7" &
# exec -a sets argv[0]; sleep never re-execs → the marker STAYS in cmdline forever.
# HOST-VERIFIED this session: the anchored pattern matches it; TERM kills it; lane-70-style
# prefix collisions do NOT match. Record the pid, and in cleanup `kill` + `wait` it.

# CRITICAL (the anchored sweep pattern — copy verbatim, do not "simplify"): 
#     local pat="user-data-dir=$dir( |\$)"
#     if pgrep -f -- "$pat" >/dev/null 2>&1; then
#         pkill    -f -- "$pat" 2>/dev/null || true
#         sleep 0.2                        # let renderer/GPU/utility children exit
#         pkill -9 -f -- "$pat" 2>/dev/null || true
#     fi
# pgrep/pkill -f match a regex SUBSTRING of /proc/<pid>/cmdline; an UNanchored
# `user-data-dir=$dir` would also match $dir followed by more digits (lane 3's pattern is
# a substring of lane 30/31/300…). `( |$)` anchors at the lane-dir boundary (Chrome's
# cmdline has the dir followed by a space or EOL). pgrep rc 1 (no match) MUST sit inside
# the `if` condition (errexit-exempt); pkill always `|| true`. In the double-quoted
# pattern, `\$` is the literal-$ escape; `$dir` still expands.

# CRITICAL (rm -rf prefix guard — copy the 3-condition guard verbatim):
#     dir="$POOL_EPHEMERAL_ROOT/$target"
#     if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
#         rm -rf -- "$dir" 2>/dev/null || true
#     fi
# NEVER rm a bare path built from lease fields (corrupt lease = untrustworthy fields);
# $target is ^[0-9]+$-validated at the elif, and the guard is defense-in-depth.

# CRITICAL (branch ORDER in the numeric branch): probe [[ -f ]] + pool_lease_exists FIRST
# as the corrupt check, BEFORE the existing `if pool_lease_exists "$target"` — so the
# clean path and the no-lease path keep their exact current lines/behavior. Shape:
#     if [[ -f "$POOL_LANES_DIR/$target.json" ]] && ! pool_lease_exists "$target"; then
#         <corrupt teardown ...>; return 0
#     fi
#     if pool_lease_exists "$target"; then <existing (b), untouched>; else <existing (d), untouched>; fi
# Both corrupt-probe conditions sit in the `if` condition → errexit-exempt (pool_lease_exists
# rc 1 is a signal, not an error). The [[ -f ]] short-circuits the common absent-file case.

# CRITICAL (R6 registration): _br_run_suite has a HARDCODED case list (~512-515) — NO
# compgen discovery. Forgetting the list entry = the case never runs = vacuous green.
# Append r6_bug003_release_corrupt_lease to the r5 continuation line.

# GOTCHA (set -e in test bodies): `_fail` RETURNS 1 — never a bare statement; use
# `_fail "R6: ..." || rc_all=1` (r3_neg pattern). `(( rc == 0 ))` must sit inside if/||.
# Snapshot ALL observable state (survivors via pgrep -af, dir presence, rc) BEFORE the
# cleanup block; cleanup runs unconditionally (`|| true` per line).

# GOTCHA (documented residual — do NOT fix here): `release all` iterates pool_lanes_list
# (glob *.json, NO JSON validation) → pool_release_lane → _pool_release_lane_internals
# no-ops on corrupt → a corrupt file SURVIVES `release all` (and is counted in
# "Released N lane(s)."). The item scopes ONLY the numeric branch; operators use
# `release N` or `reap` for corrupt leases. README documents `release N` (not `all`).

# GOTCHA (untouched by design): pool_lane_is_stale rc-2 skip and pool_find_free_lane's
# [[ -f ]] check stay EXACTLY as-is (collision safety — system_context §7: "Do not change
# this — make the corrupt state reclaimable instead"). S1's seam + S2's branch are the
# designated reclaimers.

# GOTCHA (line drift): fix_design cites HEAD-at-breakdown numbers (4394-4420); the file is
# NOW 5146 LOC (major-fix subtasks landed code). Re-locate everything with grep before
# editing; the PRP's numbers (pool_admin_release 4606-4709, branch 4655-4682) are current.

# GOTCHA (scope): S2 = the numeric-branch teardown + R6 + one README sentence. Do NOT:
# touch pool_reap_orphan_dirs or R5 (S1, LANDED); weaken pool_find_free_lane/
# pool_lane_is_stale; change _pool_release_lane_internals; add fsync; touch `release all`;
# touch doctor/help/validate.sh (P1.M2.T2/T3/T4); do a Mode-B doc sweep (P1.M3).
```

## Implementation Blueprint

### Data models and structure

No schema change. The lease JSON shape is untouched; corrupt = "file present +
`pool_lease_exists` rc 1" (its exact definition: `[[ -f ]]` + `_pool_json_valid`). The only
"structure" is the numeric-branch state machine, which gains one state:

| State | Old outcome | New outcome |
|---|---|---|
| Valid lease | `pool_release_lane` delegate, `Released lane N.`, rc 0 | (unchanged) |
| **Present-but-corrupt** | `Lane N has no active lease.`, rc 1 (burned lane) | **inline teardown, `Released lane N (corrupt lease cleared).`, rc 0** |
| Absent | `Lane N has no active lease.`, rc 1 | (unchanged) |

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current state and confirm the edit sites (line numbers drift — re-locate)
  - RUN: grep -nE '^pool_admin_release\(\)|^_pool_release_lane_internals\(\)|^pool_reap_orphan_dirs\(\)' lib/pool.sh
  - EXPECT: pool_admin_release 4606, _pool_release_lane_internals 2121, pool_reap_orphan_dirs 3388.
  - RUN: sed -n '4655,4682p' lib/pool.sh
  - EXPECT: the numeric branch exactly as quoted in §"the exact current numeric branch"
        (below) — elif classification, `if pool_lease_exists "$target"` → delegate +
        `Released lane %s.` → else `Lane %s has no active lease.` + return 1.
  - RUN (S1 contract landed — DO NOT re-implement):
        grep -n 'BUG-003' lib/pool.sh test/bootrace.sh README.md
  - EXPECT: the S1 block in pool_reap_orphan_dirs, R5 + its _br_run_suite entry, the reap
        sentence in README. If ANY is missing, S1 has not landed — do NOT implement it
        yourself; flag it (the seams are independent, so you may still proceed with S2's
        edits, but note the dependency in your report).
  - RUN: bash -n lib/pool.sh && bash -n test/bootrace.sh && echo OK
  - EXPECT: OK (clean baseline).

Task 1: EDIT lib/pool.sh — insert the corrupt-teardown branch in pool_admin_release
  - LOCATE the numeric branch (Task 0). The exact current numeric branch:
        elif [[ "$target" =~ ^[0-9]+$ ]]; then
            # --- (b)/(d) numeric: PROBE existence BEFORE delegating (the key guard) ---
            # ... (existing comment block) ...
            if pool_lease_exists "$target"; then
                # (b) lease EXISTS → delegate the real teardown. ...
                pool_release_lane "$target" >/dev/null
                # %s echoes the target token verbatim ("Released lane 7.").
                printf 'Released lane %s.\n' "$target"
                return 0
            else
                # (d) lease ABSENT → nothing to release. ...
                printf 'Lane %s has no active lease.\n' "$target"
                return 1
            fi
  - INSERT (between the elif's existing comment block and the `if pool_lease_exists`
        line — the existing (b)/(d) code stays byte-identical below it):
        # --- BUG-003 (fix_design §4 seam 2): CORRUPT-lease branch — BEFORE the clean/absent
        #     probe. pool_lease_exists rc 1 means missing OR corrupt; the [[ -f ]] pre-probe
        #     distinguishes them: file present + invalid JSON = a corrupt lease the shared
        #     kernel can NEVER clean (_pool_release_lane_internals step (1) early-returns 0
        #     on unreadable JSON, and its id-based kill is unreachable without parseable ids).
        #     Left alone it burns the lane number forever (pool_find_free_lane's deliberate
        #     [[ -f ]] collision check treats it as occupied; pool_lane_is_stale rc 2 skips
        #     it) and status shows a permanent '? ?' STALE row. Reachable via power loss
        #     (_pool_atomic_write does no fsync by design — fix_design §5). Treat it as
        #     releasable: tear down DIRECTLY. Lease ids are untrustworthy by definition →
        #     cmdline-sweep kill (the anchored house idiom), NOT pool_chrome_kill.
        if [[ -f "$POOL_LANES_DIR/$target.json" ]] && ! pool_lease_exists "$target"; then
            # (a) Kill any process still on this lane's dir — the anchored pattern from
            #     _pool_release_lane_internals (3b) / pool_reap_orphan_dirs: `( |$)` anchors
            #     at the lane-dir boundary so prefix-colliding lanes (3 vs 30/300) never
            #     match; pgrep rc 1 (no match) is the if-condition (errexit-exempt); pkill
            #     best-effort; sleep lets renderer/GPU children exit before the force kill.
            dir="$POOL_EPHEMERAL_ROOT/$target"
            local pat="user-data-dir=$dir( |\$)"
            if pgrep -f -- "$pat" >/dev/null 2>&1; then
                _pool_log "pool_admin_release(corrupt): lane $target cmdline sweep (lease ids untrusted)"
                pkill    -f -- "$pat" 2>/dev/null || true
                sleep 0.2
                pkill -9 -f -- "$pat" 2>/dev/null || true
            fi
            # (b) Prefix-guarded rm of the lane dir — RECONSTRUCTED from lane + root (never
            #     trust the corrupt lease's ephemeral_dir); same 3-condition guard as
            #     _pool_release_lane_internals step (4). `|| true` (TOCTOU-safe).
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            # (c) Remove the corrupt lease file — THE reclaim (frees the lane number).
            rm -f -- "$POOL_LANES_DIR/$target.json" 2>/dev/null || true
            _pool_log "pool_admin_release(corrupt): cleared corrupt lease + lane $target (BUG-003)"
            printf 'Released lane %s (corrupt lease cleared).\n' "$target"
            return 0
        fi

  - ALSO: add `local dir` — the function declares ALL locals up front; add `dir` to the
        existing locals block (`local target="${1:-}"` / `local -a lanes` / `local lane`)
        as a plain `local dir` line. (`local pat="…"` mid-function stays INSIDE the branch
        — established house style at §3b + the reap loop; it is a parameter expansion, not
        a $(…) capture, so SC2155-safe.)
  - WHY this order: file-present+invalid is checked first so the two existing sub-branches
        below keep their exact current lines (byte-identical behavior); a corrupt lease can
        never reach them.
  - GOTCHA: both corrupt-probe conditions sit inside the `if` condition → errexit-exempt.
        The `&&` short-circuits: absent file → the pool_lease_exists call is skipped
        entirely (zero extra forks on the common absent path).

Task 2: EDIT lib/pool.sh — update pool_admin_release's docstring (the big comment block above it)
  - FIND the docstring lines that describe the numeric branch (search for the
        'RETURN CODES' / '(b)' / '(d)' notes in the block at ~4606-4644).
  - UPDATE (additive, next to the (b)/(d) documentation):
        #   - NEW (BUG-003, fix_design §4 seam 2): a PRESENT-BUT-CORRUPT lanes/N.json (file
        #     exists, pool_lease_exists rc 1) is treated as RELEASABLE: inline teardown
        #     (anchored user-data-dir cmdline sweep — lease ids untrustworthy; prefix-guarded
        #     rm of $POOL_EPHEMERAL_ROOT/N; rm of the lease file) → 'Released lane N (corrupt
        #     lease cleared).' rc 0. The shared kernel (_pool_release_lane_internals) cannot
        #     do this — it early-returns 0 on unreadable JSON. `release all` still no-ops on
        #     corrupt leases (pool_lanes_list does not validate JSON; NOT in scope) — use
        #     `release N` (or reap, once its dir is gone) for corrupt leases.
  - ALSO update the docstring's set -e GUARDS note: `pool_lease_exists` now appears in a
        SECOND if-condition (the corrupt probe) — both are the same errexit-exempt idiom;
        note `pgrep -f` rc 1 is likewise if-guarded.
  - GOTCHA: comment-only; no behavior change in this task. Keep every other docstring
        line (usage/rc contract, D7 stdout-discipline notes) intact.

Task 3: ADD test/bootrace.sh — r6_bug003_release_corrupt_lease
  - PLACE: after R5's closing `}` (line ~508), before the
        `# --- single-setup runner ---` / `_br_run_suite` block.
  - REFERENCE IMPLEMENTATION (paste-ready; style mirrors R5 seeding + r3_neg discipline;
        NO boot needed — the corrupt lease is seeded directly):
      ----------------------------------------------------------------
      # R6 — BUG-003 (fix_design §4 seam 2): `release N` must clear a PRESENT-BUT-CORRUPT
      # lease. Two variants: (1) corrupt 7.json + dir 7 present + a LIVE process whose
      # cmdline carries the lane's user-data-dir marker (exec -a sleep — the fake-chrome
      # fixture execs python3, which REPLACES cmdline and would make the kill assertion
      # vacuous) → rc 0, lease gone, dir gone, ZERO survivors on the anchored pattern
      # (the sweep verifiably killed); (2) corrupt 7.json, NO dir (the shape reap can
      # never reach — pool_reap_orphan_dirs iterates $EPH/*/) → rc 0, lease gone.
      r6_bug003_release_corrupt_lease() {
          local rc lease7 dir7 pat survivors rc_all
          _br_spawn_owner                 # a live owner so the pool verbs run normally
          lease7="$AGENT_BROWSER_POOL_STATE/lanes/7.json"
          dir7="$AGENT_CHROME_EPHEMERAL_ROOT/7"
          pat="user-data-dir=$dir7( |\$)"

          # --- variant 1: corrupt lease + dir + LIVE marker process ---
          mkdir -p -- "$AGENT_BROWSER_POOL_STATE/lanes" "$dir7"
          printf 'not json {{{' >"$lease7"
          printf 'orphan-marker\n' >"$dir7/Preferences"
          bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$dir7 lane7" >/dev/null 2>&1 &
          local mp=$!
          sleep 0.3                       # let the marker process settle into /proc
          rc=0
          timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release 7 >/dev/null 2>&1 || rc=$?
          sleep 0.3                       # let the sweep's TERM/0.2s/KILL land
          # --- snapshot observable state BEFORE cleanup ---
          survivors="$(pgrep -f -- "$pat" 2>/dev/null || true)"
          # --- cleanup FIRST (always runs) ---
          kill "$mp" 2>/dev/null || true
          wait "$mp" 2>/dev/null || true
          rm -f -- "$lease7" 2>/dev/null || true
          rm -rf -- "$dir7" 2>/dev/null || true
          # --- assertions on snapshots ---
          rc_all=0
          if (( rc != 0 )); then
              _fail "R6: release 7 on corrupt lease rc=$rc (expected 0)" || rc_all=1
          fi
          if [[ -e "$lease7" ]]; then
              _fail "R6: corrupt lease 7.json survived release (BUG-003 reproduced)" || rc_all=1
          fi
          if [[ -e "$dir7" ]]; then
              _fail "R6: lane dir 7 survived release" || rc_all=1
          fi
          if [[ -n "$survivors" ]]; then
              _fail "R6: live process on lane 7 dir survived the sweep: $survivors" || rc_all=1
          fi

          # --- variant 2: corrupt lease, NO dir (reap can never reach this shape) ---
          printf 'not json {{{' >"$lease7"
          rc=0
          timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release 7 >/dev/null 2>&1 || rc=$?
          if (( rc != 0 )); then
              _fail "R6: release 7 on corrupt lease (no dir) rc=$rc (expected 0)" || rc_all=1
          fi
          if [[ -e "$lease7" ]]; then
              _fail "R6: corrupt lease (no dir) survived release" || rc_all=1
          fi
          # Self-cleanup (belt-and-suspenders; happy path already cleared everything).
          rm -f -- "$lease7" 2>/dev/null || true
          rm -rf -- "$dir7" 2>/dev/null || true
          return "$rc_all"
      }
      ----------------------------------------------------------------
  - REGISTER (MANDATORY — no compgen discovery): in `_br_run_suite`'s hardcoded list,
        append to the r5 continuation line:
              r5_bug003_corrupt_lease_reclaimed r6_bug003_release_corrupt_lease; do
        (i.e. insert ` r6_bug003_release_corrupt_lease` after `r5_bug003_corrupt_lease_reclaimed`).
  - WHY exec -a sleep for the marker (and NOT the fake-chrome fixture): the fixture's final
        `exec python3 -m http.server` replaces /proc/cmdline — the `user-data-dir=` marker
        DISAPPEARS, so `pgrep -f "$pat"` finds nothing whether or not the sweep ran
        (vacuous pass). exec -a pins the marker in argv[0]; sleep never re-execs.
        HOST-VERIFIED: visible to the anchored pattern; TERM kills it; lane-70 collisions
        don't match. `wait` after `kill` reaps the zombie (AGENTS.md §3).
  - WHY variant 2 exists: S1's seam requires the dir to exist (reap iterates
        $POOL_EPHEMERAL_ROOT/*/) — the dir-less corrupt lease is release's job ONLY.
        This asserts the complete consistent story.
  - GOTCHA: `_fail` returns 1 → always `|| rc_all=1`; `(( rc != 0 ))` inside `if` only.
  - GOTCHA: $pat is a parameter expansion (safe inline local). The anchored `( |\$)` must
        survive verbatim — double-quoted, `\$` is the literal-$ escape.

Task 4: EDIT README.md — '### release [<N>|all]' (~line 249-265)
  - FIND the intro: 'Explicitly tear down one lane by number, or every lane. With no/invalid
        argument it prints a usage block to stderr and exits 1.'
  - EXTEND (append to that paragraph):
        A corrupt or unparseable `lanes/<N>.json` is also cleared (killing any Chrome still
        on that lane's profile dir — the lease contents can't be trusted), freeing the lane
        number. (`release all` does not clear corrupt leases; use `release N` or `reap`.)
  - FIND the example block's `Released lane 1.` line; ADD after it:
        Released lane 7 (corrupt lease cleared).
  - GOTCHA: do NOT touch the `Lane 99 has no active lease.      # exit code 1` example
        (that behavior is unchanged) or the `### reap` section (S1's).

Task 5: VERIFY — the full gauntlet BEFORE claiming done
  - RUN: bash -n lib/pool.sh && bash -n test/bootrace.sh && echo OK     # EXPECT: OK
  - RUN: shellcheck -S warning lib/pool.sh; shellcheck -S warning test/bootrace.sh
        # EXPECT: zero output from both (project gate).
  - RUN (the fix, isolated, hermetic — mirrors R6 but standalone):
        T="$(mktemp -d -p "$HOME" -t abpool-r6man.XXXXXX)"
        mkdir -p -- "$T/state/lanes" "$T/active/7"
        printf 'not json {{{' >"$T/state/lanes/7.json"
        bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$T/active/7 m" >/dev/null 2>&1 &
        MP=$!; sleep 0.3
        rc=0
        HOME="$T/home" mkdir -p -- "$T/home"   # ensure HOME exists for config defaults
        env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" \
            AGENT_CHROME_EPHEMERAL_ROOT="$T/active" AGENT_CHROME_MASTER="$T/m" \
            AGENT_CHROME_ALLOW_SLOW_COPY=1 \
            timeout 30 bash "$PWD/bin/agent-browser-pool" release 7; rc=$?
        echo "rc=$rc (expect 0)"; ls "$T/state/lanes/" 2>/dev/null; [[ -d "$T/active/7" ]] || echo "dir gone (expect)"
        pgrep -f -- "user-data-dir=$T/active/7( |\$)" >/dev/null 2>&1 && echo "FAIL: survivor" || echo "no survivors (expect)"
        kill "$MP" 2>/dev/null || true; wait "$MP" 2>/dev/null || true; rm -rf -- "$T"
        # EXPECT: rc=0, lanes/ empty, dir gone, no survivors. (bin/agent-browser-pool runs
        #       pool_config_init itself; the env redirects keep it hermetic.)
  - RUN (regression: clean + absent branches unchanged):
        T="$(mktemp -d -p "$HOME" -t abpool-r6reg.XXXXXX)"
        env HOME="$T" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
            timeout 30 bash "$PWD/bin/agent-browser-pool" release 99; echo "absent rc=$? (expect 1)"
        rm -rf -- "$T"
        # EXPECT: 'Lane 99 has no active lease.' + absent rc=1 (expect 1).
  - RUN (the suite — THE gate):
        timeout 600 bash test/bootrace.sh
        # EXPECT: exit 0, summary '8 passed, 0 failed' (r1..r5 + r6; R5 still green — S1
        #       untouched).
  - RUN (scope check — S1's seam + S1's test untouched):
        git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'pool_reap_orphan_dirs|pool_reap\(orphan\)' \
          && echo "FAIL: out-of-scope edit to reap (S1)" || echo "scope OK (reap untouched)"
        git diff -- test/bootrace.sh | grep -E '^[+-]' | grep -E 'r5_bug003' \
          && echo "FAIL: R5 modified (S1)" || echo "scope OK (R5 untouched)"
        # EXPECT: scope OK (both). The only diffs: pool_admin_release branch + docstring,
        #       R6 + its list entry, README release section.
  - FIX any failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the corrupt-teardown branch (verbatim-ready; idioms from house sources) --
# Precondition: $target passed the elif ^[0-9]+$ classification (path-safe).
if [[ -f "$POOL_LANES_DIR/$target.json" ]] && ! pool_lease_exists "$target"; then
    dir="$POOL_EPHEMERAL_ROOT/$target"                       # local dir; declared up front
    local pat="user-data-dir=$dir( |\$)"                     # ANCHORED at the dir boundary
    if pgrep -f -- "$pat" >/dev/null 2>&1; then              # rc 1 = if-condition (exempt)
        _pool_log "pool_admin_release(corrupt): lane $target cmdline sweep (lease ids untrusted)"
        pkill    -f -- "$pat" 2>/dev/null || true            # TERM the whole cmdline set
        sleep 0.2                                            # renderer/GPU grace (verbatim)
        pkill -9 -f -- "$pat" 2>/dev/null || true            # force stragglers
    fi
    if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
        rm -rf -- "$dir" 2>/dev/null || true                 # 3-condition prefix guard (verbatim)
    fi
    rm -f -- "$POOL_LANES_DIR/$target.json" 2>/dev/null || true   # THE reclaim
    _pool_log "pool_admin_release(corrupt): cleared corrupt lease + lane $target (BUG-003)"
    printf 'Released lane %s (corrupt lease cleared).\n' "$target"  # item's EXACT wording
    return 0
fi
# (the existing `if pool_lease_exists "$target"; then …; else …; fi` follows UNCHANGED)

# --- Pattern: R6's live marker (NOT the fake-chrome fixture) --------------------------
# bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$dir7 lane7" &
# exec -a pins the marker in argv[0]; sleep never re-execs → /proc/<pid>/cmdline keeps
# `user-data-dir=…/7` for the anchored pgrep -f match. Cleanup: kill + WAIT (reap zombie).

# --- Critical micro-rules --------------------------------------------------------------
#  * pool_lease_exists / pgrep -f rc 1 ALWAYS inside if-conditions (errexit-exempt).
#  * pkill / rm always `2>/dev/null || true` (best-effort, TOCTOU-safe).
#  * `local pat="…"`/`local mp=$!` are parameter expansions (SC2155-safe); NO `local x="$(…)"`.
#  * NEVER kill -0 (ESRCH/EPERM ambiguity) — pgrep//proc only (house rule).
#  * `sleep 0.2` between TERM and -9 stays (renderer/GPU children grace).
#  * _fail in tests returns 1 → `|| rc_all=1`; snapshot BEFORE cleanup; cleanup unconditional.
#  * THE case-list registration in _br_run_suite is part of the deliverable (no discovery).
```

### Integration Points

```yaml
PRIOR — consumed, NOT modified by S2:
  - pool_lease_exists (1005-1019): rc 0 valid / rc 1 missing-or-corrupt. Used twice (the
        corrupt probe + the existing clean probe). Always if-guarded.
  - pool_release_lane (3186+): the CLEAN-lease delegate — unchanged, still rc-0-always.
  - _pool_release_lane_internals (2121-2181): the shared kernel — READ ONLY here (idiom
        source); its corrupt-lease early-return is WHY the inline teardown exists.
  - pool_reap_orphan_dirs (3388-3436): S1's seam — LANDED, DO NOT TOUCH.
  - POOL_LANES_DIR / POOL_EPHEMERAL_ROOT (frozen by pool_config_init, which the function
        already calls at step a) + _pool_log.

S2 EDITS:
  - pool_admin_release numeric branch: +1 branch (corrupt teardown) + docstring note
    + `local dir`. Existing branches byte-identical.
  - test/bootrace.sh: r6 case + hardcoded list entry (7 → 8 cases).
  - README.md: one sentence + one example line in '### release'.

LATER — provided:
  - P1.M3.T1.S1 (final changeset gate): bootrace must report 8/8 incl. R6.
  - P1.M3.T2.S1 (README Mode-B sync) + P1.M3.T2.S2 (skill docs): S2's sentence is the
        release-side counterpart of S1's reap sentence; the changeset doc sync reconciles
        both. NOTE for that subtask: skill references may also warrant the same sentence.
  - Consumed by: the operator workflow (status → release N → lane freed); consistent with
        S1's reap path (corrupt state reclaimable by BOTH verbs).

CONFIG / DATABASE / ROUTES: none. No env vars, no schema, no new files. The reclaim is
purely file/process teardown within the already-initialized POOL_* roots.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh && bash -n test/bootrace.sh && echo OK
shellcheck -S warning lib/pool.sh       # project gate; EXPECT zero output
shellcheck -S warning test/bootrace.sh  # EXPECT zero output
# Expected: OK + zero output from both shellchecks.
```

### Level 2: Unit / Case Validation (the new R6 + the suite)

```bash
# THE gate: the whole bootrace suite (single setup; r1-r6). Timeout per AGENTS.md §2.
timeout 600 bash test/bootrace.sh
# Expected: exit 0; summary '8 passed, 0 failed' — r6_bug003_release_corrupt_lease PASS
#           (both variants), r5 still PASS (S1 untouched), all earlier cases still PASS.
# If r5/r3-neg regress: you touched S1's code or the shared kernel — re-read Task 1 scope.
# If r6 runs but a case named r6 never appears in the output: you forgot the
#           _br_run_suite list registration (vacuous green) — fix Task 3's registration.
```

### Level 3: Integration / Manual Verification (hermetic, timeout-bounded)

```bash
# 3a. The corrupt+dir+live-chrome shape, end-to-end through the real admin CLI.
T="$(mktemp -d -p "$HOME" -t abpool-r6man.XXXXXX)"
mkdir -p -- "$T/state/lanes" "$T/active/7" "$T/home"
printf 'not json {{{' >"$T/state/lanes/7.json"
bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$T/active/7 m" >/dev/null 2>&1 &
MP=$!; sleep 0.3
rc=0
env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    AGENT_CHROME_MASTER="$T/m" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
    timeout 30 bash "$PWD/bin/agent-browser-pool" release 7 || rc=$?
echo "rc=$rc (expect 0)"
[[ -e "$T/state/lanes/7.json" ]] && echo "FAIL: lease survived" || echo "lease gone (expect)"
[[ -e "$T/active/7" ]] && echo "FAIL: dir survived" || echo "dir gone (expect)"
sleep 0.2
pgrep -f -- "user-data-dir=$T/active/7( |\$)" >/dev/null 2>&1 && echo "FAIL: survivor" || echo "no survivors (expect)"
kill "$MP" 2>/dev/null || true; wait "$MP" 2>/dev/null || true; rm -rf -- "$T"
# Expected: rc=0 (expect 0), lease gone, dir gone, no survivors.
# NOTE: the admin CLI prints 'Released lane 7 (corrupt lease cleared).' to stdout (visible
#       above since we don't redirect); confirm it appears verbatim.

# 3b. Regression: the absent branch is unchanged.
T="$(mktemp -d -p "$HOME" -t abpool-r6reg.XXXXXX)"
env HOME="$T" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    timeout 30 bash "$PWD/bin/agent-browser-pool" release 99; echo "rc=$? (expect 1)"
rm -rf -- "$T"
# Expected: 'Lane 99 has no active lease.' then rc=1 (expect 1).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The lane number is actually UN-BURNED after the corrupt release (PRD's core harm).
T="$(mktemp -d -p "$HOME" -t abpool-r6free.XXXXXX)"
mkdir -p -- "$T/state/lanes" "$T/active" "$T/home"
for n in 1 2 3 4 5 6; do printf '{"port":%d}' "$((53400+n))" >"$T/state/lanes/$n.json"; done
printf 'not json {{{' >"$T/state/lanes/7.json"
env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    timeout 30 bash "$PWD/bin/agent-browser-pool" release 7 >/dev/null
n="$( ( trap - EXIT INT TERM; HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" \
        AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
        source "$PWD/lib/pool.sh" && pool_config_init && pool_find_free_lane ) 2>/dev/null || true )"
echo "find_free_lane=$n (expect 7)"
rm -rf -- "$T"
# Expected: find_free_lane=7 (expect 7) — the corrupt file's removal freed the lane.

# 4b. status no longer shows the '? ?' STALE row for the released lane.
T="$(mktemp -d -p "$HOME" -t abpool-r6st.XXXXXX)"
mkdir -p -- "$T/state/lanes" "$T/active" "$T/home"
printf 'not json {{{' >"$T/state/lanes/7.json"
env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    timeout 30 bash "$PWD/bin/agent-browser-pool" release 7 >/dev/null
env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    timeout 30 bash "$PWD/bin/agent-browser-pool" status 2>/dev/null | grep -qE '^ *7 ' \
    && echo "FAIL: status still shows lane 7" || echo "no lane-7 row (expect)"
rm -rf -- "$T"
# Expected: no lane-7 row (expect).

# 4c. Anchoring sanity — a prefix-colliding lane (70) is NEVER matched by lane 7's sweep.
T="$(mktemp -d -p "$HOME" -t abpool-r6anc.XXXXXX)"
mkdir -p -- "$T/active/70"
bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$T/active/70 m" >/dev/null 2>&1 &
MP=$!; sleep 0.3
mkdir -p -- "$T/state/lanes" "$T/home"
printf 'not json {{{' >"$T/state/lanes/7.json"
env HOME="$T/home" AGENT_BROWSER_POOL_STATE="$T/state" AGENT_CHROME_EPHEMERAL_ROOT="$T/active" \
    timeout 30 bash "$PWD/bin/agent-browser-pool" release 7 >/dev/null; sleep 0.2
pgrep -f -- "user-data-dir=$T/active/70( |\$)" >/dev/null 2>&1 \
    && echo "lane-70 process untouched (expect)" || echo "FAIL: sweep hit lane 70"
[[ -d "$T/active/70" ]] && echo "lane-70 dir intact (expect)" || echo "FAIL: dir 70 removed"
kill "$MP" 2>/dev/null || true; wait "$MP" 2>/dev/null || true; rm -rf -- "$T"
# Expected: both "(expect)" lines — the anchored pattern + guards cannot collide.

# 4d. Scope check (S1's landed work untouched).
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'pool_reap_orphan_dirs|pool_reap\(orphan\)' \
  && echo "FAIL: out-of-scope reap edit" || echo "scope OK: reap untouched"
git diff -- test/bootrace.sh | grep -E '^[+-]' | grep -E 'r5_bug003' \
  && echo "FAIL: R5 modified" || echo "scope OK: R5 untouched"
# Expected: scope OK (both).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` clean on lib/pool.sh + test/bootrace.sh.
- [ ] `shellcheck -S warning` clean on both (project gate).
- [ ] Level 3a/3b pass (corrupt shape end-to-end; absent-branch regression).
- [ ] Level 4a-4d pass (lane un-burned; no STALE row; prefix-collision safety; scope).
- [ ] `timeout 600 bash test/bootrace.sh` → exit 0, **8 passed, 0 failed** (incl. R6 both variants).

### Feature Validation

- [ ] Numeric branch: corrupt lease (file present, `pool_lease_exists` rc 1) → sweep-kill →
      prefix-guarded rm dir → rm lease → `Released lane N (corrupt lease cleared).` rc 0.
- [ ] Corrupt-with-dir + live marker process → zero survivors on the anchored pattern
      (R6 variant 1 + Level 3a — the sweep verifiably killed).
- [ ] Corrupt-without-dir → rc 0, lease gone (R6 variant 2 — the shape reap can't reach).
- [ ] Clean-lease branch byte-identical: `pool_release_lane` + `Released lane N.` rc 0.
- [ ] Absent branch byte-identical: `Lane N has no active lease.` rc 1 (Level 3b).
- [ ] $target validated `^[0-9]+$` before any path use (the elif classification).
- [ ] `pool_find_free_lane` returns the released lane number (Level 4a); status row gone (4b).

### Code Quality Validation

- [ ] Only lib/pool.sh (pool_admin_release + its docstring), test/bootrace.sh (r6 + list
      entry), README.md (release section) modified.
- [ ] S1's landed code untouched (4d): pool_reap_orphan_dirs seam, R5, README reap section.
- [ ] Every rc-1 call (`pool_lease_exists`, `pgrep -f`) inside if-conditions; every
      `pkill`/`rm` with `2>/dev/null || true`; `sleep 0.2` TERM→KILL grace preserved.
- [ ] rm -rf carries the 3-condition prefix guard (verbatim from step 4 of the kernel).
- [ ] No `local x="$(…)"` (SC2155); locals declared up front (`local dir` added).
- [ ] R6 follows the snapshot→cleanup→assert discipline; `_fail ... || rc_all=1`; kill+wait
      on the marker process (zero orphans, AGENTS.md §3).
- [ ] Docstring updated additively (new branch documented; set -e note extended).

### Documentation & Deployment

- [ ] README `### release`: corrupt-lease sentence + `Released lane 7 (corrupt lease cleared).`
      example; the `Lane 99 … # exit code 1` example and `### reap` section untouched.
- [ ] No new env vars, globals, schema, or files.

---

## Anti-Patterns to Avoid

- ❌ Don't try to reuse/fix `_pool_release_lane_internals` for the corrupt case — its step
  (1) early-returns 0 on unreadable JSON BY DESIGN (it runs in the reap loop over many
  lanes and must be non-fatal). The release-side branch is the contract (fix_design §4).
- ❌ Don't use `pool_chrome_kill` with ids parsed from the corrupt lease — ids from a
  corrupt lease are untrustworthy BY DEFINITION. Use the anchored cmdline sweep.
- ❌ Don't "simplify" the sweep pattern by dropping `( |$)` — pgrep/pkill -f match SUBSTRINGS;
  lane 3's unanchored pattern would kill lane 30/31/300 (Level 4c proves the anchoring).
- ❌ Don't drop the rm -rf prefix guard ("$target is already validated") — the guard is
  defense-in-depth house style; copy it verbatim (step 4 of the kernel).
- ❌ Don't put `pool_lease_exists`/`pgrep -f` as bare statements — rc 1 ABORTS under
  `set -euo pipefail` (lib/pool.sh line 1). Always inside if-conditions.
- ❌ Don't forget the `_br_run_suite` case-list registration — bootrace has NO compgen
  discovery; an unregistered r6 never runs (vacuous green). Registration is deliverable.
- ❌ Don't assert the R6 kill against the fake-chrome fixture — its final
  `exec python3 -m http.server` REPLACES cmdline (drops `user-data-dir=`) → the assertion
  passes vacuously. Use the exec -a sleep marker (host-verified).
- ❌ Don't touch S1's landed work: pool_reap_orphan_dirs, R5, README `### reap` — disjoint
  seams (fix_design §7: S1/S2 mutually independent).
- ❌ Don't weaken `pool_find_free_lane`'s `[[ -f ]]` or `pool_lane_is_stale`'s rc-2 skip —
  deliberate collision safety (system_context §7: "make the corrupt state reclaimable
  instead"); the reclaim is by explicit `release N`.
- ❌ Don't "fix" `release all` on corrupt leases here — out of scope (the item scopes the
  numeric branch); documented as a residual in README + the docstring.
- ❌ Don't add fsync to `_pool_atomic_write` — fix_design §5 decided NO (deliberate,
  documented; reclaim paths are the mitigation).
- ❌ Don't modify PRD.md, tasks.json, prd_snapshot.md, prd_index.txt, .gitignore, or any
  file beyond the three named (lib/pool.sh, test/bootrace.sh, README.md).

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The design is **pre-decided by fix_design §4 seam 2** (probe, teardown order, guards,
  message wording) — this PRP merely operationalizes it with the idioms quoted verbatim
  from their house sources, each line-cited against the CURRENT file (line drift from
  fix_design's HEAD-at-breakdown numbers is explicitly handled).
- **S1's landed state was verified in-tree** (not assumed): the reap seam, R5 + its list
  entry, and the README sentence are present — so S2's boundary is concrete, and the
  R6/R5 + scope checks (Level 4d) mechanically prevent regression/conflict.
- The two genuinely non-obvious traps are both surfaced with host-verified fixes: (1) the
  shared kernel's early-return (why the teardown must be inline), and (2) the fake-chrome
  fixture's exec-cmdline replacement (why R6 needs the `exec -a` marker — verified on this
  host: visible to the anchored pattern, TERM-killed, zero orphans, no lane-70 collision).
- The R6 case is paste-ready in the house style (seeding à la R5; snapshot→cleanup→assert
  à la r3_neg; `_fail || rc_all=1`; kill+wait reaping), and the suite's target count
  (7 → **8 passed, 0 failed**) is stated so a vacuous-green regression is detectable.
- The -1 reflects the residual environment sensitivity of Level-3/4 manual checks
  (`pgrep` timing on slow hosts — mitigated by the 0.2-0.3s settles) and that the bootrace
  full-suite run exercises the sibling majors' cases too, so a pre-existing flake there
  would surface as a failure the implementer must triage (the R3-control green-gate note in
  the harness header tells them fixtures-vs-pool apart).