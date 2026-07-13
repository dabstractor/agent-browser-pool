# Research — `pool_reap_stale()` design (P1.M5.T3.S1)

> The lazy reaper: scan every lane, release every stale one, echo the reaped count.
> Read-only research (host-verified code reads + 2 fresh-eyes subagents: `scout` codebase
> recon + `researcher` bash-correctness brief). No files edited.

---

## §1 — THE defining architectural fact: acquire has its OWN inlined reap loop

The item CONTRACT says `pool_reap_stale` is "Consumed by acquire step 3a (M5.T1.S1)".
**This is LEGACY design intent.** The LANDED acquire critical section
(`_pool_acquire_critical_section`, `lib/pool.sh:1966`) does NOT call `pool_reap_stale` (nor
`pool_release_lane`). It has its OWN inlined reap loop (`lib/pool.sh:1974-1994`) that calls
the **PRIVATE** `_pool_release_lane_internals "$n"` directly (`lib/pool.sh:1992`):

```bash
# (a/b) REAP-STALE + REUSE-ORPHAN, interleaved per lane in ascending order.
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then
        ... (reuse-orphan check) ...
        # REAP-STALE: not adoptable (or adoption failed) → release the lane's resources.
        _pool_release_lane_internals "$n"      # PRIVATE kernel — NOT pool_release_lane
    fi
done
```

**WHY the split** (PRD §2.19 + `architecture/key_findings.md` FINDING 2): the acquire flock is
SHORT and claim-only. The daemon `close` SUBPROCESS (which `pool_release_lane` runs) is
FORBIDDEN under the short flock. So acquire reaps with the kernel only (no subprocess); the
standalone `pool_reap_stale` (which calls `pool_release_lane` + its `close`) runs OUTSIDE any
flock.

**The designed two-path split:**
| path | context | reaps via | daemon `close`? | flock? |
|---|---|---|---|---|
| acquire step 3a | INSIDE short flock (`pool_acquire_locked`) | `_pool_release_lane_internals` (private kernel) | NO | YES |
| **`pool_reap_stale`** (this task) | OUTSIDE any flock | `pool_release_lane` (public) | YES | NO |

