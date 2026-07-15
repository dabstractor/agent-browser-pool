# Audit — the SHIPPED contract the rewritten README must mirror

First-party verification of every shipped artifact the README must describe. Every value
below is read DIRECTLY from the shipped code (not from memory/PRD). The implementer should
treat this as the source of truth for all tables/examples in the new README; re-verify with
the one-liners if anything is in doubt.

## 0. The model in one line (PRD §2.17 / O5 / O6)

`agent-browser-pool` is the **sole entry point**, invoked **explicitly**. There is **no PATH
shadowing** — the real `agent-browser` is never intercepted. The lane is selected by the
caller's `(pid, comm, starttime)` identity, never an argument. So the command
`agent-browser-pool <verb> <args>` is **identical on every lane**, every call.

This is the OPPOSITE of the OLD README's "transparent PATH-shadowing wrapper" model.

## 1. bin/agent-browser-pool — the SOLE entry point (shipped)

File: `bin/agent-browser-pool` (1366 bytes). Confirmed: `bin/` contains ONLY `agent-browser-pool`
(+ `.gitkeep`); the `bin/agent-browser` PATH-shadowing shim is DELETED (P2.M2.T2.S1).

Top-level dispatch (verbatim, after `pool_config_init` + `pool_state_init`):

```bash
cmd="${1:-status}"
case "$cmd" in
    status)            pool_admin_status ;;
    reap)              pool_admin_reap ;;
    release)           pool_admin_release "${2:-}" ;;
    doctor)            pool_admin_doctor ;;
    --help|-h|help)    pool_admin_help ;;
    *) pool_wrapper_main "$@" ;;
esac
```

