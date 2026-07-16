# PRP — P1.M3.T1.S1: Update README.md META references + final consistency sweep

> **Bugfix context**: This subtask is the **documentation half of Issue 1/3** (META-passthrough
> removal) from the QA report
> (`plan/002_97982899bef6/bugfix/001_2f350a0ce445/TEST_RESULTS.md`). The **code** half is DONE:
> P1.M1.T1.S1 deleted the step-c META-passthrough block from `pool_wrapper_main`; P1.M1.T1.S2
> deleted `pool_dispatch_classify` + its obsolete selftest AND already synced
> `configuration.md` + `SKILL.md` to the new "pool verbs vs driving" model. P1.M2.T1.S1
> (IN PARALLEL — treated as a CONTRACT) is replacing the stale META assertions in
> `test/transparency.sh`. **THIS task (P1.M3.T1.S1) is the final doc sweep: remove every
> META-passthrough reference from `README.md` and confirm the whole repo is consistent.** It is
> Mode-B (docs-only): it edits **only `README.md`** (no code, no tests, no other docs — those are
> already clean or owned by the parallel item).

---

## Goal

**Feature Goal**: Make `README.md` describe the **post-pivot dispatch model** — "pool verbs vs
driving" with **no META/passthrough class** — so the user-facing docs match the shipped code
(META dispatch was removed for lane isolation: a caller-supplied `--session <X>` must never
target another agent's lane). Today README still tells readers that `--version`, `skills`,
`dashboard`, `plugin`, `mcp`, `session list`, and flags-only invocations "pass through to the
real `agent-browser` unchanged, acquiring no lane" — the exact behavior the code fix removed
(QA Issue 1/3). After this task, README states that those tokens are **driving commands** that
resolve the owner, fail-fast without a `pi` ancestor, and run scoped to the caller's own lane.

**Deliverable** (edits to ONE file — `README.md`; + a repo-wide consistency check):
1. **Location 1** (~line 95): drop "and META commands" from the "Driving commands require a pi
   ancestor" callout; state the new contract.
2. **Location 2** (~lines 135-141): replace the "Classification detail" blockquote (the META token
   list) with the new pool-verbs-vs-driving model.
3. **Location 3** (~lines 255-270 + step 2 at ~277): rewrite the "How it works" intro + classify
   diagram — **remove the META branch entirely**; merge step 2 into the driving flow.
4. **Location 4** (~line 316): drop "and META commands" from the Troubleshooting callout.
5. **Final consistency sweep**: `grep -rnE 'meta|passthrough|META|dispatch_classify'` across the
   repo and confirm the ONLY remaining hits are (i) the unrelated **owner-passthrough** concept in
   `lib/pool.sh` (DO NOT TOUCH), (ii) "meta" as common English, and — if run before the parallel
   item lands — the expected stale hits in `test/transparency.sh` (P1.M2.T1.S1's job).

**Success Definition**:
- `README.md` contains **zero** references to a META command class, META passthrough, or
  `pool_dispatch_classify`. `grep -nE 'META|passthrough|dispatch_classify' README.md` returns nothing.
- README's dispatch description matches `configuration.md` §"Command dispatch: pool verbs vs.
  driving" (the canonical wording already shipped by P1.M1.T1.S2): pool verbs
  (status/reap/release/doctor/help) work from any shell; **everything else is a driving command**
  requiring a `pi` ancestor (fail-fast without one), scoped to the caller's lane with `--session`
  stripped.
- The repo-wide sweep finds no stale META-dispatch references outside (a) `lib/pool.sh`
  owner-passthrough (unrelated) and (b) `test/transparency.sh` (parallel item, if not yet landed).
- No code, test, or other doc file is modified by this task.

## User Persona

**Target User**: Developers/operators/agents reading `README.md` to understand how
`agent-browser-pool` dispatches commands. The stale META model actively misleads: it implies
`agent-browser-pool mcp --session abpool-3` is a safe no-lane passthrough, when the code now
(correctly) treats it as a driving command (so a caller can't aim `--session` at another lane).

**Use Case**: A reader checks "do `skills`/`--version`/`mcp` need a `pi` ancestor?" README must
answer consistently with the code: **yes** — they are driving commands.

**Pain Points Addressed**: Doc/code drift. The QA report (Issue 3) flagged that docs still
described the removed model; this task closes that gap for the user-facing README.

## Why

- **Docs must match shipped behavior.** The code fix (P1.M1) removed META passthrough to close a
  real cross-lane isolation breach (QA Issue 1). README still documents the old, insecure model —
  a reader following it would expect `mcp`/`session list` to bypass lane scoping. This task aligns
  the docs with the security-critical code change.
- **Closes the doc half of the meta-removal delta.** delta_prd.md line 27 + the QA Issue 3 require
  all docs to describe "pool verbs vs driving." `configuration.md` + `SKILL.md` are done; README is
  the last user-facing doc with stale META references.
- **The sweep is the durable guarantee.** A grep gate ensures no stale META-dispatch reference
  survives anywhere (code/tests/docs), making a future regression visible.

## What

Edits to `README.md` only. Each edit is **content-anchored** (the exact old text → new text), so
it is robust to line-number drift. The canonical new wording mirrors
`.agents/skills/agent-browser-pool/references/configuration.md` §"Command dispatch: pool verbs
vs. driving" (already shipped).

### Success Criteria

- [ ] `grep -nE 'META|passthrough|dispatch_classify' README.md` → **no output** (zero stale refs).
- [ ] Location 1 (~L95): the callout no longer says "and META commands"; it states pool verbs work
  from any shell and everything else is a driving command requiring a `pi` ancestor.
- [ ] Location 2 (~L135-141): the "Classification detail" blockquote describes the new model (no
  META class; pool verbs caught by `bin/agent-browser-pool`; everything else driving, incl.
  `--version`/`skills`/`mcp`/`session list`/flags-only).
- [ ] Location 3 (~L255-277): the "How it works" intro + classify diagram have **no META branch**;
  step 2 is merged into the driving flow (no "META command?" mention).
- [ ] Location 4 (~L316): the Troubleshooting callout no longer says "and META commands".
- [ ] README's dispatch description is consistent with `configuration.md` (pool verbs vs driving).
- [ ] The file-tree line (~L356: "sole entry point: pool verbs + driving router") is **unchanged**
  (already correct).
- [ ] Repo-wide sweep (`grep -rnE 'meta|passthrough|META|dispatch_classify' lib/pool.sh
      bin/agent-browser-pool test/*.sh .agents/skills/agent-browser-pool/**/*.md README.md`): the
      only remaining hits are (a) `lib/pool.sh` owner-passthrough (unrelated — see Gotchas), (b)
      "meta" as common English, and (c) `test/transparency.sh` IF the parallel item hasn't landed.
- [ ] No file other than `README.md` is modified.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed?"** → Yes.
This PRP includes: the **current-state** reconciliation (what's already fixed vs. what remains);
the exact content-anchored oldText→newText for each README location; the canonical new-contract
wording (mirrored from the already-shipped `configuration.md`); the precise sweep command + the
expected acceptable/unacceptable hits (incl. the owner-passthrough disambiguation and the
parallel-item carve-out); and explicit scope guards (don't touch transparency.sh / code / other docs).

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/architecture/research_meta_refs.md
  why: the COMPLETE reference map of every meta/passthrough/dispatch_classify hit in the repo
        (pre-fix). §0 disambiguates the TWO "passthrough" concepts (META-dispatch #1 vs owner
        #2). §4 lists every file:line. USE IT to build the sweep, but RECONCILE with the current
        state (P1.M1 already removed the lib/pool.sh + validate.sh + configuration.md + SKILL.md hits).
  pattern: §4 README.md subsection lists the exact META locations.
  gotcha: §0/§4 — the lib/pool.sh owner-passthrough hits (402-403, 497-498, 580-581, 1005-1006,
        2089-2099, 2149) are UNRELATED (POOL_OWNER_PID==0 no-pi-ancestor semantics). DO NOT TOUCH.

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: the CANONICAL new-contract wording, already shipped by P1.M1.T1.S2. §"Command dispatch:
        pool verbs vs. driving" (lines 44-75) is the exact model README must mirror. Quote/paraphrase it.
  pattern: pool verbs (status/reap/release/doctor/help) caught by bin BEFORE pool_wrapper_main;
        everything else → driving → resolve owner → fail-fast without pi → acquire/reuse lane →
        strip --session → force AGENT_BROWSER_SESSION → exec. "There is no 'meta / passthrough' class."

- file: plan/002_97982899bef6/delta_prd.md
  why: the authoritative delta. Line 27 (META/passthrough class removed; pool verbs are an
        allowlist, everything else driving). Line 36 (pool verbs need no owner; driving requires pi
        + fails fast). Line 82 (configuration.md "meta vs driving" → "pool verbs vs driving" — the
        same change README needs). Line 97 (README overhaul scope — note: THIS task is scoped to the
        META/passthrough subset only, NOT the broader master-profile/DISABLE/cutover rewrite).
  pattern: line 27 + 36 are the contract README must state.

- file: README.md
  why: the file under edit. READ the 4 META locations (95, 135-141, 255-277, 316) + confirm line
        356 (file tree) is already clean.
  gotcha: "and META commands work from any shell." appears TWICE (L95 slash-form, L316
        comma-form) — distinguish by the surrounding separator style when editing.

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: already shipped in the new model (lines 57-69: "Every command except pool verbs is a
        driving command … There is no 'meta / passthrough' class"). Cross-check README is consistent
        with SKILL.md (they describe the same dispatch).

# Sibling/parallel contracts (treated as truth — DO NOT edit their files)
- file: plan/002_97982899bef6/bugfix/001_2f350a0ce445/P1M2T1S1/PRP.md
  why: P1.M2.T1.S1 (IN PARALLEL) replaces test_passthrough_skills / test_version_passthrough in
        test/transparency.sh with fail-fast tests + syncs the header. THIS task must NOT edit
        transparency.sh. If the sweep is run before P1.M2.T1.S1 lands, transparency.sh WILL still
        show stale META refs — that is EXPECTED (the parallel item's job), not a regression to fix.
  gotcha: do NOT "help" by editing transparency.sh — it conflicts with the parallel item.

# External authoritative docs
- url: https://www.markdownguide.org/basic-syntax/#blockquotes-1
  why: README uses blockquotes (`>`) for the callouts being edited (Locations 1, 2, 4). Preserve
        the `>` prefix + continuation `>` on wrapped lines when replacing blockquote text.
```

### Current Codebase tree (relevant subset)

```bash
agent-browser-pool/
├── README.md                              # ← THIS TASK EDITS (the only file changed)
├── lib/pool.sh                            # CLEAN of META dispatch (owner-passthrough only — out of scope)
├── bin/agent-browser-pool                 # CLEAN (sole entry point: pool verbs + driving router)
├── test/
│   ├── transparency.sh                    # P1.M2.T1.S1 (parallel) — NOT this task
│   ├── validate.sh                        # CLEAN (selftest_dispatch_classify_cases deleted)
│   ├── concurrency.sh, release_reaper.sh  # CLEAN
└── .agents/skills/agent-browser-pool/
    ├── SKILL.md                           # CLEAN (new model, shipped by P1.M1.T1.S2)
    └── references/configuration.md        # CLEAN (canonical "pool verbs vs driving" — mirror this)
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (two "passthrough" concepts — DO NOT conflate): the word "passthrough" in lib/pool.sh
# means TWO unrelated things. (1) META-dispatch passthrough — REMOVED (the subject of this fix).
# (2) OWNER passthrough — POOL_OWNER_PID==0 (no pi ancestor) → the wrapper FAILS-FAST. The owner-
# passthrough references (lib/pool.sh ~403, 498, 581, 1005, 2089-2099, 2149) are UNRELATED and must
# NOT be touched. The sweep MUST NOT flag them. (research_meta_refs.md §0.)

# CRITICAL (parallel-item carve-out): test/transparency.sh is being fixed by P1.M2.T1.S1 IN
# PARALLEL. If you run the sweep before it lands, transparency.sh shows stale META refs — that is
# EXPECTED, not yours to fix. Do NOT edit transparency.sh (conflicts with the parallel item).

# GOTCHA (line-number drift): the README META locations are cited by approximate line number
# (~95, ~135-141, ~255-277, ~316) but line numbers SHIFT as you edit. Use the CONTENT-ANCHORED
# oldText strings in the Implementation Tasks (the exact prose), not line numbers, to locate edits.

# GOTCHA (duplicate phrase): "and META commands work from any shell." appears at TWO locations
# (the L95 callout uses " / " slash separators; the L316 troubleshooting uses ", " comma
# separators across a line wrap). Distinguish them by the surrounding separator style so each edit
# targets the right one.

# GOTCHA (preserve blockquote `>` prefix): Locations 1, 2, 4 are blockquotes (`>`). When replacing
# their text, keep the `>` prefix on every wrapped line (continuation lines need `>` too).

# GOTCHA (scope — NOT the broader README rewrite): delta_prd.md line 97 describes a LARGER README
# overhaul (master-profile→real-chrome-udd, AGENT_BROWSER_POOL_DISABLE removal, cutover/install
# rewrite, repo layout). THIS item is scoped STRICTLY to META-passthrough references + the
# meta/passthrough/dispatch_classify sweep. Do NOT expand into the DISABLE/master/cutover rewrite
# (separate concerns; out of scope here). Leave the file-tree line (~356) as-is — it's already correct.
```

## Implementation Blueprint

### Data models and structure

None — this is a prose/markdown edit. The "model" is the dispatch contract: **pool verbs vs
driving** (no META class). Mirror `configuration.md` §"Command dispatch".

### Implementation Tasks (ordered; all edit `README.md` only)

```yaml
Task 0: VERIFY current state + locate edits by content (line numbers drift)
  - RUN (confirm README is the only stale file; everything else is clean):
        grep -rnE 'META|passthrough|dispatch_classify' lib/pool.sh bin/agent-browser-pool \
            test/validate.sh .agents/skills/agent-browser-pool/ README.md | grep -v 'transparency.sh'
  - EXPECT: hits ONLY in README.md (the locations below). (lib/pool.sh owner-passthrough uses
        lowercase "passthrough" — if your grep matched it, those are UNRELATED; see Gotchas. The
        uppercase META / dispatch_classify hits should be README-only outside transparency.sh.)
  - RUN (confirm transparency.sh is the parallel item's, not yours):
        grep -nE 'META|passthrough|dispatch_classify' test/transparency.sh | head
  - EXPECT: stale hits (P1.M2.T1.S1's job). DO NOT EDIT transparency.sh.
  - RUN (read the canonical wording to mirror):
        sed -n '/## Command dispatch: pool verbs vs. driving/,/## How acquire works/p' \
            .agents/skills/agent-browser-pool/references/configuration.md
  - EXPECT: the pool-verbs-vs-driving section — paraphrase this for README.

Task 1: EDIT Location 1 — the "Driving commands require a pi ancestor" callout (~L95)
  - OLD (exact prose — slash-form separators distinguish it from L316):
        > (`status` / `doctor` / `reap` / `release` / `help`) and META commands work from any shell.
  - NEW:
        > (`status` / `doctor` / `reap` / `release` / `help`) work from any shell; every other
        > command is a driving command that requires a `pi` ancestor.
  - NOTE: keep the `>` blockquote prefix; this is the tail of a multi-line callout (the preceding
        lines about "fails fast … call agent-browser directly" stay). Only the "Pool verbs …"
        sentence changes.

Task 2: EDIT Location 2 — replace the "Classification detail" blockquote (~L135-141)
  - OLD (the whole blockquote — the META token list):
        > **Classification detail.** A few tokens are **META** and pass through to the real
        > `agent-browser` unchanged, acquiring no lane: `--version`; the subcommands `skills`,
        > `dashboard`, `plugin`, `mcp`; `session list`; and a flags-only invocation with no
        > subcommand (e.g. `agent-browser-pool --json`). Note that `--help` / `-h` / `help` are
        > **pool verbs** (they print this tool's help and never reach the real binary), and a bare
        > `agent-browser-pool` with no args defaults to `status`.
  - NEW (the pool-verbs-vs-driving model — mirror configuration.md):
        > **Classification detail.** There is no "meta / passthrough" class. `bin/agent-browser-pool`
        > catches the **pool verbs** (`status`, `reap`, `release`, `doctor`, `help`/`--help`/`-h`;
        > a bare invocation defaults to `status`) and runs them with no lane. **Everything else is a
        > driving command** — including `--version`, `skills`, `dashboard`, `plugin`, `mcp`,
        > `session list`, and a flags-only invocation (e.g. `agent-browser-pool --json`). A driving
        > command resolves your owning `pi` process, **fails fast** without a `pi` ancestor, and runs
        > scoped to your own lane (any `--session <X>` you pass is stripped and
        > `AGENT_BROWSER_SESSION=abpool-<N>` is forced). This is why a caller can never aim a command
        > at another agent's lane.
  - FOLLOW pattern: configuration.md §"Command dispatch" (the canonical wording).

Task 3: EDIT Location 3a — the "How it works" intro (~L255-257)
  - OLD:
        On each invocation, `agent-browser-pool` classifies the command, then either runs a pool verb,
        passes a META command through to the real binary, or runs the lane lifecycle for a driving
        command:
  - NEW:
        On each invocation, `bin/agent-browser-pool` splits the command: a **pool verb** runs an
        admin function (no lane); **everything else is a driving command** that runs the lane
        lifecycle:

Task 4: EDIT Location 3b — the classify diagram (~L258-270): REMOVE the META branch
  - OLD (the diagram block — note the META branch + the "(not passthrough)" parenthetical):
        agent-browser-pool open https://example.com        ← agent types this, nothing else
           │ 1. classify:
           │      pool verb (status/reap/release/doctor/help)?  → run it (no lane)
           │      META (--version, skills, dashboard, plugin, mcp, session list, flags-only)?
           │                                                     → passthrough to the real binary (no lane)
           │ 2. else DRIVING:
           │      resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST (not passthrough)
           ├─ already hold my lease?  reuse my lane
           ├─ else acquire:  reap stale  →  reuse-orphan OR  cp --reflink master(real Chrome)→ephemeral
           │                  →  launch Chrome (setsid process group, anti-throttle flags)  →  connect daemon
           ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
           └─ exec the real agent-browser with the cleaned args   (process replacement)
  - NEW (no META branch; one pool-verb/driving split; drop "(not passthrough)"):
        agent-browser-pool open https://example.com        ← agent types this, nothing else
           │ 1. split (bin/agent-browser-pool):
           │      pool verb (status/reap/release/doctor/help)?  → run it (no lane, no owner resolve)
           │      else DRIVING → pool_wrapper_main:
           │           resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST
           ├─ already hold my lease?  reuse my lane
           ├─ else acquire:  reap stale  →  reuse-orphan OR  cp --reflink master(real Chrome)→ephemeral
           │                  →  launch Chrome (setsid process group, anti-throttle flags)  →  connect daemon
           ├─ strip any --session, force AGENT_BROWSER_SESSION=abpool-<N>
           └─ exec the real agent-browser with the cleaned args   (process replacement)
  - GOTCHA: keep the ASCII-art alignment/indentation consistent with the surrounding code fence.
        The diagram lives inside a ``` fence; preserve the fence.

Task 5: EDIT Location 3c — step 2 of the lifecycle list (~L277): merge into driving flow
  - OLD:
        2. classify — pool verb? META command? → handled above (no lane);
  - NEW:
        2. (pool verbs were handled by `bin/agent-browser-pool` above — no lane); otherwise driving:
  - NOTE: the numbered list (1 config+state; 2 ...; 3 resolve owner; …) must stay coherent. Step 2
        becomes a parenthetical (pool verbs already handled); step 3 ("driving command → resolve
        the owning pi process") is unchanged and now directly follows.

Task 6: EDIT Location 4 — the Troubleshooting callout (~L316)
  - OLD (comma-form — distinguishes it from L95's slash-form):
        `reap`, `release`, `help`) and META commands work from any shell.
  - NEW:
        `reap`, `release`, `help`) work from any shell; all other commands are driving (they
        require a `pi` ancestor).
  - NOTE: this is the tail of a wrapped blockquote line (preceded by "Pool verbs (`status`,
        `doctor`,"); keep the `>` prefix.

Task 7: FINAL CONSISTENCY SWEEP (the deliverable's verification gate)
  - RUN (the item's sweep command):
        grep -rnE 'meta|passthrough|META|dispatch_classify' \
            lib/pool.sh bin/agent-browser-pool test/*.sh \
            .agents/skills/agent-browser-pool/**/*.md README.md
  - EXPECT (classify every hit):
      * README.md → NONE (all 4 locations fixed). If any remain → fix them (you missed a spot).
      * lib/pool.sh → ONLY owner-passthrough (lowercase "passthrough", lines ~403/498/581/1005/
        2089-2099/2149; POOL_OWNER_PID==0 semantics). UNRELATED — DO NOT TOUCH.
      * bin/agent-browser-pool → NONE.
      * test/validate.sh → NONE (selftest deleted by P1.M1.T1.S2).
      * .agents/skills/.../{SKILL.md,references/configuration.md} → only the NEW framing
        ("There is no 'meta / passthrough' class") — acceptable (it's documenting the removal).
      * test/transparency.sh → IF the parallel item P1.M2.T1.S1 has NOT landed, stale hits remain
        here — EXPECTED, not yours. (If it HAS landed → NONE.)
      * "meta" as common English (e.g. "metadata") in any file → acceptable; inspect each.
  - RUN (README-specific zero-stale-ref gate):
        grep -nE 'META|passthrough|dispatch_classify' README.md
  - EXPECT: no output.
  - RUN (rendered-doc sanity — optional): eyeball the edited sections in a markdown previewer or
        `sed -n '90,145p;250,320p' README.md` to confirm prose flows + blockquote/diagram formatting.
```

### Implementation Patterns & Key Details

```markdown
<!-- Canonical dispatch paragraph to mirror (paraphrase configuration.md §"Command dispatch"): -->
`bin/agent-browser-pool` splits each invocation before any lane work:
- **Pool verb** (no lane, no owner, no Chrome): `status`, `reap`, `release [<N>|all]`, `doctor`,
  `help`/`--help`/`-h`; a bare call defaults to `status`.
- **Everything else → DRIVING** → `pool_wrapper_main`: resolve the owning `pi` PID; **fail-fast**
  without a `pi` ancestor; otherwise acquire/reuse your lane, strip any `--session`, force
  `AGENT_BROWSER_SESSION=abpool-<N>`, exec the real binary with cleaned args.

<!-- The one-line summary that replaces "and META commands work from any shell": -->
Pool verbs work from any shell; every other command is a driving command requiring a `pi` ancestor.
```

### Integration Points

```yaml
DOCS (this task IS the docs change — Mode B):
  - README.md: 4 META locations rewritten to the pool-verbs-vs-driving model (Tasks 1-6).
  - No other doc edited (configuration.md + SKILL.md already shipped by P1.M1.T1.S2).

CONSISTENCY GATE (Task 7): the repo-wide grep sweep. Acceptable residual hits are explicitly
  enumerated (owner-passthrough in lib/pool.sh; the new-model "no meta class" framing in the skill
  docs; transparency.sh if the parallel item hasn't landed; common-English "meta"). Anything else
  is a regression to fix.

CONFIG / DATABASE / ROUTES: none. Docs-only.
```

## Validation Loop

### Level 1: Syntax & Style (markdown well-formedness)

```bash
# No broken code fences, no dangling blockquote markers. Quick structural check:
awk '/^```/{c++} END{print "fences="(c%2==0?"balanced":"UNBALANCED")}' README.md   # → balanced
# Eyeball the edited regions:
sed -n '90,100p;130,145p;253,285p;310,320p' README.md
# Expected: prose flows; blockquotes keep `>`; the diagram fence is intact; no "META"/"passthrough".
```

### Level 2: The Stale-Reference Gate (the core check)

```bash
# 2a. README has ZERO stale META/passthrough/dispatch_classify references:
grep -nE 'META|passthrough|dispatch_classify' README.md
# Expected: no output.

# 2b. The "meta" (case-insensitive) hits that remain in README are common-English only:
grep -niE 'meta' README.md
# Expected: only acceptable uses (e.g. none, or "metadata"-style). Investigate any hit.
```

### Level 3: Consistency with the Shipped Docs + Code

```bash
# 3a. README's dispatch description matches configuration.md (the canonical wording):
grep -nE 'pool verb|driving|fail.?fast|pi ancestor' README.md | head
# Expected: README now uses the same "pool verbs vs driving" / "fail-fast" / "pi ancestor" framing.

# 3b. README does NOT contradict the shipped code (META dispatch is gone from lib/pool.sh):
grep -nE 'pool_dispatch_classify|== "meta"' lib/pool.sh
# Expected: no output (the code has no META classifier; README must not claim one exists).

# 3c. Cross-check: README, SKILL.md, configuration.md all describe the SAME model:
for f in README.md .agents/skills/agent-browser-pool/SKILL.md \
         .agents/skills/agent-browser-pool/references/configuration.md; do
  echo "== $f =="; grep -cE 'pool verb|driving' "$f"
done
# Expected: each file mentions pool-verbs/driving (consistent vocabulary).
```

### Level 4: The Final Repo-Wide Sweep (Task 7)

```bash
grep -rnE 'meta|passthrough|META|dispatch_classify' \
    lib/pool.sh bin/agent-browser-pool test/*.sh \
    .agents/skills/agent-browser-pool/**/*.md README.md
# Expected: classify every hit —
#   * lib/pool.sh  → owner-passthrough ONLY (lowercase; POOL_OWNER_PID==0). UNRELATED. OK.
#   * skill docs   → "There is no 'meta / passthrough' class" (documenting the removal). OK.
#   * README.md    → NONE.
#   * test/*       → transparency.sh may have stale hits IF P1.M2.T1.S1 hasn't landed (EXPECTED).
#   * common-English "meta" → inspect; OK if unrelated.
# Any OTHER hit (a stale META-dispatch reference) → FIX IT.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: README markdown well-formed (balanced code fences; blockquotes intact).
- [ ] Level 2a: `grep -nE 'META|passthrough|dispatch_classify' README.md` → no output.
- [ ] Level 2b: any remaining `meta` in README is common-English only.
- [ ] Level 3a-c: README consistent with configuration.md / SKILL.md / the shipped code.
- [ ] Level 4: repo-wide sweep — only acceptable residual hits (owner-passthrough, new-model
      framing in skill docs, transparency.sh if parallel item pending, common-English).

### Feature Validation

- [ ] Location 1 (~L95): no "and META commands"; states pool-verbs-any-shell + driving-needs-pi.
- [ ] Location 2 (~L135-141): blockquote describes pool-verbs-vs-driving (no META class).
- [ ] Location 3 (~L255-277): intro + diagram have NO META branch; step 2 merged into driving.
- [ ] Location 4 (~L316): no "and META commands".
- [ ] File-tree line (~L356) unchanged (already correct).

### Code Quality / Scope Validation

- [ ] ONLY `README.md` is modified (`git diff --stat` shows one file).
- [ ] No edits to `test/transparency.sh` (parallel item), `lib/pool.sh`/`bin/*` (code), or
      `configuration.md`/`SKILL.md`/`validate.sh` (already clean).
- [ ] Scope held to META/passthrough — NOT expanded into the broader master-profile/DISABLE/cutover
      README rewrite (separate concern, out of scope).

### Documentation & Deployment

- [ ] README accurately describes the shipped (post-pivot) dispatch model.
- [ ] No new env vars / config / code introduced (docs-only).

---

## Anti-Patterns to Avoid

- ❌ Don't edit `test/transparency.sh` — that's P1.M2.T1.S1 (parallel); editing it causes a conflict.
- ❌ Don't touch the `lib/pool.sh` owner-passthrough references — they're UNRELATED
  (`POOL_OWNER_PID==0`); the sweep must not flag them as regressions.
- ❌ Don't conflate the two "passthrough" concepts (META-dispatch [removed] vs owner [fail-fast]).
- ❌ Don't expand scope into the broader README rewrite (master-profile→real-chrome-udd,
  `AGENT_BROWSER_POOL_DISABLE`, cutover/install) — this item is META/passthrough-only.
- ❌ Don't edit code or other docs — this is a Mode-B docs task on `README.md` alone.
- ❌ Don't locate edits by line number (they drift) — use the content-anchored oldText strings.
- ❌ Don't break the ASCII diagram's alignment or the blockquote `>` prefixes when rewriting.
- ❌ Don't leave a half-rewritten dispatch model — all 4 locations must tell the SAME (new) story.
