# Research: Chrome EADDRINUSE stderr + instant-exit behavior (P1.M2.T1.S1)

Date: 2026-07-12 (bugfix 001)
Host-verified + Chromium-source-researched facts for the `pool_chrome_launch`
EADDRINUSE-detection fix.

---

## 1. THE CRITICAL FINDING: EADDRINUSE does NOT cause Chrome instant-exit

**Chrome (Chromium) does NOT exit immediately when `--remote-debugging-port=<port>`
fails to bind due to EADDRINUSE.** The DevTools HTTP handler
(`content/browser/devtools/devtools_http_handler.cc`) is a best-effort subsystem on
its own thread; on bind failure it `LOG(ERROR)`s and the browser process continues its
main message loop. The CDP endpoint on the specified port never answers.

**Implication for this subtask (P1.M2.T1.S1):** The `pool_chrome_launch`
"instant-exit / empty pgid" guard (`if [[ -z "$pgid" ]]` at lib/pool.sh:1531) does
**NOT** fire for EADDRINUSE in the common case — Chrome is alive, the pgid is captured
successfully, and the failure manifests ~30s later as a CDP timeout in `pool_wait_cdp`.

**Therefore:** The grep-in-the-instant-exit-block approach specified by this subtask's
contract is a **DEFENSIVE** measure that handles the *edge case* where EADDRINUSE *does*
cause instant exit (e.g. a Chrome version/config where the bind failure is fatal, or a
combined error that makes Chrome exit). The **primary** EADDRINUSE recovery (the common
CDP-timeout case) is the job of **P1.M2.T1.S2** (`_pool_launch_and_verify` re-pick port).
This subtask (S1) is still CORRECT and NECESSARY: it converts a fatal `pool_die` into a
retryable return-1 for the instant-exit-with-EADDRINUSE-in-log case, so that S2's caller
contract (return 1 = retryable) is honored on BOTH failure paths.

This nuance MUST be documented in the PRP and the function docstring so the implementer
does not mistakenly believe S1 alone fully fixes the race.

Sources:
- `content/browser/devtools/devtools_http_handler.cc` — the `LOG(ERROR) << "Cannot start
  http server for devtools."` path; non-fatal.
  https://chromium.googlesource.com/chromium/src/+/main/content/browser/devtools/devtools_http_handler.cc
- `chrome/browser/devtools/remote_debugging_server.cc` — creates the handler during
  `PreMainMessageLoopRun`; non-fatal on failure.
- Puppeteer `BrowserRunner.ts` polls the CDP endpoint (not exit code) because Chrome
  does not exit on DevTools bind failure.
  https://github.com/puppeteer/puppeteer/blob/main/src/node/BrowserRunner.ts

---

## 2. Chrome's actual EADDRINUSE stderr strings (Chromium source)

| Source file | String | Reliability in `google-chrome-stable` |
|---|---|---|
| `devtools_http_handler.cc` | `Cannot start http server for devtools.` | **HIGH** — `LOG(ERROR)` always compiled in. PRIMARY grep target. |
| `tcp_server_socket_posix.cc` | `Bind failed: Address already in use` | **MEDIUM** — only if `PLOG(ERROR)` (not `DPLOG`, which is debug-only). Uncertain in release. |
| `net_error_list.h` | `ERR_ADDRESS_IN_USE` (-147) | The net::Error enum name; the **literal string `EADDRINUSE` never appears** in Chrome stderr. |
| `address_already_in_use.cc` | (port-conflict retry handler) | May log a conflict message; exact text unverified. |

### Critical: the literal `EADDRINUSE` is DEAD
Chrome uses `ERR_ADDRESS_IN_USE` (the net::Error enum), NOT the C errno macro name
`EADDRINUSE`. The item description's grep alternative `EADDRINUSE` will **never match**
Chrome's actual output. However — the item description is the CONTRACT, and the grep
pattern is given verbatim. The implementer should use the pattern AS SPECIFIED (it is
harmless — the dead `EADDRINUSE` alternative simply never matches; the other alternatives
do the work). The PRP documents this but does NOT deviate from the contract pattern.

---

## 3. GREP PATTERN CRITIQUE (item description vs. Chromium reality)

**Item description specifies (verbatim contract):**
```bash
grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null
```

**Host-verified truth table** (tested this session against known phrases):

