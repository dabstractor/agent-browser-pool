# install.sh — Cutover Installer: Research Facts & Design Decisions (P1.M8.T1.S1)

Consolidates direct codebase recon + the external bash best-practices brief. The PRP
at `../PRP.md` consumes this. Host-verified 2026-07-13.

---

## 1. The contract (item §3, authoritative)

INPUT: repo dir (where install.sh lives). Optional `--force` flag.
LOGIC (install.sh):
  a. Print PROMINENT WARNING about PATH shadowing being all-or-nothing.
  b. Print WARNING about running agents being silently intercepted.
  c. Unless `--force`: prompt `'Type YES to continue:'`, require EXACT match.
  d. Create symlinks:
       `ln -sf <repo>/bin/agent-browser      ~/scripts/agent-browser`
       `ln -sf <repo>/bin/agent-browser-pool ~/.local/bin/agent-browser-pool`
  e. Create state dir: `mkdir -p ~/.local/state/agent-browser-pool/lanes`, `touch acquire.lock`.
  f. Run doctor to verify dependencies.
  g. Print success message (testing-by-absolute-path + bypass `AGENT_BROWSER_POOL_DISABLE=1`).
  h. Make install.sh executable.
OUTPUT: install.sh that safely sets up the pool + prints clear guidance.
DOCS: [Mode A] install.sh itself IS user-facing documentation — prompts/warnings ARE the cutover docs.

PRD selectors: §2.17 (cutover), §2.1 (components + symlink targets), §3/§h2.2 (repo layout:
`install.sh` lives at repo ROOT alongside `bin/`, `lib/`).

## 2. Codebase facts (host-verified)

- **PATH order** (system_context §3): `/home/dustin/scripts` PRECEDES `/home/dustin/.local/bin`.
  Confirmed live: `~/scripts` and `~/.local/bin` both exist + WRITABLE. So a symlink at
  `~/scripts/agent-browser` shadows the real `~/.local/bin/agent-browser` (which is ITSELF a
  symlink → node_modules binary; `which -a agent-browser` → `/home/dustin/.local/bin/agent-browser`).
- **Greenfield install targets**: `~/scripts/agent-browser` does NOT exist; `~/.local/bin/agent-browser-pool`
  does NOT exist. No existing install.sh / uninstall script anywhere (`find . -name 'install*.sh'` → none
  outside plan/).
- **`install.sh` placement**: repo ROOT (PRD §3 layout: `install.sh` sibling of `bin/`, `lib/`).
  `REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"` resolves it symlink-safe
  (mirrors `bin/agent-browser` line 8 + the staged `bin/agent-browser-pool`).
- **`bin/agent-browser`** (M6.T3.S2, LANDED): 12-line symlink-safe shim → sources `lib/pool.sh` →
  `pool_wrapper_main "$@"` (terminal exec). `chmod +x`. The thing install.sh symlink #1 points at.
- **`bin/agent-browser-pool`** (P1.M7.T5.S1 — STAGED/present now): symlink-safe admin dispatcher →
  `pool_config_init` + `pool_state_init` + `case` dispatch to `pool_admin_{status,reap,release,doctor,help}`.
  Default verb `status`; unknown → stderr + exit 1. The thing install.sh symlink #2 points at + the
  doctor binary install.sh invokes.
