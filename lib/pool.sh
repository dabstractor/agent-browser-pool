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
