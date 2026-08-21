#!/usr/bin/env bash
#
# ./validate.sh — comprehensive project validation for agent-browser-pool.
#
# Phases:
#   P1  LINT            bash -n (syntax) + shellcheck on every shell file.
#   P2  CONTRACT        static doc/code contract checks (defaults, help coverage,
#                       dead code, .gitignore sanity).
#   P3  UNIT/SUITES     the repo's own test suites, each under a hard timeout,
#                       each followed by a LEAK SWEEP (live Chrome / leftover dirs
#                       left behind by a "passing" suite = recorded failure).
#   P4  E2E (hermetic)  complete user journeys from README.md / SKILL.md /
#                       PRD.md executed against FAKE chrome + FAKE agent-browser
#                       binaries (no real Chrome is launched by this phase) in an
#                       isolated sandbox (temp HOME/state/ephemeral/master).
#
# Safety (AGENTS.md): every subprocess is timeout-bounded; a trap reaps all fake
# Chromes + simulated owners and removes the sandbox; suites only run when their
# prerequisites exist; `--fast` skips the real-Chrome suites.
#
# Usage: bash plan/004_de5e94ac127c/validate.sh [--fast]
#   May be invoked from any CWD; the script cds to the repo root itself.
#   --fast skips the real-Chrome suites.
#
# Exit 0 iff every check passes. Failures print "FAIL:" lines with stable names.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
declare -a FAILED_NAMES=()
FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n' "$1"; }
info() { printf '       %s\n' "$1"; }

section() { printf '\n== %s\n' "$1"; }

# =============================================================================
# P1 — LINT
# =============================================================================
section "P1 lint (bash -n + shellcheck)"
for f in bin/agent-browser-pool lib/pool.sh install.sh \
         test/validate.sh test/bootrace.sh test/concurrency.sh test/release_reaper.sh test/transparency.sh; do
    if timeout 60 bash -n "$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f"; fi
    # SC1091 (source not followed) is informational; count errors+warnings only.
    sc_errs="$(timeout 120 shellcheck -s bash "$f" 2>/dev/null | grep -cE 'level=[0-9]+.*(error|warning)' || true)"
    sc_errs2="$(timeout 120 shellcheck -s bash "$f" 2>/dev/null | grep -cE '\^-- SC[0-9]+ \((error|warning)\)' || true)"
    if (( sc_errs2 == 0 )); then ok "shellcheck: $f"; else bad "shellcheck: $f ($sc_errs2 error/warning)"; fi
done

# =============================================================================
# P2 — STATIC CONTRACT CHECKS
# =============================================================================
section "P2 doc/code contract checks"

SB="$(mktemp -d /tmp/abpool-validate.XXXXXX)"
export ABPOOL_VALIDATE_SANDBOX="$SB"
V_HOME="$SB/home"; mkdir -p "$V_HOME"
trap 'cleanup' EXIT INT TERM

# Resolve the CODE default master (hermetic HOME, no AGENT_CHROME_MASTER).
CODE_MASTER="$(env HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$SB/probe-state" \
    bash -c 'source lib/pool.sh; pool_config_init >/dev/null 2>&1; printf "%s" "${POOL_MASTER_DIR:-}"' 2>/dev/null || true)"
if [[ "$CODE_MASTER" == "$V_HOME/.agent-chrome-profiles/master-profile" ]]; then
    info "code default master = $CODE_MASTER"
elif [[ -n "$CODE_MASTER" ]]; then
    info "code default master = $CODE_MASTER"
else
    bad "contract: could not resolve code default master"
fi

HELP_TEXT="$(timeout 60 env HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$SB/probe-state" \
    bash bin/agent-browser-pool help 2>/dev/null || true)"

# sc1: pool_admin_help's stated default vs the code default.
if grep -q 'AGENT_CHROME_MASTER.*default: ~/.config/google-chrome' <<<"$HELP_TEXT" \
   && [[ "$CODE_MASTER" == */.agent-chrome-profiles/master-profile ]]; then
    bad "contract:help-vs-code-master-default (help says ~/.config/google-chrome; code uses $CODE_MASTER)"
else
    ok "contract:help-vs-code-master-default consistent"
fi

# sc2: user docs (README + skill reference + PRD) vs the code default.
DOCS_DEFAULT='XDG_CONFIG_HOME:-~/.config}/google-chrome'
if grep -q "$DOCS_DEFAULT" README.md .agents/skills/agent-browser-pool/references/configuration.md PRD.md 2>/dev/null \
   && [[ "$CODE_MASTER" == */.agent-chrome-profiles/master-profile ]]; then
    bad "contract:docs-vs-code-master-default (README/SKILL/PRD say ~/.config/google-chrome; code uses $CODE_MASTER)"
