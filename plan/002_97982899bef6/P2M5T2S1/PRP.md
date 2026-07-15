# PRP — P2.M5.T2.S1: Rewrite transparency.sh invocations + update passthrough/fail-fast tests

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`).
**Work item**: P2.M5.T2.S1 (2 points) — milestone P2.M5 (Test Framework Updates), task T2.
**Dependency / starting state**: Builds on the **SHIPPED POST-P2.M2 tree + the T1.S1 validate.sh contract**.
**VERIFIED LIVE**:
- `bin/` contains ONLY `agent-browser-pool` + `.gitkeep` (P2.M2.T2.S1 — the old `bin/agent-browser`
  shim is DELETED; `agent-browser-pool` is the sole entry point).
- `lib/pool.sh` `pool_wrapper_main` (P2.M1.T1.S2) **fail-fast** on no-pi-ancestor: `pool_die
  "agent-browser-pool: driving commands require a pi ancestor …"` (lib/pool.sh:3645) — exit 1,
  stderr contains the literal `pi ancestor`. `POOL_DISABLE` is GONE (`grep -c POOL_DISABLE
  lib/pool.sh` → 0).
- `bin/agent-browser-pool` dispatch (P2.M2.T1.S1): `status|reap|release|doctor|--help|-h|help` →
  `pool_admin_*`; `*) pool_wrapper_main "$@"`.
- `test/validate.sh` (the T1.S1 contract — already satisfied live): defines `ABPOOL_ADMIN`
  (line 26) and contains **NO `ABPOOL_WRAPPER`** (grep → 0).
- `test/transparency.sh` SOURCES `validate.sh` and runs under `set -euo pipefail` (line 51). It
  still references `$ABPOOL_WRAPPER` at 5 sites (lines 179, 233, 247, 320, 394) → these are
  **UNBOUND** → the suite ABORTS under `set -u` today. **So this item's rename is load-bearing,
  not cosmetic.** Full research: `plan/002_97982899bef6/P2M5T2S1/research/notes.md`.

**This item edits exactly ONE file: `test/transparency.sh`.**

---

## Goal

**Feature Goal**: Make `test/transparency.sh` consistent with the shipped **no-shadow
explicit-invocation** model (PRD §2.17): every invocation goes through the SOLE entry point
`bin/agent-browser-pool` (`$ABPOOL_ADMIN`), never through the deleted `bin/agent-browser` shim
(`$ABPOOL_WRAPPER`). Specifically: (1) rename all 5 `$ABPOOL_WRAPPER` → `$ABPOOL_ADMIN` (makes
the file runnable under `set -u` again); (2) **SPLIT** the old `test_passthrough_help_version`
into two tests, because `--help` is now a POOL VERB (caught by the bin `case` → `pool_admin_help`,
NOT real-binary help) while `--version` still passes through to the real binary; (3) **ADD** a
new `test_driving_no_pi_ancestor_fails_fast` validating the shipped fail-fast contract
(§2.4 step 1); (4) rewrite every `wrapper`/`passthrough`-for-no-pi comment to the
explicit-invocation vocabulary.

**Deliverable**: An edited `test/transparency.sh` (the verbatim semantic edits E1–E5 below +
the mechanical rename + comment table) that: contains ZERO `ABPOOL_WRAPPER`; ZERO bare `wrapper`
substring; invokes only `$ABPOOL_ADMIN`; asserts `--help` output CONTAINS `agent-browser-pool`
and `--version` output is byte-equal to the real binary; fails-fast-asserts the no-pi-ancestor
case; and passes `bash -n` + `shellcheck -s bash` with NO new error/warning findings (baseline =
only the pre-existing SC1091 infos).

**Success Definition**:
- `grep -c 'ABPOOL_WRAPPER' test/transparency.sh` → **0**.
- `grep -c 'wrapper' test/transparency.sh` → **0** (the whole wrapper concept is gone; no
  `pool_wrapper_main` refs live in transparency.sh — those are in validate.sh/lib).
- `grep -c 'ABPOOL_ADMIN' test/transparency.sh` → **≥6** (5 renamed invocation sites + the
  pre-existing line-481 runner `release all`).
- `grep -c 'test_help_shows_pool_help\|test_version_passthrough' test/transparency.sh` → **≥2**
  (the split is present) AND `grep -c 'test_passthrough_help_version'` → **0** (old combined fn gone).
- `grep -c 'test_driving_no_pi_ancestor_fails_fast' test/transparency.sh` → **≥1** (new fail-fast test).
- `bash -n test/transparency.sh` → exit 0. `shellcheck -s bash test/transparency.sh` → ONLY the
  pre-existing SC1091 infos (no SC2154 for `ABPOOL_WRAPPER`, no new error/warning codes).
- `git status --short` → only `test/transparency.sh` modified by this item.

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21) — "There is **no PATH shadowing** … `agent-browser-pool`
  (the sole entry point)". PRD §2.4 (h3.8) step 0 — `--help` is a POOL VERB; step 1 — "No pi
  ancestor → DRIVING fails fast". PRD §2.15 (h3.19) — the no-idea contract. The transparency
  suite must assert the ACTUAL shipped routing, not the deleted shim's. The current file asserts
  `--help` byte-equal to the real binary (now FALSE — `--help` shows pool help) and references a
  non-existent `$ABPOOL_WRAPPER` (aborts under `set -u`).
- **Who it helps**: Anyone running `bash test/transparency.sh` in an isolated sandbox — right now
  it ABORTS (unbound `ABPOOL_WRAPPER`) and, even if it didn't, the `--help` assertion would FAIL.
  After this item the suite is green against the live model and also newly covers the fail-fast
  contract (which no test validated). It unblocks P2.M5.T3.S1 (concurrency/release_reaper comments).
- **Scope cohesion**: Item T2.S1 of milestone P2.M5. Its ONLY job is the transparency.sh rewrite.
  It does NOT touch validate.sh (T1.S1), concurrency.sh/release_reaper.sh (T3.S1), lib/pool.sh,
  bin/*, install.sh, or any .md (each owned by completed/sibling/later items).

---

## What

**User-visible behavior**: None directly — `test/transparency.sh` is a test harness. The
observable effect: the suite runs against the sole-entry-point model; `--help` is asserted to
show POOL help; `--version`/`skills` are asserted to pass through byte-equal; no-pi-ancestor
driving commands are asserted to fail fast.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `lib/pool.sh`, `bin/agent-browser-pool`, `install.sh` — SHIPPED behavior (read-only).
- `test/validate.sh` (T1.S1 owns it), `test/concurrency.sh`, `test/release_reaper.sh` (T3.S1).
- All `*.md`, `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — read-only.
- In `test/transparency.sh` itself: every helper (`_transparency_setup_real_env`,
  `_transparency_acquire_boot`, `_transparency_spawn_owner`, `_transparency_kill_owner`,
  `_transparency_run_open_bg`'s LOGIC (only its var+comment change), `_transparency_wait_my_lane`,
  `_transparency_reap_bg`, `_transparency_reap_all_sim_owners`); tests (c)–(h) LOGIC (only their
  invocation var + comments change); the single-setup runner `_abpool_run_transparency_suite`
  (auto-discovers `^test_` via `compgen` — adding/splitting test fns needs ZERO runner change).

