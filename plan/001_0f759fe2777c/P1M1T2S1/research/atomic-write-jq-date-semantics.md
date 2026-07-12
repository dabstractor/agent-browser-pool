# Research: Atomic `mv` writes + `jq`/`date` semantics for pool helpers

> Sources cited inline. Environment (jq 1.8.2, GNU coreutils mv/date, bash 5.3.15) verified on host per task brief.

## Topic A — Atomic file write via `mv`

**Same-filesystem `rename(2)` is atomic.** When `oldpath` and `newpath` are on the same filesystem, POSIX `rename()` is atomic: if `newpath` exists it is atomically replaced, and no observer can see `newpath` missing mid-op — it sees either the old inode or the new one, never a gap. [POSIX rename](https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html) · [Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)

**Cross-filesystem `mv` is NOT atomic.** `rename(2)` returns `EXDEV` across mounts; GNU `mv` then falls back to copy-then-unlink, with a window where `newpath` is partially written. [coreutils mv](https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html)

**Our pattern is atomic.** Write `lanes/<N>.json.tmp` then `mv` it over `lanes/<N>.json` inside the *same* `lanes/` dir — one atomic step; concurrent readers see old-or-new, never half. Edge cases: existing dst is replaced atomically; a crash/signal *before* `mv` leaves the prior `.json` intact plus an orphan `.tmp` (sweep these at startup); a crash *during* `mv` cannot yield a half-named result — rename is all-or-nothing at the FS layer.

**fsync caveat.** Atomic ≠ crash-durable. Without `fsync` of the tmp file's data *and* the parent directory, a power loss can leave the new directory entry pointing at a zero-length file (ext4 allocation behavior). Bash has no `fsync` builtin; coreutils `sync` is global/coarse. **Recommendation:** skip `fsync` for a short-lived pool lease file and document the caveat — the file is cheaply rewritten and the pool tolerates a stale read far better than a torn one. [rename(2) NOTES](https://man7.org/linux/man-pages/man2/rename.2.html)

**`set -euo pipefail` invocation.** Quote every expansion (SC2086); a failing `mv` must surface as `pool_die`:
```bash
if ! mv -- "lanes/${n}.json.tmp" "lanes/${n}.json"; then
    pool_die "failed to rename lane ${n}"
fi
```
The `--` guards against paths starting with `-`.

## Topic B — `jq empty`, `date +%s`, age formatting

**`jq empty` exit codes** ([jq manual](https://jqlang.github.io/jq/manual/)). `empty` parses each input value and produces no output (not even `null`):
- Valid object/array: **0**.
- Malformed JSON: **non-zero** — jq prints a parse error (exit 2).
- Missing file: **non-zero** (exit 2, "could not open").
- Empty file (0 bytes): **0** — *caveat:* `jq empty` accepts empty input; reject empties with a separate `[ -s "$file" ]` size check.
- Bare scalar (`123`, `"hello"`): **0** — valid JSON per RFC 8259. To require an object, use `jq -e 'type=="object"'`.

**`-e` note:** the "last value null/false → exit 1" rule applies *only* under `--exit-status`. Plain `jq empty` exits 0 on success regardless of output — which is why it is the standard validation idiom.

**Multi-doc files:** jq reads a *stream* of whitespace-separated values, so `jq empty` validates *every* document — two objects both must parse or jq errors on the second. It reads the whole file.

**Helper under `set -e`:**
```bash
json_ok() {
    if jq empty "$1" >/dev/null 2>&1; then return 0; else return 1; fi
}
```
The `if`-condition is exempt from `set -e`, so a non-zero exit returns cleanly instead of aborting.

**`date +%s`** ([GNU date](https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html)): prints Unix epoch seconds as digits; always exits 0 → safe under `set -e`. `%s` is a GNU extension (not strictly POSIX) but guaranteed by coreutils; `now=$(date +%s)` is idiomatic.

**Age formatter (pure bash, `(( ))`):**
```bash
format_age() {            # args: acquired_at now  (epoch seconds)
    local diff=$(( $2 - $1 ))
    if (( diff < 0 ));    then echo "future";            return; fi
    if (( diff < 60 ));   then echo "${diff}s";          return; fi
    if (( diff < 3600 )); then echo "$((diff / 60))m";   return; fi
    if (( diff < 86400 ));then echo "$((diff / 3600))h"; return; fi
    echo "$((diff / 86400))d"
}
```
Boundaries verified: `0s`→`0s`, `59s`→`59s`, `60s`→`1m`, `3600s`→`1h`, `86400s`→`1d`, negative→`future`. Emits the largest whole unit only.
