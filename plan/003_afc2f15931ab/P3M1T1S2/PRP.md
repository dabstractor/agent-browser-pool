# PRP — P3.M1.T1.S2: Generalize `pool_owner_resolve` to set-membership + record actual matched comm

**Parent plan:** P3 (Multi-Harness Owner Resolution, Decision O9) → M1 (Core generalization, `lib/pool.sh`) → T1 → **S2**
**Scope:** ONE subtask. Edits `pool_owner_resolve` (4 logic edits + header-comment rephrase), corrects one misleading comment in S1's block, and does a Mode-A docs sweep in `configuration.md` + `SKILL.md`. Does NOT touch the fail-fast message TEXT (that is S3), the identity layer, or `test/*` (that is P3.M2).
**Upstream dependency:** P3.M1.T1.S1 — **LANDED**. It added the `POOL_HARNESSES` global (lowercased, single-comma, never-empty, default `pi,claude,codex,agy,antigravity`) to `pool_config_init`. S2 consumes it.

---

> ## ⚠️ DEVIATION FROM CONTRACT — READ FIRST (proven, not optional)
>
> The item contract (point 3c) and S1's in-code comment (`lib/pool.sh:190`) specify the
> walk-loop match predicate with **DOUBLE** commas:
> ```bash
> [[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   # ← CONTRACT/S1: BROKEN
> ```
> **This is provably broken.** `POOL_HARNESSES` is stored as a *clean single-comma* list
> (`pi,claude,codex,agy,antigravity`). Wrapping its ends with `,,` gives
> `,,pi,claude,codex,agy,antigravity,,` — between tokens there is still only ONE comma, so
> the pattern `*,,$comm,*` (which demands a double comma *before* the token) matches ONLY
> the first token `pi`. `claude`/`codex`/`agy`/`antigravity` **never match** → every non-pi
> driving command fails fast → P3's whole purpose is silently defeated.
>
> Scratch-test proof (static; deleted after): with the double-comma form, `comm="claude"`
> did NOT match; only `comm="pi"` did.
>
> **This PRP specifies the CORRECT single-comma predicate instead:**
> ```bash
> [[ ",$POOL_HARNESSES," == *",$comm,"* ]]       # ← CORRECT: single-comma wrap
> ```
> Verified: all 5 default tokens match; substrings (`i`,`pixyz`,`claude2`) rejected;
> `shellcheck` rc 0. See `research/findings.md` FINDING 1 for full proof. **Do NOT use the
> double-comma form.** S1's misleading comment at `lib/pool.sh:190` is corrected in Task 6.

---

## Goal

**Feature Goal:** `pool_owner_resolve` resolves the owning process by **set-membership** over the configured `POOL_HARNESSES` (instead of a hardcoded `comm == "pi"`), and records the **ACTUAL matched harness comm** in `POOL_OWNER_COMM` — so identity, lease-reuse, and stale-detection work identically for every supported harness (pi/claude/codex/agy/antigravity/…). It returns `POOL_OWNER_PID == 0` only when NO recognized harness is an ancestor.

**Deliverable:**
1. Four logic edits inside `pool_owner_resolve` (`lib/pool.sh`): (a) TEST MODE records the override pid's real comm; (b) add `found_comm=""` local; (c) walk-loop check → single-comma set-membership, capturing `found_comm`; (d) RESULT writes `$found_comm`. Plus a header-comment rephrase (f) and a no-ancestor log rephrase (e).
2. One comment-only correction in S1's `pool_config_init` block (`lib/pool.sh:190`) — the double-comma example → single-comma.
3. Mode-A docs sweep: ~5 phrasings in `configuration.md` + ~4 in `SKILL.md` (+ recommended consistency phrasings).

**Success Definition:** `bash -n lib/pool.sh` and `shellcheck -s bash lib/pool.sh` both rc 0; `pool_owner_resolve` records the real matched comm for any comm in `POOL_HARNESSES` (pi or otherwise) and returns PID=0 only when no recognized harness is an ancestor; lease-write sites (`_pool_acquire_critical_section`, `_pool_adopt_lane`) now persist the actual comm without further edits; existing pi-owner behavior is byte-identical; docs no longer say "pi ancestor"/"owning pi process".

---

## Why

