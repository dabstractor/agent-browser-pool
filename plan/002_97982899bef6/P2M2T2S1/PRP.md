# PRP — P2.M2.T2.S1: Delete `bin/agent-browser` and update `bin/.gitkeep`

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M2.T2.S1 (0.5 points)
**Dependency / starting state**: Builds on the POST-P2.M1 tree (milestone P2.M1 complete: DISABLE
removed, no-pi-ancestor fail-fast, `_pool_preflight_real_bin` in place). The sibling item
**P2.M2.T1.S1** is rewiring `bin/agent-browser-pool`'s `*)` arm in PARALLEL — this item's only touch
on `bin/agent-browser-pool` is a read-only existence/syntax check, so the two items are **file-
disjoint and compose in either order**. This item deletes ONE git-tracked file: `bin/agent-browser`
(the old PATH-shadowing shim), and keeps `bin/.gitkeep`.
**Full research notes**: `plan/002_97982899bef6/P2M2T2S1/research/notes.md`

---

## Goal

**Feature Goal**: Remove the obsolete `bin/agent-browser` PATH-shadowing shim from the repository so
that the REAL `~/.local/bin/agent-browser` (the Vercel CLI) is **unshadowed** and `bin/agent-browser-pool`
is the **sole** pool entry point — matching PRD §2.1 (h3.5), §2.17 (h3.21, "no PATH shadowing"), and
§3 (h2.2, repository layout lists only `bin/agent-browser-pool`).

**Deliverable**: A one-file repo change — `git rm bin/agent-browser` — after which: (a) the file no
longer exists in the working tree or git index; (b) `bin/.gitkeep` is untouched (still present, still
empty); (c) `bin/agent-browser-pool` is verified to still exist, be executable, and pass `bash -n`;
(d) `git ls-files bin/` shows only `bin/.gitkeep` + `bin/agent-browser-pool`. **No other file is
modified** — every remaining reference to the shim is owned by a downstream item (mapped in §Known
Gotchas) and is intentionally left untouched.

**Success Definition**:
- `test ! -e bin/agent-browser` → true (file gone).
- `test -x bin/agent-browser-pool` → true (sole entry point intact + executable).
- `bash -n bin/agent-browser-pool` → exit 0 (still valid; unaffected by this item or the parallel
  `*)` rewiring).
- `test -f bin/.gitkeep` → true (kept, still 0 bytes).
- `git ls-files bin/` → exactly two lines: `bin/.gitkeep` and `bin/agent-browser-pool`.
- `git status --short -- bin/` → shows the staged deletion of `bin/agent-browser` and NOTHING else
  under `bin/` (no stray edits to `.gitkeep` or `agent-browser-pool` from this item).

---

## Why

- **Business value / PRD alignment**: PRD §2.1 establishes that `~/.local/bin/agent-browser` is "the
  REAL Vercel CLI — hard runtime dependency (unchanged, upgradable)" and `~/.local/bin/agent-browser-pool`
  is the "SOLE entry point". PRD §2.17 states plainly: "**There is no PATH shadowing** — the real
  `agent-browser` is never intercepted." The shim was the interception mechanism of the old model; it
  has no role in the new explicit-invocation model (driving commands route through `agent-browser-pool`
  directly after P2.M2.T1.S1). PRD §3's repository layout lists ONLY `bin/agent-browser-pool` under
  `bin/` — deletion is the documented end state.
- **Who it helps**: Prevents confusion about which `agent-browser` is being invoked; eliminates the
  silent global-interception footgun; makes the repo's `bin/` match the PRD exactly. Operators and
  agents get one unambiguous entry point; the real CLI is never shadowed by the repo.
- **Scope cohesion**: This is the second item of milestone P2.M2 (Entry Point & Binary Pivot). It is
  the direct successor of P2.M2.T1.S1 (which makes `bin/agent-browser-pool` the sole dispatcher). It
  is the prerequisite for P2.M3.T1.S1 (install.sh rewrite — the new installer has nothing to symlink
  for the shim). It touches ONLY `bin/agent-browser` (a deletion); `lib/pool.sh`, `install.sh`,
  `README.md`, `SKILL.md`, `references/*`, and `test/*` are all untouched here and are owned by
  P2.M1(done)/P2.M3/P2.M4/P2.M5/P2.M6.

---

## What

