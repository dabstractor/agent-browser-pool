# PRP — P2.M2.T1.S1: Change `*)` branch from error to `pool_wrapper_main` dispatch

**Project**: agent-browser-pool (bash — `lib/pool.sh` + `bin/*` + `test/*`)
**Work item**: P2.M2.T1.S1
**Dependency / starting state**: Builds on the **POST-P2.M1** live tree (milestone P2.M1 complete:
DISABLE removed, no-pi-ancestor fail-fast in `pool_wrapper_main`, `_pool_preflight_real_bin`
defined @ lib/pool.sh:3552 + called @ 3630). `pool_wrapper_main` (lib/pool.sh:3619-3757) is fully
ready and TERMINAL. This item rewires ONE case arm in `bin/agent-browser-pool` (25 lines) so
non-admin tokens route to it, plus a header-comment update. The parallel item **P2.M1.T3.S1** edits
ONLY `pool_admin_help` text inside `lib/pool.sh` — fully disjoint from this file; compose freely.
**Full research notes**: `plan/002_97982899bef6/P2M2T1S1/research/notes.md`

---

## Goal

**Feature Goal**: Make `bin/agent-browser-pool` the SOLE entry point for BOTH pool verbs AND driving
commands (PRD §2.1/§2.4/§2.12), by changing the `*)` (default) case arm from a hard error
(`Unknown command: $cmd`) to `pool_wrapper_main "$@"`, so that any token which is not an admin verb
(`status|reap|release|doctor|--help|-h|help`) is routed to the full lane lifecycle (acquire/reuse my
lane → exec the real `agent-browser`).

**Deliverable**: A modified `bin/agent-browser-pool` in which (a) the `*)` arm reads
`pool_wrapper_main "$@" ;;` (the `Unknown command` error is gone), (b) the 5-line file header
comment is reframed from "admin CLI" to "SOLE entry point: pool verbs + driving router" with a
§2.4 cross-reference, and (c) every other line — the 5 admin arms, the `cmd="${1:-status}"` default,
the unconditional `pool_config_init`/`pool_state_init`, the symlink-safe `readlink -f` resolution,
`set -euo pipefail` — is byte-for-byte unchanged. `bash -n` stays clean and `shellcheck` introduces
NO new findings beyond the pre-existing SC1091 info.

**Success Definition**:
- `grep -Fc 'Unknown command: $cmd' bin/agent-browser-pool` → **0** (old error removed).
- `grep -F '*) pool_wrapper_main "$@" ;;' bin/agent-browser-pool` → **1** hit.
- `grep -F 'cmd="${1:-status}"' bin/agent-browser-pool` → **1** hit (default preserved, untouched).
- All 5 admin arms present verbatim: `status)`, `reap)`, `release)`, `doctor)`, `--help|-h|help)`.
- `grep -E 'SOLE entry point' bin/agent-browser-pool` → **1** hit; `grep '§2.4' bin/agent-browser-pool`
  → **1** hit; `grep -c 'admin CLI' bin/agent-browser-pool` → **0** (old framing gone).
- `bash -n bin/agent-browser-pool` exits 0.
- `shellcheck -s bash bin/agent-browser-pool` output is IDENTICAL before/after (only the single
  pre-existing SC1091 info on the `source` line) — i.e. NO new findings introduced.
- Isolated dispatch micro-check: `agent-browser-pool bogus-driving-verb` (with state redirected to
  a temp tree and `AGENT_BROWSER_REAL` pointed at a nonexistent path) exits non-zero with the
  `_pool_preflight_real_bin` die message on stderr — proving the `*)` arm reached
  `pool_wrapper_main` — and NEVER prints `Unknown command`.

---

## Why

- **Business value / PRD alignment**: PRD §2.4 step 0 + §2.12 define `agent-browser-pool` as a
  single dispatcher where admin verbs run inline and **every other token is a DRIVING command**
  routed to the caller's identity-locked lane (§2.4 steps 1-5: owner resolve → find/acquire → boot →
  ensure-connected → exec real `agent-browser`). Today the `*)` arm rejects everything that isn't an
  admin verb, so `agent-browser-pool open <url>` is impossible. This one-line rewiring ACTIVATES the
  entire lane pipeline that milestone P2.M1 already built and hardened. See
  `architecture/gap_analysis.md` §2.
- **Who it helps**: Every agent + operator that wants to drive a browser through the pool. After this
  item, `agent-browser-pool <verb> <args>` works for the full real-binary surface (open/click/type/
  snapshot/eval/get/find/…) — the lane is chosen by identity, never named as an argument (§2.4
  invariant). Operators still get `status|reap|release|doctor|help` unchanged.