- **Delivers P3 / Decision O9 (multi-harness).** Owner resolution was `pi`-only (PRD §2.4 step 1, §1.1). S1 added the configurable set; S2 is the consumer that makes resolution actually use it. PRD §2.8: `comm` records the ACTUAL matched harness so `status`/`doctor` show which tool owns each lane and stale-detection works across all harnesses.
- **Unblocks the rest of P3.** S3 (fail-fast message names the supported harnesses) and P3.M2.T1 (the non-pi selftest `selftest_owner_resolves_non_pi_harness`) both depend on S2 recording a real non-pi comm. S2's TEST-MODE change (read `/proc/$ovr_pid/comm`) is what lets P3.M2.T1.S2 simulate a claude owner WITHOUT a new env-var hook.
- **Truthfulness.** Today `POOL_OWNER_COMM` is hardcoded `"pi"` even when the real owner is (say) claude. Once generalized, the stored comm is the kernel-set truth → `status`/`doctor`/audit logs are accurate.

---

## What

### Visible behavior

- A driving command run under **any** recognized harness (`comm ∈ POOL_HARNESSES`) resolves an owner and gets a lane, exactly as `pi` does today.
- `agent-browser-pool status` / `doctor` show the real owning comm per lane (e.g. `claude`, not always `pi`).
- A driving command with **no** recognized-harness ancestor still fails fast (the fail-fast *message* is S3; S2 only keeps the PID==0 *condition* intact).
- TEST MODE (`AGENT_BROWSER_POOL_OWNER_PID` set): the recorded comm is the **real** `/proc/<pid>/comm` of the simulated owner (a pi sim → `"pi"`, preserving every existing test; a claude sim → `"claude"`).

### Success criteria

- [ ] Walk-loop uses **single-comma** set-membership `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]` (NOT double-comma).
- [ ] `found_comm` is captured in the walk loop and written to `POOL_OWNER_COMM` in the RESULT block.
- [ ] TEST MODE records `$(cat /proc/$ovr_pid/comm 2>/dev/null || printf 'pi')` (falls back to `pi`).
- [ ] `POOL_OWNER_PID == 0` iff no recognized harness is an ancestor (condition unchanged at the fail-fast site).
- [ ] Lease-write sites persist the real comm with **no** edits to them (auto-correct).
- [ ] `bash -n lib/pool.sh` ⇒ rc 0; `shellcheck -s bash lib/pool.sh` ⇒ rc 0.
- [ ] Header comment + no-ancestor log + docs rephrased off "pi ancestor / owning pi process".
- [ ] No change to `pool_owner_alive`, `pool_lane_is_stale`, `pool_lease_find_mine`, the fail-fast *condition*, `bin/*`, or `test/*`.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this successfully?_ **Yes** — every edit is specified by exact current text (NOT line numbers — they drift), the one non-obvious correctness trap (double-comma bug) is proven and the fix given, the consumers are confirmed auto-correcting, and validation is static + a bounded isolated micro-check. See `research/findings.md`.

### Documentation & References

```yaml
# MUST READ — load into context before editing
- file: lib/pool.sh
  why: The ONLY source file changed. pool_owner_resolve is the function body to edit.
  sections:
    - "pool_owner_resolve (now ~line 498, post-S1): header comment + TEST MODE + walk loop + RESULT + no-ancestor log"
    - "TEST MODE block: the `POOL_OWNER_COMM=\"pi\";` whose PRECEDING line is `POOL_OWNER_PID=\"$ovr_pid\";` (EDIT a)"
    - "walk loop: `local ppid=\"\" comm=\"\" line=\"\" found_pid=\"\" steps=0` (EDIT b) + `if [[ \"$comm\" == \"pi\" ]]; then found_pid=\"$pid\"; break; fi` (EDIT c)"
    - "RESULT block: the `POOL_OWNER_COMM=\"pi\";` whose PRECEDING line is `POOL_OWNER_PID=\"$found_pid\";` (EDIT d)"
    - "no-ancestor log: `_pool_log \"pool_owner_resolve: no pi ancestor (passthrough mode)\"` (EDIT e)"
    - "S1 block ~line 186-196: the comment at ~190 shows the BROKEN double-comma predicate (Task 6 corrects it)"
  pattern: "every POOL_* global is frozen as `POOL_X=\"$val\"; declare -g POOL_X` (two statements). Match this shape."

