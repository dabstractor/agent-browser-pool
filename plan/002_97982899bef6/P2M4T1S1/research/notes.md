# Research Notes — P2.M4.T1.S1: Complete rewrite of SKILL.md (agent-browser-pool as sole command)

## 0. Deliverable

**One file rewritten in place**: `.agents/skills/agent-browser-pool/SKILL.md` (~125 lines → ~115-125
lines). Mode A (user-facing contract doc): the SKILL.md IS the documentation artifact. No separate
docs subtask for this file. The PRP supplies the **exact target SKILL.md verbatim** (a complete
rewrite ⇒ the artifact is the spec, mirroring the P2.M3.T1.S1 install.sh PRP precedent).

## 1. Current SKILL.md — structure + what each part becomes

File: `.agents/skills/agent-browser-pool/SKILL.md` (read in full). Structure:

| Current section / element | Status in rewrite | Why |
|---|---|---|
| Frontmatter `description` (says "transparent pool wrapper", "`agent-browser`") | **REPLACE** verbatim | Item LOGIC (a): exact new string. |
| Title `# Agent Browser Pool — how to use your Chrome lane` | **KEEP** (item LOGIC b) | Identical title is mandated. |
| Opening paragraph ("On this host `agent-browser` is a transparent PATH-shadowing wrapper...") | **REPLACE** | Item LOGIC (c): invariant command, NOT a transparent wrapper; add "command never names a lane". |
| `## 1. Get + connect` + `agent-browser open https://example.com` | **REWRITE** all examples → `agent-browser-pool` | Item LOGIC (d). |
| `### Connection rules` | **REWRITE** examples (connect / --session) → `agent-browser-pool` | Item LOGIC (e). Semantics unchanged (arg stripped / overridden). |
| `### Which commands trigger a lane` (meta list incl. `--help`/`-h`) | **REWRITE** | Item LOGIC (f): meta = `skills, --version, session list, dashboard, plugin, mcp`. REMOVE `--help`/`-h` (now pool verbs), REMOVE DISABLE mention, REMOVE "no pi ancestor → passthrough". |
| `## 2. Tear down` (`agent-browser close`) | **REWRITE** → `agent-browser-pool close` | Item LOGIC (g). `close` = disconnect-only; release auto on pi exit. |
| `## 3. Inspect your lane` (status/doctor) | **FOLD into §3 Safety** (keep content; read-only + safe) | Item LOGIC (h): §3 = "Safety". status/doctor are read-only & safe; natural fit. |
| `## 4. Common pitfalls` (1st bullet = passthrough/DISABLE) | **REPLACE 1st bullet** | Item LOGIC (i/f): REMOVE DISABLE + passthrough. New 1st bullet = "driving outside `pi` fails fast". |
| `## 5. Reference` → `references/configuration.md` | **KEEP** | Still the detail reference (P2.M4.T2.S1 updates it in parallel). |

## 2. Behavior contracts (verified against the LIVE post-P2.M1/P2.M2 tree)

Confirmed by reading `lib/pool.sh` + `bin/agent-browser-pool`:

- **Dispatch** (`bin/agent-browser-pool` lines 19-27): `cmd="${1:-status}"`; pool verbs
  `status|reap|release|doctor|--help|-h|help` → pool_admin_*; `*) → pool_wrapper_main "$@"`.
  Bare invocation (no args) → **status** (NOT help).
