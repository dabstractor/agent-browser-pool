# Research notes — P2.M4.T2.S1: Update configuration.md

**Scope**: ONE file — `.agents/skills/agent-browser-pool/references/configuration.md`
(currently **134 lines**; gap_analysis §6 estimated ~170 — actual is 134). This is a
TARGETED-EDIT task (≈7 regions), not a full rewrite.

## Source-of-truth verification (all STATIC reads — AGENTS.md §1 compliant; nothing executed)

### 1. DISABLE is fully removed from shipped code
```
$ grep -n 'AGENT_BROWSER_POOL_DISABLE\|POOL_DISABLE' lib/pool.sh
(none)
```
→ config.md's DISABLE row + DISABLE callout + DISABLE dispatch item + DISABLE troubleshooting
reference are ALL now describing dead behavior. Must be removed.

### 2. AGENT_CHROME_MASTER default = REAL Chrome user-data-dir (NOT master-profile)
`lib/pool.sh` `pool_config_init` (lines 142-154):
```bash
    # CoW SOURCE: defaults to the user's REAL Chrome user-data-dir (auto-detected), so
    # agents start from the human's current auth without a separate template. The source
    # may be live/in-use (PRD §2.7). Override AGENT_CHROME_MASTER for a dedicated template.
    xdg_cfg="${XDG_CONFIG_HOME:-$POOL_HOME_DIR/.config}"
    master_dir="$(_pool_config_canon_path \
        "${AGENT_CHROME_MASTER:-$xdg_cfg/google-chrome}")"
    ...
    POOL_MASTER_DIR="$master_dir"; declare -g POOL_MASTER_DIR
```
→ effective default = `${XDG_CONFIG_HOME:-~/.config}/google-chrome`. config.md currently says
`~/.agent-chrome-profiles/master-profile` (WRONG). Also `pool_admin_help` (lib/pool.sh:4624)
already ships the correct text to mirror:
```
  AGENT_CHROME_MASTER   CoW source profile (default: ~/.config/google-chrome — your real Chrome user-data-dir)
```

### 3. No-pi-ancestor = FAIL-FAST (not passthrough)
`lib/pool.sh` `pool_wrapper_main` step d (lines 3641-3646):
```bash
    # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
                 "For raw browser use without pooling, call 'agent-browser' directly."
    fi
```
→ exact guidance string to quote in the dispatch table + troubleshooting fix column:
"driving commands require a pi ancestor; for raw browser use call `agent-browser` directly".

### 4. Dispatch order in pool_wrapper_main (meta → owner → acquire)
Steps in `pool_wrapper_main` (lib/pool.sh:43-81):
- step a: config + state init
- preflight: `_pool_preflight_real_bin`
- step c: `pool_dispatch_classify` → meta → `exec "$POOL_REAL_BIN" "$@"` (passthrough UNCHANGED)
- step d: owner resolve → no pi → `pool_die`
- step e→g: find-or-acquire lane, exec real binary with cleaned args

→ contract's new dispatch order (1 meta→passthrough, 2 no-pi→fail-fast, 3 otherwise→acquire)
matches the shipped step order exactly.

### 5. --help/-h/help are POOL VERBS, NOT meta-passthrough (consistency with sibling skill)
`bin/agent-browser-pool` outer dispatcher:
```bash
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;        # ← intercepted HERE, before pool_wrapper_main
    *) pool_wrapper_main "$@" ;;
esac
```
→ `agent-browser-pool --help` / `-h` / `help` → `pool_admin_help` (pool verb). They NEVER reach
`pool_dispatch_classify`. By contrast `--version` is NOT in the outer case → falls to `*)` →
`pool_wrapper_main` → `pool_dispatch_classify` → meta → passthrough to real binary.

`pool_dispatch_classify` (lib/pool.sh:3173-3223) meta set = `--help|-h|--version` (flag pos),
`session list` (two-word), `skills|dashboard|plugin|mcp`, empty/flags-only. NOTE: classify WOULD
call --help/-h meta, but they are intercepted upstream — so the USER-FACING accurate statement is
"--help/-h/help are pool verbs". The sibling PRP P2.M4.T1.S1 enforces this exact point in SKILL.md
(hard grep: meta list must NOT include --help/-h). **configuration.md must agree or the two docs
contradict each other.**

### 6. Bare `agent-browser-pool` (no args) defaults to `status` — NOT meta
`cmd="${1:-status}"` → bare invocation hits the `status)` arm → `pool_admin_status`. Never reaches
classify. The current config.md meta-list item "A bare `agent-browser` with no subcommand (upstream
prints help)" is doubly wrong: wrong command name (shadowing era) AND wrong classification. A
flags-only invocation (e.g. `agent-browser-pool --json`) DOES reach *) → classify → meta → help.

