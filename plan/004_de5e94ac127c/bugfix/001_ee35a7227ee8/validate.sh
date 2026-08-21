#!/usr/bin/env bash
# ./validate.sh — comprehensive validation for agent-browser-pool @ HEAD (6fdbd82).
#
# Validates the 6 bug fixes required by the PRD (BUG-001..006, fix commits
# 8ad9fc5..6fdbd82) plus novel adversarial journeys against the fixed code.
#
# Phases:
#   P1 LINT      bash -n + shellcheck on every shell file (incl. test/bootrace.sh).
#   P2 CONTRACT  static code/doc markers for each PRD fix.
#   P3 SUITES    repo suites under hard timeouts + leak sweep after each:
#                  test/bootrace.sh (hermetic), test/validate.sh (hermetic),
#                  plan/004_de5e94ac127c/validate.sh --fast run FROM A FOREIGN CWD
#                  (BUG-006: ROOT resolution + green-as-shipped). Real-Chrome suites
#                  (transparency/release_reaper/concurrency) only with --full.
#   P4 E2E       hermetic journeys, fake chrome (real HTTP CDP) + fake agent-browser,
#                  isolated temp HOME/state/ephemeral/master on the real btrfs $HOME,
#                  simulated owners via the PRD §2.19 test hooks. Includes
#                  deterministic repros for every PRD bug + new-bug hunts
#                  (boot-lock >20s window, pin-over-corrupt-lease, lock-file fallout).
#
# Safety (AGENTS.md): every subprocess is timeout-bounded; one sandbox for the whole
# P4 phase; trap reaps owners + fake chromes and removes the sandbox; `--full` opts
# into real Chrome (the repo suites' own isolated frameworks); the operator's real
# pool state, master, and running Chrome are never touched.
#
# Usage: bash validate.sh [--full]
# Exit 0 iff every check passes. FAIL lines carry stable names.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
declare -a FAILED_NAMES=()
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n' "$1"; }
info(){ printf '       %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }

# =============================================================================
# P1 — LINT
# =============================================================================
section "P1 lint (bash -n + shellcheck)"
for f in bin/agent-browser-pool lib/pool.sh install.sh \
         test/validate.sh test/concurrency.sh test/release_reaper.sh \
         test/transparency.sh test/bootrace.sh plan/004_de5e94ac127c/validate.sh; do
    if timeout 60 bash -n "$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f"; fi
    sc="$(timeout 180 shellcheck -s bash "$f" 2>/dev/null | grep -cE '\^-- SC[0-9]+ \((error|warning)\)' || true)"
    if (( sc == 0 )); then ok "shellcheck: $f"; else bad "shellcheck: $f ($sc error/warning)"; fi
done

# =============================================================================
# P2 — STATIC CONTRACT (one marker per PRD fix)
# =============================================================================
section "P2 contract checks (PRD BUG-001..006 fixes present in code)"
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

has lib/pool.sh 'Crash-recovery guard (BUG-001)' \
    && ok "c1 BUG-001: pool_copy_master guards an existing target" \
    || bad "c1 BUG-001: guard marker missing in pool_copy_master"
if grep -q 'pool_lane_boot_lock()' lib/pool.sh && grep -q 'flock -w 20 8' lib/pool.sh \
   && grep -q 'BUG-002 / PRD h2.5' lib/pool.sh; then
    ok "c2 BUG-002: per-lane boot lock + dead-pid gate present"
else
    bad "c2 BUG-002: boot lock / dead-pid gate markers missing"
fi
has lib/pool.sh 'BUG-003 (fix_design §4 seam 1)' && has lib/pool.sh 'BUG-003 (fix_design §4 seam 2)' \
    && ok "c3 BUG-003: corrupt-lease reclaim in reap + release" \
    || bad "c3 BUG-003: reclaim markers missing"
has lib/pool.sh 'BUG-004 (fix_design §3)' \
    && ok "c4 BUG-004: doctor pre-creates the ephemeral root" \
    || bad "c4 BUG-004: doctor fix marker missing"
has lib/pool.sh 'replaces the default pi,claude,codex,agy,antigravity' \
    && ok "c5 BUG-005: help documents replace semantics + 5 defaults" \
    || bad "c5 BUG-005: help text wrong"
if grep -q 'ROOT=.*\.\./\.\.' plan/004_de5e94ac127c/validate.sh \
   && grep -q 'readlink -f "${BASH_SOURCE' plan/004_de5e94ac127c/validate.sh; then
    ok "c6 BUG-006: artifact ROOT resolves repo root (../../ from plan/004_*)"
else
    bad "c6 BUG-006: artifact ROOT does not resolve to repo root"
fi

# =============================================================================
# P3 — REPO SUITES (timeout + leak sweep)
# =============================================================================
section "P3 repo test suites"

sweep_leaks() {
    local leaks=0 pids p d
    pids="$(pgrep -f 'user-data-dir=.*abpool-test-eph' 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        leaks=$((leaks+1)); printf '       LEAK: live Chrome after suite: %s\n' "$(tr '\n' ' ' <<<"$pids")"
        for p in $pids; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
        sleep 1
        for p in $pids; do kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done
    fi
    for d in "$HOME"/abpool-test-eph.* /tmp/abpool-test.* /tmp/abpool-validate.*; do
        [[ -e "$d" ]] || continue
        leaks=$((leaks+1)); printf '       LEAK: leftover dir: %s\n' "$d"; rm -rf -- "$d" 2>/dev/null || true
    done
    return "$leaks" 2>/dev/null || true
}

run_suite() { # NAME TIMEOUT CMD...
    local name="$1" tmo="$2"; shift 2
    local out rc leaks
    printf -- '-- suite %s (timeout %ss)\n' "$name" "$tmo"
    out="$(timeout "$tmo" "$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -3 | sed 's/^/    /'
    if (( rc == 0 )); then ok "suite: $name rc=0"
    elif (( rc == 124 )); then bad "suite: $name TIMED OUT after ${tmo}s"
    else bad "suite: $name rc=$rc"; fi
    leaks=0; sweep_leaks || leaks=$?
    if (( leaks > 0 )); then bad "suite-leak: $name left processes/dirs behind (swept)"
    else ok "suite-leak: $name clean"; fi
}

run_suite test/bootrace.sh        300 bash test/bootrace.sh
run_suite test/validate.sh        420 bash test/validate.sh
# BUG-006: the committed artifact must run green FROM ANY CWD (foreign dir proves ROOT).
( cd /tmp && run_suite plan/004-artifact-fast 900 bash "$ROOT/plan/004_de5e94ac127c/validate.sh" --fast )

if (( FULL )); then
    HAVE_CHROME=0; command -v google-chrome-stable >/dev/null 2>&1 && HAVE_CHROME=1
    HAVE_MASTER=0
    [[ -n "$(ls -A "$HOME/.agent-chrome-profiles/master-profile" 2>/dev/null || true)" ]] && HAVE_MASTER=1
    if (( HAVE_CHROME && HAVE_MASTER )); then
        run_suite test/transparency.sh    540 bash test/transparency.sh
        run_suite test/release_reaper.sh  540 bash test/release_reaper.sh
        run_suite test/concurrency.sh     900 bash test/concurrency.sh
    else
        info "--full: real-Chrome suites skipped (chrome=$HAVE_CHROME master=$HAVE_MASTER)"
    fi
else
    info "real-Chrome suites skipped (use --full to include them)"
fi

# =============================================================================
# P4 — HERMETIC E2E JOURNEYS (fake chrome + fake agent-browser)
# =============================================================================
section "P4 E2E journeys (hermetic fakes, single sandbox)"

SB="$(mktemp -d -p "$HOME" -t abpool-myval.XXXXXX)"
V_HOME="$SB/home"; V_STATE="$SB/state"; V_EPH="$SB/eph"; V_MASTER="$SB/master"; V_BIN="$SB/bin"
mkdir -p "$V_HOME" "$V_STATE" "$V_EPH" "$V_MASTER/Default" "$V_BIN"
printf '{"profile":{"last_used":"Default"}}\n' >"$V_MASTER/Local State"
printf 'x' >"$V_MASTER/Default/Preferences"
printf 'trusted-identity\n' >"$V_MASTER/Default/master-marker.txt"
LAUNCHES="$SB/chrome-launches.log"

cat >"$V_BIN/fake-chrome" <<'EOF'
#!/usr/bin/env bash
port="" dir=""
for a in "$@"; do case "$a" in
    --remote-debugging-port=*) port="${a##*=}";;
    --user-data-dir=*)         dir="${a##*=}";;
