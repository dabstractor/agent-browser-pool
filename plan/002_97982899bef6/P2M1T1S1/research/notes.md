# Research Notes — P2.M1.T1.S1 (Remove POOL_DISABLE from pool_config_init)

Scope: surgical removal of the `AGENT_BROWSER_POOL_DISABLE` → `POOL_DISABLE` wiring from
`pool_config_init` and its doc comment in `lib/pool.sh`. No other files touched here.

## Exact target lines in lib/pool.sh (4613 lines total)

| Line | Current content | Action |
|------|-----------------|--------|
| 109  | `#   AGENT_BROWSER_POOL_DISABLE     (unset = pooling active) ... POOL_DISABLE  bool (1=passthrough)` | DELETE entire row |
| 180  | `    # 5. Booleans — 1/true/yes/on (case-insensitive) → on, else off.` | KEEP (does not name POOL_DISABLE) |
| 181  | `    local headless disable allow_slow_copy` | EDIT → `    local headless allow_slow_copy` (drop `disable`) |
| 182  | `    headless="$(_pool_config_bool "${AGENT_CHROME_HEADLESS:-}")"` | KEEP |
| 183  | `    disable="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"` | DELETE |
| 184  | `    allow_slow_copy="$(_pool_config_bool "${AGENT_CHROME_ALLOW_SLOW_COPY:-}")"` | KEEP |
| 185  | `    POOL_HEADLESS="$headless"; declare -g POOL_HEADLESS` | KEEP |
| 186  | `    POOL_DISABLE="$disable"; declare -g POOL_DISABLE` | DELETE |
| 187  | `    POOL_ALLOW_SLOW_COPY="$allow_slow_copy"; declare -g POOL_ALLOW_SLOW_COPY` | KEEP |

## Key findings

### 1. The `local headless disable allow_slow_copy` line (181) MUST be edited too
The item contract's literal steps (a,b) only name the deletion of lines 183 and 186. But after
those two deletions, the `disable` local is dead. The implementer should also drop `disable` from
the `local` declaration on line 181. Verified reasoning via isolated /tmp shellcheck tests:

- **Without** the function's `# shellcheck disable=SC2034` directive, leaving `disable` in the
  `local` decl but unassigned fires `SC2034 (warning): disable appears unused`.
- **With** the existing directive (line 130, applies to `pool_config_init`), that warning is
  suppressed — so the shellcheck gate (step f) passes either way. BUT leaving dead code is poor
  hygiene and step (e)'s "do NOT remove headless/allow_slow_copy — those are still needed" implies
  the `disable` token should be removed (it is the boolean line that is no longer needed).

→ Recommendation: edit line 181 to `    local headless allow_slow_copy` for cleanliness. This is
not strictly required by shellcheck, but is the correct reading of the contract and matches the
gap_analysis intent.

### 2. Baseline shellcheck is CLEAN
`shellcheck -s bash lib/pool.sh` → exit 0, zero output. The PRP must require the implementer to
preserve this (exit 0 after the change).

### 3. The function-level SC2034 disable (line 130) covers pool_config_init
```
# shellcheck disable=SC2034 # POOL_* globals are the exported contract of this lib;
# downstream subtasks (M1.T1.S3, M2–M7) and tests read them after pool_config_init runs.
pool_config_init() {
```
This directive suppresses SC2034 for all assignments inside the function (POOL_* globals are read
externally by tests and sibling functions). It must NOT be removed — other POOL_* globals
(POOL_HEADLESS, POOL_ALLOW_SLOW_COPY, POOL_PORT_BASE, …) still rely on it.

### 4. `source lib/pool.sh` is SAFE (no top-level execution)
Confirmed: all 61 entries are function definitions. Every call to `pool_config_init`/
`pool_state_init` occurs inside another function (lines 2103, 3608–3609, 3909–3910, …). There is
no top-level `if [[ "${BASH_SOURCE[0]}"...` guard because there is no top-level code at all.
Therefore an isolated micro-check that sources the file and calls `pool_config_init` does NOT spawn
Chrome, daemons, or any subprocess — it only resolves paths and sets globals. Safe + fast.

### 5. Dependency boundaries — what is OUT of scope for THIS item
Other `POOL_DISABLE` / `AGENT_BROWSER_POOL_DISABLE` references that are owned by LATER subtasks and
MUST NOT be touched in S1:

| Reference | Line(s) | Owner (later subtask) |
|-----------|---------|-----------------------|
| `if [[ "${POOL_DISABLE:-0}" == "1" ]]` passthrough block + `# b. safety valve` comment | 3585, 3598, 3606, 3611–3617 | P2.M1.T1.S2 (pool_wrapper_main) |
| `printf '  AGENT_BROWSER_POOL_DISABLE ...'` in `pool_admin_help` | 4609 | P2.M1.T3.S1 (pool_admin_help) |
| `selftest_config_disable` + assertions in test harness | validate.sh:346–357 | P2.M5.T1.S1 (validate.sh) |
| install.sh DISABLE mentions | install.sh:13,31,76,215 | P2.M3.T1.S1 (install.sh rewrite) |

### 6. Transient, EXPECTED consequence of S1 (do NOT "fix" it here)
After S1, `POOL_DISABLE` is no longer initialized. The still-present pool_wrapper_main block
(line 3613) reads `${POOL_DISABLE:-0}` → "0" → the passthrough branch becomes dead/inert (never
fires). This is the intended contract (item OUTPUT step 4): the dead code is removed by S2.
Likewise, the existing `validate.sh` `selftest_config_disable` test (lines 352–357) WILL FAIL after
S1 because it asserts `POOL_DISABLE=1`. This failure is EXPECTED and is resolved by P2.M5.T1.S1.
The S1 validation gates must NOT run the full validate.sh (it would surface this known-expected
failure); instead run the targeted static + micro checks in the PRP's Validation Loop.

## PRD grounding
- §2.11 Discovery & configuration: "(removed) AGENT_BROWSER_POOL_DISABLE and the ~/scripts
  PATH-shadow are gone — there is no interception to bypass."
- §2.17 Install (no cutover danger): "Removed: the AGENT_BROWSER_POOL_DISABLE safety valve
  (nothing to bypass)..."
- §4 Decision O5 (No PATH shadowing / pivot): "Removes the cutover danger, the ~/scripts
  PATH-ordering requirement, and AGENT_BROWSER_POOL_DISABLE."