- file: .agents/skills/agent-browser-pool/references/configuration.md
  why: Mode-A docs sweep (rides with the work). 5 REQUIRED rephrases + consistency items.
  match: by exact phrase (S1 added a table row ~line 28, so line numbers shifted; match TEXT).

- file: .agents/skills/agent-browser-pool/SKILL.md
  why: Mode-A docs sweep. 4 REQUIRED rephrases + consistency items. (S1 did NOT touch SKILL.md.)

- docfile: plan/003_afc2f15931ab/P3M1T1S2/research/findings.md
  why: Verified research for THIS subtask — esp. FINDING 1 (double-comma bug + proof) and FINDING 3 (exact match targets).
  section: "FINDING 1 (the bug), FINDING 2 (line drift → match on text), FINDING 4 (consumers auto-correct)"

- file: plan/003_afc2f15931ab/P3M1T1S1/PRP.md
  why: S1 contract (LANDED). Defines POOL_HARNESSES shape (clean single-comma lowercase list, never empty, MUTABLE) — the input S2 consumes. Confirms the matching predicate S2 must use.

- prd: PRD.md §2.4 step 1 (resolve OWNER), §2.8 (lease comm = actual matched harness), §2.11 ($AGENT_BROWSER_POOL_HARNESSES), Decision O9 (§4)
  why: The requirement being implemented.

- file: AGENTS.md
  why: Operating rules. PLANNING/IMPL task: STATIC checks only (bash -n, shellcheck, bounded isolated micro-check). Do NOT boot Chrome or run the suite against the live sandbox. Reap any subprocess.
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh                                              # ← EDIT pool_owner_resolve (4 logic + comment) + S1 comment fix (Task 6)
.agents/skills/agent-browser-pool/references/configuration.md   # ← EDIT (Mode-A docs sweep)
.agents/skills/agent-browser-pool/SKILL.md               # ← EDIT (Mode-A docs sweep)
bin/agent-browser-pool                                   # read-only (dispatcher; owner logic is in pool_owner_resolve)
test/{validate,release_reaper,concurrency,transparency}.sh      # read-only (multi-harness coverage = P3.M2.T1)
```

### Desired codebase tree (files touched)

```bash
lib/pool.sh                                              # 4 logic edits + header-comment rephrase + 1 S1-comment fix
.agents/skills/agent-browser-pool/references/configuration.md   # ~5 rephrases (+ consistency)
.agents/skills/agent-browser-pool/SKILL.md               # ~4 rephrases (+ consistency)
# No new files. No tests added (P3.M2.T1 owns multi-harness coverage).
```

### Known gotchas of our codebase & library quirks

```bash
# CRITICAL — DO NOT USE THE DOUBLE-COMMA PREDICATE. It is in the contract (3c) and in
# S1's comment (lib/pool.sh:190) but it is BROKEN: with a single-comma list it matches
# only the first token. Use SINGLE comma: [[ ",$POOL_HARNESSES," == *",$comm,"* ]].
# Proof: research/findings.md FINDING 1.

# CRITICAL — match on EXACT TEXT, never line numbers. S1 landed in parallel and shifted
# every line the contract cites by ~+13 (contract said 486-583; reality is ~498-594 and
# will drift further). The two `POOL_OWNER_COMM="pi";` lines differ only in their
# PRECEDING context line ($ovr_pid vs $found_pid) and inter-token whitespace — always
# include the preceding PID line as edit context to disambiguate.

# GOTCHA — SC2155 does NOT fire on the TEST-MODE line. SC2155 targets `local X="$(…)"`.
# The TEST-MODE assignment is a bare GLOBAL: `POOL_OWNER_COMM="$(cat … || printf 'pi')"; declare -g …`
# (no `local`), so SC2155 is not triggered. If for any reason shellcheck flags it, fall
# back to the two-statement form (see Task 1 contingency). The walk-loop uses plain vars,
# not command-substitution assignments, so no SC2155 risk there.

