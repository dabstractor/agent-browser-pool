# Research — P1.M4.T3.S1: daemon connect + verify + process-group teardown

**Host-verified: 2026-07-12** on `agent-browser` v0.28.0 (Rust binary,
`/home/dustin/.local/bin/agent-browser` → `agent-browser-linux-x64`, npm `agent-browser`,
repo `github.com/vercel-labs/agent-browser`, docs `agent-browser.dev`).
Chrome: `google-chrome-stable` 149. All experiments used throwaway session names
(`abpool-*-$$`) to avoid the 24 existing manual sessions on the shared daemon
(FINDING 4: t7, weaveapply, curaihealthlane, …).

---

## §1. `agent-browser --session <name> connect <port|url>` — the BINDER

| target                     | rc   | behavior                                                        |
|----------------------------|------|-----------------------------------------------------------------|
| LIVE pooled chrome on port | **0** | binds the daemon session to that chrome; prints `✓ Done`        |
| DEAD port (no listener)    | **1** | clean failure: `✗ All CDP discovery methods failed for …: … Connection refused (os error 111)` |
| bogus ws:// URL            | **0** | *(edge — agent-browser reports the failure string but the wrapper-level rc was 0 for a ws:// URL pointing nowhere; the POOL only ever passes a numeric port, where rc is a clean 0/1)* |

**CONCLUSION:** as a binder, `connect <numeric-port>` is a clean 0/1 — exactly what the
item CONTRACT step 3a specifies. `pool_daemon_connect(session, port)` is a thin,
non-fatal wrapper: `"$POOL_REAL_BIN" --session "$session" connect "$port"`; return its rc.

- The daemon **auto-starts on the first command** of a session (README › Architecture;
  subagent finding 12) — no explicit daemon-start is needed before `connect`.
- `connect` is **idempotent / re-bindable**: re-running `connect <same-live-port>` after
  a prior connect returns rc 0 and the session's cdp-url again reports that port.
  Verified (reconnect rc=0, post-reconnect url port == pooled port).
- `--session <name>` is an **isolated, persistent binding** in the shared daemon
  (README › Sessions; subagent finding 13). The pool's `abpool-<N>` namespace does NOT
  collide with the existing manual sessions.

---

## §2. `agent-browser --session <name> get cdp-url` — THE AUTO-LAUNCH TRAP ⚠️

This is the **single most important finding** in this research and it INVALIDATES the
literal premise of both the item CONTRACT step 3b and PRD §2.4 step 4.

### 2.1 Observed behavior (host-verified)

| session state                                  | rc   | output                              | side effect                       |
|------------------------------------------------|------|-------------------------------------|-----------------------------------|
| bound to pooled chrome (port P)                | **0** | `ws://127.0.0.1:P/devtools/browser/…` | none (chrome already exists)      |
| **never connected** (fresh session name)       | **0** | `ws://127.0.0.1:<RANDOM>/…`         | **🚨 AUTO-LAUNCHES a managed Chrome** |
| **chrome died** after a prior connect          | **0** | `ws://127.0.0.1:<RANDOM>/…`         | **🚨 AUTO-LAUNCHES a managed Chrome** |

The "managed Chrome" is agent-browser's OWN Chrome (Chrome for Testing / detected system
Chrome) on a **random port** (35961, 37163, 46733, … — NOT a pool port), with a temp
user-data-dir under `/tmp/agent-browser-chrome-*` (FINDING 5 — the exact accumulation the
pool exists to eliminate).

### 2.2 The smoking gun (STEP E of the steady-state experiment)

```
pooled chrome bound on port 55597 (session connected, get cdp-url → ws://127.0.0.1:55597/…)
→ kill the pooled chrome (kill -9 -- -<pgid>)
→ agent-browser --session <name> get cdp-url
   rc=0, url=ws://127.0.0.1:46733/…
   chrome procs BEFORE get: 61   AFTER get: 67      ← 🚨 STRAY CHROME AUTO-LAUNCHED
```

### 2.3 Why this is CATASTROPHIC for the pool (not just a leak)