- **Scope cohesion**: This is the FIRST item of milestone P2.M2 (Entry Point & Binary Pivot). It is
  the prerequisite for the sibling P2.M2.T2.S1 (delete the old `bin/agent-browser` PATH-shadow shim
  — obsolete once driving routes through `agent-browser-pool` directly). It touches ONLY
  `bin/agent-browser-pool`; `lib/pool.sh` (P2.M1, complete + parallel P2.M1.T3.S1), `install.sh`
  (P2.M3), `SKILL.md`/`config.md`/`README.md` (P2.M4/P2.M6), and `test/*` (P2.M5) are all untouched.
  The full real-Chrome integration of `agent-browser-pool open <url>` is validated by P2.M5's
  `test/transparency.sh` + `test/concurrency.sh` in an isolated sandbox — NOT by this item.

---

## What

**User-visible behavior**:
- `agent-browser-pool open <url>` (and any other non-admin token) now REACHES the lane pipeline:
  resolve owner → reuse-or-acquire my lane → boot/ensure-connected → exec the real `agent-browser`
  with `AGENT_BROWSER_SESSION=abpool-<N>` + cleaned args. (Terminal: it never returns to the
  dispatcher; success `exec`s, fatal paths `pool_die`/`exit 1`.)
- `agent-browser-pool status|reap|release|doctor` and `agent-browser-pool --help|-h|help` are
  UNCHANGED (same arms, same functions, same default).
- A bare `agent-browser-pool` (no args) STILL runs `status` (`cmd="${1:-status}"`).
- The `Unknown command: $cmd` message is GONE forever.

**Unchanged (explicitly preserved)**:
- The 5 admin case arms, verbatim: `status) pool_admin_status ;;`, `reap) pool_admin_reap ;;`,
  `release) pool_admin_release "${2:-}" ;;`, `doctor) pool_admin_doctor ;;`,
  `--help|-h|help) pool_admin_help ;;`.
- `cmd="${1:-status}"` (the no-arg default).
- The unconditional `pool_config_init` + `pool_state_init` calls before the case (idempotent;
  `pool_wrapper_main` re-calls them harmlessly — the existing comment already documents this).
- The symlink-safe resolution (`REAL_SCRIPT`/`REAL_DIR`/`source "$REAL_DIR/../lib/pool.sh"`).
- `set -euo pipefail`.
- `lib/pool.sh`, `bin/agent-browser`, `install.sh`, every doc + test file.

### Success Criteria

- [ ] `*)` arm changed from `echo "Unknown command: $cmd" >&2; exit 1` to `pool_wrapper_main "$@"`.
- [ ] `Unknown command` no longer appears anywhere in `bin/agent-browser-pool`.
- [ ] `cmd="${1:-status}"` default preserved (1 hit, byte-identical).
- [ ] All 5 admin arms present and byte-identical to the starting tree.
- [ ] File header comment reframed to "SOLE entry point: pool verbs + driving router"; adds §2.4
      cross-reference; removes "admin CLI" framing + "Dispatches to the pool_admin_* functions." line
      (replaced by an accurate both-arms description).
- [ ] `bash -n bin/agent-browser-pool` exits 0.
- [ ] `shellcheck -s bash bin/agent-browser-pool` introduces NO new findings (only the pre-existing
      SC1091 info remains — see Known Gotchas).
- [ ] Isolated dispatch micro-check passes (§Level 2): a driving verb reaches `pool_wrapper_main`
      (proven by the preflight die message), no `Unknown command`, no Chrome booted.

---

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **Yes** — the exact file (25 lines, reproduced verbatim in the research notes §1),
the exact `oldText`/`newText` for both disjoint edits (the `*)` arm + the 5-line header comment),
the proof that `pool_wrapper_main "$@"` receives the full argv (no `shift` after `cmd=`), the fact
that `pool_wrapper_main` is self-contained + terminal (so the case arm needs no guard and nothing
follows it), the shellcheck-baseline-is-SC1091-not-clean gotcha, a deterministic Chrome-free
validation recipe (preflight die), and the explicit out-of-scope list (which other items own) are
all specified below.

### Documentation & References