# GOTCHA — `/proc/$pid/comm` is kernel-set, ≤15 chars, no embedded newline (command
# substitution strips the trailing newline anyway). For a real pi process it is exactly
# "pi"; for claude it is "claude". The `|| printf 'pi'` fallback preserves existing
# pi-sim tests if the override pid is already dead at resolve time.

# GOTCHA — never make POOL_OWNER_* readonly and never add an init guard. pool_owner_resolve
# RESETS the globals on every entry (the `POOL_OWNER_PID="0"; …; declare -g …` block) —
# this is the re-runnable contract (the test harness calls it repeatedly). Preserve it.

# GOTCHA — keep the walk loop's `|| true` on the `/proc/$pid/comm` read and the existing
# ppid-walk termination conditions (ppid==1, ==0, ==pid, non-numeric). Only the comm
# equality test changes; do not touch the rest of the loop body.
```

---

## Implementation Blueprint

### Data models / structure

None new. `POOL_OWNER_COMM` becomes the actual matched comm (was a hardcoded `"pi"`). The
lease `.owner.comm` (PRD §2.8) is written downstream from `$POOL_OWNER_COMM` by
`_pool_acquire_critical_section` / `_pool_adopt_lane` — those need **no** edit (they
already use `"$POOL_OWNER_COMM"`, confirmed FINDING 4). Identity model `(pid, comm,
starttime)` is unchanged; only the acceptable comm *set* widens and the recorded comm
becomes the real match.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT pool_owner_resolve — TEST MODE records the real comm (lib/pool.sh)
  - FIND (match on TEXT; context line disambiguates from the RESULT-block twin):
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM
  - REPLACE the second line with:
        POOL_OWNER_COMM="$(cat /proc/$ovr_pid/comm 2>/dev/null || printf 'pi')"; declare -g POOL_OWNER_COMM
  - WHY: records the sim owner's real kernel-set comm. A pi sim → "pi" (preserves every
    existing test); a claude sim → "claude" (enables P3.M2.T1.S2 with NO new env hook).
    Falls back to "pi" if /proc read fails. NOTE: this is a bare GLOBAL assignment (no
    `local`) so SC2155 does not fire (verified).
  - CONTINGENCY (only if shellcheck flags SC2155 — it should not): use two statements:
        local ovr_comm=""
        ovr_comm="$(cat /proc/$ovr_pid/comm 2>/dev/null || printf 'pi')"
        POOL_OWNER_COMM="$ovr_comm"; declare -g POOL_OWNER_COMM

Task 2: EDIT pool_owner_resolve — add found_comm local (lib/pool.sh, walk-loop declaration)
  - FIND (match on TEXT):
        local ppid="" comm="" line="" found_pid="" steps=0
  - REPLACE with:
        local ppid="" comm="" line="" found_pid="" found_comm="" steps=0
  - WHY: carries the matched comm out of the loop into the RESULT block. Must be declared
    here (loop scope) so it survives the `break`.

Task 3: EDIT pool_owner_resolve — walk-loop check → set-membership (lib/pool.sh)
  - FIND (match on TEXT; the 3 lines inside the while body):
        if [[ "$comm" == "pi" ]]; then
            found_pid="$pid"
            break
        fi
  - REPLACE with:
        if [[ ",$POOL_HARNESSES," == *",$comm,"* ]]; then
            found_pid="$pid"
            found_comm="$comm"
            break
        fi
  - CRITICAL: SINGLE comma (",$POOL_HARNESSES," and *",$comm,"*). NOT double-comma —
    see the deviation banner + research FINDING 1. The loop already reads comm generically
    (`IFS= read -r comm < /proc/$pid/comm`); ONLY the equality test changes.
  - WHY: matches the first ancestor whose comm is any recognized harness, and captures
    WHICH one into found_comm.

Task 4: EDIT pool_owner_resolve — RESULT writes $found_comm (lib/pool.sh)
  - FIND (match on TEXT; preceding $found_pid line disambiguates from TEST-MODE twin):
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM
  - REPLACE the second line with:
        POOL_OWNER_COMM="$found_comm"; declare -g POOL_OWNER_COMM
  - WHY: records the ACTUAL matched harness comm (not a constant). Downstream lease
    writers then persist it automatically (FINDING 4).

Task 5: EDIT pool_owner_resolve — header comment + no-ancestor log (lib/pool.sh)
  - 5a. FIND the header-comment phrase (in the line containing "§1.1"):
        (walk ppid to comm=='pi')
    REPLACE with:
        (walk ppid to first ancestor whose comm is a recognized harness)
  - 5b. FIND the LOGIC-block line:
        # directly; (2) REAL MODE walk ppid from $$ to comm=='pi'; (3) no pi ancestor
    REPLACE with:
        # directly; (2) REAL MODE walk ppid from $$ to first ancestor in $POOL_HARNESSES; (3) no recognized-harness ancestor
    (This single replacement fixes BOTH the "(2) … comm=='pi'" and the "(3) no pi ancestor"
    phrases in one sentence — keeps the comment coherent. The contract spelled out only the
    "(3)" rephrase; the "(2)" part is the same hardcoded-pi language in the same sentence and
    MUST move with it to avoid a self-contradiction.)
  - 5c. FIND the no-ancestor log:
        _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
    REPLACE with:
        _pool_log "pool_owner_resolve: no recognized-harness ancestor (passthrough mode)"
  - WHY: the comment + log now describe generalized resolution. (Header line 1
    "Resolve the owning pi process" may optionally become "owning harness process" — minor.)

Task 6: CORRECT S1's misleading comment (lib/pool.sh, ~line 190, comment-only)
  - FIND (inside S1's recognized-harnesses block in pool_config_init):
        #      [[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   (double-comma wrap ⇒ exact-token).
  - REPLACE with:
        #      [[ ",$POOL_HARNESSES," == *",$comm,"* ]]   (comma-delimited wrap ⇒ exact-token match).
  - WHY: that comment documents exactly the predicate Task 3 implements. As written it shows
    the BROKEN double-comma form; leaving it makes the file self-contradictory and would
    mislead the next reader. Comment-only; no behavior change. (S1 landed; this is a factual
    fix in the same file S2 owns.)

Task 7: DOCS — configuration.md (Mode A; match on TEXT, lines shifted after S1)
  FILE: .agents/skills/agent-browser-pool/references/configuration.md
  REQUIRED rephrases (exact phrase → replacement):
    7a. "resolve the owning `pi` PID" → "resolve the owning recognized-harness PID"
    7b. "there is no `pi` ancestor" → "there is no recognized-harness ancestor"
    7c. "For a driving command under `pi`:" → "For a driving command under a supported harness:"
    7d. "resolve owning pi PID (walk ppid → comm == 'pi')" →
        "resolve owning harness PID (walk ppid → first ancestor whose comm is in $POOL_HARNESSES)"
    7e. "Your owning `pi` process exits" → "Your owning harness process exits"
  CONSISTENCY (recommended; would otherwise be factually false post-P3 — same file):
    7f. troubleshooting matrix ~L122: "Driving command run outside `pi` (no pi ancestor → fail-fast)"
        → "Driving command run outside a supported harness (no recognized-harness ancestor → fail-fast)"
        and "Run your browser work under `pi`;" → "Run your browser work under a supported harness;"
  DO NOT touch the fail-fast MESSAGE text (~L55-56: "… require a pi ancestor …") — that is S3.

Task 8: DOCS — SKILL.md (Mode A; S1 did not touch it, lines stable; match on TEXT)
  FILE: .agents/skills/agent-browser-pool/SKILL.md
  REQUIRED rephrases (exact phrase → replacement):
    8a. "(your owning `pi` process and its start time)" → "(your owning harness process and its start time)"
    8b. "keyed on your owning `pi` process (and its start time" → "keyed on your owning harness process (and its start time"
    8c. "resolves your pi owner" → "resolves your harness owner"
    8d. "When your owning `pi` process exits" → "When your owning harness process exits"
  CONSISTENCY (recommended; §4 pitfall, would otherwise be false post-P3):
    8e. "driving commands require a `pi` ancestor" → "driving commands require a supported agent harness"
        and "Run your browser work under `pi`; don't try to bypass it." →
            "Run your browser work under a supported harness (pi/claude/codex/agy); don't try to bypass it."
```

