---
name: agent-browser-pool
description: Drive a browser through the `agent-browser` transparent pool wrapper — get a dedicated, isolated Chrome profile lane, reuse it across calls, and tear it down correctly. Use whenever you run `agent-browser` to open pages, connect, close, scrape, or automate, and want to know how your lane is acquired, pinned to you, and released.
---

# Agent Browser Pool — how to use your Chrome lane

On this host `agent-browser` is a transparent PATH-shadowing wrapper. When you run it
under `pi`, it silently gives you your **own locked Chrome browser with a dedicated
ephemeral profile** for the lifetime of your session:

- **1 agent = 1 browser.** No other agent shares your lane, and you cannot reach theirs.
- **Dedicated profile.** It starts from a trusted master template (Google login, password
  manager, the agent-browser extension are already present).
- **One browser for the whole session.** Your first call boots it; every later call reuses it.

**You do not manage lanes — the wrapper does. Just type normal `agent-browser` commands.**
That is the entire API. The sections below exist so you understand what is happening and
don't fight the pool.

## 1. Get + connect to your lane (acquire is automatic)

Your lane is acquired on your **first "driving" command**. There is no separate
"create lane" or "connect to port" step for you to run:

```bash
agent-browser open https://example.com     # this single call does everything
```

Behind the scenes it:
1. Finds a free lane just for you, keyed on your owning `pi` process (and its start time,
   so a recycled PID can never steal your lane).
2. Copy-on-writes a fresh profile from the master template.
3. Launches Chrome on the lane's port and connects the agent-browser daemon to it.
4. Pins your session to `abpool-<N>` (you never type this).

After that, **every** `agent-browser` call in your session routes to that same
lane/browser/profile. You do not reconnect between calls.

### Connection rules (don't fight the pool)

- **Do not pass a port or CDP URL.** The pool owns the connection. If you type
  `agent-browser connect <port>` / `connect <url>`, the argument is silently dropped and
  the call routes to your already-connected lane. A bare `agent-browser connect` is an
  automatic no-op success.
- **Do not pass `--session <name>`.** The pool strips it and forces
  `AGENT_BROWSER_SESSION=abpool-<N>`. If you pass one anyway, it is harmlessly overridden.
- These overrides are intentional: commands taught by the upstream agent-browser skill
  "just work," routed to your lane.

### Which commands trigger a lane

**Driving** commands (open, connect, close, get, screenshot, scrape, automate, … and any
unrecognized command) acquire/use your lane. A small set of **meta** commands pass
straight through to the real tool WITHOUT acquiring a lane (so they work with no lane):
`skills`, `--help`/`-h`, `--version`, `session list`, `dashboard`, `plugin`, `mcp`, and a
bare `agent-browser` with no subcommand. See `references/configuration.md` for the full
dispatch table.

## 2. Tear down when you're finished

### `close` is NOT a teardown — it's a disconnect

```bash
agent-browser close          # disconnects your lane's daemon ONLY
agent-browser close --all    # also safe: --all is scoped to YOUR lane
```

`close` detaches the daemon↔Chrome binding but **leaves the browser and profile alive for
reuse** within your session. Your next driving command re-binds automatically. Use `close`
mid-session to drop the connection; do not mistake it for "release." `--all` is safe
because the pool scopes it to your lane — it can never kill a peer's session.

### The real teardown is automatic

**Just end your session normally.** When your owning `pi` process exits, the lane is
released: the Chrome process group is killed, the ephemeral profile directory is deleted,
and the lease is dropped. You normally do nothing explicit.

Corollary: **the profile is ephemeral.** Anything you change during the session (new
logins, cookies, downloads, history) lives only in your lane's copy and is **deleted on
release** — never written back to the master template. Re-establish session state each
time; don't expect it to survive.

### Do NOT run pool admin commands as routine cleanup

`agent-browser-pool release <N>`, `release all`, and `reap` are **operator** tools.
Critically, `release <N>` is **not** scoped to your lane — releasing the wrong number (or
`all`) tears down **other agents'** lanes. Run them only if a human operator explicitly
asks you to. The correct agent teardown is: stop using the browser and let your session end.

## 3. Inspect your lane (read-only, always safe)

```bash
agent-browser-pool status     # read-only table of all active lanes
agent-browser-pool doctor     # read-only diagnostic of the whole pool
```

In `status`, find your row by your working directory / owner PID. The `STATE` column is:

- `live` — Chrome reachable.
- `disconnected` — lane leased but the daemon dropped; your next driving call re-binds.
- `STALE` — owner process died (the reaper will reclaim it on the next acquire).

## 4. Common pitfalls

- **"I got the wrong / no browser."** You were in **passthrough**: either you have no `pi`
  ancestor in your process tree, or `AGENT_BROWSER_POOL_DISABLE` is set to a truthy value
  (`1`/`true`/`yes`/`on`) in your shell. Run under `pi` and unset it.
- **"My `agent-browser` call hangs a long time."** The pool may be **exhausted** (all lanes
  busy). It self-heals — it reaps dead owners and, after `AGENT_BROWSER_POOL_WAIT` (default
  600s), force-reclaims one. Do **not** try to "fix" this by booting Chrome directly.
- **Never launch `google-chrome-stable` or touch the master profile / other lanes'
  directories directly.** Always go through `agent-browser`. A direct Chrome launch bypasses
  the pool and conflicts with it (and the master profile must never be launched or mutated).
- **Don't confuse `close` with release.** `close` keeps your browser alive for reuse;
  release (which happens automatically when your session ends) destroys it.

## 5. Reference

For the full environment-variable table, the complete meta-vs-driving command dispatch
classification, the acquire lifecycle, and a symptom→cause→fix troubleshooting matrix,
read **`references/configuration.md`**.
