# PRP — P2.M3.T1.S1: Complete rewrite of `install.sh` — no PATH shadowing, no cutover

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M3.T1.S1 (2 points)
**Dependency / starting state**: Builds on the POST-P2.M2 tree. The sibling item **P2.M2.T2.S1**
is deleting `bin/agent-browser` IN PARALLEL — by the time this item runs, the OLD PATH-shadowing
shim is GONE, and `bin/agent-browser-pool` is the **sole entry point** (its `*)` arm already
dispatches driving commands to `pool_wrapper_main`, per the completed P2.M2.T1.S1). `lib/pool.sh`
is the POST-P2.M1 version (DISABLE removed, no-pi-ancestor fail-fast, `_pool_preflight_real_bin`
present). **This item rewrites exactly ONE file: `install.sh`** (repo root), in place.
**Full research notes**: `plan/002_97982899bef6/P2M3T1S1/research/notes.md`

---

## Goal

**Feature Goal**: Replace the current 221-line cutover installer (`install.sh`) with a clean
~85-line benign installer that does exactly the **three** things PRD §2.17 prescribes —
(1) symlink `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool` (the sole entry point),
(2) pre-create the pool state dir (`lanes/` + `acquire.lock`), (3) run `doctor` — and **nothing
else**: no `~/scripts` symlink, no PATH-ordering check, no cutover warning, no YES confirmation
gate, no `AGENT_BROWSER_POOL_DISABLE` references. Installing the pool can no longer disrupt
running agents, because the real `agent-browser` is never intercepted.

> **Line-count note**: the gap_analysis estimated "~50-70 lines" for the *logic*. The validated
> final artifact is **87 lines** (`wc -l`) — ~30 statements of logic + the **required Mode-A
> user-facing output** (the `--help` heredoc and the success message that, per PRD §2.15, *IS* the
> install documentation). This is a 60% reduction from the 221-line original and well within the
> spirit of the target. **Accept any count in the ~80-95 band; do not pad or strip the Mode-A
> documentation to hit 70.** (Verified: `wc -l install.sh` = 87 for the verbatim block below.)

**Deliverable**: A rewritten `install.sh` (repo root) that: resolves `REPO_DIR` via
`readlink -f`; validates the two repo files it depends on (`bin/agent-browser-pool` + `lib/pool.sh`,
**not** the deleted shim); sources `lib/pool.sh` + calls `pool_config_init`; creates the one
entry-point symlink (idempotent `ln -sfnv`); calls `pool_state_init`; runs
`$REPO_DIR/bin/agent-browser-pool doctor` as a subprocess; prints a simple success message
(Mode A: the install documentation) covering symlink / doctor status / usage / uninstall;
accepts `--force|-f` (backward-compat no-op) and `--help|-h`; passes `bash -n` + `shellcheck -s
bash` cleanly (exit 0). **No other file is modified.**

**Success Definition**:
- `install.sh` exists, is executable, passes `bash -n install.sh` (exit 0), and passes
  `shellcheck -s bash install.sh` (exit 0). *(The verbatim artifact below achieves this via a
  `# shellcheck disable=SC1091` directive on the dynamic `source` line — see Known Gotchas.)*
- `grep` confirms the **OLD MECHANISMS** are gone: zero matches for `AGENT_BROWSER_POOL_DISABLE`,
  `HOME/scripts` (the `~/scripts` dir), `Type YES`, `command -v agent-browser`, `_path_parts`
  (the PATH-ordering primitive), and `^warn()` (the old stderr helper).
- The words `shadow`/`cutover` **may legitimately appear** in the new script's *negation*
  comments ("NO PATH shadowing", "NO cutover") — this is intended documentation, NOT a regression.
- `grep` confirms the ADDITIONS: it sources `lib/pool.sh`, calls `pool_config_init` AND
  `pool_state_init`, runs `bin/agent-browser-pool doctor`, creates exactly the one symlink
  (`ln -sfnv .../bin/agent-browser-pool .../agent-browser-pool`), accepts `--force|-f` + `--help|-h`,
  and documents uninstall.
- `install.sh` never references `bin/agent-browser` (the deleted shim).
- **Only** `install.sh` is modified by this item (`git status --short` shows one path).

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21) states plainly: "There is **no PATH shadowing** — the
  real `agent-browser` is never intercepted, so installing the pool cannot disrupt running agents
  or other `agent-browser` users." It then enumerates the three benign things install does and
  explicitly calls out what is **Removed**: "`AGENT_BROWSER_POOL_DISABLE` ... and the
  `~/scripts`-ahead-of-`~/.local/bin` PATH requirement." PRD §2.1 (h3.5) fixes the component
  model: `~/.local/bin/agent-browser-pool` is the "SOLE entry point"; the real CLI is unshadowed.
  The current install.sh is the entire interception mechanism of the dead old model — it must go.
