# PRP — P1.M4.T2.S2: Chrome launch with setsid + anti-throttle + CDP readiness wait

---

## Goal

**Feature Goal**: Implement the **Chrome-launch + CDP-readiness primitives** for the
agent-browser-pool — the two functions that turn a chosen port + an ephemeral profile dir into
a live, pooled Chrome whose whole process tree can be torn down as one unit. This is the
literal realization of PRD §2.6 (Chrome launch per lane), §2.4 step 3g–3h (LAUNCH setsid …;
WAIT for CDP `/json/version`), and the item CONTRACT (steps 3a–3b). Two functions, appended at
EOF of `lib/pool.sh` under a new `# Lane lifecycle — Chrome launch & CDP readiness` banner,
directly after `pool_find_free_port` (the P1.M4.T2.S1 deliverable). They run in the acquire
**post-lock boot** (M5.T1.S2), **outside** the flock critical section (key_findings FINDING 2),
concurrently with other agents' boots.

1. **`pool_chrome_launch(port, user_data_dir, lane)`** — the literal realization of the item
   CONTRACT step 3a:
   ```
   a. Build flag list: --remote-debugging-port=<port>, --user-data-dir=<ABSOLUTE path>,
      --no-first-run, --no-default-browser-check, --disable-background-timer-throttling,
      --disable-backgrounding-occluded-windows, --disable-renderer-backgrounding,
      --disable-features=CalculateNativeWinOcclusion, --disable-back-forward-cache.
      If POOL_HEADLESS=1, add --headless=new.
      Log file: $POOL_STATE_DIR/chrome-<lane>.log.
      Launch: setsid "$POOL_CHROME_BIN" <flags> > "$log_file" 2>&1 &
      Capture CHROME_PID=$!
      Get CHROME_PGID: ps -o pgid= -p $CHROME_PID | tr -d ' '  (should equal CHROME_PID).
      Export CHROME_PID and CHROME_PGID as globals.
   ```
   Exports the globals **`POOL_CHROME_PID`** and **`POOL_CHROME_PGID`** (see Naming below).

2. **`pool_wait_cdp(port)`** — the literal realization of the item CONTRACT step 3b:
   ```
   b. Loop up to 60 times (30s total): curl -sf http://127.0.0.1:<port>/json/version.
      Return 0 if CDP responds, 1 on timeout.
      On timeout: kill the Chrome process group, return 1.
   ```

3. No new files, no new env vars, no user docs ("DOCS: none — internal functions"). Pure
   append of TWO functions. Reads only `POOL_CHROME_BIN`, `POOL_HEADLESS`, `POOL_STATE_DIR`
   (all frozen by `pool_config_init`, M1.T1.S2). Writes nothing to disk except the Chrome log.
   `pool_chrome_launch` `pool_die`s on failure (bad args, instant death, missing log dir);
   `pool_wait_cdp` is **non-fatal** (returns 0/1 — the caller owns the retry policy).

**Deliverable**: Two functions (`pool_chrome_launch`, `pool_wait_cdp`) appended to
`lib/pool.sh` under a new `# Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)`
banner, placed directly after `pool_find_free_port`'s closing brace (the P1.M4.T2.S1
deliverable, which appends after `pool_copy_master` @1253–1312). Pure addition: no edits to
any existing function, no new env-vars/files. Every behavior is **host-verified (2026-07-12)**
via a real `google-chrome-stable` (Chrome 149) end-to-end launch — setsid `pgid==pid` held,
all 9 flags accepted, CDP `/json/version` answered in ~0.5 s, and `kill -- -<pgid>` left
**0 orphans**. See `research/chrome-launch-host-verified.md` (all checks PASSED).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`, calling
  `pool_chrome_launch <port> <abs-udd> <lane>` with `POOL_HEADLESS=1` launches a real headless
  Chrome; sets `POOL_CHROME_PID` (non-empty) and `POOL_CHROME_PGID == POOL_CHROME_PID`
  (the setsid contract); returns 0; writes `$POOL_STATE_DIR/chrome-<lane>.log`.
- After launch, `pool_wait_cdp <port>` returns **0** (CDP `/json/version` responds within
  30 s — host-observed ~0.5 s).
- `/proc/$POOL_CHROME_PID/cmdline` contains **all** required flags verbatim, including
  `--disable-features=CalculateNativeWinOcclusion` and `--headless=new` (when headless).
- `kill -- -"$POOL_CHROME_PGID"` tears down the **entire** Chrome tree (renderer/GPU/utility
  children) with **0 orphans** — verified by `pgrep -P "$POOL_CHROME_PID"` → empty.
- `pool_wait_cdp` on a port with **no** listener returns **1** after ≤30 s, and — if a
  `POOL_CHROME_PGID` is set — kills that process group first.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
  deliverables (M1–M4.T2.S1) unchanged and still callable.

## User Persona

**Target User**: Internal only — no end user or operator ever calls these directly. Their sole
consumer is another function inside the post-lock boot:

- **P1.M5.T1.S2** (acquire **post-lock boot**) — the **primary** consumer. After the flock
  critical section writes the provisional claim and releases the lock (key_findings FINDING 2:
  keep flock short), the post-lock boot does
  `copy → find_free_port → launch → wait_cdp → connect → update lease`. `pool_chrome_launch` +
  `pool_wait_cdp` are the **launch + wait** halves of that boot. After they succeed, M5.T1.S2
  reads `POOL_CHROME_PID`/`POOL_CHROME_PGID` and writes them into the lease's `chrome_pid`/
  `chrome_pgid` fields (external_deps §6 schema).

**Use Case**: Every `agent-browser` invocation that does NOT already hold a valid lease enters
the acquire flow: flock → reap-stale → choose-N → provisional claim (release flock) →
**post-lock boot**. These two functions are the "launch + become-ready" half of that boot.
Without them there is no pooled Chrome to drive, and no reliable process-group handle to tear
it down later.

**Pain Points Addressed**:
- **Chrome must be its own process-group leader so release is clean.** `setsid` makes Chrome a
  session leader (pgid==pid) so release (M5.T2.S1) can `kill -- -<pgid>` the renderer/GPU/
  utility children with no orphans. HOST-VERIFIED: 5 children → 0 orphans.
- **Backgrounded pool windows get JS-timer-throttled on Wayland.** PRD §2.6: the anti-throttle
  flags are REQUIRED. Without them heavy SPA apply forms never hydrate. HOST-VERIFIED: all
  flags survive in `/proc/<pid>/cmdline`.
- **Chrome takes a variable time to bind the CDP port.** Racing straight to `connect`
  (M4.T3.S1) after launch fails intermittently. `pool_wait_cdp` makes readiness deterministic.
- **One place that owns the setsid/`$!`/pgid-capture contract + the instant-death hazard.**
  Centralizing launch means the only consumer (M5.T1.S2) gets a ready Chrome + two globals and
  a clear rc contract.

## Why

- **It is the bring-up step of the ephemeral-profile model.** PRD §1.2/§2.4 define the pool's
  acquire flow; steps 3g ("LAUNCH: setsid google-chrome-stable --remote-debugging-port=…") and
  3h ("WAIT for CDP (/json/version, ≤30×0.5s)") are THESE functions. Everything downstream
  (connect M4.T3.S1, the lease's `chrome_pid`/`chrome_pgid`, release M5.T2.S1) operates on the
  handles these functions produce.
- **The setsid→pgid contract is the teardown foundation.** PRD §2.19 + key_findings FINDING 6:
  launch with `setsid` so pgid==pid; release does `kill -- -<pgid>` to take down the whole
  tree. This function is the **only** place that establishes that invariant; getting it wrong
  leaks Chrome processes on every release.
- **The anti-throttle flags are a correctness requirement, not a nicety.** PRD §2.6 +
  external_deps §2.1 list them for a reason (Wayland throttling). Centralizing them here means
  every lane gets them identically.

## What

User-visible behavior: none directly (internal library primitives). Observable contract:

| scenario | `pool_chrome_launch` / `pool_wait_cdp` |
|---|---|
| valid port+abs-udd+lane, Chrome boots | `pool_chrome_launch` returns **0**; sets `POOL_CHROME_PID` (non-empty), `POOL_CHROME_PGID == POOL_CHROME_PID` |
| `POOL_HEADLESS==1` | `--headless=new` present in `/proc/$POOL_CHROME_PID/cmdline` |
| `POOL_HEADLESS!=1` (default) | no `--headless*` flag (windowed — PRD §2.6) |
| Chrome boots, CDP answers within 30 s | `pool_wait_cdp` returns **0** |
| no Chrome / Chrome never binds CDP within 30 s | `pool_wait_cdp` **kills the pgroup** (if `POOL_CHROME_PGID` set), returns **1** |
| Chrome dies the instant it is launched | `pool_chrome_launch` `pool_die`s ("Chrome (pid …) exited immediately; see <log>") |
| bad args (port not numeric / udd empty or relative / lane not numeric) | `pool_chrome_launch` `pool_die`s before launching anything |

**Hard invariants** (every row):
- **`POOL_CHROME_PGID == POOL_CHROME_PID` after a successful launch** (the setsid contract;
  verified host-side). Both exported via `declare -g`.
- **The pgid capture is GUARDED** against instant death (§5 gotcha): a bare `pg="$(ps -o
  pgid= …)"` would ABORT under `set -e` if Chrome is already gone; we use `|| true` + a
  `[[ -z ]]` check that converts "already dead" into a clean `pool_die` with the log path.
