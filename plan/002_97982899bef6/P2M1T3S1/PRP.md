# PRP — P2.M1.T3.S1: Update `pool_admin_help` (remove DISABLE, add Driving commands, refresh description + MASTER default)

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M1.T3.S1
**Dependency / starting state**: Builds on the **POST-P2.M1.T2.S1** live tree (the `_pool_preflight_real_bin`
preflight is already defined @ lib/pool.sh:3551, called @ 3629, listed in RC-TAXONOMY @ 3592). That
sibling item is **fully disjoint** from `pool_admin_help` (4591-4625): the two touch regions ~1000
lines apart, so they compose in either order. This PRP is a **pure user-facing text edit** to ONE
function — no logic, no globals, no disk, no Chrome.
**Full research notes**: `plan/002_97982899bef6/P2M1T3S1/research/notes.md`

---

## Goal

**Feature Goal**: Bring `pool_admin_help` (the user-facing help printed by
`agent-browser-pool --help|-h|help`) into alignment with the new explicit-invocation,
no-shadow model: (a) delete the now-removed `AGENT_BROWSER_POOL_DISABLE` config line; (b) reframe
the one-line description so it states `agent-browser-pool` is the sole entry point for BOTH pool
verbs and driving commands; (c) add a new "Driving commands" section documenting that any
non-admin token routes to the caller's identity-locked lane, with 3 concrete examples; (d) correct
the `AGENT_CHROME_MASTER` default description to reference the real Chrome user-data-dir
(`~/.config/google-chrome`).

**Deliverable**: A modified `lib/pool.sh` in which `pool_admin_help` (and ONLY that function) has
the five edits below applied verbatim, and for which `bash -n lib/pool.sh` + `shellcheck -s bash
lib/pool.sh` both remain clean, and the live help output (captured by sourcing the pure library)
contains none of the stale strings and all of the new ones.

**Success Definition**:
- `grep -c 'POOL_DISABLE' lib/pool.sh` returns **0** (the help's DISABLE line was the file's last
  `POOL_DISABLE` reference — the sibling P2.M1.T2.S1 explicitly left it for this item).
- `shellcheck -s bash lib/pool.sh` exits 0 with zero output; `bash -n lib/pool.sh` exits 0.
- Sourcing `lib/pool.sh` and calling `pool_admin_help` prints: the new "sole entry point"
  description, a "Driving commands:" section containing the 3 examples (`open <url>`, `screenshot`,
  `close`), an `AGENT_CHROME_MASTER` line mentioning `user-data-dir`, and NO occurrence of
  `AGENT_BROWSER_POOL_DISABLE` or `shadowed CLI`.

---

## Why

- **Business value / PRD alignment**: PRD §2.12 (CLI) defines `agent-browser-pool` as a single
  dispatcher where `status | reap | release | doctor | help` are admin verbs and **every other
  token is a driving command** routed to the caller's own lane (§2.4, §2.15). The old help only
  documented admin verbs and still advertised `AGENT_BROWSER_POOL_DISABLE` — a knob that milestone
  P2.M1.T1 has removed from the code. This item makes the help an **accurate contract** for the new
  model. See architecture `gap_analysis.md` §1c.
- **Who it helps**: Any agent or operator running `agent-browser-pool --help`. Today the help
  misleads them (lists a dead env var, hides that `agent-browser-pool open <url>` is even a thing,
  and calls the real binary a "shadowed CLI"). After this, the help is self-sufficient.
- **Scope cohesion**: This is the final `lib/pool.sh` change in milestone P2.M1 (after the
  DISABLE-removal + fail-fast + preflight items). It touches a region disjoint from all of them and
  from every other in-flight item (P2.M2/P2.M4/P2.M5 own `bin/*`, `references/configuration.md`,
  `test/*`, `SKILL.md`, `README.md` — none own `pool_admin_help`).

---

## What

