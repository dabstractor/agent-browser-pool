# PRP — P1.M4.T3.S1: agent-browser connect + verify + process group teardown

---

## Goal

**Feature Goal**: Implement the **daemon-connect / connected-verify / Chrome-teardown
primitives** for the agent-browser-pool — the three functions that bind the shared
agent-browser daemon to a pooled Chrome, check that binding side-effect-free, and tear down
a Chrome's whole process tree as one idempotent unit. This is the literal realization of
PRD §2.4 step 3i (CONNECT: `agent-browser --session abpool-<N> connect <port>`), step 4
(ENSURE CONNECTED), §2.5/§2.10 release semantics (kill pgroup), §2.19 (process-group
teardown gotcha), key_findings FINDING 6, and the item CONTRACT (steps 3a–3c). Three
functions, appended at EOF of `lib/pool.sh` under a new
`# Lane lifecycle — daemon connect, verify & teardown (P1.M4.T3.S1)` banner, placed
directly after `pool_wait_cdp` (the P1.M4.T2.S2 deliverable, currently the last function in
the file). Pure addition: no edits to any existing function, no new env-vars/files.

1. **`pool_daemon_connect(session, port)`** — bind the daemon session to the pooled Chrome.
   CONTRACT 3a: `"$POOL_REAL_BIN" --session "$session" connect "$port"`. **HOST-VERIFIED**:
   connect to a LIVE chrome → rc 0 (+ binds; `get cdp-url` then reports the pooled port);
   connect to a DEAD port → rc 1 ("All CDP discovery methods failed … Connection refused").
   Non-fatal: returns the subprocess rc (0 success / 1 failure); never `pool_die`.

2. **`pool_daemon_connected(session, port)`** — side-effect-free "is this lane drivable?"
   check. ⚠️ **DEVIATES from the literal CONTRACT step 3b** (`get cdp-url >/dev/null 2>&1`),
   which is **BROKEN on agent-browser 0.28.0** (see Gotchas + research §2): `get cdp-url`
   on a disconnected/dead-chrome session **auto-launches a stray managed Chrome** (verified:
   chrome proc count 61→67) and **always returns rc 0**, so it can never report "not
   connected" AND it leaks/strays. The CORRECT, side-effect-free implementation combines two
   host-verified read-only probes (research §3 + §4):
   - (1) is the session known to the daemon? `--json session list` (read-only, NEVER
     launches) → `jq -e … index($session)`. Absent ⇒ fresh/restarted daemon ⇒ return 1.
   - (2) is the pooled chrome alive? `curl -sf http://127.0.0.1:<port>/json/version` (never
     launches). Dead ⇒ return 1 (PRD §2.14 chrome-crash — the primary failure).
   - both pass ⇒ return 0. **The signature gains `port`** (the contract said `session` only)
     because the reliable signal is the pooled chrome's liveness, which needs the port.
     `session` is still used (step 1). Non-fatal (return 0/1).

3. **`pool_chrome_kill(chrome_pid, chrome_pgid)`** — idempotent whole-tree teardown.
   CONTRACT 3c, HOST-VERIFIED (research §5): primary `kill -- -<pgid>` (SIGTERM) →
   `sleep 0.5` → `kill -9 -- -<pgid>` (SIGKILL) → fallback bare-pid `kill`/`kill -9`.
   Every signal is `2>/dev/null || true` (kill on already-dead returns rc 1 ESRCH and would
   ABORT under `set -euo pipefail` — verified). Numeric-guarded so chrome_pid=0 / chrome_pgid=0
   (a provisional lease, PRD §2.4 step 3d) are skipped safely. Non-fatal (return 0 always).

**Deliverable**: Three functions appended to `lib/pool.sh` under a new banner after
`pool_wait_cdp`. Pure addition; reads only `POOL_REAL_BIN` (frozen by `pool_config_init`,
M1.T1.S2) for the two daemon functions; `pool_chrome_kill` reads no globals (args only).
Every behavior is **host-verified (2026-07-12)** against real `google-chrome-stable` (149)
and the real `agent-browser` 0.28.0 daemon — see
`research/daemon-connect-teardown-host-verified.md` (the `get cdp-url` auto-launch trap §2
is the highest-impact finding in this task).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, calling
  `pool_daemon_connect abpool-3 <port>` against a LIVE headless Chrome returns **0**; against
  a DEAD port returns **1** (without `pool_die`-ing or aborting the caller under `set -e`).
- After `pool_daemon_connect abpool-3 <port>` succeeds, `pool_daemon_connected abpool-3 <port>`
  returns **0**; after the pooled Chrome is killed (pgroup teardown), it returns **1**.
- **`pool_daemon_connected` NEVER launches a Chrome** — chrome proc count is unchanged
  before/after a call on a dead-chrome session (the §2 trap is avoided). Verified by a
  before/after `pgrep -c` assertion in the validation loop.
- `pool_chrome_kill <pid> <pgid>` on a live `setsid` Chrome pgroup kills the **whole tree**
  (0 orphans via `pgrep -P`); calling it **again** on the now-dead pids returns **0** (idempotent
  — every kill guarded by `|| true`, no `set -e` abort).
- `pool_chrome_kill 0 0` (provisional-lease args) returns **0** and harms nothing.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M4.T2.S2) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls these directly. Their
consumers are three orchestration layers:

- **P1.M5.T1.S2** (acquire **post-lock boot**) — calls `pool_daemon_connect` at PRD §2.4
  step 3i, right after `pool_wait_cdp` succeeds, then writes `connected:true` into the lease.
- **P1.M5.T1.S3** (ensure_connected — the **hot path**, runs on EVERY `agent-browser`
  invocation) — calls `pool_daemon_connected` to decide reconnect-vs-reuse. ⚠️ This primitive
  REPLACES the literal PRD §2.4 step 4 `get cdp-url || connect` (which is broken — §2 of
  research). Recommended consumer idiom: `pool_daemon_connected "$session" "$port" ||
  pool_daemon_connect "$session" "$port"`.
- **P1.M5.T2.S1** (release) + **P1.M5.T3.S1** (reap_stale) — call `pool_chrome_kill` to tear
  down a lane's Chrome pgroup (reads `chrome_pid`/`chrome_pgid` from the lease).
- **P1.M5.T3.S2** (reuse_orphan) — calls `pool_daemon_connected` (is the orphan's chrome
  responsive?) then `pool_daemon_connect` (re-bind the adopted session).

**Use Case**: Every `agent-browser` invocation enters acquire → (launch) → **connect** →
drive; every *subsequent* invocation runs **ensure_connected** (the verify primitive) before
driving; every release/reap runs **kill** to reclaim the lane. These three primitives are
the connect/verify/teardown verbs of that lifecycle.