Key consequences for the README:
- **Default command (no args) = `status`** (NOT help, NOT passthrough).
- **`--help` / `-h` / `help` are POOL VERBS** → `pool_admin_help` (they NEVER reach the real
  binary). The OLD README treated `--help`/`--version` as META passthrough — **WRONG now** for
  `--help`; only `--version` is still meta (it's not in the top-level case).
- **Everything else (any token that isn't a pool verb) → `pool_wrapper_main`** = a DRIVING
  command routed to the caller's own lane.

## 2. Command dispatch: admin verbs vs. meta vs. driving (verified from
   `pool_dispatch_classify` + the top-level case)

| Classification | Tokens | Behavior |
|---|---|---|
| **Pool verb** (entry-point `case`, runs pool fn, never touches the real binary) | `status`, `reap`, `release [<N>\|all]`, `doctor`, `help` / `--help` / `-h`, and bare invocation (default = `status`) | pool admin function |
| **META** (classified by `pool_dispatch_classify` inside `pool_wrapper_main` → **passthrough**: the real `agent-browser` runs unchanged, NO lane acquired) | `--version`; `skills`, `dashboard`, `plugin`, `mcp`; `session list`; a flags-only invocation with no subcommand (e.g. `agent-browser-pool --json`) | exec real binary, no lane |
| **DRIVING** (everything else — `open`, `connect`, `close`, `get`, `screenshot`, `click`, `type`, `eval`, `find`, AND any unrecognized token) | acquire/reuse MY lane (by identity) → exec the real `agent-browser` against it | lane lifecycle + exec |

CRITICAL nuance (the README must get this right, the OLD README got it wrong):
- `--help` / `-h` / `help` → **POOL VERB** (`pool_admin_help`), NOT meta. They never reach the
  real binary.
- `--version` → **META** (passthrough to real binary). It is NOT caught by the top-level case.

## 3. install.sh — the three benign things (shipped, verified)

File: `install.sh`. Header comment verbatim:

> Three benign things — NO PATH interception, so installing CANNOT disrupt running agents
> or other agent-browser users (lane selection is by caller identity, never a PATH rewrite):
>   1. symlinks bin/agent-browser-pool -> ~/.local/bin/agent-browser-pool (sole entry point)
>   2. pre-creates the pool state dir (lanes/ + acquire.lock)
>   3. runs `doctor` to verify the real agent-browser, Chrome, btrfs, and the master profile

Verified facts:
- `ln -sfnv -- "$REPO_DIR/bin/agent-browser-pool" "$HOME/.local/bin/agent-browser-pool"` — ONE
  symlink, to `~/.local/bin` (NOT `~/scripts`). `-sfnv`: symbolic/force/no-deref/verbose.
- `pool_state_init` pre-creates `lanes/` + `acquire.lock`.
- Runs `"$REPO_DIR/bin/agent-browser-pool" doctor` as a SUBPROCESS (rc insulated); prints a
  success banner even if doctor fails (symlink + state dir still created; tells user to re-run
  `agent-browser-pool doctor` after fixing).
- **`--force`/`-f` accepted but a NO-OP** (backward-compat; there is no confirmation to skip).
- **No YES confirmation gate. No cutover warning. No `~/scripts`. No PATH-ordering check.**
- Help (`./install.sh --help`) prints: "There is NO PATH interception and NO disruptive
  takeover — installing cannot disrupt running agents."
- **Uninstall: `rm -f ~/.local/bin/agent-browser-pool`** (ONE symlink; repo + state untouched).

## 4. Environment variables — verified defaults from `pool_config_init` (lib/pool.sh)

This is the authoritative env-var table for the README. Defaults read from the shipped
`pool_config_init`:

| Variable | Default (shipped) | Notes |
|---|---|---|
| `AGENT_BROWSER_POOL_STATE` | `$HOME/.local/state/agent-browser-pool` | state dir: `lanes/`, `acquire.lock`, `alerts.log`, `chrome-<N>.log`, `pool.log` |
| `AGENT_CHROME_MASTER` | **`${XDG_CONFIG_HOME:-~/.config}/google-chrome`** (your REAL Chrome user-data-dir) | CoW source; read-only to the pool; may be live/in-use |
| `AGENT_CHROME_EPHEMERAL_ROOT` | `~/.agent-chrome-profiles/active` | ephemeral lane dirs at `<root>/<N>/`; deleted on release |
| `AGENT_BROWSER_REAL` | `~/.local/bin/agent-browser` | the REAL Vercel CLI; called by ABSOLUTE PATH; stays upgradable |
| `AGENT_CHROME_BIN` | `google-chrome-stable` | bare name → `command -v`; a path → `-f -x` |
| `AGENT_CHROME_PORT_BASE` | `53420` | lowest pool TCP port |
| `AGENT_CHROME_PORT_RANGE` | `1000` | range = `[53420, 54420)` |
| `AGENT_BROWSER_POOL_WAIT` | `600` (10 min) | acquire block timeout (s) before force-reap + alert |
| `AGENT_CHROME_HEADLESS` | unset = **windowed** | truthy (`1`/`true`/`yes`/`on`) → `--headless=new` |
| `AGENT_CHROME_ALLOW_SLOW_COPY` | unset = **refuse** on non-btrfs | truthy → permit real ~4.8 GB copy per acquire |

**`AGENT_BROWSER_POOL_DISABLE` is GONE** — there is no such row, no such var, no such
behavior. (gap_analysis §1a/§1b/§6 removed it from `pool_config_init`, `pool_wrapper_main`,
and configuration.md.) The README MUST NOT contain it.

Test-only hooks (mention as "not for users"): `AGENT_BROWSER_POOL_OWNER_PID`,
`AGENT_BROWSER_POOL_OWNER_STARTTIME` (simulate distinct owners without a real `pi`).

## 5. `pool_admin_help` output (verbatim, the canonical command/env reference)

`bin/agent-browser-pool help` prints (the README's Commands + Configuration sections should
mirror this exactly):

```
agent-browser-pool — the sole entry point for browser pool verbs AND driving commands.

Usage: agent-browser-pool <command> [args]

If no command is given, 'status' is assumed.

Commands:
  status                  Print a read-only table of all active lanes:
                          lane, port, session, owner pid+cwd, chrome pid, age, state.
  reap                    Tear down lanes whose owning process has died:
                          kill Chrome, delete the ephemeral profile dir, remove the lease.
  release [<N>|all]       Explicitly tear down one lane by number, or every lane.
                          Use 'release all' to clear the whole pool.
  doctor                  Diagnose the pool: verify dependencies, the real binary,
                          the filesystem (btrfs), and the master profile; reconcile
                          leases against live Chromes and ephemeral dirs; report leaks.
                          Exits 1 if any check fails, 0 otherwise.
  help                    Show this help. Aliases: --help, -h.

Driving commands:
  Any token that is not a command above is treated as a DRIVING command and is
  routed to your own locked lane (the lane is chosen by your identity, never by
  an argument). The real agent-browser runs against your lane:
    agent-browser-pool open <url>    open a URL in your lane
    agent-browser-pool screenshot     capture a screenshot
    agent-browser-pool close         disconnect your lane daemon (lane and profile survive for reuse)
  Every other real agent-browser verb works the same way (get cdp-url, click,
  type, eval, find, ...). You never pass a lane, port, or session.

Configuration (environment variables; all optional):
  AGENT_BROWSER_POOL_STATE        state dir (lease store + logs)
  AGENT_CHROME_MASTER             CoW source profile (default: ~/.config/google-chrome — your real Chrome user-data-dir)
  AGENT_CHROME_EPHEMERAL_ROOT     ephemeral lane dir root
  AGENT_BROWSER_REAL              the real agent-browser binary (run for driving commands)
  AGENT_CHROME_BIN                Chrome binary (default: google-chrome-stable)
  AGENT_CHROME_PORT_BASE          lowest pool TCP port (default: 53420)
  AGENT_CHROME_PORT_RANGE         number of ports in the pool (default: 1000)
  AGENT_BROWSER_POOL_WAIT         acquire block timeout, seconds (default: 600)
  AGENT_CHROME_HEADLESS           launch Chrome headless if set (1/true/yes/on)
  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)
```

## 6. `pool_admin_doctor` section labels (verbatim) — for the README's doctor subsection

The shipped `doctor` prints these sections IN ORDER (printf labels verified):

```
[dependencies]   <dep> OK | MISSING   (flock, setsid, pgrep, pkill, cp, curl, jq, chrome)
                 notify-send OK | MISSING (optional)
[binary]         <POOL_REAL_BIN> OK | FAIL (missing or not executable)
[filesystem]     <POOL_EPHEMERAL_ROOT> OK (btrfs) | WARN (<fstype>; slow-copy allowed) | FAIL (<fstype>; not btrfs)
[master]         <POOL_MASTER_DIR> OK | FAIL (missing or empty)   ← label is '[master]'; NOW = real Chrome dir
[lanes]          (no active leases) | lane <N> OK | lane <N> WARN (<findings>) | lane <N> WARN (PROVISIONAL; incomplete acquire)
[dirs]           (no ephemeral dirs) | <dir> WARN (ORPHAN DIR: no lease) | (<N> dir(s), all leased)
[summary]        OK=N  WARN=N  FAIL=N   +  "Healthy." | "Problems found."
```

NOTE for the README: the `[master]` section LABEL is unchanged (still prints `[master]`), but
what it checks has changed — it now verifies `$AGENT_CHROME_MASTER` (default your real
`~/.config/google-chrome`) exists + is non-empty, NOT a `master-profile` template. Describe it
accurately ("the source/master profile"), do NOT resurrect the `master-profile` path.

## 7. `pool_admin_status` table (unchanged format) — for the README's status subsection

```
LANE   PORT SESSION           OWNER_PID OWNER_CWD                CHROME_PID   AGE STATE
   1  53420 abpool-1             836725 ~/projects/my-agent           104816 2m13s live
```

Empty pool prints `No active lanes.` STATE ∈ {`live`, `disconnected`, `STALE`} (STALE → fields
show `?`). This format is UNCHANGED by the pivot (only the model around it changed).

## 8. No-pi-ancestor = FAIL-FAST (not passthrough) — CRITICAL correction

The OLD README said a human in a terminal with no `pi` ancestor gets "passthrough" to the real
`agent-browser`. **This is WRONG now.** `pool_wrapper_main` step d (gap_analysis §1b Change 2):

```bash
pool_owner_resolve
if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
    pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
             "For raw browser use without pooling, call 'agent-browser' directly."
fi
```

So: a DRIVING command with no `pi` ancestor **fails fast** (non-zero exit, actionable message).
The README's Usage + Troubleshooting must say this. (Pool verbs `status`/`doctor`/`reap`/
`release`/`help` never need an owner and work from any shell — the top-level case runs them
before owner resolution. META commands also never reach owner resolution — they passthrough
inside `pool_wrapper_main` before the no-pi check.)

