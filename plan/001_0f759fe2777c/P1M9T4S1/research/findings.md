# Research findings — P1.M9.T4.S1 (Transparency checklist tests)

## 1. What this item produces
A NEW file `test/transparency.sh` that validates PRD §2.15 "the no-idea contract" — an agent
must NOT be able to tell that pooling is happening. 8 `test_*` bodies (a–h) + a SINGLE-SETUP
runner. SOURCES the LANDED framework `test/validate.sh` (P1.M9.T1.S1) for the 5 assertions +
`spawn_sim_owner` + `setup/teardown` (but does NOT use `run_test`/`abpool_run_suite` — they
call `setup()` per-test → 3rd-call HANG in this sandbox; see §5).

## 2. The wrapper lifecycle (lib/pool.sh:3451 `pool_wrapper_main`) — what each item exercises
```
a. config+state init          (pool_config_init / pool_state_init)
b. POOL_DISABLE==1 → exec passthrough          ← not tested here (disable is a cutover valve)
c. pool_dispatch_classify → 'meta' → exec REAL BIN unchanged   ← items (a),(b)
d. pool_owner_resolve → PID==0 (no pi ancestor) → exec passthrough  ← NOT the agent case
e. pool_lease_find_mine → N  ELSE pool_acquire_locked(+boot)         ← items (c),(d),(h)
f. pool_ensure_connected N                                          ← items (c),(d),(e),(f)
g. pool_normalize_close → pool_normalize_connect (rewrite POOL_NORM_ARGS)   ← items (e),(g)
h. pool_strip_session_args → pool_force_session(N) → AGENT_BROWSER_SESSION=abpool-N   ← item (f)
i. exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"   ← TERMINAL; no code after
```

## 3. Dispatch classification (lib/pool.sh:3030 `pool_dispatch_classify`) — META vs DRIVING
- META (passthrough, exec unchanged): `--help` | `-h` | `--version` (short-circuit FIRST),
  `session list` (two-word), and cmd ∈ {`skills`,`dashboard`,`plugin`,`mcp`}.
- DRIVING: everything else (open/click/.../connect/close/session/...) + unrecognized + empty.
- META short-circuits BEFORE owner resolution ⇒ `skills get core` / `--help` / `--version`
  passthrough REGARDLESS of whether a pi ancestor exists. ⇒ item (a)/(b) is pure output-equality.

## 4. NORMALIZATION + SESSION OVERRIDE (the "agent can't escape its lane" half of §2.15)
- `pool_normalize_close` (lib/pool.sh:3091): if cmd==`close`, strip EVERY `--all` token; sets
  `POOL_CLOSE_ALL_SEEN=1`. Everything else preserved. ⇒ item (g): raw `close --all` becomes
  `close` (scoped) — the `--all` that would nuke ALL daemon sessions is neutralized.
- `pool_normalize_connect` (lib/pool.sh:3218): if cmd==`connect`, strip the FIRST non-flag
  positional after it (the `<port|url>`). ⇒ item (e): `connect 12345` → bare `connect`, the
  random arg is IGNORED. GOTCHA: bare `connect` is a RUNTIME ERROR in the real binary
  ("<port|url> required"); pool_ensure_connected ALREADY bound the lane daemon in step (f), so
  the bare result's rc is irrelevant to the lane-routing contract — verify ROUTING (find_mine→N)
  + STRIPPING (unit-check POOL_NORM_ARGS), NOT the bare-connect exit code.
- `pool_strip_session_args` (lib/pool.sh:3291): removes every `--session <X>`/`--session=<X>`;
  writes `POOL_CLEAN_ARGS`.
- `pool_force_session N` (lib/pool.sh:3369): `export AGENT_BROWSER_SESSION=abpool-N`.
- ⇒ item (f): `--session <X> open <url>` → the FLAG is stripped + env FORCED to abpool-N. The
  OBSERVABLE proof: the lease's `.session` == `abpool-<N>` and ≠ `<X>` (read via pool_lease_field).

