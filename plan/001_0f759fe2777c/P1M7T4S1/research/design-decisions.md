# Design Decisions — `pool_admin_doctor()` (P1.M7.T4.S1)

The synthesis that drives the PRP. Factual backbone = `codebase-doctor-facts.md`;
external validation = `external-doctor-patterns.md`. Each decision cites its
rationale + the gotcha it resolves. Verified against LIVE `lib/pool.sh` (3916
lines, `set -euo pipefail` at **line 18**, `pool_admin_release` LANDED @3830).

---

## D1 — Lib-only; append at the DYNAMIC live EOF; own banner

`pool_admin_doctor()` is APPENDED to `lib/pool.sh` under a NEW banner
`# Admin CLI — doctor (P1.M7.T4.S1)`. NO new files, NO edits to any existing
function, NO new globals/env-vars. **The append site is the CURRENT live EOF,
detected dynamically (`tail`), NOT hardcoded.** Rationale: the sibling
`pool_admin_release` (P1.M7.T3.S1) LANDED during research (file grew 3762 →
3916; release @3830, EOF = its closing `}` @3916). doctor appends AFTER
`pool_admin_release`. Order among admin functions is IRRELEVANT — each is
self-contained, called by name from the future dispatcher
(`case doctor) pool_admin_doctor "$@" ;;`). Hardcoding "after pool_admin_reap
@3762" (as the landed siblings' comments do) would mis-place doctor today.

## D2 — No input (full system scan)

`pool_admin_doctor()` takes NO arguments. Mirrors `pool_admin_reap` (no args).
Locals only: counters (`ok`/`warn`/`fail`), the lanes snapshot array, loop vars,
and per-lane scratch (`json`/`fields`/`ephemeral_dir`/`chrome_pid`/`port`).

## D3 — Non-fatal by necessity: CANNOT call pool_check_btrfs / pool_check_master

**THE dominant correctness constraint.** `pool_die` (lib/pool.sh:30) is
`exit 1` — a PROCESS exit, NOT catchable. `pool_check_btrfs` (lib/pool.sh:230)
and `pool_check_master` (lib/pool.sh:266) BOTH `pool_die` on the very failures
doctor exists to DETECT + REPORT. If doctor called them, the FIRST problem would
abort the whole run BEFORE the summary printed. So doctor REPLICATES their
detection NON-fatally:

- **btrfs** (mirror pool_check_btrfs @234): `fstype="$(findmnt -nno FSTYPE -T
  "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"`; OK if `[[ "$fstype" == "btrfs" ]]`.
  The `-T` flag is MANDATORY (pool_check_btrfs GOTCHA @217-221; a bare `findmnt
  "$dir"` matches SOURCE not the mount tree and exits 1 even on btrfs). Empty
  fstype (missing root / findmnt failure) = "not btrfs".
- **master** (mirror pool_check_master @267-269): `[[ -d "$POOL_MASTER_DIR" ]] &&
  [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]` (exists + non-empty; no
  stat/du of the 4.8 GB master).

This is the ONE place doctor must NOT compose the landed helpers. It composes
their LOGIC, not their fatal wrappers.

## D4 — Severity model: FAIL (blocking) vs WARN (recoverable)

The contract asks for OK/WARN/FAIL counts + "return non-zero if any FAIL" but
does NOT pin which finding is which severity. This decision does:

| Finding | Severity | Why |
|---|---|---|
| Required dep MISSING (flock, setsid, pgrep, pkill, curl, jq, cp, chrome) | **FAIL** | pool cannot function |
| POOL_REAL_BIN not present/executable | **FAIL** | wrapper has nothing to exec |
| FS not btrfs (and POOL_ALLOW_SLOW_COPY != 1) | **FAIL** | every acquire would do a catastrophic 4.8 GB real copy |
| master missing/empty | **FAIL** | acquire cannot bootstrap |
| notify-send MISSING | **(optional — not FAIL, not counted)** | PRD §2.16: "optional"; _pool_alert guards it |
| LEAK (lease w/o ephemeral_dir) | **WARN** | recoverable — release/reap cleans it |
| LEAK (lease w/ dead chrome_pid) | **WARN** | the reaper's exact domain (stale lease) |
| DISCONNECTED (port not listening) | **WARN** | transient; ensure_connected self-heals |
| ORPHAN DIR (dir w/o lease) | **WARN** | recoverable — reap reuses / release cleans |

**Rationale:** infrastructure problems BLOCK correct operation → FAIL (exit 1);
lane/dir inconsistencies are EXACTLY what `reap`/`release` recover from → WARN
(exit 0). So doctor becomes a triage tool: "FAIL = fix your setup; WARN = run
`reap`/`release`." Precedent: `brew doctor` (advisory warnings vs hard errors),
`git fsck` (non-zero on error) — external-doctor-patterns §2. **Exit rule:
`if (( fail > 0 )); then return 1; else return 0; fi`.** WARN never moves the
exit code. (doctor `return`s — it is a library function; the dispatcher exits.)

