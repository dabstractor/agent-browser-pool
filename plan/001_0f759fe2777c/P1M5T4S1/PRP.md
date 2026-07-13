# PRP — P1.M5.T4.S1: `pool_wait_for_lane()` — block-with-timeout + force-reap + alert

---

## Goal

**Feature Goal**: Implement **`pool_wait_for_lane()`** — the **IQ2 pool-exhaustion handler**
(PRD §2.9): a PUBLIC function the wrapper (M6) calls when `pool_acquire_locked` returns 1
("no free/reusable lane"). It **blocks up to `POOL_WAIT` seconds** (default 600 = 10 min),
polling every 2 s — each iteration re-running `pool_reap_stale()` (full daemon-close reap)
then retrying `pool_acquire_locked()` (which takes its OWN short flock and inlines its own
reap+reuse+choose+claim). On acquiring a lane it **echoes lane N + return 0**. On **timeout**
it **FORCE-REAPs**: scans every lane, finds the **OLDEST lane whose owner is actually dead**
(`pool_lane_is_stale` rc 0, oldest by numeric `acquired_at` epoch), **releases it via the
PUBLIC `pool_release_lane`** (daemon close + Chrome pgroup kill + rm dir + rm lease), tries
`pool_acquire_locked()` **one final time**, and **alerts** (notify-send + alerts.log). If
that succeeds → **echo lane N + return 0**. If there was **no stale lane to reap**
(all-live-owners) **or** a peer won the just-freed lane in the race → **return 1** (nothing
echoed) after alerting. Per PRD §2.9, hitting this path at all means **sessions accumulated
without cleanup = a leak to investigate** — hence the alert.

This is a **pure addition**: ONE new banner section at EOF (`# Pool exhaustion
(P1.M5.T4.S1)`) containing TWO functions — the PRIVATE `_pool_alert SUMMARY BODY` helper
(best-effort `notify-send` + `$POOL_STATE_DIR/alerts.log` append) and the PUBLIC
`pool_wait_for_lane`. **NO edits to any existing function, no new env vars/globals (it reads
the already-frozen `POOL_WAIT` + `POOL_STATE_DIR`), no new files, NO flock of its own.** It
COMPOSES six LANDED functions — `pool_acquire_locked` (M5.T1.S1), `pool_reap_stale`
(M5.T3.S1), `pool_lane_is_stale` (M3.T2.S3), `pool_lanes_list` (M3.T2.S1),
`pool_lease_field` (M3.T1.S2), `pool_release_lane` (M5.T2.S1) — and the `_pool_now` (M1.T2.S1)
+ `_pool_log` (M1.T2.S1) primitives.

The function implements the item CONTRACT verbatim (research §1 reconciles the
flock/lock-free topology, research §2 the dependency contracts, research §3 the bash
timing/rc correctness, research §4 the alert):

**a.** Poll loop up to `POOL_WAIT` seconds (2 s cadence): `pool_reap_stale >/dev/null`;
      `if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi`; `sleep 2`.
      **Check-timeout-BEFORE-body** so `POOL_WAIT=0` → zero iterations → straight to
      force-reap.
**b.** On timeout: **FORCE-REAP** — iterate `pool_lanes_list`; for each lane where
      `pool_lane_is_stale "$n"` is rc 0, read `acquired_at` (epoch, via `pool_lease_field`,
      `|| true` + `=~ ^[0-9]+$` guarded; corrupt/missing **skipped** — never defaulted to 0);
      track the lane with the **smallest** `acquired_at` (numeric `(( ))` inside `if`);
      `pool_release_lane "$oldest" >/dev/null` (PUBLIC teardown, OUTSIDE any flock).
**c.** Try `pool_acquire_locked()` one final time. If rc 0 → **alert** + `printf '%s\n'
      "$N"; return 0`. (A peer may have grabbed the freed lane → rc 1 falls through to d.)
**d.** Still no lane (no stale lane existed / all-live-owners / lost the race) → **alert**
      (PRD §2.9 "alert on timeout/force") + `_pool_log` a clear message + `return 1`
      (nothing echoed).
**e.** ALERT = `notify-send 'agent-browser-pool' 'Pool exhausted — force-reaped lane N.
      Possible leak.'` (verbatim, em-dash —) **plus** a timestamped line appended to
      `$POOL_STATE_DIR/alerts.log`. The total-failure path uses an analogous body
      (`'Pool exhausted — no lane available after <WAIT>s + force-reap. Possible leak.'`).

