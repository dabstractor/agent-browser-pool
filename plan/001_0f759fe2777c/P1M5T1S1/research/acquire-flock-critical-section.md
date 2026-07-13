# Research — P1.M5.T1.S1: flock critical section (reap-stale + reuse-orphan + choose-N + provisional claim)

Date: 2026-07-13. Sources: lib/pool.sh (read in full), plan/…/P1M4T3S1/PRP.md (parallel
contract), plan/…/architecture/{key_findings,system_context}.md, PRD §2.4/§2.8/§2.9/§2.10/§2.19,
flock(1)/flock(2)/bash manual (external research subagent, cited below).

---

## §0. The cross-dependency problem (MOST IMPORTANT)

The item CONTRACT (step 3a) says: "call release internals (kill pgroup, rm dir, delete lease).
See M5.T2.S1 for the release function — **it must exist first**. NOTE: This depends on
P1.M5.T2.S1."

**Reality (tasks.json plan_status):**
- P1.M5.T1.S1 (THIS) — Researching.
- P1.M5.T2.S1 (release) — Planned (NOT landed).
- P1.M5.T3.S1 (reap_stale) — Planned (NOT landed).
- P1.M5.T3.S2 (reuse_orphan) — Planned (NOT landed).

So the three helpers `pool_acquire_locked()` would naturally call DO NOT EXIST yet. The PRP
MUST make `pool_acquire_locked()` **self-contained and one-pass implementable** without them.

### Resolution (what this PRP mandates)

1. **Define `_pool_release_lane_internals(LANE)` HERE** — the "release internals" the
   CONTRACT references: read lease → `pool_chrome_kill(chrome_pid, chrome_pgid)` →
   `rm -rf ephemeral_dir` (guarded under POOL_EPHEMERAL_ROOT) → `rm lease file`.
   Idempotent + non-fatal. **This IS the kernel M5.T2.S1's public `pool_release_lane()`
   will compose** — documented as a contract so M5.T2.S1 does NOT duplicate it.
2. **Inline the reap-stale + reuse-orphan logic inside `pool_acquire_locked()`'s critical
   section** (as private inline logic / a private `_pool_acquire_critical_section` body).
   Justified: the item CONTRACT lists reap-stale (3a) + reuse-orphan (3b) as STEPS of
   `pool_acquire_locked`, and inlining keeps the lock-holding logic in ONE readable place.
   M5.T3.S1 (reap_stale) + M5.T3.S2 (reuse_orphan) will be the **standalone** (admin CLI /
   on-demand) versions; they will share `_pool_release_lane_internals`.

This unblocks the circular dependency: this task ships a working acquire with its own
release kernel; the later tasks build public APIs on top.

---

## §1. flock + `set -euo pipefail` semantics (external research, HOST-VERIFIED claims)

Pattern (item CONTRACT): `( flock 9; <body> ) 9>"$POOL_LOCK_FILE"`.

1. **Plain `flock 9` (no -n/-w) blocks until acquired, returns 0** → safe under `set -e`.
   Only `-n`/`-w` return non-zero (conflict); we use plain blocking. flock(1) DESCRIPTION.
2. **Lock auto-released on subshell exit — including SIGKILL.** flock(2) locks bind to the
   OPEN FILE DESCRIPTION; the kernel closes fds on process death → lock freed. NO trap needed
   for the lock itself. This is why the subshell idiom is robust: lock lifetime == fd 9
   lifetime == subshell lifetime.
