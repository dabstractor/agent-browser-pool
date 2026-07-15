# Delta PRD — Pivot to explicit `agent-browser-pool` invocation (no PATH shadow)

**Status:** Ready to build. All decisions resolved (carried from PRD §4 O5–O8).
**Delta from:** session 001 (`prd_snapshot.md` = current PRD.md, HEAD commit `3a2f065`).
**Size class:** Medium. The underlying pool machinery (lease/acquire/release/reap/owner-resolve/copy/boot) is **complete and unchanged**. This delta changes only the **entry-point contract**: transparent PATH-shadowing wrapper → explicit invariant command. The contract change ripples through the installer, the agent skill, and the tests — but not the lane engine.

**One-line goal:** Replace the global `~/scripts`-based `agent-browser` shadow with a single explicit entry point, `agent-browser-pool <verb> <args>`, whose lane is selected by the caller's process identity — **never an argument** — so (a) installing the pool can no longer disrupt running agents, (b) an agent cannot reach another agent's lane through any normal command, and (c) the per-process `DISABLE` safety valve is obsolete and removed.

---

## 1. What actually changed (PRD diff, condensed)

The PRD diff is large in *line count* but narrow in *mechanism*. Three of the new decisions are **already implemented** by HEAD commit `3a2f065`; the rest is this delta's scope.

### 1.1 Already shipped — do NOT re-implement (verify only)
- **O4 — Source profile.** `$AGENT_CHROME_MASTER` now defaults to the user's **real Chrome user-data-dir** (`${XDG_CONFIG_HOME:-~/.config}/google-chrome`), live/in-use supported. ✅ Done in `pool_config_init`, `pool_check_master` (new guidance message), `pool_copy_master` (`Singleton*` glob strip **+ assert none survive**), and `pool_admin_help` (master help line). **Doc fallout only** (see §3): README + `configuration.md` still describe `master-profile`/static-template.

### 1.2 In scope for this delta (the pivot)
- **O5 — No PATH shadowing.** The pool is invoked **explicitly** as `agent-browser-pool` (sole entry point + skill). The `~/scripts`-ahead-of-`~/.local/bin` shadow, the cutover danger, and the `AGENT_BROWSER_POOL_DISABLE` safety valve are **removed**. The real `agent-browser` CLI is never intercepted.
- **O6 — Invariant command, identity-keyed lanes.** The lane is selected by the caller's `(pid, comm, starttime)` identity — never an argument. The agent's command is **identical on every lane**. Cross-lane access is impossible through normal use because **no command names a lane** except operator `release <N>` (teardown, not join).
- **O7 — Full surface owned.** Every real-`agent-browser` verb passes through; the pool owns only connection/session/lifecycle. (Step-5 cleaning: strip `--session <X>`, drop a `connect <port|url>` positional, `close` stays disconnect-only.)
- **O8 — `agent-browser` is a hard runtime dependency**, enforced two ways: `doctor`'s binary check (already present) **plus a new preflight on every driving call** that fails fast with an actionable "install agent-browser ≥ 0.28" message rather than booting a lane it can't drive.

### 1.3 Removed (note for awareness — no tasks)
- `bin/agent-browser` wrapper shim (deleted; repo ships only `bin/agent-browser-pool`).
- `AGENT_BROWSER_POOL_DISABLE` / `POOL_DISABLE` and all passthrough semantics derived from it.
- The META/passthrough command class (`skills`, `--version`, `session list`, `dashboard`, `plugin`, `mcp` passing through unchanged). In the new model these are simply **not pool commands**: pool verbs are an explicit allowlist; everything else is a driving command that owns a lane. `agent-browser` (the real CLI) remains available for raw/meta use.
- `install.sh` cutover warning, confirmation gate, `~/scripts` symlink, and PATH-ordering verification.

---

## 2. Scope

### 2.1 In scope
- Consolidate to a single entry point (`bin/agent-browser-pool` routes **both** pool verbs and driving commands); delete `bin/agent-browser`.
- Reclassify dispatch: **POOL VERB** (status|reap|release|doctor|help|--help|-h) vs **DRIVING** (everything else). Pool verbs need no owner; driving **requires a `pi` ancestor and fails fast** if absent ("for raw browser use call `agent-browser` directly") — replacing the old no-pi-ancestor passthrough.
- Add the real-binary **preflight** to the driving path (O8).
- Rewrite `install.sh` (benign, no cutover).
- Rewrite the agent **skill** (`SKILL.md` + `references/configuration.md`) for the invariant-command contract.
- Pivot the test harnesses to the single entry point and to the new fail-fast/no-passthrough expectations.
- Sync `README.md` (cross-cutting).

