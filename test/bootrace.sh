#!/usr/bin/env bash
# bootrace.sh — BUG-001/002 regression suite for changeset 001 (agent-browser-pool).
#
# Purpose: regressions for the crash-recovery master-copy bug (BUG-001) and, later,
# the concurrent-boot race (BUG-002, added by sibling subtask T2.S1).
#
# Safety contract (AGENTS.md):
#   - SINGLE process-spawning setup for the whole suite (never per-test).
#   - Every potentially-blocking subprocess wrapped in `timeout`.
#   - Zero orphan processes left behind (suite trap sweeps everything, `|| true` per line).
#   - Hermetic: HOME/state/ephemeral/config all redirected under one mktemp tree;
#     fake chrome + fake agent-browser only; no operator state touched.
#
# Invocation: bash test/bootrace.sh   (exit 0 iff all cases pass)
#
# --- BUG-002 fixture contract (added by T2.S1) -----------------------------------
# FAKE_CHROME_DELAY       seconds the fake chrome sleeps BEFORE opening the CDP
#                         listener (default 0; validated ^[0-9]+$ inside the fake).
#                         During the delay `curl /json/version` FAILS = the race window
#                         that mis-sends pool_ensure_connected down the relaunch path.
# FAKE_CHROME_COUNT_FILE  path; the fake chrome appends one line "pid port dir" on EVERY
#                         launch, BEFORE the delay sleep (launches killed mid-delay
#                         still count). Suite default: $BR_T/chrome-launches.log; each
#                         case resets it with `: >`.
# FAKE_CP_DELAY (R4)         seconds a PATH-shimmed `cp` (in $BR_T/bin) sleeps BEFORE
#                         copying into the ephemeral root — makes "second command
#                         during the copy, before the port write" DETERMINISTIC.
# _bootrace_setup         ONE suite setup: sandbox + env redirects + fixtures + trap.
# _bootrace_teardown      trap target: kill owners (+wait), pkill fake patterns, rm tree.
#
# Consumers of this harness (add cases here, do not fork the file):
#   P1.M1.T2.S2 (boot lock — R4-style pre-port-race cases)
#   P1.M1.T2.S3 (ensure_connected hardening — drives R3 GREEN)
#   P1.M1.T2.S4 (release sweep widening — leak-assertion cases)
#   P1.M2 (R5–R8 minor-bug cases)
#
# KNOWN-GREEN (post T2.S2 + T2.S3): r3_bug002_race_e2e now EXPECTED TO PASS —
# ensure_connected serializes on the lane boot lock, re-reads the lease under it,
# and gates relaunch on a confirmed-dead /proc/<chrome_pid> — so the suite exits 0
# with ALL cases passing (control, R1, R2, R3-control, R3, R4).
# r3_control_delayed_boot_succeeds is the harness's own green gate; if THAT fails, the
# fixtures are wrong, not the pool.

set -euo pipefail

# --- repo resolution (mirror test/validate.sh) ---------------------------------
BOOTRACE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ABPOOL_REPO="$(cd "$BOOTRACE_DIR/.." && pwd)"

# --- counters + helpers ---------------------------------------------------------
BR_PASS=0
BR_FAIL=0
declare -a BR_FAILED=()
declare -a BR_OWNERS=()

_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-}"
    [[ "$expected" == "$actual" ]] \
        || { _fail "assert_eq${label:+ ($label)}: expected [$expected] got [$actual]"; return 1; }
}

# --- sandbox setup (ONE call for the whole suite) -------------------------------
# Contract names _bootrace_setup/_bootrace_teardown (T2.S1 item contract §4); thin
# wrappers over the _br_* core so both naming schemes stay valid. ONE setup call.
# -p "$HOME": keep the temp tree on the real (btrfs) FS so lanes exercise real cp.
_bootrace_setup() {
    BR_T="$(mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX)"
    mkdir -p -- "$BR_T/home" "$BR_T/state" "$BR_T/active" "$BR_T/master/Default" \
             "$BR_T/bin" "$BR_T/profile-home/.local/bin"

    # A minimal VALID master (pool_check_master requires content — 'Local State' + Default/):
    printf '{"user-experience-enrollment":{"prevalence":0}}\n' >"$BR_T/master/Local State"
    printf '{"marker":"trusted-identity"}\n' >"$BR_T/master/Default/Preferences"
    # TRUSTED-PROFILE MARKER for R2: must land at the lane top level after recovery.
    printf 'master-marker\n' >"$BR_T/master/Default/master-marker.txt"

    trap '_bootrace_teardown' EXIT INT TERM

    HOME="$BR_T/home"
    export HOME
    AGENT_BROWSER_POOL_STATE="$BR_T/state"
    AGENT_CHROME_EPHEMERAL_ROOT="$BR_T/active"
    AGENT_CHROME_MASTER="$BR_T/master"
    AGENT_CHROME_BIN="$BR_T/bin/fake-chrome"
    AGENT_BROWSER_REAL="$BR_T/bin/fake-agent-browser"
    AGENT_CHROME_ALLOW_SLOW_COPY=1
    export AGENT_BROWSER_POOL_STATE AGENT_CHROME_EPHEMERAL_ROOT AGENT_CHROME_MASTER \
           AGENT_CHROME_BIN AGENT_BROWSER_REAL AGENT_CHROME_ALLOW_SLOW_COPY

    # BUG-002 launch counter (suite default; cases reset with `: >`).
    FAKE_CHROME_COUNT_FILE="$BR_T/chrome-launches.log"
    export FAKE_CHROME_COUNT_FILE
    : >"$FAKE_CHROME_COUNT_FILE"
}

