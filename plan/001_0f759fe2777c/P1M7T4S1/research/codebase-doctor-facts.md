# codebase-doctor-facts.md — `pool_admin_doctor()` (P1.M7.T4.S1)

FACTS note for implementing `pool_admin_doctor()` in `lib/pool.sh`. All line
numbers VERIFIED against LIVE `lib/pool.sh` on 2026-07-13 (`wc -l` = **3916**).
This note is the factual backbone of the PRP.

> STALE-COMMENT NOTE: LANDED admin comments (status/reap/release) and the task
> brief cite `set -euo pipefail` at `lib/pool.sh:23`. The ACTUAL strict-mode line
> is **line 18**. Treat inline "lib/pool.sh:23" refs as stale; the real guard is 18.

> KEY RUNTIME DISCOVERY (changes the plan): sibling P1.M7.T3.S1 `pool_admin_release`
> has ALREADY LANDED (banner `lib/pool.sh:3765`, function `pool_admin_release()`
> `lib/pool.sh:3830`, closing `}` at EOF **line 3916**). The brief assumed it was
> "in progress"; it is LANDED. doctor must APPEND after the CURRENT EOF (3916),
> after `pool_admin_release` — NOT after `pool_admin_reap` (3762).

---

## 1. pool_config_init + pool_state_init (globals doctor needs)

**`pool_config_init()` — `lib/pool.sh:126`.** Re-runnable, mutable globals (no
readonly guard — every call re-resolves). Globals doctor reads:

| Global | Line | Value / shape |
|---|---|---|
| `POOL_STATE_DIR` | 157 | `$AGENT_BROWSER_POOL_STATE` or `$HOME/.local/state/agent-browser-pool` |
| `POOL_MASTER_DIR` | 158 | `$AGENT_CHROME_MASTER` or `$HOME/.agent-chrome-profiles/master-profile` |
| `POOL_EPHEMERAL_ROOT` | 159 | `$AGENT_CHROME_EPHEMERAL_ROOT` or `$HOME/.agent-chrome-profiles/active` |
| `POOL_REAL_BIN` | 160 | `$AGENT_BROWSER_REAL` or `$HOME/.local/bin/agent-browser` |
| `POOL_CHROME_BIN` | 164-174 | name-or-path (branch below) |
| `POOL_ALLOW_SLOW_COPY` | 194 | "1"/"0" string |
| `POOL_LANES_DIR` | 200 | `$POOL_STATE_DIR/lanes` |

**CHROME_BIN name-or-path branch (`lib/pool.sh:152-163`):**
```bash
    local chrome_in chrome_out
    chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
    if [[ "$chrome_in" == */* ]]; then
        chrome_out="$(_pool_config_canon_path "$chrome_in")"   # explicit path → canonicalize
    else
        chrome_out="$chrome_in"                                # bare name → store as-is (PATH-resolved at launch)
    fi
    POOL_CHROME_BIN="$chrome_out"; declare -g POOL_CHROME_BIN
```
Doctor: if `POOL_CHROME_BIN` contains `/` → `[[ -x "$POOL_CHROME_BIN" ]]`; if a
bare name → `command -v "$POOL_CHROME_BIN"`. Both branches needed.

**`pool_state_init()` — `lib/pool.sh:202`.** Idempotent `mkdir -p` + `touch`:
```bash
pool_state_init() {
    mkdir -p -- "$POOL_LANES_DIR" || pool_die "pool_state_init: cannot create lanes dir: $POOL_LANES_DIR"
    touch -- "$POOL_LOCK_FILE"   || pool_die "pool_state_init: cannot create lock file: $POOL_LOCK_FILE"
    return 0
}
```
Confirmed idempotent (doc comment: "NO 'if not exists' guard is needed",
"calling this on every acquire is cheap and correct"). **Doctor calling it is
SAFE** — mirrors status/reap/release step "a". Returns 0; pool_die's only on a
real FS failure (acceptable loud failure for a misconfigured pool).

---

## 2. pool_die is `exit 1` — NOT catchable (CRITICAL)

**`pool_die()` — `lib/pool.sh:30`:**
```bash
pool_die() {
    printf '%s\n' "$*" >&2
    exit 1     # line 32 — PROCESS exit, NOT catchable
}
```
`exit 1` terminates the PROCESS. **CRITICAL IMPLICATION:** doctor CANNOT call
`pool_check_btrfs` or `pool_check_master` (both pool_die on the failure path
doctor is specifically trying to DETECT). doctor MUST replicate their detection
NON-FATALLY. Verified pool_die calls:
- **`pool_check_btrfs` — `lib/pool.sh:247`:** `pool_die "pool_check_btrfs: $POOL_EPHEMERAL_ROOT is not on btrfs" ...`
- **`pool_check_master` — `lib/pool.sh:272`:** `pool_die "pool_check_master: master template missing or empty:" ...`

