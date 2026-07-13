# PRP — P1.M5.T3.S2: `pool_reuse_orphan()` — adopt responsive Chrome with dead owner

---

## Goal

**Feature Goal**: Implement **`pool_reuse_orphan()`** — the **IQ4 reuse-if-responsive**
adoption entry point (PRD §2.4 step 3b): a function that scans **every** lane
(`pool_lanes_list`), asks the tri-state predicate `pool_lane_is_stale` (rc 0=stale / 1=live /
2=no-lease) whether each lane's owner is dead/recycled/unverifiable, and for the **first STALE
lane whose Chrome is still RESPONSIVE** (`pool_daemon_connected "$session" "$port"` == 0) **ADOPTS**
it — delegating to the PRIVATE `_pool_adopt_lane` kernel (reassign owner to the current caller
`POOL_OWNER_*`, set `connected=true`, stamp `last_seen_at`, re-bind the daemon via
`pool_daemon_connect`). It then **echoes the adopted lane N** and `return 0`. If **no** orphan is
responsive, it echoes nothing and `return 1`. **NO reap, NO choose-N, NO Chrome launch** — this is
reuse-only (the ~5-10s Chrome boot is skipped; PRD §2.4 step 3b / IQ4).

This is the **PUBLIC building-block form** of the reuse-orphan operation — the deliberate
complement to acquire's OWN inlined reuse-orphan loop (`_pool_acquire_critical_section`,
`lib/pool.sh:1977-1996`), which interleaves reap+reuse per lane and, on a FAILED adopt, REAPS the
lane. The item CONTRACT's "Consumed by acquire step 3b (M5.T1.S1)" + "runs inside the flock
critical section of pool_acquire_locked" is **legacy design intent** (research §1 — exactly
parallel to the S1 `pool_reap_stale` story): the LANDED acquire already inlines its own
reuse-orphan (calling `_pool_adopt_lane` directly under the flock). `pool_reuse_orphan` is the
reusable/testable entry point for FUTURE callers (an acquire refactor that extracts the inline; an
exhaustion retry; admin/doctor reconcile). Do **NOT** wire it into acquire (the inline is shipped +
correct); do **NOT** change acquire's loop.

The function implements the item CONTRACT verbatim (research §6 reconciles the inline-vs-delegate
nuance):
**a.** `for n in $(pool_lanes_list)` — iterate ALL lanes (snapshot).
**b.** `if pool_lane_is_stale "$n"; then …; fi` — tri-state verdict (rc 0 stale → enter; rc 1 live
   / rc 2 no-lease → fall through).
**c.** Read `port` + `session` via `pool_lease_field`; **gate**: `[[ "$port" =~ ^[0-9]+$ && "$port"
   -gt 0 ]] && pool_daemon_connected "$session" "$port"` (read-only, NEVER launches — PRD §2.4 3b).
   A provisional lease (`port=0`) has no Chrome yet → never an orphan → skipped.
**d.** On a responsive orphan: `if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi`
   — adopt (reassign owner + connected=true + last_seen_at + daemon re-bind). If adopt FAILS
   (Chrome died mid-race) → fall through, try the NEXT stale lane.
**e.** `return 1` (no responsive orphan adopted; nothing echoed).
**f.** NOTE: **runs within a serialized context** — the caller MUST hold `$POOL_LOCK_FILE`
   (research §3 — adoption is NOT collision-safe; the function takes NO own flock).

**Deliverable**: One PUBLIC function `pool_reuse_orphan()`, appended to `lib/pool.sh` under the
EXISTING **`# Reaper & orphan reuse`** banner (`lib/pool.sh:2483`) directly AFTER `pool_reap_stale`
(the current EOF — `lib/pool.sh:2595`, the M5.T3.S1 deliverable that LANDED in parallel). **Pure
addition: no edits to any existing function, no new private helpers, no new env-vars/globals, no new
files, NO flock.** It COMPOSES four LANDED functions — `pool_lanes_list` (M3.T2.S1) +
`pool_lane_is_stale` (M3.T2.S3) + `pool_lease_field` (M3.T1.S2, for port/session) +
`pool_daemon_connected` (M4.T3.S1, responsiveness gate) — and DELEGATES the actual adoption to the
PRIVATE `_pool_adopt_lane` (M5.T1.S1). The banner tag line is bumped `(P1.M5.T3.S1)` →
`(P1.M5.T3.S1, P1.M5.T3.S2)` (a COMMENT-only edit — no function code touched).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve`, given a pool
  with a mix of lanes — one orphan (dead owner pid 99998, but a Chrome still listening on its CDP
  port), one stale-with-dead-Chrome lane, one live lane, and one provisional lane (`port=0`) —
  calling `n="$(pool_reuse_orphan)"` returns **rc 0**, echoes **exactly one integer** = the orphan's
  lane number, and: (a) the orphan's lease `owner` is **reassigned** to the current
  `POOL_OWNER_PID`/`COMM`/`STARTTIME`/`CWD`, `connected`==`true`, `last_seen_at` refreshed, and the
  daemon is **re-bound** (`pool_daemon_connected` still rc 0); (b) the stale-with-dead-Chrome lane
  is **untouched** (NOT reaped — reuse-only); (c) the live lane is **untouched**; (d) the
  provisional lane (`port=0`) is **skipped** (never adopted — no Chrome yet).
- **No orphan** (all stale lanes have dead Chromes, or all lanes are live): `pool_reuse_orphan`
  echoes nothing + `return 1`.
- **Empty pool**: `pool_reuse_orphan` echoes nothing + `return 1` (zero iterations).
- **Passthrough owner** (`POOL_OWNER_PID==0`): `pool_reuse_orphan` echoes nothing + `return 1`
  (defense-in-depth — a passthrough owner must NOT adopt; mirrors acquire).
- **Adopt-failure-mid-race** (orphan responsive at the gate, but `_pool_adopt_lane` returns 1 —
  Chrome died between the probe and the re-bind): `pool_reuse_orphan` falls through to the NEXT
  stale lane; if none adoptable → `return 1`. (The lane is NOT reaped — reuse-only; a later reap
  sweep or acquire handles it.)
- **First-of-many** (multiple responsive orphans, lanes 1+3): adopts the LOWEST N (1) and returns
  immediately (does not adopt 3).
- **stdout discipline**: `n=$(pool_reuse_orphan)` captures EXACTLY one integer token (the adopted
  lane) on success, and an empty string on `return 1` — because the ONLY stdout write is
  `printf '%s\n' "$n"`, and every helper (`pool_daemon_connected`, `_pool_adopt_lane`,
  `pool_lease_field`, `_pool_log`) is stdout-clean (research §5).
- **Non-fatal**: `pool_reuse_orphan` NEVER calls `pool_die`; it returns 0 or 1.
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero warnings —
  host-verified ShellCheck 0.11.0); all prior deliverables (M1–M5.T3.S1) unchanged and still
  callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its consumers (per the item
CONTRACT §4 + PRD §2.4 step 3b, all within a SERIALIZED context — the caller holds `$POOL_LOCK_FILE`):

- **A future `_pool_acquire_critical_section` refactor** (the CONTRACT's literal "consumed by acquire
  step 3b") — POSSIBLE consumer: acquire could extract its inlined reuse-orphan loop into a call to
  `pool_reuse_orphan`. The LANDED acquire currently inlines it (S1 invariant: do NOT touch acquire's
  loop), so this is a documented FUTURE option, NOT a hard dependency.
- **M5.T4.S1 exhaustion retry** — POSSIBLE consumer: when `pool_acquire_locked` returns 1
  (exhaustion), a retry that re-scans for an orphan that appeared since. (Acquire already tried
  reuse-orphan before declaring exhaustion, so this is a niche re-check.)
- **M7.T4.S1 `doctor` reconcile** — POSSIBLE consumer: an admin reconcile that adopts responsive
  orphans. (No `adopt` CLI command exists in PRD §2.12; doctor is the plausible admin caller.)

**Use Case**: A pi agent crashed mid-task. Its owner pid died but its Chrome (process group) is
STILL listening on its CDP port — a perfectly good browser about to be needlessly torn down + a
new one booted (~5-10s). A caller (within the acquire flock, or an admin/exhaustion context that
holds the lock) invokes `pool_reuse_orphan`; it scans every lane, `pool_lane_is_stale` flags the
dead-owner lane (rc 0), `pool_daemon_connected` confirms the Chrome is still responsive, and
`_pool_adopt_lane` reassigns the owner to the current caller + re-binds the daemon — skipping the
copy/launch. The caller gets the lane number back and proceeds straight to EXEC. The boot is saved.

**Pain Points Addressed**:
- **Needless Chrome reboots after a crash.** An orphaned-but-responsive Chrome is a wasted asset if
  only reaped. reuse-orphan ADOPTS it (IQ4 = reuse-if-responsive) — the ~5-10s Chrome boot + master
  copy are skipped (PRD §2.4 step 3b).
- **One bad lane must never abort the scan.** Every step is non-fatal + fall-through: a corrupt
  lease (rc 2 skip), a provisional lane (port=0 skip), a dead-Chrome lane (not responsive → skip),
  an adopt-failure-mid-race (fall through to next), or an empty pool are all clean `return 1` paths.
- **DRY.** It COMPOSES the LANDED staleness predicate (`pool_lane_is_stale`), the LANDED
  responsiveness gate (`pool_daemon_connected`), and the LANDED adoption kernel (`_pool_adopt_lane`).
  Re-implementing the jq owner-mutation, the daemon connect, or the curl probe would duplicate three
  carefully-verified functions + risk divergence.

## Why

- **This IS PRD §2.4 step 3b / IQ4 (reuse-if-responsive).** "If a lane has a dead owner but its
  Chrome is still listening on its CDP port, adopt it: reassign owner, ensure connected, skip the
  expensive master copy. This saves the ~5-10s Chrome boot."
- **It is the PUBLIC building-block complement to acquire's inlined reuse-orphan.** Exactly as S1's
  `pool_reap_stale` is the public form of acquire's inlined reap, `pool_reuse_orphan` is the public
  form of acquire's inlined adoption. The LANDED acquire inlines its own (under the flock,
  intertwined with reap); the public function exists for reuse, testability, and documentation.
- **Composes, does not duplicate.** It reuses the LANDED `_pool_adopt_lane` (which already does the
  owner-reassign + connected + re-bind), `pool_daemon_connected` (the read-only responsiveness
  gate), `pool_lane_is_stale` (the tri-state verdict), and `pool_lanes_list` (the iterator).
  Re-implementing any of these duplicates verified logic + risks divergence.
- **Non-fatal is non-negotiable.** It returns 0 (adopted) or 1 (none); never `pool_die`. A corrupt
  lease, a provisional lane, a dead Chrome, or an adopt-failure-mid-race are all clean fall-through
  / `return 1` paths.

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| 1 orphan + 1 stale-dead-Chrome + 1 live + 1 provisional | `n="$(pool_reuse_orphan)"` | **rc 0**; `n`==orphan-lane; orphan owner REASSIGNED + connected=true + daemon re-bound; stale-dead-Chrome lane UNTOUCHED; live lane UNTOUCHED; provisional lane skipped |
| no orphan (all stale lanes have dead Chromes) | `pool_reuse_orphan` | **rc 1**; nothing echoed; no lane touched |
| empty pool | `pool_reuse_orphan` | **rc 1**; nothing echoed |
| all-live pool | `pool_reuse_orphan` | **rc 1**; nothing echoed; no lane touched |
| passthrough owner (`POOL_OWNER_PID==0`) | `pool_reuse_orphan` | **rc 1**; nothing echoed (defense-in-depth) |
| adopt-failure-mid-race (responsive at gate, `_pool_adopt_lane` rc 1) | (internal) | gate passes → adopt rc 1 → fall through to next stale lane; if none → rc 1; lane NOT reaped |
| multiple responsive orphans (lanes 1 + 3) | `n="$(pool_reuse_orphan)"` | **rc 0**; `n`==1 (LOWEST N; returns immediately, does not touch 3) |
| corrupt lease (pool_lane_is_stale rc 2) | (internal) | skipped (falls through); rc 1 if no other orphan |
| provisional lane (`port=0`) stale | (internal) | port-not-`>0` → not an orphan → skipped; rc 1 if no other orphan |

**Hard invariants** (every row):
- **`pool_reuse_orphan` NEVER calls `pool_die`.** It returns 0 (adopted) or 1 (none). It is
  NON-FATAL always (verdicts/gate/adopt are all `if`/`&&`-guarded — errexit-exempt; the
  port/session reads are `|| true`-guarded inside `$()`).
- **DELEGATE — do NOT duplicate.** The staleness verdict comes from `pool_lane_is_stale`; the
  responsiveness gate from `pool_daemon_connected`; the adoption (owner-reassign + connected +
  re-bind) from `_pool_adopt_lane`. Do NOT re-inline the jq owner-mutation, the `pool_daemon_connect`,
  or a raw `curl /json/version` probe. (DRY + the M3.T2.S3 / M4.T3.S1 / M5.T1.S1 contracts. Research
  §2 + §6.)
- **NO own flock (Design B).** The function takes NO lock. **PRECONDITION: the caller MUST already
  hold `$POOL_LOCK_FILE`** — adoption is NOT collision-safe (two concurrent adopters of the same
  orphan would both believe they own lane N). Do NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"` inside
  this function: flock(2) locks are bound per open-file-description; a fresh `9>"$POOL_LOCK_FILE"`
  redirect opens a NEW file description, so a blocking flock taken here while the caller already
  holds the lock via its own fd 9 will DENY itself and BLOCK FOREVER (self-deadlock). See
  https://man7.org/linux/man-pages/man2/flock.2.html (research §3).
