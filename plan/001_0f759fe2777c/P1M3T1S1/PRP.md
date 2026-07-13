# PRP — P1.M3.T1.S1: Lease schema + atomic write function

---

## Goal

**Feature Goal**: Implement the **lease write layer** of `lib/pool.sh` — the two
functions that serialize the PRD §2.8 lease object to JSON and persist it atomically to
`$POOL_LANES_DIR/<N>.json`. This is the *write* half of the lease I/O layer (the read +
schema-validation half is the next task, P1.M3.T1.S2). Together they are the on-disk
state machine that every acquire / release / heartbeat / reap decision reads and mutates.

1. **`pool_lease_write(lane, ephemeral_dir, port, session, owner_pid, owner_comm, owner_starttime, owner_cwd, chrome_pid, chrome_pgid, connected)`**
   — builds the **full** lease JSON via `jq -n --arg/--argjson` (one `--arg`/`--argjson`
   per field, all field names + values passed as jq DATA — never interpolated into the
   filter), stamps `version=1` + `acquired_at`/`last_seen_at` (both `$(_pool_now)`,
   captured once so they match), and publishes atomically by composing the already-landed
   `_pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$json"`. Creates a **new** lease
   (overwrites any prior content at that path).

2. **`pool_lease_update(lane, field, value)`**
   — reads the **existing** lease, mutates exactly one **top-level** field via the
   injection-safe path-assignment `jq --arg f "$field" --argjson v "$value" '.[$f] = $v'`
   (siblings preserved), and re-publishes atomically. This is the primitive the post-lock
   boot (M5.T1.S2) uses to fill in `port` / `chrome_pid` / `chrome_pgid` / `connected`
   after Chrome is up, and `ensure_connected` (M5.T1.S3) uses for the `last_seen_at`
   heartbeat. PRD §2.19 ("Atomic lease writes: write `lanes/<N>.json.tmp` then `mv`…
   never write the lease in place") is satisfied by composing `_pool_atomic_write`.

These are the literal realization of the item's CONTRACT (LOGIC a–d) and
key_findings.md FINDING 7. `jq` is confirmed present at `/usr/bin/jq` (version 1.8.2);
every `jq`/`mv` behavior in this PRP is **host-verified** (2026-07-12).

**Deliverable**:
1. Two functions appended to `lib/pool.sh`, in a new **"Lease management"** section at
   EOF (directly below the owner-resolution section — `pool_owner_resolve` and, if the
   parallel P1.M2.T2.S1 has landed, `pool_owner_alive`). Order: `pool_lease_write` then
   `pool_lease_update`. No forward references between them.
2. No new globals, no new env vars, no new files, no new external dependencies. Pure
   additions to `lib/pool.sh`. Both functions are leaf-ish writers that compose the
   M1.T2.S1 primitives (`_pool_atomic_write`, `_pool_json_valid`, `_pool_now`) and read
   exactly one global (`POOL_LANES_DIR`, frozen by `pool_config_init`).
3. Each function follows the strict-mode-safe patterns verified on this host and passes
   `bash -n` + `shellcheck` clean.

**Success Definition**:
- After `set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init`,
  calling `pool_lease_write` with the 11 documented args writes a file at
  `$POOL_LANES_DIR/<lane>.json` whose JSON content matches the PRD §2.8 schema **with
  correct types** (numbers as numbers, the boolean `connected` as a JSON boolean, strings
  as strings), `version==1`, `acquired_at==last_seen_at` (both ≈ now), and no orphan
  `.tmp` left behind.
- `pool_lease_update <lane> <field> <value>` on an existing lease updates exactly that
  field (number/boolean/string-as-quoted-JSON), preserves every sibling field and the
  `owner` sub-object, and re-publishes atomically (no `.tmp` left, no content loss).
- A `connected` value of `0`/`1`/`yes`/`""` is **rejected** by `pool_lease_write` (it
  would store a number, violating the boolean contract — see gotcha 4b).
- A non-numeric `port`/`pid` makes the `jq -n` build fail → `pool_die` (clear message).
- `pool_lease_update` rejects a missing lease, a corrupted (non-JSON) lease, and an
  invalid field name (`pool_die`); a non-JSON `value` (e.g. empty) makes `jq --argjson`
  fail → `pool_die`.
- `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; whole file sources cleanly
  under `set -euo pipefail`; all prior deliverables (M1, M2.T1.\*, M2.T2.S1) unchanged.

## User Persona

**Target User**: Internal only — no end user or operator ever calls these. Consumers are
later subtasks inside `lib/pool.sh` and the two wrappers:

- **P1.M5.T1.S1** (acquire — flock critical section) calls `pool_lease_write` with
  **provisional** values (`port=0 chrome_pid=0 chrome_pgid=0 connected=false`) to claim a
  lane under flock, then **releases the lock before booting Chrome** (key_findings
  FINDING 2) so concurrent acquires boot in parallel.
- **P1.M5.T1.S2** (post-lock boot) calls `pool_lease_update lane port <P>` /
  `… chrome_pid <PID>` / `… chrome_pgid <PGID>` / `… connected true` once Chrome is up
  and the daemon is connected.
- **P1.M5.T1.S3** (`ensure_connected`) calls `pool_lease_update lane last_seen_at <now>`
  as the heartbeat on every invocation (PRD §2.4 step 4).
- **P1.M3.T1.S2** (lease read + validation) reads what these functions write — the schema
  written here must match the schema validated there.

**Use Case**: serialize the pool's per-lane runtime state (owner identity, ephemeral dir,
Chrome port/pid/pgid, connection flag, timestamps) to a JSON file that concurrent
processes (other acquires, the lazy reaper, the admin `status`) read atomically. The
lease is the shared state of the whole pool; these two functions are its only writers.

**Pain Points Addressed**:
- **Torn reads under concurrency.** Writing the lease in place would let a concurrent
  reader (under the short flock window) see a 0-byte or truncated JSON → composing
  `_pool_atomic_write` (tmp + same-dir `mv`) makes the publish atomic ("old-or-new,
  never torn"). PRD §2.19, key_findings FINDING 7.
- **Type corruption.** A hand-rolled `printf '{"port":%d,...}'` would mangle a `cwd`/
  `comm` containing `"`/`\` and would store `port`/`connected` as the wrong JSON type if
  built carelessly (`--arg port 8080` → `"port":"8080"`; `--argjson connected 1` → a
  number). `jq -n --arg/--argjson` + explicit `connected` validation eliminates all three.
- **Injection.** Building a jq filter by interpolating a field name is fragile; passing
  the field name + value as `--arg`/`--argjson` data (filter is a fixed literal
  `.[$f] = $v`) is injection-safe by construction.

## Why

- **The lease file IS the pool's coordination state.** Every correctness property of the
  pool (N agents ↔ N distinct lanes, no collision; owner-liveness-driven release; stale
  reaping) is enforced by reading and writing this file. `pool_lease_write` /
  `pool_lease_update` are its only mutators. If they write a malformed or torn lease,
  every downstream decision (find_free_lane, is_lane_stale, reap, status) corrupts.
- **Atomicity is non-negotiable under the short flock design.** key_findings FINDING 2
  keeps the flock critical section to scan+claim+write only, then releases before the
  ~10 s Chrome boot. That means a lease write happens *inside* the critical section while
  other processes may be *reading* lanes for their own scan. Only an atomic publish
  (tmp+mv) keeps those readers from observing a half-written file. Composing the existing
  `_pool_atomic_write` primitive gives this for free.
- **Right types, right escaping, for free.** `jq -n --arg/--argjson` produces
  syntactically-valid, correctly-typed, correctly-escaped JSON without any hand-rolling.
  This is the idiomatic jq approach (research `jq-lease-build-and-update.md` §5).
- **Separates "write a full lease" from "patch one field".** The acquire flow has two
  distinct phases (provisional claim → post-boot patch). Splitting them into two
  functions keeps each single-purpose and testable, and lets the post-boot patch be a
  cheap read-modify-write instead of rebuilding the whole object.

## What

User-visible behavior: none directly (internal library writers). Observable contract:

| Function | Args | Returns / side effects | Failure mode |
|---|---|---|---|
| `pool_lease_write` | `$1=lane` `$2=ephemeral_dir` `$3=port` `$4=session` `$5=owner_pid` `$6=owner_comm` `$7=owner_starttime` `$8=owner_cwd` `$9=chrome_pid` `$10=chrome_pgid` `$11=connected` | builds full lease JSON (version=1, acquired_at/last_seen_at=now), writes `$POOL_LANES_DIR/$lane.json` atomically. Returns 0. | `pool_die` (exit 1) if `lane` non-numeric, `connected` not `true`/`false`, the `jq -n` build fails, or `_pool_atomic_write` fails |
| `pool_lease_update` | `$1=lane` `$2=field` `$3=value` | reads existing lease, sets top-level `field` to `value` (raw JSON via `--argjson`), writes back atomically. Returns 0. | `pool_die` (exit 1) if `lane` non-numeric, `field` not a safe identifier, lease missing, lease not valid JSON, the `jq` mutate fails (non-JSON `value`), or `_pool_atomic_write` fails |

**Type semantics of `pool_lease_update`'s `value`:** it is spliced as **raw JSON** via
`--argjson`. So `pool_lease_update 7 port 53427` → number; `… 7 connected true` → boolean;
`… 7 last_seen_at 1720000123` → number. To set a *string* field the caller passes a
JSON-quoted value (`pool_lease_update 7 session '"abpool-7"'`) — but the documented
post-lock-boot/heartbeat use cases are all numbers/booleans, never strings. An empty or
non-JSON `value` makes `jq --argjson` exit 2 → `pool_die`.

**Field scope of `pool_lease_update`:** top-level fields only (regex
`^[a-zA-Z_][a-zA-Z0-9_]*$`). Dotted `owner.*` updates are out of scope — `owner` is
written once at acquire and never mutated. This matches every real consumer (M5.T1.S2
patches `port`/`chrome_pid`/`chrome_pgid`/`connected`; M5.T1.S3 patches `last_seen_at`).

### Success Criteria

- [ ] Both functions defined in `lib/pool.sh`, callable after `source lib/pool.sh`
  (requires `pool_config_init` first, since they read `POOL_LANES_DIR`; tests also call
  `pool_state_init` to create the dir). Appended in a new "Lease management" section at
  EOF, below the owner-resolution section.
- [ ] `pool_lease_write 7 "$EPH" 53427 abpool-7 836725 pi 1234567890 "/home/dustin/projects/x" 104816 104816 true`
  produces `$POOL_LANES_DIR/7.json` whose content equals the PRD §2.8 example shape with
  correct types (`jq -e '.version==1 and .lane==7 and .port==53427 and
  (.connected|not|not) and .connected==true and .owner.pid==836725 and .owner.comm=="pi"
  and (.acquired_at|type)=="number" and (.last_seen_at|type)=="number"'`).
- [ ] A fresh lease has `acquired_at == last_seen_at` (both set from a single
  `$(_pool_now)` capture).
- [ ] `pool_lease_write` rejects `connected` values other than the literals `true`/`false`
  (`0`, `1`, `yes`, `""`, `True`) with `pool_die` — they would store a number/string and
  violate the boolean contract.
- [ ] `pool_lease_write` rejects a non-numeric `lane` with `pool_die`.
- [ ] A non-numeric numeric-field value (e.g. `port=abc`) makes the `jq -n` build fail →
  `pool_die` (clear, lane-tagged message).
- [ ] No orphan `.tmp` file remains after a successful `pool_lease_write` (the rename
  consumed it) and the target file ends in valid JSON (`_pool_json_valid` → 0).
- [ ] `pool_lease_update 7 port 9999` on an existing lease sets `.port==9999`, preserves
  every sibling field AND the `owner` sub-object, and leaves valid JSON.
- [ ] `pool_lease_update 7 connected true` / `… false` sets a JSON boolean (not a number).
- [ ] `pool_lease_update 7 last_seen_at <now>` sets a number (heartbeat path).
- [ ] `pool_lease_update` rejects a missing lease (`pool_die`), a corrupted/non-JSON lease
  (`pool_die`), and an invalid `field` name containing non-identifier chars (`pool_die`).
- [ ] `pool_lease_update` with an empty/non-JSON `value` makes `jq --argjson` fail →
  `pool_die`.
- [ ] Neither function leaves an orphan `.tmp` on the happy path; on a `jq` failure the
  target file is **unchanged** (the mutate is computed before `_pool_atomic_write`, so a
  build failure never touches the existing lease).
- [ ] Both functions `pool_die` (never `return 1`) — they are writers expected to succeed;
  failure is exceptional and fatal to the caller. (`pool_die` writes one line to stderr +
  exit 1.)
- [ ] `bash -n lib/pool.sh` clean; `shellcheck lib/pool.sh` clean; all prior deliverables
  (M1, M2.T1.\*, M2.T2.S1) unchanged and still callable.

## All Needed Context

### Context Completeness Check

**"If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?"** → Yes. This PRP includes: the host-verified `jq` facts
(`--arg`→string vs `--argjson`→raw value; `.[ $f ] = $v` injection-safe assignment;
`--argjson 0`→number-not-boolean; `--argjson ""`→exit 2; `$()` strips jq's trailing
newline so the file is newline-less — all verified this session and in
`research/jq-lease-build-and-update.md`); the exact schema with per-field jq flag
(`research/lease-schema-and-consumers.md` §1); the exact primitives to compose
(`_pool_atomic_write`, `_pool_json_valid`, `_pool_now`, `pool_die` — with their
contracts); the exact placement (new "Lease management" section at EOF, below the owner
section); the exact downstream consumer contract (M5 acquire/heartbeat); and
copy-pasteable, host-verified validation commands for every behavior.

### Documentation & References

```yaml
# MUST READ — primary sources of truth
- file: PRD.md
  why: §2.8 (the EXACT lease schema this task writes — version/lane/ephemeral_dir/port/
        session/owner{pid,comm,starttime,cwd}/chrome_pid/chrome_pgid/acquired_at/
        last_seen_at/connected), §2.19 ("Atomic lease writes: write lanes/<N>.json.tmp
        then mv … never write the lease in place"), §2.4 (request lifecycle — acquire then
        ensure_connected, the two writers' call sites), §2.2 (no bare ~ — ephemeral_dir/
        owner.cwd are absolute).
  pattern: §2.8 JSON is the byte-for-byte target output of pool_lease_write.
  gotcha: §2.8's "connected": true is a JSON BOOLEAN. --argjson connected 1 would store a
        NUMBER → must validate connected ∈ {true,false} (research §4b, host-verified).

- file: plan/001_0f759fe2777c/architecture/key_findings.md
  why: FINDING 7 (Lease Atomic Write Pattern) is the literal ancestor — write to
        $lease_file.tmp then mv; same FS guaranteed by same directory. FINDING 2 (short
        flock critical section: claim under flock, release BEFORE Chrome boot) explains
        WHY the provisional write + post-boot update split exists. The "Function Naming
        Convention" reserves pool_lease_* for this subdomain.
  pattern: FINDING 7's write_lease() is the conceptual ancestor of pool_lease_write
        (generalized: build JSON with jq -n, publish via _pool_atomic_write).
  gotcha: FINDING 7 redirects jq output to the .tmp directly; THIS task captures via
        "$(...)" then hands the string to _pool_atomic_write (which owns the tmp+mv). The
        only consequence: $() strips jq's trailing newline → the file is newline-less
        (harmless; research §4c). Do NOT add a trailing newline.

- file: plan/001_0f759fe2777c/architecture/external_deps.md
  why: §6 (Lease JSON Schema v1 — byte-identical to PRD §2.8; "Atomic writes: Write to
        lanes/<N>.json.tmp, then mv"), §4 (jq at /usr/bin/jq — "Read/write lease JSON
        files"), §5 (env-var → POOL_* table; POOL_LANES_DIR is derived from
        AGENT_BROWSER_POOL_STATE).
  pattern: §6 schema is the contract; §4 confirms jq is the JSON tool.
  gotcha: none new beyond PRD §2.8.

- file: plan/001_0f759fe2777c/architecture/system_context.md
  why: §7 (pool state dir layout: lanes/<N>.json is where leases live; the .tmp is a
        sibling in the same dir → same FS → atomic rename), §2 (jq 1.8.2 confirmed).
  pattern: §7 → lease path is $POOL_LANES_DIR/<N>.json.
  gotcha: the dir must exist (pool_state_init, M1.T1.S3) before writing — these functions
        do NOT mkdir (surfacing a misconfigured state dir loudly is correct).

# This task's own research (host-verified)
- file: plan/001_0f759fe2777c/P1M3T1S1/research/jq-lease-build-and-update.md
  why: the deep brief on --arg vs --argjson, the injection-safe .[$f]=$v update,
        atomic read-modify-write via the existing primitive, and the four gotchas
        (interpolation injection; --argjson 0→number-not-bool; $() strips trailing
        newline; --argjson rejects non-JSON with exit 2). Every claim host-verified.
  pattern: §1 (the full jq -n build), §2 (the .[$f]=$v update), §3 (compose
        _pool_atomic_write — do NOT reinvent tmp+mv).
  gotcha: §4b (validate connected) and §4c (newline-less file is intentional) are the two
        non-obvious ones.

- file: plan/001_0f759fe2777c/P1M3T1S1/research/lease-schema-and-consumers.md
  why: the per-field jq-flag table (§1), the primitives to compose (§2), the owner
        globals to source args from at the realistic call site (§3), the downstream
        consumer contract (§4 — why pool_lease_update is top-level-only), placement (§5),
        and the scope guard (§7 — what NOT to do).
  pattern: §1 table → the exact --arg/--argjson choices; §4 → field set is top-level only.
  gotcha: §4 — owner.* is never updated in place; pool_lease_update must NOT try to.

# External authoritative docs (for the HOW)
- url: https://jqlang.github.io/jq/manual/#invoking-jq
  why: --arg (binds a JSON string) vs --argjson (binds a parsed JSON value) and
        -n/--null-input (run the filter once against null, no input file).
  critical: --arg port 8080 → "port":"8080" (STRING); --argjson port 8080 → port:8080
        (NUMBER). Numeric/boolean/timestamp fields MUST use --argjson; string fields
        (ephemeral_dir, session, comm, cwd) use --arg. Host-verified.
  section: "Invoking jq" (--arg, --argjson, --null-input).

- url: https://jqlang.github.io/jq/manual/
  why: path expressions (`.[$f]`) and assignment (`.[$f] = $v`) — set one field by
        variable name while preserving siblings; the field name + value enter as DATA
        (injection-safe), never spliced into the filter program text.
  critical: NEVER build a filter by string-interpolating field names/values
        (`jq ".${field}=${val}"`); ALWAYS pass via --arg/--argjson with a fixed-literal
        filter. Host-verified: .[$f]=$v preserves siblings.
  section: ".[] / .[expr]" and "Assignment".

- url: https://man7.org/linux/man-pages/man2/rename.2.html
  why: rename(2) atomically replaces the directory entry ON THE SAME FILESYSTEM. The .tmp
        is in the SAME DIRECTORY as the target (handled by _pool_atomic_write) → same FS.
  critical: cross-FS mv falls back to copy+unlink (non-atomic). _pool_atomic_write already
        guarantees same-dir; this task just composes it. Do NOT use mktemp in /tmp.
  section: DESCRIPTION.

- url: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
  why: errexit (`set -e`) exemptions — the condition of `if`/`||`/`&&` and `[[ ]]` inside
        those conditions are EXEMPT. So `[[ "$lane" =~ ^[0-9]+$ ]] || pool_die …` and
        `json="$(jq …)" || pool_die …` are safe.
  section: `-e` (errexit).

- url: https://github.com/koalaman/shellcheck/wiki/SC2155
  why: "declare and assign separately" — `local x; x="$(cmd)"` so the command's exit
        status is not masked. Critical for `json="$(jq …)" || pool_die …` to work: a
        PLAIN assignment's status == the command-substitution's status (unlike
        `local x="$(…)"` which masks it).
  critical: declare `local …` FIRST, then assign in separate statements.

- url: https://github.com/koalaman/shellcheck/wiki/SC2086
  why: double-quote all expansions (universal; these fns pass paths/args to jq/mv).
- url: https://github.com/koalaman/shellcheck/wiki/SC2124
  why: use `# shellcheck disable=...` only when justified; not expected to be needed here.

# Prior-subtask contracts (treated as already-implemented truth)
- file: plan/001_0f759fe2777c/P1M1T1S1/PRP.md
  why: S1 created lib/pool.sh with set -euo pipefail (propagates to callers) + pool_die()
        (printf '%s\n' "$*" >&2; exit 1). THIS task APPENDS below the owner section. Call
        pool_die on build/mutate/publish failures.
  pattern: pool_die is the canonical exit-1 helper.

- file: plan/001_0f759fe2777c/P1M1T1S2/PRP.md
  why: S2 delivers pool_config_init() + the POOL_* globals, incl. POOL_LANES_DIR (derived
        = $POOL_STATE_DIR/lanes, canonicalized). Both new functions READ POOL_LANES_DIR →
        pool_config_init is a PRECONDITION (callers run it once at startup).
  pattern: POOL_LANES_DIR is the directory under which <lane>.json lives.
  gotcha: do NOT re-resolve paths inside these fns — trust the frozen POOL_LANES_DIR.

- file: plan/001_0f759fe2777c/P1M1T1S3/PRP.md
  why: S3 delivers pool_state_init() (idempotent mkdir -p $POOL_LANES_DIR + touch lock).
        Callers run it before writing. THESE fns do NOT mkdir — a missing dir surfaces as
        a pool_die from _pool_atomic_write, which is the desired loud failure.
  gotcha: tests must call pool_state_init (or mkdir -p) before pool_lease_write.

- file: plan/001_0f759fe2777c/P1M1T2S1/PRP.md
  why: T2.S1 delivers the four I/O primitives THIS task composes:
        - _pool_atomic_write FILEPATH CONTENT → tmp+same-dir mv; pool_die on failure;
          printf '%s' (exact bytes, no added newline). [publish the lease]
        - _pool_json_valid FILEPATH → jq empty predicate (0 valid / 1 not); never fatal.
          [pool_lease_update pre-check for a clear error]
        - _pool_now → epoch seconds. [acquired_at / last_seen_at]
  pattern: T2.S1's PRP literally says "M3.T1.S1 builds the lease JSON via jq -n --arg …
        and calls _pool_atomic_write." THIS is that task.
  gotcha: _pool_atomic_write uses printf '%s' (no newline) — and $(jq …) already stripped
        jq's trailing newline — so the lease file is newline-less. Intentional, harmless.

- file: plan/001_0f759fe2777c/P1M2T1S1/PRP.md   # LANDED
  why: M2.T1.S1 landed pool_owner_resolve() + the POOL_OWNER_* globals. The REALISTIC call
        site sources owner args from these globals (pool_lease_write takes explicit args,
        not the globals — more testable). Also: the file's owner-resolution section is
        where THIS task appends below.
  gotcha: do NOT modify pool_owner_resolve or any owner function.

- file: plan/001_0f759fe2777c/P1M2T2S1/PRP.md   # parallel, treated as LANDED (CONTRACT)
  why: M2.T2.S1 (parallel) appends pool_owner_alive() below pool_owner_resolve. THIS task
        appends its "Lease management" section AFTER the owner section (at EOF). No
        functional coupling (lease I/O does not call the liveness predicate). Locate EOF
        and append there; do NOT touch pool_owner_alive if it has landed.
  gotcha: because M2.T2.S1 is parallel, the append point is "end of file" — do not assume
        a specific function is last. `grep -nE '^[a-z_][a-z_0-9]*\(\)' lib/pool.sh | tail`
        to confirm.
```

### Current Codebase tree

After **M1 (S1–T2.S1), M2.T1.S1, and M2.T2.S1** have landed (M2.T2.S1 in parallel —
treat as done or pending; either way this task appends at EOF), the repo looks like:

```bash
agent-browser-pool/
├── .git/
├── .gitignore
├── PRD.md                                # READ-ONLY
├── README.md
├── bin/.gitkeep                          # S1 — empty
├── lib/
│   └── pool.sh                           # S1 header+set -euo pipefail+pool_die+_pool_log
│                                         # + S2 _pool_config_* + pool_config_init
│                                         # + S3 pool_state_init/pool_check_btrfs/pool_check_master
│                                         # + T2.S1 _pool_atomic_write/_pool_json_valid/_pool_now/_pool_age_str
│                                         # + M2.T1.S1 _pool_get_starttime/_pool_owner_starttime/pool_owner_resolve  (LANDED)
│                                         # + M2.T1.S2 wrapper conversion                                            (LANDED)
│                                         # + M2.T2.S1 pool_owner_alive                                              (parallel→laned)
├── test/.gitkeep                         # empty
└── plan/001_0f759fe2777c/
    ├── architecture/{external_deps,key_findings,system_context}.md
    ├── prd_snapshot.md, prd_index.txt, tasks.json
    ├── P1M1T1S1/.../PRP.md
    ├── P1M1T1S2/.../PRP.md
    ├── P1M1T1S3/.../PRP.md
    ├── P1M1T2S1/.../PRP.md
    ├── P1M2T1S1/.../PRP.md
    ├── P1M2T1S2/.../PRP.md
    ├── P1M2T2S1/.../PRP.md
    └── P1M3T1S1/                         # THIS subtask
        ├── PRP.md                         # THIS FILE
        └── research/{jq-lease-build-and-update.md, lease-schema-and-consumers.md}
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
agent-browser-pool/
└── lib/
    └── pool.sh   # MODIFIED — APPEND a "Lease management" section with two functions:
                  #          pool_lease_write(...)  and  pool_lease_update(...)
                  #   (NO changes to any existing function)
```

**File responsibility**: `lib/pool.sh` remains the single shared library. This subtask
adds the **lease write layer** — the only mutators of `$POOL_LANES_DIR/<N>.json`. It
composes the M1.T2.S1 I/O primitives and is consumed by the lease-query layer (M3.T2),
the acquire/release orchestration (M5), and (read-side) the lease read+validation
(M3.T1.S2).

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (host-verified): --arg vs --argjson typing.
#   --arg name value       → binds a JSON STRING (always double-quoted in output).
#   --argjson name JSON    → binds a parsed JSON VALUE (number/bool/null/object/array).
# Numeric + boolean + timestamp fields (version,lane,port,owner.pid,owner.starttime,
# chrome_pid,chrome_pgid,acquired_at,last_seen_at,connected) MUST use --argjson.
# String fields (ephemeral_dir,session,owner.comm,owner.cwd) use --arg.
# The #1 bug: --arg port 8080 → "port":"8080" (string). Always --argjson for numbers.

# CRITICAL (host-verified): --argjson connected 1 stores a NUMBER (1), not a boolean.
# 0/1 are valid JSON NUMBERS; true/false are BOOLEANS (different types). A caller passing
# connected=0/1 to mean off/on would violate the lease's boolean contract. THEREFORE
# pool_lease_write MUST validate connected ∈ {true,false} EXPLICITLY before the jq build.
# (research §4b; verified: echo '{}' | jq --argjson v 1 '.x=$v' → {"x":1}.)

# CRITICAL (host-verified): --argjson rejects non-JSON with exit 2.
# Empty string, "abc", an unquoted word → "jq: invalid JSON text passed to --argjson",
# exit 2. This is the validation backstop for numeric fields in BOTH functions: a
# non-numeric port/chrome_pid (write) or a non-JSON value/empty (update) makes jq fail
# → wrap in `|| pool_die`. (verified: --argjson v "" → exit 2; --argjson v abc → exit 2.)

# CRITICAL (injection-safe field update): use `jq --arg f "$field" --argjson v "$value"
# '.[$f] = $v'`. The field name + value enter jq as DATA (--arg/--argjson), never spliced
# into the filter program text (which is the fixed literal `.[$f] = $v`). NEVER build a
# filter by interpolation: `jq ".${field}=${val}"` is fragile/injectable. .[$f]=$v
# PRESERVES sibling fields + the owner sub-object (host-verified). A `^[a-zA-Z_]
# [a-zA-Z0-9_]*$` regex on the field name is defense-in-depth (rejects nonsense even
# though .[ $f ] is already safe) and matches every top-level schema field.

# CRITICAL (no trailing newline — intentional, harmless): jq emits a trailing '\n'; bash
# command substitution $() STRIPS ALL trailing newlines. So json="$(jq -n …)" has NO
# trailing newline, and _pool_atomic_write's printf '%s' preserves that exactly → the
# lease FILE is newline-less. Every JSON consumer (jq, the read layer M3.T1.S2) handles
# this fine. Do NOT try to re-add a newline (it would complicate the round-trip for no
# functional gain). Document it; move on.

# CRITICAL (SC2155 — declare and assign SEPARATELY): `local x="$(cmd)"` masks cmd's exit
# status. The captures here are PLAIN assignments after a `local` declaration:
#     local json lease_file
#     json="$(jq -n …)" || pool_die …
# A plain assignment's status == the command-substitution's status, so `|| pool_die`
# fires correctly on jq failure. NEVER write `local json="$(jq …)"`.

# CRITICAL (set -e + jq failure): a bare `json="$(jq …)"` whose jq FAILS aborts under
# set -e (propagated by S1) before pool_die can run. ALWAYS `json="$(jq …)" || pool_die …`
# — the `||` list is errexit-exempt.

# CRITICAL (set -e + [[ ]]): a bare `[[ "$lane" =~ ^[0-9]+$ ]]` that is false returns 1
# and ABORTS under set -e. ALWAYS `[[ … ]] || pool_die …` (the `||` list is exempt).

# CRITICAL (atomicity comes from _pool_atomic_write, NOT from these fns): do NOT open a
# .tmp or call mv yourself. Build the JSON string, then hand it to
# `_pool_atomic_write "$POOL_LANES_DIR/$lane.json" "$json"`. The primitive guarantees
# same-dir tmp → same-FS → atomic rename, and pool_die on failure.

# CRITICAL (do NOT mkdir): neither function creates $POOL_LANES_DIR. Callers must run
# pool_state_init (M1.T1.S3) first. A missing dir surfaces as a pool_die from
# _pool_atomic_write — the desired loud failure (do not mask it with a silent mkdir).

# GOTCHA (a jq BUILD failure never corrupts the existing lease): pool_lease_write computes
# `json` fully BEFORE calling _pool_atomic_write; pool_lease_update computes `updated`
# fully BEFORE calling _pool_atomic_write. So if jq fails, the existing lease is untouched
# (pool_die fires before any write). Only a successful jq result reaches _pool_atomic_write.

# GOTCHA (owner.* is never updated in place): pool_lease_update is TOP-LEVEL fields only.
# The owner sub-object is written once at acquire (pool_lease_write) and never mutated.
# This matches every real consumer (M5.T1.S2 patches port/chrome_pid/chrome_pgid/connected;
# M5.T1.S3 patches last_seen_at). Do NOT add dotted-path support.

# GOTCHA (no logging on the happy path): these are write primitives called inside the
# flock critical section and on every heartbeat. Logging "wrote lane N" each time would
# flood the pool log. Callers (M5 acquire/release) log at the OPERATION level. (Matches
# the T2.S1 primitive convention.) It is acceptable for pool_die's stderr message to be
# the only output on failure.

# GOTCHA (pool_die, not return 1): these are WRITERS expected to succeed; failure is
# exceptional and fatal to the caller (a failed lease write inside acquire means the pool
# is in trouble). Use pool_die (exit 1). Do NOT return non-zero silently.

# GOTCHA (scope): this task is the WRITE layer ONLY. Do NOT: read+validate a lease
# (M3.T1.S2); query lanes (M3.T2.*); delete/teardown a lease (M5.T2.S1); acquire/release
# orchestration or flock (M5.T1.*); range-validate port (M4.T2.S1 find_free_port).
```

## Implementation Blueprint

### Data models and structure

This subtask defines no new globals and no on-disk layout (the layout is
`$POOL_LANES_DIR/<N>.json`, already established by M1). It defines TWO functions whose
data contract is the PRD §2.8 lease object. Per-field jq flag (see
`research/lease-schema-and-consumers.md` §1):

| field | JSON type | jq flag | arg / source |
|---|---|---|---|
| `version` | number | `--argjson` | constant `1` |
| `lane` | number | `--argjson` | `$1` (validated `^[0-9]+$`) |
| `ephemeral_dir` | string | `--arg` | `$2` |
| `port` | number | `--argjson` | `$3` (placeholder `0`) |
| `session` | string | `--arg` | `$4` |
| `owner.pid` | number | `--argjson` | `$5` |
| `owner.comm` | string | `--arg` | `$6` |
| `owner.starttime` | number | `--argjson` | `$7` |
| `owner.cwd` | string | `--arg` | `$8` |
| `chrome_pid` | number | `--argjson` | `$9` (placeholder `0`) |
| `chrome_pgid` | number | `--argjson` | `$10` (placeholder `0`) |
| `acquired_at` | number | `--argjson` | `$(_pool_now)` (auto, captured once) |
| `last_seen_at` | number | `--argjson` | `$(_pool_now)` (auto, same capture) |
| `connected` | boolean | `--argjson` | `$11` (validated `true`/`false`) |

**Naming**: both are `pool_lease_*` (lease subdomain; item-description-mandated exact
names). No `_` prefix — they are the lease-subdomain entry points (mirrors
`pool_owner_resolve`). Internal-only in practice (never operator-invoked).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 0: VERIFY the dependencies (M1 primitives + globals) are present and locate the append point
  - RUN: test -f lib/pool.sh && bash -c 'set -euo pipefail; source lib/pool.sh; \
             type _pool_atomic_write _pool_json_valid _pool_now pool_die pool_config_init'
  - EXPECT: all five reported as functions. (These are M1 — COMPLETE. If any is MISSING,
        STOP — this subtask depends on M1.T2.S1; the orchestrator sequences it first.)
  - RUN (confirm POOL_LANES_DIR resolves after pool_config_init):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 echo "LANES=$POOL_LANES_DIR"; [[ "$POOL_LANES_DIR" == /* ]] && echo OK-abs'
  - EXPECT: an ABSOLUTE path (no '~') + OK-abs.
  - RUN (confirm jq present + the key behaviors this task relies on):
        bash -c 'jq --version; jq -n --argjson p 0 --argjson c false "{port:\$p,conn:\$c}"; \
                 echo "{\"port\":0}" | jq --argjson v 9 --arg f port ".[\$f] = \$v"; \
                 echo "{}" | jq --argjson v "" ".x=\$v" 2>/dev/null; echo "argjson-empty-exit=$?"'
  - EXPECT: jq-1.8.2; a {"port":0,"conn":false} object; a {"port":9} object; and
        argjson-empty-exit=2 (the --argjson-rejects-non-JSON backstop).
  - RUN (locate the append point — EOF):
        grep -nE '^[a-z_][a-z_0-9]*\(\)' lib/pool.sh | tail -3
        tail -5 lib/pool.sh
  - EXPECT: the last function is pool_owner_resolve OR pool_owner_alive (if M2.T2.S1
        landed in parallel). APPEND a new section below it. Do NOT touch any owner fn.
  - RUN (file is otherwise clean):
        bash -n lib/pool.sh && echo OK
  - EXPECT: OK.

Task 1: APPEND pool_lease_write() to lib/pool.sh (new "Lease management" section, at EOF)
  - PLACEMENT: directly below the last owner-resolution function (pool_owner_resolve, or
        pool_owner_alive if it landed). Add a section banner:
        # =============================================================================
        # Lease management — JSON write & atomic update (P1.M3.T1.S1)
        # =============================================================================
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_write LANE EPHEMERAL_DIR PORT SESSION OWNER_PID OWNER_COMM \
        #                  OWNER_STARTTIME OWNER_CWD CHROME_PID CHROME_PGID CONNECTED
        #
        # Build the FULL lease object (PRD §2.8 schema) with jq -n and publish it
        # atomically to $POOL_LANES_DIR/<LANE>.json. version is fixed at 1;
        # acquired_at and last_seen_at are both stamped to $(_pool_now) (captured ONCE,
        # so they match). Composes _pool_atomic_write (M1.T2.S1) for the tmp+mv publish.
        #
        # CONSUMERS: M5.T1.S1 acquire (provisional claim: PORT/CHROME_PID/CHROME_PGID=0,
        # CONNECTED=false) ; the read/query layer (M3.T1.S2 / M3.T2.*) reads what this
        # writes.
        #
        # TYPING (research §1): numbers + the boolean + timestamps use --argjson; strings
        # (ephemeral_dir, session, owner.comm, owner.cwd) use --arg. The #1 lease bug is
        # --arg on a number → a quoted string; --argjson keeps the type.
        #
        # GOTCHA — connected must be a JSON BOOLEAN: --argjson connected 1 would store the
        # NUMBER 1, not true. Validate connected ∈ {true,false} explicitly.
        # GOTCHA — non-numeric numerics make the jq build fail (exit 1 inside $(…)) → the
        # `|| pool_die` fires.
        # GOTCHA — $(jq …) strips jq's trailing newline, so the file is newline-less
        # (harmless; every JSON consumer handles it). _pool_atomic_write's printf '%s'
        # preserves the exact bytes.
        # GOTCHA — a jq BUILD failure happens BEFORE _pool_atomic_write, so the existing
        # lease (if any) is never corrupted by a failed build.
        # PRECONDITION: pool_config_init (for POOL_LANES_DIR) and pool_state_init (to
        # create the dir) must have run. A missing dir → _pool_atomic_write pool_die.
        pool_lease_write() {
            local lane="${1:-}"
            local ephemeral_dir="${2:-}"
            local port="${3:-}"
            local session="${4:-}"
            local owner_pid="${5:-}"
            local owner_comm="${6:-}"
            local owner_starttime="${7:-}"
            local owner_cwd="${8:-}"
            local chrome_pid="${9:-}"
            local chrome_pgid="${10:-}"
            local connected="${11:-}"
            local now json lease_file

            # Validate lane (the index) and connected (must be a JSON boolean literal).
            # `[[ ]] || pool_die` is errexit-exempt.
            [[ "$lane" =~ ^[0-9]+$ ]] \
                || pool_die "pool_lease_write: lane must be a non-negative integer, got: '$lane'"
            [[ "$connected" == "true" || "$connected" == "false" ]] \
                || pool_die "pool_lease_write: connected must be 'true' or 'false' (a JSON boolean), got: '$connected'"

            # One timestamp capture → acquired_at == last_seen_at for a fresh lease.
            now="$(_pool_now)"

            # Build the JSON. Every field name + value is jq DATA (--arg/--argjson); the
            # filter is a fixed literal → injection-safe. PLAIN assignment (not
            # `local x=$(…)`) so jq's exit status reaches `|| pool_die` (SC2155).
            json="$(jq -n \
                --argjson version 1 \
                --argjson lane "$lane" \
                --arg ephemeral_dir "$ephemeral_dir" \
                --argjson port "$port" \
                --arg session "$session" \
                --argjson owner_pid "$owner_pid" \
                --arg owner_comm "$owner_comm" \
                --argjson owner_starttime "$owner_starttime" \
                --arg owner_cwd "$owner_cwd" \
                --argjson chrome_pid "$chrome_pid" \
                --argjson chrome_pgid "$chrome_pgid" \
                --argjson acquired_at "$now" \
                --argjson last_seen_at "$now" \
                --argjson connected "$connected" \
                '{version:$version, lane:$lane, ephemeral_dir:$ephemeral_dir, port:$port,
                  session:$session,
                  owner:{pid:$owner_pid,comm:$owner_comm,starttime:$owner_starttime,cwd:$owner_cwd},
                  chrome_pid:$chrome_pid, chrome_pgid:$chrome_pgid,
                  acquired_at:$acquired_at, last_seen_at:$last_seen_at, connected:$connected}')" \
                || pool_die "pool_lease_write: failed to build lease JSON for lane $lane" \
                            "(check numeric field values: port=$port owner_pid=$owner_pid" \
                            "owner_starttime=$owner_starttime chrome_pid=$chrome_pid" \
                            "chrome_pgid=$chrome_pgid)"

            # Atomic publish (tmp in same dir → same FS → atomic rename). pool_die on failure.
            lease_file="$POOL_LANES_DIR/$lane.json"
            _pool_atomic_write "$lease_file" "$json"
        }
  - FOLLOW pattern: `local …` declared FIRST, captures AFTER (SC2155); `[[ ]] || pool_die`
        (errexit-exempt); `… "$(jq …)" || pool_die` (set -e safe + status-preserving);
        compose _pool_atomic_write for the publish; ONE _pool_now capture.
  - GOTCHA: numbers/bool/timestamps use --argjson; strings use --arg. connected validated.
  - GOTCHA: do NOT mkdir; do NOT add a trailing newline; do NOT log on success.
  - NAMING: pool_lease_write (item-mandated; lease subdomain).
  - PLACEMENT: first function in the new "Lease management" section.

Task 2: APPEND pool_lease_update() to lib/pool.sh (directly below pool_lease_write)
  - IMPLEMENT (verbatim-ready — paste this function body):
        # pool_lease_update LANE FIELD VALUE
        #
        # Read the EXISTING lease for LANE, set the top-level FIELD to VALUE (spliced as
        # raw JSON via --argjson), and re-publish atomically. Sibling fields and the
        # `owner` sub-object are PRESERVED. Used by the post-lock boot (M5.T1.S2:
        # port/chrome_pid/chrome_pgid/connected) and the heartbeat (M5.T1.S3:
        # last_seen_at).
        #
        # FIELD is TOP-LEVEL only (regex ^[a-zA-Z_][a-zA-Z0-9_]*$); dotted `owner.*`
        # updates are NOT supported (owner is written once at acquire, never mutated).
        #
        # VALUE typing: it is parsed as JSON by --argjson, so 53427 → number,
        # true/false → boolean, '"str"' → string (caller must quote). An empty/non-JSON
        # value makes jq exit 2 → pool_die.
        #
        # INJECTION SAFETY (research §2): the filter is the fixed literal `.[$f] = $v`;
        # FIELD and VALUE enter jq as DATA (--arg/--argjson), never spliced into the
        # program. The field regex is defense-in-depth.
        # GOTCHA — a missing or corrupted lease is a pool_die (update assumes a valid
        # lease just written by THIS process under flock; corruption is exceptional).
        # GOTCHA — the mutate is computed BEFORE _pool_atomic_write, so a jq failure never
        # touches the existing lease.
        # PRECONDITION: pool_config_init + pool_state_init; the lease must already exist
        # (written by pool_lease_write).
        pool_lease_update() {
            local lane="${1:-}"
            local field="${2:-}"
            local value="${3:-}"
            local lease_file updated

            # Validate lane + field name (safe identifier — defense-in-depth even though
            # .[$f] is already injection-safe).
            [[ "$lane" =~ ^[0-9]+$ ]] \
                || pool_die "pool_lease_update: lane must be a non-negative integer, got: '$lane'"
            [[ "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
                || pool_die "pool_lease_update: invalid field name: '$field' (top-level identifier only)"

            lease_file="$POOL_LANES_DIR/$lane.json"

            # The lease must already exist.
            [[ -f "$lease_file" ]] \
                || pool_die "pool_lease_update: lease file does not exist: $lease_file"

            # Syntax pre-check for a clear error (composes the M1.T2.S1 predicate).
            if ! _pool_json_valid "$lease_file"; then
                pool_die "pool_lease_update: lease file is not valid JSON: $lease_file"
            fi

            # Mutate one top-level field; preserve siblings + owner. PLAIN assignment so
            # jq's exit status reaches `|| pool_die` (SC2155). A non-JSON value (empty,
            # unquoted text) → jq --argjson exit 2 → pool_die.
            updated="$(jq --argjson v "$value" --arg f "$field" '.[$f] = $v' "$lease_file")" \
                || pool_die "pool_lease_update: failed to update lane $lane field '$field'" \
                            "(value must be valid JSON: number, true/false, or a quoted string;" \
                            "got: '$value')"

            # Atomic re-publish.
            _pool_atomic_write "$lease_file" "$updated"
        }
  - FOLLOW pattern: same strict-mode guards as Task 1; `.[$f] = $v` (injection-safe,
        sibling-preserving); _pool_json_valid pre-check for a clear message; compute
        `updated` BEFORE the atomic write.
  - GOTCHA: top-level fields ONLY. Do NOT add dotted-path support.
  - GOTCHA: VALUE is raw JSON — document that a string value needs caller-supplied quotes.
  - NAMING: pool_lease_update (item-mandated; lease subdomain).
  - PLACEMENT: directly below pool_lease_write (last function in the new section).

Task 3: VERIFY (run BEFORE claiming done — every command must pass)
  - RUN: bash -n lib/pool.sh                                   # syntax — MUST be clean
  - RUN: shellcheck lib/pool.sh                                # zero warnings (whole file)
  - RUN (both functions defined + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; type pool_lease_write pool_lease_update' \
            >/dev/null && echo OK
        # EXPECT: OK.
  - RUN (happy-path write: correct schema + types):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/home/dustin/projects/x" 104816 104816 true; \
                 f="$POOL_LANES_DIR/7.json"; \
                 jq -e "\".version==1 and .lane==7 and .ephemeral_dir==\"/x/7\" and .port==53427 and .session==\"abpool-7\" and .owner.pid==836725 and .owner.comm==\"pi\" and .owner.starttime==1234567890 and .owner.cwd==\"/home/dustin/projects/x\" and .chrome_pid==104816 and .chrome_pgid==104816 and (.acquired_at|type)==\"number\" and (.last_seen_at|type)==\"number\" and .connected==true" "$f" >/dev/null; \
                 test "$(.acquired_at=; jq -r ".acquired_at" "$f")" = "$(jq -r ".last_seen_at" "$f")"; \
                 test ! -e "$f.tmp"; echo OK'
        # EXPECT: OK. (schema+types correct; acquired_at==last_seen_at; no orphan .tmp.)
  - RUN (provisional claim: port/chrome_pid/chrome_pgid=0, connected=false):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 3 "/x/3" 0 abpool-3 100 pi 99 "/c" 0 0 false; \
                 jq -e ".port==0 and .chrome_pid==0 and .chrome_pgid==0 and .connected==false" \
                     "$POOL_LANES_DIR/3.json" >/dev/null; echo OK'
        # EXPECT: OK.
  - RUN (connected REJECTS non-boolean: 1, 0, yes, "", True → pool_die, no file written):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        for bad in 1 0 yes "" True; do
          AGENT_BROWSER_POOL_STATE="$tmp/state" \
          bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                   pool_lease_write 1 "/x" 0 s 1 pi 1 "/c" 0 0 "'"$bad"'"' 2>/dev/null \
            && echo "FAIL: bad connected='$bad' was accepted" || echo "OK rejected connected='$bad'"
        done
        test ! -e "$tmp/state/lanes/1.json" && echo "OK no file written for bad connected"
        # EXPECT: five "OK rejected" lines + "OK no file written".
  - RUN (non-numeric lane → pool_die):
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
                 pool_lease_write abc "/x" 0 s 1 pi 1 "/c" 0 0 true' 2>&1 | grep -q "lane must be" \
            && echo OK || echo FAIL
        # EXPECT: OK (pool_die message mentions lane).
  - RUN (non-numeric numeric field → jq build fails → pool_die, no file):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 5 "/x" abc s 1 pi 1 "/c" 0 0 true' 2>/dev/null \
            && echo FAIL || echo "OK build-fail -> pool_die"
        test ! -e "$tmp/state/lanes/5.json" && echo "OK no file" || echo "FAIL file written"
        # EXPECT: OK build-fail -> pool_die + OK no file.
  - RUN (UPDATE: number field, siblings + owner preserved):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 0 abpool-7 836725 pi 1234567890 "/c" 0 0 false; \
                 pool_lease_update 7 port 53427; \
                 f="$POOL_LANES_DIR/7.json"; \
                 jq -e ".port==53427 and .lane==7 and .session==\"abpool-7\" and .owner.pid==836725 and .owner.comm==\"pi\" and .connected==false" "$f" >/dev/null; \
                 test ! -e "$f.tmp"; echo OK'
        # EXPECT: OK (port updated; lane/session/owner/connected unchanged; no .tmp).
  - RUN (UPDATE: boolean connected true; UPDATE: number last_seen_at):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
                 pool_lease_update 7 connected true; \
                 pool_lease_update 7 last_seen_at 1720000999; \
                 pool_lease_update 7 chrome_pid 555; \
                 pool_lease_update 7 chrome_pgid 555; \
                 jq -e ".connected==true and .last_seen_at==1720000999 and .chrome_pid==555 and .chrome_pgid==555" "$POOL_LANES_DIR/7.json" >/dev/null; echo OK'
        # EXPECT: OK (boolean stays boolean; numbers stay numbers).
  - RUN (UPDATE: missing lease → pool_die):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_update 9 port 1' 2>&1 | grep -q "does not exist" && echo OK || echo FAIL
        # EXPECT: OK.
  - RUN (UPDATE: corrupted lease → pool_die):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/state/lanes"; printf 'not json' > "$tmp/state/lanes/2.json"
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_update 2 port 1' 2>&1 | grep -q "not valid JSON" && echo OK || echo FAIL
        # EXPECT: OK.
  - RUN (UPDATE: invalid field name → pool_die):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 4 "/x" 0 s 1 pi 1 "/c" 0 0 false; \
                 pool_lease_update 4 "owner.pid" 9' 2>&1 | grep -q "invalid field name" \
            && echo OK || echo FAIL
        # EXPECT: OK (dotted name rejected — top-level only).
  - RUN (UPDATE: non-JSON value (empty) → pool_die, existing lease UNCHANGED):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 6 "/x" 0 s 1 pi 1 "/c" 0 0 false; \
                 before="$(cat "$POOL_LANES_DIR/6.json")"; \
                 pool_lease_update 6 port "" 2>/dev/null && echo FAIL || echo "OK reject empty"; \
                 after="$(cat "$POOL_LANES_DIR/6.json")"; \
                 [[ "$before" == "$after" ]] && echo "OK lease-unchanged" || echo "FAIL lease-changed"'
        # EXPECT: OK reject empty + OK lease-unchanged.
  - RUN (UPDATE: string value via caller-quoted JSON):
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        AGENT_BROWSER_POOL_STATE="$tmp/state" \
        bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
                 pool_lease_write 8 "/x" 0 s 1 pi 1 "/c" 0 0 false; \
                 pool_lease_update 8 session "\"abpool-8\""; \
                 jq -e ".session==\"abpool-8\"" "$POOL_LANES_DIR/8.json" >/dev/null; echo OK'
        # EXPECT: OK (string set via quoted-JSON value).
  - RUN (regression: all prior functions still present + callable):
        bash -c 'set -euo pipefail; source lib/pool.sh; \
                 type pool_die _pool_log pool_config_init pool_state_init \
                      _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
                      _pool_get_starttime _pool_owner_starttime pool_owner_resolve \
                      pool_lease_write pool_lease_update >/dev/null && echo OK'
        # EXPECT: OK (pool_owner_alive may also be present if M2.T2.S1 landed — fine).
  - FIX every failure before proceeding.
```

### Implementation Patterns & Key Details

```bash
# --- Pattern: the two functions (paste into a new "Lease management" section at EOF) -

# (section banner first)
pool_lease_write() {
    local lane="${1:-}"
    local ephemeral_dir="${2:-}"
    local port="${3:-}"
    local session="${4:-}"
    local owner_pid="${5:-}"
    local owner_comm="${6:-}"
    local owner_starttime="${7:-}"
    local owner_cwd="${8:-}"
    local chrome_pid="${9:-}"
    local chrome_pgid="${10:-}"
    local connected="${11:-}"
    local now json lease_file

    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_lease_write: lane must be a non-negative integer, got: '$lane'"
    [[ "$connected" == "true" || "$connected" == "false" ]] \
        || pool_die "pool_lease_write: connected must be 'true' or 'false' (a JSON boolean), got: '$connected'"

    now="$(_pool_now)"           # ONE capture → acquired_at == last_seen_at

    # Numbers/bool/timestamps → --argjson; strings → --arg. Filter is a fixed literal.
    # PLAIN assignment so jq's exit status reaches `|| pool_die` (SC2155).
    json="$(jq -n \
        --argjson version 1 \
        --argjson lane "$lane" \
        --arg ephemeral_dir "$ephemeral_dir" \
        --argjson port "$port" \
        --arg session "$session" \
        --argjson owner_pid "$owner_pid" \
        --arg owner_comm "$owner_comm" \
        --argjson owner_starttime "$owner_starttime" \
        --arg owner_cwd "$owner_cwd" \
        --argjson chrome_pid "$chrome_pid" \
        --argjson chrome_pgid "$chrome_pgid" \
        --argjson acquired_at "$now" \
        --argjson last_seen_at "$now" \
        --argjson connected "$connected" \
        '{version:$version, lane:$lane, ephemeral_dir:$ephemeral_dir, port:$port,
          session:$session,
          owner:{pid:$owner_pid,comm:$owner_comm,starttime:$owner_starttime,cwd:$owner_cwd},
          chrome_pid:$chrome_pid, chrome_pgid:$chrome_pgid,
          acquired_at:$acquired_at, last_seen_at:$last_seen_at, connected:$connected}')" \
        || pool_die "pool_lease_write: failed to build lease JSON for lane $lane" \
                    "(check numeric field values: port=$port owner_pid=$owner_pid" \
                    "owner_starttime=$owner_starttime chrome_pid=$chrome_pid chrome_pgid=$chrome_pgid)"

    lease_file="$POOL_LANES_DIR/$lane.json"
    _pool_atomic_write "$lease_file" "$json"
}

pool_lease_update() {
    local lane="${1:-}"
    local field="${2:-}"
    local value="${3:-}"
    local lease_file updated

    [[ "$lane" =~ ^[0-9]+$ ]] \
        || pool_die "pool_lease_update: lane must be a non-negative integer, got: '$lane'"
    [[ "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
        || pool_die "pool_lease_update: invalid field name: '$field' (top-level identifier only)"

    lease_file="$POOL_LANES_DIR/$lane.json"
    [[ -f "$lease_file" ]] \
        || pool_die "pool_lease_update: lease file does not exist: $lease_file"
    if ! _pool_json_valid "$lease_file"; then
        pool_die "pool_lease_update: lease file is not valid JSON: $lease_file"
    fi

    # Injection-safe: filter is fixed literal `.[$f] = $v`; field+value are jq DATA.
    # Siblings + owner preserved. Compute BEFORE the atomic write (no corruption on fail).
    updated="$(jq --argjson v "$value" --arg f "$field" '.[$f] = $v' "$lease_file")" \
        || pool_die "pool_lease_update: failed to update lane $lane field '$field'" \
                    "(value must be valid JSON: number, true/false, or a quoted string; got: '$value')"

    _pool_atomic_write "$lease_file" "$updated"
}

# --- Critical micro-rules baked into the above --------------------------------
#  * numbers/bool/timestamps use --argjson; strings use --arg (the #1 bug is --arg on a
#    number → a quoted string).
#  * connected is validated to literally "true"/"false" BEFORE the build (--argjson
#    connected 1 would store the NUMBER 1).
#  * lane + field validated with `[[ =~ ]] || pool_die` (errexit-exempt).
#  * `local …` declared FIRST, captures AFTER (SC2155) — so `… "$(jq …)" || pool_die`
#    correctly reflects jq's exit status. NEVER `local x="$(jq …)"`.
#  * `… "$(jq …)" || pool_die` — `||` makes a jq failure a controlled branch (set -e safe).
#  * `now="$(_pool_now)"` captured ONCE → acquired_at == last_seen_at.
#  * `_pool_atomic_write` owns tmp+same-dir mv; these fns never touch .tmp/mv directly.
#  * the mutate is computed in `updated` BEFORE _pool_atomic_write → a jq failure never
#    corrupts the existing lease.
#  * `.[$f] = $v` passes field+value as jq DATA (injection-safe); siblings preserved.
#  * top-level fields only (field regex); owner.* is never mutated.
#  * no mkdir (callers run pool_state_init); no trailing newline ($(jq) strips it;
#    intentional + harmless); no _pool_log on success (callers log at operation level).
#  * pool_die (not return 1) — writers are expected to succeed; failure is fatal.
```

### Integration Points

```yaml
CONSUMED (treated as already-implemented truth — M1 COMPLETE, M2.T2.S1 parallel):
  - _pool_atomic_write(filepath, content) (M1.T2.S1): the publish primitive. Called by
        BOTH functions. Owns tmp+same-dir mv; pool_die on failure; printf '%s' (exact bytes).
  - _pool_json_valid(filepath) (M1.T2.S1): predicate. Called by pool_lease_update as a
        syntax pre-check for a clear "not valid JSON" error. Never fatal.
  - _pool_now (M1.T2.S1): epoch seconds. Called ONCE per pool_lease_write to stamp
        acquired_at + last_seen_at.
  - pool_die (M1.T1.S1): exit-1 helper. The ONLY failure path (build/mutate/publish).
  - pool_config_init (M1.T1.S2): freezes POOL_LANES_DIR. PRECONDITION (callers run it).
  - pool_state_init (M1.T1.S3): creates $POOL_LANES_DIR. PRECONDITION (callers run it).

PROVIDED (the consumers — later subtasks):
  - P1.M3.T1.S2 (lease read + validation): reads $POOL_LANES_DIR/<N>.json; runs
        _pool_json_valid (syntax) then a stricter jq -e schema check. The schema written
        HERE must match the schema validated THERE (PRD §2.8).
  - P1.M3.T2.* (lease queries): read-only over the leases these functions write
        (enumerate / find_my_lease / find_free_lane / is_lane_stale).
  - P1.M5.T1.S1 (acquire critical section): pool_lease_write with PROVISIONAL values
        (port=0 chrome_pid=0 chrome_pgid=0 connected=false) under flock; releases lock
        before Chrome boot (key_findings FINDING 2).
  - P1.M5.T1.S2 (post-lock boot): pool_lease_update for port/chrome_pid/chrome_pgid/
        connected after Chrome is up + daemon connected.
  - P1.M5.T1.S3 (ensure_connected): pool_lease_update lane last_seen_at <now> heartbeat.
  - P1.M7.T1.S1 (admin status): reads acquired_at → _pool_age_str (consumes the
        timestamp these functions write).

CONFIG / DATABASE / ROUTES: none. No new env vars. No new globals (reads POOL_LANES_DIR,
        frozen by pool_config_init). No dir I/O beyond the lease file (dirs are the
        caller's responsibility via pool_state_init). No user docs ("internal functions";
        the schema is documented in PRD §2.8).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After appending the two functions — fix before Level 2.
bash -n lib/pool.sh                # parse check. MUST be clean (zero output).
shellcheck lib/pool.sh             # MUST report zero issues (whole file, incl. all prior subtasks).
# Expected: zero output from both.
```

### Level 2: Unit Tests (Component Validation)

No bats framework yet (M9.T1.S1 builds it). Validate inline (these become regression
seeds). Each block is self-contained (its own $tmp state dir, cleaned on EXIT).

```bash
# 2a. Both functions defined + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; type pool_lease_write pool_lease_update' >/dev/null && echo OK
# Expected: OK.

# 2b. Happy-path write: schema + types + acquired_at==last_seen_at + no orphan .tmp.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 53427 abpool-7 836725 pi 1234567890 "/home/dustin/projects/x" 104816 104816 true; \
         f="$POOL_LANES_DIR/7.json"; \
         jq -e ".version==1 and .lane==7 and .port==53427 and .session==\"abpool-7\" and .owner.pid==836725 and .owner.comm==\"pi\" and .owner.starttime==1234567890 and .owner.cwd==\"/home/dustin/projects/x\" and .chrome_pid==104816 and .chrome_pgid==104816 and (.acquired_at|type)==\"number\" and (.last_seen_at|type)==\"number\" and .connected==true" "$f" >/dev/null; \
         test "$(jq -r ".acquired_at" "$f")" = "$(jq -r ".last_seen_at" "$f")"; \
         test ! -e "$f.tmp"; echo OK'
# Expected: OK.

# 2c. Provisional claim (placeholders) — the acquire M5.T1.S1 call shape.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 3 "/x/3" 0 abpool-3 100 pi 99 "/c" 0 0 false; \
         jq -e ".port==0 and .chrome_pid==0 and .chrome_pgid==0 and .connected==false" "$POOL_LANES_DIR/3.json" >/dev/null; echo OK'
# Expected: OK.

# 2d. connected rejects non-booleans (0/1/yes/""/True) → pool_die, no file.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for bad in 1 0 yes "" True; do
  AGENT_BROWSER_POOL_STATE="$tmp/state" \
  bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
           pool_lease_write 1 "/x" 0 s 1 pi 1 "/c" 0 0 "'"$bad"'"' 2>/dev/null \
    && echo "FAIL accepted '$bad'" || echo "OK rejected '$bad'"
done
test ! -e "$tmp/state/lanes/1.json" && echo "OK no-file"
# Expected: five "OK rejected" + "OK no-file".

# 2e. Non-numeric lane + non-numeric port → pool_die, no file.
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; \
         pool_lease_write abc "/x" 0 s 1 pi 1 "/c" 0 0 true' 2>&1 | grep -q "lane must be" && echo OK1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 5 "/x" abc s 1 pi 1 "/c" 0 0 true' 2>/dev/null && echo FAIL2 || echo OK2
test ! -e "$tmp/state/lanes/5.json" && echo OK2-nofile
# Expected: OK1, OK2, OK2-nofile.

# 2f. UPDATE number field — siblings + owner preserved, no .tmp.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 0 abpool-7 836725 pi 1234567890 "/c" 0 0 false; \
         pool_lease_update 7 port 53427; \
         f="$POOL_LANES_DIR/7.json"; \
         jq -e ".port==53427 and .lane==7 and .session==\"abpool-7\" and .owner.pid==836725 and .owner.comm==\"pi\" and .connected==false" "$f" >/dev/null; \
         test ! -e "$f.tmp"; echo OK'
# Expected: OK.

# 2g. UPDATE boolean + numbers (post-lock-boot shape) + heartbeat.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 7 "/x/7" 0 abpool-7 1 pi 1 "/c" 0 0 false; \
         pool_lease_update 7 connected true; \
         pool_lease_update 7 chrome_pid 555; \
         pool_lease_update 7 chrome_pgid 555; \
         pool_lease_update 7 last_seen_at 1720000999; \
         jq -e ".connected==true and .chrome_pid==555 and .chrome_pgid==555 and .last_seen_at==1720000999" "$POOL_LANES_DIR/7.json" >/dev/null; echo OK'
# Expected: OK.

# 2h. UPDATE error paths: missing lease / corrupted lease / bad field name / non-JSON value.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# missing
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_lease_update 9 port 1' 2>&1 | grep -q "does not exist" && echo OK-missing
# corrupted
mkdir -p "$tmp/state/lanes"; printf 'not json' > "$tmp/state/lanes/2.json"
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_lease_update 2 port 1' 2>&1 | grep -q "not valid JSON" && echo OK-corrupt
# bad field name (dotted)
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 4 "/x" 0 s 1 pi 1 "/c" 0 0 false; pool_lease_update 4 "owner.pid" 9' 2>&1 | grep -q "invalid field name" && echo OK-badfield
# non-JSON value (empty) — existing lease UNCHANGED
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 6 "/x" 0 s 1 pi 1 "/c" 0 0 false; \
         b="$(cat "$POOL_LANES_DIR/6.json")"; \
         pool_lease_update 6 port "" 2>/dev/null && echo FAIL || echo OK-reject-empty; \
         a="$(cat "$POOL_LANES_DIR/6.json")"; [[ "$b" == "$a" ]] && echo OK-unchanged'
# Expected: OK-missing, OK-corrupt, OK-badfield, OK-reject-empty, OK-unchanged.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. Full file sources; all prior + new functions present + callable.
bash -c 'set -euo pipefail; source lib/pool.sh; \
         type pool_die _pool_log pool_config_init pool_state_init \
              _pool_atomic_write _pool_json_valid _pool_now _pool_age_str \
              _pool_get_starttime _pool_owner_starttime pool_owner_resolve \
              pool_lease_write pool_lease_update >/dev/null && echo OK'
# Expected: OK.

# 3b. Downstream-consumer simulation: the realistic acquire flow (resolve → write
#     provisional → boot → patch → heartbeat), all via these two functions.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
AGENT_BROWSER_POOL_OWNER_PID="$$" \
AGENT_BROWSER_POOL_OWNER_STARTTIME="123" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; pool_owner_resolve; \
         lane=1; \
         pool_lease_write "$lane" "/x/$lane" 0 "abpool-$lane" "$POOL_OWNER_PID" "$POOL_OWNER_COMM" "$POOL_OWNER_STARTTIME" "$POOL_OWNER_CWD" 0 0 false; \
         # ... Chrome boots, port 53420 chosen, pid/pgid 4242, daemon connects ... \
         pool_lease_update "$lane" port 53420; \
         pool_lease_update "$lane" chrome_pid 4242; \
         pool_lease_update "$lane" chrome_pgid 4242; \
         pool_lease_update "$lane" connected true; \
         pool_lease_update "$lane" last_seen_at "$(_pool_now)"; \
         jq -e ".port==53420 and .chrome_pid==4242 and .chrome_pgid==4242 and .connected==true and .owner.pid==$$" "$POOL_LANES_DIR/$lane.json" >/dev/null; \
         echo "OK full-lifecycle lane=$lane"'
# Expected: OK full-lifecycle lane=1.

# 3c. Atomicity: a concurrent reader (here, a parallel jq) never sees a torn file.
#     Run 20 write/read races; every read must be valid JSON.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" bash -c 'source lib/pool.sh; pool_config_init; pool_state_init'
ok=1
for i in $(seq 1 20); do
  AGENT_BROWSER_POOL_STATE="$tmp/state" \
    bash -c "set -euo pipefail; source lib/pool.sh; pool_config_init; \
             pool_lease_update $((i%3+1)) last_seen_at $i 2>/dev/null || \
             pool_lease_write $((i%3+1)) /x 0 s 1 pi 1 /c 0 0 false" &
  AGENT_BROWSER_POOL_STATE="$tmp/state" \
    bash -c "source lib/pool.sh; pool_config_init; f=\$POOL_LANES_DIR/$((i%3+1)).json; \
             [[ -f \$f ]] && { jq empty \"\$f\" 2>/dev/null || { echo TORN; exit 9; }; }" 
  wait
done
echo "OK no-torn-reads (ok=$ok)"
# Expected: OK no-torn-reads (ok=1). (Every observed file is valid JSON or absent — never torn.)

# 3d. No stray repo artifacts (these fns write only under $POOL_LANES_DIR/state).
git status --porcelain --untracked-files=all | grep -E '\.(log|lock)$' \
  || echo "repo clean of stray runtime artifacts"
# Expected: 'repo clean of stray runtime artifacts' (only lib/pool.sh modified).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Re-confirm the host jq facts the implementation depends on.
echo "jq: $(jq --version) at $(command -v jq)"
echo "--argjson number : $(jq -n --argjson p 53427 '{port:$p}')"
echo "--argjson boolean: $(jq -n --argjson c true  '{connected:$c}')"
echo "--argjson 1 → number (NOT bool): $(jq -n --argjson x 1 '{x:$x}' | jq -r '.x|type')"
echo "update .[\$f]=\$v (siblings kept): $(echo '{"a":1,"b":2}' | jq --argjson v 9 --arg f a '.[$f]=$v')"

# 4b. Type integrity sweep: every field's JSON type after a write matches the schema.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
AGENT_BROWSER_POOL_STATE="$tmp/state" \
bash -c 'set -euo pipefail; source lib/pool.sh; pool_config_init; pool_state_init; \
         pool_lease_write 1 /x 53420 abpool-1 100 pi 200 /c 300 301 true; \
         jq -r "to_entries[]|\"\(.key): \(.value|type)\" + (if (.value|type)==\"object\" then \"{\" + ([.value|to_entries[]|\"\(.key):\(.value|type)\"]|join(\",\")) + \"}\" else \"\" end)" "$POOL_LANES_DIR/1.json"'
# Expected: version/number, lane/number, ephemeral_dir/string, port/number,
#   session/string, owner/object{pid:number,comm:string,starttime:number,cwd:string},
#   chrome_pid/number, chrome_pgid/number, acquired_at/number, last_seen_at/number,
#   connected/boolean. (NO field is the wrong type.)

# 4c. shellcheck SC2155 sweep — no `local x="$(cmd)"` masking inside the new functions.
sed -n '/^pool_lease_write() {/,/^}/p;/^pool_lease_update() {/,/^}/p' lib/pool.sh \
  | grep -nE 'local [a-z_]+="\$\(' && echo "FAIL: SC2155 violation" || echo "OK SC2155-clean"
# Expected: OK SC2155-clean.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully.
- [ ] `bash -n lib/pool.sh` clean (zero output).
- [ ] `shellcheck lib/pool.sh` reports zero issues (whole file).
- [ ] Both functions callable after `source lib/pool.sh` (2a).
- [ ] Happy-path write produces correct schema + types + `acquired_at==last_seen_at` + no orphan `.tmp` (2b).
- [ ] Provisional-claim shape (port/pid/pgid=0, connected=false) works (2c).
- [ ] `connected` rejects `0`/`1`/`yes`/`""`/`True` (2d).
- [ ] Non-numeric lane + non-numeric numeric field → pool_die, no file (2e).
- [ ] UPDATE preserves siblings + owner (2f); UPDATE types stay correct (2g).
- [ ] UPDATE error paths: missing / corrupted / bad field / non-JSON value (2h).
- [ ] Full lifecycle (resolve → write → patch → heartbeat) works (3b).
- [ ] No torn reads under concurrent write/read (3c).
- [ ] No stray repo artifacts (3d).

### Feature Validation

- [ ] Lease written matches PRD §2.8 schema byte-for-shape (version/lane/ephemeral_dir/
      port/session/owner{pid,comm,starttime,cwd}/chrome_pid/chrome_pgid/acquired_at/
      last_seen_at/connected) — verified by 2b + 4b.
- [ ] Every field has the correct JSON type (number vs string vs boolean) — 4b.
- [ ] Atomic publish (tmp+mv) via `_pool_atomic_write`; never writes the lease in place.
- [ ] `pool_lease_update` is injection-safe (field+value are jq DATA; filter is a fixed literal).
- [ ] Integration points match the consumer contract (M5.T1.S1 provisional write, M5.T1.S2
      post-boot patch, M5.T1.S3 heartbeat) — 3b.

### Code Quality Validation

- [ ] Follows existing `lib/pool.sh` patterns (`pool_die`, `_pool_*` composition, `[[ ]] ||
      pool_die`, SC2155 two-statement captures, `|| pool_die` on jq).
- [ ] File placement: new "Lease management" section at EOF, below the owner section.
- [ ] Anti-patterns avoided: no mkdir, no trailing-newline re-add, no `_pool_log` on
      success, no `local x="$(…)"`, no jq-filter interpolation, no dotted-field updates.
- [ ] Dependencies properly composed (`_pool_atomic_write`, `_pool_json_valid`,
      `_pool_now`, `pool_die`, `POOL_LANES_DIR`); no new globals/env vars/files/deps.

### Documentation & Deployment

- [ ] Each function has a doc comment explaining contract, typing, gotchas, consumers,
      and preconditions.
- [ ] No new user docs (internal functions; schema documented in PRD §2.8).
- [ ] No new env vars to document.

---

## Anti-Patterns to Avoid

- ❌ Don't write the lease in place — compose `_pool_atomic_write` (tmp + same-dir mv).
- ❌ Don't use `--arg` for numbers/booleans/timestamps (→ quoted strings / wrong type).
- ❌ Don't validate `connected` lazily — `--argjson connected 1` silently stores a number.
- ❌ Don't build a jq filter by interpolating field names/values — pass as `--arg`/`--argjson` data.
- ❌ Don't `local x="$(jq …)"` (masks exit status) — declare first, assign after.
- ❌ Don't leave a bare `jq …` ungoverned under `set -e` — always `… || pool_die`.
- ❌ Don't mkdir inside these functions — callers run `pool_state_init`.
- ❌ Don't re-add a trailing newline — `$(jq)` strips it; it's harmless and intentional.
- ❌ Don't add dotted/`owner.*` update support — top-level only (matches all consumers).
- ❌ Don't catch-all and continue — writers use `pool_die` (failure is fatal to the caller).
