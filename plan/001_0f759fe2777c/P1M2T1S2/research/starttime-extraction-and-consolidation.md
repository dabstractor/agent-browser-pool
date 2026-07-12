# Research: Robust starttime extraction + S1/S2 consolidation (P1.M2.T1.S2)

Date: 2026-07-12
Scope: the canonical starttime extractor `_pool_get_starttime(pid)` and how it
relates to S1's already-landed `_pool_owner_starttime(pid)`.

---

## 1. HOST-VERIFIED /proc/<pid>/stat FACTS (this session)

Direct verification on this host (run inside the project):

| Method | Result | Correct? |
|---|---|---|
| `wc -w < /proc/self/stat` | **52** fields | — (the field count) |
| `cut -d' ' -f22 /proc/self/stat` | 8283368 | ✅ starttime (field 22) |
| `sed 's/.*)//' /proc/self/stat \| awk '{print $20}'` | 8283368 | ✅ robust (agrees) |
| `awk '{print $22}' /proc/self/stat` | 8283369 | ✅ (1-tick diff = different PID, see §4) |
| `awk '{print $(NF-19)}' /proc/self/stat` (PRD §2.19) | **4096** | ❌ this is field 33 (vsize), NOT starttime |
| `getconf CLK_TCK` | **100** | — (ticks/sec; starttime unit) |

**Conclusions:**
- `starttime` is **field 22** of `/proc/<pid>/stat`, measured in clock ticks since boot.
- The three correct extraction methods AGREE (within ±1 tick, which is just a different
  PID reading `/proc/self` — see §4).
- The PRD §2.19 `NF-19` formula is **wrong**: NF=52 on this host, so NF-19 = field 33
  (= vsize ≈ 4096 KiB), not field 22 (starttime ≈ 8.28M ticks). NF is NOT a fixed
  constant across kernel versions / process states, so any right-indexed offset is
  inherently fragile.

---

## 2. THE CORRECT ROBUST METHOD — why field 20 of the post-paren remainder == field 22

`/proc/<pid>/stat` line shape:
```
<pid> (<comm>) <state> <ppid> <pgrp> ... <starttime=field22> ... <field52>
  1     2       3       4     5            22                     52
```
- Field 2 (`comm`) is **parenthesized** and MAY contain spaces (e.g. `(Chrome Helper)`),
  which shifts every later field for a naive left-to-right split.
- The robust fix: delete everything up to AND INCLUDING the **last** `)` (greedy). This
  removes exactly fields 1 (pid) and 2 (comm), regardless of spaces inside comm. After
  the strip, the remainder begins at field 3 (state), so **overall field N == field
  (N−2) of the remainder**. Therefore starttime (field 22) == field **20** of the
  remainder (22 − 2 = 20).

Pure-bash strip (no extra fork, codebase style):
```bash
after="${stat_line##*)}"          # GREEDY longest prefix up to & incl. last ')'
start="$(awk '{print $20}' <<<"$after")"
```
Shell-pipeline equivalent (what the item description + PRD/arch docs cite):
```bash
sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'
```
Both are **identical in result** (verified: 8283368 for both). The pure-bash form is
preferred in `_pool_get_starttime` because we already capture the line into a variable
(to test for the missing-file case) and it avoids a redundant `sed` fork; the comment
documents the `sed` form as the canonical reference.

---

## 3. S1/S2 OVERLAP AND THE CONSOLIDATION DECISION (the central design question)

### The situation
- **S1 (P1.M2.T1.S1) has LANDED**: `lib/pool.sh` already defines `_pool_owner_starttime(pid)`
  AND `pool_owner_resolve()`. S1 bundled a starttime extractor (named `_pool_owner_starttime`)
  inside itself because `pool_owner_resolve` needs it, and S1 could not assume S2 would be
  ready when it ran (parallel execution).
