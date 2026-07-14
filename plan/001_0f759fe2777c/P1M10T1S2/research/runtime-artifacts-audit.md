# Runtime Artifacts Audit — .gitignore coverage for P1.M10.T1.S2

> Source of truth: the implemented code (`lib/pool.sh`, `install.sh`, `test/validate.sh`) +
> the live repo state (`git ls-files`, `git status --ignored`, current `.gitignore`).
> All facts extracted statically (no Chrome booted — AGENTS.md §1).

## 1. Every runtime artifact the system can CREATE (and WHERE)

All of these are written under a single configurable root, `$POOL_STATE_DIR`, whose default
is **`$HOME/.local/state/agent-browser-pool`** — i.e. **OUTSIDE the repo working tree**.

| Artifact | Created at | Code ref (lib/pool.sh) | Extension |
|---|---|---|---|
| Main pool log | `$POOL_STATE_DIR/pool.log` | `_pool_log` @ line 25 (`${AGENT_BROWSER_POOL_STATE:-…}/pool.log`) | `.log` |
| Per-lane Chrome log | `$POOL_STATE_DIR/chrome-<lane>.log` | `pool_boot_lane` @ line 1494 | `.log` |
| Exhaustion alert log | `$POOL_STATE_DIR/alerts.log` | `_pool_alert` @ line 2826 | `.log` |
| Runtime lease files | `$POOL_STATE_DIR/lanes/<N>.json` | `POOL_LANES_DIR` = `$POOL_STATE_DIR/lanes` @ line 181; read at 1059/1335 | `.json` |
| flock critical-section lock | `$POOL_STATE_DIR/acquire.lock` | `pool_state_init` @ line 203 (`mkdir -p lanes/` + touch lock); install.sh line 143 | (no ext) |

Ephemeral profile trees (CoW copies of the master) are created under
`$POOL_EPHEMERAL_ROOT` = **`$HOME/.agent-chrome-profiles/active/<N>`** (lines 141, 1246-1273) —
also OUTSIDE the repo. The master template is `$HOME/.agent-chrome-profiles/master-profile`.

**Conclusion:** In normal operation **zero runtime artifacts are written into the repo.**
`.gitignore` therefore exists as **defense-in-depth** for the one override scenario: a
developer exporting `AGENT_BROWSER_POOL_STATE` (or `AGENT_CHROME_EPHEMERAL_ROOT`) to a path
*inside* the repo, or running the pool with a cwd-relative state dir.

## 2. Is `.state/` actually used? (the work item's "if used locally" qualifier)

`grep -rn '\.state/' lib/ install.sh bin/ test/` → **zero matches.** The string `.state/`
appears NOWHERE in code, tests, or install. The system's real state dir is the absolute
`~/.local/state/agent-browser-pool`. So the existing `.state/` gitignore entry is a
**vestigial / generic catch-all** — it does not correspond to any path the system writes.
It is harmless (kept defensively), but the implementer should treat it as "generic state-dir
catch-all", not as a real artifact location, and document it as such.

## 3. Test harness isolation — do tests drop artifacts in the repo?

NO. `test/validate.sh`:
- line 186: `ABPOOL_TEST_ROOT="$(mktemp -d -t abpool-test.XXXXXX)"`
- line 189: `export HOME="$ABPOOL_TEST_ROOT/home"`
- line 190: `export AGENT_BROWSER_POOL_STATE="$ABPOOL_TEST_ROOT/state"`

So every test run redirects state + HOME to a throwaway `/tmp` tree, then `trap`s its removal.
**No test writes into the repo cwd.** The `.gitkeep` files in `bin/` and `test/` are the only
non-script files there and are intentionally tracked placeholders.

## 4. Current `.gitignore` (verbatim) + coverage verdict

```
1  # runtime / install artifacts (not version-controlled)
2  *.log
3
4  # local dev symlinks / state
5  .state/
6
7  # agent harness runtime artifacts (transcripts, meta, outputs)
8  .pi-subagents/
9
10 # environment files
11 .env
12 .env.*
13 !.env.example
14
15 # OS-specific files
16 .DS_Store
17 Thumbs.db
18
19 # build artifacts
20 dist/
21 build/
22
23 # dependency directories
24 node_modules/
25 venv/
26 __pycache__/
```

Verdict against the work-item's required runtime exclusions:

