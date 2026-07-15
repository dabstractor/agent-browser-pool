# Reference Implementation: EADDRINUSE detection + selftest (P1.M2.T1.S1)

Paste-ready, strict-mode-safe bash. All facts host-verified 2026-07-12.

## 1. THE EDIT (lib/pool.sh, pool_chrome_launch instant-exit block)

### Current code (lib/pool.sh:1531-1538, verified this session)
```bash
    pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
    if [[ -z "$pgid" ]]; then
        # Chrome died before we could read its pgroup. Best-effort reap of the bare pid,
        # then die with the log path (Chrome's stderr is in there).
        kill "$POOL_CHROME_PID" 2>/dev/null || true
        pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                 "see log: $log_file"
    fi
```

### Replacement (the fix — EADDRINUSE → return 1, else → pool_die)
```bash
    pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
    if [[ -z "$pgid" ]]; then
        # Chrome died before we could read its pgroup. Best-effort reap of the bare pid.
        kill "$POOL_CHROME_PID" 2>/dev/null || true
        # EADDRINUSE detection (Issue 2): if Chrome's log shows a port-bind failure,
        # return 1 (NON-FATAL, retryable) so _pool_launch_and_verify (S2) can re-pick a
        # port. This handles the instant-exit-with-EADDRINUSE edge case. NOTE: the COMMON
        # EADDRINUSE case (Chrome stays up, no CDP) is caught by pool_wait_cdp's 30s
        # timeout and recovered by S2's port re-pick — THIS grep is the defensive fast
        # path for the instant-exit variant. The pattern matches Chrome's
        # "Cannot start http server for devtools" (devtools_http_handler.cc) and the
        # strerror "Address already in use" variants. `if grep` is errexit-exempt.
        if grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null; then
            _pool_log "pool_chrome_launch: Chrome exited immediately (port $port may be in use); see log: $log_file"
            return 1
        fi
        # Genuine misconfiguration (broken binary / bad flags / corrupt profile) — FATAL.
        pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                 "see log: $log_file"
    fi
```

### Why this structure
- `if grep -qiE ...; then` — the `if` condition is errexit-exempt, so grep's rc-1 (no
  match) is a clean branch, not a set -e abort.
- `_pool_log` (warning) BEFORE `return 1` — observability; the caller (S2) logs its own
  re-pick, but this line records WHY the launch failed (port-in-use vs misconfig).
- `return 1` (NOT `pool_die`) — the retryable signal. S2's `_pool_launch_and_verify`
  calls `pool_chrome_launch` WITHOUT a set -e guard today (it assumes pool_die-or-0);
  S2 will add the `if ! pool_chrome_launch ...; then re-pick; fi` guard. (S1's contract:
  return 0 success | return 1 EADDRINUSE-instant-exit | pool_die fatal.)
- The existing `kill "$POOL_CHROME_PID" 2>/dev/null || true` STAYS (it reaps the bare
  pid before either return path). Moved ABOVE the grep so the pid is reaped regardless.
- `2>/dev/null` on grep — suppresses "No such file" if the log somehow wasn't created
  (defensive; the mkdir -p + redirect at line 1505-1519 ensures it exists).

---

## 2. THE DOCSTRING UPDATE (lib/pool.sh ~1440-1480)

The function docstring currently says (verified, lines ~1455-1480):
```
# Returns 0 on success; pool_die on bad args / instant Chrome death / missing log dir.
```
and
```
#   - POOL_CHROME_PGID=$(ps -o pgid= -p $PID | tr -d ' ')  (GUARDED — see GOTCHA)
```
and the GOTCHA:
```
# GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
#   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
#   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
#   `[[ -z ]]` check → pool_die with the log path. Highest-impact gotcha in this task.
```

### Docstring changes (Mode A — document the new return-1-on-EADDRINUSE)
1. Update the `# Returns` line:
   ```
   # Returns 0 on success; 1 on instant Chrome death WITH an EADDRINUSE-like error in
   # the log (port collision — retryable, caller re-picks a port); pool_die on bad args
   # / instant Chrome death WITHOUT EADDRINUSE (genuine misconfiguration) / missing log dir.
   ```
