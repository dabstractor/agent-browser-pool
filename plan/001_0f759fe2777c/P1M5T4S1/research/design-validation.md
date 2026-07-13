# Design Validation — `pool_wait_for_lane()` (P1.M5.T4.S1)

Scope: validate the design of a NEW public function `pool_wait_for_lane()` to be
appended to `lib/pool.sh` (PRD §2.9 block-with-timeout + force-reap + alert). This is
a DESIGN-ONLY artifact (review-only): no source files were modified. Every claim cites
`lib/pool.sh` line numbers (file is 2774 lines as of this research — the parallel
S2 `pool_reuse_orphan` has landed at line 2703).

## Verdict

All 10 design assumptions in the task are CONFIRMED, with three refinements (Q4
rc-hazard list, Q6 loop structure, Q7 redirect set). Recommended ~45-line sketch and
a gotchas list are at the end.

---

## Files Retrieved (the composition surface)

1. `lib/pool.sh:1-80` — file header, `set -euo pipefail` (line 16), `_pool_log` (39) —
   confirms strict mode propagates and `_pool_log` writes the LOG FILE (+stderr fallback),
   never stdout.
2. `lib/pool.sh:126-209` — `pool_config_init`: freezes `POOL_STATE_DIR` (140),
   `POOL_LANES_DIR` (197), `POOL_LOCK_FILE` (199), `POOL_WAIT` (168). These are the only
   globals `pool_wait_for_lane` needs.
3. `lib/pool.sh:344-358` — `_pool_now` (352) = `date '+%s'` → epoch integer, exit 0.
4. `lib/pool.sh:682-762` — `pool_lease_write`: `now="$(_pool_now)"` (704),
   `--argjson acquired_at "$now"` (721) → `acquired_at` is a NUMERIC epoch integer (not ISO).
5. `lib/pool.sh:876-905` — `pool_lease_field` (876): rc 1 on missing/corrupt lane;
   echoes "null" for a missing JSON path; always rc 0 for a present field.
6. `lib/pool.sh:967-981` — `pool_lanes_list` (967): echoes newline-separated,
   numerically-sorted lane N; rc 0 always; empty/missing dir ⇒ 0 iterations.
7. `lib/pool.sh:1164-1199` — `pool_lane_is_stale` (1164): TRI-STATE 0=stale / 1=live /
   2=no-lease. Bare call ABORTS under set -e on rc 1/2.
8. `lib/pool.sh:1813-1870` — `_pool_release_lane_internals` (1813): PRIVATE, NO daemon
   close, kill+rm+rm-lease, rc 0 always. Used UNDER the acquire flock.
9. `lib/pool.sh:1966-2041` — `_pool_acquire_critical_section` (1966): inlines reap (via
   `_pool_release_lane_internals`) + reuse-orphan + choose-N + claim, all UNDER flock.
10. `lib/pool.sh:2043-2068` — `pool_acquire_locked` (2043): owns its flock via
    `( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`. Lock is short
    (scan+reap+claim only).
11. `lib/pool.sh:2438-2482` — `pool_release_lane` (2438): PUBLIC; daemon close subprocess
    `"$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true` (~2472) redirects
    ONLY stderr — stdout can leak; rc 0 always; idempotent.
12. `lib/pool.sh:2549-2607` — `pool_reap_stale` (2549): NO flock; rc 0 always; echoes the
    reaped COUNT to stdout; redirects each `pool_release_lane "$n" >/dev/null`.
13. `lib/pool.sh:2703-2774` — `pool_reuse_orphan` (the parallel S2 deliverable; EOF).

## The rc-hazardous helpers + correct guards

