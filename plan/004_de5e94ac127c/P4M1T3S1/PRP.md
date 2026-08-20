# PRP — P4.M1.T3.S1: Insert caller-mode branch in pool_owner_resolve

## Goal

**Feature Goal**: When `POOL_OWNER_MODE == "caller"` (set by `pool_config_init` from
`ABPOOL_OWNER`, landed in P4.M1.T2.S1), `pool_owner_resolve` resolves the owner to the
calling shell's `$PPID` (the orchestrator subprocess parent in production) instead of
walking the ppid chain for a recognized harness. Ancestor mode (default) stays
byte-identical to HEAD.

**Deliverable**: A single new branch block in `pool_owner_resolve` (lib/pool.sh),
inserted AFTER the TEST MODE hook block and BEFORE the REAL MODE ppid walk, setting the
four existing globals and returning 0. Plus one in-code comment citing PRD §2.12.

**Success Definition**:
- `ABPOOL_OWNER=caller` + live parent → `POOL_OWNER_PID=$PPID`, `POOL_OWNER_COMM` from
  `/proc/$PPID/comm`, `POOL_OWNER_STARTTIME` via `_pool_owner_starttime "$PPID"`,
  `POOL_OWNER_CWD` via `readlink /proc/$PPID/cwd`; one `_pool_log` CALLER MODE line;
  `return 0`.