- **`pool_wait_cdp` never `pool_die`s.** Timeout is `return 1` (non-fatal) — the caller
  (M5.T1.S2) owns the "retry launch once; then fail, drop lane" policy (PRD §2.14). Same
  non-fatal family as `pool_find_free_port` (M4.T2.S1).
- **Anti-throttle flags are unconditional.** `--headless=new` is the only conditional flag
  (gated on `POOL_HEADLESS==1`).
- **No bare `~` anywhere** (PRD §2.2): `--user-data-dir` gets the absolute path verbatim;
  `user_data_dir` is validated absolute before launch.
- **The log path's dir is ensured** before the backgrounded redirect (otherwise the shell
  fails to open the redirect and `$!` is a pid that immediately exits — a subtle hazard).

### Success Criteria

- [ ] `pool_chrome_launch` + `pool_wait_cdp` defined in `lib/pool.sh` under a
      `# Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)` banner, directly after
      `pool_find_free_port`'s closing brace. Callable after `source lib/pool.sh` +
      `pool_config_init`.
- [ ] A real headless launch (`POOL_HEADLESS=1`) sets `POOL_CHROME_PID` (non-empty) and
      `POOL_CHROME_PGID == POOL_CHROME_PID`; returns 0.
- [ ] `pool_wait_cdp <port>` returns 0 against the just-launched Chrome within 30 s.
- [ ] `/proc/$POOL_CHROME_PID/cmdline` contains all 9 flags verbatim (incl.
      `--disable-features=CalculateNativeWinOcclusion`, `--headless=new`).
- [ ] `kill -- -"$POOL_CHROME_PGID"` leaves **0 orphans** (`pgrep -P` empty).
- [ ] `pool_wait_cdp <dead-port>` (with a stand-in `POOL_CHROME_PGID` set to a throwaway
      `setsid sleep` pgroup) returns **1** within 30 s **and** the stand-in pgroup is killed.
- [ ] Instant-death path: launching a non-existent binary (`POOL_CHROME_BIN=/no/such/chrome`)
      → `pool_chrome_launch` `pool_die`s cleanly (does NOT abort via a bare `$(…)`).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean (whole file); all prior
      deliverables (M1, M2.\*, M3.\*, M4.T1.S1, M4.T2.S1) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **setsid `$!`/pgid contract**
(host-verified — `setsid CMD &; SP=$!` gives `pgid==pid==sid`; do NOT add `--fork` —
research §1); the **real-Chrome end-to-end proof** (all 9 flags accepted, CDP up in ~0.5 s,
`kill -- -pgid` → 0 orphans — research §2/§3/§4); the **instant-death `set -e` hazard** on
the pgid capture and its mandatory guard (research §5 — the single most important gotcha); the
**15 s vs 30 s CDP-timeout conflict** and its resolution (60×0.5 s = 30 s — research §7); the
**`--` requirement on `kill -- -<pgid>` and `grep -F --`** in flag checks; the exact placement
(after `pool_find_free_port`, the S1 deliverable); the env-var wiring
(`POOL_CHROME_BIN`/`POOL_HEADLESS`/`POOL_STATE_DIR`); and copy-pasteable, host-verified
validation commands including a real-Chrome integration test.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.6 (Chrome launch per lane — the EXACT flag list + setsid + anti-throttle rationale),
        §2.4 step 3g (LAUNCH setsid … + record chrome_pid + pgid) + 3h (WAIT for CDP
        /json/version) — THESE functions, §2.19 (setsid→pgid==pid; kill -- -<pgid>; keep flock
        short → launch is OUTSIDE the flock), §2.14 (Chrome slow to boot → /json/version
        timeout → retry launch once; then fail, drop lane — the CALLER's policy, NOT ours).
  pattern: §2.6 is the literal command; §2.4 step 3g/3h are the acquire-flow call sites.
  gotcha: §2.4 step 3h says "≤30×0.5s" and §2.14 says "15s" but CONTRACT 3b + external_deps §2.2
        say 60×0.5s=30s. PRP resolves to 30s (research §7) — the budget is one named constant.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §2.1 (Launch Command — the EXACT setsid line with redirection `> "$CHROME_LOG" 2>&1 &`
        + the full flag list), §2.2 (CDP Readiness Check — `for i in $(seq 1 60); curl -sf …;
        sleep 0.5; done; return 1` = the 60×0.5s=30s loop THIS task implements), §2.3 (port
        selection — the port ARG comes from pool_find_free_port, M4.T2.S1), §4 (setsid at
        /usr/bin/setsid util-linux; curl at /usr/bin/curl; kill is a builtin), §5
        (AGENT_CHROME_BIN / AGENT_CHROME_HEADLESS env vars), §6 (lease schema chrome_pid /
        chrome_pgid fields the caller writes from our globals).
  pattern: §2.1 IS the launch command; §2.2 IS the readiness loop (paste-ready).
  gotcha: §2.2's loop uses `seq 1 60`; we use a bash `(( ))` counter (no `seq` fork) but the
        budget + sleep 0.5 are identical.

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (flock critical section SHORT → launch + wait run OUTSIDE the flock,
        concurrently across agents), FINDING 3 (no bare ~ → user_data_dir MUST be absolute),
        FINDING 6 (setsid → pgid==pid; CHROME_PID=$!; CHROME_PGID=$(ps -o pgid= -p $PID | tr -d
        ' '); teardown kill -- -<pgid>; fallback pkill -P).
  pattern: FINDING 6 IS the pgid-capture idiom (verbatim); FINDING 2 → non-locking launch.
  gotcha: FINDING 6's `ps -o pgid=` capture is a BARE $(…) that ABORTs under set -e if Chrome
        is already dead — research §5 + the PRP mandate the guard.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — POOL_STATE_DIR is where chrome-<lane>.log lives), the "Note"
        that stock agent-browser uses --remote-debugging-port=0 (random) while the pool MUST use
        an explicit recorded port (passed in here as the `port` arg).
  pattern: the log path is $POOL_STATE_DIR/chrome-<lane>.log.
  gotcha: none beyond the above.

# This task's own research (REAL-CHROME host-verified — ALL PASSED)
- file: plan/001_0f759fe2777c/P1M4T2S2/research/chrome-launch-host-verified.md
  why: the deep brief on (a) the setsid $!/pgid contract (§1, HOST-VERIFIED pgid==pid==sid); (b)
        the real Chrome end-to-end launch (§2 — 5 children → 0 orphans on group kill); (c) CDP
        /json/version shape + curl -sf exit codes (§3); (d) all 9 anti-throttle flags accepted
        verbatim (§4); (e) THE KEY GOTCHA — ps -o pgid= aborts under set -e on instant death
        (§5); (f) the naming decision POOL_CHROME_PID/PGID (§6); (g) the 15s-vs-30s resolution
        (§7); (h) the timeout-kill semantics (§8); (i) env-var wiring (§9); (j) placement
        (§10); and the paste-ready, host-verified function bodies.
  pattern: §5 (the guard), §8 (the loop), §1 (the contract).
  gotcha: §5 is the one that WILL cause a hard-to-debug abort if missed.

# The LANDED functions/globals this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md   # pool_config_init (M1.T1.S2 — LANDED @126)
  why: freezes POOL_CHROME_BIN (name-or-path; bare name resolved via PATH by setsid/execvp),
        POOL_HEADLESS (bool "1"/"0" from AGENT_CHROME_HEADLESS), POOL_STATE_DIR (absolute).
        This task reads all three. CONTRACT: all are MUTABLE declare -g globals, re-runnable.
  gotcha: POOL_CHROME_BIN/POOL_HEADLESS/POOL_STATE_DIR are the GLOBALS (validated), not the
        env vars AGENT_CHROME_BIN/AGENT_CHROME_HEADLESS/AGENT_BROWSER_POOL_STATE.

- file: plan/001_0f759fe2777c/P1M1.T1.S1/PRP.md   # pool_die / _pool_log (M1.T1.S1 — LANDED)
  why: pool_chrome_launch calls pool_die on bad args / instant death / missing log dir.
        _pool_log is OPTIONAL here (a single "launched Chrome pid=… pgid=… port=…" line is
        nice observability but not required by the contract). Use _pool_log for the launched
        line; keep pool_die messages on stderr (pool_die already prints to stderr).
  gotcha: pool_die EXITS the process (exit 1). pool_wait_cdp must NOT call it (non-fatal).

- file: plan/001_0f759fe2777c/P1M4.T2.S1/PRP.md   # pool_find_free_port (M4.T2.S1 — IMPLEMENTING)
  why: the IMMEDIATE PREDECESSOR in the post-lock boot AND at EOF. pool_find_free_port is
        appended after pool_copy_master (@1253); THIS task appends after pool_find_free_port.
        It produces the `port` arg passed into pool_chrome_launch. CONTRACT: rc 0 → stdout is
        the port; rc 1 → exhausted (M5.T1.S2 handles before ever calling us).
  gotcha: placement — if S1 has not landed yet, append after pool_copy_master; the banner text
        disambiguates either way. Do NOT touch pool_find_free_port or any prior function.

