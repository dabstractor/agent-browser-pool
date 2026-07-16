# Research Notes — P1.M1.T4.S1 (docs accuracy sweep post-fix)

> Research artifact for the implementer. The authoritative, self-contained contract is
> `../PRP.md`. This file holds the per-location verdict table + code evidence gathered during
> the sweep. The implementer should CONFIRM each verdict against the live tree, then perform
> the 2 targeted updates (and may append the final "what changed" log here).

## 0. Preconditions verified (all 3 code fixes are ALREADY applied to the working tree)

`lib/pool.sh` is **4611 LOC** in the working tree. Static checks only (AGENTS.md §1). All three
fixes are confirmed present — this subtask reviews the FINAL state, not a hypothetical one.

| Fix | Evidence (content grep, line numbers are orientation) | Status |
|-----|--------------------------------------------------------|--------|
| Issue 1 (reaper anchored `pgrep`/`pkill`) | `lib/pool.sh:2925`: `local pat="user-data-dir=$dir( |\$)"` (anchored to lane-dir boundary); the comment block at `:2908-2917` documents the prefix-collision rationale. | ✅ applied (T1.S1) |
| Issue 2 (doctor `ss` optional) | `lib/pool.sh:4290`: `for dep in flock setsid pgrep pkill cp curl jq findmnt; do` (NO `ss` in FAIL loop). `:4340`: `printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' "ss"`. Docstring `:4200/4209/4210` lists `ss` as optional. | ✅ applied (T2.S1) |
| Issue 3 reconnect (S1) | `lib/pool.sh:2581`: `&& ! pool_cdp_is_ours "$port" "$ephemeral_dir" "$chrome_pid"; then` (identity gate on the reconnect branch). | ✅ applied (T3.S1) |
| Issue 3 relaunch (S2) | `lib/pool.sh:2620`: `if ! pool_wait_cdp "$port" "$ephemeral_dir" "${POOL_CHROME_PID:-}"; then` (3 args → identity ON). NO 1-arg `pool_wait_cdp "$port"` call remains in `pool_ensure_connected`. Docstrings `:1671`/`:1614` updated. | ✅ applied (T3.S2) |

**Implication for THIS subtask**: the docs must be reconciled against the final, fixed behavior.
The `ss`-is-optional behavior (Issue 2) is the one fix that has a changeset-level doc surface
that is now *incomplete/inaccurate* (the README lists the optional deps but omits `ss`). Issues
1 and 3 are internal hardening with no user-facing behavior change, so their doc surfaces are
either still accurate or only "more accurate than before."

## 1. Per-location verdict (the sweep)

### README.md

| § | Location (line) | Current text | Verdict | Action |
|---|-----------------|--------------|---------|--------|
| Prerequisites | §Dependencies `:47-48` | "`...required (\`flock\`, \`setsid\`, \`pgrep\`, \`pkill\`, \`cp\`, \`curl\`, \`jq\`; \`notify-send\` is optional).`" | **NOW INACCURATE** — Issue 2 made `ss` optional; the prose omits it. (Also pre-existing: `findmnt` is required+printed by `doctor` but unlisted.) | **UPDATE**: add `ss` to the optional note (in-scope). Recommend also adding `findmnt` to the required list (adjacent accuracy fix). |
| Admin / `doctor` | `[dependencies]` example block `:230-231` | "`[dependencies]   flock, setsid, pgrep, pkill, cp, curl, jq, chrome → OK / MISSING;`<br>`                 notify-send → OK / MISSING (optional)`" | **NOW INACCURATE** — the rendered example omits the `ss` optional line the code now emits (`:4340`). (Also pre-existing: omits `findmnt`.) | **UPDATE**: add the `ss` optional line so the example matches actual output (in-scope). Recommend also adding `findmnt` (adjacent). |
| Admin / `doctor` | "Exits `0` if healthy, `1` only if a blocking infrastructure check **fails**." `:224` | unchanged prose | **NOW ACCURATE (and more so than before)** — before Issue 2, `ss` absence wrongly triggered exit 1, contradicting this claim; after Issue 2 the claim is finally true. | **NO CHANGE** — verify + note the fix made a pre-existing claim correct. |
| Admin / `reap` | "`...killing any orphaned Chrome still pointed at them). Always exits 0.`" `:193` | unchanged prose | **ACCURATE** — Issue 1 changed HOW the orphan kill is *scoped* (anchored pattern), not the behavior ("kill the orphan's own Chrome"). The anchored fix makes "any orphaned Chrome still pointed at them" *more* literally true (no longer also hits prefix-colliding live lanes). | **NO CHANGE** — verify + note. |
| How it works | lifecycle item 6 `:320` — "`pool_ensure_connected` (reconnect if the daemon died)" | unchanged prose | **ACCURATE** — high-level summary. Issue 3 hardening is defense-in-depth; the summary is not misleading (the fn still reconnects; it now verifies identity first). | **NO CHANGE** — verify + note (item contract (c) agrees). |
| Troubleshooting / Leaks | "`reap` ... removes orphan dirs" `:381`; "`doctor` exits `1` only on a blocking `FAIL`" `:383` | unchanged prose | **ACCURATE** — Issue 2 makes the doctor exit-code claim finally true. | **NO CHANGE** — verify + note. |

