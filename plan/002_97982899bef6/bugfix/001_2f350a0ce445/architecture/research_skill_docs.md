# Skill Docs Research — meta commands, passthrough, and the dispatch model

> Static analysis only. No source files were modified. This document catalogs every place in
> the `agent-browser-pool` skill docs (and the user-facing README) that references **meta
> commands**, **passthrough**, or the **dispatch model** (classify → pool-verb / META / driving),
> with exact line ranges.

## Scope notes

- The skill lives at `.agents/skills/agent-browser-pool/` and contains exactly **three** `.md`
  files: `SKILL.md`, `README.md`, `references/configuration.md` (all read in full).
- **There is no `docs/` directory** in this repo (`ls -d docs` → not found). The task's
  "grep `docs/*.md`" therefore has no target; the user-facing documentation is the **root
  `README.md`**, which was grepped instead. Results below cover `README.md` + the three skill
  `.md` files.
- Grep terms: `meta`, `passthrough`, `dispatch`, `classify` (case-insensitive). META also
  appears in uppercase (`META`) in `README.md`; "meta" appears lowercase in the skill files.

## Files Retrieved

1. `.agents/skills/agent-browser-pool/SKILL.md` (lines 1-146, full file) — procedural agent
   guide; contains the "Which commands trigger a lane" subsection (meta vs. driving) and a
   pointer to the full dispatch table.
2. `.agents/skills/agent-browser-pool/references/configuration.md` (lines 1-159, full file) —
   reference material; contains the canonical **"Command dispatch: meta vs. driving"** section,
   the **"Meta commands (passthrough)"** list, and the **"Driving commands"** list.
3. `.agents/skills/agent-browser-pool/README.md` (lines 1-44, full file) — skill overview;
   lists the dispatch table reference but contains no meta/passthrough specifics itself.
4. `README.md` (lines 1-379, full file) — root user docs; the **most detailed** dispatch
   description, with a Classification-detail blockquote and a "How it works" classify diagram.

## Exact line ranges: sections referencing meta / passthrough / dispatch model

### `.agents/skills/agent-browser-pool/SKILL.md`

| Lines | Section / content |
|---|---|
| **55-65** | `### Which commands trigger a lane` — defines Driving vs. **meta** commands. The meta clause is specifically at **lines 61-63**: "A small set of **meta** commands pass straight through to the real `agent-browser` WITHOUT acquiring a lane … `skills`, `--version`, `session list`, `dashboard`, `plugin`, and `mcp`." Distinguishes pool verbs (`status`/`reap`/`release`/`doctor`/`help`) from meta at **line 64**. Pointer to the full dispatch table at **line 65**. |
| **143-145** | `## 5. Reference` — points reader to `references/configuration.md` for "the complete **meta-vs-driving dispatch** classification". (Reference pointer only; no dispatch logic here.) |

### `.agents/skills/agent-browser-pool/references/configuration.md` (CANONICAL)

| Lines | Section / content |
|---|---|
| **44-54** | `## Command dispatch: meta vs. driving` — header + the ordered 3-step **classify** decision from `pool_wrapper_main` (first match wins): **(1)** meta → **passthrough**; **(2)** no `pi` ancestor → **fail-fast** `pool_die`; **(3)** otherwise → acquire/find lane. Step 1 (meta→passthrough) is at **line 49**. |
| **55-67** | `### Meta commands (passthrough — never acquire a lane)` — the canonical list of tokens that reach the real `agent-browser` unchanged: `--version` (57); `skills`, `dashboard`, `plugin`, `mcp` (58); `session list` (59); flags-only invocation with no subcommand, e.g. `agent-browser-pool --json` (60). The **critical caveat** is at **lines 62-67**: `--help`/`-h`/`help` are **pool verbs**, NOT meta-passthrough (entry-point dispatcher `bin/agent-browser-pool` catches them → `pool_admin_help`); a bare `agent-browser-pool` defaults to `status`. |
| **69-76** | `### Driving commands (use your lane)` — "Everything else", incl. `open`/`connect`/`close`, `get`, `screenshot`, scrape/automate, and **any unrecognized command** (defaults to driving). |
| **8** | Intro paragraph names the implementing functions: `pool_dispatch_classify`, `pool_wrapper_main`, `pool_admin_*` (the code symbols the docs claim to mirror). |

### `.agents/skills/agent-browser-pool/README.md`

| Lines | Section / content |
|---|---|
| **23** | "What it covers" → lists `references/configuration.md` as "env-var table, **command dispatch**, lifecycle, troubleshooting matrix". (Pointer only; no meta/passthrough content in this file.) |

### `README.md` (root user docs)