```yaml
# MUST READ / ground truth for the change
- file: bin/agent-browser-pool   (25 lines — the ONLY file modified)
  why: The dispatcher. Two disjoint edits: the `*)` arm (logic) + the 5-line header comment (text).
  pattern: "case arm is `    <pat>) <body> ;;` (4-space indent, `;;` terminator). NO `shift` after
           `cmd=\"${1:-status}\"`, so `$@` still holds every original positional — that is WHY
           `pool_wrapper_main \"$@\"` receives the driving verb + its args."
  gotcha: "The dispatcher calls pool_config_init + pool_state_init UNCONDITIONALLY before the case.
           pool_wrapper_main calls them AGAIN. This is INTENTIONAL + harmless (idempotent); the
           existing comment documents it. DO NOT remove the unconditional calls — they keep the
           admin arms working even though pool_wrapper_main is not on their path."

- file: lib/pool.sh  (pool_wrapper_main, lines 3619-3757)
  why: The function the `*)` arm now invokes. Self-contained + TERMINAL — does its own
       config/state init + preflight + classify + owner + lane + exec. So the case arm needs NO
       `if`/`||` guard and NOTHING may follow it in the arm.
  pattern: "pool_wrapper_main is rc-less + terminal: every success path `exec \"$POOL_REAL_BIN\" …`
           (process replacement, never returns); every fatal path `pool_die` (exit 1). Invoke as a
           bare statement: `pool_wrapper_main \"$@\" ;;`."
  critical: "pool_wrapper_main's 3rd step is `class=\"$(pool_dispatch_classify \"$@\")\"` — it
            classifies meta (skills/--version/session list…) vs driving on the FULL argv. So routing
            `*)` → pool_wrapper_main is correct for BOTH driving commands AND meta commands that slip
            past the admin arms. No extra special-casing in the dispatcher."

- file: lib/pool.sh  (_pool_preflight_real_bin, lines 3540-3559)
  why: The KEY to safe validation. It is pool_wrapper_main's 3rd step and it `pool_die`s if
       `$POOL_REAL_BIN` is missing/non-executable — BEFORE owner resolve / lane acquire / Chrome boot.
       Pointing AGENT_BROWSER_REAL at a nonexistent path makes it die fast, deterministically,
       pi-ancestor-independently. The die message is the proof the `*)` arm reached pool_wrapper_main.
  pattern: "_pool_preflight_real_bin reads ONLY $POOL_REAL_BIN (frozen by pool_config_init via
           AGENT_BROWSER_REAL → realpath -m, canonicalize-missing, exits 0). pool_die =
           `printf '%s\\n' \"$*\" >&2; exit 1`."

- file: lib/pool.sh  (pool_config_init, ~lines 95-160)
  why: Confirms AGENT_BROWSER_REAL (default ~/.local/bin/agent-browser) → POOL_REAL_BIN via
       `_pool_config_canon_path` (realpath -m). Setting AGENT_BROWSER_REAL=/nonexistent does NOT fail
       config (canonicalize-missing); it only fails later at preflight. Enables the safe validation.

- file: plan/002_97982899bef6/architecture/gap_analysis.md  §2
  why: The item's own contract — quotes the exact before/after dispatch (`*) → pool_wrapper_main
       "$@"`). Confirms scope: "Everything else stays the same. Pool verbs are handled by the case
       arms; everything else goes to pool_wrapper_main."

- prd: PRD.md §2.4 (h3.8) — Request lifecycle
  why: step 0 classify (POOL VERB vs DRIVING) + the full lane pipeline the rewired arm activates.
  critical: "The command never names a lane — `agent-browser-pool <verb> <args>` always means MY
       lane by identity. pool_wrapper_main owns this; the dispatcher just hands off `$@`."

- prd: PRD.md §2.12 (h3.16) — CLI dispatch table
  why: "<driving verb> [args]  # anything else → acquire/reuse MY lane + exec the real agent-browser".
       Source for the header-comment reframe ("pool verbs + driving router").

- prd: PRD.md §2.1 (h3.5) — Components
  why: "~/.local/bin/agent-browser-pool ← SOLE entry point (symlink → repo bin/): pool verbs +
       driving router". Source of the "SOLE entry point" wording for the header.

- file: plan/002_97982899bef6/P2M1T3S1/PRP.md   (parallel item — CONTRACT for help text)
  why: P2.M1.T3.S1 edits ONLY pool_admin_help TEXT in lib/pool.sh. It is DISJOINT from this file.
       This PRP must NOT assert on help-text strings (only on dispatch wiring) so it composes with
       either ordering of the two items. Its `*) → pool_wrapper_main` mention is the routing this
       item wires up; it only edits the TEXT that describes it.

- file: plan/002_97982899bef6/P2M1T2S1/PRP.md   (completed — CONTRACT for the starting state)
  why: P2.M1.T2.S1 added _pool_preflight_real_bin (3552/3630) — the function that makes this item's
       validation safe. Confirms pool_wrapper_main's region is DONE + stable for this item to call.
```