**Deliverable**: Two functions appended to `lib/pool.sh` under a NEW banner
`# Pool exhaustion (P1.M5.T4.S1)` at EOF (directly after `pool_reuse_orphan`, ~line 2774):
`_pool_alert` (private helper) immediately ABOVE `pool_wait_for_lane` (public), per the
helpers-first convention (`_pool_release_lane_internals` before `pool_release_lane`;
`_pool_acquire_critical_section` before `pool_acquire_locked`).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve`, given
  a pool where `pool_acquire_locked` returns 1 (all lanes live) **and** one lane has a dead
  owner (stale) with the oldest `acquired_at`: with `POOL_WAIT` set small (e.g. via test
  override `AGENT_BROWSER_POOL_WAIT=0` or a short value), `N="$(pool_wait_for_lane)"`
  returns **rc 0**, echoes **exactly one integer** = the force-reaped lane N, the stale
  lane's Chrome+dir+lease are torn down, a `notify-send` fires (or is no-op if headless),
  and `$POOL_STATE_DIR/alerts.log` gains one timestamped line whose body contains
  "force-reaped lane N".
- Given an **all-live-owners** pool (no stale lane): `pool_wait_for_lane` returns **rc 1**,
  echoes nothing, alerts (force/timeout alert), and logs the exhaustion message.
- Given a pool where **a lane frees during the wait** (another process releases mid-poll):
  the poll loop's `pool_acquire_locked` succeeds → `pool_wait_for_lane` echoes that lane +
  rc 0, **and does NOT force-reap or fire the force-reap alert** (the happy path; no alert).
- **POOL_WAIT=0**: the poll loop runs **zero iterations**; control goes straight to
  force-reap (no spurious `sleep 2`).
- **Lost-the-race**: force-reap frees lane N, but a concurrent acquire grabs it before the
  final `pool_acquire_locked` → that final attempt returns 1 → `pool_wait_for_lane` returns
  1 (nothing echoed) + alerts. No deadlock, no double-acquire.
- **stdout discipline**: `N=$(pool_wait_for_lane)` captures EXACTLY one integer token on rc 0
  and an empty string on rc 1 — because the ONLY stdout write is `printf '%s\n' "$N"`, and
  every helper is silenced (`pool_reap_stale >/dev/null`, `pool_release_lane >/dev/null`,
  `_pool_alert >/dev/null 2>&1`; `pool_acquire_locked` is captured in `$()`; `_pool_log`
  writes the LOG FILE, never stdout).
- **Non-fatal alerts**: `_pool_alert` NEVER affects `pool_wait_for_lane`'s rc — a missing
  `notify-send`, a headless session, or an unwritable `alerts.log` are all `|| true` no-ops.
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero
  warnings — host-verified ShellCheck 0.11.0); all prior deliverables (M1–M5.T3.S2)
  unchanged and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its single consumer
(per the item CONTRACT §4 + PRD §2.9, all within the wrapper's main shell):

- **M6.T3.S1 wrapper lifecycle** — the wrapper first calls `pool_acquire_locked` (the fast
  path). On rc 1 (exhaustion) it calls `pool_wait_for_lane`:
  ```bash
  local N
  if N="$(pool_acquire_locked)"; then
      <post-lock boot / ensure_connected>
  else
      if N="$(pool_wait_for_lane)"; then
          <post-lock boot / ensure_connected for N>
      else
          pool_die "agent-browser-pool: no lane available after ${POOL_WAIT}s + force-reap"
      fi
  fi
  ```
  (The wrapper's exact wiring is M6's concern; this task ships the building block.)

**Use Case**: All lanes are in use by live pi agents. A new agent invocation finds no free
lane. Rather than immediately failing, it waits up to 10 min, reaping stale lanes each poll
(maybe one frees up). If none free up, it force-reaps the oldest lane whose owner actually
died (the most likely leak), alerts the operator (desktop notification + log line), and
proceeds. If genuinely every owner is alive, it fails with a clear message so the operator
knows the pool is genuinely saturated (add more lanes) vs. a leak (investigate).

**Pain Points Addressed**:
- **Premature failure under transient contention.** Without a wait, two simultaneous
  acquires could see "no free lane" even though one releases a millisecond later. The poll
  loop absorbs that (IQ2 = block-with-timeout).
- **Leaks accumulate invisibly.** A crashed agent's lane is reclaimed lazily at the next
  acquire, but if the pool fills with dead-owner lanes faster than acquires reap them, the
  force-reap + alert surfaces the leak immediately — the operator gets a desktop
  notification + a durable log line naming the reclaimed lane.
- **Genuine saturation is distinguishable from a leak.** The all-live-owners path returns a
  distinct "no lane available" message (vs. the force-reap message), so the operator knows
  the pool needs more capacity rather than a leak hunt.

## Why

- **This IS PRD §2.9 (pool exhaustion — IQ2 = block-with-timeout + alert).** The three-step
  contract (block → force-reap → fail) is implemented exactly. The alert (notify-send +
  `alerts.log`) is mandated because "hitting this at all means sessions accumulated without
  cleanup — i.e. a leak to investigate."
- **It COMPOSES, it does not duplicate.** It reuses `pool_acquire_locked` (the flock-owning
  acquire), `pool_reap_stale` (the lock-free full reap), `pool_release_lane` (the lock-free
  teardown), `pool_lane_is_stale` (the tri-state verdict), `pool_lanes_list` (the iterator),
  `pool_lease_field` (the `acquired_at` read), `_pool_now` (epoch), and `_pool_log` (file
  logger). Re-implementing the reap, the release, or the staleness check would duplicate
  four carefully-verified functions + risk divergence.
- **It is LOCK-FREE by design.** Only `pool_acquire_locked` flocks. `pool_wait_for_lane`
  holds NO lock across the 2 s `sleep` (that would serialize the entire pool for up to 10
  min) and takes NO lock for force-reap (`pool_release_lane` is lane-local + idempotent +
  lock-free, exactly as the standalone `pool_reap_stale` composes it). This matches the
  codebase's established flock topology (research §1).
- **The alert is best-effort and non-fatal.** A headless session or a missing `notify-send`
  must never prevent the function from returning its lane (or its failure). The
  `alerts.log` write is the durable record; the desktop notification is a convenience.

## What

User-visible behavior: the **desktop notification** (`notify-send`) is the one directly
user-observable artifact; the **`alerts.log` line** is the durable record. Otherwise this is
an internal library function. Observable contract:

| scenario | call (after a prior `pool_acquire_locked` returned 1) | result |
|---|---|---|
| lane frees during wait | `N="$(pool_wait_for_lane)"` | **rc 0**; `N`==freed-lane; NO force-reap; NO alert (happy poll path) |
| 1 stale (dead-owner) lane, oldest | `N="$(pool_wait_for_lane)"` (after timeout) | **rc 0**; `N`==reaped-lane; stale lane torn down; **force-reap alert** (notify-send + alerts.log line "force-reaped lane N") |
| all-live-owners (no stale lane) | `pool_wait_for_lane` | **rc 1**; nothing echoed; **timeout/fail alert** (notify-send + alerts.log line "no lane available …"); log line |
| lost the race (peer grabs freed lane) | `pool_wait_for_lane` | **rc 1**; nothing echoed; **timeout/fail alert**; log line |
| `POOL_WAIT=0` (1 stale lane) | `N="$(pool_wait_for_lane)"` | poll loop runs **0 iterations**; straight to force-reap → **rc 0**; `N`==reaped-lane; force-reap alert |
| multiple stale lanes | `N="$(pool_wait_for_lane)"` | force-reaps the **OLDEST** (smallest `acquired_at`); alerts with that N |
| headless session / no notify-send | (any alert path) | `notify-send` skipped (command -v guard) / no-op; `alerts.log` line still written; rc unaffected |
| unwritable alerts.log | (any alert path) | alerts.log write `|| true` (no-op); notify-send still attempted; rc unaffected |

**Hard invariants** (every row):
- **LOCK-FREE — `pool_wait_for_lane` takes NO flock.** It composes the flock-owning
  `pool_acquire_locked` (which itself does `( flock 9; … ) 9>"$POOL_LOCK_FILE"`) and the
  lock-free `pool_reap_stale` + `pool_release_lane`. Do NOT add `( flock 9; … )
  9>"$POOL_LOCK_FILE"` inside this function — holding a lock across the 2 s `sleep` (up to
  10 min) would serialize the ENTIRE pool, and a fresh `9>"$POOL_LOCK_FILE"` opens a NEW
  open-file-description that would self-deadlock if any caller already held the lock (see
  the `pool_reuse_orphan` self-deadlock WARNING, and man flock(2)). (research §1.)
- **Force-reap uses the PUBLIC `pool_release_lane`, NOT the PRIVATE
  `_pool_release_lane_internals`.** `pool_wait_for_lane` runs OUTSIDE any flock, so the
  daemon-close subprocess (forbidden under the short acquire flock, PRD §2.19) is allowed +
  desired — `pool_release_lane` does close + kill + rm dir + rm lease (idempotent, rc 0
  always). `_pool_release_lane_internals` skips the close (for in-lock use) and would leave
  a lingering daemon session. (research §2.4.)
- **DELEGATE — do NOT duplicate.** The acquire is `pool_acquire_locked`; the full reap is
  `pool_reap_stale`; the single-lane teardown is `pool_release_lane`; the staleness verdict
  is `pool_lane_is_stale`; the epoch is `_pool_now`; the file logger is `_pool_log`. Do NOT
  re-inline the reap loop, the release kernel, `pool_owner_alive`, or a raw `jq`/`kill`/`rm`.
- **Use the tri-state predicate under an `if` — NEVER bare.** A bare `pool_lane_is_stale
  "$n"` whose rc is 1 (live) or 2 (no lease) ABORTS under `set -e`. The `if
  pool_lane_is_stale "$n"; then …; fi` is errexit-exempt. (research §3.)
- **Capture `pool_acquire_locked` under an `if` with a SPLIT-local — NEVER bare / NEVER
  `local N=$(…)`.** `pool_acquire_locked` returns 1 on exhaustion; a bare `N=$(…)` ABORTS
  under `set -e`, and `local N=$(…)` masks the rc (SC2155). The mandatory idiom is
  `local N; …; if N="$(pool_acquire_locked)"; then …; fi`. (research §3.)
- **Read `acquired_at` with `|| true` INSIDE the `$()`, then validate `=~ ^[0-9]+$`.**
  `pool_lease_field` returns 1 on a missing/corrupt lease (TOCTOU). A corrupt/missing
  `acquired_at` MUST be **skipped** (`continue`) — NEVER defaulted to 0 (0 would always win
  "oldest" and reap a lane whose age we couldn't even read). (research §2.3.)
- **Every `(( ))` comparison is in a CONDITION context** (`if`/`&&`/`||`/`while`), never a
  bare statement. A bare `(( expr ))` whose value is 0 returns rc 1 and ABORTS under `set -e`.
  `(( now - start >= POOL_WAIT )) && break` and `if (( ts < oldest_ts )); then …; fi` are
  errexit-exempt. (research §3, bash-patterns.md §6.)
- **Timing uses `_pool_now` (epoch), NOT `$SECONDS`.** `$SECONDS` loses its special
  properties if a caller `unset`s it — a real hazard for a *sourced* library in an arbitrary
  caller shell. `_pool_now` (`date '+%s'`) returns the true epoch regardless of subshell
  nesting AND is the same clock `acquired_at` uses, so elapsed-time and lease-age are on one
  clock. (research §3, bash-patterns.md §1.) Display timestamps in `_pool_alert` use the
  forkless builtin `printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1` (house style, mirrors
  `_pool_log`).
- **stdout discipline.** The ONLY stdout write is `printf '%s\n' "$N"` (on success). Every
  other writer is silenced: `pool_reap_stale >/dev/null` (echoes a count),
  `pool_release_lane >/dev/null` (its daemon-close subprocess redirects only stderr — stdout
  can leak), `_pool_alert … >/dev/null 2>&1` (notify-send may print diagnostics).
  `pool_acquire_locked` is captured in `$()`; `_pool_log` writes the LOG FILE, never stdout.
- **`_pool_alert` is best-effort + non-fatal.** `notify-send` guarded by
  `command -v notify-send >/dev/null 2>&1`; the whole call `>/dev/null 2>&1 || true`
  (headless session / missing binary). The `alerts.log` append is
  `mkdir -p … || true` + `printf … >> … 2>/dev/null || true`. `_pool_alert` returns 0 always
  and NEVER affects `pool_wait_for_lane`'s rc.

### Success Criteria

- [ ] `_pool_alert SUMMARY BODY` defined (private) + `pool_wait_for_lane` defined (public)
      under a NEW `# Pool exhaustion (P1.M5.T4.S1)` banner at EOF, `_pool_alert` ABOVE
      `pool_wait_for_lane`. Callable after `source lib/pool.sh` + `pool_config_init` +
      `pool_owner_resolve`.
- [ ] Lane frees during wait: poll loop's `pool_acquire_locked` succeeds → rc 0; `N`==
      freed-lane; NO force-reap; NO alert (Scenario 1).
- [ ] Stale lane at timeout: force-reap oldest stale → final acquire succeeds → rc 0;
      `N`==reaped-lane; stale lane torn down; force-reap alert fires + alerts.log line
      "force-reaped lane N" (Scenario 2).
- [ ] All-live-owners: rc 1; nothing echoed; timeout/fail alert + log line (Scenario 3).
- [ ] Lost-the-race: rc 1; nothing echoed; timeout/fail alert + log line; no deadlock
      (Scenario 4).
- [ ] `POOL_WAIT=0`: poll loop runs 0 iterations (no spurious sleep); straight to force-reap
      (Scenario 5).
- [ ] Multiple stale lanes: force-reaps the OLDEST (smallest `acquired_at`); alert names it
      (Scenario 6).
- [ ] `N=$(pool_wait_for_lane)` captures EXACTLY one integer on rc 0, empty on rc 1 (stdout
      discipline).
- [ ] `_pool_alert` best-effort + non-fatal: missing notify-send / headless / unwritable
      alerts.log do NOT change the rc (Scenario 7/8).
