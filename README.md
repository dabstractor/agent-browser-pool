# `agent-browser-pool`

**Dedicated Chrome profile lanes for AI agents, via a single invariant command.**

`agent-browser-pool` gives every AI agent its own dedicated, locked Chrome profile for the
lifetime of its session — a fresh, trusted profile copied from your real Chrome, isolated
from every other agent, and cleaned up automatically when the agent finishes or crashes.
Agents invoke it explicitly; nothing is intercepted and nothing is shadowed.

- **Not a fork.** A thin bash wrapper + the `agent-browser-pool` CLI. The real
  [`agent-browser`](https://github.com/vercel/agent-browser) is called by absolute path and
  stays upgradable.
- **Ephemeral profiles.** Each acquire **copy-on-writes** a fresh profile from your **real
  Chrome profile** (default `~/.config/google-chrome`) and deletes it on release. Because the
  pool lives on **btrfs**, `cp --reflink=always` makes every copy instant and deduplicated.
- **1 agent = 1 browser.** Mutual exclusion via leases keyed on the owning harness process (and
  its start time). The next agent gets the next free lane.
- **Explicit invariant command.** Agents run `agent-browser-pool <verb> <args>`; the lane is
  selected by the caller's process identity, never an argument. The command is identical on
  lane 1 or lane 99.

See **[PRD.md](./PRD.md)** for the full product requirements and technical spec.

## Status

**MVP V2 — explicit invocation model (no PATH shadowing).** The sole entry point
(`bin/agent-browser-pool`), the shared lease library (`lib/pool.sh`), the installer
(`install.sh`), and the agent skill (`.agents/skills/agent-browser-pool/`) are all implemented
and tested. See **Installation** below to set it up.

## Prerequisites

1. **btrfs** at the pool root (`~/.agent-chrome-profiles/active`). The pool copy-on-writes a
   profile per lane; btrfs makes each `cp --reflink=always` instant and deduplicated. On a
   non-btrfs filesystem the pool **refuses** the ~4.8 GB copy unless you set
   `AGENT_CHROME_ALLOW_SLOW_COPY` (to `1`/`true`/`yes`/`on`).
2. **A real Chrome profile** at `~/.config/google-chrome` (or point `AGENT_CHROME_MASTER` at
   any user-data-dir). It holds the identity every agent should start from (Google login,
   password manager, the `agent-browser` extension). It **may be live/in-use** — agents CoW
   a snapshot each acquire, so new logins propagate to the next lane automatically. The pool
   treats it as **read-only**: it is never launched, written, or deleted.
3. **`agent-browser` ≥ 0.28** at `~/.local/bin/agent-browser` — a hard runtime dependency. It
   supplies `--session`, `connect`, `get cdp-url`, and the `AGENT_BROWSER_SESSION` env var. It
   stays upgradable: the pool calls it by absolute path, so updating the binary just works.
4. **`google-chrome-stable`** (or whatever `$AGENT_CHROME_BIN` points at).

A handful of coreutils/util-linux/procps tools are also required (`flock`, `setsid`, `pgrep`,
`pkill`, `cp`, `curl`, `jq`; `notify-send` is optional). Run `agent-browser-pool doctor` to
verify the whole stack — see [Admin commands](#admin-commands).

## Installation

`install.sh` does **three benign things** — there is **no PATH interception**, so installing
**cannot disrupt running agents** (lane selection is by caller identity, never a PATH rewrite):

1. symlinks `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool` (the sole entry point);
2. pre-creates the pool state dir (`lanes/` + `acquire.lock`);
3. runs `doctor` to verify the real `agent-browser` ≥ 0.28, Chrome, btrfs, and the source
   profile.

```bash
./install.sh                 # symlink + state dir + doctor (benign; no confirmation needed)
./install.sh --global-skill  # ALSO symlink the agent skill into ~/.agents/skills/ (opt-in)
./install.sh --help          # show help (note: --force / -f exists but is a no-op)
```

**The agent skill is opt-in.** By default the skill is *project-scoped*: pi discovers it only
while working inside this repo. Pass `--global-skill` to also expose it to pi sessions in
**every** project:

```bash
./install.sh --global-skill   # ~/.local/bin/agent-browser-pool + ~/.agents/skills/agent-browser-pool
```

**Uninstall:** remove the symlink(s) (the repo files and state dir are untouched):

```bash
rm -f ~/.local/bin/agent-browser-pool ~/.agents/skills/agent-browser-pool
```

See [PRD.md §2.17](./PRD.md) for why installation is non-disruptive (no PATH interception).

### Cross-harness skill installation

**The agent skill is cross-harness, installed per-harness.** The skill is an Agent
Skills-standard skill at `.agents/skills/agent-browser-pool/` (discovered project-scoped
inside this repo). `install.sh --global-skill` symlinks it into `~/.agents/skills/`. To
teach each harness natively, install into its own skills dir:

| Harness               | Global skills dir                          | Project skills dir     | Follows symlinks?           |
| --------------------- | ------------------------------------------ | ---------------------- | --------------------------- |
| pi                    | `~/.agents/skills/`, `~/.pi/agent/skills/` | `.agents/skills/`      | yes                         |
| Claude Code           | `~/.claude/skills/`                        | `.claude/skills/`      | yes                         |
| Codex                 | `~/.codex/skills/`                         | `.agents/skills/`      | **no — openai/codex#11314** |
| Antigravity (agy/IDE) | `~/.antigravity/skills/`                   | `.antigravity/skills/` | verify                      |

> **Codex caveat:** Codex does not discover a *symlinked* `.agents/skills` (openai/codex#11314).
> For Codex, install the skill as a real directory copy into `~/.codex/skills/` (or wait for
> the upstream fix). pi and Claude Code follow symlinks, so `--global-skill` suffices for them.

## Usage (for agents)

The command is `agent-browser-pool <verb> <args>`. The lane is selected by your process
identity (your owning harness process and its start time) — **the command never names a lane**,
and you cannot escape your own lane or harm another agent's:

- `agent-browser-pool open https://example.com` — your lane, the same browser for the whole
  session.
- `agent-browser-pool connect <anything>` — routes to **your** lane (the argument is ignored).
- `agent-browser-pool --session <X> …` — `--session` is stripped and forced to `abpool-<N>`
  for your lane (you never type this).
- `agent-browser-pool close [--all]` — disconnects **your** lane's daemon only (the lane,
  Chrome, and ephemeral dir survive for reuse). It is **not** a release.

```bash
agent-browser-pool open https://example.com     # your lane, same browser for the session
```

> **Driving commands require a supported-harness ancestor.** From a plain terminal with no recognized-harness ancestor, a
> driving command **fails fast** with an actionable message — by design. Run browser work
> under a supported harness (`pi`/`claude`/`codex`/`agy`), or call `agent-browser` directly for raw access without pooling. Pool verbs
> (`status` / `doctor` / `reap` / `release` / `help`) work from any shell; every other
> command is a driving command that requires a supported-harness ancestor.
> See [How it works](#how-it-works).

For the full procedural contract (acquire lifecycle, reuse rules, teardown semantics), read
the agent skill at **[`.agents/skills/agent-browser-pool/SKILL.md`](./.agents/skills/agent-browser-pool/SKILL.md)**.

## Commands

`agent-browser-pool` is the sole command for **both** the operator-facing pool verbs **and**
agent driving commands. With no command given, `status` is assumed. (This mirrors
`agent-browser-pool help`.)

### Pool verbs (operator / read-only — work from any shell)

```bash
agent-browser-pool               # status (the default)
agent-browser-pool status
agent-browser-pool reap
agent-browser-pool release 1
agent-browser-pool release all
agent-browser-pool doctor
agent-browser-pool help          # aliases: --help, -h
```

### Driving commands (agent — routed to your own lane)

Any token that is **not** a pool verb is treated as a **driving** command and routed to your
own locked lane (chosen by your identity, never an argument). The real `agent-browser` runs
against your lane:

```bash
agent-browser-pool open https://example.com   # open a URL in your lane
agent-browser-pool screenshot                  # capture a screenshot
agent-browser-pool close                      # disconnect your lane daemon (lane + profile survive)
agent-browser-pool get cdp-url                # every other real agent-browser verb works the same way
agent-browser-pool click | type | eval | find | ...
```

You never pass a lane, port, or session.

> **Classification detail.** There is no separate "meta" class that runs without a
> lane. `bin/agent-browser-pool`
> catches the **pool verbs** (`status`, `reap`, `release`, `doctor`, `help`/`--help`/`-h`;
> a bare invocation defaults to `status`) and runs them with no lane. **Everything else is a
> driving command** — including `--version`, `skills`, `dashboard`, `plugin`, `mcp`,
> `session list`, and a flags-only invocation (e.g. `agent-browser-pool --json`). A driving
> command resolves your owning harness process, **fails fast** without a recognized-harness ancestor, and runs
> scoped to your own lane (any `--session <X>` you pass is stripped and
> `AGENT_BROWSER_SESSION=abpool-<N>` is forced). This is why a caller can never aim a command
> at another agent's lane.

## Admin commands

### `status` (default)

Prints a read-only table of all active lanes. Empty pool prints `No active lanes.`

```
LANE   PORT SESSION           OWNER_PID OWNER_CWD                CHROME_PID   AGE STATE
   1  53420 abpool-1             836725 ~/projects/my-agent           104816 2m13s live
```

`STATE` is one of: `live` (Chrome reachable) · `disconnected` (lane leased but the daemon
dropped) · `STALE` (lease row missing/corrupt — fields show `?`).

### `reap`

Tear down lanes whose owning harness process has died (kill the Chrome process group, delete the
ephemeral profile dir, remove the lease). Always exits 0.

```
No stale lanes found.
```
```
Reaped 2 stale lane(s).
```

### `release [<N>|all]`

Explicitly tear down one lane by number, or every lane. With no/invalid argument it prints a
usage block to stderr and exits 1.

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

Diagnose the pool. Checks dependencies, the real binary, the filesystem (btrfs), the
source/master profile, and reconciles leases against live Chromes and ephemeral dirs. Exits
`0` if healthy, `1` if any check fails. Sections, in order:

```
[dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, chrome → OK / MISSING;
                 notify-send → OK / MISSING (optional)
[binary]         the real agent-browser → OK / FAIL
[filesystem]     ephemeral root → OK (btrfs) / WARN (non-btrfs + slow-copy allowed) / FAIL
[master]         the source/master profile (your real Chrome dir, $AGENT_CHROME_MASTER) → OK / FAIL
[lanes]          per lease → OK / WARN (LEAK, DISCONNECTED, PROVISIONAL)
[dirs]           per numeric dir → WARN (ORPHAN DIR) / "(N dir(s), all leased)"
[summary]        OK=N  WARN=N  FAIL=N  +  "Healthy."  (or "Problems found.")
```

The `[master]` section label is unchanged from earlier versions, but it now checks your
**real** Chrome user-data-dir (default `~/.config/google-chrome`, or whatever
`$AGENT_CHROME_MASTER` points at) exists and is non-empty — it is the copy-on-write source,
read-only to the pool. A healthy summary:

```
  OK=14  WARN=0  FAIL=0
  Healthy.
```

See [PRD.md §2.12](./PRD.md) for the command list and §2.14 for the failure modes each
command fixes.

## Configuration reference

All configuration is via environment variables and **all are optional**. Every path is
resolved to an **absolute** path before any subprocess — a bare `~` is never emitted to
Chrome, `rm`, or a log file. The table below matches `agent-browser-pool help` / the shipped
`pool_config_init` defaults exactly.

| Env var | Default | Meaning |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `~/.local/state/agent-browser-pool` | state dir (`lanes/`, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log`) |
| `AGENT_CHROME_MASTER` | `~/.config/google-chrome` (your **real** Chrome user-data-dir) | CoW source profile; **read-only** to the pool; may be live/in-use |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/`; deleted on release |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL `agent-browser` CLI (called by absolute path; stays upgradable) |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; a path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | number of ports in the pool → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (seconds) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | set to `1`/`true`/`yes`/`on` to launch Chrome with `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | set to `1`/`true`/`yes`/`on` to permit a real (slow) ~4.8 GB copy per acquire |
| `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |

Three vars shape behavior most:

- **`AGENT_CHROME_MASTER`** — the CoW source. Defaults to your real Chrome user-data-dir so
  agents start from your current auth with no separate template. Point it at a dedicated
  profile dir if you prefer. It is treated as read-only and may be live/in-use.
- **`AGENT_CHROME_ALLOW_SLOW_COPY`** — on a non-btrfs filesystem the pool refuses the
  expensive copy by default; set this only if you accept a slow acquire.
- **`AGENT_CHROME_HEADLESS`** — off by default (trusted profiles must look real; headless is
  detectable). Set for headless/server hosts.

> **Test-only hooks** (not for users): `AGENT_BROWSER_POOL_OWNER_PID` and
> `AGENT_BROWSER_POOL_OWNER_STARTTIME` let the test harness simulate distinct agent owners
> without a real `pi` ancestor (PRD.md §2.18). Do not set these in normal use.

For the full dispatch table, acquire lifecycle, and a troubleshooting matrix, see
**[`.agents/skills/agent-browser-pool/references/configuration.md`](./.agents/skills/agent-browser-pool/references/configuration.md)**.

## How it works

On each invocation, `bin/agent-browser-pool` splits the command: a **pool verb** runs an
admin function (no lane); **everything else is a driving command** that runs the lane
lifecycle:

```
agent-browser-pool open https://example.com        ← agent types this, nothing else
   │ 1. split (bin/agent-browser-pool):
   │      pool verb (status/reap/release/doctor/help)?  → run it (no lane, no owner resolve)
   │      else DRIVING → pool_wrapper_main:
   │           resolve owning harness PID + starttime; no recognized-harness ancestor → FAIL-FAST
   ├─ already hold my lease?  reuse my lane
   ├─ else acquire:  reap stale  →  reuse-orphan OR  cp --reflink master(real Chrome)→ephemeral
   │                  →  launch Chrome (setsid process group, anti-throttle flags)  →  connect daemon
   ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
   └─ exec the real agent-browser with the cleaned args   (process replacement)
```

Lane lifecycle ordering (`pool_wrapper_main`):

1. config + state init;
2. (pool verbs were handled by `bin/agent-browser-pool` above — no lane); otherwise driving:
3. **driving command → resolve the owning harness process**; if there is no recognized-harness ancestor,
   **fail fast** with an actionable error (by design — call `agent-browser` directly for raw
   access);
4. find my lane (`pool_lease_find_mine`) or acquire (reap-stale → reuse-orphan → boot/adopt);
5. provisional lane (port 0) → boot it (copy + port + launch + connect); adopted orphan
   (port > 0) → reuse as-is;
6. `pool_ensure_connected` (reconnect if the daemon died);
7. normalize `close`/`connect` args, strip any `--session`, force
   `AGENT_BROWSER_SESSION=abpool-<N>`;
8. `exec` the real `agent-browser` with the cleaned args — terminal step.

**Release** happens when the owning harness process exits (the next acquire reaps it), on
explicit `agent-browser-pool release`, or on pool-exhaustion force-reap: kill the Chrome
**process group**, `rm -rf` the ephemeral dir, drop the lease. There is **no idle TTL**. A
crashed agent → its harness PID dies → next acquire reaps it. `close` mid-task is
**disconnect-only**: the lane, Chrome, and ephemeral dir survive for reuse.

## Troubleshooting

The canonical triage sequence:

```bash
agent-browser-pool status      # what lanes exist right now?
agent-browser-pool doctor      # what is broken / leaking?
agent-browser-pool reap        # tear down lanes whose owner died
agent-browser-pool release 1   # or: release all
```

### Driving command errored: "requires a supported agent harness"

**Symptom:** an `agent-browser-pool` driving command fails with a message like
*"agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy). For raw browser use without pooling, call 'agent-browser' directly."*

**Cause:** by design. Driving commands acquire a lane keyed on your owning harness process; with
no recognized-harness ancestor in the process tree, there is no identity to key the lease on, so the command
**fails fast** rather than silently doing the wrong thing.

**Fix:** run browser work under a supported harness (e.g. inside a `pi`/`claude`/`codex`/`agy`
session), or — for raw browser use without pooling — call the real `agent-browser` directly. Pool
verbs (`status`, `doctor`, `reap`, `release`, `help`) work from any shell; all other commands are
driving (they require a supported-harness ancestor).

### Pool exhaustion — an agent blocks, then force-reaps

**Symptom:** an agent's driving call blocks for a long time, then a lane is force-reclaimed
and you get a desktop notification (`notify-send`) and a line in
`~/.local/state/agent-browser-pool/alerts.log`.

**Cause:** all lanes are in use. The pool blocks up to `AGENT_BROWSER_POOL_WAIT` (600 s by
default), re-running stale-reap each poll. On timeout it force-reclaims the oldest lane whose
owner is actually dead and **alerts**. If even force-reap can't free a lane, the call exits
non-zero.

**Fix:** `agent-browser-pool reap` then `release all` to clear the pool, and **investigate the
leak** — hitting the alert at all means sessions accumulated without cleanup. Tune
`AGENT_BROWSER_POOL_WAIT` if your workload legitimately needs longer. See PRD.md §2.9.

### Leaks — orphan dirs, dead Chrome, stale leases

**Symptom:** `doctor` reports `WARN` lines, or ephemeral dirs / Chrome processes outlive their
agents.

**Cause:** crashed/killed agents left behind state the reaper hasn't reclaimed yet.

**Fix:** `agent-browser-pool doctor` — the `[lanes]` section flags
`LEAK (no dir)` / `LEAK (dead chrome)` / `DISCONNECTED` / `PROVISIONAL`, and `[dirs]` flags
`ORPHAN DIR` (a numeric dir with no lease). Clear with `reap` (stale lanes only) or
`release <N>` / `release all` (explicit teardown). `doctor` exits `1` when problems are found.
See PRD.md §2.14.

## Repository layout

```
agent-browser-pool/
├── README.md                  ← this file (user docs)
├── PRD.md                     ← full product requirements + technical spec
├── AGENTS.md                  ← operating rules for AI agents in this repo
├── install.sh                 ← benign 3-step installer (symlink + state dir + doctor)
├── bin/
│   └── agent-browser-pool     ← sole entry point: pool verbs + driving router  (→ lib/pool.sh)
├── lib/
│   └── pool.sh                ← shared lease logic (config, acquire, boot, release, reap, admin)
├── .agents/skills/agent-browser-pool/
│   ├── SKILL.md               ← procedural "how to use your lane" guide (the agent contract)
│   ├── README.md              ← skill overview + global install
│   └── references/
│       └── configuration.md   ← env-var table, dispatch, lifecycle, troubleshooting matrix
└── test/
    ├── validate.sh            ← test framework (assertions, owner sim, hermetic setup/teardown)
    ├── concurrency.sh         ← N agents → N distinct lanes, no collision
    ├── release_reaper.sh      ← release + stale reaper + crash simulation
    └── transparency.sh        ← dispatch + classification contract checks
```

Runtime state is **not** in the repo — it is created at install / on first run and is
gitignored:

- `~/.local/state/agent-browser-pool/` — `lanes/<N>.json`, `acquire.lock`, `alerts.log`,
  `chrome-<N>.log`, `pool.log`.
- `~/.agent-chrome-profiles/` — `active/<N>/` (ephemeral lane dirs). The CoW **source** is your
  real Chrome user-data-dir at `~/.config/google-chrome` (or whatever `$AGENT_CHROME_MASTER`
  points at); the pool never writes to it.

For agent operating rules (sandbox safety, process reaping, test isolation), see
**[AGENTS.md](./AGENTS.md)** — this README documents the shipped product; AGENTS.md documents
how to work *in* the repo.
