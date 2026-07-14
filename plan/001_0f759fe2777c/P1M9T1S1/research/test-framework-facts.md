# Research — P1.M9.T1.S1: Test framework (`test/validate.sh`)

> Authoritative facts + design for the `test/validate.sh` harness. Everything below is
> either host-verified (run 2026-07-13) or cited to a primary source. The companion
> `external-research.md` (raw subagent output) lives at
> `.pi-subagents/artifacts/outputs/fdd52218/research.md`.

---

## §1. Codebase facts (ground truth — read `lib/pool.sh` directly)

### 1.1 The test-hook overrides ALREADY EXIST and are wired (LANDED)
`pool_owner_resolve()` @lib/pool.sh:478 implements PRD §2.18 / key_findings FINDING 8:

- **TEST MODE** (the harness path): if `AGENT_BROWSER_POOL_OWNER_PID` is set + numeric →
  use it directly, set `POOL_OWNER_COMM="pi"`, and:
  - if `AGENT_BROWSER_POOL_OWNER_STARTTIME` is ALSO set → use it verbatim;
  - else read the REAL starttime via `_pool_owner_starttime "$pid"` (→ `_pool_get_starttime`,
    the greedy-`)`-strip → field-20 parser @lib/pool.sh:404).
- Skips the ppid walk entirely (so a plain-terminal harness with no `pi` ancestor works).
- **CRITICAL (host-verified):** an INVALID/non-numeric `_OWNER_PID` is IGNORED with a log
  line + `return 0` (falls through to REAL mode → passthrough). The framework MUST pass a
  valid numeric PID.

### 1.2 The comm-liveness coupling (THE pivotal constraint)
`pool_owner_alive PID EXPECTED_STARTTIME [EXPECTED_COMM=pi]` @lib/pool.sh:616 reads the
ACTUAL `/proc/<pid>/comm` and compares to `EXPECTED_COMM` (default `"pi"`) — it does NOT
trust `POOL_OWNER_COMM`. Decision ladder: `/proc/<pid>` exists → `comm == "pi"` →
`starttime` matches → return 0 (alive). ANY divergence → return 1 (dead/recycled).

**Consequence:** for a lease to be "mine" (reuse) / "live" (not stale), the PID recorded
in the lease must point to a REAL running process whose `/proc/<pid>/comm` is literally
`pi`. The env-override hook sets the *identity*; it does NOT fake the *kernel-visible
process*. Therefore the harness MUST spawn a real process with `comm == "pi"` and use ITS
pid as `AGENT_BROWSER_POOL_OWNER_PID`. (Verified mechanism in §2.)

Callers that exercise this path: `pool_lease_find_mine` @1003, `pool_lane_is_stale`
@1164, `_pool_acquire_critical_section` REAP-STALE, `pool_reuse_orphan`.

### 1.3 How to make a lane appear held / gone (assertion targets)
- A lane N is "held" ⟺ lease file `$POOL_LANES_DIR/$N.json` is present (numeric *.json).
  `pool_lanes_list` @967 enumerates exactly these.
- `pool_lease_exists N` @918 ⟺ `[[ -f "$POOL_LANES_DIR/$N.json" ]]` AND valid JSON.
  Returns rc 1 on missing/corrupt/non-numeric → a BARE call ABORTS under set -e → the
  assertion helper MUST wrap in `if`/`||`.
- The ephemeral profile dir for lane N is `$POOL_EPHEMERAL_ROOT/$N/` (reconstructed by
  `_pool_release_lane_internals` @1813 as `$POOL_EPHEMERAL_ROOT/$lane`).
- Chrome is launched per lane by `pool_chrome_launch` @1471 with the flag
  `--user-data-dir="$POOL_EPHEMERAL_ROOT/$lane"` (+ setsid → own process group).