- file: plan/001_0f759fe2777c/P1M4.T1.S1/PRP.md   # pool_copy_master (M4.T1.S1 — LANDED @1253)
  why: the STYLE/STRUCTURE analog — the most recent lifecycle function. It validates its arg is
        absolute (PRD §2.2), pre-checks preconditions, does the work, returns 0 / pool_die.
        Its docstring GOTCHA format + banner style are the template for THIS task. Read it for
        the `[[ "$x" == /* ]] || pool_die` absolute-path guard + the `mkdir -p -- "$parent"`
        defensive-dir pattern (mirrored here for the log dir).
  pattern: arg validation → precondition → work → return 0 / pool_die.
  gotcha: pool_copy_master defensively mkdir -p's the parent; THIS task defensively mkdir -p's
        $POOL_STATE_DIR (the log dir) before the backgrounded redirect.

# External authoritative docs (for the WHY)
- url: https://man7.org/linux/man-pages/man1/setsid.1.html
  why: setsid runs a program in a new session; default (no --fork/-f) calls setsid(2) + execvp
        when the caller is not a pgroup leader → the launched cmd's pid == $! and pgid==pid.
  critical: do NOT add --fork/-f — it would fork and break pgid==pid (research §1).
  section: DESCRIPTION.

- url: https://man7.org/linux/man-pages/man2/setsid.2.html
  why: setsid(2) creates a new session iff the caller is not a process group leader → the new
        session leader's pid==pgid==sid. Explains WHY the host-verified pgid==pid holds.
  section: DESCRIPTION.

- url: https://chromedevtools.github.io/devtools-protocol/
  why: the HTTP endpoint /json/version is the canonical "CDP is ready" probe (returns 200 + JSON
        with Browser/Protocol-Version/webSocketDebuggerUrl once DevTools is bound). THIS task's
        pool_wait_cdp polls exactly that.
  critical: before Chrome binds, the port refuses → curl exit 7 → keep looping.
  section: "HTTP Endpoints" (known-standard anchor).

- url: https://peter.sh/experiments/chromium-command-line-flags/
  why: the authoritative list of Chrome flags; confirms each anti-throttle flag name + that
        --headless=new is the modern headless mode (legacy --headless is deprecated).
  section: (search each flag name).
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.\*, M2.T2.S1, M3.T1.\*, M3.T2.S1–S3, M4.T1.S1** have landed AND
**M4.T2.S1** (`pool_find_free_port`) lands (parallel, treated as CONTRACT), `lib/pool.sh` ends
with `pool_find_free_port` as the final function (appended after `pool_copy_master` @1253–1312):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ~1360 lines after S1 lands:
│                                         #   set -euo pipefail + pool_die/_pool_log (M1.T1.S1)
│                                         #   + _pool_config_*/pool_config_init (M1.T1.S2)  ← POOL_CHROME_BIN/HEADLESS/STATE_DIR frozen
│                                         #   + pool_state_init/pool_check_btrfs/pool_check_master (M1.T1.S3)
│                                         #   + _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str (M1.T2.S1)
│                                         #   + _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve (M2.T1.*)
│                                         #   + pool_owner_alive (M2.T2.S1)
│                                         #   + pool_lease_write/pool_lease_update (M3.T1.S1)
│                                         #   + pool_lease_read/pool_lease_field/pool_lease_exists (M3.T1.S2)
│                                         #   + pool_lanes_list/pool_lease_find_mine/_any (M3.T2.S1)
│                                         #   + pool_find_free_lane (M3.T2.S2)
│                                         #   + pool_lane_is_stale (M3.T2.S3)
│                                         #   + pool_copy_master (M4.T1.S1)  ← @1253–1312
│                                         #   + pool_find_free_port (M4.T2.S1)  ← appended @~1313–1360 = EOF
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M4T2S1/PRP.md
    └── P1M4T2S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/chrome-launch-host-verified.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND two functions under a new banner after the current EOF
                  #   (after pool_find_free_port's closing brace; if S1 unlanded, after
                  #    pool_copy_master — the banner text disambiguates):
                  #   # Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)
                  #   pool_chrome_launch(port, user_data_dir, lane):
                  #       setsid "$POOL_CHROME_BIN" <flags> > "$POOL_STATE_DIR/chrome-<lane>.log" 2>&1 &
                  #       capture POOL_CHROME_PID=$! ; guarded POOL_CHROME_PGID=$(ps -o pgid= …)
                  #       pool_die on bad args / instant death / missing log dir.
                  #   pool_wait_cdp(port):
                  #       60× (curl -sf /json/version || sleep 0.5); rc 0 if ready;
                  #       on timeout kill -- -"$POOL_CHROME_PGID" (if set), return 1.
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**Chrome-bring-up primitives** — the launch + CDP-readiness step of PRD §2.4 step 3g–3h. They
read `POOL_CHROME_BIN`/`POOL_HEADLESS`/`POOL_STATE_DIR`; they are consumed by the acquire
post-lock boot (M5.T1.S2), outside the flock.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (the setsid $!/pgid contract): `setsid CMD &; SP=$!` gives pgid==pid==sid for the
#   launched CMD because util-linux setsid (default, NO --fork) exec's the command after
#   setsid(2) when the caller is not a pgroup leader (true in any non-interactive script).
#   HOST-VERIFIED (research §1). Do NOT add setsid --fork/-f — it would fork and the recorded
#   $! would be the intermediate, breaking pgid==pid (release would then leak orphans).

# CRITICAL (the pgid capture ABORTS under set -e on instant death): `ps -o pgid= -p $PID`
#   returns rc 1 + empty output if the process is already gone (Chrome crashed on a bad port /
#   missing binary / instant exit). A BARE `pg="$(ps -o pgid= -p $PID | tr -d ' ')"` therefore
#   ABORTs the whole pool under `set -euo pipefail`. MUST guard: `|| true` then `[[ -z ]]` →
#   pool_die with the log path. HOST-VERIFIED (research §5). This is the single highest-impact
#   gotcha in this task.

# CRITICAL (kill -- -<pgid> needs the --): the pgid is a positive integer but the arg starts
#   with '-' so `kill` would parse it as a flag without `--`. `kill -- -"$PGID"` signals the
#   whole process group (negative pid). HOST-VERIFIED (research §2: 5 children → 0 orphans).
#   The negative-pid form is the ONLY thing that catches renderer/GPU/utility children.

# CRITICAL (--headless=new, not --headless): the modern headless mode (Chrome 112+); legacy
#   --headless is deprecated. Gated on POOL_HEADLESS=="1" (pool_config_init normalizes
#   AGENT_CHROME_HEADLESS to "1"/"0"). Default (unset) = WINDOWED per PRD §2.6 (trusted profiles
#   must look real; headless is detectable). HOST-VERIFIED (research §4).

# CRITICAL (the log redirect MUST have an existing dir): `setsid … > "$log_file" 2>&1 &` fails
#   to OPEN the redirect if $log_file's dir does not exist; the backgrounded job then exits
#   immediately and $! is a pid that's already gone (tripping the §5 guard). Defensively
#   `mkdir -p -- "$POOL_STATE_DIR"` first (pool_state_init already does this via mkdir -p of the
#   lanes subdir, but be robust like pool_copy_master's mkdir -p of the parent).

# CRITICAL (POOL_CHROME_PID/POOL_CHROME_PGID naming — codebase convention): every global in
#   lib/pool.sh is POOL_*; pool_owner_resolve sets POOL_OWNER_PID etc. via declare -g. So export
#   POOL_CHROME_PID + POOL_CHROME_PGID (NOT the contract's bare CHROME_PID/CHROME_PGID, which is
#   shorthand). The consumer M5.T1.S2 reads these names → writes lease chrome_pid/chrome_pgid.
#   (research §6).

# GOTCHA (pool_wait_cdp is NON-FATAL): timeout → return 1, NOT pool_die. The caller (M5.T1.S2)
#   owns the PRD §2.14 "retry launch once; then fail, drop lane" policy. Same non-fatal family
#   as pool_find_free_port. Callers MUST guard under set -e: `if pool_wait_cdp "$port"; then …`.

# GOTCHA (the 15s-vs-30s conflict — resolved to 30s): PRD §2.4 step 3h + §2.14 say 15s but
#   CONTRACT 3b + external_deps §2.2 say 60×0.5s=30s. Implement 60×0.5s=30s (the contract's
#   explicit LOGIC step + the impl reference agree); the budget is ONE named local constant so
#   it is trivially tunable. (research §7).

# GOTCHA (flag-checks in tests need `grep -F --`): each flag starts with '-', so `grep -qF
#   "$f"` is mis-parsed as a grep option. Use `grep -qF -- "$f"` (the `--` ends option parsing).

# GOTCHA (naming): pool_chrome_launch + pool_wait_cdp — the CONTRACT body literally says
#   "Implement pool_chrome_launch(...)" and "pool_wait_cdp(port)". Do NOT rename.

# GOTCHA (placement): APPEND at EOF (after pool_find_free_port, the S1 deliverable). Do NOT
#   touch any existing function. This task only READS POOL_CHROME_BIN/POOL_HEADLESS/POOL_STATE_DIR.

