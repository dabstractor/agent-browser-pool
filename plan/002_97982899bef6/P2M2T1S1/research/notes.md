# Research notes — P2.M2.T1.S1: Change `*)` branch from error to `pool_wrapper_main` dispatch

## 0. Item contract (verbatim from the work-item description)

Edit `bin/agent-browser-pool` (25 lines):
- a. `*) echo "Unknown command: $cmd" >&2; exit 1 ;;` → `*) pool_wrapper_main "$@" ;;`
- b. Keep ALL other case arms UNCHANGED.
- c. Keep `cmd="${1:-status}"` default (bare `agent-browser-pool` → status).
- d. `$@` passed to `pool_wrapper_main` must include ALL original args (driving verb + its args).
- e. Header comment: "admin CLI" → "SOLE entry point: pool verbs + driving router".
- f. Run `bash -n bin/agent-browser-pool` and `shellcheck -s bash bin/agent-browser-pool`.
- DOCS [Mode A]: update the file header comment; cross-reference PRD §2.1 and §2.4.

Source of truth: `plan/002_97982899bef6/architecture/gap_analysis.md` §2 (reads identically to the
contract above) + PRD §2.4 (h3.8) + §2.12 (h3.16) + §2.1 (h3.5).

## 1. Current state of `bin/agent-browser-pool` (verified, full 25-line file)

```bash
#!/usr/bin/env bash
#
# bin/agent-browser-pool — admin CLI for the agent-browser-pool (PRD §2.1, §2.12).
# Resolves its own real path (symlink-safe, same mechanism as bin/agent-browser) so it can
# source the shared lib regardless of where it is symlinked (~/.local/bin/agent-browser-pool
# → repo/bin/agent-browser-pool at install time). Dispatches to the pool_admin_* functions.
# Default command (no args) is `status`.
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.1; mirrors bin/agent-browser)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
# Init config + state unconditionally so every subcommand has globals + a lanes dir.
# (Idempotent; each pool_admin_* ALSO calls them as its own precondition — redundant, harmless.)
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
```

Confirmed: `wc -l bin/agent-browser-pool` == 25. The `*)` arm is the ONLY line changed for logic;
the 5-line header comment block (lines 2-6) is the ONLY other region changed (text only).

## 2. Why `pool_wrapper_main "$@"` receives the FULL argv (item step d — verified)

`cmd="${1:-status}"` is a plain parameter assignment; it does NOT `shift`. Verified:
`grep -n 'shift' bin/agent-browser-pool` → only `cmd=` at line 17, NO `shift` anywhere.
Therefore `$@` still contains every original positional. Example:
- `agent-browser-pool open https://example.com`
  → `$1=open $2=https://example.com` → `cmd=open` → case `open` matches `*)` →
  `pool_wrapper_main open https://example.com`.
- pool_wrapper_main's 3rd step is `class="$(pool_dispatch_classify "$@")"` on that full argv
  (lib/pool.sh:3631), so it MUST receive the driving verb + its args. ✓

## 3. `pool_wrapper_main` is fully ready (dependency contract — verified)

`pool_wrapper_main` (lib/pool.sh:3619-3757) is self-contained and terminal:
- step a: `pool_config_init` + `pool_state_init` (idempotent — the dispatcher ALSO calls these
  unconditionally; the redundancy is harmless and already documented in the dispatcher comment).
- step b: `_pool_preflight_real_bin` — pool_die's if `$POOL_REAL_BIN` missing/non-exec.
- step c: `class="$(pool_dispatch_classify "$@")"` → meta → `exec "$POOL_REAL_BIN" "$@"`
  (passthrough); driving → continue.
- step d: `pool_owner_resolve` → `POOL_OWNER_PID==0` ⇒ `pool_die "requires a pi ancestor…"`
- steps e–k: find-or-acquire lane → ensure connected → normalize/strip/clean args → exec real bin.

So routing `*)` → `pool_wrapper_main "$@"` is correct for BOTH (a) genuine driving commands
(open/click/type/…) AND (b) meta commands that slip past the admin arms (skills/--version/session
list…) — pool_wrapper_main's own classify handles meta vs driving. No special-casing needed in the
dispatcher. (gap_analysis §2: "Pool verbs are handled by the case arms; everything else (driving
commands + meta commands that slip through) goes to pool_wrapper_main.")

RC taxonomy (lib/pool.sh:3585-3593): pool_wrapper_main has NO useful return code — it is TERMINAL
(every success path `exec`s, every fatal path `pool_die`/`exit 1`). So `*) pool_wrapper_main "$@" ;;`
needs no `||`/`if` guard, and nothing follows it in the case arm. ✓

## 4. CRITICAL: shellcheck baseline on `bin/agent-browser-pool` is NOT clean-exit

