# Research — BUG-004: doctor false-FAILs `[filesystem] not btrfs` on fresh installs

> Target: `pool_admin_doctor`'s `[filesystem]` block in `lib/pool.sh`.
> Fix (fix_design.md §3, CHOSEN design): pre-create the ephemeral root (`mkdir -p … || true`)
> immediately before the `fstype` capture — the `pool_copy_master` pattern, non-fatal variant.

All facts below were verified **live on this host** (2026-08-20, post BUG-003-S2 landing,
`wc -l lib/pool.sh` = **5211**). Line numbers WILL drift — always re-locate by grep, not number.

---

## 1. The bug, reproduced live

```
$ AGENT_CHROME_EPHEMERAL_ROOT=$T/root-gone (nonexistent) ... bash bin/agent-browser-pool doctor
[filesystem]
  /home/dustin/abpool-r7check.Q7pi2w/root-gone FAIL (unknown; not btrfs)   ← FALSE
...
doctor rc=1                                                                ← FALSE
```

Root cause: `findmnt -nno FSTYPE -T <missing-path>` → **rc 1, EMPTY output** (verified).
The `|| true` neutralizes the rc; `fstype=""` falls into the FAIL branch
(`"${fstype:-unknown}"` → "unknown"). On this host `$HOME` **is** btrfs — the probe would
have said `btrfs` had the path existed. The ephemeral root is legitimately absent on a fresh
install: **install.sh pre-creates ONLY the state dir** (`pool_state_init`, install.sh:98);
the ephemeral root is first created by `pool_copy_master` (lib/pool.sh:1336) at first acquire.
install.sh:103-111 then runs doctor as a subprocess → "doctor: found problems" on a healthy
machine. Bare `agent-browser-pool doctor` on a cloned-but-uninstalled tree is equally broken.

## 2. The code today (exact anchors)

- `pool_admin_doctor()` starts at **lib/pool.sh:4856**; locals `local ok=0 warn=0 fail=0` etc.
- The `[filesystem]` block: banner comment **4963-4969**, `printf '[filesystem]\n'` **4970**,
  **fstype capture at 4971**:
  ```bash
  fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
  ```
  then OK / WARN / FAIL branches (**4972-4984**), formats EXACT:
  - `printf '  %-22s OK (btrfs)\n' "$POOL_EPHEMERAL_ROOT"`
  - `printf '  %-22s WARN (%s; slow-copy allowed)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"`
  - `printf '  %-22s FAIL (%s; not btrfs)\n' "$POOL_EPHEMERAL_ROOT" "${fstype:-unknown}"`
  KEEP all three branches + formats byte-identical — the fix only removes the *cause* of the
  empty-string case.
- Re-locate with: `grep -n 'fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"' lib/pool.sh`

## 3. The pattern to mirror (pool_copy_master, lib/pool.sh:1330-1337)

```bash
parent="$(dirname -- "$target_dir")"
mkdir -p -- "$parent" \
    || pool_die "pool_copy_master: cannot create parent dir: $parent"
```

**Doctor's variant must be NON-FATAL**: `mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true`
— doctor NEVER aborts mid-report (that's why it replicates instead of calling the die-ing
helpers). If mkdir genuinely fails (perms/RO-FS), the root stays absent → fstype empty →
FAIL "(unknown; not btrfs)" — now a **true** failure (the documented dir cannot be created),
which is exactly what doctor should report.

Why **pre-create** (fix_design §3, chosen over the ancestor-probe alternative from the PRD
recommendation): repeat runs are exact, the diagnostic self-heals, and `doctor` is an operator
tool — creating the documented default `~/.agent-chrome-profiles/active` dir is safe and
user-visible. fix_design's exact snippet:

```bash
# BUG-004: the ephemeral root may not exist yet on a fresh install (first created by
# pool_copy_master at first acquire). findmnt -T on a MISSING path exits 1 EMPTY →
# false "not btrfs". Mirror pool_copy_master: ensure the dir, then probe it.
mkdir -p -- "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true
```

## 4. Things NOT to touch (verified)