### 2.2 Out of scope
- Any change to lease data model, acquire/release/reap, owner resolution, copy/boot, port allocation, exhaustion handling, or Chrome launch flags — all complete and correct.
- `btrfs subvolume snapshot` for atomic live-source copies (PRD §2.7 explicit *future*).
- `doctor` asserting `agent-browser --version ≥ 0.28` numerically (PRD §2.16 explicit *future*); the preflight checks executability only.
- Generalizing the owner identity beyond `comm=="pi"` (PRD §2.4 `[DEFAULT]` note — future option).

---

## 3. Requirements

> **Reference for implementers:** all lane-engine functions are unchanged — call them, do not rewrite them. Affected completed code is named in §4.

### Phase D1 — Pivot to explicit invocation

#### Milestone D1.M1 — Entry-point consolidation & dispatch pivot (code)

**D1.M1.T1 — Sole entry point + dispatch reclassification.**
`bin/agent-browser-pool` becomes the **only** entry point. Its dispatcher (currently a `case` that errors `Unknown command` on `*)`) routes: pool verbs → existing `pool_admin_*` functions (status/reap/release/doctor, and `--help|-h|help` → `pool_admin_help`); **everything else → the driving router** (`pool_wrapper_main`, see D1.M1.T2). Then **delete `bin/agent-browser`** (the wrapper shim) and its `bin/.gitkeep` if now empty. PRD §2.4 step 0, §3.
- *Mode A docs (ride with this work):* update the file-header comment in `bin/agent-browser-pool` to describe it as the **sole entry point (pool verbs + driving router)**, not "admin CLI". Open detail (note, do not block): PRD lists POOL VERB as exactly `(status|reap|release|doctor|help|--help|-h)`; `--version` is therefore *driving*. Confirm this is acceptable or special-case `--version`→preflight-only passthrough — implementer's call, keep it minimal.

