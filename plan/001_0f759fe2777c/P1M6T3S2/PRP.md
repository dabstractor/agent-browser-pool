# PRP — P1.M6.T3.S2: `bin/agent-browser` executable — source `lib/pool.sh` via symlink-safe path

---

## Goal

**Feature Goal**: Create the thin executable entry point **`bin/agent-browser`** that turns
the repo into the transparent PATH-shadowing wrapper described in PRD §2.1 / §2.17. Its
entire job is six statements: enable strict mode → resolve its OWN real path through any
symlink chain → `source` the shared library → hand control to `pool_wrapper_main "$@"`.
When `install.sh` (M8.T1.S1, not yet built) symlinks this file to `~/scripts/agent-browser`
(ahead of `~/.local/bin` on `PATH`), every `agent-browser` call in every shell resolves to
it; this shim sources `lib/pool.sh` and delegates, so the pooling lifecycle (acquire → boot
→ ensure → force-session → exec) — all implemented in P1.M6.T3.S1's `pool_wrapper_main` —
fires for driving commands while meta / human-terminal / `POOL_DISABLE` calls pass through
unchanged to the real `~/.local/bin/agent-browser`.

**Deliverable**: ONE new file — **`bin/agent-browser`** — containing the verbatim contract
below, made executable (`chmod 0755`). It is the **sibling consumer** of P1.M6.T3.S1's
`pool_wrapper_main()` (lib-only). This task is **bin-only**: it touches NO function in
`lib/pool.sh`, NO `tasks.json`, NO `PRD.md`, NO `.gitignore`, NO `install.sh`. `bin/.gitkeep`
stays in place (the admin CLI `bin/agent-browser-pool` is M7.T5.S1).

**Success Definition** — after this task, `bin/agent-browser`:

1. **Exists and is executable**: `test -x bin/agent-browser` passes.
2. **Is shellcheck/syntax-clean**: `bash -n bin/agent-browser` and
   `shellcheck -s bash bin/agent-browser` report ZERO warnings (same bar as `lib/pool.sh`).
3. **Sources the lib and reaches `pool_wrapper_main`** — verifiable WITHOUT Chrome by setting
   `AGENT_BROWSER_POOL_DISABLE=1` (passthrough) + a STUBBED `AGENT_BROWSER_REAL`, invoking the
   shim, and asserting the stub received the ORIGINAL argv verbatim:
   `./bin/agent-browser --session evil open https://example.com` → stub sees `--session evil
   open https://example.com` (disable short-circuits before strip/force).
4. **Resolves its path symlink-safely** — the distinguishing check: invoke the shim THROUGH a
   symlink in a *different* temp directory (simulating `~/scripts/agent-browser →
   <repo>/bin/agent-browser`), with `AGENT_BROWSER_POOL_DISABLE=1` + stub, and assert the stub
   still receives the ORIGINAL argv. If the shim used bare `dirname "$0"` (no `readlink -f`),
   `source <tempdir>/../lib/pool.sh` would miss and `set -e` would abort → test fails.
5. **Leaves `lib/pool.sh` byte-identical**: `git diff --stat lib/pool.sh` shows no change from
   T3.S1's landed state. This task appends/edits nothing in the library.
6. **`bin/.gitkeep` retained**: `test -f bin/.gitkeep` still passes (the admin tool isn't built
   yet; removing the placeholder is out of scope and pointless).

## User Persona

**Target User**: Indirect — never hand-tuned by an end user. Its three consumers are:

1. **AI agents (the primary user).** A `pi` child invokes `agent-browser <cmd>` hundreds of
   times per task via stateless bash, exactly as `skills get core` teaches. With the symlink
   installed (M8.T1.S1), `~/scripts/agent-browser` shadows `~/.local/bin/agent-browser`;
   every call lands here, sources the lib, and `pool_wrapper_main` transparently routes it to
   the agent's locked/connected ephemeral lane (or passes through for meta/help). The agent
   has **no idea** pooling is happening (PRD §2.15 "no idea" contract).
2. **A human in a terminal** (PRD §2.17 "develop/test before cutover"). Before install, the
   wrapper is exercised by **absolute path** (`…/bin/agent-browser …`) so it does not disturb
   the PATH-resolved `agent-browser` that running agents use. `pool_wrapper_main` detects "no
   `pi` ancestor" and passes such calls through to the real tool unchanged.