- `ABPOOL_OWNER=caller` with dead/orphaned parent (`/proc/$PPID` missing OR `$PPID == 1`)
  → `pool_die` with the exact §2.15-style message (below). Caller mode must NEVER
  leave `POOL_OWNER_PID=0` on the happy path (the wrapper fail-fast at ~L3643–3645 keys
  on `POOL_OWNER_PID == "0"` — do not change that gate's condition).
- No `ABPOOL_OWNER` set → the function's ancestor path is byte-identical to HEAD
  (verify by diffing the function against HEAD).
- `bash -n lib/pool.sh` + `shellcheck -s bash lib/pool.sh` clean (zero new warnings).

## Why

PRD §2.12 (O10): parallel browser-driving subprocesses from one orchestrator each need
their own lane. Keying ownership on `$PPID` (the orchestrator-spawned wrapper process)
means each subprocess's lane is reaped by the existing lazy reaper when it exits — zero
downstream changes needed. This subtask is the resolve branch ONLY: docs ride in
P4.M1.T3.S2, pin branch in P4.M1.T4, tests in P4.M2.T1.S2/S3.

## What

### Success Criteria

- [ ] Caller branch inserted at the blank lines between the TEST MODE block
      (`return 0` … `fi`) and the `# --- 2. REAL MODE` comment in `pool_owner_resolve`.
- [ ] Hook precedence preserved: `AGENT_BROWSER_POOL_OWNER_PID` (TEST MODE) still wins
      over caller mode (branch ordering: globals reset → TEST MODE → CALLER MODE →
      REAL MODE walk).
- [ ] Hard error on dead parent: `pool_die "agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process"`.
- [ ] No new globals; no changes to any downstream function (`pool_lease_find_mine`,
      `pool_owner_alive`, reaper, lease writes) or the wrapper gate.
- [ ] No ppid ancestor walk and no `POOL_HARNESSES` matching inside the caller branch
      (`AGENT_BROWSER_POOL_HARNESSES` is irrelevant in caller mode — no harness
      fail-fast applies).
- [ ] Static checks clean; ancestor path byte-identical to HEAD.

## All Needed Context

### Documentation & References

```yaml
- url: (in-repo PRD) PRD.md §2.12 (caller-scoped selection), §2.14 (caller-scoped
       exception), §2.15 (failure-mode row), §2.20 (early /proc read gotcha)
  why: defines owner = caller, bypass of harness fail-fast, hard-error semantics.
  critical: the PRD's "$$" wording is the in-process test view; binding resolution is
       owner = THIS shell's $PPID (delta PRD §1 — the production caller is the
       orchestrator subprocess that invoked bin/agent-browser-pool).

- file: lib/pool.sh — pool_owner_resolve (currently ~L516–L614)
  why: the ONLY function to modify.
  pattern: exact internal order today: globals reset (L533–534) → TEST MODE block
       (~L537–561: `return 0` then `fi`) → two blank lines → `# --- 2. REAL MODE`
       comment + `local pid="$$"` walk. Insert the caller branch on the blank lines.
  gotcha: every global write follows `VAR="..."; declare -g VAR` — copy that. Comm
       read uses the TEST-MODE cat-with-fallback style (~L545):
       `POOL_OWNER_COMM="$(cat /proc/$PPID/comm 2>/dev/null || printf 'unknown')"`.
       starttime via the existing wrapper `_pool_owner_starttime "$PPID"` (it delegates
       to `_pool_get_starttime`, the ONE canonical parser — greedy `##*)` strip +
       field 20; never write your own parser, never naive `awk '{print $22}'`).

- file: lib/pool.sh — pool_owner_alive (~L655–688)
  why: downstream consumer of the globals; keys on /proc/<pid> existence + comm +
       starttime. NO changes needed; cited to prove zero downstream impact.

- file: lib/pool.sh — pool_wrapper_main fail-fast (~L3643–3645)
  why: fires only when POOL_OWNER_PID=="0". Caller mode must always set a non-zero
       PID or pool_die — never fall through to 0 on the happy path. Do NOT change
       the gate's condition.

- file: lib/pool.sh — pool_config_init step 6b (~L218–232, landed P4.M1.T2.S1)
  why: sets POOL_OWNER_MODE ("caller" iff ABPOOL_OWNER non-empty, else "ancestor").
       Read ONLY the global `POOL_OWNER_MODE`; never re-read ABPOOL_OWNER here.

- file: plan/004_de5e94ac127c/architecture/system_context.md §3, synthesis.md §2.2
  why: the research basis for the insertion point and precedence ordering.
```

### Known Gotchas of our codebase & Library quirks

```bash
# CRITICAL precedence: TEST MODE hook > CALLER MODE > ancestor walk. Existing tests and
#   hook-simulated parallel tests rely on the hook winning.
# CRITICAL §2.20 early-read: the /proc snapshot inside pool_owner_resolve runs before
#   the step-k exec — satisfied by construction ($PPID survives exec anyway; the
#   wrapper never execs the pool itself, it sources lib/pool.sh in-process).
# CRITICAL $PPID==1 check: a reparented/orphaned caller's parent is init → owner is
#   gone → hard error (a dead-on-arrival owner would claim a lane instantly stale).
# $PPID is NOT updated on subshell forking issues in some shells — but we only care
#   about the wrapper process's parent, which is exactly $PPID in-process. Do NOT
#   re-derive the ppid from /proc/self/status (keep it simple: $PPID).
# SC2155: never `local x="$(…)"` — declare locals separately, assign in a second
#   statement (the function's existing style does exactly this).
# set -e: guard every rc-1 read with `|| true` (cat/readlink) like the TEST MODE block.
```

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: MODIFY lib/pool.sh — pool_owner_resolve
  - LOCATE: the two blank lines after the TEST MODE block's closing `fi` and before
    the `# --- 2. REAL MODE: walk ppid chain from $$` comment.
  - INSERT (before the REAL MODE comment; renumber local comments if the file uses
    `--- N.` numbering — the caller block becomes section 2 and REAL MODE becomes 3):
    if [[ "$POOL_OWNER_MODE" == "caller" ]]; then
        # Caller-scoped ownership (PRD §2.12 mode 1 / O10, P4.M1.T3.S1): the owner is
        # the parent of this pool process (production: the orchestrator subprocess).
        # The recognized-harness fail-fast does NOT apply here. No ppid walk.
        if [[ "$PPID" == "1" || ! -d "/proc/$PPID" ]]; then
            pool_die "agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process"
        fi
        local c_pid="$PPID" c_comm="" c_st="" c_cwd=""
        POOL_OWNER_PID="$c_pid"; declare -g POOL_OWNER_PID
        c_comm="$(cat "/proc/$c_pid/comm" 2>/dev/null)" || c_comm="unknown"
        POOL_OWNER_COMM="$c_comm"; declare -g POOL_OWNER_COMM
        c_st="$(_pool_owner_starttime "$c_pid" 2>/dev/null)" || true
        if [[ -n "$c_st" ]]; then
            POOL_OWNER_STARTTIME="$c_st"; declare -g POOL_OWNER_STARTTIME
        fi
        c_cwd="$(readlink "/proc/$c_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$c_cwd" ]]; then
            POOL_OWNER_CWD="$c_cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: CALLER MODE owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}" \
                  "cwd=${POOL_OWNER_CWD:-<unknown>}"
        return 0
    fi
  - STYLE: mirror the TEST MODE block's cat-with-fallback, `|| true` guards, `declare -g`
    after assignment, and single `_pool_log` line. Keep locals prefixed to avoid
    colliding with REAL MODE's `local pid=""` etc. (or place the block so its locals
    are scoped before REAL MODE's declarations — locals in one function share scope).
  - GOTCHA: pool_die message must match the text above verbatim (it mirrors the docs
    written in P4.M1.T3.S2 / troubleshooting rows).

Task 2: VERIFY no other file changes
  - Confirm zero downstream edits: grep that POOL_OWNER_MODE is read ONLY inside
    pool_owner_resolve's new branch (config-init write site + env-table comment aside).
  - Confirm the wrapper fail-fast condition (~L3643–3645) is untouched.

Task 3: STATIC VALIDATION (see Validation Loop — planning-time only bash -n/shellcheck;
    live tests belong to P4.M2)
```

### Integration Points

```yaml
CONSUMES:
  - POOL_OWNER_MODE global from pool_config_init step 6b (P4.M1.T2.S1): branch active
    only when == "caller".
PRODUCES:
  - POOL_OWNER_PID / _COMM / _STARTTIME / _CWD keyed on $PPID — consumed unchanged by
    pool_lease_find_mine, pool_owner_alive, pool_lane_is_stale, reaper, lease writes.
DOWNSTREAM (future, NOT this subtask):
  - P4.M1.T4 pin branch reuses the same triple; P4.M2.T1.S2/S3 test it; P4.M1.T3.S2
    documents it. This subtask adds ONLY the in-code §2.12 comment — no .md edits.
```

## Validation Loop

### Level 1: Syntax & Style

```bash
bash -n lib/pool.sh
shellcheck -s bash lib/pool.sh   # zero NEW warnings vs HEAD
# Expected: both clean. Fix before proceeding.
```

### Level 2: Ancestor-path byte-identity

```bash
git diff lib/pool.sh   # confirm the ONLY hunks are inside pool_owner_resolve's new
                       # branch (+ the comment); the ancestor walk body unchanged.
# Optional static identity check (no live runs):
git show HEAD:lib/pool.sh | sed -n '/REAL MODE/,/^}/p' > /tmp/a
sed -n '/REAL MODE/,/^}/p' lib/pool.sh > /tmp/b
diff /tmp/a /tmp/b   # only section-number comment drift allowed
```

### Level 3: Isolated micro-check (only if needed; timeout-bounded, temp-tree)

```bash
# Bounded, isolated sanity of resolve-only (NO Chrome, NO lanes):
T=$(mktemp -d)
timeout 20 env -i HOME="$T" PATH=/usr/bin:/bin bash -c '
  set -euo pipefail
  source lib/pool.sh 2>/dev/null || source ./lib/pool.sh
  # stub config paths so pool_config_init does not die; then:
  pool_config_init
  pool_owner_resolve
  echo "mode=$POOL_OWNER_MODE pid=$POOL_OWNER_PID comm=$POOL_OWNER_COMM st=${POOL_OWNER_STARTTIME:-none}"
'
# Expected: mode=caller pid=<the timeout-shell pid> comm=bash st=<digits>
rm -rf "$T"
# Do NOT boot Chrome or run the suite — that is P4.M2's job, in the full sandbox.
```

## Final Validation Checklist

- [ ] `bash -n` + `shellcheck` clean (zero new warnings)
- [ ] Caller branch sits between TEST MODE `fi` and REAL MODE comment; hook precedence kept
- [ ] Dead-parent case pool_dies with the exact message; happy path never leaves PID=0
- [ ] Only the four existing globals set; no new globals; no downstream file/function edits
- [ ] Ancestor path byte-identical to HEAD (diff-verified)
- [ ] In-code comment cites PRD §2.12; no docs files touched (they belong to T3.S2)
- [ ] No orphan processes / temp dirs left by any micro-check

## Anti-Patterns to Avoid

- ❌ Don't write a new /proc/<pid>/stat parser — use `_pool_owner_starttime`
- ❌ Don't use `kill -0` for the parent liveness check — `/proc/$PPID` + `!= 1` only
- ❌ Don't read `ABPOOL_OWNER` directly — read the frozen `POOL_OWNER_MODE` global
- ❌ Don't relax/modify the wrapper's `POOL_OWNER_PID=="0"` gate
- ❌ Don't add TEST MODE env vars, walk POOL_HARNESSES, or touch lease logic here

**Confidence Score: 9/10** — insertion point, exact code shape, and all consumers are
verified against the live source; the only residual risk is line-number drift from the
concurrently-landing P4.M1.T2.S2 docs item (docs-only, no lib/pool.sh conflict).