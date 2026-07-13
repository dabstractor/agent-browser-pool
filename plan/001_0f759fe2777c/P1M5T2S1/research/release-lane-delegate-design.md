# Research — P1.M5.T2.S1: PUBLIC `pool_release_lane(lane)` (release & teardown)

**Status: research complete.** Evidence base = (1) direct read of the LANDED
`lib/pool.sh` (kernel + pool_chrome_kill + pool_daemon_connect + pool_lease_read),
(2) the completed M5.T1.S1 PRP delegate-contract, (3) the M4.T3.S1 host-verified
research, (4) HOST VERIFICATION of the `agent-browser close` subcommand on this host
(agent-browser 0.28.0, 2026-07-13). No files modified.

---

## §0. The ONE-LINE answer

`pool_release_lane(LANE)` = **read `session` from the lease → `$POOL_REAL_BIN --session
"$session" close 2>/dev/null || true` → delegate to `_pool_release_lane_internals "$LANE"`
(kill pgroup + rm dir + rm lease)** → return 0. The daemon `close` is the ONE step the
LANDED kernel omits; everything else is delegated (DRY, per the M5.T1.S1 contract).

---

## §1. The delegate design is CONTRACTED (M5.T1.S1 PRP)

The completed M5.T1.S1 PRP (`plan/001_0f759fe2777c/P1M5T1S1/PRP.md`) states in MULTIPLE
places that the public `pool_release_lane` (this task) COMPOSES the private kernel, never
duplicates it:

> "M5.T2.S1's public `pool_release_lane()` will **compose** `_pool_release_lane_internals`
> rather than duplicate it (documented as a contract below). This unblocks the circular
> acquire↔release dependency."

And the LANDED banner comment in `lib/pool.sh` (~line 1806):

> "The private release kernel (_pool_release_lane_internals) is ALSO composed by M5.T2.S1's
> public pool_release_lane and M5.T3.S1's reap (shared teardown path)."

And `_pool_release_lane_internals`'s own docstring (CONSUMERS):

> "Called by _pool_acquire_critical_section's REAP-STALE step (3a) … AND (by contract), by
> M5.T2.S1 pool_release_lane + M5.T3.S1 reap_stale."

➡ **Verdict:** a STANDALONE re-implementation would VIOLATE the M5.T1.S1 contract.
**Delegate.** The public layer adds exactly ONE step (daemon `close`) on top of the kernel.

---

## §2. The LANDED kernel `_pool_release_lane_internals` (what we delegate TO)

Body in `lib/pool.sh` ~line 1813 (M5.T1.S1, COMPLETE). Verified step-by-step:

