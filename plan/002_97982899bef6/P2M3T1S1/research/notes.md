# Research Notes — P2.M3.T1.S1: Complete rewrite of install.sh

**Item**: Complete rewrite of install.sh — no PATH shadowing, no cutover.
**Dependency / starting state**: P2.M2 complete (bin/agent-browser DELETED by the parallel
P2.M2.T2.S1; bin/agent-browser-pool is the sole entry point with `*) pool_wrapper_main "$@"`
dispatch already in place from P2.M2.T1.S1). lib/pool.sh is the POST-P2.M1 version (DISABLE
removed, no-pi-ancestor fail-fast, `_pool_preflight_real_bin` present).
**Scope**: ONE file — `install.sh`. Nothing else touched.

---

## 0. ⚠️ DISCOVERY (supersedes the “current = 221-line cutover” premise in §1 below)

`git log -- install.sh` shows the rewrite was **already performed** and is in HEAD:

```
7926c44 Replace cutover installer with benign setup      ← HEAD (NEW benign install.sh)
05853c1 Add deliberate cutover installer with YES gate   ← the old 221-line cutover version
```

The **current** `install.sh` on disk (== HEAD, **105 lines**, `git status` clean) is **already
the benign, no-shadow installer** — NOT the 221-line cutover version described in §1. Verified
against the contract: all three benign things present (symlink / `pool_state_init` / doctor
subprocess); all OLD mechanisms absent (`AGENT_BROWSER_POOL_DISABLE`, `~/scripts`, `Type YES`,
`command -v agent-browser`, `_path_parts`, `warn()`); both flags present; Mode-A success message
present; `bash -n` exit 0; never references the deleted shim.

**The ONE open defect**: `shellcheck -s bash install.sh` **exits 1** with `SC1091` (info) on
`source "$REPO_DIR/lib/pool.sh"` (line 60). The committed file has `# shellcheck source=lib/pool.sh`
(line 59) but is **MISSING** `# shellcheck disable=SC1091`. → **contract step l fails.**

**Fix (verified on host)**: insert one directive line between `source=` and `source`:

```bash
# shellcheck source=lib/pool.sh
# shellcheck disable=SC1091   # source path is dynamic; lib/pool.sh verified present above
source "$REPO_DIR/lib/pool.sh"
```

With both directives, `shellcheck -s bash install.sh` exits 0 (verified). The canonical artifact
in the PRP (87 lines) embeds this fix and additionally aligns wording with PRD §2.17 (“shadowing”);
it is behavior-identical to the committed version.

**Implication for the PRP**: the “complete rewrite” is essentially DONE. The remaining
deliverable is (1) the one-line SC1091 fix (Path A, surgical) or a full canonical replace
(Path B), and (2) conformance verification. §1–§7 below remain accurate as *background* on what
the OLD cutover installer contained and why each element was removed — but the “current state”
in §1 describes the pre-`7926c44` file, not HEAD.

---

## 1. The CURRENT install.sh (221 lines — the thing being replaced)