| Test phrase | Matches? |
|---|---|
| `Address already in use` | ✅ MATCH (`address already in use`) |
| `Cannot start http server for devtools` | ✅ MATCH (`cannot start http server`) |
| `Couldn't bind to port` | ✅ MATCH (`couldn.t bind` — the `.` matches the apostrophe) |
| `bind: Address already in use` | ✅ MATCH |
| `EADDRINUSE` (bare) | ✅ MATCH (but never appears in real Chrome output — dead) |
| `Failed to bind to any port` | ❌ NO MATCH (NOT covered — `bind.*failed` requires "failed" AFTER "bind"; this has "Failed...bind") |
| `Bind failed: Address already in use` | ✅ MATCH (`bind.*failed`) |
| Broken GPU / bad flags / missing binary | ❌ NO MATCH (correct — these stay fatal) |
| Empty log | ❌ NO MATCH (correct) |

**Verdict:** The item's pattern is CORRECT for the known Chrome EADDRINUSE strings
(`cannot start http server`, `address already in use`, `Bind failed`). The `EADDRINUSE`
and `couldn.t bind` alternatives are dead/harmless. The pattern does NOT over-match
non-EADDRINUSE instant-exit causes (verified: broken GPU, bad flags, missing binary,
empty log all NO MATCH). **Use the pattern AS SPECIFIED in the contract.** Do NOT
"improve" it — the contract is explicit, and deviating risks the implementer second-
guessing the item author.

---

## 4. HOST-VERIFIED MOCK TEST APPROACH (this session)

**Proven working:** A fake chrome binary (a bash script that writes an EADDRINUSE line
to stderr then exits 1) triggers the exact code path S1 modifies:

```bash
# fake-chrome script:
#!/usr/bin/env bash
echo "[ERROR:devtools_http_handler.cc(123)] Cannot start http server for devtools." >&2
exit 1
```

Simulated launch (mirrors `pool_chrome_launch` lines 1519-1538):
```bash
setsid -- "$fakechrome" >"$log_file" 2>&1 &
PID=$!; sleep 0.2
pgid="$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')" || true
# pgid is EMPTY (fake chrome exited instantly) → instant-exit block fires
if [[ -z "$pgid" ]]; then
    if grep -qiE 'cannot start http server|...' "$log_file" 2>/dev/null; then
        echo "DETECTED: EADDRINUSE → return 1 (retryable)"   # ✅ THE FIX
        kill "$PID" 2>/dev/null || true
        exit 1   # return 1 (NOT pool_die)
    else
        echo "NOT EADDRINUSE → pool_die (fatal)"              # genuine misconfig
        exit 2
    fi
fi
```

**Verified output:** `pgid=[]`, `DETECTED: EADDRINUSE → return 1 (retryable)`, exit code 1.

This proves: (a) the mock triggers the instant-exit block, (b) the grep detects the
EADDRINUSE text in the log, (c) the function returns 1 instead of `pool_die`-ing. The
test in validate.sh will use this exact mock approach.

---

## 5. STRICT-MODE (set -euo pipefail) TRAPS for the edit

The edit site (lib/pool.sh:1531-1538) is INSIDE a function that runs under
`set -euo pipefail` (propagated by the S1 header). Key traps:

| Trap | Symptom | Fix (already applied in surrounding code) |
|---|---|---|
| `grep` returns 1 (no match) | bare `grep` aborts under set -e | `grep ... \|\| true` OR wrap in `if grep ...; then` (the `if` makes non-zero a clean branch) — the item uses `if grep -qiE ...; then`, which is correct |
| `kill` returns non-zero (process already dead) | bare `kill` aborts | `kill "$PID" 2>/dev/null \|\| true` (already in the existing code at line 1536) |
| `pool_die` exits the process | (intended for the non-EADDRINUSE path) | keep `pool_die` ONLY in the else branch; the EADDRINUSE branch uses `return 1` |

The item's specified logic structure is already set -e-safe:
```bash
if grep -qiE '...' "$log_file" 2>/dev/null; then   # if-condition = errexit-exempt
    _pool_log "..."                                 # _pool_log never fails
    kill "$POOL_CHROME_PID" 2>/dev/null || true     # guarded
    return 1                                        # NON-FATAL, retryable
fi
# falls through to the existing pool_die (fatal) for non-EADDRINUSE
```

---

## 6. TASK BOUNDARY (S1 vs S2 vs S3)

| Concern | S1 (THIS task) | S2 (`_pool_launch_and_verify` re-pick) | S3 (concurrency test) |
|---|---|---|---|
| EADDRINUSE grep in `pool_chrome_launch` instant-exit block | ✅ HERE | — | — |
| `pool_chrome_launch` returns 1 (not pool_die) on EADDRINUSE instant-exit | ✅ HERE | — | — |
| Update `pool_chrome_launch` docstring (return-1-on-EADDRINUSE) | ✅ HERE | — | — |
| `_pool_launch_and_verify` catches return 1 + re-picks a port | — | ✅ S2 | — |
| Fix stale "retries on EADDRINUSE" comment (lines 1335, 1383) | — (item says "S2") | ✅ S2 | — |
| Concurrency test exercises collision recovery | — | — | ✅ S3 |
| validate.sh selftest for the grep/return-1 logic | ✅ HERE (mock-based) | — | — |

