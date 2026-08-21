# Research notes — P1.M2.T3.S1 (BUG-005 help text fix + R8)

## Ground truth verified (static reads only, per AGENTS.md planning rules)

- `pool_config_init` harness block, lib/pool.sh ~207-217:
  `harnesses_raw="${AGENT_BROWSER_POOL_HARNESSES:-pi,claude,codex,agy,antigravity}"`,
  lowercased, `tr -s ','`, lead/trail commas stripped, empty→default. **REPLACE semantics**.
- Consumer: `pool_owner_resolve` matches `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]`
  (lib/pool.sh ~618) — replace semantics means an override silently breaks pi/claude/etc.
- Wrong help lines currently at lib/pool.sh **5205-5206** (PRD's 4879-4880 is STALE — file
  drifted from sibling subtasks; locate by
  `grep -n "AGENT_BROWSER_POOL_HARNESSES    extra" lib/pool.sh`).
- Column layout: env var names padded so descriptions align at a fixed column; continuation
  printf lines indented 34 spaces (verified against ABPOOL_LANE/AGENT_CHROME_* siblings).
- test/bootrace.sh: single-setup runner `_br_run_suite` with HARDCODED for-list (r1…r6 at
  time of read; r7 being added in parallel by P1.M2.T2.S1 per its PRP). Case style: `local`
  declares, `_fail "R#: msg" || rc=1`, `timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" …`,
  `|| true` guards, bodies in main shell (no subshells — EXIT-trap hazard).
- README.md:320 and .agents/skills/agent-browser-pool/references/configuration.md:28 already
  document replace semantics (per item contract; not re-modified by this subtask).
- lib/pool.sh is function-definitions at source time (dispatch driven by
  bin/agent-browser-pool) — safe to `source lib/pool.sh` in a subshell for the config probe.

## Parallel-item coordination

- P1.M2.T2.S1 (R7, doctor mkdir fix) is in flight in the same files. Our PRP: locate lines
  by grep; do NOT add r7 ourselves; insert r8 after whichever r-case is last; no conflict
  beyond the runner for-list append (different lines).
- P1.M3.T2.S2 consumes the exact substring 'replaces the default pi,claude,codex,agy,antigravity'.