### Success Criteria

- [ ] ZERO `$ABPOOL_WRAPPER` references (def gone because it's in validate.sh; all 5 uses renamed).
- [ ] ZERO bare `wrapper` substring (every comment rewritten to `driving command`/`pool`).
- [ ] All driving/meta invocations use `$ABPOOL_ADMIN` (the sole entry point).
- [ ] `test_passthrough_help_version` REMOVED; replaced by `test_help_shows_pool_help` (asserts
      `--help` output CONTAINS `agent-browser-pool`) + `test_version_passthrough` (byte-equal to
      `$POOL_REAL_BIN --version`).
- [ ] `test_passthrough_skills` keeps byte-equal (skills is META → passthrough); only var+comment change.
- [ ] NEW `test_driving_no_pi_ancestor_fails_fast` asserts a no-pi-ancestor driving command fails
      fast (output contains `pi ancestor`).
- [ ] No comment anywhere calls no-pi-ancestor "passthrough" (it is fail-fast now).
- [ ] `bash -n` → 0; `shellcheck -s bash` → only pre-existing SC1091 infos; only transparency.sh changed.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes.** Every semantic change is given **verbatim** below (E1–E5: exact old → new
blocks, copy-pasteable into `edit`); the variable rename is a safe 5-site replacement (enumerated
+ grep-verified); the remaining comment edits are an explicit old→new fragment table. The one
non-obvious thing — WHY `--help` is no longer passthrough (the bin `case` intercepts it before
`pool_wrapper_main`) and HOW to deterministically test no-pi-ancestor despite this suite possibly
running under `pi` (setsid-detach) — is fully explained in §Known Gotchas with the exact mechanism.

### Documentation & References

```yaml
# MUST READ — the dispatch contract that decides every assertion
- file: bin/agent-browser-pool
  why: The SOLE entry point. Its `case "$cmd"` intercepts status|reap|release|doctor|--help|-h|help
        BEFORE pool_wrapper_main. So `--help` → pool_admin_help (POOL help), NOT passthrough.
        `--version`/`skills`/driving → `*) pool_wrapper_main "$@"`.
  critical: "THIS is why test (b) must split: --help never reaches pool_dispatch_classify. classify
             DOES tag --help|-h|--version as 'meta' (lib/pool.sh ~3180), but that only matters for
             tokens that REACH pool_wrapper_main (--version has no case arm → it reaches it → meta
             → exec real binary → byte-equal HOLDS). --help is swallowed by the bin case."

- file: lib/pool.sh   pool_wrapper_main  (lines 3619-3772)  + pool_dispatch_classify (3173-3233)
  why: step order: config→preflight→classify(meta→exec)→owner_resolve(==0→pool_die)→acquire/boot/exec.
        pool_dispatch_classify: --help|-h|--version / session list / skills|dashboard|plugin|mcp → meta.
  critical: "no-pi-ancestor → pool_die 'agent-browser-pool: driving commands require a pi ancestor …'
             (line 3645). pool_die (line 30): printf '%s\\n' \"$*\" >&2; exit 1 → full msg to STDERR,
             exit 1, contains literal 'pi ancestor'. preflight (_pool_preflight_real_bin) runs BEFORE
             owner-resolve → AGENT_BROWSER_REAL must be set or pool_die fires a DIFFERENT msg."

- file: lib/pool.sh   pool_admin_help  (lines 4592-4666)
  why: First line of `agent-browser-pool --help` output = 'agent-browser-pool — the sole entry point …'.
  critical: "Output CONTAINS the literal 'agent-browser-pool'. The real Vercel agent-browser --help
             never emits '-pool'. So [[ \"$out\" == *agent-browser-pool* ]] is unique + robust."

- file: lib/pool.sh   pool_owner_resolve  (lines 487-590)
  why: TEST MODE if AGENT_BROWSER_POOL_OWNER_PID set+numeric → comm='pi'. REAL MODE walks ppid from $$.
  critical: "There is NO 'force no-owner' env var. To SIMULATE no-pi-ancestor deterministically you must
             detach the driving subprocess from this shell's ppid tree (setsid) AND strip the owner env
             override (env -u). See §Known Gotchas + E5."

- contract: plan/002_97982899bef6/P2M5T1S1/PRP.md   (the T1.S1 contract this builds on)
  why: T1.S1 removed ABPOOL_WRAPPER from validate.sh and kept ABPOOL_ADMIN (line 26). transparency.sh
        SOURCES validate.sh → $ABPOOL_ADMIN is available, $ABPOOL_WRAPPER is GONE (unbound under set -u).
  critical: "Do NOT re-add ABPOOL_WRAPPER to validate.sh. It is correctly gone. transparency.sh must
             switch to the already-defined $ABPOOL_ADMIN."

- contract: plan/002_97982899bef6/architecture/gap_analysis.md   §9
  why: §9 test/transparency.sh — the change map for THIS item (a-g). Matches the item_description.
  critical: "§9's point (b): --help is now a pool verb; byte-equal assertion is WRONG. point (d):
             no-pi-ancestor was passthrough, now fail-fast."

- prd: PRD §2.17 (h3.21), §2.4 (h3.8), §2.15 (h3.19), §2.18 (h3.22)
  why: no PATH shadowing / sole entry point; --help is a pool verb + no-pi-ancestor fails fast; the
        no-idea contract; the AGENT_BROWSER_POOL_OWNER_PID test-hook override for simulating owners.

- file: test/transparency.sh   (CURRENT file — EDITED by E1-E5 + rename + comment table)
  why: The file being edited. 502 lines. Read it to anchor the edits against current line numbers.
  pattern: "Single-setup runner (ONE setup(); bodies via `if \"$fn\"`; main shell, no subshell). Bodies
            spawn their OWN owner via _transparency_spawn_owner. Chrome booted headless via the lib
            (pool_acquire_locked/pool_boot_lane) to avoid terminal-exec hangs. The runner auto-discovers
            ^test_ fns — adding/splitting fns needs NO runner edit."
```

### Current codebase tree (relevant slice)

```bash
test/
├── transparency.sh    # EDITED by this item (502 → ~530 lines after split + new test). The deliverable.
├── validate.sh        # SOURCED by transparency.sh. ABPOOL_ADMIN defined (L26); ABPOOL_WRAPPER GONE (T1.S1).
├── concurrency.sh     # UNTOUCHED (P2.M5.T3.S1 — comments only)
└── release_reaper.sh  # UNTOUCHED (P2.M5.T3.S1 — comments only)
bin/
├── agent-browser-pool # UNTOUCHED (P2.M2 done — sole entry point). Its `case` decides every assertion.
└── .gitkeep           # UNTOUCHED
lib/pool.sh            # UNTOUCHED (P2.M1 done — fail-fast; pool_admin_help; pool_dispatch_classify).
PRD.md                 # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
test/
└── transparency.sh   # EDITED: $ABPOOL_WRAPPER→$ABPOOL_ADMIN (5 sites); test (b) split into 2 fns;
                      #   +test_driving_no_pi_ancestor_fails_fast; all 'wrapper' comments rewritten.
