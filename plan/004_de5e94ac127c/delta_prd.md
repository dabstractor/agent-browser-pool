# Delta PRD — Caller-Scoped Lane Selection & Lane Pinning (PRD §2.11, §2.12, §2.14, §2.15, §2.16, §2.19, §2.20; Decisions O10/O11)

**Delta from:** `plan/003_afc2f15931ab` (Multi-Harness Owner Resolution, COMPLETE — O9 landed:
`POOL_HARNESSES` config, set-membership walk, actual-comm recording, generalized
`spawn_sim_owner`, non-pi selftest, cross-harness docs).
**Status:** Ready to build. All decisions resolved (PRD §4 adds O10/O11).

---

## 0. Diff summary — what ACTUALLY changed

One conceptual addition in two parts — **caller-scoped lane selection** — plus a mechanical
section-renumber fallout:

1. **§2.11 (config): two new env vars.**
   - `ABPOOL_OWNER=caller` (any value) — key lane ownership on the **calling process**
     instead of the harness ancestor.
   - `ABPOOL_LANE=<N>` (positive integer) — explicit lane pin: adopt a free/stale lane N or
     hard-error on a live foreign lease.
2. **§2.12 (NEW section, "Caller-scoped lane selection")** — the spec for both modes,
   including: no ppid walk in caller mode; harness fail-fast does NOT apply in caller mode;
   all downstream lease logic (find-mine, liveness, stale-reap, teardown-on-owner-exit)
   unchanged; pin = free/stale→take, live-foreign→hard error (never a takeover); default
   path **byte-identical**; `--session`/`connect`/close scoping keep working in both modes;
   the parallel-scraper usage example; and the docs-impact note (SKILL.md + references must
   document both modes; code comments citing renumbered PRD sections must be updated).
3. **§2.13 (was §2.12, CLI):** + closing paragraph — `ABPOOL_LANE` is the controlled
   exception to "no lane-naming command" (can only create/adopt free/stale, never take over
   a live foreign lease).
4. **§2.14 (was §2.13, Safety):** + "Caller-scoped exception (§2.12)" bullet — both modes
   preserve cross-agent isolation; default path byte-identical.
5. **§2.15 (was §2.14, Failure modes):** + one row — pinned lane held by live foreign owner
   → fail fast, never take over.
6. **§2.16 (was §2.15, Invocation checklist):** + one line — orchestrator mode
     (`ABPOOL_OWNER=caller` per subprocess → own lane + auto-reap on exit).
7. **§2.19 (was §2.18, Testing):** + "Caller-scoped lanes (§2.12)" bullet block — parallel
   caller-mode acquires → distinct lanes; caller-mode lane reaped after owner death;
   pinned-lane conflicts error cleanly; default path unchanged.
8. **§2.20 (was §2.19, Impl notes):** + two gotchas — (a) caller mode reads
   `/proc/…/stat` (starttime) at owner-resolve time, before any exec; (b) `ABPOOL_LANE`
   must be a positive integer, validated **before** the flock, hard-error on malformed
   (no silent fallback to auto-assignment).
9. **Renumbering fallout:** old §2.12–§2.19 → §2.13–§2.20. ~73 `§2.1[2-9]` citations exist
   in code comments + README (lib/pool.sh 36, bin 1, install.sh 2, tests 30, README 4;
   SKILL/reference docs cite none) and must be re-mapped +1.
10. **§4:** + O10 (caller-scoped auto-assignment), + O11 (optional lane pin).

**Size: medium feature addition** — one branch in owner resolution, one branch in the
acquire path, config parsing, tests, docs, and a mechanical citation sweep. NOT a
re-architecture: lease model, reaper, liveness layer, flock acquire, boot pipeline, and
arg-cleaning are reused unchanged. Target: 1 phase, 3 milestones, ~110 LOC of new bash.

---

## 1. Resolved ambiguity — what "the calling process" is (read FIRST)

PRD §2.12 says caller mode keys on "`$$` … `/proc/$$/stat`". Taken literally at the CLI,
`$$` is the **wrapper process** (`bin/agent-browser-pool`), which is a *fresh, short-lived
process per command* (it `exec`s the real binary at step k and exits). Keying on the
wrapper's own pid would (a) make every lane stale after each command (owner dead), and
(b) let parallel scrapers **adopt each other's lanes** via REUSE-ORPHAN (any responsive
orphan is adoptable) — breaking the headline use case and §2.14 isolation.

**Resolution (binding for this delta):** in caller mode the owner is the **process that
invoked the pool command** — the wrapper's **immediate parent (`$PPID`)** in production.
The PRD's `$$` wording describes the in-process view (lib sourced directly by a test
shell, where the caller *is* `$$`). Consequences:

