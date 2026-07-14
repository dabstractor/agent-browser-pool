# AGENTS.md — operating rules for AI agents working in this repo

> **Read this FIRST. Every time. Before you run a single command.**
> The single most expensive failure mode in this project is an agent **hanging the sandbox**.
> It has cost days of confusion. The rules below exist to make sure it never happens again.

This is a **bash** project (`lib/pool.sh` + `bin/*` + `test/*`) that launches real Chrome
processes, manages process groups, and runs under `set -euo pipefail`. Several of its normal
operations — booting a browser, backgrounding daemons, flock critical sections — can **wedge a
shared sandbox silently**: the shell tool blocks until its global timeout with **no output**, so
it looks like the agent "just stopped working." You must treat that as a hard failure to avoid,
not a transient glitch.

---

## 1. MANDATORY: test in an isolated sandbox. Never hang the shared environment.

### What "isolated sandbox" means (in priority order)
1. **Best:** a throwaway container / VM / `bwrap` (bubblewrap) / `firejail` / `chroot` with its
   own `$HOME`, its own `/tmp`, and no access to the operator's real state or running processes.
2. **Minimum acceptable:** an isolated temp tree — `HOME`, state dirs, ephemeral root, and config
   all redirected under a fresh `mktemp -d` — plus hard timeouts on every subprocess (see §2).
3. **Never acceptable:** launching real browsers, real daemons, or the real test suite directly
   against the operator's live `$HOME` / running Chrome / shared `/tmp` during research or
   planning. That is exactly what wedges the sandbox.

### During PLANNING / RESEARCH (creating PRPs, investigating): NO real execution
- **Do not boot real Chrome.** **Do not run the test suite.** **Do not launch `agent-browser`,
  `google-chrome-stable`, or any daemon.**
- Verify by **reading the code** + **static checks only**: `bash -n <file>` (syntax) and
  `shellcheck -s bash <file>` (lint). These never block.
- If you need to confirm a behavior, write a **timeout-bounded, isolated micro-check** (see §2)
  that cleans up after itself — and only after you have already established the answer from the
  code. Prefer *not* running it at all.
- An empirical run is a **last resort**, never the first move. The authoritative contract is the
  source code. If a live run hangs the sandbox, you have failed, not the environment.

### During IMPLEMENTATION / VALIDATION: isolated + bounded
- Run the real suite **only** inside an isolated sandbox (container/VM/bwrap/firejail, or the
  isolated temp-tree pattern the test framework already uses).
- Every potentially-blocking subprocess MUST be wrapped in `timeout` (§2).
- Reap everything you spawn (§3). Leave zero orphan processes behind.

---

## 2. MANDATORY: hard timeouts on every subprocess that could block

Any command that launches a browser, opens a port, takes a lock, or talks to a daemon can hang.
**Always** bound it:

```bash
timeout 60 some-command        # NEVER call a browser/daemon/network op without `timeout`
timeout 60 bash -c '...'       # bound a whole script
```

- If a command you launched produces **no output within a few seconds**, assume it is hung,
  **abort it**, and reason from the code instead. Do NOT wait for the global tool timeout — that
  is the failure mode this file exists to prevent.
- Prefer to launch slow things **backgrounded** (`&`) so you retain control, capture `$!`, then
  `wait` with a deadline and `kill` the process group if it exceeds it.

---

## 3. MANDATORY: reap what you spawn. Never leak processes.

Unreaped background processes **accumulate** and eventually wedge the environment (this is a
real, observed root cause of hangs in this repo).

- Kill **process groups**, not bare PIDs: launch pooled Chrome via `setsid` (so `pgid == pid`),
  and tear it down with `kill -- -"$pgid"` then `kill -9 -- -"$pgid"` (the `--` is required — the
  arg starts with `-`). See `pool_chrome_kill` in `lib/pool.sh` for the canonical escalation.
- After `kill <child>`, the child becomes a **zombie** until its parent `wait`s. A zombie's
  `/proc/<pid>` (and sometimes its `comm`) persist → liveness checks can read it as "alive"
  (false-positive). **Always `wait <pid>` after killing a child you own** so `/proc` truly clears.