**Pain Points Addressed**:
- **`get cdp-url` silently launches stray Chromes and lies about connection state** (the
  #1 footgun on agent-browser 0.28.0 — research §2). `pool_daemon_connected` is the
  side-effect-free substitute that lets the hot path avoid both the leak and the
  wrong-profile-drive catastrophe.
- **Release must tear down the whole Chrome tree with no orphans.** The `setsid`→pgid==pid
  contract (established by `pool_chrome_launch`, M4.T2.S2) makes `kill -- -<pgid>` take down
  renderer/GPU/utility children. `pool_chrome_kill` is the canonical, idempotent escalation.
- **Teardown must be idempotent + non-fatal** — release/reap run over many lanes; one
  already-dead Chrome must never abort the pool under `set -euo pipefail`.

## Why

- **These are the connect/verify/teardown verbs of the ephemeral-profile model.** PRD §2.4
  step 3i (CONNECT) + step 4 (ENSURE CONNECTED) + §2.5/§2.10 (release = kill pgroup) are
  THESE functions. Without them the pool can neither bind a daemon to its pooled Chrome nor
  reclaim a lane.
- **The `get cdp-url` auto-launch trap would silently break the pool.** The PRD's §2.4 step 4
  literal design assumes `get cdp-url` fails when disconnected; on 0.28.0 it instead launches
  a stray and returns 0, so the agent would drive a fresh random profile (no auth/tabs) and
  leak Chromes. Centralizing the side-effect-free check here means every consumer (M5.T1.S3,
  M5.T3.S2) gets a correct, stray-free probe. See research §2 — the single most important
  finding in this task.
- **Process-group teardown correctness is the no-orphars foundation.** key_findings FINDING 6
  + PRD §2.19: `kill -- -<pgid>` (note `--`, negative pid) catches the whole tree. Getting
  the idempotency wrong (bare `kill` under `set -e`) aborts release/reap on the first
  already-dead lane.

## What

User-visible behavior: none directly (internal library primitives). Observable contract:

| scenario | function | result |
|---|---|---|
| `pool_daemon_connect <sess> <port>` to a LIVE chrome | connect | **rc 0**; daemon session bound (next `get cdp-url` reports `<port>`) |
| `pool_daemon_connect <sess> <port>` to a DEAD port | connect | **rc 1** (non-fatal; "Connection refused" on stderr→/dev/null) |
| `pool_daemon_connected <sess> <port>` after a successful connect + live chrome | connected | **rc 0**; **no Chrome launched** (chrome count unchanged) |
| `pool_daemon_connected <sess> <port>` after the pooled chrome is killed | connected | **rc 1**; **no stray Chrome launched** (chrome count unchanged) |
| `pool_daemon_connected <sess> <port>` for a session the daemon never saw | connected | **rc 1** (absent from `session list`); no launch |
| `pool_chrome_kill <pid> <pgid>` on a live `setsid` Chrome pgroup | kill | **rc 0**; whole tree dead (0 orphans); SIGTERM→0.5s→SIGKILL |
| `pool_chrome_kill <pid> <pgid>` called AGAIN on the now-dead pids | kill | **rc 0** (idempotent; every kill `\|\| true`) |
| `pool_chrome_kill 0 0` (provisional lease, no chrome yet) | kill | **rc 0** (numeric guards skip; no-op) |
| bad args (session empty / port non-numeric) | connect/connected | **rc 1** (non-fatal, defensive); kill → **rc 0** (guards skip) |

**Hard invariants** (every row):
- **`pool_daemon_connected` NEVER launches a Chrome.** It uses ONLY read-only probes
  (`session list --json` + `curl /json/version`). The `get cdp-url` command is FORBIDDEN in
  this function (research §2 — auto-launch trap). Verified by a before/after `pgrep -c`
  assertion in the validation loop.
- **All three functions are NON-FATAL** (return rc; never `pool_die`). They run inside
  acquire/release/reap orchestration where one dead/unbindable lane must not abort the whole
  pool. Same family as `pool_wait_cdp` / `pool_find_free_port` / `pool_lease_read`.
- **Every `kill` is `2>/dev/null || true`.** `kill` on an already-dead pid/pgid returns rc 1
  (ESRCH) — under `set -euo pipefail` (propagated by `lib/pool.sh` line 17) an unguarded kill
  ABORTS the caller. Verified (research §5). This is the idempotency mechanism — no `kill -0`
  pre-check needed.
- **`kill -- -<pgid>` needs the `--`** (pgid is a positive int but the arg starts with `-`).
  The negative-pid form signals the whole process group. (PRD §2.19, FINDING 6.)
- **Numeric guards on pid/pgid** so a provisional lease (`chrome_pid=0`, `chrome_pgid=0`,
  PRD §2.4 step 3d) and non-numeric junk are skipped, not signalled.
- **`pool_chrome_kill` does NOT touch the daemon session** (no `agent-browser close`) — it is
  the *Chrome* teardown only. Daemon/session disconnect is the wrapper's `close` interception
  (M6.T1.S2) and release's lease-delete concern (M5.T2.S1). Scope: kill the Chrome tree.

### Success Criteria

- [ ] `pool_daemon_connect`, `pool_daemon_connected`, `pool_chrome_kill` defined in
      `lib/pool.sh` under a `# Lane lifecycle — daemon connect, verify & teardown (P1.M4.T3.S1)`
      banner, directly after `pool_wait_cdp`'s closing brace. Callable after
      `source lib/pool.sh` + `pool_config_init`.
- [ ] `pool_daemon_connect abpool-3 <live-port>` → **0**; `pool_daemon_connect abpool-3 <dead-port>`
      → **1** (no abort under `set -e`).
- [ ] After a successful connect, `pool_daemon_connected abpool-3 <port>` → **0**; after the
      pooled chrome is killed → **1**.
- [ ] `pool_daemon_connected` on a dead-chrome session does **not** change the chrome proc
      count (before/after `pgrep -c -f remote-debugging-port` equal) — proves the §2 trap is
      avoided.
- [ ] `pool_chrome_kill <pid> <pgid>` on a live `setsid` pgroup → **0**, 0 orphans
      (`pgrep -P <pid>` empty); a second call → **0** (idempotent).
- [ ] `pool_chrome_kill 0 0` → **0**, no-op.
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.\*, M4.T1.S1, M4.T2.S1, M4.T2.S2) unchanged and callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **`get cdp-url` auto-launch
trap** (host-verified — the #1 finding; it invalidates the literal CONTRACT step 3b and PRD
§2.4 step 4, and mandates the side-effect-free curl + session-list design); the **connect
exit-code contract** (host-verified rc 0 live / rc 1 dead); the **side-effect-free probes**
(`session list` is read-only/non-launching — verified; `curl /json/version` is non-launching
— verified); the **kill idempotency + `--` + ESRCH-under-set-e hazard** (host-verified); the
**SIGTERM→grace→SIGKILL escalation** rationale; the **naming + placement** (after
`pool_wait_cdp`, the M4.T2.S2 deliverable); the **globals** read (`POOL_REAL_BIN` only); and
copy-pasteable, host-verified validation commands including a real-Chrome integration test.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3i (CONNECT: agent-browser --session abpool-<N> connect <port>) + step 4
        (ENSURE CONNECTED — NOTE: its literal `get cdp-url || connect` is BROKEN on 0.28.0,
        see research §2; THIS task's pool_daemon_connected is the stray-free replacement),
        §2.5/§2.10 (release = kill pgroup), §2.14 (Chrome crash mid-task → relaunch+reconnect
        — the primary failure pool_daemon_connected detects), §2.19 (kill -- -<pgid>; the
        `--`; setsid pgid==pid), §2.8 (close = disconnect-only; next call reuses the browser
        — informs the session-list-membership design).
  pattern: step 3i IS pool_daemon_connect; step 4 IS pool_daemon_connected; §2.19 IS the kill idiom.
  gotcha: step 4's `get cdp-url` probe AUTO-LAUNCHES strays on 0.28.0 — do NOT use it; use
        pool_daemon_connected (this task) instead.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §1.4 (Key Subcommands for Pool Plumbing — `--session <name> connect <port>` binds;
        `get cdp-url` "exit 0 = connected" — NOTE this claim is FALSE on 0.28.0 per research
        §2; `--session <name> close`; `session list`), §4 (kill is a builtin; setsid/pgrep/
        curl/jq verified present), §5 (AGENT_BROWSER_REAL → POOL_REAL_BIN), §6 (lease schema
        chrome_pid / chrome_pgid / port / session / connected fields the consumers read/write).
  pattern: §1.4 IS the daemon-command reference.
  gotcha: §1.4's "get cdp-url exit 0 = yes [connected]" is the source of the broken CONTRACT
        step 3b premise; research §2 supersedes it with host evidence.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 4 (a daemon with MANY pre-existing sessions is already running — use throwaway
        abpool-* names in tests, never disturb t7/weaveapply/etc.), FINDING 5 (/tmp/agent-
        browser-chrome-* accumulation is exactly what the auto-launch trap worsens), FINDING 6
        (setsid → pgid==pid; CHROME_PGID=$(ps -o pgid= -p $PID|tr -d ' '); teardown
        kill -- -<pgid>; fallback pkill -P / bare-pid kill) — IS the kill contract.
  pattern: FINDING 6 IS the teardown idiom (verbatim).
  gotcha: FINDING 6's `kill -- -<pgid>` on an already-dead group returns rc 1 — every kill
        MUST be `|| true` under set -e (research §5).

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — context for where POOL_REAL_BIN/POOL_STATE_DIR live), the
        note that stock agent-browser uses --remote-debugging-port=0 while the pool uses an
        explicit recorded port (passed to pool_daemon_connect).

