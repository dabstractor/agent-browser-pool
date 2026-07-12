# PRP — P1.M1.T2.S1: Atomic file write + JSON helpers

---

## Goal

**Feature Goal**: Implement the **I/O primitive layer** of `lib/pool.sh` — four
small, internal, `_pool_*`-prefixed helper functions that every lease-writing and
admin-status code path will compose:

1. `_pool_atomic_write(filepath, content)` — write `content` to `filepath.tmp` then
   `mv` it over `filepath`, so concurrent readers (the flock critical section in M5.T1,
   the reaper in M5.T3, the admin `status` in M7.T1) never observe a half-written lease.
2. `_pool_json_valid(filepath)` — predicate wrapping `jq empty` that returns 0 if the
   file is syntactically valid JSON, 1 otherwise (including missing/unreadable).
3. `_pool_now()` — echo the current Unix epoch (`date +%s`); the timestamp source for
   `acquired_at` / `last_seen_at` in the lease (PRD §2.8).
4. `_pool_age_str(timestamp)` — human-readable age string (`5m`, `2h`, `3d`) for the
   admin `status` lane table (PRD §2.12 / M7.T1.S1).

These are the literal, physical implementation of PRD §2.19 ("Atomic lease writes: write
`lanes/<N>.json.tmp` then `mv`… never write the lease in place") and the JSON-validation
requirement of PRD §2.8 (the lease data model is JSON). `jq` is confirmed present at
`/usr/bin/jq` (version 1.8.2) per `external_deps.md §4` and `system_context.md §2`.

**Deliverable**:
1. Four functions appended to `lib/pool.sh`, in this order, directly below the last
   function delivered by the **P1.M1.T1.S3** precheck layer (treated as a hard contract —
   see Integration Points). Order matters only because the file is read top-to-bottom by
   humans; there are no forward references between these four.
2. No new globals, no new env vars, no new files, no new external dependencies. Pure
   additions to `lib/pool.sh`. Each function is a leaf — none calls the others.
3. Each function follows the strict-mode-safe patterns verified on this host (see Known
   Gotchas) and passes `bash -n` + `shellcheck` clean.

**Success Definition**:
- `set -euo pipefail; source lib/pool.sh; pool_config_init` then calling each helper
  behaves exactly as the I/O contract table below specifies — atomic write produces a
  final file whose bytes equal the content argument; `jq empty`-based validation returns
  0 on valid JSON and 1 on malformed/missing; `_pool_now` echoes a digit string; `_pool_age_str`
  emits `Ns`/`Nm`/`Nh`/`Nd` by largest whole unit with negative diffs clamped to `0s`.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file still sources
  cleanly under `set -euo pipefail`.
- No regressions in S1 (`pool_die`, `_pool_log`), S2 (`pool_config_init` + `POOL_*`
  globals), or S3 (`pool_state_init`, `pool_check_btrfs`, `pool_check_master`).
- A crash between the `printf` and the `mv` inside `_pool_atomic_write` leaves the prior
  target file intact (atomicity: the target is never observed missing or torn); an orphan
  `.tmp` may remain (cleanup is a caller/startup concern, noted but NOT implemented here).

## User Persona

**Target User**: The downstream lease I/O layer (P1.M3.T1.S1/S2 — lease schema + atomic
write, lease read + validation), the reaper (P1.M5.T3.S1), the admin `status` command
(P1.M7.T1.S1), and the test harness (P1.M9.T1.S1) which will stub/override these to
simulate concurrency. These helpers are **internal** (`_pool_*`) — no end-user or operator
ever invokes them directly.

**Use Case**:
- `_pool_atomic_write` — M3.T1.S1's `pool_lease_write(lane, data)` serializes the lease
  object to a JSON string and calls `_pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$json"`
  so that M5.T1's concurrent acquires (holding flock for only the scan+claim window) and
  M5.T3's reaper never read a partially-written lease.
- `_pool_json_valid` — M3.T1.S2's `pool_lease_read(lane)` uses it to reject a corrupted/
  truncated lease file (e.g. a torn write that somehow survived, or a hand-edited file)
  and treat the lane as stale.
- `_pool_now` — M3.T1.S1 sets `acquired_at: "$(_pool_now)"` and M5.T1.S3's
  `ensure_connected` refreshes `last_seen_at: "$(_pool_now)"` on every invocation.
- `_pool_age_str` — M7.T1.S1's `status` command renders each lane's `acquired_at` as a
  human-friendly `5m` / `2h` / `3d` column.

**Pain Points Addressed**:
- PRD §2.19: writing the lease in place would let a concurrent reader (under the short
  flock window) see a 0-byte or truncated JSON → `_pool_atomic_write` makes the publish
  atomic via same-directory rename.
- `jq empty` legitimately exits non-zero on malformed JSON; under `set -e` (propagated by
  S1) a bare `jq empty "$f"` would abort the whole caller → `_pool_json_valid` wraps it in
  `if` so non-zero is a clean boolean signal.
- Admin `status` wants a compact age column; raw epoch seconds are unreadable →
  `_pool_age_str` formats to the largest whole unit.

## Why

- **Concurrency safety is the pool's central correctness property.** The whole point of
  the pool (PRD §1.3) is that N agents can concurrently acquire N distinct lanes without
  collision. The lease file is the shared state; `_pool_atomic_write` is what makes a
  lease read "old-or-new, never torn." key_findings.md FINDING 7 codifies this exact
  write-to-tmp-then-mv pattern.
- **Foundational for M3 (leases).** M3.T1.S1's lease-write and M3.T1.S2's lease-read are
  the first real consumers; building the primitive now (with its strict-mode traps
  pre-solved) means M3 just composes it rather than re-deriving `jq empty` exit handling
  and the `|| pool_die` rename guard.
- **Foundational for M7 (admin status).** The status lane table needs a human-readable
  age; `_pool_age_str` centralizes the largest-whole-unit formatting so M7.T1.S1 is a
  thin renderer.
- **Separates syntax-validation from schema-validation.** `_pool_json_valid` answers only
  "is this syntactically JSON?" (RFC 8259). The stricter "is this a valid *lease object*
  with required fields?" belongs to M3.T1.S2 (lease schema validation). Splitting them
  now keeps each layer single-purpose and testable. (Caveat: `jq empty` accepts bare
  scalars like `123` and empty files as "valid JSON" — see Known Gotchas; the lease
  object-type check is M3.T1.S2's job, not this subtask's.)

## What

User-visible behavior: none directly (internal library functions). Observable contract:

| Function | Args | Returns / echoes | Side effects | Failure mode |
|---|---|---|---|---|
| `_pool_atomic_write` | `$1=filepath`, `$2=content` (content defaults to `""` if unset) | 0 on success | writes `$filepath.tmp` then `mv -f -- "$filepath.tmp" "$filepath"` | `pool_die` (exit 1) if the tmp write or the rename fails |
| `_pool_json_valid` | `$1=filepath` | 0 if `jq empty "$1"` succeeds, 1 otherwise | none (read-only) | never exits the process; never calls `pool_die` (it is a predicate) |
| `_pool_now` | (none) | echoes `<digits>` (Unix epoch seconds), exit 0 | none | `pool_die` only if `date` itself fails (vanishingly rare; allowed to propagate) |
| `_pool_age_str` | `$1=timestamp` (epoch seconds) | echoes `Ns` / `Nm` / `Nh` / `Nd` (largest whole unit), exit 0 | none | never exits the process; clamps negative diff to `0s` |

### Success Criteria

- [ ] All four functions are defined in `lib/pool.sh` and callable after `source lib/pool.sh`
  (no `pool_config_init` required — these are leaf helpers that do not read `POOL_*`
  globals; but tests may call `pool_config_init` first for realism).
- [ ] `_pool_atomic_write "$f" "$content"` produces a file at `$f` whose byte content is
  EXACTLY `$content` (no added trailing newline — `printf '%s'` not `printf '%s\n'`),
  and a file `$f.tmp` does NOT exist afterward (the rename consumed it).
- [ ] `_pool_atomic_write` is atomic w.r.t. the target: if `$f` already exists with old
  content, a concurrent reader observes either the old bytes or the new bytes, never an
  empty/torn file (this is guaranteed by same-directory `mv`; the Level-4 test confirms
  the same-FS condition holds for `$POOL_LANES_DIR`).
- [ ] `_pool_atomic_write`, on a write failure to `$f.tmp`, removes the partial `.tmp`
  and calls `pool_die` (exit 1).
- [ ] `_pool_atomic_write`, on an `mv` failure, calls `pool_die` (exit 1) and does NOT
  silently leave the target unchanged.
- [ ] The `.tmp` file is always `$filepath.tmp` (same directory as `$filepath` — never
  `/tmp` — so the rename is intra-filesystem and therefore atomic).
- [ ] `_pool_json_valid "$f"` returns 0 for: a valid JSON object, a valid JSON array, a
  valid bare scalar (`123`, `"hi"`), an empty (0-byte) file (all "valid JSON per RFC 8259"
  as reported by `jq empty`).
- [ ] `_pool_json_valid "$f"` returns 1 for: malformed JSON, a missing file, an
  unreadable file (permission denied).
- [ ] `_pool_json_valid` redirects jq's stderr to `/dev/null` (so malformed-JSON parse
  errors do not leak to the user).
