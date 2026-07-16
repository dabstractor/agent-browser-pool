# Research Notes — P3.M2.T1.S3 (transparency.sh fail-fast poll → new R3 message text)

Static research only. No tests run, no Chrome booted (AGENTS.md §1). All line numbers are
EXACT against the current tree (verified 2026-07-12 via `grep -n`).

---

## 1. The contract (what this item must deliver)

Update `test/transparency.sh::test_driving_no_pi_ancestor_fails_fast` (+ its header comment)
so its temp-file poll matches P3.M1.T1.S3's NEW fail-fast message instead of the literal
`pi ancestor` substring. P3.M1.T1.S3 (now Complete) changed `pool_die` from "require a pi
ancestor" to "require a supported agent harness (pi/claude/codex/agy)" — so the old literal
substring poll is a guaranteed false-negative (test would time out).

**Scope (from the work-item contract):** ONLY `test_driving_no_pi_ancestor_fails_fast` (the
function) + its header comment block. Do NOT change structure (setsid --fork detach, temp-file
poll, bounded deadline). Validation = `bash -n` + `shellcheck -s bash` rc 0 (static only;
do NOT run the suite — AGENTS.md §1).

---

## 2. The NEW message (lib/pool.sh — the source of truth)

`lib/pool.sh:3429-3430` (the driving-command dispatcher step d, inside `pool_wrapper_main`):
```bash
pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
         "For raw browser use without pooling, call 'agent-browser' directly."
```
- `pool_die` body (lib/pool.sh:29-32): `printf '%s\n' "$*" >&2; exit 1` → `$*` joins args
  with `$IFS` (default space) → emits ONE line. Full line:
  `agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy). For raw browser use without pooling, call 'agent-browser' directly.`