## 9. Obsolete terms that MUST reach ZERO in the rewritten README

Verified current hit counts in README.md (must all → 0 in the rewrite):

| Phrase | current hits | why obsolete |
|---|---|---|
| `PATH-shadow` | 3 | no PATH shadowing exists (O5) |
| `transparent wrapper` | 1 | not a wrapper; explicit tool |
| `transparent PATH` | 2 | ditto |
| `cutover` | 8 | no cutover (benign install) |
| `~/scripts` | 2 | install target is `~/.local/bin`, not `~/scripts` |
| `AGENT_BROWSER_POOL_DISABLE` | 7 | var removed entirely (gap_analysis §1a/§6) |
| `safety valve` | 3 | the DISABLE mechanism it described is gone |
| `master-profile` | 5 | source is now the REAL Chrome dir, not a `master-profile` template |
| `all-or-nothing` | 1 | cutover language; gone |
| `passes through to the real` (in the "human terminal → passthrough" sense) | 1 | no-pi-ancestor is now fail-fast |

WORDS that are FINE to keep (do NOT blanket-zero these — they have legitimate uses):
- `wrapper` / `passthrough` — `pool_wrapper_main` is a real internal symbol; META commands
  genuinely "pass through" to the real binary. Use them where accurate (META), never to
  describe the overall tool as "a transparent wrapper."