- **Use the tri-state predicate under an `if` — NEVER bare.** A bare `pool_lane_is_stale "$n"` whose
  rc is 1 (live) or 2 (no lease) ABORTS under `set -e` (`pool_lane_is_stale` GOTCHA @
  `lib/pool.sh:1145-1148`). The `if pool_lane_is_stale "$n"; then …; fi` is errexit-exempt.
- **Gate responsiveness with `&&`, never bare `pool_daemon_connected`.** `[[ "$port" =~ … && "$port"
  -gt 0 ]] && pool_daemon_connected "$session" "$port"` — the `&&`-list is errexit-exempt (rc 1
  short-circuits, no abort). A bare `pool_daemon_connected …` returning 1 would ABORT under `set -e`.
- **Adopt under an `if` — never bare `_pool_adopt_lane`.** `if _pool_adopt_lane "$n"; then echo;
  return 0; fi` — rc 1 (Chrome died mid-race) falls through to the next candidate, no abort.
- **Read port/session BEFORE the gate, with `|| true` INSIDE the `$()`.** `pool_lease_field` returns
  1 on a missing/corrupt lease (TOCTOU) → the `|| true` makes the capture set-e-safe; an empty port
  → the `[[ -gt 0 ]]` gate fails → skipped. Split `local` (declare FIRST, assign AFTER — SC2155).
- **Stdout discipline.** ONLY `printf '%s\n' "$n"` writes to the function's stdout (on success).
  Every helper is stdout-clean (research §5): `pool_lease_field` is captured in `$()`;
  `pool_daemon_connected` redirects both probes `>/dev/null`; `_pool_adopt_lane`'s internal
  `pool_daemon_connect` is `>/dev/null 2>&1` and `_pool_log` writes the LOG FILE (never stdout). So
  no extra `>/dev/null` redirect is needed on `_pool_adopt_lane`.
- **Reuse-ONLY — NO reap, NO choose-N.** This function does NOT call `pool_release_lane`,
  `_pool_release_lane_internals`, or `pool_find_free_lane`. A non-responsive stale lane is SKIPPED
  (left for a later reap sweep / acquire), not reaped. (Contrast acquire's inline, which reaps the
  non-adoptable stale lane — acquire's goal is to CLAIM a lane; this function's goal is to FIND an
  orphan to reuse, returning 1 if none.)

### Success Criteria

- [ ] `pool_reuse_orphan` defined in `lib/pool.sh` under the existing `# Reaper & orphan reuse`
      banner (tag bumped to `P1.M5.T3.S1, P1.M5.T3.S2`), appended after `pool_reap_stale`. Callable
      after `source lib/pool.sh` + `pool_config_init` + `pool_owner_resolve`.
- [ ] Mixed pool (orphan + stale-dead-Chrome + live + provisional): rc 0; `n`==orphan-lane; orphan
      owner reassigned + connected=true + daemon re-bound; other lanes untouched (Scenario 1).
- [ ] No orphan (all stale dead-Chrome): rc 1; nothing echoed (Scenario 2).
- [ ] Empty pool: rc 1; nothing echoed (Scenario 3).
- [ ] All-live pool: rc 1; nothing echoed; no lane touched (Scenario 4).
- [ ] Passthrough owner (`POOL_OWNER_PID==0`): rc 1; nothing echoed (Scenario 5).
- [ ] Adopt-failure-mid-race: gate passes → adopt rc 1 → fall through → rc 1 if none; lane NOT
      reaped (Scenario 6).
- [ ] First-of-many orphans: adopts the LOWEST N, returns immediately (Scenario 7).
- [ ] `n=$(pool_reuse_orphan)` captures EXACTLY one integer on success, empty on rc 1 (stdout
      discipline).
- [ ] Non-fatal always: never `pool_die`; returns 0 or 1.
- [ ] NO own flock (Design B); delegates to `pool_lane_is_stale` + `pool_daemon_connected` +
      `_pool_adopt_lane` (no re-implementation of owner-mutation / connect / curl).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file);
      all prior deliverables (M1–M5.T3.S1) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?"** → Yes. This PRP includes: the **acquire-vs-reuse-orphan split** (research §1 —
acquire inlines its OWN reuse-orphan under the flock; `pool_reuse_orphan` is the public building
block; the CONTRACT's "consumed by acquire" is legacy design intent, exactly like S1); the
**KEY divergence from S1 — adoption is NOT collision-safe** (research §3 — the flock decision:
Design B, NO own flock, caller MUST hold the lock; Design A self-deadlocks via flock(2) per-OFD
semantics); the **dependency contracts** (research §2 — the tri-state `pool_lane_is_stale`, the
read-only `pool_daemon_connected` gate, the `_pool_adopt_lane` adoption kernel, `pool_lanes_list`,
`pool_lease_field`, the file-only `_pool_log`); the **bash correctness** (research §4 — the
`if`/`&&`-exemptions, the split-`local`+`|| true` capture, the word-split snapshot idiom, the
`return 1` composition with `if n="$(…)"`); the **stdout discipline** (research §5 — every helper
is stdout-clean); the **CONTRACT step 3b(d) reconciliation** (research §6 — the gate-then-adopt
delegation satisfies "ensure connected: if not, connect"); the **full verbatim-ready
implementation** (Implementation Tasks Task 1); and copy-pasteable, host-verified validation
commands (7 scenarios).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.4 step 3b (REUSE-ORPHAN — IQ4 = reuse-if-responsive: adopt a responsive-but-orphaned
        Chrome, reassign owner, ensure connected, skip the copy). §2.4 step 3a (REAP-STALE — the
        sibling, inlined alongside reuse-orphan in acquire). §2.8 (lease schema — owner.{pid,comm,
        starttime,cwd} + session + port + connected). §2.10 (Reaper — lazy, on acquire + on demand).
        §2.14 (the three stale failure modes: pid dead / comm!=pi / starttime mismatch). §2.19
        (flock = SHORT, ACQUIRE-ONLY — adoption via pool_daemon_connect is an ATTACH, safe inside
        the lock; but a STANDALONE pool_reuse_orphan takes NO own lock per Design B).
  pattern: §2.4 step 3b IS pool_reuse_orphan (the inline acquire does the equivalent @1977-1996).
  gotcha: §2.4 step 3b says "runs inside the flock critical section of pool_acquire_locked" — this
        describes the FUNCTION's intended CONTEXT (caller-held lock), NOT that the function takes
        its own flock. The LANDED acquire inlines reuse-orphan; pool_reuse_orphan is the public
        building block. Do NOT wire it into acquire (research §1).

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M5T3S2/research/reuse-orphan-design.md
  why: §0 (current file state — pool_reap_stale LANDED @2549-2595; pool_reuse_orphan ABSENT;
        append @2596); §1 (the acquire-vs-reuse-orphan split — the defining fact, parallel to S1);
        §2 (the 5 dependency contracts with line numbers + the tri-state + the read-only gate +
        the _pool_adopt_lane kernel); §3 (THE KEY DIVERGENCE FROM S1 — adoption is NOT collision-safe
        ⇒ Design B, NO own flock, caller-must-hold-lock; Design A self-deadlocks via flock(2)
        per-OFD); §4 (bash correctness — the if/&& exemptions, the split-local capture, the
        return-1 composition); §5 (stdout discipline); §6 (the CONTRACT 3b(d) reconciliation);
        §7 (naming/placement/scope); §8 (decisions table).
  pattern: §1 + §2 + §3 + §6 IS the implementation spine.
  gotcha: §3 (NO own flock — the flock(2) self-deadlock) is the highest-impact fact. §2.1 (delegate
        to _pool_adopt_lane — do NOT re-inline the jq owner-mutation) is the second.

