# Validation Report — agent-browser-pool @ HEAD `6fdbd82`

**Date:** 2026-08-20/21 · **Validator:** `./validate.sh` (this repo root) + manual probes
**Scope:** Verification of the 6 PRD-required bug fixes (BUG-001..006, fix commits `8ad9fc5..6fdbd82`) plus novel adversarial validation of the fixed code. Everything ran in isolated sandboxes (temp `HOME`/state/ephemeral/master under a btrfs `mktemp -d` tree, fake chrome + fake agent-browser for the hermetic phases), every subprocess under `timeout`, zero leaked processes/dirs (verified after every suite and at exit).

> Note: a concurrent sibling agent was observed writing PRPs under `plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/` (P1M3T1S1, P1M3T2S1, `tasks.json`) during this validation. Those files are not mine and were not touched. The validated source tree (`lib/pool.sh`, `bin/`, `install.sh`, `test/*`, `plan/004_de5e94ac127c/validate.sh`) is clean at HEAD `6fdbd82`.

---

## How this was validated

| Phase | What | Result |
|---|---|---|
| P1 Lint | `bash -n` + `shellcheck -s bash` on all 9 shell files (incl. the new `test/bootrace.sh` and the committed artifact) | **clean** |
| P2 Contract | static markers for each PRD fix (BUG-001 guard, BUG-002 boot lock + dead-pid gate, BUG-003 reclaim seams, BUG-004 doctor pre-create, BUG-005 help text, BUG-006 ROOT) | **6/6 present** |
| P3 Suites | `test/bootrace.sh` **10/10**, `test/validate.sh` **33/33**, committed artifact `plan/004_de5e94ac127c/validate.sh --fast` run **from a foreign CWD** → **87/88 (1 fail — issue 2 below)**. Real-Chrome suites run manually earlier this session: `transparency.sh` **10/10**, `release_reaper.sh` **5/5**, `concurrency.sh` **3/3**, all with zero leak sweeps (also available via `./validate.sh --full`) | green except artifact |
| P4 E2E | 14 hermetic journeys with fake chrome (real HTTP CDP server) + fake agent-browser: per-bug regression repros (all six PRD bugs), 2-way/3-way same-owner mid-boot races, pre-port (mid-copy) race, **>20s boot-lock window**, pin-over-corrupt-lease, doctor fresh-install, help contract, caller-mode lane counting with `.boot.lock` fallout, two-owner parallel boot, final leak sweep | **12/14 green; 2 failures = the new bugs below** |

`./validate.sh` summary: **passed: 41 failed: 2** (the 2 product failures below; the artifact failure is counted under P3).

---

## Verification of the PRD-required fixes

| PRD bug | Status | Evidence |
|---|---|---|
| BUG-001 master-copy nesting on re-boot | **FIXED** | `pool_copy_master` now `rm -rf`s any pre-existing target (lib/pool.sh:1340-1355); bootrace R1/R2 + my e01/e02 green on btrfs (trusted marker at lane top level, no `<master>/` nesting, stale junk gone) |
| BUG-002 concurrent same-owner boot race (double launch, clobbered ids, leak) | **FIXED for boots ≤20s; residual defect in the >20s window → issue 1 (BUG-007)** | per-lane boot lock + in-lock re-check + dead-pid gate + widened (3b) sweep are all present and work: bootrace R3/R3-neg/R4 + my e03 (2-way), e04 (3-way), e05 (pre-port) all green — 1 launch, no spurious fail, lease pid live, no leaks |
| BUG-003 corrupt lease uncleanable | **FIXED** | `reap` removes dir + corrupt `lanes/N.json` and frees the lane number (e07); `release N` clears corrupt leases with cmdline sweep (bootrace R6 both variants, my e08) |
| BUG-004 doctor false-FAIL on fresh install | **FIXED** | doctor `mkdir -p`s the ephemeral root before the `findmnt -T` probe; missing root → `OK (btrfs)` + rc 0 (e10); true non-btrfs still WARNs/FAILs (bootrace R7 v2/v3) |
| BUG-005 help misdocuments HARNESSES as append | **FIXED** | help says "replaces the default pi,claude,codex,agy,antigravity; empty/unset -> default"; runtime probe confirms replace semantics + 5-harness default (e11) |
| BUG-006 committed artifact path-broken | **PARTIALLY FIXED** | ROOT now resolves the repo root — all 88 checks execute from any CWD (no rc-127 path errors). But the artifact is **not green as shipped**: 1/88 fails (issue 2 / BUG-008) |