- [ ] `_pool_json_valid` NEVER calls `pool_die` and NEVER exits the process — it is a
  pure 0/1 predicate.
- [ ] `_pool_now` echoes a string matching `^[0-9]+$` and exits 0.
- [ ] `_pool_age_str` with a timestamp `now - N` seconds produces: `N<60` → `Ns`
  (e.g. `30s`); `60≤N<3600` → `Nm` where `M=N/60` (e.g. 90→`1m`); `3600≤N<86400` → `Nh`
  where `H=N/3600` (e.g. 3700→`1h`); `N≥86400` → `Nd` where `D=N/86400` (e.g. 90000→`1d`).
- [ ] `_pool_age_str` with a FUTURE timestamp (negative diff, e.g. clock skew or bogus
  input) echoes `0s` and exits 0 (never aborts).
- [ ] `_pool_age_str` with a zero diff (same second) echoes `0s`.
- [ ] None of the four functions read any `POOL_*` global or any env var (they are pure
  leaf helpers taking explicit args).
- [ ] None of the four functions call `_pool_log` on the happy path (they are primitives;
  logging is the caller's job — M3/M5/M7 will log at the operation level).
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources
  cleanly under `set -euo pipefail`; S1, S2, S3 deliverables still work.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the exact host-verified `jq
empty` exit-code semantics (0 for valid/scalar/empty; 2/5 for malformed/missing —
verified this session), the exact same-directory-`mv` atomicity guarantee (key_findings.md
FINDING 7 + POSIX rename(2)), the exact `printf '%s'` byte-preservation behavior
(verified), the exact strict-mode traps (`jq empty` non-zero under `set -e`; bare
`(( ))` evaluating to 0 is fatal under `set -e`), the exact downstream consumer contract
(M3 lease I/O, M7 status), and copy-pasteable validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.19 (Implementation notes / gotchas: "Atomic lease writes: write
        lanes/<N>.json.tmp then mv (rename is atomic on the same FS); never write the
        lease in place"), §2.8 (lease data model — the JSON these helpers read/write),
        §2.12 (admin CLI status — consumes _pool_age_str for the age column).
  pattern: §2.19 line gives the exact tmp-then-mv form. §2.8 shows the lease is a JSON
        OBJECT (so stricter object-type validation is M3.T1.S2, not here).
  gotcha: §2.19 says "same FS" — the .tmp MUST be in the same DIRECTORY as the target
        (POOL_LANES_DIR). A .tmp in /tmp would be a cross-FS copy+unlink (non-atomic).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 7 (Lease Atomic Write Pattern) is the literal code pattern this subtask
        implements — write to $lease_file.tmp, then `mv "$tmp_file" "$lease_file"`, with
        the note "mv (rename) is atomic on the same filesystem. Since all lease files are
        in $STATE_DIR/lanes/, the temp file and final file are on the same FS."
  pattern: FINDING 7's write_lease() is the direct ancestor of _pool_atomic_write
        (generalized from lane-leases to any filepath+content).
  gotcha: FINDING 7 uses jq -n to BUILD the JSON then redirect to tmp. THIS subtask's
        _pool_atomic_write takes already-serialized content (so it is reusable for
        non-jq writers too); the jq-build step is M3.T1.S1's job.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §4 (jq at /usr/bin/jq — used for "Read/write lease JSON files"), §6 (Lease JSON
        Schema v1 + "Atomic writes: Write to lanes/<N>.json.tmp, then mv"), §3 (cp/mv
        coreutils presence).
  pattern: §4 confirms jq is the JSON tool; §6 reiterates the atomic-write contract.
  gotcha: §6's schema is a lease OBJECT — _pool_json_valid only checks JSON syntax
        (accepts scalars/arrays/empty too); the object-shape check is M3.T1.S2.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout — lanes/<N>.json is where leases live; the .tmp files
        will be siblings), §2 (jq 1.8.2 confirmed present at /usr/bin/jq).
  pattern: §7 → _pool_atomic_write will be called with $POOL_LANES_DIR/<N>.json.
  gotcha: none new — the state dir existence is S3's (pool_state_init) concern.

# External authoritative docs (for the HOW)
- url: https://man7.org/linux/man-pages/man2/rename.2.html
  why: POSIX/Linux rename(2) — "If newpath already exists it will be atomically replaced"
        and the same-filesystem atomicity guarantee; EXDEV (cross-device) falls back to
        copy+unlink in coreutils mv (non-atomic).
  critical: ON THIS HOST (verified): `mv` within the same directory is one atomic
        rename; `mv` across mounts is copy+unlink. THEREFORE _pool_atomic_write MUST put
        the .tmp in the SAME directory as the target. The NOTES section covers the
        fsync-for-crash-durability caveat (distinct from atomicity).
  section: DESCRIPTION + NOTES (fsync/durability).

- url: https://jqlang.github.io/jq/manual/
  why: `jq empty` — "empty ... produces no output ... without producing any output (not
        even null)". Exit status: 0 on success, non-zero on parse error or unreadable
        input. This is the standard JSON-validation idiom.
  critical: ON THIS HOST (verified 2026-07-12): `jq empty <file>` exits 0 for valid
        objects/arrays AND for bare scalars (`123`, `"hi"`) AND for empty (0-byte) files
        (all "valid JSON per RFC 8259"); exits 2 for missing file; exits 5 for malformed
        JSON. So _pool_json_valid is a SYNTAX check, NOT a schema/object check. Document
        this; the stricter "is this a lease OBJECT with required fields?" is M3.T1.S2.
  section: the `empty` builtin; "Invoking jq" → exit status.

- url: https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html
  why: `date +%s` — "%s ... seconds since the epoch" (GNU extension, guaranteed by
        coreutils on this host). Always exits 0, prints only digits + newline.
  critical: `$(date +%s)` is safe under set -e (date effectively never fails). Verified.

- url: https://www.gnu.org/software/bash/manual/bash.html#Shell-Arithmetic
  why: `(( ))` arithmetic and the `$(( ))` expansion form for the age formatter.
  critical: a bare `(( expr ))` as a STATEMENT returns exit status 1 when the result is
        0 (or false) — FATAL under set -e. ALWAYS put `(( ))` inside `if (( ))` or guard
        with `||`. The `$(( ))` EXPANSION form is always safe.

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: authoritative on `set -e` (the `if` / `||` / `&&` and `[[ ]]` / `(( ))` inside
        conditions are EXEMPT from errexit) and `set -u` (use `${1:-}` for optionals).
  critical: `if jq empty "$f"; then return 0; else return 1; fi` — the jq non-zero exit
        is a clean branch, not an abort, BECAUSE it is the condition of an `if`.

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` (two statements) so the
        command's exit status is not masked.
  critical: every `local` capture in these functions must be two-statement form.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions. Universal.

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 created lib/pool.sh with `#!/usr/bin/env bash`, `set -euo pipefail` (propagates
        to callers), `pool_die()` (printf '%s\n' "$*" >&2; exit 1), `_pool_log()`, and
        `_pool_log_path()`. THIS subtask APPENDS to that file. Call `pool_die` on fatal
        write/rename failures. Do NOT call `_pool_log` on the happy path.
  pattern: S1's `pool_die` is the canonical exit-1 helper.
  gotcha: S1 propagates `set -euo pipefail` into the caller. Every command whose non-zero
        exit is a SIGNAL not a failure (jq empty, (( )) ) MUST be wrapped in `if`/`||`.

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 delivers `pool_config_init()` + the POOL_* globals. This subtask's helpers are
        LEAF functions that take explicit args and do NOT read any POOL_* global — so
        pool_config_init is NOT required to call them. But tests (and downstream callers)
        will have called pool_config_init first; _pool_atomic_write is typically invoked
        with a path UNDER $POOL_LANES_DIR.
  pattern: no direct dependency; included only so the implementer knows the globals exist
        for the test snippets that use $POOL_LANES_DIR.
  gotcha: none — do not couple these helpers to any POOL_* global (keep them pure/reusable).

- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md
  why: S3 (IN PARALLEL) delivers pool_state_init / pool_check_btrfs / pool_check_master.
        THIS subtask appends BELOW whichever of S2/S3 landed last in the file. Because S3
        is running in parallel, the implementer must locate the END of the current
        lib/pool.sh and append there — do NOT assume a specific function is last.
  pattern: append at EOF; the four helpers are independent leaf functions, order among
        themselves is the only constraint (atomic_write, json_valid, now, age_str).
  gotcha: if S3 has NOT landed yet, that's fine — append below S2's pool_config_init.
        If S3 HAS landed, append below S3's pool_check_master. Either way: EOF.

- file: plan/001_0f759fe2777c/P1M1T2S1/research/atomic-write-jq-date-semantics.md
  why: the deep-research brief with all host-verified jq/mv/date facts and the exact
        strict-mode-safe patterns. The "Consolidated patterns" in the reference impl are
        adapted from it.
  pattern: Topic A (mv atomicity + fsync caveat), Topic B (jq empty exit codes +
        date +%s + age formatter).
  gotcha: the empty-file-returns-0 and bare-scalar-returns-0 behaviors of jq empty are
        documented here; they are ACCEPTABLE for a syntax check and the object-shape
        check is deferred to M3.T1.S2.

- file: plan/001_0f759fe2777c/P1M1T2S1/research/helper-function-reference-impl.md
  why: the paste-ready reference implementation of all four functions, with strict-mode
        notes and self-test snippets. This is the direct ancestor of the Implementation
        Patterns section below.
  pattern: the four function bodies + the "Strict-mode notes" bullets.
  gotcha: the reference uses `printf '%s'` (no newline) for atomic_write — this is
        INTENTIONAL so the file bytes equal the content arg exactly; the caller (M3.T1.S1)
        decides whether to append a trailing newline to the JSON it passes in.