# The S1 precedent (the sibling — its design + framing is the template for this task)
- file: plan/001_0f759fe2777c/P1M5T3S1/PRP.md
  why: S1's `pool_reap_stale` is the PUBLIC building-block complement to acquire's INLINED reap.
        This task is the EXACT parallel for reuse-orphan. S1's framing of "the CONTRACT's 'consumed
        by acquire' is legacy design intent" (research §1) + "no own flock" + "pure addition under
        the shared banner" + "delegates to LANDED functions" is the template. S1 LANDED
        (lib/pool.sh:2549-2595); this task appends directly below it.
  pattern: S1's structure (docstring with LOGIC + CALLER CONTRACT + GOTCHA; the tri-state `if`
        idiom; the split-`local` capture; stdout discipline; non-fatal return) is the model.
  gotcha: S1 (reap) is IDEMPOTENT (release twice = no-op) → genuinely flock-free + safe unflocked.
        THIS task (adopt) is NOT collision-safe → Design B (caller MUST hold the lock). The docstring
        MUST state this precondition + the deadlock warning. This is the ONE structural difference.

# Architecture
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (SHORT flock — scan+reap+choose+claim under lock; the standalone functions run
        outside it OR rely on the caller's lock). FINDING 6 (setsid → pgid==pid — performed by the
        release/reap kernel, NOT this task). The naming-recommendation block (`pool_*` public /
        `_pool_*` private).

# The LANDED functions this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M5T1S1/PRP.md   # _pool_adopt_lane (M5.T1.S1 — LANDED @1892)
  why: the PRIVATE adoption kernel this task DELEGATES to. Returns 0 (adopted: lease republished
        with owner reassigned + connected=true + last_seen_at + daemon re-bound) / 1 (fail). Needs
        POOL_OWNER_PID numeric + POOL_OWNER_{COMM,STARTTIME,CWD}. NEVER checks staleness or
        responsiveness — the CALLER gates that (this task does). It logs the adoption itself
        ("pool_acquire(adopt): reused orphan lane N …") → this task does NOT add a second log line.
        The jq owner-mutation is inject-safe (--arg/--argjson DATA) — do NOT re-inline it.