PRD §2.4 step 4 (ENSURE-CONNECTED) literal design:
```
agent-browser --session abpool-<N> get cdp-url >/dev/null 2>&1 || agent-browser --session abpool-<N> connect <port>
```
On agent-browser 0.28.0 this is broken TWO ways:

1. **`get cdp-url` ALWAYS returns rc 0** (it auto-launches rather than failing). So the
   `|| connect <port>` recovery branch **never fires**.
2. When the pooled chrome is momentarily unreachable (crash, slow boot, daemon restart),
   `get cdp-url` **launches a STRAY chrome on a random port and re-binds the session to
   the STRAY**. The agent then **silently drives the stray** (fresh profile, no auth, no
   tabs) instead of its pooled authenticated profile — violating the pool's core contract.
   Plus it leaks Chrome processes (the `/tmp/agent-browser-chrome-*` problem, FINDING 5).

### 2.4 There is NO documented disable flag

Subagent (researcher) scanned the full README Options table + SKILL.md: there is **no**
`--no-launch` / `--no-auto-launch` / `AGENT_BROWSER_NO_LAUNCH` / `AGENT_BROWSER_NO_AUTO_LAUNCH`.
The only launch/connection toggles that exist are the *opposite* concern:
`--auto-connect`/`AGENT_BROWSER_AUTO_CONNECT` (attach to an already-running Chrome),
`--cdp <port|url>` (attach to an existing endpoint), `--provider` (cloud browser),
`--executable-path` (which binary). **None makes `get cdp-url` a pure non-launching probe.**
The closest launch-adjacent control is `AGENT_BROWSER_IDLE_TIMEOUT_MS` (daemon exits after
idle) — it does not prevent the next command from relaunching.

**CONCLUSION:** `get cdp-url` **MUST NOT** be used as the connected-check primitive.
`pool_daemon_connected` must use a **side-effect-free** probe instead (§4).

---

## §3. `session list` — the READ-ONLY, NON-LAUNCHING introspection ✅

| property                                       | verified                                                                  |
|------------------------------------------------|---------------------------------------------------------------------------|
| read-only / no chrome launch                   | chrome proc count UNCHANGED across a `session list` call (72 → 72) ✓       |
| rc                                             | **0** regardless of whether the queried session exists                     |
| `--json` envelope                              | `{"success":true,"data":{"sessions":["name1","name2",…]}}`                 |
| never-seen session                             | **absent** from `data.sessions` (grep count 0) ✓                          |
| session after `connect <live-port>`            | **appears** in `data.sessions` (count 1) ✓                                |
| session after `close`                          | **STILL PRESENT** in `data.sessions` (count 1) — entry lingers ✗ (imprecise) |

**CONCLUSION:** `session list` is a safe, side-effect-free way to ask "does the daemon
know about session X at all?" Membership is a **conservative** signal:
- absent ⇒ the daemon was never connected / restarted fresh ⇒ **definitely need to (re)connect**.
- present ⇒ the session was created at some point (may still be bound, or lingering after
  a disconnect-only `close` — PRD §2.8). Present + live-chrome ⇒ treat as connected
  (matches PRD §2.8's "next call reuses the same browser" intent; the [OPEN — confirm] is
  M6.T1.S2's close-interception concern, not this primitive's).

---

## §4. `curl http://127.0.0.1:<port>/json/version` — the side-effect-free CHROME probe ✅

| chrome state    | rc            | side effect |
|-----------------|---------------|-------------|
| alive (CDP up)  | **0** (HTTP 200) | none        |
| dead / no listener | non-zero (curl 7: connection refused) | none |

- **Never launches anything.** It probes Chrome's HTTP endpoint directly, no daemon call.
- Instant on refusal (rc 7) — cheap on the hot path.
- This is the SAME idiom already used by `pool_wait_cdp` (M4.T2.S2) and `pool_find_free_port`
  (M4.T2.S1), so it is idiomatic in this codebase.

**CONCLUSION:** this is the authoritative, side-effect-free "is the pooled chrome alive?"
probe. Combined with the `session list` membership check (§3), it yields a correct,
stray-free `pool_daemon_connected` (§6).

