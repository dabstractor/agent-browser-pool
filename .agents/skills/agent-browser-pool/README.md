# agent-browser-pool (Agent Skill)

An [Agent Skill](https://github.com/earendil-works/pi-coding-agent) that teaches AI agents
how to use the [`agent-browser-pool`](../..) Chrome-profile pool correctly: how their
dedicated lane is acquired and connected, how it's reused across calls, and how to tear it
down.

## What it covers

- **Acquire + connect:** the lane is created automatically on the first driving
  `agent-browser-pool` command under `pi`; agents don't pass ports or `--session` (the pool
  owns them).
- **Teardown:** `close` is disconnect-only; the real release happens automatically when the
  owning `pi` process exits. Agents should avoid `agent-browser-pool release`/`reap`
  (operator tools; `release <N>` is not owner-scoped).
- **Pitfalls:** driving commands fail fast without a `pi` ancestor (use `agent-browser`
  directly for raw access), pool exhaustion hangs, ephemeral profiles, and why to never
  launch Chrome directly.

## Files

- `SKILL.md` — procedural guide loaded by the agent.
- `references/configuration.md` — env-var table, command dispatch, lifecycle, troubleshooting
  matrix (read on demand).

## Installation

This skill is project-scoped (lives at `.agents/skills/agent-browser-pool/`), so any
Agent Skills-compatible client working in this repo discovers it automatically. To make it
available **globally** (every project), the easiest path is the installer's opt-in flag:

```bash
./install.sh --global-skill      # symlinks this skill into ~/.agents/skills/
```

…or symlink it into your user skills dir by hand:

```bash
ln -s "$(pwd)/.agents/skills/agent-browser-pool" ~/.agents/skills/agent-browser-pool
```

In Pi specifically, you can also load just this skill for a quick check:

```bash
pi --no-skills --skill .agents/skills/agent-browser-pool
```
