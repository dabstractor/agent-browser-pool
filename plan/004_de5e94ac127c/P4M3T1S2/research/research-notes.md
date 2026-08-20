# Research notes — P4.M3.T1.S2 final audit (citation sweep, die-text mirrors, cross-doc consistency)

Snapshot taken while P4.M3.T1.S1 (README sync) is being implemented in parallel.
Static only (grep/read); no browsers, no test runs, per AGENTS.md §1.

## 1. Sources

- `plan/004_de5e94ac127c/architecture/citation_audit.md` §1 (baseline 96/92, per-file
  56/1/2/6/4/12/10/5; post-sweep distribution 2.12=0 2.13=10 2.14=2 2.15=24 2.16=25
  2.17=5 2.18=3 2.19=16 2.20=11; untouched §2.10=10, §2.11=3) and §8 (verification
  command set). §7: test/*.sh § cites are comment-only; .agents/ has only §2.7/§2/§3
  (outside range).
- `plan/004_de5e94ac127c/P4M1T1S1/research/sweep_audit.md` — the recorded R1 audit
  (all gates passed; §2.17b at pool.sh:3636; +/- equal per file).
- `plan/004_de5e94ac127c/architecture/synthesis.md` §1/§4/§5 — contracts, die-text
  wording, docs surfaces.
- `plan/004_de5e94ac127c/P4M3T1S1/PRP.md` — the README contract being implemented in
  parallel (2 env rows, orchestrator section, lifecycle step-3 line, pinned-conflict
  troubleshooting block quoting die text, orchestrator checklist line, §2.12/§2.16 cites).

## 2. Live mid-changeset state (observed now, NOT final numbers)

Per-file `grep -oE '§2\.1[3-9]|§2\.20'` occurrence counts today:
pool.sh 63, bin 1, install 2, validate 9, concurrency 5, release_reaper 12,
transparency 10, README 5. pool.sh additionally has **6 `§2.12`** tokens (new,
caller-scoped — legitimate per contract: "every §2.12 citation in code points at
caller-scoped content"). README currently 0 × §2.12 (S1 will add ~2-3).

⇒ The audit CANNOT hardcode absolute totals. Expected per file =
R1 post-sweep baseline (56/1/2/6/4/12/10/5) + only the citations each implementing
subtask deliberately added and recorded (pool.sh +7 = caller-mode comments incl.
6×§2.12; validate.sh +3; concurrency.sh +1; README +S1's additions). The auditor
reconstructs "expected" from the recorded subtask notes and the sweep_audit delta —
it does not guess.

## 3. Die texts in lib/pool.sh (verbatim anchors for mirror check)

- L230: `agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '<raw>'`
- L590: `agent-browser-pool: ABPOOL_OWNER=caller requires a live parent process (got ppid $PPID); invoke agent-browser-pool as a child of the long-lived orchestrator process`
- L2318: `pinned lane $POOL_LANE_PIN is held by a live owner (pid $o_pid, comm $o_comm); a pinned lane is never a takeover — unset ABPOOL_LANE or choose a free lane`
- L3797: `agent-browser-pool: ABPOOL_LANE=$POOL_LANE_PIN: pinned lane unavailable (see the error above)`

Docs that must mirror these: README.md (S1's troubleshooting block), skill
references/configuration.md, SKILL.md, skill README.md (grep both sides).

## 4. Grep set

`grep -oE '§2\.1[3-9]|§2\.20'` for shifted-set totals (§2.20 needs explicit alternation
— `[2-9]` misses it). Old-token leak check: `grep -rnE '§2\.1[2-9]'` minus the
legitimate new §2.12 caller-scoped ones; the audit rule is: swept-set totals =
baseline + recorded deliberate additions; every §2.12 in code cites caller-scoped
content (PRD §2.12 = "Caller-scoped lane selection"); no pre-R1 meaning survived.

## 5. Cross-doc consistency surfaces

README.md, .agents/skills/agent-browser-pool/references/configuration.md,
.agents/skills/agent-browser-pool/SKILL.md, .agents/skills/agent-browser-pool/README.md —
same env-var names+defaults (ABPOOL_OWNER unset default, ABPOOL_LANE unset/positive-int,
AGENT_BROWSER_POOL_WAIT=600, PORT_BASE 53420/RANGE 1000, HARNESSES default list) and same
mode vocabulary ("caller mode"/"orchestrator mode", "pinned lane", "never a takeover",
"live parent", "auto-reaped on exit"). 003-changeset discipline: grep quoted strings on
both doc and code sides.

## 6. Static gates

`bash -n` + `shellcheck -s bash` on lib/pool.sh, install.sh, test/*.sh (bin too);
install.sh must be `git status --porcelain install.sh` clean (PRD: no change).
Orphan audit per AGENTS.md §6: `pgrep -af 'chrome|abpool|sleep'` filtered to
validation-spawned processes; `ls /tmp/abpool-*` must be empty (use `ls … 2>/dev/null`
to avoid rc-1 under errexit-style aborts; never bare `kill -0`).