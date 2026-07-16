# System Context — META Passthrough Removal

## Summary

The `agent-browser-pool` project wraps `agent-browser` (a Chrome automation CLI for AI
agents). Its #1 guarantee is **lane isolation**: each agent gets its own ephemeral Chrome
profile + daemon session, and cannot reach another agent's lane through normal tool use.

A planned Phase-2 delta (removing the "META passthrough" command class) was **not
implemented**, leaving a critical isolation breach: meta commands (`skills`, `mcp`,
`dashboard`, `plugin`, `session list`, `--version`, flags-only) bypass the pool's
session-forcing and owner-resolution, allowing cross-lane access via `--session`.

## The Bug (One Root Cause, Four Issues)

**Root cause:** `pool_dispatch_classify` (`lib/pool.sh:3070–3128`) still classifies a
third command class — "meta" — and `pool_wrapper_main` step-c (`lib/pool.sh:3529–3536`)
execs these unchanged, BEFORE owner resolution and BEFORE session stripping/forcing.

**Four consequences (Issues 1–4 in the PRD):**

| Issue | Severity | Consequence |
|-------|----------|-------------|
| 1 | Critical | `--session <X>` passes through unstripped to meta commands → cross-lane access |
| 2 | Major | `--version`/`skills`/`mcp` bypass the no-`pi`-ancestor fail-fast gate |
| 3 | Major | Tests + skill docs still assert the old meta-passthrough model (suite passes despite bug) |
| 4 | Minor | `pool_dispatch_classify` duplicates the pool-verb/driving split already done by `bin/agent-browser-pool` |

## The Fix

Eliminate the META class entirely. After the fix:

1. **`bin/agent-browser-pool`** remains the single source of truth for the pool-verb
   vs. driving split (its `case` statement at lines 30–37 routes
   `status|reap|release|doctor|--help|-h|help` to admin functions).
2. **`pool_dispatch_classify`** is **deleted** (it was always returning `meta` or
   `driving`; with meta removed, it always returns `driving`, which is redundant since
   the bin dispatcher already split pool verbs out).
3. **`pool_wrapper_main` step-c** is **deleted** (the `if [[ "$class" == "meta" ]]` block
   + the `class` local variable + the classify call). All non-pool-verb tokens now flow
   through the driving path: owner resolve → fail-fast → acquire/reuse lane → normalize
   args → strip `--session` → force `AGENT_BROWSER_SESSION` → exec.

## Code Change Map

### lib/pool.sh (PRIMARY)

| Lines | What | Action |
|-------|------|--------|
| 3012–3069 | `pool_dispatch_classify` contract comment block | **Delete** |
| 3070–3128 | `pool_dispatch_classify` function body | **Delete** |
| 3439–3440 | `_pool_preflight_real_bin` comment referencing "meta commands exec it too" | **Update**: remove meta reference |
| 3462–3515 | `pool_wrapper_main` header comment block (references step c / classify / meta) | **Update**: remove meta/classify references |
| 3517 | `local class N port _has_json _a` | **Update**: remove `class` |
| 3529–3536 | Step-c META block (classify call + meta exec) | **Delete** |
| 3176, 3352, 3668, 3717 | Comments saying "mirrors pool_dispatch_classify" | **Update**: reword to not reference deleted function |

### test/transparency.sh

| Lines | What | Action |
|-------|------|--------|
| 8–12 | Header checklist (a) and (b2) describe meta passthrough | **Update**: describe new contract |
| 229–243 | `test_passthrough_skills` (byte-equal assertion) | **Replace**: assert `skills get core` fail-fast without pi ancestor |
| 265–277 | `test_version_passthrough` (byte-equal assertion) | **Replace**: assert `--version` fail-fast without pi ancestor |

### test/validate.sh

| Lines | What | Action |
|-------|------|--------|
| 345–384 | `selftest_dispatch_classify_cases` (tests deleted function) | **Delete/Replace**: remove selftest (function no longer exists); optionally add a driving-path selftest |

