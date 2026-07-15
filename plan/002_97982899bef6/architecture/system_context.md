# System Context — Plan 002: No-Shadow Pivot

## Overview

Plan 001 built and shipped a complete MVP of `agent-browser-pool` using a
**PATH-shadowing** architecture: a `bin/agent-browser` wrapper shim was
symlinked into `~/scripts/` (ahead of `~/.local/bin` on PATH), silently
intercepting every `agent-browser` call process-wide.

The current PRD has **pivoted** (Decision O5) to an **explicit invocation**
model: `agent-browser-pool <verb> <args>` is the sole entry point. No PATH
shadowing, no interception, no safety valve (`AGENT_BROWSER_POOL_DISABLE`).

This plan (002) is a **refactoring phase**, not a rebuild. The existing
4613-line `lib/pool.sh` has a battle-tested lease/acquire/release/reap/launch
core. Only the entry-point dispatch and several now-obsolete mechanisms need to
change. The lease I/O, owner resolution, Chrome launch, reaper, and
exhaustion logic are all reusable as-is.

## What's Already Aligned with the PRD

The last commit (`3a2f065 Adopt live profile source and explicit invocation`)
partially aligned the codebase with the new PRD:

1. **`pool_config_init`** (lib/pool.sh:132-210): `POOL_MASTER_DIR` already
   defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome` (real Chrome
   user-data-dir), NOT the old `master-profile`.
2. **`pool_check_master`** (lib/pool.sh:276-294): Error message already
   references the real Chrome dir.
3. **`POOL_EPHEMERAL_ROOT`**: Already defaults to `$HOME/.agent-chrome-profiles/active`.
4. **Port base/range**: Already 53420 / 1000.
5. **Exhaustion wait**: Already 600s.

## What's NOT Aligned (The Gaps)

### Gap 1: Entry Point — bin/agent-browser-pool is admin-only
- **Current**: Dispatches only `status|reap|release|doctor|help|--help|-h`.
  The `*)` branch **errors** with "Unknown command".
- **Required** (PRD §2.4): The SOLE entry point handling BOTH pool verbs AND
  driving commands. The `*)` branch must call `pool_wrapper_main "$@"`.

### Gap 2: Old PATH-Shadowing Shim — bin/agent-browser
- **Current**: `bin/agent-browser` is a 10-line shim that sources pool.sh and
  calls `pool_wrapper_main "$@"`. It's symlinked to `~/scripts/agent-browser`
  by install.sh to shadow the real binary.
- **Required** (PRD §2.1, §3): This file should NOT exist. The real
  `agent-browser` at `~/.local/bin/agent-browser` is used directly.

### Gap 3: POOL_DISABLE mechanism
- **Current**: `pool_config_init` reads `AGENT_BROWSER_POOL_DISABLE` → `POOL_DISABLE`.
  `pool_wrapper_main` step b checks `POOL_DISABLE==1` → passthrough `exec`.
  `pool_admin_help` lists it. `configuration.md` and README document it.
  `test/validate.sh` selftest tests it.
- **Required** (PRD §2.11, §2.17): `AGENT_BROWSER_POOL_DISABLE` is removed
  entirely. There is no interception to bypass.

### Gap 4: No-pi-ancestor — passthrough → fail-fast
- **Current**: `pool_wrapper_main` step d: `POOL_OWNER_PID==0` →
  `exec "$POOL_REAL_BIN" "$@"` (passthrough to real binary).
- **Required** (PRD §2.4 step 1): `POOL_OWNER_PID==0` →
  `pool_die "requires a pi ancestor; for raw browser use call 'agent-browser' directly"`.

### Gap 5: Missing preflight check for agent-browser binary
- **Current**: No check for `$POOL_REAL_BIN` existence before lane logic.
- **Required** (PRD §2.16): A preflight on every driving call that fails fast
  if `agent-browser` binary is missing.

### Gap 6: install.sh still does PATH shadowing
- **Current**: 221 lines with cutover warning, `~/scripts` symlink,
  PATH-ordering verification.
- **Required** (PRD §2.17): Three benign things — symlink `agent-browser-pool`,
  pre-create state dir, run doctor. No `~/scripts`, no cutover warning.

### Gap 7: SKILL.md teaches `agent-browser` command
- **Current**: Teaches `agent-browser open <url>` (PATH-shadowing). Description
  says "transparent PATH-shadowing wrapper."
- **Required** (PRD §2.15): Teaches `agent-browser-pool open <url>` (explicit
  invocation). Description reflects invariant command model.

### Gap 8: configuration.md has stale defaults
- **Current**: `AGENT_CHROME_MASTER` default listed as `master-profile`.
  `AGENT_BROWSER_POOL_DISABLE` documented. Dispatch table includes DISABLE
  passthrough and no-pi-ancestor passthrough.
- **Required**: Master default is real Chrome dir. DISABLE removed. Dispatch
  table reflects pool-verb-vs-driving model.

### Gap 9: Test files reference old model
- **test/validate.sh**: `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"`.
  Selftest tests `AGENT_BROWSER_POOL_DISABLE`.
- **test/transparency.sh**: Invokes `$ABPOOL_WRAPPER` for driving commands.
  Tests passthrough behavior (meta, no-pi-ancestor) that is changing.
- **test/concurrency.sh**: Comments reference the wrapper. Calls lib functions
  directly (no binary invocation for driving).
- **test/release_reaper.sh**: Comments reference the wrapper. Already uses
  `agent-browser-pool release/reap` for admin verbs.

### Gap 10: README.md describes old architecture
- PATH-shadowing, master-profile, `AGENT_BROWSER_POOL_DISABLE`, cutover.

## Key Architectural Decisions for This Pivot

1. **`pool_wrapper_main` is REUSED, not rewritten.** It already implements
   the complete driving lifecycle (acquire→boot→ensure-connected→clean-args→exec).
   Only three changes: remove DISABLE passthrough (step b), change no-pi-ancestor
   to fail-fast (step d), add preflight.

2. **`pool_dispatch_classify` is KEPT.** It still classifies meta commands
   (--help, --version, skills, dashboard) for passthrough within
   `pool_wrapper_main`. Meta commands that reach `pool_wrapper_main` (via the
   `*)` branch of `bin/agent-browser-pool`) still pass through to the real
   binary unchanged — they don't need a lane.

3. **Pool verb classification lives in `bin/agent-browser-pool` dispatch.**
   The binary's case statement checks `$1` against pool verbs. Everything else
   goes to `pool_wrapper_main`. This is simpler than the old model's two-stage
   classification (wrapper shim → pool_dispatch_classify).

4. **Meta passthrough semantics.** In the new model, `agent-browser-pool skills`
   → `*)` branch → `pool_wrapper_main` → `pool_dispatch_classify` → "meta" →
   passthrough to real binary. This is correct: meta commands don't need a lane.
   The `--help`/`-h` pool verbs are caught by the dispatch case BEFORE reaching
   pool_wrapper_main — they show the pool's own help.

5. **Test invocation pattern.** Tests that invoke driving commands must use
   `bin/agent-browser-pool <verb>` instead of `bin/agent-browser <verb>`.
   Tests that call lib functions directly (concurrency.sh) need comment updates
   only. Tests that already use `agent-browser-pool` for admin verbs
   (release_reaper.sh) need comment updates only.
