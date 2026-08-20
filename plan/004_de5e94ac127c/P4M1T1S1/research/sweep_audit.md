# Sweep Audit — P4.M1.T1.S1 §-citation renumber (§2.12–§2.19 → §2.13–§2.20)

Executed in-place at repo HEAD. Pure static token substitution (grep/perl/git only); no
processes spawned, no test suite run, PRD.md / docs/ / .agents/ untouched.

## File list (8)

lib/pool.sh bin/agent-browser-pool install.sh test/validate.sh test/concurrency.sh
test/release_reaper.sh test/transparency.sh README.md

## Task 1 — Pre-flight gate (PASSED)

Command: `grep -oE '§2\.1[2-9]' "$f" | wc -l` per file

| file | count |
|---|---|
| lib/pool.sh | 56 |
| bin/agent-browser-pool | 1 |
| install.sh | 2 |
| test/validate.sh | 6 |
| test/concurrency.sh | 4 |
| test/release_reaper.sh | 12 |
| test/transparency.sh | 10 |
| README.md | 5 |

Total 96 occurrences — matches baseline exactly. `git status --porcelain` showed only
` M plan/004_de5e94ac127c/tasks.json` (orchestrator-owned) + the untracked work-item dir.
Pre-sweep `wc -l`: pool.sh 4695, README.md 421 (all 8013 total).

## Task 2 — Sweep command (citation_audit.md §5 verbatim)

```bash
for v in 19 18 17 16 15 14 13 12; do
  perl -pi -e "s/\\xc2\\xa72\\.$v(?![0-9])/\\xc2\\xa72\\.$((v+1))/g" $FILES
done
```

(Descending order; perl lookahead `(?![0-9])` so `§2.16b` → `§2.17b` passes through; byte-escaped
`\xc2\xa7` locale-proof § anchor.)

## Task 3 — Verification (citation_audit.md §8; ALL PASSED)

### (a) Distribution matrix — exact match

| key | §2.12 | §2.13 | §2.14 | §2.15 | §2.16 | §2.17 | §2.18 | §2.19 | §2.20 |
|---|---|---|---|---|---|---|---|---|---|
| count | 0 | 10 | 2 | 24 | 25 | 5 | 3 | 16 | 11 |

Total 96. Expected: 0/10/2/24/25/5/3/16/11 ✔

### (b) Per-file post-sweep (`§2\.1[3-9]|§2\.20`)

| file | occ | lines |
|---|---|---|
| lib/pool.sh | 56 | 55 |
| bin/agent-browser-pool | 1 | 1 |
| install.sh | 2 | 2 |
| test/validate.sh | 6 | 6 |
| test/concurrency.sh | 4 | 4 |
| test/release_reaper.sh | 12 | 10 |
| test/transparency.sh | 10 | 10 |
| README.md | 5 | 4 |

Total 96 occ / 92 lines ✔ (matches expected 55/1/2/6/4/10/10/4 lines)

### (c) Untouched values

§2.10 = 10, §2.11 = 3 (13 total) — identical to pre-sweep ✔

### (d) Syntax + lint (7 scripts; README.md excluded)

`bash -n` clean on all 7 scripts ✔
`shellcheck -s bash` clean on lib/pool.sh ("OK lib/pool.sh"); the other 6 scripts report only
**pre-existing info-level** findings (SC1091: `source` of runtime-resolved path;
SC2016: intentional single-quoted `bash -c` bodies in validate.sh) — none touch § citations;
all are comment-only changed files and the findings are on unchanged lines.

### (e) Git purity

`git diff --numstat -- $FILES`:

```
4	4	README.md
1	1	bin/agent-browser-pool
2	2	install.sh
55	55	lib/pool.sh
4	4	test/concurrency.sh
10	10	test/release_reaper.sh
10	10	test/transparency.sh
6	6	test/validate.sh
```

+/- equal per file ✔ (92+/92−). `git diff -U0 | grep -E '^[+-][^+-]' | grep -vc '§'` → **0** ✔
`grep -n '§2\.17b' lib/pool.sh` → line 3636 (was §2.16b) ✔
`wc -l` identical per file (8013 total; pool.sh 4695, README.md 421) ✔

## Conclusion

All Success Criteria met. Codebase § citations now match the renumbered PRD.md (§2.12 =
caller-scoped selection … §2.20 = impl notes).