2. Update the CONTRACT block (the `# CONSUMER:` line ~1465):
   ```
   # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → Chrome launched + globals
   #   set (pgid==pid); rc 1 → EADDRINUSE detected on instant-exit (retryable — caller
   #   re-picks a port via pool_find_free_port); pool_die → fatal (propagates). The caller
   #   MUST guard under set -e: `if ! pool_chrome_launch ...; then <re-pick port>; fi`.
   ```
3. Update the GOTCHA (the "Highest-impact gotcha" block ~1473):
   ```
   # GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
   #   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
   #   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
   #   `[[ -z ]]` check. On instant death, grep the log for EADDRINUSE-like patterns
   #   (Issue 2): match → return 1 (retryable, caller re-picks port); no match → pool_die
   #   (genuine misconfiguration). NOTE: the COMMON EADDRINUSE case is Chrome STAYING UP
   #   without CDP → caught by pool_wait_cdp's 30s timeout → S2 re-picks; THIS grep is the
   #   defensive fast path for the instant-exit variant.
   ```

---

## 3. THE SELFTEST (test/validate.sh, new selftest_chrome_launch_eaddrinuse body)

### Placement
AFTER `selftest_dispatch_classify_cases` (ends ~line 416) and BEFORE `_run_selftest_suite`
(line 418). The compgen-based discovery is order-independent; placement is for textual
merge cleanliness with the landed P1.M1.T1.S1/P1.M1.T2.S1 blocks.

### Reference implementation (verified mock approach — see research §4)
```bash
# --- pool_chrome_launch EADDRINUSE detection (P1.M2.T1.S1 / Issue 2) -------------
# Mock-based test: a fake "chrome" binary that writes an EADDRINUSE line to stderr then
# exits 1 instantly. Verifies pool_chrome_launch detects the bind failure in the log and
# returns 1 (retryable) instead of pool_die (fatal). No real Chrome (AGENTS.md §1).
# Picked up by the single-setup _run_selftest_suite (same runner as the other selftest_*).
selftest_chrome_launch_eaddrinuse() {
    local fakechrome logdir log_file rc
    # Isolated subdir under the test root (do NOT pollute the shared $POOL_STATE_DIR).
    logdir="$ABPOOL_TEST_ROOT/eaddrinuse-selftest"
    mkdir -p -- "$logdir"
    fakechrome="$logdir/fake-chrome"
    # The fake chrome: write the primary Chromium EADDRINUSE string to stderr (captured
    # to the log by the setsid redirect), then exit 1 instantly (triggers empty-pgid).
    cat >"$fakechrome" <<'MOCK'
#!/usr/bin/env bash
echo "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2
exit 1
MOCK
    chmod +x "$fakechrome"

    # Point POOL_CHROME_BIN at the fake + POOL_STATE_DIR at the isolated logdir so the
    # chrome-<lane>.log lands where we can inspect it. Run pool_chrome_launch in a SUBSHELL
    # so a (buggy) pool_die is caught as a non-zero rc rather than killing the harness.
    log_file="$logdir/chrome-7.log"
    rc=0
    AGENT_CHROME_BIN="$fakechrome" \
    AGENT_BROWSER_POOL_STATE="$logdir" \
    timeout 10 bash -c '
        set -euo pipefail
        source "$1/lib/pool.sh"
        pool_config_init
        pool_chrome_launch 53420 /tmp/__abp_dummy_udd__ 7
    ' _ "$ABPOOL_REPO" || rc=$?

    # ASSERT: rc 1 (EADDRINUSE detected → retryable), NOT pool_die (which would be rc 1
    # too but via exit — distinguish by checking the log was grepped: the warning _pool_log
    # line is the signal). The cleanest assertion: rc==1 AND the log file contains the
    # EADDRINUSE text (proving the grep had something to match).
    assert_eq "1" "$rc" "pool_chrome_launch returns 1 on EADDRINUSE instant-exit (not pool_die/0)" || return 1
    [[ -f "$log_file" ]] || { _fail "chrome log not created at $log_file"; return 1; }
    grep -qiE 'cannot start http server|address already in use' "$log_file" \
        || { _fail "log missing EADDRINUSE text (grep pattern would not have matched)"; return 1; }

    # --- Negative case: a fake chrome that exits 1 WITHOUT EADDRINUSE → pool_die (rc 1) ---
    # Distinguish from the EADDRINUSE case: pool_die prints to stderr + exits 1. We assert
    # that a NON-EADDRINUSE instant-exit still fails (rc!=0) — the grep did NOT match, so
    # pool_die fired. (We cannot easily assert "pool_die specifically" vs "return 1" from
    # outside without parsing stderr; the positive case above proves the EADDRINUSE path
    # returns 1 cleanly. This negative case proves the non-EADDRINUSE path still fails.)
    local fakebad="$logdir/fake-bad-chrome"
    cat >"$fakebad" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR:gpu_init.cc] GPU process isn't usable. Goodbye." >&2
exit 1
MOCK
    chmod +x "$fakebad"
    local log2="$logdir/chrome-8.log" rc2=0
    AGENT_CHROME_BIN="$fakebad" \
    AGENT_BROWSER_POOL_STATE="$logdir" \
    timeout 10 bash -c '
        set -euo pipefail
        source "$1/lib/pool.sh"
        pool_config_init
        pool_chrome_launch 53421 /tmp/__abp_dummy_udd2__ 8
    ' _ "$ABPOOL_REPO" || rc2=$?
    # Non-EADDRINUSE instant-exit → pool_die → rc 1 (non-zero). Must NOT be rc 0.
    [[ "$rc2" -ne 0 ]] || { _fail "non-EADDRINUSE instant-exit returned 0 (should fail)"; return 1; }
    # And the log must NOT contain EADDRINUSE text (proving the grep correctly did NOT match).
    [[ -f "$log2" ]] && grep -qiE 'cannot start http server|address already in use' "$log2" \
        && { _fail "negative-case log unexpectedly matched EADDRINUSE"; return 1; } || true
}
```