- Install an `EXIT`/`INT`/`TERM` trap that kills your background processes + removes your temp
  tree. Make every line in the trap end in `|| true` so the trap itself can never abort.
- Before you return from any task, confirm you left **zero** orphaned `sleep`/`pi`/Chrome/daemon
  processes behind (`pgrep -af <pattern>`).

---

## 4. PROACTIVE: recognize and defeat accumulation + trap hazards

Be proactive — solve these **before** they bite, not after a hang.

- **Per-invocation accumulation:** if a setup/init helper spawns a process (a daemon, a
  background `sleep`, a "fake owner") **every time it is called**, then calling it per-test
  **will** accumulate state and can wedge after N calls. This repo's test framework's `setup()`
  is exactly such a helper and **is known to hang on the 3rd call in a shared sandbox.**
  - **Rule:** cap such helpers. A test suite MUST call a process-spawning `setup()` **at most
    once** (single-setup runner), with each test spawning/cleaning its own short-lived resources —
    never per-test. See `test/release_reaper.sh`'s `_abpool_run_release_reaper_suite` for the
    approved pattern.
  - Do **not** "restore" a per-test `run_test`/`abpool_run_suite` runner if a single-setup runner
    is in place. Do **not** run a framework's built-in self-test to "check the framework" if that
    self-test calls the spawning setup once per case.
- **EXIT-trap-in-subshell hazard:** an `EXIT` trap is inherited by subshells and `( … )` blocks.
  If a trap does `rm -rf` a shared temp root, running test bodies in `( … )` subshells will
  **delete the shared state between tests**. Prefer running bodies in the **main shell** via
  `if test_fn; then …` (a failing assert's `return 1` is the function's rc → recorded as FAIL →
  the suite continues; no subshell means the trap never fires mid-suite).
- **`set -e` is not a panacea** (Greg's BashFAQ/105): commands in `if`/`||`/`&&` conditions are
  errexit-exempt; `(( 0 ))` as a statement aborts; `local x="$(…)"` masks failure (SC2155); a
  bare `kill`/`pgrep`/`curl` returning non-zero aborts. Guard every rc-1 call explicitly. None of
  this is a hang by itself, but an unguarded abort mid-cleanup can leave orphans → §3 violation →
  eventual wedge.
- **`kill -0` is a trap:** it returns non-zero for *both* "dead" (ESRCH) and "foreign-alive"
  (EPERM). Never use it for liveness. Use `/proc/<pid>` existence, `pgrep`, or a real probe
  (`curl /json/version` for a CDP browser).

---

## 5. Project ownership — DO NOT MODIFY these (read-only)

- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/prd_index.txt` — product requirements (human-owned).
- `plan/**/tasks.json` — the orchestrator's task tree.
- `.gitignore` — orchestrator-owned.
- Any file another in-flight work item owns (check `plan/<id>/tasks.json` status before editing).
- The operator's real `~/.local/state/agent-browser-pool/`, `~/.agent-chrome-profiles/`, and
  running Chrome — **never touch**. All tests/hermetic runs redirect these to a temp tree.

When creating a **PRP** (in `plan/<id>/<item>/PRP.md`), you may write only that PRP + its
`research/` notes — unless an explicit instruction widens scope.

---

## 6. Quick checklist before you return / end your turn

- [ ] No command I launched is still running (`pgrep -af` for browsers, `sleep`, daemons,
      `pi`, `abpool-*`).
- [ ] No temp roots / orphan dirs left under `/tmp` from my runs.
- [ ] Every subprocess I ran during research was static (`bash -n`/`shellcheck`) or, if live,
      isolated + `timeout`-bounded + reaped.
- [ ] I did **not** boot real Chrome or run the real test suite against the shared sandbox during
      planning.
- [ ] Any test code I produced uses a **single** process-spawning setup + reaps everything + runs
      bodies without mid-suite trap firing.

**If you cannot tick every box, stop and fix it before ending your turn. A hang is your fault.**
