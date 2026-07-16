# PRP — P1.M1.T2.S1: Move `ss` from FAIL loop to optional block + update doctor docstring + add ss-missing test

> **Bugfix context**: This subtask fixes **Issue 2 (Minor)** from the QA report
> (`plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md` and
> `architecture/recon_issue2_doctor.md`). `pool_admin_doctor` hard-FAILs on a missing
> `ss`, but `ss` is genuinely optional (its runtime caller `pool_find_free_port` degrades
> silently to a curl-only probe) — directly contradicting the function's own severity-model
> docstring and the inline comment three lines above the loop. The repo is fully implemented
> (`lib/pool.sh` is 4569 LOC). This subtask runs **in parallel** with P1.M1.T1.S1 (Issue 1 —
> reaper anchoring); the two touch **disjoint functions** (`pool_admin_doctor` vs
> `pool_reap_orphan_dirs`) and **disjoint test bodies** (`selftest_doctor_*` vs
> `selftest_reap_orphan_dirs_*`), so there is no conflict.
>
> **LINE-NUMBER NOTE (post parallel-shift):** P1.M1.T1.S1 landed edits around
> `lib/pool.sh:2889` (the reaper) which shifted everything below it down ~8 lines. The
> line numbers in this PRP were verified against the CURRENT file. The authoritative edit
> sites are located by **content grep** (not line number) in Task 0; the exact current
> line numbers are: `[dependencies]` loop = **lib/pool.sh:4266**; notify-send block =
> **:4300–4303**; docstring `a.` bullet = **:4154–4158**; SEVERITY MODEL "(not counted)"
> line = **:4177**; OUTPUT "MISSING = FAIL" line = **:4184**; `[dependencies]` OUTPUT
> notify-send row = **:4186**; `[summary]` exit logic = **:4485–4497** (consumer, do NOT
> touch). Test template `selftest_doctor_flags_disconnected_lease` = **test/validate.sh:932**.
> If P1.M1.T1.S1 lands FURTHER edits after this PRP is written, re-locate via the content
> greps in Task 0 — the code text is stable, only line numbers drift.

---

## Goal

**Feature Goal**: Move `ss` out of the `pool_admin_doctor` required-dependency FAIL loop into a dedicated optional-dependency block (mirroring the existing `notify-send` pattern), so that a host lacking `ss` (e.g. a minimal container without `iproute2`) no longer produces a false `doctor` FAIL / exit-1 — matching `ss`'s own documented severity ("no FAIL, no WARN"). Make the doctor docstring's severity model internally consistent (it currently omits `ss` from the optional list while the inline comment claims it is non-counted). Add a hermetic, timeout-bounded self-test that stubs `command -v ss` to fail and asserts the `ss` line carries the `(optional …)` qualifier (not a bare `MISSING`).

**Deliverable**:
1. `lib/pool.sh` — the `[dependencies]` loop (`lib/pool.sh:4266` — content: `for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do`) changed to `for dep in flock setsid pgrep pkill cp curl jq findmnt; do` (drop the trailing ` ss`). **`findmnt` STAYS** in the loop (its absence surfaces indirectly as a btrfs FAIL — it is genuinely required).
2. `lib/pool.sh` — a new dedicated `ss` block added after the loop (right after the `notify-send` block at `lib/pool.sh:4300–4303` is the natural placement — both optionals grouped), using the `notify-send` pattern: OK branch = `printf` + `ok++`; MISSING branch = `printf` with `(optional; port-probe degrades to curl-only)` and **NO `fail++`**.
3. `lib/pool.sh` — the `pool_admin_doctor` docstring updated in 4 places so the severity model is internally consistent (line numbers current as of the parallel P1.M1.T1.S1 shift; re-locate via content grep if they drift again):
   - `lib/pool.sh:4177` `#   (not counted): notify-send MISSING (optional).` → add `; ss MISSING (optional, degrades to curl-only port probe).`
   - `lib/pool.sh:4184` OUTPUT line `#     <dep>           OK | MISSING            (MISSING = FAIL, except notify-send)` → `(MISSING = FAIL, except notify-send and ss)`
   - `lib/pool.sh:4154–4158` the `a.` bullet → add `ss` to the OPTIONAL list alongside `notify-send`.
   - `lib/pool.sh:4186` `[dependencies]` OUTPUT section → add an `ss` row mirroring the `notify-send` row.
4. `test/validate.sh` — a new `selftest_doctor_ss_optional_when_missing` function, added alongside `selftest_doctor_flags_disconnected_lease` (`test/validate.sh:932–961`). Hermetic, timeout-bounded subshell that stubs `command` so `command -v ss` returns 1, and asserts the `ss` line contains `optional`.
5. No consumer-site changes: `install.sh` runs `doctor` as its final step and will now correctly exit 0 on a host lacking only `ss`.

**Success Definition**:
- `ss` no longer appears in the `for dep in …` loop (`grep -n 'for dep in' lib/pool.sh` shows the loop WITHOUT `ss`).
- A dedicated `if command -v ss` block exists, with OK → `ok++` and MISSING → no `fail++` and the message `MISSING (optional; port-probe degrades to curl-only)`.
- With `command -v ss` stubbed to fail, `pool_admin_doctor` prints `ss` followed by `MISSING (optional` (containing the literal substring `optional`), and the `FAIL` count is **not** incremented by `ss` (verified: `FAIL=1` from the tmpfs-non-btrfs only, NOT `FAIL=2`).
- `findmnt` STAYS in the FAIL loop (`grep -n 'for dep in' lib/pool.sh` still contains `findmnt`).
- `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean (project gate).
- `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- `bash test/validate.sh` exits 0 with the new `selftest_doctor_ss_optional_when_missing` body PASS.
- The docstring's severity model, OUTPUT contract, and `a.` bullet all mention `ss` as optional (internally consistent).

## User Persona

**Target User**: Operators installing `agent-browser-pool` on minimal/containerized hosts that lack `iproute2` (and thus `ss`). Secondary: the install flow (`install.sh` runs `doctor` as its final step) and any operator running `agent-browser-pool doctor` to diagnose the pool.

**Use Case**: An operator installs the pool in a stripped container (no `ss`). Today `install.sh`'s final `doctor` step prints `ss MISSING`, increments `fail`, exits 1, and reports "Problems found." — falsely signaling a broken setup when the pool would actually work fine (port allocation falls back to the `curl`-only probe). After the fix, `doctor` reports `ss MISSING (optional; …)`, does NOT increment `fail`, and (on an otherwise-healthy host) exits 0 / "Healthy."

**User Journey**: Operator → `agent-browser-pool doctor` → `[dependencies]` section shows `ss   MISSING (optional; port-probe degrades to curl-only)` → `[summary]` shows `FAIL=0` (assuming no other real problems) → "Healthy." → operator trusts the install. No false alarm.

**Pain Points Addressed**:
- **False install failure** (most severe — PRD §2.17: "install runs `doctor`"): on `ss`-less hosts, `install.sh` falsely reports problems.
- **Docstring/code contradiction** (the root complaint of Issue 2): the inline comment at `lib/pool.sh:4255–4257` says `ss` is "no FAIL, no WARN" but the loop body does `fail=$((fail+1))`. The fix makes code match the (correct) comment.
- **Operator confusion**: a "MISSING" without context looks like a real gap; the `(optional; …)` qualifier tells the operator exactly what degrades and why it's fine.

