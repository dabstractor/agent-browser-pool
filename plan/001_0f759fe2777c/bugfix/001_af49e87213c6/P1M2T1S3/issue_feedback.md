# Implementation Issue Feedback (Attempt 1/3)

The previous implementation attempt encountered an issue that requires re-planning.

## Issue Details

S3 implementation is COMPLETE and CORRECT (both edits applied to test/concurrency.sh; all static gates pass: bash -n clean, shellcheck -S warning clean, no sleep 0.3, both new comments present; assertions byte-for-byte unchanged; scope clean — only test/concurrency.sh modified). However, the Level 3 LIVE run (timeout 300 bash test/concurrency.sh) FAILS deterministically with 'port not all distinct/nonzero: 53420 53420 53421' — and this is the CORRECT, INTENDED outcome: S3 successfully turned the concurrency test into a real gate that EXPOSED a genuine production bug the old 0.3s stagger was hiding. ROOT CAUSE (investigated via captured pool.log + chrome logs): when 3 lanes boot concurrently with no stagger, two lanes both pick port 53420 (pool_find_free_port TOCTOU outside the flock — lane 1 hasn't written its lease yet). Lane 2's Chrome fails to bind IPv4 0.0.0.0:53420 ('bind() failed: Address already in use (98)') but SILENTLY FALLS BACK to IPv6 [::1]:53420 and stays up. Neither S1 nor S2 recovers this: S1 only catches the INSTANT-EXIT EADDRINUSE variant (Chrome dies immediately) — this Chrome stays alive; S2 only re-picks on pool_chrome_launch rc 1 (S1) or pool_wait_cdp's 30s timeout, but pool_wait_cdp curls 127.0.0.1 (IPv4) which hits LANE 1's Chrome and succeeds in <1s. So lane 2 provisions on 53420 (same as lane 1), and the distinct-port assertion correctly fails. The run is deterministic (~4.2s, no timeout) across 4 runs — NOT the probabilistic 3-way re-pick flakiness the PRP's Task-2b minimal-stagger fallback was designed for. S2's contract (re-pick + pool_boot_lane lease-port re-read) IS landed (confirmed present); the gap is that S2's TRIGGER CONDITIONS don't cover this alive-on-IPv6-fallback variant. Per the PRP's explicit, repeated scope rules ('S3 does NOT edit lib/pool.sh'; 'If the test fails, investigate S1+S2, not S3'; 'Do NOT weaken the assertions to make it pass'; 'Do NOT use the Task-2b fallback to mask an actual S1+S2 bug — investigate first'), I did NOT weaken the assertions, did NOT re-add a stagger, and did NOT edit production code. The production fix belongs to a FOLLOW-UP task (e.g. force IPv4-only binding via --remote-debugging-address=127.0.0.1 in pool_chrome_launch, OR make pool_wait_cdp verify the CDP websocket endpoint matches THIS lane's Chrome rather than any responder on the port). NOTE: my initial isolated diagnostic misconfigured POOL_STATE_DIR and briefly polluted the operator's real ~/.local/state/agent-browser-pool/ (a stray lane-9 lease + chrome log + appended pool.log lines); I have fully restored that state to its pre-session content (lanes dir empty, chrome-9.log removed, pool.log truncated back to pre-session entries) and cleaned all temp roots. Environment is clean: zero orphan processes, zero leftover temp dirs. SUMMARY: S3 is done and working as designed; the failing live run is a feature (it caught a real defect), and requires a separate production-code fix (out of S3's scope) to pass.

## Full Agent Output

Environment fully clean — zero orphans, zero leftover temp roots. The operator's real state was polluted by my initial (misconfigured) diag and has been restored to its pre-session content.

## Summary

**S3 implementation is complete and correct.** I made the two specified edits to `test/concurrency.sh`:
1. **Task 1** — Rewrote the step-(4) block comment (L247) to explain the no-stagger rationale (S1 EADDRINUSE detect + S2 re-pick recover collisions; assertions verify recovery; 3-way-flake note).
2. **Task 2** — Removed the `sleep 0.3` stagger (L272), replaced with a multi-line "No stagger" comment so it isn't re-added.

All **static gates pass** (Level 1: `bash -n` clean, `shellcheck -S warning` clean, both comments present, no `sleep 0.3`), scope is clean (only `test/concurrency.sh`), and no assertions were changed (Level 4).

**The live run (Level 3) fails — and that is the correct, intended outcome.** The S3 test did its job: it turned a passing test into a real gate that **caught a genuine production bug** the old stagger was hiding.

### Root cause the S3 test exposed (investigated via captured pool log + chrome logs)

