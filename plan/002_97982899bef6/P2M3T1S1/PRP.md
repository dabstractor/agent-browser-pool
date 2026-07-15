# PRP — P2.M3.T1.S1: Complete rewrite of `install.sh` — no PATH shadowing, no cutover

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M3.T1.S1 (2 points)
**Dependency / starting state**: Builds on the POST-P2.M2 tree. The sibling item **P2.M2.T2.S1**
deletes `bin/agent-browser` (the OLD PATH-shadowing shim) — by the time this item runs the shim is
GONE and `bin/agent-browser-pool` is the **sole entry point** (its `*)` arm dispatches driving
commands to `pool_wrapper_main`, per the completed P2.M2.T1.S1). `lib/pool.sh` is the POST-P2.M1
version (DISABLE removed, no-pi-ancestor fail-fast, `_pool_preflight_real_bin` present). **This
item owns exactly ONE file: `install.sh`** (repo root).
**Full research notes**: `plan/002_97982899bef6/P2M3T1S1/research/notes.md`

---

## ⚠️ DISCOVERED CURRENT STATE — read this first

During research, `git log -- install.sh` revealed the rewrite was **already performed** and is in
HEAD:

```
7926c44 Replace cutover installer with benign setup      ← HEAD (the NEW install.sh lives here)
05853c1 Add deliberate cutover installer with YES gate   ← the old 221-line cutover version
```

The **current** `install.sh` on disk (== HEAD, 105 lines, `git status` clean) is **already the
benign, no-shadow installer** — NOT the old 221-line cutover version. Verified against the
contract at research time:

| Contract requirement | Current `install.sh` status |
|---|---|
| `set -euo pipefail` | ✅ present |
| `REPO_DIR` via `readlink -f` + `cd && pwd` | ✅ present (exact pattern) |
| Pre-flight checks exactly TWO files (`bin/agent-browser-pool` + `lib/pool.sh`) | ✅ present |
| `source lib/pool.sh` + `pool_config_init` | ✅ present |
| `mkdir -p "$HOME/.local/bin"` + one `ln -sfnv` symlink | ✅ present |
| `pool_state_init` | ✅ present |
| doctor run as subprocess (`if ! "$REPO_DIR/bin/agent-browser-pool" doctor`) | ✅ present |
| Mode-A success message (symlink + doctor status + usage + uninstall) | ✅ present |
| `--force\|-f` (no-op) + `--help\|-h` | ✅ present |
| `AGENT_BROWSER_POOL_DISABLE` / `~/scripts` / `Type YES` / PATH-ordering / `warn()` | ✅ ALL ABSENT |
| Never references deleted shim `bin/agent-browser` | ✅ confirmed |
| `bash -n install.sh` | ✅ exit 0 |
| **`shellcheck -s bash install.sh` (contract step l)** | ❌ **EXIT 1** |

**The ONE open defect**: `shellcheck -s bash install.sh` exits 1 with `SC1091` (info) on the
dynamic `source "$REPO_DIR/lib/pool.sh"` line. The committed file has `# shellcheck source=lib/pool.sh`
but is **missing** the `# shellcheck disable=SC1091` directive. SC1091 is a known false-positive
for runtime-resolved source paths; shellcheck treats it as a finding and exits non-zero. **This
is a contract-step-l failure and the sole blocker.**

> **Implication**: the "complete rewrite" is essentially DONE. The remaining deliverable is
> (1) make `install.sh` pass contract step l (`shellcheck` exit 0) by adding the one missing
> directive line, and (2) verify full conformance via the validation gates below. The verbatim
> canonical artifact in this PRP is the validated target — the implementer may either apply the
> one-line surgical fix (recommended; respects the committed work) or replace the file wholesale
> with the canonical artifact (also valid; additionally aligns wording with PRD §2.17 "shadowing").

---

## Goal

