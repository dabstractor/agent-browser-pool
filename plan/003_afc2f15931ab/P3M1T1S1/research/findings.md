# Research notes — P3.M1.T1.S1 (AGENT_BROWSER_POOL_HARNESSES + POOL_HARNESSES)

All findings below are from STATIC analysis only (code reads + `bash -n`/`shellcheck` on
scratch files). No browsers/daemons/test-suite were launched (AGENTS.md §1 PLANNING rules).

## 1. pool_config_init structure (lib/pool.sh:130-193) — confirmed numbered sections

| §  | Lines    | Category        | Globals set                                   |
|----|----------|-----------------|-----------------------------------------------|
| 1  | 131-136  | HOME resolve    | POOL_HOME_DIR                                 |
| 2  | 138-155  | path globals    | STATE_DIR, MASTER_DIR, EPHEMERAL_ROOT, REAL_BIN |
| 3  | 157-166  | name-or-path    | POOL_CHROME_BIN  ← STRING pattern (the one to mimic) |
| 4  | 168-176  | numerics (uint) | PORT_BASE, PORT_RANGE, WAIT                   |
| 5  | 178-183  | booleans        | HEADLESS, ALLOW_SLOW_COPY  ← ends at line 183 |
| 6  | 185-190  | derived paths   | LANES_DIR, LOCK_FILE  ← MUST stay last (finalizes paths off STATE_DIR) |

Insertion point (per contract): AFTER line 183 (`POOL_ALLOW_SLOW_COPY=…; declare -g …`)
and BEFORE line 185 (`# 6. Derived paths`). Resolution of the contract's "§7" prose slip:
**insert the new block as §6 and renumber the derived-paths block 6→7** so numbering stays
monotonic (1..7) and derived paths remain the finalization tail.

## 2. §3 CHROME_BIN pattern (lib/pool.sh:157-166) — the template to follow

```bash
    local chrome_in chrome_out                      # locals declared first
    chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"   # ${VAR:-default}
    if [[ "$chrome_in" == */* ]]; then … ; else chrome_out="$chrome_in"; fi
    POOL_CHROME_BIN="$chrome_out"; declare -g POOL_CHROME_BIN   # freeze, MUTABLE
```
- `local` declared separately from assignment (avoids SC2155 under `set -e`).
- Final freeze is `POOL_X="$val"; declare -g POOL_X` (NOT readonly → re-runnable for tests;
  contract at lib/pool.sh:124-127). New POOL_HARNESSES MUST follow this exact shape.

## 3. SC2034 gate — VERIFIED GREEN after S1 (the one real risk)

Baseline: `shellcheck -s bash lib/pool.sh` ⇒ rc=0 today. All current POOL_* globals happen
to be consumed in-file (HEADLESS@chome_launch, ALLOW_SLOW_COPY@copy_master/doctor, …), so
none are "unused". After S1, POOL_HARNESSES is assigned but NOT consumed in-file until S2
(pool_owner_resolve) lands → would normally trip SC2034.

Empirical scratch tests (isolated /tmp files):
- TEST A: `# shellcheck disable=SC2034` immediately before `foo() { … declare -g X …}` ⇒ rc=0
  (directive DOES suppress SC2034 for assignments inside the function).
- TEST B: directive inside the function, before the assignment ⇒ rc=1 (does NOT suppress).
- TEST C: directive, then a COMMENT line, then function (mirrors lib/pool.sh:128→129→130) ⇒ rc=0
  (intervening comment does NOT break scope).

lib/pool.sh:128 already has `# shellcheck disable=SC2034` immediately before the comment at
129 and the function at 130 ⇒ **POOL_HARNESSES assigned inside pool_config_init is already
covered. No new shellcheck directive is needed.** If the implementer splits the assignment
OUT of pool_config_init (not advised), they'd need a fresh directive.

## 4. Normalization pipeline (contract 3b) — exact transforms

Input default: `pi,claude,codex,agy,antigravity`.
1. lowercase      : `tr '[:upper:]' '[:lower:]'`
2. squeeze commas : `tr -s ','`           (`,pi,,claude,` → `,pi,claude,`)
3. trim ends      : `${harnesses#,}` then `${harnesses%,}`  (one each suffices post-squeeze)
4. guard empty    : if `[[ -z "$harnesses" ]]` → restore default (all-commas input ⇒ empty
                    ⇒ default; an empty set must NEVER escape — every driving cmd would then
                    fail the no-ancestor check).
Whitespace is intentionally NOT trimmed (contract lists only the 3 transforms). Documented
gotcha for users: include no spaces (matching is exact comma-wrapped tokens).

Stored form = clean comma list, e.g. `pi,claude,codex,agy,antigravity`. Downstream consumer
(S2, pool_owner_resolve) does the comma-wrap match:
`[[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]`  (double-comma-wrap ⇒ exact-token; 'pi' ≠ 'piXYZ').

## 5. Header comment table (lib/pool.sh:100-108) — add one row

Format: `#   <ENV VAR 28c>   <DEFAULT>   <GLOBAL>   <CATEGORY>`. `AGENT_BROWSER_POOL_HARNESSES`
is exactly 28 chars (same as `AGENT_CHROME_ALLOW_SLOW_COPY`) ⇒ aligns identically. New category
label: `comma-set`. Place after the ALLOW_SLOW_COPY row (line 108), before the `#` separator (109).
Do NOT add an entry to the "Errors" block (119-122) — the harness set guards-to-default, never
pool_die's. Also note line 128's disable comment already references "downstream subtasks"; it
already covers POOL_HARNESSES.

## 6. Docs — configuration.md

Line 27 = `| \`AGENT_CHROME_ALLOW_SLOW_COPY\` | … | … |` (last row of the 3-col env-var table;
table header at line 16). Insert the AGENT_BROWSER_POOL_HARNESSES row immediately AFTER line 27.
Exact cell text is dictated by the contract (Mode A, rides with the work; no separate docs subtask).

## 7. Validation gates (contract point 4) — both static, rc 0

- `bash -n lib/pool.sh`            (syntax)
- `shellcheck -s bash lib/pool.sh` (lint — stays rc 0 per §3)
Both are static (never block / never spawn — AGENTS.md-compliant during research AND impl).
A runtime micro-check (pool_config_init under a temp HOME w/ the override, assert POOL_HARNESSES)
is OPTIONAL and must be isolated + `timeout`-bounded + reaped if run. No new test is added by S1
(test coverage is P3.M2.T1, a separate subtask).

## 8. Downstream cohesion (do NOT break S2/S3)

- POOL_HARNESSES is the SOLE input to S2 (pool_owner_resolve set-membership + actual-comm record).
- S3 updates the fail-fast message to name supported harnesses (reads POOL_HARNESSES for the list).
- P3.M2.T1.S1 generalizes spawn_sim_owner to a named comm; M2.T1.S2 adds a non-pi positive+negative
  owner test. S1 must NOT change pool_owner_resolve (still hardcodes `comm == "pi"` at lib/pool.sh:521)
  — that is S2's job. S1 only provides the configured set.