**User-visible behavior**: None at runtime — this is a source-tree deletion. The change is visible
only in the repo: the file `bin/agent-browser` no longer exists. The installed user-facing binaries
(`~/.local/bin/agent-browser` = real CLI, `~/.local/bin/agent-browser-pool` = pool entry point) are
NOT in the repo's control for this item and are NOT touched (AGENTS.md §1/§5).

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `bin/.gitkeep` — stays (empty, 0 bytes).
- `bin/agent-browser-pool` — stays (only READ for validation: exists/executable/`bash -n`).
- `lib/pool.sh` — stays (stale COMMENTS at lines 7, 96, 3564 mention the shim; they are harmless doc
  cruft, explicitly out of scope per item step c — "No code changes needed in pool.sh").
- `install.sh` — stays (OLD cutover installer; ~20 refs to the shim; COMPLETELY rewritten by
  P2.M3.T1.S1). Not run here.
- `test/validate.sh`, `test/transparency.sh`, `test/concurrency.sh`, `test/release_reaper.sh` — stay
  (reference the shim via `ABPOOL_WRAPPER`; rewritten/updated by P2.M5). NOT run here (AGENTS.md §1).
- `README.md` — stays (rewritten by P2.M6.T1.S1).
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.

### Success Criteria

- [ ] `bin/agent-browser` is deleted (`git rm`).
- [ ] `bin/.gitkeep` is present and unchanged (still 0 bytes).
- [ ] `bin/agent-browser-pool` still exists, is executable, and passes `bash -n`.
- [ ] `git ls-files bin/` shows exactly `bin/.gitkeep` + `bin/agent-browser-pool`.
- [ ] No file OTHER than `bin/agent-browser` is modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the exact file to delete (13 lines, reproduced verbatim), its git-tracking
status, the exact deletion command (`git rm`), the exact verification commands, and a complete map of
every remaining reference to the shim (each tagged with its downstream owner and an explicit "do NOT
touch" instruction) are all specified below. No ambiguity about scope.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: bin/agent-browser   (13 lines / 675 bytes — the ONLY file deleted; verbatim in notes.md §1)
  why: The obsolete PATH-shadowing shim. Deletion target. `git ls-files bin/` confirms it is tracked.
  pattern: "sources lib/pool.sh + `pool_wrapper_main \"$@\"` — the exact behavior now reachable
           directly via bin/agent-browser-pool's `*)` arm (P2.M2.T1.S1), making the shim redundant."
  gotcha: "It is git-TRACKED, so use `git rm bin/agent-browser` (not bare `rm`) to stage the deletion
           in one step. A bare `rm` would leave git showing it as ` D` (unstaged) — still deletable via
           `git add -A bin/`, but `git rm` is the clean canonical op."

- file: bin/.gitkeep   (empty, 0 bytes — UNTOUCHED)
  why: Keeps the bin/ directory tracked. Item step d: "Check if bin/.gitkeep exists (it does) — keep it."
  gotcha: "bin/ stays non-empty after deletion (agent-browser-pool remains), so .gitkeep is technically
           redundant — but the contract says KEEP it. Do NOT delete or modify .gitkeep."

- file: bin/agent-browser-pool   (25 lines — UNTOUCHED by this item; only READ for validation)
  why: The SOLE entry point after deletion. Verified to exist + be executable + pass `bash -n`.
  gotcha: "This file is being edited IN PARALLEL by P2.M2.T1.S1 (the `*)` arm: error →
           `pool_wrapper_main \"$@\"`). Validation must be AGNOSTIC to the `*)` content — assert only
           exists/executable/`bash -n`. `bash -n` passes for BOTH arm forms, so the check is robust."

- prd: PRD.md §2.1 (h3.5) — Components
  why: "~/.local/bin/agent-browser ← the REAL Vercel CLI — hard runtime dependency (unchanged)";
       "~/.local/bin/agent-browser-pool ← SOLE entry point". Source of "unshadowed + sole entry".
  critical: "The repo shim bin/agent-browser is NOT in the component list. Only the real CLI
             (~/.local/bin/agent-browser) and the pool entry (bin/agent-browser-pool) are."

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "There is NO PATH shadowing — the real agent-browser is never intercepted." Confirms the shim's
       interception model is dead.

- prd: PRD.md §3 (h2.2) — Repository layout (planned)
  why: The `bin/` tree lists ONLY `agent-browser-pool` — no `agent-browser`. This deletion makes the
       repo match the planned layout.