---

## Issues found (3)

### 1. MAJOR — `pool_boot_lane`'s 20s lock-timeout fallback is dead code: false `rc 0`, 40s stall, then the same spurious failure BUG-002 targeted
**ID:** BUG-007 · **Location:** `lib/pool.sh:2700-2716` (`pool_boot_lane`); interacts with `pool_wrapper_main` step h and `_pool_ensure_connected_locked` port=0 path.

In `pool_boot_lane`:

```bash
if ( flock -w 20 8 || exit 99; _pool_boot_lane_locked "$lane" ) 8>"$(pool_lane_boot_lock "$lane")"; then
    return 0
fi
lock_rc=$?          # ← always 0 here: a false `if…fi` with no else returns the
                    #   IF-statement's status, not the subshell's exit 99
if (( lock_rc == 99 )); then   # never true → documented fallback never runs
    _pool_log "pool_boot_lane: boot lock busy >20s ...; proceeding unlocked"
    ...
return "$lock_rc"   # returns 0 — false success while the lane is still port=0
```

Verified by `bash -x` trace (flock fires `exit 99` at exactly +20.0s, next line is `lock_rc=0`) and deterministic repro (check `e06`). Consequences when a same-owner second command races a peer boot that holds the lane's boot lock longer than 20s:

1. `pool_boot_lane` skips the documented "proceed unlocked" fallback entirely (dead code — the `pool_boot_lane: boot lock busy` log line never fires; verified `busy_boot_log=0`).
2. It returns a **false success** (`rc 0`) with the lane still un-booted (`port=0`).
3. The wrapper proceeds to `pool_ensure_connected`, whose *own* `flock -w 20` then blocks another 20s, times out, runs unlocked, reads `port=0` → "not booted" → the second command dies `lane N not connected; aborting` after a ~40s stall — the exact spurious-failure symptom the BUG-002 fix was required to eliminate (PRD §2.16 "same browser for all my commands across many stateless bash calls"), now narrowed to the >20s-boot window.

Reachability of a >20s boot lock hold: (a) non-btrfs hosts with `AGENT_CHROME_ALLOW_SLOW_COPY=1` — a real multi-GB copy takes minutes, so *every* first acquire with parallel tool calls hits this; (b) any host (incl. default btrfs) where Chrome is slow to open CDP — `pool_wait_cdp`'s budget is 15s×2 attempts (re-pick retry) inside the lock, so a wedged/slow Chrome holds the boot lock ~30s+. No double launch or leak occurs (the dead fallback accidentally prevents the worse unlocked double-boot), and the first command still succeeds — but the second command's failure is spurious, the rc contract is a lie, and the shipped fallback is unreachable code.

**Repro:** `bash validate.sh` check `e06` (FAKE_CP_DELAY=45, second command at +1.2s): `rc_b=1 after 41s`, `rc_a=0`, `launches=1`, `busy_boot_log=0`. Control `e06ctl` (15s copy) passes. Direct trace evidence in the report appendix of the session log (`flock -w 20 8` → `exit 99` → `lock_rc=0` → `return 0`).

**Fix direction:** capture the subshell status without the if-statement swallow, e.g. mirror `pool_ensure_connected`'s explicit `elif/else` structure (`lock_rc=99` in the else branch), or `local rc=0; ( … ) || rc=$?` with the timeout signal set inside the subshell; then the existing fallback + a re-check runs as documented. Add a regression case to `test/bootrace.sh` with `FAKE_CP_DELAY` > 20 asserting the fallback fires and the second command re-checks instead of dying.

### 2. MINOR — the committed validation artifact is still red as shipped: its e2e12 counts the fix's own new `N.boot.lock` files as lanes (87/88)
**ID:** BUG-008 · **Location:** `plan/004_de5e94ac127c/validate.sh:475` (`ls "$V_STATE/lanes" | wc -l`); regression introduced by the fix commit that added `pool_lane_boot_lock` files into `lanes/`.