## Why

- **Issue 2 (Minor)** from the QA report. The fix is **1 token removed from a loop + 1 new ~6-line block + 4 docstring line-edits + 1 test** — minimal blast radius. The only behavioral change is that `ss` no longer increments `fail`; every other dep (`flock setsid pgrep pkill cp curl jq findmnt` + chrome + binary) is untouched.
- **`ss` is genuinely non-blocking** (runtime evidence in `recon_issue2_doctor.md §4`): `pool_find_free_port` (`lib/pool.sh:1412–1416`) snapshots listeners with `listeners="$(ss -tlnH 2>/dev/null || true)"`. A missing `ss` → empty `listeners` → the per-port `grep ":$port "` never matches → the live `curl /json/version` probe is the real guard. Pool port allocation works without `ss`.
- **`notify-send` is the established pattern** (`lib/pool.sh:4292–4295`): a separate `if command -v` block, outside the shared loop, with OK → `ok++` and MISSING → `printf '… (optional)'` and NO `fail++`. Aligning `ss` to this pattern is consistent, not a new concept.
- **`findmnt` deliberately stays in the FAIL loop.** Its absence causes `pool_check_btrfs` to see an empty fstype and `pool_die` (treating it as non-btrfs). So `findmnt` IS blocking. Only `ss` is over-counted. (Explicitly called out in `recon_issue2_doctor.md` Risks.)
- **Closes a test blind spot.** `recon_issue2_doctor.md` Risks notes: "No test pins the current ss-as-FAIL behavior … no test catches a regression — consider adding one." This subtask adds that test.

## What

User-visible behavior: on a host lacking `ss`, `agent-browser-pool doctor` no longer reports a false problem. The `[dependencies]` section shows `ss   MISSING (optional; port-probe degrades to curl-only)` instead of a bare `ss   MISSING`, and the `[summary]` exit code is driven only by genuinely-blocking failures. Observable contract:

### Behavior change (loop - 1 token; + 1 block)

The `[dependencies]` loop currently (`lib/pool.sh:4258`):
```bash
for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
```
becomes:
```bash
for dep in flock setsid pgrep pkill cp curl jq findmnt; do
```
and a new block is added right after the `notify-send` block (`lib/pool.sh:4292–4295`):
```bash
# ss — OPTIONAL (pool_find_free_port lib/pool.sh:1412 degrades to a curl-only probe when
# absent via `|| true`). Absence is NOT a FAIL (and NOT a WARN) — port allocation still
# works via the live curl /json/version probe. (Issue #2: was wrongly in the FAIL loop.)
if command -v ss >/dev/null 2>&1; then
    printf '  %-22s OK\n' "ss"
    ok=$((ok+1))
else
    printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' "ss"
fi
```

### Success Criteria

- [ ] `grep -n 'for dep in flock' lib/pool.sh` shows the loop WITHOUT a trailing ` ss` (i.e. ends `… findmnt; do`).
- [ ] `grep -n 'findmnt' lib/pool.sh | grep 'for dep in'` still matches (findmnt STAYS in the loop).
- [ ] A dedicated `if command -v ss` block exists in `pool_admin_doctor`, placed after the `notify-send` block.
- [ ] The `ss` OK branch does `ok=$((ok+1))`; the MISSING branch does NOT do `fail=$((fail+1))` and prints `MISSING (optional; port-probe degrades to curl-only)`.
- [ ] With `command -v ss` stubbed to fail (via the `command()` override in a scoped subshell), `pool_admin_doctor`'s `ss` output line contains the literal substring `optional`.
- [ ] With `command -v ss` stubbed to fail, the `[summary]` `FAIL` count is NOT incremented by `ss`. Specifically: on a tmpfs temp tree (which yields exactly 1 unrelated btrfs FAIL), the summary shows `FAIL=1` (was `FAIL=2` before the fix — empirically reproduced this session).
- [ ] **Regression — all other deps unchanged:** with `ss` present (the default on this host), `flock/setsid/pgrep/pkill/cp/curl/jq/findmnt/chrome/notify-send` all still report `OK` and the loop still counts them.
- [ ] **Regression — `ss` present still counts as OK:** when `ss` IS present, the new block prints `ss   OK` and increments `ok` (so the total `OK` count on a healthy host is unchanged: it was 13 with `ss` in the loop, still 13 with `ss` in its own block — verified empirically this session).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck -s bash -S warning lib/pool.sh` clean.
- [ ] `bash -n test/validate.sh` clean; `shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] `bash test/validate.sh` exits 0 with the new `selftest_doctor_ss_optional_when_missing` body PASS.
- [ ] The docstring severity-model line (`:4169`), OUTPUT line (`:4176`), `a.` bullet (`:4145–4149`), and `[dependencies]` OUTPUT section (`:4178`) all mention `ss` as optional.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"** → Yes. This PRP pins the exact line numbers (verified against the current 4569-LOC file this session), quotes the current code at every edit site, gives the verified replacement code, reproduces the bug empirically (showing the exact `FAIL=2` → `FAIL=1` transition), validates the `command()` stub approach for the test, specifies the test framework's exact runner pattern (single-setup `selftest_*`, hermetic timeout-bounded subshell mirroring `selftest_doctor_flags_disconnected_lease`), and lists the precise validation commands. The implementer needs no prior exposure to `lib/pool.sh` beyond reading the quoted snippets.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/recon_issue2_doctor.md
  why: THE recon doc for this exact bug. Verbatim line numbers, the exact loop code, the
        exact notify-send reference pattern, the runtime evidence (pool_find_free_port
        degrades via || true), and the suggested fix shape (4 numbered steps). Authoritative.
  pattern: '§(3) gives the notify-send reference block (lib/pool.sh:4292-4299); §"Suggested
        fix shape" gives the exact loop edit + the exact new ss block + the 4 docstring edits.'
  gotcha: '§Risks: "findmnt deliberately stays FAIL per its own comment — the fix must NOT
        move findmnt." Only ss moves. Also: "No test pins the current ss-as-FAIL behavior"
        → this subtask ADDS the test (recon explicitly recommends it).'

- file: lib/pool.sh
  why: THE file being edited. Read lines 4138-4300 (the full pool_admin_doctor header +
        docstring + the [dependencies] section: loop at 4258, chrome check, notify-send at
        4300-4303) and lines 4485-4497 (the [summary] exit-code logic).
  pattern: 'Existing style — the notify-send block (4292-4295) is the EXACT pattern to copy
        for ss: a separate `if command -v <dep>` block, OK branch printf+ok++, MISSING
        branch printf with "(optional …)" and NO fail++. Docstring uses ALL-CAPS section
        markers (SEVERITY MODEL, OUTPUT, CONTRACT) with precise rc semantics.'
  gotcha: 'The loop is at lib/pool.sh:4258 (verified). The notify-send block is at 4292-4295
        (verified). The docstring lines: a. bullet 4145-4149, SEVERITY MODEL 4163-4172 (the
        "(not counted)" line is 4169), OUTPUT 4174-4186 (the "<dep> OK | MISSING" line is
        ~4176, the [dependencies] OUTPUT block is ~4178). ALL VERIFIED this session against
        the 4569-LOC file. Do NOT trust the QA report'"'"'s "~line" approximations; the
        recon doc line numbers are exact.'