| Required exclusion (item §3 LOGIC) | Current coverage | Action |
|---|---|---|
| `*.log` (chrome-*.log, alerts.log, pool.log) | ✅ line 2 `*.log` matches ALL three | KEEP; add comment enumerating them |
| `.state/` (if used locally) | ✅ line 5 present | KEEP as catch-all; it is NOT used by the system (§2) but harmless defensively |
| `lanes/*.json` (runtime leases) | ⚠️ only covered transitively via `.state/` IF an override uses that name | DOCUMENT (outside-repo by default; catch-all covers override); optionally add `acquire.lock` for explicitness |
| `acquire.lock` (flock) | ⚠️ NOT explicitly covered | ADD `acquire.lock` (the only runtime artifact with a non-`.log` extension) |
| `plan/` must NOT be ignored | ✅ not matched by any pattern (confirmed tracked via `git ls-files`) | KEEP un-ignored; add a COMMENT stating plan/ is intentionally tracked (never a gitignore ENTRY — AGENTS.md §5) |

## 5. What the repo MUST continue to track (do not accidentally ignore)

From `git ls-files`, the intentionally-tracked source + history set:

- Source: `README.md`, `PRD.md`, `AGENTS.md`, `.gitignore`, `install.sh`, `bin/agent-browser`,
  `bin/agent-browser-pool`, `bin/.gitkeep`, `lib/pool.sh`, `test/*.sh`, `test/.gitkeep`
- History: `plan/001_0f759fe2777c/**` (PRPs, research/, architecture/, tasks.json, prd_*)

**None** of these are matched by the current `.gitignore` (verified: `*.log` matches no tracked
file; `.state/`/`.pi-subagents/` match no tracked dir). The work item's "only tracks" list
(`README.md, PRD.md, .gitignore, install.sh, bin/*, lib/*, test/*`) is slightly stale — it
omits `AGENTS.md` (a legit source file, must stay tracked) and `plan/` (explicitly tracked for
history). The implementer must preserve ALL of these and must NOT add ignore entries for
`plan/`, `PRD.md`, or `tasks.json` (AGENTS.md §5 + FORBIDDEN OPERATIONS).

## 6. Validation tooling — `git check-ignore` (static, no Chrome, AGENTS.md §1-safe)

`.gitignore` has no linter like shellcheck; the authoritative check is git itself:

```bash
# (a) confirm a runtime artifact path WOULD be ignored (path need NOT exist on disk):
git check-ignore -v chrome-1.log        # → .gitignore:2:*.log   chrome-1.log   (exit 0)
git check-ignore -v alerts.log          # → .gitignore:2:*.log   alerts.log     (exit 0)
git check-ignore -v pool.log            # → .gitignore:2:*.log   pool.log       (exit 0)
git check-ignore -v .state/lanes/1.json # → .gitignore:5:.state/ ...             (exit 0)
git check-ignore -v acquire.lock        # → (after ADD) matches                  (exit 0)

# (b) confirm plan/ and source files are NOT ignored (must exit 1 = not ignored):
git check-ignore plan/001_0f759fe2777c/PRD.md         # → exit 1 (good)
git check-ignore lib/pool.sh                          # → exit 1 (good)

# (c) confirm NO currently-tracked file is accidentally ignored:
git ls-files | while read -r f; do git check-ignore -q "$f" && echo "LEAK: $f is ignored!"; done
# → must print NOTHING.

# (d) clean working tree (no stray untracked runtime files):
git status --short --ignored    # only .pi-subagents/ (and .git/) should appear under !!
```

`git check-ignore` operates on path STRINGS, so it needs no real files on disk and never boots
Chrome — fully compliant with AGENTS.md §1 (static checks only during planning/research).

## 7. AGENTS.md §5 / FORBIDDEN-OPERATIONS interaction — SCOPED AUTHORIZATION

AGENTS.md §5 lists `.gitignore` as "orchestrator-owned" and the PRP prompt's FORBIDDEN list
says "Never add plan/, PRD.md, or task files to gitignore." Work item P1.M10.T1.S2 is the
**orchestrator's explicit, scoped instruction** to update `.gitignore` for runtime artifacts.
Therefore:
- ✅ AUTHORIZED: adding ignore PATTERNS for runtime artifacts (`*.log`, `.state/`, `acquire.lock`)
  and clarifying COMMENTS.
- ❌ FORBIDDEN: any ignore ENTRY (positive or negated) that targets `plan/`, `PRD.md`, or
  `tasks.json`. (A plain `# comment` mentioning plan/ is tracked is fine — it is not an entry.)
- The implementer edits ONLY `.gitignore`; no other file.
