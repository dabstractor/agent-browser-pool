# Research: Codebase facts for `pool_admin_status()` (P1.M7.T1.S1)

> Verified by direct reads of `lib/pool.sh` (3541 lines), `PRD.md`, and
> `plan/001_0f759fe2777c/tasks.json`. Line numbers are 1-indexed.

## Summary
`pool_admin_status()` is a **read-only, lib-only** function to be **APPENDED**
to the end of `lib/pool.sh` (file ends at `pool_wrapper_main`, `lib/pool.sh:3541`).
It composes four contract-documented helpers — `pool_lanes_list`,
`pool_lease_read`, `pool_lane_is_stale`, `_pool_age_str` — to print a lane table
to **stdout**. The lease JSON has 12 top-level fields (`connected` is a JSON
**boolean**); `pool_lane_is_stale` is **tri-state** (rc 0=stale / 1=live / 2=no-lease);
every non-zero-returning helper MUST be guarded under `set -e`. The dispatcher
`bin/agent-browser-pool` is a **separate task (P1.M7.T5.S1)** and does NOT exist.

## 1. Lease JSON schema (PRD §2.8 `PRD.md:189-207` + `pool_lease_write` `lib/pool.sh:682`)

```json
{ "version":1, "lane":7, "ephemeral_dir":"…", "port":53427, "session":"abpool-7",
  "owner":{"pid":836725,"comm":"pi","starttime":1234567890,"cwd":"/home/…"},
  "chrome_pid":104816, "chrome_pgid":104816,
  "acquired_at":1720000000, "last_seen_at":1720000123, "connected":true }
```
`owner` is a nested object (`{pid,comm,starttime,cwd}`). `connected` is a JSON
**boolean** (validated `lib/pool.sh:701-702`; reading it must NOT use `jq -e`).

## 2. Helper contracts (the functions `pool_admin_status` composes)

- **`pool_lanes_list`** (`lib/pool.sh:967`): echoes numeric lane stems from
  `$POOL_LANES_DIR/*.json`, sorted `-n`; skips non-numeric (`^[0-9]+$` guard,
  `lib/pool.sh:972`); **always rc 0**. Precondition: `pool_config_init`.
- **`pool_lane_is_stale LANE`** (`lib/pool.sh:1164`): **TRI-STATE** — rc **0=STALE**
  (owner dead/recycled), rc **1=LIVE** (alive+identity match), rc **2=NO-LEASE**
  (missing/corrupt). rc convention INVERTED vs `pool_owner_alive` so
  `if pool_lane_is_stale "$n"; then reap; fi` reads naturally.
- **`pool_lease_read LANE`** (`lib/pool.sh:823`): echoes **raw JSON** (`cat`);
  rc 0 on success; **rc 1** on bad-lane/missing/corrupt; logs ONE warning on
  CORRUPT only (`lib/pool.sh:839`). **CALLERS-under-set-ee MUST guard**
  (`lib/pool.sh:817-820`): `if json="$(pool_lease_read "$lane")"; then …`.
- **`pool_lease_field LANE FIELD`** (`lib/pool.sh:876`): dotted-path read
  (`owner.pid`, `owner.cwd`); rc 0/1; **NO `jq -e`** (exits 1 on `false`)
  → `connected` echoes literal `true`/`false` at rc 0. M7.T1.S1 is a named
  consumer (`lib/pool.sh:858-861`).
- **`_pool_age_str TS`** (`lib/pool.sh:369`): epoch → `Ns/Nm/Nh/Nd`; clamps
  negative→`0s`; **rc 0 always**. (TS must be numeric or `$(( ))` errors.)

## 3. Precondition pattern

`pool_wrapper_main` (`lib/pool.sh:3451`) does step "a" first (`lib/pool.sh:3455-3459`):
```bash
pool_config_init
pool_state_init
```
Both rc-0-or-`pool_die` → no guard. `pool_state_init` `mkdir -p $POOL_LANES_DIR`
guarantees the dir exists. `pool_admin_status` MUST do the same. Global = `POOL_LANES_DIR`.

## 4. Append/convention pattern

Banner = triple `# ===…===` (78 `=`) bracketing `# Section (P1.Mx.Tx.Sx)`
(e.g. `lib/pool.sh:933-935`, `lib/pool.sh:2974-2976`). EOF = `pool_wrapper_main`
closing `}` at `lib/pool.sh:3541`. **No `pool_admin` function exists**
(`grep -n 'pool_admin' lib/pool.sh` → none). New function appended after
`pool_wrapper_main` under banner `# Admin CLI — status (P1.M7.T1.S1)`.

## 5. `set -e` / SC2155 gotchas (all live — `set -euo pipefail` at `lib/pool.sh:23`)

- **(a) SC2155**: never `local x="$(…)"`; declare then assign.
- **(b)** `(( ))` as a STATEMENT returns 1 when result is 0 → fatal under `set -e`;
  keep arithmetic inside `if`/`elif`; `$(( ))` expansion is always safe.
- **(c)** capturing a non-zero-returning fn (pool_lease_read rc 1, pool_lane_is_stale
  rc 1/2) MUST be guarded: `if …; then` or `&& rc=0 || rc=$?`. A bare capture ABORTS.

## 6. STDOUT discipline

`_pool_log` → file+stderr (never stdout); `pool_die` → stderr+exit. So
`pool_admin_status`'s stdout is **purely the table** (pipeable).

## 7. Boundary vs M7.T5.S1

This task = `pool_admin_status()` only (append to lib). It MUST NOT create
`bin/agent-browser-pool` (M7.T5.S1: `case … status) pool_admin_status ;;`).
MUST NOT modify any existing function. Append-only.