When N=3 lanes boot concurrently without the stagger, two lanes both pick port 53420 (the `pool_find_free_port` TOCTOU outside the flock — lane 1 hasn't written its lease yet). Both launch Chrome on 53420. Lane 2's Chrome **fails to bind IPv4** (`bind() failed: Address already in use (98)` in chrome-2.log) but **silently falls back to IPv6 `[::1]:53420` and stays up**. Then:

- **S1 never triggers** — S1 only catches the *instant-exit* EADDRINUSE variant; this Chrome stays alive.
- **S2 never triggers** — S2 re-picks only on `pool_chrome_launch` rc 1 (S1) or `pool_wait_cdp`'s 30s timeout. But `pool_wait_cdp` curls `127.0.0.1:53420` (IPv4), which hits **lane 1's Chrome** (the winner on IPv4) and succeeds in <1s.
- Result: lane 2 provisions on 53420 — the **same port as lane 1** — pointing at lane 1's Chrome. The distinct-port assertion (`53420 53420 53421`) correctly fails.

This is **deterministic** (same failure all 4 runs, ~4.2s each — no 30s timeout ever fires), not the probabilistic 3-way re-pick flakiness the PRP's Task-2b fallback was designed for.

### Scope determination

The PRP is explicit and repeated: **"S3 does NOT edit lib/pool.sh (S1+S2 own the re-pick). If the test fails, investigate S1+S2, not S3. Do NOT weaken the assertions to make it pass."** I followed this precisely:

- I did **not** weaken the assertions or re-add a stagger (that would mask the bug — the exact anti-pattern the PRP forbids).
- I did **not** edit `lib/pool.sh` (out of scope; a separate task must extend collision detection to the "Chrome stays up on IPv6" variant — e.g. force IPv4-only via `--remote-debugging-address=127.0.0.1`, or have `pool_wait_cdp` verify the CDP websocket matches this lane's Chrome).
- S2's contract (re-pick + `pool_boot_lane` lease-port re-read) **is landed** — confirmed present. The gap is that S2's *trigger conditions* don't cover this alive-on-IPv6 variant.

The S3 deliverable is finished: the test now genuinely exercises port-collision recovery, and it correctly fails until the production code is fixed in a follow-up task. This is an **issue** (the PRP's Success Criteria for the *live* run cannot be met until a production fix lands), not an error in S3 itself.

```json
{
  "result": "issue",
  "message": "S3 implementation is COMPLETE and CORRECT (both edits applied to test/concurrency.sh; all static gates pass: bash -n clean, shellcheck -S warning clean, no sleep 0.3, both new comments present; assertions byte-for-byte unchanged; scope clean — only test/concurrency.sh modified). However, the Level 3 LIVE run (timeout 300 bash test/concurrency.sh) FAILS deterministically with 'port not all distinct/nonzero: 53420 53420 53421' — and this is the CORRECT, INTENDED outcome: S3 successfully turned the concurrency test into a real gate that EXPOSED a genuine production bug the old 0.3s stagger was hiding. ROOT CAUSE (investigated via captured pool.log + chrome logs): when 3 lanes boot concurrently with no stagger, two lanes both pick port 53420 (pool_find_free_port TOCTOU outside the flock — lane 1 hasn't written its lease yet). Lane 2's Chrome fails to bind IPv4 0.0.0.0:53420 ('bind() failed: Address already in use (98)') but SILENTLY FALLS BACK to IPv6 [::1]:53420 and stays up. Neither S1 nor S2 recovers this: S1 only catches the INSTANT-EXIT EADDRINUSE variant (Chrome dies immediately) — this Chrome stays alive; S2 only re-picks on pool_chrome_launch rc 1 (S1) or pool_wait_cdp's 30s timeout, but pool_wait_cdp curls 127.0.0.1 (IPv4) which hits LANE 1's Chrome and succeeds in <1s. So lane 2 provisions on 53420 (same as lane 1), and the distinct-port assertion correctly fails. The run is deterministic (~4.2s, no timeout) across 4 runs — NOT the probabilistic 3-way re-pick flakiness the PRP's Task-2b minimal-stagger fallback was designed for. S2's contract (re-pick + pool_boot_lane lease-port re-read) IS landed (confirmed present); the gap is that S2's TRIGGER CONDITIONS don't cover this alive-on-IPv6-fallback variant. Per the PRP's explicit, repeated scope rules ('S3 does NOT edit lib/pool.sh'; 'If the test fails, investigate S1+S2, not S3'; 'Do NOT weaken the assertions to make it pass'; 'Do NOT use the Task-2b fallback to mask an actual S1+S2 bug — investigate first'), I did NOT weaken the assertions, did NOT re-add a stagger, and did NOT edit production code. The production fix belongs to a FOLLOW-UP task (e.g. force IPv4-only binding via --remote-debugging-address=127.0.0.1 in pool_chrome_launch, OR make pool_wait_cdp verify the CDP websocket endpoint matches THIS lane's Chrome rather than any responder on the port). NOTE: my initial isolated diagnostic misconfigured POOL_STATE_DIR and briefly polluted the operator's real ~/.local/state/agent-browser-pool/ (a stray lane-9 lease + chrome log + appended pool.log lines); I have fully restored that state to its pre-session content (lanes dir empty, chrome-9.log removed, pool.log truncated back to pre-session entries) and cleaned all temp roots. Environment is clean: zero orphan processes, zero leftover temp dirs. SUMMARY: S3 is done and working as designed; the failing live run is a feature (it caught a real defect), and requires a separate production-code fix (out of S3's scope) to pass."
}
```

## Instructions

Review this feedback and create a revised PRP that addresses the issue.
If the issue is fundamentally impossible to resolve, output `"result": "fail"` with an explanation.