| step | code | behavior |
|---|---|---|
| validate lane | `[[ "$lane" =~ ^[0-9]+$ ]] \|\| return 0` | path-traversal defense |
| (1) read lease | `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi` | rc 1 (missing/corrupt) ⇒ return 0 (idempotent) |
| (2) ONE jq fork | `mapfile -t _f < <(jq -r '.chrome_pid, .chrome_pgid, .ephemeral_dir' <<<"$json")` | extracts 3 fields. **NOTE: does NOT read `session`.** |
| (3) kill | `pool_chrome_kill "$chrome_pid" "$chrome_pgid"` | SIGTERM→0.5s→SIGKILL pgroup + bare-pid fallback; handles 0/0 provisional |
| (4) rm dir | `dir="$POOL_EPHEMERAL_ROOT/$lane"; if [[ …prefix-guard… ]]; then rm -rf -- "$dir" 2>/dev/null \|\| true; fi` | RECONSTRUCTED (does NOT trust lease's ephemeral_dir) + prefix-guard. + defense-in-depth second block for a distinct lease subtree. |
| (5) rm lease | `rm -f -- "$POOL_LANES_DIR/$lane.json" 2>/dev/null \|\| true` | idempotent (already-deleted / TOCTOU) |
| return | `return 0` | **NON-FATAL always** |

➡ **KEY GAPS for the public layer:** the kernel (a) does NOT read `session`, and (b) does
NOT call the daemon `close`. Both are the public `pool_release_lane`'s job. Because the
kernel DELETES the lease (step 5), the public layer MUST read `session` BEFORE delegating.

`pool_chrome_kill` docstring (the M4.T3.S1 LANDED primitive the kernel composes) makes the
deferral explicit:

> "Chrome-teardown ONLY: do NOT call `agent-browser --session <name> close` here.
> Daemon/session disconnect is the wrapper's close interception (M6.T1.S2) + release's
> lease-delete (M5.T2.S1). Scope: kill the Chrome tree."

---

## §3. HOST VERIFICATION — `agent-browser --session <name> close` (the one uncertain piece)

Run on this host, agent-browser **0.28.0**, 2026-07-13. Throwaway session names
`abpool-reltest-$$`; real pooled-style Chrome on a free port; careful cleanup. **No
existing sessions touched; no strays left.**

| scenario | rc | chrome after | session in list after | stray launched? |
|---|---|---|---|---|
| `close` on a NEVER-CONNECTED (fresh) session | **0** | n/a | — | no |
| `close` on a LIVE connected session (chrome alive) | **0** | **STILL ALIVE** ✅ (disconnect-only confirmed) | **STILL PRESENT** (lingers) ✅ | no |
| `close` on a DEAD-chrome session (kill chrome first) | **0** | dead | lingers | **NO** (chrome proc count 2→2 unchanged) ✅ |
| `close` ×2 more on the same dead session (idempotency) | **0**, **0** | dead | lingers | no |

**`close --help` (captured):**
```
agent-browser close - Close the browser
Usage: agent-browser close [options]
Closes the browser instance for the current session.
Aliases: quit, exit
Options:
  --all                Close all active sessions      ← the wrapper M6.T1.S2 must intercept
```

### Conclusions (host-verified, agent-browser 0.28.0)

1. **`close` rc is ALWAYS 0** — fresh, live, dead, repeated. So the CONTRACT's
   `2>/dev/null || true` is defensive-but-correct (future-proof + documents non-fatal
   intent; the rc is currently always 0). KEEP the guard — it is the idempotency mechanism.
2. **`close` is DISCONNECT-ONLY** — the Chrome SURVIVES `close` (EXP2: chrome still alive +
   CDP up after close). `close` does NOT quit the browser despite its help text. The pool
   relies on `pool_chrome_kill` (the pgroup kill) to actually terminate Chrome. This
   CONFIRMS PRD §2.5 ("`agent-browser close` (mid-task) = disconnect-only … the lane,
   Chrome, and ephemeral dir stay alive").
3. **`close` does NOT launch strays** — chrome proc count UNCHANGED before/after a `close`
   on a dead-chrome session (unlike `get cdp-url`, M4.T3.S1 research §2). So `close` is
   SAFE to call at any point in release (before or after the kill).
4. **the session LINGERS** in `session list` after `close` (still present) — matches M4.T3.S1
   research §3. Harmless: a re-acquired lane (same N → same `abpool-N`) re-binds via
   `pool_daemon_connect`, which is idempotent/re-bindable (M4.T3.S1 research §1).
5. **ordering kill ↔ close is IMMATERIAL** — both are idempotent, non-interfering, and
   (host-verified) rc 0 regardless of state. So `close` can run BEFORE or AFTER
   `pool_chrome_kill` with identical results.

➡ **Design choice (see §4):** run `close` BEFORE delegating to the kernel (graceful daemon
detach while the Chrome may still be reachable), then let the kernel kill + rm + rm-lease.
The CONTRACT's literal order (c. KILL → d. DISCONNECT) is swapped to (d → c); this is
IMMATERIAL (§3.5) and the swap is JUSTIFIED (graceful detach + DRY delegation — the kernel
bundles kill+rm+rmlease and the M5.T1.S1 contract mandates delegation, §1).

---

## §4. The composition order (the design decision)

Because the kernel bundles (kill + rm dir + rm lease) as ONE idempotent unit and the
M5.T1.S1 contract MANDATES delegation (§1), the public function's composition is:

```
pool_release_lane(LANE):
  1. validate lane (^[0-9]+$) else return 0
  2. pool_lease_read "$LANE" → json   (rc 1 = missing/corrupt → return 0, idempotent)
  3. session = jq -r '.session' (defensive reconstruct → "abpool-$LANE" if empty/null)
  4. $POOL_REAL_BIN --session "$session" close 2>/dev/null || true   ← the ONE added step
  5. _pool_release_lane_internals "$LANE"   ← kill pgroup + rm dir + rm lease (DRY)
  6. _pool_log … ; return 0
```

**Why `close` BEFORE the kernel (not after):**
- **Graceful detach**: the daemon unbinds from a possibly-still-reachable Chrome (cleaner
  than unbinding from an already-dead Chrome). Host-verified rc 0 either way (§3).
- **Natural session read**: `session` is read up-front (step 3); the kernel deletes the
  lease (its step 5), so the session read MUST precede delegation regardless. Putting
  `close` right after the read is the obvious spot.
- **Idempotent end-to-end**: a 2nd `pool_release_lane` on the same lane hits step 2 → rc 1
  (lease already deleted by the 1st call) → return 0. Idempotent. ✓
- **Order immaterial** (§3.5): kill↔close are independent idempotent operations; the literal
  CONTRACT order (c→d) is honored in INTENT (both run), only swapped in sequence for the
  DRY-delegation reason above.

**Why `close` is NOT inside the kernel:** (1) the kernel runs INSIDE the acquire flock (short
critical section — PRD §2.19 forbids subprocess/launch work under the lock); a subprocess
`close` there violates the short-flock invariant. (2) `pool_chrome_kill`'s scope docstring
explicitly defers daemon disconnect to "release's lease-delete (M5.T2.S1)". (3) The public
release runs OUTSIDE the flock (§5), so the subprocess `close` is safe here.

---

## §5. FLOCK: the public release does NOT take the lock

- The kernel `_pool_release_lane_internals` contains NO `flock`; it is called BOTH inside
  the acquire flock (by `_pool_acquire_critical_section` REAP-STALE) AND outside it (by
  `pool_boot_lane` cleanup, M5.T1.S2). It is **lock-agnostic**.
- The ONLY public flock entry point is `pool_acquire_locked` (M5.T1.S1):
  `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`.
- PRD §2.19: "Keep the flock critical section short: claim the lane (scan + write lease)
  under flock, then release before launching Chrome." Flock = ACQUIRE-ONLY.
- The release CONSUMERS (M5.T3 reap_stale, M7.T3 admin release, M5.T4 exhaustion) hold NO
  flock around release/reap (per tasks.json contracts).

➡ **Verdict:** `pool_release_lane` does NOT acquire the flock. Rationale: release is
**lane-local + idempotent** (kill a specific pid, rm a specific dir, rm a specific lease);
every kill/rm/close is `2>/dev/null || true`, so a concurrent acquire's in-lock reap of the
SAME lane is a harmless idempotent no-op. (If a future caller wants mutual exclusion, IT
takes the flock — not this function.)

⚠ **Stale-contract note:** the M5.T2.S1 tasks.json CONTRACT lists "Consumed by … acquire
reap-stale (M5.T1.S1)" — but the LANDED M5.T1.S1 calls the PRIVATE kernel directly (inside
the flock), NOT the public function (the public `close` subprocess is forbidden under the
short flock). So the public `pool_release_lane`'s real consumers are the reaper / admin /
exhaustion paths — all OUTSIDE the flock. Document this; don't repeat the stale line.

---

## §6. Lease schema + `session` read

PRD §2.8 (frozen by M3.T1.S1) — `lanes/<N>.json`:
```json
{ "version":1, "lane":7, "ephemeral_dir":"…/active/7", "port":53427,
  "session":"abpool-7", "owner":{…}, "chrome_pid":104816, "chrome_pgid":104816,
  "acquired_at":…, "last_seen_at":…, "connected":true }
```
- `session` is a TOP-LEVEL field; value pattern `abpool-<N>` (set at CLAIM, PRD §2.4 step 3d).
- Read: `pool_lease_read LANE` (echoes raw JSON / rc 0; rc 1 missing/corrupt) + ONE jq fork
  `jq -r '.session'`. This is the SAME idiom `_pool_adopt_lane` uses for `.port`.
- **Defensive reconstruct:** if `session` is empty OR literal `"null"` (jq -r on a missing
  field), reconstruct as `"abpool-$lane"` (deterministic from the lane number; matches the
  S3 ensure_connected defensive-reconstruct convention).

`POOL_REAL_BIN` (used for the `close` subprocess): set by `pool_config_init` (M1.T1.S2)
from env `AGENT_BROWSER_REAL` (default `$HOME/.local/bin/agent-browser`), canonicalized
absolute via `realpath -m`. The SAME global `pool_daemon_connect`/`pool_daemon_connected`
use. Guard `${POOL_REAL_BIN:-}` (set -u safety; release is non-fatal — if unset, skip close,
the kernel still tears down Chrome+dir+lease).

---

## §7. bash gotchas (set -euo pipefail, propagated by lib/pool.sh line 17)

1. **`local x=$(…)` masks errexit (BashFAQ 105 / SC2155):** declare `local` FIRST, assign
   AFTER: `local json session; json="$(pool_lease_read …)"`. The S3 PRP + kernel both follow
   this. Applies to pool_lease_read + jq captures.
2. **pool_lease_read returns 1 (non-fatal) on missing/corrupt** — a BARE call ABORTS under
   set -e. Guard with `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi`
   (errexit-exempt `if !`; `return 0` = idempotent no-op). Mirror the kernel exactly.
3. **`jq -r '.session'` cannot fail** on valid JSON (guaranteed by pool_lease_read's
   `_pool_json_valid` pre-check) — but the assignment is still split (gotcha 1).
4. **`"$POOL_REAL_BIN"` under set -u:** if somehow unset, `"$POOL_REAL_BIN"` is an unbound-
   variable error BEFORE the command runs (not catchable by the command's `|| true`). Guard
   with `[[ -n "${POOL_REAL_BIN:-}" ]]` (default-expansion) around the close call.
5. **The kernel is NON-FATAL (returns 0 always)** — so `pool_release_lane` inherits rc 0
   from the kernel's final `return 0`. Do NOT add a `|| return` that could mask it.
6. **Idempotency is the kernel's + close's job:** every kill/rm is `2>/dev/null || true`
   (inside the kernel); close is `2>/dev/null || true` (host-verified rc 0, §3). A 2nd call
   on the same lane is a clean no-op (step 2 → lease gone → return 0).

---

## §8. Naming, placement, consumers, scope

- **Name (CONTRACT, authoritative):** `pool_release_lane` (PUBLIC, NO underscore prefix).
  Pairs with the private `_pool_release_lane_internals` kernel. NO new private helpers —
  the body is ~10 lines; fragmenting it would hurt readability.
- **Placement:** APPEND at EOF of `lib/pool.sh`, under a NEW banner
  `# Release & teardown (P1.M5.T2.S1)`, directly AFTER `pool_ensure_connected` (the current
  EOF, the M5.T1.S3 deliverable). Pure addition — NO edits to any existing function
  (especially NOT `_pool_release_lane_internals` / `pool_chrome_kill` / `pool_lease_read`).
- **Consumers (real, outside the flock — §5):**
  - M5.T3.S1 `pool_reap_stale` — iterate stale lanes, call `pool_release_lane` each.
  - M7.T3.S1 `pool_admin_release` — `release [<N>|all]` CLI → `pool_release_lane`.
  - M5.T4.S1 exhaustion force-reap — force-release the oldest dead-owner lane.
  - (NOT M5.T1.S1 acquire REAP-STALE — that uses the private kernel inside the flock, §5.)
- **Scope:** `pool_release_lane` ONLY. Do NOT implement reap_stale (M5.T3), admin release
  (M7.T3), exhaustion (M5.T4), or the wrapper (M6). Do NOT touch the kernel. Do NOT add a
  flock. Do NOT add new env vars / globals (reads POOL_REAL_BIN + POOL_LANES_DIR via the
  kernel + pool_lease_read).

---

## §9. Decisions summary (for the PRP)

| # | decision | evidence |
|---|---|---|
| D1 | DELEGATE to `_pool_release_lane_internals` (do NOT duplicate kill/rm/lease) | M5.T1.S1 PRP contract (§1) |
| D2 | The ONE added step = daemon `close` (read session → close → delegate) | CONTRACT 3b/3d + pool_chrome_kill scope docstring (§2) |
| D3 | `close` runs BEFORE delegation (graceful detach); order immaterial (host-verified) | §3.5 + §4 |
| D4 | `close 2>/dev/null \|\| true` (rc always 0 on 0.28.0, but defensive + idempotent) | §3 |
| D5 | NO flock (lane-local + idempotent; matches kernel + consumers) | §5 |
| D6 | read `session` BEFORE delegation (kernel deletes the lease) | §2 + §6 |
| D7 | defensive reconstruct `session="abpool-$lane"` if empty/null | §6 (S3 convention) |
| D8 | idempotent + NON-FATAL (return 0 always; missing lease → return 0) | kernel contract + §7 |
| D9 | banner `# Release & teardown (P1.M5.T2.S1)`, appended after pool_ensure_connected | §8 |