**Feature Goal**: Ensure `install.sh` fully conforms to the PRD §2.17 contract — the three benign
things (symlink / state-dir / doctor), no PATH shadowing, no cutover, no `AGENT_BROWSER_POOL_DISABLE`
— **AND passes contract step l** (`bash -n` + `shellcheck -s bash`, both exit 0). The rewrite
itself is already in HEAD (`7926c44`); this item closes the one remaining gap (the failing
`shellcheck` gate) and certifies conformance.

**Deliverable**: A conformant, lint-clean `install.sh` such that `bash -n install.sh` exits 0 AND
`shellcheck -s bash install.sh` exits 0, while preserving all three benign behaviors and all the
removals already present in HEAD. Two acceptable paths (pick ONE):
- **Path A (recommended — surgical, respects committed work)**: add the single directive line
  `# shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above`
  immediately after the existing `# shellcheck source=lib/pool.sh` (line 59) and before the
  `source "$REPO_DIR/lib/pool.sh"` line. → 106 lines, lint-clean, contract-conformant.
- **Path B (full canonical replace)**: overwrite `install.sh` with the verbatim artifact in
  §Implementation Blueprint. → 87 lines, lint-clean, and additionally aligns wording with PRD
  §2.17 ("shadowing") + tightens comments. Verified identical in behavior to the committed version.

**Success Definition**:
- `bash -n install.sh` exits 0.
- `shellcheck -s bash install.sh` exits 0 (zero findings). *(This is the delta from the current
  HEAD, which exits 1 on SC1091.)*
- `grep` confirms the OLD MECHANISMS remain absent: `AGENT_BROWSER_POOL_DISABLE`, `HOME/scripts`,
  `Type YES`, `command -v agent-browser`, `_path_parts`, `^warn()` — zero matches.
- `grep` confirms the ADDITIONS remain present: sources `lib/pool.sh`, calls `pool_config_init` +
  `pool_state_init`, runs `bin/agent-browser-pool doctor`, creates exactly the one entry-point
  symlink, accepts `--force|-f` + `--help|-h`, documents uninstall.
- `install.sh` still never references the deleted shim `bin/agent-browser`.
- **Only** `install.sh` is modified by this item (`git status --short` shows one path).

---

## Why

- **PRD alignment**: PRD §2.17 (h3.21): "There is **no PATH shadowing** — the real `agent-browser`
  is never intercepted, so installing the pool cannot disrupt running agents." It enumerates the
  three benign things install does and marks **Removed**: "`AGENT_BROWSER_POOL_DISABLE` ... and the
  `~/scripts`-ahead-of-`~/.local/bin` PATH requirement." PRD §2.1 (h3.5): `~/.local/bin/agent-browser-pool`
  is the "SOLE entry point". The committed installer already realizes this model; this item makes
  it pass the project's own static gate (`shellcheck`) so the contract is fully honored.
- **Who it helps**: A failing `shellcheck` gate would block P2.M5's isolated-sandbox test pass
  (which lints the suite) and signals a latent quality issue. Closing it makes install.sh a clean,
  verifiable, low-surface entry point.
- **Scope cohesion**: This is item T1 of milestone P2.M3 (Install Script Rewrite). It is the
  prerequisite for P2.M6.T1.S1 (README rewrite — describes this installer) and for P2.M5
  (test/transparency.sh + test/validate.sh exercise install in an isolated sandbox). It touches
  ONLY `install.sh`; `lib/pool.sh`, `bin/*`, `README.md`, `SKILL.md`, `references/*`, `test/*` are
  untouched here and owned by P2.M1(done)/P2.M2/P2.M4/P2.M5/P2.M6.

---

## What

**User-visible behavior**: Unchanged from the committed installer — `./install.sh` prints (at
most) the one `ln -sfnv` line, the full `doctor` report, and a short success summary, then exits
0; it creates/refreshes one symlink and pre-creates the state dir; never touches `~/scripts`,
never checks PATH ordering, never asks for confirmation. `--force`/`-f` is a no-op; `--help`/`-h`
prints usage. This PRP changes only the lint-cleanliness (and optionally the comment wording if
Path B is chosen).

