# Research — P1.M4.T1.S1: README.md overview sweep for the changeset (Issues 1 & 4)

This is the **Mode B** changeset-level documentation sync. It runs LAST (depends on all
implementing subtasks) and sweeps README.md **narrative/overview** sections that span
multiple issues. **Per-file docs (env var table, help text, inline comments) were already
updated in Mode A** by the implementing subtasks — this task does NOT re-touch them.

---

## §0. Scope determination — which issues touch README narrative?

| Issue | Fix (subtask) | README narrative impact? |
|---|---|---|
| **1** (boolean env vars accept `1/true/yes/on`) | P1.M1.T1.S1 (COMPLETE) | **YES** — multiple prose mentions of `VAR=1` now under-state the accepted set. |
| **2** (port-collision race recovery) | P1.M2.T1.S1/.S2 (COMPLETE) | **NO** — internal boot-path resilience; README "How it works" lifecycle mentions "launch Chrome" generically, never "retries on EADDRINUSE". No user-visible behavior change. |
| **3** (close → rebind) | P1.M3.T1.S1/.S2 (COMPLETE) + S3 (parallel) | **NO** — user-visible behavior UNCHANGED ("close = disconnect-only; next call reuses the same browser"). The rebind is transparent. |
| **4** (bare `agent-browser` → META passthrough) | P1.M1.T2.S1 (COMPLETE) | **YES** — the README "How it works" META list omits bare invocation. (The S1 PRP explicitly deferred this to "the Mode B final task will sweep README 'How it works'.") |
| **5** (help text "if set" wording) | P1.M1.T1.S1 (COMPLETE, Mode A) | **NO** — `pool_admin_help` (lib/pool.sh) was already fixed in Mode A; README has no parallel "if set" wording. |

**Conclusion: README scope = Issue 1 (boolean truthy) + Issue 4 (bare invocation).**
Issues 2, 3, 5 have ZERO README narrative impact and are explicitly out of scope.

---

## §1. What Mode A ALREADY updated (DO NOT re-touch — skip these)

Confirmed against the current `README.md`:

- **Env var table, lines 218–220** (P1.M1.T1.S1 Mode A) — ALREADY say `1/true/yes/on`:
  ```
  | `AGENT_CHROME_HEADLESS`        | ... | set to `1`/`true`/`yes`/`on` to launch Chrome with `--headless=new` |
  | `AGENT_CHROME_ALLOW_SLOW_COPY` | ... | set to `1`/`true`/`yes`/`on` to permit a real (slow) 4.8 GB copy per acquire |
  | `AGENT_BROWSER_POOL_DISABLE`   | ... | `1`/`true`/`yes`/`on` = per-process passthrough (safety valve — see below) |
  ```
  This table is the **authoritative** value reference. **Skip it.**
- **"Three vars shape behavior most" bullets (lines 225–227)** — describe *behavior*, not the
  accepted value form. Not stale. **Skip.**
- **`pool_admin_help` in `lib/pool.sh`** (lines ~4418–4420) — already `1/true/yes/on` (Mode A).
  Not a README file. **Skip.**

---

## §2. The 7 STALE narrative edit sites (the actual work)

All line numbers verified against the current `README.md` (372 lines, mtime Jul 14).

### Issue 1 — boolean env vars now accept `1/true/yes/on` (6 sites)

Every site below currently says `VAR=1` (implying ONLY `1` works). After Issue 1 the code
accepts `1/true/yes/on` (case-insensitive), so the prose under-states the contract. The fix
mirrors the env-table form already in place (line 220).

