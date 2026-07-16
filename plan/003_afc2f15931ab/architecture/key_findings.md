# Key Findings & Feasibility — Plan/003 (Multi-Harness Owner Resolution)

## Feasibility verdict: ✅ READY TO BUILD

The delta is well-scoped, the code is clean and modular, and all touch-points are confirmed
by static research (`bash -n` + `shellcheck -s bash` both clean on lib/pool.sh). No
re-architecture; one core function + config + message + test/doc sweep.

## Verified facts (all line numbers exact against current tree)

### Code touch-points (lib/pool.sh)
| Site | Line | Current | Change | Requirement |
|------|------|---------|--------|-------------|
| config block | after 176 | (no harness config) | ADD POOL_HARNESSES freeze | R1 |
| config header comment | ~109-128 | (no harness line) | ADD AGENT_BROWSER_POOL_HARNESSES doc | R1 |
| TEST MODE comm | 514 | `POOL_OWNER_COMM="pi"` | read `/proc/$ovr_pid/comm` (fallback "pi") | R2 (D1) |
| walk loop declaration | 535 | `local ... found_pid=""` | ADD `found_comm=""` | R2 |
| walk loop check | 540 | `if [[ "$comm" == "pi" ]]` | set-membership `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]` + capture found_comm | R2 |
| RESULT comm | 564 | `POOL_OWNER_COMM="pi"` | `="$found_comm"` | R2 |
| no-ancestor log | 581 | "no pi ancestor" | "no recognized-harness ancestor" | R2 |
| resolve header comment | 487-498 | "walk ppid to comm=='pi'" | "first ancestor whose comm is a recognized harness" | R2 |
| fail-fast message | 3415 | "require a pi ancestor (owning pi process)" | "require a supported agent harness (pi/claude/codex/agy)" | R3 |
| fail-fast comment | 3411-3412 | "no pi ancestor → fail-fast" | "no recognized-harness ancestor → fail-fast" | R3 |

### No-change sites (already comm-generic — confirmed)
| Site | Line | Why no change |
|------|------|---------------|
| `pool_owner_alive` | 627, 662 | `${3:-pi}` fallback (pi ∈ default set); generic `[[ == $expected_comm ]]` |
| `pool_lane_is_stale` | 1176 | passes stored `${comm:-pi}` generically |
| lease write (acquire) | 2133 | writes `$POOL_OWNER_COMM` — auto-correct after R2 |
| lease write (adopt) | 2044 | `--arg comm "$POOL_OWNER_COMM"` — auto-correct after R2 |

### Test touch-points (test/)
| Site | Line | Current | Change | Requirement |
|------|------|---------|--------|-------------|
| `spawn_sim_owner` | 103-140 | `[SECONDS]`, hardcoded `pi` bin | `[SECONDS] [COMM]`, 2nd positional default `pi` | R4 |
| `selftest_sim_owner_is_alive_pi` | 293-307 | asserts pi-comm owner | KEEP GREEN (pi ∈ default set) | R4 (preserve) |
| NEW selftest | (new) | — | `selftest_owner_resolves_non_pi_harness` (positive claude + negative xterm) | R4 |
| transparency.sh fail-fast poll | 528 | `[[ "$msg" == *"pi ancestor"* ]]` | match new R3 message (`"supported agent harness"`) | blast radius (D2) |

### Doc touch-points — see docs_map.md for the full per-file/per-line map.
- **Mode A (ride with M1 subtasks):** configuration.md (9 edits), SKILL.md (7 edits), skill-README.md (1-3 edits).
- **Mode B (final task M3):** README.md root (~15 edits + NEW §2.17 cross-harness section), install.sh (optional).

## Risks & mitigations
1. **transparency.sh:528 breaks** when R3 changes the message → mitigated by P3.M2.T1.S3
   (depends on the message-change subtask). See D2.
2. **TEST MODE comm (D1)** — if not generalized, the new selftest's positive case can't observe
   a non-pi comm → mitigated by baking the D1 decision into P3.M1.T1.S2's context_scope.
3. **concurrency.sh** uses a per-test setup() runner (2 calls) — pre-existing, NOT touched by
   this delta. The new selftest goes in validate.sh's single-setup runner (safe).
4. **15-char TASK_COMM_LEN** — default set `pi,claude,codex,agy,antigravity` all ≤15 chars. No
   truncation risk for the default set; custom harnesses may need a guard (out of scope).

## SP estimate: ~10 SP across 3 milestones, 3 tasks, 9 subtasks.
