# PRP — P4.M2.T2.S2: Caller-mode two-child E2E (real CLI + real Chrome)

## Goal

**Feature Goal**: Add a third test body to `test/concurrency.sh` —
`test_caller_mode_children_get_distinct_lanes` — that proves PRD §2.12 / O10 with REAL
subprocesses: two child `bash` processes, each invoking the REAL CLI
(`bin/agent-browser-pool`) with `ABPOOL_OWNER=caller`, each landing on a DISTINCT lane
whose `owner.pid` equals that child's pid, and both lanes going stale + fully reaped
(`release all` / `pool_reap_stale`) once the children exit.

**Deliverable**: One new `test_` function in `test/concurrency.sh` (plus any tiny helper
it needs). No other files. This rides on the single-setup runner delivered by
P4.M2.T2.S1 (see `plan/004_de5e94ac127c/P4M2T2S1/PRP.md` — treat as contract:
`_abpool_run_concurrency_suite` will exist, bodies run via `if "$fn"` in the MAIN shell,
inter-body backstop does `release all` + kill/waits `ABPOOL_CUR_OWNERS`).

**Success Definition**:
- `bash -n` + `shellcheck -s bash test/concurrency.sh` clean.
- Isolated-sandbox run: `AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh`
  → **3 passed, 0 failed**, rc 0.
- Zero orphaned chrome/sleep/agent-browser/abpool processes and zero leftover temp dirs
  after the run (AGENTS.md §3/§6).
- NOTE (PRD R5): this E2E is OPTIONAL-but-sanctioned confidence on top of the required
  unit coverage (P4.M2.T1). If a host/environment blocker arises (no Chrome, no btrfs,
  no real agent-browser), prefer skipping this item over wedging the sandbox — but given
  the suite's existing real-Chrome bodies already run on this host, it should work.

## Why