- file: test/validate.sh
  why: 'The test framework. ADD selftest_doctor_ss_optional_when_missing alongside
        selftest_doctor_flags_disconnected_lease (validate.sh:932-961). The single-setup
        _run_selftest_suite (validate.sh:~890) auto-discovers any selftest_* function via
        `compgen -A function | grep "^selftest_" | sort`.'
  pattern: 'selftest_doctor_flags_disconnected_lease is the EXACT template: (1) create an
        outdir under $ABPOOL_TEST_ROOT, (2) write a body.sh heredoc that sources the lib,
        pool_config_init + pool_state_init, sets up any state, STUBS the relevant function
        (there: curl; here: command), runs pool_admin_doctor in `$(... || true)` (doctor
        returns rc 1 on FAIL>0 — tolerate it), greps the output for the invariant, exits
        non-zero on assertion failure, (3) run body.sh via `timeout 15 bash "$script"
        "$ABPOOL_REPO" "$outdir"` with AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT
        pointed at the outdir, (4) assert_eq "0" "$rc" "label (out: $out)".'
  gotcha: 'Do NOT use run_test/abpool_run_suite for this — that path calls setup() per test
        (spawns a sim-owner process) and AGENTS.md §4 forbids >1 process-spawning setup()
        call in a shared sandbox (the 3rd call hangs). The selftest_* prefix is auto-picked
        by the SINGLE-SETUP _run_selftest_suite. ALSO: the body runs in a SUBSHELL (via
        `bash "$script"`) so the command() stub is naturally scoped — it does NOT leak to
        the rest of the suite.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/architecture/system_context.md
  why: 'Confirms the host environment and the test-isolation constraints (AGENTS.md §1/§2:
        no real Chrome, timeout-bounded, isolated temp tree). The doctor selftest is a
        pure-function + hermetic-subshell test — no Chrome, no daemon.'
  pattern: 'the selftest_doctor_flags_disconnected_lease pattern is the approved hermetic
        shape: outdir under ABPOOL_TEST_ROOT, body.sh heredoc, timeout 15, scoped stubs.'
  gotcha: 'the temp tree is tmpfs (not btrfs) → doctor ALWAYS reports 1 btrfs FAIL in tests.
        This is UNRELATED to the ss check. The selftest must NOT assert fail==0; it asserts
        ONLY that the ss line carries "optional" (and optionally that ss does not add a 2nd
        FAIL). See Task 5 for the exact assertion strategy.'

- file: PRD.md
  why: '§2.12 (doctor: "reconcile leases vs live Chromes vs dirs; report leaks"), §2.16
        (verify all dependencies present at runtime), §2.17 (install runs doctor as final
        step). The bug is a §2.16/§2.17 false-positive: doctor reports a non-blocking dep
        as blocking, breaking the install on ss-less hosts.'
  pattern: '§2.16 lists the required deps; ss is NOT among the originally-enumerated
        required set (it was added later as "Issue #7" per the inline comment). The fix
        restores ss to optional status, matching §2.16'"'"'s intent.'
  gotcha: 'PRD §2.16 does NOT list ss as required. The original doctor author added ss to
        the FAIL loop (with a comment admitting it is non-blocking) — a self-contradiction.
        Issue 2 corrects this.'

# External authoritative docs (for the HOW — minimal; this is a small structural fix)
- url: https://www.gnu.org/software/bash/manual/html_node/Shell-Builtins.html
  why: 'the `command` builtin and `builtin command "$@"` — how to override `command` in a
        scoped function so `command -v ss` returns 1 while everything else passes through.
        This is the stub mechanism the test uses.'
  critical: 'ON THIS HOST (verified 2026-07-16): defining `command() { if [[ "${1:-}" ==
        "-v" && "${2:-}" == "ss" ]]; then return 1; fi; builtin command "$@"; }` in a
        subshell makes `command -v ss` return 1 AND `command -v flock` (etc.) still return
        0. doctor'"'"'s loop uses `command -v "$dep"` so the stub correctly simulates a
        missing ss while leaving all other deps detectable. The stub is scoped to the
        subshell (the body.sh run via `bash "$script"`) so it does NOT leak.'
  section: search page for `command` then "command [-pVv]".

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: 'double-quote expansions. Universal. The new ss block follows the existing notify-send
        block which is already SC2086-clean.'
  critical: 'no shellcheck concern is introduced by copying the notify-send pattern verbatim
        with the dep name changed to ss.'

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/P1M1T1S1/PRP.md
  why: 'P1.M1.T1.S1 (Issue 1 — reaper anchoring) runs IN PARALLEL. It edits
        pool_reap_orphan_dirs (lib/pool.sh:~2895-2902) + its inline comment, and ADDS
        selftest_reap_orphan_dirs_kills_only_target_lane to validate.sh. THIS subtask edits
        pool_admin_doctor (lib/pool.sh:4258 + 4292-4295 + docstring 4145-4178) and ADDS
        selftest_doctor_ss_optional_when_missing. Disjoint functions + disjoint test bodies
        → no merge conflict.'
  pattern: 'P1.M1.T1.S1 also adds a selftest_* body (selftest_reap_orphan_dirs_*) to
        validate.sh. THIS subtask adds selftest_doctor_ss_optional_when_missing. Both APPEND
        to the selftest_* block. Place this body alongside the other selftest_doctor_* body
        (selftest_doctor_flags_disconnected_lease, validate.sh:852-881) for cohesion.'
  gotcha: 'Both subtasks APPEND selftest bodies to validate.sh. To avoid a textual merge
        conflict, place the new selftest_doctor_ss_optional_when_missing IMMEDIATELY AFTER
        selftest_doctor_flags_disconnected_lease (validate.sh:~882, before the
        `# --- source-vs-execute gate` comment at ~884). The _run_selftest_suite
        auto-discovers ALL selftest_* functions via compgen, so order does not affect
        discovery — only textual merge cleanliness.'

- file: plan/003_afc2f15931ab/bugfix/001_262079d529b6/TEST_RESULTS.md
  why: 'the QA report that identified Issue 2. Confirms the bug (ss in the FAIL loop
        contradicts its own comment), the location (~lib/pool.sh:4258), the repro (ss-less
        host → doctor exit 1), and the suggested fix (remove ss from loop, report separately
        like notify-send).'
  pattern: 'TEST_RESULTS §"Minor Issues" Issue 2 — the "Steps to Reproduce" (host lacking ss
        → doctor FAIL=1 / exit 1) is the exact scenario the new selftest encodes (via the
        command() stub instead of a real ss-less host, for hermeticity).'
  gotcha: 'TEST_RESULTS also lists Issues 1 (reaper) and 3 (ensure_connected) — those are OUT
        OF SCOPE (P1.M1.T1.S1 does 1; P1.M1.T3 does 3). Stay in scope: Issue 2 only.'