else
    ok "contract:docs-vs-code-master-default consistent"
fi

# sc3: help must document the shipped config surface (PRD §2.11/§2.12).
for v in ABPOOL_OWNER ABPOOL_LANE AGENT_BROWSER_POOL_HARNESSES AGENT_CHROME_PROFILE; do
    if grep -q "$v" <<<"$HELP_TEXT"; then ok "help documents $v"; else bad "contract:help-missing-env-doc($v)"; fi
done

# sc4: dead code — pool_check_btrfs was removed (validation issue #5: defined, never
#     called; the non-btrfs refusal lives in pool_copy_master + doctor). Assert it stays GONE
#     (any non-comment occurrence reintroduces dead code or a stale reference).
DEFS="$(grep -n 'pool_check_btrfs' lib/pool.sh | grep -vE '^[0-9]+:\s*#' || true)"
if [[ -z "$DEFS" ]]; then ok "pool_check_btrfs removed (no dead code)"; else bad "contract:pool_check_btrfs-dead-code (reintroduced without a call site)"; fi

# sc5: .gitignore must not ignore PRD.md / plan/.
if git check-ignore -q PRD.md 2>/dev/null || git check-ignore -q plan 2>/dev/null; then
    bad "contract:gitignore-covers-prd-or-plan"
else
    ok ".gitignore does not ignore PRD.md/plan/"
fi

# =============================================================================
# P3 — REPO SUITES (hard timeout + leak sweep after each)
# =============================================================================
section "P3 repo test suites"

sweep_leaks() {
    # Kill any Chrome left running under an abpool-test ephemeral root; remove
    # leftover abpool-test dirs. Returns count of leaks found (0 = clean).
    local leaks=0 pids p d
    pids="$(pgrep -f 'user-data-dir=.*abpool-test-eph' 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        leaks=$((leaks+1))
        printf '       LEAK: live Chrome after suite: %s\n' "$(tr '\n' ' ' <<<"$pids")"
        for p in $pids; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
        sleep 1
        for p in $pids; do kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done
    fi
    for d in "$HOME"/abpool-test-eph.* /tmp/abpool-test.*; do
        [[ -e "$d" ]] || continue
        leaks=$((leaks+1))
        printf '       LEAK: leftover dir: %s\n' "$d"
        rm -rf -- "$d" 2>/dev/null || true
    done
    return "$leaks" 2>/dev/null || true
}

run_suite() { # NAME TIMEOUT CMD...
    local name="$1" tmo="$2"; shift 2
    local out rc leaks
    printf -- '-- suite %s (timeout %ss)\n' "$name" "$tmo"
    out="$(timeout "$tmo" "$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -4 | sed 's/^/    /'
    if (( rc == 0 )); then
        ok "suite: $name rc=0"
    elif (( rc == 124 )); then
        bad "suite: $name TIMED OUT after ${tmo}s"
    else
        bad "suite: $name rc=$rc"
    fi
    leaks=0; sweep_leaks || leaks=$?
    if (( leaks > 0 )); then bad "suite-leak: $name left processes/dirs behind (swept)"; else ok "suite-leak: $name clean"; fi
}

run_suite test/validate.sh-selftest 420 bash test/validate.sh
# BUG-008 fix: also run (and lint, P1 above) the BUG-002 regression suite — hermetic
# (fake chrome), so safe in --fast mode too.
run_suite test/bootrace.sh 600 bash test/bootrace.sh

HAVE_CHROME=0
command -v google-chrome-stable >/dev/null 2>&1 && HAVE_CHROME=1
HAVE_MASTER=0
[[ -n "$(ls -A "$HOME/.agent-chrome-profiles/master-profile" 2>/dev/null || true)" ]] && HAVE_MASTER=1

if (( FAST )); then
    info "--fast: skipping real-Chrome suites"
elif (( HAVE_CHROME && HAVE_MASTER )); then
    run_suite test/transparency.sh 540 bash test/transparency.sh
    run_suite test/release_reaper.sh 540 bash test/release_reaper.sh
    run_suite test/concurrency.sh 900 bash test/concurrency.sh
else
    info "real-Chrome suites skipped (chrome=$HAVE_CHROME master=$HAVE_MASTER)"
fi

# =============================================================================
# P4 — E2E HERMETIC JOURNEYS (fake chrome + fake agent-browser)
# =============================================================================
section "P4 E2E journeys (hermetic fakes)"

