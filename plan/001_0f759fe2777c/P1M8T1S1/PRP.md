# PRP — P1.M8.T1.S1: `install.sh` with confirmation + cutover warning + state dir setup

---

## Goal

**Feature Goal**: Create **`install.sh`** at the repo root — the deliberate, human-driven
**cutover installer** from PRD §2.17 ("install is deliberate, not automatic. `install.sh`
prints this warning and requires a confirmation flag") + §2.1 (the two symlink targets) +
§3/§h2.2 (`install.sh` lives at the repo root, sibling of `bin/`/`lib/`). It: prints a
**prominent cutover warning** (PATH shadowing is global/all-or-nothing; running agents on
the old workflow will be **silently intercepted**), **requires an exact `YES` confirmation**
(or `--force`), **symlinks** `bin/agent-browser → ~/scripts/agent-browser` (shadows
`~/.local/bin/agent-browser`) + `bin/agent-browser-pool → ~/.local/bin/agent-browser-pool`,
**pre-creates the pool state dir** (`lanes/` + `acquire.lock`), **runs `doctor`** to verify
dependencies, and prints a **success message** with TEST-FIRST (absolute-path invocation),
BYPASS (`AGENT_BROWSER_POOL_DISABLE=1`), ADMIN, and UNINSTALL guidance. Made executable
(`chmod 0755`).

**Deliverable**: ONE new file — **`install.sh`** at the repo ROOT (alongside `bin/`, `lib/`,
`PRD.md`, `README.md`), `chmod 0755`. NO other file is created or modified. (Mode A: the
script's own warning/success output IS the user-facing cutover documentation.)

**Success Definition**:
- `test -f install.sh && test -x install.sh`; `bash -n install.sh` passes;
  `shellcheck -s bash install.sh` → only **SC1091 (info)** on the dynamic `source` line (the
  ACCEPTED codebase convention — identical to `bin/agent-browser` + `bin/agent-browser-pool`),
  NO error/warning severity.
- `install.sh` sources `lib/pool.sh` symlink-safely (`readlink -f "${BASH_SOURCE[0]}"` →
  `dirname` → `cd && pwd`, mirroring the bin shims), then calls `pool_config_init` +
  `pool_state_init` from the lib.
- **Hermetic** run (`HOME=<tmp> AGENT_BROWSER_POOL_STATE=<tmp> ./install.sh --force`) → **rc 0**,
  creates `$tmp/scripts/agent-browser → <repo>/bin/agent-browser` AND
  `$tmp/.local/bin/agent-browser-pool → <repo>/bin/agent-browser-pool` (verified via `readlink`),
  creates `$tmp-state/lanes/` (dir) + `$tmp-state/acquire.lock` (file), AND `doctor` output is
  printed — **even though `doctor` itself returns rc 1 in the isolated env** (install must NOT
  abort on a non-zero doctor; the wrapper install itself succeeded).
- Confirmation gate: `printf 'YES\n' | HOME=<tmp> ./install.sh` → **rc 0** (proceeds);
  `printf 'no\n' | …` → **rc 1** ("Aborted."); `printf '' | …` (EOF) → **rc 1** ("Aborted (no
  input).") — the EOF path MUST be the guarded `||` list, NOT a raw `set -e` abort.
- `./install.sh --help` (and `-h`) → usage to **stdout**, **rc 0**; `./install.sh --bogus` →
  "unknown option" to **stderr**, **rc 1**.
- Idempotent: a second `./install.sh --force` → rc 0, symlinks unchanged (`ln -sfnv` replaces
  cleanly; `pool_state_init` mkdir/touch are idempotent).
- `bin/agent-browser`, `bin/agent-browser-pool`, `bin/.gitkeep`, `lib/pool.sh`, `.gitignore`,
  `PRD.md`, `README.md`, `tasks.json` UNCHANGED (`git status --short` shows ONLY `install.sh`
  new untracked, outside `plan/`).

## User Persona

**Target User**: The human admin performing the **cutover** (PRD §2.17) — the one person who
decides *when* the pool goes live on this host. They have running AI agents possibly mid-task
on the OLD manual workflow (`acquire.sh` + per-task `--session` + persistent profiles `1..10`).

**Use Case**: The admin has finished validating the pool by ABSOLUTE-PATH invocation (PRD §2.17:
"Develop/test before cutover … `…/bin/agent-browser …`") and is now ready to make the shadow
global. They run `./install.sh`, read the prominent cutover warning, confirm no critical agents
are mid-task, type `YES`, and the pool goes live. Later they run `./install.sh --force` to
re-install after a `git pull` (idempotent), or `rm ~/scripts/agent-browser
~/.local/bin/agent-browser-pool` to uninstall.

**User Journey**: `./install.sh` → reads the `===`-bordered "silently intercepted" warning →
checks their running agents → types `YES` → sees the symlink map + "TEST FIRST" + "BYPASS" +
"ADMIN" + "UNINSTALL" guidance → `which agent-browser` now resolves to `~/scripts/agent-browser`
(the shadow) → `agent-browser-pool status` works via the admin symlink → done.

**Pain Points Addressed**: Without an explicit, warning-gated installer, a careless `ln -s`
would silently break every running agent (their next `agent-browser` call gets intercepted →
abandons in-progress profile-3 work, PRD §2.17). The confirmation + warning make cutover a
deliberate, informed act — and the success message teaches the two escape hatches
(absolute-path testing + `AGENT_BROWSER_POOL_DISABLE=1`) so the admin is never stuck.

## Why

- **This IS PRD §2.17's cutover gate.** §2.17 is explicit: *"install is deliberate, not
  automatic. `install.sh` prints this warning and requires a confirmation flag."* Without this
  script, the pool's wrapper shim + admin CLI (M6/M7) are unreachable from the PATH — there is
  no safe way to go live. This task is the bridge from "repo exists" to "pool is the global
  `agent-browser`."
- **It is the capstone of the entire P1.M8 milestone** (the only subtask in M8). Everything
  before it (M1–M7) built `lib/pool.sh` + the two `bin/` executables; this task wires them onto
  the PATH and creates the runtime state dir, then verifies the host with `doctor`.
- **It must be unmissable about the all-or-nothing shadow.** PRD §2.17: *"There is no safe
  partial shadow — the PATH mechanism is all-or-nothing; the disable env is the only per-session
  opt-out."* A `git pull && ./install.sh --force` re-shadowing after an upgrade is fine; a casual
  `./install.sh` while agents run is the failure mode the warning + `YES` gate exist to prevent.
- **It reuses the LANDED lib (DRY), not hand-rolled paths.** `pool_config_init` (canonical
  `POOL_STATE_DIR`/`POOL_LANES_DIR`/`POOL_LOCK_FILE`, config validation, respects
  `AGENT_BROWSER_POOL_STATE`) + `pool_state_init` (the idempotent step-(e) state setup — its
  doc-comment literally names this task) give install.sh correct, override-respecting,
  shellcheck-adjacent behavior for free.
- **It must NOT duplicate/conflict with siblings.** `bin/agent-browser` (M6.T3.S2) +
  `bin/agent-browser-pool` (M7.T5.S1, in-flight) are the symlink TARGETS + the doctor binary;
  `lib/pool.sh` is sourced (not edited); `README.md`'s install section is synced by M10.T1.S1
  (this task's own stdout IS the Mode A docs). install.sh owns ONLY its single new file.

## What

User-visible behavior: **a working `install.sh`** that (1) warns prominently, (2) gates on an
exact `YES` (or `--force`), (3) creates the two PATH symlinks + the state dir, (4) runs
`doctor`, (5) prints a clear success/cutover-ops summary. For verification (no Chrome / master /
`pi` ancestor needed), the observable contract is: arg parsing, the confirmation gate, the
symlink + state creation, and doctor being invoked — all hermetically testable with a temp HOME.

### The install.sh body (verbatim contract — authoritative from item §3 + design D1–D13)

```bash
#!/usr/bin/env bash
#
# install.sh — install the agent-browser-pool cutover (PRD §2.1, §2.17).
#
# WHAT THIS DOES (a deliberate, all-or-nothing CUTOVER — read the warning):
#   1. symlinks bin/agent-browser      -> ~/scripts/agent-browser
#      (~/scripts PRECEDES ~/.local/bin on PATH -> the wrapper SHADOWS the real CLI)
#   2. symlinks bin/agent-browser-pool -> ~/.local/bin/agent-browser-pool
#   3. pre-creates the pool state dir (lanes/ + acquire.lock) via the lib
#   4. runs `doctor` to verify dependencies
#
# Mode A: this script's warning + success output IS the cutover documentation.
# Safety valve (per-session): export AGENT_BROWSER_POOL_DISABLE=1 to bypass the shadow.
set -euo pipefail

# --- resolve REPO dir (symlink-safe; mirrors bin/agent-browser bootstrap) ---
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- argument parsing ---
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            cat <<'EOF'
install.sh — install the agent-browser-pool cutover.

Once installed, bin/agent-browser is symlinked into ~/scripts/ (ahead of ~/.local/bin
on PATH), so EVERY `agent-browser` call in EVERY shell is intercepted by the wrapper.
This is ALL-OR-NOTHING; running agents on the old workflow will be silently intercepted.
The only per-session opt-out is AGENT_BROWSER_POOL_DISABLE=1.

Usage: ./install.sh [--force|-f]

  (no flag)   Print the cutover warning and require you to type YES to proceed.
  --force|-f  Skip the confirmation (re-install / scripted use).
  --help|-h   Show this help.
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

# --- stderr helper for all warnings / errors ---
warn() { printf '%s\n' "$*" >&2; }

# --- prominent cutover warning (PRD §2.17 — the exact "silently intercepted" + "all-or-nothing" sentences) ---
BAR='============================================================'
warn ""
warn "$BAR"
warn "  agent-browser-pool — CUTOVER INSTALL (read carefully)"
warn "$BAR"
warn ""
warn "  This will symlink bin/agent-browser into ~/scripts/, which is AHEAD of"
warn "  ~/.local/bin on your PATH. Once installed, the wrapper is GLOBAL and"
warn "  process-wide: EVERY 'agent-browser' call in EVERY shell resolves to it."
warn "  There is NO safe partial shadow — the PATH mechanism is all-or-nothing."
warn ""
warn "  RUNNING AGENTS WILL BE SILENTLY INTERCEPTED:"
warn "    Any agent still on the OLD manual workflow (acquire.sh + per-task"
warn "    --session + persistent profiles 1..10) will have its NEXT 'agent-browser'"
warn "    call intercepted: owner resolution finds its pi PID, the wrapper overrides"
warn "    its --session/connect args, and it lands on a fresh ephemeral lane —"
warn "    ABANDONING in-progress work on profile 3 (etc.). This BREAKS running work."
warn ""
warn "  Make sure no critical agents are mid-task before continuing. To test first"
warn "  WITHOUT installing, invoke the wrapper by ABSOLUTE PATH:"
warn "      $REPO_DIR/bin/agent-browser open https://example.com"
warn ""
warn "  Per-session bypass (old workflow / debugging):"
warn "      export AGENT_BROWSER_POOL_DISABLE=1"
warn "$BAR"
warn ""

# --- confirmation gate (unless --force) — set -e-safe (the || list harnesses read's EOF) ---
if [[ "$FORCE" != "1" ]]; then
    if ! read -r -p 'Type YES to continue: ' reply; then
        warn "Aborted (no input)."
        exit 1
    fi
    if [[ "${reply:-}" != "YES" ]]; then
        warn "Aborted."
        exit 1
    fi
fi

# --- pre-flight: the repo files we symlink + source must exist & be executable ---
for f in "$REPO_DIR/bin/agent-browser" "$REPO_DIR/bin/agent-browser-pool" "$REPO_DIR/lib/pool.sh"; do
    [[ -f "$f" ]] || { warn "install.sh: missing repo file: $f"; exit 1; }
done
[[ -x "$REPO_DIR/bin/agent-browser" ]]      || { warn "install.sh: not executable: $REPO_DIR/bin/agent-browser"; exit 1; }
[[ -x "$REPO_DIR/bin/agent-browser-pool" ]] || { warn "install.sh: not executable: $REPO_DIR/bin/agent-browser-pool"; exit 1; }

# --- source the shared lib (canonical path resolution + idempotent state init) ---
# shellcheck source=lib/pool.sh
source "$REPO_DIR/lib/pool.sh"
# Resolve canonical POOL_STATE_DIR / POOL_LANES_DIR / POOL_LOCK_FILE + validate config.
# (Normal host -> rc 0. Can pool_die on genuine misconfig — a config error SHOULD abort.)
pool_config_init

# --- target dirs (defensive, idempotent; $HOME is absolute -> never a bare ~ to a subprocess) ---
mkdir -p -- "$HOME/scripts" "$HOME/.local/bin"

# --- create the symlinks (ABSOLUTE source; -sfnv: symbolic/force/no-deref/verbose) ---
ln -sfnv -- "$REPO_DIR/bin/agent-browser"      "$HOME/scripts/agent-browser"
ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"

# --- pre-create the pool state dir (lanes/ + acquire.lock) — reuses the lib's canonical paths ---
# pool_state_init: mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE. Idempotent.
pool_state_init

# --- run doctor to verify dependencies (SUBPROCESS insulates us from its exit code / pool_die) ---
warn ""
warn "Running dependency check (doctor)..."
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    warn ""
    warn "$BAR"
    warn "  doctor found problems (see the report above). The wrapper + admin symlinks"
    warn "  and the state dir were created successfully, but one or more RUNTIME"
    warn "  dependencies are missing (e.g. chrome, the real binary, btrfs, master)."
    warn "  The pool will not work until these are fixed. Re-check with:"
    warn "      $REPO_DIR/bin/agent-browser-pool doctor"
    warn "$BAR"
else
    warn "doctor: healthy."
fi

# --- success message (Mode A: this IS the cutover documentation) — to stdout ---
printf '\n%s\n' "$BAR"
printf '  Installed agent-browser-pool.\n'
printf '%s\n' "$BAR"
printf '\n'
printf '  wrapper:  %s\n' "$HOME/scripts/agent-browser"
printf '            -> %s\n' "$REPO_DIR/bin/agent-browser"
printf '            (shadows %s/.local/bin/agent-browser)\n' "$HOME"
printf '  admin:    %s/.local/bin/agent-browser-pool\n' "$HOME"
printf '            -> %s\n' "$REPO_DIR/bin/agent-browser-pool"
printf '  state:    %s/{lanes,acquire.lock}\n' "$POOL_STATE_DIR"
printf '\n'
printf 'TEST FIRST (before relying on the shadow): invoke the wrapper by ABSOLUTE PATH to\n'
printf 'exercise all logic WITHOUT touching the PATH-resolved agent-browser that running\n'
printf 'agents use:\n'
printf '    %s/bin/agent-browser open https://example.com\n' "$REPO_DIR"
printf '\n'
printf 'BYPASS (per-session): export AGENT_BROWSER_POOL_DISABLE=1 to make THIS shell use\n'
printf 'the real %s/.local/bin/agent-browser directly (old workflow / debugging).\n' "$HOME"
printf '\n'
printf "ADMIN:  agent-browser-pool status | reap | 'release [<N>|all]' | doctor\n"
printf '\n'
printf 'UNINSTALL: rm -f %s/scripts/agent-browser %s/.local/bin/agent-browser-pool\n' "$HOME" "$HOME"
printf '\n'
```
Then `chmod 0755 install.sh`.

### Success Criteria

- [ ] `install.sh` created at the repo ROOT (NEW; `chmod 0755`); shebang `#!/usr/bin/env bash`
      + `set -euo pipefail`.
- [ ] `REPO_DIR` resolved symlink-safely via `readlink -f "${BASH_SOURCE[0]}"` → `dirname` → `cd && pwd`
      (mirrors `bin/agent-browser`).
- [ ] Arg parsing: `--force|-f` sets `FORCE=1`; `--help|-h` → usage to **stdout**, **rc 0**; unknown →
      **stderr** + **rc 1**.
- [ ] Prominent `===`-bordered cutover warning to **stderr**, reproducing PRD §2.17's "silently
      intercepted" + "all-or-nothing" + absolute-path-test + `AGENT_BROWSER_POOL_DISABLE=1` guidance.
- [ ] Confirmation gate: unless `--force`, `read -r -p 'Type YES to continue: ' reply` guarded by
      `if ! read …` (EOF-safe); exact match `[[ "${reply:-}" == "YES" ]]` required (case-sensitive).
- [ ] Pre-flight checks `bin/agent-browser` + `bin/agent-browser-pool` + `lib/pool.sh` exist + the two
      bins are executable.
- [ ] Sources `lib/pool.sh`; calls `pool_config_init` (canonical paths + config validation).
- [ ] `mkdir -p -- "$HOME/scripts" "$HOME/.local/bin"` (defensive, idempotent; `$HOME` is absolute).
- [ ] `ln -sfnv -- "$REPO_DIR/bin/agent-browser" "$HOME/scripts/agent-browser"` AND
      `ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"` (absolute source).
- [ ] Calls `pool_state_init` (creates `POOL_LANES_DIR` + `POOL_LOCK_FILE`; idempotent) — contract step (e).
- [ ] Runs `"$REPO_DIR/bin/agent-browser-pool" doctor` as a **subprocess** in `if ! …`; on rc≠0 prints a
      prominent warning but **install.sh's own rc stays 0** (does NOT abort).
- [ ] Success message to **stdout** with the symlink map + TEST-FIRST + BYPASS + ADMIN + UNINSTALL.
- [ ] `bash -n install.sh` passes; `shellcheck -s bash install.sh` → only SC1091 (info) on the `source`
      line, NO error/warning severity.
- [ ] `bin/agent-browser`, `bin/agent-browser-pool`, `bin/.gitkeep`, `lib/pool.sh`, `.gitignore`,
      `PRD.md`, `README.md`, `tasks.json` UNCHANGED.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **verbatim install.sh body** (item §3 + design
D1–D13); the **single-deliverable + repo-ROOT placement** decision (PRD §3 layout; `install.sh` is a
sibling of `bin/`/`lib/`, NOT inside `bin/`); the **two exact symlink targets** (PRD §2.1:
`~/scripts/agent-browser` shadows `~/.local/bin/agent-browser` because `/home/dustin/scripts` PRECEDES
`/home/dustin/.local/bin` on PATH — host-verified); the **confirmation-gate `set -e` gotcha** (`read`
returns non-zero on EOF → must be harnessed by `if !`/`||`, else `set -e` aborts raw); the **`ln -sf`
directory-target gotcha** (use a file-named target + `-n`); the **doctor-as-subprocess + report-don't-
abort decision** (doctor rc≠0 in isolated envs is expected; `pool_die`=exit1 means an inline call would
kill install.sh); the **state-setup-via-`pool_state_init` decision** (the lib's own doc-comment names
this task; DRY + canonical paths); the **shellcheck SC1091 convention** (info-level on dynamic `source`
is the accepted codebase norm — identical to both `bin/` shims); the **stdout/stderr split**
(`--help`+success+doctor → stdout; warnings+prompt+errors → stderr); the **`$HOME`-is-absolute**
satisfaction of PRD §2.2 ("never pass bare ~"); host-verified tooling (bash, ln, readlink, realpath, mkdir,
touch, chmod, tput all at /usr/bin); and a copy-pasteable hermetic Level-2 test (temp `HOME` +
`AGENT_BROWSER_POOL_STATE` so the real `~/scripts` + real state are never touched).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.17 (cutover — the EXACT "silently intercepted" + "all-or-nothing" + "install is deliberate"
        not automatic" + absolute-path-test + AGENT_BROWSER_POOL_DISABLE sentences install.sh reproduces).
        §2.1 (components: the two symlink targets — "~/scripts/agent-browser ← shadow wrapper
        (symlink → repo bin/; AHEAD of ~/.local/bin on PATH)" + "/home/dustin/.local/bin/agent-browser-pool
        ← admin tool (symlink → repo bin/)" + "~/.local/state/agent-browser-pool/{acquire.lock,lanes/}").
        §3/§h2.2 (repo layout: "install.sh ← symlinks bin/* onto PATH" at the ROOT). §2.2 (hard rule:
        resolve every path; never pass ~ to a subprocess — install.sh uses $HOME, never a bare ~).
  pattern: §2.17's sentences ARE the warning banner text; §2.1's targets ARE the two ln commands;
        §2.2's rule = why we pass $HOME (absolute) not ~ to mkdir/ln.
  gotcha: §2.17 — the shadow is GLOBAL/process-wide the instant the symlink lands; the warning MUST
        print BEFORE the symlink is created (it does — confirmation gate precedes the ln).

# This task's own research (THE factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M8T1S1/research/install-cutover-facts.md
  why: §1 the verbatim contract. §2 codebase facts (PATH order, greenfield targets, pool_config_init/
        pool_state_init/pool_die/pool_admin_doctor signatures + line numbers, doctor rc=1 in isolated
        envs PROVES the report-don't-abort decision). §3 external bash best-practices (read-under-set-e,
        ln -sf dir-target gotcha, warning UX, readlink -f vs realpath -m) with URLs. §4 the shellcheck
        SC1091 convention (host-verified on BOTH bin shims). §5 design decisions D1–D13. §6 validation
        approach (no harness; hermetic temp-HOME test). §7 scope boundaries.
  pattern: §5 D1–D13 ARE the install.sh body; §6 IS the Level-2 test.
  gotcha: §2 — pool_die=exit1 → doctor MUST be a subprocess (D10); pool_state_init's doc-comment names
        THIS task as the state-dir creator → call pool_state_init, don't hand-roll mkdir/touch (D9).

# The proven sibling shims (the symlink-safe bootstrap + the chmod-0755 + shellcheck-SC1091 convention)
- file: bin/agent-browser
  why: lines 1-12 are the EXACT bootstrap install.sh mirrors (shebang, set -euo pipefail, readlink -f
        "${BASH_SOURCE[0]}", dirname, source "$REAL_DIR/../lib/pool.sh"). install.sh uses the same
        readlink -f → dirname → (cd && pwd) for REPO_DIR (it needs the REPO root, not bin/, so it cd's
        one level up from dirname). chmod 0755. shellcheck emits ONLY SC1091 (info) on the source line.
  pattern: the readlink -f → dirname → source block IS install.sh's bootstrap.
  gotcha: bin/agent-browser's last line is `pool_wrapper_main "$@"` (terminal exec) — install.sh does
        NOT copy that; it ends in the success printf block. install.sh resolves to the REPO root
        (parent of bin/), so its source path is "$REPO_DIR/lib/pool.sh" (NOT "../lib/pool.sh").

- file: bin/agent-browser-pool
  why: the admin dispatcher install.sh (a) symlinks to ~/.local/bin/agent-browser-pool and (b) invokes
        for `doctor`. Its `case doctor) pool_admin_doctor ;;` wiring is what `"$REPO_DIR/bin/agent-
        browser-pool" doctor` reaches. Confirms the doctor binary exists (P1.M7.T5.S1 — present/staged).
  pattern: install.sh's doctor call target.
  gotcha: if P1.M7.T5.S1 had NOT landed, install.sh's pre-flight (`[[ -x .../bin/agent-browser-pool ]]`)
        catches it with a clear message BEFORE symlinking. (Defensive D6.)

# The LANDED lib functions install.sh sources + calls
- file: lib/pool.sh
  why: pool_config_init @126 (canonical POOL_STATE_DIR/POOL_LANES_DIR/POOL_LOCK_FILE + config validation;
        can pool_die on misconfig). pool_state_init @202 (mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE;
        idempotent; its doc-comment @191-193 LITERALLY says "or until install.sh pre-creates it — M8.T1.S1").
        pool_admin_doctor @4011 (the doctor install.sh invokes via the binary). pool_die @30 (exit 1 —
        why doctor runs as a subprocess). _pool_config_canon_path @? (realpath -m). set -euo pipefail @18.
  pattern: pool_config_init + pool_state_init ARE install.sh's path-resolution + state-setup steps.
  gotcha: pool_config_init/pool_state_init can pool_die (exit 1) on genuine misconfig — install.sh calls
        them directly (a config error SHOULD abort install); but doctor is invoked as a SUBPROCESS so a
        doctor-side pool_die cannot kill install.sh's shell. (D10.)

# Sibling PRPs (the shape to mirror — NEW top-level executable + chmod + shellcheck-SC1091-OK)
- file: plan/001_0f759fe2777c/P1M6T3S2/PRP.md
  why: bin/agent-browser (LANDED) — the EXACT "new executable at a fixed path, chmod 0755, bash -n +
        shellcheck clean (SC1091 info OK), Level-2 symlink-safety test" pattern. install.sh mirrors it
        for structure + validation (but install.sh is at the repo ROOT, not bin/).
- file: plan/001_0f759fe2777c/P1M7T5S1/PRP.md
  why: bin/agent-browser-pool (in-flight, the symlink target + doctor binary). Its dispatcher + the
        doctor wiring (`case doctor) pool_admin_doctor ;;`) confirm what install.sh invokes. Read it as
        a CONTRACT (per parallel_execution_context): assume it lands exactly as specified.

# Architecture (host facts)
- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §3 (PATH order — ~/scripts precedes ~/.local/bin; both exist + writable; no existing shadow).
        §7 (state dir layout — lanes/ + acquire.lock). §2 (all CLI deps present — what doctor verifies).
  pattern: §3 IS the shadowing mechanism install.sh relies on; §7 IS the state dir install.sh creates.
  gotcha: §3 — `which -a agent-browser` currently → ~/.local/bin/agent-browser (no shadow yet); after
        install it flips to ~/scripts/agent-browser. The Level-3 smoke verifies this flip.
```

### Current Codebase tree

After **M1–M7.T4.S1** landed + **M7.T5.S1** (in-flight: `bin/agent-browser-pool` staged +
`pool_admin_help()` appended @4267), the repo root has `bin/{agent-browser,agent-browser-pool,
.gitkeep}`, `lib/pool.sh` (4267+ lines), `PRD.md`, `README.md`, `.gitignore`, `test/.gitkeep`.
**`install.sh` does NOT exist yet. THIS task creates it at the repo ROOT:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md                             # install section synced by M10.T1.S1 (NOT this task)
├── install.sh                            # NEW (this task): the cutover installer (repo ROOT)
├── bin/
│   ├── .gitkeep                          # RETAINED
│   ├── agent-browser                     # M6.T3.S2 (wrapper shim) — UNCHANGED (symlink target #1)
│   └── agent-browser-pool                # M7.T5.S1 (admin dispatcher) — UNCHANGED (symlink target #2 + doctor)
├── lib/
│   └── pool.sh                           # UNCHANGED (SOURCED by install.sh; not edited). EOF @4267+.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M8T1S1/
        ├── PRP.md                         # THIS FILE
        └── research/install-cutover-facts.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── install.sh                            # NEW (chmod 0755; repo ROOT): the deliberate cutover installer.
                                          #   symlink-safe REPO_DIR; --force/--help; prominent §2.17
                                          #   warning to stderr; exact-YES gate; pre-flight; source lib;
                                          #   pool_config_init; mkdir targets; ln -sfnv x2; pool_state_init;
                                          #   doctor subprocess (report, don't abort); Mode-A success to stdout.
```

**File responsibilities**:
- `install.sh` — the cutover gate + PATH wiring + state bootstrap + host verification. Owns NO pooling
  logic: it reuses `pool_config_init` (paths/config) + `pool_state_init` (state dir) + invokes
  `bin/agent-browser-pool doctor` (host check). Its printed output (warning + success) is the Mode A
  user-facing cutover documentation.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the confirmation-gate set -e gotcha): under `set -euo pipefail` a BARE `read -r -p … reply`
#   returns non-zero on EOF (Ctrl-D)/closed stdin and ABORTS the script (raw set -e) BEFORE the equality
#   check runs. POSIX exempts non-final members of `||`/`&&` lists + `if` conditions from set -e, so the
#   FIX is `if ! read -r -p '…' reply; then …; exit 1; fi` (then `[[ "${reply:-}" == YES ]] || {…; exit 1;}`).
#   The Level-2 test pipes '' (EOF) and asserts rc 1 + the "Aborted (no input)." message (NOT a raw abort).

# CRITICAL (doctor MUST be a subprocess, NOT an inline pool_admin_doctor call): pool_die @lib/pool.sh:30
#   is `printf … >&2; exit 1`. pool_admin_doctor calls pool_config_init + pool_state_init, EITHER of which
#   can pool_die on genuine misconfig → an INLINE call would EXIT install.sh's whole shell mid-install.
#   Worse, doctor itself returns rc 1 whenever FAIL>0 — which in an isolated/ partial host (missing master/
#   binary under a temp HOME) is EXPECTED (prototype run: OK=9 WARN=1 FAIL=2, rc 1). So: run
#   `"$REPO_DIR/bin/agent-browser-pool" doctor` in `if ! …; then <warn> fi`, and keep install.sh's OWN rc
#   at 0 (the wrapper/admin/state succeeded; doctor flags ORTHOGONAL runtime deps). NEVER abort install on
#   doctor rc≠0. (research §2, §5-D10.)

# CRITICAL (the ln -sf directory-target gotcha): if the symlink TARGET is an EXISTING DIRECTORY, `ln -sf
#   src target` creates the link INSIDE it (target/basename(src)) rather than erroring — `-f` does NOT
#   prevent this. FIX: always use a full FILE-NAMED target (`"$HOME/scripts/agent-browser"`, never bare
#   `"$HOME/scripts"`) AND add `-n` (--no-dereference) so a pre-existing symlink-to-dir target is replaced,
#   not dereferenced. Use `ln -sfnv` (-s -f -n -v). ABSOLUTE source ("$REPO_DIR/bin/…"). Idempotent.
#   (research §3, §5-D8.)

# CRITICAL (state setup = pool_state_init, NOT hand-rolled mkdir/touch): pool_state_init @lib/pool.sh:202
#   does `mkdir -p -- "$POOL_LANES_DIR"` + `touch -- "$POOL_LOCK_FILE"` with CANONICAL paths (resolved by
#   pool_config_init via realpath -m). Its doc-comment @191-193 LITERALLY names this task: "the state dir
#   does NOT exist until first run (or until install.sh pre-creates it — M8.T1.S1)". Calling pool_state_init
#   is DRY + override-respecting (honors AGENT_BROWSER_POOL_STATE). Do NOT hand-roll
#   `mkdir -p ~/.local/state/agent-browser-pool/lanes; touch acquire.lock` — that hardcodes the default
#   path and ignores overrides. (research §2, §5-D9.)

# CRITICAL (install.sh is at the REPO ROOT, not bin/): PRD §3 layout shows `install.sh` as a SIBLING of
#   bin/ + lib/. REPO_DIR resolves to the repo root (parent of bin/), so the source path is
#   "$REPO_DIR/lib/pool.sh" (NOT "../lib/pool.sh" as in the bin shims, which resolve to bin/ then go ../lib).
#   The symlink sources are "$REPO_DIR/bin/agent-browser" + "$REPO_DIR/bin/agent-browser-pool" (absolute).

# CRITICAL (PRD §2.2: never pass bare ~ to a subprocess): `~` is only expanded by the SHELL in certain
#   contexts, NOT by `ln`/`mkdir`. install.sh uses "$HOME" (which is absolute: /home/dustin) everywhere —
#   `mkdir -p -- "$HOME/scripts"` and `ln -sfnv -- "$REPO_DIR/…" "$HOME/scripts/agent-browser"`. NEVER
#   write `ln -s … ~/scripts/agent-browser` (the literal ~ would be passed to ln → broken). pool_config_init
#   further canonicalizes via realpath -m. (research §3, §5-D7.)

# GOTCHA (shellcheck SC1091 (info) is EXPECTED + ACCEPTED): `shellcheck -s bash install.sh` emits ONE
#   info: SC1091 "Not following: …lib/pool.sh was not specified as input" on the dynamic `source` line.
#   This is IDENTICAL to `shellcheck -s bash bin/agent-browser` + `bin/agent-browser-pool` (host-verified)
#   and is the accepted codebase convention. Validation passes if there are NO error/warning-severity
#   issues (SC1091 info is fine). Equivalently: `shellcheck --exclude=SC1091 -s bash install.sh` → clean.
#   (research §4.)

# GOTCHA (stdout vs stderr split): `--help` + the success summary + doctor's own output → STDOUT (positive
#   result; capturable: `./install.sh --force | tee`). The cutover WARNING banner + the `read -p` prompt
#   (read writes its prompt to stderr) + the doctor-fail warning + all errors → STDERR. This is the
#   conventional split; `./install.sh --force 2>&1 | tee install.log` captures both in order.

# GOTCHA (install.sh's OWN rc is 0 even when doctor rc≠0): the wrapper/admin symlinks + state dir are the
#   install's deliverables; doctor is a host-health CHECK, orthogonal to whether the install succeeded.
#   Returning rc 0 (with a prominent stderr warning when doctor fails) keeps `--force` scriptable + matches
#   "the install itself worked; verify deps separately". (research §5-D10.)

# GOTCHA (read -p prompt destination): bash `read -p 'prompt'` writes the prompt to STDERR (not stdout).
#   So the confirmation prompt co-locates with the stderr warning banner — consistent. If a user redirects
#   stderr they won't see the prompt, but `read` still consumes stdin; the gate still works. (research §3.)

# GOTCHA (re-install / idempotency): `ln -sfnv` replaces an existing symlink cleanly; `mkdir -p` +
#   `touch` (via pool_state_init) are idempotent; `pool_config_init` is re-runnable (MUTABLE globals, no
#   init-guard). So `./install.sh --force` after a `git pull` re-points the symlinks at the new bins +
#   re-asserts the state dir, rc 0. (research §5.)

# GOTCHA (UNINSTALL is a one-liner, NOT a script): the success message prints `rm -f
#   ~/scripts/agent-browser ~/.local/bin/agent-browser-pool` (PRD §2.17: the disable env is the only
#   per-SESSION opt-out; full removal = delete the two symlinks). No uninstall.sh is in scope.
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk layout change beyond the new
`install.sh` file + the runtime symlinks/state it creates (the symlinks + state dir are
INSTALL-TIME artifacts, not repo files), and NO new env vars. `install.sh` defines three
script-local vars (`REPO_DIR`, `FORCE`, `reply`) + reuses the lib's `POOL_STATE_DIR` for the
success message. All pooling state/env is owned by `pool_config_init`/`pool_state_init`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the symlink targets exist
  - RUN: test -f lib/pool.sh && test -f bin/agent-browser && test -f bin/agent-browser-pool \
        && test -f bin/.gitkeep && echo "OK layout"
  - EXPECT: all exist (bin/agent-browser-pool from P1.M7.T5.S1 — staged/present).
  - RUN (confirm this task is greenfield — NO existing install.sh):
        test -e install.sh && echo "STOP: install.sh exists" || echo "OK: install.sh greenfield"
  - EXPECT: OK: install.sh greenfield.
  - RUN (confirm install.sh is NOT inside bin/ — it is a repo-ROOT sibling):
        test -e bin/install.sh && echo "STOP: wrong placement" || echo "OK: not in bin/"
  - EXPECT: OK: not in bin/.
  - RUN (confirm the lib functions install.sh sources + calls are defined):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_config_init pool_state_init; do type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; done; \
          echo "OK config/state fns defined"'
  - EXPECT: OK config/state fns defined (both LANDED @126/@202).
  - RUN (confirm doctor is reachable via the admin binary):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_admin_doctor >/dev/null && echo "OK doctor defined"'
        grep -q 'case' bin/agent-browser-pool && grep -q 'doctor' bin/agent-browser-pool && echo "OK doctor wired in dispatcher"
  - EXPECT: OK doctor defined + wired (pool_admin_doctor @4011; dispatcher `case doctor)`).
  - RUN (confirm the symlink-safe bootstrap pattern — mirror it for REPO_DIR):
        sed -n '1,12p' bin/agent-browser
  - EXPECT: shebang + set -euo pipefail + readlink -f "${BASH_SOURCE[0]}" + dirname + source.
  - RUN (host tooling + PATH-shadow precondition):
        bash --version | head -1
        for t in ln readlink realpath mkdir touch chmod; do command -v "$t" >/dev/null && echo "$t OK" || echo "$t MISSING"; done
        # PATH-shadow precondition (system_context §3): ~/scripts precedes ~/.local/bin
        : "${HOME:?HOME unset}"
        test -d "$HOME/scripts" && test -d "$HOME/.local/bin" && echo "OK target dirs exist"
        # prove ~/scripts precedes ~/.local/bin on PATH:
        case ":$PATH:" in *":$HOME/scripts:"*":$HOME/.local/bin:"*) echo "OK scripts precedes local/bin" ;; *) echo "WARN: PATH order unexpected (shadow may not work)" ;; esac
  - EXPECT: bash 5.x; all tools OK; target dirs exist; scripts precedes local/bin.
  - RUN (confirm shellcheck SC1091 is the ONLY emission on the existing bin shims — the convention):
        shellcheck -s bash bin/agent-browser 2>&1 | grep -E 'SC[0-9]+' | sort -u
  - EXPECT: only SC1091 (info). This is what install.sh's source line will emit too.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not break existing syntax — it only SOURCES the lib).

Task 1: CREATE install.sh (the verbatim body, executable, at the repo ROOT)
  - PLACEMENT: install.sh (NEW file at the REPO ROOT — sibling of bin/, lib/, PRD.md, README.md).
        NOT inside bin/.
  - IMPLEMENT: paste the verbatim body from the "What → The install.sh body" section above, EXACTLY
        (shebang + header comment + set -euo pipefail + REPO_DIR resolution + arg parse [--force/--help/
        unknown] + warn() + the === cutover banner to stderr + the if-!-read confirmation gate + pre-flight
        for/[[ -x ]] + source "$REPO_DIR/lib/pool.sh" + pool_config_init + mkdir -p targets + ln -sfnv x2 +
        pool_state_init + the if-!-doctor subprocess + the stdout success block). Then `chmod 0755 install.sh`.
  - MAKE EXECUTABLE: chmod 0755 install.sh
  - NOTE on the `# shellcheck source=lib/pool.sh` directive: it is a HINT for editors/`shellcheck -x`;
        `shellcheck -s bash install.sh` (without -x) still emits SC1091 (info) on the dynamic source —
        that is ACCEPTED (matches both bin shims). Do NOT add `# shellcheck disable=SC1091` unless you
        want a fully-silent run; the convention is to tolerate the info.
  - VERIFY (immediately after):
        bash -n install.sh && echo "OK syntax"
        shellcheck -s bash install.sh; echo "(SC1091 info on the source line is ACCEPTED — matches bin/*)"
        test -x install.sh && echo "OK executable"
        test -f bin/.gitkeep && echo "OK .gitkeep retained"
        git status --short | grep -qvE '^\?\? install.sh$|plan/' && echo "STOP: unexpected change!" || echo "OK only install.sh new"
  - EXPECT: OK syntax; shellcheck shows at most SC1091 (info); OK executable; .gitkeep retained;
        git status shows ONLY install.sh (untracked) outside plan/.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY `install.sh` (new untracked) outside plan/ (plan/ changes are this PRP + research).
        bin/agent-browser, bin/agent-browser-pool, bin/.gitkeep, lib/pool.sh, .gitignore, PRD.md,
        README.md, tasks.json, prd_snapshot.md UNCHANGED. NO uninstall.sh, NO bin/install.sh.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe REPO_DIR (mirror bin/agent-browser, but resolve to the REPO root not bin/):
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
#   readlink -f canonicalizes install.sh (handles ./install.sh, bash install.sh, symlinks);
#   dirname → the dir containing install.sh = the repo ROOT; cd && pwd → absolute. Source path is
#   "$REPO_DIR/lib/pool.sh" (the bin shims use "../lib/pool.sh" because they live IN bin/ — install.sh
#   does NOT, so it does not need the ../).

# PATTERN — set -e-safe confirmation gate (THE gotcha):
if [[ "$FORCE" != "1" ]]; then
    if ! read -r -p 'Type YES to continue: ' reply; then      # EOF/Ctrl-D → read rc 1 → branch taken
        warn "Aborted (no input)."; exit 1
    fi
    if [[ "${reply:-}" != "YES" ]]; then                       # EXACT, case-sensitive match
        warn "Aborted."; exit 1
    fi
fi
#   The `if !` harnesses read's failure so set -e does NOT abort raw. `${reply:-}` defends set -u if
#   read somehow left reply unset (it won't, but defensive).

# PATTERN — the symlinks (ABSOLUTE source, file-named target, -sfnv):
mkdir -p -- "$HOME/scripts" "$HOME/.local/bin"                 # defensive + idempotent; $HOME is absolute
ln -sfnv -- "$REPO_DIR/bin/agent-browser"      "$HOME/scripts/agent-browser"
ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"
#   -s symbolic, -f force (replace existing), -n no-deref (safe vs a symlink-to-dir target), -v verbose.
#   NEVER `ln … ~/scripts/agent-browser` (bare ~ is passed literally to ln → broken). Use "$HOME/...".

# PATTERN — state setup via the lib (NOT hand-rolled):
pool_config_init        # canonical POOL_STATE_DIR/POOL_LANES_DIR/POOL_LOCK_FILE + config validation
pool_state_init         # mkdir -p POOL_LANES_DIR + touch POOL_LOCK_FILE (idempotent; canonical paths)
#   This IS contract step (e). pool_state_init's doc-comment @lib/pool.sh:191-193 names THIS task.

# PATTERN — doctor as a subprocess, report-don't-abort:
if ! "$REPO_DIR/bin/agent-browser-pool" doctor; then
    warn "<prominent: doctor found problems; wrapper installed; re-check with … doctor>"
fi
#   install.sh's OWN rc stays 0 (the if-! only WARNS). A subprocess insulates us from doctor's pool_die/exit
#   + its rc 1 in isolated envs. (research §5-D10.)

# GOTCHA — WHY if-! read (not bare read): bare `read` under set -e aborts on EOF before the match check.
#   (research §3, Greg's Wiki BashFAQ/105.)
# GOTCHA — WHY ln -sfnv (not ln -sf): a file-named target + -n avoids the directory-target gotcha.
#   (research §3, coreutils ln manual.)
# GOTCHA — WHY pool_state_init (not mkdir/touch): the lib's canonical paths + override-respect + the
#   doc-comment literally assigns this task the state-dir-creation responsibility. (research §2/§5-D9.)
# GOTCHA — WHY doctor is a subprocess (not inline pool_admin_doctor): pool_die=exit1 would kill install.sh;
#   + doctor rc 1 is expected in partial hosts. (research §2/§5-D10.)
# GOTCHA — WHY stdout for success / stderr for warnings: conventional; `2>&1 | tee` captures both.
#   (research §5-D13.)
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "install.sh (NEW; chmod 0755; REPO ROOT — sibling of bin/, lib/, PRD.md, README.md).
            Verbatim body from the 'What' section."

PATH (the cutover — runtime, not repo):
  - symlink: "$HOME/scripts/agent-browser -> <repo>/bin/agent-browser   (SHADOWS ~/.local/bin/agent-browser;
            ~/scripts precedes ~/.local/bin on PATH — system_context §3, host-verified)"
  - symlink: "$HOME/.local/bin/agent-browser-pool -> <repo>/bin/agent-browser-pool   (admin tool on PATH)"

STATE (runtime, not repo — created by install.sh via the lib):
  - dir:    "$POOL_STATE_DIR/lanes/   (mkdir -p via pool_state_init; canonical; honors
            AGENT_BROWSER_POOL_STATE)"
  - file:   "$POOL_STATE_DIR/acquire.lock   (touch via pool_state_init)"

