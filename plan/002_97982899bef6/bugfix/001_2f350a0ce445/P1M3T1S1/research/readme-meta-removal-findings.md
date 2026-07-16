# Research — P1.M3.T1.S1: README.md META-removal + final consistency sweep

**Plan:** 002_97982899bef6/bugfix/001_2f350a0ce445 · **Item:** P1.M3.T1.S1 (Mode B docs)
**Method:** static analysis (grep + read) of the LIVE repo. No browsers/tests run (AGENTS.md §1).

---

## 1. Current state — what's ALREADY fixed vs. what remains (reconciled THIS session)

The `research_meta_refs.md` architecture doc was written **pre-fix**. After P1.M1 (Complete) +
P1.M1.T1.S2, the live state is:

| File | META/passthrough/dispatch_classify state | Owner |
|---|---|---|
| `lib/pool.sh` | **CLEAN of META dispatch.** `pool_dispatch_classify` + step-c block fully DELETED (grep: no `pool_dispatch_classify`, no `== "meta"`, no `class=`). The remaining `passthrough` hits are the **unrelated owner-passthrough concept** (lines ~403, 498, 581, 1005, 2089-2099, 2149: `POOL_OWNER_PID==0` no-pi-ancestor semantics) — **OUT OF SCOPE, do not touch.** | P1.M1.T1.S1/S2 ✓ |
| `bin/agent-browser-pool` | **CLEAN** (zero meta/passthrough/dispatch_classify). Its `case` (status/reap/release/doctor/--help/-h/help → admin; `*)` → pool_wrapper_main) is the sole pool-verb/driving split. | P1.M1 ✓ |
| `test/validate.sh` | **CLEAN** — `selftest_dispatch_classify_cases` DELETED (grep returns nothing). | P1.M1.T1.S2 ✓ |
| `.agents/skills/agent-browser-pool/references/configuration.md` | **CLEAN** — rewritten to "## Command dispatch: pool verbs vs. driving" (lines 44-75); "There is no 'meta / passthrough' class" (line 75). This is the CANONICAL new wording to mirror in README. | P1.M1.T1.S2 ✓ |
| `.agents/skills/agent-browser-pool/SKILL.md` | **CLEAN** — "Every command except pool verbs is a driving command" (lines 57-69); "There is no 'meta / passthrough' class" (line 68). | P1.M1.T1.S2 ✓ |
| `test/transparency.sh` | **STALE** — `test_passthrough_skills` (236) + `test_version_passthrough` (270) + header (10, 12) still assert the OLD META-passthrough model. | **P1.M2.T1.S1 (parallel — NOT mine)** |
| `README.md` | **STALE** — META refs at lines 95, 135-141, 255-256, 262-265 (diagram), 277, 316-317. Line 356 (file tree) already clean. | **THIS TASK (P1.M3.T1.S1)** |
| `test/concurrency.sh`, `test/release_reaper.sh` | CLEAN (no hits). | n/a |
| `docs/*.md` | N/A — `docs/` does not exist. | n/a |

**Conclusion:** the ONLY file MY task edits is **`README.md`**. transparency.sh is the parallel
item's job; everything else is already done. The "final consistency sweep" (LOGIC e) confirms
this and must NOT flag the parallel/owner-passthrough hits as regressions.

---

## 2. README.md — exact META locations + the fix for each (content-anchored, line# drift-safe)

### Location 1 — the "Driving commands require a pi ancestor" callout (line ~95)
**OLD:** `> ... Pool verbs (`status` / `doctor` / `reap` / `release` / `help`) and META commands work from any shell.`
**FIX:** drop "and META commands"; state the new contract. →
`> ... Pool verbs (`status` / `doctor` / `reap` / `release` / `help`) work from any shell; every other command is a driving command that requires a `pi` ancestor.`

### Location 2 — the "Classification detail" blockquote (lines ~135-141)
**OLD:** the whole blockquote listing META tokens (`--version`; `skills`/`dashboard`/`plugin`/`mcp`; `session list`; flags-only) that "pass through to the real agent-browser unchanged, acquiring no lane."
**FIX:** replace with the new model — there is no META class; pool verbs are caught by `bin/agent-browser-pool`'s case; everything else (incl. `--version`, `skills`, `mcp`, `session list`, flags-only) is a DRIVING command that resolves the owner, fails-fast without `pi`, and runs scoped to the caller's lane with `--session` stripped. Mirror configuration.md §"Command dispatch".