# This task's own research (REAL-CHROME + REAL-DAEMON host-verified — ALL PASSED / findings logged)
- file: plan/001_0f759fe2777c/P1M4T3S1/research/daemon-connect-teardown-host-verified.md
  why: THE evidence base. §1 (connect rc 0 live / rc 1 dead — verified); §2 (THE get cdp-url
        AUTO-LAUNCH TRAP — chrome count 61→67, always rc 0, no disable flag — the reason
        pool_daemon_connected must NOT use get cdp-url); §3 (session list is READ-ONLY / never
        launches; never-seen=absent; after-connect=present; after-close=lingers); §4 (curl
        /json/version is side-effect-free chrome liveness); §5 (kill idempotency: every kill
        on dead returns rc 1 ESRCH → MUST `|| true`; `--` mandatory; SIGTERM→0.5s→SIGKILL);
        §6 (the resulting pool_daemon_connected design + the port-arg justification); §7
        (naming/placement/consumers); §8 (researcher subagent corroboration).
  pattern: §6 IS the pool_daemon_connected design; §5 IS the pool_chrome_kill idiom; §1 IS
        pool_daemon_connect.
  gotcha: §2 is the one that WILL cause a catastrophic wrong-profile-drive + chrome leak if
        the implementer follows the literal CONTRACT step 3b.

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init (M1.T1.S2 — LANDED @126)
  why: freezes POOL_REAL_BIN (canonicalized absolute path to the agent-browser binary; default
        $HOME/.local/bin/agent-browser). pool_daemon_connect + pool_daemon_connected read it.
        CONTRACT: MUTABLE declare -g global, re-runnable.
  gotcha: POOL_REAL_BIN is the GLOBAL (validated+canonicalized), not the env AGENT_BROWSER_REAL.

- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md   # pool_die / _pool_log (M1.T1.S1 — LANDED)
  why: these three functions do NOT call pool_die (all non-fatal). _pool_log is OPTIONAL
        (one observability line each is nice but not required). Keep any messages minimal.
  gotcha: pool_die EXITS the process — forbidden in these primitives.

- file: plan/001_0f759fe2777c/P1M4T2S2/PRP.md   # pool_chrome_launch / pool_wait_cdp (M4.T2.S2 — LANDED at EOF)
  why: the IMMEDIATE PREDECESSOR at EOF. THIS task appends after pool_wait_cdp's closing brace.
        pool_wait_cdp has its OWN inline single-SIGKILL (`kill -- -"$POOL_CHROME_PGID"`) for
        the CDP-timeout path; pool_chrome_kill (THIS task) is the CANONICAL thorough teardown
        for release/reap. Do NOT refactor pool_wait_cdp to call pool_chrome_kill (out of scope).
        pool_chrome_launch exports POOL_CHROME_PID/POOL_CHROME_PGID — NOT used by this task
        (we take pid/pgid as ARGS from the lease, per the item CONTRACT INPUT).
  gotcha: placement — append after pool_wait_cdp; the banner text disambiguates. Do NOT touch
        pool_wait_cdp or any prior function.

- file: plan/001_0f759fe2777c/P1M3T1S1/PRP.md   # pool_lease_write / pool_lease_field (M3.T1.* — LANDED)
  why: the CONSUMERS read chrome_pid/chrome_pgid/port/session/connected FROM the lease and pass
        them INTO pool_chrome_kill / pool_daemon_connect / pool_daemon_connected. This task does
        NOT read leases itself (it takes args), but understanding the lease field names matters
        for the consumer contracts documented here.

# External authoritative docs (for the WHY; behavior is HOST-VERIFIED in the research file)
- url: https://github.com/vercel-labs/agent-browser
  why: the agent-browser repo (package.json repository.url — canonical org is vercel-labs, NOT
        vercel). v0.28.0. Native Rust binary agent-browser-linux-x64.
  section: README › Architecture (daemon auto-starts on first command) › Sessions (--session
        isolated binding) › CDP Mode (connect <port>).

- url: https://agent-browser.dev
  why: docs site. Confirms the --json envelope {"success":true,"data":{…}}.
  section: (command reference).

- url: https://man7.org/linux/man-pages/man2/kill.2.html
  why: kill(2) — ESRCH ("No such process") is why `kill` on an already-dead pid/pgid returns
        rc 1. Under `set -e` that aborts the caller → every kill MUST be `|| true`. Also: a
        negative pid means "signal the process group".
  section: ERRORS (ESRCH); DESCRIPTION (pid>0 / pid<-1 / pid==0 / pid==-1 semantics).

- url: https://man7.org/linux/man-pages/man1/setsid.1.html
  why: setsid makes Chrome its own session/group leader (pgid==pid) — the invariant
        pool_chrome_kill's `kill -- -<pgid>` relies on (established by pool_chrome_launch).
  section: DESCRIPTION.
```

### Current Codebase tree

After **M1–M4.T2.S1** have landed AND **M4.T2.S2** (`pool_chrome_launch` + `pool_wait_cdp`)
has landed (parallel, treated as CONTRACT — both ARE already present in `lib/pool.sh` at EOF,
lines ~1380–1591), `lib/pool.sh` ends with `pool_wait_cdp` as the final function:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ~1591 lines after M4.T2.S2 lands:
│                                         #   set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)  ← POOL_REAL_BIN frozen
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.*)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)
│                                         #   + pool_lanes_list/pool_lease_find_mine/_any (M3.T2.S1)
│                                         #   + pool_find_free_lane (M3.T2.S2)
│                                         #   + pool_lane_is_stale (M3.T2.S3)
│                                         #   + pool_copy_master (M4.T1.S1)
│                                         #   + pool_find_free_port (M4.T2.S1)
│                                         #   + pool_chrome_launch + pool_wait_cdp (M4.T2.S2)  ← current EOF @~1591
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M4T2S2/PRP.md
    └── P1M4T3S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/daemon-connect-teardown-host-verified.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND three functions under a new banner after the current EOF
                  #   (after pool_wait_cdp's closing brace):
                  #   # Lane lifecycle — daemon connect, verify & teardown (P1.M4.T3.S1)
                  #   pool_daemon_connect(session, port):
                  #       "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1
                  #       return its rc (0 live / 1 dead). Non-fatal.
                  #   pool_daemon_connected(session, port):   # port ADDED — see Gotchas (get cdp-url trap)
                  #       (1) session in read-only `--json session list`? (jq -e index) || return 1
                  #       (2) curl -sf http://127.0.0.1:<port>/json/version >/dev/null 2>&1 || return 1
                  #       return 0.  NEVER calls get cdp-url (auto-launches strays). Non-fatal.
                  #   pool_chrome_kill(chrome_pid, chrome_pgid):
                  #       kill -- -<pgid> (SIGTERM) → sleep 0.5 → kill -9 -- -<pgid>
                  #       → fallback kill/kill -9 <pid>.  EVERY kill `2>/dev/null || true`.
                  #       Numeric-guarded (skip 0/non-numeric). Idempotent. Non-fatal (return 0).
                  #   (NO changes to any existing function — esp. NOT pool_wait_cdp)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **daemon-bind / verify / Chrome-teardown primitives** — the connect (PRD §2.4 step 3i),
ensure-connected-verify (step 4, stray-free), and release-kill (§2.5/§2.10) verbs. They read
`POOL_REAL_BIN` (the two daemon functions) and take pid/pgid/session/port as args; they are
consumed by the acquire post-lock boot (M5.T1.S2), ensure_connected (M5.T1.S3), release
(M5.T2.S1), and the reaper (M5.T3.S1/S2).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (THE get cdp-url AUTO-LAUNCH TRAP — highest-impact gotcha in this task):
#   `agent-browser --session <name> get cdp-url` on a session with NO live browser
#   AUTO-LAUNCHES a managed Chrome on a RANDOM port (not a pool port) and returns rc 0.
#   HOST-VERIFIED (research §2): chrome count 61→67 across one get cdp-url call on a
#   dead-chrome session; never-seen session also auto-launches. There is NO --no-launch /
#   AGENT_BROWSER_NO_LAUNCH flag (researcher confirmed). This INVALIDATES the item CONTRACT
#   step 3b AND PRD §2.4 step 4 (`get cdp-url || connect`): get cdp-url always returns 0 so
#   the recovery never fires, AND it silently re-binds the session to a STRAY chrome (wrong
#   profile, no auth) + leaks chromes. CONSEQUENCE: pool_daemon_connected MUST NOT use
#   get cdp-url; it uses read-only `session list` + `curl /json/version` instead (research §3/§4).

# CRITICAL (kill on already-dead returns rc 1 → ABORTS under set -e): every `kill -- -<pgid>`,
#   `kill -9 -- -<pgid>`, `kill <pid>`, `kill -9 <pid>` returns rc 1 (ESRCH) when the target is
#   already dead. lib/pool.sh line 17 sets `set -euo pipefail`, so an UNGUARDED kill ABORTS the
#   caller (release/reap over many lanes). EVERY kill MUST be `… 2>/dev/null || true`. This IS
#   the idempotency mechanism (no kill -0 pre-check needed). HOST-VERIFIED (research §5).

# CRITICAL (kill -- -<pgid> needs the `--`): the pgid is a positive integer but the arg starts
#   with '-', so `kill` parses `-<pgid>` as a FLAG without `--`. `kill -- -"$PGID"` signals the
#   whole process group (negative pid). HOST-VERIFIED. PRD §2.19 + key_findings FINDING 6.

# CRITICAL (numeric-guard pid/pgid args): a PROVISIONAL lease writes chrome_pid=0 and
#   chrome_pgid=0 (PRD §2.4 step 3d — before the post-lock boot fills them in). pool_chrome_kill
#   MUST guard `[[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 0 ]]` (and same for pid) before signalling,
#   so pool_chrome_kill 0 0 is a safe no-op. Also defends non-numeric/junk from a corrupt lease.

# GOTCHA (pool_daemon_connected signature ADDS port): the item CONTRACT step 3b names
#   pool_daemon_connected(session). The reliable, side-effect-free check needs the POOLED PORT
#   (curl /json/version), so the signature is pool_daemon_connected(session, port). session is
#   STILL USED (the `session list` membership pre-check). Document the deviation; the literal
#   `get cdp-url` form is broken (above). This is a justified deviation in service of the
#   contract's INTENT ("return 0 if connected, 1 if not").

# GOTCHA (session list is READ-ONLY but IMPRECISE after close): `agent-browser --json session
#   list` never launches a chrome (verified), but a session LINGERS in the list after a
#   disconnect-only `close` (verified, research §3 last row). So "session in list" ≠ "currently
#   bound"; it means "the daemon once knew this session". Combined with the curl chrome-probe,
#   the only imprecise case is right after a close (session lingers + chrome still alive →
#   returns 0). Per PRD §2.8 that is INTENDED ("next call reuses the same browser"); the §2.8
#   [OPEN — confirm] is M6.T1.S2's concern, not this primitive's. Document for consumers.

