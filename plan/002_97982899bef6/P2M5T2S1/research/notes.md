# Research Notes — P2.M5.T2.S1 (rewrite transparency.sh invocations + fail-fast tests)

Item: rewrite `test/transparency.sh` for the no-shadow explicit-invocation model.
Sibling/contract: P2.M5.T1.S1 (validate.sh — `ABPOOL_WRAPPER` removed, `ABPOOL_ADMIN` kept).
All findings below are VERIFIED LIVE against the current tree (static reads only — AGENTS.md §1).

---

## 1. Dispatch semantics (bin/agent-browser-pool — SOLE entry point, SHIPPED P2.M2)

`bin/agent-browser-pool` dispatch (verified, read verbatim):
```bash
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) pool_wrapper_main "$@" ;;
esac
```

**Routing per token (decisive for test design):**
| invocation                        | bin case arm      | reaches pool_wrapper_main? | behavior                                   | test assertion            |
|-----------------------------------|-------------------|----------------------------|--------------------------------------------|---------------------------|
| `--help`                          | `--help\|-h\|help`| NO                         | `pool_admin_help` → POOL help text         | CONTAINS 'agent-browser-pool' (NOT byte-equal) |
| `--version`                       | `*)`              | YES → classify `--version` → meta | exec `$POOL_REAL_BIN --version`     | byte-equal to real binary (HOLDS) |
| `skills get core`                 | `*)`              | YES → classify cmd=`skills` → meta | exec `$POOL_REAL_BIN skills get core` | byte-equal to real binary (HOLDS) |
| `open <url>` / `connect`/`close`  | `*)`              | YES → driving              | acquire/boot/exec                          | lane assertions (unchanged) |
| `status`/`reap`/`release`/`doctor`| named arms        | NO                         | admin verbs (no lane)                      | (not tested here)         |

**Why `--help` is NOT passthrough:** the bin `case` intercepts `--help` BEFORE
`pool_wrapper_main`/`pool_dispatch_classify` ever run. `pool_dispatch_classify` DOES classify
`--help|-h|--version` as `meta` (lib/pool.sh ~3180), but that only matters for tokens that
REACH pool_wrapper_main (i.e. `--version`, which has no case arm). `--help` is swallowed by the
bin dispatch. This is THE core reason test (b) must split.

## 2. pool_wrapper_main (SHIPPED P2.M1.T1.S2 — no-pi-ancestor is fail-fast)

Step order (verified, lib/pool.sh:3619+):
  a. pool_config_init + pool_state_init
  b. `_pool_preflight_real_bin` (must exist+exec, else pool_die with a real-bin message)
  c. `class="$(pool_dispatch_classify "$@")"`; meta → `exec "$POOL_REAL_BIN" "$@"`
  d. `pool_owner_resolve`; if `POOL_OWNER_PID==0` → `pool_die "agent-browser-pool: driving
     commands require a pi ancestor (owning pi process). For raw browser use without pooling,
     call 'agent-browser' directly."`  (lib/pool.sh:3645)
  e–k. acquire/boot/connected/normalize/session/exec (unchanged)

`pool_die` (lib/pool.sh:30): `printf '%s\n' "$*" >&2; exit 1` → full message to STDERR, exit 1,
contains the literal substring `pi ancestor`. (Both args are joined by a single space by `$*`.)

## 3. pool_admin_help output (verified, lib/pool.sh:4592+)

First line: `agent-browser-pool — the sole entry point for browser pool verbs AND driving commands.`
→ output CONTAINS the literal `agent-browser-pool`. The real Vercel `agent-browser --help` does
NOT contain `agent-browser-pool` (it describes itself as `agent-browser`). So asserting
`[[ "$out" == *"agent-browser-pool"* ]]` on `$ABPOOL_ADMIN --help` output is robust + unique.

## 4. The rename is LOAD-BEARING (not cosmetic)

CURRENT `test/validate.sh` grep (verified): `ABPOOL_ADMIN` defined at line 26; **`ABPOOL_WRAPPER`
is ABSENT** (zero matches). transparency.sh SOURCES validate.sh and runs under `set -euo pipefail`
(line 51). Its 5 `$ABPOOL_WRAPPER` references (lines 179,233,247,320,394) are therefore
UNBOUND → under `set -u` the suite ABORTS at the first driving/meta invocation. So the
`$ABPOOL_WRAPPER` → `$ABPOOL_ADMIN` rename is REQUIRED just to make the file runnable. (T1.S1's
contract = ABPOOL_WRAPPER removed; the live validate.sh already satisfies it.)

## 5. Exact rename + comment sites (grep enumeration)

`$ABPOOL_WRAPPER` variable (5 sites — rename to `$ABPOOL_ADMIN`):
- 179: `_transparency_run_open_bg` — `timeout --signal=KILL 25 "$ABPOOL_WRAPPER" "$@" ...`
- 233: `test_passthrough_skills` — `w="$(timeout 15 "$ABPOOL_WRAPPER" skills get core ...)"`
- 247: `test_passthrough_help_version` loop — `w="$(timeout 15 "$ABPOOL_WRAPPER" "$flag" ...)"`
- 320: `test_connect_random_ignored` LAYER 2 — `"$ABPOOL_WRAPPER" connect 98765`
- 394: `test_close_all_scoped_no_peer_harm` LAYER 2 — `"$ABPOOL_WRAPPER" close --all`

