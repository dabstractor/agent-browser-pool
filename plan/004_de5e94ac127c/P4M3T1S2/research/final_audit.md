# Final audit — P4.M3.T1.S2 (citation sweep verification, die-text mirrors, cross-doc consistency, leak check)

Mode B closing audit of the complete P4 changeset. Static, read-only (the single exception:
one minimal doc-side fix in the skill's configuration.md, recorded in Gate E below). No
production code file, PRD.md, install.sh, or test was modified by this audit.

Method per AGENTS.md §1: grep/read/git only; no browsers booted, no test suite run, no
daemon launched. All `grep -P` patterns use the UTF-8 `§` anchor and `(?!\d)` lookahead
(the `\b` trap from citation_audit §3 does not apply); `§2\.20` always grepped via the
explicit alternation `§2\.1[3-9]|§2\.20` — `[2-9]` alone misses the trailing `0`.

## Inputs

- `plan/004_de5e94ac127c/architecture/citation_audit.md` §1 (baseline), §3 (token catalog), §8 (commands)
- `plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md` (recorded R1 post-sweep state; sweep commit `5b9ee1e`)
- Per-subtask research records (P4M1T2S1/T3S1/T4S3, P4M2T1S1–T3S2, P4M3T1S1)
- `plan/004_de5e94ac127c/P4M3T1S2/research/research-notes.md` (die-text anchors, mid-changeset counts)

## Task 1 — Reconciliation table (baseline + recorded additions = measured)

Additions were attributed deterministically by diffing the per-file citation-token
multisets between the sweep commit `5b9ee1e` and HEAD (`git show 5b9ee1e:<f> | grep -oP
'§2\.\d+[a-z]?'` vs the same on the working tree), so every deviation from baseline is a
named, greppable addition — not a guess.

| file | R1 baseline (shifted set) | recorded additions since R1 | expected | measured | verdict |
|---|---|---|---|---|---|
| lib/pool.sh | 56 | +7 shifted (caller/pin code comments: +1 §2.13, +2 §2.14, +3 §2.15, +1 §2.20 — P4.M1.T2/T3/T4) + 6× §2.12 | 63 (+6 §2.12) | 63 + 6×§2.12 (occ 63 / lines 62) | PASS |
| bin/agent-browser-pool | 1 | none | 1 | 1 (1) | PASS |
| install.sh | 2 | none (PRD: unchanged) | 2 | 2 (2) | PASS |
| test/validate.sh | 6 | +3 §2.19 (P4.M2 caller-mode test blocks) + 4× §2.12 + 1 §2.8 | 9 (+4 §2.12) | 9 (9) + 4×§2.12 + 1×§2.8 | PASS |
| test/concurrency.sh | 4 | +1 §2.19 + 1 §2.10 (caller-mode E2E, single-setup runner — P4.M2) + 1× §2.12 | 5 (+1 §2.12) | 5 (5) + 1×§2.12 + 1×§2.10 | PASS |
| test/release_reaper.sh | 12 | none | 12 | 12 (10) | PASS |
| test/transparency.sh | 10 | none | 10 | 10 (10) | PASS |
| README.md | 5 | +1 §2.12 (P4.M3.T1.S1 pin-conflict block) | 5 (+1 §2.12) | 5 (4) + 1×§2.12 | PASS |

Provenance notes:
- The §2.19-heavy delta in validate/concurrency is **not** a sweep regression: pre-sweep
  (`5b9ee1e^`) validate.sh had old §2.18=2 and concurrency old §2.18=4 (old §2.18 =
  "Testing & validation"), which the sweep correctly mapped to new §2.19; the implementing
  subtasks then added further new-§2.19 (Testing) citations. Verified against
  `git show 5b9ee1e^:<file>` token multisets and PRD headings (new §2.19 = "Testing &
  validation", §2.20 = "Implementation notes").
- pool.sh's shifted additions live in the caller/pin code landed by P4.M1.T2–T4
  (pool.sh:218 §2.11/§2.12, 222 §2.20, 2248 §2.12+§2.15, 2251 §2.8, 2258/2317 §2.14,
  2274 §2.12, 2282 §2.8, 3754 §2.12/§2.13, 3757/3793 §2.15, 3791 §2.12) — exactly the
  "+7 incl. 6×§2.12 caller-mode comments" recorded in this item's research notes §2.

### Gate A — citation re-audit: PASS

Repo-wide shifted-set distribution across the 8 swept files, measured:

```
§2.13=11  §2.14=4  §2.15=27  §2.16=25  §2.17=5  §2.18=3  §2.19=16+2=… see per-file matrix
```

Per-file matrix (command: `grep -oP "§2\\.$v(?!\\d)" $f | wc -l` per value):

| file | 2.12 | 2.13 | 2.14 | 2.15 | 2.16 | 2.17 | 2.18 | 2.19 | 2.20 | shifted total (lines) |
|---|---|---|---|---|---|---|---|---|---|---|
| lib/pool.sh | 6 | 9 | 2 | 21 | 13 | 5 | 0 | 3 | 10 | 63 (62) |
| bin/agent-browser-pool | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 (1) |
| install.sh | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0 | 0 | 2 (2) |
| test/validate.sh | 4 | 0 | 2 | 0 | 1 | 0 | 1 | 5 | 0 | 9 (9) |
| test/concurrency.sh | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 5 | 0 | 5 (5) |
| test/release_reaper.sh | 0 | 0 | 0 | 4 | 1 | 0 | 0 | 6 | 1 | 12 (10) |
| test/transparency.sh | 0 | 0 | 0 | 0 | 9 | 0 | 0 | 0 | 1 | 10 (10) |
| README.md | 1 | 1 | 0 | 2 | 0 | 0 | 1 | 1 | 0 | 5 (4) |

Every cell = R1 post-sweep baseline cell + a named addition above. Baseline repo-wide
distribution (2.13=10 2.14=2 2.15=24 2.16=25 2.17=5 2.18=3 2.19=16 2.20=11) + recorded
additions = measured exactly.

### Gate B — §2.12 legitimacy (context review): PASS

All 12 `§2.12` occurrences read in context; every one cites caller-scoped lane
selection / lane pinning (PRD §2.12 "Caller-scoped lane selection", modes 1/2, O10/O11):

- lib/pool.sh:218 ("Caller-scoped owner mode + lane pin (PRD §2.11/§2.12, O10/O11)"),
  :584 (mode 1), :2248 (mode 2 pin branch), :2274 (mode 2), :3754 (PIN MODE), :3791 (pin skip find-mine)
- test/validate.sh:989, :1063, :1071, :1206 (caller-mode/pin test blocks)
- test/concurrency.sh:404 (caller-mode E2E)
- README.md:441 ("See [PRD.md §2.12](./PRD.md)" closing the pinned-conflict troubleshooting block)

Zero occurrences carry the old pre-R1 meaning (§2.12-was-command-list); the only
command-list citation left is correctly §2.13 (README:298, pool.sh:2843/2974/4018…).
`grep -rnE '§2\.1[2-9]'` across lib/ bin/ install.sh test/ README.md .agents/ reviewed —
no old-numbering survivor anywhere. §2.17b intact exactly once (lib/pool.sh:3774).

### Gate C — untouched sets: PASS (with reconciled additions)

Measured within the swept set: `§2.10`=11, `§2.11`=4, `§2.9`=10, `§2.8`=14, `§2.7`=9.
Deltas vs the citation_audit §1 untouched baseline (§2.10=10, §2.11=3) are the
token-multiset-diff-attributed deliberate additions of implementing subtasks, not sweep
leakage:

- §2.10 +1: test/concurrency.sh:408 (single-setup runner comment — "lazy reaper, §2.10",
  P4.M2's runner rework) and pool.sh unchanged (§2.10 pool count identical to R1).
- §2.11 +1: lib/pool.sh:218 — the caller-mode config-parse comment citing
  §2.11/§2.12 (Discovery & configuration), recorded intent in P4M1T2S1 notes ("new
  comments must cite NEW numbering (§2.11/§2.12/§2.20)").
- §2.8 +3: lib/pool.sh:2251, :2282 (one-lane-per-owner invariant in the caller/pin
  branches) + test/validate.sh:1206 — all cite §2.8 "≤1-lane-per-owner", semantically
  correct for the new code.

All additions read in context; none is an old-numbering token. Byte-identical
preservation holds for every baseline token (verified by multiset diff: only additions,
zero removals/renumbers outside the additions listed in the Task-1 table).

### Gate D — PRD.md never swept: PASS

`git log --oneline 095e919..HEAD -- PRD.md` → empty (last PRD.md touch is `984f340`,
pre-changeset); `git status --porcelain PRD.md` → empty.

## Task 3 — Die-text mirror check: PASS

Code side (located by content grep, line numbers current):

- lib/pool.sh:230 `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '$lane_pin'`
- lib/pool.sh:590 `agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process`
- lib/pool.sh:2294 `owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE`
- lib/pool.sh:2318 `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`
- lib/pool.sh:3797 `agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)`
- lib/pool.sh:3782 `agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy).` (+ second line re `agent-browser` direct)
- lib/pool.sh:3808 `agent-browser-pool: no lane available after ${POOL_WAIT:-600}s + force-reap`

Doc side mirrors (grep both directions):
- configuration.md:56 (live-parent die, wrapped), :89 (pin conflict, verbatim incl.
  `$POOL_LANE_PIN`/`$o_pid`/`$o_comm`), :91 (pinned lane unavailable), :95 (one-lane
  invariant, verbatim vars), :99 + :207 (positive integer), :126 (harness fail-fast),
  :206 (pin conflict row) — all match byte-for-byte modulo `$var`/ellipsis substitution.
- README.md:164 (positive integer, `'<raw value>'`), :398 (harness fail-fast + the
  "For raw browser use…" continuation, matches pool.sh:3782's full text), :427–429 (pin
  conflict + wrapper wrap, `N`/`…` for vars), :431 (one-lane invariant sibling error),
  :433 (positive integer).
- SKILL.md:162 + skill README.md:22 quote the "never a takeover" semantic phrase, not a
  die string — consistent, no stale quote.
No doc quotes a string absent from lib/pool.sh; no die text lacks its doc mirror.

## Task 4 — Cross-doc consistency: PASS (after one minimal doc fix)

Env vars and defaults identical across README.md, references/configuration.md, SKILL.md,
skill README.md and lib/pool.sh (lib/pool.sh:184–186, 212 defaults):

- `ABPOOL_OWNER` unset → harness-ancestor ownership; set (rec. `caller`) → caller mode
  keyed on the calling subprocess's **live parent**; fail-fast exemption in caller mode.
- `ABPOOL_LANE` unset → auto-assign (lowest free lane); positive-int N → pin
  (free/stale → take, stale reaped first, orphan never adopted; own live lease → reuse;
  live foreign → hard error, **never a takeover**; malformed → startup hard error).
- `AGENT_BROWSER_POOL_WAIT`=600, `AGENT_CHROME_PORT_BASE`=53420, `_RANGE`=1000,
  `AGENT_BROWSER_POOL_HARNESSES`=`pi,claude,codex,agy,antigravity` — identical in both
  config tables (README:315–322, configuration.md:23–30) and in code. The die-string
  shorthand "(pi/claude/codex/agy)" matches pool.sh:3782 verbatim in README:398 and
  configuration.md:126.
- Remaining vars (AGENT_BROWSER_REAL, AGENT_CHROME_MASTER/EPHEMERAL_ROOT/BIN/HEADLESS/
  ALLOW_SLOW_COPY, AGENT_BROWSER_POOL_STATE) present with matching defaults in the two
  configuration tables.
- Mode vocabulary ("caller mode", "orchestrator mode", "pinned lane", "never a takeover",
  "live parent", "auto-reap(ed)") consistent; no surface contradicts another.

P4.M3.T1.S1 contract verified present in README.md: env rows directly after HARNESSES
(README:320–322), `### Orchestrator mode (caller-scoped lanes)` under Usage (README:129,
with auto-reap / fail-fast exemption / default-path-unchanged + parallel-scrapers
example), lifecycle step 3 caller-mode line (README:366–369), pinned-conflict
troubleshooting block (README:425–441), orchestrator checklist line mirroring PRD §2.16's
final item (README:174). S1's "§2.16 if the new prose cites them" was conditional — the
checklist line mirrors §2.16 without citing it; citations present are exactly
§2.9/§2.12/§2.13/§2.15/§2.18/§2.19.

### Gate E — doc-side fix applied and re-audited

- FAIL (first run): references/configuration.md:29 said caller mode keys ownership on
  "the calling process itself (`$$`)" — the PRD §2.12 wording, not the implemented
  contract (live parent, per pool.sh:590 and P4M2T1S2 notes which explicitly recorded
  that `$$` is the in-process test view, live parent is binding). README and SKILL
  surfaces already said "live parent". This was a forked-wording miss, doc-only.
- FIX (minimal): configuration.md:29 changed to "key lane ownership on the calling
  subprocess (its live parent) … auto-reaped when it exits" (also syncing the
  "auto-reaped" vocabulary).
- RE-AUDIT: `grep -n '\$\$'` across all four doc surfaces → zero matches; all four
  surfaces now agree with lib/pool.sh. PASS.

## Task 5 — Static gates + install.sh invariance: PASS

- `bash -n` OK on lib/pool.sh, bin/agent-browser-pool, install.sh, test/*.sh (7/7).
- `shellcheck -s bash lib/pool.sh install.sh test/*.sh`: pool.sh and install.sh clean;
  the test scripts emit only the **pre-existing info-level** SC1091 (sourced
  runtime-resolved paths) and SC2016 (intentional single-quoted `bash -c` bodies) — the
  identical set recorded at R1 in sweep_audit Task 3(d); zero warnings, zero new findings.
- `git status --porcelain install.sh` → empty (PRD: install.sh unchanged). Confirmed
  also by the `5b9ee1e`→HEAD token diff (install.sh zero delta).

## Task 6 — Leak audit (AGENTS.md §6): PASS (one remediation)

- `pgrep -af 'chrome|abpool-|agent-browser-pool|sleep'`: the only matches are the
  **operator's** real pool Chrome lanes (ports 53420/53421,
  `~/.agent-chrome-profiles/active/{1,2}`, baseline pids 139271/211550 — same lanes
  recorded in P4M2T3S2's baseline/leak logs and attributed operator-owned there),
  operator desktop Chrome/Brave/Claude processes, and the operator's 5s polling `sleep`
  churn (new pids every 5s, also present in the pre-changeset baseline log). **Zero
  processes owned by changeset validation runs.** Not touched, per AGENTS.md.
- `ls -d /tmp/abpool-*` first run: one leftover — `/tmp/abpool-dbg-417940`, an **empty**
  directory (mtime today 19:41, owner pid gone, zero files, referenced by no changeset
  code or research note; attribution unknown). Remediated per AGENTS.md §3 with `rmdir`
  (safe: empty). Re-run: `/tmp/abpool-*` → empty. Recorded here as the remediation.
- Final state: zero changeset-owned orphan processes, zero leftover temp trees.

## Conclusion

All gates green (Gate E and the leak audit each after one recorded minimal remediation;
neither touched production code). No production file was modified by this audit — the
only writes are this report and the one-line doc fix in
`.agents/skills/agent-browser-pool/references/configuration.md`.

**The P4 changeset is documentation-complete, citation-complete, leak-free.**