esac; done
printf '%s %s %s\n' "$$" "$port" "$dir" >>"${FAKE_CHROME_COUNT_FILE:-/dev/null}" 2>/dev/null || true
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
sleep "${FAKE_CHROME_DELAY:-0}"
d="$(mktemp -d -t fake-cdp.XXXXXX)"; mkdir -p "$d/json"
printf '{"Browser":"FakeChrome/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/fake"}\n' "$port" >"$d/json/version"
cd -- "$d" || exit 1
trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT INT TERM
exec python3 -m http.server "$port" --bind 127.0.0.1
EOF
cat >"$V_BIN/fake-ab" <<'EOF'
#!/usr/bin/env bash
session="" prev=""
for a in "$@"; do [[ "$prev" == "--session" ]] && session="$a"; prev="$a"; done
case " $* " in
    *" session list "*) printf '{"success":true,"data":{"sessions":["%s"]}}\n' "${session:-abpool-1}"; exit 0;;
    *) exit 0;;
esac
EOF
cat >"$V_BIN/cp" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
    --*) ;;
    *)  if [[ "$a" == "$AGENT_CHROME_EPHEMERAL_ROOT"/* ]]; then
            [[ -n "${FAKE_CP_MARKER:-}" ]] && : >"$FAKE_CP_MARKER" 2>/dev/null || true
            sleep "${FAKE_CP_DELAY:-0}"; break
        fi ;;
esac; done
exec /usr/bin/cp "$@"
EOF
chmod +x "$V_BIN/fake-chrome" "$V_BIN/fake-ab" "$V_BIN/cp"

declare -a OWNERS=()
spawn_owner() { # echoes pid
    sleep 600 & local pid=$!; OWNERS+=("$pid")
    AGENT_BROWSER_POOL_OWNER_PID="$pid"
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$( (source "$ROOT/lib/pool.sh" && _pool_get_starttime "$pid") 2>/dev/null || true )"
    export AGENT_BROWSER_POOL_OWNER_PID AGENT_BROWSER_POOL_OWNER_STARTTIME
    SPAWNED_PID="$pid"
}
PENV=(env -u ABPOOL_LANE -u ABPOOL_OWNER
      HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$V_STATE" AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH"
      AGENT_CHROME_MASTER="$V_MASTER" AGENT_BROWSER_REAL="$V_BIN/fake-ab"
      AGENT_CHROME_BIN="$V_BIN/fake-chrome" AGENT_CHROME_ALLOW_SLOW_COPY=1
      AGENT_CHROME_PORT_BASE=55720 AGENT_CHROME_PORT_RANGE=100 AGENT_BROWSER_POOL_WAIT=15
      FAKE_CHROME_COUNT_FILE="$LAUNCHES" PATH="$V_BIN:$PATH")

hard_clean() { # tear everything pool-shaped in the sandbox (between journeys)
    timeout 30 env HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$V_STATE" \
        AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" AGENT_CHROME_MASTER="$V_MASTER" \
        AGENT_BROWSER_REAL="$V_BIN/fake-ab" AGENT_CHROME_BIN="$V_BIN/fake-chrome" \
        "$ROOT/bin/agent-browser-pool" release all >/dev/null 2>&1 || true
    pkill -f -- "user-data-dir=$V_EPH" 2>/dev/null || true
    rm -f -- "$V_STATE/lanes/"*.json 2>/dev/null || true
    rm -rf -- "$V_EPH"/* 2>/dev/null || true
    : >"$LAUNCHES"
}
final_teardown() {
    [[ "${VT_FINAL:-0}" == 1 ]] || return 0
    VT_FINAL=0
    local pid
    for pid in "${OWNERS[@]:-}"; do kill "$pid" 2>/dev/null || true; done 2>/dev/null || true
    for pid in "${OWNERS[@]:-}"; do wait "$pid" 2>/dev/null || true; done 2>/dev/null || true
    pkill -f 'fake-cdp\.' 2>/dev/null || true
    pkill -f -- "user-data-dir=$V_EPH" 2>/dev/null || true
    rm -rf -- "$SB" 2>/dev/null || true
}
trap 'final_teardown' EXIT INT TERM
VT_FINAL=1

lease_json() { jq -c "$1" "$V_STATE/lanes/$2.json" 2>/dev/null || echo "null"; }
n_launches() { wc -l <"$LAUNCHES" 2>/dev/null || printf 0; }
pid_alive() { [[ "$1" != "0" && -d "/proc/$1" ]]; }

# --- e01 BUG-001: pre-existing junk dir → clean flat copy, no nesting -------------
mkdir -p "$V_EPH/1"; printf 'junk' >"$V_EPH/1/junk"
rc=0
( trap - EXIT INT TERM; export HOME="$V_HOME" AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" \
      AGENT_CHROME_MASTER="$V_MASTER" AGENT_CHROME_ALLOW_SLOW_COPY=1
  source "$ROOT/lib/pool.sh" && pool_config_init && pool_copy_master "$V_EPH/1" ) 2>/dev/null || rc=$?
if (( rc == 0 )) && [[ -f "$V_EPH/1/Local State" && ! -e "$V_EPH/1/junk" && ! -d "$V_EPH/1/master" ]]; then
    ok "e01 BUG-001: stale target replaced by clean flat copy (no nesting, no junk)"
else bad "e01 BUG-001: guard failed rc=$rc (nested/junk copy)"; fi
rm -rf -- "$V_EPH/1"

# --- e02 BUG-001 e2e: port=0 lease + remnant dir → recovery boot -------------------
spawn_owner
( trap - EXIT INT TERM; export HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$V_STATE" \
      AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" AGENT_CHROME_MASTER="$V_MASTER" \
      AGENT_CHROME_ALLOW_SLOW_COPY=1
  source "$ROOT/lib/pool.sh" && pool_config_init && pool_state_init && \
  pool_lease_write 1 "$V_EPH/1" 0 abpool-1 "$SPAWNED_PID" sleep \
  "$( (source "$ROOT/lib/pool.sh" && _pool_get_starttime "$SPAWNED_PID") 2>/dev/null || true )" \
  "$SB" 0 0 false ) 2>/dev/null
mkdir -p "$V_EPH/1"; printf 'crash-remnant' >"$V_EPH/1/crash-marker"
rc=0; PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
"${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
if (( rc == 0 )) && [[ -f "$V_EPH/1/Default/master-marker.txt" && ! -d "$V_EPH/1/master" ]]; then
    ok "e02 BUG-001: crash recovery re-boots with trusted top-level profile"
else bad "e02 BUG-001: recovery boot rc=$rc (nesting or missing marker)"; fi
hard_clean

# --- e03 BUG-002 mid-boot race (2-way): slow chrome, second cmd at 0.8s -------------
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
FAKE_CHROME_DELAY=4 "${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & APID=$!
sleep 0.8
rc_b=0; "${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_b=$?
wait "$APID" 2>/dev/null || true
lp="$(lease_json .chrome_pid 1)"; n="$(n_launches)"
if (( rc_b == 0 )) && [[ "$n" == 1 ]] && pid_alive "$lp"; then
    ok "e03 BUG-002: mid-boot 2-way race — no spurious fail, 1 launch, live lease pid"
else bad "e03 BUG-002: rc_b=$rc_b launches=$n lease_pid=$lp"; fi
hard_clean

# --- e04 BUG-002 3-way stress: A bg, B at 0.8s, C at 1.6s --------------------------
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
FAKE_CHROME_DELAY=4 "${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & A1=$!
sleep 0.8; rc_b=0; "${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_b=$?
sleep 0.8; rc_c=0; "${PENV_here[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_c=$?
wait "$A1" 2>/dev/null || true
n="$(n_launches)"
if (( rc_b == 0 && rc_c == 0 )) && [[ "$n" == 1 ]]; then
    ok "e04 BUG-002: 3-way race — all succeed, single chrome"
else bad "e04 BUG-002: rc_b=$rc_b rc_c=$rc_c launches=$n"; fi
hard_clean

# --- e05 BUG-002 pre-port race (slow copy 3s + slow chrome 4s, marker-polled) -------
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
FAKE_CP_DELAY=3 FAKE_CP_MARKER="$SB/cp.marker" FAKE_CHROME_DELAY=4 \
    "${PENV_here[@]}" timeout 90 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & A1=$!
rm -f "$SB/cp.marker"; for _ in $(seq 1 200); do [[ -f "$SB/cp.marker" ]] && break; sleep 0.05; done
rc_b=0; "${PENV_here[@]}" timeout 90 "$ROOT/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_b=$?
wait "$A1" 2>/dev/null; rc_a=$?
n="$(n_launches)"
if (( rc_a == 0 && rc_b == 0 )) && [[ "$n" == 1 && ! -d "$V_EPH/1/master" ]]; then
    ok "e05 BUG-002: pre-port race — serialized, 1 launch, no nested copy"
else bad "e05 BUG-002: rc_a=$rc_a rc_b=$rc_b launches=$n"; fi
hard_clean

# --- e06 NEW (boot-lock >20s window): 45s copy, second cmd → what happens? ---------
# Documents BUG-007: pool_boot_lane's lock_rc=$? capture is broken (if…fi without
# else ⇒ rc 0), the documented unlocked fallback never runs, and the second command
# burns 2×20s then dies "lane N not connected; aborting" (spurious — cmd A is fine).
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
FAKE_CP_DELAY=45 "${PENV_here[@]}" timeout 150 "$ROOT/bin/agent-browser-pool" open about:blank >"$SB/e06A" 2>&1 & A1=$!
sleep 1.2
t0=$SECONDS; rc_b=0
"${PENV_here[@]}" timeout 150 "$ROOT/bin/agent-browser-pool" get cdp-url >"$SB/e06B" 2>&1 || rc_b=$?
dur=$((SECONDS - t0))
wait "$A1" 2>/dev/null; rc_a=$?
n="$(n_launches)"; lp="$(lease_json .chrome_pid 1)"
busy_boot="$(grep -c 'pool_boot_lane: boot lock busy' "$V_STATE/pool.log" 2>/dev/null || true)"
if (( rc_b == 0 )); then
    ok "e06 lock>20s: second command survived a >20s peer boot (${dur}s)"
else
    bad "e06 lock>20s: second command rc=$rc_b after ${dur}s (BUG-007: dead fallback + spurious failure)"
    info "e06 detail: rc_a=$rc_a launches=$n busy_boot_log=$busy_boot outB=$(tail -1 "$SB/e06B" 2>/dev/null)"
fi
if (( busy_boot == 0 )); then
    info "e06 note: pool_boot_lane's documented 'busy >20s → proceeding unlocked' log never fired (dead code)"
fi
hard_clean

# --- e06ctl control: 15s copy (< 20s lock budget) → both succeed --------------------
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
FAKE_CP_DELAY=15 "${PENV_here[@]}" timeout 90 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & A1=$!
sleep 1.0
rc_b=0; "${PENV_here[@]}" timeout 90 "$ROOT/bin/agent-browser-pool" get cdp-url >/dev/null 2>&1 || rc_b=$?
wait "$A1" 2>/dev/null || true
n="$(n_launches)"
if (( rc_b == 0 )) && [[ "$n" == 1 ]]; then
    ok "e06ctl: peer boot <20s — lock serializes cleanly (fallback window not hit)"
else bad "e06ctl: rc_b=$rc_b launches=$n (lock broken even inside budget)"; fi
hard_clean

# --- e07 BUG-003a: corrupt lease + orphan dir → reap clears BOTH --------------------
mkdir -p "$V_STATE/lanes" "$V_EPH/7"; printf 'not json {{{' >"$V_STATE/lanes/7.json"
printf 'x' >"$V_EPH/7/Preferences"
spawn_owner
PENV_here=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$SPAWNED_PID" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
"${PENV_here[@]}" timeout 30 "$ROOT/bin/agent-browser-pool" reap >/dev/null 2>&1 || true
for n in 1 2 3 4 5 6; do printf '{"port":%d}' "$((55720 + n))" >"$V_STATE/lanes/$n.json"; done
free="$( ( trap - EXIT INT TERM; source "$ROOT/lib/pool.sh" && \
    AGENT_BROWSER_POOL_STATE="$V_STATE" AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" \
    pool_config_init && pool_find_free_lane ) 2>/dev/null || true )"
if [[ ! -e "$V_EPH/7" && ! -e "$V_STATE/lanes/7.json" && "$free" == 7 ]]; then
    ok "e07 BUG-003: reap clears corrupt lease + dir; lane number un-burned"
else bad "e07 BUG-003: dir/lease remains or lane still burned (free=$free)"; fi
rm -f "$V_STATE/lanes/"[1-6].json 2>/dev/null || true

# --- e08 BUG-003b: corrupt lease, NO dir → release N clears it ----------------------
printf 'not json {{{' >"$V_STATE/lanes/7.json"
rc=0; "${PENV_here[@]}" timeout 30 "$ROOT/bin/agent-browser-pool" release 7 >/dev/null 2>&1 || rc=$?
if (( rc == 0 )) && [[ ! -e "$V_STATE/lanes/7.json" ]]; then
    ok "e08 BUG-003: release N clears a corrupt lease (no-dir shape)"
else bad "e08 BUG-003: release 7 rc=$rc, lease remains"; fi

# --- e09 NEW (pin-over-corrupt-lease sweep gap): live rogue must not survive -------
# Documents BUG-009: the pin path's rc-2 branch rm -rf's the dir WITHOUT the cmdline
# sweep release/reap perform — a live chrome pinned to the dir survives on deleted inodes.
mkdir -p "$V_EPH/7"
printf 'not json {{{' >"$V_STATE/lanes/7.json"
MARKER="chrome --user-data-dir=$V_EPH/7 lane7"
bash -c 'exec -a "$1" sleep 300' _ "$MARKER" >/dev/null 2>&1 & ROGUE=$!
sleep 0.5
rc=0; "${PENV_here[@]}" ABPOOL_LANE=7 timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 || rc=$?
sleep 0.3
survivors="$(pgrep -f -- "user-data-dir=$V_EPH/7( |\$)" 2>/dev/null || true)"
kill "$ROGUE" 2>/dev/null || true; wait "$ROGUE" 2>/dev/null || true
if (( rc == 0 )) && [[ -z "$survivors" ]]; then
    ok "e09 pin+corrupt: rogue chrome swept before the fresh boot"
elif [[ -n "$survivors" ]]; then
    bad "e09 pin+corrupt: live chrome survived pin-acquire over corrupt lease: $survivors (BUG-009)"
else
    bad "e09 pin+corrupt: pin rc=$rc (unexpected failure)"
fi
hard_clean

# --- e10 BUG-004: doctor with a MISSING ephemeral root -----------------------------
MISS="$SB/active-missing"
rc=0
out="$(AGENT_BROWSER_POOL_STATE="$V_STATE" HOME="$V_HOME" AGENT_CHROME_MASTER="$V_MASTER" \
    AGENT_CHROME_EPHEMERAL_ROOT="$MISS" AGENT_CHROME_BIN="$V_BIN/fake-chrome" \
    AGENT_BROWSER_REAL="$V_BIN/fake-ab" \
    timeout 30 "$ROOT/bin/agent-browser-pool" doctor 2>&1)" || rc=$?
if grep -qF -- "$MISS OK (btrfs)" <<<"$out" && [[ -d "$MISS" ]]; then
    ok "e10 BUG-004: doctor OK (btrfs) on fresh install; root created"
else bad "e10 BUG-004: doctor rc=$rc out: $(grep -F "$MISS" <<<"$out" | head -1)"; fi
rm -rf -- "$MISS" 2>/dev/null || true

# --- e11 BUG-005: help contract + replace semantics --------------------------------
help_out="$(timeout 30 env HOME="$V_HOME" "$ROOT/bin/agent-browser-pool" help 2>/dev/null || true)"
actual="$(cd "$ROOT" && env -u AGENT_BROWSER_POOL_HARNESSES bash -c \
    'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
withovr="$(cd "$ROOT" && AGENT_BROWSER_POOL_HARNESSES=myagent bash -c \
    'source lib/pool.sh; pool_config_init; printf "%s" "$POOL_HARNESSES"' 2>/dev/null || true)"
if grep -qi 'replaces the default pi,claude,codex,agy,antigravity' <<<"$help_out" \
   && [[ "$actual" == "pi,claude,codex,agy,antigravity" && "$withovr" == "myagent" ]] \
   && ! grep -qi 'appended' <<<"$help_out"; then
    ok "e11 BUG-005: help == replace semantics == code default"
else bad "e11 BUG-005: help/code mismatch (actual=$actual withovr=$withovr)"; fi

# --- e12 NEW (lock-file fallout, BUG-008): caller-mode lanes counting ---------------
# Two caller-mode children → exactly 2 *.json leases. The artifact's e2e12 counts
# with a bare `ls`, which now also sees the fix's own N.boot.lock files.
: >"$LAUNCHES"
c_pids=()
for i in 1 2; do
    ( timeout 90 env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
        -u ABPOOL_LANE ABPOOL_OWNER=caller HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$V_STATE" \
        AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" AGENT_CHROME_MASTER="$V_MASTER" \
        AGENT_BROWSER_REAL="$V_BIN/fake-ab" AGENT_CHROME_BIN="$V_BIN/fake-chrome" \
        AGENT_CHROME_ALLOW_SLOW_COPY=1 AGENT_CHROME_PORT_BASE=55720 AGENT_CHROME_PORT_RANGE=100 \
        FAKE_CHROME_COUNT_FILE="$LAUNCHES" PATH="$V_BIN:$PATH" \
        bash -c 'exec 3>/dev/null; bin='"$ROOT"'/bin/agent-browser-pool; cd /; exec "$bin" open about:blank' ) &
    c_pids+=("$!")
done
wait "${c_pids[@]}" 2>/dev/null || true
json_n="$(find "$V_STATE/lanes" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
ls_n="$(ls "$V_STATE/lanes" 2>/dev/null | wc -l)"
lock_n="$(find "$V_STATE/lanes" -maxdepth 1 -name '*.boot.lock' 2>/dev/null | wc -l)"
st_out="$(AGENT_BROWSER_POOL_STATE="$V_STATE" HOME="$V_HOME" \
    AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" AGENT_CHROME_MASTER="$V_MASTER" \
    AGENT_CHROME_BIN="$V_BIN/fake-chrome" AGENT_BROWSER_REAL="$V_BIN/fake-ab" \
    timeout 30 "$ROOT/bin/agent-browser-pool" status 2>/dev/null)" || true
lanes_in_status="$(grep -cE '^ +[0-9]+ ' <<<"$st_out" || true)"
if [[ "$json_n" == 2 && "$lanes_in_status" == 2 ]]; then
    ok "e12: product counts leases correctly with .boot.lock present (json=$json_n status_rows=$lanes_in_status)"
else bad "e12: product miscounts with lock files (json=$json_n status_rows=$lanes_in_status)"; fi
if (( ls_n > json_n )); then
    info "e12 note: bare 'ls lanes/' counts $ls_n entries vs $json_n leases (+'$lock_n' .boot.lock) — this is what breaks the committed artifact's e2e12 (BUG-008)"
fi
hard_clean

# --- e13 two DIFFERENT owners boot lanes 1+2 in parallel ---------------------------
spawn_owner; O_A="$SPAWNED_PID"
spawn_owner; O_B="$SPAWNED_PID"
PA=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O_A")
PB=("${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O_B" \
    AGENT_BROWSER_POOL_OWNER_STARTTIME="$AGENT_BROWSER_POOL_OWNER_STARTTIME")
PA=("${PA[@]}" AGENT_BROWSER_POOL_OWNER_STARTTIME="$( (source "$ROOT/lib/pool.sh" && _pool_get_starttime "$O_A") 2>/dev/null || true )")
PB=("${PB[@]}" AGENT_BROWSER_POOL_OWNER_STARTTIME="$( (source "$ROOT/lib/pool.sh" && _pool_get_starttime "$O_B") 2>/dev/null || true )")
"${PA[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & C1=$!
"${PB[@]}" timeout 60 "$ROOT/bin/agent-browser-pool" open about:blank >/dev/null 2>&1 & C2=$!
rc1=0; rc2=0; wait "$C1" || rc1=$?; wait "$C2" || rc2=$?
n="$(n_launches)"
# End-state contract: 2 distinct healthy lanes. NOTE: the raw launch count may exceed
# 2 when the parallel boots race on the lowest free port (both leases are port=0 at
# pick time) and the loser relaunches via the documented best-effort re-pick — that is
# PRD §2.4-designed behavior, not a bug, provided the end state is 2 healthy lanes.
p1="$(lease_json .port 1)"; p2="$(lease_json .port 2)"
c1p="$(lease_json .chrome_pid 1)"; c2p="$(lease_json .chrome_pid 2)"
conn1="$(lease_json .connected 1)"; conn2="$(lease_json .connected 2)"
if (( rc1 == 0 && rc2 == 0 )) && [[ "$p1" != "$p2" && "$p1" != null && "$p2" != null ]] \
   && [[ "$conn1:$conn2" == true:true ]] && pid_alive "$c1p" && pid_alive "$c2p"; then
    ok "e13: two owners boot lanes 1+2 concurrently — both healthy (ports $p1/$p2; launches=$n incl. any port-race retries)"
else
    bad "e13: rc1=$rc1 rc2=$rc2 p1=$p1 p2=$p2 conn=$conn1/$conn2 c1=$c1p c2=$c2p"
fi
hard_clean

# --- e14 final leak sweep ----------------------------------------------------------
sleep 0.5
left="$(pgrep -f -- "user-data-dir=$V_EPH" 2>/dev/null || true)"
fcdp="$(pgrep -f 'fake-cdp\.' 2>/dev/null || true)"
if [[ -z "$left" && -z "$fcdp" ]]; then ok "e14: zero leaked processes after P4"; else
    bad "e14: leaked: ${left:-} ${fcdp:-}"; pkill -f 'fake-cdp\.' 2>/dev/null || true; pkill -f -- "user-data-dir=$V_EPH" 2>/dev/null || true; fi

# =============================================================================
# SUMMARY
# =============================================================================
section "SUMMARY"
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf 'Failed checks:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    VT_FINAL=1; final_teardown
    exit 1
fi
VT_FINAL=1; final_teardown
exit 0