**Implication for this PRP:** `pool_reap_stale` must NOT be wired into acquire (acquire's
loop is already shipped + correct + inlined). The REAL consumers of `pool_reap_stale` are:
1. **M7.T2.S1 `agent-browser-pool reap`** — the on-demand admin command (PRD §2.10 "on demand
   via `agent-browser-pool reap`"; §2.12 admin CLI). PRIMARY consumer.
2. **M5.T4.S1 exhaustion force-reap** — POSSIBLY (though M5.T4 may force-release a SPECIFIC
   oldest dead-owner lane via `pool_release_lane` directly; a full `pool_reap_stale` sweep is
   the alternative). Documented as a consumer context, not a hard dependency.

The CONTRACT's literal text is honored in SPIRIT: the reaper IS lazy (PRD §2.10), and stale
lanes ARE reaped on demand. The wiring detail (inlined-in-acquire vs standalone function) is
the implementer's call — and acquire already chose inline. So `pool_reap_stale` ships as the
**outside-the-flock, full-sweep, daemon-close-inclusive** reaper for the admin reap command.

---

## §2 — The dependency contracts (all LANDED + host-verified this session)

### 2.1 `pool_lane_is_stale LANE` — TRI-STATE verdict (`lib/pool.sh:1164`)
Returns:
- **`0`** = STALE (owner dead/recycled/unverifiable → caller reaps).
- **`1`** = LIVE (owner alive + identity matches → caller keeps).
- **`2`** = NO LEASE (file missing OR corrupt → caller skips).

Read-only verdict; NEVER kills/writes/logs itself (the only possible log is from its composed
`pool_lease_read`). Composes `pool_lease_read` + ONE jq fork for `owner.{pid,starttime,comm}`
+ `pool_owner_alive`.

**SET -e HAZARD** (`lib/pool.sh:1145-1148`): a BARE `pool_lane_is_stale "$n"` whose rc is 1
(live) or 2 (no lease) **ABORTS** the caller under `set -e`. The MANDATORY idiom is
`if pool_lane_is_stale "$n"; then reap; fi` — the `if` condition is errexit-exempt; rc 1/2
fall through cleanly; only rc 0 enters the body. (Bash manual, *The Set Builtin* `-e`: the
condition following `if` is in the exemption list.)

### 2.2 `pool_release_lane LANE` — PUBLIC teardown (`lib/pool.sh:2438`, CURRENT EOF @2480)
Returns **0 ALWAYS** (idempotent, non-fatal — never `pool_die`, never non-zero). Body:
1. validate lane (`^[0-9]+$` else `return 0`);
2. `pool_lease_read` → json; rc 1 (missing/corrupt) ⇒ `return 0` (idempotent "already released");
3. extract `.session` (reconstruct `abpool-$lane` if empty/null);
4. `if [[ -n "${POOL_REAL_BIN:-}" ]]; then "$POOL_REAL_BIN" --session "$session" close 2>/dev/null || true; fi`;
5. `_pool_release_lane_internals "$lane"` (KILL pgroup + RM DIR + RM LEASE — the kernel);
6. `_pool_log …; return 0`.

**NO flock** (lane-local + idempotent). The ONLY step the public layer adds over the kernel
is the daemon `close`. `close` is disconnect-only, rc always 0 on agent-browser 0.28.0, no
strays (host-verified in `P1M4T3S1/research/daemon-connect-teardown-host-verified.md` §3).

### 2.3 `pool_lanes_list` — iterator (`lib/pool.sh:967`)
Echoes every numeric lane stem from `$POOL_LANES_DIR/*.json`, one N per line, `sort -n`
ascending. **Always returns 0** (empty/missing dir is a valid state → no-match glob → 0
iterations → no output). The documented reaper idiom is `for n in $(pool_lanes_list)`
(`lib/pool.sh:960-963`): output is digits-only/newline-separated, so the unquoted command
substitution word-splits into exactly the lane numbers (intentional). nullglob is NOT set → a
no-match glob expands to the literal path → `[[ -f "$f" ]] || continue` rejects it.

Already used by `pool_lease_find_mine`, `pool_lease_find_mine_any`,
`_pool_acquire_critical_section`, `pool_find_free_port` — so the idiom is battle-proven.

### 2.4 `pool_lease_field LANE FIELD` — nested read (`lib/pool.sh:876`)
`jq -r --arg f "$field" 'getpath($f|split("."))' "$file"` — supports DOTTED nested paths
(e.g. `owner.pid`, `owner.starttime`). `--arg` = DATA (inject-safe; FIELD is never spliced).
Returns 1 on missing file / corrupt JSON / non-numeric lane; echoes the value + rc 0
otherwise (a MISSING PATH yields the literal `"null"` + rc 0). Used for the reaper log line's
owner pid. Already used for nested `owner.*` reads by `pool_lease_find_mine`.

### 2.5 `_pool_log MSG...` — file logger (`lib/pool.sh:39`)
Variadic message → appends `"<ISO-8601 ts> <msg>"` to the pool log file
(`$AGENT_BROWSER_POOL_STATE/pool.log` via `_pool_log_path`), falls back to stderr. **Never
fails the caller** (best-effort; `mkdir -p` the log dir; `|| printf … >&2`). **Writes to the
LOG FILE (or stderr), NEVER to stdout** — so logging inside `pool_reap_stale` does NOT pollute
the reaped-count stdout capture. Uses `printf -v ts '%(...)T' -1` (no `date` fork).

---

## §3 — bash correctness under `set -euo pipefail` (researcher brief, canonical sources)

### 3.1 The tri-state `if` is errexit-exempt
```bash
for n in $(pool_lanes_list); do
    if pool_lane_is_stale "$n"; then   # rc 0 => stale; rc 1/2 => false (NO abort)
        pool_release_lane "$n"
        reaped=$((reaped + 1))
    fi
done
```
Bash manual (*The Set Builtin*, `-e`): the shell does not exit if the failing command is
"part of the test following the `if` or `elif` reserved words". So rc 1 (live) and rc 2 (no
lease) are simply *false* — execution falls to the next iteration. **Only rc 0 enters the
body.** This is THE canonical pattern for multi-valued predicates under `set -e`.
(BashFAQ 105 — https://mywiki.wooledge.org/BashFAQ/105)

### 3.2 `local var=$(cmd)` masks errexit (SC2155); arithmetic form matters
- `local` always returns 0 → `local X="$(…)"` SWALLOWS the command's rc. Fix: declare FIRST,
  assign separately (`local X; X="$(…)"`). Applies to the pid capture.
- **`reaped=$((reaped + 1))`** = assignment form → exit status 0 → **safe**.
- ❌ `(( reaped++ ))` = command form → returns 1 when the pre-increment value is 0 →
  **ABORTS under set -e on the FIRST reap** when `reaped==0`. NEVER use it.
  (Bash manual *Compound Commands* `(( ))`: "exit status is 0 if the value of the expression
  is non-zero; otherwise 1".)

### 3.3 Word-split idiom + snapshot iteration
- `for n in $(pool_lanes_list)` is the INTENDED idiom for known-safe digit-only,
  newline-separated output. Word-splits on IFS (space/tab/newline) into exactly the lane
  numbers; no glob hazard (digits aren't metacharacters); `$()` strips trailing newlines.
  (Greg's Wiki — https://mywiki.wooledge.org/WordSplitting)
- **Snapshot semantics**: command substitution is fully evaluated BEFORE the loop body runs
  for the first time → the lane list is FROZEN. Releasing lanes mid-loop (deleting leases)
  CANNOT mutate the iteration set. (Bash manual *Command Substitution*.)
- **ShellCheck 0.11.0 (this host) does NOT flag** `for n in $(pool_lanes_list)` as SC2046 in
  this context — host-verified: `shellcheck -s bash lib/pool.sh` exits 0 on the current file
  (which already contains the identical idiom at `lib/pool.sh:1975` in acquire). **No disable
  directive needed.**
- If `pool_lanes_list` emits nothing → 0 iterations → reaped stays 0 → echo `0`. Correct.

### 3.4 Bonus (set -e): the `for … in $()` list's exit status is NOT checked by errexit
If `pool_lanes_list` itself failed, the loop would silently iterate over an empty list rather
than abort. `pool_lanes_list` returns 0 always, so this is moot — but it means a reap sweep is
never aborted by a lane-listing hiccup.

---

## §4 — flock verdict: NO flock for `pool_reap_stale`

Consensus (scout + researcher + the M5.T2.S1 PRP's identical decision for `pool_release_lane`
+ `architecture/key_findings.md` FINDING 2): **`pool_reap_stale` does NOT take the flock.**

Rationale:
- `pool_release_lane` is **lane-local + idempotent** — every kill/rm/close is
  `2>/dev/null || true`; a concurrent acquire's in-lock reap of the SAME lane is a harmless
  idempotent no-op (both kill the same pgroup `|| true`, rm the same dir/lease `|| true`,
  close the same session rc 0).
- A per-lane operation on a NAMED lane is the atomicity unit, not the whole sweep. There is
  NO non-atomic read-modify-write over a shared structure (the "count" is a local variable,
  not a shared file).
- Flocking the WHOLE sweep would SERIALIZE it against acquire — harmful: the daemon `close`
  subprocesses (one per stale lane) take time, and a long sweep would block new acquires.
  The lazy reaper is explicitly the OUTSIDE-the-flock path.
- The pool_lanes_list snapshot is taken once; lanes that appear/disappear mid-sweep are
  handled correctly by the per-lane tri-state check + idempotent release (a new lane not in
  the snapshot → not reaped this pass → reaped next pass; a lane deleted between list + check
  → `pool_lane_is_stale` returns 2 → skip; a lane that becomes live between list + check →
  `pool_lane_is_stale` returns 1 → skip).

**Contrast**: acquire's inlined reap DOES run under flock (it's part of the claim critical
section that must be serialized). The standalone `pool_reap_stale` does not. Both are correct
because release is idempotent.

---

## §5 — stdout discipline: the reaped-count capture MUST be clean

`pool_reap_stale` echoes the reaped count to stdout (`printf '%s\n' "$reaped"`) so the admin
reap command (M7.T2) captures it via `count=$(pool_reap_stale)`. Command substitution captures
**ALL stdout** from the function. Therefore:

- **ONLY `printf '%s\n' "$reaped"` may write to the function's stdout.**
- `_pool_log` writes to the LOG FILE (and stderr fallback) — NOT stdout → safe.
- ⚠️ **`pool_release_lane` runs `$POOL_REAL_BIN --session … close 2>/dev/null`** — only STDERR
  is redirected; **close's STDOUT is NOT redirected inside `pool_release_lane`**. If `close`
  emits anything to stdout (e.g. a confirmation JSON), it would pollute the count capture.
  **FIX: redirect `pool_release_lane`'s stdout within the reap loop:**
  ```bash
  pool_release_lane "$n" >/dev/null
  ```
  This suppresses ANY stray stdout from release (incl. the `close` subprocess + the kernel's
  kills/rms, which are silent anyway) while `_pool_log` still fires (it writes to the file, not
  stdout). `pool_release_lane` returns 0 always → no `|| true` needed under set -e in the
  `if` body (but it is harmless to add for defensive consistency — left out here to match the
  researcher skeleton + the always-0 contract).

  (Note: `pool_lanes_list`'s lane-number stdout is captured in the `for … in $()` command
  substitution for the LOOP LIST — it does NOT flow to `pool_reap_stale`'s own stdout. So it
  cannot pollute the count. Only release-time subprocesses are the concern → handled by the
  `>/dev/null` redirect.)

---

## §6 — the owner-pid log line (CONTRACT requirement)

The CONTRACT log format: `'Reaped stale lane N (owner pid P dead/recycled)'`. To get P:
- Read `owner.pid` BEFORE releasing (release deletes the lease).
- Use `pool_lease_field "$n" owner.pid` (nested-path support, §2.4). Best-effort + TOCTOU-safe:
  ```bash
  pid="$(pool_lease_field "$n" owner.pid 2>/dev/null || true)"
  [[ -n "$pid" && "$pid" != "null" ]] || pid="?"
  ```
  - `local pid; pid="$(…)"` (split — SC2155); the `|| true` INSIDE the `$()` makes the capture
    set -e-safe against a TOCTOU missing-lease rc 1 (pool_lease_field returns 1 on missing).
  - `pool_lease_field` echoes the literal `"null"` for a missing owner path → normalize to `"?"`.
- `pool_lane_is_stale` already confirmed the lease is readable (it returned rc 0 stale), so in
  the normal case the pid is present. The TOCTOU window between the verdict and the pid read is
  tiny; the `|| true` + `?` fallback make it bulletproof. Reaping is NOT the hot path (runs on
  admin reap / occasional sweep, not every invocation) → the extra read+jq fork is negligible.

---

## §7 — naming, placement, scope

- **Name**: `pool_reap_stale` (PUBLIC — no `_` prefix; matches `pool_release_lane` /
  `pool_acquire_locked` public convention + the `pool_reap_*` family in
  `architecture/key_findings.md` naming recommendation). CONTRACT-mandated name.
- **Placement**: APPEND to `lib/pool.sh` under a new banner `# Reaper & orphan reuse (P1.M5.T3.S1)`
  directly AFTER `pool_release_lane`'s closing brace (`lib/pool.sh:2480` = current EOF).
  **Pure addition** — no edits to any existing function. `pool_release_lane` becomes the
  second-to-last function; `pool_reap_stale` is the new EOF.
- **Banner**: start a M5.T3 banner now (the sibling M5.T3.S2 `reuse_orphan` will append under
  the SAME banner later). This matches how M5.T1 used one banner for S1+S2+S3.
- **Scope**: `pool_reap_stale` ONLY. Do NOT implement `reuse_orphan` (M5.T3.S2 — separate
  task, appends under the same banner later), the admin reap CLI (M7.T2 — calls this function),
  exhaustion force-reap (M5.T4), or the wrapper (M6). Do NOT touch acquire's inlined reap loop.
  Do NOT add a flock. Do NOT add new env vars / globals / files. One function, ~25 lines incl.
  the docstring.

---

## §8 — decisions table

| decision | choice | rationale |
|---|---|---|
| Reap via | `pool_release_lane` (PUBLIC) | runs OUTSIDE the flock → the daemon `close` is allowed + wanted (full teardown incl. daemon disconnect). CONTRAST acquire (inlined kernel, no close, under flock). |
| flock? | **NO** | release is lane-local + idempotent; a concurrent acquire reap of the same lane is a harmless no-op. Flocking the sweep would serialize vs acquire. |
| staleness verdict | `pool_lane_is_stale` (tri-state) | CONTRACT step 3b mandates it; DRY (do NOT re-inline owner-alive checks). |
| iterate | `for n in $(pool_lanes_list)` | documented idiom; snapshot; known-safe digit output. |
| count increment | `reaped=$((reaped + 1))` | assignment form (safe); NEVER `(( reaped++ ))` (aborts when 0). |
| set -e guard | `if pool_lane_is_stale "$n"; then …; fi` | errexit-exempt; rc 1/2 fall through. |
| pid for log | `pool_lease_field "$n" owner.pid` (best-effort, before release) | CONTRACT log format; nested-path support; `|| true` + `?` fallback. |
| stdout | ONLY `printf '%s\n' "$reaped"` | count capture `count=$(pool_reap_stale)`. Redirect `pool_release_lane "$n" >/dev/null` so the daemon `close` can't pollute it. |
| logging | `_pool_log` (file) per stale lane + summary | observability via `agent-browser-pool status`/doctor; never stdout. |
| return | `return 0` ALWAYS | non-fatal (admin tooling / sweeps); never `pool_die`. |
| echo | the reaped count | observability (CONTRACT step 3c). |
| placement | append after `pool_release_lane` (line 2480) under a new M5.T3 banner | current EOF; pure addition. |