- **Meta vs driving** (`pool_dispatch_classify`, lib/pool.sh:3173): meta = `--help`/`-h`/`--version`
  (any flag position), `skills`/`dashboard`/`plugin`/`mcp`, `session list`, or a flags-only/no-command
  invocation. Everything else (incl. unrecognized) = `driving`. **NOTE**: `--help`/`-h` never reach
  classify — they're caught as the pool verb `help` in the dispatcher. So in the new model the META
  passthrough set that actually reaches the real binary = `--version`, `skills`, `session list`,
  `dashboard`, `plugin`, `mcp`, and a bare flags-only call. (Item LOGIC f's list = exactly these.)
- **No-pi-ancestor** (`pool_wrapper_main` step d): DRIVING → `pool_die` exit 1:
  `"agent-browser-pool: driving commands require a pi ancestor (owning pi process). For raw browser
  use without pooling, call 'agent-browser' directly."` Meta commands short-circuit at step c
  (classify) BEFORE step d, so they still work with no pi ancestor.
- **connect arg** (`pool_normalize_connect`, lib/pool.sh:3357): if cmd==`connect`, the single
  `<port|url>` positional following it is stripped (lane is already connected). Bare `connect` =
  no-op success.
- **--session** (`pool_strip_session_args` 3461 + `pool_force_session` 3527): any `--session <X>`
  (or `--session=<X>`) is stripped; `AGENT_BROWSER_SESSION=abpool-<N>` forced.
- **close --all** (`pool_normalize_close`, lib/pool.sh:3284): every standalone `--all` stripped IFF
  cmd==`close` (sets `POOL_CLOSE_ALL_SEEN`); then `--session abpool-<N>` forced ⇒ real exec is
  `close --session abpool-<N>` → kills ONLY my lane's daemon. Never a peer's session.
- **Master default** (`pool_config_init`, lib/pool.sh:154 + system_context): `POOL_MASTER_DIR`
  defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome` (the real Chrome user-data-dir),
  NOT the old `master-profile`. The skill's "source profile (your real `~/.config/google-chrome`)"
  claim is ACCURATE.
- **AGENT_BROWSER_POOL_DISABLE**: `grep` in lib/pool.sh returns NOTHING — fully removed (P2.M1.T3.S1
  complete). `pool_admin_help` (lib/pool.sh:4592) already has the new "Driving commands" section +
  new env-var list, no DISABLE. The skill must contain ZERO DISABLE references.

## 3. The removals (grep targets the PRP asserts — all must be ABSENT in the new SKILL.md)

- `transparent` / `PATH-shadowing` / `shadowing` / "transparent wrapper"
- `AGENT_BROWSER_POOL_DISABLE` / `POOL_DISABLE`
- `passthrough` (the "human terminal passthrough" concept) — NOTE: the word "passthrough" appears
  in the §1f meta description in the current skill ("pass straight through"); the rewrite may keep
  the PHRASE "pass straight through" for meta commands (that behavior is real + unchanged), but must
  NOT describe no-pi-ancestor as passthrough. The safe grep target is the LITERAL old strings:
  `AGENT_BROWSER_POOL_DISABLE`, `transparent`, `PATH-shadowing`, "human terminal",
  "no pi ancestor → passthrough", and `agent-browser open` (the canonical wrong example).
- Any bare `agent-browser <verb>` example without the `-pool` suffix.

## 4. The additions (grep targets — all must be PRESENT)

- Frontmatter description = exact mandated string (ends "...open pages, connect, close, scrape, or automate.").
- `agent-browser-pool open https://example.com` (the canonical correct example).
- "The command never names a lane." (the headline invariant).
- `agent-browser-pool connect <port>`, `agent-browser-pool close`, `agent-browser-pool close --all`,
  `agent-browser-pool --session`, `agent-browser-pool status`, `agent-browser-pool doctor`.
- "fails fast" / "require a pi ancestor" (the no-pi-ancestor behavior, NOT passthrough).
- Meta list: `skills`, `--version`, `session list`, `dashboard`, `plugin`, `mcp`.
- Reference to `references/configuration.md`.

## 5. Dependencies / disjointness / parallel safety

- **P2.M3.T1.S1** (install.sh, parallel): DISJOINT file. install.sh's success message prints
  `agent-browser-pool open <url>` examples — CONSISTENT with this skill. No conflict.
- **P2.M4.T2.S1** (configuration.md, planned sibling): this skill's §5 points to it. Both are being
  updated to the new model in parallel; the skill must not DUPLICATE configuration.md-owned content
  (full env table, full dispatch table, troubleshooting matrix) — it only references it. The skill's
  few inline claims (master default, close/connect semantics) are verified against lib/pool.sh
  directly, so they stay correct regardless of configuration.md's transient state.
- **P2.M6.T1.S1** (README.md): the README will mirror the skill's command model. DISJOINT file.
- This item touches ONLY `.agents/skills/agent-browser-pool/SKILL.md`. lib/pool.sh, bin/*,
  references/configuration.md, README.md, test/* are all untouched.

## 6. Validation approach (AGENTS.md §1: NO execution)

A markdown file has no runtime. Validation is STATIC + structural:
- grep assertions for the removals (§3) and additions (§4).
- frontmatter sanity (name + description present; description = exact string).
- the `references/configuration.md` link target EXISTS in the tree.
- section headers present (§1 Get + connect, §2 Tear down, §3 Safety, §4 Common pitfalls, §5 Reference).
- `git status --short` shows ONLY `.agents/skills/agent-browser-pool/SKILL.md`.
- NO Chrome, NO daemons, NO test suite. A doc edit cannot hang the sandbox, but we still never boot
  anything (AGENTS.md §1/§6).
