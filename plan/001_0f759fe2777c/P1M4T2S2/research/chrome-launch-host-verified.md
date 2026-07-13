# Research — P1.M4.T2.S2: Chrome launch with setsid + anti-throttle + CDP readiness wait

**Date:** 2026-07-12
**Host:** util-linux 2.42.2 · google-chrome-stable → Chrome 149.0.7827.114 · bash 5.x
**Method:** every claim below was executed against the real host (commands preserved verbatim).
The companion PRP cites these as `HOST-VERIFIED`.

---

## §0 — Results summary (all PASSED)

| check | result |
|---|---|
| Chrome binary present | `/usr/bin/google-chrome-stable` (310-byte wrapper → `/opt/google/chrome/chrome`) ✓ |
| `setsid` present | `/usr/bin/setsid` (util-linux 2.42.2) ✓ |
| **`setsid CMD &; SP=$!` → `$!` IS the cmd PID** | ✓ (the launched command's pid, NOT an intermediate) |
| **pgid == pid == sid** after `setsid … &` | ✓ `pgid=2031215 == pid=2031215 == sid=2031215` |
| Real Chrome boots with the full flag set | ✓ (no flag rejected; `DevTools listening on ws://…`) |
| CDP `/json/version` becomes reachable | ✓ in ~0.5 s (1 iteration of the 60×0.5 s loop) |
| `kill -- -<pgid>` tears down the whole group | ✓ chrome had 5 children → **0 orphans** after the group kill |
| `ps -o pgid= -p $P` output format | raw is whitespace-padded; `tr -d ' '` → clean integer ✓ |
| **TOCTOU: `ps -o pgid=` after instant death** | rc 1, empty output → **BARE capture ABORTS under `set -e`** (GOTCHA §5) |
| All 9 flags present in `/proc/<pid>/cmdline` | ✓ (incl. exact `--disable-features=CalculateNativeWinOcclusion`, `--headless=new`) |

---

## §1 — The `setsid` + `$!` + pgid contract (HOST-VERIFIED)

Tested in a non-interactive `bash -c 'set -euo pipefail …'` (job control OFF — the exact
context `lib/pool.sh` runs in, because `set -euo pipefail` has no `-m`):

```bash
setsid sleep 300 &
SP=$!
PGID="$(ps -o pgid= -p "$SP" | tr -d ' ')"
# => captured $! = 2026601 ; ps -o pgid= -p 2026601 => pgid=2026601 ; sid=2026601 ; comm=sleep
# => RESULT: pgid==pid (setsid did NOT fork; exec contract HOLDS)
kill -- -"$PGID"   # => succeeded ; process DEAD
```

**Why it holds:** util-linux `setsid` (default, NO `-f`/`--fork`) calls `setsid(2)` then
`execvp()`s the command when the calling process is **not** a process group leader. In a
script (job control off) a backgrounded `setsid` is not a pgroup leader, so it does **not**
fork — it `exec`s the target. Therefore `$!` (the PID bash recorded for the `setsid` job) is
the PID the command inherits via exec, and because `setsid(2)` made it a session leader, its
**pgid == pid == sid**.

This is EXACTLY the contract in `key_findings.md` FINDING 6 and `external_deps.md` §2.1.
**Do NOT add `setsid --fork`/`-f`** — that WOULD fork and break pgid==pid (the recorded `$!`
would be the intermediate, not chrome).

Canonical ref (man, known-standard anchor): `man 1 setsid` → DESCRIPTION ("runs a program in
a new session"); `man 2 setsid` ("creates a new session if the calling process is not a
process group leader").

---

## §2 — Real Chrome end-to-end launch (HOST-VERIFIED)

Launched the EXACT contract command (headless variant) on a free port:

```bash
setsid "google-chrome-stable" \
  --remote-debugging-port=55555 --user-data-dir=<tmp>/chrome-prof \
  --no-first-run --no-default-browser-check \
  --disable-background-timer-throttling --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding --disable-features=CalculateNativeWinOcclusion \
  --disable-back-forward-cache --headless=new > <log> 2>&1 &
CPID=$! ; PGID=$(ps -o pgid= -p "$CPID" | tr -d ' ')
# => chrome pid=$!=2031215  pgid=2031215  (equal? YES)
```

- **Teardown:** `kill -- -"$PGID"` → chrome DEAD, **0 orphaned children** (it had 5: renderer,
  GPU, utility, etc.). This is the no-orphars contract PRD §2.19 demands.
- **Log:** `DevTools listening on ws://127.0.0.1:55555/devtools/browser/…` — no flag rejected.
- **Wrapper transparency:** `/usr/bin/google-chrome-stable` is a 310-byte script that
  `exec`s `/opt/google/chrome/chrome`. Because setsid wrapped the wrapper and the wrapper
  exec'd chrome, `$!` is stable and IS chrome's pid. Confirmed (pgid==pid held, cmdline was
  chrome's).

---

## §3 — CDP `/json/version` readiness (HOST-VERIFIED)

After the §2 launch, the readiness loop became satisfied in **1 iteration (~0.5 s)**:

```
CDP ready after 1 iteration(s) (~0.5s)
{
   "Browser": "Chrome/149.0.7827.114",
   "Protocol-Version": "1.3",
   "User-Agent": "Mozilla/5.0 … HeadlessChrome/149.0.0.0 …",
   "V8-Version": "14.9.207.27",
   "WebKit-Version": "537.36 (@5be7af702aa73ed64f47858cecc86290e42f2a20)",
   "webSocketDebuggerUrl": "ws://127.0.0.1:55555/devtools/browser/ce1f2c94-…"
}
```

- `/json/version` is the canonical "CDP HTTP endpoint is up" probe. It returns HTTP **200 +
  JSON** once the DevTools server is bound. Before that, the port refuses the connection.
- **`curl -sf` exit-code semantics** (the contract's probe):
  - connection refused (Chrome still booting / port closed) → **exit 7** → loop continues.
  - HTTP 200 → **exit 0** → ready, `return 0`.
  - HTTP ≥ 400 → `-f` makes it non-zero (defensive; a real CDP endpoint returns 200).
- No `--max-time` is strictly needed here (connection-refused is instant, §4 of the S1
  research proved this), but adding `--max-time 2` is a harmless defensive bound against a
  pathological DROP-style filtered port. The contract's bare `curl -sf` is also acceptable;
  the PRP uses the bare form to match external_deps §2.2 exactly.

Canonical refs (known-standard): https://chromedevtools.github.io/devtools-protocol/
(“HTTP Endpoints” → `/json/version`); https://developer.chrome.com/docs/devtools/protocol-overview.

---

## §4 — Anti-throttle flags all accepted (HOST-VERIFIED)

Inspected `/proc/$CPID/cmdline` after the §2 launch. **All 9 flags present**, verbatim:

```
PRESENT: --remote-debugging-port
PRESENT: --user-data-dir
PRESENT: --disable-background-timer-throttling
PRESENT: --disable-backgrounding-occluded-windows
PRESENT: --disable-renderer-backgrounding
PRESENT: --disable-features          (value: =CalculateNativeWinOcclusion)
PRESENT: --disable-back-forward-cache
PRESENT: --headless                  (value: =new)
```

Chrome rewrote its cmdline (prepended `--ozone-platform-hint=wayland --gtk-version=4 …` from
the wrapper) but **our flags survived unchanged**, including the exact
`--disable-features=CalculateNativeWinOcclusion` and `--headless=new`.

Why each matters (PRD §2.6: "Anti-throttle flags are required on Wayland"):
- `--disable-background-timer-throttling` — stops Chrome from slowing `setTimeout`/`setInterval`
  when the tab/window is backgrounded. Without it heavy SPA apply forms never hydrate.
- `--disable-backgrounding-occluded-windows` — do not deprioritize fully-occluded windows.
- `--disable-renderer-backgrounding` — do not throttle the renderer process when hidden.
- `--disable-features=CalculateNativeWinOcclusion` — disable the native occlusion detection
  that would otherwise mark pooled windows as occluded (Wayland) and throttle them.
- `--disable-back-forward-cache` — avoid freeze-on-navigate semantics that can stall a
  backgrounded tab.
- `--headless=new` — the **modern** headless (Chrome 112+); the legacy `--headless` is
  deprecated. Only added when `POOL_HEADLESS==1` (default = windowed, PRD §2.6).

Canonical flag ref (known-standard): https://peter.sh/experiments/chromium-command-line-flags/
(search each flag name); https://developer.chrome.com/blog/chrome-headless-shell (the `=new`
mode). NOTE for the implementer: flag-list grep checks in tests MUST use `grep -qF -- "$f"`
because each flag starts with `-` (a bare `grep -qF "$f"` is parsed as a grep option — this
bit the research script and is documented in the PRP's test section).

---

## §5 — THE KEY GOTCHA: `ps -o pgid=` TOCTOU + `set -e` (HOST-VERIFIED)

If Chrome exits immediately (bad port, missing binary, instant crash), the pid recorded in
`$!` is already gone when we capture the pgid:

```bash
setsid true &
P=$! ; sleep 0.3
pg="$(ps -o pgid= -p "$P" 2>/dev/null | tr -d " ")"   # BARE capture
# => ps returned rc=1 (process gone) — BARE capture ABORTS under set -e
```

`ps -o pgid= -p <dead-pid>` exits **rc 1** with empty output. Under `set -euo pipefail`
(propagated into every caller by lib/pool.sh line 11) a **bare** command-substitution
`pg="$(ps …)"` therefore **aborts the whole pool** the moment Chrome fails to stay up.

**Mandatory guard** (the PRP encodes this): capture defensively and treat empty as fatal:

```bash
pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
if [[ -z "$pgid" ]]; then
    # Chrome died before we could read its pgroup — clean up the pid and die.
    kill "$POOL_CHROME_PID" 2>/dev/null || true
    pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately; see $log_file"
fi
```

The `|| true` keeps the capture from tripping errexit; the `[[ -z ]]` then converts the
"empty = already dead" case into a clean `pool_die` (with the log path so the operator can
read Chrome's stderr). This mirrors how `pool_lane_is_stale`/`pool_lease_find_mine` guard
their `$(…)` captures, and it preserves the `pgid == pid` invariant the release step
(M5.T2.S1) relies on for `kill -- -<pgid>`.

---

## §6 — Naming: `POOL_CHROME_PID` / `POOL_CHROME_PGID` (convention wins)

The item CONTRACT says "Export CHROME_PID and CHROME_PGID as globals." But **every** global in
`lib/pool.sh` is `POOL_*` (`POOL_OWNER_PID`, `POOL_PORT_BASE`, `POOL_STATE_DIR`, …) and the
only other "produce globals after an operation" function — `pool_owner_resolve` (M2.T1.S1) —
sets `POOL_OWNER_PID`/`POOL_OWNER_COMM`/`POOL_OWNER_STARTTIME`/`POOL_OWNER_CWD` via
`declare -g`. For consistency the PRP exports **`POOL_CHROME_PID`** and **`POOL_CHROME_PGID`**.

Rationale: (a) one global namespace for the whole lib; (b) the lease schema
(`external_deps.md` §6) stores them as `chrome_pid`/`chrome_pgid`, so the consumer M5.T1.S2
will read `POOL_CHROME_PID`→write `chrome_pid`; (c) this PRP is the authority the M5.T1.S2 PRP
will cite, so the name is self-consistent. The contract's bare `CHROME_PID` is treated as
shorthand.

---

## §7 — CDP-timeout conflict: 15 s (PRD §2.4/§2.14) vs 30 s (external_deps §2.2 / CONTRACT 3b)

The sources disagree on the readiness-loop budget:

| source | figure | form |
|---|---|---|
| PRD §2.4 step 3h (selected h3.8) | **15 s** | "≤30×0.5s" |
| PRD §2.14 failure table (selected h3.18) | **15 s** | "/json/version timeout (15s)" |
| CONTRACT 1.RESEARCH NOTE | **15 s** | "up to 30×0.5s=15s" |
| CONTRACT 3b (the actual LOGIC) | **30 s** | "Loop up to 60 times (30s total)" |
| `external_deps.md` §2.2 (impl reference) | **30 s** | `for i in $(seq 1 60)` |

**Resolution (PRP): 60 iterations × 0.5 s = 30 s.** The contract's step **3b is the direct
implementation directive** ("Loop up to 60 times (30s total)") and external_deps §2.2 — the
canonical implementation reference with actual code — agrees. The PRD §2.4/§2.14 "15 s" is a
stale summary figure. 30 s is also the safer choice: Chrome cold-boot under concurrent
acquire load (each doing a reflink copy + launch) can exceed 15 s, and a too-short wait would
spuriously trigger the §2.14 "retry launch once; then fail" path. The loop budget is
documented as a single named constant in the function so it is trivially tunable.

---

## §8 — `pool_wait_cdp` timeout-kill semantics

CONTRACT 3b: "On timeout: kill the Chrome process group, return 1."

`pool_wait_cdp(port)` therefore needs the pgid of the just-launched Chrome. It reads the
**global** `POOL_CHROME_PGID` that `pool_chrome_launch` set one step earlier in the post-lock
boot (M5.T1.S2 always calls launch→wait in that order). Implementation:

```bash
pool_wait_cdp() {
    local port="${1:-}" i
    for (( i = 0; i < 60; i++ )); do
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    # timeout — tear down the process group so we don't leak a half-booted Chrome.
    if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then
        kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true
    fi
    return 1
}
```

- The pgid guard (`=~ ^[0-9]+$`) makes `pool_wait_cdp` safe to call standalone in tests
  without a prior launch (empty pgid → skip the kill, just return 1).
- `kill -- -<pgid>` (`--` mandatory: pgid is a positive integer but the arg starts with `-`).
- This is the SAME teardown primitive M4.T3.S1 / M5.T2.S1 will formalize; when they land they
  may extract a `pool_kill_chrome_pgroup` helper that this function can delegate to. For now
  it is inlined (no dependency on unbuilt tasks).
- `return 1` (NOT `pool_die`) — the caller (M5.T1.S2) owns the "retry launch once, then fail,
  drop lane" policy per PRD §2.14. Same non-fatal-query family as `pool_find_free_port`.

---

## §9 — Env-var wiring (confirmed against `pool_config_init`)

`pool_config_init` (M1.T1.S2, LANDED @126) already freezes every value this task needs:

| global | source env var | sample | used here |
|---|---|---|---|
| `POOL_CHROME_BIN` | `AGENT_CHROME_BIN` | `google-chrome-stable` | the binary setsid execs |
| `POOL_HEADLESS` | `AGENT_CHROME_HEADLESS` | `0` (unset) / `1` | add `--headless=new` iff `==1` |
| `POOL_STATE_DIR` | `AGENT_BROWSER_POOL_STATE` | `…/agent-browser-pool` | log = `$POOL_STATE_DIR/chrome-<lane>.log` |

Verified live:
```
POOL_CHROME_BIN=google-chrome-stable
POOL_HEADLESS=0  (AGENT_CHROME_HEADLESS unset => 0/windowed)
with AGENT_CHROME_HEADLESS=1 => POOL_HEADLESS=1
```

`POOL_CHROME_BIN` may be a bare name (resolved via PATH by `setsid`/execvp) or an absolute
path (canonicalized by pool_config_init). Both work — §2 launched with the bare name.

---

## §10 — Banner / placement / scope

- **Banner:** new `# Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)` section.
- **Placement:** APPEND at EOF, directly below the P1.M4.T2.S1 deliverable
  (`pool_find_free_port`). The file is currently 1312 lines ending at `pool_copy_master`'s
  closing brace; S1 (parallel, "Implementing") appends `pool_find_free_port` after that, so
  **S2 appends after S1's `pool_find_free_port`**. Do NOT touch any existing function. (If S1
  has not landed yet when S2 starts, append after `pool_copy_master` and S1 will naturally
  sit before this section — the banner text disambiguates.)
- **Scope (out of bounds):** do NOT connect the daemon (M4.T3.S1), do NOT take/release the
  flock (M5.T1.S1), do NOT update the lease's `chrome_pid`/`chrome_pgid` (M5.T1.S2 — the
  caller reads `POOL_CHROME_PID`/`POOL_CHROME_PGID` and writes them into the lease), do NOT
  pick the port (M4.T2.S1 — the caller passes the already-chosen port in).
