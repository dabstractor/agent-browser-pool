# Research — README facts (authoritative, taken straight from the implementation)

> Source of truth for P1.M10.T1.S1's README update. Every value below was read directly
> from the **implemented** `lib/pool.sh` (4302 lines), `bin/*`, and `install.sh` on
> 2026-07-14. The README MUST match these exactly — a README that disagrees with the
> tool's own `--help` / `doctor` output is a bug. **Static reads only (AGENTS.md §1).**

---

## 0. Why no external subagent research was needed

This is a **documentation-sync task**. The authoritative contract is the shipped code,
not external docs. The single highest-value research is extracting the exact env-var
defaults + admin output formats from `lib/pool.sh` (done below). A "good README structure"
web search would add less signal than the existing in-repo exemplar: `install.sh` is
already a Mode-A "this output IS the documentation" file, and the current README's
"30-second version" is already strong.

---

## 1. Current README.md state (what exists & what must change)

File: `README.md` (~95 lines). Written **pre-implementation** (greenfield phase).

Sections present:
- Title + 4-bullet overview (not-a-fork / ephemeral / 1-agent-1-browser / invisible) — GOOD, keep.
- "Status: **Design / brainstorm.** Implementation pending…" — **MUST CHANGE** → MVP is shipped.
- "Prerequisites" (master template, btrfs, install planned) — keep, expand.
- "How it works (30-second version)" — GOOD, keep, verify accuracy vs §3 below.

GAPS (none of these exist yet; all are required by the item contract a–i):
- Install section (`./install.sh`, confirmation, cutover warning).
- Usage for agents ("just type `agent-browser`").
- Admin commands reference with **example outputs** (status / reap / release / doctor).
- Configuration reference (env-var table with defaults).
- Safety valve (`AGENT_BROWSER_POOL_DISABLE=1`).
- Troubleshooting (pool exhaustion, leaks, doctor).
- Repo layout tree.

---

## 2. Env-var defaults — AUTHORITATIVE (lib/pool.sh:126-176 `pool_config_init` + `pool_admin_help` @4286-4300)

The `agent-browser-pool --help` output lists exactly these. README table MUST match.

| Env var | Internal global | Default | Meaning |
|---|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `POOL_STATE_DIR` | `~/.local/state/agent-browser-pool` | state dir (lease store `lanes/` + `acquire.lock` + `alerts.log` + `chrome-<N>.log` + `pool.log`) |
| `AGENT_CHROME_MASTER` | `POOL_MASTER_DIR` | `~/.agent-chrome-profiles/master-profile` | static master template (CoW source; never launched/mutated/deleted) |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `POOL_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs live at `<root>/<N>/` |
| `AGENT_BROWSER_REAL` | `POOL_REAL_BIN` | `~/.local/bin/agent-browser` | the REAL agent-browser CLI (called by absolute path; stays upgradable) |
| `AGENT_CHROME_BIN` | `POOL_CHROME_BIN` | `google-chrome-stable` | Chrome binary (bare name → `command -v`; path → `-f -x`) |
| `AGENT_CHROME_PORT_BASE` | `POOL_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `POOL_PORT_RANGE` | `1000` | # of ports in pool → range `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `POOL_WAIT` | `600` (10 min) | acquire block timeout (s) before force-reap+alert |
| `AGENT_CHROME_HEADLESS` | `POOL_HEADLESS` | unset = **windowed** | set to `1`/`true`/`yes` → launch Chrome `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | `POOL_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | set to allow a real (slow) 4.8 GB copy per acquire |
| `AGENT_BROWSER_POOL_DISABLE` | `POOL_DISABLE` | unset = **pooling active** | `1` = per-process passthrough (safety valve, §2.17) |

Test-only hooks (document in a clearly-marked "testing" note, NOT the user table):
`AGENT_BROWSER_POOL_OWNER_PID` + `AGENT_BROWSER_POOL_OWNER_STARTTIME` (simulate distinct
agent owners from a non-pi harness; PRD §2.18).

All paths are resolved to **absolute** (`$HOME` + `realpath`) before any subprocess —
a bare `~` is NEVER emitted to Chrome/rm/logs (PRD §2.2; the README should state this
as a guarantee, not a gotcha).

---

## 3. Wrapper request lifecycle — AUTHORITATIVE (lib/pool.sh:3451 `pool_wrapper_main`)

The "How it works (30-second version)" block in README must match this ordering:

```
a. config + state init
b. POOL_DISABLE==1                          → passthrough: exec real binary, no pooling
c. pool_dispatch_classify → "meta"          → passthrough: skills/--help/--version/session list/dashboard/plugin
d. pool_owner_resolve → no pi ancestor      → passthrough: human in a terminal, raw upstream tool
e. pool_lease_find_mine → reuse my lane N   (else acquire-locked → wait-for-lane)
f. if lane provisional (port 0) → pool_boot_lane ; else adopted orphan (skip boot)
g. pool_ensure_connected (reconnect if daemon died)
h. pool_normalize_close (scope --all to my lane) / pool_normalize_connect (strip arg) /
   pool_strip_session_args / pool_force_session abpool-<N>
i. exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"   (TERMINAL — process replacement)
```

