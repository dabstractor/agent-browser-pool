# Citation audit — PRD section renumber sweep (R1): old §2.12–§2.19 → new §2.13–§2.20

Scope: `lib/pool.sh`, `bin/agent-browser-pool`, `install.sh`, `test/{validate,concurrency,release_reaper,transparency}.sh`, `README.md`.
Method: static only (grep/read/git-log). No browser, no tests, no repo binary launched. No repo file modified.

## 1. Authoritative baseline (what the sweep + verification MUST preserve)

Every `§2.1x` citation token in the repo is sign-prefixed (UTF-8 `c2 a7`, verified by hexdump).
There are **zero** bare tokens, **zero** hyphen ranges (`§2.12-2.15` style: NONE exist),
**zero** HTML entities (`&sect;`), **zero** written-out forms (`PRD 2.12`, `sec 2.12`, `section 2.12`, `S2.12` — NONE),
**zero** sign+space forms (`§ 2.12`), **zero** doubled signs (`§§`).

Baseline occurrences of the to-be-shifted set `§2.1[2-9]` (lines in parens; a line with 2 tokens counts once):

| file                        | §2.12 | §2.13 | §2.14 | §2.15 | §2.16 | §2.17 | §2.18 | §2.19 | TOTAL occ (lines) |
|-----------------------------|------:|------:|------:|------:|------:|------:|------:|------:|-------------------|
| lib/pool.sh                 |     8 |     0 |    18 |    13 |     5 |     0 |     3 |     9 | **56** (55)       |
| bin/agent-browser-pool      |     1 |     0 |     0 |     0 |     0 |     0 |     0 |     0 | **1** (1)         |
| install.sh                  |     0 |     0 |     0 |     1 |     0 |     1 |     0 |     0 | **2** (2)         |
| test/validate.sh            |     0 |     2 |     0 |     1 |     0 |     1 |     2 |     0 | **6** (6)         |
| test/concurrency.sh         |     0 |     0 |     0 |     0 |     0 |     0 |     4 |     0 | **4** (4)         |
| test/release_reaper.sh      |     0 |     0 |     4 |     1 |     0 |     0 |     6 |     1 | **12** (10)       |
| test/transparency.sh        |     0 |     0 |     0 |     9 |     0 |     0 |     0 |     1 | **10** (10)       |
| README.md                   |     1 |     0 |     2 |     0 |     0 |     1 |     1 |     0 | **5** (4)          |
| **TOTAL**                   |    10 |     2 |    24 |    25 |     5 |     3 |    16 |    11 | **96** (92)        |

Post-sweep expectation (occurrences): §2.12=0, §2.13=10, §2.14=2, §2.15=24, §2.16=25, §2.17=5,
§2.18=3, §2.19=16, §2.20=11; per-file totals 56/1/2/6/4/12/10/5 (sum 96, lines still 92).

Untouched values that MUST stay identical: `§2.10`=10 (pool 7 + release_reaper 3),
`§2.11`=3 (pool.sh:21,203,227), `§2.9`=10, `§2.8`=11, `§2.7`=11 (incl. 2 in .agents/), etc.
Research-note citations must stay identical: bare `§2`×20, `§3`×34, `§4`×22, `§5`×13, `§6`×7,
`§7`×4, `§0`×1, `§1`×16, and dotted research refs `§1.1`×4, `§1.2`×4, `§1.3`×10, `§1.4`×1,
`§1.5`×2, `§3.2`×2, `§4.4`×1, `§6.1`×1. AGENTS.md refs (e.g. `AGENTS.md §1`, `§3`) also untouched.

## 2. Reconciliation: PRD's "~73" vs quick count 96 vs true 96

- The delta PRD's per-file numbers (36/1/2/6/4/10/10/4 = 73) are **line counts**, not occurrence
  counts — for 7 of 8 files they match today's *line* counts exactly (bin 1, install 2, validate 6,
  concurrency 4, release_reaper 10, transparency 10, README 4). Two files have two tokens on one
  line (release_reaper 12 occ/10 lines; README 5 occ/4 lines), so line counts undercount by 3.
- pool.sh is the real discrepancy: claimed 36, actual 55 lines / 56 occurrences. 36 is **exactly**
  the line count of the restricted pattern `PRD §2.1[2-9]` (word "PRD" immediately before the sign)
  in pool.sh today — stable across the last 3 commits (ed31938, a3fa197, f687b3f all show 56/55/36),
  so the file did not grow; the estimator used the narrower `PRD §`-prefixed pattern for pool.sh
  and/or mixed lines-vs-occurrences. The 20 pool.sh citations lacking a literal `PRD ` prefix
  (standalone `§2.14`, `+ §2.19`, slash-chain tails) were missed.
