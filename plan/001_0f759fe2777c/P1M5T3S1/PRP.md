# PRP — P1.M5.T3.S1: `pool_reap_stale()` — scan all lanes, release stale ones

---

## Goal

**Feature Goal**: Implement **`pool_reap_stale()`** — the **lazy reaper** (PRD §2.10): a
function that scans **every** lane (`pool_lanes_list`), asks the tri-state predicate
`pool_lane_is_stale` (rc 0=stale / 1=live / 2=no-lease) whether each lane's owner is
dead/recycled/unverifiable, and for every **stale** lane calls the PUBLIC `pool_release_lane`
(full teardown: daemon `close` + Chrome pgroup kill + `rm -rf` ephemeral dir + delete lease).
It then **echoes the reaped count** to stdout for observability and `return 0`. No input, no
flock, no background daemon (PRD §2.10: lazy, on demand).

This is the **outside-the-flock**, **daemon-`close`-inclusive** reaper — the deliberate
complement to acquire's OWN inlined reap loop (`_pool_acquire_critical_section`,
`lib/pool.sh:1966-1994`), which reaps with the PRIVATE `_pool_release_lane_internals` kernel
directly **inside** the short flock (where the `close` subprocess is forbidden — PRD §2.19 /
`architecture/key_findings.md` FINDING 2). The item CONTRACT's "Consumed by acquire step 3a"
is **legacy design intent**: the LANDED acquire already inlines its own reap; the REAL consumer
of this function is the **on-demand admin reap command** (`agent-browser-pool reap`, M7.T2 /
PRD §2.10 "on demand" + §2.12), with exhaustion force-reap (M5.T4) as possible future caller.

The function implements the item CONTRACT verbatim:
**a.** `for n in $(pool_lanes_list)` — iterate ALL lanes (snapshot).
**b.** `if pool_lane_is_stale "$n"; then …; fi` — tri-state verdict:
   - rc **0** (stale) → `pool_release_lane "$n"`; `_pool_log "…reaped stale lane N (owner pid P dead/recycled)…"`; `reaped=$((reaped+1))`.
   - rc **1** (live) → skip (falls through the `if`).
   - rc **2** (no lease) → skip (falls through the `if`).
**c.** `printf '%s\n' "$reaped"` — echo the count (observability).
**d.** `return 0`.

**Deliverable**: One PUBLIC function `pool_reap_stale()`, appended to `lib/pool.sh` under a new
banner **`# Reaper & orphan reuse (P1.M5.T3.S1)`** directly AFTER `pool_release_lane` (the
current EOF — `lib/pool.sh:2480`, the M5.T2.S1 deliverable). **Pure addition: no edits to any
existing function, no new private helpers, no new env-vars/globals, no new files, no flock.**
It COMPOSES three LANDED functions — `pool_lanes_list` (M3.T2.S1) + `pool_lane_is_stale`
(M3.T2.S3) + `pool_release_lane` (M5.T2.S1) — plus `pool_lease_field` (M3.T1.S2) for the log
line's owner pid and `_pool_log` (M1.T2.S1).

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init`, given a pool with a mix of
  lanes — some stale (dead owner pid), some live (owner `$$` + correct comm + starttime), one
  corrupt lease, and a non-numeric stray `*.json` artifact — calling `reaped="$(pool_reap_stale)"`
  returns **rc 0**, echoes exactly one integer line = the count of stale lanes reaped, and:
  (a) every stale lane's Chrome pgroup is **dead**, its ephemeral dir is **gone**, its lease
  file is **gone** (`pool_lease_exists N` ⇒ 1); (b) every LIVE lane is **untouched** (its
  lease/port/chrome/dir all still present + the Chrome still responds); (c) the corrupt lease
  is **skipped** (rc 2), NOT reaped, NOT deleted; (d) the non-numeric artifact is **skipped**
  by `pool_lanes_list` (never appears in the iteration).
- **Empty pool**: with no `lanes/` dir (or an empty one), `pool_reap_stale` echoes `0` + rc 0
  (zero iterations — `pool_lanes_list` returns nothing).
- **All-live pool**: `pool_reap_stale` echoes `0` + rc 0; no lane is touched (every verdict is
  rc 1 → falls through).
- **Idempotent re-reap**: run `pool_reap_stale` twice back-to-back → both rc 0; the first
  reaps the stale lanes, the second echoes `0` (everything stale was already reaped).
- **Concurrent with acquire**: a `pool_reap_stale` sweep running while a `pool_acquire_locked`
  claims a lane never corrupts the count and never aborts either side (release is idempotent;
  no flock on either's reap path conflicts).
- **stdout discipline**: `count=$(pool_reap_stale)` captures EXACTLY one integer token (the
  reaped count), even when lanes are reaped — because `pool_release_lane "$n" >/dev/null`
  suppresses the daemon `close` subprocess's stdout, and `_pool_log` writes to the log FILE.
- **Non-fatal always**: `pool_reap_stale` NEVER calls `pool_die` and NEVER returns non-zero.
  A TOCTOU race (lease deleted between `pool_lane_is_stale` and `pool_release_lane`) degrades
  to a clean idempotent no-op (`pool_release_lane` returns 0 on a missing lease).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` clean (whole file, zero
  warnings — host-verified ShellCheck 0.11.0); all prior deliverables (M1–M5.T2.S1) unchanged
  and still callable.

## User Persona

**Target User**: Internal only — never called by an end user directly. Its consumers (per the
item CONTRACT §4 + PRD §2.10/§2.12, all OUTSIDE any flock):

