# Agent Browser Pool — configuration & reference

Detailed lookup material for the `agent-browser-pool` skill. Read this when you need exact
env-var values, the full command dispatch table, the acquire lifecycle, or a
troubleshooting matrix. For the procedural "how to use your lane" guide, see `SKILL.md`.

All of this reflects the shipped behavior in `lib/pool.sh` (`pool_config_init`,
`pool_wrapper_main`, `pool_admin_*`). Defaults assume the standard
install; this host may override any of them via environment.

## Environment variables (all optional)

Every path is resolved to an **absolute** path before any subprocess — a bare `~` is never
passed to Chrome, `rm`, or a log. "Truthy" means `1`/`true`/`yes`/`on` (case-insensitive).

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `~/.local/state/agent-browser-pool` | state dir: `lanes/<N>.json` leases, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log` |
| `AGENT_CHROME_MASTER` | `${XDG_CONFIG_HOME:-~/.config}/google-chrome` | CoW source — your real Chrome user-data-dir. Agents copy current state on each acquire, so new logins propagate. May be live/in-use (PRD §2.7). **Never launch, mutate, or delete.** |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/` (deleted on release) |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL `agent-browser` CLI (bare name → `command -v`; a path → `-f -x`; stays upgradable) |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; a path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | number of ports → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (seconds) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | truthy → launch Chrome with `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | truthy → permit a real (slow) ~4.8 GB copy per acquire |
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
| `ABPOOL_OWNER` | unset = harness-ancestor ownership | any non-empty value (recommended: `caller`) → key lane ownership on the calling process itself (`$$`) instead of the harness ancestor → each parallel subprocess gets its own lane, reaped when it exits. See the "Caller-scoped lanes" subsection. The recognized-harness fail-fast does not apply in caller mode |
| `ABPOOL_LANE` | unset = auto-assign (lowest free lane) | positive integer N → pin lane N: adopt it if free or stale (reaping a stale lease first); a live lease owned by another process → hard error — **never a takeover**. Malformed value (not a positive integer) → hard error at startup, before any lane work. For deterministic assignment ("scraper X always gets lane 3"), not for reaching another agent's lane |

The three that most affect behavior:

- **`AGENT_CHROME_MASTER`** — the CoW source, defaulting to your real Chrome user-data-dir
  (`~/.config/google-chrome`). Agents copy it fresh on each acquire, so new logins/auth you
  create in Chrome propagate to agents automatically. It may even be live/in-use (PRD §2.7).
  Point it at a dedicated template if you want a fixed source instead.
- **`AGENT_CHROME_ALLOW_SLOW_COPY`** — on non-btrfs the wrapper refuses the expensive copy
  by default; set this only if you accept a slow acquire.
- **`AGENT_CHROME_HEADLESS`** — off by default (trusted profiles must look real; headless is
  detectable). Set it for headless/server hosts.

> **Test-only hooks** (not for users): `AGENT_BROWSER_POOL_OWNER_PID` and
> `AGENT_BROWSER_POOL_OWNER_STARTTIME` simulate distinct agent owners without a real `pi`
> ancestor. Never set these in normal use.

### Caller-scoped lanes (orchestrator mode)

With `ABPOOL_OWNER` set to any non-empty value (recommended: `caller`), lane ownership keys
on the **calling process** — the subprocess that invoked `agent-browser-pool` — instead of the
recognized-harness ancestor. One orchestrator session can run many parallel browser-driving
subprocesses, each transparently getting its own lane.

- **Parent-pid semantics.** The owner is the process that invoked the pool command; the pool
  records its pid + starttime. If that parent is already dead or reparented, the command
  fails fast: `pool_die`: "agent-browser-pool: ABPOOL_OWNER=caller requires a live parent
  process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived
  orchestrator process" — an owner that died on arrival would claim an instantly-stale lane.
- **Auto-reap.** When the subprocess exits, its lane is reaped by the existing lazy reaper
  (on the next acquire or `reap`) → no manual cleanup needed.
- **Fail-fast exemption.** The recognized-harness fail-fast does **not** apply in caller mode
  → caller mode with no harness ancestor is fine.
- **Default path unchanged.** With `ABPOOL_OWNER` unset, ownership keys on the harness
  ancestor exactly as before.

Typical usage — parallel scrapers from one orchestrator session:

```bash
ABPOOL_OWNER=caller .venv/bin/python scrapers/linkedin_discover.py --no-ping &
ABPOOL_OWNER=caller .venv/bin/python scrapers/indeed_discover.py --no-ping &
wait
```

Each subprocess resolves to its own lane; each lane is reaped when its subprocess exits.

### Lane pinning (ABPOOL_LANE)

With `ABPOOL_LANE=<N>` set (a positive integer), auto-assignment is skipped and lane N is
used directly. This is the narrative expansion of the `ABPOOL_LANE` row in the env-var
table above — the two env-table rows are the summary; this subsection is the full semantics.

- **Free or stale lane → take it.** A free lane is claimed normally. A stale lease is
  reaped first, then the lane is claimed — even a responsive orphan Chrome is **not**
  adopted under a pin; the pin guarantees deterministic fresh state.
- **Live lease owned by you → idempotent reuse.** Same lane, same browser; the call echoes
  lane N and succeeds (rc 0) like any reuse.
- **Live lease owned by another process → hard error. Never a takeover.** The acquire dies
  inside the critical section with:
  `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`
  and the wrapper terminates with:
  `agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)`
  There is no wait (the `AGENT_BROWSER_POOL_WAIT` exhaustion path does not apply to a pin)
  and no force-reap — a pinned lane is **never** a takeover.
- **You already hold a different live lane → hard error.** Quoting verbatim:
  `owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE`
- **Malformed value → hard error at startup.** Anything that is not a positive integer
  (`03`, `abc`, `0`, `-2`) dies in `pool_config_init`, before any lane work (pre-flock,
  every verb):
  `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw value>'`
  Empty/unset means auto-assign as usual.

