---
name: agent-browser-pool
description: Drive a browser through agent-browser-pool — get a dedicated, isolated Chrome profile lane, reuse it across calls, and tear it down correctly. Use whenever you run agent-browser-pool to open pages, connect, close, scrape, or automate.
---

# Agent Browser Pool — how to use your Chrome lane

`agent-browser-pool <verb> <args>` is your one browser command. It is not a wrapper around
some other tool — it is the explicit tool you call. Every call means *your own locked Chrome
with a dedicated ephemeral profile*, for the lifetime of your session:

- **1 agent = 1 browser.** No other agent shares your lane, and you cannot reach theirs.
- **Dedicated profile.** It starts from a trusted master template (Google login, password
  manager, the agent-browser extension are already present).
- **One browser for the whole session.** Your first driving call boots it; every later call
  reuses it.

**The command never names a lane.** `agent-browser-pool <verb> <args>` is **identical every
time** — the same on lane 1 or lane 99. Your lane is selected by your own process identity
(your owning `pi` process and its start time), never by an argument. You do not — and cannot —
pass a lane number, port, or session.

**You do not manage lanes — `agent-browser-pool` does. Just type the command.** That is the
entire API. The sections below exist so you understand what is happening and don't fight the pool.

## 1. Get + connect to your lane (acquire is automatic)

Your lane is acquired on your **first driving command**. There is no separate "create lane" or
"connect to port" step for you to run:

```bash
agent-browser-pool open https://example.com     # this single call does everything
```

Behind the scenes it:
1. Finds a free lane just for you, keyed on your owning `pi` process (and its start time, so a
   recycled PID can never steal your lane).
2. Copy-on-writes a fresh profile from the master template.
3. Launches Chrome on the lane's port, connects the daemon, and pins your session to `abpool-<N>` (you never type this).

After that, **every** driving call in your session routes to that same lane/browser/profile.
You do not reconnect between calls.

### Connection rules (don't fight the pool)

- **Do not pass a port or CDP URL.** The pool owns the connection. If you type
  `agent-browser-pool connect <port>` / `connect <url>`, the argument is silently dropped and
  the call routes to your already-connected lane. A bare `agent-browser-pool connect` is an
  automatic no-op success.
- **Do not pass `--session <name>`.** The pool strips it and forces
  `AGENT_BROWSER_SESSION=abpool-<N>`. If you pass one anyway, it is harmlessly overridden.
- These overrides are intentional: the pool owns connection + session + lifecycle so the
  command is the same regardless of which lane you're on.

### Which commands trigger a lane

**Driving** commands acquire/use your lane. They include `open`, `connect`, `close`, `get`,
`screenshot`, `click`, `type`, `eval`, `find`, and **any unrecognized command** — an unknown
verb still gets your lane rather than erroring out.

A small set of **meta** commands pass straight through to the real `agent-browser` WITHOUT
acquiring a lane (so they work with no lane): `skills`, `--version`, `session list`,
`dashboard`, `plugin`, and `mcp`. (The pool's own verbs — `status`, `reap`, `release`,
`doctor`, and `help`/`--help`/`-h` — run pool functions, not the real binary; see §2 and §3.)
See `references/configuration.md` for the full dispatch table.

## 2. Tear down when you're finished

### `close` is NOT a teardown — it's a disconnect

```bash
agent-browser-pool close          # disconnects your lane's daemon ONLY
agent-browser-pool close --all    # also safe: --all is stripped and scoped to YOUR lane
```

`close` detaches the daemon↔Chrome binding but **leaves the browser and profile alive for
reuse** within your session. Your next driving command re-binds automatically. Use `close`
mid-session to drop the connection; do not mistake it for "release." `--all` is safe because
the pool strips it and forces `--session abpool-<N>` — it can never kill a peer's session.

### The real teardown is automatic

**Just end your session normally.** When your owning `pi` process exits, the lane is released:
the Chrome process group is killed, the ephemeral profile directory is deleted, and the lease
is dropped. You normally do nothing explicit.

Corollary: **the profile is ephemeral.** Anything you change during the session (new logins,
cookies, downloads, history) lives only in your lane's copy and is **deleted on release** —
never written back to the master template. Re-establish session state each time; don't expect
it to survive.

### Do NOT run pool admin commands as routine cleanup

`agent-browser-pool release <N>`, `release all`, and `reap` are **operator** tools.
Critically, `release <N>` is **not** scoped to your lane — releasing the wrong number (or
`all`) tears down **other agents'** lanes. Run them only if a human operator explicitly asks
you to. The correct agent teardown is: stop using the browser and let your session end.

## 3. Safety

### Inspect your lane (read-only, always safe)

```bash
agent-browser-pool status     # read-only table of all active lanes
agent-browser-pool doctor     # read-only diagnostic of the whole pool
```

In `status`, find your row by your working directory / owner PID. The `STATE` column is:

- `live` — Chrome reachable.
- `disconnected` — lane leased but the daemon dropped; your next driving call re-binds.
- `STALE` — owner process died (the reaper will reclaim it on the next acquire).

### Safety & identity rules (non-negotiable)

Each ephemeral profile starts as a clone of the master identity:

- **Never enter credentials; never unlock a password manager.** Existing SSO/Google login is
  fine to *use*; never type a password.
- **Verify the target URL before every click/fill/navigate.**
- **Never drive the source profile directly, and never launch `google-chrome-stable` yourself.**
  The source (your real `~/.config/google-chrome`) is only ever **copied** — agents drive ephemeral
  CoW copies, never the source. A direct Chrome launch bypasses the pool, conflicts with it, and
  risks mutating the master.
- **Isolation by construction.** Because no command accepts a lane selector, you physically
  cannot reach another agent's lane through normal tool use. The next agent gets the next free
  lane.

## 4. Common pitfalls

- **"I ran a driving command outside `pi` and it errored."** By design: driving commands
  require a `pi` ancestor — that is how your lane is keyed to you. The call fails fast with an
  actionable message pointing you at the real `agent-browser` for raw browser use. Run your
  browser work under `pi`; don't try to bypass it.
- **"My `agent-browser-pool` call hangs a long time."** The pool may be **exhausted** (all
  lanes busy). It self-heals — it reaps dead owners and, after `AGENT_BROWSER_POOL_WAIT`
  (default 600s), force-reclaims one. Do **not** try to "fix" this by booting Chrome directly.
- **Don't confuse `close` with release.** `close` keeps your browser alive for reuse; release
  (which happens automatically when your session ends) destroys it.

## 5. Reference

For the full environment-variable table, the complete meta-vs-driving dispatch classification,
the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix, read
**`references/configuration.md`**.
