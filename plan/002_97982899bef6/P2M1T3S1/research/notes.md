# Research Notes — P2.M1.T3.S1

**Item**: Update `pool_admin_help`: remove `AGENT_BROWSER_POOL_DISABLE`, add a "Driving commands"
section, refresh the description + `AGENT_CHROME_MASTER` default text.

## 1. Current state of `pool_admin_help` (VERIFIED against live tree)

The function lives at **lib/pool.sh:4591-4625** (the item description cited 4578-4613; numbers have
drifted ~+13 from prior P2.M1 edits — the edits below anchor on EXACT TEXT, never line numbers).

Full function body (read 2025-XX, live tree = POST-P2.M1.T2.S1):

```
4562 # pool_admin_help
4591 pool_admin_help() {
4592     printf 'agent-browser-pool — manage the agent-browser ephemeral-profile pool.\n'
...
4598     printf 'Commands:\n'
...
4610     printf '  help                    Show this help. Aliases: --help, -h.\n'
4611     printf '\n'
4612     printf 'Configuration (environment variables; all optional):\n'
4613     printf '  AGENT_CHROME_MASTER             CoW source profile (default: your real Chrome profile)\n'
4614     printf '  AGENT_CHROME_EPHEMERAL_ROOT     ephemeral lane dir root\n'
4615     printf '  AGENT_BROWSER_REAL              the real agent-browser binary (shadowed CLI)\n'
...
4621     printf '  AGENT_CHROME_ALLOW_SLOW_COPY    permit non-btrfs (slow) copies if set (1/true/yes/on)\n'
4622     printf '  AGENT_BROWSER_POOL_DISABLE      disable pooling (passthrough) if set (1/true/yes/on)\n'
4623     printf '\n'
4624     printf "Run 'agent-browser-pool doctor' to verify your setup.\n"
4625     return 0
4626 }
```

The 4 edit targets (the item's steps a–d):
- **(b) description** — line 4592.
- **(c) Driving commands section** — insert between line 4610 (`help ...`) and line 4612
  (`Configuration ...`). The anchor is the 3-line block: `help` printf + `'\n'` + `Configuration` printf.
- **(d) AGENT_CHROME_MASTER** — line 4613.
- **(a) AGENT_BROWSER_POOL_DISABLE (DELETE)** — line 4622. Anchor: `ALLOW_SLOW_COPY` printf +
  `DISABLE` printf + `'\n'` (3 lines).

## 2. The 5th edit — `AGENT_BROWSER_REAL` "(shadowed CLI)" — consequential hygiene

Line 4615 reads: `the real agent-browser binary (shadowed CLI)`. This is **factually false** under
milestone P2 ("No-Shadow Pivot"): there is no PATH shadowing anymore; the real `agent-browser`
binary is exec'd directly by `pool_wrapper_main` for driving commands (PRD §2.4, §2.16). Leaving
"(shadowed CLI)" makes the help text self-contradictory with the new description (step b → "sole
entry point"). It is:
- in the SAME printf block being edited,
- owned by NO other work item (P2.M4.T2.S1 = `references/configuration.md`, a different file;
  this item = the only owner of `pool_admin_help`),
- a 3-word change.

→ Include as a REQUIRED Task, flagged as one phrase beyond the literal contract (same discipline the
sibling PRP P2.M1.T2.S1 used for its RC-TAXONOMY comment edit). New text: `the real agent-browser
binary (run for driving commands)` (no apostrophe → no quoting hazard).

## 3. `POOL_DISABLE` footprint (sets the validation expectation)

`grep -c 'POOL_DISABLE' lib/pool.sh` = **1** (only line 4622, in the help). The sibling P2.M1.T2.S1
explicitly left this single ref for THIS item. → After this item: `grep POOL_DISABLE lib/pool.sh` =
**0 hits** (clean removal; nothing else in the file references it).

## 4. Sibling / parallel-item safety (DISJOINT)

P2.M1.T2.S1 (`_pool_preflight_real_bin`) is ALREADY applied in the live tree:
- definition @ lib/pool.sh:3551
- call @ lib/pool.sh:3629 (in `pool_wrapper_main` step a)
- RC-TAXONOMY mention @ lib/pool.sh:3592

All three are in the **pool_wrapper_main region (~3534-3640)**, which is ~1000 lines ABOVE
`pool_admin_help` (4591-4625). The two items touch **disjoint regions** → edits compose in either
order; no merge collision possible. This PRP assumes the post-S1 live state.

## 5. Driving-commands wording — source of truth

PRD anchors (given in selected_prd_content):
- §2.12 (h3.16): "`<driving verb> [args]  # anything else → acquire/reuse MY lane + exec the real
  agent-browser`" and "Every other token is a driving command routed to the caller's own lane (§2.4)."
- §2.15 (h3.19): "`agent-browser-pool open <url>` … (lane selected by my identity, not an arg)";
  "Any real-agent-browser verb works: `agent-browser-pool {screenshot,get cdp-url,click,type,
  eval,find,…}`"; "`agent-browser-pool close` → disconnects MY lane's daemon only
  (lane/Chrome/profile survive for reuse)".

→ Help section wording derived directly from these (identity-based lane, never an arg; close =
daemon-only disconnect; lane survives). The 3 examples requested by the item: `open <url>`,
`screenshot`, `close`.

## 6. Quoting conventions in this function

- Single-quoted `printf '...\n'` is the norm.
- Apostrophes inside single-quoted strings use the `'"'"'` idiom (see line 4596
  `'status'` and line 4607 `'release all'`). → To keep my new text simple + quoting-bug-free, I
  AVOID apostrophes entirely (e.g. "disconnect your lane daemon", not "lane's daemon";
  "run for driving commands", not "exec'd").
- `<` / `>` / `...` inside single quotes are literal (no redirection inside quotes) → safe in
  `printf '... open <url> ...'`.

## 7. Validation strategy (AGENTS.md §1 — static + pure-call only)

`pool_admin_help` is PROVABLY PURE (its own docstring @ lib/pool.sh:4562-4590: "reads NO global,
touches NO disk, does NO $(…) … only printf + return 0"). And `lib/pool.sh` has NO top-level
executable code (verified by the sibling PRP; `source` only defines functions). Therefore:
- `bash -n lib/pool.sh` — syntax (static, never blocks).
- `shellcheck -s bash lib/pool.sh` — lint (static; shellcheck available at /usr/bin/shellcheck).
- A `timeout 10` micro-check: `source lib/pool.sh; pool_admin_help` → capture stdout → grep for
  (1) no `AGENT_BROWSER_POOL_DISABLE`, (2) `Driving commands:` + the 3 examples, (3) new
  description, (4) no `shadowed CLI`, (5) `user-data-dir` in MASTER line. This exercises the REAL
  output with ZERO browser/daemon/disk risk (the function prints and returns).
- `grep -c 'POOL_DISABLE' lib/pool.sh` → expect **0**.

No `test/validate.sh`, no `test/transparency.sh`, no Chrome, no `agent-browser` invocation, no
shared-$HOME writes.

## 8. Out of scope (owned by other items — do NOT touch)

- `bin/agent-browser-pool` dispatcher `*)` arm → `pool_wrapper_main "$@"` (P2.M2.T1.S1).
- `references/configuration.md` DISABLE row / master default / dispatch table (P2.M4.T2.S1).
- `SKILL.md` / `README.md` (P2.M4.T1.S1 / P2.M6.T1.S1).
- `test/*` DISABLE selftest + ABPOOL_WRAPPER (P2.M5).
- `pool_admin_doctor`, `pool_wrapper_main`, `_pool_preflight_real_bin` (already correct / sibling).