3. **The M9 unit-test harness.** Sources `lib/pool.sh` and drives `pool_wrapper_main` through
   dispatch/passthrough branches; for end-to-end tests it invokes this shim with stubbed env
   (the symlink test in this PRP's Level 2 is a preview of that harness).

**Use Case**: (as above) — the shim is the bootstrap that makes `pool_wrapper_main` the
process-wide `agent-browser` once installed. Before install, it is the safe absolute-path
test entry point.

**Pain Points Addressed**:
- **Without symlink-safe resolution, the installed wrapper would break.** A shim that computed
  the lib path from `$0` (the symlink) would look for `<symlink-dir>/../lib/pool.sh` and die.
  `readlink -f "${BASH_SOURCE[0]}"` canonicalizes through the symlink to `<repo>/bin`, so
  `../lib/pool.sh` always resolves to `<repo>/lib/pool.sh` regardless of where it's symlinked.
- **Without a single exec entry point, pooling logic would have to live in every shim.** By
  sourcing one shared `lib/pool.sh` and calling one `pool_wrapper_main`, all lifecycle logic
  is centralized and testable (PRD §2.1 "shared lease logic").

## Why

- **This IS PRD §2.1's "wrapper shim (sources `lib/pool.sh`, dispatches)"** and the production
  realization of §2.17's `~/scripts/agent-browser` shadow. The PRD §3 repository layout shows
  `bin/agent-browser ← wrapper shim (sources lib/pool.sh, dispatches)` as a first-class
  component. This task creates it.
- **It is the entry point for the entire P1.M6 milestone.** P1.M6.T1–T3.S1 are all library
  functions (`pool_dispatch_classify`, `pool_normalize_close/connect`, `pool_strip_session_args`
  / `pool_force_session`, `pool_wrapper_main`). None of them is reachable from a real
  `agent-browser` invocation until THIS shim exists and sources them. The shim is the capstone
  wiring that makes the pool *invokable*.
- **It is deliberately tiny and contract-fixed.** The item description and the T3.S1 PRP both
  give the EXACT eight lines. There is no design latitude: implement the contract verbatim,
  `chmod +x`, validate. The risk surface is the symlink resolution — which is exactly what
  this PRP's Level-2 symlink test targets.
- **It must NOT duplicate or conflict with T3.S1.** T3.S1 owns `pool_wrapper_main` in
  `lib/pool.sh` (lib-only). This task owns only `bin/agent-browser` (bin-only). They are a
  contract pair: the shim's final statement is `pool_wrapper_main "$@"`, and `pool_wrapper_main`
  is terminal (exec / pool_die) so the shim runs nothing after it. Treat T3.S1's PRP as a
  CONTRACT — assume `pool_wrapper_main` is defined at `lib/pool.sh` EOF exactly as specified.

## What

User-visible behavior: **a working `agent-browser` command that pools transparently** (once
symlinked onto PATH). For this task's verification (no Chrome, no master profile, no real
`pi` ancestor), the observable contract is the passthrough behavior under
`AGENT_BROWSER_POOL_DISABLE=1` + a stubbed real binary, invoked both directly and through a
symlink.

### The file (verbatim contract — authoritative from item description + T3.S1 PRP)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.17; scout-conventions §9)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"
```

Then `chmod 0755 bin/agent-browser`.

**Behavioral contract of the shim** (delegated to `pool_wrapper_main`, which is terminal):

| invocation | shim does | observable (DISABLE=1 + stub) |
|---|---|---|
| `bin/agent-browser --help` | `source` lib → `pool_wrapper_main --help` → `exec "$POOL_REAL_BIN" --help` | stub sees `--help` verbatim |
| `bin/agent-browser --session evil open <url>` | source → `pool_wrapper_main` → DISABLE short-circuit → `exec "$POOL_REAL_BIN" --session evil open <url>` | stub sees ORIGINAL argv incl. `--session evil` (no strip/force under DISABLE) |
| **via symlink** `$TMP/agent-browser --help` (→ repo/bin/agent-browser) | `readlink -f` resolves through symlink → sources `<repo>/lib/pool.sh` → `pool_wrapper_main --help` → exec stub | stub sees `--help` (proves symlink-safe sourcing) |
| (driving, pooled owner, DISABLE unset) | source → `pool_wrapper_main` → full lifecycle → `exec` real CLI on lane `N` with `AGENT_BROWSER_SESSION=abpool-<N>` | needs Chrome — Level 3 / M9 |

### Success Criteria

- [ ] **File created** at `bin/agent-browser` (alongside `bin/.gitkeep`, which is retained).
- [ ] **Verbatim contract**: the eight lines above appear byte-for-byte (shebang, strict mode,
      `readlink -f "${BASH_SOURCE[0]}"`, `dirname`, `source "$REAL_DIR/../lib/pool.sh"`,
      `pool_wrapper_main "$@"` as the LAST statement). A short header comment (2-4 lines)
      describing the shim is OPTIONAL but recommended (satisfies the item's DOCS step:
      "self-documenting via comments").
- [ ] **Executable**: `test -x bin/agent-browser` passes (`chmod 0755`).
- [ ] **Syntax clean**: `bash -n bin/agent-browser` → exit 0.
- [ ] **Shellcheck clean**: `shellcheck -s bash bin/agent-browser` → ZERO warnings.
- [ ] **Direct passthrough** (DISABLE=1 + stub): `bin/agent-browser --session evil open
      https://example.com` → stub output contains `evil` AND `https://example.com` AND
      `AGENT_BROWSER_SESSION` is NOT `abpool-<N>` (disable short-circuits before force).
- [ ] **Symlink-safe passthrough** (THE distinguishing check): a symlink
      `$TMP/agent-browser → <repo>/bin/agent-browser`, invoked as `$TMP/agent-browser --help`
      under DISABLE=1 + stub → stub output contains `--help`. (Proves `readlink -f` resolved
      through the symlink; a bare `dirname "$0"` shim would fail to source and abort.)
- [ ] **Meta passthrough**: `bin/agent-browser skills get core` (DISABLE=1 + stub, no owner
      pid) → stub sees `skills get core` (classify→meta OR disable short-circuit; both pass
      through unchanged).
