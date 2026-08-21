# Validation Report — `agent-browser-pool`

**Date:** 2026-08-20 · **Validator:** automated (`./validate.sh`) + manual code review + live suite runs
**Scope:** `lib/pool.sh` (4,846 lines), `bin/agent-browser-pool`, `install.sh`, `test/{validate,concurrency,release_reaper,transparency}.sh`, `.agents/skills/agent-browser-pool/` docs, README.md — against the PRD provided.

---

## How this was validated

| Phase | What | Result |
|---|---|---|
| P1 Lint | `bash -n` + `shellcheck -s bash` on all 7 shell files | **clean** (0 errors/warnings; only info-level SC1091) |
| P2 Contract | static doc/code consistency probes (defaults, help coverage, dead code, .gitignore) | **8 findings** (see issues 1–5 below) |
| P3 Repo suites | all 4 suites, hard timeouts, leak sweep after each | `validate.sh` selftest **33/33**, `transparency.sh` **10/10**, `release_reaper.sh` **5/5**, `concurrency.sh` **3/3` — but transparency leaked once (issue 3) |
| P4 E2E journeys | 17 hermetic end-to-end journeys with **fake Chrome (real HTTP/CDP server) + fake agent-browser**, temp HOME/state/ephemeral/master, simulated owners via the PRD §2.19 test hooks: zero-prep open, reuse, arg cleaning, close semantics, 2-owner isolation, crash/adopt-or-release, release/reap/doctor, fail-fast, caller-mode parallelism, lane-pin matrix, master hygiene, orphan sweep, install.sh | 86+ checks pass; **1 product regression found** (issue 1) |

Everything ran in isolated sandboxes (temp roots, redirected `AGENT_BROWSER_POOL_STATE`/`AGENT_CHROME_EPHEMERAL_ROOT`/`HOME`), every subprocess under `timeout`, zero leaked processes/dirs left by the validator. The operator's real pool (`lanes/1,3,4`, live Chrome on :53420) was never touched.

---

## Issues found (9)

### 1. MAJOR (functional bug) — Stuck provisional lane permanently blocks a live owner after any fatal mid-boot failure
**Evidence:** deterministically reproduced by `./validate.sh` journey e2e16.
- A live owner's first `open` dies fatally mid-boot via `pool_die` (e.g. master missing/empty → `pool_check_master` inside `pool_copy_master`, or any copy/atomic-write failure). The provisional lease (`port=0`) **survives** because `pool_die` exits without releasing it.
- After the fault is fixed, **every subsequent driving command by that still-live owner fails forever**: `pool_wrapper_main` → `pool_lease_find_mine` → reuse branch (lib/pool.sh:3799) sets `_lane_fresh=""` → the `port==0 → boot` gate (lib/pool.sh:3817–3823) is **skipped on the reuse path** → `pool_ensure_connected` logs `not booted (port='0')` → `pool_die "lane 1 not connected; aborting"`.
- The lane-pin path handles this correctly (it always re-checks `port==0` and boots); only the default reuse path is broken. The owner stays blocked until the harness process exits or an operator runs `release N`/`reap`.
**PRD:** §2.4 step 2 ("Found & valid → reuse" — a port=0 lease is not a booted lane), §2.15 ("fail, drop lane"). 
**Fix direction:** on the reuse path, treat `port<=0` as un-booted (boot it, or release-and-reacquire); optionally make fatal boot paths release the provisional lease before dying.

### 2. MAJOR (doc/code contract) — `AGENT_CHROME_MASTER` default contradicts the PRD, README, SKILL reference, and the tool's own `help`
**Evidence:** static probes `contract:help-vs-code-master-default` and `contract:docs-vs-code-master-default`.
- **Code** (`pool_config_init`, lib/pool.sh:151): default `$HOME/.agent-chrome-profiles/master-profile` — the *old* plan/001 design; the comment even says "NOT the human's personal ~/.config/google-chrome". `XDG_CONFIG_HOME` is never consulted.
- **PRD.md §2.7/§2.11, README.md, `.agents/skills/agent-browser-pool/references/configuration.md`** (which claims to "reflect the shipped behavior in lib/pool.sh"), **and the built-in `agent-browser-pool help`** (lib/pool.sh:4834) all document `${XDG_CONFIG_HOME:-~/.config}/google-chrome`.
**Consequence:** on a fresh install configured per the docs, `doctor` fails `[master]` and every acquire dies "source profile missing or empty" even though the user's real Chrome exists; on hosts where the legacy master-profile happens to exist, agents silently clone a *stale* identity instead of the current one the docs promise. The `help` text and the code disagree *within the same file*.
**Fix direction:** pick one default (PRD says real Chrome user-data-dir) and align code + help + `pool_check_master`'s message + all docs.

### 3. MAJOR (intermittent leak) — `test/transparency.sh` can leave a live Chrome process tree + orphan ephemeral dir in `$HOME` after a PASSING run
**Evidence:** observed live on this host during validation (10/10 PASS, then found: main Chrome pgid 521860 + zygote/renderer/crashpad children running under `--user-data-dir=/home/dustin/abpool-test-eph.hQfmdw/1`, dir still present; required manual kill + rm). Did not reproduce in 2 subsequent runs — timing-dependent.
**Root cause (two compounding parts):**
- *Pool race:* `pool_chrome_launch` persists `chrome_pid/pgid` into the lease only after launch returns (`_pool_boot_write_chrome_ids`), so a driving wrapper killed inside that window leaves a lease with `chrome_pid=0` → `pool_release_lane` → `pool_chrome_kill 0 0` is a **no-op** → `rm -rf` removes the dir but Chrome recreates its user-data-dir and keeps running with no lease.
- *Test-infra gap:* the suite's inter-body backstop runs only `release all` (lease-driven). Orphan chrome+dir cleanup exists — `pool_reap_orphan_dirs` (pgrep/pkill by `user-data-dir=...`) — but only `reap` invokes it, and the backstop never calls `reap`.
**PRD:** Goal 4 (cleanup on crash) / AGENTS.md §3 (never leak processes — the exact accumulation failure this repo exists to prevent).
**Fix direction:** add `reap` to the suite's inter-body/final cleanup; optionally make `_pool_release_lane_internals` fall back to a `pgrep -f "user-data-dir=$ephemeral_dir"` kill when lease chrome ids are 0/untrusted (mirroring `pool_reap_orphan_dirs`).

### 4. MINOR (docs) — `agent-browser-pool help` env reference is missing 4 shipped variables
`ABPOOL_OWNER`, `ABPOOL_LANE`, `AGENT_BROWSER_POOL_HARNESSES`, `AGENT_CHROME_PROFILE` are absent from the help text (they *are* in README + `references/configuration.md`). PRD §2.12 explicitly requires the new modes to be documented everywhere agents look; the built-in help is the first place they look.

### 5. MINOR (dead code) — `pool_check_btrfs` is defined but never called
lib/pool.sh:286. The non-btrfs refusal still happens de facto via `cp --reflink=always` failure in `pool_copy_master` (plus doctor's own probe), so PRD §2.15 behavior is preserved — but the function is dead and its comments call it "the acquire-INIT gate", which is misleading. Wire it into acquire or delete it.

### 6. MINOR (spec deviation) — PRD §2.9 exhaustion semantics are unreachable; port exhaustion fails hard with no block/alert
Lanes are unbounded (PRD §1.3 Goal 5), so `pool_acquire_locked` never fails and `pool_wait_for_lane`'s block → force-reap-oldest-stale → `notify-send`/`alerts.log` path is effectively dead code. The genuinely exhaustible resource is the TCP port range: `pool_find_free_port` rc=1 → `pool_boot_lane` releases the lane → the wrapper `pool_die`s "boot failed" **immediately** — no 600 s block, no alert. SKILL.md's "slow-then-connects = exhaustion self-heal after `AGENT_BROWSER_POOL_WAIT`" guidance therefore describes behavior that cannot occur.

### 7. MINOR (race/invariant) — default acquire path doesn't enforce one-lane-per-owner inside the flock
`pool_wrapper_main` enforces "one owner ≤ 1 lane" only via `pool_lease_find_mine` *before* the lock (PRD §2.4 step 2). Two concurrent driving commands from the same harness can both miss and each claim a lane. The **pin** path added an in-lock guard (`already holds live lane … one-lane-per-owner invariant`, lib/pool.sh:2294) — the default path has none. Cross-agent isolation is unaffected (same owner), so severity is Minor; it self-heals only when the owner exits.

### 8. LOW (spec deviation) — CDP readiness budget is 30 s/attempt, not the documented 15 s
`pool_wait_cdp` uses `POOL_CDP_TRIES=60 × 0.5 s` (lib/pool.sh:1835); PRD §2.4 step 3h specifies ≤30×0.5 s (=15 s) and §2.15 says 15 s. With the retry ladder (same-port retry + re-picked port) a bad boot can consume ~90 s before failing. Harmless, but diverges from both PRD numbers.

### 9. LOW (robustness observation, currently per-spec) — `pool_ensure_connected`'s relaunch path never re-picks a port
If a foreign process squats the lane's recorded port, the relaunch binds nothing, `wait_cdp` burns the full budget, and the command fails — whereas fresh boots re-pick via `_pool_launch_and_verify`. PRD §2.15 says "relaunch on same dir+port", so this is technically per-spec; flagged for either a PRD clarification or a port re-pick on bind failure.

---

## What passed (confidence in the core)

- All lint/static checks clean; all 4 repo suites green (33+10+5+3).
- E2E (hermetic, fake binaries): zero-prep acquire → correct Chrome flags (windowed, anti-throttle set, absolute paths, `--profile-directory` derivation), port allocation in range, per-lane chrome logs; **same-lane reuse across stateless calls without re-copy/relaunch**; full arg-cleaning contract (`--session`/`--session=` stripped, `AGENT_BROWSER_SESSION=abpool-<N>` forced, `connect <port|url>` dropped, bare `connect` no-op success); `close`/`close --all` disconnect-only with lane+profile survival and clean rebind; **two owners → distinct lanes/ports**; dead-owner lane **adopted with the same Chrome pid** (REUSE-ORPHAN) and fully reaped (chrome killed, dir+lease gone) when not adoptable; `release N`/`release all`/`reap`/`doctor` operator journeys incl. orphan-dir detection; no-harness fail-fast; caller-mode parallel subprocesses → distinct lanes, auto-reaped after exit; lane-pin matrix (free adopt, live-foreign hard error "never a takeover", second-lane guard, malformed value dies at startup); master read-only + `Singleton*` stripped from copies; `install.sh` symlink + state-dir bootstrap; zero leaked processes/dirs after every run.

## Residual risks / notes

- Issue 3's leak is timing-dependent; the validator now sweeps for it automatically after each suite (and would flag it as a failure).
- The PRD/tasks in `plan/` are human/orchestrator-owned and were treated read-only; `PRD.md` still lists "Tasks: " empty at the end (cosmetic).
- The real suites boot real headless Chrome from the real master profile on this host; the validator's own E2E phase never launches real Chrome.

**Verdict:** `validation_result.json` → `hasIssues: true`, `issueCount: 9`.