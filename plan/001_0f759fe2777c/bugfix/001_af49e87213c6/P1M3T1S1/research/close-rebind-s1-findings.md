# Research — P1.M3.T1.S1: Mark lease connected=false on close

**Bugfix:** 001_af49e87213c6 · **Issue:** 3 (close→next-driving skips rebind)
**Task:** S1 of P1.M3.T1 — set `connected=false` in `pool_wrapper_main`'s close path before exec.
**Method:** static analysis of the LIVE `lib/pool.sh` (4510 LOC) + host-verified micro-checks
(no Chrome/daemon launched; throwaway temp state only — AGENTS.md §1/§2).

---

## 1. The close path in `pool_wrapper_main` (lines 3565–3691) — exact step map

```
a. pool_config_init / pool_state_init                      (3573)
b. POOL_DISABLE==1 → passthrough exec                       (3579)
c. pool_dispatch_classify → "meta" → passthrough exec       (3586)   [close ⇒ "driving"]
d. pool_owner_resolve → POOL_OWNER_PID==0 → passthrough     (3593)
e→g. pool_lease_find_mine / pool_acquire_locked / boot      (3602)   [N set here]
h. pool_ensure_connected "$N"  ← (S2 will read .connected)  (3630)
i. pool_normalize_close / pool_normalize_connect            (3637)   [writes POOL_NORM_ARGS]
j. pool_strip_session_args / pool_force_session             (3644)   [writes POOL_CLEAN_ARGS]
   POOL_CLOSE_ALL_SEEN observability log                    (3647-3650)
   <<<<<<<<<<<<<<<<<<<<  INSERT NEW BLOCK HERE  >>>>>>>>>>>>>>>>>>   (between 3650 and 3652)
k. _pool_clean_args_is_bare_connect short-circuit           (3668)   [close ⇒ NOT bare connect]
   exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"            (3691)   [TERMINAL — nothing after]
```

**Insertion point (host-confirmed exact bytes):** directly after the `POOL_CLOSE_ALL_SEEN`
`if`/`fi` block and before the `# --- k. EXEC the real binary` comment. POOL_CLEAN_ARGS is
fully built at step j; exec is at step k. The new block runs in between. ✓

---

## 2. `pool_lease_update` contract (lines 768–806) — the primitive S1 composes

`pool_lease_update LANE FIELD VALUE`:
- Validates `lane` (`^[0-9]+$`) and `field` (safe identifier) → `pool_die` on bad input.
- Requires the lease file to exist (`[[ -f ]]`) → `pool_die` if missing.
- `_pool_json_valid` pre-check → `pool_die` if corrupt.
- `jq --argjson v "$value" --arg f "$field" '.[$f] = $v'` → `pool_die` if VALUE isn't valid JSON.
- Returns 0 on success; **`pool_die` (exit 1, NOT return 1)** on ANY failure.

**CRITICAL — `pool_lease_update "$N" connected false || true` does NOT defend against failure.**
`pool_die` does `exit 1` (kills the PROCESS); `|| true` only catches a non-zero *return*. So a
corrupt/missing lease would ABORT the wrapper (and the agent's `close`). The item's literal
`|| true` is insufficient. **To make the defense real, run it in a subshell:**
`( pool_lease_update "$N" connected false ) 2>/dev/null || _pool_log "…non-fatal…"`.
The subshell contains `pool_die`'s `exit 1` (the subshell dies, the parent's `||` swallows it).
The lease was just read at step h so corruption is very unlikely, but the subshell makes the
"close must always exec" (PRD §2.15 transparency) guarantee hold even in that edge case.

**Host-verified round-trip (2026-07-14):**
```bash
$ AGENT_BROWSER_POOL_STATE=$tmp/state bash -c 'source lib/pool.sh; pool_config_init; pool_state_init;
    pool_lease_write 1 /x 53420 abpool-1 1 pi 100 /c 200 201 true;   # connected=true
    pool_lease_update 1 connected false;                              # S1's call
    jq -r .connected "$POOL_LANES_DIR/1.json"'
false                          # ← JSON boolean false (not the string "false", not 0). ✓
```

`pool_lease_write` signature (11 positional args, confirmed by the host run):
`pool_lease_write LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME OWNER_CWD CHROME_PID CHROME_PGID CONNECTED`

---