- **`lib/pool.sh`** (4267+ lines, LANDED): the shared lib. install.sh is a THIRD consumer (sources it
  for `pool_config_init` + `pool_state_init`; header lines 5-6 name bin/agent-browser + bin/agent-browser-pool
  as consumers — install.sh joins them).
  - `pool_config_init` @126: resolves `$HOME` via `realpath`, then canonicalizes every path via
    `_pool_config_canon_path` (→ `realpath -m`). Sets globals incl. `POOL_STATE_DIR`, `POOL_LANES_DIR`,
    `POOL_LOCK_FILE`, `POOL_REAL_BIN`, `POOL_MASTER_DIR`, `POOL_EPHEMERAL_ROOT`. Validates numerics
    (`_pool_config_require_uint` → pool_die on non-digit); enforces `PORT_RANGE>0`. **Can `pool_die`
    (= exit 1) on genuine misconfig; normal host → rc 0.** MUTABLE globals → re-runnable.
  - `pool_state_init` @202: `mkdir -p -- "$POOL_LANES_DIR"` + `touch -- "$POOL_LOCK_FILE"`. IDEMPOTENT
    (no "if exists" guard — cheap + correct on every call). Its doc-comment EXPLICITLY says install.sh
    (M8.T1.S1) pre-creates the state dir via it: *"the state dir does NOT exist until first run (or until
    install.sh pre-creates it — M8.T1.S1)"*. → **install.sh step (e) = call `pool_state_init`** (reuses the
    lib's canonical paths + idempotent mkdir/touch — DRY; do NOT hand-roll `mkdir lanes`/`touch lock`).
  - `pool_die` @30: `printf '%s\n' "$*" >&2; exit 1`. → **If install.sh called `pool_admin_doctor` INLINE
    and doctor's config_init hit a pool_die, install.sh's WHOLE SHELL would exit.** → **Run doctor as a
    SUBPROCESS** (`"$REPO_DIR/bin/agent-browser-pool" doctor`) to insulate (D11).
  - `pool_admin_doctor` @4011: config+state init → `[dependencies] flock setsid pgrep pkill cp curl jq
    + chrome + notify-send(optional)` → `[binary] $POOL_REAL_BIN` → `[filesystem] btrfs (non-fatal replica
    of pool_check_btrfs; WARN if non-btrfs+ALLOW_SLOW_COPY, FAIL if non-btrfs)` → `[master] $POOL_MASTER_DIR
    exists+non-empty` → `[lanes] reconcile` → `[dirs] orphan` → `[summary] OK=N WARN=N FAIL=N` + "Healthy."/"Problems found.".
    **Returns 1 if FAIL>0, else 0.** WARN never affects rc.
  - `set -euo pipefail` is at **lib/pool.sh:18** (re-asserted into install.sh's shell on source).
- **Doctor rc on isolated test envs**: prototype run with `HOME=<tmp>` + `AGENT_BROWSER_POOL_STATE=<tmp>`
  + `AGENT_CHROME_ALLOW_SLOW_COPY=1` → `doctor rc=1` (master+binary missing under temp HOME → FAIL=2,
    filesystem non-btrfs → WARN=1). On the REAL host (master 4.8GB + real binary present) doctor → rc 0.
    **CONFIRMS install must NOT abort on doctor rc≠0** (D11): the wrapper/admin install itself succeeds;
    doctor flags orthogonal runtime deps.

## 3. External bash best-practices (researcher brief, URL-cited)

- **`read` under `set -e`**: `read` returns non-zero on EOF/Ctrl-D. POSIX exempts non-final members of
  `&&`/`||` lists + `if` conditions from `set -e`. → Guard with `read -r -p '...' reply || { ...; exit 1; }`
  OR `if ! read ...; then ...; exit 1; fi`. Then exact-match `[[ "${reply:-}" == "YES" ]] || { ...; exit 1; }`.
  Docs: POSIX `set -e` (2.25); Greg's Wiki BashFAQ/105; bash manual `read`.
- **`ln -sf` directory-target gotcha**: if `target` is an EXISTING DIRECTORY, `ln -sf src target` creates
  the link INSIDE it (`target/basename(src)`) — `-f` does NOT prevent this. Fix: ALWAYS use a full
  FILE-NAMED target (`~/scripts/agent-browser`, never bare `~/scripts`); add `-n` (`--no-dereference`) so
  an existing symlink-to-dir target is replaced, not dereferenced. **Use `ln -sfnv`** (`-s -f -n -v`).
  Idempotent (re-run replaces cleanly). GNU coreutils `ln`; BSD/macOS also support `-n` (host is GNU/Linux).
- **Prominent warning UX**: bordered multi-line banner; color via `tput` gated on `[[ -t 2 ]]` (NEVER rely
  on color alone). Prior art: Homebrew `install.sh` (`ohai`/`warn`/`odie`), rustup cutover notice.
  Docs: POSIX `tput`; Greg's Wiki BashFAQ/037. (For THIS script a plain ASCII `===` banner to stderr is
  sufficient + pipe-safe — no ANSI needed; see D4.)