# No new files. No deletions. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL — WHY --help IS NOT PASSTHROUGH (the heart of test (b)'s split):
#   bin/agent-browser-pool does `case "$cmd" in ... --help|-h|help) pool_admin_help ;; ... *) pool_wrapper_main`.
#   `$1`=`--help` matches the --help arm → pool_admin_help. It NEVER reaches pool_wrapper_main or
#   pool_dispatch_classify. So `agent-browser-pool --help` prints the POOL's help (first line:
#   "agent-browser-pool — the sole entry point …"), NOT the real agent-browser's help. The old
#   byte-equal assertion (wrapper --help == real --help) is now FALSE and would FAIL.
#   `--version` has NO case arm → `*) pool_wrapper_main --version` → classify tags --version as meta
#   → `exec "$POOL_REAL_BIN" --version` → byte-equal to the real binary STILL HOLDS.

# CRITICAL — NO-PI-ANCESTOR IS FAIL-FAST, NOT PASSTHROUGH (shipped P2.M1.T1.S2):
#   pool_wrapper_main step d: POOL_OWNER_PID==0 → pool_die (exit 1, stderr 'pi ancestor'). Any comment
#   or assertion implying no-pi-ancestor "passes through" is WRONG and must become fail-fast.

# CRITICAL — DETERMINISTIC NO-PI-ANCESTOR TESTING (why a naive test would be FLAKY):
#   pool_owner_resolve REAL MODE walks ppid from $$. THIS SUITE IS OFTEN LAUNCHED BY `pi` (the coding
#   harness), so a normally-spawned `$ABPOOL_ADMIN` child's ppid chain INCLUDES pi → it would FIND an
#   owner → NOT fail-fast → flaky/context-dependent. The env override AGENT_BROWSER_POOL_OWNER_PID only
#   SIMULATES an owner EXISTING; there is NO "force no-owner" env var.
#   FIX (E5): detach via `setsid` (no --wait) — setsid forks the child into a NEW session + exits; the
#   child reparents to the subreaper/pid 1 (systemd, comm!='pi') → ppid walk finds no 'pi' → PID=0 →
#   fail-fast. `env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME` strips any
#   inherited override. setsid exits before the child ⇒ `$()` capture is racy ⇒ redirect the detached
#   child's output to a TEMP FILE and poll (bounded; pool_die fires at step d, BEFORE any Chrome/lane
#   work ⇒ sub-second). Reliable on Linux (setsid is util-linux). No hang, no orphan (child self-exits
#   via pool_die; setsid pid reaped by `wait`; grandchild reaped by subreaper).

# CRITICAL — PREFLIGHT RUNS BEFORE THE DIE: pool_wrapper_main calls _pool_preflight_real_bin at step b,
#   BEFORE owner-resolve/die. If AGENT_BROWSER_REAL is unset, preflight pool_die's with a REAL-BIN msg
#   (not 'pi ancestor') → the new test would fail for the wrong reason. So test (i) MUST call
#   _transparency_setup_real_env first (it exports AGENT_BROWSER_REAL). It must NOT call
#   _transparency_spawn_owner (we want NO owner).

# CRITICAL — the rename is REQUIRED, not cosmetic: validate.sh (T1.S1) has NO ABPOOL_WRAPPER. Under
#   `set -u` (transparency.sh line 51) every `$ABPOOL_WRAPPER` is unbound → the suite ABORTS at the
#   first driving/meta invocation. grep -c ABPOOL_WRAPPER MUST be 0 after the edit.

# CRITICAL (shellcheck baseline): `shellcheck -s bash test/transparency.sh` exits 1 TODAY with ONLY
#   SC1091 (info, x2 — the `source ./validate.sh` lines). Do NOT treat exit 1 as failure. Gate =
#   no NEW error/warning codes; specifically NO SC2154 (unbound ABPOOL_WRAPPER) after the rename.

# CRITICAL (AGENTS.md §1/§6): validation during implementation is STATIC ONLY — bash -n + shellcheck +
#   grep + git status. Do NOT run `bash test/transparency.sh` as a gate: the suite boots real Chrome +
#   spawns sim-owners (sandbox-wedge risk). It is OPTIONAL, in a fully isolated container only (Level 3).

# GOTCHA — 'wrapper' substring must reach ZERO, not just ABPOOL_WRAPPER. grep -c wrapper must be 0.
#   All ~21 current 'wrapper' hits (lines 18,19,24,82,169,171,177,178,184,201,235,249,256,298,299,318,
#   327,353,355,390,478) refer to the deleted shim / wrapper-driven commands. None is pool_wrapper_main
#   (that lives in validate.sh/lib). Drive them all to 0 via the comment table in §Implementation.

# GOTCHA — keep 'passthrough' ONLY for META. skills/--version genuinely pass through (meta → exec real
#   binary). Do NOT erase the word 'passthrough' from test (a)/(b2); just never apply it to no-pi-ancestor.

# GOTCHA — the runner is auto-discovery (compgen ^test_). Splitting test (b) into 2 fns + adding test (i)
#   needs ZERO runner edits. The new fns are picked up automatically. Do NOT touch _abpool_run_transparency_suite.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is a set of surgical edits to one bash test harness. The semantic
edits (E1–E5) are given **verbatim** below (exact old → new, copy-pasteable into `edit`); the
variable rename + comment edits are enumerated mechanically.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ + anchor (context — no writes)
  - READ: test/transparency.sh  lines 1-35 (header + GOTCHA), 165-205 (_transparency_run_open_bg +
          its comments), 224-251 (tests a + b), 290-400 (tests e + g comments), 425-490 (runner).
  - CONFIRM (read-only, already verified in research): bin/ has only agent-browser-pool; validate.sh
           has ABPOOL_ADMIN (L26) and NO ABPOOL_WRAPPER; lib/pool.sh:3645 pool_die has 'pi ancestor';
           pool_admin_help first line has 'agent-browser-pool'.
  - WHY: anchor the edits against current line numbers + confirm the shipped state justifies each change.

Task 2: RENAME the 5 $ABPOOL_WRAPPER → $ABPOOL_ADMIN (mechanical, REQUIRED for runnability)
  - The 5 sites (all INVOCATIONS, verified by grep — NO comment uses the $variable): lines 179, 233,
    247, 320, 394. NOTE: line 247 is inside test_passthrough_help_version, which E4 REPLACES wholly,
    so it is handled by E4 — do not double-edit. Effective standalone-rename sites: 179, 233, 320, 394.
  - SAFE one-shot: `sed -i 's/\$ABPOOL_WRAPPER/\$ABPOOL_ADMIN/g' test/transparency.sh` (matches ONLY
    the $variable; comments use the bare word 'wrapper' without $, so they are untouched — they are
    handled by the comment table in Task 5). OR 4 explicit edits. Either way.
  - VERIFY after: `grep -c ABPOOL_WRAPPER test/transparency.sh` → 0.
  - WHY: validate.sh (T1.S1) no longer defines ABPOOL_WRAPPER → under set -u the suite aborts. ABPOOL_ADMIN
         (validate.sh L26) is the sole entry point. Item_description point (a)/(e).

