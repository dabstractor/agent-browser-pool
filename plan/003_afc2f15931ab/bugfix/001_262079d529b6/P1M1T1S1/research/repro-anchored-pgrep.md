# Empirical Reproduction — Issue #1 (unanchored pgrep/pkill -f prefix collision)

**Date:** 2026-07-16
**Method:** Isolated `mktemp -d` tree, fake-Chrome processes with controlled argv, `timeout`-bounded, all processes reaped. No real Chrome. (AGENTS.md §1/§2 compliant.)
**Purpose:** Prove (a) the bug is real, (b) the anchored-ERE fix works, (c) the regression-test harness design is sound. This note is the evidence base for `P1M1T1S1/PRP.md`'s confidence score and the test reference implementation.

---

## The fake-Chrome harness (the non-obvious part)

The contract suggested `setsid -f sleep 300 -- --user-data-dir=...` for the regression test.
**That does not work** — `sleep` treats `--user-data-dir=...` as an unrecognized option and
exits immediately:

```
sleep: unrecognized option '--user-data-dir=/tmp/.../active/3'
Try 'sleep --help' for more information.
```

So the process dies before any assertion can run, and `/proc/<pid>/cmdline` never holds the
argv alive. The correct harness is a **bash loop script** that accepts arbitrary argv and
blocks forever:

```bash
cat >"$ROOT/fakechrome.sh" <<'EOF'
#!/usr/bin/env bash
# Hold the caller-supplied argv (incl. --user-data-dir=<dir>) alive until killed.
while :; do read -r -t 86400 _ || sleep 86400; done
EOF
chmod +x "$ROOT/fakechrome.sh"
```

Spawn with **plain `setsid`** (NOT `-f`), capturing `$!`:

```bash
setsid "$ROOT/fakechrome.sh" "--user-data-dir=$EPH/3"  "--remote-debugging-port=53423" >/dev/null 2>&1 &
pgid3=$!
setsid "$ROOT/fakechrome.sh" "--user-data-dir=$EPH/30" "--remote-debugging-port=53453" >/dev/null 2>&1 &
pgid30=$!
```

`setsid` (no `-f`) forks the child into a new session and the calling shell backgrounds the
`setsid` process itself; `$!` is that process, which IS the session leader (pgid == pid).
`setsid -f` would fork-and-exit, leaving `$!` pointing at the transient launcher.

Verified `/proc/<pgid>/cmdline` is clean and correct:

```
pid=2889722 alive cmd=[bash /tmp/.../fakechrome.sh --user-data-dir=/tmp/.../active/3 --remote-debugging-port=53423 ]
pid=2889723 alive cmd=[bash /tmp/.../fakechrome.sh --user-data-dir=/tmp/.../active/30 --remote-debugging-port=53453 ]
```

## Verified results (the core proof)

With `EPH=/tmp/.../active`, two fake chromes on lanes 3 and 30:

```
=== UNANCHORED (bug): pattern=[user-data-dir=$EPH/3] ===
  matches: [2889722 2889723]              ← BOTH pids (lane 3 AND lane 30) — the bug

=== ANCHORED (fix): pattern=[user-data-dir=$EPH/3( |$)] ===
  matches: [2889722]                      ← ONLY lane 3 — the fix
```

Simulating the reap kill (`pkill -9 -f` with the anchored pattern) on lane 3 only:

```
=== Simulate the reap kill (anchored, -9) on lane 3 only ===
  lane3 (pgid 2889722) alive? NO-GOOD-KILLED      ← orphan killed (correct)
  lane30 (pgid 2889723) alive? YES-GOOD-SPARED    ← live lane spared (correct)
leaked=0                                          ← full cleanup, no orphans
```

## ShellCheck on the proposed fix

```bash
pat="user-data-dir=$dir( |\$)"
if pgrep -f -- "$pat" >/dev/null 2>&1; then
    pkill    -f -- "$pat" 2>/dev/null || true
    sleep 0.2
    pkill    -9 -f -- "$pat" 2>/dev/null || true
fi
```

`shellcheck -s bash` on this block: **CLEAN** (0 findings). Note the `\$` inside the
double-quoted assignment yields a literal `$` in the string, which is the ERE end-of-line
metacharacter.

Verified `pat` value:

```
pat=[user-data-dir=/home/x/active/3( |$)]
CORRECT
```

## Liveness check choice

`kill -0 $pid` is a trap (AGENTS.md §3): it returns non-zero for BOTH "dead" (ESRCH) and
"foreign-alive" (EPERM). The test uses `/proc/<pgid>` directory existence instead:

```bash
[[ -d /proc/$pgid3 ]]  && echo "alive" || echo "dead"
```

Verified reliable across the kill sequence (lane 3 `/proc/$pgid3` disappears after `pkill -9`;
lane 30 `/proc/$pgid30` persists).

## Cleanup pattern (AGENTS.md §3)

Teardown kills the **process group** (the `--` is required because the arg starts with `-`),
then `wait`s both pgids so `/proc` truly clears (no zombies):

```bash
kill -9 -- -$pgid30 2>/dev/null || true
wait "$pgid30" 2>/dev/null || true
wait "$pgid3"  2>/dev/null || true
```

Final leak check: `pgrep -f "user-data-dir=$EPH"` → 0 matches.

## Conclusion

- The bug is real and empirically reproducible with safe fake processes.
- The anchored-ERE fix (`user-data-dir=$dir( |$)`) eliminates the prefix collision.
- The regression-test design (bash-loop fakechrome + plain-setsid + /proc liveness + pgroup
  teardown) is validated and ready to drop into `test/validate.sh`.
- The contract's `sleep 300 -- --user-data-dir=...` suggestion is incorrect and MUST be
  replaced with the bash-loop harness documented here.