**D1.M1.T2 — `pool_wrapper_main` pivot + config/help cleanup + real-binary preflight.**
In `lib/pool.sh`, modify `pool_wrapper_main` (the driving router) per PRD §2.4 steps 1 & 5:
  - **Remove** the `POOL_DISABLE==1 → passthrough` step (currently step b).
  - **Remove** the META passthrough step (currently step c: `pool_dispatch_classify` → meta/exec-unchanged). Reclassify: there is no "meta" class in the pool entry now — the `bin` dispatcher already handled pool verbs; everything reaching `pool_wrapper_main` is driving. `pool_dispatch_classify` is either deleted or reduced to the pool-verb/driving split already done by the dispatcher (avoid duplication). Preserve the still-needed helpers it sat between: `pool_normalize_close`/`pool_normalize_connect`, `pool_strip_session_args`, `pool_force_session`, the bare-connect no-op short-circuit, and the close→`connected=false` mark (Issue #1/#3) — these are unchanged.
  - **Change no-`pi`-ancestor behavior** from passthrough → **fail fast**: `pool_owner_resolve` sets `POOL_OWNER_PID==0` → `pool_die` with *"requires a pi ancestor; for raw browser use call `agent-browser` directly"* (PRD §2.4 step 1). The test-hook overrides (`AGENT_BROWSER_POOL_OWNER_PID`/`_OWNER_STARTTIME`) continue to bypass the ppid walk (key_findings FINDING 8 — unchanged).
  - **Add the real-binary preflight (O8):** before booting/acquiring a lane, verify `POOL_REAL_BIN` exists and is executable; on failure, `pool_die` with an actionable "install agent-browser ≥ 0.28" message (do NOT boot a lane you can't drive). New small helper (e.g. `_pool_check_real_bin`); call it on the driving path.
  - **Remove `POOL_DISABLE`** from `pool_config_init` (the `_pool_config_bool "${AGENT_BROWSER_POOL_DISABLE:-}"` computation + its `declare -g` + the config-reference comment line ~109).
  - **Update `pool_admin_help`:** drop the `AGENT_BROWSER_POOL_DISABLE` line; describe invocation as `agent-browser-pool <verb> [args]` and note `release <N>` is operator-only (the sole lane-naming command, teardown not join — PRD §2.12).
- *Mode A docs:* the in-code config-reference block and `pool_admin_help` output are the user-facing surface changed here — update both as above.

#### Milestone D1.M2 — Installer + agent skill contract

**D1.M2.T1 — Rewrite `install.sh` (no shadow, no cutover).**
Per PRD §2.17: do three benign things — (1) symlink `bin/agent-browser-pool` → `~/.local/bin/agent-browser-pool` (the sole entry point); (2) pre-create the pool state dir (`lanes/` + `acquire.lock`) via the lib; (3) run `doctor`. **Remove** the cutover warning, the `YES` confirmation gate, the `--force` flag, the `~/scripts` symlink, and the entire PATH-ordering verification block. Remove the `AGENT_BROWSER_POOL_DISABLE` mention from all output. Uninstall becomes `rm -f ~/.local/bin/agent-browser-pool`.
- *Mode A docs:* `install.sh`'s prompts/output ARE the install documentation — rewrite them to match (benign install, no danger).

**D1.M2.T2 — Rewrite the agent skill (`SKILL.md` + `references/configuration.md`).**
This is the agent-facing contract; it currently teaches the old `agent-browser …` transparent-wrapper model and must move fully to `agent-browser-pool <verb> <args>` (PRD §2.15 invocation checklist):
  - `SKILL.md`: drop "transparent PATH-shadowing wrapper" framing; lead with "the command never names a lane — `agent-browser-pool <verb> <args>` always means *my* lane." Teach the **full real-`agent-browser` verb surface** (O7). Update connection rules (no `--session`; `connect <x>` arg dropped; `close [--all]` disconnects only my lane). Remove the `AGENT_BROWSER_POOL_DISABLE`/passthrough pitfall; replace the "wrong/no browser" cause with the new *no `pi` ancestor → fail fast* guidance ("run under `pi`; for raw browser use call `agent-browser` directly"). Note `release <N>` is operator-only.
  - `references/configuration.md`: rewrite the env-var table (master default → real Chrome user-data-dir per §1.1; **drop** `AGENT_BROWSER_POOL_DISABLE`); replace the "meta vs driving" dispatch section with "pool verbs vs driving" (PRD §2.4 step 0) and the no-pi-ancestor fail-fast; update the troubleshooting matrix (remove the passthrough cause); update invocation examples to `agent-browser-pool …`.
- *Mode A docs:* these two files **are** the documentation deliverable for the contract change.

#### Milestone D1.M3 — Test pivot + changeset-level docs

**D1.M3.T1 — Pivot test harnesses to the single entry point.**
All four harnesses currently drive via `ABPOOL_WRAPPER="$ABPOOL_REPO/bin/agent-browser"` and admin via `ABPOOL_ADMIN="…/bin/agent-browser-pool"`; `transparency.sh`/`validate.sh`/`concurrency.sh`/`release_reaper.sh` all assume the wrapper+passthrough model. Changes:
  - Point the driving entry at `bin/agent-browser-pool` (one entry now); retire/collapse the `ABPOOL_WRAPPER` vs `ABPOOL_ADMIN` split (e.g. `ABPOOL_ENTRY`).
  - **Remove** the obsolete assertions: `transparency.sh` tests (a) `skills get core`→passthrough and (b) `--help`/`--version`→passthrough (byte-equal to the real binary) — there is no passthrough now. Replace with the new contract: pool verbs (`--help`,`status`) work with no owner; a driving command with no `pi` ancestor (and no override) **fails fast non-zero**.
  - **Remove** the `validate.sh` `AGENT_BROWSER_POOL_DISABLE`→`POOL_DISABLE` test block (lines ~346–357) and any passthrough/owner-passthrough assertions.
  - Keep all lane-engine coverage (concurrency = N distinct lanes; release/reaper teardown; close≠release; session override; reuse-by-owner) — only the **entry invocation** and the removed-passthrough expectations change.
  - Honor AGENTS.md §1–§4: tests stay isolated (temp-tree HOME/state/ephemeral), `timeout`-bounded, single-setup, reaped; no real Chrome against the live HOME during planning.
- *Mode A docs:* none beyond in-test comments.

**D1.M3.T2 — Sync changeset-level documentation (`README.md`).** *(Mode B — depends on all above.)*
`README.md` is built end-to-end around the old model: "transparent PATH-shadowing wrapper" (line 3), `master-profile` (lines 12, 34, 211, 368), cutover install (§Installation 50–88), `AGENT_BROWSER_POOL_DISABLE`/Safety-valve (§234–246, 254, 273, 338), and the repo-layout block (§343–368, still lists `bin/agent-browser` wrapper + `master-profile/`). Update to: explicit `agent-browser-pool` invocation; source profile = real Chrome user-data-dir (live, read-only to the pool); benign install (no cutover); drop the Safety-valve section; refresh prerequisites (agent-browser ≥ 0.28 is a hard dependency), config table (no DISABLE), troubleshooting (no passthrough cause), and repository layout (only `bin/agent-browser-pool`). Verify accuracy against the final code.

---

## 4. Affected completed work (file / function map)

Implementers must **edit**, not rebuild, these existing artifacts:

| Artifact | Change |
|---|---|
| `bin/agent-browser` | **DELETE** (wrapper shim no longer shipped). |
| `bin/agent-browser-pool` | Dispatcher `*)` → driving router (`pool_wrapper_main`); header comment → "sole entry point". |
| `lib/pool.sh` → `pool_wrapper_main` | Drop DISABLE passthrough (b) + META passthrough (c); no-pi-ancestor → fail-fast (d); add real-binary preflight. Keep normalize/strip/force/bare-connect/close-mark steps unchanged. |
| `lib/pool.sh` → `pool_dispatch_classify` | Obsoleted/reduced by the dispatcher's pool-verb/driving split; remove or simplify to avoid duplication. |
| `lib/pool.sh` → `pool_config_init` | Remove `POOL_DISABLE` computation + config-reference line. |
| `lib/pool.sh` → `pool_admin_help` | Drop DISABLE line; reframe invocation; note `release` is operator-only. |
| `install.sh` | Rewrite: benign (one symlink + state dir + doctor); remove cutover/confirmation/shadow/PATH-check. |
| `.agents/skills/agent-browser-pool/SKILL.md` | Full rewrite (invariant command, full surface). |
| `.agents/skills/agent-browser-pool/references/configuration.md` | Rewrite env table + dispatch + troubleshooting. |
| `README.md` | Mode B sync (§3 D1.M3.T2). |
| `test/{transparency,validate,concurrency,release_reaper}.sh` | Entry → `bin/agent-browser-pool`; remove passthrough/DISABLE assertions; add fail-fast expectations. |

**Unchanged (do not touch):** `pool_owner_resolve`, `pool_owner_alive`, `pool_lease_*`, `pool_lanes_list`, `pool_lane_is_stale`, `pool_acquire_locked`, `pool_boot_lane`, `pool_ensure_connected`, `pool_release_lane`, `pool_reap_stale`, `pool_reuse_orphan`, `pool_wait_for_lane`, `pool_copy_master` (already updated for O4), `pool_check_btrfs`, `pool_check_master` (already updated for O4), `pool_admin_status`/`reap`/`release`/`doctor`, the lease JSON schema, and all Chrome launch flags.

---

## 5. Decisions (all resolved — from PRD §4)

- **O4 — Source profile** = real Chrome user-data-dir (live, read-only to the pool). ✅ *Already implemented*; docs pending.
- **O5 — No PATH shadowing** = explicit `agent-browser-pool` entry; cutover danger + `DISABLE` removed. ✅
- **O6 — Invariant command, identity-keyed lanes** = lane by `(pid,comm,starttime)`, never an argument; cross-lane access impossible through normal use. ✅
- **O7 — Full surface owned** = every real verb passes through; pool owns connection/session/lifecycle only. ✅
- **O8 — Hard runtime dependency** = `agent-browser` enforced by `doctor` + new driving-call preflight (executability; numeric `--version` check is future). ✅

---

## 6. Validation criteria (the delta "done" contract)

- [ ] `bin/agent-browser` is gone; `bin/agent-browser-pool` is the sole repo entry point and routes both pool verbs and driving commands.
- [ ] `agent-browser-pool open <url>` under `pi` (or with owner override) acquires/reuses **my** lane — same command on every lane; I never pass a lane/port/session.
- [ ] A driving command with **no `pi` ancestor** (and no override) **fails fast** with the "call `agent-browser` directly" message (no passthrough, no lane boot).
- [ ] Pool verbs (`status`, `doctor`, `--help`) work from any shell with **no owner** required.
- [ ] `AGENT_BROWSER_POOL_DISABLE` is gone from code, `pool_admin_help`, the skill, the README, and `install.sh`.
- [ ] A driving call with `POOL_REAL_BIN` missing/non-executable **fails fast** before booting a lane (preflight).
- [ ] `install.sh` creates only `~/.local/bin/agent-browser-pool` + the state dir, runs `doctor`, prints no cutover warning, asks no confirmation.
- [ ] `agent-browser-pool --session <X> open <url>` → forced to `abpool-<N>`; `agent-browser-pool connect <port>` → arg dropped; `agent-browser-pool close [--all]` → my lane only.
- [ ] Tests pass isolated + `timeout`-bounded, single-setup, fully reaped (AGENTS.md §1–§6); no real Chrome against the live HOME during planning.
- [ ] README + skill accurately describe the implemented system (no `master-profile`/shadow/cutover/DISABLE stale references).
