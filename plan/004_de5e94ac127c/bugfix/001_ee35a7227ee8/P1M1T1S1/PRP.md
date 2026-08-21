# PRP — P1.M1.T1.S1: Guard `pool_copy_master` against a pre-existing target dir + R1/R2 regression cases

> **Bugfix context**: This subtask fixes **BUG-001 (Major)** from the QA report
> (`plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/` PRD h2.2/h3.0). It is the FIRST work
> item of changeset 001 and has **no dependencies** (fix_design.md §7). It creates
> `test/bootrace.sh` (this changeset's new regression suite) with the single-setup skeleton
> + the R1/R2 cases; sibling subtask **P1.M1.T2.S1** later extends the same file with the
> FAKE_CHROME_DELAY / launch-count fixtures for the BUG-002 race cases (R3/R4). Do NOT
> implement the per-lane boot lock or any BUG-002 work here.

---

## Goal

**Feature Goal**: Make `pool_copy_master` **idempotent against an existing target dir** so that crash-recovery re-boots (and, later, concurrent same-owner boots) can never nest the master copy inside the lane dir. Today, GNU `cp` with an existing destination dir copies the source INTO it (`dst/<basename-src>/…`), so a re-boot of a crashed lane leaves `active/<N>/<master-basename>/` and the lane then runs Chrome against a **fresh empty profile** — silently losing the trusted master identity (logins/Bitwarden) the PRD guarantees (§1.2, §2.7, §2.15). On btrfs the nested copy succeeds and the command exits 0, so nothing surfaces the corruption.

**Deliverable**:
1. `lib/pool.sh` — a BUG-001 crash-recovery guard inserted in `pool_copy_master` immediately after `mkdir -p -- "$parent"` and BEFORE the reflink `cp`: if `$target_dir` exists, `rm -rf` it (with a `pool_die` fallback), plus a BUG-001 comment block.
2. `lib/pool.sh` — the existing "Do NOT mkdir the target" comment extended to note the new guard.
3. `test/bootrace.sh` — NEW file: this changeset's regression suite, with the single-setup runner skeleton (test_framework.md §1) + the fake-chrome / fake-agent-browser fixtures (heredoc → `$T/bin/`, test_framework.md §3) + regression cases **R1** (guard, FS-agnostic) and **R2** (crash-recovery end-to-end) — written TDD-style (failing before the lib fix, green after).
4. Everything else unchanged: die-path messages, findmnt diagnostics, the `(d) Singleton*` strip, the function's rc contract.

**Success Definition**:
- `bash -n` + `shellcheck -s bash -S warning` clean on both `lib/pool.sh` and `test/bootrace.sh`.
- `bash test/bootrace.sh` exits 0 with R1 + R2 PASSING (and a "0 failed" summary), zero orphan processes (`pgrep -af` on the fake patterns finds nothing after the suite).
- Pre-fix (red): running the suite against the UNFIXED lib must FAIL R1 and R2 (proving the tests actually exercise the bug). Implement TDD: write the tests first, watch them fail, apply the guard, watch them pass.
- `grep -n 'BUG-001' lib/pool.sh` finds the guard comment; the guard sits between the `mkdir -p -- "$parent"` block and the `(a) reflink` comment.

## User Persona

**Target User**: Agents in the pool whose lane's boot crashed mid-way (owner killed, power blip, pool_die in the copy→port-write window) and whose NEXT driving command triggers the stuck-lane recovery re-boot. Also: the operator whose btrfs home makes the corruption silent.

**Use Case / Journey**: A boot dies between the master copy (step a) and the port write (step b). The lease stays `port=0` with the copied dir present. The owner's next `agent-browser-pool open …` hits the stuck-lane recovery (wrapper: live lease port==0 → re-boot) → `pool_boot_lane` → `pool_copy_master` → **today**: cp nests the master inside the existing dir → Chrome launches a FRESH EMPTY profile, exit 0, agent silently loses its trusted identity. **After this fix**: the guard removes the stale dir first → clean reflink re-copy (~instant) → trusted profile restored (PRD §2.15 recovery).

**Pain Points Addressed**:
- Silent trusted-profile loss on btrfs (exit 0, no log names the corruption).
- The recovery path added by the previous changeset (`_lane_fresh=1` re-boot) becomes actually SAFE instead of deterministically triggering the bug.
- Second trigger (both-same-owner commands in the pre-port window, BUG-002) is *reduced* to a benign no-op-refresh here; the serialization half is T2.S2's job.

## Why

- **BUG-001 (Major)** per the PRD: `cp -a --reflink=always src dst` with an EXISTING dst dir nests src INTO it. The only `rm -rf` in the current function is on the reflink-**FAILURE** branch (~1306), which is why tmpfs/non-btrfs hosts mask the bug (reflink fails → rm → clean retry) while btrfs silently corrupts. Reproduced in the bug hunt (BH1d: `active/1/` contained `crash-marker, master2` — no top-level `Local State`).
- The fix is 5 lines at a single seam, grounded in `fix_design.md §1` (chosen design: **rm, not fail-loudly** — the stale dir is by definition untrusted partial state from a boot that died before the port write; failing loudly would permanently wedge the very recovery path the last changeset added; the reflink re-copy is ~instant).
- This subtask is the foundation for **P1.M1.T2.S2** (its boot-lane serialization relies on the guarded copy making a second boot's copy a clean refresh) and creates `test/bootrace.sh` which **P1.M1.T2.S1 extends**.

## What

### Behavior change (one inserted guard)

```bash
# Crash-recovery guard (BUG-001): ... [comment block]
if [[ -e "$target_dir" ]]; then
    rm -rf -- "$target_dir" 2>/dev/null \
        || pool_die "pool_copy_master: cannot remove stale target dir: $target_dir"
fi
```
inserted after `mkdir -p -- "$parent"` and before the `(a) reflink` comment. Semantics: any pre-existing target state (stale partial copy from a crashed boot, junk, an empty dir left by a failed reflink) is removed so the subsequent cp always sees a NON-existent destination → top-level copy, never nesting. This covers BOTH the reflink path and the slow-copy retry path (`cp -a` nests identically).

### What does NOT change

- The validation preamble (non-empty + absolute target checks at the top).
- `pool_check_master` precheck.
- The reflink-FAILURE branch's existing `rm -rf ... || true` + slow-copy escape hatch + `pool_die` messages + `findmnt` diagnostics.
- The `(d) Singleton*` strip + its assertion.
- The rc contract (rc 0 or `pool_die`).
- `pool_boot_lane`, the wrapper's stuck-lane recovery, and every other function.

### Success Criteria

- [ ] Guard present at the exact seam with the BUG-001 comment block; "NEVER mkdir the target" comment extended.
- [ ] `bash -n lib/pool.sh` + `shellcheck -s bash -S warning lib/pool.sh` clean (baseline is clean; this edit cannot introduce findings — if it does, you edited beyond the seam).
- [ ] `test/bootrace.sh` exists, runs single-setup, R1 + R2 green, exits 0, zero orphans.
- [ ] R1 asserts the GUARD itself (works on any FS): pre-existing junk dir → after `pool_copy_master`, top-level `Local State` exists AND no `$EPH/1/<master-basename>/` nesting.
- [ ] R2 asserts the e2e recovery: provisional lease `port=0` + dir present → driving command → rc 0 + the master's marker file lands at the lane top level + no nesting.
- [ ] TDD evidence: the suite was run RED (R1+R2 failing) before the lib fix, then GREEN after.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP quotes the exact current text at the insertion seam (verified by direct read of `lib/pool.sh:1278–1357` at HEAD), gives the exact guard code (from the reviewed `fix_design.md §1`), and provides a complete reference implementation of `test/bootrace.sh` — single-setup runner, fake chrome (python3 http.server serving `/json/version`), fake agent-browser (connect/no-op contract), fake owner — all following the project's documented test contract. The non-obvious traps (why `sleep` can't fake chrome, single-setup, no fd-9 self-deadlock, `/proc` liveness) are called out.

### Documentation & References

```yaml
# MUST READ — project-internal (primary)
- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/fix_design.md
  why: '§1 is the reviewed fix design for THIS bug — exact guard code + the rm-vs-fail-loudly rationale + the test contract. §7 confirms this subtask has no deps and that T2.S1 later extends bootrace.sh.'
  section: '§1 BUG-001' (and §7 for ordering).

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/system_context.md
  why: '§5 confirms BUG-001 by direct read: the exact function span (1278-1357), the unguarded cp (~1304), the only-rm-on-failure-branch (~1306), the reachability chain (wrapper stuck-lane recovery → pool_boot_lane step a at ~2628 → crash window copy→port-write at ~2651), and the tmpfs-masking explanation.'
  section: '§5 BUG-001 — CONFIRMED'.

- file: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/architecture/test_framework.md
  why: 'THE test contract for this changeset: §1 single-setup runner pattern, §2 bootrace.sh sandbox spec (env redirects), §3 fake-chrome/fake-agent-browser fixture spec, §4 the R1/R2 definitions, §5 the per-test safety checklist. The new suite MUST follow it.'
  section: '§1–§5 (all)'.

- file: lib/pool.sh
  why: THE file being edited. Read pool_copy_master in full (1278-1357) before editing. The exact text at the insertion seam is quoted in Task 2 (byte-accurate at HEAD).
  pattern: 'Existing style: `[[ ]] || pool_die` validation, `if !` errexit-exempt wraps, pool_die multi-line messages, PRD § citations in comments.'
  gotcha: 'Line numbers drift after edits — the edit tool matches by EXACT TEXT. Also: the function runs under set -euo pipefail; `[[ -e ]]` in `if` is errexit-exempt; keep the `|| pool_die` (NOT `|| true`) on the guard rm per the reviewed design.'

- file: test/release_reaper.sh
  why: '§1 of test_framework.md names its `_abpool_run_release_reaper_suite` the CANONICAL single-setup runner. Mirror its shape: ONE setup, `if test_fn; then` main-shell bodies, suite-level trap reaping everything.'
  pattern: 'Suite-level `trap … EXIT INT TERM` with every line `|| true`; counters PASS/FAIL; exit rc 1 iff any failure.'

- file: test/transparency.sh
  why: 'The `_transparency_spawn_owner` helper (lines ~160-170) is the reference for simulating an owner: `spawn_sim_owner` (from validate.sh) or a live sleep process + export AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME, then call pool_owner_resolve in the current shell to refresh globals. Also shows `env -u` for no-owner cases (not needed for R1/R2).'
  pattern: 'OWNER env exports + starttime capture via _pool_get_starttime.'

# External references
- url: https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
  why: 'Confirms the nesting behavior: when the destination of cp is an existing DIRECTORY, cp copies each source INTO that directory (dst/<basename-src>). This is the root cause the guard removes.'
  critical: 'cp -a src existing-dst-dir NEVER errors on this — it "succeeds" with the wrong shape. That is why the bug is silent on btrfs.'

- url: https://docs.python.org/3/library/http.server.html
  why: 'The fake chrome serves /json/version via `python3 -m http.server PORT` over a directory containing a `json/version` file — zero-dependency, long-lived, curl -sf friendly. pool_wait_cdp/pool_find_free_port probe `curl -sf http://127.0.0.1:PORT/json/version`.'
  critical: 'http.server maps the URL path /json/version to the FILE <cwd>/json/version — create that file. curl -f needs a 200; http.server returns 200 for existing files.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/pool.sh                      # 4889 LOC — pool_copy_master at 1278-1357 (seam ~1302-1304)
├── bin/agent-browser-pool           # CLI entry (source lib/pool.sh + dispatch) — the wrapper R2 drives
├── test/
│   ├── validate.sh                  # 1636 LOC — framework helpers (assert_eq, spawn_sim_owner, setup)
│   ├── release_reaper.sh            # 475 LOC — CANONICAL single-setup runner pattern
│   ├── transparency.sh              # owner-sim + env-redirection idioms
│   └── concurrency.sh               # read-only study for fake-owner idioms
└── plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8/
    ├── architecture/{system_context,fix_design,test_framework}.md
    └── P1M1T1S1/PRP.md              # THIS FILE
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/pool.sh                      # EDIT — BUG-001 guard in pool_copy_master (+ comment sync)
└── test/
    └── bootrace.sh                  # NEW — changeset-001 regression suite: single-setup runner +
                                     #        fake-chrome/agent-browser fixtures + R1/R2
                                     #        (T2.S1 later adds FAKE_CHROME_DELAY/count knobs + R3/R4;
                                     #         minor-fix cases R5-R9 may also land here later)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (why the bug is btrfs-only / why R1 must assert the GUARD): on tmpfs the
# reflink cp FAILS → the existing failure branch rm -rf's the target → clean retry —
# masking the missing guard. On btrfs the nested cp SUCCEEDS → silent corruption, rc 0.
# Therefore R1 must NOT depend on the FS: it asserts the guard directly (pre-create junk
# dir → after pool_copy_master, top-level 'Local State' + no <master-basename>/ nesting).
# This works identically on tmpfs and btrfs. (fix_design.md §1 test contract.)

# CRITICAL (test harness — single setup, AGENTS.md §4): setup() that spawns processes
# MUST be called AT MOST ONCE per suite. The 3rd per-test setup() call HANGS a shared
# sandbox (documented hazard). bootrace.sh uses ONE setup; each R-case spawns + reaps
# its OWN short-lived resources (sim-owner, fake chrome) in the MAIN shell via
# `if test_fn; then … else …` (a failing assert's `return 1` records FAIL, suite continues).

# CRITICAL (no fd-9 self-deadlock): the ONLY flock in the codebase is
# `( flock 9; … ) 9>"$POOL_LOCK_FILE"` in pool_acquire_locked. If a test ever needs a
# lock, it MUST be a NEW file on a NEW fd — never fd 9 on acquire.lock (self-deadlock;
# design note lib/pool.sh:3250-3256). R1/R2 need no extra locks at all.

# GOTCHA (fake chrome): `sleep` CANNOT be the fake chrome — the pool probes
# `curl -sf http://127.0.0.1:PORT/json/version` (pool_wait_cdp + pool_find_free_port),
# so the fake must actually SERVE HTTP. Use `python3 -m http.server "$port"` from a cwd
# containing a `json/version` file (URL path /json/version → file json/version). It is
# long-lived; reap with pkill on a unique pattern. python3 is present on this host.

# GOTCHA (fake chrome launch shape): pool_chrome_launch starts the binary with
# --remote-debugging-port=<port> --user-data-dir=<dir> [+ flags] — the fake must PARSE
# the port from its argv (don't hardcode it; pool_find_free_port picks the lowest free).

# GOTCHA (fake agent-browser): pool_daemon_connect runs
# `"$POOL_REAL_BIN" --session <name> connect <port>` and needs rc 0; the wrapper then
# exec's `"$POOL_REAL_BIN" … <original args>` and must exit 0. A no-op script that
# exits 0 for everything satisfies both (match `connect` if you want to be tidy).

# GOTCHA (liveness): NEVER `kill -0` (ESRCH-vs-EPERM ambiguity). Use `/proc/<pid>`
# existence or pgrep. Reap process GROUPS (`kill -- -pgid`) for anything setsid'd.

# GOTCHA (set -e in tests): pgrep/pkill/curl return 1 legitimately — guard every bare
# rc-1 call (`|| true` or an `if`) or the suite aborts mid-body. Suite trap lines all
# end `|| true` so the trap itself can never fail.

# GOTCHA (edit seam): the guard goes AFTER `mkdir -p -- "$parent"` and BEFORE the
# `(a) reflink` comment. Do NOT touch the existing failure-branch rm (keep `|| true`
# there — it is the retry-path cleanup, intentionally lenient) — the NEW guard's rm
# uses `|| pool_die` per fix_design.md §1 (a stale dir we cannot remove must be loud).
```

## Implementation Blueprint

### Data models and structure

Not applicable — no schema/API change. `pool_copy_master TARGET_DIR` keeps its contract: rc 0 or `pool_die`.

### Implementation Tasks (ordered by dependencies — TDD)

```yaml
Task 1: CREATE test/bootrace.sh — suite skeleton + fixtures + R1/R2 (write FIRST; they must FAIL red)
  - CREATE test/bootrace.sh following test_framework.md §1-§3. STRUCTURE (top to bottom):
    1. Header comment: purpose (BUG-001/002 regressions for changeset 001), the AGENTS.md
       safety contract (single-setup, timeout, zero orphans), invocation `bash test/bootrace.sh`.
    2. `set -euo pipefail`; repo resolution mirroring test/validate.sh:24-26
       (`BOOTRACE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"`;
       `ABPOOL_REPO="$(cd "$BOOTRACE_DIR/.." && pwd)"`).
    3. Counters (BR_PASS/BR_FAIL/BR_FAILED array) + `_fail MSG` helper (printf to stderr; return 1).
    4. `assert_eq EXPECTED ACTUAL [LABEL]` helper (copy from test/validate.sh:58-62).
    5. Sandbox setup (ONE call — see Task 1a).
    6. Fixture builders: _br_make_fake_chrome + _br_make_fake_ab + _br_spawn_owner (Task 1b).
    7. Regression cases r1_… and r2_… (Task 1c/1d) — named with an `r` prefix NOT `test_`
       (avoids any future collision with abpool_run_suite discovery; the suite calls them
       explicitly — but test_framework.md §4 calls them "named functions"; use the literal
       names `r1_bug001_guard_fs_agnostic` / `r2_bug001_recovery_e2e` and an explicit
       run list, OR follow release_reaper's explicit-list style).
    8. Single-setup runner `_br_run_suite` (Task 1e) + BASH_SOURCE gate at the bottom.

  Task 1a: SANDBOX SETUP (hermetic, ONE call for the whole suite):
    ----------------------------------------------------------------
    BR_T="$(mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX)"   # -p "$HOME": real-FS (btrfs) lanes
    mkdir -p -- "$BR_T/home" "$BR_T/state" "$BR_T/active" "$BR_T/master/Default" \
             "$BR_T/bin" "$BR_T/profile-home/.local/bin"
    # A minimal VALID master (pool_check_master requires content — 'Local State' + Default/):
    printf '{"user-experience-enrollment":{"prevalence":0}}\n' >"$BR_T/master/Local State"
    printf '{"marker":"trusted-identity"}\n' >"$BR_T/master/Default/Preferences"
    # TRUSTED-PROFILE MARKER for R2: a file the master carries that MUST land at the lane top level.
    printf 'master-marker\n' >"$BR_T/master/Default/master-marker.txt"
    # Suite trap — every line `|| true` (test_framework.md §1):
    trap '_br_teardown' EXIT INT TERM
    ----------------------------------------------------------------
    ENV REDIRECTS (exported for the whole suite; each R-case may refine):
    HOME="$BR_T/home"; export HOME
    AGENT_BROWSER_POOL_STATE="$BR_T/state"
    AGENT_CHROME_EPHEMERAL_ROOT="$BR_T/active"
    AGENT_CHROME_MASTER="$BR_T/master"
    AGENT_CHROME_BIN="$BR_T/bin/fake-chrome"
    AGENT_BROWSER_REAL="$BR_T/bin/fake-agent-browser"
    AGENT_CHROME_ALLOW_SLOW_COPY=1            # suite-safe on tmpfs CI hosts
    export AGENT_BROWSER_POOL_STATE AGENT_CHROME_EPHEMERAL_ROOT AGENT_CHROME_MASTER \
           AGENT_CHROME_BIN AGENT_BROWSER_REAL AGENT_CHROME_ALLOW_SLOW_COPY

  Task 1b: FIXTURES (heredoc → $BR_T/bin/; chmod +x; NO repo-level fixture files):
    - _br_make_fake_chrome — serves CDP /json/version on the argv port, blocks forever:
      ----------------------------------------------------------------
      _br_make_fake_chrome() {
          cat >"$BR_T/bin/fake-chrome" <<'EOF'
      #!/usr/bin/env bash
      # fake chrome: parse --remote-debugging-port from argv; serve /json/version; block.
      port=""
      for a in "$@"; do
          [[ "$a" == --remote-debugging-port=* ]] && port="${a##*=}"
      done
      [[ "$port" =~ ^[0-9]+$ ]] || exit 1
      d="$(mktemp -d -t fake-cdp.XXXXXX)"
      mkdir -p -- "$d/json"
      printf '{"Browser":"FakeChrome/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/fake"}\n' "$port" \
          >"$d/json/version"
      cd -- "$d" || exit 1
      exec python3 -m http.server "$port" --bind 127.0.0.1
      EOF
          chmod +x -- "$BR_T/bin/fake-chrome"
      }
      ----------------------------------------------------------------
      (NOTE for T2.S1: it will extend this fake with FAKE_CHROME_DELAY + count-file knobs;
      keep the port-parsing skeleton stable so the extension is additive.)
    - _br_make_fake_ab — no-op agent-browser (connect rc 0; exec'd driving cmd rc 0):
      ----------------------------------------------------------------
      _br_make_fake_ab() {
          cat >"$BR_T/bin/fake-agent-browser" <<'EOF'
      #!/usr/bin/env bash
      # fake agent-browser: satisfy pool_daemon_connect (`--session X connect P` → rc 0)
      # and the final exec (any args → rc 0).
      exit 0
      EOF
          chmod +x -- "$BR_T/bin/fake-agent-browser"
      }
      ----------------------------------------------------------------
    - _br_spawn_owner — live sim owner + env exports (mirror _transparency_spawn_owner):
      spawns a `sleep 600` background process, captures its pid + `_pool_get_starttime`,
      exports AGENT_BROWSER_POOL_OWNER_PID/_STARTTIME, echoes the pid. The runner's
      teardown kills any owners this suite spawned (track them in BR_OWNERS+=()).

  Task 1c: R1 — r1_bug001_guard_fs_agnostic (direct function test; works on ANY FS):
    ----------------------------------------------------------------
    r1_bug001_guard_fs_agnostic() {
        # Pre-create the lane dir with junk (any pre-existing state — the crash remnant).
        mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
        printf 'partial-crash-state\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
        # Call the function DIRECTLY in a subshell (a pool_die there must not kill the suite).
        if ! ( source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && \
               pool_copy_master "$AGENT_CHROME_EPHEMERAL_ROOT/1" ) ; then
            _fail "R1: pool_copy_master failed on pre-existing target"; return 1
        fi
        # THE guard assertions:
        if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Local State" ]]; then
            _fail "R1: no top-level 'Local State' in the lane dir (nested or empty copy)"; return 1
        fi
        if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" || -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/$(basename -- "$AGENT_CHROME_MASTER")" ]]; then
            _fail "R1: nested <master-basename>/ dir inside the lane dir (BUG-001 reproduced)"; return 1
        fi
        if [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker" ]]; then
            _fail "R1: stale junk survived (guard did not rm the pre-existing dir)"; return 1
        fi
    }
    # Cleanup at end of body: rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    ----------------------------------------------------------------
    (RED before the fix: cp nests the master → 'Local State' lands at
     $EPH/1/master/Local State → the top-level check FAILS. On tmpfs the reflink branch
     fails and rm's first — so to make R1 RED on tmpfs too, note AGENT_CHROME_ALLOW_SLOW_COPY=1
     is exported (the slow retry would nest identically); on btrfs the reflink nests directly.
     Either way the no-top-level-Local-State / junk-survived assertions catch it.)

  Task 1d: R2 — r2_bug001_recovery_e2e (wrapper-level crash recovery):
    ----------------------------------------------------------------
    r2_bug001_recovery_e2e() {
        local owner rc
        owner="$(_br_spawn_owner)"
        # 1) Provisional lease: lane 1, port=0 — the crashed-boot state. Args:
        #    LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME CWD CHROME_PID CHROME_PGID CONNECTED
        ( source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && pool_state_init && \
          pool_lease_write 1 "$AGENT_CHROME_EPHEMERAL_ROOT/1" 0 abpool-1 "$owner" pi \
          "$(_pool_get_starttime "$owner")" "$BR_T" 0 0 false )
        # 2) Simulate crash-AFTER-copy: the dir exists (partial/junk state).
        mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
        printf 'crash-remnant\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
        # 3) Next driving command through the real wrapper → stuck-lane recovery re-boot.
        rc=0
        timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
        if (( rc != 0 )); then
            _fail "R2: recovery boot failed rc=$rc (expected 0)"; return 1
        fi
        # 4) Trusted-profile assertion: the master's marker file landed at the LANE TOP level.
        if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Default/master-marker.txt" ]]; then
            _fail "R2: master marker missing — lane did not get a clean trusted copy"; return 1
        fi
        # 5) NO nesting.
        if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" ]]; then
            _fail "R2: nested master dir inside lane 1 (BUG-001 reproduced at e2e level)"; return 1
        fi
        # 6) Clean up THIS test's lane (kill fake chrome via cmdline sweep + release).
        timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
        pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
        rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
        rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    }
    ----------------------------------------------------------------
    (RED before the fix on btrfs: the wrapper exits 0 but the lane holds a NESTED copy —
     the marker check FAILS (marker at $EPH/1/master/Default/…). On tmpfs the slow-copy
     retry nests the same way. GREEN after: guard rms the remnant → clean copy → marker
     at top level.)

  Task 1e: SINGLE-SETUP RUNNER + teardown (mirror release_reaper.sh):
    ----------------------------------------------------------------
    _br_run_suite() {
        local fn
        for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e; do
            printf '== %s\n' "$fn"
            if "$fn"; then BR_PASS=$((BR_PASS+1)); printf '   PASS\n';
            else BR_FAIL=$((BR_FAIL+1)); BR_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
        done
        printf '\n%d passed, %d failed\n' "$BR_PASS" "$BR_FAIL"
        (( BR_FAIL > 0 )) && return 1
        return 0
    }
    _br_teardown() {                       # every line || true — the trap can never fail
        for pid in "${BR_OWNERS[@]:-}"; do kill "$pid" 2>/dev/null || true; done 2>/dev/null || true
        pkill -f -- 'fake-cdp\.' 2>/dev/null || true
        pkill -f -- "user-data-dir=$BR_T/active" 2>/dev/null || true
        pkill -f -- 'http.server' 2>/dev/null || true   # narrow: only our fakes ran in this env
        [[ -n "${BR_T:-}" ]] && rm -rf -- "$BR_T" 2>/dev/null || true
    }
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        _br_make_fake_chrome; _br_make_fake_ab
        _br_run_suite || exit 1
    fi
    ----------------------------------------------------------------
    - GOTCHA: BR_OWNERS must be a declared array at the top (`declare -a BR_OWNERS=()`);
      _br_spawn_owner appends. pkill of the OWNER pids + fakes happens ONLY in teardown /
      per-body cleanup — never leave the suite's trap empty.
    - GOTCHA: wrap the wrapper invocation in `timeout 60` (boot includes CDP waits; the
      fake serves instantly, but the bound protects the sandbox — AGENTS.md §2).

Task 2: RUN THE SUITE RED (TDD gate — do this BEFORE editing lib/pool.sh)
  - RUN: bash test/bootrace.sh ; echo "rc=$?"
  - EXPECTED: R1 FAIL + R2 FAIL (the exact assertion messages above), suite rc=1.
    PROOF the tests exercise the bug. If either PASSES pre-fix, the test is wrong —
    debug the test (most likely: the master fixture is empty → pool_check_master dies
    before the cp; ensure 'Local State' + Default/Preferences exist per Task 1a).
  - ALSO RUN the static checks now to have a clean-file baseline:
    bash -n test/bootrace.sh && shellcheck -s bash -S warning test/bootrace.sh

Task 3: EDIT lib/pool.sh — insert the BUG-001 guard (exact text)
  - FIND this EXACT block in pool_copy_master (byte-accurate at HEAD):
      ----------------------------------------------------------------
          parent="$(dirname -- "$target_dir")"
          mkdir -p -- "$parent" \
              || pool_die "pool_copy_master: cannot create parent dir: $parent"

          # (a) reflink CoW copy — instant on btrfs. 2>/dev/null suppresses the per-file
      ----------------------------------------------------------------
  - REPLACE WITH (guard inserted between the mkdir block and the (a) comment; the
    "NEVER mkdir" comment sentence EXTENDED per the contract):
      ----------------------------------------------------------------
          parent="$(dirname -- "$target_dir")"
          mkdir -p -- "$parent" \
              || pool_die "pool_copy_master: cannot create parent dir: $parent"

          # Crash-recovery guard (BUG-001): a previous boot may have died between the
          # copy and the port write (crash/kill mid-boot — the lease stays port=0 with the
          # copied dir present; the wrapper's stuck-lane recovery then re-boots this lane).
          # GNU cp with an EXISTING dst dir copies the source INTO it (dst/<basename-src>/…)
          # → the lane would silently run a FRESH EMPTY profile (no top-level Local State).
          # Remove ANY pre-existing target so the cp below always sees a non-existent
          # destination (idempotent: any target state → clean copy; the reflink re-copy is
          # ~instant). `|| pool_die`: a stale dir we cannot remove must be LOUD, not a
          # silent nest. target_dir is validated non-empty + absolute above.
          # (This also covers the slow-copy retry below — cp -a nests identically — and
          #  makes a concurrent second boot's copy a clean refresh once T2.S2 serializes
          #  boots. Do NOT mkdir the target itself: the guard + cp create it.)
          if [[ -e "$target_dir" ]]; then
              rm -rf -- "$target_dir" 2>/dev/null \
                  || pool_die "pool_copy_master: cannot remove stale target dir: $target_dir"
          fi

          # (a) reflink CoW copy — instant on btrfs. 2>/dev/null suppresses the per-file
      ----------------------------------------------------------------
  - PRESERVE EVERYTHING ELSE in the function verbatim: the validation preamble,
    pool_check_master, the reflink-failure branch (incl. its `rm -rf … || true`), the
    slow-copy escape hatch + die messages + findmnt diagnostics, the (d) Singleton* strip.
  - ALSO EDIT the earlier comment sentence that says
    `# (cp creates it; mkdir-ing it would trigger the nesting hazard). ` —
    leave it as-is OR minimally append `(the BUG-001 guard below removes a pre-existing
    target)`; the new guard comment already documents the hazard, so a minimal touch is fine.

Task 4: VERIFY — static + suite green + zero-orphans sweep
  - RUN (in order):
      bash -n lib/pool.sh
      shellcheck -s bash -S warning lib/pool.sh
      bash -n test/bootrace.sh
      shellcheck -s bash -S warning test/bootrace.sh
      bash test/bootrace.sh ; echo "rc=$?"
      bash test/validate.sh            # existing suites must stay green (guard is additive)
      pgrep -af 'fake-cdp|fake-agent-browser|user-data-dir=.*/abpool-bootrace' || echo "zero orphans"
  - EXPECTED: all four static checks clean; bootrace.sh prints R1 PASS + R2 PASS,
    "2 passed, 0 failed", rc=0; validate.sh unchanged-green; zero orphans.
  - (release_reaper/transparency/concurrency also exercise copy paths but need real
    agent-browser/master — run them only if the sandbox provisions them; the guard is
    additive to a function whose callers' tests already pass at HEAD. validate.sh is
    the required gate here.)

### Implementation Patterns & Key Details

```bash
# Pattern A — the guard (from reviewed fix_design.md §1; rm-not-fail rationale):
if [[ -e "$target_dir" ]]; then
    rm -rf -- "$target_dir" 2>/dev/null \
        || pool_die "pool_copy_master: cannot remove stale target dir: $target_dir"
fi
# [[ -e ]] in `if` is errexit-exempt; `|| pool_die` makes an un-removable stale dir LOUD.
# Contrast: the EXISTING failure-branch rm keeps `|| true` (retry-path leniency) — do not
# "harmonize" them; they encode different policies.

# Pattern B — single-setup runner (test_framework.md §1 / release_reaper.sh):
# ONE process-spawning setup for the whole suite; bodies in the MAIN shell via
# `if fn; then`; suite trap reaps everything with `|| true` on every line; explicit
# per-body cleanup of the resources that body spawned (owners, fake chromes, lanes).

# Pattern C — fake chrome (must SERVE HTTP, not sleep):
#   parse --remote-debugging-port from argv → mkdir json/ → write version JSON →
#   `exec python3 -m http.server "$port" --bind 127.0.0.1` from that cwd.
# curl -sf http://127.0.0.1:PORT/json/version then returns 200 — satisfying
# pool_wait_cdp AND pool_find_free_port's live-endpoint checks.

# Pattern D — provisional lease fixture (the crashed-boot state):
# pool_lease_write LANE EPHEM_DIR PORT SESSION OWNER_PID OWNER_COMM OWNER_STARTTIME \
#                  CWD CHROME_PID CHROME_PGID CONNECTED
#   → port=0, chrome ids 0/0, connected=false  (system_context.md §3 provisional claim)

# Pattern E — R1 asserts the GUARD (FS-agnostic), R2 asserts the RECOVERY (e2e).
# R1 needs no chrome/owner (direct function call in a subshell); R2 needs all fixtures.
```

### Integration Points

```yaml
CODE:
  - lib/pool.sh pool_copy_master   — INSERT guard (~8 lines incl. comment) at the mkdir→cp seam
  - test/bootrace.sh               — NEW (~150-200 lines): runner + fixtures + R1/R2

DO NOT TOUCH:
  - lib/pool.sh pool_boot_lane / pool_wrapper_main / stuck-lane recovery (correct as-is; the guard makes them safe)
  - lib/pool.sh pool_chrome_launch / pool_wait_cdp / pool_daemon_connect (R2 consumes them via fakes)
  - the 4 existing test suites (validate.sh is run as a gate, not edited)
  - README.md / skill docs (crash-recovery nuance is swept by P1.M3.T2.S1 — Mode B)

DOWNSTREAM CONSUMERS (do not implement here):
  - P1.M1.T2.S1 extends test/bootrace.sh (FAKE_CHROME_DELAY + count knobs + R3/R4) — keep the
    fixture skeleton stable and the file structured for additive cases.
  - P1.M1.T2.S2's boot-lane lock relies on this guarded copy (a losing second boot's copy
    becomes a clean refresh).

CONFIG: none (no env vars, no defaults, no schema).
ROUTES/DATABASE: none.
```

## Validation Loop

> **AGENTS.md §1/§2**: no real Chrome, no real agent-browser, no operator state. All
> dynamic checks use fakes under `timeout` in a redirected temp tree.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
bash -n lib/pool.sh
shellcheck -s bash -S warning lib/pool.sh
bash -n test/bootrace.sh
shellcheck -s bash -S warning test/bootrace.sh
# Expected: zero output from all four; shellcheck exit 0 each.
# Baseline lib is clean at HEAD; the guard adds a `[[ -e ]]` if + rm/die — cannot introduce
# findings. If shellcheck fires, you edited beyond the seam — revert and redo.
```

### Level 2: Unit / Regression Tests (the TDD core)

```bash
# 2a. RED gate (run BEFORE applying Task 3, after Task 1+2):
bash test/bootrace.sh; echo "rc=$?"
# Expected (pre-fix): R1 FAIL (no top-level 'Local State' / junk survived) + R2 FAIL
#                    (master marker missing / nested dir), rc=1.
# Record this output — it is the TDD evidence required by the Success Definition.

# 2b. GREEN gate (after Task 3):
bash test/bootrace.sh; echo "rc=$?"
# Expected: "== r1_bug001_guard_fs_agnostic / PASS", "== r2_bug001_recovery_e2e / PASS",
#           "2 passed, 0 failed", rc=0.

# 2c. Existing-suite regression gate (guard must be purely additive):
bash test/validate.sh
# Expected: exits 0, same pass count as at HEAD (validate.sh exercises pool_copy_master
#           via its own hermetic setup).
```

### Level 3: Integration / Static Contract Checks

```bash
# 3a. Guard is at the right seam (between mkdir parent and the (a) reflink comment):
grep -n -A2 'cannot create parent dir' lib/pool.sh | grep -q 'BUG-001' \
  && echo "guard follows parent mkdir" || echo "FAIL: guard misplaced"
# Expected: "guard follows parent mkdir".

# 3b. Existing failure-branch rm is UNCHANGED (still `|| true`):
grep -c 'rm -rf -- "$target_dir" 2>/dev/null || true' lib/pool.sh   # Expected: 1

# 3c. The guard's die-path present exactly once:
grep -c 'cannot remove stale target dir' lib/pool.sh                # Expected: 1

# 3d. Singleton strip untouched:
grep -q 'rm -f -- "$target_dir"/Singleton\* || true' lib/pool.sh && echo "Singleton strip intact"

# 3e. Zero orphans after the suite:
pgrep -af 'fake-cdp|abpool-bootrace|user-data-dir=.*bootrace' || echo "zero orphans"
# Expected: "zero orphans".
```

### Level 4: Manual Guard Verification (optional, 5-second isolated micro-check)

```bash
# Direct proof the guard makes the function idempotent, on ANY fs (tmpfs /tmp is fine —
# the guard is asserted, not the reflink):
timeout 20 bash -c '
  set -euo pipefail
  T=$(mktemp -d); trap "rm -rf $T" EXIT
  mkdir -p "$T/master/Default" "$T/active/1"
  printf "x" >"$T/master/Local State"
  printf "junk" >"$T/active/1/crash-marker"
  export AGENT_CHROME_MASTER="$T/master" AGENT_CHROME_ALLOW_SLOW_COPY=1
  source lib/pool.sh; pool_config_init
  pool_copy_master "$T/active/1"
  [[ -f "$T/active/1/Local State" ]] && ! [[ -e "$T/active/1/crash-marker" ]] \
    && echo "GUARD OK (clean copy, junk gone)" || { echo "GUARD BROKEN"; exit 1; }
'
# Expected: "GUARD OK (clean copy, junk gone)".
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n` + `shellcheck -s bash -S warning` clean on `lib/pool.sh` AND `test/bootrace.sh`.
- [ ] Level 2a RED evidence recorded (R1+R2 failed pre-fix).
- [ ] Level 2b GREEN: bootrace.sh 2 passed, 0 failed, rc=0.
- [ ] Level 2c: `bash test/validate.sh` still green.
- [ ] Level 3e: zero orphan processes after the suite.

### Feature Validation

- [ ] Guard inserted at the exact seam with the BUG-001 comment block (crash-recovery semantics documented).
- [ ] "NEVER mkdir the target" comment note extended.
- [ ] R1 green: pre-existing junk dir → top-level `Local State` + no `<master-basename>/` nesting + junk gone (FS-agnostic).
- [ ] R2 green: provisional port=0 lease + remnant dir → driving command rc=0 → master's marker file at lane top level → no nesting.
- [ ] Die-path messages, findmnt diagnostics, Singleton* strip all untouched (Level 3b/3d).
- [ ] `pool_copy_master` rc contract unchanged (rc 0 or pool_die).

### Code Quality Validation

- [ ] TDD order followed (tests first, RED, then fix, then GREEN).
- [ ] Single-setup runner; per-body spawn+reap; every trap line `|| true`; `timeout` on all subprocesses.
- [ ] Fakes heredoc'd into `$T/bin/` (no repo-level fixture files); no real Chrome/agent-browser/operator state touched.
- [ ] Fake chrome serves HTTP `/json/version` (not a sleep — the pool probes with curl).
- [ ] No scope creep: no boot lock, no ensure_connected changes, no BUG-002/003/… work.
- [ ] Fixture skeleton kept stable for T2.S1's additive extension (delay/count knobs).

### Documentation & Deployment

- [ ] In-code BUG-001 comment block present (code-as-doc rides with the work — Mode A).
- [ ] No repo docs changed (README/skill sweep is P1.M3.T2.S1 — Mode B).
- [ ] No new env vars, config, or schema changes.

---

## Anti-Patterns to Avoid

- ❌ Don't use `|| true` on the guard's `rm -rf` — an un-removable stale dir must `pool_die` loudly (that's the reviewed design; contrast the failure-branch's deliberate `|| true`).
- ❌ Don't remove or "harmonize" the existing reflink-failure-branch `rm -rf … || true` — it serves the retry path; the new guard serves the pre-existing-target path. Different policies, both correct.
- ❌ Don't test only on tmpfs and call it done — tmpfs masks the silent path; R1 asserts the guard itself so it is red/green on ANY FS (that is the whole point of R1).
- ❌ Don't fake chrome with `sleep` — the pool probes `curl -sf …/json/version`; the fake must serve HTTP (python3 http.server over a `json/version` file).
- ❌ Don't hardcode the fake chrome's port — parse `--remote-debugging-port=` from argv (pool_find_free_port picks the lowest free).
- ❌ Don't call setup() per test (3rd call hangs a shared sandbox) — ONE suite setup, per-body resources.
- ❌ Don't run test bodies in `( … )` subshells — a failing body's cleanup trap handling differs; use main-shell `if fn; then` per the canonical runner.
- ❌ Don't leave the suite's EXIT trap reaping nothing — owners, fake-cdp http.servers, and bootrace-scoped chromes must all be swept (`|| true` on every trap line).
- ❌ Don't implement any BUG-002 piece here (boot lock, ensure_connected, sweep widening) — T2.S2/S3/S4 own them.
- ❌ Don't edit the 4 existing test suites — validate.sh is a gate, not an edit target.
- ❌ Don't trust the cited line numbers blindly — re-verify the seam with grep before editing (fix_design.md's own instruction).

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale: the guard is ~8 lines at a single seam with a byte-accurate oldText and code taken verbatim from the reviewed `fix_design.md §1`; it cannot introduce shellcheck findings (baseline clean, purely additive `if`). The test suite follows the project's own documented test contract (test_framework.md §1–§5) with the canonical single-setup runner, and both regression cases are specified assertion-by-assertion including the FS-agnostic trap (why tmpfs masks the bug and how R1 defeats that). The residual -1: R2's end-to-end path depends on the fake chrome + fake agent-browser satisfying `pool_wait_cdp` (curl probe) and `pool_daemon_connect` (rc-0 connect) exactly — if agent-browser 0.28's real CLI contract differs from the no-op fake in some unchecked way (e.g. the exec'd `open` needing specific output), the implementer may need to loosen the fake; the Level 2b failure output pinpoints it immediately, and the TDD RED gate (2a) ensures the tests are provably sensitive before the fix is trusted.