| Helper | rc on the "no work" path | Hazard under `set -e` | Correct guard |
|---|---|---|---|
| `pool_lane_is_stale "$n"` (1164) | 1 (live) / 2 (no lease) | bare call ABORTS on 1/2 | `if pool_lane_is_stale "$n"; then …; fi` |
| `pool_acquire_locked` (2043) | 1 (exhaustion) | bare `N=$(…)` ABORTS on 1 | `local N; if N="$(pool_acquire_locked)"; then …; fi` (split-local) |
| `pool_lease_field "$n" FIELD` (876) | 1 (missing/corrupt) | bare capture ABORTS on 1 | `ts="$(pool_lease_field "$n" acquired_at 2>/dev/null \|\| true)"` then validate `=~ ^[0-9]+$` |
| `pool_release_lane "$n"` (2438) | 0 always | none (rc-safe) | STILL redirect `>/dev/null` (close subprocess leaks stdout) |
| `pool_reap_stale` (2549) | 0 always | none | redirect `>/dev/null` (echoes count) |
| `pool_lanes_list` (967) | 0 always | none | `for n in $(pool_lanes_list)` (rc-safe) |

Plus the arithmetic hazard: `(( expr ))` as a STATEMENT returns rc 1 when the result
is 0 → ABORTS under set -e. Use it only inside `if`/`while`/`&&`/`||` conditions
(errexit-exempt there), or the `$(( ))` EXPANSION form (always safe).

## Architecture (locking topology — CONFIRMED)

`pool_wait_for_lane` is the M6-wrapper exhaustion path. The wrapper first calls
`pool_acquire_locked` directly (the fast path). On rc 1 it calls `pool_wait_for_lane`:

1. **Poll loop** (≤ `POOL_WAIT` s, 2 s cadence): `pool_reap_stale >/dev/null` (full
   daemon-close reap, UNFLOCKED) then `pool_acquire_locked` (which takes its OWN short
   flock and inlines its own reap+claim). On acquire rc 0 → echo N, return 0.
2. **Force-reap** on timeout: scan for the OLDEST lane whose owner is dead
   (`pool_lane_is_stale` rc 0, oldest by numeric `acquired_at`), release it via the
   PUBLIC `pool_release_lane`, ALERT, then try `pool_acquire_locked` once more.
3. **Fail** (rc 1, nothing echoed) if still no lane.

ONLY `pool_acquire_locked` flocks. `pool_reap_stale` (2549) and `pool_release_lane`
(2438) are explicitly lock-free and idempotent, so `pool_wait_for_lane` must NOT take
any flock — it composes flock-owning and flock-free helpers. Holding a lock across the
2 s `sleep` would serialize the entire pool for up to 10 min.

## Answers to the 10 design questions

### Q1 — Does `pool_acquire_locked` take its OWN flock? CONFIRMED.
`( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"` (2043-2068). The lock
covers ONLY scan+reap+reuse+choose+claim. `pool_reap_stale` (2549) is UNFLOCKED.
⇒ `pool_wait_for_lane` must NOT hold any lock during the poll loop or the force-reap.
(Also note `pool_reuse_orphan`'s self-deadlock WARNING: never add a fresh
`9>"$POOL_LOCK_FILE"` inside a helper — flock(2) is per-open-file-description.)

### Q2 — Oldest stale lane by `acquired_at`. CONFIRMED numeric epoch; safe.
`acquired_at` is a numeric epoch integer (`pool_lease_write` 704/721; `_pool_now`=352).
Select-oldest = iterate `pool_lanes_list`, keep lanes where `pool_lane_is_stale` rc 0,
read `acquired_at` via `pool_lease_field` (guarded `|| true`, validate `=~ ^[0-9]+$`;
a corrupt/missing value MUST be skipped via `continue` — never defaulted to 0, which
would always win "oldest"), and numerically compare with `(( ))` INSIDE an `if`/`||`
condition. There is NO ISO-format field to worry about.

