# Research Notes — P2.M1.T1.S2 (Remove POOL_DISABLE passthrough + no-pi-ancestor fail-fast)

Scope: surgical edits inside `pool_wrapper_main` (and its header-comment block) in
`lib/pool.sh`. Remove the `POOL_DISABLE==1` passthrough (step b) entirely, and change the
no-pi-ancestor branch (step d) from `exec` passthrough to `pool_die` fail-fast. Plus the
header-comment hygiene that becomes stale as a direct consequence.

S1 (P2.M1.T1.S1) removes `POOL_DISABLE` from `pool_config_init` first. S2 removes the
**consumer**. The two touch disjoint regions (config_init lines ~96-210 vs wrapper ~3577+),
so the edit tool's text-matching works regardless of apply order; only line *numbers* shift
(S1 deletes 3 lines above the wrapper → wrapper lines move up by 3 after S1). All edits below
are specified by **exact text**, so they are robust to that shift.

## Exact target lines in lib/pool.sh (PRE-S1 current state; ~4613 lines)

| Line | Current content | Action | Bucket |
|------|-----------------|--------|--------|
| 3578 | `# GOTCHA — TERMINAL: all four exits are exec (b/c/d/k) or pool_die. NO return on success.` | UPDATE: b is deleted, d is no longer exec → `exits are exec (c/k) or pool_die (d + error branches)` | hygiene (consequential) |
| 3579 | `# GOTCHA — passthrough exec (b/c/d) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:` | UPDATE: only step c remains a passthrough exec → `(b/c/d)` → `(c)` | hygiene (consequential) |
| 3582 | `# GOTCHA — POOL_DISABLE is read AFTER pool_config_init (which freezes it @176). Step b reads` | DELETE (line + next) | required — item step (d) |
| 3583 | `#   the FROZEN global, not the raw env var.` | DELETE (with 3582) | required — item step (d) |
| 3595 | `# CONSUMES: POOL_DISABLE, POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS,` | remove `POOL_DISABLE, ` | required — item step (d) |
| 3603 | `    # config freezes POOL_DISABLE, POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.` | remove `POOL_DISABLE, ` | required — item step (d) |
| 3608 | `    # --- b. safety valve (PRD §2.17): POOL_DISABLE==1 → passthrough, no pooling ---` | DELETE entire step-b block (3608-3613) + trailing blank (3614) | required — item step (a) |
| 3609 | `    # Read the FROZEN global (config_init just set it). ORIGINAL "$@" unchanged.` | DELETE (with block) | required — item step (a) |
| 3610 | `    if [[ "${POOL_DISABLE:-0}" == "1" ]]; then` | DELETE (with block) | required — item step (a) |
| 3611 | `        _pool_log "pool_wrapper_main: POOL_DISABLE=1 → passthrough"` | DELETE (with block) | required — item step (a) |
| 3612 | `        exec "$POOL_REAL_BIN" "$@"` | DELETE (with block) | required — item step (a) |
| 3613 | `    fi` | DELETE (with block) | required — item step (a) |
| 3624 | `    # --- d. owner resolution (step 1): no pi ancestor → passthrough --------------` | `passthrough` → `fail-fast` | required — item step (c) |
| 3626 | `    # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ human in terminal).` | `human in terminal` → `caller has no pi ancestor` | required — item step (c) (comment accuracy) |
| 3628 | `        _pool_log "pool_wrapper_main: no pi ancestor → passthrough (human terminal)"` | REPLACE (with 3630) by `pool_die` 2-arg call | required — item step (b) |
| 3630 | `        exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — raw upstream tool for humans` | REPLACE (with 3628) by `pool_die` 2-arg call | required — item step (b) |

After S1 (POOL_DISABLE gone from config_init) the line numbers above each move UP by 3, but the
**text** of every target is byte-identical → the edit tool's `oldText` matches regardless.

## pool_die contract (verified, lib/pool.sh:30-33)

```bash
pool_die() {
    printf '%s\n' "$*" >&2
    exit 1
}
```
`"$*"` joins ALL args with the first char of IFS (default: space) into ONE line. So the S2 call:
```bash
pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
         "For raw browser use without pooling, call 'agent-browser' directly."
```
prints exactly ONE stderr line:
`agent-browser-pool: driving commands require a pi ancestor (owning pi process). For raw browser use without pooling, call 'agent-browser' directly.`
then exits 1. Matches gap_analysis §1b Change 2 and item LOGIC step (b) verbatim.

## pool_dispatch_classify — `open` is DRIVING (verified, lib/pool.sh:3172-3222)

