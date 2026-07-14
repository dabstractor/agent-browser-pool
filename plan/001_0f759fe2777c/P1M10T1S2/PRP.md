# PRP — P1.M10.T1.S2: Verify `.gitignore` covers all runtime artifacts

> **Scope flag.** This is a tiny **CONFIG-ONLY** PRP (item contract §3 OUTPUT: ".gitignore
> accurately covers runtime artifacts"). Its **sole** output is an updated `.gitignore`
> (+ this PRP). It adds **zero** source/lib/bin/test/README/PRD changes and **zero** runtime
> behavior changes. It does NOT boot Chrome or run the test suite (AGENTS.md §1).
>
> **Runs in parallel with P1.M10.T1.S1** (the README rewrite). S1's PRP §"Integration Points"
> explicitly defers ALL `.gitignore` work to THIS item ("GITIGNORE: none — this PRP must NOT
> touch .gitignore — that is P1.M10.T1.S2's job"). S1 also says its README §"Repository layout"
> will mark runtime dirs as gitignored; the two are consistent and non-overlapping. Treat
> S1's PRP as a contract that the README will reference runtime-dirs-as-gitignored — this
> item must make `.gitignore` actually match that claim.

---

## Goal

**Feature Goal**: Make `.gitignore` an accurate, self-documenting defense-in-depth filter that
excludes every runtime artifact the shipped pool can create, while preserving (a) all
intentionally-tracked source files and (b) the tracked `plan/` history tree.

**Deliverable**: an updated `.gitignore` that explicitly names every runtime artifact class
(pool.log, chrome-\<lane>.log, alerts.log, lanes/\<N>.json leases, acquire.lock) in comments,
adds the one missing positive pattern (`acquire.lock`), and verifies via `git check-ignore`
that no tracked file (especially `plan/`, `PRD.md`, `AGENTS.md`, source under `bin/ lib/ test/`)
is accidentally ignored.

**Success Definition**: `git check-ignore -v` reports every runtime artifact path as ignored;
reports every tracked source/history path as NOT ignored; `git status --ignored` shows only
`.pi-subagents/` as the ignored runtime tree; `git ls-files` is byte-identical for all
pre-existing entries (no tracked file dropped by a new ignore pattern).

---

## User Persona

**Target User**: the **maintainer / future contributor** who clones the repo and must never
accidentally `git add` a runtime log, a stale lease JSON, or a stray flock lock. (End users
of the pool never see `.gitignore` — item §5: "DOCS: none — .gitignore is not user-facing.")
**Use Case**: a developer overrides `AGENT_BROWSER_POOL_STATE` to a path inside the repo for
local debugging, then runs `git add -A`; the filter must keep the resulting logs/leases/locks
out of the commit.
**Pain Points Addressed**: today `acquire.lock` (the flock file) is the only runtime artifact
with a non-`.log` extension and is NOT explicitly covered; `lanes/*.json` leases are only
covered transitively via the `.state/` catch-all, which a maintainer could misread as
accidental cruft and delete.

---

## Why

- P1.M10 is the final milestone and this is the housekeeping task that guarantees the repo
  ships clean: only source + tracked `plan/` history, never runtime state.
- The shipped system (M1–M9) writes 5 distinct runtime artifacts (research §1) — three are
  `*.log` (already covered), but `acquire.lock` and `lanes/*.json` are not, and the existing
  `.state/` entry is **vestigial** (matches no real path — research §2) so its purpose is
  opaque to a reader.
- The README rewrite (parallel S1) will state that runtime dirs are gitignored; `.gitignore`
  must actually live up to that statement, with comments a maintainer can trust.
- Zero behavioral risk: `.gitignore` affects only what git tracks, never runtime behavior.

---

## What

A **minimal, surgical edit of `.gitignore`** (overwrite or in-place edit — implementer's
choice, but the result must equal the target below):

1. **KEEP** `*.log` (line 2) — it already covers `pool.log`, `chrome-<lane>.log`, `alerts.log`.
2. **KEEP** `.state/` (line 5) as a generic repo-relative state-dir catch-all, but **document**
   that it is defense-in-depth (the real state dir is the absolute `~/.local/state/agent-browser-pool`,
   outside the repo — research §1/§2).
3. **ADD** an explicit `acquire.lock` pattern — the flock critical-section file, the one
   runtime artifact with no `.log` extension (research §1).
4. **ADD clarifying comments** that enumerate ALL five runtime artifact classes and state that
   they live under `$AGENT_BROWSER_POOL_STATE` (default `~/.local/state/agent-browser-pool`,
   outside the repo), so `.gitignore` only matters for an in-repo override.
5. **ADD a trailing comment** (NOT a gitignore entry) noting that `plan/`, `PRD.md`,
   `AGENTS.md`, and source under `bin/ lib/ test/ install.sh` are intentionally tracked and
   must never be ignored. (A `#` comment is not a gitignore rule; it cannot accidentally
   match. Do NOT add `!plan/`-style negations — AGENTS.md §5 forbids any `plan/` entry.)
6. **PRESERVE** all existing unrelated entries verbatim: `.pi-subagents/`, `.env`/`.env.*`/
   `!.env.example`, `.DS_Store`/`Thumbs.db`, `dist/`/`build/`, `node_modules/`/`venv/`/
   `__pycache__/`.

### Success Criteria
- [ ] `git check-ignore -v pool.log chrome-1.log alerts.log` all exit 0 and cite `*.log`.
- [ ] `git check-ignore -v acquire.lock` exits 0 and cites the new pattern.
- [ ] `git check-ignore -v .state/lanes/1.json` exits 0 and cites `.state/`.
- [ ] `git check-ignore` exits 1 (NOT ignored) for: `plan/001_0f759fe2777c/PRD.md`,
      `plan/001_0f759fe2777c/tasks.json`, `PRD.md`, `AGENTS.md`, `README.md`, `install.sh`,
      `lib/pool.sh`, `bin/agent-browser`, `test/validate.sh`.
- [ ] `git ls-files` is unchanged for every pre-existing entry (no tracked file newly ignored);
      verify with: `git ls-files | while read -r f; do git check-ignore -q "$f" && echo "LEAK: $f"; done`
      → prints NOTHING.
- [ ] `.gitignore` contains NO entry (positive or negated) targeting `plan/`, `PRD.md`, or
      `tasks.json` (AGENTS.md §5 / FORBIDDEN OPERATIONS).
- [ ] Only `.gitignore` is modified in the whole change.

---

## All Needed Context

### Context Completeness Check
An implementer who has never seen this repo can complete the task from: (1) the current
`.gitignore` (to preserve unrelated entries), (2) the runtime-artifact audit
(`research/runtime-artifacts-audit.md` — the exact 5 artifacts + their code refs + paths), and
(3) `git ls-files` (the set that must stay tracked). All three are provided/referenced. No live
Chrome, no test run, no daemon is required (AGENTS.md §1: static checks only).

### Documentation & References
```yaml
# --- AUTHORITATIVE AUDIT (read FIRST; the single source of truth for this PRP) ---
- file: plan/001_0f759fe2777c/P1M10T1S2/research/runtime-artifacts-audit.md
  why: "the exact 5 runtime artifacts (pool.log / chrome-<lane>.log / alerts.log /
        lanes/<N>.json / acquire.lock), their on-disk paths (all under $POOL_STATE_DIR,
        OUTSIDE the repo by default), code line refs, the '.state/ is vestigial' finding (§2),
        test-harness isolation (§3), current .gitignore coverage verdict (§4), and the
        git check-ignore validation recipe (§6)."
  critical: "§4 (coverage verdict) is the gap analysis — it says: KEEP *.log + .state/,
             ADD acquire.lock, DOCUMENT lanes/*.json as covered-via-catch-all. §7 explains
             the SCOPED authorization to edit .gitignore despite AGENTS.md §5."

# --- the file being edited (preserve its unrelated entries verbatim) ---
- file: .gitignore
  why: "the deliverable. KEEP: lines for .pi-subagents/, .env*, OS files, build/ dist/,
        node_modules/ venv/ __pycache__/. ADJUST: the *.log + .state/ block (add comments +
        acquire.lock). ADD: trailing comment about intentionally-tracked files."
  pattern: "gitignore glob syntax: '*.log' matches any depth; '.state/' matches a dir named
            .state at any depth; a bare 'acquire.lock' matches a file of that name anywhere.
            Comments are full-line '# …'. There is NO shell expansion — literal patterns only."

# --- runtime artifact producers (read-only refs; do NOT edit) ---
- file: lib/pool.sh:25      # _pool_log writes $POOL_STATE_DIR/pool.log
- file: lib/pool.sh:1494    # pool_boot_lane writes $POOL_STATE_DIR/chrome-<lane>.log
- file: lib/pool.sh:2826    # _pool_alert appends $POOL_STATE_DIR/alerts.log
- file: lib/pool.sh:181     # POOL_LANES_DIR = $POOL_STATE_DIR/lanes  (leases: lanes/<N>.json)
- file: lib/pool.sh:203     # pool_state_init: mkdir -p lanes/ + touch acquire.lock
- file: install.sh:143      # install prints 'state: <dir>/{lanes,acquire.lock}' — proves the artifact set
  why: "confirm the 5-artifact inventory in the audit is complete and the names are exact."

# --- config default (proves state dir is absolute / outside-repo by default) ---
- file: lib/pool.sh:137     # POOL_STATE_DIR default = $HOME/.local/state/agent-browser-pool
  why: "establishes that .gitignore is defense-in-depth (normal runs never touch the repo)."

# --- PRD (READ-ONLY; quote the repo-layout intent, don't edit) ---
- url: PRD.md#h2.2          # §3 Repository layout (planned) — the tracked-file contract
  why: "the PRD's repo layout lists exactly README.md, PRD.md, .gitignore, install.sh, bin/*,
        lib/*, test/*. This item's '.gitignore' must keep those (plus AGENTS.md and plan/
        history) tracked and exclude everything else runtime."

# --- parallel sibling PRP (contract; do NOT duplicate its work) ---
- file: plan/001_0f759fe2777c/P1M10T1S1/PRP.md
  why: "S1 rewrites README.md and EXPLICITLY defers ALL .gitignore edits to this item
        ('GITIGNORE: none — this PRP must NOT touch .gitignore'). S1's README §Repo-layout
        will claim runtime dirs are gitignored; this item makes that claim true. No overlap."
```

### Current Codebase tree (relevant subset)
```bash
agent-browser-pool/
├── .gitignore           ← EDIT THIS (the deliverable; only file touched)
├── README.md            ← tracked (parallel S1 rewrites it; do NOT touch here)
├── PRD.md               ← tracked (READ-ONLY)
├── AGENTS.md            ← tracked (READ-ONLY; do NOT ignore it)
├── install.sh           ← tracked
├── bin/{agent-browser,agent-browser-pool,.gitkeep}   ← tracked
├── lib/pool.sh          ← tracked (runtime-artifact producers; read-only here)
├── test/{validate,concurrency,release_reaper,transparency}.sh + .gitkeep  ← tracked
└── plan/001_0f759fe2777c/**  ← tracked (project history; MUST stay tracked — AGENTS.md §5)
```

### Desired Codebase tree with files to be added/changed
```bash
agent-browser-pool/
└── .gitignore           ← MODIFIED (add comments + acquire.lock; preserve everything else)
                          (nothing else changes — config-only PRP)
```

### Known Gotchas of our codebase & Library Quirks
```bash
# CRITICAL: ALL runtime artifacts live under $POOL_STATE_DIR (default ~/.local/state/
#   agent-browser-pool) which is OUTSIDE the repo. .gitignore is DEFENSE-IN-DEPTH for the
#   override scenario (dev sets AGENT_BROWSER_POOL_STATE=./something). Do not assume the
#   pool writes into the repo — it never does by default. (research §1.)

# CRITICAL: .state/ (current line 5) matches NO real path — grep -rn '\.state/' across
#   lib/ bin/ test/ install.sh returns ZERO matches (research §2). It is a vestigial catch-all.
#   Keep it defensively but DOCUMENT it; do not treat it as a live artifact location.

# CRITICAL: tests are hermetic — test/validate.sh:186-190 redirects HOME + STATE to a mktemp
#   tree. No test writes runtime artifacts into the repo cwd. (research §3.) So no test-time
#   .gitignore entries are needed; .gitkeep placeholders in bin/ and test/ are intentional.

# GOTCHA: gitignore has NO negation needed for plan/. plan/ is tracked and not matched by any
#   pattern — adding '!plan/' would be an 'entry targeting plan/' which AGENTS.md §5 forbids.
#   Use a plain '# comment' to document that plan/ is tracked; comments are not gitignore rules.

# GOTCHA: a bare 'lanes/' pattern (without leading '/') would match 'lanes/' at ANY depth,
#   including a hypothetical future 'lib/lanes/' — too broad. Do NOT add 'lanes/'. The runtime
#   leases (lanes/<N>.json) live under $POOL_STATE_DIR/lanes and are covered by the .state/
#   catch-all when overridden into the repo. Document this; do not add a top-level lanes/ rule.

# GOTCHA: do NOT broaden '*.log' or add '*.json' — '*.json' would ignore plan/ PRPs? No —
#   plan PRPs are .md. But '*.json' WOULD match plan/.../tasks.json (which MUST stay tracked)
#   and any future config. Avoid '*.json' entirely. Keep logs as '*.log' only.

# GOTCHA: validation is via 'git check-ignore -v <path>' on path STRINGS — the path does NOT
#   need to exist on disk. This keeps the check static (AGENTS.md §1). Never touch real files
#   to "test" the ignore; never boot Chrome.
```

---

## Implementation Blueprint

### Data models and structure
_N/A — this is a gitignore (plain-text glob) config task. There is no data model. The closest
analog is the runtime-artifact inventory in `research/runtime-artifacts-audit.md §1/§4`, which
maps 1:1 to the comment block the implementer writes._

### Implementation Tasks (ordered; no inter-task deps — single file)

```yaml
Task 1: READ — inventory the current .gitignore + confirm the audit
  - READ .gitignore (26 lines; see research §4 for verbatim contents).
  - CROSS-CHECK the 5 runtime artifacts against lib/pool.sh:25/1494/2826/181/203 and
    install.sh:143 — confirm pool.log, chrome-<lane>.log, alerts.log, lanes/<N>.json,
    acquire.lock are the complete set and the names are exact.
  - NO EDIT yet; just confirm the gap analysis (research §4): *.log covers 3 of 5; .state/
    is a vestigial catch-all; acquire.lock is the only uncovered artifact; lanes/*.json is
    covered-via-.state/-when-overridden.

Task 2: EDIT the "runtime / install artifacts" block (lines 1–5 region)
  - REPLACE the minimal 2-line block:
        # runtime / install artifacts (not version-controlled)
        *.log
        # local dev symlinks / state
        .state/
    WITH a documented block that:
      * keeps `*.log` and cites the three log artifacts in a comment;
      * keeps `.state/` and documents it as the repo-relative state-dir catch-all (the real
        state dir is the absolute ~/.local/state/agent-browser-pool — outside the repo);
      * ADDS `acquire.lock` (the flock critical-section file);
      * ADDS a comment enumerating lanes/<N>.json leases as covered by .state/ when overridden
        into the repo (so a future maintainer does not delete .state/ thinking it is cruft).
  - TARGET block (implementer may reword comments but MUST keep these PATTERNS):
        # --- pool runtime artifacts (defense-in-depth) ---
        # All pool runtime state lives under $AGENT_BROWSER_POOL_STATE
        # (default: ~/.local/state/agent-browser-pool) — OUTSIDE this repo. The patterns below
        # only matter if a dev overrides the state dir to a path inside the repo.
        *.log            # pool.log, chrome-<lane>.log, alerts.log
        acquire.lock     # flock critical-section file (pool_state_init)
        .state/          # repo-relative state-dir override catch-all (covers lanes/<N>.json leases)

Task 3: PRESERVE all unrelated entries verbatim (do not touch)
  - KEEP EXACTLY as-is: the .pi-subagents/ block, the .env/.env.*/!.env.example block, the
    .DS_Store/Thumbs.db block, the dist//build/ block, and the node_modules//venv//__pycache__
    block. Do not reorder, reword, or merge them.

Task 4: ADD a trailing "intentionally tracked" comment block (NOT gitignore entries)
  - APPEND at end of file a comment-only block (every line starts with '#') stating:
        # --- intentionally tracked (do NOT ignore; never add an entry for these) ---
        # Source:   README.md PRD.md AGENTS.md install.sh bin/ lib/ test/
        # History:  plan/  (project history tree — tracked; AGENTS.md §5)
    - CRITICAL: these are COMMENTS only. Do NOT write `!plan/`, `!PRD.md`, `!/bin/`, or any
      negated/positive entry. A comment cannot match a path; it cannot accidentally ignore or
      un-ignore anything. (AGENTS.md §5 forbids any plan//PRD.md/tasks.json ENTRY.)

Task 5: STATIC VALIDATE with git check-ignore (no files created, no Chrome)
  - RUN the validation recipe in research §6 / the Validation Loop below.
  - CONFIRM: every runtime path ignored; every tracked path NOT ignored; no tracked file
    leaked (the `git ls-files | check-ignore` loop prints NOTHING).
  - CONFIRM: git status --short --ignored lists ONLY .pi-subagents/ under !! (and the
    expected untracked plan/P1M10T1S* dirs from the in-flight work — those are fine, they are
    new tracked content being added by this/other items).
```

### Implementation Patterns & Key Details
```gitignore
# gitignore syntax notes for the implementer:
#  - '*.log'           → matches any file ending .log at ANY depth (good — covers chrome-*.log).
#  - '.state/'         → matches a DIRECTORY named .state at any depth (trailing slash = dir-only).
#  - 'acquire.lock'    → matches a FILE named acquire.lock at any depth (no slash = any location).
#  - '# …'             → full-line comment; ignored by git as a rule. CANNOT match a path.
#  - '!pattern'        → negation (re-includes). DO NOT use for plan/PRD/tasks (AGENTS.md §5).
#  - There is NO regex; NO shell globbing beyond fnmatch; NO variable expansion. Literal globs.
#
# The ONLY behavioral change this PRP permits is: 'acquire.lock' becomes ignored where before
# it was not. Everything else is comments + preserved patterns. Net new ignore coverage = 1 file.
```

### Integration Points
```yaml
GIT:
  - file: ".gitignore"
    change: "add 'acquire.lock' pattern; add documentation comments; preserve all other entries"
    verify: "git check-ignore -v acquire.lock exits 0 after the change (exits 1 before)"

CONFIG: none (no env var added — .gitignore documents the EXISTING AGENT_BROWSER_POOL_STATE default).
ROUTES: none.
DATABASE: none.
README: none — .gitignore is not user-facing (item §5). The parallel README item (S1) will
        reference runtime-dirs-as-gitignored in its Repo-layout section; this item makes that
        statement true. Do NOT edit README here.
SOURCE: none — do NOT touch lib/pool.sh, bin/*, install.sh, test/*, PRD.md, AGENTS.md, tasks.json.
```

---

## Validation Loop

### Level 1: File integrity (static — AGENTS.md §1 compliant)

```bash
# (a) .gitignore is non-empty and parses (git accepts it; malformed = git complains):
git check-ignore -v .gitignore >/dev/null 2>&1; echo "rc=$? (0 or 128 ok if self-test sane)"
test -s .gitignore && echo ".gitignore non-empty OK"
# Expected: ".gitignore non-empty OK". If git emits a parse error on any later check, the file
# is malformed — re-read it and fix the offending line.

# (b) no forbidden entries (plan/, PRD.md, tasks.json) as positive OR negated rules:
grep -nE '^\s*!?plan/?\s*$|^\s*!?PRD\.md\s*$|^\s*!?tasks\.json\s*$|^\s*!?plan/' .gitignore \
  && echo "FORBIDDEN ENTRY PRESENT (AGENTS.md §5)!" || echo "no forbidden entries OK"
# Expected: "no forbidden entries OK". (Comments mentioning these names are fine — this grep
# targets leading-optional-'!' lines that are actual rules, not '# ...' comment lines. Still,
# review any hit manually: a hit inside a '# comment' is a false positive; a real rule is a FAIL.)

# (c) the required patterns are present:
grep -qx '\*.log' .gitignore         && echo "*.log present OK"   || echo "MISSING *.log"
grep -qx 'acquire.lock' .gitignore   && echo "acquire.lock present OK" || echo "MISSING acquire.lock"
grep -qx '.state/' .gitignore        && echo ".state/ present OK" || echo "MISSING .state/"
# Expected: all three "present OK".
```

### Level 2: Runtime-artifact coverage (the core VERIFY gate — `git check-ignore`)

```bash
# (a) every runtime artifact path IS ignored (exit 0 + cites the pattern). Paths need not exist.
for p in pool.log chrome-1.log chrome-7.log alerts.log acquire.lock .state/lanes/1.json .state/lanes/12.json; do
  if git check-ignore -q "$p"; then echo "IGNORED OK: $p"; else echo "NOT IGNORED (FAIL): $p"; fi
done
# Expected: every line "IGNORED OK:". Any "NOT IGNORED" for a runtime path = a coverage gap.

# (b) every tracked source/history path is NOT ignored (exit 1):
for p in PRD.md AGENTS.md README.md install.sh lib/pool.sh bin/agent-browser \
         bin/agent-browser-pool test/validate.sh test/concurrency.sh \
         plan/001_0f759fe2777c/PRP.md plan/001_0f759fe2777c/tasks.json \
         plan/001_0f759fe2777c/architecture/system_context.md; do
  if git check-ignore -q "$p"; then echo "ACCIDENTALLY IGNORED (FAIL): $p"; else echo "tracked OK: $p"; fi
done
# Expected: every line "tracked OK:". Any "ACCIDENTALLY IGNORED" = a too-broad new pattern.

# (c) no CURRENTLY-tracked file is newly ignored by the change (the strongest regression gate):
git ls-files | while read -r f; do git check-ignore -q "$f" && echo "LEAK: $f"; done
# Expected: prints NOTHING. Any "LEAK:" line = a tracked file that the new .gitignore now hides
# from git — investigate immediately (likely a too-broad pattern like '*.json' or 'lanes/').
```

### Level 3: Working-tree cleanliness (no stray runtime files committed)

```bash
# (a) confirm no runtime artifact is currently sitting untracked in the repo:
git status --short | grep -iE '\.log$|acquire\.lock|lanes/.*\.json|\.state/' && echo "STRAY RUNTIME FILE (clean or ignore it)" || echo "no stray runtime files OK"
# Expected: "no stray runtime files OK". (If a stray file appears, it is from a local dev run —
# the new .gitignore should make it vanish from `git status`. Do NOT commit it.)

# (b) confirm the only ignored tree is .pi-subagents/ (the harness artifacts):
git status --short --ignored | grep '^!!' | grep -v '\.pi-subagents/' | grep -vE 'plan/001.*P1M10T1S[12]' && echo "UNEXPECTED IGNORED ENTRY" || echo "ignored-set OK"
# Expected: "ignored-set OK". (.pi-subagents/ is the harness; plan/...P1M10T1S1/2 may show as
# untracked during the parallel work — that is expected new content, not a runtime artifact.)
```

### Level 4: Documentation / self-documentation review

```bash
# (a) the runtime-artifact comment block names all 5 classes (so a maintainer trusts the filter):
grep -c 'pool\.log\|chrome-\|alerts\.log\|lanes/\|acquire\.lock' .gitignore
# Expected: >= 5 (the comment should mention each artifact at least once).

# (b) the comment states the state dir is OUTSIDE the repo (so .gitignore = defense-in-depth):
grep -iE 'outside|defense|override|~/.local/state|AGENT_BROWSER_POOL_STATE' .gitignore >/dev/null && echo "documented OK" || echo "add the defense-in-depth note"
# Expected: "documented OK".

# (c) the trailing comment notes plan/ + source are intentionally tracked (comment-only):
grep -iE 'plan/|intentionally tracked|do NOT ignore' .gitignore >/dev/null && echo "tracked-note OK" || echo "add the tracked-note comment"
# Expected: "tracked-note OK". (Reminder: COMMENT only, never a '!plan/' entry.)

# (d) "No Prior Knowledge" read: a maintainer who has never seen this repo reads .gitignore and
#     understands (i) what runtime artifacts exist, (ii) why they live outside the repo, and
#     (iii) that plan/ + source are deliberately tracked. Self-review pass.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `.gitignore` parses (no git error); no forbidden `plan/`/`PRD.md`/`tasks.json`
      entries; `*.log`, `acquire.lock`, `.state/` all present.
- [ ] Level 2: every runtime path (`pool.log`, `chrome-*.log`, `alerts.log`, `acquire.lock`,
      `.state/lanes/*.json`) reports IGNORED; every tracked source/history path reports NOT
      ignored; `git ls-files | check-ignore` loop prints NOTHING (no regression).
- [ ] Level 3: no stray runtime files in working tree; ignored-set is only `.pi-subagents/`
      (+ expected new untracked plan/ work-in-progress).
- [ ] Level 4: comments name all 5 artifact classes + state-dir-is-outside-repo + plan/source
      intentionally-tracked note.

### Feature Validation (the item contract §3 OUTPUT)
- [ ] `*.log` covers chrome-*.log and alerts.log (research §1; verify via check-ignore).
- [ ] `.state/` retained (covers a repo-relative override incl. lanes/*.json leases).
- [ ] `acquire.lock` added (the previously-uncovered flock artifact).
- [ ] repo tracks ONLY source + history: README.md, PRD.md, AGENTS.md, .gitignore, install.sh,
      bin/*, lib/*, test/*, plan/** — and nothing runtime.
- [ ] `plan/` is NOT ignored (remains tracked; AGENTS.md §5).

### Code Quality / Hygiene
- [ ] Only `.gitignore` modified (no README/PRD/AGENTS.md/install.sh/lib/bin/test/tasks.json
      changes — AGENTS.md §5 + FORBIDDEN OPERATIONS).
- [ ] No broad patterns that risk shadowing source (`*.json`, bare `lanes/`, `*.lock` without
      the specific name) — only the surgical `acquire.lock`.
- [ ] Comments are accurate and match the audit (research/runtime-artifacts-audit.md).
- [ ] Unrelated entries (`.pi-subagents/`, `.env*`, OS files, build/dist, node_modules/venv)
      preserved verbatim.

### Documentation & Deployment
- [ ] `.gitignore` is self-documenting (a maintainer understands the artifact set + why
      patterns are defense-in-depth) — item §5 "DOCS: none" is satisfied: the comments ARE the
      documentation, not a separate user-facing file.
- [ ] Consistent with the parallel README (S1) §Repo-layout claim that runtime dirs are
      gitignored.

---

## Anti-Patterns to Avoid

- ❌ Don't add broad patterns like `*.json` (would shadow `plan/.../tasks.json` which MUST stay
  tracked) or bare `lanes/` (would shadow a hypothetical future `lib/lanes/`). Use the surgical
  `acquire.lock` only; let `.state/` be the catch-all for overridden leases.
- ❌ Don't add any gitignore ENTRY (rule, positive OR negated) for `plan/`, `PRD.md`, or
  `tasks.json` — AGENTS.md §5 forbids it. A `# comment` mentioning them is fine and encouraged.
- ❌ Don't boot Chrome, run the test suite, or create real runtime files to "test" the ignore —
  `git check-ignore` works on path strings (AGENTS.md §1: static checks only).
- ❌ Don't reorder/merge/reword the unrelated `.pi-subagents/`, `.env*`, OS, build, or
  dependency blocks — preserve them verbatim to minimize diff risk.
- ❌ Don't edit any file other than `.gitignore` (no README/PRD/install/lib/bin/test/tasks.json).
- ❌ Don't treat `.state/` as a live artifact location — it matches NO real path (research §2);
  it is a vestigial catch-all kept defensively. Document it as such.

---

## Confidence Score

**9/10** for one-pass success. The task is a surgical single-file config edit with the entire
artifact inventory already audited verbatim in `research/runtime-artifacts-audit.md` (5 artifacts,
exact paths, code refs, gap analysis). The change is exactly one new pattern (`acquire.lock`) +
comments; the rest is preservation. The only residual risk is accidentally introducing a
too-broad pattern — fully mitigated by the Level-2 `git check-ignore` regression gate
(`git ls-files | check-ignore` must print nothing) and the forbidden-entry grep (Level 1b).
No code is touched, so there is zero behavioral/regression risk; the worst case is a comment
wording tweak, not a reimplementation.