## 5. THE CENTRAL GOTCHA — a wrapper-driven `open` may NOT EXIT
Source: `test/concurrency.sh:12-14` (the precedent's own note): the wrapper TERMINATES via
`exec "$POOL_REAL_BIN" …`; the real agent-browser may not exit for `open` ⇒ `wait` hangs.
AGENTS.md §2-§3: every blocking subprocess MUST be `timeout`-bounded + backgrounded + reaped.
DESIGN (poll-then-kill, applies to items c/d/f):
  - The lane is ACQUIRED+BOOTED+CONNECTED and the lease WRITTEN BEFORE the terminal `exec`.
  - So: background `timeout --signal=KILL 20 "$ABPOOL_WRAPPER" open <url> >/dev/null 2>&1 &`,
    capture bg pid ($! = the `timeout` job). Poll `pool_lease_find_mine` (this owner) up to a
    deadline (~18s; Chrome boots ~3-8s). Read the lease (lane N, .session). Assert. Then
    `kill <bgpid>` + `wait <bgpid>` to reap the timeout job (Chrome survives — it is the POOL's,
    launched via setsid; reaped by `release all` in teardown/inter-body cleanup).
  - Use `about:blank` as the URL (local, no network; fastest navigation; avoids flake).
  - Robust whether `open` exits fast OR hangs (timeout + poll cover both).

## 6. META passthrough verification (items a, b) — deterministic, NO Chrome, fast
- `skills get core` / `--help` / `--version` are META → exec `$POOL_REAL_BIN <args>` unchanged.
- PROOF of passthrough = BYTE-EQUAL stdout: run both under `timeout 15`, capture, assert_eq.
  - `$ABPOOL_WRAPPER skills get core`  vs  `$POOL_REAL_BIN skills get core`
  - `$ABPOOL_WRAPPER --help`           vs  `$POOL_REAL_BIN --help`
  - `$ABPOOL_WRAPPER --version`        vs  `$POOL_REAL_BIN --version`
- The wrapper's config/state init log to a FILE (POOL_LOG_PATH), NOT stdout → stdout is clean →
  byte-equality holds. NEVER assert on the CONTENT (it varies by agent-browser version); assert
  EQUALITY (wrapper doesn't corrupt it).
- These run in the body; under `set -e` capture BOTH (subshell `(out=$("$bin" "$@"); echo)`) and
  compare. If real agent-browser emits to stderr, capture 2>&1 too — but assert STDOUT equality.

## 7. item (g) vs the PREVIOUS item's `test_close_is_disconnect_only` (NO DUPLICATION)
- `test/release_reaper.sh` (P1.M9.T3.S1) `test_close_is_disconnect_only` is SINGLE-owner +
  bare `close`: asserts Chrome+dir+lease SURVIVE close (close != release) + next cmd reuses N.
- item (g) is DIFFERENT: `close --all` (the `--all` strip) + MULTI-owner (a PEER lane must be
  UNAFFECTED). Verify: (1) `--all` was stripped (POOL_CLOSE_ALL_SEEN==1 after
  `pool_normalize_close close --all`; unit-check), (2) MY lane's daemon is disconnected (bare
  `close --session abpool-N` is what the wrapper exec's), (3) a SECOND owner's lane+Chrome stay
  ALIVE after MY `close --all` (curl /json/version on peer's port still responds). This is the
  §2.15 "cannot harm other agents' lanes" half — genuinely new, not a dup.

## 8. item (h) — next agent, next lane (the concurrency seam, but via OWNERS not parallelism)
- Two DISTINCT owners (spawn_sim_owner x2 → distinct PID + starttime). Owner A acquire+boot → N.
  Owner B (swap AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME to B's) acquire+boot → M. Assert N!=M,
  both leases present, both Chrome alive. Reuses the concurrency suite's LESSON (distinct owners
  get distinct lanes) but SEQUENTIALLY (no parallelism → no `wait`-hang risk) + via the lib
  acquire path (not the wrapper exec) to stay deterministic.

## 9. Reusable helpers to COPY from test/release_reaper.sh (the LANDED, host-proven pattern)
- `_release_setup_real_env` → rename `_transparency_setup_real_env`: resolve REAL home via
  `getent passwd`, override AGENT_CHROME_MASTER (real master or minimal), AGENT_BROWSER_REAL
  (real binary), RELOCATE AGENT_CHROME_EPHEMERAL_ROOT to a btrfs temp dir under real home
  (/tmp is tmpfs here → `cp --reflink=always` fails → pool_die), append it to ABPOOL_SIM_BINS
  (so the EXIT trap reaps it), re-run pool_config_init/pool_state_init.
- `_release_acquire_boot` → `_transparency_acquire_boot`: pool_owner_resolve →
  pool_acquire_locked → (port==0) pool_boot_lane; echoes N.
- `_test_spawn_owner`: spawn fresh live `pi` owner, export OWNER_PID/_STARTTIME, set
  ABPOOL_CUR_OWNER, `pool_owner_resolve` (refresh globals in THIS shell). Echoes pid.
- `_release_kill_owner_and_reap_zombie` → kill+wait (reap zombie so /proc clears).
- Runner `_abpool_run_transparency_suite`: ONE setup(); kill setup's unused owner; loop
  `for fn in test_*` run via `if "$fn"; then` in the MAIN shell (NO subshell → EXIT trap does
  NOT fire mid-suite → temp root survives all bodies); inter-body: `release all` + kill owner.
  ONE teardown(). Source-vs-execute gate at the bottom (BASH_SOURCE==0).

## 10. Real binaries present on THIS host (host-verified)
- `$real_home/.local/bin/agent-browser` → symlink to agent-browser-linux-x64 (executable). ✓
- `$real_home/.agent-chrome-profiles/master-profile` (the read-only master). ✓ (reuse if non-empty)
- `google-chrome-stable` (Chrome). ✓
- `btrfs` under `$real_home` (ephemeral root relocation target). ✓
- ⇒ all 8 transparency tests are RUNNABLE on this host under the isolated temp-tree + btrfs root.

## 11. Static-only gates for PLANNING (AGENTS.md §1 — no Chrome/suite during research)
- `bash -n test/transparency.sh` (syntax)
- `shellcheck -s bash test/transparency.sh` (lint)
- These NEVER block. The full `timeout 900 bash test/transparency.sh` runs only at VALIDATION,
  inside the framework's isolated temp tree (HOME/state/ephemeral redirected + btrfs root + trap).