# --- sandbox layout ---------------------------------------------------------
V_STATE="$SB/state"; V_EPH="$SB/eph"; V_MASTER="$SB/master"
V_BIN="$SB/bin"
mkdir -p "$V_STATE" "$V_EPH" "$V_MASTER" "$V_BIN" "$V_HOME/.local"

# tiny fake master (non-empty so pool_check_master passes)
printf '{"profile":{"last_used":"Default"}}\n' >"$V_MASTER/Local State"
mkdir -p "$V_MASTER/Default"; printf 'x' >"$V_MASTER/Default/Preferences"

# --- fake chrome: real HTTP server on --remote-debugging-port ----------------
cat >"$V_BIN/fake-chrome" <<'PYEOF'
#!/usr/bin/env python3
import sys, os, signal, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port = 0; udd = ""
args = sys.argv[1:]
for a in args:
    if a.startswith('--remote-debugging-port='): port = int(a.split('=',1)[1])
    elif a.startswith('--user-data-dir='): udd = a.split('=',1)[1]
log = os.environ.get('FAKE_CHROME_LOG', '')
if log:
    with open(log, 'a') as f:
        f.write('LAUNCH port=%d udd=%s args=%s\n' % (port, udd, ' '.join(args)))
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"Browser": "fake-chrome",
                           "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/browser/0" % port}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(('127.0.0.1', port), H)
def stop(*_): os._exit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
srv.serve_forever()
PYEOF
chmod +x "$V_BIN/fake-chrome"

# --- fake agent-browser -------------------------------------------------------
cat >"$V_BIN/agent-browser" <<'ABEOF'
#!/usr/bin/env bash
log="${FAKE_AB_LOG:?}"; st="${FAKE_AB_STATE:?}"
sess="${AGENT_BROWSER_SESSION:-}"
# mirror the real CLI: key on the --session FLAG (the pool passes it as a flag;
# AGENT_BROWSER_SESSION env is unset during boot/adopt connect calls)
if [[ -z "$sess" ]]; then
    prev=""
    for a in "$@"; do
        if [[ "$prev" == "--session" ]]; then sess="$a"; break; fi
        [[ "$a" == --session=* ]] && { sess="${a#*=}"; break; }
        prev="$a"
    done
fi
printf 'SESSION=%s ARGS=%s\n' "$sess" "$*" >>"$log"
mkdir -p "$st"
case " $* " in
  *" connect "*)
      touch "$st/sessions"
      grep -qxF "$sess" "$st/sessions" 2>/dev/null || printf '%s\n' "$sess" >>"$st/sessions" ;;
  *" close "*)
      if [[ -f "$st/sessions" ]]; then
          grep -vxF "$sess" "$st/sessions" >"$st/sessions.tmp" 2>/dev/null || true
          mv -f "$st/sessions.tmp" "$st/sessions" 2>/dev/null || true
      fi ;;
esac
if [[ " $* " == *" session list "* ]]; then
    printf '{"data":{"sessions":['
    first=1
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        (( first )) || printf ','
        printf '"%s"' "$s"
        first=0
    done <"$st/sessions" 2>/dev/null
    printf ']}}\n'
fi
exit 0
ABEOF
chmod +x "$V_BIN/agent-browser"

FAKE_AB_LOG="$SB/ab.log"; : >"$FAKE_AB_LOG"
FAKE_AB_STATE="$SB/abstate"; mkdir -p "$FAKE_AB_STATE"
FAKE_CHROME_LOG="$SB/chrome.log"; : >"$FAKE_CHROME_LOG"

# pool env for every E2E invocation (NEVER exported globally — the real suites
# in P3 and the operator's real pool must not see these).
PENV=(env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME
      HOME="$V_HOME"
      AGENT_BROWSER_POOL_STATE="$V_STATE"
      AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH"
      AGENT_CHROME_MASTER="$V_MASTER"
      AGENT_BROWSER_REAL="$V_BIN/agent-browser"
      AGENT_CHROME_BIN="$V_BIN/fake-chrome"
      AGENT_CHROME_ALLOW_SLOW_COPY=1
      AGENT_CHROME_PORT_BASE=54620
      AGENT_CHROME_PORT_RANGE=100
      AGENT_BROWSER_POOL_WAIT=10
      FAKE_AB_LOG="$FAKE_AB_LOG" FAKE_AB_STATE="$FAKE_AB_STATE"
      FAKE_CHROME_LOG="$FAKE_CHROME_LOG")

