# PRP — P3.M1.T1.S3: Update fail-fast message to name supported harnesses

**Parent plan:** P3 (Multi-Harness Owner Resolution, Decision O9) → M1 (Core generalization, `lib/pool.sh`) → T1 → **S3**
**Scope:** ONE subtask. A **pure string/comment change** to the fail-fast `pool_die` message in `pool_wrapper_main` (1 message line + 2 comment lines) + a Mode-A docs sweep (1 inline quote in `configuration.md`, 1 bold quote in `SKILL.md` §4, 3 phrasings in the skill `README.md`). **NO condition change, NO logic change, NO behavior change.** Does NOT touch `test/*` (the test-poll fix is P3.M2.T1.S3) or the root `README.md` (P3.M3.T1.S1).
**Upstream dependency:** P3.M1.T1.S2 — **LANDED (docs verified on disk).** S2 generalized the owner-resolution *prose* (`configuration.md` L54/55/82/122, `SKILL.md` L20/36/58/87/136/138) and **explicitly deferred the fail-fast MESSAGE TEXT** to S3. S3 consumes the post-S2 file state (see `research/findings.md` FINDING 2–3).

---

## Goal

**Feature Goal:** The fail-fast error shown when a driving command has no recognized-harness ancestor now **names the supported harnesses** (`pi/claude/codex/agy`) instead of saying "require a pi ancestor (owning pi process)". The accompanying code comment and the skill docs mirror the new wording. The fail-fast *condition* (`POOL_OWNER_PID == 0`) and the second message line ("For raw browser use…") are byte-identical.

**Deliverable:**
1. **`lib/pool.sh`** — in `pool_wrapper_main` step-d: change the `pool_die` first-line text (1 line) + rephrase the 2-line comment above it. Condition + 2nd line unchanged.
2. **`.agents/skills/agent-browser-pool/references/configuration.md`** — update the inline `pool_die` message quote (the one phrase S2 deferred).
3. **`.agents/skills/agent-browser-pool/SKILL.md`** — update the §4-pitfalls bold quote ("outside `pi`"). (S2 already did the rest of §4.)
4. **`.agents/skills/agent-browser-pool/README.md`** — 3 phrasings (1 required, 2 optional).

**Success Definition:** `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` both rc 0; the fail-fast message reads `…require a supported agent harness (pi/claude/codex/agy).`; the step-d comment says "recognized-harness ancestor"; the fail-fast condition and 2nd line are unchanged; the three docs mirror the new wording; a grep finds no stale `pi ancestor` in the message locations of the touched files.

---

## Why

- **Delivers P3 / Decision O9 at the user-facing surface.** S1 added the configurable harness set; S2 made resolution use it; **S3 makes the error message tell the user the truth** — that any of `pi/claude/codex/agy` is accepted, not just `pi`. Without S3, a Claude/Codex/AGY user who somehow lacks a recognized-harness ancestor gets a message that still says "require a pi ancestor", which is now false and actively misleading (PRD §2.4 step 1, §1.1, Decision O9).
- **Truthfulness of the contract.** PRD §2.4 step 1 defines the fail-fast text as `"requires a supported agent harness (pi/claude/codex/agy)"`. Today the shipped text says "pi ancestor". S3 reconciles code ↔ PRD ↔ docs.
- **Unblocks the test update.** P3.M2.T1.S3 ("Update transparency.sh fail-fast poll") depends on S3's new message text existing — it cannot update the poll substring until the message is finalized here.

---

## What

### Visible behavior

- A driving command with **no** recognized-harness ancestor still fails fast (exit 1) — identical control flow.
- The **stderr/log message** now reads:
  ```
  agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy).
  For raw browser use without pooling, call 'agent-browser' directly.
  ```
  (was: `…require a pi ancestor (owning pi process).` on line 1; line 2 unchanged.)
- Nothing else changes: pool verbs, lane acquisition, owner resolution, lease identity — all untouched.

### Success criteria

