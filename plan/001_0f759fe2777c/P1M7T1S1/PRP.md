# PRP — P1.M7.T1.S1: `pool_admin_status()` — format and display the lane table

---

## Goal

**Feature Goal**: Implement **`pool_admin_status()`** — the READ-ONLY lane table
printer for the `agent-browser-pool status` admin command (PRD §2.12 / §1.5). It
takes **no input**, snapshots every lane via `pool_lanes_list`, and for each lane
reads its lease + computes a human-readable age + a STATE verdict, then prints a
fixed-width, aligned, **truncating** column table to **stdout**. When the pool is
empty it prints a single `No active lanes.` line. This is the **`status`** half of
the admin CLI's **user-facing** surface; the `reap`/`release`/`doctor` commands and
the `bin/agent-browser-pool` **dispatcher** are SEPARATE tasks (M7.T2–T5).

**Deliverable**: ONE new PUBLIC function `pool_admin_status()`, **APPENDED** to
`lib/pool.sh` at its current end-of-file (`lib/pool.sh:3541`, the closing `}` of
`pool_wrapper_main`), introduced by a NEW section banner
`# Admin CLI — status (P1.M7.T1.S1)`. **Pure addition: no edits to any existing
function, no new private helpers, no new env-vars/globals, no new files.** It
COMPOSES four LANDED, contract-documented helpers — `pool_config_init` +
`pool_state_init` (M1.T1.S2/S3, the precondition), `pool_lanes_list` (M3.T2.S1),
`pool_lease_read` (M3.T1.S2), `pool_lane_is_stale` (M3.T2.S3), `_pool_age_str`
(M1.T2.S1) — plus `printf`/`jq`/`mapfile` (all already used throughout the lib).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init`, given a pool
  with a mix of lanes — one **live** (owner `$$`+comm+starttime match, connected),
  one **stale** (dead owner pid), one **disconnected** (live owner, `connected:false`),
  one **corrupt** lease (invalid JSON), and a non-numeric stray `*.json` artifact —
  calling `pool_admin_status` returns **rc 0** and prints EXACTLY: a header line
  (`LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`) then ONE aligned
  row per VALID lane in ascending lane order (the corrupt lease shows a degraded
  row with `?` fields and state `STALE`; the stray non-numeric `*.json` is skipped
  by `pool_lanes_list` and never appears).
- Each valid lane's **STATE** is correct: `live` / `STALE` / `disconnected` per the
  precedence **STALE > disconnected > live** (see Implementation Patterns). The
  corrupt-lease row shows `STALE` (it cannot be verified alive).
- Each **AGE** column shows a human age (`Ns`/`Nm`/`Nh`/`Nd`) computed from the
  lease's `acquired_at`; a missing/non-numeric `acquired_at` shows `?`.
- **Empty pool** (`mapfile` of `pool_lanes_list` is empty): prints the single line
  `No active lanes.` and returns 0 — NO header, NO table.
- **Column alignment**: header + rows share ONE `printf` format string so columns
  line up; `OWNER_CWD` (24) and `SESSION` (16) are **truncated** (precision
  `%-N.Ns`) so a long path never shoves the next column over.
- **stdout discipline**: stdout is PURELY the table (or the empty message) — safely
  pipeable (`status | grep STALE`). The corrupt-lease WARNING goes to the log file +
  stderr via `_pool_log` (inside `pool_lease_read`), NOT stdout.
- **Non-fatal always**: `pool_admin_status` NEVER calls `pool_die` and NEVER returns
  non-zero. A corrupt lease / TOCTOU deletion degrades to a degraded row + continue.
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file,
  ZERO warnings — host-verified ShellCheck 0.11.0); all prior deliverables
  (M1–M6.T3.S2) unchanged and still callable; `lib/pool.sh`'s only diff is the
  appended banner + function.

## User Persona

**Target User**: Human admin (PRD §1.5: "Human runs `agent-browser-pool status` to
see lanes/owners/ages"). The function is called indirectly — the `bin/agent-browser-pool`
dispatcher (M7.T5.S1) wires `case "$cmd" in status) pool_admin_status ;; …`. This
task builds the LIBRARY function only; the dispatcher binary is future work.

**Use Case**: An operator suspects a leak (agents died, Chromes linger) — they run
`agent-browser-pool status` to see, at a glance: which lanes exist, who owns each
(pid + cwd), each lane's Chrome pid + age, and crucially each lane's STATE
(`STALE` = reapable leak, `disconnected` = Chrome down, `live` = healthy).

**User Journey**: `agent-browser-pool status` → reads table → spots `STALE` rows →
runs `agent-browser-pool reap` (M7.T2.S1) to clean them.

**Pain Points Addressed**: Without `status`, the admin must hand-parse `lanes/*.json`
files with `jq` to answer "what's running, who owns it, is anything stale?" —
error-prone and slow. `status` renders the full picture in one aligned table, with
the STATE column pre-computing the actionable verdict (stale vs live vs disconnected).

## Why

- **This IS PRD §2.12's `status` command** (`status # lane | port | session | owner
  pid+cwd | chrome pid | age | state`) and the operational half of §1.5's user story
  ("Human runs `agent-browser-pool status` to see lanes/owners/ages"). The PRD §3
  repository layout implies `bin/agent-browser-pool` as a first-class component;
  this function is the library logic that backs its `status` subcommand.
- **It is READ-ONLY and side-effect-free** (modulo `pool_state_init`'s idempotent
  `mkdir -p`). Safe to run any time; never kills a process, never deletes a lease.
  This is the deliberate contrast to `reap` (M5.T3.S1 / M7.T2.S1, which destroys).
- **It composes only LANDED, tested helpers** — no new system interaction, no flock,
  no Chrome. The whole feature is "iterate + read + format". Low risk; the risk
  surface is the `set -e` guard discipline around the non-zero-returning helpers
  (`pool_lease_read` rc 1, `pool_lane_is_stale` rc 0/1/2) — exactly what the
  Implementation Patterns + Validation target.
- **It must NOT duplicate or conflict with sibling tasks.** M7.T2.S1 (`reap`),
  M7.T3.S1 (`release`), M7.T4.S1 (`doctor`), M7.T5.S1 (the `bin/agent-browser-pool`
  dispatcher + `--help`) are all `Planned`/separate. This task owns ONLY
  `pool_admin_status()` in `lib/pool.sh`. Treat their (future) PRPs as siblings:
  the dispatcher will call `pool_admin_status` by name (`case status) pool_admin_status ;;`).

## What

User-visible behavior: **`agent-browser-pool status` prints an aligned lane table**
(header + one row per lane, ascending) or `No active lanes.` when empty. For this
task's verification (no Chrome, no master profile, no real `pi` ancestor needed),
the contract is exercised with **synthetic lease JSON files** dropped into a temp
`AGENT_BROWSER_POOL_STATE` dir — see Level 2.

### The contract (authoritative from item description + research)

**Output columns** (PRD §2.12, exact order): `LANE  PORT  SESSION  OWNER_PID
OWNER_CWD  CHROME_PID  AGE  STATE`.

**Logic (item contract, verbatim):**
a. Precondition: `pool_config_init` + `pool_state_init` (mirrors `pool_wrapper_main`
   step "a", `lib/pool.sh:3455-3459` — guarantees `POOL_LANES_DIR` exists).
b. Snapshot lanes: `mapfile -t lanes < <(pool_lanes_list)`.
c. If empty → `printf 'No active lanes.\n'; return 0`.
d. Print the header row (shared `printf` format string).
e. For each lane: `pool_lease_read` → extract fields (one `jq` fork via `mapfile`) →
   `age=_pool_age_str(acquired_at)` → `state` via `pool_lane_is_stale` + `connected`
   → print one row (shared format string).
f. A lane whose lease is missing/corrupt (TOCTOU) → degraded row (`?` fields, state
   `STALE`), then continue.

### Success Criteria

- [ ] `pool_admin_status()` appended to `lib/pool.sh` under banner
      `# Admin CLI — status (P1.M7.T1.S1)`; no other function touched.
- [ ] `bash -n lib/pool.sh` → exit 0; `shellcheck -s bash lib/pool.sh` → ZERO warnings.
- [ ] Empty pool → prints exactly `No active lanes.\n`, rc 0, NO header.
- [ ] Non-empty pool → prints header (8 column labels) + one row per valid lane,
      ascending lane order, columns aligned (shared format string).
- [ ] STATE precedence correct: `STALE` (rc 0) > `disconnected` (rc≠0 + `connected:false`)
      > `live` (rc≠0 + `connected:true`).
- [ ] AGE shows `Ns/Nm/Nh/Nd`; non-numeric/missing `acquired_at` → `?`.
- [ ] Corrupt lease (invalid JSON) → degraded row (`?`/`STALE`), row printed, loop
      continues; `_pool_log` warning goes to file+stderr (NOT stdout).
- [ ] stdout is PURELY the table/empty-message (pipeable — `status | grep STALE` works).
- [ ] `lib/pool.sh` diff is append-only (banner + function); `bin/`, `.gitignore`,
      `PRD.md`, `tasks.json` untouched.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **verbatim function
contract** (item description + research, re-stated in Implementation Blueprint with
copy-pasteable code); the **exact `printf` format string** with column widths
chosen to fit both header labels AND data (research §6 + design-decisions D4); the
**STATE precedence** pinned (STALE > disconnected > live; design-decisions D5); the
**tri-state `pool_lane_is_stale` rc semantics** (0=stale/1=live/2=no-lease) and the
**mandatory `set -e` guards** (`if …; then`, never a bare capture); the
**append-under-banner convention**; host-verified tooling (bash 5.3, ShellCheck 0.11,
jq, GNU coreutils); and a copy-pasteable, **no-Chrome** validation script (Level 2)
that synthesizes leases and asserts output.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.12 (status output format: "lane | port | session | owner pid+cwd | chrome
        pid | age | state"). §1.5 (user story: "Human runs agent-browser-pool status
        to see lanes/owners/ages"). §2.8 (lease data model — confirms connected is a
        JSON boolean, owner is a nested object).
  pattern: the 8 columns + their meaning come straight from §2.12.
  gotcha: §2.8 — `connected` is a JSON boolean; reading it must NOT use `jq -e` (exits
        1 on `false`). Compare the STRING "false".

# This task's own research (the factual + design backbone — read in full)
- file: plan/001_0f759fe2777c/P1M7T1S1/research/codebase-status-facts.md
  why: §1 the exact lease schema (12 fields, owner nested, connected boolean).
        §2 the contracts of pool_lanes_list (rc 0 always, skips non-numeric),
        pool_lane_is_stale (TRI-STATE 0=stale/1=live/2=no-lease), pool_lease_read
        (rc 0/1, logs on corrupt, CALLERS-MUST-GUARD), _pool_age_str (rc 0 always).
        §3 the pool_config_init+pool_state_init precondition. §4 the banner convention.
        §5 the set -e / SC2155 / capture-guard gotchas. §6 stdout discipline. §7 the
        M7.T5.S1 boundary (do NOT build the dispatcher).
  pattern: §2's contracts ARE the calls this function makes; §5's guards ARE the
        safety net.
  gotcha: §2 — pool_lane_is_stale rc is INVERTED vs pool_owner_alive (rc 0 == stale).

- file: plan/001_0f759fe2777c/P1M7T1S1/research/design-decisions.md
  why: D1 (lib-only, append under banner). D3 (one pool_lease_read + one jq fork via
        mapfile per lane). D4 (the PINNED printf format string + column widths).
        D5 (the PINNED STATE precedence: STALE > disconnected > live). D6 (numeric
        guard on acquired_at before _pool_age_str). D7 (empty-pool mapfile check).
        D8 (stdout discipline). D9 (column docs live in THIS function's header).
  pattern: D4's format string + D5's if/elif/fi ARE the implementation.
  gotcha: D6 — acquired_at="null" (missing field) → `$(( now - null ))` arithmetic
        error under set -e; guard with `[[ =~ ^[0-9]+$ ]]` first.

- file: plan/001_0f759fe2777c/P1M7T1S1/research/external-bash-table-formatting.md
  why: §1/§2 printf `%Ns`/`%-Ns` (min-width, NO auto-truncate) + precision `%-N.Ns`
        (truncate to exactly N cols). §3 column -t NOT needed. §4 spaces not tabs.
        §5 empty-field printf is safe. §6 the recommended layout (widths ≥ label+data).
  pattern: §6's format string is the one to use (refined in design-decisions D4).
  gotcha: §2 — bare `%-24s` does NOT truncate a long cwd; MUST use `%-24.24s`.

# Sibling PRP (the CONTRACT model — same lib-only, append-under-banner shape)
- file: plan/001_0f759fe2777c/P1M5T3S1/PRP.md
  why: pool_reap_stale() is the closest analog — also iterates pool_lanes_list, calls
        pool_lane_is_stale (tri-state), guards under set -e, appended under a banner.
        Its "Deliverable" + "Success Definition" structure is the house style to match.
  pattern: "append to lib/pool.sh under banner X; compose landed helpers; never die;
        return 0" is the exact shape of THIS task.
  gotcha: reap MODIFIES (releases lanes); status is READ-ONLY — simpler, no teardown.

# The library this function is appended to (read header + EOF to confirm append site)
- file: lib/pool.sh
  why: line 23 (set -euo pipefail — every gotcha is live). pool_lanes_list @967,
        pool_lease_read @823 (CALLERS-MUST-GUARD @817-820), pool_lane_is_stale @1164
        (tri-state doc @1118-1126; the `if ! json="$(pool_lease_read …)"` guard pattern
        @1170), _pool_age_str @369 (numeric-guard need). pool_wrapper_main @3451 (the
        precondition pattern @3455-3459). EOF @3541 (closing } of pool_wrapper_main) —
        the append site.
  pattern: pool_lane_is_stale's body (@1164-1191) is the EXACT mapfile+jq+guard pattern
        to reuse for field extraction.
  gotcha: every non-zero-returning helper (pool_lease_read, pool_lane_is_stale) MUST be
        called inside an `if` or `&& rc=0 || rc=$?` — a bare capture ABORTS under set -e.

# Architecture
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 3 (PRD §2.2 — no bare ~; all paths absolute). Confirms the admin CLI
        inherits the same path-resolution discipline (pool_config_init canonicalizes
        POOL_LANES_DIR, so status never touches ~ directly).
  pattern: the precondition (config_init) already enforces this.
  gotcha: status itself introduces NO new path handling — it reads POOL_LANES_DIR.
```

### Current Codebase tree

After **M1–M6.T3.S2** landed, `lib/pool.sh` (3541 lines) ends at `pool_wrapper_main`
(closing `}` @3541). `bin/agent-browser` exists (M6.T3.S2). The admin CLI binary does
NOT exist yet (M7.T5.S1). **THIS task appends `pool_admin_status()` to `lib/pool.sh`:**

```bash
agent-browser-pool/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/
│   ├── .gitkeep                          # retained (admin CLI bin/agent-browser-pool is M7.T5.S1)
│   └── agent-browser                     # M6.T3.S2 (the wrapper shim) — UNCHANGED
├── lib/
│   └── pool.sh                           # EOF @3541 (pool_wrapper_main). THIS task APPENDS
│                                         #   the banner "# Admin CLI — status (P1.M7.T1.S1)"
│                                         #   + pool_admin_status() after line 3541.
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    └── P1M7T1S1/
        ├── PRP.md                         # THIS FILE
        └── research/{codebase-status-facts,design-decisions,external-bash-table-formatting}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                           # MODIFIED (append-only): +banner +pool_admin_status() at EOF
└── (no other files change)
```

**File responsibility**: `pool_admin_status()` is the **read-only lane table renderer**
backing `agent-browser-pool status`. It owns NO lifecycle logic — it iterates, reads,
formats, prints. It is consumed by the future dispatcher (M7.T5.S1:
`case status) pool_admin_status ;;`).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (pool_lane_is_stale is TRI-STATE, rc INVERTED vs pool_owner_alive — facts §2):
#   rc 0 = STALE (owner dead/recycled)   ← `if pool_lane_is_stale "$n"; then` is TRUE here
#   rc 1 = LIVE  (alive+identity match)  ← falls through the if
#   rc 2 = NO-LEASE (missing/corrupt)    ← falls through the if
#   A bare `pool_lane_is_stale "$n"` whose rc is 1 or 2 ABORTS under set -e (lib/pool.sh:1144-1148).
#   ALWAYS call it inside `if …; then … else … fi`.

# CRITICAL (pool_lease_read returns rc 1 on missing/corrupt — facts §2): a bare
#   `json="$(pool_lease_read "$lane")"` ABORTS when the lease is missing/corrupt
#   (lib/pool.sh:817-820). Use `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …`.
#   The 2>/dev/null mirrors pool_lane_is_stale's own capture (lib/pool.sh:1170); the corrupt
#   WARNING is still logged to file+stderr by pool_lease_read (NOT stdout).

# CRITICAL (SC2155 — never `local x="$(…)"`): declare ALL locals up front, then assign. The
#   lib's house rule (pool_wrapper_main @3452). Applies to json, fields, age, state, etc.

# CRITICAL (`(( ))` as a STATEMENT returns 1 when result is 0 — _pool_age_str doc @358-362):
#   FATAL under set -e. Keep arithmetic inside `if`/`elif`/`for`. The `$(( ))` EXPANSION form
#   is always safe. So: `if (( ${#lanes[@]} == 0 )); then …` (inside if — safe); but a bare
#   `(( count++ ))` when count wraps to 0 would abort — use `count=$(( count + 1 ))`.

# GOTCHA (acquired_at="null" → arithmetic error — design-decisions D6): a missing
#   .acquired_at makes jq echo the literal string "null"; `$(( now - null ))` is a bash
#   arithmetic error under set -e. Guard: `[[ "$acquired_at" =~ ^[0-9]+$ ]]` BEFORE
#   _pool_age_str. (The schema guarantees numeric, but defend anyway.)

# GOTCHA (connected is a JSON BOOLEAN — pool_lease_write @701-702; facts §1): read it as a
#   STRING ("true"/"false") and compare against "false". Do NOT use `jq -e` (exits 1 on
#   false) and do NOT numeric-test it. `[[ "$connected" == "false" ]]`.

# GOTCHA (printf %-Ns does NOT truncate — external-formatting §2): a long OWNER_CWD would
#   shove CHROME_PID out of alignment. Use precision `%-24.24s` (exactly 24 cols) for
#   OWNER_CWD and `%-16.16s` for SESSION. Header + rows share ONE format string.

# GOTCHA (stdout discipline): status's stdout is PURELY the table. _pool_log writes to
#   file+stderr; pool_die to stderr. Do NOT add stray echo/printf to stdout. This makes
#   `status | grep STALE` work.

# GOTCHA (mapfile + set -e): `mapfile -t lanes < <(pool_lanes_list)` — process substitution
#   exit status is NOT propagated, so set -e does not abort even if pool_lanes_list failed
#   (it returns 0 always anyway). Safe pattern; reused from pool_lane_is_stale (@1175-1178).

# GOTCHA (corrupt lease in the loop): pool_lanes_list lists *.json by NAME (does NOT validate
#   JSON — facts §2). So a corrupt lease CAN appear in the iteration. Handle it: the
#   pool_lease_read rc-1 branch prints a degraded row and `continue`s. NEVER let one bad
#   lane abort the whole table.

# GOTCHA (TOCTOU): a lane file may be deleted (by a concurrent reap/acquire) between
#   pool_lanes_list and pool_lease_read. The `if ! json="$(…)"` guard turns this into a
#   degraded row + continue (or just continue). status is read-only and concurrent-safe.
```

## Implementation Blueprint

### Data models and structure

**None.** This task introduces NO data model, NO on-disk change, NO new env-vars/globals.
It reads existing lease JSON (schema fixed by PRD §2.8 / `pool_lease_write`) and prints
formatted text. All locals are function-scoped bash variables (`lanes`, `json`, `fields`,
`port`, `session`, `owner_pid`, `owner_cwd`, `chrome_pid`, `acquired_at`, `connected`,
`age`, `state`, `lane`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY greenfield + host tooling + the compose targets exist
  - RUN: test -f lib/pool.sh && echo "OK lib present"
  - EXPECT: present.
  - RUN (confirm this task is greenfield — NO existing pool_admin_status):
        grep -n 'pool_admin_status' lib/pool.sh && echo "STOP: already exists" || echo "OK: greenfield"
  - EXPECT: OK: greenfield (no matches).
  - RUN (confirm the compose targets are defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
          for f in pool_lanes_list pool_lease_read pool_lane_is_stale _pool_age_str \
                   pool_config_init pool_state_init; do \
            type "$f" >/dev/null || { echo "MISSING: $f"; exit 1; }; \
          done; echo "OK all compose targets defined"'
  - EXPECT: OK all compose targets defined.
  - RUN (confirm the tri-state contract of pool_lane_is_stale — read its doc):
        sed -n '1118,1135p' lib/pool.sh
  - EXPECT: doc stating "0 = STALE", "1 = LIVE", "2 = NO LEASE".
  - RUN (host tooling):
        bash --version | head -1
        command -v shellcheck >/dev/null && shellcheck --version | grep -E '^version:'
        command -v jq >/dev/null && jq --version
  - EXPECT: bash 5.3.x, ShellCheck 0.11.0, jq present.
  - RUN (confirm current EOF = append site):
        tail -3 lib/pool.sh
  - EXPECT: the closing `}` of pool_wrapper_main (the last line). Append AFTER it.
  - RUN: bash -n lib/pool.sh && echo "OK lib syntax (baseline preserved)"
  - EXPECT: OK (this task must not break existing syntax).

Task 1: APPEND pool_admin_status() to lib/pool.sh (the verbatim contract)
  - PLACEMENT: APPEND at end of lib/pool.sh (after the closing `}` of pool_wrapper_main),
        preceded by the new banner. NO edits to any existing line.
  - IMPLEMENT (verbatim — paste exactly; the header doc-comment satisfies the item's
        DOCS step by documenting every output column + STATE values):

# =============================================================================
# Admin CLI — status (P1.M7.T1.S1)
# =============================================================================
# pool_admin_status
#
# Print a READ-ONLY lane table to stdout for `agent-browser-pool status`
# (PRD §1.5 / §2.12). No input. Iterates EVERY lane (pool_lanes_list), reads each
# lease (pool_lease_read), computes a human age from acquired_at (_pool_age_str),
# and derives a STATE verdict (pool_lane_is_stale + the `connected` field).
#
# OUTPUT COLUMNS (PRD §2.12 order), one space-separated aligned row per lane:
#   LANE       lane number (int)                 — from pool_lanes_list
#   PORT       Chrome DevTools port (int)        — .port
#   SESSION    AGENT_BROWSER_SESSION string      — .session   (truncated 16)
#   OWNER_PID  owning pi process pid (int)       — .owner.pid
#   OWNER_CWD  owner's working dir (path)        — .owner.cwd (truncated 24)
#   CHROME_PID Chrome process pid (int)          — .chrome_pid
#   AGE        time since acquired_at            — _pool_age_str (Ns/Nm/Nh/Nd)
#   STATE      verdict (see below)               — live | STALE | disconnected
#
# STATE precedence (STALE > disconnected > live), from the tri-state
# pool_lane_is_stale (rc 0=STALE / 1=LIVE / 2=NO-LEASE) + the JSON boolean
# `connected` (compare the STRING "false" — never `jq -e`):
#   pool_lane_is_stale rc 0                         → STALE
#   rc 1 (live) or rc 2 (no-lease/TOCTOU):
#       connected == "false"                        → disconnected
#       else                                        → live
# A STALE owner wins regardless of connectivity (the lane is a reapable leak).
#
# EMPTY POOL → prints the single line "No active lanes." and returns 0 (no header).
#
# CONTRACT:
#   - READ-ONLY: kills nothing, deletes nothing. The only side effect is
#     pool_state_init's idempotent mkdir -p of POOL_LANES_DIR.
#   - NEVER calls pool_die; NEVER returns non-zero. A corrupt lease (invalid JSON)
#     or a TOCTOU deletion degrades to a row of "?" fields with state STALE, then
#     continues. The corrupt-lease warning is logged by pool_lease_read to the log
#     FILE + stderr (NOT stdout) → stdout stays a clean, pipeable table.
#   - A stray non-numeric *.json is skipped by pool_lanes_list (never iterated).
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_lease_read returns rc 1 on missing/corrupt → MUST guard:
#     `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …`.
#   - pool_lane_is_stale is tri-state (rc 0/1/2) → MUST call inside `if …; then …`.
#   - never `local x="$(…)"` (SC2155); declare then assign.
#   - `(( ))` only inside if/elif; `$(( ))` expansion is always safe.
#   - acquired_at from a missing field is the STRING "null" → `$(( now - null ))`
#     is an arithmetic error; guard `[[ "$acquired_at" =~ ^[0-9]+$ ]]` first.
#
# PRECONDITION: pool_config_init (for POOL_LANES_DIR) + pool_state_init (mkdir it).
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case status) pool_admin_status ;;`.
pool_admin_status() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`).
    local -a lanes fields
    local fmt json lane
    local port session owner_pid owner_cwd chrome_pid acquired_at connected
    local age state

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_wrapper_main step "a" (lib/pool.sh:3455-3459). pool_state_init's
    # idempotent mkdir -p guarantees POOL_LANES_DIR exists for the pool_lanes_list glob.
    pool_config_init
    pool_state_init

    # Shared fixed-width format string (header + every row). %-N.Ns = truncate to
    # exactly N cols (bare %-Ns does NOT truncate → long cwd/session would misalign).
    # Widths ≥ both the header label and typical data (research §6 / design-decisions D4).
    fmt='%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n'

    # --- b. snapshot lanes into an array (also a clean empty-pool check) ---------
    # Process substitution exit status is NOT propagated → set -e safe (pool_lanes_list
    # returns 0 always anyway). mapfile of empty output → empty array.
    mapfile -t lanes < <(pool_lanes_list)

    # --- c. empty pool → single message, rc 0, NO header ------------------------
    # `(( ))` inside `if` is errexit-exempt (the returns-1-on-zero gotcha does not apply).
    if (( ${#lanes[@]} == 0 )); then
        printf 'No active lanes.\n'
        return 0
    fi

    # --- d. header row ----------------------------------------------------------
    printf -- "$fmt" \
        "LANE" "PORT" "SESSION" "OWNER_PID" "OWNER_CWD" "CHROME_PID" "AGE" "STATE"

    # --- e. one row per lane ----------------------------------------------------
    for lane in "${lanes[@]}"; do
        # Read the lease. A bare capture ABORTS under set -e on rc 1 (missing/corrupt) →
        # guard with `if !`. 2>/dev/null suppresses jq's corrupt-parse stderr (the
        # WARNING is logged to file+stderr by pool_lease_read, NOT printed to stdout).
        if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
            # Missing (TOCTOU) OR corrupt: degraded row, keep the table intact.
            # pool_lanes_list already validated lane is numeric, so it is a real lane id.
            printf -- "$fmt" "$lane" "?" "?" "?" "?" "?" "?" "STALE"
            continue
        fi

        # Extract all row fields in ONE jq fork (mirrors pool_lane_is_stale @1175-1178:
        # mapfile -t < <(jq -r '.a, .b, .c' <<<"$json")). `:-` defends a short read.
        mapfile -t fields < <(jq -r \
            '.port, .session, .owner.pid, .owner.cwd, .chrome_pid, .acquired_at, .connected' \
            <<<"$json")
        port="${fields[0]:-}"
        session="${fields[1]:-}"
        owner_pid="${fields[2]:-}"
        owner_cwd="${fields[3]:-}"
        chrome_pid="${fields[4]:-}"
        acquired_at="${fields[5]:-}"
        connected="${fields[6]:-}"

        # AGE from acquired_at. _pool_age_str is rc 0 always, but acquired_at MUST be
        # numeric first: a missing field → "null" → `$(( now - null ))` arithmetic
        # error under set -e. Guard, then call (rc 0 — no further guard needed).
        if [[ "$acquired_at" =~ ^[0-9]+$ ]]; then
            age="$(_pool_age_str "$acquired_at")"
        else
            age="?"
        fi

        # STATE verdict (precedence STALE > disconnected > live).
        # pool_lane_is_stale is TRI-STATE → MUST call inside `if` (a bare rc-1/2 call
        # ABORTS). rc 0 → STALE; rc 1 (live) OR rc 2 (no-lease/TOCTOU) → decide by
        # connectivity (connected is a JSON boolean; compare the STRING "false").
        if pool_lane_is_stale "$lane"; then
            state="STALE"
        else
            if [[ "$connected" == "false" ]]; then
                state="disconnected"
            else
                state="live"
            fi
        fi

        printf -- "$fmt" \
            "$lane" "$port" "$session" "$owner_pid" "$owner_cwd" "$chrome_pid" "$age" "$state"
    done

    return 0
}

  - VERIFY (immediately after):
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (whole file)
        grep -n 'pool_admin_status' lib/pool.sh | head -1        # the definition line
        git diff --stat lib/pool.sh                              # append-only diff
  - EXPECT: all OK; the only change to lib/pool.sh is the appended banner + function.

Task 2: (NO COLLATERAL EDITS) confirm scope
  - RUN: git status --short
  - EXPECT: ONLY lib/pool.sh modified (append-only). bin/, .gitignore, PRD.md,
        tasks.json, prd_snapshot.md UNCHANGED. NO new files outside plan/.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — guard a non-zero-returning helper under set -e (the dominant safety pattern):
#   pool_lease_read returns rc 1 on missing/corrupt → bare capture ABORTS.
if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
    printf -- "$fmt" "$lane" "?" "?" "?" "?" "?" "?" "STALE"   # degraded row
    continue
fi
#   (Mirrors pool_lane_is_stale's own capture at lib/pool.sh:1170.)

# PATTERN — one jq fork for all fields (mapfile, like pool_lane_is_stale @1175-1178):
mapfile -t fields < <(jq -r '.port, .session, .owner.pid, .owner.cwd, .chrome_pid, .acquired_at, .connected' <<<"$json")
port="${fields[0]:-}"; session="${fields[1]:-}"; owner_pid="${fields[2]:-}"; ...
#   Cheaper than 7× pool_lease_field (7 jq forks/lane). Dotted paths work (getpath).

# PATTERN — tri-state predicate guard (pool_lane_is_stale rc 0/1/2):
if pool_lane_is_stale "$lane"; then
    state="STALE"          # rc 0 — owner dead/recycled
else
    # rc 1 (live) OR rc 2 (no-lease/TOCTOU): not stale → decide by connectivity.
    if [[ "$connected" == "false" ]]; then state="disconnected"; else state="live"; fi
fi
#   The if/else collapses rc-1 and rc-2 into the connected-based branch (robust to TOCTOU).

# PATTERN — truncating fixed-width column (header + rows share ONE fmt):
fmt='%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n'
printf -- "$fmt" "LANE" "PORT" "SESSION" "OWNER_PID" "OWNER_CWD" "CHROME_PID" "AGE" "STATE"
printf -- "$fmt" "$lane" "$port" "$session" "$owner_pid" "$owner_cwd" "$chrome_pid" "$age" "$state"
#   %-16.16s = left-justify, min-width 16, PRECISION 16 (truncate to exactly 16 cols).
#   Spaces (not tabs) → alignment independent of terminal tab-stop width.

# PATTERN — numeric-guard before arithmetic (acquired_at may be "null"):
if [[ "$acquired_at" =~ ^[0-9]+$ ]]; then age="$(_pool_age_str "$acquired_at")"; else age="?"; fi

# GOTCHA — WHY `if (( ${#lanes[@]} == 0 ))` and not bare `(( ${#lanes[@]} == 0 ))`:
#   a bare `(( ))` statement returns 1 when the expression is 0 → FATAL under set -e.
#   Inside `if` it is exempt. The `$(( ))` EXPANSION form is always safe. (lib/pool.sh:358-362.)
# GOTCHA — WHY `mapfile … < <(pool_lanes_list)` not `lanes="$(pool_lanes_list)"`:
#   an array capture via mapfile preserves one-element-per-line and gives ${#lanes[@]}
#   for the empty check; a scalar capture would need word-splitting in the `for`.
# GOTCHA — WHY compare `[[ "$connected" == "false" ]]` not a boolean test:
#   connected is a JSON boolean; jq -r echoes the literal "true"/"false". `jq -e` would
#   exit 1 on `false`. (pool_lease_write @701-702; pool_lease_field doc @867-869.)
```

### Integration Points

```yaml
FILESYSTEM:
  - modify: "lib/pool.sh (APPEND-ONLY: banner + pool_admin_status() after line 3541)"

LIBRARY (lib/pool.sh):
  - composes: "pool_config_init + pool_state_init (precondition); pool_lanes_list
              (iterate); pool_lease_read (lease bytes); pool_lane_is_stale (state);
              _pool_age_str (age). All LANDED + contract-documented — read their docs
              before calling."

GITIGNORE:
  - no change: ".gitignore is orchestrator-owned (M10.T1.S2); no rule matches the diff."

CONSUMERS (the dispatcher, FUTURE — NOT this task):
  - M7.T5.S1 bin/agent-browser-pool: "case \"\$cmd\" in status) pool_admin_status ;; …".
            This task does NOT create the binary. It only provides the function the
            binary will call by name."

NO CHANGES TO:
  - any existing lib/pool.sh function (append-only), bin/ (M6.T3.S2 owns agent-browser;
    M7.T5.S1 owns agent-browser-pool), .gitignore, PRD.md / tasks.json / prd_snapshot.md
    (read-only), test/ (M9.T1.S1 owns the harness).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the function — fix before proceeding.
bash -n lib/pool.sh && echo "OK bash -n"
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # ZERO warnings (WHOLE file)
grep -n 'pool_admin_status' lib/pool.sh | head -1        # the definition exists
git diff --stat lib/pool.sh                              # append-only (no -/= churn in middle)
# Expected: all OK. The diff should be purely additive (a few hundred + lines, 0 deletions).
#   shellcheck zero warnings: watch SC2155 (declare-then-assign), SC2086 (quote "$lane"/"$json"),
#   SC2034 (all locals ARE used). The format string with %-N.Ns precision is shellcheck-clean.
```

### Level 2: Unit Tests (Component Validation — NO Chrome needed)

`pool_admin_status` is purely read-format-print. It is fully verifiable WITHOUT Chrome /
a master profile / a real `pi` ancestor by writing **synthetic lease JSON** into a temp
`AGENT_BROWSER_POOL_STATE` dir, then sourcing the lib and calling the function. This
mirrors how the M9 harness (P1.M9.T1.S1) will drive it.

```bash
# Save as /tmp/test_status.sh and run: bash /tmp/test_status.sh
# Run from the REPO ROOT.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; [[ -f "$REPO/lib/pool.sh" ]] || REPO="$(pwd)"
cd "$REPO"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1" >&2; }

# --- fresh isolated state dir per scenario ---
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"
LANES="$STATE/lanes"; mkdir -p "$LANES"
export AGENT_CHROME_MASTER="$STATE/master" AGENT_CHROME_EPHEMERAL_ROOT="$STATE/active"
export POOL_LOG_PATH=/dev/null  # keep stdout clean (suppress _pool_log stderr too)

# helper: write a lease JSON exactly as pool_lease_write would (types preserved)
write_lease() { # lane port session opid ocwd cpid acquired connected
    local lane="$1" port="$2" sess="$3" opid="$4" ocwd="$5" cpid="$6" acq="$7" conn="$8"
    jq -n --argjson lane "$lane" --argjson port "$port" --arg session "$sess" \
          --argjson owner_pid "$opid" --arg owner_cwd "$ocwd" --argjson chrome_pid "$cpid" \
          --argjson acquired_at "$acq" --argjson connected "$conn" \
          '{version:1, lane:$lane, ephemeral_dir:"", port:$port, session:$session,
            owner:{pid:$owner_pid, comm:"pi", starttime:0, cwd:$owner_cwd},
            chrome_pid:$chrome_pid, chrome_pgid:$chrome_pid,
            acquired_at:$acquired_at, last_seen_at:$acquired_at, connected:$connected}' \
          > "$LANES/$lane.json"
}

source ./lib/pool.sh
pool_config_init   # freezes POOL_LANES_DIR etc.
NOW="$(date +%s)"

# ---- Case 1: EMPTY pool → "No active lanes." + rc 0 + NO header ----------------
out="$(pool_admin_status)"; rc=$?
[[ "$rc" -eq 0 ]] && [[ "$out" == "No active lanes." ]] \
    && ok "empty: single message + rc 0" || bad "empty: got rc=$rc out=[$out]"
! grep -q 'LANE' <<<"$out" && ok "empty: no header printed" || bad "empty: header leaked"

# ---- Case 2: live lane (owner=$$, connected) → state "live" -------------------
# pool_owner_alive($$, starttime, comm) needs a real starttime; use the test-hook:
# AGENT_BROWSER_POOL_OWNER_PID/$OWNER_STARTTIME simulate a live owner. Simplest: make
# the lane's owner.pid == the CURRENT shell's pid with a plausible starttime, and set
# POOL_OWNER_* so pool_owner_alive agrees. If that's fiddly, assert the FORMAT instead
# of the exact 'live' verdict (see Case 5 for the stale verdict, which is deterministic).
write_lease 3 53423 "abpool-3" "$$" "$REPO" 104816 "$((NOW-7200))" "true"
out="$(pool_admin_status)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "live: rc 0" || bad "live: rc=$rc"
grep -q '^LANE ' <<<"$out" && ok "live: header present" || bad "live: no header"
# exactly one data row (header + 1 line):
[[ "$(grep -c . <<<"$out")" -eq 2 ]] && ok "live: header + 1 row" || bad "live: row count"
# row 3 has lane=3 and a numeric port:
grep -qE '^[[:space:]]*3[[:space:]]+53423' <<<"$out" && ok "live: lane 3 + port aligned" \
    || bad "live: lane/port not found"

# ---- Case 3: disconnected lane (connected:false) → row has "disconnected" -----
# (owner liveness may vary; assert the disconnected token appears when not stale)
write_lease 1 53421 "abpool-1" 999999 "$REPO" 104811 "$((NOW-60))" "false"
out="$(pool_admin_status)"
# lane 1's owner 999999 is almost certainly dead → STALE (precedes disconnected).
# So assert EITHER STALE or disconnected appears for lane 1 (precedence-robust):
grep -qE '^[[:space:]]*1[[:space:]].*(STALE|disconnected)' <<<"$out" \
    && ok "disconnected-or-stale: lane 1 verdict present" || bad "disconnected: verdict missing"

# ---- Case 4: corrupt lease (invalid JSON) → degraded row, loop continues -------
write_lease 2 53422 "abpool-2" "$$" "$REPO" 104812 "$((NOW-3600))" "true"
printf '{ not valid json' > "$LANES/2.json"   # corrupt it
out="$(pool_admin_status)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "corrupt: rc 0 (non-fatal)" || bad "corrupt: rc=$rc"
# lane 2 still appears (degraded row), AND the good lanes still appear (loop continued):
grep -qE '^[[:space:]]*2[[:space:]]' <<<"$out" && ok "corrupt: lane 2 row present (degraded)" \
    || bad "corrupt: lane 2 missing"
[[ "$(grep -cE '^[[:space:]]*[0-9]' <<<"$out")" -ge 2 ]] && ok "corrupt: other rows survived" \
    || bad "corrupt: loop aborted early"

# ---- Case 5: DETERMINISTIC STALE verdict — dead owner pid (no pi named 1) -----
# owner.pid=1 with starttime=0 + comm=pi: pool_owner_alive returns 1 (pid 1 is not 'pi'
# OR starttime mismatch) → pool_lane_is_stale rc 0 → STALE. Deterministic across hosts.
write_lease 5 53425 "abpool-5" 1 "$REPO" 104815 "$((NOW-1800))" "true"
out="$(pool_admin_status)"
grep -qE '^[[:space:]]*5[[:space:]].*STALE' <<<"$out" \
    && ok "stale: lane 5 → STALE (dead owner)" || bad "stale: lane 5 not STALE"

# ---- Case 6: non-numeric stray *.json is SKIPPED by pool_lanes_list -----------
printf 'garbage' > "$LANES/notanumber.json"
out="$(pool_admin_status)"
! grep -q 'notanumber' <<<"$out" && ok "stray: non-numeric *.json skipped" \
    || bad "stray: non-numeric artifact appeared"

# ---- Case 7: AGE format (Ns/Nm/Nh/Nd) on a known-acquired lane ----------------
write_lease 7 53427 "abpool-7" 1 "$REPO" 104817 "$((NOW-120))" "true"  # 120s → "2m"
out="$(pool_admin_status)"
# lane 7 is stale (owner 1) so it appears; assert an age token is in the AGE column.
grep -qE '^[[:space:]]*7[[:space:]].*[0-9]+[smhd][[:space:]]' <<<"$out" \
    && ok "age: lane 7 shows an Ns/Nm/Nh/Nd token" || bad "age: no age token on lane 7"

# ---- Case 8: column alignment — header + row share ONE fmt -------------------
out="$(pool_admin_status)"
# header line and a data line both have 8 fields separated by 2+ spaces / known widths.
# Sanity: header line starts with "LANE" and contains all 8 labels.
hdr="$(grep -m1 '^LANE' <<<"$out")"
for label in LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE; do
    grep -q "$label" <<<"$hdr" || bad "align: header missing $label"
done
ok "align: header has all 8 column labels"

# ---- Case 9: stdout is PURELY the table (no log noise leaks to stdout) --------
# (POOL_LOG_PATH=/dev/null above; _pool_log also writes stderr. Assert no ISO timestamp
#  lines — which _pool_log emits — appear on stdout.)
out="$(pool_admin_status)"
! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' <<<"$out" \
    && ok "stdout-discipline: no _pool_log timestamp leaked to stdout" \
    || bad "stdout-discipline: log line on stdout"

rm -rf "$STATE"
echo "---"; echo "pass=$pass fail=$fail"; [[ "$fail" -eq 0 ]]
# Expected: pass≥17, fail=0. (Case 2/3 owner-liveness depends on the host's pid table;
#   Cases 5/7 use the deterministic dead-owner-1 trick → STALE + age are host-independent.)
```

### Level 3: Integration Testing (System Validation)

The full end-to-end (a real pooled Chrome lane exists and `status` shows it `live`)
needs a real Chrome + master profile + a `pi` ancestor — the domain of the M9 harness.
**For this task, Level 2's synthetic-lease tests ARE the integration proof** that the
function reads real-shape lease JSON and renders the table correctly. A smoke once the
dispatcher (M7.T5.S1) lands + a real lane is acquired:

```bash
# PREREQ: a lane acquired via the wrapper (run inside pi). Then, from a human terminal:
AGENT_BROWSER_POOL_STATE="${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool}" \
    bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_status'
# Expected: one aligned row for the live lane with AGE counting up; STATE = live.
# Kill the owning pi → re-run status → STATE flips to STALE (next acquire reaps it).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Pipeability (PRD §2.12 admin ergonomics): status | grep STALE lists only leaks.
bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_status' | grep STALE || true

# Long-path truncation (external-formatting §2): a 60-char cwd must NOT shove CHROME_PID.
STATE="$(mktemp -d)"; export AGENT_BROWSER_POOL_STATE="$STATE"; mkdir -p "$STATE/lanes"
export POOL_LOG_PATH=/dev/null
LONGCWD="/home/dustin/projects/some/very/deeply/nested/long/path/that/exceeds/twenty/four/chars"
jq -n --argjson lane 1 --argjson port 53421 --arg session "abpool-1" --argjson owner_pid 1 \
      --arg owner_cwd "$LONGCWD" --argjson chrome_pid 104811 --argjson acquired_at "$(date +%s)" \
      --argjson connected true \
      '{version:1,lane:$lane,ephemeral_dir:"",port:$port,session:$session,
        owner:{pid:$owner_pid,comm:"pi",starttime:0,cwd:$owner_cwd},
        chrome_pid:$owner_pid,chrome_pgid:$owner_pid,acquired_at:$acquired_at,
        last_seen_at:$acquired_at,connected:$connected}' > "$STATE/lanes/1.json"
bash -c 'source lib/pool.sh; pool_config_init; pool_state_init; pool_admin_status'
# Expected: the OWNER_CWD cell is truncated to 24 chars (precision) and CHROME_PID/AGE/STATE
#   stay in their columns (no drift). Confirm the row width is bounded (~94 cols).
rm -rf "$STATE"

# Concurrent-safe read while a reap runs in another shell: run `status` in a loop while
# `pool_reap_stale` deletes lanes — status must never abort (rc 0 every iteration) and
# never print a half-row. (TOCTOU → degraded row or skip; set -e guard handles it.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 complete: `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` zero
      warnings (whole file) + `git diff --stat lib/pool.sh` is append-only (0 deletions).
- [ ] Level 2 passes (pass≥17, fail=0): empty pool, live row, disconnected/stale verdict,
      corrupt-lease degraded row + loop continues, non-numeric stray skipped, age format,
      column alignment, stdout discipline.

### Feature Validation

- [ ] `pool_admin_status()` appended under banner `# Admin CLI — status (P1.M7.T1.S1)`.
- [ ] Empty pool → exactly `No active lanes.\n` (no header), rc 0.
- [ ] Non-empty → header (`LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`)
      + one aligned row per valid lane, ascending.
- [ ] STATE precedence correct: STALE (rc 0) > disconnected (rc≠0 + connected:false) > live.
- [ ] Corrupt/missing lease → degraded row (`?`/`STALE`) + continue (loop survives).
- [ ] Long OWNER_CWD/SESSION truncated (precision `%-N.Ns`); columns never drift.
- [ ] stdout is purely the table (pipeable; no `_pool_log`/`pool_die` noise).

### Code Quality Validation

- [ ] Follows house style: `set -euo pipefail`-safe (all non-zero helpers guarded), SC2155
      (declare-then-assign), `(( ))` only inside `if`, banner convention, doc-comment header.
- [ ] Composes ONLY landed helpers (no new system interaction, no flock, no Chrome).
- [ ] Anti-patterns avoided: no bare `pool_lease_read`/`pool_lane_is_stale` capture (would
      abort on rc 1/2); no `jq -e` on `connected`; no bare `%-Ns` for cwd/session (no truncate);
      no `pool_die` (read-only, non-fatal); no edits to existing functions.
- [ ] The header doc-comment documents all 8 output columns + STATE values (item DOCS step).

### Documentation & Deployment

- [ ] The function is self-documenting via its header doc-comment (columns + STATE + contract).
- [ ] No new env-vars; no `.gitignore` change; no new files; the dispatcher is M7.T5.S1.
- [ ] The `--help` subcommand text (which references these columns) is the dispatcher's job;
      this task provides the documented function the dispatcher will call.

---

## Anti-Patterns to Avoid

- ❌ Don't build `bin/agent-browser-pool` or wire `--help` — that is M7.T5.S1. This task is
      **lib-only**: append `pool_admin_status()` to `lib/pool.sh`. Nothing else.
- ❌ Don't edit any existing function in `lib/pool.sh` — append-only. `git diff` must be purely
      additive (0 deletions in the existing body).
- ❌ Don't call `pool_lease_read` / `pool_lane_is_stale` WITHOUT a guard — both can return
      non-zero (rc 1 / rc 1+2) and a bare capture ABORTS under `set -e`. Use
      `if ! json="$(…)"` and `if pool_lane_is_stale …; then … else … fi`.
- ❌ Don't use `jq -e` to read `connected` — `-e` exits 1 on JSON `false`. Use `jq -r` (echoes
      the literal string) and compare `[[ "$connected" == "false" ]]`.
- ❌ Don't compute AGE without a numeric guard on `acquired_at` — a missing field yields the
      STRING `"null"`, and `$(( now - null ))` is an arithmetic error under `set -e`.
- ❌ Don't use a bare `%-Ns` for OWNER_CWD / SESSION — it does NOT truncate; a long path shoves
      the next column. Use precision `%-N.Ns`.
- ❌ Don't use tabs for column alignment — tab stops are terminal-dependent → misalign. Use
      fixed-width spaces (`printf %-Ns`).
- ❌ Don't call `pool_die` or return non-zero — status is read-only + non-fatal; a corrupt lease
      degrades to a `?`/`STALE` row and the loop continues.
- ❌ Don't print anything but the table (or the empty message) to stdout — `_pool_log` (file+stderr)
      and `pool_die` (stderr) must not leak; stdout must stay pipeable.
- ❌ Don't use `local x="$(…)"` (SC2155) — declare all locals up front, then assign.
- ❌ Don't write a bare `(( expr ))` statement (returns 1 on a zero result → fatal under `set -e`) —
      keep arithmetic inside `if`/`elif`, or use the `$(( ))` expansion form.
- ❌ Don't iterate `*.json` yourself — use `pool_lanes_list` (it skips non-numeric artifacts and
      sorts ascending, so the table is deterministic).
- ❌ Don't modify `.gitignore`, `PRD.md`, `tasks.json`, `prd_snapshot.md`, `bin/`, or `test/` —
      those are owned by other tasks / the orchestrator / humans.