LIBRARY (lib/pool.sh — SOURCED, not edited):
  - sources: "install.sh does 'source "$REPO_DIR/lib/pool.sh"' → joins bin/agent-browser +
            bin/agent-browser-pool as the THIRD consumer (header lines 5-6 name the first two)."
  - calls:   "pool_config_init @126 (paths/config) + pool_state_init @202 (state dir). Invokes
            pool_admin_doctor @4011 INDIRECTLY via the admin binary subprocess."

GITIGNORE:
  - no change: "no rule matches install.sh (it is a tracked repo file). .gitignore is orchestrator-owned
            (M10.T1.S2)."

NO CHANGES TO:
  - bin/agent-browser (M6.T3.S2), bin/agent-browser-pool (M7.T5.S1), bin/.gitkeep (retained),
    lib/pool.sh (sourced, not edited), .gitignore, PRD.md / tasks.json / prd_snapshot.md (read-only),
    README.md install section (M10.T1.S1 syncs it — install.sh's OWN output is the Mode A docs),
    test/ (M9.T1.S1 builds the harness). NO uninstall.sh in scope (UNINSTALL is a printed one-liner).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating install.sh + chmod 0755 — fix before proceeding.
bash -n install.sh && echo "OK bash -n"
shellcheck -s bash install.sh; echo "(SC1091 info on the dynamic source line is ACCEPTED — matches bin/agent-browser + bin/agent-browser-pool; host-verified)"
test -x install.sh && echo "OK executable"
# Equivalently, a fully-silent shellcheck run (excludes the accepted info):
shellcheck --exclude=SC1091 -s bash install.sh && echo "OK shellcheck (--exclude=SC1091)"
# Confirm ONLY install.sh is new (no collateral edits):
git status --short | grep -vE 'plan/|^\?\? install.sh$' && echo "STOP: unexpected change" || echo "OK only install.sh new"
# Expected: OK bash -n; shellcheck shows at most SC1091 (info); OK executable; only install.sh new.
#   SC2155 does NOT fire (REPO_DIR/FORCE/reply are plain top-level/script vars, not local). SC2086
#   satisfied by quoting "$REPO_DIR/...", "$HOME/...", "${BASH_SOURCE[0]}", "${reply:-}".
```

### Level 2: Functional Tests (HERMETIC — no Chrome/master/pi needed; temp HOME + state)

install.sh is testable WITHOUT Chrome / a master profile / a real `pi` ancestor — it only needs
the LANDED lib + the two bin executables. **The test uses a temp `HOME` + temp
`AGENT_BROWSER_POOL_STATE` so it NEVER touches the real `~/scripts`, `~/.local/bin/agent-browser-pool`,
or the real `~/.local/state/agent-browser-pool`.**

```bash
# Save as /tmp/test_install.sh and run: bash /tmp/test_install.sh
# Run from the REPO ROOT (where install.sh + bin/ + lib/ live).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/install.sh" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# Fresh hermetic env per test group.
mkhome() {  # echo a fresh tmp HOME + tmp STATE (space-sep)
    local h s; h="$(mktemp -d)"; s="$(mktemp -d)/state/agent-browser-pool"
    mkdir -p "$h/scripts" "$h/.local/bin"
    echo "$h $s"
}

# --- Case 1 (structure): executable + bash -n + shellcheck (SC1091 info OK) ---
bash -n install.sh && test -x install.sh \
    && shellcheck --exclude=SC1091 -s bash install.sh \
    && ok "structure: executable + bash -n + shellcheck clean (SC1091 excluded)" \
    || bad "structure"

# --- Case 2 (verbatim contract lines present) ---
grep -q 'readlink -f "\${BASH_SOURCE\[0\]}"' install.sh \
    && grep -q 'source "\$REPO_DIR/lib/pool\.sh"' install.sh \
    && grep -q 'pool_config_init' install.sh && grep -q 'pool_state_init' install.sh \
    && grep -q 'ln -sfnv -- "\$REPO_DIR/bin/agent-browser"[[:space:]]*"\$HOME/scripts/agent-browser"' install.sh \
    && grep -q 'ln -sfnv -- "\$REPO_DIR/bin/agent-browser-pool"[[:space:]]*"\$HOME/.local/bin/agent-browser-pool"' install.sh \
    && grep -q 'Type YES to continue:' install.sh \
    && grep -q 'AGENT_BROWSER_POOL_DISABLE' install.sh \
    && grep -q 'silently intercepted\|SILENTLY INTERCEPTED' install.sh \
    && ok "contract: verbatim lines present (bootstrap, ln -sfnv x2, gate, bypass, warning)" \
    || bad "contract: a required line is missing/wrong"

# --- Case 3 (--help -> stdout, rc 0; BEFORE any warning/confirm) ---
out="$(./install.sh --help 2>/dev/null)" && echo "$out" | grep -q 'Usage: ./install.sh' \
    && echo "$out" | grep -q -- '--force' \
    && ok "--help -> usage to stdout, rc 0" \
    || bad "--help"
# -h alias too:
./install.sh -h >/dev/null 2>&1 && ok "-h alias -> rc 0" || bad "-h alias"

# --- Case 4 (unknown option -> stderr, rc 1) ---
if ./install.sh --bogus >/dev/null 2>/dev/null; then bad "unknown-opt: expected rc 1"; \
else ok "unknown-opt -> rc 1"; fi

# --- Case 5 (--force: creates symlinks + state, runs doctor, install rc 0 EVEN IF doctor rc 1) ---
read H S <<<"$(mkhome)"
out_err="$(HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force 2>&1 >/tmp/i_out)" ; rc=$?
[[ $rc -eq 0 ]] && ok "--force install rc 0" || bad "--force rc (got $rc)"
# symlink correctness (the SHADOW + the admin):
[[ "$(readlink "$H/scripts/agent-browser")" == "$REPO/bin/agent-browser" ]] && ok "wrapper symlink -> repo/bin/agent-browser" || bad "wrapper symlink"
[[ "$(readlink "$H/.local/bin/agent-browser-pool")" == "$REPO/bin/agent-browser-pool" ]] && ok "admin symlink -> repo/bin/agent-browser-pool" || bad "admin symlink"
# state dir created (via pool_state_init; canonical, under the override $S):
[[ -d "$S/lanes" && -f "$S/acquire.lock" ]] && ok "state dir created: \$S/lanes + acquire.lock" || bad "state dir"
# doctor was invoked (its report in the merged output):
grep -q '\[summary\]' /tmp/i_out && ok "doctor ran (printed [summary])" || bad "doctor not run"
# install rc stayed 0 even though doctor rc!=1 in this isolated env (no master/binary under temp HOME):
if grep -q 'doctor found problems' <<<"$out_err"; then ok "doctor rc!=0 -> WARNED but install rc 0 (report-don't-abort)"; \
else ok "doctor rc 0 in this env -> 'doctor: healthy.' (either path is correct)"; fi
# success message to stdout:
grep -q 'Installed agent-browser-pool' /tmp/i_out && grep -q 'UNINSTALL' /tmp/i_out && ok "success message (Mode A docs) to stdout" || bad "success message"
rm -rf "$H" "$S" /tmp/i_out

# --- Case 6 (confirmation gate: YES -> proceeds, rc 0) ---
read H S <<<"$(mkhome)"
if printf 'YES\n' | HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh >/dev/null 2>&1; then
    [[ "$(readlink "$H/scripts/agent-browser")" == "$REPO/bin/agent-browser" ]] && ok "gate: 'YES' -> proceeds + symlink created" || bad "gate YES (no symlink)"
else bad "gate: 'YES' should proceed (rc 0)"; fi
rm -rf "$H" "$S"

# --- Case 7 (confirmation gate: wrong answer -> 'Aborted.', rc 1; NO symlink created) ---
read H S <<<"$(mkhome)"
if printf 'no\n' | HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh >/dev/null 2>&1; then
    bad "gate: 'no' should abort (rc 1)"
else
    [[ ! -e "$H/scripts/agent-browser" ]] && ok "gate: 'no' -> rc 1 + NO symlink created" || bad "gate 'no' (symlink created anyway)"
fi
rm -rf "$H" "$S"

# --- Case 8 (confirmation gate: EOF / no input -> 'Aborted (no input).', rc 1; NOT a raw set -e abort) ---
read H S <<<"$(mkhome)"
if printf '' | HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh >/dev/null 2>/tmp/eof_err; then
    bad "gate: EOF should abort (rc 1)"
else
    grep -q 'Aborted (no input)' /tmp/eof_err && ok "gate: EOF -> rc 1 + 'Aborted (no input).' (if-!-read harness, NOT raw set -e)" || bad "gate EOF (wrong/no message)"
fi
rm -rf "$H" "$S" /tmp/eof_err

# --- Case 9 (idempotency: --force twice -> stable symlinks, rc 0) ---
read H S <<<"$(mkhome)"
HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force >/dev/null 2>&1
ln1="$(readlink "$H/scripts/agent-browser")"
HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force >/dev/null 2>&1 && rc=$? || rc=$?
ln2="$(readlink "$H/scripts/agent-browser")"
[[ $rc -eq 0 && "$ln1" == "$ln2" ]] && ok "idempotency: --force twice -> rc 0, stable symlink" || bad "idempotency"
rm -rf "$H" "$S"

# --- Case 10 (pre-flight: missing bin/agent-browser-pool -> clear error, rc 1, NO symlink) ---
# Temporarily hide bin/agent-browser-pool (rename) to simulate P1.M7.T5.S1 not-yet-landed.
if [[ -f bin/agent-browser-pool ]]; then
    mv bin/agent-browser-pool bin/agent-browser-pool.hidden
    read H S <<<"$(mkhome)"
    if HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force >/tmp/pf_out 2>/tmp/pf_err; then
        bad "pre-flight: should fail when bin/agent-browser-pool missing"
    else
        grep -q 'missing repo file' /tmp/pf_err && [[ ! -e "$H/scripts/agent-browser" ]] \
            && ok "pre-flight: missing bin -> clear 'missing repo file' + rc 1 + NO symlink" \
            || bad "pre-flight message/behavior"
    fi
    rm -rf "$H" "$S" /tmp/pf_out /tmp/pf_err
    mv bin/agent-browser-pool.hidden bin/agent-browser-pool   # RESTORE
else
    ok "pre-flight: (skipped — bin/agent-browser-pool already absent)"
fi

# --- Cleanup ---
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≈14, fail=0. Case 5's doctor-WARN/healthy branch both count as PASS (either proves the
#   report-don't-abort wiring). Case 10 only runs if bin/agent-browser-pool exists (it restores it).
```

### Level 3: Integration Testing (System Validation — the REAL cutover, manual)

The real cutover touches the LIVE `~/scripts` + `~/.local/bin` + the real state dir + needs a Chrome +
master profile for doctor to pass. It is a **manual, human-driven** act (that is the WHOLE POINT of the
confirmation gate). Once a master profile exists + the admin has read the warning:

```bash
# 1. (optional, RECOMMENDED first) Test the wrapper by ABSOLUTE PATH — no PATH mutation:
"$PWD/bin/agent-browser" open https://example.com   # exercises all wrapper logic; running agents unaffected
# 2. The deliberate cutover (interactive — read the warning, type YES):
./install.sh                                         # → prominent banner → 'Type YES to continue:' → YES
# 3. Verify the shadow is now global:
which agent-browser                                  # EXPECT: /home/dustin/scripts/agent-browser  (was ~/.local/bin/agent-browser)
readlink "$(which agent-browser)"                    # EXPECT: /home/dustin/projects/agent-browser-pool/bin/agent-browser
# 4. Verify the admin tool is on PATH + works via its own symlink:
which agent-browser-pool                             # EXPECT: /home/dustin/.local/bin/agent-browser-pool
agent-browser-pool status                            # → "No active lanes." (fresh state)
agent-browser-pool doctor                            # → [summary] Healthy. (master 4.8GB + real binary present on the real host)
# 5. Bypass sanity (per-session, old workflow / debug):
AGENT_BROWSER_POOL_DISABLE=1 agent-browser session list   # → routes to the REAL ~/.local/bin/agent-browser
# 6. Uninstall (full removal — PRD §2.17 says removal = delete the two symlinks):
rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool
which agent-browser                                  # EXPECT: back to /home/dustin/.local/bin/agent-browser
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Transparency (PRD §2.17) spot-checks (the cutover contract install.sh enforces):
#   [ ] `./install.sh` (interactive, real HOME) prints the === banner BEFORE creating any symlink
#       (the warning precedes the ln) — verify by reading the script order OR by interrupting at the
#       prompt and confirming NO ~/scripts/agent-browser was created.
#   [ ] The banner reproduces PRD §2.17's "silently intercepted" + "all-or-nothing" sentences
#       (grep install.sh for them).
#   [ ] `./install.sh --help` documents the cutover + the disable env (Mode A).
#   [ ] After install, `AGENT_BROWSER_POOL_DISABLE=1 agent-browser …` bypasses (Level 3 step 5).
# Robustness — invoke install.sh via several forms (all resolve REPO_DIR symlink-safe):
( cd "$REPO" && bash install.sh --help >/dev/null 2>&1 && echo "PASS: 'bash install.sh'" ) || echo "FAIL"
( cd "$REPO" && ./install.sh -h >/dev/null 2>&1 && echo "PASS: './install.sh'" ) || echo "FAIL"
( cd /tmp && bash "$REPO/install.sh" --help >/dev/null 2>&1 && echo "PASS: by absolute path from another cwd" ) || echo "FAIL"
# Re-install-after-upgrade simulation (idempotent re-shadow):
read H S <<<"$(mktemp -d)/h $(mktemp -d)/s"; mkdir -p "$H/scripts" "$H/.local/bin"
HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force >/dev/null 2>&1
# "upgrade" = rewrite a marker in the repo bin (simulate git pull); re-install re-points the symlink:
HOME="$H" AGENT_BROWSER_POOL_STATE="$S" ./install.sh --force 2>&1 | grep -q "Installed agent-browser-pool" \
    && echo "PASS: re-install after upgrade -> rc 0 + re-asserts symlinks" || echo "FAIL"
rm -rf "$H" "$S"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n install.sh` passes; `shellcheck -s bash install.sh` → only SC1091
      (info); `test -x install.sh` passes; `git status` shows ONLY `install.sh` new (outside plan/).
- [ ] Level 2 Cases 1-2 (structure, verbatim contract) PASS.
- [ ] Level 2 Cases 3-4 (`--help`/`-h` → stdout rc 0; unknown opt → stderr rc 1) PASS.
- [ ] Level 2 Case 5 (**`--force` hermetic install**: symlinks resolve to repo bins, state dir created,
      doctor ran, **install rc 0 even when doctor rc 1**) PASS — the single most important check.
- [ ] Level 2 Cases 6-8 (**confirmation gate**: `YES`→rc 0+symlink; `no`→rc 1+no symlink; **EOF→rc 1+
      "Aborted (no input)." via the if-!-read harness, NOT raw set -e**) PASS.
- [ ] Level 2 Case 9 (idempotency: `--force` twice → stable symlink, rc 0) PASS.
- [ ] Level 2 Case 10 (pre-flight: missing `bin/agent-browser-pool` → clear error, rc 1, no symlink) PASS.

### Feature Validation

- [ ] `install.sh` exists at the repo ROOT, executable (`chmod 0755`), contains the verbatim body.
- [ ] Prominent `===` cutover warning to **stderr** reproduces PRD §2.17 (silently intercepted +
      all-or-nothing) + absolute-path-test + `AGENT_BROWSER_POOL_DISABLE=1`.
- [ ] Confirmation gate requires EXACT `YES` (case-sensitive) unless `--force`; EOF-safe (if-!-read).
- [ ] Two `ln -sfnv` symlinks with ABSOLUTE sources + file-named `$HOME/...` targets.
- [ ] State dir created via `pool_state_init` (canonical `POOL_LANES_DIR` + `POOL_LOCK_FILE`).
- [ ] `doctor` runs as a **subprocess**; install rc stays 0 regardless of doctor rc.
- [ ] Success message to **stdout** (Mode A docs): symlink map + TEST-FIRST + BYPASS + ADMIN + UNINSTALL.
- [ ] `bin/agent-browser`, `bin/agent-browser-pool`, `bin/.gitkeep`, `lib/pool.sh`, `.gitignore`,
      `PRD.md`, `README.md`, `tasks.json` UNCHANGED.

### Code Quality Validation

- [ ] Follows the codebase shebang convention (`#!/usr/bin/env bash` — matches `lib/pool.sh:1` + the bin shims).
- [ ] Strict mode (`set -euo pipefail`) declared in install.sh AND re-asserted by the lib on source.
- [ ] Anti-patterns avoided: no bare `read` under set -e (if-!-read harness); no bare `~/…` to subprocesses
      (`$HOME` only); no inline `pool_admin_doctor` (subprocess for insulation); no hand-rolled state mkdir/touch
      (`pool_state_init`); no `ln -sf` without `-n`/file-named target; no abort on doctor rc≠0.
- [ ] Self-documenting (header comment + the `--help` output + the warning banner + the success summary all
      serve as the Mode A cutover documentation; satisfies the item's DOCS step).

### Documentation & Deployment

- [ ] install.sh's printed output (warning + success) IS the cutover documentation (Mode A).
- [ ] No new env vars; no `.gitignore` change; no `lib/pool.sh` edit (sourced only); no `README.md` edit
      (M10.T1.S1 syncs the README install section separately).
- [ ] README.md's existing "Install (planned): `./install.sh` …" line now matches reality (validated by
      M10.T1.S1; out of scope here).

---

## Anti-Patterns to Avoid

- ❌ Don't use a BARE `read -r -p … reply` under `set -euo pipefail` — EOF/Ctrl-D makes `read` return
  non-zero and set -e aborts the script RAW (no "Aborted" message, no clean exit). Harness it with
  `if ! read …; then …; exit 1; fi` (the Level-2 Case 8 EOF test catches the bare-read regression).
- ❌ Don't run `pool_admin_doctor` INLINE — `pool_die` (= `exit 1`) inside its config/state init would kill
  install.sh's whole shell mid-install, AND doctor legitimately returns rc 1 in partial hosts (missing
  master/binary). Run `"$REPO_DIR/bin/agent-browser-pool" doctor` as a SUBPROCESS in `if ! …; then <warn>`,
  and keep install.sh's OWN rc at 0. (Level-2 Case 5 proves this.)
