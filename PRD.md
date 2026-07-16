# PRD & Technical Spec — `agent-browser-pool`

**Status:** Design / brainstorm. Open items are boxed at the end. Decisions marked
**[DEFAULT]** are applied pending your confirmation.

**One-line goal:** Every AI agent that runs `agent-browser-pool …` gets its own
dedicated, locked, trusted Chrome profile for its whole session — via a single
**invariant command** (`agent-browser-pool <verb> <args>`) whose lane is selected by
the agent's own process identity, **never an argument** — so no agent can reach
another's lane through normal use — and the Chrome + profile are guaranteed cleaned
up when the agent finishes or crashes.

---

## 1. Product Requirements

### 1.1 Background
- `agent-browser` (Vercel, v0.28.0, Rust CLI) drives Chrome over CDP. It is
  **env-driven**: `AGENT_BROWSER_SESSION=<name>` selects a **persistent daemon
  process** keyed by name; `agent-browser --session <name> connect <port>` binds
  that daemon to a Chrome on a port; every later `AGENT_BROWSER_SESSION=<name>
  agent-browser …` routes there. (Verified.)
- Every `bash` tool call an agent makes is a child of one **agent-harness process**
  — `pi`, Claude Code (`claude`), Codex (`codex`), or Antigravity's agent (`agy`).
  Walking `ppid` to the first ancestor whose `comm` is a **recognized harness**
  yields a stable, unique-per-agent PID. (Verified on this host: `pi`, `claude`,
  `codex`, `agy`, and the `antigravity` IDE are all installed; this session →
  836725 under `pi`.) Subagents are separate harness processes → separate lanes.
- The pool root `~/.agent-chrome-profiles` is on **btrfs**, so `cp --reflink=always`
  makes profile copies **instant and deduplicated** (each profile ≈ 4.8 GB; CoW
  shares all blocks until the agent writes). This is what makes ephemeral profiles
  viable. (Verified.)

### 1.2 The model (ephemeral profiles copied from a source)
- **The source profile** is whatever `$AGENT_CHROME_MASTER` points at — **default:
  your real Chrome user-data-dir** (`${XDG_CONFIG_HOME:-~/.config}/google-chrome`).
  It holds the identity every agent should start from (Google login, Bitwarden, the
  agent-browser extension). It may be your **live, in-use** profile: keep browsing
  and logging in, and each acquire copies the *current* state, so agents pick up new
  auth automatically. (For a frozen, guaranteed-consistent source, copy your profile
  once to a dedicated dir and point there — see §2.7.)
- On **acquire**, the pool copy-on-writes the source into a fresh **ephemeral** dir,
  launches Chrome against the *copy*, connects the daemon, and records a lease.
- On **release**, the pool kills the Chrome process group, **deletes the ephemeral
  dir**, and drops the lease. The source is **read-only to the pool**: never
  launched, never written to, never deleted. (The human mutating their own live
  profile is expected; the pool only reads it.)
- Persistent dirs `~/.agent-chrome-profiles/{1..10}` (a legacy working set, if any)
  are **outside the pool's world** — it never touches them. Ephemeral dirs live in an
  isolated subdir (see §2.3).

