# Agent Browser Pool — configuration & reference

Detailed lookup material for the `agent-browser-pool` skill. Read this when you need exact
env-var values, the full command dispatch table, the acquire lifecycle, or a
troubleshooting matrix. For the procedural "how to use your lane" guide, see `SKILL.md`.

All of this reflects the shipped behavior in `lib/pool.sh` (`pool_config_init`,
`pool_dispatch_classify`, `pool_wrapper_main`, `pool_admin_*`). Defaults assume the standard
install; this host may override any of them via environment.

## Environment variables (all optional)

Every path is resolved to an **absolute** path before any subprocess — a bare `~` is never
passed to Chrome, `rm`, or a log. "Truthy" means `1`/`true`/`yes`/`on` (case-insensitive).

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `~/.local/state/agent-browser-pool` | state dir: `lanes/<N>.json` leases, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log` |
| `AGENT_CHROME_MASTER` | `~/.agent-chrome-profiles/master-profile` | static master template — CoW source. **Never launch, mutate, or delete.** |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/` (deleted on release) |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL `agent-browser` CLI (called by absolute path; stays upgradable) |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; a path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | number of ports → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (seconds) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | truthy → launch Chrome with `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | truthy → permit a real (slow) ~4.8 GB copy per acquire |
| `AGENT_BROWSER_POOL_DISABLE` | unset = **pooling active** | truthy → per-process passthrough (safety valve; see pitfalls) |

The three that most affect behavior:

- **`AGENT_BROWSER_POOL_DISABLE`** — the safety valve. Set it truthy in ONE shell and that
  process bypasses pooling entirely (raw upstream tool, no lane). Per-process, not global.
- **`AGENT_CHROME_ALLOW_SLOW_COPY`** — on non-btrfs the wrapper refuses the expensive copy
  by default; set this only if you accept a slow acquire.
- **`AGENT_CHROME_HEADLESS`** — off by default (trusted profiles must look real; headless is
  detectable). Set it for headless/server hosts.

> **Test-only hooks** (not for users): `AGENT_BROWSER_POOL_OWNER_PID` and
> `AGENT_BROWSER_POOL_OWNER_STARTTIME` simulate distinct agent owners without a real `pi`
> ancestor. Never set these in normal use.

## Command dispatch: meta vs. driving

The wrapper classifies each invocation **before** touching a lane. Decisions (in order, first
match wins) from `pool_wrapper_main`:

1. `AGENT_BROWSER_POOL_DISABLE` truthy → **passthrough** (no lane, raw upstream).
2. **meta** command → **passthrough** (no lane).
3. No `pi` ancestor in the process tree → **passthrough** (human in a terminal).
4. Otherwise → acquire/find your lane, then run the command against it.

### Meta commands (passthrough — never acquire a lane)

- `--help`, `-h`, `--version`
- `skills`, `dashboard`, `plugin`, `mcp`
- `session list`
- A bare `agent-browser` with **no subcommand** (upstream prints help)

### Driving commands (use your lane)

Everything else, including:

- `open <url>`, `connect <port|url>` (arg ignored — pool owns connection), `close [--all]`
- `get <resource>` (e.g. `get cdp-url`), `screenshot`, scrape/automate commands
- **Any unrecognized command** (defaults to driving, so unknown verbs still get a lane)

## How acquire works (the lifecycle)

For a driving command under `pi` with pooling active:

```
agent-browser open <url>
 │ 1. resolve owning pi PID (walk ppid → comm == 'pi'); record (pid, starttime) identity
 ├─ already hold a lease for me?  → reuse my lane (skip boot)
 ├─ else acquire (under flock):
 │     reap stale lanes → reuse an orphaned-but-live lane  OR
 │     CoW-copy master → ephemeral → pick a free port → launch Chrome (setsid pgroup) →
 │     wait for CDP → connect the agent-browser daemon
 ├─ ensure connected (reconnect if the daemon died since last call)
 ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
 └─ exec the real agent-browser with cleaned args   (process replacement)
```

Lane identity is keyed on the owning `pi` **PID + starttime** (not PID alone — PID recycling
is real). That triple is what guarantees a crashed agent's lane is detected as stale and
reclaimed, and that a recycled PID can never hijack your lane.

## Release lifecycle (teardown)

Release happens when **any** of these occurs:

- **Your owning `pi` process exits** → the lane becomes stale → the next acquire's reaper
  (or `agent-browser-pool reap`) tears it down. This is the normal path for agents.
- **Explicit `agent-browser-pool release <N>` / `release all`** → operator-driven teardown.
- **Pool exhaustion** → after `AGENT_BROWSER_POOL_WAIT`, the oldest dead-owner lane is
  force-reclaimed (with a desktop alert + `alerts.log` entry).

Release = kill the Chrome **process group** (`SIGTERM` → `SIGKILL`), `rm -rf` the ephemeral
profile dir, drop the lease. There is **no idle TTL** — a lane persists until its owner dies
or it's explicitly released.

`close` is **not** release: it disconnects the daemon only; the lane, Chrome, and ephemeral
dir survive for reuse within the session.

## Troubleshooting matrix

| Symptom | Likely cause | Fix / response |
|---|---|---|
| Wrong browser / no lane acquired | Passthrough: no `pi` ancestor, or `AGENT_BROWSER_POOL_DISABLE` truthy | Run under `pi`; `unset AGENT_BROWSER_POOL_DISABLE` |
| `connect <port>` "did nothing" | By design — the pool owns the connection and drops your arg | It worked; your lane is already connected. Use `agent-browser-pool status` to confirm |
| `agent-browser` call hangs a long time | Pool exhausted (all lanes busy); self-healing reaper running | Wait; it reaps dead owners and force-reclaims after `AGENT_BROWSER_POOL_WAIT` (600s). Don't boot Chrome directly |
| `close` didn't free my lane / Chrome still running | By design — `close` is disconnect-only; lane survives for reuse | End your session to release; or ask the operator to run `release <N>` |
| Session logins/cookies didn't persist | Ephemeral profile is deleted on release, never written to master | By design — re-establish each session |
| `status` shows my lane as `disconnected` | Daemon dropped but Chrome alive | Your next driving command re-binds automatically |
| `status` shows my lane as `STALE` / field `?` | Owner process died or lease is corrupt | The reaper will reclaim it; the operator can run `reap` |
| `doctor` reports WARN lines | Cruft from crashed agents (orphan dirs, dead Chrome, stale leases) | Operator-only: `agent-browser-pool reap` then `release <N>` / `release all` |

## Admin CLI (operator-facing)

`agent-browser-pool` is the **operator** admin tool. With no command, `status` is assumed.
**Read-only and safe for any process:** `status`, `doctor`. **Mutating — operator use:**
`reap`, `release [<N>|all]`. As an agent, prefer leaving teardown to the automatic reaper
and only touch these if asked.

```
agent-browser-pool                 # status (default)
agent-browser-pool status
agent-browser-pool reap            # tear down lanes whose owner died
agent-browser-pool release 1       # explicit teardown of one lane
agent-browser-pool release all     # clear the whole pool
agent-browser-pool doctor          # diagnose the pool (exits 1 if unhealthy)
agent-browser-pool help            # aliases: --help, -h
```