## 3. The `connected=false` consumer — `pool_ensure_connected` (lines 2390–~2470) [S2's job, NOT S1]

Today `pool_ensure_connected` does NOT read `.connected`. Its step b is:
```bash
if pool_daemon_connected "$session" "$port"; then
    pool_lease_update "$lane" last_seen_at "$now"   # heartbeat
    return 0                                        # EARLY-EXIT — skips rebind
fi
```
`pool_daemon_connected` (1727) returns 0 after a close (session lingers in `session list` +
Chrome alive) → so the rebind branch (step c: reconnect / relaunch) is SKIPPED. That is the bug.

**S2 (P1.M3.T1.S2) will fix the READ side:** add `.connected` to the one-jq-fork field
extraction (currently `.session, .port, .ephemeral_dir` only) and, when `.connected == false`,
skip the `pool_daemon_connected` early-exit so the reconnect/relaunch branch runs. **S1 only
WRITES `connected=false` on close; S1 does NOT touch `pool_ensure_connected`.**

**Round-trip already wired on the success path:** on a successful reconnect, step c already
calls `pool_lease_update "$lane" connected true` (line ~2430). So once S2 lands, the cycle is
`close→false` (S1) → `ensure sees false→reconnect→true` (S2). Confirmed by reading step c.

---

## 4. Why a helper predicate (not a bare inline loop) — testability + consistency

The item says "use a simple loop: iterate POOL_CLEAN_ARGS, skip flags, check first non-flag ==
'close'." The item ALSO says the test should "call the close-detection logic (or
pool_wrapper_main with a mocked exec)." The phrase **"call the close-detection logic"** implies
the detection should be **callable in isolation** → a named predicate.

The codebase already has the exact sibling pattern: **`_pool_clean_args_is_bare_connect`**
(lines 3710–3760) — a predicate that scans the cleaned argv for the `connect` command. Adding
**`_pool_clean_args_is_close`** as its twin (same flag-scan `case`, returns 0 iff the first
non-flag token is `close`) is:
- **Consistent** with the established pattern (one predicate per recognized command shape).
- **Unit-testable in isolation** — pure function of `$@`, no globals/Chrome/exec → trivially
  Chrome-free per AGENTS.md.
- The wiring in `pool_wrapper_main` becomes a clean 6-line `if` block.

**Flag-scan to mirror** (from `pool_dispatch_classify` / `_pool_clean_args_is_bare_connect`):
`--session` (skip 2), `--session=*` (skip 1), `--*` (skip 1), `-*` (skip 1), first other =
command. NOTE: by the time we scan POOL_CLEAN_ARGS, step j already stripped `--session`, so
`--session` won't appear — but mirroring the full `case` is harmless defense-in-depth (the
predicate stays correct if ever called on raw argv).

---

## 5. close vs the bare-connect short-circuit (step k) — no interference