- ❌ Don't hand-roll `mkdir -p ~/.local/state/agent-browser-pool/lanes; touch acquire.lock` — that hardcodes
  the default path + ignores `AGENT_BROWSER_POOL_STATE` overrides. Call `pool_state_init` (canonical paths;
  its doc-comment literally names this task). (research §5-D9.)
- ❌ Don't write `ln -s … ~/scripts/agent-browser` (bare `~`) — `~` is NOT expanded by `ln`; it'd be passed
  literally and break. Use `"$HOME/scripts/agent-browser"` (`$HOME` is absolute). (PRD §2.2.)
- ❌ Don't use `ln -sf` without a file-named target + `-n` — if the target is an existing directory (or a
  symlink to a dir), `ln -sf` creates the link INSIDE it. Always target a full file name + `-n`. (research §3.)
- ❌ Don't make install.sh ABORT on a non-zero `doctor` — the wrapper/admin/state are the deliverables; doctor
  is an orthogonal host check. Print a prominent warning + let install rc stay 0. (research §5-D10.)
- ❌ Don't place `install.sh` inside `bin/` — PRD §3 shows it at the repo ROOT (sibling of `bin/`/`lib/`).
  REPO_DIR resolves to the root; source path is `"$REPO_DIR/lib/pool.sh"` (not `../lib/pool.sh`).
- ❌ Don't print the cutover warning to stdout (it'd interleave with the success summary + pollute
  `./install.sh --force | tee` logs). Warnings + the prompt → STDERR; success + doctor output + `--help` → STDOUT.
- ❌ Don't print the warning AFTER creating the symlinks — the WHOLE point (PRD §2.17) is the warning + gate
  PRECEDE the PATH mutation. Order: warn → confirm → (pre-flight) → symlinks.
- ❌ Don't add `# shellcheck disable=SC1091` as a hack — SC1091 (info) on the dynamic `source` is the ACCEPTED
  codebase convention (identical to both bin shims); tolerate it. (`--exclude=SC1091` is fine for a silent run.)
- ❌ Don't edit `bin/agent-browser`, `bin/agent-browser-pool`, `lib/pool.sh`, `.gitignore`, `PRD.md`,
  `README.md`, or `tasks.json` — out of scope / owned by other tasks / humans. The ONLY deliverable is `install.sh`.
- ❌ Don't create an `uninstall.sh` — UNINSTALL is the printed one-liner `rm -f ~/scripts/agent-browser
  ~/.local/bin/agent-browser-pool` (PRD §2.17: the disable env is the per-session opt-out; full removal = delete
  the two symlinks). No uninstall script is in scope.