3. **Parent-shell functions ARE inherited by `( ... )` subshells** (it's a fork, not exec).
   So `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` works — the body
   function (with all globals: POOL_OWNER_*, POOL_LANES_DIR, POOL_EPHEMERAL_ROOT, …) is
   available inside. Variables/return/exit changes do NOT propagate back; stdout + exit code DO.
4. **`return` inside `_pool_acquire_critical_section` (a function) becomes the subshell's exit
   status** (it's the last command). So `return 0`/`return 1` propagate cleanly. `exit N`
   also works (unwinds immediately). Do NOT use bare `return` directly in the `( )` body
   (only inside a function).
5. **CRITICAL GOTCHA — `local var=$( ... )` MASKS errexit** (BashFAQ 105): `local` always
   returns 0, so `set -e` does NOT fire if the command-substitution fails. EVERY command-
   substitution capture MUST be split: `local var; var=$( ... )`. This affects how the CALLER
   captures `pool_acquire_locked`'s output AND every internal `$(pool_lease_field …)` capture.
6. **`9>file` truncates the lock file** — harmless (advisory lock, content irrelevant).
   `set -u`: `9>"$POOL_LOCK_FILE"` is expanded by the parent; the var is set by
   pool_config_init (precondition). Parent dir must exist (pool_state_init ensures it).
7. **`/usr/bin/flock` (util-linux 2.42.2) is present** on this host (verified). `flock FD`
   form (lock an already-open fd) is what the idiom uses.

URLs: https://man7.org/linux/man-pages/man1/flock.1.html (SYNOPSIS third form + EXIT STATUS);
https://man7.org/linux/man-pages/man2/flock.2.html (open-file-description binding, NOTES);
https://www.gnu.org/software/bash/manual/bash.html#Command-Execution-Environment (subshell
inheritance); https://mywiki.wooledge.org/BashFAQ/105 (`local` masking).

---

## §2. What is safe INSIDE the short flock critical section (FINDING 2)

FINDING 2: keep the flock section SHORT — claim under lock, **launch Chrome AFTER releasing**.
The slow op is the 5–10 s Chrome LAUNCH (S2, outside lock). Inside the lock, these are all
fast (verified):

| op | cost | inside lock? |
|---|---|---|
| `kill -- -<pgid>` (signal pgroup) | single kill(2) syscall, µs | ✅ YES (reap) |
| `rm -rf` btrfs reflink (CoW) ephemeral dir | metadata/refcount only, ms | ✅ YES (reap) |
| jq read/mutate + atomic `mv` of lease JSON | µs–ms | ✅ YES (adopt/claim) |
| `pool_find_free_lane` numeric probe | µs | ✅ YES (choose-N) |
| `agent-browser --session X connect PORT` (ATTACH to running Chrome) | CDP handshake, ms–low-100ms | ✅ YES (adopt, rare path) |
| `setsid google-chrome …` (Chrome LAUNCH) | 5–10 s | ❌ NEVER (that's S2, OUTSIDE lock) |

`pool_daemon_connect` (attach) is ~100× faster than a Chrome launch — acceptable in the rare
adopt path. The common path (reap + choose + provisional claim) has NO subprocess spawn at all
(kill + rm + jq + mv). So the section is short as required.

---

## §3. Composed-function contracts (verified from lib/pool.sh)

| function | signature | rc convention | notes |
|---|---|---|---|
| `pool_lanes_list` | (none) | always 0; echoes lane N per line, sorted -n | empty/missing dir → 0 lines (valid) |
| `pool_lane_is_stale LANE` | lane | **0=stale / 1=live / 2=no-lease** (TRI-STATE, INVERTED) | caller MUST capture all 3: `if …; then; fi` rc0=stale, fallthrough rc1/2 |
| `pool_find_free_lane` | (none) | **always 0**, echoes N | bare `N="$(pool_find_free_lane)"` is set -e SAFE |
| `pool_lease_write` | LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME OWNER_CWD CHROME_PID CHROME_PGID CONNECTED (11 args) | 0 / pool_die | `connected` MUST be literal "true"/"false" |
| `pool_lease_read LANE` | lane | 0+echoes JSON / 1 (missing OR corrupt) | caller MUST guard under set -e |
| `pool_lease_field LANE FIELD` | lane, dotted-path | 0+echoes / 1 (missing/corrupt); missing FIELD echoes "null" rc0 | supports nested `owner.pid` |
| `pool_lease_update LANE FIELD VALUE` | lane, top-level field, JSON value | 0 / pool_die | **TOP-LEVEL FIELD ONLY** — nested `owner.*` NOT supported (quoted docstring: "owner is written once at acquire, never mutated") |
| `pool_chrome_kill PID PGID` | pid, pgid | **always 0** (idempotent) | handles 0/0 (provisional lease) safely |
| `pool_daemon_connect SESSION PORT` | session, port | **0 live / 1 dead** (non-fatal) | from P1.M4.T3.S1 (parallel — WILL exist) |
| `pool_daemon_connected SESSION PORT` | session, port | **0 if session known AND chrome alive / else 1** (NEVER launches) | from P1.M4.T3.S1 (parallel) |
| `pool_owner_resolve` | (none) | 0; sets POOL_OWNER_PID/COMM/STARTTIME/CWD | TEST MODE via AGENT_BROWSER_POOL_OWNER_PID |
| `_pool_atomic_write FILEPATH CONTENT` | filepath, content | 0 / pool_die | tmp+mv same dir = atomic rename |

### Lease JSON schema (written by pool_lease_write — PRD §2.8)
```json
{"version":1,"lane":3,"ephemeral_dir":"/…/active/3","port":53423,"session":"abpool-3",
 "owner":{"pid":1234,"comm":"pi","starttime":8283368,"cwd":"/home/…"},
 "chrome_pid":104816,"chrome_pgid":104816,
 "acquired_at":1720…,"last_seen_at":1720…,"connected":false}
```

### Globals (frozen by pool_config_init; read by this task)
- `POOL_LOCK_FILE` = `$POOL_STATE_DIR/acquire.lock` (the flock target)
- `POOL_LANES_DIR` = `$POOL_STATE_DIR/lanes` (leases live here as `<N>.json`)
- `POOL_EPHEMERAL_ROOT` = `$HOME/.agent-chrome-profiles/active` (ephemeral dirs `<N>/`)
- `POOL_OWNER_PID/COMM/STARTTIME/CWD` (set by pool_owner_resolve — the claimer's identity)

---

## §4. The reuse-orphan owner-reassignment gotcha

REUSE-ORPHAN (step 3b): adopt a stale-but-responsive lane → reassign owner to CURRENT.
`pool_lease_update` CANNOT do nested `owner.*` updates (top-level only). Two options:
- **(A)** read lease, extract all fields, `pool_lease_write` with new owner (faithful, reuses S1).
- **(B)** targeted jq mutation: `.owner = {new} | .connected = true | .last_seen_at = $now`,
  then `_pool_atomic_write`.

**Chosen: (B)** — it is a localized, atomic nested rewrite (no need to re-read/echo all 11
fields); it directly composes `_pool_atomic_write` (M1.T2.S1 LANDED) + jq. This is the same
inject-safe pattern pool_lease_update uses (`--arg`/`--argjson` DATA, fixed filter). Documented
as a justified deviation (pool_lease_update's top-level restriction is a convenience, not a
hard rule; the owner-reassignment is the ONE place owner is mutated, by design).

---

## §5. Output contract (what pool_acquire_locked returns + how the caller branches)

`pool_acquire_locked` echoes lane N + returns 0 on success (claimed OR adopted), or echoes
nothing + returns 1 (no free lane → M5.T4 exhaustion). The caller distinguishes
provisional-vs-adopted by reading the lease:

| outcome | lease state after pool_acquire_locked | caller action |
|---|---|---|
| provisional CLAIM (step 3d) | port=0, chrome_pid=0, connected=false | S2: copy→port→launch→connect→update lease |
| reuse-orphan ADOPT (step 3b) | port>0, chrome_pid>0, connected=true | S3: skip boot; just `ensure_connected` |
| no free lane | (no lease written) | M5.T4: block-with-timeout / force-reap / alert |

This matches PRD §2.4 step 3b ("adopt it … skip the copy") + step 3d (provisional claim) +
§2.9 (exhaustion).

---

## §6. Safety: `rm -rf` guard + idempotency

`_pool_release_lane_internals` does `rm -rf "$ephemeral_dir"`. The ephemeral_dir comes from
the lease (could be corrupt/hostile). **MANDATORY GUARD**: only rm if non-empty AND a prefix
of `$POOL_EPHEMERAL_ROOT/` (e.g. `/home/…/active/3`). Reconstructing from lane number
(`$POOL_EPHEMERAL_ROOT/$lane`) is even safer — PREFERRED in the helper (defense-in-depth:
both the guard AND the reconstruction). Every kill/rm is `2>/dev/null || true` (idempotent
under set -e; pool_chrome_kill already self-guards). Re-running on an already-released lane is
a no-op (lease gone → pool_lease_read returns 1 → return 0).
