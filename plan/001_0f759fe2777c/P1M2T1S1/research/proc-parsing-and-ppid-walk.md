# Research: /proc parsing, ppid walk, test-hook overrides (P1.M2.T1.S1)

Date: 2026-07-12
Host-verified facts for the `pool_owner_resolve()` implementation.

---

## 1. HOST-VERIFIED /proc FACTS (this session)

### 1.1 ppid chain walk (this very session)
Walking ppid from `$$`:
```
pid=<bash> comm='bash' ppid=<pi>
pid=<pi>   comm='pi'   → STOP (match found)
```
Full chain to init: `bash → pi → timeout → zsh → systemd-inhibit → zsh → tmux:server → systemd → 1`.
The `pi` ancestor is the immediate parent of the bash tool-call shell. ✅ Confirms PRD §1.1.

### 1.2 /proc/<pid>/comm
- Returns the BARE comm (no parens), with a single trailing newline.
- Read idiom: `IFS= read -r comm < "/proc/$pid/comm"` (the `read` consumes the trailing
  newline, so no `${comm%$'\n'}` needed).
- Under `set -e`, a bare redirection-into-`read` that fails (process gone, EACCES) ABORTS.
  Guard with `|| true` or `if`.

### 1.3 /proc/<pid>/status (PPid: line)
- Format: `PPid:\t<N>` (tab-separated).
- Parse: `awk '/^PPid:/ {print $2}' /proc/$pid/status` or pure-bash loop.
- This is the ROBUST source of ppid — avoids the comm-paren parsing problem entirely.

### 1.4 /proc/<pid>/stat — starttime (field 22)
- Field 2 (comm) is wrapped in parens and CAN contain spaces → naive `awk '{print $22}'`
  is WRONG when comm has spaces. For `pi` (no spaces) `cut -d' ' -f22` happens to work,
  but the parens-aware method is required for robustness.
- **Verified starttime values this session** (all agree):
  - `cut -d' ' -f22 /proc/self/stat` → 8239564
  - `sed 's/.*)//' /proc/self/stat | awk '{print $20}'` → 8239564
- **Robust method**: strip everything up to and including the LAST `)`, then field 20
  of the remainder (= field 22 overall, offset −2).
  ```bash
  after="${line##*\)}"        # bash: longest prefix up to last ')'
  # OR: sed 's/.*)//' /proc/$pid/stat | awk '{print $20}'
  ```
- starttime is in **clock ticks since boot**; `getconf CLK_TCK` = **100** on this host.
- NOTE: This task EXTRACTS and STORES starttime only; the liveness/recycling *check*
  belongs to P1.M2.T2.S1 (`is_owner_alive`).

### 1.5 /proc/<pid>/cwd
- It's a symlink; `readlink /proc/$pid/cwd` returns the absolute cwd path.
- Can fail with EACCES (different uid / Yama ptrace_scope) or ENOENT (process died / cwd unlinked).
- Guard: `cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || true`; treat empty as "unknown".

---

## 2. STRICT-MODE (set -euo pipefail) TRAPS — verified

| Trap | Symptom | Fix |
|---|---|---|
| `local x="$(cmd)"` (SC2155) | masks cmd's exit status; hides failures under set -e | `local x; x="$(cmd)"` two-statement |
| bare `(( expr ))` statement | returns 1 when result is 0 → FATAL under set -e | always `if (( ))` or `(( )) \|\| ...` |
| `[[ "$v" =~ ^[0-9]+$ ]]` standalone | fails to match → returns 1 → aborts under set -e | use inside `if`/`\|\|`/`&&` (exempt) |
| `IFS= read ... < /missing` | redirection failure aborts under set -e | `\|\| true` or `if` wrap |
| `readlink /proc/X/cwd` failure | ENOENT/EACCES aborts under set -e | `\|\| true`, check empty |
| `${VAR}` under set -u when unset | unbound variable error | `${VAR:-}` |

---

## 3. GLOBAL-SETTING PATTERN

