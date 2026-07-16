# Research Findings — P3.M1.T1.S2

**Generalize `pool_owner_resolve` to set-membership over `POOL_HARNESSES` + record actual matched comm.**

All checks STATIC (AGENTS.md §1): `bash -n`, `shellcheck`, and throwaway scratch
snippets under `/tmp`. **No Chrome booted, no test suite run, no daemon launched.**

---

## FINDING 1 — ⚠️ CRITICAL: the contract's DOUBLE-COMMA predicate is BROKEN

The item contract (point 3c) and S1's in-code comment (`lib/pool.sh:190`) both specify
the walk-loop match as:

```bash
[[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   # ← contract & S1 comment: DOUBLE comma
```

**This is wrong.** S1 stores `POOL_HARNESSES` as a *clean single-comma* list
(`pi,claude,codex,agy,antigravity` — verified `lib/pool.sh:196`, squeeze via
`tr -s ','` at line 194). Wrapping a single-comma list with `,,` on each END yields:

```
,,pi,claude,codex,agy,antigravity,,
```

Between tokens there is still only ONE comma. The pattern `*,,$comm,*` demands a
**double comma immediately before** the token. That double-comma-before only exists
for the **first** token (`,,pi,`). Therefore:

| comm   | double-comma match? | reason                                                    |
|--------|---------------------|-----------------------------------------------------------|
| pi     | ✅ MATCH            | `,,pi,` is present (the leading wrap)                     |
| claude | ❌ NO MATCH         | needs `,,claude,`; the list has only `,claude,`           |
| codex  | ❌ NO MATCH         | needs `,,codex,`                                          |
| agy    | ❌ NO MATCH         | needs `,,agy,`                                            |
| antigravity | ❌ NO MATCH     | needs `,,antigravity,`                                    |

**Empirical proof** (scratch test, `/tmp/sc_test.sh`, since deleted):
```
POOL_HARNESSES="pi,claude,codex,agy,antigravity"; comm="claude"
[[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   # → false; "matched claude" did NOT print
```

**Consequence if followed literally:** only `pi` owners ever resolve; claude/codex/agy/
antigravity owners fall through to the no-ancestor path → every non-pi driving command
fails fast. This silently **defeats the entire purpose of P3 / Decision O9** (multi-harness).
Root cause of the error: the contract author/S1-PRP author likely tested only the first
(default) token `pi` and assumed it generalized.

**CORRECT predicate — SINGLE comma** (the standard bash "in-list" idiom; also what
`architecture/core_code_map.md §1` R1 note shows):

```bash
[[ ",$POOL_HARNESSES," == *",$comm,"* ]]      # ← correct: SINGLE comma wrap
```

**Empirical proof** (scratch test `/tmp/sc_single.sh`, since deleted, shellcheck rc=0):
```
in_set() { [[ ",$POOL_HARNESSES," == *",$1,"* ]]; }
pi → MATCH | claude → MATCH | codex → MATCH | agy → MATCH | antigravity → MATCH
i → no-match | PI → no-match (case-sensitive, correct) | pixyz → no-match | xterm → no-match
"" → no-match | "," → no-match | claude2 → no-match
```

Properties verified: (1) all 5 default tokens match; (2) no substring false-positives
(`i`, `pixyz`, `claude2` correctly rejected because every token is comma-delimited on
both sides incl. the wrap); (3) case-sensitive (comm from `/proc` is lowercase; S1
lowercases the set, so a stored uppercase token would not match — acceptable); (4)
shellcheck rc=0 (no SC2053 — the intentional glob `*` on the rhs is fine).

**DECISION for this PRP:** specify the **single-comma** predicate. This deviates from
the contract's literal text (3c) but fulfills its *intent* ("set-membership"). The
deviation is documented in the PRP with proof. One-pass success is impossible with the
double-comma form. S1's misleading comment at `lib/pool.sh:190` (which documents the
broken form) is corrected as a small comment-only task (it lives in the same file and
documents exactly the predicate S2 implements).

---

## FINDING 2 — line numbers are a MOVING TARGET: S1 landed in parallel

S1 (P3.M1.T1.S1) was implemented concurrently and **has landed**: `POOL_HARNESSES`
exists (`lib/pool.sh:196`), the header-comment table row exists (`:109`), and
`shellcheck -s bash lib/pool.sh` is **rc 0** post-S1. S1 inserted ~13 lines *above*
`pool_owner_resolve`, shifting every line number the contract cites:

| contract line | pre-S1 text                              | current (post-S1) line |
|---------------|------------------------------------------|------------------------|
| 487–498       | header comment of `pool_owner_resolve`   | ~498–512               |
| 514           | `POOL_OWNER_COMM="pi";` (TEST MODE)      | 527                    |
| 535/536       | `local ppid="" comm="" … steps=0`        | 549                    |
| 540           | `if [[ "$comm" == "pi" ]]; then`         | 553                    |
| 564           | `POOL_OWNER_COMM="pi";` (RESULT)         | 577                    |
| 581           | `_pool_log "… no pi ancestor …"`         | 594                    |

**RULE for the implementer: match on EXACT TEXT, never on line numbers.** The two
`POOL_OWNER_COMM="pi";` lines are disambiguated by (a) their preceding line
(`$ovr_pid` vs `$found_pid`) and (b) their differing inter-token whitespace
(TEST MODE has fewer alignment spaces). Provide both lines as context in every edit.

---

## FINDING 3 — exact current match-target text (post-S1; match on text, not lines)

All verified by `grep -n` against the live file (this state):