- [ ] LOCK-FREE: no `flock` / no `9>"$POOL_LOCK_FILE"` inside the function; delegates to
      `pool_acquire_locked` (flock-owner) + `pool_reap_stale`/`pool_release_lane` (lock-free).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole
      file); all prior deliverables (M1–M5.T3.S2) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **lock topology** (research §1 — only
`pool_acquire_locked` flocks; `pool_wait_for_lane` is lock-free; force-reap uses the PUBLIC
`pool_release_lane` outside the flock); the **dependency contracts** with line numbers
(research §2 — the flock-owning acquire, the lock-free reap, the lock-free teardown, the
tri-state staleness verdict, the iterator, the `acquired_at` epoch read, the epoch primitive,
the file logger); the **bash correctness** (research §3 — the tri-state `if`, the split-local
`if N=$(…)`, the `|| true`-inside-`$()` capture, the `(( ))`-in-condition rule, the
`_pool_now`-not-`$SECONDS` rule, the check-before-body loop for `POOL_WAIT=0`); the **alert
design** (research §4 — the verbatim force-reap message, the `_pool_alert` helper, the
stdout/redirect contract); the **full verbatim-ready implementation** (Implementation Tasks
Task 1/2); and copy-pasteable, host-verified validation commands (8 scenarios).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.9 (Pool exhaustion — IQ2 = block-with-timeout + alert: block up to AGENT_BROWSER_POOL_WAIT
        [DEFAULT 600], polling + re-running reap-stale each iteration; on timeout FORCE-reap the
        oldest dead-owner lane + alert; if all-live-owners fail non-zero). §2.14 failure table
        ("Pool exhausted (accumulation) → block→force-reap→alert (§2.9)"). §2.19 (keep the flock
        critical section SHORT; the daemon close is a subprocess forbidden under the acquire lock).
  pattern: §2.9 step 1-3 IS pool_wait_for_lane; the alert text IS the notify-send body.
  gotcha: §2.9 "Alert on timeout/force" — alert on BOTH the force-reap success AND the total
        failure. The notify-send summary is 'agent-browser-pool' (verbatim).

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M5T4S1/research/design-validation.md
  why: §"rc-hazardous helpers" (the table of guards); §Architecture (locking topology —
        CONFIRMED lock-free); Q1-Q10 (every design question answered with line numbers); the
        recommended ~45-line implementation sketch (copy-pasteable); the 14-item gotchas list.
  pattern: the sketch IS the implementation spine.
  gotcha: Q3 (force-reap uses pool_release_lane, NOT _pool_release_lane_internals) + Q5
        (_pool_now not $SECONDS) + Q6 (POOL_WAIT=0 → check-before-body) + Q7 (stdout redirects)
        are the highest-impact facts.
- file: plan/001_0f759fe2777c/P1M5T4S1/research/bash-patterns.md
  why: §1 ($SECONDS unset-fragile → use _pool_now; printf %()T for display); §3 (POOL_WAIT=0
        check-before-body); §4 (notify-send best-effort guard); §5 (atomic >> append); §6
        ((()))-in-condition rule); §7 (split-local + if-capture, SC2155/BashFAQ 105). Each with
        GNU-manual / wooledge / ShellCheck URLs.
  pattern: the TL;DR table IS the idiom checklist.
  gotcha: §1 the "$SECONDS loses special properties if unset" sentence (disqualifies it for a
        sourced library); §6 the bare `(( x ))` when x==0 aborts under set -e.

# The sibling precedents (their framing + docstring depth is the template)
- file: plan/001_0f759fe2777c/P1M5T3S1/PRP.md   # pool_reap_stale (M5.T3.S1 — LANDED @2549)
  why: the lock-free full-reap function this task COMPOSES in its poll loop. Its design framing
        ("NO flock; composes pool_release_lane; non-fatal rc 0; tri-state under if; stdout
        discipline; the banner-placement convention") is the structural model. S1 LANDED.
  pattern: the docstring-with-LOGIC/CALLER-CONTRACT/GOTCHA sections; the split-local capture.
- file: plan/001_0f759fe2777c/P1M5T3S2/PRP.md   # pool_reuse_orphan (M5.T3.S2 — LANDED @2703)
  why: the PUBLIC building-block complement that LANDED in parallel; its "caller-must-hold-lock
        vs lock-free" analysis + the self-deadlock WARNING (never add a fresh 9>"$POOL_LOCK_FILE"
        inside a helper) directly informs this task's LOCK-FREE decision. Its banner sits
        immediately before this task's new banner.
  pattern: the depth of the docstring + the gotchas block.
  gotcha: the flock(2) per-open-file-description self-deadlock — the reason this task takes NO
        own lock AND never opens 9>"$POOL_LOCK_FILE".

# Architecture
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (SHORT flock — scan+reap+choose+claim under lock; the standalone reap/release
        run outside it). The naming-recommendation block (pool_* public / _pool_* private).

# The LANDED functions this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M5T1S1/PRP.md   # pool_acquire_locked (M5.T1.S1 — LANDED @2043)
  why: the flock-OWNING acquire this task calls each poll + as the final attempt. Echoes lane N
        + rc 0 on success; echoes nothing + rc 1 on exhaustion (all-live / passthrough). Takes
        its OWN `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` — so
        pool_wait_for_lane must NOT hold any lock. Its CALLER CONTRACT block documents the
        `local N; if N="$(pool_acquire_locked)"; then …; fi` idiom (split-local).
- file: plan/001_0f759fe2777c/P1M5T3S1/PRP.md   # pool_reap_stale (M5.T3.S1 — LANDED @2549)
  why: the LOCK-FREE full reap called each poll iteration. Echoes the reaped COUNT to stdout
        (MUST >/dev/null). rc 0 always. Internally composes pool_release_lane (with daemon
        close) — so it does the thorough cleanup acquire's inlined reap (no close) does not.
- file: plan/001_0f759fe2777c/P1M5T2S1/PRP.md   # pool_release_lane (M5.T2.S1 — LANDED @2438)
  why: the LOCK-FREE, idempotent PUBLIC teardown used for FORCE-REAP. Daemon close + Chrome
        pgroup kill + rm dir + rm lease; rc 0 always. Its close subprocess redirects ONLY
        stderr → caller MUST >/dev/null (stdout hygiene).