- file: plan/001_0f759fe2777c/P1M4T3S1/PRP.md   # pool_daemon_connected (M4.T3.S1 — LANDED @1689)
  why: the READ-ONLY responsiveness gate (CONTRACT 3b(c)). TWO probes: daemon `session list` +
        curl /json/version. NEVER launches. Its docstring (@1676) explicitly lists "M5.T3.S2
        reuse_orphan (is the orphan's chrome responsive?)" as a consumer. Returns 0 (responsive) /
        1 (not). Use under `&&` (never bare — rc 1 aborts under set -e). Raw `curl /json/version`
        ALONE is INSUFFICIENT for adoption (the daemon must know the session so the re-bind is
        meaningful) — research §2.2 + researcher brief Q2.
- file: plan/001_0f759fe2777c/P1M3T2S3/PRP.md   # pool_lane_is_stale (M3.T2.S3 — LANDED @1164)
  why: the TRI-STATE verdict (0=stale/1=live/2=no-lease). Read-only. SET -e HAZARD: a bare call
        ABORTS on rc 1/2 → MUST use `if pool_lane_is_stale "$n"; then …; fi`.
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list (M3.T2.S1 — LANDED @967)
  why: the iterator. Newline-separated, numerically-sorted lane numbers; rc 0 ALWAYS; empty/missing
        dir ⇒ 0 iterations. `for n in $(pool_lanes_list)` is the documented idiom.
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_field (M3.T1.S2 — LANDED @876)
  why: nested-path read (`port`/`session` are top-level). Returns 1 on missing/corrupt (NON-FATAL);
        echoes `"null"` for a missing path. Used to read the orphan's port + session for the gate.
- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md   # _pool_log (M1.T2.S1 — LANDED @39)
  why: the file logger. Writes the LOG FILE (+ stderr fallback), NEVER stdout ⇒ safe inside the
        lane-echo capture. (_pool_adopt_lane calls it; this task does not call it directly.)

# External authoritative docs (for the WHY; behavior host-verified in research §3/§4)
- url: https://man7.org/linux/man-pages/man2/flock.2.html
  why: flock(2) locks are associated with an OPEN FILE DESCRIPTION (not a process). "If a process
        uses open(2) (or similar) to obtain more than one file descriptor for the same file, these
        file descriptors are treated independently by flock(). An attempt to lock … may be denied by
        a lock that the calling process has already placed via another file descriptor." ⇒ a fresh
        `9>"$POOL_LOCK_FILE"` opens a NEW OFD → a blocking flock taken inside a caller that already
        holds the lock BLOCKS FOREVER (self-deadlock). This is WHY Design A is rejected (§3).
  section: the "Open file descriptions" paragraph.
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: the `-e` exemption list — the condition following `if`/`elif` AND any command in a `&&`/`||`
        list except the last are exempt. So `if pool_lane_is_stale`, `… && pool_daemon_connected`,
        and `if _pool_adopt_lane` all fall through on rc 1 (no abort).
  section: `-e` (the exemption list paragraph).
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "Why doesn't set -e do what I expected?" — the `local X=$(…)` masking (SC2155) + the
        `|| true`-inside-`$()` non-fatal-capture pattern.
- url: https://www.shellcheck.net/wiki/SC2155
  why: "Declare and assign separately" — split `local X; X="$(…)"` so the command's rc is preserved.
- url: https://mywiki.wooledge.org/WordSplitting
  why: `for n in $(pool_lanes_list)` is safe for digit-only, newline-separated, glob-free output;
        command substitution is a SNAPSHOT (frozen before the loop).
- url: https://chromedevtools.github.io/devtools-protocol/
  why: `/json/version` returns browser METADATA only — it does NOT report per-session/daemon state.
        Confirms raw curl is insufficient for adoption (the daemon session-list check is meaningful).
```

### Current Codebase tree

After **M1–M5.T3.S1** have landed, `lib/pool.sh` (2595 lines) ends with `pool_reap_stale` as the
final function (@2549, closing brace @2595):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T3.S1) with pool_reap_stale at EOF.
│                                         #   Banner order at EOF:
│                                         #   ... pool_chrome_launch + pool_wait_cdp (M4.T2.S2)
│                                         #   # Lane lifecycle — daemon connect, verify & teardown (M4.T3.S1)
│                                         #   pool_daemon_connect / pool_daemon_connected / pool_chrome_kill
│                                         #   # Acquire — flock critical section (M5.T1.S1)
│                                         #   _pool_release_lane_internals / _pool_adopt_lane
│                                         #   / _pool_acquire_critical_section / pool_acquire_locked
│                                         #   # Acquire — post-lock boot (M5.T1.S2)
│                                         #   _pool_boot_write_chrome_ids / _pool_launch_and_verify / pool_boot_lane
│                                         #   # Acquire — ensure connected (M5.T1.S3)
│                                         #   pool_ensure_connected
│                                         #   # Release & teardown (P1.M5.T2.S1)
│                                         #   pool_release_lane
│                                         #   # Reaper & orphan reuse (P1.M5.T3.S1)   ← banner @2483
│                                         #   pool_reap_stale  ← current EOF (closing brace @2595)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T3S1/PRP.md
    └── P1M5T3S2/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/reuse-orphan-design.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND ONE function under the EXISTING banner AFTER pool_reap_stale (EOF):
                  #   # Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)   ← tag bumped (COMMENT-only edit)
                  #   pool_reap_stale()          # (S1 — already present, UNCHANGED)
                  #   pool_reuse_orphan():       # PUBLIC — the CONTRACT name (reuse-if-responsive)
                  #       guard: POOL_OWNER_PID numeric & !=0  else return 1   # passthrough must not adopt
                  #       a. for n in $(pool_lanes_list)                       # snapshot; empty ⇒ 0 iters
                  #       b.   if pool_lane_is_stale "$n"; then                # tri-state; if=errexit-exempt
                  #       c.      port/session = pool_lease_field "$n" (|| true inside $(); "null"→"")
                  #              if [[ port =~ ^[0-9]+$ && port>0 ]] && pool_daemon_connected "$session" "$port"; then
                  #       d.        if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi  # adopted→done
                  #                      # adopt rc 1 (Chrome died mid-race) → fall through, try next orphan
                  #              fi        # port=0 (provisional) OR not responsive → skip (NOT reaped)
                  #            fi          # rc 1 (live) / rc 2 (no lease) → skip
                  #       e. return 1      # no responsive orphan adopted; nothing echoed
                  #   (NO changes to any existing function — esp. NOT _pool_acquire_critical_section's
                  #    inlined reuse-orphan loop / _pool_adopt_lane / pool_daemon_connected / pool_reap_stale)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**public reuse-orphan entry point** (PRD §2.4 step 3b / IQ4) — the scan that adopts the first
responsive orphan and echoes its lane. It COMPOSES `pool_lanes_list` (iteration) +
`pool_lane_is_stale` (verdict) + `pool_lease_field` (port/session read) + `pool_daemon_connected`
(responsiveness gate) + `_pool_adopt_lane` (adoption). It reads `POOL_LANES_DIR` + `POOL_OWNER_*` +
`POOL_REAL_BIN` (via the helpers). It writes nothing new itself (the adoption kernel does the lease
rewrite + daemon re-bind; the lane number is a local variable echoed on success).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (acquire-vs-reuse-orphan split — research §1): the LANDED acquire critical section
#   (_pool_acquire_critical_section @ lib/pool.sh:1966) has its OWN inlined reuse-orphan loop
#   (@1977-1996) that calls _pool_adopt_lane directly, INTERLEAVED with reap (on a failed adopt it
#   REAPS the lane via _pool_release_lane_internals, then continues). pool_reuse_orphan is the
#   PUBLIC REUSE-ONLY building block: it adopts the first responsive orphan (on a failed adopt it
#   falls through to the NEXT stale lane — NO reap). Do NOT wire pool_reuse_orphan into acquire;
#   do NOT change acquire's loop. The CONTRACT's "Consumed by acquire step 3b" is legacy design
#   intent (exactly like S1's reap story). Document this in the docstring.

# CRITICAL (THE KEY DIVERGENCE FROM S1 — research §3): adoption is NOT collision-safe. Two
#   concurrent adopters of the SAME orphan would both read the lease, both find it responsive,
#   both rewrite .owner, both re-bind the daemon, and both echo lane N → BOTH believe they own N.
#   (Contrast S1's reap, which is idempotent — release twice = no-op.) Therefore pool_reuse_orphan
#   REQUIRES serialization. DECISION: Design B — pool_reuse_orphan takes NO own flock; the CALLER
#   MUST already hold $POOL_LOCK_FILE. DO NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"` inside this
#   function: flock(2) locks are bound per OPEN FILE DESCRIPTION (man flock(2)); a fresh
#   9>"$POOL_LOCK_FILE" opens a NEW OFD, so a blocking flock taken here while the caller already
#   holds the lock via its own fd 9 is DENIED BY THE CALLER'S OWN LOCK → BLOCKS FOREVER
#   (self-deadlock). The docstring MUST state the caller-must-hold-lock precondition + this
#   deadlock warning prominently.

# CRITICAL (DELEGATE — do NOT duplicate — research §2/§6): the adoption (owner-reassign +
#   connected=true + last_seen_at + daemon re-bind) is ALREADY _pool_adopt_lane (M5.T1.S1). The
#   responsiveness gate is ALREADY pool_daemon_connected (M4.T3.S1). Do NOT re-inline the jq
#   .owner mutation, pool_daemon_connect, or a raw curl /json/version probe. (Re-inlining the jq
#   owner-mutation duplicates a subtle, inject-safe, set-e-sensitive write + risks divergence;
#   raw curl is INSUFFICIENT — adoption needs the daemon to know the session.)

# CRITICAL (tri-state predicate under set -e — research §4.1, pool_lane_is_stale GOTCHA
#   @ lib/pool.sh:1145-1148): a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or 2 (no
#   lease) ABORTS the caller under set -e. The MANDATORY idiom is `if pool_lane_is_stale "$n";
#   then adopt; fi` — the if-condition is errexit-exempt; rc 1/2 fall through cleanly.

# CRITICAL (responsiveness gate under set -e — research §4.1): pool_daemon_connected returns 1
#   (not responsive) — a BARE call ABORTS under set -e. Use it under `&&` (errexit-exempt):
#       [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected "$session" "$port"
#   The `[[ ]] && func` list is exempt: rc 1 short-circuits (func skipped on a bad port), no abort.
#   Likewise gate _pool_adopt_lane under `if _pool_adopt_lane "$n"; then …; fi` (rc 1 falls through).

# CRITICAL (port=0 provisional lease is NEVER an orphan — research §2/3): a PROVISIONAL lease
#   (written by acquire step 3d before the Chrome boots) has port=0, chrome_pid=0 — NO Chrome yet.
#   The `[[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]]` gate REJECTS port=0 → such a lane is NEVER
#   adopted (correct — there is nothing to reuse). It is also skipped (NOT reaped — reuse-only).

# CRITICAL (read port/session with || true INSIDE the $() — research §4.2): pool_lease_field
#   returns 1 on a missing/corrupt lease (TOCTOU between the staleness verdict and the read). The
#   `|| true` INSIDE the $() makes the capture set-e-safe (the capture yields "" on failure → the
#   [[ -gt 0 ]] gate fails → skipped). Split local (declare FIRST, assign AFTER — SC2155):
#       local port session
#       port="$(pool_lease_field "$n" port 2>/dev/null || true)"
#       session="$(pool_lease_field "$n" session 2>/dev/null || true)"
#   (No need to normalize "null"→"?" here — an empty/"null" port simply fails the numeric gate.)

# CRITICAL (passthrough owner must NOT adopt — research §4/§8): POOL_OWNER_PID==0 means no pi
#   ancestor (a human in a terminal / a passthrough invocation). Such an owner must NOT adopt a
#   lane (it would be immediately stale to everyone + _pool_adopt_lane itself returns 1 on a
#   non-numeric POOL_OWNER_PID). Mirror acquire's defense: `[[ "$POOL_OWNER_PID" =~ ^[0-9]+$ &&
#   "$POOL_OWNER_PID" != "0" ]] || return 1` at the top. (errexit-exempt.)

# CRITICAL (reuse-ONLY — NO reap, NO choose-N — research §1/§3): this function does NOT call
#   pool_release_lane, _pool_release_lane_internals, or pool_find_free_lane. A non-responsive
#   stale lane is SKIPPED (left for a later reap sweep / acquire), NOT reaped. On exhaustion
#   (no orphan) it returns 1 — the CALLER decides what to do (block/reap/claim-new). Contrast
#   acquire's inline, which reaps non-adoptable stale lanes + falls through to choose-N — acquire's
#   goal is to CLAIM a lane; this function's goal is to FIND an orphan to reuse.

# GOTCHA (stdout discipline — research §5): the ONLY stdout write is `printf '%s\n' "$n"` (on
#   success). Every helper is stdout-clean: pool_lease_field is captured in $(); pool_daemon_connected
#   redirects both probes >/dev/null; _pool_adopt_lane's pool_daemon_connect is >/dev/null 2>&1 and
#   _pool_log writes the LOG FILE (never stdout). So NO extra >/dev/null is needed on _pool_adopt_lane.
#   On return 1 (no orphan) NOTHING is echoed → `n=$(pool_reuse_orphan)` yields the empty string.

# GOTCHA (no double-logging — research §2.1/§5): _pool_adopt_lane logs the adoption itself
#   ("pool_acquire(adopt): reused orphan lane N (port=…, owner pid=…)"). pool_reuse_orphan does
#   NOT add a second _pool_log line (would duplicate). _pool_log is file-only → stdout stays clean.

# GOTCHA (adopt-failure-mid-race — research §6): the Chrome can die BETWEEN the responsiveness
#   gate (pool_daemon_connected rc 0) and the re-bind inside _pool_adopt_lane (pool_daemon_connect
#   rc 1). _pool_adopt_lane returns 1 → `if _pool_adopt_lane "$n"; then …; fi` falls through →
#   the loop continues to the NEXT stale lane (try the next orphan). If none adoptable → return 1.
#   The racy lane is NOT reaped (reuse-only); a later reap sweep / acquire handles it.

# GOTCHA (snapshot iteration — research §4.3): `for n in $(pool_lanes_list)` captures the list
#   ONCE before the loop (command substitution is fully evaluated up front). Adopting a lane
#   mid-loop (rewriting its lease, not deleting it) CANNOT mutate the iteration set. A new lane
#   not in the snapshot is not seen this pass; a lane deleted between list + check →
#   pool_lane_is_stale rc 2 → skip. Correct.

# GOTCHA (ShellCheck — host-verified): ShellCheck 0.11.0 does NOT flag `for n in $(pool_lanes_list)`
#   as SC2046 in this context — `shellcheck -s bash lib/pool.sh` exits 0 on the current file (which
#   already contains the identical idiom at lib/pool.sh:1977 in acquire). NO disable directive needed.

# GOTCHA (naming + placement — research §7): pool_reuse_orphan (PUBLIC, CONTRACT name, NO `_`
#   prefix). APPEND at EOF (line 2596) under the EXISTING "Reaper & orphan reuse" banner, directly
#   below pool_reap_stale. Bump the banner tag `(P1.M5.T3.S1)` → `(P1.M5.T3.S1, P1.M5.T3.S2)`
#   (a COMMENT-only edit — no function code touched). NO new private helpers (the body is ~12 lines;
#   delegating to _pool_adopt_lane keeps it short). Do NOT touch any existing function.

# GOTCHA (scope — reuse-only): do NOT implement reap_stale (M5.T3.S1 — ALREADY LANDED), the
#   acquire refactor (M5.T1.S1 — keep its inline), exhaustion force-reap (M5.T4), the admin CLI
#   (M7), or the wrapper (M6). Do NOT add a flock. Do NOT touch acquire's inlined reuse-orphan loop.
#   Do NOT add new env vars / globals / files. This task ships pool_reuse_orphan ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**. It
reads the lease schema (PRD §2.8, frozen by M3.T1.S1) — specifically `port` + `session` (for the
responsiveness gate) + `owner.pid` (implicitly, via the staleness verdict) — and delegates all
mutating work to `_pool_adopt_lane` (which rewrites `.owner` / `.connected` / `.last_seen_at` and
re-binds the daemon).

Global READ (frozen by `pool_config_init` + `pool_owner_resolve`):

| global | source | role |
|---|---|---|
| `POOL_LANES_DIR` | pool_config_init | lane enumeration (`pool_lanes_list`) + per-lane reads (`pool_lease_field`) |
| `POOL_OWNER_PID` / `_COMM` / `_STARTTIME` / `_CWD` | pool_owner_resolve | the adopter identity (passed to `_pool_adopt_lane`, which rewrites the lease `.owner`). The guard requires `POOL_OWNER_PID` numeric & non-zero. |
| `POOL_REAL_BIN` | pool_config_init | the daemon `session list` + `connect` subprocesses (via `pool_daemon_connected` + `_pool_adopt_lane`→`pool_daemon_connect`; NOT read directly here) |
| `POOL_LOCK_FILE` | pool_config_init | NOT used by this function (Design B — the CALLER holds it); referenced only in the docstring precondition. |

External commands (all present on host; verified this session): `jq` (via `pool_lease_field` +
inside `_pool_adopt_lane`), `agent-browser` `session list`/`connect` (via the helpers), `curl`
(via `pool_daemon_connected`).

**Naming** (CONTRACT-mandated + codebase convention): `pool_reuse_orphan` (public, CONTRACT name,
no `_`; matches the `pool_*` family). **No private helpers** — the body is ~12 lines + linear;
delegating to `_pool_adopt_lane` keeps it short. Fragmenting into `_pool_*` helpers would hurt
readability.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_owner_resolve pool_lanes_list pool_lane_is_stale \
                  pool_lease_field pool_daemon_connected _pool_adopt_lane'
  - EXPECT: all reported as functions (M1–M5.T3.S1 LANDED). If _pool_adopt_lane is MISSING →
        STOP (the adoption kernel this task delegates to does not exist; M5.T1.S1 must land first).
        If pool_reuse_orphan ALREADY EXISTS → STOP (someone implemented it already; reconcile).
  - RUN (verify the globals + the gate):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_LANES_DIR" && -n "$POOL_REAL_BIN" && -n "$POOL_LOCK_FILE" ]] \
                   && echo "OK globals" || echo FAIL'
        command -v jq >/dev/null && command -v curl >/dev/null && echo "OK jq+curl" || echo FAIL
  - EXPECT: OK globals ; OK jq+curl.
  - RUN (locate the append point — current EOF must be pool_reap_stale, the S1 deliverable):
        grep -nE '^pool_reap_stale\(\)' lib/pool.sh
        grep -n 'Reaper & orphan reuse' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        # ALSO confirm the public name does NOT yet exist:
        grep -nE '^pool_reuse_orphan\(\)' lib/pool.sh && echo "STOP: already exists" || echo "OK: absent"
  - EXPECT: pool_reap_stale defined (@2549); it is the last function (closing brace @2595 = EOF).
        The banner line (@2483) reads "# Reaper & orphan reuse (P1.M5.T3.S1)". APPEND the new
        function AFTER pool_reap_stale's closing brace (line 2596). pool_reuse_orphan ABSENT.
  - RUN (confirm the acquire reuse-orphan loop is INLINED + calls _pool_adopt_lane — do NOT touch):
        grep -nE '_pool_adopt_lane "\$n"' lib/pool.sh
  - EXPECT: a hit inside _pool_acquire_critical_section (~line 1986) — confirms acquire does its
        OWN inlined reuse-orphan (NOT pool_reuse_orphan). This task appends a SEPARATE function.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_reuse_orphan() to lib/pool.sh
  - PLACEMENT: directly below pool_reap_stale's closing brace at EOF (line 2596), under the
        EXISTING "Reaper & orphan reuse" banner. ALSO bump the banner tag line (@2483) from
        "(P1.M5.T3.S1)" to "(P1.M5.T3.S1, P1.M5.T3.S2)" (COMMENT-only edit).
  - EDIT (banner tag bump — COMMENT-only, do NOT touch any function code):
        old: # Reaper & orphan reuse (P1.M5.T3.S1)
        new: # Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)
  - IMPLEMENT (verbatim-ready — paste this block at EOF, then adapt commentary to codebase style):

pool_reuse_orphan() {
    local n port session

    # ── Guard: a passthrough owner (POOL_OWNER_PID==0, no pi ancestor) must NOT adopt a lane ──
    # (it would be immediately stale to everyone; _pool_adopt_lane itself returns 1 on a non-numeric
    # POOL_OWNER_PID). Mirrors _pool_acquire_critical_section's defense. `[[ ]] || return 1` is
    # errexit-exempt. CONTRACT step 3b INPUT = the current POOL_OWNER_* (the new owner).
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1

    # (a) Iterate ALL lanes. pool_lanes_list: newline-separated, numerically-sorted lane numbers;
    #     rc 0 always; empty/missing dir ⇒ 0 iterations. The unquoted command substitution is the
    #     documented idiom (digits-only; word-splits on IFS into exactly the lane numbers). The list
    #     is a SNAPSHOT (captured once before the loop) — adopting a lane mid-loop (rewriting its
    #     lease) cannot mutate the iteration set.
    for n in $(pool_lanes_list); do

        # (b) TRI-STATE verdict. pool_lane_is_stale: 0=stale / 1=live / 2=no-lease. The `if`-
        #     condition is errexit-exempt — rc 1 (live) and rc 2 (no lease) fall through cleanly
        #     (skip); ONLY rc 0 (stale) enters the body. A BARE call would ABORT under set -e on
        #     rc 1/2 (pool_lane_is_stale GOTCHA @ ~line 1145-1148). (CONTRACT 3b(a/b).)
        if pool_lane_is_stale "$n"; then

            # (c) Read the orphan's port + session for the responsiveness gate. pool_lease_field:
            #     top-level `port`/`session` read; rc 1 on missing/corrupt (TOCTOU between the
            #     staleness verdict and this read); echoes "null" for a missing path. The `|| true`
            #     INSIDE the $() makes the capture set -e-safe (yields "" on failure). The
            #     assignment is split (local declared above) — no SC2155 / errexit masking.
            port="$(pool_lease_field "$n" port 2>/dev/null || true)"
            session="$(pool_lease_field "$n" session 2>/dev/null || true)"

            # (c) RESPONSIVENESS GATE (CONTRACT 3b(c)). A provisional lease has port=0 (no Chrome
            #     yet) → the `[[ -gt 0 ]]` test rejects it (never an orphan). pool_daemon_connected:
            #     READ-ONLY two-probe check (daemon `session list` + curl /json/version); NEVER
            #     launches; rc 0 = responsive, rc 1 = not. Raw curl ALONE is insufficient for
            #     adoption (the daemon must know the session so the re-bind is meaningful). The
            #     `[[ ]] && func` list is errexit-exempt — rc 1 (not responsive / bad port)
            #     short-circuits (skip this lane), NO abort. A BARE pool_daemon_connected would
            #     ABORT under set -e on rc 1.
            if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
               && pool_daemon_connected "$session" "$port"; then

                # (d) ADOPT (CONTRACT 3b(d) — reassign owner / connected=true / last_seen_at /
                #     ensure-connected, all ALREADY implemented by _pool_adopt_lane). The gate
                #     above is the "ensure connected" CHECK; _pool_adopt_lane does the owner-reassign
                #     + the daemon re-bind (pool_daemon_connect) — the "if not, connect" ACT.
                #     DELEGATE — do NOT re-inline the jq .owner mutation or pool_daemon_connect.
                #     `if _pool_adopt_lane "$n"; then …; fi` is errexit-exempt: rc 1 (Chrome died
                #     between the gate and the re-bind) → fall through to the NEXT stale lane (try
                #     the next orphan); the racy lane is NOT reaped (reuse-only). On rc 0 → echo
                #     the lane + return 0 (DONE — first responsive orphan adopted).
                if _pool_adopt_lane "$n"; then
                    # The ONLY stdout write: the adopted lane N. Every helper is stdout-clean
                    # (pool_lease_field captured in $(); pool_daemon_connected redirects both probes
                    # >/dev/null; _pool_adopt_lane's pool_daemon_connect is >/dev/null 2>&1 and
                    # _pool_log writes the LOG FILE). _pool_adopt_lane logs the adoption itself
                    # ("pool_acquire(adopt): reused orphan lane N …") → no second log line here.
                    printf '%s\n' "$n"
                    return 0
                fi
            fi
            # port=0 (provisional) OR not responsive OR adopt-failed → skip this lane (NOT reaped;
            # reuse-only — a later reap sweep / acquire handles it). Continue to the next lane.
        fi
    done

    # (e) No responsive orphan was adoptable. CONTRACT step 3b(e). Nothing echoed (so
    #     `n=$(pool_reuse_orphan)` yields the empty string). NON-FATAL (never pool_die).
    return 1
}

  - FOLLOW pattern: the docstring (ABOVE the function — see the full docstring block in Task 1b
        below) with DESIGN / LOGIC / CALLER CONTRACT / GOTCHA sections (mirror pool_reap_stale +
        _pool_adopt_lane); guard POOL_OWNER_PID (mirrors _pool_acquire_critical_section); the
        tri-state predicate under an `if` (never bare); the responsiveness gate under `&&` (never
        bare); the adoption under an `if` (never bare); split-`local` captures with `|| true`
        INSIDE the `$()`; delegate to `_pool_adopt_lane` (no re-inlined jq/connect/curl).
  - NAMING: pool_reuse_orphan (PUBLIC, CONTRACT name, no `_`). NO private helpers.
  - PLACEMENT: the function in the (banner-tag-bumped) "Reaper & orphan reuse" section, after
        pool_reap_stale.

Task 1b: THE DOCSTRING (place immediately ABOVE the `pool_reuse_orphan() {` line)
  - IMPLEMENT (verbatim-ready docstring — mirrors the depth of pool_reap_stale / _pool_adopt_lane):

# pool_reuse_orphan
#
# PRD §2.4 step 3b / IQ4 "reuse-if-responsive" — the PUBLIC building-block entry point that ADOPTS
# the first STALE lane whose Chrome is still RESPONSIVE. Scans EVERY lane (pool_lanes_list), asks
# the tri-state predicate pool_lane_is_stale whether each lane's owner is dead/recycled, and for the
# first stale lane whose Chrome answers (pool_daemon_connected) DELEGATES to _pool_adopt_lane
# (reassign owner to the current POOL_OWNER_*, set connected=true, stamp last_seen_at, re-bind the
# daemon). Echoes the adopted lane N + return 0; or return 1 if no responsive orphan. Skips the
# ~5-10s Chrome boot + master copy (the Chrome is already running). NO reap, NO choose-N, NO launch.
#
# DESIGN — the acquire-vs-reuse-orphan SPLIT (research §1): the LANDED acquire critical section
# (_pool_acquire_critical_section @ ~line 1966) INLINES its OWN reuse-orphan loop (@ ~1977-1996),
# INTERLEAVED with reap (on a failed adopt it REAPS the lane, then continues — its goal is to CLAIM
# a lane). This PUBLIC function is REUSE-ONLY: it adopts the first responsive orphan and returns;
# on a failed adopt it falls through to the NEXT stale lane (NO reap); on exhaustion it returns 1.
# The CONTRACT's "Consumed by acquire step 3b" is LEGACY design intent (the LANDED acquire already
# inlines reuse-orphan); the REAL callers are a future acquire refactor / exhaustion retry / admin
# doctor reconcile. Do NOT wire this into acquire (the inline is shipped + correct).
#
# ⚠️ THE KEY DIVERGENCE FROM pool_reap_stale — FLOCK / SERIALIZATION (research §3): adoption is NOT
# collision-safe. Two concurrent adopters of the SAME orphan would both read the lease, both find it
# responsive, both rewrite .owner, both re-bind the daemon, and both echo lane N → BOTH believe they
# own N. (Contrast pool_reap_stale, which is idempotent — release twice = no-op → safely unflocked.)
# THEREFORE pool_reuse_orphan REQUIRES SERIALIZATION. DECISION: this function takes NO own flock; the
# CALLER MUST already hold an exclusive flock on $POOL_LOCK_FILE. This mirrors the codebase convention
# (ONLY pool_acquire_locked flocks; all building-block functions are lock-free) + pool_reap_stale.
#
# ⚠️ DO NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"` inside this function. flock(2) locks are bound
# per OPEN FILE DESCRIPTION (https://man7.org/linux/man-pages/man2/flock.2.html): a fresh
# 9>"$POOL_LOCK_FILE" redirect opens a NEW file description, so a blocking flock taken here while the
# caller already holds the lock via its own fd 9 is DENIED BY THE CALLER'S OWN LOCK → BLOCKS FOREVER
# (self-deadlock). The caller serializes; this function is lock-free.
#
# DELEGATE (do NOT duplicate — research §2/§6): the responsiveness gate is pool_daemon_connected
# (M4.T3.S1, READ-ONLY, never launches); the adoption (owner-reassign + connected + re-bind) is
# _pool_adopt_lane (M5.T1.S1). Do NOT re-inline the jq .owner mutation, pool_daemon_connect, or a
# raw curl /json/version probe (raw curl is INSUFFICIENT — adoption needs the daemon to know the
# session so the re-bind is meaningful).
#
# LOGIC (CONTRACT a→e):
#   guard. POOL_OWNER_PID numeric & !=0  else return 1   (passthrough owner must not adopt)
#   a. for n in $(pool_lanes_list)  — snapshot; empty ⇒ 0 iters.
#   b.   if pool_lane_is_stale "$n"; then   — TRI-STATE; the if-condition is errexit-exempt:
#          rc 0 (stale) → enter body;  rc 1 (live) / rc 2 (no lease) → fall through (skip).
#   c.      port/session = pool_lease_field "$n" (|| true inside $(); missing → "")
#          if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected "$session" "$port"; then
#   d.        if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi   # adopted → DONE
#                    # adopt rc 1 (Chrome died mid-race) → fall through, try the NEXT orphan
#          fi        # port=0 (provisional) OR not responsive → skip (NOT reaped; reuse-only)
#        fi
#   e. return 1   — no responsive orphan adopted; nothing echoed.
#
# CALLER CONTRACT (within a SERIALIZED context — caller holds $POOL_LOCK_FILE; under set -e):
#     local n
#     if n="$(pool_reuse_orphan)"; then
#         <proceed: the lane n is adopted, owner=reassigned, connected=true, daemon re-bound;
#          go straight to EXEC / ensure_connected>
#     else
#         <no responsive orphan: reap-sweep / claim-a-new-lane / block / alert>
#     fi
#
# GOTCHA — tri-state under set -e: a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or 2 (no
#   lease) ABORTS the caller. The `if …; then …; fi` is MANDATORY (the condition is errexit-exempt).
#   (pool_lane_is_stale GOTCHA @ ~line 1145-1148.)
# GOTCHA — responsiveness gate under set -e: pool_daemon_connected returns 1 (not responsive) → a
#   BARE call ABORTS. Use it under `&&`: `[[ port>0 ]] && pool_daemon_connected …` (the &&-list is
#   errexit-exempt; rc 1 short-circuits). Likewise `if _pool_adopt_lane "$n"; then …; fi` (rc 1
#   falls through to the next orphan).
# GOTCHA — port=0 provisional lease is NEVER an orphan: the `[[ -gt 0 ]]` gate rejects it (no Chrome
#   yet → nothing to reuse). It is skipped, NOT reaped (reuse-only).
# GOTCHA — adopt-failure-mid-race: the Chrome can die between the gate (pool_daemon_connected rc 0)
#   and the re-bind (pool_daemon_connect rc 1 inside _pool_adopt_lane) → _pool_adopt_lane rc 1 → fall
#   through to the next orphan. The racy lane is NOT reaped; a later reap sweep / acquire handles it.
# GOTCHA — stdout discipline: ONLY `printf '%s\n' "$n"` writes stdout (on success). Every helper is
#   stdout-clean. On return 1 NOTHING is echoed → `n=$(pool_reuse_orphan)` yields "". No extra
#   >/dev/null needed on _pool_adopt_lane (its pool_daemon_connect is already >/dev/null 2>&1; its
#   _pool_log is file-only). _pool_adopt_lane logs the adoption itself → no double-logging here.
# GOTCHA — `local var=$(…)` masks errexit (SC2155): split every capture (local declared FIRST,
#   assign AFTER); guard pool_lease_field's rc-1 with || true INSIDE the $().
# GOTCHA — NON-FATAL: never pool_die; returns 0 (adopted) / 1 (none). A corrupt lease ⇒ rc 2 skip;
#   a dead-Chrome lane ⇒ not responsive ⇒ skip; an empty pool ⇒ 0 iterations ⇒ return 1.
# GOTCHA — NO own flock (Design B): caller MUST hold $POOL_LOCK_FILE (adoption is not collision-safe).
#   Adding an inner flock SELF-DEADLOCKS (flock(2) per-OFD). See the WARNING block above.
# Reads POOL_LANES_DIR + POOL_OWNER_* (via _pool_adopt_lane) + POOL_REAL_BIN (via the helpers).
# PRECONDITION: pool_config_init + pool_owner_resolve  AND  the caller holds $POOL_LOCK_FILE.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck -s bash lib/pool.sh                        # zero warnings (whole file)
  - RUN: shellcheck -s bash lib/pool.sh | grep -i 'pool_reuse_orphan' || echo "OK no SC on new fn"
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_reuse_orphan' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: MIXED POOL — 1 orphan + 1 stale-dead-Chrome + 1 live + 1 provisional → rc 0; adopt the orphan ---
  - RUN (build a mixed pool with isolated state + test-hook owner overrides):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # The ADOPTER identity (current subshell): use the test-hook so POOL_OWNER_* is set.
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  # Lane 1: ORPHAN — dead owner 99998, but boot a REAL Chrome on it (responsive).
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  orphan_port="$(pool_lease_field 1 port)"
                  # Lane 2: STALE with a DEAD Chrome (owner 99997 dead; kill its chrome so it is not responsive).
                  pool_lease_write 2 "$POOL_EPHEMERAL_ROOT/2" 0 "abpool-2" 99997 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 2
                  pool_chrome_kill "$(pool_lease_field 2 chrome_pid)" "$(pool_lease_field 2 chrome_pgid)"
                  # Lane 3: LIVE (owner = $$ + correct comm + correct starttime) — must NOT be touched.
                  pool_lease_write 3 "$POOL_EPHEMERAL_ROOT/3" 0 "abpool-3" $$ pi "$st" "/tmp" 0 0 "false"
                  pool_boot_lane 3
                  live_port="$(pool_lease_field 3 port)"; live_cpid="$(pool_lease_field 3 chrome_pid)"
                  # PRE-checks:
                  curl -sf "http://127.0.0.1:$orphan_port/json/version" >/dev/null && echo "OK1-pre-orphan-alive" || echo "FAIL1-pre-orphan"
                  pool_lease_exists 1 && echo "OK1-pre-1" || echo "FAIL1-pre-1"
                  pool_lease_exists 3 && echo "OK1-pre-3" || echo "FAIL1-pre-3"
                  # REUSE-ORPHAN (set the adopter identity via test-hook in THIS call):
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       AGENT_BROWSER_POOL_OWNER_COMM=pi \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 0 ]] && echo "OK1-rc0" || echo "FAIL1-rc=$rc"
                  [[ "$n" == "1" ]] && echo "OK1-adopted-lane-1" || echo "FAIL1-lane=$n"
                  # ORPHAN lane 1 now belongs to the adopter ($$): owner.pid reassigned, connected=true.
                  newowner="$(pool_lease_field 1 owner.pid)"
                  conn="$(pool_lease_field 1 connected)"
                  [[ "$newowner" == "$$" ]] && echo "OK1-owner-reassigned" || echo "FAIL1-owner=$newowner"
                  [[ "$conn" == "true" ]] && echo "OK1-connected-true" || echo "FAIL1-connected=$conn"
                  # ORPHAN Chrome STILL alive (re-used, not killed):
                  curl -sf "http://127.0.0.1:$orphan_port/json/version" >/dev/null && echo "OK1-orphan-chrome-alive" || echo "FAIL1-orphan-chrome-dead"
                  # STALE-DEAD-CHROME lane 2 UNTOUCHED (reuse-only — NOT reaped): lease still present.
                  pool_lease_exists 2 && echo "OK1-lane2-untouched" || echo "FAIL1-lane2-reaped"
                  # LIVE lane 3 UNTOUCHED:
                  pool_lease_exists 3 && echo "OK1-lane3-lease" || echo "FAIL1-lane3-lease"
                  ps -p "$live_cpid" >/dev/null 2>&1 && echo "OK1-lane3-chrome-alive" || echo "FAIL1-lane3-chrome-dead"
                  # CLEANUP:
                  pool_release_lane 1 >/dev/null 2>&1 || true
                  pool_release_lane 2 >/dev/null 2>&1 || true
                  pool_release_lane 3 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK1-pre-orphan-alive ; OK1-pre-1 ; OK1-pre-3 ; OK1-rc0 ; OK1-adopted-lane-1 ;
        #         OK1-owner-reassigned ; OK1-connected-true ; OK1-orphan-chrome-alive ;
        #         OK1-lane2-untouched ; OK1-lane3-lease ; OK1-lane3-chrome-alive.
  #
  # --- SCENARIO 2: NO ORPHAN (all stale lanes have dead Chromes) → rc 1; nothing echoed ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  pool_chrome_kill "$(pool_lease_field 1 chrome_pid)" "$(pool_lease_field 1 chrome_pgid)"
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 1 ]] && echo "OK2-rc1" || echo "FAIL2-rc=$rc"
                  [[ -z "$n" ]] && echo "OK2-nothing-echoed" || echo "FAIL2-echoed=$n"
                  pool_lease_exists 1 && echo "OK2-lane1-untouched" || echo "FAIL2-lane1-reaped"
                  pool_release_lane 1 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK2-rc1 ; OK2-nothing-echoed ; OK2-lane1-untouched.
  #
  # --- SCENARIO 3: EMPTY POOL → rc 1; nothing echoed ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 1 ]] && echo "OK3-rc1" || echo "FAIL3-rc=$rc"
                  [[ -z "$n" ]] && echo "OK3-nothing-echoed" || echo "FAIL3-echoed=$n"'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK3-rc1 ; OK3-nothing-echoed.
  #
  # --- SCENARIO 4: ALL-LIVE POOL → rc 1; no lane touched ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" $$ pi "$st" "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  port="$(pool_lease_field 1 port)"; cpid="$(pool_lease_field 1 chrome_pid)"
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 1 ]] && echo "OK4-rc1" || echo "FAIL4-rc=$rc"
                  [[ -z "$n" ]] && echo "OK4-nothing-echoed" || echo "FAIL4-echoed=$n"
                  pool_lease_exists 1 && echo "OK4-lease" || echo "FAIL4-lease-gone"
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK4-chrome-alive" || echo "FAIL4-chrome-dead"
                  ps -p "$cpid" >/dev/null 2>&1 && echo "OK4-pid-alive" || echo "FAIL4-pid-gone"
                  pool_release_lane 1 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK4-rc1 ; OK4-nothing-echoed ; OK4-lease ; OK4-chrome-alive ; OK4-pid-alive.
  #
  # --- SCENARIO 5: PASSTHROUGH OWNER (POOL_OWNER_PID==0) → rc 1; nothing echoed ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Seed an orphan (responsive Chrome, dead owner).
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  orphan_port="$(pool_lease_field 1 port)"
                  # A passthrough owner: NO pi ancestor → pool_owner_resolve sets POOL_OWNER_PID=0.
                  n="$(bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                [[ \"\$POOL_OWNER_PID\" == \"0\" ]] || POOL_OWNER_PID=0   # force passthrough
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 1 ]] && echo "OK5-rc1" || echo "FAIL5-rc=$rc"
                  [[ -z "$n" ]] && echo "OK5-nothing-echoed" || echo "FAIL5-echoed=$n"
                  # Orphan UNTOUCHED (not adopted):
                  [[ "$(pool_lease_field 1 owner.pid)" == "99998" ]] && echo "OK5-owner-unchanged" || echo "FAIL5-owner-changed"
                  pool_release_lane 1 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK5-rc1 ; OK5-nothing-echoed ; OK5-owner-unchanged.
  #
  # --- SCENARIO 6: ADOPT-FAILURE-MID-RACE (responsive at gate, _pool_adopt_lane rc 1) → rc 1; lane NOT reaped ---
  #   Simulate the race: an orphan whose Chrome is responsive at the gate but DIES right before the
  #   re-bind. Easiest robust proxy: there is no clean hook into _pool_adopt_lane, so verify the
  #   FALL-THROUGH behavior structurally — an orphan that is NOT responsive (Chrome dead) is skipped
  #   and a SECOND candidate (if present) is tried. (This is the same code path: gate-fail ⇒ skip.)
  - RUN (two stale lanes; lane 1 Chrome dead (gate fails), lane 2 responsive → adopt lane 2):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  # Lane 1: stale, Chrome DEAD (gate will fail → skip, try next).
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  pool_chrome_kill "$(pool_lease_field 1 chrome_pid)" "$(pool_lease_field 1 chrome_pgid)"
                  # Lane 2: stale, Chrome RESPONSIVE (the adoptable orphan).
                  pool_lease_write 2 "$POOL_EPHEMERAL_ROOT/2" 0 "abpool-2" 99999 pi 2222 "/tmp" 0 0 "false"
                  pool_boot_lane 2
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 0 && "$n" == "2" ]] && echo "OK6-fell-through-to-lane-2" || echo "FAIL6-rc=$rc n=$n"
                  # Lane 1 NOT reaped (reuse-only):
                  pool_lease_exists 1 && echo "OK6-lane1-untouched" || echo "FAIL6-lane1-reaped"
                  pool_release_lane 1 >/dev/null 2>&1 || true
                  pool_release_lane 2 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK6-fell-through-to-lane-2 ; OK6-lane1-untouched.
  #
  # --- SCENARIO 7: FIRST-OF-MANY (lanes 1 + 3 both responsive orphans) → adopts the LOWEST N (1) ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  pool_lease_write 3 "$POOL_EPHEMERAL_ROOT/3" 0 "abpool-3" 99997 pi 3333 "/tmp" 0 0 "false"
                  pool_boot_lane 3
                  n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                       bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                                pool_reuse_orphan")"
                  rc=$?
                  [[ $rc -eq 0 && "$n" == "1" ]] && echo "OK7-lowest-N-1" || echo "FAIL7-rc=$rc n=$n"
                  # Lane 3 NOT adopted (its owner still the dead 99997):
                  [[ "$(pool_lease_field 3 owner.pid)" == "99997" ]] && echo "OK7-lane3-untouched" || echo "FAIL7-lane3-touched"
                  pool_release_lane 1 >/dev/null 2>&1 || true
                  pool_release_lane 3 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK7-lowest-N-1 ; OK7-lane3-untouched.