- **Verdict: 73 was measured differently (line counts + a `PRD §`-restricted pattern for pool.sh),
  not merely stale.** The quick count of 96 is CORRECT: 96 sign-prefixed `§2.1[2-9]` occurrences on
  92 lines, and `grep -oE '2\.1[2-9]'` (sign not required) also returns exactly 96 — i.e. no bare
  `2.1x` string exists anywhere in the sweep targets. Verification must use **96/92**, not 73.

## 3. Token-form catalog (all forms; examples are real file:line)

1. **Parenthesized `(PRD §N.N)`** — dominant form.
   - lib/pool.sh:452 `…(PRD §2.4)…`, lib/pool.sh:521 `…(TEST-ONLY, PRD §2.15…)`, test/validate.sh:3.
2. **`PRD §N.N` mid-sentence, unparenthesized** — lib/pool.sh:21 `Per PRD §2.11 the`, bin/agent-browser-pool:4.
3. **Markdown link `[PRD.md §N.N](./PRD.md)`** — README.md:81 `[PRD.md §2.17](./PRD.md)`, README.md:250, :286.
4. **Standalone `§N.N` with no `PRD` prefix** — lib/pool.sh:293 `and §2.14 (a missing master must fail…)`,
   lib/pool.sh:1836 `§2.19 (kill -- -<pgid>)`, lib/pool.sh:4256 `§2.16 ("verify all dependencies…")`,
   README.md:250 `and §2.14 for the failure modes`.
5. **Slash chains, every token independently signed** — test/release_reaper.sh:4
   `(PRD §2.18; §2.5/§2.9/§2.10/§2.14)`, :175 `(PRD §2.5/§2.18)`, :280 `(PRD §2.9/§2.10/§2.14/§2.18)`,
   README.md:250 `[PRD.md §2.12](./PRD.md) for the command list and §2.14…`.
6. **Sign + quoted-title / spaced pairs** — test/release_reaper.sh:318 `§2.5 "close != release" / §2.18`,
   :363 `§2.5 / §2.15`; install.sh:3 `(PRD §2.1, §2.17)` (comma list incl. BARE `§2.1` and `§2.4`).
7. **`+`-joined stacks** — lib/pool.sh:2021 `+ §2.10 (lazy reaper on acquire) + §2.19 (atomic lease…)`,
   lib/pool.sh:1129 `+ §2.14 (the three stale failure modes…)`.
8. **Attached-letter sub-clause `§2.16b`** — exactly ONE in the repo: lib/pool.sh:3636
   `preflight (PRD §2.16b): real agent-browser binary must exist + be executable`.
   Verified against old PRD (git ed31938:PRD.md, §2.16 Dependencies): items are "**(a)** doctor's
   `[binary]` check … **(b)** a **preflight** in the pool entry…". So BOTH pool.sh:3547 `§2.16 (a)`
   (spaced form) AND pool.sh:3636 `§2.16b` (attached form) cite OLD §2.16 → BOTH must become §2.17.
   Note: pool.sh's §2.16 baseline of 5 includes this token (plain `§2\.16` grep matches inside `§2.16b`).

Gotchas for a naive `§2\.1[2-9]` regex — verified against the real corpus:
- It MISSES **nothing** in the 2.12–2.19 space: every token carries its own sign; no ranges, no bare
  tails, no entities, no written-out forms exist.
- It WRONGLY TOUCHES nothing: bare `§2.1` (bin:4, bin:11, PRD-text) is safe because the next char is
  `,`/`;`/space, never `[2-9]`; `§2.10`/`§2.11` are excluded by `[2-9]`; research refs (`research §2`,
  `§4.4`, `§6.1`…) don't match `2.1[2-9]`.
- It would be WRONG to drop the `§` anchor (`sed 's/2\.12/…'`) — today that happens to be safe (96
  matches either way) but it would also match future bare numbers (e.g. dates, versions) and loses
  the guarantee. Keep the anchor.
- **`\b` IS A TRAP (found by dry-run):** `s/…2\.16\b/…/` does NOT match `§2.16b` (6→b is
  word-char→word-char, no boundary) and would silently leave a stale citation pointing at NEW §2.16
  (Invocation checklist) instead of §2.17 (Dependencies item b). Use `(?![0-9])` lookahead — see §5.