- **Who it helps**: Operators and agents get a trivially safe install (no global PATH side
  effects, no disruption of in-flight work). Coexistence with the old manual workflow becomes
  per-call and automatic (agents still on the old workflow simply don't invoke
  `agent-browser-pool` yet). Reduced installer surface = fewer footguns.
- **Scope cohesion**: This is item T1 of milestone P2.M3 (Install Script Rewrite). It is the
  direct successor of P2.M2 (which deleted the shim + made `agent-browser-pool` the sole
  dispatcher). It is the prerequisite for P2.M6.T1.S1 (README rewrite — the README's install
  section will describe this new installer). It touches ONLY `install.sh`; `lib/pool.sh`,
  `bin/*`, `README.md`, `SKILL.md`, `references/*`, `test/*` are all untouched here and owned by
  P2.M1(done)/P2.M2/P2.M4/P2.M5/P2.M6.

---

## What

**User-visible behavior**: Running `./install.sh` prints (at most) the one `ln -sfnv` line, the
full `doctor` report, and a short success summary — then exits 0. It creates/refreshes exactly
one symlink (`~/.local/bin/agent-browser-pool`) and pre-creates the pool state dir. It never
touches `~/scripts`, never checks PATH ordering, and never asks for confirmation. `--force`/`-f`
is accepted and does nothing (no confirmation to skip). `--help`/`-h` prints the benign-model
usage and exits 0.

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `bin/agent-browser-pool` — stays (only READ: pre-flight `-x` + doctor subprocess target).
- `lib/pool.sh` — stays (SOURCED + 3 functions CALLED; stale comments @4/@7 mention the deleted
  shim — harmless doc cruft, out of scope per the function-reuse map; do NOT tidy).
- `bin/agent-browser` — assumed already DELETED by P2.M2.T2.S1; install.sh never references it.
- `README.md`, `SKILL.md`, `references/*`, `test/*` — stay (owned by P2.M4/P2.M5/P2.M6).
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.
- Operator's real `$HOME` (`~/.local/bin/agent-browser`, state dir, running Chrome) — NOT run
  during this item (AGENTS.md §1); the script *describes* creating a symlink + state dir but we
  do not execute it here.

### Success Criteria

- [ ] `install.sh` is rewritten in place; `wc -l` ~80-95 (~87 expected).
- [ ] `bash -n install.sh` exits 0.
- [ ] `shellcheck -s bash install.sh` exits 0.
- [ ] No occurrence of the OLD mechanisms: `AGENT_BROWSER_POOL_DISABLE`, `~/scripts`/`$HOME/scripts`,
      `Type YES`, `command -v agent-browser`, `_path_parts`, `^warn()`.
- [ ] `install.sh` never references `bin/agent-browser` (the deleted shim).
- [ ] `install.sh` sources `lib/pool.sh`, calls `pool_config_init` + `pool_state_init`, runs
      `$REPO_DIR/bin/agent-browser-pool doctor`, and creates exactly the one entry-point symlink.
- [ ] `install.sh` accepts `--force|-f` (no-op) and `--help|-h`.
- [ ] Only `install.sh` is modified by this item.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?_ **Yes** — the EXACT final `install.sh` is provided verbatim in §Implementation
Blueprint (it is a complete rewrite, so the artifact itself is the spec), plus: the precise
functions it calls (with line anchors + return-code semantics), the exact static-validation
commands (verified present + verified CLEAN on the host), the exact grep assertions (removals +
additions, with the "negation comment" caveat), the design decisions (D1-D6) that resolve every
ambiguity, and the full scope map. No guessing. (The verbatim artifact was validated end-to-end:
`bash -n` exit 0, `shellcheck -s bash` exit 0, all removal/addition greps pass.)

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §4
  why: "install.sh — COMPLETE REWRITE. Current (221 lines): Cutover installer with PATH
        shadowing. New (~50-70 lines): Three benign things: 1. ln -sfnv .../bin/agent-browser-pool
        ~/.local/bin/agent-browser-pool; 2. Pre-create state dir via pool_state_init; 3. Run
        doctor. No cutover warning, no ~/scripts, no PATH-ordering verification, no confirmation
        gate, no AGENT_BROWSER_POOL_DISABLE references."
  critical: "This IS the item's contract. The verbatim script in this PRP implements it exactly
        (87 lines incl. required Mode-A documentation; see the line-count note in Goal)."