- **M7.T2.S1 `pool_admin_reap`** — the `agent-browser-pool reap` CLI command (PRD §2.10 "on
  demand via `agent-browser-pool reap`"; §2.12 admin CLI). The PRIMARY consumer: calls
  `count="$(pool_reap_stale)"` then reports "Reaped N lane(s)" to the admin.
- **M5.T4.S1 exhaustion force-reap** — POSSIBLE consumer (PRD §2.9 block→force-reap→alert).
  M5.T4 may call `pool_reap_stale` for a full sweep when the pool is full of dead-owner lanes,
  OR force-`pool_release_lane` a specific oldest dead-owner lane. Either way, `pool_reap_stale`
  is the documented full-sweep entry point.
- **(NOT M5.T1.S1 acquire step 3a)** — the LANDED acquire critical section inlines its OWN reap
  loop calling the PRIVATE `_pool_release_lane_internals` directly (the `close` subprocess is
  forbidden under the short flock). `pool_reap_stale` is NOT wired into acquire. This is the
  designed split (research §1); do NOT change it.

**Use Case**: A pi agent crashed mid-task. Its owner pid died but its Chrome (process group) +
ephemeral dir + lease file linger. An admin runs `agent-browser-pool reap`; `pool_reap_stale`
scans every lane, `pool_lane_is_stale` flags the dead-owner lane (rc 0), and
`pool_release_lane` tears it down (daemon disconnect + Chrome kill + dir remove + lease
delete), freeing lane N for the next acquire. The admin sees "Reaped 1 lane(s)". OR a future
exhaustion handler calls it when the pool is full of dead-owner lanes to free space before
blocking/alerting.

**Pain Points Addressed**:
- **Dead-owner lanes accumulate** without an explicit teardown. The lazy reaper reclaims them
  on demand (PRD §2.10) — Chrome renderers/GPU/utility children (the whole pgroup, via
  `pool_release_lane` → `pool_chrome_kill`), the bound daemon session, the ephemeral dir, and
  the lease — in one sweep.
- **One bad lane must never abort the pool.** Every step is non-fatal + idempotent: a missing
  lease (TOCTOU), a corrupt lease (skipped, rc 2), an already-dead Chrome (kill is `|| true`),
  or a re-release are all clean no-ops. `return 0` always.
- **Observability without stdout pollution.** The reaped count is the ONLY stdout write; all
  per-lane diagnostics go to the log file. The admin reap command captures the count cleanly.

## Why

- **This IS PRD §2.10 "Reaper"** — the lazy, on-demand stale-lease cleanup. No background
  daemon by default; a crashed agent's Chrome+dir is reclaimed either at the next acquire
  (acquire's inlined reap) OR by an explicit `pool_reap_stale` (via `agent-browser-pool reap`).
- **It is the OUTSIDE-the-flock complement to acquire's inlined reap.** Acquire reaps with the
  private kernel under the short flock (no `close` subprocess allowed). The standalone reaper
  runs OUTSIDE any flock and uses the PUBLIC `pool_release_lane` — which DOES run the daemon
  `close` (full teardown incl. daemon disconnect, PRD §2.5). Both are correct because release
  is idempotent; neither needs to exclude the other.
- **Composes, does not duplicate.** It reuses the LANDED staleness predicate
  (`pool_lane_is_stale`, M3.T2.S3) and the LANDED teardown (`pool_release_lane`, M5.T2.S1).
  Re-implementing the owner-liveness check or the kill/rm/close logic would duplicate two
  carefully-verified functions + risk divergence.
- **Non-fatal is non-negotiable.** It runs from admin tooling / sweeps under `set -euo
  pipefail`; one stale-but-racy or corrupt lane must never abort the sweep. Every verdict is
  tri-state-guarded (`if …; then …; fi` is errexit-exempt); every release is idempotent
  (`return 0` always).

## What

User-visible behavior: none directly (internal library function). Observable contract:

| scenario | call | result |
|---|---|---|
| 2 stale + 1 live + 1 corrupt lease | `count="$(pool_reap_stale)"` | **rc 0**; `count`==`2`; both stale lanes' Chrome DEAD + dir GONE + lease GONE; the live lane UNTOUCHED; the corrupt lease skipped (still present) |
| empty pool (no lanes dir) | `pool_reap_stale` | **rc 0**; echoes `0`; nothing touched |
| all-live pool | `pool_reap_stale` | **rc 0**; echoes `0`; no lane touched |
| re-reap (after a reap) | `pool_reap_stale` | **rc 0**; echoes `0` (everything stale already reaped) |
| TOCTOU (lease deleted between verdict + release) | (internal) | stale verdict rc 0 → `pool_release_lane` returns 0 (no-op on missing lease) → counted; clean |
| concurrent acquire | (internal) | no abort either side; count not corrupted; release is idempotent |
| non-numeric stray `lanes/foo.json` | (internal) | skipped by `pool_lanes_list` (never iterated) |

**Hard invariants** (every row):
- **`pool_reap_stale` NEVER calls `pool_die` and NEVER returns non-zero.** It is NON-FATAL
  always (verdicts are tri-state-guarded; `pool_release_lane` returns 0 always; the pid read
  is `|| true`). It runs from admin tooling / sweeps where one racy lane must never abort.
- **DELEGATE — do NOT duplicate.** The staleness verdict comes from `pool_lane_is_stale`; the
  teardown from `pool_release_lane`. Do NOT re-inline `pool_owner_alive`, `pool_chrome_kill`,
  or the `rm -rf`/`close` logic. (DRY + the M3.T2.S3/M5.T2.S1 contracts.)
- **Use `pool_lane_is_stale` under an `if` — NEVER bare.** A bare call whose rc is 1 (live) or
  2 (no lease) **ABORTS** under `set -e` (`pool_lane_is_stale` GOTCHA @ `lib/pool.sh:1145-1148`).
  The `if pool_lane_is_stale "$n"; then …; fi` is errexit-exempt — rc 1/2 fall through.
- **`reaped=$((reaped + 1))` — NEVER `(( reaped++ ))`.** The command form `(( reaped++ ))`
  returns rc 1 when the pre-increment value is 0 → **ABORTS on the first reap**. Use the
  assignment form (research §3.2).
- **Read the owner pid BEFORE releasing.** `pool_release_lane` deletes the lease; read
  `owner.pid` via `pool_lease_field` first (best-effort `|| true`; normalize `"null"`→`"?"`).
- **Stdout discipline.** ONLY `printf '%s\n' "$reaped"` writes to the function's stdout.
  Redirect `pool_release_lane "$n" >/dev/null` so the daemon `close` subprocess cannot pollute
  the count capture. `_pool_log` writes to the log FILE (not stdout) → safe.
- **NO flock.** Release is lane-local + idempotent; a concurrent acquire's in-lock reap of the
  same lane is a harmless no-op. Flocking the sweep would serialize it against acquire. (§4.)
- **Every `local` capture is split** (`local X; X="$(…)"` — BashFAQ 105 / SC2155) and the
  non-fatal `pool_lease_field` capture is guarded with `|| true` inside the `$()`.

### Success Criteria

- [ ] `pool_reap_stale` defined in `lib/pool.sh` under a `# Reaper & orphan reuse (P1.M5.T3.S1)`
      banner, appended after `pool_release_lane`. Callable after `source lib/pool.sh` +
      `pool_config_init`.
- [ ] Mixed pool: 2 stale + 1 live + 1 corrupt → rc 0; count==2; stale lanes fully torn down;
      live lane untouched; corrupt lease skipped (not deleted).
- [ ] Empty pool → echoes `0`; rc 0.
- [ ] All-live pool → echoes `0`; rc 0; no lane touched.
- [ ] Re-reap idempotent → rc 0; echoes `0`.
- [ ] `count=$(pool_reap_stale)` captures EXACTLY one integer (stdout discipline).
- [ ] Non-fatal always: never `pool_die`, never non-zero.
- [ ] NO flock; delegates to `pool_lane_is_stale` + `pool_release_lane` (no re-implementation).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file);
      all prior deliverables (M1–M5.T2.S1) unchanged + callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the **acquire-vs-reaper split** (the
defining architectural fact — research §1: acquire inlines its OWN reap loop with the private
kernel under the flock; `pool_reap_stale` is the outside-the-flock public-reaper complement);
the **dependency contracts** (research §2 — the tri-state `pool_lane_is_stale`, the always-0
idempotent `pool_release_lane`, the `pool_lanes_list` iterator, the nested-path
`pool_lease_field`, the file-only `_pool_log`); the **bash correctness** (research §3 — the
`if`-exemption, the `reaped=$((…+1))` vs `(( …++ ))` trap, the word-split idiom, snapshot
iteration); the **flock verdict** (research §4 — no flock); the **stdout-discipline
requirement** (research §5 — redirect `pool_release_lane >/dev/null`); the **pid-for-log
approach** (research §6); the **full verbatim-ready implementation** (Implementation Tasks
Task 1); and copy-pasteable, host-verified validation commands (a mixed-pool test, an
empty-pool test, an all-live test, a re-reap idempotency test, a stdout-capture test, and a
concurrent-with-acquire smoke test).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.10 (Reaper — lazy, on acquire + on demand via `agent-browser-pool reap`; NO background
        daemon by default). §2.4 step 3a (REAP-STALE inside acquire). §2.5 (Release semantics —
        the teardown `pool_release_lane` performs). §2.8 (lease schema — owner.{pid,comm,starttime}
        + session). §2.9 (exhaustion force-reap — possible consumer). §2.12 (admin CLI reap).
        §2.14 (the three stale failure modes: pid dead / comm!=pi / starttime mismatch). §2.19
        (flock = SHORT, ACQUIRE-ONLY — the standalone reaper runs OUTSIDE it).
  pattern: §2.10 IS pool_reap_stale; §2.12's `reap` calls it + reports the count.
  gotcha: §2.4 step 3a says "REAP-STALE" runs inside acquire — but the LANDED acquire inlines its
        OWN loop with the PRIVATE kernel (the `close` subprocess is forbidden under the flock).
        pool_reap_stale is the OUTSIDE-the-flock reaper for the admin reap command (research §1).

# This task's own research (THE evidence base — read in full)
- file: plan/001_0f759fe2777c/P1M5T3S1/research/reap-stale-design.md
  why: §1 (the acquire-vs-reaper split — the defining fact); §2 (the 5 dependency contracts with
        line numbers + the tri-state + the always-0 idempotent release); §3 (bash correctness —
        the `if`-exemption, the arithmetic trap, the word-split idiom, snapshot iteration,
        ShellCheck 0.11.0 host-verified clean); §4 (NO flock); §5 (stdout discipline — redirect
        release stdout); §6 (the pid-for-log approach); §7 (naming/placement/scope); §8
        (decisions table).
  pattern: §1 + §2 + §3 IS the implementation spine.
  gotcha: §5 (stdout discipline — the daemon close subprocess is NOT stdout-redirected inside
        pool_release_lane) + §3.2 (`(( reaped++ ))` ABORTS when reaped==0) are the two
        highest-impact facts.

# Architecture
- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 2 (SHORT flock — scan+reap+choose+claim under lock; boot/teardown OUTSIDE; ⇒ the
        standalone reaper's daemon close runs outside the flock). FINDING 6 (setsid → pgid==pid;
        `kill -- -<pgid>` tears the whole tree — performed by pool_release_lane's kernel). The
        naming-recommendation block (`pool_reap_*` family).

# The LANDED functions this task COMPOSES (treated as CONTRACT — already in lib/pool.sh)
- file: plan/001_0f759fe2777c/P1M3T2S3/PRP.md   # pool_lane_is_stale (M3.T2.S3 — LANDED @1164)
  why: the TRI-STATE verdict (0=stale/1=live/2=no-lease). Read-only; composes pool_lease_read +
        pool_owner_alive. The `if pool_lane_is_stale "$n"; then reap; fi` idiom is documented
        here as the canonical reaper pattern. SET -e HAZARD: a bare call ABORTS on rc 1/2.
- file: plan/001_0f759fe2777c/P1M5T2S1/PRP.md   # pool_release_lane (M5.T2.S1 — LANDED @2438, EOF)
  why: the PUBLIC teardown this task calls per stale lane. Returns 0 ALWAYS (idempotent,
        non-fatal). Runs `$POOL_REAL_BIN --session … close 2>/dev/null` (NOTE: stdout NOT
        redirected inside it) → `_pool_release_lane_internals`. NO flock. This task MUST redirect
        its stdout (`>/dev/null`) so the close subprocess can't pollute the count capture (§5).
        Its CALLER-CONTRACT docstring (@ ~line 2418) gives the EXACT reaper idiom this task
        implements: `for n in $(pool_lanes_list); do if pool_lane_is_stale "$n"; then
        pool_release_lane "$n"; fi; done`.
- file: plan/001_0f759fe2777c/P1M3T2S1/PRP.md   # pool_lanes_list (M3.T2.S1 — LANDED @967)
  why: the iterator. Returns newline-separated, numerically-sorted lane numbers; rc 0 ALWAYS;
        empty/missing dir ⇒ 0 iterations. `for n in $(pool_lanes_list)` is the documented idiom.
        nullglob NOT set ⇒ non-numeric `*.json` artifacts are rejected by `[[ -f ]]`.
- file: plan/001_0f759fe2777c/P1M3T1S2/PRP.md   # pool_lease_field (M3.T1.S2 — LANDED @876)
  why: nested-path read (`owner.pid` via getpath($f|split("."))). Returns 1 on missing/corrupt
        (NON-FATAL); echoes `"null"` for a missing path. Used for the log line's owner pid.
- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md   # _pool_log (M1.T2.S1 — LANDED @39)
  why: the file logger. Variadic message → ISO-8601 timestamped line to the LOG FILE (+
        stderr fallback). Writes to the file/stderr, NEVER stdout ⇒ safe inside the count-capture
        function. Never fails the caller.

# External authoritative docs (for the WHY; behavior is host-verified in research §3)
- url: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
  why: the `-e` exemption list — the condition following `if`/`elif`/`while`/`until` is exempt,
        so `if pool_lane_is_stale "$n"; then …; fi` does NOT abort on rc 1/2. This is why the
        tri-state predicate is safe under an `if` and fatal when bare.
  section: `-e` (the exemption list paragraph).
- url: https://mywiki.wooledge.org/BashFAQ/105
  why: "Why doesn't set -e do what I expected?" — the `local X=$(…)` masking (SC2155) + the
        `(( i++ ))`-aborts-when-zero trap (the reason to use `reaped=$((reaped+1))`).
- url: https://www.gnu.org/software/bash/manual/html_node/Compound-Commands.html
  why: `(( expression ))` returns rc 1 when the value is 0 → the arithmetic-command trap.
  section: `(( ))`.
- url: https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html
  why: command substitution is a SNAPSHOT (fully evaluated before the loop runs) → mid-loop
        releases cannot mutate the iteration set; `$()` strips trailing newlines.
```

### Current Codebase tree

After **M1–M5.T2.S1** have landed, `lib/pool.sh` (2480 lines) ends with `pool_release_lane` as
the final function (@2438, closing brace @2480):

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # empty (M6 populates)
├── lib/
│   └── pool.sh                           # ends (after M5.T2.S1) with pool_release_lane at EOF.
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
│                                         #   pool_release_lane  ← current EOF (closing brace @2480)
├── test/.gitkeep                         # empty (bats harness is M9.T1.S1)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1…P1M5T2S1/PRP.md
    └── P1M5T3S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/reap-stale-design.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND ONE function under a new banner AFTER pool_release_lane (EOF):
                  #   # Reaper & orphan reuse (P1.M5.T3.S1)
                  #   pool_reap_stale():   # PUBLIC — the CONTRACT name (lazy reaper)
                  #       a. for n in $(pool_lanes_list)                       # snapshot; empty ⇒ 0 iters
                  #       b.   if pool_lane_is_stale "$n"; then                # tri-state; if=errexit-exempt
                  #              pid = pool_lease_field "$n" owner.pid (|| true; "null"→"?")
                  #              pool_release_lane "$n" >/dev/null             # full teardown (close+kill+rm+rmlease)
                  #              _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
                  #              reaped=$((reaped + 1))                        # assignment form (safe)
                  #            fi                                            # rc 1 (live) / rc 2 (no lease) → skip
                  #       c. printf '%s\n' "$reaped"                          # ONLY stdout write (observability)
                  #       d. return 0                                         # non-fatal always
                  #   (NO changes to any existing function — esp. NOT _pool_acquire_critical_section's
                  #    inlined reap loop / pool_release_lane / pool_lane_is_stale / pool_lanes_list)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask adds the
**public lazy reaper** sweep (PRD §2.10) — the idempotent, non-fatal, outside-the-flock scan
that releases every stale lane and echoes the count. It COMPOSES `pool_lanes_list` (iteration)
+ `pool_lane_is_stale` (verdict) + `pool_release_lane` (teardown) + `pool_lease_field` (pid for
log) + `_pool_log` (observability). It reads `POOL_LANES_DIR` (via the helpers). It writes
nothing new (the helpers do the rm/close; the count is a local variable).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (acquire vs reaper split — research §1): the LANDED acquire critical section
#   (_pool_acquire_critical_section @ lib/pool.sh:1966) has its OWN inlined reap loop that calls
#   the PRIVATE _pool_release_lane_internals directly (NOT pool_release_lane, NOT pool_reap_stale)
#   because the daemon close subprocess is FORBIDDEN under the short acquire flock (PRD §2.19).
#   pool_reap_stale is the OUTSIDE-the-flock reaper: it calls the PUBLIC pool_release_lane (which
#   DOES run close). Do NOT wire pool_reap_stale into acquire; do NOT change acquire's loop.
#   The CONTRACT's "Consumed by acquire step 3a" is legacy design intent — the real consumer is
#   the admin reap command (M7.T2). Document this in the docstring.

# CRITICAL (tri-state predicate under set -e — research §3.1, pool_lane_is_stale GOTCHA
#   @ lib/pool.sh:1145-1148): a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or 2 (no
#   lease) ABORTS the caller under set -e. The MANDATORY idiom is `if pool_lane_is_stale "$n";
#   then reap; fi` — the if-condition is errexit-exempt; rc 1/2 fall through cleanly; only rc 0
#   (stale) enters the body. (Bash manual -e exemption list.)

# CRITICAL (arithmetic trap — research §3.2): use `reaped=$((reaped + 1))` (assignment form,
#   exit 0). NEVER `(( reaped++ ))` — the COMMAND form returns rc 1 when the pre-increment value
#   is 0 → ABORTS under set -e on the FIRST reap (when reaped==0). (BashFAQ 105 / Bash manual
#   Compound Commands `(( ))`.)

# CRITICAL (stdout discipline — research §5): pool_release_lane runs
#   `$POOL_REAL_BIN --session … close 2>/dev/null` — only STDERR is redirected inside it; the
#   close subprocess's STDOUT is NOT redirected. If close emits anything to stdout it would
#   pollute `count=$(pool_reap_stale)`. FIX: redirect pool_release_lane's stdout within the loop:
#       pool_release_lane "$n" >/dev/null
#   _pool_log writes to the LOG FILE (+ stderr fallback), NEVER stdout → safe (keeps firing).
#   The ONLY stdout write from pool_reap_stale itself is `printf '%s\n' "$reaped"`. (pool_lanes_list's
#   lane-number stdout is captured in the `for … in $()` list-substitution, NOT the function's
#   stdout — so it cannot pollute the count.)

# CRITICAL (DELEGATE — do NOT duplicate — research §2/§4): the staleness verdict comes from
#   pool_lane_is_stale (M3.T2.S3); the teardown from pool_release_lane (M5.T2.S1). Do NOT re-inline
#   pool_owner_alive / pool_chrome_kill / the rm-rf / the close. Re-implementing duplicates two
#   verified functions + the prefix-guarded rm logic + risks divergence.

# CRITICAL (read pid BEFORE release — research §6): pool_release_lane DELETES the lease (via its
#   kernel). Read owner.pid via pool_lease_field FIRST (best-effort `|| true`; normalize
#   "null"/empty → "?"). The verdict already confirmed the lease was readable (rc 0 stale), so
#   the TOCTOU window is tiny + the fallback makes it bulletproof.

# CRITICAL (NON-FATAL always — never pool_die, never non-zero — research §3/§4): pool_reap_stale
#   runs from admin tooling / sweeps under `set -euo pipefail` (lib/pool.sh line 17). A TOCTOU
#   missing lease, a corrupt lease (rc 2 skip), an already-dead Chrome (kill is `|| true`), or a
#   re-release are all clean no-ops. pool_release_lane returns 0 always; the pid read is `|| true`;
#   `return 0` always. Do NOT add any path that could return non-zero or call pool_die.

# CRITICAL (NO flock — research §4): pool_reap_stale does NOT acquire the lock. Rationale: release
#   is lane-local + idempotent (kill a specific pid, rm a specific dir, rm a specific lease, close
#   a specific session — all `|| true`); a concurrent acquire's in-lock reap of the SAME lane is a
#   harmless idempotent no-op. Flocking the WHOLE sweep would serialize it vs acquire (the daemon
#   close subprocesses take time) — harmful. The pool_lanes_list snapshot is taken once; lanes that
#   appear/disappear mid-sweep are handled by the per-lane tri-state check + idempotent release.

# GOTCHA (`local var=$(...)` masks errexit — research §3.2 / BashFAQ 105 / SC2155): `local X="$(…)"`
#   — local returns 0 always, so set -e does NOT fire on a failing $(…). EVERY capture MUST be split:
#       local pid
#       pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
#   The `|| true` is INSIDE the $() so the capture is set -e-safe against pool_lease_field's rc 1.

# GOTCHA (pool_lease_field echoes literal "null" for a missing path — research §6): guard BOTH
#   empty AND "null", default to "?" for the log:
#       [[ -n "$pid" && "$pid" != "null" ]] || pid="?"

# GOTCHA (snapshot iteration — research §3.3): `for n in $(pool_lanes_list)` captures the list
#   ONCE before the loop (command substitution is fully evaluated up front). Releasing lanes
#   mid-loop (deleting leases) CANNOT mutate the iteration set. A new lane not in the snapshot is
#   not reaped this pass (reaped next pass); a lane deleted between list + check → pool_lane_is_stale
#   rc 2 → skip. Correct.

# GOTCHA (ShellCheck — host-verified): ShellCheck 0.11.0 does NOT flag `for n in $(pool_lanes_list)`
#   as SC2046 in this context — `shellcheck -s bash lib/pool.sh` exits 0 on the current file (which
#   already contains the identical idiom at line 1975 in acquire). NO disable directive needed.

# GOTCHA (naming + placement — research §7): pool_reap_stale (PUBLIC, CONTRACT name, NO `_`
#   prefix). Starts the M5.T3 banner (the sibling M5.T3.S2 reuse_orphan appends under the SAME
#   banner later). APPEND at EOF after pool_release_lane. NO new private helpers (the body is
#   ~12 lines; fragmenting would hurt readability). Do NOT touch any existing function.

# GOTCHA (scope — reap sweep ONLY): do NOT implement reuse_orphan (M5.T3.S2), admin reap CLI
#   (M7.T2 — calls this function), exhaustion force-reap (M5.T4), or the wrapper (M6). Do NOT add
#   a flock. Do NOT touch acquire's inlined reap loop. Do NOT add new env vars / globals / files.
#   This task ships pool_reap_stale ONLY.
```

## Implementation Blueprint

### Data models and structure

This subtask defines **no on-disk layout change** and **no new env vars / globals exported**.
It reads the lease schema (PRD §2.8, frozen by M3.T1.S1) — specifically `owner.pid` (for the
log line) via `pool_lease_field` — and delegates all destructive work to `pool_release_lane`.

Global READ (frozen by `pool_config_init`):

| global | source | role |
|---|---|---|
| `POOL_LANES_DIR` | pool_config_init | lane enumeration (`pool_lanes_list`) + per-lane reads (`pool_lease_field`, via `pool_release_lane`) |
| `POOL_REAL_BIN` | pool_config_init | the daemon `close` subprocess (via `pool_release_lane`; NOT read directly here) |
| `POOL_EPHEMERAL_ROOT` | pool_config_init | dir removal (via `pool_release_lane`'s kernel; NOT read directly here) |

External commands (all present on host; verified this session): `jq` (via `pool_lease_field`),
`agent-browser` `$close` (via `pool_release_lane`), `rm`/`kill` (via the kernel).

**Naming** (CONTRACT-mandated + codebase convention): `pool_reap_stale` (public, CONTRACT name,
no `_`; matches the `pool_reap_*` family in the architecture naming recommendation). **No
private helpers** — the body is ~12 lines + linear; composing three LANDED functions keeps it
short. Fragmenting into `_pool_*` helpers would hurt readability.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_config_init pool_lanes_list pool_lane_is_stale \
                  pool_release_lane pool_lease_field _pool_log'
  - EXPECT: all reported as functions (M1–M5.T2.S1 LANDED). If pool_release_lane is MISSING →
        STOP (the teardown function this task calls does not exist; M5.T2.S1 must land first).
        If pool_reap_stale ALREADY EXISTS → STOP (someone implemented it already; reconcile).
  - RUN (verify the globals + the tri-state verdict):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 [[ -n "$POOL_LANES_DIR" && -n "$POOL_REAL_BIN" ]] && echo "OK globals" || echo FAIL'
        command -v jq >/dev/null && echo "OK jq" || echo FAIL
  - EXPECT: OK globals ; OK jq.
  - RUN (locate the append point — current EOF must be pool_release_lane):
        grep -nE '^pool_release_lane\(\)' lib/pool.sh
        tail -3 lib/pool.sh; echo "---"; wc -l lib/pool.sh
        # ALSO confirm the public name does NOT yet exist:
        grep -nE '^pool_reap_stale\(\)' lib/pool.sh && echo "STOP: already exists" || echo "OK: absent"
  - EXPECT: pool_release_lane defined (@2438); it is the last function (closing brace @2480).
        APPEND the new banner + the function AFTER its closing brace. pool_reap_stale ABSENT.
  - RUN (confirm the acquire reap loop is INLINED + uses the private kernel — do NOT touch it):
        grep -nE '_pool_release_lane_internals "\$n"' lib/pool.sh
  - EXPECT: a hit inside _pool_acquire_critical_section (~line 1992) — confirms acquire reaps
        with the PRIVATE kernel (NOT pool_reap_stale). This task appends a SEPARATE function.
  - RUN: bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_reap_stale() to lib/pool.sh
  - PLACEMENT: after a new banner, directly below pool_release_lane's closing brace at EOF.
  - IMPLEMENT (verbatim-ready — paste this block, then adapt commentary to codebase style):
        # =============================================================================
        # Reaper & orphan reuse (P1.M5.T3.S1)
        # =============================================================================
        # pool_reap_stale
        #
        # PRD §2.10 "Reaper" — the LAZY, on-demand stale-lease cleanup. Scans EVERY lane
        # (pool_lanes_list), asks the tri-state predicate pool_lane_is_stale whether each
        # lane's owner is dead/recycled/unverifiable, and for every STALE lane calls the PUBLIC
        # pool_release_lane (full teardown: daemon close + Chrome pgroup kill + rm dir + delete
        # lease). Echoes the reaped count to stdout for observability; returns 0. NO flock, NO
        # background daemon (PRD §2.10 — lazy; a crashed agent's Chrome+dir is reclaimed here OR
        # at the next acquire's inlined reap).
        #
        # DESIGN — the acquire-vs-reaper SPLIT (research §1): the LANDED acquire critical section
        # (_pool_acquire_critical_section @ ~line 1966) inlines its OWN reap loop that calls the
        # PRIVATE _pool_release_lane_internals directly — because the daemon close subprocess is
        # FORBIDDEN under the short acquire flock (PRD §2.19 / key_findings FINDING 2). This
        # standalone reaper runs OUTSIDE any flock and uses the PUBLIC pool_release_lane (which
        # DOES run close). The CONTRACT's "Consumed by acquire step 3a" is legacy design intent;
        # the REAL consumer is the on-demand admin reap command (M7.T2 `agent-browser-pool reap`,
        # PRD §2.10/§2.12), with exhaustion force-reap (M5.T4) as a possible future caller.
        #
        # DELEGATE (do NOT duplicate — research §2/§4): the staleness verdict comes from
        # pool_lane_is_stale (M3.T2.S3); the teardown from pool_release_lane (M5.T2.S1). Do NOT
        # re-inline pool_owner_alive / pool_chrome_kill / the rm-rf / the close.
        #
        # LOGIC (CONTRACT a→d):
        #   a. for n in $(pool_lanes_list)  — snapshot (cmd-subst captured once); empty ⇒ 0 iters.
        #   b.   if pool_lane_is_stale "$n"; then   — TRI-STATE; the if-condition is errexit-exempt:
        #          rc 0 (stale) → enter body;  rc 1 (live) / rc 2 (no lease) → fall through (skip).
        #          pid  = pool_lease_field "$n" owner.pid (best-effort || true; "null"/empty → "?")
        #                 — read BEFORE release (release deletes the lease).
        #          pool_release_lane "$n" >/dev/null — full teardown (close+kill+rm+rmlease; rc 0
        #                 always). >/dev/null so the daemon close subprocess can't pollute the count
        #                 capture (_pool_log still fires — it writes the LOG FILE, not stdout).
        #          _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
        #          reaped=$((reaped + 1)) — assignment form (safe); NEVER (( reaped++ )) (aborts @0).
        #        fi
        #   c. printf '%s\n' "$reaped"  — the ONLY stdout write (count capture for M7.T2).
        #   d. return 0  — NON-FATAL always (never pool_die, never non-zero).
        #
        # CALLER CONTRACT (the admin reap command M7.T2 / exhaustion M5.T4, under set -e):
        #     reaped="$(pool_reap_stale)"   # captures exactly one integer; rc 0 always
        #   OR (fire-and-forget):  pool_reap_stale >/dev/null 2>&1 || true
        #
        # GOTCHA — tri-state under set -e: a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or
        #   2 (no lease) ABORTS the caller. The `if …; then …; fi` is MANDATORY (the condition is
        #   errexit-exempt). (pool_lane_is_stale GOTCHA @ ~line 1145-1148.)
        # GOTCHA — `(( reaped++ ))` ABORTS when reaped==0 (command form returns rc 1 on value 0).
        #   Use `reaped=$((reaped + 1))` (assignment form, exit 0). (BashFAQ 105.)
        # GOTCHA — stdout discipline: pool_release_lane's daemon close subprocess is NOT stdout-
        #   redirected inside it; redirect pool_release_lane "$n" >/dev/null so the count capture
        #   stays clean. _pool_log writes the LOG FILE (never stdout) → keeps firing.
        # GOTCHA — read pid BEFORE release: pool_release_lane deletes the lease; extract owner.pid
        #   first (best-effort || true; "null"/empty → "?").
        # GOTCHA — `local var=$(…)` masks errexit (SC2155): split every capture (local declared
        #   FIRST, assign AFTER); guard pool_lease_field's rc-1 with || true INSIDE the $().
        # GOTCHA — NON-FATAL always: never pool_die, never non-zero. A TOCTOU missing lease ⇒
        #   pool_release_lane returns 0 (no-op); a corrupt lease ⇒ pool_lane_is_stale rc 2 (skip).
        # GOTCHA — NO flock: release is lane-local + idempotent; a concurrent acquire's in-lock reap
        #   of the same lane is a harmless no-op. Flocking the sweep would serialize vs acquire.
        # GOTCHA — snapshot iteration: the lane list is frozen before the loop; mid-loop releases
        #   cannot mutate the iteration set.
        # Reads POOL_LANES_DIR (via helpers). No new globals exported. No new env vars / files.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR via pool_lanes_list/pool_lease_field;
        #   POOL_REAL_BIN via pool_release_lane). pool_state_init NOT required (pool_lanes_list
        #   handles a missing lanes dir as a no-match glob → 0 iterations; _pool_log mkdir -p's).
        pool_reap_stale() {
            local n pid
            local reaped=0

            # (a) Iterate ALL lanes. pool_lanes_list: newline-separated, numerically-sorted lane
            #     numbers; rc 0 always; empty/missing dir ⇒ no-match glob ⇒ 0 iterations. The
            #     unquoted command substitution is the documented idiom (digits-only; word-splits
            #     on IFS into exactly the lane numbers). The list is a SNAPSHOT (captured once
            #     before the loop) — mid-loop releases cannot mutate the iteration set.
            for n in $(pool_lanes_list); do

                # (b) TRI-STATE verdict. pool_lane_is_stale: 0=stale / 1=live / 2=no-lease.
                #     The `if`-condition is errexit-exempt — rc 1 (live) and rc 2 (no lease) fall
                #     through cleanly (skip); ONLY rc 0 (stale) enters the body. A BARE call would
                #     ABORT under set -e on rc 1/2 (pool_lane_is_stale GOTCHA @ ~line 1145-1148).
                if pool_lane_is_stale "$n"; then
                    # Best-effort read of the owner pid for the log line. Read BEFORE release
                    # (pool_release_lane deletes the lease). pool_lease_field: nested-path read
                    # (owner.pid via getpath); rc 1 on missing/corrupt; echoes "null" for a missing
                    # path. The `|| true` INSIDE the $() makes the capture set -e-safe against a
                    # TOCTOU missing-lease rc 1 (pid falls back to "?"). The assignment is split
                    # (local declared above) — no SC2155 / errexit masking.
                    pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
                    [[ -n "$pid" && "$pid" != "null" ]] || pid="?"

                    # Release the stale lane: daemon close + Chrome pgroup kill + rm dir + delete
                    # lease (pool_release_lane returns 0 ALWAYS — idempotent, non-fatal). Redirect
                    # its stdout to /dev/null so the daemon close subprocess cannot pollute THIS
                    # function's reaped-count stdout capture. _pool_log (inside release + below)
                    # writes the LOG FILE (+ stderr fallback), NEVER stdout → still fires.
                    pool_release_lane "$n" >/dev/null

                    _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
                    # assignment form — safe under set -e. NEVER `(( reaped++ ))` (aborts @0).
                    reaped=$((reaped + 1))
                fi
            done

            # (c) Echo the reaped count to stdout for observability. This is the ONLY stdout write
            #     in the function (consumers capture via `count=$(pool_reap_stale)`, e.g. the admin
            #     reap command M7.T2). 0 = nothing was stale. $() strips the trailing newline so
            #     the caller gets a bare integer token.
            printf '%s\n' "$reaped"

            # (d) NON-FATAL always — never pool_die, never non-zero.
            return 0
        }
  - FOLLOW pattern: `local` declared FIRST, assignments AFTER (SC2155 + BashFAQ-105); the
        tri-state predicate under an `if` (never bare); the non-fatal capture guarded with
        `|| true` INSIDE the `$()`; `reaped=$((reaped + 1))` (assignment, never command form);
        `_pool_log` one summary line per stale lane; docstring with LOGIC + CALLER CONTRACT +
        GOTCHA sections (mirror pool_release_lane + pool_lane_is_stale).
  - NAMING: pool_reap_stale (PUBLIC, CONTRACT name, no `_`). NO private helpers.
  - PLACEMENT: the function in the new "(P1.M5.T3.S1)" banner, after pool_release_lane.

Task 2: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck -s bash lib/pool.sh                        # zero warnings (whole file)
  - RUN: shellcheck -s bash lib/pool.sh | grep -i 'pool_reap_stale' || echo "OK no SC on new fn"
  - RUN (function defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_reap_stale' >/dev/null && echo OK
        # EXPECT: OK.
  #
  # --- SCENARIO 1: MIXED POOL — 2 stale + 1 live + 1 corrupt → rc 0; count==2; correct teardown ---
  - RUN (build a mixed pool with isolated state + test-hook owner overrides):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # Lane 1 + Lane 2: STALE (dead owner pid 99998 — not alive).
                  for n in 1 2; do
                      pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99998 pi 1111 "/tmp" 0 0 "false"
                      pool_boot_lane "$n"
                  done
                  # Lane 3: LIVE — owner = $$ (the running subshell) + its REAL comm + starttime
                  # (pool_owner_alive checks comm AND starttime; $$'s comm is "bash" on a bash -c,
                  # so we must record the ACTUAL comm + the canonical starttime, NOT "pi"/1111).
                  live_comm="$(cat /proc/$$/comm)"; live_st="$(_pool_get_starttime "$$" 2>/dev/null)"
                  pool_lease_write 3 "$POOL_EPHEMERAL_ROOT/3" 0 "abpool-3" "$$" "$live_comm" "$live_st" "/tmp" 0 0 "false"
                  pool_boot_lane 3
                  live_port="$(pool_lease_field 3 port)"
                  live_cpid="$(pool_lease_field 3 chrome_pid)"
                  # Lane 4: CORRUPT lease (will be pool_lane_is_stale rc 2 → skipped).
                  printf "NOT JSON{" > "$POOL_LANES_DIR/4.json"
                  # PRE-checks:
                  curl -sf "http://127.0.0.1:$live_port/json/version" >/dev/null && echo "OK1-pre-live-chrome" || echo "FAIL1-pre-live"
                  pool_lease_exists 1 && echo "OK1-pre-1" || echo "FAIL1-pre-1"
                  pool_lease_exists 3 && echo "OK1-pre-3" || echo "FAIL1-pre-3"
                  # REAP:
                  count="$(pool_reap_stale)"; rc=$?
                  [[ $rc -eq 0 ]] && echo "OK1-rc0" || echo "FAIL1-rc=$rc"
                  [[ "$count" == "2" ]] && echo "OK1-count-2" || echo "FAIL1-count=$count"
                  # stale lanes 1+2 GONE:
                  pool_lease_exists 1 && echo "FAIL1-1" || echo "OK1-1-gone"
                  pool_lease_exists 2 && echo "FAIL1-2" || echo "OK1-2-gone"
                  # LIVE lane 3 UNTOUCHED:
                  pool_lease_exists 3 && echo "OK1-3-lease" || echo "FAIL1-3-lease"
                  curl -sf "http://127.0.0.1:$live_port/json/version" >/dev/null && echo "OK1-3-chrome-alive" || echo "FAIL1-3-chrome-dead"
                  ps -p "$live_cpid" >/dev/null 2>&1 && echo "OK1-3-pid-alive" || echo "FAIL1-3-pid-gone"
                  # CORRUPT lease 4 SKIPPED (not deleted — rc 2 verdict):
                  test -f "$POOL_LANES_DIR/4.json" && echo "OK1-4-corrupt-skipped" || echo "FAIL1-4-deleted"
                  # CLEANUP the live lane:
                  pool_release_lane 3 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK1-pre-live-chrome ; OK1-pre-1 ; OK1-pre-3 ; OK1-rc0 ; OK1-count-2 ;
        #         OK1-1-gone ; OK1-2-gone ; OK1-3-lease ; OK1-3-chrome-alive ; OK1-3-pid-alive ;
        #         OK1-4-corrupt-skipped.
  #
  # --- SCENARIO 2: EMPTY POOL → echoes 0; rc 0 ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  count="$(pool_reap_stale)"; rc=$?
                  [[ $rc -eq 0 ]] && echo "OK2-rc0" || echo "FAIL2-rc=$rc"
                  [[ "$count" == "0" ]] && echo "OK2-count-0" || echo "FAIL2-count=$count"'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK2-rc0 ; OK2-count-0.
  #
  # --- SCENARIO 3: ALL-LIVE POOL → echoes 0; rc 0; no lane touched ---
  - RUN:
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  # LIVE lane: owner = $$ + its REAL comm ("bash") + canonical starttime.
                  live_comm="$(cat /proc/$$/comm)"; live_st="$(_pool_get_starttime "$$" 2>/dev/null)"
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" "$$" "$live_comm" "$live_st" "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  port="$(pool_lease_field 1 port)"; cpid="$(pool_lease_field 1 chrome_pid)"
                  count="$(pool_reap_stale)"; rc=$?
                  [[ $rc -eq 0 ]] && echo "OK3-rc0" || echo "FAIL3-rc=$rc"
                  [[ "$count" == "0" ]] && echo "OK3-count-0" || echo "FAIL3-count=$count"
                  pool_lease_exists 1 && echo "OK3-lease" || echo "FAIL3-lease-gone"
                  curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && echo "OK3-chrome-alive" || echo "FAIL3-chrome-dead"
                  ps -p "$cpid" >/dev/null 2>&1 && echo "OK3-pid-alive" || echo "FAIL3-pid-gone"
                  pool_release_lane 1 >/dev/null 2>&1 || true'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK3-rc0 ; OK3-count-0 ; OK3-lease ; OK3-chrome-alive ; OK3-pid-alive.
  #
  # --- SCENARIO 4: RE-REAP idempotent → rc 0, echoes 0 the second time ---
  - RUN (boot 2 stale lanes, reap, reap again):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  for n in 1 2; do
                      pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99998 pi 1111 "/tmp" 0 0 "false"
                      pool_boot_lane "$n"
                  done
                  c1="$(pool_reap_stale)"; echo "OK4-first-count=$c1"
                  c2="$(pool_reap_stale)"; echo "OK4-second-count=$c2"
                  [[ "$c1" == "2" && "$c2" == "0" ]] && echo "OK4-idempotent" || echo "FAIL4 c1=$c1 c2=$c2"'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK4-first-count=2 ; OK4-second-count=0 ; OK4-idempotent.
  #
  # --- SCENARIO 5: STDOUT DISCIPLINE — count capture is EXACTLY one integer ---
  - RUN (reap with a stale lane; verify the capture is a pure integer):
        STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
        AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" \
        AGENT_CHROME_HEADLESS=1 \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
                  pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
                  pool_boot_lane 1
                  count="$(pool_reap_stale)"
                  # the capture must be EXACTLY the integer "1" (no stray close/JSON output):
                  [[ "$count" =~ ^[0-9]+$ ]] && echo "OK5-integer" || echo "FAIL5-not-integer=[$count]"
                  [[ "$count" == "1" ]] && echo "OK5-value-1" || echo "FAIL5-value=$count"'
        rm -rf "$STATE" "$EPHEM"
        # EXPECT: OK5-integer ; OK5-value-1.
```

### Implementation Patterns & Key Details

```bash
# The reap spine (research §1-§6):
#   pool_reap_stale:
#     local reaped=0
#     for n in $(pool_lanes_list); do                       # snapshot; empty ⇒ 0 iters
#         if pool_lane_is_stale "$n"; then                   # tri-state; if=errexit-exempt (rc 1/2 skip)
#             pid = pool_lease_field "$n" owner.pid || true  # BEFORE release; "null"→"?"
#             pool_release_lane "$n" >/dev/null              # full teardown; >/dev/null = clean count
#             _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
#             reaped=$((reaped + 1))                         # assignment form (NOT (( reaped++ )))
#         fi
#     done
#     printf '%s\n' "$reaped"                                # ONLY stdout write
#     return 0                                               # non-fatal always

# The tri-state guard (research §3.1):
#   if pool_lane_is_stale "$n"; then reap; fi
#   # rc 0 (stale) → body; rc 1 (live) / rc 2 (no lease) → fall through (skip). The `if`
#   # condition is errexit-exempt (bash manual -e exemption list). A BARE call ABORTS on rc 1/2.

# The arithmetic form (research §3.2):
#   reaped=$((reaped + 1))      # assignment form → exit 0 → safe
#   # NEVER: (( reaped++ ))     # command form → rc 1 when value 0 → ABORTS on first reap

# The best-effort pid capture (research §6 — split local, || true INSIDE $()):
#   local pid
#   pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
#   [[ -n "$pid" && "$pid" != "null" ]] || pid="?"

# The stdout-redirected release (research §5):
#   pool_release_lane "$n" >/dev/null
#   # pool_release_lane's daemon close subprocess is NOT stdout-redirected inside it; >/dev/null
#   # keeps `count=$(pool_reap_stale)` clean. _pool_log writes the LOG FILE (never stdout).
```

### Integration Points

```yaml
LANES (read-only enumeration via pool_lanes_list; per-lane read + delete via helpers):
  - enumerate: pool_lanes_list → $POOL_LANES_DIR/*.json (numeric stems, sort -n)
  - read: owner.pid via pool_lease_field (for the log line)
  - delete: by pool_release_lane (the lease, dir, chrome, daemon close)

DAEMON (side-effect — the close, via pool_release_lane):
  - $POOL_REAL_BIN --session <abpool-N> close   (rc 0; disconnect-only) — per stale lane

GLOBALS (no new exports — reads only):
  - POOL_LANES_DIR (pool_lanes_list + pool_lease_field; via pool_release_lane)
  - POOL_REAL_BIN (the close subprocess, via pool_release_lane)
  - POOL_EPHEMERAL_ROOT (dir removal, via pool_release_lane's kernel)

CONSUMERS (downstream — NOT this task's concern, documented for context):
  - M7.T2.S1 admin reap: reaped="$(pool_reap_stale)"; echo "Reaped $reaped lane(s)"
  - M5.T4.S1 exhaustion: pool_reap_stale (full sweep) OR force pool_release_lane "$oldest"
  - (NOT M5.T1.S1 acquire — it inlines its own reap loop with the private kernel under the flock)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after the function is appended — fix before proceeding.
bash -n lib/pool.sh                              # syntax — MUST be clean (zero output)
shellcheck -s bash lib/pool.sh                   # whole file — zero warnings (ShellCheck 0.11.0)
shellcheck -s bash lib/pool.sh | grep -i 'pool_reap_stale' || echo "OK no SC on new fn"
# Expected: zero errors/warnings. If any exist, READ the output and fix before proceeding.
```

### Level 2: Unit / Scenario Tests (Component Validation)

The project has no bats harness yet (M9.T1.S1). Validate via the **host-verified scenarios in
Task 2** (real Chrome + real agent-browser + isolated state dirs), which exercise every branch:

```bash
# Run each SCENARIO 1–5 from Task 2 in turn. Each is self-contained (mktemp state + EPHEM dirs,
# real master/chrome/agent-browser, cleanup at the end). EXPECT the documented OK* lines.

# Quick smoke (function callable, echoes 0 on an empty pool):
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
         c="$(pool_reap_stale)"; echo "smoke count=$c rc=$?"'
# Expected: smoke count=0 rc=0.
```

### Level 3: Integration Testing (System Validation)

```bash
# Concurrent-with-acquire smoke — a reap sweep does not abort / corrupt an in-flight acquire:
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
AGENT_BROWSER_POOL_OWNER_PID=77777 AGENT_BROWSER_POOL_OWNER_STARTTIME=12345 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve
          # Seed a stale lane (dead owner 99998) + boot it:
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          # Acquire (claims a fresh lane; its inlined reap also frees lane 1):
          N="$(pool_acquire_locked)"; port="$(pool_lease_field "$N" port)"
          [[ "$port" == "0" || -z "$port" || "$port" == "null" ]] && pool_boot_lane "$N"
          # Sweep AFTER acquire (lane 1 already reaped by acquire; the sweep echoes a small count):
          c="$(pool_reap_stale)"; echo "OK3-post-acquire-sweep-count=$c rc=$?"
          # CLEANUP:
          pool_release_lane "$N" >/dev/null 2>&1 || true'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-post-acquire-sweep-count=<small int> rc=0; no abort either side.

# Reaper-style full sweep (mirrors the M5.T2.S1 reaper-loop test, now via the real function):
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          # Boot 2 stale lanes:
          for n in 1 2; do
              pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99998 pi 1111 "/tmp" 0 0 "false"
              pool_boot_lane "$n"
          done
          c="$(pool_reap_stale)"
          [[ "$c" == "2" ]] && echo "OK3-swept-2" || echo "FAIL3-swept=$c"
          for n in 1 2; do pool_lease_exists "$n" && echo "FAIL lane $n" || echo "OK lane $n gone"; done'
rm -rf "$STATE" "$EPHEM"
# Expected: OK3-swept-2 ; OK lane 1 gone ; OK lane 2 gone.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Verify the count capture is robust to a stale lane whose daemon close WOULD emit stdout
# (defense: the >/dev/null redirect). Boot a stale lane, reap, assert the capture is a pure int:
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          pool_lease_write 1 "$POOL_EPHEMERAL_ROOT/1" 0 "abpool-1" 99998 pi 1111 "/tmp" 0 0 "false"
          pool_boot_lane 1
          c="$(pool_reap_stale)"
          [[ "$c" =~ ^[0-9]+$ && "$c" == "1" ]] && echo "OK4-clean-capture" || echo "FAIL4-capture=[$c]"'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-clean-capture.

# Stress — reap a pool with MANY stale lanes; count matches; no abort:
STATE="$(mktemp -d)"; EPHEM="$(mktemp -d)/active"
AGENT_BROWSER_POOL_STATE="$STATE" AGENT_CHROME_EPHEMERAL_ROOT="$EPHEM" AGENT_CHROME_HEADLESS=1 \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init
          for n in 1 2 3 4 5; do
              pool_lease_write "$n" "$POOL_EPHEMERAL_ROOT/$n" 0 "abpool-$n" 99998 pi 1111 "/tmp" 0 0 "false"
              pool_boot_lane "$n"
          done
          c="$(pool_reap_stale)"
          [[ "$c" == "5" ]] && echo "OK4-stress-5" || echo "FAIL4-stress=$c"
          for n in 1 2 3 4 5; do pool_lease_exists "$n" && echo "FAIL lane $n" || true; done
          echo "OK4-all-reaped"'
rm -rf "$STATE" "$EPHEM"
# Expected: OK4-stress-5 ; OK4-all-reaped.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `bash -n lib/pool.sh` clean; `shellcheck -s bash lib/pool.sh` zero warnings (whole file).
- [ ] Level 2: all 5 scenarios from Task 2 print their documented `OK*` lines.
- [ ] Level 3: the concurrent-with-acquire smoke + the reaper-style full sweep print their `OK3*` lines.
- [ ] Level 4: the clean-capture test prints `OK4-clean-capture`; the 5-lane stress prints
      `OK4-stress-5` + `OK4-all-reaped`.

### Feature Validation

- [ ] Mixed pool (2 stale + 1 live + 1 corrupt): rc 0; count==2; stale lanes torn down; live lane
      untouched; corrupt lease skipped (not deleted) (Scenario 1).
- [ ] Empty pool: echoes `0`; rc 0 (Scenario 2).
- [ ] All-live pool: echoes `0`; rc 0; no lane touched (Scenario 3).
- [ ] Re-reap idempotent: rc 0; second sweep echoes `0` (Scenario 4).
- [ ] Stdout discipline: `count=$(pool_reap_stale)` captures EXACTLY one integer (Scenario 5).
- [ ] DELEGATES to `pool_lane_is_stale` (verdict) + `pool_release_lane` (teardown); does NOT
      re-inline owner-alive / kill / rm / close logic.
- [ ] Reads `owner.pid` BEFORE releasing (release deletes the lease).
- [ ] Uses `reaped=$((reaped + 1))` (NEVER `(( reaped++ ))`).
- [ ] Uses `if pool_lane_is_stale "$n"; then …; fi` (NEVER a bare call).
- [ ] Redirects `pool_release_lane "$n" >/dev/null` (clean count capture).
- [ ] Non-fatal always: never `pool_die`, never non-zero.
- [ ] NO flock (lane-local + idempotent).

### Code Quality Validation

- [ ] Follows existing codebase patterns (the `for n in $(pool_lanes_list)` idiom from
      `_pool_acquire_critical_section`; the `if pool_lane_is_stale` tri-state idiom from
      `pool_lane_is_stale`'s own docstring; split-`local` captures; `_pool_log` summary lines;
      docstring with LOGIC + CALLER CONTRACT + GOTCHA sections).
- [ ] `pool_reap_stale` appended under a new `(P1.M5.T3.S1)` banner after `pool_release_lane`;
      NO edits to any existing function (esp. NOT `_pool_acquire_critical_section`'s inlined reap).
- [ ] Every `local` capture is split; the non-fatal `pool_lease_field` capture is `|| true`-guarded.
- [ ] Anti-patterns avoided (see below): no kernel/owner-alive duplication, no flock, no pool_die,
      no `(( reaped++ ))`, no bare `pool_lane_is_stale`, no missing stdout redirect on release.

### Documentation & Deployment

- [ ] Code is self-documenting (the docstring's LOGIC block IS the spec; the GOTCHA block captures
      the acquire-vs-reaper split, the tri-state hazard, the arithmetic trap, the stdout discipline,
      the no-flock decision).
- [ ] `_pool_log` summary line per stale lane is informative (lane + owner pid + dead/recycled).
- [ ] No new env vars (reads only the frozen POOL_LANES_DIR / POOL_REAL_BIN via helpers).

---

## Anti-Patterns to Avoid

- ❌ Don't DUPLICATE the staleness check or the teardown — DELEGATE to `pool_lane_is_stale`
  (verdict) + `pool_release_lane` (teardown). Re-implementing `pool_owner_alive` / `pool_chrome_kill`
  / the `rm -rf` / the `close` duplicates verified logic + risks divergence.
- ❌ Don't wire `pool_reap_stale` into acquire — acquire (`_pool_acquire_critical_section`) has its
  OWN inlined reap loop using the PRIVATE `_pool_release_lane_internals` (the daemon `close`
  subprocess is forbidden under the short flock). This function is the OUTSIDE-the-flock reaper.
- ❌ Don't call `pool_lane_is_stale` BARE — a bare call returns 1 (live) or 2 (no lease) and ABORTS
  under `set -e`. Always `if pool_lane_is_stale "$n"; then reap; fi` (the condition is
  errexit-exempt).
- ❌ Don't use `(( reaped++ ))` — the command form returns rc 1 when the value is 0 → ABORTS on the
  first reap. Use `reaped=$((reaped + 1))` (assignment form).
- ❌ Don't call `pool_die` or return non-zero — `pool_reap_stale` is NON-FATAL always (it runs from
  admin tooling / sweeps under `set -euo pipefail`; a TOCTOU-racy or corrupt lane must never abort).
- ❌ Don't add a flock — release is lane-local + idempotent; a concurrent acquire's reap of the same
  lane is a harmless no-op. Flocking the sweep would serialize it against acquire.
- ❌ Don't forget `>/dev/null` on `pool_release_lane "$n"` — pool_release_lane's daemon `close`
  subprocess is NOT stdout-redirected inside it; without `>/dev/null` the count capture
  `count=$(pool_reap_stale)` could be polluted. (`_pool_log` writes the file, not stdout — safe.)
- ❌ Don't read `owner.pid` AFTER releasing — `pool_release_lane` deletes the lease. Read it first
  (best-effort `|| true`; normalize `"null"`→`"?"`).
- ❌ Don't write `local X="$(…)"` — `local` masks errexit (BashFAQ 105 / SC2155). Split it.
- ❌ Don't create private helpers or new files — the body is ~12 lines; one function reads cleaner.
  Append to `lib/pool.sh` under the new banner; nothing else.
- ❌ Don't implement `reuse_orphan` (M5.T3.S2), the admin reap CLI (M7.T2), exhaustion force-reap
  (M5.T4), or the wrapper (M6) — out of scope. This task ships `pool_reap_stale` ONLY.
