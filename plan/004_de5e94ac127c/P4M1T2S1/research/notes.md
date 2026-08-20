# Research notes — P4.M1.T2.S1 (POOL_OWNER_MODE / POOL_LANE_PIN)

Verified against lib/pool.sh at HEAD (pre P4.M1.T1.S1 sweep; sweep is 1:1 token subst, line count unchanged):

- `pool_die` at L29–32: `printf '%s\n' "$*" >&2; exit 1`.
- `_pool_config_require_uint` die at ~L74–75: `"$name must be a non-negative integer, got: '${val:-<unset>}'"` — severity precedent for ABPOOL_LANE.
- port_range check ~L192: `pool_die "AGENT_CHROME_PORT_RANGE must be > 0 (got $port_range)"`.
- Step 5b (POOL_PROFILE_DIR raw env capture, ~L196–201) — the raw-string idiom for ABPOOL_OWNER (NOT `_pool_config_bool`: PRD says any non-empty value = caller; "false"/"0" must still be caller mode).
- Step 6 harnesses block ends ~L213 with `POOL_HARNESSES="$harnesses"; declare -g POOL_HARNESSES` — insert new step 6b after this, before "# 7. Derived paths" (~L215).
- Env-var table comment at L112–L131; SC2034 disable at ~L131 covers POOL_* globals; file is shellcheck-clean.
- `pool_config_init` is intentionally re-runnable (no init guard, header comment ~L120–124) — new assignments must be unconditional.
- `grep -r ABPOOL_ lib bin` → zero existing ABPOOL_OWNER/ABPOOL_LANE refs. `test/validate.sh` L25–38 uses its own `ABPOOL_*` framework vars (repo/admin/pass/fail) — unrelated names, untouched.
- TEST-MODE hook malformed PID is warn+ignore (~L539–541) — deliberate contrast; ABPOOL_LANE hard-dies per PRD §2.20 ("validate before the flock section and hard-error").
- Concurrent sibling P4.M1.T1S1 renumbers § citations in lib/pool.sh; new comments must cite NEW numbering (§2.11/§2.12/§2.20).
- Consumers (not in scope): P4.M1.T3.S1 (POOL_OWNER_MODE in pool_owner_resolve), P4.M1.T4.S1/S2 (POOL_LANE_PIN in acquire). Tests: P4.M2.T1.S1. User-doc rows: P4.M1.T2.S2.