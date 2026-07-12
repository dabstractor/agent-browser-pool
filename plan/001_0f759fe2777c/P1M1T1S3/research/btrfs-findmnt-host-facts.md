# Research: btrfs detection, state-dir setup, and findmnt semantics on THIS host

> Scope: the three functions P1.M1.T1.S3 must deliver — `pool_state_init()`,
> `pool_check_btrfs()`, `pool_check_master()` — appended to `lib/pool.sh` after
> `pool_config_init()` (P1.M1.T1.S2). All findings verified by running commands on
> the target host (2026-07-12).

---

## Summary

1. **`findmnt -T` (a.k.a. `--target`) is MANDATORY** for detecting the filesystem of a
   *directory path*. The `external_deps.md §3.2` snippet omits `-T` and is **BROKEN on
   this host** (it returns exit 1 on an existing btrfs dir). `pool_check_btrfs` MUST use
   `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"`.
2. **`findmnt -T` exits 1 when the target path does not exist.** It does NOT walk up to
   the nearest existing ancestor. So `pool_check_btrfs` must treat an empty/missing
   FSTYPE result as "not btrfs" and die (unless slow-copy is allowed). This is the
   correct, safe behavior — the ephemeral root MUST exist for CoW to work anyway.
3. **The state dir does NOT exist yet** (verified: `ls ~/.local/state/agent-browser-pool`
   → "No such file or directory"). `mkdir -p` is idempotent (safe to call repeatedly);
   `touch` is idempotent on an existing file. So `pool_state_init()` can be called every
   acquire with no special guard.
4. **`master-profile` exists and is 4.8 GB** (verified). It is NOT a btrfs subvolume — it
   is a plain directory ON btrfs. `findmnt -T` on it correctly reports `btrfs` because
   it walks up to the `/home` mount. (This is why `-T` matters: it finds the mount the
   path lives on, not the path itself.)
5. **The exact `cp` command** the error message in `pool_check_master` should print is
   derived from PRD §2.7 line 182 and §1.2: the master is created by the user **once** by
   copying a configured Chrome profile with `--reflink=always`. PRD §2.14 line 267
   mandates "fail with the exact `cp` command to create it".

---

## Host-verified facts (commands run 2026-07-12)

### Fact 1: `findmnt -T` is required; bare `findmnt <dir>` is broken

```
$ findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles"
btrfs                                       # exit 0  ✓

$ findmnt -nno FSTYPE "$HOME/.agent-chrome-profiles/active"   # NO -T
                                            # exit 1  ✗ (empty output!)
```

**Why:** `findmnt` without `-T`/`--target` treats the positional arg as a **source
(device)** specifier, not a mount target. A directory path is not a device, so it prints
nothing and exits 1. This is the single most important gotcha for this subtask — the
architecture doc (`external_deps.md §3.2`) example omits `-T` and would silently fail,
making `pool_check_btrfs` always die with "not btrfs" even on btrfs.

**References:**
- `findmnt(1)`, "Target column" / `--target` description:
  > "Display all filesystems containing the specified file (or directory)."
  This is the documented behavior: WITHOUT `-T`, the arg is matched against
  **SOURCE**, not the mount tree.
- util-linux source: `findmnt` maps a bare positional arg to `srcstr` (source filter),
  not `tgtstr` (target filter).

### Fact 2: `findmnt -T` on a NONEXISTENT path exits 1

```
$ findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles/active-fake"; echo $?
1                                           # exit 1, empty output
$ findmnt -nno FSTYPE -T "/nonexistent/whatever"; echo $?
1                                           # exit 1, empty output
```

**Implication:** If an operator sets `AGENT_CHROME_EPHEMERAL_ROOT` to a dir that doesn't
exist yet, `pool_check_btrfs` sees an empty FSTYPE and dies "not btrfs (got: )". This is
*correct* defensive behavior — the ephemeral root must exist before CoW copy, so failing
early with a clear message is better than a cryptic `cp` error later. The error message
should mention both possibilities (non-btrfs OR missing) so the operator knows what to
check. PRD §2.11 + system_context §8 confirm the default `active/` exists on this host.

### Fact 3: `findmnt -T` on an EXISTING file/dir inside the mount reports the mount's FSTYPE

```
$ findmnt -nno FSTYPE -T "$HOME/.agent-chrome-profiles/master-profile"
btrfs                                       # exit 0
$ findmnt -no FSTYPE,TARGET,SOURCE -T "$HOME/.agent-chrome-profiles/active"
btrfs /home /dev/nvme1n1p2[/@home]          # shows the real mount
```

**Implication:** `findmnt -T "$POOL_EPHEMERAL_ROOT"` correctly reports the filesystem of
the *mount that path lives on*, which is exactly what the btrfs-CoW decision needs. Works
whether the ephemeral root is the mount point itself or a subdir of it.

### Fact 4: State dir does NOT exist; `mkdir -p` + `touch` are idempotent

```
$ ls -la "$HOME/.local/state/agent-browser-pool"
ls: cannot access '/home/dustin/.local/state/agent-browser-pool': No such file or directory

$ tmp=$(mktemp -d); mkdir -p "$tmp/sub/deep"; mkdir -p "$tmp/sub/deep"; echo "mkdir -p twice OK"
mkdir -p twice OK
$ tmp2=$(mktemp); touch "$tmp2"; touch "$tmp2"; echo "touch twice OK"
touch twice OK
```

