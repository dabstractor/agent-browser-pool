# Research — P1.M6.T3.S2: `bin/agent-browser` executable (symlink-safe sourcing shim)

> **Scope:** The thin executable `bin/agent-browser` whose entire job is: enable strict
> mode → resolve its OWN real path (symlink-safe) → `source lib/pool.sh` → call
> `pool_wrapper_main "$@"`. Nothing else. It is the entry point that P1.M6.T3.S1's
> `pool_wrapper_main()` (lib-only) is written to be called by.
>
> **Task size:** 0.5 points. The verbatim contract is fixed (item description + T3.S1
> PRP "User Persona"). This note synthesizes the symlink-safety analysis and defines the
> ONE distinguishing validation (invoke the shim *through a symlink*). It deliberately
> re-uses the symlink research already produced in T3.S1's session rather than redoing it.

---

## 1. The two path resolutions are SEPARATE — this task owns only one

`external-bash-wrapper.md` §13 (read in full) draws the critical distinction:

| Resolution | Owned by | Resolves what | Mechanism |
|---|---|---|---|
| **A. shim self → `lib/pool.sh`** | **THIS task** | where is the *library* on disk | `readlink -f "${BASH_SOURCE[0]}"` then `dirname … ../lib/pool.sh` |
| B. `POOL_REAL_BIN` (real upstream CLI) | `pool_config_init` (`lib/pool.sh:147`) | where is the *real `agent-browser`* binary | `AGENT_BROWSER_REAL` env (default `$HOME/.local/bin/agent-browser`), canon via `realpath -m` |

The shim does NOT touch `POOL_REAL_BIN`. The `exec "$POOL_REAL_BIN"` (inside
`pool_wrapper_main`) consumes a path already canonicalized by config init. Keep them
separate: the shim resolves *itself* to find the lib; config resolves the *real binary*.

---

## 2. The symlink gotcha — WHY `readlink -f` before `dirname`

PRD §2.1 / §2.17: `install.sh` (M8.T1.S1, not yet built) symlinks
`~/scripts/agent-browser → <repo>/bin/agent-browser`, and `~/scripts` precedes
`~/.local/bin` on PATH. So in production the shim is **invoked via a symlink**.

If the shim did `source "$(dirname "$0")/../lib/pool.sh"`:
- `$0` (≈ `BASH_SOURCE[0]` for a top-level executed script) = `/home/dustin/scripts/agent-browser` (the **symlink**)
- `dirname "$0"` = `/home/dustin/scripts`
- `../lib/pool.sh` = `/home/dustin/lib/pool.sh` → **WRONG** (lib lives at `<repo>/lib/pool.sh`)
- `source` fails → `set -e` aborts → every `agent-browser` call dies.

The fix (the contract): canonicalize FIRST.
- `readlink -f "${BASH_SOURCE[0]}"` follows **every** symlink hop → `<repo>/bin/agent-browser`
- `dirname` → `<repo>/bin`
- `../lib/pool.sh` → `<repo>/lib/pool.sh` ✓