The META set is exactly: `--help`/`-h`/`--version`, plus the two-word `session list`
(next-token peek). `open` is the first non-flag token → falls to the `*) cmd="$1"` branch →
returns `driving`. So `pool_wrapper_main open <url>` does NOT short-circuit at step c and DOES
reach step d (owner resolution). This is what makes the fail-fast microcheck correct: with a
forced no-owner, execution dies at step d, never reaching step g (Chrome boot).

## pool_owner_resolve — deterministic "no pi ancestor" simulation (verified, lib/pool.sh:490-583)

TEST MODE (PRD §2.18 / key_findings FINDING 8): if `AGENT_BROWSER_POOL_OWNER_PID` is set AND
matches `^[0-9]+$`, it is used DIRECTLY as the owner PID (no ppid walk). Setting it to `0`:
- `POOL_OWNER_PID="0"`, `POOL_OWNER_COMM="pi"`.
- Step d checks `[[ "${POOL_OWNER_PID:-0}" == "0" ]]` → TRUE → `pool_die`.

This means a validation microcheck can force the no-pi-ancestor path **deterministically and
without booting Chrome**, even if the test shell's real ppid chain happens to include a `pi`
process (i.e. when the agent runs inside pi). The starttime/cwd reads for PID 0 are guarded
(`2>/dev/null || true`) → fail silently, non-blocking.

## Test-suite impact of S2 (and S1) — EXPECTED failures only

| Test file | Reference | Effect after S1+S2 | Owner of the fix |
|-----------|-----------|--------------------|------------------|
| test/validate.sh | `selftest_config_disable` lines 346-357 (asserts `POOL_DISABLE=1`) | FAILS — `POOL_DISABLE` is unset | P2.M5.T1.S1 |
| test/transparency.sh | (none — grep for `no pi`/`human`/`passthrough.*no` returns rc 1; every test calls `_transparency_spawn_owner`) | **No failure** from the fail-fast change; no existing test exercises the no-pi-ancestor path | — (P2.M5.T2.S1 rewrites invocations later, but no assertion breaks now) |
| test/transparency.sh items (c)-(h) | use a spawned owner + real Chrome | NOT run during S2 (AGENTS.md §1: no Chrome during lib edits) | — |

→ The S2 validation gates MUST NOT run validate.sh or transparency.sh (the former has a known
expected failure owned by a later subtask; the latter boots real Chrome and is out of bounds
for a lib edit). Use the static gates + isolated, `timeout`-bounded micro-checks instead.

## Consumers of pool_wrapper_main's new behavior (for context, not edits here)

- `bin/agent-browser-pool`: currently `*) echo "Unknown command"; exit 1`. P2.M2.T1.S1 changes
  it to `*) pool_wrapper_main "$@"`. So the driving→fail-fast path is exercised only after that
  later subtask wires it in. S2 changes the function's contract; the entry point follows later.
- A caller with NO pi ancestor issuing a DRIVING command now gets exit 1 + the actionable
  message (instead of silently running the real binary as the agent's PID). Meta commands
  (skills/--version/session list) still pass through unchanged at step c — correct (PRD §2.4
  step 0: pool verbs + classify; §2.15: skills get core passthrough unaffected).

## Out-of-scope (DO NOT touch in S2)

| Reference | Line | Owner |
|-----------|------|-------|
| `printf '  AGENT_BROWSER_POOL_DISABLE ...'` in pool_admin_help | ~4606 | P2.M1.T3.S1 |
| `_pool_preflight_real_bin` (real-binary existence check) | NEW, inserted later | P2.M1.T2.S1 |
| `selftest_config_disable` in test harness | validate.sh:346-357 | P2.M5.T1.S1 |
| install.sh DISABLE mentions | install.sh:13,31,76,215 | P2.M3.T1.S1 |
| configuration.md DISABLE row | references/configuration.md | P2.M4.T2.S1 |
| SKILL.md / README.md passthrough language | SKILL.md, README.md | P2.M4.T1.S1 / P2.M6.T1.S1 |

## Baseline static gates (must remain green)

- `bash -n lib/pool.sh` → exit 0.
- `shellcheck -s bash lib/pool.sh` → exit 0, zero output (verified clean baseline; the deleted
  block has no shellcheck-relevant constructs, and the new `pool_die` 2-arg line-continuation is
  standard bash, SC-clean).

## SAFE TO SOURCE (re-confirmed)

lib/pool.sh has NO top-level execution (all 61 entries are functions; every
pool_config_init/pool_state_init/pool_wrapper_main call is inside another function). Sourcing
only defines functions. A micro-check that sources the lib, force-sets the no-owner override,
and calls `pool_wrapper_main open <url>` dies at step d (pool_die → exit 1) BEFORE any lane
lookup, port probe, or Chrome boot. It spawns nothing and leaves no orphans.
