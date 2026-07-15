# Research notes — P2.M4.T3.S1: Update skill README.md for new model

**Item**: P2.M4.T3.S1 (0.5 points) — Update `.agents/skills/agent-browser-pool/README.md`
**Milestone**: P2.M4 (Skill & Reference Documentation)
**Contract**: `plan/002_97982899bef6/architecture/gap_analysis.md` §7
**Scope**: ONE file edited in place (39-line README → ~40-line README). No new files. No deletions.

---

## 1. The contract (verbatim)

gap_analysis.md §7:
> ## 7. Skill README.md — UPDATE (~50 lines)
> - Remove "transparent wrapper" language
> - Remove `AGENT_BROWSER_POOL_DISABLE` pitfall mention

Item description (the precise edit map):
> 3. LOGIC: In .agents/skills/agent-browser-pool/README.md:
>    a. Update the description: remove 'transparent Chrome-profile wrapper', use
>       'agent-browser-pool Chrome-profile pool' or similar.
>    b. Update 'What it covers': change 'first driving agent-browser command' to
>       'first driving agent-browser-pool command'.
>    c. Update pitfalls: remove AGENT_BROWSER_POOL_DISABLE reference. Change
>       'no pi ancestor → passthrough' to 'no pi ancestor → fails fast (use
>       agent-browser directly for raw access)'.
>    d. Keep the Files section and Installation section largely unchanged (they
>       reference the skill directory structure, not the command).

---

## 2. Current README.md — exact text + line numbers (39 lines)

```
 1: # agent-browser-pool (Agent Skill)
 2:
 3: An [Agent Skill](https://github.com/earendil-works/pi-coding-agent) that teaches AI agents
 4: how to use the [`agent-browser-pool`](../..) transparent Chrome-profile wrapper correctly:
 5: how their dedicated lane is acquired and connected, how it's reused across calls, and how
 6: to tear it down.
 7:
 8: ## What it covers
 9:
10: - **Acquire + connect:** the lane is created automatically on the first driving
11:   `agent-browser` command under `pi`; agents don't pass ports or `--session` (the pool owns
12:   them).
13: - **Teardown:** `close` is disconnect-only; the real release happens automatically when the
14:   owning `pi` process exits. Agents should avoid `agent-browser-pool release`/`reap`
15:   (operator tools; `release <N>` is not owner-scoped).
16: - **Pitfalls:** passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`), pool
17:   exhaustion hangs, ephemeral profiles, and why to never launch Chrome directly.
18:
19: ## Files
20:
21: - `SKILL.md` — procedural guide loaded by the agent.
22: - `references/configuration.md` — env-var table, command dispatch, lifecycle, troubleshooting
23:   matrix (read on demand).
24:
25: ## Installation
26:
27: This skill is project-scoped (lives at `.agents/skills/agent-browser-pool/`), so any
28: Agent Skills-compatible client working in this repo discovers it automatically. To make it
29: available **globally** (every project), symlink it into your user skills dir:
30:
31: ```bash
32: ln -s "$(pwd)/.agents/skills/agent-browser-pool" ~/.agents/skills/agent-browser-pool
33: ```
34:
35: In Pi specifically, you can also load just this skill for a quick check:
36:
37: ```bash
38: pi --no-skills --skill .agents/skills/agent-browser-pool
39: ```
```

### Stale regions (the ONLY things to change)
- **Line 4** (LOGIC a): "transparent Chrome-profile wrapper" → "Chrome-profile pool"
- **Line 11** (LOGIC b): "`agent-browser` command under `pi`" → "`agent-browser-pool` command under `pi`"
- **Lines 16-17** (LOGIC c): "passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`)" → "driving commands fail fast without a `pi` ancestor (use `agent-browser` directly for raw access)"

### Preserved verbatim (LOGIC d — do NOT touch)
- Lines 1-3, 5-6 (title + intro, modulo line-4 phrase)
- Lines 8-15 (What it covers header + Acquire/Teardown bullets)
- Lines 19-39 (Files section + Installation section, incl. both bash code fences)

---

## 3. Verified SHIPPED behavior (truth anchors — read-only greps, AGENTS.md §1 compliant)