## Exhaustive stale-reference map in current configuration.md (134 lines)

| # | Line(s) | Current content | Required change | Contract LOGIC |
|---|---------|-----------------|-----------------|----------------|
| E1 | 19 | `AGENT_CHROME_MASTER` row, default `~/.agent-chrome-profiles/master-profile`, "static master template" | default → `${XDG_CONFIG_HOME:-~/.config}/google-chrome`; meaning → real Chrome dir, may be live/in-use (PRD §2.7) | a |
| E2 | 28 | `AGENT_BROWSER_POOL_DISABLE` env-table row | **DELETE** row | b |
| E3 | 32-35 | "The three that most affect behavior" bullet for DISABLE ("the safety valve") | replace with AGENT_CHROME_MASTER bullet (defaults to live Chrome → agents pick up new auth) | d |
| E4 | 48 | dispatch item 1: "DISABLE truthy → passthrough" | **DELETE** item | e |
| E5 | 49-51 | dispatch items 2/3/4 (meta→passthrough / no-pi→passthrough / otherwise→acquire) | renumber: (1) meta→passthrough, (2) no-pi→**fail-fast** (`pool_die`), (3) otherwise→acquire | e |
| E6 | 55 | meta-list first bullet `--help, -h, --version` | remove `--help, -h` (pool verbs); keep `--version`; add callout that --help/-h/help are pool verbs intercepted by the entry-point dispatcher | e (consistency w/ sibling SKILL.md) |
| E7 | 58 | meta-list "A bare `agent-browser` with no subcommand (upstream prints help)" | fix to flags-only invocation (e.g. `--json`); note bare→`status` | e (accuracy) |
| E8 | 66 | "For a driving command under `pi` with pooling active:" | drop "with pooling active" (DISABLE-era vestige; pooling is now unconditional) | accuracy |
| E9 | 73 | ASCII lifecycle diagram: `agent-browser open <url>` | → `agent-browser-pool open <url>` | g |
| E10 | 110 | troubleshooting row 1: "Passthrough: no pi ancestor, or DISABLE truthy" / "Run under pi; unset DISABLE" | cause → "Driving command run outside pi (no pi ancestor → fail-fast)"; fix → "Run under pi; for raw browser use call agent-browser directly" | f |
| E11 | 112 | troubleshooting row 3 symptom: "`agent-browser` call hangs" | → "`agent-browser-pool` call hangs" (consistency w/ new command model) | g (spirit) |

**Unchanged (verified clean, no DISABLE/stale refs):** title + intro (1-8); env-table rows other
than MASTER/DISABLE; test-only-hooks callout (37-39); "Driving commands" subsection (60-64);
"How acquire works" prose + remainder of diagram (74-82); entire "Release lifecycle" (84-105);
troubleshooting rows 2,4-8; "Admin CLI" section (107-134).

## Cross-doc consistency (PARALLEL execution hazard)

P2.M4.T1.S1 rewrites SKILL.md IN PARALLEL. Its PRP hard-asserts:
- SKILL.md has ZERO `AGENT_BROWSER_POOL_DISABLE`, `transparent`, `shadowing`, `agent-browser open`.
- SKILL.md's meta list = `skills, --version, session list, dashboard, plugin, mcp` (NO --help/-h).
- SKILL.md §5 points to `references/configuration.md` for the full env table + dispatch table +
  troubleshooting matrix.

→ configuration.md (this item) MUST be consistent: no DISABLE, master = real Chrome dir,
--help/-h = pool verbs. If config.md contradicts SKILL.md, an agent reading both is misled.
The --help/-h callout (E6) is the linchpin of this consistency.

## Validation approach

ALL static (AGENTS.md §1): `grep` for removals (DISABLE, master-profile, `agent-browser open`,
"no pi ancestor → passthrough") + additions (real Chrome dir default, fail-fast wording,
`agent-browser-pool open`), `shellcheck` on the embedded bash code-fence snippets, Markdown
structure check, and a `git status` scope check tolerant of the parallel SKILL.md change.

## No external research needed

This is a pure internal doc-accuracy task: make the reference doc match shipped bash behavior.
The PRD (§2.11, §2.4, §2.7, §2.14, §2.17) + `lib/pool.sh` + `bin/agent-browser-pool` ARE the
sources of truth. No libraries, no external patterns.