## D5 — notify-send is OPTIONAL → its absence is NOT a FAIL

PRD §2.16: "notify-send (libnotify — exhaustion alerts; **optional**)." `_pool_alert`
(lib/pool.sh:2824) guards it with `command -v notify-send >/dev/null 2>&1`.
Therefore doctor prints `notify-send ... MISSING (optional)` and does NOT count
it toward FAIL (nor WARN — it is genuinely fine to lack it). All OTHER deps are
required → MISSING is FAIL. This is the ONE asymmetry in the dep section.

## D6 — The chrome dep check uses POOL_CHROME_BIN (name-or-path), not the literal "google-chrome-stable"

The contract dep list literally says "google-chrome-stable", but POOL_CHROME_BIN
(pool_config_init @152-174) is configurable via `$AGENT_CHROME_BIN` (default
`google-chrome-stable`; an explicit path is canonicalized, a bare name is stored
as-is for PATH resolution at launch). The CORRECT + USEFUL check is POOL_CHROME_BIN
with the name-or-path branch:
```bash
if [[ "$POOL_CHROME_BIN" == */* ]]; then [[ -x "$POOL_CHROME_BIN" ]]; \
else command -v "$POOL_CHROME_BIN" >/dev/null 2>&1; fi
```
This respects BOTH the default (google-chrome-stable) AND an override
(e.g. chromium) — checking the literal "google-chrome-stable" would FALSE-alarm
on a chromium setup. This is the ONE smart substitution in the dep loop.

## D7 — Dep-check idiom = `command -v` (POSIX), always inside a guard

`command -v "$dep" >/dev/null 2>&1` is the codebase's EXISTING PATH-presence
idiom (`_pool_alert` @2824) + POSIX-standard + ShellCheck-preferred (SC2230:
prefer over `which`). `command -v` returns 1 when the dep is absent → a BARE call
ABORTS under `set -e`. So EVERY dep check is inside `if command -v …; then …; else
…; fi` (or a `||` list — errexit-exempt). doctor ESTABLISHES the first systematic
multi-dep PATH check in the lib.

## D8 — Reconciliation loop mirrors `pool_admin_status`

Reuse the LANDED idiom verbatim:
```bash
mapfile -t lanes < <(pool_lanes_list)         # rc 0 always; process-sub exit not propagated
if (( ${#lanes[@]} == 0 )); then ...; fi       # (( )) INSIDE if (bare @0 is FATAL)
for lane in "${lanes[@]}"; do
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then ...; continue; fi
    mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")
    ephemeral_dir="${fields[0]:-}"; chrome_pid="${fields[1]:-}"; port="${fields[2]:-}"
    ...
done
```
ONE jq fork per lane (not three `pool_lease_field` calls) — mirrors status @3650.
`pool_lease_read` rc 1 (missing/corrupt) MUST be guarded `if !`. `jq -r` echoes
numbers as digit strings (fine for `/proc/$chrome_pid` and `curl $port`).

## D9 — Per-lane checks: three (non-fatal), with PROVISIONAL-lease handling

For each booted lease (port > 0):
1. **dir exists?** `[[ -d "$ephemeral_dir" ]]` → no ⇒ **LEAK (lease without dir)**.
2. **chrome alive?** guard `chrome_pid` is a positive integer, then
   `[[ -d "/proc/$chrome_pid" ]]` (the codebase liveness idiom — pool_owner_alive
   @636; `kill -0` is a TRAP it rejects). no ⇒ **LEAK (lease with dead Chrome)**.
3. **port listening?** `curl -sf --max-time 2 "http://127.0.0.1:$port/json/version"
   >/dev/null 2>&1` inside `if` (pool_daemon_connected @1711 / pool_find_free_port
   @1407 idiom; `--max-time 2` bounds a hung port). no ⇒ **DISCONNECTED**.

**PID-recycling caveat** (external-doctor-patterns §5): `[[ -d /proc/$pid ]]`
proves *a* process holds the PID, not that it is *Chrome*. Accepted: (a) it
matches the codebase idiom + the contract literally; (b) the reconciliation is
multi-faceted — a recycled PID still fails the PORT check (DISCONNECTED) and the
dir check, so a true leak surfaces via another channel; (c) Chrome `comm` is
truncated (TASK_COMM_LEN=15 → "google-chrome-s"), so a comm match is unreliable
and would risk false negatives. The simple `/proc` check is the pragmatic
baseline; a stronger `/proc/$pid/exe` readlink match is a documented FUTURE
enhancement, NOT in scope.

