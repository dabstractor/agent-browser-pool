# Research: P4.M1.T4.S3 — pin documentation (configuration.md + SKILL.md + skill README)

## Source of truth: exact implemented die strings (from sibling PRPs, treated as contracts)

1. **Malformed `ABPOOL_LANE`** (P4.M1.T2.S1, `pool_config_init`, pre-flock, every verb):
   `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw value>'`
   (Strict uint; `03`, `abc`, `0`, `-2` all die. Empty/unset → auto-assign.)

2. **Pinned lane live-foreign** (P4.M1.T4.S1, inside acquire critical section):
   `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`

3. **Pinned but owner already holds another lane** (P4.M1.T4.S1):
   `owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE`

4. **Wrapper terminal surface on any pinned acquire failure** (P4.M1.T4.S2, replaces exhaustion wait — never waits, never force-reaps):
   `agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)`

5. **Caller-mode dead parent** (P4.M1.T3.S1):
   `agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process`

## Pin semantics (5 cases, P4.M1.T4.S1)
- free → claim; stale → reap+claim (NO orphan adoption even if Chrome responsive); live+mine → idempotent reuse (echo N, rc 0); live+foreign → die (#2); I hold another live lane → die (#3). Ownership/reaping rules unchanged; works in both owner modes.

## Actual current file anchors (line numbers in the item description are estimates; anchor by content)

`references/configuration.md` (182 lines):
- env table L11–30 — `ABPOOL_OWNER` row L29, `ABPOOL_LANE` row L30 **already present** (T2.S2). Do not duplicate.
- `### Caller-scoped lanes (orchestrator mode)` at L47, ends ~L74 (usage code block + "Default path unchanged"). Insert `### Lane pinning (ABPOOL_LANE)` subsection right after it, before `## Command dispatch` at L76.
- Troubleshooting matrix `## Troubleshooting matrix` at L153; header row L155 `| Symptom | Likely cause | Fix / response |`; rows L157–165; last row is the `doctor` WARN row (L165). Add 3 rows after L165.

`SKILL.md` (167 lines):
- `## 4. Common pitfalls` L143; existing bullets are `- **"quoted complaint"** explanation…`; last bullet is "Don't confuse `close` with release." (~L155/156). Add pin bullet after it.
- `## 5. Reference` L162–167; final sentence ends with "…subsection for parallel-worker usage." Extend with pin mention.

`README.md` (46 lines):
- `## What it covers` bullets at L10–L18 (3 bullets: Acquire+connect / Teardown / Pitfalls). Add a 4th bullet at L19 covering orchestrator mode + pin.

## Style rules
- No PRD § citations in skill docs (SKILL.md, configuration.md, README.md).
- Die strings quoted in docs must be EXACT mirrors of the implemented strings (audited by P4.M3.T1.S2). Where the code interpolates ($ vars), quote with the leading `agent-browser-pool:` prefix where the implemented string has one (strings #1, #4, #5 have it; #2/#3 do not).