### Implementation Patterns & Key Details

```bash
# PATTERN — the single-comma "in-list" match (THE correctness crux). DO NOT use double comma.
#   lhs: wrap the clean list with ONE comma each end  → ",pi,claude,codex,agy,antigravity,"
#   rhs: *",<token>,"*  → every token is comma-delimited both sides ⇒ exact-token, no substring.
if [[ ",$POOL_HARNESSES," == *",$comm,"* ]]; then … fi

# PATTERN — every POOL_OWNER_* freeze is two statements (match the file's existing style):
POOL_OWNER_COMM="$found_comm"; declare -g POOL_OWNER_COMM

# PATTERN — the global reset on entry is the re-runnable contract; DO NOT remove/readonly it:
POOL_OWNER_PID="0"; POOL_OWNER_COMM=""; POOL_OWNER_STARTTIME=""; POOL_OWNER_CWD=""
declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD

# NON-GOALS (do NOT do these in S2):
#   - Do NOT change the fail-fast MESSAGE text (lib/pool.sh pool_wrapper_main pool_die …) — S3.
#     (S2 keeps the PID==0 CONDITION intact.)
#   - Do NOT touch pool_owner_alive / pool_lane_is_stale / pool_lease_find_mine — comm-generic (FINDING 4).
#   - Do NOT touch the lease-write sites (_pool_acquire_critical_section, _pool_adopt_lane) — auto-correct.
#   - Do NOT add a test in test/ — multi-harness coverage is P3.M2.T1.
#   - Do NOT use the double-comma predicate (contract 3c) — see the deviation banner.
```