```

### Current Codebase tree (relevant slice)

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh                   # 4569 LOC — pool_admin_doctor at 4231-4488
│                                 #   [dependencies] loop at 4258 (drop trailing ' ss')
│                                 #   notify-send block at 4292-4295 (MODEL for the new ss block)
│                                 #   docstring at 4138-4230 (4 lines to edit: 4145-4149, 4169, 4176, 4178)
│                                 #   [summary] exit logic at 4485-4497 (CONSUMER — do NOT edit)
├── test/
│   └── validate.sh               # 926 LOC — selftest_doctor_flags_disconnected_lease at 932-961 (TEMPLATE)
│                                 #   _run_selftest_suite at ~890 (auto-discovers selftest_*)
└── plan/003_afc2f15931ab/bugfix/001_262079d529b6/
    ├── architecture/recon_issue2_doctor.md   # THE recon doc (exact code + line numbers + fix shape)
    ├── architecture/system_context.md        # host env + test isolation constraints
    ├── TEST_RESULTS.md                       # QA report (Issue 2 confirmed)
    ├── P1M1T1S1/PRP.md                       # parallel subtask (Issue 1 — disjoint function)
    └── P1M1T2S1/                             # THIS subtask
        └── PRP.md                            # THIS FILE
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. All edits are IN-PLACE in 2 existing files:
#   lib/pool.sh       — [dependencies] loop (-1 token 'ss') + new ss block (+~7 lines) + 4 docstring line-edits
#   test/validate.sh  — ADD selftest_doctor_ss_optional_when_missing body (~30 lines)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (empirically verified this session, 2026-07-16): the bug reproduces exactly as
# described. With command -v ss stubbed to fail, doctor prints "ss   MISSING" and FAIL=2
# (ss + the tmpfs-non-btrfs). After the fix it must print "ss   MISSING (optional; …)" and
# FAIL=1 (tmpfs-non-btrfs only). The baseline (ss present) is OK=13 WARN=0 FAIL=1. The fix
# must NOT change the OK count when ss IS present (it stays 13 — ss moves from the loop's
# ok++ to the new block's ok++, net zero).
# VERIFIED REPRO COMMAND (run BEFORE and AFTER the fix to confirm the transition):
#   tmp=$(mktemp -d)
#   AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
#   timeout 15 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
#     command() { if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi; builtin command "$@"; }
#     pool_admin_doctor 2>/dev/null | grep -E "ss |summary|FAIL" || true'
#   rm -rf "$tmp"
# BEFORE fix: "ss   MISSING" + "FAIL=2". AFTER fix: "ss   MISSING (optional; …)" + "FAIL=1".

# CRITICAL: findmnt STAYS in the FAIL loop. Its absence causes pool_check_btrfs to see an
# empty fstype and pool_die (non-btrfs). So findmnt IS blocking. Only ss moves. The fix
# touches ONLY the trailing ' ss' in the `for dep in` line — do NOT remove findmnt.
# Verify: grep -n 'for dep in flock' lib/pool.sh must still contain 'findmnt'.

# CRITICAL (the command() stub mechanism for the test): doctor's loop uses
# `command -v "$dep"`. To simulate a missing ss hermetically (without a real ss-less host),
# override the command builtin in the body.sh subshell:
#     command() {
#         if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi
#         builtin command "$@"
#     }
# VERIFIED this session: this makes `command -v ss` return 1 while `command -v flock` etc.
# still return 0. The stub is scoped to the subshell (body.sh run via `bash "$script"`) so
# it does NOT leak to the rest of the validate.sh suite. Do NOT try `ss() { return 127; }`
# (that stubs the ss COMMAND, not `command -v ss` — doctor would still find ss on PATH and
# print OK). Do NOT try removing ss from PATH (fragile, host-dependent). The command()
# override is the correct, hermetic mechanism.

# CRITICAL (doctor returns rc 1 on FAIL>0): the temp tree is tmpfs (not btrfs) → doctor
# ALWAYS reports 1 btrfs FAIL in tests. So `pool_admin_doctor` in the test body returns 1.
# The test body MUST run it as `out="$(pool_admin_doctor 2>/dev/null || true)"` (the `||
# true` tolerates the rc 1 so set -e does not abort the body before the assertion). This
# mirrors selftest_doctor_flags_disconnected_lease exactly. The assertion is on the OUTPUT
# (the ss line contains "optional"), NOT on the exit code.

# GOTCHA (the assertion must be robust to the unrelated tmpfs FAIL): assert ONLY that the
# ss output line contains the literal "optional". Do NOT assert fail==0 (the tmpfs FAIL
# makes it 1). Optionally ALSO assert that the [summary] FAIL line is "FAIL=1" (proving ss
# did not add a 2nd FAIL) — but this is a stronger assertion that couples to the tmpfs
# environment; the contract says "Keep it simple: assert the ss line contains 'optional'".
# The PRP's Task 5 includes BOTH: the primary assertion (ss line contains "optional") and
# a secondary belt-and-suspenders assertion (FAIL count not incremented by ss — verified
# via "FAIL=1" not "FAIL=2"). The implementer may keep just the primary if the secondary
# proves flaky, but both passed empirically this session.

# GOTCHA (placement of the new ss block): place it right AFTER the notify-send block
# (lib/pool.sh:4300-4303), BEFORE the [binary] section header (lib/pool.sh:4312). This
# groups both optional deps together in the [dependencies] output, which reads naturally:
#   ... findmnt OK
#   chrome (...) OK
#   notify-send   OK | MISSING (optional)
#   ss            OK | MISSING (optional; port-probe degrades to curl-only)
# Do NOT place it before notify-send (breaks the existing grouping) or inside the for loop
# (it must be a separate if-block, like notify-send).

# GOTCHA (the docstring edits must keep the file internally consistent): the 4 edit sites
# are: (1) the a. bullet at 4145-4149 (add ss to the OPTIONAL list), (2) the SEVERITY MODEL
# "(not counted)" line at 4169 (add ss), (3) the OUTPUT "MISSING = FAIL, except notify-send"
# line at ~4176 (add "and ss"), (4) the [dependencies] OUTPUT section at ~4178 (add an ss
# row). All 4 must move in lockstep — editing only the code and not the docstring leaves
# the self-contradiction that Issue 2 complains about.

# GOTCHA (set -e): the new ss block uses `if command -v ss >/dev/null 2>&1; then …; else …; fi`
# — the `if` makes command -v's non-zero exit a clean branch (NOT a set -e abort), identical
# to the notify-send block. ok++/fail are $(( )) EXPANSIONS (always set -e safe). No bare
# (( )) statements.

# GOTCHA (scope): this fix is ISSUE 2 ONLY. Do NOT fix Issue 1 (reaper — P1.M1.T1.S1) or
# Issue 3 (ensure_connected — P1.M1.T3). Do NOT move findmnt. Do NOT change the chrome
# check, the [binary]/[filesystem]/[master]/[lanes]/[dirs] sections, or the [summary]
# exit logic. One token out of the loop + one new block + four docstring lines + one test.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. The only "structure" is `pool_admin_doctor`'s `[dependencies]` section composition, which gains a sibling optional-dep block alongside `notify-send`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the current function and reproduce the bug BEFORE fixing
  - RUN: read lib/pool.sh around the `[dependencies]` loop — locate it by CONTENT, not line
        number (the parallel P1.M1.T1.S1 reaper fix shifted line numbers ~8): 
        grep -n 'for dep in flock' lib/pool.sh   # → currently ~4266
        grep -n 'notify-send — OPTIONAL' lib/pool.sh  # → currently ~4300 (the MODEL block)
  - EXPECT: the loop (content: `for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do`),
        the chrome check, and the notify-send block (content: `# notify-send — OPTIONAL …`).
  - RUN (empirical baseline — confirm the bug BEFORE fixing):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
        timeout 15 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
          command() { if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi; builtin command "$@"; }
          pool_admin_doctor 2>/dev/null | grep -E "ss |summary|FAIL" || true'
    - EXPECT (BEFORE fix): a line "  ss   MISSING" (bare, no "optional") AND "  FAIL=2".
      (After fix: "  ss   MISSING (optional; …)" AND "  FAIL=1".)
  - RUN (baseline with ss present — confirm OK count):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
          pool_admin_doctor 2>/dev/null | grep -E "summary"' || true
    - EXPECT: "OK=13  WARN=0  FAIL=1" (the 13 includes ss; after the fix ss still counts → still 13).