- **Range/pair boundary question (asked):** NO range spans 2.11–2.12 or 2.19–2.20; NO pair pairs
  2.12 with 2.11 or 2.19 with 2.20 in a way a single-token substitution could double-shift. Chains
  like `§2.9/§2.10/§2.14/§2.18` mix untouched (2.9, 2.10) and shifted tokens on one line — each
  token is independently signed and substituted exactly once (see §5 proof).

## 4. Pre-existing §2.20 and untouched values

- `§2.20` occurrences across lib/ bin/ install.sh test/ README.md docs/ .agents/: **0**. So the
  post-sweep §2.20 count (11) is purely old-§2.19 tokens — unambiguous verification.
- `§2.10` = 10 (pool 7, release_reaper 3 — note release_reaper chains put §2.10 on the SAME lines as
  shifted tokens); `§2.11` = 3 (pool.sh only). Both must be byte-identical after the sweep.

## 5. The recipe (exact, copy-pasteable, descending order)

```bash
cd /home/dustin/projects/agent-browser-pool
FILES="lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh test/concurrency.sh test/release_reaper.sh test/transparency.sh README.md"
# Pre-flight (must print 96 and the per-file numbers 56 1 2 6 4 12 10 5):
for f in $FILES; do printf '%s %s\n' "$f" "$(grep -oE '§2\.1[2-9]' "$f" | wc -l)"; done
# Sweep: descending (2.19→2.20 first … 2.12→2.13 last). Byte-escaped UTF-8 sign = locale-proof.
# (?![0-9]) NOT \b: \b misses the ONE attached-letter form §2.16b (must become §2.17b, see §3.8).
for v in 19 18 17 16 15 14 13 12; do
  perl -pi -e "s/\\xc2\\xa72\\.$v(?![0-9])/\\xc2\\xa72\\.$((v+1))/g" $FILES
done
```
- `sed` alternative (only if perl unavailable; GNU sed, both script and files are UTF-8):
  `LC_ALL=C.UTF-8 sed -i "s/§2\.19\([^0-9]\)/§2.20\1/g" $FILES` plus an end-of-line variant
  `s/§2\.19$/§2.20/` per value, descending. Strongly prefer perl: sed has no lookahead, so it needs
  the capture-group dance and would still mishandle `§2.16b` only if written with `[0-9]` classes
  incorrectly — the perl one-liner is the validated form.
- **Why descending is safe (proof on real lines):** each substitution runs exactly once, highest old
  value first. A token shifted by step k (e.g. §2.18→§2.19) can only be re-matched by the step for
  its NEW value (§2.19→§2.20), which already ran — impossible double-shift.
  - release_reaper.sh:4 `(PRD §2.18; §2.5/§2.9/§2.10/§2.14)` → 19→20: no-op; 18→19: `§2.18`→`§2.19`
    (19→20 already done, stays); 14→15: `§2.14`→`§2.15` ⇒ `(PRD §2.19; §2.5/§2.9/§2.10/§2.15)`.
    `§2.5`/`§2.9`/`§2.10` never matched by `§2\.1[2-9]`. Correct.
  - pool.sh:2021 `§2.10 … + §2.19 (atomic lease…` → `+ §2.20`; §2.10 untouched.
  - bin/agent-browser-pool:4 `(PRD §2.1, §2.4, §2.12)` → `(PRD §2.1, §2.4, §2.13)`; bare `§2.1` and
    `§2.4` untouched (pattern demands a second digit 2–9 after `§2.1`).
  - pool.sh:3636 `PRD §2.16b` → `PRD §2.17b` (lookahead lets the letter pass through; `\b` would NOT).
  - README.md:250 has two independent signed tokens on one line (`§2.12`, `§2.14`) — each shifts once.
- Do NOT add PRD.md, docs/ (empty dir), or .agents/ to the file list (see §7); PRD.md is human-owned
  (AGENTS.md §5) and is ALREADY renumbered at HEAD (see §6).

## 6. Repo state notes

- `PRD.md` at HEAD (984f340) is ALREADY in the NEW state: headings 2.12 Caller-scoped lane selection,
  2.13 CLI, 2.14 Safety, 2.15 Failure modes, 2.16 Invocation checklist, 2.17 Dependencies, 2.18
  Install, 2.19 Testing, 2.20 Implementation notes. The code citations are the stale side — that is
  exactly what R1 fixes. PRD.md must NOT be in the sweep (human-owned, already correct).
- `git status --porcelain` (pre-sweep): only `?? plan/004_de5e94ac127c/` (this work item, untracked).
  Tracked tree is clean — any diff after the sweep is attributable to the sweep alone.

## 7. Functional test assertions vs comments; docs/ and .agents/