Task 3: SEMANTIC EDITS — apply E1, E2, E3, E4 (verbatim below)
  - E1: rewrite the header comment list (a)-(h) → (a),(b1),(b2),(c)-(h),(i). [anchored, unique]
  - E2: rewrite the 'open MAY HANG' GOTCHA block (wrapper→driving command; fix lib line ref). [unique]
  - E3: rewrite test_passthrough_skills (a) comment + assertion text (keeps byte-equal; META stays). [unique]
  - E4: REPLACE test_passthrough_help_version with test_help_shows_pool_help + test_version_passthrough. [unique]
  - WHY: gap_analysis §9 (b)/(d) + PRD §2.4 step 0 (--help is a pool verb) + the verified dispatch semantics.
  - BUCKET: required.

Task 4: ADD test_driving_no_pi_ancestor_fails_fast (E5 — verbatim below)
  - INSERT the new test_* function (verbatim in E5) immediately BEFORE the `_abpool_run_transparency_suite`
    runner (i.e. after test_next_agent_distinct_lane's closing brace), with a `# ===` separator.
  - WHY: covers the shipped §2.4 fail-fast contract no test currently validates (gap_analysis §9 (d)).
         Deterministic via setsid-detach (see §Known Gotchas). Auto-discovered by the runner (no runner edit).
  - BUCKET: required.

Task 5: COMMENT REWRITE — apply the old→new fragment table (drive `grep -c wrapper` → 0)
  - For EACH row in the Comment Rewrite Table below: replace the exact old fragment with the new one.
    These are the ~15 remaining 'wrapper' comment fragments NOT already handled by E1/E2/E3/E4.
  - VERIFY after: `grep -c wrapper test/transparency.sh` → 0.
  - WHY: item_description point (f) — update ALL wrapper/PATH-shadowing/passthrough comments to the
         explicit-invocation model. 'passthrough' stays ONLY for META (skills/--version), never no-pi.
  - BUCKET: required.

Task 6: STATIC VALIDATION (AGENTS.md §1: static only — no execution)
  - RUN: bash -n test/transparency.sh  (expect exit 0).
  - RUN: shellcheck -s bash test/transparency.sh  (expect ONLY the pre-existing SC1091 infos;
         assert NO SC2154 for ABPOOL_WRAPPER, no new error/warning — see §Validation Loop L1).
  - RUN: the grep assertions in §Validation Loop Level 1 (ABPOOL_WRAPPER→0; wrapper→0; ABPOOL_ADMIN≥6;
         split fns present; old combined fn gone; new test present; 'pi ancestor' present).
  - RUN: git status --short  (expect ONLY test/transparency.sh modified by this item).
  - WHY: contract step (g) + AGENTS.md §1/§6. No Chrome, no daemons, no test-suite run.
  - BUCKET: required.
```

#### Edit Targets (verbatim old → new — copy-pasteable into `edit`)

> All `oldText` blocks are verified UNIQUE in the current `test/transparency.sh`. E1–E4 can be one
> `edit` call (4 `edits[]` entries) since their oldText blocks are disjoint+unique; E5 is a separate
> insert. Line numbers are current anchors (the edit matches on exact text, so drift is irrelevant).

---

**E1 — rewrite the header comment list (the (a)-(h) block, current lines ~7-15):**

oldText:
```
# Proves that an agent issuing the EXACT commands the upstream agent-browser skill teaches
# (`skills get core`, `open`, `connect <port>`, `--session <X>`, `close --all`, …) is
# silently routed to its own locked ephemeral lane and CAN NEITHER DETECT NOR ESCAPE the
# pool. One test_* body per §2.15 clause:
#   (a) agent-browser skills get core    → passthrough (META, unaffected)
#   (b) --help / --version               → passthrough (META, unaffected)
#   (c) open <url> zero-prep             → lands MY lane (acquired+booted+connected+leased)
#   (d) 2nd open same owner              → reuses the SAME lane N (find_mine, not re-acquire)
#   (e) connect <random>                 → routed to MY lane (the <port|url> arg is STRIPPED)
#   (f) --session <X> open <url>         → forced to abpool-<N> (X is STRIPPED + env forced)
#   (g) close --all                      → only MY lane's daemon session closed; PEER unaffected
#   (h) next agent (distinct PID)        → a DIFFERENT lane (no collision)
```
newText:
```
# Proves that an agent issuing the EXACT commands the agent-browser-pool skill teaches
# (`skills get core`, `open`, `connect <port>`, `--session <X>`, `close --all`, …) is routed
# to its own locked ephemeral lane via the SOLE entry point bin/agent-browser-pool (explicit
# invocation — NO PATH shadowing) and CAN NEITHER DETECT NOR ESCAPE the pool. One test_* body
# per §2.15 clause (+ invocation-surface + fail-fast contracts):
#   (a)  agent-browser-pool skills get core → passthrough (META → exec real binary; byte-equal)
#   (b1) agent-browser-pool --help          → POOL help (bin dispatch → pool_admin_help; NOT real help)
#   (b2) agent-browser-pool --version       → passthrough (META → exec real binary; byte-equal)
#   (c)  open <url> zero-prep               → lands MY lane (acquired+booted+connected+leased)
#   (d)  2nd open same owner                → reuses the SAME lane N (find_mine, not re-acquire)
#   (e)  connect <random>                   → routed to MY lane (the <port|url> arg is STRIPPED)
#   (f)  --session <X> open <url>           → forced to abpool-<N> (X is STRIPPED + env forced)
#   (g)  close --all                        → only MY lane's daemon session closed; PEER unaffected
#   (h)  next agent (distinct PID)          → a DIFFERENT lane (no collision)
#   (i)  driving cmd, no pi ancestor        → FAIL-FAST pool_die (exit 1 + 'pi ancestor'; §2.4 step 1)
```

---

**E2 — rewrite the 'open MAY HANG' GOTCHA block (current lines ~18-24):**

oldText:
```
# ★★★ THE 'open MAY HANG' GOTCHA (§gotcha 1) ★★★ The wrapper's success path TERMINATES via
# `exec "$POOL_REAL_BIN" …` (lib/pool.sh:3546). A wrapper-driven `open` may NOT exit (the
# real agent-browser can stay foregrounded). So item (c)/(d)/(f) NEVER `wait` an open bare;
# they background it under a HARD `timeout --signal=KILL`, then POLL `pool_lease_find_mine`
# for the lane (the lane is acquired+booted+connected+lease-WRITTEN BEFORE the terminal exec
# ⇒ observable while the driving open runs), then kill+wait the bg job. Chrome survives the
# wrapper kill (setsid → own session); the runner's inter-body `release all` reaps it.
```
newText:
```
# ★★★ THE 'open MAY HANG' GOTCHA (§gotcha 1) ★★★ A driving command's success path TERMINATES
# via `exec "$POOL_REAL_BIN" …` (pool_wrapper_main step k, lib/pool.sh). A driving `open` may
# NOT exit (the real agent-browser can stay foregrounded). So item (c)/(d)/(f) NEVER `wait`
# an open bare; they background it under a HARD `timeout --signal=KILL`, then POLL
# `pool_lease_find_mine` for the lane (the lane is acquired+booted+connected+lease-WRITTEN
# BEFORE the terminal exec ⇒ observable while the driving open runs), then kill+wait the bg
# job. Chrome survives the driving-command kill (setsid → own session); the runner's
# inter-body `release all` reaps it.
```

---

**E3 — rewrite test_passthrough_skills (a) header comment + assertion text (keeps byte-equal):**

oldText:
```
# =============================================================================
# TEST (a) — `agent-browser skills get core` → passthrough (META, byte-equal to real binary).
# PRD §2.15: meta commands are unaffected. META short-circuits in pool_dispatch_classify
# (lib/pool.sh:3036) BEFORE owner resolve — but set a pi ancestor anyway to prove meta wins
# regardless. Assert EQUALITY (not content — version/skills output varies).
# =============================================================================
test_passthrough_skills() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null       # a pi ancestor IS present; meta ignores it
    local w r
    w="$(timeout 15 "$ABPOOL_WRAPPER" skills get core 2>/dev/null || true)"
    r="$(timeout 15 "$POOL_REAL_BIN"  skills get core 2>/dev/null || true)"
    assert_eq "$r" "$w" "skills get core: wrapper output == real binary output (passthrough)" || return 1
}
```
newText:
```
# =============================================================================
# TEST (a) — `agent-browser-pool skills get core` → passthrough (META, byte-equal to real binary).
# PRD §2.15: meta commands are unaffected. `skills` has no case arm in bin/agent-browser-pool →
# `*) pool_wrapper_main` → pool_dispatch_classify classifies cmd=`skills` as meta → exec
# `$POOL_REAL_BIN skills get core`. META short-circuits BEFORE owner resolve — but set a pi
# ancestor anyway to prove meta wins regardless. Assert EQUALITY (not content — output varies).
# =============================================================================
test_passthrough_skills() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null       # a pi ancestor IS present; meta ignores it
    local w r
    w="$(timeout 15 "$ABPOOL_ADMIN" skills get core 2>/dev/null || true)"
    r="$(timeout 15 "$POOL_REAL_BIN"  skills get core 2>/dev/null || true)"
    assert_eq "$r" "$w" "skills get core: pool output == real binary output (meta passthrough)" || return 1
}
```
*(Renames the var to `$ABPOOL_ADMIN`; rewrites the comment (skills→meta via pool_wrapper_main,
not "META short-circuits in classify before owner" framing stays accurate); assertion text
`wrapper output` → `pool output`. Byte-equal assertion is PRESERVED — skills genuinely passes through.)*

---

**E4 — SPLIT test_passthrough_help_version into test_help_shows_pool_help + test_version_passthrough:**

oldText (the whole combined function, current lines ~239-251):
```
# =============================================================================
# TEST (b) — `--help` and `--version` → passthrough (META, byte-equal). Same shape as (a),
# TWO sub-checks (both flags). Assert EQUALITY (not content).
# =============================================================================
test_passthrough_help_version() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local w r flag
    for flag in --help --version; do
        w="$(timeout 15 "$ABPOOL_WRAPPER" "$flag" 2>/dev/null || true)"
        r="$(timeout 15 "$POOL_REAL_BIN"  "$flag" 2>/dev/null || true)"
        assert_eq "$r" "$w" "$flag: wrapper output == real binary output (passthrough)" || return 1
    done
}
```
newText:
```
# =============================================================================
# TEST (b1) — `agent-browser-pool --help` → POOL help (NOT passthrough).
# PRD §2.15 / §2.4 step 0: `--help` is a POOL VERB caught by bin/agent-browser-pool's dispatch
# case (`--help|-h|help) → pool_admin_help`) BEFORE pool_wrapper_main/pool_dispatch_classify run.
# So the output is the POOL's help text — NOT the real agent-browser's help. The byte-equal
# assertion that held under PATH-shadowing is now WRONG. Assert the output CONTAINS the pool's
# signature phrase 'agent-browser-pool' (the real agent-browser --help never emits '-pool').
# (A pi ancestor is irrelevant to a pool verb, but spawn one for parity with the other bodies.)
# =============================================================================
test_help_shows_pool_help() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local out
    out="$(timeout 15 "$ABPOOL_ADMIN" --help 2>&1 || true)"
    [[ "$out" == *"agent-browser-pool"* ]] \
        || { _fail "--help did not show pool help (missing 'agent-browser-pool'); got: $out"; return 1; }
}

