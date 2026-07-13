# Research — P1.M7.T5.S1: Admin CLI dispatcher (`bin/agent-browser-pool`) + `pool_admin_help()`

## Date: 2026-07-13

---

## 1. TWO deliverables, and WHERE each lives

The item description names TWO things:

1. **`bin/agent-browser-pool`** — the thin dispatcher executable. The item gives a
   VERBATIM contract (the `case` statement). This is a NEW file in `bin/`.
2. **`pool_admin_help()`** — prints usage for all subcommands. The item says
   "Also implement pool_admin_help()."

**WHERE does `pool_admin_help()` live?** → `lib/pool.sh`, appended at the current
live EOF (now **4233**, after the LANDED `pool_admin_doctor`), under a new banner
`# Admin CLI — help (P1.M7.T5.S1)`.

**Why lib/pool.sh, not inline in the binary:**
- The verbatim contract calls `pool_admin_help` directly in the `case` — there is
  NO inline function definition shown. It must be DEFINED by the sourced lib.
- EVERY other `pool_admin_*` function (status @3594, reap @3730, release @3830,
  doctor @4011) lives in `lib/pool.sh` under its own `# Admin CLI — <name>` banner.
  `pool_admin_help` follows the SAME sibling pattern (naming convention: `pool_admin_*`).
- This keeps `bin/agent-browser-pool` a THIN dispatcher (mirrors `bin/agent-browser`,
  which is a thin 8-line shim that delegates to `pool_wrapper_main`). All logic lives
  in the lib; the binary is just bootstrap + dispatch.

So: **`bin/agent-browser-pool` is bin-only; `pool_admin_help()` is lib-only (append).**
Two files change. `lib/pool.sh`'s diff is append-only (banner + function). The other
three admin functions are NOT touched.

---

## 2. The verbatim dispatcher contract (from item description — AUTHORITATIVE)

```bash
#!/usr/bin/env bash
set -euo pipefail
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_config_init
pool_state_init
cmd="${1:-status}"
case "$cmd" in
  status) pool_admin_status ;;
  reap) pool_admin_reap ;;
  release) pool_admin_release "${2:-}" ;;
  doctor) pool_admin_doctor ;;
  --help|-h|help) pool_admin_help ;;
  *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
```

