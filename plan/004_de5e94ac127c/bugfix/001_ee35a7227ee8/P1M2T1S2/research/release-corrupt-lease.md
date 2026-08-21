# Research: pool_admin_release corrupt-lease teardown (P1.M2.T1.S2 — BUG-003 seam 2)

Date: 2026-08-20. Changeset: plan/004_de5e94ac127c/bugfix/001_ee35a7227ee8.
Task: make `release N` treat a present-but-corrupt lease as releasable (PRD h2.3/h3.2,
fix_design.md §4 seam 2). S1 (reap-side, parallel, "Implementing") is ALREADY LANDED —
verified in the working tree (BUG-003 seam-1 block present in pool_reap_orphan_dirs).

---

## 1. S1 CONTRACT STATE (verified in-tree, not assumed)

- `pool_reap_orphan_dirs` (NOW lib/pool.sh:3388-3436): the orphan branch ends with the
  S1 block — `if [[ -f "$POOL_LANES_DIR/$base.json" ]] && ! pool_lease_exists "$base";
  then rm -f -- ...; _pool_log "pool_reap(orphan): removed corrupt lease ... (BUG-003)"; fi`
  placed BEFORE `orphans=$((orphans + 1))` (count stays dirs-only).
- test/bootrace.sh: `r5_bug003_corrupt_lease_reclaimed` (line 473) IS in the file AND in
  `_br_run_suite`'s HARDCODED case list (lines 512-515). Suite currently: **7 cases,
  "7 passed, 0 failed"** expected.