# =============================================================================
# TEST (b2) — `agent-browser-pool --version` → passthrough (META, byte-equal to real binary).
# `--version` has NO case arm in bin/agent-browser-pool → falls to `*) pool_wrapper_main` →
# pool_dispatch_classify classifies `--version` as meta → exec `$POOL_REAL_BIN --version`.
# So the byte-equal assertion STILL HOLDS (identical to the old model, just via $ABPOOL_ADMIN).
# =============================================================================
test_version_passthrough() {
    _transparency_setup_real_env || return 1
    _transparency_spawn_owner >/dev/null
    local w r
    w="$(timeout 15 "$ABPOOL_ADMIN"  --version 2>/dev/null || true)"
    r="$(timeout 15 "$POOL_REAL_BIN" --version 2>/dev/null || true)"
    assert_eq "$r" "$w" "--version: pool output == real binary output (meta passthrough)" || return 1
}
```
*(Replaces the single combined loop with TWO auto-discovered functions: `--help` asserts CONTAINS
`agent-browser-pool` (pool help, not real help); `--version` keeps byte-equal (it still passes
through). Both use `$ABPOOL_ADMIN`. The runner auto-discovers `^test_` so the split needs no
runner edit.)*

---

**E5 — ADD test_driving_no_pi_ancestor_fails_fast (NEW; insert before the runner):**

> INSERT this function immediately BEFORE the `_abpool_run_transparency_suite` runner comment
> block (i.e. after `test_next_agent_distinct_lane`'s closing `}`), with a `# ===` separator.
> Anchor the insert on the unique line `# _abpool_run_transparency_suite — the SINGLE-SETUP runner.`

