# Recon — Issue #1: Reaper (`pool_reap_orphan_dirs` + `pool_admin_reap`)

Static read-only mapping. No processes/tests run. All line numbers from the
working tree at `/home/dustin/projects/agent-browser-pool`.

## 1. `pool_reap_orphan_dirs()` — `lib/pool.sh:2874-2912`

### Signature + locals (2874-2876)
```bash
pool_reap_orphan_dirs() {
    local d base dir
    local orphans=0
```

### Guard (2878)
```bash
    [[ -d "$POOL_EPHEMERAL_ROOT" ]] || { printf '%s\n' "$orphans"; return 0; }
```

### Loop structure (2880-2910) — VERBATIM
```bash
    for d in "$POOL_EPHEMERAL_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        base="${d%/}"           # strip trailing slash
        base="${base##*/}"      # basename
        [[ "$base" =~ ^[0-9]+$ ]] || continue

        if ! pool_lease_exists "$base"; then
            dir="$POOL_EPHEMERAL_ROOT/$base"
            if pgrep -f -- "user-data-dir=$dir" >/dev/null 2>&1; then
                pkill -f -- "user-data-dir=$dir" 2>/dev/null || true
                sleep 0.2
                pkill -9 -f -- "user-data-dir=$dir" 2>/dev/null || true
            fi
            if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
                rm -rf -- "$dir" 2>/dev/null || true
            fi
            _pool_log "pool_reap(orphan): removed orphan dir $dir (no lease)"
            orphans=$((orphans + 1))
        fi
    done
```

### Tail (2911-2912)
```bash
    printf '%s\n' "$orphans"
    return 0
}
```

## 2. The orphan-kill block — EXACT (the bug)

This is `lib/pool.sh:2898-2902`. Verbatim:

```bash
            if pgrep -f -- "user-data-dir=$dir" >/dev/null 2>&1; then
                pkill -f -- "user-data-dir=$dir" 2>/dev/null || true
                sleep 0.2
                pkill -9 -f -- "user-data-dir=$dir" 2>/dev/null || true
            fi
```

Key facts:
- Inside the `if ! pool_lease_exists "$base"; then … fi` block (line 2892), only for an *unleased* dir.
- Match scope string = `"user-data-dir=$dir"` where `$dir` = `$POOL_EPHEMERAL_ROOT/$base` (full absolute).
- `pgrep -f` / `pkill -f` match as a **regex substring** of `/proc/<pid>/cmdline`.
- Lane numbers are path components → pattern for orphan lane **3** (`…/active/3`) is a substring of lane **30** (`…/active/30`), 31, …, 300, …
- `sleep 0.2` is a fixed sub-second bash builtin (cannot hang).
- `pkill` and `pkill -9` are best-effort (`2>/dev/null || true`).
- NO `wait` of killed Chrome children; NO pgroup kill. Relies on `pkill -f` to reach child processes.

## 3. Variable names + construction

| var   | role                                                            | set at line |
|-------|-----------------------------------------------------------------|-------------|
| `d`   | loop var: raw `"$POOL_EPHEMERAL_ROOT"/*/` entry (TRAILING slash) | 2886 (`for`) |
| `base`| numeric basename of `d`                                         | 2888-2889    |
| `dir` | reconstructed **absolute** path used for kill + rm              | 2893         |
| `orphans` | running count, echoed at end                               | 2876, 2909, 2911 |

Construction chain:
```bash
base="${d%/}"           # strip trailing slash   (2888)
base="${base##*/}"      # basename               (2889)
[[ "$base" =~ ^[0-9]+$ ]] || continue             (2890)
dir="$POOL_EPHEMERAL_ROOT/$base"                  (2893)
```

## 4. `pool_admin_reap()` — `lib/pool.sh:3933-3985`

User-facing wrapper. Only caller of `pool_reap_orphan_dirs` (line 3959).

```bash
pool_admin_reap() {
    local stale_count orphan_count total
    pool_config_init
    pool_state_init
    stale_count="$(pool_reap_stale)"
    orphan_count="$(pool_reap_orphan_dirs)"
    total=$((stale_count + orphan_count))
    # conditional printf of counts
    return 0
}
```

## 5. Test: `selftest_reap_orphan_dirs_removes_and_skips` — `test/validate.sh:826-844`

```bash
selftest_reap_orphan_dirs_removes_and_skips() {
    pool_lease_write 5 "$POOL_EPHEMERAL_ROOT/5" 0 abpool-5 11 pi 9 /x 0 0 false
    mkdir -p "$POOL_EPHEMERAL_ROOT/5"
    mkdir -p "$POOL_EPHEMERAL_ROOT/9"
    mkdir -p "$POOL_EPHEMERAL_ROOT/12"
    local orphans; orphans="$(pool_reap_orphan_dirs)"
    assert_eq "2" "$orphans" "orphan-reap removed 2 orphan dirs" || return 1
    assert_no_dir "$POOL_EPHEMERAL_ROOT/9"   || return 1
    assert_no_dir "$POOL_EPHEMERAL_ROOT/12"  || return 1
    [[ -d "$POOL_EPHEMERAL_ROOT/5" ]] || { _fail "leased orphan dir 5 was removed"; return 1; }
    orphans="$(pool_reap_orphan_dirs)"
    assert_eq "0" "$orphans" "orphan-reap idempotent" || return 1
    rm -rf -- "$POOL_EPHEMERAL_ROOT/5" 2>/dev/null || true
}
```

**GAP**: Creates NO Chrome process → the `pgrep`/`pkill -f` block (2898-2902) is **never exercised**. The orphan Chrome-kill path has zero test coverage.

## 6. Risks for the bugfix

1. The kill block (2898-2902) is unreachable by the existing test. The regression test MUST spawn fake-Chrome processes.
2. `$dir` contains regex metacharacters (`.` in path) — permissive but not unsafe in practice.
3. No pgroup kill / no `wait` — the block diverges from the canonical `pool_chrome_kill` pattern (AGENTS.md §3). Pre-existing; not part of this fix.
