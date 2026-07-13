# Research: jq lease-object build + atomic single-field update

**Date:** 2026-07-12 (host-verified) · **Host:** jq 1.8.2 at `/usr/bin/jq`
**Task:** P1.M3.T1.S1 — Lease schema + atomic write function

Combines (a) the external jq best-practices brief (jqlang manual / SO / coreutils /
rename(2)) with (b) **live host verification** of every behavioral claim in this shell.

---

## 1. `--arg` (string) vs `--argjson` (raw JSON value) — the core distinction

| Flag | Binds `$name` to | Use for |
|---|---|---|
| `--arg name value` | JSON **string** `"value"` (always double-quoted in output) | `ephemeral_dir`, `session`, `owner.comm`, `owner.cwd` |
| `--argjson name JSON-text` | **parsed JSON value** (number / boolean / null / object / array) | `version`, `lane`, `port`, `owner.pid`, `owner.starttime`, `chrome_pid`, `chrome_pgid`, `acquired_at`, `last_seen_at`, `connected` |

**Authoritative source:** jq manual "Invoking jq" —
<https://jqlang.github.io/jq/manual/#invoking-jq> (manual root
<https://jqlang.github.io/jq/manual/>). jqlang is the maintained fork (supersedes
abandoned `stedolan/jq`).

> `--argjson name JSON-text:` passes a JSON-encoded value... `$foo` is available in
> the program and has the value `123` (a **number**, not a string).

**The #1 lease bug:** passing `--arg port 8080` silently stores `"port":"8080"`
(string) instead of `"port":8080` (number). Numeric + boolean fields **must** use
`--argjson`. Manual JSON-string construction (`printf '{"port":%d,...}'`) is the
classic source of broken leases — a `cwd`/`comm` containing `"` or `\` corrupts the
whole file; `jq -n --arg/--argjson` escapes correctly for free.

### Host-verified build of the full lease object

```bash
jq -n \
  --argjson version 1 \
  --argjson lane 7 \
  --arg ephemeral_dir "/x/7" \
  --argjson port 0 \
  --arg session "abpool-7" \
  --argjson owner_pid 836725 \
  --arg owner_comm "pi" \
  --argjson owner_starttime 123 \
  --arg owner_cwd "/c" \
  --argjson chrome_pid 0 \
  --argjson chrome_pgid 0 \
  --argjson acquired_at 1720000000 \
  --argjson last_seen_at 1720000000 \
  --argjson connected false \
  '{version:$version, lane:$lane, ephemeral_dir:$ephemeral_dir, port:$port,
    session:$session,
    owner:{pid:$owner_pid,comm:$owner_comm,starttime:$owner_starttime,cwd:$owner_cwd},
    chrome_pid:$chrome_pid, chrome_pgid:$chrome_pgid,
    acquired_at:$acquired_at, last_seen_at:$last_seen_at, connected:$connected}'
# → pretty-prints the full object, exit 0  (VERIFIED 2026-07-12)
```

---

## 2. SAFE single-field update: `.[$f] = $v` (field name is DATA, not code)

```bash
jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$lease_file"
```

`.[$f]` is a **path expression** using bracket indexing with a variable. Assignment
updates exactly that path while preserving every sibling field.

**WHY injection-safe:** the filter handed to jq is the literal text `.[$f] = $v`.
The contents of `$field` and `$value` **never become part of the program** — they
enter jq as *data* (`$field` via `--arg` = a JSON string used only as a dict key;
`$value` via `--argjson` = parsed JSON data, *not* evaluated as jq code). Contrast
the **unsafe** form `jq ".${field} = ${value}"` which text-splices names/values into
the program source (breaks the filter / leaks data via `env`/`input`). **Always pass
names + values as `--arg`/`--argjson`, keep the filter a fixed literal.**

(Defense in depth: a `^[a-zA-Z_][a-zA-Z0-9_]*$` regex on the field name rejects
nonsense even though `.[ $f ]` is already safe.)

### Host-verified update semantics (siblings preserved)

```bash
$ echo '{"port":0,"connected":false,"lane":7}' \
    | jq --argjson v 53427 --arg f port '.[$f] = $v'
{ "port": 53427, "connected": false, "lane": 7 }      # VERIFIED — siblings kept

$ echo '{"port":0,"connected":false}' \
    | jq --argjson v true --arg f connected '.[$f] = $v'
{ "port": 0, "connected": true }                       # VERIFIED — boolean