```

### Implementation Patterns & Key Details

```bash
# The reuse-orphan spine (research §1/§3/§6):
#   pool_reuse_orphan:
#     local n port session
#     [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1   # passthrough guard
#     for n in $(pool_lanes_list); do                       # snapshot; empty ⇒ 0 iters
#         if pool_lane_is_stale "$n"; then                   # tri-state; if=errexit-exempt (rc 1/2 skip)
#             port="$(pool_lease_field "$n" port 2>/dev/null || true)"    # split local; ||true inside $()
#             session="$(pool_lease_field "$n" session 2>/dev/null || true)"
#             if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
#                && pool_daemon_connected "$session" "$port"; then        # &&-list=errexit-exempt (rc 1 skip)
#                 if _pool_adopt_lane "$n"; then              # delegate; if=errexit-exempt (rc 1 → next)
#                     printf '%s\n' "$n"                       # ONLY stdout write
#                     return 0                                 # adopted → DONE
#                 fi
#             fi                                              # port=0 / not responsive → skip (NOT reaped)
#         fi
#     done
#     return 1                                                # no responsive orphan; nothing echoed

# The tri-state guard (research §4.1):
#   if pool_lane_is_stale "$n"; then …; fi
#   # rc 0 (stale) → body; rc 1 (live) / rc 2 (no lease) → fall through (skip). The `if`
#   # condition is errexit-exempt (bash manual -e exemption list). A BARE call ABORTS on rc 1/2.

