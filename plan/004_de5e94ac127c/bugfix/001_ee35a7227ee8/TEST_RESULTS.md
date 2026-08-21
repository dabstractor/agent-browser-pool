# Bug Fix Requirements

## Overview
Tested HEAD (bugfix commit 7154d99: master-dir default, stuck-lane recovery, mid-boot kill sweep, port-exhaustion blocking, one-lane-per-owner guard, help vars) against the PRD end-to-end. Static: bash -n + shellcheck clean on all 7 shell files. Dynamic: all 4 repo suites green (validate 33/33, release_reaper 5/5, transparency 10/10, concurrency 3/3, zero leftovers), the bugfix's own hermetic E2E assertions green (88/0 when paths resolve), plus ~35 novel adversarial checks with fake Chrome/agent-browser sandboxes on btrfs and tmpfs (crash-recovery, caller-mode sequential reuse and parallelism, lane-pin matrix, port exhaustion, corrupt leases, doctor on fresh installs, help-vs-code contract probes). Verified fixes: stuck provisional lane (e2e16 path) recovers, master default matches PRD, port exhaustion now blocks+alerts+cleans, caller mode reuses one lane across sequential commands from a stable parent and reaps on exit, same-owner concurrent acquires serialize onto one lane via the new in-lock guard. Found 6 new bugs: 2 major — (1) re-booting a lane whose ephemeral dir already exists (the new crash-recovery path) nests the master copy inside the dir and silently launches a fresh untrusted profile on btrfs; (2) a second concurrent command from the same owner during boot spuriously fails, double-launches Chrome, clobbers the lease chrome ids, and leaks the real Chrome past `release all` — plus 4 minor (corrupt lease uncleanable by any verb → burned lane; doctor false-FAIL on fresh installs before the ephemeral root exists; help misdocumenting AGENT_BROWSER_POOL_HARNESSES as append; the committed validation suite path-broken as shipped).


## Critical Issues (Must Fix)
Issues that prevent core functionality from working.

None.


## Major Issues (Should Fix)
Issues that significantly impact user experience or functionality.

### Issue 1: Re-boot of an existing lane dir nests the master copy inside it — ephemeral profile silently loses the master identity (btrfs)
**Severity**: Major
**ID**: BUG-001
**Location**: lib/pool.sh:1278-1310 (pool_copy_master cp without existing-target guard); reachable via lib/pool.sh:3818-3834 (wrapper re-boots live port=0 leases)

**Description**:
pool_copy_master (lib/pool.sh:1278) runs `cp -a --reflink=always "$POOL_MASTER_DIR" "$target_dir"` with no guard for an already-existing target. GNU cp with an existing destination dir copies the source INTO it (dst/<basename-src>/...). The wrapper's stuck-lane recovery added in the bugfix (lib/pool.sh:3818-3834: a live lease with port==0 is now re-booted) makes this reachable deterministically: if a boot dies between the copy and the port write (crash/kill mid-boot), the lease stays port=0 with the copied dir present, and the owner's next driving command boots that lane again — cp nests the master inside active/<N> (reproduced: active/1/master2/ containing Local State + Default). The subsequent launch then runs Chrome against a user-data-dir with NO top-level Local State/profile, i.e. a FRESH EMPTY profile — the agent silently loses the trusted identity (logins/Bitwarden) the PRD guarantees (§1.2 'the identity every agent should start from', §2.7, §2.15 recovery). The command still exits 0, so nothing surfaces the corruption. On the operator's btrfs home the reflink cp succeeds directly into the existing dir; on tmpfs/non-btrfs the failure path rm -rf's the target first, masking the bug (why it escaped testing). Two concurrent same-owner commands racing in the pre-port window (both take the fresh-boot path) are a second trigger (see BUG-002). The function's own comments document the nesting hazard but only handle the failed-reflink retry path.