---

## §5. Process-group teardown — `kill -- -<pgid>` (host-verified, idempotent)

Setup: `setsid sleep 300 &; SP=$!; PGID=$(ps -o pgid= -p $SP|tr -d ' ')` → **PGID == SP**
(the setsid contract, also verified by M4.T2.S2).

| command                                      | target state   | rc (unguarded) | meaning                          |
|----------------------------------------------|----------------|----------------|----------------------------------|
| `kill -- -"$PGID"` (SIGTERM, default)        | live pgroup    | 0              | whole group signalled            |
| `kill -- -"$PGID"` (SIGTERM)                 | already dead   | **1** (ESRCH)  | no such process ⚠️ needs `\|\| true` |
| `kill -9 -- -"$PGID"` (SIGKILL)              | already dead   | **1**          | same — needs `\|\| true`         |
| `kill "$PID"` (bare pid, SIGTERM)            | already dead   | **1**          | fallback also needs `\|\| true`  |
| `kill -9 "$PID"`                             | already dead   | **1**          | same                             |
| `kill -0 "$PID"`                             | dead           | 1              | liveness test                    |

**KEY POINTS:**
1. **`--` is MANDATORY** on every negative-pid `kill`: the pgid is a positive int but the
   arg starts with `-`, so `kill` would parse `-<pgid>` as a flag without `--`.
   `kill -- -"$PGID"` signals the whole process group (negative pid).
2. **Every `kill` of an already-dead target returns rc 1 (ESRCH)** — under `set -euo
   pipefail` (propagated by `lib/pool.sh` line 17) a bare `kill -- -"$PGID"` on a dead
   group **ABORTS the caller**. Every kill MUST be `… 2>/dev/null || true`.
3. **Idempotency is achieved purely via `|| true`** — calling on already-dead processes is
   a no-op (rc 1 swallowed). No pre-check (`kill -0`) needed; the contract's "idempotent"
   requirement is satisfied by guarding every signal.
4. **SIGTERM → sleep 0.5 → SIGKILL escalation is sound**: Chrome (and `sleep`) respond to
   SIGTERM, but renderer/GPU/utility children can lag; the 0.5 s grace then SIGKILL catches
   stragglers. Verified: the `sleep` pgroup leader died on SIGTERM alone; the SIGKILL then
   returns 1 (already dead) harmlessly.
5. **Bare-pid fallback** (`kill "$PID"` / `kill -9 "$PID"`) is the contract's fallback for
   when the pgid is unknown/0 (a provisional lease writes chrome_pgid=0) or the group kill
   missed the leader. Numeric-guarded so a 0/empty arg is skipped.