The existing `pool_config_init` uses: `POOL_STATE_DIR="$state_dir"; declare -g POOL_STATE_DIR`.
This "both" pattern works because no caller declares a `local` of the same name. The
cleaner single-statement form `declare -g POOL_OWNER_PID="$pid"` is strictly correct in
every scope (bash ≥ 4.2). **Recommendation**: use `declare -g POOL_OWNER_PID="$pid"` for
new globals. The POOL_OWNER_* globals are mutable (not readonly) so the function is
re-runnable (test harness calls it repeatedly with different overrides).

---

## 4. TEST-HOOK OVERRIDE ENV VARS (PRD §2.18, key_findings FINDING 8)

```bash
AGENT_BROWSER_POOL_OWNER_PID=<pid>         # simulate a specific owner PID (test mode)
AGENT_BROWSER_POOL_OWNER_STARTTIME=<val>   # simulate starttime
```
Detection under set -u: `[[ -n "${AGENT_BROWSER_POOL_OWNER_PID:-}" ]]`.
When PID override is set: skip the ppid walk, use it directly. Set
`POOL_OWNER_COMM='pi'` and `POOL_OWNER_STARTTIME` from the override (or empty if unset).
When PID override is NOT set: walk ppid from `$$` for `comm=='pi'`.

These are TEST-ONLY hooks — documented in code comments only, never in user-facing docs.

---

## 5. TASK BOUNDARY (this task vs P1.M2.T1.S2)

| Concern | This task (S1) | Sibling (S2) |
|---|---|---|
| ppid walk to comm=='pi' | ✅ HERE | — |
| test-hook overrides (PID, starttime) | ✅ HERE | — |
| `POOL_OWNER_PID` (0 if no pi) | ✅ HERE | — |
| `POOL_OWNER_COMM` | ✅ HERE | — |
| `POOL_OWNER_CWD` (readlink) | ✅ HERE | — |
| robust starttime **extraction** from /proc/stat | ✅ HERE (S2 is the robust extractor, but S1 calls it; see note below) | ✅ S2 |
| starttime stored in `POOL_OWNER_STARTTIME` | ✅ HERE (store value) | — |
| liveness/recycling **check** (`is_owner_alive`) | — | ✅ P1.M2.T2.S1 |

**IMPORTANT note on S1 vs S2 overlap**: The item description for S1 says "Extract starttime
(see S2)" — i.e. S1 STORES POOL_OWNER_STARTTIME but the robust extraction function is
provided by S2. To avoid a forward-dependency (S1 running before S2 is implemented), S1
should call S2's extraction function IF it exists, and otherwise fall back to a minimal
inline extraction (the `sed 's/.*)//' | awk '{print $20}'` one-liner, host-verified).
Since S1 and S2 run in parallel and S1 cannot assume S2 is landed, S1 must be
self-contained for starttime extraction but SHOULD delegate to S2's named function when
available. The cleanest contract: S1 implements `pool_owner_resolve()` which calls an
internal `_pool_owner_starttime(pid)` extractor — and S2 replaces/augments that extractor
with a more robust version. To keep S1 self-contained and avoid conflicts, S1 defines its
OWN minimal `_pool_owner_starttime()` inline; if S2 lands a same-named function, the later
sourcing wins (both append to the same file). Coordinate via this PRP's "Integration
Points" section.

---

## 6. SOURCES

- proc(5) man page: https://man7.org/linux/man-pages/man5/proc.5.html
  (comm field, status PPid line, stat field 22 starttime, cwd symlink, PID-recycling)
- kernel.org proc.rst: https://www.kernel.org/doc/html/latest/filesystems/proc.html
- GNU Bash Manual — declare (-g): https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- GNU Bash Manual — The Set Builtin (set -e exemptions): https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- GNU Bash Manual — Shell Parameter Expansion (`${VAR:-}`, `${var##pat}`): https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
- Architecture: plan/001_0f759fe2777c/architecture/system_context.md §6 (proc parsing), §2 (env)
- Architecture: plan/001_0f759fe2777c/architecture/key_findings.md FINDING 1 (starttime),
  FINDING 8 (test hooks)
- PRD §1.1 (pi ancestor), §2.4 step 1 (resolve OWNER), §2.18 (test overrides), §2.19 (proc parsing gotchas)
