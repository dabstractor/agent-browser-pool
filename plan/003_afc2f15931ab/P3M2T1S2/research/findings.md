# Research notes — P3.M2.T1.S2: `selftest_owner_resolves_non_pi_harness`

Static research only. No suite run, no Chrome booted (AGENTS.md §1). All line numbers are
CURRENT (post P3.M2.T1.S1 landing); the test_code_map.md numbers are pre-S1 and have shifted.

---

## 0. Prerequisite P3.M2.T1.S1 is LANDED in tree (verified)

`spawn_sim_owner [SECONDS] [COMM]` (COMM default `"pi"`) is present at `test/validate.sh:128`.
Confirmed by reading 128–169:
- `local dur="${1:-600}" comm_name="${2:-pi}" …`
- 15-char `TASK_COMM_LEN` guard (warn + truncate `${comm_name:0:15}`).
- `bin="$bin_dir/$comm_name"` (bin filename generalizes) while `mktemp -d -t abpool-pi.XXXXXX`
  (dir PREFIX preserved — the EXIT-trap glob backstop `rm -rf -- /tmp/abpool-pi.*` stays valid
  for ANY comm).
- Settle loop `[[ "$comm" == "$comm_name" ]]`.
So `spawn_sim_owner 600 claude` and `spawn_sim_owner 600 xterm` are available — this item's sole
prerequisite is satisfied.

## 1. `pool_owner_resolve` TEST MODE records the ACTUAL comm (lib/pool.sh:499–613)

TEST MODE branch (when `AGENT_BROWSER_POOL_OWNER_PID` is set + numeric), pool.sh ~524–556:
```bash
POOL_OWNER_COMM="$(cat /proc/"$ovr_pid"/comm 2>/dev/null || printf 'pi')"; declare -g POOL_OWNER_COMM
```
→ reads the REAL `/proc/<pid>/comm`. Falls back to `"pi"` ONLY if unreadable (dead/EPERM). For a
live `spawn_sim_owner 600 claude` process this is exactly `"claude"`. It also sets
`POOL_OWNER_PID="$ovr_pid"` (non-zero ⇒ resolved) and `POOL_OWNER_STARTTIME` from the env var if
given, else reads via `_pool_owner_starttime`. **NEVER fatal** (always `return 0`). It does NOT do
harness-set membership in TEST MODE (it trusts the override pid); that is the intended contract for
testability (PRD §2.18). Globals are reset to defaults at the TOP of every call → re-runnable.

## 2. `pool_owner_alive` is comm-generic (lib/pool.sh:638–686)

`pool_owner_alive PID EXPECTED_STARTTIME [EXPECTED_COMM]` (comm default `"pi"`). Decision ladder:
(a) `/proc/<pid>` missing → return 1; (b) `/proc/<pid>/comm != EXPECTED_COMM` → return 1;
(c) starttime mismatch → return 1; (d) all pass → return 0. Reads the actual starttime via
`_pool_get_starttime` internally. **Never fatal.** This is exactly what makes the positive
(`claude` accepted) and negative (`xterm` rejected as `claude`) cases provable.

## 3. `_pool_get_starttime` (lib/pool.sh:425+)

Canonical extractor: echoes the digits-only starttime + rc 0 on success; echoes nothing + rc 1
(non-fatal) on failure. `setup()` (validate.sh:197–198) and `selftest_sim_owner_is_alive_pi` use
it. Using it for `st` and passing the same `st` as `pool_owner_alive`'s EXPECTED_STARTTIME ⇒ the
internal read matches (same source).

## 4. The runner: single-setup, main-shell bodies (validate.sh:728–757)

```bash
_run_selftest_suite() {
    setup                                  # ★ ONE AND ONLY setup() call
    for fn in $(compgen -A function | grep '^selftest_' | sort); do
        if "$fn"; then ABPOOL_PASS=…; else ABPOOL_FAIL=…; fi
        rm -f -- "${POOL_LANES_DIR:?}/"*.json 2>/dev/null || true   # inter-body backstop
    done
    teardown
}
```
- **Auto-discovery** via `compgen -A function | grep '^selftest_' | sort` — NO registration.
- Body runs via `if "$fn"` in the MAIN shell (no `( … )` subshell ⇒ the EXIT trap never fires
  mid-suite ⇒ shared temp root + `ABPOOL_CUR_OWNER` survive across bodies). A failing assert's
  `return 1` becomes the function's rc → recorded as FAIL → suite continues.
- Inter-body backstop is `rm -f lanes/*.json` only (not a POOL_OWNER_* reset).