### 1.4 Teardown primitives (what "release all" does)
- Admin binary: `bin/agent-browser-pool release all` → `pool_admin_release all`
  @3830 → snapshots `pool_lanes_list` → `pool_release_lane N` EACH (rc 0 ALWAYS; idempotent;
  kills pgroup + disconnects daemon + `rm -rf` dir + deletes lease).
- `bin/agent-browser-pool reap` → `pool_admin_reap` @3730 → `pool_reap_stale` (stale-only,
  skips live-owner lanes). Distinct from release.
- Both the admin binary AND the wrapper resolve paths via `pool_config_init`, which reads
  `AGENT_BROWSER_POOL_STATE` / `AGENT_CHROME_EPHEMERAL_ROOT` / `AGENT_CHROME_MASTER` /
  `HOME` env vars. **Host-verified:** `HOME=<tmp> AGENT_BROWSER_POOL_STATE=<tmp>/state
  AGENT_CHROME_EPHEMERAL_ROOT=<tmp>/active bash -c 'source lib/pool.sh; pool_config_init;
  pool_state_init'` → `POOL_LANES_DIR=<tmp>/state/lanes`, state created. So as long as the
  harness EXPORTS these before invoking the binary, the binary operates on the temp tree.
  (Subprocess inherits the exports → consistent FS state.)