- file: plan/002_97982899bef6/architecture/gap_analysis.md  §3
  why: The item's own contract: "bin/agent-browser — DELETE. The old PATH-shadowing shim. In the new
       model, ~/.local/bin/agent-browser is the REAL Vercel CLI (unshadowed). This file is no longer
       needed."

- file: plan/002_97982899bef6/P2M2T1S1/PRP.md   (parallel item — CONTRACT for the entry point)
  why: P2.M2.T1.S1 rewires bin/agent-browser-pool's `*)` arm to `pool_wrapper_main "$@"`. Confirms the
       shim becomes redundant (driving routes through agent-browser-pool directly). DISJOINT from this
       file → composes in either order.

- file: plan/002_97982899bef6/P2M2T2S1/research/notes.md  §3
  why: The complete reference map: every remaining mention of the shim + its downstream owner. Read
       this BEFORE editing to avoid touching another item's files.
```

### Current codebase tree (relevant slice)

```bash
bin/
├── .gitkeep             # empty (0 bytes) — UNTOUCHED
├── agent-browser        # 13 lines / 675 bytes — DELETED by this item (git-tracked)
└── agent-browser-pool   # 25 lines — UNTOUCHED (validated read-only: -x + bash -n)
lib/pool.sh              # ~4626 lines — UNTOUCHED. (stale comments @7,96,3564 are OUT OF SCOPE.)
install.sh               # OLD cutover installer — UNTOUCHED (P2.M3.T1.S1 rewrites it).
README.md                # UNTOUCHED (P2.M6.T1.S1 rewrites it).
test/{validate,transparency,concurrency,release_reaper}.sh  # UNTOUCHED (P2.M5). NOT run here.
PRD.md                   # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
bin/
├── .gitkeep             # unchanged (kept)
└── agent-browser-pool   # unchanged (sole entry point; validated read-only)
# bin/agent-browser — REMOVED (git rm). No new files. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (use git rm, not bare rm): bin/agent-browser is git-TRACKED. `git rm bin/agent-browser`
#   removes it from the working tree AND stages the deletion in one step. `git status --short`
#   should then show `D  bin/agent-browser` (staged delete). Do NOT leave an unstaged ` D`.

# CRITICAL (do NOT touch lib/pool.sh): after deletion, THREE COMMENTS in lib/pool.sh become stale —
#     line 7:   "#   - bin/agent-browser       (the transparent PATH-shadowing wrapper shim)"
#     line 96:  "# of bin/agent-browser and bin/agent-browser-pool (and re-callable for tests)."
#     line 3564:"# PRD §2.4 steps 0→5 — the orchestration entry point. Called by bin/agent-browser"
#   Item step c EXPLICITLY says "No code changes needed in pool.sh." These are doc comments, harmless,
#   and NOT owned by this item. LEAVE THEM. Do not "tidy" them (scope violation; lib/pool.sh is owned
#   by P2.M1's region, and no downstream item is assigned to these specific comments).
#   NOTE: lib/pool.sh lines 103 + 152 reference ~/.local/bin/agent-browser (the REAL CLI) — those are
#   CORRECT and must NEVER change; do not conflate them with the repo shim.

# CRITICAL (do NOT touch install.sh / README.md / test/* / references/* / SKILL.md): they all still
#   mention the shim and/or ABPOOL_WRAPPER, but each is owned by a downstream item:
#     install.sh            → P2.M3.T1.S1 (complete rewrite)
#     test/validate.sh      → P2.M5.T1.S1 (remove ABPOOL_WRAPPER + selftest_config_disable)
#     test/transparency.sh  → P2.M5.T2.S1 (rewrite; ABPOOL_WRAPPER → ABPOOL_ADMIN)
#     test/concurrency.sh, test/release_reaper.sh → P2.M5.T3.S1 (comment updates)
#     README.md             → P2.M6.T1.S1 (complete rewrite)
#     SKILL.md, references/configuration.md, skill README.md → P2.M4
#   The git dependency graph orders P2.M5/P2.M6 AFTER P2.M2 → the dangling references are BY DESIGN
#   during this item. Per AGENTS.md §1, do NOT run the test suite, so they cause no harm.

# CRITICAL (do NOT touch the operator's real $HOME): ~/.local/bin/agent-browser is the REAL Vercel CLI
#   (a real binary, NOT a symlink to our repo) — deleting repo bin/agent-browser does NOT affect it
#   (PRD §2.1). A prior OLD-model install may have left ~/scripts/agent-browser → repo bin/agent-browser;
#   that dangling-symlink cleanup is P2.M3's install.sh job, NOT this item. Never touch
#   ~/.local/bin/agent-browser, ~/scripts, ~/.local/state/agent-browser-pool, or running Chrome.

