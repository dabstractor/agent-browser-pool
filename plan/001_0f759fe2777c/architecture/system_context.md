# System Context & Environment Verification

## Date: 2026-07-12
## Researcher: Lead Architect Agent (automated)

---

## 1. Codebase State — GREENFIELD

The repository `/home/dustin/projects/agent-browser-pool/` is **greenfield**: no source
code exists yet. Current contents:

```
agent-browser-pool/
├── .git/                          ← initialized, 1 commit on main
├── .gitignore                     ← (*.log, .state/)
├── PRD.md                         ← full PRD (READ-ONLY)
├── README.md                      ← overview (pre-existing, needs final sync)
└── plan/001_0f759fe2777c/         ← plan artifacts
    ├── prd_snapshot.md
    ├── prd_index.txt
    └── architecture/              ← THIS DIRECTORY
```

**No `bin/`, `lib/`, `test/`, or `install.sh` exist yet.** All must be created from scratch.

---

## 2. Environment Verification — ALL PRD CLAIMS CONFIRMED

| Claim | Status | Evidence |
|---|---|---|
| `agent-browser` v0.28.0 at `/home/dustin/.local/bin/agent-browser` | ✅ CONFIRMED | `agent-browser 0.28.0`; symlink → node_modules binary |
| btrfs at `~/.agent-chrome-profiles` | ✅ CONFIRMED | `findmnt -T "$HOME/.agent-chrome-profiles"` → `/dev/nvme1n1p2[/@home] btrfs` |
| `cp --reflink=always` works on btrfs | ✅ CONFIRMED | Tested directly on the mount → "REFLINK OK on btrfs" |
| Master template exists (4.8 GB) | ✅ CONFIRMED | `du -sh master-profile` → 4.8G |
| Persistent profiles `1..10` exist | ✅ CONFIRMED | All 10 dirs present |
| `active/` subdir exists (empty) | ✅ CONFIRMED | Created by user, 0 entries |
| `pi` ancestor PID walk works | ✅ CONFIRMED | ppid walk from `$$` → `bash → pi (1409826) → timeout → zsh → ...` |
| All CLI dependencies present | ✅ CONFIRMED | `flock`, `setsid`, `pgrep`, `pkill`, `curl`, `jq`, `notify-send`, `google-chrome-stable`, `cp` — all at expected paths |

---

## 3. PATH Configuration (Critical for Shadowing)

Current PATH order (relevant subset):
```
/home/dustin/.pi/agent/bin          ← pi agent binaries
/home/dustin/scripts                ← TARGET for wrapper symlink (ahead of .local/bin)
/home/dustin/.local/bin             ← real agent-browser lives here
```

**Confirmed:** `~/scripts` precedes `~/.local/bin` on PATH, so a symlink at
`~/scripts/agent-browser` will shadow the real binary. This is the shadowing mechanism.

**Current `~/scripts/agent-browser`:** Does NOT exist yet. No existing wrapper to
displace.

---

## 4. agent-browser Daemon & Session Model

### 4.1 Architecture
- `agent-browser` is a **Rust CLI** (single binary) that launches a **persistent daemon
  process** (observed: PID 590833 on this host).
- The daemon is keyed by **session name**. `AGENT_BROWSER_SESSION=<name>` or
  `--session <name>` selects which daemon connection to use.
- `session list` shows all active session bindings. Each binding points to a CDP endpoint.
- When `connect <port>` is called, it creates/updates the session binding to point at
  the CDP endpoint on that port.
- Subsequent commands (`open`, `click`, `snapshot`, etc.) route through the session's
  daemon → CDP → Chrome.

### 4.2 Key CLI Behaviors Verified
| Command | Behavior | Exit Code |
|---|---|---|
| `agent-browser --session <name> connect <port>` (dead port) | Fails with CDP discovery error | 1 |
| `agent-browser --session <name> get cdp-url` (connected) | Prints WebSocket URL | 0 |
| `agent-browser --session <name> get cdp-url` (unconnected) | Prints URL if daemon has one, else may error | varies |
| `agent-browser --session <name> close` | Disconnects that session only | 0 |
| `agent-browser close --all` | Closes ALL sessions | 0 |
| `AGENT_BROWSER_SESSION=<name> agent-browser session` | Shows current session name | 0 |
| `agent-browser skills get core` | Prints skill doc (passthrough) | 0 |
| `agent-browser session list` | Lists active sessions | 0 |