- **S2's item description** explicitly wants a function named `_pool_get_starttime(pid)`,
  "used by pool_owner_resolve (to record POOL_OWNER_STARTTIME) and is_owner_alive (to
  verify identity across PID recycling)." It mandates the robust `sed 's/.*)//' | awk
  '{print $20}'` method and a code comment explaining why the PRD NF-19 formula is wrong.

### The conflict
If S2 simply appends a SECOND full starttime parser (`_pool_get_starttime`) alongside
S1's `_pool_owner_starttime`, the codebase has **two parsers doing identical work** —
pure duplication (forbidden by the parallel-context rule "Do NOT duplicate or conflict
with work specified in the previous PRP") and a maintenance hazard (fix one, forget the
other). S1's own Integration-Points note anticipated S2 "harden[ing]/augment[ing]" the
extractor.

### The resolution: CONSOLIDATION VIA DELEGATION
- **`_pool_get_starttime(pid)` is THE canonical, robust, thoroughly-documented, input- +
  output-validated starttime extractor.** It is the single source of truth for starttime
  parsing. `is_owner_alive` (P1.M2.T2.S1) calls it directly; future code calls it.
- **`_pool_owner_starttime` is reduced to a one-line delegating wrapper:**
  ```bash
  _pool_owner_starttime() { _pool_get_starttime "$@"; }
  ```
  This preserves S1's interface EXACTLY (same name, same I/O contract: echo digits /
  return 0, or return 1 with no echo, never fatal), so `pool_owner_resolve`'s call sites
  are UNTOUCHED and S1's behavior/regressions are preserved. There is exactly ONE real
  parser. This satisfies "build upon S1's outputs" (we keep S1's function name and
  contract) AND "do not duplicate" (one implementation).

### Why delegation over (b) editing pool_owner_resolve's call sites
Alternative (b) would update `pool_owner_resolve` to call `_pool_get_starttime` directly
(2 call sites: the TEST MODE block + the REAL MODE result block). Delegation (a) achieves
the same single-source-of-truth with **zero** changes to `pool_owner_resolve` and a
one-line change to `_pool_owner_starttime`'s body. Lower blast radius, equally clean.
The PRP mandates (a).

### Extra robustness `_pool_get_starttime` adds beyond S1's inline version
1. **Input validation**: `[[ "$pid" =~ ^[0-9]+$ ]] || return 1` — reject a non-numeric /
   empty PID cleanly (S1 relied on `cat` failing gracefully). The item says "INPUT: A
   PID"; validating the shape is defensive and never breaks callers (pool_owner_resolve
   only passes validated numeric pids).
2. **Output validation**: confirm the extracted value matches `^[0-9]+$` before echoing
   (guards a truncated/garbled stat line). S1 only checked `[[ -n ]]`.
3. **Comprehensive canonical comment**: the item REQUIRES (point 5) "a code comment
   explaining why the PRD's NF-19 approach is wrong and documenting the correct method."
   `_pool_get_starttime` carries the definitive version of that comment.

---

## 4. THE ±1-TICK "OFF-BY-ONE" RED HERRING (do not be fooled)

When validating, note: each SEPARATE shell command that reads `/proc/self/stat` reads a
**different process** (the command's own PID). Two such processes spawned microseconds
apart can have starttimes differing by 1 tick (10 ms at CLK_TCK=100). This explains why
this session saw `cut -f22 /proc/self/stat` = 8283368 but `awk '{print $22}' /proc/self/stat`
= 8283369 — they are DIFFERENT PIDs, not a parsing discrepancy.

**Test correctly**: compare `_pool_get_starttime "$$"` against `cut -d' ' -f22 /proc/$$/stat`
WITHIN THE SAME shell — `$$` is stable, so the two reads target the SAME process and the
values match EXACTLY. Use `$$` (not `/proc/self`) in validation assertions.

---

## 5. STRICT-MODE (set -euo pipefail) TRAPS — verified, baked into the impl

lib/pool.sh line 1 sets `set -euo pipefail` (S1), propagated into every caller.

| Trap | Fix (used in `_pool_get_starttime`) |
|---|---|
| `local x="$(cmd)"` (SC2155) masks exit status | `local x; x="$(cmd)"` two-statement |
| `cat /proc/$pid/stat` fails (vanished/EACCES) → set -e abort | `stat_line="$(cat ... 2>/dev/null)" \|\| true` |
| standalone `[[ "$v" =~ ^[0-9]+$ ]]` that fails to match aborts | put `[[ =~ ]]` inside `if [[ ! ... ]]; then return 1; fi` |
| `${VAR}` under set -u when unset | `${1:-}` for the positional arg |

`_pool_get_starttime` never calls `pool_die` and never exits the process — it is a 0/1
extractor. Callers (`pool_owner_resolve`, `is_owner_alive`) treat the empty/1 case as
"process dead / identity unknown."

---

## 6. SOURCES

- proc(5): https://man7.org/linux/man-pages/man5/proc.5.html — `/proc/[pid]/stat` field
  table (field 22 = starttime, clock ticks since boot; comm = field 2, parenthesized,
  may contain spaces).
- kernel.org proc.rst: https://www.kernel.org/doc/html/latest/filesystems/proc.html —
  canonical field table (same facts).
- S1 research (proc-parsing-and-ppid-walk.md §1.4, §5) — host-verified starttime values,
  the S1/S2 task boundary, the parens-strip method.
- architecture/system_context.md §6.1 — the critical finding (NF-19 wrong; correct
  method = `sed 's/.*)//' | awk '{print $20}'`).
- architecture/key_findings.md FINDING 1 (NF-19 bug) + "Function Naming Convention"
  (`pool_*` public, `_pool_*` internal).
- S1's PRP (P1M2T1S1/PRP.md) — Integration Points note anticipating S2 hardening the
  extractor; the exact I/O contract to preserve.
