# Research Findings — P3.M2.T1.S1

**Item:** Generalize `spawn_sim_owner` to optional comm name (2nd positional, default `pi`)
**Phase:** PRP creation (research). Static checks only (AGENTS.md §1). No Chrome, no suite run.

---

## 1. The target function — `test/validate.sh:103–141`

Current text (verbatim, captured 2026-07-13):

```bash
# =============================================================================
# spawn_sim_owner [SECONDS] — echo the PID of a LIVE process whose /proc/comm=="pi".
#
# WHY THIS EXISTS (the pivotal gotcha): pool_owner_alive (lib/pool.sh:616) reads the
# REAL /proc/<pid>/comm and requires "pi". The env override (AGENT_BROWSER_POOL_OWNER_PID)
# sets the lease's owner IDENTITY; it does NOT fake the kernel-visible process. So for a
# lease to be "mine"/"live", its owner PID must point at a real running "pi". The kernel
# sets /proc/<pid>/comm to the BASENAME of the executed ELF (proc(5)), NOT argv[0] — so
# copying /usr/bin/sleep to a file named "pi" and exec'ing it yields comm=="pi"
# (HOST-VERIFIED 2026-07-13). `exec -a pi sleep` does NOT work (argv[0] only).
#
# Tracks the pid (ABPOOL_CUR_OWNER, set by setup) + its temp bin dir (trap removes it).
# SETTLES on a poll loop: after fork the child briefly shows the PARENT's comm until
# execve completes — reading comm/starttime in that window returns the wrong value
# (cost a verification run: it returned "bash"). The poll guarantees a ready-to-use pid.
# Host tooling verified: /usr/bin/sleep present.
# =============================================================================
spawn_sim_owner() {
    local dur="${1:-600}" bin_dir bin pid comm tries
    bin_dir="$(mktemp -d -t abpool-pi.XXXXXX)"
    bin="$bin_dir/pi"
    cp -- /usr/bin/sleep "$bin"
    chmod +x -- "$bin"
    "$bin" "$dur" </dev/null >/dev/null 2>&1 &
    pid="$!"
    tries=0
    while (( tries++ < 50 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [[ "$comm" == "pi" ]] && break
        sleep 0.02
    done
    ABPOOL_SIM_BINS+=("$bin_dir")
    printf '%s\n' "$pid"
}
```

Three change points (all inside this one function):
- `local dur="${1:-600}" bin_dir …` → add `comm_name="${2:-pi}"`.
- `bin="$bin_dir/pi"` → `bin="$bin_dir/$comm_name"`.
- `[[ "$comm" == "pi" ]]` → `[[ "$comm" == "$comm_name" ]]`.
- PLUS a 15-char truncation guard, and a header-comment refresh.

---

## 2. The 6 callers — ALL pass zero comm arg (backward compatible)

Verified by grep (`spawn_sim_owner` invocations):

| File:line | Call |
|-----------|------|
| test/validate.sh:197 | `pid="$(spawn_sim_owner)"` (setup) |
| test/release_reaper.sh:157 | `pid="$(spawn_sim_owner)"` |
| test/release_reaper.sh:238 | `owner_y="$(spawn_sim_owner)"` |
| test/concurrency.sh:233 | `pid="$(spawn_sim_owner)"` |
| test/concurrency.sh:383 | `pid="$(spawn_sim_owner)"` |
| test/transparency.sh:162 | `pid="$(spawn_sim_owner)"` |

Additional bare invocations in transparency.sh:433/439/478/483 (also zero-arg). **None pass a comm
arg → `$2` defaulting to `"pi"` preserves every caller.** No other test file defines its own
`spawn_sim_owner`; all source `test/validate.sh` for it.

---

## 3. CRITICAL gotcha — keep the `mktemp` dir PREFIX