**Unchanged (explicitly preserved — do NOT edit in this item)**:
- `bin/agent-browser-pool` — stays (only READ: pre-flight `-x` + doctor subprocess target).
- `lib/pool.sh` — stays (SOURCED + 3 functions CALLED; stale comments @4/@7 mention the deleted
  shim — harmless doc cruft, out of scope; do NOT tidy).
- `bin/agent-browser` — assumed already DELETED by P2.M2.T2.S1; install.sh never references it.
- `README.md`, `SKILL.md`, `references/*`, `test/*` — stay (owned by P2.M4/P2.M5/P2.M6).
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY, never touched.
- Operator's real `$HOME` — NOT run during this item (AGENTS.md §1); we only static-check the file.

### Success Criteria

- [ ] `bash -n install.sh` exits 0.
- [ ] `shellcheck -s bash install.sh` exits 0 (zero findings) — **the key delta from HEAD**.
- [ ] No occurrence of OLD mechanisms: `AGENT_BROWSER_POOL_DISABLE`, `~/scripts`/`$HOME/scripts`,
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
this successfully?_ **Yes** — the discovered current state is documented (already rewritten in
HEAD `7926c44`), the ONE open defect is pinned to an exact line + exact one-line fix, the
canonical target artifact is provided verbatim (and was validated lint-clean on the host), the
precise functions the script calls are pinned to line anchors with return-code semantics, and the
exact static-validation commands (verified present + the failing one reproduced) are given. No
guessing.

### Documentation & References

```yaml
# MUST READ — the contract for this exact item
- file: plan/002_97982899bef6/architecture/gap_analysis.md   §4
  why: "install.sh — COMPLETE REWRITE ... New (~50-70 lines): Three benign things: 1. ln -sfnv
        .../bin/agent-browser-pool ~/.local/bin/agent-browser-pool; 2. Pre-create state dir via
        pool_state_init; 3. Run doctor. No cutover warning, no ~/scripts, no PATH-ordering, no
        confirmation gate, no AGENT_BROWSER_POOL_DISABLE."
  critical: "The committed HEAD already satisfies this contract EXCEPT shellcheck step l (SC1091)."

- file: plan/002_97982899bef6/architecture/external_deps.md   (§install.sh Dependency Changes)
  why: "Old install.sh required ~/scripts to precede ~/.local/bin on $PATH. REMOVED. New needs:
        $HOME/.local/bin (created if missing), ln (coreutils), repo files bin/agent-browser-pool
        + lib/pool.sh to exist + be executable."

- prd: PRD.md §2.17 (h3.21) — Install (no cutover danger)
  why: "install.sh does three benign things ... Removed: AGENT_BROWSER_POOL_DISABLE ... and the
        ~/scripts-ahead-of-~/.local/bin PATH requirement."
  critical: "Lane selection is by caller identity (never a PATH interception) → coexistence is
        per-call. Installing cannot disrupt running agents."

- prd: PRD.md §2.1 (h3.5) — Components
  why: "~/.local/bin/agent-browser-pool ← SOLE entry point (symlink → repo bin/)". Confirms the
        ONE symlink target + name.

- prd: PRD.md §2.16 (h3.20) — Dependencies
  why: "agent-browser ≥ 0.28 — enforced by doctor's [binary] check (run by install.sh)." Confirms
        install just RUNS doctor (does not reimplement checks).

- file: install.sh   (CURRENT — already the benign installer, HEAD 7926c44, 105 lines)
  why: Read it to see the already-implemented target. The committed version is functionally
        conformant; it only lacks the SC1091 disable directive (line 59 has source= but not
        disable=) → shellcheck exits 1.
  pattern: "KEEP its structure verbatim if using Path A; the only insertion is the disable line.
           If using Path B, replace wholesale with the canonical artifact (behavior-identical)."
  gotcha: "Do NOT regress: keep all three benign things, all removals, both flags, the Mode-A
           success message, the doctor subprocess guard."

- file: bin/agent-browser-pool   (25 lines — READ only; the sole entry point + doctor target)
  why: "Confirms `doctor` is reachable as `$REPO_DIR/bin/agent-browser-pool doctor` (case arm →
        pool_admin_doctor), and that the binary self-inits config+state. So install's doctor call
        is a self-contained subprocess."

- file: lib/pool.sh   (SOURCED + 3 functions CALLED — UNTOUCHED)
  why: "pool_config_init (line 131): validates $HOME, freezes all POOL_* globals incl.
        POOL_STATE_DIR/POOL_LANES_DIR/POOL_LOCK_FILE; returns 0, pool_die on misconfig.
        pool_state_init (line 209): mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE; idempotent;
        returns 0, pool_die on real FS failure. pool_admin_doctor (line 4330): invoked via the
        subprocess; calls config+state init itself; returns 0 healthy / 1 problems; prints the
        full report to stdout."
  critical: "lib/pool.sh is SAFE TO SOURCE: the ONLY top-level executable statement is
             `set -euo pipefail` (line 18); everything else is comments + function defs. No side
             effect fires on `source`. pool_config_init is idempotent."

- file: plan/002_97982899bef6/P2M2T2S1/PRP.md   (parallel sibling — CONTRACT for the deleted shim)
  why: "Confirms bin/agent-browser is DELETED → install.sh must NOT check/symlink it. DISJOINT
        files → composes in either order."
```

