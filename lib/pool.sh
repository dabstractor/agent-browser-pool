#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/pool.sh — shared library for the agent-browser-pool project.
#
# Sourced by:
#   - bin/agent-browser       (the transparent PATH-shadowing wrapper shim)
#   - bin/agent-browser-pool  (the admin CLI: status / reap / release / doctor)
#
# This file is meant to be SOURCED (`. lib/pool.sh` or `source lib/pool.sh`),
# NOT executed directly. It defines foundational utilities only.
#
# Requires: bash >= 4.2 (uses the printf '%(fmt)T' builtin). Hosts run bash 5.x.
# Strict mode: `set -euo pipefail` below propagates into every caller's shell by design.
#
# TODO(later subtasks): owner resolution, acquire/release, reap, copy, Chrome launch.
#                       This file currently provides ONLY the skeleton + die/log utilities.
set -euo pipefail

# Resolve the pool log path to an ABSOLUTE form (PRD §2.2: never use bare ~).
# Callers/tests may override with POOL_LOG_PATH; otherwise default under the
# runtime state dir (~/.local/state/agent-browser-pool/). Per PRD §2.11 the
# state dir is $AGENT_BROWSER_POOL_STATE.
_pool_log_path() {
    printf '%s\n' "${POOL_LOG_PATH:-${AGENT_BROWSER_POOL_STATE:-${HOME}/.local/state/agent-browser-pool}/pool.log}"
}

# pool_die MSG...
#   Print MSG to stderr and exit non-zero. The canonical error-exit helper.
pool_die() {
    printf '%s\n' "$*" >&2
    exit 1
}

# _pool_log MSG...
#   Append one "<ISO-8601 timestamp> MSG" line to the pool log (and to stderr).
#   Uses the builtin printf '%(...)T' (no `date` fork). Creates the log dir
#   if missing; if the log cannot be written, the line still goes to stderr.
_pool_log() {
    local msg ts log_path log_dir
    msg="${*:-}"
    # -1 == current time; ISO-8601 with numeric timezone, e.g. 2026-07-12T18:49:04-0400.
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    log_path="$(_pool_log_path)"
    log_dir="${log_path%/*}"
    if [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null; then
        printf '%s %s\n' "$ts" "$msg" >>"$log_path" || printf '%s %s\n' "$ts" "$msg" >&2
    else
        printf '%s %s\n' "$ts" "$msg" >&2
    fi
}

# _pool_config_canon_path INPUT
#   Canonicalize INPUT to an absolute path via `realpath -m` (--canonicalize-missing).
#   `-m` exits 0 even when intermediate components do not exist yet, which is REQUIRED
#   for the pool's default state/ephemeral/master/lanes/lock paths (they are created
#   later by P1.M1.T1.S3 / P1.M4.*). Bare `realpath` would exit 1 under `set -e`.
#   Fatal (pool_die) on empty input or an unresolvable path.
_pool_config_canon_path() {
    local in="$1" out
    [[ -n "$in" ]] || pool_die "_pool_config_canon_path: empty input"
    out="$(realpath -m -- "$in")" || pool_die "_pool_config_canon_path: cannot canonicalize: $in"
    printf '%s\n' "$out"
}

# _pool_config_require_uint NAME VALUE
#   Validate that VALUE is digits-only (a non-negative integer). Print VALUE on success;
#   pool_die with a NAME-tagged message otherwise. The regex test lives inside `[[ ]]`,
#   which is exempt from `set -e`, so a failed match is safe.
_pool_config_require_uint() {
    local name="$1" val="${2:-}"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        pool_die "$name must be a non-negative integer, got: '${val:-<unset>}'"
    fi
    printf '%s\n' "$val"
}

# _pool_config_bool VALUE
#   Normalize a tri-state env value to "1" (on) or "0" (off). ON when the value is
#   one of 1 / true / yes / on (case-insensitive); every other value (including "0",
#   "false", "no", "off", arbitrary strings, and unset) is OFF. Keeps boolean
#   semantics predictable and matches the README + `agent-browser-pool help` contract.
_pool_config_bool() {
    local v="${1:-}"
    v="${v,,}"                      # bash 4.0+ to-lower (no subshell, set -u safe)
    case "$v" in
        1|true|yes|on) printf '%s\n' 1 ;;
        *)             printf '%s\n' 0 ;;
    esac
}

