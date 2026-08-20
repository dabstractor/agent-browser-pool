# PRP — P4.M1.T1.S1: Execute + verify the descending in-place §-citation renumber sweep

## Goal

**Feature Goal**: Renumber all stale PRD section citations `§2.12`–`§2.19` → `§2.13`–`§2.20` in
exactly 8 tracked files, in-place, with zero behavior change, and prove correctness with a
recorded audit matching the pre-computed distribution matrix.

**Deliverable**: The 8 files re-cited at HEAD + an audit artifact
(`plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md` or a sibling file under the work-item
dir) recording the exact commands run and actual counts observed.

**Success Definition**: Pre-flight counts match the baseline exactly; the post-sweep distribution
is `2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11` (96 total); untouched
values (`§2.10`=10, `§2.11`=3) byte-identical; `wc -l` per file identical; `bash -n` +
`shellcheck -s bash` clean on the 7 scripts (NOT README.md); `git diff --numstat` shows equal
+/- per file and zero changed lines lacking `§`; the lone `§2.16b` at lib/pool.sh:3636 became
`§2.17b`.

## Why

PRD.md at HEAD is ALREADY renumbered (human-owned, AGENTS.md §5): §2.12 = caller-scoped selection,
§2.13 CLI, §2.14 safety, §2.15 failure modes, §2.19 testing, §2.20 impl notes. Every code/test/README
citation still points at the OLD numbering — i.e., every existing `§2.12` citation now points at the
wrong section. All later subtasks in P4 (T2 config, T3 caller mode, T4 lane pin, M2 tests, M3 docs)
will cite the NEW numbering; this sweep makes the codebase consistent first so later diffs are clean.

## What

A purely mechanical, static, in-place token substitution — **no logic edits, no new features, no
test runs, no browser launches** (AGENTS.md §1: research/planning rules apply; this task launches
nothing — it is grep/perl/git only, all inherently non-blocking).

### Success Criteria

- [ ] All 8 files re-cited: occurrences of old set drop to 0; new set totals 96 across 92 lines.
- [ ] `§2.16b` (lib/pool.sh:3636) → `§2.17b` (the `\b` trap — see Gotchas).
- [ ] Untouched counts identical: `§2.10`=10, `§2.11`=3; `wc -l` identical per file (pool.sh 4695, README.md 421).
- [ ] `bash -n` OK on 7 scripts; `shellcheck -s bash` OK on 7 scripts (skip README.md — markdown).
- [ ] `git diff -U0 -- $FILES | grep -E '^[+-][^+-]' | grep -vc '§'` prints **0**; numstat +/- equal per file.
- [ ] Audit artifact records commands + actual counts proving the matrix.

## All Needed Context

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/architecture/citation_audit.md
  why: THE authoritative recipe + verification set. §5 = exact perl loop; §8 = exact verification
       commands; §1 = baseline matrix; §9 = dry-run proof on /tmp copies (already validated).
  critical: The PRD delta's "~73" was a different measurement (line counts + PRD§-restricted
       pattern) — NEVER use 73. Verification total is 96 occurrences / 92 lines.
  section: all of it; follow §5 verbatim

- file: plan/004_de5e94ac127c/architecture/synthesis.md
  why: §1 gives work-item context; confirms this subtask precedes all P4 implementation.