Task 1: EDIT lib/pool.sh — remove ss from the [dependencies] FAIL loop
  - LOCATE by content: grep -n 'for dep in flock' lib/pool.sh  (currently ~line 4266)
  - FIND (the exact current line — verify with Task 0's grep):
        for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
  - REPLACE WITH:
        for dep in flock setsid pgrep pkill cp curl jq findmnt; do
  - WHY: ss is optional (pool_find_free_port degrades via || true). Only the trailing ` ss`
        is removed. findmnt STAYS (its absence → btrfs FAIL → genuinely blocking).
  - GOTCHA: this is a 1-token deletion. Do NOT touch anything else on the line or the loop body.

Task 2: EDIT lib/pool.sh — add the dedicated ss block after notify-send
  - LOCATE by content: grep -n 'notify-send — OPTIONAL' lib/pool.sh  (currently ~line 4300)
  - FIND (the notify-send block — the MODEL; currently ~4300-4303):
        # notify-send — OPTIONAL (PRD §2.16; _pool_alert guards it lib/pool.sh:2824).
        # Absence is NOT a FAIL (and NOT a WARN) — it is genuinely fine to lack it.
        if command -v notify-send >/dev/null 2>&1; then
            printf '  %-22s OK\n' "notify-send"
            ok=$((ok+1))
        else
            printf '  %-22s MISSING (optional)\n' "notify-send"
        fi
  - INSERT IMMEDIATELY AFTER that block (and BEFORE the `# ===… [binary] …` section header
        at line 4312) the new ss block:
        # ss — OPTIONAL (pool_find_free_port lib/pool.sh:1412 degrades to a curl-only probe
        # when absent via `|| true`). Absence is NOT a FAIL (and NOT a WARN) — port allocation
        # still works via the live curl /json/version probe. (Issue #2: was wrongly in the
        # FAIL loop, contradicting the comment above it.)
        if command -v ss >/dev/null 2>&1; then
            printf '  %-22s OK\n' "ss"
            ok=$((ok+1))
        else
            printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' "ss"
        fi
  - WHY: mirrors notify-send exactly. OK → ok++; MISSING → printf with "(optional; …)" and
        NO fail++. The %-22s format matches the loop's column width so the output stays aligned.
  - GOTCHA: the `command -v ss` is inside `if` (set -e safe — a bare call would abort). The
        ok++/fail are $(( )) expansions (always safe). No bare (( )).
  - GOTCHA: do NOT add `fail=$((fail+1))` in the else branch — that is the whole point of the
        fix. The else branch ONLY prints.

Task 3: EDIT lib/pool.sh — update the pool_admin_doctor docstring (4 lines, lockstep)
  - EDIT 3a — the `a.` bullet (lines 4145-4149). FIND:
        #   a. DEPS        — command -v each required dep {flock, setsid, pgrep, pkill, cp,
        #                    curl, jq} + the Chrome binary ($POOL_CHROME_BIN, name-or-path) +
        #                    the OPTIONAL notify-send. Required MISSING → FAIL; notify-send
        #                    MISSING → "(optional)", NOT counted.
    REPLACE WITH:
        #   a. DEPS        — command -v each required dep {flock, setsid, pgrep, pkill, cp,
        #                    curl, jq, findmnt} + the Chrome binary ($POOL_CHROME_BIN, name-or-path)
        #                    + the OPTIONAL notify-send AND ss. Required MISSING → FAIL;
        #                    notify-send/ss MISSING → "(optional)", NOT counted.
    (Added findmnt to the required set for accuracy + added "AND ss" to the OPTIONAL list.)
  - EDIT 3b — the SEVERITY MODEL "(not counted)" line (line 4169). FIND:
        #   (not counted): notify-send MISSING (optional).
    REPLACE WITH:
        #   (not counted): notify-send MISSING (optional); ss MISSING (optional, degrades to curl-only port probe).
  - EDIT 3c — the OUTPUT "MISSING = FAIL" line (~line 4176). FIND:
        #     <dep>           OK | MISSING            (MISSING = FAIL, except notify-send)
    REPLACE WITH:
        #     <dep>           OK | MISSING            (MISSING = FAIL, except notify-send and ss)
  - EDIT 3d — the [dependencies] OUTPUT section (~line 4178). FIND:
        #     notify-send     OK | MISSING (optional)
    REPLACE WITH:
        #     notify-send     OK | MISSING (optional)
        #     ss              OK | MISSING (optional; port-probe degrades to curl-only)
    (Add the ss row directly after the notify-send row.)
  - WHY: the docstring must be internally consistent with the code. Issue 2's root complaint
        is the contradiction between the inline comment ("no FAIL, no WARN") and the loop
        body (fail++). Editing only the code and not the docstring leaves the docstring's
        severity model (which omits ss from optional) still self-contradictory.
  - GOTCHA: all 4 edits must move in lockstep. Verify with the grep in Task 6.

Task 4: ADD test/validate.sh — selftest_doctor_ss_optional_when_missing body
  - ADD a new function named `selftest_doctor_ss_optional_when_missing` (the
        _run_selftest_suite at validate.sh:~890 auto-discovers any selftest_* function —
        NO registration needed).
  - PLACE: IMMEDIATELY AFTER selftest_doctor_flags_disconnected_lease (validate.sh:~882,
        before the `# --- source-vs-execute gate` comment at ~884). This groups the two
        doctor selftests together and avoids merge conflicts with the parallel
        P1.M1.T1.S1 PRP (which adds selftest_reap_orphan_dirs_* elsewhere).
  - FOLLOW pattern: selftest_doctor_flags_disconnected_lease (validate.sh:932-961) — the
        EXACT template: outdir under $ABPOOL_TEST_ROOT, body.sh heredoc, source the lib,
        pool_config_init + pool_state_init, stub the relevant builtin, run doctor in
        `$(... || true)`, grep the output, run via `timeout 15 bash "$script" "$ABPOOL_REPO"
        "$outdir"` with AGENT_BROWSER_POOL_STATE + AGENT_CHROME_EPHEMERAL_ROOT pointed at
        the outdir, assert_eq "0" "$rc" "label (out: $out)".
  - NAMING: selftest_doctor_ss_optional_when_missing.
  - REFERENCE IMPLEMENTATION (verified: the command() stub works hermetically; the body
        runs in a subshell so the stub is scoped; doctor returns rc 1 on the tmpfs FAIL so
        `|| true` is required):
      ----------------------------------------------------------------
      # Issue #2: ss is OPTIONAL (pool_find_free_port degrades to curl-only when absent).
      # doctor must NOT count a missing ss as a FAIL — the ss line must carry "(optional …)".
      # Hermetic: stub `command -v ss` to fail in the body subshell (scoped, no leak); the
      # tmpfs temp tree yields 1 unrelated btrfs FAIL, so assert the ss LINE (not fail==0).
      selftest_doctor_ss_optional_when_missing() {
          local outdir script rc out
          outdir="$ABPOOL_TEST_ROOT/doctor-ss-opt"
          mkdir -p -- "$outdir/active"
          script="$outdir/body.sh"
          cat >"$script" <<'EOF'
      set -euo pipefail
      source "$1/lib/pool.sh"
      pool_config_init
      pool_state_init
      # Stub `command` so `command -v ss` returns 1 (ss "missing") while every other
      # `command -v <dep>` passes through to the real builtin. Scoped to this subshell.
      command() {
          if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then
              return 1
          fi
          builtin command "$@"
      }
      # doctor returns rc 1 when FAIL>0 (the tmpfs temp tree shows a non-btrfs FAIL, which
      # is UNRELATED to the ss check) -> tolerate with `|| true` so set -e does not abort.
      out="$(pool_admin_doctor 2>/dev/null || true)"
      # PRIMARY invariant: the ss line carries "(optional" (not a bare MISSING).
      printf '%s\n' "$out" | grep -qE 'ss +MISSING \(optional' || exit 1
      # SECONDARY belt-and-suspenders: ss did NOT add a FAIL. The tmpfs tree yields exactly
      # 1 btrfs FAIL; if ss were still counted, FAIL would be 2. Assert FAIL=1.
      printf '%s\n' "$out" | grep -qE 'FAIL=1\b' || exit 1
      EOF
          rc=0
          out="$(AGENT_BROWSER_POOL_STATE="$outdir/state" \
                AGENT_CHROME_EPHEMERAL_ROOT="$outdir/active" \
                timeout 15 bash "$script" "$ABPOOL_REPO" 2>&1)" || rc=$?
          assert_eq "0" "$rc" "doctor [dependencies]: missing ss is optional, not FAIL (out: $out)" || return 1
      }
      ----------------------------------------------------------------
  - WHY the command() stub (not PATH manipulation / not `ss() { return 127; }`): doctor's
        loop uses `command -v "$dep"`. Stubbing the ss COMMAND (`ss() {...}`) does NOT
        affect `command -v ss` (which checks PATH) → doctor would still print "ss OK".
        Removing ss from PATH is fragile and host-dependent. The command() override is the
        only hermetic mechanism that makes `command -v ss` return 1 while leaving all other
        deps detectable. VERIFIED this session.
  - WHY `|| true` on the doctor call: the tmpfs temp tree (under ABPOOL_TEST_ROOT, which is
        under /tmp → tmpfs) is NOT btrfs → doctor's [filesystem] section reports 1 FAIL →
        doctor returns rc 1. Without `|| true`, set -e aborts the body before the assertion.
        This mirrors selftest_doctor_flags_disconnected_lease exactly.
  - WHY assert FAIL=1 (not fail==0): the tmpfs FAIL is unrelated to ss; fail==0 is
        unachievable on a tmpfs tree. The invariant is "ss did not add a FAIL" — which
        manifests as FAIL=1 (tmpfs only) rather than FAIL=2 (tmpfs + ss). If the secondary
        assertion proves flaky on some CI host (e.g. a btrfs /tmp), the PRIMARY assertion
        (ss line contains "optional") is sufficient and robust; keep both but the primary
        is the load-bearing one.
  - GOTCHA: the `|| return 1` after assert_eq makes fail-fast explicit (assert_eq returns 1
        on mismatch → the body ends → recorded FAIL → suite continues).
  - GOTCHA: do NOT spawn Chrome or a sim-owner — this is a pure-function + hermetic-subshell
        test. The body runs in its own `bash "$script"` subshell with its own scoped stubs.
  - GOTCHA: the heredoc uses `<<'EOF'` (quoted) so $1, $2, $(...) are NOT expanded by the
        outer shell — they expand when body.sh runs. This matches
        selftest_doctor_flags_disconnected_lease.

Task 5: VERIFY — wait, Task 5 is the verification gauntlet (renumbered below as the Validation Loop). Run it BEFORE claiming done.
  - (See the Validation Loop section — run Level 1 + Level 2 + Level 3 in order.)
```

### Implementation Patterns & Key Details

```bash
# Pattern A — the single loop edit (drop the trailing ' ss'):
# BEFORE (lib/pool.sh:4258):
#     for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
# AFTER:
#     for dep in flock setsid pgrep pkill cp curl jq findmnt; do
# Only the trailing ' ss' is removed. findmnt STAYS.

# Pattern B — the new ss block (copy of the notify-send pattern, dep name + message changed):
#     # ss — OPTIONAL (pool_find_free_port lib/pool.sh:1412 degrades to a curl-only probe
#     # when absent via `|| true`). Absence is NOT a FAIL (and NOT a WARN) — port allocation
#     # still works via the live curl /json/version probe. (Issue #2: was wrongly in the
#     # FAIL loop, contradicting the comment above it.)
#     if command -v ss >/dev/null 2>&1; then
#         printf '  %-22s OK\n' "ss"
#         ok=$((ok+1))
#     else
#         printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' "ss"
#     fi
# WHY this is the right pattern: it is byte-identical in structure to the notify-send block
# (lib/pool.sh:4292-4295) — the established optional-dep idiom in this very function.

# Pattern C — the command() stub for the test (hermetic ss-missing simulation):
#     command() {
#         if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi
#         builtin command "$@"
#     }
# WHY: doctor's loop calls `command -v "$dep"`. Stubbing the ss command does NOT affect
# `command -v ss`. PATH manipulation is fragile. The command() override is the only hermetic
# way to make `command -v ss` return 1 while passing every other `command -v` through.
# Scoped to the body.sh subshell → no leak.

# Pattern D — the test body shape (hermetic subshell, mirrors selftest_doctor_flags_disconnected_lease):
#   outdir under $ABPOOL_TEST_ROOT; body.sh heredoc (<<'EOF'); source lib; config+state init;
#   stub; `out="$(pool_admin_doctor 2>/dev/null || true)"`; grep the invariant; run via
#   `timeout 15 bash "$script" "$ABPOOL_REPO"` with env pointed at outdir; assert_eq "0" "$rc".
```

### Integration Points

```yaml
CODE (2 in-place edits, 1 insertion, 1 addition — no new files):
  - lib/pool.sh:4258         [dependencies] loop: drop trailing ' ss' (findmnt STAYS)
  - lib/pool.sh:+7 (after 4295) new ss optional-dep block (mirrors notify-send at 4292-4295)
  - lib/pool.sh:4145-4149    docstring `a.` bullet (add ss to OPTIONAL, add findmnt to required)
  - lib/pool.sh:4169         docstring SEVERITY MODEL "(not counted)" line (add ss)
  - lib/pool.sh:~4176        docstring OUTPUT "MISSING = FAIL, except …" line (add "and ss")
  - lib/pool.sh:~4178        docstring [dependencies] OUTPUT section (add ss row)
  - test/validate.sh:+1      1 new selftest_doctor_ss_optional_when_missing body (ADD, ~32 lines)

CONSUMER (DO NOT TOUCH — already correct):
  - lib/pool.sh:4485-4497    [summary] exit logic: `if (( fail > 0 )); then return 1; fi`.
                             Benefits automatically — with ss no longer incrementing fail,
                             a host missing only ss no longer trips the exit-1.
  - install.sh               runs `doctor` as its final step → now correctly exits 0 on ss-less hosts.

PARALLEL SUBTASK (P1.M1.T1.S1 — disjoint, no conflict):
  - edits pool_reap_orphan_dirs (lib/pool.sh:~2895-2902) + inline comment, adds
    selftest_reap_orphan_dirs_kills_only_target_lane.
  - THIS subtask edits pool_admin_doctor (lib/pool.sh:4258 + 4292-4295 + docstring) + adds
    selftest_doctor_ss_optional_when_missing. Disjoint functions + disjoint test bodies.

CONFIG: none. No env vars. No defaults. No paths.
ROUTES: none.
DATABASE: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after EACH edit — fix before proceeding.
bash -n lib/pool.sh                 # parse check. MUST be clean (no output).
shellcheck -s bash -S warning lib/pool.sh   # MUST report zero issues (project gate; ShellCheck 0.11.0).
bash -n test/validate.sh            # parse check the test file after adding the body.
shellcheck -s bash -S warning test/validate.sh   # MUST be clean.
# Expected: zero output from all four.
# NOTE: the project uses `shellcheck -s bash -S warning` (the QA report confirmed this is the
#       project's gate). Do NOT use a stricter -S info/style threshold — the existing codebase
#       was validated at -S warning and may have style-level annotations by design.
```

### Level 2: Unit Tests (Component Validation)

```bash
# 2a. The Issue 2 fix in isolation — ss-missing no longer increments FAIL (the motivating bug):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
timeout 15 bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
  command() { if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi; builtin command "$@"; }
  out="$(pool_admin_doctor 2>/dev/null || true)";
  printf "%s\n" "$out" | grep -qE "ss +MISSING \(optional" && echo "ss line OK" || { echo "FAIL: ss line missing optional"; exit 1; };
  printf "%s\n" "$out" | grep -qE "FAIL=1\b" && echo "FAIL count OK (1, not 2)" || { echo "FAIL: FAIL count is 2 (ss still counted)"; exit 1; }'
# Expected: "ss line OK" AND "FAIL count OK (1, not 2)"   (BEFORE the fix: ss line had no "optional" AND FAIL=2.)

# 2b. The test framework self-test suite (now includes the new doctor body):
bash test/validate.sh
# Expected: prints "== selftest_doctor_ss_optional_when_missing / PASS" and a final
#           "N passed, 0 failed" line; exits 0.
# If ANY selftest fails, the suite exits non-zero — debug root cause, do not proceed.

# 2c. Regression — ss PRESENT still counts as OK (the OK total is unchanged):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
  pool_admin_doctor 2>/dev/null | grep -E "^  (flock|setsid|pgrep|pkill|cp|curl|jq|findmnt|ss|notify-send) " | sort'
# Expected: 10 lines (the 8 loop deps + ss + notify-send), each ending "OK" on this host.
#           (Confirms ss still appears in the output via its own block, and the other deps are unaffected.)

# 2d. Regression — findmnt STAYS in the FAIL loop (do NOT move it):
grep -n 'for dep in flock' lib/pool.sh
# Expected: one line ending "... findmnt; do" (NOT "... findmnt ss; do", and NOT missing findmnt).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Verify the [summary] exit logic is BYTE-UNCHANGED:
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -E 'fail > 0|Problems found|Healthy|return [01]'
# Expected: NO output (the [summary] block at 4485-4497 is untouched). If you see a summary-block
#           diff, STOP — you over-edited; revert that hunk.

# 3b. Verify the full lib/pool.sh diff is minimal + scoped to pool_admin_doctor:
git diff --stat -- lib/pool.sh
# Expected: 1 file changed, ~10-14 insertions, ~5-8 deletions (the loop -1 token, the new ss
#           block +~7 lines, the 4 docstring line-edits).
git diff -- lib/pool.sh | grep -E '^[+-]' | grep -vE '^[+-]{3}'
# Expected: ONLY hunks within pool_admin_doctor (lines ~4145-4178 docstring + ~4258 loop + ~4295 new block).
#           NO hunks in pool_reap_orphan_dirs, pool_find_free_port, pool_check_btrfs, etc.

# 3c. Verify the test body was added (and named selftest_*):
grep -n 'selftest_doctor_ss_optional_when_missing' test/validate.sh
# Expected: the function definition line + (optionally) the PASS line from a validate.sh run.

# 3d. Full repo smoke (no Chrome launched — pure sourcing + doctor against a tmp tree):
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init;
         pool_admin_doctor >/dev/null 2>&1 || true; echo SOURCED_OK'
# Expected: SOURCED_OK
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The motivating scenario (Issue 2 from TEST_RESULTS.md): a host lacking only ss should
#     NOT trip a doctor FAIL. Simulate via the command() stub (hermetic — no need for a real
#     ss-less host). Assert: doctor's [summary] FAIL count excludes ss.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  command() { if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then return 1; fi; builtin command "$@"; }
  out="$(pool_admin_doctor 2>/dev/null || true)"
  # The ss line must explain the degradation:
  echo "$out" | grep -E "ss +MISSING" | grep -q "optional" \
    && echo "ss reported as OPTIONAL (correct — Issue 2 fixed)" \
    || { echo "ss reported as bare MISSING (BUG NOT FIXED)"; exit 1; }
  # And the FAIL count must not include ss (tmpfs non-btrfs is the only FAIL → FAIL=1):
  echo "$out" | grep -E "FAIL=" | grep -q "FAIL=1" \
    && echo "ss did NOT increment FAIL (correct)" \
    || { echo "ss incremented FAIL (BUG NOT FIXED)"; exit 1; }
'
# Expected: "ss reported as OPTIONAL (correct — Issue 2 fixed)" AND "ss did NOT increment FAIL (correct)"

# 4b. Confirm ss IS present on this host (so the default path — ss OK + ok++ — is also exercised):
command -v ss && echo "ss present on host (default path: ss OK, ok++)" || echo "ss absent (the bug scenario)"
# Expected: "/usr/bin/ss" + "ss present on host …" (this host has iproute2 7.1.0 — verified).

# 4c. Confirm findmnt STAYS required (the fix must NOT move it). Simulate findmnt missing →
#     doctor MUST still count it as FAIL:
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" AGENT_CHROME_EPHEMERAL_ROOT="$tmp/active" \
timeout 15 bash -c '
  set -euo pipefail
  source lib/pool.sh
  pool_config_init
  pool_state_init
  command() { if [[ "${1:-}" == "-v" && "${2:-}" == "findmnt" ]]; then return 1; fi; builtin command "$@"; }
  out="$(pool_admin_doctor 2>/dev/null || true)"
  echo "$out" | grep -E "findmnt" | grep -q MISSING \
    && echo "findmnt MISSING still counted (correct — it stays required)" \
    || { echo "findmnt not reported MISSING — regression"; exit 1; }
'
# Expected: "findmnt MISSING still counted (correct — it stays required)"

# (No Chrome, no daemon, no concurrency validation applies to this pure-function + docs fix.
#  Issues 1 (reaper) and 3 (ensure_connected) are OUT OF SCOPE — P1.M1.T1.S1 / P1.M1.T3.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck -s bash -S warning lib/pool.sh` clean (zero warnings).
- [ ] `bash -n test/validate.sh` clean.
- [ ] `shellcheck -s bash -S warning test/validate.sh` clean.
- [ ] Level 2 snippet 2a passes (ss-missing → line has "optional" + FAIL=1 not 2).
- [ ] Level 2 snippet 2b passes (`bash test/validate.sh` exits 0, new body PASS).
- [ ] Level 2 snippet 2c passes (ss present → ss OK; 10 dep lines on this host).
- [ ] Level 2 snippet 2d passes (findmnt STAYS in the loop).

### Feature Validation

- [ ] `ss` removed from the `for dep in …` loop (loop ends `… findmnt; do`).
- [ ] `findmnt` STILL in the loop (not moved).
- [ ] Dedicated `if command -v ss` block added after the notify-send block.
- [ ] `ss` OK branch does `ok++`; MISSING branch does NOT do `fail++` and prints `(optional; …)`.
- [ ] With `command -v ss` stubbed to fail: ss line contains "optional" (Level 4 snippet 4a).
- [ ] With `command -v ss` stubbed to fail: FAIL count is 1 (tmpfs only), not 2 (Level 4 snippet 4a).
- [ ] With `ss` present: ss reports OK and increments ok (Level 2 snippet 2c).
- [ ] With `findmnt` stubbed missing: findmnt still counted as MISSING/FAIL (Level 4 snippet 4c).
- [ ] The `[summary]` exit logic (`lib/pool.sh:4485-4497`) is unchanged (Level 3 snippet 3a).

### Code Quality Validation

- [ ] The new ss block is byte-identical in structure to the notify-send block (the established idiom).
- [ ] `if command -v ss` is inside `if` (set -e safe); no bare `(( ))`.
- [ ] The `command()` stub in the test uses `builtin command "$@"` pass-through (hermetic, scoped).
- [ ] Test body runs doctor as `$(... || true)` (tolerates the tmpfs rc 1).
- [ ] Test body named `selftest_doctor_ss_optional_when_missing` (single-setup runner — NOT `test_*`).
- [ ] Test body placed after `selftest_doctor_flags_disconnected_lease` (validate.sh:~882).
- [ ] No scope creep into Issues 1 (reaper) or 3 (ensure_connected).
- [ ] No new env vars; no config changes; no path changes.

### Documentation & Deployment

- [ ] Docstring `a.` bullet lists ss as OPTIONAL (and findmnt as required).
- [ ] Docstring SEVERITY MODEL "(not counted)" line includes ss.
- [ ] Docstring OUTPUT "MISSING = FAIL, except …" line includes "and ss".
- [ ] Docstring [dependencies] OUTPUT section has an ss row mirroring the notify-send row.
- [ ] Mode A satisfied: docstring rode with the code in this same subtask (no separate docs task).

---

## Anti-Patterns to Avoid

- ❌ Don't move `findmnt` out of the FAIL loop — its absence surfaces indirectly as a btrfs FAIL (pool_check_btrfs pool_die's on empty fstype). Only `ss` moves. The fix drops the SINGLE trailing ` ss` token; `findmnt` stays.
- ❌ Don't add `fail=$((fail+1))` in the new ss block's else branch — that is the entire bug. The else branch ONLY prints `(optional; …)`.
- ❌ Don't stub the `ss` command (`ss() { return 127; }`) in the test — doctor's loop uses `command -v ss` (a PATH check), which is unaffected by a command stub. Use the `command()` builtin override with `builtin command "$@"` pass-through (the only hermetic way to make `command -v ss` return 1).
- ❌ Don't manipulate PATH to simulate ss-missing — fragile and host-dependent. The `command()` override is hermetic and scoped to the body subshell.
- ❌ Don't assert `fail==0` in the test — the tmpfs temp tree yields 1 unrelated btrfs FAIL; `fail==0` is unachievable. Assert the ss LINE carries "optional" (primary) and/or FAIL=1-not-2 (secondary).
- ❌ Don't run `pool_admin_doctor` in the test without `|| true` — it returns rc 1 on the tmpfs FAIL, which under `set -e` aborts the body before the assertion.
- ❌ Don't touch the `[summary]` exit logic (`lib/pool.sh:4485-4497`), `pool_find_free_port`, `pool_check_btrfs`, or any function other than `pool_admin_doctor`. The fix is scoped to the `[dependencies]` section + its docstring.
- ❌ Don't name the test body `test_doctor_*` — that prefix is run by `abpool_run_suite` with per-test `setup()` (spawns a process), which HANGS on the 3rd call in a shared sandbox (AGENTS.md §4). Use `selftest_doctor_*` (single-setup runner).
- ❌ Don't spawn Chrome or a sim-owner in the doctor test body — it's a pure-function + hermetic-subshell test; the body runs in its own `bash "$script"` subshell with scoped stubs.
- ❌ Don't fix Issues 1 (reaper) or 3 (ensure_connected) in this subtask — they have their own subtasks (P1.M1.T1.S1 / P1.M1.T3). Stay in scope: Issue 2 only.
- ❌ Don't edit only the code and skip the docstring — Issue 2's root complaint is the code/comment contradiction. All 4 docstring edit-sites must move in lockstep with the code.
- ❌ Don't blanket-disable shellcheck rules — copying the notify-send pattern (already clean) introduces no warnings; fix the code, not the linter.
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, `TEST_RESULTS.md`, `architecture/`, or any file other than `lib/pool.sh` and `test/validate.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The fix is **one token removed from a loop + one ~7-line block (a verbatim copy of the
  existing notify-send pattern with the dep name changed) + four docstring line-edits + one
  test body**. Tiny, well-bounded surface, all within a single function (`pool_admin_doctor`).
- The bug was **reproduced empirically this session** (2026-07-16): with `command -v ss`
  stubbed to fail, doctor prints `ss   MISSING` (bare) and `FAIL=2`; the fix transitions
  this to `ss   MISSING (optional; …)` and `FAIL=1`. The exact repro command is in Known
  Gotchas and Validation Level 4a, so the implementer can verify the before/after transition
  directly.
- The **`command()` stub mechanism** for the test was validated this session — it makes
  `command -v ss` return 1 while passing all other `command -v` through, and it's scoped to
  the body subshell (no leak). This is the one non-obvious part of the test, and it's confirmed
  working.
- The **reference pattern** (`notify-send` at lib/pool.sh:4292–4295) is in the same function,
  so the new ss block is a literal sibling — no new idiom invented.
- The **test template** (`selftest_doctor_flags_disconnected_lease` at validate.sh:852–881) is
  quoted in full and the new body follows it line-for-line (outdir, body.sh heredoc, scoped
  stub, `|| true` on doctor, grep invariant, `timeout 15 bash`, assert_eq).
- The parallel P1.M1.T1.S1 PRP touches a **disjoint function** (`pool_reap_orphan_dirs`) and
  **disjoint test body** (`selftest_reap_orphan_dirs_*`), with placement guidance to avoid
  textual merge conflicts (place this body after `selftest_doctor_flags_disconnected_lease`).
- The -1 reflects residual risk in the secondary test assertion (`FAIL=1` not `FAIL=2`), which
  couples to the tmpfs environment — if a CI host has a btrfs `/tmp` the FAIL count differs.
  The PRIMARY assertion (ss line contains "optional") is environment-independent and is the
  load-bearing one; the PRP explicitly notes the implementer may drop the secondary if flaky.
  Level 2 snippet 2a + 2b catch any breakage immediately.
