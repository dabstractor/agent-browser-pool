# PRD & Technical Spec — `agent-browser-pool`

**Status:** Design / brainstorm. Open items are boxed at the end. Decisions marked
**[DEFAULT]** are applied pending your confirmation.

**One-line goal:** Every AI agent that types `agent-browser …` gets its own
dedicated, locked, trusted Chrome profile for its whole session — with zero
awareness pooling is happening — and the Chrome + profile are guaranteed cleaned up
when the agent finishes or crashes.

---

## 1. Product Requirements

### 1.1 Background
- `agent-browser` (Vercel, v0.28.0, Rust CLI) drives Chrome over CDP. It is
  **env-driven**: `AGENT_BROWSER_SESSION=<name>` selects a **persistent daemon
  process** keyed by name; `agent-browser --session <name> connect <port>` binds
  that daemon to a Chrome on a port; every later `AGENT_BROWSER_SESSION=<name>
  agent-browser …` routes there. (Verified.)
- Every `bash` tool call an agent makes is a child of one **`pi` process**; walking
  `ppid` to `comm == pi` yields a stable, unique-per-agent PID. (Verified: this
  session → 836725.) Subagents are separate `pi` processes → separate lanes.
- The pool root `~/.agent-chrome-profiles` is on **btrfs**, so `cp --reflink=always`
  makes profile copies **instant and deduplicated** (each profile ≈ 4.8 GB; CoW
  shares all blocks until the agent writes). This is what makes ephemeral profiles
  viable. (Verified.)

### 1.2 The model (ephemeral profiles from a master copy)
- **One static master template** at `~/.agent-chrome-profiles/master-profile` holds the
  identity every agent should start from (Google login, Bitwarden, the
  agent-browser extension — whatever you put there).
- On **acquire**, the wrapper copy-on-writes the master into a fresh **ephemeral**
  dir, launches Chrome against it, connects the daemon, and records a lease.
- On **release**, the wrapper kills the Chrome process group, **deletes the
  ephemeral dir**, and drops the lease. The master is never mutated or deleted.
- Persistent dirs `~/.agent-chrome-profiles/{1..10}` (your current working set) are
  **outside the wrapper's world** — it never touches them. Ephemeral dirs live in an
  isolated subdir (see §2.3).

### 1.3 Goals
1. **Transparency.** Agents run `agent-browser …` exactly as upstream teaches and
   it Just Works — same browser for the whole session, no flags/port/session to
   remember. The agent cannot tell pooling is happening.
2. **1 agent = 1 browser = 1 ephemeral profile.** No two agents ever share a Chrome.
3. **Mutual exclusion.** Held lanes can't be grabbed; the next agent gets the next
   free one.
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
- Agent runs `agent-browser open <url>` with zero prep → opens in a trusted,
  logged-in Chrome that only it is using.
- Every later `agent-browser …` in the session hits that same Chrome, even though
  each command is a fresh shell.
- When the agent's `pi` process exits (task done / crash), its Chrome is killed and
  its ephemeral profile deleted within milliseconds.
- Human runs `agent-browser-pool status` to see lanes/owners/ages, and
  `agent-browser-pool reap` to clean any leaked Chrome.

---

## 2. Technical Spec