### Current codebase tree (relevant slice)

```bash
bin/agent-browser-pool   # 25 lines — the ONLY file this item modifies (2 disjoint edits).
bin/agent-browser        # old PATH-shadow shim — DELETED by sibling P2.M2.T2.S1, NOT here.
bin/.gitkeep             # untouched
lib/pool.sh              # ~4626 lines — UNTOUCHED. pool_wrapper_main:3619-3757 (ready, terminal).
                         #   _pool_preflight_real_bin:3540-3559 (safe-validation key).
                         #   pool_config_init/pool_state_init/pool_admin_* — all unchanged.
test/                    # UNTOUCHED (P2.M5 owns the driving-path integration tests).
plan/002_97982899bef6/architecture/gap_analysis.md   # §2 (read-only contract)
```

### Desired codebase tree with files to be added and responsibility of file

```bash
# NO new files. ONLY bin/agent-browser-pool is modified, in TWO disjoint regions:
bin/agent-browser-pool   # `*)` arm: error → pool_wrapper_main "$@"
                         # header comment (5 lines): "admin CLI" → "SOLE entry point … driving router"
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (shellcheck baseline is NOT clean-exit): `shellcheck -s bash bin/agent-browser-pool`
#   ALREADY exits 1 on the UNCHANGED file with ONE info-level SC1091 (the `source ../lib/pool.sh`
#   line — unavoidable for a dispatcher). So item step f's "shellcheck passes" means
#   "NO NEW findings introduced" — DIFF before/after, or assert the ONLY output line is the SC1091
#   info. Do NOT assert `shellcheck` exits 0 (it never did). `bash -n` DOES exit 0 and must remain.

# CRITICAL (anchor edits on TEXT, not line numbers): the file is tiny (25 lines) but always quote
#   the exact string. The `*)` arm is exactly `    *) echo "Unknown command: $cmd" >&2; exit 1 ;;`
#   (4-space indent, spaces around `>&2`). Match it verbatim.

# CRITICAL (do NOT add a guard or trailing code to the arm): pool_wrapper_main is TERMINAL — every
#   success path exec's the real binary (process replacement, never returns), every fatal path
#   pool_die's (exit 1). So `*) pool_wrapper_main "$@" ;;` is correct as a BARE statement. Do NOT
#   write `*) pool_wrapper_main "$@" || exit 1 ;;` or add anything after it in the arm.

# CRITICAL (keep the unconditional init calls): pool_config_init + pool_state_init run BEFORE the
#   case on EVERY invocation. pool_wrapper_main calls them again (redundant, idempotent, harmless —
#   already documented in the file). They MUST stay so the admin arms (status/reap/release/doctor/
#   help) still have globals + a lanes dir without depending on pool_wrapper_main. Do NOT "optimize"
#   by removing them.

# CRITICAL (full argv is passed correctly): `cmd="${1:-status}"` does NOT shift (grep confirms no
#   `shift` in the file). So `pool_wrapper_main "$@"` receives the driving verb + ALL its args.
#   pool_wrapper_main's classify step NEEDS the full argv. Do NOT change `cmd=` or add a shift.

# CRITICAL (no Chrome / no daemon during validation — AGENTS.md §1): do NOT run a real driving
#   command against the operator's $HOME / live Chrome. The Level-2 micro-check forces the preflight
#   to die fast (AGENT_BROWSER_REAL=/nonexistent + state in a temp tree) so it proves dispatch
#   reached pool_wrapper_main WITHOUT booting Chrome. The full `open <url>`→lane→Chrome path is
#   validated by P2.M5 in an isolated sandbox, NOT here.

# SAFE TO SOURCE? N/A — bin/agent-browser-pool is an executable script (not a library); it runs
#   pool_config_init/pool_state_init at top level. Do NOT source it. Validate by EXECUTING it in an
#   isolated, timeout-bounded micro-check (Level 2) instead.
```

---

## Implementation Blueprint

### Data models and structure

N/A — no data models. This is a 2-edit change to a 25-line dispatcher: one logic line (the `*)`
arm) and one 5-line text block (the header comment). The only "contract" is: every other line stays
byte-identical, and the change introduces no shellcheck findings.

### Implementation Tasks (ordered by dependencies)