# pool_config_init — resolve every configuration override to validated absolute globals.
#
# Enforces PRD §2.2 (never pass ~ to a subprocess) by canonicalizing every path via
# `realpath -m` against an already-absolute $POOL_HOME_DIR. Called once near the top
# of bin/agent-browser and bin/agent-browser-pool (and re-callable for tests).
#
# Configuration reference (env var → POOL_* global):
#   ENV VAR                        DEFAULT                                         GLOBAL                CATEGORY
#   AGENT_BROWSER_POOL_STATE       $HOME/.local/state/agent-browser-pool           POOL_STATE_DIR        path (may not exist)
#   AGENT_CHROME_MASTER            $HOME/.agent-chrome-profiles/master-profile     POOL_MASTER_DIR       path (may not exist)
#   AGENT_CHROME_EPHEMERAL_ROOT    $HOME/.agent-chrome-profiles/active             POOL_EPHEMERAL_ROOT   path (may not exist)
#   AGENT_BROWSER_REAL             $HOME/.local/bin/agent-browser                  POOL_REAL_BIN         path (may not exist)
#   AGENT_CHROME_BIN               google-chrome-stable                            POOL_CHROME_BIN       name-or-path
#   AGENT_CHROME_PORT_BASE         53420                                           POOL_PORT_BASE        uint
#   AGENT_CHROME_PORT_RANGE        1000                                            POOL_PORT_RANGE       uint (>0)
#   AGENT_BROWSER_POOL_WAIT        600                                             POOL_WAIT             uint
#   AGENT_CHROME_HEADLESS          (unset = windowed)                              POOL_HEADLESS         bool (1=headless)
#   AGENT_BROWSER_POOL_DISABLE     (unset = pooling active)                        POOL_DISABLE          bool (1=passthrough)
#   AGENT_CHROME_ALLOW_SLOW_COPY   (unset = refuse non-btrfs)                      POOL_ALLOW_SLOW_COPY  bool (1=allow real copy)
#
# Derived (no env var):
#   POOL_HOME_DIR    = realpath($HOME)                       (fatal if unset/unresolvable)
#   POOL_LANES_DIR   = $POOL_STATE_DIR/lanes
#   POOL_LOCK_FILE   = $POOL_STATE_DIR/acquire.lock
#
# Boolean rule: a var counts as ON only when its value is exactly "1". Any other value
# (including "true", "yes", "0") is OFF. This keeps semantics strict and predictable.
#
# Errors (any of these → pool_die, exit 1):
#   - $HOME unset/empty or unresolvable
#   - a numeric var is non-numeric
#   - POOL_PORT_RANGE <= 0
#
# Globals are MUTABLE (not readonly) so this function is RE-RUNNABLE: the test harness
# (P1.M9.T1.S1) sources lib/pool.sh once and calls pool_config_init repeatedly with
# different overrides per case in a single shell. There is intentionally NO
# "already-initialized" guard — every call re-resolves unconditionally.
# shellcheck disable=SC2034 # POOL_* globals are the exported contract of this lib;
# downstream subtasks (M1.T1.S3, M2–M7) and tests read them after pool_config_init runs.
pool_config_init() {
    # 1. $HOME first — every other default is anchored on the now-absolute POOL_HOME_DIR.
    local home_raw="${HOME:-}"
    [[ -n "$home_raw" ]] || pool_die "pool_config_init: \$HOME is unset or empty"
    local home_resolved
    home_resolved="$(realpath -- "$home_raw")" || pool_die "pool_config_init: cannot resolve \$HOME ($home_raw)"
    POOL_HOME_DIR="$home_resolved"; declare -g POOL_HOME_DIR

    # 2. Path globals (defaults anchored on POOL_HOME_DIR; realpath -m via the helper).
    local state_dir master_dir ephemeral_root real_bin
    state_dir="$(_pool_config_canon_path \
        "${AGENT_BROWSER_POOL_STATE:-$POOL_HOME_DIR/.local/state/agent-browser-pool}")"
    master_dir="$(_pool_config_canon_path \
        "${AGENT_CHROME_MASTER:-$POOL_HOME_DIR/.agent-chrome-profiles/master-profile}")"
    ephemeral_root="$(_pool_config_canon_path \
        "${AGENT_CHROME_EPHEMERAL_ROOT:-$POOL_HOME_DIR/.agent-chrome-profiles/active}")"
    real_bin="$(_pool_config_canon_path \
        "${AGENT_BROWSER_REAL:-$POOL_HOME_DIR/.local/bin/agent-browser}")"
    POOL_STATE_DIR="$state_dir"; declare -g POOL_STATE_DIR
    POOL_MASTER_DIR="$master_dir"; declare -g POOL_MASTER_DIR
    POOL_EPHEMERAL_ROOT="$ephemeral_root"; declare -g POOL_EPHEMERAL_ROOT
    POOL_REAL_BIN="$real_bin"; declare -g POOL_REAL_BIN

    # 3. CHROME_BIN name-or-path: a bare name (no '/') is resolved via PATH at launch
    #    time (M4.T2.S2), so store it as-is; an explicit path is canonicalized here.
    local chrome_in chrome_out
    chrome_in="${AGENT_CHROME_BIN:-google-chrome-stable}"
    if [[ "$chrome_in" == */* ]]; then
        chrome_out="$(_pool_config_canon_path "$chrome_in")"
    else
        chrome_out="$chrome_in"
    fi
    POOL_CHROME_BIN="$chrome_out"; declare -g POOL_CHROME_BIN

    # 4. Numerics — validate digits-only, THEN enforce PORT_RANGE > 0.
    local port_base port_range wait
    port_base="$(_pool_config_require_uint AGENT_CHROME_PORT_BASE "${AGENT_CHROME_PORT_BASE:-53420}")"
    port_range="$(_pool_config_require_uint AGENT_CHROME_PORT_RANGE "${AGENT_CHROME_PORT_RANGE:-1000}")"
    wait="$(_pool_config_require_uint AGENT_BROWSER_POOL_WAIT "${AGENT_BROWSER_POOL_WAIT:-600}")"
    (( port_range > 0 )) || pool_die "AGENT_CHROME_PORT_RANGE must be > 0 (got $port_range)"
    POOL_PORT_BASE="$port_base"; declare -g POOL_PORT_BASE
    POOL_PORT_RANGE="$port_range"; declare -g POOL_PORT_RANGE
    POOL_WAIT="$wait"; declare -g POOL_WAIT

    # 5. Booleans — 1/true/yes/on (case-insensitive) → on, else off.
    local headless disable allow_slow_copy
    headless="$(_pool_config_bool "${AGENT_CHROME_HEADLESS:-}")"
    disable="$(_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}")"
    allow_slow_copy="$(_pool_config_bool "${AGENT_CHROME_ALLOW_SLOW_COPY:-}")"
    POOL_HEADLESS="$headless"; declare -g POOL_HEADLESS
    POOL_DISABLE="$disable"; declare -g POOL_DISABLE
    POOL_ALLOW_SLOW_COPY="$allow_slow_copy"; declare -g POOL_ALLOW_SLOW_COPY

    # 6. Derived paths (after POOL_STATE_DIR is final).
    local lanes_dir lock_file
    lanes_dir="$(_pool_config_canon_path "$POOL_STATE_DIR/lanes")"
    lock_file="$(_pool_config_canon_path "$POOL_STATE_DIR/acquire.lock")"
    POOL_LANES_DIR="$lanes_dir"; declare -g POOL_LANES_DIR
    POOL_LOCK_FILE="$lock_file"; declare -g POOL_LOCK_FILE

    return 0
}

# pool_state_init — bring the on-disk pool state dir into existence (idempotent).
#
# Enforces PRD §2.11 / system_context §7: the state dir does NOT exist until first
# run (or until install.sh pre-creates it — M8.T1.S1). This function is the "first
# run" creation path so that a fresh checkout's very first acquire just works.
#
# Reads POOL_LANES_DIR and POOL_LOCK_FILE (frozen by pool_config_init). Idempotent:
# `mkdir -p` and `touch` are idempotent by design, so calling this on every acquire
# is cheap and correct — NO "if not exists" guard is needed. Silent on success
# (no _pool_log — prechecks must not flood the log on the happy path).
#
# Returns 0 on success; calls pool_die (exit 1) if mkdir/touch fails for a real
# filesystem reason (permission denied, read-only FS, etc.).
pool_state_init() {
    mkdir -p -- "$POOL_LANES_DIR" \
        || pool_die "pool_state_init: cannot create lanes dir: $POOL_LANES_DIR"
    touch -- "$POOL_LOCK_FILE" \
        || pool_die "pool_state_init: cannot create lock file: $POOL_LOCK_FILE"
    return 0
}

# pool_check_btrfs — refuse a non-btrfs ephemeral root unless the escape hatch is set.
#
# Enforces PRD §2.7 and §2.14: a non-btrfs filesystem at POOL_EPHEMERAL_ROOT would
# silently trigger a catastrophic 4.8 GB real copy per acquire (the CoW `cp
# --reflink=always` would fall back to a full copy). Refuse loudly unless
# POOL_ALLOW_SLOW_COPY=1 (normalized from AGENT_CHROME_ALLOW_SLOW_COPY by S2).
#
# CRITICAL GOTCHA: uses `findmnt -T` (the --target flag is MANDATORY). A bare
# `findmnt -nno FSTYPE "$dir"` (NO -T) matches the positional arg against SOURCE
# (a device), not the mount tree, and exits 1 on this host EVEN ON BTRFS — verified
# 2026-07-12. The architecture doc external_deps.md §3.2 example omits -T and is
# BROKEN; do not copy it. Always: `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"`.
#
# findmnt legitimately exits 1 when the path is missing or not on a btrfs mount; the
# `|| true` neutralizes that so set -e (propagated by S1) does not abort the capture.
# An empty FSTYPE (missing path / findmnt failure) is treated as "not btrfs".
#
# Reads POOL_EPHEMERAL_ROOT and POOL_ALLOW_SLOW_COPY (frozen by pool_config_init).
# Echoes the detected FSTYPE on success (handy for callers + tests). Returns 0 when
# btrfs OR slow-copy allowed; calls pool_die otherwise.
pool_check_btrfs() {
    local fstype
    # `|| true` makes the command-substitution always succeed; fstype becomes "" on
    # failure (missing path / not found), which the [[ ]] test below handles.
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"

    if [[ "$fstype" == "btrfs" ]]; then
        printf '%s\n' "$fstype"
        return 0
    fi

    # Not btrfs — including the empty case (path missing or findmnt failed).
    if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
        printf '%s\n' "${fstype:-unknown}"
        return 0
    fi

    pool_die "pool_check_btrfs: $POOL_EPHEMERAL_ROOT is not on btrfs" \
             "(detected: '${fstype:-<empty/missing>})." \
             "A real copy of the 4.8 GB master per acquire would be catastrophic." \
             "Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point" \
             "AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount (the path may not exist)."
}

# pool_check_master — verify the master template exists and is populated.
#
# Enforces PRD §2.7 (the master is read-only, created once, never launched/mutated)
# and §2.14 (a missing master must fail with the EXACT cp command to bootstrap it).
#
# Tests existence (-d) and non-emptiness (ls -A) ONLY — do NOT stat/du the 4.8 GB
# master (slow). "Non-empty" is sufficient to catch a stray `mkdir` that created
# the dir without copying a profile into it.
#
# Reads POOL_MASTER_DIR (frozen by pool_config_init). Returns 0 when the dir exists
# and is non-empty; calls pool_die with an actionable copy-paste cp command
# otherwise (covering BOTH missing AND empty dir).
pool_check_master() {
    if [[ -d "$POOL_MASTER_DIR" ]] \
       && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
        return 0
    fi

    pool_die "pool_check_master: master template missing or empty:" \
             "$POOL_MASTER_DIR" \
             "Create it ONCE by copying a configured Chrome profile, e.g.:" \
             "  cp -a --reflink=always <your-chrome-profile> \"$POOL_MASTER_DIR\"" \
             "(see PRD §1.2 — the master is created once, never launched/mutated.)"
}

# _pool_atomic_write FILEPATH [CONTENT]
#   Write CONTENT to FILEPATH atomically: write to FILEPATH.tmp (same directory
#   → same filesystem → atomic rename) then `mv` it over FILEPATH. A concurrent
#   reader sees old-or-new, never a half-written file (PRD §2.19, key_findings
#   FINDING 7).
#
#   GOTCHA (same-FS atomicity): rename(2) is atomic ONLY when src and dst are on
#   the SAME filesystem. The .tmp is "${filepath}.tmp" (same DIRECTORY as the
#   target) to GUARANTEE same-FS. NEVER use mktemp (puts the file in /tmp, a
#   different mount → cross-FS copy+unlink, NON-atomic).
#
#   GOTCHA (no fsync / crash-durability): we do NOT fsync (no bash builtin;
#   coreutils `sync` is global and too slow for a per-lease primitive). A
#   power-loss crash between the write and the rename leaves the OLD target
#   intact plus an orphan .tmp — acceptable for a short-lived pool lease (the
#   reaper, M5.T3, treats a stale lease as reaper-able anyway). Atomicity (no
#   torn reads) is what matters here, not crash-durability.
#
#   GOTCHA (orphan .tmp cleanup): if the process is killed between the printf
#   and the mv, an orphan <filepath>.tmp remains. This function removes only
#   ITS OWN partial .tmp on a write failure; sweeping other stale .tmp files is
#   a caller/startup (install.sh / doctor) concern, NOT implemented here.
#
#   Args:  $1=filepath, $2=content (defaults to "" if unset).
#   Returns 0 on success. Calls pool_die (exit 1) if the tmp write or the rename
#   fails — never silently leaves the target unchanged.
_pool_atomic_write() {
    local filepath="$1" content="${2:-}"
    local tmp
    tmp="${filepath}.tmp"
    # printf '%s' preserves the EXACT bytes (no added newline) so file bytes ==
    # content arg. The `if !` makes a write failure a controlled branch so the
    # cleanup rm runs before pool_die exits.
    if ! printf '%s' "$content" >"$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        pool_die "_pool_atomic_write: cannot write tmp file: $tmp"
    fi
    # mv -f overwrites without prompting (suppresses any interactive alias); --
    # guards paths starting with '-'. `||` is set -e safe.
    mv -f -- "$tmp" "$filepath" \
        || pool_die "_pool_atomic_write: cannot rename tmp into place: $tmp -> $filepath"
}

# _pool_json_valid FILEPATH
#   Predicate: is FILEPATH syntactically valid JSON? Returns 0 (valid) / 1
#   (invalid, missing, or unreadable). NEVER calls pool_die — it is a boolean.
#
#   NOTE (syntax vs schema): `jq empty` exits 0 for valid objects/arrays AND for
#   bare scalars (123, "hi") AND for empty files (all "valid JSON per RFC 8259");
#   non-zero (2 for missing, 5 for malformed, verified jq 1.8.2) for malformed /
#   missing / unreadable. So this is a SYNTAX check, NOT a schema check. The
#   stricter "is this a lease OBJECT with required fields?" is M3.T1.S2's job.
#
#   Args:  $1=filepath.
#   Returns 0 if `jq empty` succeeds, 1 otherwise. Never exits the process.
_pool_json_valid() {
    local filepath="$1"
    # The `if` makes jq's non-zero exit a clean branch (NOT a set -e abort).
    # stderr → /dev/null so malformed-JSON parse errors don't leak to the user.
    if jq empty "$filepath" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# _pool_now
#   Echo the current Unix epoch (seconds since 1970) as digits. Used for lease
#   acquired_at / last_seen_at (PRD §2.8). `date +%s` is a GNU coreutils
#   extension, guaranteed on this host; exits 0 reliably (safe under set -e).
#   Matches the idiom in key_findings.md FINDING 7 and external_deps.md.
#
#   Args:  none.
#   Echoes <digits>, exit 0.
_pool_now() {
    date '+%s'
}

# _pool_age_str TIMESTAMP
#   Echo a human-readable age for TIMESTAMP (epoch seconds): largest whole unit
#   — Ns (<60), Nm (<3600), Nh (<86400), Nd (else). A future/negative diff
#   (clock skew, bogus ts) clamps to "0s". Used by admin `status` (PRD §2.12,
#   M7.T1.S1).
#
#   GOTCHA (set -e + arithmetic): a bare `(( expr ))` as a STATEMENT returns
#   exit status 1 when the result is 0 — FATAL under set -e. EVERY `(( ))` here
#   is inside `if`/`elif` (exempt from errexit). The `$(( ))` EXPANSION form is
#   always safe.
#
#   Args:  $1=timestamp (epoch seconds).
#   Echoes Ns/Nm/Nh/Nd (negative→"0s"), exit 0.
_pool_age_str() {
    local ts="$1"
    local now diff
    now="$(date '+%s')"          # two-statement (SC2155); date +%s always exits 0
    diff=$(( now - ts ))         # $(( )) EXPANSION is always set -e safe
    if (( diff < 0 )); then      # clamp future/negative to 0
        diff=0
    fi
    if (( diff < 60 )); then
        printf '%ss\n' "$diff"
    elif (( diff < 3600 )); then
        printf '%sm\n' "$(( diff / 60 ))"
    elif (( diff < 86400 )); then
        printf '%sh\n' "$(( diff / 3600 ))"
    else
        printf '%sd\n' "$(( diff / 86400 ))"
    fi
}

# =============================================================================
# Owner resolution (P1.M2.T1.S1 + P1.M2.T1.S2)
# =============================================================================
# Resolves WHICH pi process owns the current tool-call shell, by walking the
# ppid chain from $$ up to the first process whose /proc/<pid>/comm == 'pi'
# (PRD §1.1 / §2.4 step 1). Populates the four POOL_OWNER_* globals consumed by
# every downstream lease query (M3.T2.S1 find_my_lease) and the wrapper
# lifecycle (M6.T3 passthrough gate). Also implements the TEST-HOOK overrides
# of PRD §2.18 / key_findings FINDING 8 (AGENT_BROWSER_POOL_OWNER_PID +
# _OWNER_STARTTIME) so the test harness (M9.T1.S1) can simulate distinct agents
# from distinct subshell PIDs WITHOUT real pi ancestor processes.
#
# P1.M2.T1.S2 adds the CANONICAL starttime extractor _pool_get_starttime()
# below and reduces S1's _pool_owner_starttime() to a one-line delegating
# wrapper so the codebase holds exactly ONE starttime parser (no duplication).

_pool_get_starttime() {
    # _pool_get_starttime PID
    #
    # THE CANONICAL starttime extractor for the pool. Echo the process starttime
    # (/proc/<pid>/stat field 22, clock ticks since boot; CLK_TCK=100 on this
    # host) for PID. Returns 0 + echoes a digits-only string on success; returns
    # 1 (NOT fatal, echoes nothing) if PID is empty/non-numeric, or
    # /proc/<pid>/stat is absent/unreadable, or the parsed value is not an integer.
    #
    # CONSUMERS:
    #   - pool_owner_resolve()  → records POOL_OWNER_STARTTIME (PRD §2.4 step 1, §2.8),
    #     via the _pool_owner_starttime() wrapper below.
    #   - is_owner_alive() (P1.M2.T2.S1) → reads a lease owner's CURRENT starttime
    #     and compares to the stored value; a mismatch means the PID was recycled
    #     (PRD §2.8, §2.19). The (pid, starttime) pair is the anti-recycling key.
    #
    # WHY THE PRD §2.19 "NF-19" FORMULA IS WRONG (key_findings FINDING 1,
    # system_context §6.1, host-verified 2026-07-12):
    #   /proc/<pid>/stat field 2 is comm, wrapped in parens:  "<pid> (<comm>) <state> ..."
    #   comm MAY contain spaces (e.g. "(Chrome Helper)"), shifting every later field,
    #   so a naive left-to-right `awk '{print $22}'` is unsafe in general. The PRD
    #   tried to read "from the right": field 22 from the start == index NF-19. That
    #   formula assumes a FIXED total field count of 41. On this host the real count
    #   is 52, so NF-19 == field 33 — which is vsize (≈ 4096), NOT starttime. The
    #   total count is NOT fixed across kernel versions / process states, so any
    #   NF-based offset is inherently fragile. Verified: `awk '{print $(NF-19)}'
    #   /proc/self/stat` = 4096 (WRONG) vs the correct field-22 starttime ≈ 8283368.
    #
    # THE CORRECT ROBUST METHOD:
    #   Strip "pid (comm)" by deleting everything up to AND INCLUDING the LAST ')'
    #   (greedy), collapsing any spaces inside comm. That removes exactly fields 1
    #   (pid) + 2 (comm), so overall field N == field (N-2) of the remainder.
    #   starttime (field 22) therefore falls at field 20 of the remainder (22-2=20).
    #   Pure bash (preferred — no extra fork; we already hold the line in a var):
    #       after="${stat_line##*)}"        # GREEDY longest prefix up to last ')'
    #       start="$(awk '{print $20}' <<<"$after")"
    #   Shell-pipeline equivalent (what the PRD/arch docs cite — IDENTICAL result):
    #       sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'
    #   Verified agreement (comm='pi'/'bash'/'cat'/'head', no spaces): all three
    #   methods yield the same starttime.
    local pid="${1:-}"
    local stat_line after start
    # Input validation: a non-numeric / empty PID is a clean "no value" (return 1),
    # never fatal. `[[ =~ ]]` inside `if` is errexit-exempt.
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    # `cat ... 2>/dev/null || true`: a vanished / permission-denied /proc entry is a
    # clean "process dead" signal (return 1), NOT a set -e abort. SC2155: two-stmt.
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || true
    if [[ -z "$stat_line" ]]; then
        return 1
    fi
    # Drop "pid (comm)" — GREEDY strip to & incl. the LAST ')'.
    after="${stat_line##*)}"
    start="$(awk '{print $20}' <<<"$after")"   # field 22 overall == field 20 here
    # Output validation: guard a truncated/garbled stat line. Return 1 (no echo),
    # never fatal.
    if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$start"
}

_pool_owner_starttime() {
    # Thin delegating wrapper preserved for S1's pool_owner_resolve() call sites.
    # The canonical parser is _pool_get_starttime() above (P1.M2.T1.S2); keeping
    # this alias means there is exactly ONE starttime parser in the codebase while
    # pool_owner_resolve's existing `_pool_owner_starttime "$ovr_pid"` calls stay
    # unchanged. I/O contract unchanged: echo digits/return 0, or return 1
    # (no echo), never fatal.
    _pool_get_starttime "$@"
}

pool_owner_resolve() {
    # Resolve the owning pi process and populate POOL_OWNER_* globals.
    # Implements PRD §2.4 step 1 (resolve OWNER), §1.1 (walk ppid to comm=='pi'),
    # and the test-hook overrides of PRD §2.18 / key_findings FINDING 8.
    #
    # TEST-HOOK env vars (TEST-ONLY, PRD §2.18 / key_findings FINDING 8 — narrowly
    # scoped, NOT exposed in user-facing docs):
    #   AGENT_BROWSER_POOL_OWNER_PID        — simulate a specific owner PID.
    #   AGENT_BROWSER_POOL_OWNER_STARTTIME  — simulate the owner starttime.
    #
    # LOGIC: (1) TEST MODE if AGENT_BROWSER_POOL_OWNER_PID set+numeric → use
    # directly; (2) REAL MODE walk ppid from $$ to comm=='pi'; (3) no pi ancestor
    # → PID=0 (passthrough). NEVER fatal. Globals MUTABLE → re-runnable. One
    # _pool_log line per call (never inside the walk loop — this runs on every
    # agent-browser invocation).

    # Reset globals to defaults every call (re-runnable contract).
    POOL_OWNER_PID="0"; POOL_OWNER_COMM=""; POOL_OWNER_STARTTIME=""; POOL_OWNER_CWD=""
    declare -g POOL_OWNER_PID POOL_OWNER_COMM POOL_OWNER_STARTTIME POOL_OWNER_CWD

    # --- 1. TEST MODE: env-var override -------------------------------------
    if [[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]; then
        local ovr_pid="$AGENT_BROWSER_POOL_OWNER_PID"
        if [[ ! "$ovr_pid" =~ ^[0-9]+$ ]]; then
            _pool_log "pool_owner_resolve: invalid AGENT_BROWSER_POOL_OWNER_PID='$ovr_pid' (ignored)"
            return 0
        fi
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM
        if [[ -n "${AGENT_BROWSER_POOL_OWNER_STARTTIME:-}" ]]; then
            POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME"; declare -g POOL_OWNER_STARTTIME
        else
            local st=""
            st="$(_pool_owner_starttime "$ovr_pid" 2>/dev/null)" || true
            if [[ -n "$st" ]]; then
                POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
            fi
        fi
        local cwd=""
        cwd="$(readlink "/proc/$ovr_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: TEST MODE owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}"
        return 0
    fi

    # --- 2. REAL MODE: walk ppid chain from $$ ------------------------------
    local pid="$$"
    local ppid="" comm="" line="" found_pid="" steps=0
    while (( steps++ < 128 )); do
        comm=""
        IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || true
        if [[ "$comm" == "pi" ]]; then
            found_pid="$pid"
            break
        fi
        ppid=""
        if [[ -r "/proc/$pid/status" ]]; then
            while IFS= read -r line; do
                if [[ "$line" == PPid:* ]]; then
                    ppid="${line#PPid:}"
                    ppid="${ppid//[[:space:]]/}"
                    break
                fi
            done < "/proc/$pid/status"
        fi
        if [[ ! "$ppid" =~ ^[0-9]+$ ]]; then break; fi
        if (( ppid == 1 ));  then break; fi
        if (( ppid == 0 ));  then break; fi
        if (( ppid == pid )); then break; fi
        pid="$ppid"
    done

    # --- 3. RESULT ----------------------------------------------------------
    if [[ -n "$found_pid" ]]; then
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM
        local st=""
        st="$(_pool_owner_starttime "$found_pid" 2>/dev/null)" || true
        if [[ -n "$st" ]]; then
            POOL_OWNER_STARTTIME="$st"; declare -g POOL_OWNER_STARTTIME
        fi
        local cwd=""
        cwd="$(readlink "/proc/$found_pid/cwd" 2>/dev/null)" || true
        if [[ -n "$cwd" ]]; then
            POOL_OWNER_CWD="$cwd"; declare -g POOL_OWNER_CWD
        fi
        _pool_log "pool_owner_resolve: owner pid=$POOL_OWNER_PID" \
                  "comm=$POOL_OWNER_COMM starttime=${POOL_OWNER_STARTTIME:-<none>}" \
                  "cwd=${POOL_OWNER_CWD:-<unknown>}"
        return 0
    fi

    _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"
    return 0
}

# =============================================================================
# Owner liveness & identity verification (P1.M2.T2.S1)
# =============================================================================

# pool_owner_alive PID EXPECTED_STARTTIME [EXPECTED_COMM]
#
# Predicate: is the lease owner PID still alive AND still the SAME process that
# took the lease? Returns 0 (alive + identity matches) or 1 (dead / recycled /
# unverifiable). NEVER fatal — never calls pool_die, never writes, never logs
# (leaf predicate; callers log the decision).
#
# WHY THREE CHECKS (PRD §2.5 owner-liveness-driven release, §2.14 failure modes,
# key_findings FINDING 1, research note §2/§4):
#   PID recycling is real: after a pi crash, the kernel hands that PID number to
#   an UNRELATED process. pid alone is NOT identity. The (pid, comm, starttime)
#   triple IS — starttime (field 22 of /proc/<pid>/stat, clock ticks since boot)
#   is unique per process invocation and strictly increases for a recycled PID.
#   This triple is the industry-standard identity check (systemd, psmisc,
#   procps-ng; research note §5).
#
# DECISION LADDER (order matters — cheapest/most-likely-fail first; research §4.4):
#   a. /proc/<pid> missing                → dead              → return 1
#   b. /proc/<pid>/comm != EXPECTED_COMM  → recycled (non-pi) → return 1
#   c. starttime != EXPECTED_STARTTIME    → recycled (new pi) → return 1
#   d. all pass                           → alive + same      → return 0
#
# GOTCHA — kill -0 is a TRAP (research note §3, kill(2)): `kill -0 $pid` returns
# 1 for BOTH ESRCH (dead) and EPERM (alive but not yours) — the shell cannot
# tell them apart, so a live foreign process looks dead. We use /proc/<pid>
# existence, which never conflates them. /proc is also needed for comm/stat, so
# one source of truth.
#
# GOTCHA — comm truncation (research note §1.2): /proc/<pid>/comm is at most 15
# chars (TASK_COMM_LEN=16). 'pi' is 2 chars → zero risk. Do not pad/trim.
#
# GOTCHA — TOCTOU (research note §4): a process can die between checks. Each
# /proc read is independently guarded (|| return 1), so a mid-function death
# yields return 1 (stale) — SAFE. The caller must be idempotent (reaper re-runs
# on next acquire). Even return 0 only proves liveness at that instant.
pool_owner_alive() {
    local pid="${1:-}"
    local expected_starttime="${2:-}"
    local expected_comm="${3:-pi}"
    local comm actual_starttime

    # Input validation: pid must be a non-negative integer. A non-numeric/empty
    # pid is not a verifiable owner → return 1. `[[ =~ ]] || return 1` is safe
    # under set -e (the `||` list is errexit-exempt).
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    # (a) Liveness: /proc/<pid> must exist (it is a directory for live PIDs;
    # verified -d/-e both true on host). A dead process has no /proc entry.
    [[ -d "/proc/$pid" ]] || return 1

    # (b) Image-name first pass: read /proc/<pid>/comm. `$(cat ...)` strips the
    # trailing newline (bash Command Substitution), so comm is the bare name
    # with no '\n' — no manual strip needed. If the read fails (process died
    # mid-function → TOCTOU, or EACCES), treat as dead. PLAIN assignment (not
    # `local x=$(...)`) so cat's exit status is preserved → `|| return 1` works.
    # Quote the RHS of [[ == ]] so a glob-y expected_comm can't pattern-match.
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
    [[ "$comm" == "$expected_comm" ]] || return 1

    # (c) Authoritative identity token: starttime via the canonical extractor
    # _pool_get_starttime (P1.M2.T1.S2). It echoes digits/return 0 on success,
    # return 1 (no echo, never fatal) on failure (process died, garbled stat).
    # Extraction failure → not verifiably alive → return 1.
    actual_starttime="$(_pool_get_starttime "$pid" 2>/dev/null)" || return 1
    [[ "$actual_starttime" == "$expected_starttime" ]] || return 1

    # (d) Alive and the same process invocation that took the lease.
    return 0
}

# =============================================================================
# Lease management — JSON write & atomic update (P1.M3.T1.S1)
# =============================================================================

# pool_lease_write LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM \
#                  OWNER_STARTTIME OWNER_CWD CHROME_PID CHROME_PGID CONNECTED
#
# Build the FULL lease object (PRD §2.8 schema) with jq -n and publish it
# atomically to $POOL_LANES_DIR/<LANE>.json. version is fixed at 1;
# acquired_at and last_seen_at are both stamped to $(_pool_now) (captured ONCE,
# so they match). Composes _pool_atomic_write (M1.T2.S1) for the tmp+mv publish.
#
# CONSUMERS: M5.T1.S1 acquire (provisional claim: PORT/CHROME_PID/CHROME_PGID=0,
# CONNECTED=false) ; the read/query layer (M3.T1.S2 / M3.T2.*) reads what this
# writes.
#
# TYPING (research §1): numbers + the boolean + timestamps use --argjson; strings
# (ephemeral_dir, session, owner.comm, owner.cwd) use --arg. The #1 lease bug is
# --arg on a number → a quoted string; --argjson keeps the type.
#
# GOTCHA — connected must be a JSON BOOLEAN: --argjson connected 1 would store the
# NUMBER 1, not true. Validate connected ∈ {true,false} explicitly.
# GOTCHA — non-numeric numerics make the jq build fail (exit 1 inside $(…)) → the
# `|| pool_die` fires.
# GOTCHA — $(jq …) strips jq's trailing newline, so the file is newline-less
# (harmless; every JSON consumer handles it). _pool_atomic_write's printf '%s'
# preserves the exact bytes.
# GOTCHA — a jq BUILD failure happens BEFORE _pool_atomic_write, so the existing
# lease (if any) is never corrupted by a failed build.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR) and pool_state_init (to
# create the dir) must have run. A missing dir → _pool_atomic_write pool_die.
pool_lease_write() {
    local lane="${1:-}"
    local ephemeral_dir="${2:-}"
    local port="${3:-}"
    local session="${4:-}"
    local owner_pid="${5:-}"
    local owner_comm="${6:-}"
    local owner_starttime="${7:-}"
    local owner_cwd="${8:-}"
    local chrome_pid="${9:-}"
    local chrome_pgid="${10:-}"
    local connected="${11:-}"
    local now json lease_file

    # Validate lane (the index) and connected (must be a JSON boolean literal).
    # `[[ ]] || pool_die` is errexit-exempt.
    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_lease_write: lane must be a non-negative integer, got: '$lane'"
    [[ "$connected" == "true" || "$connected" == "false" ]] \
        || pool_die "pool_lease_write: connected must be 'true' or 'false' (a JSON boolean), got: '$connected'"

    # One timestamp capture → acquired_at == last_seen_at for a fresh lease.
    now="$(_pool_now)"

    # Build the JSON. Every field name + value is jq DATA (--arg/--argjson); the
    # filter is a fixed literal → injection-safe. PLAIN assignment (not
    # `local x=$(…)`) so jq's exit status reaches `|| pool_die` (SC2155).
    json="$(jq -n \
        --argjson version 1 \
        --argjson lane "$lane" \
        --arg ephemeral_dir "$ephemeral_dir" \
        --argjson port "$port" \
        --arg session "$session" \
        --argjson owner_pid "$owner_pid" \
        --arg owner_comm "$owner_comm" \
        --argjson owner_starttime "$owner_starttime" \
        --arg owner_cwd "$owner_cwd" \
        --argjson chrome_pid "$chrome_pid" \
        --argjson chrome_pgid "$chrome_pgid" \
        --argjson acquired_at "$now" \
        --argjson last_seen_at "$now" \
        --argjson connected "$connected" \
        '{version:$version, lane:$lane, ephemeral_dir:$ephemeral_dir, port:$port,
          session:$session,
          owner:{pid:$owner_pid,comm:$owner_comm,starttime:$owner_starttime,cwd:$owner_cwd},
          chrome_pid:$chrome_pid, chrome_pgid:$chrome_pgid,
          acquired_at:$acquired_at, last_seen_at:$last_seen_at, connected:$connected}')" \
        || pool_die "pool_lease_write: failed to build lease JSON for lane $lane" \
                    "(check numeric field values: port=$port owner_pid=$owner_pid" \
                    "owner_starttime=$owner_starttime chrome_pid=$chrome_pid" \
                    "chrome_pgid=$chrome_pgid)"

    # Atomic publish (tmp in same dir → same FS → atomic rename). pool_die on failure.
    lease_file="$POOL_LANES_DIR/$lane.json"
    _pool_atomic_write "$lease_file" "$json"
}

# pool_lease_update LANE FIELD VALUE
#
# Read the EXISTING lease for LANE, set the top-level FIELD to VALUE (spliced as
# raw JSON via --argjson), and re-publish atomically. Sibling fields and the
# `owner` sub-object are PRESERVED. Used by the post-lock boot (M5.T1.S2:
# port/chrome_pid/chrome_pgid/connected) and the heartbeat (M5.T1.S3:
# last_seen_at).
#
# FIELD is TOP-LEVEL only (regex ^[a-zA-Z_][a-zA-Z0-9_]*$); dotted `owner.*`
# updates are NOT supported (owner is written once at acquire, never mutated).
#
# VALUE typing: it is parsed as JSON by --argjson, so 53427 → number,
# true/false → boolean, '"str"' → string (caller must quote). An empty/non-JSON
# value makes jq exit 2 → pool_die.
#
# INJECTION SAFETY (research §2): the filter is the fixed literal `.[$f] = $v`;
# FIELD and VALUE enter jq as DATA (--arg/--argjson), never spliced into the
# program. The field regex is defense-in-depth.
# GOTCHA — a missing or corrupted lease is a pool_die (update assumes a valid
# lease just written by THIS process under flock; corruption is exceptional).
# GOTCHA — the mutate is computed BEFORE _pool_atomic_write, so a jq failure never
# touches the existing lease.
# PRECONDITION: pool_config_init + pool_state_init; the lease must already exist
# (written by pool_lease_write).
pool_lease_update() {
    local lane="${1:-}"
    local field="${2:-}"
    local value="${3:-}"
    local lease_file updated

    # Validate lane + field name (safe identifier — defense-in-depth even though
    # .[$f] is already injection-safe).
    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_lease_update: lane must be a non-negative integer, got: '$lane'"
    [[ "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
        || pool_die "pool_lease_update: invalid field name: '$field' (top-level identifier only)"

    lease_file="$POOL_LANES_DIR/$lane.json"

    # The lease must already exist.
    [[ -f "$lease_file" ]] \
        || pool_die "pool_lease_update: lease file does not exist: $lease_file"

    # Syntax pre-check for a clear error (composes the M1.T2.S1 predicate).
    if ! _pool_json_valid "$lease_file"; then
        pool_die "pool_lease_update: lease file is not valid JSON: $lease_file"
    fi

    # Mutate one top-level field; preserve siblings + owner. PLAIN assignment so
    # jq's exit status reaches `|| pool_die` (SC2155). A non-JSON value (empty,
    # unquoted text) → jq --argjson exit 2 → pool_die.
    updated="$(jq --argjson v "$value" --arg f "$field" '.[$f] = $v' "$lease_file")" \
        || pool_die "pool_lease_update: failed to update lane $lane field '$field'" \
                    "(value must be valid JSON: number, true/false, or a quoted string;" \
                    "got: '$value')"

    # Atomic re-publish.
    _pool_atomic_write "$lease_file" "$updated"
}

# -----------------------------------------------------------------------------
# Lease management — JSON read & validation (P1.M3.T1.S2)
# -----------------------------------------------------------------------------

# pool_lease_read LANE
#
# Read $POOL_LANES_DIR/<LANE>.json and echo the RAW JSON on success (return 0).
# If the file does not exist → return 1 (a lane with no lease is simply unleased —
# a NORMAL state, NOT an error). If the file exists but is invalid JSON → log a
# warning via _pool_log and return 1 (defensive coding against a crash-mid-write;
# rare under S1's atomic writes). NEVER calls pool_die — read functions are
# non-fatal (they run inside enumeration/reaper loops).
#
# CONSUMERS: M3.T2.S1 find_my_lease / M5.T3.S1 reap_stale / M5.T3.S2 reuse_orphan
# (full-lease reads); M7.T1.S1 status / M7.T4.S1 doctor.
#
# GOTCHA — the file is newline-less (S1's _pool_atomic_write uses printf '%s');
# `cat` reproduces the exact bytes. Consumers pipe to jq (handles no-newline) or
# capture via $() (strips trailing newline). Do NOT re-add a newline.
# GOTCHA — CALLERS under set -e must guard the call:
#   `rc=0; out="$(pool_lease_read "$lane")" || rc=$?`  or  `if out="$(…)"; then`.
#   A bare `out="$(pool_lease_read 99)"` ABORTS the caller when this returns 1.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR). The dir need not exist — a
# missing dir surfaces as file-not-found → return 1 (correct: "no lease").
pool_lease_read() {
    local lane="${1:-}"
    local file

    # Validate lane (path-traversal defense + catches caller bugs). Read functions
    # RETURN 1 on a bad lane (never pool_die) — a bogus lane simply "has no lease".
    # `[[ ]] || return 1` is errexit-exempt.
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    file="$POOL_LANES_DIR/$lane.json"

    # Missing file → normal "unleased" state → return 1 (silent).
    [[ -f "$file" ]] || return 1

    # Corrupt JSON → log ONE warning (CONTRACT) + return 1 (silent stdout).
    # _pool_json_valid is the M1.T2.S1 predicate (jq empty); never fatal.
    if ! _pool_json_valid "$file"; then
        _pool_log "pool_lease_read: corrupt lease (invalid JSON) for lane $lane: $file"
        return 1
    fi

    # Echo the raw bytes. `|| return 1` handles a TOCTOU deletion (rare). After the
    # validity check cat normally succeeds.
    cat "$file" || return 1
    return 0
}

# pool_lease_field LANE FIELD
#
# Read one field from $POOL_LANES_DIR/<LANE>.json and echo its raw value (return 0).
# FIELD is a jq-style DOTTED PATH — top-level (port, connected, last_seen_at,
# chrome_pid, …) OR nested (owner.pid, owner.starttime, owner.comm, owner.cwd).
# "Helper for quick access" (CONTRACT). Silent on missing file / corrupt JSON /
# invalid lane / empty field (return 1, no output). A field PATH that does not
# exist in the object echoes `null` and returns 0 (standard jq getpath behavior).
#
# CONSUMERS: M3.T2.S1 find_my_lease (owner.pid, owner.starttime — NESTED);
# M3.T2.S3 is_lane_stale (last_seen_at, chrome_pid); M5.T3.S2 reuse_orphan
# (owner.pid, chrome_pid, port, connected, ephemeral_dir); M7.T1.S1 status
# (lane, port, session, chrome_pid, acquired_at, connected).
#
# INJECTION SAFETY (research §3b): the filter is the fixed literal
# `getpath($f|split("."))`; FIELD enters jq as DATA (--arg = a JSON string used as
# a dict key), NEVER spliced into the program. Supports nested paths in one shot.
# NEVER `jq -r ".${field}"`.
# GOTCHA — NO `jq -e` (research §3a): -e exits 1 on `false` as well as `null`,
# which would break reads of the boolean `connected`. Plain `jq -r` guarantees a
# present field ALWAYS echoes + returns 0 (even when the value is false).
# GOTCHA — missing field → echoes "null" (exit 0). Callers query schema-defined
# fields (PRD §2.8), so this is harmless. It is the faithful "jq -r .field" behavior.
# GOTCHA — silent on corrupt (no log); callers wanting diagnostics use
# pool_lease_read (which logs). This keeps field a lean "quick access" helper.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR).
pool_lease_field() {
    local lane="${1:-}"
    local field="${2:-}"
    local file

    # Validate lane (path-traversal defense) + field is non-empty.
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$field" ]] || return 1

    file="$POOL_LANES_DIR/$lane.json"

    # Missing file → return 1 (silent). Corrupt JSON → return 1 (silent).
    [[ -f "$file" ]] || return 1
    _pool_json_valid "$file" || return 1

    # Injection-safe nested read. `|| return 1` handles a TOCTOU race (file deleted
    # or corrupted between the check and the read). After _pool_json_valid, jq
    # normally succeeds; a missing path yields null (exit 0).
    jq -r --arg f "$field" 'getpath($f|split("."))' "$file" || return 1
    return 0
}

# pool_lease_exists LANE
#
# Predicate: does lane LANE have a VALID lease file? Return 0 if
# $POOL_LANES_DIR/<LANE>.json exists AND is valid JSON (parseable by jq); return 1
# otherwise (missing / corrupt / non-numeric lane). Pure predicate — NEVER logs,
# NEVER writes, NEVER calls pool_die (mirrors _pool_json_valid and pool_owner_alive).
#
# "valid" = SYNTACTICALLY valid JSON (composed via _pool_json_valid). A full
# schema-completeness check (all 12 PRD §2.8 fields + types) is OUT OF SCOPE — the
# literal CONTRACT is "exists and is valid" = exists + parseable, and downstream
# consumers read specific fields defensively (a missing field → null via
# pool_lease_field).
#
# CONSUMERS: M3.T2.S2 find_free_lane (return 1 == "lane N is free"; lowest N≥1
# with no lease); M3.T2.S1 find_my_lease (skip lanes with no lease); M7.T4.S1
# doctor (reconcile leases vs live Chromes vs dirs).
#
# GOTCHA — non-numeric lane → return 1 (path-traversal safe; a bogus lane "has no
# lease"). Read functions never die.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR).
pool_lease_exists() {
    local lane="${1:-}"
    local file

    # Validate lane (path-traversal defense). Predicate → return 1 on bad lane.
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    file="$POOL_LANES_DIR/$lane.json"

    # Exists + valid JSON → 0; else 1. Composes the M1.T2.S1 predicate (never fatal).
    [[ -f "$file" ]] || return 1
    _pool_json_valid "$file" || return 1
    return 0
}

# =============================================================================
# Lease management — query operations (P1.M3.T2.S1)
# =============================================================================
# Cross-lane iteration + owner-correlation queries. Composes the S2 read helpers
# (pool_lease_field), the M2.T2.S1 identity predicate (pool_owner_alive), and the
# M2.T1.S1 owner globals (POOL_OWNER_PID). Consumed by the wrapper lifecycle step 2
# (M6.T3.S1 reuse-vs-acquire), the reap/ensure-connected orchestration (M5), and the
# admin CLI (M7 status/doctor). NON-FATAL by design: "no match"/"no lease" returns 1
# (the wrapper's signal to acquire), mirroring _pool_json_valid / pool_owner_alive /
# the S2 readers.

# pool_lanes_list
#
# Enumerate every NUMERIC lane stem from $POOL_LANES_DIR/*.json, echo each N on its
# own line, numerically sorted ascending (sort -n). Always returns 0 — an empty or
# missing lanes dir is a VALID state (the wrapper's first-ever acquire; PRD §2.4
# step 2 scans this), never an error.
#
# CONSUMERS: pool_lease_find_mine / pool_lease_find_mine_any (below); M5.T3 reap;
# M7.T1 status; M7.T4 doctor; M5.T4 force-reap (find oldest dead-owner lane).
#
# GOTCHA — nullglob is NOT set: a no-match glob expands to the LITERAL
# "$POOL_LANES_DIR/*.json". `[[ -f "$f" ]] || continue` rejects that literal (and
# subdirs, and non-files). Host-verified 2026-07-12.
# GOTCHA — numeric filter: a stray non-numeric *.json (e.g. an editor artifact) is
# skipped by the ^[0-9]+$ test, matching the lane-validation contract used by every
# lease function (S1/S2). Lane numbers are the only thing we ever echo.
# GOTCHA — for n in $(pool_lanes_list): output is digits-only/newline-separated, so
# the unquoted command substitution word-splits into exactly the lane numbers
# (intentional; quoting would make it one word). Safe because no lane has whitespace.
# GOTCHA — | sort -n runs the loop body in a subshell; the function's status is
# sort's (always 0). The explicit `return 0` documents intent and is pipefail-safe.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR). The dir need not exist — a
# missing dir surfaces as a no-match glob → 0 iterations → no output (correct).
pool_lanes_list() {
    local f base n
    for f in "$POOL_LANES_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        n="${base%.json}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$n"
    done | sort -n
    return 0
}

# pool_lease_find_mine
#
# Find MY valid lease: scan every lane; on the first lane whose owner.pid ==
# POOL_OWNER_PID AND pool_owner_alive(pid, starttime, comm) → echo that lane N and
# return 0. If no valid match → return 1. Implements PRD §2.4 step 2 ("Find MY
# lease: owner.pid==pid && comm=='pi' && starttime match").
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle step 2 (rc 0 → reuse lane N; rc 1 → acquire);
# M5.T1.S3 ensure_connected (reuse gate).
#
# ORDERING (CONTRACT): owner.pid == POOL_OWNER_PID (cheap string equality) BEFORE
# pool_owner_alive (3× /proc reads). Most lanes are not mine; only the (≤1, by the
# §2.8 invariant) pid-matching lane reaches the liveness check.
# GOTCHA — corrupt/mid-deletion leases are SKIPPED, not fatal: pool_lease_field
# returns 1 on missing/corrupt (S2 contract); `|| continue` keeps the scan alive
# under set -e (one bad lane must never break the hot wrapper path).
# GOTCHA — pool_owner_alive is passed the LEASE's stored starttime + comm so it can
# compare them against the LIVE process → defeats PID recycling (PRD §2.8/§2.14).
# GOTCHA — POOL_OWNER_PID == "0" (passthrough) passes the guard; the loop finds no
# real pid==0 lease → return 1 (correct). Unset/empty/non-numeric → return 1 fast.
# GOTCHA — CALLERS under set -e MUST guard: `if n="$(pool_lease_find_mine)"; then …`.
#   A bare `n="$(pool_lease_find_mine)"` ABORTS on the rc-1 path (same hazard as
#   pool_lease_read — S2 research §2).
# PRECONDITION: pool_config_init + pool_owner_resolve (for POOL_OWNER_PID).
pool_lease_find_mine() {
    local n pid st comm
    # No resolved owner → no lease. `[[ ]] || return 1` is errexit-exempt.
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
    for n in $(pool_lanes_list); do
        pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
        # Cheap equality first; skip non-mine lanes without touching /proc.
        [[ "$pid" == "$POOL_OWNER_PID" ]] || continue
        st="$(pool_lease_field "$n" owner.starttime 2>/dev/null)" || continue
        comm="$(pool_lease_field "$n" owner.comm 2>/dev/null)" || continue
        # Live + same process invocation? (pool_owner_alive returns 1 on dead/
        # recycled — the `if` is simply false → keep scanning.) One owner ≤1 lane
        # (§2.8) ⟹ the scan falls through to return 1 if this one is stale.
        if pool_owner_alive "$pid" "$st" "$comm"; then
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 1
}

# pool_lease_find_mine_any
#
# ★★★ DEAD CODE — CURRENTLY UNUSED (Issue #5) ★★★ This diagnostic variant has ZERO
# non-comment call sites. Its docstring below lists reap / doctor / release as intended
# consumers, but none actually call it: pool_reap_stale uses pool_lane_is_stale;
# pool_admin_doctor uses pool_lease_read; pool_admin_release uses pool_lanes_list. It is
# RETAINED as a documented building block for a future self-reap / reconcile path that
# has not been wired. Do NOT assume it is live.
#
# Diagnostic variant of find_mine: return the first lane whose owner.pid ==
# POOL_OWNER_PID REGARDLESS of liveness (no pool_owner_alive call). Surfaces a STALE
# lease that nonetheless names this PID — for the reaper (M5.T3), doctor (M7.T4),
# and explicit release (M7.T3) self-cleanup paths. Echo the lane N and return 0 on
# the first pid-match; return 1 if no lane names this PID.
#
# CONSUMERS: M5.T3 reap (self-reap / diagnostic), M7.T4 doctor (reconcile), M7.T3
# release [<N>|all] (find my lanes to tear down).
#
# DIFFERENCE from find_mine: no pool_owner_alive → returns a lane even when the owner
# is dead/recycled. find_mine = "valid mine"; find_mine_any = "claiming to be mine".
# GOTCHA — first-match semantics (return immediately). §2.8 invariant ⟹ ≤1 such
# lane, so first-match == only-match in correct operation.
# GOTCHA — corrupt lanes skipped via `|| continue` (same as find_mine).
# GOTCHA — CALLERS under set -e MUST guard: `if n="$(pool_lease_find_mine_any)"; then`.
# PRECONDITION: pool_config_init + pool_owner_resolve (for POOL_OWNER_PID).
pool_lease_find_mine_any() {
    local n pid
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1
    for n in $(pool_lanes_list); do
        pid="$(pool_lease_field "$n" owner.pid 2>/dev/null)" || continue
        if [[ "$pid" == "$POOL_OWNER_PID" ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# Lease management — query operations (P1.M3.T2.S2)
# =============================================================================
# Lane allocation: the lowest-free-lane probe. Implements PRD §2.4 step 3c
# ("CHOOSE N: lowest N≥1 with no active/<N> dir and no lanes/<N>.json lease").
# A pure, read-only numeric probe; composes NOTHING below it (it does not call
# pool_lease_exists, pool_lanes_list, or any M3.T2.S1 function). Reads only the two
# frozen pool_config_init globals. Consumed by the acquire flock critical section
# (M5.T1.S1 step 3c).

# pool_find_free_lane
#
# Walk N = 1, 2, 3, … (lanes are UNBOUNDED — created on demand, PRD §2.4). Echo the
# first N where BOTH the ephemeral dir is absent AND the lease file is absent, and
# return 0. ALWAYS echoes a value and returns 0 — there is no "no free lane" failure
# state (the live-agent count is finite, so the probe terminates at ≈ live-count+1;
# reap_stale at step 3a has already removed dead-owner lanes before this runs at 3c).
#
# CONSUMER: M5.T1.S1 acquire step 3c, INSIDE the caller's flock on $POOL_LOCK_FILE.
#   Because this function always returns 0, a bare `N="$(pool_find_free_lane)"` is
#   set -e SAFE (no `if` guard needed) — unlike pool_lease_find_mine (returns 1).
#
# WHY TWO CHECKS (dir AND lease — research §0/§7): checking only the lease would miss
# an orphaned ephemeral dir (a Chrome still running after its lease was deleted, or a
# crash between `cp -a` and pool_lease_write). Checking only the dir would miss the
# provisional-claim window (lease written at step 3d, dir copied at 3e — both inside
# the same flock, so a second serialized acquirer must skip lane N). BOTH must be
# absent for a lane to be free.
# WHY [[ -f ]] NOT pool_lease_exists (research §3): pool_lease_exists returns 1 (free)
# on a CORRUPT lease (jq-empty parse fails), which would let us reuse a lane whose
# Chrome may still be live (reap skipped it — couldn't read owner.pid) → COLLISION.
# [[ -f ]] treats a present-but-corrupt file as occupied (safe; just skips that N).
# It is also cheaper (no jq fork) inside the lock.
# GOTCHA — for (( n=1; ; n++ )): the empty middle condition is the canonical
# "loop forever"; its condition slot is NOT a statement, so errexit never fires on it.
# (A bare `(( n++ ))` STATEMENT would return 1 when n was 0 and ABORT under set -e —
# same trap as _pool_age_str's (( )) blocks; the for-form sidesteps it.)
# GOTCHA — no hard cap: do NOT add `n <= MAX`. The contract is "lowest N≥1, increment"
# with no bound. Pool EXHAUSTION (PRD §2.9) is M5.T4's concern (external timeout around
# the whole acquire), not this function's.
# GOTCHA — missing parents are fine: if POOL_EPHEMERAL_ROOT/POOL_LANES_DIR don't exist
# yet, [[ -d "$POOL_EPHEMERAL_ROOT/1" ]] is simply false → N=1 is free. Read-only:
# never mkdirs.
# GOTCHA — junk immunity: a stray foo.json / sub.json/ subdir is never tested (the
# probe is purely numeric N=1,2,3,…), unlike pool_lanes_list which globs and filters.
# PRECONDITION: pool_config_init (for the ABSOLUTE POOL_EPHEMERAL_ROOT + POOL_LANES_DIR).
pool_find_free_lane() {
    local n
    for (( n = 1; ; n++ )); do
        if [[ ! -d "$POOL_EPHEMERAL_ROOT/$n" && ! -f "$POOL_LANES_DIR/$n.json" ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    done
}

# =============================================================================
# Lease management — query operations (P1.M3.T2.S3)
# =============================================================================
# Per-lane staleness verdict for the lazy reaper. Implements PRD §2.5 (release is
# owner-liveness-driven) + §2.14 (the three stale failure modes: pid dead / comm!=pi
# / starttime mismatch) + §2.10 (reaper is lazy, on acquire). Reads a lane's lease,
# extracts its owner.{pid,starttime,comm} triple, and delegates the identity check to
# pool_owner_alive (M2.T2.S1). Consumed by the reaper (M5.T3.S1) and the acquire flock
# step 3a REAP-STALE (M5.T1.S1) — it runs BEFORE pool_find_free_lane (step 3c) so freed
# lane numbers are reusable in the same critical section.

# pool_lane_is_stale LANE
#
# TRI-STATE verdict (NOT a boolean):
#   0 = STALE     — owner dead/recycled/unverifiable → caller reaps the lane.
#   1 = LIVE      — owner alive + identity matches → caller keeps the lane.
#   2 = NO LEASE  — lease file missing OR corrupt → caller skips (nothing to reap).
#
# The rc convention is INVERTED vs pool_owner_alive (which returns 0=alive / 1=dead):
#   pool_owner_alive -> 1 (dead)  ==>  pool_lane_is_stale -> 0 (stale)
#   pool_owner_alive -> 0 (alive) ==>  pool_lane_is_stale -> 1 (live)
# The inversion is deliberate: it makes the reaper idiom
#   `if pool_lane_is_stale "$n"; then pool_release_lane "$n"; fi`
# read naturally — rc 0 ("true") IS the "yes, stale" answer (shell convention).
#
# LOGIC (CONTRACT a→d):
#   a. pool_lease_read "$lane". rc 1 (missing OR corrupt) → return 2 (skip).
#   b. Extract owner.{pid,starttime,comm} from the in-memory JSON (ONE jq fork).
#   c. pool_owner_alive "$pid" "$starttime" "$comm". rc 1 → return 0 (stale).
#   d. rc 0 (alive) → return 1 (live).
#
# CONSUMERS: M5.T3.S1 reap_stale (the lazy reaper, per-lane in the scan loop);
#   M5.T1.S1 acquire flock step 3a (reap-stale before choose-N).
#
# GOTCHA — CALLERS under set -e MUST guard: a BARE `pool_lane_is_stale "$n"` whose rc
#   is 1 (live) or 2 (no lease) ABORTS the caller. Use `if pool_lane_is_stale "$n";
#   then reap; fi` (rc 1/2 fall through) or `pool_lane_is_stale "$n" && rc=0 || rc=$?`
#   to capture all three codes. Same hazard family as pool_lease_read/find_mine.
# GOTCHA — compose ONLY pool_lease_read + pool_owner_alive (CONTRACT-named). Do NOT use
#   pool_lease_field (3 extra reads + forks). Read ONCE, extract with ONE jq via mapfile.
# GOTCHA — missing AND corrupt both → rc 2: pool_lease_read returns 1 for both; a corrupt
#   lease can't identify the owner/chrome_pgid to kill safely, so skip (doctor M7.T4
#   reconciles). pool_lease_read logs the ONE "corrupt lease" warning on the corrupt path.
# GOTCHA — missing/garbled owner FIELDS → stale (rc 0): a valid-JSON lease with no owner
#   object yields pid="null" → pool_owner_alive's own `[[ =~ ^[0-9]+$ ]]` rejects it →
#   returns 1 → is_stale returns 0. SAFE (unverifiable → reaped, never trusted); needs
#   NO special-case branch.
# GOTCHA — mapfile -t is mandatory: strips trailing newlines so pid compares cleanly.
# GOTCHA — jq reads the in-memory herestring (not the file): no TOCTOU, and jq cannot
#   fail on parse (pool_lease_read already guaranteed valid JSON via _pool_json_valid).
# NEVER calls pool_die / NEVER writes / NEVER kills / NEVER logs directly (read-only
#   VERDICT; the caller acts). The only possible log line comes from pool_lease_read.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR, via pool_lease_read).
pool_lane_is_stale() {
    local lane="${1:-}"
    local json pid starttime comm
    local -a _owner

    # (a) Read the lease. Validate lane (path-traversal defense; a non-numeric lane
    # simply "has no lease" → rc 2). `if !` is errexit-exempt — a bare capture would
    # ABORT under set -e when pool_lease_read returns 1 (missing OR corrupt). The
    # 2>/dev/null suppresses jq's corrupt-parse stderr (the warning is logged, not on
    # stderr, so diagnostics are preserved).
    [[ "$lane" =~ ^[0-9]+$ ]] || return 2
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
        return 2
    fi

    # (b) Extract owner.{pid,starttime,comm} from the in-memory JSON in ONE jq fork.
    # Comma emits exactly 3 lines (one per expression; a missing .owner → three
    # "null" lines). mapfile -t strips trailing newlines → 3 clean elements. The
    # `:-` defaults defend an (impossible) short read. jq cannot fail here (valid JSON
    # guaranteed; herestring is in-memory — no file TOCTOU).
    mapfile -t _owner < <(jq -r '.owner.pid, .owner.starttime, .owner.comm' <<<"$json")
    pid="${_owner[0]:-}"
    starttime="${_owner[1]:-}"
    comm="${_owner[2]:-}"

    # (c)/(d) Delegate identity+liveness to pool_owner_alive and INVERT its rc.
    # pool_owner_alive: 0=alive → return 1 (live);  1=dead/recycled/non-numeric-pid
    # → return 0 (stale). The `if` is errexit-exempt (pool_owner_alive returns 1 on
    # the stale path — a bare call would abort; the if keeps it safe).
    if pool_owner_alive "$pid" "$starttime" "${comm:-pi}"; then
        return 1     # live — owner is the same process that took the lease
    fi
    return 0          # stale — owner dead/recycled/unverifiable → caller reaps
}

# =============================================================================
# Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)
# =============================================================================
# Materialize one ephemeral Chrome profile from the read-only master template.
# Implements PRD §2.7 (Copy / master hygiene) + §2.19 (reflink detection: cp
# --reflink=always; on failure refuse unless AGENT_CHROME_ALLOW_SLOW_COPY=1) and
# removes the three stale Chrome single-instance locks the template carries. Consumed
# by the acquire POST-LOCK boot (M5.T1.S2: copy → port → launch → connect → update
# lease), OUTSIDE the flock critical section (key_findings FINDING 2 — the ~instant
# reflink copy is cheap enough to run concurrently with other acquires' boots).

# pool_copy_master TARGET_DIR
#
# Copy $POOL_MASTER_DIR (the master template) into TARGET_DIR (an ephemeral lane,
# normally $POOL_EPHEMERAL_ROOT/<N>) as a flat profile, then remove the stale
# Singleton* locks. Returns 0 on success; pool_die on any failure.
#
# LOGIC (CONTRACT a→e):
#   a. cp -a --reflink=always "$POOL_MASTER_DIR" "$TARGET_DIR"  (instant CoW on btrfs).
#   b. cp fails (non-btrfs / unsupported) AND POOL_ALLOW_SLOW_COPY != 1 → pool_die.
#   c. cp fails AND POOL_ALLOW_SLOW_COPY == 1 → retry with cp -a (slow real copy).
#   d. after success: rm -f SingletonLock SingletonCookie SingletonSocket.
#   e. return 0 / pool_die on failure.
#
# CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → TARGET_DIR is a flat,
#   lock-cleaned, ready-to-launch profile; any failure exits the process via pool_die.
#
# GOTCHA — reflink stderr FLOODS on non-btrfs: cp emits one "Operation not supported"
#   line PER source file (thousands for a 4.8 GB master) and exits rc 1. The reflink
#   attempt runs with 2>/dev/null. HOST-VERIFIED (research §1.1).
# GOTCHA — reflink failure leaves an EMPTY PARTIAL TARGET_DIR: cp creates TARGET_DIR
#   (empty) before failing. We `rm -rf -- "$target_dir"` on the failure path so the
#   caller's `[[ -d ]]` free-lane probe is not fooled and the slow retry does not nest.
#   HOST-VERIFIED (research §1.2).
# GOTCHA — NESTING HAZARD: `cp -a src dst` when dst EXISTS copies src INTO dst
#   (dst/<basename src>/…); when dst is ABSENT, dst becomes a flat copy of src. Because
#   the failed reflink leaves dst existing, the `rm -rf` before the slow retry is
#   MANDATORY to keep the copy FLAT. HOST-VERIFIED (research §1.3/§1.4).
# GOTCHA — SingletonSocket is an AF_UNIX socket: rm -f removes it like a file; no
#   special-case. `-f` tolerates a clean master where some are absent. (research §5).
# GOTCHA — compose pool_check_master, NOT pool_check_btrfs: the cp exit code IS the
#   btrfs detection (contract steps a-c). pool_check_btrfs would pre-empt it and checks
#   POOL_EPHEMERAL_ROOT not the target; it is the acquire-INIT gate (M5.T1.S1). A raw
#   findmnt -T is used ONLY to report the FS in the die message. (research §3).
# GOTCHA — findmnt -T is MANDATORY: a bare `findmnt -nno FSTYPE "$dir"` (no -T) exits 1
#   ON THIS HOST EVEN ON BTRFS. external_deps.md §3.2 omits -T and is BROKEN. (§4).
# GOTCHA — POOL_EPHEMERAL_ROOT may not exist on a first run (pool_state_init does NOT
#   create it); mkdir -p the PARENT of TARGET_DIR so cp can create the target. NEVER
#   mkdir the target itself (that would flip cp into nesting mode).
# GOTCHA — TARGET_DIR validated absolute (PRD §2.2: no bare ~ / relative paths to cp or
#   rm) and non-empty (also guards the internal rm -rf).
# Reads ONLY POOL_MASTER_DIR + POOL_ALLOW_SLOW_COPY (frozen by pool_config_init).
# No new globals/env-vars/files.
# PRECONDITION: pool_config_init (for POOL_MASTER_DIR + POOL_ALLOW_SLOW_COPY).
pool_copy_master() {
    local target_dir="${1:-}"
    local parent fstype

    # Validate target_dir: non-empty + ABSOLUTE (PRD §2.2; also guards the rm -rf).
    # `[[ ]] || pool_die` is errexit-exempt.
    [[ -n "$target_dir" ]] \
        || pool_die "pool_copy_master: empty target_dir"
    [[ "$target_dir" == /* ]] \
        || pool_die "pool_copy_master: target_dir must be absolute: $target_dir"

    # Pre-check the master (PRD §2.14: die with the exact bootstrap cp command if
    # missing/empty). pool_check_master is M1.T1.S3 (LANDED @266): rc 0 or pool_die.
    pool_check_master

    # Ensure the PARENT of target_dir exists (cp needs it; the ephemeral root may not
    # exist on a first run). mkdir -p is idempotent. Do NOT mkdir the target itself
    # (cp creates it; mkdir-ing it would trigger the nesting hazard). `|| pool_die` so a
    # real FS error is a clean fatal (not a set -e abort).
    parent="$(dirname -- "$target_dir")"
    mkdir -p -- "$parent" \
        || pool_die "pool_copy_master: cannot create parent dir: $parent"

    # (a) reflink CoW copy — instant on btrfs. 2>/dev/null suppresses the per-file
    # "Operation not supported" flood on non-btrfs (research §1.1). `if !` is
    # errexit-exempt — a bare cp that fails would ABORT under set -e.
    if ! cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null; then
        # reflink failed (non-btrfs / unsupported). cp left an empty PARTIAL target_dir
        # (research §1.2). rm it so the retry does not NEST (research §1.3). PLAIN rm
        # under `if !`: if rm itself fails we fall through to die below (acceptable —
        # something is deeply wrong with the FS).
        rm -rf -- "$target_dir" 2>/dev/null || true

        # (c) slow-copy escape hatch (POOL_ALLOW_SLOW_COPY normalized to "1"/"0" by
        # pool_config_init's _pool_config_bool — exactly "1" → on).
        if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
            if ! cp -a -- "$POOL_MASTER_DIR" "$target_dir"; then
                pool_die "pool_copy_master: slow copy (cp -a) also failed:" \
                         "$POOL_MASTER_DIR -> $target_dir"
            fi
        else
            # (b) not btrfs + no escape → die loudly. Report the detected FS for clarity
            # (findmnt -T MANDATORY; || true neutralizes a missing-path exit 1).
            fstype="$(findmnt -nno FSTYPE -T "$parent" 2>/dev/null || true)"
            pool_die "pool_copy_master: cp --reflink=always failed" \
                     "(target FS '${fstype:-<unknown>}' is not btrfs / reflink unsupported)." \
                     "A real 4.8 GB copy per acquire would be catastrophic." \
                     "Set AGENT_CHROME_ALLOW_SLOW_COPY=1 to allow it, or point" \
                     "AGENT_CHROME_EPHEMERAL_ROOT at a btrfs mount (the path may not exist)."
        fi
    fi

    # (d) remove stale Chrome single-instance locks from the template (would confuse a
    # launched Chrome). SingletonSocket may be an AF_UNIX socket — rm -f handles all
    # three. -f tolerates a clean master where some are absent. `|| pool_die` for safety.
    rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie" "$target_dir/SingletonSocket" \
        || pool_die "pool_copy_master: cannot remove Singleton locks in: $target_dir"

    return 0
}

# =============================================================================
# Lane lifecycle — port allocation (P1.M4.T2.S1)
# =============================================================================
# Select the lowest free TCP port in [POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE)
# for a freshly-claimed lane's Chrome to bind. Implements PRD §2.4 step 3f ("PORT: lowest
# free TCP port in [BASE, BASE+RANGE); probe via curl /json/version") + §2.3 (the
# 3-stage free test). Consumed by the acquire POST-LOCK boot (M5.T1.S2: copy → port →
# launch → connect → update lease), OUTSIDE the flock critical section (key_findings
# FINDING 2 — concurrent boots; selection is BEST-EFFORT: the launch is the authoritative
# bind; on a launch/CDP failure, _pool_launch_and_verify re-picks a different port via
# pool_find_free_port and retries once (Issue 2 / S1+S2)).

# pool_find_free_port
#
# Echo the lowest free TCP port in [POOL_PORT_BASE, POOL_PORT_BASE+POOL_PORT_RANGE) and
# return 0; return 1 if the whole range is occupied (exhaustion — non-fatal, ~impossible
# with the default 1000-port range). A port is "free" when ALL of:
#   1. NOT claimed by any live lease's .port      (provisional port=0 claims do NOT count)
#   2. NOT shown listening by `ss -tlnH`          (any OS listener)
#   3. NOT answering curl /json/version           (a live non-pool Chrome on that port)
#
# LOGIC (CONTRACT 3a→3c):
#   a. Build a claimed-port set from lanes/*.json (compose pool_lanes_list +
#      pool_lease_field); skip port<=0 / non-numeric (PRD §2.4 step 3d provisional = 0).
#   b. Capture `ss -tlnH` ONCE (netlink is more expensive than a grep fork; mirrors
#      pool_lane_is_stale's "ONE jq fork" principle). Loop BASE..BASE+RANGE-1:
#        - skip if claimed (O(1) assoc-array lookup)
#        - skip if `:$port ` (trailing space = word boundary) appears in the snapshot
#        - skip if curl /json/version responds (live CDP endpoint)
#        - first pass → echo + return 0.
#   c. none free → return 1 (NOT pool_die — recoverable; caller → M5.T4 exhaustion flow).
#
# CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → stdout is the port to bind;
#   rc 1 → range exhausted, caller must handle (block/force-reap/alert). Caller MUST guard
#   under set -e: `if port="$(pool_find_free_port)"; then …`.
#
# GOTCHA — provisional leases carry port=0 (PRD §2.4 step 3d): the claimed-set builder
#   filters `[[ =~ ^[0-9]+$ && -gt 0 ]]`, so a mid-acquire lane does NOT reserve a port.
#   HOST-VERIFIED (research §3, scenario 2).
# GOTCHA — the ss regex NEEDS the trailing space (`:$port `): it is the local-addr /
#   peer-addr separator → the word boundary. Without it `:5342` would match `:53420`.
#   IPv6-safe ([::]:9222 still has ':9222 '). Plain grep -q (literal) — port is numeric.
#   HOST-VERIFIED (research §1).
# GOTCHA — capture ss ONCE, not per-port: the contract writes the ss|grep inside the loop;
#   ss is a netlink call (slower than grep). We snapshot once and grep the captured text.
#   `|| true` degrades a transient ss failure to an empty snapshot (curl still guards).
#   HOST-VERIFIED (research §2).
# GOTCHA — curl --max-time 2 is DEFENSIVE: connection-refused (rc 7) is INSTANT, so this
#   adds zero latency for free ports; it only bounds a pathological DROP-style filtered
#   port. -f makes a 404 responder non-zero, but such a responder is ALREADY caught by the
#   ss check (it IS listening) — curl only runs for ss-free ports → it's the live race
#   guard. HOST-VERIFIED (research §4).
# GOTCHA — NEVER pool_die on exhaustion: rc 1 (non-fatal query), same family as
#   pool_lease_read / pool_lease_find_mine. Caller MUST guard under set -e. (research §6).
# GOTCHA — this is the FIRST `local -A` (associative array) in the codebase: the idiomatic
#   O(1) fork-free "set" for the claimed-port membership test inside a ≤1000-iteration
#   loop. bash 4+ (already required by mapfile/declare -g). (research §3).
# GOTCHA — TOCTOU tolerated: runs OUTSIDE the flock (FINDING 2); two acquires can both
#   pick the same port — the launch is authoritative; on a launch/CDP failure,
#   _pool_launch_and_verify re-picks a different port via pool_find_free_port and retries
#   once (Issue 2 / S1+S2). (research §5).
# Reads ONLY POOL_PORT_BASE + POOL_PORT_RANGE (frozen by pool_config_init) + the lease
# JSON (via pool_lanes_list/pool_lease_field). Writes nothing. No new globals/env-vars.
# PRECONDITION: pool_config_init (for POOL_PORT_BASE/RANGE + POOL_LANES_DIR via helpers).
pool_find_free_port() {
    local port p n listeners
    local -A claimed=()

    # (a) Build the claimed-port set. Compose the LANDED readers (pool_lanes_list +
    #     pool_lease_field) — same enumeration pattern as pool_lease_find_mine. Skip
    #     port<=0 / non-numeric: a PROVISIONAL claim writes port=0 (PRD §2.4 step 3d)
    #     and must NOT reserve a port. `|| continue` keeps a corrupt/missing lease from
    #     aborting the scan (pool_lease_field returns 1, silent). assoc-array assignment
    #     is errexit-safe.
    for n in $(pool_lanes_list); do
        p="$(pool_lease_field "$n" port 2>/dev/null)" || continue
        [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && claimed["$p"]=1
    done

    # Snapshot the listening sockets ONCE (not per-port). `|| true` so a transient ss
    # failure (missing binary / permission) degrades to an empty snapshot — the per-port
    # curl below is the live check that still guards.
    listeners="$(ss -tlnH 2>/dev/null || true)"

    # (b) Lowest free port in [BASE, BASE+RANGE). POOL_PORT_BASE/RANGE are validated
    #     uints (pool_config_init) → safe in (( )). Each skip is errexit-exempt
    #     (`[[ ]] || continue`, `grep … && continue`, `if curl …; then continue; fi`).
    for (( port = POOL_PORT_BASE; port < POOL_PORT_BASE + POOL_PORT_RANGE; port++ )); do
        # 1. claimed by a live lease? (O(1) assoc lookup; ${:-} is safe for unset keys)
        [[ -z "${claimed[$port]:-}" ]] || continue
        # 2. OS listener? (`:$port ` trailing space = word boundary; literal grep)
        grep -q ":$port " <<<"$listeners" && continue
        # 3. live CDP endpoint? (a non-pool Chrome answering /json/version). -f fails on
        #    HTTP>=400; --max-time bounds a DROP-style filter (connection-refused is
        #    instant). 2>&1 + >/dev/null = fully silent.
        if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$port"
        return 0
    done

    # (c) Exhausted — rc 1, NOT pool_die. Caller handles via M5.T4 (block/force-reap/alert).
    return 1
}

# =============================================================================
# Lane lifecycle — Chrome launch & CDP readiness (P1.M4.T2.S2)
# =============================================================================
# Launch one pooled Chrome as its own process-group leader (pgid==pid via setsid) on a
# chosen port + ephemeral profile dir, then wait for its CDP endpoint to answer. Implements
# PRD §2.6 (Chrome launch per lane — the EXACT flag list) + §2.4 step 3g (LAUNCH setsid …;
# record chrome_pid + pgid) + 3h (WAIT for CDP /json/version). Consumed by the acquire
# POST-LOCK boot (M5.T1.S2: copy → find_free_port → launch → wait_cdp → connect → update
# lease), OUTSIDE the flock critical section (key_findings FINDING 2 — concurrent boots).

# pool_chrome_launch PORT USER_DATA_DIR LANE
#
# Launch Chrome (via setsid, so pgid==pid) on PORT with USER_DATA_DIR, writing combined
# stdout/stderr to $POOL_STATE_DIR/chrome-<LANE>.log. Exports globals POOL_CHROME_PID and
# POOL_CHROME_PGID (== POOL_CHROME_PID — the setsid contract; release does kill -- -<pgid>).
# Returns 0 on success; 1 on instant Chrome death WITH an EADDRINUSE-like error in
# the log (port collision -- retryable, caller re-picks a port); pool_die on bad args
# / instant Chrome death WITHOUT EADDRINUSE (genuine misconfiguration) / missing log dir.
#
# LOGIC (CONTRACT 3a):
#   - flag list: --remote-debugging-port=<port> --user-data-dir=<ABSOLUTE udd>
#     --no-first-run --no-default-browser-check --disable-background-timer-throttling
#     --disable-backgrounding-occluded-windows --disable-renderer-backgrounding
#     --disable-features=CalculateNativeWinOcclusion --disable-back-forward-cache
#     ( + --headless=new iff POOL_HEADLESS==1 )
#   - log file: $POOL_STATE_DIR/chrome-<lane>.log
#   - launch: setsid "$POOL_CHROME_BIN" <flags> > "$log" 2>&1 &
#   - capture POOL_CHROME_PID=$!
#   - POOL_CHROME_PGID=$(ps -o pgid= -p $PID | tr -d ' ')  (GUARDED — see GOTCHA)
#   - export both as globals (declare -g).
#
# CONSUMER: M5.T1.S2 acquire post-lock boot. CONTRACT: rc 0 → Chrome launched + the two
#   globals are set (pgid==pid); rc 1 → EADDRINUSE detected on instant-exit (retryable --
#   caller re-picks a port via pool_find_free_port); pool_die → fatal (propagates). The
#   caller MUST guard under set -e: `if ! pool_chrome_launch ...; then <re-pick port>; fi`.
#   The caller then calls pool_wait_cdp <port>, then reads the globals into the lease.
#
# GOTCHA — setsid $!/pgid contract (HOST-VERIFIED, research §1): `setsid CMD &; SP=$!`
#   gives pgid==pid==sid for CMD because util-linux setsid (default, NO --fork) exec's the
#   command after setsid(2) when the caller is not a pgroup leader. Do NOT add --fork/-f
#   (it would fork and break pgid==pid → release would leak orphans).
# GOTCHA — the pgid capture ABORTS under set -e on instant death (HOST-VERIFIED, research
#   §5): `ps -o pgid= -p $PID` returns rc 1 + empty if Chrome already exited (bad port /
#   missing binary). A BARE $(…) would ABORT the pool. Capture with `|| true`, then a
#   `[[ -z ]]` check. On instant death, grep the log for EADDRINUSE-like patterns
#   (Issue 2): match → return 1 (retryable, caller re-picks port); no match → pool_die
#   (genuine misconfiguration). NOTE: the COMMON EADDRINUSE case is Chrome STAYING UP
#   without CDP → caught by pool_wait_cdp's 30s timeout → S2 re-picks; THIS grep is the
#   defensive fast path for the instant-exit variant. Pattern:
#   grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind'.
# GOTCHA — the log redirect needs an existing dir: `> "$log" 2>&1 &` fails to open if the
#   dir is missing → the job exits instantly → trips the §5 guard. Defensively mkdir -p
#   $POOL_STATE_DIR first (pool_state_init already does this, but be robust).
# GOTCHA — POOL_CHROME_BIN may be a bare name (resolved via PATH by setsid/execvp) or an
#   absolute path (canonicalized by pool_config_init). Both work — pass it quoted.
# GOTCHA — NO bare ~ (PRD §2.2): USER_DATA_DIR is validated ABSOLUTE before launch.
# GOTCHA — POOL_CHROME_PID/POOL_CHROME_PGID naming follows the codebase POOL_* convention
#   (every global is POOL_*; pool_owner_resolve sets POOL_OWNER_PID). The contract's bare
#   CHROME_PID/CHROME_PGID is shorthand. (research §6)
# Reads ONLY POOL_CHROME_BIN + POOL_HEADLESS + POOL_STATE_DIR (frozen by pool_config_init).
# Writes only the Chrome log. No new env-vars/files.
# PRECONDITION: pool_config_init (for the three globals).
pool_chrome_launch() {
    local port="${1:-}"
    local user_data_dir="${2:-}"
    local lane="${3:-}"
    local log_file flags pgid

    # Validate args. All `[[ ]] || pool_die` are errexit-exempt.
    [[ "$port" =~ ^[0-9]+$ ]] \
        || pool_die "pool_chrome_launch: port must be a non-negative integer, got: '${port:-<unset>}'"
    [[ -n "$user_data_dir" ]] \
        || pool_die "pool_chrome_launch: user_data_dir is empty"
    [[ "$user_data_dir" == /* ]] \
        || pool_die "pool_chrome_launch: user_data_dir must be ABSOLUTE (PRD §2.2): $user_data_dir"
    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_chrome_launch: lane must be a non-negative integer, got: '${lane:-<unset>}'"
    [[ -n "$POOL_CHROME_BIN" ]] \
        || pool_die "pool_chrome_launch: POOL_CHROME_BIN is empty (run pool_config_init first)"

    # Ensure the log dir exists so the backgrounded redirect can open the log file.
    # pool_state_init already mkdir -p's the lanes subdir (a child of POOL_STATE_DIR), but
    # be robust: this function may be called in a test that skipped pool_state_init.
    mkdir -p -- "$POOL_STATE_DIR" \
        || pool_die "pool_chrome_launch: cannot create log dir: $POOL_STATE_DIR"
    log_file="$POOL_STATE_DIR/chrome-$lane.log"

    # Build the flag list (array — survives any future arg with spaces; no word-splitting).
    flags=(
        --remote-debugging-port="$port"
        --user-data-dir="$user_data_dir"
        --no-first-run
        --no-default-browser-check
        --disable-background-timer-throttling
        --disable-backgrounding-occluded-windows
        --disable-renderer-backgrounding
        --disable-features=CalculateNativeWinOcclusion
        --disable-back-forward-cache
    )
    [[ "$POOL_HEADLESS" == "1" ]] && flags+=(--headless=new)

    # Launch: setsid makes Chrome its own session/group leader (pgid==pid). The redirection
    # captures Chrome's combined stdout/stderr to the per-lane log. `&` backgrounds it; $!
    # is Chrome's pid (setsid exec'd it — research §1). Backgrounding is errexit-exempt.
    setsid -- "$POOL_CHROME_BIN" "${flags[@]}" >"$log_file" 2>&1 &
    POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID

    # Capture the process-group id. GUARDED (research §5): `ps -o pgid= -p $PID` returns
    # rc 1 + empty if Chrome already died (instant exit). A bare $(…) would ABORT under
    # set -e; `|| true` keeps us alive, then `[[ -z ]]` converts "already dead" into a
    # clean pool_die with the log path so the operator can read Chrome's stderr.
    pgid="$(ps -o pgid= -p "$POOL_CHROME_PID" 2>/dev/null | tr -d ' ')" || true
    if [[ -z "$pgid" ]]; then
        # Chrome died before we could read its pgroup. Best-effort reap of the bare pid
        # (runs before BOTH exit paths below).
        kill "$POOL_CHROME_PID" 2>/dev/null || true
        # EADDRINUSE detection (Issue 2): if Chrome's log shows a port-bind failure,
        # return 1 (NON-FATAL, retryable) so _pool_launch_and_verify (S2) can re-pick a
        # port. This handles the instant-exit-with-EADDRINUSE edge case. NOTE: the
        # COMMON EADDRINUSE case (Chrome stays up, no CDP -> pool_wait_cdp 30s timeout)
        # is recovered by S2's port re-pick on the CDP-timeout path; THIS grep is the
        # defensive fast path for the instant-exit variant. The pattern matches Chrome's
        # "Cannot start http server for devtools" (devtools_http_handler.cc) + the
        # strerror "Address already in use" / "Bind failed" variants. (The `EADDRINUSE`
        # alternative is dead -- Chrome uses ERR_ADDRESS_IN_USE -- but harmless; kept per
        # the item contract.) `if grep` is errexit-exempt (rc 1 = no match = clean branch).
        if grep -qiE 'address already in use|bind.*failed|EADDRINUSE|cannot start http server|couldn.t bind' "$log_file" 2>/dev/null; then
            _pool_log "pool_chrome_launch: Chrome exited immediately (port $port may be in use); see log: $log_file"
            return 1
        fi
        # Genuine misconfiguration (broken binary / bad flags / corrupt profile) -- FATAL.
        pool_die "pool_chrome_launch: Chrome (pid $POOL_CHROME_PID) exited immediately;" \
                 "see log: $log_file"
    fi
    POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID

    # Observability: one line. _pool_log writes ISO-8601 + msg to the pool log + stderr.
    # (Best-effort: _pool_log never fails the caller — it falls back to stderr.)
    _pool_log "pool_chrome_launch: lane=$lane port=$port pid=$POOL_CHROME_PID pgid=$POOL_CHROME_PGID headless=$POOL_HEADLESS"

    return 0
}

# pool_wait_cdp PORT
#
# Poll Chrome's CDP HTTP endpoint (http://127.0.0.1:<PORT>/json/version) until it answers
# (HTTP 200 → curl -sf exits 0) or the budget is exhausted. Returns 0 if CDP is ready;
# returns 1 on timeout AFTER killing the Chrome process group (so a half-booted Chrome
# does not leak). NON-FATAL: never pool_die — the caller (M5.T1.S2) owns the PRD §2.14
# "retry launch once; then fail, drop lane" policy.
#
# LOGIC (CONTRACT 3b):
#   - loop up to 60 times (30s total): curl -sf http://127.0.0.1:<port>/json/version
#   - return 0 if CDP responds (curl rc 0)
#   - on timeout: kill -- -<POOL_CHROME_PGID> (if set + numeric), then return 1.
#
# CONSUMER: M5.T1.S2 acquire post-lock boot, called immediately after pool_chrome_launch.
#   CONTRACT: rc 0 → Chrome's CDP is ready, proceed to connect (M4.T3.S1); rc 1 → timed
#   out, Chrome pgroup already killed here, caller retries launch once then drops the lane.
#   Caller MUST guard under set -e: `if pool_wait_cdp "$port"; then …; else <retry path>; fi`.
#
# GOTCHA — 60×0.5s=30s (research §7): CONTRACT 3b ("Loop up to 60 times (30s total)") +
#   external_deps §2.2 (`seq 1 60`) agree; PRD §2.4 step 3h / §2.14 "15s" is a stale
#   summary. We use a bash (( )) counter (no seq fork). The budget is ONE named constant.
# GOTCHA — curl -sf exit codes: connection-refused (Chrome still booting) = rc 7 → keep
#   looping; HTTP 200 = rc 0 → ready. No --max-time needed (refused is instant); the bare
#   `curl -sf` matches external_deps §2.2 exactly.
# GOTCHA — kill -- -<pgid> needs the `--` (pgid is a positive int but the arg starts with
#   '-'). Guarded by a numeric check so pool_wait_cdp is safe to call standalone in tests
#   (no prior launch → POOL_CHROME_PGID unset → skip the kill, just return 1).
# GOTCHA — NON-FATAL (return 1, NOT pool_die): same family as pool_find_free_port.
# Reads only $1 (port) + the global POOL_CHROME_PGID (set by pool_chrome_launch). No writes
# beyond the process-group signal.
# PRECONDITION: pool_chrome_launch (for POOL_CHROME_PGID) when used in the real boot; none
#   required for a standalone timeout test (the pgid guard makes it safe).
# shellcheck disable=SC2034 # POOL_CDP_TRIES is the single tunable budget.
pool_wait_cdp() {
    local port="${1:-}"
    local i
    local -ri POOL_CDP_TRIES=60    # ×0.5s sleep = 30s budget (research §7; tunable)

    [[ "$port" =~ ^[0-9]+$ ]] || return 1   # bad port → non-fatal rc 1 (defensive)

    for (( i = 0; i < POOL_CDP_TRIES; i++ )); do
        if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done

    # Timeout — tear down the process group so a half-booted Chrome does not leak.
    # The numeric guard makes this safe when called without a prior pool_chrome_launch.
    if [[ "${POOL_CHROME_PGID:-}" =~ ^[0-9]+$ ]]; then
        kill -- -"$POOL_CHROME_PGID" 2>/dev/null || true
    fi
    return 1
}

# =============================================================================
# Lane lifecycle — daemon connect, verify & teardown (P1.M4.T3.S1)
# =============================================================================
# The three daemon/Chrome primitives of the pool: bind the shared agent-browser daemon
# to a pooled Chrome (connect), check that binding SIDE-EFFECT-FREE (connected), and tear
# down a Chrome's whole process tree idempotently (kill). Implements PRD §2.4 step 3i
# (CONNECT), step 4 (ENSURE CONNECTED — stray-free), §2.5/§2.10 (release = kill pgroup),
# §2.19 (kill -- -<pgid>), key_findings FINDING 6. Consumed by the acquire post-lock boot
# (M5.T1.S2), ensure_connected (M5.T1.S3), release (M5.T2.S1), and the reaper (M5.T3.*).

# pool_daemon_connect SESSION PORT
#
# Bind the agent-browser daemon session SESSION to the pooled Chrome on PORT by running
# `$POOL_REAL_BIN --session "$SESSION" connect "$PORT"`. Returns the subprocess rc:
# 0 on success (live chrome), 1 on failure (dead port / unreachable). NON-FATAL — never
# pool_die; the caller (M5.T1.S2) owns the retry policy.
#
# LOGIC (CONTRACT 3a, HOST-VERIFIED research §1):
#   - "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1
#   - return its rc (connect to live chrome → rc 0 + binds; connect to dead port → rc 1,
#     "All CDP discovery methods failed … Connection refused").
#
# CONSUMER: M5.T1.S2 acquire post-lock boot (PRD §2.4 step 3i), called right after
#   pool_wait_cdp succeeds. M5.T3.S2 reuse_orphan (re-bind an adopted session). CONTRACT:
#   rc 0 → session bound (caller writes connected:true); rc 1 → caller retries / drops.
#   Caller MUST guard under set -e: `if pool_daemon_connect …; then …`.
#
# GOTCHA — connect to a DEAD port is a CLEAN rc 1 (HOST-VERIFIED, research §1): agent-browser
#   prints "✗ All CDP discovery methods failed … Connection refused" and exits 1. It does
#   NOT launch anything. So pool_daemon_connect is safe to call speculatively.
# GOTCHA — connect is IDEMPOTENT / re-bindable (HOST-VERIFIED, research §1): re-running
#   connect on an already-bound session + same-live-port returns rc 0 (re-binds). Safe to
#   call in ensure_connected's reconnect path.
# GOTCHA — the daemon auto-starts on the first command of a session (researcher finding 12);
#   no explicit daemon-start is needed before connect.
# GOTCHA — the daemon is SHARED (FINDING 4): SESSION is an isolated binding in the shared
#   daemon; the pool's abpool-<N> namespace does not collide with existing manual sessions.
# Reads ONLY POOL_REAL_BIN (frozen by pool_config_init). Writes nothing.
# PRECONDITION: pool_config_init (for POOL_REAL_BIN).
pool_daemon_connect() {
    local session="${1:-}"
    local port="${2:-}"

    # Validate args (defensive, NON-FATAL rc 1 — never pool_die). `[[ ]] || return 1`
    # is errexit-exempt.
    [[ -n "$session" ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$POOL_REAL_BIN" ]] || return 1

    # Bind. >/dev/null 2>&1 — we only care about the rc. The daemon auto-starts if needed.
    # NOTE: do NOT add `|| true` here — we WANT to return the real rc (0 live / 1 dead).
    # The `command ; return $?` form is set -e safe (the command's non-zero does not abort
    # because it is the LAST statement before an explicit return; but be explicit):
    "$POOL_REAL_BIN" --session "$session" connect "$port" >/dev/null 2>&1 || return 1
    return 0
}

# pool_daemon_connected SESSION PORT
#
# Side-effect-free "is this lane's pooled Chrome connected/drivable?" check. Returns 0 if
# BOTH (1) the daemon knows about SESSION and (2) the pooled Chrome on PORT answers CDP;
# returns 1 otherwise. NON-FATAL — never pool_die, NEVER launches a Chrome.
#
# ⚠️ DEVIATES FROM THE LITERAL CONTRACT STEP 3b (research §2): the contract said
#   `get cdp-url >/dev/null 2>&1`, but on agent-browser 0.28.0 `get cdp-url` on a
#   disconnected/dead-chrome session AUTO-LAUNCHES a stray managed Chrome (verified: chrome
#   count 61→67) and ALWAYS returns rc 0 — so it can never report "not connected" AND it
#   leaks/strays. There is NO --no-launch flag (researcher confirmed). This function uses
#   TWO read-only, non-launching probes instead (research §3 + §4).
#
# LOGIC (HOST-VERIFIED research §3/§4/§6):
#   1. SESSION known to the daemon? `--json session list` is READ-ONLY (never launches);
#      absent ⇒ fresh/restarted daemon ⇒ return 1.
#   2. pooled Chrome on PORT alive? `curl -sf /json/version` never launches; dead ⇒ return 1
#      (PRD §2.14 Chrome crash — the primary failure).
#   3. both pass ⇒ return 0.
#
# WHY THE SIGNATURE ADDS PORT: the only reliable, stray-free signal for "connected" is the
# pooled Chrome's liveness (curl), which needs the port. SESSION is still used (step 1).
#
# CONSUMER: M5.T1.S3 ensure_connected (the HOT PATH — every invocation). CONTRACT:
#   rc 0 → lane drivable, proceed to exec; rc 1 → reconnect/relaunch. Recommended idiom:
#     pool_daemon_connected "$session" "$port" || pool_daemon_connect "$session" "$port"
#   ⚠️ This REPLACES the literal PRD §2.4 step 4 `get cdp-url || connect` (broken on 0.28.0).
#   Also M5.T3.S2 reuse_orphan (is the orphan's chrome responsive?).
#
# GOTCHA — get cdp-url is FORBIDDEN here (research §2 auto-launch trap). Read-only probes only.
# GOTCHA — session list is READ-ONLY but IMPRECISE after close (research §3): a session
#   LINGERS in the list after a disconnect-only close, so "in list" ≠ "currently bound".
#   Combined with the curl chrome-probe, the only imprecise case is right after a close
#   (lingering session + still-alive chrome → returns 0). Per PRD §2.8 that is INTENDED
#   ("next call reuses the same browser"); the §2.8 [OPEN — confirm] is M6.T1.S2's concern.
# GOTCHA — NON-FATAL (return 0/1, never pool_die): same family as pool_wait_cdp.
# GOTCHA — CALLERS under set -e MUST guard: `if pool_daemon_connected …; then …` or
#   `pool_daemon_connected … || <reconnect>`.
# Reads ONLY POOL_REAL_BIN (for `session list`). Writes nothing. Launches nothing.
# PRECONDITION: pool_config_init (for POOL_REAL_BIN).
pool_daemon_connected() {
    local session="${1:-}"
    local port="${2:-}"

    # Validate args (defensive, NON-FATAL rc 1).
    [[ -n "$session" ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$POOL_REAL_BIN" ]] || return 1

    # (1) Is SESSION known to the daemon? `session list` is READ-ONLY (never launches —
    #     research §3). `--json` → {"success":true,"data":{"sessions":[…]}}. jq -e exits 0
    #     iff index($session) is non-null (session present). The `if !` is errexit-exempt;
    #     a transient agent-browser/jq failure degrades to "not connected" (return 1) — SAFE
    #     (caller reconnects). 2>/dev/null keeps stderr clean.
    if ! "$POOL_REAL_BIN" --session "$session" --json session list 2>/dev/null \
            | jq -e --arg s "$session" '.data.sessions | index($s)' >/dev/null 2>&1; then
        return 1
    fi

    # (2) Is the pooled Chrome on PORT alive? curl /json/version is SIDE-EFFECT-FREE (never
    #     launches — research §4). rc 0 = HTTP 200 = alive; non-zero = dead/unreachable.
    #     `|| return 1` is errexit-exempt. curl -sf: -s silent, -f fail-on-HTTP-error.
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || return 1

    # (3) Session known + chrome alive ⇒ connected/drivable.
    return 0
}

# pool_chrome_kill CHROME_PID CHROME_PGID
#
# Tear down a pooled Chrome's ENTIRE process tree idempotently: SIGTERM the process group,
# wait briefly, SIGKILL the group, then a bare-pid fallback. Safe to call on already-dead
# processes (every kill is `2>/dev/null || true`) and on provisional-lease args
# (CHROME_PID=0 / CHROME_PGID=0 are skipped). Returns 0 ALWAYS (teardown must never fail
# the caller). NON-FATAL — never pool_die. Does NOT touch the daemon session (Chrome-only).
#
# LOGIC (CONTRACT 3c, HOST-VERIFIED research §5):
#   - Primary:  kill -- -"$chrome_pgid" 2>/dev/null || true       (SIGTERM the pgroup)
#   - Wait:     sleep 0.5                                              (let stragglers exit)
#   - Force:    kill -9 -- -"$chrome_pgid" 2>/dev/null || true       (SIGKILL the pgroup)
#   - Fallback: kill   "$chrome_pid" 2>/dev/null || true             (bare pid, if pgid
#               kill -9 "$chrome_pid" 2>/dev/null || true              missed the leader)
#   Numeric guards: skip pgid/pid <= 0 (provisional lease) or non-numeric.
#
# CONSUMER: M5.T2.S1 release + M5.T3.S1 reap_stale (per-lane teardown, reading
#   chrome_pid/chrome_pgid from the lease). CONTRACT: rc 0 always; the whole tree is gone
#   (0 orphans) on return. Idempotent — safe in reap loops over many (possibly-dead) lanes.
#
# GOTCHA — kill on an ALREADY-DEAD target returns rc 1 (ESRCH) → ABORTS under set -e
#   (lib/pool.sh line 17 `set -euo pipefail`). EVERY kill MUST be `… 2>/dev/null || true`.
#   This IS the idempotency mechanism (no kill -0 pre-check). HOST-VERIFIED (research §5).
# GOTCHA — `kill -- -<pgid>` needs the `--` (pgid is positive but the arg starts with '-').
#   The negative-pid form signals the whole process group (renderer/GPU/utility children).
#   PRD §2.19 + key_findings FINDING 6.
# GOTCHA — numeric guards: a PROVISIONAL lease writes chrome_pid=0, chrome_pgid=0 (PRD §2.4
#   step 3d). Guard `[[ =~ ^[0-9]+$ && -gt 0 ]]` so pool_chrome_kill 0 0 is a safe no-op.
# GOTCHA — SIGTERM → sleep 0.5 → SIGKILL escalation is sound (research §5): Chrome responds
#   to SIGTERM but renderer/GPU/utility children can lag; the 0.5 s grace then SIGKILL
#   catches stragglers. Verified 0 orphans after escalation.
# GOTCHA — the bare-pid fallback covers a pgid of 0 (provisional) OR a missed group leader;
#   it is NOT a substitute for the group kill (which catches children the bare pid misses).
# GOTCHA — Chrome-teardown ONLY: do NOT call `agent-browser --session <name> close` here.
#   Daemon/session disconnect is the wrapper's close interception (M6.T1.S2) + release's
#   lease-delete (M5.T2.S1). Scope: kill the Chrome tree.
# GOTCHA — do NOT confuse with pool_wait_cdp's inline single-SIGKILL (M4.T2.S2, CDP-timeout
#   cleanup). This is the CANONICAL thorough teardown for release/reap. They coexist; do
#   NOT refactor pool_wait_cdp.
# Reads NO globals (args only). Writes nothing. Returns 0 always.
pool_chrome_kill() {
    local chrome_pid="${1:-}"
    local chrome_pgid="${2:-}"

    # Primary + force: signal the PROCESS GROUP (negative pid). Numeric guard: skip
    # non-numeric or <= 0 (provisional lease pgid=0). SIGTERM (default) → grace → SIGKILL.
    if [[ "$chrome_pgid" =~ ^[0-9]+$ ]] && (( chrome_pgid > 0 )); then
        kill -- -"$chrome_pgid" 2>/dev/null || true    # SIGTERM the whole pgroup
        sleep 0.5                                     # let renderer/GPU/utility children exit
        kill -9 -- -"$chrome_pgid" 2>/dev/null || true # SIGKILL any stragglers
    fi

    # Fallback: bare pid (covers pgid=0 / missed leader). Numeric guard as above.
    if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
        kill   "$chrome_pid" 2>/dev/null || true      # SIGTERM the leader
        kill -9 "$chrome_pid" 2>/dev/null || true      # SIGKILL the leader
    fi

    return 0
}

# =============================================================================
# Acquire — flock critical section (P1.M5.T1.S1)
# =============================================================================
# The flock-guarded acquire critical section: REAP-STALE + REUSE-ORPHAN + CHOOSE-N +
# CLAIM (PRD §2.4 step 3a–3d). Implements key_findings FINDING 2 (claim under the SHORT
# flock, boot Chrome AFTER releasing — no launch/copy/wait inside the lock) + §2.9
# (rc 1 ⇒ exhaustion → M5.T4) + §2.10 (lazy reaper on acquire) + §2.19 (atomic lease
# writes). Consumed by the acquire post-lock boot (M5.T1.S2) and the exhaustion loop
# (M5.T4). The private release kernel (_pool_release_lane_internals) is ALSO composed by
# M5.T2.S1's public pool_release_lane and M5.T3.S1's reap (shared teardown path).

# _pool_release_lane_internals LANE
#
# The release KERNEL: tear down one lane's Chrome + ephemeral dir + lease. Idempotent +
# NON-FATAL (return 0 always; every kill/rm `2>/dev/null || true`; a missing/corrupt lease
# is a clean no-op). Called by _pool_acquire_critical_section's REAP-STALE step (3a) for
# each non-adoptable stale lane, AND (by contract) by M5.T2.S1 pool_release_lane +
# M5.T3.S1 reap_stale.
#
# LOGIC:
#   1. pool_lease_read "$lane" → JSON (rc 1 = missing/corrupt → return 0, nothing to release).
#   2. ONE jq fork: extract .chrome_pid, .chrome_pgid, .ephemeral_dir.
#   3. pool_chrome_kill "$chrome_pid" "$chrome_pgid"  (idempotent; handles 0/0 provisional).
#   4. rm -rf the ephemeral dir — RECONSTRUCTED as "$POOL_EPHEMERAL_ROOT/$lane" AND guarded
#      ([[ -n && == "$POOL_EPHEMERAL_ROOT"/* ]]) before any rm (NEVER rm an arbitrary lease path).
#   5. rm -f "$POOL_LANES_DIR/$lane.json"  (the lease file).
#   return 0.
#
# GOTCHA — idempotent + non-fatal: runs in the reap loop over many lanes; one already-dead
#   lane must NEVER abort the pool under set -e. pool_lease_read rc 1 ⇒ return 0.
# GOTCHA — rm -rf SAFETY: reconstruct the dir from the lane number + POOL_EPHEMERAL_ROOT
#   (don't trust the lease's ephemeral_dir field) AND prefix-guard. research §6.
# GOTCHA — pool_chrome_kill already self-guards 0/0 (provisional lease) + every kill || true.
# Reads POOL_EPHEMERAL_ROOT + POOL_LANES_DIR (frozen). Writes: signals + rm + lease delete.
# PRECONDITION: pool_config_init.
_pool_release_lane_internals() {
    local lane="${1:-}"
    local json chrome_pid chrome_pgid ephemeral_dir dir
    local -a _f

    # Validate lane (path-traversal defense; a bogus lane "has nothing to release").
    [[ "$lane" =~ ^[0-9]+$ ]] || return 0

    # (1) Read the lease. rc 1 (missing OR corrupt) → nothing to release → return 0.
    #     `if !` is errexit-exempt (a bare capture would ABORT under set -e on rc 1).
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
        return 0
    fi

    # (2) ONE jq fork: extract the fields _pool_acquire needs. Comma → 3 lines; mapfile -t
    #     strips trailing newlines. jq cannot fail here (valid JSON guaranteed by
    #     pool_lease_read's _pool_json_valid pre-check); the herestring is in-memory.
    mapfile -t _f < <(jq -r '.chrome_pid, .chrome_pgid, .ephemeral_dir' <<<"$json")
    chrome_pid="${_f[0]:-}"
    chrome_pgid="${_f[1]:-}"
    ephemeral_dir="${_f[2]:-}"

    # (3) Kill the Chrome process group (idempotent; handles 0/0 provisional lease).
    pool_chrome_kill "$chrome_pid" "$chrome_pgid"

    # (4) rm -rf the ephemeral dir — RECONSTRUCT from lane + POOL_EPHEMERAL_ROOT (do NOT
    #     trust the lease's ephemeral_dir), AND prefix-guard. Defense-in-depth: even a
    #     corrupt/hostile lease cannot make us rm an arbitrary path. `|| true` for safety.
    dir="$POOL_EPHEMERAL_ROOT/$lane"
    if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
        rm -rf -- "$dir" 2>/dev/null || true
    fi
    # (Defense-in-depth: if the lease's ephemeral_dir DIFFERS from the reconstructed path
    #  and is a distinct valid sub-tree under POOL_EPHEMERAL_ROOT, remove it too — covers a
    #  historical layout change. Same guard.)
    if [[ -n "$ephemeral_dir" && "$ephemeral_dir" == "$POOL_EPHEMERAL_ROOT"/* \
          && "$ephemeral_dir" != "$POOL_EPHEMERAL_ROOT/" && "$ephemeral_dir" != "$dir" ]]; then
        rm -rf -- "$ephemeral_dir" 2>/dev/null || true
    fi

    # (5) Delete the lease file. `|| true` (already-deleted / TOCTOU).
    rm -f -- "$POOL_LANES_DIR/$lane.json" 2>/dev/null || true

    _pool_log "pool_acquire(reap): released stale lane $lane (chrome_pid=${chrome_pid:-0})"
    return 0
}

# _pool_adopt_lane LANE
#
# REUSE-ORPHAN adoption (PRD §2.4 step 3b / IQ4): reassign a responsive-but-orphaned lane's
# owner to the CURRENT claimer, mark connected, and re-bind the daemon. Called by
# _pool_acquire_critical_section when a STALE lane has a RESPONSIVE Chrome
# (pool_daemon_connected == 0). Skips the copy/launch (the Chrome is already running).
#
# LOGIC:
#   1. pool_lease_read "$lane" → JSON (rc 1 ⇒ return 1, can't adopt a missing lease).
#   2. Extract .port + .session (for the daemon re-bind).
#   3. jq mutate: .owner = {pid,comm,starttime,cwd from POOL_OWNER_*} | .connected = true
#      | .last_seen_at = $(_pool_now). Inject-safe (--arg/--argjson DATA, fixed filter).
#   4. _pool_atomic_write the mutated JSON back to the lease file (tmp+mv, same FS).
#   5. pool_daemon_connect "$session" "$port" — re-bind the daemon to the (still-running)
#      Chrome. rc 0 ⇒ return 0 (adopted). rc 1 ⇒ the Chrome died between the responsiveness
#      probe and now → return 1 (caller will REAP it instead).
#
# WHY A DIRECT jq MUTATION (not pool_lease_update): pool_lease_update is TOP-LEVEL FIELD ONLY
#   and CANNOT touch the nested .owner sub-object (M3.T1.S1 docstring: "owner is written
#   once at acquire, never mutated"). Adoption is the ONE deliberate owner mutation. The jq
#   `.owner = {…} | .connected = true | .last_seen_at = $now` filter is inject-safe (all
#   values are --arg/--argjson DATA, never spliced into the program). research §4.
#
# GOTCHA — the responsiveness probe (pool_daemon_connected) runs in the CALLER BEFORE this;
#   this function only does the REASSIGN + RE-BIND. A race where the Chrome dies between the
#   probe and pool_daemon_connect is handled by connect returning rc 1 ⇒ caller reaps.
# GOTCHA — `connected` MUST be a JSON boolean (true), not the number 1. pool_daemon_connect
#   is an ATTACH (~ms) — safe inside the lock (research §2); it is NOT a Chrome launch.
# GOTCHA — owner reassignment writes the CURRENT POOL_OWNER_* identity (the adopter), so the
#   lane is now "mine" and survives pool_lane_is_stale for the adopter.
# NON-FATAL (return 0 adopted / 1 Chrome-died-mid-adopt). Reads POOL_OWNER_* + POOL_LANES_DIR.
# PRECONDITION: pool_config_init + pool_owner_resolve.
_pool_adopt_lane() {
    local lane="${1:-}"
    local json port session now updated_lease

    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
        return 1   # can't adopt a missing/corrupt lease
    fi

    # Extract port + session for the re-bind. PLAIN assignment (not local x=$(…)) so jq's
    # exit status is preserved — but jq cannot fail on valid JSON; guard anyway.
    port="$(jq -r '.port' <<<"$json")"
    session="$(jq -r '.session' <<<"$json")"

    # Validate the owner identity globals are present (defensive; pool_owner_resolve sets them).
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ ]] || return 1

    # Mutate: rewrite .owner to the CURRENT claimer, set connected=true, stamp last_seen_at.
    # All values enter jq as DATA (--arg/--argjson) → inject-safe. starttime/cwd via --arg
    # (strings) OR --argjson (numbers) — starttime is digits → --argjson; cwd/comm → --arg.
    now="$(_pool_now)"
    if ! updated_lease="$(jq \
            --argjson now "$now" \
            --argjson pid "$POOL_OWNER_PID" \
            --arg comm "$POOL_OWNER_COMM" \
            --argjson starttime "${POOL_OWNER_STARTTIME:-0}" \
            --arg cwd "${POOL_OWNER_CWD:-}" \
            '.owner = {pid:$pid, comm:$comm, starttime:$starttime, cwd:$cwd}
             | .connected = true
             | .last_seen_at = $now' \
            <<<"$json" 2>/dev/null)"; then
        return 1   # jq build failure — caller reaps
    fi

    # Atomic publish (tmp+mv same dir = same FS). _pool_atomic_write pool_die's on a real
    # FS failure (exceptional); that exits the subshell → flock released → propagates.
    _pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$updated_lease"

    # Re-bind the daemon to the (still-running) Chrome. An ATTACH — safe inside the lock.
    # rc 1 ⇒ Chrome died between the probe and now ⇒ tell the caller to reap (return 1).
    if ! pool_daemon_connect "$session" "$port"; then
        return 1
    fi

    _pool_log "pool_acquire(adopt): reused orphan lane $lane (port=$port, owner pid=$POOL_OWNER_PID)"
    return 0
}

# _pool_acquire_critical_section
#
# THE FLOCK BODY — runs inside `( flock 9; <this> ) 9>"$POOL_LOCK_FILE"`. A FUNCTION (so it
# can `return` and inherit all globals). Performs PRD §2.4 step 3a–3d:
#   a. REAP-STALE + REUSE-ORPHAN (interleaved per lane): for each lane, pool_lane_is_stale
#      rc 0 (stale) → if pool_daemon_connected(session,port)==0 (responsive Chrome) → ADOPT
#      (_pool_adopt_lane; echo N; return 0); else REAP (_pool_release_lane_internals).
#      rc 1 (live) / rc 2 (no lease) → skip.
#   c. CHOOSE-N: pool_find_free_lane → N (always echoes + rc 0; set -e safe).
#   d. CLAIM: pool_lease_write(N, ephemeral_dir, 0, abpool-N, owner..., 0, 0, "false").
#   echo N; return 0.  Fall-through (POOL_OWNER_PID==0 OR no free lane) → return 1.
#
# OUTPUT: echoes the claimed/adopted lane N on success (return 0); echoes nothing on
# exhaustion (return 1). The CALLER distinguishes provisional (port:0/connected:false → S2
# boots) vs adopted (port>0/connected:true → S3 ensures) by reading the lease. research §5.
#
# GOTCHA — TRI-STATE pool_lane_is_stale: `if pool_lane_is_stale "$n"; then …; fi` runs the
#   body on rc 0 (stale) only; rc 1 (live) / rc 2 (no-lease) fall through. A BARE call
#   ABORTS under set -e on rc 1/2.
# GOTCHA — reuse-orphan uses pool_daemon_connected (read-only, NEVER launches — P1.M4.T3.S1
#   research §2 forbids get cdp-url). Only port>0 lanes can be orphans (provisional port=0
#   has no Chrome yet → always reaped, never adopted).
# GOTCHA — POOL_OWNER_PID==0 ⇒ return 1 (a passthrough owner must not claim; defense-in-depth).
# GOTCHA — _pool_adopt_lane return 1 (Chrome died mid-adopt) ⇒ fall through to REAP that lane.
# Reads POOL_OWNER_*, POOL_EPHEMERAL_ROOT, POOL_LANES_DIR. Non-fatal on exhaustion (rc 1).
# PRECONDITION: pool_config_init + pool_owner_resolve (+ pool_state_init by the wrapper).
_pool_acquire_critical_section() {
    local n port session N ephemeral_dir

    # Defensive: a passthrough owner (no pi ancestor → POOL_OWNER_PID==0) must NOT claim a
    # lane (it would be immediately stale to everyone). The wrapper gates passthrough BEFORE
    # acquire in M6; this is defense-in-depth. `[[ ]] || return 1` is errexit-exempt.
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1

    # (a/b) REAP-STALE + REUSE-ORPHAN, interleaved per lane in ascending order.
    for n in $(pool_lanes_list); do
        # TRI-STATE capture: pool_lane_is_stale 0=stale / 1=live / 2=no-lease.
        # `if …; then` runs the body on rc 0 (stale) only; rc 1/2 fall through (skip).
        if pool_lane_is_stale "$n"; then
            # Stale. Is it an ORPHAN (responsive Chrome)? Only lanes with a real port can be.
            port="$(pool_lease_field "$n" port 2>/dev/null)" || port=""
            session="$(pool_lease_field "$n" session 2>/dev/null)" || session=""
            if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
               && pool_daemon_connected "$session" "$port"; then
                # REUSE-ORPHAN: adopt. If adoption succeeds → we're DONE (return this lane).
                # If adoption fails (Chrome died mid-adopt) → fall through to reap it.
                if _pool_adopt_lane "$n"; then
                    printf '%s\n' "$n"
                    return 0
                fi
            fi
            # REAP-STALE: not adoptable (or adoption failed) → release the lane's resources.
            _pool_release_lane_internals "$n"
        fi
    done

    # (c) CHOOSE-N: lowest free lane. Always echoes + rc 0 → bare capture is set -e safe.
    N="$(pool_find_free_lane)"

    # (d) CLAIM: write the PROVISIONAL lease (port=0, chrome_pid=0, chrome_pgid=0,
    #     connected=false, owner=current). pool_lease_write validates connected ∈
    #     {"true","false"} + builds via jq + publishes atomically. A build/FS failure
    #     pool_die's → exits the subshell → flock released → propagates (exceptional).
    ephemeral_dir="$POOL_EPHEMERAL_ROOT/$N"
    pool_lease_write "$N" "$ephemeral_dir" 0 "abpool-$N" \
        "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "${POOL_OWNER_STARTTIME:-0}" "${POOL_OWNER_CWD:-}" \
        0 0 "false"

    _pool_log "pool_acquire(claim): provisional lane $N for owner pid=$POOL_OWNER_PID"
    printf '%s\n' "$N"
    return 0
}

# pool_acquire_locked
#
# PUBLIC ENTRY POINT — acquire a lane under an exclusive flock on $POOL_LOCK_FILE. Runs
# _pool_acquire_critical_section inside the canonical `( flock 9; body ) 9>file` subshell
# (key_findings FINDING 2; flock(1) man-page-recommended shell form). The lock is held ONLY
# for scan+reap+reuse+choose+claim (NO Chrome launch/copy/wait — those are S2, post-lock).
#
# Echoes the claimed/adopted lane N + return 0 on success; echoes nothing + return 1 on
# exhaustion (all lanes live / passthrough owner) → M5.T4. The lock auto-releases on return
# (incl. pool_die/SIGKILL — the kernel closes fd 9 on subshell exit; research §1.2).
#
# CALLER CONTRACT (under set -e — split the capture per BashFAQ 105):
#     local N
#     if N="$(pool_acquire_locked)"; then
#         port="$(pool_lease_field "$N" port)"
#         if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
#             <S2 post-lock boot: copy→port→launch→connect→update lease>
#         else
#             <S3 adopted: ensure_connected only; skip the boot>
#         fi
#     else
#         <M5.T4 exhaustion: block-with-timeout / force-reap / alert>
#     fi
#
# GOTCHA — `local N; N="$(pool_acquire_locked)"` MUST be split: `local N=$(…)` masks errexit
#   (local returns 0). research §1.5 / BashFAQ 105.
# GOTCHA — pool_state_init is called first so `9>"$POOL_LOCK_FILE"` cannot fail on a missing
#   parent dir (idempotent; pool_die only on a real FS error).
# Reads POOL_LOCK_FILE (+ everything _pool_acquire_critical_section reads). No new globals.
# PRECONDITION: pool_config_init + pool_owner_resolve (+ pool_state_init, called here).
pool_acquire_locked() {
    # Ensure the lock file + lanes dir exist (idempotent) so the fd-9 redirect opens cleanly.
    pool_state_init

    # The canonical flock idiom. fd 9 is opened on POOL_LOCK_FILE; `flock 9` (blocking,
    # returns 0) acquires the exclusive lock; the body function runs (inherited — it's a
    # subshell fork); the subshell's exit status == the function's return code; stdout (echo
    # N) propagates to the caller's $(…). The lock is released when the subshell exits.
    (
        flock 9
        _pool_acquire_critical_section
    ) 9>"$POOL_LOCK_FILE"
}

# =============================================================================
# Acquire — post-lock boot (P1.M5.T1.S2)
# =============================================================================
# Turn a PROVISIONALLY-claimed lane (port=0, from pool_acquire_locked / M5.T1.S1) into a
# FULLY-provisioned lane: copy master → pick port → launch Chrome → wait CDP → bind daemon
# → finalize lease. PRD §2.4 step 3e–3j, run OUTSIDE the flock (key_findings FINDING 2:
# concurrent boots). PRD §2.14 failure handling: CDP-timeout → retry launch once → drop
# lane. Every recoverable failure cleans up via _pool_release_lane_internals (M5.T1.S1)
# and returns 1. Consumed by the wrapper lifecycle (M6.T3.S1) after pool_acquire_locked
# returns a provisional lane. The launch+wait sub-flow (_pool_launch_and_verify) is ALSO
# composed by M5.T1.S3 ensure_connected for a Chrome mid-task crash relaunch.

# _pool_boot_write_chrome_ids LANE
#
# Write the POOL_CHROME_PID / POOL_CHROME_PGID globals (set by pool_chrome_launch) into the
# lease for LANE as top-level chrome_pid / chrome_pgid. Called right after EACH launch (incl.
# the retry in _pool_launch_and_verify) — NOT only at step f. This is the LEAK-PREVENTION
# refinement (research §2):
#   (1) _pool_release_lane_internals reads chrome_id FROM THE LEASE → with this early write
#       it correctly kills the LIVE Chrome on the daemon-connect-fail path (step e). Without
#       it, cleanup would read chrome_pid:0 → pool_chrome_kill 0 0 (no-op) → LEAK.
#   (2) if pool_boot_lane is killed mid-way, the lazy reaper (M5.T3) reads the lease and
#       tears the Chrome down — impossible if chrome_id is still 0.
# Uses pool_lease_update (top-level field; value = raw JSON number via --argjson). The lease
# exists (provisional from S1); a missing/corrupt lease would pool_die (exceptional).
#
# GOTCHA — reference the globals with ${…:-} (set -u safe before any launch).
# Reads POOL_CHROME_PID/PGID (+ POOL_LANES_DIR via pool_lease_update). No new globals.
# PRECONDITION: pool_chrome_launch just succeeded (both globals set).
_pool_boot_write_chrome_ids() {
    local lane="${1:-}"
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1
    pool_lease_update "$lane" chrome_pid "${POOL_CHROME_PID:-0}"
    pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"
}

# _pool_launch_and_verify PORT EPHEMERAL_DIR LANE
#
# The launch + CDP-wait + RETRY-ONCE sub-flow with PORT RE-PICK (Issue 2 / S2). Returns 0
# if Chrome's CDP endpoint answers — possibly after re-picking a DIFFERENT port on a launch
# or CDP failure; returns 1 if all retries (2 same-port + 1 re-picked-port) are exhausted.
# PRD §2.14 "Chrome slow to boot → retry launch once; then fail, drop lane", generalized by
# Issue 2 to re-pick a port then retry once. Composed by pool_boot_lane (step c+d); pool_boot_lane
# re-reads the lease port after a successful call so a re-picked port flows to the daemon connect.
#
# LOGIC:
#   1. Attempt 1 (same port): `if pool_chrome_launch "$port" …; then` — rc 1 (EADDRINUSE,
#      detected by S1) → fall through to the re-pick (step 5). rc 0 → write_chrome_ids +
#      pool_wait_cdp "$port": rc 0 → return 0; rc 1 (Chrome pgroup already killed) → attempt 2.
#   2. Attempt 2 (same-port retry — PRD §2.14): `if pool_chrome_launch "$port" …; then` —
#      rc 1 → fall through to the re-pick. rc 0 → write_chrome_ids + pool_wait_cdp "$port":
#      rc 0 → return 0; rc 1 → fall through to the re-pick (both same-port attempts failed).
#   3. (Re-pick trigger paths: attempt-1 launch rc 1, attempt-2 launch rc 1, OR both CDP
#      timeouts — all fall through to step 5.)
#   4. (The Issue-#6 log-preserve: attempt-1's chrome-<lane>.log is renamed to .attempt1.log
#      before attempt 2's launch truncates it — only when attempt 1 ran.)
#   5. PORT RE-PICK (ONE retry, no loop — Issue 2 / S2): `if ! new_port="$(pool_find_free_port)"`;
#      rc 1 (exhausted) → return 1. Else pool_lease_update "$lane" port "$new_port"; then
#      `if ! pool_chrome_launch "$new_port" …; then return 1; fi`; write_chrome_ids;
#      pool_wait_cdp "$new_port": rc 0 → return 0; rc 1 → return 1.
#
# GOTCHA — pool_chrome_launch rc 1 (EADDRINUSE — S1) is NON-FATAL and triggers the re-pick;
#   only pool_die (genuine misconfig: broken binary / bad flags / non-EADDRINUSE instant-exit)
#   propagates as fatal. Both launch calls are guarded with `if …; then` so a return-1 does
#   NOT abort under set -e (it falls through to the re-pick).
# GOTCHA — the re-pick updates the LEASE port (pool_lease_update). pool_boot_lane MUST re-read
#   it (pool_lease_field) after this returns 0, or the daemon connect uses the stale $port.
# GOTCHA — ONE re-pick only (no loop): the re-pick block is reached at most once per call.
# GOTCHA — the retry/re-pick overwrites POOL_CHROME_PID/PGID (and the lease chrome-ids) with
#   the latest Chrome's identity, so a subsequent cleanup reads the correct pid.
# GOTCHA — pool_wait_cdp ALREADY kills the pgroup on timeout; do NOT add a redundant kill.
# NON-FATAL on the failure paths (return 1). No new globals exported (new_port is local).
# PRECONDITION: pool_config_init + pool_state_init + a PROVISIONAL lease for LANE (port>0,
#   written by pool_boot_lane step b — pool_find_free_port + pool_lease_update rely on it).
_pool_launch_and_verify() {
    local port="${1:-}"
    local ephemeral_dir="${2:-}"
    local lane="${3:-}"
    local new_port

    # Validate args (defensive; the caller already validated, but be safe).
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || return 1
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    # --- Attempt 1 (same port) ---
    # Guard pool_chrome_launch (Issue 2 / S1): rc 1 = EADDRINUSE detected on instant-exit
    # (retryable) → fall through to the port re-pick below. rc 0 → write chrome-ids + wait
    # for CDP. (A pool_die from pool_chrome_launch — genuine misconfig — still propagates.)
    if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then
        _pool_boot_write_chrome_ids "$lane"                    # globals → lease (§2)
        if pool_wait_cdp "$port"; then
            return 0
        fi
        # pool_wait_cdp rc 1 ⇒ Chrome pgroup ALREADY KILLED (research §1.3). Retry once on
        # the SAME port (PRD §2.14) before re-picking a different port.
        # PRESERVE attempt 1's diagnostic log (Issue #6): pool_chrome_launch opens
        # $POOL_STATE_DIR/chrome-<lane>.log with `>` (truncate). On retry that would DESTROY
        # the first Chrome's stderr — exactly the output most useful for diagnosing why the
        # first boot failed. Rename attempt-1's log aside first so the second launch's
        # truncate only clears the (now-empty) live log, and the first attempt's output
        # survives for post-mortem. Best-effort (`|| true`): a missing/empty log is not fatal.
        if [[ -f "$POOL_STATE_DIR/chrome-$lane.log" ]]; then
            mv -f -- "$POOL_STATE_DIR/chrome-$lane.log" \
                    "$POOL_STATE_DIR/chrome-$lane.attempt1.log" 2>/dev/null || true
            _pool_log "_pool_launch_and_verify: preserved attempt-1 log: $POOL_STATE_DIR/chrome-$lane.attempt1.log"
        fi
        # --- Attempt 2 (same-port retry — PRD §2.14) ---
        if pool_chrome_launch "$port" "$ephemeral_dir" "$lane"; then
            _pool_boot_write_chrome_ids "$lane"                # 2nd chrome-ids → lease
            if pool_wait_cdp "$port"; then
                return 0
            fi
        fi
    fi

    # --- Port re-pick (ONE retry with a DIFFERENT port; Issue 2 / S2) ---
    # Reached when (a) pool_chrome_launch returned 1 (EADDRINUSE — S1) on attempt 1 or 2, OR
    # (b) both same-port CDP-timeout attempts failed. pool_find_free_port excludes ports
    # already claimed by leases (incl. our current $port, written by pool_boot_lane step b),
    # so the new port is guaranteed different from the colliding one. ONE re-pick only —
    # do NOT loop. On exhaustion or retry failure, return 1 (caller drops the lane).
    if ! new_port="$(pool_find_free_port)"; then
        _pool_log "_pool_launch_and_verify: no free port to re-pick for lane $lane; giving up"
        return 1
    fi
    # Update the lease so pool_boot_lane's daemon connect (step e) uses the real bound port,
    # and so a concurrent pool_find_free_port sees this port claimed too.
    pool_lease_update "$lane" port "$new_port"
    _pool_log "_pool_launch_and_verify: re-picked port $new_port for lane $lane (was $port)"
    # Retry launch + wait on the new port. pool_chrome_launch rc 1 here = EADDRINUSE again
    # → do NOT loop (one re-pick only) → return 1.
    if ! pool_chrome_launch "$new_port" "$ephemeral_dir" "$lane"; then
        return 1
    fi
    _pool_boot_write_chrome_ids "$lane"
    if pool_wait_cdp "$new_port"; then
        return 0
    fi
    return 1
}

# pool_boot_lane LANE
#
# PUBLIC ENTRY POINT (the CONTRACT name). Provision a lane: COPY master → PORT →
# LAUNCH+WAIT (retry once) → CONNECT → finalize LEASE. PRD §2.4 step 3e–3j, OUTSIDE the
# flock (key_findings FINDING 2 — concurrent boots; this function does NO locking). Input:
# a PROVISIONAL lease for LANE (port=0, from pool_acquire_locked). Output: lane fully
# provisioned (return 0) OR cleaned up (return 1).
#
# Recoverable failures (→ _pool_release_lane_internals + return 1):
#   - step b: pool_find_free_port rc 1 (port range exhausted) — no Chrome yet.
#   - step d: _pool_launch_and_verify rc 1 (CDP timed out twice) — Chrome already killed.
#   - step e: pool_daemon_connect rc 1 (daemon bind failed) — LIVE Chrome killed via cleanup
#     (chrome_id is in the lease from step c's early write → no leak).
# Fatal failures (pool_die propagates — genuine misconfiguration; provisional lease self-heals
# via the next acquire's REAP-STALE):
#   - step a: pool_copy_master non-btrfs / slow-copy-fail.
#   - step c: pool_chrome_launch instant-exit (broken binary / bad flags).
#
# CALLER CONTRACT (the wrapper M6.T3.S1, under set -e — split the capture per BashFAQ 105):
#     local N
#     if N="$(pool_acquire_locked)"; then
#         local port
#         port="$(pool_lease_field "$N" port)"
#         if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
#             pool_boot_lane "$N" || <retry acquire / M5.T4 exhaustion>
#         else
#             <M5.T1.S3 adopted: ensure_connected only; skip the boot>
#         fi
#     else
#         <M5.T4 exhaustion>
#     fi
#
# GOTCHA — the chrome-id early write (step c, inside _pool_launch_and_verify) is what makes
#   the step-e cleanup able to kill the LIVE Chrome. Never reorder it to step f (§2).
# GOTCHA — step b writes port to the lease BEFORE launch (anti-collision — §4).
# GOTCHA — `local PORT; PORT="$(…)"` MUST be split (BashFAQ 105 / SC2155).
# GOTCHA — every recoverable failure → `_pool_release_lane_internals "$LANE"` then
#   return 1. Do NOT write your own kill/rm here.
# Reads POOL_EPHEMERAL_ROOT, POOL_LANES_DIR (via helpers), POOL_REAL_BIN (via
# pool_daemon_connect), POOL_CHROME_PID/PGID (via _pool_boot_write_chrome_ids). No new globals.
# PRECONDITION: pool_config_init + pool_state_init + a PROVISIONAL lease for LANE (from S1).
pool_boot_lane() {
    local lane="${1:-}"
    local ephemeral_dir port now

    # Validate lane.
    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_boot_lane: lane must be a non-negative integer, got: '$lane'"

    ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"

    # --- a. COPY: reflink CoW copy of the master → ephemeral dir (PRD §2.4 step 3e / §2.7). ---
    #     pool_die's (fatal) on non-btrfs/no-slow-copy — propagates (genuine misconfiguration).
    pool_copy_master "$ephemeral_dir"

    # --- b. PORT: lowest free TCP port (PRD §2.4 step 3f). ---
    #     rc 1 = range exhausted (NON-FATAL). Split the capture (BashFAQ 105). On failure,
    #     clean up (the dir was just copied) + return 1.
    if ! port="$(pool_find_free_port)"; then
        _pool_log "pool_boot_lane: port range exhausted for lane $lane; dropping lane"
        _pool_release_lane_internals "$lane"
        return 1
    fi
    # Anti-collision: write port to the lease BEFORE launch so concurrent pool_find_free_port
    # calls see it claimed (research §4). pool_lease_update splices the value as raw JSON.
    pool_lease_update "$lane" port "$port"

    # --- c+d. LAUNCH + WAIT (retry once on CDP timeout) (PRD §2.4 step 3g/3h / §2.14). ---
    #     _pool_launch_and_verify returns 0 (CDP ready — possibly after a port re-pick — Issue 2/S2)
    #     or 1 (all retries exhausted; Chrome killed). On failure, clean up + return 1.
    if ! _pool_launch_and_verify "$port" "$ephemeral_dir" "$lane"; then
        _pool_log "pool_boot_lane: CDP not ready after retry for lane $lane port $port; dropping lane"
        _pool_release_lane_internals "$lane"
        return 1
    fi
    # _pool_launch_and_verify may have re-picked a different port on a launch/CDP failure (Issue 2 / S2)
    # and updated the lease; re-read the authoritative port so the daemon connect (step e) + the
    # provisioned log (step f) use the REAL bound port, not the stale local $port. Guarded: a
    # failed re-read (truly exceptional — corrupt lease mid-boot) keeps the original $port.
    local reread_port
    reread_port="$(pool_lease_field "$lane" port 2>/dev/null)" || true
    if [[ "$reread_port" =~ ^[0-9]+$ && "$reread_port" -gt 0 ]]; then
        port="$reread_port"
    fi

    # --- e. CONNECT: bind the daemon session to the Chrome (PRD §2.4 step 3i). ---
    #     rc 1 = NON-FATAL (dead/unreachable). The Chrome is ALIVE here (CDP just answered) —
    #     _pool_release_lane_internals kills it correctly (chrome_id is in the lease from step c).
    if ! pool_daemon_connect "abpool-$lane" "$port"; then
        _pool_log "pool_boot_lane: daemon connect failed for lane $lane port $port; dropping lane"
        _pool_release_lane_internals "$lane"
        return 1
    fi

    # --- f. UPDATE LEASE: connected=true + last_seen_at=now (PRD §2.4 step 3j). ---
    #     port + chrome_pid + chrome_pgid are already set (steps b + c). `connected` MUST be
    #     the literal "true" (pool_lease_update splices via --argjson). last_seen_at = epoch s.
    now="$(_pool_now)"
    pool_lease_update "$lane" connected true
    pool_lease_update "$lane" last_seen_at "$now"

    _pool_log "pool_boot_lane: lane $lane provisioned (port=$port pid=${POOL_CHROME_PID:-0})"
    return 0
}

# =============================================================================
# Acquire — ensure connected (P1.M5.T1.S3)
# =============================================================================
# PRD §2.4 step 4 (ENSURE CONNECTED) — the per-invocation self-heal. Given an
# ALREADY-BOOTED lane (port>0, from pool_boot_lane / S2 or a reuse-orphan adoption / S1),
# verify it is STILL drivable; if not, RECONNECT (re-bind the daemon) or RELAUNCH (restart
# Chrome on the SAME dir+port, keeping the profile — PRD §2.14 "Chrome crash mid-task").
# Consumed by the wrapper lifecycle step 4 (M6.T3.S1) on EVERY DRIVING call.
#
# Returns 0 if connected (was-already OR reconnected OR relaunched); 1 on failure. NEVER
# drops the lane (that's the wrapper's / reaper's job). The literal PRD `get cdp-url` probe
# is BROKEN on agent-browser 0.28.0 (auto-launches strays — P1.M4.T3.S1 research §2), so
# the connected check is the SIDE-EFFECT-FREE pool_daemon_connected + curl /json/version.

# pool_ensure_connected LANE
#
# LOGIC (CONTRACT a→d):
#   a. Read the lease → session, port, ephemeral_dir (+ chrome_pid). Lease missing/corrupt
#      OR port<=0 (provisional, not booted) → return 1 (defensive — S2's job).
#   b. pool_daemon_connected "$session" "$port" (SIDE-EFFECT-FREE): rc 0 → touch last_seen_at
#      → return 0.
#   c. NOT connected. Chrome alive? curl /json/version on the port (NOT kill -0 — research §2):
#      ALIVE → pool_daemon_connect (re-bind the daemon): rc 0 → connected:true + last_seen_at
#      → return 0; rc 1 → last_seen_at → return 1.
#      DEAD → RELAUNCH on same dir+port: rm -f Singleton* ; pool_chrome_launch (0 or fatal
#      pool_die) ; early-write chrome_pid/pgid (reaper-safe) ; pool_wait_cdp (rc 1 → chrome
#      already killed → connected:false + last_seen_at → return 1) ; pool_daemon_connect
#      (rc 1 → connected:false + last_seen_at → return 1) ; connected:true + last_seen_at
#      → return 0.
#   d. last_seen_at is touched on EVERY path (the observability heartbeat).
#
# CALLER CONTRACT (the wrapper M6.T3.S1, under set -e):
#     if ! pool_ensure_connected "$N"; then
#         <lane unusable: retry acquire / M5.T4 exhaustion / surface error>
#     fi
#     exec ... AGENT_BROWSER_SESSION=abpool-<N> ...
#
# GOTCHA — get cdp-url is FORBIDDEN (P1.M4.T3.S1 §2): use pool_daemon_connected (2 args).
# GOTCHA — the Chrome-aliveness sub-check is curl /json/version, NOT kill -0 (research §2).
# GOTCHA — NEVER drops the lane: returns 1, leaves lease + chrome as-is. No _pool_release_*.
# GOTCHA — pool_chrome_launch pool_die (instant-exit) is FATAL + propagates (research §1.3).
# GOTCHA — pool_wait_cdp KILLS the pgroup on timeout: after rc 1 the relaunched chrome is dead.
# GOTCHA — early chrome-id write BEFORE wait_cdp (reaper-safe — research §5).
# GOTCHA — Singleton cleanup before relaunch (research §3 / pool_copy_master pattern).
# GOTCHA — every `local` capture is split (BashFAQ 105); every rc-1 helper guarded.
# Reads POOL_EPHEMERAL_ROOT (relaunch udd) + POOL_LANES_DIR (via helpers) + POOL_CHROME_PID/PGID
# (set by pool_chrome_launch). No new globals exported.
# PRECONDITION: pool_config_init + pool_state_init + a BOOTED lease for LANE (port>0).
pool_ensure_connected() {
    local lane="${1:-}"
    local json session port ephemeral_dir now
    local -a _f

    # Validate lane.
    [[ "$lane" =~ ^[0-9]+$ ]] \
        || { _pool_log "pool_ensure_connected: bad lane '$lane'"; return 1; }

    # --- a. Read the lease (ONE read, ONE jq fork — the pool_lane_is_stale "ONE fork" idiom). ---
    # Lease missing/corrupt → return 1 (non-fatal; never pool_die — runs on the hot path).
    # `if !` is errexit-exempt (a bare capture ABORTS on rc 1).
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
        _pool_log "pool_ensure_connected: no/corrupt lease for lane $lane"
        return 1
    fi
    # Extract the 3 fields we need in ONE jq fork (comma → 3 lines; mapfile -t strips \n).
    # jq cannot fail here (valid JSON guaranteed by pool_lease_read's _pool_json_valid).
    mapfile -t _f < <(jq -r '.session, .port, .ephemeral_dir' <<<"$json")
    session="${_f[0]:-}"
    port="${_f[1]:-}"
    ephemeral_dir="${_f[2]:-}"

    # A not-booted (provisional) lane has port:0 — ensure_connected is for BOOTED lanes.
    # Reconstruct session/ephemeral_dir defensively if the lease fields are empty.
    [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
        || { _pool_log "pool_ensure_connected: lane $lane not booted (port='$port')"; return 1; }
    [[ -n "$session" ]]      || session="abpool-$lane"
    [[ -n "$ephemeral_dir" && "$ephemeral_dir" == /* ]] || ephemeral_dir="$POOL_EPHEMERAL_ROOT/$lane"

    now="$(_pool_now)"

    # --- b. ALREADY connected? (SIDE-EFFECT-FREE — never launches; the get cdp-url REPLACEMENT). ---
    if pool_daemon_connected "$session" "$port"; then
        pool_lease_update "$lane" last_seen_at "$now"   # observability heartbeat
        return 0
    fi

    # --- c. NOT connected. Chrome alive? curl /json/version (NOT kill -0 — research §2). ---
    if curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
        # Chrome ALIVE → the daemon just lost its binding. RECONNECT (cheap ~ms attach).
        if pool_daemon_connect "$session" "$port"; then
            pool_lease_update "$lane" connected true
            pool_lease_update "$lane" last_seen_at "$now"
            _pool_log "pool_ensure_connected: lane $lane reconnected (same chrome, port=$port)"
            return 0
        fi
        _pool_log "pool_ensure_connected: lane $lane reconnect FAILED (chrome alive, connect rc 1)"
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi

    # --- c. Chrome DEAD → RELAUNCH on the SAME dir+port (PRD §2.14 "Chrome crash mid-task"). ---
    # Singleton cleanup BEFORE launch (research §3 / pool_copy_master pattern): defeats the
    # PID-recycle false-alive that would make Chrome exit without binding. Safe: curl just
    # proved the chrome is dead. SingletonSocket is AF_UNIX — rm -f handles all three.
    rm -f -- "$ephemeral_dir/SingletonLock" "$ephemeral_dir/SingletonCookie" "$ephemeral_dir/SingletonSocket" \
        2>/dev/null || true

    # Launch the NEW chrome on the same port + same dir. pool_chrome_launch sets globals
    # POOL_CHROME_PID/PGID (declare -g); returns 0 or pool_die's on INSTANT exit (FATAL —
    # propagates; genuine misconfiguration, NOT a recoverable mid-task crash).
    pool_chrome_launch "$port" "$ephemeral_dir" "$lane"

    # Early chrome-id write (BEFORE wait_cdp — reaper-safe, research §5): if wait_cdp times
    # out (kills the pgroup) or this process is SIGKILL'd mid-relaunch, the lease holds the
    # new (dead-or-live) chrome identity so _pool_release_lane_internals / the reaper act
    # correctly. ${:-0} is set -u safe (globals are set after a successful launch, but be
    # defensive). pool_lease_update splices the value as raw JSON (bare digits OK).
    pool_lease_update "$lane" chrome_pid  "${POOL_CHROME_PID:-0}"
    pool_lease_update "$lane" chrome_pgid "${POOL_CHROME_PGID:-0}"

    # Wait for the relaunched chrome's CDP. rc 1 = timeout AND the pgroup is ALREADY KILLED
    # (pool_wait_cdp does the kill before returning 1). Non-fatal: set connected:false +
    # touch last_seen_at, return 1. (The lane is NOT dropped — wrapper/reaper's job.)
    if ! pool_wait_cdp "$port"; then
        _pool_log "pool_ensure_connected: lane $lane relaunch CDP timeout (chrome killed)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi

    # CDP ready → re-bind the daemon. rc 1 = the (alive) chrome won't bind — set
    # connected:false, return 1. (We do NOT kill the live chrome here — ensure_connected
    # never drops the lane; the next ensure_connected / reaper handles it.)
    if ! pool_daemon_connect "$session" "$port"; then
        _pool_log "pool_ensure_connected: lane $lane relaunch connect FAILED (cdp up, connect rc 1)"
        pool_lease_update "$lane" connected false
        pool_lease_update "$lane" last_seen_at "$now"
        return 1
    fi

    # Relaunch succeeded: a fresh chrome on the same port + dir, profile kept (PRD §2.14).
    pool_lease_update "$lane" connected true
    pool_lease_update "$lane" last_seen_at "$now"
    _pool_log "pool_ensure_connected: lane $lane relaunched (new pid=${POOL_CHROME_PID:-0}, port=$port)"
    return 0
}

# =============================================================================
# Release & teardown (P1.M5.T2.S1)
# =============================================================================
# PRD §2.5 "Release semantics" — the PUBLIC, idempotent, non-fatal teardown that fully
# releases one lane: disconnect the daemon session, kill the Chrome process group, remove
# the ephemeral dir, delete the lease. Consumed by the reaper (M5.T3 reap_stale), the admin
# CLI (M7.T3 release [<N>|all]), and exhaustion force-reap (M5.T4). NOT used by acquire's
# in-lock REAP-STALE (that calls the private kernel directly — the close subprocess is
# forbidden under the short acquire flock, PRD §2.19).
#
# DESIGN — DELEGATE (M5.T1.S1 contract): the completed acquire PRP states verbatim:
#   "M5.T2.S1's public pool_release_lane() will COMPOSE _pool_release_lane_internals
#    rather than duplicate it." So the KILL (pool_chrome_kill pgroup teardown) + RM DIR
#   (prefix-guarded rm -rf) + RM LEASE (rm -f) all happen via _pool_release_lane_internals.
#   The ONE step this public layer adds — that the kernel deliberately omits (per
#   pool_chrome_kill's docstring: "Daemon/session disconnect is … release's lease-delete
#   (M5.T2.S1)") — is the daemon `close`.
#
# LOGIC (CONTRACT 3a→3g; the c↔d order is swapped — see GOTCHA — immaterial, host-verified):
#   a. validate lane (^[0-9]+$) else return 0 (path-traversal defense).
#   b. pool_lease_read "$lane" → json. rc 1 (missing/corrupt) ⇒ already released ⇒ return 0
#      (idempotent). Extract session (the ONE field the kernel does not read). Defensive
#      reconstruct → "abpool-$lane" if empty/null.
#   c. DISCONNECT daemon: $POOL_REAL_BIN --session "$session" close 2>/dev/null || true.
#      Run BEFORE the kill (graceful detach while the Chrome may still be reachable).
#   d. _pool_release_lane_internals "$lane" → KILL pgroup + RM DIR + RM LEASE (the kernel,
#      non-fatal, idempotent). It re-reads the lease + does all destructive work.
#   e. _pool_log … ; return 0.
#
# CALLER CONTRACT (the reaper M5.T3 / admin M7.T3 / exhaustion M5.T4, under set -e):
#     for n in $(pool_lanes_list); do
#         if pool_lane_is_stale "$n"; then pool_release_lane "$n"; fi   # rc 0 always
#     done
#   OR explicit: pool_release_lane "$N". No flock needed (lane-local + idempotent).
#
# GOTCHA — DELEGATE: do NOT re-implement kill/rm/lease (the kernel does it; duplicating
#   violates the M5.T1.S1 contract + the prefix-guarded rm logic). Read session, close, delegate.
# GOTCHA — read session BEFORE delegating: the kernel DELETES the lease; after delegation
#   pool_lease_read returns "no lease". So extract session up front.
# GOTCHA — close BEFORE kill (d→c swap vs the literal CONTRACT): graceful detach + the kernel
#   bundles kill+rm+rmlease. IMMATERIAL — close is disconnect-only (Chrome survives it),
#   rc always 0, no strays (research §3, HOST-VERIFIED on agent-browser 0.28.0).
# GOTCHA — close 2>/dev/null || true: rc is ALWAYS 0 on 0.28.0, but the guard is future-proof +
#   the idempotency mechanism + non-fatal intent. close does NOT kill Chrome (pool_chrome_kill
#   does); the session LINGERS after close (harmless; re-acquire re-binds via connect).
# GOTCHA — NON-FATAL always: never pool_die, never non-zero. Missing lease ⇒ return 0;
#   bad lane ⇒ return 0; POOL_REAL_BIN unset ⇒ skip close (kernel still tears down).
# GOTCHA — NO flock: release is lane-local + idempotent. Flocking is the caller's concern.
# GOTCHA — every `local` capture is split (BashFAQ 105); pool_lease_read guarded (rc 1 non-fatal).
# Reads POOL_REAL_BIN (close subprocess) + POOL_LANES_DIR (via helpers). No new globals exported.
# PRECONDITION: pool_config_init (+ pool_state_init by the caller).
pool_release_lane() {
    local lane="${1:-}"
    local json session

    # (a) Validate lane (path-traversal defense; a bogus lane "has nothing to release").
    #     `[[ ]] || return 0` is errexit-exempt. Matches the kernel.
    [[ "$lane" =~ ^[0-9]+$ ]] || return 0

    # (b) Read the lease. rc 1 (missing OR corrupt) ⇒ already released ⇒ return 0 (idempotent).
    #     `if !` is errexit-exempt (a bare capture would ABORT under set -e on rc 1).
    if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
        return 0
    fi

    # Extract `session` — the ONE field the kernel does NOT read (needed for the daemon close).
    # jq cannot fail here (valid JSON guaranteed by pool_lease_read's _pool_json_valid). The
    # assignment is split (local declared above) — no SC2155 / errexit masking. jq -r on a
    # missing field outputs the literal "null" → guard both empty AND "null", reconstruct.
    session="$(jq -r '.session' <<<"$json")"
    [[ -n "$session" && "$session" != "null" ]] || session="abpool-$lane"

    # (c) DISCONNECT the daemon session — graceful detach while the Chrome may still be
    #     reachable (close is DISCONNECT-ONLY: it does NOT kill the Chrome — host-verified,
    #     research §3). rc is ALWAYS 0 on agent-browser 0.28.0 (fresh/live/dead/repeated);
    #     `2>/dev/null || true` is future-proof + the idempotency mechanism. The session
    #     LINGERS in the daemon's session list after close (M4.T3.S1 research §3) — harmless:
    #     a re-acquired lane (same N → same abpool-N) re-binds via pool_daemon_connect
    #     (idempotent, M4.T3.S1 research §1). Guard POOL_REAL_BIN (set -u safety; release is
    #     non-fatal — if unset, skip close, the kernel still tears down Chrome+dir+lease).
    if [[ -n "${POOL_REAL_BIN:-}" ]]; then
        "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true
    fi

    # (d) Delegate the Chrome teardown + dir removal + lease deletion to the shared kernel
    #     (M5.T1.S1 contract: COMPOSE, do NOT duplicate). The kernel re-reads the lease,
    #     calls pool_chrome_kill (pgroup SIGTERM→SIGKILL + bare-pid fallback; idempotent),
    #     rm -rf the reconstructed prefix-guarded $POOL_EPHEMERAL_ROOT/$lane, and rm -f the
    #     lease. It returns 0 ALWAYS (non-fatal). So pool_release_lane inherits rc 0.
    _pool_release_lane_internals "$lane"

    _pool_log "pool_release: released lane $lane (daemon session '$session' disconnected, chrome killed, dir+lease removed)"
    return 0
}

# =============================================================================
# Reaper & orphan reuse (P1.M5.T3.S1, P1.M5.T3.S2)
# =============================================================================
# pool_reap_stale
#
# PRD §2.10 "Reaper" — the LAZY, on-demand stale-lease cleanup. Scans EVERY lane
# (pool_lanes_list), asks the tri-state predicate pool_lane_is_stale whether each
# lane's owner is dead/recycled/unverifiable, and for every STALE lane calls the PUBLIC
# pool_release_lane (full teardown: daemon close + Chrome pgroup kill + rm dir + delete
# lease). Echoes the reaped count to stdout for observability; returns 0. NO flock, NO
# background daemon (PRD §2.10 — lazy; a crashed agent's Chrome+dir is reclaimed here OR
# at the next acquire's inlined reap).
#
# DESIGN — the acquire-vs-reaper SPLIT (research §1): the LANDED acquire critical section
# (_pool_acquire_critical_section @ ~line 1966) inlines its OWN reap loop that calls the
# PRIVATE _pool_release_lane_internals directly — because the daemon close subprocess is
# FORBIDDEN under the short acquire flock (PRD §2.19 / key_findings FINDING 2). This
# standalone reaper runs OUTSIDE any flock and uses the PUBLIC pool_release_lane (which
# DOES run close). The CONTRACT's "Consumed by acquire step 3a" is legacy design intent;
# the REAL consumer is the on-demand admin reap command (M7.T2 `agent-browser-pool reap`,
# PRD §2.10/§2.12), with exhaustion force-reap (M5.T4) as a possible future caller.
#
# DELEGATE (do NOT duplicate — research §2/§4): the staleness verdict comes from
# pool_lane_is_stale (M3.T2.S3); the teardown from pool_release_lane (M5.T2.S1). Do NOT
# re-inline pool_owner_alive / pool_chrome_kill / the rm-rf / the close.
#
# LOGIC (CONTRACT a→d):
#   a. for n in $(pool_lanes_list)  — snapshot (cmd-subst captured once); empty ⇒ 0 iters.
#   b.   if pool_lane_is_stale "$n"; then   — TRI-STATE; the if-condition is errexit-exempt:
#          rc 0 (stale) → enter body;  rc 1 (live) / rc 2 (no lease) → fall through (skip).
#          pid  = pool_lease_field "$n" owner.pid (best-effort || true; "null"/empty → "?")
#                 — read BEFORE release (release deletes the lease).
#          pool_release_lane "$n" >/dev/null — full teardown (close+kill+rm+rmlease; rc 0
#                 always). >/dev/null so the daemon close subprocess can't pollute the count
#                 capture (_pool_log still fires — it writes the LOG FILE, not stdout).
#          _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
#          reaped=$((reaped + 1)) — assignment form (safe); NEVER (( reaped++ )) (aborts @0).
#        fi
#   c. printf '%s\n' "$reaped"  — the ONLY stdout write (count capture for M7.T2).
#   d. return 0  — NON-FATAL always (never pool_die, never non-zero).
#
# CALLER CONTRACT (the admin reap command M7.T2 / exhaustion M5.T4, under set -e):
#     reaped="$(pool_reap_stale)"   # captures exactly one integer; rc 0 always
#   OR (fire-and-forget):  pool_reap_stale >/dev/null 2>&1 || true
#
# GOTCHA — tri-state under set -e: a BARE `pool_lane_is_stale "$n"` whose rc is 1 (live) or
#   2 (no lease) ABORTS the caller. The `if …; then …; fi` is MANDATORY (the condition is
#   errexit-exempt). (pool_lane_is_stale GOTCHA @ ~line 1145-1148.)
# GOTCHA — `(( reaped++ ))` ABORTS when reaped==0 (command form returns rc 1 on value 0).
#   Use `reaped=$((reaped + 1))` (assignment form, exit 0). (BashFAQ 105.)
# GOTCHA — stdout discipline: pool_release_lane's daemon close subprocess is NOT stdout-
#   redirected inside it; redirect pool_release_lane "$n" >/dev/null so the count capture
#   stays clean. _pool_log writes the LOG FILE (never stdout) → keeps firing.
# GOTCHA — read pid BEFORE release: pool_release_lane deletes the lease; extract owner.pid
#   first (best-effort || true; "null"/empty → "?").
# GOTCHA — `local var=$(…)` masks errexit (SC2155): split every capture (local declared
#   FIRST, assign AFTER); guard pool_lease_field's rc-1 with || true INSIDE the $().
# GOTCHA — NON-FATAL always: never pool_die, never non-zero. A TOCTOU missing lease ⇒
#   pool_release_lane returns 0 (no-op); a corrupt lease ⇒ pool_lane_is_stale rc 2 (skip).
# GOTCHA — NO flock: release is lane-local + idempotent; a concurrent acquire's in-lock reap
#   of the same lane is a harmless no-op. Flocking the sweep would serialize vs acquire.
# GOTCHA — snapshot iteration: the lane list is frozen before the loop; mid-loop releases
#   cannot mutate the iteration set.
# Reads POOL_LANES_DIR (via helpers). No new globals exported. No new env vars / files.
# PRECONDITION: pool_config_init (for POOL_LANES_DIR via pool_lanes_list/pool_lease_field;
#   POOL_REAL_BIN via pool_release_lane). pool_state_init NOT required (pool_lanes_list
#   handles a missing lanes dir as a no-match glob → 0 iterations; _pool_log mkdir -p's).
pool_reap_stale() {
    local n pid
    local reaped=0

    # (a) Iterate ALL lanes. pool_lanes_list: newline-separated, numerically-sorted lane
    #     numbers; rc 0 always; empty/missing dir ⇒ no-match glob ⇒ 0 iterations. The
    #     unquoted command substitution is the documented idiom (digits-only; word-splits
    #     on IFS into exactly the lane numbers). The list is a SNAPSHOT (captured once
    #     before the loop) — mid-loop releases cannot mutate the iteration set.
    for n in $(pool_lanes_list); do

        # (b) TRI-STATE verdict. pool_lane_is_stale: 0=stale / 1=live / 2=no-lease.
        #     The `if`-condition is errexit-exempt — rc 1 (live) and rc 2 (no lease) fall
        #     through cleanly (skip); ONLY rc 0 (stale) enters the body. A BARE call would
        #     ABORT under set -e on rc 1/2 (pool_lane_is_stale GOTCHA @ ~line 1145-1148).
        if pool_lane_is_stale "$n"; then
            # Best-effort read of the owner pid for the log line. Read BEFORE release
            # (pool_release_lane deletes the lease). pool_lease_field: nested-path read
            # (owner.pid via getpath); rc 1 on missing/corrupt; echoes "null" for a missing
            # path. The `|| true` INSIDE the $() makes the capture set -e-safe against a
            # TOCTOU missing-lease rc 1 (pid falls back to "?"). The assignment is split
            # (local declared above) — no SC2155 / errexit masking.
            pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
            [[ -n "$pid" && "$pid" != "null" ]] || pid="?"

            # Release the stale lane: daemon close + Chrome pgroup kill + rm dir + delete
            # lease (pool_release_lane returns 0 ALWAYS — idempotent, non-fatal). Redirect
            # its stdout to /dev/null so the daemon close subprocess cannot pollute THIS
            # function's reaped-count stdout capture. _pool_log (inside release + below)
            # writes the LOG FILE (+ stderr fallback), NEVER stdout → still fires.
            pool_release_lane "$n" >/dev/null

            _pool_log "pool_reap: reaped stale lane $n (owner pid $pid dead/recycled)"
            # assignment form — safe under set -e. NEVER `(( reaped++ ))` (aborts @0).
            reaped=$((reaped + 1))
        fi
    done

    # (c) Echo the reaped count to stdout for observability. This is the ONLY stdout write
    #     in the function (consumers capture via `count=$(pool_reap_stale)`, e.g. the admin
    #     reap command M7.T2). 0 = nothing was stale. $() strips the trailing newline so
    #     the caller gets a bare integer token.
    printf '%s\n' "$reaped"

    # (d) NON-FATAL always — never pool_die, never non-zero.
    return 0
}

# -----------------------------------------------------------------------------
# pool_reuse_orphan
#
# ★★★ DEAD CODE — CURRENTLY UNUSED (Issue #4) ★★★ This PUBLIC function has ZERO
# non-comment call sites. The reuse-orphan feature is shipped via the INLINE loop inside
# _pool_acquire_critical_section (@ ~line 1977-1996), which is correct + shipped. This
# standalone function is RESERVED for a future acquire refactor / exhaustion retry /
# admin doctor reconcile (see DESIGN below) that does not yet exist. Do NOT assume it is
# live; do NOT delete it without confirming those future callers are abandoned.
#
# PRD §2.4 step 3b / IQ4 "reuse-if-responsive" — the PUBLIC building-block entry
# point that ADOPTS the first STALE lane whose Chrome is still RESPONSIVE. Scans
# EVERY lane (pool_lanes_list), asks the tri-state predicate pool_lane_is_stale
# whether each lane's owner is dead/recycled, and for the first stale lane whose
# Chrome answers (pool_daemon_connected) DELEGATES to _pool_adopt_lane (reassign
# owner to the current POOL_OWNER_*, set connected=true, stamp last_seen_at,
# re-bind the daemon). Echoes the adopted lane N + return 0; or return 1 if no
# responsive orphan. Skips the ~5-10s Chrome boot + master copy (the Chrome is
# already running). NO reap, NO choose-N, NO launch.
#
# DESIGN — the acquire-vs-reuse-orphan SPLIT (research §1): the LANDED acquire
# critical section (_pool_acquire_critical_section @ ~line 1966) INLINES its OWN
# reuse-orphan loop (@ ~1977-1996), INTERLEAVED with reap (on a failed adopt it
# REAPS the lane, then continues — its goal is to CLAIM a lane). This PUBLIC
# function is REUSE-ONLY: it adopts the first responsive orphan and returns; on a
# failed adopt it falls through to the NEXT stale lane (NO reap); on exhaustion it
# returns 1. The CONTRACT's "Consumed by acquire step 3b" is LEGACY design intent
# (the LANDED acquire already inlines reuse-orphan); the REAL callers are a future
# acquire refactor / exhaustion retry / admin doctor reconcile. Do NOT wire this
# into acquire (the inline is shipped + correct).
#
# WARNING — THE KEY DIVERGENCE FROM pool_reap_stale — FLOCK / SERIALIZATION
# (research §3): adoption is NOT collision-safe. Two concurrent adopters of the
# SAME orphan would both read the lease, both find it responsive, both rewrite
# .owner, both re-bind the daemon, and both echo lane N → BOTH believe they own N.
# (Contrast pool_reap_stale, which is idempotent — release twice = no-op → safely
# unflocked.) THEREFORE pool_reuse_orphan REQUIRES SERIALIZATION. DECISION: this
# function takes NO own flock; the CALLER MUST already hold an exclusive flock on
# $POOL_LOCK_FILE. This mirrors the codebase convention (ONLY pool_acquire_locked
# flocks; all building-block functions are lock-free) + pool_reap_stale.
#
# WARNING — DO NOT add `( flock 9; … ) 9>"$POOL_LOCK_FILE"` inside this function.
# flock(2) locks are bound per OPEN FILE DESCRIPTION
# (https://man7.org/linux/man-pages/man2/flock.2.html): a fresh 9>"$POOL_LOCK_FILE"
# redirect opens a NEW file description, so a blocking flock taken here while the
# caller already holds the lock via its own fd 9 is DENIED BY THE CALLER'S OWN LOCK
# → BLOCKS FOREVER (self-deadlock). The caller serializes; this function is
# lock-free.
#
# DELEGATE (do NOT duplicate — research §2/§6): the responsiveness gate is
# pool_daemon_connected (M4.T3.S1, READ-ONLY, never launches); the adoption
# (owner-reassign + connected + re-bind) is _pool_adopt_lane (M5.T1.S1). Do NOT
# re-inline the jq .owner mutation, pool_daemon_connect, or a raw curl
# /json/version probe (raw curl is INSUFFICIENT — adoption needs the daemon to
# know the session so the re-bind is meaningful).
#
# LOGIC (CONTRACT a→e):
#   guard. POOL_OWNER_PID numeric & !=0  else return 1   (passthrough owner must not adopt)
#   a. for n in $(pool_lanes_list)  — snapshot; empty ⇒ 0 iters.
#   b.   if pool_lane_is_stale "$n"; then   — TRI-STATE; the if-condition is errexit-exempt:
#          rc 0 (stale) → enter body;  rc 1 (live) / rc 2 (no lease) → fall through (skip).
#   c.      port/session = pool_lease_field "$n" (|| true inside $(); missing → "")
#          if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] && pool_daemon_connected "$session" "$port"; then
#   d.        if _pool_adopt_lane "$n"; then printf '%s\n' "$n"; return 0; fi   # adopted → DONE
#                    # adopt rc 1 (Chrome died mid-race) → fall through, try the NEXT orphan
#          fi        # port=0 (provisional) OR not responsive → skip (NOT reaped; reuse-only)
#        fi
#   e. return 1   — no responsive orphan adopted; nothing echoed.
#
# CALLER CONTRACT (within a SERIALIZED context — caller holds $POOL_LOCK_FILE;
# under set -e):
#     local n
#     if n="$(pool_reuse_orphan)"; then
#         <proceed: the lane n is adopted, owner=reassigned, connected=true, daemon
#          re-bound; go straight to EXEC / ensure_connected>
#     else
#         <no responsive orphan: reap-sweep / claim-a-new-lane / block / alert>
#     fi
#
# GOTCHA — tri-state under set -e: a BARE `pool_lane_is_stale "$n"` whose rc is 1
#   (live) or 2 (no lease) ABORTS the caller. The `if …; then …; fi` is MANDATORY
#   (the condition is errexit-exempt). (pool_lane_is_stale GOTCHA @ ~line 1145-1148.)
# GOTCHA — responsiveness gate under set -e: pool_daemon_connected returns 1 (not
#   responsive) → a BARE call ABORTS. Use it under `&&`:
#   `[[ port>0 ]] && pool_daemon_connected …` (the &&-list is errexit-exempt; rc 1
#   short-circuits). Likewise `if _pool_adopt_lane "$n"; then …; fi` (rc 1 falls
#   through to the next orphan).
# GOTCHA — port=0 provisional lease is NEVER an orphan: the `[[ -gt 0 ]]` gate
#   rejects it (no Chrome yet → nothing to reuse). It is skipped, NOT reaped
#   (reuse-only).
# GOTCHA — adopt-failure-mid-race: the Chrome can die between the gate
#   (pool_daemon_connected rc 0) and the re-bind (pool_daemon_connect rc 1 inside
#   _pool_adopt_lane) → _pool_adopt_lane rc 1 → fall through to the next orphan.
#   The racy lane is NOT reaped; a later reap sweep / acquire handles it.
# GOTCHA — stdout discipline: ONLY `printf '%s\n' "$n"` writes stdout (on
#   success). Every helper is stdout-clean. On return 1 NOTHING is echoed →
#   `n=$(pool_reuse_orphan)` yields "". No extra >/dev/null needed on
#   _pool_adopt_lane (its pool_daemon_connect is already >/dev/null 2>&1; its
#   _pool_log is file-only). _pool_adopt_lane logs the adoption itself → no
#   double-logging here.
# GOTCHA — `local var=$(…)` masks errexit (SC2155): split every capture (local
#   declared FIRST, assign AFTER); guard pool_lease_field's rc-1 with || true
#   INSIDE the $().
# GOTCHA — NON-FATAL: never pool_die; returns 0 (adopted) / 1 (none). A corrupt
#   lease ⇒ rc 2 skip; a dead-Chrome lane ⇒ not responsive ⇒ skip; an empty pool
#   ⇒ 0 iterations ⇒ return 1.
# GOTCHA — NO own flock (Design B): caller MUST hold $POOL_LOCK_FILE (adoption is
#   not collision-safe). Adding an inner flock SELF-DEADLOCKS (flock(2) per-OFD).
#   See the WARNING block above.
# Reads POOL_LANES_DIR + POOL_OWNER_* (via _pool_adopt_lane) + POOL_REAL_BIN
# (via the helpers). PRECONDITION: pool_config_init + pool_owner_resolve AND the
# caller holds $POOL_LOCK_FILE.
# -----------------------------------------------------------------------------
pool_reuse_orphan() {
    local n port session

    # ── Guard: a passthrough owner (POOL_OWNER_PID==0, no pi ancestor) must NOT adopt a lane ──
    # (it would be immediately stale to everyone; _pool_adopt_lane itself returns 1 on a
    # non-numeric POOL_OWNER_PID). Mirrors _pool_acquire_critical_section's defense.
    # `[[ ]] || return 1` is errexit-exempt. CONTRACT step 3b INPUT = the current POOL_OWNER_*.
    [[ "$POOL_OWNER_PID" =~ ^[0-9]+$ && "$POOL_OWNER_PID" != "0" ]] || return 1

    # (a) Iterate ALL lanes. pool_lanes_list: newline-separated, numerically-sorted lane
    #     numbers; rc 0 always; empty/missing dir ⇒ 0 iterations. The unquoted command
    #     substitution is the documented idiom (digits-only; word-splits on IFS into exactly
    #     the lane numbers). The list is a SNAPSHOT (captured once before the loop) — adopting
    #     a lane mid-loop (rewriting its lease) cannot mutate the iteration set.
    for n in $(pool_lanes_list); do

        # (b) TRI-STATE verdict. pool_lane_is_stale: 0=stale / 1=live / 2=no-lease. The `if`
        #     condition is errexit-exempt — rc 1 (live) and rc 2 (no lease) fall through cleanly
        #     (skip); ONLY rc 0 (stale) enters the body. A BARE call would ABORT under set -e on
        #     rc 1/2 (pool_lane_is_stale GOTCHA @ ~line 1145-1148). (CONTRACT 3b(a/b).)
        if pool_lane_is_stale "$n"; then

            # (c) Read the orphan's port + session for the responsiveness gate.
            #     pool_lease_field: top-level `port`/`session` read; rc 1 on missing/corrupt
            #     (TOCTOU between the staleness verdict and this read); echoes "null" for a
            #     missing path. The `|| true` INSIDE the $() makes the capture set -e-safe
            #     (yields "" on failure). The assignment is split (local declared above) —
            #     no SC2155 / errexit masking.
            port="$(pool_lease_field "$n" port 2>/dev/null || true)"
            session="$(pool_lease_field "$n" session 2>/dev/null || true)"

            # (c) RESPONSIVENESS GATE (CONTRACT 3b(c)). A provisional lease has port=0 (no
            #     Chrome yet) → the `[[ -gt 0 ]]` test rejects it (never an orphan).
            #     pool_daemon_connected: READ-ONLY two-probe check (daemon `session list` +
            #     curl /json/version); NEVER launches; rc 0 = responsive, rc 1 = not. Raw
            #     curl ALONE is insufficient for adoption (the daemon must know the session
            #     so the re-bind is meaningful). The `[[ ]] && func` list is errexit-exempt —
            #     rc 1 (not responsive / bad port) short-circuits (skip this lane), NO abort.
            #     A BARE pool_daemon_connected would ABORT under set -e on rc 1.
            if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] \
               && pool_daemon_connected "$session" "$port"; then

                # (d) ADOPT (CONTRACT 3b(d) — reassign owner / connected=true / last_seen_at /
                #     ensure-connected, all ALREADY implemented by _pool_adopt_lane). The gate
                #     above is the "ensure connected" CHECK; _pool_adopt_lane does the
                #     owner-reassign + the daemon re-bind (pool_daemon_connect) — the
                #     "if not, connect" ACT. DELEGATE — do NOT re-inline the jq .owner mutation
                #     or pool_daemon_connect. `if _pool_adopt_lane "$n"; then …; fi` is
                #     errexit-exempt: rc 1 (Chrome died between the gate and the re-bind) →
                #     fall through to the NEXT stale lane (try the next orphan); the racy lane
                #     is NOT reaped (reuse-only). On rc 0 → echo the lane + return 0 (DONE —
                #     first responsive orphan adopted).
                if _pool_adopt_lane "$n"; then
                    # The ONLY stdout write: the adopted lane N. Every helper is stdout-clean
                    # (pool_lease_field captured in $(); pool_daemon_connected redirects both
                    # probes >/dev/null; _pool_adopt_lane's pool_daemon_connect is
                    # >/dev/null 2>&1 and _pool_log writes the LOG FILE). _pool_adopt_lane
                    # logs the adoption itself ("pool_acquire(adopt): reused orphan lane N …")
                    # → no second log line here.
                    printf '%s\n' "$n"
                    return 0
                fi
            fi
            # port=0 (provisional) OR not responsive OR adopt-failed → skip this lane (NOT
            # reaped; reuse-only — a later reap sweep / acquire handles it). Continue.
        fi
    done

    # (e) No responsive orphan was adoptable. CONTRACT step 3b(e). Nothing echoed (so
    #     `n=$(pool_reuse_orphan)` yields the empty string). NON-FATAL (never pool_die).
    return 1
}


# =============================================================================
# Pool exhaustion (P1.M5.T4.S1)
# =============================================================================
# Block-with-timeout + force-reap + alert — PRD §2.9 (IQ2). The PUBLIC handler the
# wrapper (M6) calls when pool_acquire_locked returns 1 ("no free/reusable lane").
# _pool_alert is the best-effort notify-send + alerts.log helper; pool_wait_for_lane
# is the block→force-reap→alert flow.

# _pool_alert SUMMARY BODY
#
# Best-effort exhaustion alert (PRD §2.9 "Alert on timeout/force: notify-send desktop
# notification + a line to ~/.local/state/agent-browser-pool/alerts.log"). Fires a
# desktop notification (notify-send) AND appends one timestamped line to
# $POOL_STATE_DIR/alerts.log. ALWAYS returns 0 — a missing notify-send, a headless
# session (no DISPLAY / DBUS_SESSION_BUS_ADDRESS), or an unwritable alerts.log are
# ALL non-fatal no-ops. It must NEVER affect its caller's return code.
#
# LOGIC:
#   1. ts = printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1   (house-style display timestamp; no
#      `date` fork — mirrors _pool_log @~line 41).
#   2. notify-send "$SUMMARY" "$BODY" — guarded by `command -v` (may be absent on a
#      minimal host) + 2>/dev/null || true (exits non-zero in a headless session).
#   3. mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true  (the dir normally exists via
#      pool_state_init; defensive for an early/standalone call).
#   4. printf '%s %s: %s\n' "$ts" "$SUMMARY" "$BODY" >>"$POOL_STATE_DIR/alerts.log"
#      2>/dev/null || true  (O_APPEND small write < PIPE_BUF ⇒ atomic on local FS;
#      POSIX write()/O_APPEND).
#   5. return 0.
#
# GOTCHA — notify-send exits non-zero with no display (libnotify) ⇒ MUST guard; a bare
#   call ABORTS under set -e.
# GOTCHA — the `>>` append is atomic-enough for a single short line (POSIX O_APPEND +
#   PIPE_BUF); NO flock needed (multiple exhausted agents alerting concurrently is fine).
# GOTCHA — writes NOTHING to stdout (notify-send → D-Bus; printf → the file) ⇒ safe
#   inside the caller's lane-echo capture; the caller STILL redirects >/dev/null 2>&1
#   for hygiene (notify-send may print diagnostics to stderr).
# Reads POOL_STATE_DIR (frozen by pool_config_init). No new globals. PRECONDITION:
#   pool_config_init (for POOL_STATE_DIR). Non-fatal (rc 0 always).
_pool_alert() {
    local summary="${1:-}" body="${2:-}" ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$summary" "$body" >/dev/null 2>&1 || true
    fi
    # alerts.log under the runtime state dir (frozen by pool_config_init). Derive inline —
    # no new global (consistent with _pool_log's inline path derivation).
    if [[ -n "${POOL_STATE_DIR:-}" ]]; then
        mkdir -p -- "$POOL_STATE_DIR" 2>/dev/null || true
        printf '%s %s: %s\n' "$ts" "$summary" "$body" \
            >>"$POOL_STATE_DIR/alerts.log" 2>/dev/null || true
    fi
    return 0
}

# pool_wait_for_lane
#
# PRD §2.9 / IQ2 "block-with-timeout + alert" — the PUBLIC exhaustion handler. Called by
# the wrapper (M6) AFTER pool_acquire_locked returned 1 ("no free/reusable lane"). Blocks
# up to POOL_WAIT seconds (default 600), polling every 2 s (reap-stale + retry-acquire);
# on timeout FORCE-reaps the OLDEST dead-owner lane, alerts, and retries acquire once more;
# if still no lane (all-live-owners / lost the race) it alerts + returns 1.
#
# DESIGN — LOCK-FREE (research §1): ONLY pool_acquire_locked flocks
# (`( flock 9; _pool_acquire_critical_section ) 9>"$POOL_LOCK_FILE"`). pool_reap_stale and
# pool_release_lane are explicitly lock-free + idempotent. pool_wait_for_lane takes NO flock
# (holding one across the 2 s sleep — up to 10 min — would serialize the ENTIRE pool) and
# opens NO `9>"$POOL_LOCK_FILE"` (flock(2) locks are per OPEN FILE DESCRIPTION; a fresh OFD
# here would self-deadlock against any caller-held lock — man flock(2)). It COMPOSES the
# flock-owner + the lock-free helpers.
#
# LOGIC (CONTRACT a→e):
#   a. POLL (≤ POOL_WAIT s, 2 s cadence; check-BEFORE-body so POOL_WAIT=0 → 0 iterations):
#        start = _pool_now
#        while true; do
#            now = _pool_now; (( now - start >= POOL_WAIT )) && break   # &&-list = errexit-exempt
#            pool_reap_stale >/dev/null                                  # full daemon-close reap (lock-free)
#            if N = pool_acquire_locked; then printf '%s\n' "$N"; return 0; fi   # split-local, if-capture
#            sleep 2
#        done
#   b. FORCE-REAP (oldest dead-owner lane):
#        oldest_lane=""; oldest_ts=""
#        for cand in $(pool_lanes_list); do
#            if pool_lane_is_stale "$cand"; then                          # tri-state; if = errexit-exempt
#                ts = pool_lease_field "$cand" acquired_at (|| true inside $(); "null"/missing → "")
#                [[ "$ts" =~ ^[0-9]+$ ]] || continue                      # corrupt → SKIP (never default to 0)
#                if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then   # ||-list = errexit-exempt
#                    oldest_ts="$ts"; oldest_lane="$cand"
#                fi
#            fi
#        done
#   c. if oldest_lane set:
#        pool_release_lane "$oldest_lane" >/dev/null                      # PUBLIC teardown (close+kill+rm; lock-free)
#        _pool_alert 'agent-browser-pool' "Pool exhausted — force-reaped lane $oldest_lane. Possible leak."
#        _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
#        if N = pool_acquire_locked; then printf '%s\n' "$N"; return 0; fi  # peer may have won the race → rc 1
#   d. (no stale lane OR lost the race): alert + log + return 1 (nothing echoed)
#        _pool_alert 'agent-browser-pool' "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak."
#        _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
#        return 1
#   e. ALERT = the _pool_alert calls above (notify-send + alerts.log); see _pool_alert.
#
# CALLER CONTRACT (the wrapper M6, under set -e — split the capture per BashFAQ 105):
#     local N
#     if N="$(pool_acquire_locked)"; then
#         <post-lock boot / ensure_connected>
#     elif N="$(pool_wait_for_lane)"; then
#         <post-lock boot / ensure_connected for N>
#     else
#         pool_die "agent-browser-pool: no lane available after ${POOL_WAIT}s + force-reap"
#     fi
#
# GOTCHA — LOCK-FREE: NO flock, NO `9>"$POOL_LOCK_FILE"` anywhere in this function (see
#   DESIGN). Delegate acquire to pool_acquire_locked.
# GOTCHA — force-reap uses the PUBLIC pool_release_lane (close+kill+rm), NOT the private
#   _pool_release_lane_internals (no close, in-lock only). This function runs UNFLOCKED.
# GOTCHA — pool_lane_is_stale under an `if`, NEVER bare (rc 1/2 abort under set -e).
# GOTCHA — pool_acquire_locked under an `if` with a SPLIT-local (`local N` first; plain
#   `N="$(…)"`), NEVER `local N=$(…)` (SC2155 masks errexit) or a bare capture.
# GOTCHA — every `(( ))` is in a condition context (`&&`/`||`/`if`), NEVER a bare statement
#   (value 0 → rc 1 → abort).
# GOTCHA — timing uses `_pool_now` (epoch), NEVER `$SECONDS` (unset-fragile in a sourced
#   library); display ts in _pool_alert uses printf %()T.
# GOTCHA — POOL_WAIT=0 ⇒ check-BEFORE-body ⇒ 0 poll iterations ⇒ straight to force-reap.
# GOTCHA — stdout discipline: ONLY `printf '%s\n' "$N"` escapes (on success). pool_reap_stale
#   >/dev/null; pool_release_lane >/dev/null; _pool_alert >/dev/null 2>&1; _pool_log → LOG FILE.
# GOTCHA — lost-the-race after force-reap is ACCEPTABLE (rc 1, nothing echoed). Do NOT
#   retry-loop the force-reap — a peer legitimately won N.
# GOTCHA — _pool_alert is best-effort + non-fatal (rc 0 always); NEVER affects this rc.
# Reads POOL_WAIT + POOL_STATE_DIR (via _pool_alert; both frozen by pool_config_init) +
# POOL_LANES_DIR (via the helpers). No new globals.
# PRECONDITION: pool_config_init + pool_owner_resolve + (by the wrapper) one prior
#   pool_acquire_locked that returned 1. NOT the first acquire.
pool_wait_for_lane() {
    local N now start oldest_lane oldest_ts cand ts

    # (a) POLL loop — check-timeout-BEFORE-body so POOL_WAIT=0 runs ZERO iterations.
    start="$(_pool_now)"
    while true; do
        now="$(_pool_now)"
        # &&-list ⇒ errexit-exempt (no abort even when the comparison is false). CHECK FIRST.
        (( now - start >= POOL_WAIT )) && break
        # Full daemon-close reap (lock-free, idempotent, rc 0 always). Echoes a count → >/dev/null.
        pool_reap_stale >/dev/null
        # Acquire (takes its OWN short flock; inlines reap+reuse+choose+claim). rc 0 ⇒ done.
        # `if N="$(…)"` with N already declared above (plain assignment, NOT local N=$(…)).
        if N="$(pool_acquire_locked)"; then
            printf '%s\n' "$N"
            return 0
        fi
        sleep 2
    done

    # (b) FORCE-REAP — find the OLDEST lane whose owner is actually dead.
    oldest_lane=""
    oldest_ts=""
    for cand in $(pool_lanes_list); do
        # tri-state: rc 0 (stale) → enter; rc 1 (live) / rc 2 (no lease) → skip. `if` = exempt.
        if pool_lane_is_stale "$cand"; then
            # acquired_at is a numeric epoch (pool_lease_write @~704/721; _pool_now). `|| true`
            # inside $() makes the capture set -e-safe (pool_lease_field rc 1 on corrupt).
            ts="$(pool_lease_field "$cand" acquired_at 2>/dev/null || true)"
            # corrupt/missing ⇒ SKIP (never default to 0 — 0 would always win "oldest").
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            # ||-list ⇒ errexit-exempt. First stale lane seeds oldest; later older ones replace it.
            if [[ -z "$oldest_ts" ]] || (( ts < oldest_ts )); then
                oldest_ts="$ts"
                oldest_lane="$cand"
            fi
        fi
    done

    # (c) If we found a stale lane, force-reap it, ALERT, and try acquire ONE more time.
    if [[ -n "$oldest_lane" ]]; then
        # PUBLIC teardown (close+kill+rm dir+rm lease; lock-free, idempotent, rc 0 always).
        # >/dev/null (the close subprocess @~2472 redirects only stderr — stdout can leak).
        pool_release_lane "$oldest_lane" >/dev/null
        # ALERT — notify-send summary 'agent-browser-pool' + the VERBATIM force-reap body
        # (PRD §2.9; em-dash —). >/dev/null 2>&1 (notify-send may print stderr; writes no stdout).
        _pool_alert 'agent-browser-pool' \
            "Pool exhausted — force-reaped lane $oldest_lane. Possible leak." >/dev/null 2>&1
        _pool_log "pool_wait: force-reaped stale lane $oldest_lane after ${POOL_WAIT}s timeout"
        # Final acquire. A peer may have grabbed the just-freed lane first → rc 1 falls through to (d).
        if N="$(pool_acquire_locked)"; then
            printf '%s\n' "$N"
            return 0
        fi
    fi

    # (d) No stale lane existed (all-live-owners) OR lost the race. ALERT + log + return 1
    #     (nothing echoed ⇒ N=$(pool_wait_for_lane) yields the empty string).
    _pool_alert 'agent-browser-pool' \
        "Pool exhausted — no lane available after ${POOL_WAIT}s + force-reap. Possible leak." >/dev/null 2>&1
    _pool_log "pool_wait: exhausted — no free/reusable lane after ${POOL_WAIT}s + force-reap"
    return 1
}

# =============================================================================
# Wrapper shim — command dispatch (P1.M6.T1.S1)
# =============================================================================
# PRD §2.4 step 0 dispatcher. Classify an agent-browser invocation as 'meta'
# (passthrough — exec the real binary unchanged) or 'driving' (route to the agent's
# locked lane). ECHOES 'meta' or 'driving' on stdout; returns 0 ALWAYS. Called by the
# wrapper lifecycle (M6.T3.S1) as the VERY FIRST step, BEFORE owner resolution.

# pool_dispatch_classify [--] ARGS...
#
# Walk $@ left→right, skipping leading flags to find the first non-flag token (the
# command), then classify. Pure: reads NO globals, writes NO files, calls NO external
# commands. stdout = EXACTLY one token ('meta'|'driving'). Returns 0 always.
#
# LOGIC (item contract steps a–e):
#   a. Flag scan (first non-flag token = command):
#        --help | -h | --version  → echo 'meta'; return 0   (short-circuit: always a
#                                   help/version request — PRD §2.4 / external_deps §1.2 META)
#        --session <X>            → shift 2 (space form: consume flag + value)
#        --session=<X>            → shift 1 (equals form: value attached; caught by --*)
#        --json | <any --flag>    → shift 1 (caught by --*)
#        <any -shortflag except -h> → shift 1 (caught by -*)
#        <non-flag>               → the COMMAND; break (peek next token for session-list)
#   b. META classification:
#        'session' + next=='list' → 'meta'   (two-word command; bare 'session' is DRIVING)
#        cmd ∈ {skills, dashboard, plugin, mcp} → 'meta'
#   c. EVERYTHING ELSE → 'driving'. Covers the DRIVING set
#      (open/click/dblclick/type/fill/press/keyboard/hover/focus/check/uncheck/select/drag/
#       upload/download/scroll/scrollintoview/wait/screenshot/pdf/snapshot/eval/connect/
#       close/session/back/forward/reload/get/is/find — external_deps.md §1.1) AND
#   d. unrecognized commands (contract step d: "default to 'driving' — let the real binary
#      handle the error"). Because (c) and (d) BOTH yield 'driving', the DRIVING set is NOT
#      enumerated in code — detecting META + defaulting the rest is identical and stays
#      correct as agent-browser adds driving commands (mouse, react, …).
#   e. No command found (only flags / empty $@) → 'meta' (passthrough — a help/usage request, like --help; Issue 4).
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle step 0; unit tests (M9).
#
# GOTCHA — return 0 ALWAYS. No failure mode ⇒ the caller's
#   `class="$(pool_dispatch_classify "$@")"` is set -e-safe with NO guard (unlike
#   pool_lease_find_mine which returns 1 on no-match and REQUIRES an `if` guard).
# GOTCHA — NO precondition. Callable BEFORE pool_config_init / pool_owner_resolve (dispatch
#   is PRD §2.4 STEP 0, before owner resolution step 1). Reads NO POOL_* globals. This also
#   makes it unit-testable with zero fixtures.
# GOTCHA — the loop guard `while (( $# > 0 ))` is a CONDITION (errexit-exempt). A BARE
#   `(( expr ))` statement whose value is 0 returns rc 1 and ABORTS under set -e
#   (lib/pool.sh:362-364). Shift-based iteration (NO index counter) avoids the
#   `(( i++ ))`-returns-0 trap entirely.
# GOTCHA — `shift 2 || shift` for --session: the `||`-list is errexit-exempt; tolerates a
#   trailing --session with no value (shift 2 fails → shift consumes just --session).
# GOTCHA — 'session list' (two-word) is META; bare 'session' is DRIVING. The lookahead
#   peeks the token immediately after the command (`next="${2:-}"`). session ∈ DRIVING so
#   'session <other>' → 'driving' via the default.
# GOTCHA — SCOPE: CLASSIFIES ONLY. Does NOT intercept 'close --all' / normalize 'connect'
#   (M6.T1.S2), strip '--session' / force AGENT_BROWSER_SESSION (M6.T2.S1), or wire the
#   lifecycle (M6.T3.S1). Here connect & close simply classify 'driving'.
# PRECONDITION: none. The function is pure.
pool_dispatch_classify() {
    local tok cmd next
    cmd=""
    while (( $# > 0 )); do
        tok="$1"
        case "$tok" in
            --help|-h|--version)
                printf 'meta\n'
                return 0
                ;;
            --session)
                # Space form: consume the flag AND its value. `|| shift` tolerates a
                # trailing --session with no value (shift 2 fails → shift 1). The `||`
                # list is errexit-exempt.
                shift 2 || shift
                ;;
            --*)
                # Any other long flag: --json, --session=X (equals form), --headed, …
                shift
                ;;
            -*)
                # Any short flag except -h (caught above): -i, -c, -d, -p, -v, -q, …
                shift
                ;;
            *)
                # First non-flag token = the command. Peek the next token (for the
                # 'session list' two-word META command) and stop scanning.
                cmd="$1"
                next="${2:-}"
                break
                ;;
        esac
    done

    # No command token found (only flags / empty $@) → 'meta' (passthrough). A
    # subcommand-less invocation is a help/usage request (upstream prints help + exits 0),
    # not a driving action — mirrors the --help/-h/--version short-circuit above (Issue 4).
    if [[ -z "$cmd" ]]; then
        printf 'meta\n'
        return 0
    fi

    # META classification. (The DRIVING set + unrecognized commands all fall through to
    # the default 'driving' below — contract steps c & d.)
    if [[ "$cmd" == session && "$next" == list ]]; then
        printf 'meta\n'
        return 0
    fi
    case "$cmd" in
        skills|dashboard|plugin|mcp)
            printf 'meta\n'
            return 0
            ;;
    esac

    # Everything else → 'driving' (DRIVING set + unrecognized; contract c & d).
    printf 'driving\n'
    return 0
}

# =============================================================================
# Wrapper shim — arg normalization (P1.M6.T1.S2)
# =============================================================================
# PRD §2.4 / §2.15 transparency normalizers. Rewrite an agent's DRIVING argv so the
# pool — not the agent — controls connection & teardown scope. Called by the wrapper
# lifecycle (M6.T3.S1) AFTER pool_dispatch_classify returned 'driving' and the lane is
# acquired, BEFORE M6.T2.S1 strips --session / forces AGENT_BROWSER_SESSION.
#
# Output channel = the GLOBAL ARRAY POOL_NORM_ARGS (declare -ga) — NOT stdout (argv can
# contain spaces/newlines; stdout is unsafe for an array). pool_normalize_close also sets
# the scalar GLOBAL POOL_CLOSE_ALL_SEEN (0/1). Both functions return 0 ALWAYS; stdout EMPTY.
# They read ONLY "$@" (NO config globals) → callable after a bare `source lib/pool.sh`.

# pool_normalize_close [--] ARGS...
#
# If the command is 'close', strip EVERY standalone '--all' token (a raw --all would nuke
# ALL daemon sessions incl. other agents' lanes — PRD §2.4/§2.15). All other tokens
# (--json, --session <X>, the literal 'close', extra args) are PRESERVED in order. If the
# command is NOT 'close', POOL_NORM_ARGS = args UNCHANGED (--all is left alone: it may be a
# legitimate token for another command, e.g. `find role x --all`).
#
# Sets POOL_CLOSE_ALL_SEEN=1 iff at least one '--all' was stripped from a close command
# (else 0) — the contract's "set a flag to close ONLY my session"; the lifecycle's
# observability hook. The ACTUAL session-scoping is: strip --all (here) + force
# --session abpool-<N> (M6.T2.S1) → the real exec is `close --session abpool-<N>`.
#
# LOGIC:
#   a. Scan $@ (mirroring pool_dispatch_classify) to find the COMMAND (first non-flag):
#        --session <X>  → skip 2 (consume flag + value)
#        --session=<X>  → skip 1 (caught by --*)
#        <any --flag>   → skip 1 (caught by --*; treated as bool — MIRRORS classify)
#        <any -short>   → skip 1 (caught by -*)
#        <non-flag>     → the COMMAND; stop.
#   b. Rebuild from the ORIGINAL args: drop every token whose value is exactly '--all'
#      IFF the command == 'close'. Track seen_all.
#   c. POOL_NORM_ARGS = rebuilt array; POOL_CLOSE_ALL_SEEN = seen_all. Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_NORM_ARGS, NOT stdout. stdout stays EMPTY. The
#   caller reads "${POOL_NORM_ARGS[@]}". (argv may contain spaces → stdout is unsafe.)
# GOTCHA — return 0 ALWAYS; no failure mode ⇒ the caller needs NO if-guard.
# GOTCHA — --session is PRESERVED (only skipped during the scan). M6.T2.S1 strips it.
# GOTCHA — the index counter uses `i=$((i+1))` (assignment, always rc 0), NEVER `(( i++ ))`
#   (returns rc 1 when i==0 → ABORT under set -e; lib/pool.sh:362-365). The only (( )) are
#   `while (( i < ${#orig[@]} ))` (cond, exempt) — no if-cond needed here.
# GOTCHA — MIRRORS pool_dispatch_classify's scan exactly so the two siblings agree on the
#   command token (do NOT enumerate agent-browser value-flags). Safe for close --all.
# PRECONDITION: none. Reads only "$@".
# shellcheck disable=SC2034 # POOL_NORM_ARGS/POOL_CLOSE_ALL_SEEN are OUTPUT-only contracts
# read by the wrapper (M6.T3.S1) + tests (M9).
pool_normalize_close() {
    local -a orig=("$@") out=()
    local cmd="" tok seen_all=0
    local i=0

    # --- a. Find the COMMAND (mirror pool_dispatch_classify's flag-scan), index-based. ---
    # `i=$((i+N))` is an ASSIGNMENT (always rc 0) — avoids the bare-(( i++ )) trap. The
    # `while (( ))` is a CONDITION (errexit-exempt). --session consumes its value (skip 2);
    # all other flags skip 1 (matches classify's "all --* ⇒ shift-1" shortcut).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;   # space form: flag + value
            --session=*)    i=$((i+1)) ;;   # equals form: value attached
            --*)            i=$((i+1)) ;;   # --json, --all, --cdp, … (MIRRORS classify: bool)
            -*)             i=$((i+1)) ;;   # -i -c -d -p …
            *)              cmd="$tok"; break ;;   # first non-flag = COMMAND
        esac
    done

    # --- b. Rebuild from ORIGINAL args; drop every '--all' IFF cmd==close. ---
    for tok in "${orig[@]}"; do
        if [[ "$cmd" == close && "$tok" == --all ]]; then
            seen_all=1
            continue
        fi
        out+=("$tok")
    done

    # --- c. Emit normalized argv + flag; return 0 ALWAYS. ---
    # declare -ga NAME=( … ) is the canonical atomic global-array+assign form (keeps values,
    # clean under shellcheck). The scalar flag uses the assign-then-declare-g idiom (pool_chrome_launch @1514).
    declare -ga POOL_NORM_ARGS=( "${out[@]}" )
    POOL_CLOSE_ALL_SEEN=$seen_all
    declare -g POOL_CLOSE_ALL_SEEN
    return 0
}

# pool_normalize_connect [--] ARGS...
#
# If the command is 'connect', strip the SINGLE <port|url> positional that follows it (the
# upstream skill teaches `connect <port>`; the lane's real connection is owned by
# pool_ensure_connected / PRD §2.4 step 4 using the LANE's port from the lease). Flags
# (--json, --session <X>) are PRESERVED. If the command is NOT 'connect', POOL_NORM_ARGS =
# args UNCHANGED.
#
# LOGIC:
#   a. Scan $@ (mirroring classify) to find the COMMAND.
#   b. If cmd != 'connect' → POOL_NORM_ARGS = args UNCHANGED; return 0.
#   c. If cmd == 'connect': CONTINUE scanning PAST the command; the FIRST non-flag token
#      (skipping --session's value, --session=X, --json, etc.) is the <port|url> positional.
#      Record its index. (Bare `connect` with no positional → nothing to strip.)
#   d. Rebuild POOL_NORM_ARGS = args MINUS that one positional (order + flags preserved).
#      Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — bare `connect` (no positional) is a RUNTIME ERROR in the real binary (exit 1,
#   "<port|url> required"). After this strip the result is bare `connect`. PRD §2.4 step 4
#   (pool_ensure_connected) ALREADY binds the lane's daemon — so pool_wrapper_main (M6.T3.S1)
#   must NOT naively exec a bare connect (the agent would see the error → breaks §2.15
#   transparency). RESOLVED (Issue #1): pool_wrapper_main detects the bare connect (via
#   _pool_clean_args_is_bare_connect) and short-circuits to a success no-op. This function
#   strips the arg per contract; the bare-result handling is pool_wrapper_main step k.
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_NORM_ARGS, NOT stdout. stdout stays EMPTY.
# GOTCHA — return 0 ALWAYS. Does NOT touch POOL_CLOSE_ALL_SEEN.
# GOTCHA — --session is PRESERVED (only its value is skipped during the positional scan).
# GOTCHA — strips only the FIRST non-flag positional after connect (agent-browser connect
#   takes exactly one <port|url>); extra stray positionals (malformed) are left for the
#   binary to error on.
# PRECONDITION: none. Reads only "$@".
# shellcheck disable=SC2034 # POOL_NORM_ARGS is an OUTPUT-only contract read by the wrapper
# (M6.T3.S1) + tests (M9).
pool_normalize_connect() {
    local -a orig=("$@") out=()
    local cmd="" tok
    local i=0 strip_idx=-1
    local j=0

    # --- a. Find the COMMAND (mirror classify), index-based. ---
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;
            -*)             i=$((i+1)) ;;
            *)              cmd="$tok"; i=$((i+1)); break ;;   # command found; advance PAST it
        esac
    done

    # --- b. Not connect → unchanged. ---
    if [[ "$cmd" != connect ]]; then
        declare -ga POOL_NORM_ARGS=( "${orig[@]}" )
        return 0
    fi

    # --- c. cmd==connect: find the FIRST non-flag positional AFTER the command (the <port|url>). ---
    # Continues the SAME scan from where phase (a) left off (i already points just past `connect`).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;   # skip flag + value
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;   # skip --json etc. (preserve them; not stripped)
            -*)             i=$((i+1)) ;;
            *)              strip_idx=$i; break ;;   # the <port|url> positional
        esac
    done

    # --- d. Rebuild MINUS strip_idx (or unchanged if no positional was found). ---
    # `if (( j == strip_idx ))` is an if-CONDITION (errexit-exempt). When strip_idx==-1 (no
    # positional) the test is never true → out == orig. `j=$((j+1))` is the safe counter form.
    for tok in "${orig[@]}"; do
        if (( j == strip_idx )); then
            j=$((j+1))
            continue
        fi
        out+=("$tok")
        j=$((j+1))
    done

    declare -ga POOL_NORM_ARGS=( "${out[@]}" )
    return 0
}

# =============================================================================
# Wrapper shim — session override (P1.M6.T2.S1)
# =============================================================================
# PRD §2.4 step 5 / §2.15 transparency. Neutralize an agent's attempt to bypass its
# lane via the upstream-skill-taught --session <X> flag or an inherited
# AGENT_BROWSER_SESSION=<X> env var. Called by the wrapper lifecycle (M6.T3.S1) AFTER
# pool_dispatch_classify returned 'driving', AFTER M6.T1.S2's close/connect normalize,
# and AFTER acquire + ensure_connected, but BEFORE the exec.
#
# HOST-VERIFIED precedence (agent-browser 0.28.0): the --session <name> FLAG WINS over
# the AGENT_BROWSER_SESSION env var (the env is the fallback when no flag is given).
# ⇒ NEITHER strip-alone NOR force-alone suffices. BOTH are required:
#     pool_strip_session_args  → remove every --session from the argv
#     pool_force_session       → export AGENT_BROWSER_SESSION=abpool-<lane>
#   so the env var is the SOLE session source, pinned to the agent's lane.

# pool_strip_session_args [--] ARGS...
#
# Pure argv transform: remove EVERY '--session <X>' (space form: flag + value) and
# '--session=<X>' (equals form: single token) from ARGS, preserving all other tokens
# (other --flags, -shortflags, positionals, args with spaces/newlines) in original order.
# Writes the cleaned argv to the GLOBAL ARRAY POOL_CLEAN_ARGS (declare -ga). Returns 0
# ALWAYS (removing a token that isn't there is a valid no-op). stdout: EMPTY.
#
# LOGIC (CONTRACT a, research codebase-internal §3/§5):
#   - Snapshot $@ into local -a orig=("$@").
#   - Walk orig with an index i; rebuild into local -a out=():
#        --session      → if a next token exists: i+=2 (drop flag + value); else i+=1 (drop trailing flag)
#        --session=*    → i+=1 (drop the single equals-form token)
#        <anything else>→ out+=("$tok"); i+=1   (KEEP verbatim, incl. --session-name)
#   - POOL_CLEAN_ARGS = out. Return 0.
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle (passes ${POOL_NORM_ARGS[@]} from M6.T1.S2 as
#   the args); unit tests (M9).
#
# GOTCHA — OUTPUT is the GLOBAL ARRAY POOL_CLEAN_ARGS, NOT stdout. stdout stays EMPTY.
#   The caller reads "${POOL_CLEAN_ARGS[@]}". (argv may contain spaces → stdout is unsafe.)
# GOTCHA — return 0 ALWAYS; no failure mode ⇒ the caller needs NO if-guard.
# GOTCHA --session-name is NOT stripped (different feature: cookie/localStorage persistence;
#   research bash-external §6). Only --session / --session=<X> are removed.
# GOTCHA — multiple --session are ALL dropped; trailing --session (no value) is dropped
#   without reading past the array end (the i+1<${#orig[@]} guard).
# GOTCHA — the index counter uses `i=$((i+N))` (assignment, always rc 0), NEVER `(( i++ ))`
#   (returns rc 1 when i==0 → ABORT under set -e; lib/pool.sh:360-365). The only (( )) are
#   `while (( i < ${#orig[@]} ))` (cond, exempt) and `if (( i+1 < ${#orig[@]} ))` (cond, exempt).
# GOTCHA — MIRRORS pool_dispatch_classify's scan case-arms (--session / --session=*) so the
#   wrapper-shim siblings agree on what a --session token is.
# GOTCHA — POOL_CLEAN_ARGS is DISTINCT from M6.T1.S2's POOL_NORM_ARGS (pipeline:
#   POOL_NORM_ARGS → strip → POOL_CLEAN_ARGS → exec). This function reads only "$@" (it does
#   NOT reference POOL_NORM_ARGS) → decoupled from the parallel sibling.
# PRECONDITION: none. Reads only "$@".
pool_strip_session_args() {
    local -a orig=("$@") out=()
    local i=0 tok

    # Walk orig with an index; rebuild into out MINUS every --session token. `i=$((i+N))`
    # is an ASSIGNMENT (always rc 0) — avoids the bare-(( i++ )) trap (lib/pool.sh:360-365).
    # The `while (( ))` and `if (( ))` are CONDITIONS (errexit-exempt).
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)
                # Space form: drop the flag AND its value (if a next token exists).
                # Trailing `--session` with no value → drop just the flag (i+=1).
                if (( i+1 < ${#orig[@]} )); then
                    i=$((i+2))
                else
                    i=$((i+1))
                fi
                ;;
            --session=*)
                # Equals form: single combined token (--session=X) → drop it.
                i=$((i+1))
                ;;
            *)
                # KEEP everything else verbatim (incl. --session-name, --json, positionals).
                out+=("$tok")
                i=$((i+1))
                ;;
        esac
    done

    # Emit the cleaned argv via the GLOBAL ARRAY (atomic single-statement; REPLACES each
    # call — no stale elements; empty out → POOL_CLEAN_ARGS=() with 0 elements).
    # shellcheck disable=SC2034 # POOL_CLEAN_ARGS is an OUTPUT-only contract read by the
    # wrapper (M6.T3.S1) + tests (M9); this lib writes it, it does not read it back.
    declare -ga POOL_CLEAN_ARGS=( "${out[@]}" )
    return 0
}

# pool_force_session LANE
#
# Export AGENT_BROWSER_SESSION=abpool-<LANE> into the CALLING shell's environment so the
# later `exec "$POOL_REAL_BIN" …` (M6.T3.S1) inherits it. Because pool_strip_session_args
# removed any --session flag, this env var is the SOLE session source → the agent cannot
# bypass its lane. Validates LANE is a non-negative integer; returns 1 (non-fatal, no
# export) on a bad lane. stdout: EMPTY.
#
# LOGIC (CONTRACT b, research bash-external §4):
#   - lane="${1:-}"  (set -u safe)
#   - [[ "$lane" =~ ^[0-9]+$ ]] || return 1   (non-numeric/empty/negative → do-no-harm)
#   - export AGENT_BROWSER_SESSION="abpool-$lane"   (persists in calling shell; inherited by exec)
#   - return 0
#
# CONSUMERS: M6.T3.S1 wrapper lifecycle; unit tests (M9).
#
# GOTCHA — `export` inside a function (no $(...) / no pipe) runs in the CALLING shell →
#   the env var PERSISTS after the function returns AND is inherited by a later exec.
#   Host-verified (bash-external §4).
# GOTCHA — NON-FATAL rc 0/1 (never pool_die): mirrors pool_daemon_connect @1630 /
#   pool_daemon_connected @1680. The caller MUST guard: `if pool_force_session "$N"; then …`.
# GOTCHA — on rc 1 we return WITHOUT exporting (do-no-harm: any prior AGENT_BROWSER_SESSION
#   is left untouched).
# GOTCHA — a SUCCESSFUL export OVERWRITES any inherited AGENT_BROWSER_SESSION (that is the
#   point — "strip inherited AGENT_BROWSER_SESSION" collapses to one overwrite export).
# GOTCHA — does NOT touch AGENT_BROWSER_SESSION_NAME (different feature; bash-external §6).
# PRECONDITION: none (reads only $1; no config/init needed).
pool_force_session() {
    local lane="${1:-}"

    # Validate lane: non-negative integer. `[[ ]] || return 1` is errexit-exempt.
    # Bad lane (empty/non-numeric/negative) → return 1 WITHOUT exporting (do-no-harm).
    [[ "$lane" =~ ^[0-9]+$ ]] || return 1

    # Force the lane session. export VAR=val is ShellCheck-clean (no cmd-sub → no SC2155).
    # Persists in the calling shell; inherited by the later exec.
    export AGENT_BROWSER_SESSION="abpool-$lane"
    return 0
}

# =============================================================================
# Wrapper shim — complete lifecycle (P1.M6.T3.S1)
# =============================================================================
# PRD §2.4 steps 0→5 — the orchestration entry point. Called by bin/agent-browser
# (M6.T3.S2) as its FINAL statement (`pool_wrapper_main "$@"`; the shim runs nothing
# after it). TERMINAL by design: every success path ends in `exec "$POOL_REAL_BIN" …`
# (process replacement — never returns); every fatal path ends in `pool_die` (exit 1).
# There is NO `return` on the success path — there is no caller state to resume.
#
# This is the ONLY place the full pipeline is wired. It COMPOSES (does not re-implement):
#   - M6.T1.S1 pool_dispatch_classify   (step c: meta vs driving)
#   - M6.T1.S2 pool_normalize_close/connect (step i: scope close --all, strip connect positional)
#   - M6.T2.S1 pool_strip_session_args / pool_force_session (step j: neutralize --session + env)
#   - M2    pool_owner_resolve          (step d: find the owning pi; ==0 ⇒ human terminal)
#   - M3    pool_lease_find_mine        (step e: reuse my live lane)
#   - M5    pool_acquire_locked / pool_wait_for_lane (step f: get a lane)
#           pool_boot_lane              (step g: boot a provisional lane)
#           pool_ensure_connected       (step h: per-call self-heal)
#
# THE LANE FLOWS VIA STDOUT, NOT A GLOBAL. pool_lease_find_mine / pool_acquire_locked /
# pool_wait_for_lane all `printf '%s\n' "$N"` and set NO global (verified: no
# POOL_FOUND_LANE / POOL_ACQUIRED_LANE in this file). The wrapper captures N via
# `local N; … if N="$(…)"` — NEVER `local N="$(…)"` (SC2155 masks errexit; BashFAQ 105).
#
# BOOT-VS-ADOPT: pool_acquire_locked returns a PROVISIONAL lease (port=0) on the
# choose-N path, OR an ADOPTED orphan (port>0, already booted) on the reuse-orphan path.
# The wrapper reads `port="$(pool_lease_field "$N" port)" || port=""` and boots ONLY when
# port ∈ {"0","",null}. Booting an adopted lane would re-copy/re-launch (wasteful + racy).
#
# RC TAXONOMY (which helpers need an `if`/`||` guard under set -e):
#   rc 0 ALWAYS (no guard):  pool_dispatch_classify, pool_normalize_close/connect,
#                            pool_strip_session_args, pool_config_init, pool_state_init,
#                            pool_owner_resolve (config/state/owner pool_die on FATAL misconfig)
#   rc 0/1 NON-FATAL (guard): pool_lease_find_mine, pool_acquire_locked, pool_wait_for_lane,
#                            pool_lease_field, pool_force_session
#   rc 0/1, rc 1 ⇒ lane GONE: pool_boot_lane      (rc 1 ⇒ _pool_release_lane_internals already ran)
#   rc 0/1, rc 1 ⇒ lane KEPT: pool_ensure_connected (NEVER drops the lane; reaper's job later)
#   pool_die FATAL (propagates): inside pool_boot_lane / pool_ensure_connected (chrome instant-exit)
#
# GOTCHA — TERMINAL: all four exits are exec (b/c/d/k) or pool_die. NO return on success.
# GOTCHA — passthrough exec (b/c/d) passes the ORIGINAL "$@" UNCHANGED (PRD §2.4 step 0:
#   "exec real binary unchanged"; §2.15: "skills get core → passthrough (unaffected)"). ONLY
#   step k (driving) uses the cleaned "${POOL_CLEAN_ARGS[@]}".
# GOTCHA — POOL_DISABLE is read AFTER pool_config_init (which freezes it @176). Step b reads
#   the FROZEN global, not the raw env var.
# GOTCHA — pool_boot_lane rc 1 ⇒ lane DROPPED ⇒ pool_die (no in-place retry; re-entering
#   acquire with the same exhausted state would loop).
# GOTCHA — pool_ensure_connected rc 1 ⇒ lane NOT dropped ⇒ pool_die (surface the failure;
#   reaper cleans up on the agent's NEXT acquire). Do NOT retry in-place.
# GOTCHA — the connect-normalize may leave a bare `connect` in POOL_NORM_ARGS; after
#   session-stripping the wrapper SHORT-CIRCUITS it (step k) to a success no-op — pool_ensure_connected
#   (step h) already bound the daemon, so exec'ing
#   `agent-browser --session abpool-<N> connect` is a harmless no-op connect.
# GOTCHA — close --all interception: pool_normalize_close sets POOL_CLOSE_ALL_SEEN=1 iff it
#   stripped ≥1 --all from a close cmd. Log it for observability (PRD §2.15).
# PRECONDITION: none (pool_config_init + pool_state_init are step a — the first thing run).
# CONSUMES: POOL_DISABLE, POOL_REAL_BIN, POOL_OWNER_PID, POOL_WAIT, POOL_NORM_ARGS,
#   POOL_CLOSE_ALL_SEEN, POOL_CLEAN_ARGS (all set by the helpers above).
# EXPORTS (via pool_force_session): AGENT_BROWSER_SESSION=abpool-<N> (inherited by the step-k exec).
pool_wrapper_main() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"` — declare then assign).
    local class N port _has_json _a

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # config freezes POOL_DISABLE, POOL_REAL_BIN, POOL_WAIT, POOL_LANES_DIR, POOL_LOCK_FILE.
    # state idempotently mkdirs lanes/ + touches acquire.lock.
    pool_config_init
    pool_state_init

    # --- b. safety valve (PRD §2.17): POOL_DISABLE==1 → passthrough, no pooling ---
    # Read the FROZEN global (config_init just set it). ORIGINAL "$@" unchanged.
    if [[ "${POOL_DISABLE:-0}" == "1" ]]; then
        _pool_log "pool_wrapper_main: POOL_DISABLE=1 → passthrough"
        exec "$POOL_REAL_BIN" "$@"
    fi

    # --- c. dispatch (step 0): meta → exec passthrough UNCHANGED -----------------
    # pool_dispatch_classify is rc 0 ALWAYS (no guard); prints exactly one token meta|driving.
    # Plain assignment (class declared above) → SC2155-clean + errexit-safe (classify never fails).
    class="$(pool_dispatch_classify "$@")"
    if [[ "$class" == "meta" ]]; then
        _pool_log "pool_wrapper_main: meta command → passthrough"
        exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — skills/--help/session list/etc.
    fi

    # --- d. owner resolution (step 1): no pi ancestor → passthrough --------------
    # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ human in terminal).
    pool_owner_resolve
    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
        _pool_log "pool_wrapper_main: no pi ancestor → passthrough (human terminal)"
        exec "$POOL_REAL_BIN" "$@"           # UNCHANGED — raw upstream tool for humans
    fi

    # --- e→g. find-or-acquire my lane (steps 2→3) --------------------------------
    # Lane is STDOUT-only. Split capture (`local N` above; `N="$(…)"` here) inside an `if` keeps
    # rc 1 set -e-safe (the condition is just false). NEVER `local N="$(…)"` (SC2155 masks rc 1).
    if N="$(pool_lease_find_mine)"; then
        # Found my LIVE lane → reuse it (skip acquire + boot). Go to step h (ensure connected).
        _pool_log "pool_wrapper_main: reusing lane $N"
    else
        # Not found → acquire (step 3). Fallback to wait-for-lane on exhaustion.
        if ! N="$(pool_acquire_locked)"; then
            if ! N="$(pool_wait_for_lane)"; then
                # True exhaustion: timeout + force-reap yielded nothing. Surface to the agent.
                pool_die "agent-browser-pool: no lane available after ${POOL_WAIT:-600}s + force-reap"
            fi
        fi

        # --- g. boot-vs-adopt ------------------------------------------------
        # pool_lease_field is rc 0/1 (returns 1 on missing/corrupt) → guard with `|| port=""`
        # (||-list is errexit-exempt). A PROVISIONAL lease has port=0; an ADOPTED orphan has port>0.
        port="$(pool_lease_field "$N" port)" || port=""
        if [[ "$port" == "0" || -z "$port" || "$port" == "null" ]]; then
            # Provisional → boot it (copy+port+launch+connect). rc 1 ⇒ lane was DROPPED → pool_die
            # (no in-place retry; re-entering acquire with the same exhausted state would loop).
            _pool_log "pool_wrapper_main: booting provisional lane $N"
            pool_boot_lane "$N" || pool_die "agent-browser-pool: boot failed for lane $N"
        else
            # Adopted orphan (port>0, already booted) → SKIP boot (would re-copy/re-launch).
            _pool_log "pool_wrapper_main: adopted orphan lane $N (port=$port) → skip boot"
        fi
    fi

    # --- h. ensure connected (step 4): per-call self-heal -----------------------
    # rc 1 ⇒ lane unusable but NOT dropped (reaper's job on next acquire). pool_die surfaces it.
    # Do NOT retry in-place (would hit the same dead Chrome).
    pool_ensure_connected "$N" || pool_die "agent-browser-pool: lane $N not connected; aborting"

    # --- i. arg normalization (step 5, first half) ------------------------------
    # Both rc 0 ALWAYS (no guard). pool_normalize_close writes POOL_NORM_ARGS + POOL_CLOSE_ALL_SEEN;
    # pool_normalize_connect OVERWRITES POOL_NORM_ARGS (chained: read ${POOL_NORM_ARGS[@]} → write it).
    pool_normalize_close "$@"
    pool_normalize_connect "${POOL_NORM_ARGS[@]}"

    # --- j. session override (step 5, second half) ------------------------------
    # pool_strip_session_args is rc 0 ALWAYS; writes POOL_CLEAN_ARGS (every --session removed).
    # pool_force_session is rc 0/1; exports AGENT_BROWSER_SESSION=abpool-<N> (persists; inherited by exec).
    pool_strip_session_args "${POOL_NORM_ARGS[@]}"
    pool_force_session "$N" || pool_die "agent-browser-pool: bad lane '$N' for session force"

    # Observability: log if we scoped a close --all (PRD §2.15: "close --all → cannot harm peers").
    if [[ "${POOL_CLOSE_ALL_SEEN:-0}" == "1" ]]; then
        _pool_log "pool_wrapper_main: intercepted close --all → scoped to lane $N"
    fi

    # --- k. EXEC the real binary (step 5, terminal) -----------------------------
    # Process replacement (PID stays; exported AGENT_BROWSER_SESSION inherited). UNREACHABLE code
    # after this line. The agent's command now runs against its locked, booted, connected lane.
    #
    # GOTCHA — BARE-CONNECT SHORT-CIRCUIT (Issue #1 / PRD §2.15 transparency):
    #   pool_normalize_connect (step i) strips the agent's `<port|url>` positional because the
    #   pool owns the real connection (pool_ensure_connected, step h, already bound the lane's
    #   daemon). That leaves a BARE `connect` (plus any flags like --json) in POOL_CLEAN_ARGS.
    #   A bare `connect` is a RUNTIME ERROR in the real binary ("<port|url> required", exit 1)
    #   — the agent typed a skill-taught `connect <port>` and would see a spurious failure even
    #   though the lane IS connected. PRD §2.15: the agent must never see a no-idea failure.
    #   So when the cleaned argv is a bare connect (command `connect`, no positional remaining),
    #   short-circuit to a SUCCESSFUL no-op (the lane's daemon is already bound): confirm on
    #   stderr, exit 0. We do NOT exec the erroring bare connect.
    if _pool_clean_args_is_bare_connect "${POOL_CLEAN_ARGS[@]}"; then
        _pool_log "pool_wrapper_main: bare connect → no-op (lane $N already bound by ensure_connected)"
        # Transparency for --json callers (agent-browser's --json convention is
        # {"success":true,...} on stdout): if the agent passed --json, emit a success
        # object so a JSON-parsing caller isn't surprised by empty stdout. Otherwise print a
        # human-friendly confirmation to stderr (stdout stays clean for interactive use).
        _has_json=0
        for _a in "${POOL_CLEAN_ARGS[@]}"; do
            [[ "$_a" == "--json" ]] && _has_json=1
        done
        if (( _has_json )); then
            printf '{"success":true,"data":{"lane":%s,"session":"%s","connected":true}}\n' \
                "$N" "${AGENT_BROWSER_SESSION:-abpool-$N}"
        else
            printf 'agent-browser-pool: connect → already routed to lane %s (session %s)\n' \
                "$N" "${AGENT_BROWSER_SESSION:-abpool-$N}" >&2
        fi
        exit 0
    fi

    exec "$POOL_REAL_BIN" "${POOL_CLEAN_ARGS[@]}"
}

# _pool_clean_args_is_bare_connect ARGS...
#
# Does the cleaned argv represent a BARE `connect` — i.e. the command (first positional)
# is `connect` AND there is NO further positional arg (only leading flags / --json are OK)?
# Returns 0 (true) iff so; returns 1 (false) otherwise.
#
# Why this exists: pool_normalize_connect strips the agent's `<port|url>` positional (the
# pool owns the connection). That leaves a bare `connect`, which the real binary rejects
# ("<port|url> required", exit 1). This predicate lets pool_wrapper_main short-circuit that
# erroring exec into a successful no-op (PRD §2.15 transparency; Issue #1).
#
# LOGIC (mirrors pool_normalize_connect / pool_dispatch_classify's flag-vs-command scan):
#   a. Walk $@; the first NON-flag token (skipping --session/--session=/--*/-*) is the COMMAND.
#   b. If the command is NOT `connect` → return 1.
#   c. Continue scanning PAST the command. If ANY further non-flag positional is found → return 1
#      (a positional survived stripping → not bare, e.g. `connect 98765` somehow passed through).
#   d. No further positional → return 0 (bare connect, possibly with trailing flags).
#
# GOTCHA — a bare `connect` with NO args at all (empty $@) returns 1 (no command found → not
#   a connect). A purely-empty POOL_CLEAN_ARGS also returns 1 (the real exec handles it).
# GOTCHA — return 0/1 ONLY (never pool_die); reads only "$@".
# PRECONDITION: none.
_pool_clean_args_is_bare_connect() {
    local -a orig=("$@")
    local i=0 tok cmd=""

    # --- a. find the COMMAND (first non-flag token) ---
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;
            -*)             i=$((i+1)) ;;
            *)              cmd="$tok"; i=$((i+1)); break ;;
        esac
    done

    # --- b. not connect (or no command at all) → not bare connect ---
    [[ "$cmd" == connect ]] || return 1

    # --- c. scan PAST the command for any further positional ---
    while (( i < ${#orig[@]} )); do
        tok="${orig[i]}"
        case "$tok" in
            --session)      i=$((i+2)) ;;
            --session=*)    i=$((i+1)) ;;
            --*)            i=$((i+1)) ;;
            -*)             i=$((i+1)) ;;
            *)              return 1 ;;   # a positional survived → not bare
        esac
    done

    # --- d. command was connect, no further positional → bare connect ---
    return 0
}