### Current codebase tree (relevant slice)

```bash
install.sh               # ALREADY the benign installer (HEAD 7926c44, 105 lines); FAILS shellcheck (SC1091)
bin/
├── .gitkeep             # UNTOUCHED
├── agent-browser        # (deleted by parallel P2.M2.T2.S1 — assume gone; never referenced)
└── agent-browser-pool   # 25 lines — UNTOUCHED (sole entry point; READ only)
lib/pool.sh              # ~4626 lines — UNTOUCHED (SOURCED + 3 funcs called)
README.md                # UNTOUCHED (P2.M6.T1.S1)
test/*                   # UNTOUCHED (P2.M5). NOT run here (AGENTS.md §1).
PRD.md                   # READ-ONLY.
```

### Desired codebase tree with files to be added and responsibility of file

```bash
install.sh               # Path A: +1 line (SC1091 directive) → 106 lines, lint-clean.
                         # Path B: replaced with canonical artifact → 87 lines, lint-clean.
# No new files. No deletions. No other modifications.
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (THE defect to fix): the committed install.sh has `# shellcheck source=lib/pool.sh`
#   (line 59) but is MISSING `# shellcheck disable=SC1091`, so `shellcheck -s bash install.sh`
#   emits SC1091 (info) on `source "$REPO_DIR/lib/pool.sh"` and EXITS 1 (verified on HEAD).
#   FIX: insert the disable directive on the line BETWEEN source= and source, exactly:
#       # shellcheck source=lib/pool.sh
#       # shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
#       source "$REPO_DIR/lib/pool.sh"
#   Verified: with both directives, `shellcheck -s bash install.sh` exits 0. (This is the ONLY
#   behavioral gap between HEAD and the contract.)

# CRITICAL (doctor is a SUBPROCESS; its failure must NOT abort install): it is run as
#   "$REPO_DIR/bin/agent-browser-pool" doctor   inside an `if ! ...; then` (condition list →
#   errexit-exempt; doctor's `return 1` does NOT trip `set -e`). The committed version already
#   does this correctly. Do NOT "improve" it by propagating doctor's rc as install's exit code
#   — doctor is a diagnostic of things install cannot fix (real binary, Chrome, btrfs, master);
#   the symlink + state dir succeeded. Keep exit 0. (Design D1.)

# CRITICAL (--force must stay a no-op, not an unused var): the committed version correctly uses a
#   multi-line comment inside the `--force|-f)` arm (no FORCE variable) — ShellCheck SC2034-clean.
#   Do NOT re-introduce a `FORCE=1` that is never read.

