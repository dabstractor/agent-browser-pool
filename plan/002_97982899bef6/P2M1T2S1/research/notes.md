# Research Notes — P2.M1.T2.S1: Add `_pool_preflight_real_bin()` + call in `pool_wrapper_main`

**Item**: Add a preflight that fails fast when the real `agent-browser` binary
(`$POOL_REAL_BIN`) is missing/non-executable, before any lane/dispatch work.
**PRD source**: §2.16 (Dependencies) — "Enforced two ways: (a) doctor's [binary] check;
(b) a preflight in the pool entry on every driving call that fails fast."
**Gap**: architecture/system_context.md **Gap 5**.
**Parallel sibling**: P2.M1.T1.S2 (removes POOL_DISABLE + flips no-pi-ancestor to
fail-fast) — treated as a CONTRACT; its post-state is the starting point here.

---

## 1. Starting state = POST-P2.M1.T1.S2 (verified against the live working tree)

The working tree ALREADY reflects S2's output (confirmed by direct read + grep):

- `grep -n POOL_DISABLE lib/pool.sh` → exactly ONE hit: `pool_admin_help:4597`
  (the `printf '  AGENT_BROWSER_POOL_DISABLE ...'` line, owned by P2.M1.T3.S1).
  **Zero** `POOL_DISABLE` in the `pool_wrapper_main` region.
- `pool_wrapper_main` step d is ALREADY fail-fast:
  `pool_die "agent-browser-pool: driving commands require a pi ancestor ..."`
- The step-b (POOL_DISABLE safety valve) block is GONE. The step-a → step-c region is now:
  ```
      pool_config_init
      pool_state_init

      # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
  ```
  (exactly one blank line between `pool_state_init` and the step-c comment).
- Header comments already reflect the no-POOL_DISABLE reality:
  - CONSUMES: `POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS, …` (no DISABLE).
  - `# config freezes POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.`
  - `# GOTCHA — TERMINAL: exits are exec (c/k) or pool_die (d + error branches).`
  - `# GOTCHA — passthrough exec (c) passes the ORIGINAL "$@" UNCHANGED …`
  - RC TAXONOMY "rc 0 ALWAYS (no guard)" list:
    `pool_dispatch_classify, pool_normalize_close/connect, pool_strip_session_args,
     pool_config_init, pool_state_init, pool_owner_resolve`.

⇒ This item builds on that clean post-S2 baseline. **No POOL_DISABLE interaction.**

## 2. Static baseline (must be preserved)

```
bash -n lib/pool.sh            → exit 0   (verified)
shellcheck -s bash lib/pool.sh → exit 0, ZERO output   (verified)
```
Both gates must remain green after this item's edits.

## 3. The check predicate (canonical form — reuse the doctor's)

`pool_admin_doctor` `[binary]` section (lib/pool.sh ~4380) uses EXACTLY:
```bash
if [[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]; then
```
The preflight uses the SAME predicate (consistency; same semantics: a symlink to an
executable is `-x`-true, a dangling symlink is `-f`-false, a non-executable file is
`-x`-false). **Do NOT** use `command -v` — `POOL_REAL_BIN` is an absolute path frozen by
`pool_config_init`, not a PATH lookup.

## 4. `POOL_REAL_BIN` provenance (why the preflight runs AFTER config_init)

- `pool_config_init` (lib/pool.sh:131-207) freezes `POOL_REAL_BIN`:
  `real_bin="$(_pool_config_canon_path "${AGENT_BROWSER_REAL:-$POOL_HOME_DIR/.local/bin/agent-browser}")"`
  then `POOL_REAL_BIN="$real_bin"; declare -g POOL_REAL_BIN`.
- `_pool_config_canon_path` uses `realpath -m` (canonicalize-missing; exits 0 even when
  the path does not exist). So a missing binary is frozen to its canonical absolute path
  WITHOUT error — the existence check is the preflight's job, exactly as PRD §2.16 intends.