### 2.1 Components (two binaries + one lib)
```
~/scripts/agent-browser             ← shadow wrapper (symlink → repo bin/; ahead of ~/.local/bin on PATH)
/home/dustin/.local/bin/agent-browser-pool   ← admin tool (symlink → repo bin/)
repo/lib/pool.sh                    ← shared lease logic (owner resolve / acquire / release / reap / copy / launch)
                                     ↓ calls by absolute path
/home/dustin/.local/bin/agent-browser        ← real CLI (unchanged, upgradable)

~/.local/state/agent-browser-pool/  ← lease store + logs (runtime, not in repo)
├── acquire.lock                    ← short global flock
├── lanes/<N>.json                  ← one lease per held lane
└── chrome-<N>.log                  ← per-lane Chrome stderr/stdout

~/.agent-chrome-profiles/
├── master-profile/                    ← static template (you create once; never launched)
├── active/<N>/                     ← ephemeral lanes (CoW copy of master; deleted on release)
└── 1..10/                          ← your persistent working set — UNTOUCHED by the wrapper
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
from `master-profile`, so there is no collision logic and no "skip 1–10" special case.
(The earlier "range 11+" instruction is satisfied more robustly by isolation.)

### 2.4 Request lifecycle (the wrapper, per invocation)
```
agent-browser <args>
 ├─ 0. Parse first non-flag token → dispatch:
 │     DRIVING (open/click/type/snapshot/eval/get/find/.../connect/close/session …) → lane logic
 │     META/passthrough (skills / --help / -h / --version / dashboard / plugin / session list) → exec real binary unchanged
 ├─ 1. Resolve OWNER: walk ppid to first comm=="pi"; record {pid, comm, starttime}.
 │     No pi ancestor (human in a terminal) → passthrough, no lane magic.
 ├─ 2. Find MY lease (scan lanes/*.json for owner.pid==pid && comm=="pi" && starttime match).
 │     Found & valid → reuse lane N → goto 4.
 ├─ 3. ACQUIRE (no valid lease):
 │     under short flock(acquire.lock):
 │       a. REAP-STALE: for each lane whose owner pid is dead / comm!="pi" / starttime mismatch
 │          → kill its Chrome pgroup, rm -rf its ephemeral dir, delete lease.
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
 └─ 5. EXEC real binary with AGENT_BROWSER_SESSION=abpool-<N> forced + original args.
       Strip any inherited --session / AGENT_BROWSER_SESSION so the agent can't bypass its lane.
```

**Transparent absorption of upstream-skill patterns** (agents follow `skills get
core` to the letter and still land on their lane):
- `agent-browser connect [<anything>]` → ensure my lane connected; **ignore** the arg.
- `agent-browser --session <X> …` → **override** to `abpool-<N>`.
- `agent-browser close [--all]` → **disconnect my lane's daemon only**; never touch
  other owners' lanes (raw `--all` would nuke peers).

### 2.5 Release semantics
Release is **owner-liveness-driven**, not TTL-driven (no idle timer). Triggers:

| trigger | action |
|---|---|
| Owning `pi` exits (task done / killed / crash) | detected by next acquire's REAP-STALE → kill pgroup, `rm -rf` ephemeral dir, delete lease |
| Explicit `agent-browser-pool release [<N>\|all]` | same teardown |
| Pool-exhaustion block timeout (§2.9) | force-reap the oldest dead-owner lane, then proceed; **alert** (this signals a leak) |

**`agent-browser close` (mid-task) = disconnect-only.** The daemon detaches but the
lane, Chrome, and ephemeral dir stay alive, so the agent's next call reuses the
*same* browser (open tabs/forms preserved) without a redundant master copy. The
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

### 2.7 Copy / master hygiene
- `cp -a --reflink=always <master> <active/N>` → instant CoW on btrfs. If the FS
  ever isn't btrfs, **fail loudly** (don't silently do a 4.8 GB real copy per
  acquire) unless `AGENT_CHROME_ALLOW_SLOW_COPY=1`.
- After copy: `rm -f <active/N>/SingletonLock <active/N>/SingletonCookie
  <active/N>/SingletonSocket` (stale locks from the template would confuse Chrome).
- `master-profile` is read-only as far as the wrapper is concerned: never launched,
  never mutated, never deleted.

### 2.8 Lease data model (`lanes/<N>.json`)
```json
{
  "version": 1,
  "lane": 7,
  "ephemeral_dir": "/home/dustin/.agent-chrome-profiles/active/7",
  "port": 53427,
  "session": "abpool-7",
  "owner": { "pid": 836725, "comm": "pi", "starttime": 1234567890, "cwd": "/home/dustin/projects/x" },
  "chrome_pid": 104816,
  "chrome_pgid": 104816,
  "acquired_at": 1720000000,
  "last_seen_at": 1720000123,
  "connected": true
}
```
- One owner holds ≤1 lane (enforced at acquire step 2).
- `starttime` (from `/proc/<pid>/stat` field 22) defeats PID recycling into a new pi.

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
- **Master template:** `$AGENT_CHROME_MASTER` (default
  `~/.agent-chrome-profiles/master-profile`).
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
- **Bypass (safety valve):** `$AGENT_BROWSER_POOL_DISABLE=1` → wrapper passes through to the real binary with no pooling (per-process). See §2.17.

### 2.12 Admin CLI — `agent-browser-pool`
```
status                 # lane | port | session | owner pid+cwd | chrome pid | age | state
reap                   # kill+delete dead-owner lanes
release [<N>|all]      # explicit teardown
doctor                 # reconcile leases vs live Chromes vs dirs; report leaks
```

### 2.13 Safety & identity rules (carried from the prior skill, non-negotiable)
Each ephemeral profile starts as a clone of the master identity:
- **Never enter credentials; never unlock Bitwarden.** Existing SSO/Google login is
  fine to *use*; never type a password.
- **Verify the target URL before every click/fill/navigate.**
- **Never drive the human's daily driver** (`~/.config/google-chrome`); the pool
  exists so agents never need to.

### 2.14 Failure modes & recovery
| failure | detection | recovery |
|---|---|---|
| agent `pi` crash/kill | owner pid dead | REAP-STALE → kill pgroup, rm dir, drop lease |
| PID recycled into non-pi | comm != "pi" | stale → reclaimed |
| PID recycled into new pi | starttime mismatch | stale → reclaimed |
| Chrome crash mid-task | `get cdp-url` fails in ENSURE-CONNECTED | relaunch on same dir+port, reconnect, keep lease (open tabs lost; profile kept) |
| Chrome slow to boot | /json/version timeout (15s) | retry launch once; then fail, drop lane |
| master-profile missing | acquire precheck | fail with the exact `cp` command to create it |
| FS not btrfs | acquire precheck | refuse unless `AGENT_CHROME_ALLOW_SLOW_COPY=1` |
| Pool exhausted (accumulation) | no free lane | block→force-reap→alert (§2.9) |
| `npm -g` upgrades agent-browser | wrapper uses absolute path | unaffected |

### 2.15 Transparency checklist (the "no idea" contract)
- [ ] `agent-browser skills get core` → passthrough (unaffected).
- [ ] `agent-browser open <url>` with zero prep → opens in my locked ephemeral lane.
- [ ] Same browser for all my commands across many stateless bash calls.
- [ ] `agent-browser connect <x>` (as the skill teaches) → routed to my lane.
- [ ] `agent-browser --session <x> …` (as the skill teaches) → forced to my lane.
- [ ] `agent-browser close --all` → cannot harm other agents' lanes.
- [ ] Next agent → next free lane; never collides.
- [ ] My crash → my Chrome dies, my ephemeral dir is deleted, no manual cleanup.

### 2.16 Dependencies (all verified present on this host)
- `agent-browser` ≥ 0.28 — the wrapped CLI; supplies `--session`, `connect`, `get
  cdp-url`, and the `AGENT_BROWSER_SESSION` env. (Verified 0.28.0 at
  `/home/dustin/.local/bin/agent-browser`.)
- `google-chrome-stable` (or whatever `$AGENT_CHROME_BIN` points at).
- **btrfs** at the pool root (enables `cp --reflink=always`).
- util-linux: `flock`, `setsid`; procps-ng: `pgrep`, `pkill`; coreutils: `cp`
  (with `--reflink`); `curl` (CDP probing); `jq` (lease JSON); `notify-send`
  (libnotify — exhaustion alerts; optional). `/proc` filesystem (Linux only).
- `agent-browser-pool doctor` (§2.12) should verify all of the above at runtime.

### 2.17 Cutover & coexistence (read before installing)
Once `install.sh` symlinks `bin/agent-browser` into `~/scripts/`, the wrapper is
**global and process-wide**: every `agent-browser` call in every shell resolves to
it (`~/scripts` precedes `~/.local/bin` on PATH). That has a sharp edge mid-cutover:

- **Running agents on the old manual workflow** (`acquire.sh` + per-task
  `--session` + persistent profiles `1..10`) will have their next `agent-browser`
  call **silently intercepted**: owner resolution finds their `pi` PID, the wrapper
  overrides their `--session`/`connect` args, and they land on a fresh ephemeral
  lane — abandoning in-progress work on profile `3` (etc.). **This breaks running
  work.**
- So **install is deliberate, not automatic.** `install.sh` prints this warning and
  requires a confirmation flag.
- **Develop/test before cutover** by invoking the wrapper **by absolute path**
  (`…/bin/agent-browser …`) — exercises all logic without touching the
  PATH-resolved `agent-browser` that running agents use.
- **Safety valve:** `$AGENT_BROWSER_POOL_DISABLE=1` (per-process passthrough) lets a
  specific session stay on the old workflow during cutover, or aids debugging.
- **Migration:** once the manual `1..10` workflow is retired, remove the old
  skill's `acquire.sh` guidance and install the shadow. There is **no safe partial
  shadow** — the PATH mechanism is all-or-nothing; the disable env is the only
  per-session opt-out.

### 2.18 Testing & validation
- **Owner resolution needs a `pi` ancestor.** A harness run from a plain
  interactive shell has none → the wrapper enters passthrough and can't be
  exercised. Remedies: (a) run the harness **under pi** (a subagent) so owner
  resolution works for real; or (b) set testability overrides
  `AGENT_BROWSER_POOL_OWNER_PID=<pid>` (+ `_OWNER_STARTTIME`) to simulate distinct
  agents from distinct subshell PIDs. (Implement as narrowly-scoped test hooks.)
- **Smoke tests launch a real, windowed Chrome** — on Hyprland that pops a visible
  window. For unattended harness runs set `AGENT_CHROME_HEADLESS=1` (plumbing tests
  only; headless trips some anti-bot walls, so it's not valid for trusted-profile
  wall-passing validation).
- **The main interactive `pi` is long-lived**, so a lease it takes persists until
  explicit release — every test must call `agent-browser-pool release`/`reap` and
  assert the ephemeral dir + Chrome process group are gone.
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
├── install.sh                  ← symlinks bin/* onto PATH
├── bin/
│   ├── agent-browser           ← wrapper shim (sources lib/pool.sh, dispatches)
│   └── agent-browser-pool      ← admin tool
├── lib/
│   └── pool.sh                 ← shared: owner resolve / acquire / release / reap / copy / launch
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
- **O4 — Master template:** `~/.agent-chrome-profiles/master-profile` (created by the
  user; 4.8 G real profile, verified). Its stale `Singleton*` locks are stripped from
  each ephemeral CoW copy before launch. ✅

Everything is locked: btrfs/reflink copies, delete-on-release, block-with-timeout
+ alert, reuse-orphan-if-responsive, fully invisible, `agent-browser-pool` binary,
port base 53420, `$HOME`/absolute-path resolution. Ready to build.