- P4.M2.T1.S3 proved caller-mode distinct lanes using the IN-PROCESS owner-override
  hooks (`AGENT_BROWSER_POOL_OWNER_PID`). This item proves the REAL end-to-end path:
  `ABPOOL_OWNER=caller` → `pool_owner_resolve` keys on the CLI's `$PPID` (lib/pool.sh:588)
  → lease `owner.pid` == the actual orchestrating subprocess pid → lane reaped when that
  subprocess dies (lazy reaper, §2.10). That is exactly the PRD §2.12 "parallel scrapers"
  usage pattern (§2.19 testing bullet: "via the owner-override hooks **or real
  subprocesses**").
- The single-setup conversion (S1) exists precisely so a 3rd body is safe.

## What

New body `test_caller_mode_children_get_distinct_lanes` in `test/concurrency.sh`:

1. Call `_concurrency_setup_master` (real master / btrfs ephemeral root / real
   agent-browser binary / `pool_config_init` re-run) — same as body 1.
2. Launch TWO child processes:
   ```bash
   child_pid_i="$(  # pseudo: capture pid of the child bash
       bash -c '
         ABPOOL_OWNER=caller agent-browser-pool open about:blank
         sleep 30   # stay alive so the parent can assert "lane held while caller lives"
       ' &
   )"
   ```
   - Launch as `bash -c '…' &` from the MAIN-shell body (children of the main shell →
     they MUST be killed + `wait`ed before the body returns — LM-4).
   - Wrap the WHOLE child in `timeout 60` — i.e.
     `timeout 60 bash -c '…' &` — so `open` (whose underlying agent-browser may not
     exit promptly) and the `sleep` are both hard-bounded (AGENTS.md §2). `timeout` is
     the OUTER parent; the inner bash exec's nothing, so the CLI's `$PPID` is the inner
     bash — which is the "orchestrator subprocess" identity we want. Do NOT put the
     `ABPOOL_OWNER=caller exec agent-browser-pool …` form from the item description
     literally (`exec` would end the child the moment `open` returns, before we can
     assert the held lane); the `… ; sleep 30` (no exec) form satisfies the same
     contract ("the CLI's $PPID IS that child") and keeps the child alive.
   - Invoke the CLI by ABSOLUTE repo path: `"$CONCURRENCY_DIR/../bin/agent-browser-pool"`
     (never rely on PATH). Environment: children inherit the main shell's exports
     (redirected HOME/state from `setup()`, `_concurrency_setup_master` overrides:
     `AGENT_CHROME_MASTER`, `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_BROWSER_REAL`, plus
     `AGENT_CHROME_HEADLESS=1` already exported for the run). `ABPOOL_OWNER=caller` is
     set INSIDE the child's bash (subshell-scoped) so the main shell is unaffected.
   - Record each inner-bash pid: since `timeout` forks the bash, capture the bash pid by
     having the child write its own `$$` to a file first:
     `bash -c 'printf "%s\n" $$ > "$1/self-'"$i"'.pid"; …' _ "$results_dir"` — or
     simpler: `bash -c 'printf "%s\n" $$ >'"$results_dir"'/child-'"$i"'.pid"; ABPOOL_OWNER=caller "$0" open about:blank || true; sleep 30' "$CLI"`.
     Use whichever you find clearest; the requirement is: know each child's pid.
     (Alternative: `setsid` not needed; plain `&` is fine — these are main-shell
     children and kill+wait works.)
3. Wait-with-deadline for BOTH leases to appear (Chrome boot takes seconds; poll, never
   block indefinitely):
   ```bash
   local deadline=$(( SECONDS + 90 )) got=0
   while (( SECONDS < deadline )); do
       # find lanes whose owner.pid == child pid; count them
       mapfile -t held < <(pool_lanes_list)
       got=0
       for ln in "${held[@]:-}"; do
           fpid="$(pool_lease_field "$ln" owner.pid 2>/dev/null)" || fpid=""
           [[ "$fpid" == "$child1" || "$fpid" == "$child2" ]] && got=$((got+1))
       done
       (( got >= 2 )) && break
       sleep 1
   done
   assert_eq "2" "$got" "both children hold leases" || { <cleanup>; return 1; }
   ```
4. While both children are alive, assert:
   - exactly two lanes whose `owner.pid` ∈ {child1, child2};
   - the two lane numbers are DISTINCT (`_assert_all_distinct_and_nonzero`);
   - both `port` values distinct + nonzero (real boots, not provisional).
5. Kill both children (simulating orchestrator-subprocess exit), then `wait` them
   (zombie reap — LM-4). Optionally `_pool_get_starttime` guard not needed.
6. Assert both lanes are now STALE: `pool_lane_is_stale "$ln"` returns 0 for each
   (owner pid dead). Then run the reaper — as a SUBPROCESS like the other bodies'
   cleanup (`"$ABPOOL_ADMIN" reap` or `release all`; prefer `release all` for
   determinism, then `reap` as belt-and-suspenders, both `|| true`-guarded in the
   cleanup path) — and assert `assert_lane_gone` for both lane numbers ×2 plus
   `assert_no_chrome`.
7. Reap the btrfs ephemeral root exactly like body 1's step (9b):
   `[[ -n "${_concurrency_btrfs_root:-}" ]] && rm -rf -- "$_concurrency_btrfs_root" 2>/dev/null || true`
   (plus kill+wait any children if we bailed early).
8. On ANY early `return 1` (assert failure) BEFORE the kill step, the body MUST still
   kill+wait both children (guarded `|| true`) so no `timeout 60 bash`/sleep lingers —
   implement via a small local `_caller_e2e_cleanup` invoked before each early
   `return 1`, or structure the body so asserts happen after children are already dead
   (preferred: keep the kill+wait immediately after the "held" assertions pass; for the
   pre-kill failure paths do kill+wait then return).

Also: register nothing in `ABPOOL_CUR_OWNERS` (these children are real `bash`, not
`spawn_sim_owner` sim-owners) — S1's backstop can't know them; the body owns their
reaping. Keep the file-header comment accurate (mention the caller-mode E2E body).

### Success Criteria

- [ ] New body passes alongside the two existing bodies (3 passed, 0 failed).
- [ ] Distinct-lane + owner.pid==child-pid + stale-after-exit + full-teardown assertions
      all present and meaningful.
- [ ] No orphans / leftover dirs after the suite.

## All Needed Context

### Context Completeness Check

An agent new to this repo needs: the caller-mode semantics in lib/pool.sh, the child
launch geometry (who is `$PPID` of the CLI), the hermetic scaffolding already provided
by setup + `_concurrency_setup_master`, and the S1 runner contract. All pinned below.

### Documentation & References

```yaml
- file: plan/004_de5e94ac127c/P4M2T2S1/PRP.md
  why: CONTRACT for the runner this body runs under (single setup, main-shell bodies,
    ABPOOL_CUR_OWNERS backstop, kill+wait helpers). Assume landed.
- file: lib/pool.sh:580–600 (pool_owner_resolve caller branch)
  why: caller mode keys on $PPID of the CLI process; pool_die if parent dead. The child
    bash IS the CLI's parent → lease owner.pid == child bash pid.
  gotcha: caller mode reads /proc/$PPID — if the parent died before resolve, driving
    fails; our children run `open` immediately, so fine.
- file: lib/pool.sh:218–230 (POOL_OWNER_MODE / POOL_LANE_PIN config)
  why: ABPOOL_OWNER=caller semantics (any value).
- file: test/concurrency.sh
  why: the file to modify. Reuse: _concurrency_setup_master (:77+), _concurrency_run_one_lane
    pattern notes (why direct lib calls were needed there — NOT applicable here: this test
    intentionally goes through the REAL CLI and bounds it with `timeout 60`), body 1's
    assert helpers (_assert_all_distinct_and_nonzero), steps (7)-(9b) as the assertion +
    cleanup template.
  gotcha: header comment explains why CLI-level `open` was avoided before (exec → may not
    exit → wait hangs). THIS body resolves it with `timeout 60`; note that in a comment.
- file: test/validate.sh:128–160 (spawn_sim_owner), :200–215 (setup env overrides)
  why: NOT used for the children (real bash, not sim owners), but shows the isolation env
    (HOME/AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT) children inherit.
  gotcha: setup() exports the temp HOME — the real agent-browser CLI in the child derives
    its daemon paths from env, so inheritance is what makes this hermetic.
- file: plan/004_de5e94ac127c/architecture/test_framework.md (§13 LM-1..LM-8)
  why: landmines. LM-2 (no runner subshells — S1 handles), LM-4 (kill+wait the children
    you spawn), LM-5 (guard rc-1 calls: pool_lease_field, pool_lanes_list under set -e),
    LM-8 (don't bypass the real master/binary overrides).
- file: AGENTS.md §1–§3, §6
  why: timeout-wrap everything, isolated sandbox only, reap everything, zero orphans.
- doc: PRD §2.12 (selected above) — the contract being E2E-proven; §2.19 caller-scoped
    bullets ("or real subprocesses", "lane reaped after its death").
```

### Current Codebase tree (relevant)

```bash
test/concurrency.sh   # ★ modify: + test_caller_mode_children_get_distinct_lanes (place
                      #   BEFORE the runner fn / gate; any position among test_ fns works —
                      #   compgen|sort enumerates: caller_mode… sorts FIRST alphabetically,
                      #   so it will run before the n_agents bodies — fine either way)
test/validate.sh      # framework — DO NOT MODIFY
test/release_reaper.sh# reference only
lib/pool.sh, bin/agent-browser-pool  # SUT — read only
```

### Known Gotchas of our codebase & Library Quirks

- **G1 — CLI `open` may not exit** (the whole reason body 1 avoided the CLI): the wrapper
  `exec`s into the real agent-browser. Bound the entire child with `timeout 60` and do
  NOT `exec` inside the child's bash; append a bounded `sleep 30` so the "caller alive"
  window is deterministic. Never bare-`wait` without a deadline.
- **G2 — capture the CHILD's pid, not `timeout`'s**: launching `timeout 60 bash -c '…' &`
  gives `$!` = timeout's pid. Have the inner bash write its own `$$` to a results file
  before invoking the CLI; read it back in the parent (with a short retry loop — file
  appears within milliseconds).
- **G3 — kill + `wait` both children** (LM-4): plain `kill` leaves zombies; `wait
  "$pid" 2>/dev/null || true`. Killing the timeout wrapper (`$!`) with default TERM
  propagates to the child; safest is to kill the process GROUP if you launched with
  setsid, else kill BOTH `$!` and the inner pid, then wait both. Prefer
  `kill "$bgpid" "$child_pid" 2>/dev/null || true` then wait each.
- **G4 — hermetic env is inherited, don't re-export**: children launched with plain `&`
  from the body inherit setup's + `_concurrency_setup_master`'s exports. Only
  `ABPOOL_OWNER=caller` is set inside the child (subshell-scoped). Use the ABSOLUTE CLI
  path `"$CONCURRENCY_DIR/../bin/agent-browser-pool"`; `$ABPOOL_ADMIN` is the admin
  wrapper if defined in validate.sh — check before reusing (it exists; other bodies use
  `"$ABPOOL_ADMIN" release all`).
- **G5 — set -e guards** (LM-5): `pool_lease_field`, `pool_lanes_list`, `pool_lane_is_stale`
  can return 1; use `$( … 2>/dev/null) || var=""` and `if pool_lane_is_stale …` forms.
  `(( got >= 2 )) && break` is errexit-safe in `&&` position but as a bare statement with
  result 0-value would abort — keep it in a condition context.
- **G6 — S1's backstop does NOT reap your children**: they're not in `ABPOOL_CUR_OWNERS`
  and are real bashes. The body itself must guarantee kill+wait on every exit path
  (including early assert-fail returns) — use a local cleanup helper invoked before every
  early `return 1`.
- **G7 — btrfs root reuse**: `_concurrency_setup_master` reaps stale roots and creates a
  fresh one; as body 1's step (9b), delete `$_concurrency_btrfs_root` at body end. With
  S1's single setup the main-shell trap still can't see it, so keep the explicit reap.
- **G8 — don't touch the other bodies or the runner** (S1's contract). Purely additive.