- [ ] `pool_die` first-line text == `…require a supported agent harness (pi/claude/codex/agy).` (exactly, incl. the harness list)
- [ ] `pool_die` 2nd line `"For raw browser use without pooling, call 'agent-browser' directly."` **verbatim unchanged**
- [ ] Fail-fast **condition** `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then` **unchanged**
- [ ] Step-d comment says "recognized-harness ancestor" (both the `→ fail-fast` line and the `==0 ⇒ caller has no …` line)
- [ ] `configuration.md` inline `pool_die` quote mirrors the new text
- [ ] `SKILL.md` §4 bold quote no longer says "outside `pi`"
- [ ] skill `README.md` line ~16 says "supported-harness ancestor"
- [ ] `bash -n lib/pool.sh` ⇒ rc 0; `shellcheck -s bash lib/pool.sh` ⇒ rc 0
- [ ] No edits to `test/*`, root `README.md`, the fail-fast condition, or any logic

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this successfully?_ **Yes** — every edit is specified by **exact current (post-S2) text** (NOT line numbers — they drift), the one coordination hazard (S2 already landed overlapping docs) is resolved with an explicit done/defer split, the blast radius (test breakage) is named and fenced off to P3.M2.T1.S3, and validation is static-only. See `research/findings.md`.

### Documentation & References

```yaml
# MUST READ — load into context before editing
- file: lib/pool.sh
  why: The ONLY source file changed. pool_wrapper_main step-d is the fail-fast site.
  sections:
    - "pool_wrapper_main step-d: the comment `# --- d. owner resolution (step 1): no pi ancestor → fail-fast ---`
       + the `pool_die \"agent-browser-pool: driving commands require a pi ancestor (owning pi process).\"` line.
       NOTE: contract cited lines 3413-3416 (stale); ACTUAL is ~3425-3431 (S1/S2 shifted it). MATCH ON TEXT."
  pattern: "pool_die (lib/pool.sh:29) takes 1+ string args, logs to pool log + stderr, exit 1. Two-line form here."

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: Mode-A docs. S2 ALREADY generalized the prose (L54/55/82/122). S3 edits ONLY the inline pool_die MESSAGE quote (L55-56).
  match: "the substring `commands require a pi ancestor` inside the inline `pool_die` quote"

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: Mode-A docs. S2 ALREADY generalized §4 (L136 `require a supported agent harness`, L138 `under a supported harness (pi/claude/codex/agy)`).
       S3 edits ONLY the §4 bold quote `\"I ran a driving command outside `pi` and it errored.\"` (L135).
  gotcha: "DO NOT change L136 to 'supported-harness ancestor' — S2's wording 'supported agent harness' is already there and stands."

- file: .agents/skills/agent-browser-pool/README.md
  why: Mode-A docs. S2 did NOT touch this file → all 3 phrasings are S3's. L16 required; L11/L14 optional.

- docfile: plan/003_afc2f15931ab/P3M1T1S3/research/findings.md
  why: Verified research for THIS subtask — esp. FINDING 2 (S2 landed), FINDING 3 (done/defer split), FINDING 4 (test blast radius).

- file: plan/003_afc2f15931ab/P3M1T1S2/PRP.md
  why: S2 CONTRACT (LANDED). Its Task 7/8 define what S2 already did to configuration.md/SKILL.md and explicitly deferred
       the fail-fast message text to S3. Confirms the post-S2 state S3 consumes.

- prd: PRD.md §2.4 step 1 (fail-fast text: "requires a supported agent harness (pi/claude/codex/agy)"), Decision O9 (§4)
  why: The authoritative message wording.