- ⇒ the preflight MUST run AFTER `pool_config_init` (so `$POOL_REAL_BIN` is set) and is
  meaningless before it. It also runs after `pool_state_init` (cheap, idempotent mkdir) —
  ordering state_init vs preflight does not matter functionally, but the item contract
  says "AFTER pool_config_init + pool_state_init (step a)" so we place it last in step a.

## 5. `pool_die` join semantics (the message is 3 args → ONE stderr line)

`pool_die()` (lib/pool.sh:30): `printf '%s\n' "$*" >&2; exit 1`.
`"$*"` joins ALL positional args with the FIRST char of `$IFS` (a space) into ONE line.
The item's required 3-arg call therefore prints a SINGLE line:
```
agent-browser-pool: the real agent-browser binary is missing or not executable: <POOL_REAL_BIN> Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path.
```
Use a `\` line-continuation to keep the 3 string literals on 3 source lines (matches the
file's existing multi-line `pool_die` style, e.g. step d). Do NOT collapse into one literal,
do NOT add `\n`. The path (`$POOL_REAL_BIN`) is passed UNQUOTED-as-its-own-arg — actually
it MUST be its own double-quoted arg: `"$POOL_REAL_BIN"` (word-splitting safety).

## 6. Placement of the new function definition

File convention (verified): a `_pool_*` private helper that is consumed primarily by one
public function is defined IMMEDIATELY BEFORE that consumer's `# ===` section divider.
Example: `_pool_acquire_critical_section` (lib/pool.sh:2021) sits directly before
`pool_acquire_locked`'s `# ===`/docstring/function.

For `_pool_preflight_real_bin`, the consumer is `pool_wrapper_main` (lib/pool.sh:3596).
Current layout around the boundary:
```
    export AGENT_BROWSER_SESSION="abpool-$lane"      # end of pool_force_session body
    return 0
}                                                    # pool_force_session close brace
                                                     # blank line
# ================================================================                  # pool_wrapper_main SECTION divider
# Wrapper shim — complete lifecycle (P1.M6.T3.S1)
# ================================================================
# ... (big contiguous docstring for pool_wrapper_main) ...
pool_wrapper_main() {
```
⇒ Insert `_pool_preflight_real_bin` (+ its Mode-A docstring) between `pool_force_session`'s
closing `}` and the `# ===` divider. This keeps the wrapper's docstring contiguous with its
function and matches the `_pool_acquire_critical_section` precedent.

(Note: the item text says "around lib/pool.sh:3590". In the CURRENT post-S2 file, line 3590
falls INSIDE the wrapper docstring — you cannot define a function inside a comment block.
The intent — "the function immediately before pool_wrapper_main" — is satisfied by the
placement above. Anchor edits on the exact TEXT, not line numbers; S2 already shifted the
wrapper up by 3 vs its pre-S1 position.)

## 7. Placement of the CALL in `pool_wrapper_main`

Item contract: "AFTER pool_config_init + pool_state_init (step a) but BEFORE the
pool_dispatch_classify call (step c). … runs on EVERY invocation that reaches
pool_wrapper_main (driving commands + meta passthrough). … unguarded … on its own line
between pool_state_init and pool_dispatch_classify."

⇒ Fold into step a: insert `_pool_preflight_real_bin` (unguarded) as the last line of the
step-a block, immediately after `pool_state_init` and before the blank line + step-c
comment. Because it runs BEFORE `pool_dispatch_classify`, it covers BOTH meta (`--version`,
`skills`, bare flags) and driving paths — exactly the contract.

## 8. Consequential header-comment hygiene (same discipline S2 applied)

The RC TAXONOMY block is the file's authoritative "which helper needs an `if`/`||` guard
under set -e" reference. `_pool_preflight_real_bin` is rc 0 ALWAYS (returns 0 on success,
pool_die's on failure — same category as `pool_config_init`/`pool_state_init`). It MUST be
added to the "rc 0 ALWAYS (no guard)" list, else a future maintainer might wrongly wrap the
call in a guard or, conversely, think a guardless call is an oversight.