References: `readlink(1)` `-f, --canonicalize`
(https://man7.org/linux-man-pages/man1/readlink.1.html); Greg's Wiki BashFAQ 028
"how do I determine the location of my script?" (https://mywiki.wooledge.org/BashFAQ/028).

---

## 3. `BASH_SOURCE[0]` vs `$0` — use `BASH_SOURCE[0]`

For a **directly-executed** script `${BASH_SOURCE[0]} == $0`, so `BASH_SOURCE[0]` is
strictly safer and never worse (external-bash-wrapper §10). `$0` can be `bash`, an
absolute path, or a symlink depending on invocation; `BASH_SOURCE[0]` is always "the
file currently being read/executed". The contract uses `${BASH_SOURCE[0]}` — keep it.

`readlink -f` handles whatever string it gets (bare name, `./x`, absolute, symlinked) and
always returns an absolute canonical path, so the resolution is robust to how the shim is
invoked (by PATH, by absolute path, via symlink, relatively).

---

## 4. `readlink -f` vs `realpath` vs `realpath -m` — pick by existence requirement

| Tool | Requires final path to exist? | Notes |
|---|---|---|
| `readlink -f` | **yes** | canonicalizes; available on this host ✓ |
| `realpath` (GNU) | yes | same semantics as `readlink -f` ✓ |
| `realpath -m` | **no** (`--canonicalize-missing`) | used by `_pool_config_canon_path` / `pool_config_init` for *defaults that may not exist yet* |

The shim obviously **exists** (it is running), so plain `readlink -f` (the contract) is
correct and slightly stricter. Do NOT switch to `realpath -m` here (no need; the file
exists). Host-verified: `/usr/bin/readlink` (GNU coreutils, `-f, --canonicalize`),
`/usr/bin/realpath`, bash `5.3.15(1)-release`, ShellCheck `0.11.0` all present.

---

## 5. Sourcing is side-effect-free — safe to `source` unconditionally

`lib/pool.sh` is **meant to be sourced** (file header comment lines 1-16; "This file is
meant to be SOURCED ... NOT executed directly. It defines foundational utilities only.").
At source time the ONLY top-level statements that run are `set -euo pipefail` (line 18)
and function **definitions**. `pool_config_init` / `pool_state_init` / `pool_wrapper_main`
do NOT run at source time — `pool_wrapper_main` calls config+state as step "a" *inside*
itself. So `source` just defines functions; the shim then explicitly invokes
`pool_wrapper_main "$@"`. Confirmed by reading `lib/pool.sh:1-60` and the T3.S1 PRP.

The lib's top-of-file `set -euo pipefail` (line 18) propagates into the shim's shell on
`source`. The shim ALSO declares its own `set -euo pipefail` **before** sourcing (the
verbatim contract). This is:
- the rbenv/rustup shim convention (`set -e` at top of every shim),
- **idempotent** (setting strict mode twice is a no-op), and
- protects the shim's own pre-source statements (`readlink`/`dirname`) under strict mode.

Keep both. Do not delete the shim's own `set -euo pipefail`.

---

## 6. `SC2155` does NOT apply to top-level assignments

`SC2155` ("declare and assign separately to avoid masking return status") fires only for
`local`/`declare`/`readonly`/`typeset`. The contract's lines
`REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"` and `REAL_DIR="$(dirname "$REAL_SCRIPT")"`
are **plain top-level assignments** in a script (not inside a function, no `local`) →
SC2155 does not trigger. `shellcheck -s bash bin/agent-browser` is clean as written.
(Under `set -e`, if `readlink -f` failed the assignment would return non-zero and abort —
but `readlink -f` on the running script's own path cannot fail, so this is moot.)

---

## 7. `bin/.gitkeep` and `.gitignore` — no changes needed

- `bin/` currently holds only `.gitkeep` (the placeholder that keeps the empty dir in
  git). The shim is a NEW file **alongside** `.gitkeep`. **Leave `.gitkeep` in place** —
  the admin tool `bin/agent-browser-pool` (M7.T5.S1) is not built yet, so the dir would
  become empty again if `.gitkeep` were removed and only the wrapper existed... actually
  with the wrapper present the dir is non-empty, but `.gitkeep` is harmless and its
  removal is out of scope. Keep it.
- `.gitignore` (read in full) matches `*.log`, `.state/`, `.pi-subagents/`, `.env*`,
  `dist/`, `build/`, `node_modules/`, `venv/`, `__pycache__/`, OS files. **None** match
  `bin/agent-browser`. The versioned wrapper is NOT ignored. No `.gitignore` change is
  required — and `.gitignore` is orchestrator-owned (M10.T1.S2 verifies it); this task
  must NOT touch it.

---

## 8. Validation strategy — the symlink test is the distinguishing check

Standard checks (apply to any bash file): `bash -n`, `shellcheck -s bash`, `test -x`.

The check UNIQUE to this task: **invoke the shim THROUGH a symlink** in a temp dir
(simulating `~/scripts/agent-browser → <repo>/bin/agent-browser`), with
`AGENT_BROWSER_POOL_DISABLE=1` (passthrough safety valve) + a STUBBED `AGENT_BROWSER_REAL`
(captures argv to a file), and assert the stub received the ORIGINAL argv. If the shim
resolved its path wrong, `source …/lib/pool.sh` would fail → `set -e` abort → no
passthrough → test fails. This single test proves: shebang works, symlink resolution
works, sourcing works, `pool_wrapper_main` is reached, and the passthrough `exec` works —
all WITHOUT Chrome / a master profile / a real pi ancestor.

Secondary (direct-invocation, no symlink): `./bin/agent-browser --help` with DISABLE=1 +
stub → assert `--help` in stub output. Proves the non-symlink path too.

Driving happy-path (acquire→boot→ensure→exec) needs Chrome + master profile + a pi owner
and belongs to M9 / Level 3 smoke; NOT this task's unit bar.

---

## 9. The verbatim contract (fixed — do not deviate)

From the item description (authoritative) and confirmed identical in the T3.S1 PRP
"User Persona" + "Integration Points":

```bash
#!/usr/bin/env bash
set -euo pipefail
# Resolve real script dir (handles symlinks — PRD §2.17; scout-conventions §9)
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"
source "$REAL_DIR/../lib/pool.sh"
pool_wrapper_main "$@"
```

Then `chmod +x bin/agent-browser`. The shim runs NOTHING after `pool_wrapper_main "$@"`
(it is the LAST statement — `pool_wrapper_main` is terminal: every success path ends in
`exec`, every fatal path in `pool_die`→`exit 1`). The item's DOCS step ("the file itself
is self-documenting via comments") is satisfied by the inline `# Resolve real script dir
…` comment (plus an optional 2-3 line header describing what the shim is).

---

## Sources (re-used from T3.S1; no new external search needed)

- `readlink(1)` — `https://man7.org/linux-man-pages/man1/readlink.1.html` (`-f, --canonicalize`)
- GNU coreutils `realpath` — `https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html`
- Bash Reference Manual → `BASH_SOURCE` — `https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html`
- Bash Reference Manual → `.` (source) — `https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html`
- Greg's Wiki BashFAQ 028 (find a script's dir / resolve symlinks) — `https://mywiki.wooledge.org/BashFAQ/028`
- `lib/pool.sh` (lines 1-60 header + helpers; 3380-3391 EOF) — read in full on this host.
- `PRD.md` §2.1 (components), §2.17 (cutover & coexistence) — the symlink-on-PATH rationale.
- `plan/001_0f759fe2777c/P1M6T3S1/research/external-bash-wrapper.md` §3/§10/§12/§13 — the symlink-safety + two-resolutions analysis (read in full).
