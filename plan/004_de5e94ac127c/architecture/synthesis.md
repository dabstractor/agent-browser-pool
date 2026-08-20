# Synthesis — caller-scoped lane selection & lane pinning (delta 004_de5e94ac127c)

Canonical cross-research summary for downstream PRP agents. Sources (all in this directory):
`system_context.md` (lib/pool.sh line-pinned map), `citation_audit.md` (R1 sweep recipe +
authoritative baseline), `test_framework.md` (runners/selftests/landmines), `docs_map.md`
(doc surfaces + insertion points). Line numbers verified against the working tree at HEAD
984f340 (tracked tree clean; only `plan/004_de5e94ac127c/` untracked).

## 1. Verdict: PRD is feasible as specified. Reality corrections below are binding.

| # | PRD claim | Reality (verified) | Action for implementers |
|---|---|---|---|
| V1 | "~73 §2.1[2-9] citations" | **96 occurrences on 92 lines** (73 was line-counts + a `PRD §`-restricted pool.sh pattern; pool.sh alone is 56 occ/55 lines). Per-file occ baseline: pool 56, bin 1, install 2, validate 6, concurrency 4, release_reaper 12, transparency 10, README 5 | Verification totals must be **96/92** and per-file 56/1/2/6/4/12/10/5 — never 73 |
| V2 | sweep files list | Correct 8 files; PRD.md is **already renumbered at HEAD** and human-owned — exclude; docs/ is EMPTY; .agents/ has only §2.7 + internal §2/§3 refs (outside shift range) — exclude | Use exactly the citation_audit §5 recipe (perl, descending, `(?![0-9])` lookahead) |
| V3 | `\b`-style token safety | **Trap:** ONE `§2.16b` attached-letter token (pool.sh:3636) — `\b` silently misses it; lookahead `(?![0-9])` is mandatory (dry-run validated) | Recipe as written; dry-run proved distribution + per-file totals |
| V4 | "~2203 / ~3642 / ~3651" line cites | Exact: `_pool_acquire_critical_section` L2203–L2248 (CHOOSE-N L2234, CLAIM L2240–L2244); fail-fast `if` L3643 (die L3644–L3645); `pool_lease_find_mine` call L3651; `pool_owner_resolve` L516–L614 (TEST MODE fi **L561**, REAL MODE comment L564 — insert between, on blank L562–L563); `pool_config_init` L132–L223 (harness block L203–L213, derived paths from L215); env table comment L112–L131 | Use these pinned anchors |
| V5 | "owner = wrapper's `$PPID`" | Correct and confirmed: `pool_owner_resolve` runs in the wrapper bash process, so `$PPID` there is the invoking orchestrator subprocess. Real mode today starts `local pid="$$"` (L565) | Caller branch: `$PPID` + `/proc/$PPID/{comm,cwd}` + `_pool_owner_starttime "$PPID"` |
| V6 | TEST MODE hook precedence | Confirmed: `AGENT_BROWSER_POOL_OWNER_PID` block L537–L561 wins today; caller branch goes AFTER it (sanctioned — hook keeps highest precedence for simulation) | Insertion point = after L561, before L564 |
| V7 | no pre-existing ABPOOL_OWNER/ABPOOL_LANE | Confirmed zero matches outside plan/004 docs | Names free |
| V8 | "transparency.sh polls message text, not § numbers" | Confirmed: every § citation in test/*.sh is comment-only; `transparency.sh:534` greps `"supported agent harness"` | Renumber cannot change test outcomes; audit still verifies |

## 2. Implementation contracts (the three insertion points)

### 2.1 Config (R2) — `pool_config_init` (L132–L223)
Add a step beside the harnesses block (L203–L213), before derived paths (L215):
- `ABPOOL_OWNER`: any non-empty value → `POOL_OWNER_MODE="caller"`; unset/empty → `"ancestor"`.
  Follow the raw-string precedent (`POOL_PROFILE_DIR` L196–L201), NOT `_pool_config_bool`.
- `ABPOOL_LANE`: unset/empty → `POOL_LANE_PIN=""`. Set → must match `^[1-9][0-9]*$` else
  `pool_die "ABPOOL_LANE must be a positive integer, got: '<val>'"` — mirrors the
  malformed-env die precedents (`_pool_config_require_uint` L74–L75, port_range L192). Hard
  error regardless of verb, BEFORE any flock (§2.20). Note the contrast: the TEST-MODE hook
  malformed PID is warn+ignore (L539–L541) — ABPOOL_LANE deliberately follows the stricter
  config-init precedent per PRD R2.
- Freeze `POOL_LANE_PIN` as the numeric string (not re-read from env later).
- Extend the env-var table comment L112–L131 with both rows.
- **SC2034:** lib/pool.sh is lint-clean today via an in-file `disable=SC2034` at L131
  covering POOL_* globals — new globals `POOL_OWNER_MODE`/`POOL_LANE_PIN` are covered by the
  same mechanism as long as they are `declare -g`'d in the same style; shellcheck must stay
  at ZERO warnings.
- Default-path byte-identity: with both vars unset the only new work is two empty-string
  assignments; no control flow changes.

### 2.2 Caller-mode resolve (R3) — `pool_owner_resolve` (L516–L614)
Branch after TEST MODE `fi` (L561), before REAL MODE (L564):
```bash
if [[ "${POOL_OWNER_MODE:-ancestor}" == "caller" ]]; then
    # owner = the process that invoked us (PRD §2.12, Decision O10)
    validate: /proc/$PPID readable AND $PPID != 1 (reparented/orphan) else
        pool_die "ABPOOL_OWNER=caller: invoking process (ppid $PPID) is gone or reparented; " \
                 "invoke agent-browser-pool as a child of the long-lived orchestrator process"
    POOL_OWNER_PID="$PPID"; declare -g POOL_OWNER_PID
    POOL_OWNER_COMM="$(IFS= read -r ... < /proc/$PPID/comm)";   # cat-with-fallback style as TEST MODE L545
    POOL_OWNER_STARTTIME="$(_pool_owner_starttime "$PPID")"
    POOL_OWNER_CWD="$(readlink /proc/$PPID/cwd 2>/dev/null || true)"
    _pool_log "pool_owner_resolve: CALLER MODE owner pid=$PPID ..."; return 0
fi
```
- No ppid walk, no `POOL_HARNESSES` matching (irrelevant in caller mode).
- Never leaves `POOL_OWNER_PID=0` on the happy path → the wrapper fail-fast (L3643) is
  bypassed **without touching its condition**. It still fires when the parent is dead/
  reparented — via our explicit `pool_die`, which is the desired hard error (§2.15 row).
- Snapshot happens inside `pool_owner_resolve` (runs at step d, before the step-k exec) —
  satisfies the §2.20 "read /proc before any exec" gotcha by construction.
- Everything downstream (`pool_lease_find_mine`, `pool_owner_alive`, `pool_lane_is_stale`,
  reaper, lease writes) consumes the same four globals — zero downstream changes.

### 2.3 Pin acquire path (R4) — wrapper + `_pool_acquire_critical_section`
**(a) `pool_wrapper_main` L3651:** when `POOL_LANE_PIN` is non-empty, SKIP
`pool_lease_find_mine` and call `pool_acquire_locked` directly (the pin branch subsumes
reuse: live-mine → same lane echoed).
**(b) Pinned wrapper must NOT use the exhaustion fallback:** today L3656–L3659 falls into
`pool_wait_for_lane` (block-with-timeout + force-reap) on any acquire failure. For a pin
that is WRONG: live-foreign must hard-error immediately, never wait, never force-reap.
Contract: the pinned path calls `pool_acquire_locked` with NO wait fallback —
`N="$(pool_acquire_locked)" || pool_die "ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see error above)"`.
The critical section prints the detailed diagnostic (lane N, live owner pid, "never a
takeover") to stderr before exiting non-zero; the wrapper's die adds the pin context.
**(c) `_pool_acquire_critical_section` (L2203–L2248), pinned branch — runs under the flock
(L2289, fd 9 on `$POOL_STATE_DIR/acquire.lock`), placed before the reap/adopt scan
(L2213–L2233) so the scan is skipped entirely for pins:**
1. Lease missing AND no `$POOL_EPHEMERAL_ROOT/$N` dir (free) → CLAIM N exactly as today's
   step (d): `pool_lease_write "$N" "$POOL_EPHEMERAL_ROOT/$N" 0 "abpool-$N" $POOL_OWNER_PID
   $POOL_OWNER_COMM ${POOL_OWNER_STARTTIME:-0} ${POOL_OWNER_CWD:-} 0 0 "false"` (provisional
   port=0; boot happens later in the wrapper via port==0 → `pool_boot_lane`, L3665–L3674 —
   unchanged).
2. `pool_lane_is_stale "$N"` rc 0 (stale, tri-state L1178–L1211) →
   `_pool_release_lane_internals "$N"` (reap-if-stale; idempotent, non-fatal) then CLAIM N.
   **No adoption** (deterministic assignment prefers a clean lane — differs from the
   auto-path's REUSE-ORPHAN, deliberately).
3. Lease live + owner is me (`pool_lease_field` owner.pid == POOL_OWNER_PID etc.) →
   `printf '%s\n' "$N"; return 0` (idempotent re-pin, no rewrite).
4. Lease live + foreign → stderr diagnostic + exit non-zero (pool_die or exit 1): name lane
   N, the live owner pid, "never a takeover" (§2.15 row). No block, no force.
5. Caller already holds a live lease on a DIFFERENT lane → hard error (≤1-lane-per-owner
   invariant preserved; PRD silent → hard error is the safe resolution).
   Implementation note: with the wrapper skipping find-mine when pinned, case 5 must be
   detected inside the critical section (e.g. scan leases for a live one owned by
   POOL_OWNER_PID on lane ≠ N — the existing stale-scan loop body is the template).
6. `pool_find_free_lane` must NOT be consulted for pins (it has no bound and would pick a
   different N).
Format validation already happened pre-flock in R2 (§2.20). Ownership/reaping rules apply
in both modes — a pinned lane is still lazily reaped when its owner dies (no reaper change).
Boot/ensure-connected/arg-cleaning/close-scoping untouched.

## 3. Test plan grounding (R5)
- New tests are `selftest_*` in `test/validate.sh` → auto-discovered by `_run_selftest_suite`
  (validate.sh:1178–1196) under the SINGLE process-spawning `setup()` (:204–228). No
  registration. Bodies run in the main shell via `if "$fn"`; every assert ends `|| return 1`.
- Imitate: `selftest_owner_resolves_non_pi_harness` (:351 — own-owner spawn/reap + inline env
  override), `selftest_real_bin_name_or_path` (:871 — temp-HOME config subshells),
  `selftest_preflight_accepts_bare_name_on_path` (:896 — `( … ) || rc=$?` die-asserts),
  `selftest_close_marks_lease_disconnected` (:463 — mocked body.sh in `timeout 15 bash`).
- In-process caller-mode resolve: setup() exports the TEST MODE hook, which outranks caller
  mode → test in a subshell with BOTH hook vars unset:
  `( unset AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME; ABPOOL_OWNER=caller
  pool_owner_resolve; printf '%s\n' "$POOL_OWNER_PID|$POOL_OWNER_COMM|..." )` then assert
  pid == current `$PPID`-of-the-subshell semantics (capture `$PPID` in the same subshell),
  comm matches `/proc/$PPID/comm`, starttime non-empty, != 0.
- Parallel/distinct + death-reap: two `spawn_sim_owner` owners + re-export the hook +
  `pool_owner_resolve` between acquires (the `_test_spawn_owner` pattern,
  release_reaper.sh:155–173); kill+`wait` the owner before staleness asserts (LM-4 zombie
  false-alive). Inter-body lease sweep (:1192) clears lanes between bodies.
- Pin matrix: free→claim; stale→reap-then-claim (old lease gone + new owner); live-foreign →
  subshell rc!=0 + message grep; live-mine → same N, no rewrite; already-holds-other-lane →
  die; malformed `ABPOOL_LANE` (`0`, `-1`, `abc`) → `pool_config_init` dies in subshell.
- **concurrency.sh landmine (LM-1):** it uses the PER-TEST `abpool_run_suite` runner
  (:441) with exactly 2 `test_` bodies — a 3rd would make `setup()`'s 3rd call HANG the
  shared sandbox. The optional real-Chrome E2E therefore REQUIRES first converting
  concurrency.sh to a release_reaper-style single-setup runner (mirror
  `_abpool_run_release_reaper_suite` :440–467 incl. inter-body `release all` + kill
  `ABPOOL_CUR_OWNER` backstop). This conversion is the AGENTS.md-endorsed direction (never
  the reverse). PRD sanctions the Chrome-free unit set as the required coverage; E2E is
  additive.
- Blessed invocations (isolated sandbox + timeout only): `timeout 120 bash test/validate.sh`
  (expect rc 0), `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh`,
  `... 300 ... release_reaper.sh`, `... 180 ... transparency.sh`.

## 4. Documentation plan
Mode A (rides with work): configuration.md env rows (:28–29 insert), caller subsection,
pin subsection + troubleshooting rows (matrix row at :131); SKILL.md orchestrator sub-block
(~:53) + pitfall bullet (:150) + §5 pointer; skill README bullet (:19).
Mode B (final task): root README.md env rows (:272–273), orchestrator `###` under Usage
(~:127), troubleshooting block (~:370), checklist mention, lifecycle step-3 touch-up
(:312–322); citation-sweep audit (totals 96/92, distribution 2.12=0 2.13=10 2.14=2 2.15=24
2.16=25 2.17=5 2.18=3 2.19=16 2.20=11; §2.10=10, §2.11=3 untouched); verify every quoted
`pool_die` text mirrors the implemented strings.
Note: docs/ (root) is empty; configuration.md carries two `PRD §2.7` cites (outside the
shift range — untouched); README:250 already cites §2.12 for "command list" and MUST be
re-pointed by the sweep to §2.13 (CLI) — the sweep handles it mechanically.

## 5. Execution order (dependency spine)
R1 sweep FIRST (it touches all 8 files in place; all later work cites new numbering) →
R2 config → R3 caller resolve → R4 pin path (needs R2's `POOL_LANE_PIN`; wrapper no-fallback
rule §2.3b) → M2 tests (validate.sh selftests; concurrency.sh single-setup conversion before
any E2E) → full validation matrix → M3 README + audit. install.sh: no change (verified — no
new dirs/flags).