BUG-006 required the committed artifact to "run green as shipped". The ROOT fix works — invoked per its usage (`bash plan/004_de5e94ac127c/validate.sh --fast` from the repo root) and even from a foreign CWD, all 88 checks now execute (no rc-127 path errors). But the BUG-002 fix's per-lane boot locks are created as `lanes/<N>.boot.lock` in the same directory the artifact's e2e12 counts with a bare `ls`: after its two caller-mode children boot lanes 1 and 2, the dir holds `1.json 2.json 1.boot.lock 2.boot.lock` → `lanes_live=4 (want 2)` → **`passed: 87 failed: 1`** deterministically at HEAD (reproduced twice, plus an isolated micro-repro showing exactly 2 healthy leases + 2 launches + 4 `ls` entries). The product itself is unaffected — `pool_lanes_list` globs `*.json`, `pool_find_free_lane` tests `<N>.json`, and the design note explicitly documents `*.boot.lock` invisibility (my e12 confirms `status` shows exactly the 2 real lanes).

Secondary gap in the same artifact: its P1 lint list and P3 suite list do not include `test/bootrace.sh` (the fix's own regression suite), so the recorded validator never lints or runs the new regressions it was built to protect.

**Fix direction:** count leases with `find … -name '*.json' | wc -l` (or a `*.json` glob) in e2e12; add `test/bootrace.sh` to the artifact's lint + P3 lists; re-run the artifact from the repo root and from a foreign CWD and record a green 88/88.

### 3. MINOR — pin-acquire over a corrupt lease rm -rf's the lane dir without the cmdline sweep the new corrupt-lease paths perform → live Chrome survives on a deleted user-data-dir
**ID:** BUG-009 · **Location:** `lib/pool.sh:2381-2387` (`_pool_acquire_critical_section` pin path, `pool_lane_is_stale` rc-2 branch); contrast `pool_admin_release` corrupt branch (lib/pool.sh:4693-4715) and `pool_reap_orphan_dirs` (lib/pool.sh:3439-3442).

The BUG-003 fix taught `release N` and `reap` to treat a present-but-corrupt `lanes/N.json` as reclaimable and to run the anchored `user-data-dir=$dir( |$)` cmdline sweep before `rm -rf`. The **pin** path's rc-2 (no-lease/corrupt-lease) branch takes the same "no lease" interpretation but removes the dir with **no sweep and no kill**: `ABPOOL_LANE=N` over a corrupt lease whose dir still has a live Chrome (the exact state BUG-003 models: corrupt lease + orphan Chrome) leaves that Chrome running on deleted inodes while a fresh copy + new Chrome boot on the same lane number. Verified (check `e09`, twice): a pattern-matching live process survives the pin boot; the rogue is only reclaimed later if lane N is released/reaped, and its port stays occupied meanwhile. Defense-in-depth inconsistency rather than a likely field failure (a corrupt lease with a live Chrome requires external interference/FS-level corruption while Chrome lives — power loss kills the Chrome too), but it is the same leak class the changeset set out to close, one seam away from the two it fixed.

**Fix direction:** in the pin path's rc-2 branch, run the same anchored pgrep/pkill sweep + prefix-guarded `rm -rf` as `pool_admin_release`'s corrupt branch before claiming/booting (or route through a shared helper); add a bootrace-style case with a corrupt lease + live marker process asserting zero survivors.

---

## Testing summary

- **Total bugs found: 3** (1 major, 2 minor) — all new, introduced by or adjacent to the fix commits; none of the 6 PRD bugs remain unfixed (4 fully fixed, BUG-002/BUG-006 fixed with the residuals above re-filed as BUG-007/BUG-008).
- Static: `bash -n` + `shellcheck` clean on all 9 shell files.
- Suites: bootrace 10/10, validate selftest 33/33, transparency 10/10, release_reaper 5/5, concurrency 3/3 — all zero-leak.
- Hermetic E2E: 41 checks green / 2 red (the 2 product bugs), including deterministic repros for every PRD bug and both new bugs.
- Real Chrome (this session, manual runs of the three real-Chrome suites in their own isolated frameworks): green, zero leftovers. The operator's real pool state, master profile, and running Chrome were never touched.

## Recommendations

1. Fix `pool_boot_lane`'s rc capture (BUG-007) and add a >20s-boot regression to `test/bootrace.sh`; consider whether the unlocked fallback should instead re-check-and-fail-soft (the unlocked double-boot path it would restore carries its own hazards — with the re-check as the guard).
2. Fix the artifact's e2e12 lease counting and wire `test/bootrace.sh` into its lint + P3 lists; re-record a green run (BUG-008).
3. Add the cmdline sweep to the pin path's corrupt-lease branch (BUG-009), ideally by sharing the sweep helper with `release`/`reap`.