### Integration Points

```yaml
CODE (lib/pool.sh):
  - pool_owner_resolve: 4 logic edits (Tasks 1-4) + header/log rephrase (Task 5)
  - pool_config_init (S1's block): comment-only correction (Task 6)
  - shellcheck: no new directive needed (SC2034 already covers POOL_HARNESSES in-file now
    that pool_owner_resolve reads it; SC2155 not triggered by the TEST-MODE global assignment)

DOCS (Mode A — ride with the work):
  - configuration.md: Tasks 7a-7e required (+ 7f consistency)
  - SKILL.md: Tasks 8a-8d required (+ 8e consistency)

NO CHANGES TO:
  - fail-fast message text (S3), pool_owner_alive, pool_lane_is_stale, pool_lease_find_mine,
    lease-write sites, bin/*, test/*, lease JSON schema, install.sh, README.md (README = P3.M3.T1)

DOWNSTREAM AUTO-CORRECT (verified FINDING 4):
  - _pool_acquire_critical_section writes "$POOL_OWNER_COMM" into .owner.comm  → real comm now
  - _pool_adopt_lane            --arg comm "$POOL_OWNER_COMM"                  → real comm now
  - pool_lease_find_mine        matches owner.comm == POOL_OWNER_COMM          → works for any comm
```

---

## Validation Loop

> **AGENTS.md compliance:** every gate below is STATIC or a bounded isolated micro-check.
> None boots Chrome, launches a daemon, or touches the live `$HOME`/Chrome. They cannot
> hang the sandbox. Reap any subprocess (the micro-check spawns none).

### Level 1: Syntax & Lint (MANDATORY — contract point 4)

```bash
bash -n lib/pool.sh               && echo "syntax OK"
shellcheck -s bash lib/pool.sh    && echo "shellcheck OK"
# Expected: both OK, rc 0. If shellcheck flags SC2155 on the TEST-MODE line, apply the
# Task-1 contingency (declare local separately). If it flags anything else, READ the
# message and fix — do not blanket-disable.
```

### Level 2: Isolated micro-check of the resolve logic (OPTIONAL but recommended)

A bounded, self-cleaning check that sources the real `lib/pool.sh` (read-only) under a
throwaway `HOME`/state, drives `pool_owner_resolve` via the TEST-MODE override with
simulated owners of varying comm, and asserts `POOL_OWNER_COMM`. It uses a real
short-lived `$BASHPID` subprocess as the "sim owner" so `/proc/$pid/comm` is truthful.
Never boots Chrome. Reaps the helper on exit.