## Implementation Blueprint

### Implementation Tasks (ordered)

```yaml
Task 1: ADD local helper _caller_e2e_cleanup (near _concurrency_run_one_lane)
  - INPUT: bg pids array ref or "pid…" args; kills each (|| true) + waits each (|| true).
  - Reuse S1's _concurrency_kill_owner_and_reap_zombie if it landed; else inline.

Task 2: ADD test_caller_mode_children_get_distinct_lanes (after test_1, before runner)
  - STRUCTURE: as the "What" section steps 1–8; mirror body 1's comment density (explain
    WHY timeout-wrapped CLI calls are now safe vs the header's old rationale).
  - PLACEMENT: between the existing bodies and the S1 runner fn — any spot among bodies.
  - NAMING: test_ prefix (runner enumerates via compgen|grep '^test_'|sort).

Task 3: UPDATE the file-header comment
  - One or two lines: "Body 3 (caller-mode E2E) drives the REAL CLI with timeout-bounded
    children — see its own comment for why that's safe here."

Task 4: VALIDATE per the loop below.
```

### Implementation Patterns & Key Detail (child launch)

```bash
local cli="$CONCURRENCY_DIR/../bin/agent-browser-pool" results_dir="$ABPOOL_TEST_ROOT/caller-e2e"
mkdir -p -- "$results_dir"
local -a bg=()
for (( i = 0; i < 2; i++ )); do
    timeout 60 bash -c '
        printf "%s\n" "$$" >"'"$results_dir"'/child-'"$i"'.pid"
        export ABPOOL_OWNER=caller
        "$0" open about:blank >/dev/null 2>&1 || true   # lane acquire+boot happens here
        sleep 30                                          # stay alive = lane legitimately held
    ' "$cli" &
    bg+=("$!")
done
# read child pids back (retry ~10×0.1s), then poll leases with deadline as in What/step 3.
```