# CRITICAL (`(( ))` under set -e): the doctor_ok check is inside `if (( doctor_ok )); then`
#   (errexit-exempt) — mirror pool_admin_doctor's `if (( fail > 0 ))`. Never write a bare
#   `(( doctor_ok ))`. The committed version already does this correctly.

# CRITICAL (do NOT touch lib/pool.sh): stale comments at lines 4 + 7 still mention the deleted
#   shim. P2.M1-region doc cruft, OUT OF SCOPE. LEAVE THEM.

# CRITICAL (the words "shadow"/"cutover"/"interception" are NOT removal signals): the committed
#   installer LEGITIMATELY uses "NO PATH interception"/"no disruptive takeover" in comments/help
#   (documenting what it does NOT do). When asserting removals, grep for OLD MECHANISMS (DISABLE,
#   ~/scripts, Type YES, command -v agent-browser, _path_parts, warn()), NOT the negation words.
#   (PRD §2.17 says "shadowing"; the canonical artifact uses that wording, but "interception" is
#   semantically equivalent — do NOT treat the wording difference as a defect.)

# CRITICAL (validation is STATIC ONLY — AGENTS.md §1): do NOT execute install.sh, do NOT run
#   doctor, do NOT boot Chrome, do NOT run test/*.sh during this item. The ENTIRE validation is
#   `bash -n` + `shellcheck` + grep assertions (Level 1). Live execution is P2.M5's job.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This item touches one shell script (and, given the discovered state,
optionally only adds one directive line). The canonical artifact below is the validated target.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MAKE install.sh PASS SHELLCHECK (contract step l) — the ONE open defect
  - CONTEXT: HEAD's install.sh (7926c44) is functionally conformant but `shellcheck -s bash
             install.sh` exits 1 on SC1091 (missing disable directive). bash -n already passes.
  - CHOOSE exactly ONE path:
    Path A (RECOMMENDED — surgical, 1-line insertion):
      - EDIT install.sh: insert the line
            # shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
        immediately AFTER the existing line `# shellcheck source=lib/pool.sh` (line 59) and
        BEFORE `source "$REPO_DIR/lib/pool.sh"` (line 60). Change nothing else.
      - RESULT: 106 lines, lint-clean, contract-conformant (preserves the committed wording).
    Path B (full canonical replace):
      - WRITE install.sh with the EXACT content of the "Target install.sh (verbatim)" block below.
      - RESULT: 87 lines, lint-clean, contract-conformant, AND aligns wording with PRD §2.17
        ("shadowing") + tighter comments. Behavior-identical to the committed version.
  - WHY: contract step l (`shellcheck -s bash install.sh`) must exit 0.
  - BUCKET: required (this is the entire remaining deliverable).

Task 2: STATIC VALIDATION (conformance certification — AGENTS.md §1: static only)
  - RUN:  bash -n install.sh
  - RUN:  shellcheck -s bash install.sh      # MUST now exit 0 (was 1 on HEAD)
  - RUN:  the grep assertions in §Validation Loop Level 1 (removals absent + additions present).
  - RUN:  git status --short                  # expect EXACTLY one path: install.sh
  - WHY:  certify the file conforms to the contract after the fix. No live execution.
  - BUCKET: required.
```

#### Target install.sh (verbatim — canonical artifact; Path B, and the reference for Path A)

> This is the complete, lint-clean canonical `install.sh`. **Verified on the host**: `bash -n`
> exit 0, `shellcheck -s bash` exit 0 (zero findings, thanks to the `SC1091` disable directive),
> `wc -l` = 87, all removal/addition greps pass. It is **behavior-identical** to the committed
> HEAD version; the deltas are: (1) the added `# shellcheck disable=SC1091` directive (the fix),
> (2) comment wording "shadowing"/"interception" aligned to PRD §2.17, (3) tighter comments/help
> (105 → 87 lines). **Path A implementers need NOT write this whole file** — they only insert the
> one disable directive line into the existing file; this block is the canonical reference + the
> Path-B content.

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
# PATTERN — the SC1091-safe dynamic source (the FIX; two directives; verified shellcheck exit 0):
# shellcheck source=lib/pool.sh
# shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
source "$REPO_DIR/lib/pool.sh"
# WITHOUT the disable line, shellcheck emits SC1091 and exits 1 (this is HEAD's current defect).