### .agents/skills/agent-browser-pool/references/configuration.md

| Lines | What | Action |
|-------|------|--------|
| 44–76 | "Command dispatch: meta vs. driving" + "Meta commands (passthrough)" sections | **Rewrite**: "Command dispatch: pool verbs vs. driving" |

### .agents/skills/agent-browser-pool/SKILL.md

| Lines | What | Action |
|-------|------|--------|
| 55–65 | "Which commands trigger a lane" subsection (lists meta commands) | **Rewrite**: remove meta set; all non-pool-verbs are driving |
| 143–145 | Reference pointer to "meta-vs-driving dispatch" | **Update**: change to "pool-verbs-vs-driving" |

### README.md (Mode B — cross-cutting overview)

| Lines | What | Action |
|-------|------|--------|
| 94–96 | "META commands work from any shell" | **Update**: remove META clause |
| 135–141 | Classification detail blockquote (META list) | **Update**: remove META list |
| 253–294 | "How it works" classify diagram (META branch) | **Update**: remove META branch |
| 313–317 | Troubleshooting META reference | **Update**: remove META reference |

## Dispatch Flow (After Fix)

```
agent-browser-pool <args>
        │  bin/agent-browser-pool  (line 29: cmd="${1:-status}")
        │  case (lines 30-37):
        ├─ status/reap/release/doctor ─→ pool_admin_*   (pool verb, NO lane)
        ├─ --help|-h|help             ─→ pool_admin_help (pool verb)
        └─ *)                          ─→ pool_wrapper_main "$@"
                                          │
   pool_wrapper_main (lib/pool.sh:3516)
     a. pool_config_init / pool_state_init / _pool_preflight_real_bin
     [step c DELETED — no more classify/meta passthrough]
     d. owner resolve: no pi ancestor → FAIL-FAST (pool_die)
     e-g. find-or-acquire lane
     h. ensure connected
     i. normalize close/connect args
     j. strip --session, force AGENT_BROWSER_SESSION=abpool-<N>
     k. exec real binary with CLEANED args
```

## Key Invariants Preserved

- **`--help`/`-h`/`help`** are pool verbs, caught by `bin/agent-browser-pool`'s `case`
  BEFORE `pool_wrapper_main`. They are unaffected by this fix.
- **Bare `agent-browser-pool`** (no args) defaults to `status` — also a pool verb,
  unaffected.
- **Owner-passthrough concept** (`POOL_OWNER_PID==0`, no pi ancestor) is UNRELATED to
  META dispatch passthrough. References at lines 580–581, 1005, 2089–2099 are NOT touched.
- **`_pool_preflight_real_bin`** still runs (step a) before any dispatch — it now guards
  only the driving path, not meta.
- **concurrency.sh** has ZERO meta/passthrough references — no changes needed.

## Test Framework Notes (Critical for Implementers)

- **No Makefile or test runner.** Each test file is self-running via a `BASH_SOURCE` gate.
  Run: `bash test/validate.sh`, `bash test/transparency.sh`.
- **Single-setup constraint** (AGENTS.md §4): `setup()` spawns a process; the 3rd call
  HANGS the sandbox. `transparency.sh` uses `_abpool_run_transparency_suite` (one setup()
  call, bodies run in the MAIN shell via `if "$fn"; then`). Do NOT change this pattern.
- **Test discovery**: `compgen -A function | grep '^test_'` — adding/renaming a `test_*`
  function auto-registers it.
- **`_transparency_spawn_owner`** spawns a live "pi"-comm process per test body. It sets
  `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME` and calls `pool_owner_resolve` in the main
  shell (subshell exports don't propagate).
- **`_transparency_setup_real_env`** points `AGENT_BROWSER_REAL`/`AGENT_CHROME_MASTER` at
  REAL host resources (the temp-tree master is empty → preflight would fail). Required for
  tests that actually exec the real binary.
- The fail-fast tests (no pi ancestor) must NOT call `_transparency_spawn_owner` — they
  test the path where `POOL_OWNER_PID==0`.
