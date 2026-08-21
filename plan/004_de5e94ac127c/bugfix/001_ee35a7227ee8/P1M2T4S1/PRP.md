# PRP — P1.M2.T4.S1: Fix validate.sh ROOT to resolve to the repo root (BUG-006)

name: "BUG-006 validate.sh ROOT path fix"
description: One-line bootstrap fix in plan/004_de5e94ac127c/validate.sh so the committed validation artifact runs green as shipped from any CWD.

---

## Goal

**Feature Goal**: `plan/004_de5e94ac127c/validate.sh` resolves `ROOT` to the **repository root** instead of its own directory, so all repo-relative invocations inside the script (`bash bin/agent-browser-pool`, `bash install.sh`, `bash test/validate.sh`, the lint loop) resolve correctly when the script is run as committed: `bash plan/004_de5e94ac127c/validate.sh [--fast]` from anywhere.

**Deliverable**: The edited `plan/004_de5e94ac127c/validate.sh` (ROOT line 24 + refreshed usage comment).

**Success Definition**: Running `timeout 900 bash plan/004_de5e94ac127c/validate.sh --fast` from the repo root completes its P1/P2 phases with **zero** `No such file or directory` failures (i.e., no rc-127 path errors). The full 89-check green run is P1.M3.T1.S1's responsibility, not this item's.

## Why

- BUG-006 (PRD h2.3 Issue 4 / h3.5): as committed, the script cds into `plan/004_de5e94ac127c/` where no `bin/` or `install.sh` exists → 'passed: 25 failed: 64', every failure an rc-127 path error. The validation_report.md's "86+ checks pass" is not reproducible from the committed tree.
- The underlying checks ARE green (verified: run from a scratch dir with repo symlinks → 88/0). Only the bootstrap is broken.

## What

Change line 24 of `plan/004_de5e94ac127c/validate.sh` from:

```bash
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
```

to:

```bash
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
```

Keep line 25 (`cd "$ROOT"`) unchanged — everything downstream already assumes repo-root CWD after that cd. The script lives at `<repo>/plan/004_de5e94ac127c/validate.sh`, so `dirname/../..` is the repo root.

Refresh the top-of-file usage comment (the block around lines 2–8) to state it runs from anywhere, e.g. add 2–3 lines:

```bash
# Usage: bash plan/004_de5e94ac127c/validate.sh [--fast]
#   May be invoked from any CWD; the script cds to the repo root itself.
#   --fast skips the real-Chrome suites.
```

## All Needed Context

### Context Completeness Check

The only file touched is `plan/004_de5e94ac127c/validate.sh`. All facts below were verified by reading it.

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/validate.sh
  why: The file being fixed; understand its bootstrap (lines 24-25), --fast flag (line 31),
       and its repo-relative invocations
  pattern: "ROOT=.../ cd \"$ROOT\" at 24-25; P1 lint loop uses relative paths bin/..., lib/pool.sh,
       install.sh, test/*.sh; later phases run `bash bin/agent-browser-pool`, `bash install.sh`,
       `bash test/validate.sh`"
  gotcha: Keep `readlink -f "${BASH_SOURCE[0]}"` for symlink safety — only append /../..
          INSIDE the cd argument. Do not introduce a second variable (no REPO_ROOT).

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M2T3S1/PRP.md
  why: Sibling item running in parallel (BUG-005 help-text fix in lib/pool.sh help output)
  pattern: Do not touch lib/pool.sh help text here; the validate.sh P2 contract checks may
           read help output but this PRP only edits validate.sh's bootstrap — no conflict.
```

### Current Codebase (relevant excerpt)

```bash
# plan/004_de5e94ac127c/validate.sh:24-25
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"
```

Repo-relative consumers inside the script (all resolve once ROOT == repo root): P1 lint loop (bin/, lib/, install.sh, test/*), e2e invocations `bash bin/agent-browser-pool`, `bash install.sh`, `bash test/validate.sh`.

### Known Gotchas

- **Ownership**: `plan/**/tasks.json`, `PRD.md`, `prd_snapshot.md`, `prd_index.txt` are orchestrator/human-owned — DO NOT touch. `validate.sh` is NOT in that list; fixing it is explicitly mandated by the PRD (h2.5 Recommendations). Modify nothing else under `plan/`.
- **AGENTS.md isolation**: never run the suite against live `$HOME`. If you run it at all, run `--fast` in an isolated temp tree (the script already builds its own sandbox under `mktemp`, with HOME/state/ephemeral redirected — but verify before running) and wrap in `timeout`.
- Do not "improve" other parts of the script. Minimal diff: line 24 + usage comment.

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: MODIFY plan/004_de5e94ac127c/validate.sh
  - CHANGE line 24 to: ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
  - KEEP: line 25 `cd "$ROOT"`; the readlink -f; the --fast parsing; everything else
  - REFRESH: top-of-file comment block to document `bash plan/004_de5e94ac127c/validate.sh [--fast]`
    runs from any CWD

Task 2: VERIFY statically
  - bash -n plan/004_de5e94ac127c/validate.sh          # syntax
  - shellcheck -s bash plan/004_de5e94ac127c/validate.sh  # zero new error/warning
  - Confirm ROOT math: script path <repo>/plan/004_de5e94ac127c/validate.sh
    → dirname = <repo>/plan/004_de5e94ac127c → /../.. = <repo>

Task 3: VERIFY at runtime (R9) — isolated + timeout-bounded only
  - From the repo root: timeout 900 bash plan/004_de5e94ac127c/validate.sh --fast 2>&1 | tee /tmp/r9.log
  - grep -c 'No such file or directory' /tmp/r9.log   # MUST be 0
  - P1 lint + P2 contract phases must show no path-related FAILs
  - Do NOT chase full 89-check green — that is P1.M3.T1.S1's gate
```

### Implementation Notes

```bash
# The one-line fix (exact):
# BEFORE
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# AFTER
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
```

## Validation Loop

### Level 1: Syntax (static, always safe)

```bash
bash -n plan/004_de5e94ac127c/validate.sh
shellcheck -s bash plan/004_de5e94ac127c/validate.sh
# Expected: clean / no NEW findings vs. before the edit
```

### Level 2: Runtime R9 path check (isolated, timeout-bounded)

```bash
timeout 900 bash plan/004_de5e94ac127c/validate.sh --fast 2>&1 | tee /tmp/r9-p1m2t4s1.log
grep 'No such file or directory' /tmp/r9-p1m2t4s1.log   # expect no matches
# P1/P2 phase sections must contain no FAIL lines caused by missing paths.
```

Per AGENTS.md: this script builds its own sandbox (temp HOME/state/ephemeral, fake chrome) and
`--fast` skips real-Chrome suites, so an isolated bounded run is acceptable; if anything wedges
or produces no output within seconds, abort and reason from code. Reap anything spawned; leave
no temp dirs.

## Final Validation Checklist

- [ ] Line 24 changed exactly as specified; `cd "$ROOT"` and readlink kept
- [ ] Usage comment documents run-from-anywhere + `--fast`
- [ ] `bash -n` + `shellcheck` clean (no new findings)
- [ ] R9: `--fast` run from repo root shows zero `No such file or directory`
- [ ] No other file under `plan/` (or anywhere) modified
- [ ] No orphan processes / temp dirs left behind

## Anti-Patterns to Avoid

- ❌ Do not introduce a `REPO_ROOT` variable or restructure the bootstrap — one-line fix
- ❌ Do not run the full (non-fast) suite here
- ❌ Do not run anything against live `$HOME` / real state dirs

**Confidence Score: 10/10** — verified one-line fix with a deterministic runtime check.