# META Passthrough Model — Complete Reference Map

Static analysis only (grep + read). No browsers/tests run.
Scope searched: `lib/pool.sh`, `bin/agent-browser-pool`, `test/*.sh`,
`.agents/skills/**/*.md`, `docs/*.md`, `README.md`.

> **docs/ directory does NOT exist** in this repo → `docs/*.md` has zero hits.
> All docs references live under `.agents/skills/agent-browser-pool/`.

---

## 0. Two distinct "passthrough" concepts (DO NOT conflate)

The word "passthrough" appears in `lib/pool.sh` with **two unrelated meanings**.
A bug fix targeting META dispatch must touch only #1:

| # | Concept | Where | Meaning |
|---|---------|-------|---------|
| 1 | **META dispatch passthrough** (the task subject) | `pool_dispatch_classify` + `pool_wrapper_main` step c | classify a command as `meta` → `exec "$POOL_REAL_BIN" "$@"` unchanged, no lane |
| 2 | **Owner passthrough mode** (UNRELATED) | `pool_owner_resolve`, `pool_acquire_locked` | `POOL_OWNER_PID==0` (no pi ancestor found) — the owner is "passthrough". The wrapper gates this as FAIL-FAST, never a real lane claim |

References to concept #2 (owner passthrough) are listed in §4 below for
disambiguation; they are **out of scope** for a META-classify bug fix.

---

## 1. `pool_dispatch_classify` — the classifier function

**File:** `lib/pool.sh`
**Comment/contract block:** lines **3012–3069** (the `# PRD §2.4 step 0 dispatcher...` block).
**Function definition:** lines **3070–3128** (`pool_dispatch_classify() {` … `}`).

The next function (`pool_normalize_close`) begins at line **3181**.

### Classification logic (inside the function)
- **a. Flag scan** (lines 3071–3102): `while (( $# > 0 ))` shifts flags.
  - `--help|-h|--version` → `printf 'meta\n'; return 0` (lines 3076–3078) — short-circuit.
  - `--session <X>` → `shift 2 || shift` (line 3083).
  - `--*` → `shift 1` (line 3089).
  - `-*` (short flag except `-h`) → `shift 1` (line 3094).
  - first non-flag → `cmd="$1"; next="${2:-}"; break` (lines 3097–3100).
- **e. No command found** (flags-only / empty) → `meta` (lines 3104–3109).
- **b. META classification** (lines 3112–3123):
  - `cmd==session && next==list` → `meta` (lines 3114–3117).
  - `cmd ∈ {skills,dashboard,plugin,mcp}` → `meta` (lines 3118–3123, `case`).
- **c/d. Everything else** → `driving` (lines 3125–3127).

**Contract:** pure (reads NO globals, writes NO files, calls NO externals);
echoes exactly one token `meta`|`driving`; returns 0 **ALWAYS** → caller needs no `if`-guard.

---

## 2. Step-c META block in `pool_wrapper_main`

**File:** `lib/pool.sh`
**`pool_wrapper_main() {`:** line **3516** (locals declared at 3517).

**Step-c block (the `if [[ "$class" == "meta" ]]` block):** lines **3529–3536**

```
3529:     # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
3530:     # pool_dispatch_classify is rc 0 ALWAYS (no guard); prints exactly one token meta|driving.
3531:     # Plain assignment (class declared above) → SC2155-clean + errexit-safe (classify never fails).
3532:     class="$(pool_dispatch_classify "$@")"
3533:     if [[ "$class" == "meta" ]]; then
3534:         _pool_log "pool_wrapper_main: meta command → passthrough"
3535:         exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — skills/--help/session list/etc.
3536:     fi
```

The actual `if` body is lines **3533–3536** (log + `exec "$POOL_REAL_BIN" "$@"`).
`$POOL_REAL_BIN` is frozen earlier by `pool_config_init` (step a, lines 3519–3527)
and guarded by `_pool_preflight_real_bin` (line 3527) which `pool_die`s if the
binary is missing/unexecutable — this guard covers BOTH driving AND meta paths.

> Note: `exec "$@"` here passes the **ORIGINAL, unmodified** argv. Only the
> driving branch (step k) uses the cleaned `${POOL_CLEAN_ARGS[@]}` (see
> GOTCHA at lines 3499–3501).

---

## 3. `bin/agent-browser-pool` — the entry-point dispatcher

**File:** `bin/agent-browser-pool` (41 lines total)
**Has ZERO occurrences** of `meta`, `passthrough`, or `dispatch_classify`.

Its `case` dispatch (lines 30–37) runs **BEFORE** `pool_wrapper_main`:

```
30: case "$cmd" in
31:     status)            pool_admin_status ;;
32:     reap)              pool_admin_reap ;;
33:     release)           pool_admin_release "${2:-}" ;;
34:     doctor)            pool_admin_doctor ;;
35:     --help|-h|help)    pool_admin_help ;;
36:     *) pool_wrapper_main "$@" ;;
37: esac
```