# The responsiveness gate (research §4.1):
#   [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected "$session" "$port"
#   # the `[[ ]] && func` list is errexit-exempt: a non-numeric/zero port OR a non-responsive
#   # daemon (rc 1) short-circuits (skip the lane), NO abort. A BARE pool_daemon_connected ABORTS.

# The adoption delegation (research §2.1/§6):
#   if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi
#   # _pool_adopt_lane does owner-reassign + connected=true + last_seen_at + pool_daemon_connect.
#   # rc 0 → adopted (echo + return 0). rc 1 (Chrome died mid-race) → fall through to the next
#   # stale lane (NO reap — reuse-only). The `if` is errexit-exempt.

# The non-fatal port/session capture (research §4.2 — split local, || true INSIDE $()):
#   local port session
#   port="$(pool_lease_field "$n" port 2>/dev/null || true)"
#   # pool_lease_field returns 1 on a missing/corrupt lease (TOCTOU); the || true INSIDE the $()
#   # makes the capture set -e-safe (yields "" → the [[ -gt 0 ]] gate fails → skip). No "null"
#   # normalization needed here — an empty/"null" port simply fails the numeric gate.

# The NO-flock decision (research §3 — Design B):
#   # pool_reuse_orphan takes NO own flock. PRECONDITION: caller holds $POOL_LOCK_FILE.
#   # DO NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"` — flock(2) per-OFD → self-deadlock if
#   # called within an existing holder. Adoption is not collision-safe; the caller serializes.
```

### Integration Points

```yaml
LANES (read-only enumeration via pool_lanes_list; per-lane read via pool_lease_field):
  - enumerate: pool_lanes_list → $POOL_LANES_DIR/*.json (numeric stems, sort -n)
  - read: port + session via pool_lease_field (for the responsiveness gate)

DAEMON (side-effects — delegated, NOT direct):
  - responsiveness probe: pool_daemon_connected → $POOL_REAL_BIN --session <abpool-N> --json session list
                          + curl http://127.0.0.1:<port>/json/version   (READ-ONLY, never launches)
  - re-bind: _pool_adopt_lane → pool_daemon_connect → $POOL_REAL_BIN --session <abpool-N> connect <port>

LEASE (mutation — delegated to _pool_adopt_lane):
  - rewrite: .owner = {pid,comm,starttime,cwd from POOL_OWNER_*} | .connected = true | .last_seen_at = $now
             (jq --arg/--argjson DATA, inject-safe; _pool_atomic_write tmp+mv same FS)

GLOBALS (no new exports — reads only):
  - POOL_LANES_DIR (pool_lanes_list + pool_lease_field)
  - POOL_OWNER_PID / _COMM / _STARTTIME / _CWD (pool_owner_resolve → _pool_adopt_lane rewrites .owner)
  - POOL_REAL_BIN (the session-list + connect subprocesses, via the helpers)
  - POOL_LOCK_FILE (NOT used here; caller holds it — Design B)

CONSUMERS (downstream — NOT this task's concern, documented for context):
  - (FUTURE) _pool_acquire_critical_section refactor: extract its inlined reuse-orphan loop into a
        pool_reuse_orphan call (the LANDED acquire keeps its inline for now — S1 invariant).
  - M5.T4.S1 exhaustion retry: re-scan for an orphan after acquire returns 1.
  - M7.T4.S1 doctor reconcile: adopt responsive orphans (no `adopt` CLI in PRD §2.12).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after the function is appended + the banner tag bumped — fix before proceeding.
bash -n lib/pool.sh                              # syntax — MUST be clean (zero output)
shellcheck -s bash lib/pool.sh                   # whole file — zero warnings (ShellCheck 0.11.0)
shellcheck -s bash lib/pool.sh | grep -i 'pool_reuse_orphan' || echo "OK no SC on new fn"
# Expected: zero errors/warnings. If any exist, READ the output and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

The project has no bats harness yet (M9.T1.S1). Validate via the **host-verified scenarios in
Task 2** (real Chrome + real agent-browser + isolated state dirs + test-hook owner overrides), which
exercise every branch:

```bash
# Run each SCENARIO 1–7 from Task 2 in turn. Each is self-contained (mktemp state + EPHEM dirs,
# real master/chrome/agent-browser, cleanup at the end). EXPECT the documented OK* lines.

# Quick smoke (function callable, returns 1 on an empty pool, echoes nothing):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
         n="$(pool_reuse_orphan)"; echo "smoke n=[$n] rc=$?"'
# Expected: smoke n=[] rc=1.
```

### Level 3: Integration Testing (System Validation)

```bash
# Verify the adopted lane is genuinely DRIVABLE end-to-end (the daemon re-bind worked): after a
# successful adoption, the lane answers a real agent-browser command under its session.
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
          # Seed an orphan (responsive Chrome, dead owner).
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          port="$(pool_lease_field 1 port)"; session="abpool-1"
          # ADOPT it:
          n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
               bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                        pool_reuse_orphan")"
          [[ "$n" == "1" ]] || { echo "FAIL3-adopt n=$n"; pool_release_lane 1 >/dev/null 2>&1 || true; exit 1; }
          # The adopted lane must be DRIVABLE: a real agent-browser snapshot under the session.
          if "$POOL_REAL_BIN" --session "$session" snapshot >/dev/null 2>&1; then
              echo "OK3-adopted-lane-drivable"
          else
              echo "FAIL3-not-drivable"
          fi
          pool_release_lane 1 >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-adopted-lane-drivable.

# Idempotency-of-scan smoke — two back-to-back reuse_orphan calls on a pool with ONE orphan:
# the FIRST adopts it (rc 0, lane N); the SECOND finds nothing (the lane is now LIVE for the
# adopter → pool_lane_is_stale rc 1 → skip) → rc 1.
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          run() { AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                  bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                           pool_reuse_orphan"; }
          n1="$(run)"; r1=$?; n2="$(run)"; r2=$?
          [[ "$r1" -eq 0 && "$n1" == "1" ]] && echo "OK3-first-adopted" || echo "FAIL3-first r=$r1 n=$n1"
          [[ "$r2" -eq 1 && -z "$n2" ]] && echo "OK3-second-none" || echo "FAIL3-second r=$r2 n=$n2"
          pool_release_lane 1 >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-first-adopted ; OK3-second-none.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Verify stdout is EXACTLY the adopted lane token (no daemon/session-list/curl leakage): adopt an
# orphan, capture, assert a pure integer.
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          n="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
               bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                        pool_reuse_orphan")"
          [[ "$n" =~ ^[0-9]+$ && "$n" == "1" ]] && echo "OK4-clean-integer-capture" || echo "FAIL4-capture=[$n]"
          pool_release_lane 1 >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-clean-integer-capture.

# Stress — a pool with MANY responsive orphans: adopts the LOWEST N, returns immediately.
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          st="$(cat /proc/$$/stat | sed "s/.*)//;s/ .*//" )"
          for n in 2 4 6; do
              pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99998 pi 1111 "/tmp" 0 0 "false"
              pool_boot_lane "$n"
          done
          got="$(AGENT_BROWSER_POOL_OWNER_PID=$$ AGENT_BROWSER_POOL_OWNER_STARTTIME=$st \
                 bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; pool_owner_resolve
                          pool_reuse_orphan")"
          [[ "$got" == "2" ]] && echo "OK4-stress-lowest-2" || echo "FAIL4-stress-got=$got"
          for n in 2 4 6; do pool_release_lane "$n" >/dev/null 2>&1 || true; done'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-stress-lowest-2.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file).