`close` is NOT `connect`, so `_pool_clean_args_is_bare_connect` returns 1 for a close argv →
the bare-connect `exit 0` short-circuit does NOT fire for close. Therefore placing the
close-block BEFORE the bare-connect check is safe (they're mutually exclusive command shapes).
Order rationale: close-handling sits next to the other close handling (the POOL_CLOSE_ALL_SEEN
log), keeping related logic together.

---

## 6. Chrome-FREE test design (AGENTS.md-compliant)

Testing the wired behavior is hard only because `pool_wrapper_main` ends in `exec` (replaces
the process) and step h (`pool_ensure_connected`) + step e (`pool_lease_find_mine`) need a live
daemon/owner. **All bypassed with function overrides + a no-op exec in a subshell:**

```bash
# In a test body (sources test/validate.sh for setup/assert helpers):
setup                                       # temp state dir, AGENT_BROWSER_POOL_STATE
pool_config_init; pool_state_init           # idempotent; freezes POOL_LANES_DIR
pool_lease_write 1 "$ABPOOL_TEST_ROOT/active/1" 53420 abpool-1 1 pi 100 "$ABPOOL_TEST_ROOT" 0 0 true
pool_ensure_connected() { return 0; }       # override: step h needs no daemon
pool_lease_find_mine()   { printf '1\n'; return 0; }   # override: step e hands back lane 1
printf '#!/bin/sh\nexit 0\n' > "$ABPOOL_TEST_ROOT/noop.sh"; chmod +x "$ABPOOL_TEST_ROOT/noop.sh"
# CRITICAL: set AGENT_BROWSER_REAL (the ENV VAR), NOT POOL_REAL_BIN — pool_config_init
# (called inside pool_wrapper_main) RE-RESOLVES POOL_REAL_BIN from AGENT_BROWSER_REAL,
# overwriting any inline POOL_REAL_BIN=… . Setting POOL_REAL_BIN inline would silently run
# the REAL agent-browser (touching the operator's daemon — AGENTS.md violation; verified).
( AGENT_BROWSER_REAL="$ABPOOL_TEST_ROOT/noop.sh" AGENT_BROWSER_POOL_OWNER_PID=1 \
    pool_wrapper_main close --json )         # SUBSHELL: exec replaces the subshell, parent survives
assert_eq "false" "$(jq -r '.connected' "$POOL_LANES_DIR/1.json")" "connected after close"
```

Why this is sound:
- Function overrides are inherited by `( … )` subshells (bash fork semantics) → the overrides
  ARE active inside `pool_wrapper_main`.
- `AGENT_BROWSER_POOL_OWNER_PID=1` makes step d's `==0` passthrough check pass (no real pi
  process needed; `pool_owner_resolve` in test-mode just sets globals, doesn't die on PID 1).
- `pool_dispatch_classify close` → `"driving"` (real fn; no override needed).
- The subshell's `exec` of the no-op replaces only the subshell; the parent asserts afterward.
- Zero Chrome, zero daemon, zero lingering processes (no-op exec exits 0; no spawn_sim_owner).

**Unit test** (predicate, even cheaper): `assert _pool_clean_args_is_close close`;
`! assert … open`; `assert _pool_clean_args_is_close --json close`; `! assert … connect`;
empty argv → return 1.

---

## 7. Parallel-item conflict check — NONE

P1.M2.T1.S3 (Implementing in parallel) is **TEST-ONLY** on `test/concurrency.sh` (removes the
0.3s stagger). Its PRP explicitly states: *"P1.M3 (close-rebind) is disjoint (close path /
connected flag — no interaction with the boot/re-pick path)."* No file overlap, no semantic
conflict. ✓

---

## 7b. CURRENT STATE observed at research time (2026-07-14 20:40) — VERIFY before acting

While this research was in progress, `lib/pool.sh` was modified (mtime 20:40:12) by a
concurrent implementer. On inspection the **production change for S1 is ALREADY PRESENT**
and matches this spec nearly verbatim:
- `_pool_clean_args_is_close()` predicate — **defined** at lib/pool.sh:3792 (flag-scan case
  identical to §4; final `[[ "$cmd" == close ]]`).
- The close→`connected=false` wiring — **present** in `pool_wrapper_main` at lib/pool.sh
  3652-3666, including the **subshell defense** `( pool_lease_update "$N" connected false )
  2>/dev/null || _pool_log …` (exactly §2's recommendation — `|| true` was NOT used).
- The expanded step-k comments (3670-3673) — **present**.
- `bash -n` + `shellcheck -S warning` on the current file: **clean**.

**The TEST, however, is NOT present** — `grep -rn '_pool_clean_args_is_close|close_marks_lease'
test/` returns nothing. So the **primary remaining deliverable for S1 is the TEST** (Task 4 in
the PRP), plus a verification pass that the already-landed production code matches this spec.

**IMPLICATION FOR THE PRP / IMPLEMENTER:** Tasks 1-3 of the PRP are framed as
VERIFY-OR-IMPLEMENT (the implementer MUST first check the current state — do NOT blindly
re-add code that already exists, which would duplicate/contradict it). Task 4 (the test) is the
real remaining work. If a future revert removes the production code, the full spec in the PRP
restores it.

## 8. Scope guard (do NOT do in S1)

- ❌ Modify `pool_ensure_connected` to READ `.connected` → that is **S2** (P1.M3.T1.S2).
- ❌ Add the end-to-end close→rebind Chrome test → that is **S3** (P1.M3.T1.S3).
- ❌ Touch `pool_normalize_close` / `pool_normalize_connect` / `pool_daemon_connected`.
- ❌ Change the `connected` semantics or schema — only FLIP it to `false` on close.
- ❌ Re-implement flag-scanning inline if a predicate is cleaner — use `_pool_clean_args_is_close`.
