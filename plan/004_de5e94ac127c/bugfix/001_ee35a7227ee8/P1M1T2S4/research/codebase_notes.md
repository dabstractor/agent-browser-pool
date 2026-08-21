# P1.M1.T2.S4 — widen (3b) release sweep: research notes

## Current code (lib/pool.sh ~2083-2101, inside _pool_release_lane_internals)

```bash
dir="$POOL_EPHEMERAL_ROOT/$lane"
if [[ ! ( "$chrome_pid"  =~ ^[0-9]+$ && "$chrome_pid"  -gt 0 )
      && ! ( "$chrome_pgid" =~ ^[0-9]+$ && "$chrome_pgid" -gt 0 ) ]]; then
    local pat="user-data-dir=$dir( |\$)"
    if pgrep -f -- "$pat" >/dev/null 2>&1; then
        _pool_log "pool_acquire(reap): lane $lane chrome ids untrusted → cmdline sweep"
        pkill    -f -- "$pat" 2>/dev/null || true
        sleep 0.2
        pkill    -9 -f -- "$pat" 2>/dev/null || true
    fi
fi
```

- Gate requires BOTH ids non-numeric/<=0. BUG-002 clobber state = positive-but-DEAD
  ids (doomed 2nd chrome). `pool_chrome_kill` on dead ids is a no-op → rm -rf deletes
  user-data-dir under a LIVE Chrome → leak.
- `pool_chrome_kill` (lib/pool.sh ~2055): group kill w/ numeric guards + 0.5s
  SIGTERM→SIGKILL escalation; bare-pid fallback; returns 0 always. Self-guards 0/0.
- Steps around: (2) mapfile jq extraction of chrome_pid/chrome_pgid/ephemeral_dir at
  ~2131; (3) pool_chrome_kill at ~2135; (3b) sweep; (4) guarded rm -rf reconstructed
  dir; (5) rm -f lease.

## fix_design.md §2c (authoritative)

- Drop the both-ids-<=0 precondition; run the anchored sweep as a FALLBACK whenever
  the id-based kill cannot be trusted: ids <=0/non-numeric OR `/proc/<chrome_pid>` no
  longer exists (recorded id dead) OR pgrep still matches while recorded pid gone.
- "Simplest correct form": sweep whenever `pgrep -f` matches and the recorded pid is
  not confirmed alive-and-matching. Keep pgrep guard (no match → no kill), anchored
  `user-data-dir=$dir( |$)` pattern (prefix-collision safe), pkill/sleep-0.2/pkill -9
  escalation VERBATIM.
- Liveness = `/proc/<pid>` existence, NEVER `kill -0` (ESRCH/EPERM ambiguity,
  AGENTS.md §4).

## Design decision for the widened gate

Note the whitelist subtlety: `/proc/<chrome_pid>` existing is NOT enough to skip the
sweep — the recorded pid could be a recycled/unrelated live pid, and the BUG-002 state
is precisely "recorded pid dead while a DIFFERENT pid runs on that dir". Safe skip
condition (conservative, matches fix_design "not confirmed alive-and-matching"):
run the sweep UNLESS the recorded chrome_pid is numeric >0 AND `/proc/$chrome_pid`
exists AND its cmdline contains `user-data-dir=$dir`. Checking the cmdline via
`tr '\0' ' ' </proc/$pid/cmdline | grep -F -- "user-data-dir=$dir"` confirms the
recorded pid IS the process on this dir → id-kill already handled it. Any other state
(ids<=0, /proc gone, or cmdline mismatch) → sweep (still pgrep-guarded so a no-match
costs one pgrep fork and kills nothing).

Extra check while confirming: read /proc/<pid>/cmdline — cheap, no fork beyond cat/tr.
Alternative minimal form (no cmdline read): sweep whenever pid dead or non-numeric;
if pid alive but mismatched, the pgrep guard prevents harm but the mismatch case
(clobbered to a foreign live pid) would skip the sweep and leak. Chosen form covers it.

## Idempotence / non-fatality requirements

- Release kernel runs in reap loop under `set -euo pipefail`; every new command must
  be `2>/dev/null || true` guarded or errexit-exempt (`if` conditions).
- pgrep rc 1 (no match) must not abort → keep inside `if pgrep … ; then`.
- Sweep is idempotent: pkill on dead/no match is a no-op with `|| true`.

## Upstream contract (T2.S2 done, T2.S3 in flight — parallel)

- T2.S2 delivered `pool_lane_boot_lock N` + fd-8 `flock -w 20` idiom; boot/connect
  serialization makes the race itself rare — (3b) is defense-in-depth after S4.
- T2.S3 restructures `pool_ensure_connected` under the same lock. No interface change
  to `_pool_release_lane_internals` from either; S4 only touches the (3b) gate.

## Test surface (test/bootrace.sh)

- Single-setup runner (`_br_spawn_owner` etc.), snapshot-then-clean-then-assert
  pattern (see `r3_bug002_race_e2e` lines ~288-333).
- R3 already asserts zero `pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT"`
  survivors after `release all` + 0.3s settle.
- S4 adds a NEW deterministic negative-control case (R3-neg): manually write a lease
  with dead-but-positive chrome_pid/chrome_pgid (e.g. spawn+kill a `sleep` to harvest
  a real dead pid), spawn a LIVE fake chrome pointed at `$EPH/1`, run `release all`,
  assert the live fake is dead. This case is red on current code (leak) and green
  only with the widened gate.
- Fake chrome harness: FAKE_CHROME_COUNT_FILE launch counter, FAKE_CHROME_DELAY,
  fakes installed under an isolated HOME/tmp tree; every case ends with
  release-all + pkill -f user-data-dir + rm lease/dir (copy that cleanup block).