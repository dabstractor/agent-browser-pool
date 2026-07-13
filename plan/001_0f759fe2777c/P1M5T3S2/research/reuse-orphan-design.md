# Research — `pool_reuse_orphan()` design (P1.M5.T3.S2)

> The orphan-reuse entry point: scan every STALE lane, ADOPT the first whose Chrome is still
> responsive (reassign owner + re-bind daemon), echo the lane, return 0 — or return 1.
> Read-only research (host-verified code reads + 2 fresh-eyes subagents: `scout` codebase
> recon + `researcher` flock/bash-correctness brief). No files edited.

Evidence base: direct reads of `lib/pool.sh` (all dependency functions) + the
`P1M5T3S1/PRP.md` + `P1M5T3S1/research/reap-stale-design.md` (the S1 precedent) +
`architecture/key_findings.md` + the scout recon + the researcher brief below.

---

## §0 — Current file state (host-verified this session)

`lib/pool.sh` is now **2595 lines**. **`pool_reap_stale` HAS LANDED** (S1, in parallel) — it is
the LAST function (def `lib/pool.sh:2549`, closing brace `@2595` = EOF). Banner at
`lib/pool.sh:2483`:

```bash
# =============================================================================
# Reaper & orphan reuse (P1.M5.T3.S1)     ← shared M5.T3 banner (covers BOTH S1 + S2)
# =============================================================================
```

`pool_reuse_orphan` does **NOT exist** (`grep -nE '^pool_reuse_orphan\(\)' lib/pool.sh` → empty).
Forward-references to the bare token `reuse_orphan` appear only in COMMENTS (lines 812, 860,
1615, 1676, 1959, 2244) — the canonical "M5.T3.S2 reuse_orphan" future-consumer notes.

**Implication for placement**: `pool_reuse_orphan` APPENDS at EOF (line 2596), directly below
`pool_reap_stale`'s closing brace, UNDER THE SAME "Reaper & orphan reuse" banner. The banner
tag line should be bumped from `(P1.M5.T3.S1)` → `(P1.M5.T3.S1, P1.M5.T3.S2)` (a COMMENT-only
edit — no function code touched).

---

## §1 — THE defining architectural fact: acquire already INLINES reuse-orphan (the S1 precedent)

The item CONTRACT says `pool_reuse_orphan` is "Consumed by acquire step 3b (M5.T1.S1)" and
"runs inside the flock critical section of pool_acquire_locked." **This is LEGACY DESIGN
INTENT** — exactly parallel to the S1 `pool_reap_stale` story. The LANDED acquire critical
section (`_pool_acquire_critical_section`, `lib/pool.sh:1966`) does NOT call a public
`pool_reuse_orphan`. It INLINES the identical scan→probe→adopt flow (`lib/pool.sh:1977-1996`):

```bash
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then
        port="$(pool_lease_field "$n" port 2>/dev/null)" || port=""
        session="$(pool_lease_field "$n" session 2>/dev/null)" || session=""
        if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
           && pool_daemon_connected "$session" "$port"; then
            if _pool_adopt_lane "$n"; then
                printf '%s\n' "$n"
                return 0
            fi
        fi
        _pool_release_lane_internals "$n"      # reap the non-adoptable stale lane
    fi
done
```

The acquire version is INTERLEAVED (reap + reuse per lane, in one pass) and, on a FAILED adopt,
REAPS the lane then continues — because its goal is to CLAIM a lane (adopt-or-claim-a-new-one).
The PUBLIC `pool_reuse_orphan` is REUSE-ONLY (adopt the first responsive orphan; on a failed
adopt, fall through to the NEXT candidate; if none, return 1 — NO reap, NO choose-N).

**The designed two-path split** (mirrors S1 exactly):

| path | context | adopts via | reaps? | choose-N? |
|---|---|---|---|---|
| acquire step 3b | INSIDE flock (`pool_acquire_locked`) | `_pool_adopt_lane` (inline) | YES (interleaved, via kernel) | YES (on exhaustion) |
| **`pool_reuse_orphan`** (this task) | caller-held flock (building block) | `_pool_adopt_lane` (delegated) | **NO** (reuse-only) | **NO** |

**Implication**: `pool_reuse_orphan` must NOT be wired into acquire (acquire's inline is shipped
+ correct). It is the PUBLIC, reusable building-block form of reuse-orphan — the documented
entry point for FUTURE callers (an acquire refactor that extracts the inline; an exhaustion
retry; admin/doctor reconcile). Exactly as `pool_reap_stale` exists alongside acquire's inlined
reap. (S1 `research/reap-stale-design.md` §1 sets this precedent; S2 follows it.)