# CRITICAL (validation is agnostic to the parallel rewiring): bin/agent-browser-pool is being edited by
#   P2.M2.T1.S1 in parallel (the `*)` arm). Assert ONLY: file exists + executable + `bash -n` exit 0.
#   Do NOT assert on the `*)` arm's content (error vs dispatch) — that is P2.M2.T1.S1's region and is
#   mid-flight. `bash -n` passes for either form.

# CRITICAL (no runtime validation needed): a file deletion introduces/changes NO runtime behavior, and
#   AGENTS.md §1 forbids running the test suite / booting Chrome / touching the shared sandbox during
#   planning+this change. The ENTIRE validation is static (Level 1). Do not invent a runtime test.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models, no logic. This item is a single `git rm` of one 13-line shim plus static
verification. No code is written.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: DELETE bin/agent-browser  (item steps a–d)
  - RUN:  git rm bin/agent-browser
  - WHY:  PRD §2.1/§2.17/§3 + gap_analysis §3. The old PATH-shadowing shim is obsolete once driving
          routes through bin/agent-browser-pool directly (P2.M2.T1.S1). Removing it unshadows the real
          ~/.local/bin/agent-browser and makes the repo's bin/ match PRD §3.
  - BUCKET: required (the entire deliverable).
  - NOTE: `git rm` both unlinks the file AND stages the deletion. If for any reason `git rm` is
          unavailable, `rm -f bin/agent-browser && git add -A bin/` is equivalent; verify with
          `git status --short -- bin/` (expect a staged `D  bin/agent-browser`).

Task 2: VERIFY the remaining tree (item steps b + e) — STATIC ONLY
  - RUN:  test ! -e bin/agent-browser                && echo "OK: shim deleted"
  - RUN:  test -x bin/agent-browser-pool             && echo "OK: sole entry point executable"
  - RUN:  bash -n bin/agent-browser-pool             && echo "OK: bash -n clean"
  - RUN:  test -f bin/.gitkeep                       && echo "OK: .gitkeep kept"
  - RUN:  test "$(git ls-files bin/ | wc -l)" -eq 2  && echo "OK: exactly 2 files tracked in bin/"
  - RUN:  git ls-files bin/                          # must print only: bin/.gitkeep  bin/agent-browser-pool
  - WHY:  item step b (agent-browser-pool still exists/executable) + step d (.gitkeep kept) + step e
          (bash -n on the remaining binary). All static — no execution, no Chrome (AGENTS.md §1).
  - BUCKET: required.
```

### Implementation Patterns & Key Details

```bash
# Task 1 — the canonical, single-command deletion:
git rm bin/agent-browser

# Task 2 — verification (run from the repo root, all must print OK):
test ! -e bin/agent-browser               || { echo "FAIL: shim still present"; exit 1; }
test -x   bin/agent-browser-pool          || { echo "FAIL: entry point not executable"; exit 1; }
bash -n   bin/agent-browser-pool          || { echo "FAIL: bash -n on entry point"; exit 1; }
test -f   bin/.gitkeep                    || { echo "FAIL: .gitkeep missing"; exit 1; }
test "$(git ls-files bin/ | wc -l)" -eq 2 || { echo "FAIL: wrong file count in bin/"; exit 1; }
git ls-files bin/ | grep -qx 'bin/agent-browser' \
  && { echo "FAIL: bin/agent-browser still tracked"; exit 1; } || echo "OK: shim untracked"

# Expected after Task 1+2:
#   bin/ contains exactly: .gitkeep (0 bytes), agent-browser-pool (executable).
#   git ls-files bin/ prints exactly two lines: bin/.gitkeep, bin/agent-browser-pool.
#   git status --short shows the deletion staged.