- file: PRD.md
  why: READ-ONLY, already renumbered at HEAD (§2.12 caller-scoped … §2.20 impl notes). NEVER
       include PRD.md in the sweep file list. AGENTS.md §5 forbids modifying it.
  gotcha: PRD.md must NOT be touched; docs/ is empty; .agents/** has only §2.7/§2/§3 refs
       (outside shift range) and must be excluded — zero-change there is required.
```

### Verified current baseline (re-checked live at PRP-writing time)

```
lib/pool.sh              occ=56 lines=55
bin/agent-browser-pool   occ=1  lines=1
install.sh               occ=2  lines=2
test/validate.sh         occ=6  lines=6
test/concurrency.sh      occ=4  lines=4
test/release_reaper.sh   occ=12 lines=10
test/transparency.sh     occ=10 lines=10
README.md                occ=5  lines=4
TOTAL                    96 occ / 92 lines
```

`git status --porcelain` currently shows ` M plan/004_de5e94ac127c/tasks.json` (orchestrator-owned
status flip) — that is expected and fine; the requirement is that NO OTHER tracked file is dirty
pre-sweep, so any post-sweep diff is attributable to the sweep alone.

### Known Gotchas (from citation_audit.md — dry-run proven)

```bash
# 1. \b IS A TRAP: sed/perl \b does NOT match §2.16b → §2.17b (word-char→word-char, no boundary).
#    A \b-based sweep was dry-run and FAILED (left distribution 2.16=26/2.17=4).
#    MANDATORY: perl lookahead (?![0-9]) — lets the letter 'b' pass through.
# 2. DESCENDING order (v=19→12) is mandatory: a token shifted by step k can only be re-matched by
#    the already-executed step for its new value → double-shift impossible.
# 3. Byte-escaped UTF-8 sign \xc2\xa7 in the perl pattern = locale-proof. Keep the § anchor;
#    never drop it (future bare numbers would match).
# 4. Post-sweep grep set must be '§2\.1[3-9]|§2\.20' — [2-9] alone misses §2.20 (11 occurrences).
# 5. shellcheck README.md is meaningless — lint only the 7 scripts.
# 6. Test citations are comment-only; transparency.sh:534 asserts message text ("pi ancestor"),
#    not § numbers — renumbering cannot change any test outcome. DO NOT run the test suite.
# 7. NEVER use sed \b. Never add PRD.md, docs/, or .agents/ to the file list.
```

## Implementation Blueprint

### Task 1: Pre-flight gate (abort if mismatch)

```bash
cd /home/dustin/projects/agent-browser-pool
FILES="lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh test/concurrency.sh test/release_reaper.sh test/transparency.sh README.md"
for f in $FILES; do printf '%s %s\n' "$f" "$(grep -oE '§2\.1[2-9]' "$f" | wc -l)"; done
# MUST print: 56 1 2 6 4 12 10 5 (in file order). If not → STOP, re-audit, do not sweep.
git status --porcelain   # no tracked file outside plan/004_de5e94ac127c/ dirty
```

### Task 2: Execute the sweep (citation_audit.md §5 verbatim)

```bash
for v in 19 18 17 16 15 14 13 12; do
  perl -pi -e "s/\\xc2\\xa72\\.$v(?![0-9])/\\xc2\\xa72\\.$((v+1))/g" $FILES
done
```

### Task 3: Verify (citation_audit.md §8 verbatim)

```bash
# (a) distribution: expect 2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11
for v in 2.12 2.13 2.14 2.15 2.16 2.17 2.18 2.19 2.20; do
  printf '%s %s\n' "$v" "$(cat $FILES | grep -oE "§${v//./\\.}" | wc -l)"; done
# (b) per-file: occ 56 1 2 6 4 12 10 5 (=96); lines 55 1 2 6 4 10 10 4 (=92)
for f in $FILES; do printf '%s occ=%s lines=%s\n' "$f" \
  "$(grep -oE '§2\.1[3-9]|§2\.20' "$f" | wc -l)" "$(grep -cE '§2\.1[3-9]|§2\.20' "$f")"; done
# (c) untouched: §2.10+§2.11 = 13 total (10+3), §2.10=10 §2.11=3
# (d) syntax + lint on 7 scripts only
for f in $FILES; do [ "$f" = README.md ] || { bash -n "$f" && shellcheck -s bash "$f" && echo "OK $f"; }; done
# (e) pure in-place edit
git diff --numstat -- $FILES | awk '$1!=$2{print "MISMATCH "$3}'   # no output
git diff -U0 -- $FILES | grep -E '^[+-][^+-]' | grep -vc '§'        # 0
grep -n '§2\.17b' lib/pool.sh                                        # line 3636 present
# wc -l per file identical to pre-sweep (pool.sh 4695, README.md 421)
```

### Task 4: Record the audit

Write `plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md` containing: the commands run,
actual pre-flight counts, actual post-sweep distribution + per-file counts, numstat output, and
the lint results. This is the deliverable later subtasks cite.

## Validation Loop

All validation is static (grep/perl/git/bash -n/shellcheck) — nothing can block; no sandbox
isolation needed because no browser/daemon/process is ever spawned. Per AGENTS.md, do NOT run the
test suite for this task (comment-only changes; proven outcome-neutral).

### Level 1: Syntax
- `bash -n` + `shellcheck -s bash` on the 7 scripts → clean (README.md excluded).

### Level 2: Matrix verification
- Task 3 commands, all counts exactly as specified in Success Definition.

### Level 3: Git purity
- numstat equal +/- per file; zero changed lines without `§`; only the 8 files modified
  (plus pre-existing orchestrator-owned `plan/**` churn, which is not yours to touch).

## Final Validation Checklist

- [ ] Distribution matrix exact: 0/10/2/24/25/5/3/16/11 for 2.12…2.20
- [ ] Per-file occ 56/1/2/6/4/12/10/5 = 96; lines 55/1/2/6/4/10/10/4 = 92
- [ ] §2.10=10, §2.11=3 unchanged; §2.17b at lib/pool.sh:3636
- [ ] `wc -l` identical per file; zero non-§ changed lines
- [ ] bash -n + shellcheck clean (7 scripts)
- [ ] PRD.md, docs/, .agents/ untouched; no test suite run; no processes spawned
- [ ] Audit artifact written under plan/004_de5e94ac127c/P4M1T1S1/research/
- [ ] AGENTS.md §6 checklist: zero orphans/temp dirs (none were created)

## Anti-Patterns to Avoid

- ❌ Never use `\b` or sed for the substitution (dry-run-proven failure on §2.16b)
- ❌ Never sweep PRD.md / docs/ / .agents/
- ❌ Never run the test suite or launch Chrome "to check nothing broke" — static proof suffices
- ❌ Never compare against the PRD's "~73" figure (different measurement; correct total = 96)
- ❌ Do not hand-edit any citation — the perl loop is the validated, uniform mechanism

**Confidence: 10/10** — the exact recipe was dry-run validated on /tmp copies with all counts
matching (citation_audit.md §9); this PRP only re-executes it in place and records the audit.