### 4.3 Session Persistence
Sessions persist in the daemon until explicitly closed. A `connect` to a new port
updates the binding. `close` removes it. **Sessions survive across CLI invocations**
(different bash calls) because the daemon process is persistent.

### 4.4 agent-browser's Own Chrome Management (NOT USED BY POOL)
By default, `agent-browser open <url>` with no prior connect launches its own Chrome
in a temp dir (`/tmp/agent-browser-chrome-<uuid>`) with `--remote-debugging-port=0`.
**The pool wrapper bypasses this entirely** by launching Chrome itself and using
`connect` to bind the daemon to the pool's Chrome.

---

## 5. Existing Chrome Process Patterns

### 5.1 Observed Chrome Launch (by agent-browser's default)
```
/opt/google/chrome/chrome \
  --password-store=gnome-libsecret \
  --ozone-platform-hint=wayland \
  --remote-debugging-port=0 \
  --user-data-dir=/tmp/agent-browser-chrome-<uuid>
```
Note: agent-browser uses `--remote-debugging-port=0` (random port). The pool must use
an **explicit port** from the pool range [53420, 54420).

### 5.2 Chrome Process Tree
Chrome launches as: main process → crashpad_handler → zygotes → GPU process →
network service → renderers → storage service. **All share the same `--user-data-dir`
flag.** This is why `setsid` + `kill -- -<pgid>` is needed for clean teardown.

---

## 6. `/proc` Parsing — CRITICAL FINDING

### 6.1 starttime Field
`starttime` is **field 22** of `/proc/<pid>/stat`. The PRD's suggested `$(NF-19)`
approach is **WRONG** — it returns field 33, not 22.

**Correct methods (all verified on this host):**
```bash
# Method 1: Direct field 22 (safe — "pi" has no spaces in comm)
cut -d' ' -f22 /proc/<pid>/stat

# Method 2: Parens-aware (robust against spaces in comm)
sed 's/.*)//' /proc/<pid>/stat | awk '{print $20}'
# Removes everything up to and including the last ')', then field 20 (= 22 - 2)
```

**Recommended:** Use Method 2 for maximum robustness. The comm field for `pi` is just
"pi" (no spaces), so Method 1 also works, but Method 2 is defensive.

### 6.2 comm Field
`comm` is field 2, wrapped in parens: `(pi)`. Can be read via `/proc/<pid>/comm`
(strips parens, gives bare `pi`).

### 6.3 ppid Field
`ppid` is field 4. Also available via `/proc/<pid>/status` under `PPid:`.

---

## 7. Pool State Directory (To Be Created)

```
~/.local/state/agent-browser-pool/
├── acquire.lock                    ← global flock for acquire critical section
├── alerts.log                      ← exhaustion/force-reap alerts
├── lanes/
│   ├── 1.json                      ← lease for lane 1 (only if held)
│   ├── 2.json                      ← lease for lane 2 (only if held)
│   └── ...
└── chrome-1.log                    ← per-lane Chrome stdout/stderr
└── chrome-2.log
└── ...
```

Does NOT exist yet. Must be created on first run or by install.sh.

---

## 8. Ephemeral Directory Layout

```
~/.agent-chrome-profiles/
├── master-profile/                 ← 4.8 GB, static template (NEVER launched/mutated)
├── active/                         ← ephemeral lanes (exists, currently empty)
│   ├── 1/                          ← CoW copy, deleted on release
│   ├── 2/
│   └── ...
├── 1/ .. 10/                       ← persistent working set (NEVER TOUCHED by wrapper)
```

**Verified:** `active/` exists and is empty. `master-profile/` is 4.8 GB.
`1..10` persistent dirs exist and must never be touched.