**User-visible behavior**: `agent-browser-pool --help` (and `-h`/`help`) prints updated text to
STDOUT and returns 0 (unchanged). Specifically, the printed help:
1. Opens with: `agent-browser-pool — the sole entry point for browser pool verbs AND driving commands.`
   (was: `… manage the agent-browser ephemeral-profile pool.`).
2. Adds a "Driving commands:" section (after the admin "Commands:" list, before "Configuration"),
   explaining that any token not matching an admin verb is a driving command routed to the caller's
   own identity-locked lane, with 3 examples: `agent-browser-pool open <url>`, `agent-browser-pool
   screenshot`, `agent-browser-pool close`.
3. The `AGENT_CHROME_MASTER` config line now says the default is the real Chrome user-data-dir
   (`~/.config/google-chrome`) instead of "your real Chrome profile".
4. **No longer prints** the `AGENT_BROWSER_POOL_DISABLE` line.
5. (Consequential hygiene) The `AGENT_BROWSER_REAL` line no longer says "(shadowed CLI)"; it now
   says "(run for driving commands)" — accurate under the no-shadow model.

**Unchanged (explicitly preserved)**:
- The admin "Commands:" list (`status`, `reap`, `release`, `doctor`, `help`) is byte-for-byte
  unchanged.
- Every other config env-var line (`AGENT_BROWSER_POOL_STATE`, `AGENT_CHROME_EPHEMERAL_ROOT`,
  `AGENT_CHROME_BIN`, `AGENT_CHROME_PORT_BASE/RANGE`, `AGENT_BROWSER_POOL_WAIT`,
  `AGENT_CHROME_HEADLESS`, `AGENT_CHROME_ALLOW_SLOW_COPY`) is unchanged.
- The closing `Run 'agent-browser-pool doctor' …` line and `return 0` are unchanged.
- The function's docstring (lib/pool.sh:4562-4590) is unchanged (it is already accurate: "PURE,
  reads NO global, stdout only, rc 0").
- `pool_admin_help` remains a PURE function (no globals, no disk, no `$(…)`).
- Every other function in `lib/pool.sh` (incl. `pool_wrapper_main`, `_pool_preflight_real_bin`,
  `pool_admin_doctor`) is untouched.

### Success Criteria

- [ ] Description line (4592) updated to the "sole entry point … verbs AND driving commands" text.
- [ ] "Driving commands:" section inserted between the `help` line (4610) and the `Configuration`
      line (4612), containing the 3 verbatim examples.
- [ ] `AGENT_CHROME_MASTER` line (4613) references `user-data-dir` + `~/.config/google-chrome`.
- [ ] `AGENT_BROWSER_POOL_DISABLE` line (4612→was 4622) DELETED.
- [ ] `AGENT_BROWSER_REAL` "(shadowed CLI)" → "(run for driving commands)".
- [ ] `bash -n lib/pool.sh` exits 0; `shellcheck -s bash lib/pool.sh` exits 0, zero output.
- [ ] `grep -c 'POOL_DISABLE' lib/pool.sh` → 0.
- [ ] Sourced `pool_admin_help` output passes all Level-2 grep assertions.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the exact file, the exact `oldText`/`newText` for every one of the five
disjoint edits (verified against the live post-S1 tree), the quoting conventions (single-quoted
`printf`, apostrophe-avoidance + the `'"'"'` idiom where unavoidable), the line-drift caveat (anchor
on text, not numbers), the `pool_admin_help`-is-pure fact (which makes sourcing-and-calling a safe
validation), and the explicit out-of-scope list (which other items own) are all specified below.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: lib/pool.sh  (pool_admin_help, current lines 4591-4625)
  why: The ONLY function (and ONLY file) modified. Five disjoint edits, each anchored on exact text.
  pattern: >
    Each printf is `printf '...<literal>...\n'` (single-quoted). Apostrophes inside use the
    `'"'"'` idiom (see the existing `'status'` @4596 and `'release all'` @4607 lines). NEW text in
    this PRP AVOIDS apostrophes to eliminate quoting risk. `<`, `>`, `...` are literal inside
    single quotes (safe).
  gotcha: >
    The item description cited lines "4578-4613" but the live function is at 4591-4625 (~+13 drift
    from prior P2.M1 edits). ALL edits anchor on EXACT TEXT, never line numbers.