```

### Current Codebase tree

After **S1, S2, and S3** are implemented (S3 in parallel — treat as done or pending;
either way this subtask appends at EOF), the repo looks like:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/                                  # S1 — empty (.gitkeep)
├── lib/
│   └── pool.sh                           # S1 header+set -euo pipefail+pool_die+_pool_log
│                                         # + S2 _pool_config_* helpers + pool_config_init
│                                         # + S3 pool_state_init/pool_check_btrfs/pool_check_master (parallel)
├── test/                                 # S1 — empty (.gitkeep)
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md
    ├── prd_index.txt
    ├── tasks.json
    ├── P1M1T1S1/{PRP.md, research/bash-library-research.md}
    ├── P1M1T1S2/{PRP.md, research/bash-config-init-research.md}
    ├── P1M1T1S3/{PRP.md, research/btrfs-findmnt-host-facts.md}      # parallel
    └── P1M1T2S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{atomic-write-jq-date-semantics.md, helper-function-reference-impl.md}
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
├── lib/
│   └── pool.sh   # MODIFIED — append _pool_atomic_write, _pool_json_valid, _pool_now, _pool_age_str
└── (nothing else changes this subtask)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
adds the **I/O primitive layer** between the prechecks (S3) and the pool logic (M2–M5).
It appends, in order, at EOF (below whichever of S2/S3 landed last):

1. `_pool_atomic_write()` — atomic file publish (write .tmp, mv over target).
2. `_pool_json_valid()` — JSON syntax predicate (jq empty).
3. `_pool_now()` — Unix epoch seconds.
4. `_pool_age_str()` — human-readable age (largest whole unit).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified, 2026-07-12): `jq empty <file>` exit codes:
#   valid JSON object/array ........ exit 0
#   valid bare scalar (123, "hi") . exit 0   ← "valid JSON per RFC 8259"
#   empty (0-byte) file ........... exit 0   ← jq accepts empty input
#   malformed JSON ................ exit 5   (parse error on jq 1.8.2)
#   missing file .................. exit 2   ("No such file")
#   unreadable file ............... exit 2
# VERIFIED THIS SESSION. Consequence: _pool_json_valid is a SYNTAX check, NOT a
# schema/object check. It will return 0 (valid) for `123`, `"hello"`, or an empty file.
# The stricter "is this a lease OBJECT with version/lane/owner/...?" belongs to M3.T1.S2
# (lease read + validation), which will use `jq -e 'type=="object" and has("lane") ...'`.
# DO NOT try to make _pool_json_valid stricter than `jq empty` — that changes its contract.

# CRITICAL (set -e + jq empty): jq legitimately exits non-zero on malformed/missing JSON.
# A bare `jq empty "$f"` ABORTS under set -e (which S1 propagates) before the function can
# return 1. WRAP IT: `if jq empty "$f" >/dev/null 2>&1; then return 0; else return 1; fi`.
# The `if` condition is EXEMPT from errexit. ALWAYS redirect jq stderr to /dev/null so
# parse errors don't leak to the user.

# CRITICAL (same-FS atomicity): rename(2) is atomic ONLY when src and dst are on the SAME
# filesystem. `mv` across mounts falls back to copy+unlink (non-atomic). THEREFORE the
# .tmp file MUST be `"${filepath}.tmp"` — same directory as the target. NEVER use
# `mktemp` (which puts the file in /tmp by default, a different mount than
# $POOL_LANES_DIR). key_findings.md FINDING 7 + PRD §2.19 both state "same FS" — the
# cleanest way to GUARANTEE same-FS is same-DIRECTORY.

# CRITICAL (set -e + arithmetic): a bare `(( expr ))` as a STATEMENT returns exit status 1
# when the result is 0 (or any false-y value). Under set -e this is FATAL. ALWAYS put
# `(( ))` inside `if (( ))` or guard with `|| true` / `|| pool_die`. The `$(( expr ))`
# EXPANSION form is always safe (it produces a string, never a non-zero exit). So
# `diff=$(( now - ts ))` is fine; `(( diff < 60 ))` must be inside `if`.

# CRITICAL (SC2155): `local x="$(cmd)"` masks cmd's exit status (and under set -e hides
# failures). ALWAYS: `local x; x="$(cmd)"` — two statements. This matters for the
# `date +%s` capture in _pool_age_str (and would matter for any future jq capture).

# CRITICAL (printf byte-preservation): use `printf '%s' "$content"` (NOT `printf '%s\n'`)
# in _pool_atomic_write, so the file bytes EQUAL the content arg exactly. The caller
# (M3.T1.S1) decides whether the JSON string it passes ends with a newline. Verified:
# `printf '%s' '{"a":1}xyz'` writes exactly 11 bytes, no added newline.

# GOTCHA (fsync / crash-durability): rename is atomic but NOT crash-durable without
# fsync of the .tmp file's data AND the parent directory. Bash has no fsync builtin;
# coreutils `sync` is global/coarse (syncs everything, too slow). PRAGMATIC DECISION: do
# NOT fsync. Rationale: a pool lease is a short-lived cache of runtime state (pid, port,
# last_seen_at); a power-loss between write and rename leaves the OLD lease intact (rename
# hadn't happened) plus an orphan .tmp — the reaper (M5.T3) treats a stale lease as
# reaper-able anyway. The pool tolerates a stale read far better than a torn one (which
# atomicity prevents). Document this in a code comment; do NOT add `sync`.

# GOTCHA (orphan .tmp cleanup): if the process is killed BETWEEN the `printf > .tmp` and
# the `mv`, an orphan `<filepath>.tmp` remains. _pool_atomic_write does NOT sweep these
# (it can't — it doesn't know about other in-flight writes). Startup cleanup of stale
# .tmp files is a CALLER/install concern (e.g. install.sh or a future doctor command may
# `rm -f $POOL_LANES_DIR/*.json.tmp`). Do NOT add cleanup logic to _pool_atomic_write
# beyond removing ITS OWN partial .tmp on a write failure (so one failed call doesn't
# block the next).

# GOTCHA (mv -f vs mv): use `mv -f` (or rely on `mv`'s default behavior of overwriting).
# `mv -f` suppresses any interactive prompt (in case the environment aliases mv to
# mv -i). The `--` protects against paths starting with '-'.

# GOTCHA (no _pool_log on happy path): these are primitives called on every lease write
# and every status render. Logging "wrote $f" each time would flood the log. Callers
# (M3/M5/M7) log at the OPERATION level ("acquired lane 7"), not the primitive level.

# GOTCHA (scope): these are I/O PRIMITIVES. Do NOT: build the lease JSON object (that's
# M3.T1.S1 using jq -n); validate the lease SCHEMA (M3.T1.S2); acquire flock (M5.T1.S1);
# read a lease into a bash associative array (M3.T1.S2). This subtask provides only the
# four leaf operations. Keep them pure (explicit args, no globals, no env).
```

## Implementation Blueprint

### Data models and structure

This subtask defines no data models, no JSON, no globals. It adds four pure leaf
functions. Their I/O contract (also in the "What" section):

| Function | Args | Globals read | Writes / Side effects | Returns |
|---|---|---|---|---|
| `_pool_atomic_write` | `$1=filepath`, `$2=content` (default `""`) | none | writes `$1.tmp`; `mv -f -- "$1.tmp" "$1"` | 0 on success; `pool_die` (exit 1) on write or rename failure |
| `_pool_json_valid` | `$1=filepath` | none | none (jq reads the file) | 0 if jq empty succeeds, 1 otherwise; never exits the process |
| `_pool_now` | (none) | none | none | echoes `<digits>`, exit 0 |
| `_pool_age_str` | `$1=timestamp` | none | none | echoes `Ns`/`Nm`/`Nh`/`Nd` (negative→`0s`), exit 0 |

**Naming**: all four are internal (`_pool_*` prefix) — they are called only by other
`lib/pool.sh` functions, never by the wrappers or the operator. Matches the `key_findings.md`
"Function Naming Convention" (`_pool_*` = internal helpers).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: READ the prior PRPs and confirm the file is ready to append at EOF
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type pool_die _pool_log pool_config_init'
  - EXPECT: all three reported as functions. (pool_state_init/pool_check_btrfs/
        pool_check_master may or may not be present yet — S3 runs in PARALLEL. If present,
        append below them; if absent, append below pool_config_init. Either way: EOF.)
  - RUN: bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
             echo "LANES=$POOL_LANES_DIR"'
  - EXPECT: an absolute path (no '~'). (Used by the Level-2/3 tests.)
  - NOTE: the file ALREADY contains the S1 header, set -euo pipefail, pool_die, _pool_log,
        _pool_log_path, AND S2's _pool_config_* helpers + pool_config_init, AND POSSIBLY
        S3's pool_state_init/pool_check_btrfs/pool_check_master. APPEND at EOF. Do NOT
        duplicate anything.

Task 1: APPEND _pool_atomic_write() to lib/pool.sh (at EOF)
  - IMPLEMENT: write content to filepath.tmp (same dir → same FS → atomic rename), then mv.
  - BEHAVIOR (verbatim-ready):
        _pool_atomic_write() {
            # Write CONTENT to FILEPATH atomically: write to FILEPATH.tmp (same directory
            # → same filesystem → atomic rename) then `mv` it over FILEPATH. A concurrent
            # reader sees old-or-new, never a half-written file (PRD §2.19, key_findings
            # FINDING 7). PRAGMATIC CAVEAT: we do NOT fsync (no bash builtin; coreutils
            # `sync` is global), so a power-loss crash between write and rename could lose
            # the new data — acceptable for a short-lived pool lease, NOT for a database.
            local filepath="$1" content="${2:-}"
            local tmp
            tmp="${filepath}.tmp"
            # printf '%s' preserves the EXACT bytes (no added newline). On write failure,
            # rm the partial .tmp before dying so one failed call doesn't block the next.
            if ! printf '%s' "$content" >"$tmp"; then
                rm -f -- "$tmp" 2>/dev/null || true
                pool_die "_pool_atomic_write: cannot write tmp file: $tmp"
            fi
            # mv -f overwrites without prompting; -- guards paths starting with '-'.
            mv -f -- "$tmp" "$filepath" \
                || pool_die "_pool_atomic_write: cannot rename tmp into place: $tmp -> $filepath"
        }
  - FOLLOW pattern: S1's pool_die for errors; `if ! cmd; then ...; fi` makes the write
        failure a controlled branch (not a set -e abort) so the cleanup rm runs.
  - GOTCHA: the .tmp is `"${filepath}.tmp"` (same directory) — NEVER mktemp (which would
        put it in /tmp, a different mount → cross-FS copy+unlink, non-atomic).
  - GOTCHA: `printf '%s'` not `printf '%s\n'` — the file bytes must equal the content arg.
  - NAMING: _pool_atomic_write (internal).
  - PLACEMENT: at EOF (below S2's pool_config_init, or below S3's pool_check_master if
        S3 has landed).

Task 2: APPEND _pool_json_valid() to lib/pool.sh (below _pool_atomic_write)
  - IMPLEMENT: predicate — return 0 if `jq empty "$1"` succeeds, else 1.
  - BEHAVIOR (verbatim-ready):
        _pool_json_valid() {
            # Predicate: is FILEPATH syntactically valid JSON? Returns 0 (valid) / 1
            # (invalid, missing, or unreadable). NEVER calls pool_die — it is a boolean.
            # NOTE: `jq empty` exits 0 for valid objects/arrays AND for bare scalars
            # (123, "hi") AND for empty files (all valid JSON per RFC 8259); non-zero for
            # malformed/missing. So this is a SYNTAX check, not a schema check. The
            # stricter "is this a lease OBJECT with required fields?" is M3.T1.S2's job.
            local filepath="$1"
            # The `if` makes jq's non-zero exit a clean branch (NOT a set -e abort).
            # stderr → /dev/null so malformed-JSON parse errors don't leak to the user.
            if jq empty "$filepath" >/dev/null 2>&1; then
                return 0
            fi
            return 1
        }
  - FOLLOW pattern: `if cmd; then return 0; fi; return 1` — the condition is exempt from
        errexit.
  - GOTCHA: NEVER `pool_die` from a predicate. NEVER `echo` anything (callers test the
        exit status, not output).
  - GOTCHA: do NOT try to make this stricter (e.g. `jq -e 'type=="object"'`) — that
        changes the contract; object-shape validation is M3.T1.S2.
  - NAMING: _pool_json_valid (internal).
  - PLACEMENT: directly below _pool_atomic_write.

Task 3: APPEND _pool_now() to lib/pool.sh (below _pool_json_valid)
  - IMPLEMENT: echo the current Unix epoch via `date +%s`.
  - BEHAVIOR (verbatim-ready):
        _pool_now() {
            # Echo the current Unix epoch (seconds since 1970) as digits. Used for lease
            # acquired_at / last_seen_at (PRD §2.8). `date +%s` is a GNU coreutils
            # extension, guaranteed on this host; exits 0 reliably (safe under set -e).
            date '+%s'
        }
  - FOLLOW pattern: no `local`, no capture — just let date write to stdout.
  - GOTCHA: do NOT `echo "$(date +%s)"` (pointless command substitution + echo); let date
        write directly.
  - GOTCHA: do NOT use the bash builtin `printf '%(%s)T' -1` (EPOCH time) — while it is
        fork-free, S1 already standardized on `printf '%(...)T'` for ISO-8601 LOG
        timestamps, but `_pool_now` is the SOURCE for lease epoch fields and `date +%s`
        is the universally-understood idiom (matches key_findings.md FINDING 7 and
        external_deps.md). Either works; use `date +%s` for clarity and external-tool
        consistency. (If you prefer the builtin, `printf '%(%s)T\n' -1` is equivalent and
        fork-free — acceptable, but document the choice.)
  - NAMING: _pool_now (internal).
  - PLACEMENT: directly below _pool_json_valid.

Task 4: APPEND _pool_age_str() to lib/pool.sh (below _pool_now)
  - IMPLEMENT: echo human-readable age (largest whole unit) for an epoch-seconds ts.
  - BEHAVIOR (verbatim-ready):
        _pool_age_str() {
            # Echo a human-readable age for TIMESTAMP (epoch seconds): largest whole unit
            # — Ns (<60), Nm (<3600), Nh (<86400), Nd (else). A future/negative diff
            # (clock skew, bogus ts) clamps to "0s". Used by admin `status` (PRD §2.12,
            # M7.T1.S1). GOTCHA: bare `(( expr ))` as a statement returns 1 when the
            # result is 0 — FATAL under set -e — so EVERY `(( ))` here is inside `if`.
            local ts="$1"
            local now diff
            now="$(date '+%s')"          # two-statement (SC2155); date +%s always exits 0
            diff=$(( now - ts ))         # $(( )) EXPANSION is always set -e safe
            if (( diff < 0 )); then      # clamp future/negative to 0
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
  - FOLLOW pattern: `local x; x="$(...)"` two-statement; `if (( ))` / `elif (( ))` for
        every arithmetic condition (exempt from errexit); `$(( ))` for the division
        expansion (always safe).
  - GOTCHA: the `<60` / `<3600` / `<86400` thresholds give largest-whole-unit: 59→`59s`,
        60→`1m`, 3599→`59m`, 3600→`1h`, 86399→`23h`, 86400→`1d`. Verified by the Level-2 tests.
  - GOTCHA: clamp negative diff (future ts) to 0 BEFORE the unit tests, so `(( diff < 0 ))`
        is the one place a bare-ish `(( ))` appears — and it's inside `if`, so safe.
  - GOTCHA: `printf '%ss\n' "$diff"` — the `ss` is the format-specifier `%s` followed by
        the literal `s`. Do not write `printf '%s\n' "${diff}s"` (also works; pick one and
        be consistent — the `%ss\n` form is slightly more readable).
  - NAMING: _pool_age_str (internal).
  - PLACEMENT: directly below _pool_now (last function in the file).

Task 5: VERIFY (do this BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                  # syntax
  - RUN: shellcheck lib/pool.sh                               # zero warnings (whole file)
  - RUN (all four functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type _pool_atomic_write _pool_json_valid _pool_now _pool_age_str'
        # EXPECT: all four reported as functions.
  - RUN (_pool_atomic_write produces exact bytes, no .tmp left):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_atomic_write "'"$tmp"'/f.json" "{\"a\":1}xyz"; \
                 test "$(cat "'"$tmp"'/f.json")" = "{\"a\":1}xyz"; \
                 test ! -e "'"$tmp"'/f.json.tmp"; echo OK'
        # EXPECT: OK (file content is exactly the arg; no orphan .tmp).
  - RUN (_pool_atomic_write is idempotent-ish: overwrites existing target atomically):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_atomic_write "'"$tmp"'/f.json" "first"; \
                 _pool_atomic_write "'"$tmp"'/f.json" "second"; \
                 test "$(cat "'"$tmp"'/f.json")" = "second"; echo OK'
        # EXPECT: OK (second write replaced first).
  - RUN (_pool_atomic_write with empty content → 0-byte file):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_atomic_write "'"$tmp"'/empty.json" ""; \
                 test ! -s "'"$tmp"'/empty.json"; echo OK'
        # EXPECT: OK (0-byte file created).
  - RUN (_pool_atomic_write dies on unwritable target dir):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_atomic_write "/nonexistent/__abp_no_dir__$RANDOM/f.json" "x"' \
          ; echo "exit=$?"
        # EXPECT: a pool_die message ("cannot write tmp file...") + exit=1, and no .tmp left.
  - RUN (_pool_json_valid: valid object → 0):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '{"a":1}' > "$tmp/good.json"
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_json_valid "'"$tmp/good.json"'"; then echo valid; else echo invalid; fi'
        # EXPECT: valid.
  - RUN (_pool_json_valid: malformed → 1):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf 'not json' > "$tmp/bad.json"
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_json_valid "'"$tmp/bad.json"'"; then echo valid; else echo invalid; fi'
        # EXPECT: invalid. (And NO jq stderr leaks — redirect to /dev/null.)
  - RUN (_pool_json_valid: missing file → 1, no abort):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 if _pool_json_valid "/tmp/__abp_missing__$RANDOM.json"; then echo valid; else echo invalid; fi'
        # EXPECT: invalid.
  - RUN (_pool_json_valid: bare scalar & empty file → 0, DOCUMENTED caveat):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        printf '123' > "$tmp/scalar.json"; : > "$tmp/empty.json"
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_json_valid "'"$tmp/scalar.json"'" && echo "scalar=valid"; \
                 _pool_json_valid "'"$tmp/empty.json"'" && echo "empty=valid"'
        # EXPECT: scalar=valid AND empty=valid (jq empty accepts these per RFC 8259).
        # NOTE: this is the documented syntax-vs-schema caveat; M3.T1.S2 adds the
        # object-shape check.
  - RUN (_pool_now echoes digits):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 out="$(_pool_now)"; [[ "$out" =~ ^[0-9]+$ ]] && echo "OK now=$out"'
        # EXPECT: OK now=<10-digit epoch>.
  - RUN (_pool_age_str boundaries: 30s, 59s, 60s→1m, 90s→1m, 3599s→59m, 3600s→1h, 3700s→1h,
        86399s→23h, 86400s→1d, 90000s→1d):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 now="$(date +%s)"; \
                 test "$(_pool_age_str $((now-30)))"   = "30s";  \
                 test "$(_pool_age_str $((now-59)))"   = "59s";  \
                 test "$(_pool_age_str $((now-60)))"   = "1m";   \
                 test "$(_pool_age_str $((now-90)))"   = "1m";   \
                 test "$(_pool_age_str $((now-3599)))" = "59m";  \
                 test "$(_pool_age_str $((now-3600)))" = "1h";   \
                 test "$(_pool_age_str $((now-3700)))" = "1h";   \
                 test "$(_pool_age_str $((now-86399)))"= "23h";  \
                 test "$(_pool_age_str $((now-86400)))"= "1d";   \
                 test "$(_pool_age_str $((now-90000)))"= "1d";   \
                 echo OK'
        # EXPECT: OK (all 10 boundary cases).
  - RUN (_pool_age_str future/negative → 0s):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 now="$(date +%s)"; \
                 test "$(_pool_age_str $((now+9999)))" = "0s"; \
                 test "$(_pool_age_str $((now+1)))"    = "0s"; \
                 echo OK'
        # EXPECT: OK (future ts clamped to 0s).
  - RUN (_pool_age_str same-second → 0s):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 test "$(_pool_age_str "$(date +%s)")" = "0s"; echo OK'
        # EXPECT: OK.
  - RUN (S1 + S2 + S3 still work after append — regression):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 _pool_log pre; pool_config_init; pool_state_init; \
                 _pool_atomic_write "$POOL_LANES_DIR/7.json" "{\"lane\":7}"; \
                 _pool_json_valid "$POOL_LANES_DIR/7.json" && echo lease-valid; \
                 pool_check_btrfs >/dev/null; pool_check_master; \
                 echo "age=$(_pool_age_str "$(date +%s)")"'
        test -s "$tmp/state/pool.log" && echo OK
        # EXPECT: lease-valid, age=0s, OK. (All four helpers compose with S1/S2/S3.)
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the four functions, verbatim-ready (append at EOF) -----------------

_pool_atomic_write() {
    # Write CONTENT to FILEPATH atomically: write to FILEPATH.tmp (same directory
    # → same filesystem → atomic rename) then `mv` it over FILEPATH. A concurrent
    # reader sees old-or-new, never a half-written file (PRD §2.19, key_findings
    # FINDING 7). PRAGMATIC CAVEAT: we do NOT fsync (no bash builtin; coreutils
    # `sync` is global), so a power-loss crash between write and rename could lose
    # the new data — acceptable for a short-lived pool lease, NOT for a database.
    local filepath="$1" content="${2:-}"
    local tmp
    tmp="${filepath}.tmp"
    # printf '%s' preserves the EXACT bytes (no added newline). On write failure,
    # rm the partial .tmp before dying so one failed call doesn't block the next.
    if ! printf '%s' "$content" >"$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        pool_die "_pool_atomic_write: cannot write tmp file: $tmp"
    fi
    # mv -f overwrites without prompting; -- guards paths starting with '-'.
    mv -f -- "$tmp" "$filepath" \
        || pool_die "_pool_atomic_write: cannot rename tmp into place: $tmp -> $filepath"
}

_pool_json_valid() {
    # Predicate: is FILEPATH syntactically valid JSON? Returns 0 (valid) / 1
    # (invalid, missing, or unreadable). NEVER calls pool_die — it is a boolean.
    # NOTE: `jq empty` exits 0 for valid objects/arrays AND for bare scalars
    # (123, "hi") AND for empty files (all valid JSON per RFC 8259); non-zero for
    # malformed/missing. So this is a SYNTAX check, not a schema check. The
    # stricter "is this a lease OBJECT with required fields?" is M3.T1.S2's job.
    local filepath="$1"
    # The `if` makes jq's non-zero exit a clean branch (NOT a set -e abort).
    # stderr → /dev/null so malformed-JSON parse errors don't leak to the user.
    if jq empty "$filepath" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_pool_now() {
    # Echo the current Unix epoch (seconds since 1970) as digits. Used for lease
    # acquired_at / last_seen_at (PRD §2.8). `date +%s` is a GNU coreutils
    # extension, guaranteed on this host; exits 0 reliably (safe under set -e).
    date '+%s'
}

_pool_age_str() {
    # Echo a human-readable age for TIMESTAMP (epoch seconds): largest whole unit
    # — Ns (<60), Nm (<3600), Nh (<86400), Nd (else). A future/negative diff
    # (clock skew, bogus ts) clamps to "0s". Used by admin `status` (PRD §2.12,
    # M7.T1.S1). GOTCHA: bare `(( expr ))` as a statement returns 1 when the
    # result is 0 — FATAL under set -e — so EVERY `(( ))` here is inside `if`.
    local ts="$1"
    local now diff
    now="$(date '+%s')"          # two-statement (SC2155); date +%s always exits 0
    diff=$(( now - ts ))         # $(( )) EXPANSION is always set -e safe
    if (( diff < 0 )); then      # clamp future/negative to 0
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

# --- Critical micro-rules baked into the above ---------------------------------
#  * `tmp="${filepath}.tmp"` (same dir) — guarantees same-FS → atomic rename. NEVER
#    mktemp (would put .tmp in /tmp, a different mount → non-atomic copy+unlink).
#  * `if ! printf ...; then rm ...; pool_die; fi` — the `if` makes the write failure a
#    controlled branch so the cleanup runs; then pool_die exits.
#  * `mv -f -- "$tmp" "$filepath" || pool_die ...` — `||` is set -e safe; -f suppresses
#    any interactive alias; -- guards leading-dash paths.
#  * `if jq empty "$f" >/dev/null 2>&1; then return 0; fi; return 1` — the condition is
#    errexit-exempt, so jq's non-zero exit returns 1 cleanly (no abort). stderr silenced.
#  * `now="$(date '+%s')"` two-statement — SC2155-clean.
#  * `diff=$(( now - ts ))` — the EXPANSION form is always set -e safe (it's an
#    assignment of a string, not an arithmetic command).
#  * every `(( ))` is inside `if`/`elif` — bare `(( ))` returning 0 is fatal under set -e.
#  * `printf '%s' "$content"` (no `\n`) — file bytes equal the content arg exactly.
#  * `pool_die` (S1) is the only exit-the-process path, and only _pool_atomic_write uses it
#    (on write/rename failure). The other three never exit the process.
#  * No _pool_log on the happy path — primitives are silent; callers log at operation level.
```

### Integration Points

```yaml
PRIOR (S1 + S2 + S3) — consumed, not modified:
  - pool_die()           : S1's exit-1 helper. Called by _pool_atomic_write on write/rename
                           failure. NOT called by the other three (they are predicates/echoers).
  - _pool_log()          : S1's logger. NOT called by any of these four on the happy path
                           (primitives must be silent; callers log at the operation level).
  - pool_config_init()   : S2's config resolver. NOT required to call these four (they take
                           explicit args, read no globals). But tests/callers will have run
                           pool_config_init first, and _pool_atomic_write is typically given
                           a path under $POOL_LANES_DIR.
  - pool_state_init()    : S3's state-dir creator. Ensures $POOL_LANES_DIR exists before
                           _pool_atomic_write is called with a $POOL_LANES_DIR/<N>.json path.
                           (These helpers do NOT create dirs — caller must.)

LATER — provided (the lease layer, admin CLI, and tests):
  - P1.M3.T1.S1 (lease schema + atomic write): builds the lease JSON via `jq -n --arg ...`
        and calls `_pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$json"`. This subtask
        provides the publish primitive; M3.T1.S1 provides the serialize step.
  - P1.M3.T1.S2 (lease read + validation): reads $POOL_LANES_DIR/<N>.json, runs
        `_pool_json_valid` first (syntax), then a stricter `jq -e 'type=="object" and
        has("lane") and has("owner")...'` (schema). The split is intentional: syntax here,
        schema there.
  - P1.M5.T1.S1 (acquire critical section): under flock, calls pool_lease_write (which
        calls _pool_atomic_write) so concurrent acquires never tear each other's lease.
        Also sets acquired_at/last_seen_at via _pool_now.
  - P1.M5.T1.S3 (ensure_connected): refreshes last_seen_at via _pool_now on every call.
  - P1.M5.T3.S1 (reap_stale): uses _pool_json_valid to detect a corrupted lease (treat as
        stale → reap), and _pool_now to compute age.
  - P1.M7.T1.S1 (admin status): for each lane, reads acquired_at from the lease and calls
        `_pool_age_str "$acquired_at"` to render the age column.
  - P1.M9.T1.S1 (test harness): may override _pool_now (via a test hook env var, TBD) to
        simulate fixed timestamps; may exercise _pool_atomic_write concurrently to verify
        no torn reads.

CONFIG / DATABASE / ROUTES: none. No new env vars. No new globals. No dir creation
(these are pure I/O primitives; dirs are the caller's responsibility via pool_state_init).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after appending the four functions — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. S1+S2+S3).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds):

```bash
# 2a. All four functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type _pool_atomic_write _pool_json_valid _pool_now _pool_age_str' >/dev/null && echo OK
# Expected: OK.

# 2b. _pool_atomic_write produces exact bytes, leaves no .tmp.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_atomic_write "'"$tmp"'/f.json" "{\"a\":1}xyz"; \
         test "$(cat "'"$tmp"'/f.json")" = "{\"a\":1}xyz"; \
         test ! -e "'"$tmp"'/f.json.tmp"; echo OK'
# Expected: OK.

# 2c. _pool_atomic_write overwrites an existing target atomically (second call wins).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_atomic_write "'"$tmp"'/f.json" "first"; \
         _pool_atomic_write "'"$tmp"'/f.json" "second"; \
         test "$(cat "'"$tmp"'/f.json")" = "second"; echo OK'
# Expected: OK.

# 2d. _pool_atomic_write with empty content → 0-byte file.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_atomic_write "'"$tmp"'/empty.json" ""; \
         test ! -s "'"$tmp"'/empty.json"; echo OK'
# Expected: OK.

# 2e. _pool_atomic_write dies on unwritable target dir (and leaves no .tmp).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_atomic_write "/nonexistent/__abp__$RANDOM/f.json" "x"' ; echo "exit=$?"
# Expected: a pool_die message ("cannot write tmp file...") + exit=1.

# 2f. _pool_json_valid: valid object → 0 (valid).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '{"a":1}' > "$tmp/good.json"
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_json_valid "'"$tmp/good.json"'"; then echo valid; else echo invalid; fi'
# Expected: valid.

# 2g. _pool_json_valid: malformed → 1 (invalid), NO jq stderr leak.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'not json' > "$tmp/bad.json"
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_json_valid "'"$tmp/bad.json"'"; then echo valid; else echo invalid; fi'
# Expected: invalid (and no parse-error text on stderr).

# 2h. _pool_json_valid: missing file → 1 (invalid), no abort.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         if _pool_json_valid "/tmp/__abp_missing__$RANDOM.json"; then echo valid; else echo invalid; fi'
# Expected: invalid.

# 2i. _pool_json_valid: bare scalar + empty file → 0 (DOCUMENTED syntax caveat).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '123' > "$tmp/scalar.json"; : > "$tmp/empty.json"
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_json_valid "'"$tmp/scalar.json"'" && echo "scalar=valid"; \
         _pool_json_valid "'"$tmp/empty.json"'" && echo "empty=valid"'
# Expected: scalar=valid AND empty=valid (jq empty accepts these per RFC 8259).
# NOTE: this is the documented syntax-vs-schema caveat; M3.T1.S2 adds object-shape check.

# 2j. _pool_now echoes a digit string.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         out="$(_pool_now)"; [[ "$out" =~ ^[0-9]+$ ]] && echo "OK now=$out"'
# Expected: OK now=<10-digit epoch>.

# 2k. _pool_age_str boundaries (all 10 cases).
bash -c 'set -euo pipefail; source lib/pool.sh; \
         now="$(date +%s)"; \
         test "$(_pool_age_str $((now-30)))"   = "30s";  \
         test "$(_pool_age_str $((now-59)))"   = "59s";  \
         test "$(_pool_age_str $((now-60)))"   = "1m";   \
         test "$(_pool_age_str $((now-90)))"   = "1m";   \
         test "$(_pool_age_str $((now-3599)))" = "59m";  \
         test "$(_pool_age_str $((now-3600)))" = "1h";   \
         test "$(_pool_age_str $((now-3700)))" = "1h";   \
         test "$(_pool_age_str $((now-86399)))"= "23h";  \
         test "$(_pool_age_str $((now-86400)))"= "1d";   \
         test "$(_pool_age_str $((now-90000)))"= "1d";   \
         echo OK'
# Expected: OK.

# 2l. _pool_age_str future/negative → 0s (clamp); same-second → 0s.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         now="$(date +%s)"; \
         test "$(_pool_age_str $((now+9999)))" = "0s"; \
         test "$(_pool_age_str $((now+1)))"    = "0s";  \
         test "$(_pool_age_str "$now")"        = "0s";  \
         echo OK'
# Expected: OK.

# 2m. Regression: S1 (_pool_log, pool_die), S2 (pool_config_init + POOL_* globals),
#      S3 (pool_state_init etc., IF landed) still work after the append.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; \
         _pool_log pre; pool_config_init; pool_state_init; \
         _pool_atomic_write "$POOL_LANES_DIR/7.json" "{\"lane\":7}"; \
         _pool_json_valid "$POOL_LANES_DIR/7.json" && echo lease-valid; \
         echo "age=$(_pool_age_str "$(date +%s)")"'
test -s "$tmp/state/pool.log" && grep -q pre "$tmp/state/pool.log" && echo OK
# Expected: lease-valid, age=0s, OK. (If S3 has not landed, drop the pool_state_init line
#           and the $POOL_LANES_DIR write — just exercise the helpers against a tmpdir.)

# Expected: ALL of 2a–2m pass. Debug root cause on any failure (most likely a missing
# `if` around `jq empty` or `(( ))`, a `mktemp` instead of same-dir .tmp, a `printf '%s\n'`
# adding a stray newline, or a SC2155 local-capture).
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. The full file sources cleanly and S1+S2+S3+S4(T2.S1) are all present.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str' \
  >/dev/null && echo OK
# Expected: OK (all seven are functions; pool_state_init/pool_check_* too if S3 landed).

# 3b. Downstream-consumer smoke test: simulate M3.T1.S1's lease-write + M7.T1.S1's status
#     render against the REAL $POOL_LANES_DIR (pointed at a tmpdir).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         lane=7; \
         json="{\"version\":1,\"lane\":$lane,\"acquired_at\":$(_pool_now)}"; \
         _pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$json"; \
         _pool_json_valid "$POOL_LANES_DIR/$lane.json" || pool_die "lease not valid JSON"; \
         acquired_at=$(jq -r ".acquired_at" "$POOL_LANES_DIR/$lane.json"); \
         echo "lane=$lane age=$(_pool_age_str "$acquired_at")"; echo OK'
# Expected: "lane=7 age=0s" and OK — proves the four helpers compose exactly as M3/M7 will use them.

# 3c. Concurrency-correctness smoke test: N concurrent atomic writes to DISTINCT files
#     never tear (each file ends with exactly its own content); this is the property
#     _pool_atomic_write guarantees via same-dir rename.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pids=(); for i in $(seq 1 10); do \
             ( _pool_atomic_write "$POOL_LANES_DIR/$i.json" "{\"i\":$i,\"pad\":\"$(printf "x%.0s" {1..1000})\"}" ) & \
             pids+=($!); \
         done; \
         wait "${pids[@]}"; \
         ok=0; for i in $(seq 1 10); do \
             f="$POOL_LANES_DIR/$i.json"; \
             _pool_json_valid "$f" || { echo "FAIL: $f invalid"; exit 1; }; \
             got=$(jq -r ".i" "$f"); \
             [[ "$got" == "$i" ]] || { echo "FAIL: $f i=$got"; exit 1; }; \
             ok=$((ok+1)); \
         done; echo "wrote+validated $ok files concurrently"'
# Expected: "wrote+validated 10 files concurrently" — no torn writes, all valid JSON.

# 3d. No stray repo artifacts from testing (these functions must not create runtime dirs
#     under the repo; all state goes under $POOL_STATE_DIR = a tmpdir in tests).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock|json|tmp)$' \
  || echo "repo clean of runtime artifacts"
# Expected: 'repo clean of runtime artifacts'.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Confirm the jq empty exit-code matrix on THIS host (the core correctness claim).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '{"a":1}' > "$tmp/obj";   jq empty "$tmp/obj"   >/dev/null 2>&1; echo "object exit=$?"
printf '123'     > "$tmp/num";   jq empty "$tmp/num"   >/dev/null 2>&1; echo "scalar exit=$?"
: >                "$tmp/empty"; jq empty "$tmp/empty" >/dev/null 2>&1; echo "empty exit=$?"
printf 'not json'> "$tmp/bad";   jq empty "$tmp/bad"   >/dev/null 2>&1; echo "malformed exit=$?"
jq empty "$tmp/nope" >/dev/null 2>&1; echo "missing exit=$?"
# Expected: object=0, scalar=0, empty=0, malformed=5 (or non-zero), missing=2 (or non-zero).
#           This is WHY _pool_json_valid uses `jq empty` as a SYNTAX check and why the
#           object-shape check is deferred to M3.T1.S2.

# 4b. Confirm same-directory mv is a single atomic rename (not copy+unlink) on THIS host.
#     (strace is informational; if unavailable, the concurrency test 3c is sufficient proof.)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'x' > "$tmp/a.tmp"
strace -e rename -o "$tmp/strace.log" mv -f -- "$tmp/a.tmp" "$tmp/a" 2>/dev/null || mv -f -- "$tmp/a.tmp" "$tmp/a"
grep -q 'rename("' "$tmp/strace.log" 2>/dev/null && echo "mv = single rename (atomic)" || echo "mv (strace unavailable; 3c proves correctness)"
# Expected: "mv = single rename (atomic)" if strace is present; otherwise the fallback message
#           and reliance on 3c's concurrent-write test.

# 4c. Confirm printf '%s' preserves exact bytes (no added newline) — the atomicity-of-content claim.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s' '{"a":1}abcdefghijklmnopqrstuvwxyz' > "$tmp/t"
test "$(wc -c < "$tmp/t")" = 33 && echo "exact bytes preserved"
# Expected: "exact bytes preserved" (33 bytes = the content length, no added newline).

# 4d. Confirm the $POOL_LANES_DIR is on the SAME filesystem as its .tmp (atomicity precondition).
#     Both are in the same directory by construction, so this is guaranteed — but verify the
#     default state dir is on a real (non-tmpfs) FS so leases survive across processes.
findmnt -nno FSTYPE -T "${AGENT_BROWSER_POOL_STATE:-$HOME/.local/state/agent-browser-pool}" 2>/dev/null \
  && echo "state dir on a real FS" || echo "state dir FS unknown (ok if tests use a tmpdir)"
# Expected: a FSTYPE line (e.g. btrfs/ext4) + the echo. (Tests point AGENT_BROWSER_POOL_STATE
#           at a tmpdir, which is fine — atomicity only requires same-FS, not a specific FS.)
```

## Final Validation Checklist

### Technical Validation

- [ ] `bash -n lib/pool.sh` passes (zero output).
- [ ] `shellcheck lib/pool.sh` passes (zero warnings/errors) — whole file incl. S1 + S2 + S3.
- [ ] Level 2 snippets 2a–2m all pass.
- [ ] Level 3 snippets 3a–3d all pass.
- [ ] Level 4 snippets 4a–4d confirm the host facts that justify the design (jq empty exit
      matrix; same-dir mv is atomic; printf '%s' preserves bytes; state dir on a real FS).

### Feature Validation

- [ ] `_pool_atomic_write()`, `_pool_json_valid()`, `_pool_now()`, `_pool_age_str()` defined
      and callable after `source lib/pool.sh`.
- [ ] `_pool_atomic_write` writes exact bytes (no added newline), leaves no `.tmp`, overwrites
      atomically, and `pool_die`s on write/rename failure.
- [ ] `_pool_atomic_write` puts the `.tmp` in the SAME directory as the target (never `/tmp`).
- [ ] `_pool_json_valid` returns 0 for valid JSON (object/array/scalar/empty) and 1 for
      malformed/missing/unreadable; never calls `pool_die`; never exits the process.
- [ ] `_pool_json_valid` silences jq's stderr (no parse-error leak).
- [ ] `_pool_now` echoes a `^[0-9]+$` string, exit 0.
- [ ] `_pool_age_str` emits largest-whole-unit (`Ns`/`Nm`/`Nh`/`Nd`) at all 10 boundaries and
      clamps negative/future to `0s`.
- [ ] None of the four functions read any `POOL_*` global or env var (pure leaf helpers).
- [ ] None of the four functions call `_pool_log` on the happy path; only `_pool_atomic_write`
      uses `pool_die` (on failure).

### Code Quality Validation

- [ ] APPENDED to S1+S2(+S3)'s `lib/pool.sh` — all prior functions intact and unmodified.
- [ ] Every `local` capture is two-statement (SC2155 clean): `local x; x="$(...)"`.
- [ ] Every `jq empty` and every `(( ))` is inside `if`/`||` (set -e safe).
- [ ] `.tmp` path is same-directory as target (same-FS atomic rename guarantee).
- [ ] `printf '%s'` (not `%s\n`) used for atomic write (exact byte preservation).
- [ ] All expansions double-quoted (SC2086 clean); `--` used on `mv`/`rm`.
- [ ] No new globals, no `declare -g`, no `readonly`, no new env vars.
- [ ] No top-level executable code added beyond function definitions (sourcing stays
      side-effect-free apart from S1's existing `set -euo pipefail`).
- [ ] Naming matches the project convention: `_pool_*` (internal, leading underscore).

### Documentation & Deployment

- [ ] Each function has a leading comment explaining its purpose, the PRD section / finding
      it implements, and the one key gotcha (same-dir .tmp for atomic_write; syntax-vs-schema
      for json_valid; largest-whole-unit + clamp for age_str).
- [ ] The jq empty "accepts scalars/empty" caveat is documented in `_pool_json_valid`'s comment
      so a future reader doesn't try to tighten it (that's M3.T1.S2).
- [ ] The no-fsync crash-durability caveat is documented in `_pool_atomic_write`'s comment.
- [ ] No source/PRD/tasks.json/.gitignore files modified.

---

## Anti-Patterns to Avoid

- ❌ Don't put the `.tmp` file anywhere other than the SAME directory as the target.
  `mktemp` defaults to `/tmp` (a different mount) → `mv` falls back to copy+unlink
  (non-atomic). Always `tmp="${filepath}.tmp"`. (key_findings.md FINDING 7; PRD §2.19.)
- ❌ Don't write `local x="$(cmd)"` — split into `local x; x="$(cmd)"` (SC2155; masks exit
  status under `set -e`).
- ❌ Don't use a bare `jq empty "$f"` outside an `if`/`||` — jq exits non-zero on malformed
  JSON and `set -e` (propagated by S1) aborts the caller before the function can `return 1`.
  Wrap in `if jq empty "$f" >/dev/null 2>&1; then return 0; fi; return 1`.
- ❌ Don't let `_pool_json_valid` `echo` anything or call `pool_die` — it is a 0/1 predicate;
  callers test the exit status, not output.
- ❌ Don't try to make `_pool_json_valid` stricter than `jq empty` (e.g. `jq -e
  'type=="object"'`) — that changes its contract from "syntax" to "schema". The object-shape
  check is M3.T1.S2. `jq empty` accepting bare scalars and empty files is a DOCUMENTED
  feature, not a bug.
- ❌ Don't write a bare `(( expr ))` as a statement — it returns 1 when the result is 0,
  which is FATAL under `set -e`. Always `if (( expr ))` or `(( expr )) || ...`. The `$(( ))`
  EXPANSION form (`x=$(( ... ))`) is always safe.
- ❌ Don't use `printf '%s\n'` in `_pool_atomic_write` — that adds a trailing newline the
  caller didn't ask for. Use `printf '%s'` so file bytes == content arg exactly.
- ❌ Don't add `fsync`/`sync` to `_pool_atomic_write` — bash has no builtin fsync; `sync` is
  global and too slow for a per-lease primitive. The crash-durability caveat is documented
  and accepted (short-lived lease, reaper tolerates stale reads; atomicity is what matters).
- ❌ Don't call `_pool_log` from these primitives on the happy path — they run on every lease
  write and every status render; logging them floods the log. Callers (M3/M5/M7) log at the
  operation level.
- ❌ Don't have these helpers read any `POOL_*` global — keep them pure (explicit args) so
  they're reusable and testable in isolation.
- ❌ Don't build the lease JSON object, validate the lease schema, acquire flock, or read a
  lease into an array here — those are M3.T1.S1 / M3.T1.S2 / M5.T1.S1. This subtask is the
  four I/O primitives ONLY.
- ❌ Don't recreate S1's, S2's, or S3's deliverables — APPEND only, at EOF (below whichever
  of S2/S3 landed last).
- ❌ Don't modify `PRD.md`, `tasks.json`, `prd_snapshot.md`, `.gitignore`, or any source file
  other than appending to `lib/pool.sh`.

---

## Confidence Score

**9 / 10** — one-pass implementation success likelihood.

Rationale:
- The four functions are small and their contracts are unusually precise (explicit I/O
  table, exact byte-preservation requirement, exact 10-case age boundary table, exact
  return-vs-exit distinction between the predicate and the writer).
- The two subtle traps were **verified on the host this session**: (1) `jq empty` exit
  codes (0 for object/scalar/empty; 2 for missing; 5 for malformed — confirmed in
  Validation 4a), and (2) same-directory `mv` is a single atomic rename while cross-mount
  `mv` is copy+unlink (confirmed via 4b/3c). Both are called out in five places (Known
  Gotchas, Task 1/2/4, Implementation Patterns, Anti-Patterns).
- The `set -e` interactions (`jq empty` non-zero, bare `(( ))` returning 0) — the two
  classic bash-strict-mode footguns — are each called out with the exact correct idiom
  (`if` wrap; `if (( ))`) and a dedicated Level-2 test.
- The -1 reflects that the implementer could fumble the `_pool_age_str` boundary math
  (off-by-one on the `<60` vs `<=60` threshold) or use `printf '%s\n'` instead of
  `printf '%s'` — the Level-2 tests (2k, 2b) catch both immediately.