- **Every § citation in test/*.sh is inside a comment** (line-leading `#` or trailing inline `#`).
  Zero code lines in test/ or lib/pool.sh contain `§2.x`. The only two code-adjacent § are trailing
  comments citing AGENTS.md: test/transparency.sh:248 (`AGENTS.md §3`), test/validate.sh:646 (`AGENTS.md §1`).
- **transparency.sh:** verified — it polls MESSAGE TEXT, not section numbers:
  `_transparency_assert_driving_no_pi_fails_fast` (test/transparency.sh:242) does
  `[[ "$msg" == *"pi ancestor"* ]]` in a bounded 10s poll loop; the §2.15/§2.20 citations are all
  comments. Renumbering cannot change any test outcome. Same for validate.sh, concurrency.sh,
  release_reaper.sh: comment-only citations, no string match on `§` or on section numbers anywhere.
- **docs/ (root):** the directory is EMPTY — zero citations (PRD claim "none": correct, trivially).
- **.agents/skills/agent-browser-pool/**: 3 lines contain § but NONE in the 2.12–2.19 range:
  references/configuration.md:19 and :34 (`PRD §2.7` — outside the shift range, untouched),
  SKILL.md:68 (`see §2 and §3` — skill-doc sections, not PRD). PRD's "none" claim is correct **for
  the to-be-shifted set**; technically 3 section citations exist there but §2.7/§2/§3 never match
  `§2\.1[2-9]`, so excluding .agents/ from the sweep is safe AND required (zero-change there).

## 8. Verification command set (post-sweep, all static)

```bash
cd /home/dustin/projects/agent-browser-pool
FILES="lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh test/concurrency.sh test/release_reaper.sh test/transparency.sh README.md"
# (a) per-value distribution shifted +1 (expect totals 2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11)
for v in 2.12 2.13 2.14 2.15 2.16 2.17 2.18 2.19 2.20; do
  printf '%s %s\n' "$v" "$(cat $FILES | grep -oE "§${v//./\\.}" | wc -l)"; done
# (b) per-file totals preserved (expect occ 56 1 2 6 4 12 10 5 = 96; lines 55 1 2 6 4 10 10 4 = 92)
#     NOTE: post-sweep the set is §2.13–§2.20 — §2.20 is NOT matched by [2-9]; include it explicitly.
for f in $FILES; do printf '%s occ=%s lines=%s\n' "$f" \
  "$(grep -oE '§2\.1[3-9]|§2\.20' "$f" | wc -l)" "$(grep -cE '§2\.1[3-9]|§2\.20' "$f")"; done
# (c) untouched sets byte-identical (expect 2.10=10 2.11=3; research/AGENTS § counts unchanged vs §1 above)
for f in $FILES; do printf '%s ' "$(grep -oE '§2\.1[01]' "$f" | wc -l)"; done; echo
# (d) syntax + lint on every touched file
for f in $FILES; do bash -n "$f" && echo "OK $f"; done
for f in lib/pool.sh bin/agent-browser-pool install.sh test/*.sh README.md; do shellcheck -s bash "$f" && echo "SC OK $f"; done
# (e) pure in-place edit: equal +/- per file, no added/removed lines; every changed line contains §
git diff --numstat -- $FILES            # col1 == col2 for every row
git diff --numstat -- $FILES | awk '$1!=$2{print "MISMATCH "$3}'
git diff -U0 -- $FILES | grep -E '^[+-][^+-]' | grep -vc '§'   # must print 0
git status --porcelain                  # only modified: the 8 files (+ untracked plan/004…/)
```
Notes: (d) shellcheck on README.md is meaningless (markdown) — keep it to the 7 scripts.
Verification totals 96 must NOT be compared to the PRD's 73 (see §2).

## 9. Dry-run validation of this recipe (isolated /tmp copies; repo untouched)

Executed the exact §5 recipe against copies in /tmp (then removed). Results, all matching prediction:
- Distribution: 2.12=0 2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11 (96 total).
- Per-file totals: 56 1 2 6 4 12 10 5 (occ) / 55 1 2 6 4 10 10 4 (lines) — identical to baseline.
- Untouched: §2.10+§2.11 = 13 (10+3) unchanged; `§2.16b`→`§2.17b`; no stale §2.16 refs remain.
- `bash -n` passed on all 7 scripts; `wc -l` identical (pool.sh 4695, README.md 421).
- diff vs originals: changed lines 110/2/4/12/8/20/20/8 (each = 2× its line count → equal +/-);
  zero changed lines without `§`. A first attempt using `\b` instead of `(?![0-9])` FAILED this
  validation (left §2.16b stale, distribution 2.16=26/2.17=4) — that is why §5 mandates lookahead.