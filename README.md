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

**MVP shipped** — transparent wrapper (`bin/agent-browser`), admin CLI
(`agent-browser-pool`), and installer (`install.sh`) are all implemented and
tested. See **Installation** below to set it up.

## Prerequisites

1. **btrfs** at the pool root (`~/.agent-chrome-profiles`). The pool copy-on-writes
   the master profile per lane; btrfs makes each `cp --reflink=always` instant and
   deduplicated. On a non-btrfs filesystem the wrapper **refuses** the slow 4.8 GB
   copy unless you set `AGENT_CHROME_ALLOW_SLOW_COPY=1`.
2. **Master template** at `~/.agent-chrome-profiles/master-profile` — a full Chrome
   profile holding the identity every agent should start from (Google login,
   Bitwarden, the `agent-browser` extension). **Never launch Chrome directly against
   `master-profile`**: it is a static template. The wrapper CoW-copies it per lane
   and strips its stale `Singleton*` locks.
3. **`agent-browser` ≥ 0.28** at `~/.local/bin/agent-browser` (supplies `--session`,
   `connect`, `get cdp-url`, and the `AGENT_BROWSER_SESSION` env var). It stays
   upgradable — the wrapper calls it by absolute path, so updating the binary just
   works.
4. **`google-chrome-stable`** (or whatever `$AGENT_CHROME_BIN` points at).

A handful of coreutils/util-linux tools are also required (`flock`, `setsid`,
`pgrep`, `pkill`, `cp`, `curl`, `jq`; `notify-send` is optional). Run
`agent-browser-pool doctor` to verify the whole stack — see
[Admin commands](#admin-commands).

## Installation

`install.sh` is the cutover installer. It symlinks `bin/agent-browser` →
`~/scripts/agent-browser` (which **precedes** `~/.local/bin` on your `PATH`, so the
wrapper **shadows** the real CLI process-wide), symlinks `bin/agent-browser-pool` →
`~/.local/bin/agent-browser-pool`, pre-creates the pool state dir, and runs `doctor`
to verify dependencies.

> **Cutover warning (read before installing).** This is **all-or-nothing**: the
> PATH-shadowing mechanism has no safe partial mode, and the only per-session opt-out
> is `AGENT_BROWSER_POOL_DISABLE=1`. Once installed, **running agents on the OLD
> workflow are silently intercepted** — their next `agent-browser` call is routed to
> a fresh ephemeral lane, abandoning any in-progress work on persistent profiles. Do
> not install while critical agents are mid-task.

Because the cutover is deliberate and not automatic, `install.sh` prints the warning
above and asks you to type `YES`:

```bash
./install.sh            # prints the cutover warning, asks you to type YES
./install.sh --force    # scripted / re-install (skips the YES prompt)
./install.sh --help     # show help
```

**Test before cutover** by invoking the wrapper **by absolute path** — this
exercises every line of logic *without* touching the PATH-resolved `agent-browser`
that running agents use:

```bash
<repo>/bin/agent-browser open https://example.com
```

**Uninstall:** remove the two symlinks (the repo files and state dir are untouched):

```bash
rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool
```

See [PRD.md §2.17](./PRD.md) for the full cutover & coexistence rationale.

## Usage (for agents)

Just type `agent-browser …` exactly as the upstream skill teaches. The wrapper
routes every call to your locked ephemeral lane. You cannot tell pooling is
happening, and you cannot escape your own lane or harm another agent's lane:

- `agent-browser open https://example.com` — your lane, the same browser for the
  whole session.
- `agent-browser connect <anything>` — routes to **your** lane (the argument is
  ignored).
- `agent-browser --session <X> …` — forced to `abpool-<N>` for your lane.
- `agent-browser close [--all]` — disconnects **your** lane's daemon only (the
  lane, Chrome, and ephemeral dir survive for reuse). It is **not** a release.

```bash
agent-browser open https://example.com     # your lane, same browser for the session
```