**Implication:** `pool_state_init()` is a plain `mkdir -p "$POOL_LANES_DIR"; touch
"$POOL_LOCK_FILE"`. No guard, no "if not exists" check — both are idempotent by design.
Safe to call on every acquire.

### Fact 5: `master-profile` is a 4.8 GB plain directory on btrfs

```
$ du -sh "$HOME/.agent-chrome-profiles/master-profile"
4.8G	/home/dustin/.local/.agent-chrome-profiles/master-profile
```

**Implication for `pool_check_master()`:** Check two things — (a) the dir exists
(`-d`), (b) it is non-empty (so a stray `mkdir` without copy doesn't pass). Do NOT check
size (4.8 GB stat is slow) and do NOT check for specific files (the contents are a full
Chrome profile; coupling to specific filenames is brittle). A simple `-d && non-empty`
test is the right granularity.

---

## The exact `cp` command for the `pool_check_master` error message

PRD §2.14 mandates: "master-profile missing | acquire precheck | fail with the **exact
`cp` command** to create it." The command must use the pool's own resolved paths
(`$POOL_MASTER_DIR`) and the btrfs reflink flag so a copy-paste-run works. Derived from
PRD §2.7 line 182 (`cp -a --reflink=always <master> <active/N>`) and §1.2 ("you create
once"):

```
# To create the master template (run ONCE), copy a configured Chrome profile:
cp -a --reflink=always <your-configured-chrome-profile> "$POOL_MASTER_DIR"
```

The function should print `$POOL_MASTER_DIR` literally (already resolved to absolute by
`pool_config_init`), and instruct the user to point the source at an existing Chrome
profile they have configured (e.g. their daily driver, or a throwaway they set up). Keep
the message actionable: state the missing path, then the command.

---

## Strict-mode considerations (carried forward from S1 + S2)

The lib propagates `set -euo pipefail`. For this subtask:

- **`findmnt` exits 1 on missing/non-btrfs** — capture it in a way that does NOT abort
  under `set -e`. The idiomatic, SC2155-clean pattern:
  ```bash
  local fstype
  fstype="$(findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT" 2>/dev/null || true)"
  ```
  The `|| true` neutralizes the non-zero exit so `set -e` doesn't fire; `fstype` becomes
  empty string, which the subsequent `[[ ]]` test treats as "not btrfs".

- **`mkdir -p` / `touch` failing** would be a real filesystem error (not normal) — let
  those propagate via `pool_die` with a clear message rather than `|| true`.

- **`[[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]`** is the non-empty-dir
  test. The `ls -A` returns non-zero on an empty dir; wrap so `set -e` doesn't fire:
  ```bash
  if [[ ! -d "$POOL_MASTER_DIR" ]] || [[ -z "$(ls -A "$POOL_MASTER_DIR" 2>/dev/null)" ]]; then
      pool_die "..."
  fi
  ```
  Using `ls -A` (not `ls`) avoids the `.`/`..` entries; capturing in `$(...)` and testing
  with `-z`/`-n` is robust.

- **No `readonly`, no `declare -g`** — these functions READ `POOL_*` globals set by
  `pool_config_init`; they do not define any globals of their own. (Consistent with S2's
  "globals live in pool_config_init" decision.)

- **All expansions quoted**, all `local` captures split into two statements (SC2155).

---

## What these functions must NOT do (scope guards)

- Do NOT create the ephemeral root or the master dir (those are operator/install
  responsibilities; system_context §7-8 confirm master exists, active/ exists).
- Do NOT validate Chrome, ports, or real-bin (that's config, done in S2).
- Do NOT acquire flock, read leases, or reap stale lanes (that's M3/M5).
- Do NOT perform the CoW copy or SingletonLock cleanup (that's M4.T1.S1). These functions
  are the **precheck** layer that runs *before* any of that.
- Do NOT log via `_pool_log` on success (config/precheck noise would pollute every
  acquire); DO use `pool_die` on fatal failures so the error reaches stderr. (Logging of
  alerts is M5.T4.S1's job.)

---

## References

- `findmnt(1)` man page — `--target`/`-T` semantics: "display all filesystems containing
  the specified file (or directory)". util-linux.
- PRD.md §2.7 (copy/master hygiene), §2.14 (failure modes table, lines 266-267),
  §2.11 (discovery & configuration — `AGENT_CHROME_ALLOW_SLOW_COPY`).
- plan/001_0f759fe2777c/architecture/external_deps.md §3.1–§3.3 (copy command, btrfs
  detection — **note §3.2's missing `-T` is a bug; see Fact 1 above**), §5 (config vars).
- plan/001_0f759fe2777c/architecture/system_context.md §7 (state dir layout, not yet
  created), §8 (ephemeral layout, master = 4.8 GB, active/ exists & empty).
- plan/001_0f759fe2777c/P1M1T1S2/PRP.md — the CONTRACT for `POOL_EPHEMERAL_ROOT`,
  `POOL_MASTER_DIR`, `POOL_STATE_DIR`, `POOL_LANES_DIR`, `POOL_LOCK_FILE`,
  `POOL_ALLOW_SLOW_COPY` (all guaranteed absolute, validated, present after
  `pool_config_init`).