> Both edits are in `bin/agent-browser-pool`, in DISJOINT regions. They MAY be applied in a SINGLE
> `edit` call with two `edits[]` entries (the tool matches each `oldText` against the original file
> independently; each is unique). Order in the array does not matter.

```yaml
Task 1: EDIT bin/agent-browser-pool — CHANGE the `*)` arm from error to dispatch (item step a)
  - oldText:
        *) echo "Unknown command: $cmd" >&2; exit 1 ;;
  - newText:
        *) pool_wrapper_main "$@" ;;
  - WHY: PRD §2.4 step 0 / §2.12 — any non-admin token is a DRIVING command routed to the caller's
         lane. pool_wrapper_main is self-contained + TERMINAL (exec/pool_die), so the arm is a bare
         statement with no guard and nothing trailing. The full "$@" is correct (no shift after cmd=).
  - BUCKET: required (item step a — the core logic change).

Task 2: EDIT bin/agent-browser-pool — REFRAME the file header comment (item step e + DOCS)
  - oldText (the 5 comment lines, lines 2-6):
        # bin/agent-browser-pool — admin CLI for the agent-browser-pool (PRD §2.1, §2.12).
        # Resolves its own real path (symlink-safe, same mechanism as bin/agent-browser) so it can
        # source the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
        # → repo/bin/agent-browser-pool at install time). Dispatches to the pool_admin_* functions.
        # Default command (no args) is `status`.
  - newText:
        # bin/agent-browser-pool — SOLE entry point for the agent-browser-pool: pool verbs + driving
        # router (PRD §2.1, §2.4, §2.12). Resolves its own real path (symlink-safe) so it can source
        # the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
        # → repo/bin/agent-browser-pool at install time). Pool verbs (status|reap|release|doctor|help)
        # dispatch to pool_admin_*; every other token is a DRIVING command routed to pool_wrapper_main,
        # which acquires/reuses the caller's lane and execs the real agent-browser (§2.4 steps 1-5).
        # Default command (no args) is `status`.
  - WHY: item step e ("admin CLI" → "SOLE entry point: pool verbs + driving router") + DOCS [Mode A]
         (cross-reference §2.1 + §2.4). The old "Dispatches to the pool_admin_* functions." line is
         now incomplete (it also dispatches to pool_wrapper_main) — replaced by an accurate
         both-arms description. Preserves the em-dash (—), the symlink note, the `status` default,
         and the §2.1/§2.12 cross-refs; ADDS §2.4. No apostrophes in new text (not needed anyway —
         comments are unquoted, but keeps it clean).
  - BUCKET: required (item step e + DOCS).

Task 3: VERIFY — static gates + isolated dispatch micro-check (no Chrome/daemons)
  - RUN: bash -n bin/agent-browser-pool                                    # exit 0
  - RUN: shellcheck -s bash bin/agent-browser-pool                         # DIFF vs baseline;
         assert the ONLY output is the pre-existing SC1091 info (NO new findings)
  - RUN: the grep + dispatch micro-checks in "Validation Loop → Level 1/2/3".
```

### Implementation Patterns & Key Details

```bash
# Task 1 — the `*)` arm must read EXACTLY:
#     *) pool_wrapper_main "$@" ;;
#   (4-space indent; bare statement; NO `|| exit 1`, NO trailing code. pool_wrapper_main is terminal.)
#
# Task 2 — the header comment block must read EXACTLY (5 lines → 6 lines):
#     # bin/agent-browser-pool — SOLE entry point for the agent-browser-pool: pool verbs + driving
#     # router (PRD §2.1, §2.4, §2.12). Resolves its own real path (symlink-safe) so it can source
#     # the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
#     # → repo/bin/agent-browser-pool at install time). Pool verbs (status|reap|release|doctor|help)
#     # dispatch to pool_admin_*; every other token is a DRIVING command routed to pool_wrapper_main,
#     # which acquires/reuses the caller's lane and execs the real agent-browser (§2.4 steps 1-5).
#     # Default command (no args) is `status`.
#
# DO NOT:
#   - change any other line. The 5 admin arms, cmd="${1:-status}", the unconditional
#     pool_config_init/pool_state_init, the REAL_SCRIPT/REAL_DIR resolution, and
#     `set -euo pipefail` stay byte-identical.
#   - add a guard (`|| ...`) or trailing statement to the `*)` arm.
#   - remove the unconditional init calls.
#   - add a `shift` (it would break pool_wrapper_main's full-argv contract).
#   - touch lib/pool.sh, bin/agent-browser, install.sh, any doc or test file.
#   - run test/validate.sh, test/transparency.sh, install.sh, or any real agent-browser / Chrome
#     command, and do NOT touch the shared $HOME (AGENTS.md §1). Use the Level-2 micro-check only.
```

