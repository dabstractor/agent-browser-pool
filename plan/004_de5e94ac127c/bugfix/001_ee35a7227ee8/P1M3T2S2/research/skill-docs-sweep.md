# Research — P1.M3.T2.S2: skill-docs sweep & sync (.agents/skills/agent-browser-pool/)

Date: 2026-08-21 · HEAD `5f2a702` (all changeset-001 fixes landed; S1 README sync in flight).
Method: read-only greps/reads only (AGENTS.md §1 — no live runs).

---

## 1. The skill dir (confirmed contents)

`.agents/skills/agent-browser-pool/` = exactly 3 files (system_context.md §1):

| file | role | lines-relevant |
|---|---|---|
| `SKILL.md` | procedural guide agents load | §1 acquire (:26-…), §2 teardown (:81), §3 safety, §4 pitfalls (:153 "fails to boot"), §5 ref pointer |
| `README.md` | meta/index: "What it covers" bullets, Files, Installation | :8-19 |
| `references/configuration.md` | env table (:14-32), caller-mode (:35-…), pinning, dispatch, **lifecycle (:153-175)**, release (:176-…), **troubleshooting matrix (:193-207)**, **Admin CLI (:210-225)** |

## 2. Sweep results — statements the changeset invalidated

Sweep greps: `concurren|race|two command|same time|crash|recover|boot` over all 3 files + full reads.

### (a) "concurrent commands from one agent can fail during boot / leak Chrome"

**NO invalidated claim exists.** No skill file ever documented the BUG-002 failure mode
(the skill predates its discovery; the bug was found by adversarial testing). SKILL.md:15
("One browser for the whole session") and configuration.md's lifecycle diagram (:157-168)
are silent on concurrency. → invalidation sweep = **no-op**; the sync *adds* the new
guarantee (E1/E5) so the skill "agrees with README" (S1 Edit 1) and code.

### (b) crash-recovery / stale-lane guidance vs corrupt-lease reclaim (BUG-003)

Two matrix rows predate the fix and understate the new reality:

- **configuration.md:204** — `| status shows my lane as STALE / field ? | Owner process died or
  lease is corrupt | The reaper will reclaim it; the operator can run reap |`.
  Before BUG-003 the Fix cell was **false for corrupt leases** (no verb could clear one —
  burned lane). Now `reap` removes a corrupt `lanes/<N>.json` **once its dir is gone**
  (lib/pool.sh `pool_reap_orphan_dirs`: `rm -f -- "$POOL_LANES_DIR/$base.json"` + log
  "removed corrupt lease … (BUG-003)"), and `release <N>` clears one **even with the dir +
  live Chrome present** (`_pool_release_lane_internals` corrupt branch + cmdline sweep
  "chrome ids untrusted → cmdline sweep"). README's landed release § (Mode-A) wording:
  "(`release all` does not clear corrupt leases; use `release N` or `reap`.)" → **EDIT E2**.
- **configuration.md:205** — doctor-WARN row Fix: "reap clears stale lanes **and** orphan dirs"
  → now also corrupt leases → **EDIT E3**.
- configuration.md:200 / SKILL.md:153-158 ("fails to boot … will **not** self-heal"):
  **remains accurate** for genuine boot failures (Chrome/port/resource). The one case that
  *did* become self-healing (crashed-boot stale dir, wiped on re-boot) is exactly what
  lifecycle paragraph E1 documents. → **no edit** to these rows (rationale recorded).

### (c) doctor on fresh installs (BUG-004)

No skill file claims doctor fails on a fresh install (invalidation sweep = no-op). But
README's landed doctor § (Mode-A) documents the new behavior: "If the ephemeral root
directory does not exist yet, `doctor` creates it — so the btrfs check is exact on fresh
installs". The skill's Admin CLI doctor line (configuration.md:223) is the natural mirror →
**EDIT E4** (one clause).

### (d) configuration.md env table vs pool_config_init