- file: lib/pool.sh  (pool_admin_help docstring, 4562-4590)
  why: Proves the function is PURE ("reads NO global, touches NO disk, does NO $(…) … only printf
       + return 0"). This is what makes the Level-2 validation (source lib + call pool_admin_help)
       100% safe — no Chrome, no daemon, no disk, no $HOME writes.
  pattern: "PURE; stdout only; NEVER pool_die; rc 0. Do NOT add any $(…), disk, or global read."

- prd: PRD.md §2.12 (h3.16) — CLI dispatch table
  why: "anything else → acquire/reuse MY lane + exec the real agent-browser" + "Every other token
       is a driving command routed to the caller's own lane (§2.4)." This is the source of truth
       for the new Driving commands section wording.
  critical: release is the SOLE lane-naming command and TEARS DOWN (agents are not taught it);
       every other token is driving. Do NOT suggest agents pass a lane/port/session.

- prd: PRD.md §2.15 (h3.19) — Invocation checklist (the contract the skill teaches)
  why: Source of the 3 example verbs + their semantics:
       `agent-browser-pool open <url>` (lane by identity, not arg);
       `{screenshot,get cdp-url,click,type,eval,find,…}` all work;
       `agent-browser-pool close` → disconnects the lane's DAEMON only (lane/Chrome/profile survive).

- prd: PRD.md §2.11 (h3.15) — Discovery & configuration
  why: Source of the AGENT_CHROME_MASTER default text: "$AGENT_CHROME_MASTER (default
       ${XDG_CONFIG_HOME:-~/.config}/google-chrome — your real Chrome user-data-dir)". Also the
       explicit "(removed) AGENT_BROWSER_POOL_DISABLE and the ~/scripts PATH-shadow are gone".

- file: plan/002_97982899bef6/architecture/gap_analysis.md  §1c
  why: The item's own contract: "pool_admin_help (lib/pool.sh:4578-4613) currently lists
       AGENT_BROWSER_POOL_DISABLE … and only documents admin verbs. … Add a driving commands
       section." Confirms scope.

- file: plan/002_97982899bef6/P2M1T2S1/PRP.md
  why: The CONTRACT for the post-S1 starting state. S1 added _pool_preflight_real_bin (3551/3629)
       and is FULLY DISJOINT from pool_admin_help (4591-4625). S1's Level-3 check explicitly leaves
       the single POOL_DISABLE ref @ pool_admin_help for THIS item: "exactly ONE hit at
       pool_admin_help (~4597) — owned by P2.M1.T3.S1, NOT this item."
  critical: Do NOT re-touch the pool_wrapper_main / preflight region. Do NOT change S1's edits.

- file: bin/agent-browser-pool  (dispatcher)
  why: Confirms how the help is reached (`case --help|-h|help) pool_admin_help ;;`) and that the
       driving routing (`*) → pool_wrapper_main "$@"`) is OWNED BY P2.M2.T1.S1, NOT this item. The
       help TEXT documents behavior that P2.M2.T1.S1 will wire up; this PRP only edits the text.
```

### Current codebase tree (relevant slice)

```bash
lib/pool.sh            # ~4626 lines. pool_admin_help:4591-4625 (the ONLY region this item edits).
                       # _pool_preflight_real_bin:3551 + call:3629 (sibling S1, already applied,
                       #   DISJOINT). pool_admin_doctor:~4380. pool_wrapper_main:~3640.