### Integration Points

```yaml
NONE for this item.
  - No database, no config file, no NEW env vars, no routes.
  - The ONLY integration surface is the dispatch routing in bin/agent-browser-pool.
  - Downstream consumers that build on this LATER (NOT here):
      * bin/agent-browser (old PATH-shadow shim) → DELETED by P2.M2.T2.S1 (obsolete once driving
        routes through agent-browser-pool directly).
      * install.sh rewrite                                            (P2.M3.T1.S1)
      * SKILL.md / configuration.md / README.md rewrites              (P2.M4 / P2.M6)
      * test/transparency.sh + test/concurrency.sh driving-path       (P2.M5 — the REAL integration
        validation of `agent-browser-pool open <url>` → lane → Chrome, in an isolated sandbox).
```

---

## Validation Loop

> Per AGENTS.md §1/§2/§3: every command below is STATIC (`bash -n`, `shellcheck`, `grep`) or an
> isolated, `timeout`-bounded micro-check that redirects ALL pool state to a throwaway temp tree and
> forces the preflight to die fast — so it proves dispatch WITHOUT booting Chrome or any daemon. No
> real `agent-browser`, no real Chrome, no shared-$HOME writes, no full test suite.

### Level 1: Syntax & Style + source structure (run after the edits)

```bash
cd /home/dustin/projects/agent-browser-pool

# Syntax — must exit 0
bash -n bin/agent-browser-pool

# Lint — DIFF against the pre-change baseline. The UNCHANGED file already emits ONE info-level
# SC1091 on the `source` line (exits 1 because of the info). The contract is "NO NEW findings",
# NOT "exit 0". Capture and assert the ONLY line is the SC1091 info.
shellcheck -s bash bin/agent-browser-pool > /tmp/s1_sc.txt 2>&1; sc_rc=$?
echo "shellcheck rc=$sc_rc"
# Expect exactly ONE line, the SC1091 info on the `source` line:
test "$(grep -vc '^$' /tmp/s1_sc.txt)" -eq 1 && grep -q 'SC1091' /tmp/s1_sc.txt \
  && echo "OK: only the pre-existing SC1091 info (no new findings)" \
  || { echo "FAIL: new shellcheck finding(s) introduced:"; cat /tmp/s1_sc.txt; }
rm -f /tmp/s1_sc.txt

# Source-structure grep assertions (the contract)
grep -qF '*) pool_wrapper_main "$@" ;;' bin/agent-browser-pool  && echo "OK: *) routes to pool_wrapper_main" || echo "FAIL: *) arm not rewired"
grep -qF 'Unknown command' bin/agent-browser-pool               && echo "FAIL: Unknown command still present" || echo "OK: Unknown command removed"
grep -qF 'cmd="${1:-status}"' bin/agent-browser-pool            && echo "OK: default preserved" || echo "FAIL: default lost"
grep -qF 'status)            pool_admin_status ;;' bin/agent-browser-pool   && echo "OK: status arm"   || echo "FAIL: status arm changed"
grep -qF 'reap)              pool_admin_reap ;;'   bin/agent-browser-pool   && echo "OK: reap arm"     || echo "FAIL: reap arm changed"
grep -qF 'release)           pool_admin_release "${2:-}" ;;' bin/agent-browser-pool && echo "OK: release arm" || echo "FAIL: release arm changed"
grep -qF 'doctor)            pool_admin_doctor ;;' bin/agent-browser-pool   && echo "OK: doctor arm"  || echo "FAIL: doctor arm changed"
grep -qF -- '--help|-h|help)    pool_admin_help ;;' bin/agent-browser-pool  && echo "OK: help arm"    || echo "FAIL: help arm changed"

# Header comment assertions (item step e + DOCS)
grep -q 'SOLE entry point' bin/agent-browser-pool  && echo "OK: SOLE entry point framing" || echo "FAIL: no SOLE entry point framing"
grep -q '§2.4' bin/agent-browser-pool              && echo "OK: §2.4 cross-ref added"      || echo "FAIL: no §2.4 cross-ref"
grep -q 'admin CLI' bin/agent-browser-pool         && echo "FAIL: stale 'admin CLI' framing remains" || echo "OK: admin CLI framing removed"

# Expect: bash -n exit 0; shellcheck prints ONLY the SC1091 info; every grep prints OK:.
```

