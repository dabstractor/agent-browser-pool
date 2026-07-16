# Delta PRD — Multi-Harness Owner Resolution (PRD §1.1, §2.4, §2.8, §2.11, §2.17; Decision O9)

**Delta from:** `plan/002_97982899bef6` (No-Shadow Pivot — explicit `agent-browser-pool` invocation, COMPLETE).
**Status:** Ready to build. All decisions resolved (PRD §4 adds O9; the earlier "[DEFAULT: pi-required; … future option]" note in §2.4 is now RESOLVED).

---

## 0. Diff summary — what ACTUALLY changed

The entire delta between the prior PRD and the current PRD is **one conceptual change**: owner resolution generalizes from `pi`-only to a **recognized agent-harness set** (PRD Decision O9). Every other diff is downstream phrasing/documentation that flows from it.

### Concrete changes (counted, not inflated)

1. **New config var (§2.11):** `AGENT_BROWSER_POOL_HARNESSES` — comma-separated agent-harness process names (`comm` values) the pool treats as valid lane owners. **Default: `pi,claude,codex,agy,antigravity`.** This is a new global (`POOL_HARNESSES`) frozen in `pool_config_init`.
2. **Owner resolution logic (§1.1, §2.4 step 1):** `pool_owner_resolve()` walks `ppid` to the **first ancestor whose `comm` is in the recognized set** (not a hardcoded `"pi"`), and records the **actual matched comm** in `POOL_OWNER_COMM` (e.g. `"claude"`, `"codex"`). No recognized-harness ancestor → still fail-fast (condition unchanged: `POOL_OWNER_PID == 0`).
3. **Lease `owner.comm` field (§2.8):** already records `owner.comm`; the only change is it now holds the **actual matched harness**, not a constant `"pi"`. The JSON example changed `"comm": "pi"` → `"comm": "claude"` and gained a bullet explaining `status`/`doctor` show which tool owns each lane.
4. **Stale detection (§2.4 step 3a, §2.14):** the failure-mode table rows rephrased (`pi`→`harness`, `non-pi`→`non-harness`, `new pi`→`new harness proc`). **No logic change** — `pool_lane_is_stale`/`pool_owner_alive` already compare the lease's stored `comm` generically via the `comm != expected_comm` check; the `${comm:-pi}` fallbacks stay valid (`pi` is in the default set).
5. **Fail-fast message (§2.4 step 1):** `"… require a pi ancestor (owning pi process)."` → `"… requires a supported agent harness (pi/claude/codex/agy) …"`. Condition unchanged.
6. **Cross-harness skill installation docs (§2.17):** NEW paragraph + per-harness skills-dir table (pi / Claude Code / Codex / Antigravity) + the **Codex symlink caveat** (openai/codex#11314: Codex does not discover a *symlinked* `.agents/skills`; install a real copy for Codex). `install.sh --global-skill` already exists and covers pi's `~/.agents/skills/`; the per-harness dirs are documented steps.
7. **Phrasing sweep (§1.5, §2.5, §2.18, plus README/SKILL/configuration/skill-README):** "pi process"/"pi ancestor" → "harness process"/"recognized-harness ancestor" where the text means the generalized owner (not where it specifically means the `pi` tool).

**This is a medium-sized feature addition touching one core function path + config + a focused doc sync. It is NOT a re-architecture.** Target: 1 phase, 3 milestones.

---

## 1. Requirements

### R1 — Recognized-harness set as configuration (§2.11)
Add `AGENT_BROWSER_POOL_HARNESSES` (default `pi,claude,codex,agy,antigravity`), parsed in `pool_config_init` into a new global `POOL_HARNESSES`. Stored as the comma-separated, lowercased, de-duplicated list (a lookup string the walk loop can `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]` against). Empty/unset falls back to the default (never an empty set — an empty set would make every driving command fail the no-ancestor check).
- **Mode A docs (ride with work):** add the `AGENT_BROWSER_POOL_HARNESSES` row to the env-var table in `references/configuration.md` and to `pool_config_init`'s comment block (lib/pool.sh ~line 109). Document the "node-wrapped launcher may expose a different `comm`" tuning note (PRD §2.11).

### R2 — Generalize `pool_owner_resolve()` (§1.1, §2.4 step 1, §2.8)
In `lib/pool.sh` `pool_owner_resolve()` (currently lines ~486–583):
- **REAL MODE walk loop (~line 540):** replace `if [[ "$comm" == "pi" ]]` with set-membership against `POOL_HARNESSES`. On match, capture the matched `comm` into the variable used for `POOL_OWNER_COMM` (NOT a hardcoded `"pi"`).
- **RESULT block (~line 563):** set `POOL_OWNER_COMM` to the **actually matched** comm.
- **TEST MODE block (~line 514):** it currently hardcodes `POOL_OWNER_COMM="pi"`. Keep `"pi"` as the test-mode default (it is in the default set and preserves all existing owner-simulation tests), OR honor a narrow new test hook `AGENT_BROWSER_POOL_OWNER_COMM` if needed by R3's tests. Prefer keeping `"pi"` unless R3 proves otherwise — minimize test-hook surface.
- Leave the no-ancestor path returning `POOL_OWNER_PID="0"` **unchanged** (the wrapper's fail-fast condition is identical).
- **Mode A docs (ride with work):** update the function's header comment (§2.4 step 1 reference: "walk ppid to first comm=='pi'" → "to first ancestor whose comm is a recognized harness"); update the `_pool_log` "no pi ancestor" line to "no recognized-harness ancestor".

### R3 — Update the fail-fast message (§2.4 step 1, `pool_wrapper_main` ~line 3415)
Change `pool_die` text from `"… require a pi ancestor (owning pi process)."` to `"… requires a supported agent harness (pi/claude/codex/agy)."` (keep the "For raw browser use without pooling, call 'agent-browser' directly." second line). No condition change.
- **Mode A docs:** the message text itself is user-facing doc; no separate doc file.

### R4 — Multi-harness test coverage (§2.18)
The existing `spawn_sim_owner` (test/validate.sh:103) and `selftest_sim_owner_is_alive_pi` (line 293) simulate a `"pi"`-comm owner by copying `sleep` to a file named `pi`. Add coverage proving a **non-`pi` harness comm** resolves and stays live:
- Generalize `spawn_sim_owner` to optionally take a `comm` name (default `pi`), so a test can spawn a `"claude"`-comm owner.
- Add a selftest (e.g. `selftest_owner_resolves_non_pi_harness`) asserting: under default `POOL_HARNESSES`, a simulated `"claude"`-comm ancestor resolves (`POOL_OWNER_COMM=="claude"`, `POOL_OWNER_PID!=0`) and `pool_owner_alive` accepts it; and that a comm NOT in the set (e.g. `"xterm"`) does NOT resolve.
- **Do not** regress existing `pi`-comm coverage — `pi` remains in the default set, so `selftest_sim_owner_is_alive_pi` stays green untouched.
- **AGENTS.md §1/§2:** any live run stays isolated + `timeout`-bounded + reaped; prefer asserting against lib functions (`pool_owner_resolve` + `pool_owner_alive`) directly rather than booting Chrome. Owner-simulation spawns real processes — keep the single-setup discipline and reap sim-owner PIDs.

### R5 — Documentation sync (Mode A, per-file) + changeset-level README (Mode B)
- **Mode A (ride with each implementing requirement above):**
  - `references/configuration.md`: add `AGENT_BROWSER_POOL_HARNESSES` row; rephrase the dispatch/troubleshooting rows that say "no pi ancestor → fail-fast" to "no recognized-harness ancestor → fail-fast"; fix the `resolve owning pi PID (walk ppid → comm == 'pi')` line to the set-membership wording; the `pi` ancestor pitfall row → recognized-harness.
  - `.agents/skills/agent-browser-pool/SKILL.md`: rephrase "outside `pi` … fails fast" to "outside a supported harness (`pi`/`claude`/`codex`/`agy`) … fails fast"; mention lanes are owned by the harness process.
  - `.agents/skills/agent-browser-pool/README.md`: pitfall line "without a `pi` ancestor" → "without a supported-harness ancestor".
- **Mode B (changeset-level, depends on R1–R4):**
  - `README.md`: (a) env-var table gains `AGENT_BROWSER_POOL_HARNESSES`; (b) the "requires a `pi` ancestor" callouts and the architecture "resolve owning `pi`" line generalize to recognized-harness; (c) **add the §2.17 cross-harness skill-installation paragraph + the per-harness skills-dir table + the Codex symlink caveat** (`openai/codex#11314`) — this is the headline doc addition of the changeset. `install.sh --global-skill` already covers pi's `~/.agents/skills/`; document the per-harness dirs as manual install steps (optionally extend `install.sh` help/success text to reference them — NOT required).
  - `install.sh`: optionally update `--global-skill` help text to point at the README's per-harness table. No new required flag.

---

## 2. Scope deltas vs. the prior (completed) PRD

- **MODIFIED:** owner identity model — `pi`-only → recognized-harness set (O9). The triple `(pid, comm, starttime)` (§2.8/§2.13) is unchanged; only the *set of acceptable `comm` values* widens, and the recorded `comm` becomes the actual match.
- **MODIFIED (doc-only):** §1.1, §1.5, §2.5, §2.14, §2.18 phrasing (`pi`→`harness`).
- **ADDED:** `AGENT_BROWSER_POOL_HARNESSES` config (§2.11), O9 decision (§4), §2.17 per-harness skill-install table + Codex caveat.
- **REMOVED:** none. (The "[DEFAULT: pi-required; … future option]" note in the prior §2.4 is superseded/resolved by O9 — no code carried that DEFAULT.)
- **Preserved from prior session (do NOT re-implement):** the entire no-shadow explicit-invocation model (P2.M1–M6, COMPLETE). `install.sh --global-skill`, `pool_wrapper_main` fail-fast condition, `pool_lane_is_stale`/`pool_owner_alive` identity checks, atomic lease writes, reflink copy, and all PATH-isolation machinery are reused unchanged.

---

## 3. Plan structure (for the breakdown agent)

**Phase P3 — Multi-harness owner resolution.** One phase, three milestones. Estimated ~80–120 LOC of bash touched (mostly in `lib/pool.sh` + tests) plus a focused doc sweep.

- **P3.M1 — Core generalization (`lib/pool.sh`):** R1 (config var + `POOL_HARNESSES`), R2 (`pool_owner_resolve` set-membership + record actual comm), R3 (fail-fast message). Static checks only (`bash -n`, `shellcheck -s bash`); do not boot Chrome.
- **P3.M2 — Test coverage (`test/`):** R4 (generalize `spawn_sim_owner`; add non-`pi`-harness selftest). Runs isolated + bounded per AGENTS.md.
- **P3.M3 — Documentation sync:** R5 Mode A (configuration.md, SKILL.md, skill README.md) + Mode B changeset-level `README.md` (incl. the §2.17 per-harness table + Codex caveat). Depends on P3.M1 + P3.M2.

---

## 4. Acceptance

- `pool_owner_resolve` records the **actual matched comm** for any harness in `POOL_HARNESSES`, and resolves `POOL_OWNER_PID=0` only when no recognized harness is an ancestor.
- A simulated non-`pi` harness (e.g. `"claude"`) resolves and stays live; a non-harness comm does not.
- The fail-fast message names the supported harnesses; the condition is unchanged.
- `AGENT_BROWSER_POOL_HARNESSES` is configurable; empty/unset → default set (never empty).
- `bash -n`/`shellcheck -s bash` clean on `lib/pool.sh`, `install.sh`, `test/*`; no existing `pi`-comm test regresses.
- README/configuration/SKILL/skill-README reflect the recognized-harness model and document per-harness skill install + the Codex caveat.