# =============================================================================
# Admin CLI — status (P1.M7.T1.S1)
# =============================================================================
# pool_admin_status
#
# Print a READ-ONLY lane table to stdout for `agent-browser-pool status`
# (PRD §1.5 / §2.12). No input. Iterates EVERY lane (pool_lanes_list), reads each
# lease (pool_lease_read), computes a human age from acquired_at (_pool_age_str),
# and derives a STATE verdict (pool_lane_is_stale + the `connected` field).
#
# OUTPUT COLUMNS (PRD §2.12 order), one space-separated aligned row per lane:
#   LANE       lane number (int)                 — from pool_lanes_list
#   PORT       Chrome DevTools port (int)        — .port
#   SESSION    AGENT_BROWSER_SESSION string      — .session   (truncated 16)
#   OWNER_PID  owning pi process pid (int)       — .owner.pid
#   OWNER_CWD  owner's working dir (path)        — .owner.cwd (truncated 24)
#   CHROME_PID Chrome process pid (int)          — .chrome_pid
#   AGE        time since acquired_at            — _pool_age_str (Ns/Nm/Nh/Nd)
#   STATE      verdict (see below)               — live | STALE | disconnected
#
# STATE precedence (STALE > disconnected > live), from the tri-state
# pool_lane_is_stale (rc 0=STALE / 1=LIVE / 2=NO-LEASE) + the JSON boolean
# `connected` (compare the STRING "false" — never `jq -e`):
#   pool_lane_is_stale rc 0                         → STALE
#   rc 1 (live) or rc 2 (no-lease/TOCTOU):
#       connected == "false"                        → disconnected
#       else                                        → live
# A STALE owner wins regardless of connectivity (the lane is a reapable leak).
#
# EMPTY POOL → prints the single line "No active lanes." and returns 0 (no header).
#
# CONTRACT:
#   - READ-ONLY: kills nothing, deletes nothing. The only side effect is
#     pool_state_init's idempotent mkdir -p of POOL_LANES_DIR.
#   - NEVER calls pool_die; NEVER returns non-zero. A corrupt lease (invalid JSON)
#     or a TOCTOU deletion degrades to a row of "?" fields with state STALE, then
#     continues. The corrupt-lease warning is logged by pool_lease_read to the log
#     FILE + stderr (NOT stdout) → stdout stays a clean, pipeable table.
#   - A stray non-numeric *.json is skipped by pool_lanes_list (never iterated).
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_lease_read returns rc 1 on missing/corrupt → MUST guard:
#     `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …`.
#   - pool_lane_is_stale is tri-state (rc 0/1/2) → MUST call inside `if …; then …`.
#   - never `local x="$(…)"` (SC2155); declare then assign.
#   - `(( ))` only inside if/elif; `$(( ))` expansion is always safe.
#   - acquired_at from a missing field is the STRING "null" → `$(( now - null ))`
#     is an arithmetic error; guard `[[ "$acquired_at" =~ ^[0-9]+$ ]]` first.
#
# PRECONDITION: pool_config_init (for POOL_LANES_DIR) + pool_state_init (mkdir it).
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case status) pool_admin_status ;;`.
pool_admin_status() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`).
    local -a lanes fields
    local fmt json lane
    local port session owner_pid owner_cwd chrome_pid acquired_at connected
    local age state

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_wrapper_main step "a" (lib/pool.sh:3455-3459). pool_state_init's
    # idempotent mkdir -p guarantees POOL_LANES_DIR exists for the pool_lanes_list glob.
    pool_config_init
    pool_state_init

    # Shared fixed-width format string (header + every row). %-N.Ns = truncate to
    # exactly N cols (bare %-Ns does NOT truncate → long cwd/session would misalign).
    # Widths ≥ both the header label and typical data (research §6 / design-decisions D4).
    fmt='%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n'

    # --- b. snapshot lanes into an array (also a clean empty-pool check) ---------
    # Process substitution exit status is NOT propagated → set -e safe (pool_lanes_list
    # returns 0 always anyway). mapfile of empty output → empty array.
    mapfile -t lanes < <(pool_lanes_list)

    # --- c. empty pool → single message, rc 0, NO header ------------------------
    # `(( ))` inside `if` is errexit-exempt (the returns-1-on-zero gotcha does not apply).
    if (( ${#lanes[@]} == 0 )); then
        printf 'No active lanes.\n'
        return 0
    fi

    # --- d. header row ----------------------------------------------------------
    # SC2059 disabled: $fmt is a trusted compile-time constant (hardcoded above), NOT
    # external input — using it as the format string is what GUARANTEES the header and
    # every data row share ONE identical column layout (the alignment invariant).
    # shellcheck disable=SC2059
    printf -- "$fmt" \
        "LANE" "PORT" "SESSION" "OWNER_PID" "OWNER_CWD" "CHROME_PID" "AGE" "STATE"

    # --- e. one row per lane ----------------------------------------------------
    for lane in "${lanes[@]}"; do
        # Read the lease. A bare capture ABORTS under set -e on rc 1 (missing/corrupt) →
        # guard with `if !`. 2>/dev/null suppresses jq's corrupt-parse stderr (the
        # WARNING is logged to file+stderr by pool_lease_read, NOT printed to stdout).
        if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
            # Missing (TOCTOU) OR corrupt: degraded row, keep the table intact.
            # pool_lanes_list already validated lane is numeric, so it is a real lane id.
            # shellcheck disable=SC2059
            printf -- "$fmt" "$lane" "?" "?" "?" "?" "?" "?" "STALE"
            continue
        fi

        # Extract all row fields in ONE jq fork (mirrors pool_lane_is_stale @1175-1178:
        # mapfile -t < <(jq -r '.a, .b, .c' <<<"$json")). `:-` defends a short read.
        mapfile -t fields < <(jq -r \
            '.port, .session, .owner.pid, .owner.cwd, .chrome_pid, .acquired_at, .connected' \
            <<<"$json")
        port="${fields[0]:-}"
        session="${fields[1]:-}"
        owner_pid="${fields[2]:-}"
        owner_cwd="${fields[3]:-}"
        chrome_pid="${fields[4]:-}"
        acquired_at="${fields[5]:-}"
        connected="${fields[6]:-}"

        # AGE from acquired_at. _pool_age_str is rc 0 always, but acquired_at MUST be
        # numeric first: a missing field → "null" → `$(( now - null ))` arithmetic
        # error under set -e. Guard, then call (rc 0 — no further guard needed).
        if [[ "$acquired_at" =~ ^[0-9]+$ ]]; then
            age="$(_pool_age_str "$acquired_at")"
        else
            age="?"
        fi

        # STATE verdict (precedence STALE > disconnected > live).
        # pool_lane_is_stale is TRI-STATE → MUST call inside `if` (a bare rc-1/2 call
        # ABORTS). rc 0 → STALE; rc 1 (live) OR rc 2 (no-lease/TOCTOU) → decide by
        # connectivity (connected is a JSON boolean; compare the STRING "false").
        if pool_lane_is_stale "$lane"; then
            state="STALE"
        else
            if [[ "$connected" == "false" ]]; then
                state="disconnected"
            else
                state="live"
            fi
        fi

        # shellcheck disable=SC2059
        printf -- "$fmt" \
            "$lane" "$port" "$session" "$owner_pid" "$owner_cwd" "$chrome_pid" "$age" "$state"
    done

    return 0
}

# ============================================================================
# Admin CLI — reap (P1.M7.T2.S1)
# ============================================================================
# pool_admin_reap
#
# PRD §2.12 `reap` / §2.10 — the USER-FACING reap report for
# `agent-browser-pool reap`. No input. Calls the LANDED pool_reap_stale
# (M5.T3.S1 — the lazy reaper: scans every lane, releases every stale one,
# echoes the reaped count), CAPTURES that count, and prints a human report to
# stdout. Returns 0 always.
#
# OUTPUT (the ONLY stdout — exactly one line):
#   N == 0  → "No stale lanes found."
#   N  > 0  → "Reaped N stale lane(s)."   (N = the integer from pool_reap_stale)
#
# The literal "lane(s)" handles both singular and plural (do not special-case N=1).
#
# CONTRACT:
#   - DELEGATE: ALL reap logic (lane enumeration, tri-state staleness verdict,
#     full teardown: daemon close + Chrome pgroup kill + rm dir + delete lease)
#     lives in pool_reap_stale. This function does NOT re-implement any of it.
#   - CAPTURE the count: pool_reap_stale writes the raw integer to ITS stdout
#     (for any caller's `count=$(…)`). This function MUST capture it
#     (count="$(pool_reap_stale)") so the integer does NOT leak to the user
#     alongside the message. pool_admin_reap's stdout is PURELY the one report.
#   - NON-FATAL always: NEVER calls pool_die in its own body; NEVER returns
#     non-zero. Reaping 0 lanes is NOT an error → "No stale lanes found." + rc 0.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_reap_stale returns rc 0 ALWAYS (lib/pool.sh:2601) → a bare capture
#     `count="$(pool_reap_stale)"` is SAFE — NO `if !` guard needed. (This is the
#     one place this function is SIMPLER than its sibling pool_admin_status, which
#     must guard pool_lease_read rc 1 / pool_lane_is_stale rc 1/2.)
#   - never `local x="$(…)"` (SC2155); declare then assign.
#   - `(( count == 0 ))` MUST be inside `if` (a bare `(( ))` statement returns 1
#     when the value is 0 → FATAL under set -e). The `$(( ))` expansion form is
#     always safe.
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case reap) pool_admin_reap ;;`.
pool_admin_reap() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`).
    local count

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3604-3606) + pool_wrapper_main step "a"
    # (lib/pool.sh:3455-3459). pool_state_init's idempotent mkdir -p guarantees
    # POOL_LANES_DIR exists (so a fresh pool's first reap works cleanly).
    pool_config_init
    pool_state_init

    # --- b. CAPTURE the reaped count from pool_reap_stale -----------------------
    # pool_reap_stale (M5.T3.S1): scans every lane, releases each stale one (full
    # teardown: close+kill+rm+rmlease), echoes ONE integer = the count reaped, rc 0
    # ALWAYS (non-fatal). The capture is MANDATORY: pool_reap_stale writes the raw
    # integer to ITS stdout — if we did NOT capture it, the integer would leak to
    # the user alongside our message. $() strips the trailing newline → bare token.
    # NO `if !` guard: pool_reap_stale rc 0 always (unlike pool_lease_read/pool_lane_is_stale).
    count="$(pool_reap_stale)"

    # --- c. print the human report (the ONLY stdout write in this function) -----
    # Bare `(( count == 0 ))` returns 1 when count==0 → FATAL under set -e. Inside
    # `if` it is errexit-exempt. count is digits-only (pool_reap_stale's contract),
    # so the arithmetic is always valid. The literal "lane(s)" handles N=1 and N>0.
    if (( count == 0 )); then
        printf 'No stale lanes found.\n'
    else
        printf 'Reaped %d stale lane(s).\n' "$count"
    fi

    # --- d. NON-FATAL always — never pool_die in body, never non-zero -----------
    return 0
}

