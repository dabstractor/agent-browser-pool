# PRP — P3.M1.T1.S1: Add `AGENT_BROWSER_POOL_HARNESSES` config var + `POOL_HARNESSES` global

**Parent plan:** P3 (Multi-Harness Owner Resolution, Decision O9) → M1 (Core generalization, `lib/pool.sh`) → T1 → **S1**
**Scope:** ONE subtask. Adds a single config block to `pool_config_init` (the recognized-harness set) + one docs row. Does NOT touch `pool_owner_resolve` (that is S2) or the fail-fast message (that is S3).
**Foundation subtask:** no upstream dependency — this is the first code change of P3. Its only output (`POOL_HARNESSES`) is consumed by S2/S3.

---

## Goal

**Feature Goal:** `pool_config_init` reads `AGENT_BROWSER_POOL_HARNESSES`, normalizes it, guards against the empty case, and freezes it into a new global `POOL_HARNESSES` — a lowercased, de-duped, never-empty, comma-separated harness-comm lookup string available to every function in `lib/pool.sh`.

**Deliverable:**
1. A new config section in `pool_config_init` (`lib/pool.sh`) that produces `POOL_HARNESSES` following the existing §3 `CHROME_BIN` string pattern.
2. One new row in the `pool_config_init` header comment table (`lib/pool.sh`).
3. One new row in the env-var table of `.agents/skills/agent-browser-pool/references/configuration.md`.

**Success Definition:** `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` both return rc 0; `POOL_HARNESSES` equals `pi,claude,codex,agy,antigravity` when the env var is unset, and equals the normalized form of any user-supplied value (never empty); the stored form is directly matchable by S2's `[[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]` predicate.

---

## Why