newText (the new function to insert — prepend it before that unique runner-comment line):
```bash
# =============================================================================
# TEST (i) — driving command with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
# PRD §2.4 step 1 / shipped P2.M1.T1.S2: "No pi ancestor → DRIVING fails fast" — pool_wrapper_main
# step d calls pool_die (exit 1, stderr contains 'pi ancestor … for raw browser use call
# 'agent-browser' directly').
#
# DETERMINISM: pool_owner_resolve REAL MODE walks ppid from $$. This suite is often launched BY
# `pi` (the coding harness), so a normally-spawned driving subprocess's ppid chain INCLUDES pi →
# it would find an owner → NOT fail-fast → flaky. There is no "force no-owner" env var. So DETACH
# the driving command from this shell's tree via `setsid` (no --wait): setsid forks the child into
# a NEW session and exits; the child reparents to the subreaper / pid 1 (systemd, comm != 'pi') →
# ppid walk finds no 'pi' → POOL_OWNER_PID=0 → fail-fast. `env -u` strips any inherited owner
# override. Because setsid exits before the child, $() capture is racy → redirect the detached
# child's output to a TEMP FILE and poll (bounded) for 'pi ancestor'. pool_die fires at step d,
# BEFORE any Chrome/lane work → sub-second. No hang, no orphan (child self-exits via pool_die;
# setsid pid reaped by `wait`; grandchild reaped by its new parent/subreaper — AGENTS.md §3).
# =============================================================================
test_driving_no_pi_ancestor_fails_fast() {
    _transparency_setup_real_env || return 1   # AGENT_BROWSER_REAL MUST be set so _pool_preflight_real_bin passes BEFORE the owner-resolve die
    # Deliberately NO _transparency_spawn_owner — this body has NO pi ancestor.
    local tmp bg deadline msg
    tmp="$(mktemp)"
    # Fully detach: setsid (new session → reparent to subreaper, comm != 'pi') + strip owner overrides.
    env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        setsid "$ABPOOL_ADMIN" open about:blank >"$tmp" 2>&1 &
    bg=$!
    wait "$bg" 2>/dev/null || true              # setsid exits immediately after forking the detached child
    # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
    deadline=$(( $(date +%s) + 10 ))
    msg=""
    while (( $(date +%s) < deadline )); do
        msg="$(cat "$tmp" 2>/dev/null || true)"
        [[ "$msg" == *"pi ancestor"* ]] && break
        sleep 0.2
    done
    rm -f -- "$tmp"
    [[ "$msg" == *"pi ancestor"* ]] \
        || { _fail "driving cmd with no pi ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
}

```

---

#### Comment Rewrite Table (Task 5 — drive `grep -c wrapper` → 0)

For each row, replace the **exact old fragment** with the new one. (Fragments already handled by
E1/E2/E3/E4 are omitted. These are the remaining `wrapper`-word comment sites.)

| Line (~) | old fragment | new fragment |
|----------|---------------|--------------|
| 82  | `pool_release_lane's daemon close, and every wrapper exec ALL fail.` | `pool_release_lane's daemon close, and every driving exec ALL fail.` |
| 169 | `# WHY: a wrapper-driven \`open\` may NOT exit` | `# WHY: a driving \`open\` may NOT exit` |
| 171 | `So background the wrapper under a HARD \`timeout` | `So background the driving command under a HARD \`timeout` |
| 177 | `# $@ = wrapper args (e.g.` | `# $@ = driving args (e.g.` |
| 178 | `it kills its child — the wrapper — on expiry).` | `it kills its child — the driving command — on expiry).` |
| 184 | `the same seam the wrapper's reuse` | `the same seam the pool's reuse` |
| 201 | `# Chrome survives the wrapper kill (setsid` | `# Chrome survives the driving-command kill (setsid` |
| 256 | `# Backgrounds the wrapper open (may not exit)` | `# Backgrounds the driving open (may not exit)` |
| 298 | `with a live lane N, a wrapper \`connect <random>\` must NOT move us` | `with a live lane N, a driving \`connect <random>\` must NOT move us` |
| 299 | `After Issue #1 the wrapper SHORT-CIRCUITS` | `After Issue #1 the pool SHORT-CIRCUITS` |
| 318 | `post-Issue #1 the wrapper short-circuits to a success no-op` | `post-Issue #1 the pool short-circuits to a success no-op` |
| 327 | `the upstream --session flag. The wrapper` | `the upstream --session flag. The pool` |
| 353 | `\`close --all\` through the wrapper (scoped to abpool-NA` | `\`close --all\` through the pool (scoped to abpool-NA` |
| 355 | `# The wrapper exec's \`"$POOL_REAL_BIN"\`` | `# The pool exec's \`"$POOL_REAL_BIN"\`` |
| 390 | `run its close --all through the wrapper (scoped to abpool-NA).` | `run its close --all through the pool (scoped to abpool-NA).` |
| 478 | `Chrome from a bg'd open survives wrapper kill (setsid)` | `Chrome from a bg'd open survives driving-command kill (setsid)` |

> After applying: `grep -c wrapper test/transparency.sh` → **0**. (If any hit remains, it is a
> missed row — apply its old→new fragment.) `passthrough` SHOULD still appear for META (skills in
> E3's assertion text, --version in E4's `test_version_passthrough`) — that is correct; do NOT
> remove `passthrough` there. `passthrough` must NOT appear for no-pi-ancestor anywhere.

### Implementation Patterns & Key Details

```bash
# PATTERN — the assertion shape changed for exactly ONE token (--help) and is preserved for the rest.
#   skills (a): byte-equal to $POOL_REAL_BIN  — META passthrough (unchanged contract, just $ABPOOL_ADMIN).
#   --help (b1): CONTAINS 'agent-browser-pool' — POOL verb (bin case intercepts it).
#   --version (b2): byte-equal to $POOL_REAL_BIN — META passthrough (reaches pool_wrapper_main → meta).
#   driving (c-h): lane assertions — unchanged contract, just $ABPOOL_ADMIN.
#   no-pi (i): fail-fast — output contains 'pi ancestor' (NEW contract coverage).

# PATTERN — the runner is auto-discovery. _abpool_run_transparency_suite: `compgen -A function |
#   grep '^test_' | sort`. Splitting test (b) into 2 fns + adding test (i) needs NO runner edit.
#   The new fns run as their own bodies with the same inter-body backstop (release all + reap).

# PATTERN — every driving/meta invocation now goes through the SOLE entry point $ABPOOL_ADMIN
#   (bin/agent-browser-pool). There is no $ABPOOL_WRAPPER anywhere (validate.sh T1.S1 removed it).
#   Under set -u the old refs aborted; the rename restores runnability.

# GOTCHA — test (i) determinism depends on setsid-detach reparenting the child to a non-'pi'
#   subreaper (systemd/init). Reliable on Linux (util-linux). If your sandbox's subreaper were
#   somehow 'pi' (it is not), the test would find an owner instead of failing fast — surface that
#   via the assertion rather than silently passing. The 10s poll deadline bounds any pathology.

# GOTCHA — test (i) must call _transparency_setup_real_env (sets AGENT_BROWSER_REAL) but must NOT
#   call _transparency_spawn_owner. preflight (_pool_preflight_real_bin) runs BEFORE the owner-resolve
#   die; without AGENT_BROWSER_REAL, pool_die would fire a real-bin message, not 'pi ancestor'.

# GOTCHA — shellcheck exit 1 is EXPECTED (pre-existing SC1091 x2). Do not "fix" SC1091 (it is the
#   deliberate `source ./validate.sh`). Assert only: no NEW codes, no SC2154 for ABPOOL_WRAPPER.

# GOTCHA — do NOT re-add ABPOOL_WRAPPER to validate.sh. It is correctly gone (T1.S1). transparency.sh
#   must consume the already-defined $ABPOOL_ADMIN.
```

### Integration Points

```yaml
NONE for this item beyond the single test file.
  - This item CONSUMES (does not modify):
      * test/validate.sh — defines $ABPOOL_ADMIN (L26); ABPOOL_WRAPPER removed (T1.S1). transparency.sh sources it.
      * bin/agent-browser-pool — the sole entry point whose `case` decides --help vs driving routing.
      * lib/pool.sh — pool_wrapper_main (fail-fast), pool_dispatch_classify (meta), pool_admin_help ('agent-browser-pool'), pool_die ('pi ancestor').
  - Downstream consumers that build on this LATER (NOT here):
      * test/concurrency.sh + release_reaper.sh (P2.M5.T3.S1) — comment updates only.