# GOTCHA (scope): this task is launch + CDP-readiness ONLY. Do NOT: pick the port (M4.T2.S1 —
#   the `port` arg is passed in); connect the daemon (M4.T3.S1); take/release the flock
#   (M5.T1.S1); update the lease's chrome_pid/chrome_pgid (M5.T1.S2 — the caller reads our
#   globals and writes the lease); acquire/release/reap (M5); or formalize a reusable
#   pool_kill_chrome_pgroup helper (M4.T3.S1 — the timeout-kill is INLINED here, guarded).
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout** and **no new env vars**. It defines TWO functions
and exports TWO globals. It reads three frozen globals and one arg triple; it writes the
Chrome log file (`$POOL_STATE_DIR/chrome-<lane>.log`) and nothing else.

Globals READ (all frozen by `pool_config_init`, M1.T1.S2):

| global | source env var | example | role |
|---|---|---|---|
| `POOL_CHROME_BIN` | `AGENT_CHROME_BIN` | `google-chrome-stable` | the binary setsid execs (name → PATH lookup; path → absolute) |
| `POOL_HEADLESS` | `AGENT_CHROME_HEADLESS` | `0` (unset) / `1` | add `--headless=new` iff `=="1"` |
| `POOL_STATE_DIR` | `AGENT_BROWSER_POOL_STATE` | `…/agent-browser-pool` | log = `$POOL_STATE_DIR/chrome-<lane>.log` |

Globals EXPORTED (via `declare -g`, codebase convention — research §6):

| global | set by | example | consumed by |
|---|---|---|---|
| `POOL_CHROME_PID` | `pool_chrome_launch` | `2031215` | `pool_wait_cdp` (timeout-kill fallback); M5.T1.S2 (lease `chrome_pid`) |
| `POOL_CHROME_PGID` | `pool_chrome_launch` | `2031215` (== pid) | `pool_wait_cdp` (timeout-kill); M5.T2.S1 release (`kill -- -<pgid>`) |

External commands (verified present, external_deps §4): `setsid` (`/usr/bin/setsid`, util-linux
2.42.2), `ps` (`ps -o pgid= -p <pid>`), `curl` (`curl -sf http://127.0.0.1:<port>/json/version`),
`kill` (builtin), `sleep` (builtin/utility). `google-chrome-stable` (`/usr/bin/google-chrome-stable`,
verified Chrome 149).