- **`readlink -f` vs `realpath -m`**: `readlink -f` requires all components to EXIST (free existence check
  under set -e); `realpath -m` resolves even non-existent paths. For install.sh's REPO_DIR (install.sh
  exists) + target dirs (must exist), `readlink -f` is correct. (pool_config_init uses `realpath -m` via
  `_pool_config_canon_path` for state paths — that's the lib's concern, not install.sh's.) Host HAS both
  `realpath` (with `-m`) + `readlink` (GNU).

## 4. shellcheck convention (host-verified)

`shellcheck -s bash bin/agent-browser` + `bin/agent-browser-pool` BOTH emit ONLY **SC1091 (info)** on the
dynamic `source "$…/lib/pool.sh"` line ("Not following: … was not specified as input"). This is INFO
severity, not error/warning, and is the ACCEPTED codebase convention (the M6/M7 PRPs call it "zero
warnings" — SC1091 info is tolerated). → install.sh's `source "$REPO_DIR/lib/pool.sh"` will emit the SAME
SC1091 info; it is acceptable. Validation: `shellcheck -s bash install.sh` → NO error/warning severity
(SC1091 info expected). Equivalently `shellcheck --exclude=SC1091 -s bash install.sh` → clean.

## 5. Design decisions (baked into the PRP)

- **D1 (symlink-safe REPO_DIR)**: `REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"`.
  Mirrors bin/agent-browser's bootstrap. install.sh may be invoked as `./install.sh`, `bash install.sh`,
  or by absolute path — all resolve to the canonical repo root.
- **D2 (source the lib for path resolution + state init)**: `source "$REPO_DIR/lib/pool.sh"`. Gives
  install.sh `pool_config_init` (canonical POOL_STATE_DIR/POOL_LANES_DIR/POOL_LOCK_FILE + config validation)
  + `pool_state_init` (the step-e state setup). DRY + respects `AGENT_BROWSER_POOL_STATE` override.
- **D3 (arg parsing)**: `--force`/`-f` → skip confirmation. `--help`/`-h` → usage to STDOUT, rc 0 (before
  any warning/confirm). Unknown → stderr + exit 1. (install.sh's own --help is Mode A docs.)
- **D4 (prominent banner, ASCII, stderr)**: a `===`-bordered multi-line warning reproducing PRD §2.17's
  exact "silently intercepted" + "all-or-nothing" sentences. Printed to STDERR (conventional for warnings;
  `read -p`'s prompt also goes to stderr → consistent). NO ANSI color (pipe-safe; banner shape carries the
  prominence; color is optional/gated). Printed BEFORE the confirmation gate.
- **D5 (confirmation gate, set -e-safe)**: unless `--force`, `read -r -p 'Type YES to continue: ' reply ||
  { ...; exit 1; }` then `[[ "${reply:-}" == "YES" ]] || { ...; exit 1; }`. EXACT match (case-sensitive).
  EOF/Ctrl-D → "Aborted (no input)." + exit 1 (NOT a raw set -e abort — the `||` list harnesses it).
- **D6 (pre-flight before source)**: verify `bin/agent-browser`, `bin/agent-browser-pool`, `lib/pool.sh`
  exist + the two bins are executable BEFORE sourcing/ symlinking. Clear `pool_die`-style message + exit 1
  if missing (e.g. P1.M7.T5.S1 not yet landed when install.sh is first run). Defensive.
- **D7 (target dirs, never bare ~)**: `mkdir -p -- "$HOME/scripts" "$HOME/.local/bin"` (idempotent,
  defensive). `$HOME` is absolute (`/home/dustin`) → satisfies PRD §2.2 "never pass bare ~ to a subprocess".
  (`$HOME` itself is the shell's expansion, not a `~` literal passed to `ln`/`mkdir`.)
- **D8 (symlinks, `ln -sfnv`, ABSOLUTE source)**: `ln -sfnv -- "$REPO_DIR/bin/agent-browser"
  "$HOME/scripts/agent-browser"` + `ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool"
  "$HOME/.local/bin/agent-browser-pool"`. `-s` symbolic, `-f` force, `-n` no-deref (safe vs a pre-existing
  symlink-to-dir target), `-v` verbose (transparency). Source is absolute (REPO_DIR). Re-runnable (idempotent).
- **D9 (state setup = pool_state_init)**: `pool_state_init` (NOT hand-rolled mkdir/touch). Creates
  `$POOL_LANES_DIR` + `$POOL_LOCK_FILE` with canonical paths, idempotently. This IS contract step (e).
- **D10 (doctor as subprocess; report, do NOT abort — THE key decision)**: `"$REPO_DIR/bin/agent-browser-pool"
  doctor` in an `if ! …; then` block. Captures rc; prints its (stdout) report; on rc≠0 prints a prominent
  "doctor found problems — wrapper installed but verify deps" warning to stderr. **install.sh's OWN rc stays
  0** (the wrapper + admin symlinks + state succeeded; doctor flags orthogonal runtime deps). Rationale: the
  prototype proved doctor returns 1 in isolated/ partial hosts but the install of the wrapper itself is
  correct; the user fixes deps + re-runs doctor. Subprocess (not inline `pool_admin_doctor`) insulates
  install.sh from any `pool_die`/`exit` inside doctor/config_init. (Alternative: inline call — REJECTED,
  pool_die-exit risk.)
- **D11 (success message, Mode A docs, stdout)**: prints the symlink map (wrapper/admin/state paths),
  TEST-FIRST guidance (invoke wrapper by ABSOLUTE PATH), BYPASS (`export AGENT_BROWSER_POOL_DISABLE=1`),
  ADMIN commands (`agent-browser-pool status|reap|'release [<N>|all]'|doctor`), UNINSTALL one-liner
  (`rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool`). To STDOUT (positive result).
- **D12 (chmod 0755)**: the install.sh FILE is created executable (`chmod 0755 install.sh`). Matches
  bin/agent-browser + bin/agent-browser-pool. (A script can't meaningfully chmod-itself during its first run;
  this is a deliverable-time step.)
- **D13 (stdout/stderr split)**: `--help` + success summary + doctor output → STDOUT. Cutover warning banner +
  confirmation prompt + doctor-fail warning + all errors → STDERR. Capturable: `./install.sh --force 2>&1 | tee`.

## 6. Validation approach (no existing harness; test/ is empty — only .gitkeep)

No test framework exists (M9.T1.S1 builds the bats harness later). install.sh is validated by:
- **Level 1**: `bash -n` + `shellcheck -s bash` (SC1091 info OK) + `test -x`.
- **Level 2 (HERMETIC functional test)**: run install.sh with `HOME=<mktemp -d>` +
  `AGENT_BROWSER_POOL_STATE=<mktemp -d>` so the test NEVER touches the real `~/scripts` or real state.
  Assert: `--force` rc 0 + symlinks resolve to repo bins + state dir/lock created + doctor output present;
  confirmation gate: stdin="YES"→rc 0, stdin="no"→rc 1, stdin="" (EOF)→rc 1; `--help`→stdout rc 0; unknown
  opt→stderr rc 1; idempotency: run `--force` twice → stable symlinks, rc 0. (Prototype run already proved
  the install flow + the doctor-via-symlink path work.)
- **Level 3 (real cutover smoke, manual)**: real interactive `./install.sh` (type YES) → `which
  agent-browser` flips to `~/scripts/agent-browser` → `agent-browser-pool status` works via the admin symlink.
  (Out of scope to automate; this is the human cutover.)

## 7. Scope boundaries (do NOT touch)

- `bin/agent-browser` (M6.T3.S2), `bin/agent-browser-pool` (M7.T5.S1), `bin/.gitkeep` — RETAINED/unchanged.
- `lib/pool.sh` — unchanged (install.sh SOURCES it; does not append).
- `.gitignore` (orchestrator-owned, M10.T1.S2), `PRD.md`/`tasks.json`/`prd_snapshot.md` (read-only).
- `README.md` install section (M10.T1.S1 syncs it) — install.sh's OWN output is the Mode A docs; README
  sync is a separate task.
- The ONLY deliverable: `install.sh` (repo root, NEW, chmod 0755). Plus this research file.
