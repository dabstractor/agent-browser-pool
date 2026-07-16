# System Context — Bug Fix Suite (3 issues)

## Project

`agent-browser-pool` — a bash-based browser pool (`lib/pool.sh` 4570+ LOC, `bin/agent-browser-pool`,
`install.sh`, test suite under `test/`). Manages isolated Chrome profile lanes keyed on the owning
harness process identity. Runs under `set -euo pipefail`.

## Three Issues — Validated Against Current Source

All three issues were confirmed by reading `lib/pool.sh` in the working tree (static analysis only;
no Chrome booted, no shared-sandbox test runs — per AGENTS.md §1/§2). Detailed per-issue recon is in
the sibling files `recon_issue1_reaper.md`, `recon_issue2_doctor.md`, `recon_issue3_ensure_connected.md`.

### Issue 1 (Major) — Reaper unanchored `pgrep`/`pkill -f` kills other lanes' Chromes

- **Location**: `lib/pool.sh:2898-2902` (`pool_reap_orphan_dirs`, the orphan-kill block).
- **Root cause**: `pgrep -f -- "user-data-dir=$dir"` matches as a regex **substring** of the full
  `/proc/<pid>/cmdline`. Lane numbers are path components, so the pattern for orphan lane **3**
  (`…/active/3`) is a substring of lane **30** (`…/active/30`). The `pkill` kills every live lane
  whose number starts with the orphan's number.
- **Fix surface**: 5 lines (the pgrep + 2× pkill + 1× pgrep guard). Anchor the pattern to the
  lane-dir boundary: `user-data-dir=$dir( |$)` (ERE — Chrome's cmdline has the dir followed by a
  space or EOL). `$dir` is absolute; `$base` is validated `^[0-9]+$`; `.` in path is a harmless
  regex metachar (matches itself). Injection-safe.
- **Test gap**: `selftest_reap_orphan_dirs_removes_and_skips` (`test/validate.sh:826-844`) creates
  empty orphan *dirs* but NEVER spawns a Chrome process — the pgrep/pkill branch is dead code in
  the test. A regression test must spawn fake-Chrome processes with controlled argv on prefix-
  colliding lane numbers (e.g. 3 and 30) and assert only lane 3 is killed.

### Issue 2 (Minor) — `doctor` hard-FAILs on missing `ss` (contradicts its own docstring)

- **Location**: `lib/pool.sh:4258` (the `for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do`
  loop in `pool_admin_doctor`).
- **Root cause**: `ss` is in the same FAIL loop as required deps. Its absence → `fail++` → exit 1.
  But the inline comment at `lib/pool.sh:4255-4257` says "no FAIL, no WARN," and the runtime caller
  `pool_find_free_port` (`lib/pool.sh:1412-1416`) degrades silently to a curl-only probe when `ss`
  is absent (`listeners="$(ss -tlnH 2>/dev/null || true)"`).
- **Fix surface**: Remove `ss` from the `for` loop (keep `findmnt` — it IS required). Add a dedicated
  optional-`ss` block mirroring the `notify-send` pattern at `lib/pool.sh:4292-4299`:
  `printf '  %-22s MISSING (optional)\n' "ss"` with no `fail++`. Update the docstring severity model
  (`lib/pool.sh:4169`, `4176`, `4145-4149`) to list `ss` as optional.
- **Test gap**: No test asserts doctor's behavior on an `ss`-less environment. Add a test that stubs
  `command -v ss` to fail and asserts doctor's `[dependencies]` section shows `ss MISSING (optional)`
  with no FAIL and exit code driven only by genuinely-blocking failures.

### Issue 3 (Minor) — `pool_ensure_connected` skips BUG-1 identity check on both binding paths

- **Location**: `lib/pool.sh:2561-2572` (reconnect branch) and `lib/pool.sh:2597` (relaunch branch,
  `pool_wait_cdp "$port"` with a SINGLE arg → identity check disabled).
- **Root cause**: The acquire path (`_pool_launch_and_verify`, `lib/pool.sh:2297-2347`) was hardened
  with `pool_cdp_is_ours` / 3-arg `pool_wait_cdp` to prevent binding to a foreign Chrome. The per-call
  hot path `pool_ensure_connected` was NOT hardened the same way:
  - **Reconnect**: `curl -sf …/json/version` → if anything answers, `pool_daemon_connect` rebinds
    without verifying the answerer is this lane's Chrome.
  - **Relaunch**: `pool_wait_cdp "$port"` (1 arg → `check_identity=0` inside `pool_wait_cdp`).