**Naming** (CONTRACT-mandated, exact): `pool_chrome_launch`, `pool_wait_cdp`. No `_` prefix —
they are public entry points (mirrors `pool_copy_master`). Internal-only in practice (sole
consumer M5.T1.S2).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_state_init pool_die _pool_log pool_copy_master'
  - EXPECT: all five reported as functions. (pool_config_init is M1.T1.S2 LANDED @126; pool_state_init
        is M1.T1.S3 LANDED @202; pool_die/_pool_log are M1.T1.S1 LANDED @30/@39; pool_copy_master is
        M4.T1.S1 LANDED @1253.) If any is MISSING, STOP — this task depends on them.
  - RUN (sanity-check the three globals this task reads):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_CHROME_BIN" ]] && echo "OK POOL_CHROME_BIN=$POOL_CHROME_BIN" || echo FAIL; \
                 [[ "$POOL_HEADLESS" =~ ^[01]$ ]] && echo "OK POOL_HEADLESS=$POOL_HEADLESS" || echo FAIL; \
                 [[ "$POOL_STATE_DIR" == /* ]] && echo "OK POOL_STATE_DIR=$POOL_STATE_DIR" || echo FAIL'
        # EXPECT: OK POOL_CHROME_BIN=google-chrome-stable ; OK POOL_HEADLESS=0 ; OK POOL_STATE_DIR=<abs>.
  - RUN (verify the external commands this task shells out to):
        command -v setsid >/dev/null && echo "OK setsid present" || echo FAIL
        command -v ps >/dev/null && echo "OK ps present" || echo FAIL
        command -v curl >/dev/null && echo "OK curl present" || echo FAIL
        command -v google-chrome-stable >/dev/null && echo "OK chrome present" || echo FAIL
        # EXPECT: all OK.
  - RUN (host-verify the setsid $!/pgid contract ONCE before coding — research §1):
        bash -c 'set -euo pipefail; setsid sleep 5 & SP=$!; \
                 PGID="$(ps -o pgid= -p "$SP" | tr -d " ")"; \
                 [[ "$PGID" == "$SP" ]] && echo "OK setsid pgid==pid ($SP)" || echo "FAIL pgid=$PGID pid=$SP"; \
                 kill -- -"$PGID" 2>/dev/null || true'
        # EXPECT: OK setsid pgid==pid (<pid>). If this FAILs, the host's setsid forks — STOP and
        #   consult research §1 (do NOT proceed; the whole teardown contract depends on pgid==pid).
  - RUN (locate the append point — current EOF):
        tail -5 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        grep -nE '^(pool_find_free_port|pool_copy_master)\(\)' lib/pool.sh
  - EXPECT: the last function is EITHER pool_find_free_port (S1 landed) OR pool_copy_master (S1
        not yet landed). APPEND the new banner + two functions AFTER whichever is last. Do NOT
        touch any existing function.
  - RUN (file is otherwise clean): bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_chrome_launch() + pool_wait_cdp() to lib/pool.sh (the two functions)
  - PLACEMENT: after a new banner, directly below the last function at EOF (pool_find_free_port
        if S1 landed, else pool_copy_master).
  - IMPLEMENT (verbatim-ready — paste this block):
        # =============================================================================
        # Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)
        # =============================================================================
        # Launch one pooled Chrome as its own process-group leader (pgid==pid via setsid) on a
        # chosen port + ephemeral profile dir, then wait for its CDP endpoint to answer. Implements
        # PRD §2.6 (Chrome launch per lane — the EXACT flag list) + §2.4 step 3g (LAUNCH setsid …;
        # record chrome_pid + pgid) + 3h (WAIT for CDP /json/version). Consumed by the acquire
        # POST-LOCK boot (M5.T1.S2: copy → find_free_port → launch → wait_cdp → connect → update
        # lease), OUTSIDE the flock critical section (key_findings FINDING 2 — concurrent boots).

        # pool_chrome_launch PORT USER_DATA_DIR LANE
        #
        # Launch Chrome (via setsid, so pgid==pid) on PORT with USER_DATA_DIR, writing combined
        # stdout/stderr to $POOL_STATE_DIR/chrome-<LANE>.log. Exports globals POOL_CHROME_PID and
        # POOL_CHROME_PGID (== POOL_CHROME_PID — the setsid contract; release does kill -- -<pgid>).
        # Returns 0 on success; pool_die on bad args / instant Chrome death / missing log dir.
        #
        # LOGIC (CONTRACT 3a):
        #   - flag list: --remote-debugging-port=<port> --user-data-dir=<ABSOLUTE udd>
        #     --no-first-run --no-default-browser-check --disable-background-timer-throttling
        #     --disable-backgrounding-occluded-windows --disable-renderer-backgrounding
        #     --disable-features=CalculateNativeWinOcclusion --disable-back-forward-cache
        #     ( + --headless=new iff POOL_HEADLESS==1 )
        #   - log file: $POOL_STATE_DIR/chrome-<lane>.log
        #   - launch: setsid "$POOL_CHROME_BIN" <flags> > "$log" 2>&1 &
        #   - capture POOL_CHROME_PID=$!
        #   - POOL_CHROME_PGID=$(ps -o pgid= -p $PID | tr -d ' ')  (GUARDED — see GOTCHA)
        #   - export both as globals (declare -g).
        #
        # CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → Chrome is launched + the two
        #   globals are set (pgid==pid); any failure exits the process via pool_die. The caller then
        #   calls pool_wait_cdp <port>, then reads POOL_CHROME_PID/POOL_CHROME_PGID into the lease.
        #
        # GOTCHA — setsid $!/pgid contract (HOST-VERIFIED, research §1): `setsid CMD &; SP=$!`
        #   gives pgid==pid==sid for CMD because util-linux setsid (default, NO --fork) exec's the
        #   command after setsid(2) when the caller is not a pgroup leader. Do NOT add --fork/-f
        #   (it would fork and break pgid==pid → release would leak orphans).
        # GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
        #   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
        #   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
        #   `[[ -z ]]` check → pool_die with the log path. Highest-impact gotcha in this task.
        # GOTCHA — the log redirect needs an existing dir: `> "$log" 2>&1 &` fails to open if the
        #   dir is missing → the job exits instantly → trips the §5 guard. Defensively mkdir -p
        #   $POOL_STATE_DIR first (pool_state_init already does this, but be robust).
        # GOTCHA — POOL_CHROME_BIN may be a bare name (resolved via PATH by setsid/execvp) or an
        #   absolute path (canonicalized by pool_config_init). Both work — pass it quoted.
        # GOTCHA — NO bare ~ (PRD §2.2): USER_DATA_DIR is validated ABSOLUTE before launch.
        # GOTCHA — POOL_CHROME_PID/POOL_CHROME_PGID naming follows the codebase POOL_* convention
        #   (every global is POOL_*; pool_owner_resolve sets POOL_OWNER_PID). The contract's bare
        #   CHROME_PID/CHROME_PGID is shorthand. (research §6)
        # Reads ONLY POOL_CHROME_BIN + POOL_HEADLESS + POOL_STATE_DIR (frozen by pool_config_init).
        # Writes only the Chrome log. No new env-vars/files.
        # PRECONDITION: pool_config_init (for the three globals).
        pool_chrome_launch() {
            local port="${1:-}"
            local user_data_dir="${2:-}"
            local lane="${3:-}"
            local log_file flags pgid

            # Validate args. All `[[ ]] || pool_die` are errexit-exempt.
            [[ "$port" =~ ^[0-9]+$ ]] \
                || pool_die "pool_chrome_launch: port must be a non-negative integer, got: '${port:-<unset>}'"
            [[ -n "$user_data_dir" ]] \
                || pool_die "pool_chrome_launch: user_data_dir is empty"
            [[ "$user_data_dir" == /* ]] \
                || pool_die "pool_chrome_launch: user_data_dir must be ABSOLUTE (PRD §2.2): $user_data_dir"
            [[ "$lane" =~ ^[0-9]+$ ]] \
                || pool_die "pool_chrome_launch: lane must be a non-negative integer, got: '${lane:-<unset>}'"
            [[ -n "$POOL_CHROME_BIN" ]] \
                || pool_die "pool_chrome_launch: POOL_CHROME_BIN is empty (run pool_config_init first)"

            # Ensure the log dir exists so the backgrounded redirect can open the log file.
            # pool_state_init already mkdir -p's the lanes subdir (a child of POOL_STATE_DIR), but
            # be robust: this function may be called in a test that skipped pool_state_init.
            mkdir -p -- "$POOL_STATE_DIR" \
                || pool_die "pool_chrome_launch: cannot create log dir: $POOL_STATE_DIR"
            log_file="$POOL_STATE_DIR/chrome-$lane.log"

            # Build the flag list (array — survives any future arg with spaces; no word-splitting).
            flags=(
                --remote-debugging-port="$port"
                --user-data-dir="$user_data_dir"
                --no-first-run
                --no-default-browser-check
                --disable-background-timer-throttling
                --disable-backgrounding-occluded-windows
                --disable-renderer-backgrounding
                --disable-features=CalculateNativeWinOcclusion
                --disable-back-forward-cache
            )
            [[ "$POOL_HEADLESS" == "1" ]] && flags+=(--headless=new)

            # Launch: setsid makes Chrome its own session/group leader (pgid==pid). The redirection
            # captures Chrome's combined stdout/stderr to the per-lane log. `&` backgrounds it; $!
            # is Chrome's pid (setsid exec'd it — research §1). Backgrounding is errexit-exempt.
            setsid -- "$POOL_CHROME_BIN" "${flags[@]}" >"$log_file" 2>&1 &
            POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID

            # Capture the process-group id. GUARDED (research §5): `ps -o pgid= -p $PID` returns
            # rc 1 + empty if Chrome already died (instant exit). A bare $(…) would ABORT under
            # set -e; `|| true` keeps us alive, then `[[ -z ]]` converts "already dead" into a
            # clean pool_die with the log path so the operator can read Chrome's stderr.
            pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
            if [[ -z "$pgid" ]]; then
                # Chrome died before we could read its pgroup. Best-effort reap of the bare pid,
                # then die with the log path (Chrome's stderr is in there).
                kill "$POOL_CHROME_PID" 2>/dev/null || true
                pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                         "see log: $log_file"
            fi
            POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID

            # Observability: one line. _pool_log writes ISO-8601 + msg to the pool log + stderr.
            # (Best-effort: _pool_log never fails the caller — it falls back to stderr.)
            _pool_log "pool_chrome_launch: lane=$lane port=$port pid=$POOL_CHROME_PID pgid=$POOL_CHROME_PGID headless=$POOL_HEADLESS"

            return 0
        }

        # pool_wait_cdp PORT
        #
        # Poll Chrome's CDP HTTP endpoint (http://127.0.0.1:<PORT>/json/version) until it answers
        # (HTTP 200 → curl -sf exits 0) or the budget is exhausted. Returns 0 if CDP is ready;
        # returns 1 on timeout AFTER killing the Chrome process group (so a half-booted Chrome
        # does not leak). NON-FATAL: never pool_die — the caller (M5.T1.S2) owns the PRD §2.14
        # "retry launch once; then fail, drop lane" policy.
        #
        # LOGIC (CONTRACT 3b):
        #   - loop up to 60 times (30s total): curl -sf http://127.0.0.1:<port>/json/version
        #   - return 0 if CDP responds (curl rc 0)
        #   - on timeout: kill -- -<POOL_CHROME_PGID> (if set + numeric), then return 1.
        #
        # CONSUMER: M5.T1.S2 acquire post-lock boot, called immediately after pool_chrome_launch.
        #   CONTRACT: rc 0 → Chrome's CDP is ready, proceed to connect (M4.T3.S1); rc 1 → timed
        #   out, Chrome pgroup already killed here, caller retries launch once then drops the lane.
        #   Caller MUST guard under set -e: `if pool_wait_cdp "$port"; then …; else <retry path>; fi`.
        #
        # GOTCHA — 60×0.5s=30s (research §7): CONTRACT 3b ("Loop up to 60 times (30s total)") +
        #   external_deps §2.2 (`seq 1 60`) agree; PRD §2.4 step 3h / §2.14 "15s" is a stale
        #   summary. We use a bash (( )) counter (no seq fork). The budget is ONE named constant.
        # GOTCHA — curl -sf exit codes: connection-refused (Chrome still booting) = rc 7 → keep
        #   looping; HTTP 200 = rc 0 → ready. No --max-time needed (refused is instant); the bare
        #   `curl -sf` matches external_deps §2.2 exactly.
        # GOTCHA — kill -- -<pgid> needs the `--` (pgid is a positive int but the arg starts with
        #   '-'). Guarded by a numeric check so pool_wait_cdp is safe to call standalone in tests
        #   (no prior launch → POOL_CHROME_PGID unset → skip the kill, just return 1).
        # GOTCHA — NON-FATAL (return 1, NOT pool_die): same family as pool_find_free_port.
        # Reads only $1 (port) + the global POOL_CHROME_PGID (set by pool_chrome_launch). No writes
        # beyond the process-group signal.
        # PRECONDITION: pool_chrome_launch (for POOL_CHROME_PGID) when used in the real boot; none
        #   required for a standalone timeout test (the pgid guard makes it safe).
        # shellcheck disable=SC2034 # POOL_CDP_TRIES is the single tunable budget.
        pool_wait_cdp() {
            local port="${1:-}"
            local i
            local -ri POOL_CDP_TRIES=60    # ×0.5s sleep = 30s budget (research §7; tunable)

            [[ "$port" =~ ^[0-9]+$ ]] || return 1   # bad port → non-fatal rc 1 (defensive)

            for (( i = 0; i < POOL_CDP_TRIES; i++ )); do
                if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
                    return 0
                fi
                sleep 0.5
            done

            # Timeout — tear down the process group so a half-booted Chrome does not leak.
            # The numeric guard makes this safe when called without a prior pool_chrome_launch.
            if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then
                kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true
            fi
            return 1
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155); arg validation via
        `[[ ]] || pool_die` (errexit-exempt, same as pool_copy_master); `mkdir -p -- "$dir" ||
        pool_die` (pool_copy_master's defensive-dir pattern); `local -ri` for the tunable
        constant; `setsid -- … &` (the `--` guards against a POOL_CHROME_BIN that could be
        mistaken for a setsid flag — though it won't be, defensive); array expansion
        `"${flags[@]}"` (no word-splitting); `2>/dev/null`/`2>&1` on ps+curl (never flood
        stderr); guarded pgid capture (`|| true` + `[[ -z ]]`).
  - NAMING: pool_chrome_launch + pool_wait_cdp (CONTRACT-mandated; do NOT rename).
  - PLACEMENT: the only two functions in the new "(P1.M4.T2.S2)" banner.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_chrome_launch pool_wait_cdp' >/dev/null && echo OK
        # EXPECT: OK.
  # NOTE: pool_wait_cdp returns 1 on TIMEOUT (never pool_die), so it never exits the process —
  # but the calling shell's set -e means a BARE `pool_wait_cdp "$port"` whose rc is 1 ABORTs the
  # caller. Use `if pool_wait_cdp "$port"; then …` in real code. In the tests below, the
  # `bash -c` invocations that assert rc 1 use an explicit `if … else …` guard.
  #
  # --- SCENARIO 1: REAL Chrome end-to-end (headless) — launch + globals + CDP ready + flags + teardown
  - RUN (the headline integration test — launches REAL headless Chrome on a free port):
        STATE="$(mktemp -d)"; UDD="$(mktemp -d)/lane-3"
        PORT=55557   # a port above the pool range to avoid colliding with any pool test traffic
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_BIN=google-chrome-stable AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_launch "'"$PORT"'" "'"$UDD"'" 3
                  echo "PID=$POOL_CHROME_PID PGID=$POOL_CHROME_PGID"
                  [[ -n "$POOL_CHROME_PID" && "$POOL_CHROME_PGID" == "$POOL_CHROME_PID" ]] && echo OK1-globals || echo FAIL1-globals'
        # EXPECT: PID=<n> PGID=<same n> ; OK1-globals.   (the setsid pgid==pid contract, HOST-VERIFIED.)
  - RUN (CDP becomes ready within 30s → pool_wait_cdp rc 0):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  if pool_wait_cdp "'"$PORT"'"; then echo OK2-cdp-ready; else echo FAIL2-cdp; fi'
        # EXPECT: OK2-cdp-ready.   (host-observed ~0.5s.)
  - RUN (all 9 flags present in /proc/<pid>/cmdline — NOTE the `grep -F --`):
        PID="$(AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  # relaunch to get a fresh pid we control (the prior one is still up from S1)
                  pool_chrome_launch "'"$PORT"'" "'"$UDD"'" 3 >/dev/null; echo "$POOL_CHROME_PID"')"
        CMDLINE="$(tr "\0" "\n" < /proc/$PID/cmdline 2>/dev/null)"
        for f in --remote-debugging-port --user-data-dir --no-first-run --no-default-browser-check \
                 --disable-background-timer-throttling --disable-backgrounding-occluded-windows \
                 --disable-renderer-backgrounding --disable-back-forward-cache --headless=new; do
            grep -qF -- "$f" <<<"$CMDLINE" && echo "  PRESENT: $f" || echo "  MISSING: $f"
        done
        grep -qF -- "--disable-features=CalculateNativeWinOcclusion" <<<"$CMDLINE" \
            && echo OK-features-value || echo FAIL-features-value
        # EXPECT: all PRESENT + OK-features-value.
        # clean up this Chrome via the pgroup (proves teardown leaves 0 orphans):
        PGID="$(ps -o pgid= -p "$PID" | tr -d ' ')"
        PRE=$(pgrep -c -P "$PID" 2>/dev/null || echo 0); echo "children before kill: $PRE"
        kill -- -"$PGID" 2>/dev/null; sleep 1
        kill -0 "$PID" 2>/dev/null && echo "FAIL still alive" || echo OK3-dead
        POST=$(pgrep -P "$PID" 2>/dev/null | wc -l); echo "orphaned children: $POST"
        # EXPECT: children before kill: >=1 ; OK3-dead ; orphaned children: 0.
  - RUN (log file was written):
        test -s "$STATE/chrome-3.log" && echo OK4-log || echo FAIL4-log
        grep -q "DevTools listening" "$STATE/chrome-3.log" && echo OK4-log-devtools || echo "(headless may not print this line — OK4-log alone is sufficient)"
        # EXPECT: OK4-log (non-empty). The DevTools line is best-effort.
  #
  # --- SCENARIO 2: pool_wait_cdp TIMEOUT — returns 1 + kills the pgroup
  - RUN (stand-in: a `setsid sleep` pgroup that NEVER listens on the probed port):
        # give pool_wait_cdp a fake-but-real pgroup to kill, and a dead port, then assert rc 1 + kill.
        setsid sleep 300 & SP=$!; SPGID="$(ps -o pgid= -p "$SP" | tr -d ' ')"
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  POOL_CHROME_PGID="'"$SPGID"'"'
        # NOTE: globals set inside a `bash -c` don't persist to the next invocation, so do it inline:
        AGENT_BROWSER_POOL_STATE="$STATE" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  POOL_CHROME_PGID="'"$SPGID"'"
                  if pool_wait_cdp 55598; then echo FAIL5-ready; else echo OK5-timeout-rc1; fi'
        # EXPECT: OK5-timeout-rc1.   (55598 has no listener; ~30s wait — this is the slow test.)
        # assert the stand-in pgroup was killed by pool_wait_cdp's timeout path:
        kill -0 "$SP" 2>/dev/null && echo "FAIL5-still-alive" || echo OK5-pgroup-killed
        # EXPECT: OK5-pgroup-killed.   (proves kill -- -<POOL_CHROME_PGID> fired on timeout.)
  #
  # --- SCENARIO 3: instant-death guard — pool_chrome_launch pool_dies (does NOT abort via bare $())
  - RUN (point at a non-existent binary → Chrome can't start → guarded pool_die, rc != 0):
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_BIN=/no/such/chrome AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_launch '"$PORT"' "'"$UDD"'" 3
                  echo UNREACHED' >/tmp/s3.out 2>&1; rc=$?
        echo "instant-death exit=$rc"; cat /tmp/s3.out
        # EXPECT: exit != 0 and "exited immediately" in the output (the §5 guard fired, NOT a
        #   bare-$(…) set -e abort — the message proves we reached the `[[ -z ]]` branch).
  #
  # --- SCENARIO 4: windowed default (no --headless) when POOL_HEADLESS != 1
  - RUN (AGENTS_CHROME_HEADLESS unset → POOL_HEADLESS=0 → no --headless in flags):
        # NOTE: launching WINDOWED Chrome pops a real window on the desktop. To avoid that in CI,
        #   this scenario only ASSERTS the flag-construction logic via a DRY-RUN: temporarily set
        #   POOL_CHROME_BIN to `true` (which setsid exec's; it "exits immediately" → trips the §5
        #   guard, but we can still inspect that --headless was NOT added by checking the die path).
        #   The authoritative windowed check is manual: run Scenario 1 WITHOUT AGENT_CHROME_HEADLESS
        #   and grep /proc/<pid>/cmdline for `--headless` (expect absent). Document this in the
        #   validation log. (Automated: skipped to avoid popping a window in headless CI.)
        echo "SCENARIO 4 (windowed default): MANUAL — re-run Scenario 1 with AGENT_CHROME_HEADLESS unset; expect no --headless in cmdline."
  #
  # --- SCENARIO 5: bad-arg validation (each pool_dies before launching)
  - RUN (non-numeric port):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_launch notaport "'"$UDD"'" 3' 2>&1 | grep -q "port must be" && echo OK6-port || echo FAIL6
  - RUN (relative user_data_dir):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_launch '"$PORT"' relative/dir 3' 2>&1 | grep -q "must be ABSOLUTE" && echo OK7-udd || echo FAIL7
  - RUN (non-numeric lane):
        AGENT_BROWSER_POOL_STATE="$STATE" bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
                  pool_chrome_launch '"$PORT"' "'"$UDD"'" abc' 2>&1 | grep -q "lane must be" && echo OK8-lane || echo FAIL8
        # EXPECT: OK6-port ; OK7-udd ; OK8-lane.
  #
  # --- SCENARIO 6: composes the right pieces (body content checks)
  - RUN:
        body_l="$(sed -n "/^pool_chrome_launch() {/,/^}/p" lib/pool.sh)"
        body_w="$(sed -n "/^pool_wait_cdp() {/,/^}/p" lib/pool.sh)"
        grep -q 'setsid -- "\$POOL_CHROME_BIN"' <<<"$body_l" && echo OK-setsid || echo FAIL
        grep -q 'POOL_CHROME_PID=\$!; declare -g POOL_CHROME_PID' <<<"$body_l" && echo OK-pid || echo FAIL
        grep -q 'ps -o pgid= -p "\$POOL_CHROME_PID" 2>/dev/null' <<<"$body_l" && echo OK-pgid-capture || echo FAIL
        grep -q '|| true' <<<"$body_l" && echo OK-guard-true || echo FAIL
        grep -q 'pool_die "pool_chrome_launch: Chrome (pid' <<<"$body_l" && echo OK-instant-death || echo FAIL
        grep -q -- "--disable-features=CalculateNativeWinOcclusion" <<<"$body_l" && echo OK-features || echo FAIL
        grep -q -- "--headless=new" <<<"$body_l" && echo OK-headless || echo FAIL
        grep -q 'kill -- -"\$POOL_CHROME_PGID"' <<<"$body_w" && echo OK-wait-kill || echo FAIL
        grep -q "POOL_CDP_TRIES=60" <<<"$body_w" && echo OK-budget || echo FAIL
        grep -q "return 1" <<<"$body_w" && echo OK-wait-rc1 || echo FAIL
        grep -q "pool_die" <<<"$body_w" && echo FAIL-wait-dies || echo OK-wait-nofatal
        # EXPECT: all OK / no-FAIL lines.
  - RUN (regression: all prior + new functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      pool_check_btrfs pool_check_master \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime pool_owner_resolve pool_owner_alive \
                      pool_lease_write pool_lease_update \
                      pool_lease_read pool_lease_field pool_lease_exists \
                      pool_lanes_list pool_lease_find_mine pool_lease_find_mine_any \
                      pool_find_free_lane pool_lane_is_stale pool_copy_master \
                      pool_find_free_port pool_chrome_launch pool_wait_cdp >/dev/null && echo OK'
        # EXPECT: OK (all functions, incl. pool_find_free_port if S1 landed, + the two new ones).
  - RUN (cleanup test artifacts — kill any stray Chrome from Scenario 1's first launch):
        pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
        rm -rf "$STATE" "$(dirname "$UDD")" /tmp/s3.out
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: pool_chrome_launch (paste under the new banner after pool_find_free_port) -----

pool_chrome_launch() {
    local port="${1:-}"
    local user_data_dir="${2:-}"
    local lane="${3:-}"
    local log_file flags pgid

    # arg validation (errexit-exempt `[[ ]] || pool_die`)
    [[ "$port"        =~ ^[0-9]+$ ]] || pool_die "pool_chrome_launch: port must be a non-negative integer, got: '${port:-<unset>}'"
    [[ -n "$user_data_dir"         ]] || pool_die "pool_chrome_launch: user_data_dir is empty"
    [[ "$user_data_dir" == /*      ]] || pool_die "pool_chrome_launch: user_data_dir must be ABSOLUTE (PRD §2.2): $user_data_dir"
    [[ "$lane"        =~ ^[0-9]+$ ]] || pool_die "pool_chrome_launch: lane must be a non-negative integer, got: '${lane:-<unset>}'"
    [[ -n "$POOL_CHROME_BIN"       ]] || pool_die "pool_chrome_launch: POOL_CHROME_BIN is empty (run pool_config_init first)"

    # ensure the log dir exists (pool_state_init already does this; be robust)
    mkdir -p -- "$POOL_STATE_DIR" || pool_die "pool_chrome_launch: cannot create log dir: $POOL_STATE_DIR"
    log_file="$POOL_STATE_DIR/chrome-$lane.log"

    # flag array (no word-splitting; survives future args with spaces)
    flags=(
        --remote-debugging-port="$port"
        --user-data-dir="$user_data_dir"
        --no-first-run --no-default-browser-check
        --disable-background-timer-throttling
        --disable-backgrounding-occluded-windows
        --disable-renderer-backgrounding
        --disable-features=CalculateNativeWinOcclusion
        --disable-back-forward-cache
    )
    [[ "$POOL_HEADLESS" == "1" ]] && flags+=(--headless=new)

    # launch: setsid exec's chrome (pgid==pid); & backgrounds; $! is chrome's pid
    setsid -- "$POOL_CHROME_BIN" "${flags[@]}" >"$log_file" 2>&1 &
    POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID

    # GUARDED pgid capture (research §5): a bare $(…) ABORTs under set -e if chrome is already dead
    pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
    if [[ -z "$pgid" ]]; then
        kill "$POOL_CHROME_PID" 2>/dev/null || true
        pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately; see log: $log_file"
    fi
    POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID

    _pool_log "pool_chrome_launch: lane=$lane port=$port pid=$POOL_CHROME_PID pgid=$POOL_CHROME_PGID headless=$POOL_HEADLESS"
    return 0
}

# --- Pattern: pool_wait_cdp ----------------------------------------------------------------

pool_wait_cdp() {
    local port="${1:-}"
    local i
    local -ri POOL_CDP_TRIES=60    # ×0.5s = 30s budget (research §7; tunable)

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    for (( i = 0; i < POOL_CDP_TRIES; i++ )); do
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    # timeout — kill the pgroup (guarded so standalone tests without a launch are safe)
    if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then
        kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true
    fi
    return 1
}

# --- Critical micro-rules baked into the above --------------------------------
#  * setsid exec's the command (default, NO --fork) → $! is chrome's pid AND pgid==pid==sid.
#    HOST-VERIFIED. Do NOT add --fork (breaks the invariant).
#  * GUARD the `ps -o pgid=` capture (research §5): bare $(…) aborts under set -e on instant
#    death. `|| true` + `[[ -z ]]` → pool_die with the log path. HIGHEST-IMPACT gotcha.
#  * kill -- -<pgid> needs `--` (pgid is positive but the arg starts with '-'). Negative pid =
#    signal the whole group. HOST-VERIFIED: 5 children → 0 orphans.
#  * --headless=new (modern; legacy --headless deprecated). Gated on POOL_HEADLESS=="1".
#    Default = WINDOWED (PRD §2.6).
#  * pool_wait_cdp is NON-FATAL (return 1, never pool_die). Caller guards under set -e.
#  * 60×0.5s=30s budget (research §7). Single named constant (local -ri POOL_CDP_TRIES).
#  * mkdir -p $POOL_STATE_DIR before the redirect so the backgrounded job can open the log.
#  * No bare ~ (PRD §2.2): user_data_dir validated absolute before launch.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — LANDED in lib/pool.sh):
  - pool_config_init() (M1.T1.S2 @126): freezes POOL_CHROME_BIN (name-or-path), POOL_HEADLESS
        (bool "1"/"0" from AGENT_CHROME_HEADLESS), POOL_STATE_DIR (absolute). THIS task reads
        all three.
  - pool_state_init() (M1.T1.S3 @202): mkdir -p's POOL_LANES_DIR (a child of POOL_STATE_DIR) →
        POOL_STATE_DIR exists after it runs. THIS task also mkdir -p's POOL_STATE_DIR defensively.
  - pool_die() / _pool_log() (M1.T1.S1 @30/@39): pool_chrome_launch calls pool_die on failure;
        both functions call _pool_log for the observability line.

CALLER (future — M5.T1.S2 acquire post-lock boot, NOT built here):
  - After the flock critical section writes the provisional claim and releases the lock
    (key_findings FINDING 2: keep flock short), M5.T1.S2 runs:
        pool_copy_master "$POOL_EPHEMERAL_ROOT/$N"                 # M4.T1.S1
        port="$(pool_find_free_port)" || <M5.T4 exhaustion flow>   # M4.T2.S1 (guarded)
        pool_chrome_launch "$port" "$POOL_EPHEMERAL_ROOT/$N" "$N"  # THIS task
        if pool_wait_cdp "$port"; then                             # THIS task
            # connect daemon (M4.T3.S1)
            pool_lease_update "$N" chrome_pid  "$POOL_CHROME_PID"  # M3.T1.S1
            pool_lease_update "$N" chrome_pgid "$POOL_CHROME_PGID"
            pool_lease_update "$N" port "$port"
        else
            # PRD §2.14: retry launch once; then fail, drop lane (M5.T4/M5.T2.S1)
        fi
    THIS task's globals (POOL_CHROME_PID/POOL_CHROME_PGID) are how M5.T1.S2 fills the lease's
    chrome_pid/chrome_pgid (external_deps §6 schema) and how M5.T2.S1 release does
    `kill -- -<chrome_pgid>`.

ENV VARS (all already wired by pool_config_init; NONE new in this task):
  - AGENT_CHROME_BIN      → POOL_CHROME_BIN   (google-chrome-stable; the binary setsid execs)
  - AGENT_CHROME_HEADLESS → POOL_HEADLESS     (unset=0/windowed; 1=headless → --headless=new)
  - AGENT_BROWSER_POOL_STATE → POOL_STATE_DIR (log = $POOL_STATE_DIR/chrome-<lane>.log)

NO DATABASE / NO ROUTES / NO CONFIG-FILE CHANGES. This is a pure library append.
```

## Validation Loop

> This is a bash library. There is no test harness yet (bats arrives in M9.T1.S1), so each
> level uses inline scenario scripts against the real `lib/pool.sh`. **This task can (and
> should) launch REAL Chrome** for the headline test — the host has `google-chrome-stable`
> (Chrome 149) and the full flag set was host-verified accepted. Use `AGENT_CHROME_HEADLESS=1`
> in automated runs to avoid popping windows. `pool_wait_cdp` returns 1 on timeout (never
> `pool_die`), so — like pool_find_free_port — the timeout assertion uses an explicit
> `if … else …` guard rather than a bare call.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh                  # parse check — MUST be clean
shellcheck lib/pool.sh               # lint the WHOLE file — zero warnings
# Expected: both clean. If shellcheck flags the new functions, READ the wiki:
#   SC2155 = declare local separately from assignment (we do); SC2086 = quote vars (we do);
#   SC2310/SC2312 = set -e in $(…) — the pgid capture is INTENTIONALLY guarded with `|| true`.
```

### Level 2: Unit / Scenario Tests (Component Validation — see Task 2 for the full set)

```bash
# Headline: REAL headless Chrome launch → globals set (pgid==pid) → CDP ready → teardown 0 orphans.
STATE="$(mktemp -d)"; UDD="$(mktemp -d)/lane-3"; PORT=55557
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_BIN=google-chrome-stable AGENT_CHROME_HEADLESS=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           pool_chrome_launch "'"$PORT"'" "'"$UDD"'" 3
           [[ -n "$POOL_CHROME_PID" && "$POOL_CHROME_PGID" == "$POOL_CHROME_PID" ]] && echo "OK globals pgid==pid" || echo FAIL'
AGENT_BROWSER_POOL_STATE="$STATE" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           if pool_wait_cdp "'"$PORT"'"; then echo "OK cdp ready"; else echo "FAIL cdp"; fi'
# Expected: OK globals pgid==pid ; OK cdp ready. (Then teardown via kill -- -<pgid> + 0 orphans;
#   all 9 flags in /proc/<pid>/cmdline — see Task 2 Scenario 1 for the full assertion block.)

# Timeout: stand-in `setsid sleep` pgroup + dead port → pool_wait_cdp rc 1 + pgroup killed.
setsid sleep 300 & SP=$!; SPGID="$(ps -o pgid= -p "$SP" | tr -d ' ')"
AGENT_BROWSER_POOL_STATE="$STATE" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           POOL_CHROME_PGID="'"$SPGID"'"
           if pool_wait_cdp 55598; then echo "FAIL ready"; else echo "OK timeout rc1"; fi'
kill -0 "$SP" 2>/dev/null && echo "FAIL still alive" || echo "OK pgroup killed"
# Expected: OK timeout rc1 ; OK pgroup killed. (Slow: ~30s.)

# Instant-death guard: non-existent binary → pool_die (NOT a bare-$(…) abort).
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_BIN=/no/such/chrome AGENT_CHROME_HEADLESS=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           pool_chrome_launch '"$PORT"' "'"$UDD"'" 3; echo UNREACHED' >/tmp/s3.out 2>&1; rc=$?
echo "exit=$rc"; grep -q "exited immediately" /tmp/s3.out && echo "OK guard fired" || echo "FAIL"
# Expected: exit != 0 ; OK guard fired.

# Cleanup
pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
rm -rf "$STATE" "$(dirname "$UDD")" /tmp/s3.out
```

### Level 3: Integration Testing (Real Chrome + host facts)

```bash
# Host facts the functions rely on (regression against env change):
command -v setsid && command -v ps && command -v curl && command -v google-chrome-stable
setsid sleep 2 & SP=$!; [[ "$(ps -o pgid= -p "$SP" | tr -d ' ')" == "$SP" ]] \
  && echo "setsid pgid==pid OK" || echo "setsid BROKEN"; kill -- -"$SP" 2>/dev/null || true

# Full real-Chrome lifecycle with the production globals (no fixture overrides beyond state dir):
STATE="$(mktemp -d)"; UDD="$(mktemp -d)/lane-1"; PORT=55558
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_HEADLESS=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
           pool_chrome_launch '"$PORT"' "'"$UDD"'" 1
           pool_wait_cdp '"$PORT"'
           echo "launched+ready: pid=$POOL_CHROME_PID pgid=$POOL_CHROME_PGID"
           kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true'
sleep 1; pgrep -f "remote-debugging-port=$PORT" >/dev/null && echo "LEAK" || echo "clean (no leak)"
# Expected: launched+ready: pid=… pgid=<same> ; clean (no leak). Confirms the full
# launch→wait→teardown lifecycle end-to-end with the real production globals.
rm -rf "$STATE" "$(dirname "$UDD")"
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Flag-presence audit of a REAL launch (NOTE: grep -F -- because flags start with '-'):
STATE="$(mktemp -d)"; UDD="$(mktemp -d)/lane-2"; PORT=55559
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_HEADLESS=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           pool_chrome_launch '"$PORT"' "'"$UDD"'" 2 >/dev/null
           echo "$POOL_CHROME_PID"' > /tmp/pid.txt
PID="$(cat /tmp/pid.txt)"; sleep 1
CMDLINE="$(tr "\0" "\n" < /proc/$PID/cmdline)"
for f in --remote-debugging-port --user-data-dir --no-first-run --no-default-browser-check \
         --disable-background-timer-throttling --disable-backgrounding-occluded-windows \
         --disable-renderer-backgrounding --disable-features=CalculateNativeWinOcclusion \
         --disable-back-forward-cache --headless=new; do
  grep -qF -- "$f" <<<"$CMDLINE" && echo "OK $f" || echo "MISSING $f"
done
kill -- -"$(ps -o pgid= -p "$PID" | tr -d ' ')" 2>/dev/null || true
rm -rf "$STATE" "$(dirname "$UDD")" /tmp/pid.txt
# Expected: OK for every flag (all 9 + --headless=new).

# Concurrency sanity (two parallel launches on DIFFERENT ports — FINDING 2: boots run outside the
# flock; each gets its own pgroup):
STATE="$(mktemp -d)"; UDD1="$(mktemp -d)/1"; UDD2="$(mktemp -d)/2"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_HEADLESS=1 \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init
           pool_chrome_launch 55560 "'"$UDD1"'" 1 & pid1=$!
           pool_chrome_launch 55561 "'"$UDD2"'" 2 & pid2=$!
           wait $pid1; wait $pid2
           # NOTE: the globals reflect the LAST launch; the per-call pids/pkids are captured in
           # the _pool_log lines. Confirm two distinct chromes:
           pgrep -af "remote-debugging-port=5556[01]" | wc -l'
sleep 1
pkill -f "remote-debugging-port=5556[01]" 2>/dev/null || true   # (real teardown is per-pgroup)
rm -rf "$STATE" "$(dirname "$UDD1")" "$(dirname "$UDD2")"
# Expected: 2 (two independent Chrome processes/proups on distinct ports).

# Regression: the whole file still lints clean after the append.
shellcheck lib/pool.sh && echo "whole-file shellcheck OK"
bash -n lib/pool.sh && echo "whole-file bash -n OK"
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (Level 1).
- [ ] `shellcheck lib/pool.sh` clean — whole file (Level 1).
- [ ] All Level 2 scenarios pass: REAL launch → globals pgid==pid; CDP ready rc 0; all 9 flags
      present; teardown 0 orphans; timeout rc 1 + pgroup killed; instant-death guard fires.
- [ ] Level 3 host facts: setsid/ps/curl/google-chrome-stable present; setsid pgid==pid holds;
      full launch→wait→teardown lifecycle clean (no leak).
- [ ] Level 4: every required flag OK in a real launch; two concurrent launches → 2 chromes;
      whole-file `shellcheck` + `bash -n` clean after the append.

### Feature Validation

- [ ] All success criteria from "What" section met.
- [ ] setsid contract: `POOL_CHROME_PGID == POOL_CHROME_PID` after a successful launch
      (host-verified). `kill -- -<pgid>` leaves 0 orphans.
- [ ] `pool_wait_cdp <port>` returns 0 once CDP answers; returns 1 on timeout (≤30 s) AND kills
      the pgroup (if `POOL_CHROME_PGID` set + numeric).
- [ ] All 9 flags present verbatim in `/proc/<pid>/cmdline`; `--headless=new` ONLY when
      `POOL_HEADLESS==1` (default windowed — PRD §2.6).
- [ ] Bad-arg validation pool_dies before launching anything (port/udd/lane checks).
- [ ] Instant-death path `pool_die`s with the log path (NOT a bare-`$(…)` set -e abort).
- [ ] `pool_wait_cdp` is NON-FATAL (never pool_die); caller `if`-guard idiom demonstrated.

### Code Quality Validation

- [ ] Follows existing codebase patterns: `local`-first (SC2155), errexit-exempt `[[ ]] ||
      pool_die` validation (pool_copy_master style), `mkdir -p -- "$dir" || pool_die` defensive
      dir, array `flags=()` + `"${flags[@]}"` (no word-splitting), guarded `$(…)` capture.
- [ ] Banner style matches the M3/M4.T1/M4.T2.S1 sections; placed at EOF after
      `pool_find_free_port`.
- [ ] `POOL_CHROME_PID`/`POOL_CHROME_PGID` naming follows the `POOL_*` convention; documented in
      the docstring with rationale.
- [ ] No new globals beyond the two `POOL_CHROME_*` (exported via `declare -g`); no new env vars;
      no new files / on-disk layout (only the per-lane Chrome log, which is a runtime artifact).

### Documentation & Deployment

- [ ] No new user docs required ("DOCS: none — internal functions"). Both functions are
      self-documenting via their docstring headers (GOTCHA lines).
- [ ] No new env vars; no README changes; no .gitignore changes.

---

## Anti-Patterns to Avoid

- ❌ Don't add `setsid --fork`/`-f` — it forks and breaks `pgid==pid` (release would then leak
  orphans). The default (exec) is what makes the contract hold. HOST-VERIFIED (research §1).
- ❌ Don't capture the pgid with a BARE `pgid="$(ps -o pgid= -p $PID | tr -d ' ')"` — under
  `set -euo pipefail` it ABORTs the pool the instant Chrome dies before the capture. Use
  `|| true` + a `[[ -z ]]` → `pool_die` guard (research §5).
- ❌ Don't drop the `--` from `kill -- -<pgid>` — a positive integer that starts with `-` is
  parsed as a kill flag without it. The negative pid IS the whole-process-group signal.
- ❌ Don't use `--headless` (legacy/deprecated) — use `--headless=new` (modern, Chrome 112+).
- ❌ Don't `pool_die` from `pool_wait_cdp` on timeout — return 1 (non-fatal); the caller
  (M5.T1.S2) owns the PRD §2.14 retry policy. Same non-fatal family as `pool_find_free_port`.
- ❌ Don't call `pool_wait_cdp "$port"` bare under `set -e` — the rc-1 timeout ABORTs the
  caller. Use `if pool_wait_cdp "$port"; then …`.
- ❌ Don't skip the `mkdir -p "$POOL_STATE_DIR"` — the backgrounded `> "$log"` redirect fails to
  open if the dir is missing, the job exits instantly, and you trip the §5 guard with a
  misleading "exited immediately" message.
- ❌ Don't pass a relative `--user-data-dir` (PRD §2.2) — validate absolute before launch.
- ❌ Don't build the flag list as a space-separated string — use a bash array (`flags=()` +
  `"${flags[@]}"`) so future flags with spaces/values survive intact.
- ❌ Don't connect the daemon, take/release the flock, update the lease, or pick the port here —
  those are M4.T3.S1 / M5.T1.S1 / M5.T1.S2 / M4.T2.S1 (out of scope). The timeout process-group
  kill is INLINED + guarded here only because no reusable teardown helper exists yet (M4.T3.S1).
- ❌ Don't rename `pool_chrome_launch` / `pool_wait_cdp` — the contract + consumer (M5.T1.S2)
  use exactly those names. And export `POOL_CHROME_PID`/`POOL_CHROME_PGID` (the `POOL_*`
  convention), not the contract's bare `CHROME_PID`/`CHROME_PGID` shorthand (research §6).