# --- fixtures -------------------------------------------------------------------

_br_make_fake_chrome() {
    cat >"$BR_T/bin/fake-chrome" <<'EOF'
#!/usr/bin/env bash
# fake chrome: parse --remote-debugging-port/--user-data-dir from argv; append one
# "pid port dir" line to $FAKE_CHROME_COUNT_FILE (BEFORE the delay — launches killed
# mid-delay still count); sleep ${FAKE_CHROME_DELAY:-0} (the race window: CDP not up
# yet); then serve /json/version and block forever.
port="" dir=""
for a in "$@"; do
    case "$a" in
        --remote-debugging-port=*) port="${a##*=}" ;;
        --user-data-dir=*)         dir="${a##*=}"  ;;
    esac
done
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
if [[ -n "${FAKE_CHROME_COUNT_FILE:-}" ]]; then
    printf '%s %s %s\n' "$$" "$port" "${dir:-<no-dir>}" >>"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || true
fi
if [[ "${FAKE_CHROME_DELAY:-0}" =~ ^[0-9]+$ && "${FAKE_CHROME_DELAY:-0}" -gt 0 ]]; then
    sleep "$FAKE_CHROME_DELAY"
fi
d="$(mktemp -d -t fake-cdp.XXXXXX)"
mkdir -p -- "$d/json"
printf '{"Browser":"FakeChrome/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/fake"}\n' "$port" \
    >"$d/json/version"
cd -- "$d" || exit 1
trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT INT TERM
exec python3 -m http.server "$port" --bind 127.0.0.1
EOF
    chmod +x -- "$BR_T/bin/fake-chrome"
}

_br_make_fake_ab() {
    cat >"$BR_T/bin/fake-agent-browser" <<'EOF'
#!/usr/bin/env bash
# fake agent-browser — satisfies pool_daemon_connect / pool_daemon_connected /
# terminal exec (lib/pool.sh contract):
#   `--session S connect P`            → rc 0 (pool_daemon_connect only checks rc)
#   `--session S --json session list`  → {"success":true,"data":{"sessions":[S]}}
#       (pool_daemon_connected pipes this through
#        jq -e --arg s S '.data.sessions | index($s)' — reporting the QUERIED session
#        makes the check pass: stateless-yet-"connected" after connect)
#   anything else (terminal exec: open/get/…) → rc 0
session="" prev=""
for a in "$@"; do
    [[ "$prev" == "--session" ]] && session="$a"
    prev="$a"
done
case " $* " in
    *" session list "*)
        printf '{"success":true,"data":{"sessions":["%s"]}}\n' "${session:-abpool-1}"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x -- "$BR_T/bin/fake-agent-browser"
}

# Spawn a live sim owner (sleep process) + export the owner env; echo the pid.
_br_spawn_owner() {
    local pid st
    sleep 600 &
    pid=$!
    BR_OWNERS+=("$pid")
    # refresh starttime via the lib helper
    st="$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && _pool_get_starttime "$pid" ) 2>/dev/null || true )"
    AGENT_BROWSER_POOL_OWNER_PID="$pid"
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$st"
    export AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME
    BR_LAST_OWNER="$pid"
    BR_LAST_OWNER_COMM="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
}