- **`pool_check_btrfs` has been REMOVED** — lib/pool.sh:297: "pool_check_btrfs has been REMOVED
  (dead code — zero call sites; validation issue #5)". The item's "Do NOT touch pool_check_btrfs"
  means: leave the removal alone; do NOT recreate it or "restore" it. The doctor comment block
  references it only as the historical primitive being replicated.
- **install.sh needs NO change** (fix_design §3 chose the doctor-side minimal path): fixing
  doctor fixes both install.sh's step-3 subprocess and bare CLI runs.
- **`pool_copy_master`** — BUG-001/BUG-002 territory (landed, R1-R4 green). Read-only reference.
- **The `[dirs]` section is unaffected**: it already guards `if [[ -d "$POOL_EPHEMERAL_ROOT" ]]`;
  an empty created root → glob `"$POOL_EPHEMERAL_ROOT/*/"` no-match (nullglob NOT set → literal
  → `[[ -d ]]` rejects) → `dir_count=0` → "(no ephemeral dirs)" — the same output as an absent
  root. No output change.
- **`findmnt -T` is MANDATORY** on this host: a bare `findmnt -nno FSTYPE "$dir"` (no -T)
  matches SOURCE not the mount tree and exits 1 even on btrfs (external_deps.md §3.2 omits -T
  and is broken). Keep `-T` verbatim.

## 5. Doctor rc semantics (needed for R7 assertions)

- `ok/warn/fail` counters; WARN never affects rc; `(( fail > 0 ))` → "Problems found." rc 1,
  else "Healthy." rc 0 (summary block ~5108-5120).
- Optional deps (notify-send, ss) print `MISSING (optional…)` with **no fail increment**
  (verified at ~4917-4934) — rc unaffected. Both are present on this host anyway.
- In the bootrace harness env (below), every check except the bug is green:
  deps real + fake-chrome/fake-agent-browser executable, master valid (`$BR_T/master` seeded),
  no lanes, no dirs → doctor rc is 0 **iff** [filesystem] doesn't false-FAIL.

## 6. The bootrace.sh harness (R7's home)

- Header contract: ONE process-spawning setup for the whole suite (`_bootrace_setup`),
  timeout on every subprocess, zero orphans, hermetic (`HOME`/state/ephemeral/config under one
  `mktemp -d`).
- `_bootrace_setup`: `BR_T="$(mktemp -d -p "$HOME" -t abpool-bootrace.XXXXXX)"` — **under the
  REAL `$HOME` → on real btrfs** (this is what makes R7's positive case probe `btrfs`).
  Exports: `HOME=$BR_T/home`, `AGENT_BROWSER_POOL_STATE=$BR_T/state`,
  `AGENT_CHROME_EPHEMERAL_ROOT=$BR_T/active`, `AGENT_CHROME_MASTER=$BR_T/master`,
  `AGENT_CHROME_BIN=$BR_T/bin/fake-chrome`, `AGENT_BROWSER_REAL=$BR_T/bin/fake-agent-browser`,
  **`AGENT_CHROME_ALLOW_SLOW_COPY=1`** ← suite-wide default; R7's FAIL variant must override
  it per-command (`AGENT_CHROME_ALLOW_SLOW_COPY=0` prefix — `_pool_config_bool`: exactly "1" = on).
- Case style (from R5/R6): locals declared up front (`local rc out ... rc_all`); invoke via
  `timeout 30 "$ABPOOL_REPO/bin/agent-browser-pool" <verb>`, capture `|| rc=$?`;
  snapshot observable state BEFORE cleanup; **cleanup unconditional with `|| true`**;
  assertions `_fail "R7: …" || rc_all=1`; end `return "$rc_all"`.
- **R7 needs NO `_br_spawn_owner`** — doctor never consults owner identity (no lane/owner logic
  in its checks); config+state init is done inside doctor itself.
- Per-command env override: a prefix assignment (`AGENT_CHROME_EPHEMERAL_ROOT=x timeout 30 cmd`)
  overrides the exported value for that one subprocess only. This lets R7 point the root at
  `$BR_T/active-missing` / a tmpfs dir without disturbing other cases.
- **Registration is a HARDCODED list** in `_br_run_suite` (bootrace.sh:577-580) — there is NO
  compgen discovery; a case defined but not listed runs never (vacuous green). Current list
  (8 cases, post-R6):
  ```
  r1_bug001_guard_fs_agnostic r2_bug001_recovery_e2e \
  r3_control_delayed_boot_succeeds r3_bug002_race_e2e \
  r3_neg_dead_ids_release_still_kills r4_bug002_preport_race \
  r5_bug003_corrupt_lease_reclaimed r6_bug003_release_corrupt_lease
  ```
  R7 appends `r7_bug004_doctor_fresh_install` → **9 cases**. The case function goes after R6's
  closing `}` and before `_br_run_suite` (~line 575). Header comment already anticipates
  "P1.M2 (R5–R8 minor-bug cases)".
- Sibling work (parallel P1.M2.T1.S2, BUG-003 seam 2) has LANDED: R6 exists, corrupt-release
  branch at lib/pool.sh:4682-4715. Disjoint from this task (release ≠ doctor).

## 7. Host FS facts for the R7 variants

| Path | FSTYPE |
|---|---|
| `$HOME`, `mktemp -d -p "$HOME"` (→ BR_T, root_missing) | **btrfs** |
| `/dev/shm/…` (existing dir) | **tmpfs** (non-btrfs) |
| `/tmp` | tmpfs |

- Missing path probe: `findmnt -nno FSTYPE -T "$T/active-missing"` → rc 1, empty. After
  `mkdir -p` → `btrfs`. ✓ verified.
- Negative control (existing tmpfs): with `AGENT_CHROME_ALLOW_SLOW_COPY=1` →
  `WARN (tmpfs; slow-copy allowed)`; with `=0` → `FAIL (tmpfs; not btrfs)` + rc 1. ✓ verified live.
- grep assertions use `grep -qF -- "$root OK (btrfs)" <<<"$out"` — fixed-string, anchored to the
  full root path (unique; temp roots are >22 chars so `%-22s` doesn't truncate).

## 8. README (Mode-A note)

- `### \`doctor\`` heading at **README.md:275**; first paragraph ends
  "…they do **not** affect the exit code." then "Sections, in order:" block follows.
- Insert ONE sentence per fix_design §3: doctor creates the ephemeral root if absent (so the
  btrfs check is exact on fresh installs). Place at the end of the first paragraph (before
  "Sections, in order:").
- This note RIDES with this subtask so P1.M3.T2.S1 (changeset README sync) doesn't redo it.