| Claim in new README | Source (verified live) |
|---|---|
| No `AGENT_BROWSER_POOL_DISABLE` anywhere | `grep -c AGENT_BROWSER_POOL_DISABLE lib/pool.sh` → **0** (P2.M1 done) |
| "driving commands fail fast without a `pi` ancestor" | `lib/pool.sh:3645-3646`: `pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." "For raw browser use without pooling, call 'agent-browser' directly."` |
| "use `agent-browser` directly for raw access" | same pool_die guidance string (above) |
| Sibling SKILL.md ships the new model | `grep -c 'AGENT_BROWSER_POOL_DISABLE\|transparent' SKILL.md` → **0**; `grep -c 'agent-browser-pool' SKILL.md` → **14**. FAIL-FAST described there too. |
| `agent-browser-pool` is the typed command (not `agent-browser`) | PRD §2.4 (h3.8) step 5: "EXEC the REAL binary: AGENT_BROWSER_SESSION=abpool-<N> agent-browser <cleaned args>" — the USER types `agent-browser-pool`; the pool internally execs the real binary. README teaches the user-typed command. |

**Note on "transparent wrapper" removal**: PRD §1.3 (h3.2) goal #1 "Explicit, invariant
invocation"; PRD §2.4 (h3.8) agent-facing invariant "The command never names a lane." The
pool is now an EXPLICIT tool (`agent-browser-pool`), not a transparent shadow of
`agent-browser`. The old `bin/agent-browser` PATH-shadow shim is DELETED (P2.M2.T2.S1).
So "transparent wrapper" is factually dead language.

**Note on "passthrough" word**: the README uses "passthrough" ONLY to describe the dead
no-pi-ancestor behavior. It does NOT discuss meta-command passthrough (that's configuration.md
+ SKILL.md territory). So removing "passthrough" entirely from this README is correct and
safe — there's no legitimate meta-passthrough mention here to preserve. (Contrast with
SKILL.md/configuration.md, which KEEP "pass straight through" for meta commands.)

---

## 4. Edit map (E1-E4)

| ID | LOGIC | Location | Old | New |
|----|-------|----------|-----|-----|
| E1 | a | line 4 | "transparent Chrome-profile wrapper" | "Chrome-profile pool" |
| E2 | b | line 11 | "`agent-browser` command under `pi`" | "`agent-browser-pool` command under `pi`" |
| E3 | c | lines 16-17 | "passthrough (no `pi` ancestor / `AGENT_BROWSER_POOL_DISABLE`)" | "driving commands fail fast without a `pi` ancestor (use `agent-browser` directly for raw access)" |
| E4 | d | lines 19-39 | (Files + Installation) | UNCHANGED |

E1-E3 are localized phrase replacements. E4 preserves the Files + Installation sections
verbatim (they reference the skill directory structure and `pi` invocation, not the browser
command — already correct in the new model).

---

## 5. Cross-doc consistency map

The README is the skill's "marketing blurb" (what the skill IS + what it covers). It must
agree with its two sibling docs that ship the same model:

- **SKILL.md** (P2.M4.T1.S1 — COMPLETE/shipped): uses `agent-browser-pool` as sole command;
  zero DISABLE/transparent; describes driving-outside-pi as "fails fast"; references
  `references/configuration.md`. README's "Acquire/Teardown/Pitfalls" bullets mirror these
  claims at a high level. ✓
- **configuration.md** (P2.M4.T2.S1 — in progress): env table (no DISABLE), dispatch table
  (no-pi→fail-fast), troubleshooting (fail-fast framing). README's Pitfalls bullet is the
  one-liner version; the matrix lives in configuration.md. ✓
- **repo README.md** (P2.M6.T1.S1 — later): will mirror the same command model. This skill
  README leads; the repo README follows later. No conflict.

**Disjointness**: this item touches ONLY `.agents/skills/agent-browser-pool/README.md`.
SKILL.md (shipped), configuration.md (P2.M4.T2.S1 in flight), `lib/pool.sh`, `bin/*`,
`install.sh`, repo `README.md`, `test/*` are all untouched by THIS item.

---

## 6. Validation strategy (static ONLY — AGENTS.md §1/§6)

A 39-line Markdown edit cannot hang the sandbox, but we STILL execute nothing. Validation:
- grep REMOVALS return zero: `transparent`, `AGENT_BROWSER_POOL_DISABLE`, the dead
  `passthrough (no `pi` ancestor` phrase, `agent-browser` command (the wrong example).
- grep ADDITIONS match: `Chrome-profile pool`, `agent-browser-pool` command, `fail fast`,
  the raw-access guidance `use `agent-browser` directly`.
- scope check: `git status --short` shows ONLY `.agents/skills/agent-browser-pool/README.md`
  (tolerant of parallel SKILL.md/configuration.md if they land in the same tree).
- shellcheck on the two embedded bash code fences (they are unchanged installation snippets,
  but lint them anyway for rigor).
- line count ~37-45.

Levels 2-4 are N/A (a doc has no runtime).

---

## 7. Confidence: high

Single-file, 3 localized phrase edits, full verbatim target provided, every claim anchored to
verified shipped behavior, validation entirely static. Cannot fail one-pass except by typo.