pool() { timeout 90 "${PENV[@]}" bash bin/agent-browser-pool "$@"; }
ab_lines()      { wc -l <"$FAKE_AB_LOG" 2>/dev/null || printf '0'; }
chrome_launches(){ grep -c '^LAUNCH' "$FAKE_CHROME_LOG" 2>/dev/null || printf '0'; }
live_fakes()    { pgrep -f "$V_BIN/fake-chrome" 2>/dev/null || true; }

declare -a SIM_OWNERS=()
SPAWNED_PID=""
spawn_owner() { # sets SPAWNED_PID (live "owner" = exec'd sleep: no orphan on kill).
    # NOTE: callers must NOT use "$(spawn_owner)" — command substitution runs this
    # in a subshell and SIM_OWNERS would never reach the parent's cleanup trap.
    ( exec sleep 300 ) >/dev/null 2>&1 &
    SPAWNED_PID=$!
    SIM_OWNERS+=("$SPAWNED_PID")
}
as_owner() { # PID CMD...  (override AFTER PENV so its `env -u ...` doesn't strip it;
    #             STARTTIME deliberately unset — pool_owner_resolve TEST MODE reads the
    #             real /proc value itself, which is always correct for a live sim owner)
    local pid="$1"; shift
    timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$pid" \
        bash bin/agent-browser-pool "$@"
}