```

---

## Validation Loop

> Per AGENTS.md §1/§6: EVERY command below is STATIC (`bash -n`, `shellcheck`, `grep`, `git`).
> **Do NOT run `bash test/transparency.sh`, do NOT boot Chrome, do NOT invoke
> `agent-browser`/`agent-browser-pool` driving commands during this item.** The static checks are
> authoritative. (An optional isolated-sandbox suite run is Level 3 and is NOT a gate.)

### Level 1: Syntax, lint & content (run after all edits)

```bash
cd /home/dustin/projects/agent-browser-pool
F=test/transparency.sh

# --- syntax (contract step g) ---
bash -n "$F" && echo "OK: bash -n" || echo "FAIL: bash -n"

# --- lint (contract step g): assert NO SC2154 for ABPOOL_WRAPPER + no NEW error/warning ---
shellcheck -s bash "$F" > /tmp/sc_trans_after.txt 2>&1; sc_rc=$?
if grep -qE 'SC2154' /tmp/sc_trans_after.txt && grep -qi 'ABPOOL_WRAPPER' /tmp/sc_trans_after.txt; then
  echo "FAIL: shellcheck flags ABPOOL_WRAPPER as unbound (SC2154 — a $ABPOOL_WRAPPER ref survived)"
else
  echo "OK: no shellcheck SC2154 for ABPOOL_WRAPPER"
fi
newcodes=$(grep -oE 'SC[0-9]+' /tmp/sc_trans_after.txt | sort -u | tr '\n' ' ')
echo "shellcheck codes present: $newcodes"
for c in $newcodes; do
  case "$c" in
    SC1091) : ;;                 # pre-existing info (source ./validate.sh) — expected
    *) echo "FAIL: unexpected NEW shellcheck code $c (review /tmp/sc_trans_after.txt)";;
  esac
done
echo "(if no FAIL above) OK: only the pre-existing SC1091 info remains"

# --- REMOVALS: each grep MUST find ZERO ---
for pat in 'ABPOOL_WRAPPER' 'wrapper' 'test_passthrough_help_version'; do
    n=$(grep -cE "$pat" "$F" || true)
    [ "$n" -eq 0 ] && echo "OK: absent: $pat" || echo "FAIL: found $n x [$pat]"
done

# --- ADDITIONS / PRESERVES: each MUST match ---
grep -c 'ABPOOL_ADMIN' "$F" | grep -qE '[6-9]|[1-9][0-9]' && echo "OK: ABPOOL_ADMIN present (>=6)" || echo "FAIL: ABPOOL_ADMIN count <6"
grep -q 'test_help_shows_pool_help' "$F"  && echo "OK: test_help_shows_pool_help present"  || echo "FAIL: --help test missing"
grep -q 'test_version_passthrough' "$F"    && echo "OK: test_version_passthrough present"  || echo "FAIL: --version test missing"
grep -q 'test_driving_no_pi_ancestor_fails_fast' "$F" && echo "OK: no-pi fail-fast test present" || echo "FAIL: no-pi test missing"
grep -q '*"agent-browser-pool"*' "$F"      && echo "OK: --help asserts pool signature phrase" || echo "FAIL: --help assertion missing"
grep -q 'pi ancestor' "$F"                  && echo "OK: fail-fast 'pi ancestor' assertion present" || echo "FAIL: 'pi ancestor' missing"
grep -q 'test_passthrough_skills' "$F"     && echo "OK: test (a) skills passthrough preserved" || echo "FAIL: test (a) lost"

# --- runner UNCHANGED (auto-discovery intact) ---
grep -q 'compgen -A function | grep '"'"'^test_'"'"' | sort' "$F" && echo "OK: runner auto-discovery intact" || echo "FAIL: runner changed"
```

**Expected**: `bash -n` → OK; shellcheck → only SC1091 infos; `ABPOOL_WRAPPER`/`wrapper`/
`test_passthrough_help_version` → 0 each; `ABPOOL_ADMIN` ≥6; the two split fns + the new fail-fast
test + the pool-signature assertion + 'pi ancestor' all present; test (a) preserved; runner intact.

### Level 2: Component Validation — N/A (static by design)

The test bodies' runtime correctness is enforced by Level 1 (the split/new fns are syntactically
valid + assert the verified routing) + the shipped-behavior anchors in §Documentation. Per AGENTS.md
§1 we do NOT execute the suite. Live exercise is the optional Level-3 check.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Shipped-behavior anchors that justify the assertions (read-only greps — NO binary execution):
grep -q 'pool_die "agent-browser-pool: driving commands require a pi ancestor' lib/pool.sh \
  && echo "OK: pool_wrapper_main fail-fast present (test i is justified)" || echo "FAIL: fail-fast missing in lib"
grep -q "agent-browser-pool — the sole entry point" lib/pool.sh \
  && echo "OK: pool_admin_help emits 'agent-browser-pool' (test b1 is justified)" || echo "FAIL: help text changed"
grep -q -- '--help|-h|help)' bin/agent-browser-pool \
  && echo "OK: bin dispatch has a --help|-h|help arm (test b1 routing is correct)" || echo "FAIL: bin --help arm missing"

# validate.sh contract (T1.S1) intact (read-only):
grep -q 'ABPOOL_ADMIN="\$ABPOOL_REPO/bin/agent-browser-pool"' test/validate.sh && echo "OK: ABPOOL_ADMIN defined" || echo "FAIL: ABPOOL_ADMIN def lost"
grep -q 'ABPOOL_WRAPPER' test/validate.sh && echo "FAIL: validate.sh still has ABPOOL_WRAPPER (would re-break)" || echo "OK: validate.sh has no ABPOOL_WRAPPER"

# Scope: NO file OUTSIDE test/transparency.sh was modified by THIS item.
git status --short
git status --short | grep -vE '^.{2} test/transparency\.sh$' | grep . \
  && echo "FAIL: changes outside test/transparency.sh" || echo "OK: only test/transparency.sh modified"

# Confirm siblings/SHIPPED files untouched:
for f in test/validate.sh test/concurrency.sh test/release_reaper.sh lib/pool.sh bin/agent-browser-pool \
         install.sh README.md PRD.md .gitignore; do
  git diff --name-only | grep -qx "$f" && echo "FAIL: $f modified by this item" || echo "OK: $f untouched"
done

# OPTIONAL (NOT a gate; ONLY in a fully isolated container/bwrap/temp-tree per AGENTS.md §1/§3):
#   running the suite confirms the 9 bodies (a, b1, b2, c-h, i) pass against live Chrome. It boots
#   real headless Chrome + spawns sim-owners (single setup) → NEVER run it in the shared sandbox.
#   If run isolated: 'AGENT_CHROME_HEADLESS=1 timeout 180 bash test/transparency.sh; echo rc=$?' —
#   expect rc 0. The static Level-1 checks are authoritative; this run is extra confidence only.
```