- Python/bash orchestrator subprocess calling `agent-browser-pool` many times → owner =
  the subprocess (stable across its calls) → one lane per subprocess, reaped when it
  exits. Exactly O10's stated semantics.
- The existing **TEST MODE hook (`AGENT_BROWSER_POOL_OWNER_PID` + `_STARTTIME`) keeps
  highest precedence** (above caller mode) — all existing tests and the new
  hook-simulated parallel test keep working unchanged (PRD §2.19 sanctions "via the
  owner-override hooks or real subprocesses").
- Caller mode must validate the parent: `/proc/$PPID` readable **and** `PPID != 1`
  (a reparented/orphaned caller is gone) — else `pool_die` with guidance ("invoke
  agent-browser-pool as a child of the long-lived orchestrator process"). A
  dead-on-arrival owner would claim a lane that is instantly stale to everyone.
- §2.20's "read /proc early, before any exec" gotcha is satisfied by design: snapshot the
  parent's `comm`/`starttime` inside `pool_owner_resolve` (which runs before the step-k
  exec; `$PPID` is unaffected by exec anyway).

---

## 2. Requirements

### R1 — Mechanical: PRD section-reference renumber sweep (FIRST, before new code)
Old §2.12→§2.13, §2.13→§2.14, §2.14→§2.15, §2.15→§2.16, §2.16→§2.17, §2.17→§2.18,
§2.18→§2.19, §2.19→§2.20 — applied **in descending order** (2.19 first) so nothing
double-shifts. Files: `lib/pool.sh` (36 citations), `bin/agent-browser-pool` (1),
`install.sh` (2), `test/validate.sh` (6), `test/concurrency.sh` (4),
`test/release_reaper.sh` (10), `test/transparency.sh` (10), `README.md` (4). Comment/README
text only — **zero behavior change, zero line-count change** (in-place token replacement).
New code from R2–R4 then cites the NEW numbering (§2.12 caller selection, §2.14 safety,
§2.15 failure modes, §2.19 testing, §2.20 impl notes).
- **Verify:** `bash -n` + `shellcheck -s bash` clean on every touched file; a grep audit
  shows the citation count preserved (73) with the distribution shifted +1; no test
  matches on `§2.x` strings (transparency.sh polls message text, not section numbers —
  confirmed).
- **Mode A docs:** none (mechanical sweep; README citations are corrected in place).

### R2 — Config: parse + validate `ABPOOL_OWNER` and `ABPOOL_LANE` (§2.11, §2.20)
In `pool_config_init` (`lib/pool.sh` ~130–230), add a block beside the §6 harnesses block
(~204–213):
- `ABPOOL_OWNER`: ON when set to **any non-empty value** (no truthy filtering — PRD says
  "any value"; recommend the conventional `caller`). Freeze as `POOL_OWNER_MODE`
  (`caller`/`ancestor`).
- `ABPOOL_LANE`: unset → `POOL_LANE_PIN=""` (default path). Set → must match
  `^[1-9][0-9]*$`; **malformed → `pool_die`** (hard error, no silent fallback — PRD §2.20),
  regardless of verb (config parses on every invocation; surfacing operator error early is
  the simple, consistent contract).
- Update the `pool_config_init` header env-var table comment (~100–115) with both vars.
- **Mode A docs (ride with work):** add `ABPOOL_OWNER` + `ABPOOL_LANE` rows to the env-var
  table in `.agents/skills/agent-browser-pool/references/configuration.md` (3-column
  format, after the `AGENT_BROWSER_POOL_HARNESSES` row, line ~28), matching the PRD §2.11
  wording.

### R3 — Caller-mode owner resolution (§2.12 mode 1, O10)
In `pool_owner_resolve` (`lib/pool.sh` 516–618), insert a branch **after the TEST MODE
block (~537–561) and before the REAL MODE ppid walk (~563)**:
- `POOL_OWNER_MODE == caller` → owner = the calling process per §1 above: pid=`$PPID`,
  `comm` from `/proc/$PPID/comm`, `starttime` via the existing `_pool_owner_starttime`,
  `cwd` via `readlink /proc/$PPID/cwd`. Validate (§1): `/proc/$PPID` readable and
  `PPID != 1`, else `pool_die`. **No ppid walk, no `POOL_HARNESSES` matching** —
  `AGENT_BROWSER_POOL_HARNESSES` is irrelevant in caller mode.
- Never sets `POOL_OWNER_PID=0` in caller mode → the wrapper's existing fail-fast
  condition (`== 0`, `pool_wrapper_main` ~3642) is bypassed **without changing the
  condition** (PRD: "a caller-mode process under a harness counts, and caller mode with no
  harness ancestor is also fine").
- Everything downstream (`pool_lease_find_mine`, `pool_owner_alive`, `pool_lane_is_stale`,
  reaper, lease writes at `_pool_acquire_critical_section`/`_pool_adopt_lane`) works
  unchanged — the owner triple is just keyed differently. No other function changes.
- **Mode A docs (ride with work):** `references/configuration.md` gains a "Caller-scoped
  lanes (orchestrator mode)" subsection with the PRD §2.12 parallel-scrapers example and
  the §1 parent-pid semantics; `SKILL.md` gains an orchestrator-mode note + the §2.16
  checklist line ("`ABPOOL_OWNER=caller` per subprocess → own lane, reaped on exit").

### R4 — Lane pin acquire path (§2.12 mode 2, §2.13 note, O11)
When `POOL_LANE_PIN` is set, lane selection uses N directly — skip
`pool_lease_find_mine` and `pool_find_free_lane` and the global reap/adopt scan:
- **`pool_wrapper_main` (~3651):** when pinned, skip the find-mine call and go straight to
  `pool_acquire_locked` (the pin logic below subsumes reuse).
- **`_pool_acquire_critical_section` (~2203):** pin branch replaces the reap-all/adopt/
  choose-N flow with a lane-N-specific one (still under the flock; format validation
  already happened in R2, pre-flock per §2.20):
  - No lease, no dir (free) → CLAIM N directly (`pool_lease_write`, provisional port=0 —
    same claim as today).
  - Lease stale (`pool_lane_is_stale` rc 0, reuse the tri-state as-is) →
    `_pool_release_lane_internals "$N"` (reap-if-stale, same semantics as acquire 3a;
    **no adoption** — deterministic assignment prefers a clean lane), then CLAIM N.
  - Lease live + owner is **me** (current `POOL_OWNER_*` identity) → reuse: echo N, no
    rewrite (idempotent re-pin).
  - Lease live + **foreign** owner → `pool_die` hard error naming lane N, the live owner
    pid, and "never a takeover" — **no block-with-timeout, no force** (§2.15 row).
  - Caller already holds a live lease on a *different* lane → `pool_die` (preserves the
    ≤1-lane-per-owner invariant; PRD is silent — hard error is the safe resolution).
- Ownership/reaping rules apply in **both** modes (caller or ancestor) — a pinned lane is
  still reaped when its owner dies (existing lazy reaper; no change).
- Boot/ensure-connected/cleaning/exec are untouched: a pinned provisional lane boots
  exactly like an auto one; `--session` stripping, `connect` normalization, and
  close-scoping (§2.4 step 5) keep working in both modes.
- **Mode A docs (ride with work):** `references/configuration.md` pin subsection +
  troubleshooting rows (pinned live-foreign conflict; malformed `ABPOOL_LANE`; caller-mode
  parent dead/reparented — mirror the exact `pool_die` texts); `SKILL.md` §4 pitfalls +
  §5 reference rows for both vars; skill `README.md` one-paragraph orchestrator-mode
  mention.

### R5 — Test coverage (§2.19 caller-scoped bullets; AGENTS.md §1/§2/§4 discipline)
All new lib-level tests are **auto-discovered selftests** in `test/validate.sh`
(`compgen | grep '^selftest_'`) running under the single-setup runner; they drive lib
functions directly with hermetic state dirs (`AGENT_BROWSER_POOL_STATE`,
`AGENT_CHROME_EPHEMERAL_ROOT` redirected to temp) and **boot no Chrome** —
`pool_acquire_locked` claims leases without launching (boot is a separate function):
1. **Caller-mode resolve (unit):** `ABPOOL_OWNER=caller pool_owner_resolve` in-process →
   `POOL_OWNER_PID == $PPID`, comm matches `/proc/$PPID/comm`, starttime non-empty,
   PID != 0 (fail-fast bypass proven).
2. **Distinct lanes, parallel caller-mode owners:** two simulated owners via the existing
   `AGENT_BROWSER_POOL_OWNER_PID` hook (PRD §2.19 sanctions this) doing parallel
   `pool_acquire_locked` → distinct lanes, both leases valid.
3. **Caller-mode owner death → reap:** kill the simulated owner (existing
   kill+`wait` zombie-reaping pattern) → `pool_lane_is_stale` rc 0 → reaper frees it.
4. **Pin matrix:** free→claim; stale→reap-then-claim (assert old lease gone + new owner);
   live-foreign→dies with the clear error (subshell + rc assert); live-mine→reuse; already
   -holds-another-lane→dies; malformed `ABPOOL_LANE` (e.g. `0`, `-1`, `abc`) → `pool_die`
   in `pool_config_init` (subshell assert).
5. **Default-path regression:** no env vars → `POOL_OWNER_MODE=ancestor`,
   `POOL_LANE_PIN=""`, and `pool_owner_resolve` behaves exactly as today (existing
   selftests already cover this — they must stay green **untouched**).
- **Optional E2E (one bounded test, real Chrome):** extend `test/concurrency.sh` with a
  caller-mode variant — two child `bash -c` processes each running
  `ABPOOL_OWNER=caller agent-browser-pool <driving>` under the suite's existing
  isolated+timeout+release/reap discipline → distinct lanes, full teardown after child
  exit. Only if runtime budget allows; the unit set above is the required coverage.
- No existing test sets the new vars → zero blast radius (the 003 fail-fast message test
  is unaffected; caller mode never reaches the fail-fast).

### R6 — Sync changeset-level documentation (Mode B — FINAL, depends on R1–R5)
- `README.md` (root): (a) env-var table gains `ABPOOL_OWNER` + `ABPOOL_LANE` rows (after
  the `AGENT_BROWSER_POOL_HARNESSES` row, line ~272 — **wording synced with
  configuration.md**); (b) NEW "Caller-scoped lanes (orchestrator mode)" section with the
  PRD §2.12 parallel-scrapers example, the pin rules (free/stale→take,
  live-foreign→error), and the isolation note (both modes preserve cross-agent
  isolation; default path unchanged); (c) failure-mode/troubleshooting row for the pinned
  live-foreign conflict; (d) invocation-checklist mention of orchestrator mode.
- Verify the R1 sweep left no stale citations anywhere (`grep -rn '§2\.1[2-9]'` spot-audit
  against the new numbering) and that all quoted `pool_die` texts mirror the implemented
  strings (same discipline as 003).
- `install.sh`: **no change** (no new dirs/flags/behavior).

---

## 3. Scope deltas vs. the prior (completed) PRD

- **ADDED:** caller-scoped auto-assignment (`ABPOOL_OWNER=caller`, O10); explicit lane pin
  (`ABPOOL_LANE=<N>`, O11); PRD §2.12; §2.15 failure row; §2.16 checklist line; §2.19 test
  bullets; §2.20 gotchas; config rows in §2.11.
- **MODIFIED (doc-only):** §2.13 CLI gains the `ABPOOL_LANE` exception paragraph; §2.14
  safety gains the caller-scoped bullet; §2.12–§2.19 renumbered → §2.13–§2.20 (hence R1).
- **REMOVED:** none.
- **Preserved from prior sessions (do NOT re-implement):** the entire O9 harness-set
  resolution (`POOL_HARNESSES`, set-membership walk, actual-comm recording), lease data
  model + atomic writes, lazy reaper + tri-state staleness, flock acquire critical
  section + post-lock boot, REUSE-ORPHAN adoption, exhaustion wait/force/alert, arg
  cleaning (`--session` strip, `connect` normalize, close scoping), install/no-shadow
  model, and the generalized `spawn_sim_owner` test helper.

## 4. Plan structure (for the breakdown agent)

**Phase P4 — Caller-scoped lane selection & lane pinning.** One phase, three milestones:

- **P4.M1 — Core (`lib/pool.sh`), static checks only:** R1 (renumber sweep FIRST), R2
  (config + validation), R3 (caller-mode resolve), R4 (pin acquire path). Verify each with
  `bash -n` + `shellcheck -s bash`; boot no Chrome (AGENTS.md §1).
- **P4.M2 — Tests (`test/validate.sh`, optional `concurrency.sh` E2E):** R5. Isolated +
  timeout-bounded + single-setup; reap every spawned sim owner.
- **P4.M3 — Documentation sync:** R6 Mode B (README root + sweep audit). Mode A docs ride
  with R2/R3/R4 as noted.

## 5. Acceptance

- **Default path byte-identical:** with no new env vars, all existing suites pass
  untouched; `POOL_OWNER_MODE=ancestor`, `POOL_LANE_PIN=""`.
- **Caller mode:** owner = the invoking process (`$PPID` at the CLI; TEST MODE hook
  overrides for simulation); one lane per orchestrator subprocess; lane reaped after the
  subprocess exits; harness fail-fast bypassed without any condition change; dead/reparented
  parent (PPID unreadable or 1) → clear hard error.
- **Pin:** free→claim, stale→reap-then-claim, live-mine→reuse, live-foreign→hard error
  (never takeover, never wait), already-holds-another-lane→hard error, malformed→pre-flock
  hard error. Pinned lanes obey the same ownership/reaping rules.
- `bash -n` + `shellcheck -s bash` clean on `lib/pool.sh`, `install.sh`, `test/*`;
  new selftests green; no orphan processes/dirs after test runs (AGENTS.md §3).
- README/configuration/SKILL/skill-README document both modes (incl. the parallel-scraper
  example), and the section-citation sweep is complete and audited.