---

## §2 — The dependency contracts (all LANDED + host-verified; scout recon confirms)

### 2.1 `_pool_adopt_lane LANE` — PRIVATE adoption kernel (`lib/pool.sh:1892`)
Returns **0** = adopted (lease republished + daemon rebound); **1** = fail. Body:
1. validate lane (`^[0-9]+$` else rc 1);
2. `pool_lease_read "$lane"` → json (rc 1 missing/corrupt ⇒ rc 1);
3. extract `.port` + `.session`;
4. **PRECONDITION**: `POOL_OWNER_PID` numeric (else rc 1); also reads `POOL_OWNER_COMM`,
   `POOL_OWNER_STARTTIME`, `POOL_OWNER_CWD`, `POOL_LANES_DIR`, `POOL_REAL_BIN`;
5. **jq mutate** (inject-safe, all `--arg`/`--argjson` DATA): `.owner = {pid,comm,starttime,cwd}`
   (reassign to CURRENT claimer) `| .connected = true | .last_seen_at = $now`;
6. `_pool_atomic_write` the mutated lease (tmp+mv, same FS);
7. `pool_daemon_connect "$session" "$port"` (re-bind; rc 1 ⇒ Chrome died mid-adopt ⇒ rc 1);
8. `_pool_log "pool_acquire(adopt): reused orphan lane …"`; `return 0`.

**NON-FATAL** (never `pool_die`). It does NOT check staleness OR responsiveness — the CALLER
gates that (`pool_reuse_orphan` does so via `pool_lane_is_stale` + `pool_daemon_connected`).
**This IS the CONTRACT step 3b(d)** (reassign owner / connected=true / last_seen_at / ensure
connected) — already implemented. **DELEGATE to it; do NOT re-inline the jq owner-mutation.**
(S1 `research/reap-stale-design.md` §2 + the researcher brief Q2: re-inlining duplicates a
subtle, set-e-sensitive write + risks divergence.)

### 2.2 `pool_daemon_connected SESSION PORT` — READ-ONLY responsiveness gate (`lib/pool.sh:1689`)
Returns **0** = session known to daemon AND pooled Chrome answers CDP; **1** otherwise. TWO
read-only probes (NEVER launches — the `get cdp-url` auto-launch trap is avoided):
1. `"$POOL_REAL_BIN" --session "$s" --json session list | jq -e '.data.sessions|index($s)'`;
2. `curl -sf "http://127.0.0.1:$port/json/version"`.
Its docstring (`lib/pool.sh:1676`) **explicitly lists "M5.T3.S2 reuse_orphan (is the orphan's
chrome responsive?)"** as a consumer. **This IS the CONTRACT step 3b(c)** responsiveness check
(raw `curl /json/version` alone is INSUFFICIENT — adoption needs the daemon to know the session
so the re-bind is meaningful; researcher brief Q2(1) + Chrome DevTools Protocol docs).

### 2.3 `pool_lanes_list` — iterator (`lib/pool.sh:967`)
Newline-separated, numerically-sorted lane numbers; rc 0 ALWAYS; empty/missing dir ⇒ 0
iterations. Idiom: `for n in $(pool_lanes_list)`. (Identical to S1's usage.)

### 2.4 `pool_lane_is_stale LANE` — TRI-STATE verdict (`lib/pool.sh:1164`)
**0**=stale / **1**=live / **2**=no-lease. Read-only. **SET -e HAZARD** (`lib/pool.sh:1145-1148`):
a BARE call ABORTS on rc 1/2. MANDATORY idiom: `if pool_lane_is_stale "$n"; then …; fi` (the
`if` condition is errexit-exempt; rc 1/2 fall through). (Identical to S1.)

### 2.5 `pool_lease_field LANE FIELD` — nested read (`lib/pool.sh:876`)
`jq -r --arg f "$field" 'getpath($f|split("."))' "$file"`. Top-level `port` / `session` reads
work (no dot needed). rc 1 on missing/corrupt/non-numeric lane; echoes `"null"` for a missing
path (rc 0). Used to read the orphan's `port` + `session` for the responsiveness gate.

### 2.6 `_pool_log MSG...` — file logger (`lib/pool.sh:39`)
Writes the LOG FILE (+ stderr fallback), NEVER stdout ⇒ safe inside the lane-echo capture.
(Identical to S1.) NOTE: `_pool_adopt_lane` logs the adoption summary itself, so
`pool_reuse_orphan` does NOT need an additional log line (avoids double-logging).

---

## §3 — THE KEY DIVERGENCE FROM S1: adoption is NOT collision-safe ⇒ the flock story

S1's `pool_reap_stale` takes **NO flock** because reaping is **idempotent** (release twice =
no-op; a concurrent acquire reap of the same lane is harmless). **Adoption is DIFFERENT**: if
two concurrent adopters both scan the same orphan (read lease → both find it responsive → both
rewrite `.owner` → both `pool_daemon_connect` → both echo lane N), BOTH callers believe they
own lane N = a **COLLISION**. Adoption therefore REQUIRES serialization.