Pinning works in **both owner modes** — the default harness-ancestor ownership and
`ABPOOL_OWNER=caller` (see the *Caller-scoped lanes* subsection above) — and pinned lanes
obey the same reaping rules as any lane: when the owner dies, the lease goes stale and is
reaped by the next acquire or an explicit `reap`.

The purpose is deterministic assignment ("scraper X always gets lane 3"), **not** reaching
another live agent's lane — the live-foreign hard error preserves cross-agent isolation.

Typical usage — a worker pinned to a specific lane in caller mode:

```bash
ABPOOL_LANE=3 ABPOOL_OWNER=caller ./scrape.sh   # worker pinned to lane 3
```

## Command dispatch: pool verbs vs. driving

The entry-point dispatcher (`bin/agent-browser-pool`) splits each invocation **before** any
lane work. Decisions (in order, first match wins):

1. **Pool verb** → admin function (no lane — no Chrome, no owner resolution):
   `status`, `reap`, `release [<N>|all]`, `doctor`, `--help`/`-h`/`help`. A bare
   `agent-browser-pool` (no arguments) defaults to `status`. These print pool state or
   the pool's own help and never touch a browser.
2. **Everything else → DRIVING** → `pool_wrapper_main`: resolve the owning recognized-harness PID; if
   there is no recognized-harness ancestor, **fail-fast** (`pool_die`: "agent-browser-pool: driving
   commands require a supported agent harness (pi/claude/codex/agy)... For raw browser use without pooling, call
   'agent-browser' directly."). With `ABPOOL_OWNER` set (caller mode), ownership keys on the calling
   process instead — no harness ancestor is required (see *Caller-scoped lanes* above). Otherwise
   acquire/reuse the caller's lane, strip any
   `--session`, force `AGENT_BROWSER_SESSION=abpool-<N>`, and exec the real binary with
   the cleaned args.

### Driving commands (use your lane)

Every non-pool-verb token is a driving command — it resolves the caller's owner identity,
fails fast without a recognized-harness ancestor, and runs scoped to the caller's own lane. This
includes:

- `open <url>`, `connect <port|url>` (arg ignored — pool owns connection), `close [--all]`
- `get <resource>` (e.g. `get cdp-url`), `screenshot`, scrape/automate commands
- `--version`, `skills`, `dashboard`, `plugin`, `mcp`, `session list` — all driving now
  (they previously short-circuited to an unchanged exec; that path is removed for lane
  isolation: a caller-supplied `--session <X>` must never target another lane)
- A flags-only invocation (e.g. `agent-browser-pool --json`) — driving (fails fast
  without a `pi` ancestor, same as any unrecognized verb)
- **Any unrecognized command** (defaults to driving, so unknown verbs still get a lane)

> There is no "meta / passthrough" class. The only commands that run without a lane are
> the pool verbs above, caught by `bin/agent-browser-pool` before `pool_wrapper_main`.
> See "Admin CLI" below.

## How acquire works (the lifecycle)

For a driving command under a supported harness:

```
agent-browser-pool open <url>
 │ 1. resolve owning harness PID (walk ppid → first ancestor whose comm is in $POOL_HARNESSES); record (pid, starttime) identity
 ├─ already hold a lease for me?  → reuse my lane (skip boot)
 ├─ else acquire (under flock):
 │     reap stale lanes → reuse an orphaned-but-live lane  OR
 │     CoW-copy master → ephemeral → pick a free port → launch Chrome (setsid pgroup) →
 │     wait for CDP → connect the agent-browser daemon
 ├─ ensure connected (reconnect if the daemon died since last call)
 ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
 └─ exec the real agent-browser with cleaned args   (process replacement)
```

Lane identity is keyed on the owning harness **PID + starttime** (not PID alone — PID recycling
is real). That triple is what guarantees a crashed agent's lane is detected as stale and
reclaimed, and that a recycled PID can never hijack your lane. In caller mode (`ABPOOL_OWNER` set) the same
**PID + starttime** identity keys on the invoking subprocess instead of the harness ancestor —
the same staleness/reuse guarantees apply.

## Release lifecycle (teardown)

Release happens when **any** of these occurs:

- **Your owning harness process exits** → the lane becomes stale → the next acquire's reaper
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
| Wrong browser / no lane acquired | Driving command run outside a supported harness (no recognized-harness ancestor → fail-fast) | Run your browser work under a supported harness; for raw browser use call `agent-browser` directly |
| `connect <port>` "did nothing" | By design — the pool owns the connection and drops your arg | It worked; your lane is already connected. Use `agent-browser-pool status` to confirm |
| `agent-browser-pool` call is slow but eventually connects | Pool exhausted (all lanes busy); self-healing reaper running | Wait; it reaps dead owners and force-reclaims after `AGENT_BROWSER_POOL_WAIT` (600s). Don't boot Chrome directly |
| `agent-browser-pool` call **fails to boot** / never connects (errors, or no progress across retries) | **Not** exhaustion — a boot that fails does so identically every time (Chrome/profile/port/resource problem); will **not** self-heal | Run `agent-browser-pool doctor`; if it reports problems or the failure repeats, **stop retrying and escalate to the operator** — don't loop, don't boot Chrome directly, don't `release all` (kills peers' lanes) |
| `close` didn't free my lane / Chrome still running | By design — `close` is disconnect-only; lane survives for reuse | End your session to release; or ask the operator to run `release <N>` |
| Session logins/cookies didn't persist | Ephemeral profile is deleted on release, never written to master | By design — re-establish each session |
| `status` shows my lane as `disconnected` | Daemon dropped but Chrome alive | Your next driving command re-binds automatically |
| `status` shows my lane as `STALE` / field `?` | Owner process died or lease is corrupt | The reaper will reclaim it; the operator can run `reap` |
| `doctor` reports WARN lines | Cruft from crashed agents (orphan dirs, dead Chrome, stale leases, disconnected daemon) | Operator-only: `agent-browser-pool reap` clears stale lanes **and** orphan dirs; `release <N>` / `release all` for explicit teardown |
| Pinned-lane call dies: "pinned lane N is held by a live owner (pid …, comm …); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane" | `ABPOOL_LANE=N` but lane N has a live lease owned by another process | By design — a pinned lane is never a takeover and never waits; unset `ABPOOL_LANE`, pick a free lane, or wait for that owner to release |
| Pool dies at startup: "agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw>'" | `ABPOOL_LANE` is malformed (non-numeric, `0`, negative, leading zeros) | Fix the value to a positive integer or unset it (auto-assign) |
| Caller-mode call dies: "agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid …); invoke agent-browser-pool as a child of the long-lived orchestrator process" | The invoking subprocess's parent is dead/reparented (an instantly-stale owner) | Invoke `agent-browser-pool` as a child of the long-lived orchestrator process |

## Admin CLI (operator-facing)

`agent-browser-pool` is the **operator** admin tool. With no command, `status` is assumed.
**Read-only and safe for any process:** `status`, `doctor`. **Mutating — operator use:**
`reap`, `release [<N>|all]`. As an agent, prefer leaving teardown to the automatic reaper
and only touch these if asked.

```
agent-browser-pool                 # status (default)
agent-browser-pool status
agent-browser-pool reap            # tear down stale-owner lanes + remove orphan dirs
agent-browser-pool release 1       # explicit teardown of one lane
agent-browser-pool release all     # clear the whole pool
agent-browser-pool doctor          # diagnose the pool (exits 1 on a blocking FAIL only; WARNs are advisory)
agent-browser-pool help            # aliases: --help, -h
```
