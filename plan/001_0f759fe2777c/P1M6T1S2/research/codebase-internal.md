# Codebase Recon — P1.M6.T1.S2: `close --all` interception + `connect` arg normalization

**Scope:** read-only recon of `lib/pool.sh` (3086 lines, ends in `pool_dispatch_classify`) +
PRD/external_deps + live `agent-browser` CLI (v0.28.0). Two NEW pure bash functions
(`pool_normalize_close`, `pool_normalize_connect`) will be appended at EOF after the
`# Wrapper shim — command dispatch (P1.M6.T1.S1)` banner. Host: bash 5.3, shellcheck 0.11.0,
`set -euo pipefail`.

---

## 1. Array / multi-value return conventions in `lib/pool.sh`

### What exists (grep-verified)

| mechanism | count | representative lines |
|---|---|---|
| `declare -g` (scalar global set by a function) | ~27 | `lib/pool.sh:132,144-147,158,166-168,175-177,183-184` (config); `:496,505-506,508,513,519,555-556,560,565` (owner); `:1514,1528` (chrome pid/pgid) |
| `declare -ga` / `declare -gA` (global ARRAY) | **0** | none |
| `local -n` / `declare -n` (nameref) | **0** | none (confirmed across all of `lib/`) |
| `mapfile -d ''` (NUL-delim) | **0** | none |
| `mapfile -t` (newline-delim, into LOCAL array) | 3 | `lib/pool.sh:1184` (`_owner`), `:1830` (`_f`), `:2306` (`_f`) — all INTERNAL jq-field extraction, NOT function return values |
| stdout-echo-of-multiple-tokens | 1 | `pool_lanes_list` (`lib/pool.sh:967-981`): one lane-N per line via `printf '%s\n' "$n"` piped to `sort -n` |

### Dominant pattern — single scalar token via stdout + rc 0/1

Every public function that "returns a value" **echoes exactly one token on stdout** and uses
the return code for ok/no-match. Callers capture with the split form `local N; if N="$(func)"; then …`
(split mandatory: `local N=$(…)` masks errexit — BashFAQ 105; documented at `lib/pool.sh:2033-2036`).

- `pool_lease_find_mine` (`lib/pool.sh:1003-1040`): echoes lane N, `return 0`; or `return 1`.
  Callers MUST guard: `if n="$(pool_lease_find_mine)"; then …` (`:1035-1037`).
- `_pool_acquire_critical_section` (`lib/pool.sh:1966-2041`) / `pool_acquire_locked` (`:2043-2085`):
  echoes claimed lane N inside the `( flock 9; … ) 9>"$POOL_LOCK_FILE"` subshell; stdout
  propagates through `$(…)`; `return 1` on exhaustion/passthrough (`:1976-1977`).
- `pool_dispatch_classify` (`lib/pool.sh:3030-3086`): echoes `'meta'`/`'driving'`; `return 0` ALWAYS.

### The four functions named in the task

- **`pool_chrome_launch`** (`lib/pool.sh:1471-1568`): returns **rc only (0 / pool_die)** — NO stdout
  value. Communicates via GLOBALS: `POOL_CHROME_PID=$!; declare -g POOL_CHROME_PID` (`:1514`)
  and `POOL_CHROME_PGID="$pgid"; declare -g POOL_CHROME_PGID` (`:1528`). Builds a LOCAL array
  `flags=( … )` (`:1500-1510`) but **never returns it** — used only for the local `setsid … "${flags[@]}"` call.
- **`pool_acquire_locked`** (`lib/pool.sh:2043-2085`): single scalar N via stdout (see above).
- **`pool_lanes_list`** (`lib/pool.sh:967-981`): the ONLY multi-token-stdout function. Newline-separated
  lane numbers; consumed unquoted `for n in $(pool_lanes_list)` (e.g. `:1024,1983`).
- **`pool_lease_find_mine`** (`lib/pool.sh:1003-1040`): single scalar N via stdout + rc 0/1.

### ⚠ KEY FINDING — NO precedent for returning an ARG array (not a scalar)