**RELATIONSHIP to `pool_wait_cdp` (M4.T2.S2):** `pool_wait_cdp` has its OWN inline
single-SIGKILL (`kill -- -"$POOL_CHROME_PGID"`) for the CDP-timeout cleanup path — a fast
"abort a half-booted chrome". `pool_chrome_kill` (THIS task) is the CANONICAL, thorough
teardown (SIGTERM→grace→SIGKILL + bare-pid fallback) for release/reap. They are DIFFERENT
intentionally; **do NOT refactor pool_wait_cdp to call pool_chrome_kill** (out of scope;
pool_wait_cdp is M4.T2.S2's deliverable and its inline kill predates this function).

---

## §6. Resulting design for `pool_daemon_connected` (stray-free)

The item CONTRACT step 3b literally says `get cdp-url >/dev/null 2>&1` → return 0/1.
§2 proves this is broken (always 0 + launches strays). The CORRECT, side-effect-free
implementation combines §3 + §4:

```
pool_daemon_connected(session, port):           # port ADDED (contract said session-only)
  1. session known to the daemon?               # §3 — read-only, no launch
     agent-browser --json session list | jq -e --arg s "$session" '.data.sessions|index($s)' >/dev/null
     || return 1            # absent ⇒ fresh/restarted daemon ⇒ must (re)connect
  2. pooled chrome alive?                        # §4 — curl, no launch
     curl -sf http://127.0.0.1:<port>/json/version >/dev/null 2>&1
     || return 1            # chrome crash (PRD §2.14 primary failure) ⇒ relaunch+reconnect
  3. return 0               # session known + chrome alive ⇒ connected/drivable
```

**Why the signature gains `port`:** the only reliable, stray-free signal for "connected"
is the pooled chrome's liveness (curl), which needs the port. `get cdp-url` (the
contract's chosen command) is unusable. `session` is still used (step 1). This is a
minimal, justified deviation from the literal contract in service of the contract's
INTENT ("return 0 if connected, 1 if not") — the alternative (literal `get cdp-url`)
ships a function that always lies AND leaks chromes.

**Known limitation (documented for consumers):** after a disconnect-only `close`
(PRD §2.8, M6.T1.S2), the session lingers in `session list` (§3 last row) and the chrome
stays alive, so this returns 0 ("connected"). Per PRD §2.8 that is the INTENDED behavior
("next call reuses the same browser"); the daemon re-attaches on the next drive. The
PRD §2.8 `[OPEN — confirm]` on close semantics is M6.T1.S2's concern, not this primitive's.

**Flagged for M5.T1.S3 (ensure_connected):** the literal PRD §2.4 step 4
(`get cdp-url || connect`) is BROKEN on 0.28.0 (§2.3). ensure_connected should call
`pool_daemon_connected(session,port)` (this primitive) instead of the raw `get cdp-url`
probe. Recommended safe orchestration: `pool_daemon_connected || pool_daemon_connect`.

---

## §7. Naming, placement, consumers

- **Names (item CONTRACT, authoritative):** `pool_daemon_connect`, `pool_daemon_connected`,
  `pool_chrome_kill`. (key_findings' `pool_lane_*` convention is a suggestion; the CONTRACT
  wins for this task. `pool_chrome_kill` pairs naturally with `pool_chrome_launch` M4.T2.S2.)
- **Placement:** APPEND at EOF of `lib/pool.sh`, under a new banner, directly after
  `pool_wait_cdp`'s closing brace (the M4.T2.S2 deliverable, currently the last function).
  Pure addition — no edits to any existing function.
- **Globals read:** `POOL_REAL_BIN` (pool_daemon_connect/connected; frozen by
  pool_config_init M1.T1.S2). pool_chrome_kill reads NONE (args only).
- **Consumers (item CONTRACT §4 + plan):**
  - M5.T1.S2 acquire post-lock boot → `pool_daemon_connect` (PRD §2.4 step 3i).
  - M5.T1.S3 ensure_connected → `pool_daemon_connected` (PRD §2.4 step 4 — see §6 flag).
  - M5.T2.S1 release → `pool_chrome_kill`.
  - M5.T3.S1 reap_stale → `pool_chrome_kill`.
  - M5.T3.S2 reuse_orphan → `pool_daemon_connected` + `pool_daemon_connect`.
- **All three are NON-FATAL** (return rc, never pool_die): they run inside
  acquire/release/reap orchestration where one dead lane must not abort the whole pool.
  Same family as `pool_wait_cdp` / `pool_find_free_port` / `pool_lease_read`.

---

## §8. Subagent corroboration (researcher, 2026-07-12)

The `researcher` subagent independently confirmed (reading the installed v0.28.0 README,
package.json, bin launcher, postinstall, SKILL.md):
- repo `github.com/vercel-labs/agent-browser` (NOT `vercel/agent-browser`); docs
  `agent-browser.dev`; npm `agent-browser`; native Rust binary `agent-browser-linux-x64`.
- daemon **auto-starts on first command** and persists; `--session` is an isolated binding.
- **auto-launch on a dead session is confirmed behavior**; **no disable flag exists**.
- `--json` envelope `{"success":true,"data":{…}}`; `get cdp-url --json` →
  `{"success":true,"data":{"cdpUrl":"ws://…"}}` (matches §2/§4 observed).
- exit codes are **undocumented** in the README — hence this host verification (§1/§2).
Full output: `.pi-subagents/artifacts/outputs/5b03d245/research.md`.