### Q3 — Force-reap release: PUBLIC `pool_release_lane`. CONFIRMED.
`pool_wait_for_lane` runs OUTSIDE any flock (Q1). The PUBLIC `pool_release_lane` (2438)
is the consistent choice: full teardown (daemon close + Chrome pgroup kill + `rm -rf`
ephemeral dir + `rm -f` lease), runs UNFLOCKED, idempotent (rc 0 always), and is exactly
what the standalone `pool_reap_stale` (2549) composes. The PRIVATE
`_pool_release_lane_internals` (1813) is reserved for the IN-LOCK acquire reap (it
skips the daemon close — a subprocess forbidden under the short acquire flock, PRD §2.19).
Using `_pool_release_lane_internals` here would skip the daemon close — wrong. Use
`pool_release_lane "$oldest" >/dev/null`.

### Q4 — `set -e` rc-hazard list. CONFIRMED + enumerated (see table above).

### Q5 — Timing: use `_pool_now` epoch, NOT `$SECONDS`. RECOMMENDED.
Capture `start="$(_pool_now)"` once; compute `elapsed = $(_pool_now) - start` each check.
Reasons: (a) `$SECONDS` has the quirk "If unset, it loses its special properties" —
dangerous for a *sourced* library in an arbitrary caller shell; (b) `_pool_now` returns
the true epoch regardless of subshell nesting, and is the SAME clock `acquired_at`
uses, so elapsed-time and lease-time are consistent; (c) the fork cost (`date +%s`) is
trivial at a 2 s cadence. (The forkless builtin alternative `printf '%(%s)T' -1` is also
valid and is house style for *display* timestamps — used in `_pool_log` / `_pool_alert` —
but for elapsed arithmetic the named `_pool_now` primitive is preferred for DRY/consistency;
see bash-patterns.md §1.)

### Q6 — `POOL_WAIT=0` edge case. CONFIRMED: check-timeout-BEFORE-body ⇒ zero iterations.
```bash
start="$(_pool_now)"
while true; do
    now="$(_pool_now)"
    (( now - start >= POOL_WAIT )) && break   # CHECK FIRST (errexit-exempt in && cond)
    pool_reap_stale >/dev/null
    if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
    sleep 2
done
# → force-reap
```
With `POOL_WAIT=0`: first iteration `0 - 0 >= 0` is true → `break` immediately → straight
to force-reap. Correct: the wrapper only calls `pool_wait_for_lane` AFTER one
`pool_acquire_locked` already returned 1.

### Q7 — stdout discipline. CONFIRMED + full redirect set.
For `N=$(pool_wait_for_lane)` to capture EXACTLY one integer, every other writer must be
silenced:
- `pool_acquire_locked` — echoes ONLY N (rc 0) / nothing (rc 1). CLEAN (the one value captured).
- `pool_reap_stale` — echoes the reaped COUNT. MUST `>/dev/null`.
- `pool_release_lane` — its daemon-close subprocess (~2472) redirects ONLY stderr; stdout
  can leak. MUST `>/dev/null`.
- `notify-send` — writes to D-Bus (not stdout) but may print diagnostics to stderr.
  `_pool_alert` must `>/dev/null 2>&1` + `command -v` guard.
- `_pool_log` (39) — writes the LOG FILE (+ stderr fallback), NEVER stdout. CLEAN.
So the mandatory redirects are: `pool_reap_stale >/dev/null`, `pool_release_lane >/dev/null`,
`_pool_alert … >/dev/null 2>&1`. The ONLY `printf '%s\n' "$N"` that reaches the top is the
success echo.

### Q8 — `_pool_alert SUMMARY BODY`. CONFIRMED; recommended shape.
- best-effort `notify-send "$1" "$2"` guarded by `command -v notify-send >/dev/null 2>&1`,
  whole thing `>/dev/null 2>&1 || true` (non-graphical session / missing binary non-fatal).
- append ONE timestamped line to `$POOL_STATE_DIR/alerts.log`; `mkdir -p -- "$POOL_STATE_DIR"
  2>/dev/null || true` defensively first.
- timestamp via `printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1` (the `_pool_log` idiom at 41-42)
  — NO `date` fork, consistent with the file.
- alerts.log path: DERIVE INLINE from `$POOL_STATE_DIR/alerts.log` (frozen at line 140). Do
  NOT introduce a new global (consistent with `_pool_log` deriving its path inline).