Verified live:
```
$ shellcheck -s bash bin/agent-browser-pool   # exits 1, prints:
In bin/agent-browser-pool line 12:
source "$REAL_DIR/../lib/pool.sh"
       ^------------------------^ SC1091 (info): Not following: ./../lib/pool.sh …
```
SC1091 is an **info**-level diagnostic, PRE-EXISTING on the unchanged file (it's the sourced-lib
warning, unavoidable for a dispatcher). shellcheck exits 1 *because of the info*.

➡ **Contract for item step f is NOT "shellcheck exits 0". It is "the change introduces NO NEW
shellcheck findings."** The post-edit `shellcheck -s bash bin/agent-browser-pool` output must be
IDENTICAL to the pre-edit output (still only the single SC1091 info, same line). The implementer
must DIFF before/after (or assert the only line in the output is the SC1091 info), not assert exit 0.

`bash -n bin/agent-browser-pool` DOES exit 0 today and must continue to.

## 5. Safe, Chrome-free, deterministic dispatch validation (AGENTS.md §1/§2 compliant)

The risk with validating "the `*)` arm now reaches pool_wrapper_main" is that a real driving
command would proceed past classify → owner → ACQUIRE → BOOT CHROME (AGENTS.md §1 violation during
planning, and a real lane boot during implementation).

**Solution — force the preflight to die FIRST**, before any owner/lane/Chrome work:
1. `AGENT_BROWSER_POOL_STATE=$tmp` → redirect all state writes (pool_config_init freezes paths;
   pool_state_init mkdirs `$tmp/lanes` + touches `$tmp/acquire.lock`) to a throwaway temp tree.
2. `AGENT_BROWSER_REAL=/nonexistent/agent-browser` → pool_config_init freezes
   `POOL_REAL_BIN=<canonical of /nonexistent/agent-browser>` via `realpath -m` (canonicalize-
   missing, exits 0 — lib/pool.sh:65-70 — so config does NOT fail on a missing path).
3. Run `timeout 10 env AGENT_BROWSER_POOL_STATE=$tmp AGENT_BROWSER_REAL=/nonexistent/agent-browser \
   bin/agent-browser-pool bogus-driving-verb-xyz`.
4. Dispatch path: case `bogus-driving-verb-xyz` → `*)` → `pool_wrapper_main bogus-driving-verb-xyz`
   → config → state → `_pool_preflight_real_bin` → `[[ -f … && -x … ]]` false →
   `pool_die "agent-browser-pool: the real agent-browser binary is missing or not executable: …"
   "Install agent-browser >= 0.28, or set AGENT_BROWSER_REAL to the correct path."` (lib/pool.sh:3552-3559).
   `pool_die` = `printf '%s\n' "$*" >&2; exit 1` (lib/pool.sh:30-33).

This is **deterministic, pi-ancestor-independent, daemon-free, Chrome-free, and network-free**.
The preflight die message is PROOF the `*)` arm reached pool_wrapper_main (preflight is pool_
wrapper_main's 3rd step). The OLD behavior (`Unknown command: bogus-driving-verb-xyz`) is GONE.

Negative control (admin arm unchanged): grep-assert the source still has all 5 admin arms verbatim
+ `cmd="${1:-status}"` + the help arm routes to pool_admin_help. Do NOT runtime-test `--help`'s
TEXT (the parallel P2.M1.T3.S1 owns help text) — only assert `--help` exits 0 via grep of the arm,
or optionally run it isolated (pool_admin_help is PURE: no globals/disk/$(…)).

## 6. Scope boundaries (do NOT touch — owned by other items)

- `lib/pool.sh` — UNTOUCHED. pool_wrapper_main, _pool_preflight_real_bin, pool_admin_* all belong
  to completed P2.M1 items. This item edits ONLY `bin/agent-browser-pool`.
- `bin/agent-browser` (the old PATH-shadow shim) — DELETED by sibling P2.M2.T2.S1, NOT here.
- `install.sh` — rewrite is P2.M3.T1.S1.
- `SKILL.md`, `references/configuration.md`, `README.md` — P2.M4 / P2.M6.
- `test/*` — P2.M5. The full driving-path integration (real `agent-browser-pool open <url>` reaching
  a lane + Chrome) is validated there in an isolated sandbox, NOT by this item.
- Parallel item P2.M1.T3.S1 edits `pool_admin_help` TEXT in lib/pool.sh — disjoint from this file;
  my validation must NOT assert on help-text strings (only on dispatch wiring).

## 7. PRD cross-references for the header comment (item step e / DOCS)

- §2.1 (h3.5): "~/.local/bin/agent-browser-pool ← SOLE entry point (symlink → repo bin/): pool verbs
  + driving router".
- §2.4 (h3.8): step 0 classify — POOL VERB → admin; "anything else → DRIVING command → lane logic".
- §2.12 (h3.16): "<driving verb> [args] # anything else → acquire/reuse MY lane + exec the real
  agent-browser".

The new header must: (1) drop the "admin CLI" framing, (2) state "SOLE entry point: pool verbs +
driving router", (3) cross-reference §2.1 + §2.4 (currently only §2.1, §2.12).