### 1.3 Goals
1. **Explicit, invariant invocation.** Agents run `agent-browser-pool <verb> <args>`
   — the **same** command every time, regardless of which lane they're on. No
   flags/port/session/**lane-number** to remember or pass: the lane is derived from
   the agent's own process identity, never an argument. The agent does not — and
   cannot — name a lane.
2. **1 agent = 1 browser = 1 ephemeral profile.** No two agents ever share a Chrome.
3. **Mutual exclusion + isolation.** Lanes are keyed on the owner's
   `(pid, comm, starttime)` identity; a held lane cannot be grabbed, and — because no
   command accepts a lane selector — one agent **cannot reach another's lane through
   normal tool use**. The next agent gets the next free lane.
4. **Reliable cleanup — including on crash.** Chrome process group killed **and**
   ephemeral profile dir deleted when the agent is done, whether it exits cleanly,
   is killed, or crashes/power-loss.
5. **Discoverable, unbounded pool.** Lanes created on demand from the master; no
   fixed count, no fixed port↔profile map.

### 1.4 Non-goals
- Not a multi-tab manager (one tab per Chrome; agent discipline).
- Not a way for agents to pick a *specific* profile.
- Not persistent Chrome (ephemeral by design).
- Not a fork of `agent-browser`.

### 1.5 User stories
- Agent runs `agent-browser-pool open <url>` with zero prep → opens in a trusted,
  logged-in Chrome that only it is using (lane picked by the agent's identity, not an arg).
- Every later `agent-browser-pool …` in the session hits that same Chrome/lane, even
  though each command is a fresh shell — the command is identical every time.
- When the agent's harness process exits (task done / crash), its Chrome is killed
  and its ephemeral profile deleted within milliseconds.
- Human runs `agent-browser-pool status` to see lanes/owners/ages, and
  `agent-browser-pool reap` to clean any leaked Chrome.

---

## 2. Technical Spec

### 2.1 Components (two binaries + one lib)
```
~/.local/bin/agent-browser-pool     ← SOLE entry point (symlink → repo bin/): pool verbs + driving router
repo/lib/pool.sh                    ← shared lease logic (owner resolve / acquire / release / reap / copy / launch)
                                     ↓ calls by absolute path
~/.local/bin/agent-browser          ← the REAL Vercel CLI — hard runtime dependency (unchanged, upgradable)

.agents/skills/agent-browser-pool/SKILL.md   ← the agent contract (Agent Skills standard;
                                             discovered by pi, Claude Code, Codex, AGY)

~/.local/state/agent-browser-pool/  ← lease store + logs (runtime, not in repo)
├── acquire.lock                    ← short global flock
├── lanes/<N>.json                  ← one lease per held lane
└── chrome-<N>.log                  ← per-lane Chrome stderr/stdout

~/.config/google-chrome/            ← SOURCE profile (default $AGENT_CHROME_MASTER; = your real Chrome user-data-dir; read-only to the pool)
~/.agent-chrome-profiles/
├── active/<N>/                     ← ephemeral lanes (CoW copy of the source; deleted on release)
└── 1..10/                          ← legacy persistent working set — UNTOUCHED by the pool
```

### 2.2 Hard rule: resolve every path; never pass `~` to a subprocess
Tilde expansion does **not** happen after `=` or inside quotes, so a literal `~`
creates a junk dir named `~` (you've hit this). The wrapper **resolves all paths to
absolute form up front** (`$HOME` + `realpath`) and never emits a bare `~` to Chrome,
`rm`, log paths, or any subprocess. Enforced in `lib/pool.sh`.

### 2.3 Ephemeral dir location  **[OPEN — see Open items]**
**[DEFAULT]** Ephemeral lanes live in an isolated subdir
`~/.agent-chrome-profiles/active/<N>/`, numbered from 1, created on acquire and
deleted on release. This cleanly separates them from the persistent `1..10` and
from the source profile, so there is no collision logic and no "skip 1–10" special case.
(The earlier "range 11+" instruction is satisfied more robustly by isolation.)

### 2.4 Request lifecycle (the pool entry, per invocation)
```
agent-browser-pool <args>
 ├─ 0. Classify the first non-flag token:
 │     POOL VERB (status | reap | release | doctor | help | --help | -h) → run that admin command; done (no lane).
 │     anything else → DRIVING command (open/click/type/snapshot/eval/get/find/connect/close/…) → lane logic below.
 ├─ 1. Resolve OWNER: walk ppid to the first ancestor whose comm is a RECOGNIZED
 │     HARNESS (default set: pi, claude, codex, agy; configurable via
 │     $AGENT_BROWSER_POOL_HARNESSES, §2.11). Record {pid, comm, starttime} with the
 │     ACTUAL matched comm (not a hardcoded “pi”). No recognized-harness ancestor →
 │     DRIVING fails fast (“requires a supported agent harness (pi/claude/codex/agy);
 │     for raw browser use call `agent-browser` directly”).
 │     (Pool verbs never need an owner.)   [RESOLVED — was “pi-required”; O9 generalizes it.]
 ├─ 2. Find MY lease (scan lanes/*.json for owner.pid==pid && comm==<my matched harness>
 │     && starttime match). Found & valid → reuse lane N → goto 4.
 ├─ 3. ACQUIRE (no valid lease):
 │     under short flock(acquire.lock):
 │       a. REAP-STALE: for each lane whose owner pid is dead / comm not a recognized
 │          harness / starttime mismatch → kill its Chrome pgroup, rm -rf its ephemeral
 │          dir, delete lease.
 │       b. REUSE-ORPHAN: if any lane has a *responsive* Chrome but a dead owner
 │          → adopt it (reassign owner, ensure connected), skip the copy.   [IQ4 = reuse-if-responsive]
 │       c. CHOOSE N: lowest N≥1 with no active/<N> dir and no lanes/<N>.json lease.
 │       d. CLAIM: write lanes/<N>.json (owner, port=0, session=abpool-<N>, chrome_pid=0).
 │       release flock.
 │     outside the lock (concurrent boots allowed):
 │       e. COPY: cp -a --reflink=always <master> <active/N>; rm Singleton{Lock,Cookie,Socket}.
 │       f. PORT: lowest free TCP port in [BASE, BASE+RANGE); probe via curl /json/version.  [BASE=53420]
 │       g. LAUNCH: setsid google-chrome-stable --remote-debugging-port=<port> --user-data-dir=<abs active/N>
 │          + anti-throttle flags (§2.6); record chrome_pid + pgid.
 │       h. WAIT for CDP (/json/version, ≤30×0.5s).
 │       i. CONNECT: agent-browser --session abpool-<N> connect <port>.
 │       j. Update lease {port, chrome_pid, pgid, connected:true}.
 ├─ 4. ENSURE CONNECTED: agent-browser --session abpool-<N> get cdp-url >/dev/null 2>&1
 │        || agent-browser --session abpool-<N> connect <port>     (reconnect if daemon died)
 │     touch lease mtime (observability).
 └─ 5. EXEC the REAL binary: AGENT_BROWSER_SESSION=abpool-<N> agent-browser <cleaned args>.
       Cleaning (pool owns connection + session + lifecycle): strip any caller `--session <X>`;
       drop a `connect <port|url>` positional (the lane is already connected). `close` stays disconnect-only.
```

**Agent-facing invariants (what the skill guarantees):**
- **The command never names a lane.** `agent-browser-pool <verb> <args>` always means
  *my* lane — selected by my owner identity (step 2/3), never an argument. The same
  command works identically on lane 1 or lane 99; the agent cannot tell which it's on
  and never needs to.
- **Full surface supported.** Every real-`agent-browser` verb passes through unchanged;
  the pool owns only connection + session + lifecycle. Defensive cleaning (step 5):
  `--session <X>` is stripped/overridden to `abpool-<N>`; a `connect <port|url>`
  positional is dropped (the lane is already connected); `close [--all]` disconnects my
  lane's daemon only and never touches another owner's lane.

### 2.5 Release semantics
Release is **owner-liveness-driven**, not TTL-driven (no idle timer). Triggers:

| trigger | action |
|---|---|
| Owning harness exits (task done / killed / crash) | detected by next acquire's REAP-STALE → kill pgroup, `rm -rf` ephemeral dir, delete lease |
| Explicit `agent-browser-pool release [<N>\|all]` | same teardown |
| Pool-exhaustion block timeout (§2.9) | force-reap the oldest dead-owner lane, then proceed; **alert** (this signals a leak) |

**`agent-browser close` (mid-task) = disconnect-only.** The daemon detaches but the
lane, Chrome, and ephemeral dir stay alive, so the agent's next call reuses the
*same* browser (open tabs/forms preserved) without a redundant source copy. The
ephemeral dir is deleted only on true release (owner exit / explicit).  **[OPEN — confirm]**

### 2.6 Chrome launch (per lane)
```
setsid google-chrome-stable \
  --remote-debugging-port=<port> \
  --user-data-dir=<ABSOLUTE active/N path> \
  --no-first-run --no-default-browser-check \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-features=CalculateNativeWinOcclusion \
  --disable-back-forward-cache
```
- Windowed (no `--headless`): trusted profiles that must look real; headless is
  detectable. Override via `AGENT_CHROME_HEADLESS=1`.
- `setsid` puts Chrome in its own process group → release can `kill -- -<pgid>` to
  tear down the whole tree (renderer/GPU/utility children), no orphans.
- Anti-throttle flags are **required** (Wayland): without them, backgrounded pool
  windows get JS-timer-throttled and heavy SPA apply forms never hydrate.
- Binary: `AGENT_CHROME_BIN` (default `google-chrome-stable`).

### 2.7 Copy / source-profile hygiene
- **Source** = `$AGENT_CHROME_MASTER`, default `${XDG_CONFIG_HOME:-~/.config}/google-chrome`
  (your real Chrome user-data-dir). Point it at any Chrome user-data-dir.
- **Live/in-use source is supported.** The human may keep browsing and logging in;
  each acquire CoW-copies the *current* state, so new auth propagates to agents
  automatically. **Caveat:** copying a profile Chrome is actively writing can yield a
  slightly-torn snapshot (SQLite files mid-write); Chrome is generally resilient and
  self-heals, but for guaranteed consistency close Chrome first or point
  `AGENT_CHROME_MASTER` at a dedicated frozen template. *(Future: `btrfs subvolume
  snapshot` for a truly atomic, consistent snapshot.)*
- `cp -a --reflink=always <source> <active/N>` → instant CoW on btrfs. If the FS ever
  isn't btrfs, **fail loudly** (don't silently do a multi-GB real copy per acquire)
  unless `AGENT_CHROME_ALLOW_SLOW_COPY=1`.
- After copy: strip inherited single-instance artifacts with `rm -f <active/N>/Singleton*`
  (a **glob, not a fixed list** — covers any future singleton file) and **assert none
  survive**. These matter most for a live source: a copied `SingletonLock` symlink →
  `hostname-<live-pid>` would make the copy think Chrome is already running and
  forward-and-exit instead of launching.
- The source is **read-only to the pool**: never launched, never written to, never
  deleted. (The human mutating their own live profile is expected; the pool only reads.)

### 2.8 Lease data model (`lanes/<N>.json`)
```json
{
  "version": 1,
  "lane": 7,
  "ephemeral_dir": "/home/dustin/.agent-chrome-profiles/active/7",
  "port": 53427,
  "session": "abpool-7",
  "owner": { "pid": 836725, "comm": "claude", "starttime": 1234567890, "cwd": "/home/dustin/projects/x" },
  "chrome_pid": 104816,
  "chrome_pgid": 104816,
  "acquired_at": 1720000000,
  "last_seen_at": 1720000123,
  "connected": true
}
```
- One owner holds ≤1 lane (enforced at acquire step 2).
- `starttime` (from `/proc/<pid>/stat` field 22) defeats PID recycling into a new harness process.
- `comm` records the ACTUAL matched harness (pi/claude/codex/agy/…), not a constant — so
  `status`/`doctor` show which tool owns each lane, and stale detection works across all harnesses.

### 2.9 Pool exhaustion  **[IQ2 = block-with-timeout + alert]**
If no free/reusable lane at acquire:
1. Block up to **`AGENT_BROWSER_POOL_WAIT`** seconds **[DEFAULT 600 (= 10 min)]**, polling for a
   release/reap, re-running REAP-STALE each iteration.
2. On timeout: **force** — reclaim the oldest lane whose owner is actually dead
   (there must be one if we're truly exhausted via accumulation), and alert.
3. If even force-reap can't free one (genuinely all-live-owners): fail non-zero with
   a clear message.
- **Alert** on timeout/force: `notify-send` desktop notification + a line to
  `~/.local/state/agent-browser-pool/alerts.log`. **Per your note, hitting this at
  all means sessions accumulated without cleanup — i.e. a leak to investigate.**

### 2.10 Reaper  **[IQ3 = lazy, on acquire]**
- Stale-lease cleanup runs **inside every acquire** (step 3a) and on demand via
  `agent-browser-pool reap`. No background daemon by default.
- A crashed agent's Chrome+dir is reclaimed either at the next acquire or by an
  explicit `reap`. (A background systemd-user timer is a possible future add for
  promptness; not in scope unless you ask.)

### 2.11 Discovery & configuration
- **Recognized harnesses (owner resolution):** `$AGENT_BROWSER_POOL_HARNESSES` —
  comma-separated agent-harness process names (`comm` values) the pool treats as valid
  lane owners. Default: `pi,claude,codex,agy,antigravity`. Owner resolution (§2.4 step 1)
  walks `ppid` to the first ancestor matching one; the matched comm is recorded in the
  lease. Tune the list to match how each harness is installed on a host (a node-wrapped
  launcher may expose a different `comm` than the native binary; the Antigravity GUI's
  integrated terminal may surface the editor's `comm` rather than `agy`).
- **Source profile (CoW source):** `$AGENT_CHROME_MASTER` (default
  `${XDG_CONFIG_HOME:-~/.config}/google-chrome` — your real Chrome user-data-dir).
  Point at any Chrome user-data-dir; agents copy the current state on each acquire, so
  new logins propagate. May be live/in-use (see §2.7).
- **Ephemeral root:** `$AGENT_CHROME_EPHEMERAL_ROOT` (default
  `~/.agent-chrome-profiles/active`).
- **Pool size:** unbounded — lanes are `active/<N>` for the lowest free N.
- **State dir:** `$AGENT_BROWSER_POOL_STATE` (default `~/.local/state/agent-browser-pool`).
- **Real binary:** `$AGENT_BROWSER_REAL` (default `/home/dustin/.local/bin/agent-browser`).
- **Chrome binary:** `$AGENT_CHROME_BIN` (default `google-chrome-stable`).
- **Port base/range:** `$AGENT_CHROME_PORT_BASE`=**53420**, `$AGENT_CHROME_PORT_RANGE`=**1000**.
- **Exhaustion wait:** `$AGENT_BROWSER_POOL_WAIT`=**600** (10 min).
- **Headless:** `$AGENT_CHROME_HEADLESS` (unset = windowed).
- **Slow-copy escape hatch:** `$AGENT_CHROME_ALLOW_SLOW_COPY` (unset = refuse on non-btrfs).
- **(removed)** `AGENT_BROWSER_POOL_DISABLE` and the `~/scripts` PATH-shadow are gone
  — there is no interception to bypass (see §2.17).

### 2.12 CLI — `agent-browser-pool` (pool verbs + driving router)
```
status                 # lane | port | session | owner pid+cwd | chrome pid | age | state   (read-only)
reap                   # kill+delete dead-owner lanes                                        (operator)
release [<N>|all]      # explicit teardown — the ONLY command that names a lane              (operator; not agent-taught)
doctor                 # reconcile leases vs live Chromes vs dirs; report leaks             (read-only)
<driving verb> [args]  # anything else → acquire/reuse MY lane + exec the real agent-browser (agent)
```
`release` is the sole lane-naming command and it *tears down* (it cannot join a lane);
agents are not taught it. Every other token is a driving command routed to the caller's
own lane (§2.4).

### 2.13 Safety & identity rules (carried from the prior skill, non-negotiable)
Each ephemeral profile starts as a clone of the master identity:
- **Never enter credentials; never unlock Bitwarden.** Existing SSO/Google login is
  fine to *use*; never type a password.
- **Verify the target URL before every click/fill/navigate.**
- **Never drive the source profile directly.** The source (default: your real
  `~/.config/google-chrome`) is only ever **copied** — agents drive ephemeral CoW
  copies, never the source itself. The pool never launches, writes to, or deletes the
  source.
- **Isolation by construction.** Lane identity is the owner's `(pid, comm, starttime)`
  triple (§2.8). Acquire selects/creates the lane owned by THIS caller; there is **no
  argument that names a lane**, so an agent cannot express 'use lane N.' One owner holds
  ≤1 lane (enforced at acquire step 2). The only lane-naming command is operator-only
  `release <N>` (teardown, not join). Forging another owner's identity or tampering with
  the lease store directly is out of scope (accepted) — through normal tool use, an agent
  physically cannot reach another agent's lane.

### 2.14 Failure modes & recovery
| failure | detection | recovery |
|---|---|---|
| agent harness crash/kill | owner pid dead | REAP-STALE → kill pgroup, rm dir, drop lease |
| PID recycled into non-harness | comm not recognized | stale → reclaimed |
| PID recycled into new harness proc | starttime mismatch | stale → reclaimed |
| Chrome crash mid-task | `get cdp-url` fails in ENSURE-CONNECTED | relaunch on same dir+port, reconnect, keep lease (open tabs lost; profile kept) |
| Chrome slow to boot | /json/version timeout (15s) | retry launch once; then fail, drop lane |
| source profile missing/empty | acquire precheck | fail with guidance: use Chrome so the default exists, or set `AGENT_CHROME_MASTER` to an existing user-data-dir |
| FS not btrfs | acquire precheck | refuse unless `AGENT_CHROME_ALLOW_SLOW_COPY=1` |
| Pool exhausted (accumulation) | no free lane | block→force-reap→alert (§2.9) |
| `npm -g` upgrades agent-browser | wrapper uses absolute path | unaffected |

### 2.15 Invocation checklist (the contract the skill teaches)
- [ ] `agent-browser-pool open <url>` with zero prep → opens in MY locked ephemeral lane (lane selected by my identity, not an arg).
- [ ] The command is identical no matter which lane I'm on; I never pass a lane/port/session.
- [ ] Same browser for all my commands across many stateless bash calls (reuse by owner identity).
- [ ] Any real-agent-browser verb works: `agent-browser-pool {screenshot,get cdp-url,click,type,eval,find,…}`.
- [ ] `agent-browser-pool close` → disconnects MY lane's daemon only (lane/Chrome/profile survive for reuse).
- [ ] I cannot reach another agent's lane through any normal command.
- [ ] Next agent → next free lane; never collides.
- [ ] My crash → my Chrome dies, my ephemeral dir is deleted, no manual cleanup.

### 2.16 Dependencies (all verified present on this host)
- `agent-browser` ≥ 0.28 — the REAL Vercel CLI; a **hard runtime dependency**. The
  pool calls it by absolute path (`$AGENT_BROWSER_REAL`, default
  `~/.local/bin/agent-browser`) on every driving command — it need **not** be on the
  caller's PATH, only exist + be executable. Enforced two ways: (a) `doctor`'s
  `[binary]` check (run by `install.sh`); (b) a **preflight** in the pool entry on every
  driving call that fails fast with an actionable 'install agent-browser ≥ 0.28' message
  rather than booting a lane it can't drive. Supplies `--session`, `connect`, `get
  cdp-url`, `AGENT_BROWSER_SESSION`. *(Future: doctor should assert `--version` ≥ 0.28,
  not just executability.)* Because we pass through the **entire** verb surface (§2.4),
  anything the Vercel tool can do, `agent-browser-pool <verb>` supports.
- `google-chrome-stable` (or whatever `$AGENT_CHROME_BIN` points at).
- **btrfs** at the pool root (enables `cp --reflink=always`).
- util-linux: `flock`, `setsid`; procps-ng: `pgrep`, `pkill`; coreutils: `cp`
  (with `--reflink`); `curl` (CDP probing); `jq` (lease JSON); `notify-send`
  (libnotify — exhaustion alerts; optional). `/proc` filesystem (Linux only).
- `agent-browser-pool doctor` (§2.12) should verify all of the above at runtime.

### 2.17 Install (no cutover danger)
There is **no PATH shadowing** — the real `agent-browser` is never intercepted, so
installing the pool cannot disrupt running agents or other `agent-browser` users.
`install.sh` does three benign things:
1. symlinks `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool` (the sole entry point);
2. pre-creates the pool state dir (`lanes/` + `acquire.lock`);
3. runs `doctor` to verify the real `agent-browser` ≥ 0.28, Chrome, btrfs, and the master profile.
Because lane selection is by caller identity (never a PATH interception), agents still on
the old manual workflow are simply unaffected — they aren't calling `agent-browser-pool`
yet. Coexistence is trivial and per-call. **Removed:** the `AGENT_BROWSER_POOL_DISABLE`
safety valve (nothing to bypass) and the `~/scripts`-ahead-of-`~/.local/bin` PATH requirement.

**The agent skill is cross-harness, installed per-harness.** The skill is an Agent
Skills-standard skill at `.agents/skills/agent-browser-pool/` (discovered project-scoped
inside this repo). `install.sh --global-skill` symlinks it into `~/.agents/skills/`. To
teach each harness natively, install into its own skills dir:

| Harness | Global skills dir | Project skills dir | Follows symlinks? |
|---|---|---|---|
| pi | `~/.agents/skills/`, `~/.pi/agent/skills/` | `.agents/skills/` | yes |
| Claude Code | `~/.claude/skills/` | `.claude/skills/` | yes |
| Codex | `~/.codex/skills/` | `.agents/skills/` | **no — openai/codex#11314** |
| Antigravity (agy/IDE) | `~/.antigravity/skills/` | `.antigravity/skills/` | verify |

> **Codex caveat:** Codex does not discover a *symlinked* `.agents/skills` (openai/codex#11314).
> For Codex, install the skill as a real directory copy into `~/.codex/skills/` (or wait for
> the upstream fix). pi and Claude Code follow symlinks, so `--global-skill` suffices for them.

### 2.18 Testing & validation
- **Owner resolution needs a recognized-harness ancestor.** A command run from a
  plain interactive shell has none → driving commands can't key a lane (§2.4 step 1).
  Remedies: (a) run the command **under a supported harness** (`pi`/`claude`/`codex`/
  `agy`) so owner resolution works for real; or (b) set testability overrides
  `AGENT_BROWSER_POOL_OWNER_PID=<pid>` (+ `_OWNER_STARTTIME`) to simulate distinct
  agents from distinct subshell PIDs. (Narrowly-scoped test hooks; pool verbs like
  `status`/`doctor` need no owner and work from any shell.)
- **Smoke tests launch a real, windowed Chrome** — on Hyprland that pops a visible
  window. For unattended harness runs set `AGENT_CHROME_HEADLESS=1` (plumbing tests
  only; headless trips some anti-bot walls, so it's not valid for trusted-profile
  wall-passing validation).
- **A long-lived interactive harness** (e.g. the main `pi`, or a persistent
  `claude`/`codex`/`agy` session) keeps its lease until explicit release — every test
  must call `agent-browser-pool release`/`reap` and assert the ephemeral dir + Chrome
  process group are gone.
- **Concurrency harness:** N parallel "agents" (distinct owner PIDs via the
  override) must each get a distinct lane; assert no two share a lane and all
  release cleanly with no leftover dirs/processes.

### 2.19 Implementation notes (gotchas for the implementer)
- **`/proc/<pid>/stat` parsing:** `comm` is field 2 but wrapped in parens and may
  contain spaces, shifting everything after it. Read `starttime` **from the right**
  (it's field 22 from the start → index `NF-19` after `awk` split on space), not by
  naïve left count.
- **Process-group teardown:** launch with `setsid` so Chrome is its own group
  leader (pgid == pid); release does `kill -- -<pgid>` (note the `--` and negative
  pid) to take down renderer/GPU/utility children with no orphans.
- **Keep the flock critical section short:** claim the lane (scan + write lease)
  under `flock`, then **release before launching Chrome** so concurrent acquires
  boot in parallel rather than serializing on a ~10 s Chrome startup.
- **Atomic lease writes:** write `lanes/<N>.json.tmp` then `mv` (rename is atomic
  on the same FS); never write the lease in place.
- **Reflink detection:** `cp --reflink=always`; on failure (non-btrfs) refuse
  unless `AGENT_CHROME_ALLOW_SLOW_COPY=1` (a 4.8 GB real copy per acquire is a
  footgun).
- **No bare `~` anywhere** (§2.2): resolve `$HOME` to absolute up front for every
  path handed to Chrome, `rm`, logs, or any subprocess.

---

## 3. Repository layout (planned)
```
agent-browser-pool/
├── README.md
├── PRD.md                      ← this file
├── .gitignore
├── install.sh                  ← symlinks bin/agent-browser-pool onto PATH + doctor
├── bin/
│   └── agent-browser-pool      ← SOLE entry point: pool verbs + driving router (sources lib/pool.sh)
├── lib/
│   └── pool.sh                 ← shared: owner resolve / acquire / release / reap / copy / launch
├── .agents/skills/agent-browser-pool/
│   └── SKILL.md                ← the agent contract (the only browser skill; teaches the full surface)
└── test/
    └── validate.sh             ← concurrency / mutual-exclusion / release harness
```
~250 LOC bash total. No fork, no Rust, no daemon.

---

## 4. Decisions (all resolved)

- **O1 — Ephemeral dir location:** isolated subdir `~/.agent-chrome-profiles/active/<N>/`. ✅
- **O2 — `close` semantics:** disconnect-only mid-task; ephemeral dir deleted only on
  true release (owner exit / explicit). ✅
- **O3 — Exhaustion wait + alert:** wait **600 s (10 min)**, then force-reap a dead
  lane, then `notify-send` + log. ✅
- **O4 — Source profile.** `$AGENT_CHROME_MASTER`, default = your real Chrome
  user-data-dir (`${XDG_CONFIG_HOME:-~/.config}/google-chrome`). The CoW source may be
  live/in-use (agents copy the current state each acquire → new logins propagate); the
  pool treats it as read-only (never launched/written/deleted). Stale `Singleton*`
  locks stripped from each copy. For guaranteed copy consistency, point at a dedicated
  frozen template. ✅
- **O5 — No PATH shadowing (pivot).** The pool is invoked explicitly as
  `agent-browser-pool` (sole entry point + skill), NOT by shadowing the real
  `agent-browser`. Removes the cutover danger, the `~/scripts` PATH-ordering
  requirement, and `AGENT_BROWSER_POOL_DISABLE`. ✅
- **O6 — Invariant command, identity-keyed lanes.** The lane is selected by the
  caller's `(pid, comm, starttime)` identity — never an argument — so the agent's
  command (`agent-browser-pool <verb> <args>`) is identical on every lane, and
  cross-lane access is impossible through normal use. ✅
- **O7 — Full surface owned.** Every real-`agent-browser` verb passes through
  unchanged; the pool owns only connection/session/lifecycle. ✅
- **O8 — `agent-browser` is a hard runtime dependency**, enforced by `doctor` + a
  pool preflight (fail-fast); called by absolute path, not required on PATH. ✅
- **O9 — Multi-harness owner resolution.** Owner resolution generalizes from
  `pi`-only to a **recognized harness set** (default `pi,claude,codex,agy,antigravity`;
  configurable via `$AGENT_BROWSER_POOL_HARNESSES`, §2.11). The lease records the *actual*
  matched `comm`, so identity, reuse, and stale-detection work identically for every
  harness. Driving commands fail fast only when NO recognized harness is an ancestor;
  the skill is installed per-harness (§2.17, incl. the Codex symlink caveat). ✅ (Resolves
  the earlier "[DEFAULT: pi-required; … future option]" note in §2.4.)

Everything is locked: btrfs/reflink copies, delete-on-release, block-with-timeout
+ alert, reuse-orphan-if-responsive, explicit invariant invocation, identity-keyed
isolation, `agent-browser-pool` binary, port base 53420, `$HOME`/absolute-path
resolution, and multi-harness owner resolution (pi/Claude Code/Codex/AGY, O9).
Ready to build.