# GOTCHA (all three NON-FATAL — never pool_die): they run inside acquire/release/reap where one
#   dead/unbindable lane must not abort the pool. Return rc; let the caller decide. Same family
#   as pool_wait_cdp / pool_find_free_port / pool_lease_read. CALLERS under set -e MUST guard:
#   `if pool_daemon_connect …; then …` / `pool_daemon_connected … || pool_daemon_connect …`.

# GOTCHA (the daemon is SHARED — use throwaway abpool-* session names in tests): FINDING 4 — a
#   daemon with ~24 pre-existing manual sessions (t7, weaveapply, …) is already running. The
#   pool's abpool-<N> namespace does NOT collide. In tests, NEVER call close --all or otherwise
#   touch non-abpool sessions. Validation below uses abpool-prp-* names only.

# GOTCHA (pool_chrome_kill is Chrome-teardown ONLY — no daemon close): do NOT call
#   `agent-browser --session <name> close` inside pool_chrome_kill. Daemon/session disconnect is
#   the wrapper's close interception (M6.T1.S2) + release's lease-delete (M5.T2.S1). Scope: kill
#   the Chrome process tree. (close also lingers the session — research §3 — so it wouldn't even
#   clean the daemon state.)

# GOTCHA (do NOT refactor pool_wait_cdp): pool_wait_cdp (M4.T2.S2) has its OWN inline
#   `kill -- -"$POOL_CHROME_PGID"` (single SIGKILL) for the CDP-timeout cleanup path. It is a
#   DIFFERENT, faster teardown for a half-booted chrome. pool_chrome_kill is the CANONICAL
#   thorough teardown (SIGTERM→grace→SIGKILL + bare-pid fallback) for release/reap. They
#   intentionally coexist. Touching pool_wait_cdp is out of scope (it's M4.T2.S2's deliverable).

# GOTCHA (naming): pool_daemon_connect + pool_daemon_connected + pool_chrome_kill — the CONTRACT
#   names these exactly. (key_findings' pool_lane_* convention is a suggestion; the CONTRACT
#   wins. pool_chrome_kill pairs naturally with pool_chrome_launch M4.T2.S2.) Do NOT rename.

# GOTCHA (placement): APPEND at EOF (after pool_wait_cdp). Do NOT touch any existing function.
#   This task only READS POOL_REAL_BIN (frozen by pool_config_init).

# GOTCHA (scope): connect + verify + Chrome-teardown ONLY. Do NOT: take/release the flock
#   (M5.T1.S1); orchestrate acquire/release/reap (M5); update the lease's connected/chrome_pid/
#   chrome_pgid (M5.T1.S2/M5.T2.S1 — the callers read our rc + pass our args); intercept the
#   wrapper's close --all (M6.T1.S2); or relaunch a crashed chrome (M5.T1.S3 owns the
#   relaunch+reconnect policy; pool_daemon_connected only ANSWERS "is it connected?").
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout** and **no new env vars**. It defines THREE
functions, exports NO globals (it reads one, `POOL_REAL_BIN`), and takes args. It shells out
to `agent-browser`, `curl`, `jq`, `kill`, `sleep` — all verified present (external_deps §4).

Global READ (frozen by `pool_config_init`, M1.T1.S2):

| global | source env var | example | role |
|---|---|---|---|
| `POOL_REAL_BIN` | `AGENT_BROWSER_REAL` | `/home/dustin/.local/bin/agent-browser` | the agent-browser binary (daemon client) — connect + connected probes |

Args (from the lease — see external_deps §6 schema; passed by the consumers M5.T1/M5.T2/M5.T3):

| arg | example | used by | source lease field |
|---|---|---|---|
| `session` | `abpool-3` | pool_daemon_connect, pool_daemon_connected | `session` |
| `port` | `53427` | pool_daemon_connect, pool_daemon_connected | `port` |
| `chrome_pid` | `104816` | pool_chrome_kill | `chrome_pid` |
| `chrome_pgid` | `104816` (== pid, setsid) | pool_chrome_kill | `chrome_pgid` |

External commands (verified present): `agent-browser` (`"$POOL_REAL_BIN"` — symlink →
`agent-browser-linux-x64`), `curl` (`curl -sf http://127.0.0.1:<port>/json/version`),
`jq` (`jq -e --arg s … '.data.sessions|index($s)'`), `kill` (builtin), `sleep` (builtin/utility).

