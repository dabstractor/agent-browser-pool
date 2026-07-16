# Bug Fix Requirements

## Overview

Creative end-to-end QA of the `agent-browser-pool` implementation against the original
PRD (§1–§2) **and** the Phase‑2 delta (`plan/002_97982899bef6/delta_prd.md` — the pivot
to explicit `agent-browser-pool` invocation).

**Method.** Static analysis (`bash -n` all files clean; `shellcheck -s bash` clean — 0
findings on the 4533‑line `lib/pool.sh`), deep code reading of every affected function, and
**isolated, timeout‑bounded micro‑checks** of the pure plumbing functions
(`pool_dispatch_classify`, `pool_normalize_close/connect`, `pool_strip_session_args`,
`_pool_get_starttime`, lease write/read, `status`/`doctor`/`release`) in a throwaway
`mktemp` tree with `$HOME`/state/ephemeral/master all redirected away from the operator's
live environment. No real Chrome was booted against the shared sandbox; all live checks
used a fake `agent-browser` shim. (Per AGENTS.md §1–§6.)

**Quality assessment.** The lane engine itself is excellent: owner‑identity keying
(`(pid, comm, starttime)`), robust `/proc/<pid>/stat` parsing (greedy strip past the last
`)`, correctly rejecting the PRD's fragile `NF‑19` formula), short flock critical section
with post‑lock boot, atomic lease writes, prefix‑guarded `rm -rf`, idempotent release/reap,
correct `--session` stripping and `connect`/`close` normalization for **driving** commands,
clean `install.sh`, and a thorough `doctor`. The delta items that **were** done are done
well (`bin/agent-browser` deleted; `AGENT_BROWSER_POOL_DISABLE` purged everywhere;
preflight; benign installer; fail‑fast for driving commands without a `pi` ancestor).

**However**, one core delta requirement — **removal of the META passthrough class** — was
**not implemented**, and it has a real security consequence: meta commands bypass the
pool's session‑forcing, so an agent can target (and enumerate) **other agents' lanes**
through normal `agent-browser-pool` commands. This breaks the project's #1 guarantee.

---

## Critical Issues (Must Fix)

### Issue 1: META passthrough retained — breaks lane isolation (cross‑lane access via `--session`)

**Severity**: Critical
**PRD Reference**: §1.3 Goal 3 ("no command accepts a lane selector — one agent cannot
reach another's lane through normal tool use"); §2.4 step 0 ("anything else → DRIVING
command") + step 5 ("strip any caller `--session <X>`"); §2.13 ("there is no argument
that names a lane… through normal tool use, an agent physically cannot reach another
agent's lane"). Delta `D1.M1.T2` ("**Remove** the META passthrough step… there is no
'meta' class in the pool entry now") and validation criterion ("A driving command with no
`pi` ancestor… fails fast… **no passthrough**").

**Root cause.** `pool_dispatch_classify` (`lib/pool.sh:3070`) still classifies a third
command class — "meta" — for `skills|dashboard|plugin|mcp` (case at `lib/pool.sh:3119`),
`session list`, `--help|-h|--version`, and flags‑only/empty argv. `pool_wrapper_main`
step **c** (`lib/pool.sh:3532‑3536`) then executes these **unchanged** and **before**
owner resolution / before the step‑5 cleaning:

```bash
class="$(pool_dispatch_classify "$@")"
if [[ "$class" == "meta" ]]; then
    _pool_log "pool_wrapper_main: meta command → passthrough"
    exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — skills/--help/session list/etc.
fi
```

That `exec "$@"` passes the **original** argv straight to the real `agent-browser`. The
step‑5 cleaning (`pool_strip_session_args` + `pool_force_session`, steps i/j) only runs on
the driving path, so for meta commands:

- any caller `--session <X>` is **NOT stripped**; and
- `AGENT_BROWSER_SESSION` is **NOT forced** to the caller's `abpool-<N>`.

**Expected Behavior** (PRD §2.4 step 0 + delta): only
`(status|reap|release|doctor|help|--help|-h)` are pool verbs; **everything else is a
DRIVING command** that resolves the caller's owner identity, fails fast without a `pi`
ancestor, and runs with `--session` stripped and `AGENT_BROWSER_SESSION=abpool-<N>` forced.
No command except operator `release <N>` may name a lane.

**Actual Behavior.** A meta command accepts a lane selector (`--session`) and runs with no
forced session, so it can be aimed at **any** lane's daemon:

**Steps to Reproduce** (isolated temp tree; fake `agent-browser` shim that echoes its argv):

```bash
ROOT=$(mktemp -d); export HOME=$ROOT/home
mkdir -p $HOME/.local/bin $ROOT/state $ROOT/active $ROOT/master/Default
printf '#!/usr/bin/env bash\necho "RECV: argv=[$*] session_env=${AGENT_BROWSER_SESSION:-<unset>}"\n' > $HOME/.local/bin/agent-browser
chmod +x $HOME/.local/bin/agent-browser
export AGENT_BROWSER_POOL_STATE=$ROOT/state AGENT_CHROME_EPHEMERAL_ROOT=$ROOT/active \
       AGENT_CHROME_MASTER=$ROOT/master AGENT_CHROME_ALLOW_SLOW_COPY=1 \
       AGENT_BROWSER_REAL=$HOME/.local/bin/agent-browser
unset AGENT_BROWSER_POOL_OWNER_PID

# A) --session passes through UNSTRIPPED to a meta command → targets lane 3's daemon:
agent-browser-pool mcp --session abpool-3
#   RECV: argv=[mcp --session abpool-3] session_env=<unset>

agent-browser-pool dashboard --session abpool-3
#   RECV: argv=[dashboard --session abpool-3] session_env=<unset>

# B) session list runs with no forced session → lists ALL daemon sessions (every lane):
agent-browser-pool session list
#   RECV: argv=[session list] session_env=<unset>

# Contrast — a DRIVING command correctly strips --session + forces the session:
agent-browser-pool open --session abpool-3 url   # → cleaned argv "open url" (correct)
```

**Why this is a real isolation breach (not merely a spec nit).** Per `agent-browser mcp
--help` (verified on host, v0.28.0), `mcp` "Start[s] an MCP stdio server" whose `core`
profile exposes `agent_browser_open`, `agent_browser_snapshot`, interaction, and `eval`
tools, and `--session <name>` is a documented **Global Option**. Sessions are "isolated
browser instances" and each pool lane creates a session `abpool-<N>` bound to that lane's
Chrome. Therefore:

1. `agent-browser-pool session list` **enumerates every active lane** (session names
   `abpool-1`, `abpool-2`, …) — an information disclosure of other agents' presence and
   the pool's lane count. (Trivially triggered; no `pi` ancestor required.)
2. `agent-browser-pool mcp --session abpool-<N>` starts an MCP server bound to **lane N's
   daemon/browser**, giving an MCP‑aware agent the full open/click/type/snapshot/eval
   surface over **another agent's** Chrome — a complete read/write cross‑lane breach via
   the pool's own entry point. (The agent first discovers `N` via step 1.)

Both are reachable "through normal tool use" (ordinary `agent-browser-pool` commands an
agent can type), contradicting §1.3 Goal 3 and §2.13.

**Suggested Fix.** Implement the delta as written — eliminate the meta class:

1. In `pool_dispatch_classify` (`lib/pool.sh:3070`): return `'driving'` for **all** inputs
   (or delete the function and rely solely on the `bin/agent-browser-pool` dispatcher's
   pool‑verb split, which already correctly handles `status|reap|release|doctor|help|--help|-h`).
2. In `pool_wrapper_main` (`lib/pool.sh:3532‑3536`): **delete step c** (the
   `if [[ "$class" == "meta" ]] … exec "$POOL_REAL_BIN" "$@"` block). Then `--version`,
   `skills`, `mcp`, `dashboard`, `plugin`, `session list`, and flags‑only invocations all
   flow through the driving path: owner resolve → fail‑fast without a `pi` ancestor →
   acquire/reuse the caller's lane → `--session` stripped → `AGENT_BROWSER_SESSION`
   forced to `abpool-<N>`.
3. If a `--version` passthrough is genuinely desired, the delta explicitly permits
   special‑casing **only** `--version` to a preflight‑only passthrough — but not the whole
   meta set, and never with an unstripped `--session`.

(See Issue 3 for the required test + skill‑doc updates that must accompany this fix.)

---

## Major Issues (Should Fix)

### Issue 2: Meta/flags‑only commands bypass the no‑`pi`‑ancestor fail‑fast

**Severity**: Major
**PRD Reference**: PRD §2.4 step 1 ("No pi ancestor → DRIVING fails fast") + delta
validation criterion ("A driving command with **no `pi` ancestor** (and no override)
**fails fast** with the 'call `agent-browser` directly' message (**no passthrough**, no
lane boot)").

**Expected Behavior.** Any non‑pool‑verb token (including `--version`, `skills`, `mcp`,
`session list`, and a bare `agent-browser-pool --json`) invoked with no `pi` ancestor must
exit non‑zero with the fail‑fast message, because per §2.4 step 0 these are all driving
commands.

**Actual Behavior.** Because the meta passthrough (Issue 1) runs **before** owner
resolution, these tokens short‑circuit to `exec` and never hit the fail‑fast gate. Verified
in an isolated temp tree (fake `agent-browser` shim, no owner override):

```bash
agent-browser-pool --version        # → prints the real binary's version, rc=0  (should fail-fast)
agent-browser-pool skills get core  # → runs unchanged, rc=0                   (should fail-fast)
agent-browser-pool --json           # → passes through (flags-only → meta)     (should fail-fast)
```

So `agent-browser-pool --version` succeeds from any shell (no `pi` ancestor), while
`agent-browser-pool screenshot` correctly fails/blocks — an inconsistent contract surface.
This is the same root cause as Issue 1; it is listed separately because it is an
independently‑checkable acceptance criterion of the delta.

**Steps to Reproduce.** From a plain interactive shell (no `pi` ancestor) with no
`AGENT_BROWSER_POOL_OWNER_PID` override: `agent-browser-pool --version; echo "rc=$?"` →
exits 0 and prints a version (observed). The driving‑command counterpart correctly does
not pass through.

**Suggested Fix.** Same as Issue 1 (remove the meta passthrough). Once `--version` etc.
flow through the driving path, they will fail‑fast without a `pi` ancestor exactly like
`open`/`screenshot`/etc.

---

### Issue 3: Test suite and agent skill still assert/describe the removed meta‑passthrough model

**Severity**: Major
**PRD Reference**: Delta `D1.M3.T1` ("**Remove** the obsolete assertions: `transparency.sh`
tests (a) `skills get core`→passthrough and (b) `--version`/`--help`→passthrough… there is
no passthrough now. Replace with the new contract…") and `D1.M2.T2` ("replace the 'meta vs
driving' dispatch section with 'pool verbs vs driving'").

**Expected Behavior.** After the pivot, tests should assert the **new** contract (pool
verbs work with no owner; non‑pool‑verb tokens fail‑fast without `pi` and get a scoped
session), and the skill's `references/configuration.md` should describe "pool verbs vs
driving" — not "meta → passthrough".

**Actual Behavior.** The meta‑removal half of the delta was skipped coherently across
code, tests, and docs:

- `test/transparency.sh:236` — `test_passthrough_skills()` still asserts
  `agent-browser-pool skills get core` is byte‑equal to the real binary (META passthrough).
- `test/transparency.sh:270` — `test_version_passthrough()` still asserts
  `agent-browser-pool --version` is byte‑equal to the real binary (META passthrough).
- The file header (lines 8–10) still documents the passthrough checklist.
- `.agents/skills/agent-browser-pool/references/configuration.md` lines 47–66 still
  document "Command dispatch: meta vs. driving" with a "Meta commands (passthrough — never
  acquire a lane)" subsection listing `--version`, `skills`, `dashboard`, `plugin`, `mcp`,
  `session list`.

**Why this matters.** Because the tests still assert the **old** behavior and the code
still implements it, the suite **passes** despite the delta being unmet — the deviation is
invisible to `run_test`/CI. An agent reading the skill is also taught that these commands
"never acquire a lane," reinforcing the isolation gap from Issue 1.

**Steps to Reproduce.** `grep -nE 'passthrough|meta' test/transparency.sh` and
`grep -nE 'meta|passthrough' .agents/skills/agent-browser-pool/references/configuration.md`
both return live references (verified).

**Suggested Fix.** After fixing Issue 1: in `test/transparency.sh`, replace
`test_passthrough_skills` / `test_version_passthrough` with assertions that (a) pool verbs
(`--help`, `status`) work with no owner and (b) `skills`/`--version`/`mcp`/`session list`
**fail‑fast** without a `pi` ancestor (and, with an owner, run scoped to the caller's lane
with `--session` stripped). In `references/configuration.md`, replace the "meta vs driving"
section with the "pool verbs vs driving" model (§2.4 step 0). Note `--help`/`-h`/`help` are
already correctly pool verbs via the `bin` dispatcher, so only the meta‑passthrough subset
needs re‑framing.

---

## Minor Issues (Nice to Fix)

### Issue 4: Duplicated/overlapping command classification (dispatcher vs `pool_dispatch_classify`)

**Severity**: Minor
**PRD Reference**: Delta `D1.M1.T2` ("`pool_dispatch_classify` is either deleted or reduced
to the pool‑verb/driving split already done by the dispatcher (avoid duplication)").

**Actual Behavior.** `bin/agent-browser-pool`'s `case` already routes
`status|reap|release|doctor|--help|-h|help` to admin functions, so those never reach
`pool_wrapper_main`. Yet `pool_dispatch_classify` still contains a `--help|-h` short‑circuit
(`lib/pool.sh:3093`) and a `skills|dashboard|plugin|mcp` arm (`lib/pool.sh:3119`) that are
now partly dead (`--help` can no longer reach it) and partly the source of Issue 1. Once
the meta class is removed (Issue 1), `pool_dispatch_classify` collapses to "always
driving" and can be deleted entirely, leaving the `bin` dispatcher as the single source of
truth for the pool‑verb/driving split.

**Suggested Fix.** Delete `pool_dispatch_classify` and its single call site in
`pool_wrapper_main` (step c) as part of the Issue 1 fix.

---

## Testing Summary

- **Total checks performed:** ~60 (static: `bash -n` ×7, `shellcheck` ×7; isolated live
  micro‑checks of dispatch/normalize/strip/starttime/lease/status/doctor/release/help +
  end‑to‑end entry‑point behavior with a fake `agent-browser` shim).
- **Passing:** the lane engine and all delta items except the meta‑passthrough removal
  (owner identity, acquire/release/reap, copy/Singleton hygiene, port allocation,
  `--session`/`connect`/`close` normalization **for driving commands**, preflight,
  `install.sh`, `status`/`doctor`/`release` edge cases, `help`).
- **Failing:** 1 Critical (Issue 1) + 2 Major (Issues 2–3, same root cause) + 1 Minor
  (Issue 4).
- **Areas with good coverage:** arg cleaning for driving commands; lease lifecycle &
  staleness; release/reap idempotency & teardown safety; config/init validation; doctor
  diagnostics; install behavior.
- **Areas needing more attention:** the meta/driving classification boundary (Issue 1 —
  the security‑relevant gap), and end‑to‑end real‑Chrome boot/concurrency under an isolated
  container (not exercised here per AGENTS.md §1; the existing `test/concurrency.sh`
  harness covers N‑distinct‑lanes but, like `transparency.sh`, still assumes the
  passthrough model and should be re‑validated after the fix).
- **Sandbox hygiene:** all checks ran in a throwaway `mktemp` tree (deleted afterward);
  zero orphan processes or temp artifacts left behind; the operator's live
  `~/.local/state/agent-browser-pool` and running Chrome were never modified.