### Q9 — Naming/placement. CONFIRMED.
PUBLIC name `pool_wait_for_lane` (no leading `_`). Append a NEW banner section
`# Pool exhaustion (P1.M5.T4.S1)` at EOF (after `pool_reuse_orphan`'s closing brace,
~line 2774). Place the PRIVATE `_pool_alert` helper in the SAME new section, immediately
ABOVE `pool_wait_for_lane` (helpers-first convention, matching how
`_pool_release_lane_internals` precedes `pool_release_lane`, and
`_pool_acquire_critical_section` precedes `pool_acquire_locked`).

### Q10 — TOCTOU / double-acquire. CONFIRMED acceptable.
Between the force-reap `pool_release_lane` and the final `pool_acquire_locked`, another
concurrent agent's acquire can grab the just-freed lane first (the release deletes the
lease + dir, making N "free"; a peer's `pool_find_free_lane` + claim under ITS flock wins
the race). Then the final `pool_acquire_locked` returns 1 again → `pool_wait_for_lane`
returns 1 (contract d). This is the ACCEPTABLE total-failure path — no deadlock, no
double-acquire (claims are serialized by the single flock in `pool_acquire_locked`).
Because `pool_acquire_locked` INLINES its own reap+reuse+claim under flock, the final
attempt is fully atomic — no window where `pool_wait_for_lane` could "pre-claim" N outside
the lock and then double-claim inside it. Observable outcome = win-or-lose-the-race → rc 0
(echo N) / rc 1 (nothing).

## Recommended implementation sketch (~45 lines)

Appended at EOF after a new `# Pool exhaustion (P1.M5.T4.S1)` banner. `_pool_alert` goes
first (helpers-first), then `pool_wait_for_lane`. This is a SKETCH for the implementer,
not a committed edit.

```bash
# _pool_alert SUMMARY BODY  (private, best-effort)
_pool_alert() {
    local summary="${1:-}" body="${2:-}" ts alerts_dir
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$summary" "$body" >/dev/null 2>&1 || true
    fi
    alerts_dir="${POOL_STATE_DIR:-}"
    [[ -n "$alerts_dir" ]] || return 0
    mkdir -p -- "$alerts_dir" 2>/dev/null || true
    printf '%s %s: %s\n' "$ts" "$summary" "$body" >>"$alerts_dir/alerts.log" 2>/dev/null || true
}

# pool_wait_for_lane  (public; called by the wrapper M6 when pool_acquire_locked rc==1)
pool_wait_for_lane() {
    local N now start oldest_lane oldest_ts ts cand_lane
    start="$(_pool_now)"
    # (a) poll loop — check-timeout-BEFORE-body so POOL_WAIT=0 → zero iterations
    while true; do
        now="$(_pool_now)"
        (( now - start >= POOL_WAIT )) && break
        pool_reap_stale >/dev/null
        if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
        sleep 2
    done
    # (b) force-reap: oldest lane whose owner is actually dead
    oldest_lane=""; oldest_ts=""
    for cand_lane in $(pool_lanes_list); do
        if pool_lane_is_stale "$cand_lane"; then
            ts="$(pool_lease_field "$cand_lane" acquired_at 2>/dev/null || true)"
            [[ "$ts" =~ ^[0-9]+$ ]] || continue      # corrupt → skip (never "oldest")
            if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then
                oldest_ts="$ts"; oldest_lane="$cand_lane"
            fi
        fi
    done
    if [[ -n "$oldest_lane" ]]; then
        pool_release_lane "$oldest_lane" >/dev/null
        _pool_alert 'agent-browser-pool' \
            "Pool exhausted — force-reaped lane $oldest_lane. Possible leak." >/dev/null 2>&1
        _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
        # (c) one final acquire; peer may have won the race → rc 1 is acceptable
        if N="$(pool_acquire_locked)"; then printf '%s\n' "$N"; return 0; fi
    fi
    # (d) all-live-owners / no stale / lost the race: alert + fail non-zero, nothing echoed
    _pool_alert 'agent-browser-pool' \
        "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak." >/dev/null 2>&1
    _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
    return 1
}
```