bin/agent-browser-pool # dispatcher; `*)` arm still errors today → P2.M2.T1.S1 rewires it (NOT here)
test/                  # NOT touched (P2.M5 owns updates)
plan/002_97982899bef6/architecture/gap_analysis.md   # §1c (read-only)
plan/002_97982899bef6/P2M1T2S1/PRP.md                # S1 contract (read-only)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONLY lib/pool.sh is modified, and ONLY the pool_admin_help function body (5 edits).
lib/pool.sh            # pool_admin_help: new description, +Driving commands section,
                       #   AGENT_CHROME_MASTER default corrected, DISABLE line removed,
                       #   AGENT_BROWSER_REAL "(shadowed CLI)" → "(run for driving commands)".
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (anchor on TEXT, not line numbers): the item description cited "4578-4613" but the live
#   function is 4591-4625. Every oldText below is EXACT text copied from the live tree (post-S1).
#   Do not trust any line number — match the strings.

# CRITICAL (single-quote printf quoting): each line is `printf '...\n'`. To embed an apostrophe
#   inside single quotes you MUST use the `'"'"'` idiom (see existing 'status'/'release all' lines).
#   This PRP's NEW text AVOIDS apostrophes entirely (e.g. "disconnect your lane daemon", NOT
#   "lane's daemon"; "run for driving commands", NOT "exec'd") to eliminate the quoting hazard.

# CRITICAL (< > ... are literal in single quotes): `printf '... open <url> ...'` is safe — no
#   redirection happens inside quotes. Do NOT escape them.

# CRITICAL (this is a TEXT-only edit): pool_admin_help must stay PURE. Do NOT add $(…), disk I/O,
#   global reads, or pool_die. It only `printf`s + `return 0`. (Docstring 4562-4590 already states
#   this; keep it true.)

# CRITICAL (do NOT touch the dispatcher): the driving routing (`*) → pool_wrapper_main "$@"`) is
#   P2.M2.T1.S1. This PRP only edits the help TEXT that DESCRIBES that routing.

# CRITICAL (consequential hygiene beyond the literal contract): the AGENT_BROWSER_REAL line says
#   "(shadowed CLI)" — false under the "No-Shadow Pivot". It is in the SAME printf block, owned by
#   no other item, and contradicts the new "sole entry point" description. Fix it (Task 5). Same
#   discipline the sibling S1 PRP used for its RC-TAXONOMY comment.

# CRITICAL (no execution of browsers/daemons — AGENTS.md §1): validate with bash -n, shellcheck,
#   and the isolated source+call micro-check ONLY. pool_admin_help is PURE → sourcing lib/pool.sh
#   (which has NO top-level executable code) and calling it touches nothing.

# SAFE TO SOURCE: lib/pool.sh defines functions only — `source lib/pool.sh` runs no commands.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This is five disjoint text edits to one PURE printf-only function. The only
"contract" is: the function remains PURE (no `$(…)`, no disk, no globals), stdout-only, rc 0.

### Implementation Tasks (ordered by dependencies)

> All five edits are in `lib/pool.sh`, in DISJOINT regions of `pool_admin_help`. They MAY be applied
> in a SINGLE `edit` call with five `edits[]` entries (the tool matches each `oldText` against the
> original file independently; each is unique). Order in the array does not matter.