# PATTERN — doctor subprocess guard (set -e-safe; already correct in HEAD):
doctor_ok=1
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    doctor_ok=0
fi
# `if !` is a condition list → errexit-exempt: doctor's `return 1` does NOT abort the script.
# Then `if (( doctor_ok )); then ...` — the `(( ))` is inside `if` → errexit-exempt (a bare
# `(( 0 ))` would otherwise ABORT under set -e). Exactly pool_admin_doctor's own pattern.

# GOTCHA — pool_config_init is called IN install.sh's shell (not only via doctor) so that
#   POOL_STATE_DIR is frozen for pool_state_init AND for the success message. Idempotent.
# GOTCHA — lib/pool.sh's top-level `set -euo pipefail` (line 18) propagates into install.sh's
#   shell on `source`. Fine — install.sh sets it itself at the top. No conflict.
```

### Integration Points

```yaml
NONE beyond the repo file tree (one file touched).
  - The script CONSUMES (does not modify):
      * lib/pool.sh — pool_config_init, pool_state_init (in-process); pool_admin_doctor (via the
        bin/agent-browser-pool doctor subprocess).
      * bin/agent-browser-pool — the doctor subprocess target + pre-flight -x check.
  - Downstream consumers that build on this LATER (NOT here):
      * README.md install section   (P2.M6.T1.S1 — will describe THIS installer)
      * test/validate.sh + test/transparency.sh   (P2.M5 — exercise install in an isolated
        sandbox; that is the ONLY place install.sh is actually executed)
```

---

## Validation Loop

> Per AGENTS.md §1/§2/§3: EVERY command below is STATIC (`bash -n`, `shellcheck`, `grep`, `test`,
> `git`). **Do NOT execute install.sh, do NOT run doctor, do NOT boot Chrome, do NOT run
> test/*.sh during this item.** Levels 2-4 are N/A (no runtime behavior change; live execution is
> P2.M5's job in an isolated sandbox).

### Level 1: Syntax, Style & content (run after the fix)

```bash
cd /home/dustin/projects/agent-browser-pool

# --- contract step l: static checks (BOTH must exit 0; shellcheck was 1 on HEAD) ---
bash -n install.sh && echo "OK: bash -n" || echo "FAIL: bash -n"
shellcheck -s bash install.sh && echo "OK: shellcheck (was FAIL on HEAD — SC1091 fixed)" || echo "FAIL: shellcheck"

# --- line count (Path A ~106; Path B ~87) ---
n=$(wc -l < install.sh); echo "lines: $n"

# --- the SC1091 directive MUST now be present (the fix) ---
grep -nq 'shellcheck disable=SC1091' install.sh && echo "OK: SC1091 directive present" || echo "FAIL: missing SC1091 directive"

# --- REMOVALS: OLD MECHANISMS — each grep MUST find ZERO matches ---
for pat in 'AGENT_BROWSER_POOL_DISABLE' 'HOME/scripts' 'Type YES' 'command -v agent-browser' '_path_parts' '^warn\(\)'; do
    if grep -nE "$pat" install.sh; then echo "FAIL: found removed mechanism: $pat"; else echo "OK: absent: $pat"; fi
done