```bash
# Run from the repo root. Bounded by `timeout`; cleans its temp tree.
timeout 30 bash -c '
  set -euo pipefail
  root="$(mktemp -d -t abpool-s2.XXXXXX)"; trap "rm -rf \"$root\"" EXIT
  export HOME="$root/home"; mkdir -p "$HOME"
  export AGENT_BROWSER_POOL_STATE="$root/state"
  export AGENT_CHROME_EPHEMERAL_ROOT="$root/active"
  export AGENT_CHROME_MASTER="$root/master"; mkdir -p "$AGENT_CHROME_MASTER"
  . ./lib/pool.sh

  # spawn a named "sim owner" whose real /proc/.../comm is <name>; return its pid on stdout
  spawn_owner() { # spawn_owner <comm-name>  → echoes pid
    local nm="$1" fifo="$root/f.$RANDOM"
    mkfifo "$fifo"; ( exec -a "$nm" bash -c "read x <\"$fifo\"; exit 0" ) & local p=$!
    : <>"$fifo" & sleep 0.05
    echo "$p"
  }

  # pi sim owner → comm must be "pi" (preserves existing tests)
  p="$(spawn_owner pi)"
  AGENT_BROWSER_POOL_OWNER_PID="$p" AGENT_BROWSER_POOL_OWNER_STARTTIME="$(awk "{print \$22}" /proc/$p/stat)" \
    pool_config_init; pool_owner_resolve
  [[ "$POOL_OWNER_COMM" == "pi" ]] || { echo "FAIL: pi-sim → [$POOL_OWNER_COMM]"; kill "$p" 2>/dev/null||true; exit 1; }
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

  # non-pi sim owner NOT in default set → still recorded truthfully (TEST MODE never filters);
  # the SET-MEMBERSHIP filter is only exercised by the REAL walk (P3.M2.T1.S2). Here we just
  # confirm TEST MODE stops hardcoding "pi".
  p="$(spawn_owner myagent)"
  AGENT_BROWSER_POOL_OWNER_PID="$p" AGENT_BROWSER_POOL_OWNER_STARTTIME="$(awk "{print \$22}" /proc/$p/stat)" \
    pool_owner_resolve
  [[ "$POOL_OWNER_COMM" == "myagent" ]] || { echo "FAIL: myagent-sim → [$POOL_OWNER_COMM] (expected myagent, not pi)"; kill "$p" 2>/dev/null||true; exit 1; }
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

  echo "ALL S2 MICRO-CHECKS PASS"
'
```

> NOTE: this micro-check exercises Tasks 1 + 4 (TEST MODE records the real comm). The
> REAL walk-loop set-membership (Task 3) is most directly proven by P3.M2.T1.S2's
> `selftest_owner_resolves_non_pi_harness` (out of S2 scope). A pure-logic proof of the
> predicate is the scratch test in `research/findings.md` FINDING 1 (single-comma matches
> all 5 tokens; rejects substrings). Do NOT add this micro-check to `test/` permanently —
> P3.M2.T1 owns test coverage.

### Level 3: Downstream-cohesion read-check (static — guards scope)

```bash
# S2 must NOT have changed the fail-fast CONDITION or the identity layer.
grep -n 'POOL_OWNER_PID.*== "0"\|expected_comm=\${3:-pi}\|pool_owner_alive "\$pid" "\$starttime"' lib/pool.sh
# Expected: the fail-fast condition (== "0") and pool_owner_alive/pool_lane_is_stale are
# UNCHANGED. Only pool_owner_resolve + S1's comment + the two docs changed.
#
# Confirm the lease-write sites still reference $POOL_OWNER_COMM (untouched, auto-correcting):
grep -n -- '--arg comm "\$POOL_OWNER_COMM"\|"\$POOL_OWNER_PID" "\$POOL_OWNER_COMM"' lib/pool.sh
```

### Level 4: Docs consistency grep (static)

```bash
# After the sweep, no stale "pi ancestor" / "owning `pi` process" should remain in the
# edited docs (except the fail-fast MESSAGE text in configuration.md, which is S3's):
grep -n 'owning `pi` process\|pi ancestor\|under `pi`\|walk ppid → comm == .pi.\|resolves your pi owner' \
  .agents/skills/agent-browser-pool/references/configuration.md \
  .agents/skills/agent-browser-pool/SKILL.md
# Expected: in configuration.md, only the ~L55-56 fail-fast MESSAGE quote may still say
# "pi ancestor" (S3 will fix it). In SKILL.md, zero matches for these phrases.
```