All **13 existing rows verified against code** (lib/pool.sh:99-112 config-table comment +
parsing): STATE, MASTER (default `${XDG_CONFIG_HOME:-~/.config}/google-chrome` ✓),
EPHEMERAL_ROOT, REAL, CHROME_BIN, PORT_BASE 53420, PORT_RANGE 1000, WAIT 600, HEADLESS,
ALLOW_SLOW_COPY, HARNESSES (default `pi,claude,codex,agy,antigravity` :213 ✓, **replace**
semantics ✓), ABPOOL_OWNER, ABPOOL_LANE. **No env var changed in this changeset → table
edits: none.**

**Pre-existing gap (recorded, out of scope):** `AGENT_CHROME_PROFILE`
(pool_config_init:109/204 → `POOL_PROFILE_DIR`, "unset = derive from Local State
last_used"; help :5252 documents it) is absent from configuration.md's env table **and
equally absent from README's config table** — a symmetric, pre-changeset omission, not a
changeset delta. Adding one row to only the skill would desync the two docs. → **no edit;
flagged for a future docs pass.**

### HARNESSES three-way agreement (item research note — "fix any straggler")

| surface | evidence | semantics |
|---|---|---|
| help (code) | lib/pool.sh:5250-5251: "recognized harness command names (comma-separated; **replaces the default pi,claude,codex,agy,antigravity; empty/unset -> default**)" | replace ✓ |
| README | README.md:329 row: "Empty/unset → default (never empty)" | replace ✓ |
| skill | configuration.md:28 row: identical wording to README:329 | replace ✓ |

**All three agree. No straggler.** (BUG-005 was help-text-only; P1.M2.T3.S1 fixed it.)

## 3. Wording source of truth

- README Mode-A admin sections (landed with the M2 commits, quoted in §2b/§2c above).
- S1's Edit 1 paragraph (README "How it works", landing in parallel — treat as landed):
  "**Boot serialization & crash recovery.** A lane's boot and any later reconnect/relaunch
  are serialized by a short-lived per-lane boot lock (`lanes/<N>.boot.lock`) … a reconnect
  waits (up to ~20s) … `pool_copy_master` first wipes any stale partial dir left at
  `active/<N>` and re-copies fresh from the master…". Code evidence: `pool_lane_boot_lock`
  → `$POOL_LANES_DIR/<N>.boot.lock` (:267-296), `flock -w 20` fd 8 (:2703 boot, :2957
  ensure-connected), guarded wipe `rm -rf -- "$target_dir"` in `pool_copy_master`
  (:1352/:1364).

## 4. Edit plan (5 edits + recorded no-ops)

| id | file:anchor | action |
|---|---|---|
| E1 | configuration.md lifecycle ¶ (after the "Lane identity is keyed…" ¶, before `## Release lifecycle`) | add "Boot serialization & crash recovery." paragraph (condensed S1 Edit 1, names `lanes/<N>.boot.lock`, ~20s, port-0 wipe + re-copy, `pool_copy_master`) |
| E2 | configuration.md:204 (STALE row Fix cell) | corrupt-lease reclaim: `reap` after dir gone; `release <N>` even with dir present; `release all` skips corrupt |
| E3 | configuration.md:205 (doctor WARN row Fix cell) | "clears stale lanes, orphan dirs, **and** corrupt leases" |
| E4 | configuration.md:223 (Admin CLI doctor line) | append "; creates the ephemeral root if missing, so the btrfs check is exact on fresh installs" |
| E5 | SKILL.md §1 end (after "You do not reconnect between calls.") | one sentence: concurrent commands from your session are safe — boots/reconnects serialize per lane (agent voice, no internals; the detail lives in configuration.md E1) |
| no-op | skill README.md | no invalidated claims (all bullets still true) → untouched |
| no-op | SKILL.md:153-158 / configuration.md:199-200 | exhaustion/boot-failure guidance still accurate → untouched |
| no-op | env table | 13 rows verified; AGENT_CHROME_PROFILE gap pre-existing+symmetric → untouched this task |

Layering principle honored: SKILL.md = agent-facing guarantee (plain voice);
configuration.md = technical detail (paths/functions); both defer to README wording.

## 5. Scope fence (from system_context.md §1 + AGENTS.md)

EDIT ONLY the two skill files above. Off-limits: README.md (S1 owns it, parallel),
lib/, bin/, test/, install.sh, PRD.md, plan/** (own research/ dir excepted). Docs-only
task — zero live runs (AGENTS.md §1); verify claims by grep only.