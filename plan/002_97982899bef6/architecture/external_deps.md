# External Dependencies — Plan 002 Validation

All dependencies were verified present and unchanged from Plan 001.

## Runtime Dependencies (unchanged)

| Dependency | Version/Status | Usage | PRD § |
|---|---|---|---|
| `agent-browser` | ≥ 0.28.0 (Vercel, Rust CLI) | The REAL binary; called by absolute path on every driving command | §2.16 |
| `google-chrome-stable` | system | Chrome browser; launched per-lane via `setsid` | §2.6 |
| `btrfs` | filesystem at pool root | Enables `cp --reflink=always` CoW copies | §2.7 |
| `flock` | util-linux | Global acquire lock | §2.4 step 3 |
| `setsid` | util-linux | Chrome process group isolation | §2.6 |
| `pgrep`/`pkill` | procps-ng | Owner liveness checks | §2.8 |
| `cp --reflink` | coreutils | CoW profile copy | §2.7 |
| `curl` | system | CDP probing (`/json/version`) | §2.4 step 3h |
| `jq` | system | Lease JSON I/O | §2.8 |
| `notify-send` | libnotify (optional) | Exhaustion alerts | §2.9 |
| `/proc` | Linux | PID/stat/comm/starttime | §2.8 |

## agent-browser CLI Behavior (Verified from Codebase Usage)

The pool interacts with `agent-browser` via these specific operations:

1. **`agent-browser --session <name> connect <port>`** — Binds the named daemon
   to a Chrome on the given port. Used in `pool_daemon_connect` (lib/pool.sh:1689).
   Idempotent (can reconnect).

2. **`agent-browser --session <name> get cdp-url`** — Liveness check: returns 0
   when the daemon is connected, non-zero otherwise. Used in
   `pool_daemon_connected` (lib/pool.sh:1747) and `pool_ensure_connected`
   (lib/pool.sh:2412).

3. **`agent-browser --session <name> close`** — Disconnects the daemon from
   Chrome (daemon-session teardown only; does NOT kill Chrome). Used in
   `pool_release_lane` (lib/pool.sh:2576).

4. **`AGENT_BROWSER_SESSION=<name> agent-browser <verb> <args>`** — Routes a
   driving command to the daemon's Chrome. The pool's terminal `exec` in
   `pool_wrapper_main` (lib/pool.sh:3740).

5. **`agent-browser --version`** — Version check. PRD §2.16 notes this as a
   future doctor improvement (currently doctor checks executability only).

## What's NOT a Dependency Change

This pivot does NOT add or remove any external dependencies. The real
`agent-browser` binary continues to be called by absolute path
(`$POOL_REAL_BIN`, default `~/.local/bin/agent-browser`). The only change is
that it is NO LONGER shadowed by a wrapper shim on PATH — it is invoked
directly by the pool's `pool_wrapper_main` terminal `exec`, and by users who
want raw browser access.

## install.sh Dependency Changes

The old install.sh required `~/scripts` to precede `~/.local/bin` on `$PATH`.
This requirement is **removed**. The new install.sh only needs:
- `$HOME/.local/bin` to exist (created if missing)
- `ln` (coreutils) for the symlink
- The repo files `bin/agent-browser-pool` + `lib/pool.sh` to exist + be executable