---

## Final Validation Checklist

### Technical validation
- [ ] `bash -n lib/pool.sh` ⇒ rc 0
- [ ] `shellcheck -s bash lib/pool.sh` ⇒ rc 0 (no SC2155 on the TEST-MODE line; no new disables)
- [ ] (optional) Level 2 micro-check prints "ALL S2 MICRO-CHECKS PASS"
- [ ] Level 3 grep confirms fail-fast condition + identity layer + lease-write sites unchanged
- [ ] Level 4 docs grep: no stale "pi ancestor/owning `pi` process" except S3's message text

### Feature validation
- [ ] Walk loop uses **single-comma** set-membership `[[ ",$POOL_HARNESSES," == *",$comm,"* ]]` (NOT double)
- [ ] `found_comm` captured in walk loop; RESULT writes `POOL_OWNER_COMM="$found_comm"`
- [ ] TEST MODE records `$(cat /proc/$ovr_pid/comm 2>/dev/null || printf 'pi')`
- [ ] pi sim owner ⇒ `POOL_OWNER_COMM=="pi"` (existing tests preserved)
- [ ] non-pi sim owner ⇒ `POOL_OWNER_COMM` == that owner's real comm (not hardcoded "pi")
- [ ] `POOL_OWNER_PID==0` iff no recognized-harness ancestor (fail-fast condition intact)
- [ ] Lease `.owner.comm` now persists the real comm with NO edit to the write sites

### Code quality
- [ ] Edits matched on EXACT TEXT (not line numbers); two `POOL_OWNER_COMM="pi";` sites disambiguated by context
- [ ] S1's misleading double-comma comment corrected (Task 6) — file no longer self-contradictory
- [ ] Re-runnable contract preserved (global reset on entry; no `readonly`, no init guard)
- [ ] Scope respected: no edits to fail-fast message text, identity layer, lease writers, bin/*, test/*

### Documentation
- [ ] configuration.md: 7a–7e rephrased (+ 7f consistency); fail-fast MESSAGE text left for S3
- [ ] SKILL.md: 8a–8d rephrased (+ 8e consistency)
- [ ] Header comment + no-ancestor log no longer say "pi ancestor"

---

## Anti-Patterns to Avoid

- ❌ **Do NOT use the double-comma predicate** `[[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]` (contract 3c / S1 comment). It matches only the first token. Use single comma. (Proven — see banner + FINDING 1.)
- ❌ Do NOT edit by line number — S1 shifted them and they will keep drifting. Match exact text; include the preceding PID line to disambiguate the two `POOL_OWNER_COMM="pi";` sites.
- ❌ Do NOT touch the fail-fast MESSAGE text — that is S3 (you only keep the PID==0 *condition*).
- ❌ Do NOT touch `pool_owner_alive` / `pool_lane_is_stale` / `pool_lease_find_mine` / the lease-write sites — they are comm-generic and auto-correct (FINDING 4).
- ❌ Do NOT add `readonly` or an init guard to `POOL_OWNER_*` — `pool_owner_resolve` resets them every call (re-runnable contract).
- ❌ Do NOT change anything in the walk loop except the comm equality test (the `|| true`, the ppid-walk, the termination guards all stay).
- ❌ Do NOT add a permanent test in `test/` — multi-harness coverage is P3.M2.T1. The Level-2 micro-check is a throwaway validation, not a committed test.
- ❌ Do NOT boot Chrome or run the suite to "verify" — static gates + the isolated micro-check are the correct validation (AGENTS.md §1).
- ❌ Do NOT blanket-`# shellcheck disable` anything — if shellcheck flags SC2155 on the TEST-MODE line, apply the Task-1 two-statement contingency instead.

---

**Confidence score: 9/10** for one-pass implementation success. The change is small and
local (one function + one comment + two docs), every match target is pinned to exact text
(line-drift-proof), and the consumers are verified auto-correcting. The one real risk — the
contract's broken double-comma predicate — is caught, proven, and replaced with the correct
single-comma form, and S1's contradicting comment is corrected in the same pass. The -1
reserves for an implementer copy-pasting the contract's double-comma literal despite the
banner (mitigated by placing the deviation banner at the very top and repeating "SINGLE
comma" at every occurrence).