Transparency absorption (PRD §2.4 — README "Usage" should mention these implicitly):
- `agent-browser connect <anything>` → routed to my lane (arg ignored).
- `agent-browser --session <X> …` → forced to `abpool-<N>`.
- `agent-browser close [--all]` → disconnects MY lane's daemon only; never harms peers.

Release triggers (PRD §2.5): owning `pi` exits (next acquire REAP-STALE reclaims it) /
explicit `agent-browser-pool release` / pool-exhaustion force-reap. **No idle TTL.**
`agent-browser close` mid-task = disconnect-only (lane/Chrome/dir survive for reuse).

---

## 4. Admin CLI — `agent-browser-pool` — AUTHORITATIVE output formats

Source: `bin/agent-browser-pool` (dispatcher; default cmd = `status`) →
`pool_admin_status` (3594) / `pool_admin_reap` (3730) / `pool_admin_release` (3830) /
`pool_admin_doctor` (4011) / `pool_admin_help` (4267).

### 4.1 `status` (default)
Format string (header + every row identical): `%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s`
Header: `LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE`
Empty pool → single line: `No active lanes.`
STATE values: `live` | `disconnected` | `STALE` (corrupt/unreadable lease row → fields `?`, state `STALE`).

### 4.2 `reap`
`No stale lanes found.`  OR  `Reaped N stale lane(s).`  (rc 0 always)

### 4.3 `release [<N>|all]`
- `release all` (N>0) → `Released N lane(s).`
- `release all` (N==0) → `No active lanes to release.`
- `release N` (lease exists) → `Released lane N.`
- `release N` (no lease) → `Lane N has no active lease.` (rc 1)
- `release` / `release foo` → STDERR usage block (rc 1):
  ```
  Usage: agent-browser-pool release [<N>|all]

  Release (tear down) one lane or all lanes.
    release N    Release lane N (explicit teardown).
    release all  Release all active lanes.
  ```

### 4.4 `doctor` — sections + verdict (rc 0 healthy / rc 1 problems)
```
[dependencies]   flock setsid pgrep pkill cp curl jq chrome($POOL_CHROME_BIN) → OK/MISSING; notify-send → OK / MISSING (optional)
[binary]         $POOL_REAL_BIN → OK / FAIL (missing or not executable)
[filesystem]     $POOL_EPHEMERAL_ROOT → OK (btrfs) / WARN (non-btrfs + slow-copy allowed) / FAIL (not btrfs)
[master]         $POOL_MASTER_DIR → OK / FAIL (missing or empty)
[lanes]          per lease: OK / WARN (LEAK(no dir)|LEAK(dead chrome)|DISCONNECTED|PROVISIONAL)
[dirs]           per numeric dir: WARN (ORPHAN DIR: no lease)  |  "(N dir(s), all leased)" / "(no ephemeral dirs)"
[summary]        OK=N  WARN=N  FAIL=N   +  "Healthy."  OR  "Problems found."
```