**Steps to Reproduce**:
1) Temp tree on btrfs (e.g. mktemp -d -p /home/dustin), fake chrome + fake agent-browser via AGENT_CHROME_BIN/AGENT_BROWSER_REAL, AGENT_CHROME_MASTER=$T/master. 2) Simulated owner: AGENT_BROWSER_POOL_OWNER_PID=$(pgrep of a live sleep). 3) First `open` with an EMPTY master → rc!=0 'source profile missing or empty', provisional lanes/1.json (port=0) survives. 4) `cp -a $T/master $EPH/1` (simulates crash-after-copy) and populate $T/master (Local State + Default/Preferences). 5) Re-run `open` → rc=0 but `$EPH/1/master/` now exists (nested copy) and $EPH/1 has no top-level 'Local State' — verified in bug-hunt run BH1d on btrfs (entries: crash-marker, master2).

### Issue 2: Concurrent driving commands from one owner during lane boot: spurious failure, duplicate Chrome, clobbered lease ids, and a leaked Chrome that survives release
**Severity**: Major
**ID**: BUG-002
**Location**: lib/pool.sh:2744-2927 (pool_ensure_connected: curl-fail → relaunch without verifying the recorded chrome is dead / no in-flight-boot handling); lib/pool.sh:2083-2101 (3b sweep gated on ids<=0 only); lib/pool.sh:3784+ (wrapper has no boot mutex for same-owner reuse)

**Description**:
There is no same-owner boot synchronization. If an agent issues two pool commands in parallel (pi supports parallel tool calls) while the first is still booting (a window of seconds — copy + port write + CDP wait up to 15 s), the second command finds the live lease (port>0, connected=false) and enters pool_ensure_connected (lib/pool.sh:2744). Its probe curl fails only because the first Chrome has not opened its CDP port YET, but ensure_connected interprets any curl failure as 'Chrome dead' and falls through to the relaunch branch — starting a SECOND chrome on the same port+dir. Reproduced (harness2 R4, fake chrome with 4 s startup delay): the second chrome loses the port race, wait_cdp's identity check (socket owner pid != lease pid) loops to its 15 s timeout, and the second command dies 'agent-browser-pool: lane 1 not connected; aborting' (spurious — the lane was booting fine); meanwhile the lease's chrome_pid/chrome_pgid are clobbered to the doomed second chrome (lease pid dead while the real Chrome lives), and a later `release all` kills by those dead ids (no-op) and rm -rf's the dir — leaving the REAL Chrome running with a deleted user-data-dir (leaked pid observed). The (3b) MID-BOOT cmdline sweep added for validation issue #3 (lib/pool.sh:2083) only fires when BOTH ids are <=0/non-numeric, so a positive-but-dead id defeats it — the exact leak class it was meant to close. Violates PRD §2.16 ('same browser for all my commands across many stateless bash calls'), Goal 4 (guaranteed cleanup), and AGENTS.md §3 (never leak processes). If the second command instead arrives before the port write, both take the fresh-boot path and BUG-001's nested copy triggers as well.

**Steps to Reproduce**:
Isolated temp tree, fake chrome (python HTTP /json/version) with FAKE_CHROME_DELAY=4, live sim owner via AGENT_BROWSER_POOL_OWNER_PID. Start `agent-browser-pool open about:blank` in background; 0.8 s later run `agent-browser-pool get cdp-url`. Observed: rc2=1 ('lane 1 not connected; aborting'), chrome launches=2, lease chrome_pid=844043 (dead) while live chrome is 843893, and after `release all` pid 843893 still running (harness2.sh R4b-R4e, all four assertions FAIL).


## Minor Issues (Nice to Fix)
Small improvements or polish items.

### Issue 1: A corrupt lease file can never be cleaned by any pool verb — lane number permanently burned, permanent '? STALE' status row
**Severity**: Minor
**ID**: BUG-003
**Location**: lib/pool.sh:1189-1276 (pool_lane_is_stale rc2 skip), lib/pool.sh:3131+ (pool_reap_orphan_dirs leaves the lease file), lib/pool.sh:4349+ (pool_admin_release path)