- **Unblocks P3 (Decision O9):** owner resolution is being generalized from `pi`-only to a recognized-harness *set* (PRD §2.4 step 1, §2.11, O9). That set must exist as a configured global before any consumer can use it. S2 (walk loop), S3 (fail-fast message), and P3.M2 (tests) all read `POOL_HARNESSES`.
- **Configuration, not hardcoding:** the default `pi,claude,codex,agy,antigravity` covers the four supported harnesses, but a host may surface a different `comm` than the native binary (node-wrapped launchers; the Antigravity IDE terminal may expose the editor's comm rather than `agy`). Making it an env var lets operators tune it without code edits (PRD §2.11).
- **Safety invariant:** an empty set would make every driving command fail the no-ancestor check, so the config must NEVER emit an empty value — it falls back to the default.

---

## What

### Visible behavior (configuration only — no runtime/CLI behavior changes from S1 alone)

- `AGENT_BROWSER_POOL_HARNESSES` is an optional env var. When unset/empty-after-normalization, `POOL_HARNESSES` defaults to `pi,claude,codex,agy,antigravity`.
- When set, the value is normalized: lowercased, consecutive commas collapsed, leading/trailing commas trimmed. Example inputs → outputs:
  - `PI,Claude,CODEX` → `pi,claude,codex`
  - `,pi,,claude,` → `pi,claude`
  - `,,,` (all commas) → empty after normalization → **falls back to default** `pi,claude,codex,agy,antigravity`
  - unset / `""` → default
- `POOL_HARNESSES` is MUTABLE (not `readonly`) and re-resolved on every `pool_config_init` call — the test harness sources `lib/pool.sh` once and calls `pool_config_init` repeatedly per case (lib/pool.sh:124-127). There is intentionally NO "already-initialized" guard; preserve that.

### Success criteria

- [ ] New config block in `pool_config_init` sets `POOL_HARNESSES` via `declare -g`, MUTABLE, re-runnable.
- [ ] Normalization = lowercase + squeeze-commas + trim-end-commas (exactly these three; no whitespace stripping).
- [ ] Empty-after-normalization ⇒ falls back to the default string (never empty).
- [ ] Header comment table lists `AGENT_BROWSER_POOL_HARNESSES → POOL_HARNESSES (comma-set)`.
- [ ] `configuration.md` env-var table has the new row after the `AGENT_CHROME_ALLOW_SLOW_COPY` row.
- [ ] `bash -n lib/pool.sh` ⇒ rc 0.
- [ ] `shellcheck -s bash lib/pool.sh` ⇒ rc 0.
- [ ] No change to `pool_owner_resolve`, the fail-fast message, `bin/*`, or `test/*`.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this successfully?_ **Yes** — the exact insertion line, the pattern to copy, the normalization pipeline, the verified shellcheck behavior, and the downstream matching contract are all specified below.

### Documentation & References

```yaml
# MUST READ — load these into context before editing
- file: lib/pool.sh
  why: The ONLY source file changed. pool_config_init lives at lines 130-193.
  sections:
    - "helpers (27-95): pool_die (29), _pool_config_bool (82), _pool_config_require_uint (65), _pool_config_canon_path (58) — all printf their result"
    - "header comment table (100-108): ENV VAR → DEFAULT → GLOBAL → CATEGORY columns — add one row here"
    - "§3 CHROME_BIN block (157-166): THE STRING PATTERN TO MIMIC (local-first, ${VAR:-default}, freeze via declare -g, MUTABLE)"
    - "§5 booleans block (178-183): ends at line 183 — INSERT THE NEW BLOCK AFTER THIS, BEFORE the §6 derived-paths comment at line 185"
    - "§6 derived-paths block (185-190): renumber its comment 6→7; it must stay LAST (finalizes paths off POOL_STATE_DIR)"
    - "re-runnable contract comment (124-127): MUTABLE globals, NO init guard — do NOT make POOL_HARNESSES readonly"
    - "line 128 '# shellcheck disable=SC2034': ALREADY covers POOL_HARNESSES (verified — see gotcha); no new directive needed"
  pattern: "local x; x='${VAR:-default}'; <normalize>; POOL_X='$x'; declare -g POOL_X"

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: The docs file changed (Mode A — rides with the work). Env-var table header at line 16.
  sections:
    - "table rows end at line 27 (AGENT_CHROME_ALLOW_SLOW_COPY). INSERT the new row AFTER line 27."
  pattern: 3-column markdown '| Variable | Default | Meaning |' matching the existing rows

- docfile: plan/003_afc2f15931ab/P3M1T1S1/research/findings.md
  why: Verified research for this exact subtask (structure map, SC2034 proof, normalization examples)
  section: "§3 SC2034 gate (the one non-obvious risk) and §4 normalization pipeline"

- prd: PRD.md §2.11 (Discovery & configuration) + §2.4 step 1 (owner resolution) + Decision O9 (§4)
  why: Defines the var, its default, and the matching semantics. The default set and 'never empty' rule come from here.

- file: AGENTS.md
  why: Operating rules. This is a PLANNING→IMPL task: static checks only (bash -n, shellcheck). Do NOT boot Chrome or run the suite against the live sandbox.
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh                                 # ← EDIT (pool_config_init: add §6 block; renumber derived→§7; header comment row)
.agents/skills/agent-browser-pool/references/configuration.md   # ← EDIT (one table row)
bin/agent-browser-pool                      # read-only (no change — dispatcher; owner logic is in pool_wrapper_main/S2)
test/{validate,release_reaper,concurrency,transparency}.sh      # read-only (no test added by S1; coverage is P3.M2)
```

### Desired codebase tree (files touched)

```bash
lib/pool.sh                                 # +1 config section (~8 lines) + 1 header-comment row + renumber one comment
.agents/skills/agent-browser-pool/references/configuration.md   # +1 table row
# No new files. No new tests in S1 (P3.M2.T1 owns multi-harness test coverage).
```

### Known gotchas of our codebase & library quirks

```bash
# CRITICAL — SC2034 ("assigned but never used"): POOL_HARNESSES is NOT consumed in-file
# until S2 lands. TODAY shellcheck is rc=0 only because every other POOL_* global happens to
# be read somewhere in lib/pool.sh. VERIFIED (scratch tests, research/findings.md §3): the
# existing `# shellcheck disable=SC2034` at lib/pool.sh:128 sits immediately before the
# comment(129)+function(130), and that placement SUPPRESSES SC2034 for every `declare -g`
# INSIDE pool_config_init (even with the intervening comment line). ⇒ Adding POOL_HARNESSES
# inside pool_config_init keeps shellcheck green. DO NOT move the assignment out of the
# function; DO NOT add a second directive unless you can prove rc!=0 without it.

# CRITICAL — declare locals SEPARATELY from their command-substitution assignment
# (SC2155 under `set -euo pipefail`). Mimic §3: `local harnesses_in harnesses` THEN assign.
# Capture the tr pipeline via `harnesses="$(printf '%s' "$raw" | tr … | tr …)"`.

# CRITICAL — never make POOL_* readonly and never add an "already-initialized" guard.
# The test harness re-runs pool_config_init per case (lib/pool.sh:124-127). MUTABLE is load-bearing.

# GOTCHA — the stored form must be the CLEAN comma list (e.g. 'pi,claude,codex,agy,antigravity'),
# NOT pre-wrapped in commas. S2 does the comma-wrap at match time:
#   [[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   # double-comma wrap ⇒ exact-token match
# So 'pi' must NOT substring-match 'piXYZ'. Storing clean + wrapping at match site gives that.

# GOTCHA — do NOT trim whitespace. Contract specifies exactly three transforms
# (lowercase, squeeze-commas, trim-end-commas). A sloppy 'pi, claude' would store 'pi, claude'
# and the space-bearing token won't match comm 'claude' — that is the documented contract; users
# must not include spaces. (Future hardening to strip spaces is out of scope for S1.)

# GOTCHA — section numbering. The contract prose calls the new block "§7" but also says insert
# it "before the §6 derived-paths block". Resolution: make the new block §6 (insert between
# current line 183 and line 185) and renumber the existing derived-paths comment from
# '# 6. Derived paths' → '# 7. Derived paths'. Keeps 1..7 monotonic; derived paths stays the
# finalization tail (it depends on POOL_STATE_DIR being final).
```

---

## Implementation Blueprint

### Data models / structure

None new. The only artifact is the global string `POOL_HARNESSES` (lowercased, comma-separated harness-comm tokens, never empty). No JSON/lease changes — the lease `comm` field (PRD §2.8) is written by S2 from the *actual matched* comm, not from this set.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD the recognized-harness config section to pool_config_init (lib/pool.sh)
  - INSERT: a new numbered section BETWEEN line 183
      (POOL_ALLOW_SLOW_COPY="$allow_slow_copy"; declare -g POOL_ALLOW_SLOW_COPY)
    AND line 185 (the '# 6. Derived paths' comment). Label it '# 6. Recognized harnesses …'
    and RENUMBER the following derived-paths comment from '# 6.' to '# 7.' (see gotcha).
  - IMPLEMENT: read AGENT_BROWSER_POOL_HARNESSES with default 'pi,claude,codex,agy,antigravity';
    normalize (lowercase via `tr '[:upper:]' '[:lower:]'`; squeeze commas via `tr -s ','`;
    trim one leading + one trailing comma via bash param expansion `${v#,}` / `${v%,}` —
    safe because tr -s leaves at most a single comma at each end);
    GUARD: if the normalized result is empty, restore the default string;
    freeze into POOL_HARNESSES via `declare -g` (MUTABLE — NOT readonly).
  - FOLLOW pattern: §3 CHROME_BIN block (lib/pool.sh:157-166) — `local` first, then
    `${VAR:-default}` assignment, then `POOL_X="$val"; declare -g POOL_X`.
  - NAMING: global POOL_HARNESSES; local vars harnesses / harnesses_raw (snake_case).
  - DEPENDENCIES: none (foundation subtask). Must run BEFORE the §7 derived-paths block
    is not required (POOL_HARNESSES is independent of derived paths) — placement is for
    readability/numbering only; the guard means order does not affect correctness.
  - REFERENCE IMPLEMENTATION (adapt indentation to the file's 4-space style):
      # 6. Recognized harnesses (owner resolution, PRD §2.11 / Decision O9) — comma-separated
      #    comm values the pool treats as valid lane owners. Normalized to a clean lowercase
      #    comma list (never empty: an empty set would fail every driving command's ancestor
      #    check). Consumed as a lookup by pool_owner_resolve (M1.T1.S2):
      #      [[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   (double-comma wrap ⇒ exact-token).
      local harnesses_raw harnesses
      harnesses_raw="${AGENT_BROWSER_POOL_HARNESSES:-pi,claude,codex,agy,antigravity}"
      harnesses="$(printf '%s' "$harnesses_raw" | tr '[:upper:]' '[:lower:]' | tr -s ',')"
      harnesses="${harnesses#,}"; harnesses="${harnesses%,}"
      [[ -n "$harnesses" ]] || harnesses="pi,claude,codex,agy,antigravity"
      POOL_HARNESSES="$harnesses"; declare -g POOL_HARNESSES

Task 2: ADD the header-comment table row (lib/pool.sh)
  - INSERT: one row in the config-reference table (lines 100-108), immediately AFTER the
    AGENT_CHROME_ALLOW_SLOW_COPY row (line 108) and BEFORE the blank '#' separator (line 109).
  - MATCH: the 4-column comment format '#   <ENV 28c>   <DEFAULT>   <GLOBAL>   <CATEGORY>'.
    AGENT_BROWSER_POOL_HARNESSES is 28 chars (identical length to AGENT_CHROME_ALLOW_SLOW_COPY)
    so it aligns with the existing rows. Use category label 'comma-set'.
  - ROW TEXT (align columns to the surrounding rows):
      #   AGENT_BROWSER_POOL_HARNESSES   pi,claude,codex,agy,antigravity                 POOL_HARNESSES        comma-set (lowercased; empty→default)
  - DO NOT: add anything to the 'Errors' block (lib/pool.sh:119-122) — the harness set
    guards-to-default and never calls pool_die. The 'Boolean rule' / 'Derived' notes need no edit.
  - DEPENDENCIES: Task 1 (names must agree: AGENT_BROWSER_POOL_HARNESSES → POOL_HARNESSES).

Task 3: ADD the docs table row (Mode A — rides with the work; no separate docs subtask)
  - FILE: .agents/skills/agent-browser-pool/references/configuration.md
  - INSERT: one markdown row in the env-var table (header at line 16), immediately AFTER
    line 27 (the AGENT_CHROME_ALLOW_SLOW_COPY row — the table's last row).
  - MATCH: the 3-column '| Variable | Default | Meaning |' format of the existing rows.
  - ROW TEXT (per contract):
      | `AGENT_BROWSER_POOL_HARNESSES` | `pi,claude,codex,agy,antigravity` | comma-separated `comm` values treated as valid lane owners; owner resolution matches the first ancestor whose comm is in this set. Empty/unset → default (never empty) |
  - DO NOT: edit the 'Test-only hooks' note, the prose 'three that most affect behavior'
    section, or any other file. This is a single-row addition.
  - DEPENDENCIES: none (docs); logically paired with Tasks 1-2 (same variable).
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the §3 CHROME_BIN string-config block (the template). Note: local declared
# SEPARATELY from assignment (SC2155-safe under set -euo pipefail); final freeze via
# declare -g; MUTABLE (no readonly) so pool_config_init is re-runnable for the test harness.
local chrome_in chrome_out
chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
…
POOL_CHROME_BIN="$chrome_out"; declare -g POOL_CHROME_BIN

# PATTERN — every POOL_* assignment in this file is the two-statement freeze:
#     POOL_X="$val"; declare -g POOL_X
# POOL_HARNESSES MUST use exactly this shape. See Task 1 reference implementation.

# PATTERN — the empty-guard is a hard safety invariant, not a nicety:
#   `[[ -n "$harnesses" ]] || harnesses="<default>"`
# An empty POOL_HARNESSES would make S2's match predicate fail for ALL comms → every driving
# command fails owner resolution → the pool is bricked. Never allow empty to escape.

# NON-GOAL (do NOT do these in S1):
#   - Do NOT change pool_owner_resolve (still hardcodes comm=='pi' at lib/pool.sh:521) — S2.
#   - Do NOT change the fail-fast message text (lib/pool.sh:3415) — S3.
#   - Do NOT add a selftest/test in test/ — multi-harness coverage is P3.M2.T1.
```

### Integration Points

```yaml
CODE (lib/pool.sh):
  - add section: pool_config_init, between current line 183 (end §5) and line 185 (start §6)
  - renumber comment: '# 6. Derived paths' (185) → '# 7. Derived paths'
  - add header-comment table row: after line 108, before line 109
  - shellcheck directive: NONE added — line 128 already covers it (verified)

DOCS (.agents/skills/agent-browser-pool/references/configuration.md):
  - add table row: after line 27 (last env-var table row)

GLOBAL CONTRACT (new, consumed downstream):
  - POOL_HARNESSES : string, lowercased comma-separated comm tokens, never empty,
                     MUTABLE, frozen by pool_config_init. Default 'pi,claude,codex,agy,antigravity'.
  - consumers: S2 pool_owner_resolve (set-membership + record actual comm),
               S3 fail-fast message (name the supported harnesses from this list)

NO CHANGES TO:
  - pool_owner_resolve, pool_wrapper_main, bin/* (owner logic = S2)
  - test/* (coverage = P3.M2)
  - lease JSON schema, install.sh, README.md (README sweep = P3.M3.T1, separate)
```

---

## Validation Loop

> **AGENTS.md compliance:** all gates below are STATIC (never spawn a browser/daemon, never
> touch the live `$HOME`/Chrome). Run them directly — they cannot hang the sandbox.

### Level 1: Syntax & Lint (MANDATORY — contract point 4)

```bash
# After editing lib/pool.sh — both MUST be rc 0.
bash -n lib/pool.sh               && echo "syntax OK"
shellcheck -s bash lib/pool.sh    && echo "shellcheck OK"
# Expected: both print OK and exit 0. If shellcheck reports SC2034 for POOL_HARNESSES,
# the assignment was placed OUTSIDE pool_config_init — move it back inside the function
# (the line-128 directive covers in-function assignments only; see gotcha).
```

### Level 2: Isolated runtime micro-check (OPTIONAL but recommended — confirm the logic)

A bounded, self-cleaning check that calls `pool_config_init` under a throwaway `HOME` with
various overrides and asserts `POOL_HARNESSES`. It sources the real lib (read-only) and only
writes under a temp tree it removes on exit. Never boots Chrome.

```bash
# Run from the repo root. Bounded by `timeout`; reaps nothing (no background procs).
timeout 30 bash -c '
  set -euo pipefail
  root="$(mktemp -d -t abpool-s1.XXXXXX)"
  trap "rm -rf \"$root\"" EXIT
  export HOME="$root/home"; mkdir -p "$HOME"
  export AGENT_BROWSER_POOL_STATE="$root/state"
  export AGENT_CHROME_EPHEMERAL_ROOT="$root/active"
  export AGENT_CHROME_MASTER="$root/master"; mkdir -p "$AGENT_CHROME_MASTER"
  # source the lib (defines pool_config_init + helpers; no side effects until called)
  . ./lib/pool.sh

  chk() { # chk <input-or-UNSET> <expected>   (UNSET ⇒ unset the var)
    if [[ "$1" == UNSET ]]; then unset AGENT_BROWSER_POOL_HARNESSES
    else export AGENT_BROWSER_POOL_HARNESSES="$1"; fi
    pool_config_init
    [[ "$POOL_HARNESSES" == "$2" ]] || { echo "FAIL: input=[$1] got=[$POOL_HARNESSES] want=[$2]"; exit 1; }
  }
  D="pi,claude,codex,agy,antigravity"
  chk UNSET            "$D"          # unset → default
  chk ""               "$D"          # empty → default
  chk ",,,,"           "$D"          # all-commas → empty → default
  chk "PI,Claude,CODEX" "pi,claude,codex"      # lowercase + no trailing default merge
  chk ",pi,,claude,"   "pi,claude"             # squeeze + trim
  chk "agy"            "agy"                   # single token
  echo "ALL MICRO-CHECKS PASS"
'
```

If the micro-check is skipped, Level 1 + a read-through of Task 1's reference implementation
is sufficient (the logic is small and the contract is explicit). Do NOT add this as a permanent
test in `test/` — that is P3.M2.T1's scope.

### Level 3: Docs render check

```bash
# Confirm the new row is a well-formed 3-column markdown table row and sits after line 27.
sed -n "16,30p" .agents/skills/agent-browser-pool/references/configuration.md
# Eyeball: the AGENT_BROWSER_POOL_HARNESSES row has exactly 3 pipe-separated cells and
# appears directly under the AGENT_CHROME_ALLOW_SLOW_COPY row. (No markdown linter is
# configured in this repo; a visual column count is the gate.)
```

### Level 4: Downstream-cohesion read-check (static — guards scope)

```bash
# S1 must NOT have touched owner resolution or the fail-fast message (those are S2/S3).
grep -n 'comm == "pi"\|require a pi ancestor\|require a supported agent harness' lib/pool.sh
# Expected: the existing pool_owner_resolve (comm == "pi") and the existing fail-fast
# message are UNCHANGED. Only pool_config_init + the header comment + configuration.md changed.
```

---

## Final Validation Checklist

### Technical validation
- [ ] `bash -n lib/pool.sh` ⇒ rc 0
- [ ] `shellcheck -s bash lib/pool.sh` ⇒ rc 0 (no new SC2034 — covered by line 128)
- [ ] (optional) Level 2 micro-check prints "ALL MICRO-CHECKS PASS"
- [ ] Level 3 docs row is a well-formed 3-column row after line 27
- [ ] Level 4 grep confirms pool_owner_resolve + fail-fast message unchanged

### Feature validation
- [ ] `POOL_HARNESSES == pi,claude,codex,agy,antigravity` when env var unset
- [ ] Normalization: lowercase + squeeze-commas + trim-end-commas (verified by micro-check)
- [ ] Empty-after-normalization ⇒ default (never empty)
- [ ] `POOL_HARNESSES` is MUTABLE + set via `declare -g` inside `pool_config_init`
- [ ] Header comment table has the `AGENT_BROWSER_POOL_HARNESSES → POOL_HARNESSES (comma-set)` row
- [ ] `configuration.md` env-var table has the new row after `AGENT_CHROME_ALLOW_SLOW_COPY`

### Code quality
- [ ] Follows the §3 CHROME_BIN string pattern (local-first, `${VAR:-default}`, `declare -g`)
- [ ] Section numbering monotonic (new block §6; derived paths renumbered §7)
- [ ] No `readonly`, no init guard (preserves the re-runnable contract)
- [ ] SC2155 avoided (locals declared separately from command-substitution assignment)
- [ ] Scope respected: no edits to `pool_owner_resolve`, `bin/*`, `test/*`, lease schema, README

### Documentation
- [ ] Header comment row matches the 4-column format of surrounding rows
- [ ] `configuration.md` row matches the 3-column format and uses the contract's exact wording

---

## Anti-Patterns to Avoid

- ❌ Don't add a second `# shellcheck disable=SC2034` — the existing one at line 128 already covers in-function `declare -g` (verified). Only add one if you can demonstrate rc!=0.
- ❌ Don't pre-wrap `POOL_HARNESSES` in commas (e.g. `,pi,claude,`). Store the CLEAN list; S2 wraps at match time. Storing wrapped would double-wrap and break the predicate.
- ❌ Don't make `POOL_HARNESSES` `readonly` or add an "already-initialized" guard — the test harness re-runs `pool_config_init` per case (lib/pool.sh:124-127).
- ❌ Don't trim whitespace, "validate" tokens, or dedupe beyond `tr -s ','` — the contract specifies exactly three transforms. Over-normalizing risks diverging from S2's match assumptions.
- ❌ Don't touch `pool_owner_resolve` / the fail-fast message / `test/*` — those are S2, S3, and P3.M2 respectively. S1 is config-only.
- ❌ Don't run the real test suite or boot Chrome to "verify" this — it's a pure config function; static gates + the optional isolated micro-check are the correct validation (AGENTS.md §1).
- ❌ Don't `local x="$(…)"` in one statement (SC2155) — declare `local` first, then assign (mirrors §3).

---

**Confidence score: 9/10** for one-pass implementation success. The change is small (one config block + one comment row + one docs row), the insertion point and pattern are pinned to exact line numbers, the one non-obvious risk (SC2034 after S1) is verified resolved, and the normalization pipeline is fully specified with worked input→output examples. The -1 reserves for the implementer mis-reading the §6/§7 numbering note — mitigated by spelling out the resolution explicitly in the gotcha and Task 1.