### Location 3 — "How it works" intro + classify diagram (lines ~255-270)
**OLD intro (255-257):** "classifies the command, then either runs a pool verb, **passes a META command through to the real binary**, or runs the lane lifecycle for a driving command"
**FIX:** drop the META clause. → "splits each invocation: a **pool verb** runs an admin function (no lane); **everything else is a driving command** that runs the lane lifecycle."
**OLD diagram (262-265):** the `META (--version, skills, …)? → passthrough to the real binary (no lane)` branch, plus `no pi ancestor → FAIL-FAST (not passthrough)`.
**FIX:** remove the META branch entirely. The diagram becomes: pool verb → run it (no lane); else DRIVING → resolve owner; no pi ancestor → FAIL-FAST → acquire/reuse lane → strip --session → force session → exec. Drop "(not passthrough)" (passthrough no longer exists as a contrast).
**OLD step 2 (277):** "classify — pool verb? META command? → handled above (no lane);"
**FIX:** → "pool verb? → handled above (no lane); otherwise driving —" (merge into the driving flow).

### Location 4 — Troubleshooting callout (lines ~316-317)
**OLD:** `... Pool verbs (`status`, `doctor`, `reap`, `release`, `help`) and META commands work from any shell.`
**FIX:** → `... Pool verbs (`status`, `doctor`, `reap`, `release`, `help`) work from any shell; all other commands are driving (they require a `pi` ancestor).`

### Location 5 — file-tree line (~356) — ALREADY CLEAN
`│   └── agent-browser-pool     ← sole entry point: pool verbs + driving router  (→ lib/pool.sh)` — **leave unchanged.**

---

## 3. The canonical NEW contract (mirror this wording — from configuration.md §"Command dispatch")

**Pool verbs** (caught by `bin/agent-browser-pool` BEFORE `pool_wrapper_main`; no lane, no owner
resolution, no Chrome): `status`, `reap`, `release [<N>|all]`, `doctor`, `--help`/`-h`/help`. A
bare `agent-browser-pool` (no args) defaults to `status`.

**Everything else → DRIVING** → `pool_wrapper_main`: resolve the owning `pi` PID; if there is no
`pi` ancestor, **fail-fast** (`pool_die`: *"agent-browser-pool: driving commands require a pi
ancestor… For raw browser use without pooling, call 'agent-browser' directly."*). Otherwise
acquire/reuse the caller's lane, strip any `--session`, force `AGENT_BROWSER_SESSION=abpool-<N>`,
and exec the real binary with the cleaned args.

**Driving now includes** (previously META-passthrough): `--version`, `skills`, `dashboard`,
`plugin`, `mcp`, `session list`, and a flags-only invocation (e.g. `--json`). **There is no
"meta / passthrough" class.**

Delta PRD authority (`plan/002_97982899bef6/delta_prd.md` line 27): *"The META/passthrough
command class … is removed … pool verbs are an explicit allowlist; everything else is a driving
command that owns a lane."* Line 36: pool verbs need no owner; driving **requires a `pi` ancestor
and fails fast** if absent.

---

## 4. The final consistency sweep (LOGIC e) — expected results AFTER this task + the parallel item

**Command:** `grep -rnE 'meta|passthrough|META|dispatch_classify' lib/pool.sh bin/agent-browser-pool test/*.sh .agents/skills/agent-browser-pool/**/*.md README.md`

After README (this task) + transparency.sh (P1.M2.T1.S1) land, the ONLY acceptable remaining hits:

1. **`lib/pool.sh` owner-passthrough** (concept #2 — UNRELATED): lines ~403, 498, 581, 1005,
   2089-2099, 2149. These describe `POOL_OWNER_PID==0` (no pi ancestor) semantics — the wrapper
   gates this as FAIL-FAST. **DO NOT TOUCH** (research_meta_refs.md §0/§4 disambiguates).
2. **"meta" as common English** in unrelated context (e.g. "metadata") — acceptable; inspect each.
3. **NONE** referencing the removed META-dispatch class, `pool_dispatch_classify`, or the
   `exec "$POOL_REAL_BIN" "$@"` unchanged passthrough.

If the sweep is run BEFORE P1.M2.T1.S1 lands, `test/transparency.sh` will still show the stale
assertions — that is EXPECTED (parallel item), not a regression this task must fix. Document this
in the PRP so the implementer doesn't "fix" the parallel item's file.

---

## 5. Scope guard (do NOT do in this task)

- ❌ Edit `test/transparency.sh` — that is **P1.M2.T1.S1** (parallel).
- ❌ Touch the owner-passthrough references in `lib/pool.sh` (concept #2 — unrelated; the sweep
  must NOT flag them).
- ❌ Do the BROADER README rewrite (master-profile→real-chrome-udd, `AGENT_BROWSER_POOL_DISABLE`
  removal, cutover/install rewrite). delta_prd.md line 97 describes a larger README overhaul, but
  THIS item is scoped strictly to **META-passthrough references + the meta/passthrough/dispatch_classify sweep**. (DISABLE/master/cutover are separate concerns; if present they are out of scope here.)
- ❌ Edit `configuration.md` / `SKILL.md` / `validate.sh` / `bin/agent-browser-pool` — already clean.
- ❌ Edit any code (`lib/pool.sh`, `bin/*`). This is a Mode-B docs-only task.