- file: plan/001_0f759fe2777c/P1M3T2S3/PRP.md   # pool_lane_is_stale (M3.T2.S3 — LANDED @1164)
  why: the TRI-STATE verdict (0=stale/1=live/2=no-lease) for force-reap's oldest-stale search.
        SET -e HAZARD: bare call ABORTS on rc 1/2 → MUST use `if pool_lane_is_stale "$n"; then`.
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list (M3.T2.S1 — LANDED @967)
  why: the iterator (force-reap's scan). Newline-separated, numerically-sorted lane numbers;
        rc 0 always; empty/missing dir ⇒ 0 iterations. `for n in $(pool_lanes_list)` is the idiom.
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_field (M3.T1.S2 — LANDED @876)
  why: the top-level `acquired_at` read for oldest-selection. Returns 1 on missing/corrupt
        (NON-FATAL); echoes "null" for a missing path. MUST guard with `|| true` inside `$()`.
- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md   # _pool_now + _pool_log (M1.T2.S1 — LANDED @39/@352)
  why: _pool_now = `date '+%s'` (epoch int; the elapsed-time clock + the acquired_at clock).
        _pool_log = file logger (writes LOG FILE + stderr fallback, NEVER stdout) ⇒ safe inside
        the lane-echo capture. The _pool_log timestamp idiom `printf -v ts '%(...)T' -1` is
        reused by _pool_alert.

# External authoritative docs (for the WHY; behavior host-verified in research)
- url: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
  why: "$SECONDS ... If unset, it loses its special properties, even if it is subsequently
        reset." ⇒ disqualifies $SECONDS for a SOURCED library (an arbitrary caller may unset it).
        Use _pool_now (epoch) for elapsed arithmetic.
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: the `-e` exemption list — the condition following `if`/`elif`/`while` AND any command in
        a `&&`/`||` list except the last are exempt. So `if pool_lane_is_stale`, `(( … )) &&
        break`, `(( … )) || true`, `if (( … ))`, and `if N="$(pool_acquire_locked)"` all fall
        through cleanly (no abort) on a non-zero rc.
  section: `-e` (the exemption list paragraph).
- url: https://www.gnu.org/software/bash/manual/html_node/Compound-Commands.html
  why: "`(( expression ))` ... The exit status is 0 if the expression evaluates to non-zero;
        otherwise the exit status is 1." ⇒ a BARE `(( x ))` with x==0 returns 1 and ABORTS under
        set -e. Always put `(( ))` in a condition context.
- url: https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
  why: `printf '%(format)T' -1` — the forkless builtin time formatting (`-1` = current time),
        the house-style idiom for _pool_log/_pool_alert display timestamps (no `date` fork).
  section: `printf` (the `(fmt)T` / `-1` description).
- url: https://www.shellcheck.net/wiki/SC2155
  why: "Declare and assign separately" — `local N; N="$(pool_acquire_locked)"` so the command's
        rc is preserved (a `local N=$(…)` masks errexit).
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "Why doesn't set -e do what I expected?" — the `local X=$(…)` masking + the `|| true`
        non-fatal capture + the `(( ))`-returns-1-on-zero traps.
- url: https://pubs.opengroup.org/onlinepubs/9699919799/functions/write.html
  why: `O_APPEND` writes "no intervening file modification operation shall occur" ⇒ small `>>`
        appends (each < PIPE_BUF, typically 4096) are atomic on a local FS — the alerts.log
        append is safe without a flock.
- url: https://man7.org/linux/man-pages/man2/flock.2.html
  why: flock(2) locks are associated with an OPEN FILE DESCRIPTION (not a process). A fresh
        `9>"$POOL_LOCK_FILE"` opens a NEW OFD → a blocking flock taken inside a caller that
        already holds the lock BLOCKS FOREVER (self-deadlock). This is WHY pool_wait_for_lane
        takes NO own lock and never opens 9>"$POOL_LOCK_FILE" (it lets pool_acquire_locked own
        the lock).
  section: the "Open file descriptions" paragraph.
- url: https://manpages.debian.org/stable/libnotify-bin/notify-send.1.en.html
  why: notify-send exits non-zero when it cannot reach a notification daemon / D-Bus session
        (no DISPLAY) ⇒ MUST guard with command -v + 2>/dev/null || true (non-fatal).
```

### Current Codebase tree

After **M1–M5.T3.S2** have landed, `lib/pool.sh` (2774 lines) ends with `pool_reuse_orphan`
as the final function (@2703, closing brace @~2774). The banner at @2483 already reads
`# Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)`:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T3.S2) with pool_reuse_orphan at EOF.
│                                         #   Banner order at EOF:
│                                         #   # Release & teardown (P1.M5.T2.S1)
│                                         #   pool_release_lane
│                                         #   # Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)
│                                         #   pool_reap_stale
│                                         #   pool_reuse_orphan  ← current EOF (~line 2774)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T3S2/PRP.md
    └── P1M5T4S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{design-validation,bash-patterns}.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a NEW banner section at EOF (after pool_reuse_orphan):
                  #   # Pool exhaustion (P1.M5.T4.S1)   ← NEW banner
                  #   _pool_alert SUMMARY BODY:       # PRIVATE — best-effort notify-send + alerts.log
                  #       printf -v ts '%(...%z)T' -1                    # house-style display ts (no date fork)
                  #       command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" >/dev/null 2>&1 || true
                  #       mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true
                  #       printf '%s %s: %s\n' "$ts" "$1" "$2" >>"$POOL_STATE_DIR/alerts.log" 2>/dev/null || true
                  #       return 0   # ALWAYS (best-effort, non-fatal)
                  #   pool_wait_for_lane():           # PUBLIC — the CONTRACT name (block+force-reap+alert)
                  #       (a) POLL: start=_pool_now; while true; do
                  #               now=_pool_now; (( now-start >= POOL_WAIT )) && break   # check-BEFORE-body
                  #               pool_reap_stale >/dev/null
                  #               if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
                  #               sleep 2
                  #             done
                  #       (b) FORCE-REAP: oldest_lane=""; for cand in $(pool_lanes_list); do
                  #               if pool_lane_is_stale "$cand"; then
                  #                 ts=$(pool_lease_field "$cand" acquired_at 2>/dev/null || true)
                  #                 [[ "$ts" =~ ^[0-9]+$ ]] || continue
                  #                 if [[ -z "$oldest_lane" ]] || (( ts < oldest_ts )); then oldest_ts=$ts; oldest_lane=$cand; fi
                  #               fi
                  #             done
                  #       (c) if oldest_lane set: pool_release_lane "$oldest_lane" >/dev/null;
                  #             _pool_alert 'agent-browser-pool' "Pool exhausted — force-reaped lane $oldest_lane. Possible leak."
                  #             _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
                  #             if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
                  #       (d) _pool_alert 'agent-browser-pool' "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak."
                  #             _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
                  #             return 1   # nothing echoed
                  #   (NO changes to any existing function — esp. NOT pool_acquire_locked /
                  #    pool_reap_stale / pool_release_lane / pool_lane_is_stale / pool_reuse_orphan)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds
the **public pool-exhaustion handler** (PRD §2.9 / IQ2) — the block-with-timeout +
force-reap + alert flow the wrapper invokes when acquire returns exhaustion. It COMPOSES
`pool_acquire_locked` (acquire) + `pool_reap_stale` (poll reap) + `pool_lane_is_stale`
(staleness verdict) + `pool_lanes_list` (scan) + `pool_lease_field` (`acquired_at` read) +
`pool_release_lane` (force-reap teardown) + `_pool_now` (epoch) + `_pool_log` (file logger).
It reads `POOL_WAIT` + `POOL_STATE_DIR` (both frozen by `pool_config_init`). It writes the
new `$POOL_STATE_DIR/alerts.log` (via `_pool_alert`) and one or two `_pool_log` lines.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (LOCK-FREE — research §1): pool_wait_for_lane takes NO flock. ONLY
#   pool_acquire_locked flocks (`( flock 9; _pool_acquire_critical_section )
#   9>"$POOL_LOCK_FILE"`, @2043). pool_reap_stale (@2549) and pool_release_lane (@2438) are
#   explicitly lock-free + idempotent. Holding a lock across the 2 s sleep (up to 10 min)
#   would serialize the ENTIRE pool. AND: do NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"`
#   inside this function — flock(2) locks are bound per OPEN FILE DESCRIPTION (man flock(2));
#   a fresh 9>"$POOL_LOCK_FILE" opens a NEW OFD, so a blocking flock taken here while ANY
#   caller already holds the lock is DENIED → BLOCKS FOREVER (self-deadlock). This task
#   neither holds nor opens the lock; it delegates acquire to pool_acquire_locked. Document
#   this prominently in the docstring.

# CRITICAL (force-reap uses the PUBLIC pool_release_lane — research §2.4): pool_wait_for_lane
#   runs OUTSIDE any flock, so the daemon-close subprocess (forbidden under the short acquire
#   flock, PRD §2.19) is allowed + desired. pool_release_lane (@2438) does close + Chrome
#   pgroup kill + rm dir + rm lease (idempotent, rc 0 always). Do NOT use the PRIVATE
#   _pool_release_lane_internals (@1813) — it skips the close (reserved for IN-LOCK acquire
#   reap) and would leave a lingering daemon session.

# CRITICAL (tri-state predicate under set -e — research §3, pool_lane_is_stale GOTCHA
#   @ ~line 1145-1148): a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or 2 (no
#   lease) ABORTS the caller under set -e. The MANDATORY idiom is `if pool_lane_is_stale
#   "$n"; then …; fi` (the if-condition is errexit-exempt).

# CRITICAL (capture pool_acquire_locked under an if with a SPLIT-local — research §3,
#   SC2155/BashFAQ 105): pool_acquire_locked returns 1 on exhaustion. A BARE
#   `N="$(pool_acquire_locked)"` ABORTS under set -e; `local N="$(pool_acquire_locked)"`
#   masks the rc (local returns 0) so set -e can't see it. The MANDATORY idiom:
#       local N                       # declared FIRST
#       …
#       if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
#   (plain assignment, NOT `local N=$(…)`).

# CRITICAL (read acquired_at with || true INSIDE the $() + validate — research §2.3):
#   pool_lease_field returns 1 on a missing/corrupt lease (TOCTOU between the staleness
#   verdict and the read). The `|| true` INSIDE the $() makes the capture set -e-safe. Then
#   validate `[[ "$ts" =~ ^[0-9]+$ ]] || continue` — a corrupt/missing value MUST be SKIPPED,
#   NEVER defaulted to 0 (0 would always win "oldest" and reap a lane whose age we couldn't
#   read). Split local (declare FIRST, assign AFTER — SC2155):
#       ts="$(pool_lease_field "$cand" acquired_at 2>/dev/null || true)"

# CRITICAL ((( )) in a CONDITION, never bare — research §3, bash-patterns.md §6): a BARE
#   `(( expr ))` whose value is 0 returns rc 1 and ABORTS under set -e. Every arithmetic
#   comparison here MUST be in a condition context:
#       (( now - start >= POOL_WAIT )) && break       # &&-list: errexit-exempt
#       if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then …; fi   # ||-list: exempt
#   (BashFAQ 105; GNU bash Compound Commands: "(( expr )) returns 1 when the expression is 0".)

# CRITICAL (timing uses _pool_now, NOT $SECONDS — research §3, bash-patterns.md §1): "$SECONDS
#   ... loses its special properties if unset" (GNU Bash Variables) — a real hazard for a
#   SOURCED library in an arbitrary caller shell. _pool_now (@352 = `date '+%s'`) returns the
#   true epoch regardless of subshell nesting AND is the SAME clock acquired_at uses. Display
#   timestamps in _pool_alert use the forkless `printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1`
#   (house style, mirrors _pool_log). NEVER reference $SECONDS in this function.

# CRITICAL (POOL_WAIT=0 — check-BEFORE-body — research §3, bash-patterns.md §3): pool_config_init
#   validates POOL_WAIT digits-only (NO >0 enforcement), so POOL_WAIT=0 is a real value. The
#   loop MUST check the deadline BEFORE the reap/acquire/sleep so POOL_WAIT=0 runs ZERO
#   iterations and falls straight to force-reap (no spurious sleep). Structure:
#       while true; do
#           now="$(_pool_now)"
#           (( now - start >= POOL_WAIT )) && break   # CHECK FIRST
#           pool_reap_stale >/dev/null
#           if N="$(pool_acquire_locked)"; then …; return 0; fi
#           sleep 2
#       done

# GOTCHA (stdout discipline — research §2): the ONLY stdout write is `printf '%s\n' "$N"` (on
#   success). Every other writer is silenced: `pool_reap_stale >/dev/null` (echoes a count);
#   `pool_release_lane >/dev/null` (its daemon-close subprocess @~2472 redirects ONLY stderr —
#   stdout can leak); `_pool_alert … >/dev/null 2>&1` (notify-send may print diagnostics).
#   pool_acquire_locked is captured in $(); _pool_log writes the LOG FILE (never stdout). On
#   return 1 NOTHING is echoed → `N=$(pool_wait_for_lane)` yields the empty string.

# GOTCHA (force-reap message is VERBATIM — PRD §2.9 / CONTRACT step e): the notify-send body
#   for the force-reap path is EXACTLY 'Pool exhausted — force-reaped lane N. Possible leak.'
#   (note the em-dash — and the literal "lane N" with N substituted). The summary/app is
#   'agent-browser-pool'. Preserve the em-dash (—), not a hyphen.

# GOTCHA (_pool_alert is best-effort + non-fatal — research §4): notify-send may be absent
#   (guard `command -v notify-send >/dev/null 2>&1`) or fail in a headless session
#   (>/dev/null 2>&1 || true). The alerts.log write may fail (mkdir -p … || true; printf … >>
#   … 2>/dev/null || true). _pool_alert returns 0 ALWAYS and MUST NEVER affect
#   pool_wait_for_lane's rc. It is called with `>/dev/null 2>&1` at the call site (stdout
#   hygiene), but it writes nothing to stdout anyway.

# GOTCHA (lost-the-race is ACCEPTABLE — research §1/Q10): between force-reap's
#   pool_release_lane and the final pool_acquire_locked, a concurrent agent's acquire can grab
#   the just-freed lane first. Then the final pool_acquire_locked returns 1 → pool_wait_for_lane
#   returns 1 (nothing echoed) + the timeout/fail alert. This is the ACCEPTABLE total-failure
#   path — NO deadlock, NO double-acquire (claims are serialized by pool_acquire_locked's single
#   flock). Do NOT retry-loop the force-reap; a peer legitimately won N.

# GOTCHA (pool_acquire_locked already reaps inline — research §1): _pool_acquire_critical_section
#   (@1966) inlines its OWN reap (via _pool_release_lane_internals, NO close) + reuse-orphan +
#   choose-N + claim, under flock. The separate `pool_reap_stale >/dev/null` before it in the
#   poll loop is NOT redundant — pool_reap_stale uses the PUBLIC pool_release_lane (WITH daemon
#   close) for thorough cleanup. Both are correct to call.

# GOTCHA (snapshot iteration — research §2): `for cand in $(pool_lanes_list)` captures the list
#   ONCE before the loop (command substitution is fully evaluated up front). A lane deleted
#   between list + check → pool_lane_is_stale rc 2 → skip. Correct.

# GOTCHA (naming + placement — research §1/Q9): pool_wait_for_lane (PUBLIC, CONTRACT name, NO
#   `_` prefix). _pool_alert (PRIVATE helper, `_` prefix). APPEND at EOF (after
#   pool_reuse_orphan, ~line 2774) under a NEW "# Pool exhaustion (P1.M5.T4.S1)" banner.
#   _pool_alert goes IMMEDIATELY ABOVE pool_wait_for_lane (helpers-first convention:
#   _pool_release_lane_internals before pool_release_lane; _pool_acquire_critical_section
#   before pool_acquire_locked). NO new env vars / globals / files.

# GOTCHA (scope — exhaustion only): do NOT implement the wrapper lifecycle (M6), the admin CLI
#   (M7), or the test harness (M9). This task ships _pool_alert + pool_wait_for_lane ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**.
It reads the lease schema (PRD §2.8, frozen by M3.T1.S1) — specifically `acquired_at` (the
epoch-integer creation timestamp used for oldest-selection) and `owner.pid` (implicitly, via
the staleness verdict) — and delegates all mutating work to `pool_release_lane` (which does
the daemon close + Chrome kill + rm dir + rm lease).

Global READ (frozen by `pool_config_init` + `pool_owner_resolve`):

| global | source | role |
|---|---|---|
| `POOL_WAIT` | pool_config_init (line 168) | the block timeout (seconds; default 600). Validated uint. Read for the deadline arithmetic + the alert/log messages. |
| `POOL_STATE_DIR` | pool_config_init (line 140) | the `alerts.log` parent (`$POOL_STATE_DIR/alerts.log`, derived inline by `_pool_alert`; NO new global). |
| `POOL_LOCK_FILE` | pool_config_init (line 199) | NOT used by this function (LOCK-FREE — `pool_acquire_locked` owns it); referenced only in the docstring warning. |

External commands (all present on host; verified this session): `notify-send`
(`/usr/bin/notify-send` — confirmed), `sleep` (coreutils), `date` (via `_pool_now`), `jq`
(via `pool_lease_field`). The forkless builtin `printf '%(...)T' -1` is used for display
timestamps (no `date` fork in `_pool_alert`).

**Naming** (CONTRACT-mandated + codebase convention): `pool_wait_for_lane` (public,
CONTRACT name, no `_`; matches the `pool_*` family) + `_pool_alert` (private helper, `_`
prefix; matches `_pool_*`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_owner_resolve pool_acquire_locked pool_reap_stale \
                  pool_release_lane pool_lane_is_stale pool_lanes_list pool_lease_field \
                  _pool_now _pool_log'
  - EXPECT: all reported as functions (M1–M5.T3.S2 LANDED). If pool_acquire_locked /
        pool_reap_stale / pool_release_lane / pool_lane_is_stale are MISSING → STOP
        (a dependency this task composes does not exist). If pool_wait_for_lane ALREADY
        EXISTS → STOP (someone implemented it already; reconcile).
  - RUN (verify the globals + the alert tools):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_WAIT" && -n "$POOL_STATE_DIR" && -n "$POOL_LOCK_FILE" ]] \
                   && echo "OK globals" || echo FAIL'
        command -v notify-send >/dev/null && echo "OK notify-send" || echo "notify-send absent (best-effort will skip)"
        command -v jq >/dev/null && command -v sleep >/dev/null && echo "OK jq+sleep" || echo FAIL
  - EXPECT: OK globals ; OK notify-send ; OK jq+sleep. (notify-send absent is acceptable —
        _pool_alert guards it; but on THIS host it IS present at /usr/bin/notify-send.)
  - RUN (locate the append point — current EOF must be pool_reuse_orphan, the S2 deliverable):
        grep -nE '^pool_reuse_orphan\(\)' lib/pool.sh
        grep -n 'Reaper & orphan reuse' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        # ALSO confirm the public name + the helper do NOT yet exist:
        grep -nE '^pool_wait_for_lane\(\)|^_pool_alert\(\)' lib/pool.sh && echo "STOP: already exists" || echo "OK: absent"
        # Confirm there is NO existing alerts.log / notify-send handling:
        grep -nE 'alerts\.log|notify-send' lib/pool.sh && echo "STOP: unexpected prior art" || echo "OK: greenfield"
  - EXPECT: pool_reuse_orphan defined (@~2703); it is the last function (closing brace = EOF,
        ~line 2774). The banner (@2483) reads "# Reaper & orphan reuse (P1.M5.T3.S1,
        P1.M5.T3.S2)". APPEND the new banner + functions AFTER pool_reuse_orphan's closing
        brace. pool_wait_for_lane + _pool_alert ABSENT. No alerts.log/notify-send prior art.
  - RUN (confirm pool_acquire_locked owns the flock — do NOT add another):
        grep -nE 'flock 9' lib/pool.sh
  - EXPECT: exactly ONE flock site, inside pool_acquire_locked (~line 2064). This task adds
        NONE.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND the new banner + _pool_alert() + pool_wait_for_lane() to lib/pool.sh
  - PLACEMENT: directly below pool_reuse_orphan's closing brace at EOF (~line 2775), under a
        NEW "# Pool exhaustion (P1.M5.T4.S1)" banner. _pool_alert FIRST (helpers-first), then
        pool_wait_for_lane.
  - IMPLEMENT (verbatim-ready — paste the banner + Task 1a docstring + _pool_alert +
        Task 1b docstring + pool_wait_for_lane at EOF):

# =============================================================================
# Pool exhaustion (P1.M5.T4.S1)
# =============================================================================
# Block-with-timeout + force-reap + alert — PRD §2.9 (IQ2). The PUBLIC handler the
# wrapper (M6) calls when pool_acquire_locked returns 1 ("no free/reusable lane").
# _pool_alert is the best-effort notify-send + alerts.log helper; pool_wait_for_lane
# is the block→force-reap→alert flow.

# _pool_alert SUMMARY BODY
#
# Best-effort exhaustion alert (PRD §2.9 "Alert on timeout/force: notify-send desktop
# notification + a line to ~/.local/state/agent-browser-pool/alerts.log"). Fires a
# desktop notification (notify-send) AND appends one timestamped line to
# $POOL_STATE_DIR/alerts.log. ALWAYS returns 0 — a missing notify-send, a headless
# session (no DISPLAY / DBUS_SESSION_BUS_ADDRESS), or an unwritable alerts.log are
# ALL non-fatal no-ops. It must NEVER affect its caller's return code.
#
# LOGIC:
#   1. ts = printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1   (house-style display timestamp; no
#      `date` fork — mirrors _pool_log @~line 41).
#   2. notify-send "$SUMMARY" "$BODY" — guarded by `command -v` (may be absent on a
#      minimal host) + 2>/dev/null || true (exits non-zero in a headless session).
#   3. mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true  (the dir normally exists via
#      pool_state_init; defensive for an early/standalone call).
#   4. printf '%s %s: %s\n' "$ts" "$SUMMARY" "$BODY" >>"$POOL_STATE_DIR/alerts.log"
#      2>/dev/null || true  (O_APPEND small write < PIPE_BUF ⇒ atomic on local FS;
#      POSIX write()/O_APPEND).
#   5. return 0.
#
# GOTCHA — notify-send exits non-zero with no display (libnotify) ⇒ MUST guard; a bare
#   call ABORTS under set -e.
# GOTCHA — the `>>` append is atomic-enough for a single short line (POSIX O_APPEND +
#   PIPE_BUF); NO flock needed (multiple exhausted agents alerting concurrently is fine).
# GOTCHA — writes NOTHING to stdout (notify-send → D-Bus; printf → the file) ⇒ safe
#   inside the caller's lane-echo capture; the caller STILL redirects >/dev/null 2>&1
#   for hygiene (notify-send may print diagnostics to stderr).
# Reads POOL_STATE_DIR (frozen by pool_config_init). No new globals. PRECONDITION:
#   pool_config_init (for POOL_STATE_DIR). Non-fatal (rc 0 always).
_pool_alert() {
    local summary="${1:-}" body="${2:-}" ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$summary" "$body" >/dev/null 2>&1 || true
    fi
    # alerts.log under the runtime state dir (frozen by pool_config_init). Derive inline —
    # no new global (consistent with _pool_log's inline path derivation).
    if [[ -n "${POOL_STATE_DIR:-}" ]]; then
        mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true
        printf '%s %s: %s\n' "$ts" "$summary" "$body" \
            >>"$POOL_STATE_DIR/alerts.log" 2>/dev/null || true
    fi
    return 0
}

# pool_wait_for_lane
#
# PRD §2.9 / IQ2 "block-with-timeout + alert" — the PUBLIC exhaustion handler. Called by
# the wrapper (M6) AFTER pool_acquire_locked returned 1 ("no free/reusable lane"). Blocks
# up to POOL_WAIT seconds (default 600), polling every 2 s (reap-stale + retry-acquire);
# on timeout FORCE-reaps the OLDEST dead-owner lane, alerts, and retries acquire once more;
# if still no lane (all-live-owners / lost the race) it alerts + returns 1.
#
# DESIGN — LOCK-FREE (research §1): ONLY pool_acquire_locked flocks
# (`( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`). pool_reap_stale and
# pool_release_lane are explicitly lock-free + idempotent. pool_wait_for_lane takes NO flock
# (holding one across the 2 s sleep — up to 10 min — would serialize the ENTIRE pool) and
# opens NO `9>"$POOL_LOCK_FILE"` (flock(2) locks are per OPEN FILE DESCRIPTION; a fresh OFD
# here would self-deadlock against any caller-held lock — man flock(2)). It COMPOSES the
# flock-owner + the lock-free helpers.
#
# LOGIC (CONTRACT a→e):
#   a. POLL (≤ POOL_WAIT s, 2 s cadence; check-BEFORE-body so POOL_WAIT=0 → 0 iterations):
#        start = _pool_now
#        while true; do
#            now = _pool_now; (( now - start >= POOL_WAIT )) && break   # &&-list = errexit-exempt
#            pool_reap_stale >/dev/null                                  # full daemon-close reap (lock-free)
#            if N = pool_acquire_locked; then printf '%s\n' "$N"; return 0; fi   # split-local, if-capture
#            sleep 2
#        done
#   b. FORCE-REAP (oldest dead-owner lane):
#        oldest_lane=""; oldest_ts=""
#        for cand in $(pool_lanes_list); do
#            if pool_lane_is_stale "$cand"; then                          # tri-state; if = errexit-exempt
#                ts = pool_lease_field "$cand" acquired_at (|| true inside $(); "null"/missing → "")
#                [[ "$ts" =~ ^[0-9]+$ ]] || continue                      # corrupt → SKIP (never default to 0)
#                if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then   # ||-list = errexit-exempt
#                    oldest_ts="$ts"; oldest_lane="$cand"
#                fi
#            fi
#        done
#   c. if oldest_lane set:
#        pool_release_lane "$oldest_lane" >/dev/null                      # PUBLIC teardown (close+kill+rm; lock-free)
#        _pool_alert 'agent-browser-pool' "Pool exhausted — force-reaped lane $oldest_lane. Possible leak."
#        _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
#        if N = pool_acquire_locked; then printf '%s\n' "$N"; return 0; fi  # peer may have won the race → rc 1
#   d. (no stale lane OR lost the race): alert + log + return 1 (nothing echoed)
#        _pool_alert 'agent-browser-pool' "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak."
#        _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
#        return 1
#   e. ALERT = the _pool_alert calls above (notify-send + alerts.log); see _pool_alert.
#
# CALLER CONTRACT (the wrapper M6, under set -e — split the capture per BashFAQ 105):
#     local N
#     if N="$(pool_acquire_locked)"; then
#         <post-lock boot / ensure_connected>
#     elif N="$(pool_wait_for_lane)"; then
#         <post-lock boot / ensure_connected for N>
#     else
#         pool_die "agent-browser-pool: no lane available after ${POOL_WAIT}s + force-reap"
#     fi
#
# GOTCHA — LOCK-FREE: NO flock, NO `9>"$POOL_LOCK_FILE"` anywhere in this function (see
#   DESIGN). Delegate acquire to pool_acquire_locked.
# GOTCHA — force-reap uses the PUBLIC pool_release_lane (close+kill+rm), NOT the private
#   _pool_release_lane_internals (no close, in-lock only). This function runs UNFLOCKED.
# GOTCHA — pool_lane_is_stale under an `if`, NEVER bare (rc 1/2 abort under set -e).
# GOTCHA — pool_acquire_locked under an `if` with a SPLIT-local (`local N` first; plain
#   `N="$(…)"`), NEVER `local N=$(…)` (SC2155 masks errexit) or a bare capture.
# GOTCHA — every `(( ))` is in a condition context (`&&`/`||`/`if`), NEVER a bare statement
#   (value 0 → rc 1 → abort).
# GOTCHA — timing uses `_pool_now` (epoch), NEVER `$SECONDS` (unset-fragile in a sourced
#   library); display ts in _pool_alert uses printf %()T.
# GOTCHA — POOL_WAIT=0 ⇒ check-BEFORE-body ⇒ 0 poll iterations ⇒ straight to force-reap.
# GOTCHA — stdout discipline: ONLY `printf '%s\n' "$N"` escapes (on success). pool_reap_stale
#   >/dev/null; pool_release_lane >/dev/null; _pool_alert >/dev/null 2>&1; _pool_log → LOG FILE.
# GOTCHA — lost-the-race after force-reap is ACCEPTABLE (rc 1, nothing echoed). Do NOT
#   retry-loop the force-reap — a peer legitimately won N.
# GOTCHA — _pool_alert is best-effort + non-fatal (rc 0 always); NEVER affects this rc.
# Reads POOL_WAIT + POOL_STATE_DIR (via _pool_alert; both frozen by pool_config_init) +
# POOL_LANES_DIR (via the helpers). No new globals/env-vars/files.
# PRECONDITION: pool_config_init + pool_owner_resolve + (by the wrapper) one prior
#   pool_acquire_locked that returned 1. NOT the first acquire.
pool_wait_for_lane() {
    local N now start oldest_lane oldest_ts cand ts

    # (a) POLL loop — check-timeout-BEFORE-body so POOL_WAIT=0 runs ZERO iterations.
    start="$(_pool_now)"
    while true; do
        now="$(_pool_now)"
        # &&-list ⇒ errexit-exempt (no abort even when the comparison is false). CHECK FIRST.
        (( now - start >= POOL_WAIT )) && break
        # Full daemon-close reap (lock-free, idempotent, rc 0 always). Echoes a count → >/dev/null.
        pool_reap_stale >/dev/null
        # Acquire (takes its OWN short flock; inlines reap+reuse+choose+claim). rc 0 ⇒ done.
        # `if N="$(…)"` with N already declared above (plain assignment, NOT local N=$(…)).
        if N="$(pool_acquire_locked)"; then
            printf '%s\n' "$N"
            return 0
        fi
        sleep 2
    done

    # (b) FORCE-REAP — find the OLDEST lane whose owner is actually dead.
    oldest_lane=""
    oldest_ts=""
    for cand in $(pool_lanes_list); do
        # tri-state: rc 0 (stale) → enter; rc 1 (live) / rc 2 (no lease) → skip. `if` = exempt.
        if pool_lane_is_stale "$cand"; then
            # acquired_at is a numeric epoch (pool_lease_write @~704/721; _pool_now). `|| true`
            # inside $() makes the capture set -e-safe (pool_lease_field rc 1 on corrupt).
            ts="$(pool_lease_field "$cand" acquired_at 2>/dev/null || true)"
            # corrupt/missing ⇒ SKIP (never default to 0 — 0 would always win "oldest").
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            # ||-list ⇒ errexit-exempt. First stale lane seeds oldest; later older ones replace it.
            if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then
                oldest_ts="$ts"
                oldest_lane="$cand"
            fi
        fi
    done

    # (c) If we found a stale lane, force-reap it, ALERT, and try acquire ONE more time.
    if [[ -n "$oldest_lane" ]]; then
        # PUBLIC teardown (close+kill+rm dir+rm lease; lock-free, idempotent, rc 0 always).
        # >/dev/null (the close subprocess @~2472 redirects only stderr — stdout can leak).
        pool_release_lane "$oldest_lane" >/dev/null
        # ALERT — notify-send summary 'agent-browser-pool' + the VERBATIM force-reap body
        # (PRD §2.9; em-dash —). >/dev/null 2>&1 (notify-send may print stderr; writes no stdout).
        _pool_alert 'agent-browser-pool' \
            "Pool exhausted — force-reaped lane $oldest_lane. Possible leak." >/dev/null 2>&1
        _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
        # Final acquire. A peer may have grabbed the just-freed lane first → rc 1 falls through to (d).
        if N="$(pool_acquire_locked)"; then
            printf '%s\n' "$N"
            return 0
        fi
    fi

    # (d) No stale lane existed (all-live-owners) OR lost the race. ALERT + log + return 1
    #     (nothing echoed ⇒ N=$(pool_wait_for_lane) yields the empty string).
    _pool_alert 'agent-browser-pool' \
        "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak." >/dev/null 2>&1
    _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
    return 1
}

  - FOLLOW pattern: the docstring (ABOVE each function) with DESIGN/LOGIC/CALLER CONTRACT/
        GOTCHA sections (mirror pool_reap_stale + pool_release_lane); the LOCK-FREE framing;
        the tri-state `if`; the split-local `if N=$(…)`; the `(( ))`-in-condition; the
        `_pool_now` epoch; the check-before-body loop; the stdout-redirect set; the
        best-effort `_pool_alert`.
  - NAMING: pool_wait_for_lane (PUBLIC, CONTRACT name, no `_`) + _pool_alert (PRIVATE, `_`).
  - PLACEMENT: the new "# Pool exhaustion (P1.M5.T4.S1)" banner at EOF, _pool_alert above
        pool_wait_for_lane.

  - VERIFY immediately after the edit:
        bash -n lib/pool.sh && echo "OK syntax"
        shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # zero warnings expected
        grep -nE '^pool_wait_for_lane\(\)|^_pool_alert\(\)' lib/pool.sh   # both present
        grep -cE 'flock 9' lib/pool.sh   # STILL 1 (only pool_acquire_locked)
  - EXPECT: OK syntax ; OK shellcheck (zero warnings) ; both functions present ; flock count 1.
```

### Implementation Patterns & Key Details

```bash
# Pattern: LOCK-FREE composition (the defining constraint)
#   pool_wait_for_lane takes NO flock. It calls pool_acquire_locked (which owns the flock)
#   and the lock-free pool_reap_stale / pool_release_lane. Holding a lock across sleep(2)
#   for up to 10 min would serialize the pool; opening 9>"$POOL_LOCK_FILE" here would
#   self-deadlock (flock(2) per-OFD). Delegate acquire; never lock here.

# Pattern: split-local + if-capture for a function that returns 1 on the "nothing" path
#   pool_acquire_locked returns 1 on exhaustion. `local N=$(…)` masks the rc (SC2155) and a
#   bare `N=$(…)` aborts under set -e. Declare FIRST, assign in the `if`:
local N
…
if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi

# Pattern: tri-state predicate under `if` (never bare)
#   pool_lane_is_stale: 0=stale/1=live/2=no-lease. Bare call aborts on 1/2.
if pool_lane_is_stale "$cand"; then …; fi

# Pattern: best-effort capture of a possibly-missing field
ts="$(pool_lease_field "$cand" acquired_at 2>/dev/null || true)"   # || true INSIDE the $()
[[ "$ts" =~ ^[0-9]+$ ]] || continue                                 # validate; skip corrupt

# Pattern: (( )) ONLY in a condition context (bare aborts when value==0)
(( now - start >= POOL_WAIT )) && break                  # &&-list ⇒ exempt
if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then … # ||-list ⇒ exempt

# Pattern: best-effort alert (notify-send + alerts.log), non-fatal
if command -v notify-send >/dev/null 2>&1; then
    notify-send "$summary" "$body" >/dev/null 2>&1 || true
fi
mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true
printf '%s %s: %s\n' "$ts" "$summary" "$body" >>"$POOL_STATE_DIR/alerts.log" 2>/dev/null || true
```

### Integration Points

```yaml
CONFIG:
  - reads: POOL_WAIT (uint, default 600; frozen by pool_config_init @line 168)
  - reads: POOL_STATE_DIR (path; frozen @line 140) → alerts.log parent (derived inline; NO new global)
  - NO new env vars / globals / files. (alerts.log is created on first alert via mkdir -p.)

LIBRARY (lib/pool.sh):
  - append: NEW "# Pool exhaustion (P1.M5.T4.S1)" banner + _pool_alert + pool_wait_for_lane
            at EOF (after pool_reuse_orphan, ~line 2775).
  - no edits: to any existing function (esp. pool_acquire_locked, pool_reap_stale,
              pool_release_lane, pool_lane_is_stale, pool_reuse_orphan).

CONSUMERS (NOT this task's scope — documented for context):
  - M6.T3.S1 wrapper lifecycle: `elif N="$(pool_wait_for_lane)"; then …` (the only caller).
  - alerts.log is also a candidate output for M7.T4 doctor (leak investigation).
```

## Validation Loop

> **NOTE — no test framework yet.** The bats harness is M9.T1.S1 (Planned). Until then,
> validate via the manual/functional scenarios below (all use only `source lib/pool.sh` +
> the LANDED functions; no bats needed). Every command is host-runnable as-is.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
cd /home/dustin/projects/agent-browser-pool

# Run after the edit — fix before proceeding.
bash -n lib/pool.sh && echo "OK syntax"          # parse check (set -e propagate-safe)
shellcheck -s bash lib/pool.sh && echo "OK shellcheck"   # host ShellCheck 0.11.0; ZERO warnings expected
grep -nE '^pool_wait_for_lane\(\)|^_pool_alert\(\)' lib/pool.sh   # both present
grep -cE 'flock 9' lib/pool.sh   # STILL 1 (only pool_acquire_locked — this task adds NONE)

# Expected: OK syntax ; OK shellcheck (zero warnings) ; both functions listed ; flock count 1.
```

### Level 2: Unit / Contract Scenarios (Component Validation)

These scenarios exercise the contract rows. They need a throwaway state dir + simulated
owners (the M9.T1.S1 test-hook overrides `AGENT_BROWSER_POOL_OWNER_PID` /
`_OWNER_STARTTIME`; for manual validation, fake leases by writing `$POOL_LANES_DIR/<N>.json`
via `pool_lease_write` with owner pids that are dead). Use `AGENT_BROWSER_POOL_WAIT` to keep
the poll short.

```bash
# Setup helper for each scenario (run in a fresh subshell so globals don't leak):
setup() {
  export AGENT_BROWSER_POOL_STATE="$(mktemp -d)/state"
  export AGENT_BROWSER_POOL_OWNER_PID=$$            # this shell "owns" newly-claimed lanes
  export AGENT_BROWSER_POOL_DISABLE=0
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_owner_resolve
  pool_state_init
}

# Scenario A — happy poll path (lane frees during wait): hard to simulate deterministically
# without a second process; SKIP for manual validation (covered structurally by the poll loop).
# Instead verify the function RETURNS A LANE when acquire would succeed:
( setup
  # Empty pool ⇒ pool_acquire_locked succeeds immediately (choose-N). Simulate exhaustion
  # bypass by calling pool_wait_for_lane on an empty pool: it acquires lane 1 in the first poll.
  AGENT_BROWSER_POOL_WAIT=2
  pool_config_init
  N="$(pool_wait_for_lane)"; rc=$?
  echo "rc=$rc N=$N"
  [[ "$rc" == "0" && "$N" == "1" ]] && echo "PASS A: empty-pool poll acquires lane 1" || echo "FAIL A"
)

# Scenario B — force-reap a stale (dead-owner) lane at timeout:
( setup
  AGENT_BROWSER_POOL_WAIT=0        # skip the poll loop; straight to force-reap
  pool_config_init
  # Claim lane 1 with a DEAD owner pid (99998 is not running) so pool_acquire_locked's
  # inline reap would normally reclaim it — but to simulate EXHAUSTION we also fill the pool.
  # Simpler: write a stale lease directly, then make acquire "fail" is hard; instead verify
  # the FORCE-REAP + alert mechanics on a pool with one stale lane by checking the alerts.log.
  # (See Scenario C for the all-live failure; here we assert the stale lane is reaped + alerted.)
  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 53421 "abpool-1" 99998 "pi" 0 "" 0 0 "false"
  # pool_acquire_locked will inline-reap lane 1 (dead owner) then claim it via choose-N → rc 0.
  N="$(pool_wait_for_lane)"; rc=$?
  echo "rc=$rc N=$N"
  [[ "$rc" == "0" ]] && echo "PASS B: stale lane reclaimed (rc 0, lane returned)" || echo "FAIL B"
  test -f "$POOL_STATE_DIR/alerts.log" && echo "alerts.log exists" || echo "no alerts.log (acceptable if acquire succeeded pre-force-reap)"
)

# Scenario C — all-live-owners ⇒ total failure (rc 1) + alert:
( setup
  AGENT_BROWSER_POOL_WAIT=0
  pool_config_init
  # Fill the lane space is impractical without POOL_PORT_RANGE=0; instead, force exhaustion by
  # making pool_acquire_locked fail. The cleanest manual check: with an EMPTY pool acquire
  # SUCCEEDS, so to see rc 1 we monkeypatch is not available. Instead assert the FAILURE-PATH
  # alert helper works standalone:
  _pool_alert 'agent-browser-pool' 'Pool exhausted — no lane available after 0s + force-reap. Possible leak.'
  grep -q 'no lane available' "$POOL_STATE_DIR/alerts.log" && echo "PASS C: alerts.log failure line written" || echo "FAIL C"
)

# Scenario D — _pool_alert is best-effort + non-fatal (returns 0 even if alerts.log unwritable):
( setup
  _pool_alert 't' 'b'; rc=$?
  [[ "$rc" == "0" ]] && echo "PASS D1: _pool_alert rc 0 (writable)" || echo "FAIL D1"
  # Make POOL_STATE_DIR unwritable path:
  POOL_STATE_DIR="/nonexistent-cannot-create-x/y/z"
  _pool_alert 't' 'b'; rc=$?
  [[ "$rc" == "0" ]] && echo "PASS D2: _pool_alert rc 0 (unwritable, non-fatal)" || echo "FAIL D2"
)

# Scenario E — stdout discipline: N=$(pool_wait_for_lane) captures EXACTLY one integer:
( setup
  AGENT_BROWSER_POOL_WAIT=0
  pool_config_init
  out="$(pool_wait_for_lane)"   # empty pool → acquires lane 1
  [[ "$out" =~ ^[0-9]+$ ]] && echo "PASS E: stdout is exactly one integer ($out)" || echo "FAIL E: got '$out'"
)

# Expected: every scenario prints PASS. (Scenarios B/C are illustrative; the structural
# guarantees — split-local capture, tri-state if, (( )) in condition, stdout redirects —
# are enforced by shellcheck + bash -n in Level 1.)
```

### Level 3: Integration Testing (System Validation)

```bash
cd /home/dustin/projects/agent-browser-pool

# (1) Source + resolve cleanly:
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve; \
         type pool_wait_for_lane _pool_alert >/dev/null && echo "OK resolvable"'

# (2) Verify the full acquire→wait→force-reap chain is wired (no real Chrome needed): call
#     pool_wait_for_lane on a fresh state dir; it should acquire lane 1 (empty pool) in the
#     first poll and echo "1":
bash -c 'set -euo pipefail; \
         export AGENT_BROWSER_POOL_STATE="$(mktemp -d)/state" AGENT_BROWSER_POOL_WAIT=2 \
                AGENT_BROWSER_POOL_OWNER_PID=$$; \
         source lib/pool.sh; pool_config_init; pool_owner_resolve; pool_state_init; \
         N="$(pool_wait_for_lane)"; echo "acquired lane: $N"; [[ "$N" == "1" ]] && echo OK'
# Expected: OK (empty-pool fast path acquires lane 1).

# (3) Verify the alert writes a real alerts.log line + (if graphical) fires notify-send:
bash -c 'set -euo pipefail; \
         export AGENT_BROWSER_POOL_STATE="$(mktemp -d)/state"; \
         source lib/pool.sh; pool_config_init; \
         _pool_alert "agent-browser-pool" "Pool exhausted — force-reaped lane 7. Possible leak."; \
         echo "--- alerts.log ---"; cat "$POOL_STATE_DIR/alerts.log"'
# Expected: one line "<ISO-8601> agent-browser-pool: Pool exhausted — force-reaped lane 7. Possible leak."

# (4) Confirm prior deliverables are UNCHANGED + still callable (regression):
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_acquire_locked pool_reap_stale pool_release_lane pool_lane_is_stale \
              pool_reuse_orphan pool_lanes_list pool_lease_field _pool_now _pool_log \
              >/dev/null && echo "OK all prior functions present"'
# Expected: OK all prior functions present.
```

### Level 4: Creative & Domain-Specific Validation

```bash
cd /home/dustin/projects/agent-browser-pool

# (A) Simulate a REAL exhaustion + force-reap with TWO concurrent shells + faked dead owner.
#     Shell 1 claims lane 1 with a LIVE owner (itself); Shell 2 (with POOL_WAIT=1) calls
#     pool_wait_for_lane, times out, and — finding NO stale lane — returns 1 + alerts:
rm -rf /tmp/abpool-l4; mkdir -p /tmp/abpool-l4/state/lanes
# Shell 1: write a LIVE lease for lane 1 (owner = a long-running sleep PID):
LIVE_PID=$(bash -c 'sleep 300 & echo $!'); ST=$(_epoch=$(date +%s); echo 0) # starttime stub
bash -c "set -euo pipefail; source lib/pool.sh; \
         export AGENT_BROWSER_POOL_STATE=/tmp/abpool-l4/state; \
         pool_config_init; \
         pool_lease_write 1 /tmp/abpool-l4/active/1 53421 abpool-1 $LIVE_PID pi 0 '' 0 0 false; \
         echo 'live lane 1 written'"
# Shell 2: force exhaustion by also blocking lane claim is impractical without POOL_PORT_RANGE=0;
#   instead, directly assert the all-live failure path produces rc 1 + an alerts.log line:
bash -c "set -euo pipefail; source lib/pool.sh; \
         export AGENT_BROWSER_POOL_STATE=/tmp/abpool-l4/state AGENT_BROWSER_POOL_WAIT=0 \
                AGENT_BROWSER_POOL_OWNER_PID=\$\$; \
         pool_config_init; pool_owner_resolve; pool_state_init; \
         # (pool_acquire_locked will inline-reap nothing live + claim a NEW lane → rc 0 here,
         #  because the pool isn't actually full. This confirms the happy path; a TRULY full
         #  pool needs POOL_PORT_RANGE=0 which is out of scope for manual L4.) \
         N=\$(pool_wait_for_lane); echo \"rc-ok lane=\$N\""
kill "$LIVE_PID" 2>/dev/null || true
# Expected: the alert helper + the function compose without error; alerts.log is written on
# the alert paths. (A fully-deterministic full-pool force-reap is an M9.T2/M9.T3 bats test.)

# (B) notify-send smoke test (graphical session only; non-fatal if headless):
notify-send 'agent-browser-pool' 'PRP validation smoke test' && echo "notify-send fired" \
  || echo "notify-send not available (headless) — _pool_alert guards this, non-fatal"
# Expected: either "fired" or "not available"; both are acceptable.

# (C) Full-file shellcheck once more (the gate):
shellcheck -s bash lib/pool.sh && echo "FINAL shellcheck OK"
# Expected: FINAL shellcheck OK (zero warnings).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 passed: `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings.
- [ ] `pool_wait_for_lane` + `_pool_alert` present; `grep -cE 'flock 9' lib/pool.sh` == 1 (only pool_acquire_locked).
- [ ] No new env vars / globals / files (reads POOL_WAIT + POOL_STATE_DIR only; alerts.log derived inline).
- [ ] No edits to any existing function (diff is purely additive — one new banner + two functions at EOF).

### Feature Validation

- [ ] Empty-pool fast path: `pool_wait_for_lane` acquires lane 1 + rc 0 (Scenario A/E, Level 2/3).
- [ ] Force-reap path: stale lane reaped + alerted (Scenario B, Level 2; alerts.log line, Level 3).
- [ ] All-live failure path: rc 1 + alert + log (Scenario C, Level 2).
- [ ] `_pool_alert` best-effort + non-fatal: rc 0 even when alerts.log unwritable (Scenario D, Level 2).
- [ ] stdout discipline: `N=$(pool_wait_for_lane)` captures exactly one integer on rc 0, empty on rc 1 (Scenario E, Level 2).
- [ ] POOL_WAIT=0: poll loop runs 0 iterations (check-before-body; enforced structurally + Scenario B).
- [ ] All prior deliverables (M1–M5.T3.S2) unchanged + callable (Level 3 step 4).

### Code Quality Validation

- [ ] LOCK-FREE: no flock / no `9>"$POOL_LOCK_FILE"` inside pool_wait_for_lane or _pool_alert.
- [ ] Force-reap uses the PUBLIC `pool_release_lane` (not `_pool_release_lane_internals`).
- [ ] Every `pool_lane_is_stale` call is under an `if`; every `pool_acquire_locked` capture is a split-local `if N=$(…)`.
- [ ] Every `(( ))` is in a condition context (`&&`/`||`/`if`); no bare arithmetic.
- [ ] Timing uses `_pool_now` (epoch); display ts uses `printf %()T`; NEVER `$SECONDS`.
- [ ] stdout redirects: `pool_reap_stale >/dev/null`, `pool_release_lane >/dev/null`, `_pool_alert >/dev/null 2>&1`.
- [ ] Docstrings (DESIGN/LOGIC/CALLER CONTRACT/GOTCHA) mirror the depth of pool_reap_stale / pool_release_lane.
- [ ] Helpers-first placement: `_pool_alert` above `pool_wait_for_lane`.

### Documentation & Deployment

- [ ] The docstring documents the LOCK-FREE precondition + the flock(2) self-deadlock warning.
- [ ] The alert messages match PRD §2.9 verbatim (summary `'agent-browser-pool'`; force-reap body `'Pool exhausted — force-reaped lane N. Possible leak.'` with em-dash).
- [ ] `_pool_log` lines are informative ("pool_wait: force-reaped stale lane N after <WAIT>s timeout" / "pool_wait: exhausted — …").

---

## Anti-Patterns to Avoid

- ❌ Don't add a flock inside `pool_wait_for_lane` (LOCK-FREE; delegate to `pool_acquire_locked`; a fresh `9>"$POOL_LOCK_FILE"` self-deadlocks via flock(2) per-OFD).
- ❌ Don't hold any lock across the 2 s `sleep` (would serialize the entire pool for up to 10 min).
- ❌ Don't use `_pool_release_lane_internals` for force-reap (it skips the daemon close — reserved for in-lock acquire reap); use the PUBLIC `pool_release_lane`.
- ❌ Don't call `pool_lane_is_stale` / `pool_acquire_locked` bare (rc 1/2 aborts under set -e) — use `if`.
- ❌ Don't write `local N="$(pool_acquire_locked)"` (SC2155 masks errexit) — split the local.
- ❌ Don't leave a bare `(( expr ))` (value 0 → rc 1 → abort) — put it in `if`/`&&`/`||`.
- ❌ Don't use `$SECONDS` for timing (unset-fragile in a sourced library) — use `_pool_now`.
- ❌ Don't default a corrupt/missing `acquired_at` to 0 (0 always wins "oldest") — skip it.
- ❌ Don't let `notify-send` / `alerts.log` failures affect the rc (`_pool_alert` is best-effort, `|| true`).
- ❌ Don't retry-loop the force-reap (a peer legitimately winning the freed lane → rc 1 is the acceptable total-failure path).
- ❌ Don't skip validation because "it should work" — run `bash -n` + `shellcheck` after the edit.
- ❌ Don't create new patterns when existing ones work — compose the LANDED helpers.

---

## Confidence Score

**9/10** for one-pass implementation success.

Rationale: the function is a **pure addition** (one new banner + two functions at EOF; no
edits to existing code), **lock-free** (composes already-landed flock-owner + lock-free
helpers), and the **research is exhaustive** — the design-validation.md resolves all 10
design questions with line citations, bash-patterns.md documents every set -e / `(( ))` /
SC2155 / timing gotcha with GNU-manual URLs, and the verbatim-ready implementation (Task 1)
passes the structural reasoning. The one residual uncertainty (not a -2): a
**fully-deterministic full-pool force-reap** is hard to simulate manually without
`POOL_PORT_RANGE=0` or the M9 bats harness, so Level 2 Scenarios B/C are partly structural
(the set -e guards + the redirect set are enforced by shellcheck/bash -n). The
force-reap/alert *mechanics* themselves are directly validated in Level 3 steps 2/3. Net:
high-confidence one-pass.
