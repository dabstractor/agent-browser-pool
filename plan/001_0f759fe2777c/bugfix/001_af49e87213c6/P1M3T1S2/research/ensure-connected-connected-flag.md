# Research: pool_ensure_connected connected-flag check (P1.M3.T1.S2 / Issue #3 read side)

**Date:** 2026-07-14 (host-read against the LIVE `lib/pool.sh`, 4577 LOC)
**Task:** P1.M3.T1.S2 — make `pool_ensure_connected` READ the lease `connected` field and skip
the `pool_daemon_connected` early-exit when it is `false` (the post-close case).
**Sibling contract:** P1.M3.T1.S1 (the WRITE side) is **COMPLETE** — both its production code
(`_pool_clean_args_is_close` at `lib/pool.sh:3792`; the close→`connected=false` block at
`3658-3666`) AND its tests (`selftest_clean_args_is_close_cases`, `selftest_close_marks_lease_disconnected`,
`selftest_open_does_not_flip_connected`, `selftest_close_survives_corrupt_lease` in `test/validate.sh`)
are present. So when S2 runs, **`connected=false` IS durably written on every close**, and S2's job
is purely to consume it.

> **Line-number note:** the item description cites `pool_ensure_connected` at `lib/pool.sh:2306-2402`
> with the jq at `:2323` and the early-exit at `:2339-2341`. Those offsets are from the
> ~4424-LOC snapshot in the key_findings doc; the **current** file is 4577 LOC. The function is now
> at **`lib/pool.sh:2390`** (def line), the extraction `mapfile` at **`:2408`**, the early-exit
> `if pool_daemon_connected …` at **`:2423`**. The STRUCTURE is identical to the item's description;
> only the line numbers shifted. Use `grep -n 'pool_ensure_connected()' lib/pool.sh` to locate.

---

## 1. The exact current code of `pool_ensure_connected` (host-read, 2390-2500)

```bash
pool_ensure_connected() {
    local lane="${1:-}"
    local json session port ephemeral_dir now          # <-- EDIT 1: add `connected`
    local -a _f

    [[ "$lane" =~ ^[0-9]+$ ]] || { _pool_log …; return 1; }

    # a. Read the lease (pool_lease_read → json; rc 1 on missing/corrupt → return 1).
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …; return 1; fi

    # EDIT 2: extraction + comment
    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")   # <-- + ', .connected'
    session="${_f[0]:-}"
    port="${_f[1]:-}"
    ephemeral_dir="${_f[2]:-}"
    # <-- EDIT 2b: add  connected="${_f[3]:-true}"

    [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || { …; return 1; }
    [[ -n "$session" ]]      || session="abpool-$lane"
    [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"
    now="$(_pool_now)"

    # b. ALREADY connected?
    # EDIT 3: the early-exit condition
    if pool_daemon_connected "$session" "$port"; then        # <-- prefix with [[ "$connected" == "true" ]] &&
        pool_lease_update "$lane" last_seen_at "$now"
        return 0
    fi

    # c. NOT connected. Chrome alive? curl /json/version …
    if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
        if pool_daemon_connect "$session" "$port"; then
            pool_lease_update "$lane" connected true         # <-- ALREADY sets connected=true ✓
            pool_lease_update "$lane" last_seen_at "$now"
            return 0
        fi
        …; return 1
    fi

    # c. Chrome DEAD → RELAUNCH (rm Singleton*, pool_chrome_launch, wait_cdp, connect) …
    …
    pool_lease_update "$lane" connected true                 # <-- ALREADY sets connected=true ✓ (relaunch success)
    return 0
}
```

**Critical observation:** BOTH the curl-reconnect branch (`:2463`) AND the relaunch branch
(`:2497`) **already** call `pool_lease_update "$lane" connected true` on success. So once S2
makes `connected=false` skip the early-exit, the function naturally falls through to curl→
`pool_daemon_connect` (post-close: chrome alive) which re-binds AND flips `connected` back to
`true`. **No new write is needed** — S2 is a pure READ/branch change. This is exactly the
item's OUTPUT contract.

---

## 2. The four surgical edits (host-verified exact text to match)