lease_json() { cat "$V_STATE/lanes/$1.json" 2>/dev/null || true; }
lease_field() { jq -r "$2" "$V_STATE/lanes/$1.json" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# E2E-01 install.sh journey (README "Install")
# ---------------------------------------------------------------------------
if timeout 120 env HOME="$V_HOME" \
    AGENT_BROWSER_POOL_STATE="$V_STATE" AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" \
    AGENT_CHROME_MASTER="$V_MASTER" AGENT_BROWSER_REAL="$V_BIN/agent-browser" \
    AGENT_CHROME_BIN="$V_BIN/fake-chrome" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
    bash install.sh >"$SB/install.out" 2>&1; then
    ok "e2e01 install.sh rc=0"
else
    bad "e2e01 install.sh failed: $(tail -3 "$SB/install.out" | tr '\n' ' ')"
fi
[[ -L "$V_HOME/.local/bin/agent-browser-pool" ]] && ok "e2e01 symlink created" || bad "e2e01 symlink missing"
[[ -d "$V_STATE/lanes" && -e "$V_STATE/acquire.lock" ]] && ok "e2e01 state dir pre-created" || bad "e2e01 state dir missing"

# ---------------------------------------------------------------------------
# E2E-02 empty pool: status (default + explicit), help
# ---------------------------------------------------------------------------
out="$(pool status 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"No active lanes."* ]] && ok "e2e02 status empty rc=0" || bad "e2e02 status empty: rc=$rc out=$out"
out="$(pool 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"No active lanes."* ]] && ok "e2e02 default verb = status" || bad "e2e02 default verb: rc=$rc"

# ---------------------------------------------------------------------------
# E2E-03 zero-prep open (the headline user story)
# ---------------------------------------------------------------------------
O1=""; spawn_owner; O1=$SPAWNED_PID
out="$(as_owner "$O1" open about:blank 2>"$SB/e03.err")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "e2e03 zero-prep open rc=0"; else bad "e2e03 zero-prep open rc=$rc: $(cat "$SB/e03.err")"; fi
[[ -f "$V_STATE/lanes/1.json" ]] && ok "e2e03 lane 1 lease exists" || bad "e2e03 lane 1 lease missing"
port="$(lease_field 1 .port)"
[[ "$port" =~ ^5[4-9][0-9]{3}$ ]] && (( port >= 54620 && port < 54720 )) \
    && ok "e2e03 port $port in [54620,54720)" || bad "e2e03 port out of range: $port"
[[ -d "$V_EPH/1" ]] && ok "e2e03 ephemeral dir created" || bad "e2e03 ephemeral dir missing"
[[ "$(chrome_launches)" -ge 1 ]] && ok "e2e03 chrome launched" || bad "e2e03 chrome never launched"
launch_line="$(grep '^LAUNCH' "$FAKE_CHROME_LOG" | head -1)"
[[ "$launch_line" == *"user-data-dir=$V_EPH/1"* ]] && ok "e2e03 chrome got right user-data-dir" || bad "e2e03 chrome udd wrong: $launch_line"
[[ "$launch_line" == *"--no-first-run --no-default-browser-check"* ]] && ok "e2e03 anti-first-run flags present" || bad "e2e03 flags missing"
[[ "$launch_line" != *"--headless"* ]] && ok "e2e03 windowed by default (fake)" || info "e2e03 headless flag seen (env?)"
last_ab="$(tail -1 "$FAKE_AB_LOG")"
[[ "$last_ab" == "SESSION=abpool-1 ARGS=open about:blank" ]] && ok "e2e03 real bin exec'd with clean args" || bad "e2e03 ab line: $last_ab"
[[ "$(lease_field 1 .connected)" == "true" ]] && ok "e2e03 lease connected=true" || bad "e2e03 lease connected=$(lease_field 1 .connected)"
[[ -f "$V_STATE/chrome-1.log" ]] && ok "e2e03 per-lane chrome log exists" || bad "e2e03 chrome log missing"

# ---------------------------------------------------------------------------
# E2E-04 same owner reuses the lane across stateless invocations
# ---------------------------------------------------------------------------
before="$(chrome_launches)"
out="$(as_owner "$O1" get cdp-url 2>"$SB/e04.err")"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e04 second command rc=0" || bad "e2e04 second command rc=$rc: $(cat "$SB/e04.err")"
[[ "$(chrome_launches)" -eq "$before" ]] && ok "e2e04 no re-launch on reuse" || bad "e2e04 chrome relaunched on reuse"
[[ "$(lease_field 1 .lane)" == "1" ]] && ok "e2e04 still lane 1" || bad "e2e04 lane changed"
tail -1 "$FAKE_AB_LOG" | grep -q 'SESSION=abpool-1 ARGS=get cdp-url' \
    && ok "e2e04 passthrough verb" || bad "e2e04 passthrough line: $(tail -1 "$FAKE_AB_LOG")"

# ---------------------------------------------------------------------------
# E2E-05 argument cleaning (--session strip / connect drop / bare connect noop)
# ---------------------------------------------------------------------------
as_owner "$O1" --session evil open http://example.com >/dev/null 2>&1
tail -1 "$FAKE_AB_LOG" | grep -q 'SESSION=abpool-1 ARGS=open http://example.com$' \
    && ok "e2e05 --session stripped + session forced" || bad "e2e05 session strip: $(tail -1 "$FAKE_AB_LOG")"
as_owner "$O1" open http://example.com --session=zz >/dev/null 2>&1
tail -1 "$FAKE_AB_LOG" | grep -q 'ARGS=open http://example.com --session=zz' \
    && bad "e2e05 --session= form NOT stripped" || ok "e2e05 --session= form stripped"
n_before="$(grep -c '9999' "$FAKE_AB_LOG" 2>/dev/null || true)"
out="$(as_owner "$O1" connect 9999 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e05 connect <port> rc=0 (no-op)" || bad "e2e05 connect rc=$rc"
[[ "$(grep -c '9999' "$FAKE_AB_LOG" 2>/dev/null || true)" -eq "${n_before:-0}" ]] \
    && ok "e2e05 connect arg dropped (bogus port never reached real bin)" || bad "e2e05 bogus port reached real bin"
out="$(as_owner "$O1" --session evil connect ws://x 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e05 --session+connect combo rc=0" || bad "e2e05 combo rc=$rc"

# ---------------------------------------------------------------------------
# E2E-06 close semantics (disconnect-only, --all scoped to my lane)
# ---------------------------------------------------------------------------
as_owner "$O1" close --all >/dev/null 2>&1
tail -1 "$FAKE_AB_LOG" | grep -q 'SESSION=abpool-1 ARGS=close$' \
    && ok "e2e06 close --all → close scoped to my session" || bad "e2e06 close scoping: $(tail -1 "$FAKE_AB_LOG")"
[[ "$(lease_field 1 .connected)" == "false" ]] && ok "e2e06 lease connected=false" || bad "e2e06 connected=$(lease_field 1 .connected)"
[[ -d "$V_EPH/1" ]] && ok "e2e06 lane dir survives close (disconnect-only)" || bad "e2e06 dir deleted on close"
[[ -n "$(live_fakes)" ]] && ok "e2e06 chrome survives close" || bad "e2e06 chrome died on close"

# ---------------------------------------------------------------------------
# E2E-07 close → next command rebinds the SAME lane (no re-copy/relaunch)
# ---------------------------------------------------------------------------
before="$(chrome_launches)"
as_owner "$O1" open about:blank >/dev/null 2>"$SB/e07.err"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e07 post-close open rc=0" || bad "e2e07 post-close open rc=$rc: $(cat "$SB/e07.err")"
[[ "$(chrome_launches)" -eq "$before" ]] && ok "e2e07 same chrome reused after close" || bad "e2e07 chrome relaunched after close"
[[ "$(lease_field 1 .connected)" == "true" ]] && ok "e2e07 reconnected (connected=true)" || bad "e2e07 connected=$(lease_field 1 .connected)"

# ---------------------------------------------------------------------------
# E2E-08 two owners → two lanes, two ports (mutual exclusion)
# ---------------------------------------------------------------------------
O2=""; spawn_owner; O2=$SPAWNED_PID
as_owner "$O2" open about:blank >/dev/null 2>"$SB/e08.err"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e08 owner2 open rc=0" || bad "e2e08 owner2 rc=$rc: $(cat "$SB/e08.err")"
p1="$(lease_field 1 .port)"; p2="$(lease_field 2 .port)"
[[ -n "$p2" && "$p2" != "$p1" && "$p2" != "null" ]] \
    && ok "e2e08 distinct lanes+ports ($p1 vs $p2)" || bad "e2e08 lanes/ports: p1=$p1 p2=$p2"
[[ "$(lease_field 2 .ephemeral_dir)" == "$V_EPH/2" ]] && ok "e2e08 lane2 dir distinct" || bad "e2e08 lane2 dir: $(lease_field 2 .ephemeral_dir)"
out="$(pool status 2>&1)"
[[ "$out" == *"LANE"* && "$out" == *"live"* ]] && ok "e2e08 status table shows live lanes" || bad "e2e08 status: $out"

# ---------------------------------------------------------------------------
# E2E-09 crash semantics: owner dies → next acquire reaps (adopt-or-release)
# ---------------------------------------------------------------------------
kill "$O2" 2>/dev/null || true; wait "$O2" 2>/dev/null || true
pid2="$(lease_field 2 .chrome_pid)"
O3=""; spawn_owner; O3=$SPAWNED_PID
before="$(chrome_launches)"
as_owner "$O3" open about:blank >/dev/null 2>"$SB/e09.err"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e09 owner3 open rc=0 after owner2 death" || bad "e2e09 owner3 rc=$rc: $(cat "$SB/e09.err")"
# REUSE-ORPHAN (PRD §2.4 3b): lane2's chrome is responsive → adopted by owner3,
# keeping the SAME chrome pid and NOT relaunching
[[ "$(lease_field 2 .owner.pid)" == "$O3" ]] \
    && ok "e2e09 orphan lane now owned by owner3" \
    || bad "e2e09 lane2 not taken over by owner3 (owner pid=$(lease_field 2 .owner.pid))"
[[ "$(lease_field 2 .chrome_pid)" == "$pid2" ]] \
    && ok "e2e09 orphan lane adopted (same chrome pid $pid2, reuse-if-responsive)" \
    || bad "e2e09 chrome replaced (adopt path not taken; pid $(lease_field 2 .chrome_pid) != $pid2)"
[[ "$(chrome_launches)" -eq "$before" ]] && ok "e2e09 no chrome relaunch (adopted)" || bad "e2e09 chrome relaunched (no adoption)"

# ---------------------------------------------------------------------------
# E2E-10 reap + release teardown (operator journey from README)
# ---------------------------------------------------------------------------
# tear down O3's lane first (kill owner → reap) so the pool is EMPTY for the
# remaining journeys (a live owner legitimately keeps its chrome)
kill "$O3" 2>/dev/null || true; sleep 0.3
out="$(pool reap 2>&1)"
[[ ! -e "$V_STATE/lanes/2.json" && ! -e "$V_EPH/2" ]] \
    && ok "e2e10 owner3 lane reaped after death" || bad "e2e10 owner3 lane leftovers"
out="$(pool release 1 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e10 release 1 rc=0" || bad "e2e10 release 1 rc=$rc"
[[ ! -e "$V_STATE/lanes/1.json" && ! -e "$V_EPH/1" ]] && ok "e2e10 lane1 lease+dir gone" || bad "e2e10 lane1 leftovers"
out="$(pool release 42 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "e2e10 release of unleased lane fails (rc=$rc)" || bad "e2e10 release 42 rc=0?"
out="$(pool reap 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "e2e10 reap rc=0" || bad "e2e10 reap rc=$rc"
[[ -z "$(live_fakes)" ]] && ok "e2e10 all fake chromes killed by reap/release" || bad "e2e10 chromes alive: $(live_fakes | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# E2E-11 fail-fast: no recognized harness ancestor (PRD §2.4 step 1)
# ---------------------------------------------------------------------------
out="$(timeout 60 env -u AGENT_BROWSER_POOL_OWNER_PID -u AGENT_BROWSER_POOL_OWNER_STARTTIME \
    HOME="$V_HOME" AGENT_BROWSER_POOL_STATE="$V_STATE" AGENT_CHROME_EPHEMERAL_ROOT="$V_EPH" \
    AGENT_CHROME_MASTER="$V_MASTER" AGENT_BROWSER_REAL="$V_BIN/agent-browser" \
    AGENT_CHROME_BIN="$V_BIN/fake-chrome" AGENT_CHROME_ALLOW_SLOW_COPY=1 \
    AGENT_BROWSER_POOL_HARNESSES=definitelynope \
    bash bin/agent-browser-pool open about:blank 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"supported agent harness"* ]] \
    && ok "e2e11 no-harness fail-fast" || bad "e2e11 fail-fast: rc=$rc out=$out"

# ---------------------------------------------------------------------------
# E2E-12 caller-scoped lanes (ABPOOL_OWNER=caller): parallel subprocesses
# ---------------------------------------------------------------------------
: >"$FAKE_AB_LOG"
caller_pids=()
for i in 1 2; do
    ( timeout 90 "${PENV[@]}" ABPOOL_OWNER=caller bash -c '
          exec 3>/dev/null
          bin='"$ROOT"'/bin/agent-browser-pool
          cd /; exec "$bin" open about:blank' ) &
    caller_pids+=("$!")
done
wait "${caller_pids[@]}"   # wait ONLY for these jobs (bare `wait` would also block
                            # on the 300s sim-owner sleeps → spurious hang)
lanes_live="$(find "$V_STATE/lanes" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
(( lanes_live == 2 )) && ok "e2e12 two caller-mode children → 2 distinct lanes" \
    || bad "e2e12 caller-mode lanes: $lanes_live (want 2)"
out="$(pool reap 2>&1)"; rc=$?
[[ "$out" == *"Reaped 2"* ]] && ok "e2e12 caller lanes auto-reaped after exit" || bad "e2e12 reap after caller exit: $out"
[[ -z "$(live_fakes)" ]] && ok "e2e12 chromes reaped" || bad "e2e12 chromes left: $(live_fakes | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# E2E-13 lane pinning (ABPOOL_LANE): free adopt / live-foreign hard error / malformed
# ---------------------------------------------------------------------------
O4=""; spawn_owner; O4=$SPAWNED_PID          # OA: pins a FREE lane as its FIRST command (holds no other lane)
out="$(timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O4" ABPOOL_LANE=5 \
    bash bin/agent-browser-pool open about:blank 2>&1)"; rc=$?
[[ $rc -eq 0 && -f "$V_STATE/lanes/5.json" && "$(lease_field 5 .owner.pid)" == "$O4" ]] \
    && ok "e2e13 pin adopts free lane 5" || bad "e2e13 pin free: rc=$rc $out"
O5=""; spawn_owner; O5=$SPAWNED_PID          # OB: FIRST command = pin OA's LIVE lane → hard error, never takeover
out="$(timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O5" ABPOOL_LANE=5 \
    bash bin/agent-browser-pool open about:blank 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"never a takeover"* ]] \
    && ok "e2e13 live-foreign pin hard-errors" || bad "e2e13 foreign pin: rc=$rc out=$out"
