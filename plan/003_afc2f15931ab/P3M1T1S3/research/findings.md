# Research Findings — P3.M1.T1.S3: Update fail-fast message to name supported harnesses

Static research of `lib/pool.sh` + the three skill docs + the test blast radius.
**No Chrome booted, no test suite run** (AGENTS.md §1 — PLANNING task). Verified with
reads + `grep` + (evidence below) `bash -n`/`shellcheck` on the current `lib/pool.sh`.

This is a **pure string/comment change** to ONE `pool_die` call + its 2-line comment, plus a
Mode-A docs sweep. No logic, no condition, no behavior change.

---

## FINDING 1 — Line drift: contract cited 3413-3416; ACTUAL is 3425-3431

The item contract (point 1) cites `lib/pool.sh:3413-3416` (comment 3411-3412). That is STALE —
S1 (+ the S2 in-flight edits) shifted every line. Verified current text (`grep -n`):

```
3425:    # --- d. owner resolution (step 1): no pi ancestor → fail-fast ----------------
3426:    # pool_owner_resolve is rc 0 ALWAYS; sets POOL_OWNER_PID (==0 ⇒ caller has no pi ancestor).
3427:    pool_owner_resolve
3428:    if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then
3429:        pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \
3430:                 "For raw browser use without pooling, call 'agent-browser' directly."
3431:    fi
```

→ **RULE: match on EXACT TEXT, never line numbers.** The whole `pool_wrapper_main` step-d
block is small and unique; pin edits by substring.

---

## FINDING 2 — S2 has LANDED its docs changes (files are in POST-S2 state)

`parallel_execution_context` says S2 is in-flight. Direct re-grep confirms S2's Mode-A docs
edits are ALREADY on disk:

**SKILL.md** (S2 Task 8 — DONE):
```
20:(your owning harness process and its start time)            ← was "owning `pi` process" (8a ✓)
36:keyed on your owning harness process                        ← (8b ✓)
58:resolves your harness owner                                 ← was "resolves your pi owner" (8c ✓)
87:When your owning harness process exits                      ← (8d ✓)
136:require a supported agent harness                          ← was "require a `pi` ancestor" (8e ✓)
138:browser work under a supported harness (pi/claude/codex/agy)  ← (8e ✓)
```

**configuration.md** (S2 Task 7 — DONE):
```
54: resolve the owning recognized-harness PID                  ← was "owning `pi` PID" (7a ✓)
55: there is no recognized-harness ancestor                    ← was "no `pi` ancestor" (7b ✓)
82: For a driving command under a supported harness:           ← (7c ✓)
122: outside a supported harness (no recognized-harness ancestor → fail-fast) ... under a supported harness  ← (7f ✓)
```

**CONSEQUENCE:** S2 already generalized the *prose around owner resolution*. What S2
EXPLICITLY DEFERRED (its Task 7 note: "DO NOT touch the fail-fast MESSAGE text … that is S3")
is the **inline `pool_die` MESSAGE QUOTE** itself — which still says "require a pi ancestor"
(configuration.md:56). That is S3's uniquely-owned docs edit.

---

## FINDING 3 — The clean S3 scope split (uniquely-S3 vs already-done-by-S2)

Every edit below was verified against CURRENT (post-S2) file text. "S3-UNIQUE" = only S3
does it; "S2-DONE" = already on disk, S3 must NOT re-edit (only verify).

### CODE — `lib/pool.sh` (ALL S3-UNIQUE; S2 did not touch pool_wrapper_main)
| Target (exact text) | Disposition |
|---|---|
| `pool_die "agent-browser-pool: driving commands require a pi ancestor (owning pi process)." \` (L3429) | **S3-UNIQUE** → `require a supported agent harness (pi/claude/codex/agy).` |
| comment `# --- d. owner resolution (step 1): no pi ancestor → fail-fast ---` (L3425) | **S3-UNIQUE** → `no recognized-harness ancestor → fail-fast` |
| comment `# pool_owner_resolve … (==0 ⇒ caller has no pi ancestor).` (L3426) | **S3-UNIQUE** → `caller has no recognized-harness ancestor` (keep block coherent) |
| condition `if [[ "${POOL_OWNER_PID:-0}" == "0" ]]; then` (L3428) | **UNCHANGED** (contract: NO condition change) |
| 2nd line `"For raw browser use without pooling, call 'agent-browser' directly."` (L3430) | **UNCHANGED verbatim** |

### DOCS — `configuration.md` (S3-UNIQUE = the message quote ONLY; rest S2-DONE)
| Target | Disposition |
|---|---|
| inline quote `commands require a pi ancestor...` (L55-56) | **S3-UNIQUE** → `commands require a supported agent harness (pi/claude/codex/agy)...` |
| "resolve the owning recognized-harness PID" (L54) | **S2-DONE** — verify only |
| "there is no recognized-harness ancestor" (L55) | **S2-DONE** — verify only |
| troubleshooting matrix row (L122) | **S2-DONE** — verify only |