### 4.5 `help` / `--help` / `-h`
Prints the full subcommand list + the env-var table (this is the canonical one-line-per-var
listing — README's configuration table should be a superset with defaults filled in).

---

## 5. Chrome launch — AUTHORITATIVE (lib/pool.sh `pool_chrome_launch`, flags @1500-1508)

`setsid google-chrome-stable` +:
```
--remote-debugging-port=<port>
--user-data-dir=<ABSOLUTE active/N path>
--no-first-run --no-default-browser-check
--disable-background-timer-throttling
--disable-backgrounding-occluded-windows
--disable-renderer-backgrounding
--disable-features=CalculateNativeWinOcclusion
--disable-back-forward-cache
--headless=new        # IFF POOL_HEADLESS==1
```
- Windowed by default (trusted profiles must look real; headless is detectable).
- `setsid` → Chrome is its own process group (pgid==pid) → release does `kill -- -<pgid>`.
- Anti-throttle flags are REQUIRED on Wayland (else backgrounded pool windows' JS timers throttle).

---

## 6. Cutover warning — AUTHORITATIVE verbatim source = `install.sh`

`install.sh` is **Mode A** ("this script's warning + success output IS the cutover
documentation"). The README's Install section should mirror its language and point users
at `./install.sh` (and at `--force`/`--help`). Canonical sentences to preserve:
- `~/scripts` PRECEDES `~/.local/bin` on PATH → wrapper SHADOWS the real CLI.
- ALL-OR-NOTHING; no safe partial shadow; the disable env is the only per-session opt-out.
- Running agents on the OLD workflow are **silently intercepted** → abandons in-progress
  work on persistent profiles `1..10` → breaks running work.
- Install is **deliberate, not automatic**: `./install.sh` prints the warning and requires
  typing `YES` (or `--force`).
- Test BEFORE cutover by invoking the wrapper **by absolute path**: `…/bin/agent-browser …`.
- Safety valve: `export AGENT_BROWSER_POOL_DISABLE=1` (per-session passthrough).
- Uninstall: `rm -f ~/scripts/agent-browser ~/.local/bin/agent-browser-pool`.

What install.sh actually does: symlinks `bin/agent-browser`→`~/scripts/agent-browser`,
`bin/agent-browser-pool`→`~/.local/bin/agent-browser-pool`, pre-creates state dir
(`lanes/` + `acquire.lock` via `pool_state_init`), runs `doctor`.

---

## 7. Pool exhaustion + alerts (PRD §2.9) — AUTHORITATIVE (`pool_wait_for_lane`, `_pool_alert` @2815)

- No free/reusable lane → block up to `AGENT_BROWSER_POOL_WAIT` (600s), re-running
  REAP-STALE each poll iteration.
- Timeout → FORCE-reclaim the oldest lane whose owner is actually dead; **alert**.
- Even force-reap can't free one → `pool_die "agent-browser-pool: no lane available after
  600s + force-reap"` (non-zero exit).
- **Alert = best-effort `notify-send` desktop notification + ONE timestamped line appended
  to `$POOL_STATE_DIR/alerts.log`** (format: `<iso-ts> <SUMMARY>: <BODY>`). notify-send is
  OPTIONAL; a missing binary / headless session (no DISPLAY/DBUS) / unwritable log are all
  tolerated (best-effort, rc 0 always). **Hitting the alert at all signals a LEAK to investigate.**

---

## 8. Repo layout (what the README should show)

```
agent-browser-pool/
├── README.md                  ← this file (user docs — the changeset-level overview)
├── PRD.md                     ← full product requirements + technical spec (READ-ONLY)
├── AGENTS.md                  ← operating rules for AI agents in this repo
├── install.sh                 ← cutover installer (symlinks + doctor + warning)
├── bin/
│   ├── agent-browser          ← transparent PATH-shadowing wrapper shim (→ lib/pool.sh: pool_wrapper_main)
│   └── agent-browser-pool     ← admin CLI dispatcher (→ lib/pool.sh: pool_admin_*)
├── lib/
│   └── pool.sh                ← shared lease logic (config, owner, leases, acquire, boot, release, reap, admin)
└── test/
    ├── validate.sh            ← test framework (assertions, owner sim, hermetic setup/teardown)
    ├── concurrency.sh         ← N agents → N distinct lanes, no collision
    ├── release_reaper.sh      ← release + stale reaper + crash simulation
    └── transparency.sh        ← (from P1.M9.T4.S1) the "no-idea contract" checklist
```
Runtime (NOT in repo — created at install / on first run, gitignored):
`~/.local/state/agent-browser-pool/{lanes/<N>.json, acquire.lock, alerts.log, chrome-<N>.log, pool.log}`
and `~/.agent-chrome-profiles/{master-profile, active/<N>/}`.

---

## 9. Test suite — how to validate / reference in README

Run pattern (hermetic, timeout-bounded — AGENTS.md §1–4): `timeout 900 bash test/<file>.sh`
- `test/validate.sh` — framework + self-test.
- `test/concurrency.sh`, `test/release_reaper.sh` — landed.
- `test/transparency.sh` — produced by the parallel item P1.M9.T4.S1 (assume landed per its PRP).

README should NOT be a test how-to (that's AGENTS.md's job) but MAY mention the suite
exists + that `doctor` is the runtime self-check.

---

## 10. README accuracy/validation strategy (for the PRP's Validation gates)

A README is validated differently from code:
1. **Internal consistency**: env-var table in README == `agent-browser-pool --help` output
   (the help is generated from `pool_admin_help`; README must not invent/drop a var).
2. **Example-output faithfulness**: the `status`/`doctor`/`release` example blocks use the
   EXACT column labels / section headers / verdict strings the functions emit (§4 above).
3. **Bash-block syntax**: every ```bash fenced block parses (`bash -n` on the extracted block).
4. **Link integrity**: relative links resolve (PRD.md, AGENTS.md, install.sh); no dead anchors.
5. **Markdown well-formedness** (if `markdownlint`/`mdformat` present; optional — not a repo dep).
6. **Status line**: no longer says "Design / brainstorm / implementation pending".

The implementer can self-check #1/#2 by diffing the README's tables against the live
`agent-browser-pool --help` and a real (or hand-constructed) `status`/`doctor` run — but
per AGENTS.md, do NOT boot real Chrome during doc work; construct the example outputs from
the §4 format strings (they are deterministic), not from a live run.