# ============================================================================
# Admin CLI — release (P1.M7.T3.S1)
# ============================================================================
# pool_admin_release [TARGET]
#
# PRD §2.12 `release [<N>|all]` / §2.5 "Explicit release" — the USER-FACING
# release command. Takes ONE optional argument TARGET (the string "all", a lane
# number N, or empty/invalid), CLASSIFIES it, and explicitly tears down the named
# lane(s) by delegating to the LANDED pool_release_lane (M5.T2.S1 — kill pgroup +
# disconnect daemon + rm dir + delete lease; rc 0 ALWAYS; idempotent). Prints a
# one-line confirmation. Distinct from `reap` (M7.T2.S1): reap is STALE-ONLY
# (pool_reap_stale skips live-owner lanes); release is EXPLICIT (admin-named lane
# is torn down live OR stale).
#
# LOGIC (CONTRACT 3a→3d):
#   a. TARGET == "all"  → snapshot pool_lanes_list; if empty → "No active lanes to
#      release."; else pool_release_lane EACH, then "Released N lane(s)." (N = count).
#      rc 0.
#   b. TARGET is a number AND pool_lease_exists → pool_release_lane TARGET;
#      "Released lane N.". rc 0.
#   c. TARGET is empty OR invalid (not "all", not ^[0-9]+$) → print USAGE to STDERR.
#      rc 1.
#   d. TARGET is a number AND NOT pool_lease_exists → "Lane N has no active lease."
#      rc 1. (Nothing torn down.)
#
# OUTPUT (stdout = the result line; stderr = usage only):
#   release all (N>0)  → stdout: "Released N lane(s)."
#   release all (N==0) → stdout: "No active lanes to release."
#   release N (exists) → stdout: "Released lane N."
#   release N (absent) → stdout: "Lane N has no active lease."
#   release / release foo → stderr: usage block; stdout EMPTY.
#
# The literal "lane(s)" handles both singular and plural (do not special-case N=1).
#
# CONTRACT:
#   - DELEGATE: ALL teardown logic lives in pool_release_lane. This function does NOT
#     re-implement any of it. It classifies + probes existence + delegates + reports.
#   - PROBE BEFORE DELEGATING (the key decision): pool_release_lane is idempotent +
#     rc-0-always + SILENTLY no-ops on a missing lease (lib/pool.sh:2448-2450). So it
#     CANNOT distinguish "I just released lane N" from "lane N had no lease" (BOTH rc 0).
#     The numeric branch MUST probe pool_lease_exists FIRST to pick the right message
#     ("Released lane N." vs "Lane N has no active lease."). In the `all` branch no
#     per-lane probe is needed: pool_lanes_list yields ONLY lanes with a lease.
#   - EXPLICIT, NOT reap: release calls pool_release_lane DIRECTLY (admin-named lane —
#     live OR stale). Do NOT route through pool_reap_stale (stale-only; skips live lanes).
#   - RETURN CODES: rc 0 for successful releases (all cases + numeric-found); rc 1 for
#     usage-error (c) + targeted-not-found (d). This DELIBERATELY diverges from the reap
#     sibling's rc-0-always: release takes an ARGUMENT and can hit "not found", which is a
#     genuine error (Unix convention). NEVER pool_die in the body.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:23):
#   - pool_lease_exists returns rc 1 on missing/corrupt/non-numeric → a BARE call
#     ABORTS under set -e. ALWAYS `if pool_lease_exists "$lane"; then …; else …; fi`
#     (rc 1 falls into else, errexit-exempt). This is the SAME hazard as pool_lane_is_stale.
#   - pool_release_lane returns rc 0 ALWAYS → a BARE call (after the probe passes) is
#     set -e-safe. NO `if !` guard.
#   - pool_lanes_list returns rc 0 ALWAYS → the `mapfile -t lanes < <(pool_lanes_list)`
#     snapshot + any iteration is safe.
#   - never `local x="$(…)"` (SC2155); declare then assign. (`local target="${1:-}"` is a
#     parameter expansion, NOT a `$(…)` capture → SC2155-safe inline.)
#   - `(( ${#lanes[@]} == 0 ))` MUST be inside `if` (a bare `(( ))` statement returns 1
#     when the value is 0 → FATAL under set -e).
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case release) pool_admin_release "$@" ;;`.
pool_admin_release() {
    # Declare ALL locals up front (SC2155). `target` is a parameter expansion (NOT a
    # `$(…)` capture), so inline `local target="${1:-}"` is SC2155-safe. `lanes` is the
    # snapshot array for the `all` branch; `lane` is the loop var.
    local target="${1:-}"
    local -a lanes
    local lane

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3604-3606) + pool_admin_reap
    # (lib/pool.sh:3738-3742) + pool_wrapper_main step "a". pool_state_init's
    # idempotent mkdir -p guarantees POOL_LANES_DIR exists (so a fresh pool's first
    # release — `release all` on an empty pool — works cleanly).
    pool_config_init
    pool_state_init

    # --- classify TARGET: "all" → numeric → else(usage) -------------------------
    if [[ "$target" == "all" ]]; then
        # --- (a) release ALL lanes: snapshot first for an accurate count + clean ---
        # --- empty-pool check (mirrors pool_admin_status @lib/pool.sh:3624/3629). -
        # Process-substitution exit status is NOT propagated → set -e safe. mapfile of
        # empty output → empty array. pool_lanes_list yields ONLY lanes with a lease
        # (numeric *.json stems), so every iterated lane is real.
        mapfile -t lanes < <(pool_lanes_list)
        # `(( ))` inside `if` is errexit-exempt (bare `(( ))` @0 is FATAL under set -e).
        if (( ${#lanes[@]} == 0 )); then
            printf 'No active lanes to release.\n'
            return 0
        fi
        # Release each lane. pool_release_lane is rc 0 ALWAYS (idempotent; non-fatal) →
        # the bare call is set -e-safe. NO per-lane pool_lease_exists probe: pool_lanes_list
        # already guaranteed each lane has a lease. (Contrast the numeric branch, which
        # MUST probe.) A concurrent reap may race a lane away between snapshot + release —
        # pool_release_lane no-ops cleanly on the now-absent lease (rc 0); the summary count
        # reflects the snapshot (acceptable; contract says only "Print summary".)
        # >/dev/null suppresses the delegate's stdout (pool_release_lane runs the
        # `agent-browser … close` subprocess whose `✓ Browser closed` line would otherwise
        # leak into this function's result line — stdout discipline, design-decisions D7.
        # Matches pool_admin_reap @lib/pool.sh:2579 + exhaustion @lib/pool.sh:2952.)
        for lane in "${lanes[@]}"; do
            pool_release_lane "$lane" >/dev/null
        done
        # Literal "lane(s)" handles N=1 and N>0 (no singular special-case — same as reap).
        printf 'Released %d lane(s).\n' "${#lanes[@]}"
        return 0

    elif [[ "$target" =~ ^[0-9]+$ ]]; then
        # --- (b)/(d) numeric: PROBE existence BEFORE delegating (the key guard) ---
        # pool_lease_exists is rc 0 (valid lease) / rc 1 (missing/corrupt/non-numeric).
        # A BARE call with rc 1 ABORTS under set -e → the `if` is MANDATORY (rc 1 falls
        # into else, errexit-exempt). This probe is REQUIRED because pool_release_lane is
        # rc-0-always + silently no-ops on a missing lease — it CANNOT tell us the lane
        # was absent. The probe picks the right message.
        if pool_lease_exists "$target"; then
            # (b) lease EXISTS → delegate the real teardown. pool_release_lane is rc 0
            # ALWAYS → bare call, NO `if !` guard. It reads the lease, disconnects the
            # daemon, kills the Chrome pgroup, rm -rf the dir, deletes the lease.
            # >/dev/null suppresses the delegate's stdout (the `agent-browser … close`
            # subprocess prints `✓ Browser closed` to stdout — that would leak into this
            # function's single result line; stdout discipline, design-decisions D7.
            # Matches pool_admin_reap @lib/pool.sh:2579 + exhaustion @lib/pool.sh:2952.)
            pool_release_lane "$target" >/dev/null
            # %s echoes the target token verbatim ("Released lane 7.").
            printf 'Released lane %s.\n' "$target"
            return 0
        else
            # (d) lease ABSENT → nothing to release. NOT an idempotent success (the admin
            # named a SPECIFIC lane that isn't there) → rc 1 (Unix convention). Nothing is
            # torn down (pool_release_lane was NOT called).
            printf 'Lane %s has no active lease.\n' "$target"
            return 1
        fi

    else
        # --- (c) empty OR invalid (not "all", not ^[0-9]+$) → usage to STDERR ------
        # Usage goes to stderr (the misuse path; conventional). stdout stays EMPTY so a
        # `out="$(pool_admin_release foo)"` captures nothing. rc 1 (usage error). The
        # full --help is the dispatcher's job (M7.T5.S1); this is the function-level
        # fallback the item contract requires ("print usage").
        printf 'Usage: agent-browser-pool release [<N>|all]\n' >&2
        printf '\n' >&2
        printf 'Release (tear down) one lane or all lanes.\n' >&2
        printf '  release N    Release lane N (explicit teardown).\n' >&2
        printf '  release all  Release all active lanes.\n' >&2
        return 1
    fi
}

# ============================================================================
# Admin CLI — doctor (P1.M7.T4.S1)
# ============================================================================
# pool_admin_doctor
#
# PRD §2.12 `doctor` ("reconcile leases vs live Chromes vs dirs; report leaks") +
# §2.16 ("verify all dependencies present at runtime"). The USER-FACING diagnostic
# for `agent-browser-pool doctor`. NO input. READ-ONLY: probes six subsystems, prints
# a sectioned report, returns rc 0/1. Changes NOTHING on disk (unlike reap/release).
#
# LOGIC (CONTRACT a→g):
#   a. DEPS        — command -v each required dep {flock, setsid, pgrep, pkill, cp,
#                    curl, jq} + the Chrome binary ($POOL_CHROME_BIN, name-or-path) +
#                    the OPTIONAL notify-send. Required MISSING → FAIL; notify-send
#                    MISSING → "(optional)", NOT counted.
#   b. REAL BIN    — $POOL_REAL_BIN is a regular file + executable → OK / FAIL.
#   c. FS          — btrfs at $POOL_EPHEMERAL_ROOT (findmnt -T) → OK; non-btrfs +
#                    POOL_ALLOW_SLOW_COPY==1 → WARN; non-btrfs + no-slow-copy → FAIL.
#   d. MASTER      — $POOL_MASTER_DIR exists + non-empty (-d + ls -A) → OK / FAIL.
#   e. RECONCILE LANES — per lease (pool_lanes_list): ephemeral_dir missing → LEAK;
#                    dead chrome_pid → LEAK; port not listening (curl /json/version) →
#                    DISCONNECTED. Each = WARN. A provisional lease (port=0) → ONE WARN
#                    "PROVISIONAL" and the three checks are SKIPPED.
#   f. RECONCILE DIRS  — per numeric dir in $POOL_EPHEMERAL_ROOT: no matching lease →
#                    ORPHAN DIR = WARN.
#   g. SUMMARY     — print "OK=N  WARN=N  FAIL=N" + verdict; return 1 if fail>0 else 0.
#
# SEVERITY MODEL (FAIL = blocking infra; WARN = recoverable lane/dir cruft):
#   FAIL (exit 1): missing required dep; $POOL_REAL_BIN not executable; non-btrfs (no
#                  slow-copy); master missing/empty.
#   WARN (exit 0): non-btrfs + slow-copy; LEAK (no dir / dead chrome); DISCONNECTED;
#                  ORPHAN DIR; PROVISIONAL lease; corrupt/unreadable lease.
#   (not counted): notify-send MISSING (optional).
# Rationale: infra problems BLOCK correct pool operation → FAIL; lane/dir cruft is
#   EXACTLY what reap/release recover from → WARN. doctor = "FAIL = fix setup; WARN =
#   run reap/release." Precedent: brew doctor (advisory vs hard), git fsck (non-zero).
#
# OUTPUT (ALL to stdout — capturable):
#   [dependencies]
#     <dep>           OK | MISSING            (MISSING = FAIL, except notify-send)
#     chrome (<bin>)  OK | MISSING
#     notify-send     OK | MISSING (optional)
#   [binary]
#     <POOL_REAL_BIN> OK | MISSING (not executable)
#   [filesystem]
#     <EPHEMERAL_ROOT> OK (btrfs) | WARN (<fs>; slow-copy allowed) | FAIL (<fs>; not btrfs)
#   [master]
#     <MASTER_DIR>    OK | FAIL (missing or empty)
#   [lanes]
#     lane <N>   OK | WARN (LEAK(no dir); LEAK(dead chrome); DISCONNECTED) | WARN (PROVISIONAL)
#     (no active leases)   ← empty pool
#   [dirs]
#     <dir>      WARN (ORPHAN DIR: no lease)
#     (no ephemeral dirs) | (N dir(s), all leased)
#   [summary]
#     OK=N  WARN=N  FAIL=N
#     Healthy. | Problems found.
#
# CONTRACT:
#   - NON-FATAL probing (THE key constraint): pool_die (lib/pool.sh:30) is `exit 1`
#     (uncatchable). pool_check_btrfs (lib/pool.sh:230) + pool_check_master
#     (lib/pool.sh:266) BOTH pool_die on the failures doctor must DETECT+REPORT —
#     calling them would abort doctor on the FIRST problem before the summary prints.
#     So doctor REPLICATES their detection NON-fatally (findmnt -T / -d + ls -A) with
#     if/else instead of pool_die. This is the ONE place doctor does NOT compose the
#     landed helpers.
#   - READ-ONLY: doctor changes NOTHING. It is a diagnostic, not a recovery tool.
#     Recovery is reap/release (the admin decides from doctor's output).
#   - NEVER pool_die in the body (report, don't die). The ONLY pool_die-capable calls
#     are the precondition pool_config_init/pool_state_init (rc-0-or-pool_die on genuine
#     misconfiguration — correct; matches status/reap/release).
#   - RETURN CODES: rc 0 iff fail==0; rc 1 iff fail>0. WARN NEVER affects rc.
#
# set -e GUARDS (all live — set -euo pipefail at lib/pool.sh:18 [NOT 23 — sibling
# comments citing :23 are STALE]):
#   - command -v returns 1 on an ABSENT dep → a BARE call ABORTS. ALWAYS inside
#     `if command -v …; then …; else …; fi`.
#   - pool_lease_read returns rc 1 on missing/corrupt → a BARE capture ABORTS. ALWAYS
#     `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then …; continue; fi`.
#   - pool_lease_exists returns rc 1 (no lease) → ALWAYS `if ! pool_lease_exists …; then`.
#   - findmnt / curl / ls exit non-zero (missing path / closed port / empty dir) →
#     `|| true` (findmnt, inside $()) or `if`/`if !` (curl, ls -A inside [[ ]]).
#   - `(( ))` ONLY inside `if`/`&&`/`||` (a BARE `(( ))` statement returns 1 when the
#     value is 0 → FATAL). `$(( ))` expansion (`ok=$((ok+1))`) is ALWAYS safe.
#   - never `local x="$(…)"` (SC2155); declare then assign. (`local ok=0` literal is safe.)
#   - nullglob NOT set → a no-match glob "$POOL_EPHEMERAL_ROOT/*/" is its literal →
#     `[[ -d "$d" ]] || continue`.
#
# PRECONDITION: pool_config_init (globals) + pool_state_init (mkdir POOL_LANES_DIR).
#   Both rc-0-or-pool_die (a misconfigured pool fails loudly — correct). No guard.
# CONSUMERS: M7.T5.S1 bin/agent-browser-pool dispatcher: `case doctor) pool_admin_doctor ;;`.
# SUGGESTED --help (for M7.T5.S1 to wire; NOT wired by this task):
#   "  doctor                 diagnose the pool: deps, fs, master, reconcile leases/Chromes/dirs"
pool_admin_doctor() {
    # Declare ALL locals up front (SC2155: never `local x="$(…)"`). `ok/warn/fail` are
    # literal-initialized (safe); every `$(…)` capture is declared-then-assigned below.
    local ok=0 warn=0 fail=0
    local fstype dep chrome_present chrome_label dir_count orphan_count
    local -a lanes fields
    local lane json ephemeral_dir chrome_pid port findings
    local d base

    # --- a. config + state init (rc 0 or pool_die — no guard needed) -------------
    # Mirrors pool_admin_status (lib/pool.sh:3616) + pool_admin_reap + pool_admin_release.
    pool_config_init
    pool_state_init

    # =========================================================================
    # [dependencies] — command -v each required dep + chrome (name-or-path) + notify-send
    # =========================================================================
    printf '[dependencies]\n'
    # Required PATH deps. `command -v` is POSIX-standard + the codebase idiom
    # (_pool_alert lib/pool.sh:2824); preferred over `which` (ShellCheck SC2230).
    # rc 1 (absent) MUST be inside `if` (a bare call ABORTS under set -e).
    # Deps beyond the core set (Issue #7):
    #   findmnt — used by pool_check_btrfs + this doctor's own btrfs probe (missing → empty
    #            fstype, surfaces indirectly as a btrfs FAIL; naming it is more honest).
    #   ss      — used by pool_find_free_port (ss -tlnH) for port allocation. Absence
    #            degrades SILENTLY to a curl-only probe (the || true empty-snapshot path);
    #            no FAIL, no WARN → name it so the operator can see the degradation.
    for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf '  %-22s OK\n' "$dep"
            ok=$((ok+1))
        else
            printf '  %-22s MISSING\n' "$dep"
            fail=$((fail+1))
        fi
    done
    # Chrome — $POOL_CHROME_BIN (configurable via $AGENT_CHROME_BIN; default
    # google-chrome-stable). name-or-path branch (pool_config_init lib/pool.sh:152-174):
    # a path → -f + -x; a bare name → command -v. Checking the LITERAL "google-chrome-stable"
    # would FALSE-alarm on a chromium override.
    chrome_label="$POOL_CHROME_BIN"
    if [[ "$POOL_CHROME_BIN" == */* ]]; then
        if [[ -f "$POOL_CHROME_BIN" && -x "$POOL_CHROME_BIN" ]]; then
            chrome_present=1
        else
            chrome_present=0
        fi
    else
        if command -v "$POOL_CHROME_BIN" >/dev/null 2>&1; then
            chrome_present=1
        else
            chrome_present=0
        fi
    fi
    if (( chrome_present )); then
        printf '  %-22s OK\n' "chrome ($chrome_label)"
        ok=$((ok+1))
    else
        printf '  %-22s MISSING\n' "chrome ($chrome_label)"
        fail=$((fail+1))
    fi
    # notify-send — OPTIONAL (PRD §2.16; _pool_alert guards it lib/pool.sh:2824).
    # Absence is NOT a FAIL (and NOT a WARN) — it is genuinely fine to lack it.
    if command -v notify-send >/dev/null 2>&1; then
        printf '  %-22s OK\n' "notify-send"
        ok=$((ok+1))
    else
        printf '  %-22s MISSING (optional)\n' "notify-send"
    fi

    # =========================================================================
    # [binary] — $POOL_REAL_BIN exists + executable
    # =========================================================================
    printf '[binary]\n'
    if [[ -f "$POOL_REAL_BIN" && -x "$POOL_REAL_BIN" ]]; then
        printf '  %-22s OK\n' "$POOL_REAL_BIN"
        ok=$((ok+1))
    else
        printf '  %-22s FAIL (missing or not executable)\n' "$POOL_REAL_BIN"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [filesystem] — btrfs at $POOL_EPHEMERAL_ROOT (REPLICATE pool_check_btrfs NON-fatally)
    # =========================================================================
    # pool_check_btrfs (lib/pool.sh:230) pool_die's on non-btrfs — doctor must NOT call
    # it (would abort before the summary). Replicate its findmnt -T primitive non-fatally.
    # `-T` is MANDATORY (pool_check_btrfs GOTCHA @217-221; a bare findmnt "$dir" matches
    # SOURCE not the mount tree and exits 1 even on btrfs). `|| true` neutralizes a
    # missing-path exit-1 → fstype becomes "" → "not btrfs".
    printf '[filesystem]\n'
    fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
    if [[ "$fstype" == "btrfs" ]]; then
        printf '  %-22s OK (btrfs)\n' "$POOL_EPHEMERAL_ROOT"
        ok=$((ok+1))
    elif [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]; then
        # Non-btrfs but slow-copy allowed → degraded-but-functional (real 4.8 GB copy per
        # acquire) → WARN. (pool_check_btrfs allows this path too.)
        printf '  %-22s WARN (%s; slow-copy allowed)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"
        warn=$((warn+1))
    else
        printf '  %-22s FAIL (%s; not btrfs)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [master] — $POOL_MASTER_DIR exists + non-empty (REPLICATE pool_check_master NON-fatally)
    # =========================================================================
    # pool_check_master (lib/pool.sh:266) pool_die's on missing/empty — doctor must NOT
    # call it. Replicate its -d + ls -A primitive non-fatally (no stat/du of the 4.8 GB
    # master). `ls -A` inside `[[ -n "$(...)" ]]` is errexit-exempt; 2>/dev/null handles
    # a missing dir.
    printf '[master]\n'
    if [[ -d "$POOL_MASTER_DIR" ]] && [[ -n "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
        printf '  %-22s OK\n' "$POOL_MASTER_DIR"
        ok=$((ok+1))
    else
        printf '  %-22s FAIL (missing or empty)\n' "$POOL_MASTER_DIR"
        fail=$((fail+1))
    fi

    # =========================================================================
    # [lanes] — reconcile each lease: dir present? chrome alive? port listening?
    # =========================================================================
    # Mirror pool_admin_status's snapshot (lib/pool.sh:3631) + per-lane read guard
    # (lib/pool.sh:3638) + ONE-fork jq extraction (lib/pool.sh:3650). pool_lanes_list
    # rc-0-always; process-sub exit not propagated → set -e safe; empty output → empty
    # array.
    printf '[lanes]\n'
    mapfile -t lanes < <(pool_lanes_list)
    if (( ${#lanes[@]} == 0 )); then
        # `(( ))` INSIDE `if` (bare @0 is FATAL under set -e).
        printf '  (no active leases)\n'
    else
        for lane in "${lanes[@]}"; do
            # pool_lease_read rc 1 (missing/corrupt) → MUST guard `if !` (bare ABORTS).
            if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then
                printf '  lane %-6s WARN (corrupt or unreadable lease)\n' "$lane"
                warn=$((warn+1))
                continue
            fi
            # ONE jq fork (mirror status): ephemeral_dir (str), chrome_pid (num), port (num).
            # `:-` defends a short read. jq -r echoes numbers as digit strings (fine for
            # /proc/$chrome_pid and the curl $port interpolation).
            mapfile -t fields < <(jq -r '.ephemeral_dir, .chrome_pid, .port' <<<"$json")
            ephemeral_dir="${fields[0]:-}"
            chrome_pid="${fields[1]:-}"
            port="${fields[2]:-}"
            findings=""
            # Provisional lease (port not a positive integer) → incomplete acquire that was
            # NOT cleaned up. Skip the three checks (they'd spuriously triple-flag a
            # port=0/chrome=0 lease). A persistent provisional lease is itself a leak → WARN.
            # `[[ ]] && (( ))` in a `&&` list is errexit-exempt; `(( ))` only runs if the
            # regex matched (short-circuit) → safe.
            if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then
                # (1) dir present? `[[ ]] || findings+=` : test true → skip; false → append.
                [[ -d "$ephemeral_dir" ]] || findings+='LEAK(no dir); '
                # (2) chrome alive? codebase idiom [[ -d /proc/$pid ]] (pool_owner_alive
                # @636). A booted lane should have chrome_pid>0; 0/invalid → LEAK.
                if [[ "$chrome_pid" =~ ^[0-9]+$ ]] && (( chrome_pid > 0 )); then
                    [[ -d "/proc/$chrome_pid" ]] || findings+='LEAK(dead chrome); '
                else
                    findings+='LEAK(invalid chrome_pid); '
                fi
                # (3) port listening? curl /json/version SIDE-EFFECT-FREE (pool_daemon_connected
                # @1711). --max-time 2 bounds a hung port (pool_find_free_port @1407). rc !=0
                # → DISCONNECTED.
                if curl -sf --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
                    :
                else
                    findings+='DISCONNECTED; '
                fi
                if [[ -z "$findings" ]]; then
                    printf '  lane %-6s OK\n' "$lane"
                    ok=$((ok+1))
                else
                    # Strip the trailing "; " (the `%` removes the shortest suffix match).
                    printf '  lane %-6s WARN (%s)\n' "$lane" "${findings%; }"
                    warn=$((warn+1))
                fi
            else
                printf '  lane %-6s WARN (PROVISIONAL; incomplete acquire)\n' "$lane"
                warn=$((warn+1))
            fi
        done
    fi

    # =========================================================================
    # [dirs] — orphan detection: per numeric dir in $POOL_EPHEMERAL_ROOT, no lease → ORPHAN
    # =========================================================================
    # nullglob NOT set → a no-match glob "$POOL_EPHEMERAL_ROOT/*/" is its literal → `[[ -d ]]
    # || continue` rejects it (+ files + subdirs). Numeric basename filter mirrors
    # pool_lanes_list's ^[0-9]+$ test. pool_lease_exists rc 1 (no lease) → MUST `if !`.
    printf '[dirs]\n'
    dir_count=0
    orphan_count=0
    if [[ -d "$POOL_EPHEMERAL_ROOT" ]]; then
        for d in "$POOL_EPHEMERAL_ROOT"/*/; do
            [[ -d "$d" ]] || continue
            base="${d%/}"           # strip trailing slash
            base="${base##*/}"      # basename
            [[ "$base" =~ ^[0-9]+$ ]] || continue
            dir_count=$((dir_count+1))
            if ! pool_lease_exists "$base"; then
                printf '  %-22s WARN (ORPHAN DIR: no lease)\n' "$d"
                orphan_count=$((orphan_count+1))
                warn=$((warn+1))
            fi
        done
    fi
    if (( dir_count == 0 )); then
        printf '  (no ephemeral dirs)\n'
    elif (( orphan_count == 0 )); then
        printf '  (%d dir(s), all leased)\n' "$dir_count"
    fi

    # =========================================================================
    # [summary] — counts + verdict + return code
    # =========================================================================
    printf '[summary]\n'
    printf '  OK=%d  WARN=%d  FAIL=%d\n' "$ok" "$warn" "$fail"
    # `(( ))` INSIDE `if` (bare @0 would be FATAL). WARN never affects rc.
    if (( fail > 0 )); then
        printf '  Problems found.\n'
        return 1
    fi
    printf '  Healthy.\n'
    return 0
}

