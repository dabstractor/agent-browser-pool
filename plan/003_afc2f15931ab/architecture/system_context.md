# System Context — Plan/003 (Multi-Harness Owner Resolution, Decision O9)

## What this plan is

A **delta** on the completed `agent-browser-pool` implementation. The prior plans (001/002)
delivered the full pool: explicit `agent-browser-pool` invocation, identity-keyed lanes,
reflink copy, reaper, all CLI verbs, tests, docs. This delta (003) makes **one conceptual
change**: owner resolution generalizes from `pi`-only to a **recognized agent-harness set**
(`pi,claude,codex,agy,antigravity`), configurable via `AGENT_BROWSER_POOL_HARNESSES`.

**This is NOT a re-architecture.** It touches one core function path + one config block +
one user-facing message + a focused test/doc sweep. Target: ~80–120 LOC of bash + a doc sweep.

## Source documents
- `plan/003_afc2f15931ab/delta_prd.md` — the delta requirements (R1–R5) and suggested structure.
- `plan/003_afc2f15931ab/prd_snapshot.md` — full current PRD (Decision O9 added).
- `PRD.md` (root) — authoritative PRD (read-only).

## Current codebase state (verified)
- `lib/pool.sh` — 4406 lines, single shared library. `bash -n` + `shellcheck -s bash` clean.
- `bin/agent-browser-pool` — entry point (sources lib/pool.sh).
- `test/{validate,release_reaper,concurrency,transparency}.sh` — test framework + suites.
- `.agents/skills/agent-browser-pool/{SKILL.md,README.md,references/configuration.md}` — skill docs.
- `README.md`, `install.sh` — user docs + installer.
- All prior functionality is COMPLETE and reused unchanged.

## The change in one diagram
```
BEFORE (pi-only):                    AFTER (recognized-harness set):
pool_config_init                     pool_config_init
  (no harness config)                  + POOL_HARNESSES = $AGENT_BROWSER_POOL_HARNESSES
                                        (default: pi,claude,codex,agy,antigravity)
pool_owner_resolve                   pool_owner_resolve
  walk ppid → comm == "pi"            walk ppid → comm ∈ POOL_HARNESSES  [set membership]
  POOL_OWNER_COMM = "pi" (hardcoded)  POOL_OWNER_COMM = $found_comm      [actual match]
pool_wrapper_main                    pool_wrapper_main
  "require a pi ancestor"             "require a supported agent harness (pi/claude/codex/agy)"
```

## What does NOT change (already comm-generic)
- `pool_owner_alive` — compares the **stored** comm generically (line 662). `${3:-pi}` fallback
  stays valid (pi ∈ default set).
- `pool_lane_is_stale` — passes stored comm to `pool_owner_alive`. No change.
- Lease write sites (lines 2044, 2133) — write `$POOL_OWNER_COMM` automatically.
- Identity triple `(pid, comm, starttime)` — unchanged; only the **set of acceptable comm
  values** widens.

## Key architectural decisions made during research

### D1 — TEST MODE records the actual process comm (not hardcoded "pi")
The delta said "keep `pi` as test-mode default OR add a hook." Research revealed the new
selftest (R4) needs TEST MODE to record a non-pi comm. **Decision: in TEST MODE, read
`/proc/$ovr_pid/comm` instead of hardcoding "pi"** (pool.sh:514). This:
- Is truthful (records the sim owner's real kernel-set comm).
- Is backward-compatible (a `pi` sim owner → comm="pi").
- Makes the new `claude` selftest work WITHOUT a new env-var test hook (minimal surface).
- Falls back to "pi" if the read fails (robustness preserved).

### D2 — transparency.sh:528 is in R3's blast radius
`test_driving_no_pi_ancestor_fails_fast()` polls for the literal substring `"pi ancestor"`
in the pool_die message (transparency.sh:528). R3 changes the message wording. **This test
WILL break** and must be updated to match the new text (`"supported agent harness"`). Assigned
to P3.M2 (test milestone) as a subtask depending on P3.M1.T1.S3 (the message change).

### D3 — Mode A docs ride with work; Mode B README is the final task
Per SOW §5: configuration.md/SKILL.md/skill-README.md edits (Mode A) ride with the M1
subtasks that cause them. README.md root (Mode B) is the cross-cutting final task in M3,
depending on all M1+M2 subtasks. The env-var table row appears in BOTH: configuration.md
(Mode A, R1) and README.md (Mode B, M3) — exactly the §5 example.

## Constraints honored
- **AGENTS.md §1**: planning/research = static checks only. No Chrome booted, no test suite run.
- **AGENTS.md §4**: test changes keep the single-setup discipline; sim-owner PIDs reaped.
- **Writer safety**: one writer per file per sequential chain; subtask dependencies enforce order.
- **TDD (§3)**: every subtask implies write-failing-test → implement → pass; no separate test subtasks (except R4 which IS the test-generalization requirement).