**Description**:
pool_lane_is_stale returns rc 2 (skip) for a corrupt/invalid lease, so pool_reap_stale never touches it; pool_reap_orphan_dirs removes an orphan DIR but leaves the lanes/N.json file in place; and `release N` refuses because pool_lease_exists fails on invalid JSON ('Lane N has no active lease.', rc 1). Net effect: a corrupt lease is uncleanable except by manual rm — `status` shows a permanent '?' STALE row and pool_find_free_lane ([[ -f $LANES/N.json ]]) treats the lane as occupied forever, permanently burning lane N. Since _pool_atomic_write deliberately does no fsync (documented), a power loss (PRD Goal 4 explicitly covers crash/power-loss) can leave a zero-length or partial lease, making this reachable without external sabotage. PRD §2.10 expects stale/corrupt state to be reclaimable by the lazy reaper / `reap`.

**Steps to Reproduce**:
T=$(mktemp -d); mkdir -p $T/state/lanes $T/active/7; printf 'not json {{{' > $T/state/lanes/7.json; printf x > $T/active/7/Preferences; then with HOME/AGENT_BROWSER_POOL_STATE/AGENT_CHROME_EPHEMERAL_ROOT redirected: `agent-browser-pool status` → '7  ? ? ... STALE'; `agent-browser-pool reap` → 'Removed 1 orphan dir(s).' but lanes/7.json REMAINS; `agent-browser-pool release 7` → 'Lane 7 has no active lease.' rc=1. Lane 7 is skipped by every future acquire.

### Issue 2: doctor false-FAILs '[filesystem] not btrfs' on a fresh install because the ephemeral root does not exist yet
**Severity**: Minor
**ID**: BUG-004
**Location**: lib/pool.sh:4597-4604 (pool_admin_doctor filesystem probe); interacts with install.sh step 3

**Description**:
pool_admin_doctor probes the filesystem with `findmnt -nno FSTYPE -T "$POOL_EPHEMERAL_ROOT"` (lib/pool.sh:~4597). findmnt -T on a NON-EXISTENT path exits 1 with empty output (verified), so on a 100% btrfs host where ~/.agent-chrome-profiles/active has not been created yet (a fresh install — install.sh pre-creates only the STATE dir; the ephemeral root is first created by pool_copy_master at first acquire), doctor reports '[filesystem] FAIL (unknown; not btrfs)', returns 1, and install.sh prints 'doctor: found problems'. This contradicts PRD §2.18 step 3 (install runs doctor to verify btrfs on a fresh machine). pool_copy_master itself avoids this by probing the parent dir; doctor does not.

**Steps to Reproduce**:
AGENT_CHROME_EPHEMERAL_ROOT=$T/active-missing (nonexistent) with redirected HOME/state → `agent-browser-pool doctor` prints '[filesystem]  $T/active-missing FAIL (unknown; not btrfs)' and 'Problems found.' on a host whose /home is btrfs (findmnt -nno FSTYPE -T /home/dustin → btrfs, but -T on the missing child path → rc 1, empty).

### Issue 3: `help` misdocuments AGENT_BROWSER_POOL_HARNESSES as APPENDING to the default harnesses — code REPLACES the set (silently disabling pi/claude/codex/agy/antigravity)
**Severity**: Minor
**ID**: BUG-005
**Location**: lib/pool.sh:4879-4880 (pool_admin_help); contradicts lib/pool.sh:227-233 (pool_config_init)

**Description**:
The help text added in the bugfix commit says: 'AGENT_BROWSER_POOL_HARNESSES  extra recognized harness command names (comma-separated; appended to pi/claude/codex/agy)'. The code (pool_config_init, lib/pool.sh:227-233) REPLACES the entire set when the var is set (empty→default). Verified at runtime: with AGENT_BROWSER_POOL_HARNESSES=myagent, POOL_HARNESSES='myagent' and 'pi' is NO LONGER recognized — every default harness's driving commands would fail the ancestor check. The base list cited in help also omits 'antigravity' (the 5th default). README.md:320 and references/configuration.md:28 document the real (replace) semantics; only the built-in help — the first place users look — is wrong. PRD §2.11 defines the variable as the recognized set (code matches PRD; help does not).