Notes on the sketch:
- `(( now - start >= POOL_WAIT )) && break` and `(( ts < oldest_ts ))` are both in condition
  contexts → errexit-exempt; no rc-1 abort.
- `local N now …` is declared once, then each `N="$(pool_acquire_locked)"` is a plain
  assignment (NOT `local N=$(…)`), so errexit is preserved (BashFAQ 105 / SC2155).
- `_pool_alert`'s output is fully silenced (`>/dev/null 2>&1`); the only stdout to escape
  `pool_wait_for_lane` is the success `printf '%s\n' "$N"`.
- `POOL_WAIT` is read as an already-validated uint global from `pool_config_init` (168).

## Gotchas list

1. **Never hold a flock across the 2 s `sleep`.** `pool_wait_for_lane` is lock-free; it
   composes the flock-owning `pool_acquire_locked` and the lock-free
   `pool_reap_stale`/`pool_release_lane`. (Q1, pool_reuse_orphan self-deadlock WARNING.)
2. **`pool_acquire_locked` already reaps inline** (via `_pool_acquire_critical_section`,
   1966). The separate `pool_reap_stale >/dev/null` before it is NOT redundant — it uses
   the PUBLIC `pool_release_lane` (daemon close) vs the in-lock
   `_pool_release_lane_internals` (no close); both are correct to call.
3. **Force-reap must use `pool_release_lane`, NOT `_pool_release_lane_internals`.** The
   private one skips the daemon close (forbidden under flock) and would leave a lingering
   daemon session. (Q3.)
4. **`acquired_at` is a numeric epoch** (704/721); compare with `(( ))` only inside
   `if`/`&&`. A corrupt/missing value must be SKIPPED (`continue`), not defaulted to 0.
5. **`(( ))` statement-form aborts on result 0** under set -e. Every arithmetic comparison
   here is in a condition context (`if`/`&&`), which is exempt.
6. **`pool_release_lane`'s close subprocess leaks stdout** (~2472 redirects only stderr).
   Always `>/dev/null`. Same for `pool_reap_stale` (echoes its count).
7. **`POOL_WAIT=0` must be zero poll iterations** → use check-before-body (`break` before
   the reap/acquire/sleep). (Q6.)
8. **Timing uses `_pool_now` epoch, not `$SECONDS`** — robust when `pool_wait_for_lane`
   itself runs in the wrapper's `N=$(…)` subshell, and immune to `unset SECONDS`.
   (Q5; see bash-patterns.md §1.)
9. **`pool_wait_for_lane`'s precondition is `pool_config_init` + `pool_owner_resolve` +
   (by the wrapper) one prior `pool_acquire_locked` that returned 1.** It must NOT be
   called as the very first acquire.
10. **Lost-the-race after force-reap is ACCEPTABLE** (returns 1, nothing echoed). Do not
    retry-loop the force-reap — a peer legitimately won N. (Q10.)
11. **`_pool_alert` is best-effort and non-fatal**: `notify-send` may be absent (guard
    `command -v`); `alerts.log` write may fail (`|| true`). It must NEVER affect
    `pool_wait_for_lane`'s rc.
12. **`notify-send` summary text**: use `'agent-browser-pool'` as the app/summary and the
    message as body, matching the PRD §2.9 wording verbatim
    (`'Pool exhausted — force-reaped lane N. Possible leak.'` — note the em-dash).
13. **No `set -e` interaction with `sleep`** — `sleep` returns 0; safe. `pool_state_init`
    is called inside `pool_acquire_locked`, not here.
14. **Placement at EOF** (after `pool_reuse_orphan`, ~line 2774) under a new
    `# Pool exhaustion (P1.M5.T4.S1)` banner; `_pool_alert` immediately precedes
    `pool_wait_for_lane`. (Q9.)