[[ "$(lease_field 5 .owner.pid)" == "$O4" ]] && ok "e2e13 pinned lane ownership unchanged" || bad "e2e13 takeover happened!"
# OA pinning a SECOND lane while already holding lane 5 → one-lane-per-owner guard
out="$(timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O4" ABPOOL_LANE=6 \
    bash bin/agent-browser-pool open about:blank 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"one-lane-per-owner"* ]] \
    && ok "e2e13 second-lane pin guarded" || bad "e2e13 second-lane pin: rc=$rc out=$out"
out="$(timeout 60 "${PENV[@]}" ABPOOL_LANE=abc bash bin/agent-browser-pool status 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"positive integer"* ]] && ok "e2e13 malformed pin dies at startup" || bad "e2e13 malformed pin: rc=$rc out=$out"
pool release all >/dev/null 2>&1

# ---------------------------------------------------------------------------
# E2E-14 master hygiene: source read-only, Singleton* stripped from the copy
# ---------------------------------------------------------------------------
master_hash_before="$(find "$V_MASTER" -type f ! -name 'Singleton*' | sort | xargs md5sum 2>/dev/null | md5sum)"
printf 'host-123' >"$V_MASTER/SingletonLock"; : >"$V_MASTER/SingletonCookie"; : >"$V_MASTER/SingletonSocket"
O6=""; spawn_owner; O6=$SPAWNED_PID
as_owner "$O6" open about:blank >/dev/null 2>&1
lane6="$(ls "$V_STATE/lanes" 2>/dev/null | sed 's/\.json//' | sort -n | tail -1)"
if compgen -G "$V_EPH/$lane6/Singleton*" >/dev/null 2>&1; then
    bad "e2e14 Singleton artifacts survived in copy"