### Level 2: Component Validation — isolated dispatch micro-check (Chrome-free)

```bash
cd /home/dustin/projects/agent-browser-pool

# Isolate ALL pool state in a throwaway temp tree (AGENTS.md §1). Force the preflight to die FAST
# (AGENT_BROWSER_REAL → nonexistent) so a driving verb reaches pool_wrapper_main and dies at its
# 3rd step (_pool_preflight_real_bin), BEFORE owner resolve / lane acquire / Chrome boot. This
# PROVES the *) arm routes to pool_wrapper_main without booting anything.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A token that is NOT an admin verb → must now reach pool_wrapper_main (preflight die), NOT the
# old "Unknown command" error.
timeout 10 env \
  AGENT_BROWSER_POOL_STATE="$tmp" \
  AGENT_BROWSER_REAL="/nonexistent/agent-browser" \
  bin/agent-browser-pool bogus-driving-verb-xyz >/tmp/s1_out.txt 2>/tmp/s1_err.txt
rc=$?
echo "exit=$rc"
cat /tmp/s1_err.txt   # human-visible; should show the preflight die message

# (a) It FAILED (preflight die is exit 1) — good: dispatch reached pool_wrapper_main.
test "$rc" -ne 0 && echo "OK: driving verb fails (reached pool_wrapper_main)" || echo "FAIL: driving verb unexpectedly succeeded (would have exec'd/Chrome)"

# (b) The failure is the PREFLIGHT message (proof it reached pool_wrapper_main's 3rd step).
grep -q 'the real agent-browser binary is missing or not executable' /tmp/s1_err.txt \
  && echo "OK: preflight die message present (dispatch reached pool_wrapper_main)" \
  || echo "FAIL: preflight die message absent — dispatch did NOT reach pool_wrapper_main"

# (c) The OLD error is GONE.
grep -q 'Unknown command' /tmp/s1_err.txt \
  && echo "FAIL: old 'Unknown command' error still emitted" \
  || echo "OK: 'Unknown command' error gone"

# (d) No Chrome / no daemon / no lane dir was created (preflight died first).
test -d "$tmp/lanes" && echo "NOTE: lanes dir created by pool_state_init (expected, harmless; empty)" || echo "OK: no lanes dir"
test -z "$(ls -A "$tmp/lanes" 2>/dev/null)" && echo "OK: no lane leases written" || echo "FAIL: a lane lease was written (dispatch went too far)"

rm -f /tmp/s1_out.txt /tmp/s1_err.txt
# trap removes $tmp
```

Expected: `exit=1`, the preflight die message present, `Unknown command` absent, and NO lane lease
written. If the micro-check hangs past ~1s, ABORT — that would mean dispatch went PAST preflight
into owner/lane/Chrome work (an AGENTS.md §1 violation); do not wait for the `timeout 10`.

> NOTE: do NOT additionally run a real `agent-browser-pool open <url>` here — that boots Chrome and
> is the job of P2.M5's `test/transparency.sh` / `test/concurrency.sh` in an isolated sandbox. This
> item's job is only to prove the `*)` arm reaches `pool_wrapper_main` (done by the preflight die).

### Level 3: Integration / Cross-task safety (read-only checks only)

```bash
cd /home/dustin/projects/agent-browser-pool

# No new shellcheck findings anywhere (whole-file view): the only diagnostic must be SC1091.
shellcheck -s bash bin/agent-browser-pool 2>&1 | grep -v 'SC1091\|^$\|For more information\|shellcheck.net' \
  && echo "FAIL: unexpected shellcheck output above" || echo "OK: no shellcheck findings except SC1091"

# The sibling region in lib/pool.sh is untouched (disjoint): pool_wrapper_main + preflight intact.
grep -n 'pool_wrapper_main()' lib/pool.sh          # defn @3619 (UNCHANGED)
grep -n '_pool_preflight_real_bin' lib/pool.sh     # defn @3552 + call @3630 (UNCHANGED)

# The old PATH-shadow shim still exists (sibling P2.M2.T2.S1 deletes it, NOT this item).
test -f bin/agent-browser && echo "OK: bin/agent-browser untouched (owned by P2.M2.T2.S1)" || echo "NOTE: bin/agent-browser absent"

# Only bin/agent-browser-pool changed vs the starting tree (sanity: no stray edits elsewhere).
git diff --stat -- bin/agent-browser-pool   # expect exactly this one file
git diff --name-only | grep -v '^bin/agent-browser-pool$' \
  && echo "FAIL: unexpected files modified" || echo "OK: only bin/agent-browser-pool modified"

# Do NOT run: test/validate.sh, test/transparency.sh, install.sh, or any agent-browser command.
```