# --- ADDITIONS: each grep MUST find a match ---
grep -nq 'source "\$REPO_DIR/lib/pool.sh"' install.sh && echo "OK: sources pool.sh" || echo "FAIL: no source"
grep -nq 'pool_config_init' install.sh && echo "OK: pool_config_init" || echo "FAIL: no pool_config_init"
grep -nq 'pool_state_init' install.sh && echo "OK: pool_state_init" || echo "FAIL: no pool_state_init"
grep -nq 'bin/agent-browser-pool" doctor' install.sh && echo "OK: doctor subprocess" || echo "FAIL: no doctor subprocess"
grep -nq 'ln -sfnv -- "\$REPO_DIR/bin/agent-browser-pool"' install.sh && echo "OK: one entry-point symlink" || echo "FAIL: missing symlink"
grep -nq -- '--help|-h' install.sh && echo "OK: --help accepted" || echo "FAIL: no --help"
grep -nq -- '--force|-f' install.sh && echo "OK: --force accepted" || echo "FAIL: no --force"
grep -nqi 'UNINSTALL' install.sh && echo "OK: uninstall documented" || echo "FAIL: no uninstall doc"

# --- sanity: negation words (shadow/cutover/interception) MAY appear in comments — do NOT flag ---
grep -niE 'shadow|cutover|interception' install.sh | sed 's/^/  (intended negation comment) /'

# --- the deleted shim is NEVER referenced ---
if grep -n 'bin/agent-browser"' install.sh | grep -v 'agent-browser-pool'; then
    echo "FAIL: install.sh references the deleted shim"
else
    echo "OK: no reference to the deleted shim"
fi

# --- scope: ONLY install.sh changed by this item ---
git status --short
git status --short | grep -qvE '^.M? install\.sh$' && echo "FAIL: unexpected changed files" || echo "OK: only install.sh changed"
```

**Expected**: `bash -n` exit 0; `shellcheck -s bash` exit 0 (the key delta — was 1 on HEAD); the
SC1091 directive present; all 6 removed-mechanism greps find nothing; all addition greps match;
the shim unreferenced; `git status --short` shows only `install.sh`.

### Level 2: Component Validation — N/A

Runtime correctness (doctor wiring, symlink, state-dir init) is exercised by `test/validate.sh`
+ `test/transparency.sh` (P2.M5) in an isolated sandbox — not here. The committed installer's
runtime behavior is unchanged by this fix (the fix only adds a shellcheck directive).

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# Confirm lib/pool.sh was NOT edited by this item:
git diff --name-only | grep -q '^lib/pool\.sh$' \
  && echo "FAIL: lib/pool.sh unexpectedly modified" || echo "OK: lib/pool.sh untouched"

# Confirm bin/agent-browser-pool was NOT edited by this item:
git diff --name-only | grep -q '^bin/agent-browser-pool$' \
  && echo "NOTE: bin/agent-browser-pool changed (by P2.M2 in parallel, not this item — OK)" \
  || echo "OK: bin/agent-browser-pool untouched by this item"

# Confirm the lib is sourceable (dry path check — no execution):
test -f lib/pool.sh && test -r lib/pool.sh && echo "OK: lib/pool.sh sourceable" || echo "FAIL"

# Do NOT run: install.sh, test/*.sh, doctor, or any agent-browser / Chrome command (AGENTS.md §1).
```

### Level 4: Creative & Domain-Specific Validation — N/A

No domain runtime to validate here. Repo state is fully pinned by Level 1-3 + the canonical
artifact + the item contract + PRD §2.17.

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 run: `bash -n install.sh` exit 0; **`shellcheck -s bash install.sh` exit 0** (was 1
      on HEAD — SC1091 fixed).
- [ ] The `# shellcheck disable=SC1091` directive is present (Path A) or the file matches the
      canonical artifact (Path B).
- [ ] All 6 removed-mechanism greps find NOTHING; all addition greps match.
- [ ] `git status --short` shows ONLY `install.sh` changed by this item.

### Feature Validation