---

## 3. The btrfs detection primitive (replicate, non-fatal)

**`pool_check_btrfs` — `lib/pool.sh:230`.** Exact fstype capture (`lib/pool.sh:234`):
```bash
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
```
**GOTCHA (mandatory `-T`):** `--target` is MANDATORY. A bare
`findmnt -nno FSTYPE "$dir"` (no `-T`) matches the positional arg against SOURCE
(a device), not the mount tree, and exits 1 on this host EVEN ON BTRFS — verified
2026-07-12 (`lib/pool.sh:217-221`). external_deps.md §3.2 example omits `-T` and
is BROKEN; do not copy it.

**Empty fstype = "not btrfs"** (`lib/pool.sh:241`). `|| true` neutralizes findmnt
exit-1 so set -e does not abort; fstype → "" on missing path/not-found.

Doctor's non-fatal check (capture, compare WITHOUT pool_die): `fstype="$(findmnt
-nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"; if [[ "$fstype" ==
"btrfs" ]]; then OK; else FAIL; fi`. (Pool root may not exist yet on a fresh
install — `|| true` handles that.)

---

## 4. The master detection primitive (replicate, non-fatal)

**`pool_check_master` — `lib/pool.sh:266`.** Exact test (`lib/pool.sh:267-269`):
```bash
pool_check_master() {
    if [[ -d "$POOL_MASTER_DIR" ]] \
       && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
        return 0
    fi
    pool_die ...
```
Tests existence (`-d`) AND non-emptiness (`ls -A`). Does NOT stat/du the 4.8 GB
master. `2>/dev/null` on `ls` neutralizes a missing dir under set -e.

Doctor's non-fatal check: same `[[ -d ... ]] && [[ -n "$(ls -A ... 2>/dev/null)" ]]`,
report OK/FAIL instead of pool_die.

---

## 5. The two LANDED admin siblings doctor must mirror in SHAPE

Established admin-function shape (Mode A, lib-only, self-contained, called by name
from the future dispatcher M7.T5.S1): locals up front (never `local x="$(…)"` /
SC2155); precondition step "a" `pool_config_init`+`pool_state_init`; banner section;
doc-comment is the function-level docs (Mode A); CONTRACT + `set -e GUARDS` header.

### pool_admin_status — `lib/pool.sh:3594` (banner `lib/pool.sh:3544`)
```
# Admin CLI — status (P1.M7.T1.S1)
```
Locals-up-front (`lib/pool.sh:3607-3611`):
```bash
    local -a lanes fields
    local fmt json lane
    local port session owner_pid owner_cwd chrome_pid acquired_at connected
    local age state
```
Step "a" (`lib/pool.sh:3616-3618`): `pool_config_init` / `pool_state_init`.
Snapshot idiom (`lib/pool.sh:3631`): `mapfile -t lanes < <(pool_lanes_list)`
(process-sub exit NOT propagated → set -e safe; empty output → empty array).
Empty-pool — `(( ))` INSIDE `if` (`lib/pool.sh:3634-3637`):
```bash
    if (( ${#lanes[@]} == 0 )); then printf 'No active lanes.\n'; return 0; fi
```
Per-lane read guard (`lib/pool.sh:3638-3646`):
```bash
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then ...; continue; fi
```
Multi-field ONE-fork jq extraction (`lib/pool.sh:3650-3659`):
```bash
    mapfile -t fields < <(jq -r \
        '.port, .session, .owner.pid, .owner.cwd, .chrome_pid, .acquired_at, .connected' \
        <<<"$json")
    port="${fields[0]:-}"; ...
```

### pool_admin_reap — `lib/pool.sh:3730` (banner `lib/pool.sh:3690`)
```
# Admin CLI — reap (P1.M7.T2.S1)
```
**rc-0-always contract** (header: "Returns 0 always", "NEVER calls pool_die ...
NEVER returns non-zero"). `count="$(pool_reap_stale)"` UNGUARDED (pool_reap_stale
rc-0-always, `lib/pool.sh:3747`). `(( count == 0 ))` INSIDE `if` (`lib/pool.sh:3754`);
ends `return 0` (`lib/pool.sh:3760`).

### CURRENT EOF + last function
**`lib/pool.sh` is 3916 lines.** LAST function = **`pool_admin_release`** (banner
`lib/pool.sh:3765`, `pool_admin_release()` `lib/pool.sh:3830`, closing `}` at
**line 3916** = EOF). Confirmed via `wc -l` + `tail -5`.

---

## 6. Lease read primitives for the reconciliation loop

**`pool_lease_read` — `lib/pool.sh:823`.** rc 0 echoes raw JSON / rc 1 on missing
or corrupt (logs ONE warning on corrupt). **MUST guard with `if !`** under set -e
(a bare capture ABORTS on rc 1 — documented `lib/pool.sh:820`):
```bash
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then ...; fi
```
**`pool_lease_field` — `lib/pool.sh:876`.** Single dotted-field read, rc 1 on
missing/corrupt; present-null echoes "null" rc 0. **MUST guard.** Nested in one
shot (`owner.pid`).

**RECOMMENDED for doctor's reconciliation:** mirror status's ONE-fork mapfile.
Doctor needs `ephemeral_dir` (string), `chrome_pid` (number), `port` (number):
```bash
    mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")
    ephemeral_dir="${fields[0]:-}"; chrome_pid="${fields[1]:-}"; port="${fields[2]:-}"
```
ONE jq fork per lane (not three `pool_lease_field` calls). `:-` defends a short
read. jq `-r` echoes numbers as digit strings — fine for `/proc/$chrome_pid` and
the curl `$port` interpolation. (Established idiom: status `lib/pool.sh:3650`.)

---

## 7. The lease schema fields

**`pool_lease_write` — `lib/pool.sh:682`** (jq build `lib/pool.sh:703-718`), confirmed
by external_deps.md §6 (`architecture/external_deps.md:199-222`). 12 fields:
`version`(1) · `lane`(int) · `ephemeral_dir`(string) · `port`(int) · `session`(string)
· `owner{pid,comm,starttime,cwd}` · `chrome_pid`(int) · `chrome_pgid`(int)
· `acquired_at`(int) · `last_seen_at`(int) · `connected`(JSON bool).

**ephemeral_dir naming CONFIRMED** = `$POOL_EPHEMERAL_ROOT/$lane`. `pool_boot_lane`
`lib/pool.sh:2193`:
```bash
    ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"
```
(also `lib/pool.sh:2003` acquire claim: `ephemeral_dir="$POOL_EPHEMERAL_ROOT/$N"`.)
Doctor's "dir exists?" = `[[ -d "$ephemeral_dir" ]]` reading ephemeral_dir from the
lease (which is `$POOL_EPHEMERAL_ROOT/$lane`).

external_deps.md §6 verbatim (`external_deps.md:203-222`):
```json
{"version":1,"lane":7,"ephemeral_dir":"/home/dustin/.agent-chrome-profiles/active/7",
 "port":53427,"session":"abpool-7",
 "owner":{"pid":836725,"comm":"pi","starttime":1234567890,"cwd":"/home/dustin/projects/x"},
 "chrome_pid":104816,"chrome_pgid":104816,
 "acquired_at":1720000000,"last_seen_at":1720000123,"connected":true}
```

---

## 8. Chrome-pid liveness idiom

**`pool_owner_alive` — `lib/pool.sh:616`.** First liveness check (`lib/pool.sh:636`):
`[[ -d "/proc/$pid" ]] || return 1`. Established codebase primitive for "is pid
alive" (live PID has a `/proc/<pid>` dir; dead one does not). Comment rejects
`kill -0` as a TRAP (conflates ESRCH-dead with EPERM-alive-not-yours); `/proc`
never conflates (`lib/pool.sh:608-612`).

Doctor's chrome liveness = simple `[[ -d "/proc/$chrome_pid" ]]` (matches idiom +
contract "Is chrome_pid alive?"). Chrome's `comm` is truncated/generic
(TASK_COMM_LEN ≤15) → comm-matching NOT reliable for Chrome; use bare `/proc`
existence (owner comm/starttime checks are for the `pi` owner, not Chrome). Guard
provisional value (lease may have `chrome_pid=0`): treat 0/non-numeric as "not
alive". Keep `[[ ]]` in an `if`/compound (`&&`/`||` lists are errexit-exempt).
```bash
    [[ "$chrome_pid" =~ ^[0-9]+$ && "$chrome_pid" -gt 0 ]] || chrome_alive="no"
    [[ -d "/proc/$chrome_pid" ]] && chrome_alive="yes" || chrome_alive="no"
```

---

## 9. Port-listening idiom

**`pool_daemon_connected` — `lib/pool.sh:1689`** (`lib/pool.sh:1711`):
```bash
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || return 1
```
**`pool_find_free_port` — `lib/pool.sh:1376`** (`lib/pool.sh:1407`):
```bash
        if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
```
(Also `lib/pool.sh:1578` wait_cdp, `lib/pool.sh:2327` ensure_connected.) `-s`
silent, `-f` fail-on-HTTP-error; **rc 0 = HTTP 200 = Chrome listening/alive.**
SIDE-EFFECT-FREE (never launches anything — research §4).

Doctor's "Is port listening?" (inside `if`; recommend `--max-time 2` to bound a
hung connection — matches find_free_port):
```bash
    if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
        port_ok="yes"; else port_ok="no"; fi
```

---

## 10. notify-send optionality

**`_pool_alert` — `lib/pool.sh:2815`.** Guards notify-send (`lib/pool.sh:2824`):
```bash
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$summary" "$body" >/dev/null 2>&1 || true
    fi
```
**notify-send is OPTIONAL** — PRD §2.16 (`prd_snapshot.md:289`): "`notify-send`
(libnotify — exhaustion alerts; optional)." **IMPLICATION: a MISSING notify-send
must NOT be a FAIL.** When doctor verifies §2.16 deps, notify-send is the ONE
optional dep — absence is INFO/non-issue, not FAIL. (All others — btrfs, flock,
setsid, pgrep/pkill, cp --reflink, curl, jq, /proc, chrome, agent-browser — required.)

---

## 11. command -v as the dep-check idiom

**`command -v notify-send >/dev/null 2>&1`** (`lib/pool.sh:2824`) is the codebase's
existing PATH-presence idiom. Doctor is the FIRST SYSTEMATIC multi-dep PATH check
in the lib (status/reap/release don't check deps) → it ESTABLISHES the idiom:
```bash
    for dep in flock setsid pgrep pkill cp curl jq; do
        command -v "$dep" >/dev/null 2>&1 || report_missing
    done
```
(`command -v` in a `||` list is errexit-exempt under set -e.)

---

## 12. set -euo pipefail (line 18) — every set -e hazard doctor must guard

Strict-mode line is **`lib/pool.sh:18`** (NOT 23 — comments citing `:23` are stale).
Hazards for doctor:
- **`pool_lease_read` rc 1** (`lib/pool.sh:823`) → guard `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"`.
- **`pool_lease_field` rc 1** (`lib/pool.sh:876`) → guard with `if !` (doctor prefers one-fork jq mapfile, but if field is used, guard it).
- **bare `(( ))` statement** returns 1 when value is 0 → FATAL. Keep `(( ))` ONLY inside `if`/`elif` (status `lib/pool.sh:3634`, reap `lib/pool.sh:3754`). `$(( ))` expansion always safe.
- **`local x="$(…)"` is SC2155** → declare then assign (status `lib/pool.sh:3607-3611`).
- **`findmnt`/`curl`/`ls`/`cat` exit non-zero** → `|| true` (findmnt `lib/pool.sh:234`, `ls -A` `lib/pool.sh:268`) or `if`/`if !` (curl `lib/pool.sh:1407`).
- **`pool_lanes_list`** rc-0-always (`lib/pool.sh:967`) → bare `mapfile -t lanes < <(pool_lanes_list)` safe (process-sub exit not propagated anyway).
- **`pool_lane_is_stale`** tri-state rc 0/1/2 → MUST call inside `if` (not needed by doctor unless it reuses the verdict; doctor reconciles chrome/dir liveness directly).
- **`pool_config_init`/`pool_state_init`** rc-0-or-pool_die → no guard (misconfigured pool fails loudly — correct); doctor is NOT non-fatal here.

---

## 13. Parallel-execution context — append at the DYNAMIC current EOF

Sibling **P1.M7.T3.S1 `pool_admin_release`** has ALREADY LANDED (contrary to the
brief's "in progress"): banner `lib/pool.sh:3765`, function `lib/pool.sh:3830`,
EOF at line 3916. Verified by reading its PRP (`plan/.../P1M7T3S1/PRP.md:22-23,
56-58, 62-64`): release PRP says append "after the LANDED `pool_admin_reap`
(current EOF `lib/pool.sh:3762`)" and explicitly handles "if `pool_admin_release`
is ALREADY present → verify it in place (do NOT append a duplicate); if absent →
append it after the LAST admin function (verify the LIVE EOF)."

**CONCLUSION for doctor:** APPEND at the CURRENT EOF of `lib/pool.sh` (currently
**line 3916**, closing `}` of `pool_admin_release`), under its OWN banner
`# Admin CLI — doctor (P1.M7.T4.S1)`. The append site MUST be detected DYNAMICALLY
(tail of file), NOT hardcoded to 3762 or 3916 — the live EOF moves as siblings
land. Order among admin functions is irrelevant: each is self-contained, called
by name from the dispatcher (`case doctor) pool_admin_doctor "$@" ;;`).
Implementation-time: `tail -n 3 lib/pool.sh` to confirm the live EOF, then append.

---

## 14. Sibling task boundaries — doctor owns ONLY pool_admin_doctor()

doctor must NOT touch: **status** (M7.T1.S1, LANDED `lib/pool.sh:3594`);
**reap** (M7.T2.S1, LANDED `lib/pool.sh:3730`); **release** (M7.T3.S1, LANDED
`lib/pool.sh:3830`); **dispatcher binary `bin/agent-browser-pool` + `--help`**
(M7.T5.S1, FUTURE). doctor's docs are the FUNCTION HEADER doc-comment (Mode A);
the dispatcher wires `--help` and the `case doctor)` dispatch.

doctor owns **ONLY `pool_admin_doctor()`** appended to `lib/pool.sh`. `lib/pool.sh`
diff is append-only (banner + function); `bin/`, `.gitignore`, tests are M7.T5.S1's
concern (unless the doctor PRP separately defines a test task).

---

## 15. pool_lanes_list (rc 0 always; numeric; sorted -n)

**`pool_lanes_list` — `lib/pool.sh:967`.** Body (`lib/pool.sh:979-988`):
```bash
pool_lanes_list() {
    local f base n
    for f in "$POOL_LANES_DIR"/*.json; do
        [[ -f "$f" ]] || continue          # reject literal glob + subdirs + non-files
        base="${f##*/}"
        n="${base%.json}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue # numeric-only; stray editor artifacts skipped
        printf '%s\n' "$n"
    done | sort -n
    return 0
}
```
- **rc 0 always** (explicit `return 0`; `| sort -n` runs the loop in a subshell so
  the function's status is sort's, always 0 — pipefail-safe).
- **numeric `*.json` stems, sorted `-n`.** Empty output on no leases (no-match glob
  → `[[ -f ]] || continue` → 0 iterations → no output). Missing dir → no output.
- **Safe for** `mapfile -t lanes < <(pool_lanes_list)` (status idiom) AND
  `for n in $(pool_lanes_list)` (digits-only/newline-separated → unquoted word-split
  is intentional + safe; documented `lib/pool.sh:971`).

Doctor's reconciliation loop mirrors status: `mapfile -t lanes < <(pool_lanes_list)`
→ empty-pool `if (( ${#lanes[@]} == 0 ))` → `for lane in "${lanes[@]}"`.

---

## Doctor building-block summary (for the PRP author)

1. **Precondition:** `pool_config_init` + `pool_state_init` (rc-0-or-pool_die, no guard).
2. **Reconcile loop:** `mapfile -t lanes < <(pool_lanes_list)` → empty-pool guard (`(( ))` inside `if`) → per-lane `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"` → ONE-fork `mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")`.
3. **Per-lane checks (non-fatal):** chrome alive `[[ -d "/proc/$chrome_pid" ]]` (guard chrome_pid 0/non-numeric); port listening `curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1` (inside `if`); dir present `[[ -d "$ephemeral_dir" ]]`.
4. **Environment checks (replicate, NOT call — they pool_die):** btrfs `findmnt -nno FSTYPE -T ...` FAIL if `!= "btrfs"` (unless `POOL_ALLOW_SLOW_COPY=1`); master `[[ -d ... ]] && [[ -n "$(ls -A ... 2>/dev/null)" ]]` FAIL if false; deps `command -v` (flock/setsid/pgrep/pkill/cp/curl/jq); chrome name-or-path branch; `[[ -e /proc ]]`; **notify-send OPTIONAL → missing is NOT a FAIL.**
5. **Append:** OWN banner `# Admin CLI — doctor (P1.M7.T4.S1)` at DYNAMIC live EOF (currently 3916, after `pool_admin_release`). Detect via `tail`, do not hardcode.
6. **set -e guards:** `if !` on lease reads; `(( ))` only inside `if`; never `local x="$(…)"`; `|| true` on findmnt/curl/ls.