# Deterministic copy-phase delay for R4: a PATH shim ahead of the real cp that
# sleeps $FAKE_CP_DELAY only when the destination is under the ephemeral root
# (other cp calls pass through untouched, reflink semantics preserved). While
# sleeping it touches $FAKE_CP_MARKER — the "provably pre-port" signal R4 polls
# (the lane dir itself only appears once cp actually runs, i.e. AFTER the sleep).
_br_make_fake_cp() {
    cat >"$BR_T/bin/cp" <<'EOF'
#!/usr/bin/env bash
# cp shim (R4): sleep FAKE_CP_DELAY when copying into the ephemeral root, then exec
# the REAL cp with identical argv. Never used unless a case prepends $BR_T/bin to PATH.
for a in "$@"; do
    case "$a" in
        --*) ;;
        *)  if [[ "$a" == "$AGENT_CHROME_EPHEMERAL_ROOT"/* ]]; then
                if [[ "${FAKE_CP_DELAY:-0}" =~ ^[0-9]+$ && "${FAKE_CP_DELAY:-0}" -gt 0 ]]; then
                    if [[ -n "${FAKE_CP_MARKER:-}" ]]; then
                        : >"$FAKE_CP_MARKER" 2>/dev/null || true
                    fi
                    sleep "$FAKE_CP_DELAY"
                fi
                break
            fi ;;
    esac
done
exec /usr/bin/cp "$@"
EOF
    chmod +x -- "$BR_T/bin/cp"
}

# --- regression cases -------------------------------------------------------------

# R1 — BUG-001 guard, FS-agnostic: pre-existing junk dir must be replaced by a clean
# top-level copy (never nested, never merged).
r1_bug001_guard_fs_agnostic() {
    mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
    printf 'partial-crash-state\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
    if ! ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && \
           pool_copy_master "$AGENT_CHROME_EPHEMERAL_ROOT/1" ) ; then
        _fail "R1: pool_copy_master failed on pre-existing target"; return 1
    fi
    if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Local State" ]]; then
        _fail "R1: no top-level 'Local State' in the lane dir (nested or empty copy)"; return 1
    fi
    if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" || -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/$(basename -- "$AGENT_CHROME_MASTER")" ]]; then
        _fail "R1: nested <master-basename>/ dir inside the lane dir (BUG-001 reproduced)"; return 1
    fi
    if [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker" ]]; then
        _fail "R1: stale junk survived (guard did not rm the pre-existing dir)"; return 1
    fi
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
}

# R2 — BUG-001 crash recovery end-to-end: provisional port=0 lease + remnant dir →
# next driving command re-boots the lane and the trusted master copy lands at top level.
r2_bug001_recovery_e2e() {
    local owner rc
    _br_spawn_owner
    owner="$BR_LAST_OWNER"
    # 1) Provisional lease: lane 1, port=0 — the crashed-boot state.
    ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && pool_config_init && pool_state_init && \
      pool_lease_write 1 "$AGENT_CHROME_EPHEMERAL_ROOT/1" 0 abpool-1 "$owner" "$BR_LAST_OWNER_COMM" \
      "$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && _pool_get_starttime "$owner" ) 2>/dev/null || true )" \
      "$BR_T" 0 0 false )
    # 2) Simulate crash-AFTER-copy: the dir exists (partial/junk state).
    mkdir -p -- "$AGENT_CHROME_EPHEMERAL_ROOT/1"
    printf 'crash-remnant\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/1/crash-marker"
    # 3) Next driving command through the real wrapper → stuck-lane recovery re-boot.
    rc=0
    timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        _fail "R2: recovery boot failed rc=$rc (expected 0)"; return 1
    fi
    # 4) Trusted-profile assertion: master's marker file at the LANE TOP level.
    if [[ ! -f "$AGENT_CHROME_EPHEMERAL_ROOT/1/Default/master-marker.txt" ]]; then
        _fail "R2: master marker missing — lane did not get a clean trusted copy"; return 1
    fi
    # 5) NO nesting.
    if [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" ]]; then
        _fail "R2: nested master dir inside lane 1 (BUG-001 reproduced at e2e level)"; return 1
    fi
    # 6) Clean up THIS test's lane.
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
}

# R3-control — BUG-002 harness green gate: a SINGLE open with a slow-booting chrome
# (FAKE_CHROME_DELAY=4) must succeed — pool_wait_cdp waits past the delay, the lane
# connects through the fakes, exactly ONE chrome launch. If this fails, the FIXTURES
# are wrong (fake contract mismatch), not the pool.
r3_control_delayed_boot_succeeds() {
    local rc n connected
    _br_spawn_owner
    : >"$FAKE_CHROME_COUNT_FILE"
    rc=0
    FAKE_CHROME_DELAY=4 timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        _fail "R3-control: delayed single open rc=$rc (expected 0)"
    fi
    n="$(wc -l <"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || printf 0)"
    connected="$(jq -r '.connected // "null"' "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || echo null)"
    # --- cleanup FIRST (always runs) ---
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    # --- assertions on snapshots ---
    if (( rc != 0 )); then return 1; fi
    if [[ "$n" != "1" ]]; then
        _fail "R3-control: expected exactly 1 launch, got $n"; return 1
    fi
    if [[ "$connected" != "true" ]]; then
        _fail "R3-control: lease connected=$connected (expected true)"; return 1
    fi
}

# R3 — BUG-002 race e2e (KNOWN-RED until T2.S2/S3): FAKE_CHROME_DELAY=4, cmd A bg, cmd B
# at 0.8s. Assertions snapshot-then-clean-then-assert (cleanup always runs, even red).
r3_bug002_race_e2e() {
    local rc2 n lease_pid survivors dir_gone count_pids rc_all
    _br_spawn_owner
    : >"$FAKE_CHROME_COUNT_FILE"
    # cmd A backgrounded (its own timeout bounds it).
    FAKE_CHROME_DELAY=4 timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 &
    local apid=$!
    sleep 0.8
    # cmd B: the racing second command.
    rc2=0
    timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc2=$?
    wait "$apid" 2>/dev/null || true
    # --- snapshot observable state ---
    n="$(wc -l <"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || printf 0)"
    lease_pid="$(jq -r '.chrome_pid // 0' "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || echo 0)"
    # chrome liveness must be snapshotted BEFORE the cleanup kills it (R4 idiom).
    local pid_live=0
    [[ "$lease_pid" != "0" && -d "/proc/$lease_pid" ]] && pid_live=1
    # --- cleanup FIRST (always runs, even when assertions would fail) ---
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    sleep 0.3
    survivors="$(pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true)"
    dir_gone=1; [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1" ]] && dir_gone=0
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    # --- assertions on snapshots (each a named, grep-able R3: FAIL line) ---
    rc_all=0
    if (( rc2 != 0 )); then
        _fail "R3: second command rc=$rc2 (spurious failure — race hit)" || rc_all=1
    fi
    if [[ "$n" != "1" ]]; then
        _fail "R3: expected exactly 1 chrome launch, got $n (double-launch)" || rc_all=1
    fi
    count_pids="$(awk '{print $1}' "$FAKE_CHROME_COUNT_FILE" 2>/dev/null | tr '\n' ' ' || true)"
    if (( pid_live != 1 )) \
       || [[ " ${count_pids} " != *" $lease_pid "* ]]; then
        _fail "R3: lease chrome_pid=$lease_pid not live / not the launched pid (clobbered lease; launched: ${count_pids:-none})" || rc_all=1
    fi
    if [[ -n "$survivors" ]]; then
        _fail "R3: leaked chrome processes after release all: $survivors" || rc_all=1
    fi
    if (( dir_gone != 1 )); then
        _fail "R3: lane dir survived release all" || rc_all=1
    fi
    return "$rc_all"
}

# R3-neg — BUG-002 negative control for the WIDENED (3b) sweep (T2.S4): the lease
# holds positive-but-DEAD ids (the clobber state) while a LIVE chrome runs on the
# lane dir. The old gate (fire only when BOTH ids <=0) skipped the sweep → leak.
# With the widened gate (skip only when the recorded pid is alive-and-matching),
# release must still kill the live chrome. KNOWN-RED pre-fix, GREEN post-fix.
r3_neg_dead_ids_release_still_kills() {
    local rc dp survivors dir_gone rc_all
    _br_spawn_owner
    # Harvest a REAL dead positive pid: kill + wait reaps it → /proc/$dp gone.
    sleep 300 &
    dp=$!
    kill "$dp" 2>/dev/null || true
    wait "$dp" 2>/dev/null || true
    # Boot one lane normally (no fake delay; rc must be 0 else fixtures are broken).
    rc=0
    timeout 60 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        _fail "R3-neg: fixture problem — single open rc=$rc"
        timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
        pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
        rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
        rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
        return 1
    fi
    # Simulate the BUG-002 clobber: rewrite the lease ids to the dead pid while the
    # fake chrome (recorded in FAKE_CHROME_COUNT_FILE) is still LIVE.
    jq --argjson pid "$dp" --argjson pgid "$dp" \
       '.chrome_pid=$pid | .chrome_pgid=$pgid' \
       "$AGENT_BROWSER_POOL_STATE/lanes/1.json" >"$BR_T/r3neg.lease.json" 2>/dev/null \
       && cat "$BR_T/r3neg.lease.json" >"$AGENT_BROWSER_POOL_STATE/lanes/1.json"
    rm -f "$BR_T/r3neg.lease.json" 2>/dev/null || true
    # Release with the lying lease ids.
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    sleep 0.3
    # --- snapshot observable state ---
    survivors="$(pgrep -af "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true)"
    dir_gone=1; [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/1" ]] && dir_gone=0
    # --- cleanup FIRST (always runs) ---
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    # --- assertions on snapshots ---
    rc_all=0
    if [[ -n "$survivors" ]]; then
        _fail "R3-neg: live chrome on lane 1 survived release with dead lease ids: $survivors" || rc_all=1
    fi
    if (( dir_gone != 1 )); then
        _fail "R3-neg: lane dir survived release all" || rc_all=1
    fi
    return "$rc_all"
}

# R4 — BUG-002 PRE-PORT race (T2.S2 green gate): cmd B fires while cmd A is provably
# mid-COPY (before the port write — deterministic via the PATH-shimmed slow cp).
# With the per-lane boot lock: B blocks on <1>.boot.lock, A finishes, B's in-lock
# re-check sees port>0 + CDP alive → returns 0 with NO re-copy / NO second launch.
# Assertions: both rc 0; exactly ONE chrome launch; no master* nesting inside the
# lane dir; lease chrome_pid == the live fake chrome pid.
r4_bug002_preport_race() {
    local rc_a rc_b n lease_pid nested count_pids rc_all _
    _br_spawn_owner
    _br_make_fake_cp
    : >"$FAKE_CHROME_COUNT_FILE"
    # cmd A backgrounded: slow copy (3s) then slow chrome (4s) — bounded by timeout.
    rc_a=0
    FAKE_CP_DELAY=3 FAKE_CHROME_DELAY=4 \
        FAKE_CP_MARKER="$BR_T/copy-phase.marker" PATH="$BR_T/bin:$PATH" \
        timeout 90 "$ABPOOL_REPO/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 &
    local apid=$!
    rm -f -- "$BR_T/copy-phase.marker" 2>/dev/null || true
    # DETERMINISTIC pre-port trigger: poll (bounded) until the cp shim's MARKER appears
    # — it is touched at sleep START, so the marker proves cmd A is mid-copy, BEFORE
    # the port write (which happens only after cp completes; the lane dir itself only
    # comes into existence with the real copy).
    for _ in $(seq 1 200); do
        [[ -f "$BR_T/copy-phase.marker" ]] && break
        sleep 0.05
    done
    if [[ ! -f "$BR_T/copy-phase.marker" ]]; then
        kill "$apid" 2>/dev/null || true
        wait "$apid" 2>/dev/null || true
        _fail "R4: copy-phase marker never appeared — cmd A never reached the copy (fixture broken)"
        return 1
    fi
    # cmd B: the racing second command, provably pre-port.
    rc_b=0
    timeout 90 "$ABPOOL_REPO/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_b=$?
    wait "$apid" 2>/dev/null || rc_a=$?
    # --- snapshot observable state (BEFORE cleanup) ---
    n="$(wc -l <"$FAKE_CHROME_COUNT_FILE" 2>/dev/null || printf 0)"
    lease_pid="$(jq -r '.chrome_pid // 0' "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || echo 0)"
    nested=""
    [[ -d "$AGENT_CHROME_EPHEMERAL_ROOT/1/master" ]] && nested=1
    # chrome liveness must be snapshotted BEFORE the cleanup kills it.
    local pid_live=0
    [[ "$lease_pid" != "0" && -d "/proc/$lease_pid" ]] && pid_live=1
    # --- cleanup FIRST (always runs, even when assertions would fail) ---
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT" 2>/dev/null || true
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/1.json" 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/1" 2>/dev/null || true
    # --- assertions on snapshots (each a named, grep-able R4: FAIL line) ---
    rc_all=0
    if (( rc_a != 0 )); then
        _fail "R4: first command rc=$rc_a (expected 0)" || rc_all=1
    fi
    if (( rc_b != 0 )); then
        _fail "R4: second command rc=$rc_b (spurious failure — pre-port race hit)" || rc_all=1
    fi
    if [[ "$n" != "1" ]]; then
        _fail "R4: expected exactly 1 chrome launch, got $n (double-launch)" || rc_all=1
    fi
    if [[ -n "$nested" ]]; then
        _fail "R4: nested master dir inside lane 1 (BUG-001 reproduced via double-copy)" || rc_all=1
    fi
    count_pids="$(awk '{print $1}' "$FAKE_CHROME_COUNT_FILE" 2>/dev/null | tr '\n' ' ' || true)"
    if (( pid_live != 1 )) \
       || [[ " ${count_pids} " != *" $lease_pid "* ]]; then
        _fail "R4: lease chrome_pid=$lease_pid not live / not the launched pid (clobbered lease; launched: ${count_pids:-none})" || rc_all=1
    fi
    return "$rc_all"
}

# R5 — BUG-003: reap must ALSO remove a present-but-invalid lanes/N.json once its
# orphan dir is gone. Before the fix, `reap` removed the dir but left the corrupt
# lease → pool_find_free_lane's [[ -f ]] treated lane 7 as occupied forever (deliberate
# collision safety — the FILE must be removed, not the guard weakened) and status
# showed a permanent '? ? … STALE' row. PRD h2.3/h3.2 repro + fix_design §4 test
# contract. No chrome launch: the orphan branch's pgrep matches nothing (rc 1 → no kill).
r5_bug003_corrupt_lease_reclaimed() {
    # Seed: lane 7 = the BUG-003 state (corrupt lease + orphan dir with a marker file).
    # (lanes 1-6 are seeded AFTER the reap — the stale pass would reap their valid-but-
    # dead leases, and file presence is ALL pool_find_free_lane checks.)
    local n lease7
    mkdir -p -- "$AGENT_BROWSER_POOL_STATE/lanes" "$AGENT_CHROME_EPHEMERAL_ROOT/7"
    printf 'not json {{{' >"$AGENT_BROWSER_POOL_STATE/lanes/7.json"
    printf 'orphan-marker\n' >"$AGENT_CHROME_EPHEMERAL_ROOT/7/Preferences"
    # Run reap through the real admin CLI (house style: timeout; rc 0 always).
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" reap >/dev/null 2>&1 || true
    # 1) BOTH artifacts gone: the dir AND the corrupt lease.
    if [[ -e "$AGENT_CHROME_EPHEMERAL_ROOT/7" ]]; then
        _fail "R5: orphan dir 7 still present after reap"; return 1
    fi
    lease7="$AGENT_BROWSER_POOL_STATE/lanes/7.json"
    if [[ -e "$lease7" ]]; then
        _fail "R5: corrupt lease 7.json still present after reap (BUG-003 reproduced)"; return 1
    fi
    # 2) Lane number un-burned: with 1-6 now occupied, find_free_lane must return 7.
    mkdir -p -- "$AGENT_BROWSER_POOL_STATE/lanes"
    for n in 1 2 3 4 5 6; do
        printf '{"port":%d}' "$((53400 + n))" >"$AGENT_BROWSER_POOL_STATE/lanes/$n.json"
    done
    n="$( ( trap - EXIT INT TERM; source "$ABPOOL_REPO/lib/pool.sh" && \
            pool_config_init && pool_find_free_lane ) 2>/dev/null || true )"
    if [[ "$n" != "7" ]]; then
        _fail "R5: pool_find_free_lane returned '${n:-<empty>}' (expected 7 — lane still burned)"; return 1
    fi
    # 3) status no longer shows a row for lane 7.
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/"[1-6].json 2>/dev/null || true
    if timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" status 2>/dev/null | grep -qE '^ *7 '; then
        _fail "R5: status still shows a row for lane 7"; return 1
    fi
    # Self-cleanup (lanes 1-6 seeds; 7 is already gone on the happy path).
    rm -f -- "$AGENT_BROWSER_POOL_STATE/lanes/"[1-6].json 2>/dev/null || true
    rm -rf -- "$AGENT_CHROME_EPHEMERAL_ROOT/7" 2>/dev/null || true
}

# R6 — BUG-003 (fix_design §4 seam 2): `release N` must clear a PRESENT-BUT-CORRUPT
# lease. Two variants: (1) corrupt 7.json + dir 7 present + a LIVE process whose
# cmdline carries the lane's user-data-dir marker (exec -a sleep — the fake-chrome
# fixture execs python3, which REPLACES cmdline and would make the kill assertion
# vacuous) → rc 0, lease gone, dir gone, ZERO survivors on the anchored pattern
# (the sweep verifiably killed); (2) corrupt 7.json, NO dir (the shape reap can
# never reach — pool_reap_orphan_dirs iterates $EPH/*/) → rc 0, lease gone.
r6_bug003_release_corrupt_lease() {
    local rc lease7 dir7 pat survivors rc_all
    _br_spawn_owner                 # a live owner so the pool verbs run normally
    lease7="$AGENT_BROWSER_POOL_STATE/lanes/7.json"
    dir7="$AGENT_CHROME_EPHEMERAL_ROOT/7"
    pat="user-data-dir=$dir7( |\$)"

    # --- variant 1: corrupt lease + dir + LIVE marker process ---
    mkdir -p -- "$AGENT_BROWSER_POOL_STATE/lanes" "$dir7"
    printf 'not json {{{' >"$lease7"
    printf 'orphan-marker\n' >"$dir7/Preferences"
    bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$dir7 lane7" >/dev/null 2>&1 &
    local mp=$!
    sleep 0.3                       # let the marker process settle into /proc
    rc=0
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release 7 >/dev/null 2>&1 || rc=$?
    sleep 0.3                       # let the sweep's TERM/0.2s/KILL land
    # --- snapshot observable state BEFORE cleanup ---
    survivors="$(pgrep -f -- "$pat" 2>/dev/null || true)"
    # --- cleanup FIRST (always runs) ---
    kill "$mp" 2>/dev/null || true
    wait "$mp" 2>/dev/null || true
    rm -f -- "$lease7" 2>/dev/null || true
    rm -rf -- "$dir7" 2>/dev/null || true
    # --- assertions on snapshots ---
    rc_all=0
    if (( rc != 0 )); then
        _fail "R6: release 7 on corrupt lease rc=$rc (expected 0)" || rc_all=1
    fi
    if [[ -e "$lease7" ]]; then
        _fail "R6: corrupt lease 7.json survived release (BUG-003 reproduced)" || rc_all=1
    fi
    if [[ -e "$dir7" ]]; then
        _fail "R6: lane dir 7 survived release" || rc_all=1
    fi
    if [[ -n "$survivors" ]]; then
        _fail "R6: live process on lane 7 dir survived the sweep: $survivors" || rc_all=1
    fi

    # --- variant 2: corrupt lease, NO dir (reap can never reach this shape) ---
    printf 'not json {{{' >"$lease7"
    rc=0
    timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" release 7 >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        _fail "R6: release 7 on corrupt lease (no dir) rc=$rc (expected 0)" || rc_all=1
    fi
    if [[ -e "$lease7" ]]; then
        _fail "R6: corrupt lease (no dir) survived release" || rc_all=1
    fi
    # Self-cleanup (belt-and-suspenders; happy path already cleared everything).
    rm -f -- "$lease7" 2>/dev/null || true
    rm -rf -- "$dir7" 2>/dev/null || true
    return "$rc_all"
}

# R7 — BUG-004 (fix_design §3): doctor must not false-FAIL [filesystem] when the
# ephemeral root does not exist yet (fresh install: install.sh pre-creates only the
# STATE dir; the root is first created by pool_copy_master at first acquire).
# findmnt -T on a MISSING path exits 1 EMPTY → fstype "" → false "not btrfs".
# Fix under test: doctor mkdir -p's the root before probing (pre-create, non-fatal).
# Three variants:
#   (1) MISSING root on the harness's btrfs tree → 'OK (btrfs)' + dir created + rc 0
#       (every other doctor check is green in the harness env, so rc reflects ONLY
#       real findings);
#   (2) existing tmpfs (non-btrfs) root + suite-default ALLOW_SLOW_COPY=1 → WARN
#       (proves the WARN branch still fires);
#   (3) same root + ALLOW_SLOW_COPY=0 → FAIL + rc≠0 (proves a GENUINE non-btrfs
#       finding still fails — the false-FAIL is gone, the true one stays).
r7_bug004_doctor_fresh_install() {
    local rc out root_missing root_tmpfs rc_all
    root_missing="$BR_T/active-missing"
    root_tmpfs="$(mktemp -d -p /dev/shm -t abpool-r7-nonbtrfs.XXXXXX)"
    rc_all=0

    # --- variant 1: MISSING root → OK (btrfs) + dir created + rc 0 ---
    # Prefix assignment overrides the suite-exported AGENT_CHROME_EPHEMERAL_ROOT for
    # this ONE subprocess (plain assignment after `local` = SC2155-safe).
    rc=0
    out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_missing" \
           timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
    if (( rc != 0 )); then
        _fail "R7: doctor rc=$rc with missing ephemeral root (BUG-004 reproduced)" || rc_all=1
    fi
    if ! grep -qF -- "$root_missing OK (btrfs)" <<<"$out"; then
        _fail "R7: [filesystem] expected 'OK (btrfs)' for missing root: $root_missing" || rc_all=1
    fi
    if [[ ! -d "$root_missing" ]]; then
        _fail "R7: doctor did not create the missing ephemeral root" || rc_all=1
    fi

    # --- variant 2: existing NON-btrfs (tmpfs) + ALLOW_SLOW_COPY=1 → WARN ---
    rc=0
    out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_tmpfs" \
           timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
    if ! grep -qF -- "$root_tmpfs WARN (tmpfs; slow-copy allowed)" <<<"$out"; then
        _fail "R7: expected 'WARN (tmpfs; slow-copy allowed)' for $root_tmpfs" || rc_all=1
    fi

    # --- variant 3: same root + ALLOW_SLOW_COPY=0 → FAIL + rc 1 ---
    rc=0
    out="$(AGENT_CHROME_EPHEMERAL_ROOT="$root_tmpfs" AGENT_CHROME_ALLOW_SLOW_COPY=0 \
           timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
    if (( rc == 0 )); then
        _fail "R7: doctor rc=0 on genuine non-btrfs without slow-copy (expected 1)" || rc_all=1
    fi
    if ! grep -qF -- "$root_tmpfs FAIL (tmpfs; not btrfs)" <<<"$out"; then
        _fail "R7: expected 'FAIL (tmpfs; not btrfs)' for $root_tmpfs" || rc_all=1
    fi

    # --- cleanup (unconditional; AGENTS.md §3) ---
    rm -rf -- "$root_missing" "$root_tmpfs" 2>/dev/null || true
    return "$rc_all"
}

r8_bug005_help_harnesses_contract() {
    local rc=0 help actual withovr
    # (a) help text contract — bounded, hermetic (help only printfs; suite env redirects state)
    help="$(timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" help 2>/dev/null || true)"
    if ! grep -qi 'antigravity' <<<"$help"; then
        _fail "R8: help omits antigravity" || rc=1
    fi
    if ! grep -qi 'replaces' <<<"$help"; then
        _fail "R8: help lacks 'replaces'" || rc=1
    fi
    if grep -qi 'appended' <<<"$help"; then
        _fail "R8: help still says 'appended'" || rc=1
    fi
    # (b) help-vs-code: default list cited in help == actual default
    # shellcheck disable=SC2016  # $POOL_HARNESSES expands in the child
    actual="$(cd "$ABPOOL_REPO" && env -u AGENT_BROWSER_POOL_HARNESSES bash -c \
        'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
    if [[ "$actual" != "pi,claude,codex,agy,antigravity" ]]; then
        _fail "R8: actual default is [$actual]" || rc=1
    fi
    if ! grep -qi 'pi,claude,codex,agy,antigravity' <<<"$help"; then
        _fail "R8: help default list != actual default ($actual)" || rc=1
    fi
    # (c) replace-semantics behavior check
    # shellcheck disable=SC2016  # $POOL_HARNESSES expands in the child
    withovr="$(cd "$ABPOOL_REPO" && AGENT_BROWSER_POOL_HARNESSES=myagent bash -c \
        'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
    if [[ "$withovr" != "myagent" ]]; then
        _fail "R8: override produced [$withovr], expected myagent (replace)" || rc=1
    fi
    return "$rc"
}