```yaml
Task 1: EDIT lib/pool.sh — UPDATE the description line (item step b)
  - oldText:
        printf 'agent-browser-pool — manage the agent-browser ephemeral-profile pool.\n'
  - newText:
        printf 'agent-browser-pool — the sole entry point for browser pool verbs AND driving commands.\n'
  - WHY: the old description ("manage the … pool") hides that driving commands are also accepted.
         PRD §2.12 makes the binary the sole entry point for both. Preserves the em-dash (—) + period.
  - BUCKET: required (item step b).

Task 2: EDIT lib/pool.sh — ADD the "Driving commands" section (item step c)
  - oldText (the 3-line seam between the admin Commands list and the Configuration section):
        printf '  help                    Show this help. Aliases: --help, -h.\n'
        printf '\n'
        printf 'Configuration (environment variables; all optional):\n'
  - newText (insert the Driving commands block in the blank line between help and Configuration):
        printf '  help                    Show this help. Aliases: --help, -h.\n'
        printf '\n'
        printf 'Driving commands:\n'
        printf '  Any token that is not a command above is treated as a DRIVING command and is\n'
        printf '  routed to your own locked lane (the lane is chosen by your identity, never by\n'
        printf '  an argument). The real agent-browser runs against your lane:\n'
        printf '    agent-browser-pool open <url>    open a URL in your lane\n'
        printf '    agent-browser-pool screenshot     capture a screenshot\n'
        printf '    agent-browser-pool close         disconnect your lane daemon (lane and profile survive for reuse)\n'
        printf '  Every other real agent-browser verb works the same way (get cdp-url, click,\n'
        printf '  type, eval, find, ...). You never pass a lane, port, or session.\n'
        printf '\n'
        printf 'Configuration (environment variables; all optional):\n'
  - WHY: documents the §2.12/§2.15 contract that any non-admin token routes to the caller's own
         identity-locked lane. Gives the 3 examples the item requires. Wording avoids apostrophes
         (quoting safety) and uses PRD's exact verb list (screenshot/get cdp-url/click/type/eval/find).
  - GOTCHA: the 4-space-indented examples are intentional (visually nested under the header). The
            description columns are best-effort aligned; CLARITY matters more than perfect column
            alignment — keep the 3 example command strings EXACTLY as written (open <url>,
            screenshot, close) since the Level-2 checks grep for them.
  - BUCKET: required (item step c).

Task 3: EDIT lib/pool.sh — UPDATE the AGENT_CHROME_MASTER default text (item step d)
  - oldText:
        printf '  AGENT_CHROME_MASTER             CoW source profile (default: your real Chrome profile)\n'
  - newText:
        printf '  AGENT_CHROME_MASTER             CoW source profile (default: ~/.config/google-chrome — your real Chrome user-data-dir)\n'
  - WHY: the old "your real Chrome profile" is vague; PRD §2.11 pins the default to the real Chrome
         user-data-dir (${XDG_CONFIG_HOME:-~/.config}/google-chrome). Uses an em-dash (matches file
         style) to avoid nested parens.
  - BUCKET: required (item step d).

Task 4: EDIT lib/pool.sh — DELETE the AGENT_BROWSER_POOL_DISABLE line (item step a)
  - oldText:
        printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)\n'
        printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set (1/true/yes/on)\n'
        printf '\n'
  - newText:
        printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)\n'
        printf '\n'
  - WHY: the DISABLE knob was removed in P2.M1.T1.S1; this is the file's LAST POOL_DISABLE ref
         (sibling S1 left it here on purpose). After this edit: grep POOL_DISABLE lib/pool.sh = 0.
  - BUCKET: required (item step a).

Task 5: EDIT lib/pool.sh — fix stale "shadowed CLI" on AGENT_BROWSER_REAL (consequential hygiene)
  - oldText:
        printf '  AGENT_BROWSER_REAL              the real agent-browser binary (shadowed CLI)\n'
  - newText:
        printf '  AGENT_BROWSER_REAL              the real agent-browser binary (run for driving commands)\n'
  - WHY (not optional): "(shadowed CLI)" is factually false under the No-Shadow Pivot — there is no
         PATH shadowing; pool_wrapper_main execs the real binary directly for driving commands. It
         sits in the SAME printf block being edited, contradicts the new "sole entry point"
         description (Task 1), and is owned by no other item (P2.M4.T2.S1 = configuration.md, a
         different file). Leaving it = a self-contradictory help. One phrase beyond the literal
         contract, same hygiene discipline as S1's RC-TAXONOMY edit. No apostrophe → no quoting risk.
  - BUCKET: consequential hygiene (caused by the model pivot + Task 1), in-scope.

Task 6: VERIFY — static gates + pure-output micro-check (no browsers/daemons)
  - RUN: bash -n lib/pool.sh                         # exit 0
  - RUN: shellcheck -s bash lib/pool.sh              # exit 0, zero output
  - RUN: the source+call micro-checks in "Validation Loop → Level 2".
  - RUN: grep -c 'POOL_DISABLE' lib/pool.sh          # expect 0
```