### Level 4: Creative & Domain-Specific Validation — N/A

A test-harness rewrite has no domain runtime beyond Levels 1-3. The one domain-specific check —
that `--help` truly shows pool help and no-pi-ancestor truly fails fast — is pinned by the
shipped-behavior anchors (pool_admin_help first line; pool_wrapper_main:3645 pool_die) verified
live in research, not by executing the binary here (AGENTS.md §1).

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n test/transparency.sh` → exit 0.
- [ ] `shellcheck -s bash test/transparency.sh` → only the pre-existing SC1091 infos; NO SC2154 for
      `ABPOOL_WRAPPER`; no new error/warning codes.
- [ ] `grep -c ABPOOL_WRAPPER` → 0; `grep -c wrapper` → 0; `grep -c test_passthrough_help_version` → 0.
- [ ] Scope: only `test/transparency.sh` modified by this item.

### Feature Validation

- [ ] All driving/meta invocations use `$ABPOOL_ADMIN` (the sole entry point); no `$ABPOOL_WRAPPER`.
- [ ] `test_passthrough_skills` (a) preserved (byte-equal; META passthrough) — var+comment only.
- [ ] `test_passthrough_help_version` REMOVED; `test_help_shows_pool_help` (CONTAINS
      `agent-browser-pool`) + `test_version_passthrough` (byte-equal) added.
- [ ] `test_driving_no_pi_ancestor_fails_fast` added (asserts output contains `pi ancestor`).
- [ ] No comment calls no-pi-ancestor "passthrough" (it is fail-fast). `passthrough` remains ONLY
      for META (skills/--version).
- [ ] Runner `_abpool_run_transparency_suite` UNCHANGED (compgen auto-discovery intact).

### Code Quality / Scope Validation

- [ ] **Only** `test/transparency.sh` is modified by this item.
- [ ] `test/validate.sh`, `test/concurrency.sh`, `test/release_reaper.sh`, `lib/pool.sh`,
      `bin/*`, `install.sh`, all `*.md` untouched.
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no daemons, no suite run) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] No external doc files change (the contract's DOCS note). Internal test comments are
      updated inline (header list, GOTCHA block, every `wrapper` comment → explicit-invocation vocab).
- [ ] The transparency suite asserts the ACTUAL shipped routing (`--help`→pool help,
      `--version`/`skills`→meta passthrough, no-pi→fail-fast, driving→lane) per PRD §2.4/§2.15/§2.17.

---

## Anti-Patterns to Avoid

- ❌ Don't byte-compare `--help` to the real binary — `--help` is intercepted by the bin `case`
      (`--help|-h|help) → pool_admin_help`) and shows POOL help, not real-binary help. Assert CONTAINS
      `agent-browser-pool` instead. (Only `--version`/`skills` still byte-compare.)
- ❌ Don't leave any `passthrough` assertion/comment for no-pi-ancestor — it is fail-fast now
      (pool_die, exit 1, `pi ancestor`). Only META (skills/--version) passes through.
- ❌ Don't re-add `ABPOOL_WRAPPER` to validate.sh to "fix" transparency.sh — it is correctly gone
      (T1.S1). Switch transparency.sh to the already-defined `$ABPOOL_ADMIN`.
- ❌ Don't test no-pi-ancestor with a plain `$ABPOOL_ADMIN open` child — if this suite runs under
      `pi`, the child's ppid chain includes pi → finds an owner → does NOT fail fast → flaky. Detach
      via `setsid` + `env -u AGENT_BROWSER_POOL_OWNER_PID` (E5).
- ❌ Don't call `_transparency_spawn_owner` in test (i) — you WANT no owner. But DO call
      `_transparency_setup_real_env` (sets `AGENT_BROWSER_REAL`) so `_pool_preflight_real_bin` passes
      before the owner-resolve die (else pool_die fires a real-bin message, not `pi ancestor`).
- ❌ Don't touch the runner `_abpool_run_transparency_suite` to register the split/new tests — it
      auto-discovers `^test_` via `compgen`. Adding/splitting fns needs zero runner change.
- ❌ Don't treat `shellcheck` exit 1 as failure — it's 1 TODAY (pre-existing SC1091 infos from
      `source ./validate.sh`). The gate is "no SC2154 for ABPOOL_WRAPPER + no new error/warning codes".
- ❌ Don't run `bash test/transparency.sh` as a gate or in the shared sandbox — it boots real Chrome +
      spawns sim-owners (sandbox-wedge risk, AGENTS.md §1/§3/§4). Static checks suffice; the suite is
      optional in a fully isolated container only.
- ❌ Don't edit `test/validate.sh` / `concurrency.sh` / `release_reaper.sh` / `lib/pool.sh` / `bin/*`
      here — each is owned by T1.S1 / T3.S1 / completed P2.M1–M2. This item touches ONLY transparency.sh.
- ❌ Don't leave ANY `wrapper` substring — `grep -c wrapper` must be 0 (apply every row in the
      Comment Rewrite Table). `pool_wrapper_main` is NOT in transparency.sh (it's in validate.sh/lib),
      so there are no legitimate `wrapper` keeps here.

---

## Confidence Score

**9/10** — one-pass success likelihood. The item edits ONE bash test harness, and the PRP supplies
the 4 semantic edits (E1–E4) **verbatim** (exact old→new, copy-pasteable), the new fail-fast test
(E5) verbatim, a safe one-shot variable rename (5 sites, grep-verified), and an explicit old→new
fragment table for every remaining `wrapper` comment. The decisive non-obvious facts — WHY `--help`
is no longer passthrough (bin `case` intercepts it before `pool_wrapper_main`) and HOW to
deterministically test no-pi-ancestor despite the suite possibly running under `pi` (setsid-detach
+ `env -u` + temp-file poll) — are explained in §Known Gotchas, §Documentation, and §Anti-Patterns
(three reinforcements) and pinned to verified LIVE anchors (bin dispatch read verbatim;
pool_wrapper_main:3645 pool_die; pool_admin_help first line; validate.sh ABPOOL_ADMIN@L26 /
ABPOOL_WRAPPER=0). Validation is entirely static (`bash -n` + `shellcheck` + `grep` + `git`) and
CANNOT wedge the sandbox (AGENTS.md §1); shellcheck SC2154 specifically catches any surviving
`$ABPOOL_WRAPPER` reference. Not 10/10 only because: (a) the new test (i)'s determinism depends on
`setsid` reparenting the child to a non-`pi` subreaper (reliable on Linux, but an unusual
sandbox could in theory differ — the bounded poll + assertion surface any such pathology rather
than silently passing); (b) the ~16-row comment table is mechanical but voluminous, so a single
missed row would leave one `wrapper` hit (the Level-1 `grep -c wrapper → 0` gate catches it and
names the fix); (c) exact `# ===` separator dash-counts when inserting E5 are left to the editor's
match (mitigated by anchoring on the unique runner-comment line). All three are fully addressed by
the validation gates.