# --- single-setup runner -----------------------------------------------------------

_br_run_suite() {
    local fn
    for fn in r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e \
              r3_control_delayed_boot_succeeds r3_bug002_race_e2e \
              r3_neg_dead_ids_release_still_kills r4_bug002_preport_race \
              r5_bug003_corrupt_lease_reclaimed r6_bug003_release_corrupt_lease \
              r7_bug004_doctor_fresh_install \
              r8_bug005_help_harnesses_contract; do
        printf '== %s\n' "$fn"
        if "$fn"; then BR_PASS=$((BR_PASS+1)); printf '   PASS\n';
        else BR_FAIL=$((BR_FAIL+1)); BR_FAILED+=("$fn"); printf '   FAIL\n' >&2; fi
    done
    printf '\n%d passed, %d failed\n' "$BR_PASS" "$BR_FAIL"
    (( BR_FAIL > 0 )) && return 1
    return 0
}

_br_teardown() {
    local pid
    # Guard against spurious fires: subshells/command substitutions inherit the EXIT
    # trap. Do nothing until the runner marks the suite as finishing (AGENTS.md §4).
    [[ "${BR_TEARDOWN_FINAL:-0}" == 1 ]] || return 0
    BR_TEARDOWN_FINAL=0
    for pid in "${BR_OWNERS[@]:-}"; do kill "$pid" 2>/dev/null || true; done 2>/dev/null || true
    for pid in "${BR_OWNERS[@]:-}"; do wait "$pid" 2>/dev/null || true; done 2>/dev/null || true
    pkill -f -- 'fake-cdp\.' 2>/dev/null || true
    pkill -f -- "user-data-dir=$BR_T/active" 2>/dev/null || true
    pkill -f -- 'http.server' 2>/dev/null || true
    [[ -n "${BR_T:-}" ]] && rm -rf -- "$BR_T" 2>/dev/null || true
}

# Contract-name teardown (T2.S1 §4) — thin wrapper over the _br_* core.
_bootrace_teardown() {
    _br_teardown "@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _bootrace_setup          # ONE setup for the whole suite (never per-case)
    _br_make_fake_chrome
    _br_make_fake_ab
    BR_TEARDOWN_FINAL=1
    _br_run_suite || exit 1
fi