The other header comments need NO change:
- CONSUMES already lists `POOL_REAL_BIN`.
- The step-a comment already says "config freezes POOL_REAL_BIN, …".
- "GOTCHA — TERMINAL: exits are exec (c/k) or pool_die (d + error branches)" — the preflight
  pool_die is an "error branch" (fires before c); the statement stays accurate.
- "GOTCHA — passthrough exec (c)…" — still true (c is unchanged).

## 9. `pool_dispatch_classify` confirms the integration micro-check design

`pool_dispatch_classify` (lib/pool.sh:3172-3282):
- `--help|-h|--version` → prints `meta`, return 0 (FIRST case arm).
- bare flags only / empty `$@` → `meta`.
- `session list`, `skills|dashboard|plugin|mcp` → `meta`.
- everything else (incl. `open`, `connect`, `close`, unrecognized) → `driving`.

⇒ For the integration micro-check: `pool_wrapper_main --version` with a MISSING binary must
die at the PREFLIGHT (before dispatch), proving the call sits before step c and covers meta.
Assert: exit 1 + the binary message present; NOT a meta-passthrough (no real-binary exec).

## 10. Validation strategy (AGENTS.md §1/§2 — no Chrome, no daemons, no shared $HOME)

All checks are STATIC or isolated `timeout`-bounded micro-checks that source the pure lib
(`source lib/pool.sh` defines functions only — no top-level execution) and die/return at the
preflight BEFORE any lane/port/Chrome work.

- Override mechanism: set `AGENT_BROWSER_REAL=<bogus path>` BEFORE sourcing →
  `pool_config_init` freezes `POOL_REAL_BIN` to that path; OR override `POOL_REAL_BIN`
  directly after sourcing (it is a plain global). Both work; the env-var form exercises the
  real config path.
- Redirect `HOME` to a `mktemp -d` so `pool_state_init`'s mkdir lands in an ephemeral tree,
  never the operator's real `~/.local/state/agent-browser-pool`.

Micro-checks:
1. **UNIT fail**: bogus `AGENT_BROWSER_REAL` → `_pool_preflight_real_bin` direct call →
   exit 1, message contains both distinctive substrings.
2. **UNIT pass**: `AGENT_BROWSER_REAL=/bin/true` → `_pool_preflight_real_bin` direct call →
   exit 0, no output.
3. **INTEGRATION ordering**: bogus binary + `pool_wrapper_main --version` (meta) →
   exit 1 + binary message (proves preflight runs before dispatch and covers meta; never
   reaches the real-binary exec).

## 11. Test-impact analysis (no NEW expected failures introduced)

This item is PURELY ADDITIVE: it adds one new fail-fast path (missing binary) that only
triggers when the real `agent-browser` is actually absent. In every normal test run the
binary exists → preflight returns 0 → behavior identical to today.

- `test/transparency.sh` — boots real Chrome; not run here (P2.M5.T2.S1 rewrites it). When
  run later it uses a real binary → preflight passes. No new failure.
- `test/validate.sh` — already has the EXPECTED `selftest_config_disable` failure from S2
  (owned by P2.M5.T1.S1). The preflight adds no new validate.sh failure.
- `test/concurrency.sh`, `test/release_reaper.sh` — call lib functions / admin verbs with a
  real binary present → preflight passes. No new failure.

⇒ The static gates (bash -n, shellcheck) + the 3 isolated micro-checks are the complete
validation surface for this item. Do NOT run the real suite against the shared sandbox.

## 12. Out-of-scope (owned by other items — do NOT touch)

- `pool_admin_help` `AGENT_BROWSER_POOL_DISABLE` printf (lib/pool.sh:4597) → P2.M1.T3.S1.
- `pool_admin_doctor` `[binary]` check (already exists; PRD §2.16 enforcement (a)) — leave
  as-is. (PRD future note: "doctor should assert `--version` ≥ 0.28" — NOT this item.)
- `bin/agent-browser-pool` `*)` → `pool_wrapper_main "$@"` dispatch → P2.M2.T1.S1.
- Any external doc (configuration.md / SKILL.md / README.md) → P2.M4 / P2.M6.