**Naming** (CONTRACT-mandated, exact): `pool_daemon_connect`, `pool_daemon_connected`,
`pool_chrome_kill`. No `_` prefix — public entry points (mirror `pool_chrome_launch` /
`pool_wait_cdp`). Internal-only in practice (sole consumers M5.\*).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init pool_die _pool_log pool_wait_cdp'
  - EXPECT: all five reported as functions. (pool_config_init M1.T1.S2 @126; pool_state_init
        M1.T1.S3 @202; pool_die/_pool_log M1.T1.S1 @30/@39; pool_wait_cdp M4.T2.S2 @EOF.)
        If any is MISSING, STOP — this task depends on them.
  - RUN (sanity-check POOL_REAL_BIN, the one global this task reads):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -x "$POOL_REAL_BIN" ]] && echo "OK POOL_REAL_BIN=$POOL_REAL_BIN" || echo FAIL'
        # EXPECT: OK POOL_REAL_BIN=/home/dustin/.local/bin/agent-browser (or override).
  - RUN (verify the external commands):
        command -v curl >/dev/null && echo "OK curl" || echo FAIL
        command -v jq >/dev/null && echo "OK jq" || echo FAIL
        command -v sleep >/dev/null && echo "OK sleep" || echo FAIL
        # kill is a bash builtin (always present).
        # EXPECT: all OK.
  - RUN (verify the agent-browser daemon + the read-only session-list behavior ONCE):
        SESS="abpool-task0-$$"
        before="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        agent-browser --json session list >/dev/null 2>&1 && echo "OK session list rc 0" || echo FAIL
        after="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK session list READ-ONLY (no launch)" || echo "FAIL session list launched a chrome"
        # EXPECT: OK session list rc 0 ; OK session list READ-ONLY (no launch).
        #   If the second FAILs, the host's agent-browser launches on session list — STOP and
        #   consult research §3 (the pool_daemon_connected design depends on session list being
        #   non-launching).
  - RUN (locate the append point — current EOF):
        tail -5 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^pool_wait_cdp\(\)' lib/pool.sh
  - EXPECT: the last function is pool_wait_cdp. APPEND the new banner + three functions AFTER
        its closing brace. Do NOT touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_daemon_connect() + pool_daemon_connected() + pool_chrome_kill() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_wait_cdp's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block):
        # =============================================================================
        # Lane lifecycle — daemon connect, verify & teardown (P1.M4.T3.S1)
        # =============================================================================
        # The three daemon/Chrome primitives of the pool: bind the shared agent-browser daemon
        # to a pooled Chrome (connect), check that binding SIDE-EFFECT-FREE (connected), and tear
        # down a Chrome's whole process tree idempotently (kill). Implements PRD §2.4 step 3i
        # (CONNECT), step 4 (ENSURE CONNECTED — stray-free), §2.5/§2.10 (release = kill pgroup),
        # §2.19 (kill -- -<pgid>), key_findings FINDING 6. Consumed by the acquire post-lock boot
        # (M5.T1.S2), ensure_connected (M5.T1.S3), release (M5.T2.S1), and the reaper (M5.T3.*).

        # pool_daemon_connect SESSION PORT
        #
        # Bind the agent-browser daemon session SESSION to the pooled Chrome on PORT by running
        # `$POOL_REAL_BIN --session "$SESSION" connect "$PORT"`. Returns the subprocess rc:
        # 0 on success (live chrome), 1 on failure (dead port / unreachable). NON-FATAL — never
        # pool_die; the caller (M5.T1.S2) owns the retry policy.
        #
        # LOGIC (CONTRACT 3a, HOST-VERIFIED research §1):
        #   - "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1
        #   - return its rc (connect to live chrome → rc 0 + binds; connect to dead port → rc 1,
        #     "All CDP discovery methods failed … Connection refused").
        #
        # CONSUMER: M5.T1.S2 acquire post-lock boot (PRD §2.4 step 3i), called right after
        #   pool_wait_cdp succeeds. M5.T3.S2 reuse_orphan (re-bind an adopted session). CONTRACT:
        #   rc 0 → session bound (caller writes connected:true); rc 1 → caller retries / drops.
        #   Caller MUST guard under set -e: `if pool_daemon_connect …; then …`.
        #
        # GOTCHA — connect to a DEAD port is a CLEAN rc 1 (HOST-VERIFIED, research §1): agent-browser
        #   prints "✗ All CDP discovery methods failed … Connection refused" and exits 1. It does
        #   NOT launch anything. So pool_daemon_connect is safe to call speculatively.
        # GOTCHA — connect is IDEMPOTENT / re-bindable (HOST-VERIFIED, research §1): re-running
        #   connect on an already-bound session + same-live-port returns rc 0 (re-binds). Safe to
        #   call in ensure_connected's reconnect path.
        # GOTCHA — the daemon auto-starts on the first command of a session (researcher finding 12);
        #   no explicit daemon-start is needed before connect.
        # GOTCHA — the daemon is SHARED (FINDING 4): SESSION is an isolated binding in the shared
        #   daemon; the pool's abpool-<N> namespace does not collide with existing manual sessions.
        # Reads ONLY POOL_REAL_BIN (frozen by pool_config_init). Writes nothing.
        # PRECONDITION: pool_config_init (for POOL_REAL_BIN).
        pool_daemon_connect() {
            local session="${1:-}"
            local port="${2:-}"

            # Validate args (defensive, NON-FATAL rc 1 — never pool_die). `[[ ]] || return 1`
            # is errexit-exempt.
            [[ -n "$session" ]] || return 1
            [[ "$port" =~ ^[0-9]+$ ]] || return 1
            [[ -n "$POOL_REAL_BIN" ]] || return 1

            # Bind. >/dev/null 2>&1 — we only care about the rc. The daemon auto-starts if needed.
            # NOTE: do NOT add `|| true` here — we WANT to return the real rc (0 live / 1 dead).
            # The `command ; return $?` form is set -e safe (the command's non-zero does not abort
            # because it is the LAST statement before an explicit return; but be explicit):
            "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1 || return 1
            return 0
        }

        # pool_daemon_connected SESSION PORT
        #
        # Side-effect-free "is this lane's pooled Chrome connected/drivable?" check. Returns 0 if
        # BOTH (1) the daemon knows about SESSION and (2) the pooled Chrome on PORT answers CDP;
        # returns 1 otherwise. NON-FATAL — never pool_die, NEVER launches a Chrome.
        #
        # ⚠️ DEVIATES FROM THE LITERAL CONTRACT STEP 3b (research §2): the contract said
        #   `get cdp-url >/dev/null 2>&1`, but on agent-browser 0.28.0 `get cdp-url` on a
        #   disconnected/dead-chrome session AUTO-LAUNCHES a stray managed Chrome (verified: chrome
        #   count 61→67) and ALWAYS returns rc 0 — so it can never report "not connected" AND it
        #   leaks/strays. There is NO --no-launch flag (researcher confirmed). This function uses
        #   TWO read-only, non-launching probes instead (research §3 + §4).
        #
        # LOGIC (HOST-VERIFIED research §3/§4/§6):
        #   1. SESSION known to the daemon? `--json session list` is READ-ONLY (never launches);
        #      absent ⇒ fresh/restarted daemon ⇒ return 1.
        #   2. pooled Chrome on PORT alive? `curl -sf /json/version` never launches; dead ⇒ return 1
        #      (PRD §2.14 Chrome crash — the primary failure).
        #   3. both pass ⇒ return 0.
        #
        # WHY THE SIGNATURE ADDS PORT: the only reliable, stray-free signal for "connected" is the
        # pooled Chrome's liveness (curl), which needs the port. SESSION is still used (step 1).
        #
        # CONSUMER: M5.T1.S3 ensure_connected (the HOT PATH — every invocation). CONTRACT:
        #   rc 0 → lane drivable, proceed to exec; rc 1 → reconnect/relaunch. Recommended idiom:
        #     pool_daemon_connected "$session" "$port" || pool_daemon_connect "$session" "$port"
        #   ⚠️ This REPLACES the literal PRD §2.4 step 4 `get cdp-url || connect` (broken on 0.28.0).
        #   Also M5.T3.S2 reuse_orphan (is the orphan's chrome responsive?).
        #
        # GOTCHA — get cdp-url is FORBIDDEN here (research §2 auto-launch trap). Read-only probes only.
        # GOTCHA — session list is READ-ONLY but IMPRECISE after close (research §3): a session
        #   LINGERS in the list after a disconnect-only close, so "in list" ≠ "currently bound".
        #   Combined with the curl chrome-probe, the only imprecise case is right after a close
        #   (lingering session + still-alive chrome → returns 0). Per PRD §2.8 that is INTENDED
        #   ("next call reuses the same browser"); the §2.8 [OPEN — confirm] is M6.T1.S2's concern.
        # GOTCHA — NON-FATAL (return 0/1, never pool_die): same family as pool_wait_cdp.
        # GOTCHA — CALLERS under set -e MUST guard: `if pool_daemon_connected …; then …` or
        #   `pool_daemon_connected … || <reconnect>`.
        # Reads ONLY POOL_REAL_BIN (for `session list`). Writes nothing. Launches nothing.
        # PRECONDITION: pool_config_init (for POOL_REAL_BIN).
        pool_daemon_connected() {
            local session="${1:-}"
            local port="${2:-}"

            # Validate args (defensive, NON-FATAL rc 1).
            [[ -n "$session" ]] || return 1
            [[ "$port" =~ ^[0-9]+$ ]] || return 1
            [[ -n "$POOL_REAL_BIN" ]] || return 1

            # (1) Is SESSION known to the daemon? `session list` is READ-ONLY (never launches —
            #     research §3). `--json` → {"success":true,"data":{"sessions":[…]}}. jq -e exits 0
            #     iff index($session) is non-null (session present). The `if !` is errexit-exempt;
            #     a transient agent-browser/jq failure degrades to "not connected" (return 1) — SAFE
            #     (caller reconnects). 2>/dev/null keeps stderr clean.
            if ! "$POOL_REAL_BIN" --session "$session" --json session list 2>/dev/null \
                    | jq -e --arg s "$session" '.data.sessions | index($s)' >/dev/null 2>&1; then
                return 1
            fi

            # (2) Is the pooled Chrome on PORT alive? curl /json/version is SIDE-EFFECT-FREE (never
            #     launches — research §4). rc 0 = HTTP 200 = alive; non-zero = dead/unreachable.
            #     `|| return 1` is errexit-exempt. curl -sf: -s silent, -f fail-on-HTTP-error.
            curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || return 1

            # (3) Session known + chrome alive ⇒ connected/drivable.
            return 0
        }

        # pool_chrome_kill CHROME_PID CHROME_PGID
        #
        # Tear down a pooled Chrome's ENTIRE process tree idempotently: SIGTERM the process group,
        # wait briefly, SIGKILL the group, then a bare-pid fallback. Safe to call on already-dead
        # processes (every kill is `2>/dev/null || true`) and on provisional-lease args
        # (CHROME_PID=0 / CHROME_PGID=0 are skipped). Returns 0 ALWAYS (teardown must never fail
        # the caller). NON-FATAL — never pool_die. Does NOT touch the daemon session (Chrome-only).
        #
        # LOGIC (CONTRACT 3c, HOST-VERIFIED research §5):
        #   - Primary:  kill -- -"$chrome_pgid" 2>/dev/null || true       (SIGTERM the pgroup)
        #   - Wait:     sleep 0.5                                              (let stragglers exit)
        #   - Force:    kill -9 -- -"$chrome_pgid" 2>/dev/null || true       (SIGKILL the pgroup)
        #   - Fallback: kill   "$chrome_pid" 2>/dev/null || true             (bare pid, if pgid
        #               kill -9 "$chrome_pid" 2>/dev/null || true              missed the leader)
        #   Numeric guards: skip pgid/pid <= 0 (provisional lease) or non-numeric.
        #
        # CONSUMER: M5.T2.S1 release + M5.T3.S1 reap_stale (per-lane teardown, reading
        #   chrome_pid/chrome_pgid from the lease). CONTRACT: rc 0 always; the whole tree is gone
        #   (0 orphans) on return. Idempotent — safe in reap loops over many (possibly-dead) lanes.
        #
        # GOTCHA — kill on an ALREADY-DEAD target returns rc 1 (ESRCH) → ABORTS under set -e
        #   (lib/pool.sh line 17 `set -euo pipefail`). EVERY kill MUST be `… 2>/dev/null || true`.
        #   This IS the idempotency mechanism (no kill -0 pre-check). HOST-VERIFIED (research §5).
        # GOTCHA — `kill -- -<pgid>` needs the `--` (pgid is positive but the arg starts with '-').
        #   The negative-pid form signals the whole process group (renderer/GPU/utility children).
        #   PRD §2.19 + key_findings FINDING 6.
        # GOTCHA — numeric guards: a PROVISIONAL lease writes chrome_pid=0, chrome_pgid=0 (PRD §2.4
        #   step 3d). Guard `[[ =~ ^[0-9]+$ && -gt 0 ]]` so pool_chrome_kill 0 0 is a safe no-op.
        # GOTCHA — SIGTERM → sleep 0.5 → SIGKILL escalation is sound (research §5): Chrome responds
        #   to SIGTERM but renderer/GPU/utility children can lag; the 0.5 s grace then SIGKILL
        #   catches stragglers. Verified 0 orphans after escalation.
        # GOTCHA — the bare-pid fallback covers a pgid of 0 (provisional) OR a missed group leader;
        #   it is NOT a substitute for the group kill (which catches children the bare pid misses).
        # GOTCHA — Chrome-teardown ONLY: do NOT call `agent-browser --session <name> close` here.
        #   Daemon/session disconnect is the wrapper's close interception (M6.T1.S2) + release's
        #   lease-delete (M5.T2.S1). Scope: kill the Chrome tree.
        # GOTCHA — do NOT confuse with pool_wait_cdp's inline single-SIGKILL (M4.T2.S2, CDP-timeout
        #   cleanup). This is the CANONICAL thorough teardown for release/reap. They coexist; do
        #   NOT refactor pool_wait_cdp.
        # Reads NO globals (args only). Writes nothing. Returns 0 always.
        pool_chrome_kill() {
            local chrome_pid="${1:-}"
            local chrome_pgid="${2:-}"

            # Primary + force: signal the PROCESS GROUP (negative pid). Numeric guard: skip
            # non-numeric or <= 0 (provisional lease pgid=0). SIGTERM (default) → grace → SIGKILL.
            if [[ "$chrome_pgid" =~ ^[0-9]+$ ]] && (( chrome_pgid > 0 )); then
                kill -- -"$chrome_pgid" 2>/dev/null || true    # SIGTERM the whole pgroup
                sleep 0.5                                     # let renderer/GPU/utility children exit
                kill -9 -- -"$chrome_pgid" 2>/dev/null || true # SIGKILL any stragglers
            fi

            # Fallback: bare pid (covers pgid=0 / missed leader). Numeric guard as above.
            if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
                kill   "$chrome_pid" 2>/dev/null || true      # SIGTERM the leader
                kill -9 "$chrome_pid" 2>/dev/null || true     # SIGKILL the leader
            fi

            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155); arg validation via
        `[[ ]] || return 1` (errexit-exempt, NON-FATAL — same family as pool_wait_cdp); `2>/dev/null`
        on agent-browser/curl/kill (never flood stderr); `|| return 1` / `|| true` to keep the
        caller alive under set -e; `(( x > 0 ))` inside `&&` (errexit-safe).
  - NAMING: pool_daemon_connect + pool_daemon_connected + pool_chrome_kill (CONTRACT-mandated).
  - PLACEMENT: the only three functions in the new "(P1.M4.T3.S1)" banner.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_daemon_connect pool_daemon_connected pool_chrome_kill' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: pool_daemon_connect — live vs dead port (rc 0 / rc 1, no abort) ---
  - RUN (launch a REAL headless Chrome on a free port, then connect):
        STATE="$(mktemp -d)"; UDD="$(mktemp -d)/lane-c"
        PORT=55594
        setsid google-chrome-stable --remote-debugging-port="$PORT" --user-data-dir="$UDD" \
          --no-first-run --no-default-browser-check --headless=new >/tmp/s1-chrome.log 2>&1 &
        CP=$!
        for i in $(seq 1 20); do curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break; sleep 0.5; done
        SESS="abpool-s1-$$"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_daemon_connect "'"$SESS"'" "'"$PORT"'"; then echo OK1-connect-live; else echo FAIL1; fi'
        # EXPECT: OK1-connect-live.
  - RUN (connect to a DEAD port → rc 1, no abort under set -e):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_daemon_connect "'"$SESS"'" 55593; then echo FAIL2-should-be-dead; else echo OK2-connect-dead-rc1; fi'
        # EXPECT: OK2-connect-dead-rc1.
  #
  # --- SCENARIO 2: pool_daemon_connected — connected rc 0; dead-chrome rc 1; NEVER launches ---
  - RUN (after the live connect in SCENARIO 1 → connected rc 0):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_daemon_connected "'"$SESS"'" "'"$PORT"'"; then echo OK3-connected; else echo FAIL3; fi'
        # EXPECT: OK3-connected.
  - RUN (NEVER-seen session → rc 1, NO launch):
        before="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_daemon_connected "abpool-never-'"$$"'" "'"$PORT"'"; then echo FAIL4-never; else echo OK4-never-rc1; fi'
        after="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK4-no-launch ($before==$after)" || echo "FAIL4-STRAY-LAUNCH ($before->$after)"
        # EXPECT: OK4-never-rc1 ; OK4-no-launch (N==N).  ← proves the §2 trap is avoided.
  - RUN (kill the pooled chrome → connected rc 1, NO stray launch — THE key assertion):
        PGP="$(ps -o pgid= -p "$CP" | tr -d ' ')"; kill -9 -- -"$PGP" 2>/dev/null; sleep 1
        before="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_daemon_connected "'"$SESS"'" "'"$PORT"'"; then echo FAIL5-should-be-dead; else echo OK5-dead-chrome-rc1; fi'
        after="$(pgrep -c -f remote-debugging-port 2>/dev/null || echo 0)"
        [[ "$before" == "$after" ]] && echo "OK5-no-stray ($before==$after)" || echo "FAIL5-STRAY-LAUNCH ($before->$after)"
        # EXPECT: OK5-dead-chrome-rc1 ; OK5-no-stray (N==N).  ← THE headline: dead chrome, NO stray.
        #   (If FAIL5-STRAY-LAUNCH, the implementer used get cdp-url — re-read Gotchas + research §2.)
  #
  # --- SCENARIO 3: pool_chrome_kill — whole-tree teardown, 0 orphans, idempotent ---
  - RUN (launch a fresh Chrome + children, then kill the whole tree):
        setsid google-chrome-stable --remote-debugging-port=55592 --user-data-dir="$UDD" \
          --no-first-run --no-default-browser-check --headless=new >/tmp/s3-chrome.log 2>&1 &
        CP2=$!
        for i in $(seq 1 20); do curl -sf "http://127.0.0.1:55592/json/version" >/dev/null 2>&1 && break; sleep 0.5; done
        PG2="$(ps -o pgid= -p "$CP2" | tr -d ' ')"
        kids_before="$(pgrep -c -P "$CP2" 2>/dev/null || echo 0)"; echo "children before kill: $kids_before"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_kill "'"$CP2"'" "'"$PG2"'"; echo "kill rc=$?"'
        sleep 0.6
        kill -0 "$CP2" 2>/dev/null && echo "FAIL6-alive" || echo "OK6-dead"
        orphans="$(pgrep -P "$CP2" 2>/dev/null | wc -l)"; echo "orphaned children: $orphans"
        # EXPECT: children before kill: >=1 ; OK6-dead ; orphaned children: 0.
  - RUN (idempotent — call AGAIN on the now-dead pids; rc 0, no set -e abort):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_kill "'"$CP2"'" "'"$PG2"'"; echo "re-kill rc=$?"'
        # EXPECT: re-kill rc=0.  (every kill was || true — no ESRCH abort.)
  - RUN (provisional-lease args → rc 0, no-op):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_kill 0 0; echo "kill-0-0 rc=$?"'
        # EXPECT: kill-0-0 rc=0.
  #
  # --- SCENARIO 4: full acquire-style sequence — connect → connected → kill → connected(dead) ---
  - RUN (the end-to-end primitive chain a real acquire/ensure/release uses):
        setsid google-chrome-stable --remote-debugging-port=55591 --user-data-dir="$UDD" \
          --no-first-run --no-default-browser-check --headless=new >/tmp/s4-chrome.log 2>&1 &
        CP3=$!
        for i in $(seq 1 20); do curl -sf "http://127.0.0.1:55591/json/version" >/dev/null 2>&1 && break; sleep 0.5; done
        PG3="$(ps -o pgid= -p "$CP3" | tr -d ' ')"
        SESS4="abpool-s4-$$"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_daemon_connect "'"$SESS4"'" 55591                                              || { echo FAIL4a; exit 1; }
                  pool_daemon_connected "'"$SESS4"'" 55591                                            || { echo FAIL4b; exit 1; }
                  pool_chrome_kill "'"$CP3"'" "'"$PG3"'"
                  if pool_daemon_connected "'"$SESS4"'" 55591; then echo FAIL4c-still-connected; else echo OK4-end-to-end; fi'
        # EXPECT: OK4-end-to-end.  (connect → connected(0) → kill → connected(1).)
  #
  # --- CLEANUP all test chromes/sessions ---
  - RUN:
        for c in "$CP" "$CP2" "$CP3"; do g="$(ps -o pgid= -p "$c" 2>/dev/null | tr -d ' ')" && kill -9 -- -"$g" 2>/dev/null; done
        for p in $(pgrep -f "$UDD" 2>/dev/null); do g="$(ps -o pgid= -p "$p" | tr -d ' ')"; kill -9 -- -"$g" 2>/dev/null; done
        for s in "$SESS" "abpool-s1-$$" "$SESS4"; do "$HOME/.local/bin/agent-browser" --session "$s" close >/dev/null 2>&1 || true; done
        rm -rf "$STATE" "$(dirname "$UDD")" 2>/dev/null
        echo "remaining chromes with our UDD: $(pgrep -f "$UDD" 2>/dev/null | wc -l)"
  - EXPECT: 0 remaining.
  #
  # --- PRIOR-DELIVERABLES regression (must still all be callable) ---
  - RUN:
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 type pool_config_init pool_state_init pool_die _pool_log \
                      pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_read pool_lease_field \
                      pool_lanes_list pool_find_free_lane pool_lane_is_stale \
                      pool_copy_master pool_find_free_port pool_chrome_launch pool_wait_cdp \
                      pool_daemon_connect pool_daemon_connected pool_chrome_kill' >/dev/null && echo OK-regression
  - EXPECT: OK-regression (all prior functions + the three new ones present).
