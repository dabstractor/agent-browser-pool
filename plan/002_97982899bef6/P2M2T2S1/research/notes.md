# Research Notes — P2.M2.T2.S1: Delete `bin/agent-browser` and update `bin/.gitkeep`

**Work item**: P2.M2.T2.S1 (0.5 points) — milestone P2.M2 (Entry Point & Binary Pivot).
**Status when researched**: P2.M1 complete; P2.M2.T1.S1 (dispatch rewiring) running IN PARALLEL;
this item depends on the POST-P2.M2.T1.S1 tree but is **file-disjoint** from it.
**Research method**: static only (read + `rg` + `wc` + `git ls-files`), per AGENTS.md §1. No
Chrome, no test suite, no real execution. All claims below are host-verified on the live tree.

---

## 1. The file being deleted — `bin/agent-browser` (verbatim, 13 lines / 675 bytes)

```bash
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
```

- **What it is**: the OLD PATH-shadowing entry point. Under the old model, `install.sh` symlinked
  `~/scripts/agent-browser` → this file so EVERY `agent-browser` call was intercepted by the wrapper
  (which sourced `lib/pool.sh` and called `pool_wrapper_main "$@"`).
- **Why obsolete now**: PRD §2.1 (h3.5) + §2.17 (h3.21) establish the NEW model — there is **no PATH
  shadowing**; `~/.local/bin/agent-browser` is the REAL Vercel CLI (unshadowed, upgradable); the SOLE
  pool entry point is `~/.local/bin/agent-browser-pool` → repo `bin/agent-browser-pool`. After
  P2.M2.T1.S1 rewires `bin/agent-browser-pool`'s `*)` arm to `pool_wrapper_main "$@"`, driving
  commands route through `agent-browser-pool` directly — the shim has no remaining purpose.
- **PRD §3 (h2.2)** repository layout does NOT list a `bin/agent-browser` file — confirms deletion is
  the target end state.

## 2. Git tracking state (host-verified)

```
$ git ls-files bin/
bin/.gitkeep
bin/agent-browser        ← tracked (13 lines, 675 bytes)
bin/agent-browser-pool   ← tracked (25 lines, 1185 bytes)
```

- `bin/agent-browser` is **git-tracked**, so the canonical removal is `git rm bin/agent-browser`
  (removes from working tree + stages the deletion). `bin/.gitkeep` is **empty (0 bytes)** and stays.
- After deletion: `git ls-files bin/` → only `bin/.gitkeep` + `bin/agent-browser-pool`. The `bin/`
  directory stays non-empty (two files remain), so the dir remains tracked regardless of `.gitkeep`.
  `.gitkeep` is kept per the item contract (step d) — no action needed on it.

## 3. Reference map — everything that mentions the repo shim, and WHO owns each

