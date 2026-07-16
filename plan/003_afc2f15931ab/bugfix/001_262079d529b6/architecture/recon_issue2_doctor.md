# Recon: `pool_admin_doctor()` — `ss` optional-dependency handling (Issue #2)

Static read-only recon of `lib/pool.sh`. All line numbers verbatim from the
current file. Function spans **`lib/pool.sh:4231-4488`** (header docstring
starts at `4138`).

## TL;DR / the bug

The `[dependencies]` loop (`lib/pool.sh:4258-4266`) treats **`ss` as a hard
FAIL dep**, but `ss`'s own inline comment (`lib/pool.sh:4255-4257`) AND its
runtime caller (`pool_find_free_port` `lib/pool.sh:1412-1415`) both declare it
**non-blocking / silently-degrading**. Consequence: on a host without `ss`,
`doctor` prints `ss MISSING`, increments `fail`, and exits `1` ("Problems
found.") — directly contradicting the comment's "no FAIL, no WARN" claim.
`notify-send` (`lib/pool.sh:4292-4299`) is the canonical reference pattern for
an optional dep that `ss` should be aligned to.

## (1) The dependencies loop — EXACT current code

`lib/pool.sh:4258-4266`:

```bash
    for dep in flock setsid pgrep pkill cp curl jq findmnt ss; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf '  %-22s OK\n' "$dep"
            ok=$((ok+1))
        else
            printf '  %-22s MISSING\n' "$dep"
            fail=$((fail+1))
        fi
    done
```

The preceding comment block (`lib/pool.sh:4249-4257`):

```bash
    # Required PATH deps. `command -v` is POSIX-standard + the codebase idiom
    # (_pool_alert lib/pool.sh:2824); preferred over `which` (ShellCheck SC2230).
    # rc 1 (absent) MUST be inside `if` (a bare call ABORTS under set -e).
    # Deps beyond the core set (Issue #7):
    #   findmnt — used by pool_check_btrfs + this doctor's own btrfs probe (missing → empty
    #            fstype, surfaces indirectly as a btrfs FAIL; naming it is more honest).
    #   ss      — used by pool_find_free_port (ss -tlnH) for port allocation. Absence
    #            degrades SILENTLY to a curl-only probe (the || true empty-snapshot path);
    #            no FAIL, no WARN → name it so the operator can see the degradation.
```

**Contradiction:** the comment for `ss` says *"no FAIL, no WARN"* but the loop
body does `fail=$((fail+1))` unconditionally for **every** dep, including `ss`.

Note: `findmnt` is intentionally left as FAIL (its comment justifies it — its
absence surfaces indirectly as a btrfs FAIL anyway). Only `ss` is over-counted.

## (2) The docstring / severity model (header) — `ss` status

### SEVERITY MODEL — `lib/pool.sh:4163-4172`

```bash
# SEVERITY MODEL (FAIL = blocking infra; WARN = recoverable lane/dir cruft):
#   FAIL (exit 1): missing required dep; $POOL_REAL_BIN not executable; non-btrfs (no
#                  slow-copy); master missing/empty.
#   WARN (exit 0): non-btrfs + slow-copy; LEAK (no dir / dead chrome); DISCONNECTED;
#                  daemon disconnected (lease connected:false); ORPHAN DIR; PROVISIONAL
#                  lease; corrupt/unreadable lease.
#   (not counted): notify-send MISSING (optional).
```

Key observation: the severity model lists only **notify-send** under
"(not counted)". `ss` is **NOT mentioned** in the severity model header.

### LOGIC contract `a` — `lib/pool.sh:4145-4149`

```bash
#   a. DEPS        — command -v each required dep {flock, setsid, pgrep, pkill, cp,
#                    curl, jq} + the Chrome binary ($POOL_CHROME_BIN, name-or-path) +
#                    the OPTIONAL notify-send. Required MISSING → FAIL; notify-send
#                    MISSING → "(optional)", NOT counted.
```

This `a.` bullet names only the **core 7** deps as "required" and lists
**notify-send** as the single OPTIONAL dep. `findmnt` and `ss` are absent.

### RETURN-CODE contract — `lib/pool.sh:4209`

```bash
#   - RETURN CODES: rc 0 iff fail==0; rc 1 iff fail>0. WARN NEVER affects rc.
```

Because `ss MISSING` increments `fail` today, it currently drives the exit code to 1.

## (3) How `notify-send` is handled — the reference pattern for optional deps

`lib/pool.sh:4292-4299` (immediately after the Chrome check):

```bash
    # notify-send — OPTIONAL (PRD §2.16; _pool_alert guards it lib/pool.sh:2824).
    # Absence is NOT a FAIL (and NOT a WARN) — it is genuinely fine to lack it.
    if command -v notify-send >/dev/null 2>&1; then
        printf '  %-22s OK\n' "notify-send"
        ok=$((ok+1))
    else
        printf '  %-22s MISSING (optional)\n' "notify-send"
    fi
```

The pattern: OK branch = `printf` + `ok++`. MISSING branch = `printf` with `(optional)` — NO `fail++`.
It is a separate `if command -v` block, **outside** the shared `for dep in …` loop.

## (4) Why `ss` is genuinely non-blocking (runtime evidence)

`pool_find_free_port` snapshots listeners with `|| true` fallback (`lib/pool.sh:1412-1416`):

```bash
    listeners="$(ss -tlnH 2>/dev/null || true)"
```

A missing `ss` → empty `listeners` → per-port `grep ":$port "` never matches →
the live `curl /json/version` probe is the real guard. Pool port allocation
works without `ss`.

## (5) Summary / exit-code logic at the end of doctor

`lib/pool.sh:4476-4488`:

```bash
    printf '[summary]\n'
    printf '  OK=%d  WARN=%d  FAIL=%d\n' "$ok" "$warn" "$fail"
    if (( fail > 0 )); then
        printf '  Problems found.\n'
        return 1
    fi
    printf '  Healthy.\n'
    return 0
```

Contract: **rc 0 iff `fail==0`; rc 1 iff `fail>0`. WARN never affects rc.**

## Suggested fix shape

1. **Remove `ss` from the uniform-FAIL `for` loop** (`lib/pool.sh:4258`) — change to
   `for dep in flock setsid pgrep pkill cp curl jq findmnt; do`. Keep `findmnt` IN the loop.
2. **Add a dedicated `ss` block** after the loop, using the notify-send pattern:
   ```bash
   if command -v ss >/dev/null 2>&1; then
       printf '  %-22s OK\n' "ss"
       ok=$((ok+1))
   else
       printf '  %-22s MISSING (optional; port-probe degrades to curl-only)\n' "ss"
   fi
   ```
3. **Update the docstring** so the model is internally consistent:
   - `lib/pool.sh:4169` "(not counted): notify-send MISSING (optional)." → add `ss`.
   - `lib/pool.sh:4176` OUTPUT line `MISSING = FAIL, except notify-send` → `except notify-send and ss`.
   - `lib/pool.sh:4145-4149` `a.` bullet → add `ss` to the OPTIONAL list.
   - `lib/pool.sh:4178` [dependencies] OUTPUT → add `ss` row.

## Risks

- **No test pins the current ss-as-FAIL behavior**: none of the 4 test files assert doctor's
  `[dependencies]` output or exit code for `ss`/`findmnt`. Aligning `ss` to optional will not
  break an existing assertion, but also no test catches a regression — consider adding one.
- **`findmnt` deliberately stays FAIL** per its own comment — the fix must NOT move `findmnt`.