**Critical consequence:** `--help` / `-h` / `help` and a bare no-arg call
(defaults to `status`, line 29 `cmd="${1:-status}"`) are caught here as **pool
verbs** and NEVER reach `pool_dispatch_classify`. So although classify would tag
`--help`/`-h`/`--version` as `meta`, only `--version` actually reaches the
classifier at runtime — `--help`/`-h` are intercepted by bin first.

`skills`, `dashboard`, `plugin`, `mcp`, `session list`, and `--version` all hit
the `*)` arm → `pool_wrapper_main` → classify `meta` → passthrough.

---

## 4. All `meta` / `passthrough` / `dispatch_classify` hits (file:line)

### `lib/pool.sh`
**META dispatch (concept #1 — in scope):**
- `3016` `# PRD §2.4 step 0 dispatcher. Classify an agent-browser invocation as 'meta'`
- `3017` `# (passthrough — exec the real binary unchanged) or 'driving'...`
- `3018` `# locked lane). ECHOES 'meta' or 'driving'...`
- `3025` `# commands. stdout = EXACTLY one token ('meta'|'driving'). Returns 0 always.`
- `3029–3030` `--help | -h | --version → echo 'meta'...` (flag-scan contract)
- `3036–3038` `b. META classification: 'session' + next=='list' → 'meta'...`
- `3047` `e. No command found (only flags / empty $@) → 'meta' (passthrough...)`
- `3052` `# 'class="$(pool_dispatch_classify "$@")"' is set -e-safe with NO guard`
- `3076–3078` `--help|-h|--version) printf 'meta\n'; return 0 ;;`
- `3096` `# 'session list' two-word META command` (comment in flag scan)
- `3104–3109` no-command → `printf 'meta\n'; return 0`
- `3112–3123` `# META classification...` + `session list` arm + `skills|dashboard|plugin|mcp` case
- `3120` `printf 'meta\n'` (inside the META case)
- `3439–3447` `_pool_preflight_real_bin` comment: real binary is a HARD runtime dep for **driving AND meta** (3440 `# commands (skills/--version/…) exec it too`)
- `3468` `# - M6.T1.S1 pool_dispatch_classify (step c: meta vs driving)`
- `3499–3501` GOTCHA: passthrough exec (c) passes ORIGINAL `"$@"` UNCHANGED
- `3526–3527` preflight covers driving + meta
- `3529–3536` **step-c META block** (see §2)

**Owner passthrough (concept #2 — UNRELATED, out of scope):**
- `402–403` `# lifecycle (M6.T3 passthrough gate)` (owner-resolution doc)
- `497–498` `# → PID=0 (passthrough)` (pool_owner_resolve comment)
- `580–581` `_pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"`
- `1005–1006` `# GOTCHA — POOL_OWNER_PID == "0" (passthrough) passes the guard...`
- `2089–2099` passthrough owner must NOT claim a lane (pool_acquire_locked defense-in-depth)
- `2149` `# exhaustion (all lanes live / passthrough owner) → M5.T4`

### `bin/agent-browser-pool`
- **No occurrences** of `meta`, `passthrough`, or `dispatch_classify`.
  Pool verbs intercepted here; everything else → `pool_wrapper_main` (line 36).

### `test/transparency.sh`
**`test_passthrough_skills()` — lines 236–243:**
- `236` `test_passthrough_skills() {`
- `237` `_transparency_setup_real_env || return 1`
- `238` `_transparency_spawn_owner >/dev/null` (pi ancestor present; meta ignores it)
- `240` `w="$(timeout 15 "$ABPOOL_ADMIN" skills get core 2>/dev/null || true)"`
- `241` `r="$(timeout 15 "$POOL_REAL_BIN"  skills get core 2>/dev/null || true)"`
- `242` `assert_eq "$r" "$w" "skills get core: pool output == real binary output (meta passthrough)" || return 1`
- `243` `}`

**`test_version_passthrough()` — lines 270–277:**
- `270` `test_version_passthrough() {`
- `271` `_transparency_setup_real_env || return 1`
- `272` `_transparency_spawn_owner >/dev/null`
- `274` `w="$(timeout 15 "$ABPOOL_ADMIN"  --version 2>/dev/null || true)"`
- `275` `r="$(timeout 15 "$POOL_REAL_BIN" --version 2>/dev/null || true)"`
- `276` `assert_eq "$r" "$w" "--version: pool output == real binary output (meta passthrough)" || return 1`
- `277` `}`

**Other transparency.sh references:**
- `10` `(a) agent-browser-pool skills get core → passthrough (META → exec real binary; byte-equal)`
- `12` `(b2) agent-browser-pool --version → passthrough (META → exec real binary; byte-equal)`
- `229–234` TEST (a) header comment (skills META → exec)
- `246–249` TEST (b1) header: `--help` → POOL help, NOT passthrough (caught by bin)
- `265–268` TEST (b2) header: `--version` → passthrough via classify

### `test/validate.sh`
**`selftest_dispatch_classify_cases()` — lines 355–384** (pure-function unit table):
- `345–354` header comment (full classification table, Issue 4)
- `355` `selftest_dispatch_classify_cases() {`
- `358–361` META: `--help`/`-h`/`--version` → `meta`
- `363–366` META: `session list` + `skills|dashboard|plugin|mcp` → `meta`
- `368–374` META (Issue 4): no-args / flags-only / empty → `meta`
  (`pool_dispatch_classify`, `--json`, `--session foo`, `--session=foo`,
   `--headed --json`, `-i`, `""`)
- `376–378` DRIVING: `open click connect close session back get find` → `driving`
- `380` DRIVING: `unknowncmd` → `driving` (default)
- `382–383` DRIVING: `--session foo open`, `--json click` → `driving`
- `384` `}`
- (No meta/passthrough references elsewhere in validate.sh beyond lines 345–384.)

### `test/concurrency.sh`, `test/release_reaper.sh`
- **No occurrences** of `meta`, `passthrough`, or `dispatch_classify`.

### `.agents/skills/agent-browser-pool/SKILL.md`
- `60–62` "A small set of **meta** commands pass straight through... `skills`,
  `--version`, `session list`, `dashboard`, `plugin`, `mcp`."
- `143–144` "For the full ... meta-vs-driving dispatch classification, read
  `references/configuration.md`."

### `.agents/skills/agent-browser-pool/references/configuration.md`
- `44` `## Command dispatch: meta vs. driving`
- `49` `1. **meta** command → **passthrough** (no lane — the real binary runs unchanged).`
- `55` `### Meta commands (passthrough — never acquire a lane)`
- `57–60` list: `--version`; `skills, dashboard, plugin, mcp`; `session list`;
  flags-only invocation.
- `64–66` `> --help, -h, help are **pool verbs**, not meta-passthrough` (caught by bin first).
- `8` `pool_dispatch_classify` listed among shipped-behavior functions.

### `README.md`
- `95` META commands work from any shell.
- `135–136` "A few tokens are **META** and pass through to the real `agent-browser`
  unchanged, acquiring no lane: `--version`; the subcommands `skills`, ..."
- `255–256` "passes a META command through to the real binary..."
- `263–264` flow diagram: `META (--version, skills, dashboard, plugin, mcp,
  session list, flags-only)? → passthrough to the real binary (no lane)`
- `266` `no pi ancestor → FAIL-FAST (not passthrough)` (owner concept #2, disambiguation)
- `277` `2. classify — pool verb? META command? → handled above (no lane);`
- `317` META commands work from any shell.

### `docs/*.md`
- **N/A — `docs/` directory does not exist.**

---

## 5. Architecture / data flow

```
agent-browser-pool <args>
        │  bin/agent-browser-pool  (line 29: cmd="${1:-status}")
        │  case (lines 30-37):
        ├─ status/reap/release/doctor ─→ pool_admin_*   (pool verb, NO lane, NO classify)
        ├─ --help|-h|help             ─→ pool_admin_help (pool verb; intercepted HERE)
        └─ *)                          ─→ pool_wrapper_main "$@"
                                          │
   pool_wrapper_main (lib/pool.sh:3516)
     a. pool_config_init / pool_state_init / _pool_preflight_real_bin   (3519-3527)
     c. class="$(pool_dispatch_classify "$@")"                          (3532)
        ├─ class==meta  → exec "$POOL_REAL_BIN" "$@" UNCHANGED          (3533-3536)
        └─ class==driving → owner resolve → lane lifecycle → exec cleaned args
```

- `pool_dispatch_classify` is **pure** and the **sole classifier** (one token on stdout).
- The meta exec path uses the **original argv**; only driving uses normalized args.
- `bin/agent-browser-pool` short-circuits pool verbs (incl. `--help`/`help`/bare→status)
  **before** classify runs. This is why `--help` is a pool verb even though classify
  would tag `--help`/`-h` as `meta`.

---

## 6. Start here

Open **`lib/pool.sh:3070`** — the `pool_dispatch_classify` definition (body
3070–3128, contract comment 3012–3069). Then its single call site, the step-c
META block at **`lib/pool.sh:3529–3536`** in `pool_wrapper_main`. The
classification truth table is mirrored in **`test/validate.sh:355–384`**
(`selftest_dispatch_classify_cases`), and the end-to-end byte-equality
contract in **`test/transparency.sh:236–243`** (`test_passthrough_skills`)
and **`test/transparency.sh:270–277`** (`test_version_passthrough`).

## 7. Risks / open questions
- **`--help`/`-h`/`help`/bare-no-arg** are pool verbs handled in `bin/agent-browser-pool`
  (lines 35, 29), NOT by `pool_dispatch_classify`. A fix that changes classify's
  `--help`/`-h` handling will NOT affect the live `--help` path (still pool help).
- Keep the **owner-passthrough** references (§4 concept #2, lines 580–581, 1005,
  2089–2099) clearly separate — they are unrelated to META dispatch.
- `docs/` does not exist; if the task expects doc edits there, the path is stale.
