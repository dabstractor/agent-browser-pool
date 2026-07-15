# Research Notes — P2.M5.T1.S1: Remove ABPOOL_WRAPPER and DISABLE selftest from validate.sh

Item: edit **`test/validate.sh` ONLY**. All findings below are STATIC (read-only / `grep` /
`sed` / `bash -n` / `shellcheck`). Per AGENTS.md §1 NO real Chrome / daemon / test-suite run
was performed during this research. No processes were spawned.

---

## 1. Contract source & reconciliation (THE authoritative spec)

The item description cites `plan/002_97982899bef6/architecture/gap_analysis.md` **§8**. That
section (read in full) is the contract:

> §8. test/validate.sh — UPDATE
> - Line 26: `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` → remove or repurpose
> - Line 314: `[[ -x "$ABPOOL_WRAPPER" ]]` check → update or remove
> - Lines 346-357: `selftest_config_disable` → remove entirely (tests POOL_DISABLE)
> - Any other selftest or assertion using `ABPOOL_WRAPPER`

**CRITICAL reconciliation — the gap_analysis names are LOOSE; the LIVE file differs:**

| Contract (gap_analysis §8) | LIVE `test/validate.sh` (current) | Match? |
|---|---|---|
| Line 26: `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` | **Line 26** `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` | ✅ EXACT |
| Line 314: `[[ -x "$ABPOOL_WRAPPER" ]]` | **Line 314** `[[ -x "$ABPOOL_WRAPPER" ]] || { _fail "wrapper not executable: $ABPOOL_WRAPPER"; return 1; }` | ✅ EXACT |
| Lines 346-357: `selftest_config_disable` | **NO function literally named `selftest_config_disable`.** The function that tests `AGENT_BROWSER_POOL_DISABLE → POOL_DISABLE` is **`selftest_config_bool_via_pool_config_init`** (def line 350; comment header 346-349; body to line 358). | ⚠️ NAME differs; LOCATION matches (346-358) |