**IMPORTANT:** The item description assigns the stale-comment fix to S2
("Add port re-pick retry in _pool_launch_and_verify + fix stale comment"). S1 must NOT
touch the stale comments at lines 1335 and 1383 — that's S2's scope. S1 ONLY modifies
`pool_chrome_launch` (the instant-exit block + docstring) and adds the validate.sh selftest.

---

## 7. TEST INFRASTRUCTURE (validate.sh) — confirmed

- `assert_eq EXPECTED ACTUAL [LABEL]` (validate.sh:58) — returns 0/1, calls `_fail` on mismatch.
- `selftest_*` functions are auto-discovered by `_run_selftest_suite` (validate.sh:418)
  via `compgen -A function | grep "^selftest_" | sort` — NO registration needed.
- The selftest runner is SINGLE-SETUP: `setup()` is called ONCE for all selftest bodies
  (AGENTS.md §4 — per-test setup hangs on the 3rd call). The new body MUST be named
  `selftest_*` (NOT `test_*`).
- P1.M1.T1.S1 (boolean) and P1.M1.T2.S1 (dispatch) selftest blocks have LANDED
  (validate.sh:324-416). The new block goes AFTER `selftest_dispatch_classify_cases`
  (ends ~line 416) and BEFORE `_run_selftest_suite` (line 418).
- `setup()` sets `ABPOOL_REPO`, `ABPOOL_TEST_ROOT`, `HOME`, `AGENT_BROWSER_POOL_STATE`,
  etc. + calls `pool_config_init` + `pool_state_init`. The new selftest body will
  INHERIT these globals but must create its OWN fake-chrome binary + isolated log path
  (do NOT pollute the shared state dir — use a subdirectory of `$ABPOOL_TEST_ROOT`).
- The selftest body runs in the MAIN shell (not a subshell) under `_run_selftest_suite`.
  A failing `assert_eq ... || return 1` ends the body (fail-fast) → recorded FAIL →
  suite continues. Match the P1.M1.T1.S1 `selftest_config_bool_*` idiom.

---

## 8. AGENTS.md COMPLIANCE for the selftest

- **No real Chrome** — use a fake-chrome script (bash one-liner that writes EADDRINUSE
  to stderr + exits 1). Verified working this session (§4).
- **Isolated temp HOME** — `setup()` already provides `$ABPOOL_TEST_ROOT`; the body
  creates its fake-chrome + log under a subdir of it.
- **Hard timeout** — wrap the `pool_chrome_launch` call in the body with `timeout 10`
  (defensive; the fake chrome exits instantly, so this never trips, but it satisfies
  AGENTS.md §2).
- **Reap what you spawn** — the fake chrome exits instantly (no lingering process).
  The body's `kill "$POOL_CHROME_PID" 2>/dev/null || true` (inside pool_chrome_launch)
  reaps it. Verify no orphans via the body's own cleanup (rm the fake-chrome + log).
- **No process-spawning setup() per test** — the body is `selftest_*` (single-setup).

---

## 9. SOURCES

- Chromium `devtools_http_handler.cc`:
  https://chromium.googlesource.com/chromium/src/+/main/content/browser/devtools/devtools_http_handler.cc
- Chromium `net_error_list.h` (`NET_ERROR(ADDRESS_IN_USE, -147)`):
  https://chromium.googlesource.com/chromium/src/+/main/net/base/net_error_list.h
- Chromium `tcp_server_socket_posix.cc` (SO_REUSEADDR + bind):
  https://chromium.googlesource.com/chromium/src/+/main/net/socket/tcp_server_socket_posix.cc
- Chromium `address_already_in_use.cc` (port-conflict retry handler):
  https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/devtools/address_already_in_use.cc
- Puppeteer `BrowserRunner.ts` (polls CDP, not exit code):
  https://github.com/puppeteer/puppeteer/blob/main/src/node/BrowserRunner.ts
- Linux `bind(2)` / `socket(7)` man pages (EADDRINUSE, SO_REUSEADDR)
- Project: `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/key_findings.md` (Issue 2)
- Project: `plan/001_0f759fe2777c/bugfix/001_af49e87213c6/architecture/scout-boot-connect.md` (§2.5)
- Project: `lib/pool.sh:1440-1545` (pool_chrome_launch), `test/validate.sh:40-80,264-418` (selftest infra)