## 5. The template: `selftest_sim_owner_is_alive_pi` (validate.sh:314–329)

Calls `pool_owner_alive "$pid" "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-0}" "pi"` directly with the
(pid, starttime, comm) triple. It does NOT spawn its own owner — it reuses `setup`'s (the env
vars). Our new selftest DEPARTS from the template ONLY in that it spawns + reaps its OWN owners
(it must not clobber the shared `ABPOOL_CUR_OWNER`).

## 6. REAPING — the load-bearing subtlety (AGENTS.md §3/§4)

### 6a. The `$(spawn_sim_owner …)` reparenting fact (host-verified)
`spawn_sim_owner` is consumed via `pid="$(spawn_sim_owner …)"` — a command subshell. The
backgrounded `sleep` child is a child of that SUBSHELL; when the subshell exits the child is
reparented. **The parent (main shell) CANNOT `wait` it** — `wait "$pid"` returns 127 ("pid is not
a child of this shell"). Verified in a bounded, isolated micro-check.

### 6b. Why that is HARMLESS here (and consistent with the codebase)
The codebase's sanctioned idiom is `_release_kill_owner_and_reap_zombie` (release_reaper.sh:141):
```bash
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
```
The `kill` terminates the process; the subreaper (init/systemd-user) reaps the zombie. `wait`'s 127
is masked by `|| true`. release_reaper.sh uses the SAME idiom for the SAME `spawn_sim_owner` pids,
so our selftest is consistent with the suite. For OUR selftest specifically the residual zombie is
additionally harmless because we NEVER re-check a killed owner's liveness — we capture all
assertion values FIRST, reap, THEN assert.

### 6c. Guaranteed-reap design: "capture → reap → assert"
Every phase is: spawn → capture (starttime, resolve globals, alive-rc, real-comm) → kill+wait →
assert on captured values. Because asserts are LAST, an assert failure (return 1) can never skip a
reap. Between spawn and reap every intermediate op is `set -e`-EXEMPT (plain assignments; the
non-fatal `pool_owner_resolve`; `pool_owner_alive … || alive_rc=$?`; `cat … || true`), so the reap
path is always reached. The temp bin dirs (/tmp/abpool-pi.*) are reaped by the EXIT trap's
comm-agnostic glob backstop.

## 7. Env-override semantics (host-verified, bounded micro-check)
`AGENT_BROWSER_POOL_OWNER_PID="$pid" … pool_owner_resolve` (inline single-command env assignment)
OVERRIDES the exported value for that one call and REVERTS afterward — even though setup() did
`export AGENT_BROWSER_POOL_OWNER_PID=<pi owner>`. So the later `selftest_sim_owner_is_alive_pi`
still sees setup's pi owner. The negative case does NOT call `pool_owner_resolve` (it calls
`pool_owner_alive` directly), so no env interaction there. Also verified: `cmd || rc=$?` captures a
non-zero return WITHOUT aborting under `set -euo pipefail`.

## 8. No cross-test pollution
- Sort order of discovery: `…selftest_lane_exists_after_write`, **`selftest_owner_resolves_non_pi_harness`**,
  `selftest_sim_owner_is_alive_pi`, …  → our body runs just before the pi-alive selftest.
- No selftest reads the `POOL_OWNER_*` GLOBALS (grep found only comments referencing them); they
  use `AGENT_BROWSER_POOL_OWNER_*` env or literals. So mutating `POOL_OWNER_COMM="claude"` is
  harmless, and `pool_owner_resolve` resets globals at the top of each call anyway.
- We do NOT touch `ABPOOL_CUR_OWNER` (setup's pi owner stays alive for the whole suite).
- No lease files written (resolve TEST MODE + pool_owner_alive never write) → the inter-body
  `rm -f lanes/*.json` backstop is a no-op for us.

## 9. Validation baseline (static; verified runnable in this tree)
- `bash -n test/validate.sh` → rc 0.
- `shellcheck -S warning -s bash test/validate.sh` → rc 0.
- Plain `shellcheck -s bash test/validate.sh` → rc 1 with **5 pre-existing info** findings at
  lines **29, 599, 629, 659, 691** (SC1091 @29, SC2016 @others) — all intentional, OUT OF SCOPE.
  Inserting ~45 lines at line ~330 shifts the four SC2016 line numbers up; the implementer must
  confirm the count stays 5 and none land in the new function.
- The selftest suite itself is Chrome-free (the `setsid`/`pool_boot_lane` hits at 583/654 are in
  COMMENTS), but we still DO NOT run it during planning (AGENTS.md §1) — the implementing agent
  runs it isolated + bounded per §2.