**Steps to Reproduce**:
1) `agent-browser-pool help | grep -A1 AGENT_BROWSER_POOL_HARNESSES` → 'appended to pi/claude/codex/agy'. 2) HOME=$T AGENT_BROWSER_POOL_HARNESSES=myagent bash -c 'source lib/pool.sh; pool_config_init; echo $POOL_HARNESSES' → 'myagent' (no defaults). 3) [[ ",$POOL_HARNESSES," == *",pi,"* ]] → false.

### Issue 4: Committed validation suite plan/004_de5e94ac127c/validate.sh is path-broken as committed — 64 of 89 checks fail with 'No such file or directory' when run per its own usage
**Severity**: Minor
**ID**: BUG-006
**Location**: plan/004_de5e94ac127c/validate.sh:24-25 (ROOT/cd vs relative invocations at ~304-567)

**Description**:
The suite (added by the bugfix commit as the recorded validation artifact) resolves ROOT to its own directory and `cd "$ROOT"` (lines 24-25), but then invokes the system under test via REPO-RELATIVE paths (`bash bin/agent-browser-pool`, `bash install.sh`). Run as committed (`bash plan/004_de5e94ac127c/validate.sh [--fast]` from the repo root) it cds into plan/004_de5e94ac127c/ where no bin/ or install.sh exists: result 'passed: 25 failed: 64', every failure an rc-127 path error (e2e01 install, e2e07-e2e16, e2e12 caller-mode, e2e13 pin matrix...). The validation_report.md's '86+ checks pass' is therefore not reproducible from the committed tree — the assertions only pass when the script is executed from a directory that repo-relative paths resolve against (verified: run from a scratch dir with bin/, install.sh, lib/, test/ symlinked to the repo → 'passed: 88 failed: 0', so the underlying checks ARE green on HEAD; it is the harness bootstrap that is broken, undermining the artifact's auditability).

**Steps to Reproduce**:
From the repo root: `bash plan/004_de5e94ac127c/validate.sh --fast` → summary 'passed: 25 failed: 64', e.g. 'FAIL e2e01 install.sh failed: bash: install.sh: No such file or directory'. Then copy the script into a scratch dir containing symlinks bin→repo/bin, install.sh→repo/install.sh, lib→repo/lib, test→repo/test and run it there → 'passed: 88 failed: 0'.

## Testing Summary
- Total bugs found: 6
- Critical: 0
- Major: 2
- Minor: 4

## Recommendations
- Guard pool_copy_master against an existing target (rm -rf the stale dir, or fail loudly) so crash-recovery and concurrent boots cannot nest the master copy; add a regression test on btrfs.
- Serialize same-owner boots: e.g. a per-lane boot flock or a lease 'booting' marker so a concurrent second command waits for (or re-checks) the in-flight boot instead of relaunching; have ensure_connected verify the recorded chrome pid is actually dead before relaunching, and widen the (3b) cmdline sweep to fire when the recorded ids are dead (not only <=0).
- Make `reap`/`release` able to clear corrupt leases (e.g. reap_orphan_dirs also removes an unparseable lanes/N.json after its dir is gone), and consider fsync in _pool_atomic_write given the power-loss requirement.
- Probe the nearest EXISTING ancestor (as pool_copy_master does) in doctor's filesystem check, or pre-create the ephemeral root in install.sh.
- Fix the help text for AGENT_BROWSER_POOL_HARNESSES to match replace semantics and the 5-harness default; fix plan/004_de5e94ac127c/validate.sh's ROOT so the committed validation artifact runs green as shipped.