### DOCS — `SKILL.md` (S3-UNIQUE = the §4 bold quote ONLY; rest S2-DONE)
| Target | Disposition |
|---|---|
| bold quote `"I ran a driving command outside `pi` and it errored."` (L135) | **S3-UNIQUE** → `outside a supported harness (`pi`/`claude`/`codex`/`agy`)` |
| `require a supported agent harness` (L136) | **S2-DONE** — verify only (DO NOT change to "supported-harness ancestor"; S2's wording stands) |
| `under a supported harness (pi/claude/codex/agy)` (L138) | **S2-DONE** — verify only |

### DOCS — skill `README.md` (S2 did NOT touch it → ALL S3)
| Target (exact current text) | Disposition |
|---|---|
| L16 `driving commands fail fast without a `pi` ancestor` | **S3-UNIQUE (REQUIRED)** → `fail fast without a supported-harness ancestor` |
| L11 `` `agent-browser-pool` command under `pi`; `` | **S3-UNIQUE (OPTIONAL)** → `under a supported harness` |
| L14 `owning `pi` process exits.` | **S3-UNIQUE (OPTIONAL)** → `owning harness process exits.` |

---

## FINDING 4 — BLAST RADIUS: test/transparency.sh polls `"pi ancestor"` → WILL break

`grep -n 'pi ancestor' test/transparency.sh` shows it at ~20 sites. The ACTIVE poll/assert
sites (not just comments) that break the moment S3's message no longer contains "pi ancestor":

```
254:        [[ "$msg" == *"pi ancestor"* ]] && break      # TEST (a) skills get core
258:    [[ "$msg" == *"pi ancestor"* ]]\                  # TEST (a) assert
535:        [[ "$msg" == *"pi ancestor"* ]] && break      # TEST (i) driving cmd
539:    [[ "$msg" == *"pi ancestor"* ]]\                  # TEST (i) assert
540:        || { _fail "driving cmd with no pi ancestor did NOT fail fast; ..."; return 1; }
```

Plus ~15 comment sites (10,12,19,230,262,265,268,269,285,297,300,499,500,501,511,517).

**This is EXPECTED and ACCEPTABLE.** The fix (broaden the poll substring + re-comment) is a
**separate, downstream subtask — P3.M2.T1.S3** ("Update transparency.sh fail-fast poll to
match new R3 message text", 0.5 pts), which depends on THIS subtask (S3). Confirmed in
`<plan_status>`: P3.M2.T1.S3 is Planned and ordered after P3.M1.

**IMPLICATION FOR S3 VALIDATION:** S3 MUST NOT run the test suite to "verify" — (a) AGENTS.md
§1 forbids running the suite against the shared sandbox during impl, and (b) it WILL fail
until P3.M2.T1.S3 lands. S3's validation is STATIC ONLY: `bash -n` + `shellcheck` + grep.
S3 does NOT edit `test/*` (out of scope — P3.M2.T1.S3 owns it).

---

## FINDING 5 — Root `README.md` is OUT OF SCOPE (owned by P3.M3.T1.S1)

There are TWO README files. Do not confuse them:
- **`.agents/skills/agent-browser-pool/README.md`** → **S3** (contract 5c). S3 edits it.
- **root `README.md`** (project README) → **P3.M3.T1.S1** ("Update README.md root: env-var
  table, callouts, architecture, troubleshooting, phrasing sweep", 2 pts, Planned). S3 does
  NOT touch it.

The root README has many "pi ancestor" / fail-fast refs that S3 must leave alone (verified):
```
278: │  resolve owning pi PID + starttime; no pi ancestor → FAIL-FAST
290: 3. driving command → resolve the owning `pi` process; if there is no `pi` ancestor,
318: ### Driving command errored: "requires a pi ancestor"
321: commands require a pi ancestor (owning pi process)."*
323: Cause: ... keyed on your owning `pi` process ...
327: Fix: run browser work under `pi` ...
```
These are P3.M3.T1.S1's job. S3 leaves them.

---

## FINDING 6 — Other "pi ancestor" comments in lib/pool.sh NOT in S3 scope

`grep -n 'pi ancestor' lib/pool.sh` (beyond the S3 target block):
```
419:  # from distinct subshell PIDs WITHOUT real pi ancestor processes.   ← pool_owner_resolve TEST-MODE comment
2111: # Defensive: a passthrough owner (no pi ancestor → POOL_OWNER_PID==0) must NOT claim a  ← _pool_acquire_critical_section
```
Both are comments in OTHER functions (pool_owner_resolve test-mode; acquire critical section).
The contract scopes S3 to **only** the pool_wrapper_main step-d comment (the fail-fast site).
Line 419 is pool_owner_resolve's domain (S2's); line 2111 is acquire's domain. S3 leaves both
to avoid scope creep / cross-task conflicts. (If desired, a future comment-sweep task can
catch them; they are behavior-irrelevant comments.)

---

## FINDING 7 — Exact new message text (authoritative)

Contract point 3 + PRD §2.4 step 1 agree. The `pool_die` two-line form:
```
pool_die "agent-browser-pool: driving commands require a supported agent harness (pi/claude/codex/agy)." \
         "For raw browser use without pooling, call 'agent-browser' directly."
```
- Line 1 changes: `…require a pi ancestor (owning pi process).` → `…require a supported agent harness (pi/claude/codex/agy).`
- Line 2: **verbatim, unchanged**.
- `pool_die` (lib/pool.sh:29) logs to pool log + stderr then `exit 1`. Behavior unchanged.

---

## FINDING 8 — Static-check evidence (research-only, current lib/pool.sh)

```
$ bash -n lib/pool.sh            → OK (rc 0)   # will re-run post-edit as the L1 gate
$ shellcheck -s bash lib/pool.sh → OK (rc 0)   # will re-run post-edit as the L1 gate
```
No processes spawned; no browsers booted. The edits are pure string/comment substitutions —
they cannot introduce a syntax/shellcheck regression (no brace/quote/quoting change: the new
text is a plain double-quoted literal, same as the old).