### Implementation Patterns & Key Details

```bash
# Task 1 — description line must read EXACTLY:
#     printf 'agent-browser-pool — the sole entry point for browser pool verbs AND driving commands.\n'
#   (em-dash — U+2014 — preserved; trailing period; single-quoted; no apostrophe.)
#
# Task 2 — the inserted Driving commands block must read EXACTLY (verbatim command strings!):
#     printf 'Driving commands:\n'
#     printf '  Any token that is not a command above is treated as a DRIVING command and is\n'
#     printf '  routed to your own locked lane (the lane is chosen by your identity, never by\n'
#     printf '  an argument). The real agent-browser runs against your lane:\n'
#     printf '    agent-browser-pool open <url>    open a URL in your lane\n'
#     printf '    agent-browser-pool screenshot     capture a screenshot\n'
#     printf '    agent-browser-pool close         disconnect your lane daemon (lane and profile survive for reuse)\n'
#     printf '  Every other real agent-browser verb works the same way (get cdp-url, click,\n'
#     printf '  type, eval, find, ...). You never pass a lane, port, or session.\n'
#
# Task 3 — AGENT_CHROME_MASTER line must read EXACTLY:
#     printf '  AGENT_CHROME_MASTER             CoW source profile (default: ~/.config/google-chrome — your real Chrome user-data-dir)\n'
#
# Task 4 — the DISABLE line is REMOVED; the ALLOW_SLOW_COPY line + the trailing '\n' are KEPT.
#
# Task 5 — AGENT_BROWSER_REAL line must read EXACTLY:
#     printf '  AGENT_BROWSER_REAL              the real agent-browser binary (run for driving commands)\n'
#
# DO NOT:
#   - introduce apostrophes in any new text (use the apostrophe-free wording above; if you must,
#     use the `'"'"'` idiom — but you should not need to).
#   - add $(…), disk I/O, global reads, or pool_die to pool_admin_help (it must stay PURE).
#   - touch the admin Commands list, the other config lines, the docstring, the dispatcher,
#     pool_wrapper_main, _pool_preflight_real_bin, or any other function/file.
#   - run test/validate.sh, test/transparency.sh, install.sh, or any agent-browser / Chrome command,
#     and do NOT touch the shared $HOME (AGENTS.md §1).
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no env vars, no routes, no NEW external doc files.
  - The ONLY integration surface is the textual content of `agent-browser-pool --help|-h|help`.
  - Downstream consumers that will reference this LATER (NOT here):
      * bin/agent-browser-pool `*)` arm → pool_wrapper_main "$@"   (P2.M2.T1.S1) — wires up the
        routing the new "Driving commands" section DESCRIBES.
      * references/configuration.md DISABLE row / master default   (P2.M4.T2.S1)
      * SKILL.md / README.md                                       (P2.M4.T1.S1 / P2.M6.T1.S1)
      * test/transparency.sh --help expectation                    (P2.M5.T2.S1)
```

---

## Validation Loop

> Per AGENTS.md §1/§2: every command below is STATIC (`bash -n`, `shellcheck`) or an isolated,
> `timeout`-bounded micro-check that sources a PURE library and calls a PURE function. No real
> Chrome, no daemons, no full test suite, no shared-$HOME writes.

### Level 1: Syntax & Style (run after the edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# Syntax — must exit 0
bash -n lib/pool.sh

# Lint — must exit 0 with ZERO output (matches the clean pre-change baseline)
shellcheck -s bash lib/pool.sh

# Expected: both exit 0; shellcheck prints nothing.
```

### Level 2: Component Validation (isolated, timeout-bounded source+call micro-check)