```bash
# EDIT (a) TEST MODE — block (context line makes it unique):
        POOL_OWNER_PID="$ovr_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";      declare -g POOL_OWNER_COMM

# EDIT (b) walk-loop declaration:
    local ppid="" comm="" line="" found_pid="" steps=0

# EDIT (c) walk-loop check (3 lines inside the while body):
        if [[ "$comm" == "pi" ]]; then
            found_pid="$pid"
            break
        fi

# EDIT (d) RESULT — block (context line makes it unique):
        POOL_OWNER_PID="$found_pid"; declare -g POOL_OWNER_PID
        POOL_OWNER_COMM="pi";         declare -g POOL_OWNER_COMM

# EDIT (e) no-ancestor log:
    _pool_log "pool_owner_resolve: no pi ancestor (passthrough mode)"

# EDIT (f) header comment — two phrases (a 3rd phrase flagged for consistency):
    # Implements PRD §2.4 step 1 (resolve OWNER), §1.1 (walk ppid to comm=='pi'),
    ...
    # directly; (2) REAL MODE walk ppid from $$ to comm=='pi'; (3) no pi ancestor
    # → PID=0 (passthrough). NEVER fatal. ...

# FINDING-1 comment fix (S1's block, lib/pool.sh:190):
    #      [[ ",,$POOL_HARNESSES,," == *",,$comm,"* ]]   (double-comma wrap ⇒ exact-token).
```

---

## FINDING 4 — consumers auto-correct; NO edits needed downstream (verified)

The contract point 4 claims the lease-write sites and identity layer are comm-generic and
auto-correct once S2 records the real comm. Verified by reading + grep:

- **`_pool_acquire_critical_section`** (lease WRITE, ~`lib/pool.sh:2133` post-shift):
  writes `"$POOL_OWNER_COMM"` into the lease `.owner.comm`. Once S2 sets the real comm,
  this writes it automatically. **No change.**
- **`_pool_adopt_lane`** (~`lib/pool.sh:2044`): `--arg comm "$POOL_OWNER_COMM"` in the jq
  mutation. Same — auto-corrects. **No change.**
- **`pool_owner_alive`** (~624–687): `local expected_comm="${3:-pi}"`; compares the STORED
  comm generically (`[[ "$comm" == "$expected_comm" ]]`). Always called with the lease's
  stored comm. The `${:-pi}` fallback is never hit by any current caller. **No change.**
- **`pool_lane_is_stale`** (~1147–1234): `pool_owner_alive "$pid" "$starttime" "${comm:-pi}"`
  — passes the STORED comm. **No change.**
- **`pool_lease_find_mine`** (~1011): reuses a lane by matching `owner.pid &&
  owner.comm == POOL_OWNER_COMM && starttime`. Reads `POOL_OWNER_COMM` generically →
  auto-works for any comm. **No change.**
- **`pool_wrapper_main` fail-fast** (~3414): condition `POOL_OWNER_PID == "0"` is
  UNCHANGED (no ancestor of ANY recognized harness ⇒ PID 0). The message *text* is S3's
  job. **No condition change in S2.**

⇒ S2 touches ONLY `pool_owner_resolve` (4 logic edits + header comment) + S1's
misleading comment + the two docs files. Identity model `(pid, comm, starttime)`
(PRD §2.8/§2.13) is unchanged; only the *acceptable comm set* widens and the *recorded*
comm becomes the actual match.

---

## FINDING 5 — docs exact strings (match on text)

**`configuration.md`** (S1 added 1 table row ~line 28 ⇒ line numbers shifted +1; match text):
- L54 `resolve the owning \`pi\` PID` → `resolve the owning recognized-harness PID`
- L55 `there is no \`pi\` ancestor` → `there is no recognized-harness ancestor`
- L82 `For a driving command under \`pi\`:` → `For a driving command under a supported harness:`
- L86 `resolve owning pi PID (walk ppid → comm == 'pi')` →
       `resolve owning harness PID (walk ppid → first ancestor whose comm is in $POOL_HARNESSES)`
- L105 `Your owning \`pi\` process exits` → `Your owning harness process exits`
- (consistency, NOT in contract's list) L122 troubleshooting matrix:
  `Driving command run outside \`pi\` (no pi ancestor → fail-fast)` and `Run your browser work under \`pi\``
  → rephrase to harness-neutral (recommended; would otherwise be factually false post-P3)
- NOTE: the fail-fast message *text* on L55–56 (`"… require a pi ancestor …"`) is **S3's** scope —
  leave it in S2.

**`SKILL.md`** (S1 did NOT touch it ⇒ line numbers stable; match text):
- L20 `your owning \`pi\` process` → `your owning harness process`
- L36 `your owning \`pi\` process` → `your owning harness process`  (different surrounding text than L20)
- L58 `resolves your pi owner` → `resolves your harness owner`
- L87 `your owning \`pi\` process exits` → `your owning harness process exits`
- (consistency) L138 pitfall `Run your browser work under \`pi\`; don't try to bypass it.`
  and §4 `driving commands require a \`pi\` ancestor` → harness-neutral (recommended)

---

## FINDING 6 — shellcheck / syntax evidence (post-S1, current HEAD)

```
$ bash -n lib/pool.sh            → OK
$ shellcheck -s bash lib/pool.sh → OK (rc 0)
```
S1 already landed cleanly. S2's additions are shellcheck-safe (verified the new
match predicate + `found_comm=""` declaration via scratch snippets; SC2155 does NOT
fire on the TEST-MODE global assignment `POOL_OWNER_COMM="$(…)"` because SC2155 only
targets `local X="$(…)"`, not bare globals — see PRP gotcha).