- [ ] Level 2: all 7 scenarios from Task 2 print their documented `OK*` lines.
- [ ] Level 3: the adopted-lane-drivable test prints `OK3-adopted-lane-drivable`; the
      idempotency-of-scan test prints `OK3-first-adopted` + `OK3-second-none`.
- [ ] Level 4: the clean-integer-capture test prints `OK4-clean-integer-capture`; the 3-orphan
      stress prints `OK4-stress-lowest-2`.

### Feature Validation

- [ ] Mixed pool (orphan + stale-dead-Chrome + live + provisional): rc 0; `n`==orphan-lane; orphan
      owner reassigned + connected=true + daemon re-bound + Chrome still alive; stale-dead-Chrome +
      live + provisional lanes untouched (Scenario 1).
- [ ] No orphan (all stale dead-Chrome): rc 1; nothing echoed (Scenario 2).
- [ ] Empty pool: rc 1; nothing echoed (Scenario 3).
- [ ] All-live pool: rc 1; nothing echoed; no lane touched (Scenario 4).
- [ ] Passthrough owner (`POOL_OWNER_PID==0`): rc 1; nothing echoed; orphan untouched (Scenario 5).
- [ ] Adopt-fall-through: a non-responsive stale lane is skipped, the next responsive orphan is
      adopted; the skipped lane is NOT reaped (Scenario 6).