- file: AGENTS.md
  why: Operating rules. PLANNING/IMPL: STATIC checks only (bash -n, shellcheck, grep). Do NOT boot Chrome or run the
       test suite against the shared sandbox. (The suite WILL break until P3.M2.T1.S3 — that's expected, not a regression to chase.)
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh                                              # ← EDIT pool_wrapper_main step-d (1 msg + 2 comment lines)
.agents/skills/agent-browser-pool/references/configuration.md   # ← EDIT inline pool_die quote ONLY (rest S2-done)
.agents/skills/agent-browser-pool/SKILL.md               # ← EDIT §4 bold quote ONLY (rest S2-done)
.agents/skills/agent-browser-pool/README.md              # ← EDIT 3 phrasings (S2 untouched this file)
README.md                                                # read-only (root project README → P3.M3.T1.S1)
test/transparency.sh                                     # read-only (poll fix → P3.M2.T1.S3; WILL break by design)
```

### Desired codebase tree (files touched)

```bash
lib/pool.sh                                              # 1 message line + 2 comment lines (no logic/condition change)
.agents/skills/agent-browser-pool/references/configuration.md   # 1 inline quote substring
.agents/skills/agent-browser-pool/SKILL.md               # 1 §4 bold quote
.agents/skills/agent-browser-pool/README.md              # 3 phrasings (1 req + 2 opt)
# No new files. No tests added/edited.
```

### Known gotchas of our codebase & library quirks

```bash
# CRITICAL — match on EXACT TEXT, never line numbers. Contract cited 3413-3416; ACTUAL is ~3425-3431 (S1/S2 shifted it).
# The step-d block is small + unique; pin edits by substring.

# CRITICAL — DO NOT change the fail-fast CONDITION. `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then` stays byte-identical.
# Only the pool_die MESSAGE TEXT (line 1) + the 2 comment lines change. Line 2 of pool_die stays verbatim.

# CRITICAL — S2 ALREADY LANDED the overlapping docs. configuration.md L54/55/82/122 and SKILL.md L20/36/58/87/136/138
# are ALREADY generalized. S3 must NOT re-edit them (would conflict / produce a 3rd wording). S3's docs edits are the
# NARROW set in FINDING 3 (the message quote in configuration.md, the bold quote in SKILL.md, all of the skill README).

# CRITICAL — DO NOT touch test/* . test/transparency.sh polls for the literal substring "pi ancestor" (~8 active sites);
# changing the message WILL break it. That break is EXPECTED; the fix is the downstream subtask P3.M2.T1.S3.
# Do NOT "fix" the test here — out of scope, and editing test/ from S3 violates the task split.

# CRITICAL — DO NOT touch root README.md (agent-browser-pool/README.md). It has its own "pi ancestor" callouts
# (L278/290/318/321/323/327) owned by P3.M3.T1.S1. S3 edits only the SKILL README (.agents/skills/.../README.md).

# GOTCHA — the new message is still a plain double-quoted bash string literal (no $, `, \, or ! that need escaping).
# "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." — quotes safely.
# bash -n + shellcheck will be rc 0 (verified on current file; the substitution cannot introduce a quoting bug).

# GOTCHA — the harness list in the message is "pi/claude/codex/agy" (4 names). This MATCHES the PRD §2.4 step 1 text
# and the message wording in the contract. Note the DEFAULT harness SET (§2.11 / POOL_HARNESSES) is 5 names
# (pi,claude,codex,agy,antigravity) — but the MESSAGE names only the 4 the PRD message names. Keep the message to 4
# (pi/claude/codex/agy) to match PRD §2.4 step 1 verbatim; do NOT invent a 5th.
```

---

## Implementation Blueprint

### Data models / structure

None. No logic, no data, no schema. Pure text.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lib/pool.sh — pool_die first-line message (pool_wrapper_main step-d)
  - FIND (match on TEXT; the full double-quoted first arg of pool_die):
        pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
  - REPLACE the first line ONLY with:
        pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
  - CRITICAL: keep the trailing backslash-newline; keep the SECOND line verbatim:
        "For raw browser use without pooling, call 'agent-browser' directly."
  - CRITICAL: do NOT touch the `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then` line above it.

Task 2: EDIT lib/pool.sh — rephrase the 2-line step-d comment (pool_wrapper_main)
  - 2a. FIND (the comment-header line):
        # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
  - REPLACE with:
        # --- d. owner resolution (step 1): no recognized-harness ancestor → fail-fast --------
  - 2b. FIND (the comment-explanation line directly below the header):
        # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no pi ancestor).
  - REPLACE with:
        # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no recognized-harness ancestor).
  - WHY: keep the 2-line comment internally coherent (header + explanation both say "recognized-harness ancestor").
    (The contract named only the header's "no pi ancestor → fail-fast" phrase; the explanation line is the same
    hardcoded-pi language in the same block and MUST move with it or the comment contradicts itself.)

Task 3: EDIT configuration.md — inline pool_die MESSAGE quote (S2 deferred this)
  FILE: .agents/skills/agent-browser-pool/references/configuration.md
  - FIND (the substring inside the inline quote; spans a line break, match the unique fragment):
        commands require a pi ancestor
  - REPLACE with:
        commands require a supported agent harness (pi/claude/codex/agy)
  - NOTE: S2 already changed the surrounding prose ("resolve the owning recognized-harness PID", "there is no
    recognized-harness ancestor") on the same lines — your edit target is the MESSAGE quote substring ONLY, which
    S2 left untouched. Match the substring; do not touch S2's prose.

Task 4: EDIT SKILL.md — §4 pitfalls bold quote (S2 deferred the bold quote; did the rest)
  FILE: .agents/skills/agent-browser-pool/SKILL.md
  - FIND (the bold quoted pitfall title):
        "I ran a driving command outside `pi` and it errored."
  - REPLACE with:
        "I ran a driving command outside a supported harness (`pi`/`claude`/`codex`/`agy`) and it errored."
  - DO NOT touch L136 ("require a supported agent harness") or L138 ("under a supported harness (pi/claude/codex/agy)")
    — S2 already generalized them. (Contract 5b's "require a supported-harness ancestor" wording is SUPERSEDED by
    S2's landed "supported agent harness"; do NOT introduce a 3rd wording.)
  - OPTIONAL (contract 5b parenthetical): if you want extra clarity, append to the L136 sentence:
    " — that is how your lane is keyed to you (lanes are owned by the harness process)." — but ONLY if it reads
    cleanly; the core rephrase (the bold quote) is the required deliverable.

Task 5: EDIT skill README.md — fail-fast phrasings (S2 did NOT touch this file)
  FILE: .agents/skills/agent-browser-pool/README.md
  - 5a. (REQUIRED) FIND:
        - **Pitfalls:** driving commands fail fast without a `pi` ancestor (use `agent-browser`
  - REPLACE `without a `pi` ancestor` with:
        - **Pitfalls:** driving commands fail fast without a supported-harness ancestor (use `agent-browser`
  - 5b. (OPTIONAL) FIND (the "What it covers" bullet, ~L9):
        `agent-browser-pool` command under `pi`; agents don't pass ports or `--session` (the pool
  - REPLACE `under `pi`;` with `under a supported harness;`
  - 5c. (OPTIONAL) FIND (~L11):
        owning `pi` process exits. Agents should avoid `agent-browser-pool release`/`reap`
  - REPLACE `owning `pi` process exits.` with `owning harness process exits.`
  - WHY 5a is required / 5b-5c optional: 5a directly describes the fail-fast (S3's topic); 5b-5c are incidental
    "under pi" phrasings that are consistent to fix but not strictly part of the message change.
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the fail-fast site AFTER S3 (the complete target block in pool_wrapper_main step-d):
    # --- d. owner resolution (step 1): no recognized-harness ancestor → fail-fast --------
    # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no recognized-harness ancestor).
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
                 "For raw browser use without pooling, call 'agent-browser' directly."
    fi

# PATTERN — exact-text edits are safe under the S2-landed docs because S3's match targets (the message QUOTE
# substrings) are disjoint from S2's match targets (the prose phrasings). No oldText collision.

# NON-GOALS (do NOT do these in S3):
#   - Do NOT change the fail-fast CONDITION or pool_die's 2nd line.
#   - Do NOT touch test/* (P3.M2.T1.S3 owns the transparency.sh poll update — it WILL break by design).
#   - Do NOT touch root README.md (P3.M3.T1.S1 owns the project-README phrasing sweep).
#   - Do NOT re-edit S2-landed docs prose (configuration.md L54/55/82/122; SKILL.md L20/36/58/87/136/138).
#   - Do NOT change the message to list 5 harnesses — PRD §2.4 step 1 names 4 (pi/claude/codex/agy); match it.
#   - Do NOT touch the other "pi ancestor" comments in lib/pool.sh (L419 pool_owner_resolve test-mode, L2111 acquire)
#     — out of S3's scope (other functions' domains).
```

### Integration Points

```yaml
CODE (lib/pool.sh):
  - pool_wrapper_main step-d: 1 message line (Task 1) + 2 comment lines (Task 2)
  - NO change to: pool_die() itself, pool_owner_resolve, the condition, any acquire/reap/lease logic, bin/*

DOCS (Mode A — ride with the work):
  - configuration.md: Task 3 (inline quote; rest already S2-done)
  - SKILL.md:          Task 4 (§4 bold quote; rest already S2-done)
  - skill README.md:   Task 5 (3 phrasings; S2 untouched)

NO CHANGES TO:
  - test/* (P3.M2.T1.S3), root README.md (P3.M3.T1.S1), the fail-fast condition, any logic, install.sh,
    PRD.md, tasks.json, prd_snapshot.md

DOWNSTREAM (expected, not S3's job):
  - P3.M2.T1.S3 will update test/transparency.sh to poll for a substring of the NEW message
    (e.g. "supported agent harness" or "driving commands require") instead of the now-gone "pi ancestor".
```

---

## Validation Loop

> **AGENTS.md compliance:** EVERY gate below is STATIC. None boots Chrome, launches a daemon,
> touches the live `$HOME`/Chrome, or runs the test suite. They cannot hang the sandbox.
> **Do NOT run `test/transparency.sh` or any `test/*` suite** — it WILL fail until P3.M2.T1.S3
> lands (by design), and AGENTS.md §1 forbids running the suite against the shared sandbox during impl anyway.

### Level 1: Syntax & Lint (MANDATORY — contract point 4)

```bash
bash -n lib/pool.sh               && echo "syntax OK"
shellcheck -s bash lib/pool.sh    && echo "shellcheck OK"
# Expected: both OK, rc 0. The edits are plain string/comment substitutions (no quoting/brace change),
# so a regression here would be surprising — if one appears, READ the message and fix; do not blanket-disable.
```

### Level 2: Message-text + condition read-check (static — guards scope)

```bash
# (a) The new first-line message is present, the 2nd line is verbatim, and the CONDITION is unchanged.
grep -n 'require a supported agent harness (pi/claude/codex/agy)' lib/pool.sh   # → exactly 1 hit (pool_die line)
grep -n "For raw browser use without pooling, call 'agent-browser' directly." lib/pool.sh   # → exactly 1 hit (unchanged)
grep -n 'POOL_OWNER_PID:-0}.*== "0"' lib/pool.sh   # → exactly 1 hit (the UNCHANGED condition)
# Expected: each grep → 1 hit. If the condition grep returns 0 hits, you accidentally edited it — revert.

# (b) No stale "pi ancestor" remains in the MESSAGE or the step-d comment.
grep -n 'require a pi ancestor\|no pi ancestor\|caller has no pi ancestor' lib/pool.sh
# Expected: 0 hits. (Other "pi ancestor" comments at L419/L2111 may remain — out of scope; leave them.)
```

### Level 3: Docs consistency grep (static)

```bash
# configuration.md: the inline quote is updated; the message phrase "pi ancestor" is GONE from this file.
grep -n 'require a pi ancestor\|pi ancestor' .agents/skills/agent-browser-pool/references/configuration.md
# Expected: 0 hits. (S2 already cleared the prose; S3 clears the quote → file is clean of "pi ancestor".)

# SKILL.md: the §4 bold quote no longer says "outside `pi`".
grep -n 'outside `pi`\|pi ancestor' .agents/skills/agent-browser-pool/SKILL.md
# Expected: 0 hits. (S2 already cleared the rest; S3 clears the bold quote.)

# skill README.md: "fail fast without a supported-harness ancestor" present; no "without a `pi` ancestor".
grep -n 'supported-harness ancestor\|without a `pi` ancestor' .agents/skills/agent-browser-pool/README.md
# Expected: ≥1 hit for 'supported-harness ancestor'; 0 hits for 'without a `pi` ancestor'.
```

### Level 4: Scope-fence grep (static — prove you did NOT exceed scope)

```bash
# (a) test/ untouched (the poll still says "pi ancestor" — P3.M2.T1.S3 will fix it later).
grep -c '"pi ancestor"' test/transparency.sh   # → >0 (UNCHANGED — do not "fix" it here)
# (b) root README.md untouched (still has its "pi ancestor" callouts — P3.M3.T1.S1 owns them).
grep -c 'pi ancestor' README.md                 # → >0 (UNCHANGED)
# Expected: both counts >0, confirming S3 respected the task boundaries.
```

---

## Final Validation Checklist

### Technical validation
- [ ] `bash -n lib/pool.sh` ⇒ rc 0
- [ ] `shellcheck -s bash lib/pool.sh` ⇒ rc 0
- [ ] Level 2 grep: new message present (1 hit); 2nd line unchanged (1 hit); condition unchanged (1 hit); no stale "pi ancestor" in message/comment (0 hits)
- [ ] Level 3 docs grep: configuration.md, SKILL.md clean of "pi ancestor"; skill README.md has "supported-harness ancestor"
- [ ] Level 4 scope-fence grep: `test/transparency.sh` and root `README.md` UNCHANGED (counts >0)

### Feature validation
- [ ] `pool_die` first line == `…require a supported agent harness (pi/claude/codex/agy).` (4 harnesses, matches PRD §2.4 step 1)
- [ ] `pool_die` 2nd line `"For raw browser use without pooling, call 'agent-browser' directly."` verbatim
- [ ] Fail-fast condition `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then` unchanged
- [ ] Step-d comment (both lines) says "recognized-harness ancestor"
- [ ] configuration.md inline quote + SKILL.md §4 bold quote + skill README.md (≥ line 16) mirror the new wording

### Code quality
- [ ] Edits matched on EXACT TEXT (not line numbers); line drift from S1/S2 did not cause a miss
- [ ] S2-landed docs prose left untouched (no 3rd wording introduced; no conflict)
- [ ] Scope respected: no edits to the condition, test/*, root README.md, any logic, PRD/tasks.json/snapshots

### Documentation
- [ ] configuration.md message quote updated; SKILL.md §4 bold quote updated; skill README.md updated
- [ ] No stale "pi ancestor" in the fail-fast message locations of the touched files

---

## Anti-Patterns to Avoid

- ❌ **Do NOT change the fail-fast CONDITION or pool_die's 2nd line** — only the 1st message line + the 2 comment lines change.
- ❌ **Do NOT edit by line number** — contract cited 3413-3416 (stale); actual is ~3425-3431. Match exact text.
- ❌ **Do NOT re-edit S2-landed docs** (configuration.md L54/55/82/122; SKILL.md L20/36/58/87/136/138) — they are already generalized; re-editing risks a conflicting 3rd wording. S3 edits only the message QUOTE / bold quote (FINDING 3).
- ❌ **Do NOT touch `test/*`** — test/transparency.sh polls "pi ancestor" and WILL break; that fix is P3.M2.T1.S3 (downstream). Running the suite to "verify" is both forbidden (AGENTS.md §1) and guaranteed to fail.
- ❌ **Do NOT touch root `README.md`** — its "pi ancestor" callouts are P3.M3.T1.S1's. S3 edits only the skill README (`.agents/skills/agent-browser-pool/README.md`).
- ❌ **Do NOT invent a 5-harness message** — PRD §2.4 step 1 names 4 (`pi/claude/codex/agy`). Match it verbatim even though the default `POOL_HARNESSES` set has 5 (incl. antigravity).
- ❌ **Do NOT boot Chrome / run the suite** — static gates (bash -n, shellcheck, grep) are the entire validation (AGENTS.md §1).
- ❌ **Do NOT blanket-`# shellcheck disable`** — the edits cannot introduce a shellcheck finding; if one appears, read and fix the root cause.

---

**Confidence score: 9/10** for one-pass implementation success. The change is minimal and local
(one `pool_die` line + two comment lines + three narrow docs edits), every match target is pinned
to exact current (post-S2) text (line-drift-proof), the S2 coordination hazard is resolved with an
explicit done/defer split, and the blast radius (test breakage) is fenced to the correct downstream
subtask. The -1 reserves for an implementer who (a) edits by line number despite the warning, or
(b) "helpfully" also rewords the S2-landed prose / fixes the test / touches the root README — all
mitigated by the explicit NON-GOALS + the Level-4 scope-fence grep.