Notes on each line:
- `readlink -f "${BASH_SOURCE[0]}"` + `dirname` → symlink-safe lib sourcing. The admin
  tool is symlinked to `~/.local/bin/agent-browser-pool` (PRD §2.1: "← admin tool
  (symlink → repo bin/)"). A bare `dirname "$0"` would look for
  `<symlink-dir>/../lib/pool.sh` → WRONG → `source` fails → `set -e` aborts. **This is
  the #1 correctness risk — the Level-2 symlink test MUST exercise it.** Identical to
  the landed `bin/agent-browser` (read it: it is byte-identical lines 1-12).
- `pool_config_init` + `pool_state_init` BEFORE the `case`. These are idempotent; each
  admin function ALSO calls them as its own step "a" precondition (redundant, harmless).
  They CAN `pool_die` on genuine misconfiguration (e.g. `AGENT_CHROME_PORT_RANGE<=0`,
  a non-uint config value) — so on a misconfigured host even `--help`/unknown-command
  aborts BEFORE dispatch. On a normally-configured host (all defaults) both succeed.
  This is a deliberate consequence of the verbatim contract (init unconditionally up
  front so every subcommand has globals). **Follow the contract verbatim; do NOT move
  init inside the branches** (that diverges from the authoritative item contract).
- `cmd="${1:-status}"` → running `agent-browser-pool` with NO args runs `status`
  (documented in help).
- `release) pool_admin_release "${2:-}"` → passes the SECOND positional (or empty).
  `release 7` → `$2=7`. Bare `release` → `$2=""` → release prints usage + rc 1.
- `*) echo "Unknown command: $cmd" >&2; exit 1` → unknown command: message to STDERR,
  process exit 1. (`exit`, not `pool_die` — fine, dispatcher's job.)

---

## 3. The four admin signatures (for accurate help text)

| command | function | args | output | rc |
|---|---|---|---|---|
| `status` | `pool_admin_status` @3594 | none | READ-ONLY lane table (LANE/PORT/SESSION/OWNER_PID/OWNER_CWD/CHROME_PID/AGE/STATE); "No active lanes." if empty | 0 always |
| `reap` | `pool_admin_reap` @3730 | none | "No stale lanes found." / "Reaped N stale lane(s)." | 0 always |
| `release [<N>\|all]` | `pool_admin_release` @3830 | 1 optional | "Released N lane(s)." / "Released lane N." / "Lane N has no active lease." / "No active lanes to release."; usage→stderr on empty/invalid | 0 ok / 1 usage+notfound |
| `doctor` | `pool_admin_doctor` @4011 | none | sectioned report (deps/binary/fs/master/lanes/dirs/summary) | 0 healthy / 1 any FAIL |

**All four are LANDED** (verified: `grep -n '^pool_admin_' lib/pool.sh`). So the
dispatcher wires to functions that EXIST. **No parallel-coordination risk** (T4.S1
doctor LANDED during research; EOF moved 3916 → 4233). Append `pool_admin_help` at
the CURRENT live EOF (detect via `tail`, do NOT hardcode 4233).

Help-text convention (from release's own usage block @lib/pool.sh:3909):
`Usage: agent-browser-pool release [<N>|all]`. So the top-level help uses
`Usage: agent-browser-pool <command> [args]`.

---

## 4. Config env vars (for help text — from `pool_config_init` @135-174)

```bash
AGENT_BROWSER_POOL_STATE       $HOME/.local/state/agent-browser-pool   # lease store + logs
AGENT_CHROME_MASTER            $HOME/.agent-chrome-profiles/master-profile   # template (copied per lane)
AGENT_CHROME_EPHEMERAL_ROOT    $HOME/.agent-chrome-profiles/active     # ephemeral lane dirs
AGENT_BROWSER_REAL             $HOME/.local/bin/agent-browser          # shadowed real CLI
AGENT_CHROME_BIN               google-chrome-stable                    # name OR path
AGENT_CHROME_PORT_BASE         53420                                   # lowest pool TCP port
AGENT_CHROME_PORT_RANGE        1000                                    # port-count in pool
AGENT_BROWSER_POOL_WAIT        600                                     # acquire block timeout (s)
AGENT_CHROME_HEADLESS          (empty/false)                           # launch Chrome headless
AGENT_CHROME_ALLOW_SLOW_COPY   (empty/false)                           # permit non-btrfs copies
AGENT_BROWSER_POOL_DISABLE     (empty/false)                           # passthrough (wrapper)
```
All OPTIONAL with those defaults. Help should list them (Mode A: `--help` IS the
user-facing docs). Keep the descriptions short.

---

## 5. `pool_admin_help()` — design (the KEY decisions)

**Inputs:** none.
**Output:** usage text → **stdout** (explicit `--help` is conventional stdout; the
release-on-misuse usage goes to stderr — DIFFERENT case). `return 0`.

**D1 — help is PURE: no `pool_config_init`/`pool_state_init` INSIDE the function.**
Unlike its four siblings (each calls config+state as step "a"), `pool_admin_help`
reads NO global, touches NO disk, does NO `$(…)`. It is the most robust function:
just `printf`s + `return 0`. (The dispatcher's verbatim contract already calls
config+state before the `case`, so on a normal host help runs after successful init.
But the FUNCTION ITSELF must not depend on init — it is pure documentation.)

**D2 — never `pool_die`, never return non-zero.** It always succeeds. (Matches the
"explicit --help = rc 0" convention; `--help` must never exit 1.)

**D3 — document ALL subcommands + the default + the aliases.** Cover status/reap/
release/doctor/help, the `${1:-status}` default, and the `--help|-h|help` aliases.
Also list config env vars (Mode A docs). End with a pointer to `doctor` for setup
diagnostics (the PRD §2.16 "verify deps at runtime" path).

**D4 — stdout discipline.** All `printf` to stdout (no `>&2`, no log). Capturable
(`agent-browser-pool --help | grep release`).

**D5 — placement: append at live EOF, own banner, append-only.** Banner
`# Admin CLI — help (P1.M7.T5.S1)`. NO edits to any existing function. Detect EOF
via `tail` (it moved 3916→4233 as doctor landed; do not hardcode).

---

## 6. set -e gotchas specific to this task

- `set -euo pipefail` is at **lib/pool.sh line 18** (line 14 is just the comment).
  Sibling comments citing ":23" are STALE. The help banner should cite line 18.
- `pool_admin_help` has NO `$(…)` capture, NO `(( ))`, NO command-that-can-fail →
  it is the SIMPLEST admin function (fewest set -e hazards). `printf` always rc 0.
  No guards needed inside it.
- The dispatcher's `echo ... >&2; exit 1` for unknown command is fine (no set -e
  hazard — `echo` always succeeds; `exit` is terminal).
- The dispatcher's own `set -euo pipefail` (line 2) + the lib's (line 18) are both
  kept (idempotent; matches `bin/agent-browser`). The readlink/dirname lines run
  UNDER strict mode BEFORE sourcing — the shim's own `set -e` protects them.

---

## 7. `bin/` layout + `.gitkeep`

```
bin/
├── .gitkeep              # RETAINED (do not remove — out of scope; a later sync task may clean up)
├── agent-browser         # M6.T3.S2 (wrapper shim) — UNCHANGED
└── agent-browser-pool    # NEW (this task) — the admin dispatcher; chmod 0755
```
The lib header (lines 5-6) ALREADY names `bin/agent-browser-pool` as a consumer, so
sourcing is expected. `.gitignore` has NO rule matching `bin/agent-browser-pool`
(verified pattern list in M6.T3.S2 research). Do NOT modify `.gitignore`.

---

## 8. Validation approach (NO Chrome needed)

The dispatcher + help are testable WITHOUT Chrome / a master profile / a real `pi`
ancestor — they only need a sourceable lib + the landed admin functions. Levels:
- **L1:** `bash -n` + `shellcheck -s bash` (both files); `test -x`; lib append-only.
- **L2 (functional, no Chrome):**
  - `./bin/agent-browser-pool --help` (and `-h`, and `help`) → usage to stdout, rc 0.
  - `./bin/agent-browser-pool` (NO args) → `status` runs → "No active lanes." (fresh
    state dir) or a lane table; rc 0. (Proves the `${1:-status}` default.)
  - `./bin/agent-browser-pool status` → same as above.
  - `./bin/agent-browser-pool reap` → "No stale lanes found." (fresh dir); rc 0.
  - `./bin/agent-browser-pool doctor` → sectioned report (rc 0 healthy or 1 if host
    missing a dep); proves doctor wires correctly.
  - `./bin/agent-browser-pool release` (no target) → usage to STDERR, rc 1.
  - `./bin/agent-browser-pool bogus` → "Unknown command: bogus" to STDERR, rc 1.
  - **SYMLINK test (THE distinguishing check):** symlink `$TMP/agent-browser-pool →
    <repo>/bin/agent-browser-pool`, invoke `$TMP/agent-browser-pool --help` → usage
    prints. Proves `readlink -f` sourced `<repo>/lib/pool.sh` through the symlink (a
    bare `dirname "$0"` shim would `source <tmp>/../lib/pool.sh` → fail → abort).
  - Use a fresh `AGENT_BROWSER_POOL_STATE="$(mktemp -d)"` so tests don't touch the
    real pool state, and `AGENT_CHROME_ALLOW_SLOW_COPY=1` so doctor's [filesystem]
    check is WARN-not-FAIL on a non-btrfs host (the CI/dev host may not be btrfs).
- **L3/L4:** deferred to the M9 harness (needs Chrome + master + btrfs for the full
  status/reap/release lifecycle). The symlink test in L2 is the integration proof.

---

## 9. Scope boundaries (do NOT do these)

- Do NOT create/modify `install.sh` (M8.T1.S1, future — symlinks the binary to
  `~/.local/bin/`).
- Do NOT touch `bin/agent-browser` (M6.T3.S2 sibling — unchanged).
- Do NOT edit status/reap/release/doctor (siblings — unchanged).
- Do NOT modify `.gitignore`, `PRD.md`, `tasks.json`, `prd_snapshot.md` (owned).
- Do NOT remove `bin/.gitkeep` (out of scope).
- Do NOT add the `pool_admin_help` banner BEFORE doctor's banner (append at EOF only).