## Validation Loop

### Level 1: Static (always safe)

```bash
bash -n test/concurrency.sh
shellcheck -s bash test/concurrency.sh
grep -c '^    setup$' test/concurrency.sh   # still 1 (S1 preserved)
```

### Level 2: Isolated-sandbox live run (REQUIRED)

```bash
AGENT_CHROME_HEADLESS=1 timeout 240 bash test/concurrency.sh
# Expect: 3 bodies, "3 passed, 0 failed", rc 0 (caller_mode body runs first alphabetically).
```

### Level 3: Orphan / leak audit (same sandbox, immediately after)

```bash
pgrep -af 'chrome|abpool-pi|sleep 30|sleep 600|agent-browser' || echo "no orphans"
ls -d /tmp/abpool-test.* /tmp/abpool-pi.* "$HOME"/.cache/abpool-test-ephemeral/ephemeral.* 2>/dev/null \
  || echo "no leftover temp dirs"
```

### Level 4: If the body is persistently flaky

The PRD marks this E2E optional. If a genuine environment blocker appears (not a code
bug), report it — do not weaken the isolation or remove timeouts to force a pass.

## Final Validation Checklist

- [ ] Static checks clean; exactly one `setup` call; no `abpool_run_suite`/`run_test` refs
- [ ] 3 passed / 0 failed in the isolated sandbox, inside timeout 240
- [ ] Body asserts: 2 distinct lanes, owner.pid == each child pid, ports distinct+nonzero,
      stale after child death, `assert_lane_gone` ×2, `assert_no_chrome`
- [ ] Children kill+waited on ALL exit paths; btrfs root reaped; zero orphans/temp dirs
- [ ] Other bodies, runner, validate.sh, lib/, bin/, docs untouched (git status: only
      test/concurrency.sh modified beyond S1's changes)

## Anti-Patterns to Avoid

- ❌ Don't `exec` the CLI inside the child (kills the caller-identity window) and don't
  run the child without `timeout 60`.
- ❌ Don't use `$!` as the owner pid (it's `timeout`'s) — read the child's own `$$`.
- ❌ Don't poll without a deadline; don't bare-`wait` children.
- ❌ Don't kill without `wait` (zombies → false-alive + audit failure).
- ❌ Don't modify S1's runner, the other bodies, or validate.sh.
- ❌ Don't run outside the isolated sandbox (AGENTS.md §1).

## Confidence Score

8/10 — the hermetic scaffolding, real-Chrome boot path, and assertion helpers all exist
and pass today; the only novel deltas are the timeout-bounded real-CLI children and the
pid-capture geometry, both specified above. Main residual risk: real agent-browser `open`
behavior under the temp HOME (mitigated by `|| true` + lane-lease assertions being the
actual test oracle, and by the optional status of this E2E per PRD R5).