- [ ] install.sh does exactly three benign things: symlink, `pool_state_init`, doctor (contract).
- [ ] install.sh never references the deleted shim `bin/agent-browser` (contract step b).
- [ ] `--force|-f` accepted (no-op); `--help|-h` prints the benign-model help + exit 0.
- [ ] Success message (Mode A) covers: symlink created, doctor status, how to use
      `agent-browser-pool`, and uninstall (`rm -f ~/.local/bin/agent-browser-pool`).
- [ ] PRD §2.17 "no PATH shadowing / no cutover / no DISABLE / no ~/scripts" fully honored.

### Code Quality / Scope Validation

- [ ] **Only** `install.sh` is modified; no other file touched.
- [ ] `lib/pool.sh` untouched (stale shim comments @4/@7 left in place — out of scope).
- [ ] `bin/agent-browser-pool`, `bin/.gitkeep` untouched.
- [ ] `README.md`, `SKILL.md`, `references/*`, `test/*` untouched (owned by P2.M4/P2.M5/P2.M6).
- [ ] `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` untouched (read-only).
- [ ] Validation used ONLY static commands (no Chrome, no doctor run, no test suite) — AGENTS.md §1/§6.

### Documentation & Deployment

- [ ] [Mode A] install.sh's own stdout IS the install doc (success message = symlink + doctor
      status + usage + uninstall). No separate doc file written by this item.
- [ ] No new env vars introduced by install.sh (it defines none).

---

## Anti-Patterns to Avoid

- ❌ Don't assume install.sh still needs a "complete rewrite" — HEAD (`7926c44`) already did it.
      The only blocker is `shellcheck` exiting 1 (missing SC1091 directive). Fix THAT (Path A) or
      use the canonical artifact (Path B). Don't redo functional work that's already done + correct.
- ❌ Don't drop/omit the `# shellcheck disable=SC1091` directive — without it `shellcheck -s bash
      install.sh` exits 1 (reproduced on HEAD). Keep both `source=` + `disable=SC1091`.
- ❌ Don't propagate doctor's exit code as install's exit code — doctor is a diagnostic of things
      install cannot fix; the symlink + state dir succeeded. Keep exit 0. (Design D1.)
- ❌ Don't re-introduce a `FORCE=1` variable that's never read (ShellCheck SC2034). Keep `--force|-f`
      as a no-op arm (the committed version already does this correctly).
- ❌ Don't write a bare `(( doctor_ok ))` (aborts under `set -e` when 0) — always inside `if`.
- ❌ Don't check for / symlink `bin/agent-browser` — it's deleted (P2.M2.T2.S1).
- ❌ Don't "tidy" the stale shim comments in `lib/pool.sh` (lines 4, 7) — out of scope.
- ❌ Don't flag the words "shadow"/"cutover"/"interception" as regressions — the script uses them
      in negation comments intentionally. Grep for OLD MECHANISMS instead.
- ❌ Don't run install.sh, doctor, test/*.sh, or any Chrome/agent-browser command during this item
      — AGENTS.md §1 (sandbox-hang prevention). All validation is static (Level 1).
- ❌ Don't edit `README.md`/`SKILL.md`/`references/*`/`test/*` — each is owned by a downstream
      item (P2.M4/P2.M5/P2.M6).

---

## Confidence Score

**10/10** — one-pass success likelihood. The rewrite is already in HEAD (`7926c44`) and is
functionally conformant to the PRD §2.17 contract (verified: all three benign things present, all
old mechanisms absent, both flags present, Mode-A doc present, `bash -n` exit 0). The **single
open defect** — `shellcheck -s bash install.sh` exits 1 on SC1091 — is diagnosed to an exact line
and an exact one-line fix (the `# shellcheck disable=SC1091` directive), which was **verified
sufficient on the host** (adding it makes shellcheck exit 0; the canonical artifact confirms it).
Two acceptable implementation paths are specified (surgical 1-line insertion vs. full canonical
replace), both validated lint-clean. Validation is entirely static and cannot wedge the sandbox
(AGENTS.md §1). The remaining work is a literal one-line edit (or a verified file overwrite) plus
the provided static checks.