The cleanup trap (`test/validate.sh`, `_abpool_global_cleanup`) has a glob backstop:
```bash
rm -rf -- /tmp/abpool-pi.* 2>/dev/null || true
```
This is authoritative for leaked sim-owner bin dirs because `ABPOOL_SIM_BINS+=` runs inside the
`$(…)` subshell and is LOST in the parent. **The `mktemp -d -t abpool-pi.XXXXXX` dir-name prefix
MUST stay** (it's the *directory* name template, not the bin/ELF name). Only the *bin filename*
becomes `$comm_name`. Do NOT substitute `$comm_name` into the mktemp template, or non-pi owners
leak temp dirs the trap can't reap.

---

## 4. Kernel `comm` truncation — TASK_COMM_LEN guard rationale

- `proc_pid_comm(5)` (man7.org): "Strings longer than TASK_COMM_LEN (16) characters (including the
  terminating null byte) are silently truncated." → **15 usable chars**.
- The kernel sets `/proc/<pid>/comm` to the **truncated basename** of the executed ELF on execve.
- A bin ELF named with >15 chars keeps its full filename on disk, but `/proc/$pid/comm` reports
  only the first 15 chars. If `comm_name` is not also truncated, the settle-loop comparison
  `[[ "$comm" == "$comm_name" ]]` **never matches** → falls through after 50×0.02s ≈ 1s with an
  un-settled pid (returns a live pid but comm unverified → flaky downstream `pool_owner_alive`).
- **Guard:** if `${#comm_name} > 15`, warn to stderr and truncate `comm_name="${comm_name:0:15}"`
  so the comparison targets exactly what the kernel reports.
- **Defaults are unaffected** — all ≤15: `pi`=2, `claude`=6, `codex`=5, `agy`=3, `antigravity`=11.
  (Verified.)

Sources:
- https://man7.org/linux/man-pages/man5/proc_pid_comm.5.html
- https://docs.kernel.org/filesystems/proc.html (comm field)

---

## 5. Static-check baseline (HONEST gate, not a false "rc 0")

```
bash -n test/validate.sh                         → rc 0  (syntax clean)
shellcheck -s bash test/validate.sh              → rc 1  (5 pre-existing info-level findings)
shellcheck -S warning -s bash test/validate.sh   → rc 0  (no warnings/errors; all findings are info)
```

Pre-existing info-level findings (OUT OF SCOPE for this change — do not touch):
- line 29:  SC1091 (info) — `source ../lib/pool.sh` not followed (intentional; uses `-x`)
- line 578: SC2016 (info) — single-quote expression (intentional test string)
- line 608: SC2016 (info) — same
- line 638: SC2016 (info) — same
- line 670: SC2016 (info) — same

**The spawn_sim_owner region (lines 103–141) is currently clean.** Accurate gate for this change:
- `bash -n test/validate.sh` → rc 0.
- `shellcheck -S warning -s bash test/validate.sh` → rc 0 (no NEW warnings/errors).
- Equivalently: `shellcheck -s bash test/validate.sh 2>&1 | grep -E '^In test/validate.sh' | wc -l`
  stays at 5 and NONE of them fall in the edited region.

The item description's "shellcheck … rc 0" is satisfied by the `-S warning` form; the bare form is
rc 1 due to the 5 pre-existing info findings, which are unrelated and must be left alone.

---

## 6. Interface contract for downstream P3.M2.T1.S2

P3.M2.T1.S2 (new `selftest_owner_resolves_non_pi_harness`) will call, after this change lands:
- `spawn_sim_owner 600 claude`   (positive: recognized non-pi harness → resolves)
- `spawn_sim_owner 600 xterm`    (negative: unrecognized comm → rejected)

So this item's deliverable contract is precisely:
- `spawn_sim_owner [SECONDS] [COMM]` with `COMM` default `"pi"`.
- The returned PID has `/proc/<pid>/comm == "$COMM"` (after the 15-char guard).
- Zero existing callers change.

---

## 7. Scope boundaries (do NOT do these here — other items own them)

- P3.M1.T1.S2 (Complete) generalized `pool_owner_alive` in `lib/pool.sh` to accept
  `[EXPECTED_COMM]`. (Reflected in this item's refreshed header comment as a factual fix, by
  function name — no line number, to avoid drift.)
- P3.M2.T1.S2 owns the new non-pi selftest.
- P3.M2.T1.S3 owns updating `transparency.sh:528` fail-fast poll text (depends on P3.M1.T1.S3's
  new message wording).
- Do NOT run the test suite (AGENTS.md §1 planning phase; the suite boots real Chrome).