- README.md `### reap` (~line 236-237): the corrupt-lease sentence IS in.
- S1 does NOT touch: `pool_admin_release` (S2's seam), `pool_lane_is_stale` rc-2 skip,
  `pool_find_free_lane` `[[ -f ]]` collision safety, `_pool_atomic_write`.

**S1/S2 boundary (from S1's PRP, confirmed by fix_design §4):** after S1+S2, corrupt
leases are reclaimable by BOTH verbs; the corrupt-lease-with-NO-dir shape is release's
job ONLY (reap iterates `$POOL_EPHEMERAL_ROOT/*/` — no dir means reap never sees it).
S2's R6 must cover BOTH shapes (dir present + dir absent).

## 2. THE EDIT SITE — pool_admin_release numeric branch (NOW lib/pool.sh:4655-4682)

Verified current structure (the elif classification `[[ "$target" =~ ^[0-9]+$ ]]`
VALIDATES $target as a path-safe component BEFORE any path use — keep relying on it):

```bash
    elif [[ "$target" =~ ^[0-9]+$ ]]; then
        if pool_lease_exists "$target"; then
            pool_release_lane "$target" >/dev/null
            printf 'Released lane %s.\n' "$target"
            return 0
        else
            printf 'Lane %s has no active lease.\n' "$target"
            return 1
        fi
```

Why `_pool_release_lane_internals` can't be reused for the corrupt case: its step (1)
(NOW ~2138-2141) is `if ! json="$(pool_lease_read "$lane" 2>/dev/null)"; then return 0; fi`
— rc 1 = missing OR corrupt → clean no-op. It can never tear down a corrupt lease. The
release verb therefore needs its OWN inline corrupt-teardown (item contract, fix_design §4).

## 3. THE IDIOMS TO COPY (verbatim sources, host-verified)

**(a) Anchored cmdline sweep-kill** — from `_pool_release_lane_internals` §3b (~2153-2163)
and `pool_reap_orphan_dirs` (~3413-3419):
```bash
local pat="user-data-dir=$dir( |\$)"
if pgrep -f -- "$pat" >/dev/null 2>&1; then
    pkill    -f -- "$pat" 2>/dev/null || true
    sleep 0.2                        # let renderer/GPU/utility children exit
    pkill -9 -f -- "$pat" 2>/dev/null || true
fi
```
Rationale (documented at source): `( |$)` anchors at the lane-dir boundary so
prefix-colliding lanes (3 vs 30/300) are never hit; Chrome's cmdline has the dir
followed by a space (next --flag) or EOL. pgrep rc 1 (no match) inside `if` =
errexit-exempt. Ids from a corrupt lease are untrustworthy by definition → sweep, not
pool_chrome_kill. Mid-function `local pat=` is established house style (§3b + reap loop).

**(b) Prefix-guarded rm -rf** — from `_pool_release_lane_internals` step (4) (~2166-2173):
```bash
dir="$POOL_EPHEMERAL_ROOT/$lane"
if [[ -n "$dir" && "$dir" == "$POOL_EPHEMERAL_ROOT"/* && "$dir" != "$POOL_EPHEMERAL_ROOT/" ]]; then
    rm -rf -- "$dir" 2>/dev/null || true
fi
```
($target is ^[0-9]+$-validated at classification; the prefix guard is defense-in-depth.)

**(c) Lease rm**: `rm -f -- "$POOL_LANES_DIR/$target.json" 2>/dev/null || true`.

**(d) Message + log**: `printf 'Released lane %s (corrupt lease cleared).\n' "$target"`
(the item's EXACT wording) + `_pool_log "pool_admin_release(corrupt): lane $target ...
(BUG-003)"` (house tag format `fn(context): msg`). rc 0.

## 4. R6 TEST DESIGN — the live-marker technique (critical insight)

**Problem with reusing the fake-chrome fixture for R6's kill assertion:** the fake chrome
ends with `exec python3 -m http.server` — exec REPLACES /proc/pid/cmdline, so after boot
the process cmdline no longer contains `user-data-dir=` and the anchored pgrep CANNOT
match it. A sweep-kill assertion on the exec'd fixture would pass VACUOUSLY (the marker
is gone regardless of whether the sweep ran).

**Solution (host-verified this session):** a synthetic live process whose cmdline
PERMANENTLY carries the marker, via `exec -a` (sets argv[0]; `sleep` never re-execs):
```bash
bash -c 'exec -a "$1" sleep 300' _ "user-data-dir=$AGENT_CHROME_EPHEMERAL_ROOT/7 lane7" &
```
Verified on this host: (1) the anchored pattern `user-data-dir=$T/active/7( |$)` MATCHES
the marker process (space after the dir); (2) a TERM kill reaps it (zero orphans);
(3) lane-70 style prefix collisions do NOT match (anchoring works). The pool needs no
boot for R6 — the corrupt lease is seeded directly, so no owner/fake-chrome boot flow is
needed at all (lighter than r3_neg, and NOT vacuous).

**Case shape** (mirrors R5's seeding + r3_neg's snapshot→cleanup→assert discipline):
- Variant 1 (dir present + live marker): seed corrupt `7.json` + `active/7/` + marker
  process → `release 7` → assert rc 0, lease gone, dir gone, AND
  `pgrep -f "user-data-dir=$EPH/7( |$)"` finds NOTHING after (proves the sweep killed).
- Variant 2 (dir absent): corrupt `7.json` only → `release 7` → rc 0, lease gone
  (the shape S1's reap can never reach).
- Register `r6_bug003_release_corrupt_lease` in `_br_run_suite`'s HARDCODED list
  (bootrace has NO compgen discovery — a missing entry = vacuous green). Suite becomes
  **"8 passed, 0 failed"**.

## 5. set -e TRAPS for the new code (house rules, system_context §11)

- `pool_lease_exists` rc 1 must stay inside the `if`/elif chain (errexit-exempt).
- `pgrep -f` rc 1 (no match) inside `if` (errexit-exempt); `pkill`/`rm` with `|| true`.
- `sleep 0.2` between TERM and KILL (renderer/GPU grace) — copy verbatim.
- NEVER `local x="$(…)"` (SC2155); `local pat="…$dir…"` is a parameter expansion (safe).
- In test bodies: `_fail "R6: …" || rc_all=1` (never a bare _fail; it returns 1);
  `(( rc == 0 ))` inside `if`/`||`; snapshot observable state BEFORE cleanup.
- The bash `a && b` statement idiom is set -e-safe when `a` fails (the && list's
  non-final command is exempt) — R5/r3_neg already rely on `[[ -e ]] && { … }`.

## 6. RESIDUALS (documented, deliberately NOT fixed here — item scope = numeric branch)

- `release all` iterates `pool_lanes_list` (glob `*.json`, NO JSON validation) →
  `pool_release_lane` → `_pool_release_lane_internals` no-ops on corrupt → the corrupt
  file SURVIVES `release all` (and inflates the "Released N lane(s)." count). The item
  contract scopes ONLY the numeric branch; operators use `release N` or `reap` for
  corrupt leases. Document in README as "release N" behavior (not `all`).
- `pool_find_free_lane`'s `[[ -f ]]` and `pool_lane_is_stale` rc 2 stay UNTOUCHED
  (deliberate collision safety — S1's PRP + system_context §7 both mandate this).

## 7. README SITE (verified current text, `### release [<N>|all]` ~line 249-265)

Intro: "Explicitly tear down one lane by number, or every lane. With no/invalid argument
it prints a usage block to stderr and exits 1." → extend with the corrupt-lease sentence
+ add an example line `Released lane 7 (corrupt lease cleared).` to the output block
(mirrors how S1's README sentence rode with its subtask — Mode A).

## 8. SOURCES

- fix_design.md §4 (the authoritative seam-2 design + test contract) and §7 (ordering:
  P1.M2.T1.S1/S2 mutually independent).
- system_context.md (bugfix) §7 (BUG-003 confirmation, all line refs), §11 (house style).
- lib/pool.sh (HEAD 5146 LOC): pool_admin_release 4606-4709 (numeric branch 4655-4682),
  _pool_release_lane_internals 2121-2181 (early-return + §3b sweep + step-4 guards),
  pool_reap_orphan_dirs 3388-3436 (S1 seam + sweep), pool_lease_exists 1005-1019,
  pool_lanes_list ~976-988 (glob, no JSON validation), pool_chrome_kill 2065-2085.
- test/bootrace.sh: header/setup/fixtures (1-176), r3_neg (349-400: snapshot→cleanup→assert),
  R5 (473-508: corrupt seeding), _br_run_suite hardcoded list (510-523).
- P1M2T1S1/PRP.md — the S1 contract (landed state verified above).