The LANDED acquire serializes its inlined reuse-orphan via the exclusive flock on
`$POOL_LOCK_FILE` (`pool_acquire_locked`, `( flock 9; _pool_acquire_critical_section )
9>"$POOL_LOCK_FILE"`; `POOL_LOCK_FILE = $POOL_STATE_DIR/acquire.lock`, `lib/pool.sh:183`).

### 3.1 The flock DECISION: Design B — take NO own flock; caller must hold the lock (researcher Q1)

Two candidate designs:
- **Design A** — `pool_reuse_orphan` takes its OWN `( flock 9; … ) 9>"$POOL_LOCK_FILE"`.
- **Design B** — `pool_reuse_orphan` takes NO flock; PRECONDITION: caller already holds
  `$POOL_LOCK_FILE` (mirrors the codebase convention: ONLY `pool_acquire_locked` flocks; ALL
  building-block functions — `_pool_acquire_critical_section`, `_pool_adopt_lane`,
  `_pool_release_lane_internals`, `pool_release_lane`, `pool_reap_stale` — take NO flock).

**Design A is REJECTED — it SELF-DEADLOCKS.** flock(2) locks are associated with an **open file
description (OFD)**, NOT a process (Linux `flock(2)` man page,
https://man7.org/linux/man-pages/man2/flock.2.html):

> "If a process uses open(2) (or similar) to obtain more than one file descriptor for the same
> file, these file descriptors are treated independently by flock(). An attempt to lock the file
> using one of these file descriptors may be denied by a lock that the calling process has
> already placed via another file descriptor."

A fresh `9>"$POOL_LOCK_FILE"` redirect opens a NEW OFD (an `open(2)`). So if `pool_reuse_orphan`
(Design A) is ever called from WITHIN an existing holder of the lock (its PRIMARY intended
context — the acquire flock), the inner blocking `flock 9` is **denied by the caller's own lock
via a different OFD → BLOCKS FOREVER** (self-deadlock). Shell redirections are `open(2)`/`openat(2)`;
the man page's "(or similar)" clause covers them directly.

**Design B is CHOSEN.** It:
- **Avoids the self-deadlock** (no inner flock → no OFD-denial).
- **Matches the codebase convention** (only the top-level entry point flocks; building blocks
  are lock-free + composable).
- **Mirrors S1's `pool_reap_stale`** (public function, no own flock).
- **Is correct**: the top-level `pool_acquire_locked` is the single serialization gate; any
  caller of `pool_reuse_orphan` either calls it from within that gate (the intended context,
  per CONTRACT note (f)) or accepts that concurrent reuse-orphan calls can collide (a
  best-effort single-threaded retry/admin context — acceptable).

**The docstring MUST state the precondition + the deadlock warning prominently** (researcher
Q1(3) gives the exact language). This is THE critical gotcha that distinguishes S2 from S1.

---

## §4 — bash correctness under `set -euo pipefail` (researcher brief, canonical sources)

### 4.1 The tri-state `if` + the `&&` responsiveness gate are errexit-exempt
```bash
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then          # rc 0⇒stale; rc 1/2⇒fall through (NO abort)
        port=…; session=…
        if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected "$session" "$port"; then
            if _pool_adopt_lane "$n"; then …; fi   # rc 1⇒fall through (try next orphan)
        fi
    fi
done
```
Bash manual (*The Set Builtin*, `-e`): the failing command is NOT fatal if it is "part of the
test following the `if`/`elif` reserved words" OR "any command in a `&&`/`||` list except the
command following the final `&&`/`||`." So `pool_lane_is_stale` rc 1/2, `pool_daemon_connected`
rc 1, and `_pool_adopt_lane` rc 1 ALL fall through cleanly. (https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)

### 4.2 `local var=$(cmd)` masks errexit (SC2155); split + `|| true` INSIDE the `$()`
```bash
local port session
port="$(pool_lease_field "$n" port 2>/dev/null || true)"
```
`local` returns 0 always → `local X="$(…)"` swallows the command's rc (SC2155). Fix: declare
FIRST, assign AFTER. The `|| true` INSIDE the `$()` makes the capture set-e-safe against
`pool_lease_field`'s rc 1 (TOCTOU missing lease). (BashFAQ 105 — https://mywiki.wooledge.org/BashFAQ/105 ;
ShellCheck SC2155 — https://www.shellcheck.net/wiki/SC2155)

### 4.3 Word-split idiom + snapshot iteration
`for n in $(pool_lanes_list)` — digit-only, newline-separated output word-splits on IFS into
exactly the lane numbers (no glob hazard; `$()` strips trailing newlines). **Snapshot**: the
command substitution is fully evaluated ONCE before the loop → the lane list is FROZEN; an
adoption mid-loop (which rewrites a lease, not deletes it) cannot mutate the iteration set.
(Wooledge WordSplitting — https://mywiki.wooledge.org/WordSplitting.) Host-verified:
ShellCheck 0.11.0 does NOT flag this idiom (the file already contains it at `lib/pool.sh:1977`).

### 4.4 The `return 1` "nothing found" signal composes with `if n="$(pool_reuse_orphan)"; then`
`pool_reuse_orphan` returns **1 with NO stdout** = "no orphan"; **0 + echoes lane N** = "found".
The caller's `if n="$(pool_reuse_orphan)"; then …; else …; fi`: the assignment's exit status =
the command-substitution's status (Bash manual *Simple Commands*); in the `if` test position it
is errexit-exempt → rc 1 routes to `else`, no abort. (researcher brief BASH (e).)

### 4.5 NO arithmetic-counter trap here (contrast S1)
Unlike `pool_reap_stale` (which counts reaps → `reaped=$((reaped+1))` vs the `(( reaped++ ))`
trap), `pool_reuse_orphan` does NOT count — it returns on the FIRST adoption. No counter → no
arithmetic-form hazard.

---

## §5 — stdout discipline: the lane-echo capture MUST be clean

`pool_reuse_orphan` echoes the adopted lane N to stdout (`printf '%s\n' "$n"`) so the caller
captures it via `n="$(pool_reuse_orphan)"`. Command substitution captures ALL stdout. Therefore:
- **ONLY `printf '%s\n' "$n"` may write to the function's stdout.**
- `_pool_log` writes the LOG FILE (never stdout) → safe. (`_pool_adopt_lane` logs the adoption
  itself; `pool_reuse_orphan` does NOT add a second log line → no double-logging.)
- `pool_lease_field` reads are captured in `$()` → their stdout does not flow to the function's
  stdout.
- `pool_daemon_connected` redirects BOTH probes to `>/dev/null` → no stdout leak.
- `_pool_adopt_lane`'s internal `pool_daemon_connect` is `>/dev/null 2>&1`; its `jq`/writes are
  captured/internal; `_pool_log` is file-only → NO stdout leak. (Confirmed by reading the body.)
So the lane-echo is the sole stdout write. (Defensive: the `if _pool_adopt_lane "$n"; then`
guard means a FAILED adopt's diagnostics — there are none to stdout anyway — never fire on
success. No extra `>/dev/null` redirect needed on `_pool_adopt_lane`; its contract is stdout-clean.)

---

## §6 — the CONTRACT step 3b(d) "ensure connected" nuance (delegation reconciles it)

The CONTRACT inline step 3b(d) says: "Ensure daemon connected: `pool_daemon_connected(session)`.
If not, `pool_daemon_connect(session, port)`." The delegation design satisfies this:
1. **Gate** (`pool_daemon_connected "$session" "$port"`) — MUST be responsive to even attempt
   adoption (Chrome alive AND daemon knows the session). This is the "ensure connected" CHECK.
2. **Adopt** (`_pool_adopt_lane "$n"`) — does the owner-reassign + `connected=true` +
   `last_seen_at=now` + `pool_daemon_connect` (the re-bind). This is the "if not, connect" ACT.
If the Chrome dies between the gate and the adopt, `_pool_adopt_lane`'s `pool_daemon_connect`
returns 1 → adopt returns 1 → `pool_reuse_orphan` falls through to the NEXT candidate (try the
next orphan). If none → `return 1`. **Correct + DRY** (the CONTRACT's inline adoption is already
`_pool_adopt_lane`; do not re-implement).

---

## §7 — naming, placement, scope

- **Name**: `pool_reuse_orphan` (PUBLIC — no `_` prefix; matches `pool_reap_stale` /
  `pool_release_lane` / `pool_acquire_locked` public convention + the `pool_*` family in
  `architecture/key_findings.md` naming recommendation). CONTRACT-mandated name.
- **Placement**: APPEND at EOF (`lib/pool.sh:2596`), directly below `pool_reap_stale`'s closing
  brace, UNDER THE EXISTING "Reaper & orphan reuse" banner (`lib/pool.sh:2483`). **Pure
  addition** — no edits to any existing FUNCTION. The banner tag line is bumped
  `(P1.M5.T3.S1)` → `(P1.M5.T3.S1, P1.M5.T3.S2)` (a COMMENT-only edit — no function code touched).
- **Scope**: `pool_reuse_orphan` ONLY. Do NOT touch acquire's inlined reuse-orphan loop (S1
  invariant). Do NOT implement the exhaustion handler (M5.T4), admin CLI (M7), or the wrapper
  (M6). Do NOT add a flock (Design B). Do NOT add new env vars / globals / files. One function,
  ~30 lines incl. the docstring.
- **PRECONDITIONS**: `pool_config_init` + `pool_owner_resolve` (for `POOL_OWNER_*` via
  `_pool_adopt_lane`; `POOL_REAL_BIN`/`POOL_LANES_DIR` via the helpers) + **the caller MUST hold
  `$POOL_LOCK_FILE`** (Design B; adoption is not collision-safe otherwise — §3).

---

## §8 — decisions table

| decision | choice | rationale |
|---|---|---|
| adopt via | `_pool_adopt_lane` (PRIVATE, delegated) | it ALREADY implements owner-reassign + connected=true + last_seen_at + daemon re-bind (CONTRACT 3b(d)). DRY; do NOT re-inline the jq mutation. |
| responsiveness gate | `pool_daemon_connected "$session" "$port"` | LANDED read-only 2-probe check (CONTRACT 3b(c)). Raw `curl` alone is INSUFFICIENT (adoption needs the daemon to know the session). Its docstring lists this task as a consumer. |
| staleness verdict | `pool_lane_is_stale` (tri-state, under `if`) | CONTRACT 3b(a/b); DRY; the `if` is errexit-exempt. |
| iterate | `for n in $(pool_lanes_list)` | documented idiom; snapshot; known-safe digit output. |
| port/session read | `pool_lease_field "$n" port/session` (split local, `|| true` inside `$()`) | nested-safe; TOCTOU-safe; rc 1 ⇒ skip (no port ⇒ not an orphan). |
| flock? | **NO** (Design B; caller MUST hold `$POOL_LOCK_FILE`) | adoption is NOT collision-safe, BUT taking its own flock SELF-DEADLOCKS if called within an existing holder (flock(2) per-OFD). Matches the convention (only pool_acquire_locked flocks) + S1. |
| set -e guards | `if pool_lane_is_stale`; `&& pool_daemon_connected`; `if _pool_adopt_lane` | all errexit-exempt (if-test / &&-list); rc 1/2 fall through. |
| on adopt failure | fall through to the NEXT stale lane | the orphan's Chrome died mid-race; try the next candidate. If none → return 1. |
| on POOL_OWNER_PID==0 | `return 1` (no adopt) | a passthrough owner must NOT adopt (defense-in-depth; mirrors acquire). |
| stdout | ONLY `printf '%s\n' "$n"` (on success) | lane capture `n="$(pool_reuse_orphan)"`. Helpers are stdout-clean (§5). |
| logging | delegated to `_pool_adopt_lane` (it logs the adoption) | no double-logging; `_pool_log` is file-only. |
| return | `0` + echo lane N (adopted) / `1` nothing echoed (none) | CONTRACT step 3b(d)/(e). Non-fatal (never `pool_die`). |
| placement | append at EOF (line 2596) under the shared M5.T3 banner; bump banner tag to S1+S2 | current EOF = pool_reap_stale; pure addition. |

---

## §9 — test infrastructure (NOT built — validation is manual)

No `.bats` files exist (`find . -name '*.bats'` → empty); `test/` holds only `.gitkeep`. The bats
harness is M9.T1.S1 (future). So validation = `bash -n` + `shellcheck` (whole file) + host-run
manual scenarios (real Chrome + real agent-browser + isolated state dirs + test-hook owner
overrides `AGENT_BROWSER_POOL_OWNER_PID`/`_STARTTIME`), mirroring S1's Task 2 scenarios.