| # | What | Current exact text | Target |
|---|---|---|---|
| 1 | locals | `    local json session port ephemeral_dir now` | `    local json session port ephemeral_dir connected now` |
| 2a | jq extraction | `    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")` | `    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir, .connected' <<<"$json")` |
| 2b | field capture | (after `ephemeral_dir="${_f[2]:-}"`) | add `    connected="${_f[3]:-true}"` |
| 3 | early-exit condition | `    if pool_daemon_connected "$session" "$port"; then` | `    if [[ "$connected" == "true" ]] && pool_daemon_connected "$session" "$port"; then` |

Plus **Mode A docstring** updates (the LOGIC comment block at `:2358-2372`): step a lists the
read fields (add `connected`); step b describes the new gate ("only trust the probe if
connected==true; after a close S1 flipped it false → skip → fall through to curl reconnect").

**Why `connected="${_f[3]:-true}"` defaults to `true`:** backward compatibility with leases
predating S1 (or any lease lacking the field). PRD §2.8 + `pool_lease_write` always include
`connected`, but defaulting to `true` preserves the OLD always-probe behavior for any stray
field-absent lease (the safe choice — never newly skip a probe due to a missing field). This
matches the item CONTRACT verbatim ("default to true if missing — backward compatibility").

---

## 3. Why `[[ "$connected" == "true" ]] && …` is the correct gate (host-verified semantics)

- After a close, S1 writes `"connected": false` (JSON boolean). `jq -r .connected` → the **string
  `false`** (host-verified on this jq 1.8.2; `jq -r` renders a JSON boolean `false` as the bare
  word `false`).
- `[[ "$connected" == "true" ]]` → false (the string `false` ≠ `true`) → the `&&` short-circuits:
  `pool_daemon_connected` is **NOT called**, the `if` is false → fall through to the curl branch. ✓
- When `connected==true` (normal booted lease, or a lease post-reconnect), `[[ ]]` → true →
  `pool_daemon_connected` runs as before → behavior UNCHANGED for the happy path. ✓
- The `&&` list is **errexit-exempt** (the condition of `if`), so a `pool_daemon_connected` that
  legitimately returns 1 does NOT abort under `set -euo pipefail`; it just makes the `if` false
  and falls through. (This is the existing, unchanged semantics of the early-exit — S2 only adds
  the `[[ ]] &&` prefix.) ✓

**set -e note:** `[[ "$connected" == "true" ]]` as a bare statement returning 1 WOULD abort, but
it is the left operand of `&&` inside an `if` condition → exempt. Verified pattern (the codebase
already uses `if [[ … ]] && helper …; then` extensively).

---

## 4. The test design — mirror the S1 selftest pattern (Chrome-FREE, hermetic)

The S1 tests (`selftest_close_marks_lease_disconnected` at `test/validate.sh:437`) established the
convention: a `selftest_*` function that writes a `body.sh` heredoc, runs it under
`AGENT_BROWSER_POOL_STATE=… AGENT_BROWSER_REAL=… timeout 15 bash "$script" …`, and asserts rc==0.
The selftest_* functions are picked up by `_run_selftest_suite` (the single-setup runner; they do
NOT each call `setup()`).

**S2's tests are SIMPLER** than S1's (no `pool_wrapper_main`, no `exec`, no `AGENT_BROWSER_REAL`
needed) — they call `pool_ensure_connected` directly with stubs. But to stay consistent + hermetic,
use the same body-script-in-subshell pattern.

### The key mock technique: shadow `curl` with a shell function
`pool_ensure_connected` decides chrome-alive via `curl -sf "http://127.0.0.1:$port/json/version"`.
In a Chrome-free test there is no chrome on that port → the real `curl` returns non-zero → the
function would take the **relaunch** branch (which needs real Chrome — untestable here). **Fix:**
define `curl() { return 0; }` in the body script. Bash resolves functions BEFORE PATH executables,
so `curl -sf …` calls the stub (ignores its args, returns 0) → the **reconnect** branch fires
(chrome "alive") → `pool_daemon_connect` (also stubbed) is called. This is the clean, Chrome-free
way to exercise the exact code path the fix activates.

### Two tests (lock BOTH directions of the contract)

**Test A — `connected=false` → SKIP early-exit → rebind (THE FIX):**
```bash
# body.sh (set -euo pipefail; source pool.sh; config/state init)
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 false   # connected=false
pool_daemon_connected() { return 0; }     # the post-close FALSE POSITIVE (lingering session)
curl()                  { return 0; }     # chrome "alive" → reconnect branch
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }   # the rebind we want to FORCE
pool_ensure_connected 1
test "$_connect_called" = "1"                                  # rebind CALLED (no early-exit)
test "$(jq -r .connected "$POOL_LANES_DIR/1.json")" = "true"   # flipped back to true
```

**Test B — `connected=true` → early-exit → NO rebind (happy path UNCHANGED):**
```bash
pool_lease_write 1 "$2/active/1" 53420 abpool-1 1 pi 100 "$2" 200 201 true    # connected=true
pool_daemon_connected() { return 0; }
curl()                  { return 0; }
_connect_called=0
pool_daemon_connect()   { _connect_called=1; return 0; }
pool_ensure_connected 1
test "$_connect_called" = "0"    # NOT called — early-exit fired (old behavior preserved)
```

**Why `_connect_called` survives the call:** `pool_ensure_connected` and the stubbed
`pool_daemon_connect` run in the SAME shell (the body script) — `pool_ensure_connected` is called
directly, NOT in a subshell — so the assignment persists to the assertion. (Contrast: if the body
itself ran `pool_ensure_connected` in a `( … )`, the var would be lost. Don't.)

---

## 5. Round-trip correctness (the whole Issue-#3 fix, end to end)

1. **close** (S1, COMPLETE): `pool_wrapper_main` sees `close` → `pool_lease_update "$N" connected false`
   → lease now `{"…","connected":false}`. Then `exec`s the real `close` (daemon detaches; session
   lingers in `session list`; chrome stays alive).
2. **next driving command** (S2, THIS task): `pool_wrapper_main` step h calls `pool_ensure_connected`.
   - **Before S2:** reads lease (ignores `connected`) → `pool_daemon_connected` returns 0 (lingering
     session + alive chrome = false positive) → early-exit → `exec` against an UN-BOUND daemon →
     possible spurious failure (PRD §2.15 transparency risk).
   - **After S2:** reads `connected=false` → `[[ "$connected" == "true" ]]` is false → SKIP early-exit
     → curl (chrome alive) → `pool_daemon_connect` RE-BINDS → `connected=true` → `exec` against a
     BOUND daemon → success. ✓

Both halves are independently shippable; together they close Issue #3.

---

## 6. Gotchas

- **`jq -r .connected` on a JSON boolean `false` yields the string `false`** (not `"false"`, not
  `0`). Compare with `== "true"` / `== "false"`, never numeric.
- **`[[ "$connected" == "true" ]] && pool_daemon_connected …`** — the `[[ ]]` is the LEFT operand
  of `&&` inside an `if` condition → errexit-exempt (a false `[[ ]]` does NOT abort; it short-
  circuits). This is the existing idiom; do NOT add `|| true`.
- **Default `:-true`**: an absent `connected` field → behave as the OLD code (probe). Never newly
  skip a probe on a missing field.
- **`curl()` stub shadows the binary** — functions beat PATH. Valid ONLY inside the test's hermetic
  subshell; do NOT define it in lib/pool.sh.
- **`_connect_called` must be set in the SAME shell that asserts** — call `pool_ensure_connected`
  directly, not in a `( … )`.
- **Do NOT add a write of `connected=true`** — both reconnect (`:2463`) and relaunch (`:2497`) paths
  ALREADY do it. S2 is read/branch only.
- **Do NOT touch** the relaunch path, the curl branch, `pool_daemon_connected`, `pool_daemon_connect`,
  or the close path (S1). S2 edits ONLY: locals line, extraction+capture, early-exit condition, and
  the docstring.
- **No real Chrome / no real daemon** (AGENTS.md §1): the test stubs `curl` + `pool_daemon_connected`
  + `pool_daemon_connect`. `pool_chrome_launch` / `pool_wait_cdp` are NEVER reached (curl stub →
  reconnect branch, never relaunch).

---

## 7. Scope guard

- ❌ Edit the WRITE side / close path (S1 — COMPLETE).
- ❌ Add the end-to-end Chrome close→rebind test (P1.M3.T1.S3 — separate).
- ❌ Change the relaunch path, port code (P1.M2), or config (P1.M1).
- ❌ Add a new write of `connected` (the existing writes suffice).
- ❌ Re-read the lease a second time (the SINGLE `pool_lease_read` + one jq fork is the established
  "ONE fork" idiom — extend the jq, don't add a second read).
