# `agent-browser-pool`

A transparent PATH-shadowing wrapper around [Vercel's `agent-browser`](https://github.com/vercel/agent-browser)
that gives every AI agent its own **dedicated, locked, trusted Chrome profile** for
the lifetime of its session — with zero awareness that any pooling is happening —
and guarantees the Chrome process **and** the profile are cleaned up when the agent
finishes or crashes.

- **Not a fork.** A thin bash wrapper + a `agent-browser-pool` admin tool. The real
  `agent-browser` binary is called by absolute path and stays upgradable.
- **Ephemeral profiles.** Each acquire **copy-on-writes** a fresh profile from a
  master template (`~/.agent-chrome-profiles/master-profile`). On release the Chrome
  is killed and the ephemeral profile dir is **deleted**. Because the pool lives on
  **btrfs**, `cp --reflink=always` makes every copy instant and deduplicated.
- **1 agent = 1 browser.** Mutual exclusion via filesystem leases keyed on the
  owning `pi` process. The next agent gets the next free lane.
- **Fully invisible to agents.** They just type `agent-browser …` as the upstream
  skill teaches; the wrapper routes everything to their lane.

See **[PRD.md](./PRD.md)** for the full product requirements and technical spec.

## Status

**Design / brainstorm.** Implementation pending final confirmation of the last few
defaults (see "Open items" at the bottom of PRD.md).

## Prerequisites

1. **Master template** at `~/.agent-chrome-profiles/master-profile` — a full Chrome
   profile holding the identity every agent should start from (Google login,
   Bitwarden, the agent-browser extension). Already staged by the user. **Never
   launch Chrome directly against `master-profile`** — it is a static template; the
   wrapper CoW-copies it per lane and strips its stale `Singleton*` locks.
2. **btrfs** at `~/.agent-chrome-profiles` (already the case here) — enables
   instant, deduplicated copies.
3. **Install** (planned): `./install.sh` symlinks `bin/agent-browser` → `~/scripts/`
   (ahead of `~/.local/bin` on PATH) and `bin/agent-browser-pool` → `~/.local/bin/`.

## How it works (30-second version)

```
agent-browser open https://example.com        ← agent types this, nothing else
   │ wrapper walks ppid → owning pi PID  (stable across the agent's bash calls)
   ├─ already holds a lease?  reuse my lane
   ├─ else acquire:  reap stale  →  reuse-orphan OR  cp --reflink master→ephemeral
   │                  →  launch Chrome (anti-throttle flags)  →  connect daemon
   ├─ force AGENT_BROWSER_SESSION=abpool-<N>   (so every later call routes here)
   └─ exec real /home/dustin/.local/bin/agent-browser  with original args
```

Release (on the owning `pi` process exiting, or explicit `agent-browser-pool
release`): kill the Chrome **process group**, `rm -rf` the ephemeral dir, drop the
lease. A crashed agent → its `pi` PID dies → next acquire reaps it.