```bash
cd /home/dustin/projects/agent-browser-pool

# pool_admin_help is PURE (no globals/disk/$(…)) and lib/pool.sh has NO top-level execution, so
# sourcing + calling it is 100% safe (no Chrome, no daemon). Capture its real stdout and assert.
timeout 10 bash -c '
  source "$1/lib/pool.sh"
  pool_admin_help
' _ "$(pwd)" > /tmp/s3_help.txt 2>&1
echo "exit=$?"                          # Expected: exit=0

# (a) DISABLE removed from help output
grep -q 'AGENT_BROWSER_POOL_DISABLE' /tmp/s3_help.txt \
  && { echo "FAIL: DISABLE still in help"; } || { echo "OK: DISABLE removed from help"; }

# (b) Driving commands section present, with the 3 verbatim examples
grep -q 'Driving commands:' /tmp/s3_help.txt           && echo "OK: Driving commands header"     || echo "FAIL: no Driving commands header"
grep -q 'agent-browser-pool open <url>' /tmp/s3_help.txt  && echo "OK: open example"              || echo "FAIL: no open example"
grep -q 'agent-browser-pool screenshot' /tmp/s3_help.txt  && echo "OK: screenshot example"        || echo "FAIL: no screenshot example"
grep -q 'agent-browser-pool close' /tmp/s3_help.txt        && echo "OK: close example"            || echo "FAIL: no close example"

# (c) New description line
grep -q 'sole entry point for browser pool verbs AND driving commands' /tmp/s3_help.txt \
  && echo "OK: new description" || echo "FAIL: old description still present"

# (d) AGENT_CHROME_MASTER updated (user-data-dir + path)
grep -q 'user-data-dir' /tmp/s3_help.txt && grep -q '~/.config/google-chrome' /tmp/s3_help.txt \
  && echo "OK: master default updated" || echo "FAIL: master default not updated"

# (e) Consequential: stale "shadowed CLI" gone
grep -q 'shadowed CLI' /tmp/s3_help.txt \
  && { echo "FAIL: stale 'shadowed CLI' remains"; } || { echo "OK: shadowed CLI removed"; }

# (f) Purity preserved: help still returns 0 and prints the unchanged closing line
grep -q "Run 'agent-browser-pool doctor' to verify your setup." /tmp/s3_help.txt \
  && echo "OK: closing line intact" || echo "FAIL: closing line damaged"

rm -f /tmp/s3_help.txt
```

Expected: `exit=0` and every line prints `OK:`. If the source+call hangs past ~1s, ABORT — that
would mean `lib/pool.sh` grew top-level execution or `pool_admin_help` touched disk/ne (a purity
violation). Do not wait for the `timeout 10`.

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# The file's LAST POOL_DISABLE ref is now gone → whole-file count must be 0.
grep -c 'POOL_DISABLE' lib/pool.sh          # Expected: 0

# The help no longer mentions DISABLE or "shadowed CLI" anywhere in source.
grep -n 'POOL_DISABLE\|shadowed CLI' lib/pool.sh   # Expected: NO output

# The new strings are present exactly once each in source.
grep -n 'sole entry point for browser pool verbs AND driving commands' lib/pool.sh   # 1 hit
grep -n "Driving commands:" lib/pool.sh                                             # 1 hit
grep -n 'your real Chrome user-data-dir' lib/pool.sh                                # 1 hit
grep -n 'run for driving commands' lib/pool.sh                                      # 1 hit

# The sibling item's region is untouched (disjoint): preflight still defined + called.
grep -n '_pool_preflight_real_bin' lib/pool.sh   # Expected: 3 hits (defn @3551, call @3629,
                                                 # RC-TAXONOMY @3592) — UNCHANGED by this item.

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command.
```

### Level 4: Creative & Domain-Specific Validation

N/A — this item has no runtime behavior beyond printed text (no network, no DB, no perf). The help
text wording is pinned by the item contract + PRD §2.12/§2.15/§2.11. Levels 1-3 are complete and
sufficient.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` exits 0.
- [ ] `shellcheck -s bash lib/pool.sh` exits 0 with zero output.
- [ ] `grep -c 'POOL_DISABLE' lib/pool.sh` returns 0.
- [ ] Level 2 micro-check: `exit=0` and every assertion prints `OK:`.