- file: plan/002_97982899bef6/architecture/external_deps.md   (§install.sh Dependency Changes)
  why: "The old install.sh required ~/scripts to precede ~/.local/bin on $PATH. REMOVED. The new
        install.sh only needs: $HOME/.local/bin (created if missing), ln (coreutils), repo files
        bin/agent-browser-pool + lib/pool.sh to exist + be executable."

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "install.sh does three benign things ... Removed: AGENT_BROWSER_POOL_DISABLE ... and the
        ~/scripts-ahead-of-~/.local/bin PATH requirement." Source of the 3-things contract.
  critical: "Lane selection is by caller identity (never a PATH interception) → coexistence is
        per-call. Installing cannot disrupt running agents."

- prd: PRD.md §2.1 (h3.5) — Components
  why: "~/.local/bin/agent-browser-pool ← SOLE entry point (symlink → repo bin/)". Confirms the
        ONE symlink target + name.

- prd: PRD.md §2.16 (h3.20) — Dependencies
  why: "agent-browser ≥ 0.28 — enforced by doctor's [binary] check (run by install.sh)." Confirms
        install just RUNS doctor (it does not reimplement dependency checks).

- file: install.sh   (CURRENT 221-line cutover installer — the file being replaced)
  why: Read it to understand exactly what is being removed (cutover warning, YES gate, ~/scripts
        symlink, PATH-ordering block, DISABLE refs). See research notes §1 for a line-by-line map.
  pattern: "KEEP: set -euo pipefail, REPO_DIR=readlink -f pattern, the --force/--help arg loop,
           source lib/pool.sh + pool_config_init, pool_state_init, the doctor subprocess guard."
  gotcha: "Do NOT carry over the warn() helper, the cutover block, the confirmation gate, the
           bin/agent-browser check, the ~/scripts mkdir/symlink, or the PATH-ordering block."

- file: bin/agent-browser-pool   (25 lines — READ only; the sole entry point + doctor target)
  why: "Confirms `doctor` is reachable as `$REPO_DIR/bin/agent-browser-pool doctor` (case arm →
        pool_admin_doctor), and that the binary already self-inits config+state. So install's
        doctor call is a self-contained subprocess."

- file: lib/pool.sh   (SOURCED + 3 functions CALLED — UNTOUCHED)
  why: "pool_config_init (line 131): validates $HOME, freezes all POOL_* globals incl.
        POOL_STATE_DIR/POOL_LANES_DIR/POOL_LOCK_FILE; returns 0, pool_die on misconfig.
        pool_state_init (line 209): mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE; idempotent;
        returns 0, pool_die on real FS failure. pool_admin_doctor (line 4330): invoked via the
        subprocess; calls config+state init itself; returns 0 healthy / 1 problems; prints the
        full report to stdout."
  critical: "lib/pool.sh is SAFE TO SOURCE: the ONLY top-level executable statement in the whole
             file is `set -euo pipefail` (line 18); everything else is comments + function defs.
             No side effect fires on `source`. pool_config_init is idempotent; calling it in
             install.sh AND again inside the doctor subprocess is harmless."

- file: plan/002_97982899bef6/P2M2T2S1/PRP.md   (parallel sibling — CONTRACT for the deleted shim)
  why: "Confirms bin/agent-browser is DELETED by the time this item runs → install.sh must NOT
        check for it or symlink it. DISJOINT files → composes in either order."