> **Note for humans:** from a plain terminal with **no `pi` ancestor**, the wrapper
> passes through to the real `agent-browser` with no lane magic — so the operator
> can still run `agent-browser` normally in a shell. See
> [How it works](#how-it-works-30-second-version).

The transparency contract (PRD.md §2.15): *an agent that has never heard of this
pool behaves exactly as the upstream skill intends, with no setup and no special
invocation.*

## Admin commands

`agent-browser-pool` is the admin tool for the **human operator**. With no command
given, `status` is assumed.

```bash
agent-browser-pool               # status (the default)
agent-browser-pool status
agent-browser-pool reap
agent-browser-pool release 1
agent-browser-pool release all
agent-browser-pool doctor
agent-browser-pool help          # aliases: --help, -h
```

### `status` (default)

Prints a read-only table of all active lanes. Empty pool prints `No active lanes.`

```
LANE   PORT SESSION           OWNER_PID OWNER_CWD                CHROME_PID   AGE STATE
   1  53420 abpool-1             836725 ~/projects/my-agent           104816 2m13s live
```

`STATE` is one of: `live` (Chrome reachable) · `disconnected` (lane leased but the
daemon dropped) · `STALE` (lease row missing/corrupt — fields show `?`).

### `reap`

Tear down lanes whose owning `pi` process has died (kill the Chrome process group,
delete the ephemeral profile dir, remove the lease). Always exits 0.

```
No stale lanes found.
```
```
Reaped 2 stale lane(s).
```

### `release [<N>|all]`

Explicitly tear down one lane by number, or every lane. With no/invalid argument it
prints a usage block to stderr and exits 1.

```
Released lane 1.
```
```
Released 2 lane(s).
```
```
Lane 99 has no active lease.      # exit code 1
```
```
No active lanes to release.        # `release all` on an empty pool
```

### `doctor`

Diagnose the pool. Checks dependencies, the real binary, the filesystem (btrfs),
the master profile, and reconciles leases against live Chromes and ephemeral dirs.
Exits `0` if healthy, `1` if any check fails. Sections, in order:

```
[dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, chrome → OK / MISSING;
                 notify-send → OK / MISSING (optional)
[binary]         the real agent-browser → OK / FAIL
[filesystem]     ephemeral root → OK (btrfs) / WARN (non-btrfs + slow-copy allowed) / FAIL
[master]         master profile → OK / FAIL
[lanes]          per lease → OK / WARN (LEAK, DISCONNECTED, PROVISIONAL)
[dirs]           per numeric dir → WARN (ORPHAN DIR) / "(N dir(s), all leased)"
[summary]        OK=N  WARN=N  FAIL=N  +  "Healthy."  (or "Problems found.")
```

A healthy summary:

```
  OK=14  WARN=0  FAIL=0
  Healthy.
```

See [PRD.md §2.12](./PRD.md) for the command list and §2.14 for the failure modes
each command fixes.

## Configuration reference

All configuration is via environment variables and **all are optional**. Every path
is resolved to an **absolute** path before any subprocess — a bare `~` is never
emitted to Chrome, `rm`, or a log file. The table below matches
`agent-browser-pool --help` exactly.

| Env var | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `~/.local/state/agent-browser-pool` | state dir (lease store `lanes/`, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log`) |
| `AGENT_CHROME_MASTER` | `~/.agent-chrome-profiles/master-profile` | static master template (CoW source; never launched/mutated/deleted) |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/` |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL `agent-browser` CLI (called by absolute path; stays upgradable) |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; a path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | number of ports in the pool → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (seconds) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | set to `1`/`true`/`yes`/`on` to launch Chrome with `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | set to `1`/`true`/`yes`/`on` to permit a real (slow) 4.8 GB copy per acquire |
| `AGENT_BROWSER_POOL_DISABLE` | unset = **pooling active** | `1`/`true`/`yes`/`on` = per-process passthrough (safety valve — see below) |

Three vars shape behavior most:

- **`AGENT_BROWSER_POOL_DISABLE`** — the safety valve; see [Safety valve](#safety-valve).
- **`AGENT_CHROME_ALLOW_SLOW_COPY`** — on a non-btrfs filesystem the wrapper refuses
  the expensive copy by default; set this only if you accept a slow acquire.
- **`AGENT_CHROME_HEADLESS`** — off by default (trusted profiles must look real;
  headless is detectable). Set for headless/server hosts.

> **Test-only hooks** (not for users): `AGENT_BROWSER_POOL_OWNER_PID` and
> `AGENT_BROWSER_POOL_OWNER_STARTTIME` let the test harness simulate distinct agent
> owners without a real `pi` ancestor (PRD.md §2.18). Do not set these in normal use.

## Safety valve

`AGENT_BROWSER_POOL_DISABLE=1` makes **this process** pass through to the real
`agent-browser` with **no pooling** — no lane, no ephemeral profile, no interception.
It is per-process (exported into one shell), not global. Use it for cutover
coexistence (stay on the old workflow) or for debugging.

```bash
export AGENT_BROWSER_POOL_DISABLE=1
agent-browser open https://example.com    # real ~/.local/bin/agent-browser, no lane
```

See [PRD.md §2.17](./PRD.md) (cutover & coexistence) and
[Installation](#installation) above.

## How it works (30-second version)

The wrapper decides per invocation. It **passes through unchanged** when any of
these is true — otherwise it runs the lane lifecycle below:

- `AGENT_BROWSER_POOL_DISABLE=1` (safety valve);
- the command is a **META** command (`skills`, `--help`, `--version`, `session
  list`, `dashboard`, `plugin`), which need no lane;
- there is **no `pi` ancestor** — a human in a terminal gets the raw upstream tool.

```
agent-browser open https://example.com        ← agent types this, nothing else
   │ wrapper walks ppid → owning pi PID  (stable across the agent's bash calls)
   ├─ already holds a lease?  reuse my lane
   ├─ else acquire:  reap stale  →  reuse-orphan OR  cp --reflink master→ephemeral
   │                  →  launch Chrome (anti-throttle flags)  →  connect daemon
   ├─ force AGENT_BROWSER_SESSION=abpool-<N>   (so every later call routes here)
   └─ exec the real agent-browser  with original args   (process replacement)
```

Full lifecycle ordering (`pool_wrapper_main`):

1. config + state init;
2. `POOL_DISABLE=1` → passthrough (exec real binary);
3. META command → passthrough;
4. no `pi` ancestor → passthrough (human terminal);
5. find my lane (`pool_lease_find_mine`) or acquire (reap-stale → reuse-orphan →
   boot/adopt);
6. provisional lane (port 0) → boot it (copy + port + launch + connect); adopted
   orphan (port > 0) → reuse as-is;
7. `pool_ensure_connected` (reconnect if the daemon died);
8. normalize `close`/`connect` args, strip any `--session`, force
   `AGENT_BROWSER_SESSION=abpool-<N>`;
9. `exec` the real `agent-browser` with the cleaned args — terminal step.

**Release** happens when the owning `pi` process exits (the next acquire reaps it),
on explicit `agent-browser-pool release`, or on pool-exhaustion force-reap: kill the
Chrome **process group**, `rm -rf` the ephemeral dir, drop the lease. There is **no
idle TTL**. A crashed agent → its `pi` PID dies → next acquire reaps it. `close`
mid-task is **disconnect-only**: the lane, Chrome, and ephemeral dir survive for
reuse.

## Troubleshooting

The canonical triage sequence:

```bash
agent-browser-pool status      # what lanes exist right now?
agent-browser-pool doctor      # what is broken / leaking?
agent-browser-pool reap        # tear down lanes whose owner died
agent-browser-pool release 1   # or: release all
```

### Pool exhaustion — an agent blocks, then force-reaps

**Symptom:** an agent's `agent-browser` call blocks for a long time, then a lane is
force-reclaimed and you get a desktop notification (`notify-send`) and a line in
`~/.local/state/agent-browser-pool/alerts.log`.

**Cause:** all lanes are in use. The wrapper blocks up to `AGENT_BROWSER_POOL_WAIT`
(600 s by default), re-running stale-reap each poll. On timeout it force-reclaims
the oldest lane whose owner is actually dead and **alerts**. If even force-reap
can't free a lane, the wrapper exits non-zero.

**Fix:** `agent-browser-pool reap` then `release all` to clear the pool, and
**investigate the leak** — hitting the alert at all means sessions accumulated
without cleanup. Tune `AGENT_BROWSER_POOL_WAIT` if your workload legitimately needs
longer. See PRD.md §2.9.

### Leaks — orphan dirs, dead Chrome, stale leases

**Symptom:** `doctor` reports `WARN` lines, or ephemeral dirs / Chrome processes
outlive their agents.

**Cause:** crashed/killed agents left behind state the reaper hasn't reclaimed yet.

**Fix:** `agent-browser-pool doctor` — the `[lanes]` section flags
`LEAK (no dir)` / `LEAK (dead chrome)` / `DISCONNECTED` / `PROVISIONAL`, and
`[dirs]` flags `ORPHAN DIR` (a numeric dir with no lease). Clear with `reap`
(stale lanes only) or `release <N>` / `release all` (explicit teardown). `doctor`
exits `1` when problems are found. See PRD.md §2.14.

### "It didn't do anything / wrong browser"

**Symptom:** an `agent-browser` call didn't get a lane, or opened the wrong
(legacy) profile.

**Cause:** **passthrough.** Either you are a human in a terminal (no `pi`
ancestor), or `AGENT_BROWSER_POOL_DISABLE=1` is set in that shell.

**Fix:** for agents, confirm there is a `pi` ancestor in the process tree and that
the disable env is unset; then `agent-browser-pool status` to see the lane.

## Repository layout

```
agent-browser-pool/
├── README.md                  ← this file (user docs)
├── PRD.md                     ← full product requirements + technical spec
├── AGENTS.md                  ← operating rules for AI agents in this repo
├── install.sh                 ← cutover installer (symlinks + doctor + warning)
├── bin/
│   ├── agent-browser          ← transparent PATH-shadowing wrapper  (→ lib/pool.sh)
│   └── agent-browser-pool     ← admin CLI dispatcher               (→ lib/pool.sh)
├── lib/
│   └── pool.sh                ← shared lease logic (config, acquire, boot, release, reap, admin)
└── test/
    ├── validate.sh            ← test framework (assertions, owner sim, hermetic setup/teardown)
    ├── concurrency.sh         ← N agents → N distinct lanes, no collision
    ├── release_reaper.sh      ← release + stale reaper + crash simulation
    └── transparency.sh        ← the "no-idea" transparency contract checklist
```

Runtime state is **not** in the repo — it is created at install / on first run and
is gitignored:

- `~/.local/state/agent-browser-pool/` — `lanes/<N>.json`, `acquire.lock`,
  `alerts.log`, `chrome-<N>.log`, `pool.log`.
- `~/.agent-chrome-profiles/` — `master-profile/` (static template) and
  `active/<N>/` (ephemeral lane dirs).

For agent operating rules (sandbox safety, process reaping, test isolation), see
**[AGENTS.md](./AGENTS.md)** — this README documents the shipped product; AGENTS.md
documents how to work *in* the repo.
