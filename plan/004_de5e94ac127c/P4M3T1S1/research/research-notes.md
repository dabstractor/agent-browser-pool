# Research notes — P4.M3.T1.S1 (README.md Mode B documentation)

Sources: `plan/004_de5e94ac127c/architecture/docs_map.md` §1/§7/§8, `architecture/synthesis.md` §4,
live reads of `README.md`, `.agents/skills/agent-browser-pool/references/configuration.md`,
`lib/pool.sh`.

## Ground truth from the implemented code (verbatim die texts, lib/pool.sh)

- Malformed pin (pool_config_init, L230):
  `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw>'`
- Live-foreign pin (L2318):
  `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`
- One-lane-per-owner pin conflict (L2294):
  `owner pid=$POOL_OWNER_PID already holds live lane $held; ABPOOL_LANE=$POOL_LANE_PIN would violate the one-lane-per-owner invariant — release lane $held first or unset ABPOOL_LANE`
- Caller-mode dead parent (L590):
  `agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process`

**IMPORTANT semantic correction vs PRD:** caller mode keys ownership on the invoking
**parent process** (`$PPID` — the subprocess that ran `agent-browser-pool`), NOT on `$$`
itself as PRD §2.12 originally sketched. configuration.md:46–47 already documents this
("the subprocess that invoked `agent-browser-pool`"). README wording must match
configuration.md, not the PRD's `$$` phrasing.

## README.md anchors (verified live, post-R1 sweep)

- Env table `## Configuration reference` L253; header `| Env var | Default | Meaning |` at L259–260;
  HARNESSES row ends L272 → insert ABPOOL_OWNER + ABPOOL_LANE rows at L273 (before blank line).
- `## Usage (for agents)` L101–127: intro ¶ (identity keying), 4 bullets L107–112, bash fence L114–116,
  harness-ancestor blockquote L118–123, skill-pointer ¶ L125–127. New
  `### Orchestrator mode (caller-scoped lanes)` goes after the skill pointer ¶, before `## Commands` (L129).
- Lifecycle step 3 is in the numbered list under "Lane lifecycle ordering (`pool_wrapper_main`)" —
  currently ~L318: "**driving command → resolve the owning harness process**". Needs caller-keyed mention.
- `## Troubleshooting` blocks at `###` L342 (harness), L356 (exhaustion, cites PRD §2.9), L371 (leaks,
  cites PRD §2.15). New pinned-conflict block goes between exhaustion (~ends L369) and Leaks (L371),
  i.e. at ~L370. Format: **Symptom:** / **Cause:** / **Fix:** bold-labelled paragraphs.
- Current PRD citations (all NEW numbering, verified): L81 §2.18, L250 §2.13+§2.15, L286 §2.19,
  L369 §2.9, L384 §2.15. Do not disturb; new prose cites §2.12 (caller/pin) / §2.16 (checklist line).

## configuration.md wording to sync with (do not fork)

- Env rows L29–30 (insert after HARNESSES L28): `ABPOOL_OWNER` = "any non-empty value
  (recommended: `caller`) → key lane ownership on the calling process itself … The
  recognized-harness fail-fast does not apply in caller mode"; `ABPOOL_LANE` = "positive
  integer N → pin lane N: adopt if free or stale … live lease owned by another process →
  hard error — **never a takeover**. Malformed → hard error at startup".
- Caller subsection L46–74: parent-pid semantics, auto-reap via lazy reaper, fail-fast
  exemption, default path unchanged, parallel-scrapers fence
  (`ABPOOL_OWNER=caller .venv/bin/python scrapers/linkedin_discover.py --no-ping &` … `wait`).
- Pin subsection L76–105: free/stale→take (no orphan adoption under pin), live-mine→idempotent
  reuse, live-foreign→hard error (no wait/force-reap), already-holds-lane→hard error,
  malformed→startup error, works in both modes, same reap rules.
- Additional implemented nuances worth one README sentence each: under a pin a stale lane is
  reaped and even a responsive orphan Chrome is NOT adopted (fresh state guarantee); the
  exhaustion wait path never applies to pins.

## Style (docs_map §7)

3-col env table (`Env var` header in README), backticked keys/defaults, **bold** sparingly,
`→` arrows, imperative voice, em-dashes, bash fences with `#` glosses, README cites PRD as
`[PRD.md §X.YY](./PRD.md)`.