- **Chosen poll substring: `supported agent harness`** — appears EXACTLY ONCE in lib/pool.sh
  (this pool_die), is fully contiguous WITHIN the first pool_die arg (so arg-joining format
  is irrelevant), and is specific + stable (it is the core of PRD §2.4 step 1's message).
- Verified `supported agent harness` currently appears NOWHERE else in the repo (only the one
  pool_die), so the substring is specific to this fail-fast path.

---

## 3. EXACT current location in test/transparency.sh (re-derived — contract's "~528" is off)

The work-item contract says "line ~528" and "lines 498-532". The ACTUAL current tree
(numbers shift when siblings land; always re-derive with grep):

```
498  # === header comment block START ===
499  # TEST (i) — driving command with NO pi ancestor → FAIL-FAST pool_die (§2.4 step 1).
500  # PRD §2.4 step 1 / shipped P2.M1.T1.S2: "No pi ancestor → DRIVING fails fast" …
501  # … dispatcher step d calls pool_die (exit 1, stderr contains 'pi ancestor … for raw browser use call
502  # 'agent-browser' directly').
...
511  # … TEMP FILE and poll (bounded) for 'pi ancestor'. pool_die fires at step d, …
...
514  # === header comment block END ===
515  test_driving_no_pi_ancestor_fails_fast() {
516      _transparency_setup_real_env || return 1
517      # Deliberately NO _transparency_spawn_owner — this body has NO pi ancestor.
...
526      env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
527          setsid --fork "$ABPOOL_ADMIN" open about:blank >"$tmp" 2>&1 &
528      bg=$!
529      wait "$bg" 2>/dev/null || true
530      # Poll the temp file for the fail-fast message (bounded — pool_die is sub-second).
531      deadline=$(( $(date +%s) + 10 ))
532      msg=""
533      while (( $(date +%s) < deadline )); do
534          msg="$(cat "$tmp" 2>/dev/null || true)"
535          [[ "$msg" == *"pi ancestor"* ]] && break            ← LOAD-BEARING POLL #1 (contract's "~528")
536          sleep 0.2
537      done
538      rm -f -- "$tmp"
539      [[ "$msg" == *"pi ancestor"* ]] \                        ← LOAD-BEARING POLL #2 (final assert)
540          || { _fail "driving cmd with no pi ancestor did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
541  }
```

**The 8 literal `pi ancestor` occurrences WITHIN the scoped block (498–541):**
| Line | Occurrence | Kind |
|------|------------|------|
| 499  | `NO pi ancestor` | comment (concept) |
| 500  | `No pi ancestor` | comment (concept) |
| 502  | `'pi ancestor … for raw browser use` | comment (message text) |
| 511  | `poll (bounded) for 'pi ancestor'` | comment (message text) |
| 517  | `NO pi ancestor` | comment (concept) |
| 535  | `[[ "$msg" == *"pi ancestor"* ]] && break` | **POLL (load-bearing)** |
| 539  | `[[ "$msg" == *"pi ancestor"* ]] \` | **POLL (load-bearing)** |
| 540  | `no pi ancestor did NOT fail fast` | _fail label (concept) |

**Bare-`pi` references in the block that are NOT the phrase "pi ancestor"** (lines 504–508,
521, 525): these describe the REAL test environment ("this suite is often launched BY `pi`")
and the determinism reasoning ("ppid walk finds no 'pi'"). They reference the `pi` PROCESS
NAME, remain FACTUALLY TRUE (the test runs with NO harness ancestor at all), and are OUTSIDE
the contract's literal-`pi ancestor` scan. **Decision: leave them unchanged** (changing them
is drift; they are accurate environmental facts). Documented as a scope decision in the PRP.

---

## 4. ⚠️ CRITICAL BLAST-RADIUS DISCOVERY (outside contract scope — flag for orchestrator)

The work-item contract + architecture/test_code_map.md §6 ONLY flagged
`test_driving_no_pi_ancestor_fails_fast` (TEST i, 498–541). But `grep -c 'pi ancestor'
test/transparency.sh` = **21 total**; only **8** are in the scoped block. The other **13**
include a **shared helper + two sibling tests that will break IDENTICALLY** when R3 landed:

### 4a. Shared helper `_transparency_assert_driving_no_pi_fails_fast` (lines 242–260)
This is the VERIFIER used by TEST (a) `test_skills_fail_fast_no_pi` (272) and TEST (b2)
`test_version_fail_fast_no_pi` (304). It has the SAME temp-file + bounded poll, matching the
SAME literal substring:
```
254          [[ "$msg" == *"pi ancestor"* ]] && break
258      [[ "$msg" == *"pi ancestor"* ]] \
259          || { _fail "no-pi '$*' did NOT fail fast; got: ${msg:-<empty>}"; return 1; }
```
→ TEST (a) and TEST (b2) WILL time out (false-negative) exactly like TEST (i), because they
route through this helper. test_code_map §3/§6 MISSED this (it only enumerated TEST i's poll).

### 4b. Other `pi ancestor` occurrences (comments + header)
- File header lines **10, 12, 19** (the `(a)`/`(b2)`/`(i)` one-line test manifest).
- TEST (a) comment lines **265, 266, 268** ("pool_die 'driving commands require a pi ancestor …'").
- TEST (b2) comment lines **300, 301** (same).
- Helper header line **230** ("fail-fasts with the 'pi ancestor' pool_die message").

### 4c. Recommendation
These are a **genuine coverage gap in the P3.M2.T1 decomposition** — the contract author
followed test_code_map §6 (which only flagged TEST i) and did not know about the shared
helper / sibling tests. **This PRP delivers exactly the contract (TEST i + its header), and
documents this gap as RESIDUAL RISK.** Recommended follow-up: a sibling item
(P3.M2.T1.S4) that applies the identical fix to `_transparency_assert_driving_no_pi_fails_fast`
(lines 254, 258, 259 + header 229–241) and the TEST (a)/(b2) comments — one-pass SUITE
success (not just static-check success) requires it. Do NOT expand this PRP's scope without
orchestrator sign-off (scope discipline; the implementer should not silently broaden it).

---

## 5. Validation baselines (verified, static only)

```
bash -n test/transparency.sh                                  → rc 0   (current, must stay 0)
shellcheck -S warning -s bash test/transparency.sh            → rc 0   (current, must stay 0)
shellcheck -s bash test/transparency.sh (full)                → rc 1, a handful of PRE-EXISTING
                                                                 info/style findings; NONE in the scoped
                                                                 block. The 8 edits change only substring
                                                                 literals + comment words → introduce
                                                                 ZERO new findings (verified by reasoning:
                                                                 no new unquoted vars, no new patterns).
```
After the edits, re-run both; both must remain rc 0 / unchanged-in-count. Do NOT run the
test suite during planning (AGENTS.md §1).

---

## 6. Risk to one-pass success

- **For the CONTRACT scope (TEST i + header): LOW.** 8 mechanical substring/comment edits,
  static-validated. The chosen substring `supported agent harness` is host-verified to be the
  exact new pool_die text (lib/pool.sh:3429). Confidence 9/10.
- **For one-pass SUITE success: BLOCKED by the shared helper (§4a).** If the orchestrator's
  definition of "done" includes the suite actually passing, TEST (a)/(b2) will still time out
  until §4 is addressed. This is flagged, not hidden.