### Level 4: Creative & Domain-Specific Validation

N/A — this item has no runtime behavior beyond a dispatch handoff (the lane/Chrome/exec work is
pool_wrapper_main's, validated by P2.M5). The change is pinned by the item contract + PRD
§2.4/§2.12/§2.1. Levels 1-3 are complete and sufficient.

---

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n bin/agent-browser-pool` exits 0.
- [ ] `shellcheck -s bash bin/agent-browser-pool` introduces NO new findings (only the pre-existing
      SC1091 info remains).
- [ ] Level 2 micro-check: `exit=1`, preflight die message present, `Unknown command` absent, no
      lane lease written.

### Feature Validation

- [ ] `*)` arm changed to `pool_wrapper_main "$@"` (Task 1).
- [ ] Header comment reframed to "SOLE entry point: pool verbs + driving router" + §2.4 cross-ref,
      "admin CLI" framing gone (Task 2).
- [ ] `Unknown command` removed entirely from the file.
- [ ] `cmd="${1:-status}"` default preserved (byte-identical).
- [ ] All 5 admin arms byte-identical to the starting tree.

### Code Quality Validation

- [ ] Only `bin/agent-browser-pool` modified; only the `*)` arm + header comment touched within it.
- [ ] `pool_wrapper_main "$@"` invoked as a BARE statement (no guard, no trailing code — it is
      terminal).
- [ ] Unconditional `pool_config_init`/`pool_state_init` kept (admin arms still work).
- [ ] No `shift` introduced; full argv reaches `pool_wrapper_main`.
- [ ] `lib/pool.sh`, `bin/agent-browser`, `install.sh`, `references/configuration.md`, `SKILL.md`,
      `README.md`, `test/*` all untouched (owned by P2.M1/P2.M2.T2/P2.M3/P2.M4/P2.M5/P2.M6).

### Documentation & Deployment

- [ ] [Mode A] The file header comment IS the documentation change — it now states the binary is the
      sole entry point for pool verbs + driving commands, cross-referencing §2.1, §2.4, §2.12. No
      separate doc files change in THIS item (config.md = P2.M4.T2.S1; SKILL/README = P2.M4/P2.M6).

---

## Anti-Patterns to Avoid

- ❌ Don't assert `shellcheck` exits 0 — the unchanged file already exits 1 with one SC1091 *info*.
      The contract is "no NEW findings"; DIFF before/after.
- ❌ Don't add `|| exit 1` (or any guard / trailing statement) to the `*)` arm — `pool_wrapper_main`
      is TERMINAL (exec / pool_die); a bare statement is correct.
- ❌ Don't remove the unconditional `pool_config_init`/`pool_state_init` — the admin arms depend on
      them; pool_wrapper_main re-calling them is harmless + already documented.
- ❌ Don't add a `shift` (or change `cmd=`) — pool_wrapper_main NEEDS the full argv (the driving verb
      + its args).
- ❌ Don't assert on help-text strings in validation — the parallel P2.M1.T3.S1 owns `pool_admin_help`
      text in a disjoint file; assert only on dispatch wiring so the items compose in either order.
- ❌ Don't run a real driving command / boot Chrome / run the test suite during this item — use the
      isolated preflight-die micro-check; the real `open <url>`→lane→Chrome path is P2.M5's job.
- ❌ Don't touch `lib/pool.sh` or `bin/agent-browser` — `pool_wrapper_main` is done (P2.M1); the shim
      deletion is P2.M2.T2.S1.

---

## Confidence Score

**10/10** — one-pass success likelihood. The change is two disjoint edits to a 25-line dispatcher:
one logic line (`*)` error → `pool_wrapper_main "$@"`) and one 5-line→6-line header comment. Every
`oldText`/`newText` is given verbatim and verified against the live post-P2.M1 tree. `pool_wrapper_
main` is proven self-contained + terminal (so the bare statement is correct and needs no guard), and
the full-argv handoff is proven (no `shift`). The one realistic pitfall — misreading the shellcheck
baseline as "must exit 0" when the unchanged file already exits 1 with an SC1091 info — is called out
explicitly with a DIFF-based assertion. The validation is deterministic and Chrome-free (preflight
die via `AGENT_BROWSER_REAL=/nonexistent` + temp state), pi-ancestor-independent, and bounded by
`timeout`, so it cannot wedge the sandbox (AGENTS.md §1/§2). No residual risk.