**PROVISIONAL-lease handling** (the acquire-in-progress state): a lease with
`port == 0` (and `chrome_pid == 0`) is a PROVISIONAL claim from
`pool_acquire_locked` step 3d that did NOT complete its post-lock boot (which
sets port>0 on success OR cleans up via `_pool_release_lane_internals` on
failure). Running the three checks on it would spuriously flag
LEAK(dead-chrome)+DISCONNECTED(port=0). So: **if `port` is not a positive
integer → emit ONE WARN "lane N: PROVISIONAL (port=0; incomplete acquire)" and
SKIP the three checks.** A persistent provisional lease is itself a leak
(crashed mid-acquire that wasn't cleaned up) → WARN is correct.

## D10 — DIR reconciliation: ORPHAN DIR detection

For each entry in `$POOL_EPHEMERAL_ROOT/*/` (lane dirs only), extract the
basename `N`; if `N` is numeric AND there is NO lease `$POOL_LANES_DIR/N.json`
→ **ORPHAN DIR** (WARN). Guards: the ephemeral root may not exist on a fresh
pool → iterate with `[[ -d "$d" ]] || continue` (nullglob is NOT set → a no-match
glob expands to its literal, which `-d` rejects); numeric filter on the basename
(a stray non-numeric dir is skipped, mirroring pool_lanes_list's `^[0-9]+$` test).
An orphan dir = a profile left behind by a crashed release/reap → recoverable
via `release`/manual rm → WARN.

## D11 — Output format: sectioned report to stdout

All output to STDOUT (capturable). Sections (each a bracketed header + per-item
lines): `[dependencies]`, `[binary]`, `[filesystem]`, `[master]`, `[lanes]`,
`[dirs]`, `[summary]`. Per-item line = `name ....pad.... STATUS [detail]`. The
summary line is machine-parseable: `OK=N  WARN=N  FAIL=N`, followed by a verdict
("Healthy." when fail==0; "Problems found." when fail>0). External-doctor-patterns
§3 (mirrors brew doctor / flutter doctor grouped output). The EXACT format is
pinned in the PRP with a reference render.

## D12 — Return code

`if (( fail > 0 )); then return 1; else return 0; fi`. `return` (not `exit`) —
doctor is a library function; the dispatcher (M7.T5.S1) translates rc to exit.
WARNs never affect rc. Matches the contract ("Return non-zero if any FAIL").

## D13 — Non-fatal discipline: NEVER pool_die in the body

doctor REPORTS, it does not DIE. Every probe is guarded so a missing dep / dead
PID / closed port never aborts the run before the summary prints (the #1 bug in
hand-written Bash diagnostics — external-doctor-patterns §7). The ONLY
pool_die-capable calls are the precondition `pool_config_init` + `pool_state_init`
(rc-0-or-pool_die on genuine misconfiguration — correct + matches the siblings;
a broken config SHOULD fail loudly).

## D14 — DOCS via Mode A (function header) + a suggested --help line for the dispatcher

The function's header doc-comment documents EVERY check + the output contract
(the item's DOCS step, Mode A). doctor ALSO supplies a one-line suggested
`--help` entry for `doctor` for the future dispatcher (M7.T5.S1) to wire — doctor
does NOT create the binary or wire --help itself.

## D15 — No collateral edits

Append-only to `lib/pool.sh`. `bin/` (M6.T3.S2 owns agent-browser; M7.T5.S1 owns
agent-browser-pool), `.gitignore` (orchestrator-owned M10.T1.S2), `PRD.md` /
`tasks.json` / `prd_snapshot.md` (read-only), `test/` (M9.T1.S1 owns the harness)
are ALL untouched. doctor owns ONLY `pool_admin_doctor()`.

## D16 — set -e guards (all live — strict mode is at lib/pool.sh:18)

The LANDED admin comments cite `lib/pool.sh:23`; that is STALE — `set -euo
pipefail` is at **line 18** (verified). doctor's header cites line 18. Every
hazard is live:
- `pool_lease_read` rc 1 (missing/corrupt) → guard `if ! json="$(…)"`.
- bare `(( expr ))` STATEMENT returns 1 when value is 0 → FATAL. Keep `(( ))`
  ONLY inside `if`/`elif` (or `||`/`&&` lists); `$(( ))` is always safe.
- `local x="$(…)"` is SC2155 (masks errexit) → declare then assign. (`local
  lane="${1:-}"`-style parameter expansion is SC2155-safe inline.)
- `findmnt` / `curl` / `ls` / `cat` exit non-zero → `|| true` or `if !`/`if`.
- `command -v` returns 1 on absent dep → inside `if`/`||`.
- `pool_lanes_list` rc-0-always → bare `mapfile -t lanes < <(pool_lanes_list)`
  safe (process-sub exit not propagated anyway).
- nullglob NOT set → a no-match glob is its literal → `[[ -d "$f" ]] || continue`.
