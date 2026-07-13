# Research §1 — agent-browser command taxonomy & flag semantics

**Source of truth:** the REAL binary at `/home/dustin/.local/bin/agent-browser`
v0.28.0, queried this session via `agent-browser --help` / `--version`. This file is
the evidence base for the META/DRIVING classification in `pool_dispatch_classify`.

---

## 1. The two AUTHORITATIVE command lists

### 1.1 DRIVING — operate on a browser, route to the agent's lane
(PRD §2.4 step 0; `external_deps.md` §1.1; verified against `--help` "Core Commands",
"Navigation", "Get Info", "Check State", "Find Elements")

```
open, click, dblclick, type, fill, press, keyboard, hover, focus,
check, uncheck, select, drag, upload, download, scroll, scrollintoview,
wait, screenshot, pdf, snapshot, eval, connect, close, session,
back, forward, reload, get, is, find
```

> **Reconciliation note (item contract vs external_deps):** the ITEM CONTRACT step (c)
> lists 31 commands and OMITS `dblclick` (which `external_deps.md` §1.1 DOES include).
> This is HARMLESS: because the contract's step (d) defaults UNRECOGNIZED → 'driving',
> `dblclick` classifies as 'driving' either way. The classification code therefore does
> NOT need to enumerate the DRIVING set at all — see `dispatch-logic.md` §2.

### 1.2 META / passthrough — do NOT drive a browser, exec real binary unchanged
(item contract step (b); `external_deps.md` §1.2)

```
skills, dashboard, plugin, mcp, session list, --help, -h, --version
```

`session list` is a TWO-WORD command → needs a 2-token lookahead (see §3 below).
Bare `session` (or `session <other>`) is in the DRIVING set → 'driving'.

---

## 2. Flag semantics (verified from `agent-browser --help` "Options" section)

| flag | form | value? | dispatch handling |
|---|---|---|---|
| `--session <name>` | space-separated | **YES — consumes the NEXT token** | skip flag + value (shift 2) |
| `--session=<name>` | equals form | value attached | generic `--*` → skip 1 (value already attached) |
| `--json` | boolean | no | skip 1 |
| `--help` / `-h` | boolean | no | **short-circuit → 'meta'** (always a help request) |
| `--version` | boolean | no | **short-circuit → 'meta'** |
| any other `--foo` | various | — | skip 1 (generic long flag) |
| any other `-x` (e.g. `-i -c -d -p`) | short | — | skip 1 (generic short flag) |

### Verified facts (this session)
- `agent-browser --version` → `agent-browser 0.28.0` (exit 0). Confirms `--version` is a
  real global flag.
- `--session <name>` is documented: `--session <name>  Isolated session (or
  AGENT_BROWSER_SESSION env)`. Space form is THE form the skill teaches
  (`agent-browser --session <X> …`, PRD §2.4 §2.15).
- `--json` is a boolean: `--json   JSON output` (no value). Appears as a per-subcommand
  option too (e.g. `react renders stop [--json]`, `vitals [url] [--json]`).
- `-h` is the short form of `--help` (standard; help text uses `-i, -c, -d, -s` style for
  OTHER short flags, so `-h` is unambiguously help).

### Why --help / -h / --version SHORT-CIRCUIT (not "skip then nothing")
The contract step (a) lists `--help, -h, --version` among "flags to skip", BUT step (b)
lists them as META commands. The ONLY interpretation satisfying BOTH is: when any of these
is encountered during the left→right scan, **return 'meta' immediately**. Concretely:
- `agent-browser --help` → 'meta' ✓ (step b)
- `agent-browser --json --help` → 'meta' ✓ (skip --json, then --help → meta)
- `agent-browser --session foo --help` → 'meta' ✓

This is also semantically correct for the real binary: `--help`/`-h`/`--version` are
ALWAYS help/version requests regardless of position, so passthrough (meta) is safe and
avoids a needless lane acquisition.

---

## 3. Commands NOT in either list → default to 'driving' (contract step d)

`agent-browser --help` reveals MANY commands absent from the contract's two lists.
Per contract step (d) ALL of them classify as 'driving':

**Genuinely browser-driving (default-driving is CORRECT, just unenumerated):**
`dblclick, mouse, set, network, cookies, storage, tab, diff, trace, profiler, record,
console, errors, highlight, inspect, clipboard, stream, react, vitals, pushstate,
removeinitscript, batch, confirm, deny`

**Genuinely META-like but NOT in the contract's META set** (default-driving is WASTEFUL
but not broken — the wrapper acquires a lane then execs; the binary handles these without
needing the browser, so the forced `AGENT_BROWSER_SESSION` is harmless):
`install, upgrade, doctor, profiles, chat, auth`

> **Known limitation (documented, NOT a blocker):** `install/upgrade/doctor/profiles`
> will route to 'driving' and thus briefly acquire a lane before the real binary runs them.
> They still WORK (the binary ignores the session for non-browser ops). This is the
> contract's deliberate "default-to-driving" tradeoff (simple + safe). The contract's META
> set is FIXED for this task; do not extend it here. (Future enhancement, out of scope.)

---

## 4. Edge-case invocations (decisions, all per-contract)

| invocation | first non-flag token | classification | why |
|---|---|---|---|
| `agent-browser` (no args) | (none) | **driving** | no command = unrecognized → default driving (step d). Real binary shows help; rare (agents always pass a command). |
| `agent-browser --help` | (flag) | **meta** | --help short-circuit |
| `agent-browser --json` (only) | (none after skip) | **driving** | no command → default driving |
| `agent-browser --session` (no value) | (none) | **driving** | --session consumes itself; no command → driving |
| `agent-browser skills` | skills | **meta** | META set |
| `agent-browser skills get core` | skills | **meta** | META set (subcommand ignored) |
| `agent-browser session list` | session (+list) | **meta** | 2-token lookahead |
| `agent-browser session` | session | **driving** | session ∈ DRIVING; next ≠ list |
| `agent-browser session foo` | session (+foo) | **driving** | next ≠ list → driving |
| `agent-browser open https://x` | open | **driving** | DRIVING (covered by default) |
| `agent-browser --json --session s1 get url` | get | **driving** | flags skipped, get=command |
| `agent-browser --session=s1 open url` | open | **driving** | equals-form --session skipped as 1 token |
| `agent-browser connect 9222` | connect | **driving** | DRIVING (special-handling is M6.T1.S2, NOT this task) |
| `agent-browser close --all` | close | **driving** | DRIVING (close--all interception is M6.T1.S2) |
| `agent-browser install` | install | **driving** | unrecognized → default (see §3) |