else
    ok "e2e14 Singleton* stripped from ephemeral copy"
fi
master_hash_after="$(find "$V_MASTER" -type f ! -name 'Singleton*' | sort | xargs md5sum 2>/dev/null | md5sum)"
[[ "$master_hash_before" == "$master_hash_after" ]] \
    && ok "e2e14 master untouched by acquires" \
    || bad "e2e14 master mutated by pool"
rm -f "$V_MASTER/SingletonLock" "$V_MASTER/SingletonCookie" "$V_MASTER/SingletonSocket"
pool release all >/dev/null 2>&1

# ---------------------------------------------------------------------------
# E2E-15 doctor: orphan dir detection + reap cleanup
# ---------------------------------------------------------------------------
mkdir -p "$V_EPH/99"
out="$(pool doctor 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"ORPHAN"* ]] && ok "e2e15 doctor flags orphan dir (WARN, rc0)" || bad "e2e15 doctor: rc=$rc"
out="$(pool reap 2>&1)"
[[ ! -e "$V_EPH/99" ]] && ok "e2e15 reap removes orphan dir" || bad "e2e15 orphan dir left"

# ---------------------------------------------------------------------------
# E2E-16 REGRESSION: stuck provisional lane on the reuse path (port=0)
#   Boot dies after claim (empty master) → lease stays (port 0, owner alive).
#   PRD §2.4/§2.15 expect the next command to recover (boot the lane).
#   Observed: wrapper reuses the lease, never boots, dies "not connected".
# ---------------------------------------------------------------------------
V2_STATE="$SB/state2"; V2_MASTER="$SB/master2"
mkdir -p "$V2_STATE" "$V2_MASTER"     # master2 EMPTY
O7=""; spawn_owner; O7=$SPAWNED_PID
out="$(timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O7" \
    AGENT_BROWSER_POOL_STATE="$V2_STATE" AGENT_CHROME_MASTER="$V2_MASTER" \
    bash bin/agent-browser-pool open about:blank 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"source profile missing or empty"* ]] \
    && ok "e2e16 boot fails on empty master (rc=$rc)" || bad "e2e16 empty master boot: rc=$rc $out"