- [ ] **`lib/pool.sh` untouched**: `git diff --stat lib/pool.sh` empty (this task is bin-only).
- [ ] **`bin/.gitkeep` retained**: `test -f bin/.gitkeep` passes.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **verbatim eight-line contract** (item
description + T3.S1 PRP, re-stated above); the **two-resolutions distinction** (shim resolves
ITS OWN path to find `lib/pool.sh`; `POOL_REAL_BIN` is resolved separately by
`pool_config_init` — NOT the shim's job); the **symlink gotcha** (PRD §2.1/§2.17: the wrapper
is symlinked to `~/scripts/`; `dirname "$0"` would miss the lib → `readlink -f` before
`dirname` is mandatory); the **`BASH_SOURCE[0]` vs `$0`** choice; host-verified tooling
(bash 5.3.15, ShellCheck 0.11.0, GNU `readlink -f` ✓); the fact that **sourcing is
side-effect-free** (only `set -euo pipefail` + function defs run at source time); the
**SC2155 non-issue** for top-level assignments; the **`.gitkeep` retention** + **no
`.gitignore` change** requirement; and a copy-pasteable, host-verified validation script
(Level 2) whose symlink test is unique to this task.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.1 (components: "~/scripts/agent-browser ← shadow wrapper (symlink → repo bin/)" +
        "repo/lib/pool.sh ← shared lease logic"). §2.17 (cutover: "~/scripts precedes
        ~/.local/bin on PATH"; "develop/test before cutover by invoking the wrapper by
        absolute path"; "$AGENT_BROWSER_POOL_DISABLE=1 per-process passthrough"). §3 (repo
        layout: "bin/agent-browser ← wrapper shim (sources lib/pool.sh, dispatches)").
  pattern: the shim IS the "wrapper shim (sources lib/pool.sh, dispatches)" component.
  gotcha: §2.17 — before install.sh runs, test by ABSOLUTE PATH so you don't disturb the
        PATH-resolved agent-browser running agents use. The DISABLE env is the per-session
        opt-out (used by this PRP's tests to force the passthrough branch without Chrome).

# This task's own research (THE symlink-safety evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M6T3S2/research/symlink-safe-shim.md
  why: §1 the two-resolutions distinction (shim self-resolution vs POOL_REAL_BIN by config_init).
        §2 the symlink gotcha (readlink -f before dirname) + why. §3 BASH_SOURCE[0] vs $0.
        §4 readlink -f vs realpath vs realpath -m (pick by existence requirement). §5 sourcing
        is side-effect-free. §6 SC2155 does NOT apply to top-level assignments. §7 bin/.gitkeep
        retained + no .gitignore change. §8 the symlink test is the distinguishing validation.
        §9 the verbatim contract.
  pattern: §2's resolution chain IS the implementation; §8's symlink test IS the validation.
  gotcha: §1 — do NOT resolve POOL_REAL_BIN in the shim (that's config_init's job). §5 — source
        unconditionally; nothing executes at source time except set -e + function defs.

# Sibling PRP (the CONTRACT pair — assume pool_wrapper_main is landed exactly as specified)
- file: plan/001_0f759fe2777c/P1M6T3S1/PRP.md
  why: defines pool_wrapper_main() (appended at lib/pool.sh EOF under the banner "# Wrapper
        shim — complete lifecycle (P1.M6.T3.S1)"). Its "User Persona" quotes THIS task's shim
        verbatim and states: "the shim's pool_wrapper_main "$@" is the LAST statement; the
        shim runs nothing after it." Its "Integration Points" → CONSUMERS row: "M6.T3.S2
        bin/agent-browser: source \"$REAL_DIR/../lib/pool.sh\"; pool_wrapper_main \"$@\"".
  pattern: the shim↔lib contract is fixed by this sibling PRP.
  gotcha: T3.S1 is being implemented IN PARALLEL. Assume pool_wrapper_main exists at source
        time; if implementation runs before T3.S1 lands, the shim will still source cleanly
        (defines every M1-M6.T2 function) but `pool_wrapper_main` may be undefined → the
        shim would `pool_wrapper_main: command not found` under set -e. COORDINATION NOTE in
        Implementation Tasks below.

# Re-used external research from T3.S1 (symlink + exec semantics — canonical URLs)
- file: plan/001_0f759fe2777c/P1M6T3S1/research/external-bash-wrapper.md
  why: §3 (resolve the shim's own path — symlink gotcha; readlink -f before dirname). §10
        (BASH_SOURCE[0] not $0). §12 (readlink -f vs realpath vs realpath -m). §13 (the two
        resolutions are SEPARATE). §1 (exec replaces the process; exported env inherited —
        confirms pool_wrapper_main's exec hands off correctly, NOT the shim's concern but
        motivates "shim runs nothing after pool_wrapper_main"). §2 (sourced-lib terminal main:
        the shim's last statement is the function call; function is terminal).
  pattern: §3/§10/§13 = the shim's path-resolution logic. §2 = "shim is a thin bootstrap".
  gotcha: §13 — keep the shim self-resolution and POOL_REAL_BIN resolution separate.

# Architecture
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 3 (PRD §2.2 — no bare ~; resolve paths to absolute). ARCHITECTURAL
        RECOMMENDATION "Single Shared Library" shows the exact readlink -f pattern this shim
        uses (REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"; REAL_DIR="$(dirname …)";
        source "$REAL_DIR/../lib/pool.sh"; pool_main "$@"). Confirms the design.
  pattern: the "Single Shared Library" recommendation block IS this shim's blueprint.
  gotcha: FINDING 3 — the shim never passes ~ to a subprocess; readlink -f yields an absolute
        path, so "$REAL_DIR/../lib/pool.sh" is absolute. Compliant by construction.

# The library this shim sources (read header + EOF to confirm it is sourceable)
- file: lib/pool.sh
  why: lines 1-16 (header: "Sourced by: bin/agent-browser ... ; meant to be SOURCED, NOT
        executed directly"). line 18 (set -euo pipefail — propagates into the shim's shell).
        EOF @3391 (after pool_force_session; T3.S1 appends pool_wrapper_main here). Confirms
        sourcing is side-effect-free and that pool_wrapper_main will be defined (once T3.S1
        lands) for the shim to call.
  pattern: header comment already names bin/agent-browser as a consumer.
  gotcha: the lib's own `set -euo pipefail` (line 18) runs on source — the shim ALSO declares
        its own before sourcing (idempotent + rbenv convention + protects the readlink/dirname
        lines). Keep both.
```

### Current Codebase tree

After **M1–M6.T2.S1** landed and **T3.S1** (parallel) appends `pool_wrapper_main` at EOF,
`lib/pool.sh` (≈3391 lines before T3.S1, +~80 after) defines every function the shim needs.
`bin/` is still `.gitkeep`-only — THIS task creates `bin/agent-browser`:

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   └── .gitkeep                          # empty (THIS task adds bin/agent-browser alongside it)
├── lib/
│   └── pool.sh                           # header names bin/agent-browser as a consumer (lines 5-6).
│                                         #   EOF (after T3.S1): pool_force_session @3380 +
│                                         #   pool_wrapper_main (T3.S1 banner, appended at EOF).
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M6T3S1/PRP.md                   # the CONTRACT pair (pool_wrapper_main)
    └── P1M6T3S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/symlink-safe-shim.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── bin/
│   ├── .gitkeep                          # RETAINED (admin CLI bin/agent-browser-pool is M7.T5.S1)
│   └── agent-browser                     # NEW — the wrapper shim entry point:
│                                         #   #!/usr/bin/env bash ; set -euo pipefail
│                                         #   REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
│                                         #   REAL_DIR="$(dirname "$REAL_SCRIPT")"
│                                         #   source "$REAL_DIR/../lib/pool.sh"
│                                         #   pool_wrapper_main "$@"      # LAST statement
│                                         #   chmod 0755. Self-documenting via comments.
└── (no other files change)
```

**File responsibility**: `bin/agent-browser` is the **bootstrap entry point** that makes the
pool *invokable*. It owns NO lifecycle logic — it resolves its own path (symlink-safe), sources
the one shared library, and delegates to `pool_wrapper_main` (terminal). It is what
`install.sh` (M8.T1.S1) symlinks onto `~/scripts/` to shadow `~/.local/bin/agent-browser`.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the symlink gotcha — PRD §2.1/§2.17; research §2): the shim is symlinked to
#   ~/scripts/agent-browser at install time. If it computes the lib path from $0 (the symlink),
#   dirname "$0" = ~/scripts and ../lib/pool.sh = ~/lib/pool.sh → WRONG → source fails → set -e
#   aborts → every agent-browser call dies. readlink -f "${BASH_SOURCE[0]}" canonicalizes through
#   ALL symlink hops to <repo>/bin/agent-browser; dirname → <repo>/bin; ../lib/pool.sh → <repo>/lib/pool.sh ✓.
#   THE Level-2 symlink test exists to catch exactly this regression.

# CRITICAL (two separate resolutions — research §1 / external-bash-wrapper §13): the shim resolves
#   ONLY its own path to find lib/pool.sh. The REAL upstream binary path (POOL_REAL_BIN) is resolved
#   by pool_config_init (@lib/pool.sh:147) from AGENT_BROWSER_REAL (default $HOME/.local/bin/agent-browser,
#   canon via realpath -m). The shim must NOT touch POOL_REAL_BIN. Do not conflate them.

# CRITICAL (BASH_SOURCE[0] not $0 — research §3): ${BASH_SOURCE[0]} is "the file currently being
#   read/executed"; $0 is the shell name and is unreliable for path resolution. For a directly-
#   executed script they coincide, so BASH_SOURCE[0] is strictly safer. The contract uses it.

# GOTCHA (readlink -f requires the path to EXIST — research §4): the shim obviously exists (it is
#   running), so readlink -f succeeds. Do NOT switch to `realpath -m` (no need). Both readlink -f
#   and realpath are present on this host (GNU coreutils). Host-verified: /usr/bin/readlink.

# GOTCHA (sourcing is side-effect-free — research §5): lib/pool.sh's only top-level executable
#   statements are `set -euo pipefail` (line 18) + function DEFINITIONS. pool_config_init /
#   pool_state_init / pool_wrapper_main do NOT run at source time (pool_wrapper_main calls config+
#   state as step "a" inside itself). So `source` just defines functions. Safe.

# GOTCHA (set -euo pipefail appears TWICE — keep both): the shim declares it BEFORE sourcing
#   (rbenv/rustup convention; protects the readlink/dirname lines under strict mode); lib/pool.sh
#   re-declares it at line 18 on source. Idempotent. Do NOT delete the shim's own declaration.

# GOTCHA (SC2155 does NOT apply — research §6): SC2155 fires only for local/declare/readonly/typeset.
#   The shim's REAL_SCRIPT="$(readlink -f …)" / REAL_DIR="$(dirname …)" are PLAIN top-level
#   assignments (no local) → shellcheck-clean. Do not "fix" them by splitting (unnecessary).

# GOTCHA (bin/.gitkeep — research §7): the shim is a NEW file ALONGSIDE .gitkeep. RETAIN .gitkeep
#   (the admin CLI bin/agent-browser-pool is M7.T5.S1, not built yet). Removing it is out of scope.

# GOTCHA (.gitignore — research §7): no rule matches bin/agent-browser (*.log, .state/, .pi-subagents/,
#   .env*, dist/, build/, node_modules/, venv/, __pycache__/, OS files). The versioned wrapper is NOT
#   ignored. Do NOT modify .gitignore — it is orchestrator-owned (M10.T1.S2 verifies it).

# GOTCHA (pool_wrapper_main is terminal — T3.S1 PRP): every success path in pool_wrapper_main ends
#   in `exec` (process replacement); every fatal path ends in `pool_die`→`exit 1`. There is NO return
#   on the success path. Therefore the shim runs NOTHING after `pool_wrapper_main "$@"` — it is the
#   LAST statement. Any code after it would be unreachable on success.

# GOTCHA (parallel coordination with T3.S1): T3.S1 is implemented IN PARALLEL. If this shim is
#   created BEFORE T3.S1 lands pool_wrapper_main, `source lib/pool.sh` still succeeds (defines all
#   M1-M6.T2 functions) but `pool_wrapper_main "$@"` → "command not found" → set -e aborts. The
#   Level-2 tests will fail until T3.S1 lands. This is EXPECTED, not a shim bug. Implement the shim
#   to the contract regardless; the symlink-resolution + sourcing logic is independently correct.

# GOTCHA (shebang + chmod): #!/usr/bin/env bash (matches lib/pool.sh line 1 — codebase convention;
#   portable across distros where bash isn't /bin/bash). chmod 0755 (rwxr-xr-x — standard executable).
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk layout change beyond the one new file,
and NO new env vars. It creates ONE executable text file. The shim reads ONE thing from the
environment at source time — `${BASH_SOURCE[0]}` (set by bash itself) — and defines two local
script variables (`REAL_SCRIPT`, `REAL_DIR`). It exports nothing. All pooling state/env is owned
by `pool_wrapper_main` and its helpers.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the source contract
  - RUN: test -f lib/pool.sh && test -f bin/.gitkeep && echo "OK layout"
  - EXPECT: both exist; bin/ currently has only .gitkeep.
  - RUN (confirm this task is greenfield):
        test -e bin/agent-browser && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield.
  - RUN (confirm lib/pool.sh is sourceable + header names bin/agent-browser):
        sed -n '1,18p' lib/pool.sh
  - EXPECT: header "Sourced by: ... bin/agent-browser ..." + line 18 `set -euo pipefail`.
  - RUN (host tooling):
        bash --version | head -1                     # expect 5.x
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'   # expect 0.x
        command -v readlink >/dev/null && readlink --version | head -1                    # GNU coreutils
        command -v realpath >/dev/null && echo "realpath OK"
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0, GNU readlink (supports -f), realpath present.
  - RUN (T3.S1 coordination — is pool_wrapper_main defined yet?):
        if bash -c 'set -euo pipefail; source lib/pool.sh; type pool_wrapper_main' 2>/dev/null \
            | grep -q 'function'; then echo "T3.S1 LANDED: pool_wrapper_main defined";
        else echo "T3.S1 NOT YET LANDED: shim will source OK but pool_wrapper_main undefined \
            (Level-2 functional tests will fail until T3.S1 lands — see GOTCHA)"; fi
  - EXPECT: informational either way; proceed regardless (shim logic is independently correct).
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not touch lib/pool.sh).

Task 1: CREATE bin/agent-browser (the verbatim contract, executable)
  - PLACEMENT: bin/agent-browser (NEW file alongside bin/.gitkeep).
  - IMPLEMENT (verbatim — paste exactly; the 2-line header comment is OPTIONAL but recommended
        to satisfy the item's "self-documenting via comments" DOCS step):

#!/usr/bin/env bash
#
# bin/agent-browser — transparent PATH-shadowing wrapper shim (PRD §2.1, §2.17).
# Resolves its own real path (symlink-safe) so it can source the shared lib regardless of
# where it is symlinked (~/scripts/agent-browser → repo/bin/agent-browser at install time).
# SOURCES lib/pool.sh and delegates to pool_wrapper_main (terminal: exec / pool_die).
# The shim runs NOTHING after pool_wrapper_main "$@".
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.17; scout-conventions §9)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"

  - MAKE EXECUTABLE: chmod 0755 bin/agent-browser
  - VERIFY (immediately after):
        bash -n bin/agent-browser && echo "OK syntax"
        shellcheck -s bash bin/agent-browser && echo "OK shellcheck"   # ZERO warnings
        test -x bin/agent-browser && echo "OK executable"
        test -f bin/.gitkeep && echo "OK .gitkeep retained"
        git diff --stat lib/pool.sh | grep -q . && echo "STOP: lib touched!" || echo "OK lib untouched"
  - EXPECT: all OK; lib untouched; .gitkeep retained.

Task 2: (NO CHANGES) confirm no collateral edits
  - RUN: git status --short bin/ lib/ .gitignore
  - EXPECT: only `bin/agent-browser` appears as a new untracked file. lib/, .gitignore, bin/.gitkeep
        unchanged. NO edits to PRD.md / tasks.json / prd_snapshot.md (those are read-only/owned).
```

### Implementation Patterns & Key Details

```bash
# PATTERN — symlink-safe self-resolution (THE pattern this task exists to get right):
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"   # canonicalize through ALL symlink hops
REAL_DIR="$(dirname "$REAL_SCRIPT")"               # <repo>/bin  (NOT <symlink-dir>)
source "$REAL_DIR/../lib/pool.sh"                  # <repo>/lib/pool.sh  ✓

# PATTERN — thin bootstrap (rbenv/rustup/nvm precedent — external-bash-wrapper §5):
#   the shim's ONLY jobs are: locate the lib (symlink-safe), source it, call the terminal main.
#   Keep it to ~8-12 lines. NO lifecycle logic here (that's pool_wrapper_main).

# PATTERN — terminal delegation (external-bash-wrapper §2):
#   pool_wrapper_main "$@"  is the LAST statement. pool_wrapper_main is terminal (exec/pool_die),
#   so nothing after it ever runs on success. Do NOT add a trailing `exit 0` or echo.

# GOTCHA — WHY readlink -f and NOT dirname "$0": $0/BASH_SOURCE[0] is the SYMLINK path at install
#   time (~/scripts/agent-browser); dirname "$0" = ~/scripts; ../lib/pool.sh = ~/lib/pool.sh → WRONG.
#   readlink -f resolves the symlink to <repo>/bin/agent-browser FIRST. (research §2.)
# GOTCHA — WHY the shim has its OWN set -euo pipefail (lib already has it at line 18): idempotent +
#   rbenv convention + protects the readlink/dirname lines under strict mode BEFORE the lib is sourced.
# GOTCHA — WHY BASH_SOURCE[0] and not $0: BASH_SOURCE[0] is always "the file being read"; $0 is the
#   shell name and is unreliable. For an executed script they're equal, so BASH_SOURCE[0] is safer.
#   (research §3.)
# GOTCHA — WHY NOT realpath -m: the shim EXISTS (it's running); readlink -f (requires existence) is
#   stricter and correct. realpath -m is for config defaults that may not exist yet (pool_config_init).
#   (research §4.)
```

### Integration Points

```yaml
FILESYSTEM:
  - create: "bin/agent-browser (NEW; chmod 0755; alongside bin/.gitkeep which is RETAINED)"
  - pattern: "8-line shim: shebang + set -euo pipefail + readlink -f self-resolution + source + delegate"

LIBRARY (lib/pool.sh):
  - no change: "this task is bin-only. lib/pool.sh's header (lines 5-6) already names
               bin/agent-browser as a consumer; pool_wrapper_main (T3.S1) is the call target."

GITIGNORE:
  - no change: "no rule matches bin/agent-browser. .gitignore is orchestrator-owned (M10.T1.S2)."

INSTALL (NOT this task — M8.T1.S1, future):
  - future: "install.sh symlinks bin/agent-browser → ~/scripts/agent-browser (ahead of ~/.local/bin
            on PATH) with a cutover confirmation. The shim's readlink -f is what makes that symlink
            safe. Until install.sh exists, test by ABSOLUTE PATH (PRD §2.17)."

CONSUMERS (the shim's call target, built by the PARALLEL T3.S1):
  - T3.S1 pool_wrapper_main: "appended at lib/pool.sh EOF under banner '# Wrapper shim — complete
            lifecycle (P1.M6.T3.S1)'. Terminal: success → exec $POOL_REAL_BIN; fatal → pool_die.
            The shim's `pool_wrapper_main \"$@\"` is its ONLY interaction with the lib's logic."

NO CHANGES TO:
  - lib/pool.sh (bin-only task), bin/.gitkeep (retained), .gitignore (orchestrator-owned),
    PRD.md / tasks.json / prd_snapshot.md (read-only), install.sh (M8.T1.S1, future).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating the file + chmod — fix before proceeding.
bash -n bin/agent-browser && echo "OK bash -n"
shellcheck -s bash bin/agent-browser && echo "OK shellcheck"   # ZERO warnings
test -x bin/agent-browser && echo "OK executable"              # chmod 0755
# Expected: all OK. shellcheck zero warnings (SC2155 does NOT fire on plain top-level assignments;
#   SC2086 is satisfied by quoting "${BASH_SOURCE[0]}", "$REAL_SCRIPT", "$REAL_DIR/...").
#   If SC2034 fires for REAL_SCRIPT/REAL_DIR being "unused" — they ARE used (source/arg); re-check.
```

### Level 2: Unit Tests (Component Validation — NO Chrome needed)

The shim's correctness is entirely about (a) sourcing the lib and (b) resolving its path
symlink-safely. Both are verifiable WITHOUT Chrome / a master profile / a real `pi` ancestor by
using `AGENT_BROWSER_POOL_DISABLE=1` (passthrough safety valve, PRD §2.17) + a STUBBED
`AGENT_BROWSER_REAL` that captures argv. **NOTE: if T3.S1 has not yet landed
`pool_wrapper_main`, the functional Cases 2-4 fail with "command not found" — that is EXPECTED
(see GOTCHA), not a shim bug; re-run after T3.S1 lands. Case 1 (structure) always passes.**

```bash
# Save as /tmp/test_shim.sh and run: bash /tmp/test_shim.sh
# Run from the REPO ROOT (where bin/ and lib/ live).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/bin/agent-browser" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0

# --- Case 1 (structure — always passes, independent of T3.S1): file exists, executable, clean ---
bash -n bin/agent-browser && shellcheck -s bash bin/agent-browser && test -x bin/agent-browser \
    && { pass=$((pass+1)); echo "PASS structure: executable + bash -n + shellcheck clean"; } \
    || { fail=$((fail+1)); echo "FAIL structure" >&2; }
# Verify the contract lines are present (readlink -f + dirname + source ../lib + pool_wrapper_main):
grep -q 'readlink -f "\${BASH_SOURCE\[0\]}"' bin/agent-browser \
    && grep -q 'source "\$REAL_DIR/\.\./lib/pool\.sh"' bin/agent-browser \
    && grep -q 'pool_wrapper_main "\$@"' bin/agent-browser \
    && grep -q 'set -euo pipefail' bin/agent-browser \
    && { pass=$((pass+1)); echo "PASS contract: verbatim lines present"; } \
    || { fail=$((fail+1)); echo "FAIL contract: a required line is missing/wrong" >&2; }
# Verify lib untouched + .gitkeep retained:
git diff --stat lib/pool.sh | grep -q . && { fail=$((fail+1)); echo "FAIL: lib/pool.sh was modified" >&2; } \
    || { pass=$((pass+1)); echo "PASS: lib/pool.sh untouched"; }
test -f bin/.gitkeep && { pass=$((pass+1)); echo "PASS: bin/.gitkeep retained"; } \
    || { fail=$((fail+1)); echo "FAIL: bin/.gitkeep removed" >&2; }

# --- Build a STUB real binary that records argv + the forced-session env to a file ---
STUB_DIR="$(mktemp -d)"; STUB="$STUB_DIR/agent-browser-stub"
CAP="$(mktemp)"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:\n'; for a in "$@"; do printf '  [%s]\n' "$a"; done
printf 'ENV: AGENT_BROWSER_SESSION=%s\n' "${AGENT_BROWSER_SESSION:-<unset>}"
EOF
chmod +x "$STUB"

# --- Case 2 (direct passthrough — needs T3.S1): DISABLE=1 + stub → ORIGINAL argv unchanged ---
: >"$CAP"
AGENT_BROWSER_POOL_DISABLE=1 AGENT_BROWSER_REAL="$STUB" \
    AGENT_BROWSER_POOL_STATE="$(mktemp -d)" POOL_LOG_PATH=/dev/null \
    ./bin/agent-browser --session evil open https://example.com >"$CAP" 2>/dev/null \
    && grep -q -- 'evil' "$CAP" && grep -q 'https://example.com' "$CAP" \
    && ! grep -qE 'AGENT_BROWSER_SESSION=abpool-' "$CAP" \
    && { pass=$((pass+1)); echo "PASS direct-passthrough: stub got ORIGINAL argv (no strip/force under DISABLE)"; } \
    || { fail=$((fail+1)); echo "FAIL direct-passthrough (T3.S1 landed? see GOTCHA)" >&2; }

# --- Case 3 (symlink-safety — THE distinguishing check — needs T3.S1): invoke THROUGH a symlink ---
# Simulates install.sh: ~/scripts/agent-browser → <repo>/bin/agent-browser.
LINK_DIR="$(mktemp -d)"; ln -s "$REPO/bin/agent-browser" "$LINK_DIR/agent-browser"
: >"$CAP"
AGENT_BROWSER_POOL_DISABLE=1 AGENT_BROWSER_REAL="$STUB" \
    AGENT_BROWSER_POOL_STATE="$(mktemp -d)" POOL_LOG_PATH=/dev/null \
    "$LINK_DIR/agent-browser" --help >"$CAP" 2>/dev/null \
    && grep -q -- '\-\-help' "$CAP" \
    && { pass=$((pass+1)); echo "PASS symlink-safety: invoked via symlink → sourced <repo>/lib/pool.sh → passthrough"; } \
    || { fail=$((fail+1)); echo "FAIL symlink-safety: readlink -f resolution broken? (a bare dirname \$0 shim would die here)" >&2; }
# NEGATIVE-control reasoning: if the shim used `dirname "$0"` (no readlink -f), it would try to
# source "$LINK_DIR/../lib/pool.sh" = <tmp>/lib/pool.sh → source fails → set -e aborts → no --help in $CAP.

# --- Case 4 (meta passthrough — needs T3.S1): skills get core → meta → passthrough unchanged ---
: >"$CAP"
AGENT_BROWSER_POOL_DISABLE=1 AGENT_BROWSER_REAL="$STUB" \
    AGENT_BROWSER_POOL_STATE="$(mktemp -d)" POOL_LOG_PATH=/dev/null \
    ./bin/agent-browser skills get core >"$CAP" 2>/dev/null \
    && grep -q 'skills' "$CAP" && grep -q 'core' "$CAP" \
    && { pass=$((pass+1)); echo "PASS meta-passthrough: 'skills get core' reached stub unchanged"; } \
    || { fail=$((fail+1)); echo "FAIL meta-passthrough (T3.S1 landed?)" >&2; }

# --- Cleanup ---
rm -rf "$STUB_DIR" "$LINK_DIR" "$CAP"
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass=8, fail=0 — IF T3.S1 has landed pool_wrapper_main. If T3.S1 is still in flight,
#   Cases 2-4 fail with "command not found" (EXPECTED; the shim is correct). Case 1 (structure,
#   contract, lib-untouched, .gitkeep) always passes. Re-run after T3.S1 lands.
```

### Level 3: Integration Testing (System Validation — needs Chrome + master profile)

The driving happy-path (acquire → boot → ensure → force-session → exec real CLI on lane N) requires
a real Chrome, a btrfs master profile, and a `pi` ancestor (or `AGENT_BROWSER_POOL_OWNER_PID`). It
is the domain of the M9 harness. **For this task, the symlink test in Level 2 IS the integration
proof** that the shim wires `pool_wrapper_main` into an invokable `agent-browser`. A full
end-to-end smoke (run inside `pi`, master profile present) once T3.S1 lands:

```bash
# PREREQ: T3.S1 landed (pool_wrapper_main defined); master profile at $AGENT_CHROME_MASTER;
#         btrfs at ephemeral root (or POOL_ALLOW_SLOW_COPY=1); run INSIDE pi (real owner ancestor).
# Driving command — full lifecycle fires, lands on lane N, opens the page:
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool-smoke}" \
    ./bin/agent-browser --session evil open https://example.com
# Expected: a Chrome launches in an ephemeral lane; page opens; AGENT_BROWSER_SESSION forced to
#   abpool-<N> (check `agent-browser-pool status` once M7 lands, or lanes/<N>.json connected=true).

# Via SYMLINK (simulating post-install): create ~/scripts/agent-browser → repo/bin/agent-browser,
# prepend ~/scripts to PATH, then `agent-browser snapshot` — must reuse lane N (no new Chrome).
# (Per PRD §2.17: do NOT do this while running agents use the old workflow — it silently intercepts.)

# Cleanup: release the lane via the M7 admin CLI (agent-browser-pool release all) or kill the owner pi.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Transparency (PRD §2.15) spot-checks via the shim (full automation is M9.T4.S1):
#   [ ] `./bin/agent-browser skills get core` (DISABLE=1) → passthrough unchanged (Level 2 Case 4).
#   [ ] `./bin/agent-browser --help` via SYMLINK (DISABLE=1) → passthrough unchanged (Level 2 Case 3).
#   [ ] (Level 3) `./bin/agent-browser --session evil open <url>` → forced to abpool-<N> (no leak).

# Portability sanity (the host is Linux; confirm the shebang + readlink -f work as expected):
command -v env >/dev/null && echo "/usr/bin/env bash shebang resolves: $(command -v bash)"
readlink -f ./bin/agent-browser        # expect: <repo>/bin/agent-browser (absolute, canonical)
# Create a 2-hop symlink chain and confirm readlink -f still resolves (defense-in-depth):
D="$(mktemp -d)"; ln -s "$REPO/bin/agent-browser" "$D/a"; ln -s "$D/a" "$D/b"
readlink -f "$D/b" | grep -q 'bin/agent-browser$' && echo "PASS: multi-hop symlink resolves" || echo "FAIL"
rm -rf "$D"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n bin/agent-browser` + `shellcheck -s bash bin/agent-browser` zero
      warnings + `test -x` passes.
- [ ] Level 2 Case 1 (structure/contract/lib-untouched/.gitkeep) PASSES unconditionally.
- [ ] Level 2 Cases 2-4 (direct passthrough, **symlink-safety**, meta passthrough) PASS — once
      T3.S1 lands `pool_wrapper_main`. (Re-run if run pre-T3.S1; the "command not found" is EXPECTED.)
- [ ] The **symlink-safety** test (Case 3) PASSES — the single most important check for this task.

### Feature Validation

- [ ] `bin/agent-browser` exists, is executable (`chmod 0755`), and contains the verbatim contract.
- [ ] Direct invocation (DISABLE=1 + stub) passes ORIGINAL argv to the stub (no strip/force).
- [ ] **Symlink invocation** (DISABLE=1 + stub) reaches the stub — proves `readlink -f` sourced
      `<repo>/lib/pool.sh` through the symlink (the `~/scripts/` shadow scenario).
- [ ] `pool_wrapper_main "$@"` is the LAST statement; nothing follows it (terminal delegation).
- [ ] `lib/pool.sh` byte-identical (bin-only task); `bin/.gitkeep` retained.

### Code Quality Validation

- [ ] Follows the codebase shebang convention (`#!/usr/bin/env bash` — matches `lib/pool.sh:1`).
- [ ] Strict mode (`set -euo pipefail`) declared in the shim AND re-asserted by the lib on source.
- [ ] Anti-patterns avoided: no bare `dirname "$0"` (symlink-unsafe); no `realpath -m` (unnecessary);
      no lifecycle logic in the shim (that's `pool_wrapper_main`); no trailing code after
      `pool_wrapper_main "$@"`; no `local` (top-level script — SC2155 N/A).
- [ ] Self-documenting (the `# Resolve real script dir ...` comment + optional header; satisfies
      the item's DOCS step).

### Documentation & Deployment

- [ ] The file is self-documenting via comments (item DOCS step).
- [ ] No new env vars; no config changes; no `.gitignore` change; no `install.sh` (M8.T1.S1).
- [ ] Before cutover (PRD §2.17): the wrapper is testable by absolute path; `install.sh` (future)
      will symlink it to `~/scripts/` — the `readlink -f` makes that safe.

---

## Anti-Patterns to Avoid

- ❌ Don't use `dirname "$0"` / `dirname "$BASH_SOURCE[0]"` WITHOUT `readlink -f` first — at
      install time `$0` is the symlink (`~/scripts/agent-browser`) and `../lib/pool.sh` resolves to
      the wrong dir. The Level-2 symlink test catches this. Use `readlink -f "${BASH_SOURCE[0]}"`.
- ❌ Don't resolve `POOL_REAL_BIN` (the real upstream CLI) in the shim — that's `pool_config_init`'s
      job. The shim resolves ONLY its own path to find `lib/pool.sh`. (research §1.)
- ❌ Don't use `$0` instead of `${BASH_SOURCE[0]}` — `$0` is the shell name and unreliable for path
      resolution. `BASH_SOURCE[0]` is always the file being read.
- ❌ Don't use `realpath -m` — the shim exists; `readlink -f` (requires existence) is stricter + correct.
- ❌ Don't add lifecycle logic to the shim — classify/acquire/boot/ensure/strip/force/exec all live in
      `pool_wrapper_main` (lib). The shim is a thin bootstrap (~8-12 lines).
- ❌ Don't add code AFTER `pool_wrapper_main "$@"` — it is terminal (exec/pool_die); trailing code is
      unreachable on success and a `return`/`exit` there would be a bug.
- ❌ Don't delete the shim's own `set -euo pipefail` because the lib has one — keep both (idempotent +
      protects the pre-source readlink/dirnum lines under strict mode).
- ❌ Don't remove `bin/.gitkeep` — the admin CLI `bin/agent-browser-pool` (M7.T5.S1) isn't built yet.
- ❌ Don't modify `lib/pool.sh`, `.gitignore`, `PRD.md`, `tasks.json`, or `install.sh` — this task is
      bin-only; those are owned by other tasks / the orchestrator / humans.
- ❌ Don't split the top-level `REAL_SCRIPT="$(…)"` assignment to "fix" SC2155 — SC2155 does NOT apply
      to plain top-level assignments (only `local`/`declare`/`readonly`/`typeset`). The contract is
      shellcheck-clean as written.