$ echo '{"session":"old"}' \
    | jq --argjson v '"newval"' --arg f session '.[$f] = $v'
{ "session": "newval" }                                # VERIFIED — string (caller quotes)
```

Alternative for nested paths (NOT needed here — owner.* is out of scope for the
updater; the post-lock boot only touches top-level `port`/`chrome_pid`/`chrome_pgid`/
`connected`/`last_seen_at`): `setpath(["owner","pid"]; $v)`.

---

## 3. Atomic read → mutate → write (tmp + `mv`)

This project already implements the primitive: **`_pool_atomic_write filepath content`**
(P1.M1.T2.S1) writes `filepath.tmp` (same directory ⇒ same filesystem) then `mv -f`
over the target. `pool_lease_write` / `pool_lease_update` **compose** it: build the
JSON with `jq`, then hand the bytes to `_pool_atomic_write`. Do NOT re-implement tmp+mv.

- `rename(2)` is atomic only on the **same filesystem** —
  <https://man7.org/linux/man-pages/man2/rename.2.html> ("atomically replaces the
  directory entry"). `.tmp` in the SAME DIRECTORY as the target guarantees same-FS.
- `mv` / coreutils atomic-replace —
  <https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html>.

---

## 4. Gotchas (all host-verified)

### (a) NEVER interpolate field names/values into a jq filter
`jq ".${field} = ${val}"` splices them into the PROGRAM. Use `--arg`/`--argjson` + a
fixed-literal filter (§2).

### (b) `--argjson v 0` is the NUMBER `0`, NOT the boolean `false`
`0`/`1` are valid JSON **numbers**; `true`/`false` are **booleans** (different types).
If a caller passes `connected=0`/`1` to mean off/on, you store a **number** and violate
the lease's boolean contract. **Validate explicitly**: accept only the literals
`true`/`false`.

```bash
# HOST-VERIFIED: --argjson v 1 → number, not boolean
$ echo '{}' | jq --argjson v 1 '.x=$v'
{ "x": 1 }            # ← a NUMBER. So pool_lease_write MUST reject connected=1.
```

### (c) jq adds a trailing `\n`; bash `$(...)` STRIPS trailing newlines
`jq` (and `jq -c`) terminate every emitted document with a single newline. Bash command
substitution **strips ALL trailing newlines**, so `json="$(jq -n ...)"` yields a string
with **no trailing newline**. `_pool_atomic_write` uses `printf '%s'` (preserves exact
bytes), so the lease FILE ends up with **no trailing newline**.

This is **harmless**: every JSON parser (jq included) reads a file without a trailing
newline fine, and the lease is machine-written/machine-read. `pool_lease_write` and
`pool_lease_update` therefore both produce newline-less files — a cosmetic
divergence from a hand-edited file, consistent with the M1.T2.S1 contract ("the caller
decides whether to append a trailing newline"). Document it; do **not** try to re-add
a newline (it would complicate the round-trip for no functional gain).

### (d) `--argjson` rejects non-JSON with exit 2
Empty string, garbage, unquoted text → `jq: invalid JSON text passed to --argjson`,
**exit 2**. This is the validation backstop for numeric fields in `pool_lease_write`:
a non-numeric `port`/`chrome_pid` makes the jq build fail → wrap in `|| pool_die`.

```bash
# HOST-VERIFIED:
$ echo '{}' | jq --argjson v ""  '.x=$v' ; echo $?   # → exit 2  (empty)
$ echo '{}' | jq --argjson v abc '.x=$v' ; echo $?   # → exit 2  (garbage)
```

---

## 5. `jq -n` (null input) is the recommended object-builder

`-n` / `--null-input`: run the filter once against `null`, no input file. Combined with
a fleet of `--arg`/`--argjson` it is **strictly better** than hand-building a JSON
string (correct escaping + correct typing for free). This is exactly the pattern
`pool_lease_write` uses.

---

## Sources (all kept)

- jq manual (jqlang) — <https://jqlang.github.io/jq/manual/> — `-n/--null-input`,
  `--arg`, `--argjson`, path expressions, assignment.
- jq manual "Invoking jq" — <https://jqlang.github.io/jq/manual/#invoking-jq>
  (anchor per GitHub-Pages slug; Ctrl-F `--argjson` to confirm).
- jqlang/jq repo — <https://github.com/jqlang/jq> — upstream for jq 1.8.2.
- jqlang/jq wiki / FAQ — <https://github.com/jqlang/jq/wiki> — `setpath` / dynamic-field.
- StackOverflow `jq` tag — <https://stackoverflow.com/questions/tagged/jq>.
- GNU coreutils `mv` — <https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html>.
- `rename(2)` — <https://man7.org/linux/man-pages/man2/rename.2.html>.
