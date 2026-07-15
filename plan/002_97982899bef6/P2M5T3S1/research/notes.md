# Research Notes — P2.M5.T3.S1: Update comments in concurrency.sh & release_reaper.sh

**Scope**: comment-only edits to `test/concurrency.sh` + `test/release_reaper.sh`. **No
functional changes.** The test logic is correct; only prose comments use the stale
"wrapper" / deleted-`bin/agent-browser` vocabulary from the pre-P2.M2 PATH-shadowing era.

## Verified shipped state (read-only checks — AGENTS.md §1: static only)

- `bin/` contains ONLY `agent-browser-pool` + `.gitkeep`. The old `bin/agent-browser`
  PATH-shadowing shim is **DELETED** (P2.M2.T2.S1 — verified `test -e bin/agent-browser` → ABSENT).
- `bin/agent-browser-pool` dispatch (lines 20-26):
  `status|reap|release|doctor|--help|-h|help` → `pool_admin_*`; `*) pool_wrapper_main "$@"`.
- `pool_wrapper_main` is a **REAL FUNCTION** at `lib/pool.sh:3619` — the driving-command
  dispatcher. `release_reaper.sh` test e (`test_close_then_rebind`) **CALLS IT DIRECTLY** at
  line 395: `( pool_wrapper_main close )`. This is CODE, not a comment → it and every
  `pool_wrapper_main` symbol reference MUST stay.
- shellcheck baselines (both files): `rc=1` with **ONLY 2× SC1091** (the
  `# shellcheck source=./validate.sh` infos). No other codes. Gate = no NEW codes, rc=1 expected.
- `bash -n` both files → exit 0 (clean).

## CRITICAL distinction the implementer must NOT get wrong

| term in the files | what it means | action |
|---|---|---|
| `pool_wrapper_main` (symbol) | the REAL driving-dispatcher FUNCTION in lib/pool.sh, called by test e | **KEEP** (real code/symbol) |
| "the wrapper" (prose) | the OLD `bin/agent-browser` PATH-shadowing shim concept (now deleted) | **UPDATE** → "the pool entry point (bin/agent-browser-pool)" or "pool_wrapper_main" (the function) |
| "the real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser` | the REAL Vercel `agent-browser` CLI binary | **KEEP — already correct** (item contract point 1) |
| `agent-browser-pool release/reap` (admin verbs) | the pool entry point's admin dispatch | **KEEP — already correct** (item contract point 3b line 20) |

The single failure mode: confusing "the wrapper" (stale prose → update) with
`pool_wrapper_main` (real symbol → keep) with "the real agent-browser" (real CLI → keep).

## Exact prose-'wrapper' edit inventory (7 edits across 2 files)

### concurrency.sh — 3 prose sites, NO `pool_wrapper_main` symbol in this file
(grep verified: every `wrapper` hit here is prose; after edits `grep -c wrapper` → **0**)

- **C1** (header HOW IT WORKS, L12-13): "the wrapper (bin/agent-browser → pool_wrapper_main)"
  → "the pool entry point (bin/agent-browser-pool → pool_wrapper_main)"; "a wrapper-driven
  `open` test" → "a pool-driven `open` test".
- **C2** (`_concurrency_run_one_lane` WHY comment, L158): "not the wrapper" → "not via the
  pool entry point"; "the wrapper exec's into" → "pool_wrapper_main exec's into".
  (Next line L159 "the real agent-browser" stays — correct.)
- All other `agent-browser` refs in concurrency.sh (L14, L55-56, L129, L131, L135-136, L159)
  correctly refer to the REAL CLI → **unchanged**.

### release_reaper.sh — 8 prose sites + the `pool_wrapper_main` symbol (kept)
(grep verified: after edits `grep -nE 'wrapper' | grep -vE 'pool_wrapper_main'` → **0**;
 every remaining `wrapper` is the `pool_wrapper_main` symbol)

Prose → update:
- **R1** (header HOW IT WORKS, L16-21): "NOT the wrapper" → "NOT via the pool entry point
  (agent-browser-pool)"; "for driving commands exec's into the real agent-browser" (keeps
  "real agent-browser" + adds "$POOL_REAL_BIN"); "a wrapper-driven test" → "a pool-driven test";
  "the wrapper exec's" → "pool_wrapper_main exec's"; "the wrapper's terminal exec" →
  "pool_wrapper_main's terminal exec". (Satisfies item line-17 instruction: "agent-browser-pool
  for driving commands" now appears.)
- **R2** (test d close comment, L331-333): "The wrapper exec's" → "pool_wrapper_main exec's";
  "the wrapper's terminal exec" → "pool_wrapper_main's terminal exec". (Keeps "rc is 0 on
  agent-browser 0.28.0" — refers to the real CLI version, correct.)
- **R3** (test e body, L390-391): "THROUGH the wrapper (pool_wrapper_main)" → "THROUGH
  pool_wrapper_main"; "The wrapper ends in exec" → "pool_wrapper_main ends in exec".
- **R4** (test e assertion STRING, L400): "close (via wrapper)" → "close (via pool_wrapper_main)".
- **R5** (test e body, L405): "the wrapper's step h" → "pool_wrapper_main's step h".

Symbol → KEEP (NOT edits):
- L365 "BYPASSES pool_wrapper_main", L368 "runs close THROUGH pool_wrapper_main",
  L376 "( pool_wrapper_main close ) subshell", L395 `( pool_wrapper_main close )` (the call).

## Why the gate differs from the T2.S1 (transparency.sh) PRP

The T2.S1 PRP set `grep -c wrapper → 0` because transparency.sh has NO `pool_wrapper_main`
symbol. **release_reaper.sh DOES** (test e calls the function), so its gate is
`grep -nE 'wrapper' test/release_reaper.sh | grep -vE 'pool_wrapper_main'` → 0
(i.e. every remaining `wrapper` is the `pool_wrapper_main` symbol). Setting `grep -c wrapper → 0`
for release_reaper.sh would be WRONG — it would force renaming the real `pool_wrapper_main`
symbol/call, which is a functional change explicitly forbidden by the item ("No functional
changes needed").

## Out of scope (explicitly preserved — do NOT touch)

- `test/validate.sh` (P2.M5.T1.S1 owns it), `test/transparency.sh` (P2.M5.T2.S1 owns it).
- `lib/pool.sh`, `bin/*`, `install.sh`, all `*.md`, `PRD.md`, `plan/**/prd_snapshot.md`,
  `plan/**/tasks.json`, `.gitignore` — read-only.
- All "real agent-browser" / `$POOL_REAL_BIN` / `~/.local/bin/agent-browser` references (REAL CLI).
- All `agent-browser-pool release/reap` admin-verb references (already correct).
- The `pool_wrapper_main` symbol + its direct call in test e (real code).

## Validation approach (AGENTS.md §1/§6 — STATIC ONLY)

- `bash -n` both files → exit 0 (no syntax regression — comments only, but assert anyway).
- `shellcheck -s bash` both files → only the 2× SC1091 infos; rc=1 EXPECTED; no NEW codes.
- grep assertions: concurrency `wrapper` → 0; release_reaper prose `wrapper` (excl.
  `pool_wrapper_main`) → 0; `agent-browser-pool` + `real agent-browser` + `$POOL_REAL_BIN`
  references PRESERVED (count non-decreasing).
- `git status --short` → only the two test files modified.
- **NEVER** run `bash test/concurrency.sh` / `bash test/release_reaper.sh` — they boot real
  Chrome + spawn sim-owners (sandbox-wedge risk, AGENTS.md §1/§3/§4).
