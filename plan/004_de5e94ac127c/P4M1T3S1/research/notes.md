# Research notes — P4.M1.T3.S1 (caller-mode branch in pool_owner_resolve)

Verified against live source (2026-07-12 session):

- `pool_owner_resolve` in lib/pool.sh (~L516–L614). Internal order confirmed:
  globals reset → TEST MODE hook block (ends `return 0` + `fi`) → blank lines →
  `# --- 2. REAL MODE` comment + `local pid="$"` ppid walk. Insertion point = the
  blank lines.
- Globals set: exactly POOL_OWNER_PID/_COMM/_STARTTIME/_CWD, each
  `VAR=...; declare -g VAR`.
- `_pool_get_starttime` (canonical, greedy `##*)` strip + awk field 20) is wrapped by
  `_pool_owner_starttime` — reuse the wrapper, never re-implement.
- TEST MODE comm read idiom: `cat /proc/<pid>/comm 2>/dev/null || printf 'pi'`.
- `pool_owner_alive` (~L655) uses /proc existence + comm + starttime; no kill -0.
- Wrapper fail-fast at ~L3643–3645 keys on `POOL_OWNER_PID=="0"` — caller mode must
  pool_die on dead parent, never leave 0.
- P4.M1.T2.S1 already landed: `pool_config_init` step 6b (~L218–232) sets
  `POOL_OWNER_MODE` ("caller" iff ABPOOL_OWNER non-empty) + `POOL_LANE_PIN`.
  Consumer is this PRP's branch; read the global only.
- PRD §2.12 "$$" wording is the in-process test view; binding resolution per delta
  PRD §1: owner = $PPID (the orchestrator subprocess). Guard: /proc/$PPID exists and
  $PPID != 1, else pool_die (§2.15-row hard error).