> The implementer MUST NOT search for a function called `selftest_config_disable` — it does
> not exist. The function to delete is **`selftest_config_bool_via_pool_config_init`** (the
> one whose comment says "End-to-end: AGENT_BROWSER_POOL_DISABLE=… flows through
> pool_config_init to POOL_DISABLE=1. This is the cutover safety-valve contract (PRD §2.17)").

---

## 2. Dependency / starting state (what's ALREADY shipped)

Per `<plan_status>` + verified by `grep`:

- **P2.M1.T1.S1 (DONE)**: `POOL_DISABLE` is FULLY REMOVED from `lib/pool.sh`.
  - `grep -c 'POOL_DISABLE' lib/pool.sh` → **0**
  - `grep -c 'AGENT_BROWSER_POOL_DISABLE' lib/pool.sh` → **0**
  - ⇒ the DISABLE selftest in validate.sh tests a variable that **no longer exists** → it
    would FAIL (the subshell `printf "%s" "$POOL_DISABLE"` prints empty, `assert_eq "1" ""`
    fails). This is WHY it must be deleted.
- **P2.M2.T2.S1 (DONE)**: `bin/agent-browser` is DELETED.
  - `ls bin/` → only `agent-browser-pool` + `.gitkeep` (no `agent-browser`).
  - ⇒ `$ABPOOL_WRAPPER` (= `bin/agent-browser`) points at a **non-existent file** → the
    `[[ -x "$ABPOOL_WRAPPER" ]]` check would FAIL on every selftest run. This is WHY the var
    + check must be removed.
- **Parallel sibling P2.M4.T3.S1** (skill README) is being implemented in parallel; it does
  NOT touch `test/validate.sh`. No conflict.

---

## 3. `_pool_config_bool` is STILL USED ⇒ keep its two truth-table selftests

The DISABLE selftest is the END-TO-END one (`_via_pool_config_init`). The two PURE-normalizer
selftests must STAY because `_pool_config_bool` is still consumed by `lib/pool.sh` for OTHER
config:

```
lib/pool.sh:181:    headless="$(_pool_config_bool "${AGENT_CHROME_HEADLESS:-}")"
lib/pool.sh:182:    allow_slow_copy="$(_pool_config_bool "${AGENT_CHROME_ALLOW_SLOW_COPY:-}")"
```

So: **KEEP** `selftest_config_bool_truthy` (line 324) and `selftest_config_bool_falsy`
(line 333). **DELETE ONLY** `selftest_config_bool_via_pool_config_init` (lines 346-358).

---

## 4. The selftest runner has NO hardcoded list (auto-discovery)

`_run_selftest_suite` (line 763, body 766-788) enumerates functions dynamically:

```bash
for fn in $(compgen -A function | grep '^selftest_' | sort); do
    ...
    if "$fn"; then ...
```

⇒ **Contract step (d)** ("UPDATE the selftest suite runner: remove `selftest_config_disable`
from the list of selftests that are run") is **AUTOMATICALLY SATISFIED** by deleting the
function — the runner rediscovers the remaining `selftest_*` functions each run. There is
**NO list to edit** and the runner code needs **NO change**. (Line 247 is `abpool_run_suite`,
the sourced-mode runner — also auto-discovery, unrelated.)

> Do NOT add a hardcoded list, do NOT touch `_run_selftest_suite`. The deletion IS the update.

---

## 5. The `selftest_wrapper_and_admin_are_executable` function (lines 311-316) — edit map

Current (verbatim):
```bash
selftest_wrapper_and_admin_are_executable() {
    # Pre-flight the two binaries downstream tests invoke by ABSOLUTE PATH (PRD §2.17).
    # (Also consumes ABPOOL_WRAPPER/ABPOOL_ADMIN so they aren't shellcheck-SC2034-unused.)
    [[ -x "$ABPOOL_WRAPPER" ]] || { _fail "wrapper not executable: $ABPOOL_WRAPPER"; return 1; }
    [[ -x "$ABPOOL_ADMIN"   ]] || { _fail "admin not executable: $ABPOOL_ADMIN";   return 1; }
}
```

Contract step (b): "Prefer: remove the wrapper-existence check (ABPOOL_ADMIN is already checked
elsewhere or should be)." ⇒ remove the `[[ -x "$ABPOOL_WRAPPER" ]]` line (314); **KEEP** the
`[[ -x "$ABPOOL_ADMIN" ]]` line (315) — it is the ONLY executable-check for the now-sole entry
point `bin/agent-browser-pool` (downstream tests + teardown invoke it by absolute path; line
224 teardown `"$ABPOOL_ADMIN" release all`).

Contract step (e): update comments referencing 'wrapper'/'cutover'. ⇒ rewrite the 2-line
comment (312-313): "two binaries" → "sole entry point"; drop the `ABPOOL_WRAPPER` mention in
the SC2034 note; reference "explicit invocation" (PRD §2.17).

**Recommended (cleanliness):** RENAME the function `selftest_wrapper_and_admin_are_executable`
→ `selftest_admin_is_executable`. Rationale: after removing the wrapper line the name would
LIE (it no longer checks a wrapper). The rename is SAFE: the runner auto-discovers by the
`selftest_` PREFIX, so the new name is picked up with zero runner changes; no external file
references this function name (verified: `grep -rn selftest_wrapper_and_admin_are_executable`
→ only its own definition). Keeping the old name is also acceptable IF the wrapper line +
comment are fixed — but the rename is preferred for honesty.

---

## 6. ALL "wrapper"/"cutover" references in validate.sh (which to touch, which to LEAVE)

`grep -niE 'wrapper|cutover|passthrough|safety.?valve' test/validate.sh` returns:

| Line | Text | Action |
|---|---|---|
| 26 | `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` | **DELETE** (the var def) |
| 311 | `selftest_wrapper_and_admin_are_executable() {` | **RENAME** → `selftest_admin_is_executable` (recommended) |
| 313 | comment "Also consumes ABPOOL_WRAPPER/ABPOOL_ADMIN …" | **REWRITE** (drop WRAPPER) |
| 314 | `[[ -x "$ABPOOL_WRAPPER" ]] …` | **DELETE** (the wrapper check) |
| 347 | "cutover safety-valve contract (PRD §2.17)" | **DELETED WITH** the DISABLE function (it's inside that function's comment) |
| 427,429,454,458,469,488,500,519 | `pool_wrapper_main` (comments + invocations) | **LEAVE — UNRELATED.** `pool_wrapper_main` is a LIBRARY function (lib/pool.sh) that dispatches DRIVING commands (it "wraps" the real binary invocation). It has NOTHING to do with the deleted `bin/agent-browser` PATH-shadow shim. Removing these would break the close/connected selftests. |

> **GOTCHA for the implementer:** `grep 'wrapper'` will STILL return ~8 lines after a perfect
> edit — all `pool_wrapper_main` references, which are CORRECT and must stay. The validation
> must key on `ABPOOL_WRAPPER` (the variable), `AGENT_BROWSER_POOL_DISABLE`/`POOL_DISABLE`, and
> the deleted function NAME — NOT on the bare substring "wrapper".

---

## 7. shellcheck baseline (what "clean" means here)

`shellcheck -s bash test/validate.sh` currently exits 1 with ONLY **info-level** pre-existing
findings (all INTENTIONAL / unrelated to this item):
- SC1091 (info) line 30 — `source ../lib/pool.sh` (the `-x` follow directive; expected).
- SC2016 (info) lines 634, 664, 694, 726 — the deliberate single-quoted `bash -c '…'`
  hermetic subshells in the chrome/launch selftests (the `$1` etc. must NOT expand in the
  parent — that is the whole point; expected).

⇒ The validation gate is **NOT** "shellcheck exits 0" (it never did). It is:
1. **No NEW error/warning-level findings** introduced by this edit.
2. **No SC2034** ("ABPOOL_WRAPPER appears unused") — would fire if the var def (line 26)
   remained but the reference (line 314) was removed.
3. **No SC2154** ("ABPOOL_WRAPPER is referenced but not assigned") — would fire if the
   reference remained but the var def was removed.
4. Only the SAME pre-existing SC1091/SC2016 infos remain.

This makes shellcheck a STRONG gate: any half-edit (remove def but leave reference, or
vice-versa) is caught.

---

## 8. Scope boundary — files this item does NOT touch

- **`test/transparency.sh`** — ALSO references `ABPOOL_WRAPPER` (and is a 502-line rewrite of
  invocations + passthrough→fail-fast tests). That is **P2.M5.T2.S1** (separate item). OUT OF
  SCOPE here.
- `test/concurrency.sh`, `test/release_reaper.sh` — comment updates only; **P2.M5.T3.S1**.
- `lib/pool.sh`, `bin/*`, `install.sh`, `*.md` skills/repo README — each owned by a
  completed/sibling/later item. NOT touched here.
- `PRD.md`, `plan/**/prd_snapshot.md`, `plan/**/tasks.json`, `.gitignore` — READ-ONLY.

**This item edits exactly ONE file: `test/validate.sh`.**

---

## 9. Validation strategy (static-only — AGENTS.md §1/§6)

Contract step (f): `bash -n test/validate.sh` + `shellcheck -s bash test/validate.sh`.

- `bash -n` — syntax (catches a dangling brace / broken edit). Baseline: **OK**.
- `shellcheck -s bash` — lint (catches SC2034/SC2154 for a half-removed ABPOOL_WRAPPER; see §7).
- `grep` assertions — verify the removals (ABPOOL_WRAPPER → 0; POOL_DISABLE /
  AGENT_BROWSER_POOL_DISABLE → 0; the deleted function name → 0; "cutover" → 0) and that
  ABPOOL_ADMIN is PRESERVED (line 27 def + line 224 teardown + the kept admin check).
- `git status --short` — scope check: only `test/validate.sh` modified by THIS item.

**Do NOT run `bash test/validate.sh` (the selftest suite) as a required gate.** Rationale:
(a) the contract lists only `bash -n` + `shellcheck`; (b) `_run_selftest_suite` calls `setup()`
which spawns a REAL sim-owner process (`spawn_sim_owner`) — a sandbox-wedge risk per AGENTS.md
§1/§3/§4, acceptable ONLY in a fully isolated container/bwrap/temp-tree; (c) this is a pure
REMOVAL — the remaining selftests' LOGIC is unchanged, so static checks are authoritative. An
optional isolated-sandbox selftest run may be done for extra confidence but is NOT required and
NOT part of the gate.

---

## 10. Net edit map (4 edits, all in test/validate.sh)

| # | Lines (current) | Change | Contract ref |
|---|---|---|---|
| E1 | 26 | DELETE the `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` line | (a) |
| E2 | 311-316 | REWRITE the `selftest_wrapper_and_admin_are_executable` function: rename → `selftest_admin_is_executable`; delete the `[[ -x "$ABPOOL_WRAPPER" ]]` line; rewrite the 2-line comment (sole entry point / explicit invocation); KEEP the `[[ -x "$ABPOOL_ADMIN" ]]` check | (b) + (e) |
| E3 | 320-323 | UPDATE the section-header comment: drop "(+ one end-to-end through pool_config_init)" — that test is being deleted | (e) |
| E4 | 346-358 | DELETE the comment block (346-349) + the `selftest_config_bool_via_pool_config_init` function (350-358) entirely; collapse the surrounding blank lines to a single separator | (c) |
| — | 763-788 (`_run_selftest_suite`) | **NO CHANGE** — auto-discovery removes the deleted fn automatically | (d) auto-satisfied |

All four edits are captured verbatim in the PRP's §Implementation Blueprint.