- **Fix surface (reconnect)**: Extract `chrome_pid` from the lease (add to the jq extraction at
  `lib/pool.sh:2534`). After `curl` succeeds, call `pool_cdp_is_ours "$port" "$ephemeral_dir"
  "$chrome_pid"`. Mismatch → fall through to relaunch (do NOT rebind to foreign Chrome). Guard with
  `[[ "$chrome_pid" =~ ^[0-9]+$ ]]` so old leases without a valid pid preserve legacy behavior.
- **Fix surface (relaunch)**: Change `pool_wait_cdp "$port"` → `pool_wait_cdp "$port" "$ephemeral_dir"
  "${POOL_CHROME_PID:-}"` (3 args → identity enabled). Both `$ephemeral_dir` and `${POOL_CHROME_PID:-}`
  are already in scope (written to lease at `lib/pool.sh:2593-2594`).
- **Test impact (CRITICAL)**: `selftest_ensure_connected_rebinds_when_disconnected`
  (`test/validate.sh:560-588`) WILL BREAK with the reconnect fix. It stubs `curl() { return 0; }`
  (Chrome "alive" → reconnect branch) but has NO DevToolsActivePort file and chrome_pid=200 (not
  alive). After the fix, `pool_cdp_is_ours` returns 1 → falls through to relaunch instead of
  reconnecting. The test must be updated: either create a `DevToolsActivePort` file with the correct
  port + use a live pid, OR stub `pool_cdp_is_ours` to return 0.
- **Docstring impact**: `pool_wait_cdp` docstring (`lib/pool.sh:1689`) and `pool_cdp_is_ours`
  docstring (`lib/pool.sh:1622`) reference "the ensure_connected relaunch path" as using legacy
  probe-only behavior. After the fix, this is no longer true — both docstrings need updating.

## Cross-Cutting Concerns

### Test Infrastructure (AGENTS.md §3/§4 — CRITICAL)

- The selftest suite uses a **single-setup runner** (`_run_selftest_suite`, `test/validate.sh:886-924`):
  `setup()` is called ONCE (it spawns a sim-owner process), then each `selftest_*` function runs
  via `if "$fn"` in the MAIN shell (not a subshell, so the EXIT trap doesn't fire mid-suite).
- **Never** call `setup()` per-test. New selftests must be `selftest_*` functions and will be
  auto-picked-up by `compgen -A function | grep '^selftest_'`.
- New tests that spawn processes MUST reap them before returning (kill + wait the PID). Use
  `timeout` on any subprocess that could block.
- Tests run in isolated temp trees (`$ABPOOL_TEST_ROOT`) with redirected `HOME`, state dirs, and
  ephemeral roots. Never touch the operator's real `~/.local/state/` or `~/.agent-chrome-profiles/`.

### Issue Independence

The three issues touch **disjoint functions** and have **no code dependencies** between them:
- Issue 1: `pool_reap_orphan_dirs` (lib/pool.sh:2874)
- Issue 2: `pool_admin_doctor` (lib/pool.sh:4231)
- Issue 3: `pool_ensure_connected` (lib/pool.sh:2508)

They can be implemented in parallel (separate tasks), but should be applied to the same source tree
sequentially to avoid merge ambiguity.

### Documentation Surface

| Issue | Inline code comment (Mode A) | Docstring (Mode A) | README (Mode B) |
|-------|-----|-----|-----|
| 1 | `pool_reap_orphan_dirs` comment at ~line 2895 ("FULL ABSOLUTE … never hit") needs update | none | §reap mentions "killing any orphaned Chrome" — verify accuracy (no change expected) |
| 2 | none | doctor docstring severity model + OUTPUT contract (`lib/pool.sh:4169`, `4176`, `4148`) | §doctor `[dependencies]` list at README.md:230 doesn't mention `ss` — verify (may want to add) |
| 3 | none | `pool_wait_cdp` (`lib/pool.sh:1689`) + `pool_cdp_is_ours` (`lib/pool.sh:1622`) docstrings | none |
