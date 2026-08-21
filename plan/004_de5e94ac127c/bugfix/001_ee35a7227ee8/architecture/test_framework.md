# Test framework contract — changeset 001

Mandatory reading for every implementing subtask. AGENTS.md rules apply to every
test: single-setup, timeout-bounded, isolated temp tree, zero orphan processes.

## 1. The approved runner pattern (from test/release_reaper.sh)

`_abpool_run_release_reaper_suite` is the canonical single-setup runner:

- ONE process-spawning `setup()` call for the WHOLE suite (never per-test) — the
  known hang on 3rd call in a shared sandbox is exactly what this prevents.
- Each test body runs in the MAIN shell as `if test_fn; then … else …` (a failing
  assert's `return 1` records FAIL and the suite continues; no `( … )` subshell bodies
  → the shared EXIT trap cannot fire mid-suite and delete state).
- Suite-level `trap … EXIT INT TERM` reaps everything (`pkill -f` fake patterns, kill
  process groups) and `rm -rf`s the sandbox tree; every trap line ends `|| true`.
- Hard `timeout N` wraps every subprocess that could block (suite runner AND every
  spawn under it). Expected green counts are printed per suite.

Suite invocation (from repo root): `bash test/<suite>.sh` — each suite exits 0 iff
all its cases pass. test/concurrency.sh + test/transparency.sh are read-only studies
for env-redirection + fake-owner idioms.

## 2. New file: test/bootrace.sh (this changeset's regression suite)

Follows §1. Owns the same-owner-boot-race + crash-recovery regressions (BUG-001/002)
and the minor-bug regressions may live here or as small standalone cases in the same
file (preferred: ONE new file, keeps the 4 existing suites untouched).

Sandbox: `T=$(mktemp -d)` (btrfs-aware: prefer `-p "$HOME"` for real-FS lanes);
redirect `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`,
`AGENT_CHROME_MASTER`, `AGENT_CHROME_BIN`, `AGENT_BROWSER_REAL`; simulated owner via
`AGENT_BROWSER_POOL_OWNER_PID=$pid_of_sleep` + `POOL_OWNER_MODE` handling as in
test/concurrency.sh. Reap: kill the sim-owner pid + `wait`, pkill fake-chrome
patterns, rm -rf "$T".

## 3. Fake-chrome fixture with a startup-delay knob (the one new primitive)

Existing suites fake chrome WITHOUT a delay knob — the BUG-002 race needs a ~4s CDP
hold-off. Fixture: a small shell/python fake that (1) reads `$FAKE_CHROME_DELAY`
(default 0) and sleeps BEFORE serving; (2) serves `/json/version` over a tiny HTTP
listener on `--remote-debugging-port` parsed from argv; (3) records launch count to
`$FAKE_CHROME_COUNT_FILE` (append pid + port) so tests assert EXACTLY-ONE-launch;
(4) execs a long-lived `sleep`-style wait loop with `setsid` (own pgroup) so teardown
is `kill -- -pgid`. Fake agent-browser: no-op `connect`/`close`/`session list`
emitting the JSON shapes pool.sh expects (copy the argv contract from
test/transparency.sh's fake). Both fakes live in the test file (heredoc →
`$T/bin/`) — no repo-level fixture files.

## 4. Regression matrix (each case = a named function in test/bootrace.sh)

R1 BUG-001-guard-fs-agnostic: master populated; pre-create `$EPH/1` with junk; run a
boot (or call pool_copy_master directly via `source lib/pool.sh` in a subshell);
assert top-level `Local State` present, NO `$EPH/1/<master-basename>/` dir.
R2 BUG-001-recovery-e2e: provisional lease port=0 + dir present (crash-after-copy
sim) → driving command → rc 0, trusted profile (master's marker file), no nesting.
R3 BUG-002-race-e2e (PRD repro): FAKE_CHROME_DELAY=4; cmd A backgrounded; cmd B at
0.8s → B rc=0; EXACTLY one chrome launch (count file); lease chrome_pid == the live
fake's pid; then `release all` → zero `user-data-dir=$EPH` processes, dir gone.
R4 BUG-002-pre-port-race: second command DURING copy (before port write) → both
succeed; single copy; no nesting (lock + §1 guard together).
R5 BUG-003-reap-corrupt: corrupt `7.json` + orphan dir 7 → `reap` → dir AND lease
gone; lane 7 free for `pool_find_free_lane`; status shows no `? STALE` row.
R6 BUG-003-release-corrupt: corrupt `7.json` (+ live fake chrome on dir 7 cmdline) →
`release 7` rc 0, lease+dir gone, chrome dead.
R7 BUG-004-doctor-fresh: `AGENT_CHROME_EPHEMERAL_ROOT=$T/active-missing` → doctor
`[filesystem]` = OK(btrfs)/WARN, not FAIL(unknown); dir created.
R8 BUG-005-help-contract: help contains "replaces" + "antigravity"; not "appended";
help's default list == actual default set (compare against pool_config_init output).
R9 BUG-006-validate-path: `bash plan/004_de5e94ac127c/validate.sh --fast` from repo
root completes its P1/P2 phases without rc-127 path errors (full run is the M3 gate).

## 5. Safety checklist for every new test (AGENTS.md §1-§4)

- [ ] Single setup; per-test resources spawned + reaped by the test itself.
- [ ] `timeout` on EVERY subprocess; nothing unbounded (flock waits bounded by -w).
- [ ] Kill process groups (`setsid` + `kill -- -pgid`), `wait` after kill, trap cleans
      the temp tree; zero orphans at suite exit (`pgrep -af` fake patterns).
- [ ] No real Chrome, no real agent-browser, no operator state — fakes + redirected
      HOME/state/ephemeral/master only.
- [ ] Assertions print stable named FAIL lines (R1..R9) so CI/graders can grep.