> Critical for scope discipline: this item deletes ONLY `bin/agent-browser`. Several other files
> still mention it. **None of them are owned by this item.** They are listed here so the implementer
> (a) does NOT "helpfully" edit them (scope violation + touches other items' work) and (b)
> understands the dangling references are EXPECTED and tracked by downstream items.

### 3a. `lib/pool.sh` — THREE stale COMMENTS (NOT touched by this item)

| line | text | verdict |
|------|------|---------|
| 7    | `#   - bin/agent-browser       (the transparent PATH-shadowing wrapper shim)` | stale comment after deletion |
| 96   | `# of bin/agent-browser and bin/agent-browser-pool (and re-callable for tests).` | stale comment after deletion |
| 3564 | `# PRD §2.4 steps 0→5 — the orchestration entry point. Called by bin/agent-browser` | stale comment after deletion |

- These are **comments**, not code. No line of `pool.sh` sources/execs the shim by relative path
  (host-verified: `rg -n 'source.*\.\./bin/agent-browser|exec.*bin/agent-browser([^-]|$)' lib/` → none).
- The item contract (step c) explicitly states: **"No code changes needed in pool.sh."** → these
  comments stay (harmless doc cruft). A later sweep or P2.M1-equivalent may tidy them; NOT this item.

### 3b. `lib/pool.sh` lines 103 + 152 — NOT the shim (do not conflate)

```
103: #   AGENT_BROWSER_REAL             $HOME/.local/bin/agent-browser   POOL_REAL_BIN  path (may not exist)
152:         "${AGENT_BROWSER_REAL:-$POOL_HOME_DIR/.local/bin/agent-browser}")"
```
- These reference `~/.local/bin/agent-browser` — the **REAL Vercel CLI** path (PRD §2.1), which is
  the runtime dependency the pool calls by absolute path. This is CORRECT and must NOT change. It is
  a different path from the repo shim `bin/agent-browser`. Deleting the repo shim has zero effect on
  these lines.

### 3c. `install.sh` — owned by P2.M3.T1.S1 (COMPLETE REWRITE)

`install.sh` references the shim ~20× (lines 6, 16, 28, 59, 73, 93, 96, 110, 204, 205, 213, 216 …).
This is the OLD cutover installer. P2.M3.T1.S1 does a complete rewrite to the no-shadow model (per
gap_analysis §4). Until then install.sh is dead code referencing a deleted file — expected, owned
downstream. **This item does NOT touch install.sh.**

### 3d. `test/validate.sh` — owned by P2.M5.T1.S1

- Line 26: `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"`
- Line 313-314: selftest consumes `ABPOOL_WRAPPER` + asserts `-x "$ABPOOL_WRAPPER"`.
- After this item's deletion, these point at a non-existent path. P2.M5.T1.S1 removes
  `ABPOOL_WRAPPER` + the `selftest_config_disable` block (gap_analysis §8). The git dependency graph
  orders P2.M5 AFTER P2.M2 → this dangling window is by design. **Per AGENTS.md §1, we do NOT run
  the test suite during this item**, so the dangling ref causes no harm.

### 3e. `test/transparency.sh` — owned by P2.M5.T2.S1 (rewrite)

- Lines 179, 233, 247, 320, 394 invoke `$ABPOOL_WRAPPER`. Complete rewrite in P2.M5.T2.S1.
- `test/concurrency.sh:12` + `test/release_reaper.sh` comments — owned by P2.M5.T3.S1.
- Same as 3d: dangling-by-design until P2.M5; not run here.

### 3f. `README.md` — owned by P2.M6.T1.S1 (complete rewrite)

Lines 24, 39, 52, 79, 213, 243 mention `bin/agent-browser` / the shadow model. P2.M6 rewrites the
whole README. **This item does NOT touch README.md.**

### 3g. `PRD.md` — READ-ONLY (human-owned)

PRD §2.1 (line 91), §2.11 (line 268), §2.16 (line 332) reference `~/.local/bin/agent-browser` = the
REAL CLI. These describe the NEW (correct) model and are NOT about the repo shim. **Never touch
PRD.md.**

## 4. Operator-side state — NOT this item's concern (AGENTS.md §1)

- `~/.local/bin/agent-browser` = the REAL Vercel CLI (a real binary, NOT a symlink to our repo).
  Deleting repo `bin/agent-browser` does **not** affect it. (PRD §2.1 confirms "unchanged".)
- A prior OLD-model install may have left `~/scripts/agent-browser` → repo `bin/agent-browser`. After
  deletion that symlink would dangle. Its cleanup is **P2.M3's** new install.sh job (cutover). This
  item must NOT touch the operator's real `$HOME` (AGENTS.md §1/§5) and does NOT run install.sh.

## 5. Composition with the parallel item P2.M2.T1.S1 (dispatch rewiring)

- P2.M2.T1.S1 edits `bin/agent-browser-pool` (the `*)` arm: error → `pool_wrapper_main "$@"`; +
  header comment reframe). This item edits `bin/agent-browser` (deletes it). **The two files are
  disjoint** → the items compose in either order with zero conflict.
- **Implication for validation design**: this item's verification of `bin/agent-browser-pool` must
  be AGNOSTIC to the dispatch content (the `*)` arm is mid-flight in parallel). So assert only on:
  file **exists** + **executable** + `bash -n` **clean** (syntax). Do NOT assert on whether the `*)`
  arm reads `Unknown command` or `pool_wrapper_main` — that is P2.M2.T1.S1's region. `bash -n` passes
  for either form (both are valid syntax), so the check is robust to the parallel change.

## 6. Validation strategy (all STATIC — AGENTS.md §1)

No runtime behavior is introduced or removed by a file deletion, so Levels 2-4 of the PRP template
(no unit/component/integration runtime tests) are N/A. The entire validation is Level-1 static:

1. `git rm bin/agent-browser` → removes the file (working tree + staged).
2. `test ! -e bin/agent-browser` → gone.
3. `test -x bin/agent-browser-pool` → sole entry point still executable.
4. `bash -n bin/agent-browser-pool` → still syntactically valid (unchanged by THIS item; passes
   regardless of the parallel `*)` rewiring).
5. `test -f bin/.gitkeep` → kept (empty, 0 bytes).
6. `git ls-files bin/` → exactly `bin/.gitkeep` + `bin/agent-browser-pool` (no `bin/agent-browser`).
7. `git status --short -- bin/` → shows the staged deletion (`D  bin/agent-browser`).

Optional non-regression (static): `shellcheck -s bash bin/agent-browser-pool` output unchanged by
this item (it isn't edited here; only the pre-existing SC1091 info remains) — but this is owned by
P2.M2.T1.S1's baseline, so assert "no change" only loosely.

## 7. Confidence / risk

- **Trivial, deterministic deletion.** The contract is explicit (item steps a-e), the file is
  identified verbatim, git tracking is confirmed, and every dangling reference is mapped to its
  downstream owner.
- **Only real risk**: an implementer "tidying up" stale comments in `lib/pool.sh` (§3a) or fixing
  `install.sh`/`test/*`/`README.md` (§3c-3f) — each a scope violation against another item. The PRP
  must make the out-of-scope boundary LOUD and explicit.
- **Confidence: 10/10** for one-pass success.