[[ -f "$V2_STATE/lanes/1.json" ]] \
    && ok "e2e16 provisional lease survives failed boot (as coded)" \
    || bad "e2e16 no provisional lease (e2e16 premise wrong)"
# populate the master, retry — the wrapper SHOULD boot now
mkdir -p "$V2_MASTER/Default"; printf 'x' >"$V2_MASTER/Default/Preferences"
out="$(timeout 90 "${PENV[@]}" AGENT_BROWSER_POOL_OWNER_PID="$O7" \
    AGENT_BROWSER_POOL_STATE="$V2_STATE" AGENT_CHROME_MASTER="$V2_MASTER" \
    bash bin/agent-browser-pool open about:blank 2>"$SB/e16.err")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "e2e16 stuck-lane recovery works"
else
    bad "e2e16 REGRESSION stuck-provisional-lane: live owner permanently blocked after failed boot ($(head -1 "$SB/e16.err"))"
fi
timeout 60 "${PENV[@]}" AGENT_BROWSER_POOL_STATE="$V2_STATE" AGENT_CHROME_MASTER="$V2_MASTER" \
    bash bin/agent-browser-pool release all >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# E2E-17 final: no processes left, sandbox clean
# ---------------------------------------------------------------------------
sleep 1
[[ -z "$(live_fakes)" ]] && ok "e2e17 no fake chromes left" || bad "e2e17 fake chromes left: $(live_fakes | tr '\n' ' ')"
left="$(pgrep -f 'user-data-dir=.*abpool-validate' 2>/dev/null || true)"
[[ -z "$left" ]] && ok "e2e17 no sandbox chromes left" || bad "e2e17 sandbox chromes left: $left"

# =============================================================================
cleanup() {
    for p in "${SIM_OWNERS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    # belt-and-suspenders: reap any exec'd sim-owner sleeps (anchored: cannot match
    # this script's own cmdline) and any fake/sandbox chromes
    for p in $(pgrep -f '^sleep 300$' 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$V_BIN/fake-chrome" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f 'user-data-dir=.*abpool-validate' 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    rm -rf -- "$ABPOOL_VALIDATE_SANDBOX" 2>/dev/null || true
}
trap 'cleanup' EXIT INT TERM

# =============================================================================
section "SUMMARY"
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf 'Failed checks:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
exit 0