| Lines | Section / content |
|---|---|
| **94-96** | `## Usage (for agents)` blockquote — "Pool verbs (`status` / `doctor` / `reap` / `release` / `help`) and **META commands** work from any shell." (Line 95.) |
| **119-141** | `### Driving commands (agent — routed to your own lane)`. The meta/passthrough content is the **Classification detail** blockquote at **lines 135-141**: tokens that are **META** and "pass through to the real `agent-browser` unchanged, acquiring no lane" — `--version`; `skills`, `dashboard`, `plugin`, `mcp`; `session list`; flags-only (`agent-browser-pool --json`). Repeats the caveat that `--help`/`-h`/`help` are pool verbs and bare invocation defaults to `status`. |
| **253-294** | `## How it works` — the full dispatch/classify section. Key lines: **256** "passes a **META** command through to the real binary"; the **classify diagram block at lines 258-270** with the META branch explicitly at **lines 263-266** ("`META (--version, skills, dashboard, plugin, mcp, session list, flags-only)? → passthrough to the real binary (no lane)`") and the FAIL-FAST note at **line 266**; the numbered **`pool_wrapper_main` ordering list at lines 272-281**, where **step 2 (line 277)** is "classify — pool verb? **META** command? → handled above (no lane)". |
| **313-317** | `## Troubleshooting` → `### Driving command errored: "requires a pi ancestor"` — closes with "Pool verbs (`status`, `doctor`, `reap`, `release`, `help`) and **META commands** work from any shell." (Line 317.) |

## Key content: the canonical dispatch contract

All three files describe the same 3-way classification (the authoritative version is
`references/configuration.md` lines 44-76). The decision order, first-match-wins, from
`pool_wrapper_main`:

1. **META command → passthrough** (no lane; real `agent-browser` runs unchanged, works with no
   `pi` ancestor). Tokens: `--version`; `skills`, `dashboard`, `plugin`, `mcp`; `session list`;
   a flags-only invocation with no subcommand (`agent-browser-pool --json`).
2. **No `pi` ancestor → fail-fast** (`pool_die`): driving commands require a `pi` owner.
3. **Otherwise → DRIVING**: resolve owning `pi` PID+starttime, acquire/find the lane, strip
   `--session`, force `AGENT_BROWSER_SESSION=abpool-<N>`, `exec` the real binary. **Any
   unrecognized command falls here** (defaults to driving).

**Critical, easy-to-get-wrong caveat (configuration.md 62-67; README.md 138-141):**
`--help`, `-h`, and `help` are **NOT meta-passthrough** — they are **pool verbs**, caught first
by the entry-point dispatcher (`bin/agent-browser-pool`) which prints the pool's own help
(`pool_admin_help`), so they never reach the real binary. A bare `agent-browser-pool` (no args)
is also a pool verb → defaults to `status`.

**META set consistency across files:** every file lists the identical meta token set
(`--version`, `skills`, `dashboard`, `plugin`, `mcp`, `session list`, flags-only). The list is
consistent; the only cross-file variation is wording (lowercase "meta" in the skill files,
uppercase "META" in `README.md`).

## Architecture

The docs present a layered dispatch model that the code (`lib/pool.sh`) implements:

```
bin/agent-browser-pool  (entry point; catches help/--help/-h/default-status first)
        │
        ▼
lib/pool.sh :: pool_wrapper_main  →  pool_dispatch_classify
   ├─ pool verb?        (status/reap/release/doctor/help)  → pool_admin_*   (no lane)
   ├─ META command?     (--version/skills/dashboard/plugin/mcp/session list/flags-only)
   │                                                       → exec real binary (no lane)
   └─ driving           → resolve pi owner → acquire lane → exec real binary (with lane)
```

- **Two distinct "no lane" paths**, which the docs are careful to distinguish: pool verbs
  (handled by `pool_admin_*` in-process) vs. META passthrough (the real `agent-browser` runs
  unchanged). `help`/`--help`/`-h`/bare-default belong to the *pool verb* path, NOT passthrough.
- The skill docs (`SKILL.md` §1 "Which commands trigger a lane" + the Reference pointer) are the
  agent-facing summary; `configuration.md` is the exhaustive reference; `README.md` "How it
  works" + "Classification detail" is the user-facing version. All three are mutually consistent.

## Start Here

Open **`.agents/skills/agent-browser-pool/references/configuration.md` lines 44-76** — that is
the canonical, self-described source of truth for the meta/driving dispatch table and the exact
function names (`pool_dispatch_classify`, `pool_wrapper_main`) the docs claim to mirror in
`lib/pool.sh`. Any verification of "does the code match the docs?" starts there, then confirms
against `README.md` lines 253-294 (How it works) and lines 135-141 (Classification detail).

## Open questions / risks

- The docs name code symbols (`pool_dispatch_classify`, `pool_wrapper_main`, `pool_admin_*`) as
  the implementation of this classification, but the docs themselves are prose; whether the live
  `lib/pool.sh` actually classifies in this exact order (and treats `help`/flags-only the way
  the docs say) was NOT verified here — that requires reading `lib/pool.sh` (out of scope for
  this docs-only scout).
- The meta token list is identical across all three files (no drift detected), so a change to
  the meta set would require coordinated edits in `configuration.md`, `SKILL.md`, and `README.md`.