# DO NOT (scope violations):
#   - edit lib/pool.sh (stale comments @7,96,3564 are OUT OF SCOPE; item step c says no pool.sh change).
#   - edit install.sh / README.md / SKILL.md / references/* / test/* (owned by P2.M3/P2.M4/P2.M5/P2.M6).
#   - delete or modify bin/.gitkeep (item step d says keep it).
#   - touch the operator's real $HOME (~/scripts, ~/.local/bin/agent-browser, state dir) — AGENTS.md §1/§5.
#   - run test/validate.sh, test/transparency.sh, install.sh, or any agent-browser / Chrome command.
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no env vars, no routes, no new code.
  - The ONLY integration surface is the repo file tree (one file removed).
  - Downstream consumers that build on this LATER (NOT here):
      * install.sh rewrite                     (P2.M3.T1.S1 — no shim to symlink; also cleans ~/scripts)
      * SKILL.md / references/configuration.md / skill README.md rewrites   (P2.M4)
      * test/validate.sh + test/transparency.sh + concurrency/release_reaper (P2.M5 — remove ABPOOL_WRAPPER
        refs to the now-deleted shim, in an isolated sandbox)
      * README.md rewrite                      (P2.M6.T1.S1)
```

---

## Validation Loop

> Per AGENTS.md §1/§2/§3: EVERY command below is STATIC (`git`, `test`, `bash -n`, `grep`). No Chrome,
> no daemon, no real `agent-browser`, no test suite, no shared-`$HOME` writes. A file deletion has no
> runtime behavior, so Levels 2-4 (component / integration / domain) are N/A by design.

### Level 1: Syntax & Style + tree integrity (run after the deletion)

```bash
cd /home/dustin/projects/agent-browser-pool

# 1. The deletion
git rm bin/agent-browser

# 2. File-level assertions
test ! -e bin/agent-browser            && echo "OK: shim file removed"          || echo "FAIL: shim still in working tree"
test -x   bin/agent-browser-pool       && echo "OK: agent-browser-pool executable" || echo "FAIL: entry point missing/non-exec"
bash -n   bin/agent-browser-pool       && echo "OK: bash -n clean"              || echo "FAIL: bash -n on entry point"
test -f   bin/.gitkeep                 && echo "OK: .gitkeep kept"              || echo "FAIL: .gitkeep missing"
test ! -s bin/.gitkeep                 && echo "OK: .gitkeep still empty"       || echo "FAIL: .gitkeep unexpectedly non-empty"

# 3. Git-index assertions
git ls-files bin/ | sort > /tmp/binfiles.txt
# Expect exactly two lines: bin/.gitkeep and bin/agent-browser-pool
test "$(wc -l < /tmp/binfiles.txt)" -eq 2 && echo "OK: exactly 2 tracked files in bin/" || echo "FAIL: wrong count"
grep -qx 'bin/agent-browser'      /tmp/binfiles.txt && echo "FAIL: shim still tracked" || echo "OK: shim untracked"
grep -qx 'bin/.gitkeep'           /tmp/binfiles.txt && echo "OK: .gitkeep tracked"     || echo "FAIL: .gitkeep lost"
grep -qx 'bin/agent-browser-pool' /tmp/binfiles.txt && echo "OK: pool entry tracked"   || echo "FAIL: pool entry lost"
rm -f /tmp/binfiles.txt

# 4. Scope integrity — ONLY bin/agent-browser is changed by this item (nothing else under bin/)
git status --short -- bin/
# Expect a single staged line: "D  bin/agent-browser" (and nothing else under bin/).

# Optional whole-repo scope check (catch accidental stray edits):
git diff --cached --name-only --diff-filter=ACMR | grep -v '^bin/agent-browser-pool$' \
  | grep -q . && echo "FAIL: unexpected staged changes" || echo "OK: no unexpected staged changes (besides the delete)"
# (The deletion itself shows under --diff-filter=D; confirm ONLY that path was deleted:)
test "$(git diff --cached --name-only --diff-filter=D | tr '\n' ' ')" = "bin/agent-browser " \
  && echo "OK: only bin/agent-browser deleted" || echo "FAIL: unexpected deletion"

# Expect: every assertion prints OK:. `bash -n` exit 0. git status shows exactly the staged deletion.
```

### Level 2: Component Validation — N/A

No runtime behavior is introduced or changed by deleting a source file. The remaining binary's
correctness (dispatch routing) is P2.M2.T1.S1's responsibility and is validated by P2.M5's
`test/transparency.sh` + `test/concurrency.sh` in an isolated sandbox — NOT by this item.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Confirm the shim is gone from the working tree + git index (redundant with Level 1, explicit):
git ls-files bin/ | grep -q 'agent-browser$' && echo "FAIL: shim still tracked" || echo "OK: shim gone from index"

# Confirm lib/pool.sh was NOT edited by this item (its stale comments are out of scope):
git diff --cached --name-only | grep -q '^lib/pool.sh$' \
  && echo "FAIL: lib/pool.sh unexpectedly modified by this item" || echo "OK: lib/pool.sh untouched"

# Confirm the parallel-item region (bin/agent-browser-pool dispatch) is untouched BY THIS ITEM
# (P2.M2.T1.S1 may have edited it in parallel — that is fine; THIS item must not):
git diff --cached --name-only | grep -q '^bin/agent-browser-pool$' \
  && echo "NOTE: bin/agent-browser-pool has staged changes (from P2.M2.T1.S1, not this item — OK)" \
  || echo "OK: bin/agent-browser-pool untouched by this item"

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser / Chrome command.
```