Both M6.T1.S2 functions must **return a normalized arg array** (item contract: "Return normalized
args" / "OUTPUT: Normalized args"). There is **no existing precedent** for this in `lib/pool.sh`:
no nameref, no global array, no NUL-delimited stdout. The implementer must ESTABLISH a new idiom.
Candidate mechanisms, ranked by safety for args-that-may-contain-spaces:

1. **nameref (local -n)** — e.g. `pool_normalize_close out "$@"`, caller `local -a out; pool_normalize_close out "$@"`.
   Cleanest; no stdout; survives spaces. BUT introduces the codebase's FIRST nameref (0 today).
2. **NUL-delimited stdout** — `func` does `printf '%s\0' "${out[@]}"`; caller `mapfile -d '' -t arr < <(func "$@")`.
   Introduces the codebase's FIRST `mapfile -d ''` (0 today). Also safe for spaces.
3. **newline-delimited stdout** (like `pool_lanes_list`) — UNSAFE: `connect`/`close` themselves are
   simple, but a general "return normalized args" path could carry args with spaces/newlines
   (e.g. a future `type` passthrough). `$( )` capture also loses trailing newlines.

➡ **This is a design decision the implementer must make (no in-codebase precedent).** See Open
Questions §6. The "set a flag to close ONLY my session" output of `pool_normalize_close` is a
SECOND return value (args + bool) → reinforces that nameref (multiple out-params) or a distinct
mechanism is needed.

---

## 2. The `set -e` / bare-`(( ))`-returns-rc1 trap

### Exact comment (lines 362-365, inside `_pool_age_str` doc-block)

```
lib/pool.sh:362  #   GOTCHA (set -e + arithmetic): a bare `(( expr ))` as a STATEMENT returns
lib/pool.sh:363  #   exit status 1 when the result is 0 — FATAL under set -e. EVERY `(( ))` here
lib/pool.sh:364  #   is inside `if`/`elif` (exempt from errexit). The `$(( ))` EXPANSION form is
lib/pool.sh:365  #   always safe.
```

(Cross-referenced by the classify GOTCHA at `lib/pool.sh:3026` as "lib/pool.sh:362-364".)

### How `pool_dispatch_classify` avoids it (`lib/pool.sh:3030-3086`)

- **Shift-based iteration, no index counter.** The only `(( ))` is the loop *condition*
  `while (( $# > 0 ))` (`lib/pool.sh:3035`) — conditions are errexit-exempt, so a 0-arg (loop exit)
  cannot abort. There is **no** `(( i++ ))` statement anywhere (that is the exact trap: `(( i++ ))`
  when `i` was 0 returns rc 1 → ABORT).
- **`shift 2 || shift`** for `--session <X>` (`lib/pool.sh:3048`): the `||`-list is errexit-exempt;
  tolerates a trailing `--session` with no value (shift 2 fails → `shift` consumes just `--session`).

### Exact case-arms of the arg scan (`lib/pool.sh:3037-3061`) — mirror these

```bash
    while (( $# > 0 )); do
        tok="$1"
        case "$tok" in
            --help|-h|--version)            # short-circuit → 'meta'; return 0
                printf 'meta\n'; return 0 ;;
            --session)                      # SPACE form: flag + value
                shift 2 || shift ;;
            --*)                            # ANY other long flag (--json, --session=X, --headed, …)
                shift ;;                    #   treated as shift-1 (bool)
            -*)                             # ANY short flag except -h (-i,-c,-d,-p,-v,-q,…)
                shift ;;
            *)                              # FIRST non-flag = COMMAND; peek next, break
                cmd="$1"; next="${2:-}"; break ;;
        esac
    done
```

**⚠ IMPORTANT CAVEAT for a mirror scan:** classify treats **every long flag except `--session`** as
a shift-1 boolean. This is SAFE for classify (mis-parsing a leading value-flag still defaults to
'driving'). It is **NOT** safe for a normalize function that must precisely locate `close`/`connect`
or count args — see §3 for the full list of value-taking flags that would be mis-shifted.

---

## 3. `agent-browser` CLI semantics (live, v0.28.0, `/home/dustin/.local/bin/agent-browser`)

### `close --help`
```
Usage: agent-browser close [options]
Options:        --all    Close all active sessions     ← the ONLY close-specific option
Global Options: --json   Output as JSON
                --session <name>     Use specific session
Aliases: quit, exit
```
→ **`--all` is the ONLY close-specific flag.** `--json` and `--session <name>` are the only
"global" opts (available in any position). No other close-specific flag exists.

### `connect --help`
```
Usage: agent-browser connect <port|url>     ← <port|url> shown as REQUIRED (angle brackets)
Arguments: <port> Local port number (e.g., 9222)
           <url>  Full WebSocket URL (ws://, wss://, http://, https://)
Global Options: --json, --session <name>
```
→ `<port|url>` is **documented as required.** **Bare `connect` (no arg) is REJECTED:**
```
$ agent-browser connect
Missing arguments for: connect
Usage: agent-browser connect <port|url>
EXIT=1
```
→ `--json` / `--session` are **global, available in ANY position.** Verified live:
`agent-browser connect 99999999 --json` parsed `--json` after the port (returned a JSON error
about the port, exit 0). So a normalize scan cannot assume the port/url is the only positional.

### `agent-browser --help` — which flags take a VALUE (need shift-2 in an arg scan)?

The task's specific checklist — **ALL take an argument:**

| flag | takes value? |
|---|---|
| `--session <name>` | ✅ value |
| `--state <path>` | ✅ value |
| `--executable-path <path>` | ✅ value |
| `--cdp <port>` | ✅ value |
| `--headers <json>` | ✅ value |
| `--extension <path>` | ✅ value (repeatable) |
| `--download-path <path>` | ✅ value |
| `--color-scheme <scheme>` | ✅ value |
| `--session-name <name>` | ✅ value |

**And MANY MORE value-taking flags exist** beyond `--session` (full set, from the `Options:`,
`Authentication:`, and `Snapshot Options:` sections):
```
--session, --executable-path, --extension, --init-script, --enable, --args, --user-agent,
--proxy, --proxy-bypass, --profile, --session-name, --state, --headers, -p/--provider,
--device, --screenshot-dir, --screenshot-quality, --screenshot-format, --cdp,
--color-scheme, --download-path, --max-output, --allowed-domains, --action-policy,
--confirm-actions, --engine, --model, --config, -d/--depth, -s/--selector
```
Boolean (shift-1) flags: `--json, --annotate, --headed, --ignore-https-errors, --allow-file-access,
--content-boundaries, --confirm-interactive, --no-auto-dialog, --auto-connect, -v/--verbose,
-q/--quiet, --debug, --version/-V, -i/--interactive, -c/--compact`.

**⚠ Footgun — OPTIONAL bool flags** (`agent-browser --help` → "Boolean flags accept an optional
true/false value"): `--headed false`, `--hide-scrollbars false`. A naive scanner sees `--headed`
as bool (shift-1) then `false` as a positional command — ambiguous. (`--hide-scrollbars <bool>`
even *documents* the value form.)

➡ **Implication:** a normalize arg-scan that wants to robustly find `close`/`connect` among
leading flags CANNOT mirror classify's "all `--*` ⇒ shift-1" shortcut — it would mis-handle
`agent-browser --executable-path /x connect 9222` (the path becomes the "command"). Either
enumerate the value-flag set, or (recommended for M6.T1.S2) scope the scan so it does not need
to fully parse leading global flags — see §6.

---

## 4. Scope boundary vs siblings (M6.T2.S1 / M6.T3.S1)

### Sibling PRP dirs — **NOT YET BUILT**
```
plan/001_0f759fe2777c/P1M6T2S1/   → does NOT exist
plan/001_0f759fe2777c/P1M6T3S1/   → does NOT exist
```
Only `P1M6T1S1/` (classify, DONE) and `P1M6T1S2/` (this task) exist under M6.

### PRD §2.4 step 5 — the FINAL exec (PRD.md:140-142)
```
└─ 5. EXEC real binary with AGENT_BROWSER_SESSION=abpool-<N> forced + original args.
       Strip any inherited --session / AGENT_BROWSER_SESSION so the agent can't bypass its lane.
```

### external_deps.md §1.3 — Session/Connection special-handling table
| Agent Invocation | Wrapper Behavior |
|---|---|
| `connect <port>` / `connect <url>` | **Ignore the arg.** Ensure MY lane is connected. |
| `--session <X> <cmd>` | **Override** to `abpool-<N>`. **Strip** the agent's `--session` flag. |
| `AGENT_BROWSER_SESSION=<X> <cmd>` | **Override** env to `abpool-<N>`. |
| `close` | Disconnect MY lane's daemon only. |
| `close --all` | **Intercept:** disconnect MY lane only. NEVER close --all (would nuke peers). |

### ✅ CONFIRMED scope boundary
- **FINAL exec = STRIP the agent's `--session` AND FORCE `AGENT_BROWSER_SESSION=abpool-<N>` via
  ENV** (not "add `--session abpool-<N>`"). This is §2.4 step 5 + §1.3 ("Override env"/"Strip the
  agent's --session flag").
- **That `--session` stripping + env-forcing is M6.T2.S1's job, NOT M6.T1.S2's.** Confirmed by the
  sibling task's PRP (P1M6T1S1/PRP.md, repeated verbatim): "SCOPE — classify ONLY. Does NOT
  intercept `close --all`, normalize `connect <arg>` **(M6.T1.S2)**, strip `--session`, or force
  `AGENT_BROWSER_SESSION` **(M6.T2.S1)**."
- **Therefore: M6.T1.S2's normalize functions MUST NOT touch `--session`.** They handle ONLY:
  (a) `close` → strip `--all`; (b) `connect` → strip the `<port|url>` arg. `--session` (and any
  other global flag) passes through untouched; M6.T2.S1 strips/overrides it later; M6.T3.S1 wires
  the lifecycle + forces the env on the final exec.

The M6.T1.S2 item contract (tasks.json) corroborates verbatim:
> `pool_normalize_close(args)`: If command is 'close' and '--all' is present → strip '--all',
> set a flag to close ONLY my session. The real exec will be `close --session abpool-<N>`.
> `pool_normalize_connect(args)`: If command is 'connect' → strip the port/url argument entirely.
> The lane connection is ensured by ensure_connected. Return normalized args.

---

## 5. ShellCheck status + SC codes to avoid

### Current status: **100% clean**
```
$ shellcheck -s bash lib/pool.sh
$ echo $?
0          # zero warnings, host-verified (ShellCheck 0.11.0)
```
Only TWO `disable` pragmas in the file, both intentional SC2034 (exported-contract / tunable):
`lib/pool.sh:124` (POOL_* globals) and `lib/pool.sh:1569` (`POOL_CDP_TRIES`).

### SC codes referenced in comments (the codebase's "known-good" avoidance idioms)
- **SC2155** (`declare`+assign masks return status) — referenced ~12× (e.g. `lib/pool.sh:372,452,
  708,788,2179,2454,2537,2570,2632,2690,2730,2894`). **Idiom:** split into two statements,
  `local now diff; now="$(date '+%s')"` (`lib/pool.sh:371-372`). Use this for any new `local`.
- **SC2034** (unused var) — only the 2 intentional disables above.
- **SC2086** (unquoted var word-splitting) — avoided; quote everything.
- **SC2178** (array-as-scalar) / **SC2120** (function args) — not referenced; relevant if the
  implementer uses array vars: `${arr[@]}` (quoted, plural) for expansion, NOT `$arr`.

### Codes the new code MUST keep clean (new code adds zero net warnings)
- **SC2155** — split every `local x="$(…)"` / `local -a x=(… )`-with-command-substitution.
- **SC2086** — quote `"$1"`, `"${arr[@]}"`.
- **SC2120** — if a function documents params it must actually read them (or it's fine to take `"$@"`).
- **SC2178** — never treat an array as a scalar; expansion is `"${arr[@]}"`.
- If a nameref is chosen (§1/§6), expect **SC2178/SC2034** interactions — `local -n` targets need
  care; you may need `# shellcheck disable=SC2178` (which would be the codebase's FIRST such disable).

---

## 6. Open questions / risks for the implementer

1. **Array-return mechanism has NO precedent (§1).** The implementer must choose nameref vs
   NUL-delimited-stdout vs (unsafe) newline-stdout. Nameref is cleanest but is a first for this
   codebase. → surface to parent / decide before coding.
2. **`pool_normalize_close` returns TWO outputs** (normalized args + a "close-only-my-session"
   bool flag). This pushes toward nameref (multiple out-params) or a separate sentinel, since
   stdout can carry only the args.
3. **Arg-scan completeness (§2/§3):** classify's "all `--*` ⇒ shift-1" shortcut is unsafe for a
   precise normalize scan (value flags like `--executable-path`/`--cdp`/`--state`/`--color-scheme`
   would be mis-shifted). Decide whether normalize needs full value-flag enumeration, or whether it
   can operate locally around the `close`/`connect` token without re-parsing all leading globals.
4. **Optional-bool flags** (`--headed false`, `--hide-scrollbars false`) are inherently ambiguous
   to any scanner — note as an accepted limitation if encountered.
5. **Bare `connect` is a runtime ERROR (exit 1).** After normalize strips the port/url, the
   lifecycle's "ensure_connected" must run BEFORE the final exec, or `close`/`connect` semantics
   could surface the "Missing arguments" error. (Lifecycle concern → M6.T3.S1, not this task.)

## Start here
Open `lib/pool.sh:3030` (`pool_dispatch_classify`) — it is the immediate sibling, the EOF
insertion point, and the case-arm template. Then `lib/pool.sh:967` (`pool_lanes_list`, the only
multi-token-stdout precedent) and `lib/pool.sh:1471` (`pool_chrome_launch`, the local-array +
`declare -g` globals precedent) for the return-mechanism decision.
