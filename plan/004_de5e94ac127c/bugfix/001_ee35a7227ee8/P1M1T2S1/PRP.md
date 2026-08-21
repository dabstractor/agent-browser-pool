# PRP — P1.M1.T2.S1: Build `test/bootrace.sh` harness — fake chrome with `FAKE_CHROME_DELAY` + launch counter, fake agent-browser, single-setup runner

> **Bugfix context**: This subtask is the **harness half** of BUG-002 (Major — same-owner
> boot race, PRD h2.2/h3.1). It does NOT fix pool.sh. It extends the `test/bootrace.sh`
> file created by **P1.M1.T1.S1** (in parallel, Implementing — its PRP is a hard contract;
> see Integration Points) with the one new primitive the BUG-002 race needs: a fake chrome
> with a **startup-delay knob** (`FAKE_CHROME_DELAY`) and a **launch counter**
> (`FAKE_CHROME_COUNT_FILE`), plus a state-aware fake agent-browser, wired into the
> existing single-setup runner. Downstream subtasks **P1.M1.T2.S2/S3/S4** consume this
> harness to drive their fixes green, and **M2's R5–R8** cases land in the same file.

---

## Goal

**Feature Goal**: Give the changeset a deterministic, hermetic way to reproduce the BUG-002 race window (a Chrome whose CDP listener opens N seconds after launch) and to assert **exactly-one-launch** semantics. Extend `test/bootrace.sh` (skeleton + R1/R2 from P1.M1.T1.S1) with:
(a) a fake chrome that parses `--remote-debugging-port` / `--user-data-dir` from argv, **appends one line to `$FAKE_CHROME_COUNT_FILE` on every launch**, sleeps `"${FAKE_CHROME_DELAY:-0}"` **before** opening the `/json/version` HTTP listener, and stays alive until killed;
(b) a fake agent-browser that no-ops `connect` (rc 0), reports the queried session in `--json session list` (the JSON shape `pool_daemon_connected` parses), and rc-0's the terminal exec;
(c) the suite helpers under the contract names `_bootrace_setup` / `_bootrace_teardown` (consolidating the skeleton's `_br_*` helpers — do NOT duplicate the runner);
(d) a trivial **control case** (single `open` with `FAKE_CHROME_DELAY=4` → rc 0, one launch) that must PASS — proving the harness works — and the **R3 race case** (PRD h3.1 repro: cmd A backgrounded, cmd B at 0.8s) left as the **known-red** case with a named FAIL line until T2.S2/S3 land.

**Deliverable**:
1. `test/bootrace.sh` — EXTENDED (not rewritten): the fake-chrome heredoc gains `FAKE_CHROME_DELAY` + `FAKE_CHROME_COUNT_FILE` support (additively — the port-parsing skeleton from T1.S1 stays stable); a new/extended fake-agent-browser heredoc satisfying the full argv/JSON contract below; `_bootrace_setup` / `_bootrace_teardown` helper names (contract §4 of the item); the R3-race case function + the control case; a header-comment block documenting the fixture contract (the env vars, the count-file line format, who consumes what).
2. No changes to `lib/pool.sh`, `bin/`, or the 4 existing suites. Test infrastructure only.
3. R3 written to the test_framework.md §4 spec (B rc=0; exactly one launch; lease `chrome_pid` == the live fake's pid; `release all` → zero `user-data-dir=$EPH` processes, dir gone) — expected **FAIL** against unpatched pool.sh (that is the point).

**Success Definition**:
- `bash -n test/bootrace.sh` + `shellcheck -s bash -S warning test/bootrace.sh` clean.
- The **control case passes**: with `FAKE_CHROME_DELAY=4`, a single `timeout 60 bin/agent-browser-pool open about:blank` under the redirected env exits 0, `FAKE_CHROME_COUNT_FILE` has **exactly 1** line, and the lane boots + connects through the fakes.
- **R3 runs and FAILS with named lines** against unpatched pool.sh — each failed assertion prints a stable `R3:`-prefixed FAIL message (grep-able), the suite records it, and the suite's documented expected state for THIS subtask is "control PASS + R1/R2 PASS (from T1.S1) + R3 FAIL (known-red)". The suite MAY exit 1 in this state — that is correct and documented in the header (it goes green when T2.S2/S3/S4 land).
- Zero orphan processes at suite exit: `pgrep -af` on the fake patterns (`fake-cdp`, `fake-agent-browser`, `user-data-dir=…/abpool-bootrace`) finds nothing after the suite, **even when R3 fails** (per-body cleanup + the teardown trap must run regardless of case outcome).
- The header comment documents: `FAKE_CHROME_DELAY` (seconds, default 0), `FAKE_CHROME_COUNT_FILE` (append pid + port + dir per launch), `_bootrace_setup`/`_bootrace_teardown` contracts, and the consumer list (T2.S2/S3/S4, M2 R5–R8).

## User Persona

**Target User**: The implementing agents of P1.M1.T2.S2/S3/S4 (per-lane boot lock; ensure_connected hardening; release-sweep widening) — they need a deterministic race window and launch-count assertions to drive their fixes TDD-style. Secondary: the M3 final regression gate and any future contributor regression-testing boot races.

**Use Case**: T2.S3's implementer sets `FAKE_CHROME_DELAY=4`, backgrounds command A, fires command B at 0.8s, and asserts B exits 0 with exactly one line in the count file. Today (unpatched) that scenario spurious-fails B, double-launches, clobbers the lease ids, and leaks Chrome — the harness makes all four failure modes **assertable** without any real Chrome.

**User Journey**: `bash test/bootrace.sh` → sandbox under `$HOME`-anchored `mktemp -d` → fixtures built into `$T/bin/` → control case PASSes → R1/R2 PASS → R3 runs, prints named FAIL lines (known-red) → teardown reaps every fake + owner + removes the tree → summary "3 passed, 1 failed (R3 known-red until T2.S2/S3)".

**Pain Points Addressed**:
- The 4 existing suites have **no chrome-delay knob** — the race window (CDP opens seconds after launch) cannot be produced deterministically. The PRD's own repro needed `FAKE_CHROME_DELAY=4` + a 0.8s second command.
- Launch-count visibility: nothing today can assert "exactly one Chrome launched" — the count file gives R3/R4 (and T2.S2's lock tests) that assertion for free.
- The real agent-browser daemon is stateful and un-fakeable-in-parallel; a stateless "always-report-the-queried-session" fake makes `pool_daemon_connected`'s two probes controllable.

## Why

- **BUG-002 is a timing race** — it can only be regression-tested by widening the boot window. The delay knob (sleep BEFORE the listener opens) reproduces exactly the "curl fails only because CDP isn't up YET" condition that send `pool_ensure_connected` down the relaunch branch (lib/pool.sh:2812 probe → 2832+ relaunch).
- **The launch counter is the only clean way** to assert "exactly one Chrome" — counting `pgrep` hits is racy (the doomed second chrome may already be dead by assertion time). The count file is append-only from inside the fake, so the total is exact.
- **test_framework.md §3 names this fixture as "the one new primitive"** this changeset's tests need; §4's R3/R4 both depend on it. Building it once, here, keeps T2.S2/S3/S4 purely additive.
- **The harness IS the deliverable (TDD)**: its own correctness gate is the control case (delay + single open must PASS — proving the fake satisfies `pool_wait_cdp`, `pool_daemon_connect`, and the terminal exec), while R3 stays red until the lib is fixed — proving the harness is sensitive to the bug.

## What

### Fixture contract (what gets built)

**Fake chrome** (`$T/bin/fake-chrome`, heredoc — EXTEND T1.S1's version additively):
```bash
#!/usr/bin/env bash
# fake chrome — BUG-002 harness fixture.
# 1. Parse --remote-debugging-port and --user-data-dir from argv.
# 2. Append "pid port dir" to $FAKE_CHROME_COUNT_FILE (EVERY launch, BEFORE sleeping,
#    so a launch killed mid-delay still counts).
# 3. Sleep ${FAKE_CHROME_DELAY:-0} — the race window: CDP not open yet.
# 4. Serve /json/version (python3 -m http.server) on the port; block forever.
port="" dir=""
prev=""
for a in "$@"; do
    case "$a" in
        --remote-debugging-port=*) port="${a##*=}" ;;
        --user-data-dir=*)         dir="${a##*=}"  ;;
    esac
done
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
if [[ -n "${FAKE_CHROME_COUNT_FILE:-}" ]]; then
    printf '%s %s %s\n' "$$" "$port" "${dir:-<no-dir>}" >>"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || true
fi
if [[ "${FAKE_CHROME_DELAY:-0}" =~ ^[0-9]+$ && "${FAKE_CHROME_DELAY:-0}" -gt 0 ]]; then
    sleep "$FAKE_CHROME_DELAY"
fi
d="$(mktemp -d -t fake-cdp.XXXXXX)"
mkdir -p -- "$d/json"
printf '{"Browser":"FakeChrome/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/fake"}\n' "$port" >"$d/json/version"
cd -- "$d" || exit 1
exec python3 -m http.server "$port" --bind 127.0.0.1
```
(The pool's `pool_chrome_launch` already wraps the binary in `setsid`, so the fake gets its own process group from the pool side — the fake itself needs no `setsid`; teardown kills by the sweep patterns + pgid from the lease.)

**Fake agent-browser** (`$T/bin/fake-agent-browser`, heredoc — EXTEND/REPLACE T1.S1's rc-0 stub):
```bash
#!/usr/bin/env bash
# fake agent-browser — satisfies pool_daemon_connect / pool_daemon_connected / terminal exec.
# Contract (lib/pool.sh:1850-1965):
#   `--session S connect P`            → rc 0 (pool_daemon_connect only checks rc)
#   `--session S --json session list`  → emit {"success":true,"data":{"sessions":[S]}}
#                                        (pool_daemon_connected pipes this through
#                                         jq -e '.data.sessions | index($s)' — reporting
#                                         the QUERIED session makes check (1) pass)
#   anything else (terminal exec: open/get/…) → rc 0
session=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--session" ]] && session="$a"
    prev="$a"
done
if [[ "${2:-}" == "--json" || "${1:-}" == "--json" ]]; then :; fi
# detect `session list` anywhere in argv
for a in "$@"; do
    if [[ "$a" == "session" ]]; then
        # find the word after 'session'
        : # handled below by scanning; simplest: check args for 'list'
        :
    fi
done
case " $* " in
    *" session list "*)
        printf '{"success":true,"data":{"sessions":["%s"]}}\n' "${session:-abpool-1}"
        exit 0
        ;;
    *" connect "*)  exit 0 ;;
    *)              exit 0 ;;
esac
```
(Simplify when implementing — a `case " $* " in *" session list "*)` dispatch plus the
`--session` scan is enough; the sketch above shows the INTENT, tighten it to pass
shellcheck. The `sessions` array reporting the queried session makes the fake
stateless-yet-"connected": after `connect`, every subsequent `session list` for that
session reports it known. Good enough for R3/R4 and the T2.S3 lock tests.)

**Suite helpers**: `_bootrace_setup` (mktemp -d `-p "$HOME"`, env redirects, master
fixture, fixtures build, ONE owner-spawn capability, trap install) and
`_bootrace_teardown` (kill tracked owners + `wait`, `pkill -f` fake patterns, `rm -rf
"$T"` — every line `|| true`). These are the **contract names**; if T1.S1's skeleton
landed `_br_teardown`/`_br_run_suite`, **consolidate**: keep one runner, rename or alias
the setup/teardown to the `_bootrace_*` names, do NOT run two setups.

### Success Criteria

- [ ] `test/bootrace.sh` contains the delay + count knobs in the fake-chrome heredoc; the port/dir parsing skeleton from T1.S1 is preserved (additive edit).
- [ ] `FAKE_CHROME_COUNT_FILE` receives exactly one `pid port dir` line per launch, appended **before** the delay sleep.
- [ ] `FAKE_CHROME_DELAY` (validated `^[0-9]+$`, default 0) sleeps **before** the HTTP listener starts — during the delay, `curl -sf http://127.0.0.1:$port/json/version` fails (the race condition).
- [ ] The fake agent-browser handles all three argv shapes: `--session S connect P` (rc 0), `--session S --json session list` (the JSON above on stdout, rc 0), terminal exec (rc 0).
- [ ] `_bootrace_setup` / `_bootrace_teardown` exist under those names; the suite still calls setup **exactly once**; teardown runs via the EXIT/INT/TERM trap with `|| true` on every line.
- [ ] The control case (`r3_control_delayed_boot_succeeds` or similar): `FAKE_CHROME_DELAY=4`, one `timeout 60` wrapper `open` → rc 0, count file has 1 line, lane lease present with `connected:true` (jq check), then the body releases the lane and reaps.
- [ ] The R3 case per test_framework.md §4: `FAKE_CHROME_DELAY=4`; cmd A backgrounded (`timeout 60 … open about:blank &`); 0.8s later cmd B (`timeout 60 … get cdp-url`); assertions (each a named `R3:` FAIL line): B rc==0; count file has exactly 1 line; lease `chrome_pid` == the pid in the count line (and that pid is live in `/proc`); after `release all`: no `user-data-dir=$EPH` process remains (`pgrep -af` empty) and the lane dir is gone. Expected state at THIS subtask: R3 FAILS (known-red), suite reports it, header documents it.
- [ ] Zero orphans after the suite run even with R3 red: `pgrep -af 'fake-cdp|fake-agent-browser|abpool-bootrace|user-data-dir=.*bootrace'` → empty.
- [ ] Header comment documents the full fixture contract (env vars, count-line format, helper names, consumer subtasks, the known-red status of R3).
- [ ] `bash -n` + `shellcheck -s bash -S warning` clean; `bash test/bootrace.sh` runs to completion (control + R1 + R2 PASS, R3 FAIL named), no hang (total wall time bounded — every subprocess under `timeout`).
- [ ] No edits to `lib/pool.sh`, `bin/`, or the 4 existing suites.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP quotes the exact argv/JSON contracts the fakes must satisfy (verified by direct read of `pool_daemon_connect`/`pool_daemon_connected` at lib/pool.sh:1850–1965 this session), gives ready-to-adapt heredoc implementations for both fakes, specifies the R3 assertion list verbatim from test_framework.md §4 + the PRD repro, and defines the interplay with the parallel T1.S1 skeleton (extend, don't duplicate; consolidate helper names).

### Documentation & References

```yaml
# MUST READ — primary sources
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  why: THE test contract. §1 single-setup runner, §2 bootrace.sh sandbox spec, §3 the
        fake-chrome/fake-agent-browser fixture spec (this subtask implements §3 verbatim),
        §4 the R3/R4 definitions, §5 the safety checklist. Every bullet of §3 maps to a
        deliverable above.
  section: '§3 (fixture spec) + §1 (runner) + §4 (R3) + §5 (safety)'.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: '§2 locking model (why boot work runs outside the flock — the race window), §3 the
        lease schema + the provisional/connected states, §4 the wrapper flow (where the 2nd
        concurrent command lands: reuse path → pool_ensure_connected), §6 the confirmed
        BUG-002 mechanics (probe at 2812 → relaunch at 2832 → clobber at 2847 → leak).'
  section: '§2, §3, §4, §6'.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/P1M1T1S1/PRP.md
  why: THE parallel contract. T1.S1 creates test/bootrace.sh (skeleton + R1/R2 +
        _br_make_fake_chrome/_br_make_fake_ab/_br_spawn_owner/_br_run_suite/_br_teardown)
        and its PRP EXPLICITLY says: "NOTE for T2.S1: it will extend this fake with
        FAKE_CHROME_DELAY + count-file knobs; keep the port-parsing skeleton stable so the
        extension is additive." THIS subtask is that extension. Do not rewrite the runner.
  pattern: 'T1.S1's Task 1b fake-chrome heredoc is the base to extend; its Task 1e runner
        (_br_run_suite + explicit case list + trap) is the runner to REUSE (adding the new
        case functions to the list).'
  gotcha: 'Naming: T1.S1 used _br_* prefixes; THIS item's contract mandates
        _bootrace_setup/_bootrace_teardown as the exported names. Consolidate — either
        rename T1.S1's helpers or define _bootrace_setup/_bootrace_teardown as thin
        wrappers that call the _br_* ones. ONE setup call either way.'

- file: lib/pool.sh
  why: 'Read the three consumers the fakes must satisfy: pool_daemon_connect (1850-1895:
        `"$POOL_REAL_BIN" --session S connect P` rc-checked), pool_daemon_connected
        (1937-1965: `"$POOL_REAL_BIN" --session S --json session list` piped through
        `jq -e --arg s "$session" '"'"'.data.sessions | index($s)'"'"'` THEN
        `curl -sf http://127.0.0.1:$port/json/version`), and pool_chrome_launch (launches
        the fake with --remote-debugging-port=/--user-data-dir= under setsid). Also
        pool_wait_cdp (curl probe + pool_cdp_is_ours identity via ss socket-owner pid).'
  pattern: 'All verified by direct read this session (2026-07-16, HEAD 78ef635).'
  gotcha: 'pool_cdp_is_ours (lib/pool.sh:1663+) checks the CDP socket owner pid via ss —
        the fake python3 process OWNS its listener, so identity passes naturally for a
        single fake per port. No extra fixture work needed.'

- file: test/transparency.sh
  why: '§"fake" idioms + the real-agent-browser note: line 86 says the REAL daemon binary
        is required there — bootrace.sh replaces it with the fake via AGENT_BROWSER_REAL.
        Also the spawn-owner helper (_transparency_spawn_owner ~160-170) that T1.S1'"'"'s
        _br_spawn_owner mirrors.'
  pattern: 'owner simulation: live sleep pid + _pool_get_starttime + env exports.'

- file: test/release_reaper.sh
  why: 'The CANONICAL single-setup runner (_abpool_run_release_reaper_suite) — the shape
        T1.S1 already followed; reuse, do not duplicate.'
  pattern: 'ONE setup; `if fn; then` main-shell bodies; trap reaps all with || true.'

# External references
- url: https://docs.python.org/3/library/http.server.html
  why: 'The fake chrome serves /json/version via `python3 -m http.server "$port"` from a cwd
        containing json/version — curl -sf gets a 200. Same mechanism as T1.S1's fake.'
  critical: 'http.server binds after python starts — the FAKE_CHROME_DELAY sleep must happen
        BEFORE the exec into http.server, else the listener would open instantly and the
        race window vanishes. python3 present on host (T1.S1 verified).'

- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
  why: '${FAKE_CHROME_DELAY:-0} defaulting + the ${a##*=} argv-value extraction in the fakes.'
  critical: 'Validate the delay against ^[0-9]+$ inside the fake — a stray non-numeric value
        must not make every fake exit 1 (silent test breakage). Default 0 = instant CDP.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                      # 4889 LOC — pool_daemon_connect 1850-1895, pool_daemon_connected
│                                    #   1937-1965, pool_chrome_launch ~1478+, pool_wait_cdp ~1760+
├── bin/agent-browser-pool           # the wrapper the R3 cases drive (timeout-bounded)
├── test/
│   ├── validate.sh                  # 1636 LOC — framework helpers (reference only; DO NOT EDIT)
│   ├── release_reaper.sh            # 475 LOC — canonical single-setup runner (reference)
│   ├── transparency.sh              # 611 LOC — owner-sim + fake idioms (reference)
│   ├── concurrency.sh               # 683 LOC — fake-owner study (reference)
│   └── bootrace.sh                  # ← T1.S1 (parallel) creates it: skeleton + R1/R2 + _br_* helpers.
│                                    #   THIS subtask EXTENDS it (delay/count fakes, _bootrace_* names,
│                                    #   control case, R3 known-red).
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/{system_context,fix_design,test_framework}.md
    └── P1M1T1S1/PRP.md              # parallel contract (see Integration Points)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONE file edited:
#   test/bootrace.sh — EXTEND:
#     + fake-chrome heredoc: FAKE_CHROME_DELAY + FAKE_CHROME_COUNT_FILE (additive)
#     + fake-agent-browser heredoc: full argv/JSON contract (replaces T1.S1's rc-0 stub)
#     + _bootrace_setup / _bootrace_teardown (contract names; consolidate _br_* helpers)
#     + control case + r3_bug002_race_e2e (known-red, named FAIL lines)
#     + header comment: the fixture contract + known-red status + consumer list
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (delay BEFORE listener): the sleep must happen BEFORE `exec python3 -m
# http.server` — python binds the port at startup. Sleep-after-exec = no race window.
# During the delay, `curl -sf http://127.0.0.1:$port/json/version` MUST fail (that is the
# condition that mis-sends pool_ensure_connected down the relaunch branch). Sanity-check:
#   FAKE_CHROME_DELAY=4 $T/bin/fake-chrome --remote-debugging-port=45999 --user-data-dir=/tmp/x &
#   sleep 1; curl -sf http://127.0.0.1:45999/json/version && echo "RACE WINDOW BROKEN" || echo "window OK"
#   sleep 4;  curl -sf http://127.0.0.1:45999/json/version && echo "listener OK"

# CRITICAL (count BEFORE sleep): append to FAKE_CHROME_COUNT_FILE before the delay sleep —
# a launch killed mid-delay (e.g. pool_wait_cdp's timeout pgroup kill) must still count.
# R3's exactly-one-launch assertion reads the file AFTER both commands settle; appends are
# atomic-ish for short lines (single write(2)); still, keep the line SHORT (pid port dir).

# CRITICAL (single setup, AGENTS.md §4): ONE _bootrace_setup call for the whole suite. The
# 3rd per-test setup() call HANGS a shared sandbox. T1.S1 already built the single-setup
# runner — reuse it; add the new case functions to its explicit run list.

# CRITICAL (R3 is intentionally red): the suite exits non-zero while R3 fails. That is the
# documented state for THIS subtask (TDD: the harness proves the bug exists). Header must
# say so, or a grader will read the red suite as a harness bug. T2.S2/S3/S4 turn it green.

# CRITICAL (R3 cleanup must run even when assertions fail): the body must do its release +
# pkill + rm in a way that executes despite early `return 1`s. Pattern: run the assertions
# collecting into a variable, then clean up, then report — OR put the cleanup lines BEFORE
# the return-1 paths. Simplest robust shape: perform the scenario, snapshot all observable
# state (rc2, count, lease json, pgrep output) into locals, run the CLEANUP, THEN assert on
# the snapshots. Never assert-then-clean (a failed first assert leaks the fake chrome).

# CRITICAL (backgrounded cmd A needs reaping): `timeout 60 … open … &` leaves a job; after
# it exits (or times out), the body must `wait $!` (bounded — timeout guarantees exit) so
# no zombie lingers. Track spawned pids; kill + wait in per-body cleanup and teardown.

# GOTCHA (session-list JSON must be exact): pool_daemon_connected runs
#   "$POOL_REAL_BIN" --session S --json session list | jq -e --arg s S '.data.sessions | index($s)'
# The fake MUST print {"success":true,"data":{"sessions":["S"]}} (with the QUERIED session)
# on stdout. Note the call passes `--session S` BEFORE `--json session list` — the fake's
# argv scan must find the session value wherever it appears. jq -e exits 0 iff index found.

# GOTCHA (curl is a REAL binary here): unlike selftest-style curl stubs, bootrace runs the
# REAL curl against the REAL fake listener — do not stub curl in these bodies; the delay
# knob is what makes curl fail transiently.

# GOTCHA (port selection): pool_find_free_port picks from $POOL_PORT_BASE.. range and
# avoids lease-claimed + ss-listening + curl-live ports. Each case should use a FRESH
# sandbox state dir or release/reap its lane so port reuse conflicts don't flake. The
# suite-level sandbox may be shared for the tree, but lanes/leases must be per-case clean.

# GOTCHA (no fd-9 self-deadlock): never flock fd 9 on acquire.lock from a test. R3's
# backgrounded commands go through the real wrapper — fine. Any test-side locking (T2.S2
# will exercise pool_lane_boot_lock) uses the lib's own per-lane lock files.

# GOTCHA (set -e in the suite): pgrep/pkill/curl return 1 legitimately — guard every bare
# rc-1 call with `|| true` or `if`. All trap lines end `|| true`. `(( ))` only inside if.

# GOTCHA (mktemp -p "$HOME" for real-FS lanes): BUG-001's guard + R1/R2 want btrfs
# semantics on this host; keep T1.S1's `mktemp -d -p "$HOME"` sandbox anchoring. The
# FAKE_CHROME_DELAY race cases work on any FS, but consistency with T1.S1 avoids surprises.
```

## Implementation Blueprint

### Data models and structure

No lib data models change. The harness's "data model" is the **count-file line format** and the **fixture env contract** (both documented in the header):

```
FAKE_CHROME_DELAY       seconds the fake chrome sleeps BEFORE opening the CDP listener
                        (default 0; validated ^[0-9]+$ inside the fake; the race window)
FAKE_CHROME_COUNT_FILE  path; the fake appends "pid port dir" per launch (before sleeping)
_bootrace_setup         ONE suite setup: sandbox + env redirects + fixtures + trap
_bootrace_teardown      trap target: kill owners (+wait), pkill fake patterns, rm -rf tree
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the landed skeleton (T1.S1's output) before editing
  - RUN: test -f test/bootrace.sh && grep -n '_br_make_fake_chrome\|_br_make_fake_ab\|_br_spawn_owner\|_br_run_suite\|_br_teardown\|r1_bug001\|r2_bug001' test/bootrace.sh
  - EXPECT: the skeleton + R1/R2 + _br_* helpers (if T1.S1 has landed). If NOT yet landed
        (still Implementing in parallel), WAIT or build against its PRP's reference
        implementation shape (Task 1b/1e of P1M1T1S1/PRP.md) — the edit points below are
        described by CONTENT, so they apply whenever it lands.
  - RUN: bash test/bootrace.sh 2>&1 | tail -5   # baseline: R1/R2 state (green if T1.S1's lib fix landed)

Task 1: EXTEND the fake-chrome heredoc — delay + count knobs (additive)
  - LOCATE: the fake-chrome heredoc inside _br_make_fake_chrome (content: the
        `--remote-debugging-port=*` argv loop + `exec python3 -m http.server`).
  - EDIT: insert, after the port validation and BEFORE the mktemp/http.server tail:
        (a) the user-data-dir parse (`--user-data-dir=*` case in the same loop);
        (b) the count-file append (pid port dir, `>>"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || true`,
            guarded on the var being set — the fake must work when unset);
        (c) the delay sleep (validated ^[0-9]+$, default 0, only when > 0).
  - PRESERVE: the port-parsing skeleton, the json/version file write, the http.server exec.
    (See the What section for the full target heredoc — adapt T1.S1's landed text toward it.)
  - GOTCHA: the count append and the sleep come BEFORE the listener; see Known Gotchas.

Task 2: EXTEND/REPLACE the fake-agent-browser heredoc — full argv/JSON contract
  - LOCATE: the fake-agent-browser heredoc in _br_make_fake_ab (T1.S1's is `exit 0`).
  - REPLACE with the three-shape dispatcher (see the What section): scan argv for the
        `--session` value; `case " $* " in *" session list "*)` → print the
        {"success":true,"data":{"sessions":["S"]}} JSON; `connect` → rc 0; else rc 0.
  - VERIFY the JSON shape against pool_daemon_connected (lib/pool.sh:1951): pipe the fake's
        output through the EXACT jq the lib uses and confirm exit 0:
        $T/bin/fake-agent-browser --session abpool-1 --json session list \
          | jq -e --arg s abpool-1 '.data.sessions | index($s)' >/dev/null && echo OK

Task 3: CONSOLIDATE the suite helpers to the contract names
  - ADD `_bootrace_setup` / `_bootrace_teardown` (this item's contract names). If T1.S1's
        `_br_teardown`/`_br_run_suite` exist: either rename them or make _bootrace_* thin
        wrappers. ONE setup call site; ONE trap; the run list gains the new cases.
  - _bootrace_setup responsibilities (from T1.S1's Task 1a + this contract): mktemp -d -p
        "$HOME", home/state/active/master/bin dirs, master content (Local State +
        Default/Preferences + master-marker.txt), env redirects (HOME, POOL_STATE,
        EPHEMERAL_ROOT, MASTER, CHROME_BIN, BROWSER_REAL, ALLOW_SLOW_COPY=1), fixture
        builds, declare -a BR_OWNERS=(), trap '_bootrace_teardown' EXIT INT TERM, and
        export FAKE_CHROME_COUNT_FILE="$T/chrome-launches.log" (a suite-level default the
        cases can reset per-case with `: >`).
  - _bootrace_teardown: kill owners (+ wait), pkill -f the fake patterns (fake-cdp,
        fake-agent-browser is a script not a daemon — nothing to pkill for it, but the
        pattern sweep in test_framework §"zero orphans" covers it), pkill
        user-data-dir=…bootrace, rm -rf "$T". Every line `|| true`.

Task 4: ADD the control case (the harness's own green gate)
  - r3_control_delayed_boot_succeeds() (name it with the r-prefix convention the file uses):
        owner = _br_spawn_owner; : > "$FAKE_CHROME_COUNT_FILE"; export FAKE_CHROME_DELAY=4;
        timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank → rc must be 0;
        count file must have EXACTLY 1 line; the lease lanes/1.json exists with
        .connected == true (jq -r); cleanup: timeout 30 … release all || true; pkill the
        fake-cdp pattern for this lane; rm the lease + lane dir; wait on any spawned pids.
  - EXPECT: PASS against current pool.sh (a SINGLE command with a slow-booting chrome is
        the supported case — pool_wait_cdp waits up to 15s). If this FAILS, the HARNESS is
        wrong (fake contract mismatch) — fix the fake, not the expectation.

Task 5: ADD the R3 race case (known-red)
  - r3_bug002_race_e2e() per test_framework.md §4 and the PRD h3.1 repro:
        owner; : > count file; FAKE_CHROME_DELAY=4;
        cmd A: timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 &
        apid=$!; sleep 0.8;
        cmd B: rc2=0; timeout 60 … get cdp-url >/dev/null 2>&1 || rc2=$?;
        wait "$apid" || true;
        SNAPSHOT state (before cleanup): n_launches=$(wc -l < count); lease_pid=$(jq -r
        .chrome_pid lanes/1.json 2>/dev/null || echo 0); live_pids=$(pgrep -f
        "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" || true);
        CLEANUP: release all || true; pkill -f the ephemeral pattern || true; sleep 0.3;
        survivors=$(pgrep -f "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" || true);
        dir_gone check on $EPH/1; wait any spawned pids; rm lease/dir || true.
        ASSERT (each a named _fail "R3: …"): rc2 == 0; n_launches == 1; lease_pid is in
        /proc AND matches a count-file pid; survivors empty; dir gone.
  - EXPECT at THIS subtask: at least the rc2/launch-count/lease-pid assertions FAIL with
        named lines (the PRD repro observed rc2=1, launches=2, clobbered lease pid, leaked
        chrome). The body MUST still leave zero orphans (snapshot-then-clean-then-assert).
  - GOTCHA: `pgrep -f` returns 1 on no match — `|| true` everywhere; capture into vars.

Task 6: UPDATE the run list + header + VERIFY
  - Add r3_control… and r3_bug002_race_e2e to the runner's explicit case list (order:
        control BEFORE R3 so a harness bug is visible before the known-red).
  - HEADER COMMENT: purpose, the fixture contract (FAKE_CHROME_DELAY/FAKE_CHROME_COUNT_FILE
        formats), _bootrace_setup/_bootrace_teardown, the consumer list (T2.S2/S3/S4 add
        R4 + lock cases here; M2 adds R5–R8 here), the KNOWN-RED status of R3 until
        T2.S2/S3 land, invocation `bash test/bootrace.sh`.
  - RUN:
      bash -n test/bootrace.sh && shellcheck -s bash -S warning test/bootrace.sh
      bash test/bootrace.sh ; echo "rc=$?"     # expect: control+R1+R2 PASS, R3 FAIL named, rc=1 (documented)
      pgrep -af 'fake-cdp|fake-agent-browser|abpool-bootrace|user-data-dir=.*bootrace' || echo "zero orphans"
      bash test/validate.sh                    # untouched suites stay green
```

### Implementation Patterns & Key Details

```bash
# Pattern A — snapshot-then-clean-then-assert (R3's no-leak-on-failure shape):
rc2=0; timeout 60 … get cdp-url … || rc2=$?
wait "$apid" 2>/dev/null || true
n_launches="$(wc -l <"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || printf 0)"
lease_pid="$(jq -r '.chrome_pid // 0' "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || echo 0)"
# --- cleanup FIRST (always runs) ---
timeout 30 … release all >/dev/null 2>&1 || true
pkill -f "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
sleep 0.3
survivors="$(pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true)"
dir_gone=1; [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1" ]] && dir_gone=0
# --- assertions LAST (on snapshots) ---
[[ $rc2 -eq 0 ]]        || _fail "R3: second command rc=$rc2 (spurious failure)"
…

# Pattern B — the fake session-list JSON (exact shape pool_daemon_connected parses):
printf '{"success":true,"data":{"sessions":["%s"]}}\n' "$session"
# verified with the lib's own jq:  … | jq -e --arg s "$s" '.data.sessions | index($s)'

# Pattern C — delay + count ordering inside the fake chrome:
parse argv → validate port → APPEND count line → SLEEP $FAKE_CHROME_DELAY →
mktemp cdp docroot → write json/version → exec python3 -m http.server $port
# (count before sleep: killed-mid-delay launches still count; sleep before listener: the
#  curl probe fails during the window = the race condition)
```

### Integration Points

```yaml
CODE (ONE file, extended):
  - test/bootrace.sh — delay/count fake chrome; full fake agent-browser; _bootrace_setup/
        _bootrace_teardown; control case; r3_bug002_race_e2e (known-red); header contract.

CONSUMED (do not implement here):
  - lib/pool.sh pool_daemon_connect/pool_daemon_connected/pool_chrome_launch/pool_wait_cdp/
        pool_cdp_is_ours — the fakes satisfy their existing contracts; NO lib edits.
  - T1.S1's skeleton (parallel contract): runner, R1/R2, _br_spawn_owner, sandbox env —
        REUSED, consolidated under _bootrace_* names, not duplicated.

DOWNSTREAM CONSUMERS (later subtasks add cases to this file; keep it structured for that):
  - P1.M1.T2.S2 (boot lock): adds R4-style pre-port-race cases using the same knobs.
  - P1.M1.T2.S3 (ensure_connected hardening): drives R3 GREEN — the known-red flips.
  - P1.M1.T2.S4 (release sweep widening): adds leak-assertion cases reusing Pattern A.
  - P1.M2 (R5–R8 minor-bug cases) land in this same file per test_framework §4.

CONFIG: none (fixture env vars are file-local conventions documented in the header).
ROUTES/DATABASE: none.
```

## Validation Loop

> AGENTS.md §1/§2: no real Chrome, no real agent-browser, no operator state. Everything
> below runs the fakes under `timeout` in a redirected temp tree.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n test/bootrace.sh
shellcheck -s bash -S warning test/bootrace.sh
# Expected: zero output from both. (Fix the fake-agent-browser sketch's dead code — the
# What-section sketch shows intent; the landed version must be clean.)
```

### Level 2: Harness Self-Validation (the TDD core of THIS subtask)

```bash
# 2a. Control case green (proves the fakes satisfy the pool's contracts):
bash test/bootrace.sh 2>&1 | grep -E '^==|PASS|FAIL'
# Expected: control PASS + R1 PASS + R2 PASS (R1/R2 per T1.S1's landed state) and
#           r3_bug002_race_e2e FAIL with named "R3: …" lines. Suite rc=1 — DOCUMENTED.

# 2b. Delay knob actually creates the window (isolated 6s micro-check):
T=$(mktemp -d); trap 'rm -rf $T; pkill -f fake-cdp 2>/dev/null||true' EXIT
cat >"$T/fc" <<'EOF'
#!/usr/bin/env bash
port=""; for a in "$@"; do [[ "$a" == --remote-debugging-port=* ]] && port="${a##*=}"; done
d=$(mktemp -d -t fake-cdp.XXXXXX); mkdir -p "$d/json"
printf '{"Browser":"x"}\n' >"$d/json/version"
[[ -n "${FAKE_CHROME_DELAY:-}" ]] && sleep "$FAKE_CHROME_DELAY"
cd "$d" && exec python3 -m http.server "$port" --bind 127.0.0.1
EOF
chmod +x "$T/fc"; FAKE_CHROME_DELAY=4 "$T/fc" --remote-debugging-port=45991 & fpid=$!
sleep 1
curl -sf http://127.0.0.1:45991/json/version >/dev/null 2>&1 && echo "BROKEN: window closed" || echo "window OK (curl fails during delay)"
sleep 4.2
curl -sf http://127.0.0.1:45991/json/version >/dev/null 2>&1 && echo "listener OK" || echo "BROKEN: listener never opened"
kill $fpid 2>/dev/null; wait $fpid 2>/dev/null
# Expected: "window OK (curl fails during delay)" then "listener OK".

# 2c. Fake agent-browser satisfies the lib's exact session-list jq:
$T/bin/fake-agent-browser --session abpool-1 --json session list \
  | jq -e --arg s abpool-1 '.data.sessions | index($s)' >/dev/null && echo "session-list JSON OK"
$T/bin/fake-agent-browser --session abpool-1 connect 53420 && echo "connect OK"
# Expected: both OK. (Path per the landed fixture location.)

# 2d. Untouched suites stay green:
bash test/validate.sh; echo "validate rc=$?"
# Expected: rc=0 (no edits to it).
```

### Level 3: Suite Behavior + Hygiene

```bash
# 3a. The suite completes bounded (no hang) and reports the documented state:
time bash test/bootrace.sh 2>&1 | tail -8
# Expected: finishes well under ~2 min (R3's worst path: 15s wait_cdp × bounded cmds),
#           "N passed, 1 failed" naming r3_bug002_race_e2e.

# 3b. Zero orphans EVEN with R3 red:
pgrep -af 'fake-cdp|fake-agent-browser|abpool-bootrace|user-data-dir=.*bootrace' || echo "zero orphans"
# Expected: "zero orphans".

# 3c. Header contract present:
grep -n 'FAKE_CHROME_DELAY\|FAKE_CHROME_COUNT_FILE\|_bootrace_setup\|_bootrace_teardown\|known-red' test/bootrace.sh | head
# Expected: matches in the header comment + the definitions.

# 3d. No out-of-scope edits:
git status --porcelain
# Expected: ONLY test/bootrace.sh modified (plus T1.S1's files if it lands concurrently).
```

### Level 4: End-to-End Race Sensitivity (optional, the PRD repro inline)

```bash
# The PRD h3.1 repro, run by hand once to confirm the harness reproduces the bug class
# (this is exactly what r3_bug002_race_e2e automates; safe — fakes + timeout + temp tree):
#   FAKE_CHROME_DELAY=4, cmd A bg, cmd B at 0.8s → observe rc2/launch-count/lease-pid.
# Expected pre-fix: rc2=1, 2 launches, lease pid != live pid — matching the PRD's
# observed values (asserted by the R3 named FAIL lines).
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` + `shellcheck -s bash -S warning` clean on `test/bootrace.sh`.
- [ ] Level 2a: control + R1 + R2 PASS; R3 FAIL with named lines; suite rc documented.
- [ ] Level 2b: delay window verified (curl fails during delay, listener opens after).
- [ ] Level 2c: fake session-list JSON passes the lib's exact jq; connect rc 0.
- [ ] Level 2d: `bash test/validate.sh` still green.
- [ ] Level 3a: suite bounded, no hang. Level 3b: zero orphans even with R3 red.

### Feature Validation

- [ ] Fake chrome: count append per launch (before sleep); delay validated/defaulted; port+dir parsed from argv; HTTP /json/version after the delay.
- [ ] Fake agent-browser: `connect` rc 0; `--json session list` emits the exact shape; terminal exec rc 0.
- [ ] `_bootrace_setup`/`_bootrace_teardown` exist under the contract names; setup runs ONCE; trap-installed teardown with `|| true` lines.
- [ ] Control case green (single delayed open → rc 0, 1 launch, connected lease).
- [ ] R3 case present with all five named assertions (rc2 / launches / lease-pid / survivors / dir-gone), known-red, header documents it.
- [ ] Header comment documents the fixture contract + consumers + known-red status.

### Code Quality Validation

- [ ] Additive to T1.S1's skeleton (runner reused, not duplicated; helper names consolidated).
- [ ] Snapshot-then-clean-then-assert in R3 (cleanup runs even on failed assertions).
- [ ] Every subprocess under `timeout`; every rc-1-legitimate call guarded; trap lines `|| true`.
- [ ] No edits to `lib/pool.sh`, `bin/`, or the 4 existing suites.
- [ ] No real Chrome/agent-browser/operator state touched; sandbox under `mktemp -d -p "$HOME"`.

### Documentation & Deployment

- [ ] Header comment IS the doc (Mode: test infrastructure — rides with the work).
- [ ] No new env vars outside the file-local fixture contract; no config/schema changes.

---

## Anti-Patterns to Avoid

- ❌ Don't sleep AFTER starting the listener — python binds at exec; the race window vanishes. Delay must precede `exec python3 -m http.server`.
- ❌ Don't append the count line after the delay — a launch killed mid-delay must still count. Count first, sleep second.
- ❌ Don't assert-then-clean in R3 — a failed early assert would leak the fake chrome past the body. Snapshot, clean, then assert.
- ❌ Don't call setup per case (3rd call hangs a shared sandbox) — ONE `_bootrace_setup`; per-case resources spawned+reaped by the case.
- ❌ Don't duplicate T1.S1's runner — extend its case list; consolidate helpers under `_bootrace_*` instead of running two setups.
- ❌ Don't stub `curl` in these bodies — the delay knob is what makes the REAL curl fail transiently; stubbing curl would hide the very race under test.
- ❌ Don't guess the session-list JSON — it must be `{"success":true,"data":{"sessions":["S"]}}` exactly (verified against `pool_daemon_connected`'s jq at lib/pool.sh:1951). A bare array or wrong nesting makes check (1) always-fail and the control case red.
- ❌ Don't hardcode the chrome port — parse `--remote-debugging-port=` (pool_find_free_port picks).
- ❌ Don't treat R3 red as a harness failure — it is the TDD known-red; the control case is the harness's own green gate. Document in the header.
- ❌ Don't leave backgrounded wrapper jobs unwaited — `wait $apid` (bounded by its timeout) so no zombie lingers.
- ❌ Don't edit `lib/pool.sh` or implement any BUG-002 fix here — T2.S2/S3/S4 own the lib changes; this subtask is the harness only.
- ❌ Don't modify the 4 existing suites or any `plan/` orchestrator files.

---

## Confidence Score

**8 / 10** — one-pass implementation success likelihood.

Rationale: the fakes' contracts are pinned to code read directly this session (the exact
`--session S connect P` rc check, the exact `session list` jq pipeline, the curl/CDP probe
sequence, the setsid launch shape), the runner/sandbox/owner patterns already exist in the
file being extended (T1.S1's PRP quotes them in full and explicitly reserves this
extension), and the R3 assertions are transcribed from both test_framework.md §4 and the
PRD's own observed repro values. The residual −2: (1) the fake-agent-browser must satisfy
`session list` for BOTH the reuse-path probe and post-connect checks — if some path also
parses the non-`--json` `session list` output or expects a `close` side effect, the
control case will surface it and the fake needs one more shape (a small, diagnosable
iteration); (2) the parallel T1.S1 may still be mid-landing — Task 0 gates on reading its
output, and all edit points are specified by content rather than line number to absorb
drift. The control case is the built-in detector for both risks.