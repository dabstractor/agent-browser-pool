# Reference implementation: four internal pool.sh helpers

Paste-ready function definitions for `_pool_atomic_write`, `_pool_json_valid`,
`_pool_now`, and `_pool_age_str`. These are APPENDED to `lib/pool.sh`
(which already has `set -euo pipefail` and `pool_die` / `_pool_log`).

## 1. Function definitions

```bash
# _pool_atomic_write FILEPATH CONTENT
#   Write CONTENT to FILEPATH atomically: write to FILEPATH.tmp (same directory
#   as the target, so the tmp file is on the SAME FILESYSTEM) then `mv` it over
#   the target. `mv` (rename(2)) is atomic on the same filesystem — a reader
#   never sees a half-written file. GOTCHA: the tmp file MUST live in the same
#   directory as the target; a tmpfile in /tmp would be a cross-FS move
#   (non-atomic copy + unlink), defeating the purpose. PRAGMATIC CAVEAT: we do
#   NOT fsync (no `sync` of the tmp file nor its parent dir), so a power-loss
#   crash between the write and the rename could lose data — acceptable here
#   because this guards a short-lived pool lease, not a durable database.
_pool_atomic_write() {
    local filepath="$1" content="${2:-}"
    local tmp
    tmp="${filepath}.tmp"
    # printf into the tmp; on write failure, rm the partial tmp before dying so
    # a stale .tmp never blocks a later acquire. The `if` makes the write
    # failure a controlled branch (not a set -e abort), so we reach the cleanup.
    if ! printf '%s' "$content" >"$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        pool_die "_pool_atomic_write: cannot write tmp file: $tmp"
    fi
    # `mv` is the atomic-publish step. `mv` failure is fatal — die and leave
    # the tmp in place for inspection (do NOT blindly rm it; it is our evidence).
    mv -f -- "$tmp" "$filepath" \
        || pool_die "_pool_atomic_write: cannot rename tmp into place: $tmp -> $filepath"
}

# _pool_json_valid FILEPATH — predicate: is FILEPATH valid JSON?
#   Returns 0 (valid) / 1 (invalid, missing, or unreadable). MUST NOT call
#   pool_die — it is a boolean predicate, not an error path. GOTCHA: `jq empty`
#   legitimately exits 1 on malformed JSON; under `set -e` a bare `jq empty
#   "$f"` would abort the whole script, so we wrap it in `if`. jq's parse-error
#   stderr is discarded to /dev/null so malformed-JSON noise never leaks out.
_pool_json_valid() {
    local filepath="$1"
    if jq empty "$filepath" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# _pool_now — echo the current Unix epoch (seconds since 1970) via `date +%s`.
#   No args. Pure digit string on stdout. GOTCHA: none significant; `date +%s`
#   exits 0 reliably and prints only digits + newline.
_pool_now() {
    date '+%s'
}

# _pool_age_str TIMESTAMP — echo a human-readable age for an epoch-seconds ts.
#   Picks the LARGEST whole unit: <60s -> "Ns", <3600s -> "Nm", <86400s -> "Nh",
#   else "Nd". A future/negative diff (clock skew, bogus ts) clamps to "0s".
#   GOTCHA: bare `(( ))` that evaluates to 0 returns exit status 1, which is
#   FATAL under `set -e`. Every arithmetic is therefore inside `if (( ))` or
#   guarded by `|| true`, never a bare top-level `(( expr ))`.
_pool_age_str() {
    local ts="$1"
    local now diff
    now="$(date '+%s')"
    diff=$(( now - ts ))
    # Clamp negatives (future timestamp / clock skew) to 0s.
    if (( diff < 0 )); then
        diff=0
    fi
    if (( diff < 60 )); then
        printf '%ss\n' "$diff"
    elif (( diff < 3600 )); then
        printf '%sm\n' "$(( diff / 60 ))"
    elif (( diff < 86400 )); then
        printf '%sh\n' "$(( diff / 3600 ))"
    else
        printf '%sd\n' "$(( diff / 86400 ))"
    fi
}
```

## 2. Strict-mode notes

- **`set -e` vs. predicates & arithmetic:** `_pool_json_valid` and `_pool_age_str` wrap every command whose non-zero status is a *signal*, not a failure, in `if …; then` / `|| true`. A bare `jq empty "$badfile"` or a bare `(( expr ))` evaluating to 0 would otherwise abort the whole caller shell. No predicate ever calls `pool_die`.
- **`set -u` (nounset):** every expansion is either a positional that the function reads (`$1`, `${2:-}`) or a `local` assigned before use. No unquoted `$*`-style expansion; `${2:-}` / `${1:-}` style is used where an arg may legitimately be absent.
- **`set -o pipefail`:** none of these helpers use a pipeline, so there is no masked mid-pipe failure to worry about. (`_pool_now` is a single `date`, `_pool_json_valid` a single `jq`.)
- **SC2155 (declare-and-assign):** every `local` is declared alone, then assigned on the next statement — `local x; x="$(…)"` — never `local x="$(…)"`.
- **SC2086 (word-splitting):** all variable expansions are double-quoted (`"$filepath"`, `"$content"`, `"$tmp"`, `"$diff"`, etc.).
- **Output portability:** output goes through `printf '%s\n' …` / `printf '%s' …`, never bare `echo`, so values beginning with `-n` / `-e` are not reinterpreted.

## 3. Quick self-test

Run from a shell that has sourced `lib/pool.sh` (so `pool_die`, `pool_config_init`, etc. are present). Each line is self-contained:

```bash
tmp=$(mktemp -d); _pool_atomic_write "$tmp/f.json" '{"a":1}'; cat "$tmp/f.json"; echo; rm -rf "$tmp"
# expected: {"a":1}

tmp=$(mktemp -d); _pool_atomic_write "$tmp/f.json" '{"a":1}'; _pool_json_valid "$tmp/f.json" && echo valid; rm -rf "$tmp"
# expected: valid

tmp=$(mktemp -d); _pool_atomic_write "$tmp/bad" 'not json'; if _pool_json_valid "$tmp/bad"; then echo valid; else echo invalid; fi; rm -rf "$tmp"
# expected: invalid

echo "$(_pool_now)"
# expected: a 10-digit epoch, e.g. 1720822094

echo "$(_pool_age_str $(($(date +%s)-90)))"
# expected: 1m   (90s ago -> 1 minute, largest whole unit)

echo "$(_pool_age_str $(($(date +%s)-30)))"
# expected: 30s

echo "$(_pool_age_str $(($(date +%s)-90000)))"
# expected: 1d

echo "$(_pool_age_str $(($(date +%s)+9999)))"
# expected: 0s   (future timestamp clamped)
```
