# Research — P1.M4.T1.S1: `pool_copy_master(target_dir)` (btrfs reflink + Singleton cleanup)

Host: `/home` + `$HOME` = **btrfs** (`/dev/nvme1n1p2`); `/tmp` = **tmpfs**. All findings below
are **host-verified 2026-07-12** by running the exact commands against the real library.

---

## §0. Empirical verification matrix (all PASSED)

The full prototype function (identical body to the PRP's) was sourced on top of the LANDED
`lib/pool.sh` (so it composes the real `pool_check_master`, `pool_die`, `_pool_log`) and run
against a test master containing `Preferences`, `Default/Cookies`, and the three
`Singleton*` files (SingletonSocket created as a real AF_UNIX socket). Results:

| Scenario | target FS | ALLOW_SLOW_COPY | Result | Verified |
|---|---|---|---|---|
| **A** reflink happy path | btrfs (`$HOME/.abpool_test/active/1`) | 0 (unset) | rc 0, **0.017 s** (instant CoW), flat copy, **all 3 Singleton* removed** (incl. the unix socket) | ✅ |
| **B** tmpfs + no escape | tmpfs (`/tmp/.../1`) | 0 (unset) | **pool_die**, msg names `tmpfs`, **partial empty dir cleaned up** (rm -rf worked) | ✅ |
| **C** tmpfs + slow-copy escape | tmpfs (`/tmp/.../2`) | 1 | rc 0, **fell back to `cp -a`**, **FLAT copy** (no nesting), Singleton* removed | ✅ |
| **E** missing master | n/a | n/a | `pool_check_master` **pool_die** with the EXACT bootstrap `cp -a --reflink=always …` command | ✅ |
| empty target_dir arg | n/a | n/a | `pool_die: empty target_dir` | ✅ |
| relative target_dir arg | n/a | n/a | `pool_die: target_dir must be absolute: relative/1` | ✅ |

Plus: `bash -n` CLEAN, `shellcheck -s bash` CLEAN on the function body.

---

## §1. The FOUR `cp` gotchas (the heart of this task — all empirically confirmed)

### §1.1 Reflink stderr FLOODS on non-btrfs (one line per file)
On tmpfs, `cp -a --reflink=always src dst` emits one
`cp: failed to clone '<f>' from '<f>': Operation not supported` line **per source file** and
exits rc 1. A real Chrome master is ≈ 4.8 GB across **thousands** of files → thousands of
stderr lines per failed acquire. **MUST suppress**: `cp -a --reflink=always … 2>/dev/null`.
Verified: 3-file source → exactly 3 stderr lines.

### §1.2 Reflink failure leaves an EMPTY PARTIAL target dir
Before failing on the first content file, `cp` **creates the target directory** (empty,
`total 0`). Verified: after a failed reflink on tmpfs, `dst/` existed with zero files. This
matters for the retry (§1.3) and means the caller's "is lane N free?" probe (`[[ -d … ]]`)
would see a phantom dir. **MUST `rm -rf -- "$target_dir"` on reflink failure** before any
retry or return.

### §1.3 NESTING HAZARD — `cp -a src dst` when dst already exists
`cp -a src dst` semantics depend on whether `dst` exists:
- **dst ABSENT** → `dst` becomes a copy of `src`; `src`'s contents appear **directly under**
  `dst` (verified: `cp -a n_src n_dst` → `n_dst/file.txt`). This is what we WANT.
- **dst EXISTS as a dir** → `src` is copied **INTO** `dst`: result `dst/<basename src>/…`
  (verified: `cp -a n_src n_dst` → `n_dst/n_src/file.txt`). This is the **WRONG** layout —
  the ephemeral profile would be at `active/1/master-profile/…` instead of `active/1/…`.

Because §1.2 guarantees a failed reflink leaves `dst` existing, a naive retry `cp -a src dst`
would **nest**. The fix is mandatory: `rm -rf -- "$target_dir"` (§1.2 cleanup) **before** the
slow retry. Scenario C verified the retry then produces a FLAT copy.

### §1.4 `cp -a` source-into-absent-dst = FLAT copy (the correct layout)
Confirmed in scenario A and C: `cp -a --reflink=always master-profile active/1` (1 absent) →
`active/1/Preferences`, `active/1/Default/Cookies`, … i.e. the ephemeral dir **IS** the
profile (Chrome's `--user-data-dir=active/1` resolves correctly). This matches the contract's
literal `cp -a --reflink=always "$POOL_MASTER_DIR" "$target_dir"` and PRD §1.2.

---

## §2. The `set -e` + subshell hazard for TESTING pool_die (CRITICAL for validation cmds)

`pool_die` does `exit 1`. Functions run in the **current shell** (not a subshell) unless
invoked in a pipeline or explicit `( … )`. So a validation script that does:

```bash
source lib/pool.sh; pool_copy_master "/tmp/non-btrfs/1"   # pool_die → exit 1
echo "reached?"                                            # NEVER runs
```

**kills the whole script** at the `pool_die` (verified: my first test harness died at
scenario B before printing scenarios C/E). Every validation command that EXPECTS a pool_die
MUST wrap the call in a **subshell** and capture its exit:

```bash
( source lib/pool.sh; …; pool_copy_master "/tmp/.../1" ) >/tmp/out 2>/tmp/err
rc=$?; [[ "$rc" == 1 ]] && echo OK || echo FAIL
```

The happy-path (rc 0) and slow-copy (rc 0) scenarios do NOT need the subshell (no exit).
This is the SAME hazard family as the caller-side `set -e` notes in the S2/S3 PRPs, but on
the *test author* side here.

---

## §3. Composition decision: what does `pool_copy_master` call?

### §3.1 `pool_check_master` (M1.T1.S3, LANDED @266) — YES, compose it (pre-check)
**Decision: call `pool_check_master` as the FIRST step.** Rationale:
- The contract says "die on failure". The #1 reason `cp --reflink=always` would fail on a
  *btrfs* host (where reflink works) is a **missing/empty master**. Without the pre-check,
  that surfaces as a confusing "cp --reflink=always failed" message. `pool_check_master`
  dies with the **exact PRD §2.14 bootstrap command** (`cp -a --reflink=always
  <your-chrome-profile> "$POOL_MASTER_DIR"`) — far better UX (verified scenario E).
- It is **idempotent + cheap** (one `-d` + one `ls -A`; no `du`/`stat` of the 4.8 GB).
- It does NOT conflict with the contract steps (a-e); it is a defensive precondition guard
  that strengthens "die on failure" without altering the cp logic.
- If the consumer (M5.T1.S2) ALSO calls it, the second call is a no-op (master exists → rc 0).

Contract for `pool_check_master` (LANDED): `[[ -d $POOL_MASTER_DIR ]] && [[ -n $(ls -A …) ]]`
→ rc 0; else `pool_die` with the bootstrap command. Relies on `POOL_MASTER_DIR` (frozen by
`pool_config_init`). No new globals.

### §3.2 `pool_check_btrfs` (M1.T1.S3, LANDED @230) — NO, do NOT compose it
**Decision: do NOT call `pool_check_btrfs` inside `pool_copy_master`.** Rationale:
- The contract's detection mechanism IS the `cp --reflink=always` failure (steps a-c).
  `pool_check_btrfs` would *pre-empt* that and `pool_die` before cp even runs — redundant
  with the contract's own branch, and it checks `POOL_EPHEMERAL_ROOT` (the root), not the
  per-lane target.
- `pool_check_btrfs` is the acquire-init gate (called once at the top of acquire, M5.T1.S1,
  per its docstring "refuse a non-btrfs ephemeral root"). It is NOT this function's job.
- We DO reuse `pool_check_btrfs`'s `findmnt -nno FSTYPE -T` technique (§4) **purely to report
  the fstype in the die message** on the failure branch — but as a raw one-off, not the
  function call (we want our own message, not its `pool_die`).

### §3.3 What `pool_copy_master` therefore composes (final)
- `pool_check_master` (LANDED) — pre-check, gives the bootstrap-cmd error.
- `pool_die` (LANDED) — error exit.
- `_pool_log` — NOT called (the function succeeds silently; on failure `pool_die` is the
  signal). Matches the "no log on happy path" convention of `pool_state_init`.
- Raw `cp`, `rm`, `mkdir`, `findmnt` — the contract's literal tools (external_deps §3, §4).

---

## §4. The `findmnt -T` gotcha (reused from pool_check_btrfs)

Inside the failure branch we report the fstype for a clear message:
`fstype="$(findmnt -nno FSTYPE -T "$parent" 2>/dev/null || true)"`.
**The `-T` (--target) flag is MANDATORY.** A bare `findmnt -nno FSTYPE "$dir"` (no -T)
matches the positional arg against SOURCE (a device), not the mount tree, and **exits 1 on
this host EVEN ON btrfs** — documented in the LANDED `pool_check_btrfs` docstring and
`P1M1T1S3/research/btrfs-findmnt-host-facts.md`. `external_deps.md §3.2`'s example OMITS
`-T` and is BROKEN — do not copy it. Verified in scenario B: `-T /tmp/...` → `tmpfs` (exit 0).

`|| true` neutralizes findmnt's legitimate exit 1 (missing path) so `set -e` (propagated by
lib/pool.sh line 14) does not abort the message construction. Empty fstype → `<unknown>`.

---

## §5. Singleton* file types — `rm -f` handles ALL three

Chrome's single-instance files in a user-data-dir:
- `SingletonLock` — regular file (holds pid). `rm -f` ✓
- `SingletonCookie` — regular file. `rm -f` ✓
- `SingletonSocket` — **AF_UNIX socket** (verified: created one, `ls -l` shows `srwxr-xr-x`).
  `rm -f` removes a socket just like a file ✓ (verified in scenario A: the socket was gone
  after the copy+cleanup).

All three are removed with one `rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie"
"$target_dir/SingletonSocket"`. `-f` (force) is correct: in a cleanly-built master some may
not exist; `-f` does not error on a missing file. The three names are FIXED (no globs), so
there is no risk of `rm` sweeping unintended files. PRD §2.7 / external_deps §3.3 mandate
exactly these three.

These come from the **template** (the master was created by copying a real, once-launched
Chrome profile). If they survived into an ephemeral lane, a launched Chrome would think
another instance already owns the dir → it would either refuse to start or attach to the
stale owner. Removing them per-acquire is mandatory (PRD §2.7).

---

## §6. Naming, banner, placement

**Function name: `pool_copy_master`** — the CONTRACT body literally says "Implement
`pool_copy_master(target_dir)`" (the work-item title echoes it). Honor the contract verbatim
(same principle as the S3 PRP honoring `pool_lane_is_stale` over the title's `is_lane_stale`).

NOTE: `key_findings.md`'s naming *recommendation* table puts "copy, launch, connect, teardown"
under `pool_lane_*`. This function is `pool_copy_master`, NOT `pool_lane_copy`. The
contract overrides the recommendation (the recommendation is explicitly a "recommendation";
the contract + the consumer reference M5.T1.S2 are law). The consumer (M5.T1.S2 post-lock
boot) references `pool_copy_master`. Do NOT rename.

**Banner** (new section — this is the FIRST M4 task):
```
# =============================================================================
# Lane lifecycle — master copy & profile hygiene (P1.M4.T1.S1)
# =============================================================================
```
This opens the "Lane lifecycle" group that M4.T2 (port + launch) and M4.T3 (connect +
teardown) will continue. Follows the exact banner style of the M3 sections.

**Placement: APPEND at EOF**, directly after `pool_lane_is_stale`'s closing brace. The file
is currently **1197 lines** (P1.M3.T2.S3 LANDED — `pool_lane_is_stale` is the last function).
`grep -nE '^pool_lane_is_stale\(\)' lib/pool.sh` locates it; append the banner + function
after its `}`. Do NOT touch any existing function.

---

## §7. The contract logic a→e → verified implementation mapping

| Contract step | Implementation (verified) |
|---|---|
| (a) `cp -a --reflink=always "$POOL_MASTER_DIR" "$target_dir"` | `cp -a --reflink=always -- "$POOL_MASTER_DIR" "$target_dir" 2>/dev/null` (suppress per-file flood; `--` defensive) |
| (b) cp fails AND not btrfs AND `POOL_ALLOW_SLOW_COPY != 1` → die | on `if ! cp …`: `rm -rf -- "$target_dir"` (kill partial); then `if [[ "$POOL_ALLOW_SLOW_COPY" == "1" ]]` (→ §c) **else** `pool_die` with fstype from `findmnt -T`. On btrfs reflink does NOT fail, so reaching here ⟹ non-btrfs or a real error; either way die (slow-copy off). |
| (c) cp fails AND `POOL_ALLOW_SLOW_COPY == 1` → retry `cp -a` | after `rm -rf`: `if ! cp -a -- "$POOL_MASTER_DIR" "$target_dir"; then pool_die "slow copy also failed"` |
| (d) after success: `rm -f` the three Singleton* | `rm -f -- "$target_dir/SingletonLock" "$target_dir/SingletonCookie" "$target_dir/SingletonSocket"` |
| (e) return 0 / die on failure | `return 0` at end; all failure paths `pool_die` |

**Defensive additions beyond the literal contract (justified for one-pass success):**
1. `pool_check_master` pre-check (§3.1) — best-effort error message.
2. `[[ -n "$target_dir" ]]` + `[[ "$target_dir" == /* ]]` guards — PRD §2.2 (no bare `~` /
   relative paths handed to `cp`/`rm`); path-safety for the `rm -rf`.
3. `mkdir -p -- "$(dirname -- "$target_dir")"` — `cp` needs the parent (the ephemeral root)
   to exist; on a first run it may not (mirrors `pool_state_init`'s "just works" creation).
4. `rm -rf -- "$target_dir"` on reflink failure (§1.2/§1.3) — kills the empty partial + kills
   the nesting hazard for the slow retry. NOT optional.

All globals read are frozen by `pool_config_init`: `POOL_MASTER_DIR`, `POOL_ALLOW_SLOW_COPY`.
No new globals, no new env vars, no new files.

---

## §8. Consumer contract (for M5.T1.S2 — NOT built here)

`pool_copy_master` is consumed by the **acquire post-lock boot** (M5.T1.S2, "copy + port +
launch + connect + update lease"). The call site runs AFTER the flock critical section is
released (key_findings FINDING 2: keep flock short; the ~instant reflink copy is fine outside
the lock). Contract this function provides to the caller:

```
pool_copy_master "$target_dir"
# rc 0 → target_dir is a flat, lock-cleaned, ready-to-launch Chrome profile.
# any failure → process exits 1 via pool_die (the caller never sees a bad dir).
```

The caller passes `target_dir="$POOL_EPHEMERAL_ROOT/$N"` (N from `pool_find_free_lane`,
M3.T2.S2). Because `pool_copy_master` mkdir's the parent and cleans partials, the caller need
only ensure `pool_config_init` has run. `pool_check_btrfs` (the root-level gate) is expected
to have been called by the acquire *init* path (M5.T1.S1), not here.