### 1.5 `pool_die` exits the whole process (teardown gotcha)
`pool_die` @lib/pool.sh:30 is `printf >&2; exit 1`. The admin/release functions do NOT
`pool_die` in their bodies (rc-0-always), BUT `pool_config_init`/`pool_state_init` CAN
pool_die on genuine misconfig (e.g. unset `$HOME`). In the harness this means: an inline
`pool_admin_release` that hits a config error would EXIT the harness shell. **Mitigation:**
invoke teardown as a SUBPROCESS (`"$ABPOOL_ADMIN" release all >/dev/null 2>&1 || true`) so
the harness survives a pool_die. (Same lesson as M8.T1.S1's doctor-as-subprocess D10.)

### 1.6 Isolation is MANDATORY (not optional)
Without overriding `HOME` + `AGENT_BROWSER_POOL_STATE` + `AGENT_CHROME_EPHEMERAL_ROOT` +
`AGENT_CHROME_MASTER`, the harness would:
  - read/write the REAL `~/.local/state/agent-browser-pool/` (clobbering live leases);
  - `pgrep`/`pkill` the operator's REAL daily-driver Chrome;
  - `rm -rf` real ephemeral dirs.
`pool_config_init` anchors EVERY default on `realpath($HOME)` (@lib/pool.sh:126-145), so
pointing `HOME` at a temp dir + setting the three overrides gives full isolation.
**Host-verified:** the long-lived interactive `pi` holds leases until explicit release
(PRD §2.18), so a non-isolated harness would race/clobber it. Isolation is THE safety gate.

### 1.7 Host tooling (all verified present at /usr/bin)
`sleep` /usr/bin/sleep · `pgrep` /usr/bin/pgrep · `pkill` /usr/bin/pkill · `mktemp`
/usr/bin/mktemp · `bash` 5.x · `jq`, `flock`, `setsid`, `curl` (all present — doctor §2.16).
**No master profile under the real root** (`~/.agent-chrome-profiles/master-profile` absent
on this checkout) → the framework's OWN self-test MUST NOT do a real acquire/Chrome launch
(that needs master + btrfs + ~10s Chrome boot). Those are M9.T2/T3/T4. The self-test
exercises the FRAMEWORK (assertions, runner, isolation, owner-sim) against temp state +
the LANDED lib primitives (lease write/read, lanes_list, owner_alive) — no Chrome.

---

## §2. The "fake `pi`" process trick (HOST-VERIFIED 2026-07-13)

`/proc/<pid>/comm` is set by the kernel to the **basename of the executed ELF** (the
`filename` arg to `execve(2)`) — NOT `argv[0]` (proc(5); prctl(2) PR_SET_NAME). So:

```bash
td=$(mktemp -d)
cp /usr/bin/sleep "$td/pi"      # basename "pi"
chmod +x "$td/pi"
"$td/pi" 600 &                  # execve("$td/pi", ["$td/pi","600"], envp)
pid=$!
sleep 0.3                       # ⚠️ SETTLE — see gotcha
cat /proc/$pid/comm             # → "pi"   ✅ (verified)
```

Verified output: `comm via cat: [pi]`, `readlink /proc/$pid/exe → $td/pi`.

`exec -a pi /bin/sleep` does NOT work (bash `exec -a` rewrites `argv[0]` only; the binary
path passed to execve is still `/bin/sleep` → comm stays "sleep"). Confirmed by
bash manual (Bourne Shell Builtins, `exec`).

`TASK_COMM_LEN=16` (15 chars + NUL; `include/uapi/linux/sched.h`); `"pi"` is 2 chars →
zero truncation risk.

### ⚠️ GOTCHA — the fork→execve race window (cost me one verification run)
The FIRST verification returned `comm=bash`. Cause: `$!` is valid immediately after the
`&` (the child exists — a fork), but the child has NOT YET called `execve("/tmp/.../pi")`.
For a few hundred microseconds the child still shows the PARENT's `comm` ("bash"). If the
harness reads `/proc/$pid/comm` (or `starttime`) in that window → wrong value. **Fix:**
`spawn_sim_owner` must SETTLE: poll `/proc/$pid/comm` until it reads `pi` (cap a few
retries) OR `sleep 0.2` before returning. This also guarantees `_pool_get_starttime`
reads the post-exec value. The settle must happen INSIDE `spawn_sim_owner` so callers get
a ready-to-use pid.

### Simulating a STALE / dead owner (for the reaper tests in M9.T3)
Two equivalent recipes the framework should expose (via helpers or documented pattern):
1. **Dead**: `kill "$pid"` then poll until `/proc/$pid` vanishes → `pool_owner_alive` sees
   no `/proc` → return 1 (dead) → reaped.
2. **Recycled (starttime mismatch)**: keep the pid alive but set
   `AGENT_BROWSER_POOL_OWNER_STARTTIME` to a BOGUS value (e.g. one off) when re-resolving →
   `pool_owner_alive` starttime check fails → return 1 (recycled).
(Both reduce to the same stale verdict; (1) is the realistic crash simulation.)

---

## §3. External research synthesis (full raw output: external-research.md)

### 3.1 Subshell-isolated `run_test` — a test failure NEVER kills the harness
`set -e` exempts commands used as `if`/`||` conditions (Greg's Wiki BashFAQ/105). So run
the body in a subshell behind `||`:

```bash
run_test() { local name="$1" fn="$2" rc=0
    setup
    ( set -e; "$fn" ) || rc=$?     # body non-zero (assert fail OR a set-e abort) = test fail
    teardown
    if (( rc == 0 )); then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$name"); fi
}
```
- `( set -e; "$fn" )` re-enables errexit INSIDE the body so the first failing assert ends
  the test (no need for the body to thread `|| exit 1` everywhere).
- `|| rc=$?` makes the harness survive any body exit code.
- `PASS=$((PASS+1))` (the `$(( ))` EXPANSION) is always safe; NEVER `(( PASS++ ))` as a
  statement (returns the OLD value → 0 when PASS was 0 → aborts under set -e).
- `(( rc == 0 ))` is INSIDE `if` → exempt.

### 3.2 Source-vs-execute gate (`[[ "${BASH_SOURCE[0]}" == "${0}" ]]`)
`validate.sh` is BOTH a sourced library (downstream `source test/validate.sh` to reuse
helpers + runner) AND a runnable suite (`bash test/validate.sh` runs the framework
self-test). The gate runs the self-test ONLY when executed directly (bash manual,
Bash Variables → `BASH_SOURCE`). Matches the repo's `bin/*` `${BASH_SOURCE[0]}` bootstrap.

### 3.3 set -e hazards the helpers must respect (all proven in lib/pool.sh too)
- **`local x="$(…)"` MASKS failure** (SC2155): `local` always returns 0, so a failing `$(…)`
  looks like success (this does NOT abort — it's the bug). Fix: `local x; x="$(…)"`.
- **Bare `(( … ))` @0 aborts** (returns exit 1 when result is 0). Only inside `if`/`||`/
  `$(( ))`. (lib/pool.sh `_pool_age_str` documents this verbatim.)
- **`pgrep`/`grep`/`curl`/`kill` non-zero abort** (no-match / ESRCH). Wrap in `if`/`|| true`.
  `kill -0` is a TRAP (kill(2): returns 1 for BOTH ESRCH-dead AND EPERM-foreign-alive) → use
  `/proc/<pid>` + `comm` + `starttime`, never `kill -0`. (lib/pool.sh already does.)
- **SC2181**: check exit codes directly with `if cmd;`, not via `cmd; rc=$?; if [ … ]`.

### 3.4 Hermetic isolation pattern
`mktemp -d` (race-free, honours `$TMPDIR`) for a private root + `trap cleanup EXIT INT TERM`
(backstop, since set -e can abort mid-test) + per-test `setup`/`teardown`. Override
`HOME` (anchors everything), `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`,
`AGENT_CHROME_MASTER`. Mirrors git's `t/test-lib.sh` TRASH_DIRECTORY + sharness.

### 3.5 `assert_no_chrome` — scoped, not global
`pgrep -f -- "user-data-dir=$POOL_EPHEMERAL_ROOT"` matches the FULL cmdline flag the pool
writes → scopes to pool Chrome only → does NOT false-positive the operator's daily-driver
Chrome (whose `--user-data-dir` is `~/.config/google-chrome`). `pgrep -f` is a REGEX (escape
metachars in the root) and returns rc 1 on no-match → MUST be the `if` condition. Boolean
form (`pgrep … >/dev/null`) — a single Chrome is MANY processes (renderer/GPU/utility), so
do NOT count via `pgrep -c` for "is there any?".

### 3.6 References (primary, version-stable)
- proc(5): https://man7.org/linux/man-pages/man5/proc.5.html (comm, stat field 22, parsing)
- prctl(2) PR_SET_NAME + TASK_COMM_LEN: https://man7.org/linux/man-pages/man2/prctl.2.html
- kill(2) (kill -0 ESRCH/EPERM conflation): https://man7.org/linux/man-pages/man2/kill.2.html
- pgrep(1) (-f full cmdline, rc 1 no-match): https://man7.org/linux/man-pages/man1/pgrep.1.html
- mktemp(1): https://man7.org/linux/man-pages/man1/mktemp.1.html
- TASK_COMM_LEN: https://github.com/torvalds/linux/blob/master/include/uapi/linux/sched.h
- SC2155: https://www.shellcheck.net/wiki/SC2155 · SC2181: https://www.shellcheck.net/wiki/SC2181
- BashFAQ/105 (set -e is not a panacea): https://mywiki.wooledge.org/BashFAQ/105
- bash manual (BASH_SOURCE, exec -a, trap): https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- git t/test-lib.sh (canonical hand-rolled harness): https://github.com/git/git/blob/master/t/test-lib.sh
- sharness: https://github.com/chriscool/sharness

---

## §4. Design decisions for `test/validate.sh`

- **D1 — Single file, dependency-free.** PRD §3 layout names exactly `test/validate.sh`
  (no bats/shunit2). It sources `lib/pool.sh` (like the `bin/*` shims) for the LANDED
  primitives (`pool_lease_write`, `pool_lease_exists`, `pool_lanes_list`, `pool_config_init`,
  `pool_state_init`, `pool_owner_alive`, `_pool_get_starttime`).
- **D2 — Dual mode via the source-vs-execute gate.** Executed directly → run the framework
  self-test (`selftest_*` prefix) and exit non-zero on any failure. Sourced by downstream
  (M9.T2/T3/T4) → defines helpers + `abpool_run_suite [prefix]`; downstream defines
  `test_*` and calls `abpool_run_suite test_`. Distinct prefixes prevent collision.
- **D3 — The 5 contract helpers + supporting `_fail`/`spawn_sim_owner`.** The 5 named
  helpers (`assert_eq`, `assert_lane_exists`, `assert_lane_gone`, `assert_no_chrome`,
  `assert_no_dir`) are the contract surface; `_fail` records + `return 1` (never exits);
  `spawn_sim_owner` is the engine behind owner simulation (verified trick §2).
- **D4 — `run_test(name, fn)`** wraps setup → body(subshell) → teardown, counts PASS/FAIL,
  records FAILED list; `abpool_run_suite` enumerates a prefix + prints summary + exits 1 if
  any fail. (§3.1.)
- **D5 — Setup is hermetic + exports the contract env.** `mktemp -d` root; export
  `HOME`, `AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`, `AGENT_CHROME_MASTER`,
  `AGENT_CHROME_HEADLESS=1`; `pool_config_init` + `pool_state_init`; then `spawn_sim_owner`
  → export `AGENT_BROWSER_POOL_OWNER_PID` + `_OWNER_STARTTIME` (its REAL starttime). This is
  the literal contract (b) realized correctly (a unique live `pi` PID per test).
- **D6 — Teardown is a safety net.** Best-effort `"$ABPOOL_ADMIN" release all` AS A
  SUBPROCESS (`|| true`, §1.5) + kill tracked sim-owners + rm their temp bins. The
  per-test CLEANUP ASSERTIONS (release + assert_no_chrome + assert_no_dir) live in each
  test BODY (PRD §2.18 "every test must release/reap and assert cleanup"); teardown is the
  backstop so a crashed body can't contaminate the next test.
- **D7 — Global EXIT trap removes the temp root** (§3.4), even on signal/mid-test abort.
- **D8 — Self-test is Chrome-free.** Uses temp state + lib primitives only (write a lease,
  assert it exists; rm it, assert gone; assert_no_dir on a known path; assert_eq pass/fail;
  spawn_sim_owner → assert comm==pi + pool_owner_alive==0). Runs in <1s, no master/btrfs.
- **D9 — `ABPOOL_WRAPPER`/`ABPOOL_ADMIN` absolute-path constants** resolve the repo bins
  symlink-safely (mirror `bin/*`); pre-cutover testing uses ABSOLUTE paths (PRD §2.17).

## §5. Validation approach
- Level 1: `bash -n test/validate.sh`; `shellcheck -s bash test/validate.sh` (SC1091 info
  on the dynamic `source lib/pool.sh` is ACCEPTED — identical to `bin/*`, the repo norm).
- Level 2 (functional): `bash test/validate.sh` → rc 0, prints "N passed, 0 failed";
  NEGATIVE test (assert_eq with mismatched args via a throwaway selftest) → rc 1.
- Level 3 (integration sanity): `source test/validate.sh` from a scratch script, define a
  `test_*` that writes+asserts a lease, call `abpool_run_suite test_` → rc 0.
- Hermetic: the self-test must NOT touch `~/.local/state/agent-browser-pool` (assert the
  temp root is the only thing created/removed; `findmnt`/`ls` guards optional).

## §6. Scope boundaries (what this task does NOT do)
- NO real Chrome launch / real acquire / concurrency / reaper tests — those are M9.T2/T3/T4.
- NO edits to `lib/pool.sh`, `bin/*`, `install.sh`, PRD/README/tasks — validate.sh is NEW.
- NO user-facing docs (item §5: "test infrastructure, no user-facing surface").
- NO bats/shunit2 dependency (PRD §3: single `test/validate.sh`).
- The self-test does NOT exercise the wrapper binary end-to-end (needs master+btrfs+Chrome).