### Feature Validation

- [ ] Description line updated to "sole entry point … verbs AND driving commands" (Task 1).
- [ ] "Driving commands:" section inserted with the 3 verbatim examples (Task 2).
- [ ] `AGENT_CHROME_MASTER` line references `user-data-dir` + `~/.config/google-chrome` (Task 3).
- [ ] `AGENT_BROWSER_POOL_DISABLE` line deleted (Task 4).
- [ ] `AGENT_BROWSER_REAL` "(shadowed CLI)" → "(run for driving commands)" (Task 5).
- [ ] Admin Commands list, other config lines, closing line, docstring, and `return 0` unchanged.
- [ ] `pool_admin_help` remains PURE (no `$(…)`, no disk, no globals).

### Code Quality Validation

- [ ] Only `lib/pool.sh` modified; only `pool_admin_help` touched within it.
- [ ] Edits anchor on exact text (not line numbers); robust to the ~+13 line drift.
- [ ] No apostrophes introduced in new text (quoting-hazard avoided).
- [ ] `_pool_preflight_real_bin` / `pool_wrapper_main` / `pool_admin_doctor` untouched (sibling S1
      region disjoint).
- [ ] `bin/*`, `test/*`, `install.sh`, `references/configuration.md`, `SKILL.md`, `README.md` all
      untouched (owned by P2.M2 / P2.M4 / P2.M5 / P2.M6).

### Documentation & Deployment

- [ ] [Mode A] The help text IS the documentation change (user-facing output) — no separate doc
      files change in THIS item (configuration.md = P2.M4.T2.S1; SKILL/README = P2.M4/P2.M6).

---

## Anti-Patterns to Avoid

- ❌ Don't anchor edits on the item's cited line numbers (4578-4613) — they drifted; match exact text.
- ❌ Don't introduce apostrophes in new `printf` text — use the apostrophe-free wording (or the
  `'"'"'` idiom if unavoidable); "lane daemon", not "lane's daemon".
- ❌ Don't add `$(…)`, disk I/O, global reads, or `pool_die` to `pool_admin_help` — it must stay PURE.
- ❌ Don't touch the dispatcher's `*)` arm — that routing is P2.M2.T1.S1; this item only edits the
  help TEXT that describes it.
- ❌ Don't skip Task 5 ("just one phrase") — leaving "(shadowed CLI)" makes the help self-contradictory
  with the new "sole entry point" description under the No-Shadow Pivot; it's in-scope hygiene.
- ❌ Don't touch the sibling S1 region (`_pool_preflight_real_bin` / `pool_wrapper_main`) — disjoint.
- ❌ Don't run `test/validate.sh` / `test/transparency.sh` / `install.sh`, and don't boot Chrome or
  touch the shared `$HOME` (AGENTS.md §1). Use the Level 2 source+call micro-check instead.

---

## Confidence Score

**9/10** — one-pass success likelihood. The change is surgical (five disjoint single-line/block text
edits inside one PURE printf-only function), every `oldText`/`newText` is given verbatim and verified
against the live post-S1 tree, the new wording is derived directly from PRD §2.12/§2.15/§2.11 and
deliberately avoids apostrophes (eliminating the only realistic quoting pitfall), the function's
purity makes validation trivially safe (source + call, no Chrome/daemon), and the only POOL_DISABLE
ref in the file is the one being deleted (so the post-edit `grep` expectation is unambiguous: 0).
The single residual risk is an implementer skipping Task 5 as "out of contract" — this PRP marks it
explicitly as in-scope consequential hygiene (with the same justification S1 used for its
RC-TAXONOMY comment), so the result is not left internally inconsistent.