Path: `install.sh` (repo root). Verified by reading it in full. It implements the OLD cutover
model. EVERY element below is REMOVED in the rewrite (contract item step k — "NO ~/scripts
symlink. NO PATH-ordering check. NO cutover warning. NO confirmation gate. NO
AGENT_BROWSER_POOL_DISABLE references"):

- `set -euo pipefail` (line 21) — **KEEP** (the new script also uses strict mode).
- REPO_DIR resolution: `REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"`
  (line 24) — **KEEP** (contract step a: "same pattern as current").
- Arg loop with `--force|-f` → sets `FORCE=1`, `--help|-h` → help + exit 0, `*` → error + exit 1
  (lines 27-54) — **KEEP the flag shape** (contract steps i + j), but FORCE becomes a no-op.
- `warn()` helper → stderr (line 57) — **REMOVE** (no warnings needed in the benign installer).
- Big cutover warning block (lines 61-85) — **REMOVE**.
- YES confirmation gate via `read -r -p 'Type YES to continue: ' reply` (lines 88-97) — **REMOVE**.
- Pre-flight loop checking THREE files incl. `bin/agent-browser` + two `-x` checks (lines 100-104) —
  **REPLACE** with a TWO-file check (bin/agent-browser-pool + lib/pool.sh); do NOT check
  bin/agent-browser (contract step b: it's deleted).
- `source lib/pool.sh` + `pool_config_init` (lines 108-112) — **KEEP** (contract step c).
- `mkdir -p "$HOME/scripts" "$HOME/.local/bin"` (line 115) — **REPLACE** with `mkdir -p
  "$HOME/.local/bin"` only (no ~/scripts).
- TWO symlinks: `ln -sfnv .../bin/agent-browser ~/scripts/agent-browser` AND
  `ln -sfnv .../bin/agent-browser-pool ~/.local/bin/agent-browser-pool` (lines 118-119) —
  **REPLACE** with ONE symlink (agent-browser-pool only). Keep `-sfnv` flags + `--`.
- PATH-ordering verification block (~lines 122-185) — **REMOVE entirely**.
- `pool_state_init` (line 189) — **KEEP** (contract step f).
- `warn "Running dependency check (doctor)..."` + `if ! "$REPO_DIR/bin/agent-browser-pool"
  doctor; then ... else ... fi` (lines 193-205) — **KEEP the subprocess pattern** (contract step g).
- Success message block (lines 207-230) — **REPLACE** with a simple success message (contract
  steps h + DOCS): symlink created, doctor status, how to use agent-browser-pool, uninstall.

**Net**: from 221 lines → ~50-70 lines. The rewrite deletes ~150 lines of cutover/PATH logic.

### What the OLD script's help text says (to be replaced)
The old `--help` text describes the cutover ("all-or-nothing", "EVERY agent-browser call ...
intercepted", "AGENT_BROWSER_POOL_DISABLE=1 to bypass"). The new help must describe the benign
model (no shadowing, no cutover).

---

## 2. bin/agent-browser-pool — the SOLE entry point (CONTRACT, post P2.M2)

Path: `bin/agent-browser-pool` (25 lines). Read in full. It already reflects the NEW model
(P2.M2.T1.S1 is done in the working tree):

```bash
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) pool_wrapper_main "$@" ;;
esac
```

**Why this matters for install.sh**: `bin/agent-browser-pool doctor` is a SUBPROCESS that:
(1) re-sources pool.sh, (2) re-runs pool_config_init + pool_state_init (its own step "a"), (3)
dispatches `doctor` → `pool_admin_doctor`. So calling it from install.sh is self-contained and
insulated (its exit code / any `pool_die` does NOT abort the install.sh shell). This is exactly
why the contract specifies a subprocess (`$REPO_DIR/bin/agent-browser-pool doctor`), not a direct
`pool_admin_doctor` function call.

---

## 3. lib/pool.sh — the THREE functions install.sh calls directly

All three verified by reading their definitions. Sourcing lib/pool.sh is SAFE: the ONLY
top-level executable statement in the whole file is `set -euo pipefail` (line 18); everything
else is comments + function definitions (confirmed via `awk` scan — the only non-comment,
non-blank, top-level line is line 18). No acquire/launch/log side effect fires on `source`.

### 3a. pool_config_init  (lib/pool.sh:131)
- Validates `$HOME` is set + resolvable (`realpath -- "$HOME"`); `pool_die` otherwise.
- Freezes ALL POOL_* globals via `declare -g`: `POOL_HOME_DIR`, `POOL_STATE_DIR`,
  `POOL_MASTER_DIR`, `POOL_EPHEMERAL_ROOT`, `POOL_REAL_BIN`, `POOL_CHROME_BIN`,
  `POOL_PORT_BASE`, `POOL_PORT_RANGE`, `POOL_WAIT`, `POOL_HEADLESS`, `POOL_ALLOW_SLOW_COPY`,
  `POOL_LANES_DIR`, `POOL_LOCK_FILE`.
- Returns 0 on a normal host. `pool_die`s (exit 1) on genuine misconfig (bad $HOME, bad uint
  env override, PORT_RANGE<=0). **A config error SHOULD abort install** — do not guard it.
- **Why install.sh calls it**: (1) to validate $HOME before we `mkdir`/`ln` under it;
  (2) to freeze `POOL_STATE_DIR` (and `POOL_LANES_DIR`/`POOL_LOCK_FILE`) in the install.sh
  shell so `pool_state_init` works AND so the success message can print the state dir path.

### 3b. pool_state_init  (lib/pool.sh:209)
```bash
pool_state_init() {
    mkdir -p -- "$POOL_LANES_DIR" \
        || pool_die "pool_state_init: cannot create lanes dir: $POOL_LANES_DIR"
    touch -- "$POOL_LOCK_FILE" \
        || pool_die "pool_state_init: cannot create lock file: $POOL_LOCK_FILE"
    return 0
}
```
- Idempotent (`mkdir -p` + `touch`). Silent on success.
- This is EXACTLY PRD §2.17's "pre-creates the pool state dir (lanes/ + acquire.lock)".
- PRECONDITION: `pool_config_init` must have run (to freeze POOL_LANES_DIR/POOL_LOCK_FILE).

### 3c. pool_admin_doctor  (lib/pool.sh:4330) — invoked via subprocess only
- Its OWN step "a" calls `pool_config_init` + `pool_state_init` (redundant with install.sh's
  calls — harmless, idempotent).
- Runs checks: `[dependencies]` (flock/setsid/pgrep/pkill/cp/curl/jq/findmnt/ss + chrome +
  optional notify-send), `[binary]` (POOL_REAL_BIN -f -x), `[filesystem]` (btrfs via
  `findmnt -T`), `[master]` (POOL_MASTER_DIR -d + non-empty), `[lanes]`, `[dirs]`, `[summary]`.
- **Return code**: `return 0` if FAIL==0 ("Healthy."), `return 1` if FAIL>0 ("Problems found.").
  WARN never affects rc. Prints the full report to STDOUT.
- **NOTE**: doctor currently checks the real binary's EXECUTABILITY, not its `--version` (PRD
  §2.16 marks the version check as a future improvement). install.sh just runs doctor as-is.

---

## 4. Design decisions for the rewrite (locked, justified)

**D1 — doctor is run as a SUBPROCESS and its failure does NOT abort install (exit 0).**
Rationale: (a) contract step g literally says `$REPO_DIR/bin/agent-browser-pool doctor` (a
subprocess); (b) PRD §2.17 frames install as "three benign things" of which doctor is item 3 —
doctor is a *diagnostic*, and the things it checks (real binary present, Chrome, btrfs, master)
are NOT things install can create or fix; (c) the OLD install.sh already did exactly this
(`if ! doctor; then warn; else warn "healthy"; fi` — never `exit`); (d) the symlink + state dir
were created successfully regardless. So: capture doctor's rc in `doctor_ok`, print
"healthy"/"found problems" in the success message, and exit 0. **This is deliberate; do not
"improve" it by propagating doctor's rc** (a scripted caller gets a clear printed report).

**D2 — `--force|-f` is accepted but a NO-OP.**
Rationale: contract step i ("skip nothing — there's no confirmation to skip, but keep it for
backward compat / scripted use"). Implemented as an empty case arm with a comment, NOT a
`FORCE` variable (avoids ShellCheck SC2034 "unused variable"). Both `--force` and `-f` accepted.

**D3 — `--help|-h` prints the new (benign) help text and exits 0.**
Mirrors the old help arm; content describes the no-shadow model + flags + uninstall.

**D4 — install.sh calls `pool_config_init` IN ITS OWN SHELL (not just via the doctor subprocess).**
Needed to (a) validate $HOME before mkdir/ln, (b) freeze POOL_STATE_DIR for pool_state_init +
the success message. (pool_config_init is idempotent + cheap; the doctor subprocess re-runs it
harmlessly.)

**D5 — pre-flight checks exactly TWO repo files; does NOT check bin/agent-browser.**
Contract step b. Checks `$REPO_DIR/bin/agent-browser-pool` (`-f` + `-x`) and
`$REPO_DIR/lib/pool.sh` (`-f` + `-r`). The deleted shim is never referenced.

**D6 — strict mode + set -e guards.**
`set -euo pipefail` at top. doctor guarded by `if ! ...; then` (condition-list → errexit-
exempt, so doctor's `return 1` does NOT abort). `(( doctor_ok ))` only ever appears inside an
`if` (errexit-exempt — mirrors pool_admin_doctor's own `if (( fail > 0 ))`). All `||`-guarded
checks use explicit error messages to stderr + `exit 1`.

---

## 5. Static validation (the ONLY validation — AGENTS.md §1 forbids live runs)

Per AGENTS.md §1/§2, planning/validation here is STATIC ONLY. The contract step l mandates:
```bash
bash -n install.sh           # syntax (never blocks)
shellcheck -s bash install.sh  # lint (never blocks)
```
- `bash` is present (host runs bash 5.x).
- `shellcheck` 0.11.0 verified at `/usr/bin/shellcheck`. No `.shellcheckrc` in the repo, so
  `shellcheck -s bash install.sh` is the exact command (the `-s bash` matches the `# shellcheck
  shell=bash`-equivalent forcing the shebang-less... install.sh HAS a `#!/usr/bin/env bash`
  shebang, so `-s bash` is belt-and-suspenders; either form works).

**NOT done here (and must NOT be done during planning)**: actually executing install.sh,
running doctor, booting Chrome, or running `test/*.sh`. The downstream `test/validate.sh` +
`test/transparency.sh` (P2.M5) will exercise install in an ISOLATED sandbox later.

---

## 6. Dependency / scope map (what touches what — anti-scope-creep)

- **install.sh** — the ONLY file this item writes (complete rewrite in place).
- **bin/agent-browser-pool** — READ only (pre-flight `-x` check + doctor subprocess target).
  UNTOUCHED by this item (owned by P2.M2; already in its post-M2.T1 form).
- **lib/pool.sh** — SOURCED + 3 functions CALLED; UNTOUCHED. (Stale comments @4 + @7 mention
  the deleted shim — those are P2.M1-region doc cruft, out of scope. Do NOT tidy.)
- **bin/agent-browser** — assumed DELETED (P2.M2.T2.S1, parallel). install.sh never references it.
- **PRD.md, plan/**/prd_snapshot.md, plan/**/tasks.json, .gitignore** — READ-ONLY, never touched.
- **README.md, SKILL.md, references/*, test/*** — UNTOUCHED (owned by P2.M4/P2.M5/P2.M6).
- **Operator's real $HOME** (~/.local/bin/agent-browser, state dir, running Chrome) — NEVER
  touched during planning/validation. install.sh creates ONE symlink + state dir, but we don't
  RUN it here.

---

## 7. DOCS requirement (Mode A) — the success message IS the install doc

Per item DOCS + PRD §2.17 + §2.15 (Mode A): install.sh's OWN stdout IS the install
documentation. The success message MUST tell the user:
1. the symlink was created — print `$HOME/.local/bin/agent-browser-pool -> $REPO_DIR/bin/agent-browser-pool`;
2. doctor status — "healthy." or "found problems (see report above)";
3. how to use `agent-browser-pool` — a short USAGE block (status / doctor / open <url> /
   release / help);
4. uninstall — `rm -f ~/.local/bin/agent-browser-pool`.

Also desirable (informative, not strictly required): the state dir path (`$POOL_STATE_DIR`).