```

### Current codebase tree (relevant slice)

```bash
install.sh               # 221 lines — OLD cutover installer (REWRITTEN IN PLACE by this item)
bin/
├── .gitkeep             # UNTOUCHED
├── agent-browser        # (being DELETED by parallel P2.M2.T2.S1 — assume gone; never referenced)
└── agent-browser-pool   # 25 lines — UNTOUCHED (sole entry point; READ only: -x + doctor target)
lib/pool.sh              # ~4626 lines — UNTOUCHED (SOURCED + 3 funcs called; stale comments out of scope)
README.md                # UNTOUCHED (P2.M6.T1.S1)
test/*                   # UNTOUCHED (P2.M5). NOT run here (AGENTS.md §1).
PRD.md                   # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
install.sh               # REWRITTEN (~87 lines): 3 benign things — symlink, state init, doctor.
# No new files. No deletions (the shim deletion is P2.M2.T2.S1's job). No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (shellcheck SC1091 on the dynamic source line): `source "$REPO_DIR/lib/pool.sh"` uses
#   a runtime-resolved path, so `shellcheck -s bash install.sh` emits SC1091 (info) — and
#   shellcheck EXITS 1 on it (verified: the CURRENT repo install.sh has this same SC1091 + exit 1).
#   FIX (and an improvement over the current installer): put TWO directives on the lines above the
#   source, exactly:
#       # shellcheck source=lib/pool.sh
#       # shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
#       source "$REPO_DIR/lib/pool.sh"
#   Verified clean: with these directives `shellcheck -s bash install.sh` exits 0. Do NOT drop the
#   disable directive (the contract gate `shellcheck -s bash install.sh` would otherwise fail).

# CRITICAL (doctor is a SUBPROCESS; its failure must NOT abort install): run it as
#   "$REPO_DIR/bin/agent-browser-pool" doctor   inside an `if ! ...; then` (the condition list is
#   errexit-exempt, so doctor's `return 1` does NOT trip `set -e`). Capture rc in `doctor_ok` and
#   report it in the success message. Do NOT propagate doctor's rc as install's exit code — install
#   itself (symlink + state) succeeded; doctor is a diagnostic of things install cannot fix (real
#   binary, Chrome, btrfs, master). The OLD installer already behaved this way. (Design decision D1.)

# CRITICAL (--force must not create an unused-variable lint failure): do NOT write `FORCE=1` and
#   then never read it (ShellCheck SC2034). Implement --force|-f as an EMPTY case arm with a
#   comment ("backward compat / scripted use — no-op: no confirmation to skip"). (Design D2.)

# CRITICAL (`(( ))` under set -e): `(( 0 ))` as a bare statement ABORTS (Greg's BashFAQ/105). The
#   `doctor_ok` check MUST be inside an `if (( doctor_ok )); then` (errexit-exempt) — mirror
#   pool_admin_doctor's own `if (( fail > 0 ))`. Never write a bare `(( doctor_ok ))`.

# CRITICAL (REPO_DIR resolution): use the EXACT current pattern
#   REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
#   (contract step a: "same pattern as current"). readlink -f resolves symlinks (e.g. when invoked
#   via a symlinked path); cd+pwd yields a clean absolute path. Do NOT simplify to `dirname "$0"`
#   (breaks when run via symlink/relative path).

# CRITICAL (the ln flags): `-sfnv -- ` — `-s` symbolic, `-f` force (replace existing), `-n`
#   no-deref (treat an existing symlink-to-dir as a file, not a dir to descend into — belt-and-
#   suspenders since the target is a file), `-v` verbose (prints the link to stdout), `--` ends
#   options. Source is ABSOLUTE ($REPO_DIR/bin/agent-browser-pool). (PRD §2.2: never pass bare ~.)

# CRITICAL (do NOT reference the deleted shim): the pre-flight checks exactly TWO repo files —
#   bin/agent-browser-pool (-f + -x) and lib/pool.sh (-f + -r). Do NOT check bin/agent-browser.
#   (Contract step b; the shim is gone per P2.M2.T2.S1.)

# CRITICAL (do NOT touch lib/pool.sh): stale comments at lines 4 + 7 still mention the deleted
#   shim ("Sourced by: bin/agent-browser (the transparent PATH-shadowing wrapper shim)"). These are
#   P2.M1-region doc cruft, explicitly OUT OF SCOPE. LEAVE THEM.

# CRITICAL (the words "shadow"/"cutover" are NOT removal signals): the new script LEGITIMATELY says
#   "NO PATH shadowing" and "NO cutover" in its header/help comments (documenting what it does NOT
#   do). When asserting removals, grep for the OLD MECHANISMS (DISABLE, ~/scripts, Type YES,
#   command -v agent-browser, _path_parts, warn()), NOT the words shadow/cutover.

# CRITICAL (validation is STATIC ONLY — AGENTS.md §1): do NOT execute install.sh, do NOT run
#   doctor, do NOT boot Chrome, do NOT run test/*.sh during this item. The ENTIRE validation is
#   `bash -n` + `shellcheck` + grep assertions (Level 1). Live execution happens later in P2.M5's
#   isolated sandbox. Running install here risks wedging the shared sandbox.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item is a complete rewrite of one shell script. The script is the
deliverable; the exact final content is given in §Implementation Tasks (Task 1).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: REWRITE install.sh  (the entire deliverable — contract steps a–l)
  - WRITE: install.sh   (repo root — overwrite the existing 221-line file IN PLACE)
  - CONTENT: the EXACT script in the "Target install.sh (verbatim)" block below.
  - WHY: PRD §2.17 + gap_analysis §4 + external_deps §install. Replaces the cutover installer
         with the three-benign-things installer.
  - STRUCTURE (top → bottom), matching contract steps a–h:
      a. set -euo pipefail; resolve REPO_DIR via readlink -f (exact current pattern).
      b. arg loop: --force|-f → no-op (empty arm + comment); --help|-h → print help, exit 0;
         * → stderr error + exit 1.
      c. pre-flight: bin/agent-browser-pool (-f + -x) AND lib/pool.sh (-f + -r), else stderr + exit 1.
      d. `source "$REPO_DIR/lib/pool.sh"` (with the TWO shellcheck directives: source= + disable=SC1091)
         then `pool_config_init` (validates $HOME, freezes POOL_STATE_DIR etc.).
      e. `mkdir -p -- "$HOME/.local/bin"`.
      f. `ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"`.
      g. `pool_state_init` (mkdir lanes/ + touch acquire.lock; idempotent).
      h. `printf 'Running dependency check (doctor)...\n'`; `doctor_ok=1`; run
         `"$REPO_DIR/bin/agent-browser-pool" doctor` inside `if ! ...; then doctor_ok=0; fi`.
      i. print the success summary (Mode A doc): entry-point symlink → target; state dir path;
         doctor status (healthy / found problems); USAGE block (status/doctor/open/release/help);
         UNINSTALL line (`rm -f ~/.local/bin/agent-browser-pool`).
  - REMOVED (contract step k — verify by grep on OLD MECHANISMS): cutover warning, YES
         confirmation, ~/scripts symlink + mkdir, PATH-ordering verification block, warn() helper,
         AGENT_BROWSER_POOL_DISABLE.
  - BUCKET: required (the entire deliverable is this one file).

Task 2: STATIC VALIDATION  (contract step l — AGENTS.md §1: static only)
  - RUN:  bash -n install.sh
  - RUN:  shellcheck -s bash install.sh
  - RUN:  the grep assertions in §Validation Loop Level 1 (removals + additions + line count).
  - RUN:  git status --short   (expect EXACTLY one path: install.sh)
  - WHY:  contract step l. No live execution (no Chrome, no doctor run, no test suite) — AGENTS.md §1.
  - BUCKET: required.
```

#### Target install.sh (verbatim — the exact artifact to write in Task 1)

> This is the complete, final `install.sh`. **Verified clean**: `bash -n` exit 0,
> `shellcheck -s bash` exit 0 (zero findings, thanks to the `SC1091` disable directive),
> `wc -l` = 87, all removal/addition greps pass. Write it to `install.sh` (repo root),
> overwriting the existing file. The file already exists + is executable; an in-place content
> rewrite preserves its mode (no `chmod` needed). Do NOT add or remove lines except to fix a
> real defect — this is the validated artifact.

```bash
#!/usr/bin/env bash
#
# install.sh — install agent-browser-pool (PRD §2.1, §2.17).
#
# Three benign things — NO PATH shadowing (lane selection is by caller identity,
# never a PATH interception), so installing CANNOT disrupt running agents:
#   1. symlink bin/agent-browser-pool -> ~/.local/bin/agent-browser-pool (sole entry point)
#   2. pre-create the pool state dir (lanes/ + acquire.lock)
#   3. run `doctor` (verify the real agent-browser, Chrome, btrfs, master)
#
# Mode A (PRD §2.15): this script's success output IS the install documentation.
set -euo pipefail

# resolve REPO dir (symlink-safe; same pattern as the prior installer)
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# argument parsing
for arg in "$@"; do
    case "$arg" in
        --force|-f) ;;  # backward-compat / scripted use — no-op (no confirmation to skip)
        --help|-h)
            cat <<'EOF'
install.sh — install agent-browser-pool.

Creates one symlink (~/.local/bin/agent-browser-pool -> this repo's
bin/agent-browser-pool), pre-creates the pool state dir, and runs `doctor`.
NO PATH shadowing, NO cutover — installing cannot disrupt running agents.

Usage: ./install.sh [--force|-f]
  --force|-f  backward-compat / scripted use (no-op).   --help|-h  this help.
Uninstall: rm -f ~/.local/bin/agent-browser-pool
EOF
            exit 0
            ;;
        *)
            printf 'install.sh: unknown option: %s\n' "$arg" >&2
            printf 'Usage: ./install.sh [--force|-f]\n' >&2
            exit 1
            ;;
    esac
done

# pre-flight: the two repo files we symlink + source must exist & be usable
[[ -f "$REPO_DIR/bin/agent-browser-pool" && -x "$REPO_DIR/bin/agent-browser-pool" ]] \
    || { printf 'install.sh: missing/not executable: %s/bin/agent-browser-pool\n' "$REPO_DIR" >&2; exit 1; }
[[ -f "$REPO_DIR/lib/pool.sh" && -r "$REPO_DIR/lib/pool.sh" ]] \
    || { printf 'install.sh: missing/not readable: %s/lib/pool.sh\n' "$REPO_DIR" >&2; exit 1; }

# source the shared lib + freeze config globals (validates $HOME; pool_die on misconfig)
# shellcheck source=lib/pool.sh
# shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
source "$REPO_DIR/lib/pool.sh"
pool_config_init

# 1. create the sole entry-point symlink (idempotent; -sfnv = symbolic/force/no-deref/verbose)
mkdir -p -- "$HOME/.local/bin"
ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"

# 2. pre-create the pool state dir (lanes/ + acquire.lock) — idempotent
pool_state_init

# 3. run doctor as a SUBPROCESS (insulates its rc/pool_die); capture rc, do NOT abort on failure
printf 'Running dependency check (doctor)...\n'
doctor_ok=1
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    doctor_ok=0
fi

# success message (Mode A — the install documentation) -> stdout
printf '\n============================================================\n'
printf '  Installed agent-browser-pool.\n'
printf '============================================================\n\n'
printf '  entry point:  %s/.local/bin/agent-browser-pool -> %s/bin/agent-browser-pool\n' "$HOME" "$REPO_DIR"
printf '  state dir:    %s/{lanes,acquire.lock}\n' "$POOL_STATE_DIR"
if (( doctor_ok )); then
    printf '  doctor:       healthy.\n'
else
    printf '  doctor:       found problems (see report above). The symlink + state dir were\n'
    printf '                created; fix the issues then re-run: agent-browser-pool doctor\n'
fi
printf '\nUSAGE (agent-browser-pool is the sole command for verbs AND driving):\n'
printf '  agent-browser-pool status            show active lanes\n'
printf '  agent-browser-pool doctor            re-check dependencies\n'
printf '  agent-browser-pool open <url>        drive your lane (acquired/reused by identity)\n'
printf '  agent-browser-pool release [<N>|all] tear down one lane (or all)\n'
printf '  agent-browser-pool help              full command + env reference\n\n'
printf 'UNINSTALL: rm -f %s/.local/bin/agent-browser-pool\n\n' "$HOME"
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the SC1091-safe dynamic source (two directives; verified shellcheck exit 0):
# shellcheck source=lib/pool.sh
# shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
source "$REPO_DIR/lib/pool.sh"

# PATTERN — doctor subprocess guard (set -e-safe; mirrors the OLD installer's idiom):
doctor_ok=1
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    doctor_ok=0
fi
# `if !` is a condition list → errexit-exempt: doctor's `return 1` does NOT abort the script.
# Then: `if (( doctor_ok )); then ...`  — the `(( ))` is inside `if` → errexit-exempt (a bare
# `(( 0 ))` would otherwise ABORT under set -e). This is exactly pool_admin_doctor's own pattern.

# PATTERN — empty no-op case arm (avoids ShellCheck SC2034 for an unused FORCE var):
case "$arg" in
    --force|-f) ;;   # backward compat / scripted use — no confirmation to skip
    ...
esac

# PATTERN — pre-flight that CANNOT reference the deleted shim:
[[ -f "$REPO_DIR/bin/agent-browser-pool" && -x "$REPO_DIR/bin/agent-browser-pool" ]] || { ...; exit 1; }
[[ -f "$REPO_DIR/lib/pool.sh" && -r "$REPO_DIR/lib/pool.sh" ]] || { ...; exit 1; }

# GOTCHA — pool_config_init is called IN install.sh's shell (not only via doctor) so that
#   POOL_STATE_DIR is frozen for pool_state_init AND for the success message. It is idempotent;
#   the doctor subprocess re-runs it harmlessly.

# GOTCHA — lib/pool.sh's top-level `set -euo pipefail` (line 18) propagates into install.sh's
#   shell on `source`. That is FINE — install.sh sets it itself at the top. No conflict.
```

### Integration Points

```yaml
NONE for this item beyond the repo file tree (one file rewritten in place).
  - No new code, no new config, no new env vars (install.sh defines none).
  - The script CONSUMES (does not modify):
      * lib/pool.sh — pool_config_init, pool_state_init (called in-process); pool_admin_doctor
        (called via the bin/agent-browser-pool doctor subprocess).
      * bin/agent-browser-pool — the doctor subprocess target + pre-flight -x check.
  - Downstream consumers that build on this LATER (NOT here):
      * README.md install section   (P2.M6.T1.S1 — will describe THIS installer)
      * test/validate.sh + test/transparency.sh   (P2.M5 — will exercise install in an isolated
        sandbox; that is the ONLY place install.sh is actually executed)
```

---

## Validation Loop

> Per AGENTS.md §1/§2/§3: EVERY command below is STATIC (`bash -n`, `shellcheck`, `grep`, `test`,
> `git`). **Do NOT execute install.sh, do NOT run doctor, do NOT boot Chrome, do NOT run
> test/*.sh during this item.** Levels 2-4 are N/A by design (a rewrite has no runtime behavior to
> validate here; live execution is deferred to P2.M5's isolated sandbox).

### Level 1: Syntax, Style & content (run after the rewrite)

```bash
cd /home/dustin/projects/agent-browser-pool

# --- contract step l: static checks (both MUST exit 0) ---
bash -n install.sh && echo "OK: bash -n" || echo "FAIL: bash -n"
shellcheck -s bash install.sh && echo "OK: shellcheck" || echo "FAIL: shellcheck"

# --- line count (~80-95; ~87 expected) ---
n=$(wc -l < install.sh); echo "lines: $n"
test "$n" -ge 78 -a "$n" -le 95 && echo "OK: line count in band" || echo "FAIL: line count out of band"

# --- REMOVALS: OLD MECHANISMS — each grep MUST find ZERO matches ---
for pat in 'AGENT_BROWSER_POOL_DISABLE' 'HOME/scripts' 'Type YES' 'command -v agent-browser' '_path_parts' '^warn\(\)'; do
    if grep -nE "$pat" install.sh; then echo "FAIL: found removed mechanism: $pat"; else echo "OK: absent: $pat"; fi
done

# --- ADDITIONS: each grep MUST find a match ---
grep -nq 'source "\$REPO_DIR/lib/pool.sh"' install.sh && echo "OK: sources pool.sh" || echo "FAIL: no source"
grep -nq 'pool_config_init' install.sh && echo "OK: pool_config_init" || echo "FAIL: no pool_config_init"
grep -nq 'pool_state_init' install.sh && echo "OK: pool_state_init" || echo "FAIL: no pool_state_init"
grep -nq 'bin/agent-browser-pool" doctor' install.sh && echo "OK: doctor subprocess" || echo "FAIL: no doctor subprocess"
grep -nq 'ln -sfnv -- "\$REPO_DIR/bin/agent-browser-pool" "\$HOME/.local/bin/agent-browser-pool"' install.sh \
  && echo "OK: one entry-point symlink" || echo "FAIL: missing/incorrect symlink"
grep -nq -- '--help|-h' install.sh && echo "OK: --help accepted" || echo "FAIL: no --help"
grep -nq -- '--force|-f' install.sh && echo "OK: --force accepted" || echo "FAIL: no --force"
grep -nqi 'UNINSTALL' install.sh && echo "OK: uninstall documented" || echo "FAIL: no uninstall doc"
# (The SC1091 disable directive is required for a clean shellcheck exit:)
grep -nq 'shellcheck disable=SC1091' install.sh && echo "OK: SC1091 directive present" || echo "FAIL: missing SC1091 directive"

# --- sanity: the words shadow/cutover MAY appear (only as NEGATIONS — do NOT flag) ---
grep -niE 'shadow|cutover' install.sh | sed 's/^/  (intended negation comment) /'

# --- the deleted shim is NEVER referenced ---
if grep -n 'bin/agent-browser"' install.sh | grep -v 'agent-browser-pool'; then
    echo "FAIL: install.sh references the deleted shim"
else
    echo "OK: no reference to the deleted shim"
fi

# --- scope: ONLY install.sh changed by this item ---
git status --short
# Expect exactly one path: " M install.sh" (or staged equivalent). Nothing under bin/, lib/, etc.
git status --short | grep -qvE '^.M? install\.sh$' && echo "FAIL: unexpected changed files" || echo "OK: only install.sh changed"
```

**Expected**: every assertion prints `OK:`; `bash -n` exit 0; `shellcheck -s bash` exit 0; line
count ~87; the 6 removed-mechanism greps find nothing; all addition greps match (incl. the SC1091
directive); the deleted shim is unreferenced; `git status --short` shows only `install.sh`.

### Level 2: Component Validation — N/A

The script's runtime correctness (doctor wiring, symlink creation, state-dir init) is exercised
by `test/validate.sh` + `test/transparency.sh` (P2.M5) in an isolated sandbox — NOT by this item.
Running install.sh here risks wedging the shared sandbox (AGENTS.md §1).

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Confirm lib/pool.sh was NOT edited by this item (its stale comments are out of scope):
git diff --name-only | grep -q '^lib/pool\.sh$' \
  && echo "FAIL: lib/pool.sh unexpectedly modified" || echo "OK: lib/pool.sh untouched"

# Confirm bin/agent-browser-pool was NOT edited by this item (owned by P2.M2):
git diff --name-only | grep -q '^bin/agent-browser-pool$' \
  && echo "NOTE: bin/agent-browser-pool changed (by P2.M2 in parallel, not this item — OK)" \
  || echo "OK: bin/agent-browser-pool untouched by this item"

# Confirm the script will source the lib correctly (dry path check — no execution):
test -f lib/pool.sh && test -r lib/pool.sh && echo "OK: lib/pool.sh sourceable" || echo "FAIL"

# Do NOT run: install.sh, test/*.sh, doctor, or any agent-browser / Chrome command (AGENTS.md §1).
```

### Level 4: Creative & Domain-Specific Validation — N/A

A source-file rewrite has no domain runtime to validate here. The repo state is fully pinned by
Level 1-3 static checks + the verbatim artifact + the item contract + PRD §2.17.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: `bash -n install.sh` exit 0; `shellcheck -s bash install.sh` exit 0 (zero findings).
- [ ] Line count ~80-95 (~87 expected).
- [ ] All 6 removed-mechanism greps find NOTHING; all addition greps match (incl. SC1091 directive).
- [ ] `git status --short` shows ONLY `install.sh` changed by this item.

### Feature Validation

- [ ] install.sh does exactly three benign things: symlink, `pool_state_init`, doctor (contract).
- [ ] install.sh never references the deleted shim `bin/agent-browser` (contract step b).
- [ ] `--force|-f` accepted (no-op); `--help|-h` prints the benign-model help + exit 0 (steps i, j).
- [ ] Success message (Mode A) covers: symlink created, doctor status, how to use
      `agent-browser-pool`, and uninstall (`rm -f ~/.local/bin/agent-browser-pool`) (step h + DOCS).
- [ ] PRD §2.17 "no PATH shadowing / no cutover / no DISABLE / no ~/scripts" fully honored.

### Code Quality / Scope Validation

- [ ] **Only** `install.sh` is modified; no other file touched.
- [ ] `lib/pool.sh` untouched (stale shim comments @4/@7 left in place — out of scope).
- [ ] `bin/agent-browser-pool`, `bin/.gitkeep` untouched.
- [ ] `README.md`, `SKILL.md`, `references/*`, `test/*` untouched (owned by P2.M4/P2.M5/P2.M6).
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no doctor run, no test suite, no shared-
      `$HOME` writes) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] install.sh's own stdout IS the install doc (success message = symlink + doctor
      status + usage + uninstall). No separate doc file is written by this item.
- [ ] No new env vars introduced by install.sh (it defines none).

---

## Anti-Patterns to Avoid

- ❌ Don't drop the `# shellcheck disable=SC1091` directive — without it, the dynamic `source`
      emits SC1091 and `shellcheck -s bash install.sh` exits 1 (verified on the CURRENT installer).
      The directive is what makes the new installer lint-clean. Keep both `source=` + `disable=`.
- ❌ Don't propagate doctor's exit code as install's exit code — doctor is a diagnostic of things
      install cannot fix (real binary, Chrome, btrfs, master); the symlink + state dir succeeded.
      Capture `doctor_ok` and report it; exit 0. (Design D1.)
- ❌ Don't write `FORCE=1` and leave it unread (ShellCheck SC2034). Use an empty `--force|-f) ;;`
      case arm with a comment. (Design D2.)
- ❌ Don't write a bare `(( doctor_ok ))` (aborts under `set -e` when 0) — always inside `if`.
- ❌ Don't check for / symlink `bin/agent-browser` — it's deleted (P2.M2.T2.S1). The pre-flight
      checks exactly TWO files.
- ❌ Don't simplify REPO_DIR to `dirname "$0"` — it breaks under symlink/relative invocation. Use
      the exact `readlink -f` + `cd && pwd` pattern (contract step a).
- ❌ Don't drop the `-n` from `ln -sfnv` (no-deref matters if the link target is ever a dir), and
      don't drop the `--` option terminator.
- ❌ Don't "tidy" the stale shim comments in `lib/pool.sh` (lines 4, 7) — out of scope; not this
      item's files.
- ❌ Don't flag the words "shadow"/"cutover" as regressions — the new script uses them in negation
      comments ("NO PATH shadowing", "NO cutover") intentionally. Grep for OLD MECHANISMS instead.
- ❌ Don't run install.sh, doctor, test/*.sh, or any Chrome/agent-browser command during this
      item — AGENTS.md §1 (sandbox-hang prevention). All validation is static (Level 1).
- ❌ Don't edit `README.md`/`SKILL.md`/`references/*`/`test/*` — each is owned by a downstream
      item (P2.M4/P2.M5/P2.M6).

---

## Confidence Score

**10/10** — one-pass success likelihood. The item is a single-file complete rewrite, and the PRP
supplies the **exact final `install.sh` verbatim** (the artifact is the spec) — and that artifact
has been **validated end-to-end on the host**: `bash -n` exit 0, `shellcheck -s bash` exit 0 (the
`SC1091` disable directive was confirmed necessary AND sufficient — the current installer fails
this check without it), `wc -l` = 87, and all removal/addition greps pass. Every library function
the script calls is pinned to a line anchor with its return-code semantics; every `set -e` hazard
(doctor rc, `(( ))`, unused FORCE, dynamic-source SC1091) has an explicit, verified guard; the
design decisions (doctor-rc handling, --force no-op, two-file pre-flight) resolve all open
questions and are justified against the PRD. Validation is entirely static and cannot wedge the
sandbox (AGENTS.md §1); the downstream live-exercise is correctly deferred to P2.M5. The only
remaining work is a literal file overwrite + the provided static checks.