| # | Line | Section | Current (stale) | Fix |
|---|------|---------|-----------------|-----|
| 1 | **33** | Prerequisites (item 1) | `` copy unless you set `AGENT_CHROME_ALLOW_SLOW_COPY=1`. `` | name the var + parenthetical value set |
| 2 | **60** | Installation — cutover warning | `` the only per-session opt-out is `AGENT_BROWSER_POOL_DISABLE=1`. `` | name the var + parenthetical value set (HIGH-VALUE: cutover is Issue 1's most severe impact per key_findings) |
| 3 | **236** | Safety valve (heading prose) | `` `AGENT_BROWSER_POOL_DISABLE=1` makes **this process** pass through … `` | list `1/true/yes/on` (the contract's EXPLICIT ask for this section) |
| 4 | **242** | Safety valve (code block) | `export AGENT_BROWSER_POOL_DISABLE=1` | add an inline comment noting all truthy values work |
| 5 | **254** | How it works — "passes through unchanged when" bullet 1 | `` - `AGENT_BROWSER_POOL_DISABLE=1` (safety valve); `` | "is set to a truthy value (`1`/`true`/`yes`/`on`)" |
| 6 | **337** | Troubleshooting — "It didn't do anything" | `` …or `AGENT_BROWSER_POOL_DISABLE=1` is set in that shell. `` | "is set (to a truthy value)" |

### Issue 4 — bare `agent-browser` is now META passthrough (1 site)

| # | Line | Section | Current (stale) | Fix |
|---|------|---------|-----------------|-----|
| 7 | **255–256** | How it works — "passes through unchanged when" bullet 2 (the META list) | `` the command is a **META** command (`skills`, `--help`, `--version`, `session list`, `dashboard`, `plugin`), which need no lane; `` | append "**or a bare invocation with no subcommand** (upstream just prints help)" |

**Why only 1 site for Issue 4:** the "How it works" flow-diagram lifecycle step 3 (`META
command → passthrough`, line 273) is GENERIC and already accurate after the fix —
`pool_dispatch_classify` now classifies a bare invocation AS `meta`, so step 3 covers it.
The stale spot is the *enumerated META list* (bullet 2), which is what a reader scans to
decide "will my invocation boot Chrome?". That is the single list that must mention bare
invocation. (Verified: no other README section mentions bare/no-subcommand behavior — the
`grep -niE 'bare|no command|subcommand'` hits at lines 119/204/214 are unrelated: admin-tool
"default command", "bare `~`", and Chrome "bare name".)

---

## §3. Deliberately LEFT UNCHANGED (accurate / out of scope — document the reasoning)

| Line | Text | Why it stays |
|------|------|--------------|
| **218–220** | env var table | Mode A already correct (§1). |
| **225–227** | "Three vars shape behavior most" bullets | describe *behavior* (refuse/slow-copy/headless), NOT the accepted value form — not stale. |
| **272** | `` 2. `POOL_DISABLE=1` → passthrough (exec real binary); `` | This names the **internal normalized global** `POOL_DISABLE`, not the env var. After `pool_config_init` normalizes a truthy env value to the literal string `"1"`, the runtime gate `[[ "$POOL_DISABLE" == "1" ]]` is accurate. Changing it would conflate the env var with the internal global. LEAVE. |
| **273** | `3. META command → passthrough;` | Generic + accurate post-fix (bare invocation is now classified `meta` by dispatch). The enumerated META list (bullet 2, edit #7) is the precise spot; the diagram step is intentionally generic. LEAVE. |
| **242 (export line value)** | `export AGENT_BROWSER_POOL_DISABLE=1` | `=1` is a VALID canonical example (it still works). Only an inline COMMENT is added (edit #4), not a value change. |

---

## §4. Parallel-task non-conflict (P1.M3.T1.S3)

The parallel work item **P1.M3.T1.S3** is **TEST-ONLY** — it adds `test_close_then_rebind`
to `test/release_reaper.sh` (Issue 3 end-to-end test). It does **NOT** touch `README.md`.
`README.md` is exclusively THIS task's file (Mode B). Zero merge conflict. (Confirmed by
reading P1.M3.T1S3/PRP.md: "It does NOT touch lib/pool.sh, test/validate.sh, other test
files, or any docs.")

---

## §5. Consistency contract — every edit must match the Mode A wording

Mode A (P1.M1.T1.S1) settled the canonical value list as **`1/true/yes/on`** (the env table
line 220 + `pool_admin_help` lib/pool.sh:4418–4420). Every Issue-1 edit in §2 MUST use
exactly that token order (`1`/`true`/`yes`/`on`) — not `true/yes/on/1`, not `yes/true/on`,
not omitting `on` (the old README line 218 said `1/true/yes` and Mode A added `/on`).
Consistency across the table, help text, and narrative is the whole point of Mode B.

The chosen narrative pattern (used in all 6 Issue-1 edits for uniformity):
> name the env var, then `(`set to` `1`/`true`/`yes`/`on``)` — matching the table's
> `` `1`/`true`/`yes`/`on` `` form.

---

## §6. Validation approach for a MARKDOWN-ONLY task

There is no bash code to `bash -n`/`shellcheck` here (README.md is prose). The codebase has
no markdown linter configured. So validation is **grep assertions + manual review**:

1. **No stale exclusivity remains in scope**: after the edits, grep the narrative for the
   `VAR=1`-only form and confirm each remaining hit is either (a) the env table (already
   `1/true/yes/on`), (b) the lifecycle internal-global line 272 (deliberately kept), or (c)
   the code-block `export …=1` (canonical example, now commented).
2. **Truthy wording present**: grep for `1/true/yes/on` and confirm the narrative edits added
   it to the 6 Issue-1 sites + it's still in the table (3) + still in pool_admin_help (3).
3. **Bare-invocation mention present**: grep the META bullet for "no subcommand" / "bare".
4. **Cross-source consistency**: the README narrative now agrees with the env table (220) and
   `pool_admin_help` (lib/pool.sh) — all three say `1/true/yes/on`.
5. **Render check**: eyeball the edited sections (Prerequisites 1, cutover warning, Safety
   valve, How it works, Troubleshooting) to confirm prose still reads naturally + markdown
   table/code-block fences intact.

A final `git diff -- README.md` must show ONLY the 7 targeted hunks (no accidental reflow of
the env table, no re-wrapping of unrelated paragraphs).

---

## §7. Anti-scope reminders (do NOT do these)

- ❌ Do NOT re-edit the env table (218–220) — Mode A owns it.
- ❌ Do NOT edit `lib/pool.sh`, `test/*`, `PRD.md`, `tasks.json`, or any other file — this is
  README-only (Mode B). The per-file docs were Mode A's job.
- ❌ Do NOT add Issue 2/3/5 narrative — they have no user-visible/README behavior change.
- ❌ Do NOT rewrite whole sections — surgical token/phrase swaps only ("Update only what is
  stale — do not rewrite sections unnecessarily").
- ❌ Do NOT change the code-block `export …=1` VALUE — `=1` is valid; only ADD a comment.
- ❌ Do NOT touch line 272 (internal `POOL_DISABLE=1` global) — it is accurate (§3).