### `.agents/skills/agent-browser-pool/` (skill docs)

| File | Claim | Verdict | Action |
|------|-------|---------|--------|
| `SKILL.md` §2 teardown (`:87-88`) | "the Chrome **process group** is killed, the ephemeral profile directory is deleted, and the lease is dropped" | **ACCURATE** — describes release/stale-reap lease-driven teardown (which was never buggy; Issue 1 was the orphan-dir sweep, a different code path). No dependency list; no ensure_connected/identity claim. | **NO CHANGE** |
| `references/configuration.md` troubleshooting (`:129`) | "`reap` clears stale lanes **and** orphan dirs" | **ACCURATE** — true; no orphan-matching detail contradicted. | **NO CHANGE** |
| `references/configuration.md` admin CLI (`:144`) | "`doctor` ... (exits 1 on a blocking FAIL only; WARNs are advisory)" | **ACCURATE** (now more so — Issue 2 fix). No dependency list; no identity claim. | **NO CHANGE** |
| `README.md` (skill) | high-level overview; mentions `reap`/`release` as operator tools, no deps/identity/orphan-matching detail | **ACCURATE** | **NO CHANGE** |

## 2. Net change set (what the implementer actually edits)

Exactly **TWO prose regions, both in `README.md`**, both driven by Issue 2 (`ss` is now
optional). Issues 1 & 3 require **no** changeset-level doc change (verified accurate).

1. `README.md:47-48` — Prerequisites §Dependencies: add `ss` (in-scope) + `findmnt` (adjacent)
   to match the required/optional split the code enforces.
2. `README.md:230-231` — Admin/`doctor` `[dependencies]` example block: add the `ss` optional
   line (+ `findmnt` to the required list) so the rendered example matches actual `doctor`
   output.

Plus a verification log (each file checked + verdict) — recorded above in §1 and to be
re-confirmed by the implementer against the live tree.

## 3. Scope discipline (DO NOT)

- Do NOT touch `lib/pool.sh`, `bin/*`, `install.sh`, `test/*`, `PRD.md`, `AGENTS.md`,
  `plan/**/tasks.json`, `prd_snapshot.md`, `.gitignore`. (This is the doc task; code is done.)
- Do NOT "improve" prose beyond the accuracy fixes — the item contract (point 3) explicitly says
  "If a doc file is ALREADY accurate, do NOT change it. This is a verification + targeted update,
  not a rewrite."
- Do NOT add Issue-1/Issue-3 narrative to the docs (they are internal hardening with no
  user-facing behavior change; the existing high-level summaries already cover them accurately).

## 4. Validation approach (lightweight — it is a 2-line-region markdown edit)

- `grep -n 'ss' README.md` confirms the new optional note + example line are present.
- `git diff -- README.md` is SMALL (only the Prerequisites + doctor-example regions).
- `git diff --stat -- lib/pool.sh bin/ install.sh test/` is EMPTY (code untouched).
- Code-fence balance sanity on README.md (the doctor example block is a fenced ``` block).
- Optional: `npx markdownlint-cli2 README.md` if available (not required).

## 5. Final sweep result (implemented 2026-07-16)

Re-confirmed every §1 verdict against the live tree (`lib/pool.sh` is 4611 LOC; all 3 fixes
present — Task-0 greps matched: Issue 1 anchored pat at `:2925`, Issue 2 `ss`-optional loop
at `:4290` + printf at `:4340`, Issue 3 reconnect gate at `:2581` + relaunch 3-arg call at
`:2620`, no 1-arg `pool_wait_cdp "$port"` remains).

**Variant applied**: RECOMMENDED (`ss` + `findmnt`) for BOTH edits — the code genuinely
requires+prints `findmnt` (`pool_check_btrfs` `pool_die`s without it; doctor FAIL loop at
`:4290` includes it), so adding it closes a pre-existing accuracy gap alongside the in-scope
`ss`-optional fix.

- README.md §Prerequisites Dependencies (Task 1): RECOMMENDED variant — added `findmnt` to the
  required list and `and \`ss\`` to the optional clause.
- README.md §doctor `[dependencies]` example block (Task 2): RECOMMENDED variant — added
  `findmnt` to the required line and appended `ss → OK / MISSING (optional; port-probe degrades
  to curl-only)` to the optional line (mirrors `lib/pool.sh:4340` printf wording).
- All other 7 checked surfaces (README §doctor exit-code `:224`, §reap `:193`, §internals `:320`,
  §troubleshooting `:381`/`:383`; SKILL.md `:87-88`; configuration.md `:129`/`:144`; skill
  README.md): ACCURATE, unchanged — verdicts re-confirmed live in §1.
- Code untouched: `git diff --stat -- lib/pool.sh bin/ install.sh test/ PRD.md AGENTS.md` empty;
  only README.md changed among shipped docs.
- README.md code fences balanced (36, even); markdownlint introduced **no NEW** violations
  (line-keyed diff of edited-vs-baseline violations = empty; total rose 156→157 only because the
  added `ss` line shifted attribution of pre-existing MD013 line-length issues, not new rules).

Net: 2 prose regions edited in README.md (4 insertions / 4 deletions, both fenced/lined-up
correctly). This is the final documentation task for the 3-fix suite — item contract point 5.