### Level 4: Creative & Domain-Specific Validation

N/A — a file deletion has no domain-specific runtime to validate. The repo state is fully pinned by
Level 1-3 static checks + the item contract + PRD §2.1/§2.17/§3.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: every assertion prints `OK:`; `bash -n bin/agent-browser-pool` exits 0.
- [ ] `git ls-files bin/` prints exactly `bin/.gitkeep` + `bin/agent-browser-pool`.
- [ ] `git status --short -- bin/` shows only the staged deletion of `bin/agent-browser`.

### Feature Validation

- [ ] `bin/agent-browser` is deleted (Task 1).
- [ ] `bin/agent-browser-pool` exists, is executable, and passes `bash -n` (Task 2).
- [ ] `bin/.gitkeep` is present and still empty (kept per item step d).
- [ ] PRD §3 repository layout now matches the repo's `bin/` (only `agent-browser-pool`).

### Code Quality / Scope Validation

- [ ] **Only** `bin/agent-browser` is deleted; **no** other file is modified by this item.
- [ ] `lib/pool.sh` untouched (stale comments @7,96,3564 left in place — out of scope).
- [ ] `install.sh`, `README.md`, `SKILL.md`, `references/*`, `test/*` all untouched (owned by
      P2.M3/P2.M4/P2.M5/P2.M6).
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Operator's real `$HOME` (`~/.local/bin/agent-browser`, `~/scripts`, state dir) untouched.
- [ ] Validation used ONLY static commands (no Chrome, no test suite, no shared-sandbox writes).

### Documentation & Deployment

- [ ] [Mode A] No doc file changes in THIS item. The downstream doc/test/install updates
      (P2.M3/P2.M4/P2.M5/P2.M6) will reflect the deletion. (No stale comment in `lib/pool.sh` is fixed
      here — it is harmless and out of scope per item step c.)

---

## Anti-Patterns to Avoid

- ❌ Don't use bare `rm bin/agent-browser` and forget to stage it — use `git rm bin/agent-browser`
      (or follow with `git add -A bin/`) so the deletion is tracked, not left as an unstaged ` D`.
- ❌ Don't "tidy" the stale comments in `lib/pool.sh` (lines 7, 96, 3564) — item step c explicitly
      says "No code changes needed in pool.sh." They are harmless doc cruft and not this item's scope.
- ❌ Don't touch `install.sh`, `README.md`, `SKILL.md`, `references/*`, or `test/*` — every remaining
      reference to the shim is owned by a downstream item (P2.M3/P2.M4/P2.M5/P2.M6). The dangling refs
      are by design until then.
- ❌ Don't conflate `~/.local/bin/agent-browser` (the REAL CLI, lib/pool.sh:103/152) with the repo
      shim `bin/agent-browser` — they are different paths; only the latter is deleted.
- ❌ Don't delete or modify `bin/.gitkeep` — item step d says keep it.
- ❌ Don't run the test suite, `install.sh`, or any `agent-browser`/Chrome command during this item —
      AGENTS.md §1. All validation is static (Level 1).
- ❌ Don't assert on the `*)` arm content of `bin/agent-browser-pool` (error vs dispatch) — that region
      is owned by the parallel P2.M2.T1.S1. Assert only exists/executable/`bash -n`.

---

## Confidence Score

**10/10** — one-pass success likelihood. This is a single deterministic `git rm` of one git-tracked
13-line file, fully identified verbatim, with git-tracking confirmed host-side. Every remaining
reference to the shim is mapped to its downstream owner with an explicit "do NOT touch" instruction,
so scope creep is prevented. Validation is entirely static (Level 1) and cannot wedge the sandbox
(AGENTS.md §1). The only realistic failure mode — an implementer over-editing `lib/pool.sh` comments
or fixing `install.sh`/`test/*` — is called out loudly as out of scope. No residual risk.