```

### Implementation Patterns & Key Details

```bash
# PATTERN: the non-fatal rc-returning primitive (same family as pool_wait_cdp / pool_find_free_port).
#   Validate args with `[[ ]] || return 1` (errexit-exempt). Run the work; return its rc.
#   NEVER pool_die. Caller guards under set -e: `if pool_X …; then …` or `pool_X … || <recovery>`.
pool_daemon_connect() {
    local session="${1:-}" port="${2:-}"
    [[ -n "$session" ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1 || return 1
    return 0
}

# PATTERN: side-effect-free probe (NO agent-browser driving command — those auto-launch).
#   Read-only `session list` (non-launching) + curl /json/version (non-launching). Both `|| return 1`.
pool_daemon_connected() {
    local session="${1:-}" port="${2:-}"
    [[ -n "$session" && "$port" =~ ^[0-9]+$ ]] || return 1
    # (1) session known? (read-only — never launches)
    "$POOL_REAL_BIN" --session "$session" --json session list 2>/dev/null \
        | jq -e --arg s "$session" '.data.sessions | index($s)' >/dev/null 2>&1 || return 1
    # (2) chrome alive? (curl — never launches)
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || return 1
    return 0
}

# PATTERN: idempotent teardown. EVERY kill `2>/dev/null || true` (ESRCH on dead → rc 1 → would
#   ABORT under set -e). Numeric guards skip provisional-lease 0 / non-numeric. Returns 0 always.
pool_chrome_kill() {
    local chrome_pid="${1:-}" chrome_pgid="${2:-}"
    if [[ "$chrome_pgid" =~ ^[0-9]+$ ]] && (( chrome_pgid > 0 )); then
        kill   -- -"$chrome_pgid" 2>/dev/null || true   # SIGTERM pgroup
        sleep 0.5
        kill -9 -- -"$chrome_pgid" 2>/dev/null || true   # SIGKILL stragglers
    fi
    if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
        kill   "$chrome_pid" 2>/dev/null || true          # bare-pid fallback
        kill -9 "$chrome_pid" 2>/dev/null || true
    fi
    return 0
}
```

### Integration Points

```yaml
GLOBALS (read-only):
  - POOL_REAL_BIN: "frozen by pool_config_init (M1.T1.S2); default $HOME/.local/bin/agent-browser.
                    Read by pool_daemon_connect + pool_daemon_connected. pool_chrome_kill reads NONE."

LEASE FIELDS (read BY CONSUMERS, passed INTO these primitives as args — external_deps §6 schema):
  - session:      "abpool-<N>          → pool_daemon_connect(_connected) arg $1"
  - port:         "<POOL_PORT_BASE+>   → pool_daemon_connect(_connected) arg $2"
  - chrome_pid:   "<setsid pid>        → pool_chrome_kill arg $1"
  - chrome_pgid:  "== chrome_pid       → pool_chrome_kill arg $2"

CONSUMERS (downstream — NOT this task's work, documented as contract):
  - M5.T1.S2: "acquire post-lock boot calls pool_daemon_connect at PRD §2.4 step 3i, then writes
               connected:true via pool_lease_update."
  - M5.T1.S3: "ensure_connected calls pool_daemon_connected (NOT the broken `get cdp-url`);
               idiom: pool_daemon_connected \"$s\" \"$p\" || pool_daemon_connect \"$s\" \"$p\".
               Owns the chrome-relaunch policy on rc 1 (PRD §2.14)."
  - M5.T2.S1: "release calls pool_chrome_kill(lease.chrome_pid, lease.chrome_pgid), then rm dir + delete lease."
  - M5.T3.S1: "reap_stale calls pool_chrome_kill per stale lane."
  - M5.T3.S2: "reuse_orphan calls pool_daemon_connected (is orphan chrome responsive?) + pool_daemon_connect (re-bind)."

NO NEW:
  - files: "none (pure append to lib/pool.sh)."
  - env vars: "none."
  - globals: "none exported (reads POOL_REAL_BIN only)."
  - leases/migrations: "none."
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the three functions — fix before proceeding.
bash -n lib/pool.sh                       # syntax — MUST be clean
shellcheck lib/pool.sh                    # zero warnings (whole file, incl. the new functions)

# Expected: Zero errors. shellcheck may flag the intentional `|| true`/`|| return 1` patterns
# as SC2086 on the kill args if unquoted — the kill args ARE quoted ("$chrome_pgid"); ensure
# `kill -- -"$chrome_pgid"` (quoted) not `kill -- -$chrome_pgid` (unquoted). Read any output
# and fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# No bats harness yet (M9.T1.S1). Validate via the SCENARIO blocks in Task 2 above — each is a
# self-contained bash -c against a REAL Chrome + the REAL daemon. Re-run any scenario in isolation:
#
#   pool_daemon_connect live/dead:
STATE="$(mktemp -d)"; UDD="$(mktemp -d)/u"; PORT=55590
setsid google-chrome-stable --remote-debugging-port="$PORT" --user-data-dir="$UDD" \
  --no-first-run --no-default-browser-check --headless=new >/dev/null 2>&1 &
CP=$!; for i in $(seq 1 20); do curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break; sleep 0.5; done
AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
   pool_daemon_connect abpool-u-'"$$"' '"$PORT"' && echo OK-live || echo FAIL-live
   pool_daemon_connect abpool-u-'"$$"' 55589 && echo FAIL-dead || echo OK-dead-rc1'
#
#   pool_chrome_kill idempotent + 0 orphans (see Task 2 SCENARIO 3).
#
# Expected: OK-live ; OK-dead-rc1 ; (kill scenarios) 0 orphans, idempotent rc 0.
# Cleanup:
g="$(ps -o pgid= -p "$CP" 2>/dev/null | tr -d ' ')" && kill -9 -- -"$g" 2>/dev/null
for p in $(pgrep -f "$UDD" 2>/dev/null); do gg="$(ps -o pgid= -p "$p"|tr -d ' ')"; kill -9 -- -"$gg" 2>/dev/null; done
rm -rf "$STATE" "$(dirname "$UDD")" 2>/dev/null
```

### Level 3: Integration Testing (System Validation)

```bash
# The full acquire-style primitive chain (Task 2 SCENARIO 4) IS the integration test:
# connect → connected(0) → kill → connected(1), against the REAL daemon + REAL Chrome.
# Re-run it end-to-end and assert OK4-end-to-end. See Task 2 SCENARIO 4 for the exact block.

# Daemon/CLI sanity (the shared daemon is healthy; our abpool-* sessions don't disturb others):
agent-browser --json session list >/dev/null 2>&1 && echo "OK daemon responds" || echo FAIL
# Expected: OK daemon responds.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# THE critical domain-specific assertion for this task: pool_daemon_connected MUST NOT launch a
# Chrome on a dead-chrome session (the §2 trap). This is the difference between a working pool
# and one that silently drives stray profiles. Run Task 2 SCENARIO 2 (the before/after pgrep -c
# assertion) and assert OK5-no-stray (N==N). If it FAILs, the implementer used get cdp-url —
# re-read the Gotchas + research §2.

# Concurrency note (for the consumer, not this primitive): the daemon is SHARED across lanes;
# concurrent pool_daemon_connect for distinct abpool-<N> sessions are independent bindings and do
# not collide (verified by the abpool-* namespace isolation). This primitive itself is stateless
# beyond the subprocess call, so it is safe under concurrent acquire/release.
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean.
- [ ] `shellcheck lib/pool.sh` clean (whole file).
- [ ] All Task 2 scenarios pass (connect live/dead, connected 0/1 + no-launch, kill 0-orphans +
      idempotent, end-to-end chain).
- [ ] Prior-deliverables regression (Task 2 final RUN) reports OK-regression.

### Feature Validation

- [ ] `pool_daemon_connect <sess> <live-port>` → 0; `<dead-port>` → 1 (no abort).
- [ ] After connect, `pool_daemon_connected <sess> <port>` → 0; after chrome killed → 1.
- [ ] `pool_daemon_connected` NEVER changes the chrome proc count (the §2 no-stray assertion).
- [ ] `pool_chrome_kill <pid> <pgid>` → 0, 0 orphans; second call → 0 (idempotent); `0 0` → 0.
- [ ] All success criteria from "What" section met.
- [ ] No existing function modified (esp. pool_wait_cdp untouched).

### Code Quality Validation

- [ ] Follows existing codebase patterns (non-fatal rc-returning primitives like pool_wait_cdp;
      `local` first then assign; `[[ ]] || return 1`; `2>/dev/null || true` on every kill).
- [ ] File placement matches the desired tree (appended after pool_wait_cdp under the new banner).
- [ ] Anti-patterns avoided (no get cdp-url in pool_daemon_connected; no unguarded kill; no pool_die
      in these primitives; no daemon `close` in pool_chrome_kill).
- [ ] POOL_REAL_BIN is the only global read; no new globals/env-vars/files.

### Documentation & Deployment

- [ ] Each function has a docstring with LOGIC + CONSUMER + GOTCHA sections (mirrors pool_wait_cdp).
- [ ] The §2 get cdp-url trap + the signature deviation (port added) are documented in the
      pool_daemon_connected docstring (so M5.T1.S3 reads it and does NOT use the literal PRD step 4).
- [ ] _pool_log lines are OPTIONAL (keep minimal; these primitives need not log on the hot path).

---

## Anti-Patterns to Avoid

- ❌ Don't use `get cdp-url` in `pool_daemon_connected` — it auto-launches strays on 0.28.0 (research §2).
- ❌ Don't leave a `kill` unguarded — `kill` on a dead pid returns rc 1 and ABORTS under `set -e`.
- ❌ Don't call `pool_die` in these three primitives — they are non-fatal (return rc).
- ❌ Don't call `agent-browser close` inside `pool_chrome_kill` — it's Chrome-teardown only.
- ❌ Don't refactor `pool_wait_cdp` to call `pool_chrome_kill` — different teardowns, out of scope.
- ❌ Don't rename the functions — the CONTRACT names them exactly.
- ❌ Don't touch the shared daemon's non-abpool sessions (t7, weaveapply, …) in tests.
- ❌ Don't skip the numeric guards — provisional leases carry chrome_pid=0/chrome_pgid=0.
- ❌ Don't add `--no-launch`/`AGENT_BROWSER_NO_LAUNCH` — no such flag exists (researcher confirmed).
- ❌ Don't modify any file other than appending to `lib/pool.sh` (and the research/ notes).

---

## Confidence Score

**9/10** for one-pass implementation success.

**Why 9**: every behavior is **host-verified (2026-07-12)** against the real agent-browser 0.28.0
daemon + real Chrome 149 — the connect rc contract (§1), the get cdp-url auto-launch trap (§2) and
its side-effect-free workaround (§3/§4/§6), the kill idempotency + ESRCH-under-set-e hazard (§5),
and the full connect→connected→kill→connected(dead) chain (Task 2 SCENARIO 4). The single highest
risk — an implementer blindly following the literal CONTRACT step 3b (`get cdp-url`) — is called
out in **5 separate places** (Goal, Gotchas, docstring, validation assertion, Anti-Patterns) with
a concrete before/after `pgrep -c` test that fails loudly if violated.

**Why not 10**: the `pool_daemon_connected` signature deviates from the literal contract (adds
`port`), which an implementer might second-guess; the PRP justifies it thoroughly (the literal
form is broken), and the session-list membership check has one documented imprecise edge case
(after a disconnect-only close, per PRD §2.8 — an M6.T1.S2 concern, flagged for the consumer).
The daemon-restart edge case (chrome alive but daemon unbound) is mitigated by the session-list
pre-check (absent after restart) but depends on the daemon's list semantics, which are verified
for the present/absent cases but not for a live daemon restart (cannot be tested without
disturbing the 24 production sessions on the shared daemon — FINDING 4).