- `transparent` — fine as ordinary English ("transparent logging") but NOT to describe the
  invocation model. The gate is the PHRASE "transparent wrapper" / "transparent PATH", not the
  word "transparent."

## 10. The skill tree (the README's repo-layout + usage should point here)

`.agents/skills/agent-browser-pool/` (project-scoped, shipped, rewritten in P2.M4):
- `SKILL.md` — procedural "how to use your lane" guide (the agent contract).
- `references/configuration.md` — env-var table, dispatch, lifecycle, troubleshooting matrix.
- `README.md` — skill overview + install (global symlink).

The README's Usage section should tell agents/humans that the skill is the procedural doc, and
the repo-layout block must include `.agents/skills/agent-browser-pool/`.

## 11. Files the README must NOT reference as if they exist

- `bin/agent-browser` — DELETED (P2.M2.T2.S1). The README's repo-layout must show `bin/` with
  ONLY `agent-browser-pool` (+ `.gitkeep`). Any "test the wrapper by absolute path
  `<repo>/bin/agent-browser open …`" instruction is INVALID.
- `~/.agent-chrome-profiles/master-profile/` — no such static template. The source is the real
  Chrome dir (or whatever `$AGENT_CHROME_MASTER` points at).
- `~/scripts/agent-browser` — no such symlink; install goes to `~/.local/bin`.

## 12. Validation approach (no test framework for markdown)

There is no pytest/shellcheck for README.md. Validation is DETERMINISTIC grep-based content +
consistency gates (Level 1 in the PRP). These are appropriate and authoritative for a
docs-only task: (a) obsolete-phrase removals → 0; (b) required-model phrases present; (c)
cross-check the env-var table + command list against the shipped `pool_admin_help` output; (d)
markdown sanity (heading depth, no broken anchors, code fences balanced). No Chrome, no
daemons, no suite run — AGENTS.md §1/§6 (static only).
