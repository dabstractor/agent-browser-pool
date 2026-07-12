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
#   Normalize a tri-state env value to "1" (on) or "0" (off). A var counts as ON only
#   when its value is exactly "1"; every other value (including "true", "yes", "0",
#   and unset) is OFF. Keeps boolean semantics strict and predictable.
_pool_config_bool() {
    local val="${1:-}"
    if [[ "$val" == "1" ]]; then printf '1\n'; else printf '0\n'; fi
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

    # 5. Booleans — exactly "1" → on, anything else → off.
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