# ============================================================================
# Admin CLI — help (P1.M7.T5.S1)
# ============================================================================
# pool_admin_help
#
# The USER-FACING help for `agent-browser-pool --help|-h|help` (PRD §2.12 / §2.15
# transparency — Mode A: this output IS the documentation for the admin tool). NO
# input. Prints usage for every subcommand + the configuration env vars to STDOUT,
# then returns 0. Read by the bin/agent-browser-pool dispatcher's
# `case --help|-h|help) pool_admin_help ;;` branch.
#
# DESIGN (the KEY differentiators from the four admin siblings):
#   - PURE: reads NO global, touches NO disk, does NO $(…). Unlike status/reap/
#     release/doctor (each calls pool_config_init + pool_state_init as step "a"),
#     help is documentation only — it MUST NOT depend on init. (The dispatcher's
#     verbatim init-before-case already ensures globals exist on a normal host; this
#     function itself stays init-free so it is the most robust entry point.)
#   - NEVER pool_die, NEVER return non-zero. Explicit --help is conventional stdout
#     + rc 0 (--help must always succeed; matches `git --help` / `kubectl --help`).
#   - stdout ONLY (capturable: `agent-browser-pool --help | grep release`). No >&2,
#     no log. (Contrast pool_admin_release's misuse-usage → stderr + rc 1 @3909:
#     that is a DIFFERENT case — release called with no/invalid arg. This is the
#     EXPLICIT help request → stdout.)
#
# set -e GUARDS: NONE NEEDED. This function has no $(…) capture, no (( )), no
# command-that-can-fail — only `printf` (always rc 0) + `return 0`. It is the
# simplest admin function (fewest set -e hazards). (set -euo pipefail at lib/pool.sh:18
# [NOT 23 — sibling comments citing :23 are STALE].)
#
# PRECONDITION: NONE (pure function). The dispatcher inits config+state before the
# case; help does not rely on it.
# CONSUMERS: bin/agent-browser-pool dispatcher: `case --help|-h|help) pool_admin_help ;;`.
pool_admin_help() {
    printf 'agent-browser-pool — manage the agent-browser ephemeral-profile pool.\n'
    printf '\n'
    printf 'Usage: agent-browser-pool <command> [args]\n'
    printf '\n'
    printf 'If no command is given, '"'"'status'"'"' is assumed.\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  status                  Print a read-only table of all active lanes:\n'
    printf '                          lane, port, session, owner pid+cwd, chrome pid, age, state.\n'
    printf '  reap                    Tear down lanes whose owning process has died:\n'
    printf '                          kill Chrome, delete the ephemeral profile dir, remove the lease.\n'
    printf '  release [<N>|all]       Explicitly tear down one lane by number, or every lane.\n'
    printf '                          Use '"'"'release all'"'"' to clear the whole pool.\n'
    printf '  doctor                  Diagnose the pool: verify dependencies, the real binary,\n'
    printf '                          the filesystem (btrfs), and the master profile; reconcile\n'
    printf '                          leases against live Chromes and ephemeral dirs; report leaks.\n'
    printf '                          Exits 1 if any check fails, 0 otherwise.\n'
    printf '  help                    Show this help. Aliases: --help, -h.\n'
    printf '\n'
    printf 'Configuration (environment variables; all optional):\n'
    printf '  AGENT_BROWSER_POOL_STATE        state dir (lease store + logs)\n'
    printf '  AGENT_CHROME_MASTER             master profile template (copied per lane)\n'
    printf '  AGENT_CHROME_EPHEMERAL_ROOT     ephemeral lane dir root\n'
    printf '  AGENT_BROWSER_REAL              the real agent-browser binary (shadowed CLI)\n'
    printf '  AGENT_CHROME_BIN                Chrome binary (default: google-chrome-stable)\n'
    printf '  AGENT_CHROME_PORT_BASE          lowest pool TCP port (default: 53420)\n'
    printf '  AGENT_CHROME_PORT_RANGE         number of ports in the pool (default: 1000)\n'
    printf '  AGENT_BROWSER_POOL_WAIT         acquire block timeout, seconds (default: 600)\n'
    printf '  AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes/on)\n'
    printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)\n'
    printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set (1/true/yes/on)\n'
    printf '\n'
    printf "Run 'agent-browser-pool doctor' to verify your setup.\n"
    return 0
}