`$ABPOOL_ADMIN` already used at line 481 (runner inter-body `release all`) — keep.

`wrapper` substring in COMMENTS (contextual rewrite; NOT the variable):
  18,19,24,82,169,171,177,178,184,201,235,249,256,298,299,318,327,353,355,390,478.
Rule: `wrapper` (the old bin/agent-browser shim) → `driving command` / `pool` / `agent-browser-pool`.
Keep `pool_wrapper_main` references untouched where they refer to the LIBRARY dispatcher (none in
transparency.sh — those are in validate.sh). `passthrough` stays ONLY for META (skills/--version);
never for no-pi-ancestor.

`PATH-shadowing`: zero matches in transparency.sh (already absent — only validate.sh/install had it).
So no PATH-shadowing comment to remove here; just ensure no new one is introduced.

## 6. Test (b) split design

CURRENT `test_passthrough_help_version` (lines 242-251): loops `for flag in --help --version`,
byte-equal vs `$POOL_REAL_BIN`. This is WRONG for `--help` (pool help ≠ real help).

SPLIT into two auto-discovered functions:
- `test_help_shows_pool_help`: `out=$("$ABPOOL_ADMIN" --help 2>&1 || true)`; assert
  `[[ "$out" == *"agent-browser-pool"* ]]`. (Deterministic; pool help's signature phrase.)
- `test_version_passthrough`: byte-equal `$ABPOOL_ADMIN --version` vs `$POOL_REAL_BIN --version`
  (HOLDS — `--version` reaches pool_wrapper_main → meta → exec real binary).

(Runner auto-discovers `^test_` via compgen — adding functions needs ZERO runner change.)

## 7. No-pi-ancestor fail-fast test (NEW — covers a shipped contract no test validates)

Behavior: `$ABPOOL_ADMIN <driving>` with no `pi` ancestor → pool_die (exit 1, stderr 'pi ancestor').

DETERMINISM PROBLEM: pool_owner_resolve REAL MODE walks ppid from `$$`. If transparency.sh is
launched BY pi (this coding harness!), the driving subprocess's ppid chain INCLUDES pi → would
find an owner → NOT fail-fast → flaky/context-dependent. The env override (`AGENT_BROWSER_POOL_OWNER_PID`)
only SIMULATES an owner existing; there is no "force no-owner" env var.

DETERMINISTIC FIX: fully detach the driving command from this shell's tree via `setsid` (no
`--wait`): setsid forks the child into a NEW session and exits; the child is reparented to the
nearest subreaper / pid 1 (systemd — comm != 'pi') → ppid walk finds no 'pi' → POOL_OWNER_PID=0
→ fail-fast. `env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME` strips any
inherited owner override. Because setsid exits before the child, `$()` capture would be racy →
redirect the detached child's stdout+stderr to a TEMP FILE and poll it (bounded) for the
'pi ancestor' message (pool_die fires at step d, BEFORE any Chrome/lane work → sub-second).

PRECONDITION: `_pool_preflight_real_bin` runs BEFORE owner-resolve/die → AGENT_BROWSER_REAL must be
set (call `_transparency_setup_real_env` first, which exports it). No owner spawned (do NOT call
`_transparency_spawn_owner`). No lane acquired → `release all` backstop is a harmless no-op.

This test is cheap + deterministic + covers the §2.4 fail-fast contract. It does NOT hang
(no Chrome; bounded poll; detached child self-exits via pool_die).

## 8. Validation approach (AGENTS.md §1/§6 — static only during implementation)

- `bash -n test/transparency.sh` (baseline: OK).
- `shellcheck -s bash test/transparency.sh` (baseline: rc 1, ONLY SC1091 info x2 — the
  `source ./validate.sh` lines). Gate = no NEW error/warning codes; in particular no SC2154
  (unbound `$ABPOOL_WRAPPER`) and no SC2086 from the new tests.
- grep gates: `ABPOOL_WRAPPER` → 0; `ABPOOL_ADMIN` → ≥6 (5 renamed sites + line 481); the two
  new test fn names present; `pi ancestor` present (new test).
- The FULL suite run boots real Chrome + spawns sim-owners → ONLY in a fully isolated
  sandbox/container (NOT the shared one; NOT a gate during implementation). The static checks
  are authoritative for this edit (mirrors T1.S1's precedent).

## 9. Scope boundaries (do NOT touch)

- lib/pool.sh, bin/agent-browser-pool, install.sh, *.md — read-only / owned elsewhere.
- test/validate.sh, concurrency.sh, release_reaper.sh — owned by T1.S1 / T3.S1.
- PRD.md, plan/**/prd_snapshot.md, plan/**/tasks.json, .gitignore — read-only.
- This item edits ONLY test/transparency.sh.