- [ ] First-of-many orphans: adopts the LOWEST N, returns immediately (Scenario 7).
- [ ] Stdout discipline: `n=$(pool_reuse_orphan)` captures EXACTLY one integer on success, empty on
      rc 1.
- [ ] DELEGATES to `pool_lane_is_stale` (verdict) + `pool_daemon_connected` (gate) +
      `_pool_adopt_lane` (adoption); does NOT re-inline owner-mutation / connect / curl.
- [ ] Uses `if pool_lane_is_stale "$n"; then …; fi` (NEVER a bare call).
- [ ] Gates with `[[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected …` (NEVER a
      bare `pool_daemon_connected`).
- [ ] Adopts under `if _pool_adopt_lane "$n"; then …; fi` (NEVER a bare call).
- [ ] Reads port/session with split-`local` + `|| true` INSIDE the `$()`.
- [ ] Guards `POOL_OWNER_PID` numeric & non-zero (passthrough owner must not adopt).
- [ ] Reuse-ONLY: NO `pool_release_lane` / `_pool_release_lane_internals` / `pool_find_free_lane`.
- [ ] Non-fatal: never `pool_die`; returns 0 or 1.
- [ ] NO own flock (Design B); docstring states the caller-must-hold-`$POOL_LOCK_FILE` precondition
      + the flock(2) self-deadlock warning.

### Code Quality Validation

- [ ] Follows existing codebase patterns (the `for n in $(pool_lanes_list)` idiom from
      `_pool_acquire_critical_section`; the `if pool_lane_is_stale` tri-state idiom; the
      `&& pool_daemon_connected` gate idiom from acquire's inline reuse-orphan; the
      `if _pool_adopt_lane` delegation; split-`local` captures; docstring with DESIGN + LOGIC +
      CALLER CONTRACT + GOTCHA sections — mirrors `pool_reap_stale` + `_pool_adopt_lane`).
- [ ] `pool_reuse_orphan` appended under the (banner-tag-bumped) "Reaper & orphan reuse" section
      after `pool_reap_stale`; NO edits to any existing function (esp. NOT
      `_pool_acquire_critical_section`'s inlined reuse-orphan loop).
- [ ] Every `local` capture is split; the non-fatal `pool_lease_field` captures are `|| true`-guarded.
- [ ] Anti-patterns avoided (see below): no owner-mutation/connect/curl duplication, no own flock,
      no pool_die, no bare `pool_lane_is_stale`/`pool_daemon_connected`/`_pool_adopt_lane`, no reap,
      no choose-N.

### Documentation & Deployment

- [ ] Code is self-documenting (the docstring's DESIGN block captures the acquire-vs-reuse-orphan
      split; the LOGIC block IS the spec; the GOTCHA block captures the flock/self-deadlock hazard,
      the tri-state/gate/adopt set-e hazards, the port=0 / adopt-failure-mid-race / stdout-discipline
      nuances).
- [ ] `_pool_adopt_lane` logs the adoption summary (lane + port + owner pid) — no double-logging.
- [ ] No new env vars (reads only the frozen POOL_LANES_DIR / POOL_OWNER_* / POOL_REAL_BIN via helpers).

---

## Anti-Patterns to Avoid

- ❌ Don't DUPLICATE the responsiveness check, the owner-mutation, or the daemon connect — DELEGATE
  to `pool_daemon_connected` (gate) + `_pool_adopt_lane` (adoption). Re-implementing the jq `.owner`
  mutation, `pool_daemon_connect`, or a raw `curl /json/version` probe duplicates verified logic +
  risks divergence (and raw curl is INSUFFICIENT — adoption needs the daemon to know the session).
- ❌ Don't wire `pool_reuse_orphan` into acquire — acquire (`_pool_acquire_critical_section`) has its
  OWN inlined reuse-orphan loop calling `_pool_adopt_lane` directly (intertwined with reap). This
  function is the PUBLIC REUSE-ONLY building block (the "consumed by acquire step 3b" CONTRACT is
  legacy design intent — exactly like S1's reap story).
- ❌ Don't add an own flock — adoption is NOT collision-safe, BUT `pool_reuse_orphan` taking its own
  `( flock 9; … ) 9>"$POOL_LOCK_FILE"` SELF-DEADLOCKS if called within an existing holder (flock(2)
  locks are bound per open-file-description; a fresh `9>file` opens a NEW OFD → denied by the
  caller's own lock → blocks forever). DESIGN B: the CALLER holds `$POOL_LOCK_FILE`; this function
  is lock-free. State the precondition + the deadlock warning in the docstring.
- ❌ Don't REAP or CHOOSE-N — this is reuse-ONLY. A non-responsive stale lane is SKIPPED (left for a
  later reap sweep / acquire), NOT reaped. On exhaustion (no orphan) return 1; the CALLER decides.
- ❌ Don't call `pool_lane_is_stale` / `pool_daemon_connected` / `_pool_adopt_lane` BARE — each can
  return rc 1 (or 2) and ABORT under `set -e`. Always guard: `if pool_lane_is_stale "$n"; then …`,
  `[[ port>0 ]] && pool_daemon_connected …`, `if _pool_adopt_lane "$n"; then …` (all errexit-exempt).
- ❌ Don't call `pool_die` — `pool_reuse_orphan` is NON-FATAL (returns 0 or 1; a corrupt lease /
  dead-Chrome lane / empty pool / passthrough owner are all clean `return 1` paths).
- ❌ Don't write to stdout except `printf '%s\n' "$n"` (on success). Every helper is stdout-clean, so
  no extra `>/dev/null` is needed — but do NOT add `echo`/`printf` debug lines that would pollute the
  lane capture. On `return 1`, echo NOTHING.
- ❌ Don't adopt a `port=0` (provisional) lane — it has no Chrome yet (nothing to reuse). The
  `[[ "$port" -gt 0 ]]` gate rejects it.
- ❌ Don't double-log — `_pool_adopt_lane` already logs the adoption
  ("pool_acquire(adopt): reused orphan lane N …"). `pool_reuse_orphan` adds NO `_pool_log` line.
- ❌ Don't write `local X="$(…)"` — `local` masks errexit (BashFAQ 105 / SC2155). Split it, and put
  `|| true` INSIDE the `$()` for the non-fatal `pool_lease_field` captures.
- ❌ Don't create private helpers or new files — the body is ~12 lines; one function delegating to
  `_pool_adopt_lane` reads cleaner. Append to `lib/pool.sh` under the existing banner; bump the tag;
  nothing else.
- ❌ Don't implement `pool_reap_stale` (M5.T3.S1 — ALREADY LANDED), the acquire refactor (M5.T1.S1 —
  keep its inline), the exhaustion handler (M5.T4), the admin CLI (M7), or the wrapper (M6) — out of
  scope. This task ships `pool_reuse_orphan` ONLY.