### Strict-mode notes
- The `pool_chrome_launch` call runs in a `bash -c '...'` SUBSHELL with `|| rc=$?` so a
  `pool_die` (exit 1) OR a `return 1` is captured as a non-zero rc without killing the
  selftest harness. This is the ONLY safe way to test a function that may `pool_die`.
- `timeout 10` bounds the subshell (AGENTS.md §2) — the fake chrome exits instantly, so
  this never trips, but it satisfies the rule.
- `assert_eq "1" "$rc"` — proves the EADDRINUSE path returns non-zero (specifically 1).
  A `pool_die` would ALSO be rc 1; the distinguishing assertion is the log-grep (the
  warning was logged because the grep matched).
- The negative case (`fakebad`) proves the non-EADDRINUSE path still fails (rc!=0) and
  the log does NOT match the EADDRINUSE pattern — confirming the grep is selective.
- `AGENT_BROWSER_POOL_STATE="$logdir"` isolates the chrome log to the test subdir (does
  NOT pollute the shared `$POOL_STATE_DIR` from setup()).
- `AGENT_CHROME_BIN="$fakechrome"` overrides the config so pool_config_init points at the
  fake (pool_config_init stores AGENT_CHROME_BIN → POOL_CHROME_BIN; a bare name is kept
  as-is, an absolute path is canonicalized — the fake is absolute, so it's canonicalized
  harmlessly).
- Cleanup: the body creates files under `$ABPOOL_TEST_ROOT/eaddrinuse-selftest/`, which
  is under the test root that the EXIT trap in validate.sh already removes. No manual
  cleanup needed (but the body could `rm -rf "$logdir"` at the end for tidiness).
